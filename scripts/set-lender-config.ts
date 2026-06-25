import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ─── Parse SHARE_BPS ──────────────────────────────────────────────────────────
const rawShareBps = process.env.SHARE_BPS;
if (!rawShareBps) {
  console.error(
    "Missing SHARE_BPS env var. Set it to a value between 0 and 10000 (e.g. SHARE_BPS=8000).",
  );
  process.exit(1);
}
const newShareBpsNum = Number(rawShareBps);
if (
  !Number.isInteger(newShareBpsNum) ||
  newShareBpsNum < 0 ||
  newShareBpsNum > 10_000
) {
  console.error(
    `Invalid SHARE_BPS: "${rawShareBps}". Must be an integer between 0 and 10000 (inclusive).`,
  );
  process.exit(1);
}
const newShareBps = BigInt(newShareBpsNum);

// ─── Parse ENABLED ────────────────────────────────────────────────────────────
const rawEnabled = process.env.ENABLED;
if (rawEnabled === undefined) {
  console.error(
    'Missing ENABLED env var. Set it to "true", "false", "1", or "0" (e.g. ENABLED=true).',
  );
  process.exit(1);
}
let newEnabled: boolean;
if (rawEnabled === "true" || rawEnabled === "1") {
  newEnabled = true;
} else if (rawEnabled === "false" || rawEnabled === "0") {
  newEnabled = false;
} else {
  console.error(
    `Invalid ENABLED: "${rawEnabled}". Must be "true", "false", "1", or "0".`,
  );
  process.exit(1);
}

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirmUpdate(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
  oldShareBps: bigint,
  oldEnabled: boolean,
  newShareBpsVal: bigint,
  newEnabledVal: boolean,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setLenderConfig Summary ===");
  console.log(`Network:              ${networkName}`);
  console.log(`Chain ID:             ${chainId}`);
  console.log(`Caller:               ${caller}`);
  console.log(`Proxy:                ${proxy}`);
  console.log(
    `Current lenderShareBps:      ${oldShareBps.toString()} bps (${Number(oldShareBps) / 100}%)`,
  );
  console.log(`Current lenderDepositsEnabled: ${oldEnabled}`);
  console.log(
    `New lenderShareBps:          ${newShareBpsVal.toString()} bps (${Number(newShareBpsVal) / 100}%)`,
  );
  console.log(`New lenderDepositsEnabled:     ${newEnabledVal}`);
  console.log("================================\n");
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

// ─── Verify caller is owner ───────────────────────────────────────────────────
const pool = await viem.getContractAt("AssetLendingPool", proxyAddress);
const owner = await pool.read.owner();

if (owner.toLowerCase() !== callerAddress.toLowerCase()) {
  console.error(
    `Account ${callerAddress} is not the owner of proxy ${proxyAddress} (owner: ${owner}).`,
  );
  console.error("setLenderConfig is onlyOwner — transaction would revert.");
  process.exit(1);
}

// ─── Read current lender config from getPoolInfo ──────────────────────────────
const info = await pool.read.getPoolInfo();
const currentShareBps = info.lenderShareBps;
const currentEnabled = info.lenderDepositsEnabled;

console.log(`\nCurrent lenderShareBps:      ${currentShareBps.toString()} bps`);
console.log(`Current lenderDepositsEnabled: ${currentEnabled}`);

if (currentShareBps === newShareBps && currentEnabled === newEnabled) {
  console.log(
    `lenderShareBps is already ${newShareBps.toString()} bps and lenderDepositsEnabled is already ${newEnabled}. Nothing to do.`,
  );
  process.exit(0);
}

// ─── Confirmation on live networks ────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirmUpdate(
    connection.networkName,
    chainId,
    callerAddress,
    proxyAddress,
    currentShareBps,
    currentEnabled,
    newShareBps,
    newEnabled,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────
console.log(
  `\n[1/2] Calling setLenderConfig(${newShareBps.toString()}, ${newEnabled})...`,
);
const txHash = await pool.write.setLenderConfig([newShareBps, newEnabled], {
  account: callerClient.account,
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  tx: ${txHash} (block ${receipt.blockNumber})`);

// ─── Verify via getPoolInfo ───────────────────────────────────────────────────
console.log("[2/2] Verifying...");
const infoAfter = await pool.read.getPoolInfo();

if (
  infoAfter.lenderShareBps !== newShareBps ||
  infoAfter.lenderDepositsEnabled !== newEnabled
) {
  console.error(
    `CRITICAL: State mismatch after update! Expected lenderShareBps=${newShareBps} enabled=${newEnabled}, got lenderShareBps=${infoAfter.lenderShareBps} enabled=${infoAfter.lenderDepositsEnabled}`,
  );
  process.exit(1);
}
console.log(
  `  lenderShareBps confirmed: ${infoAfter.lenderShareBps.toString()} bps ✓`,
);
console.log(
  `  lenderDepositsEnabled confirmed: ${infoAfter.lenderDepositsEnabled} ✓`,
);

console.log("\n=== setLenderConfig Complete ===");
console.log(`Network:   ${connection.networkName} (chainId: ${chainId})`);
console.log(`Proxy:     ${proxyAddress}`);
console.log(
  `Old:       lenderShareBps=${currentShareBps.toString()} bps, lenderDepositsEnabled=${currentEnabled}`,
);
console.log(
  `New:       lenderShareBps=${infoAfter.lenderShareBps.toString()} bps, lenderDepositsEnabled=${infoAfter.lenderDepositsEnabled}`,
);
console.log(`Tx:        ${txHash}`);
console.log("================================\n");

// ─── Persist to deployments/<network>.json (live networks only) ───────────────
if (connection.networkConfig.type === "http") {
  const poolEntry =
    (deploymentData["AssetLendingPool"] as Record<string, unknown>) ?? {};
  deploymentData["AssetLendingPool"] = {
    ...poolEntry,
    lenderShareBps: infoAfter.lenderShareBps.toString(),
    lenderDepositsEnabled: infoAfter.lenderDepositsEnabled,
    lenderConfigUpdatedAt: new Date().toISOString(),
  };

  await writeFile(
    deploymentPath,
    JSON.stringify(deploymentData, null, 2) + "\n",
  );
  console.log(
    `Deployment info updated at deployments/${connection.networkName}.json`,
  );
}
