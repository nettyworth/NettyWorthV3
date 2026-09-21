/**
 * Produce the proof of possession that NettyVRFCoordinator.registerKey requires (audit F-04),
 * from the fulfiller's VRF key in AWS Secrets Manager, without printing, logging or writing
 * the secret.
 *
 *   node --experimental-strip-types scripts/vrf/key-possession-proof.ts \
 *     --coordinator 0x... [--chain-id 8453] [--env staging] \
 *     [--secret-id nettyworth/staging-v2-vrf-fulfiller/vrf-key] [--region us-east-1] [--profile <aws profile>] \
 *     [--out deployments/safe/vrf-staging/key-possession.json]
 *
 * The secret is fetched with the AWS CLI (`aws secretsmanager get-secret-value`), read from
 * the child's stdout pipe straight into memory, parsed (JSON field `secret_key`, the field
 * the fulfiller's task definition injects as VRF_SECRET_KEY) and used only to compute the
 * public key and the proof. Only public values are written: the public key, its keyHash,
 * the registration seed and the proof. Errors never include the secret or the CLI output.
 *
 * The output file is the input of build-safe-payloads.ts (--key-possession).
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { getAddress } from "viem";
import { parseSecretKey } from "./ecvrf.ts";
import { keyPossessionToJson, proveKeyPossession } from "./key-possession.ts";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}

function fail(msg: string): never {
  console.error(msg);
  process.exit(2);
}

const envName = arg("env") ?? "staging";
if (!/^[a-z0-9-]+$/.test(envName)) fail(`bad --env ${envName}`);
const coordinatorArg = arg("coordinator");
if (!coordinatorArg) fail("missing --coordinator (the deployed NettyVRFCoordinator)");
let coordinator: string;
try {
  coordinator = getAddress(coordinatorArg);
} catch {
  fail("--coordinator is not a valid address");
}
const chainId = BigInt(arg("chain-id") ?? "8453");
const secretId = arg("secret-id") ?? `nettyworth/${envName}-v2-vrf-fulfiller/vrf-key`;
const region = arg("region") ?? "us-east-1";
const profile = arg("profile");
const out =
  arg("out") ??
  join(dirname(fileURLToPath(import.meta.url)), "../../deployments/safe", `vrf-${envName}`, "key-possession.json");

function readSecretKey(): bigint {
  const cli = ["secretsmanager", "get-secret-value", "--secret-id", secretId, "--region", region,
    "--query", "SecretString", "--output", "text"];
  if (profile) cli.push("--profile", profile);
  let secretString: string;
  try {
    // stdout is piped into this process only; stderr (never secret) is discarded too, so a
    // CLI failure cannot echo anything. The thrown error is not printed.
    secretString = execFileSync("aws", cli, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], maxBuffer: 1 << 16 });
  } catch {
    fail(`could not read secret ${secretId} with the AWS CLI (check credentials, region and permission to GetSecretValue)`);
  }
  let field: unknown;
  try {
    field = (JSON.parse(secretString) as Record<string, unknown>).secret_key;
  } catch {
    fail(`secret ${secretId} is not JSON`);
  }
  if (typeof field !== "string") fail(`secret ${secretId} has no string field secret_key`);
  try {
    return parseSecretKey(field);
  } catch {
    fail(`secret ${secretId} field secret_key is not a valid VRF secret key`);
  }
}

const kp = proveKeyPossession(readSecretKey(), chainId, coordinator);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, keyPossessionToJson(kp));
console.log(`Key possession proof for ${secretId} (public values only):`);
console.log(`  chainId      ${kp.chainId}`);
console.log(`  coordinator  ${kp.coordinator}`);
console.log(`  publicKey    [${kp.publicKey[0]}, ${kp.publicKey[1]}]`);
console.log(`  keyHash      ${kp.keyHash}`);
console.log(`  written to   ${out}`);
console.log("Compare keyHash with the fulfiller's start-up log line \"vrf fulfiller started\" (keyHash field).");
