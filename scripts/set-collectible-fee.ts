import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments, saveDeployment } from "./lib/deployments.js";
import { sleep } from "./lib/sleep.js";

// ─── DEFAULT_ADMIN_ROLE = bytes32(0) ─────────────────────────────────────────
const DEFAULT_ADMIN_ROLE = `0x${"0".repeat(64)}` as `0x${string}`;

const MAX_COLLECTIBLE_FEE = 1_000; // 10% in bps

// ─── Parse COLLECTIBLE_FEES_BPS ───────────────────────────────────────────────
const rawBps = process.env.COLLECTIBLE_FEES_BPS;

if (!rawBps) {
  console.error(
    "Missing COLLECTIBLE_FEES_BPS environment variable.\n" +
      "Example: COLLECTIBLE_FEES_BPS=300  (= 3%)",
  );
  process.exit(1);
}

const newBps = parseInt(rawBps, 10);

if (!Number.isInteger(newBps) || isNaN(newBps) || newBps < 0) {
  console.error(
    `COLLECTIBLE_FEES_BPS must be a non-negative integer. Got: "${rawBps}"`,
  );
  process.exit(1);
}

if (newBps > MAX_COLLECTIBLE_FEE) {
  console.error(
    `COLLECTIBLE_FEES_BPS ${newBps} exceeds the on-chain maximum of ${MAX_COLLECTIBLE_FEE} (10%).\n` +
      "Aborting to avoid a revert.",
  );
  process.exit(1);
}

// ─── SKIP_ENABLE flag ─────────────────────────────────────────────────────────
const skipEnable = Boolean(process.env.SKIP_ENABLE);

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirmUpdate(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
  currentBps: number,
  currentEnabled: boolean,
  nextBps: number,
  willEnable: boolean,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setCollectibleFee Summary ===");
  console.log(`Network:          ${networkName}`);
  console.log(`Chain ID:         ${chainId}`);
  console.log(`Caller:           ${caller}`);
  console.log(`Proxy:            ${proxy}`);
  console.log(`Current bps:      ${currentBps} (${currentBps / 100}%)`);
  console.log(`New bps:          ${nextBps} (${nextBps / 100}%)`);
  console.log(`Currently enabled: ${currentEnabled}`);
  console.log(
    `Enable action:    ${skipEnable ? "skipped (SKIP_ENABLE set)" : willEnable ? "setCollectibleFeesEnabled(true)" : "already enabled — no extra call"}`,
  );
  console.log("=================================\n");
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

// ─── Resolve FeeController proxy address ─────────────────────────────────────
let proxyAddress: `0x${string}`;
let deploymentData: Record<string, unknown> = {};

if (process.env.FEE_CONTROLLER_PROXY) {
  proxyAddress = getAddress(process.env.FEE_CONTROLLER_PROXY) as `0x${string}`;
  if (isLive) {
    deploymentData = await readDeployments(networkName);
  }
} else {
  deploymentData = await readDeployments(networkName);
  const entry = deploymentData["FeeController"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      `FeeController proxy not found in deployments/${networkName}.json`,
    );
    console.error(
      "Deploy first using deploy-fee-controller.ts, or set FEE_CONTROLLER_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  proxyAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── Verify DEFAULT_ADMIN_ROLE ────────────────────────────────────────────────
const fc = await viem.getContractAt("FeeController", proxyAddress);
let hasRole = false;

try {
  const pmAddress = await fc.read.getPermissionManager();
  const pm = await viem.getContractAt("PermissionManager", pmAddress);
  hasRole = await pm.read.hasProtocolRole([DEFAULT_ADMIN_ROLE, callerAddress]);
} catch {
  console.warn(
    "Could not verify DEFAULT_ADMIN_ROLE. Proceeding, but the transaction may fail.",
  );
  hasRole = true;
}

if (!hasRole) {
  console.error(
    `Account ${callerAddress} does not have DEFAULT_ADMIN_ROLE on proxy ${proxyAddress}.\n` +
      "Grant it first using scripts/grant-role.ts.",
  );
  process.exit(1);
}

// ─── Read current state ───────────────────────────────────────────────────────
const currentBps = await fc.read.collectibleFeesBps();
const currentEnabled = await fc.read.collectibleFeesEnabled();
const willEnable = !skipEnable && !currentEnabled;

console.log(
  `\nCurrent collectibleFeesBps:     ${currentBps} (${currentBps / 100}%)`,
);
console.log(`Current collectibleFeesEnabled: ${currentEnabled}`);

// ─── Confirmation on live networks ───────────────────────────────────────────
if (isLive) {
  const ok = await confirmUpdate(
    networkName,
    chainId,
    callerAddress,
    proxyAddress,
    currentBps,
    currentEnabled,
    newBps,
    willEnable,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── [1] Set collectible fee bps ─────────────────────────────────────────────
console.log(
  `\n[1/${willEnable ? "2" : "1"}+] Calling setCollectibleFeesBps(${newBps})...`,
);
const bpsTx = await fc.write.setCollectibleFeesBps([newBps], {
  account: callerClient.account,
});
const bpsReceipt = await publicClient.waitForTransactionReceipt({
  hash: bpsTx,
});
console.log(`  tx: ${bpsTx} (block ${bpsReceipt.blockNumber})`);
await sleep(2000);

// ─── [2] Enable collectible fees (if needed) ──────────────────────────────────
let enableTx: `0x${string}` | undefined;
if (willEnable) {
  console.log("[2] Calling setCollectibleFeesEnabled(true)...");
  enableTx = await fc.write.setCollectibleFeesEnabled([true], {
    account: callerClient.account,
  });
  const enableReceipt = await publicClient.waitForTransactionReceipt({
    hash: enableTx,
  });
  console.log(`  tx: ${enableTx} (block ${enableReceipt.blockNumber})`);
  await sleep(2000);
}

// ─── Verify ───────────────────────────────────────────────────────────────────
console.log("[✓] Verifying...");
const verifiedBps = await fc.read.collectibleFeesBps();
const verifiedEnabled = await fc.read.collectibleFeesEnabled();
const expectedEnabled = skipEnable ? currentEnabled : true;

const errors: string[] = [];
if (verifiedBps !== newBps) {
  errors.push(`  collectibleFeesBps: expected ${newBps}, got ${verifiedBps}`);
}
if (verifiedEnabled !== expectedEnabled) {
  errors.push(
    `  collectibleFeesEnabled: expected ${expectedEnabled}, got ${verifiedEnabled}`,
  );
}

if (errors.length > 0) {
  console.error("Verification failed!");
  for (const e of errors) console.error(e);
  process.exit(1);
}

console.log(
  `  collectibleFeesBps:     ${verifiedBps} (${verifiedBps / 100}%) ✓`,
);
console.log(`  collectibleFeesEnabled: ${verifiedEnabled} ✓`);

console.log("\n=== setCollectibleFee Complete ===");
console.log(`Network:  ${networkName} (chainId: ${chainId})`);
console.log(`Proxy:    ${proxyAddress}`);
console.log(`New fee:  ${verifiedBps} bps (${verifiedBps / 100}%)`);
console.log(`Enabled:  ${verifiedEnabled}`);
console.log(`Tx (bps): ${bpsTx}`);
if (enableTx) console.log(`Tx (en):  ${enableTx}`);
console.log("==================================\n");

// ─── Persist to deployments/<network>.json (live networks only) ───────────────
if (isLive) {
  const existing =
    (deploymentData["FeeController"] as Record<string, unknown>) ?? {};
  await saveDeployment(networkName, "FeeController", {
    ...existing,
    collectibleFeesBps: verifiedBps.toString(),
    collectibleFeesEnabled: verifiedEnabled,
    collectibleFeesUpdatedAt: new Date().toISOString(),
  });
  console.log(`Deployment info updated at deployments/${networkName}.json`);
}
