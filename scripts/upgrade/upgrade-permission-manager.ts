/**
 * upgrade-permission-manager.ts
 *
 * Deploys a new PermissionManager implementation and upgrades the existing
 * ERC-1967 / UUPS proxy to point at it.  Requires the caller to hold
 * DEFAULT_ADMIN_ROLE in the PermissionManager proxy itself (not UPGRADER_ROLE —
 * _authorizeUpgrade is gated on DEFAULT_ADMIN_ROLE; see PermissionManager.sol).
 *
 * Usage
 * -----
 * # Live upgrade (interactive confirmation, writes upgradeHistory to JSON):
 * npx hardhat run scripts/upgrade/upgrade-permission-manager.ts --network baseSepolia
 *
 * # Dry-run on a local fork (no prompt, no JSON write):
 * PERMISSION_MANAGER_PROXY=0x<addr> \
 *   npx hardhat run scripts/upgrade/upgrade-permission-manager.ts --network forkBase
 *
 * Optional env vars:
 *   PERMISSION_MANAGER_PROXY    — override proxy address (bypass deployments JSON)
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

// Load deployment JSON, falling back to PERMISSION_MANAGER_PROXY env var for local networks
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.PERMISSION_MANAGER_PROXY) {
  proxyAddress = getAddress(
    process.env.PERMISSION_MANAGER_PROXY,
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
      "Deploy first using deploy-permission-manager.ts, or set PERMISSION_MANAGER_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  const entry = deploymentData["PermissionManager"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "PermissionManager proxy address not found in deployment file.",
    );
    console.error("Set PERMISSION_MANAGER_PROXY to override.");
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

// PermissionManager is its own authority — check DEFAULT_ADMIN_ROLE directly on the proxy.
// (There is no getPermissionManager() on PermissionManager itself.)
const pm = await viem.getContractAt("PermissionManager", proxyAddress);
let hasAdminRole = false;

try {
  const adminRole = await pm.read.DEFAULT_ADMIN_ROLE();
  hasAdminRole = await pm.read.hasProtocolRole([adminRole, upgraderAddress]);
} catch {
  console.warn(
    "Could not verify DEFAULT_ADMIN_ROLE. Proceeding, but upgrade may fail.",
  );
  hasAdminRole = true;
}

if (!hasAdminRole) {
  console.error(
    `Account ${upgraderAddress} does not have DEFAULT_ADMIN_ROLE on proxy ${proxyAddress}`,
  );
  process.exit(1);
}

const upgradeCalldata: `0x${string}` = REINITIALIZER_DATA;

console.log("\n[1/3] Deploying new PermissionManager implementation...");
const newImpl = await viem.deployContract("PermissionManager");
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
const txHash = await pm.write.upgradeToAndCall(
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

// Sanity-check that the proxy's role state is still intact after the upgrade
const adminRole = await pm.read.DEFAULT_ADMIN_ROLE();
const stillHasAdminRole = await pm.read.hasProtocolRole([
  adminRole,
  upgraderAddress,
]);
if (!stillHasAdminRole) {
  console.error(
    "Post-upgrade sanity check failed: upgrader no longer has DEFAULT_ADMIN_ROLE",
  );
  process.exit(1);
}

console.log("\n=== Upgrade Successful ===");
console.log(
  `Network:            ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Proxy:              ${proxyAddress}`);
console.log(`Old Impl:           ${currentImplAddress}`);
console.log(`New Impl:           ${newImpl.address}`);
console.log(`DEFAULT_ADMIN_ROLE: ${upgraderAddress} ✓`);
console.log("==========================\n");

if (connection.networkConfig.type === "http") {
  const pmEntry =
    (deploymentData["PermissionManager"] as Record<string, unknown>) ?? {};
  const upgradeHistory = ((pmEntry.upgradeHistory as unknown[]) ?? []).concat({
    previousImplementation: currentImplAddress,
    newImplementation: newImpl.address,
    upgradedAt: new Date().toISOString(),
    txHash,
    upgradeCalldata,
  });

  deploymentData["PermissionManager"] = {
    ...pmEntry,
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
