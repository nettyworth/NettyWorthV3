/**
 * set-max-appraisal-age.ts
 *
 * Set the maximum allowed age for an appraisal on AssetLendingPoolConfig.
 * Appraisals older than this are rejected at origination with
 * AssetLendingPool__AppraisalStale. It defaults to 7 days at initialize();
 * passing 0 disables staleness checking entirely.
 *
 * This is the direct-EOA path — it only works while an EOA still owns the
 * config proxy (forks, testnets, pre-handoff networks). Once ownership has
 * moved to the Safe (as on Base), use
 * scripts/generate-safe-set-max-appraisal-age.ts instead.
 *
 * Usage
 * -----
 * # Set a 30-day staleness window on Base Sepolia:
 * MAX_APPRAISAL_AGE=2592000 npx hardhat run scripts/set-max-appraisal-age.ts --network baseSepolia
 *
 * # Disable staleness checking, overriding the config proxy directly:
 * MAX_APPRAISAL_AGE=0 CONFIG_PROXY=0x<addr> \
 *   npx hardhat run scripts/set-max-appraisal-age.ts --network forkBase
 *
 * # Or override the pool proxy (config is resolved via on-chain getConfig()):
 * MAX_APPRAISAL_AGE=604800 ASSET_LENDING_POOL_PROXY=0x<addr> \
 *   npx hardhat run scripts/set-max-appraisal-age.ts --network baseSepolia
 *
 * Environment variables
 * ---------------------
 * MAX_APPRAISAL_AGE         (required) new max age in SECONDS; 0 disables the check
 * ASSET_LENDING_POOL_PROXY  override pool proxy (optional)
 * CONFIG_PROXY              override config proxy directly (optional; takes precedence)
 */

import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments, saveDeployment } from "./lib/deployments.js";
import { sleep } from "./lib/sleep.js";

const ONE_YEAR = 365n * 24n * 60n * 60n;

function seconds(value: bigint): string {
  const days = Number(value) / 86400;
  return `${value}s (${days % 1 === 0 ? days : days.toFixed(2)} day${days === 1 ? "" : "s"})`;
}

// ─── Parse MAX_APPRAISAL_AGE ──────────────────────────────────────────────────

const rawAge = process.env.MAX_APPRAISAL_AGE;
if (rawAge === undefined || rawAge === "") {
  console.error("Missing required env variable MAX_APPRAISAL_AGE.");
  console.error(
    "Usage: MAX_APPRAISAL_AGE=<seconds> npx hardhat run scripts/set-max-appraisal-age.ts --network <net>",
  );
  console.error(
    "There is deliberately no default — 0 silently disables staleness checking.",
  );
  process.exit(1);
}
if (!/^\d+$/.test(rawAge.trim())) {
  console.error(
    `Invalid MAX_APPRAISAL_AGE: "${rawAge}". Must be a non-negative integer number of SECONDS (e.g. 2592000 for 30 days).`,
  );
  process.exit(1);
}
const targetAge = BigInt(rawAge.trim());

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [callerClient] = await viem.getWalletClients();
const callerAddress = callerClient.account.address;
const chainId = await publicClient.getChainId();

// ─── Resolve config proxy address ────────────────────────────────────────────

let configProxyAddress: `0x${string}`;

if (process.env.CONFIG_PROXY) {
  // Direct config proxy override
  configProxyAddress = getAddress(process.env.CONFIG_PROXY) as `0x${string}`;
} else {
  // Reach the config proxy via the pool proxy
  let poolProxy: `0x${string}`;

  if (process.env.ASSET_LENDING_POOL_PROXY) {
    poolProxy = getAddress(
      process.env.ASSET_LENDING_POOL_PROXY,
    ) as `0x${string}`;
  } else {
    const deploymentData = await readDeployments(connection.networkName);
    const entry = deploymentData["AssetLendingPool"] as
      | Record<string, unknown>
      | undefined;
    if (!entry?.proxy) {
      console.error(
        `AssetLendingPool proxy address not found in deployments/${connection.networkName}.json.`,
      );
      console.error(
        "Deploy first using deploy-asset-lending-pool.ts, or set ASSET_LENDING_POOL_PROXY / CONFIG_PROXY to override.",
      );
      process.exit(1);
    }
    poolProxy = getAddress(entry.proxy as string) as `0x${string}`;
  }

  const pool = await viem.getContractAt("AssetLendingPool", poolProxy);
  configProxyAddress = await pool.read.getConfig();
}

// ─── Contract instance ────────────────────────────────────────────────────────

const config = await viem.getContractAt(
  "AssetLendingPoolConfig",
  configProxyAddress,
);

// ─── Verify caller is owner ───────────────────────────────────────────────────

const owner = await config.read.owner();
if (owner.toLowerCase() !== callerAddress.toLowerCase()) {
  console.error(
    `Account ${callerAddress} is not the owner of config proxy ${configProxyAddress} (owner: ${owner}).`,
  );
  console.error("setMaxAppraisalAge is onlyOwner — transaction would revert.");
  console.error(
    "If the owner is a Safe multisig, use scripts/generate-safe-set-max-appraisal-age.ts to produce a Safe Transaction Builder batch instead.",
  );
  process.exit(1);
}

// ─── Read current max appraisal age ───────────────────────────────────────────

const currentAge = await config.read.maxAppraisalAge();

console.log(`\nConfig proxy:     ${configProxyAddress}`);
console.log(`Owner:            ${owner}`);
console.log(
  `Current max age:  ${currentAge === 0n ? "0 (staleness checking disabled)" : seconds(currentAge)}`,
);

// ─── No-op check ─────────────────────────────────────────────────────────────

if (currentAge === targetAge) {
  console.log(
    `\nmaxAppraisalAge is already ${seconds(targetAge)}. Nothing to do.`,
  );
  process.exit(0);
}

// ─── Sanity warnings (the setter itself validates nothing) ───────────────────

if (targetAge === 0n) {
  console.warn(
    `\n  ! WARNING: 0 disables the appraisal staleness check entirely — any\n` +
      `    appraisal, however old, will pass origination.`,
  );
} else if (targetAge > ONE_YEAR) {
  console.warn(
    `\n  ! WARNING: target is longer than 365 days. Double-check the units —\n` +
      `    MAX_APPRAISAL_AGE is in SECONDS, not days.`,
  );
}

// ─── Confirmation on live networks ────────────────────────────────────────────

if (connection.networkConfig.type === "http") {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setMaxAppraisalAge Summary ===");
  console.log(`Network:          ${connection.networkName}`);
  console.log(`Chain ID:         ${chainId}`);
  console.log(`Caller:           ${callerAddress}`);
  console.log(`Config proxy:     ${configProxyAddress}`);
  console.log(
    `Old max age:      ${currentAge === 0n ? "0 (disabled)" : seconds(currentAge)}`,
  );
  console.log(
    `New max age:      ${targetAge === 0n ? "0 (disabled)" : seconds(targetAge)}`,
  );
  console.log("==================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  if (answer.toLowerCase() !== "yes") {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────

console.log(`\n[1/2] Calling setMaxAppraisalAge(${targetAge})…`);
const txHash = await config.write.setMaxAppraisalAge([targetAge], {
  account: callerClient.account,
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  tx: ${txHash} (block ${receipt.blockNumber})`);
await sleep(2000);

if (receipt.status !== "success") {
  console.error(`Transaction reverted! Hash: ${txHash}`);
  process.exit(1);
}

// ─── Verify ───────────────────────────────────────────────────────────────────

console.log("[2/2] Verifying…");
const ageAfter = await config.read.maxAppraisalAge();

if (ageAfter !== targetAge) {
  console.error(
    `CRITICAL: State mismatch after update! Expected ${targetAge}, got ${ageAfter}`,
  );
  process.exit(1);
}
console.log(
  `  maxAppraisalAge confirmed: ${ageAfter === 0n ? "0 (disabled)" : seconds(ageAfter)} ✓`,
);

// ─── Summary ──────────────────────────────────────────────────────────────────

console.log("\n=== setMaxAppraisalAge Complete ===");
console.log(`Network:      ${connection.networkName} (chainId: ${chainId})`);
console.log(`Config proxy: ${configProxyAddress}`);
console.log(
  `Old max age:  ${currentAge === 0n ? "0 (disabled)" : seconds(currentAge)}`,
);
console.log(
  `New max age:  ${ageAfter === 0n ? "0 (disabled)" : seconds(ageAfter)}`,
);
console.log(`Tx:           ${txHash}`);
console.log("===================================\n");

// ─── Persist to deployments/<network>.json (live networks only) ───────────────

if (connection.networkConfig.type === "http") {
  try {
    const deploymentData = await readDeployments(connection.networkName);
    const configEntry =
      (deploymentData["AssetLendingPoolConfig"] as Record<string, unknown>) ??
      {};

    await saveDeployment(connection.networkName, "AssetLendingPoolConfig", {
      ...configEntry,
      proxy: configProxyAddress,
      // stored as a string — BigInt is not JSON-serializable
      maxAppraisalAge: ageAfter.toString(),
      maxAppraisalAgeUpdatedAt: new Date().toISOString(),
    });
    console.log(
      `Deployment info updated at deployments/${connection.networkName}.json`,
    );
  } catch (err) {
    // Non-fatal — the on-chain state is already confirmed; just warn.
    console.warn(`Warning: could not persist to deployments JSON: ${err}`);
  }
}
