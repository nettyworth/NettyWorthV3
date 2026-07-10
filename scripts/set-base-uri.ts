import { network } from "hardhat";
import { getAddress, keccak256, toBytes } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { saveDeployment } from "./lib/deployments.js";
import { sleep } from "./lib/sleep.js";

// ─── URI_SETTER_ROLE = keccak256("URI_SETTER_ROLE") ──────────────────────────
const URI_SETTER_ROLE = keccak256(toBytes("URI_SETTER_ROLE"));

// ─── Parse ASSET_NFT_BASE_URI ─────────────────────────────────────────────────
const newBaseURI = process.env.ASSET_NFT_BASE_URI;

if (!newBaseURI) {
  console.error(
    "Missing ASSET_NFT_BASE_URI environment variable.\n" +
      'Example: ASSET_NFT_BASE_URI="https://staging-v2-api.nettyworth.io/api/v2/trading-cards/metadata/"',
  );
  process.exit(1);
}

if (!newBaseURI.endsWith("/")) {
  console.warn(
    `WARNING: ASSET_NFT_BASE_URI does not end with a trailing slash ("${newBaseURI}").\n` +
      "  tokenURI(N) will resolve to <baseURI><N> with NO separator.\n" +
      '  Recommended: add a trailing slash, e.g. "…/metadata/".',
  );
}

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirmUpdate(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
  currentURI: string | null,
  newURI: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setBaseURI Summary ===");
  console.log(`Network:     ${networkName}`);
  console.log(`Chain ID:    ${chainId}`);
  console.log(`Caller:      ${caller}`);
  console.log(`Proxy:       ${proxy}`);
  if (currentURI !== null) {
    console.log(`Current:     ${currentURI || "(empty)"}`);
  }
  console.log(`New:         ${newURI}`);
  console.log("==========================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  return answer.toLowerCase() === "yes";
}

// ─── Network connection ───────────────────────────────────────────────────────
const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [callerClient] = await viem.getWalletClients();
const callerAddress = callerClient.account.address;
const chainId = await publicClient.getChainId();

const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../deployments",
);
const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);

// ─── Resolve AssetNFT proxy address ──────────────────────────────────────────
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.ASSET_NFT_PROXY) {
  proxyAddress = getAddress(process.env.ASSET_NFT_PROXY) as `0x${string}`;
  try {
    deploymentData = JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    // No JSON file yet — skip persistence
  }
} else {
  try {
    deploymentData = JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    console.error(`No deployment file found at ${deploymentPath}`);
    console.error(
      "Deploy first using deploy-asset-nft.ts, or set ASSET_NFT_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  const entry = deploymentData["AssetNFT"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error("AssetNFT proxy address not found in deployment file.");
    console.error("Set ASSET_NFT_PROXY to override.");
    process.exit(1);
  }
  proxyAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── Verify URI_SETTER_ROLE ───────────────────────────────────────────────────
const assetNFT = await viem.getContractAt("AssetNFT", proxyAddress);
let hasRole = false;

try {
  const pmAddress = await assetNFT.read.getPermissionManager();
  const pm = await viem.getContractAt("PermissionManager", pmAddress);
  hasRole = await pm.read.hasProtocolRole([URI_SETTER_ROLE, callerAddress]);
} catch {
  console.warn(
    "Could not verify URI_SETTER_ROLE. Proceeding, but the transaction may fail.",
  );
  hasRole = true;
}

if (!hasRole) {
  console.error(
    `Account ${callerAddress} does not have URI_SETTER_ROLE on proxy ${proxyAddress}.\n` +
      "Grant it first using scripts/grant-role.ts.",
  );
  process.exit(1);
}

// ─── Read current tokenURI for token 1 (best-effort) ─────────────────────────
let currentURI: string | null = null;
let sampleTokenId: bigint | null = null;
try {
  const currentTokenURI = await assetNFT.read.tokenURI([1n]);
  currentURI = currentTokenURI;
  sampleTokenId = 1n;
  console.log(`\nCurrent tokenURI(1): ${currentTokenURI || "(empty)"}`);
} catch {
  console.log(
    "\nCould not read tokenURI(1) — no tokens minted yet or token 1 does not exist.",
  );
}

// ─── Confirmation on live networks ────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirmUpdate(
    connection.networkName,
    chainId,
    callerAddress,
    proxyAddress,
    currentURI,
    newBaseURI,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────
console.log(`\n[1/2] Calling setBaseURI("${newBaseURI}")...`);
const txHash = await assetNFT.write.setBaseURI([newBaseURI], {
  account: callerClient.account,
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  tx: ${txHash} (block ${receipt.blockNumber})`);
await sleep(2000);

// ─── Verify ───────────────────────────────────────────────────────────────────
console.log("[2/2] Verifying...");
if (sampleTokenId !== null) {
  const updatedTokenURI = await assetNFT.read.tokenURI([sampleTokenId]);
  if (!updatedTokenURI.startsWith(newBaseURI)) {
    console.error(
      `CRITICAL: tokenURI(${sampleTokenId}) does not start with the new base URI!\n` +
        `  Expected prefix: ${newBaseURI}\n` +
        `  Got:             ${updatedTokenURI}`,
    );
    process.exit(1);
  }
  console.log(`  tokenURI(${sampleTokenId}) = ${updatedTokenURI} ✓`);
} else {
  // No token to read — check the event instead
  const baseURIUpdatedTopic = keccak256(
    toBytes("BaseURIUpdated(string)"),
  ) as `0x${string}`;
  const eventFound = receipt.logs.some(
    (log) =>
      log.address.toLowerCase() === proxyAddress.toLowerCase() &&
      log.topics[0] === baseURIUpdatedTopic,
  );
  if (eventFound) {
    console.log(
      "  BaseURIUpdated event emitted ✓ (no tokens minted yet — tokenURI read skipped)",
    );
  } else {
    console.warn(
      "  WARNING: BaseURIUpdated event not found in receipt logs. Verify manually.",
    );
  }
}

console.log("\n=== setBaseURI Complete ===");
console.log(`Network: ${connection.networkName} (chainId: ${chainId})`);
console.log(`Proxy:   ${proxyAddress}`);
console.log(`New base URI: ${newBaseURI}`);
console.log(`Tx:      ${txHash}`);
console.log("===========================\n");

// ─── Persist to deployments/<network>.json (live networks only) ───────────────
if (connection.networkConfig.type === "http") {
  const assetNFTEntry =
    (deploymentData["AssetNFT"] as Record<string, unknown>) ?? {};
  await saveDeployment(connection.networkName, "AssetNFT", {
    ...assetNFTEntry,
    baseURI: newBaseURI,
    baseURIUpdatedAt: new Date().toISOString(),
  });
  console.log(
    `Deployment info updated at deployments/${connection.networkName}.json`,
  );
}
