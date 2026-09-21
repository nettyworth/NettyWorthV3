/**
 * Safe batch for the STAGING manual recovery of one stranded in-house VRF request
 * (Failed, or Unprovable past the 8191-block window). The staging PackMachine has no
 * refund function (audit F-02, accepted), so the Safe settles the open by briefly becoming
 * the router's coordinator and delivering words itself. Runbook:
 * aws/docs/pack-rip-latency/RUNBOOK-vrf-staging-manual-recovery.md.
 *
 *   node --experimental-strip-types scripts/vrf/build-recovery-payload.ts \
 *     --coordinator 0x... --request-id <id> --announced-block <n> [--rpc <url>] [--out dir]
 *
 * The words are keccak256(abi.encode(blockhash(announcedBlock), requestId, i)): the admin
 * fixes the block number in the incident notes BEFORE it is mined, so it cannot choose the
 * card. The script refuses unless the announced block is mined, the request is Failed or
 * Unprovable, the router has not already settled it, the machine is paused and no other
 * request is Pending on the coordinator (a Pending request would fail while the Safe is
 * the coordinator).
 *
 * Output (one atomic Transaction Builder batch, run by the Safe with the machine paused):
 *   router.setVRFCoordinator(Safe) + router.rawFulfillRandomWords(id, words)
 *   + router.setVRFCoordinator(coordinator)
 * Options: [--rpc <url>] (default BASE_RPC_URL, else mainnet.base.org) [--chunk <blocks>] [--out dir]
 * Read-only: no keys, no transactions.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, encodeAbiParameters, encodeFunctionData, getAddress, http, keccak256, parseAbi, parseAbiItem, type Address, type Hex } from "viem";
import { base } from "viem/chains";

const SAFE = getAddress("0xfe78E8aa8f4B9f616e05a94604aB86A7B192f456");
const STAGING_ROUTER = getAddress("0xeA3aDEac6b82b9852a140E642BC10135638653E1");
const STAGING_MACHINE = getAddress("0x46999a9D321df9e752eCc007f5F67D2981183109");
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

const coordinator = getAddress(need("coordinator"));
const requestIdArg = need("request-id");
if (!/^\d+$/.test(requestIdArg)) fail("--request-id must be a decimal uint256");
const requestId = BigInt(requestIdArg);
const announcedArg = need("announced-block");
if (!/^\d+$/.test(announcedArg)) fail("--announced-block must be a block number");
const announced = BigInt(announcedArg);
const rpc = arg("rpc") ?? process.env.BASE_RPC_URL ?? "https://mainnet.base.org";
const outDir = arg("out") ?? join(dirname(fileURLToPath(import.meta.url)), "../../deployments/safe/vrf-staging");
const client = createPublicClient({ chain: base, transport: http(rpc) });

const coordAbi = parseAbi([
  "function getRequest(uint256) view returns ((address router, uint32 numWords, uint32 callbackGasLimit, uint64 blockNum, uint8 status, bytes32 keyHash, uint256 preSeed))",
]);
const routerAbi = parseAbi([
  "function setVRFCoordinator(address newCoordinator)",
  "function rawFulfillRandomWords(uint256 requestId, uint256[] randomWords)",
  "function vrfCoordinator() view returns (address)",
]);
const machineAbi = parseAbi(["function paused() view returns (bool)"]);

try {
  if (BigInt(await client.getChainId()) !== 8453n) fail("RPC is not Base mainnet");
  const latest = await client.getBlockNumber();
  const r = await client.readContract({ address: coordinator, abi: coordAbi, functionName: "getRequest", args: [requestId] });
  if (getAddress(r.router) !== STAGING_ROUTER) fail(`request router ${r.router} is not the staging router; this runbook is staging-only`);
  const unprovable = r.status === 1 && latest - r.blockNum > WINDOW;
  if (!(r.status === 3 || unprovable)) {
    fail(`request status ${r.status} (block ${r.blockNum}): only Failed, or Pending past the ${WINDOW}-block window, is recovered this way`);
  }
  if (getAddress(await client.readContract({ address: STAGING_ROUTER, abi: routerAbi, functionName: "vrfCoordinator" })) !== coordinator) {
    fail("the staging router's coordinator is not --coordinator; resolve that first");
  }
  const settled = await client.getLogs({
    address: STAGING_ROUTER,
    event: parseAbiItem("event RandomnessFulfilled(uint256 indexed requestId, address indexed packMachine)"),
    args: { requestId },
    fromBlock: r.blockNum,
    toBlock: latest,
  });
  if (settled.length) fail(`the router already settled request ${requestId} (tx ${settled[0].transactionHash})`);
  if (!(await client.readContract({ address: STAGING_MACHINE, abi: machineAbi, functionName: "paused" }))) {
    fail("pause the staging PackMachine first (runbook step 2), then drain Pending requests");
  }
  // Any request still provable would fail terminally while the Safe is the coordinator.
  // Requests older than the window cannot be delivered anyway, so the window is the scan range.
  const requested = parseAbiItem(
    "event RandomWordsRequested(uint256 indexed requestId, address indexed router, bytes32 indexed keyHash, uint256 preSeed, uint64 blockNum, uint32 numWords, uint32 callbackGasLimit)",
  );
  const chunk = BigInt(arg("chunk") ?? "2000");
  for (let from = latest > WINDOW ? latest - WINDOW : 0n; from <= latest; from += chunk) {
    const to = from + chunk - 1n < latest ? from + chunk - 1n : latest;
    const logs = await client.getLogs({ address: coordinator, event: requested, fromBlock: from, toBlock: to });
    for (const l of logs) {
      const id = l.args.requestId as bigint;
      if (id === requestId) continue;
      const other = await client.readContract({ address: coordinator, abi: coordAbi, functionName: "getRequest", args: [id] });
      if (other.status === 1) fail(`request ${id} is still Pending: wait for the fulfiller to drain it (check-pending.ts) before recovering`);
    }
  }
  if (announced > latest) fail(`announced block ${announced} is not mined yet (latest ${latest}); wait for it`);
  if (announced <= r.blockNum) fail("the announced block must come after the request block");
  const block = await client.getBlock({ blockNumber: announced });

  const words: bigint[] = [];
  for (let i = 0n; i < BigInt(r.numWords); i++) {
    words.push(BigInt(keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }, { type: "uint256" }], [block.hash as Hex, requestId, i]))));
  }
  const txs = [
    { to: STAGING_ROUTER, data: encodeFunctionData({ abi: routerAbi, functionName: "setVRFCoordinator", args: [SAFE] }) },
    { to: STAGING_ROUTER, data: encodeFunctionData({ abi: routerAbi, functionName: "rawFulfillRandomWords", args: [requestId, words] }) },
    { to: STAGING_ROUTER, data: encodeFunctionData({ abi: routerAbi, functionName: "setVRFCoordinator", args: [coordinator] }) },
  ];
  mkdirSync(outDir, { recursive: true });
  const file = join(outDir, `recovery-${requestId.toString().slice(0, 12)}.json`);
  writeFileSync(
    file,
    JSON.stringify(
      {
        version: "1.0",
        chainId: "8453",
        createdAt: Date.now(),
        meta: {
          name: `VRF staging recovery ${requestId.toString().slice(0, 12)}…`,
          description: `Settle stranded request ${requestId} (${r.status === 3 ? "Failed" : "Unprovable"}) with words from announced block ${announced} (${block.hash}). Machine must stay paused until this batch is executed; unpause afterwards.`,
          txBuilderVersion: "1.16.5",
          createdFromSafeAddress: SAFE,
          createdFromOwnerAddress: "",
        },
        transactions: txs.map((t) => ({ to: t.to, value: "0", data: t.data, contractMethod: null, contractInputsValues: null })),
      },
      null,
      2,
    ) + "\n",
  );
  console.log(`request ${requestId}: ${r.status === 3 ? "Failed" : "Unprovable"}, ${r.numWords} word(s)`);
  console.log(`announced block ${announced} hash ${block.hash}`);
  words.forEach((w, i) => console.log(`  word[${i}] ${w}`));
  console.log(`wrote ${file}: setVRFCoordinator(Safe) + rawFulfillRandomWords + setVRFCoordinator(${coordinator as Address})`);
} catch (err) {
  console.error(err instanceof Error ? err.message.split("\n")[0] : err);
  process.exit(2);
}
