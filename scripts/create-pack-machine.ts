import { network } from "hardhat";
import { getAddress, parseEventLogs } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ─── Pack parameters (override via environment variables) ─────────────────────
// PRICE_PER_PACK: USDC cost per pack in raw units (6 decimals). e.g. "10000000" = 10 USDC
if (!process.env.PRICE_PER_PACK) {
  console.error(
    "PRICE_PER_PACK env var is required (USDC cost per pack in 6-decimal raw units, e.g. 10000000 = 10 USDC).",
  );
  process.exit(1);
}
const PRICE_PER_PACK = BigInt(process.env.PRICE_PER_PACK);

// CARDS_PER_PACK: number of NFT cards dispensed per pack open (uint8).
if (!process.env.CARDS_PER_PACK) {
  console.error(
    "CARDS_PER_PACK env var is required (number of cards per pack open, e.g. 3).",
  );
  process.exit(1);
}
const CARDS_PER_PACK = Number(process.env.CARDS_PER_PACK);
if (CARDS_PER_PACK < 1 || CARDS_PER_PACK > 255) {
  console.error("CARDS_PER_PACK must be between 1 and 255.");
  process.exit(1);
}

// START_TIME: unix timestamp (uint40) from which pack opens are permitted.
// Defaults to the current time (opens immediately).
const START_TIME = process.env.START_TIME
  ? Number(process.env.START_TIME)
  : Math.floor(Date.now() / 1000);

// ─── Confirmation prompt (live networks only) ─────────────────────────────────
async function confirm(
  networkName: string,
  chainId: number,
  deployer: string,
  factoryProxy: string,
  vrfRouterProxy: string,
  buybackProxy: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== PackMachine Creation Summary ===");
  console.log(`Network:             ${networkName}`);
  console.log(`Chain ID:            ${chainId}`);
  console.log(`Deployer:            ${deployer}`);
  console.log(`PackMachineFactory:  ${factoryProxy}`);
  console.log(`PackVRFRouter:       ${vrfRouterProxy}`);
  console.log(`BuybackPool:         ${buybackProxy}`);
  console.log(`Price Per Pack:      ${PRICE_PER_PACK} (raw units)`);
  console.log(`Cards Per Pack:      ${CARDS_PER_PACK}`);
  console.log(`Start Time:          ${START_TIME} (unix)`);
  console.log("=====================================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  return answer.toLowerCase() === "yes";
}

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [deployerClient] = await viem.getWalletClients();
const deployerAddress = deployerClient.account.address;
const chainId = await publicClient.getChainId();

// ─── Deployments JSON helpers ─────────────────────────────────────────────────
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

// ─── Resolve PACK_MACHINE_FACTORY ────────────────────────────────────────────
let factoryProxy: `0x${string}`;
if (process.env.PACK_MACHINE_FACTORY) {
  factoryProxy = getAddress(process.env.PACK_MACHINE_FACTORY) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
  const data = await readDeployments();
  const entry = data["PackMachineFactory"] as
    | Record<string, unknown>
    | undefined;
  if (!entry?.proxy) {
    console.error(
      "PackMachineFactory proxy not found. Set PACK_MACHINE_FACTORY env var or run deploy-pack-machine first.",
    );
    process.exit(1);
  }
  factoryProxy = getAddress(entry.proxy as string) as `0x${string}`;
} else {
  console.error(
    "Set PACK_MACHINE_FACTORY env var to the deployed PackMachineFactory proxy address.",
  );
  process.exit(1);
}

// ─── Resolve PACK_VRF_ROUTER ──────────────────────────────────────────────────
let vrfRouterProxy: `0x${string}`;
if (process.env.PACK_VRF_ROUTER) {
  vrfRouterProxy = getAddress(process.env.PACK_VRF_ROUTER) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
  const data = await readDeployments();
  const entry = data["PackVRFRouter"] as Record<string, unknown> | undefined;
  if (!entry?.proxy) {
    console.error(
      "PackVRFRouter proxy not found. Set PACK_VRF_ROUTER env var or run deploy-pack-machine first.",
    );
    process.exit(1);
  }
  vrfRouterProxy = getAddress(entry.proxy as string) as `0x${string}`;
} else {
  console.error(
    "Set PACK_VRF_ROUTER env var to the deployed PackVRFRouter proxy address.",
  );
  process.exit(1);
}

// ─── Resolve BUYBACK_POOL ─────────────────────────────────────────────────────
let buybackProxy: `0x${string}`;
if (process.env.BUYBACK_POOL) {
  buybackProxy = getAddress(process.env.BUYBACK_POOL) as `0x${string}`;
} else if (connection.networkConfig.type === "http") {
  const data = await readDeployments();
  const entry = data["BuybackPool"] as Record<string, unknown> | undefined;
  if (!entry?.proxy) {
    console.error(
      "BuybackPool proxy not found. Set BUYBACK_POOL env var or run deploy-pack-machine first.",
    );
    process.exit(1);
  }
  buybackProxy = getAddress(entry.proxy as string) as `0x${string}`;
} else {
  console.error(
    "Set BUYBACK_POOL env var to the deployed BuybackPool proxy address.",
  );
  process.exit(1);
}

// ─── Confirmation on live networks ────────────────────────────────────────────
if (connection.networkConfig.type === "http") {
  const ok = await confirm(
    connection.networkName,
    chainId,
    deployerAddress,
    factoryProxy,
    vrfRouterProxy,
    buybackProxy,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

// ─── [1/3] Create PackMachine clone ──────────────────────────────────────────
console.log("\n[1/3] Creating PackMachine clone via factory...");
const factory = await viem.getContractAt("PackMachineFactory", factoryProxy);
const createHash = await factory.write.createPackMachine([
  PRICE_PER_PACK,
  CARDS_PER_PACK,
  START_TIME,
]);
const createReceipt = await publicClient.waitForTransactionReceipt({
  hash: createHash,
});

const [createLog] = parseEventLogs({
  abi: factory.abi,
  eventName: "PackMachineCreated",
  logs: createReceipt.logs,
});
if (!createLog) {
  console.error(
    "PackMachineCreated event not found in receipt — unexpected factory behaviour.",
  );
  process.exit(1);
}
const cloneAddress = createLog.args.packMachine;
console.log(`  Clone: ${cloneAddress}`);

// ─── [2/3] Register clone on PackVRFRouter ────────────────────────────────────
// Required — PackMachine._requestVRF() reverts if not authorized.
console.log("[2/3] Registering clone on PackVRFRouter...");
const vrfRouter = await viem.getContractAt("PackVRFRouter", vrfRouterProxy);
const vrfHash = await vrfRouter.write.setAuthorizedPackMachine([
  cloneAddress,
  true,
]);
await publicClient.waitForTransactionReceipt({ hash: vrfHash });
console.log(`  setAuthorizedPackMachine(${cloneAddress}, true) ✓`);

// ─── [3/3] Register clone on BuybackPool ─────────────────────────────────────
// Required for the clone to call registerToken during fulfillRandomness.
console.log("[3/3] Registering clone on BuybackPool...");
const buyback = await viem.getContractAt("BuybackPool", buybackProxy);
const buybackHash = await buyback.write.registerPackMachine([
  cloneAddress,
  true,
]);
await publicClient.waitForTransactionReceipt({ hash: buybackHash });
console.log(`  registerPackMachine(${cloneAddress}, true) ✓`);

// ─── Summary ──────────────────────────────────────────────────────────────────
console.log("\n=== PackMachine Created ===");
console.log(
  `Network:             ${connection.networkName} (chainId: ${chainId})`,
);
console.log(`Clone:               ${cloneAddress}`);
console.log(`Factory:             ${factoryProxy}`);
console.log(`Price Per Pack:      ${PRICE_PER_PACK} (raw units)`);
console.log(`Cards Per Pack:      ${CARDS_PER_PACK}`);
console.log(`Start Time:          ${START_TIME} (unix)`);
console.log(`VRF authorized:      ✓`);
console.log(`Buyback registered:  ✓`);
console.log("===========================\n");

console.log("⚠️  Remaining steps before packs can open:");
console.log(
  `  1. (Optional) Configure buyback on the clone (PACK_OPERATOR_ROLE):`,
);
console.log(`       clone.setBuybackPool(${buybackProxy})             // stays on clone`);
console.log(
  `       packRegistry.setPackBuybackAllocation(${cloneAddress}, 0, <bps>)  // e.g. 2000 = 20%`,
);
console.log(`  2. Deposit NFT inventory into the clone (PACK_OPERATOR_ROLE):`);
console.log(
  `       assetNFT.setApprovalForAll(${cloneAddress}, true)  // from token owner`,
);
console.log(`       clone.deposit(tokenIds, tiers, tokensOwner)`);
console.log(`  3. Users can open packs once inventory >= cardsPerPack.\n`);

// ─── Persist deployment record (live networks only) ───────────────────────────
if (connection.networkConfig.type === "http") {
  const outPath = join(deploymentsDir, `${connection.networkName}.json`);

  let existing: Record<string, unknown> = {};
  try {
    existing = JSON.parse(await readFile(outPath, "utf8"));
  } catch {
    // file doesn't exist yet — start fresh
  }

  // Accumulate under PackMachines array so multiple clones are preserved.
  const machines = (existing["PackMachines"] as unknown[] | undefined) ?? [];
  machines.push({
    address: cloneAddress,
    pricePerPack: PRICE_PER_PACK.toString(),
    cardsPerPack: CARDS_PER_PACK,
    startTime: START_TIME.toString(),
    factory: factoryProxy,
    createdAt: new Date().toISOString(),
  });
  existing["PackMachines"] = machines;

  await mkdir(deploymentsDir, { recursive: true });
  await writeFile(outPath, JSON.stringify(existing, null, 2) + "\n");
  console.log(
    `Deployment info saved to deployments/${connection.networkName}.json`,
  );
}
