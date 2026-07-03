/**
 * upgrade-buyback-pool.ts
 *
 * Deploys a new BuybackPool implementation and upgrades the existing
 * ERC-1967 / UUPS proxy to point at it.  Requires the caller to hold
 * UPGRADER_ROLE in the PermissionManager.
 *
 * Usage
 * -----
 * # Live upgrade (interactive confirmation, writes upgradeHistory to JSON):
 * npx hardhat run scripts/upgrade/upgrade-buyback-pool.ts --network baseSepolia
 *
 * # Dry-run on a local fork (no prompt, no JSON write):
 * BUYBACK_POOL_PROXY=0x<addr> \
 *   npx hardhat run scripts/upgrade/upgrade-buyback-pool.ts --network forkBase
 *
 * Optional env vars:
 *   BUYBACK_POOL_PROXY          — override proxy address (bypass deployments JSON)
 *   UPGRADE_REINITIALIZER_DATA  — raw calldata forwarded to upgradeToAndCall
 *                                 (default "0x" = plain implementation swap)
 */

import { network } from "hardhat";
import { getAddress, keccak256, toHex } from "viem";
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

const UPGRADER_ROLE = keccak256(toHex("UPGRADER_ROLE"));

async function confirmUpgrade(
  networkName: string,
  chainId: number,
  upgrader: string,
  proxy: string,
  oldImpl: string,
  newImpl: string,
  callData: `0x${string}`,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== Upgrade Summary ===");
  console.log(`Network:          ${networkName}`);
  console.log(`Chain ID:         ${chainId}`);
  console.log(`Upgrader:         ${upgrader}`);
  console.log(`Proxy:            ${proxy}`);
  console.log(`Current Impl:     ${oldImpl}`);
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
const [upgraderClient] = await viem.getWalletClients();
const upgraderAddress = upgraderClient.account.address;
const chainId = await publicClient.getChainId();

// scripts/upgrade/ is one level deeper than scripts/, so deployments is ../../deployments
const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../../deployments",
);
const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);

// Load deployment JSON, falling back to BUYBACK_POOL_PROXY env var for local networks
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.BUYBACK_POOL_PROXY) {
  proxyAddress = getAddress(process.env.BUYBACK_POOL_PROXY) as `0x${string}`;
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
      "Deploy first using deploy-pack-machine.ts, or set BUYBACK_POOL_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  const entry = deploymentData["BuybackPool"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error("BuybackPool proxy address not found in deployment file.");
    console.error("Set BUYBACK_POOL_PROXY to override.");
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

const buyback = await viem.getContractAt("BuybackPool", proxyAddress);
let hasUpgraderRole = false;

try {
  const pmAddress = await buyback.read.getPermissionManager();
  const pm = await viem.getContractAt("PermissionManager", pmAddress);
  hasUpgraderRole = await pm.read.hasProtocolRole([
    UPGRADER_ROLE,
    upgraderAddress,
  ]);
} catch {
  console.warn(
    "Could not verify UPGRADER_ROLE. Proceeding, but upgrade may fail.",
  );
  hasUpgraderRole = true;
}

if (!hasUpgraderRole) {
  console.error(
    `Account ${upgraderAddress} does not have UPGRADER_ROLE on proxy ${proxyAddress}`,
  );
  process.exit(1);
}

const upgradeCalldata: `0x${string}` = REINITIALIZER_DATA;

console.log("\n[1/3] Deploying new BuybackPool implementation...");
const newImpl = await viem.deployContract("BuybackPool");
console.log(`  New implementation: ${newImpl.address}`);

if (connection.networkConfig.type === "http") {
  const ok = await confirmUpgrade(
    connection.networkName,
    chainId,
    upgraderAddress,
    proxyAddress,
    currentImplAddress,
    newImpl.address,
    upgradeCalldata,
  );
  if (!ok) {
    console.log("Upgrade cancelled.");
    process.exit(0);
  }
}

console.log("[2/3] Calling upgradeToAndCall on proxy...");
const txHash = await buyback.write.upgradeToAndCall(
  [newImpl.address, upgradeCalldata],
  { account: upgraderClient.account },
);
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  Upgrade tx: ${txHash} (block ${receipt.blockNumber})`);
await sleep(5000);

console.log("[3/3] Verifying upgrade...");
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

const actualDefaultBps = await buyback.read.getDefaultBuybackBps();
const actualPermissionManager = await buyback.read.getPermissionManager();

console.log("\n=== Upgrade Successful ===");
console.log(
  `Network:            ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Proxy:              ${proxyAddress}`);
console.log(`Old Impl:           ${currentImplAddress}`);
console.log(`New Impl:           ${newImpl.address}`);
console.log(`Default Buyback:    ${actualDefaultBps} bps`);
console.log(`Permission Manager: ${actualPermissionManager}`);
console.log("==========================\n");

if (connection.networkConfig.type === "http") {
  const poolEntry =
    (deploymentData["BuybackPool"] as Record<string, unknown>) ?? {};
  const upgradeHistory = ((poolEntry.upgradeHistory as unknown[]) ?? []).concat(
    {
      previousImplementation: currentImplAddress,
      newImplementation: newImpl.address,
      upgradedAt: new Date().toISOString(),
      txHash,
      upgradeCalldata,
    },
  );

  deploymentData["BuybackPool"] = {
    ...poolEntry,
    implementation: newImpl.address,
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
}
