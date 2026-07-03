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

// ─── Pool parameters (override via environment variables) ────────────────────
const LTV_BPS = BigInt(process.env.LENDING_POOL_LTV_BPS ?? "5000"); // 50%
const LENDER_SHARE_BPS = BigInt(
  process.env.LENDING_POOL_LENDER_SHARE_BPS ?? "8000",
); // 80%
const ACQUISITION_WINDOW = BigInt(
  process.env.LENDING_POOL_ACQUISITION_WINDOW ?? String(24 * 3600),
); // 24 h
const AUCTION_WINDOW = BigInt(
  process.env.LENDING_POOL_AUCTION_WINDOW ?? String(7 * 24 * 3600),
); // 7 d

// STATE_MANAGER_ROLE = keccak256("STATE_MANAGER_ROLE") — matches contracts/lib/Roles.sol:8-9
const STATE_MANAGER_ROLE = keccak256(toBytes("STATE_MANAGER_ROLE"));

async function confirm(
  networkName: string,
  chainId: number,
  deployer: string,
  paymentToken: string,
  assetNFTProxy: string,
  permissionManagerProxy: string,
  packMachineFactory: string,
  usingFactoryPlaceholder: boolean,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== Deployment Summary ===");
  console.log(`Network:              ${networkName}`);
  console.log(`Chain ID:             ${chainId}`);
  console.log(`Deployer:             ${deployer}`);
  console.log(`Payment Token:        ${paymentToken}`);
  console.log(`AssetNFT Proxy:       ${assetNFTProxy}`);
  console.log(`PermissionManager:    ${permissionManagerProxy}`);
  console.log(
    `PackMachineFactory:   ${packMachineFactory}${usingFactoryPlaceholder ? " (placeholder — call setPackMachineFactory later)" : ""}`,
  );
  console.log(`LTV:                  ${LTV_BPS} bps`);
  console.log(`Lender Share:         ${LENDER_SHARE_BPS} bps`);
  console.log(`Acquisition Window:   ${ACQUISITION_WINDOW} s`);
  console.log(`Auction Window:       ${AUCTION_WINDOW} s`);
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

// ─── Resolve PAYMENT_TOKEN (required — no default) ───────────────────────────
let paymentToken: `0x${string}`;
if (process.env.PAYMENT_TOKEN) {
  paymentToken = getAddress(process.env.PAYMENT_TOKEN) as `0x${string}`;
} else {
  console.error(
    "PAYMENT_TOKEN env var is required (ERC20 token address, e.g. USDC).",
  );
  process.exit(1);
}

// ─── Resolve ASSET_NFT_PROXY ─────────────────────────────────────────────────
let assetNFTProxy: `0x${string}`;
if (process.env.ASSET_NFT_PROXY) {
  assetNFTProxy = getAddress(process.env.ASSET_NFT_PROXY) as `0x${string}`;
} else if (isLive) {
  const data = await readDeployments(networkName);
  const entry = data["AssetNFT"] as Record<string, unknown> | undefined;
  if (!entry?.proxy) {
    console.error(
      "AssetNFT proxy address not found. Set ASSET_NFT_PROXY env var or deploy AssetNFT first.",
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
      "PermissionManager proxy address not found. Set PERMISSION_MANAGER_PROXY env var or deploy the PermissionManager first.",
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

// ─── Resolve PACK_MACHINE_FACTORY (optional — falls back to placeholder) ─────
const FACTORY_PLACEHOLDER =
  "0x0000000000000000000000000000000000000001" as const;
let packMachineFactory: `0x${string}`;
let usingFactoryPlaceholder = false;
if (process.env.PACK_MACHINE_FACTORY) {
  packMachineFactory = getAddress(
    process.env.PACK_MACHINE_FACTORY,
  ) as `0x${string}`;
} else if (isLive) {
  const data = await readDeployments(networkName);
  const entry = data["PackMachineFactory"] as
    | Record<string, unknown>
    | undefined;
  if (entry?.proxy) {
    packMachineFactory = getAddress(entry.proxy as string) as `0x${string}`;
  } else {
    packMachineFactory = FACTORY_PLACEHOLDER;
    usingFactoryPlaceholder = true;
  }
} else {
  packMachineFactory = FACTORY_PLACEHOLDER;
  usingFactoryPlaceholder = true;
}

// ─── Resolve initial owner (defaults to deployer) ────────────────────────────
const initialOwner: `0x${string}` = process.env.LENDING_POOL_OWNER
  ? (getAddress(process.env.LENDING_POOL_OWNER) as `0x${string}`)
  : deployerAddress;

// ─── Confirmation prompt on live networks ────────────────────────────────────
if (isLive) {
  const ok = await confirm(
    networkName,
    chainId,
    deployerAddress,
    paymentToken,
    assetNFTProxy,
    permissionManagerProxy,
    packMachineFactory,
    usingFactoryPlaceholder,
  );
  if (!ok) {
    console.log("Deployment cancelled.");
    process.exit(0);
  }
}

if (usingFactoryPlaceholder) {
  console.log(
    "\n⚠️  PackMachineFactory not resolved — using placeholder address.",
  );
  console.log(
    "   Call setPackMachineFactory(address) on the config contract after deployment.",
  );
}

// Re-read after confirmation so interactive pause doesn't matter.
const savedDeployments = isLive ? await readDeployments(networkName) : {};

// ─── [1/6]+[2/6] Deploy AssetLendingPoolConfig (impl + proxy) ────────────────
console.log("\n[1/6] Deploying AssetLendingPoolConfig implementation...");

let configImplAddress = await reuseAddress(
  "AssetLendingPoolConfig",
  "implementation",
  savedDeployments,
);
let configProxyAddress = await reuseAddress(
  "AssetLendingPoolConfig",
  "proxy",
  savedDeployments,
);

if (configImplAddress && configProxyAddress) {
  console.log(`  ↻ reusing AssetLendingPoolConfig impl  ${configImplAddress}`);
  console.log(`  ↻ reusing AssetLendingPoolConfig proxy ${configProxyAddress}`);
} else {
  if (!configImplAddress) {
    const configImpl = await viem.deployContract("AssetLendingPoolConfig");
    configImplAddress = configImpl.address;
    console.log(`  Config Implementation: ${configImplAddress}`);
    // Checkpoint impl immediately so a proxy-deploy failure doesn't lose it.
    if (isLive) {
      await saveDeployment(networkName, "AssetLendingPoolConfig", {
        implementation: configImplAddress,
        deployedAt: new Date().toISOString(),
      });
    }
  } else {
    console.log(`  ↻ reusing AssetLendingPoolConfig impl ${configImplAddress}`);
  }

  console.log("[2/6] Deploying AssetLendingPoolConfig proxy...");
  const configImplContract = await viem.getContractAt(
    "AssetLendingPoolConfig",
    configImplAddress,
  );
  const configInitData = encodeFunctionData({
    abi: configImplContract.abi,
    functionName: "initialize",
    args: [
      initialOwner,
      paymentToken,
      assetNFTProxy,
      LTV_BPS,
      LENDER_SHARE_BPS,
      ACQUISITION_WINDOW,
      AUCTION_WINDOW,
      packMachineFactory,
    ],
  });
  await waitForCode(publicClient, configImplAddress);
  const configProxy = await viem.deployContract("ERC1967ProxyHelper", [
    configImplAddress,
    configInitData,
  ]);
  configProxyAddress = configProxy.address;
  console.log(`  Config Proxy: ${configProxyAddress}`);
}

if (isLive) {
  await saveDeployment(networkName, "AssetLendingPoolConfig", {
    proxy: configProxyAddress,
    implementation: configImplAddress,
    owner: initialOwner,
    paymentToken,
    assetNFT: assetNFTProxy,
    packMachineFactory,
    ltvBps: LTV_BPS.toString(),
    lenderShareBps: LENDER_SHARE_BPS.toString(),
    acquisitionWindow: ACQUISITION_WINDOW.toString(),
    auctionWindow: AUCTION_WINDOW.toString(),
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [3/6]+[4/6] Deploy AssetLendingPool (impl + proxy) ──────────────────────
console.log("[3/6] Deploying AssetLendingPool implementation...");

let poolImplAddress = await reuseAddress(
  "AssetLendingPool",
  "implementation",
  savedDeployments,
);
let poolProxyAddress = await reuseAddress(
  "AssetLendingPool",
  "proxy",
  savedDeployments,
);

if (poolImplAddress && poolProxyAddress) {
  console.log(`  ↻ reusing AssetLendingPool impl  ${poolImplAddress}`);
  console.log(`  ↻ reusing AssetLendingPool proxy ${poolProxyAddress}`);
} else {
  if (!poolImplAddress) {
    const impl = await viem.deployContract("AssetLendingPool");
    poolImplAddress = impl.address;
    console.log(`  Pool Implementation: ${poolImplAddress}`);
    // Checkpoint impl immediately so a proxy-deploy failure doesn't lose it.
    if (isLive) {
      await saveDeployment(networkName, "AssetLendingPool", {
        implementation: poolImplAddress,
        deployedAt: new Date().toISOString(),
      });
    }
  } else {
    console.log(`  ↻ reusing AssetLendingPool impl ${poolImplAddress}`);
  }

  console.log("[4/6] Deploying AssetLendingPool proxy...");
  const poolImplContract = await viem.getContractAt(
    "AssetLendingPool",
    poolImplAddress,
  );
  const poolInitData = encodeFunctionData({
    abi: poolImplContract.abi,
    functionName: "initialize",
    args: [initialOwner, configProxyAddress],
  });
  await waitForCode(publicClient, poolImplAddress);
  const proxy = await viem.deployContract("ERC1967ProxyHelper", [
    poolImplAddress,
    poolInitData,
  ]);
  poolProxyAddress = proxy.address;
  console.log(`  Pool Proxy: ${poolProxyAddress}`);
}

if (isLive) {
  await saveDeployment(networkName, "AssetLendingPool", {
    proxy: poolProxyAddress,
    implementation: poolImplAddress,
    owner: initialOwner,
    config: configProxyAddress,
    permissionManager: permissionManagerProxy,
    deployedAt: new Date().toISOString(),
  });
  console.log("  ✓ checkpoint saved");
}
await sleep(STEP_DELAY_MS);

// ─── [5/6] Grant STATE_MANAGER_ROLE to the pool proxy (idempotent) ───────────
console.log(
  "[5/6] Granting STATE_MANAGER_ROLE to the pool proxy on PermissionManager...",
);
const pm = await viem.getContractAt(
  "PermissionManager",
  permissionManagerProxy,
);

const alreadyHasRole = await pm.read.hasProtocolRole([
  STATE_MANAGER_ROLE,
  poolProxyAddress,
]);
if (alreadyHasRole) {
  console.log(`  ↻ skipping grantRole (already granted)`);
} else {
  const hash = await pm.write.grantRole([STATE_MANAGER_ROLE, poolProxyAddress]);
  await publicClient.waitForTransactionReceipt({ hash });
  console.log(`  STATE_MANAGER_ROLE granted to ${poolProxyAddress}`);
}
await sleep(STEP_DELAY_MS);

// ─── [6/6] Verify deployment ──────────────────────────────────────────────────
console.log("[6/6] Verifying deployment...");
const pool = await viem.getContractAt("AssetLendingPool", poolProxyAddress);

const actualOwner = await pool.read.owner();
const poolInfo = await pool.read.getPoolInfo();
const hasRole = await pm.read.hasProtocolRole([
  STATE_MANAGER_ROLE,
  poolProxyAddress,
]);

const errors: string[] = [];

if (actualOwner.toLowerCase() !== initialOwner.toLowerCase()) {
  errors.push(`  owner: expected "${initialOwner}", got "${actualOwner}"`);
}
if (poolInfo.paymentToken.toLowerCase() !== paymentToken.toLowerCase()) {
  errors.push(
    `  paymentToken: expected "${paymentToken}", got "${poolInfo.paymentToken}"`,
  );
}
if (poolInfo.assetNFT.toLowerCase() !== assetNFTProxy.toLowerCase()) {
  errors.push(
    `  assetNFT: expected "${assetNFTProxy}", got "${poolInfo.assetNFT}"`,
  );
}
if (poolInfo.ltvBps !== LTV_BPS) {
  errors.push(`  ltvBps: expected "${LTV_BPS}", got "${poolInfo.ltvBps}"`);
}
if (poolInfo.lenderShareBps !== LENDER_SHARE_BPS) {
  errors.push(
    `  lenderShareBps: expected "${LENDER_SHARE_BPS}", got "${poolInfo.lenderShareBps}"`,
  );
}
if (poolInfo.acquisitionWindow !== ACQUISITION_WINDOW) {
  errors.push(
    `  acquisitionWindow: expected "${ACQUISITION_WINDOW}", got "${poolInfo.acquisitionWindow}"`,
  );
}
if (poolInfo.auctionWindow !== AUCTION_WINDOW) {
  errors.push(
    `  auctionWindow: expected "${AUCTION_WINDOW}", got "${poolInfo.auctionWindow}"`,
  );
}
if (!hasRole) {
  errors.push(`  STATE_MANAGER_ROLE not granted to pool proxy`);
}

if (errors.length > 0) {
  console.error("Verification failed!");
  for (const e of errors) console.error(e);
  process.exit(1);
}

console.log("\n=== Deployment Successful ===");
console.log(`Network:              ${networkName} (chainId: ${chainId})`);
console.log(`Config Implementation: ${configImplAddress}`);
console.log(`Config Proxy:          ${configProxyAddress}`);
console.log(`Pool Implementation:   ${poolImplAddress}`);
console.log(`Pool Proxy:            ${poolProxyAddress}`);
console.log(`Owner:                 ${actualOwner}`);
console.log(`Payment Token:         ${poolInfo.paymentToken}`);
console.log(`AssetNFT:              ${poolInfo.assetNFT}`);
console.log(`LTV:                   ${poolInfo.ltvBps} bps`);
console.log(`Lender Share:          ${poolInfo.lenderShareBps} bps`);
console.log(`Acquisition Window:    ${poolInfo.acquisitionWindow} s`);
console.log(`Auction Window:        ${poolInfo.auctionWindow} s`);
console.log(`STATE_MANAGER_ROLE:    granted ✓`);
if (usingFactoryPlaceholder) {
  console.log(
    `PackMachineFactory:    ${packMachineFactory} (placeholder — call setPackMachineFactory on config contract)`,
  );
} else {
  console.log(`PackMachineFactory:    ${packMachineFactory}`);
}
console.log("=============================\n");

// ─── Final checkpoint with verified owner ────────────────────────────────────
if (isLive) {
  await saveDeployment(networkName, "AssetLendingPoolConfig", {
    proxy: configProxyAddress,
    implementation: configImplAddress,
    owner: actualOwner,
    paymentToken,
    assetNFT: assetNFTProxy,
    packMachineFactory,
    ltvBps: LTV_BPS.toString(),
    lenderShareBps: LENDER_SHARE_BPS.toString(),
    acquisitionWindow: ACQUISITION_WINDOW.toString(),
    auctionWindow: AUCTION_WINDOW.toString(),
    deployedAt: new Date().toISOString(),
  });
  await saveDeployment(networkName, "AssetLendingPool", {
    proxy: poolProxyAddress,
    implementation: poolImplAddress,
    owner: actualOwner,
    config: configProxyAddress,
    permissionManager: permissionManagerProxy,
    deployedAt: new Date().toISOString(),
  });
  console.log(`Deployment info saved to deployments/${networkName}.json`);
}
