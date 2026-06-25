import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

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

// ─── TOKEN_IDS + TIERS ────────────────────────────────────────────────────────
let tokenIds: bigint[] = [];
let tiers: number[] = [];

if (!SKIP_DEPOSIT) {
  if (!process.env.TOKEN_IDS) {
    console.error(
      'TOKEN_IDS env var is required. Accepts ranges ("1-50"), comma lists ("1,2,5"), or combinations ("1-10,15,20-25"). Set SKIP_DEPOSIT=true to skip deposit.',
    );
    process.exit(1);
  }

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

  // TIERS: single value applied to all, or comma list matching tokenIds length.
  // Default: 0 (Base) for all.
  const tiersEnv = process.env.TIERS ?? "0";
  const tierParts = tiersEnv.split(",").map((t) => t.trim());

  if (tierParts.length === 1) {
    // Single tier applied to all tokens
    const t = Number(tierParts[0]);
    if (!Number.isInteger(t) || t < 0 || t > 4) {
      console.error(
        "TIERS must be an integer 0–4 (Base/Common/Uncommon/Rare/Ultra).",
      );
      process.exit(1);
    }
    tiers = Array(tokenIds.length).fill(t);
  } else {
    // Per-token tier list
    if (tierParts.length !== tokenIds.length) {
      console.error(
        `TIERS list length (${tierParts.length}) does not match TOKEN_IDS count (${tokenIds.length}).`,
      );
      process.exit(1);
    }
    tiers = tierParts.map((t, i) => {
      const n = Number(t);
      if (!Number.isInteger(n) || n < 0 || n > 4) {
        console.error(`TIERS[${i}] = "${t}" is invalid; must be 0–4.`);
        process.exit(1);
      }
      return n;
    });
  }
}

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
  if (!SKIP_DEPOSIT) {
    console.log(`Token IDs to deposit: ${tokenIds.length} tokens`);
    const tierCounts = tiers.reduce(
      (acc, t) => {
        acc[t] = (acc[t] ?? 0) + 1;
        return acc;
      },
      {} as Record<number, number>,
    );
    const tierNames = ["Base", "Common", "Uncommon", "Rare", "Ultra"];
    for (const [t, count] of Object.entries(tierCounts)) {
      console.log(`  Tier ${t} (${tierNames[Number(t)]}): ${count} tokens`);
    }
    console.log(
      `  Batches:           ${Math.ceil(tokenIds.length / 50)} × ≤50`,
    );
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

// ─── Resolve PACK_REGISTRY (only needed if configuring buyback allocation) ────
let packRegistryProxy: `0x${string}` | undefined;
if (configureBuyback) {
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
    // For non-http networks (e.g. hardhat local), resolve via factory.packRegistry()
    const factoryData = await readDeployments();
    const factoryEntry = factoryData["PackMachineFactory"] as Record<string, unknown> | undefined;
    if (factoryEntry?.packRegistry) {
      packRegistryProxy = getAddress(factoryEntry.packRegistry as string) as `0x${string}`;
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
if (!SKIP_DEPOSIT) {
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
if (configureBuyback && buybackProxy !== undefined && packRegistryProxy !== undefined) {
  console.log("\n[Buyback] Configuring buyback...");

  // setBuybackPool stays on the clone (machine-wide custody config).
  const setBuybackPoolHash = await clone.write.setBuybackPool([buybackProxy]);
  await publicClient.waitForTransactionReceipt({ hash: setBuybackPoolHash });
  console.log(`  clone.setBuybackPool(${buybackProxy}) ✓`);

  // setPackBuybackAllocation now lives on PackRegistry (pack-level config).
  const packRegistry = await viem.getContractAt("PackRegistry", packRegistryProxy);
  const setBuybackAllocHash = await packRegistry.write.setPackBuybackAllocation([
    cloneAddress,
    0,
    BUYBACK_ALLOCATION_BPS as number,
  ]);
  await publicClient.waitForTransactionReceipt({ hash: setBuybackAllocHash });
  console.log(
    `  packRegistry.setPackBuybackAllocation(${cloneAddress}, 0, ${BUYBACK_ALLOCATION_BPS}) ✓`,
  );
} else if (!configureBuyback) {
  console.log("\n[Buyback] Skipped (BUYBACK_ALLOCATION_BPS not set).");
}

// ─── Step B: Approve + deposit NFT inventory ─────────────────────────────────
if (!SKIP_DEPOSIT && assetNFTProxy !== undefined) {
  console.log(`\n[Deposit] Approving clone to pull from ${tokensOwner}...`);
  const assetNFT = await viem.getContractAt("AssetNFT", assetNFTProxy);
  const approvalHash = await assetNFT.write.setApprovalForAll([
    cloneAddress,
    true,
  ]);
  await publicClient.waitForTransactionReceipt({ hash: approvalHash });
  console.log(`  setApprovalForAll(${cloneAddress}, true) ✓`);

  // Chunk into batches of ≤50 (PackMachine.MAX_BATCH)
  const BATCH_SIZE = 50;
  const totalBatches = Math.ceil(tokenIds.length / BATCH_SIZE);
  console.log(
    `\n[Deposit] Depositing ${tokenIds.length} tokens in ${totalBatches} batch(es)...`,
  );

  for (let i = 0; i < tokenIds.length; i += BATCH_SIZE) {
    const batchIds = tokenIds.slice(i, i + BATCH_SIZE);
    const batchTiers = tiers.slice(i, i + BATCH_SIZE);
    const batchNum = Math.floor(i / BATCH_SIZE) + 1;
    console.log(
      `  Batch ${batchNum}/${totalBatches}: tokens ${batchIds[0]}–${batchIds[batchIds.length - 1]} (${batchIds.length} tokens)`,
    );
    const depositHash = await clone.write.deposit([
      batchIds,
      batchTiers,
      tokensOwner,
    ]);
    await publicClient.waitForTransactionReceipt({ hash: depositHash });
    console.log(`    ✓`);
  }
}

// ─── Summary: read back clone state ──────────────────────────────────────────
const effectivePoolSize = await clone.read.effectivePrizePoolSize();
const totalInventory = await clone.read.getTotalInventory();
const actualBuybackPool = await clone.read.getBuybackPool();
const actualBuybackBps = await clone.read.getPackBuybackAllocationBps([0n]);

console.log("\n=== PackMachine Setup Complete ===");
console.log(
  `Network:             ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Clone:               ${cloneAddress}`);
console.log(`Total Inventory:     ${totalInventory}`);
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

  const entry = idx >= 0 ? { ...machines[idx] } : { address: cloneAddress };

  if (configureBuyback) {
    entry["buybackPool"] = buybackProxy;
    entry["buybackAllocationBps"] = BUYBACK_ALLOCATION_BPS;
  }
  if (!SKIP_DEPOSIT) {
    const previous = (entry["depositedTokenIds"] as string[] | undefined) ?? [];
    entry["depositedTokenIds"] = [
      ...previous,
      ...tokenIds.map((id) => id.toString()),
    ];
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
