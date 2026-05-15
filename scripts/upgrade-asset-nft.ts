import { network } from "hardhat";
import { getAddress, keccak256, toHex } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const REINITIALIZER_DATA = (
  process.env.UPGRADE_REINITIALIZER_DATA ?? "0x"
) as `0x${string}`;

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
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== Upgrade Summary ===");
  console.log(`Network:            ${networkName}`);
  console.log(`Chain ID:           ${chainId}`);
  console.log(`Upgrader:           ${upgrader}`);
  console.log(`Proxy:              ${proxy}`);
  console.log(`Current Impl:       ${oldImpl}`);
  console.log(`New Impl:           ${newImpl}`);
  console.log(
    `Reinitializer Data: ${REINITIALIZER_DATA === "0x" ? "(none)" : REINITIALIZER_DATA}`,
  );
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
const deploymentPath = join(
  deploymentsDir,
  `${connection.networkName}.json`,
);

// Load deployment JSON, falling back to ASSET_NFT_PROXY env var for local networks
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.ASSET_NFT_PROXY) {
  proxyAddress = getAddress(process.env.ASSET_NFT_PROXY) as `0x${string}`;
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
      "Deploy first using deploy-asset-nft.ts, or set ASSET_NFT_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  const entry = deploymentData["AssetNFT"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error("AssetNFT proxy address not found in deployment file.");
    console.error("Set ASSET_NFT_PROXY to override.");
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
// Storage slot is a 32-byte (64 hex chars) right-aligned address
const currentImplAddress = getAddress(`0x${implSlotValue.slice(26)}`);

// Pre-check: upgrader must hold UPGRADER_ROLE before wasting gas on impl deployment
const nft = await viem.getContractAt("AssetNFT", proxyAddress);
const hasRole = await nft.read.hasRole([UPGRADER_ROLE, upgraderAddress]);
if (!hasRole) {
  console.error(
    `Account ${upgraderAddress} does not have UPGRADER_ROLE on proxy ${proxyAddress}`,
  );
  process.exit(1);
}

console.log("\n[1/3] Deploying new AssetNFT implementation...");
const newImpl = await viem.deployContract("AssetNFT");
console.log(`  New implementation: ${newImpl.address}`);

if (connection.networkConfig.type === "http") {
  const ok = await confirmUpgrade(
    connection.networkName,
    chainId,
    upgraderAddress,
    proxyAddress,
    currentImplAddress,
    newImpl.address,
  );
  if (!ok) {
    console.log("Upgrade cancelled.");
    process.exit(0);
  }
}

console.log("[2/3] Calling upgradeToAndCall on proxy...");
const txHash = await nft.write.upgradeToAndCall(
  [newImpl.address, REINITIALIZER_DATA],
  { account: upgraderClient.account },
);
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  Upgrade tx: ${txHash} (block ${receipt.blockNumber})`);

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

const actualName = await nft.read.name();
const actualSymbol = await nft.read.symbol();
const actualContractURI = await nft.read.contractURI();

console.log("\n=== Upgrade Successful ===");
console.log(`Network:      ${connection.networkName} (chainId: ${chainId})`);
console.log(`Proxy:        ${proxyAddress}`);
console.log(`Old Impl:     ${currentImplAddress}`);
console.log(`New Impl:     ${newImpl.address}`);
console.log(`Name:         ${actualName}`);
console.log(`Symbol:       ${actualSymbol}`);
console.log(`Contract URI: ${actualContractURI}`);
console.log("==========================\n");

if (connection.networkConfig.type === "http") {
  const assetEntry =
    ((deploymentData["AssetNFT"] as Record<string, unknown>) ?? {});
  const upgradeHistory = (
    (assetEntry.upgradeHistory as unknown[]) ?? []
  ).concat({
    previousImplementation: currentImplAddress,
    newImplementation: newImpl.address,
    upgradedAt: new Date().toISOString(),
    txHash,
    reinitializerData: REINITIALIZER_DATA,
  });

  deploymentData["AssetNFT"] = {
    ...assetEntry,
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
