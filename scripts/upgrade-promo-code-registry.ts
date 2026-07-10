import { network } from "hardhat";
import { getAddress, keccak256, toHex } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { sleep } from "./lib/sleep.js";

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

const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../deployments",
);
const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);

// Load deployment JSON, falling back to PROMO_CODE_REGISTRY_PROXY env var for local networks
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.PROMO_CODE_REGISTRY_PROXY) {
  proxyAddress = getAddress(
    process.env.PROMO_CODE_REGISTRY_PROXY,
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
      "Deploy first using deploy-promo-code-registry.ts, or set PROMO_CODE_REGISTRY_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  const entry = deploymentData["PromoCodeRegistry"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "PromoCodeRegistry proxy address not found in deployment file.",
    );
    console.error("Set PROMO_CODE_REGISTRY_PROXY to override.");
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

const registry = await viem.getContractAt("PromoCodeRegistry", proxyAddress);
let hasUpgraderRole = false;

try {
  const pmAddress = await registry.read.getPermissionManager();
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

console.log("\n[1/3] Deploying new PromoCodeRegistry implementation...");
const newImpl = await viem.deployContract("PromoCodeRegistry");
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
const txHash = await registry.write.upgradeToAndCall(
  [newImpl.address, upgradeCalldata],
  { account: upgraderClient.account },
);
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  Upgrade tx: ${txHash} (block ${receipt.blockNumber})`);
await sleep(2000);

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

const actualPackMachineFactory = await registry.read.packMachineFactory();
const actualBuybackPool = await registry.read.buybackPool();

console.log("\n=== Upgrade Successful ===");
console.log(
  `Network:             ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Proxy:               ${proxyAddress}`);
console.log(`Old Impl:            ${currentImplAddress}`);
console.log(`New Impl:            ${newImpl.address}`);
console.log(`PackMachineFactory:  ${actualPackMachineFactory}`);
console.log(`BuybackPool:         ${actualBuybackPool}`);
console.log("==========================\n");

if (connection.networkConfig.type === "http") {
  const registryEntry =
    (deploymentData["PromoCodeRegistry"] as Record<string, unknown>) ?? {};
  const upgradeHistory = (
    (registryEntry.upgradeHistory as unknown[]) ?? []
  ).concat({
    previousImplementation: currentImplAddress,
    newImplementation: newImpl.address,
    upgradedAt: new Date().toISOString(),
    txHash,
    upgradeCalldata,
  });

  deploymentData["PromoCodeRegistry"] = {
    ...registryEntry,
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
