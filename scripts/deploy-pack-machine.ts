import { network } from "hardhat";
import { encodeFunctionData, getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ─── VRF & forwarder parameters (override via environment variables) ──────────
const TRUSTED_FORWARDER = (process.env.TRUSTED_FORWARDER ??
  "0x0000000000000000000000000000000000000000") as `0x${string}`;
const VRF_CALLBACK_GAS_LIMIT = Number(
  process.env.VRF_CALLBACK_GAS_LIMIT ?? "250000",
);
const VRF_REQUEST_CONFIRMATIONS = Number(
  process.env.VRF_REQUEST_CONFIRMATIONS ?? "3",
);

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirm(
  networkName: string,
  chainId: number,
  deployer: string,
  permissionManagerProxy: string,
  assetNFTProxy: string,
  paymentToken: string,
  financeWallet: string,
  vrfCoordinator: string,
  vrfSubscriptionId: bigint,
  vrfKeyHash: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== Deployment Summary ===");
  console.log(`Network:               ${networkName}`);
  console.log(`Chain ID:              ${chainId}`);
  console.log(`Deployer:              ${deployer}`);
  console.log(`PermissionManager:     ${permissionManagerProxy}`);
  console.log(`AssetNFT:              ${assetNFTProxy}`);
  console.log(`Payment Token:         ${paymentToken}`);
  console.log(`Finance Wallet:        ${financeWallet}`);
  console.log(`Trusted Forwarder:     ${TRUSTED_FORWARDER}`);
  console.log(`VRF Coordinator:       ${vrfCoordinator}`);
  console.log(`VRF Subscription ID:   ${vrfSubscriptionId}`);
  console.log(`VRF Key Hash:          ${vrfKeyHash}`);
  console.log(`VRF Callback Gas:      ${VRF_CALLBACK_GAS_LIMIT}`);
  console.log(`VRF Confirmations:     ${VRF_REQUEST_CONFIRMATIONS}`);
  console.log("==========================\n");
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

// ─── Deployments JSON helpers ─────────────────────────────────────────────────
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

// ─── Resolve PERMISSION_MANAGER_PROXY ────────────────────────────────────────
let permissionManagerProxy: `0x${string}`;
if (process.env.PERMISSION_MANAGER_PROXY) {
  permissionManagerProxy = getAddress(
    process.env.PERMISSION_MANAGER_PROXY,
  ) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
  const data = await readDeployments();
  const entry = data["PermissionManager"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "PermissionManager proxy not found. Set PERMISSION_MANAGER_PROXY env var or deploy the PermissionManager first.",
    );
    process.exit(1);
  }
  permissionManagerProxy = getAddress(entry.proxy as string) as `0x${string}`;
} else {
  console.error(
    "Set PERMISSION_MANAGER_PROXY env var to the deployed PermissionManager proxy address.",
  );
  process.exit(1);
}

// ─── Resolve ASSET_NFT_PROXY ──────────────────────────────────────────────────
let assetNFTProxy: `0x${string}`;
if (process.env.ASSET_NFT_PROXY) {
  assetNFTProxy = getAddress(process.env.ASSET_NFT_PROXY) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
  const data = await readDeployments();
  const entry = data["AssetNFT"] as Record<string, unknown> | undefined;
  if (!entry?.proxy) {
    console.error(
      "AssetNFT proxy not found. Set ASSET_NFT_PROXY env var or deploy AssetNFT first.",
    );
    process.exit(1);
  }
  assetNFTProxy = getAddress(entry.proxy as string) as `0x${string}`;
} else {
  console.error(
    "Set ASSET_NFT_PROXY env var to the deployed AssetNFT proxy address.",
  );
  process.exit(1);
}

// ─── Resolve PAYMENT_TOKEN (required) ────────────────────────────────────────
if (!process.env.PAYMENT_TOKEN) {
  console.error(
    "PAYMENT_TOKEN env var is required (ERC20 token address, e.g. USDC).",
  );
  process.exit(1);
}
const paymentToken = getAddress(process.env.PAYMENT_TOKEN) as `0x${string}`;

// ─── Resolve FINANCE_WALLET (required) ───────────────────────────────────────
if (!process.env.FINANCE_WALLET) {
  console.error(
    "FINANCE_WALLET env var is required (address that receives pack-open payments).",
  );
  process.exit(1);
}
const financeWallet = getAddress(process.env.FINANCE_WALLET) as `0x${string}`;

// ─── Resolve VRF parameters (required) ───────────────────────────────────────
if (!process.env.VRF_COORDINATOR) {
  console.error(
    "VRF_COORDINATOR env var is required (Chainlink VRF v2.5 coordinator address).",
  );
  process.exit(1);
}
const vrfCoordinator = getAddress(process.env.VRF_COORDINATOR) as `0x${string}`;

if (!process.env.VRF_SUBSCRIPTION_ID) {
  console.error(
    "VRF_SUBSCRIPTION_ID env var is required (funded Chainlink VRF subscription ID).",
  );
  process.exit(1);
}
const vrfSubscriptionId = BigInt(process.env.VRF_SUBSCRIPTION_ID);

if (!process.env.VRF_KEY_HASH) {
  console.error(
    "VRF_KEY_HASH env var is required (Chainlink VRF key hash / gas lane, 0x-prefixed 32-byte hex).",
  );
  process.exit(1);
}
const vrfKeyHash = process.env.VRF_KEY_HASH as `0x${string}`;

// ─── Confirmation on live networks ────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirm(
    connection.networkName,
    chainId,
    deployerAddress,
    permissionManagerProxy,
    assetNFTProxy,
    paymentToken,
    financeWallet,
    vrfCoordinator,
    vrfSubscriptionId,
    vrfKeyHash,
  );
  if (!ok) {
    console.log("Deployment cancelled.");
    process.exit(0);
  }
}

// ─── [1/6] Deploy PackVRFRouter (UUPS proxy) ─────────────────────────────────
console.log("\n[1/6] Deploying PackVRFRouter...");
const vrfRouterImpl = await viem.deployContract("PackVRFRouter");
const vrfRouterInitData = encodeFunctionData({
  abi: vrfRouterImpl.abi,
  functionName: "initialize",
  args: [
    permissionManagerProxy,
    vrfCoordinator,
    vrfSubscriptionId,
    vrfKeyHash,
    VRF_CALLBACK_GAS_LIMIT,
    VRF_REQUEST_CONFIRMATIONS,
  ],
});
const vrfRouterProxy = await viem.deployContract("ERC1967ProxyHelper", [
  vrfRouterImpl.address,
  vrfRouterInitData,
]);
console.log(`  Implementation: ${vrfRouterImpl.address}`);
console.log(`  Proxy:          ${vrfRouterProxy.address}`);

// ─── [2/6] Deploy PackMachine implementation (EIP-1167 clone target — no proxy)
console.log("[2/6] Deploying PackMachine implementation (clone target)...");
const packMachineImpl = await viem.deployContract("PackMachine", [
  TRUSTED_FORWARDER,
]);
console.log(`  Implementation: ${packMachineImpl.address}`);

// ─── [3/6] Deploy PackMachineFactory (UUPS proxy) ────────────────────────────
console.log("[3/6] Deploying PackMachineFactory...");
const factoryImpl = await viem.deployContract("PackMachineFactory", [
  TRUSTED_FORWARDER,
]);
const factoryInitData = encodeFunctionData({
  abi: factoryImpl.abi,
  functionName: "initialize",
  args: [permissionManagerProxy, assetNFTProxy, paymentToken, financeWallet],
});
const factoryProxy = await viem.deployContract("ERC1967ProxyHelper", [
  factoryImpl.address,
  factoryInitData,
]);
console.log(`  Implementation: ${factoryImpl.address}`);
console.log(`  Proxy:          ${factoryProxy.address}`);

// ─── [4/6] Deploy BuybackPool (UUPS proxy) ───────────────────────────────────
// BuybackPool.initialize takes the factory proxy address — deploy after factory
// to resolve the circular dependency. factory.setBuybackPool is called in step 5.
console.log("[4/6] Deploying BuybackPool...");
const buybackImpl = await viem.deployContract("BuybackPool");
const buybackInitData = encodeFunctionData({
  abi: buybackImpl.abi,
  functionName: "initialize",
  args: [
    permissionManagerProxy,
    assetNFTProxy,
    paymentToken,
    financeWallet,
    factoryProxy.address,
  ],
});
const buybackProxy = await viem.deployContract("ERC1967ProxyHelper", [
  buybackImpl.address,
  buybackInitData,
]);
console.log(`  Implementation: ${buybackImpl.address}`);
console.log(`  Proxy:          ${buybackProxy.address}`);

// ─── [5/6] Wire PackMachineFactory ───────────────────────────────────────────
// setImplementation, setPackVRFRouter, setBuybackPool are all gated by
// DEFAULT_ADMIN_ROLE — the deployer holds this via PermissionManager.initialize.
console.log("[5/6] Wiring PackMachineFactory...");
const factory = await viem.getContractAt(
  "PackMachineFactory",
  factoryProxy.address,
);
let txHash = await factory.write.setImplementation([packMachineImpl.address]);
await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  setImplementation(${packMachineImpl.address}) ✓`);
txHash = await factory.write.setPackVRFRouter([vrfRouterProxy.address]);
await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  setPackVRFRouter(${vrfRouterProxy.address}) ✓`);
txHash = await factory.write.setBuybackPool([buybackProxy.address]);
await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  setBuybackPool(${buybackProxy.address}) ✓`);

// ─── [6/6] Verify deployments ────────────────────────────────────────────────
console.log("[6/6] Verifying deployments...");

const router = await viem.getContractAt(
  "PackVRFRouter",
  vrfRouterProxy.address,
);
const buyback = await viem.getContractAt("BuybackPool", buybackProxy.address);

const routerPM = await router.read.getPermissionManager();
const routerCoordinator = await router.read.vrfCoordinator();
const routerSubId = await router.read.subscriptionId();
const factoryPM = await factory.read.getPermissionManager();
const factoryVRFRouter = await factory.read.packVRFRouter();
const factoryBuybackPool = await factory.read.buybackPool();
const factoryAssetNFT = await factory.read.assetNFT();
const factoryPaymentToken = await factory.read.paymentToken();
const buybackPM = await buyback.read.getPermissionManager();
const buybackDefaultBps = await buyback.read.getDefaultBuybackBps();

const errors: string[] = [];

if (routerPM.toLowerCase() !== permissionManagerProxy.toLowerCase()) {
  errors.push(
    `  PackVRFRouter.permissionManager: expected "${permissionManagerProxy}", got "${routerPM}"`,
  );
}
if (routerCoordinator.toLowerCase() !== vrfCoordinator.toLowerCase()) {
  errors.push(
    `  PackVRFRouter.vrfCoordinator: expected "${vrfCoordinator}", got "${routerCoordinator}"`,
  );
}
if (routerSubId !== vrfSubscriptionId) {
  errors.push(
    `  PackVRFRouter.subscriptionId: expected "${vrfSubscriptionId}", got "${routerSubId}"`,
  );
}
if (factoryPM.toLowerCase() !== permissionManagerProxy.toLowerCase()) {
  errors.push(
    `  PackMachineFactory.permissionManager: expected "${permissionManagerProxy}", got "${factoryPM}"`,
  );
}
if (factoryVRFRouter.toLowerCase() !== vrfRouterProxy.address.toLowerCase()) {
  errors.push(
    `  PackMachineFactory.packVRFRouter: expected "${vrfRouterProxy.address}", got "${factoryVRFRouter}"`,
  );
}
if (factoryBuybackPool.toLowerCase() !== buybackProxy.address.toLowerCase()) {
  errors.push(
    `  PackMachineFactory.buybackPool: expected "${buybackProxy.address}", got "${factoryBuybackPool}"`,
  );
}
if (factoryAssetNFT.toLowerCase() !== assetNFTProxy.toLowerCase()) {
  errors.push(
    `  PackMachineFactory.assetNFT: expected "${assetNFTProxy}", got "${factoryAssetNFT}"`,
  );
}
if (factoryPaymentToken.toLowerCase() !== paymentToken.toLowerCase()) {
  errors.push(
    `  PackMachineFactory.paymentToken: expected "${paymentToken}", got "${factoryPaymentToken}"`,
  );
}
if (buybackPM.toLowerCase() !== permissionManagerProxy.toLowerCase()) {
  errors.push(
    `  BuybackPool.permissionManager: expected "${permissionManagerProxy}", got "${buybackPM}"`,
  );
}
if (buybackDefaultBps !== 8000) {
  errors.push(
    `  BuybackPool.defaultBuybackBps: expected 8000, got ${buybackDefaultBps}`,
  );
}

if (errors.length > 0) {
  console.error("Verification failed!");
  for (const e of errors) console.error(e);
  process.exit(1);
}

// ─── Summary ──────────────────────────────────────────────────────────────────
console.log("\n=== Deployment Successful ===");
console.log(
  `Network:               ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`\nPackVRFRouter`);
console.log(`  Implementation:    ${vrfRouterImpl.address}`);
console.log(`  Proxy:             ${vrfRouterProxy.address}`);
console.log(`\nPackMachine (clone target)`);
console.log(`  Implementation:    ${packMachineImpl.address}`);
console.log(`\nPackMachineFactory`);
console.log(`  Implementation:    ${factoryImpl.address}`);
console.log(`  Proxy:             ${factoryProxy.address}`);
console.log(`\nBuybackPool`);
console.log(`  Implementation:    ${buybackImpl.address}`);
console.log(`  Proxy:             ${buybackProxy.address}`);
console.log(`\nWiring`);
console.log(`  Factory.implementation:  ${packMachineImpl.address} ✓`);
console.log(`  Factory.packVRFRouter:   ${vrfRouterProxy.address} ✓`);
console.log(`  Factory.buybackPool:     ${buybackProxy.address} ✓`);
console.log("=============================\n");

console.log("⚠️  Remaining manual steps before packs can open:");
console.log(
  `  1. Add PackVRFRouter proxy as a consumer on the Chainlink VRF subscription:`,
);
console.log(
  `       subscription ${vrfSubscriptionId} → add consumer ${vrfRouterProxy.address}`,
);
console.log(
  `  2. Create a PackMachine clone (requires PACK_OPERATOR_ROLE on PermissionManager):`,
);
console.log(
  `       factory.createPackMachine(pricePerPack, cardsPerPack, startTime)`,
);
console.log(
  `  3. Register the clone with the VRF router (PACK_OPERATOR_ROLE):`,
);
console.log(`       packVRFRouter.setAuthorizedPackMachine(clone, true)`);
console.log(`  4. Register the clone with BuybackPool (PACK_OPERATOR_ROLE):`);
console.log(`       buybackPool.registerPackMachine(clone, true)`);
console.log(
  `  5. Configure buyback on the clone, deposit NFT inventory, and open packs.\n`,
);

// ─── Persist deployment record (live networks only) ───────────────────────────
if (connection.networkConfig.type === "http") {
  const outPath = join(deploymentsDir, `${connection.networkName}.json`);

  let existing: Record<string, unknown> = {};
  try {
    existing = JSON.parse(await readFile(outPath, "utf8"));
  } catch {
    // file doesn't exist yet — start fresh
  }

  existing["PackVRFRouter"] = {
    proxy: vrfRouterProxy.address,
    implementation: vrfRouterImpl.address,
    permissionManager: permissionManagerProxy,
    vrfCoordinator,
    subscriptionId: vrfSubscriptionId.toString(),
    keyHash: vrfKeyHash,
    callbackGasLimit: VRF_CALLBACK_GAS_LIMIT,
    requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
    deployedAt: new Date().toISOString(),
  };
  existing["PackMachineImplementation"] = {
    implementation: packMachineImpl.address,
    trustedForwarder: TRUSTED_FORWARDER,
    deployedAt: new Date().toISOString(),
  };
  existing["PackMachineFactory"] = {
    proxy: factoryProxy.address,
    implementation: factoryImpl.address,
    permissionManager: permissionManagerProxy,
    packMachineImplementation: packMachineImpl.address,
    packVRFRouter: vrfRouterProxy.address,
    buybackPool: buybackProxy.address,
    assetNFT: assetNFTProxy,
    paymentToken,
    financeWallet,
    trustedForwarder: TRUSTED_FORWARDER,
    deployedAt: new Date().toISOString(),
  };
  existing["BuybackPool"] = {
    proxy: buybackProxy.address,
    implementation: buybackImpl.address,
    permissionManager: permissionManagerProxy,
    assetNFT: assetNFTProxy,
    paymentToken,
    financeWallet,
    factory: factoryProxy.address,
    defaultBuybackBps: buybackDefaultBps,
    deployedAt: new Date().toISOString(),
  };

  await mkdir(deploymentsDir, { recursive: true });
  await writeFile(outPath, JSON.stringify(existing, null, 2) + "\n");
  console.log(
    `Deployment info saved to deployments/${connection.networkName}.json`,
  );
}
