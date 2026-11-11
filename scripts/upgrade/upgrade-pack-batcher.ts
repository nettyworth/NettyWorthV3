/**
 * upgrade-pack-batcher.ts
 *
 * Deploys a new PackBatcher implementation and upgrades the existing
 * ERC-1967 / UUPS proxy to point at it.  Requires the caller to hold
 * UPGRADER_ROLE in the PermissionManager.
 *
 * Two batcher proxies live on Base — one per PackMachineFactory (production
 * and staging) — so this script is run once per proxy. Each proxy's
 * `factory()` is printed and compared against the deployment file's
 * PackMachineFactory; a mismatch is a WARNING (the staging batcher is
 * expected to point at the staging factory), not an abort.
 *
 * Usage
 * -----
 * # Live upgrade (interactive confirmation, writes upgradeHistory to JSON):
 * npx hardhat run scripts/upgrade/upgrade-pack-batcher.ts --network base
 *
 * # Dry-run on a local fork (no prompt, no JSON write):
 * PACK_BATCHER_PROXY=0x<addr> \
 *   npx hardhat run scripts/upgrade/upgrade-pack-batcher.ts --network forkBase
 *
 * Optional env vars:
 *   PACK_BATCHER_PROXY          — override proxy address (bypass deployments JSON)
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

// Load deployment JSON, falling back to PACK_BATCHER_PROXY env var for local networks
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.PACK_BATCHER_PROXY) {
  proxyAddress = getAddress(process.env.PACK_BATCHER_PROXY) as `0x${string}`;
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
      "Deploy first using deploy-pack-batcher.ts, or set PACK_BATCHER_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  const entry = deploymentData["PackBatcher"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error("PackBatcher proxy address not found in deployment file.");
    console.error("Set PACK_BATCHER_PROXY to override.");
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

const batcher = await viem.getContractAt("PackBatcher", proxyAddress);
let hasUpgraderRole = false;

try {
  const pmAddress = await batcher.read.getPermissionManager();
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

// Pre-upgrade snapshot of the only storage this contract has — must survive the swap.
const factoryBefore = await batcher.read.factory();
const pausedBefore = await batcher.read.paused();
const recordedFactory = (
  deploymentData["PackMachineFactory"] as Record<string, unknown> | undefined
)?.proxy as string | undefined;
if (
  recordedFactory &&
  getAddress(recordedFactory) !== getAddress(factoryBefore)
) {
  console.warn(
    `WARNING: proxy factory() = ${factoryBefore} but deployments/${connection.networkName}.json ` +
      `records PackMachineFactory.proxy = ${recordedFactory}. Expected only for the staging batcher.`,
  );
}

const upgradeCalldata: `0x${string}` = REINITIALIZER_DATA;

console.log("\n[1/3] Deploying new PackBatcher implementation...");
const newImpl = await viem.deployContract("PackBatcher");
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
const txHash = await batcher.write.upgradeToAndCall(
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

const factoryAfter = await batcher.read.factory();
const pausedAfter = await batcher.read.paused();
const maxBatch = await batcher.read.MAX_BATCH();
const actualPermissionManager = await batcher.read.getPermissionManager();

if (
  getAddress(factoryAfter) !== getAddress(factoryBefore) ||
  pausedAfter !== pausedBefore
) {
  console.error("CRITICAL: PackBatcher storage changed across the upgrade!");
  console.error(`  factory: ${factoryBefore} -> ${factoryAfter}`);
  console.error(`  paused:  ${pausedBefore} -> ${pausedAfter}`);
  process.exit(1);
}
if (!newImpl.abi.some((f) => "name" in f && f.name === "openPacksWithCodes")) {
  console.error("CRITICAL: new implementation ABI lacks openPacksWithCodes");
  process.exit(1);
}

console.log("\n=== Upgrade Successful ===");
console.log(
  `Network:            ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Proxy:              ${proxyAddress}`);
console.log(`Old Impl:           ${currentImplAddress}`);
console.log(`New Impl:           ${newImpl.address}`);
console.log(`Factory:            ${factoryAfter}`);
console.log(`MAX_BATCH:          ${maxBatch}`);
console.log(`Paused:             ${pausedAfter}`);
console.log(`Permission Manager: ${actualPermissionManager}`);
console.log("==========================\n");

if (connection.networkConfig.type === "http") {
  const batcherEntry =
    (deploymentData["PackBatcher"] as Record<string, unknown>) ?? {};
  const recordedProxy = batcherEntry.proxy as string | undefined;
  if (
    recordedProxy &&
    getAddress(recordedProxy) !== getAddress(proxyAddress)
  ) {
    console.warn(
      `Upgraded ${proxyAddress} but deployments JSON records PackBatcher.proxy = ${recordedProxy}; ` +
        "not writing upgradeHistory. Record this proxy under its own key by hand.",
    );
  } else {
    const upgradeHistory = (
      (batcherEntry.upgradeHistory as unknown[]) ?? []
    ).concat({
      previousImplementation: currentImplAddress,
      newImplementation: newImpl.address,
      upgradedAt: new Date().toISOString(),
      txHash,
      upgradeCalldata,
    });

    deploymentData["PackBatcher"] = {
      ...batcherEntry,
      proxy: proxyAddress,
      implementation: newImpl.address,
      packMachineFactory: factoryAfter,
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
}
