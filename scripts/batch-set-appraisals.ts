import { network } from "hardhat";
import { getAddress, parseUnits } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile } from "node:fs/promises";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// ─── Types ────────────────────────────────────────────────────────────────────

interface AppraisalEntry {
  tokenId: number;
  value: number | string;
  grade: number;
  category: number;
}

// ─── Parse APPRAISALS_FILE ────────────────────────────────────────────────────

const rawFile = process.env.APPRAISALS_FILE;
if (!rawFile) {
  console.error(
    "Missing APPRAISALS_FILE env var. Set it to the path of a JSON file containing an array of appraisal entries.",
  );
  console.error(
    "  Example: APPRAISALS_FILE=./appraisals.json npx hardhat run scripts/batch-set-appraisals.ts --network sepolia",
  );
  console.error(
    '  JSON format: [{ "tokenId": 1, "value": 1000, "grade": 9, "category": 0 }, ...]',
  );
  process.exit(1);
}

const appraisalsPath = resolve(rawFile);
let appraisals: AppraisalEntry[];
try {
  const raw = await readFile(appraisalsPath, "utf8");
  appraisals = JSON.parse(raw) as AppraisalEntry[];
} catch (err) {
  console.error(
    `Failed to read or parse APPRAISALS_FILE at "${appraisalsPath}": ${err}`,
  );
  process.exit(1);
}

if (!Array.isArray(appraisals) || appraisals.length === 0) {
  console.error(
    `APPRAISALS_FILE must contain a non-empty JSON array. Got: ${JSON.stringify(appraisals).slice(0, 100)}`,
  );
  process.exit(1);
}

// ─── Validate each entry ──────────────────────────────────────────────────────

for (let i = 0; i < appraisals.length; i++) {
  const entry = appraisals[i];
  const ctx = `entry[${i}]`;

  if (
    typeof entry.tokenId !== "number" ||
    !Number.isInteger(entry.tokenId) ||
    entry.tokenId < 0
  ) {
    console.error(
      `${ctx}: "tokenId" must be a non-negative integer. Got: ${JSON.stringify(entry.tokenId)}`,
    );
    process.exit(1);
  }
  const numValue = Number(entry.value);
  if (
    (typeof entry.value !== "number" && typeof entry.value !== "string") ||
    !isFinite(numValue) ||
    numValue < 0
  ) {
    console.error(
      `${ctx}: "value" must be a non-negative number (e.g. 59.99 for $59.99). Got: ${JSON.stringify(entry.value)}`,
    );
    process.exit(1);
  }
  if (
    typeof entry.grade !== "number" ||
    !Number.isInteger(entry.grade) ||
    entry.grade < 0
  ) {
    console.error(
      `${ctx}: "grade" must be a non-negative integer. Got: ${JSON.stringify(entry.grade)}`,
    );
    process.exit(1);
  }
  if (
    typeof entry.category !== "number" ||
    !Number.isInteger(entry.category) ||
    entry.category < 0
  ) {
    console.error(
      `${ctx}: "category" must be a non-negative integer (0 = uncategorized). Got: ${JSON.stringify(entry.category)}`,
    );
    process.exit(1);
  }
}

// ─── SKIP_CONFIRM flag (for backend cron on live networks) ────────────────────

const skipConfirm =
  process.env.SKIP_CONFIRM === "true" || process.env.SKIP_CONFIRM === "1";

// ─── Confirmation prompt (live networks only, unless SKIP_CONFIRM) ────────────

async function confirmUpdate(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
  tokenCount: number,
  batchCount: number,
  decimals: number,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== batchSetAppraisals Summary ===");
  console.log(`Network:              ${networkName}`);
  console.log(`Chain ID:             ${chainId}`);
  console.log(`Caller:               ${caller}`);
  console.log(`Proxy:                ${proxy}`);
  console.log(`Total tokens:         ${tokenCount}`);
  console.log(`Batches:              ${batchCount} (max 50 per tx)`);
  console.log(`Payment token scale:  1 unit → 10^${decimals} base units`);
  console.log("==================================\n");
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

// ─── Resolve proxy address ────────────────────────────────────────────────────

let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.ASSET_LENDING_POOL_PROXY) {
  proxyAddress = getAddress(
    process.env.ASSET_LENDING_POOL_PROXY,
  ) as `0x${string}`;
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
      "Deploy first using deploy-asset-lending-pool.ts, or set ASSET_LENDING_POOL_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  const entry = deploymentData["AssetLendingPool"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "AssetLendingPool proxy address not found in deployment file.",
    );
    console.error("Set ASSET_LENDING_POOL_PROXY to override.");
    process.exit(1);
  }
  proxyAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── Resolve config proxy (batchSetAppraisals lives on AssetLendingPoolConfig) ──
const pool = await viem.getContractAt("AssetLendingPool", proxyAddress);
const configProxyAddress = await pool.read.getConfig();
const config = await viem.getContractAt(
  "AssetLendingPoolConfig",
  configProxyAddress,
);

// ─── Verify caller is owner ───────────────────────────────────────────────────
const owner = await config.read.owner();

if (owner.toLowerCase() !== callerAddress.toLowerCase()) {
  console.error(
    `Account ${callerAddress} is not the owner of proxy ${proxyAddress} (owner: ${owner}).`,
  );
  console.error("batchSetAppraisals is onlyOwner — transaction would revert.");
  process.exit(1);
}

// ─── Read payment token decimals via getPoolInfo ──────────────────────────────

const info = await pool.read.getPoolInfo();
const paymentTokenAddress = info.paymentToken as `0x${string}`;

const erc20MetadataAbi = [
  {
    name: "decimals",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;

const decimals = await publicClient.readContract({
  address: paymentTokenAddress,
  abi: erc20MetadataAbi,
  functionName: "decimals",
});

console.log(`\nPayment token: ${paymentTokenAddress} (${decimals} decimals)`);
console.log(
  `Appraisals loaded: ${appraisals.length} entries from "${appraisalsPath}"`,
);

// ─── Chunk into batches of MAX_BATCH ─────────────────────────────────────────

const MAX_BATCH = 50;
const chunks: AppraisalEntry[][] = [];
for (let i = 0; i < appraisals.length; i += MAX_BATCH) {
  chunks.push(appraisals.slice(i, i + MAX_BATCH));
}

console.log(`Batches: ${chunks.length} (max ${MAX_BATCH} tokens each)`);

// ─── Confirmation on live networks ────────────────────────────────────────────

if (connection.networkConfig.type === "http") {
  if (skipConfirm) {
    console.log("\nSKIP_CONFIRM=true — skipping confirmation prompt.");
  } else {
    const ok = await confirmUpdate(
      connection.networkName,
      chainId,
      callerAddress,
      proxyAddress,
      appraisals.length,
      chunks.length,
      decimals,
    );
    if (!ok) {
      console.log("Cancelled.");
      process.exit(0);
    }
  }
}

// ─── Send batches ─────────────────────────────────────────────────────────────

const txHashes: `0x${string}`[] = [];

for (let ci = 0; ci < chunks.length; ci++) {
  const chunk = chunks[ci];
  const tokenIds = chunk.map((e) => BigInt(e.tokenId));
  const values = chunk.map((e) => parseUnits(String(e.value), decimals));
  const grades = chunk.map((e) => BigInt(e.grade));
  const categories = chunk.map((e) => BigInt(e.category));

  console.log(
    `\n[${ci + 1}/${chunks.length}] Calling batchSetAppraisals for ${chunk.length} token(s)` +
      ` (tokenIds: ${tokenIds.slice(0, 5).map(String).join(", ")}${tokenIds.length > 5 ? ", ..." : ""})...`,
  );

  const txHash = await config.write.batchSetAppraisals(
    [tokenIds, values, grades, categories],
    { account: callerClient.account },
  );
  const receipt = await publicClient.waitForTransactionReceipt({
    hash: txHash,
  });
  console.log(`  tx: ${txHash} (block ${receipt.blockNumber})`);
  txHashes.push(txHash);
}

// ─── Post-tx verification ─────────────────────────────────────────────────────

console.log("\nVerifying appraisals on-chain...");
let mismatches = 0;

for (const entry of appraisals) {
  const tokenId = BigInt(entry.tokenId);
  const expectedValue = parseUnits(String(entry.value), decimals);
  const appraisal = await pool.read.getAppraisal([tokenId]);

  if (
    appraisal.value !== expectedValue ||
    appraisal.grade !== BigInt(entry.grade) ||
    appraisal.category !== BigInt(entry.category) ||
    appraisal.updatedAt === 0n
  ) {
    console.error(
      `CRITICAL: State mismatch for tokenId ${entry.tokenId}!\n` +
        `  Expected: value=${expectedValue}, grade=${entry.grade}, category=${entry.category}\n` +
        `  Got:      value=${appraisal.value}, grade=${appraisal.grade}, category=${appraisal.category}, updatedAt=${appraisal.updatedAt}`,
    );
    mismatches++;
  }
}

if (mismatches > 0) {
  console.error(`\nCRITICAL: ${mismatches} appraisal(s) failed verification.`);
  process.exit(1);
}

console.log(`  All ${appraisals.length} appraisal(s) verified ✓`);

// ─── Summary ──────────────────────────────────────────────────────────────────

console.log("\n=== batchSetAppraisals Complete ===");
console.log(`Network:   ${connection.networkName} (chainId: ${chainId})`);
console.log(`Proxy:     ${proxyAddress}`);
console.log(
  `Tokens:    ${appraisals.length} appraised in ${chunks.length} batch(es)`,
);
for (let i = 0; i < txHashes.length; i++) {
  console.log(`Tx[${i + 1}]:    ${txHashes[i]}`);
}
console.log("===================================\n");
