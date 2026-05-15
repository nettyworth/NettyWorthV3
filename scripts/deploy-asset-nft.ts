import { network } from "hardhat";
import { encodeFunctionData } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const NFT_NAME = process.env.ASSET_NFT_NAME ?? "NettyWorth Assets";
const NFT_SYMBOL = process.env.ASSET_NFT_SYMBOL ?? "NWA";
const CONTRACT_URI =
  process.env.ASSET_NFT_CONTRACT_URI ?? "ipfs://contract-metadata";

async function confirm(
  networkName: string,
  chainId: number,
  deployer: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== Deployment Summary ===");
  console.log(`Network:      ${networkName}`);
  console.log(`Chain ID:     ${chainId}`);
  console.log(`Deployer:     ${deployer}`);
  console.log(`NFT Name:     ${NFT_NAME}`);
  console.log(`NFT Symbol:   ${NFT_SYMBOL}`);
  console.log(`Contract URI: ${CONTRACT_URI}`);
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

console.log("\n[1/4] Deploying AssetNFT implementation...");
const impl = await viem.deployContract("AssetNFT");
console.log(`  Implementation: ${impl.address}`);

console.log("[2/4] Encoding initialize calldata...");
const initData = encodeFunctionData({
  abi: impl.abi,
  functionName: "initialize",
  args: [deployerAddress, NFT_NAME, NFT_SYMBOL, CONTRACT_URI],
});

console.log("[3/4] Deploying ERC1967 proxy...");
const proxy = await viem.deployContract("ERC1967ProxyHelper", [
  impl.address,
  initData,
]);
console.log(`  Proxy: ${proxy.address}`);

console.log("[4/4] Verifying deployment...");
const nft = await viem.getContractAt("AssetNFT", proxy.address);
const actualName = await nft.read.name();
const actualSymbol = await nft.read.symbol();
const actualContractURI = await nft.read.contractURI();

if (
  actualName !== NFT_NAME ||
  actualSymbol !== NFT_SYMBOL ||
  actualContractURI !== CONTRACT_URI
) {
  console.error("Verification failed!");
  console.error(`  name:        expected "${NFT_NAME}", got "${actualName}"`);
  console.error(
    `  symbol:      expected "${NFT_SYMBOL}", got "${actualSymbol}"`,
  );
  console.error(
    `  contractURI: expected "${CONTRACT_URI}", got "${actualContractURI}"`,
  );
  process.exit(1);
}

console.log("\n=== Deployment Successful ===");
console.log(`Network:        ${connection.networkName} (chainId: ${chainId})`);
console.log(`Implementation: ${impl.address}`);
console.log(`Proxy:          ${proxy.address}`);
console.log(`Admin:          ${deployerAddress}`);
console.log(`Name:           ${actualName}`);
console.log(`Symbol:         ${actualSymbol}`);
console.log(`Contract URI:   ${actualContractURI}`);
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
    admin: deployerAddress,
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
