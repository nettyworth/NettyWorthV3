/**
 * deploy-p2p-trade-escrow.ts
 *
 * Deploys the P2PTradeEscrow implementation behind an ERC-1967 / UUPS proxy
 * and initializes it with `owner`. Standalone contract — no PermissionManager
 * roles or wiring needed.
 *
 * Staging and production share the `base` network (same chain, same key), so
 * the deployment record file is selectable via DEPLOYMENTS_FILE to keep a
 * staging deploy out of the production record (deployments/base.json).
 *
 * Usage
 * -----
 * # Staging on Base (records into deployments/base.staging.snapshot.json):
 * DEPLOYMENTS_FILE=base.staging.snapshot \
 *   npx hardhat run scripts/deploy-p2p-trade-escrow.ts --network base
 *
 * # Replace the staging deployment with a fresh one (overwrites its record):
 * FORCE_REDEPLOY=1 DEPLOYMENTS_FILE=base.staging.snapshot \
 *   REFUND_RECIPIENT=0x<wallet> ALLOWED_ERC20=0x<usdc> ALLOWED_ERC721=0x<assetNFT> \
 *   npx hardhat run scripts/deploy-p2p-trade-escrow.ts --network base
 *
 * # Production on Base (records into deployments/base.json):
 * OWNER=0x<safe> REFUND_RECIPIENT=0x<wallet> ALLOWED_ERC20=0x<usdc> ALLOWED_ERC721=0x<assetNFT> \
 *   npx hardhat run scripts/deploy-p2p-trade-escrow.ts --network base
 *
 * # Dry-run on a local fork (no prompt, no JSON write):
 * npx hardhat run scripts/deploy-p2p-trade-escrow.ts --network forkBase
 *
 * Optional env vars:
 *   OWNER             — final owner (default: deployer); when it differs from
 *                       the deployer it must call acceptOwnership()
 *   REFUND_RECIPIENT  — wallet refunded for externally funded (Coinflow) offers;
 *                       those offers revert until it is set
 *   ALLOWED_ERC20 / ALLOWED_ERC721 / ALLOWED_ERC1155
 *                     — comma-separated token allow-list per asset type; no
 *                       trade can be created with a token that isn't on it
 *   DEPLOYMENTS_FILE  — record file basename under deployments/
 *                       (default: the network name)
 *   FORCE_REDEPLOY=1  — deploy even if the record file already has a
 *                       P2PTradeEscrow entry (the old entry is overwritten)
 */

import { network } from "hardhat";
import { encodeFunctionData, getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import {
    readDeployments,
    saveDeployment,
    waitForCode,
} from "./lib/deployments.js";

async function confirm(
    networkName: string,
    chainId: number,
    deployer: string,
    owner: string,
    refundRecipient: string | null,
    allowed: AllowedToken[],
    recordFile: string,
): Promise<boolean> {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    console.log("\n=== P2PTradeEscrow Deployment Summary ===");
    console.log(`Network:   ${networkName}`);
    console.log(`Chain ID:  ${chainId}`);
    console.log(`Deployer:  ${deployer}`);
    console.log(`Owner:     ${owner}${owner.toLowerCase() === deployer.toLowerCase() ? "" : " (transferred after setup; must acceptOwnership)"}`);
    console.log(`Refunds:   ${refundRecipient ?? "(none — set later with setRefundRecipient)"}`);
    console.log(`Tokens:    ${allowed.length ? allowed.map((t) => `${t.label} ${t.token}`).join(", ") : "(none — no trade can be created)"}`);
    console.log(`Record:    deployments/${recordFile}.json`);
    console.log("=========================================\n");
    const answer = await rl.question("Proceed with deployment? (yes/no): ");
    rl.close();
    return answer.toLowerCase() === "yes";
}

const connection = await network.create();
const { viem } = connection;
const isLive = connection.networkConfig.type === "http";

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

const recordFile = process.env.DEPLOYMENTS_FILE ?? connection.networkName;

// ─── Guard against losing track of an existing deployment ────────────────────
if (isLive && process.env.FORCE_REDEPLOY !== "1") {
    const existing = (await readDeployments(recordFile))["P2PTradeEscrow"] as
        | { proxy?: string }
        | undefined;
    if (existing) {
        console.error(
            `deployments/${recordFile}.json already records P2PTradeEscrow at ${existing.proxy}.\n` +
                "Set FORCE_REDEPLOY=1 to deploy a new one and overwrite the record.",
        );
        process.exit(1);
    }
}

// ─── Confirmation prompt ──────────────────────────────────────────────────────
if (isLive) {
    const ok = await confirm(
        connection.networkName,
        chainId,
        deployerAddress,
        owner,
        refundRecipient,
        allowed,
        recordFile,
    );
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
await waitForCode(publicClient, proxy.address);
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
if (isLive) {
    await saveDeployment(recordFile, "P2PTradeEscrow", {
        proxy: proxy.address,
        implementation: impl.address,
        owner,
        ownerAccepted: !transfersOwnership,
        refundRecipient,
        allowedTokens: allowed.map(({ token, label }) => ({ token, type: label })),
        deployedAt: new Date().toISOString(),
    });
    console.log(`Deployment info saved to deployments/${recordFile}.json`);
}
