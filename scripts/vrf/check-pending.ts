/**
 * Drain and recovery check for the VRF switch (WOR-3306).
 *
 *   node --experimental-strip-types scripts/vrf/check-pending.ts --router <router> [--from-block <n> | --lookback <blocks>] [...]
 *     Router RandomnessRequested minus RandomnessFulfilled (Chainlink or in-house). Default
 *     lookback 2 days. Chainlink's own pendingRequestExists cannot be used: the subscription
 *     is shared by the staging and production routers.
 *
 *   node --experimental-strip-types scripts/vrf/check-pending.ts --coordinator <coordinator> [--from-block <n>]
 *         [--deployment-file base.staging.snapshot] [--deployment-key NettyVRFCoordinator] [...]
 *     Every NettyVRFCoordinator request since the coordinator's deployment block, classified:
 *       Pending     still provable (within BLOCKHASH_WINDOW = 8191 blocks): the fulfiller can answer
 *       Unprovable  Pending on chain but past the window: can never be proven
 *       Failed      proof accepted but the router callback reverted: terminal
 *       Fulfilled   delivered
 *     Unprovable and Failed requests are shown as "settled" when their router has since emitted
 *     RandomnessFulfilled for them (e.g. recovered with the staging manual-recovery runbook);
 *     otherwise the user's open is still escrowed and needs recovery.
 *     The scan starts at --from-block, else at `deployedAtBlock` recorded by
 *     deploy-vrf-coordinator.ts in deployments/<file>.json[<key>] (address must match). It
 *     never falls back to a partial lookback: a missed request would be a stranded user.
 *
 * Common: [--chunk <blocks>] [--delay <ms>] [--rpc <url>] (default BASE_RPC_URL, else mainnet.base.org)
 * Exit codes: 0 nothing open; 1 requests still pending (do NOT switch coordinators);
 *             3 nothing pending, but Unprovable/Failed requests need manual recovery;
 *             2 usage or RPC error.
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress, parseAbiItem, type AbiEvent, type Address } from "viem";
import { createScanClient, DEFAULT_DELAY_MS, scanLogs } from "./log-scan.ts";

/** EIP-2935 HISTORY_SERVE_WINDOW, NettyVRFCoordinator.BLOCKHASH_WINDOW. */
export const BLOCKHASH_WINDOW = 8191n;

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function usage(msg: string): never {
  console.error(msg);
  process.exit(2);
}

function blockArg(name: string): bigint | undefined {
  const v = arg(name);
  if (v === undefined) return undefined;
  if (!/^\d+$/.test(v)) usage(`--${name} must be a non-negative integer`);
  return BigInt(v);
}

const rpc = arg("rpc") ?? process.env.BASE_RPC_URL ?? "https://mainnet.base.org";
// mainnet.base.org caps eth_getLogs at 2,000 blocks and rate-limits; a paid RPC can use
// larger --chunk and --delay 0.
const CHUNK = blockArg("chunk") ?? 2000n;
if (CHUNK <= 0n) usage("--chunk must be positive");
const delayArg = arg("delay");
if (delayArg !== undefined && !/^\d+$/.test(delayArg)) usage("--delay must be a non-negative integer (ms)");
const DELAY_MS = delayArg === undefined ? DEFAULT_DELAY_MS : Number(delayArg);
const client = createScanClient(rpc);

/** Chunked, fail-closed scan of [from, latest] (scripts/vrf/log-scan.ts). */
function scan(address: Address | Address[], event: ReturnType<typeof parseAbiItem>, from: bigint, latest: bigint) {
  return scanLogs(client, { address, events: event as AbiEvent, fromBlock: from, toBlock: latest, chunk: CHUNK, delayMs: DELAY_MS });
}

function requestIdOf(log: { topics: readonly `0x${string}`[] }): bigint {
  const t = log.topics[1];
  if (!t) throw new Error("log without requestId topic");
  return BigInt(t);
}

const ROUTER_FULFILLED = parseAbiItem("event RandomnessFulfilled(uint256 indexed requestId, address indexed packMachine)");

/** Where the coordinator scan starts: --from-block, else the recorded deployment block. */
function coordinatorFromBlock(addr: Address): bigint {
  const explicit = blockArg("from-block");
  if (explicit !== undefined) return explicit;
  const file = arg("deployment-file") ?? "base.staging.snapshot";
  const key = arg("deployment-key") ?? "NettyVRFCoordinator";
  const path = join(dirname(fileURLToPath(import.meta.url)), "../../deployments", `${file}.json`);
  let rec: { address?: string; deployedAtBlock?: string } | undefined;
  try {
    rec = (JSON.parse(readFileSync(path, "utf8")) as Record<string, typeof rec>)[key];
  } catch {
    usage(`cannot read ${path}; pass --from-block <coordinator deployment block>`);
  }
  if (!rec?.address || !rec.deployedAtBlock) usage(`${path} has no ${key}.address/deployedAtBlock; pass --from-block`);
  if (getAddress(rec.address) !== addr) {
    usage(`${path} [${key}] records ${rec.address}, not ${addr}; pass --from-block or the right --deployment-file/--deployment-key`);
  }
  return BigInt(rec.deployedAtBlock);
}

const router = arg("router");
const coordinator = arg("coordinator");
if (!router === !coordinator) usage("pass exactly one of --router or --coordinator");

try {
  const latest = await client.getBlockNumber();
  if (router) {
    const addr = getAddress(router);
    const lookback = blockArg("lookback") ?? BigInt(2 * 24 * 60 * 30); // 2 days of 2 s blocks
    const from = blockArg("from-block") ?? (latest > lookback ? latest - lookback : 0n);
    const req = await scan(addr, parseAbiItem("event RandomnessRequested(uint256 indexed requestId, address indexed packMachine, address user)"), from, latest);
    const ful = await scan(addr, ROUTER_FULFILLED, from, latest);
    const done = new Set(ful.map(requestIdOf));
    const pending = req.filter((l) => !done.has(requestIdOf(l)));
    console.log(`router ${addr}: blocks ${from}..${latest}, ${req.length} requested, ${ful.length} fulfilled`);
    for (const l of pending) console.log(`  PENDING requestId ${requestIdOf(l)} (block ${l.blockNumber}, tx ${l.transactionHash})`);
    console.log(pending.length ? `${pending.length} pending: do NOT switch yet` : "nothing pending: safe to switch");
    process.exit(pending.length ? 1 : 0);
  }

  const addr = getAddress(coordinator as string);
  const from = coordinatorFromBlock(addr);
  if (from > latest) usage(`--from-block ${from} is after the latest block ${latest}`);
  const req = await scan(
    addr,
    parseAbiItem(
      "event RandomWordsRequested(uint256 indexed requestId, address indexed router, bytes32 indexed keyHash, uint256 preSeed, uint64 blockNum, uint32 numWords, uint32 callbackGasLimit)",
    ),
    from,
    latest,
  );
  const abi = [
    {
      type: "function",
      name: "getRequest",
      stateMutability: "view",
      inputs: [{ name: "requestId", type: "uint256" }],
      outputs: [
        {
          type: "tuple",
          components: [
            { name: "router", type: "address" },
            { name: "numWords", type: "uint32" },
            { name: "callbackGasLimit", type: "uint32" },
            { name: "blockNum", type: "uint64" },
            { name: "status", type: "uint8" },
            { name: "keyHash", type: "bytes32" },
            { name: "preSeed", type: "uint256" },
          ],
        },
      ],
    },
  ] as const;

  type Cls = "Pending" | "Unprovable" | "Failed" | "Fulfilled";
  const rows: { id: bigint; cls: Cls; router: Address; blockNum: bigint }[] = [];
  for (const l of req) {
    const id = requestIdOf(l);
    // eslint-disable-next-line no-await-in-loop
    const r = await client.readContract({ address: addr, abi, functionName: "getRequest", args: [id] });
    let cls: Cls;
    if (r.status === 2) cls = "Fulfilled";
    else if (r.status === 3) cls = "Failed";
    else if (r.status === 1) cls = latest - r.blockNum > BLOCKHASH_WINDOW ? "Unprovable" : "Pending";
    else throw new Error(`request ${id} has unexpected on-chain status ${r.status}`);
    rows.push({ id, cls, router: getAddress(r.router), blockNum: r.blockNum });
  }

  // Unprovable/Failed requests may have been settled outside the coordinator (runbook).
  const stuck = rows.filter((r) => r.cls === "Unprovable" || r.cls === "Failed");
  const settled = new Set<bigint>();
  if (stuck.length) {
    const routers = [...new Set(stuck.map((r) => r.router))];
    const fromStuck = stuck.reduce((m, r) => (r.blockNum < m ? r.blockNum : m), latest);
    for (const l of await scan(routers, ROUTER_FULFILLED, fromStuck, latest)) settled.add(requestIdOf(l));
  }

  const counts: Record<Cls, number> = { Pending: 0, Unprovable: 0, Failed: 0, Fulfilled: 0 };
  let needRecovery = 0;
  for (const r of rows) {
    counts[r.cls]++;
    if (r.cls === "Fulfilled") continue;
    const age = latest - r.blockNum;
    if (r.cls === "Pending") {
      console.log(`  Pending     requestId ${r.id} (block ${r.blockNum}, ${age} blocks old, ${BLOCKHASH_WINDOW - age} left in window)`);
    } else if (settled.has(r.id)) {
      console.log(`  ${r.cls.padEnd(11)} requestId ${r.id} (block ${r.blockNum}): settled by router ${r.router}`);
    } else {
      needRecovery++;
      console.log(`  ${r.cls.padEnd(11)} requestId ${r.id} (block ${r.blockNum}): user's open still escrowed, needs manual recovery`);
    }
  }
  console.log(
    `coordinator ${addr}: blocks ${from}..${latest}, ${rows.length} requested: ` +
      `${counts.Pending} Pending, ${counts.Unprovable} Unprovable, ${counts.Failed} Failed, ${counts.Fulfilled} Fulfilled`,
  );
  if (counts.Pending) {
    console.log(`${counts.Pending} pending: do NOT switch coordinators yet (a switch fails them terminally)`);
    process.exit(1);
  }
  if (needRecovery) {
    console.log(`nothing pending (switching is safe), but ${needRecovery} request(s) need the manual-recovery runbook`);
    process.exit(3);
  }
  console.log("nothing open: safe to switch");
  process.exit(0);
} catch (err) {
  console.error(err instanceof Error ? err.message : err);
  process.exit(2);
}
