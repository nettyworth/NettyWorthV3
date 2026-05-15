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

There is no linter or formatter configured yet.

## Architecture

- **Solidity 0.8.28**, optimizer enabled (200 runs)
- **Hardhat 3 beta** — uses `defineConfig`, `configVariable()`, `edr-simulated` network types
- **OpenZeppelin v5.6.1** — both `@openzeppelin/contracts` and `@openzeppelin/contracts-upgradeable` are installed; all new contracts should use the upgradeable variants with UUPS proxy pattern
- **viem** (not ethers.js) for all TypeScript contract interactions
- **ESM project** (`"type": "module"` in package.json)

## Contract Standards

All V3 contracts must implement these patterns consistently:

- **Upgradeability**: inherit `UUPSUpgradeable` (EIP-1822) — allows logic upgrades without changing the proxy address or migrating state
- **Ownership**: inherit `Ownable2StepUpgradeable` on any contract with admin functions — new owner must explicitly accept the transfer
- **Reentrancy protection**: inherit `ReentrancyGuardUpgradeable` and apply `nonReentrant` on all state-changing functions that move assets or funds
- **Initializer pattern**: replace `constructor()` with `initialize()` protected by the `initializer` modifier; add a constructor containing only `_disableInitializers()` to lock the implementation contract
- **OpenZeppelin version**: use `@openzeppelin/contracts-upgradeable` v5.x (currently v5.6.1)

V2 contracts already follow UUPS + Ownable2StepUpgradeable + ReentrancyGuardUpgradeable. All V3 contracts must match this pattern to ensure the same upgrade governance process applies across the entire protocol.

## Project Layout

- `contracts/` — Solidity source files and Foundry-style `.t.sol` test files
- `test/` — TypeScript integration tests using `node:test` and `viem`
- `scripts/` — TypeScript deployment and standalone scripts

## Testing Conventions

Two test layers run side by side:

1. **Solidity tests** (`contracts/*.t.sol`): Inherit `forge-std/Test.sol`, use `setUp()`, `test_*` naming, `testFuzz_*` for fuzz tests, `vm.expectRevert()` for failure cases.
2. **TypeScript tests** (`test/*.ts`): Use `node:test` (`describe`/`it`), `node:assert/strict`, and Hardhat 3's viem integration (`network.create()` → `viem.deployContract()`).

## Network Configuration

| Name | Type | Chain |
|------|------|-------|
| `hardhatMainnet` | Local simulated | L1 |
| `hardhatOp` | Local simulated | OP |
| `sepolia` | HTTP | L1 testnet |
| `mainnet` | HTTP | L1 |
| `base` | HTTP | OP (Base L2) |

Config variables needed for live networks: `SEPOLIA_RPC_URL`, `SEPOLIA_PRIVATE_KEY`, `MAINNET_RPC_URL`, `MAINNET_PRIVATE_KEY`, `BASE_RPC_URL`, `BASE_PRIVATE_KEY`.
