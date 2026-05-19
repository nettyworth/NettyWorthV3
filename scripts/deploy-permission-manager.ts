import { network } from "hardhat";
import { encodeFunctionData } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

async function confirm(
  networkName: string,
  chainId: number,
  deployer: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== Deployment Summary ===");
  console.log(`Network:  ${networkName}`);
  console.log(`Chain ID: ${chainId}`);
  console.log(`Deployer: ${deployer}`);
  console.log(`Admin:    ${deployer}`);
  console.log("==========================\n");
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

if (connection.networkConfig.type === "http") {
  const ok = await confirm(connection.networkName, chainId, deployerAddress);
  if (!ok) {
    console.log("Deployment cancelled.");
    process.exit(0);
  }
}

console.log("\n[1/3] Deploying PermissionManager implementation...");
const impl = await viem.deployContract("PermissionManager");
console.log(`  Implementation: ${impl.address}`);

console.log("[2/3] Encoding initialize calldata...");
const initData = encodeFunctionData({
  abi: impl.abi,
  functionName: "initialize",
  args: [deployerAddress],
});

console.log("[3/3] Deploying ERC1967 proxy...");
const proxy = await viem.deployContract("ERC1967ProxyHelper", [
  impl.address,
  initData,
]);
console.log(`  Proxy: ${proxy.address}`);

// Verify
const pm = await viem.getContractAt("PermissionManager", proxy.address);
const adminRole = await pm.read.DEFAULT_ADMIN_ROLE();
const hasAdminRole = await pm.read.hasProtocolRole([
  adminRole,
  deployerAddress,
]);
if (!hasAdminRole) {
  console.error(
    "Verification failed: deployer does not have DEFAULT_ADMIN_ROLE",
  );
  process.exit(1);
}

console.log("\n=== Deployment Successful ===");
console.log(`Network:        ${connection.networkName} (chainId: ${chainId})`);
console.log(`Implementation: ${impl.address}`);
console.log(`Proxy:          ${proxy.address}`);
console.log(`Admin:          ${deployerAddress}`);
console.log("=============================\n");

if (connection.networkConfig.type === "http") {
  const deploymentsDir = join(
    dirname(fileURLToPath(import.meta.url)),
    "../deployments",
  );
  const outPath = join(deploymentsDir, `${connection.networkName}.json`);

  let existing: Record<string, unknown> = {};
  try {
    existing = JSON.parse(await readFile(outPath, "utf8"));
  } catch {
    // file doesn't exist yet — start fresh
  }

  existing["PermissionManager"] = {
    proxy: proxy.address,
    implementation: impl.address,
    admin: deployerAddress,
    deployedAt: new Date().toISOString(),
  };

  await mkdir(deploymentsDir, { recursive: true });
  await writeFile(outPath, JSON.stringify(existing, null, 2) + "\n");
  console.log(
    `Deployment info saved to deployments/${connection.networkName}.json`,
  );
}
