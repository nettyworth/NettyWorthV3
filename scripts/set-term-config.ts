/**
 * set-term-config.ts
 *
 * Create or update a loan term configuration on AssetLendingPoolConfig.
 * Useful for adding a short-duration test term (e.g. 5 min) without touching
 * the three production terms (0=7d, 1=15d, 2=30d).
 *
 * Usage
 * -----
 * # Add a 5-minute test term at slot 3 (all defaults):
 * npx hardhat run scripts/set-term-config.ts --network base
 *
 * # Fully parameterised:
 * TERM_ID=3 DURATION_SECONDS=300 APR_BPS=1000 ACTIVE=true \
 *   npx hardhat run scripts/set-term-config.ts --network base
 *
 * # Deactivate the term after testing:
 * TERM_ID=3 DURATION_SECONDS=300 APR_BPS=1000 ACTIVE=false \
 *   npx hardhat run scripts/set-term-config.ts --network base
 *
 * # Override proxy directly instead of reading from deployments JSON:
 * ASSET_LENDING_POOL_PROXY=0x<addr> \
 *   npx hardhat run scripts/set-term-config.ts --network base
 *
 * # Or override the config proxy directly:
 * CONFIG_PROXY=0x<addr> \
 *   npx hardhat run scripts/set-term-config.ts --network base
 *
 * Environment variables
 * ---------------------
 * TERM_ID            uint8 slot to write (default: 3)
 * DURATION_SECONDS   term duration in seconds (default: 300 = 5 min)
 * APR_BPS            annual interest rate in basis points (default: 1000 = 10%)
 * ACTIVE             "true"/"1" or "false"/"0" (default: true)
 * ASSET_LENDING_POOL_PROXY  override pool proxy (optional)
 * CONFIG_PROXY       override config proxy directly (optional; takes precedence)
 */

import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments, saveDeployment } from "./lib/deployments.js";

// ─── Parse TERM_ID ────────────────────────────────────────────────────────────

const rawTermId = process.env.TERM_ID ?? "3";
const termIdNum = Number(rawTermId);
if (
  !Number.isInteger(termIdNum) ||
  termIdNum < 0 ||
  termIdNum > 255
) {
  console.error(
    `Invalid TERM_ID: "${rawTermId}". Must be an integer between 0 and 255 (uint8).`,
  );
  process.exit(1);
}
const termId = termIdNum as number; // passed as BigInt to the ABI below

// ─── Parse DURATION_SECONDS ───────────────────────────────────────────────────

const rawDuration = process.env.DURATION_SECONDS ?? "300";
const durationNum = Number(rawDuration);
if (!Number.isInteger(durationNum) || durationNum <= 0) {
  console.error(
    `Invalid DURATION_SECONDS: "${rawDuration}". Must be a positive integer (seconds). Got 0? The contract rejects duration == 0.`,
  );
  process.exit(1);
}
const newDuration = BigInt(durationNum);

// ─── Parse APR_BPS ────────────────────────────────────────────────────────────

const rawAprBps = process.env.APR_BPS ?? "1000";
const aprBpsNum = Number(rawAprBps);
if (
  !Number.isInteger(aprBpsNum) ||
  aprBpsNum < 0 ||
  aprBpsNum > 10_000
) {
  console.error(
    `Invalid APR_BPS: "${rawAprBps}". Must be an integer between 0 and 10000 (basis points).`,
  );
  process.exit(1);
}
const newAprBps = BigInt(aprBpsNum);

// ─── Parse ACTIVE ─────────────────────────────────────────────────────────────

const rawActive = process.env.ACTIVE ?? "true";
let newActive: boolean;
if (rawActive === "true" || rawActive === "1") {
  newActive = true;
} else if (rawActive === "false" || rawActive === "0") {
  newActive = false;
} else {
  console.error(
    `Invalid ACTIVE: "${rawActive}". Must be "true", "false", "1", or "0".`,
  );
  process.exit(1);
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function seconds(value: bigint): string {
  const n = Number(value);
  if (n === 0) return "0s (not configured)";
  if (n < 3600) return `${n}s`;
  const days = n / 86400;
  return `${n}s (${days % 1 === 0 ? days : days.toFixed(2)} day${days === 1 ? "" : "s"})`;
}

function bps(value: bigint): string {
  return `${value} bps (${(Number(value) / 100).toFixed(2)}%)`;
}

// ─── Confirmation prompt (live networks only) ─────────────────────────────────

async function confirmUpdate(
  networkName: string,
  chainId: number,
  caller: string,
  configProxy: string,
  currentTerm: { duration: bigint; aprBps: bigint; active: boolean },
  termCount: number,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setTermConfig Summary ===");
  console.log(`Network:              ${networkName}`);
  console.log(`Chain ID:             ${chainId}`);
  console.log(`Caller:               ${caller}`);
  console.log(`Config proxy:         ${configProxy}`);
  console.log(`Term slot:            ${termId}`);
  console.log(`Current termCount:    ${termCount}`);
  console.log(`\nExisting term[${termId}]:`);
  console.log(
    `  duration:  ${seconds(currentTerm.duration)}${currentTerm.duration === 0n ? "  (slot empty)" : ""}`,
  );
  console.log(`  aprBps:    ${bps(currentTerm.aprBps)}`);
  console.log(`  active:    ${currentTerm.active}`);
  console.log(`\nNew term[${termId}]:`);
  console.log(`  duration:  ${seconds(newDuration)}`);
  console.log(`  aprBps:    ${bps(newAprBps)}`);
  console.log(`  active:    ${newActive}`);
  if (termId >= termCount) {
    console.log(
      `\n⚠  termCount will grow from ${termCount} → ${termId + 1}`,
    );
  }
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
  console.error("setTermConfig is onlyOwner — transaction would revert.");
  process.exit(1);
}

// ─── Read current term config and termCount ───────────────────────────────────

const [currentTerm, currentTermCount] = await Promise.all([
  config.read.getTermConfig([termId]),
  config.read.termCount(),
]);

console.log(`\nConfig proxy:  ${configProxyAddress}`);
console.log(`Owner:         ${owner}`);
console.log(
  `Current termCount: ${currentTermCount}  (slots 0–${Number(currentTermCount) - 1} are defined)`,
);
console.log(`\nCurrent term[${termId}]:`);
console.log(
  `  duration:  ${seconds(currentTerm.duration)}${currentTerm.duration === 0n ? "  (slot empty)" : ""}`,
);
console.log(`  aprBps:    ${bps(currentTerm.aprBps)}`);
console.log(`  active:    ${currentTerm.active}`);

// ─── No-op check ─────────────────────────────────────────────────────────────

if (
  currentTerm.duration === newDuration &&
  currentTerm.aprBps === newAprBps &&
  currentTerm.active === newActive
) {
  console.log(
    `\nterm[${termId}] is already set to duration=${newDuration}s, aprBps=${newAprBps}, active=${newActive}. Nothing to do.`,
  );
  process.exit(0);
}

// ─── Confirmation on live networks ────────────────────────────────────────────

if (connection.networkConfig.type === "http") {
  const ok = await confirmUpdate(
    connection.networkName,
    chainId,
    callerAddress,
    configProxyAddress,
    currentTerm,
    Number(currentTermCount),
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────

console.log(
  `\n[1/2] Calling setTermConfig(termId=${termId}, duration=${newDuration}, aprBps=${newAprBps}, active=${newActive})…`,
);
const txHash = await config.write.setTermConfig(
  [termId, newDuration, newAprBps, newActive],
  { account: callerClient.account },
);
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  tx: ${txHash} (block ${receipt.blockNumber})`);

// ─── Verify ───────────────────────────────────────────────────────────────────

console.log("[2/2] Verifying…");
const [termAfter, termCountAfter] = await Promise.all([
  config.read.getTermConfig([termId]),
  config.read.termCount(),
]);

if (
  termAfter.duration !== newDuration ||
  termAfter.aprBps !== newAprBps ||
  termAfter.active !== newActive
) {
  console.error(
    `CRITICAL: State mismatch after update! Expected duration=${newDuration} aprBps=${newAprBps} active=${newActive}, got duration=${termAfter.duration} aprBps=${termAfter.aprBps} active=${termAfter.active}`,
  );
  process.exit(1);
}
console.log(`  term[${termId}].duration  confirmed: ${seconds(termAfter.duration)} ✓`);
console.log(`  term[${termId}].aprBps    confirmed: ${bps(termAfter.aprBps)} ✓`);
console.log(`  term[${termId}].active    confirmed: ${termAfter.active} ✓`);
console.log(`  termCount                confirmed: ${termCountAfter} ✓`);

// ─── Summary ──────────────────────────────────────────────────────────────────

console.log("\n=== setTermConfig Complete ===");
console.log(`Network:      ${connection.networkName} (chainId: ${chainId})`);
console.log(`Config proxy: ${configProxyAddress}`);
console.log(
  `Old term[${termId}]:  duration=${seconds(currentTerm.duration)}, aprBps=${bps(currentTerm.aprBps)}, active=${currentTerm.active}`,
);
console.log(
  `New term[${termId}]:  duration=${seconds(termAfter.duration)}, aprBps=${bps(termAfter.aprBps)}, active=${termAfter.active}`,
);
console.log(`termCount:    ${currentTermCount} → ${termCountAfter}`);
console.log(`Tx:           ${txHash}`);
console.log("================================\n");

// ─── Persist to deployments/<network>.json (live networks only) ───────────────

if (connection.networkConfig.type === "http") {
  try {
    const deploymentData = await readDeployments(connection.networkName);
    const configEntry =
      (deploymentData["AssetLendingPoolConfig"] as Record<string, unknown>) ??
      {};

    // Merge into the existing "terms" array (or create it fresh)
    const existingTerms = Array.isArray(configEntry.terms)
      ? (configEntry.terms as Record<string, unknown>[])
      : [];
    const termRecord = {
      termId,
      durationSeconds: durationNum,
      aprBps: aprBpsNum,
      active: newActive,
      updatedAt: new Date().toISOString(),
    };
    // Replace the entry for this termId if it exists, otherwise append
    const termIdx = existingTerms.findIndex(
      (t) => t.termId === termId,
    );
    if (termIdx >= 0) {
      existingTerms[termIdx] = termRecord;
    } else {
      existingTerms.push(termRecord);
    }

    await saveDeployment(connection.networkName, "AssetLendingPoolConfig", {
      ...configEntry,
      proxy: configProxyAddress,
      terms: existingTerms,
    });
    console.log(
      `Deployment info updated at deployments/${connection.networkName}.json`,
    );
  } catch (err) {
    // Non-fatal — the on-chain state is already confirmed; just warn.
    console.warn(`Warning: could not persist to deployments JSON: ${err}`);
  }
}
