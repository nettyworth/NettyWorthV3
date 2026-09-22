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
 * (no modified, staged or untracked files) and everything the bytecode is built from —
 * contracts/, hardhat.config.ts, package.json, pnpm-lock.yaml — is byte-identical to
 * AUDITED_COMMIT, the commit signed off in Ivan's security audit. HEAD may carry later
 * non-build commits (a fix to this script, a deployment record). Deploy from a fresh checkout:
 *   git worktree add ../vrf-deploy <AUDITED_COMMIT> && cd ../vrf-deploy && pnpm install
 *   AUDITED_COMMIT=<sha> npx hardhat run scripts/deploy-vrf-coordinator.ts --network base
 *
 * After deploying it confirms the deployment was not front-run (created by this deployer at the
 * address its nonce fixes, owner is the Safe, on-chain runtime bytecode equal to the artifact
 * compiled from the audited source, and no foreign transaction has touched the contract),
 * records it, and verifies the source on Basescan.
 *
 * If a run dies after the transaction is sent, the contract is already deployed: re-running
 * plain would deploy a second one, so the script refuses when the record already holds the key.
 * Re-run with VRF_RESUME_TX=<hash> to pick up the existing deployment instead.
 *
 * Env:
 *   AUDITED_COMMIT          required: full 40-hex commit hash of the audited source
 *   VRF_COORDINATOR_OWNER   owner (default: protocol Safe 0xfe78…f456)
 *   VRF_DEPLOYMENT_FILE     deployments/<name>.json to record into
 *                           (default: base.staging.snapshot, the staging record)
 *   VRF_DEPLOYMENT_KEY      key within that file (default: NettyVRFCoordinator)
 *   VRF_RESUME_TX           adopt an already-sent deployment tx instead of sending a new one:
 *                           the recovery path when a run dies after the tx is on chain
 *   VRF_EXPECTED_CHAIN_ID   refuse to deploy unless the RPC reports this chain id
 *                           (default: 8453 on the base network, 84532 on baseSepolia)
 *   VRF_SKIP_VERIFY         set to 1 to skip the automatic Basescan verification
 *   BASESCAN_API_KEY        used for that verification (ETHERSCAN_API_KEY also accepted)
 */
import { network } from "hardhat";
import { getAddress, encodeAbiParameters, getContractAddress } from "viem";
import { createInterface } from "node:readline/promises";
import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { readDeployments, saveDeployment, waitForCode } from "./lib/deployments.js";

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
// Everything the deployed bytecode is built from. HEAD may carry later commits (a fix to this
// script, a deployment record) as long as every one of these is byte-identical to the audited
// commit — that is what the post-deploy bytecode compare is worth anything against.
const BUILD_INPUTS = ["contracts", "hardhat.config.ts", "package.json", "pnpm-lock.yaml"];
const head = git("rev-parse", "HEAD").toLowerCase();
if (head !== auditedCommit) {
  const drifted = BUILD_INPUTS.filter(
    (path) => git("rev-parse", `${head}:${path}`) !== git("rev-parse", `${auditedCommit}:${path}`),
  );
  if (drifted.length > 0) {
    console.error(
      `Refusing to deploy: HEAD is ${head}, not AUDITED_COMMIT ${auditedCommit}, and it changes ` +
        `what gets compiled: ${drifted.join(", ")}. Deploy from the audited commit.`,
    );
    process.exit(1);
  }
  console.log(
    `Audit gate passed: HEAD ${head} differs from audited ${auditedCommit}, but every build input\n` +
      `(${BUILD_INPUTS.join(", ")}) is byte-identical, so the compiled bytecode is the audited one.\n` +
      `Non-build changes since the audit:\n${git("log", "--oneline", `${auditedCommit}..${head}`)}`,
  );
} else {
  console.log(`Audit gate passed: clean tree at audited commit ${head}`);
}

const DEFAULT_OWNER = "0xfe78E8aa8f4B9f616e05a94604aB86A7B192f456";

const owner = getAddress(process.env.VRF_COORDINATOR_OWNER ?? DEFAULT_OWNER);
const deploymentFile = process.env.VRF_DEPLOYMENT_FILE ?? "base.staging.snapshot";
const deploymentKey = process.env.VRF_DEPLOYMENT_KEY ?? "NettyVRFCoordinator";
const resumeTx = (process.env.VRF_RESUME_TX ?? "").trim().toLowerCase();
if (resumeTx && !/^0x[0-9a-f]{64}$/.test(resumeTx)) {
  console.error(`Refusing to run: VRF_RESUME_TX ${resumeTx} is not a transaction hash.`);
  process.exit(1);
}

const connection = await network.create();
const { viem } = connection;
const publicClient = await viem.getPublicClient();
const [deployer] = await viem.getWalletClients();
const chainId = await publicClient.getChainId();
const isLive = connection.networkConfig.type === "http";

const EXPECTED_CHAIN_IDS: Record<string, number> = { base: 8453, baseSepolia: 84532 };
const expectedChainId = process.env.VRF_EXPECTED_CHAIN_ID
  ? Number(process.env.VRF_EXPECTED_CHAIN_ID)
  : EXPECTED_CHAIN_IDS[connection.networkName];
if (isLive && expectedChainId !== undefined && chainId !== expectedChainId) {
  console.error(
    `Refusing to deploy: the RPC for network "${connection.networkName}" reports chain id ${chainId}, ` +
      `expected ${expectedChainId}. Check BASE_RPC_URL.`,
  );
  process.exit(1);
}

// A re-run after a crash must never quietly deploy a second coordinator: if the target record
// already holds this key, the operator has to say which it is (resume, or a deliberate redeploy).
if (isLive && !resumeTx) {
  const existing = (await readDeployments(deploymentFile))[deploymentKey] as
    | { address?: string }
    | undefined;
  if (existing) {
    console.error(
      `Refusing to deploy: deployments/${deploymentFile}.json already has [${deploymentKey}] at ` +
        `${existing.address}.\n` +
        "If a previous run died after sending, re-run with VRF_RESUME_TX=<that tx hash>.\n" +
        "If you really mean to deploy a second coordinator, record it under a different " +
        "VRF_DEPLOYMENT_KEY.",
    );
    process.exit(1);
  }
}

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

const artifact = JSON.parse(
  await readFile(join(REPO_ROOT, "artifacts/contracts/NettyVRFCoordinator.sol/NettyVRFCoordinator.json"), "utf8"),
) as { abi: unknown[]; bytecode: `0x${string}`; deployedBytecode: string };

// A CREATE address is fixed by (deployer, nonce), so nobody can take it from us — but if
// something already lives there, our own accounting is wrong and the deploy would revert.
const pendingNonce = await publicClient.getTransactionCount({
  address: deployer.account.address,
  blockTag: "pending",
});
const predicted = getContractAddress({ from: deployer.account.address, nonce: BigInt(pendingNonce) });
if (!resumeTx) {
  const codeAtPredicted = await publicClient.getCode({ address: predicted });
  if (codeAtPredicted && codeAtPredicted !== "0x") {
    console.error(`Refusing to deploy: ${predicted} (deployer nonce ${pendingNonce}) already has code.`);
    process.exit(1);
  }
  console.log(`Deploying to ${predicted} (deployer nonce ${pendingNonce})`);
}

// deployContract returns as soon as the tx is signed and sent: no getTransaction round-trip
// that a load-balanced RPC can fail (hardhat-viem's sendDeploymentTransaction does one, and a
// node that had not yet seen the tx crashed the staging run with TransactionNotFoundError).
let deploymentTxHash: `0x${string}`;
if (resumeTx) {
  deploymentTxHash = resumeTx as `0x${string}`;
  console.log(`Resuming from deployment tx ${deploymentTxHash} (nothing new will be sent).`);
} else {
  deploymentTxHash = await deployer.deployContract({
    abi: artifact.abi,
    bytecode: artifact.bytecode,
    args: [owner],
  });
  console.log(
    `Deployment tx sent: ${deploymentTxHash}\n` +
      "If this run dies from here on, the transaction is already on chain: DO NOT re-run plain, " +
      `resume with VRF_RESUME_TX=${deploymentTxHash}`,
  );
}

// Wait for the receipt through RPC hiccups: a lagging node answers "not found" for a tx that
// is in fact mined, so keep asking until the deadline instead of dying on the first error.
async function waitForDeploymentReceipt(hash: `0x${string}`, timeoutMs = 900_000) {
  const deadline = Date.now() + timeoutMs;
  for (let attempt = 1; ; attempt++) {
    try {
      return await publicClient.waitForTransactionReceipt({
        hash,
        timeout: 120_000,
        pollingInterval: 2_000,
        retryCount: 10,
      });
    } catch (error) {
      if (Date.now() > deadline) throw error;
      console.log(
        `  still waiting for ${hash} (attempt ${attempt}: ${(error as Error).name}); retrying…`,
      );
      await new Promise((r) => setTimeout(r, 5_000));
    }
  }
}
const receipt = await waitForDeploymentReceipt(deploymentTxHash);

if (receipt.status !== "success" || !receipt.contractAddress) {
  console.error(`Deployment transaction ${deploymentTxHash} did not create a contract. Refusing to continue.`);
  process.exit(1);
}
const coordinatorAddress = getAddress(receipt.contractAddress);
if (getAddress(receipt.from) !== getAddress(deployer.account.address)) {
  console.error(`Refusing to continue: ${deploymentTxHash} was sent by ${receipt.from}, not the deployer.`);
  process.exit(1);
}
if (!resumeTx && coordinatorAddress !== getAddress(predicted)) {
  console.error(`Refusing to continue: deployed to ${coordinatorAddress}, expected ${predicted}.`);
  process.exit(1);
}
if (isLive) await waitForCode(publicClient, coordinatorAddress);

const coordinator = await viem.getContractAt("NettyVRFCoordinator", coordinatorAddress);
const onChainOwner = await coordinator.read.owner();
if (getAddress(onChainOwner) !== owner) {
  console.error(`Owner mismatch: expected ${owner}, got ${onChainOwner}`);
  process.exit(1);
}
const deployedAtBlock = receipt.blockNumber;
console.log(`NettyVRFCoordinator deployed at ${coordinatorAddress} in block ${deployedAtBlock} (owner ${onChainOwner})`);

// The runtime bytecode on chain must be exactly the artifact compiled from the
// audited commit (the contract has no immutables, so this is a byte compare).
const onChainCode = (await publicClient.getCode({ address: coordinatorAddress })) ?? "0x";
if (onChainCode.toLowerCase() !== artifact.deployedBytecode.toLowerCase()) {
  console.error("On-chain runtime bytecode does NOT match the artifact compiled from the audited commit. Do not use this deployment.");
  process.exit(1);
}
console.log("On-chain runtime bytecode matches the artifact compiled from the audited commit.");

// Nothing may have touched the coordinator between its constructor and this check. Ownership is
// set in the constructor (there is no initialize() to race), so the only event that may exist is
// our own OwnershipTransferred; anything else means somebody got in first.
const logsSinceDeploy = await publicClient.getLogs({
  address: coordinatorAddress,
  fromBlock: deployedAtBlock,
  toBlock: "latest",
});
const foreign = logsSinceDeploy.filter(
  (log) => log.transactionHash?.toLowerCase() !== deploymentTxHash.toLowerCase(),
);
if (foreign.length > 0) {
  console.error(
    `Refusing to continue: ${foreign.length} event(s) at ${coordinatorAddress} came from other ` +
      `transactions (first: ${foreign[0].transactionHash} in block ${foreign[0].blockNumber}). ` +
      "Investigate before using this deployment.",
  );
  process.exit(1);
}
console.log(
  `Not front-run: created by ${receipt.from} at the address its nonce fixes, owner is the Safe, ` +
    `and no transaction other than ${deploymentTxHash} has touched it.`,
);

const ctorArgs = encodeAbiParameters([{ type: "address" }], [owner]);
const deployedAt = new Date(
  Number((await publicClient.getBlock({ blockNumber: deployedAtBlock })).timestamp) * 1000,
).toISOString();

// Record before verifying: verification is a nice-to-have that talks to a third party, and its
// failure must never be the reason the address of a live contract goes unrecorded.
async function record(verification: string) {
  if (!isLive) return;
  await saveDeployment(deploymentFile, deploymentKey, {
    address: coordinatorAddress,
    owner,
    deployer: deployer.account.address,
    auditedCommit: auditedCommit,
    deployedAtBlock: deployedAtBlock.toString(),
    deploymentTx: deploymentTxHash,
    deployedAt,
    verification,
    verifier: "@chainlink/contracts@1.1.0 src/v0.8/vrf/VRF.sol (MIT)",
  });
}
await record("pending");
if (isLive) console.log(`Recorded in deployments/${deploymentFile}.json`);

// Verify on Basescan through forge: hardhat's verify task reads the API key from
// config.verify.etherscan, and this repo still declares it under the Hardhat 2 top-level
// `etherscan` key, so it sees an empty key. forge takes it from the environment.
function verifyOnBasescan(): string {
  const apiKey = process.env.BASESCAN_API_KEY ?? process.env.ETHERSCAN_API_KEY;
  if (process.env.VRF_SKIP_VERIFY === "1") return "skipped (VRF_SKIP_VERIFY=1)";
  if (!apiKey) return "skipped (no BASESCAN_API_KEY)";
  try {
    console.log("\nVerifying on Basescan…");
    execFileSync(
      "forge",
      [
        "verify-contract",
        coordinatorAddress,
        "contracts/NettyVRFCoordinator.sol:NettyVRFCoordinator",
        "--verifier",
        "etherscan",
        // chainid must be in the query string: forge does not add it to a custom verifier URL.
        "--verifier-url",
        `https://api.etherscan.io/v2/api?chainid=${chainId}`,
        "--chain",
        String(chainId),
        "--watch",
        "--constructor-args",
        ctorArgs,
      ],
      // The key goes through the environment, not argv, so it stays out of the process list.
      { cwd: REPO_ROOT, stdio: "inherit", env: { ...process.env, ETHERSCAN_API_KEY: apiKey } },
    );
    return "verified on Basescan";
  } catch (error) {
    console.error(`Basescan verification failed: ${(error as Error).message}`);
    return "FAILED — verify by hand";
  }
}
const verification = isLive ? verifyOnBasescan() : "skipped (simulated network)";
await record(verification);
console.log(`Verification: ${verification}`);
console.log(`
Confirm https://basescan.org/address/${coordinatorAddress}#code shows the verified source and that it matches:
  git show ${auditedCommit}:contracts/NettyVRFCoordinator.sol
If verification did not pass above, run it by hand from this checkout:
  forge verify-contract ${coordinatorAddress} contracts/NettyVRFCoordinator.sol:NettyVRFCoordinator \\
    --verifier etherscan --verifier-url "https://api.etherscan.io/v2/api?chainid=${chainId}" \\
    --etherscan-api-key "$BASESCAN_API_KEY" --chain ${chainId} --watch --constructor-args ${ctorArgs}

Next:
  1. Proof of possession from the fulfiller's VRF key (reads Secrets Manager, prints public values only):
     node --experimental-strip-types scripts/vrf/key-possession-proof.ts --coordinator ${coordinatorAddress}
  2. Safe batches (keyHash must equal the "vrf fulfiller started" log line's keyHash):
     node --experimental-strip-types scripts/vrf/build-safe-payloads.ts --coordinator ${coordinatorAddress} \\
       --key-possession deployments/safe/vrf-staging/key-possession.json --fulfiller-key-hash <keyHash> --simulate
  3. Drain / recovery checks scan from block ${deployedAtBlock}:
     node --experimental-strip-types scripts/vrf/check-pending.ts --coordinator ${coordinatorAddress} --from-block ${deployedAtBlock}`);
