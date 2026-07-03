import { network } from "hardhat";
import { getAddress, zeroAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ─── DEFAULT_ADMIN_ROLE = bytes32(0) ──────────────────────────────────────────
const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

// ─── SKIP_CONFIRM flag ────────────────────────────────────────────────────────
const skipConfirm =
  process.env.SKIP_CONFIRM === "true" || process.env.SKIP_CONFIRM === "1";

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirmUpdate(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
  lendingPool: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setMarketplaceLendingPool Summary ===");
  console.log(`Network:      ${networkName}`);
  console.log(`Chain ID:     ${chainId}`);
  console.log(`Caller:       ${caller}`);
  console.log(`Proxy:        ${proxy}`);
  console.log(`LendingPool:  ${lendingPool}`);
  console.log("=========================================\n");
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

// ─── Load deployment data ─────────────────────────────────────────────────────
let deploymentData: Record<string, unknown> = {};
try {
  deploymentData = JSON.parse(await readFile(deploymentPath, "utf8"));
} catch {
  if (!process.env.MARKETPLACE_PROXY || !process.env.LENDING_POOL) {
    console.error(`No deployment file found at ${deploymentPath}`);
    console.error(
      "Deploy first or set both MARKETPLACE_PROXY and LENDING_POOL env vars.",
    );
    process.exit(1);
  }
}

// ─── Resolve NettyWorthMarketplace proxy ──────────────────────────────────────
let proxyAddress: `0x${string}`;

if (process.env.MARKETPLACE_PROXY) {
  proxyAddress = getAddress(process.env.MARKETPLACE_PROXY) as `0x${string}`;
} else {
  const entry = deploymentData["NettyWorthMarketplace"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "NettyWorthMarketplace proxy address not found in deployment file.",
    );
    console.error("Set MARKETPLACE_PROXY to override.");
    process.exit(1);
  }
  proxyAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── Resolve lending-pool address ─────────────────────────────────────────────
let lendingPoolAddress: `0x${string}`;

if (process.env.LENDING_POOL) {
  lendingPoolAddress = getAddress(process.env.LENDING_POOL) as `0x${string}`;
} else {
  const entry = deploymentData["AssetLendingPool"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "AssetLendingPool proxy address not found in deployment file.",
    );
    console.error("Set LENDING_POOL to override.");
    process.exit(1);
  }
  lendingPoolAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

if (lendingPoolAddress === zeroAddress) {
  console.error("Lending pool address cannot be the zero address.");
  process.exit(1);
}

// ─── Resolve PermissionManager and verify caller holds DEFAULT_ADMIN_ROLE ─────
const market = await viem.getContractAt("NettyWorthMarketplace", proxyAddress);
const pmAddress = (await market.read.getPermissionManager()) as `0x${string}`;
const pm = await viem.getContractAt("PermissionManager", pmAddress);

const hasAdminRole = await pm.read.hasProtocolRole([
  DEFAULT_ADMIN_ROLE,
  callerAddress,
]);
if (!hasAdminRole) {
  console.error(
    `Account ${callerAddress} does not have DEFAULT_ADMIN_ROLE on PermissionManager ${pmAddress}`,
  );
  console.error(
    "setLendingPool requires DEFAULT_ADMIN_ROLE — transaction would revert.",
  );
  process.exit(1);
}

// ─── Confirmation on live networks ────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  if (skipConfirm) {
    console.log("\nSKIP_CONFIRM=true — skipping confirmation prompt.");
  } else {
    const ok = await confirmUpdate(
      connection.networkName,
      chainId,
      callerAddress,
      proxyAddress,
      lendingPoolAddress,
    );
    if (!ok) {
      console.log("Cancelled.");
      process.exit(0);
    }
  }
}

// ─── Send transaction ─────────────────────────────────────────────────────────
// Note: lendingPool is a private ERC-7201 storage field with no public getter.
// Verification relies on the receipt status and the LendingPoolUpdated event
// decoded from the receipt logs.
console.log(`\nCalling setLendingPool(${lendingPoolAddress})...`);
const txHash = await market.write.setLendingPool([lendingPoolAddress], {
  account: callerClient.account,
});
const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });

if (receipt.status === "success") {
  console.log(`  ✓  tx: ${txHash} (block ${receipt.blockNumber})`);
} else {
  console.error(`  ✗  tx reverted: ${txHash} (block ${receipt.blockNumber})`);
  process.exit(1);
}

// ─── Summary ──────────────────────────────────────────────────────────────────
console.log("\n=== setMarketplaceLendingPool Complete ===");
console.log(`Network:     ${connection.networkName} (chainId: ${chainId})`);
console.log(`Proxy:       ${proxyAddress}`);
console.log(`LendingPool: ${lendingPoolAddress}`);
console.log("==========================================\n");

// ─── Persist audit trail (live networks only) ─────────────────────────────────
if (connection.networkConfig.type === "http") {
  // Update the top-level NettyWorthMarketplace.lendingPool to fix stale record
  const marketEntry = (deploymentData["NettyWorthMarketplace"] as
    | Record<string, unknown>
    | undefined) ?? {};
  deploymentData["NettyWorthMarketplace"] = {
    ...marketEntry,
    lendingPool: lendingPoolAddress,
  };

  // Append to audit trail
  const existing =
    (deploymentData["MarketplaceLendingPoolUpdates"] as unknown[]) ?? [];
  deploymentData["MarketplaceLendingPoolUpdates"] = [
    ...existing,
    {
      lendingPool: lendingPoolAddress,
      updatedBy: callerAddress,
      txHash,
      updatedAt: new Date().toISOString(),
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
