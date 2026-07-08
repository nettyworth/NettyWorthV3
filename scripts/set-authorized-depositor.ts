/**
 * set-authorized-depositor.ts
 *
 * Authorize or revoke an address's ability to call depositFromPool on a
 * PackMachine clone.  Requires the machine to be paused first — the contract
 * reverts PackMachine__NotPaused if it is not.
 *
 * Caller must hold PACK_OPERATOR_ROLE.
 *
 * Usage
 * -----
 * # Authorize an address on the last deployed PackMachine:
 * DEPOSITOR=0x<addr> AUTHORIZED=true \
 *   npx hardhat run scripts/set-authorized-depositor.ts --network base
 *
 * # Revoke on a specific machine:
 * PACK_MACHINE=0x<addr> DEPOSITOR=0x<addr> AUTHORIZED=false \
 *   npx hardhat run scripts/set-authorized-depositor.ts --network base
 *
 * Environment variables
 * ---------------------
 * DEPOSITOR      (required) address to authorize or revoke
 * AUTHORIZED     (required) "true"/"1" to authorize, "false"/"0" to revoke
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

// ─── Parse DEPOSITOR ──────────────────────────────────────────────────────────

const rawDepositor = process.env.DEPOSITOR;
if (!rawDepositor) {
  console.error("Missing required env variable DEPOSITOR.");
  console.error(
    "Usage: DEPOSITOR=0x<addr> AUTHORIZED=true|false npx hardhat run scripts/set-authorized-depositor.ts --network <net>",
  );
  process.exit(1);
}
if (!isAddress(rawDepositor)) {
  console.error(
    `Invalid DEPOSITOR: "${rawDepositor}". Must be a valid Ethereum address (0x-prefixed, 20 bytes).`,
  );
  process.exit(1);
}
const depositor = getAddress(rawDepositor) as `0x${string}`;
if (depositor === "0x0000000000000000000000000000000000000000") {
  console.error(
    "DEPOSITOR cannot be the zero address — the contract will revert PackMachine__ZeroAddress.",
  );
  process.exit(1);
}

// ─── Parse AUTHORIZED ────────────────────────────────────────────────────────

const rawAuthorized = process.env.AUTHORIZED;
if (rawAuthorized === undefined) {
  console.error(
    'Missing required env variable AUTHORIZED ("true" or "false").',
  );
  process.exit(1);
}
let authorized: boolean;
if (rawAuthorized === "true" || rawAuthorized === "1") {
  authorized = true;
} else if (rawAuthorized === "false" || rawAuthorized === "0") {
  authorized = false;
} else {
  console.error(
    `Invalid AUTHORIZED: "${rawAuthorized}". Must be "true", "false", "1", or "0".`,
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
    "The machine must be paused before calling setAuthorizedDepositor, or the caller must hold PAUSER_ROLE to auto-pause.",
  );
  process.exit(1);
}

// ─── Confirmation on live networks ────────────────────────────────────────────

const steps = [
  ...(!wasPaused ? ["pause()"] : []),
  `setAuthorizedDepositor(${depositor}, ${authorized})`,
  ...(!wasPaused ? ["unpause()"] : []),
];

console.log(`\nPackMachine:  ${cloneAddress}`);
console.log(`Depositor:    ${depositor}`);
console.log(`Action:       ${authorized ? "AUTHORIZE" : "REVOKE"}`);
console.log(`Steps:        ${steps.join(" → ")}`);

if (connection.networkConfig.type === "http") {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setAuthorizedDepositor Summary ===");
  console.log(`Network:      ${connection.networkName}`);
  console.log(`Chain ID:     ${chainId}`);
  console.log(`Caller:       ${callerAddress}`);
  console.log(`PackMachine:  ${cloneAddress}`);
  console.log(`Depositor:    ${depositor}`);
  console.log(`Authorized:   ${authorized}`);
  console.log(`Steps:        ${steps.join(" → ")}`);
  console.log("======================================\n");
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

// ─── Step 2: setAuthorizedDepositor ──────────────────────────────────────────

console.log(
  `\n[${step++}/${totalSteps}] Calling setAuthorizedDepositor(${depositor}, ${authorized})…`,
);
const setterTx = await clone.write.setAuthorizedDepositor(
  [depositor, authorized],
  { account: callerClient.account },
);
const setterReceipt = await publicClient.waitForTransactionReceipt({
  hash: setterTx,
});
console.log(`  tx: ${setterTx} (block ${setterReceipt.blockNumber})`);
if (setterReceipt.status !== "success") {
  console.error(`setAuthorizedDepositor() reverted! Hash: ${setterTx}`);
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

console.log("\n=== setAuthorizedDepositor Complete ===");
console.log(`Network:      ${connection.networkName} (chainId: ${chainId})`);
console.log(`PackMachine:  ${cloneAddress}`);
console.log(`Depositor:    ${depositor}`);
console.log(`Authorized:   ${authorized}`);
console.log(`Setter tx:    ${setterTx}`);
console.log("=======================================\n");
