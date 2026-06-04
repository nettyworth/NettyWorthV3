import { network } from "hardhat";
import { encodeFunctionData, getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

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
    permissionManagerProxy = getAddress(process.env.PERMISSION_MANAGER_PROXY) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
    const data = await readDeployments();
    const entry = data["PermissionManager"] as Record<string, unknown> | undefined;
    if (!entry?.proxy) {
        console.error("PermissionManager proxy not found. Set PERMISSION_MANAGER_PROXY or deploy PermissionManager first.");
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
    console.error("TREASURY env var is required (platform fee recipient address).");
    process.exit(1);
}

// ─── Confirmation prompt on live networks ────────────────────────────────────
if (connection.networkConfig.type === "http") {
    const ok = await confirm(
        connection.networkName, chainId, deployerAddress,
        permissionManagerProxy, treasury,
    );
    if (!ok) { console.log("Deployment cancelled."); process.exit(0); }
}

// ─── [1/4] Deploy implementation ─────────────────────────────────────────────
console.log("\n[1/4] Deploying FeeController implementation...");
const impl = await viem.deployContract("FeeController");
console.log(`  Implementation: ${impl.address}`);

// ─── [2/4] Encode initialize calldata ────────────────────────────────────────
console.log("[2/4] Encoding initialize calldata...");
const initData = encodeFunctionData({
    abi: impl.abi,
    functionName: "initialize",
    args: [permissionManagerProxy, treasury],
});

// ─── [3/4] Deploy ERC-1967 proxy ─────────────────────────────────────────────
console.log("[3/4] Deploying ERC1967 proxy...");
const proxy = await viem.deployContract("ERC1967ProxyHelper", [impl.address, initData]);
console.log(`  Proxy: ${proxy.address}`);

// ─── [4/4] Verify deployment ──────────────────────────────────────────────────
console.log("[4/4] Verifying deployment...");
const fc = await viem.getContractAt("FeeController", proxy.address);

const actualTreasury = await fc.read.protocolFeeRecipient();
const collectibleBps = await fc.read.collectibleFeesBps();
const redemptionBps = await fc.read.redemptionFeeBps();
const collectibleEnabled = await fc.read.collectibleFeesEnabled();
const redemptionEnabled = await fc.read.redemptionFeeEnabled();

const errors: string[] = [];
if (actualTreasury.toLowerCase() !== treasury.toLowerCase()) {
    errors.push(`  treasury: expected "${treasury}", got "${actualTreasury}"`);
}
if (collectibleBps !== 500) errors.push(`  collectibleFeesBps: expected 500, got ${collectibleBps}`);
if (redemptionBps !== 500) errors.push(`  redemptionFeeBps: expected 500, got ${redemptionBps}`);
if (!collectibleEnabled) errors.push("  collectibleFeesEnabled: expected true");
if (!redemptionEnabled) errors.push("  redemptionFeeEnabled: expected true");

if (errors.length > 0) {
    console.error("Verification failed!");
    for (const e of errors) console.error(e);
    process.exit(1);
}

console.log("\n=== FeeController Deployment Successful ===");
console.log(`Network:              ${connection.networkName} (chainId: ${chainId})`);
console.log(`Implementation:       ${impl.address}`);
console.log(`Proxy:                ${proxy.address}`);
console.log(`Treasury:             ${actualTreasury}`);
console.log(`Collectible Fee:      ${collectibleBps} bps (enabled: ${collectibleEnabled})`);
console.log(`Redemption Fee:       ${redemptionBps} bps (enabled: ${redemptionEnabled})`);
console.log("===========================================\n");

// ─── Persist deployment record ────────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
    let existing: Record<string, unknown> = {};
    try { existing = JSON.parse(await readFile(deploymentPath, "utf8")); } catch { /**/ }

    existing["FeeController"] = {
        proxy: proxy.address,
        implementation: impl.address,
        permissionManager: permissionManagerProxy,
        treasury: actualTreasury,
        collectibleFeesBps: collectibleBps.toString(),
        redemptionFeeBps: redemptionBps.toString(),
        deployedAt: new Date().toISOString(),
    };

    await mkdir(deploymentsDir, { recursive: true });
    await writeFile(deploymentPath, JSON.stringify(existing, null, 2) + "\n");
    console.log(`Deployment info saved to deployments/${connection.networkName}.json`);
}
