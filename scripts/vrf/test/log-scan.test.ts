/**
 * Unit tests for log-scan.ts (audit N-02). No network.
 *   node --experimental-strip-types --test scripts/vrf/test/
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { parseAbiItem, type PublicClient } from "viem";
import { isRangeRefusal, scanLogs } from "../log-scan.ts";

const EVENT = parseAbiItem("event RandomnessFulfilled(uint256 indexed requestId, address indexed packMachine)");
const ADDR = "0xeA3aDEac6b82b9852a140E642BC10135638653E1";

/** Fake provider: one log per block divisible by 7; refuses ranges wider than `cap` like mainnet.base.org. */
function fakeClient(cap: bigint, opts: { failAt?: bigint; outOfRange?: boolean } = {}) {
  const queried: [bigint, bigint][] = [];
  const client = {
    async getLogs({ fromBlock, toBlock }: { fromBlock: bigint; toBlock: bigint }) {
      if (toBlock - fromBlock + 1n > cap) {
        throw Object.assign(new Error("RPC Request failed."), { details: "eth_getLogs is limited to a 2,000 range" });
      }
      if (opts.failAt !== undefined && fromBlock <= opts.failAt && opts.failAt <= toBlock) throw new Error("connection reset");
      queried.push([fromBlock, toBlock]);
      const logs = [];
      for (let b = fromBlock; b <= toBlock; b++) {
        if (b % 7n === 0n) logs.push({ address: ADDR, blockNumber: opts.outOfRange ? toBlock + 1n : b, logIndex: 0, blockHash: `0x${b.toString(16)}`, removed: false, topics: [] });
      }
      return logs;
    },
  } as unknown as PublicClient;
  return { client, queried };
}

test("covers every block exactly once, bisecting refused ranges", async () => {
  const { client, queried } = fakeClient(300n);
  const logs = await scanLogs(client, { address: ADDR, events: EVENT, fromBlock: 10n, toBlock: 5_009n, chunk: 2000n, delayMs: 0 });
  const covered = queried.map(([a, b]) => [a, b]).sort((x, y) => (x[0] < y[0] ? -1 : 1));
  assert.equal(covered[0][0], 10n);
  assert.equal(covered[covered.length - 1][1], 5_009n);
  for (let i = 1; i < covered.length; i++) assert.equal(covered[i][0], covered[i - 1][1] + 1n, "contiguous, no gap, no overlap");
  const expected = [];
  for (let b = 10n; b <= 5_009n; b++) if (b % 7n === 0n) expected.push(b);
  assert.deepEqual(logs.map((l) => l.blockNumber), expected, "every log once, in order");
});

test("a non-range error fails the whole scan (no partial result)", async () => {
  const { client } = fakeClient(10_000n, { failAt: 3_333n });
  await assert.rejects(scanLogs(client, { address: ADDR, events: EVENT, fromBlock: 0n, toBlock: 9_999n, chunk: 2000n, delayMs: 0 }), /connection reset/);
});

test("a single refused block fails instead of being skipped", async () => {
  const { client } = fakeClient(0n);
  await assert.rejects(scanLogs(client, { address: ADDR, events: EVENT, fromBlock: 5n, toBlock: 6n, chunk: 2n, delayMs: 0 }), (err: { details?: string }) => {
    assert.match(err.details ?? "", /2,000 range/);
    return true;
  });
});

test("a log outside the queried range is rejected", async () => {
  const { client } = fakeClient(10_000n, { outOfRange: true });
  await assert.rejects(scanLogs(client, { address: ADDR, events: EVENT, fromBlock: 0n, toBlock: 99n, delayMs: 0 }), /outside the queried range/);
});

test("argument validation", async () => {
  const { client } = fakeClient(10n);
  await assert.rejects(scanLogs(client, { address: ADDR, events: EVENT, fromBlock: 10n, toBlock: 9n }), /after toBlock/);
  await assert.rejects(scanLogs(client, { address: ADDR, events: EVENT, fromBlock: 0n, toBlock: 9n, chunk: 0n }), /chunk must be positive/);
  await assert.rejects(scanLogs(client, { address: ADDR, events: [EVENT, EVENT], args: { requestId: 1n }, fromBlock: 0n, toBlock: 9n }), /exactly one event/);
});

test("range refusals of the providers we use are recognised; transient errors are not", () => {
  assert.ok(isRangeRefusal({ details: "eth_getLogs is limited to a 2,000 range" })); // mainnet.base.org
  assert.ok(isRangeRefusal({ message: "eth_getLogs is limited to 0 - 50 blocks range" })); // 1rpc
  assert.ok(isRangeRefusal({ message: "invalid params", cause: { message: "Block range too large for public access: maximum 1000 blocks" } })); // tenderly
  assert.ok(isRangeRefusal({ message: "query returned more than 10000 results" }));
  assert.ok(!isRangeRefusal({ message: "over rate limit" }));
  assert.ok(!isRangeRefusal({ message: "connection reset" }));
});
