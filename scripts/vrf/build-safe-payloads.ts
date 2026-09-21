/**
 * Build Safe Transaction Builder batches for the in-house VRF switch and rollback (WOR-3306).
 *
 *   node --experimental-strip-types scripts/vrf/build-safe-payloads.ts \
 *     --coordinator 0x... --key-possession <file> --fulfiller-key-hash 0x... \
 *     [--env staging|prod] [--fulfiller-a 0x... --fulfiller-b 0x...] [--simulate] [--rpc <url>] [--out dir]
 *
 * --key-possession is the JSON written by key-possession-proof.ts (public key + registerKey
 * proof of possession, built from the fulfiller's VRF key in Secrets Manager).
 * --fulfiller-key-hash is the keyHash the running fulfiller logs at start-up ("vrf fulfiller
 * started"); the build refuses unless it equals the registered key's keyHash, so the Safe can
 * only register the key the fulfiller actually proves with (audit F-04).
 * --simulate eth_calls every call of batch 01 from the Safe against the deployed coordinator
 * (read-only; no keys, no transactions) and refuses if any would revert.
 *
 * Writes one JSON per Safe transaction into deployments/safe/vrf-<env>/, in execution order:
 *   01-coordinator-setup.json  coordinator.registerKey(pk, possession proof)
 *                              + coordinator.setRouter(router, true)
 *                              + coordinator.setFulfiller(wallet A, true) + setFulfiller(wallet B, true)
 *   02-pause.json              machine.pause()
 *   (drain: node --experimental-strip-types scripts/vrf/check-pending.ts --router <router>)
 *   03-switch.json             router.setVRFCoordinator(coordinator)
 *                              + router.setRequestConfirmations(1) + machine.unpause()
 *   rollback-01-pause.json     machine.pause()
 *   (drain: check-pending.ts --coordinator <coordinator>)
 *   rollback-02-switch.json    router.setVRFCoordinator(Chainlink)
 *                              + router.setRequestConfirmations(<previous>) + machine.unpause()
 * Load each file in Safe{Wallet} > Apps > Transaction Builder > drag and drop.
 * registerKey takes a struct, so its entry carries raw calldata (`data`); the batch description
 * lists the key hash to check against, and Safe decodes the call once the coordinator source
 * is verified on Basescan.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, encodeFunctionData, getAddress, http, isAddress, zeroAddress, type Hex } from "viem";
import { base } from "viem/chains";
import { checkKeyPossession, keyPossessionFromJson } from "./key-possession.ts";

const SAFE = "0xfe78E8aa8f4B9f616e05a94604aB86A7B192f456";
const CHAINLINK_COORDINATOR = "0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634";
const CHAIN_ID = 8453n;

const ENVS = {
  staging: {
    router: "0xeA3aDEac6b82b9852a140E642BC10135638653E1",
    machine: "0x46999a9D321df9e752eCc007f5F67D2981183109",
    previousConfirmations: 3,
    // Gas wallets of the two staging-v2-vrf-fulfiller tasks (A and B).
    fulfillers: ["0xDB968Dd4d02A8F2FE66205fB000125c8B3e86442", "0x440F9c1dd178C7ff5595E6471B48A7BF7d53592C"],
  },
  prod: {
    router: "0x4aD5C628030546D12754F608081a6256D6c5FDc9",
    machine: "0x8a021c02Ac5233164D7c44d87a344623A49197c5",
    previousConfirmations: 3,
    fulfillers: [] as string[], // not provisioned yet: pass --fulfiller-a and --fulfiller-b
  },
} as const;

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function fail(msg: string): never {
  console.error(msg);
  process.exit(2);
}

function required(name: string): string {
  const v = arg(name);
  if (!v) fail(`missing --${name}`);
  return v;
}

function address(name: string, value: string): string {
  if (!isAddress(value, { strict: false })) fail(`--${name} ${value} is not an address`);
  const a = getAddress(value);
  if (a === zeroAddress) fail(`--${name} must not be the zero address`);
  return a;
}

const envName = (arg("env") ?? "staging") as keyof typeof ENVS;
if (!(envName in ENVS)) fail(`unknown --env ${envName}`);
const env = ENVS[envName];
const coordinator = address("coordinator", required("coordinator"));

// Key: proof of possession for THIS coordinator on Base, and the fulfiller's own key.
let kp;
try {
  kp = keyPossessionFromJson(readFileSync(required("key-possession"), "utf8"));
  checkKeyPossession(kp, CHAIN_ID, coordinator);
} catch (err) {
  fail(`--key-possession rejected: ${err instanceof Error ? err.message : String(err)}`);
}
const keyHash = kp.keyHash.toLowerCase();
const fulfillerKeyHash = required("fulfiller-key-hash").toLowerCase();
if (!/^0x[0-9a-f]{64}$/.test(fulfillerKeyHash)) fail("--fulfiller-key-hash must be 32 bytes of hex");
if (fulfillerKeyHash !== keyHash) {
  fail(`keyHash mismatch: the key to register is ${keyHash} but the fulfiller proves with ${fulfillerKeyHash}. Refusing.`);
}
const pk: [bigint, bigint] = [BigInt(kp.publicKey[0]), BigInt(kp.publicKey[1])];

const fulfillerA = address("fulfiller-a", arg("fulfiller-a") ?? env.fulfillers[0] ?? fail("missing --fulfiller-a"));
const fulfillerB = address("fulfiller-b", arg("fulfiller-b") ?? env.fulfillers[1] ?? fail("missing --fulfiller-b"));
if (fulfillerA === fulfillerB) fail("fulfiller wallets A and B must differ");

const outDir =
  arg("out") ??
  join(dirname(fileURLToPath(import.meta.url)), "../../deployments/safe", `vrf-${envName}`);

const PROOF_COMPONENTS = [
  { name: "pk", type: "uint256[2]" },
  { name: "gamma", type: "uint256[2]" },
  { name: "c", type: "uint256" },
  { name: "s", type: "uint256" },
  { name: "seed", type: "uint256" },
  { name: "uWitness", type: "address" },
  { name: "cGammaWitness", type: "uint256[2]" },
  { name: "sHashWitness", type: "uint256[2]" },
  { name: "zInv", type: "uint256" },
] as const;
const COORDINATOR_ABI = [
  {
    type: "function",
    name: "registerKey",
    stateMutability: "nonpayable",
    inputs: [
      { name: "publicKey", type: "uint256[2]" },
      { name: "proof", type: "tuple", components: PROOF_COMPONENTS },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setRouter",
    stateMutability: "nonpayable",
    inputs: [
      { name: "router", type: "address" },
      { name: "authorized", type: "bool" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "setFulfiller",
    stateMutability: "nonpayable",
    inputs: [
      { name: "fulfiller", type: "address" },
      { name: "allowed", type: "bool" },
    ],
    outputs: [],
  },
] as const;

const p = kp.proof;
const registerKeyData = encodeFunctionData({
  abi: COORDINATOR_ABI,
  functionName: "registerKey",
  args: [
    pk,
    {
      pk: [p.pk[0], p.pk[1]],
      gamma: [p.gamma[0], p.gamma[1]],
      c: p.c,
      s: p.s,
      seed: p.seed,
      uWitness: getAddress(p.uWitness),
      cGammaWitness: [p.cGammaWitness[0], p.cGammaWitness[1]],
      sHashWitness: [p.sHashWitness[0], p.sHashWitness[1]],
      zInv: p.zInv,
    },
  ],
});
const setRouterData = encodeFunctionData({ abi: COORDINATOR_ABI, functionName: "setRouter", args: [getAddress(env.router), true] });
const setFulfillerData = (w: string) =>
  encodeFunctionData({ abi: COORDINATOR_ABI, functionName: "setFulfiller", args: [getAddress(w), true] });

type Input = { internalType: string; name: string; type: string };
interface BuilderTx {
  to: string;
  value: "0";
  data: Hex | null;
  contractMethod: { inputs: Input[]; name: string; payable: false } | null;
  contractInputsValues: Record<string, string> | null;
}

function tx(to: string, name: string, inputs: Input[] = [], values: Record<string, string> = {}): BuilderTx {
  return {
    to: getAddress(to),
    value: "0",
    data: null,
    contractMethod: { inputs, name, payable: false },
    contractInputsValues: inputs.length ? values : null,
  };
}

/** A call given as raw calldata (for struct arguments the builder UI cannot express). */
function rawTx(to: string, data: Hex): BuilderTx {
  return { to: getAddress(to), value: "0", data, contractMethod: null, contractInputsValues: null };
}

function batch(file: string, name: string, description: string, transactions: BuilderTx[]): void {
  const body = {
    version: "1.0",
    chainId: "8453",
    createdAt: Date.now(),
    meta: {
      name,
      description,
      txBuilderVersion: "1.16.5",
      createdFromSafeAddress: SAFE,
      createdFromOwnerAddress: "",
    },
    transactions,
  };
  writeFileSync(join(outDir, file), JSON.stringify(body, null, 2) + "\n");
  console.log(`  ${file}: ${transactions.map((t) => t.contractMethod?.name ?? `raw ${t.data?.slice(0, 10)}`).join(" + ")}`);
}

const addr = (name: string): Input => ({ internalType: "address", name, type: "address" });
const setVRF = (c: string) => tx(env.router, "setVRFCoordinator", [addr("newCoordinator")], { newCoordinator: c });
const setConf = (n: number) =>
  tx(env.router, "setRequestConfirmations", [{ internalType: "uint16", name: "confirmations", type: "uint16" }], {
    confirmations: String(n),
  });
const pause = tx(env.machine, "pause");
const unpause = tx(env.machine, "unpause");

// Optional pre-flight: every call of batch 01 must succeed as the Safe against the deployed
// coordinator (proves the owner, the possession proof, the router and the fulfiller inputs).
if (process.argv.includes("--simulate")) {
  const rpc = arg("rpc") ?? process.env.BASE_RPC_URL ?? "https://mainnet.base.org";
  const client = createPublicClient({ chain: base, transport: http(rpc) });
  if (BigInt(await client.getChainId()) !== CHAIN_ID) fail(`--rpc is not Base mainnet (chain ${CHAIN_ID})`);
  const calls: [string, Hex][] = [
    ["registerKey", registerKeyData],
    ["setRouter", setRouterData],
    ["setFulfiller(A)", setFulfillerData(fulfillerA)],
    ["setFulfiller(B)", setFulfillerData(fulfillerB)],
  ];
  for (const [name, data] of calls) {
    try {
      // eslint-disable-next-line no-await-in-loop
      await client.call({ account: SAFE, to: coordinator as Hex, data });
    } catch (err) {
      fail(`simulation of ${name} from the Safe reverted: ${err instanceof Error ? err.message.split("\n")[0] : String(err)}`);
    }
    console.log(`  simulated ${name} from the Safe: ok`);
  }
}

mkdirSync(outDir, { recursive: true });
console.log(`Safe batches for ${envName} -> ${outDir}`);
console.log(`  coordinator ${coordinator}`);
console.log(`  keyHash     ${keyHash} (equals the fulfiller's keyHash)`);
console.log(`  fulfillers  A ${fulfillerA}, B ${fulfillerB}`);

batch(
  "01-coordinator-setup.json",
  `VRF ${envName} 1/3: coordinator setup`,
  `On NettyVRFCoordinator ${coordinator}: registerKey (keyHash ${keyHash}, with proof of possession), authorize router ${env.router}, allow fulfillers A ${fulfillerA} and B ${fulfillerB}. No effect on users until 03.`,
  [
    rawTx(coordinator, registerKeyData),
    tx(coordinator, "setRouter", [addr("router"), { internalType: "bool", name: "authorized", type: "bool" }], {
      router: env.router,
      authorized: "true",
    }),
    ...[fulfillerA, fulfillerB].map((w) =>
      tx(coordinator, "setFulfiller", [addr("fulfiller"), { internalType: "bool", name: "allowed", type: "bool" }], {
        fulfiller: w,
        allowed: "true",
      }),
    ),
  ],
);
batch(
  "02-pause.json",
  `VRF ${envName} 2/3: pause machine`,
  `Pause PackMachine ${env.machine}. Then wait until check-pending.ts --router ${env.router} reports no pending Chainlink requests.`,
  [pause],
);
batch(
  "03-switch.json",
  `VRF ${envName} 3/3: switch to in-house VRF and unpause`,
  `Point router ${env.router} at NettyVRFCoordinator ${coordinator}, set requestConfirmations to 1, unpause the machine.`,
  [setVRF(coordinator), setConf(1), unpause],
);
batch(
  "rollback-01-pause.json",
  `VRF ${envName} rollback 1/2: pause machine`,
  `Pause PackMachine ${env.machine}. Then wait until check-pending.ts --coordinator ${coordinator} reports no pending in-house requests.`,
  [pause],
);
batch(
  "rollback-02-switch.json",
  `VRF ${envName} rollback 2/2: back to Chainlink and unpause`,
  `Point router ${env.router} back at Chainlink ${CHAINLINK_COORDINATOR}, restore requestConfirmations ${env.previousConfirmations}, unpause.`,
  [setVRF(CHAINLINK_COORDINATOR), setConf(env.previousConfirmations), unpause],
);
