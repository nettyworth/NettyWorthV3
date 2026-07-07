import { network } from "hardhat";
import { encodeFunctionData, getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { waitForCode } from "./lib/deployments.js";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

async function confirm(
  networkName: string,
  chainId: number,
  deployer: string,
  permissionManager: string,
  factory: string | null,
  buybackPool: string | null,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== PromoCodeRegistry Deployment Summary ===");
  console.log(`Network:            ${networkName}`);
  console.log(`Chain ID:           ${chainId}`);
  console.log(`Deployer:           ${deployer}`);
  console.log(`PermissionManager:  ${permissionManager}`);
  console.log(
    `PackMachineFactory: ${factory ?? "(not resolved — wiring skipped)"}`,
  );
  console.log(
    `BuybackPool:        ${buybackPool ?? "(not resolved — wiring skipped)"}`,
  );
  console.log("============================================\n");
  const answer = await rl.question("Proceed with deployment? (yes/no): ");
  rl.close();
  return answer.toLowerCase() === "yes";
}

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [deployerClient] = await viem.getWalletClients();
const deployerAddress = deployerClient.account.address;
const chainId = await publicClient.getChainId();

const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../deployments",
);
const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);

async function readDeployments(): Promise<Record<string, unknown>> {
  try {
    return JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    return {};
  }
}

// Polls `read` until it returns `expected` (case-insensitive address compare).
// Guards against load-balanced RPC nodes that haven't propagated state yet.
async function pollUntil(
  read: () => Promise<string>,
  expected: string,
  label: string,
  retries = 12,
  intervalMs = 2000,
): Promise<void> {
  for (let i = 0; i < retries; i++) {
    const val = await read();
    if (val.toLowerCase() === expected.toLowerCase()) return;
    console.log(`  [sync] ${label} not yet visible (attempt ${i + 1}/${retries}), retrying...`);
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`${label}: value did not propagate after ${retries} attempts`);
}

// ─── Resolve PERMISSION_MANAGER_PROXY ────────────────────────────────────────
let permissionManagerProxy: `0x${string}`;
if (process.env.PERMISSION_MANAGER_PROXY) {
  permissionManagerProxy = getAddress(
    process.env.PERMISSION_MANAGER_PROXY,
  ) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
  const data = await readDeployments();
  const entry = data["PermissionManager"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "PermissionManager proxy not found. Set PERMISSION_MANAGER_PROXY or deploy PermissionManager first.",
    );
    process.exit(1);
  }
  permissionManagerProxy = getAddress(entry.proxy as string) as `0x${string}`;
} else {
  console.error("Set PERMISSION_MANAGER_PROXY env var.");
  process.exit(1);
}

// ─── Resolve optional PACK_MACHINE_FACTORY_PROXY + BUYBACK_POOL_PROXY ────────
let factoryProxy: `0x${string}` | null = null;
let buybackPoolProxy: `0x${string}` | null = null;

if (process.env.PACK_MACHINE_FACTORY_PROXY) {
  factoryProxy = getAddress(
    process.env.PACK_MACHINE_FACTORY_PROXY,
  ) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
  const data = await readDeployments();
  const entry = data["PackMachineFactory"] as
    | Record<string, unknown>
    | undefined;
  if (entry?.proxy)
    factoryProxy = getAddress(entry.proxy as string) as `0x${string}`;
}

if (process.env.BUYBACK_POOL_PROXY) {
  buybackPoolProxy = getAddress(
    process.env.BUYBACK_POOL_PROXY,
  ) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
  const data = await readDeployments();
  const entry = data["BuybackPool"] as Record<string, unknown> | undefined;
  if (entry?.proxy)
    buybackPoolProxy = getAddress(entry.proxy as string) as `0x${string}`;
}

// ─── Confirmation prompt on live networks ────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirm(
    connection.networkName,
    chainId,
    deployerAddress,
    permissionManagerProxy,
    factoryProxy,
    buybackPoolProxy,
  );
  if (!ok) {
    console.log("Deployment cancelled.");
    process.exit(0);
  }
}

// ─── [1/4] Deploy implementation ─────────────────────────────────────────────
console.log("\n[1/4] Deploying PromoCodeRegistry implementation...");
const impl = await viem.deployContract("PromoCodeRegistry");
console.log(`  Implementation: ${impl.address}`);

// ─── [2/4] Encode initialize calldata ────────────────────────────────────────
console.log("[2/4] Encoding initialize calldata...");
const initData = encodeFunctionData({
  abi: impl.abi,
  functionName: "initialize",
  args: [permissionManagerProxy],
});

// ─── [3/4] Deploy ERC-1967 proxy ─────────────────────────────────────────────
console.log("[3/4] Deploying ERC1967 proxy...");
await waitForCode(publicClient, impl.address);
const proxy = await viem.deployContract("ERC1967ProxyHelper", [
  impl.address,
  initData,
]);
console.log(`  Proxy: ${proxy.address}`);

// ─── [4/4] Verify deployment ──────────────────────────────────────────────────
console.log("[4/4] Verifying deployment...");
await waitForCode(publicClient, proxy.address);
const registry = await viem.getContractAt("PromoCodeRegistry", proxy.address);

const actualPM = await registry.read.getPermissionManager();
const paused = await registry.read.paused();
const registryFactory = await registry.read.packMachineFactory();
const registryPool = await registry.read.buybackPool();

const errors: string[] = [];
if (actualPM.toLowerCase() !== permissionManagerProxy.toLowerCase()) {
  errors.push(
    `  permissionManager: expected "${permissionManagerProxy}", got "${actualPM}"`,
  );
}
if (paused) errors.push("  paused: expected false");
if (registryFactory !== "0x0000000000000000000000000000000000000000") {
  errors.push(
    `  packMachineFactory: expected zero address on fresh deploy, got "${registryFactory}"`,
  );
}
if (registryPool !== "0x0000000000000000000000000000000000000000") {
  errors.push(
    `  buybackPool: expected zero address on fresh deploy, got "${registryPool}"`,
  );
}

if (errors.length > 0) {
  console.error("Verification failed!");
  for (const e of errors) console.error(e);
  process.exit(1);
}

console.log("\n=== PromoCodeRegistry Deployment Successful ===");
console.log(
  `Network:          ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Implementation:   ${impl.address}`);
console.log(`Proxy:            ${proxy.address}`);
console.log(`PermissionManager:${actualPM}`);
console.log(`Paused:           ${paused}`);
console.log("================================================\n");

// ─── [5/6] Wire registry → factory + buybackPool ─────────────────────────────
if (factoryProxy) {
  console.log("[5a] registry.setPackMachineFactory...");
  const cur = await registry.read.packMachineFactory();
  if (cur.toLowerCase() === factoryProxy.toLowerCase()) {
    console.log("  already set — skipping");
  } else {
    const hash = await registry.write.setPackMachineFactory([factoryProxy]);
    await publicClient.waitForTransactionReceipt({ hash });
    await pollUntil(
      () => registry.read.packMachineFactory(),
      factoryProxy,
      "registry.packMachineFactory",
    );
    console.log(`  done (tx: ${hash})`);
  }
} else {
  console.log(
    "[5a] PACK_MACHINE_FACTORY_PROXY not resolved — skipping registry.setPackMachineFactory",
  );
}

if (buybackPoolProxy) {
  console.log("[5b] registry.setBuybackPool...");
  const cur = await registry.read.buybackPool();
  if (cur.toLowerCase() === buybackPoolProxy.toLowerCase()) {
    console.log("  already set — skipping");
  } else {
    const hash = await registry.write.setBuybackPool([buybackPoolProxy]);
    await publicClient.waitForTransactionReceipt({ hash });
    await pollUntil(
      () => registry.read.buybackPool(),
      buybackPoolProxy,
      "registry.buybackPool",
    );
    console.log(`  done (tx: ${hash})`);
  }
} else {
  console.log(
    "[5b] BUYBACK_POOL_PROXY not resolved — skipping registry.setBuybackPool",
  );
}

// ─── [6/6] Wire factory + buybackPool → registry ─────────────────────────────
if (factoryProxy) {
  console.log("[6a] factory.setPromoCodeRegistry...");
  const factoryContract = await viem.getContractAt(
    "PackMachineFactory",
    factoryProxy,
  );
  const cur = await factoryContract.read.promoCodeRegistry();
  if (cur.toLowerCase() === proxy.address.toLowerCase()) {
    console.log("  already set — skipping");
  } else {
    const hash = await factoryContract.write.setPromoCodeRegistry([
      proxy.address,
    ]);
    await publicClient.waitForTransactionReceipt({ hash });
    await pollUntil(
      () => factoryContract.read.promoCodeRegistry(),
      proxy.address,
      "factory.promoCodeRegistry",
    );
    console.log(`  done (tx: ${hash})`);
  }
} else {
  console.log(
    "[6a] PACK_MACHINE_FACTORY_PROXY not resolved — skipping factory.setPromoCodeRegistry",
  );
}

if (buybackPoolProxy) {
  console.log("[6b] buybackPool.setPromoCodeRegistry...");
  const buybackContract = await viem.getContractAt(
    "BuybackPool",
    buybackPoolProxy,
  );
  const cur = await buybackContract.read.getPromoCodeRegistry();
  if (cur.toLowerCase() === proxy.address.toLowerCase()) {
    console.log("  already set — skipping");
  } else {
    const hash = await buybackContract.write.setPromoCodeRegistry([
      proxy.address,
    ]);
    await publicClient.waitForTransactionReceipt({ hash });
    await pollUntil(
      () => buybackContract.read.getPromoCodeRegistry(),
      proxy.address,
      "buybackPool.promoCodeRegistry",
    );
    console.log(`  done (tx: ${hash})`);
  }
} else {
  console.log(
    "[6b] BUYBACK_POOL_PROXY not resolved — skipping buybackPool.setPromoCodeRegistry",
  );
}

const wiringIncomplete = !factoryProxy || !buybackPoolProxy;
if (wiringIncomplete) {
  console.log("\nRemaining manual steps (contracts not resolved above):");
  if (!factoryProxy) {
    console.log(
      `  registry.setPackMachineFactory(<factoryProxy>)       -- DEFAULT_ADMIN_ROLE`,
    );
    console.log(
      `  factory.setPromoCodeRegistry("${proxy.address}")     -- DEFAULT_ADMIN_ROLE`,
    );
  }
  if (!buybackPoolProxy) {
    console.log(
      `  registry.setBuybackPool(<buybackPoolProxy>)          -- DEFAULT_ADMIN_ROLE`,
    );
    console.log(
      `  buybackPool.setPromoCodeRegistry("${proxy.address}") -- PACK_OPERATOR_ROLE`,
    );
  }
}
console.log(`\nAdditional steps (always manual):`);
console.log(
  `  - Deploy a new PackMachine implementation and call factory.setImplementation(newImpl)`,
);
console.log(`    so future clones support code-aware openPack calls.`);
console.log(
  `  - Upgrade BuybackPool and PackMachineFactory implementations in place (UUPS).`,
);

// ─── Persist deployment record ────────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  let existing: Record<string, unknown> = {};
  try {
    existing = JSON.parse(await readFile(deploymentPath, "utf8"));
  } catch {
    /**/
  }

  existing["PromoCodeRegistry"] = {
    proxy: proxy.address,
    implementation: impl.address,
    permissionManager: permissionManagerProxy,
    packMachineFactory: factoryProxy ?? null,
    buybackPool: buybackPoolProxy ?? null,
    deployedAt: new Date().toISOString(),
  };

  await mkdir(deploymentsDir, { recursive: true });
  await writeFile(deploymentPath, JSON.stringify(existing, null, 2) + "\n");
  console.log(
    `Deployment info saved to deployments/${connection.networkName}.json`,
  );
}
