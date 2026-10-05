/**
 * propose-safe-upgrade-promo-buyback.ts
 *
 * UPGRADER_ROLE is held by the Safe multisig, not an EOA, so the upgrade cannot be
 * sent directly. This script:
 *   1. deploys a new PromoCodeRegistry implementation and a new BuybackPool implementation
 *      (any funded EOA; the implementations hold no authority),
 *   2. writes a Safe Transaction Builder batch: registry upgradeToAndCall first, then
 *      BuybackPool upgradeToAndCall (the pool's new redeemBuyback call needs the new registry),
 *   3. on a fork, impersonates the Safe, runs the batch and checks the result.
 *
 * Usage
 * -----
 * # Rehearse on a Base fork (nothing is broadcast):
 * npx hardhat run scripts/upgrade/propose-safe-upgrade-promo-buyback.ts --network forkBase
 *
 * # Mainnet: deploys the two implementations from BASE_PRIVATE_KEY, writes the Safe JSON.
 * # It does NOT upgrade anything. Import the JSON in app.safe.global > Transaction Builder.
 * npx hardhat run scripts/upgrade/propose-safe-upgrade-promo-buyback.ts --network base
 *
 * Optional env vars:
 *   UPGRADE_OUT   output path for the Safe JSON
 */

import { network } from "hardhat";
import { encodeFunctionData, getAddress, parseEther } from "viem";
import { readFile, writeFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const SAFE = getAddress("0xfe78E8aa8f4B9f616e05a94604aB86A7B192f456");
const ERC1967_IMPL_SLOT =
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc" as const;
const ZERO_BYTES32 = `0x${"0".repeat(64)}` as const;

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

const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../../deployments",
);
// Fork runs read prod addresses; the fork network has no JSON of its own.
const deployments = JSON.parse(
  await readFile(join(deploymentsDir, "base.json"), "utf8"),
);
const registryProxy = getAddress(deployments.PromoCodeRegistry.proxy);
const poolProxy = getAddress(deployments.BuybackPool.proxy);

async function implOf(proxy: `0x${string}`) {
  const v = await publicClient.getStorageAt({
    address: proxy,
    slot: ERC1967_IMPL_SLOT,
  });
  return getAddress(`0x${v!.slice(26)}`);
}

const oldRegistryImpl = await implOf(registryProxy);
const oldPoolImpl = await implOf(poolProxy);

// The chain is the source of truth for the "before" impl. deployments/base.json can lag
// (it did for the registry), so a mismatch is reported, not fatal.
for (const [name, live, recorded] of [
  ["PromoCodeRegistry", oldRegistryImpl, deployments.PromoCodeRegistry.implementation],
  ["BuybackPool", oldPoolImpl, deployments.BuybackPool.implementation],
] as const) {
  if (live.toLowerCase() !== String(recorded).toLowerCase()) {
    console.warn(
      `WARN ${name}: live impl ${live} differs from deployments/base.json (${recorded}). Using live.`,
    );
  }
}

console.log(`Chain ${chainId} (${isFork ? "fork" : "LIVE"})`);
console.log(`Registry proxy ${registryProxy}  impl ${oldRegistryImpl}`);
console.log(`Pool proxy     ${poolProxy}  impl ${oldPoolImpl}`);

console.log("\n[1/3] Deploying new implementations...");
const newRegistryImpl = await viem.deployContract("PromoCodeRegistry");
const newPoolImpl = await viem.deployContract("BuybackPool");
console.log(`  PromoCodeRegistry impl: ${newRegistryImpl.address}`);
console.log(`  BuybackPool impl:       ${newPoolImpl.address}`);

const txs = [
  {
    to: registryProxy,
    data: encodeFunctionData({
      abi: upgradeAbi,
      functionName: "upgradeToAndCall",
      args: [newRegistryImpl.address, "0x"],
    }),
  },
  {
    to: poolProxy,
    data: encodeFunctionData({
      abi: upgradeAbi,
      functionName: "upgradeToAndCall",
      args: [newPoolImpl.address, "0x"],
    }),
  },
];

const outPath =
  process.env.UPGRADE_OUT ??
  join(
    dirname(fileURLToPath(import.meta.url)),
    "../ops/safe",
    "upgrade-promo-registry-buyback-pool-pr20-base.json",
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
        name: "Upgrade PromoCodeRegistry then BuybackPool (PR #20, pack-bound buyback codes)",
        description: `1) registry ${registryProxy}: ${oldRegistryImpl} -> ${newRegistryImpl.address}. 2) pool ${poolProxy}: ${oldPoolImpl} -> ${newPoolImpl.address}. Order matters: the new pool calls the registry's 4-arg redeemBuyback.`,
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
  console.log("  1. Verify both implementations on Basescan.");
  console.log("  2. Import the JSON in app.safe.global > Transaction Builder, simulate, sign (2 of 3).");
  console.log("  3. Re-run with --network forkBase to rehearse the same batch.");
  process.exit(0);
}

console.log("\n[3/3] Fork rehearsal: executing the batch as the Safe...");
const testClient = await viem.getTestClient();
await testClient.impersonateAccount({ address: SAFE });
await testClient.setBalance({ address: SAFE, value: parseEther("1") });
const [deployer] = await viem.getWalletClients();

const registry = await viem.getContractAt("PromoCodeRegistry", registryProxy);
const pool = await viem.getContractAt("BuybackPool", poolProxy);

const before = {
  factory: await registry.read.packMachineFactory(),
  registryPool: await registry.read.buybackPool(),
  poolRegistry: await pool.read.getPromoCodeRegistry(),
  defaultBps: await pool.read.getDefaultBuybackBps(),
  poolBalance: await pool.read.poolBalance(),
};

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
  ["registry impl swapped", (await implOf(registryProxy)).toLowerCase() === newRegistryImpl.address.toLowerCase()],
  ["pool impl swapped", (await implOf(poolProxy)).toLowerCase() === newPoolImpl.address.toLowerCase()],
  ["registry packMachineFactory kept", (await registry.read.packMachineFactory()) === before.factory],
  ["registry buybackPool kept", (await registry.read.buybackPool()) === before.registryPool],
  ["pool promoCodeRegistry kept", (await pool.read.getPromoCodeRegistry()) === before.poolRegistry],
  ["pool defaultBuybackBps kept", (await pool.read.getDefaultBuybackBps()) === before.defaultBps],
  ["pool balance kept", (await pool.read.poolBalance()) === before.poolBalance],
];
// New surface exists and an unbound code reads as unbound.
const [, bound] = await registry.read.getBuybackBinding([ZERO_BYTES32]);
checks.push(["getBuybackBinding callable, unbound", bound === false]);
const [known] = await pool.read.getTokenPackId([0n]);
checks.push(["getTokenPackId callable, unknown for unregistered token", known === false]);

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
