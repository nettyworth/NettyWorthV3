import { network } from "hardhat";
import { getAddress, keccak256, toBytes } from "viem";
import { createInterface } from "node:readline/promises";
import { readDeployments, getDeploymentPath } from "./lib/deployments.js";
import { writeFile, rename, mkdir } from "node:fs/promises";

// ─── Role map — canonical names from contracts/lib/Roles.sol ─────────────────
const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

const ROLES: Record<string, `0x${string}`> = {
  DEFAULT_ADMIN_ROLE,
  MINTER_ROLE: keccak256(toBytes("MINTER_ROLE")),
  BURNER_ROLE: keccak256(toBytes("BURNER_ROLE")),
  STATE_MANAGER_ROLE: keccak256(toBytes("STATE_MANAGER_ROLE")),
  URI_SETTER_ROLE: keccak256(toBytes("URI_SETTER_ROLE")),
  PAUSER_ROLE: keccak256(toBytes("PAUSER_ROLE")),
  UPGRADER_ROLE: keccak256(toBytes("UPGRADER_ROLE")),
  BLACKLIST_ROLE: keccak256(toBytes("BLACKLIST_ROLE")),
  PACK_OPERATOR_ROLE: keccak256(toBytes("PACK_OPERATOR_ROLE")),
  BUYBACK_POOL_ROLE: keccak256(toBytes("BUYBACK_POOL_ROLE")),
  MARKETPLACE_ROLE: keccak256(toBytes("MARKETPLACE_ROLE")),
};

// ─── Ownable2Step contracts to transfer ──────────────────────────────────────
const OWNABLE_CONTRACTS: Array<{ key: string; contract: string }> = [
  { key: "AssetLendingPool", contract: "AssetLendingPool" },
  { key: "AssetLendingPoolConfig", contract: "AssetLendingPoolConfig" },
  { key: "P2PTradeEscrow", contract: "P2PTradeEscrow" },
];

// ─── Validate NEW_OWNER env var ───────────────────────────────────────────────
const rawNewOwner = process.env.NEW_OWNER;
if (!rawNewOwner) {
  console.error("Missing required env var: NEW_OWNER");
  console.error(
    "Usage: NEW_OWNER=0x<address> npx hardhat run scripts/transfer-ownership.ts --network <network>",
  );
  process.exit(1);
}
let newOwner: `0x${string}`;
try {
  newOwner = getAddress(rawNewOwner) as `0x${string}`;
} catch {
  console.error(`Invalid NEW_OWNER address: "${rawNewOwner}"`);
  process.exit(1);
}

// ─── Network connection ───────────────────────────────────────────────────────
const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [callerClient] = await viem.getWalletClients();
const callerAddress = callerClient.account.address;
const chainId = await publicClient.getChainId();
const isLive = connection.networkConfig.type === "http";

// ─── Load deployments ─────────────────────────────────────────────────────────
const deploymentData = await readDeployments(connection.networkName);

// ─── Resolve PermissionManager proxy ─────────────────────────────────────────
let pmProxy: `0x${string}`;
if (process.env.PERMISSION_MANAGER_PROXY) {
  pmProxy = getAddress(process.env.PERMISSION_MANAGER_PROXY) as `0x${string}`;
} else {
  const pmEntry = deploymentData["PermissionManager"] as
    | Record<string, unknown>
    | undefined;
  if (!pmEntry?.proxy) {
    console.error(
      "PermissionManager proxy address not found in deployment file.",
    );
    console.error(
      "Deploy first or set PERMISSION_MANAGER_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  pmProxy = getAddress(pmEntry.proxy as string) as `0x${string}`;
}

// ─── PermissionManager auth precheck ─────────────────────────────────────────
const pm = await viem.getContractAt("PermissionManager", pmProxy);

const callerHasAdmin = await pm.read.hasProtocolRole([
  DEFAULT_ADMIN_ROLE,
  callerAddress,
]);
if (!callerHasAdmin) {
  console.error(
    `Account ${callerAddress} does not have DEFAULT_ADMIN_ROLE on PermissionManager ${pmProxy}`,
  );
  console.error("Cannot proceed without DEFAULT_ADMIN_ROLE.");
  process.exit(1);
}

// ─── Pre-flight: determine what will be done ──────────────────────────────────
// Roles: which are not yet held by newOwner
const rolesToGrant: Array<{ name: string; hash: `0x${string}` }> = [];
const rolesAlreadyHeld: Array<{ name: string; hash: `0x${string}` }> = [];
for (const [name, hash] of Object.entries(ROLES)) {
  const alreadyHeld = await pm.read.hasProtocolRole([hash, newOwner]);
  if (alreadyHeld) {
    rolesAlreadyHeld.push({ name, hash });
  } else {
    rolesToGrant.push({ name, hash });
  }
}

// Ownable: which contracts exist and haven't set pendingOwner yet
type OwnableWork =
  | {
      status: "pending";
      key: string;
      contract: string;
      proxy: `0x${string}`;
      currentOwner: `0x${string}`;
    }
  | {
      status: "already_set";
      key: string;
      contract: string;
      proxy: `0x${string}`;
    }
  | {
      status: "caller_not_owner";
      key: string;
      contract: string;
      proxy: `0x${string}`;
      currentOwner: `0x${string}`;
    }
  | { status: "not_deployed"; key: string };

const ownableWork: OwnableWork[] = [];
for (const { key, contract } of OWNABLE_CONTRACTS) {
  const entry = deploymentData[key] as Record<string, unknown> | undefined;
  if (!entry?.proxy) {
    ownableWork.push({ status: "not_deployed", key });
    continue;
  }
  const proxy = getAddress(entry.proxy as string) as `0x${string}`;
  const c = await viem.getContractAt(contract, proxy);
  const currentOwner = getAddress(
    (await c.read.owner()) as string,
  ) as `0x${string}`;
  const pendingOwner = getAddress(
    (await c.read.pendingOwner()) as string,
  ) as `0x${string}`;
  if (pendingOwner.toLowerCase() === newOwner.toLowerCase()) {
    ownableWork.push({ status: "already_set", key, contract, proxy });
  } else if (currentOwner.toLowerCase() !== callerAddress.toLowerCase()) {
    ownableWork.push({
      status: "caller_not_owner",
      key,
      contract,
      proxy,
      currentOwner,
    });
  } else {
    ownableWork.push({
      status: "pending",
      key,
      contract,
      proxy,
      currentOwner,
    });
  }
}

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
if (isLive) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });

  console.log("\n=== transfer-ownership Summary ===");
  console.log(`Network:    ${connection.networkName} (chainId: ${chainId})`);
  console.log(`Caller:     ${callerAddress}`);
  console.log(`New owner:  ${newOwner}`);
  console.log(`PM proxy:   ${pmProxy}`);
  console.log("----------------------------------");

  if (rolesToGrant.length > 0) {
    console.log(`\nRoles to grant (${rolesToGrant.length}):`);
    for (const { name } of rolesToGrant) {
      console.log(`  + ${name}`);
    }
  }
  if (rolesAlreadyHeld.length > 0) {
    console.log(
      `\nRoles already held by new owner (${rolesAlreadyHeld.length}):`,
    );
    for (const { name } of rolesAlreadyHeld) {
      console.log(`  ~ ${name} (skip)`);
    }
  }

  console.log("\nOwnable2Step transfers:");
  for (const item of ownableWork) {
    if (item.status === "not_deployed") {
      console.log(`  ~ ${item.key}: not deployed on this network (skip)`);
    } else if (item.status === "already_set") {
      console.log(
        `  ~ ${item.key} (${item.proxy}): pendingOwner already set (skip)`,
      );
    } else if (item.status === "caller_not_owner") {
      console.log(
        `  ! ${item.key} (${item.proxy}): caller is NOT owner (${item.currentOwner}) — will skip`,
      );
    } else {
      console.log(
        `  + ${item.key} (${item.proxy}): transferOwnership(${newOwner})`,
      );
    }
  }
  console.log("==================================\n");

  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  if (answer.toLowerCase() !== "yes") {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Step 1: Grant all roles on PermissionManager ────────────────────────────
console.log("\n[Phase 1/2] PermissionManager role grants");
console.log(`  Proxy: ${pmProxy}`);

const grantedRoles: Array<{
  name: string;
  hash: `0x${string}`;
  txHash: string;
}> = [];

for (const { name, hash } of rolesToGrant) {
  console.log(`  [+] grantRole(${name}, ${newOwner})...`);
  const txHash = await pm.write.grantRole([hash, newOwner], {
    account: callerClient.account,
  });
  const receipt = await publicClient.waitForTransactionReceipt({
    hash: txHash,
  });
  // verify
  const confirmed = await pm.read.hasProtocolRole([hash, newOwner]);
  if (!confirmed) {
    console.error(
      `  CRITICAL: hasProtocolRole returned false after grantRole(${name})! tx: ${txHash}`,
    );
    process.exit(1);
  }
  console.log(`     ✓  tx: ${txHash} (block ${receipt.blockNumber})`);
  grantedRoles.push({ name, hash, txHash });
}

for (const { name } of rolesAlreadyHeld) {
  console.log(`  [~] ${name} — already held, skipped`);
}

// ─── Step 2: Ownable2Step transferOwnership ───────────────────────────────────
console.log("\n[Phase 2/2] Ownable2Step ownership transfers");

type OwnableResult = {
  key: string;
  proxy: string;
  status:
    | "transferred"
    | "skipped_not_deployed"
    | "skipped_already_set"
    | "skipped_not_owner";
  txHash?: string;
};
const ownableResults: OwnableResult[] = [];

for (const item of ownableWork) {
  if (item.status === "not_deployed") {
    console.log(`  [~] ${item.key} — not deployed on this network, skipped`);
    ownableResults.push({
      key: item.key,
      proxy: "(not deployed)",
      status: "skipped_not_deployed",
    });
    continue;
  }

  if (item.status === "already_set") {
    console.log(
      `  [~] ${item.key} (${item.proxy}) — pendingOwner already set to ${newOwner}, skipped`,
    );
    ownableResults.push({
      key: item.key,
      proxy: item.proxy,
      status: "skipped_already_set",
    });
    continue;
  }

  if (item.status === "caller_not_owner") {
    console.warn(
      `  [!] ${item.key} (${item.proxy}) — caller ${callerAddress} is not the current owner (${item.currentOwner}); skipped`,
    );
    ownableResults.push({
      key: item.key,
      proxy: item.proxy,
      status: "skipped_not_owner",
    });
    continue;
  }

  // status === "pending" — caller is owner, pendingOwner not yet set
  const c = await viem.getContractAt(item.contract, item.proxy);
  console.log(
    `  [+] ${item.key} (${item.proxy}): transferOwnership(${newOwner})...`,
  );
  const txHash = await c.write.transferOwnership([newOwner], {
    account: callerClient.account,
  });
  const receipt = await publicClient.waitForTransactionReceipt({
    hash: txHash,
  });
  // verify
  const pendingOwnerNow = getAddress(
    (await c.read.pendingOwner()) as string,
  ) as `0x${string}`;
  if (pendingOwnerNow.toLowerCase() !== newOwner.toLowerCase()) {
    console.error(
      `  CRITICAL: pendingOwner mismatch after transferOwnership on ${item.key}! tx: ${txHash}`,
    );
    process.exit(1);
  }
  console.log(`     ✓  tx: ${txHash} (block ${receipt.blockNumber})`);
  ownableResults.push({
    key: item.key,
    proxy: item.proxy,
    status: "transferred",
    txHash,
  });
}

// ─── Final summary ────────────────────────────────────────────────────────────
const totalRolesGranted = grantedRoles.length + rolesAlreadyHeld.length;
const ownableTransferred = ownableResults.filter(
  (r) => r.status === "transferred",
);
const ownableSkippedNotOwner = ownableResults.filter(
  (r) => r.status === "skipped_not_owner",
);

console.log("\n=== transfer-ownership Complete ===");
console.log(`Network:    ${connection.networkName} (chainId: ${chainId})`);
console.log(`Caller:     ${callerAddress}`);
console.log(`New owner:  ${newOwner}`);
console.log(
  `Roles:      ${grantedRoles.length} granted, ${rolesAlreadyHeld.length} already held (${totalRolesGranted}/${Object.keys(ROLES).length} total)`,
);
console.log(`Ownable:    ${ownableTransferred.length} transferred`);

// ─── ⚠ Remaining manual steps ─────────────────────────────────────────────────
const ownableNeedingAccept = ownableResults.filter(
  (r) => r.status === "transferred" || r.status === "skipped_already_set",
);
if (ownableNeedingAccept.length > 0) {
  console.log(
    "\n⚠  REQUIRED: New owner must call acceptOwnership() from their key on:",
  );
  for (const r of ownableNeedingAccept) {
    console.log(`     ${r.key}  ${r.proxy}`);
  }
  console.log(
    "   Until acceptOwnership() is called, the old owner retains full control of those contracts.",
  );
}
if (ownableSkippedNotOwner.length > 0) {
  console.log("\n⚠  MANUAL ACTION NEEDED: Caller was not the owner of:");
  for (const r of ownableSkippedNotOwner) {
    console.log(`     ${r.key}  ${r.proxy}`);
  }
  console.log(
    "   These contracts were not modified. Run this script again with the correct key.",
  );
}
console.log(
  `\n⚠  The old admin (${callerAddress}) still holds DEFAULT_ADMIN_ROLE and all operational roles.`,
);
console.log(
  "   Revoke/renounce those roles separately once the new owner has been verified as working.",
);
console.log(
  "   Use: npx hardhat run scripts/grant-role.ts --network <network> (then manually call revokeRole)",
);
if (
  ownableWork.some(
    (i) => i.status === "pending" && "key" in i && i.key === "AssetLendingPool",
  ) ||
  ownableWork.some(
    (i) => i.status === "not_deployed" && i.key !== "P2PTradeEscrow",
  )
) {
  // This message is always relevant since PackVRFRouter holds a VRF subscription consumer role
  console.log(
    "\n   NOTE: Chainlink VRF subscription ownership (on the coordinator) is separate and",
  );
  console.log(
    "   must be transferred via requestSubscriptionOwnerTransfer / acceptSubscriptionOwnerTransfer",
  );
  console.log("   on the Chainlink VRF coordinator directly.");
}
console.log("===================================\n");

// ─── Persist audit trail (live networks only) ─────────────────────────────────
if (isLive) {
  const existing = (deploymentData["OwnershipTransfers"] as unknown[]) ?? [];
  const record = {
    newOwner,
    transferredBy: callerAddress,
    permissionManager: pmProxy,
    rolesGranted: grantedRoles.map((r) => ({
      role: r.name,
      roleHash: r.hash,
      txHash: r.txHash,
    })),
    rolesAlreadyHeld: rolesAlreadyHeld.map((r) => r.name),
    ownableTransfers: ownableResults.map((r) => ({
      contract: r.key,
      proxy: r.proxy,
      status: r.status,
      txHash: r.txHash ?? null,
    })),
    transferredAt: new Date().toISOString(),
  };
  deploymentData["OwnershipTransfers"] = [...existing, record];
  const outPath = getDeploymentPath(connection.networkName);
  const tmpPath = `${outPath}.tmp`;
  await mkdir(outPath.replace(/\/[^/]+$/, ""), { recursive: true });
  await writeFile(tmpPath, JSON.stringify(deploymentData, null, 2) + "\n");
  await rename(tmpPath, outPath);
  console.log(
    `Audit trail appended to deployments/${connection.networkName}.json\n`,
  );
}
