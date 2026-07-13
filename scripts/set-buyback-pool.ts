/**
 * set-buyback-pool.ts
 *
 * Update the buyback pool address on a PackMachine clone.
 * The contract reverts PackMachine__NotPaused if called while unpaused, so
 * this script auto-pauses before the setter and restores the previous state
 * (unpaused) afterwards.
 *
 * Caller must hold PACK_OPERATOR_ROLE (for the setter) and PAUSER_ROLE (to
 * auto-pause/unpause if the machine is not already paused).
 *
 * Usage
 * -----
 * # Set buyback pool on the last deployed PackMachine:
 * BUYBACK_POOL=0x<addr> \
 *   npx hardhat run scripts/set-buyback-pool.ts --network base
 *
 * # Set on a specific machine:
 * PACK_MACHINE=0x<addr> BUYBACK_POOL=0x<addr> \
 *   npx hardhat run scripts/set-buyback-pool.ts --network base
 *
 * Environment variables
 * ---------------------
 * BUYBACK_POOL   (required) new buyback pool address
 * PACK_MACHINE   clone address (optional; defaults to last entry in PackMachines[])
 * STEP_DELAY_MS  ms to wait after each on-chain write for RPC sync (default: 3000)
 */

import { network } from "hardhat";
import { getAddress, isAddress, keccak256, toHex } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments } from "./lib/deployments.js";
import { sleep } from "./lib/sleep.js";

const STEP_DELAY_MS = Number(process.env.STEP_DELAY_MS ?? "3000");

// ─── Role constants (must match contracts/lib/Roles.sol) ─────────────────────

const PACK_OPERATOR_ROLE = keccak256(toHex("PACK_OPERATOR_ROLE"));
const PAUSER_ROLE = keccak256(toHex("PAUSER_ROLE"));

// ─── Parse BUYBACK_POOL ───────────────────────────────────────────────────────

const rawPool = process.env.BUYBACK_POOL;
if (!rawPool) {
  console.error("Missing required env variable BUYBACK_POOL.");
  console.error(
    "Usage: BUYBACK_POOL=0x<addr> npx hardhat run scripts/set-buyback-pool.ts --network <net>",
  );
  process.exit(1);
}
if (!isAddress(rawPool)) {
  console.error(
    `Invalid BUYBACK_POOL: "${rawPool}". Must be a valid Ethereum address (0x-prefixed, 20 bytes).`,
  );
  process.exit(1);
}
const newPool = getAddress(rawPool) as `0x${string}`;
if (newPool === "0x0000000000000000000000000000000000000000") {
  console.error(
    "BUYBACK_POOL cannot be the zero address — the contract will revert PackMachine__ZeroAddress.",
  );
  process.exit(1);
}

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [callerClient] = await viem.getWalletClients();
const callerAddress = callerClient.account.address;
const chainId = await publicClient.getChainId();

// ─── Resolve PackMachine clone address ───────────────────────────────────────

let cloneAddress: `0x${string}`;

if (process.env.PACK_MACHINE) {
  if (!isAddress(process.env.PACK_MACHINE)) {
    console.error(
      `Invalid PACK_MACHINE: "${process.env.PACK_MACHINE}". Must be a valid Ethereum address.`,
    );
    process.exit(1);
  }
  cloneAddress = getAddress(process.env.PACK_MACHINE) as `0x${string}`;
} else {
  const deploymentData = await readDeployments(connection.networkName);
  const machines = deploymentData["PackMachines"] as
    | Array<Record<string, unknown>>
    | undefined;
  if (!machines || machines.length === 0) {
    console.error(
      `No PackMachines found in deployments/${connection.networkName}.json.`,
    );
    console.error(
      "Set PACK_MACHINE env var to the clone address, or run create-pack-machine.ts first.",
    );
    process.exit(1);
  }
  const last = machines[machines.length - 1];
  if (!last?.address || !isAddress(last.address as string)) {
    console.error(
      "Last PackMachines entry has no valid address. Set PACK_MACHINE env var explicitly.",
    );
    process.exit(1);
  }
  cloneAddress = getAddress(last.address as string) as `0x${string}`;
  console.log(`Using last PackMachine from deployments: ${cloneAddress}`);
}

// ─── Contract instance ────────────────────────────────────────────────────────

const clone = await viem.getContractAt("PackMachine", cloneAddress);

// ─── Verify caller has required roles ────────────────────────────────────────

const machineInfo = await clone.read.getMachineInfo();
const factoryAddress = machineInfo.factory as `0x${string}`;
const factory = await viem.getContractAt("PackMachineFactory", factoryAddress);
const pmAddress = (await factory.read.getPermissionManager()) as `0x${string}`;
const pm = await viem.getContractAt("PermissionManager", pmAddress);

const [hasOperatorRole, hasPauserRole] = await Promise.all([
  pm.read.hasProtocolRole([PACK_OPERATOR_ROLE, callerAddress]),
  pm.read.hasProtocolRole([PAUSER_ROLE, callerAddress]),
]);
if (!hasOperatorRole) {
  console.error(
    `Account ${callerAddress} does not have PACK_OPERATOR_ROLE — transaction would revert.`,
  );
  process.exit(1);
}

const wasPaused = await clone.read.paused();
if (!wasPaused && !hasPauserRole) {
  console.error(
    `Account ${callerAddress} does not have PAUSER_ROLE and the machine is not paused.`,
  );
  console.error(
    "The machine must be paused before calling setBuybackPool, or the caller must hold PAUSER_ROLE to auto-pause.",
  );
  process.exit(1);
}

// ─── No-op check ─────────────────────────────────────────────────────────────

const currentPool = machineInfo.buybackPool as `0x${string}`;
if (getAddress(currentPool) === newPool) {
  console.log(
    `\nNo-op: buyback pool is already set to ${newPool}. Nothing to do.`,
  );
  process.exit(0);
}

// ─── Confirmation on live networks ────────────────────────────────────────────

const steps = [
  ...(!wasPaused ? ["pause()"] : []),
  `setBuybackPool(${newPool})`,
  ...(!wasPaused ? ["unpause()"] : []),
];

console.log(`\nPackMachine:  ${cloneAddress}`);
console.log(`Current pool: ${currentPool}`);
console.log(`New pool:     ${newPool}`);
console.log(`Steps:        ${steps.join(" → ")}`);

if (connection.networkConfig.type === "http") {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setBuybackPool Summary ===");
  console.log(`Network:      ${connection.networkName}`);
  console.log(`Chain ID:     ${chainId}`);
  console.log(`Caller:       ${callerAddress}`);
  console.log(`PackMachine:  ${cloneAddress}`);
  console.log(`Current pool: ${currentPool}`);
  console.log(`New pool:     ${newPool}`);
  console.log(`Steps:        ${steps.join(" → ")}`);
  console.log("==============================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  if (answer.toLowerCase() !== "yes") {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Step 1 (optional): pause ────────────────────────────────────────────────

const totalSteps = steps.length;
let step = 1;

if (!wasPaused) {
  console.log(`\n[${step++}/${totalSteps}] Calling pause()…`);
  const pauseTx = await clone.write.pause({ account: callerClient.account });
  const pauseReceipt = await publicClient.waitForTransactionReceipt({
    hash: pauseTx,
  });
  console.log(`  tx: ${pauseTx} (block ${pauseReceipt.blockNumber})`);
  if (pauseReceipt.status !== "success") {
    console.error(`pause() reverted! Hash: ${pauseTx}`);
    process.exit(1);
  }
  await sleep(STEP_DELAY_MS);
}

// ─── Step 2: setBuybackPool ───────────────────────────────────────────────────

console.log(`\n[${step++}/${totalSteps}] Calling setBuybackPool(${newPool})…`);
const setterTx = await clone.write.setBuybackPool([newPool], {
  account: callerClient.account,
});
const setterReceipt = await publicClient.waitForTransactionReceipt({
  hash: setterTx,
});
console.log(`  tx: ${setterTx} (block ${setterReceipt.blockNumber})`);
if (setterReceipt.status !== "success") {
  console.error(`setBuybackPool() reverted! Hash: ${setterTx}`);
  if (!wasPaused) {
    console.error(
      `⚠  Machine was auto-paused but setter failed — unpause manually or re-run.`,
    );
  }
  process.exit(1);
}
await sleep(STEP_DELAY_MS);

// ─── Step 3 (optional): unpause ──────────────────────────────────────────────

if (!wasPaused) {
  console.log(`\n[${step++}/${totalSteps}] Calling unpause()…`);
  const unpauseTx = await clone.write.unpause({
    account: callerClient.account,
  });
  const unpauseReceipt = await publicClient.waitForTransactionReceipt({
    hash: unpauseTx,
  });
  console.log(`  tx: ${unpauseTx} (block ${unpauseReceipt.blockNumber})`);
  if (unpauseReceipt.status !== "success") {
    console.error(`unpause() reverted! Hash: ${unpauseTx}`);
    console.error("⚠  Machine is still paused — unpause manually.");
    process.exit(1);
  }
  await sleep(STEP_DELAY_MS);
}

// ─── Summary ─────────────────────────────────────────────────────────────────

console.log("\n=== setBuybackPool Complete ===");
console.log(`Network:      ${connection.networkName} (chainId: ${chainId})`);
console.log(`PackMachine:  ${cloneAddress}`);
console.log(`Old pool:     ${currentPool}`);
console.log(`New pool:     ${newPool}`);
console.log(`Setter tx:    ${setterTx}`);
console.log("===============================\n");
