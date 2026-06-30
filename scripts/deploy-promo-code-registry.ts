import { network } from "hardhat";
import { encodeFunctionData, getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { waitForCode } from "./lib/deployments.js";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

async function confirm(
    networkName: string,
    chainId: number,
    deployer: string,
    permissionManager: string,
): Promise<boolean> {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    console.log("\n=== PromoCodeRegistry Deployment Summary ===");
    console.log(`Network:            ${networkName}`);
    console.log(`Chain ID:           ${chainId}`);
    console.log(`Deployer:           ${deployer}`);
    console.log(`PermissionManager:  ${permissionManager}`);
    console.log("============================================\n");
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

// ─── Confirmation prompt on live networks ────────────────────────────────────
if (connection.networkConfig.type === "http") {
    const ok = await confirm(
        connection.networkName, chainId, deployerAddress,
        permissionManagerProxy,
    );
    if (!ok) { console.log("Deployment cancelled."); process.exit(0); }
}

// ─── [1/4] Deploy implementation ─────────────────────────────────────────────
console.log("\n[1/4] Deploying PromoCodeRegistry implementation...");
const impl = await viem.deployContract("PromoCodeRegistry");
console.log(`  Implementation: ${impl.address}`);

// ─── [2/4] Encode initialize calldata ────────────────────────────────────────
console.log("[2/4] Encoding initialize calldata...");
const initData = encodeFunctionData({
    abi: impl.abi,
    functionName: "initialize",
    args: [permissionManagerProxy],
});

// ─── [3/4] Deploy ERC-1967 proxy ─────────────────────────────────────────────
console.log("[3/4] Deploying ERC1967 proxy...");
await waitForCode(publicClient, impl.address);
const proxy = await viem.deployContract("ERC1967ProxyHelper", [impl.address, initData]);
console.log(`  Proxy: ${proxy.address}`);

// ─── [4/4] Verify deployment ──────────────────────────────────────────────────
console.log("[4/4] Verifying deployment...");
const registry = await viem.getContractAt("PromoCodeRegistry", proxy.address);

const actualPM = await registry.read.getPermissionManager();
const paused = await registry.read.paused();
const factory = await registry.read.packMachineFactory();
const pool = await registry.read.buybackPool();

const errors: string[] = [];
if (actualPM.toLowerCase() !== permissionManagerProxy.toLowerCase()) {
    errors.push(`  permissionManager: expected "${permissionManagerProxy}", got "${actualPM}"`);
}
if (paused) errors.push("  paused: expected false");
if (factory !== "0x0000000000000000000000000000000000000000") {
    errors.push(`  packMachineFactory: expected zero address on fresh deploy, got "${factory}"`);
}
if (pool !== "0x0000000000000000000000000000000000000000") {
    errors.push(`  buybackPool: expected zero address on fresh deploy, got "${pool}"`);
}

if (errors.length > 0) {
    console.error("Verification failed!");
    for (const e of errors) console.error(e);
    process.exit(1);
}

console.log("\n=== PromoCodeRegistry Deployment Successful ===");
console.log(`Network:          ${connection.networkName} (chainId: ${chainId})`);
console.log(`Implementation:   ${impl.address}`);
console.log(`Proxy:            ${proxy.address}`);
console.log(`PermissionManager:${actualPM}`);
console.log(`Paused:           ${paused}`);
console.log("================================================\n");

console.log("Next steps (run as DEFAULT_ADMIN_ROLE / PACK_OPERATOR_ROLE):");
console.log(`  1. registry.setPackMachineFactory(<factoryProxy>)   -- DEFAULT_ADMIN_ROLE`);
console.log(`  2. registry.setBuybackPool(<buybackPoolProxy>)       -- DEFAULT_ADMIN_ROLE`);
console.log(`  3. factory.setPromoCodeRegistry("${proxy.address}") -- DEFAULT_ADMIN_ROLE`);
console.log(`  4. buybackPool.setPromoCodeRegistry("${proxy.address}") -- PACK_OPERATOR_ROLE`);
console.log(`  5. Deploy a new PackMachine implementation and call factory.setImplementation(newImpl)`);
console.log(`     so future clones support code-aware openPack calls.`);
console.log(`  6. Upgrade BuybackPool and PackMachineFactory implementations in place (UUPS).`);

// ─── Persist deployment record ────────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
    let existing: Record<string, unknown> = {};
    try { existing = JSON.parse(await readFile(deploymentPath, "utf8")); } catch { /**/ }

    existing["PromoCodeRegistry"] = {
        proxy: proxy.address,
        implementation: impl.address,
        permissionManager: permissionManagerProxy,
        deployedAt: new Date().toISOString(),
    };

    await mkdir(deploymentsDir, { recursive: true });
    await writeFile(deploymentPath, JSON.stringify(existing, null, 2) + "\n");
    console.log(`Deployment info saved to deployments/${connection.networkName}.json`);
}
