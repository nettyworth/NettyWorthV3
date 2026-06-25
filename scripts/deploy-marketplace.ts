import { network } from "hardhat";
import { encodeFunctionData, getAddress, keccak256, toBytes } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

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

const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../deployments",
);
const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);

async function readDeployments(): Promise<Record<string, unknown>> {
  try {
    return JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    return {};
  }
}

function resolveFromEnvOrDeployments(
  envKey: string,
  deploymentKey: string,
  data: Record<string, unknown>,
  label: string,
): `0x${string}` {
  if (process.env[envKey]) {
    return getAddress(process.env[envKey]!) as `0x${string}`;
  }
  if (connection.networkConfig.type === "http") {
    const entry = data[deploymentKey] as Record<string, unknown> | undefined;
    if (entry?.proxy) return getAddress(entry.proxy as string) as `0x${string}`;
  }
  console.error(
    `${label} not found. Set ${envKey} env var or deploy ${deploymentKey} first.`,
  );
  process.exit(1);
}

const data = await readDeployments();

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

// ─── Confirmation prompt ──────────────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirm(
    connection.networkName,
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

// ─── [1/6] Deploy implementation ─────────────────────────────────────────────
console.log("\n[1/6] Deploying NettyWorthMarketplace implementation...");
const impl = await viem.deployContract("NettyWorthMarketplace");
console.log(`  Implementation: ${impl.address}`);

// ─── [2/6] Encode initialize calldata ────────────────────────────────────────
console.log("[2/6] Encoding initialize calldata...");
const initData = encodeFunctionData({
  abi: impl.abi,
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

// ─── [3/6] Deploy ERC-1967 proxy ─────────────────────────────────────────────
console.log("[3/6] Deploying ERC1967 proxy...");
const proxy = await viem.deployContract("ERC1967ProxyHelper", [
  impl.address,
  initData,
]);
console.log(`  Proxy: ${proxy.address}`);

// ─── [4/6] Wiring: authorize marketplace on lending pool ─────────────────────
console.log(
  "[4/6] Authorizing marketplace on AssetLendingPool (setMarketplace)...",
);
const pool = await viem.getContractAt("AssetLendingPool", lendingPoolProxy);
const hash = await pool.write.setMarketplace([proxy.address]);
console.log(`  pool.marketplace = ${proxy.address}`);
await publicClient.waitForTransactionReceipt({ hash });

// ─── [5/6] Wiring: configure AssetNFT shipment refs (if env vars provided) ───
console.log("[5/6] Configuring AssetNFT shipment references...");
const nft = await viem.getContractAt("AssetNFT", assetNFTProxy);
if (process.env.SKIP_NFT_WIRING !== "true") {
  let hash = await nft.write.setPaymentToken([paymentToken]);
  await publicClient.waitForTransactionReceipt({ hash });
  hash = await nft.write.setTreasury([treasury]);
  await publicClient.waitForTransactionReceipt({ hash });
  hash = await nft.write.setFeeController([feeControllerProxy]);
  await publicClient.waitForTransactionReceipt({ hash });
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

// ─── [6/6] Verify deployment ──────────────────────────────────────────────────
console.log("[6/6] Verifying deployment...");
const market = await viem.getContractAt("NettyWorthMarketplace", proxy.address);
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
if (actualMarketplace.toLowerCase() !== proxy.address.toLowerCase()) {
  errors.push(
    `  pool.marketplace: expected "${proxy.address}", got "${actualMarketplace}"`,
  );
}

if (errors.length > 0) {
  console.error("Verification failed!");
  for (const e of errors) console.error(e);
  process.exit(1);
}

console.log("\n=== NettyWorthMarketplace Deployment Successful ===");
console.log(
  `Network:              ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Implementation:       ${impl.address}`);
console.log(`Proxy:                ${proxy.address}`);
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

// ─── Persist deployment record ────────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  let existing: Record<string, unknown> = {};
  try {
    existing = JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    /**/
  }

  existing["NettyWorthMarketplace"] = {
    proxy: proxy.address,
    implementation: impl.address,
    permissionManager: permissionManagerProxy,
    feeController: feeControllerProxy,
    lendingPool: lendingPoolProxy,
    assetNFT: assetNFTProxy,
    paymentToken,
    treasury,
    deployedAt: new Date().toISOString(),
  };

  await mkdir(deploymentsDir, { recursive: true });
  await writeFile(deploymentPath, JSON.stringify(existing, null, 2) + "\n");
  console.log(
    `Deployment info saved to deployments/${connection.networkName}.json`,
  );
}
