/**
 * Safe batch for the STAGING manual recovery of one stranded in-house VRF request
 * (Failed, or Unprovable past the 8191-block window). The staging PackMachine has no
 * refund function (audit F-02, accepted), so the Safe settles the open by briefly becoming
 * the router's coordinator and delivering words itself. Runbook:
 * aws/docs/pack-rip-latency/RUNBOOK-vrf-staging-manual-recovery.md.
 *
 *   node --experimental-strip-types scripts/vrf/build-recovery-payload.ts \
 *     --coordinator 0x... --request-id <id> --announced-block <n> [--rpc <url>] [--out dir]
 *     [--chunk <blocks>] [--delay <ms>]
 *
 * The words are keccak256(abi.encode(blockhash(announcedBlock), requestId, i)): the admin
 * fixes the block number in the incident notes BEFORE it is mined, so it cannot choose the
 * card. They are public once that block is mined, and the card also depends on the ordered
 * contents of the pack's tier pools at delivery, so the pools must not change from then until
 * the batch executes (audit N-01). The script refuses unless:
 *   - the request is Failed or Unprovable, belongs to the staging router, and the router has
 *     not settled it (chunked scan from the request block, log-scan.ts; audit N-02);
 *   - the router's coordinator is --coordinator and no other request is Pending on it;
 *   - the announced block is mined and after the request block;
 *   - every pool mutator is frozen (recovery-freeze.ts): the machine and the BuybackPool paused,
 *     no authorized depositor, at the announced block AND now, with no pause or depositor
 *     transition in between;
 *   - the machine is exactly the verified clone of the verified implementation, and the ordered
 *     pools of the request's pack and the tier weights the machine resolves from its registry
 *     are identical at the announced block and now (catches operator deposit /
 *     setPackEligibility / withdrawCards / setPackTierWeights, which no pause stops);
 *   - the card(s) predicted from those pools equal what eth_simulateV1 of the exact batch as
 *     the Safe delivers.
 *
 * Output, in deployments/safe/vrf-staging/:
 *   recovery-<id>.json         one atomic Transaction Builder batch, run by the Safe:
 *                              router.setVRFCoordinator(Safe) + router.rawFulfillRandomWords(id, words)
 *                              + router.setVRFCoordinator(coordinator)
 *   recovery-<id>.record.json  what check-recovery-payload.ts re-verifies right before execution:
 *                              the freeze evidence, the ordered pools and their fingerprint, the
 *                              tier weights, the predicted card(s), and the batch file's sha256.
 * Read-only: no keys, no transactions.
 */
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress, parseAbi, parseAbiItem, type Address, type Hex } from "viem";
import { createScanClient, scanLogs } from "./log-scan.ts";
import {
  depositorCandidates,
  drawsAsOutcome,
  freezeProblems,
  freezeTransitions,
  predictDraws,
  readDrawState,
  readFreezeState,
  readPendingOpen,
  recoveryTxs,
  recoveryWords,
  routerAbi,
  sameOutcome,
  sameWeights,
  simulateBatch,
  STAGING_MACHINE,
  STAGING_ROUTER,
  txBuilderJson,
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
function need(name: string): string {
  return arg(name) ?? fail(`missing --${name}`);
}
function uintArg(name: string): bigint | undefined {
  const v = arg(name);
  if (v === undefined) return undefined;
  if (!/^\d+$/.test(v)) fail(`--${name} must be a non-negative integer`);
  return BigInt(v);
}

const coordinator = getAddress(need("coordinator"));
const requestIdArg = need("request-id");
if (!/^\d+$/.test(requestIdArg)) fail("--request-id must be a decimal uint256");
const requestId = BigInt(requestIdArg);
const announcedArg = need("announced-block");
if (!/^\d+$/.test(announcedArg)) fail("--announced-block must be a block number");
const announced = BigInt(announcedArg);
const rpc = arg("rpc") ?? process.env.BASE_RPC_URL ?? "https://mainnet.base.org";
const outDir = arg("out") ?? join(dirname(fileURLToPath(import.meta.url)), "../../deployments/safe/vrf-staging");
const chunk = uintArg("chunk");
if (chunk === 0n) fail("--chunk must be positive");
const delay = uintArg("delay");
const tuning = { chunk, delayMs: delay === undefined ? undefined : Number(delay) };
const client = createScanClient(rpc);

const coordAbi = parseAbi([
  "function getRequest(uint256) view returns ((address router, uint32 numWords, uint32 callbackGasLimit, uint64 blockNum, uint8 status, bytes32 keyHash, uint256 preSeed))",
]);
const REQUESTED = parseAbiItem(
  "event RandomWordsRequested(uint256 indexed requestId, address indexed router, bytes32 indexed keyHash, uint256 preSeed, uint64 blockNum, uint32 numWords, uint32 callbackGasLimit)",
);
const ROUTER_FULFILLED = parseAbiItem("event RandomnessFulfilled(uint256 indexed requestId, address indexed packMachine)");

try {
  if (BigInt(await client.getChainId()) !== 8453n) fail("RPC is not Base mainnet");
  // Every read below is pinned to this block, so the checks describe one consistent state.
  const latest = await client.getBlockNumber();
  const r = await client.readContract({ address: coordinator, abi: coordAbi, functionName: "getRequest", args: [requestId], blockNumber: latest });
  if (getAddress(r.router) !== STAGING_ROUTER) fail(`request router ${r.router} is not the staging router; this runbook is staging-only`);
  const unprovable = r.status === 1 && latest - r.blockNum > WINDOW;
  if (!(r.status === 3 || unprovable)) {
    fail(`request status ${r.status} (block ${r.blockNum}): only Failed, or Pending past the ${WINDOW}-block window, is recovered this way`);
  }
  const current = await client.readContract({ address: STAGING_ROUTER, abi: routerAbi, functionName: "vrfCoordinator", blockNumber: latest });
  if (getAddress(current) !== coordinator) fail("the staging router's coordinator is not --coordinator; resolve that first");
  const settled = await scanLogs(client, { address: STAGING_ROUTER, events: ROUTER_FULFILLED, args: { requestId }, fromBlock: r.blockNum, toBlock: latest, ...tuning });
  if (settled.length) fail(`the router already settled request ${requestId} (tx ${settled[0].transactionHash})`);

  // Any request still provable would fail terminally while the Safe is the coordinator, and a
  // fulfilment would change the pools. Older requests cannot be delivered, so the window is the range.
  const requested = await scanLogs(client, { address: coordinator, events: REQUESTED, fromBlock: latest > WINDOW ? latest - WINDOW : 0n, toBlock: latest, ...tuning });
  for (const l of requested) {
    const id = BigInt(l.topics[1] as Hex);
    if (id === requestId) continue;
    // eslint-disable-next-line no-await-in-loop
    const other = await client.readContract({ address: coordinator, abi: coordAbi, functionName: "getRequest", args: [id], blockNumber: latest });
    if (other.status === 1 && latest - other.blockNum <= WINDOW) {
      fail(`request ${id} is still Pending: wait for the fulfiller to drain it (check-pending.ts) before recovering`);
    }
  }

  if (announced > latest) fail(`announced block ${announced} is not mined yet (latest ${latest}); wait for it`);
  if (announced <= r.blockNum) fail("the announced block must come after the request block");
  const block = await client.getBlock({ blockNumber: announced });

  // N-01: the freeze must hold from the announced block through now.
  const depositors = await depositorCandidates(client, STAGING_MACHINE, latest, tuning);
  const atAnnounced = await readFreezeState(client, STAGING_MACHINE, depositors, announced);
  const atLatest = await readFreezeState(client, STAGING_MACHINE, depositors, latest);
  const transitions = await freezeTransitions(client, STAGING_MACHINE, atLatest.buybackPool, announced + 1n, latest, tuning);
  const problems = [...freezeProblems(atAnnounced), ...freezeProblems(atLatest), ...transitions.map((t) => `freeze changed after the announced block: ${t}`)];
  if (problems.length) {
    fail(
      `pool mutators were not frozen from the announced block on (audit N-01). Freeze first (build-recovery-freeze.ts), then announce a NEW block:\n  ${problems.join("\n  ")}`,
    );
  }

  const pending = await readPendingOpen(client, STAGING_MACHINE, STAGING_ROUTER, requestId, r.blockNum, latest);
  if (pending.cardsCount !== Number(r.numWords)) fail(`pending open has ${pending.cardsCount} card(s) but the request asked ${r.numWords} word(s)`);
  const drawAnnounced = await readDrawState(client, STAGING_MACHINE, pending.packId, announced);
  const draw = await readDrawState(client, STAGING_MACHINE, pending.packId, latest);
  const { pools, tierWeights, poolFingerprint: fingerprint } = draw;
  if (drawAnnounced.poolFingerprint !== fingerprint) {
    fail(`pack ${pending.packId} pools changed after the announced block (${drawAnnounced.poolFingerprint} -> ${fingerprint}); an operator deposit, eligibility change or withdrawal ran during the freeze. Announce a NEW block.`);
  }
  if (!sameWeights(drawAnnounced.tierWeights, tierWeights)) {
    fail(`pack ${pending.packId} tier weights changed after the announced block ([${drawAnnounced.tierWeights}] -> [${tierWeights}]). Announce a NEW block.`);
  }

  const words = recoveryWords(block.hash as Hex, requestId, Number(r.numWords));
  const txs = recoveryTxs(requestId, words, coordinator);
  const draws = predictDraws(pools, tierWeights, words, pending.cardsCount);
  const predicted = drawsAsOutcome(draws);
  const simulated = await simulateBatch(client, txs, STAGING_MACHINE, requestId, latest);
  if (!sameOutcome(predicted, simulated)) {
    fail(`the simulated batch delivers won [${simulated.won}] failed [${simulated.failed.length}], not the predicted won [${predicted.won}] failed [${predicted.failed.length}]; refusing`);
  }

  mkdirSync(outDir, { recursive: true });
  const tag = requestId.toString().slice(0, 12);
  const file = join(outDir, `recovery-${tag}.json`);
  const kind = r.status === 3 ? "Failed" : "Unprovable";
  const batchJson = txBuilderJson(
    `VRF staging recovery ${tag}…`,
    `Settle stranded request ${requestId} (${kind}) with words from announced block ${announced} (${block.hash}). Delivers token(s) ${predicted.won.join(", ") || "none"}. Pool mutators must stay frozen until this executes: the final signer runs check-recovery-payload.ts and executes immediately; never leave it fully signed. Then run recovery-unfreeze.json.`,
    txs,
  );
  writeFileSync(file, batchJson);
  const recordFile = join(outDir, `recovery-${tag}.record.json`);
  const s = (v: bigint) => v.toString();
  writeFileSync(
    recordFile,
    JSON.stringify(
      {
        kind: "nettyworth-vrf-staging-recovery-record",
        version: 1,
        chainId: 8453,
        requestId: s(requestId),
        status: kind,
        requestBlock: s(r.blockNum),
        coordinator,
        router: STAGING_ROUTER,
        machine: STAGING_MACHINE,
        announcedBlock: s(announced),
        announcedBlockHash: block.hash,
        words: words.map(s),
        pendingOpen: { user: pending.user, packId: s(pending.packId), cardsCount: pending.cardsCount },
        tierWeights,
        builtAtBlock: s(latest),
        freeze: {
          depositors,
          atAnnounced: { machinePaused: atAnnounced.machinePaused, buybackPool: atAnnounced.buybackPool, buybackPoolPaused: atAnnounced.buybackPoolPaused, depositors: atAnnounced.depositors },
          atBuild: { machinePaused: atLatest.machinePaused, buybackPool: atLatest.buybackPool, buybackPoolPaused: atLatest.buybackPoolPaused, depositors: atLatest.depositors },
          transitionsAfterAnnounced: [],
        },
        pools: pools.map((p) => p.map(s)),
        poolFingerprint: fingerprint,
        predicted: { won: predicted.won.map(s), failed: predicted.failed.length, draws: draws.map((d) => ({ tokenId: d.tokenId === null ? null : s(d.tokenId), tier: d.tier })) },
        batchFile: `recovery-${tag}.json`,
        batchSha256: createHash("sha256").update(batchJson).digest("hex"),
        transactions: txs,
      },
      null,
      2,
    ) + "\n",
  );
  console.log(`request ${requestId}: ${kind}, ${r.numWords} word(s), pack ${pending.packId}`);
  console.log(`announced block ${announced} hash ${block.hash}`);
  words.forEach((w, i) => console.log(`  word[${i}] ${w}`));
  console.log(`freeze held from block ${announced} to ${latest}: machine and BuybackPool paused, ${depositors.length} depositor(s) de-authorized, no transitions`);
  console.log(`pack ${pending.packId} pools and tier weights [${tierWeights}] unchanged since the announced block: fingerprint ${fingerprint}`);
  console.log(`delivers token(s) ${predicted.won.join(", ") || "none"}${predicted.failed.length ? `, ${predicted.failed.length} CardFailed` : ""} (predicted from the pools = eth_simulateV1 of the batch)`);
  console.log(`wrote ${file}: setVRFCoordinator(Safe) + rawFulfillRandomWords + setVRFCoordinator(${coordinator as Address})`);
  console.log(`wrote ${recordFile}: the final signer runs check-recovery-payload.ts --record ${recordFile} right before executing`);
} catch (err) {
  console.error(err instanceof Error ? err.message.split("\n")[0] : String(err));
  process.exit(2);
}
