/**
 * Pre-execution check for a staging manual-recovery batch (audit N-01). The FINAL Safe signer
 * runs it immediately before executing, and executes only on exit 0. Runbook:
 * aws/docs/runbooks/vrf-staging-manual-recovery.md.
 *
 *   node --experimental-strip-types scripts/vrf/check-recovery-payload.ts \
 *     --record deployments/safe/vrf-staging/recovery-<id>.record.json [--rpc <url>] [--chunk <blocks>] [--delay <ms>]
 *
 * Re-verifies, against the chain now, everything build-recovery-payload.ts recorded:
 *   - the batch file is byte-identical to the one built (sha256), and its three calls are
 *     exactly setVRFCoordinator(Safe), rawFulfillRandomWords(id, words from the announced block
 *     hash), setVRFCoordinator(coordinator);
 *   - the request is still Failed/Unprovable and unsettled, the router still points at the
 *     coordinator, and no other staging-router request is Pending on it;
 *   - every pool mutator is still frozen and every proxy implementation pinned, with no pause,
 *     depositor or upgrade transition since the announced block;
 *   - the machine is still the verified clone; the pending open, the ORDERED pools of the pack
 *     (same fingerprint) and the tier weights the machine resolves are unchanged;
 *   - the card(s) predicted from the pools equal the recorded ones, and eth_simulateV1 of the
 *     batch as the Safe delivers exactly those.
 * Exit 0: execute now, in this sitting. Exit 2: do NOT execute (the reasons are listed); after a
 * pool change, freeze again and announce a new block. Read-only: no keys, no transactions.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { decodeFunctionData, getAddress, parseAbi, parseAbiItem, type Address, type Hex } from "viem";
import { createScanClient, scanLogs } from "./log-scan.ts";
import {
  depositorCandidates,
  drawsAsOutcome,
  freezeProblems,
  freezeTransitions,
  poolFingerprint,
  predictDraws,
  readDrawState,
  readFreezeState,
  readPendingOpen,
  recoveryTxs,
  recoveryWords,
  routerAbi,
  SAFE,
  sameOutcome,
  sameWeights,
  simulateBatch,
  STAGING_MACHINE,
  STAGING_ROUTER,
} from "./recovery-freeze.ts";

const WINDOW = 8191n;

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
function fail(msg: string): never {
  console.error(msg);
  process.exit(2);
}
function uintArg(name: string): bigint | undefined {
  const v = arg(name);
  if (v === undefined) return undefined;
  if (!/^\d+$/.test(v)) fail(`--${name} must be a non-negative integer`);
  return BigInt(v);
}

const recordPath = arg("record") ?? fail("missing --record <recovery-<id>.record.json>");
const rpc = arg("rpc") ?? process.env.BASE_RPC_URL ?? "https://mainnet.base.org";
const chunk = uintArg("chunk");
if (chunk === 0n) fail("--chunk must be positive");
const delay = uintArg("delay");
const tuning = { chunk, delayMs: delay === undefined ? undefined : Number(delay) };
const client = createScanClient(rpc);

interface RecordFile {
  kind: string;
  version: number;
  requestId: string;
  requestBlock: string;
  coordinator: Address;
  router: Address;
  machine: Address;
  announcedBlock: string;
  announcedBlockHash: Hex;
  words: string[];
  pendingOpen: { user: Address; packId: string; cardsCount: number };
  tierWeights: number[];
  pools: string[][];
  poolFingerprint: Hex;
  predicted: { won: string[]; failed: number };
  batchFile: string;
  batchSha256: string;
}

const coordAbi = parseAbi([
  "function getRequest(uint256) view returns ((address router, uint32 numWords, uint32 callbackGasLimit, uint64 blockNum, uint8 status, bytes32 keyHash, uint256 preSeed))",
]);
const REQUESTED = parseAbiItem(
  "event RandomWordsRequested(uint256 indexed requestId, address indexed router, bytes32 indexed keyHash, uint256 preSeed, uint64 blockNum, uint32 numWords, uint32 callbackGasLimit)",
);
const ROUTER_FULFILLED = parseAbiItem("event RandomnessFulfilled(uint256 indexed requestId, address indexed packMachine)");

let rec: RecordFile;
let batchText: string;
try {
  rec = JSON.parse(readFileSync(recordPath, "utf8")) as RecordFile;
} catch {
  fail(`cannot read ${recordPath}`);
}
if (rec.kind !== "nettyworth-vrf-staging-recovery-record" || rec.version !== 1) fail(`${recordPath} is not a recovery record (v1)`);
if (getAddress(rec.router) !== STAGING_ROUTER || getAddress(rec.machine) !== STAGING_MACHINE) fail("record is not for the staging router and machine");
if (!/^recovery-\d{1,12}\.json$/.test(rec.batchFile)) fail(`record names an unexpected batch file ${rec.batchFile}`);
const batchPath = join(dirname(recordPath), rec.batchFile);
try {
  batchText = readFileSync(batchPath, "utf8");
} catch {
  fail(`cannot read the batch file ${batchPath}`);
}

const problems: string[] = [];
const check = (ok: boolean, msg: string) => {
  if (!ok) problems.push(msg);
};

try {
  if (BigInt(await client.getChainId()) !== 8453n) fail("RPC is not Base mainnet");
  const requestId = BigInt(rec.requestId);
  const coordinator = getAddress(rec.coordinator);
  const announced = BigInt(rec.announcedBlock);

  // 1. The batch is the one that was built, and says what it must.
  check(createHash("sha256").update(batchText).digest("hex") === rec.batchSha256, `${rec.batchFile} was modified after it was built`);
  const block = await client.getBlock({ blockNumber: announced });
  check(block.hash === rec.announcedBlockHash, `announced block ${announced} hash is now ${block.hash}, recorded ${rec.announcedBlockHash} (reorg?)`);
  const words = recoveryWords(block.hash as Hex, requestId, rec.words.length);
  check(words.every((w, i) => w.toString() === rec.words[i]), "recorded words are not the announced block's words");
  const expected = recoveryTxs(requestId, words, coordinator);
  const batch = (JSON.parse(batchText) as { chainId?: string; meta?: { createdFromSafeAddress?: string }; transactions?: { to: string; value: string; data: Hex }[] });
  const txs = batch.transactions ?? [];
  check(batch.chainId === "8453", "batch is not for chain 8453");
  check(batch.meta?.createdFromSafeAddress !== undefined && getAddress(batch.meta.createdFromSafeAddress) === SAFE, "batch is not for the Safe");
  check(
    txs.length === expected.length &&
      txs.every((t, i) => getAddress(t.to) === expected[i].to && t.value === "0" && t.data?.toLowerCase() === expected[i].data.toLowerCase()),
    "batch calls are not exactly setVRFCoordinator(Safe) + rawFulfillRandomWords(id, announced words) + setVRFCoordinator(coordinator)",
  );
  if (txs.length === 3) {
    const d = decodeFunctionData({ abi: routerAbi, data: txs[2].data });
    check(d.functionName === "setVRFCoordinator" && getAddress(d.args[0] as Address) === coordinator, "the last call does not point the router back at the coordinator");
  }

  // 2. Request, router and coordinator (all pinned to one block).
  const latest = await client.getBlockNumber();
  const r = await client.readContract({ address: coordinator, abi: coordAbi, functionName: "getRequest", args: [requestId], blockNumber: latest });
  check(getAddress(r.router) === STAGING_ROUTER, "request is not the staging router's");
  check(r.status === 3 || (r.status === 1 && latest - r.blockNum > WINDOW), `request status is ${r.status}; not Failed or Unprovable`);
  check(BigInt(r.blockNum).toString() === rec.requestBlock, "request block differs from the record");
  const current = await client.readContract({ address: STAGING_ROUTER, abi: routerAbi, functionName: "vrfCoordinator", blockNumber: latest });
  check(getAddress(current) === coordinator, `the router's coordinator is ${current}, not ${coordinator}`);
  const settled = await scanLogs(client, { address: STAGING_ROUTER, events: ROUTER_FULFILLED, args: { requestId }, fromBlock: r.blockNum, toBlock: latest, ...tuning });
  check(settled.length === 0, `the router already settled request ${requestId}${settled[0] ? ` (tx ${settled[0].transactionHash})` : ""}`);
  const requested = await scanLogs(client, { address: coordinator, events: REQUESTED, args: { router: STAGING_ROUTER }, fromBlock: latest > WINDOW ? latest - WINDOW : 0n, toBlock: latest, ...tuning });
  for (const l of requested) {
    const id = BigInt(l.topics[1] as Hex);
    if (id === requestId) continue;
    // eslint-disable-next-line no-await-in-loop
    const other = await client.readContract({ address: coordinator, abi: coordAbi, functionName: "getRequest", args: [id], blockNumber: latest });
    check(!(other.status === 1 && latest - other.blockNum <= WINDOW), `request ${id} is a staging-router request Pending on the coordinator`);
  }

  // 3. Freeze still in effect, and never lifted since the announced block.
  const depositors = await depositorCandidates(client, STAGING_MACHINE, latest, tuning);
  const now = await readFreezeState(client, STAGING_MACHINE, depositors, latest);
  for (const p of freezeProblems(now)) problems.push(p);
  for (const t of await freezeTransitions(client, STAGING_MACHINE, now.buybackPool, announced + 1n, latest, tuning)) {
    problems.push(`freeze changed after the announced block: ${t}`);
  }

  // 4. Pending open, ordered pools and tier weights unchanged.
  const pending = await readPendingOpen(client, STAGING_MACHINE, STAGING_ROUTER, requestId, r.blockNum, latest);
  check(
    pending.user === getAddress(rec.pendingOpen.user) &&
      pending.packId.toString() === rec.pendingOpen.packId &&
      pending.cardsCount === rec.pendingOpen.cardsCount,
    "the machine's pending open differs from the record",
  );
  const { pools, tierWeights, poolFingerprint: fingerprint } = await readDrawState(client, STAGING_MACHINE, pending.packId, latest);
  check(fingerprint === rec.poolFingerprint, `pack ${pending.packId} pools changed since the build (${rec.poolFingerprint} -> ${fingerprint})`);
  check(sameWeights(tierWeights, rec.tierWeights), `pack ${pending.packId} tier weights changed since the build ([${rec.tierWeights}] -> [${tierWeights}])`);
  const recomputed = poolFingerprint(STAGING_MACHINE, BigInt(rec.pendingOpen.packId), rec.pools.map((p) => p.map(BigInt)));
  check(recomputed === rec.poolFingerprint, "the record's pools do not match its own fingerprint");

  // 5. The exact card(s): predicted from the pools, recorded, and simulated.
  const predicted = drawsAsOutcome(predictDraws(pools, tierWeights, words, pending.cardsCount));
  const recorded = { won: rec.predicted.won.map(BigInt), failed: Array<bigint>(rec.predicted.failed).fill(0n) };
  check(sameOutcome(predicted, recorded), `the batch would now deliver [${predicted.won}], recorded [${recorded.won}]`);
  let simulated;
  try {
    simulated = await simulateBatch(client, expected, STAGING_MACHINE, requestId, latest);
  } catch (err) {
    problems.push(`simulation of the batch failed: ${err instanceof Error ? err.message.split("\n")[0] : String(err)}`);
  }
  if (simulated) check(sameOutcome(simulated, predicted), `simulation delivers [${simulated.won}] (failed ${simulated.failed.length}), predicted [${predicted.won}]`);

  if (problems.length) {
    console.error(`DO NOT EXECUTE recovery ${requestId} (block ${latest}):\n  ${problems.join("\n  ")}`);
    console.error("If the pools or the freeze changed: freeze again (build-recovery-freeze.ts), announce a NEW block, rebuild.");
    process.exit(2);
  }
  console.log(`block ${latest}: every check passed for recovery ${requestId}`);
  console.log(`  freeze in effect since announced block ${announced}; pools fingerprint ${fingerprint} and tier weights [${tierWeights}] unchanged`);
  console.log(`  the batch delivers token(s) ${predicted.won.join(", ") || "none"}${predicted.failed.length ? `, ${predicted.failed.length} CardFailed` : ""}`);
  console.log("EXECUTE NOW, in this sitting, as the final signer. Do not leave the transaction fully signed for later.");
} catch (err) {
  problems.push(err instanceof Error ? err.message.split("\n")[0] : String(err));
  console.error(`DO NOT EXECUTE (the check could not complete):\n  ${problems.join("\n  ")}`);
  process.exit(2);
}
