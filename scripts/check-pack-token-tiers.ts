/**
 * check-pack-token-tiers.ts
 *
 * Read-only script that reports the resolved tier for one or more tokens
 * across one or more packs by calling PackMachine.getPackTokenTier(tokenId, packId).
 * Reverts per (tokenId, packId) pair are caught individually so one
 * uncustodied/ineligible token doesn't abort the whole batch.
 *
 * Usage
 * -----
 * # Single token, single pack:
 * TOKEN_ID=42 PACK_ID=0 \
 *   npx hardhat run scripts/check-pack-token-tiers.ts --network base
 *
 * # Multiple tokens x multiple packs (comma-separated, cross product):
 * TOKEN_IDS=1,2,3 PACK_IDS=0,1 \
 *   npx hardhat run scripts/check-pack-token-tiers.ts --network base
 *
 * # Override machine address (bypass deployments JSON):
 * PACK_MACHINE=0x<addr> TOKEN_ID=42 \
 *   npx hardhat run scripts/check-pack-token-tiers.ts --network base
 */

import { network } from "hardhat";
import { getAddress } from "viem";
import { readDeployments } from "./lib/deployments.js";

// ─── Helpers ──────────────────────────────────────────────────────────────────

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

// ─── Parse TOKEN_ID / TOKEN_IDS and PACK_ID / PACK_IDS env vars ─────────────

function parseBigIntList(
  singleVar: string,
  listVar: string,
  { required }: { required: boolean },
): bigint[] {
  const listValue = process.env[listVar];
  if (listValue) {
    return listValue
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => {
        try {
          return BigInt(s);
        } catch {
          console.error(`Invalid ${listVar} entry: "${s}"`);
          process.exit(1);
        }
      });
  }

  const single = (process.env[singleVar] ?? "").trim();
  if (!single) {
    if (required) {
      console.error(
        `Missing ${singleVar} (or ${listVar}) env var.\n` +
          `Example: ${singleVar}=42 npx hardhat run scripts/check-pack-token-tiers.ts --network base`,
      );
      process.exit(1);
    }
    return [];
  }
  try {
    return [BigInt(single)];
  } catch {
    console.error(`Invalid ${singleVar} value: "${single}"`);
    process.exit(1);
  }
}

const tokenIds = parseBigIntList("TOKEN_ID", "TOKEN_IDS", { required: true });
const packIds = parseBigIntList("PACK_ID", "PACK_IDS", { required: false });
const effectivePackIds = packIds.length > 0 ? packIds : [0n];

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();

// ─── Resolve PackMachine address ──────────────────────────────────────────────

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

// ─── Fetch tiers for every (tokenId, packId) pair in parallel ───────────────

const pairs = tokenIds.flatMap((tokenId) =>
  effectivePackIds.map((packId) => ({ tokenId, packId })),
);

const results = await Promise.all(
  pairs.map(({ tokenId, packId }) =>
    machine.read
      .getPackTokenTier([tokenId, packId])
      .then((tier) => ({ tokenId, packId, tier }))
      .catch((err: unknown) => ({
        tokenId,
        packId,
        __error: String(err),
      })),
  ),
);

// ─── Print results ────────────────────────────────────────────────────────────

console.log("\n=== PackMachine Token Tiers ===");
console.log(`Network:  ${connection.networkName} (chainId ${chainId})`);
console.log(`Machine:  ${machineAddress}`);
console.log(`Tokens:   ${tokenIds.join(", ")}`);
console.log(`Packs:    ${effectivePackIds.join(", ")}\n`);

let currentTokenId: bigint | undefined;
for (const result of results) {
  if (result.tokenId !== currentTokenId) {
    currentTokenId = result.tokenId;
    console.log(`── Token ${result.tokenId} ─────────────────────────────────`);
  }

  if ("__error" in result) {
    console.log(`  pack ${result.packId}: ⚠ ${result.__error}`);
    continue;
  }

  console.log(
    `  pack ${result.packId}: tier ${result.tier} (${tierLabel(Number(result.tier))})`,
  );
}

console.log("\n================================\n");
