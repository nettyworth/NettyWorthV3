import { network } from "hardhat";
import { encodeFunctionData, getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { waitForCode } from "./lib/deployments.js";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { sleep } from "./lib/sleep.js";

const TRUSTED_FORWARDER = (process.env.TRUSTED_FORWARDER ??
  "0x0000000000000000000000000000000000000000") as `0x${string}`;
const NFT_NAME = process.env.ASSET_NFT_NAME ?? "NettyWorth Assets";
const NFT_SYMBOL = process.env.ASSET_NFT_SYMBOL ?? "NWA";
const CONTRACT_URI =
  process.env.ASSET_NFT_CONTRACT_URI ??
  "https://staging-v2-api.nettyworth.io/asset-nfts";
const ROYALTY_RECEIVER = process.env.ASSET_NFT_ROYALTY_RECEIVER;
const ROYALTY_FEE = BigInt(process.env.ASSET_NFT_ROYALTY_FEE ?? "0");

async function confirm(
  networkName: string,
  chainId: number,
  deployer: string,
  permissionManagerProxy: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== Deployment Summary ===");
  console.log(`Network:            ${networkName}`);
  console.log(`Chain ID:           ${chainId}`);
  console.log(`Deployer:           ${deployer}`);
  console.log(`PermissionManager:  ${permissionManagerProxy}`);
  console.log(`Trusted Forwarder:  ${TRUSTED_FORWARDER}`);
  console.log(`NFT Name:           ${NFT_NAME}`);
  console.log(`NFT Symbol:         ${NFT_SYMBOL}`);
  console.log(`Contract URI:       ${CONTRACT_URI}`);
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

// Resolve PermissionManager proxy address
let permissionManagerProxy: `0x${string}`;
if (process.env.PERMISSION_MANAGER_PROXY) {
  permissionManagerProxy = getAddress(
    process.env.PERMISSION_MANAGER_PROXY,
  ) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
  const deploymentsDir = join(
    dirname(fileURLToPath(import.meta.url)),
    "../deployments",
  );
  const deploymentPath = join(deploymentsDir, `${connection.networkName}.json`);
  try {
    const data = JSON.parse(await readFile(deploymentPath, "utf8"));
    const entry = data["PermissionManager"] as
      | Record<string, unknown>
      | undefined;
    if (!entry?.proxy) throw new Error("PermissionManager proxy not found");
    permissionManagerProxy = getAddress(entry.proxy as string) as `0x${string}`;
  } catch {
    console.error(
      "PermissionManager proxy address not found. Set PERMISSION_MANAGER_PROXY env var or deploy the PermissionManager first.",
    );
    process.exit(1);
  }
} else {
  console.error(
    "Set PERMISSION_MANAGER_PROXY env var to the deployed PermissionManager proxy address.",
  );
  process.exit(1);
}

// Resolve royalty receiver (defaults to deployer if not set)
const royaltyReceiver = ROYALTY_RECEIVER
  ? (getAddress(ROYALTY_RECEIVER) as `0x${string}`)
  : deployerAddress;

if (connection.networkConfig.type === "http") {
  const ok = await confirm(
    connection.networkName,
    chainId,
    deployerAddress,
    permissionManagerProxy,
  );
  if (!ok) {
    console.log("Deployment cancelled.");
    process.exit(0);
  }
}

console.log("\n[1/4] Deploying AssetNFT implementation...");
const impl = await viem.deployContract("AssetNFT", [TRUSTED_FORWARDER]);
console.log(`  Implementation: ${impl.address}`);

console.log("[2/4] Encoding initialize calldata...");
const initData = encodeFunctionData({
  abi: impl.abi,
  functionName: "initialize",
  args: [
    permissionManagerProxy,
    NFT_NAME,
    NFT_SYMBOL,
    CONTRACT_URI,
    royaltyReceiver,
    ROYALTY_FEE,
  ],
});

console.log("[3/4] Deploying ERC1967 proxy...");
await waitForCode(publicClient, impl.address);
const proxy = await viem.deployContract("ERC1967ProxyHelper", [
  impl.address,
  initData,
]);
console.log(`  Proxy: ${proxy.address}`);
await sleep(5000);

console.log("[4/4] Verifying deployment...");
const nft = await viem.getContractAt("AssetNFT", proxy.address);
const actualName = await nft.read.name();
const actualSymbol = await nft.read.symbol();
const actualContractURI = await nft.read.contractURI();
const actualPM = await nft.read.getPermissionManager();

if (
  actualName !== NFT_NAME ||
  actualSymbol !== NFT_SYMBOL ||
  actualContractURI !== CONTRACT_URI ||
  actualPM.toLowerCase() !== permissionManagerProxy.toLowerCase()
) {
  console.error("Verification failed!");
  console.error(
    `  name:              expected "${NFT_NAME}", got "${actualName}"`,
  );
  console.error(
    `  symbol:            expected "${NFT_SYMBOL}", got "${actualSymbol}"`,
  );
  console.error(
    `  contractURI:       expected "${CONTRACT_URI}", got "${actualContractURI}"`,
  );
  console.error(
    `  permissionManager: expected "${permissionManagerProxy}", got "${actualPM}"`,
  );
  process.exit(1);
}

console.log("\n=== Deployment Successful ===");
console.log(
  `Network:            ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Implementation:     ${impl.address}`);
console.log(`Proxy:              ${proxy.address}`);
console.log(`PermissionManager:  ${actualPM}`);
console.log(`Name:               ${actualName}`);
console.log(`Symbol:             ${actualSymbol}`);
console.log(`Contract URI:       ${actualContractURI}`);
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

  existing["AssetNFT"] = {
    proxy: proxy.address,
    implementation: impl.address,
    permissionManager: permissionManagerProxy,
    trustedForwarder: TRUSTED_FORWARDER,
    name: actualName,
    symbol: actualSymbol,
    contractURI: actualContractURI,
    deployedAt: new Date().toISOString(),
  };

  await mkdir(deploymentsDir, { recursive: true });
  await writeFile(outPath, JSON.stringify(existing, null, 2) + "\n");
  console.log(
    `Deployment info saved to deployments/${connection.networkName}.json`,
  );
}
