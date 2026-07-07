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

// ─── VRF & forwarder parameters (override via environment variables) ──────────
const TRUSTED_FORWARDER = (process.env.TRUSTED_FORWARDER ??
  "0x0000000000000000000000000000000000000000") as `0x${string}`;
const VRF_CALLBACK_GAS_LIMIT = Number(
  process.env.VRF_CALLBACK_GAS_LIMIT ?? "500000",
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
} else if (isLive) {
  const data = await readDeployments(networkName);
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
if (isLive) {
  const ok = await confirm(
    networkName,
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

// ─── Load existing deployments once for resume checks ────────────────────────
// Re-read after confirmation so interactive pause doesn't matter.
const savedDeployments = isLive ? await readDeployments(networkName) : {};

// ─── [1/8] Deploy PackVRFRouter (UUPS proxy) ─────────────────────────────────
console.log("\n[1/8] Deploying PackVRFRouter...");

let vrfRouterImplAddress = await reuseAddress(
  "PackVRFRouter",
  "implementation",
  savedDeployments,
);
let vrfRouterProxyAddress = await reuseAddress(
  "PackVRFRouter",
  "proxy",
  savedDeployments,
);

if (vrfRouterProxyAddress && vrfRouterImplAddress) {
  console.log(`  ↻ reusing PackVRFRouter impl  ${vrfRouterImplAddress}`);
  console.log(`  ↻ reusing PackVRFRouter proxy ${vrfRouterProxyAddress}`);
} else {
  if (!vrfRouterImplAddress) {
    const vrfRouterImpl = await viem.deployContract("PackVRFRouter");
    vrfRouterImplAddress = vrfRouterImpl.address;
    console.log(`  Implementation: ${vrfRouterImplAddress}`);
    // Checkpoint impl immediately so a proxy-deploy failure doesn't lose it.
    if (isLive) {
      await saveDeployment(networkName, "PackVRFRouter", {
        implementation: vrfRouterImplAddress,
        deployedAt: new Date().toISOString(),
      });
    }
  } else {
    console.log(`  ↻ reusing PackVRFRouter impl ${vrfRouterImplAddress}`);
  }

  const vrfRouterImplContract = await viem.getContractAt(
    "PackVRFRouter",
    vrfRouterImplAddress,
  );
  const vrfRouterInitData = encodeFunctionData({
    abi: vrfRouterImplContract.abi,
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
  await waitForCode(publicClient, vrfRouterImplAddress);
  const vrfRouterProxyContract = await viem.deployContract(
    "ERC1967ProxyHelper",
    [vrfRouterImplAddress, vrfRouterInitData],
  );
  vrfRouterProxyAddress = vrfRouterProxyContract.address;
  console.log(`  Proxy:          ${vrfRouterProxyAddress}`);
}

if (isLive) {
  await saveDeployment(networkName, "PackVRFRouter", {
    proxy: vrfRouterProxyAddress,
    implementation: vrfRouterImplAddress,
    permissionManager: permissionManagerProxy,
    vrfCoordinator,
    subscriptionId: vrfSubscriptionId.toString(),
    keyHash: vrfKeyHash,
    callbackGasLimit: VRF_CALLBACK_GAS_LIMIT,
    requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [2/8] Deploy PackMachine implementation (EIP-1167 clone target — no proxy)
console.log("[2/8] Deploying PackMachine implementation (clone target)...");

let packMachineImplAddress = await reuseAddress(
  "PackMachineImplementation",
  "implementation",
  savedDeployments,
);

if (packMachineImplAddress) {
  console.log(`  ↻ reusing PackMachine impl ${packMachineImplAddress}`);
} else {
  const packMachineImpl = await viem.deployContract("PackMachine", [
    TRUSTED_FORWARDER,
  ]);
  packMachineImplAddress = packMachineImpl.address;
  console.log(`  Implementation: ${packMachineImplAddress}`);
}

if (isLive) {
  await saveDeployment(networkName, "PackMachineImplementation", {
    implementation: packMachineImplAddress,
    trustedForwarder: TRUSTED_FORWARDER,
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [3/8] Deploy PackMachineFactory (UUPS proxy) ────────────────────────────
console.log("[3/8] Deploying PackMachineFactory...");

let factoryImplAddress = await reuseAddress(
  "PackMachineFactory",
  "implementation",
  savedDeployments,
);
let factoryProxyAddress = await reuseAddress(
  "PackMachineFactory",
  "proxy",
  savedDeployments,
);

if (factoryProxyAddress && factoryImplAddress) {
  console.log(`  ↻ reusing PackMachineFactory impl  ${factoryImplAddress}`);
  console.log(`  ↻ reusing PackMachineFactory proxy ${factoryProxyAddress}`);
} else {
  if (!factoryImplAddress) {
    const factoryImpl = await viem.deployContract("PackMachineFactory", [
      TRUSTED_FORWARDER,
    ]);
    factoryImplAddress = factoryImpl.address;
    console.log(`  Implementation: ${factoryImplAddress}`);
    if (isLive) {
      await saveDeployment(networkName, "PackMachineFactory", {
        implementation: factoryImplAddress,
        deployedAt: new Date().toISOString(),
      });
    }
  } else {
    console.log(`  ↻ reusing PackMachineFactory impl ${factoryImplAddress}`);
  }

  const factoryImplContract = await viem.getContractAt(
    "PackMachineFactory",
    factoryImplAddress,
  );
  const factoryInitData = encodeFunctionData({
    abi: factoryImplContract.abi,
    functionName: "initialize",
    args: [permissionManagerProxy, assetNFTProxy, paymentToken, financeWallet],
  });
  await waitForCode(publicClient, factoryImplAddress);
  const factoryProxyContract = await viem.deployContract("ERC1967ProxyHelper", [
    factoryImplAddress,
    factoryInitData,
  ]);
  factoryProxyAddress = factoryProxyContract.address;
  console.log(`  Proxy:          ${factoryProxyAddress}`);
}

if (isLive) {
  await saveDeployment(networkName, "PackMachineFactory", {
    proxy: factoryProxyAddress,
    implementation: factoryImplAddress,
    permissionManager: permissionManagerProxy,
    assetNFT: assetNFTProxy,
    paymentToken,
    financeWallet,
    trustedForwarder: TRUSTED_FORWARDER,
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [4/8] Deploy PackRegistry (UUPS proxy) ──────────────────────────────────
// Must be deployed before BuybackPool wiring so it can be set on the factory.
// Factory is wired to both registries in step 7.
console.log("[4/8] Deploying PackRegistry...");

let registryImplAddress = await reuseAddress(
  "PackRegistry",
  "implementation",
  savedDeployments,
);
let registryProxyAddress = await reuseAddress(
  "PackRegistry",
  "proxy",
  savedDeployments,
);

if (registryProxyAddress && registryImplAddress) {
  console.log(`  ↻ reusing PackRegistry impl  ${registryImplAddress}`);
  console.log(`  ↻ reusing PackRegistry proxy ${registryProxyAddress}`);
} else {
  if (!registryImplAddress) {
    const registryImpl = await viem.deployContract("PackRegistry");
    registryImplAddress = registryImpl.address;
    console.log(`  Implementation: ${registryImplAddress}`);
    if (isLive) {
      await saveDeployment(networkName, "PackRegistry", {
        implementation: registryImplAddress,
        deployedAt: new Date().toISOString(),
      });
    }
  } else {
    console.log(`  ↻ reusing PackRegistry impl ${registryImplAddress}`);
  }

  const registryImplContract = await viem.getContractAt(
    "PackRegistry",
    registryImplAddress,
  );
  const registryInitData = encodeFunctionData({
    abi: registryImplContract.abi,
    functionName: "initialize",
    args: [permissionManagerProxy],
  });
  await waitForCode(publicClient, registryImplAddress);
  const registryProxyContract = await viem.deployContract(
    "ERC1967ProxyHelper",
    [registryImplAddress, registryInitData],
  );
  registryProxyAddress = registryProxyContract.address;
  console.log(`  Proxy:          ${registryProxyAddress}`);
}

if (isLive) {
  await saveDeployment(networkName, "PackRegistry", {
    proxy: registryProxyAddress,
    implementation: registryImplAddress,
    permissionManager: permissionManagerProxy,
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [5/8] Deploy PackTierRegistry (UUPS proxy) ──────────────────────────────
// Stores per-(machine, tokenId, packId) tier assignments for all PackMachine clones.
// Writes gated by onlyRegisteredMachine; factory wired in step 7.
console.log("[5/8] Deploying PackTierRegistry...");

let tierRegistryImplAddress = await reuseAddress(
  "PackTierRegistry",
  "implementation",
  savedDeployments,
);
let tierRegistryProxyAddress = await reuseAddress(
  "PackTierRegistry",
  "proxy",
  savedDeployments,
);

if (tierRegistryProxyAddress && tierRegistryImplAddress) {
  console.log(`  ↻ reusing PackTierRegistry impl  ${tierRegistryImplAddress}`);
  console.log(`  ↻ reusing PackTierRegistry proxy ${tierRegistryProxyAddress}`);
} else {
  if (!tierRegistryImplAddress) {
    const tierRegistryImpl = await viem.deployContract("PackTierRegistry");
    tierRegistryImplAddress = tierRegistryImpl.address;
    console.log(`  Implementation: ${tierRegistryImplAddress}`);
    if (isLive) {
      await saveDeployment(networkName, "PackTierRegistry", {
        implementation: tierRegistryImplAddress,
        deployedAt: new Date().toISOString(),
      });
    }
  } else {
    console.log(`  ↻ reusing PackTierRegistry impl ${tierRegistryImplAddress}`);
  }

  const tierRegistryImplContract = await viem.getContractAt(
    "PackTierRegistry",
    tierRegistryImplAddress,
  );
  const tierRegistryInitData = encodeFunctionData({
    abi: tierRegistryImplContract.abi,
    functionName: "initialize",
    args: [permissionManagerProxy],
  });
  await waitForCode(publicClient, tierRegistryImplAddress);
  const tierRegistryProxyContract = await viem.deployContract(
    "ERC1967ProxyHelper",
    [tierRegistryImplAddress, tierRegistryInitData],
  );
  tierRegistryProxyAddress = tierRegistryProxyContract.address;
  console.log(`  Proxy:          ${tierRegistryProxyAddress}`);
}

if (isLive) {
  await saveDeployment(networkName, "PackTierRegistry", {
    proxy: tierRegistryProxyAddress,
    implementation: tierRegistryImplAddress,
    permissionManager: permissionManagerProxy,
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [6/8] Deploy BuybackPool (UUPS proxy) ───────────────────────────────────
// BuybackPool.initialize takes the factory proxy address — deploy after factory
// to resolve the circular dependency. factory.setBuybackPool is called in step 7.
console.log("[6/8] Deploying BuybackPool...");

let buybackImplAddress = await reuseAddress(
  "BuybackPool",
  "implementation",
  savedDeployments,
);
let buybackProxyAddress = await reuseAddress(
  "BuybackPool",
  "proxy",
  savedDeployments,
);

if (buybackProxyAddress && buybackImplAddress) {
  console.log(`  ↻ reusing BuybackPool impl  ${buybackImplAddress}`);
  console.log(`  ↻ reusing BuybackPool proxy ${buybackProxyAddress}`);
} else {
  if (!buybackImplAddress) {
    const buybackImpl = await viem.deployContract("BuybackPool");
    buybackImplAddress = buybackImpl.address;
    console.log(`  Implementation: ${buybackImplAddress}`);
    if (isLive) {
      await saveDeployment(networkName, "BuybackPool", {
        implementation: buybackImplAddress,
        deployedAt: new Date().toISOString(),
      });
    }
  } else {
    console.log(`  ↻ reusing BuybackPool impl ${buybackImplAddress}`);
  }

  const buybackImplContract = await viem.getContractAt(
    "BuybackPool",
    buybackImplAddress,
  );
  const buybackInitData = encodeFunctionData({
    abi: buybackImplContract.abi,
    functionName: "initialize",
    args: [
      permissionManagerProxy,
      assetNFTProxy,
      paymentToken,
      financeWallet,
      factoryProxyAddress,
    ],
  });
  await waitForCode(publicClient, buybackImplAddress);
  const buybackProxyContract = await viem.deployContract("ERC1967ProxyHelper", [
    buybackImplAddress,
    buybackInitData,
  ]);
  buybackProxyAddress = buybackProxyContract.address;
  console.log(`  Proxy:          ${buybackProxyAddress}`);
}

if (isLive) {
  await saveDeployment(networkName, "BuybackPool", {
    proxy: buybackProxyAddress,
    implementation: buybackImplAddress,
    permissionManager: permissionManagerProxy,
    assetNFT: assetNFTProxy,
    paymentToken,
    financeWallet,
    factory: factoryProxyAddress,
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [7/8] Wire PackMachineFactory, PackRegistry, and PackTierRegistry ───────
// All factory setters gated by DEFAULT_ADMIN_ROLE — deployer holds it via PermissionManager.initialize.
// Each setter is skipped if the on-chain value already matches (idempotent / resume-safe).
console.log(
  "[7/8] Wiring PackMachineFactory, PackRegistry, and PackTierRegistry...",
);
const factory = await viem.getContractAt(
  "PackMachineFactory",
  factoryProxyAddress,
);
const packRegistry = await viem.getContractAt(
  "PackRegistry",
  registryProxyAddress,
);

// factory.setImplementation — no read getter; always send (PackMachineFactory
// has no public implementation() view, so we can't check without a read).
let txHash = await factory.write.setImplementation([packMachineImplAddress]);
await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  setImplementation(${packMachineImplAddress}) ✓`);
await sleep(STEP_DELAY_MS);

// factory.setPackVRFRouter
const currentVRFRouter = await factory.read.packVRFRouter();
if (currentVRFRouter.toLowerCase() === vrfRouterProxyAddress.toLowerCase()) {
  console.log(`  ↻ skipping setPackVRFRouter (already wired)`);
} else {
  txHash = await factory.write.setPackVRFRouter([vrfRouterProxyAddress]);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`  setPackVRFRouter(${vrfRouterProxyAddress}) ✓`);
}
await sleep(STEP_DELAY_MS);

// factory.setBuybackPool
const currentBuybackPool = await factory.read.buybackPool();
if (currentBuybackPool.toLowerCase() === buybackProxyAddress.toLowerCase()) {
  console.log(`  ↻ skipping setBuybackPool (already wired)`);
} else {
  txHash = await factory.write.setBuybackPool([buybackProxyAddress]);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`  setBuybackPool(${buybackProxyAddress}) ✓`);
}
await sleep(STEP_DELAY_MS);

// factory.setPackRegistry
const currentPackRegistry = await factory.read.packRegistry();
if (currentPackRegistry.toLowerCase() === registryProxyAddress.toLowerCase()) {
  console.log(`  ↻ skipping setPackRegistry (already wired)`);
} else {
  txHash = await factory.write.setPackRegistry([registryProxyAddress]);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`  setPackRegistry(${registryProxyAddress}) ✓`);
}
await sleep(STEP_DELAY_MS);

// packRegistry.setFactory
const currentFactory = await packRegistry.read.factory();
if (currentFactory.toLowerCase() === factoryProxyAddress.toLowerCase()) {
  console.log(`  ↻ skipping packRegistry.setFactory (already wired)`);
} else {
  txHash = await packRegistry.write.setFactory([factoryProxyAddress]);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`  packRegistry.setFactory(${factoryProxyAddress}) ✓`);
}
await sleep(STEP_DELAY_MS);

// factory.setPackTierRegistry
const packTierRegistry = await viem.getContractAt(
  "PackTierRegistry",
  tierRegistryProxyAddress,
);
const currentPackTierRegistry = await factory.read.packTierRegistry();
if (
  currentPackTierRegistry.toLowerCase() ===
  tierRegistryProxyAddress.toLowerCase()
) {
  console.log(`  ↻ skipping setPackTierRegistry (already wired)`);
} else {
  txHash = await factory.write.setPackTierRegistry([tierRegistryProxyAddress]);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`  setPackTierRegistry(${tierRegistryProxyAddress}) ✓`);
}
await sleep(STEP_DELAY_MS);

// packTierRegistry.setFactory
const currentTierRegistryFactory = await packTierRegistry.read.factory();
if (
  currentTierRegistryFactory.toLowerCase() === factoryProxyAddress.toLowerCase()
) {
  console.log(`  ↻ skipping packTierRegistry.setFactory (already wired)`);
} else {
  txHash = await packTierRegistry.write.setFactory([factoryProxyAddress]);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`  packTierRegistry.setFactory(${factoryProxyAddress}) ✓`);
}

// Re-save factory, registry, and tier-registry records with final wiring addresses.
if (isLive) {
  await saveDeployment(networkName, "PackMachineFactory", {
    proxy: factoryProxyAddress,
    implementation: factoryImplAddress,
    permissionManager: permissionManagerProxy,
    packMachineImplementation: packMachineImplAddress,
    packVRFRouter: vrfRouterProxyAddress,
    buybackPool: buybackProxyAddress,
    packRegistry: registryProxyAddress,
    packTierRegistry: tierRegistryProxyAddress,
    assetNFT: assetNFTProxy,
    paymentToken,
    financeWallet,
    trustedForwarder: TRUSTED_FORWARDER,
    deployedAt: new Date().toISOString(),
  });
  await saveDeployment(networkName, "PackRegistry", {
    proxy: registryProxyAddress,
    implementation: registryImplAddress,
    permissionManager: permissionManagerProxy,
    factory: factoryProxyAddress,
    deployedAt: new Date().toISOString(),
  });
  await saveDeployment(networkName, "PackTierRegistry", {
    proxy: tierRegistryProxyAddress,
    implementation: tierRegistryImplAddress,
    permissionManager: permissionManagerProxy,
    factory: factoryProxyAddress,
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [8/8] Verify deployments ────────────────────────────────────────────────
console.log("[8/8] Verifying deployments...");

const router = await viem.getContractAt("PackVRFRouter", vrfRouterProxyAddress);
const buyback = await viem.getContractAt("BuybackPool", buybackProxyAddress);

const routerPM = await router.read.getPermissionManager();
const routerCoordinator = await router.read.vrfCoordinator();
const routerSubId = await router.read.subscriptionId();
const factoryPM = await factory.read.getPermissionManager();
const factoryVRFRouter = await factory.read.packVRFRouter();
const factoryBuybackPool = await factory.read.buybackPool();
const factoryPackRegistry = await factory.read.packRegistry();
const factoryPackTierRegistry = await factory.read.packTierRegistry();
const registryFactory = await packRegistry.read.factory();
const tierRegistryFactory = await packTierRegistry.read.factory();
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
if (factoryVRFRouter.toLowerCase() !== vrfRouterProxyAddress.toLowerCase()) {
  errors.push(
    `  PackMachineFactory.packVRFRouter: expected "${vrfRouterProxyAddress}", got "${factoryVRFRouter}"`,
  );
}
if (factoryBuybackPool.toLowerCase() !== buybackProxyAddress.toLowerCase()) {
  errors.push(
    `  PackMachineFactory.buybackPool: expected "${buybackProxyAddress}", got "${factoryBuybackPool}"`,
  );
}
if (factoryPackRegistry.toLowerCase() !== registryProxyAddress.toLowerCase()) {
  errors.push(
    `  PackMachineFactory.packRegistry: expected "${registryProxyAddress}", got "${factoryPackRegistry}"`,
  );
}
if (
  factoryPackTierRegistry.toLowerCase() !==
  tierRegistryProxyAddress.toLowerCase()
) {
  errors.push(
    `  PackMachineFactory.packTierRegistry: expected "${tierRegistryProxyAddress}", got "${factoryPackTierRegistry}"`,
  );
}
if (registryFactory.toLowerCase() !== factoryProxyAddress.toLowerCase()) {
  errors.push(
    `  PackRegistry.factory: expected "${factoryProxyAddress}", got "${registryFactory}"`,
  );
}
if (tierRegistryFactory.toLowerCase() !== factoryProxyAddress.toLowerCase()) {
  errors.push(
    `  PackTierRegistry.factory: expected "${factoryProxyAddress}", got "${tierRegistryFactory}"`,
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

// ─── Final BuybackPool checkpoint with verified defaultBuybackBps ─────────────
if (isLive) {
  await saveDeployment(networkName, "BuybackPool", {
    proxy: buybackProxyAddress,
    implementation: buybackImplAddress,
    permissionManager: permissionManagerProxy,
    assetNFT: assetNFTProxy,
    paymentToken,
    financeWallet,
    factory: factoryProxyAddress,
    defaultBuybackBps: buybackDefaultBps,
    deployedAt: new Date().toISOString(),
  });
  console.log(`Deployment info saved to deployments/${networkName}.json`);
}

// ─── Summary ──────────────────────────────────────────────────────────────────
console.log("\n=== Deployment Successful ===");
console.log(`Network:               ${networkName} (chainId: ${chainId})`);
console.log(`\nPackVRFRouter`);
console.log(`  Implementation:    ${vrfRouterImplAddress}`);
console.log(`  Proxy:             ${vrfRouterProxyAddress}`);
console.log(`\nPackMachine (clone target)`);
console.log(`  Implementation:    ${packMachineImplAddress}`);
console.log(`\nPackMachineFactory`);
console.log(`  Implementation:    ${factoryImplAddress}`);
console.log(`  Proxy:             ${factoryProxyAddress}`);
console.log(`\nPackRegistry`);
console.log(`  Implementation:    ${registryImplAddress}`);
console.log(`  Proxy:             ${registryProxyAddress}`);
console.log(`\nPackTierRegistry`);
console.log(`  Implementation:    ${tierRegistryImplAddress}`);
console.log(`  Proxy:             ${tierRegistryProxyAddress}`);
console.log(`\nBuybackPool`);
console.log(`  Implementation:    ${buybackImplAddress}`);
console.log(`  Proxy:             ${buybackProxyAddress}`);
console.log(`\nWiring`);
console.log(`  Factory.implementation:       ${packMachineImplAddress} ✓`);
console.log(`  Factory.packVRFRouter:        ${vrfRouterProxyAddress} ✓`);
console.log(`  Factory.buybackPool:          ${buybackProxyAddress} ✓`);
console.log(`  Factory.packRegistry:         ${registryProxyAddress} ✓`);
console.log(`  Factory.packTierRegistry:     ${tierRegistryProxyAddress} ✓`);
console.log(`  Registry.factory:             ${factoryProxyAddress} ✓`);
console.log(`  TierRegistry.factory:         ${factoryProxyAddress} ✓`);
console.log("=============================\n");

console.log("⚠️  Remaining manual steps before packs can open:");
console.log(
  `  1. Add PackVRFRouter proxy as a consumer on the Chainlink VRF subscription:`,
);
console.log(
  `       subscription ${vrfSubscriptionId} → add consumer ${vrfRouterProxyAddress}`,
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
  `  5. Configure pack tier FMV bounds (PACK_OPERATOR_ROLE) — required before deposit:`,
);
console.log(
  `       packRegistry.setPackTierFmvBounds(clone, 0, [minFmv×6], [maxFmv×6])`,
);
console.log(`  6. Configure pack buyback allocation (PACK_OPERATOR_ROLE):`);
console.log(
  `       packRegistry.setPackBuybackAllocation(clone, 0, <bps>)  // e.g. 2000 = 20%`,
);
console.log(
  `  7. Deposit NFT inventory and open packs (via setup-pack-machine script).\n`,
);
