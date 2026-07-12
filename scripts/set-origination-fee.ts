/**
 * set-origination-fee.ts
 *
 * Set (or update) the origination fee on AssetLendingPoolConfig.
 * The origination fee is charged on each loan at disbursement, expressed in
 * basis points, and is swept to the designated fee wallet.
 *
 * Validation mirrors the contract:
 *   - bps must be 0..10000 (BPS)
 *   - wallet must be non-zero when bps > 0
 *   - wallet is ignored (zero is accepted) when bps == 0
 *
 * Usage
 * -----
 * # Set a 1% origination fee on Base:
 * ORIGINATION_FEE_BPS=100 FEE_WALLET=0x<addr> npx hardhat run scripts/set-origination-fee.ts --network base
 *
 * # Disable the origination fee:
 * ORIGINATION_FEE_BPS=0 npx hardhat run scripts/set-origination-fee.ts --network base
 *
 * # Override the config proxy directly instead of reading from deployments JSON:
 * ORIGINATION_FEE_BPS=100 FEE_WALLET=0x<addr> CONFIG_PROXY=0x<addr> \
 *   npx hardhat run scripts/set-origination-fee.ts --network base
 *
 * # Override the pool proxy (config is resolved via on-chain getConfig()):
 * ORIGINATION_FEE_BPS=100 FEE_WALLET=0x<addr> ASSET_LENDING_POOL_PROXY=0x<addr> \
 *   npx hardhat run scripts/set-origination-fee.ts --network base
 *
 * Environment variables
 * ---------------------
 * ORIGINATION_FEE_BPS       (required) new fee in basis points, 0..10000
 * FEE_WALLET                (required when bps > 0) address that receives the fee
 * ASSET_LENDING_POOL_PROXY  override pool proxy (optional)
 * CONFIG_PROXY              override config proxy directly (optional; takes precedence)
 */

import { network } from "hardhat";
import { getAddress, isAddress, zeroAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments, saveDeployment } from "./lib/deployments.js";

const BPS = 10_000n;

// ─── Parse ORIGINATION_FEE_BPS ───────────────────────────────────────────────

const rawBps = process.env.ORIGINATION_FEE_BPS;
if (rawBps === undefined || rawBps === "") {
  console.error("Missing required env variable ORIGINATION_FEE_BPS.");
  console.error(
    "Usage: ORIGINATION_FEE_BPS=100 FEE_WALLET=0x<addr> npx hardhat run scripts/set-origination-fee.ts --network <net>",
  );
  process.exit(1);
}
const parsedBps = Number(rawBps);
if (!Number.isInteger(parsedBps) || parsedBps < 0 || parsedBps > 10_000) {
  console.error(
    `Invalid ORIGINATION_FEE_BPS: "${rawBps}". Must be an integer 0..10000.`,
  );
  process.exit(1);
}
const newBps = BigInt(parsedBps);

// ─── Parse FEE_WALLET ────────────────────────────────────────────────────────

const rawWallet = process.env.FEE_WALLET ?? "";
let newWallet: `0x${string}`;

if (newBps > 0n) {
  if (!rawWallet) {
    console.error(
      "Missing required env variable FEE_WALLET (required when ORIGINATION_FEE_BPS > 0).",
    );
    process.exit(1);
  }
  if (!isAddress(rawWallet)) {
    console.error(
      `Invalid FEE_WALLET: "${rawWallet}". Must be a valid Ethereum address (0x-prefixed, 20 bytes).`,
    );
    process.exit(1);
  }
  const addr = getAddress(rawWallet) as `0x${string}`;
  if (addr === zeroAddress) {
    console.error(
      "FEE_WALLET cannot be the zero address when bps > 0 — the contract will revert AssetLendingPool__ZeroAddress.",
    );
    process.exit(1);
  }
  newWallet = addr;
} else {
  // bps == 0: zero wallet is acceptable; normalise whatever was provided
  newWallet = rawWallet && isAddress(rawWallet)
    ? (getAddress(rawWallet) as `0x${string}`)
    : zeroAddress;
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
  console.error("setOriginationFee is onlyOwner — transaction would revert.");
  process.exit(1);
}

// ─── Read current origination fee ────────────────────────────────────────────

const currentBps = await config.read.originationFeeBps();
const currentWallet = await config.read.feeWallet();

const fmtWallet = (addr: string) =>
  addr === zeroAddress ? "0x0 (not set)" : addr;

console.log(`\nConfig proxy:          ${configProxyAddress}`);
console.log(`Owner:                 ${owner}`);
console.log(`Current originationFeeBps: ${currentBps} bps`);
console.log(`Current feeWallet:         ${fmtWallet(currentWallet)}`);

// ─── No-op check ─────────────────────────────────────────────────────────────

if (
  currentBps === newBps &&
  currentWallet.toLowerCase() === newWallet.toLowerCase()
) {
  console.log(
    `\nOrigination fee is already set to ${newBps} bps / ${fmtWallet(newWallet)}. Nothing to do.`,
  );
  process.exit(0);
}

// ─── Confirmation on live networks ────────────────────────────────────────────

if (connection.networkConfig.type === "http") {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setOriginationFee Summary ===");
  console.log(`Network:          ${connection.networkName}`);
  console.log(`Chain ID:         ${chainId}`);
  console.log(`Caller:           ${callerAddress}`);
  console.log(`Config proxy:     ${configProxyAddress}`);
  console.log(`Old originationFeeBps: ${currentBps} bps`);
  console.log(`New originationFeeBps: ${newBps} bps`);
  console.log(`Old feeWallet:         ${fmtWallet(currentWallet)}`);
  console.log(`New feeWallet:         ${fmtWallet(newWallet)}`);
  console.log("=================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  if (answer.toLowerCase() !== "yes") {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────

console.log(
  `\n[1/2] Calling setOriginationFee(${newBps}, ${fmtWallet(newWallet)})…`,
);
const txHash = await config.write.setOriginationFee(
  [newBps, newWallet],
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
const bpsAfter = await config.read.originationFeeBps();
const walletAfter = await config.read.feeWallet();

if (bpsAfter !== newBps) {
  console.error(
    `CRITICAL: bps mismatch after update! Expected ${newBps}, got ${bpsAfter}`,
  );
  process.exit(1);
}
if (walletAfter.toLowerCase() !== newWallet.toLowerCase()) {
  console.error(
    `CRITICAL: feeWallet mismatch after update! Expected ${newWallet}, got ${walletAfter}`,
  );
  process.exit(1);
}
console.log(`  originationFeeBps confirmed: ${bpsAfter} bps ✓`);
console.log(`  feeWallet confirmed:         ${fmtWallet(walletAfter)} ✓`);

// ─── Summary ──────────────────────────────────────────────────────────────────

console.log("\n=== setOriginationFee Complete ===");
console.log(`Network:      ${connection.networkName} (chainId: ${chainId})`);
console.log(`Config proxy: ${configProxyAddress}`);
console.log(`Old originationFeeBps: ${currentBps} bps`);
console.log(`New originationFeeBps: ${bpsAfter} bps`);
console.log(`Old feeWallet: ${fmtWallet(currentWallet)}`);
console.log(`New feeWallet: ${fmtWallet(walletAfter)}`);
console.log(`Tx:           ${txHash}`);
console.log("==================================\n");

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
      originationFeeBps: Number(bpsAfter),
      feeWallet: walletAfter,
      originationFeeUpdatedAt: new Date().toISOString(),
    });
    console.log(
      `Deployment info updated at deployments/${connection.networkName}.json`,
    );
  } catch (err) {
    // Non-fatal — the on-chain state is already confirmed; just warn.
    console.warn(`Warning: could not persist to deployments JSON: ${err}`);
  }
}
