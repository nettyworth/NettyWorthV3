/**
 * register-token-buyback.ts
 *
 * Manually call BuybackPool.registerToken() to (re-)register a token's buyback
 * info on-chain. Normally this is called automatically by a PackMachine clone
 * during VRF fulfillment; use this script to fix a stuck or missing registration.
 *
 * Because registerToken checks that msg.sender is a registered PackMachine, this
 * script automatically handles the full three-step flow:
 *   1. registerPackMachine(caller, true)   — grant caller machine privileges
 *   2. registerToken(...)                  — write the token record
 *   3. registerPackMachine(caller, false)  — revoke caller machine privileges
 *
 * Caller must hold PACK_OPERATOR_ROLE (to call registerPackMachine in steps 1 & 3).
 *
 * Tiers: Base=0 / Common=1 / Uncommon=2 / Rare=3 / Ultra Rare=4 / Grail=5
 *
 * Usage
 * -----
 * TOKEN_ID=123 TIER=3 SOURCE_MACHINE=0x<addr> \
 *   npx hardhat run scripts/register-token-buyback.ts --network base
 *
 * # With an explicit amount-paid-per-card (for Spend-mode buybacks):
 * TOKEN_ID=123 TIER=3 SOURCE_MACHINE=0x<addr> AMOUNT_PAID=1000000 \
 *   npx hardhat run scripts/register-token-buyback.ts --network base
 *
 * # Override the BuybackPool address (optional; defaults to deployments JSON):
 * TOKEN_ID=123 TIER=3 SOURCE_MACHINE=0x<addr> BUYBACK_POOL=0x<addr> \
 *   npx hardhat run scripts/register-token-buyback.ts --network base
 *
 * Environment variables
 * ---------------------
 * TOKEN_ID        (required) token ID to register
 * TIER            (required) tier uint8: 0=Base 1=Common 2=Uncommon 3=Rare 4=Ultra Rare 5=Grail
 * SOURCE_MACHINE  (required) PackMachine clone address to record as source
 * AMOUNT_PAID     (optional) amountPaidPerCard in payment-token base units (default: 0)
 * BUYBACK_POOL    (optional) override BuybackPool proxy address
 * STEP_DELAY_MS   ms to wait after each on-chain write for RPC sync (default: 3000)
 */

import { network } from "hardhat";
import { getAddress, isAddress, keccak256, toHex } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments } from "./lib/deployments.js";
import { sleep } from "./lib/sleep.js";

const STEP_DELAY_MS = Number(process.env.STEP_DELAY_MS ?? "3000");
const TIER_NAMES = ["Base", "Common", "Uncommon", "Rare", "Ultra Rare", "Grail"];

// ─── Role constants (must match contracts/lib/Roles.sol) ─────────────────────

const PACK_OPERATOR_ROLE = keccak256(toHex("PACK_OPERATOR_ROLE"));

// ─── Parse TOKEN_ID ───────────────────────────────────────────────────────────

const rawTokenId = process.env.TOKEN_ID;
if (!rawTokenId) {
  console.error("Missing required env variable TOKEN_ID.");
  process.exit(1);
}
const tokenId = BigInt(rawTokenId);

// ─── Parse TIER ───────────────────────────────────────────────────────────────

const rawTier = process.env.TIER;
if (rawTier === undefined) {
  console.error(
    "Missing required env variable TIER (0=Base 1=Common 2=Uncommon 3=Rare 4=Ultra Rare 5=Grail).",
  );
  process.exit(1);
}
const tier = Number(rawTier);
if (!Number.isInteger(tier) || tier < 0 || tier > 5) {
  console.error(
    `Invalid TIER: "${rawTier}". Must be an integer 0–5 (0=Base 1=Common 2=Uncommon 3=Rare 4=Ultra Rare 5=Grail).`,
  );
  process.exit(1);
}

// ─── Parse SOURCE_MACHINE ─────────────────────────────────────────────────────

const rawSource = process.env.SOURCE_MACHINE;
if (!rawSource) {
  console.error("Missing required env variable SOURCE_MACHINE.");
  process.exit(1);
}
if (!isAddress(rawSource)) {
  console.error(
    `Invalid SOURCE_MACHINE: "${rawSource}". Must be a valid Ethereum address.`,
  );
  process.exit(1);
}
const sourceMachine = getAddress(rawSource) as `0x${string}`;

// ─── Parse AMOUNT_PAID ────────────────────────────────────────────────────────

const rawAmount = process.env.AMOUNT_PAID ?? "0";
const amountPaid = BigInt(rawAmount);

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [callerClient] = await viem.getWalletClients();
const callerAddress = callerClient.account.address;
const chainId = await publicClient.getChainId();

// ─── Resolve BuybackPool address ──────────────────────────────────────────────

let poolAddress: `0x${string}`;

if (process.env.BUYBACK_POOL) {
  if (!isAddress(process.env.BUYBACK_POOL)) {
    console.error(
      `Invalid BUYBACK_POOL: "${process.env.BUYBACK_POOL}". Must be a valid Ethereum address.`,
    );
    process.exit(1);
  }
  poolAddress = getAddress(process.env.BUYBACK_POOL) as `0x${string}`;
} else {
  const data = await readDeployments(connection.networkName);
  const poolEntry = data["BuybackPool"] as { proxy?: string } | undefined;
  if (!poolEntry?.proxy || !isAddress(poolEntry.proxy)) {
    console.error(
      `No BuybackPool.proxy found in deployments/${connection.networkName}.json.`,
    );
    console.error("Set BUYBACK_POOL env var to the proxy address.");
    process.exit(1);
  }
  poolAddress = getAddress(poolEntry.proxy) as `0x${string}`;
}

// ─── Contract instances ───────────────────────────────────────────────────────

const pool = await viem.getContractAt("BuybackPool", poolAddress);
const pmAddress = (await pool.read.getPermissionManager()) as `0x${string}`;
const pm = await viem.getContractAt("PermissionManager", pmAddress);

// ─── Preflight: caller must hold PACK_OPERATOR_ROLE ──────────────────────────

const hasOperatorRole = await pm.read.hasProtocolRole([
  PACK_OPERATOR_ROLE,
  callerAddress,
]);
if (!hasOperatorRole) {
  console.error(
    `\nAccount ${callerAddress} does not have PACK_OPERATOR_ROLE — registerPackMachine would revert.`,
  );
  process.exit(1);
}

// ─── Read existing token info & current registration status ──────────────────

const [existing, callerAlreadyRegistered] = await Promise.all([
  pool.read.getTokenInfo([tokenId]),
  pool.read.isRegisteredPackMachine([callerAddress]),
]);
const existingTier = existing[0];
const existingSource = existing[1];
const existingActive = existing[2];

// ─── Confirmation on live networks ────────────────────────────────────────────

const steps = [
  ...(!callerAlreadyRegistered ? [`registerPackMachine(caller, true)`] : []),
  `registerToken(${tokenId}, ${tier}, ${sourceMachine}, ${amountPaid})`,
  ...(!callerAlreadyRegistered ? [`registerPackMachine(caller, false)`] : []),
];

if (connection.networkConfig.type === "http") {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log(`\n=== registerToken Summary ===`);
  console.log(`Network:        ${connection.networkName}`);
  console.log(`Chain ID:       ${chainId}`);
  console.log(`Caller:         ${callerAddress}`);
  console.log(`BuybackPool:    ${poolAddress}`);
  console.log(`Token ID:       ${tokenId}`);
  console.log(`Tier:           ${tier} (${TIER_NAMES[tier]})`);
  console.log(`Source machine: ${sourceMachine}`);
  console.log(`Amount paid:    ${amountPaid}`);
  if (existingSource !== "0x0000000000000000000000000000000000000000") {
    console.log(
      `\nExisting record: tier=${existingTier} source=${existingSource} active=${existingActive}`,
    );
    console.log("This will overwrite the existing record.");
  }
  console.log(`\nSteps:          ${steps.join(" → ")}`);
  console.log("=============================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  if (answer.toLowerCase() !== "yes") {
    console.log("Cancelled.");
    process.exit(0);
  }
} else {
  console.log(`\n=== registerToken ===`);
  console.log(`Network:        ${connection.networkName} (chainId ${chainId})`);
  console.log(`BuybackPool:    ${poolAddress}`);
  console.log(`Token ID:       ${tokenId}`);
  console.log(`Tier:           ${tier} (${TIER_NAMES[tier]})`);
  console.log(`Source machine: ${sourceMachine}`);
  console.log(`Amount paid:    ${amountPaid}`);
  console.log(`Steps:          ${steps.join(" → ")}`);
}

const totalSteps = steps.length;
let step = 1;

// ─── Step 1 (conditional): grant caller machine privileges ───────────────────

let registerTokenTx: `0x${string}`;

if (!callerAlreadyRegistered) {
  console.log(`\n[${step++}/${totalSteps}] Calling registerPackMachine(caller, true)…`);
  const grantTx = await pool.write.registerPackMachine(
    [callerAddress, true],
    { account: callerClient.account },
  );
  const grantReceipt = await publicClient.waitForTransactionReceipt({ hash: grantTx });
  console.log(`  tx: ${grantTx} (block ${grantReceipt.blockNumber})`);
  if (grantReceipt.status !== "success") {
    console.error(`registerPackMachine(true) reverted! Hash: ${grantTx}`);
    process.exit(1);
  }
  await sleep(STEP_DELAY_MS);
}

// ─── Step 2: register the token ───────────────────────────────────────────────

console.log(
  `\n[${step++}/${totalSteps}] Calling registerToken(${tokenId}, ${tier}, ${sourceMachine}, ${amountPaid})…`,
);
registerTokenTx = await pool.write.registerToken(
  [tokenId, tier, sourceMachine, amountPaid],
  { account: callerClient.account },
);
const tokenReceipt = await publicClient.waitForTransactionReceipt({
  hash: registerTokenTx,
});
console.log(`  tx: ${registerTokenTx} (block ${tokenReceipt.blockNumber})`);
if (tokenReceipt.status !== "success") {
  console.error(`registerToken() reverted! Hash: ${registerTokenTx}`);
  if (!callerAlreadyRegistered) {
    console.error(
      `⚠  Caller was temporarily registered as a machine but registerToken failed.`,
    );
    console.error(
      `   Revoke manually: MACHINE=${callerAddress} REGISTER=false npx hardhat run scripts/register-pack-machine.ts --network ${connection.networkName}`,
    );
  }
  process.exit(1);
}
await sleep(STEP_DELAY_MS);

// ─── Step 3 (conditional): revoke caller machine privileges ──────────────────

if (!callerAlreadyRegistered) {
  console.log(`\n[${step++}/${totalSteps}] Calling registerPackMachine(caller, false)…`);
  const revokeTx = await pool.write.registerPackMachine(
    [callerAddress, false],
    { account: callerClient.account },
  );
  const revokeReceipt = await publicClient.waitForTransactionReceipt({ hash: revokeTx });
  console.log(`  tx: ${revokeTx} (block ${revokeReceipt.blockNumber})`);
  if (revokeReceipt.status !== "success") {
    console.error(`registerPackMachine(false) reverted! Hash: ${revokeTx}`);
    console.error(
      `⚠  Caller is still registered as a machine — revoke manually: MACHINE=${callerAddress} REGISTER=false npx hardhat run scripts/register-pack-machine.ts --network ${connection.networkName}`,
    );
    process.exit(1);
  }
  await sleep(STEP_DELAY_MS);
}

// ─── Confirm final state ──────────────────────────────────────────────────────

const updated = await pool.read.getTokenInfo([tokenId]);

// ─── Summary ──────────────────────────────────────────────────────────────────

console.log(`\n=== registerToken Complete ===`);
console.log(`Network:        ${connection.networkName} (chainId: ${chainId})`);
console.log(`BuybackPool:    ${poolAddress}`);
console.log(`Token ID:       ${tokenId}`);
console.log(`Tier:           ${updated[0]} (${TIER_NAMES[updated[0]] ?? "unknown"})`);
console.log(`Source machine: ${updated[1]}`);
console.log(`Active:         ${updated[2]}`);
console.log(`Tx:             ${registerTokenTx}`);
console.log("==============================\n");
