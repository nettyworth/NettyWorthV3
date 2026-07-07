/**
 * debug-token-eligibility.ts
 *
 * Read-only script that traces every condition of _isEligible() for one or
 * more AssetNFT token IDs and shows exactly why each passes or fails.
 *
 * _isEligible checks (in order):
 *   [1] appraisal.updatedAt != 0          (token has been appraised)
 *   [2] appraisal.value >= minAppraisalValue
 *   [3] appraisal.grade >= minGrade
 *   [4] category == 0 || eligibleCategories[category]
 *       (category 0 is always eligible; non-zero categories must be whitelisted)
 *
 * Usage
 * -----
 * TOKEN_ID=42 \
 *   npx hardhat run scripts/debug-token-eligibility.ts --network base
 *
 * TOKEN_ID=1,2,3 \
 *   npx hardhat run scripts/debug-token-eligibility.ts --network base
 *
 * Optional overrides:
 *   CONFIG_PROXY=0x<addr>              — use this config proxy directly
 *   ASSET_LENDING_POOL_PROXY=0x<addr>  — resolve config via pool.getConfig()
 */

import { network } from "hardhat";
import { formatUnits, getAddress, keccak256, encodePacked } from "viem";
import { readDeployments } from "./lib/deployments.js";

// ─── Helpers ──────────────────────────────────────────────────────────────────

const PASS = "✓ PASS";
const FAIL = "✗ FAIL";

function check(ok: boolean): string {
  return ok ? PASS : FAIL;
}

// ERC-7201 base slot for AssetLendingPoolConfig storage.
// keccak256(abi.encode(uint256(keccak256("nettyworth.storage.AssetLendingPoolConfig")) - 1)) & ~bytes32(uint256(0xff))
const CONFIG_BASE_SLOT = BigInt(
  "0x44360b8816dcda47227a5f760c5ec3f2cdf3eef6a97dfd570813ac50da6e4200",
);

// Storage layout offsets within ConfigStorage (Solidity packs right-to-left,
// mappings always occupy their own slot):
//   +0  paymentToken  (address)
//   +1  assetNFT      (address)
//   +2  termConfigs   (mapping)
//   +3  termCount     (uint8)
//   +4  appraisals    (mapping)
//   +5  minAppraisalValue
//   +6  minGrade
//   +7  eligibleCategories  (mapping)
const ELIGIBLE_CATEGORIES_SLOT = CONFIG_BASE_SLOT + 7n;

// Slot of eligibleCategories[categoryId] = keccak256(abi.encode(categoryId, mappingSlot))
function eligibleCategoryStorageSlot(categoryId: bigint): `0x${string}` {
  return keccak256(
    encodePacked(["uint256", "uint256"], [categoryId, ELIGIBLE_CATEGORIES_SLOT]),
  );
}

// ─── Parse TOKEN_ID env var ───────────────────────────────────────────────────

const rawTokenIds = process.env.TOKEN_ID ?? process.env.TOKEN_IDS;
if (!rawTokenIds) {
  console.error(
    "Missing TOKEN_ID env var. Example: TOKEN_ID=42 npx hardhat run ...",
  );
  process.exit(1);
}

const tokenIds: bigint[] = rawTokenIds
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean)
  .map((s) => {
    try {
      return BigInt(s);
    } catch {
      console.error(`Invalid TOKEN_ID value: "${s}"`);
      process.exit(1);
    }
  });

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();

// ─── Resolve config proxy address ────────────────────────────────────────────

let configProxyAddress: `0x${string}`;

if (process.env.CONFIG_PROXY) {
  configProxyAddress = getAddress(process.env.CONFIG_PROXY) as `0x${string}`;
} else if (process.env.ASSET_LENDING_POOL_PROXY) {
  const poolProxy = getAddress(
    process.env.ASSET_LENDING_POOL_PROXY,
  ) as `0x${string}`;
  const pool = await viem.getContractAt("AssetLendingPool", poolProxy);
  configProxyAddress = await pool.read.getConfig();
} else {
  const data = await readDeployments(connection.networkName);

  const configEntry = data["AssetLendingPoolConfig"] as
    | Record<string, unknown>
    | undefined;
  if (configEntry?.proxy) {
    configProxyAddress = getAddress(configEntry.proxy as string) as `0x${string}`;
  } else {
    const poolEntry = data["AssetLendingPool"] as
      | Record<string, unknown>
      | undefined;
    if (!poolEntry?.proxy) {
      console.error(
        `Neither AssetLendingPoolConfig nor AssetLendingPool proxy found in deployments/${connection.networkName}.json.`,
      );
      console.error(
        "Set CONFIG_PROXY or ASSET_LENDING_POOL_PROXY to override.",
      );
      process.exit(1);
    }
    const poolProxy = getAddress(poolEntry.proxy as string) as `0x${string}`;
    const pool = await viem.getContractAt("AssetLendingPool", poolProxy);
    configProxyAddress = await pool.read.getConfig();
  }
}

// ─── Contract instance ────────────────────────────────────────────────────────

const config = await viem.getContractAt(
  "AssetLendingPoolConfig",
  configProxyAddress,
);

// ─── Fetch shared config thresholds once ─────────────────────────────────────

const [minAppraisalValue, minGrade, maxAppraisalAge, paymentTokenAddr] =
  await Promise.all([
    config.read.minAppraisalValue(),
    config.read.minGrade(),
    config.read.maxAppraisalAge(),
    config.read.paymentToken(),
  ]);

let decimals = 6;
try {
  const token = await viem.getContractAt(
    "IERC20Metadata",
    paymentTokenAddr as `0x${string}`,
  );
  decimals = await token.read.decimals();
} catch {
  // non-metadata token — fall back to 6
}

const nowSec = BigInt(Math.floor(Date.now() / 1000));

// ─── Print header ─────────────────────────────────────────────────────────────

console.log("\n=== debug-token-eligibility ===");
console.log(`Network:           ${connection.networkName} (chainId ${chainId})`);
console.log(`Config proxy:      ${configProxyAddress}`);
console.log(`\nEligibility thresholds:`);
console.log(
  `  minAppraisalValue: ${minAppraisalValue} (${formatUnits(minAppraisalValue, decimals)} token units)`,
);
console.log(`  minGrade:          ${minGrade}`);
console.log(
  `  maxAppraisalAge:   ${maxAppraisalAge === 0n ? "disabled" : `${maxAppraisalAge}s`}`,
);

// ─── Per-token trace ──────────────────────────────────────────────────────────

for (const tokenId of tokenIds) {
  console.log(`\n${"─".repeat(56)}`);
  console.log(`Token ID: ${tokenId}`);
  console.log(`${"─".repeat(56)}`);

  // Fetch appraisal, isEligible result, and category storage slot in parallel.
  const [appraisal, eligible] = await Promise.all([
    config.read.getAppraisal([tokenId]),
    config.read.isEligible([tokenId]),
  ]);

  const { value, grade, category, updatedAt } = appraisal;

  // ── Appraisal raw data ──────────────────────────────────────────────────────
  console.log("\nAppraisal data:");
  console.log(`  updatedAt:  ${updatedAt === 0n ? "(never set)" : `block-time ${updatedAt}`}`);
  console.log(
    `  value:      ${value} (${formatUnits(value, decimals)} token units)`,
  );
  console.log(`  grade:      ${grade}`);
  console.log(`  category:   ${category}`);

  // ── Condition [1]: appraisal exists ─────────────────────────────────────────
  const cond1 = updatedAt !== 0n;
  console.log(`\nCondition [1] — appraisal.updatedAt != 0`);
  console.log(`  updatedAt=${updatedAt}  →  ${check(cond1)}`);
  if (!cond1) {
    console.log(
      "  ↳ Token has no recorded appraisal. Call setAppraisal() first.",
    );
  } else if (maxAppraisalAge !== 0n) {
    const age = nowSec > updatedAt ? nowSec - updatedAt : 0n;
    const stale = age > maxAppraisalAge;
    console.log(
      `  ↳ Age ≈ ${age}s  (maxAppraisalAge=${maxAppraisalAge}s)  ${stale ? "⚠ STALE — checkEligibility() would also revert" : "fresh"}`,
    );
  }

  // ── Condition [2]: value >= minAppraisalValue ────────────────────────────────
  const cond2 = value >= minAppraisalValue;
  const valueDelta =
    value >= minAppraisalValue ? value - minAppraisalValue : minAppraisalValue - value;
  console.log(`\nCondition [2] — appraisal.value >= minAppraisalValue`);
  console.log(
    `  ${value} >= ${minAppraisalValue}  →  ${check(cond2)}` +
      (cond2
        ? `  (surplus: +${valueDelta} / +${formatUnits(valueDelta, decimals)} token units)`
        : `  (shortfall: -${valueDelta} / -${formatUnits(valueDelta, decimals)} token units)`),
  );

  // ── Condition [3]: grade >= minGrade ─────────────────────────────────────────
  const cond3 = grade >= minGrade;
  console.log(`\nCondition [3] — appraisal.grade >= minGrade`);
  console.log(
    `  ${grade} >= ${minGrade}  →  ${check(cond3)}` +
      (cond3
        ? `  (surplus: +${grade - minGrade})`
        : `  (shortfall: -${minGrade - grade})`),
  );

  // ── Condition [4]: category == 0 || eligibleCategories[category] ─────────────
  console.log(
    `\nCondition [4] — category == 0 || eligibleCategories[category]`,
  );

  if (category === 0n) {
    console.log(`  category=0  →  ${PASS}  (category 0 always passes)`);
  } else {
    // Read the mapping slot directly from storage.
    // slot = keccak256(abi.encodePacked(uint256(category), uint256(mappingBaseSlot)))
    const storageSlot = eligibleCategoryStorageSlot(category);
    const rawValue = await publicClient.getStorageAt({
      address: configProxyAddress,
      slot: storageSlot,
    });
    // Non-zero = true
    const categoryEligible =
      rawValue !== undefined &&
      rawValue !== "0x0000000000000000000000000000000000000000000000000000000000000000";
    console.log(`  category=${category}  storage slot=${storageSlot}`);
    console.log(
      `  eligibleCategories[${category}]=${categoryEligible}  →  ${check(categoryEligible)}`,
    );
    if (!categoryEligible) {
      console.log(
        `  ↳ Category ${category} is not whitelisted. Call setEligibilityControls(... addCategories=[${category}] ...) to add it.`,
      );
    }
  }

  // ── Overall verdict ───────────────────────────────────────────────────────
  console.log(`\nOverall isEligible():  ${eligible ? "✓ ELIGIBLE" : "✗ NOT ELIGIBLE"}`);

  const failingConditions = [
    !cond1 && "[1] no appraisal",
    !cond2 && "[2] value below minimum",
    !cond3 && "[3] grade below minimum",
  ].filter(Boolean);

  if (!eligible && failingConditions.length > 0) {
    console.log(`Failing condition(s): ${failingConditions.join(", ")}`);
  } else if (!eligible) {
    console.log(`Failing condition(s): [4] category not whitelisted`);
  }
}

console.log(`\n${"═".repeat(56)}\n`);
