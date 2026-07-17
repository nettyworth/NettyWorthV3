/**
 * verify-basescan.ts
 *
 * Verifies all deployed contracts (implementations + ERC1967 proxies + linked
 * libraries) on Basescan (Base L2 block explorer) via `forge verify-contract`
 * using the Etherscan V2 multichain API.
 *
 * Usage:
 *   node --experimental-strip-types scripts/verify-basescan.ts --network base
 *   node --experimental-strip-types scripts/verify-basescan.ts --network baseSepolia
 *
 * Required env vars:
 *   BASESCAN_API_KEY   — Basescan / Etherscan API key
 *                        (get one at https://basescan.org/myapikey)
 *                        Falls back to ETHERSCAN_API_KEY if not set.
 *
 * Tip: if you see bytecode mismatch errors, ensure the contracts were compiled with:
 *   solc 0.8.28 · optimizer on (200 runs) · viaIR true · evm cancun
 * These match foundry.toml. A mismatch usually means a different bytecodeHash
 * or metadata setting. Run `forge build` before verifying.
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
  /**
   * Return `{ "contracts/Foo.sol:Foo": "0x..." }` for each library that the
   * implementation links against. These are passed as --libraries flags when
   * verifying the implementation. Return an empty object or omit when the
   * implementation has no linked dependencies.
   */
  linkedLibraries?: (entry: DeploymentEntry) => Record<string, string>;
}

interface LibraryMeta {
  /** Path within contracts/ including filename, e.g. "lib/PackPoolLib.sol" */
  sourcePath: string;
  /** Solidity library name */
  contractName: string;
  /**
   * Extract the on-chain address of the deployed library from the deployments
   * record. Return null if the address is not recorded (verification is skipped).
   */
  addressFrom: (deployments: Deployments) => string | null;
  /**
   * Return `{ "contracts/Foo.sol:Foo": "0x..." }` for each library that THIS
   * library links against (rare, but PackFulfillLib links PackPoolLib).
   * Return an empty object or omit when the library has no linked dependencies.
   */
  linkedLibraries?: (deployments: Deployments) => Record<string, string>;
}

// ─── Chain ID map ─────────────────────────────────────────────────────────────

const CHAIN_IDS: Record<string, number> = {
  base: 8453,
  baseSepolia: 84532,
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
    implCtorArgs: () => null, // no-arg constructor (_disableInitializers only)
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
  PackVRFRouter: {
    sourcePath: "PackVRFRouter.sol",
    contractName: "PackVRFRouter",
    implCtorArgs: () => null, // no-arg constructor (_disableInitializers only)
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
  PackTierRegistry: {
    sourcePath: "PackTierRegistry.sol",
    contractName: "PackTierRegistry",
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
  AssetLendingPoolConfig: {
    sourcePath: "AssetLendingPoolConfig.sol",
    contractName: "AssetLendingPoolConfig",
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
          BigInt(e?.ltvBps ?? "5000"),
          BigInt(e?.lenderShareBps ?? "8000"),
          BigInt(e?.acquisitionWindow ?? String(24 * 3600)),
          BigInt(e?.auctionWindow ?? String(7 * 24 * 3600)),
          e.packMachineFactory as `0x${string}`,
        ],
      }),
  },
  AssetLendingPool: {
    sourcePath: "AssetLendingPool.sol",
    contractName: "AssetLendingPool",
    implCtorArgs: () => null,
    linkedLibraries: (e): Record<string, string> =>
      e.lendingLib
        ? { "contracts/lib/LendingLib.sol:LendingLib": e.lendingLib }
        : {},
    proxyInitData: (e) =>
      encodeFunctionData({
        abi: [
          {
            type: "function",
            name: "initialize",
            inputs: [
              { type: "address" }, // initialOwner
              { type: "address" }, // config (AssetLendingPoolConfig proxy)
            ],
          },
        ],
        functionName: "initialize",
        args: [e.owner as `0x${string}`, e.config as `0x${string}`],
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
  // PackMachineImplementation is the EIP-1167 clone template — no proxy, impl only.
  // Its initialize() is called by the factory on each clone; we only verify the
  // shared implementation bytecode here, not the per-clone state.
  PackMachineImplementation: {
    sourcePath: "PackMachine.sol",
    contractName: "PackMachine",
    implCtorArgs: (e) =>
      encodeAddress(
        e.trustedForwarder ?? "0x0000000000000000000000000000000000000000",
      ),
    proxyInitData: () => null, // no proxy — EIP-1167 clones are not UUPS proxies
  },
};

// ─── Deployed-library metadata ────────────────────────────────────────────────
// Libraries are deployed as standalone contracts (linked at compile time) to
// keep their callers under the 24 KiB EIP-170 limit. They have no constructor
// args and no proxy — only the library address is needed.

const LIBRARY_META: Record<string, LibraryMeta> = {
  PackPoolLib: {
    sourcePath: "lib/PackPoolLib.sol",
    contractName: "PackPoolLib",
    // Address is recorded under the PackMachineImplementation entry.
    addressFrom: (deps) => {
      const e = deps["PackMachineImplementation"];
      return e && !Array.isArray(e)
        ? ((e as DeploymentEntry).packPoolLib ?? null)
        : null;
    },
  },
  PackFulfillLib: {
    sourcePath: "lib/PackFulfillLib.sol",
    contractName: "PackFulfillLib",
    addressFrom: (deps) => {
      const e = deps["PackMachineImplementation"];
      return e && !Array.isArray(e)
        ? ((e as DeploymentEntry).packFulfillLib ?? null)
        : null;
    },
    // PackFulfillLib calls into PackPoolLib via a linked call — forge needs the
    // address to match the linked bytecode it verifies against.
    linkedLibraries: (deps): Record<string, string> => {
      const e = deps["PackMachineImplementation"];
      const addr =
        e && !Array.isArray(e)
          ? ((e as DeploymentEntry).packPoolLib ?? null)
          : null;
      if (!addr) return {};
      return { "contracts/lib/PackPoolLib.sol:PackPoolLib": addr };
    },
  },
  LendingLib: {
    sourcePath: "lib/LendingLib.sol",
    contractName: "LendingLib",
    addressFrom: (deps) => {
      const e = deps["AssetLendingPool"];
      return e && !Array.isArray(e)
        ? ((e as DeploymentEntry).lendingLib ?? null)
        : null;
    },
  },
};

// ─── forge verify-contract wrapper ───────────────────────────────────────────

function forgeVerify(
  address: string,
  contractRef: string,
  chainId: number,
  apiKey: string,
  constructorArgs: string | null,
  label: string,
  /** `{ "contracts/Foo.sol:Foo": "0xADDR" }` — passed as one --libraries flag each */
  libraries: Record<string, string> = {},
): boolean {
  const libraryFlags = Object.entries(libraries).map(
    ([ref, addr]) => `--libraries '${ref}:${addr}'`,
  );
  const libraryFlagsExec = Object.entries(libraries).map(
    ([ref, addr]) => `--libraries "${ref}:${addr}"`,
  );

  const cmd = [
    "forge verify-contract",
    address,
    contractRef,
    "--verifier etherscan",
    `--verifier-url 'https://api.etherscan.io/v2/api'`,
    `--etherscan-api-key '${apiKey}'`,
    `--chain ${chainId}`,
    "--watch",
    ...libraryFlags,
    // --constructor-args must come last
    ...(constructorArgs ? [`--constructor-args '${constructorArgs}'`] : []),
  ].join(" \\\n  ");

  console.log(`\n  $ ${cmd}`);

  try {
    const output = execSync(
      [
        "forge verify-contract",
        address,
        contractRef,
        "--verifier etherscan",
        `--verifier-url "https://api.etherscan.io/v2/api"`,
        `--etherscan-api-key "${apiKey}"`,
        `--chain ${chainId}`,
        "--watch",
        ...libraryFlagsExec,
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
    `Usage: node --experimental-strip-types scripts/verify-basescan.ts --network <${Object.keys(CHAIN_IDS).join("|")}>`,
  );
  process.exit(1);
}

const chainId = CHAIN_IDS[networkName];

// Env var validation
const BASESCAN_API_KEY =
  process.env.BASESCAN_API_KEY ?? process.env.ETHERSCAN_API_KEY;

if (!BASESCAN_API_KEY) {
  console.error(
    "Missing required env var: BASESCAN_API_KEY (or ETHERSCAN_API_KEY)\n" +
      "Get a key at https://basescan.org/myapikey",
  );
  process.exit(1);
}

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

console.log(`\n🔍 Basescan verification: ${networkName} (chainId ${chainId})`);
console.log(`   Verifier: Etherscan V2 multichain API`);
console.log(`   ${"=".repeat(60)}`);

let passed = 0;
let failed = 0;
let skipped = 0;

// ─── Contracts ────────────────────────────────────────────────────────────────

for (const [contractKey, meta] of Object.entries(CONTRACT_META)) {
  const rawEntry = deployments[contractKey];
  if (!rawEntry || Array.isArray(rawEntry)) {
    // Not deployed on this network, or is an operational log array.
    console.log(`\n⚪ ${contractKey}: not in ${networkName}.json — skipping`);
    skipped++;
    continue;
  }

  const entry = rawEntry as DeploymentEntry;

  // ── Verify implementation ──────────────────────────────────────────────────
  if (entry.implementation) {
    const implCtorArgs = meta.implCtorArgs(entry);
    const implRef = `contracts/${meta.sourcePath}:${meta.contractName}`;
    const implLibs = meta.linkedLibraries ? meta.linkedLibraries(entry) : {};

    console.log(`\n📄 ${contractKey} implementation (${entry.implementation})`);
    const ok = forgeVerify(
      entry.implementation,
      implRef,
      chainId,
      BASESCAN_API_KEY,
      implCtorArgs,
      `${contractKey} impl`,
      implLibs,
    );
    ok ? passed++ : failed++;
  } else {
    console.log(`\n⚪ ${contractKey}: no implementation address — skipping`);
    skipped++;
  }

  // ── Verify proxy ───────────────────────────────────────────────────────────
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
        chainId,
        BASESCAN_API_KEY,
        proxyCtorArgs,
        `${contractKey} proxy`,
      );
      ok ? passed++ : failed++;
    }
  }
}

// ─── Deployed libraries ───────────────────────────────────────────────────────

for (const [libKey, meta] of Object.entries(LIBRARY_META)) {
  const address = meta.addressFrom(deployments);
  if (!address) {
    console.log(
      `\n⚪ ${libKey}: address not recorded in ${networkName}.json — skipping`,
    );
    skipped++;
    continue;
  }

  const libRef = `contracts/${meta.sourcePath}:${meta.contractName}`;
  const libs = meta.linkedLibraries ? meta.linkedLibraries(deployments) : {};

  console.log(`\n📚 ${libKey} (${address})`);
  const ok = forgeVerify(
    address,
    libRef,
    chainId,
    BASESCAN_API_KEY,
    null, // libraries have no constructor args
    libKey,
    libs,
  );
  ok ? passed++ : failed++;
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
      "These match foundry.toml. A mismatch usually means a different bytecodeHash or metadata setting.\n" +
      "Run `forge build` before re-running this script.",
  );
  process.exit(1);
}
