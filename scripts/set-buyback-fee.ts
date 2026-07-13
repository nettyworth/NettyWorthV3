/**
 * set-buyback-fee.ts
 *
 * Set the protocol fee charged on every BuybackPool payout (setBuybackFeeBps).
 * The fee is deducted from the seller's payout and routed to financeWallet.
 * A value of 0 disables the fee entirely (default). Max 100% (10000 bps).
 *
 * Caller must hold PACK_OPERATOR_ROLE in the PermissionManager.
 *
 * Usage
 * -----
 * # Set fee to 5% on Base:
 * BUYBACK_FEE_BPS=500 \
 *   npx hardhat run scripts/set-buyback-fee.ts --network base
 *
 * # Dry-run on a local fork (no prompt, no JSON write):
 * BUYBACK_FEE_BPS=500 \
 *   npx hardhat run scripts/set-buyback-fee.ts --network forkBase
 *
 * # Disable the fee (set to 0):
 * BUYBACK_FEE_BPS=0 \
 *   npx hardhat run scripts/set-buyback-fee.ts --network base
 *
 * Environment variables
 * ---------------------
 * BUYBACK_FEE_BPS      (required) new fee in basis points (0–10000; e.g. 500 = 5%)
 * BUYBACK_POOL_PROXY   (optional) override BuybackPool proxy; falls back to deployments/<network>.json
 */

import { network } from "hardhat";
import { getAddress, keccak256, toHex } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments, saveDeployment } from "./lib/deployments.js";
import { sleep } from "./lib/sleep.js";

const MAX_BUYBACK_FEE = 10_000; // 100% in bps

// ─── Role constants (must match contracts/lib/Roles.sol) ─────────────────────

const PACK_OPERATOR_ROLE = keccak256(toHex("PACK_OPERATOR_ROLE"));

// ─── Parse BUYBACK_FEE_BPS ───────────────────────────────────────────────────

const rawBps = process.env.BUYBACK_FEE_BPS;

if (rawBps === undefined) {
  console.error(
    "Missing BUYBACK_FEE_BPS environment variable.\n" +
      "Example: BUYBACK_FEE_BPS=500  (= 5%)\n" +
      "         BUYBACK_FEE_BPS=0    (disable fee)",
  );
  process.exit(1);
}

const newBps = parseInt(rawBps, 10);

if (!Number.isInteger(newBps) || isNaN(newBps) || newBps < 0) {
  console.error(
    `BUYBACK_FEE_BPS must be a non-negative integer. Got: "${rawBps}"`,
  );
  process.exit(1);
}

if (newBps > MAX_BUYBACK_FEE) {
  console.error(
    `BUYBACK_FEE_BPS ${newBps} exceeds the on-chain maximum of ${MAX_BUYBACK_FEE} (100%).\n` +
      "Aborting to avoid a revert.",
  );
  process.exit(1);
}

// ─── Confirmation prompt (live networks only) ─────────────────────────────────

async function confirmUpdate(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
  currentBps: number,
  nextBps: number,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setBuybackFeeBps Summary ===");
  console.log(`Network:          ${networkName}`);
  console.log(`Chain ID:         ${chainId}`);
  console.log(`Caller:           ${caller}`);
  console.log(`Proxy:            ${proxy}`);
  console.log(
    `Current fee bps:  ${currentBps} (${currentBps / 100}%)${currentBps === 0 ? " — disabled" : ""}`,
  );
  console.log(
    `New fee bps:      ${nextBps} (${nextBps / 100}%)${nextBps === 0 ? " — will disable fee" : ""}`,
  );
  console.log("================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  return answer.toLowerCase() === "yes";
}

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [callerClient] = await viem.getWalletClients();
const callerAddress = callerClient.account.address;
const chainId = await publicClient.getChainId();
const isLive = connection.networkConfig.type === "http";
const networkName = connection.networkName;

// ─── Resolve BuybackPool proxy address ───────────────────────────────────────

let proxyAddress: `0x${string}`;
let deploymentData: Record<string, unknown> = {};

if (process.env.BUYBACK_POOL_PROXY) {
  proxyAddress = getAddress(process.env.BUYBACK_POOL_PROXY) as `0x${string}`;
  if (isLive) {
    deploymentData = await readDeployments(networkName);
  }
} else {
  deploymentData = await readDeployments(networkName);
  const entry = deploymentData["BuybackPool"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      `BuybackPool proxy not found in deployments/${networkName}.json`,
    );
    console.error(
      "Deploy first using deploy-pack-machine.ts, or set BUYBACK_POOL_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  proxyAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── Verify PACK_OPERATOR_ROLE ────────────────────────────────────────────────

const buyback = await viem.getContractAt("BuybackPool", proxyAddress);
let hasRole = false;

try {
  const pmAddress = await buyback.read.getPermissionManager();
  const pm = await viem.getContractAt("PermissionManager", pmAddress);
  hasRole = await pm.read.hasProtocolRole([PACK_OPERATOR_ROLE, callerAddress]);
} catch {
  console.warn(
    "Could not verify PACK_OPERATOR_ROLE. Proceeding, but the transaction may fail.",
  );
  hasRole = true;
}

if (!hasRole) {
  console.error(
    `Account ${callerAddress} does not have PACK_OPERATOR_ROLE on proxy ${proxyAddress}.\n` +
      "Grant it first using scripts/grant-role.ts.",
  );
  process.exit(1);
}

// ─── Read current state ───────────────────────────────────────────────────────

const currentBps = await buyback.read.getBuybackFeeBps();

console.log(
  `\nCurrent buybackFeeBps: ${currentBps} (${currentBps / 100}%)${currentBps === 0 ? " — currently disabled" : ""}`,
);

// ─── No-op check ─────────────────────────────────────────────────────────────

if (currentBps === newBps) {
  console.log(`\nNo-op: buybackFeeBps is already ${newBps}. Nothing to do.`);
  process.exit(0);
}

// ─── Confirmation on live networks ───────────────────────────────────────────

if (isLive) {
  const ok = await confirmUpdate(
    networkName,
    chainId,
    callerAddress,
    proxyAddress,
    currentBps,
    newBps,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── [1] Set buyback fee bps ──────────────────────────────────────────────────

console.log(`\n[1/1] Calling setBuybackFeeBps(${newBps})...`);
const bpsTx = await buyback.write.setBuybackFeeBps([newBps], {
  account: callerClient.account,
});
const bpsReceipt = await publicClient.waitForTransactionReceipt({
  hash: bpsTx,
});
console.log(`  tx: ${bpsTx} (block ${bpsReceipt.blockNumber})`);
if (bpsReceipt.status !== "success") {
  console.error(`setBuybackFeeBps() reverted! Hash: ${bpsTx}`);
  process.exit(1);
}
await sleep(2000);

// ─── Verify ───────────────────────────────────────────────────────────────────

console.log("[✓] Verifying...");
const verifiedBps = await buyback.read.getBuybackFeeBps();

if (verifiedBps !== newBps) {
  console.error("Verification failed!");
  console.error(`  buybackFeeBps: expected ${newBps}, got ${verifiedBps}`);
  process.exit(1);
}

console.log(
  `  buybackFeeBps: ${verifiedBps} (${verifiedBps / 100}%)${verifiedBps === 0 ? " — fee disabled" : ""} ✓`,
);

console.log("\n=== setBuybackFeeBps Complete ===");
console.log(`Network:  ${networkName} (chainId: ${chainId})`);
console.log(`Proxy:    ${proxyAddress}`);
console.log(
  `New fee:  ${verifiedBps} bps (${verifiedBps / 100}%)${verifiedBps === 0 ? " — disabled" : ""}`,
);
console.log(`Tx:       ${bpsTx}`);
console.log("=================================\n");

// ─── Persist to deployments/<network>.json (live networks only) ───────────────

if (isLive) {
  const existing =
    (deploymentData["BuybackPool"] as Record<string, unknown>) ?? {};
  await saveDeployment(networkName, "BuybackPool", {
    ...existing,
    buybackFeeBps: verifiedBps.toString(),
    buybackFeeUpdatedAt: new Date().toISOString(),
  });
  console.log(`Deployment info updated at deployments/${networkName}.json`);
}
