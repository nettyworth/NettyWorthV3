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
- **Chainlink VRF v2.5** (`@chainlink/contracts` v1.1.0) — verifiable on-chain randomness for PackMachine; uses `IVRFCoordinatorV2Plus` + `VRFV2PlusClient`
- **EIP-1167 minimal clones** (`Clones.clone()`) — used for PackMachine instances; each clone has its own ERC-7201 namespaced storage; this is an exception to the UUPS-only rule
- **Uniswap Permit2** — gasless USDC transfers via canonical deployment at `0x000000000022D473030F116dDEE9F6B43aC78BA3`; interface defined locally at `contracts/interfaces/ISignatureTransfer.sol`
- **viem** (not ethers.js) for all TypeScript contract interactions
- **ESM project** (`"type": "module"` in package.json)

## Contract Standards

All V3 contracts must implement these patterns consistently:

- **Upgradeability**: inherit `UUPSUpgradeable` (EIP-1822) — logic upgrades without changing proxy address; upgrade authorized by `UPGRADER_ROLE` (or `DEFAULT_ADMIN_ROLE` on PermissionManager itself). Exception: `PackMachine` uses EIP-1167 minimal clones instead of UUPS — it is not upgradeable by design.
- **Access control**: use `PermissionManager` + `PermissionConsumer` — do NOT use per-contract `AccessControl` or `Ownable`; see _Access Control Architecture_ below. Exceptions: `AssetLendingPool` uses `Ownable2StepUpgradeable` (single admin) and interacts with `PermissionManager` only via an external `STATE_MANAGER_ROLE` grant; `P2PTradeEscrow` uses `Ownable2StepUpgradeable` with no `PermissionManager` tie at all.
- **Reentrancy protection**: apply `nonReentrant` (from `ReentrancyGuard`, non-upgradeable variant) on state-changing functions that move assets or funds
- **Initializer pattern**: replace `constructor()` with `initialize()` protected by `initializer`; constructor contains only `_disableInitializers()`
- **Namespaced storage (ERC-7201)**: all mutable state in a `@custom:storage-location erc7201:nettyworth.storage.<ContractName>` struct with a deterministic slot — prevents collision across upgrades
- **OpenZeppelin version**: `@openzeppelin/contracts-upgradeable` v5.x (currently v5.6.1)

## Access Control Architecture

The protocol uses a hub-and-spoke permission model:

1. **PermissionManager** (hub) — single UUPS-upgradeable contract holding all role grants. Inherits `AccessControlEnumerableUpgradeable`. Upgrade auth: `DEFAULT_ADMIN_ROLE`.
2. **PermissionConsumer** (spoke base) — abstract contract storing a reference to the manager. Provides `onlyProtocolRole(bytes32)` modifier that calls `permissionManager.hasProtocolRole(role, _msgSender())`.
3. **AssetNFT** (spoke) — inherits `PermissionConsumer`; overrides `_msgSender()` for ERC-2771 meta-tx sender resolution.
4. **PackMachineFactory** (spoke) — UUPS-upgradeable; inherits `PermissionConsumer`; gates `createPackMachine` and admin setters.
5. **PackVRFRouter** (spoke) — UUPS-upgradeable; inherits `PermissionConsumer`; gates `requestRandomWords` and admin setters.
6. **PackMachine** (clone spoke) — EIP-1167 clone; does not store the manager address itself; delegates role checks to the factory via `IPackMachineFactory.hasProtocolRole(role, caller)`.
7. **BuybackPool** (spoke) — UUPS-upgradeable singleton; inherits `PermissionConsumer`; gates admin functions (`setDefaultBuybackBps`, `registerPackMachine`, etc.) with `PACK_OPERATOR_ROLE`; gates emergency operations with `DEFAULT_ADMIN_ROLE`; token registration authorized via internal `registeredPackMachines` mapping (not a role).
8. **AssetLendingPool** (independent admin) — UUPS-upgradeable singleton; uses `Ownable2StepUpgradeable` (single admin), **NOT** `PermissionConsumer` — the one protocol contract outside the hub-and-spoke model. Its only tie to PermissionManager is external: the deployed pool address must be granted `STATE_MANAGER_ROLE` so it can call `assetNFT.batchSetAssetState()` to move collateral between `Held` and `Loaned`.
9. **FeeController** (spoke) — UUPS-upgradeable singleton; inherits `PermissionConsumer`; all config setters gated by `DEFAULT_ADMIN_ROLE`; upgrade gated by `UPGRADER_ROLE`. Manages two independent fee types (collectible sale fee, redemption/shipment fee) with independent enable flags.
10. **NettyWorthMarketplace** (spoke) — UUPS-upgradeable singleton; inherits `PermissionConsumer`; **not** ERC-2771 (`_msgSender() == msg.sender`). `MARKETPLACE_ROLE` gates force-close/cancel auction operations and is the role the marketplace contract itself must hold so `AssetLendingPool.settleLoanRepaymentOnSale` authorizes its calls. Config setters gated by `DEFAULT_ADMIN_ROLE`; pause by `PAUSER_ROLE`; upgrade by `UPGRADER_ROLE`.
11. **P2PTradeEscrow** (independent admin) — UUPS-upgradeable singleton; uses `Ownable2StepUpgradeable` (single owner), **NOT** `PermissionConsumer` and no `Roles.sol` roles. Fully standalone — no `PermissionManager` tie (treats `AssetNFT` as a generic ERC721). Owner gates `pause`/`unpause` and UUPS upgrades; trade actions gated by initiator/counterparty identity, not roles.
12. **PackRegistry** (spoke) — UUPS-upgradeable singleton; inherits `PermissionConsumer`; single source of truth for all pack definitions (`Pack[]`) across every PackMachine clone, keyed by `(machine, packId)`; pack-config setters (`addPack`, `setPackPrice`, `setPackTierWeights`, `setPackBuybackAllocation`, `setPackActive`, `setPackStartTime`, `stopPack`) gated by `PACK_OPERATOR_ROLE`; bootstrap `registerMachine` gated by `onlyFactory` (msg.sender == stored factory address); wiring setter `setFactory` gated by `DEFAULT_ADMIN_ROLE`; upgrade gated by `UPGRADER_ROLE`. Clones read a `PackTypes.Pack memory` snapshot from this registry at the top of every `openPack`/`openPackWithPermit2`/`fulfillRandomness` call — machine-wide custody config (`buybackPool`, `authorizedDepositors`, `retentionThresholdBps`) stays on the clone.

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
- **Chainlink VRF v2.5 shared router**: single `PackVRFRouter` consumer dispatches randomness callbacks to the correct `PackMachine` clone — avoids Chainlink's per-subscription consumer address cap
- **EIP-1167 clones with ERC-7201 storage**: `PackMachine` is cloned, not proxied; each instance has its own namespaced storage slot; cannot be UUPS-upgraded after deployment
- **Permit2 gasless payments**: `openPackWithPermit2` pulls USDC via a pre-signed Permit2 authorization; canonical address is constant across all chains
- **EIP-712 play signatures**: `PACK_OPERATOR_ROLE` signs `OpenPack(address user, uint256 nonce)` off-chain; per-user nonces prevent replay; checked on every `openPack` / `openPackWithPermit2` call
- **Swap-and-pop prize pool**: random card selection in `fulfillRandomness` uses `index = word % poolLen`, swaps selected element with the last, then pops — O(1) removal without preserving order
- **Effective pool size**: `effectivePrizePoolSize` is decremented on VRF request (not fulfillment) to prevent over-committing cards; `resetEffectivePrizePoolSize()` is an admin escape hatch for stuck requests
- **Per-machine buyback rates**: `BuybackPool` stores a per-PackMachine buyback rate override in basis points via `packMachineBuybackBps` mapping (set by `PACK_OPERATOR_ROLE` via `setPackMachineBuybackBps`); a zero value falls through to the global `defaultBuybackBps` (default 80%); this allows different packages to have different rates (e.g. standard rips = 80%, premium rips = 90%)
- **Auto-redeposit on buyback**: after a buyback, `BuybackPool` approves the source PackMachine and calls `depositFromPool(tokenId, tier)` to return the NFT to the prize pool in O(1); if the source machine is deregistered, the NFT is held in the pool for admin rescue via `rescueNFT`
- **Asset-collateralized lending**: `AssetLendingPool` accepts AssetNFT as collateral; max loan = `LTV × Σ(appraisal values)`; interest fixed upfront (`principal × aprBps × duration / (365d × BPS)`); bundle loans up to 50 NFTs with `tokenIdToActiveLoan` double-collateralization guard; includes atomic marketplace-financing path (`financeMarketplacePurchase`)
- **3-phase default lifecycle**: defaulted loans pass through Acquisition (owner recycles asset into a PackMachine via `depositFromPool`) → public Auction (anyone buys at outstanding value) → perpetual FixedListing; phase computed from timestamps in `getDefaultPhase`; default accounting debits `totalDeposited` at default and re-credits on recovery
- **Synthetix reward-per-share lender interest**: external lender capital earns a configurable share (`lenderShareBps`) of loan interest via `accInterestPerShare` accumulator + per-lender `lenderRewardDebt`; remainder accrues to protocol; lender withdraw and claim are intentionally unpaused so lenders can always exit
- **Split config/logic via abstract base**: `AssetLendingPoolConfig` owns the ERC-7201 storage struct + all admin config setters; `AssetLendingPool` inherits it and contains only business logic — keeps the storage layout in one auditable place
- **Two-fee FeeController with independent toggles**: `FeeController` exposes `getCollectibleFee(amount)` and `getRedemptionFee(baseValue)` (each returns `(fee, enabled)`); collectible sale fee defaults 5% (max 10%), redemption fee defaults 5% (max 100%); each has its own enable flag so one can be paused without affecting the other
- **Hybrid no-escrow marketplace auctions**: `NettyWorthMarketplace` uses off-chain EIP-712 `SignedAuction` + `SignedBid` messages; `commitBid` materialises on-chain `AuctionState` on first valid bid (enforces reserve price, min increment, last-minute time extension); funds pulled from winner only at `settleAuction` — no upfront escrow; three typehashes: `SignedListing`, `SignedAuction`, `SignedBid`
- **Loan-aware atomic sale settlement**: on marketplace sale, if the token is collateralised in `AssetLendingPool`, the minimum price is principal + outstanding interest; the marketplace calls `settleLoanRepaymentOnSale(loanId, marketplace, buyer)` — the pool pulls its debt from the marketplace, releases the NFT to the buyer, and the seller receives only net proceeds; the marketplace must hold `MARKETPLACE_ROLE` for this call to be authorized
- **Safe royalty handling**: `NettyWorthMarketplace` queries ERC-2981 royalties via `try/catch` so a non-compliant collection cannot revert a sale; royalty is capped so `royalty + collectibleFee ≤ gross − loanDebt`
- **Atomic P2P asset swap escrow**: `P2PTradeEscrow` lets an initiator escrow an offered bundle (ERC20/721/1155, ≤50 assets per side) for a named counterparty; `acceptTrade` atomically pulls the requested bundle counterparty→initiator directly and releases the escrowed bundle contract→counterparty — only one side is ever held in escrow; no fees, no signatures, on-chain offers only; `deadline = 0` means never expires
- **Recoverable-while-paused escrow**: `P2PTradeEscrow` gates `createTrade`/`acceptTrade` with `whenNotPaused` but intentionally omits it on `cancelTrade`/`expireTrade` so escrowed assets are always reclaimable even when the contract is paused
- **Centralized pack config**: pack definitions (`pricePerPack`, `cardsPerPack`, `startTime`, `buybackAllocationBps`, `tierWeights`, `active`, `finished`) live in `PackRegistry` keyed by `(machine, packId)`; `PackMachine` clones hold no `Pack[]` array — they call `IPackRegistry.getPack(address(this), packId)` once per open flow (and once in `fulfillRandomness`) to get a `PackTypes.Pack memory` snapshot. Machine-wide custody config (`buybackPool`, `authorizedDepositors`, `retentionThresholdBps`) stays on the clone. `PackMachineFactory.createPackMachine` calls `PackRegistry.registerMachine` to bootstrap pack 0; the canonical `Pack` struct is defined in `contracts/lib/PackTypes.sol`

## Project Layout

- `contracts/` — Solidity source files
  - `contracts/interfaces/` — Interface definitions (`IPermissionManager`, `ITransferValidator`, `IPackMachine`, `IPackMachineFactory`, `IPackVRFRouter`, `IBuybackPool`, `ISignatureTransfer`, `IAssetLendingPool`, `IAssetNFT`, `IFeeController`, `INettyWorthMarketplace`, `IP2PTradeEscrow`, `IPackRegistry`)
  - `contracts/lib/` — Libraries (`Roles.sol` — protocol role constants; `PackTypes.sol` — shared `Pack` struct used by `PackRegistry` and `PackMachine`)
  - `contracts/test-helpers/` — Mocks for testing (`MockPermit2`, `MockVRFCoordinatorV2Plus`, `MockERC1155`, etc.)
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
| ---- | ---- | ----- |
| `hardhatMainnet` | Local simulated | L1 |
| `hardhatOp` | Local simulated | OP |
| `forkMainnet` | Local fork | L1 |
| `forkBase` | Local fork | OP (Base) |
| `forkSepolia` | Local fork | L1 testnet |
| `sepolia` | HTTP | L1 testnet |
| `mainnet` | HTTP | L1 |
| `base` | HTTP | OP (Base L2) |

Config variables needed for live networks: `SEPOLIA_RPC_URL`, `SEPOLIA_PRIVATE_KEY`, `MAINNET_RPC_URL`, `MAINNET_PRIVATE_KEY`, `BASE_RPC_URL`, `BASE_PRIVATE_KEY`.
