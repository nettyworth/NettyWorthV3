/**
 * Drain check for the VRF switch (WOR-3306): lists randomness requests that have not been
 * fulfilled yet. Run after pausing the PackMachine and before switching coordinators;
 * switching while a request is pending strands it (the new coordinator cannot answer it).
 *
 *   node --experimental-strip-types scripts/vrf/check-pending.ts --router <router> [--lookback <blocks>] [--chunk <blocks>] [--delay <ms>] [--rpc <url>]
 *     Router RandomnessRequested minus RandomnessFulfilled (Chainlink or in-house).
 *   node --experimental-strip-types scripts/vrf/check-pending.ts --coordinator <coordinator> [...]
 *     NettyVRFCoordinator requests whose on-chain status is still Pending or CallbackFailed.
 *
 * Default lookback is 2 days of Base blocks (--lookback), scanned in --chunk block windows. Chainlink's own pendingRequestExists cannot be
 * used: the subscription is shared by the staging and production routers.
 * Exit code 0 = nothing pending, 1 = pending requests listed, 2 = usage/RPC error.
 */
import { createPublicClient, getAddress, http, parseAbiItem, type Address } from "viem";
import { base } from "viem/chains";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

const rpc = arg("rpc") ?? process.env.BASE_RPC_URL ?? "https://mainnet.base.org";
// 2 days of 2 s blocks. A Chainlink request still unanswered after that is stuck anyway.
const lookback = BigInt(arg("lookback") ?? String(2 * 24 * 60 * 30));
// mainnet.base.org caps eth_getLogs at 2,000 blocks and rate-limits; a paid RPC can use
// larger --chunk and --delay 0.
const CHUNK = BigInt(arg("chunk") ?? "2000");
const DELAY_MS = Number(arg("delay") ?? "500");
const client = createPublicClient({ chain: base, transport: http(rpc, { retryCount: 8, retryDelay: 2_000 }) });

async function scan(address: Address, event: ReturnType<typeof parseAbiItem>) {
  const latest = await client.getBlockNumber();
  const from = latest > lookback ? latest - lookback : 0n;
  const logs: Awaited<ReturnType<typeof client.getLogs>> = [];
  for (let start = from; start <= latest; start += CHUNK) {
    const end = start + CHUNK - 1n < latest ? start + CHUNK - 1n : latest;
    // eslint-disable-next-line no-await-in-loop
    logs.push(...(await client.getLogs({ address, event: event as never, fromBlock: start, toBlock: end })));
    // eslint-disable-next-line no-await-in-loop
    if (DELAY_MS > 0) await new Promise((r) => setTimeout(r, DELAY_MS));
  }
  return { logs, from, latest };
}

function requestIdOf(log: { topics: readonly `0x${string}`[] }): bigint {
  const t = log.topics[1];
  if (!t) throw new Error("log without requestId topic");
  return BigInt(t);
}

const router = arg("router");
const coordinator = arg("coordinator");
if (!router === !coordinator) {
  console.error("pass exactly one of --router or --coordinator");
  process.exit(2);
}

try {
  if (router) {
    const addr = getAddress(router);
    const req = await scan(addr, parseAbiItem("event RandomnessRequested(uint256 indexed requestId, address indexed packMachine, address user)"));
    const ful = await scan(addr, parseAbiItem("event RandomnessFulfilled(uint256 indexed requestId, address indexed packMachine)"));
    const done = new Set(ful.logs.map(requestIdOf));
    const pending = req.logs.filter((l) => !done.has(requestIdOf(l)));
    console.log(`router ${addr}: blocks ${req.from}..${req.latest}, ${req.logs.length} requested, ${ful.logs.length} fulfilled`);
    for (const l of pending) console.log(`  PENDING requestId ${requestIdOf(l)} (block ${l.blockNumber}, tx ${l.transactionHash})`);
    console.log(pending.length ? `${pending.length} pending: do NOT switch yet` : "nothing pending: safe to switch");
    process.exit(pending.length ? 1 : 0);
  } else {
    const addr = getAddress(coordinator as string);
    const req = await scan(
      addr,
      parseAbiItem(
        "event RandomWordsRequested(uint256 indexed requestId, address indexed router, bytes32 indexed keyHash, uint256 preSeed, uint64 blockNum, uint32 numWords, uint32 callbackGasLimit)",
      ),
    );
    const STATUS = ["None", "Pending", "Fulfilled", "CallbackFailed"];
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
    let open = 0;
    for (const l of req.logs) {
      const id = requestIdOf(l);
      // eslint-disable-next-line no-await-in-loop
      const r = await client.readContract({ address: addr, abi, functionName: "getRequest", args: [id] });
      if (r.status === 1 || r.status === 3) {
        open++;
        console.log(`  ${STATUS[r.status]} requestId ${id} (block ${r.blockNum})`);
      }
    }
    console.log(`coordinator ${addr}: blocks ${req.from}..${req.latest}, ${req.logs.length} requested, ${open} open`);
    console.log(open ? `${open} open: do NOT switch yet (CallbackFailed can be redelivered with retry)` : "nothing open: safe to switch");
    process.exit(open ? 1 : 0);
  }
} catch (err) {
  console.error(err instanceof Error ? err.message : err);
  process.exit(2);
}
