/**
 * set-pack-machine-implementation.ts
 *
 * Deploys a new PackMachine logic contract and updates the clone target stored on
 * PackMachineFactory so that future createPackMachine() clones use the new logic.
 *
 * IMPORTANT: EIP-1167 clones are immutable — existing PackMachine instances are
 * NOT upgraded. Only clones created after this script runs will use the new logic.
 *
 * What it does:
 *   [1/3] Deploy new PackMachine implementation contract
 *   [2/3] Call PackMachineFactory.setImplementation(newImpl)  [DEFAULT_ADMIN_ROLE]
 *   [3/3] Verify via ImplementationUpdated event + persist deployment record
 *
 * Usage
 * -----
 *   # Dry-run on a local fork (no prompt, no JSON write):
 *   npx hardhat run scripts/set-pack-machine-implementation.ts --network forkBase
 *
 *   # Live execution (interactive confirmation required):
 *   npx hardhat run scripts/set-pack-machine-implementation.ts --network base
 *
 * Optional env vars:
 *   NEW_PACK_MACHINE_IMPL       — skip deploy; use this already-deployed address instead
 *   TRUSTED_FORWARDER           — forwarder baked into the impl at construction (default 0x00…00)
 *   PACK_MACHINE_FACTORY_PROXY  — override PackMachineFactory proxy address
 *   PERMISSION_MANAGER_PROXY    — override PermissionManager proxy address
 *   DEPLOY_STEP_DELAY_MS        — ms to wait between transactions (default 3000)
 */

import { network } from "hardhat";
import { getAddress, parseEventLogs } from "viem";
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
const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

// ─── ERC-2771 trusted forwarder baked into implementation bytecode ────────────
const TRUSTED_FORWARDER = (process.env.TRUSTED_FORWARDER ??
  "0x0000000000000000000000000000000000000000") as `0x${string}`;

// ─── Confirmation prompt ──────────────────────────────────────────────────────
async function confirmSetImpl(
  networkName: string,
  chainId: number,
  deployer: string,
  factoryProxy: string,
  oldImplFromJson: string | undefined,
  newImpl: string,
  trustedForwarder: string,
  skippedDeploy: boolean,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== Set PackMachine Implementation Summary ===");
  console.log(`Network:              ${networkName}`);
  console.log(`Chain ID:             ${chainId}`);
  console.log(`Deployer:             ${deployer}`);
  console.log(`PackMachineFactory:   ${factoryProxy}`);
  console.log(
    `Previous Impl (json): ${oldImplFromJson ?? "(unknown — no deployments entry)"}`,
  );
  console.log(`New Impl:             ${newImpl}`);
  console.log(`Trusted Forwarder:    ${trustedForwarder}`);
  if (skippedDeploy)
    console.log(`  (re-using pre-deployed impl — no new contract deployed)`);
  console.log("==============================================");
  console.log();
  console.log(
    "⚠️  Existing PackMachine clones are NOT affected — only new clones will use the new logic.",
  );
  console.log();
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

// ─── Resolve PackMachineFactory proxy ────────────────────────────────────────
let factoryProxy: `0x${string}`;
if (process.env.PACK_MACHINE_FACTORY_PROXY) {
  factoryProxy = getAddress(
    process.env.PACK_MACHINE_FACTORY_PROXY,
  ) as `0x${string}`;
} else {
  const entry = deployments["PackMachineFactory"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "PackMachineFactory proxy not found in deployments JSON. " +
        "Set PACK_MACHINE_FACTORY_PROXY env var or ensure deployments/" +
        networkName +
        ".json is populated.",
    );
    process.exit(1);
  }
  factoryProxy = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── Resolve PermissionManager proxy ─────────────────────────────────────────
let permissionManagerProxy: `0x${string}`;
if (process.env.PERMISSION_MANAGER_PROXY) {
  permissionManagerProxy = getAddress(
    process.env.PERMISSION_MANAGER_PROXY,
  ) as `0x${string}`;
} else {
  const factory = await viem.getContractAt("PackMachineFactory", factoryProxy);
  try {
    permissionManagerProxy =
      (await factory.read.getPermissionManager()) as `0x${string}`;
  } catch {
    const pmEntry = deployments["PermissionManager"] as
      | Record<string, unknown>
      | undefined;
    if (!pmEntry?.proxy) {
      console.error(
        "PermissionManager proxy not found. Set PERMISSION_MANAGER_PROXY env var.",
      );
      process.exit(1);
    }
    permissionManagerProxy = getAddress(
      pmEntry.proxy as string,
    ) as `0x${string}`;
  }
}

// ─── Resolve prior impl address from JSON (for history record + display) ──────
const implEntry = deployments["PackMachineImplementation"] as
  | Record<string, unknown>
  | undefined;
const oldImplFromJson = implEntry?.implementation as string | undefined;

// Override trusted forwarder with recorded value if not set via env
const resolvedForwarder =
  process.env.TRUSTED_FORWARDER ??
  (implEntry?.trustedForwarder as string | undefined) ??
  TRUSTED_FORWARDER;

// ─── Skip-deploy shortcut (NEW_PACK_MACHINE_IMPL env override) ────────────────
const skipDeploy = !!process.env.NEW_PACK_MACHINE_IMPL;
let newImplAddress: `0x${string}`;
// Library addresses are only populated when we deploy — not needed for skipDeploy.
let newPackPoolLibAddress: `0x${string}` | undefined;
let newPackFulfillLibAddress: `0x${string}` | undefined;

if (skipDeploy) {
  newImplAddress = getAddress(
    process.env.NEW_PACK_MACHINE_IMPL!,
  ) as `0x${string}`;
  console.log(
    `\nUsing pre-deployed PackMachine implementation at ${newImplAddress} (skipping deploy).`,
  );
} else {
  newImplAddress = "0x0000000000000000000000000000000000000000"; // placeholder — set in step 1
}

// ─── Role pre-flight ──────────────────────────────────────────────────────────
try {
  const pm = await viem.getContractAt(
    "PermissionManager",
    permissionManagerProxy,
  );
  const hasAdmin = await pm.read.hasProtocolRole([
    DEFAULT_ADMIN_ROLE,
    deployerAddress,
  ]);
  if (!hasAdmin) {
    console.error(
      `✗ Account ${deployerAddress} does not have DEFAULT_ADMIN_ROLE on PermissionManager ${permissionManagerProxy}`,
    );
    console.error(
      "  factory.setImplementation() will revert — aborting to avoid wasted gas.",
    );
    process.exit(1);
  }
  console.log(`✓ DEFAULT_ADMIN_ROLE verified for ${deployerAddress}`);
} catch (err) {
  console.warn(
    "⚠️  Could not verify DEFAULT_ADMIN_ROLE — proceeding, but setImplementation() may fail.",
  );
  console.warn("  Error:", err);
}

// ─── [1/3] Deploy new PackMachine implementation ─────────────────────────────
// PackMachine has two public linked libraries that must be deployed first:
//   PackPoolLib (no deps) → PackFulfillLib (links PackPoolLib) → PackMachine (links both)
// Under the EIP-1167 clone pattern every clone DELEGATECALLs into this implementation,
// so the libraries MUST be correctly linked here.
console.log("\n[1/3] Deploy new PackMachine implementation...");
if (skipDeploy) {
  console.log(`  ↻ skipping deploy — using ${newImplAddress}`);
} else {
  console.log(`  Trusted forwarder: ${resolvedForwarder}`);

  // ── PackPoolLib ─────────────────────────────────────────────────────────────
  const packPoolLib = await viem.deployContract("PackPoolLib");
  newPackPoolLibAddress = packPoolLib.address;
  console.log(`  PackPoolLib: ${newPackPoolLibAddress}`);
  await waitForCode(publicClient, newPackPoolLibAddress);

  // ── PackFulfillLib (links PackPoolLib) ──────────────────────────────────────
  const packFulfillLib = await viem.deployContract("PackFulfillLib", [], {
    libraries: {
      "project/contracts/lib/PackPoolLib.sol:PackPoolLib":
        newPackPoolLibAddress,
    },
  });
  newPackFulfillLibAddress = packFulfillLib.address;
  console.log(`  PackFulfillLib: ${newPackFulfillLibAddress}`);
  await waitForCode(publicClient, newPackFulfillLibAddress);

  // ── PackMachine implementation (linked to both) ─────────────────────────────
  const implContract = await viem.deployContract(
    "PackMachine",
    [resolvedForwarder as `0x${string}`],
    {
      libraries: {
        "project/contracts/lib/PackPoolLib.sol:PackPoolLib":
          newPackPoolLibAddress,
        "project/contracts/lib/PackFulfillLib.sol:PackFulfillLib":
          newPackFulfillLibAddress,
      },
    },
  );
  newImplAddress = implContract.address;
  console.log(`  New implementation: ${newImplAddress}`);
  await waitForCode(publicClient, newImplAddress);
  console.log(`  ✓ bytecode confirmed`);
}
await sleep(STEP_DELAY_MS);

// ─── Confirmation on live networks ───────────────────────────────────────────
if (isLive) {
  const ok = await confirmSetImpl(
    networkName,
    chainId,
    deployerAddress,
    factoryProxy,
    oldImplFromJson,
    newImplAddress,
    resolvedForwarder,
    skipDeploy,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── [2/3] Call factory.setImplementation ────────────────────────────────────
console.log("[2/3] Calling PackMachineFactory.setImplementation...");
const factory = await viem.getContractAt("PackMachineFactory", factoryProxy);

const txHash = await factory.write.setImplementation([newImplAddress], {
  account: deployerClient.account,
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(
  `  tx: ${txHash} (block ${receipt.blockNumber}, status: ${receipt.status})`,
);
await sleep(STEP_DELAY_MS);

// ─── [3/3] Verify via ImplementationUpdated event ────────────────────────────
console.log("[3/3] Verifying via ImplementationUpdated event...");
const logs = parseEventLogs({
  abi: factory.abi,
  eventName: "ImplementationUpdated",
  logs: receipt.logs,
});

if (logs.length === 0) {
  console.error(
    "✗ No ImplementationUpdated event found in receipt — unexpected!",
  );
  process.exit(1);
}

const { oldImpl, newImpl } = logs[0].args as {
  oldImpl: `0x${string}`;
  newImpl: `0x${string}`;
};

if (newImpl.toLowerCase() !== newImplAddress.toLowerCase()) {
  console.error(
    `✗ Event newImpl mismatch — expected ${newImplAddress}, got ${newImpl}`,
  );
  process.exit(1);
}
console.log(`  ✓ ImplementationUpdated: ${oldImpl} → ${newImpl}`);

// ─── Summary ──────────────────────────────────────────────────────────────────
console.log("\n=== Set PackMachine Implementation Complete ===");
console.log(`Network:       ${networkName} (chainId: ${chainId})`);
console.log(`Factory:       ${factoryProxy}`);
console.log(`Old Impl:      ${oldImpl}`);
if (newPackPoolLibAddress) {
  console.log(`PackPoolLib:   ${newPackPoolLibAddress}`);
}
if (newPackFulfillLibAddress) {
  console.log(`PackFulfillLib: ${newPackFulfillLibAddress}`);
}
console.log(`New Impl:      ${newImplAddress}`);
console.log("==============================================");

// ─── Persist deployment records ───────────────────────────────────────────────
if (isLive) {
  // Update PackMachineImplementation top-level entry
  await saveDeployment(networkName, "PackMachineImplementation", {
    ...(implEntry ?? {}),
    implementation: newImplAddress,
    ...(newPackPoolLibAddress ? { packPoolLib: newPackPoolLibAddress } : {}),
    ...(newPackFulfillLibAddress
      ? { packFulfillLib: newPackFulfillLibAddress }
      : {}),
    trustedForwarder: resolvedForwarder,
    deployedAt: new Date().toISOString(),
  });

  // Merge packMachineImplementation + append history into PackMachineFactory entry
  const factoryEntry =
    (deployments["PackMachineFactory"] as
      | Record<string, unknown>
      | undefined) ?? {};
  const implHistory = (
    (factoryEntry.implementationHistory as unknown[]) ?? []
  ).concat({
    previousImplementation: oldImpl,
    newImplementation: newImplAddress,
    changedAt: new Date().toISOString(),
    txHash,
  });

  await saveDeployment(networkName, "PackMachineFactory", {
    ...factoryEntry,
    packMachineImplementation: newImplAddress,
    implementationHistory: implHistory,
  });

  console.log(
    `\nDeployment records updated at deployments/${networkName}.json`,
  );
}

console.log("\n⚠️  Reminder: existing PackMachine clones are NOT upgraded.");
console.log(
  "   Only new clones created via PackMachineFactory.createPackMachine()",
);
console.log("   will use the new implementation.");
console.log("\nNext steps:");
console.log(
  "  • Create a new clone to validate the new logic:  scripts/create-pack-machine.ts",
);
