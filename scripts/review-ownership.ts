/**
 * review-ownership.ts
 *
 * Read-only audit of the protocol's authority state:
 *   - every PermissionManager role and all of its current holders
 *   - owner() / pendingOwner() for each deployed Ownable2Step contract
 *
 * Use it before and after an ownership handoff to confirm exactly who holds
 * DEFAULT_ADMIN_ROLE (and every other role) and to spot mid-handoff state
 * (pendingOwner set but not yet accepted).
 *
 * Usage
 * -----
 * npx hardhat run scripts/review-ownership.ts --network base
 *
 * # Annotate whether a specific Safe holds each role / owns each contract:
 * SAFE_ADDRESS=0x<multisig> npx hardhat run scripts/review-ownership.ts --network base
 *
 * # Also write deployments/ownership-report.<network>.json:
 * WRITE_REPORT=1 npx hardhat run scripts/review-ownership.ts --network base
 *
 * # Override the PermissionManager proxy:
 * PERMISSION_MANAGER_PROXY=0x<addr> npx hardhat run scripts/review-ownership.ts --network base
 */

import { network } from "hardhat";
import { getAddress } from "viem";
import { writeFile, rename, mkdir } from "node:fs/promises";
import { readDeployments, getDeploymentPath } from "./lib/deployments.js";
import { ROLES, OWNABLE_CONTRACTS } from "./lib/ownership.js";

// ─── Optional SAFE_ADDRESS annotation ──────────────────────────────────────────
let safeAddress: `0x${string}` | undefined;
if (process.env.SAFE_ADDRESS) {
  try {
    safeAddress = getAddress(process.env.SAFE_ADDRESS) as `0x${string}`;
  } catch {
    console.error(`Invalid SAFE_ADDRESS address: "${process.env.SAFE_ADDRESS}"`);
    process.exit(1);
  }
}

// ─── Network connection ───────────────────────────────────────────────────────
const connection = await network.create();
const { viem } = connection;
const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();
const [callerClient] = await viem.getWalletClients();
const callerAddress = callerClient?.account?.address
  ? (getAddress(callerClient.account.address) as `0x${string}`)
  : undefined;

// ─── Load deployments ─────────────────────────────────────────────────────────
const deploymentData = await readDeployments(connection.networkName);

// ─── Resolve PermissionManager proxy ─────────────────────────────────────────
let pmProxy: `0x${string}` | undefined;
if (process.env.PERMISSION_MANAGER_PROXY) {
  pmProxy = getAddress(process.env.PERMISSION_MANAGER_PROXY) as `0x${string}`;
} else {
  const pmEntry = deploymentData["PermissionManager"] as
    | Record<string, unknown>
    | undefined;
  if (pmEntry?.proxy) {
    pmProxy = getAddress(pmEntry.proxy as string) as `0x${string}`;
  }
}

// ─── Annotate a holder address ────────────────────────────────────────────────
function annotate(addr: `0x${string}`): string {
  const tags: string[] = [];
  if (safeAddress && addr.toLowerCase() === safeAddress.toLowerCase())
    tags.push("SAFE");
  if (callerAddress && addr.toLowerCase() === callerAddress.toLowerCase())
    tags.push("caller/EOA");
  return tags.length ? `  <- ${tags.join(", ")}` : "";
}

console.log(`\n=== review-ownership ===`);
console.log(`Network:  ${connection.networkName} (chainId: ${chainId})`);
if (callerAddress) console.log(`Caller:   ${callerAddress}`);
if (safeAddress) console.log(`Safe:     ${safeAddress}`);

// ─── Roles ────────────────────────────────────────────────────────────────────
type RoleReport = { role: string; hash: `0x${string}`; holders: `0x${string}`[] };
const roleReports: RoleReport[] = [];

console.log(`\n── ROLES (PermissionManager) ──`);
if (!pmProxy) {
  console.log(
    "  PermissionManager proxy not found in deployments and PERMISSION_MANAGER_PROXY unset — skipping role enumeration.",
  );
} else {
  console.log(`  Proxy: ${pmProxy}\n`);
  const pm = await viem.getContractAt("PermissionManager", pmProxy);
  for (const [name, hash] of Object.entries(ROLES)) {
    const count = Number(
      (await pm.read.getRoleMemberCount([hash])) as bigint,
    );
    const holders: `0x${string}`[] = [];
    for (let i = 0; i < count; i++) {
      const member = getAddress(
        (await pm.read.getRoleMember([hash, BigInt(i)])) as string,
      ) as `0x${string}`;
      holders.push(member);
    }
    roleReports.push({ role: name, hash, holders });

    console.log(`  ${name} (${count})`);
    if (count === 0) {
      console.log(`     (none)`);
    } else {
      for (const h of holders) console.log(`     ${h}${annotate(h)}`);
    }
  }
}

// ─── Owners (Ownable2Step) ─────────────────────────────────────────────────────
type OwnerReport = {
  key: string;
  proxy: `0x${string}` | null;
  owner: `0x${string}` | null;
  pendingOwner: `0x${string}` | null;
  status: "deployed" | "not_deployed";
};
const ownerReports: OwnerReport[] = [];

console.log(`\n── OWNERS (Ownable2Step) ──`);
for (const { key, contract } of OWNABLE_CONTRACTS) {
  const entry = deploymentData[key] as Record<string, unknown> | undefined;
  if (!entry?.proxy) {
    console.log(`  ~ ${key}: not deployed on this network`);
    ownerReports.push({
      key,
      proxy: null,
      owner: null,
      pendingOwner: null,
      status: "not_deployed",
    });
    continue;
  }
  const proxy = getAddress(entry.proxy as string) as `0x${string}`;
  const c = await viem.getContractAt(contract, proxy);
  const owner = getAddress((await c.read.owner()) as string) as `0x${string}`;
  const pendingOwner = getAddress(
    (await c.read.pendingOwner()) as string,
  ) as `0x${string}`;
  const zero = "0x0000000000000000000000000000000000000000";

  console.log(`  ${key} (${proxy})`);
  console.log(`     owner:         ${owner}${annotate(owner)}`);
  console.log(
    `     pendingOwner:  ${
      pendingOwner.toLowerCase() === zero ? "(none)" : pendingOwner
    }${pendingOwner.toLowerCase() === zero ? "" : annotate(pendingOwner)}`,
  );
  ownerReports.push({
    key,
    proxy,
    owner,
    pendingOwner,
    status: "deployed",
  });
}

console.log(`\n========================\n`);

// ─── Optional JSON report ──────────────────────────────────────────────────────
if (process.env.WRITE_REPORT) {
  const report = {
    network: connection.networkName,
    chainId,
    permissionManager: pmProxy ?? null,
    caller: callerAddress ?? null,
    safe: safeAddress ?? null,
    // Date.now() is fine — plain node script, informational timestamp only.
    generatedAt: new Date().toISOString(),
    roles: roleReports,
    owners: ownerReports,
  };
  const outPath = getDeploymentPath(connection.networkName).replace(
    /[^/]+$/,
    `ownership-report.${connection.networkName}.json`,
  );
  const tmpPath = `${outPath}.tmp`;
  await mkdir(outPath.replace(/\/[^/]+$/, ""), { recursive: true });
  await writeFile(tmpPath, JSON.stringify(report, null, 2) + "\n");
  await rename(tmpPath, outPath);
  console.log(`Report written: ${outPath}\n`);
}
