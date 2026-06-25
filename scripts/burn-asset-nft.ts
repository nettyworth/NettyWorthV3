import { network } from "hardhat";
import { getAddress, keccak256, toBytes } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ─── Parse TOKEN_IDS env (range "1-50", comma "1,2,5", or combined "1-10,15") ─
function parseTokenIds(input: string): bigint[] {
  const ids: bigint[] = [];
  for (const part of input.split(",")) {
    const trimmed = part.trim();
    const rangeMatch = trimmed.match(/^(\d+)-(\d+)$/);
    if (rangeMatch) {
      const start = BigInt(rangeMatch[1]);
      const end = BigInt(rangeMatch[2]);
      if (end < start) throw new Error(`Invalid range: ${trimmed}`);
      for (let id = start; id <= end; id++) ids.push(id);
    } else if (/^\d+$/.test(trimmed)) {
      ids.push(BigInt(trimmed));
    } else {
      throw new Error(`Invalid TOKEN_IDS segment: "${trimmed}"`);
    }
  }
  return ids;
}

const BURNER_ROLE = keccak256(toBytes("BURNER_ROLE"));
const BATCH_SIZE = 50;

// ─── Validate TOKEN_IDS ───────────────────────────────────────────────────────
const rawTokenIds = process.env.TOKEN_IDS;
if (!rawTokenIds) {
  console.error("Missing required env var: TOKEN_IDS");
  console.error(
    'Accepts ranges ("1-50"), comma lists ("1,2,5"), or combinations ("1-10,15,20-25").',
  );
  process.exit(1);
}

let tokenIds: bigint[];
try {
  tokenIds = parseTokenIds(rawTokenIds);
} catch (e) {
  console.error(
    `Invalid TOKEN_IDS: ${e instanceof Error ? e.message : String(e)}`,
  );
  process.exit(1);
}

if (tokenIds.length === 0) {
  console.error("TOKEN_IDS resolved to an empty list.");
  process.exit(1);
}

if (tokenIds.length > 10_000) {
  console.error(
    `TOKEN_IDS list is too large (${tokenIds.length}). Cap at 10,000 to prevent runaway burns.`,
  );
  process.exit(1);
}

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirmBurn(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
  ids: bigint[],
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== batchBurn Summary ===");
  console.log(`Network:    ${networkName}`);
  console.log(`Chain ID:   ${chainId}`);
  console.log(`Caller:     ${caller}`);
  console.log(`AssetNFT:   ${proxy}`);
  console.log(
    `Tokens:     ${ids.length} (${Math.ceil(ids.length / BATCH_SIZE)} batch(es) of ≤${BATCH_SIZE})`,
  );
  console.log(
    `Token IDs:  ${ids.slice(0, 10).join(", ")}${ids.length > 10 ? ` … (+${ids.length - 10} more)` : ""}`,
  );
  console.log("=========================");
  console.warn(
    "\n⚠  Burn is IRREVERSIBLE. Tokens will be permanently destroyed.\n",
  );
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

// ─── Resolve AssetNFT proxy ───────────────────────────────────────────────────
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.ASSET_NFT_PROXY) {
  proxyAddress = getAddress(process.env.ASSET_NFT_PROXY) as `0x${string}`;
  try {
    deploymentData = JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    // No deployment file yet — skip persistence
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

// ─── Resolve PermissionManager proxy ─────────────────────────────────────────
let pmAddress: `0x${string}`;

if (process.env.PERMISSION_MANAGER_PROXY) {
  pmAddress = getAddress(process.env.PERMISSION_MANAGER_PROXY) as `0x${string}`;
} else {
  const pmEntry = deploymentData["PermissionManager"] as
    | Record<string, unknown>
    | undefined;
  if (!pmEntry?.proxy) {
    console.error(
      "PermissionManager proxy address not found in deployment file.",
    );
    console.error("Set PERMISSION_MANAGER_PROXY to override.");
    process.exit(1);
  }
  pmAddress = getAddress(pmEntry.proxy as string) as `0x${string}`;
}

// ─── Verify caller holds BURNER_ROLE ─────────────────────────────────────────
const pm = await viem.getContractAt("PermissionManager", pmAddress);
const hasBurnerRole = await pm.read.hasProtocolRole([
  BURNER_ROLE,
  callerAddress,
]);
if (!hasBurnerRole) {
  console.error(
    `Account ${callerAddress} does not have BURNER_ROLE on PermissionManager ${pmAddress}`,
  );
  console.error(
    `Grant it first: ROLE=BURNER_ROLE ACCOUNT=${callerAddress} npx hardhat run scripts/grant-role.ts --network ${connection.networkName}`,
  );
  process.exit(1);
}

// ─── Preview token state (first batch only) ──────────────────────────────────
console.log(`\nAssetNFT proxy: ${proxyAddress}`);
console.log(`Tokens to burn: ${tokenIds.length}`);

// ─── Confirmation on live networks ────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirmBurn(
    connection.networkName,
    chainId,
    callerAddress,
    proxyAddress,
    tokenIds,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Burn in batches of ≤50 ───────────────────────────────────────────────────
const nft = await viem.getContractAt("AssetNFT", proxyAddress);
const totalBatches = Math.ceil(tokenIds.length / BATCH_SIZE);
console.log(
  `\nBurning ${tokenIds.length} tokens in ${totalBatches} batch(es)...`,
);

const txHashes: `0x${string}`[] = [];
let totalBurned = 0;

for (let i = 0; i < tokenIds.length; i += BATCH_SIZE) {
  const batch = tokenIds.slice(i, i + BATCH_SIZE);
  const batchNum = Math.floor(i / BATCH_SIZE) + 1;
  process.stdout.write(
    `  [${batchNum}/${totalBatches}] Burning tokens ${batch[0]}–${batch[batch.length - 1]}...`,
  );

  const hash = await nft.write.batchBurn([batch], {
    account: callerClient.account,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });

  process.stdout.write(` tx: ${hash} (block ${receipt.blockNumber})\n`);
  txHashes.push(hash);
  totalBurned += batch.length;
}

// ─── Summary ──────────────────────────────────────────────────────────────────
console.log("\n=== batchBurn Complete ===");
console.log(`Network:    ${connection.networkName} (chainId: ${chainId})`);
console.log(`AssetNFT:   ${proxyAddress}`);
console.log(`Burned:     ${totalBurned} tokens`);
console.log(`Batches:    ${txHashes.length}`);
txHashes.forEach((h, idx) => console.log(`  Batch ${idx + 1}: ${h}`));
console.log("==========================\n");

// ─── Persist audit trail (live networks only) ─────────────────────────────────
if (connection.networkConfig.type === "http") {
  const existing = (deploymentData["BurnHistory"] as unknown[]) ?? [];
  deploymentData["BurnHistory"] = [
    ...existing,
    {
      burnedBy: callerAddress,
      tokenIds: tokenIds.map((id) => id.toString()),
      txHashes,
      burnedAt: new Date().toISOString(),
    },
  ];

  await mkdir(deploymentsDir, { recursive: true });
  await writeFile(
    deploymentPath,
    JSON.stringify(deploymentData, null, 2) + "\n",
  );
  console.log(
    `Burn history updated at deployments/${connection.networkName}.json`,
  );
}
