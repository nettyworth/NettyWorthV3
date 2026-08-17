/**
 * safe-batch.ts
 *
 * Helpers for emitting Safe (Gnosis Safe) Transaction Builder batch JSON files.
 *
 * A Safe multisig cannot run a hardhat script, so every owner-gated protocol
 * call has to be handed to the signers as a batch file they import via
 * Safe web app → Apps → Transaction Builder → "Load / import". These helpers
 * build that file and stamp the safe-react-compatible checksum so the app
 * accepts it without a "checksum mismatch" warning.
 *
 * Two ways to express a transaction:
 *   - raw data mode  — set `data` to the encoded calldata, `contractMethod` may
 *     have empty `inputs` and `contractInputsValues` is null.
 *   - ABI mode       — leave `data` null and describe the call via
 *     `contractMethod.inputs` + `contractInputsValues`; the Safe UI then shows
 *     signers a decoded call instead of an opaque hex blob.
 */

import { keccak256, toBytes } from "viem";
import { writeFile, rename, mkdir } from "node:fs/promises";
import { getDeploymentPath } from "./deployments.js";

// ─── Safe Transaction Builder types ───────────────────────────────────────────

export type SafeAbiInput = {
  internalType: string;
  name: string;
  type: string;
};

export type SafeTx = {
  to: `0x${string}`;
  value: string;
  /** Encoded calldata (raw data mode), or null when using ABI mode. */
  data: `0x${string}` | null;
  contractMethod: {
    inputs: SafeAbiInput[];
    name: string;
    payable: boolean;
  };
  /** Named arg values as decimal/hex strings (ABI mode), or null. */
  contractInputsValues: Record<string, string> | null;
};

export type SafeBatch = {
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

// ─── Checksum (mirrors safe-react `calculateChecksum`) ────────────────────────

/**
 * Serializes a JSON value with object keys sorted — the exact shape safe-react
 * hashes. Arrays keep their order; objects are emitted as the sorted key list
 * followed by each value in that order.
 */
export function serializeJSONObject(json: unknown): string {
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

/**
 * Reimplements the Safe Transaction Builder `calculateChecksum`: serialize the
 * batch with sorted keys (meta.name nulled), then keccak256 over UTF-8 bytes.
 */
export function calculateChecksum(batch: SafeBatch): `0x${string}` {
  const serialized = serializeJSONObject({
    ...batch,
    meta: { ...batch.meta, name: null },
  });
  return keccak256(toBytes(serialized));
}

// ─── Batch assembly ───────────────────────────────────────────────────────────

/**
 * Assembles a Transaction Builder batch and stamps `meta.checksum`.
 *
 * `createdAt` uses Date.now() — informational metadata only, and these are
 * plain node scripts rather than deterministic workflows.
 */
export function buildBatch(opts: {
  chainId: number | string;
  safeAddress: `0x${string}`;
  name: string;
  description: string;
  transactions: SafeTx[];
}): SafeBatch {
  const batch: SafeBatch = {
    version: "1.0",
    chainId: String(opts.chainId),
    createdAt: Date.now(),
    meta: {
      name: opts.name,
      description: opts.description,
      txBuilderVersion: "1.16.5",
      createdFromSafeAddress: opts.safeAddress,
      createdFromOwnerAddress: "",
    },
    transactions: opts.transactions,
  };
  batch.meta.checksum = calculateChecksum(batch);
  return batch;
}

/**
 * Writes a batch to `deployments/<fileStem>.<network>.json` using an atomic
 * tmp-write + rename so a crash mid-write cannot leave a truncated file.
 * Returns the path written.
 */
export async function writeBatch(
  networkName: string,
  fileStem: string,
  batch: SafeBatch,
): Promise<string> {
  const outPath = getDeploymentPath(networkName).replace(
    /[^/]+$/,
    `${fileStem}.${networkName}.json`,
  );
  const tmpPath = `${outPath}.tmp`;
  await mkdir(outPath.replace(/\/[^/]+$/, ""), { recursive: true });
  await writeFile(tmpPath, JSON.stringify(batch, null, 2) + "\n");
  await rename(tmpPath, outPath);
  return outPath;
}
