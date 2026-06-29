/**
 * verify-tenderly.ts
 *
 * Verifies all deployed contracts (implementations + ERC1967 proxies) on
 * Tenderly using `forge verify-contract`.
 *
 * Usage:
 *   node --experimental-strip-types scripts/verify-tenderly.ts --network sepolia
 *   node --experimental-strip-types scripts/verify-tenderly.ts --network mainnet
 *   node --experimental-strip-types scripts/verify-tenderly.ts --network base
 *
 * Required env vars:
 *   TENDERLY_ACCOUNT    — account slug (case-sensitive, from dashboard URL)
 *   TENDERLY_PROJECT    — project slug
 *   TENDERLY_ACCESS_KEY — from Account Settings → Authorization
 *
 * The verifier URL uses private verification by default. Append "/public" to
 * TENDERLY_VERIFIER_SUFFIX env var to make verifications public (irreversible).
 *
 * Docs: https://docs.tenderly.co/contract-verification/foundry
 */

import { execSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  encodeAbiParameters,
  encodeFunctionData,
  parseAbiParameters,
} from "viem";
import "dotenv/config";

// ─── Types ────────────────────────────────────────────────────────────────────

type DeploymentEntry = Record<string, string>;
type Deployments = Record<string, DeploymentEntry | unknown[]>;

interface ContractMeta {
  /** Path within contracts/ including filename, e.g. "AssetNFT.sol" */
  sourcePath: string;
  /** Solidity contract name */
  contractName: string;
  /**
   * Return the ABI-encoded constructor args for the *implementation* contract,
   * or null if the constructor takes no args.
   * Receives the raw deployment entry from deployments/<network>.json.
   */
  implCtorArgs: (entry: DeploymentEntry) => string | null;
  /**
   * Return the ABI-encoded initialize() calldata used when the proxy was
   * deployed. This becomes the `data` argument to ERC1967ProxyHelper(impl, data).
   * Return null only if you cannot reconstruct it (proxy verify will be skipped).
   */
  proxyInitData: (entry: DeploymentEntry) => string | null;
}

// ─── Chain ID map ─────────────────────────────────────────────────────────────

const CHAIN_IDS: Record<string, number> = {
  sepolia: 11155111,
  mainnet: 1,
  base: 8453,
};

// ─── ABI-encoding helpers ─────────────────────────────────────────────────────

/** Encode a single address as an ABI constructor arg (left-padded to 32 bytes). */
function encodeAddress(addr: string): string {
  return encodeAbiParameters(parseAbiParameters("address"), [
    addr as `0x${string}`,
  ]);
}

// ─── Per-contract metadata ────────────────────────────────────────────────────
// Each entry maps the deployment JSON key → verification metadata.
// implCtorArgs / proxyInitData are derived from the same args the deploy scripts used.

const CONTRACT_META: Record<string, ContractMeta> = {
  PermissionManager: {
    sourcePath: "PermissionManager.sol",
    contractName: "PermissionManager",
    implCtorArgs: () => null, // no-arg constructor
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [{ type: "address" }],
          },
        ],
        functionName: "initialize",
        args: [e.admin as `0x${string}`],
      }),
  },

  AssetNFT: {
    sourcePath: "AssetNFT.sol",
    contractName: "AssetNFT",
    implCtorArgs: (e) =>
      encodeAddress(
        e.trustedForwarder ?? "0x0000000000000000000000000000000000000000",
      ),
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [
              { type: "address" }, // permissionManager
              { type: "string" }, // name
              { type: "string" }, // symbol
              { type: "string" }, // contractURI
              { type: "address" }, // royaltyReceiver (defaults to admin on deploy)
              { type: "uint96" }, // royaltyFee (0 on deploy)
            ],
          },
        ],
        functionName: "initialize",
        args: [
          e.permissionManager as `0x${string}`,
          e.name ?? "NettyWorth Assets",
          e.symbol ?? "NWA",
          e.contractURI ?? "",
          // royaltyReceiver defaults to deployer; not stored in JSON → use admin
          (e.royaltyReceiver ??
            e.admin ??
            "0x0000000000000000000000000000000000000000") as `0x${string}`,
          BigInt(e.royaltyFee ?? "0"),
        ],
      }),
  },

  PackVRFRouter: {
    sourcePath: "PackVRFRouter.sol",
    contractName: "PackVRFRouter",
    implCtorArgs: () => null, // no-arg constructor
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [
              { type: "address" }, // permissionManager
              { type: "address" }, // vrfCoordinator
              { type: "uint256" }, // subscriptionId
              { type: "bytes32" }, // keyHash
              { type: "uint32" }, // callbackGasLimit
              { type: "uint16" }, // requestConfirmations
            ],
          },
        ],
        functionName: "initialize",
        args: [
          e.permissionManager as `0x${string}`,
          e.vrfCoordinator as `0x${string}`,
          BigInt(e.subscriptionId),
          e.keyHash as `0x${string}`,
          Number(e.callbackGasLimit),
          Number(e.requestConfirmations),
        ],
      }),
  },

  // PackMachineImplementation has no proxy — it is the EIP-1167 clone template.
  PackMachineImplementation: {
    sourcePath: "PackMachine.sol",
    contractName: "PackMachine",
    implCtorArgs: (e) =>
      encodeAddress(
        e.trustedForwarder ?? "0x0000000000000000000000000000000000000000",
      ),
    proxyInitData: () => null, // no proxy
  },

  PackMachineFactory: {
    sourcePath: "PackMachineFactory.sol",
    contractName: "PackMachineFactory",
    implCtorArgs: (e) =>
      encodeAddress(
        e.trustedForwarder ?? "0x0000000000000000000000000000000000000000",
      ),
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [
              { type: "address" }, // permissionManager
              { type: "address" }, // assetNFT
              { type: "address" }, // paymentToken
              { type: "address" }, // financeWallet
            ],
          },
        ],
        functionName: "initialize",
        args: [
          e.permissionManager as `0x${string}`,
          e.assetNFT as `0x${string}`,
          e.paymentToken as `0x${string}`,
          e.financeWallet as `0x${string}`,
        ],
      }),
  },

  PackRegistry: {
    sourcePath: "PackRegistry.sol",
    contractName: "PackRegistry",
    implCtorArgs: () => null,
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [{ type: "address" }],
          },
        ],
        functionName: "initialize",
        args: [e.permissionManager as `0x${string}`],
      }),
  },

  BuybackPool: {
    sourcePath: "BuybackPool.sol",
    contractName: "BuybackPool",
    implCtorArgs: () => null,
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [
              { type: "address" }, // permissionManager
              { type: "address" }, // assetNFT
              { type: "address" }, // paymentToken
              { type: "address" }, // financeWallet
              { type: "address" }, // factory
            ],
          },
        ],
        functionName: "initialize",
        args: [
          e.permissionManager as `0x${string}`,
          e.assetNFT as `0x${string}`,
          e.paymentToken as `0x${string}`,
          e.financeWallet as `0x${string}`,
          e.factory as `0x${string}`,
        ],
      }),
  },

  AssetLendingPool: {
    sourcePath: "AssetLendingPool.sol",
    contractName: "AssetLendingPool",
    implCtorArgs: () => null,
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [
              { type: "address" }, // initialOwner
              { type: "address" }, // paymentToken
              { type: "address" }, // assetNFT
              { type: "uint256" }, // ltvBps
              { type: "uint256" }, // lenderShareBps
              { type: "uint256" }, // acquisitionWindow
              { type: "uint256" }, // auctionWindow
              { type: "address" }, // packMachineFactory
            ],
          },
        ],
        functionName: "initialize",
        args: [
          e.owner as `0x${string}`,
          e.paymentToken as `0x${string}`,
          e.assetNFT as `0x${string}`,
          BigInt(e.ltvBps),
          BigInt(e.lenderShareBps),
          BigInt(e.acquisitionWindow),
          BigInt(e.auctionWindow),
          (e.packMachineFactory ??
            "0x0000000000000000000000000000000000000001") as `0x${string}`,
        ],
      }),
  },

  FeeController: {
    sourcePath: "FeeController.sol",
    contractName: "FeeController",
    implCtorArgs: () => null,
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [
              { type: "address" }, // permissionManager
              { type: "address" }, // treasury
            ],
          },
        ],
        functionName: "initialize",
        args: [
          e.permissionManager as `0x${string}`,
          e.treasury as `0x${string}`,
        ],
      }),
  },

  NettyWorthMarketplace: {
    sourcePath: "NettyWorthMarketplace.sol",
    contractName: "NettyWorthMarketplace",
    implCtorArgs: () => null,
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [
              { type: "address" }, // permissionManager
              { type: "address" }, // feeController
              { type: "address" }, // lendingPool
              { type: "address" }, // assetNFT
              { type: "address" }, // paymentToken
              { type: "address" }, // treasury
            ],
          },
        ],
        functionName: "initialize",
        args: [
          e.permissionManager as `0x${string}`,
          e.feeController as `0x${string}`,
          e.lendingPool as `0x${string}`,
          e.assetNFT as `0x${string}`,
          e.paymentToken as `0x${string}`,
          e.treasury as `0x${string}`,
        ],
      }),
  },

  P2PTradeEscrow: {
    sourcePath: "P2PTradeEscrow.sol",
    contractName: "P2PTradeEscrow",
    implCtorArgs: () => null,
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [{ type: "address" }],
          },
        ],
        functionName: "initialize",
        args: [e.owner as `0x${string}`],
      }),
  },

  PromoCodeRegistry: {
    sourcePath: "PromoCodeRegistry.sol",
    contractName: "PromoCodeRegistry",
    implCtorArgs: () => null,
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [{ type: "address" }],
          },
        ],
        functionName: "initialize",
        args: [e.permissionManager as `0x${string}`],
      }),
  },
};

// ─── forge verify-contract wrapper ───────────────────────────────────────────

function forgeVerify(
  address: string,
  contractRef: string,
  verifierUrl: string,
  accessKey: string,
  constructorArgs: string | null,
  label: string,
): boolean {
  const cmd = [
    "forge verify-contract",
    address,
    contractRef,
    `--verifier-url '${verifierUrl}'`,
    `--etherscan-api-key '${accessKey}'`,
    "--watch",
    // --constructor-args must be LAST (Tenderly requirement)
    ...(constructorArgs ? [`--constructor-args '${constructorArgs}'`] : []),
  ].join(" \\\n  ");

  console.log(`\n  $ ${cmd}`);

  try {
    const output = execSync(
      [
        "forge verify-contract",
        address,
        contractRef,
        `--verifier-url "${verifierUrl}"`,
        `--etherscan-api-key "${accessKey}"`,
        "--watch",
        ...(constructorArgs ? [`--constructor-args "${constructorArgs}"`] : []),
      ].join(" "),
      { stdio: "pipe", encoding: "utf8" },
    );
    console.log(`  ✅ ${label} verified`);
    if (output.trim())
      console.log("    " + output.trim().replace(/\n/g, "\n    "));
    return true;
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; message?: string };
    console.error(`  ❌ ${label} FAILED`);
    if (e.stdout)
      console.error("    stdout: " + e.stdout.trim().replace(/\n/g, "\n    "));
    if (e.stderr)
      console.error("    stderr: " + e.stderr.trim().replace(/\n/g, "\n    "));
    return false;
  }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

// Parse --network flag
const networkArg = process.argv.indexOf("--network");
const networkName = networkArg !== -1 ? process.argv[networkArg + 1] : null;

if (!networkName || !(networkName in CHAIN_IDS)) {
  console.error(
    `Usage: node --experimental-strip-types scripts/verify-tenderly.ts --network <${Object.keys(CHAIN_IDS).join("|")}>`,
  );
  process.exit(1);
}

const chainId = CHAIN_IDS[networkName];

// Env var validation
const TENDERLY_ACCOUNT = process.env.TENDERLY_ACCOUNT;
const TENDERLY_PROJECT = process.env.TENDERLY_PROJECT;
const TENDERLY_ACCESS_KEY = process.env.TENDERLY_ACCESS_KEY;
const PUBLIC_SUFFIX = process.env.TENDERLY_VERIFIER_SUFFIX ?? ""; // set to "/public" for public verification

if (!TENDERLY_ACCOUNT || !TENDERLY_PROJECT || !TENDERLY_ACCESS_KEY) {
  console.error(
    "Missing required env vars: TENDERLY_ACCOUNT, TENDERLY_PROJECT, TENDERLY_ACCESS_KEY\n" +
      "See .env.example for setup instructions.",
  );
  process.exit(1);
}

const verifierUrl =
  `https://api.tenderly.co/api/v1/account/${TENDERLY_ACCOUNT}/project/${TENDERLY_PROJECT}` +
  `/etherscan/verify/network/${chainId}${PUBLIC_SUFFIX}`;

// Load deployment record
const deploymentsDir = join(
  dirname(fileURLToPath(import.meta.url)),
  "../deployments",
);
const deploymentPath = join(deploymentsDir, `${networkName}.json`);

let deployments: Deployments;
try {
  deployments = JSON.parse(
    await readFile(deploymentPath, "utf8"),
  ) as Deployments;
} catch {
  console.error(
    `Could not read deployments/${networkName}.json — run the deploy scripts first.`,
  );
  process.exit(1);
}

console.log(`\n🔍 Tenderly verification: ${networkName} (chainId ${chainId})`);
console.log(`   Verifier URL: ${verifierUrl}\n`);
console.log(`   ${"=".repeat(60)}`);

let passed = 0;
let failed = 0;
let skipped = 0;

for (const [contractKey, meta] of Object.entries(CONTRACT_META)) {
  const rawEntry = deployments[contractKey];
  if (!rawEntry || Array.isArray(rawEntry)) {
    // Not deployed on this network, or is an operational log array.
    console.log(`\n⚪ ${contractKey}: not in ${networkName}.json — skipping`);
    skipped++;
    continue;
  }

  const entry = rawEntry as DeploymentEntry;

  // ── Verify implementation ──────────────────────────────────────────────
  if (entry.implementation) {
    const implCtorArgs = meta.implCtorArgs(entry);
    const implRef = `contracts/${meta.sourcePath}:${meta.contractName}`;

    console.log(`\n📄 ${contractKey} implementation (${entry.implementation})`);
    const ok = forgeVerify(
      entry.implementation,
      implRef,
      verifierUrl,
      TENDERLY_ACCESS_KEY,
      implCtorArgs,
      `${contractKey} impl`,
    );
    ok ? passed++ : failed++;
  } else {
    console.log(`\n⚪ ${contractKey}: no implementation address — skipping`);
    skipped++;
  }

  // ── Verify proxy ───────────────────────────────────────────────────────
  if (entry.proxy) {
    const initData = meta.proxyInitData(entry);
    if (!initData) {
      console.log(
        `   ⚪ ${contractKey} proxy: initData not reconstructable — skipping`,
      );
      skipped++;
    } else {
      // ERC1967ProxyHelper constructor: (address implementation, bytes memory data)
      const proxyCtorArgs = encodeAbiParameters(
        parseAbiParameters("address, bytes"),
        [entry.implementation as `0x${string}`, initData as `0x${string}`],
      );

      console.log(`\n📦 ${contractKey} proxy (${entry.proxy})`);
      const ok = forgeVerify(
        entry.proxy,
        "contracts/test-helpers/ERC1967ProxyHelper.sol:ERC1967ProxyHelper",
        verifierUrl,
        TENDERLY_ACCESS_KEY,
        proxyCtorArgs,
        `${contractKey} proxy`,
      );
      ok ? passed++ : failed++;
    }
  }
}

// ─── Summary ──────────────────────────────────────────────────────────────────
console.log(`\n${"=".repeat(60)}`);
console.log(
  `Verification complete: ✅ ${passed} passed  ❌ ${failed} failed  ⚪ ${skipped} skipped`,
);

if (failed > 0) {
  console.log(
    "\nTip: if you see bytecode mismatch errors, ensure the contracts were compiled with:\n" +
      "  solc 0.8.28 · optimizer on (200 runs) · viaIR true · evm cancun\n" +
      "These match foundry.toml. A mismatch usually means a different bytecodeHash or metadata setting.",
  );
  process.exit(1);
}
