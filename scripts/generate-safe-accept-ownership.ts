/**
 * generate-safe-accept-ownership.ts
 *
 * Generates a Safe (Gnosis Safe) Transaction Builder batch JSON that calls
 * acceptOwnership() on every deployed Ownable2Step contract. Import the output
 * into the Safe web app: Apps → Transaction Builder → "Load / import".
 *
 * This is the SECOND half of the two-step ownership handoff. The current EOA
 * owner first runs scripts/transfer-ownership.ts (which calls
 * transferOwnership(safe) → sets pendingOwner). The new owner is a Safe
 * multisig that cannot run a hardhat script, so it needs this batch to accept.
 *
 * Usage
 * -----
 * SAFE_ADDRESS=0x<multisig> \
 *   npx hardhat run scripts/generate-safe-accept-ownership.ts --network base
 *
 * The SAFE_ADDRESS is the multisig that should be pendingOwner. It is stamped
 * into the batch meta and used to verify pendingOwner() on-chain (best-effort).
 */

import { network } from "hardhat";
import { getAddress, toFunctionSelector, keccak256, toBytes } from "viem";
import { writeFile, rename, mkdir } from "node:fs/promises";
import { readDeployments, getDeploymentPath } from "./lib/deployments.js";
import { OWNABLE_CONTRACTS } from "./lib/ownership.js";

// ─── acceptOwnership() selector (Ownable2StepUpgradeable, no args) ────────────
const ACCEPT_OWNERSHIP_DATA = toFunctionSelector("acceptOwnership()"); // 0x79ba5097

// ─── Validate SAFE_ADDRESS env var ────────────────────────────────────────────
const rawSafe = process.env.SAFE_ADDRESS;
if (!rawSafe) {
  console.error("Missing required env var: SAFE_ADDRESS");
  console.error(
    "Usage: SAFE_ADDRESS=0x<multisig> npx hardhat run scripts/generate-safe-accept-ownership.ts --network <network>",
  );
  process.exit(1);
}
let safeAddress: `0x${string}`;
try {
  safeAddress = getAddress(rawSafe) as `0x${string}`;
} catch {
  console.error(`Invalid SAFE_ADDRESS address: "${rawSafe}"`);
  process.exit(1);
}

// ─── Network connection ───────────────────────────────────────────────────────
const connection = await network.create();
const { viem } = connection;
const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();

// ─── Load deployments ─────────────────────────────────────────────────────────
const deploymentData = await readDeployments(connection.networkName);

// ─── Safe Transaction Builder types ───────────────────────────────────────────
type SafeTx = {
  to: `0x${string}`;
  value: string;
  data: `0x${string}`;
  contractMethod: {
    inputs: never[];
    name: string;
    payable: boolean;
  };
  contractInputsValues: null;
};

type SafeBatch = {
  version: string;
  chainId: string;
  createdAt: number;
  meta: {
    name: string;
    description: string;
    txBuilderVersion: string;
    createdFromSafeAddress: `0x${string}`;
    createdFromOwnerAddress: string;
    checksum?: `0x${string}`;
  };
  transactions: SafeTx[];
};

/**
 * Reimplements the Safe Transaction Builder `calculateChecksum`: serialize the
 * batch with sorted keys (meta.name nulled), then keccak256 over UTF-8 bytes.
 * Matches safe-react so the app imports the file without a checksum warning.
 */
function serializeJSONObject(json: unknown): string {
  if (Array.isArray(json)) {
    return `[${json.map((el) => serializeJSONObject(el)).join(",")}]`;
  }
  if (typeof json === "object" && json !== null) {
    const obj = json as Record<string, unknown>;
    const keys = Object.keys(obj).sort();
    let acc = `{${JSON.stringify(keys)}`;
    for (const key of keys) {
      acc += `${serializeJSONObject(obj[key])},`;
    }
    return `${acc}}`;
  }
  return `${JSON.stringify(json)}`;
}

function calculateChecksum(batch: SafeBatch): `0x${string}` {
  const serialized = serializeJSONObject({
    ...batch,
    meta: { ...batch.meta, name: null },
  });
  return keccak256(toBytes(serialized));
}

// ─── Build one acceptOwnership() tx per deployed Ownable2Step contract ─────────
const transactions: SafeTx[] = [];
const included: Array<{ key: string; proxy: `0x${string}` }> = [];

console.log(`\n=== generate-safe-accept-ownership ===`);
console.log(`Network:  ${connection.networkName} (chainId: ${chainId})`);
console.log(`Safe:     ${safeAddress}`);
console.log("--------------------------------------");

for (const { key, contract } of OWNABLE_CONTRACTS) {
  const entry = deploymentData[key] as Record<string, unknown> | undefined;
  if (!entry?.proxy) {
    console.log(`  ~ ${key}: not deployed on this network (skip)`);
    continue;
  }
  const proxy = getAddress(entry.proxy as string) as `0x${string}`;

  // Best-effort verification: pendingOwner() should already be the Safe.
  try {
    const c = await viem.getContractAt(contract, proxy);
    const pendingOwner = getAddress(
      (await c.read.pendingOwner()) as string,
    ) as `0x${string}`;
    const owner = getAddress((await c.read.owner()) as string) as `0x${string}`;

    if (owner.toLowerCase() === safeAddress.toLowerCase()) {
      console.log(
        `  ~ ${key} (${proxy}): Safe is ALREADY owner — acceptOwnership would revert (skip)`,
      );
      continue;
    }
    if (pendingOwner.toLowerCase() !== safeAddress.toLowerCase()) {
      console.warn(
        `  ! ${key} (${proxy}): pendingOwner is ${pendingOwner}, NOT the Safe. ` +
          `Run transfer-ownership.ts first, or this tx will revert. Including anyway.`,
      );
    } else {
      console.log(`  + ${key} (${proxy}): pendingOwner == Safe ✓`);
    }
  } catch (err) {
    console.warn(
      `  ! ${key} (${proxy}): could not verify on-chain (${(err as Error).message}). Including anyway.`,
    );
  }

  transactions.push({
    to: proxy,
    value: "0",
    data: ACCEPT_OWNERSHIP_DATA,
    contractMethod: { inputs: [], name: "acceptOwnership", payable: false },
    contractInputsValues: null,
  });
  included.push({ key, proxy });
}

if (transactions.length === 0) {
  console.error(
    "\nNo Ownable2Step contracts to accept on this network — nothing to generate.",
  );
  process.exit(1);
}

// ─── Assemble the batch ────────────────────────────────────────────────────────
// createdAt: Date.now() is fine here (this is a plain node script, not a
// deterministic workflow). It is informational metadata only.
const batch: SafeBatch = {
  version: "1.0",
  chainId: String(chainId),
  createdAt: Date.now(),
  meta: {
    name: `Accept NettyWorth ownership (${connection.networkName})`,
    description: `acceptOwnership() for ${included.map((i) => i.key).join(", ")}`,
    txBuilderVersion: "1.16.5",
    createdFromSafeAddress: safeAddress,
    createdFromOwnerAddress: "",
  },
  transactions,
};
batch.meta.checksum = calculateChecksum(batch);

// ─── Write output (atomic tmp-write + rename) ──────────────────────────────────
const outPath = getDeploymentPath(connection.networkName).replace(
  /[^/]+$/,
  `safe-accept-ownership.${connection.networkName}.json`,
);
const tmpPath = `${outPath}.tmp`;
await mkdir(outPath.replace(/\/[^/]+$/, ""), { recursive: true });
await writeFile(tmpPath, JSON.stringify(batch, null, 2) + "\n");
await rename(tmpPath, outPath);

console.log("--------------------------------------");
console.log(`Generated ${transactions.length} acceptOwnership() tx(s):`);
for (const i of included) console.log(`     ${i.key}  ${i.proxy}`);
console.log(`\nWrote: ${outPath}`);
console.log(
  "\nNext: open the Safe web app → Apps → Transaction Builder → drag in this file (or use its import), review, and execute the batch from the multisig.",
);
console.log("======================================\n");
