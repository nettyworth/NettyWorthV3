/**
 * Deploy NettyVRFCoordinator (in-house VRF, WOR-3306).
 *
 *   npx hardhat run scripts/deploy-vrf-coordinator.ts --network base
 *
 * The deployer key (BASE_PRIVATE_KEY) only pays gas: ownership goes straight to the Safe in
 * the constructor, so the deployer holds no power over the coordinator afterwards. The
 * public key (with its proof of possession), router authorization and fulfiller allowlist are
 * set by the Safe afterwards via the Transaction Builder batch produced by
 * scripts/vrf/build-safe-payloads.ts. The deployment block (from the receipt) is recorded as
 * deployedAtBlock for check-pending.ts.
 *
 * AUDIT GATE: refuses to run unless the git working tree is completely clean
 * (no modified, staged or untracked files) and HEAD is exactly AUDITED_COMMIT,
 * the commit signed off in Ivan's security audit. Deploy from a fresh checkout:
 *   git worktree add ../vrf-deploy <AUDITED_COMMIT> && cd ../vrf-deploy && pnpm install
 *   AUDITED_COMMIT=<sha> npx hardhat run scripts/deploy-vrf-coordinator.ts --network base
 * After deploying it checks the on-chain runtime bytecode against the compiled
 * artifact and prints the Basescan verification commands.
 *
 * Env:
 *   AUDITED_COMMIT          required: full 40-hex commit hash of the audited source
 *   VRF_COORDINATOR_OWNER   owner (default: protocol Safe 0xfe78…f456)
 *   VRF_DEPLOYMENT_FILE     deployments/<name>.json to record into
 *                           (default: base.staging.snapshot, the staging record)
 *   VRF_DEPLOYMENT_KEY      key within that file (default: NettyVRFCoordinator)
 */
import { network } from "hardhat";
import { getAddress, encodeAbiParameters } from "viem";
import { createInterface } from "node:readline/promises";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { saveDeployment, waitForCode } from "./lib/deployments.js";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

// ─── Audit gate (before anything is compiled, signed or sent) ────────────────
function git(...args: string[]): string {
  return execFileSync("git", args, { cwd: REPO_ROOT, encoding: "utf8" }).trim();
}
const auditedCommit = (process.env.AUDITED_COMMIT ?? "").trim().toLowerCase();
if (!/^[0-9a-f]{40}$/.test(auditedCommit)) {
  console.error(
    "Refusing to deploy: set AUDITED_COMMIT to the full 40-hex commit hash signed off in the security audit.",
  );
  process.exit(1);
}
const dirty = git("status", "--porcelain", "--untracked-files=all");
if (dirty) {
  console.error(
    "Refusing to deploy: the working tree is not clean. Deploy from a fresh checkout of the audited commit\n" +
      `(git worktree add <dir> ${auditedCommit}). Offending paths:\n${dirty}`,
  );
  process.exit(1);
}
const head = git("rev-parse", "HEAD").toLowerCase();
if (head !== auditedCommit) {
  console.error(`Refusing to deploy: HEAD is ${head}, not AUDITED_COMMIT ${auditedCommit}.`);
  process.exit(1);
}
console.log(`Audit gate passed: clean tree at audited commit ${head}`);

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
  console.log(`Source:      audited commit ${head}`);
  console.log("======================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  if (answer.toLowerCase() !== "yes") process.exit(0);
}

// sendDeploymentTransaction (not deployContract) so the deployment block comes from the
// receipt: check-pending.ts --coordinator scans from exactly that block (audit F-03).
const { contract: coordinator, deploymentTransaction } = await viem.sendDeploymentTransaction(
  "NettyVRFCoordinator",
  [owner],
);
const receipt = await publicClient.waitForTransactionReceipt({ hash: deploymentTransaction.hash });
if (receipt.status !== "success" || !receipt.contractAddress || getAddress(receipt.contractAddress) !== getAddress(coordinator.address)) {
  console.error(`Deployment transaction ${deploymentTransaction.hash} did not create the coordinator. Refusing to continue.`);
  process.exit(1);
}
if (isLive) await waitForCode(publicClient, coordinator.address);

const onChainOwner = await coordinator.read.owner();
if (getAddress(onChainOwner) !== owner) {
  console.error(`Owner mismatch: expected ${owner}, got ${onChainOwner}`);
  process.exit(1);
}
const deployedAtBlock = receipt.blockNumber;
console.log(`NettyVRFCoordinator deployed at ${coordinator.address} in block ${deployedAtBlock} (owner ${onChainOwner})`);

// The runtime bytecode on chain must be exactly the artifact compiled from the
// audited commit (the contract has no immutables, so this is a byte compare).
const artifact = JSON.parse(
  await readFile(join(REPO_ROOT, "artifacts/contracts/NettyVRFCoordinator.sol/NettyVRFCoordinator.json"), "utf8"),
) as { deployedBytecode: string };
const onChainCode = (await publicClient.getCode({ address: coordinator.address })) ?? "0x";
if (onChainCode.toLowerCase() !== artifact.deployedBytecode.toLowerCase()) {
  console.error("On-chain runtime bytecode does NOT match the artifact compiled from the audited commit. Do not use this deployment.");
  process.exit(1);
}
console.log("On-chain runtime bytecode matches the artifact compiled from the audited commit.");

if (isLive) {
  await saveDeployment(deploymentFile, deploymentKey, {
    address: coordinator.address,
    owner,
    deployer: deployer.account.address,
    auditedCommit: head,
    deployedAtBlock: deployedAtBlock.toString(),
    deploymentTx: deploymentTransaction.hash,
    deployedAt: new Date().toISOString(),
    verifier: "@chainlink/contracts@1.1.0 src/v0.8/vrf/VRF.sol (MIT)",
  });
  console.log(`Recorded in deployments/${deploymentFile}.json`);
}

const ctorArgs = encodeAbiParameters([{ type: "address" }], [owner]);
console.log(`
Verify the deployed source on Basescan (run from this same clean checkout at ${head}):
  npx hardhat verify --network ${connection.networkName} ${coordinator.address} ${owner}
or, with the repo's usual forge flow:
  forge verify-contract ${coordinator.address} contracts/NettyVRFCoordinator.sol:NettyVRFCoordinator \\
    --verifier etherscan --verifier-url https://api.etherscan.io/v2/api --etherscan-api-key "$BASESCAN_API_KEY" \\
    --chain ${chainId} --watch --constructor-args ${ctorArgs}
Then confirm https://basescan.org/address/${coordinator.address}#code shows the verified source and that it matches:
  git show ${head}:contracts/NettyVRFCoordinator.sol

Next:
  1. Proof of possession from the fulfiller's VRF key (reads Secrets Manager, prints public values only):
     node --experimental-strip-types scripts/vrf/key-possession-proof.ts --coordinator ${coordinator.address}
  2. Safe batches (keyHash must equal the "vrf fulfiller started" log line's keyHash):
     node --experimental-strip-types scripts/vrf/build-safe-payloads.ts --coordinator ${coordinator.address} \\
       --key-possession deployments/safe/vrf-staging/key-possession.json --fulfiller-key-hash <keyHash> --simulate
  3. Drain / recovery checks scan from block ${deployedAtBlock}:
     node --experimental-strip-types scripts/vrf/check-pending.ts --coordinator ${coordinator.address} --from-block ${deployedAtBlock}`);
