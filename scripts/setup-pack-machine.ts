import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ─── Tier names (Base=0 … Grail=5) ───────────────────────────────────────────
const TIER_NAMES = [
  "Base",
  "Common",
  "Uncommon",
  "Rare",
  "Ultra Rare",
  "Grail",
];
const NUM_TIERS = 6;

// ─── Parse TOKEN_IDS env (range "1-50", comma "1,2,5", or combined "1-10,15") ─
function parseTokenIds(input: string): bigint[] {
  const ids: bigint[] = [];
  for (const part of input.split(",")) {
    const trimmed = part.trim();
    const rangeMatch = trimmed.match(/^(\d+)-(\d+)$/);
    if (rangeMatch) {
      const start = BigInt(rangeMatch[1]);
      const end = BigInt(rangeMatch[2]);
      if (end < start) throw new Error(`Invalid range: ${trimmed}`);
      for (let id = start; id <= end; id++) ids.push(id);
    } else if (/^\d+$/.test(trimmed)) {
      ids.push(BigInt(trimmed));
    } else {
      throw new Error(`Invalid TOKEN_IDS segment: "${trimmed}"`);
    }
  }
  return ids;
}

// ─── Deposit input types ──────────────────────────────────────────────────────

/** One entry in the DEPOSIT_FILE JSON array. */
interface DepositEntry {
  tokenId: number;
  assignments: { packId: number; tier: number }[];
}

/** Validated deposit record ready for on-chain calls. */
interface DepositRecord {
  tokenId: bigint;
  assignments: { packId: bigint; tier: number }[];
}

// ─── FMV bounds input types ───────────────────────────────────────────────────

/** One entry in the FMV_BOUNDS_FILE JSON array. */
interface FmvBoundsEntry {
  packId: number;
  minFmv: number[]; // length 6, whole token units
  maxFmv: number[]; // length 6, whole token units
}

// ─── SKIP_DEPOSIT flag ────────────────────────────────────────────────────────
const SKIP_DEPOSIT = process.env.SKIP_DEPOSIT === "true";

// ─── BUYBACK_ALLOCATION_BPS (optional — omit to skip buyback config) ──────────
const BUYBACK_ALLOCATION_BPS =
  process.env.BUYBACK_ALLOCATION_BPS !== undefined
    ? Number(process.env.BUYBACK_ALLOCATION_BPS)
    : undefined;

if (BUYBACK_ALLOCATION_BPS !== undefined) {
  if (
    !Number.isInteger(BUYBACK_ALLOCATION_BPS) ||
    BUYBACK_ALLOCATION_BPS < 0 ||
    BUYBACK_ALLOCATION_BPS > 10000
  ) {
    console.error("BUYBACK_ALLOCATION_BPS must be an integer 0–10000.");
    process.exit(1);
  }
}
const configureBuyback = BUYBACK_ALLOCATION_BPS !== undefined;

// ─── Parse deposit input (Mode A — env vars, or Mode B — JSON file) ───────────
let depositRecords: DepositRecord[] = [];
let depositMode: "A-env" | "B-file" | "skip" = "skip";

if (!SKIP_DEPOSIT) {
  const depositFile = process.env.DEPOSIT_FILE;

  if (depositFile) {
    // ── Mode B: per-pack JSON file ──────────────────────────────────────────
    depositMode = "B-file";
    let raw: unknown;
    try {
      raw = JSON.parse(await readFile(depositFile, "utf8"));
    } catch (e: unknown) {
      console.error(
        `Failed to read DEPOSIT_FILE "${depositFile}": ${e instanceof Error ? e.message : String(e)}`,
      );
      process.exit(1);
    }
    if (!Array.isArray(raw) || raw.length === 0) {
      console.error(`DEPOSIT_FILE must be a non-empty JSON array.`);
      process.exit(1);
    }
    for (let i = 0; i < raw.length; i++) {
      const entry = raw[i] as DepositEntry;
      if (
        typeof entry.tokenId !== "number" ||
        !Number.isInteger(entry.tokenId) ||
        entry.tokenId < 0
      ) {
        console.error(
          `DEPOSIT_FILE[${i}].tokenId must be a non-negative integer.`,
        );
        process.exit(1);
      }
      if (!Array.isArray(entry.assignments) || entry.assignments.length === 0) {
        console.error(
          `DEPOSIT_FILE[${i}].assignments must be a non-empty array.`,
        );
        process.exit(1);
      }
      const seenPacks = new Set<number>();
      for (let j = 0; j < entry.assignments.length; j++) {
        const a = entry.assignments[j];
        if (
          typeof a.packId !== "number" ||
          !Number.isInteger(a.packId) ||
          a.packId < 0
        ) {
          console.error(
            `DEPOSIT_FILE[${i}].assignments[${j}].packId must be a non-negative integer.`,
          );
          process.exit(1);
        }
        if (
          typeof a.tier !== "number" ||
          !Number.isInteger(a.tier) ||
          a.tier < 0 ||
          a.tier >= NUM_TIERS
        ) {
          console.error(
            `DEPOSIT_FILE[${i}].assignments[${j}].tier must be an integer 0–${NUM_TIERS - 1} (${TIER_NAMES.join("/")}).`,
          );
          process.exit(1);
        }
        if (seenPacks.has(a.packId)) {
          console.error(
            `DEPOSIT_FILE[${i}] has duplicate packId ${a.packId} for tokenId ${entry.tokenId}.`,
          );
          process.exit(1);
        }
        seenPacks.add(a.packId);
      }
      depositRecords.push({
        tokenId: BigInt(entry.tokenId),
        assignments: entry.assignments.map((a) => ({
          packId: BigInt(a.packId),
          tier: a.tier,
        })),
      });
    }
  } else {
    // ── Mode A: TOKEN_IDS + TIERS + optional PACK_ID env vars ──────────────
    depositMode = "A-env";
    if (!process.env.TOKEN_IDS) {
      console.error(
        "TOKEN_IDS env var is required when not using DEPOSIT_FILE.\n" +
          'Accepts ranges ("1-50"), comma lists ("1,2,3"), or combinations ("1-10,15,20-25").\n' +
          "Set SKIP_DEPOSIT=true to skip deposit entirely.",
      );
      process.exit(1);
    }

    let tokenIds: bigint[];
    try {
      tokenIds = parseTokenIds(process.env.TOKEN_IDS);
    } catch (e: unknown) {
      console.error(
        `Invalid TOKEN_IDS: ${e instanceof Error ? e.message : String(e)}`,
      );
      process.exit(1);
    }
    if (tokenIds.length === 0) {
      console.error("TOKEN_IDS resolved to an empty list.");
      process.exit(1);
    }

    const packId =
      process.env.PACK_ID !== undefined ? Number(process.env.PACK_ID) : 0;
    if (!Number.isInteger(packId) || packId < 0) {
      console.error("PACK_ID must be a non-negative integer (default 0).");
      process.exit(1);
    }

    // TIERS: single value applied to all, or comma list matching tokenIds length.
    const tiersEnv = process.env.TIERS ?? "0";
    const tierParts = tiersEnv.split(",").map((t) => t.trim());
    let tiers: number[];

    if (tierParts.length === 1) {
      const t = Number(tierParts[0]);
      if (!Number.isInteger(t) || t < 0 || t >= NUM_TIERS) {
        console.error(
          `TIERS must be an integer 0–${NUM_TIERS - 1} (${TIER_NAMES.join("/")}).`,
        );
        process.exit(1);
      }
      tiers = Array(tokenIds.length).fill(t);
    } else {
      if (tierParts.length !== tokenIds.length) {
        console.error(
          `TIERS list length (${tierParts.length}) does not match TOKEN_IDS count (${tokenIds.length}).`,
        );
        process.exit(1);
      }
      tiers = tierParts.map((t, i) => {
        const n = Number(t);
        if (!Number.isInteger(n) || n < 0 || n >= NUM_TIERS) {
          console.error(
            `TIERS[${i}] = "${t}" is invalid; must be 0–${NUM_TIERS - 1}.`,
          );
          process.exit(1);
        }
        return n;
      });
    }

    depositRecords = tokenIds.map((id, i) => ({
      tokenId: id,
      assignments: [{ packId: BigInt(packId), tier: tiers[i] }],
    }));
  }
}

// ─── Parse FMV_BOUNDS_FILE (optional) ─────────────────────────────────────────
let fmvBoundsEntries: FmvBoundsEntry[] = [];
const fmvBoundsFile = process.env.FMV_BOUNDS_FILE;
if (fmvBoundsFile) {
  let raw: unknown;
  try {
    raw = JSON.parse(await readFile(fmvBoundsFile, "utf8"));
  } catch (e: unknown) {
    console.error(
      `Failed to read FMV_BOUNDS_FILE "${fmvBoundsFile}": ${e instanceof Error ? e.message : String(e)}`,
    );
    process.exit(1);
  }
  if (!Array.isArray(raw) || raw.length === 0) {
    console.error("FMV_BOUNDS_FILE must be a non-empty JSON array.");
    process.exit(1);
  }
  for (let i = 0; i < raw.length; i++) {
    const entry = raw[i] as FmvBoundsEntry;
    if (
      typeof entry.packId !== "number" ||
      !Number.isInteger(entry.packId) ||
      entry.packId < 0
    ) {
      console.error(
        `FMV_BOUNDS_FILE[${i}].packId must be a non-negative integer.`,
      );
      process.exit(1);
    }
    if (!Array.isArray(entry.minFmv) || entry.minFmv.length !== NUM_TIERS) {
      console.error(
        `FMV_BOUNDS_FILE[${i}].minFmv must be an array of ${NUM_TIERS} numbers.`,
      );
      process.exit(1);
    }
    if (!Array.isArray(entry.maxFmv) || entry.maxFmv.length !== NUM_TIERS) {
      console.error(
        `FMV_BOUNDS_FILE[${i}].maxFmv must be an array of ${NUM_TIERS} numbers.`,
      );
      process.exit(1);
    }
    fmvBoundsEntries.push(entry);
  }
}
const configureFmvBounds = fmvBoundsEntries.length > 0;

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirm(
  networkName: string,
  chainId: number,
  deployer: string,
  cloneAddress: string,
  tokensOwner: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== PackMachine Setup Summary ===");
  console.log(`Network:             ${networkName}`);
  console.log(`Chain ID:            ${chainId}`);
  console.log(`Deployer:            ${deployer}`);
  console.log(`Clone:               ${cloneAddress}`);
  console.log(`Tokens Owner:        ${tokensOwner}`);
  if (configureBuyback) {
    console.log(`Buyback Allocation:  ${BUYBACK_ALLOCATION_BPS} bps`);
  } else {
    console.log(
      `Buyback Config:      skipped (BUYBACK_ALLOCATION_BPS not set)`,
    );
  }
  if (configureFmvBounds) {
    console.log(
      `FMV Bounds:          ${fmvBoundsEntries.length} pack(s) to configure`,
    );
  } else {
    console.log(`FMV Bounds:          skipped (FMV_BOUNDS_FILE not set)`);
  }
  if (!SKIP_DEPOSIT && depositRecords.length > 0) {
    const totalTokens = depositRecords.length;
    const totalAssignments = depositRecords.reduce(
      (s, r) => s + r.assignments.length,
      0,
    );
    const uniquePacks = new Set(
      depositRecords.flatMap((r) =>
        r.assignments.map((a) => a.packId.toString()),
      ),
    );
    console.log(
      `Deposit mode:        ${depositMode === "B-file" ? "JSON file (DEPOSIT_FILE)" : "env vars (TOKEN_IDS/TIERS/PACK_ID)"}`,
    );
    console.log(`Tokens to deposit:   ${totalTokens}`);
    console.log(
      `Total assignments:   ${totalAssignments} (across ${uniquePacks.size} unique pack(s))`,
    );
    console.log(
      `Batches:             ${Math.ceil(totalTokens / 50)} × ≤50 tokens`,
    );
    // Tier summary across all assignments
    const tierCounts: Record<number, number> = {};
    for (const r of depositRecords) {
      for (const a of r.assignments) {
        tierCounts[a.tier] = (tierCounts[a.tier] ?? 0) + 1;
      }
    }
    for (const [t, count] of Object.entries(tierCounts)) {
      console.log(
        `  Tier ${t} (${TIER_NAMES[Number(t)]}): ${count} assignment(s)`,
      );
    }
  } else {
    console.log(`Deposit:             skipped (SKIP_DEPOSIT=true)`);
  }
  console.log("==================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  return answer.toLowerCase() === "yes";
}

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [deployerClient] = await viem.getWalletClients();
const deployerAddress = deployerClient.account.address;
const chainId = await publicClient.getChainId();

// ─── Deployments JSON helpers ─────────────────────────────────────────────────
const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../deployments",
);
const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);

async function readDeployments(): Promise<Record<string, unknown>> {
  try {
    return JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    return {};
  }
}

// ─── Resolve PACK_MACHINE clone address ──────────────────────────────────────
let cloneAddress: `0x${string}`;
if (process.env.PACK_MACHINE) {
  cloneAddress = getAddress(process.env.PACK_MACHINE) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
  const data = await readDeployments();
  const machines = data["PackMachines"] as unknown[] | undefined;
  if (!machines || machines.length === 0) {
    console.error(
      "No PackMachines found in deployments JSON. Set PACK_MACHINE env var or run create-pack-machine first.",
    );
    process.exit(1);
  }
  const last = machines[machines.length - 1] as Record<string, unknown>;
  if (!last.address) {
    console.error(
      "Last PackMachine entry has no address. Set PACK_MACHINE env var explicitly.",
    );
    process.exit(1);
  }
  cloneAddress = getAddress(last.address as string) as `0x${string}`;
  console.log(`ℹ️  Using last PackMachine from deployments: ${cloneAddress}`);
} else {
  console.error("Set PACK_MACHINE env var to the PackMachine clone address.");
  process.exit(1);
}

// ─── Resolve BUYBACK_POOL (only needed if configuring buyback) ────────────────
let buybackProxy: `0x${string}` | undefined;
if (configureBuyback) {
  if (process.env.BUYBACK_POOL) {
    buybackProxy = getAddress(process.env.BUYBACK_POOL) as `0x${string}`;
  } else if (connection.networkConfig.type === "http") {
    const data = await readDeployments();
    const entry = data["BuybackPool"] as Record<string, unknown> | undefined;
    if (!entry?.proxy) {
      console.error(
        "BuybackPool proxy not found. Set BUYBACK_POOL env var or run deploy-pack-machine first.",
      );
      process.exit(1);
    }
    buybackProxy = getAddress(entry.proxy as string) as `0x${string}`;
  } else {
    console.error(
      "Set BUYBACK_POOL env var to the deployed BuybackPool proxy address.",
    );
    process.exit(1);
  }
}

// ─── Resolve PACK_REGISTRY (needed for buyback allocation or FMV bounds) ──────
let packRegistryProxy: `0x${string}` | undefined;
if (configureBuyback || configureFmvBounds) {
  if (process.env.PACK_REGISTRY) {
    packRegistryProxy = getAddress(process.env.PACK_REGISTRY) as `0x${string}`;
  } else if (connection.networkConfig.type === "http") {
    const data = await readDeployments();
    const entry = data["PackRegistry"] as Record<string, unknown> | undefined;
    if (!entry?.proxy) {
      console.error(
        "PackRegistry proxy not found. Set PACK_REGISTRY env var or run deploy-pack-machine first.",
      );
      process.exit(1);
    }
    packRegistryProxy = getAddress(entry.proxy as string) as `0x${string}`;
  } else {
    const factoryData = await readDeployments();
    const factoryEntry = factoryData["PackMachineFactory"] as
      | Record<string, unknown>
      | undefined;
    if (factoryEntry?.packRegistry) {
      packRegistryProxy = getAddress(
        factoryEntry.packRegistry as string,
      ) as `0x${string}`;
    } else {
      console.error(
        "Set PACK_REGISTRY env var to the deployed PackRegistry proxy address.",
      );
      process.exit(1);
    }
  }
}

// ─── Resolve ASSET_NFT_PROXY (only needed for deposit) ───────────────────────
let assetNFTProxy: `0x${string}` | undefined;
if (!SKIP_DEPOSIT && depositRecords.length > 0) {
  if (process.env.ASSET_NFT_PROXY) {
    assetNFTProxy = getAddress(process.env.ASSET_NFT_PROXY) as `0x${string}`;
  } else if (connection.networkConfig.type === "http") {
    const data = await readDeployments();
    const entry = data["AssetNFT"] as Record<string, unknown> | undefined;
    if (!entry?.proxy) {
      console.error(
        "AssetNFT proxy not found. Set ASSET_NFT_PROXY env var or deploy AssetNFT first.",
      );
      process.exit(1);
    }
    assetNFTProxy = getAddress(entry.proxy as string) as `0x${string}`;
  } else {
    console.error(
      "Set ASSET_NFT_PROXY env var to the deployed AssetNFT proxy address.",
    );
    process.exit(1);
  }
}

// ─── Resolve TOKENS_OWNER (defaults to deployer) ─────────────────────────────
const tokensOwner: `0x${string}` = process.env.TOKENS_OWNER
  ? (getAddress(process.env.TOKENS_OWNER) as `0x${string}`)
  : deployerAddress;

// ─── Confirmation on live networks ────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirm(
    connection.networkName,
    chainId,
    deployerAddress,
    cloneAddress,
    tokensOwner,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

const clone = await viem.getContractAt("PackMachine", cloneAddress);

// ─── Step A: Configure buyback (optional) ────────────────────────────────────
if (
  configureBuyback &&
  buybackProxy !== undefined &&
  packRegistryProxy !== undefined
) {
  console.log("\n[Buyback] Configuring buyback...");

  // setBuybackPool stays on the clone (machine-wide custody config).
  const setBuybackPoolHash = await clone.write.setBuybackPool([buybackProxy]);
  await publicClient.waitForTransactionReceipt({ hash: setBuybackPoolHash });
  console.log(`  clone.setBuybackPool(${buybackProxy}) ✓`);

  // setPackBuybackAllocation now lives on PackRegistry (pack-level config).
  const packRegistry = await viem.getContractAt(
    "PackRegistry",
    packRegistryProxy,
  );
  const setBuybackAllocHash = await packRegistry.write.setPackBuybackAllocation(
    [cloneAddress, 0n, BUYBACK_ALLOCATION_BPS as number],
  );
  await publicClient.waitForTransactionReceipt({ hash: setBuybackAllocHash });
  console.log(
    `  packRegistry.setPackBuybackAllocation(${cloneAddress}, 0, ${BUYBACK_ALLOCATION_BPS}) ✓`,
  );
} else if (!configureBuyback) {
  console.log("\n[Buyback] Skipped (BUYBACK_ALLOCATION_BPS not set).");
}

// ─── Step B: Set per-(pack, tier) FMV bounds (optional prerequisite for deposit)
if (configureFmvBounds && packRegistryProxy !== undefined) {
  console.log(
    `\n[FMV Bounds] Setting tier FMV bounds for ${fmvBoundsEntries.length} pack(s)...`,
  );

  // Resolve payment token decimals for scaling (whole token units → base units).
  const packRegistryForFmv = await viem.getContractAt(
    "PackRegistry",
    packRegistryProxy,
  );
  // Read decimals from the payment token (via clone → factory → paymentToken).
  const factoryAddress = await clone.read
    .getMachineInfo()
    .then((info) => info.factory);
  const factoryContract = await viem.getContractAt(
    "PackMachineFactory",
    factoryAddress,
  );
  const paymentTokenAddress =
    (await factoryContract.read.paymentToken()) as `0x${string}`;
  const erc20DecimalsAbi = [
    {
      name: "decimals",
      type: "function",
      stateMutability: "view",
      inputs: [],
      outputs: [{ name: "", type: "uint8" }],
    },
  ] as const;
  const decimals = await publicClient.readContract({
    address: paymentTokenAddress,
    abi: erc20DecimalsAbi,
    functionName: "decimals",
  });
  const scale = 10n ** BigInt(decimals);

  for (const entry of fmvBoundsEntries) {
    const minFmv = entry.minFmv.map((v) => BigInt(Math.round(v)) * scale) as [
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
    ];
    const maxFmv = entry.maxFmv.map((v) => BigInt(Math.round(v)) * scale) as [
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
      bigint,
    ];
    const hash = await packRegistryForFmv.write.setPackTierFmvBounds([
      cloneAddress,
      BigInt(entry.packId),
      minFmv,
      maxFmv,
    ]);
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(
      `  setPackTierFmvBounds(clone, packId=${entry.packId}, min=[${entry.minFmv.join(",")}], max=[${entry.maxFmv.join(",")}]) ✓`,
    );
  }
} else if (!configureFmvBounds && !SKIP_DEPOSIT && depositRecords.length > 0) {
  console.log(
    "\n⚠️  FMV_BOUNDS_FILE not set. Deposits will revert with PackMachine__TierFmvUnset unless" +
      " packRegistry.setPackTierFmvBounds has already been called for each (pack, tier) used.",
  );
}

// ─── Step C: Approve + deposit NFT inventory ──────────────────────────────────
if (!SKIP_DEPOSIT && depositRecords.length > 0 && assetNFTProxy !== undefined) {
  console.log(`\n[Deposit] Approving clone to pull from ${tokensOwner}...`);
  const assetNFT = await viem.getContractAt("AssetNFT", assetNFTProxy);
  const approvalHash = await assetNFT.write.setApprovalForAll([
    cloneAddress,
    true,
  ]);
  await publicClient.waitForTransactionReceipt({ hash: approvalHash });
  console.log(`  setApprovalForAll(${cloneAddress}, true) ✓`);

  // Chunk into batches of ≤50 tokens (PackMachine.MAX_BATCH).
  const BATCH_SIZE = 50;
  const totalBatches = Math.ceil(depositRecords.length / BATCH_SIZE);
  console.log(
    `\n[Deposit] Depositing ${depositRecords.length} token(s) in ${totalBatches} batch(es)...`,
  );

  for (let i = 0; i < depositRecords.length; i += BATCH_SIZE) {
    const batchRecords = depositRecords.slice(i, i + BATCH_SIZE);
    const batchNum = Math.floor(i / BATCH_SIZE) + 1;

    // Build flat-encoding arrays for this batch.
    const batchTokenIds: bigint[] = [];
    const batchPackCounts: bigint[] = [];
    const batchPackIds: bigint[] = [];
    const batchTiers: number[] = [];

    for (const rec of batchRecords) {
      batchTokenIds.push(rec.tokenId);
      batchPackCounts.push(BigInt(rec.assignments.length));
      for (const a of rec.assignments) {
        batchPackIds.push(a.packId);
        batchTiers.push(a.tier);
      }
    }

    const firstId = batchRecords[0].tokenId;
    const lastId = batchRecords[batchRecords.length - 1].tokenId;
    const totalAssignments = batchPackIds.length;
    console.log(
      `  Batch ${batchNum}/${totalBatches}: tokens ${firstId}–${lastId}` +
        ` (${batchRecords.length} tokens, ${totalAssignments} pack-tier assignments)`,
    );
    const depositHash = await clone.write.deposit([
      batchTokenIds,
      batchPackCounts,
      batchPackIds,
      batchTiers,
      tokensOwner,
    ]);
    await publicClient.waitForTransactionReceipt({ hash: depositHash });
    console.log(`    ✓`);
  }
}

// ─── Summary: read back clone state ──────────────────────────────────────────
const machineInfo = await clone.read.getMachineInfo();
const effectivePoolSize = machineInfo.effectivePrizePoolSize;
const actualBuybackPool = machineInfo.buybackPool;
const actualBuybackBps = (await clone.read.getPack([0n])).buybackAllocationBps;

console.log("\n=== PackMachine Setup Complete ===");
console.log(
  `Network:             ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Clone:               ${cloneAddress}`);
console.log(`Effective Pool Size: ${effectivePoolSize}`);
console.log(
  `Buyback Pool:        ${actualBuybackPool === "0x0000000000000000000000000000000000000000" ? "(not set)" : actualBuybackPool}`,
);
console.log(
  `Buyback Allocation:  ${actualBuybackBps} bps${actualBuybackBps === 0 ? " (disabled)" : ""}`,
);
console.log("==================================\n");

// ─── Persist to deployments/<network>.json (live networks only) ───────────────
if (connection.networkConfig.type === "http") {
  const outPath = join(deploymentsDir, `${connection.networkName}.json`);

  let existing: Record<string, unknown> = {};
  try {
    existing = JSON.parse(await readFile(outPath, "utf8"));
  } catch {
    // file doesn't exist yet — start fresh
  }

  // Update matching PackMachines[] entry (match by address), or append if not found.
  const machines =
    (existing["PackMachines"] as Record<string, unknown>[] | undefined) ?? [];
  const idx = machines.findIndex(
    (m) => (m.address as string)?.toLowerCase() === cloneAddress.toLowerCase(),
  );

  const entry: Record<string, unknown> =
    idx >= 0 ? { ...machines[idx] } : { address: cloneAddress };

  if (configureBuyback) {
    entry["buybackPool"] = buybackProxy;
    entry["buybackAllocationBps"] = BUYBACK_ALLOCATION_BPS;
  }
  if (configureFmvBounds) {
    entry["fmvBoundsConfiguredAt"] = new Date().toISOString();
  }
  if (!SKIP_DEPOSIT && depositRecords.length > 0) {
    const previous = (entry["depositedTokenIds"] as string[] | undefined) ?? [];
    entry["depositedTokenIds"] = [
      ...previous,
      ...depositRecords.map((r) => r.tokenId.toString()),
    ];
    // Record which packs each token was assigned to (summary).
    const packsSummary: Record<string, number[]> = {};
    for (const r of depositRecords) {
      packsSummary[r.tokenId.toString()] = r.assignments.map((a) =>
        Number(a.packId),
      );
    }
    entry["depositedPackAssignments"] = {
      ...((entry["depositedPackAssignments"] as
        | Record<string, number[]>
        | undefined) ?? {}),
      ...packsSummary,
    };
  }
  entry["configuredAt"] = new Date().toISOString();

  if (idx >= 0) {
    machines[idx] = entry;
  } else {
    machines.push(entry);
  }
  existing["PackMachines"] = machines;

  await mkdir(deploymentsDir, { recursive: true });
  await writeFile(outPath, JSON.stringify(existing, null, 2) + "\n");
  console.log(
    `Deployment info saved to deployments/${connection.networkName}.json`,
  );
}
