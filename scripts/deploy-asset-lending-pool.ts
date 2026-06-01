import { network } from "hardhat";
import { encodeFunctionData, getAddress, keccak256, toBytes } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

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

// ─── Helper: resolve an address from env or deployments JSON ─────────────────
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
} else if (connection.networkConfig.type === "http") {
    const data = await readDeployments();
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
} else if (connection.networkConfig.type === "http") {
    const data = await readDeployments();
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
} else if (connection.networkConfig.type === "http") {
    const data = await readDeployments();
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
if (connection.networkConfig.type === "http") {
    const ok = await confirm(
        connection.networkName,
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
        "   Call setPackMachineFactory(address) on the pool after deployment.",
    );
}

// ─── [1/5] Deploy implementation ─────────────────────────────────────────────
console.log("\n[1/5] Deploying AssetLendingPool implementation...");
const impl = await viem.deployContract("AssetLendingPool");
console.log(`  Implementation: ${impl.address}`);

// ─── [2/5] Encode initialize calldata ────────────────────────────────────────
console.log("[2/5] Encoding initialize calldata...");
const initData = encodeFunctionData({
    abi: impl.abi,
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

// ─── [3/5] Deploy ERC-1967 proxy ─────────────────────────────────────────────
console.log("[3/5] Deploying ERC1967 proxy...");
const proxy = await viem.deployContract("ERC1967ProxyHelper", [
    impl.address,
    initData,
]);
console.log(`  Proxy: ${proxy.address}`);

// ─── [4/5] Grant STATE_MANAGER_ROLE to the pool proxy ────────────────────────
console.log(
    "[4/5] Granting STATE_MANAGER_ROLE to the pool proxy on PermissionManager...",
);
const pm = await viem.getContractAt("PermissionManager", permissionManagerProxy);
await pm.write.grantRole([STATE_MANAGER_ROLE, proxy.address]);
console.log(`  STATE_MANAGER_ROLE granted to ${proxy.address}`);

// ─── [5/5] Verify deployment ──────────────────────────────────────────────────
console.log("[5/5] Verifying deployment...");
const pool = await viem.getContractAt("AssetLendingPool", proxy.address);

const actualOwner = await pool.read.owner();
const poolInfo = await pool.read.getPoolInfo();
const hasRole = await pm.read.hasProtocolRole([
    STATE_MANAGER_ROLE,
    proxy.address,
]);

const errors: string[] = [];

if (actualOwner.toLowerCase() !== initialOwner.toLowerCase()) {
    errors.push(
        `  owner: expected "${initialOwner}", got "${actualOwner}"`,
    );
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
    errors.push(
        `  ltvBps: expected "${LTV_BPS}", got "${poolInfo.ltvBps}"`,
    );
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
console.log(
    `Network:              ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Implementation:       ${impl.address}`);
console.log(`Proxy:                ${proxy.address}`);
console.log(`Owner:                ${actualOwner}`);
console.log(`Payment Token:        ${poolInfo.paymentToken}`);
console.log(`AssetNFT:             ${poolInfo.assetNFT}`);
console.log(`LTV:                  ${poolInfo.ltvBps} bps`);
console.log(`Lender Share:         ${poolInfo.lenderShareBps} bps`);
console.log(`Acquisition Window:   ${poolInfo.acquisitionWindow} s`);
console.log(`Auction Window:       ${poolInfo.auctionWindow} s`);
console.log(`STATE_MANAGER_ROLE:   granted ✓`);
if (usingFactoryPlaceholder) {
    console.log(
        `PackMachineFactory:   ${packMachineFactory} (placeholder — remember to call setPackMachineFactory)`,
    );
} else {
    console.log(`PackMachineFactory:   ${packMachineFactory}`);
}
console.log("=============================\n");

// ─── Persist deployment record ────────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
    const outPath = join(deploymentsDir, `${connection.networkName}.json`);

    let existing: Record<string, unknown> = {};
    try {
        existing = JSON.parse(await readFile(outPath, "utf8"));
    } catch {
        // file doesn't exist yet — start fresh
    }

    existing["AssetLendingPool"] = {
        proxy: proxy.address,
        implementation: impl.address,
        owner: actualOwner,
        paymentToken: poolInfo.paymentToken,
        assetNFT: poolInfo.assetNFT,
        permissionManager: permissionManagerProxy,
        packMachineFactory,
        ltvBps: poolInfo.ltvBps.toString(),
        lenderShareBps: poolInfo.lenderShareBps.toString(),
        acquisitionWindow: poolInfo.acquisitionWindow.toString(),
        auctionWindow: poolInfo.auctionWindow.toString(),
        deployedAt: new Date().toISOString(),
    };

    await mkdir(deploymentsDir, { recursive: true });
    await writeFile(outPath, JSON.stringify(existing, null, 2) + "\n");
    console.log(
        `Deployment info saved to deployments/${connection.networkName}.json`,
    );
}
