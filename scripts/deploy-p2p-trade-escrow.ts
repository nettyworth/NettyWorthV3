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
    owner: string,
): Promise<boolean> {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    console.log("\n=== P2PTradeEscrow Deployment Summary ===");
    console.log(`Network:   ${networkName}`);
    console.log(`Chain ID:  ${chainId}`);
    console.log(`Deployer:  ${deployer}`);
    console.log(`Owner:     ${owner}`);
    console.log("=========================================\n");
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

// Owner defaults to deployer; override with OWNER env var for multi-sig setups.
let owner: `0x${string}` = deployerAddress;
if (process.env.OWNER) {
    owner = getAddress(process.env.OWNER) as `0x${string}`;
}

const deploymentsDir = join(
    dirname(fileURLToPath(import.meta.url)),
    "../deployments",
);
const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);

// ─── Confirmation prompt ──────────────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
    const ok = await confirm(connection.networkName, chainId, deployerAddress, owner);
    if (!ok) { console.log("Deployment cancelled."); process.exit(0); }
}

// ─── [1/4] Deploy implementation ─────────────────────────────────────────────
console.log("\n[1/4] Deploying P2PTradeEscrow implementation...");
const impl = await viem.deployContract("P2PTradeEscrow");
console.log(`  Implementation: ${impl.address}`);

// ─── [2/4] Encode initialize calldata ────────────────────────────────────────
console.log("[2/4] Encoding initialize calldata...");
const initData = encodeFunctionData({
    abi: impl.abi,
    functionName: "initialize",
    args: [owner],
});

// ─── [3/4] Deploy ERC-1967 proxy ─────────────────────────────────────────────
console.log("[3/4] Deploying ERC1967 proxy...");
const proxy = await viem.deployContract("ERC1967ProxyHelper", [impl.address, initData]);
console.log(`  Proxy: ${proxy.address}`);

// ─── [4/4] Verify deployment ──────────────────────────────────────────────────
console.log("[4/4] Verifying deployment...");
const escrow = await viem.getContractAt("P2PTradeEscrow", proxy.address);

const actualOwner = await escrow.read.owner();
const nextId = await escrow.read.nextTradeId();

const errors: string[] = [];
if (actualOwner.toLowerCase() !== owner.toLowerCase()) {
    errors.push(`  owner: expected "${owner}", got "${actualOwner}"`);
}
if (nextId !== 0n) {
    errors.push(`  nextTradeId: expected 0, got ${nextId}`);
}

if (errors.length > 0) {
    console.error("Verification failed!");
    for (const e of errors) console.error(e);
    process.exit(1);
}

console.log("\n=== P2PTradeEscrow Deployment Successful ===");
console.log(`Network:        ${connection.networkName} (chainId: ${chainId})`);
console.log(`Implementation: ${impl.address}`);
console.log(`Proxy:          ${proxy.address}`);
console.log(`Owner:          ${actualOwner} ✓`);
console.log(`nextTradeId:    ${nextId} ✓`);
console.log("============================================\n");

// ─── Persist deployment record ────────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
    let existing: Record<string, unknown> = {};
    try { existing = JSON.parse(await readFile(deploymentPath, "utf8")); } catch { /**/ }

    existing["P2PTradeEscrow"] = {
        proxy: proxy.address,
        implementation: impl.address,
        owner,
        deployedAt: new Date().toISOString(),
    };

    await mkdir(deploymentsDir, { recursive: true });
    await writeFile(deploymentPath, JSON.stringify(existing, null, 2) + "\n");
    console.log(`Deployment info saved to deployments/${connection.networkName}.json`);
}
