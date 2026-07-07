/**
 * check-pack-buyback.ts
 *
 * Read-only script that prints the buybackPool address (machine-wide) and
 * buybackAllocationBps (per-pack) for one or more packs on a PackMachine clone.
 *
 * Usage
 * -----
 * # Default machine (PackMachines[0] in deployments) + pack 0:
 * npx hardhat run scripts/check-pack-buyback.ts --network base
 *
 * # Override machine address and pack:
 * PACK_MACHINE=0x46999a9D321df9e752eCc007f5F67D2981183109 PACK_ID=1 \
 *   npx hardhat run scripts/check-pack-buyback.ts --network base
 *
 * # Several packs in one run (PACK_IDS takes precedence over PACK_ID):
 * PACK_MACHINE=0x... PACK_IDS=0,1,2 \
 *   npx hardhat run scripts/check-pack-buyback.ts --network base
 */

import { network } from "hardhat";
import { getAddress } from "viem";
import { readDeployments } from "./lib/deployments.js";

// ─── Helpers ──────────────────────────────────────────────────────────────────

function bps(value: bigint | number): string {
  const n = typeof value === "bigint" ? Number(value) : value;
  return `${n} bps (${(n / 100).toFixed(2)}%)`;
}

const TIER_LABELS: Record<number, string> = {
  0: "Base",
  1: "Common",
  2: "Uncommon",
  3: "Rare",
  4: "Ultra Rare",
  5: "Grail",
};

function tierLabel(n: number): string {
  return TIER_LABELS[n] ?? `Unknown(${n})`;
}

// ─── Parse pack IDs ───────────────────────────────────────────────────────────

function parsePackIds(): bigint[] {
  if (process.env.PACK_IDS) {
    return process.env.PACK_IDS.split(",")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => {
        const n = BigInt(s);
        if (n < 0n) {
          console.error(`Invalid PACK_IDS entry: "${s}"`);
          process.exit(1);
        }
        return n;
      });
  }
  const single =
    process.env.PACK_ID !== undefined ? process.env.PACK_ID.trim() : "0";
  const n = BigInt(single);
  if (n < 0n) {
    console.error(`Invalid PACK_ID: "${single}"`);
    process.exit(1);
  }
  return [n];
}

const packIds = parsePackIds();

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
    console.error(`Invalid PACK_MACHINE address: "${process.env.PACK_MACHINE}"`);
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

// ─── Fetch machine-wide info + per-pack data in parallel ─────────────────────

const [machineInfo, ...packs] = await Promise.all([
  machine.read.getMachineInfo(),
  ...packIds.map((id) =>
    machine.read.getPack([id]).catch((err: unknown) => {
      // Surface the error but keep other pack reads going
      return { __error: String(err), __packId: id } as unknown as ReturnType<
        typeof machine.read.getPack
      >;
    }),
  ),
]);

// ─── Print results ────────────────────────────────────────────────────────────

console.log("\n=== check-pack-buyback ===");
console.log(
  `Network:      ${connection.networkName} (chainId ${chainId})`,
);
console.log(`Machine:      ${machineAddress}`);
console.log(
  `buybackPool:  ${
    machineInfo.buybackPool === "0x0000000000000000000000000000000000000000"
      ? "(not set)"
      : machineInfo.buybackPool
  }`,
);
console.log(`Packs queried: ${packIds.join(", ")}`);

for (let i = 0; i < packIds.length; i++) {
  const packId = packIds[i];
  const pack = packs[i] as
    | Awaited<ReturnType<typeof machine.read.getPack>>
    | { __error: string; __packId: bigint };

  console.log(`\n── Pack ${packId} ──────────────────────────────────`);

  if ("__error" in pack) {
    console.log(`  ⚠ Error reading pack ${packId}: ${pack.__error}`);
    continue;
  }

  console.log(
    `  buybackAllocationBps: ${bps(pack.buybackAllocationBps)}`,
  );
  console.log(
    `  pricePerPack:         ${pack.pricePerPack} (raw payment-token units)`,
  );
  console.log(`  cardsPerPack:         ${pack.cardsPerPack}`);
  console.log(
    `  startTime:            ${
      pack.startTime === 0
        ? "(not set)"
        : `${pack.startTime} (${new Date(Number(pack.startTime) * 1000).toISOString()})`
    }`,
  );
  console.log(
    `  active:               ${pack.active ? "✓ true" : "✗ false"}`,
  );
  console.log(
    `  finished:             ${pack.finished ? "✓ true" : "✗ false"}`,
  );

  if (pack.tierWeights?.length) {
    console.log("  tierWeights:");
    for (let t = 0; t < 6; t++) {
      console.log(
        `    [${t}] ${tierLabel(t).padEnd(10)} ${bps(pack.tierWeights[t])}`,
      );
    }
  }
}

console.log("\n=========================\n");
