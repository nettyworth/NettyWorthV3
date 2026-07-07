/**
 * check-lending-pool-config.ts
 *
 * Read-only script that prints the full configuration of the
 * AssetLendingPoolConfig contract.
 *
 * Usage
 * -----
 * # Resolve config proxy automatically from deployments JSON:
 * npx hardhat run scripts/check-lending-pool-config.ts --network base
 *
 * # Override config proxy directly:
 * CONFIG_PROXY=0x<addr> \
 *   npx hardhat run scripts/check-lending-pool-config.ts --network base
 *
 * # Override via pool proxy (script calls pool.read.getConfig()):
 * ASSET_LENDING_POOL_PROXY=0x<addr> \
 *   npx hardhat run scripts/check-lending-pool-config.ts --network base
 *
 * # Also query per-token appraisal / tier / eligibility:
 * TOKEN_IDS=1,2,3 \
 *   npx hardhat run scripts/check-lending-pool-config.ts --network base
 */

import { network } from "hardhat";
import { formatUnits, getAddress } from "viem";
import { readDeployments } from "./lib/deployments.js";

// ─── Helpers ──────────────────────────────────────────────────────────────────

function bps(value: bigint): string {
  return `${value} bps (${(Number(value) / 100).toFixed(2)}%)`;
}

function seconds(value: bigint): string {
  const days = Number(value) / 86400;
  return `${value}s (${days % 1 === 0 ? days : days.toFixed(2)} day${days === 1 ? "" : "s"})`;
}

const TIER_LABELS: Record<number, string> = {
  0: "Base",
  1: "Common",
  2: "Uncommon",
  3: "Rare",
  4: "Ultra Rare",
  5: "Grail",
};

function tierLabel(n: number): string {
  return TIER_LABELS[n] ?? `Unknown(${n})`;
}

// ─── Parse TOKEN_IDS env var ──────────────────────────────────────────────────

const rawTokenIds = process.env.TOKEN_IDS;
const tokenIds: bigint[] = rawTokenIds
  ? rawTokenIds
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => {
        const n = BigInt(s);
        if (n < 0n) {
          console.error(`Invalid TOKEN_IDS entry: "${s}"`);
          process.exit(1);
        }
        return n;
      })
  : [];

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();

// ─── Resolve config proxy address ────────────────────────────────────────────

let configProxyAddress: `0x${string}`;

if (process.env.CONFIG_PROXY) {
  configProxyAddress = getAddress(process.env.CONFIG_PROXY) as `0x${string}`;
} else if (process.env.ASSET_LENDING_POOL_PROXY) {
  const poolProxy = getAddress(
    process.env.ASSET_LENDING_POOL_PROXY,
  ) as `0x${string}`;
  const pool = await viem.getContractAt("AssetLendingPool", poolProxy);
  configProxyAddress = await pool.read.getConfig();
} else {
  const data = await readDeployments(connection.networkName);

  // Prefer the standalone AssetLendingPoolConfig entry (added alongside the
  // pool in deploy-asset-lending-pool.ts).
  const configEntry = data["AssetLendingPoolConfig"] as
    | Record<string, unknown>
    | undefined;
  if (configEntry?.proxy) {
    configProxyAddress = getAddress(configEntry.proxy as string) as `0x${string}`;
  } else {
    // Fall back: pool entry → getConfig()
    const poolEntry = data["AssetLendingPool"] as
      | Record<string, unknown>
      | undefined;
    if (!poolEntry?.proxy) {
      console.error(
        `Neither AssetLendingPoolConfig nor AssetLendingPool proxy found in deployments/${connection.networkName}.json.`,
      );
      console.error(
        "Set CONFIG_PROXY or ASSET_LENDING_POOL_PROXY to override.",
      );
      process.exit(1);
    }
    const poolProxy = getAddress(poolEntry.proxy as string) as `0x${string}`;
    const pool = await viem.getContractAt("AssetLendingPool", poolProxy);
    configProxyAddress = await pool.read.getConfig();
  }
}

// ─── Contract instance ────────────────────────────────────────────────────────

const config = await viem.getContractAt(
  "AssetLendingPoolConfig",
  configProxyAddress,
);

// ─── Fetch scalar/composite config in parallel ────────────────────────────────

const [snap, owner, factoryAddr, defaultMachine, marketplace, financeWallet] =
  await Promise.all([
    config.read.getConfigSnapshot(),
    config.read.owner(),
    config.read.packMachineFactory(),
    config.read.defaultPackMachine(),
    config.read.getMarketplace(),
    config.read.getFinanceWallet(),
  ]);

// ─── Resolve payment token decimals for human-readable amounts ────────────────

let decimals = 6; // USDC default
try {
  const token = await viem.getContractAt(
    "IERC20Metadata",
    snap.paymentToken as `0x${string}`,
  );
  decimals = await token.read.decimals();
} catch {
  // non-metadata token — fall back to 6
}

// ─── Fetch all term configs ───────────────────────────────────────────────────

const termConfigs = await Promise.all(
  Array.from({ length: snap.termCount }, (_, i) =>
    config.read.getTermConfig([i]),
  ),
);

// ─── Print header ─────────────────────────────────────────────────────────────

console.log("\n=== AssetLendingPoolConfig ===");
console.log(`Network:              ${connection.networkName} (chainId ${chainId})`);
console.log(`Config proxy:         ${configProxyAddress}`);
console.log(`Owner:                ${owner}`);

// ─── Core addresses ───────────────────────────────────────────────────────────

console.log("\n── Addresses ──────────────────────────────────");
console.log(`paymentToken:         ${snap.paymentToken}`);
console.log(`assetNFT:             ${snap.assetNFT}`);
console.log(`packMachineFactory:   ${factoryAddr}`);
console.log(
  `defaultPackMachine:   ${defaultMachine === "0x0000000000000000000000000000000000000000" ? "(not set)" : defaultMachine}`,
);
console.log(
  `marketplace:          ${marketplace === "0x0000000000000000000000000000000000000000" ? "(not set)" : marketplace}`,
);
console.log(
  `financeWallet:        ${financeWallet === "0x0000000000000000000000000000000000000000" ? "(not set)" : financeWallet}`,
);
console.log(
  `feeWallet:            ${snap.feeWallet === "0x0000000000000000000000000000000000000000" ? "(not set)" : snap.feeWallet}`,
);

// ─── Loan parameters ──────────────────────────────────────────────────────────

console.log("\n── Loan Parameters ────────────────────────────");
console.log(`ltvBps:               ${bps(snap.ltvBps)}`);
console.log(`maxUtilizationBps:    ${bps(snap.maxUtilizationBps)}`);
console.log(`originationFeeBps:    ${bps(snap.originationFeeBps)}`);

// ─── Eligibility ──────────────────────────────────────────────────────────────

console.log("\n── Eligibility ────────────────────────────────");
console.log(
  `minAppraisalValue:    ${snap.minAppraisalValue} (${formatUnits(snap.minAppraisalValue, decimals)} token units)`,
);
console.log(`minGrade:             ${snap.minGrade}`);
console.log(
  `maxAppraisalAge:      ${snap.maxAppraisalAge === 0n ? "disabled" : seconds(snap.maxAppraisalAge)}`,
);

// ─── Lender config ────────────────────────────────────────────────────────────

console.log("\n── Lender Config ──────────────────────────────");
console.log(`lenderShareBps:       ${bps(snap.lenderShareBps)}`);
console.log(`lenderDepositsEnabled:${snap.lenderDepositsEnabled ? " ✓ true" : " ✗ false"}`);

// ─── Default lifecycle ────────────────────────────────────────────────────────

console.log("\n── Default Lifecycle (defaulted loans) ────────");
console.log(`acquisitionWindow:    ${seconds(snap.acquisitionWindow)}`);
console.log(`auctionWindow:        ${seconds(snap.auctionWindow)}`);

// ─── Term configs ─────────────────────────────────────────────────────────────

console.log(`\n── Loan Terms (${snap.termCount} configured) ─────────────────────`);
for (let i = 0; i < snap.termCount; i++) {
  const term = termConfigs[i];
  console.log(
    `  [${i}] duration=${seconds(term.duration)}  apr=${bps(term.aprBps)}  active=${term.active ? "✓" : "✗"}`,
  );
}

// ─── Optional per-token detail ────────────────────────────────────────────────

if (tokenIds.length > 0) {
  console.log(`\n── Per-Token Detail (${tokenIds.length} token(s)) ──────────────`);
  for (const tokenId of tokenIds) {
    const [appraisal, tier, eligible] = await Promise.all([
      config.read.getAppraisal([tokenId]),
      config.read.defaultTokenTier([tokenId]),
      config.read.isEligible([tokenId]),
    ]);
    const age =
      appraisal.updatedAt === 0n
        ? "never appraised"
        : `${seconds(BigInt(Math.floor(Date.now() / 1000)) - appraisal.updatedAt)} ago`;
    console.log(`\n  tokenId ${tokenId}:`);
    console.log(
      `    value:      ${appraisal.value} (${formatUnits(appraisal.value, decimals)} token units)`,
    );
    console.log(`    grade:      ${appraisal.grade}`);
    console.log(`    category:   ${appraisal.category}`);
    console.log(
      `    updatedAt:  ${appraisal.updatedAt === 0n ? "—" : `block-time ${appraisal.updatedAt} (${age})`}`,
    );
    console.log(`    tier:       ${tier} (${tierLabel(Number(tier))})`);
    console.log(`    eligible:   ${eligible ? "✓ yes" : "✗ no"}`);
  }
}

console.log("\n================================\n");
