/**
 * check-buyback-token-info.ts
 *
 * Read-only script that reports the BuybackPool custody record for one or more
 * token IDs by calling BuybackPool.getTokenInfo(tokenId).
 *
 * Usage
 * -----
 * # Single token on the default-deployment pool:
 * TOKEN_ID=42 \
 *   npx hardhat run scripts/check-buyback-token-info.ts --network base
 *
 * # Multiple tokens (comma-separated):
 * TOKEN_IDS=1,2,3 \
 *   npx hardhat run scripts/check-buyback-token-info.ts --network base
 *
 * # Override pool address (bypass deployments JSON):
 * BUYBACK_POOL_PROXY=0x<addr> TOKEN_ID=42 \
 *   npx hardhat run scripts/check-buyback-token-info.ts --network base
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

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

// ─── Parse TOKEN_ID / TOKEN_IDS env vars ─────────────────────────────────────

function parseTokenIds(): bigint[] {
  if (process.env.TOKEN_IDS) {
    return process.env.TOKEN_IDS.split(",")
      .map((s) => s.trim())
      .filter(Boolean)
      .map((s) => {
        try {
          return BigInt(s);
        } catch {
          console.error(`Invalid TOKEN_IDS entry: "${s}"`);
          process.exit(1);
        }
      });
  }
  const single =
    process.env.TOKEN_ID !== undefined ? process.env.TOKEN_ID.trim() : "";
  if (!single) {
    console.error(
      "Missing TOKEN_ID (or TOKEN_IDS) env var.\n" +
        "Example: TOKEN_ID=42 npx hardhat run scripts/check-buyback-token-info.ts --network base",
    );
    process.exit(1);
  }
  try {
    return [BigInt(single)];
  } catch {
    console.error(`Invalid TOKEN_ID value: "${single}"`);
    process.exit(1);
  }
}

const tokenIds = parseTokenIds();

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

// ─── Fetch token info in parallel ────────────────────────────────────────────

const results = await Promise.all(
  tokenIds.map((tokenId) =>
    buyback.read
      .getTokenInfo([tokenId])
      .then((info) => ({ tokenId, ...info }))
      .catch((err: unknown) => ({
        tokenId,
        __error: String(err),
      })),
  ),
);

// ─── Print results ────────────────────────────────────────────────────────────

console.log("\n=== BuybackPool Token Info ===");
console.log(`Network:       ${connection.networkName} (chainId ${chainId})`);
console.log(`BuybackPool:   ${buybackProxyAddress}`);
console.log(`Tokens queried: ${tokenIds.join(", ")}\n`);

for (const result of results) {
  console.log(`── Token ${result.tokenId} ─────────────────────────────────`);

  if ("__error" in result) {
    console.log(`  ⚠ Error reading token ${result.tokenId}: ${result.__error}`);
    continue;
  }
  console.log("reuslt", result);

  const tier = result[0];
  const sourcePackMachine = result[1];
  const isActive = result[2];
  // const [tier, sourcePackMachine, isActive] = result;

  console.log(`  tier:              ${tier} (${tierLabel(Number(tier))})`);
  console.log(
    `  sourcePackMachine: ${
      sourcePackMachine === ZERO_ADDRESS ? "(none)" : sourcePackMachine
    }`,
  );
  console.log(`  isActive:          ${isActive ? "✓ true" : "✗ false"}`);
  console.log();
}

console.log("==============================\n");
