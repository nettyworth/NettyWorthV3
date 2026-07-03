/**
 * check-buyback-registration.ts
 *
 * Read-only script that reports the BuybackPool registration status and
 * buyback config for one or more PackMachine clones.
 *
 * Usage
 * -----
 * # Check specific machine(s) — comma-separated:
 * PACK_MACHINE=0x<addr>[,0x<addr>,...] \
 *   npx hardhat run scripts/check-buyback-registration.ts --network baseSepolia
 *
 * # Enumerate all machines from PackMachineRegistered event logs:
 * npx hardhat run scripts/check-buyback-registration.ts --network baseSepolia
 *
 * Optional override (bypass deployments JSON):
 * BUYBACK_POOL_PROXY=0x<addr> ...
 */

import { network } from "hardhat";
import { formatUnits, getAddress } from "viem";
import { readDeployments } from "./lib/deployments.js";

// ─── BuybackModel enum ────────────────────────────────────────────────────────

const BuybackModelLabel: Record<number, string> = {
  0: "Unset (inherit default)",
  1: "AmountSpent",
  2: "FMV",
};

function modelLabel(n: number): string {
  return BuybackModelLabel[n] ?? `Unknown(${n})`;
}

// ─── Parse PACK_MACHINE env var ───────────────────────────────────────────────

const rawMachines = process.env.PACK_MACHINE;
const targetMachines: `0x${string}`[] = rawMachines
  ? rawMachines
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => {
        try {
          return getAddress(s) as `0x${string}`;
        } catch {
          console.error(`Invalid PACK_MACHINE address: "${s}"`);
          process.exit(1);
        }
      })
  : [];

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();

// ─── Resolve BuybackPool proxy address ───────────────────────────────────────

let buybackProxyAddress: `0x${string}`;

if (process.env.BUYBACK_POOL_PROXY) {
  buybackProxyAddress = getAddress(
    process.env.BUYBACK_POOL_PROXY,
  ) as `0x${string}`;
} else {
  const data = await readDeployments(connection.networkName);
  const entry = data["BuybackPool"] as Record<string, unknown> | undefined;
  if (!entry?.proxy) {
    console.error(
      `BuybackPool proxy not found in deployments/${connection.networkName}.json.`,
    );
    console.error("Set BUYBACK_POOL_PROXY to override.");
    process.exit(1);
  }
  buybackProxyAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── BuybackPool contract instance ───────────────────────────────────────────

const buyback = await viem.getContractAt("BuybackPool", buybackProxyAddress);

// ─── Pool-level context (read once) ──────────────────────────────────────────

const defaultBps = await buyback.read.getDefaultBuybackBps();
const balance = await buyback.read.poolBalance();

console.log("\n=== BuybackPool Status ===");
console.log(`Network:              ${connection.networkName} (chainId ${chainId})`);
console.log(`BuybackPool proxy:    ${buybackProxyAddress}`);
console.log(`Pool balance:         ${formatUnits(balance, 6)} USDC (${balance} base units)`);
console.log(`Default buyback rate: ${defaultBps} bps (${(Number(defaultBps) / 100).toFixed(2)}%)`);

// ─── Resolve machine list (from env or event logs) ───────────────────────────

let machines: `0x${string}`[] = targetMachines;

if (machines.length === 0) {
  console.log(
    "\nNo PACK_MACHINE specified — enumerating from PackMachineRegistered events…",
  );

  const abi = [
    {
      name: "PackMachineRegistered",
      type: "event",
      inputs: [
        { name: "packMachine", type: "address", indexed: true },
        { name: "registered", type: "bool", indexed: false },
      ],
    },
  ] as const;

  const logs = await publicClient.getContractEvents({
    address: buybackProxyAddress,
    abi,
    eventName: "PackMachineRegistered",
    fromBlock: 0n,
    toBlock: "latest",
  });

  if (logs.length === 0) {
    console.log("No PackMachineRegistered events found on this network.");
    process.exit(0);
  }

  // Latest event per machine determines current state; keep only those
  // that were last seen as registered=true.
  const latestState = new Map<string, boolean>();
  for (const log of logs) {
    const addr = getAddress(log.args.packMachine as string);
    latestState.set(addr, log.args.registered as boolean);
  }

  machines = [...latestState.entries()]
    .filter(([, reg]) => reg)
    .map(([addr]) => addr) as `0x${string}`[];

  const deregistered = [...latestState.entries()].filter(([, reg]) => !reg);

  console.log(`Found ${latestState.size} distinct machine(s) in event history:`);
  console.log(`  → ${machines.length} currently registered`);
  if (deregistered.length > 0) {
    console.log(
      `  → ${deregistered.length} deregistered: ${deregistered.map(([a]) => a).join(", ")}`,
    );
  }
}

// ─── Per-machine report ───────────────────────────────────────────────────────

if (machines.length === 0) {
  console.log("\nNo registered machines to report.");
  process.exit(0);
}

console.log(`\n=== Per-Machine Registration Check (${machines.length} machine(s)) ===\n`);

for (const machine of machines) {
  const [isRegistered, overrideBps, model] = await Promise.all([
    buyback.read.isRegisteredPackMachine([machine]),
    buyback.read.getPackMachineBuybackBps([machine]),
    buyback.read.getResolvedModel([machine]),
  ]);

  const effectiveBps = overrideBps === 0 ? defaultBps : overrideBps;
  const overrideNote =
    overrideBps === 0 ? `(uses default: ${defaultBps} bps)` : `(override)`;

  console.log(`Machine: ${machine}`);
  console.log(`  Registered:           ${isRegistered ? "✓ yes" : "✗ no"}`);
  console.log(`  Buyback rate:         ${effectiveBps} bps (${(Number(effectiveBps) / 100).toFixed(2)}%) ${overrideNote}`);
  console.log(`  Resolved model:       ${modelLabel(Number(model))}`);
  console.log();
}
