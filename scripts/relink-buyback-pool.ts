/**
 * relink-buyback-pool.ts
 *
 * Deploys a FRESH BuybackPool (new impl + new ERC-1967 proxy) and relinks every
 * existing PackMachine clone to it.  Use this instead of the upgrade script when
 * the ERC-7201 storage slot has changed and in-place upgrade would corrupt state.
 *
 * What it does (idempotent / resume-safe):
 *   [1/4] Deploy new BuybackPool implementation + proxy
 *   [2/4] Repoint PackMachineFactory → new pool  (setBuybackPool)
 *   [3/4] Per clone: register on new pool        (registerPackMachine)
 *                    repoint clone → new pool     (setBuybackPool)
 *   [4/4] Verify all wiring
 *
 * Usage
 * -----
 *   # Dry-run on a local fork (no prompt, no JSON write):
 *   npx hardhat run scripts/relink-buyback-pool.ts --network forkBase
 *
 *   # Live deployment (interactive confirmation):
 *   npx hardhat run scripts/relink-buyback-pool.ts --network base
 *
 * Optional env vars:
 *   PACK_MACHINE_FACTORY  — override PackMachineFactory proxy address
 *   PERMISSION_MANAGER    — override PermissionManager proxy address
 *   ASSET_NFT             — override AssetNFT proxy address
 *   PAYMENT_TOKEN         — override payment token address (e.g. USDC)
 *   FINANCE_WALLET        — override finance wallet address
 *   BUYBACK_POOL          — skip deploy step; use this existing pool address instead
 *   CLONES                — comma-separated list of clone addresses to relink
 *                           (default: read from deployments/PackMachines[])
 *   DEPLOY_STEP_DELAY_MS  — ms to wait between transactions (default 3000)
 */

import { network } from "hardhat";
import { encodeFunctionData, getAddress, keccak256, toHex } from "viem";
import { createInterface } from "node:readline/promises";
import {
  readDeployments,
  saveDeployment,
  waitForCode,
} from "./lib/deployments.js";
import { sleep } from "./lib/sleep.js";

// ─── Rate-limit guard ─────────────────────────────────────────────────────────
const STEP_DELAY_MS = Number(process.env.DEPLOY_STEP_DELAY_MS ?? "3000");

// ─── Role constants (must match contracts/lib/Roles.sol) ─────────────────────
const PACK_OPERATOR_ROLE = keccak256(toHex("PACK_OPERATOR_ROLE"));
const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

// ─── Confirmation prompt ──────────────────────────────────────────────────────
async function confirmDeploy(
  networkName: string,
  chainId: number,
  deployer: string,
  factoryProxy: string,
  clones: string[],
  skipDeploy: boolean,
  preDeployedPool: string | undefined,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== BuybackPool Relink Summary ===");
  console.log(`Network:             ${networkName}`);
  console.log(`Chain ID:            ${chainId}`);
  console.log(`Deployer:            ${deployer}`);
  console.log(`PackMachineFactory:  ${factoryProxy}`);
  if (skipDeploy && preDeployedPool) {
    console.log(`Using existing pool: ${preDeployedPool} (no deploy)`);
  } else {
    console.log(`Action:              deploy fresh BuybackPool proxy + impl`);
  }
  console.log(`Clones to relink:    ${clones.length}`);
  for (const c of clones) console.log(`  - ${c}`);
  console.log("==================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  return answer.toLowerCase() === "yes";
}

// ─── Network setup ────────────────────────────────────────────────────────────
const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [deployerClient] = await viem.getWalletClients();
const deployerAddress = deployerClient.account.address;
const chainId = await publicClient.getChainId();

const isLive = connection.networkConfig.type === "http";
const networkName = connection.networkName;

const deployments = await readDeployments(networkName);

// ─── Resolve PackMachineFactory ───────────────────────────────────────────────
let factoryProxy: `0x${string}`;
if (process.env.PACK_MACHINE_FACTORY) {
  factoryProxy = getAddress(process.env.PACK_MACHINE_FACTORY) as `0x${string}`;
} else {
  const entry = deployments["PackMachineFactory"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "PackMachineFactory proxy not found. Set PACK_MACHINE_FACTORY env var or check deployments JSON.",
    );
    process.exit(1);
  }
  factoryProxy = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── Resolve initialize() args from deployments JSON ─────────────────────────
const buybackEntry = deployments["BuybackPool"] as
  | Record<string, unknown>
  | undefined;

function resolveAddr(
  envKey: string,
  deployKey: string,
  label: string,
): `0x${string}` {
  if (process.env[envKey]) return getAddress(process.env[envKey]!) as `0x${string}`;
  const raw =
    (deployments[deployKey] as Record<string, unknown> | undefined)?.proxy ??
    buybackEntry?.[deployKey.toLowerCase()];
  if (typeof raw !== "string" || !raw.startsWith("0x")) {
    console.error(
      `${label} not found. Set ${envKey} env var or ensure deployments/${networkName}.json is populated.`,
    );
    process.exit(1);
  }
  return getAddress(raw) as `0x${string}`;
}

const permissionManagerProxy = resolveAddr(
  "PERMISSION_MANAGER",
  "PermissionManager",
  "PermissionManager",
);
const assetNFTProxy = resolveAddr("ASSET_NFT", "AssetNFT", "AssetNFT");

// paymentToken and financeWallet are plain addresses (not proxied top-level keys)
// Accept either an env override or the value stored in the BuybackPool deployment record.
function resolveAddrFromBuybackOrEnv(
  envKey: string,
  field: string,
  label: string,
): `0x${string}` {
  if (process.env[envKey]) return getAddress(process.env[envKey]!) as `0x${string}`;
  const raw = buybackEntry?.[field];
  if (typeof raw !== "string" || !raw.startsWith("0x")) {
    console.error(
      `${label} not found. Set ${envKey} env var or ensure ${networkName}.json has a BuybackPool entry with the '${field}' field.`,
    );
    process.exit(1);
  }
  return getAddress(raw) as `0x${string}`;
}
const paymentToken = resolveAddrFromBuybackOrEnv(
  "PAYMENT_TOKEN",
  "paymentToken",
  "paymentToken",
);
const financeWallet = resolveAddrFromBuybackOrEnv(
  "FINANCE_WALLET",
  "financeWallet",
  "financeWallet",
);

// ─── Resolve clone list ───────────────────────────────────────────────────────
let clones: `0x${string}`[];
if (process.env.CLONES) {
  clones = process.env.CLONES.split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => getAddress(s) as `0x${string}`);
} else {
  const machines = (deployments["PackMachines"] as unknown[] | undefined) ?? [];
  clones = machines
    .map((m) => {
      const rec = m as Record<string, unknown>;
      return typeof rec.address === "string" && rec.address.startsWith("0x")
        ? (getAddress(rec.address) as `0x${string}`)
        : null;
    })
    .filter((a): a is `0x${string}` => a !== null);
}
if (clones.length === 0) {
  console.warn(
    "⚠️  No PackMachine clones found. Set CLONES env var or add entries to PackMachines[] in the deployments JSON.",
  );
}

// ─── Skip-deploy shortcut (BUYBACK_POOL env override) ────────────────────────
const skipDeploy = !!process.env.BUYBACK_POOL;
let newPoolAddress: `0x${string}` | undefined;
if (skipDeploy) {
  newPoolAddress = getAddress(process.env.BUYBACK_POOL!) as `0x${string}`;
  console.log(`\nUsing pre-deployed BuybackPool at ${newPoolAddress} (skipping deploy).`);
}

// ─── Role pre-flight ──────────────────────────────────────────────────────────
try {
  const pm = await viem.getContractAt("PermissionManager", permissionManagerProxy);
  const [hasOperator, hasAdmin] = await Promise.all([
    pm.read.hasProtocolRole([PACK_OPERATOR_ROLE, deployerAddress]),
    pm.read.hasProtocolRole([DEFAULT_ADMIN_ROLE, deployerAddress]),
  ]);
  if (!hasOperator)
    console.warn(
      `⚠️  ${deployerAddress} does not have PACK_OPERATOR_ROLE — registerPackMachine and clone.setBuybackPool will revert.`,
    );
  if (!hasAdmin)
    console.warn(
      `⚠️  ${deployerAddress} does not have DEFAULT_ADMIN_ROLE — factory.setBuybackPool will revert.`,
    );
} catch {
  console.warn(
    "⚠️  Could not verify roles — proceeding, but transactions may fail.",
  );
}

// ─── Confirmation on live networks ───────────────────────────────────────────
if (isLive) {
  const ok = await confirmDeploy(
    networkName,
    chainId,
    deployerAddress,
    factoryProxy,
    clones,
    skipDeploy,
    newPoolAddress,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── [1/4] Deploy fresh BuybackPool ──────────────────────────────────────────
console.log("\n[1/4] Deploy fresh BuybackPool...");
if (skipDeploy) {
  console.log(`  ↻ skipping deploy — using ${newPoolAddress}`);
} else {
  // Deploy implementation
  console.log("  Deploying BuybackPool implementation...");
  const implContract = await viem.deployContract("BuybackPool");
  const implAddress = implContract.address;
  console.log(`  Implementation: ${implAddress}`);
  await waitForCode(publicClient, implAddress);

  // Encode initialize calldata
  const buybackInitData = encodeFunctionData({
    abi: implContract.abi,
    functionName: "initialize",
    args: [
      permissionManagerProxy,
      assetNFTProxy,
      paymentToken,
      financeWallet,
      factoryProxy,
    ],
  });

  // Deploy proxy
  console.log("  Deploying ERC-1967 proxy...");
  const proxyContract = await viem.deployContract("ERC1967ProxyHelper", [
    implAddress,
    buybackInitData,
  ]);
  newPoolAddress = proxyContract.address;
  console.log(`  Proxy:          ${newPoolAddress}`);
  await waitForCode(publicClient, newPoolAddress);

  if (isLive) {
    await saveDeployment(networkName, "BuybackPool", {
      proxy: newPoolAddress,
      implementation: implAddress,
      permissionManager: permissionManagerProxy,
      assetNFT: assetNFTProxy,
      paymentToken,
      financeWallet,
      factory: factoryProxy,
      defaultBuybackBps: 8000,
      deployedAt: new Date().toISOString(),
    });
    console.log("  ✓ checkpoint saved to deployments JSON");
  }
}
await sleep(STEP_DELAY_MS);

const newPool = await viem.getContractAt("BuybackPool", newPoolAddress!);

// ─── [2/4] Repoint factory → new pool ────────────────────────────────────────
console.log("[2/4] Repoint PackMachineFactory → new pool...");
const factory = await viem.getContractAt("PackMachineFactory", factoryProxy);
const currentFactoryPool = await factory.read.buybackPool();
if (currentFactoryPool.toLowerCase() === newPoolAddress!.toLowerCase()) {
  console.log("  ↻ skipping setBuybackPool (factory already wired)");
} else {
  const txHash = await factory.write.setBuybackPool([newPoolAddress!]);
  await publicClient.waitForTransactionReceipt({ hash: txHash });
  console.log(`  factory.setBuybackPool(${newPoolAddress}) ✓`);
}
await sleep(STEP_DELAY_MS);

// ─── [3/4] Relink each existing clone ────────────────────────────────────────
console.log(`[3/4] Relinking ${clones.length} clone(s)...`);
for (const cloneAddr of clones) {
  console.log(`\n  Clone: ${cloneAddr}`);
  const clone = await viem.getContractAt("PackMachine", cloneAddr);

  // Register clone on new pool
  const isRegistered = await newPool.read.isRegisteredPackMachine([cloneAddr]);
  if (isRegistered) {
    console.log("    ↻ skipping registerPackMachine (already registered)");
  } else {
    const tx1 = await newPool.write.registerPackMachine([cloneAddr, true]);
    await publicClient.waitForTransactionReceipt({ hash: tx1 });
    console.log(`    registerPackMachine(${cloneAddr}, true) ✓`);
    await sleep(STEP_DELAY_MS);
  }

  // Repoint clone → new pool
  const machineInfo = await clone.read.getMachineInfo();
  const currentPool = machineInfo.buybackPool;
  if (currentPool.toLowerCase() === newPoolAddress!.toLowerCase()) {
    console.log("    ↻ skipping setBuybackPool on clone (already wired)");
  } else {
    const tx2 = await clone.write.setBuybackPool([newPoolAddress!]);
    await publicClient.waitForTransactionReceipt({ hash: tx2 });
    console.log(`    clone.setBuybackPool(${newPoolAddress}) ✓`);
    await sleep(STEP_DELAY_MS);
  }
}

// ─── [4/4] Verify ─────────────────────────────────────────────────────────────
console.log("\n[4/4] Verifying wiring...");
let allOk = true;

const verifiedDefaultBps = await newPool.read.getDefaultBuybackBps();
const verifiedPm = await newPool.read.getPermissionManager();
const verifiedFactoryPool = await factory.read.buybackPool();

console.log(`  Pool.getDefaultBuybackBps():  ${verifiedDefaultBps} bps`);
if (Number(verifiedDefaultBps) !== 8000) {
  console.error(`  ✗ Expected 8000, got ${verifiedDefaultBps}`);
  allOk = false;
} else {
  console.log("  ✓ defaultBuybackBps = 8000");
}

console.log(`  Pool.getPermissionManager():  ${verifiedPm}`);
if (verifiedPm.toLowerCase() !== permissionManagerProxy.toLowerCase()) {
  console.error(`  ✗ Expected ${permissionManagerProxy}`);
  allOk = false;
} else {
  console.log("  ✓ permissionManager matches");
}

if (verifiedFactoryPool.toLowerCase() !== newPoolAddress!.toLowerCase()) {
  console.error(
    `  ✗ Factory.buybackPool() = ${verifiedFactoryPool}, expected ${newPoolAddress}`,
  );
  allOk = false;
} else {
  console.log(`  ✓ factory.buybackPool() = ${newPoolAddress}`);
}

for (const cloneAddr of clones) {
  const clone = await viem.getContractAt("PackMachine", cloneAddr);
  const [info, isReg] = await Promise.all([
    clone.read.getMachineInfo(),
    newPool.read.isRegisteredPackMachine([cloneAddr]),
  ]);
  const clonePoolOk =
    info.buybackPool.toLowerCase() === newPoolAddress!.toLowerCase();
  const regOk = isReg === true;
  if (!clonePoolOk) {
    console.error(
      `  ✗ Clone ${cloneAddr}: getMachineInfo().buybackPool = ${info.buybackPool} (expected ${newPoolAddress})`,
    );
    allOk = false;
  } else {
    console.log(`  ✓ Clone ${cloneAddr}: buybackPool wired`);
  }
  if (!regOk) {
    console.error(
      `  ✗ Clone ${cloneAddr}: isRegisteredPackMachine() = false`,
    );
    allOk = false;
  } else {
    console.log(`  ✓ Clone ${cloneAddr}: registered on new pool`);
  }
}

// ─── Summary ──────────────────────────────────────────────────────────────────
console.log("\n=== BuybackPool Relink Complete ===");
console.log(`Network:       ${networkName} (chainId: ${chainId})`);
console.log(`New Pool:      ${newPoolAddress}`);
console.log(`Factory:       ${factoryProxy}`);
console.log(`Clones wired:  ${clones.length}`);
if (!allOk) {
  console.error("\n⚠️  One or more verification checks FAILED — review above.");
  process.exit(1);
}
console.log("\n✅  All verification checks passed.");
console.log("\nNext steps:");
console.log(
  "  • Fund the new pool:   BuybackPool.depositFunds(amount)  [PACK_OPERATOR_ROLE]",
);
console.log(
  "  • Old pool:            Consider pausing and calling emergencyWithdraw to recover USDC.",
);
console.log(
  "  • Won tokens:          Tokens won under the old pool are not yet registered on the new pool;",
);
console.log(
  "                         new wins going forward will self-register via fulfillRandomness.",
);
