/**
 * Read one string field of a JSON secret in AWS Secrets Manager, straight into memory.
 * Shared by key-possession-proof.ts (the VRF key) and fulfiller-preflight.ts (the gas keys).
 *
 * SECURITY: the secret is fetched with the AWS CLI (`aws secretsmanager get-secret-value`).
 * Only the secret id, region and profile are in argv; the value comes back on the child's
 * stdout pipe into this process only; stderr is discarded (a CLI failure cannot echo
 * anything); output is capped at 64 KiB. Every failure throws SecretReadError with a fixed
 * message naming only the secret id and field, never the value or the CLI output, and the
 * underlying error is not chained. Callers must not print, log or write what this returns.
 */
import { execFileSync } from "node:child_process";

export class SecretReadError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SecretReadError";
  }
}

export interface SecretSource {
  secretId: string;
  region: string;
  profile?: string;
}

const SECRET_ID = /^[A-Za-z0-9/_+=.@-]{1,512}$/;
const REGION = /^[a-z]{2}(-[a-z]+)+-\d$/;
const PROFILE = /^[A-Za-z0-9_.-]{1,128}$/;

export function readSecretField(src: SecretSource, field: string): string {
  if (!SECRET_ID.test(src.secretId)) throw new SecretReadError("invalid secret id");
  if (!REGION.test(src.region)) throw new SecretReadError(`invalid region for secret ${src.secretId}`);
  if (src.profile !== undefined && !PROFILE.test(src.profile)) throw new SecretReadError(`invalid profile for secret ${src.secretId}`);
  const cli = ["secretsmanager", "get-secret-value", "--secret-id", src.secretId, "--region", src.region,
    "--query", "SecretString", "--output", "text"];
  if (src.profile) cli.push("--profile", src.profile);
  let secretString: string;
  try {
    secretString = execFileSync("aws", cli, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], maxBuffer: 1 << 16 });
  } catch {
    throw new SecretReadError(
      `could not read secret ${src.secretId} with the AWS CLI (check credentials, region and permission to GetSecretValue)`,
    );
  }
  let value: unknown;
  try {
    value = (JSON.parse(secretString) as Record<string, unknown>)[field];
  } catch {
    throw new SecretReadError(`secret ${src.secretId} is not JSON`);
  }
  if (typeof value !== "string") throw new SecretReadError(`secret ${src.secretId} has no string field ${field}`);
  return value;
}
