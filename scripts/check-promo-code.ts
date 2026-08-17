/**
 * check-promo-code.ts
 *
 * Read-only script that reports the on-chain state of one or more
 * PromoCodeRegistry codes: existence, kind, bps, expiry, redemption caps and
 * usage, and — when a wallet is given — per-user eligibility, redemption
 * status, allowlist membership and a discounted-price preview.
 *
 * Usage
 * -----
 * CODE=REFERRAL_FIRST_RIP npx hardhat run scripts/check-promo-code.ts --network base
 * CODE=CODE_A,CODE_B      npx hardhat run scripts/check-promo-code.ts --network base
 * CODE_ID=0x<32-byte hex> npx hardhat run scripts/check-promo-code.ts --network base
 *
 * Optional:
 *   USER_ADDRESS=0x<addr>  also report eligibility / redemption / allowlist
 *                          for this wallet (USER also accepted, but that name
 *                          collides with the shell's own $USER)
 *   PRICE=<uint>           payment-token base units for previewDiscount
 *   PROMO_CODE_REGISTRY_PROXY=0x<addr>   bypass deployments/<network>.json
 */

import { network } from "hardhat";
import { getAddress, keccak256, toBytes, formatUnits } from "viem";
import { readDeployments } from "./lib/deployments.js";

const KindLabel: Record<number, string> = { 0: "Discount", 1: "Buyback" };

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const UINT256_MAX = 2n ** 256n - 1n;

// ─── Parse code inputs ────────────────────────────────────────────────────────

type Target = { label: string; codeId: `0x${string}` };

const targets: Target[] = [];
const seen = new Set<string>();

function addTarget(label: string, codeId: `0x${string}`): void {
  if (seen.has(codeId.toLowerCase())) return;
  seen.add(codeId.toLowerCase());
  targets.push({ label, codeId });
}

function splitEnv(value: string | undefined): string[] {
  return (value ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

for (const raw of splitEnv(process.env.CODE)) {
  // referralService / promoRegistryService.deriveCodeId hash the raw string.
  addTarget(`"${raw}"`, keccak256(toBytes(raw)));

  // couponService and the Next admin UI normalize before hashing, so the same
  // plaintext can live under a second key — check that one too.
  const normalized = raw.toUpperCase();
  if (normalized !== raw) {
    addTarget(`"${normalized}" (normalized)`, keccak256(toBytes(normalized)));
  }
}

for (const raw of splitEnv(process.env.CODE_ID)) {
  if (!/^0x[0-9a-fA-F]{64}$/.test(raw)) {
    console.error(`Invalid CODE_ID (expected 32-byte hex): "${raw}"`);
    process.exit(1);
  }
  addTarget("(raw codeId)", raw.toLowerCase() as `0x${string}`);
}

if (targets.length === 0) {
  console.error("Set CODE=<plaintext[,plaintext...]> and/or CODE_ID=0x<32-byte hex>.");
  console.error(
    "e.g. CODE=REFERRAL_FIRST_RIP npx hardhat run scripts/check-promo-code.ts --network base",
  );
  process.exit(1);
}

// ─── Parse optional user / price ──────────────────────────────────────────────

// $USER is set by the shell to the login name, so only treat it as an address
// when it actually looks like one.
const rawUser = process.env.USER_ADDRESS ?? process.env.USER;

let userAddress: `0x${string}` | undefined;
if (rawUser?.startsWith("0x")) {
  try {
    userAddress = getAddress(rawUser) as `0x${string}`;
  } catch {
    console.error(`Invalid user address: "${rawUser}"`);
    process.exit(1);
  }
}

const price = process.env.PRICE ? BigInt(process.env.PRICE) : 0n;

// ─── Network connection ───────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const chainId = await publicClient.getChainId();

// ─── Resolve PromoCodeRegistry proxy address ──────────────────────────────────

let registryAddress: `0x${string}`;

if (process.env.PROMO_CODE_REGISTRY_PROXY) {
  registryAddress = getAddress(
    process.env.PROMO_CODE_REGISTRY_PROXY,
  ) as `0x${string}`;
} else {
  const data = await readDeployments(connection.networkName);
  const entry = data["PromoCodeRegistry"] as Record<string, unknown> | undefined;
  if (!entry?.proxy) {
    console.error(
      `PromoCodeRegistry proxy not found in deployments/${connection.networkName}.json.`,
    );
    console.error("Set PROMO_CODE_REGISTRY_PROXY to override.");
    process.exit(1);
  }
  registryAddress = getAddress(entry.proxy as string) as `0x${string}`;
}

const bytecode = await publicClient.getCode({ address: registryAddress });
if (!bytecode || bytecode === "0x") {
  console.error(
    `No contract deployed at ${registryAddress} on ${connection.networkName}.`,
  );
  process.exit(1);
}

const registry = await viem.getContractAt("PromoCodeRegistry", registryAddress);

// ─── Registry-level context (read once) ───────────────────────────────────────

const [paused, factory, buybackPool] = await Promise.all([
  registry.read.paused(),
  registry.read.packMachineFactory(),
  registry.read.buybackPool(),
]);

console.log("\n=== PromoCodeRegistry ===");
console.log(`Network:            ${connection.networkName} (chainId ${chainId})`);
console.log(`Registry proxy:     ${registryAddress}`);
console.log(`Paused:             ${paused ? "⚠️  yes" : "no"}`);
console.log(`PackMachineFactory: ${factory}`);
console.log(`BuybackPool:        ${buybackPool}`);
if (userAddress) console.log(`User:               ${userAddress}`);

// ─── Per-code report ──────────────────────────────────────────────────────────

const now = BigInt(Math.floor(Date.now() / 1000));

console.log(`\n=== Codes (${targets.length}) ===\n`);

for (const { label, codeId } of targets) {
  console.log(`Code:   ${label}`);
  console.log(`codeId: ${codeId}`);

  const code = await registry.read.getCode([codeId]);

  if (!code.exists) {
    console.log("  ✗ NOT FOUND — no such code on this registry\n");
    continue;
  }

  const expiryLabel =
    code.expiry === 0n
      ? "never"
      : `${new Date(Number(code.expiry) * 1000).toISOString()}` +
        `${code.expiry <= now ? "  ⚠️  EXPIRED" : ""}`;

  const remaining = await registry.read.remainingRedemptions([codeId]);

  console.log("  ✓ exists");
  console.log(
    `  Kind:            ${KindLabel[Number(code.kind)] ?? `Unknown(${code.kind})`}`,
  );
  console.log(`  bps:             ${code.bps} (${(Number(code.bps) / 100).toFixed(2)}%)`);
  console.log(`  Active:          ${code.active ? "yes" : "⚠️  no"}`);
  console.log(`  Expiry:          ${expiryLabel}`);
  console.log(`  Redeemed:        ${code.redeemedCount}`);
  console.log(
    `  Max redemptions: ${code.maxRedemptions === 0 ? "uncapped" : code.maxRedemptions}`,
  );
  console.log(
    `  Remaining:       ${remaining === UINT256_MAX ? "uncapped" : remaining.toString()}`,
  );
  console.log(`  Once per user:   ${code.oncePerUser ? "yes" : "no"}`);
  console.log(
    `  Restricted:      ${code.restricted ? "yes (allowlist enforced)" : "no"}`,
  );
  console.log(
    `  Machine:         ${
      code.machine === ZERO_ADDRESS ? "global (any machine)" : code.machine
    }`,
  );

  if (userAddress) {
    const [eligible, redeemed, allowlisted] = await Promise.all([
      registry.read.isEligible([codeId, userAddress]),
      registry.read.hasUserRedeemed([codeId, userAddress]),
      registry.read.isAllowlisted([codeId, userAddress]),
    ]);

    console.log(`  ── for ${userAddress} ──`);
    console.log(`  Eligible:        ${eligible ? "✓ yes" : "✗ no"}`);
    console.log(`  Has redeemed:    ${redeemed ? "yes" : "no"}`);
    console.log(`  Allowlisted:     ${allowlisted ? "yes" : "no"}`);

    if (price > 0n) {
      const discounted = await registry.read.previewDiscount([
        codeId,
        userAddress,
        price,
      ]);
      console.log(
        `  Price preview:   ${formatUnits(price, 6)} → ${formatUnits(discounted, 6)} ` +
          `(saves ${formatUnits(price - discounted, 6)})`,
      );
    }
  }

  console.log();
}
