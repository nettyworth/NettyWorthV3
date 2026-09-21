/**
 * Chunked eth_getLogs scan shared by the VRF operations scripts (check-pending.ts,
 * build-recovery-payload.ts, check-recovery-payload.ts; audit N-02).
 *
 * Guarantees, the same ones check-pending.ts has always relied on:
 *   - Every block in [fromBlock, toBlock] is queried exactly once, in contiguous ranges of at
 *     most `chunk` blocks. There is no "recent blocks only" fallback: a scan either covers the
 *     whole range or throws.
 *   - Transient RPC errors are retried by the transport (createScanClient: 8 retries, 2 s apart).
 *   - A range the provider refuses as too large (mainnet.base.org caps eth_getLogs at 2,000
 *     blocks, the free drpc tier at 10,000, tenderly at 1,000) is split in half and both halves
 *     are scanned, down to a single block. Any other error, or a refusal of a single block,
 *     is thrown: the caller fails closed.
 *   - Every returned log is checked to be mined (non-null block number), not removed, emitted
 *     by a requested address and inside the range that was asked for; anything else throws.
 *   - Results are sorted by (blockNumber, logIndex) and deduplicated.
 * An optional delay between requests keeps public endpoints under their rate limits.
 */
import { createPublicClient, getAddress, http, type AbiEvent, type Address, type Log, type PublicClient } from "viem";
import { base } from "viem/chains";

export const DEFAULT_CHUNK = 2000n;
export const DEFAULT_DELAY_MS = 500;

/** Base mainnet client with the retry policy every scan relies on. */
export function createScanClient(rpc: string): PublicClient {
  return createPublicClient({ chain: base, transport: http(rpc, { retryCount: 8, retryDelay: 2_000 }) }) as PublicClient;
}

export interface ScanOptions {
  address: Address | readonly Address[];
  /** One event or several (topic0 OR-filter). */
  events: AbiEvent | readonly AbiEvent[];
  /** Indexed-argument filter; only valid with a single event. */
  args?: Record<string, unknown>;
  fromBlock: bigint;
  toBlock: bigint;
  chunk?: bigint;
  delayMs?: number;
}

const RANGE_REFUSAL = [
  /block range/i,
  /range (is )?too (large|wide|big)/i,
  /limited to (a )?[\d,]+ (block )?range/i,
  /limited to [\d,]+ ?- ?[\d,]+ blocks/i,
  /exceed(s|ed)? .*(range|limit|max)/i,
  /query returned more than/i,
  /too many (results|logs|blocks)/i,
  /response size (is )?(too large|exceeded)/i,
  /maximum \d+ blocks/i,
];

/** True when the provider refused the query for its size, not for a transient reason. */
export function isRangeRefusal(err: unknown): boolean {
  const parts: string[] = [];
  let e: unknown = err;
  for (let depth = 0; e && depth < 6; depth++) {
    const o = e as { message?: unknown; details?: unknown; shortMessage?: unknown; cause?: unknown };
    for (const v of [o.message, o.details, o.shortMessage]) if (typeof v === "string") parts.push(v);
    e = o.cause;
  }
  const text = parts.join("\n");
  return RANGE_REFUSAL.some((re) => re.test(text));
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export async function scanLogs(client: PublicClient, opts: ScanOptions): Promise<Log[]> {
  const chunk = opts.chunk ?? DEFAULT_CHUNK;
  const delayMs = opts.delayMs ?? DEFAULT_DELAY_MS;
  if (chunk <= 0n) throw new Error("scanLogs: chunk must be positive");
  if (opts.fromBlock < 0n || opts.toBlock < 0n) throw new Error("scanLogs: negative block number");
  if (opts.fromBlock > opts.toBlock) throw new Error(`scanLogs: fromBlock ${opts.fromBlock} is after toBlock ${opts.toBlock}`);
  const events = (Array.isArray(opts.events) ? opts.events : [opts.events]) as AbiEvent[];
  if (events.length === 0) throw new Error("scanLogs: no events");
  if (opts.args && events.length !== 1) throw new Error("scanLogs: args filter needs exactly one event");
  const addresses = new Set((Array.isArray(opts.address) ? opts.address : [opts.address]).map((a) => getAddress(a as string)));

  const out: Log[] = [];
  let first = true;
  const query = async (start: bigint, end: bigint): Promise<void> => {
    if (!first && delayMs > 0) await sleep(delayMs);
    first = false;
    let logs: Log[];
    try {
      logs = (await client.getLogs({
        address: [...addresses],
        ...(events.length === 1 ? { event: events[0], args: opts.args } : { events }),
        fromBlock: start,
        toBlock: end,
        strict: false,
      } as never)) as Log[];
    } catch (err) {
      if (end > start && isRangeRefusal(err)) {
        const mid = start + (end - start) / 2n;
        await query(start, mid);
        await query(mid + 1n, end);
        return;
      }
      throw err;
    }
    for (const l of logs) {
      if (l.blockNumber === null || l.logIndex === null) throw new Error("scanLogs: provider returned a pending log");
      if (l.removed) throw new Error("scanLogs: provider returned a removed log");
      if (l.blockNumber < start || l.blockNumber > end) {
        throw new Error(`scanLogs: log in block ${l.blockNumber} outside the queried range ${start}..${end}`);
      }
      if (!addresses.has(getAddress(l.address))) throw new Error(`scanLogs: log from unrequested address ${l.address}`);
    }
    out.push(...logs);
  };

  for (let start = opts.fromBlock; start <= opts.toBlock; start += chunk) {
    const end = start + chunk - 1n < opts.toBlock ? start + chunk - 1n : opts.toBlock;
    // eslint-disable-next-line no-await-in-loop
    await query(start, end);
  }

  const seen = new Set<string>();
  return out
    .filter((l) => {
      const k = `${l.blockHash}:${l.logIndex}`;
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    })
    .sort((a, b) =>
      a.blockNumber === b.blockNumber ? Number(a.logIndex! - b.logIndex!) : a.blockNumber! < b.blockNumber! ? -1 : 1,
    );
}
