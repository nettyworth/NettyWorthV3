/**
 * logs.ts
 *
 * Shared helpers for historical log analysis.
 *
 * Public RPCs (including Base) cap `eth_getLogs` by block range and/or result
 * count, so a full-history scan must be split into chunks. These helpers also
 * cover the two supporting problems that come with it: finding a sensible start
 * block from a deployment timestamp, and hydrating block timestamps for the
 * blocks that actually produced logs.
 */

import { sleep } from "./sleep.js";

/**
 * Minimal structural type for the viem public client bits used here.
 * Argument types are intentionally loose — viem's generic overloads do not
 * unify with a narrow structural signature.
 */
type LogClient = {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  getContractEvents: (args: any) => Promise<any[]>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  getBlock: (args: any) => Promise<{ timestamp: bigint }>;
  getBlockNumber: () => Promise<bigint>;
};

/** Default block-range chunk; override with LOG_CHUNK_SIZE. */
export const DEFAULT_CHUNK_SIZE = 10_000n;

export function chunkSizeFromEnv(): bigint {
  const raw = process.env.LOG_CHUNK_SIZE;
  if (!raw) return DEFAULT_CHUNK_SIZE;
  const parsed = BigInt(raw);
  if (parsed <= 0n) throw new Error(`LOG_CHUNK_SIZE must be > 0 (got ${raw})`);
  return parsed;
}

function errorText(err: unknown): string {
  const e = err as {
    details?: string;
    shortMessage?: string;
    message?: string;
  };
  return e?.details ?? e?.shortMessage ?? e?.message ?? String(err);
}

/**
 * Rate limiting must not be confused with "range too wide" — the range is fine,
 * the request just needs to wait. Shrinking on a 429 would make it worse.
 */
function isRateLimit(err: unknown): boolean {
  const msg = errorText(err).toLowerCase();
  const status =
    (err as { status?: number; statusCode?: number })?.status ??
    (err as { statusCode?: number })?.statusCode;
  return (
    status === 429 ||
    msg.includes("429") ||
    msg.includes("rate limit") ||
    msg.includes("too many requests") ||
    msg.includes("-32016")
  );
}

export interface ChunkedLogOptions {
  address: `0x${string}` | `0x${string}`[];
  abi: readonly unknown[];
  eventName: string;
  fromBlock: bigint;
  toBlock: bigint;
  chunkSize?: bigint;
  /** Optional progress callback: (scannedTo, total, matchedSoFar). */
  onProgress?: (scannedTo: bigint, toBlock: bigint, found: number) => void;
}

/**
 * Fetches all logs for a single event across a block range, splitting the range
 * into chunks and halving the chunk whenever a request fails.
 *
 * Providers signal "range too wide / too many results" inconsistently — Alchemy
 * returns a bare HTTP 400 with no machine-readable reason — so any failure is
 * treated as a shrink signal. Once a width fails, it becomes a hard ceiling for
 * the rest of the scan, so the loop settles instead of oscillating. If the
 * width reaches one block and the request still fails, the error is real and is
 * rethrown.
 *
 * `address` may be an array — viem forwards it to eth_getLogs, so every
 * PackMachine clone can be scanned in one pass.
 */
export async function getLogsChunked<T = Record<string, unknown>>(
  publicClient: LogClient,
  opts: ChunkedLogOptions,
): Promise<T[]> {
  const { address, abi, eventName, fromBlock, toBlock, onProgress } = opts;
  const results: T[] = [];

  let chunk = opts.chunkSize ?? chunkSizeFromEnv();
  let ceiling = chunk;
  let cursor = fromBlock;
  let rateLimitRetries = 0;

  while (cursor <= toBlock) {
    const end = cursor + chunk - 1n > toBlock ? toBlock : cursor + chunk - 1n;

    try {
      const logs = (await publicClient.getContractEvents({
        address,
        abi,
        eventName,
        fromBlock: cursor,
        toBlock: end,
        strict: true,
      })) as T[];

      results.push(...logs);
      cursor = end + 1n;
      rateLimitRetries = 0;
      onProgress?.(end, toBlock, results.length);

      // Grow back, but never past a width that has already failed.
      if (chunk < ceiling) chunk = chunk * 2n > ceiling ? ceiling : chunk * 2n;
    } catch (err) {
      if (isRateLimit(err)) {
        if (++rateLimitRetries > 8) throw err;
        await sleep(500 * 2 ** (rateLimitRetries - 1));
        continue;
      }
      if (chunk <= 1n) throw err;
      ceiling = chunk / 2n;
      chunk = ceiling < 1n ? 1n : ceiling;
      console.warn(
        `\n  ⚠️  ${eventName}: request failed at ${cursor}-${end}, retrying with ${chunk}-block chunks (${errorText(err)})`,
      );
    }
  }

  return results;
}

/**
 * Binary-searches for the first block with `timestamp >= target`.
 * Costs ~log2(headBlock) getBlock calls (~25 on Base) — far cheaper than
 * scanning logs from block 0 on a chain with tens of millions of blocks.
 */
export async function blockAtTimestamp(
  publicClient: LogClient,
  targetTimestamp: bigint,
): Promise<bigint> {
  let lo = 0n;
  let hi = await publicClient.getBlockNumber();

  const head = await publicClient.getBlock({ blockNumber: hi });
  if (head.timestamp <= targetTimestamp) return hi;

  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    const block = await publicClient.getBlock({ blockNumber: mid });
    if (block.timestamp < targetTimestamp) lo = mid + 1n;
    else hi = mid;
  }

  return lo;
}

/** Runs `worker` over `items` with at most `concurrency` in flight. */
export async function mapWithConcurrency<T, R>(
  items: T[],
  concurrency: number,
  worker: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;

  const runners = Array.from(
    { length: Math.min(concurrency, items.length) },
    async () => {
      for (;;) {
        const index = next++;
        if (index >= items.length) return;
        results[index] = await worker(items[index]!, index);
      }
    },
  );

  await Promise.all(runners);
  return results;
}

/**
 * Fetches timestamps for the given block numbers (deduplicated), returning a
 * map keyed by block number. Backs off and retries on rate limiting rather than
 * failing the run — this is the highest-volume call in a log analysis.
 */
export async function fetchBlockTimestamps(
  publicClient: LogClient,
  blockNumbers: bigint[],
  concurrency = 8,
): Promise<Map<bigint, bigint>> {
  const unique = [...new Set(blockNumbers)];
  const timestamps = new Map<bigint, bigint>();

  await mapWithConcurrency(unique, concurrency, async (blockNumber) => {
    for (let attempt = 0; ; attempt++) {
      try {
        const block = await publicClient.getBlock({ blockNumber });
        timestamps.set(blockNumber, block.timestamp);
        return;
      } catch (err) {
        if (!isRateLimit(err) || attempt >= 8) throw err;
        await sleep(500 * 2 ** attempt);
      }
    }
  });

  return timestamps;
}
