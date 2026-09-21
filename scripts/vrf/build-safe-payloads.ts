/**
 * Build Safe Transaction Builder batches for the in-house VRF switch and rollback (WOR-3306).
 *
 *   node --experimental-strip-types scripts/vrf/build-safe-payloads.ts \
 *     --coordinator 0x... --pk-x 0x... --pk-y 0x... [--env staging|prod] [--out dir]
 *
 * Writes one JSON per Safe transaction into deployments/safe/vrf-<env>/, in execution order:
 *   01-coordinator-setup.json  coordinator.registerKey(pk) + coordinator.setRouter(router, true)
 *   02-pause.json              machine.pause()
 *   (drain: node --experimental-strip-types scripts/vrf/check-pending.ts --router <router>)
 *   03-switch.json             router.setVRFCoordinator(coordinator)
 *                              + router.setRequestConfirmations(1) + machine.unpause()
 *   rollback-01-pause.json     machine.pause()
 *   (drain: check-pending.ts --coordinator <coordinator>)
 *   rollback-02-switch.json    router.setVRFCoordinator(Chainlink)
 *                              + router.setRequestConfirmations(<previous>) + machine.unpause()
 * Load each file in Safe{Wallet} > Apps > Transaction Builder > drag and drop.
 *
 * Pure encoding: no RPC, no keys, no transactions.
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeAbiParameters, getAddress, keccak256 } from "viem";

const SAFE = "0xfe78E8aa8f4B9f616e05a94604aB86A7B192f456";
const CHAINLINK_COORDINATOR = "0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634";
const SECP256K1_P = BigInt("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F");

const ENVS = {
  staging: {
    router: "0xeA3aDEac6b82b9852a140E642BC10135638653E1",
    machine: "0x46999a9D321df9e752eCc007f5F67D2981183109",
    previousConfirmations: 3,
  },
  prod: {
    router: "0x4aD5C628030546D12754F608081a6256D6c5FDc9",
    machine: "0x8a021c02Ac5233164D7c44d87a344623A49197c5",
    previousConfirmations: 3,
  },
} as const;

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function required(name: string): string {
  const v = arg(name);
  if (!v) {
    console.error(`missing --${name}`);
    process.exit(2);
  }
  return v;
}

const envName = (arg("env") ?? "staging") as keyof typeof ENVS;
if (!(envName in ENVS)) {
  console.error(`unknown --env ${envName}`);
  process.exit(2);
}
const env = ENVS[envName];
const coordinator = getAddress(required("coordinator"));
const pkX = BigInt(required("pk-x"));
const pkY = BigInt(required("pk-y"));
if (pkX >= SECP256K1_P || pkY >= SECP256K1_P || (pkY * pkY - (pkX ** 3n + 7n)) % SECP256K1_P !== 0n) {
  console.error("public key is not on secp256k1");
  process.exit(2);
}
const keyHash = keccak256(encodeAbiParameters([{ type: "uint256[2]" }], [[pkX, pkY]]));
const outDir =
  arg("out") ??
  join(dirname(fileURLToPath(import.meta.url)), "../../deployments/safe", `vrf-${envName}`);

type Input = { internalType: string; name: string; type: string };
interface BuilderTx {
  to: string;
  value: "0";
  data: null;
  contractMethod: { inputs: Input[]; name: string; payable: false };
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
  console.log(`  ${file}: ${transactions.map((t) => t.contractMethod.name).join(" + ")}`);
}

const addr = (name: string): Input => ({ internalType: "address", name, type: "address" });
const setVRF = (c: string) => tx(env.router, "setVRFCoordinator", [addr("newCoordinator")], { newCoordinator: c });
const setConf = (n: number) =>
  tx(env.router, "setRequestConfirmations", [{ internalType: "uint16", name: "confirmations", type: "uint16" }], {
    confirmations: String(n),
  });
const pause = tx(env.machine, "pause");
const unpause = tx(env.machine, "unpause");

mkdirSync(outDir, { recursive: true });
console.log(`Safe batches for ${envName} -> ${outDir}`);
console.log(`  coordinator ${coordinator}, keyHash ${keyHash}`);

batch(
  "01-coordinator-setup.json",
  `VRF ${envName} 1/3: coordinator setup`,
  `Register VRF key ${keyHash} and authorize router ${env.router} on NettyVRFCoordinator ${coordinator}. No effect on users until 03.`,
  [
    tx(coordinator, "registerKey", [{ internalType: "uint256[2]", name: "publicKey", type: "uint256[2]" }], {
      publicKey: `[${pkX.toString()}, ${pkY.toString()}]`,
    }),
    tx(coordinator, "setRouter", [addr("router"), { internalType: "bool", name: "authorized", type: "bool" }], {
      router: env.router,
      authorized: "true",
    }),
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
