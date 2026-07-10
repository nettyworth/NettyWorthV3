/**
 * set-term-config.ts
 *
 * Create or update loan term configuration(s) on AssetLendingPoolConfig.
 *
 * BATCH MODE (default — no TERM_ID set)
 * ──────────────────────────────────────
 * Writes the three production terms (ids 0/1/2) in one run:
 *
 *   id 0 →  7 days, aprBps 52143  (~10% flat: borrow 100 USDC, repay ~110)
 *   id 1 → 15 days, aprBps 36500  (15% flat: borrow 100 USDC, repay 115)
 *   id 2 → 30 days, aprBps 24333  (~20% flat: borrow 100 USDC, repay ~119.9997)
 *
 *   npx hardhat run scripts/set-term-config.ts --network base
 *
 * NOTE on rate encoding: the contract stores an ANNUAL rate (APR) and pro-rates
 * it over the loan duration:  interest = principal × aprBps × duration / (365d × 10000)
 * The high aprBps values above are NOT errors — they are the annualized equivalents of
 * the desired flat-over-term percentages (10%/15%/20%).
 *
 * SINGLE-TERM MODE (TERM_ID is set)
 * ───────────────────────────────────
 * Writes exactly one slot from env vars:
 *
 *   TERM_ID=3 DURATION_SECONDS=300 APR_BPS=1000 ACTIVE=true \
 *     npx hardhat run scripts/set-term-config.ts --network base
 *
 *   # Deactivate a term after testing:
 *   TERM_ID=3 DURATION_SECONDS=300 APR_BPS=1000 ACTIVE=false \
 *     npx hardhat run scripts/set-term-config.ts --network base
 *
 * PROXY OVERRIDES (both modes)
 * ─────────────────────────────
 *   ASSET_LENDING_POOL_PROXY=0x<addr>   override pool proxy
 *   CONFIG_PROXY=0x<addr>               override config proxy directly (takes precedence)
 *
 * Environment variables
 * ---------------------
 * TERM_ID            uint8 slot to write; if unset → batch mode
 * DURATION_SECONDS   term duration in seconds (single mode only; default: 300 = 5 min)
 * APR_BPS            annual interest rate in bps (single mode only; default: 1000 = 10% APR)
 * ACTIVE             "true"/"1" or "false"/"0" (single mode only; default: true)
 * ASSET_LENDING_POOL_PROXY  override pool proxy (optional)
 * CONFIG_PROXY       override config proxy directly (optional; takes precedence)
 */

import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments, saveDeployment } from "./lib/deployments.js";
import { sleep } from "./lib/sleep.js";

// ─── Production term constants (batch mode) ───────────────────────────────────
//
// aprBps is an ANNUAL rate. These values are the annualized equivalents of the
// desired flat-over-term fees: interest = principal × aprBps × duration / (365d × 10000).
//
//   id 0:  7d, aprBps=52143 → ~10% flat (100 USDC → repay ~110)
//   id 1: 15d, aprBps=36500 →  15% flat (100 USDC → repay  115)
//   id 2: 30d, aprBps=24333 → ~20% flat (100 USDC → repay ~119.9997)

const PRODUCTION_TERMS = [
  { termId: 0, durationSeconds: 7 * 86400, aprBps: 52143, active: true },
  { termId: 1, durationSeconds: 15 * 86400, aprBps: 36500, active: true },
  { termId: 2, durationSeconds: 30 * 86400, aprBps: 24333, active: true },
] as const;

// ─── Detect mode ──────────────────────────────────────────────────────────────

const isBatchMode = process.env.TERM_ID === undefined;

// ─── Parse TERM_ID (single mode only) ────────────────────────────────────────

let termId: number;
let durationNum: number;
let newDuration: bigint;
let newAprBps: bigint;
let newActive: boolean;

if (!isBatchMode) {
  const rawTermId = process.env.TERM_ID!;
  const termIdNum = Number(rawTermId);
  if (!Number.isInteger(termIdNum) || termIdNum < 0 || termIdNum > 255) {
    console.error(
      `Invalid TERM_ID: "${rawTermId}". Must be an integer between 0 and 255 (uint8).`,
    );
    process.exit(1);
  }
  termId = termIdNum;

  // ─── Parse DURATION_SECONDS ─────────────────────────────────────────────────

  const rawDuration = process.env.DURATION_SECONDS ?? "300";
  durationNum = Number(rawDuration);
  if (!Number.isInteger(durationNum) || durationNum <= 0) {
    console.error(
      `Invalid DURATION_SECONDS: "${rawDuration}". Must be a positive integer (seconds). Got 0? The contract rejects duration == 0.`,
    );
    process.exit(1);
  }
  newDuration = BigInt(durationNum);

  // ─── Parse APR_BPS ──────────────────────────────────────────────────────────

  const rawAprBps = process.env.APR_BPS ?? "1000";
  const aprBpsNum = Number(rawAprBps);
  if (!Number.isInteger(aprBpsNum) || aprBpsNum < 0 || aprBpsNum > 1_000_000) {
    console.error(
      `Invalid APR_BPS: "${rawAprBps}". Must be an integer between 0 and 1000000 (basis points).`,
    );
    process.exit(1);
  }
  newAprBps = BigInt(aprBpsNum);

  // ─── Parse ACTIVE ───────────────────────────────────────────────────────────

  const rawActive = process.env.ACTIVE ?? "true";
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
} else {
  // Satisfy TypeScript — these are only read in single mode
  termId = 0;
  durationNum = 0;
  newDuration = 0n;
  newAprBps = 0n;
  newActive = false;
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
    console.log(`\n⚠  termCount will grow from ${termCount} → ${termId + 1}`);
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

// ─── applyTerm helper ─────────────────────────────────────────────────────────
//
// Writes (and verifies) a single term slot, then persists to the deployments
// JSON on live networks. Called by both batch and single mode.

type TermInput = {
  termId: number;
  durationSeconds: number;
  aprBps: number;
  active: boolean;
};

async function applyTerm(
  term: TermInput,
  step: { current: number; total: number },
): Promise<void> {
  const { termId: id, durationSeconds, aprBps: aprBpsVal, active } = term;
  const dur = BigInt(durationSeconds);
  const apr = BigInt(aprBpsVal);
  const prefix = step.total > 1 ? `[${step.current}/${step.total}] ` : "";

  // Read current on-chain state
  const [currentTerm, currentTermCount] = await Promise.all([
    config.read.getTermConfig([id]),
    config.read.termCount(),
  ]);

  console.log(`\n${prefix}term[${id}] — current state:`);
  console.log(
    `  duration:  ${seconds(currentTerm.duration)}${currentTerm.duration === 0n ? "  (slot empty)" : ""}`,
  );
  console.log(`  aprBps:    ${bps(currentTerm.aprBps)}`);
  console.log(`  active:    ${currentTerm.active}`);
  console.log(`  termCount: ${currentTermCount}`);

  // No-op check
  if (
    currentTerm.duration === dur &&
    currentTerm.aprBps === apr &&
    currentTerm.active === active
  ) {
    console.log(`  → already up to date, skipping.`);
    return;
  }

  console.log(
    `  → setting: duration=${seconds(dur)}, aprBps=${bps(apr)}, active=${active}`,
  );
  if (id >= Number(currentTermCount)) {
    console.log(
      `  ⚠  termCount will grow from ${currentTermCount} → ${id + 1}`,
    );
  }

  // Send transaction
  const txHash = await config.write.setTermConfig([id, dur, apr, active], {
    account: callerClient.account,
  });
  const receipt = await publicClient.waitForTransactionReceipt({
    hash: txHash,
  });
  console.log(`  tx: ${txHash} (block ${receipt.blockNumber})`);
  await sleep(2000);
  // Verify
  const [termAfter, termCountAfter] = await Promise.all([
    config.read.getTermConfig([id]),
    config.read.termCount(),
  ]);
  if (
    termAfter.duration !== dur ||
    termAfter.aprBps !== apr ||
    termAfter.active !== active
  ) {
    console.error(
      `CRITICAL: State mismatch after update! Expected duration=${dur} aprBps=${apr} active=${active}, got duration=${termAfter.duration} aprBps=${termAfter.aprBps} active=${termAfter.active}`,
    );
    process.exit(1);
  }
  console.log(
    `  term[${id}].duration  confirmed: ${seconds(termAfter.duration)} ✓`,
  );
  console.log(`  term[${id}].aprBps    confirmed: ${bps(termAfter.aprBps)} ✓`);
  console.log(`  term[${id}].active    confirmed: ${termAfter.active} ✓`);
  console.log(`  termCount            confirmed: ${termCountAfter} ✓`);

  // Persist to deployments/<network>.json (live networks only)
  if (connection.networkConfig.type === "http") {
    try {
      const deploymentData = await readDeployments(connection.networkName);
      const configEntry =
        (deploymentData["AssetLendingPoolConfig"] as Record<string, unknown>) ??
        {};
      const existingTerms = Array.isArray(configEntry.terms)
        ? (configEntry.terms as Record<string, unknown>[])
        : [];
      const termRecord = {
        termId: id,
        durationSeconds,
        aprBps: aprBpsVal,
        active,
        updatedAt: new Date().toISOString(),
      };
      // Replace entry for this termId if present, otherwise append
      const termIdx = existingTerms.findIndex((t) => t.termId === id);
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
        `  Deployment info updated at deployments/${connection.networkName}.json`,
      );
    } catch (err) {
      // Non-fatal — on-chain state is confirmed; just warn.
      console.warn(`  Warning: could not persist to deployments JSON: ${err}`);
    }
  }
}

// ─── Dispatch: batch vs single ────────────────────────────────────────────────

console.log(`\nConfig proxy:  ${configProxyAddress}`);
console.log(`Owner:         ${owner}`);

if (isBatchMode) {
  // ── Batch confirmation (live networks only) ─────────────────────────────────
  if (connection.networkConfig.type === "http") {
    const rl = createInterface({
      input: process.stdin,
      output: process.stdout,
    });
    console.log("\n=== setTermConfig Batch Summary ===");
    console.log(`Network:   ${connection.networkName} (chainId: ${chainId})`);
    console.log(`Caller:    ${callerAddress}`);
    console.log(`Config:    ${configProxyAddress}`);
    console.log(`\nWill write ${PRODUCTION_TERMS.length} production terms:`);
    for (const t of PRODUCTION_TERMS) {
      console.log(
        `  id ${t.termId}: ${t.durationSeconds / 86400}d, aprBps=${t.aprBps} (${(t.aprBps / 100).toFixed(2)}% APR), active=${t.active}`,
      );
    }
    console.log("===================================\n");
    const answer = await rl.question("Proceed? (yes/no): ");
    rl.close();
    if (answer.toLowerCase() !== "yes") {
      console.log("Cancelled.");
      process.exit(0);
    }
  }

  // Apply each term sequentially (preserves nonce order)
  for (let i = 0; i < PRODUCTION_TERMS.length; i++) {
    await applyTerm(
      { ...PRODUCTION_TERMS[i] },
      { current: i + 1, total: PRODUCTION_TERMS.length },
    );
  }

  console.log("\n=== Batch setTermConfig Complete ===");
  console.log(`Network:  ${connection.networkName} (chainId: ${chainId})`);
  console.log(`Config:   ${configProxyAddress}`);
  console.log(`Wrote ${PRODUCTION_TERMS.length} terms (ids 0/1/2).`);
  console.log("====================================\n");
} else {
  // ── Single-term mode ────────────────────────────────────────────────────────
  const [currentTerm, currentTermCount] = await Promise.all([
    config.read.getTermConfig([termId]),
    config.read.termCount(),
  ]);

  console.log(
    `Current termCount: ${currentTermCount}  (slots 0–${Number(currentTermCount) - 1} are defined)`,
  );

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

  await applyTerm(
    {
      termId,
      durationSeconds: durationNum,
      aprBps: Number(newAprBps),
      active: newActive,
    },
    { current: 1, total: 1 },
  );

  console.log("\n=== setTermConfig Complete ===");
  console.log(`Network:      ${connection.networkName} (chainId: ${chainId})`);
  console.log(`Config proxy: ${configProxyAddress}`);
  console.log("================================\n");
}
