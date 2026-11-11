/**
 * propose-safe-upgrade-pack-batcher.ts
 *
 * The prod PackBatcher proxy still runs the 2026-08-05 implementation, which has only the legacy
 * `openPacks`. The API calls `openPacksWithCodes` (battle wallet, Stripe qty>1), and an unknown
 * selector reverts with empty data. UPGRADER_ROLE is held by the Safe multisig, so this script:
 *   1. picks the new implementation — by default the one the staging proxy already runs
 *      (0x9f13…ab7a), after checking its bytecode matches the compiled PackBatcher,
 *   2. writes a Safe Transaction Builder batch with a single upgradeToAndCall(newImpl, "0x"),
 *   3. on a fork, impersonates the Safe, runs the batch and checks the result.
 *
 * Usage
 * -----
 * # Rehearse on a Base fork (nothing is broadcast):
 * npx hardhat run scripts/upgrade/propose-safe-upgrade-pack-batcher.ts --network forkBase
 *
 * # Mainnet: writes the Safe JSON. It does NOT upgrade anything (and deploys nothing unless
 * # DEPLOY_NEW_IMPL=1). Import the JSON in app.safe.global > Transaction Builder.
 * npx hardhat run scripts/upgrade/propose-safe-upgrade-pack-batcher.ts --network base
 *
 * Optional env vars:
 *   PACK_BATCHER_NEW_IMPL  implementation to propose (default: the staging impl)
 *   DEPLOY_NEW_IMPL=1      deploy a fresh implementation from BASE_PRIVATE_KEY instead
 *   UPGRADE_OUT            output path for the Safe JSON
 */

import { network } from "hardhat";
import {
  BaseError,
  ContractFunctionRevertedError,
  encodeFunctionData,
  getAddress,
  parseEther,
  zeroAddress,
} from "viem";
import { readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SAFE = getAddress("0xfe78E8aa8f4B9f616e05a94604aB86A7B192f456");
// Implementation behind the staging batcher 0x48cd…ab009; built from the same source.
const STAGING_IMPL = getAddress("0x9f1307b9c3bab50e7930e2635c947aec5bc4ab7a");
const ERC1967_IMPL_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc" as const;

const upgradeAbi = [
  {
    type: "function",
    name: "upgradeToAndCall",
    stateMutability: "payable",
    inputs: [
      { name: "newImplementation", type: "address" },
      { name: "data", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

const connection = await network.create();
const { viem } = connection;
const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();
const isFork = connection.networkConfig.type === "edr-simulated";

const rootDir = join(dirname(fileURLToPath(import.meta.url)), "../..");
// Fork runs read prod addresses; the fork network has no JSON of its own.
const deployments = JSON.parse(
  await readFile(join(rootDir, "deployments/base.json"), "utf8"),
);
const proxy = getAddress(deployments.PackBatcher.proxy);

async function implOf(addr: `0x${string}`) {
  const v = await publicClient.getStorageAt({
    address: addr,
    slot: ERC1967_IMPL_SLOT,
  });
  return getAddress(`0x${v!.slice(26)}`);
}

// Runtime code with immutables zeroed (UUPS `__self` differs per deployment) and the CBOR
// metadata tail dropped, so two deployments of the same source compare equal.
function normalizeCode(
  code: string,
  immutableRefs: Record<string, { start: number; length: number }[]>,
) {
  const hex = code.replace(/^0x/, "").toLowerCase().split("");
  for (const refs of Object.values(immutableRefs)) {
    for (const r of refs) {
      for (let i = r.start * 2; i < (r.start + r.length) * 2; i++) hex[i] = "0";
    }
  }
  const s = hex.join("");
  const metaLen = parseInt(s.slice(-4), 16);
  return s.slice(0, s.length - (metaLen + 2) * 2);
}

const oldImpl = await implOf(proxy);
if (
  oldImpl.toLowerCase() !==
  String(deployments.PackBatcher.implementation).toLowerCase()
) {
  console.warn(
    `WARN PackBatcher: live impl ${oldImpl} differs from deployments/base.json ` +
      `(${deployments.PackBatcher.implementation}). Using live.`,
  );
}

console.log(`Chain ${chainId} (${isFork ? "fork" : "LIVE"})`);
console.log(`PackBatcher proxy ${proxy}  impl ${oldImpl}`);

console.log("\n[1/3] Resolving new implementation...");
let newImpl: `0x${string}`;
if (process.env.DEPLOY_NEW_IMPL === "1") {
  newImpl = (await viem.deployContract("PackBatcher")).address;
  console.log(`  Deployed fresh impl: ${newImpl}`);
} else {
  newImpl = getAddress(process.env.PACK_BATCHER_NEW_IMPL ?? STAGING_IMPL);
  console.log(`  Reusing impl: ${newImpl}`);
}
if (newImpl.toLowerCase() === oldImpl.toLowerCase()) {
  console.error("New impl equals the live impl; nothing to upgrade.");
  process.exit(1);
}

const artifact = JSON.parse(
  await readFile(
    join(rootDir, "artifacts/contracts/PackBatcher.sol/PackBatcher.json"),
    "utf8",
  ),
);
const onChainCode = await publicClient.getCode({ address: newImpl });
if (
  !onChainCode ||
  normalizeCode(onChainCode, artifact.immutableReferences ?? {}) !==
    normalizeCode(artifact.deployedBytecode, artifact.immutableReferences ?? {})
) {
  console.error(
    `Code at ${newImpl} does not match the compiled PackBatcher. ` +
      "Run `pnpm compile` on this branch, or set DEPLOY_NEW_IMPL=1 to deploy a fresh impl.",
  );
  process.exit(1);
}
console.log(
  "  Bytecode matches compiled PackBatcher (immutables/metadata ignored)",
);

const txs = [
  {
    to: proxy,
    data: encodeFunctionData({
      abi: upgradeAbi,
      functionName: "upgradeToAndCall",
      args: [newImpl, "0x"],
    }),
  },
];

const outPath =
  process.env.UPGRADE_OUT ??
  join(
    rootDir,
    "scripts/ops/safe",
    "upgrade-pack-batcher-open-with-codes-base.json",
  );

console.log("\n[2/3] Writing Safe Transaction Builder batch...");
await writeFile(
  outPath,
  JSON.stringify(
    {
      version: "1.0",
      chainId: "8453",
      createdAt: Date.now(),
      meta: {
        name: "Upgrade PackBatcher (add openPacksWithCodes)",
        description: `PackBatcher ${proxy}: ${oldImpl} -> ${newImpl}. Same implementation the staging batcher runs. Fixes empty-data reverts on battle opens and Stripe qty>1 opens.`,
        txBuilderVersion: "1.16.5",
        createdFromSafeAddress: SAFE,
        createdFromOwnerAddress: "",
      },
      transactions: txs.map((t) => ({
        to: t.to,
        value: "0",
        data: t.data,
        contractMethod: null,
        contractInputsValues: null,
      })),
    },
    null,
    2,
  ) + "\n",
);
console.log(`  ${outPath}`);

if (!isFork) {
  console.log("\n[3/3] Live run: nothing upgraded. Next:");
  console.log(
    "  1. Import the JSON in app.safe.global > Transaction Builder, simulate, sign (2 of 3).",
  );
  console.log(
    "  2. Re-run with --network forkBase to rehearse the same batch.",
  );
  console.log(
    "  3. After execution, record the upgrade in deployments/base.json PackBatcher.",
  );
  process.exit(0);
}

console.log("\n[3/3] Fork rehearsal: executing the batch as the Safe...");
const testClient = await viem.getTestClient();
await testClient.impersonateAccount({ address: SAFE });
await testClient.setBalance({ address: SAFE, value: parseEther("1") });
const [deployer] = await viem.getWalletClients();

const batcher = await viem.getContractAt("PackBatcher", proxy);

// Name of the custom error a call reverts with; "" for an empty-data revert, null if no revert.
async function revertName(call: () => Promise<unknown>) {
  try {
    await call();
    return null;
  } catch (e) {
    const reverted = (e as BaseError).walk(
      (x) => x instanceof ContractFunctionRevertedError,
    ) as ContractFunctionRevertedError | null;
    return reverted?.data?.errorName ?? "";
  }
}
const withCodesMismatch = () =>
  batcher.simulate.openPacksWithCodes(
    [zeroAddress, zeroAddress, 0n, ["0x"], [], 0n],
    { account: SAFE },
  );
const legacyEmpty = () =>
  batcher.simulate.openPacks(
    [zeroAddress, zeroAddress, 0n, [], `0x${"0".repeat(64)}`, 0n],
    { account: SAFE },
  );

const before = {
  factory: await batcher.read.factory(),
  paused: await batcher.read.paused(),
  pm: await batcher.read.getPermissionManager(),
  withCodes: await revertName(withCodesMismatch),
};
console.log(
  `  Before: openPacksWithCodes reverts with ${before.withCodes === "" ? "empty data (the bug)" : before.withCodes}`,
);

for (const t of txs) {
  const hash = await deployer.sendTransaction({
    account: SAFE,
    to: t.to,
    data: t.data,
  });
  const r = await publicClient.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`Batch tx to ${t.to} reverted`);
}

const checks: [string, boolean][] = [
  [
    "impl swapped",
    (await implOf(proxy)).toLowerCase() === newImpl.toLowerCase(),
  ],
  ["factory kept", (await batcher.read.factory()) === before.factory],
  ["paused kept", (await batcher.read.paused()) === before.paused],
  [
    "permission manager kept",
    (await batcher.read.getPermissionManager()) === before.pm,
  ],
  [
    "openPacksWithCodes dispatches (CodeIdsLengthMismatch)",
    (await revertName(withCodesMismatch)) ===
      "PackBatcher__CodeIdsLengthMismatch",
  ],
  [
    "legacy openPacks still dispatches (InvalidBatchSize)",
    (await revertName(legacyEmpty)) === "PackBatcher__InvalidBatchSize",
  ],
];

let failed = false;
for (const [label, ok] of checks) {
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${label}`);
  if (!ok) failed = true;
}
if (failed) {
  console.error("\nFork rehearsal FAILED. Do not sign the Safe batch.");
  process.exit(1);
}
console.log("\nFork rehearsal passed.");
