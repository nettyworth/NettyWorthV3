/**
 * analyze-pack-open-rates.ts
 *
 * Read-only script that reconstructs the realized tier distribution of pack
 * openings from on-chain event logs, per (PackMachine, packId), and writes one
 * CSV row per drawn card.
 *
 * Usage
 * -----
 * # All clones known to the factory, full history since machine creation:
 * npx hardhat run scripts/analyze-pack-open-rates.ts --network base
 *
 * # Specific machine(s) and an explicit block range:
 * PACK_MACHINE=0x<addr>[,0x<addr>] FROM_BLOCK=25000000 TO_BLOCK=latest \
 *   npx hardhat run scripts/analyze-pack-open-rates.ts --network base
 *
 * NOTE ON RPC LIMITS: the configured BASE_RPC_URL is on a free Alchemy tier that
 * caps eth_getLogs at a 10-block range, which cannot scan months of history.
 * Point the log scan at a node with a usable range — https://mainnet.base.org
 * allows 10,000 — while contract reads keep using the hardhat network:
 *
 * LOGS_RPC_URL=https://mainnet.base.org \
 *   npx hardhat run scripts/analyze-pack-open-rates.ts --network base
 *
 * Optional env
 * ------------
 * PACK_MACHINE            comma-separated clone addresses (default: factory.getAllPackMachines())
 * PACK_MACHINE_FACTORY    override factory proxy from deployments JSON
 * PACK_REGISTRY_PROXY     override PackRegistry proxy
 * BUYBACK_POOL_PROXY      override BuybackPool proxy
 * LOGS_RPC_URL            RPC used for log scanning only (default: hardhat network)
 * FROM_BLOCK / TO_BLOCK   block range ("latest" allowed for TO_BLOCK)
 * LOG_CHUNK_SIZE          eth_getLogs chunk width (default 10000)
 * OUT_FILE                CSV output path (default deployments/pack-draws.<network>.csv)
 * SKIP_TIMESTAMPS=1       skip per-block timestamp hydration (fewer RPC calls)
 *
 * How the tier of a won card is recovered
 * ---------------------------------------
 * `CardWon(user, tokenId, requestId)` carries no tier and no packId. The packId
 * comes from `PackOpened(user, requestId, packId, pricePaid)`, joined on
 * (machine, requestId) — note PackOpened is emitted AFTER its CardWon logs, so
 * grouping is by requestId, never by log order.
 *
 * The tier comes from `BuybackPool.TokenRegistered(tokenId, sourcePackMachine,
 * tier)`, emitted in the same fulfill-loop iteration (same tx) as the CardWon.
 * Fallbacks when that log is absent (buyback pool inactive at the time, or
 * registration reverted -> BuybackRegistrationFailed): a live
 * BuybackPool.getTokenInfo read, then the clone's own packTokenTier via
 * getPackTokenTier (only works while the token sits in the pool, i.e. for
 * failed draws and redeposited cards). Unresolved rows are reported as
 * "unknown" rather than dropped.
 *
 * The tierSource column records which path produced each value, because the two
 * fallbacks read CURRENT state: they report the token's tier now, which is only
 * the tier at draw time if the operator never reassigned it. Rows marked
 * "event" are exact; treat "buyback_read" / "machine_read" as best-effort.
 *
 * PackTierRegistry is deliberately NOT used: nothing calls setTier, so getTier
 * returns 0 for every token — indistinguishable from a real Base tier.
 *
 * Reading the numbers
 * -------------------
 * Observed rates are NOT expected to match the declared Pack.tierWeights
 * exactly. The draw zeroes any tier whose pool is empty at fulfill time and
 * renormalizes the remaining weights over the active total, so a tier that ran
 * dry shifts its probability mass onto the others. The recap prints current
 * per-(pack, tier) pool sizes so dry tiers are visible.
 */

import { network } from "hardhat";
import { createPublicClient, formatUnits, getAddress, http } from "viem";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { getDeploymentPath, readDeployments } from "./lib/deployments.js";
import {
  blockAtTimestamp,
  fetchBlockTimestamps,
  getLogsChunked,
  mapWithConcurrency,
} from "./lib/logs.js";

// ─── Tier labels (0-5 convention, see contracts/lib/PackTypes.sol) ───────────

const NUM_TIERS = 6;
const TIER_NAMES = [
  "Base",
  "Common",
  "Uncommon",
  "Rare",
  "Ultra Rare",
  "Grail",
] as const;

function tierName(tier: number): string {
  return TIER_NAMES[tier] ?? `Unknown(${tier})`;
}

// ─── Event ABI fragments ─────────────────────────────────────────────────────
// PackOpened / CardWon / CardFailed / BuybackRegistrationFailed are declared in
// PackFulfillLib and emitted under delegatecall, so the logs are attributed to
// the clone address but do NOT appear in the PackMachine artifact ABI.

const packMachineEventsAbi = [
  {
    name: "PackOpened",
    type: "event",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "requestId", type: "uint256", indexed: true },
      { name: "packId", type: "uint256", indexed: true },
      { name: "pricePaid", type: "uint128", indexed: false },
    ],
  },
  {
    name: "CardWon",
    type: "event",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "tokenId", type: "uint256", indexed: true },
      { name: "requestId", type: "uint256", indexed: true },
    ],
  },
  {
    name: "CardFailed",
    type: "event",
    inputs: [
      { name: "user", type: "address", indexed: true },
      { name: "tokenId", type: "uint256", indexed: true },
      { name: "requestId", type: "uint256", indexed: true },
    ],
  },
  {
    name: "BuybackRegistrationFailed",
    type: "event",
    inputs: [
      { name: "tokenId", type: "uint256", indexed: true },
      { name: "requestId", type: "uint256", indexed: true },
    ],
  },
] as const;

const buybackEventsAbi = [
  {
    name: "TokenRegistered",
    type: "event",
    inputs: [
      { name: "tokenId", type: "uint256", indexed: true },
      { name: "sourcePackMachine", type: "address", indexed: true },
      { name: "tier", type: "uint8", indexed: false },
    ],
  },
] as const;

const packRegistryEventsAbi = [
  {
    name: "PackTierWeightsUpdated",
    type: "event",
    inputs: [
      { name: "machine", type: "address", indexed: true },
      { name: "packId", type: "uint256", indexed: true },
      { name: "weights", type: "uint32[6]", indexed: false },
    ],
  },
] as const;

// ─── Network connection ──────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();

// Log scanning is often the binding constraint, not contract reads: many free
// RPC tiers cap eth_getLogs at a 10-block range, which makes a months-long scan
// impossible. LOGS_RPC_URL points the log scan at a node with a usable range
// (e.g. https://mainnet.base.org allows 10,000) while contract reads continue
// to use the configured hardhat network.
const logClient = process.env.LOGS_RPC_URL
  ? createPublicClient({ transport: http(process.env.LOGS_RPC_URL) })
  : publicClient;

const deployments = await readDeployments(connection.networkName);

function resolveProxy(
  key: string,
  envVar: string,
  field: "proxy" | "implementation" = "proxy",
): `0x${string}` {
  const override = process.env[envVar];
  if (override) return getAddress(override) as `0x${string}`;

  const entry = deployments[key] as Record<string, unknown> | undefined;
  if (!entry?.[field]) {
    console.error(
      `${key} ${field} not found in deployments/${connection.networkName}.json.`,
    );
    console.error(`Set ${envVar} to override.`);
    process.exit(1);
  }
  return getAddress(entry[field] as string) as `0x${string}`;
}

const factoryAddress = resolveProxy(
  "PackMachineFactory",
  "PACK_MACHINE_FACTORY",
);
const registryAddress = resolveProxy("PackRegistry", "PACK_REGISTRY_PROXY");
const buybackAddress = resolveProxy("BuybackPool", "BUYBACK_POOL_PROXY");

const factory = await viem.getContractAt("PackMachineFactory", factoryAddress);
const packRegistry = await viem.getContractAt("PackRegistry", registryAddress);
const buyback = await viem.getContractAt("BuybackPool", buybackAddress);

// ─── Resolve target machines ─────────────────────────────────────────────────

let machines: `0x${string}`[];

if (process.env.PACK_MACHINE) {
  machines = process.env.PACK_MACHINE.split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      try {
        return getAddress(s) as `0x${string}`;
      } catch {
        console.error(`Invalid PACK_MACHINE address: "${s}"`);
        process.exit(1);
      }
    });
} else {
  // The factory is authoritative — the PackMachines array in the deployments
  // JSON only records clones created by deploy scripts.
  const all = (await factory.read.getAllPackMachines()) as readonly string[];
  machines = [...all].map((a) => getAddress(a) as `0x${string}`);
}

if (machines.length === 0) {
  console.error("No PackMachine clones to analyze.");
  process.exit(1);
}

const machineSet = new Set(machines);

// ─── Resolve block range ─────────────────────────────────────────────────────

const latestBlock = await logClient.getBlockNumber();

let toBlock: bigint;
if (!process.env.TO_BLOCK || process.env.TO_BLOCK === "latest") {
  toBlock = latestBlock;
} else {
  toBlock = BigInt(process.env.TO_BLOCK);
}

let fromBlock: bigint;
if (process.env.FROM_BLOCK) {
  fromBlock = BigInt(process.env.FROM_BLOCK);
} else {
  // Derive a start block from the earliest recorded clone creation timestamp.
  // Scanning from block 0 is not viable on Base (tens of millions of blocks).
  const recorded = (deployments["PackMachines"] ?? []) as {
    createdAt?: string;
  }[];
  const timestamps = recorded
    .map((m) => (m.createdAt ? Date.parse(m.createdAt) : NaN))
    .filter((t) => Number.isFinite(t));

  if (timestamps.length === 0) {
    console.error(
      `Cannot derive a start block: no PackMachines[].createdAt in deployments/${connection.networkName}.json.`,
    );
    console.error("Set FROM_BLOCK explicitly.");
    process.exit(1);
  }

  const earliestSeconds = BigInt(Math.floor(Math.min(...timestamps) / 1000));
  const derived = await blockAtTimestamp(publicClient, earliestSeconds);
  // Small margin in case the record was written after the creation tx.
  fromBlock = derived > 5_000n ? derived - 5_000n : 0n;
}

if (fromBlock > toBlock) {
  console.error(`FROM_BLOCK (${fromBlock}) is after TO_BLOCK (${toBlock}).`);
  process.exit(1);
}

console.log("\n=== Pack Open-Rate Analysis ===");
console.log(`Network:          ${connection.networkName} (chainId ${chainId})`);
console.log(`Factory:          ${factoryAddress}`);
console.log(`PackRegistry:     ${registryAddress}`);
console.log(`BuybackPool:      ${buybackAddress}`);
console.log(`Machines:         ${machines.length}`);
for (const m of machines) console.log(`  - ${m}`);
console.log(
  `Block range:      ${fromBlock} → ${toBlock} (head ${latestBlock})`,
);

// ─── Fetch logs ──────────────────────────────────────────────────────────────

type LogBase = {
  blockNumber: bigint;
  logIndex: number;
  transactionHash: `0x${string}`;
  address: `0x${string}`;
};

async function scan<T>(
  label: string,
  address: `0x${string}` | `0x${string}`[],
  abi: readonly unknown[],
  eventName: string,
): Promise<(T & LogBase)[]> {
  const total = Number(toBlock - fromBlock + 1n);
  let lastPct = -1;

  const logs = await getLogsChunked<T & LogBase>(logClient, {
    address,
    abi,
    eventName,
    fromBlock,
    toBlock,
    onProgress: (scannedTo, _to, found) => {
      const pct = Math.floor(
        (Number(scannedTo - fromBlock + 1n) / total) * 100,
      );
      if (pct === lastPct) return;
      lastPct = pct;
      process.stdout.write(
        `\rScanning ${label}… ${String(pct).padStart(3)}% (${found} log(s))`,
      );
    },
  });

  process.stdout.write(`\rScanning ${label}… done — ${logs.length} log(s)\n`);
  return logs;
}

console.log("");

type Args<T> = { args: T };

const packOpenedLogs = await scan<
  Args<{
    user: `0x${string}`;
    requestId: bigint;
    packId: bigint;
    pricePaid: bigint;
  }>
>("PackOpened", machines, packMachineEventsAbi, "PackOpened");

const cardWonLogs = await scan<
  Args<{ user: `0x${string}`; tokenId: bigint; requestId: bigint }>
>("CardWon", machines, packMachineEventsAbi, "CardWon");

const cardFailedLogs = await scan<
  Args<{ user: `0x${string}`; tokenId: bigint; requestId: bigint }>
>("CardFailed", machines, packMachineEventsAbi, "CardFailed");

const registrationFailedLogs = await scan<
  Args<{ tokenId: bigint; requestId: bigint }>
>(
  "BuybackRegistrationFailed",
  machines,
  packMachineEventsAbi,
  "BuybackRegistrationFailed",
);

const tokenRegisteredLogs = await scan<
  Args<{
    tokenId: bigint;
    sourcePackMachine: `0x${string}`;
    tier: number;
  }>
>("TokenRegistered", buybackAddress, buybackEventsAbi, "TokenRegistered");

const weightLogs = await scan<
  Args<{ machine: `0x${string}`; packId: bigint; weights: readonly number[] }>
>(
  "PackTierWeightsUpdated",
  registryAddress,
  packRegistryEventsAbi,
  "PackTierWeightsUpdated",
);

// ─── Join: requestId → pack context ──────────────────────────────────────────

const requestKey = (machine: string, requestId: bigint) =>
  `${getAddress(machine)}:${requestId}`;

type OpenContext = {
  packId: bigint;
  user: `0x${string}`;
  pricePaid: bigint;
};

const openByRequest = new Map<string, OpenContext>();
for (const log of packOpenedLogs) {
  openByRequest.set(requestKey(log.address, log.args.requestId), {
    packId: log.args.packId,
    user: log.args.user,
    pricePaid: log.args.pricePaid,
  });
}

// ─── Join: (tx, tokenId) → tier from TokenRegistered ─────────────────────────
// Keyed by tx as well as tokenId: a token can be won, bought back, redeposited
// and won again, so tokenId alone is not unique across history.

const tierByTxToken = new Map<string, number>();
for (const log of tokenRegisteredLogs) {
  if (!machineSet.has(getAddress(log.args.sourcePackMachine))) continue;
  tierByTxToken.set(
    `${log.transactionHash}:${log.args.tokenId}`,
    Number(log.args.tier),
  );
}

const registrationFailedKeys = new Set(
  registrationFailedLogs.map((l) => `${l.transactionHash}:${l.args.tokenId}`),
);

// ─── Declared weights as of a given block ────────────────────────────────────

type WeightUpdate = {
  blockNumber: bigint;
  logIndex: number;
  weights: number[];
};

const weightHistory = new Map<string, WeightUpdate[]>();
for (const log of weightLogs) {
  const machine = getAddress(log.args.machine);
  if (!machineSet.has(machine)) continue;
  const key = `${machine}:${log.args.packId}`;
  const list = weightHistory.get(key) ?? [];
  list.push({
    blockNumber: log.blockNumber,
    logIndex: log.logIndex,
    weights: [...log.args.weights].map(Number),
  });
  weightHistory.set(key, list);
}
for (const list of weightHistory.values()) {
  list.sort((a, b) =>
    a.blockNumber === b.blockNumber
      ? a.logIndex - b.logIndex
      : a.blockNumber < b.blockNumber
        ? -1
        : 1,
  );
}

/** Current on-chain weights, used when no update precedes the draw. */
const currentWeights = new Map<string, number[] | null>();

async function getCurrentWeights(
  machine: `0x${string}`,
  packId: bigint,
): Promise<number[] | null> {
  const key = `${machine}:${packId}`;
  if (currentWeights.has(key)) return currentWeights.get(key)!;

  let weights: number[] | null = null;
  try {
    const pack = (await packRegistry.read.getPack([machine, packId])) as {
      tierWeights: readonly (number | bigint)[];
    };
    weights = [...pack.tierWeights].map(Number);
  } catch {
    weights = null; // pack removed / invalid packId
  }
  currentWeights.set(key, weights);
  return weights;
}

function weightsAtBlock(
  machine: `0x${string}`,
  packId: bigint,
  blockNumber: bigint,
): number[] | null {
  const list = weightHistory.get(`${machine}:${packId}`);
  if (!list) return null;
  let found: number[] | null = null;
  for (const update of list) {
    if (update.blockNumber <= blockNumber) found = update.weights;
    else break;
  }
  return found;
}

// ─── Build draw rows ─────────────────────────────────────────────────────────

type Row = {
  blockNumber: bigint;
  logIndex: number;
  txHash: `0x${string}`;
  machine: `0x${string}`;
  packId: bigint | null;
  requestId: bigint;
  user: `0x${string}`;
  outcome: "won" | "failed" | "failed_no_tier";
  tokenId: bigint;
  tier: number | null;
  tierSource: "event" | "buyback_read" | "machine_read" | "unknown";
  pricePaid: bigint | null;
};

const rows: Row[] = [];

function pushRow(
  log: LogBase &
    Args<{ user: `0x${string}`; tokenId: bigint; requestId: bigint }>,
  outcome: Row["outcome"],
): void {
  const machine = getAddress(log.address) as `0x${string}`;
  const ctx = openByRequest.get(requestKey(machine, log.args.requestId));
  const eventTier = tierByTxToken.get(
    `${log.transactionHash}:${log.args.tokenId}`,
  );

  rows.push({
    blockNumber: log.blockNumber,
    logIndex: log.logIndex,
    txHash: log.transactionHash,
    machine,
    packId: ctx?.packId ?? null,
    requestId: log.args.requestId,
    user: log.args.user,
    outcome,
    tokenId: log.args.tokenId,
    tier: outcome === "won" && eventTier !== undefined ? eventTier : null,
    tierSource:
      outcome === "won" && eventTier !== undefined ? "event" : "unknown",
    pricePaid: ctx?.pricePaid ?? null,
  });
}

for (const log of cardWonLogs) pushRow(log, "won");
for (const log of cardFailedLogs) {
  // tokenId 0 is the sentinel for "all eligible tiers empty" — no card was
  // ever selected, so there is no tier to resolve.
  pushRow(log, log.args.tokenId === 0n ? "failed_no_tier" : "failed");
}

rows.sort((a, b) =>
  a.blockNumber === b.blockNumber
    ? a.logIndex - b.logIndex
    : a.blockNumber < b.blockNumber
      ? -1
      : 1,
);

if (rows.length === 0) {
  console.log("\nNo CardWon / CardFailed logs in range — nothing to analyze.");
  process.exit(0);
}

// ─── Tier fallback 1: live BuybackPool.getTokenInfo ──────────────────────────

const unresolvedWon = rows.filter(
  (r) => r.tier === null && r.outcome === "won",
);

if (unresolvedWon.length > 0) {
  console.log(
    `\nResolving ${unresolvedWon.length} won card(s) without a TokenRegistered log…`,
  );

  const tokenIds = [...new Set(unresolvedWon.map((r) => r.tokenId))];
  const info = new Map<bigint, { tier: number; source: `0x${string}` }>();

  await mapWithConcurrency(tokenIds, 10, async (tokenId) => {
    try {
      const [tier, sourcePackMachine] = (await buyback.read.getTokenInfo([
        tokenId,
      ])) as [number | bigint, string, boolean];
      info.set(tokenId, {
        tier: Number(tier),
        source: getAddress(sourcePackMachine) as `0x${string}`,
      });
    } catch {
      // token never registered / pool unreachable — leave unresolved
    }
  });

  for (const row of unresolvedWon) {
    const entry = info.get(row.tokenId);
    // Only trust the read when the pool still attributes the token to the same
    // machine — otherwise it describes a later win from a different clone.
    if (entry && entry.source === row.machine) {
      row.tier = entry.tier;
      row.tierSource = "buyback_read";
    }
  }
}

// ─── Tier fallback 2: clone packTokenTier (works while token is in pool) ─────
// Covers failed draws (the token was restored to the pool) and cards that were
// bought back and redeposited.

const stillUnresolved = rows.filter(
  (r) => r.tier === null && r.outcome !== "failed_no_tier" && r.packId !== null,
);

if (stillUnresolved.length > 0) {
  console.log(
    `Resolving ${stillUnresolved.length} card(s) via clone packTokenTier…`,
  );

  type TierReader = {
    read: {
      getPackTokenTier: (args: [bigint, bigint]) => Promise<number | bigint>;
    };
  };

  const machineContracts = new Map<string, TierReader>();
  for (const m of machines) {
    machineContracts.set(
      m,
      (await viem.getContractAt("PackMachine", m)) as unknown as TierReader,
    );
  }

  const lookups = [
    ...new Set(
      stillUnresolved.map((r) => `${r.machine}:${r.tokenId}:${r.packId}`),
    ),
  ];
  const resolved = new Map<string, number>();

  await mapWithConcurrency(lookups, 10, async (key) => {
    const [machine, tokenId, packId] = key.split(":");
    const contract = machineContracts.get(machine!);
    if (!contract) return;
    try {
      const tier = await contract.read.getPackTokenTier([
        BigInt(tokenId!),
        BigInt(packId!),
      ]);
      resolved.set(key, Number(tier));
    } catch {
      // reverts with PackMachine__TokenNotInPool once the card has left custody
    }
  });

  for (const row of stillUnresolved) {
    const tier = resolved.get(`${row.machine}:${row.tokenId}:${row.packId}`);
    if (tier !== undefined) {
      row.tier = tier;
      row.tierSource = "machine_read";
    }
  }
}

// ─── Block timestamps ────────────────────────────────────────────────────────

let timestamps = new Map<bigint, bigint>();
if (process.env.SKIP_TIMESTAMPS !== "1") {
  const blocks = [...new Set(rows.map((r) => r.blockNumber))];
  console.log(`\nFetching timestamps for ${blocks.length} block(s)…`);
  // Deliberately the hardhat client, not logClient: only eth_getLogs needs the
  // wide-range node, and a public node's rate limit bites hardest here.
  timestamps = await fetchBlockTimestamps(publicClient, blocks);
}

// ─── CSV output ──────────────────────────────────────────────────────────────

const csvHeader = [
  "blockNumber",
  "blockTimestamp",
  "txHash",
  "logIndex",
  "machine",
  "packId",
  "requestId",
  "user",
  "outcome",
  "tokenId",
  "tier",
  "tierName",
  "tierSource",
  "pricePaidUsdc",
  "declaredWeightBps",
  "declaredTotalBps",
  "registrationFailed",
].join(",");

const csvLines: string[] = [csvHeader];

for (const row of rows) {
  const declared =
    row.packId === null
      ? null
      : (weightsAtBlock(row.machine, row.packId, row.blockNumber) ??
        (await getCurrentWeights(row.machine, row.packId)));

  const declaredWeight =
    declared && row.tier !== null ? (declared[row.tier] ?? "") : "";
  const declaredTotal = declared ? declared.reduce((sum, w) => sum + w, 0) : "";

  const ts = timestamps.get(row.blockNumber);

  csvLines.push(
    [
      row.blockNumber.toString(),
      ts === undefined ? "" : new Date(Number(ts) * 1000).toISOString(),
      row.txHash,
      row.logIndex.toString(),
      row.machine,
      row.packId === null ? "unknown" : row.packId.toString(),
      row.requestId.toString(),
      row.user,
      row.outcome,
      row.tokenId.toString(),
      row.tier === null ? "" : row.tier.toString(),
      row.tier === null ? "" : tierName(row.tier),
      row.tierSource,
      row.pricePaid === null ? "" : formatUnits(row.pricePaid, 6),
      declaredWeight.toString(),
      declaredTotal.toString(),
      registrationFailedKeys.has(`${row.txHash}:${row.tokenId}`) ? "1" : "0",
    ].join(","),
  );
}

const outPath =
  process.env.OUT_FILE ??
  getDeploymentPath(connection.networkName).replace(
    /[^/]+$/,
    `pack-draws.${connection.networkName}.csv`,
  );

await mkdir(dirname(outPath), { recursive: true });
const tmpPath = `${outPath}.tmp`;
await writeFile(tmpPath, csvLines.join("\n") + "\n");
await rename(tmpPath, outPath);

console.log(`\nWrote ${rows.length} draw row(s) → ${outPath}`);

// ─── Console recap ───────────────────────────────────────────────────────────

type Bucket = {
  machine: `0x${string}`;
  packId: bigint | null;
  requests: Set<string>;
  won: number;
  failed: number;
  failedNoTier: number;
  unknownTier: number;
  tierCounts: number[];
};

const buckets = new Map<string, Bucket>();

for (const row of rows) {
  const key = `${row.machine}:${row.packId ?? "unknown"}`;
  let bucket = buckets.get(key);
  if (!bucket) {
    bucket = {
      machine: row.machine,
      packId: row.packId,
      requests: new Set(),
      won: 0,
      failed: 0,
      failedNoTier: 0,
      unknownTier: 0,
      tierCounts: new Array(NUM_TIERS).fill(0),
    };
    buckets.set(key, bucket);
  }

  bucket.requests.add(row.requestId.toString());
  if (row.outcome === "won") bucket.won++;
  else if (row.outcome === "failed_no_tier") bucket.failedNoTier++;
  else bucket.failed++;

  if (row.outcome === "won") {
    if (row.tier === null || row.tier >= NUM_TIERS) bucket.unknownTier++;
    else bucket.tierCounts[row.tier]!++;
  }
}

const sortedBuckets = [...buckets.values()].sort((a, b) =>
  a.machine === b.machine
    ? Number((a.packId ?? 0n) - (b.packId ?? 0n))
    : a.machine < b.machine
      ? -1
      : 1,
);

for (const bucket of sortedBuckets) {
  console.log(
    `\n=== ${bucket.machine} — pack ${bucket.packId === null ? "unknown" : bucket.packId} ===`,
  );
  console.log(`Opens (distinct requestIds): ${bucket.requests.size}`);
  console.log(`Cards won:                   ${bucket.won}`);
  console.log(
    `Cards failed:                ${bucket.failed} (transfer failed) + ${bucket.failedNoTier} (no active tier)`,
  );
  if (bucket.unknownTier > 0) {
    console.log(`Won cards with unknown tier: ${bucket.unknownTier} ⚠️`);
  }

  const declared =
    bucket.packId === null
      ? null
      : await getCurrentWeights(bucket.machine, bucket.packId);
  const declaredTotal = declared?.reduce((sum, w) => sum + w, 0) ?? 0;

  const classified = bucket.tierCounts.reduce((sum, c) => sum + c, 0);

  // Pool sizes explain observed-vs-declared drift: an empty tier is excluded
  // from the draw and its weight is renormalized onto the remaining tiers.
  let poolSizes: bigint[] | null = null;
  if (bucket.packId !== null) {
    try {
      const machineContract = await viem.getContractAt(
        "PackMachine",
        bucket.machine,
      );
      poolSizes = (await Promise.all(
        Array.from({ length: NUM_TIERS }, (_, tier) =>
          machineContract.read.getPackTierPoolSize([bucket.packId!, tier]),
        ),
      )) as bigint[];
    } catch {
      poolSizes = null;
    }
  }

  console.log("");
  console.log("  Tier          Won   Observed %   Declared %   Pool now");
  console.log("  ----------  -----   ----------   ----------   --------");
  for (let tier = 0; tier < NUM_TIERS; tier++) {
    const count = bucket.tierCounts[tier]!;
    const observed = classified > 0 ? (count / classified) * 100 : 0;
    const declaredPct =
      declared && declaredTotal > 0
        ? (declared[tier]! / declaredTotal) * 100
        : null;
    const pool = poolSizes ? poolSizes[tier]!.toString() : "?";

    console.log(
      `  ${tierName(tier).padEnd(10)}  ${String(count).padStart(5)}   ` +
        `${observed.toFixed(4).padStart(9)}%   ` +
        `${(declaredPct === null ? "?" : declaredPct.toFixed(4)).padStart(9)}%   ` +
        `${pool.padStart(8)}${poolSizes && poolSizes[tier] === 0n ? "  ← empty" : ""}`,
    );
  }

  if (poolSizes?.some((s) => s === 0n)) {
    console.log(
      "\n  Note: empty tiers are excluded from the draw and their weight is",
    );
    console.log(
      "  renormalized onto the remaining tiers, so observed % legitimately",
    );
    console.log("  diverges from declared % for any tier that ran dry.");
  }
}

console.log("");
