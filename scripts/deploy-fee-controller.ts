import { network } from "hardhat";
import { encodeFunctionData, getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import {
  readDeployments,
  saveDeployment,
  waitForCode,
} from "./lib/deployments.js";

// ─── Rate-limit guard — pause between steps to avoid 429s on live RPCs ───────
const STEP_DELAY_MS = Number(process.env.DEPLOY_STEP_DELAY_MS ?? "3000");
const sleep = (ms: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, ms));

async function confirm(
  networkName: string,
  chainId: number,
  deployer: string,
  permissionManager: string,
  treasury: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== FeeController Deployment Summary ===");
  console.log(`Network:            ${networkName}`);
  console.log(`Chain ID:           ${chainId}`);
  console.log(`Deployer:           ${deployer}`);
  console.log(`PermissionManager:  ${permissionManager}`);
  console.log(`Treasury:           ${treasury}`);
  console.log("========================================\n");
  const answer = await rl.question("Proceed with deployment? (yes/no): ");
  rl.close();
  return answer.toLowerCase() === "yes";
}

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [deployerClient] = await viem.getWalletClients();
const deployerAddress = deployerClient.account.address;
const chainId = await publicClient.getChainId();

const isLive = connection.networkConfig.type === "http";
const networkName = connection.networkName;

// ─── Resume helper — returns an already-deployed address if chain has code there
async function reuseAddress(
  key: string,
  field: string,
  deployments: Record<string, unknown>,
): Promise<`0x${string}` | undefined> {
  const entry = deployments[key] as Record<string, unknown> | undefined;
  const raw = entry?.[field];
  if (typeof raw !== "string" || !raw.startsWith("0x")) return undefined;
  const addr = getAddress(raw) as `0x${string}`;
  const code = await publicClient.getCode({ address: addr });
  if (!code || code === "0x") {
    console.log(
      `  ⚠ ${key}.${field} found in JSON (${addr}) but no bytecode on chain — will redeploy`,
    );
    return undefined;
  }
  return addr;
}

// ─── Resolve PERMISSION_MANAGER_PROXY ────────────────────────────────────────
let permissionManagerProxy: `0x${string}`;
if (process.env.PERMISSION_MANAGER_PROXY) {
  permissionManagerProxy = getAddress(
    process.env.PERMISSION_MANAGER_PROXY,
  ) as `0x${string}`;
} else if (isLive) {
  const data = await readDeployments(networkName);
  const entry = data["PermissionManager"] as Record<string, unknown> | undefined;
  if (!entry?.proxy) {
    console.error(
      "PermissionManager proxy not found. Set PERMISSION_MANAGER_PROXY or deploy PermissionManager first.",
    );
    process.exit(1);
  }
  permissionManagerProxy = getAddress(entry.proxy as string) as `0x${string}`;
} else {
  console.error("Set PERMISSION_MANAGER_PROXY env var.");
  process.exit(1);
}

// ─── Resolve TREASURY ────────────────────────────────────────────────────────
let treasury: `0x${string}`;
if (process.env.TREASURY) {
  treasury = getAddress(process.env.TREASURY) as `0x${string}`;
} else {
  console.error(
    "TREASURY env var is required (platform fee recipient address).",
  );
  process.exit(1);
}

// ─── Confirmation prompt on live networks ────────────────────────────────────
if (isLive) {
  const ok = await confirm(
    networkName,
    chainId,
    deployerAddress,
    permissionManagerProxy,
    treasury,
  );
  if (!ok) {
    console.log("Deployment cancelled.");
    process.exit(0);
  }
}

// Re-read after confirmation so interactive pause doesn't matter.
const savedDeployments = isLive ? await readDeployments(networkName) : {};

// ─── [1/3]+[2/3] Deploy FeeController (impl + proxy) ─────────────────────────
console.log("\n[1/3] Deploying FeeController implementation...");

let implAddress = await reuseAddress(
  "FeeController",
  "implementation",
  savedDeployments,
);
let proxyAddress = await reuseAddress(
  "FeeController",
  "proxy",
  savedDeployments,
);

if (implAddress && proxyAddress) {
  console.log(`  ↻ reusing FeeController impl  ${implAddress}`);
  console.log(`  ↻ reusing FeeController proxy ${proxyAddress}`);
} else {
  if (!implAddress) {
    const impl = await viem.deployContract("FeeController");
    implAddress = impl.address;
    console.log(`  Implementation: ${implAddress}`);
    // Checkpoint impl immediately so a proxy-deploy failure doesn't lose it.
    if (isLive) {
      await saveDeployment(networkName, "FeeController", {
        implementation: implAddress,
        deployedAt: new Date().toISOString(),
      });
    }
  } else {
    console.log(`  ↻ reusing FeeController impl ${implAddress}`);
  }

  console.log("[2/3] Deploying ERC1967 proxy...");
  const implContract = await viem.getContractAt("FeeController", implAddress);
  const initData = encodeFunctionData({
    abi: implContract.abi,
    functionName: "initialize",
    args: [permissionManagerProxy, treasury],
  });
  await waitForCode(publicClient, implAddress);
  const proxy = await viem.deployContract("ERC1967ProxyHelper", [
    implAddress,
    initData,
  ]);
  proxyAddress = proxy.address;
  console.log(`  Proxy: ${proxyAddress}`);
}

if (isLive) {
  await saveDeployment(networkName, "FeeController", {
    proxy: proxyAddress,
    implementation: implAddress,
    permissionManager: permissionManagerProxy,
    treasury,
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [3/3] Verify deployment ──────────────────────────────────────────────────
console.log("[3/3] Verifying deployment...");
const fc = await viem.getContractAt("FeeController", proxyAddress);

const actualTreasury = await fc.read.protocolFeeRecipient();
const collectibleBps = await fc.read.collectibleFeesBps();
const redemptionBps = await fc.read.redemptionFeeBps();
const collectibleEnabled = await fc.read.collectibleFeesEnabled();
const redemptionEnabled = await fc.read.redemptionFeeEnabled();

const errors: string[] = [];
if (actualTreasury.toLowerCase() !== treasury.toLowerCase()) {
  errors.push(`  treasury: expected "${treasury}", got "${actualTreasury}"`);
}
if (collectibleBps !== 500)
  errors.push(`  collectibleFeesBps: expected 500, got ${collectibleBps}`);
if (redemptionBps !== 500)
  errors.push(`  redemptionFeeBps: expected 500, got ${redemptionBps}`);
if (!collectibleEnabled)
  errors.push("  collectibleFeesEnabled: expected true");
if (!redemptionEnabled) errors.push("  redemptionFeeEnabled: expected true");

if (errors.length > 0) {
  console.error("Verification failed!");
  for (const e of errors) console.error(e);
  process.exit(1);
}

console.log("\n=== FeeController Deployment Successful ===");
console.log(`Network:              ${networkName} (chainId: ${chainId})`);
console.log(`Implementation:       ${implAddress}`);
console.log(`Proxy:                ${proxyAddress}`);
console.log(`Treasury:             ${actualTreasury}`);
console.log(`Collectible Fee:      ${collectibleBps} bps (enabled: ${collectibleEnabled})`);
console.log(`Redemption Fee:       ${redemptionBps} bps (enabled: ${redemptionEnabled})`);
console.log("===========================================\n");

// ─── Final checkpoint with verified values ────────────────────────────────────
if (isLive) {
  await saveDeployment(networkName, "FeeController", {
    proxy: proxyAddress,
    implementation: implAddress,
    permissionManager: permissionManagerProxy,
    treasury: actualTreasury,
    collectibleFeesBps: collectibleBps.toString(),
    redemptionFeeBps: redemptionBps.toString(),
    deployedAt: new Date().toISOString(),
  });
  console.log(`Deployment info saved to deployments/${networkName}.json`);
}
