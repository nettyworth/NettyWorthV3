/**
 * Fulfiller wallet preflight for the switch batch (audit N-03). build-safe-payloads.ts runs it
 * under --simulate and writes 03-switch.json only if it passes.
 *
 * For each allowlisted fulfiller wallet (A and B) it proves, before the router is pointed at
 * the coordinator, that:
 *   1. the gas key the fulfiller task is given (Secrets Manager `private_key` field, injected as
 *      VRF_GAS_WALLET_PRIVATE_KEY) derives exactly the allowlisted address, so the allowlist and
 *      the running tasks cannot disagree; and
 *   2. the wallet holds at least the stated minimum balance, so the first requests after the
 *      switch are not left waiting on an unfunded wallet.
 *
 * SECURITY: each key is read with aws-secret.ts (stdout pipe into memory, stderr discarded),
 * parsed the way the fulfiller parses it (optional 0x prefix, 32 bytes), turned into an address
 * in memory and dropped. It is never printed, logged, written or put in an error message; only
 * the derived address (public) is reported.
 */
import { formatEther, getAddress, type Address, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { readSecretField, SecretReadError, type SecretSource } from "./aws-secret.ts";

/** Default minimum per wallet: 2.5x the low-urgency gas alarm (0.002 ETH), ~1,000 fulfilments. */
export const DEFAULT_MIN_GAS_WEI = 5_000_000_000_000_000n; // 0.005 ETH

export interface FulfillerWallet {
  label: string;
  /** The address batch 01 allowlists with setFulfiller. */
  allowlisted: Address;
  /** The secret whose `private_key` field the fulfiller task receives. */
  secret: SecretSource;
}

export class PreflightError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PreflightError";
  }
}

type FieldReader = (src: SecretSource, field: string) => string;

/** Address of a gas key as the fulfiller parses it; the key never leaves this function. */
export function addressOfGasKey(raw: string, secretId: string): Address {
  const hex = raw.trim().startsWith("0x") ? raw.trim() : `0x${raw.trim()}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(hex)) throw new PreflightError(`secret ${secretId} field private_key is not a 32-byte hex key`);
  try {
    return getAddress(privateKeyToAccount(hex as `0x${string}`).address);
  } catch {
    throw new PreflightError(`secret ${secretId} field private_key is not a valid secp256k1 key`);
  }
}

/**
 * Checks every wallet; throws PreflightError listing every failure (fixed messages, public
 * values only). Returns report lines on success.
 */
export async function fulfillerPreflight(
  client: PublicClient,
  wallets: readonly FulfillerWallet[],
  minWei: bigint,
  readField: FieldReader = readSecretField,
): Promise<string[]> {
  if (minWei <= 0n) throw new PreflightError("minimum gas balance must be positive");
  const failures: string[] = [];
  const lines: string[] = [];
  const derivedSeen = new Map<Address, string>();
  for (const w of wallets) {
    let derived: Address | undefined;
    try {
      derived = addressOfGasKey(readField(w.secret, "private_key"), w.secret.secretId);
    } catch (err) {
      failures.push(
        err instanceof SecretReadError || err instanceof PreflightError
          ? `wallet ${w.label}: ${err.message}`
          : `wallet ${w.label}: could not derive an address from ${w.secret.secretId}`,
      );
    }
    if (derived !== undefined) {
      const other = derivedSeen.get(derived);
      if (other) failures.push(`wallet ${w.label}: ${w.secret.secretId} holds the same key as wallet ${other}`);
      derivedSeen.set(derived, w.label);
      if (derived !== getAddress(w.allowlisted)) {
        failures.push(
          `wallet ${w.label}: ${w.secret.secretId} derives ${derived}, but the allowlisted fulfiller is ${getAddress(w.allowlisted)}`,
        );
      }
    }
    const balance = await client.getBalance({ address: w.allowlisted });
    if (balance < minWei) {
      failures.push(`wallet ${w.label}: ${getAddress(w.allowlisted)} holds ${formatEther(balance)} ETH, below the ${formatEther(minWei)} ETH minimum`);
    }
    lines.push(
      `wallet ${w.label} ${getAddress(w.allowlisted)}: key ${w.secret.secretId} ${derived === getAddress(w.allowlisted) ? "matches" : "does NOT match"}, balance ${formatEther(balance)} ETH (min ${formatEther(minWei)})`,
    );
  }
  if (failures.length) throw new PreflightError(failures.join("\n"));
  return lines;
}
