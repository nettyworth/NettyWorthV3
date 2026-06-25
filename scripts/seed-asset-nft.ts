/**
 * seed-asset-nft.ts
 *
 * Developer seeding script — deploys a fresh PermissionManager + AssetNFT (if
 * not already present) and mints a set of Pokémon PSA graded test cards.
 * Optionally sets appraisals on a deployed AssetLendingPool so the cards are
 * immediately borrow-eligible in the frontend.
 *
 * Usage:
 *   npx hardhat run scripts/seed-asset-nft.ts              # simulated network
 *   npx hardhat run scripts/seed-asset-nft.ts --network sepolia
 *
 * Env vars (all optional):
 *   PERMISSION_MANAGER_PROXY   – reuse existing PM instead of deploying
 *   ASSET_NFT_PROXY            – reuse existing NFT instead of deploying
 *   ASSET_LENDING_POOL_PROXY   – set appraisals on this pool after minting
 *   SEED_RECIPIENT             – mint to this address (default: deployer)
 *   TRUSTED_FORWARDER          – ERC-2771 forwarder (default: zero address)
 *   PAYMENT_TOKEN_DECIMALS     – appraisal value scale (default: 6 for USDC)
 *   ASSET_NFT_NAME / SYMBOL / CONTRACT_URI / ROYALTY_FEE
 */

import { network } from "hardhat";
import { encodeFunctionData, getAddress, keccak256, toBytes } from "viem";
import { createInterface } from "node:readline/promises";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

// ── Config ────────────────────────────────────────────────────────────────────

const TRUSTED_FORWARDER = (process.env.TRUSTED_FORWARDER ??
  "0x0000000000000000000000000000000000000000") as `0x${string}`;
const NFT_NAME = process.env.ASSET_NFT_NAME ?? "NettyWorth Assets (Test)";
const NFT_SYMBOL = process.env.ASSET_NFT_SYMBOL ?? "NWAT";
const CONTRACT_URI = process.env.ASSET_NFT_CONTRACT_URI ?? "";
const ROYALTY_FEE = BigInt(process.env.ASSET_NFT_ROYALTY_FEE ?? "0");
const PAYMENT_DECIMALS = Number(process.env.PAYMENT_TOKEN_DECIMALS ?? "6");

const MINTER_ROLE = keccak256(toBytes("MINTER_ROLE"));

// ── Pokémon PSA card dataset ──────────────────────────────────────────────────

interface PokemonCard {
  name: string;
  set: string;
  year: number;
  psaGrade: number;
  gradeLabel: string;
  appraisalUsd: number;
  emoji: string;
  /** Pokémon TCG CDN image URL for the card art. */
  image: string;
}

const CDN = "https://images.pokemontcg.io";

const POKEMON_CARDS: PokemonCard[] = [
  {
    name: "Charizard Holo",
    set: "Base Set",
    year: 1999,
    psaGrade: 10,
    gradeLabel: "GEM MINT",
    appraisalUsd: 50000,
    emoji: "🔥",
    image: `${CDN}/base1/4_hires.png`,
  },
  {
    name: "Charizard Holo",
    set: "Base Set",
    year: 1999,
    psaGrade: 9,
    gradeLabel: "MINT",
    appraisalUsd: 15000,
    emoji: "🔥",
    image: `${CDN}/base1/4_hires.png`,
  },
  {
    // The genuine Pikachu Illustrator promo is not on the TCG CDN; this uses
    // a distinct Jungle-set Pikachu as a test-data stand-in.
    name: "Pikachu Illustrator",
    set: "CoroCoro Promo",
    year: 1998,
    psaGrade: 9,
    gradeLabel: "MINT",
    appraisalUsd: 20000,
    emoji: "⚡",
    image: `${CDN}/base2/60_hires.png`,
  },
  {
    name: "Blastoise Holo",
    set: "Base Set",
    year: 1999,
    psaGrade: 8,
    gradeLabel: "NM-MT",
    appraisalUsd: 8000,
    emoji: "💧",
    image: `${CDN}/base1/2_hires.png`,
  },
  {
    name: "Venusaur Holo",
    set: "Base Set",
    year: 1999,
    psaGrade: 8,
    gradeLabel: "NM-MT",
    appraisalUsd: 5000,
    emoji: "🌿",
    image: `${CDN}/base1/15_hires.png`,
  },
  {
    name: "Lugia Holo",
    set: "Neo Genesis",
    year: 2000,
    psaGrade: 9,
    gradeLabel: "MINT",
    appraisalUsd: 10000,
    emoji: "🌊",
    image: `${CDN}/neo1/9_hires.png`,
  },
  {
    name: "Mewtwo Holo",
    set: "Base Set",
    year: 1999,
    psaGrade: 7,
    gradeLabel: "NM",
    appraisalUsd: 3000,
    emoji: "💜",
    image: `${CDN}/base1/10_hires.png`,
  },
  {
    name: "Gengar Holo",
    set: "Fossil",
    year: 1999,
    psaGrade: 9,
    gradeLabel: "MINT",
    appraisalUsd: 2000,
    emoji: "👻",
    image: `${CDN}/base3/5_hires.png`,
  },
  {
    name: "Alakazam Holo",
    set: "Base Set",
    year: 1999,
    psaGrade: 6,
    gradeLabel: "EX-MT",
    appraisalUsd: 1500,
    emoji: "🔮",
    image: `${CDN}/base1/1_hires.png`,
  },
  {
    name: "Gyarados Holo",
    set: "Base Set",
    year: 1999,
    psaGrade: 5,
    gradeLabel: "EX",
    appraisalUsd: 800,
    emoji: "🐉",
    image: `${CDN}/base1/6_hires.png`,
  },
  {
    name: "Dark Charizard Holo",
    set: "Team Rocket",
    year: 2000,
    psaGrade: 4,
    gradeLabel: "VG-EX",
    appraisalUsd: 500,
    emoji: "🌑",
    image: `${CDN}/base5/4_hires.png`,
  },
  {
    name: "Pikachu",
    set: "Base Set",
    year: 1999,
    psaGrade: 10,
    gradeLabel: "GEM MINT",
    appraisalUsd: 600,
    emoji: "⚡",
    image: `${CDN}/base1/58_hires.png`,
  },
];

// ── Token URI builder ─────────────────────────────────────────────────────────
// Each URI is a data:application/json;base64 payload. The `image` field holds
// a remote Pokémon TCG CDN URL (~60 extra bytes), which is negligible against
// the simulated-network tx gas cap (~16M) — batches of 4 remain well within
// budget. To use a real IPFS URL instead, replace `card.image` below, or call
// `setTokenURI` after minting (requires URI_SETTER_ROLE).

function buildTokenURI(card: PokemonCard): string {
  const metadata = {
    name: `${card.name} PSA ${card.psaGrade}`,
    description:
      `${card.name} from the ${card.set} set (${card.year}), graded ` +
      `PSA ${card.psaGrade} — ${card.gradeLabel} by Professional Sports ` +
      `Authenticator. Test card for NettyWorth development.`,
    image: card.image,
    attributes: [
      { trait_type: "Card Name", value: card.name },
      { trait_type: "Set", value: card.set },
      { trait_type: "Year", value: card.year },
      { trait_type: "Grader", value: "PSA" },
      { trait_type: "Grade", value: card.psaGrade },
      { trait_type: "Grade Label", value: card.gradeLabel },
      { trait_type: "Appraised Value (USD)", value: card.appraisalUsd },
    ],
  };
  const json = JSON.stringify(metadata);
  return "data:application/json;base64," + Buffer.from(json).toString("base64");
}

// ── Deployments file helpers ──────────────────────────────────────────────────

const __scriptDir = dirname(fileURLToPath(import.meta.url));
const deploymentsDir = join(__scriptDir, "../deployments");

async function readDeployments(
  networkName: string,
): Promise<Record<string, unknown>> {
  try {
    return JSON.parse(
      await readFile(join(deploymentsDir, `${networkName}.json`), "utf8"),
    );
  } catch {
    return {};
  }
}

async function saveDeployments(
  networkName: string,
  data: Record<string, unknown>,
): Promise<void> {
  await mkdir(deploymentsDir, { recursive: true });
  await writeFile(
    join(deploymentsDir, `${networkName}.json`),
    JSON.stringify(data, null, 2) + "\n",
  );
  console.log(`  Saved → deployments/${networkName}.json`);
}

// ── Confirmation prompt ───────────────────────────────────────────────────────

async function confirmSeed(
  networkName: string,
  chainId: number,
  deployer: string,
  recipient: string,
): Promise<boolean> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  console.log("\n=== Seed Summary ===");
  console.log(`Network:   ${networkName} (chainId: ${chainId})`);
  console.log(`Deployer:  ${deployer}`);
  console.log(`Recipient: ${recipient}`);
  console.log(`Cards:     ${POKEMON_CARDS.length} Pokémon PSA cards`);
  console.log("====================\n");
  const answer = await rl.question("Proceed? (yes/no): ");
  rl.close();
  return answer.toLowerCase() === "yes";
}

// ── Main ──────────────────────────────────────────────────────────────────────

const connection = await network.create();
const { viem } = connection;

const publicClient = await viem.getPublicClient();
const [deployerClient] = await viem.getWalletClients();
const deployerAddress = deployerClient.account.address;
const chainId = await publicClient.getChainId();

const seedRecipient: `0x${string}` = process.env.SEED_RECIPIENT
  ? (getAddress(process.env.SEED_RECIPIENT) as `0x${string}`)
  : deployerAddress;

if (connection.networkConfig.type === "http") {
  const ok = await confirmSeed(
    connection.networkName,
    chainId,
    deployerAddress,
    seedRecipient,
  );
  if (!ok) {
    console.log("Cancelled.");
    process.exit(0);
  }
}

let deployments = await readDeployments(connection.networkName);

// ── Step 1 of 4: PermissionManager ───────────────────────────────────────────

let pmProxy: `0x${string}`;

if (process.env.PERMISSION_MANAGER_PROXY) {
  pmProxy = getAddress(process.env.PERMISSION_MANAGER_PROXY) as `0x${string}`;
  console.log(`\n[1/4] Reusing PermissionManager (env): ${pmProxy}`);
} else if (
  (deployments["PermissionManager"] as Record<string, unknown> | undefined)
    ?.proxy
) {
  pmProxy = getAddress(
    (deployments["PermissionManager"] as Record<string, string>).proxy,
  ) as `0x${string}`;
  console.log(`\n[1/4] Reusing PermissionManager (deployments): ${pmProxy}`);
} else {
  console.log("\n[1/4] Deploying PermissionManager...");
  const pmImpl = await viem.deployContract("PermissionManager");
  console.log(`  impl:  ${pmImpl.address}`);
  const pmInitData = encodeFunctionData({
    abi: pmImpl.abi,
    functionName: "initialize",
    args: [deployerAddress],
  });
  const pmProxyContract = await viem.deployContract("ERC1967ProxyHelper", [
    pmImpl.address,
    pmInitData,
  ]);
  pmProxy = pmProxyContract.address;
  console.log(`  proxy: ${pmProxy}`);

  // Verify admin role
  const pm = await viem.getContractAt("PermissionManager", pmProxy);
  const adminRole = await pm.read.DEFAULT_ADMIN_ROLE();
  const hasAdmin = await pm.read.hasProtocolRole([adminRole, deployerAddress]);
  if (!hasAdmin) {
    console.error("  ERROR: deployer missing DEFAULT_ADMIN_ROLE");
    process.exit(1);
  }
  console.log("  ✓ PermissionManager deployed");

  if (connection.networkConfig.type === "http") {
    deployments = await readDeployments(connection.networkName);
    deployments["PermissionManager"] = {
      proxy: pmProxy,
      implementation: pmImpl.address,
      admin: deployerAddress,
      deployedAt: new Date().toISOString(),
    };
    await saveDeployments(connection.networkName, deployments);
  }
}

// ── Step 2 of 4: AssetNFT ─────────────────────────────────────────────────────

let nftProxy: `0x${string}`;

if (process.env.ASSET_NFT_PROXY) {
  nftProxy = getAddress(process.env.ASSET_NFT_PROXY) as `0x${string}`;
  console.log(`\n[2/4] Reusing AssetNFT (env): ${nftProxy}`);
} else if (
  (deployments["AssetNFT"] as Record<string, unknown> | undefined)?.proxy
) {
  nftProxy = getAddress(
    (deployments["AssetNFT"] as Record<string, string>).proxy,
  ) as `0x${string}`;
  console.log(`\n[2/4] Reusing AssetNFT (deployments): ${nftProxy}`);
} else {
  console.log(
    `\n[2/4] Deploying AssetNFT (forwarder: ${TRUSTED_FORWARDER})...`,
  );
  const nftImpl = await viem.deployContract("AssetNFT", [TRUSTED_FORWARDER]);
  console.log(`  impl:  ${nftImpl.address}`);
  const nftInitData = encodeFunctionData({
    abi: nftImpl.abi,
    functionName: "initialize",
    args: [
      pmProxy,
      NFT_NAME,
      NFT_SYMBOL,
      CONTRACT_URI,
      deployerAddress, // royalty receiver
      ROYALTY_FEE,
    ],
  });
  const nftProxyContract = await viem.deployContract("ERC1967ProxyHelper", [
    nftImpl.address,
    nftInitData,
  ]);
  nftProxy = nftProxyContract.address;
  console.log(`  proxy: ${nftProxy}`);

  // Verify
  const nftCheck = await viem.getContractAt("AssetNFT", nftProxy);
  const actualName = await nftCheck.read.name();
  if (actualName !== NFT_NAME) {
    console.error(
      `  ERROR: name mismatch — expected "${NFT_NAME}", got "${actualName}"`,
    );
    process.exit(1);
  }
  console.log(`  ✓ AssetNFT deployed (name: "${actualName}")`);

  if (connection.networkConfig.type === "http") {
    deployments = await readDeployments(connection.networkName);
    deployments["AssetNFT"] = {
      proxy: nftProxy,
      implementation: nftImpl.address,
      permissionManager: pmProxy,
      name: NFT_NAME,
      symbol: NFT_SYMBOL,
      contractURI: CONTRACT_URI,
      deployedAt: new Date().toISOString(),
    };
    await saveDeployments(connection.networkName, deployments);
  }
}

// ── Step 3 of 4: Mint ─────────────────────────────────────────────────────────

const pm = await viem.getContractAt("PermissionManager", pmProxy);
const nft = await viem.getContractAt("AssetNFT", nftProxy);

// Ensure deployer holds MINTER_ROLE
const hasMinter = await pm.read.hasProtocolRole([MINTER_ROLE, deployerAddress]);
if (!hasMinter) {
  console.log("\n[3/4] Granting MINTER_ROLE to deployer...");
  try {
    const hash = await pm.write.grantRole([MINTER_ROLE, deployerAddress]);
    await publicClient.waitForTransactionReceipt({ hash });
    console.log("  ✓ MINTER_ROLE granted");
  } catch (e) {
    console.error(
      `  ERROR: cannot grant MINTER_ROLE — ${(e as Error).message}`,
    );
    process.exit(1);
  }
} else {
  console.log("\n[3/4] Deployer already holds MINTER_ROLE ✓");
}

// Determine starting token ID (ERC721A sequential, starts at 1)
const totalBefore = (await nft.read.totalSupply()) as bigint;
const startTokenId = totalBefore + 1n;

console.log(
  `  Minting ${POKEMON_CARDS.length} cards to ${seedRecipient}` +
    ` (IDs ${startTokenId}–${startTokenId + BigInt(POKEMON_CARDS.length) - 1n})...`,
);

// Split into batches of 4 to stay within the simulated-network per-tx gas cap
// (hardhat edr default: 16_777_216). Each token URI is ~1.7 KB of calldata;
// ERC721A storage writes add ~50k gas per token, so 4 tokens ≈ 400k gas total —
// well under the cap.
const BATCH_SIZE = 4;
for (let i = 0; i < POKEMON_CARDS.length; i += BATCH_SIZE) {
  const slice = POKEMON_CARDS.slice(i, i + BATCH_SIZE);
  const batchRecipients: `0x${string}`[] = slice.map(() => seedRecipient);
  const batchUris: string[] = slice.map(buildTokenURI);
  await nft.write.batchMint([batchRecipients, batchUris]);
  console.log(
    `    minted batch ${Math.floor(i / BATCH_SIZE) + 1}: tokens ${startTokenId + BigInt(i)}–${startTokenId + BigInt(i) + BigInt(slice.length) - 1n}`,
  );
}

// Verify supply increased
const totalAfter = (await nft.read.totalSupply()) as bigint;
if (totalAfter !== totalBefore + BigInt(POKEMON_CARDS.length)) {
  console.error(
    `  ERROR: supply mismatch — expected ${totalBefore + BigInt(POKEMON_CARDS.length)}, got ${totalAfter}`,
  );
  process.exit(1);
}

const tokenIds = POKEMON_CARDS.map((_, i) => startTokenId + BigInt(i));
console.log(
  `  ✓ Minted ${POKEMON_CARDS.length} tokens (IDs ${tokenIds[0]}–${tokenIds[tokenIds.length - 1]})`,
);

// ── Step 4 of 4: Appraisals ───────────────────────────────────────────────────

console.log("\n[4/4] Setting appraisals on AssetLendingPool...");

let poolProxy: `0x${string}` | null = null;

if (process.env.ASSET_LENDING_POOL_PROXY) {
  poolProxy = getAddress(process.env.ASSET_LENDING_POOL_PROXY) as `0x${string}`;
  console.log(`  Using env ASSET_LENDING_POOL_PROXY: ${poolProxy}`);
} else if (
  (deployments["AssetLendingPool"] as Record<string, unknown> | undefined)
    ?.proxy
) {
  poolProxy = getAddress(
    (deployments["AssetLendingPool"] as Record<string, string>).proxy,
  ) as `0x${string}`;
  console.log(`  Using deployments entry: ${poolProxy}`);
} else {
  console.log(
    "  ⚠ No AssetLendingPool found — skipping appraisals.\n" +
      "    Set ASSET_LENDING_POOL_PROXY or deploy the pool first to make cards borrow-eligible.",
  );
}

if (poolProxy !== null) {
  const pool = await viem.getContractAt("AssetLendingPool", poolProxy);
  const poolOwner = (await pool.read.owner()) as string;

  if (poolOwner.toLowerCase() !== deployerAddress.toLowerCase()) {
    console.log(
      `  ⚠ Deployer is not pool owner (owner: ${poolOwner}) — skipping appraisals.`,
    );
  } else {
    const scalingFactor = 10n ** BigInt(PAYMENT_DECIMALS);
    const values = POKEMON_CARDS.map(
      (c) => BigInt(c.appraisalUsd) * scalingFactor,
    );
    const grades = POKEMON_CARDS.map((c) => BigInt(c.psaGrade));
    const categories = POKEMON_CARDS.map(() => 0n); // 0 = uncategorized

    const hash = await pool.write.batchSetAppraisals([
      tokenIds,
      values,
      grades,
      categories,
    ]);
    console.log(`  ✓ Appraisals set for ${tokenIds.length} tokens`);

    await publicClient.waitForTransactionReceipt({ hash });
    // Spot-check first token
    const firstId = tokenIds[0];
    const isEligible = await pool.read.isEligible([firstId]);
    const maxLoan = (await pool.read.getMaxLoanAmount([firstId])) as bigint;
    const maxLoanHuman = Number(maxLoan) / 10 ** PAYMENT_DECIMALS;
    console.log(`  Spot-check token #${firstId}:`);
    console.log(`    isEligible:    ${isEligible ? "✓ true" : "✗ false"}`);
    console.log(`    maxLoanAmount: ${maxLoanHuman.toFixed(2)} USDC`);

    if (!isEligible) {
      console.log(
        "    ⚠ Token not eligible — check minAppraisalValue / minGrade settings on the pool.",
      );
    }
  }
}

// ── Summary ───────────────────────────────────────────────────────────────────

const SEP = "─".repeat(66);
console.log(`\n╔${SEP}╗`);
console.log(`║  SEED COMPLETE — Pokémon PSA Test Cards${" ".repeat(26)}║`);
console.log(`╠${SEP}╣`);
console.log(
  `║  Network:  ${(connection.networkName + " (chainId: " + chainId + ")").padEnd(54)}║`,
);
console.log(`║  AssetNFT: ${nftProxy.padEnd(54)}║`);
console.log(`║  Recipient:${seedRecipient.padEnd(54)}║`);
console.log(`╠${SEP}╣`);

const hdr = `  ${"Token ID".padEnd(10)}${"Card Name + Set".padEnd(36)}${"PSA".padEnd(5)}${"USD Value".padEnd(12)}`;
console.log(`║${hdr.padEnd(66)}║`);
console.log(`╠${SEP}╣`);

for (let i = 0; i < POKEMON_CARDS.length; i++) {
  const card = POKEMON_CARDS[i];
  const id = tokenIds[i];
  const label = `${card.name} (${card.set})`.slice(0, 35);
  const row =
    `  ${("#" + id).padEnd(10)}${label.padEnd(36)}` +
    `${card.psaGrade.toString().padEnd(5)}$${card.appraisalUsd.toLocaleString()}`;
  console.log(`║${row.padEnd(66)}║`);
}

console.log(`╚${SEP}╝`);

console.log("\n→ Add to asset-frontend/.env.local:");
console.log(`  NEXT_PUBLIC_ASSET_NFT=${nftProxy}`);
if (poolProxy) {
  console.log(`  NEXT_PUBLIC_ASSET_LENDING_POOL=${poolProxy}`);
}
