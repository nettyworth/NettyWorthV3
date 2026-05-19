# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

NettyWorth Smart Contracts V3 — Solidity contracts for asset tokenization, built on Hardhat 3 (beta) with OpenZeppelin upgradeable contracts. Targets Ethereum mainnet and Base L2 (OP-stack).

## Build & Test Commands

```bash
pnpm compile                        # Compile contracts (also runs contract-sizer)
pnpm test                           # Run TypeScript integration tests (node:test + viem)
npx hardhat test solidity           # Run Foundry-style Solidity tests (.t.sol files)
npx hardhat test                    # Run both TypeScript and Solidity tests
npx hardhat run scripts/<script>.ts --network <network>  # Deploy via TypeScript script
```

### Linting & Formatting

```bash
pnpm lint                                          # solhint on all contracts
npx prettier --write 'contracts/**/*.sol'          # format Solidity files
```

Config: `.solhint.json` (extends `solhint:recommended`), `.prettierrc.json` (plugin: `prettier-plugin-solidity`, parser: `slang`, printWidth: 80, tabWidth: 4).

## Architecture

- **Solidity 0.8.28**, optimizer enabled (200 runs), `viaIR: true`
- **Hardhat 3 beta** — uses `defineConfig`, `configVariable()`, `edr-simulated` network types
- **OpenZeppelin v5.6.1** — both `@openzeppelin/contracts` and `@openzeppelin/contracts-upgradeable` are installed; all new contracts should use the upgradeable variants with UUPS proxy pattern
- **ERC721A Upgradeable v4** (`erc721a-upgradeable`) — use for NFT contracts; gas-efficient batch minting
- **viem** (not ethers.js) for all TypeScript contract interactions
- **ESM project** (`"type": "module"` in package.json)

## Contract Standards

All V3 contracts must implement these patterns consistently:

- **Upgradeability**: inherit `UUPSUpgradeable` (EIP-1822) — logic upgrades without changing proxy address; upgrade authorized by `UPGRADER_ROLE` (or `DEFAULT_ADMIN_ROLE` on PermissionManager itself)
- **Access control**: use `PermissionManager` + `PermissionConsumer` — do NOT use per-contract `AccessControl` or `Ownable`; see _Access Control Architecture_ below
- **Reentrancy protection**: apply `nonReentrant` (from `ReentrancyGuard`, non-upgradeable variant) on state-changing functions that move assets or funds
- **Initializer pattern**: replace `constructor()` with `initialize()` protected by `initializer`; constructor contains only `_disableInitializers()`
- **Namespaced storage (ERC-7201)**: all mutable state in a `@custom:storage-location erc7201:nettyworth.storage.<ContractName>` struct with a deterministic slot — prevents collision across upgrades
- **OpenZeppelin version**: `@openzeppelin/contracts-upgradeable` v5.x (currently v5.6.1)

## Access Control Architecture

The protocol uses a hub-and-spoke permission model:

1. **PermissionManager** (hub) — single UUPS-upgradeable contract holding all role grants. Inherits `AccessControlEnumerableUpgradeable`. Upgrade auth: `DEFAULT_ADMIN_ROLE`.
2. **PermissionConsumer** (spoke base) — abstract contract storing a reference to the manager. Provides `onlyProtocolRole(bytes32)` modifier that calls `permissionManager.hasProtocolRole(role, _msgSender())`.
3. **AssetNFT** (spoke) — inherits `PermissionConsumer`; overrides `_msgSender()` for ERC-2771 meta-tx sender resolution.

When writing new consumer contracts:

- Inherit `PermissionConsumer`
- Call `__PermissionConsumer_init(permissionManagerAddress)` in `initialize()`
- Gate functions with `onlyProtocolRole(Roles.SOME_ROLE)`
- Role constants live in `contracts/lib/Roles.sol`
- If the contract uses ERC-2771, override `_msgSender()` to use the forwarder-aware version

## Key Patterns

- **Blacklist**: address-level transfer blocking in ERC-7201 storage, checked in `_beforeTokenTransfers`, managed via `BLACKLIST_ROLE`
- **Transfer Validator**: pluggable external `ITransferValidator.validateTransfer()` hook; reverts block the transfer, silent return allows it; set by `DEFAULT_ADMIN_ROLE`
- **Meta-transactions (ERC-2771)**: trusted forwarder is immutable per implementation — changing it requires a UUPS upgrade; `_msgSender()` / `_msgData()` resolved via `ERC2771ContextUpgradeable`
- **Royalties (ERC-2981)**: default + per-token overrides, managed by `DEFAULT_ADMIN_ROLE`
- **Batch size cap**: all batch operations capped at 50 elements to bound gas

## Project Layout

- `contracts/` — Solidity source files
  - `contracts/interfaces/` — Interface definitions (`IPermissionManager`, `ITransferValidator`)
  - `contracts/lib/` — Libraries (`Roles.sol` — protocol role constants)
  - `contracts/test-helpers/` — Thin proxy wrappers for testing
  - `contracts/test/` — Foundry-style `.t.sol` test files
- `test/` — TypeScript integration tests using `node:test` and `viem`
- `scripts/` — TypeScript deployment/upgrade scripts
- `deployments/` — JSON deployment records per network (auto-created by scripts)

## Testing Conventions

Two test layers run side by side:

1. **Solidity tests** (`contracts/*.t.sol`): Inherit `forge-std/Test.sol`, use `setUp()`, `test_*` naming, `testFuzz_*` for fuzz tests, `vm.expectRevert()` for failure cases.
2. **TypeScript tests** (`test/*.ts`): Use `node:test` (`describe`/`it`), `node:assert/strict`, and Hardhat 3's viem integration (`network.create()` → `viem.deployContract()`).

## Network Configuration

| Name | Type | Chain |
|------|------|-------|
| `hardhatMainnet` | Local simulated | L1 |
| `hardhatOp` | Local simulated | OP |
| `forkMainnet` | Local fork | L1 |
| `forkBase` | Local fork | OP (Base) |
| `forkSepolia` | Local fork | L1 testnet |
| `sepolia` | HTTP | L1 testnet |
| `mainnet` | HTTP | L1 |
| `base` | HTTP | OP (Base L2) |

Config variables needed for live networks: `SEPOLIA_RPC_URL`, `SEPOLIA_PRIVATE_KEY`, `MAINNET_RPC_URL`, `MAINNET_PRIVATE_KEY`, `BASE_RPC_URL`, `BASE_PRIVATE_KEY`.
