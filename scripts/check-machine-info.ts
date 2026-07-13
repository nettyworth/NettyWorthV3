/**
 * check-machine-info.ts
 *
 * Read-only script that prints the machine-wide config returned by
 * `PackMachine.getMachineInfo()`:
 *   - factory              address of the PackMachineFactory that spawned this clone
 *   - buybackPool          address of the BuybackPool wired to this machine
 *   - effectivePrizePoolSize  cards still available (decremented on VRF request)
 *
 * Usage
 * -----
 * # Default machine (PackMachines[0] in deployments) on Base mainnet:
 * npx hardhat run scripts/check-machine-info.ts --network base
 *
 * # Override machine address:
 * PACK_MACHINE=0x46999a9D321df9e752eCc007f5F67D2981183109 \
 *   npx hardhat run scripts/check-machine-info.ts --network base
 */

import { network } from "hardhat";
import { getAddress } from "viem";
import { readDeployments } from "./lib/deployments.js";

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();

// ─── Resolve machine address ──────────────────────────────────────────────────

let machineAddress: `0x${string}`;

if (process.env.PACK_MACHINE) {
  try {
    machineAddress = getAddress(process.env.PACK_MACHINE) as `0x${string}`;
  } catch {
    console.error(
      `Invalid PACK_MACHINE address: "${process.env.PACK_MACHINE}"`,
    );
    process.exit(1);
  }
} else {
  const data = await readDeployments(connection.networkName);
  const machines = data["PackMachines"] as { address: string }[] | undefined;
  if (!machines?.length) {
    console.error(
      `No PackMachines found in deployments/${connection.networkName}.json.`,
    );
    console.error("Set PACK_MACHINE env var to the clone address.");
    process.exit(1);
  }
  machineAddress = getAddress(machines[0].address) as `0x${string}`;
}

// ─── Contract instance ────────────────────────────────────────────────────────

const machine = await viem.getContractAt("PackMachine", machineAddress);

// ─── Fetch machine info ───────────────────────────────────────────────────────

const info = await machine.read.getMachineInfo();

// ─── Print results ────────────────────────────────────────────────────────────

const ZERO = "0x0000000000000000000000000000000000000000";

console.log("\n=== check-machine-info ===");
console.log(`Network:              ${connection.networkName} (chainId ${chainId})`);
console.log(`Machine:              ${machineAddress}`);
console.log(
  `factory:              ${info.factory === ZERO ? "(not set)" : info.factory}`,
);
console.log(
  `buybackPool:          ${info.buybackPool === ZERO ? "(not set)" : info.buybackPool}`,
);
console.log(`effectivePrizePoolSize: ${info.effectivePrizePoolSize}`);
console.log("==========================\n");
