/**
 * Deploy NettyVRFCoordinator (in-house VRF, WOR-3306).
 *
 *   npx hardhat run scripts/deploy-vrf-coordinator.ts --network base
 *
 * The deployer key (BASE_PRIVATE_KEY) only pays gas: ownership goes straight to the Safe in
 * the constructor, so the deployer holds no power over the coordinator afterwards. The
 * public key and router authorization are set by the Safe afterwards via the Transaction
 * Builder batch produced by scripts/vrf/build-safe-payloads.ts.
 *
 * Env:
 *   VRF_COORDINATOR_OWNER   owner (default: protocol Safe 0xfe78…f456)
 *   VRF_DEPLOYMENT_FILE     deployments/<name>.json to record into
 *                           (default: base.staging.snapshot, the staging record)
 *   VRF_DEPLOYMENT_KEY      key within that file (default: NettyVRFCoordinator)
 */
import { network } from "hardhat";
import { getAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { saveDeployment, waitForCode } from "./lib/deployments.js";

const DEFAULT_OWNER = "0xfe78E8aa8f4B9f616e05a94604aB86A7B192f456";

const owner = getAddress(process.env.VRF_COORDINATOR_OWNER ?? DEFAULT_OWNER);
const deploymentFile = process.env.VRF_DEPLOYMENT_FILE ?? "base.staging.snapshot";
const deploymentKey = process.env.VRF_DEPLOYMENT_KEY ?? "NettyVRFCoordinator";

const connection = await network.create();
const { viem } = connection;
const publicClient = await viem.getPublicClient();
const [deployer] = await viem.getWalletClients();
const chainId = await publicClient.getChainId();
const isLive = connection.networkConfig.type === "http";

if (isLive) {
  const ownerCode = await publicClient.getCode({ address: owner });
  if (!ownerCode || ownerCode === "0x") {
    console.error(`Owner ${owner} has no code; expected the Safe. Refusing to deploy.`);
    process.exit(1);
  }
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== NettyVRFCoordinator deployment ===");
  console.log(`Network:     ${connection.networkName} (chainId ${chainId})`);
  console.log(`Deployer:    ${deployer.account.address} (pays gas only)`);
  console.log(`Owner:       ${owner}`);
  console.log(`Record into: deployments/${deploymentFile}.json [${deploymentKey}]`);
  console.log("======================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  if (answer.toLowerCase() !== "yes") process.exit(0);
}

const coordinator = await viem.deployContract("NettyVRFCoordinator", [owner]);
if (isLive) await waitForCode(publicClient, coordinator.address);

const onChainOwner = await coordinator.read.owner();
if (getAddress(onChainOwner) !== owner) {
  console.error(`Owner mismatch: expected ${owner}, got ${onChainOwner}`);
  process.exit(1);
}
const blockNumber = await publicClient.getBlockNumber();
console.log(`NettyVRFCoordinator deployed at ${coordinator.address} (owner ${onChainOwner})`);

if (isLive) {
  await saveDeployment(deploymentFile, deploymentKey, {
    address: coordinator.address,
    owner,
    deployer: deployer.account.address,
    deployedAtBlock: blockNumber.toString(),
    deployedAt: new Date().toISOString(),
    verifier: "@chainlink/contracts@1.1.0 src/v0.8/vrf/VRF.sol (MIT)",
  });
  console.log(`Recorded in deployments/${deploymentFile}.json`);
}
console.log(
  "\nNext: node --experimental-strip-types scripts/vrf/build-safe-payloads.ts " +
    `--coordinator ${coordinator.address} --pk-x <x> --pk-y <y>`,
);
