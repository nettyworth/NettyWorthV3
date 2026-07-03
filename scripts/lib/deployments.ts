import { readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../../deployments",
);

/**
 * Returns the absolute path to the deployments JSON file for the given network.
 */
export function getDeploymentPath(networkName: string): string {
  return join(deploymentsDir, `${networkName}.json`);
}

/**
 * Reads and parses the deployments JSON for the given network.
 * Returns an empty object if the file does not exist or cannot be parsed.
 */
export async function readDeployments(
  networkName: string,
): Promise<Record<string, unknown>> {
  try {
    return JSON.parse(await readFile(getDeploymentPath(networkName), "utf8"));
  } catch {
    return {};
  }
}

/**
 * Polls getCode on `address` until bytecode is present — closes the
 * read-after-write gap on load-balanced RPCs where a just-deployed
 * implementation isn't yet visible to the node servicing the next call.
 * Throws if no code appears within the timeout.
 */
export async function waitForCode(
  publicClient: {
    getCode: (a: {
      address: `0x${string}`;
    }) => Promise<`0x${string}` | undefined>;
  },
  address: `0x${string}`,
  opts: { timeoutMs?: number; intervalMs?: number } = {},
): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? 60_000;
  const intervalMs = opts.intervalMs ?? 2_000;
  const start = Date.now();
  for (;;) {
    const code = await publicClient.getCode({ address });
    if (code && code !== "0x") return;
    if (Date.now() - start > timeoutMs)
      throw new Error(
        `waitForCode: no bytecode at ${address} after ${timeoutMs}ms`,
      );
    await new Promise<void>((r) => setTimeout(r, intervalMs));
  }
}

/**
 * Atomically writes a single deployment record into the network's JSON file.
 * Reads the existing file, merges the new key, then writes to a temporary file
 * before renaming to the final path — prevents partial writes from corrupting
 * the JSON if the process dies mid-write.
 *
 * Only writes when `isLive` is true (i.e. `networkConfig.type === "http"`).
 * Callers should guard with that check to keep test-network runs clean.
 */
export async function saveDeployment(
  networkName: string,
  key: string,
  record: Record<string, unknown>,
): Promise<void> {
  await mkdir(deploymentsDir, { recursive: true });

  const outPath = getDeploymentPath(networkName);
  const tmpPath = `${outPath}.tmp`;

  let existing: Record<string, unknown> = {};
  try {
    existing = JSON.parse(await readFile(outPath, "utf8"));
  } catch {
    // file doesn't exist yet — start fresh
  }

  existing[key] = record;

  await writeFile(tmpPath, JSON.stringify(existing, null, 2) + "\n");
  await rename(tmpPath, outPath);
}
