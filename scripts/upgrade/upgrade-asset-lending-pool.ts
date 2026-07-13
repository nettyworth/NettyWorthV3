/**
 * upgrade-asset-lending-pool.ts
 *
 * Deploys a fresh LendingLib + a new AssetLendingPool implementation linked to
 * it, then upgrades the existing ERC-1967 / UUPS proxy to point at the new
 * implementation.  Requires the caller to be the pool **owner**
 * (Ownable2StepUpgradeable — NOT UPGRADER_ROLE).
 *
 * Primary purpose: obtain a durably-recorded lendingLib address in the
 * deployments JSON so verify-tenderly.ts can verify the linked implementation.
 *
 * Usage
 * -----
 * # Dry-run on a local fork (no prompt, no JSON write):
 * ASSET_LENDING_POOL_PROXY=0x<addr> \
 *   npx hardhat run scripts/upgrade/upgrade-asset-lending-pool.ts --network forkBase
 *
 * # Live upgrade (interactive confirmation, writes to deployments/<network>.json):
 * npx hardhat run scripts/upgrade/upgrade-asset-lending-pool.ts --network base
 *
 * Optional env vars:
 *   ASSET_LENDING_POOL_PROXY    — override proxy address (bypass deployments JSON)
 *   UPGRADE_REINITIALIZER_DATA  — raw calldata forwarded to upgradeToAndCall
 *                                 (default "0x" = plain implementation swap)
 */

import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { sleep } from "../lib/sleep.js";

// Optional raw reinitializer calldata for future reinitializers
const REINITIALIZER_DATA = (process.env.UPGRADE_REINITIALIZER_DATA ??
  "0x") as `0x${string}`;

// ERC-1967 implementation storage slot
const ERC1967_IMPL_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc" as const;

async function confirmUpgrade(
  networkName: string,
  chainId: number,
  upgrader: string,
  proxy: string,
  oldImpl: string,
  newLendingLib: string,
  newImpl: string,
  callData: `0x${string}`,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== Upgrade Summary ===");
  console.log(`Network:          ${networkName}`);
  console.log(`Chain ID:         ${chainId}`);
  console.log(`Owner (upgrader): ${upgrader}`);
  console.log(`Proxy:            ${proxy}`);
  console.log(`Current Impl:     ${oldImpl}`);
  console.log(`New LendingLib:   ${newLendingLib}`);
  console.log(`New Impl:         ${newImpl}`);
  console.log(`Upgrade Calldata: ${callData === "0x" ? "(none)" : callData}`);
  console.log("=======================\n");
  const answer = await rl.question("Proceed with upgrade? (yes/no): ");
  rl.close();
  return answer.toLowerCase() === "yes";
}

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [ownerClient] = await viem.getWalletClients();
const ownerAddress = ownerClient.account.address;
const chainId = await publicClient.getChainId();

// scripts/upgrade/ is one level deeper than scripts/, so deployments is ../../deployments
const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../../deployments",
);
const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);

// Load deployment JSON, falling back to ASSET_LENDING_POOL_PROXY env var for local networks
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.ASSET_LENDING_POOL_PROXY) {
  proxyAddress = getAddress(
    process.env.ASSET_LENDING_POOL_PROXY,
  ) as `0x${string}`;
  try {
    deploymentData = JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    // No JSON file yet — skip persistence
  }
} else {
  try {
    deploymentData = JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    console.error(`No deployment file found at ${deploymentPath}`);
    console.error(
      "Deploy first using deploy-asset-lending-pool.ts, or set ASSET_LENDING_POOL_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  const entry = deploymentData["AssetLendingPool"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "AssetLendingPool proxy address not found in deployment file.",
    );
    console.error("Set ASSET_LENDING_POOL_PROXY to override.");
    process.exit(1);
  }
  proxyAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

// Read current implementation from ERC-1967 storage slot — ground truth
const implSlotValue = await publicClient.getStorageAt({
  address: proxyAddress,
  slot: ERC1967_IMPL_SLOT,
});
if (!implSlotValue || implSlotValue === `0x${"0".repeat(64)}`) {
  console.error(
    `No implementation found at proxy ${proxyAddress}. Is this a valid ERC-1967 proxy?`,
  );
  process.exit(1);
}
const currentImplAddress = getAddress(`0x${implSlotValue.slice(26)}`);

// Authorization check: AssetLendingPool uses Ownable2StepUpgradeable — upgrade
// is gated by onlyOwner, NOT by UPGRADER_ROLE in PermissionManager.
const pool = await viem.getContractAt("AssetLendingPool", proxyAddress);
const poolOwner = await pool.read.owner();

if (poolOwner.toLowerCase() !== ownerAddress.toLowerCase()) {
  console.error(
    `Account ${ownerAddress} is not the pool owner — upgrade will revert.`,
  );
  console.error(
    `Pool owner is ${poolOwner}. Use the correct private key (BASE_PRIVATE_KEY).`,
  );
  process.exit(1);
}

const upgradeCalldata: `0x${string}` = REINITIALIZER_DATA;

// ─── [1/4] Deploy LendingLib ─────────────────────────────────────────────────
console.log("\n[1/4] Deploying new LendingLib...");
const lendingLib = await viem.deployContract("LendingLib");
console.log(`  New LendingLib: ${lendingLib.address}`);

// ─── [2/4] Deploy new AssetLendingPool implementation linked to LendingLib ───
console.log("[2/4] Deploying new AssetLendingPool implementation...");
const newImpl = await viem.deployContract("AssetLendingPool", [], {
  libraries: {
    "project/contracts/lib/LendingLib.sol:LendingLib": lendingLib.address,
  },
});
console.log(`  New implementation: ${newImpl.address}`);

// ─── Confirmation prompt on live networks ────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirmUpgrade(
    connection.networkName,
    chainId,
    ownerAddress,
    proxyAddress,
    currentImplAddress,
    lendingLib.address,
    newImpl.address,
    upgradeCalldata,
  );
  if (!ok) {
    console.log("Upgrade cancelled.");
    process.exit(0);
  }
}

// ─── [3/4] Upgrade proxy ─────────────────────────────────────────────────────
console.log("[3/4] Calling upgradeToAndCall on proxy...");
const txHash = await pool.write.upgradeToAndCall(
  [newImpl.address, upgradeCalldata],
  { account: ownerClient.account },
);
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  Upgrade tx: ${txHash} (block ${receipt.blockNumber})`);
await sleep(5000);

// ─── [4/4] Verify upgrade ─────────────────────────────────────────────────────
console.log("[4/4] Verifying upgrade...");
const postImplSlotValue = await publicClient.getStorageAt({
  address: proxyAddress,
  slot: ERC1967_IMPL_SLOT,
});
const postImplAddress = getAddress(`0x${postImplSlotValue!.slice(26)}`);

if (postImplAddress.toLowerCase() !== newImpl.address.toLowerCase()) {
  console.error("CRITICAL: Implementation slot mismatch after upgrade!");
  console.error(`  Expected: ${newImpl.address}`);
  console.error(`  Got:      ${postImplAddress}`);
  process.exit(1);
}

const actualOwner = await pool.read.owner();
const poolInfo = await pool.read.getPoolInfo();

console.log("\n=== Upgrade Successful ===");
console.log(
  `Network:          ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Proxy:            ${proxyAddress}`);
console.log(`Old Impl:         ${currentImplAddress}`);
console.log(`New LendingLib:   ${lendingLib.address}`);
console.log(`New Impl:         ${newImpl.address}`);
console.log(`Owner:            ${actualOwner}`);
console.log(`PaymentToken:     ${poolInfo.paymentToken}`);
console.log(`AssetNFT:         ${poolInfo.assetNFT}`);
console.log("==========================\n");

// ─── Persist updated deployment record (live networks only) ──────────────────
if (connection.networkConfig.type === "http") {
  // Spread existing entry to preserve all fields (proxy, owner, config,
  // permissionManager, eligibility fields, etc.) then overwrite impl + lib.
  const existingEntry =
    (deploymentData["AssetLendingPool"] as Record<string, unknown>) ?? {};
  const upgradeHistory = (
    (existingEntry.upgradeHistory as unknown[]) ?? []
  ).concat({
    previousImplementation: currentImplAddress,
    newImplementation: newImpl.address,
    lendingLib: lendingLib.address,
    upgradedAt: new Date().toISOString(),
    txHash,
    upgradeCalldata,
  });

  deploymentData["AssetLendingPool"] = {
    ...existingEntry,
    implementation: newImpl.address,
    lendingLib: lendingLib.address,
    upgradedAt: new Date().toISOString(),
    upgradeHistory,
  };

  await writeFile(
    deploymentPath,
    JSON.stringify(deploymentData, null, 2) + "\n",
  );
  console.log(
    `Deployment info updated at deployments/${connection.networkName}.json`,
  );
  console.log(
    `\nNext step: run verify-tenderly.ts --network ${connection.networkName} to verify LendingLib + impl.`,
  );
}
