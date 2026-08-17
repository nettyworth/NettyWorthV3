/**
 * generate-safe-set-max-appraisal-age.ts
 *
 * Generates a Safe (Gnosis Safe) Transaction Builder batch JSON that calls
 * `setMaxAppraisalAge(newMaxAge)` on AssetLendingPoolConfig. Import the output
 * into the Safe web app: Apps → Transaction Builder → "Load / import".
 *
 * `maxAppraisalAge` is the maximum age (in seconds) an appraisal may have before
 * borrow / borrowBundle / financeMarketplacePurchase reject the collateral as
 * stale. It defaults to 7 days at initialize() and is onlyOwner — so once
 * ownership is held by the multisig, this is the only way to change it.
 *
 * Staleness is an origination-time gate only: widening it does not touch
 * existing loans, repayment, or the default lifecycle.
 *
 * Usage
 * -----
 * # Default target: 30 days
 * SAFE_ADDRESS=0x<multisig> \
 *   npx hardhat run scripts/generate-safe-set-max-appraisal-age.ts --network base
 *
 * # Explicit value, in SECONDS (0 disables the staleness check entirely)
 * SAFE_ADDRESS=0x<multisig> MAX_APPRAISAL_AGE=1209600 \
 *   npx hardhat run scripts/generate-safe-set-max-appraisal-age.ts --network base
 *
 * # Override the config proxy directly
 * SAFE_ADDRESS=0x<multisig> CONFIG_PROXY=0x<addr> \
 *   npx hardhat run scripts/generate-safe-set-max-appraisal-age.ts --network base
 *
 * This script is read-only on-chain — it never sends a transaction.
 */

import { network } from "hardhat";
import { getAddress, encodeFunctionData } from "viem";
import { readDeployments } from "./lib/deployments.js";
import { buildBatch, writeBatch, type SafeTx } from "./lib/safe-batch.js";

// ─── Defaults ─────────────────────────────────────────────────────────────────

const THIRTY_DAYS = 30n * 24n * 60n * 60n; // 2_592_000 seconds
const ONE_YEAR = 365n * 24n * 60n * 60n;

function seconds(value: bigint): string {
  const days = Number(value) / 86400;
  return `${value}s (${days % 1 === 0 ? days : days.toFixed(2)} day${days === 1 ? "" : "s"})`;
}

// ─── Validate SAFE_ADDRESS env var ────────────────────────────────────────────

const rawSafe = process.env.SAFE_ADDRESS;
if (!rawSafe) {
  console.error("Missing required env var: SAFE_ADDRESS");
  console.error(
    "Usage: SAFE_ADDRESS=0x<multisig> npx hardhat run scripts/generate-safe-set-max-appraisal-age.ts --network <network>",
  );
  process.exit(1);
}
let safeAddress: `0x${string}`;
try {
  safeAddress = getAddress(rawSafe) as `0x${string}`;
} catch {
  console.error(`Invalid SAFE_ADDRESS address: "${rawSafe}"`);
  process.exit(1);
}

// ─── Parse target age ─────────────────────────────────────────────────────────

let targetAge: bigint;
const rawAge = process.env.MAX_APPRAISAL_AGE;
if (rawAge === undefined || rawAge.trim() === "") {
  targetAge = THIRTY_DAYS;
} else {
  try {
    targetAge = BigInt(rawAge.trim());
  } catch {
    console.error(
      `Invalid MAX_APPRAISAL_AGE: "${rawAge}" — expected an integer number of seconds.`,
    );
    process.exit(1);
  }
  if (targetAge < 0n) {
    console.error("MAX_APPRAISAL_AGE must not be negative.");
    process.exit(1);
  }
}

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;
const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();

// ─── Resolve config proxy address ─────────────────────────────────────────────
// Mirrors scripts/check-lending-pool-config.ts: CONFIG_PROXY wins, then the
// standalone AssetLendingPoolConfig deployment entry, then pool → getConfig().

let configProxyAddress: `0x${string}`;

if (process.env.CONFIG_PROXY) {
  configProxyAddress = getAddress(process.env.CONFIG_PROXY) as `0x${string}`;
} else {
  const data = await readDeployments(connection.networkName);
  const configEntry = data["AssetLendingPoolConfig"] as
    | Record<string, unknown>
    | undefined;
  if (configEntry?.proxy) {
    configProxyAddress = getAddress(
      configEntry.proxy as string,
    ) as `0x${string}`;
  } else {
    const poolEntry = data["AssetLendingPool"] as
      | Record<string, unknown>
      | undefined;
    if (!poolEntry?.proxy) {
      console.error(
        `Neither AssetLendingPoolConfig nor AssetLendingPool proxy found in deployments/${connection.networkName}.json.`,
      );
      console.error("Set CONFIG_PROXY to override.");
      process.exit(1);
    }
    const poolProxy = getAddress(poolEntry.proxy as string) as `0x${string}`;
    const pool = await viem.getContractAt("AssetLendingPool", poolProxy);
    configProxyAddress = getAddress(
      await pool.read.getConfig(),
    ) as `0x${string}`;
  }
}

const config = await viem.getContractAt(
  "AssetLendingPoolConfig",
  configProxyAddress,
);

console.log(`\n=== generate-safe-set-max-appraisal-age ===`);
console.log(`Network:  ${connection.networkName} (chainId: ${chainId})`);
console.log(`Safe:     ${safeAddress}`);
console.log(`Config:   ${configProxyAddress}`);
console.log("------------------------------------------");

// ─── Precheck 1: the Safe must actually own the config contract ───────────────
// AssetLendingPoolConfig is Ownable2Step — transferOwnership() only sets
// pendingOwner; the Safe must have executed acceptOwnership() for setters to
// authorize its calls.

const owner = getAddress(await config.read.owner()) as `0x${string}`;

if (owner.toLowerCase() !== safeAddress.toLowerCase()) {
  let pendingOwner: `0x${string}` | null = null;
  try {
    pendingOwner = getAddress(
      await config.read.pendingOwner(),
    ) as `0x${string}`;
  } catch {
    // older layouts may not expose pendingOwner — fall through to the generic error
  }

  console.error(`\nThe Safe is not the owner of ${configProxyAddress}.`);
  console.error(`  owner():        ${owner}`);
  console.error(`  pendingOwner(): ${pendingOwner ?? "<unavailable>"}`);

  if (
    pendingOwner &&
    pendingOwner.toLowerCase() === safeAddress.toLowerCase()
  ) {
    console.error(
      `\nOwnership handoff is only half-done: the Safe is pendingOwner but has not accepted.`,
    );
    console.error(
      `Execute deployments/safe-accept-ownership.${connection.networkName}.json from the Safe first`,
    );
    console.error(
      `(regenerate it with scripts/generate-safe-accept-ownership.ts), then re-run this script.`,
    );
  } else {
    console.error(
      `\nsetMaxAppraisalAge is onlyOwner — a batch from this Safe would revert. Aborting.`,
    );
  }
  process.exit(1);
}

console.log(`  owner() == Safe ✓`);

// ─── Precheck 2: current value / no-op short-circuit ──────────────────────────

const currentAge = (await config.read.maxAppraisalAge()) as bigint;
console.log(`  current maxAppraisalAge: ${seconds(currentAge)}`);
console.log(`  target  maxAppraisalAge: ${seconds(targetAge)}`);

if (currentAge === targetAge) {
  console.log(
    `\nAlready set to ${seconds(targetAge)} — nothing to do. No batch written.`,
  );
  process.exit(0);
}

// ─── Precheck 3: sanity warnings (the setter itself validates nothing) ────────

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

// ─── Build the transaction ────────────────────────────────────────────────────
// ABI mode (data: null + contractMethod/contractInputsValues) so signers review
// a decoded `setMaxAppraisalAge(<n>)` in the Safe UI rather than opaque hex.

const transactions: SafeTx[] = [
  {
    to: configProxyAddress,
    value: "0",
    data: null,
    contractMethod: {
      inputs: [{ internalType: "uint256", name: "newMaxAge", type: "uint256" }],
      name: "setMaxAppraisalAge",
      payable: false,
    },
    contractInputsValues: { newMaxAge: targetAge.toString() },
  },
];

// Equivalent raw calldata — printed so the signer can cross-check what the Safe
// UI displays at signing time against this script's output.
const calldata = encodeFunctionData({
  abi: [
    {
      type: "function",
      name: "setMaxAppraisalAge",
      stateMutability: "nonpayable",
      inputs: [{ name: "newMaxAge", type: "uint256" }],
      outputs: [],
    },
  ],
  functionName: "setMaxAppraisalAge",
  args: [targetAge],
});

const days = Number(targetAge) / 86400;
const label = `${days % 1 === 0 ? days : days.toFixed(2)} day${days === 1 ? "" : "s"}`;

const batch = buildBatch({
  chainId,
  safeAddress,
  name: `Set maxAppraisalAge to ${label} (${connection.networkName})`,
  description: `AssetLendingPoolConfig.setMaxAppraisalAge(${targetAge}) on ${configProxyAddress} — was ${currentAge}`,
  transactions,
});

const outPath = await writeBatch(
  connection.networkName,
  "safe-set-max-appraisal-age",
  batch,
);

console.log("------------------------------------------");
console.log(`Transaction:`);
console.log(`     to:       ${configProxyAddress}`);
console.log(`     value:    0`);
console.log(`     method:   setMaxAppraisalAge(uint256)`);
console.log(`     newMaxAge: ${targetAge}  (${label})`);
console.log(`     calldata: ${calldata}`);
console.log(`\nWrote: ${outPath}`);
console.log(
  "\nNext: open the Safe web app → Apps → Transaction Builder → drag in this file " +
    "(or use its import), confirm the decoded call and the calldata above, then collect " +
    "signatures and execute from the multisig.",
);
console.log(
  `\nAfter execution, verify with:\n` +
    `     npx hardhat run scripts/check-lending-pool-config.ts --network ${connection.networkName}`,
);
console.log("==========================================\n");
