import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ─── Parse MIN_APPRAISAL_VALUE ────────────────────────────────────────────────

const rawMinValue = process.env.MIN_APPRAISAL_VALUE;
if (rawMinValue === undefined) {
  console.error(
    "Missing MIN_APPRAISAL_VALUE env var. Whole token units (e.g. MIN_APPRAISAL_VALUE=100 for $100).",
  );
  process.exit(1);
}
const minValueNum = Number(rawMinValue);
if (!Number.isInteger(minValueNum) || minValueNum < 0) {
  console.error(
    `Invalid MIN_APPRAISAL_VALUE: "${rawMinValue}". Must be a non-negative integer.`,
  );
  process.exit(1);
}

// ─── Parse MIN_GRADE ──────────────────────────────────────────────────────────

const rawMinGrade = process.env.MIN_GRADE;
if (rawMinGrade === undefined) {
  console.error(
    "Missing MIN_GRADE env var. Numeric grade (e.g. MIN_GRADE=1). Use 0 to disable grade filtering.",
  );
  process.exit(1);
}
const minGradeNum = Number(rawMinGrade);
if (!Number.isInteger(minGradeNum) || minGradeNum < 0) {
  console.error(
    `Invalid MIN_GRADE: "${rawMinGrade}". Must be a non-negative integer.`,
  );
  process.exit(1);
}

// ─── Parse ADD_CATEGORIES / REMOVE_CATEGORIES ─────────────────────────────────
// Comma-separated lists of category IDs, e.g. ADD_CATEGORIES=1,2,3

function parseCategories(envVar: string, name: string): bigint[] {
  const raw = process.env[name];
  if (!raw) return [];
  return raw.split(",").map((s, i) => {
    const n = Number(s.trim());
    if (!Number.isInteger(n) || n < 0) {
      console.error(
        `Invalid ${name}[${i}]: "${s.trim()}". Each category must be a non-negative integer.`,
      );
      process.exit(1);
    }
    return BigInt(n);
  });
}

const addCategories = parseCategories(
  process.env.ADD_CATEGORIES ?? "",
  "ADD_CATEGORIES",
);
const removeCategories = parseCategories(
  process.env.REMOVE_CATEGORIES ?? "",
  "REMOVE_CATEGORIES",
);

// ─── SKIP_CONFIRM flag ────────────────────────────────────────────────────────

const skipConfirm =
  process.env.SKIP_CONFIRM === "true" || process.env.SKIP_CONFIRM === "1";

// ─── Confirmation prompt (live networks only) ─────────────────────────────────

async function confirmUpdate(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
  currentMinValue: bigint,
  currentMinGrade: bigint,
  newMinValue: bigint,
  newMinGrade: bigint,
  scale: bigint,
  decimals: number,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setEligibilityControls Summary ===");
  console.log(`Network:              ${networkName}`);
  console.log(`Chain ID:             ${chainId}`);
  console.log(`Caller:               ${caller}`);
  console.log(`Proxy:                ${proxy}`);
  console.log(
    `Current minAppraisalValue: ${currentMinValue} base units (= ${Number(currentMinValue / scale)} whole units)`,
  );
  console.log(`Current minGrade:           ${currentMinGrade}`);
  console.log(
    `New minAppraisalValue:     ${newMinValue} base units (= ${minValueNum} whole units × 10^${decimals})`,
  );
  console.log(`New minGrade:               ${newMinGrade}`);
  console.log(
    `Add categories:            ${addCategories.length > 0 ? addCategories.map(String).join(", ") : "(none)"}`,
  );
  console.log(
    `Remove categories:         ${removeCategories.length > 0 ? removeCategories.map(String).join(", ") : "(none)"}`,
  );
  console.log("======================================\n");
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
    // No JSON file yet
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

// ─── Resolve config proxy (setEligibilityControls lives on AssetLendingPoolConfig) ──
const pool = await viem.getContractAt("AssetLendingPool", proxyAddress);
const configProxyAddress = await pool.read.getConfig();
const config = await viem.getContractAt("AssetLendingPoolConfig", configProxyAddress);

// ─── Verify caller is owner ───────────────────────────────────────────────────
const owner = await config.read.owner();

if (owner.toLowerCase() !== callerAddress.toLowerCase()) {
  console.error(
    `Account ${callerAddress} is not the owner of proxy ${proxyAddress} (owner: ${owner}).`,
  );
  console.error(
    "setEligibilityControls is onlyOwner — transaction would revert.",
  );
  process.exit(1);
}

// ─── Read current state from getPoolInfo ─────────────────────────────────────

const info = await pool.read.getPoolInfo();
const currentMinValue = info.minAppraisalValue;
const currentMinGrade = info.minGrade;
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

const scale = 10n ** BigInt(decimals);
const newMinValue = BigInt(minValueNum) * scale;
const newMinGrade = BigInt(minGradeNum);

console.log(
  `\nCurrent minAppraisalValue: ${currentMinValue} base units (= ${Number(currentMinValue / scale)} whole units)`,
);
console.log(`Current minGrade:           ${currentMinGrade}`);

// ─── Idempotency check ────────────────────────────────────────────────────────

if (
  currentMinValue === newMinValue &&
  currentMinGrade === newMinGrade &&
  addCategories.length === 0 &&
  removeCategories.length === 0
) {
  console.log("Config already matches. Nothing to do.");
  process.exit(0);
}

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
      currentMinValue,
      currentMinGrade,
      newMinValue,
      newMinGrade,
      scale,
      decimals,
    );
    if (!ok) {
      console.log("Cancelled.");
      process.exit(0);
    }
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────

console.log(
  `\n[1/2] Calling setEligibilityControls(minValue=${newMinValue}, minGrade=${newMinGrade}, add=[${addCategories.map(String).join(", ")}], remove=[${removeCategories.map(String).join(", ")}])...`,
);
const txHash = await config.write.setEligibilityControls(
  [newMinValue, newMinGrade, addCategories, removeCategories],
  { account: callerClient.account },
);
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  tx: ${txHash} (block ${receipt.blockNumber})`);

// ─── Verify ───────────────────────────────────────────────────────────────────

console.log("[2/2] Verifying...");
const infoAfter = await pool.read.getPoolInfo();

if (
  infoAfter.minAppraisalValue !== newMinValue ||
  infoAfter.minGrade !== newMinGrade
) {
  console.error(
    `CRITICAL: State mismatch after update! Expected minAppraisalValue=${newMinValue} minGrade=${newMinGrade}, got minAppraisalValue=${infoAfter.minAppraisalValue} minGrade=${infoAfter.minGrade}`,
  );
  process.exit(1);
}
console.log(`  minAppraisalValue confirmed: ${infoAfter.minAppraisalValue} ✓`);
console.log(`  minGrade confirmed:          ${infoAfter.minGrade} ✓`);

// ─── Summary ──────────────────────────────────────────────────────────────────

console.log("\n=== setEligibilityControls Complete ===");
console.log(`Network:   ${connection.networkName} (chainId: ${chainId})`);
console.log(`Proxy:     ${proxyAddress}`);
console.log(
  `Old:       minAppraisalValue=${currentMinValue}, minGrade=${currentMinGrade}`,
);
console.log(
  `New:       minAppraisalValue=${infoAfter.minAppraisalValue}, minGrade=${infoAfter.minGrade}`,
);
if (addCategories.length > 0)
  console.log(`Added categories:   ${addCategories.map(String).join(", ")}`);
if (removeCategories.length > 0)
  console.log(`Removed categories: ${removeCategories.map(String).join(", ")}`);
console.log(`Tx:        ${txHash}`);
console.log("=======================================\n");

// ─── Persist to deployments/<network>.json (live networks only) ───────────────

if (connection.networkConfig.type === "http") {
  const poolEntry =
    (deploymentData["AssetLendingPool"] as Record<string, unknown>) ?? {};
  deploymentData["AssetLendingPool"] = {
    ...poolEntry,
    minAppraisalValue: infoAfter.minAppraisalValue.toString(),
    minGrade: infoAfter.minGrade.toString(),
    eligibilityUpdatedAt: new Date().toISOString(),
  };
  await writeFile(
    deploymentPath,
    JSON.stringify(deploymentData, null, 2) + "\n",
  );
  console.log(
    `Deployment info updated at deployments/${connection.networkName}.json`,
  );
}
