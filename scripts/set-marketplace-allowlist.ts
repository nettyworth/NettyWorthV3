import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ─── DEFAULT_ADMIN_ROLE = bytes32(0) ──────────────────────────────────────────
const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

// ─── Parse ALLOWED (default true) ────────────────────────────────────────────
const rawAllowed = process.env.ALLOWED ?? "true";
let allowedBool: boolean;
if (rawAllowed === "true" || rawAllowed === "1") {
  allowedBool = true;
} else if (rawAllowed === "false" || rawAllowed === "0") {
  allowedBool = false;
} else {
  console.error(
    `Invalid ALLOWED value: "${rawAllowed}". Expected true, false, 1, or 0.`,
  );
  process.exit(1);
}

// ─── Parse address lists ──────────────────────────────────────────────────────
function parseAddressList(envName: string): `0x${string}`[] {
  const raw = process.env[envName];
  if (!raw) return [];
  const parts = raw
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const result: `0x${string}`[] = [];
  for (const part of parts) {
    try {
      result.push(getAddress(part) as `0x${string}`);
    } catch {
      console.error(
        `Invalid address in ${envName}: "${part}". Must be a valid checksummed Ethereum address.`,
      );
      process.exit(1);
    }
  }
  // De-dupe (preserve first occurrence)
  return [...new Map(result.map((a) => [a.toLowerCase(), a])).values()];
}

const collections = parseAddressList("COLLECTIONS");
const paymentTokens = parseAddressList("PAYMENT_TOKENS");

if (collections.length === 0 && paymentTokens.length === 0) {
  console.error(
    "At least one of COLLECTIONS or PAYMENT_TOKENS must be provided.",
  );
  console.error(
    "Usage: COLLECTIONS=0x<addr>,0x<addr> PAYMENT_TOKENS=0x<addr> ALLOWED=true hardhat run scripts/set-marketplace-allowlist.ts --network <network>",
  );
  process.exit(1);
}

// ─── SKIP_CONFIRM flag ────────────────────────────────────────────────────────
const skipConfirm =
  process.env.SKIP_CONFIRM === "true" || process.env.SKIP_CONFIRM === "1";

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirmUpdate(
  networkName: string,
  chainId: number,
  caller: string,
  proxy: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== setMarketplaceAllowlist Summary ===");
  console.log(`Network:       ${networkName}`);
  console.log(`Chain ID:      ${chainId}`);
  console.log(`Caller:        ${caller}`);
  console.log(`Proxy:         ${proxy}`);
  console.log(`ALLOWED:       ${allowedBool}`);
  if (collections.length > 0) {
    console.log(`Collections (${collections.length}):`);
    for (const addr of collections) console.log(`  ${addr}`);
  }
  if (paymentTokens.length > 0) {
    console.log(`Payment tokens (${paymentTokens.length}):`);
    for (const addr of paymentTokens) console.log(`  ${addr}`);
  }
  console.log("=======================================\n");
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

// ─── Resolve NettyWorthMarketplace proxy ──────────────────────────────────────
let deploymentData: Record<string, unknown> = {};
let proxyAddress: `0x${string}`;

if (process.env.MARKETPLACE_PROXY) {
  proxyAddress = getAddress(process.env.MARKETPLACE_PROXY) as `0x${string}`;
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
      "Deploy first using deploy-marketplace.ts, or set MARKETPLACE_PROXY to specify the proxy address.",
    );
    process.exit(1);
  }
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
    "setAllowedCollection / setAllowedPaymentToken require DEFAULT_ADMIN_ROLE — transaction would revert.",
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
    );
    if (!ok) {
      console.log("Cancelled.");
      process.exit(0);
    }
  }
}

// ─── Send transactions ────────────────────────────────────────────────────────
// Note: allowedCollections and allowedPaymentTokens are private mappings in
// ERC-7201 storage with no public getter. Verification relies solely on the
// receipt status and the AllowedCollectionUpdated / AllowedPaymentTokenUpdated
// events decoded from the receipt logs.

const txHashes: string[] = [];
const failures: string[] = [];

let step = 1;
const total = collections.length + paymentTokens.length;

for (const addr of collections) {
  console.log(
    `\n[${step}/${total}] setAllowedCollection(${addr}, ${allowedBool})...`,
  );
  const txHash = await market.write.setAllowedCollection([addr, allowedBool], {
    account: callerClient.account,
  });
  const receipt = await publicClient.waitForTransactionReceipt({
    hash: txHash,
  });
  if (receipt.status === "success") {
    console.log(`  ✓  tx: ${txHash} (block ${receipt.blockNumber})`);
    txHashes.push(txHash);
  } else {
    console.error(`  ✗  tx reverted: ${txHash} (block ${receipt.blockNumber})`);
    failures.push(`setAllowedCollection(${addr}): ${txHash}`);
  }
  step++;
}

for (const addr of paymentTokens) {
  console.log(
    `\n[${step}/${total}] setAllowedPaymentToken(${addr}, ${allowedBool})...`,
  );
  const txHash = await market.write.setAllowedPaymentToken(
    [addr, allowedBool],
    { account: callerClient.account },
  );
  const receipt = await publicClient.waitForTransactionReceipt({
    hash: txHash,
  });
  if (receipt.status === "success") {
    console.log(`  ✓  tx: ${txHash} (block ${receipt.blockNumber})`);
    txHashes.push(txHash);
  } else {
    console.error(`  ✗  tx reverted: ${txHash} (block ${receipt.blockNumber})`);
    failures.push(`setAllowedPaymentToken(${addr}): ${txHash}`);
  }
  step++;
}

// ─── Summary ──────────────────────────────────────────────────────────────────
console.log("\n=== setMarketplaceAllowlist Complete ===");
console.log(`Network:    ${connection.networkName} (chainId: ${chainId})`);
console.log(`Proxy:      ${proxyAddress}`);
console.log(`ALLOWED:    ${allowedBool}`);
console.log(
  `Collections updated:    ${collections.length - failures.filter((f) => f.startsWith("setAllowedCollection")).length}/${collections.length}`,
);
console.log(
  `Payment tokens updated: ${paymentTokens.length - failures.filter((f) => f.startsWith("setAllowedPaymentToken")).length}/${paymentTokens.length}`,
);
if (failures.length > 0) {
  console.error("\nFailed transactions:");
  for (const f of failures) console.error(`  ${f}`);
}
console.log("========================================\n");

// ─── Persist audit trail (live networks only) ─────────────────────────────────
if (connection.networkConfig.type === "http" && txHashes.length > 0) {
  const existing =
    (deploymentData["MarketplaceAllowlistUpdates"] as unknown[]) ?? [];
  deploymentData["MarketplaceAllowlistUpdates"] = [
    ...existing,
    {
      collections,
      paymentTokens,
      allowed: allowedBool,
      updatedBy: callerAddress,
      txHashes,
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

if (failures.length > 0) {
  process.exit(1);
}
