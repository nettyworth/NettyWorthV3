import { network } from "hardhat";
import { encodeFunctionData, getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { saveDeployment, waitForCode } from "./lib/deployments.js";

async function confirm(
    networkName: string,
    chainId: number,
    deployer: string,
    owner: string,
    refundRecipient: string | null,
    allowed: AllowedToken[],
): Promise<boolean> {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    console.log("\n=== P2PTradeEscrow Deployment Summary ===");
    console.log(`Network:   ${networkName}`);
    console.log(`Chain ID:  ${chainId}`);
    console.log(`Deployer:  ${deployer}`);
    console.log(`Owner:     ${owner}${owner.toLowerCase() === deployer.toLowerCase() ? "" : " (transferred after setup; must acceptOwnership)"}`);
    console.log(`Refunds:   ${refundRecipient ?? "(none — set later with setRefundRecipient)"}`);
    console.log(`Tokens:    ${allowed.length ? allowed.map((t) => `${t.label} ${t.token}`).join(", ") : "(none — no trade can be created)"}`);
    console.log(`Record:    deployments/${networkName}.json`);
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

// The proxy is initialised with the deployer as owner so this script can configure it, then
// ownership is handed to OWNER (e.g. the Safe) with Ownable2Step: OWNER must call
// acceptOwnership() to take it. Without OWNER the deployer stays owner (fine for testnets,
// not for production — the owner can upgrade the escrow and redirect refunds).
const owner: `0x${string}` = process.env.OWNER
    ? (getAddress(process.env.OWNER) as `0x${string}`)
    : deployerAddress;
const transfersOwnership = owner.toLowerCase() !== deployerAddress.toLowerCase();

// Refund recipient = the NettyWorth wallet (treasury) that receives offered ERC20 refunds of
// externally funded (Coinflow) trades and may cancel them on a chargeback. Externally
// funded offers revert until it is set.
const refundRecipient: `0x${string}` | null = process.env.REFUND_RECIPIENT
    ? (getAddress(process.env.REFUND_RECIPIENT) as `0x${string}`)
    : null;

// Token allow-list — no trade can be created with a token that isn't on it. Comma-separated
// addresses per asset type, e.g. ALLOWED_ERC20=<USDC> ALLOWED_ERC721=<AssetNFT>.
// ERC1155 has a recipient hook that can grief refunds; leave it empty unless intended.
type AllowedToken = { token: `0x${string}`; assetType: number; label: string };
const ASSET_TYPES = [
    { env: "ALLOWED_ERC20", assetType: 0, label: "ERC20" },
    { env: "ALLOWED_ERC721", assetType: 1, label: "ERC721" },
    { env: "ALLOWED_ERC1155", assetType: 2, label: "ERC1155" },
];
const allowed: AllowedToken[] = ASSET_TYPES.flatMap(({ env, assetType, label }) =>
    (process.env[env] ?? "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
        .map((a) => ({ token: getAddress(a) as `0x${string}`, assetType, label })),
);

// ─── Confirmation prompt ──────────────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
    const ok = await confirm(connection.networkName, chainId, deployerAddress, owner, refundRecipient, allowed);
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
    args: [deployerAddress],
});

// ─── [3/4] Deploy ERC-1967 proxy ─────────────────────────────────────────────
console.log("[3/4] Deploying ERC1967 proxy...");
await waitForCode(publicClient, impl.address);
const proxy = await viem.deployContract("ERC1967ProxyHelper", [impl.address, initData]);
console.log(`  Proxy: ${proxy.address}`);

// ─── [4/4] Configure, hand over ownership, verify ─────────────────────────────
console.log("[4/4] Configuring and verifying deployment...");
const escrow = await viem.getContractAt("P2PTradeEscrow", proxy.address);

if (refundRecipient) {
    console.log(`  Setting refund recipient ${refundRecipient}...`);
    const hash = await escrow.write.setRefundRecipient([refundRecipient]);
    await publicClient.waitForTransactionReceipt({ hash });
}
for (const t of allowed) {
    console.log(`  Allowing ${t.label} ${t.token}...`);
    const hash = await escrow.write.setTokenAllowed([t.token, t.assetType, true]);
    await publicClient.waitForTransactionReceipt({ hash });
}
if (transfersOwnership) {
    console.log(`  Transferring ownership to ${owner} (pending its acceptOwnership)...`);
    const hash = await escrow.write.transferOwnership([owner]);
    await publicClient.waitForTransactionReceipt({ hash });
}

const actualOwner = await escrow.read.owner();
const pendingOwner = await escrow.read.pendingOwner();
const nextId = await escrow.read.nextTradeId();
const [, domainName, domainVersion] = await escrow.read.eip712Domain();

const errors: string[] = [];
if (actualOwner.toLowerCase() !== deployerAddress.toLowerCase()) {
    errors.push(`  owner: expected deployer "${deployerAddress}", got "${actualOwner}"`);
}
if (transfersOwnership && pendingOwner.toLowerCase() !== owner.toLowerCase()) {
    errors.push(`  pendingOwner: expected "${owner}", got "${pendingOwner}"`);
}
for (const t of allowed) {
    if (!(await escrow.read.isTokenAllowed([t.token, t.assetType]))) {
        errors.push(`  allow-list: ${t.label} ${t.token} not allowed`);
    }
}
if (nextId !== 0n) {
    errors.push(`  nextTradeId: expected 0, got ${nextId}`);
}
if (domainName !== "P2PTradeEscrow" || domainVersion !== "1") {
    errors.push(`  eip712Domain: expected P2PTradeEscrow/1, got ${domainName}/${domainVersion}`);
}
const actualRefundRecipient = await escrow.read.refundRecipient();
if (refundRecipient && actualRefundRecipient.toLowerCase() !== refundRecipient.toLowerCase()) {
    errors.push(`  refundRecipient: expected "${refundRecipient}", got "${actualRefundRecipient}"`);
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
if (transfersOwnership) {
    console.log(`Pending owner:  ${pendingOwner} ✓ — must call acceptOwnership() to take over`);
}
console.log(`nextTradeId:    ${nextId} ✓`);
console.log(`EIP-712:        ${domainName} v${domainVersion} ✓`);
console.log(`Refunds:        ${refundRecipient ? `${refundRecipient} ✓` : "(not set — externally funded offers revert)"}`);
console.log(`Tokens:         ${allowed.length ? allowed.map((t) => `${t.label} ${t.token}`).join(", ") + " ✓" : "(none — no trade can be created)"}`);
console.log("============================================\n");

// ─── Persist deployment record ────────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
    await saveDeployment(connection.networkName, "P2PTradeEscrow", {
        proxy: proxy.address,
        implementation: impl.address,
        owner,
        ownerAccepted: !transfersOwnership,
        refundRecipient,
        allowedTokens: allowed.map(({ token, label }) => ({ token, type: label })),
        deployedAt: new Date().toISOString(),
    });
    console.log(`Deployment info saved to deployments/${connection.networkName}.json`);
}
