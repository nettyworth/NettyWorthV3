/**
 * Unit tests for fulfiller-preflight.ts (audit N-03). No network, no AWS: the secret reader and
 * the balance source are injected. Keys here are throwaway test values.
 *   node --experimental-strip-types --test scripts/vrf/test/
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { getAddress, parseEther, type Address, type PublicClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { SecretReadError, type SecretSource } from "../aws-secret.ts";
import { fulfillerPreflight, PreflightError } from "../fulfiller-preflight.ts";

const KEY_A = "0x1111111111111111111111111111111111111111111111111111111111111111";
const KEY_B = "2222222222222222222222222222222222222222222222222222222222222222"; // no 0x, as the fulfiller accepts
const ADDR_A = getAddress(privateKeyToAccount(KEY_A).address);
const ADDR_B = getAddress(privateKeyToAccount(`0x${KEY_B}`).address);
const MIN = parseEther("0.005");

function client(balances: Record<string, bigint>) {
  return { getBalance: async ({ address }: { address: Address }) => balances[getAddress(address)] ?? 0n } as unknown as PublicClient;
}
function reader(values: Record<string, string | Error>) {
  return (src: SecretSource, field: string) => {
    assert.equal(field, "private_key");
    const v = values[src.secretId];
    if (v instanceof Error) throw v;
    return v;
  };
}
const wallets = (a: Address = ADDR_A, b: Address = ADDR_B) => [
  { label: "A", allowlisted: a, secret: { secretId: "nettyworth/staging-v2-vrf-fulfiller/gas-key-a", region: "us-east-1" } },
  { label: "B", allowlisted: b, secret: { secretId: "nettyworth/staging-v2-vrf-fulfiller/gas-key-b", region: "us-east-1" } },
];
const funded = client({ [ADDR_A]: MIN, [ADDR_B]: parseEther("1") });
const secrets = { "nettyworth/staging-v2-vrf-fulfiller/gas-key-a": KEY_A, "nettyworth/staging-v2-vrf-fulfiller/gas-key-b": KEY_B };

/** Neither the message nor anything else we report may contain a key. */
function assertNoKey(text: string) {
  for (const k of [KEY_A.slice(2), KEY_B]) assert.ok(!text.toLowerCase().includes(k), "a secret key leaked into the output");
}

test("passes when both keys derive the allowlisted wallets and both are funded", async () => {
  const lines = await fulfillerPreflight(funded, wallets(), MIN, reader(secrets));
  assert.equal(lines.length, 2);
  assert.match(lines[0], /matches/);
  assertNoKey(lines.join("\n"));
});

test("refuses when a key derives a different address, naming only the derived address", async () => {
  const other = getAddress("0x440F9c1dd178C7ff5595E6471B48A7BF7d53592C");
  await assert.rejects(fulfillerPreflight(client({ [other]: MIN, [ADDR_A]: MIN }), wallets(ADDR_A, other), MIN, reader(secrets)), (err: Error) => {
    assert.ok(err instanceof PreflightError);
    assert.match(err.message, new RegExp(`derives ${ADDR_B}, but the allowlisted fulfiller is ${other}`));
    assertNoKey(err.message);
    return true;
  });
});

test("refuses an unfunded or underfunded wallet", async () => {
  await assert.rejects(fulfillerPreflight(client({ [ADDR_A]: MIN - 1n, [ADDR_B]: 0n }), wallets(), MIN, reader(secrets)), (err: Error) => {
    assert.match(err.message, /wallet A: .* below the 0.005 ETH minimum/);
    assert.match(err.message, /wallet B: .* holds 0 ETH/);
    return true;
  });
});

test("refuses a malformed key without echoing it", async () => {
  const bad = "0xnot-a-key-" + "ab".repeat(20);
  await assert.rejects(fulfillerPreflight(funded, wallets(), MIN, reader({ ...secrets, "nettyworth/staging-v2-vrf-fulfiller/gas-key-a": bad })), (err: Error) => {
    assert.match(err.message, /gas-key-a field private_key is not a 32-byte hex key/);
    assert.ok(!err.message.includes(bad));
    return true;
  });
  const zero = "0x" + "0".repeat(64); // 32 bytes of hex but not a valid secp256k1 scalar
  await assert.rejects(fulfillerPreflight(funded, wallets(), MIN, reader({ ...secrets, "nettyworth/staging-v2-vrf-fulfiller/gas-key-b": zero })), /gas-key-b field private_key is not a valid secp256k1 key/);
});

test("refuses when both secrets hold the same key", async () => {
  await assert.rejects(
    fulfillerPreflight(funded, wallets(), MIN, reader({ ...secrets, "nettyworth/staging-v2-vrf-fulfiller/gas-key-b": KEY_A })),
    /holds the same key as wallet A/,
  );
});

test("a secret that cannot be read is a refusal with a fixed message", async () => {
  await assert.rejects(
    fulfillerPreflight(funded, wallets(), MIN, reader({ ...secrets, "nettyworth/staging-v2-vrf-fulfiller/gas-key-a": new SecretReadError("could not read secret nettyworth/staging-v2-vrf-fulfiller/gas-key-a with the AWS CLI (check credentials, region and permission to GetSecretValue)") })),
    /wallet A: could not read secret/,
  );
});

test("a non-positive minimum is rejected", async () => {
  await assert.rejects(fulfillerPreflight(funded, wallets(), 0n, reader(secrets)), /must be positive/);
});
