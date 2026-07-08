/**
 * set-pack-machine-factory.ts
 *
 * Set (or update) the PackMachineFactory address on AssetLendingPoolConfig.
 * The factory address is used to validate target machines in the defaulted-asset
 * acquisition path; the lending pool reverts AssetLendingPool__ZeroAddress if it
 * is address(0).
 *
 * Usage
 * -----
 * # Set the pack machine factory on Base:
 * PACK_MACHINE_FACTORY=0x<addr> npx hardhat run scripts/set-pack-machine-factory.ts --network base
 *
 * # Override the config proxy directly instead of reading from deployments JSON:
 * PACK_MACHINE_FACTORY=0x<addr> CONFIG_PROXY=0x<addr> \
 *   npx hardhat run scripts/set-pack-machine-factory.ts --network base
 *
 * # Or override the pool proxy (config is resolved via on-chain getConfig()):
 * PACK_MACHINE_FACTORY=0x<addr> ASSET_LENDING_POOL_PROXY=0x<addr> \
 *   npx hardhat run scripts/set-pack-machine-factory.ts --network base
 *
 * Environment variables
 * ---------------------
 * PACK_MACHINE_FACTORY      (required) new PackMachineFactory address
 * ASSET_LENDING_POOL_PROXY  override pool proxy (optional)
 * CONFIG_PROXY              override config proxy directly (optional; takes precedence)
 */

import { network } from "hardhat";
import { getAddress, isAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments, saveDeployment } from "./lib/deployments.js";

// ─── Parse PACK_MACHINE_FACTORY ───────────────────────────────────────────────

const rawFactory = process.env.PACK_MACHINE_FACTORY;
if (!rawFactory) {
  console.error(
    "Missing required env variable PACK_MACHINE_FACTORY.",
  );
  console.error(
    "Usage: PACK_MACHINE_FACTORY=0x<addr> npx hardhat run scripts/set-pack-machine-factory.ts --network <net>",
  );
  process.exit(1);
}
if (!isAddress(rawFactory)) {
  console.error(
    `Invalid PACK_MACHINE_FACTORY: "${rawFactory}". Must be a valid Ethereum address (0x-prefixed, 20 bytes).`,
  );
  process.exit(1);
}
const newFactory = getAddress(rawFactory) as `0x${string}`;
if (newFactory === "0x0000000000000000000000000000000000000000") {
  console.error(
    "PACK_MACHINE_FACTORY cannot be the zero address — the contract will revert AssetLendingPool__ZeroAddress.",
  );
  process.exit(1);
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
  console.error("setPackMachineFactory is onlyOwner — transaction would revert.");
  process.exit(1);
}

// ─── Read current pack machine factory ───────────────────────────────────────

const currentFactory = await config.read.packMachineFactory();

console.log(`\nConfig proxy:            ${configProxyAddress}`);
console.log(`Owner:                   ${owner}`);
console.log(
  `Current pack machine factory: ${currentFactory === "0x0000000000000000000000000000000000000000" ? "0x0 (not set)" : currentFactory}`,
);

// ─── No-op check ─────────────────────────────────────────────────────────────

if (currentFactory.toLowerCase() === newFactory.toLowerCase()) {
  console.log(
    `\nPack machine factory is already set to ${newFactory}. Nothing to do.`,
  );
  process.exit(0);
}

// ─── Confirmation on live networks ────────────────────────────────────────────

if (connection.networkConfig.type === "http") {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setPackMachineFactory Summary ===");
  console.log(`Network:                  ${connection.networkName}`);
  console.log(`Chain ID:                 ${chainId}`);
  console.log(`Caller:                   ${callerAddress}`);
  console.log(`Config proxy:             ${configProxyAddress}`);
  console.log(
    `Old pack machine factory: ${currentFactory === "0x0000000000000000000000000000000000000000" ? "0x0 (not set)" : currentFactory}`,
  );
  console.log(`New pack machine factory: ${newFactory}`);
  console.log("=====================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  if (answer.toLowerCase() !== "yes") {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────

console.log(`\n[1/2] Calling setPackMachineFactory(${newFactory})…`);
const txHash = await config.write.setPackMachineFactory(
  [newFactory],
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
const factoryAfter = await config.read.packMachineFactory();

if (factoryAfter.toLowerCase() !== newFactory.toLowerCase()) {
  console.error(
    `CRITICAL: State mismatch after update! Expected ${newFactory}, got ${factoryAfter}`,
  );
  process.exit(1);
}
console.log(`  packMachineFactory confirmed: ${factoryAfter} ✓`);

// ─── Summary ──────────────────────────────────────────────────────────────────

console.log("\n=== setPackMachineFactory Complete ===");
console.log(`Network:      ${connection.networkName} (chainId: ${chainId})`);
console.log(`Config proxy: ${configProxyAddress}`);
console.log(
  `Old pack machine factory: ${currentFactory === "0x0000000000000000000000000000000000000000" ? "0x0 (not set)" : currentFactory}`,
);
console.log(`New pack machine factory: ${factoryAfter}`);
console.log(`Tx:           ${txHash}`);
console.log("=====================================\n");

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
      packMachineFactory: factoryAfter,
      packMachineFactoryUpdatedAt: new Date().toISOString(),
    });
    console.log(
      `Deployment info updated at deployments/${connection.networkName}.json`,
    );
  } catch (err) {
    // Non-fatal — the on-chain state is already confirmed; just warn.
    console.warn(`Warning: could not persist to deployments JSON: ${err}`);
  }
}
