import { network } from "hardhat";
import { getAddress, keccak256, toBytes } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ─── DEFAULT_ADMIN_ROLE = bytes32(0) ──────────────────────────────────────────
const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

// ─── Role map — canonical names from contracts/lib/Roles.sol ─────────────────
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

// ─── Validate ROLE env var ────────────────────────────────────────────────────
const roleName = process.env.ROLE;
if (!roleName) {
  console.error("Missing required env var: ROLE");
  console.error(`Valid values: ${Object.keys(ROLES).join(", ")}`);
  process.exit(1);
}
if (!(roleName in ROLES)) {
  console.error(`Unknown role: "${roleName}"`);
  console.error(`Valid values: ${Object.keys(ROLES).join(", ")}`);
  process.exit(1);
}
const roleHash = ROLES[roleName]!;

// ─── Validate ACCOUNT env var ─────────────────────────────────────────────────
const rawAccount = process.env.ACCOUNT;
if (!rawAccount) {
  console.error("Missing required env var: ACCOUNT");
  console.error("Usage: ROLE=<name> ACCOUNT=0x<address> hardhat run scripts/grant-role.ts --network <network>");
  process.exit(1);
}
let targetAccount: `0x${string}`;
try {
  targetAccount = getAddress(rawAccount) as `0x${string}`;
} catch {
  console.error(`Invalid ACCOUNT address: "${rawAccount}"`);
  process.exit(1);
}

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirmGrant(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
  role: string,
  hash: string,
  account: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== grantRole Summary ===");
  console.log(`Network:    ${networkName}`);
  console.log(`Chain ID:   ${chainId}`);
  console.log(`Caller:     ${caller}`);
  console.log(`Proxy:      ${proxy}`);
  console.log(`Role:       ${role}`);
  console.log(`Role hash:  ${hash}`);
  console.log(`Account:    ${account}`);
  console.log("=========================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  return answer.toLowerCase() === "yes";
}

// ─── Network connection ───────────────────────────────────────────────────────
const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [callerClient] = await viem.getWalletClients();
const callerAddress = callerClient.account.address;
const chainId = await publicClient.getChainId();

const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../deployments",
);
const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);

// ─── Resolve PermissionManager proxy ─────────────────────────────────────────
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.PERMISSION_MANAGER_PROXY) {
  proxyAddress = getAddress(
    process.env.PERMISSION_MANAGER_PROXY,
  ) as `0x${string}`;
  try {
    deploymentData = JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    // No deployment file yet — skip persistence
  }
} else {
  try {
    deploymentData = JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    console.error(`No deployment file found at ${deploymentPath}`);
    console.error(
      "Deploy first using deploy-permission-manager.ts, or set PERMISSION_MANAGER_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
  const entry = deploymentData["PermissionManager"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "PermissionManager proxy address not found in deployment file.",
    );
    console.error("Set PERMISSION_MANAGER_PROXY to override.");
    process.exit(1);
  }
  proxyAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── Verify caller holds DEFAULT_ADMIN_ROLE ───────────────────────────────────
const pm = await viem.getContractAt("PermissionManager", proxyAddress);

const hasAdminRole = await pm.read.hasProtocolRole([
  DEFAULT_ADMIN_ROLE,
  callerAddress,
]);
if (!hasAdminRole) {
  console.error(
    `Account ${callerAddress} does not have DEFAULT_ADMIN_ROLE on PermissionManager ${proxyAddress}`,
  );
  process.exit(1);
}

// ─── Idempotency check ────────────────────────────────────────────────────────
const alreadyGranted = await pm.read.hasProtocolRole([
  roleHash,
  targetAccount,
]);
if (alreadyGranted) {
  console.log(
    `\n${targetAccount} already holds ${roleName} on PermissionManager ${proxyAddress}. Nothing to do.`,
  );
  process.exit(0);
}

// ─── Confirmation on live networks ────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirmGrant(
    connection.networkName,
    chainId,
    callerAddress,
    proxyAddress,
    roleName,
    roleHash,
    targetAccount,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────
console.log(`\n[1/2] Calling grantRole(${roleName}, ${targetAccount})...`);
const txHash = await pm.write.grantRole([roleHash, targetAccount], {
  account: callerClient.account,
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });
console.log(`  tx: ${txHash} (block ${receipt.blockNumber})`);

// ─── Verify ───────────────────────────────────────────────────────────────────
console.log("[2/2] Verifying...");
const confirmed = await pm.read.hasProtocolRole([roleHash, targetAccount]);
if (!confirmed) {
  console.error(
    `CRITICAL: hasProtocolRole returned false after grantRole! tx: ${txHash}`,
  );
  process.exit(1);
}
console.log(`  ${targetAccount} now holds ${roleName} ✓`);

// ─── Summary ──────────────────────────────────────────────────────────────────
console.log("\n=== grantRole Complete ===");
console.log(`Network:    ${connection.networkName} (chainId: ${chainId})`);
console.log(`Proxy:      ${proxyAddress}`);
console.log(`Role:       ${roleName} (${roleHash})`);
console.log(`Account:    ${targetAccount}`);
console.log(`Tx:         ${txHash}`);
console.log("==========================\n");

// ─── Persist audit trail (live networks only) ─────────────────────────────────
if (connection.networkConfig.type === "http") {
  const existing = (deploymentData["RoleGrants"] as unknown[]) ?? [];
  deploymentData["RoleGrants"] = [
    ...existing,
    {
      role: roleName,
      roleHash,
      account: targetAccount,
      grantedBy: callerAddress,
      txHash,
      grantedAt: new Date().toISOString(),
    },
  ];

  await mkdir(deploymentsDir, { recursive: true });
  await writeFile(
    deploymentPath,
    JSON.stringify(deploymentData, null, 2) + "\n",
  );
  console.log(
    `Audit trail updated at deployments/${connection.networkName}.json`,
  );
}
