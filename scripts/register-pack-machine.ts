/**
 * register-pack-machine.ts
 *
 * Check or update the registration status of a PackMachine clone on BuybackPool.
 * Only registered machines can call registerToken (and receive auto-redeposits).
 *
 * Caller must hold PACK_OPERATOR_ROLE to write; no role required for the read-only check.
 *
 * Usage
 * -----
 * # Check registration status (read-only):
 * MACHINE=0x<addr> \
 *   npx hardhat run scripts/register-pack-machine.ts --network base
 *
 * # Register a machine:
 * MACHINE=0x<addr> REGISTER=true \
 *   npx hardhat run scripts/register-pack-machine.ts --network base
 *
 * # Deregister a machine:
 * MACHINE=0x<addr> REGISTER=false \
 *   npx hardhat run scripts/register-pack-machine.ts --network base
 *
 * # Override the BuybackPool address (optional; defaults to deployments JSON):
 * MACHINE=0x<addr> REGISTER=true BUYBACK_POOL=0x<addr> \
 *   npx hardhat run scripts/register-pack-machine.ts --network base
 *
 * Environment variables
 * ---------------------
 * MACHINE       (required) PackMachine clone address to check / register
 * REGISTER      (optional) "true" or "false" to register/deregister; omit for read-only check
 * BUYBACK_POOL  (optional) override BuybackPool proxy address
 * STEP_DELAY_MS ms to wait after on-chain write for RPC sync (default: 3000)
 */

import { network } from "hardhat";
import { getAddress, isAddress, keccak256, toHex } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments } from "./lib/deployments.js";
import { sleep } from "./lib/sleep.js";

const STEP_DELAY_MS = Number(process.env.STEP_DELAY_MS ?? "3000");

// ─── Role constants (must match contracts/lib/Roles.sol) ─────────────────────

const PACK_OPERATOR_ROLE = keccak256(toHex("PACK_OPERATOR_ROLE"));

// ─── Parse MACHINE ────────────────────────────────────────────────────────────

const rawMachine = process.env.MACHINE;
if (!rawMachine) {
  console.error("Missing required env variable MACHINE.");
  console.error(
    "Usage: MACHINE=0x<addr> [REGISTER=true|false] npx hardhat run scripts/register-pack-machine.ts --network <net>",
  );
  process.exit(1);
}
if (!isAddress(rawMachine)) {
  console.error(
    `Invalid MACHINE: "${rawMachine}". Must be a valid Ethereum address (0x-prefixed, 20 bytes).`,
  );
  process.exit(1);
}
const machineAddress = getAddress(rawMachine) as `0x${string}`;
if (machineAddress === "0x0000000000000000000000000000000000000000") {
  console.error(
    "MACHINE cannot be the zero address — the contract will revert BuybackPool__ZeroAddress.",
  );
  process.exit(1);
}

// ─── Parse REGISTER ───────────────────────────────────────────────────────────

const rawRegister = process.env.REGISTER;
let desiredState: boolean | undefined;
if (rawRegister !== undefined && rawRegister !== "check" && rawRegister !== "") {
  if (rawRegister !== "true" && rawRegister !== "false") {
    console.error(
      `Invalid REGISTER: "${rawRegister}". Must be "true", "false", or omit for read-only check.`,
    );
    process.exit(1);
  }
  desiredState = rawRegister === "true";
}
const isReadOnly = desiredState === undefined;

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
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
  const pool = data["BuybackPool"] as { proxy?: string } | undefined;
  if (!pool?.proxy || !isAddress(pool.proxy)) {
    console.error(
      `No BuybackPool.proxy found in deployments/${connection.networkName}.json.`,
    );
    console.error("Set BUYBACK_POOL env var to the proxy address.");
    process.exit(1);
  }
  poolAddress = getAddress(pool.proxy) as `0x${string}`;
}

// ─── Contract instance ────────────────────────────────────────────────────────

const pool = await viem.getContractAt("BuybackPool", poolAddress);

// ─── Read current registration status ────────────────────────────────────────

const currentStatus = await pool.read.isRegisteredPackMachine([machineAddress]);

console.log(`\n=== register-pack-machine ===`);
console.log(
  `Network:     ${connection.networkName} (chainId ${chainId})`,
);
console.log(`BuybackPool: ${poolAddress}`);
console.log(`Machine:     ${machineAddress}`);
console.log(`Registered:  ${currentStatus}`);

// ─── Read-only path ───────────────────────────────────────────────────────────

if (isReadOnly) {
  console.log("(Read-only — set REGISTER=true or REGISTER=false to write)");
  console.log("=============================\n");
  process.exit(0);
}

// ─── No-op check ─────────────────────────────────────────────────────────────

if (currentStatus === desiredState) {
  console.log(
    `\nNo-op: machine is already ${desiredState ? "registered" : "deregistered"}. Nothing to do.`,
  );
  console.log("=============================\n");
  process.exit(0);
}

// ─── Role preflight ───────────────────────────────────────────────────────────

const [callerClient] = await viem.getWalletClients();
const callerAddress = callerClient.account.address;

const pmAddress = (await pool.read.getPermissionManager()) as `0x${string}`;
const pm = await viem.getContractAt("PermissionManager", pmAddress);

const hasOperatorRole = await pm.read.hasProtocolRole([
  PACK_OPERATOR_ROLE,
  callerAddress,
]);
if (!hasOperatorRole) {
  console.error(
    `\nAccount ${callerAddress} does not have PACK_OPERATOR_ROLE — transaction would revert.`,
  );
  process.exit(1);
}

// ─── Confirmation on live networks ────────────────────────────────────────────

const action = desiredState ? "register" : "deregister";

if (connection.networkConfig.type === "http") {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log(`\n=== registerPackMachine Summary ===`);
  console.log(`Network:     ${connection.networkName}`);
  console.log(`Chain ID:    ${chainId}`);
  console.log(`Caller:      ${callerAddress}`);
  console.log(`BuybackPool: ${poolAddress}`);
  console.log(`Machine:     ${machineAddress}`);
  console.log(`Action:      ${action} (${currentStatus} → ${desiredState})`);
  console.log("===================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  if (answer.toLowerCase() !== "yes") {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Execute ──────────────────────────────────────────────────────────────────

console.log(
  `\n[1/1] Calling registerPackMachine(${machineAddress}, ${desiredState})…`,
);
const tx = await pool.write.registerPackMachine([machineAddress, desiredState!], {
  account: callerClient.account,
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
console.log(`  tx: ${tx} (block ${receipt.blockNumber})`);
if (receipt.status !== "success") {
  console.error(`registerPackMachine() reverted! Hash: ${tx}`);
  process.exit(1);
}
await sleep(STEP_DELAY_MS);

// ─── Confirm new state ────────────────────────────────────────────────────────

const newStatus = await pool.read.isRegisteredPackMachine([machineAddress]);

// ─── Summary ──────────────────────────────────────────────────────────────────

console.log(`\n=== registerPackMachine Complete ===`);
console.log(`Network:     ${connection.networkName} (chainId: ${chainId})`);
console.log(`BuybackPool: ${poolAddress}`);
console.log(`Machine:     ${machineAddress}`);
console.log(`Old status:  ${currentStatus}`);
console.log(`New status:  ${newStatus}`);
console.log(`Tx:          ${tx}`);
console.log("====================================\n");
