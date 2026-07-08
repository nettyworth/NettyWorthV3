/**
 * set-lifecycle-config.ts
 *
 * Set (or update) the defaulted-loan lifecycle windows on AssetLendingPoolConfig.
 * Phase 1 (acquisition): owner can recycle the collateral into a PackMachine.
 * Phase 2 (auction): public can buy at outstanding loan value.
 * After both windows expire the loan moves to a perpetual fixed listing.
 *
 * Usage
 * -----
 * # Set acquisition = 1 day, auction = 7 days on Base:
 * ACQUISITION_WINDOW=86400 AUCTION_WINDOW=604800 \
 *   npx hardhat run scripts/set-lifecycle-config.ts --network base
 *
 * # Override the config proxy directly instead of reading from deployments JSON:
 * ACQUISITION_WINDOW=86400 AUCTION_WINDOW=604800 CONFIG_PROXY=0x<addr> \
 *   npx hardhat run scripts/set-lifecycle-config.ts --network base
 *
 * # Or override the pool proxy (config resolved via on-chain getConfig()):
 * ACQUISITION_WINDOW=86400 AUCTION_WINDOW=604800 ASSET_LENDING_POOL_PROXY=0x<addr> \
 *   npx hardhat run scripts/set-lifecycle-config.ts --network base
 *
 * Environment variables
 * ---------------------
 * ACQUISITION_WINDOW        (required) Phase-1 duration in seconds
 * AUCTION_WINDOW            (required) Phase-2 duration in seconds
 * ASSET_LENDING_POOL_PROXY  override pool proxy (optional)
 * CONFIG_PROXY              override config proxy directly (optional; takes precedence)
 */

import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments, saveDeployment } from "./lib/deployments.js";

// ─── Parse ACQUISITION_WINDOW ─────────────────────────────────────────────────

const rawAcq = process.env.ACQUISITION_WINDOW;
if (!rawAcq) {
  console.error("Missing required env variable ACQUISITION_WINDOW.");
  console.error(
    "Usage: ACQUISITION_WINDOW=<seconds> AUCTION_WINDOW=<seconds> npx hardhat run scripts/set-lifecycle-config.ts --network <net>",
  );
  process.exit(1);
}
const acqNum = Number(rawAcq);
if (!Number.isInteger(acqNum) || acqNum <= 0) {
  console.error(
    `Invalid ACQUISITION_WINDOW: "${rawAcq}". Must be a positive integer (seconds).`,
  );
  process.exit(1);
}
const newAcqWindow = BigInt(acqNum);

// ─── Parse AUCTION_WINDOW ─────────────────────────────────────────────────────

const rawAuction = process.env.AUCTION_WINDOW;
if (!rawAuction) {
  console.error("Missing required env variable AUCTION_WINDOW.");
  console.error(
    "Usage: ACQUISITION_WINDOW=<seconds> AUCTION_WINDOW=<seconds> npx hardhat run scripts/set-lifecycle-config.ts --network <net>",
  );
  process.exit(1);
}
const auctionNum = Number(rawAuction);
if (!Number.isInteger(auctionNum) || auctionNum <= 0) {
  console.error(
    `Invalid AUCTION_WINDOW: "${rawAuction}". Must be a positive integer (seconds).`,
  );
  process.exit(1);
}
const newAuctionWindow = BigInt(auctionNum);

// ─── Helpers ──────────────────────────────────────────────────────────────────

function seconds(value: bigint): string {
  const n = Number(value);
  if (n === 0) return "0s (not configured)";
  if (n < 3600) return `${n}s`;
  const days = n / 86400;
  return `${n}s (${days % 1 === 0 ? days : days.toFixed(2)} day${days === 1 ? "" : "s"})`;
}

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [callerClient] = await viem.getWalletClients();
const callerAddress = callerClient.account.address;
const chainId = await publicClient.getChainId();

// ─── Resolve config proxy address ────────────────────────────────────────────

let configProxyAddress: `0x${string}`;

if (process.env.CONFIG_PROXY) {
  // Direct config proxy override
  configProxyAddress = getAddress(process.env.CONFIG_PROXY) as `0x${string}`;
} else {
  // Reach the config proxy via the pool proxy
  let poolProxy: `0x${string}`;

  if (process.env.ASSET_LENDING_POOL_PROXY) {
    poolProxy = getAddress(
      process.env.ASSET_LENDING_POOL_PROXY,
    ) as `0x${string}`;
  } else {
    const deploymentData = await readDeployments(connection.networkName);
    const entry = deploymentData["AssetLendingPool"] as
      | Record<string, unknown>
      | undefined;
    if (!entry?.proxy) {
      console.error(
        `AssetLendingPool proxy address not found in deployments/${connection.networkName}.json.`,
      );
      console.error(
        "Deploy first using deploy-asset-lending-pool.ts, or set ASSET_LENDING_POOL_PROXY / CONFIG_PROXY to override.",
      );
      process.exit(1);
    }
    poolProxy = getAddress(entry.proxy as string) as `0x${string}`;
  }

  const pool = await viem.getContractAt("AssetLendingPool", poolProxy);
  configProxyAddress = await pool.read.getConfig();
}

// ─── Contract instance ────────────────────────────────────────────────────────

const config = await viem.getContractAt(
  "AssetLendingPoolConfig",
  configProxyAddress,
);

// ─── Verify caller is owner ───────────────────────────────────────────────────

const owner = await config.read.owner();
if (owner.toLowerCase() !== callerAddress.toLowerCase()) {
  console.error(
    `Account ${callerAddress} is not the owner of config proxy ${configProxyAddress} (owner: ${owner}).`,
  );
  console.error(
    "setDefaultLifecycleConfig is onlyOwner — transaction would revert.",
  );
  process.exit(1);
}

// ─── Read current lifecycle windows ──────────────────────────────────────────

const [currentAcq, currentAuction] = await Promise.all([
  config.read.acquisitionWindow(),
  config.read.auctionWindow(),
]);

console.log(`\nConfig proxy:       ${configProxyAddress}`);
console.log(`Owner:              ${owner}`);
console.log(`\nCurrent acquisitionWindow: ${seconds(currentAcq)}`);
console.log(`Current auctionWindow:     ${seconds(currentAuction)}`);

// ─── No-op check ─────────────────────────────────────────────────────────────

if (currentAcq === newAcqWindow && currentAuction === newAuctionWindow) {
  console.log(
    `\nLifecycle config is already set to acquisitionWindow=${newAcqWindow}s, auctionWindow=${newAuctionWindow}s. Nothing to do.`,
  );
  process.exit(0);
}

// ─── Confirmation on live networks ────────────────────────────────────────────

if (connection.networkConfig.type === "http") {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setDefaultLifecycleConfig Summary ===");
  console.log(`Network:            ${connection.networkName}`);
  console.log(`Chain ID:           ${chainId}`);
  console.log(`Caller:             ${callerAddress}`);
  console.log(`Config proxy:       ${configProxyAddress}`);
  console.log(`\nOld acquisitionWindow: ${seconds(currentAcq)}`);
  console.log(`New acquisitionWindow: ${seconds(newAcqWindow)}`);
  console.log(`\nOld auctionWindow:     ${seconds(currentAuction)}`);
  console.log(`New auctionWindow:     ${seconds(newAuctionWindow)}`);
  console.log("=========================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  if (answer.toLowerCase() !== "yes") {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────

console.log(
  `\n[1/2] Calling setDefaultLifecycleConfig(acquisitionWindow=${newAcqWindow}, auctionWindow=${newAuctionWindow})…`,
);
const txHash = await config.write.setDefaultLifecycleConfig(
  [newAcqWindow, newAuctionWindow],
  { account: callerClient.account },
);
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  tx: ${txHash} (block ${receipt.blockNumber})`);

if (receipt.status !== "success") {
  console.error(`Transaction reverted! Hash: ${txHash}`);
  process.exit(1);
}

// ─── Verify ───────────────────────────────────────────────────────────────────

console.log("[2/2] Verifying…");
const [acqAfter, auctionAfter] = await Promise.all([
  config.read.acquisitionWindow(),
  config.read.auctionWindow(),
]);

if (acqAfter !== newAcqWindow || auctionAfter !== newAuctionWindow) {
  console.error(
    `CRITICAL: State mismatch after update! Expected acquisitionWindow=${newAcqWindow} auctionWindow=${newAuctionWindow}, got acquisitionWindow=${acqAfter} auctionWindow=${auctionAfter}`,
  );
  process.exit(1);
}
console.log(`  acquisitionWindow confirmed: ${seconds(acqAfter)} ✓`);
console.log(`  auctionWindow     confirmed: ${seconds(auctionAfter)} ✓`);

// ─── Summary ──────────────────────────────────────────────────────────────────

console.log("\n=== setDefaultLifecycleConfig Complete ===");
console.log(`Network:      ${connection.networkName} (chainId: ${chainId})`);
console.log(`Config proxy: ${configProxyAddress}`);
console.log(
  `Old acquisitionWindow: ${seconds(currentAcq)} → ${seconds(acqAfter)}`,
);
console.log(
  `Old auctionWindow:     ${seconds(currentAuction)} → ${seconds(auctionAfter)}`,
);
console.log(`Tx:           ${txHash}`);
console.log("==========================================\n");

// ─── Persist to deployments/<network>.json (live networks only) ───────────────

if (connection.networkConfig.type === "http") {
  try {
    const deploymentData = await readDeployments(connection.networkName);
    const configEntry =
      (deploymentData["AssetLendingPoolConfig"] as Record<string, unknown>) ??
      {};

    await saveDeployment(connection.networkName, "AssetLendingPoolConfig", {
      ...configEntry,
      proxy: configProxyAddress,
      acquisitionWindow: acqNum,
      auctionWindow: auctionNum,
      lifecycleConfigUpdatedAt: new Date().toISOString(),
    });
    console.log(
      `Deployment info updated at deployments/${connection.networkName}.json`,
    );
  } catch (err) {
    // Non-fatal — the on-chain state is already confirmed; just warn.
    console.warn(`Warning: could not persist to deployments JSON: ${err}`);
  }
}
