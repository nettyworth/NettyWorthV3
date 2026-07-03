import { network } from "hardhat";
import { encodeFunctionData, getAddress, keccak256, toBytes } from "viem";
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

// MARKETPLACE_ROLE = keccak256("MARKETPLACE_ROLE") — matches contracts/lib/Roles.sol
const MARKETPLACE_ROLE = keccak256(toBytes("MARKETPLACE_ROLE"));

async function confirm(
  networkName: string,
  chainId: number,
  deployer: string,
  permissionManager: string,
  feeController: string,
  lendingPool: string,
  assetNFT: string,
  paymentToken: string,
  treasury: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== NettyWorthMarketplace Deployment Summary ===");
  console.log(`Network:            ${networkName}`);
  console.log(`Chain ID:           ${chainId}`);
  console.log(`Deployer:           ${deployer}`);
  console.log(`PermissionManager:  ${permissionManager}`);
  console.log(`FeeController:      ${feeController}`);
  console.log(`LendingPool:        ${lendingPool}`);
  console.log(`AssetNFT:           ${assetNFT}`);
  console.log(`Payment Token:      ${paymentToken}`);
  console.log(`Treasury:           ${treasury}`);
  console.log("================================================\n");
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

// ─── Resolve dependencies from env or deployments JSON ───────────────────────
function resolveFromEnvOrDeployments(
  envKey: string,
  deploymentKey: string,
  data: Record<string, unknown>,
  label: string,
): `0x${string}` {
  if (process.env[envKey]) {
    return getAddress(process.env[envKey]!) as `0x${string}`;
  }
  if (isLive) {
    const entry = data[deploymentKey] as Record<string, unknown> | undefined;
    if (entry?.proxy) return getAddress(entry.proxy as string) as `0x${string}`;
  }
  console.error(
    `${label} not found. Set ${envKey} env var or deploy ${deploymentKey} first.`,
  );
  process.exit(1);
}

const data = isLive ? await readDeployments(networkName) : {};

const permissionManagerProxy = resolveFromEnvOrDeployments(
  "PERMISSION_MANAGER_PROXY",
  "PermissionManager",
  data,
  "PermissionManager proxy",
);
const feeControllerProxy = resolveFromEnvOrDeployments(
  "FEE_CONTROLLER_PROXY",
  "FeeController",
  data,
  "FeeController proxy",
);
const lendingPoolProxy = resolveFromEnvOrDeployments(
  "LENDING_POOL_PROXY",
  "AssetLendingPool",
  data,
  "AssetLendingPool proxy",
);
const lendingPoolConfigProxy = resolveFromEnvOrDeployments(
  "LENDING_POOL_CONFIG_PROXY",
  "AssetLendingPoolConfig",
  data,
  "AssetLendingPoolConfig proxy",
);
const assetNFTProxy = resolveFromEnvOrDeployments(
  "ASSET_NFT_PROXY",
  "AssetNFT",
  data,
  "AssetNFT proxy",
);

let paymentToken: `0x${string}`;
if (process.env.PAYMENT_TOKEN) {
  paymentToken = getAddress(process.env.PAYMENT_TOKEN) as `0x${string}`;
} else {
  console.error(
    "PAYMENT_TOKEN env var is required (ERC20 address, e.g. USDC).",
  );
  process.exit(1);
}

let treasury: `0x${string}`;
if (process.env.TREASURY) {
  treasury = getAddress(process.env.TREASURY) as `0x${string}`;
} else {
  console.error(
    "TREASURY env var is required (platform fee recipient address).",
  );
  process.exit(1);
}

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
if (isLive) {
  const ok = await confirm(
    networkName,
    chainId,
    deployerAddress,
    permissionManagerProxy,
    feeControllerProxy,
    lendingPoolProxy,
    assetNFTProxy,
    paymentToken,
    treasury,
  );
  if (!ok) {
    console.log("Deployment cancelled.");
    process.exit(0);
  }
}

// Re-read after confirmation so interactive pause doesn't matter.
const savedDeployments = isLive ? await readDeployments(networkName) : {};

// ─── [1/6]+[2/6] Deploy NettyWorthMarketplace (impl + proxy) ─────────────────
console.log("\n[1/6] Deploying NettyWorthMarketplace implementation...");

let implAddress = await reuseAddress(
  "NettyWorthMarketplace",
  "implementation",
  savedDeployments,
);
let proxyAddress = await reuseAddress(
  "NettyWorthMarketplace",
  "proxy",
  savedDeployments,
);

if (implAddress && proxyAddress) {
  console.log(`  ↻ reusing NettyWorthMarketplace impl  ${implAddress}`);
  console.log(`  ↻ reusing NettyWorthMarketplace proxy ${proxyAddress}`);
} else {
  if (!implAddress) {
    const impl = await viem.deployContract("NettyWorthMarketplace");
    implAddress = impl.address;
    console.log(`  Implementation: ${implAddress}`);
    // Checkpoint impl immediately so a proxy-deploy failure doesn't lose it.
    if (isLive) {
      await saveDeployment(networkName, "NettyWorthMarketplace", {
        implementation: implAddress,
        deployedAt: new Date().toISOString(),
      });
    }
  } else {
    console.log(`  ↻ reusing NettyWorthMarketplace impl ${implAddress}`);
  }

  console.log("[2/6] Deploying ERC1967 proxy...");
  const implContract = await viem.getContractAt(
    "NettyWorthMarketplace",
    implAddress,
  );
  const initData = encodeFunctionData({
    abi: implContract.abi,
    functionName: "initialize",
    args: [
      permissionManagerProxy,
      feeControllerProxy,
      lendingPoolProxy,
      assetNFTProxy,
      paymentToken,
      treasury,
    ],
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
  await saveDeployment(networkName, "NettyWorthMarketplace", {
    proxy: proxyAddress,
    implementation: implAddress,
    permissionManager: permissionManagerProxy,
    feeController: feeControllerProxy,
    lendingPool: lendingPoolProxy,
    assetNFT: assetNFTProxy,
    paymentToken,
    treasury,
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [3/6] Wiring: authorize marketplace on lending pool (idempotent) ─────────
// getMarketplace is on AssetLendingPool; setMarketplace is on AssetLendingPoolConfig
// (which AssetLendingPool inherits). Use the config ABI for the write.
console.log(
  "[3/6] Authorizing marketplace on AssetLendingPool (setMarketplace)...",
);
const pool = await viem.getContractAt("AssetLendingPool", lendingPoolProxy);
const poolConfig = await viem.getContractAt(
  "AssetLendingPoolConfig",
  lendingPoolConfigProxy,
);

const currentMarketplace = await pool.read.getMarketplace();
if (currentMarketplace.toLowerCase() === proxyAddress.toLowerCase()) {
  console.log(`  ↻ skipping setMarketplace (already set)`);
} else {
  const owner = await poolConfig.read.owner();
  console.log("owner ", owner);
  const hash = await poolConfig.write.setMarketplace([proxyAddress]);
  await publicClient.waitForTransactionReceipt({ hash });
  console.log(`  pool.marketplace = ${proxyAddress}`);
}
await sleep(STEP_DELAY_MS);

// ─── [4/6] Wiring: configure AssetNFT shipment refs (if env vars provided) ───
// AssetNFT does not expose getters for these fields, so this step is not
// idempotent. Set SKIP_NFT_WIRING=true when re-running after a partial failure
// if NFT wiring already completed.
console.log("[4/6] Configuring AssetNFT shipment references...");
const nft = await viem.getContractAt("AssetNFT", assetNFTProxy);
if (process.env.SKIP_NFT_WIRING !== "true") {
  await sleep(STEP_DELAY_MS);
  let hash = await nft.write.setPaymentToken([paymentToken]);
  await publicClient.waitForTransactionReceipt({ hash });
  await sleep(STEP_DELAY_MS);
  hash = await nft.write.setTreasury([treasury]);
  await publicClient.waitForTransactionReceipt({ hash });
  await sleep(STEP_DELAY_MS);
  hash = await nft.write.setFeeController([feeControllerProxy]);
  await publicClient.waitForTransactionReceipt({ hash });
  await sleep(STEP_DELAY_MS);
  hash = await nft.write.setLendingPool([lendingPoolProxy]);
  await publicClient.waitForTransactionReceipt({ hash });
  console.log(
    "  AssetNFT: paymentToken, treasury, feeController, lendingPool set",
  );
} else {
  console.log(
    "  SKIP_NFT_WIRING=true — skipping AssetNFT wiring (call setters manually)",
  );
}
await sleep(STEP_DELAY_MS);

// ─── [5/6] Verify deployment ──────────────────────────────────────────────────
console.log("[5/6] Verifying deployment...");
const pm = await viem.getContractAt(
  "PermissionManager",
  permissionManagerProxy,
);

const actualMarketplace = await pool.read.getMarketplace();
const adminHasMarketplaceRole = await pm.read.hasProtocolRole([
  MARKETPLACE_ROLE,
  deployerAddress,
]);

const errors: string[] = [];
if (actualMarketplace.toLowerCase() !== proxyAddress.toLowerCase()) {
  errors.push(
    `  pool.marketplace: expected "${proxyAddress}", got "${actualMarketplace}"`,
  );
}

if (errors.length > 0) {
  console.error("Verification failed!");
  for (const e of errors) console.error(e);
  process.exit(1);
}

console.log("\n=== NettyWorthMarketplace Deployment Successful ===");
console.log(`Network:              ${networkName} (chainId: ${chainId})`);
console.log(`Implementation:       ${implAddress}`);
console.log(`Proxy:                ${proxyAddress}`);
console.log(`PermissionManager:    ${permissionManagerProxy}`);
console.log(`FeeController:        ${feeControllerProxy}`);
console.log(`LendingPool:          ${lendingPoolProxy}`);
console.log(`AssetNFT:             ${assetNFTProxy}`);
console.log(`PaymentToken:         ${paymentToken}`);
console.log(`Treasury:             ${treasury}`);
console.log(`pool.marketplace:     ${actualMarketplace} ✓`);
console.log(
  `Admin MARKETPLACE_ROLE: ${adminHasMarketplaceRole ? "granted ✓" : "NOT granted (grant manually for keeper)"}`,
);
console.log("====================================================\n");

// ─── [6/6] Final checkpoint ───────────────────────────────────────────────────
if (isLive) {
  await saveDeployment(networkName, "NettyWorthMarketplace", {
    proxy: proxyAddress,
    implementation: implAddress,
    permissionManager: permissionManagerProxy,
    feeController: feeControllerProxy,
    lendingPool: lendingPoolProxy,
    assetNFT: assetNFTProxy,
    paymentToken,
    treasury,
    deployedAt: new Date().toISOString(),
  });
  console.log(`Deployment info saved to deployments/${networkName}.json`);
}
