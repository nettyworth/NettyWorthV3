import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ─── DEFAULT_ADMIN_ROLE = bytes32(0) ──────────────────────────────────────────
const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

// ─── ERC-7201 storage slot for PackVRFRouterStorage (base + 3) ───────────────
// Base slot: 0x9e3c7d59c2c1e1a6a0a24454f70b7c4ed3a3a9a9f6e3b3a1c8e7d6c5b4a3a200
// Slot layout (each +1 = next 32-byte word from base):
//   +0  vrfCoordinator (address, 20 bytes, low-order)
//   +1  subscriptionId (uint256)
//   +2  keyHash (bytes32)
//   +3  callbackGasLimit (uint32, 4 bytes, lowest) | requestConfirmations (uint16, next 2 bytes)
// callbackGasLimit lives in the low 4 bytes of slot +3.
const GAS_LIMIT_STORAGE_SLOT =
  "0x9e3c7d59c2c1e1a6a0a24454f70b7c4ed3a3a9a9f6e3b3a1c8e7d6c5b4a3a203" as const;

// ─── Parse CALLBACK_GAS_LIMIT (default 250000) ────────────────────────────────
const rawGasLimit = process.env.CALLBACK_GAS_LIMIT ?? "200000";
const newGasLimit = Number(rawGasLimit);

if (
  !Number.isInteger(newGasLimit) ||
  newGasLimit < 1 ||
  newGasLimit > 4_294_967_295
) {
  console.error(
    `Invalid CALLBACK_GAS_LIMIT: "${rawGasLimit}". Must be a positive integer ≤ 4294967295 (uint32 max).`,
  );
  process.exit(1);
}

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirmUpdate(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
  oldLimit: number,
  newLimit: number,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setCallbackGasLimit Summary ===");
  console.log(`Network:       ${networkName}`);
  console.log(`Chain ID:      ${chainId}`);
  console.log(`Caller:        ${caller}`);
  console.log(`Proxy:         ${proxy}`);
  console.log(`Current Limit: ${oldLimit.toLocaleString()} gas`);
  console.log(`New Limit:     ${newLimit.toLocaleString()} gas`);
  console.log("===================================\n");
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

const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../deployments",
);
const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);

// ─── Resolve proxy address ────────────────────────────────────────────────────
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.PACK_VRF_ROUTER_PROXY) {
  proxyAddress = getAddress(process.env.PACK_VRF_ROUTER_PROXY) as `0x${string}`;
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
      "Deploy first using deploy-pack-machine.ts, or set PACK_VRF_ROUTER_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  const entry = deploymentData["PackVRFRouter"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error("PackVRFRouter proxy address not found in deployment file.");
    console.error("Set PACK_VRF_ROUTER_PROXY to override.");
    process.exit(1);
  }
  proxyAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── Verify DEFAULT_ADMIN_ROLE ────────────────────────────────────────────────
const router = await viem.getContractAt("PackVRFRouter", proxyAddress);
let hasAdminRole = false;

try {
  const pmAddress = await router.read.getPermissionManager();
  const pm = await viem.getContractAt("PermissionManager", pmAddress);
  hasAdminRole = await pm.read.hasProtocolRole([
    DEFAULT_ADMIN_ROLE,
    callerAddress,
  ]);
} catch {
  console.warn(
    "Could not verify DEFAULT_ADMIN_ROLE. Proceeding, but the transaction may fail.",
  );
  hasAdminRole = true;
}

if (!hasAdminRole) {
  console.error(
    `Account ${callerAddress} does not have DEFAULT_ADMIN_ROLE on proxy ${proxyAddress}`,
  );
  process.exit(1);
}

// ─── Read current callbackGasLimit from ERC-7201 storage ─────────────────────
const preSlotValue = await publicClient.getStorageAt({
  address: proxyAddress,
  slot: GAS_LIMIT_STORAGE_SLOT,
});
const currentGasLimit = preSlotValue
  ? Number(BigInt(preSlotValue) & 0xffffffffn)
  : 0;

console.log(
  `\nCurrent callbackGasLimit: ${currentGasLimit.toLocaleString()} gas`,
);

if (currentGasLimit === newGasLimit) {
  console.log(
    `callbackGasLimit is already ${newGasLimit.toLocaleString()} gas. Nothing to do.`,
  );
  process.exit(0);
}

// ─── Confirmation on live networks ────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirmUpdate(
    connection.networkName,
    chainId,
    callerAddress,
    proxyAddress,
    currentGasLimit,
    newGasLimit,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────
console.log(`\n[1/2] Calling setCallbackGasLimit(${newGasLimit})...`);
const txHash = await router.write.setCallbackGasLimit([newGasLimit], {
  account: callerClient.account,
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  tx: ${txHash} (block ${receipt.blockNumber})`);

// ─── Verify via storage slot ──────────────────────────────────────────────────
console.log("[2/2] Verifying...");
const postSlotValue = await publicClient.getStorageAt({
  address: proxyAddress,
  slot: GAS_LIMIT_STORAGE_SLOT,
});
const verifiedLimit = postSlotValue
  ? Number(BigInt(postSlotValue) & 0xffffffffn)
  : 0;

if (verifiedLimit !== newGasLimit) {
  console.error(
    `CRITICAL: Storage mismatch after update! Expected ${newGasLimit}, got ${verifiedLimit}`,
  );
  process.exit(1);
}
console.log(
  `  callbackGasLimit confirmed: ${verifiedLimit.toLocaleString()} gas ✓`,
);

console.log("\n=== setCallbackGasLimit Complete ===");
console.log(`Network:   ${connection.networkName} (chainId: ${chainId})`);
console.log(`Proxy:     ${proxyAddress}`);
console.log(`Old Limit: ${currentGasLimit.toLocaleString()} gas`);
console.log(`New Limit: ${verifiedLimit.toLocaleString()} gas`);
console.log(`Tx:        ${txHash}`);
console.log("=====================================\n");

// ─── Persist to deployments/<network>.json (live networks only) ───────────────
if (connection.networkConfig.type === "http") {
  const routerEntry =
    (deploymentData["PackVRFRouter"] as Record<string, unknown>) ?? {};
  deploymentData["PackVRFRouter"] = {
    ...routerEntry,
    callbackGasLimit: newGasLimit,
    callbackGasLimitUpdatedAt: new Date().toISOString(),
  };

  await writeFile(
    deploymentPath,
    JSON.stringify(deploymentData, null, 2) + "\n",
  );
  console.log(
    `Deployment info updated at deployments/${connection.networkName}.json`,
  );
}
