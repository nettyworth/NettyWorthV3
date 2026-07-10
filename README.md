# NettyWorth Smart Contracts V3

Solidity smart contracts for physical asset tokenization, targeting Ethereum mainnet and Base L2 (OP-stack).

Additional documentation:

- [Operator runbook](docs/ops-runbook.md) — deployment, role grants, emergency procedures
- [Marketplace frontend integration guide](docs/marketplace-frontend-integration.md) — frontend integration guide for the marketplace

## Tech Stack

| Layer | Technology |
| ----- | ---------- |
| Language | Solidity 0.8.28 |
| Framework | Hardhat 3 (beta) |
| Libraries | OpenZeppelin Contracts Upgradeable v5.6.1, ERC721A Upgradeable v4, Chainlink VRF v2.5, Uniswap Permit2 |
| Test runner | Foundry-style `.t.sol` + Node.js `node:test` |
| Chain interaction | viem |
| Package manager | pnpm |

## Project Layout

```text
contracts/
  AssetNFT.sol                    # ERC-721A asset tokenization with lifecycle states
  PackMachine.sol                 # Loot-pack NFT distribution (EIP-1167 clone); multi-pack; reads pack config from PackRegistry
  PackMachineFactory.sol          # Deploys and manages PackMachine clones (UUPS); wires PackRegistry + PackTierRegistry
  PackRegistry.sol                # Pack definitions per (machine, packId) — single source of truth (UUPS)
  PackTierRegistry.sol            # Per-(machine, tokenId, packId) tier assignments for all clones (UUPS)
  PackVRFRouter.sol               # Shared Chainlink VRF v2.5 consumer (UUPS)
  BuybackPool.sol                 # Guaranteed buyback pool for AssetNFTs (UUPS)
  PromoCodeRegistry.sol           # Promo/discount + buyback-rate code registry (UUPS)
  AssetLendingPool.sol            # Asset-collateralized lending pool (UUPS, Ownable2Step)
  AssetLendingPoolConfig.sol      # Lending pool storage layout + admin config (abstract base)
  FeeController.sol               # Marketplace & redemption fee rates (UUPS)
  NettyWorthMarketplace.sol       # AssetNFT marketplace: fixed-price + English auctions (UUPS)
  P2PTradeEscrow.sol              # Atomic P2P asset-swap escrow: ERC20/721/1155 bundles (UUPS, Ownable2Step)
  PermissionManager.sol           # Centralized role registry (AccessControlEnumerable)
  PermissionConsumer.sol          # Abstract base for role-gated contracts
  interfaces/
    IPackMachine.sol              # PackMachine interface (open methods take packId)
    IPackMachineFactory.sol       # Factory interface
    IPackRegistry.sol             # PackRegistry interface
    IPackVRFRouter.sol            # VRF router interface
    IBuybackPool.sol              # BuybackPool interface
    IPromoCodeRegistry.sol        # PromoCodeRegistry interface (PromoKind enum, PromoCode struct, errors, events)
    IPermissionManager.sol        # Permission manager interface
    ISignatureTransfer.sol        # Uniswap Permit2 signature transfer interface
    ITransferValidator.sol        # External transfer validation hook
    IFeeController.sol            # FeeController interface
    INettyWorthMarketplace.sol    # Marketplace interface (structs, events, errors)
    IAssetLendingPool.sol         # Lending pool interface (structs, events, errors)
    IAssetNFT.sol                 # Minimal AssetNFT interface used by the lending pool
    IAssetLendingPoolConfig.sol   # Config-domain interface: ConfigSnapshot struct, config events, admin setters/getters; runtime structs/errors stay in IAssetLendingPool
    IP2PTradeEscrow.sol           # P2P escrow interface (Asset/Trade structs, enums, events, errors)
    IPackTierRegistry.sol         # PackTierRegistry interface (setTier, deleteTier, deleteAllTiers, getTier)
  lib/
    Roles.sol                     # Protocol role constants library
    PackTypes.sol                 # Shared Pack struct used by PackRegistry and PackMachine
  test-helpers/                   # Mocks (MockPermit2, MockVRFCoordinatorV2Plus, etc.)
  test/                           # Foundry-style Solidity unit tests (.t.sol)
test/                             # TypeScript integration tests (node:test + viem)
scripts/
  deploy-permission-manager.ts    # Deploy PermissionManager + ERC1967 proxy
  deploy-asset-nft.ts             # Deploy AssetNFT + ERC1967 proxy
  upgrade-asset-nft.ts            # UUPS upgrade for AssetNFT proxy
  deploy-pack-machine.ts          # Deploy PackVRFRouter + PackMachine impl + PackMachineFactory + PackRegistry + PackTierRegistry + BuybackPool; wire factory ↔ registries
  create-pack-machine.ts          # Create a PackMachine clone via factory; register with VRFRouter + BuybackPool
  setup-pack-machine.ts           # Configure a PackMachine clone: set FMV bounds, set buyback rate, deposit NFTs (Mode A: env, Mode B: JSON file)
  deploy-promo-code-registry.ts   # Deploy PromoCodeRegistry + ERC1967 proxy; prints setPromoCodeRegistry wiring steps
  appraisals.example.json         # Sample appraisal payload for batch-set-appraisals.ts
  deposit.example.json            # Sample per-pack multi-tier deposit payload for setup-pack-machine.ts (DEPOSIT_FILE)
  fmv-bounds.example.json         # Sample FMV bounds payload for setup-pack-machine.ts (FMV_BOUNDS_FILE)
  batch-set-appraisals.ts         # Bulk-write NFT appraisal data (value/grade/category) to AssetLendingPool
  set-eligibility-controls.ts     # Set min appraisal value, min grade, and category lists on AssetLendingPool
  set-lender-config.ts            # Set lender revenue share (bps) and toggle lender deposits on AssetLendingPool
  set-callback-gas-limit.ts       # Update PackVRFRouter Chainlink callback gas limit
  set-key-hash.ts                 # Update PackVRFRouter Chainlink VRF key hash (gas lane)
  upgrade-pack-vrf-router.ts      # UUPS upgrade for PackVRFRouter proxy
  deploy-asset-lending-pool.ts    # Deploy AssetLendingPool + ERC1967 proxy; grant STATE_MANAGER_ROLE
  deploy-fee-controller.ts        # Deploy FeeController + ERC1967 proxy
  set-collectible-fee.ts          # Set collectible sale fee bps and enable it on FeeController (DEFAULT_ADMIN_ROLE)
  deploy-marketplace.ts           # Deploy NettyWorthMarketplace + ERC1967 proxy; wire pool + AssetNFT
  deploy-p2p-trade-escrow.ts      # Deploy P2PTradeEscrow + ERC1967 proxy; standalone (no protocol deps)
  seed-asset-nft.ts               # Dev helper: mint sample AssetNFT cards and seed appraisals
  send-op-tx.ts                   # OP chain transaction example
  set-finance-wallet.ts           # Set the finance wallet address on AssetLendingPoolConfig (owner)
  set-marketplace-allowlist.ts    # Toggle allowed collections / payment tokens on the marketplace (DEFAULT_ADMIN_ROLE)
  set-marketplace-lending-pool.ts # Point the marketplace at the lending pool via setLendingPool (DEFAULT_ADMIN_ROLE)
  set-term-config.ts              # Create or update a loan term slot on AssetLendingPoolConfig (owner)
  set-pack-machine-implementation.ts  # Deploy new PackMachine logic + call factory.setImplementation; new clones use the new logic
  relink-buyback-pool.ts          # Deploy a fresh BuybackPool proxy + relink every PackMachine clone to it (idempotent)
  check-buyback-registration.ts   # Read-only: report BuybackPool registration status and buyback config for PackMachine clones
  check-lending-pool-config.ts    # Read-only: print full AssetLendingPool / AssetLendingPoolConfig configuration
  check-pack-buyback.ts           # Read-only: print buybackPool address and buybackAllocationBps for one or more packs
  debug-token-eligibility.ts      # Read-only: trace every _isEligible() condition for given AssetNFT token IDs
  verify-storage-slots.ts         # Verify every hardcoded ERC-7201 slot constant matches the canonical keccak256 derivation
  verify-tenderly.ts              # Verify all deployed impls + ERC1967 proxies on Tenderly via forge verify-contract
foundry.toml                      # Foundry config mirroring Hardhat: solc 0.8.28, optimizer 200 runs, viaIR, evm cancun
docs/
  ops-runbook.md                  # Operator runbook: deployment, role grants, emergency procedures
  marketplace-frontend-integration.md  # Frontend integration guide for the marketplace
```

## AssetNFT Contract

`AssetNFT` is an ERC-721A NFT representing tokenized physical assets. Each token tracks a lifecycle state and enforces allowed transitions. Access control is delegated to the protocol-wide `PermissionManager` via `PermissionConsumer`.

### Roles

All roles are defined in `Roles.sol` and administered by `PermissionManager`.

| Role | Permission |
| ---- | ---------- |
| `DEFAULT_ADMIN_ROLE` | Manage all roles, configure royalties and transfer validator |
| `MINTER_ROLE` | Mint new tokens |
| `BURNER_ROLE` | Burn tokens |
| `STATE_MANAGER_ROLE` | Transition asset lifecycle states |
| `URI_SETTER_ROLE` | Update token and contract metadata URIs |
| `PAUSER_ROLE` | Pause and unpause transfers |
| `UPGRADER_ROLE` | Authorize UUPS contract upgrades |
| `BLACKLIST_ROLE` | Manage address blacklist |
| `MARKETPLACE_ROLE` | Protocol-wide marketplace operator — force-close/cancel auctions; authorizes `AssetLendingPool.settleLoanRepaymentOnSale` |

### Asset Lifecycle States

| State | Meaning |
| ----- | ------- |
| `Held` | In custody — default state, transfers and most actions allowed |
| `Listed` | On marketplace |
| `Loaned` | Locked as loan collateral |
| `Traded` | Locked in active trade or swap |
| `InShipment` | Physically in transit |
| `RemovedFromPlatform` | Terminal state (retired) |

Transfers are blocked unless the token is in `Held` state. Burns are only permitted from `Held` or `RemovedFromPlatform`.

### Key Features

- **ERC-721A** — gas-optimized batch minting (up to 50 per call)
- **UUPS upgradeable** (EIP-1822) — logic upgrades without changing the proxy address
- **PermissionManager access control** — centralized role registry, checks delegated via `PermissionConsumer`
- **ERC-2981 royalties** — per-token and default royalties, admin-configurable
- **ERC-2771 meta-transactions** — trusted forwarder support (immutable per implementation)
- **Blacklist system** — address-level transfer blocking via `BLACKLIST_ROLE`
- **External transfer validator** — pluggable `ITransferValidator` hook for custom transfer rules
- **Batch operations** — `batchMint`, `batchBurn`, `batchSetAssetState` (max 50 each)
- **Pausable transfers** — emergency stop via `PAUSER_ROLE`
- **ERC-7201 namespaced storage** — collision-safe across upgrades
- **ERC-7572 contract URI** — collection-level metadata

## PackMachine System

The PackMachine system is a loot-pack NFT distribution mechanism where users pay USDC to open a pack and receive randomly-selected AssetNFT tokens. Randomness is sourced from Chainlink VRF v2.5.

### Contracts

| Contract | Pattern | Role |
| -------- | ------- | ---- |
| `PackMachine` | EIP-1167 minimal clone | Individual pack instance — holds prize pool, processes opens; multi-pack; fetches pack config from `PackRegistry` |
| `PackMachineFactory` | UUPS-upgradeable singleton | Deploys clones, stores shared config, relays transfer validator hooks; wired to `PackRegistry` |
| `PackRegistry` | UUPS-upgradeable singleton | Single source of truth for all pack definitions, keyed by `(machine, packId)`; manages price, tier weights, FMV bounds, buyback allocation, start time, active/finished state |
| `PackTierRegistry` | UUPS-upgradeable singleton | Stores per-`(machine, tokenId, packId)` tier assignments for all clones; write-gated to registered pack machines; mirrors PackRegistry pattern |
| `PackVRFRouter` | UUPS-upgradeable singleton | Single Chainlink VRF consumer that routes callbacks to the correct clone |
| `BuybackPool` | UUPS-upgradeable singleton | Holds USDC from pack sales; pays guaranteed buyback to NFT holders; re-deposits NFTs into source machine |

### Per-pack card tiers

Each card (tokenId) can carry a different tier in each pack it belongs to — for example, card A is **Rare** in the Base pack but **Common** in the Elite pack. There are **6 tiers**:

| Tier index | Name | Default weight |
| ---------- | ---- | -------------- |
| 0 | Base | 70.40% |
| 1 | Common | 25.00% |
| 2 | Uncommon | 4.00% |
| 3 | Rare | 0.50% |
| 4 | Ultra Rare | 0.09% |
| 5 | Grail | 0.01% |

Per-pack tier data lives in **PackTierRegistry**, keyed by `(machine, tokenId, packId)`. Clones write to PackTierRegistry during `deposit` and `setPackEligibility`, and read from it during VRF fulfillment.

**Before depositing**, per-`(packId, tier)` FMV bounds must be configured:

```bash
packRegistry.setPackTierFmvBounds(clone, packId, minFmv[6], maxFmv[6])
# values in payment-token base units (e.g. USDC micro-units)
# all 6 tier slots must be provided; set maxFmv[tier] = 0 to disable a tier
```

`deposit` reverts `PackMachine__TierFmvUnset(packId, tier)` if the used tier has no bounds set.

**Flat-encoding deposit API:**

```text
deposit(tokenIds[], packCounts[], packIds[], tiers[], owner)
```

`packCounts[i]` consecutive entries from the flat `packIds`/`tiers` arrays give token `i`'s assignments. A single token can be deposited into multiple packs in one call (each with a different tier).

**Dormant tier map**: tier assignments survive a win and are restored automatically on `depositFromPool` (BuybackPool / AssetLendingPool re-deposit path) — no extra tier parameter needed from the caller.

### Pack definitions (PackRegistry)

All pack configuration lives in `PackRegistry`, not on the clone. A machine can host multiple packs — `packId` is the zero-based index, and pack `0` is bootstrapped automatically when the clone is created.

The canonical `PackTypes.Pack` struct (defined in `contracts/lib/PackTypes.sol`):

| Field | Type | Description |
| ----- | ---- | ----------- |
| `pricePerPack` | `uint128` | Payment-token base units charged per open |
| `cardsPerPack` | `uint8` | Cards dispensed per open (≥ 1) |
| `startTime` | `uint40` | Unix timestamp before which opens revert |
| `buybackAllocationBps` | `uint16` | Share of pack price routed to BuybackPool (0–10000 bps) |
| `active` | `bool` | Reversibly pause/unpause opens via `setPackActive` |
| `finished` | `bool` | Permanently stop opens via `stopPack` (irreversible) |
| `tierWeights` | `uint32[5]` | Probability weights per tier (Base/Common/Uncommon/Rare/Ultra), must sum to 10000; default `[7500, 1950, 400, 100, 50]` |

#### PackRegistry access control

| Function | Guard |
| -------- | ----- |
| `addPack`, `setPackPrice`, `setPackTierWeights`, `setPackBuybackAllocation`, `setPackActive`, `setPackStartTime`, `stopPack` | `PACK_OPERATOR_ROLE` |
| `setFactory` | `DEFAULT_ADMIN_ROLE` |
| `registerMachine` | `onlyFactory` (called internally by `createPackMachine`) |
| `_authorizeUpgrade` | `UPGRADER_ROLE` |

Machine-wide custody config — `buybackPool`, `authorizedDepositors`, and `retentionThresholdBps` — stays on the clone itself.

### Pack Open Call Flow

```text
User ──► PackMachine.openPack(user, packId, sig)
              │
              ├── reads PackTypes.Pack from PackRegistry.getPack(machine, packId)
              ├── pulls full (post-discount) payment into this contract (escrow)
              └──► PackVRFRouter.requestRandomWords() ──► Chainlink VRF
                                                               │
User ◄── NFT transferred ◄── PackMachine.fulfillRandomness() ◄── PackVRFRouter.rawFulfillRandomWords()
                                        │
                                        ├──► BuybackPool.registerToken() (try/catch — failure emits event, does not revert)
                                        └──► Settle escrowed payment:
                                               - wonCards/cardsPerPack share → BuybackPool + financeWallet
                                               - failed cards → refund to user
```

### Buyback Call Flow

```text
(later, card holder wants to sell back)

User ──► BuybackPool.buyback(tokenId)
              │
              ├── USDC transferred to user (80% of per-card price, or 90% with protection)
              └── NFT auto-deposited back into source PackMachine clone
```

### PackMachine Roles

| Role | Permission |
| ---- | ---------- |
| `PACK_OPERATOR_ROLE` | Create pack machines, deposit/withdraw cards, manage pack config on PackRegistry, stop machine, authorize VRF |
| `BUYBACK_POOL_ROLE` | Reserved for BuybackPool contract to call `depositFromPool` on PackMachine instances |

`PACK_OPERATOR_ROLE` holders also sign the off-chain EIP-712 `OpenPack` authorization required per pack open.

### PackMachine Features

- **EIP-1167 minimal clones** — cheap per-machine deployment; each clone has its own ERC-7201 namespaced storage
- **Multi-pack support** — each clone can host multiple packs (`packId` 0, 1, 2…); pack 0 bootstrapped at creation, further packs added via `PackRegistry.addPack`
- **Centralized pack config via PackRegistry** — pack definitions (`pricePerPack`, `cardsPerPack`, `tierWeights`, `buybackAllocationBps`, `startTime`, `active`, `finished`) fetched live from `PackRegistry` on every open; machine-wide custody config (`buybackPool`, `authorizedDepositors`, `retentionThresholdBps`) stays on the clone
- **Chainlink VRF v2.5** — verifiable on-chain randomness; shared router avoids Chainlink's per-subscription consumer cap
- **Escrowed payment model** — pack payment is held in the clone contract until `fulfillRandomness` distributes it: cards actually won receive their proportional share (buyback portion → BuybackPool, remainder → financeWallet); any cards that fail (empty pool or transfer revert) are refunded to the user proportionally. `rescueERC20` is guarded by `totalEscrowed` so pending user funds can never be swept.
- **Permit2 gasless payments** — `openPackWithPermit2(user, packId, …)` uses Uniswap's canonical Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) for relayer-submitted USDC transfers; payment is escrowed in the clone until VRF settles
- **EIP-712 play signatures** — typehash `OpenPack(address user, uint256 packId, uint256 nonce)`; operator signs each open off-chain; `packId` binds the signature to the intended pack, preventing cross-pack replay; per-user nonce prevents replay within a pack
- **Swap-and-pop prize pool** — O(1) random card selection and removal from the shared machine-wide prize pool array
- **Effective pool size accounting** — pool size decremented immediately on VRF request, preventing over-commitment before randomness arrives
- **Transfer validator relay** — factory proxies Creator Token Standard `beforeAuthorizedTransfer`/`afterAuthorizedTransfer` hooks for AssetNFT royalty enforcement

## BuybackPool Contract

`BuybackPool` is a UUPS-upgradeable pool that holds USDC allocations from pack purchases and allows token holders to sell AssetNFT cards back at a guaranteed percentage of the original per-card price. Bought-back NFTs are automatically re-deposited into their source PackMachine clone, returning them to the prize pool.

### How It Fits the System

1. When a user opens a pack, `PackMachine.fulfillRandomness()` calls `BuybackPool.registerToken()`, recording the per-card price, rarity tier, and whether buyback protection was purchased at pack-open time.
2. At any time, the token holder calls `buyback(tokenId)` or `buybackWithProtection(tokenId)` to sell the card back.
3. USDC is paid out, the NFT is transferred to the pool, and the pool auto-deposits it back into the originating PackMachine's prize pool via `depositFromPool`.

### Buyback Rates

| Mode | Default | Description |
| ---- | ------- | ----------- |
| Standard | 80% (8000 bps) | Available for all registered tokens |
| Protected | 90% (9000 bps) | Requires buyback protection purchased at pack-open time |

Per-tier overrides (5 tiers: Base/Common/Uncommon/Rare/Ultra) can be set by `PACK_OPERATOR_ROLE`. A zero override falls through to the global default.

### BuybackPool Roles

| Role | Permission |
| ---- | ---------- |
| `PACK_OPERATOR_ROLE` | Register/deregister PackMachines, set buyback rates (default, protected, per-tier) |
| `PAUSER_ROLE` | Pause and unpause the contract |
| `DEFAULT_ADMIN_ROLE` | Emergency USDC withdrawal (only while paused), rescue stuck NFTs, UUPS upgrade authorization |
| `UPGRADER_ROLE` | Authorize UUPS contract upgrades |

### BuybackPool Features

- **UUPS upgradeable** (EIP-1822) — logic upgrades without changing the proxy address
- **PermissionConsumer access control** — centralized role checks via PermissionManager
- **ERC-7201 namespaced storage** — collision-safe across upgrades
- **ReentrancyGuard** — protects buyback execution from reentrancy
- **Pausable** — emergency stop via `PAUSER_ROLE`
- **Tiered buyback rates** — per-tier overrides for both standard and protected rates; zero means use global default
- **Auto-redeposit** — bought-back NFTs automatically returned to the source PackMachine's prize pool
- **Idempotent token registration** — `registerToken` silently overwrites a stale active record instead of reverting; prevents a prior win/recycle cycle from permanently blocking VRF fulfillment for a recycled card
- **Emergency withdrawal** — admin can drain USDC to financeWallet while paused
- **NFT rescue** — admin can recover stuck NFTs (e.g. if source PackMachine is deregistered)

## PromoCodeRegistry Contract

`PromoCodeRegistry` is a UUPS-upgradeable singleton that stores and validates off-chain promo codes. A `codeId` is the `keccak256` hash of the off-chain code string. Each code belongs to one of two kinds (the `PromoKind` enum):

| Kind | Effect | Allowed bps values | Redeemer |
| ---- | ------ | ------------------ | -------- |
| **Discount** | Reduces PackMachine pack price | 1000 / 1500 / 2000 / 2500 (10–25%) | Any registered PackMachine clone (via `factory.isPackMachine`) |
| **Buyback** | Raises BuybackPool payout from 80% | 9000 / 9500 / 9800 (90–98%) | The stored BuybackPool singleton address |

### Code Configuration

Each code carries independent guards:

| Field | Description |
| ----- | ----------- |
| `expiry` | Unix timestamp after which redemption reverts (0 = no expiry) |
| `maxRedemptions` | Total-use cap (0 = uncapped) |
| `restricted` | If `true`, only allowlisted addresses may redeem |
| `oncePerUser` | If `true`, each address may redeem at most once |
| `active` | Admin kill switch; toggled independently of `expiry` |
| `machine` *(Discount only)* | Scopes the code to a single PackMachine clone (`address(0)` = valid on any registered machine) |

### Machine Binding

Discount codes can be scoped to a specific PackMachine clone via the `machine` field passed to `createCode`. When `machine != address(0)`, `redeemDiscount` reverts with `PromoCodeRegistry__WrongMachine(codeId, expected, actual)` if called from any other clone. Global codes (`machine == address(0)`) remain valid on all registered machines. The `CodeCreated` event includes the `machine` field.

### Discount Refund

`refundDiscount(codeId, user)` reverses a previously consumed discount code — it decrements `redeemedCount` and clears the `oncePerUser` flag for that user. Only callable by the same PackMachine clone that originally redeemed the code. This is called by PackMachine in the all-cards-failed VRF path, wrapped in `try/catch`, so a refund failure can never block the USDC refund to the user. Emits `CodeRefunded(codeId, user, kind, redeemedCount)`.

### PromoCodeRegistry Roles

| Role | Permission |
| ---- | ---------- |
| `PACK_OPERATOR_ROLE` | `createCode`, `setActive`, `setExpiry`, `setMaxRedemptions`, `addToAllowlist`, `removeFromAllowlist` |
| `DEFAULT_ADMIN_ROLE` | `setPackMachineFactory`, `setBuybackPool` |
| `PAUSER_ROLE` | `pause`, `unpause` |
| `UPGRADER_ROLE` | `_authorizeUpgrade` |

Redemption callers are not role-gated; instead `redeemDiscount` validates `factory.isPackMachine(msg.sender)` and `redeemBuyback` validates `msg.sender == storedBuybackPool`.

### PromoCodeRegistry Features

- **UUPS upgradeable** (EIP-1822) — logic upgrades without changing the proxy address
- **PermissionConsumer access control** — centralized role checks via PermissionManager
- **ERC-7201 namespaced storage** — collision-safe across upgrades
- **Pausable** — emergency stop via `PAUSER_ROLE`; pausing blocks all redemption and refund calls
- **Two-kind dispatch** — Discount and Buyback codes share one registry; `_validateAndConsume` enforces the expected kind on every redemption
- **Machine-scoped discount codes** — optional per-clone scoping prevents a code issued for one machine from being used on another
- **Discount refund** — `refundDiscount` allows PackMachine to restore a code on total VRF failure, keeping the user's redemption quota intact

## AssetLendingPool Contract

`AssetLendingPool` is a UUPS-upgradeable, platform-operated lending pool that accepts `AssetNFT` tokens as collateral. It is funded by both the platform treasury (owner capital) and external lenders. Loans use fixed terms with interest computed upfront. The contract also supports an atomic marketplace-financing path (buyer pays a deposit, pool finances the remainder). Admin control uses `Ownable2StepUpgradeable` — a deliberate deviation from the `PermissionConsumer` pattern used by the rest of the protocol.

Configuration setters, the ERC-7201 storage layout, and eligibility helpers live in the abstract base `AssetLendingPoolConfig` (interface: `IAssetLendingPoolConfig`); business logic lives in the concrete `AssetLendingPool`. `IAssetLendingPoolConfig` defines the `ConfigSnapshot` struct (14 fields including `maxUtilizationBps`), all config-domain events (e.g. `MaxUtilizationUpdated`), and the `getConfigSnapshot()` view that is merged into `getPoolInfo()`.

### How It Works

1. **Borrow** — a borrower collateralizes one token (`borrow`) or up to 50 tokens as a bundle (`borrowBundle`). The maximum loan amount is `LTV × Σ(appraisal values)`. Interest is fixed upfront and deducted from the disbursement.
2. **Repay** — the borrower repays principal + pre-fixed interest before the term deadline, reclaiming all collateral atomically.
3. **Marketplace financing** — `financeMarketplacePurchase` atomically purchases a marketplace-listed NFT and opens a loan. The caller passes the seller's EIP-712 `SignedListing` (verified on-chain against the marketplace domain) along with their deposit. The pool finances `listingPrice − depositAmount` (capped at LTV × appraisalValue), pays the seller the full listing price, and the token becomes collateral immediately. A per-seller `financeNonces` mapping prevents replay of the listing signature.
4. **Lender capital** — external lenders call `lenderDeposit` / `lenderWithdraw` / `claimLenderInterest`. Withdraw and claim deliberately omit `whenNotPaused` so lenders can always exit even during an emergency pause.

### Loan Terms (defaults)

| Term ID | Duration | APR |
| ------- | -------- | --- |
| `0` | 7 days | 10% (1000 bps) |
| `1` | 15 days | 15% (1500 bps) |
| `2` | 30 days | 20% (2000 bps) |

Interest formula: `principal × aprBps × duration / (365 days × BPS)`. Term configs are admin-adjustable via `setTermConfig`.

### Pool Utilization Cap

A pool-wide cap prevents the pool from being fully committed to active loans, reserving a fraction of capital for lender withdrawals.

```text
maxBorrowable = totalDeposited × maxUtilizationBps / 10000
```

A new loan reverts with `AssetLendingPool__ExceedsMaxUtilization` if `totalBorrowed + loanAmount > maxBorrowable`. Repaying a loan frees headroom immediately.

| Parameter | Default | Range | Setter |
| --------- | ------- | ----- | ------ |
| `maxUtilizationBps` | 8000 (80%) | 1–10000 | `setMaxUtilizationBps` (owner-only) |

- `10000` = no reserve (100% utilization, legacy behavior).
- Invalid values (`0` or `>10000`) revert with `AssetLendingPool__InvalidBps`.
- Emits `MaxUtilizationUpdated(oldValue, newValue)` on change.
- `PoolInfo.maxUtilizationBps` exposes the current setting via `getPoolInfo()`.

### Default Lifecycle

When the borrower misses repayment, the owner calls `initiateDefault` (or the backward-compatible alias `liquidate`). The asset then passes through three phases (durations configurable):

| Phase | Default duration | Who can act | Outcome |
| ----- | ---------------- | ----------- | ------- |
| Acquisition | 24 hours | Owner only | `acquireDefaultedAsset` — recycles NFT into a PackMachine via `depositFromPool` |
| Auction | 7 days | Anyone | `purchaseDefaultedAsset` — public purchase at outstanding value |
| Fixed listing | Perpetual | Anyone | Same public purchase function at fixed outstanding value |

### Roles / Access Control

Unlike the rest of the protocol, `AssetLendingPool` uses **`Ownable2StepUpgradeable`** (single admin) rather than `PermissionConsumer`. All admin functions (`initiateDefault`, `deposit`/`withdraw`, config setters, `pause`/`unpause`, `rescueNFT`, UUPS upgrade) are gated by `onlyOwner`.

The pool's only dependency on `PermissionManager` is external: the deployed pool address **must be granted `STATE_MANAGER_ROLE`** on `PermissionManager` so the pool can call `assetNFT.batchSetAssetState()` to flip collateral tokens between `Held` and `Loaned` states.

### AssetLendingPool Features

- **UUPS upgradeable** (EIP-1822) — logic upgrades without changing the proxy address; upgrade authorized by owner
- **ERC-7201 namespaced storage** — storage layout owned by `AssetLendingPoolConfig`, collision-safe across upgrades
- **ReentrancyGuard** — all asset/fund-moving external functions are `nonReentrant`
- **Pausable** — emergency stop for borrowing and owner operations; lender withdraw and interest claim remain unpaused
- **Bundle loans** — up to 50 NFTs per loan; `tokenIdToActiveLoan` mapping prevents double-collateralization
- **Eligibility checks** — per-token: minimum appraisal value (default $100), minimum grade, category whitelist, appraisal staleness guard (`maxAppraisalAge`, default 7 days; 0 disables)
- **Synthetix reward-per-share lender interest** — `accInterestPerShare` accumulator + per-lender `lenderRewardDebt`; `lenderShareBps` (e.g. 80%) splits interest between lenders and protocol
- **Pool utilization cap** — `maxUtilizationBps` (default 80%) caps the fraction of deposited capital committed to active loans; the reserve remains freely withdrawable by lenders; `PoolInfo.maxUtilizationBps` exposes the live value
- **Split capital accounting** — owner/treasury deposits tracked separately from lender capital and protocol interest
- **Configurable origination fee** — `originationFeeBps` deducted from disbursement (or pulled from buyer on top of deposit in the marketplace path), sent to `feeWallet`
- **EIP-712 verified marketplace financing** — `financeMarketplacePurchase` verifies the seller's `SignedListing` on-chain against the marketplace's EIP-712 domain before executing; `financeNonces` mapping prevents listing-signature replay
- **`liquidate()` alias** — backward-compatible alias for `initiateDefault()` for off-chain callers
- **PackMachine recycle integration** — defaulted assets can be deposited directly into any registered PackMachine via `depositFromPool`
- **NFT rescue** — `rescueNFT` admin escape hatch for stuck tokens

## FeeController Contract

`FeeController` is a UUPS-upgradeable contract that manages two independent fee types for the protocol: a collectible sale fee (charged by the marketplace on every sale) and a redemption/shipment fee (charged when a physical asset is redeemed). Each fee type has its own enable/disable toggle, so one can be adjusted or paused without affecting the other. Access control is via `PermissionConsumer` / `PermissionManager`.

### Fee Types

| Fee | Default | Maximum | Toggle |
| --- | ------- | ------- | ------ |
| Collectible sale fee | 5% (500 bps) | 10% (1000 bps) | `collectibleFeesEnabled` |
| Redemption / shipment fee | 5% (500 bps) | 100% (10 000 bps) | `redemptionFeeEnabled` |

All fees route to the `protocolFeeRecipient` (platform treasury). Views `getCollectibleFee(amount)` and `getRedemptionFee(baseValue)` each return `(fee, enabled)` so callers can skip the transfer when a fee type is disabled.

### FeeController Roles

| Role | Permission |
| ---- | ---------- |
| `DEFAULT_ADMIN_ROLE` | Set fee rates, toggle enable flags, update fee recipient |
| `UPGRADER_ROLE` | Authorize UUPS contract upgrades |

### FeeController Features

- **UUPS upgradeable** (EIP-1822) — logic upgrades without changing the proxy address
- **PermissionConsumer access control** — centralized role checks via PermissionManager
- **ERC-7201 namespaced storage** — collision-safe across upgrades
- **Independent fee toggles** — collectible and redemption fees can be enabled/disabled separately
- **Capped rates** — collectible fee hard-capped at 10%; redemption fee at 100%
- **Atomic fee queries** — `getCollectibleFee` / `getRedemptionFee` return both the computed amount and whether the fee is active in one call

---

## NettyWorthMarketplace Contract

`NettyWorthMarketplace` is a UUPS-upgradeable marketplace for `AssetNFT` tokens. It supports three trade modes: **fixed-price sales** (off-chain EIP-712 signed listings), **hybrid English auctions** (seller and bidders sign messages off-chain; minimal on-chain state enforces rules at commitment/settlement), and **buyer offers** (buyer signs a `SignedOffer`, seller accepts on-chain). USDC / ERC-20 only — no native ETH. Access control is via `PermissionConsumer` / `PermissionManager`.

### Trade Flows

#### Fixed-price sales

1. The seller signs a `SignedListing` EIP-712 message off-chain (collection, tokenId, price, payment token, expiry, nonce).
2. The buyer calls `buyWithSignature(listing, sig)` — the marketplace verifies the signature, marks the nonce used (CEI), then executes the sale atomically.

#### Buyer offers

1. The buyer signs a `SignedOffer` EIP-712 message off-chain (collection, tokenId, price, payment token, expiry, nonce).
2. The token owner calls `acceptOffer(offer, sig)` — the marketplace verifies the offer, atomically transfers funds to the seller and the NFT to the buyer. Emits `OfferAccepted`.

#### Hybrid English auctions

1. The seller signs a `SignedAuction` off-chain (reserve price, min increment, start/end times, `extensionWindow` + `extensionDuration`, nonce).
2. Bidders sign `SignedBid` messages off-chain (auctionId, amount, nonce, expiry).
3. `commitBid(SignedAuction auction, bytes auctionSig, SignedBid bid, bytes bidSig)` is called on-chain — the first valid bid **materialises** an `AuctionState` (reserve enforced); subsequent bids must exceed `highestBid + minIncrement`. If a bid lands within `extensionWindow` of `endTime`, the auction extends by `extensionDuration` (anti-snipe; emits `newEndTime` in `BidCommitted`). No funds move at commitment.
4. After `endTime`, anyone calls `settleAuction(auctionId)` — or `MARKETPLACE_ROLE` can force-close early. The winner's payment is pulled and the NFT is delivered atomically.
5. `cancelAuction(auctionId)` (MARKETPLACE_ROLE) or `cancelNonce(nonce)` (per-signer) cancels before settlement.
6. Views: `getAuction(auctionId)`, `isNonceUsed(signer, nonce)`, `hashAuction(auction)`.

#### Pool-default auction flow

When a borrower defaults, the lending pool can list the collateral directly on the marketplace:

1. `MARKETPLACE_ROLE` calls `listDefaultedAsset(loanId, tokenId, reservePrice, minIncrement, startTime, endTime, extensionWindow, extensionDuration)` — the lending pool is the implicit seller; collectible fees and royalties are waived; proceeds go fully to the pool to cover the outstanding debt. Emits `DefaultedAssetListed`. Single-token loans only (`Marketplace__PoolDefaultSingleTokenOnly` if a bundle).
2. Bidders call `commitPoolBid(bytes32 auctionId, SignedBid bid, bytes bidSig)` instead of `commitBid`.
3. Settlement via the normal `settleAuction` path; net debt repaid to pool, excess (if any) returned to borrower.

#### Loan-aware settlement

If the token is collateralised in `AssetLendingPool`, the minimum acceptable sale price equals principal + outstanding interest. On sale, the loan debt is repaid atomically via `settleLoanRepaymentOnSale` — the pool releases the NFT directly to the buyer, and the seller receives only the net proceeds.

### Fees & Royalties

Fees are deducted from gross proceeds before the seller receives anything:

1. **Collectible fee** — queried from `FeeController.getCollectibleFee(gross)` (default 5%), sent to `treasury`.
2. **ERC-2981 royalty** — queried via `try/catch` so a non-compliant collection cannot revert the sale; royalty is capped so `royalty + collectibleFee ≤ gross − loanDebt`.

The `SaleExecuted` event exposes the full breakdown: `gross`, `collectibleFee`, `royalty`, `loanRepaid`, `sellerProceeds`. Pool-default auctions waive both the collectible fee and royalty (proceeds go entirely to the pool).

**Notable errors:** `Marketplace__ReserveBelowOutstanding` (reserve price less than outstanding loan debt), `Marketplace__NotPoolDefaultAuction` (pool-bid functions called on a regular auction), `Marketplace__PoolDefaultSingleTokenOnly` (bundle loan submitted to the default-auction path), `Marketplace__NotSeller`, `Marketplace__NoBids`.

### NettyWorthMarketplace Roles

| Role | Permission |
| ---- | ---------- |
| `MARKETPLACE_ROLE` | Force-close or cancel any auction; contract itself must hold this role for `AssetLendingPool` to authorize `settleLoanRepaymentOnSale` |
| `DEFAULT_ADMIN_ROLE` | Update FeeController, LendingPool, treasury, allowed collections, allowed payment tokens |
| `PAUSER_ROLE` | Pause and unpause the contract |
| `UPGRADER_ROLE` | Authorize UUPS contract upgrades |

### Marketplace Features

- **UUPS upgradeable** (EIP-1822) — logic upgrades without changing the proxy address
- **PermissionConsumer access control** — centralized role checks via PermissionManager; not ERC-2771 (`_msgSender() == msg.sender`)
- **ERC-7201 namespaced storage** — collision-safe across upgrades
- **ReentrancyGuard** — protects `buyWithSignature`, `acceptOffer`, `commitBid`, and `settleAuction`
- **Pausable** — emergency stop via `PAUSER_ROLE`
- **EIP-712 signatures** — four typehashes: `SignedListing`, `SignedAuction`, `SignedBid`, `SignedOffer`; domain `("NettyWorthMarketplace", "1")`
- **Three trade modes** — fixed-price (`buyWithSignature`), buyer offers (`acceptOffer`), and hybrid English auctions (`commitBid` → `settleAuction`)
- **No-escrow hybrid auctions** — funds pulled from winner at settlement only; last-minute anti-snipe extension via `extensionWindow`/`extensionDuration`
- **Pool-default auction flow** — `listDefaultedAsset` + `commitPoolBid` lets the lending pool sell defaulted collateral; fees and royalties waived; proceeds cover loan debt
- **Per-signer nonce replay protection** — `usedNonces` mapping consumed CEI-style; user-cancellable via `cancelNonce`; auction-cancellable via `cancelAuction`
- **Collection + payment-token whitelists** — `allowedCollections` and `allowedPaymentTokens` mappings
- **Loan-aware settlement** — atomic loan repayment on sale; min price enforced against outstanding debt; `SaleExecuted` event breaks down gross/fee/royalty/loanRepaid/sellerProceeds
- **Safe royalty handling** — ERC-2981 queried in `try/catch`; royalty capped against net proceeds
- **USDC / ERC-20 only** — no native ETH accepted

---

## P2PTradeEscrow Contract

`P2PTradeEscrow` is a UUPS-upgradeable, escrow-based atomic swap contract. An `initiator` locks an offered bundle of assets on-chain for a named `counterparty`, who can accept by providing a requested bundle in return. Unlike the no-escrow marketplace, the initiator's offered assets are held in the contract until the trade is accepted, cancelled, or expired. Access control uses `Ownable2StepUpgradeable` (single owner) — this contract is **fully standalone** and has no dependency on `PermissionManager` or protocol roles.

Supports any combination of **ERC20, ERC721, and ERC1155** assets, up to 50 assets per side. No fees, no signatures, no native ETH.

### Trade Flow

1. **`createTrade(counterparty, offered, requested, deadline)`** — Initiator specifies a designated counterparty, an offered bundle, a requested bundle, and an optional deadline (`0` = never expires). Offered assets are immediately pulled from the initiator into the contract. Status: `Active`.
2. **`acceptTrade(tradeId)`** — Only the designated `counterparty` may call. Atomically: (a) pulls the requested bundle from the counterparty directly to the initiator (never escrowed), then (b) releases the escrowed offered bundle from the contract to the counterparty. Status: `Accepted`.
3. **`cancelTrade(tradeId)`** — Only the `initiator`. Returns all escrowed offered assets to the initiator. Status: `Cancelled`. Available even when the contract is paused.
4. **`expireTrade(tradeId)`** — Callable by anyone once `deadline` has passed (and `deadline != 0`). Returns escrowed assets to the initiator. Status: `Expired`. Available even when the contract is paused.

### Access Control

| Actor | Permission |
| ----- | ---------- |
| Owner (`Ownable2StepUpgradeable`) | `pause` / `unpause`; authorize UUPS upgrades |
| Initiator | `cancelTrade` |
| Counterparty | `acceptTrade` |
| Anyone (post-deadline) | `expireTrade` |

> **No protocol roles.** This contract does not inherit `PermissionConsumer` and does not use any `Roles.sol` constants. It is independent of `PermissionManager`.

### P2PTradeEscrow Features

- **UUPS upgradeable** (EIP-1822) — logic upgrades without changing the proxy address
- **Ownable2Step single owner** — NOT `PermissionConsumer`; upgrade and pause gated by owner only
- **ERC-7201 namespaced storage** — collision-safe across upgrades (`erc7201:nettyworth.storage.P2PTradeEscrow`)
- **ReentrancyGuard** — protects `createTrade`, `acceptTrade`, `cancelTrade`, and `expireTrade`
- **Pausable with safe cancel/expire** — `createTrade`/`acceptTrade` respect `whenNotPaused`; `cancelTrade`/`expireTrade` intentionally omit it so escrowed assets are always reclaimable
- **ERC20 / ERC721 / ERC1155** — ERC20 via `SafeERC20`; ERC1155 via `safeTransferFrom` with `ERC1155Holder`; ERC721 via `transferFrom`
- **Bundle cap `MAX_BUNDLE = 50`** — per side; both offered and requested bundles must be non-empty
- **Deadline** — `uint64`; `0` means no expiry; anyone can call `expireTrade` once expired
- **No fees, no signatures, no ETH** — pure on-chain atomic swap; no EIP-712 off-chain flow
- **CEI ordering** — trade status written before all external transfers in every function
- **Standalone** — no `PermissionManager`, no `FeeController`, no lending pool integration; treats `AssetNFT` as a generic ERC721

---

## PermissionManager Contract

`PermissionManager` is the centralized role registry for the protocol. It inherits `AccessControlEnumerableUpgradeable` and exposes `hasProtocolRole(bytes32 role, address account)` for consumers to query.

- Deployed as a UUPS-upgradeable proxy, independent of AssetNFT
- All 8 protocol roles plus `DEFAULT_ADMIN_ROLE` are administered here
- Consumer contracts inherit `PermissionConsumer`, which stores a reference to the manager and provides the `onlyProtocolRole` modifier
- Two-step manager migration on consumers (propose → accept) prevents accidental loss of control

## Getting Started

### Prerequisites

- Node.js 20+
- pnpm 11+

### Install

```bash
pnpm install
```

### Environment Variables

Copy and fill in the required config variables for live networks:

```bash
# RPC endpoints
SEPOLIA_RPC_URL=
MAINNET_RPC_URL=
BASE_RPC_URL=

# Deployer private keys
SEPOLIA_PRIVATE_KEY=
MAINNET_PRIVATE_KEY=
BASE_PRIVATE_KEY=

# --- deploy-asset-nft.ts (optional — falls back to deployments/<network>.json) ---
PERMISSION_MANAGER_PROXY=
ASSET_NFT_NAME=
ASSET_NFT_SYMBOL=
ASSET_NFT_CONTRACT_URI=
ASSET_NFT_ROYALTY_RECEIVER=
ASSET_NFT_ROYALTY_FEE=

# --- deploy-pack-machine.ts (required) ---
PAYMENT_TOKEN=                    # ERC-20 payment token address (e.g. USDC)
FINANCE_WALLET=                   # Wallet that receives pack-sale proceeds
VRF_COORDINATOR=                  # Chainlink VRFCoordinatorV2Plus address for the target chain
VRF_SUBSCRIPTION_ID=              # Chainlink subscription ID (must be funded)
VRF_KEY_HASH=                     # Chainlink key hash (gas lane) for the target chain

# --- create-pack-machine.ts (required) ---
PRICE_PER_PACK=                   # Pack price in payment-token base units (e.g. 10000000 = 10 USDC)
CARDS_PER_PACK=                   # Number of cards dispensed per pack (1–255)
START_TIME=                       # Optional: Unix timestamp for when packs can be opened (default: now)

# --- setup-pack-machine.ts ---
# Mode A (env): deposit all tokens into one pack
TOKEN_IDS=                        # Comma-separated token IDs or range (e.g. 1-50 or 1,2,3) to deposit
TIERS=                            # Comma-separated tier values (0=Base…5=Grail) matching TOKEN_IDS; single value applies to all
PACK_ID=                          # (optional) Pack index for all tokens (default 0)
# Mode B (file): per-token multi-pack/tier assignments
DEPOSIT_FILE=                     # Path to JSON deposit file (see scripts/deposit.example.json)
# FMV bounds (required before depositing)
FMV_BOUNDS_FILE=                  # (optional) Path to JSON FMV bounds file (see scripts/fmv-bounds.example.json)
# Buyback config
BUYBACK_ALLOCATION_BPS=           # (optional) Fraction of pack price routed to BuybackPool (e.g. 3000 = 30%); sets PackRegistry pack 0
PACK_REGISTRY=                    # (optional) PackRegistry proxy; falls back to deployments/<network>.json
SKIP_DEPOSIT=                     # (optional) Set to true to skip deposit entirely

# --- batch-set-appraisals.ts ---
APPRAISALS_FILE=                  # Path to JSON appraisal data (see scripts/appraisals.example.json); value in whole token units
# ASSET_LENDING_POOL_PROXY        # (optional) Override AssetLendingPool proxy
# SKIP_CONFIRM=true               # Skip interactive confirmation on live networks

# --- set-eligibility-controls.ts ---
MIN_APPRAISAL_VALUE=              # Minimum appraised value in whole token units (e.g. 100 = $100); 0 disables
MIN_GRADE=                        # Minimum grade integer; 0 disables grade filtering
ADD_CATEGORIES=                   # (optional) Comma-separated category IDs to whitelist (e.g. 1,2,3)
REMOVE_CATEGORIES=                # (optional) Comma-separated category IDs to remove from whitelist
# ASSET_LENDING_POOL_PROXY        # (optional) Override AssetLendingPool proxy
# SKIP_CONFIRM=true               # Skip interactive confirmation on live networks

# --- set-lender-config.ts ---
SHARE_BPS=                        # Lender revenue share in basis points (0–10000; e.g. 8000 = 80%)
ENABLED=                          # true/false — toggle lender deposits open/closed
# ASSET_LENDING_POOL_PROXY        # (optional) Override AssetLendingPool proxy

# --- deploy-asset-lending-pool.ts (required) ---
# PAYMENT_TOKEN reused from above
LTV_BPS=                          # Max loan-to-value in basis points (default 5000 = 50%)
LENDER_SHARE_BPS=                 # Lender share of interest in bps (default 8000 = 80%)

# --- deploy-fee-controller.ts (required) ---
TREASURY=                         # Platform fee recipient address

# --- set-collectible-fee.ts ---
COLLECTIBLE_FEES_BPS=             # Required. New collectible sale fee in basis points (0–1000; e.g. 300 = 3%)
FEE_CONTROLLER_PROXY=             # (optional) Override FeeController proxy; falls back to deployments/<network>.json
SKIP_ENABLE=                      # (optional) Set truthy to skip setCollectibleFeesEnabled(true) — only updates the bps

# --- deploy-marketplace.ts (required) ---
# PAYMENT_TOKEN and TREASURY reused from above
FEE_CONTROLLER_PROXY=             # (optional) Override FeeController proxy; falls back to deployments/<network>.json
LENDING_POOL_PROXY=               # (optional) Override AssetLendingPool proxy; falls back to deployments/<network>.json
ASSET_NFT_PROXY=                  # (optional) Override AssetNFT proxy; falls back to deployments/<network>.json
SKIP_NFT_WIRING=                  # Set to true to skip AssetNFT wiring (call setters manually)

# --- deploy-promo-code-registry.ts ---
PERMISSION_MANAGER_PROXY=         # (optional) Override PermissionManager proxy; falls back to deployments/<network>.json

# --- deploy-p2p-trade-escrow.ts ---
OWNER=                            # (optional) Owner address; defaults to deployer

# --- set-pack-machine-implementation.ts ---
NEW_PACK_MACHINE_IMPL=            # (optional) Reuse a pre-deployed impl; skip the deploy step
TRUSTED_FORWARDER=                # (optional) ERC-2771 forwarder baked into the impl; defaults to recorded value or 0x00…00
PACK_MACHINE_FACTORY_PROXY=       # (optional) Override PackMachineFactory proxy; falls back to deployments/<network>.json
PERMISSION_MANAGER_PROXY=         # (optional) Override PermissionManager proxy; falls back to factory.getPermissionManager()

# --- relink-buyback-pool.ts ---
PACK_MACHINE_FACTORY=             # (optional) Override PackMachineFactory proxy
PERMISSION_MANAGER=               # (optional) Override PermissionManager proxy
ASSET_NFT=                        # (optional) Override AssetNFT proxy
PAYMENT_TOKEN=                    # (reused from deploy-pack-machine.ts) ERC-20 payment token
FINANCE_WALLET=                   # (reused from deploy-pack-machine.ts) Finance wallet address
BUYBACK_POOL=                     # (optional) Skip deploy; use this existing BuybackPool address
CLONES=                           # (optional) Comma-separated clone addresses to relink; defaults to PackMachines[] in deployments JSON
DEPLOY_STEP_DELAY_MS=             # (optional) Ms between transactions (default 3000)

# --- check-buyback-registration.ts ---
PACK_MACHINE=                     # (optional) Comma-separated clone addresses; defaults to all from event logs
BUYBACK_POOL_PROXY=               # (optional) Override BuybackPool proxy

# --- check-lending-pool-config.ts ---
CONFIG_PROXY=                     # (optional) Use this AssetLendingPoolConfig proxy directly
ASSET_LENDING_POOL_PROXY=         # (optional) Resolve config via pool.getConfig(); falls back to deployments JSON
TOKEN_IDS=                        # (optional) Comma-separated token IDs to show per-token appraisal + eligibility

# --- check-pack-buyback.ts ---
PACK_MACHINE=                     # (optional) Clone address; defaults to PackMachines[0] in deployments JSON
PACK_ID=                          # (optional) Single pack index to inspect (default 0); ignored when PACK_IDS is set
PACK_IDS=                         # (optional) Comma-separated pack indices to inspect

# --- debug-token-eligibility.ts ---
TOKEN_ID=                         # Token ID(s) to trace; comma-separated or single value
CONFIG_PROXY=                     # (optional) Use this config proxy directly
ASSET_LENDING_POOL_PROXY=         # (optional) Resolve config via pool.getConfig()

# --- Tenderly contract verification (verify-tenderly.ts / pnpm verify:tenderly) ---
TENDERLY_ACCOUNT=                 # Account slug from the Tenderly dashboard URL (case-sensitive)
TENDERLY_PROJECT=                 # Project slug
TENDERLY_ACCESS_KEY=              # From Account Settings → Authorization → Generate Access Token
TENDERLY_VERIFIER_SUFFIX=         # (optional) Set to "/public" to make verifications public (irreversible)
```

## Commands

```bash
# Compile contracts (also runs contract-sizer)
pnpm compile

# Run all tests (Solidity + TypeScript)
pnpm test

# Run only Solidity tests
npx hardhat test solidity

# Run only TypeScript tests
npx hardhat test nodejs

# Lint Solidity files
pnpm lint

# Verify every hardcoded ERC-7201 storage slot matches the canonical keccak256(…) derivation
# (guards against copy-paste slot typos across upgrades)
pnpm verify:slots

# Verify all deployed implementations + ERC1967 proxies on Tenderly via forge verify-contract
# Requires TENDERLY_ACCOUNT, TENDERLY_PROJECT, TENDERLY_ACCESS_KEY in env
pnpm verify:tenderly --network <network>

# Start a fork
pnpm fork:mainnet
pnpm fork:base
pnpm fork:sepolia
```

## Deployment

### Contract dependency overview

```text
PermissionManager          (deploy FIRST — no protocol deps)
  ├── AssetNFT             depends on PermissionManager
  ├── PackVRFRouter        depends on PermissionManager + Chainlink VRF coordinator
  ├── PackRegistry         depends on PermissionManager
  │     └── (bidirectionally wired with PackMachineFactory after both are deployed)
  ├── PackTierRegistry     depends on PermissionManager
  │     └── (bidirectionally wired with PackMachineFactory after both are deployed)
  ├── PackMachineFactory   depends on PermissionManager + AssetNFT + PackRegistry + PackTierRegistry
  │     └── PackMachine clones  EIP-1167, created by the factory; pack config in PackRegistry, tier data in PackTierRegistry
  ├── BuybackPool          depends on PermissionManager + AssetNFT + PackMachineFactory
  ├── AssetLendingPool     depends on AssetNFT + PackMachineFactory
  │                        ⚠ must be granted STATE_MANAGER_ROLE on PermissionManager post-deploy
  ├── FeeController        depends on PermissionManager
  └── NettyWorthMarketplace  depends on PermissionManager + FeeController + AssetLendingPool + AssetNFT
                             ⚠ marketplace contract address must be granted MARKETPLACE_ROLE for force-close

P2PTradeEscrow             (standalone — no protocol deps; deploy independently at any time)
```

> **Note:** `deploy-pack-machine.ts` is a composite script — it deploys `PackVRFRouter`, the `PackMachine` logic contract, `PackMachineFactory`, **`PackRegistry`**, and `BuybackPool` in a single run (7 steps), then wires the factory (`setImplementation` / `setPackVRFRouter` / `setBuybackPool` / `setPackRegistry`) and the registry (`packRegistry.setFactory(factory)`) automatically.

### Deployment order

| # | Step | Script | Contracts deployed | Depends on |
| - | ---- | ------ | ------------------ | ---------- |
| 1 | Permission registry | `deploy-permission-manager.ts` | PermissionManager (UUPS) | — |
| 2 | Asset NFT | `deploy-asset-nft.ts` | AssetNFT (UUPS) | PermissionManager |
| 3 | Pack system | `deploy-pack-machine.ts` | PackVRFRouter, PackMachine impl, PackMachineFactory, PackRegistry, PackTierRegistry, BuybackPool (all UUPS) | PermissionManager, AssetNFT |
| 4 | Create a pack | `create-pack-machine.ts` | PackMachine clone (EIP-1167); bootstraps pack 0 in PackRegistry | PackMachineFactory, PackVRFRouter, BuybackPool, PackRegistry |
| 5 | Configure pack | `setup-pack-machine.ts` | — (deposits NFTs; sets buyback rate on PackRegistry pack 0) | PackMachine clone, BuybackPool, AssetNFT, PackRegistry |
| 5a | Promo codes *(optional)* | `deploy-promo-code-registry.ts` | PromoCodeRegistry (UUPS) | PackMachineFactory, BuybackPool; wire via `factory.setPromoCodeRegistry` + `buybackPool.setPromoCodeRegistry` |
| 6 | Lending pool | `deploy-asset-lending-pool.ts` | AssetLendingPool (UUPS) | AssetNFT, PackMachineFactory |
| 7 | Fee controller | `deploy-fee-controller.ts` | FeeController (UUPS) | PermissionManager |
| 8 | Marketplace | `deploy-marketplace.ts` | NettyWorthMarketplace (UUPS) | PermissionManager, FeeController, AssetLendingPool, AssetNFT |
| 9 | P2P escrow | `deploy-p2p-trade-escrow.ts` | P2PTradeEscrow (UUPS) | — |

---

### Step 1 — Deploy PermissionManager

**Prerequisites:** none.

```bash
npx hardhat run scripts/deploy-permission-manager.ts --network <network>
```

Deploys the `PermissionManager` implementation and ERC1967 proxy. The deployer is granted `DEFAULT_ADMIN_ROLE` (and all other protocol roles) in `initialize`. Saves `PermissionManager.proxy` and `.implementation` to `deployments/<network>.json`.

---

### Step 2 — Deploy AssetNFT

**Prerequisites:** PermissionManager deployed.

```bash
npx hardhat run scripts/deploy-asset-nft.ts --network <network>
```

Deploys `AssetNFT` implementation (constructor bakes in the trusted forwarder) and ERC1967 proxy. Resolves `PERMISSION_MANAGER_PROXY` from env or `deployments/<network>.json`. Saves `AssetNFT.proxy` and `.implementation`.

---

### Step 3 — Deploy the pack system

**Prerequisites:** PermissionManager + AssetNFT deployed. The following env vars are **required**:

| Variable | Description |
|----------|-------------|
| `PAYMENT_TOKEN` | ERC-20 payment token address (e.g. USDC) |
| `FINANCE_WALLET` | Wallet that receives pack-sale proceeds |
| `VRF_COORDINATOR` | Chainlink VRFCoordinatorV2Plus address for the target chain |
| `VRF_SUBSCRIPTION_ID` | Funded Chainlink subscription ID |
| `VRF_KEY_HASH` | Chainlink key hash (gas lane) for the target chain |

```bash
npx hardhat run scripts/deploy-pack-machine.ts --network <network>
```

Deploys — in order — `PackVRFRouter` (UUPS), the `PackMachine` logic contract (clone target, no proxy), `PackMachineFactory` (UUPS), **`PackRegistry`** (UUPS), **`PackTierRegistry`** (UUPS), and `BuybackPool` (UUPS). After all six are live, the script wires them automatically by calling:

- `factory.setImplementation(packMachineImpl)`
- `factory.setPackVRFRouter(vrfRouterProxy)`
- `factory.setBuybackPool(buybackProxy)` *(also wires BuybackPool side)*
- `factory.setPackRegistry(registryProxy)` — factory reads pack config from registry on every clone creation
- `packRegistry.setFactory(factoryProxy)` — registry trusts only the factory to call `registerMachine`
- `factory.setPackTierRegistry(tierRegistryProxy)` — factory provides the tier registry address to clones
- `packTierRegistry.setFactory(factoryProxy)` — registry authorizes only registered pack machines to write tier data

The verify step asserts all seven wiring relationships are correct.

Saves `PackVRFRouter`, `PackMachineImplementation`, `PackMachineFactory`, `PackRegistry`, `PackTierRegistry`, and `BuybackPool` to `deployments/<network>.json`.

> ⚠ **Manual step after this script:** Add the `PackVRFRouter` proxy address as a consumer on your Chainlink VRF subscription (via the Chainlink dashboard or coordinator contract). No pack can be opened until this is done.

---

### Step 4 — Create a PackMachine clone

**Prerequisites:** Step 3 complete; caller holds `PACK_OPERATOR_ROLE`. Required env vars:

| Variable | Description |
|----------|-------------|
| `PRICE_PER_PACK` | Pack price in payment-token base units (e.g. `10000000` = 10 USDC) |
| `CARDS_PER_PACK` | Cards dispensed per pack (1–255) |
| `START_TIME` | *(optional)* Unix timestamp when packs open; defaults to now |

```bash
npx hardhat run scripts/create-pack-machine.ts --network <network>
```

Calls `factory.createPackMachine(...)` to deploy an EIP-1167 clone. The factory internally calls `packRegistry.registerMachine(clone, pricePerPack, cardsPerPack, startTime)` to bootstrap pack 0 in the registry. The script then automatically:

- `vrfRouter.setAuthorizedPackMachine(clone, true)` — allows the clone to request VRF randomness
- `buybackPool.registerPackMachine(clone, true)` — allows the clone to register tokens in the buyback pool

Appends the clone address and config to the `PackMachines[]` array in `deployments/<network>.json`.

---

### Step 5 — Configure a PackMachine (deposit cards)

**Prerequisites:** Step 4 complete; AssetNFTs minted and owned by the operator.

The script supports two deposit modes and an optional FMV-bounds step:

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `PACK_MACHINE` | No | Clone address override; falls back to last entry in `deployments/<network>.json` |
| `BUYBACK_ALLOCATION_BPS` | No | Fraction of pack price routed to BuybackPool (e.g. `3000` = 30%); omit to skip buyback config |
| `PACK_REGISTRY` | No | PackRegistry proxy override; falls back to `deployments/<network>.json` |
| `FMV_BOUNDS_FILE` | No | Path to JSON file (see `scripts/fmv-bounds.example.json`); sets per-`(packId, tier)` FMV bounds **required before depositing** |
| `TOKEN_IDS` | Mode A | Comma-separated IDs or range (e.g. `1-50` or `1,2,3`); used when `DEPOSIT_FILE` is not set |
| `TIERS` | Mode A | Comma-separated tier values (0=Base … 5=Grail) matching `TOKEN_IDS`; single value applies to all |
| `PACK_ID` | Mode A | Pack index to deposit all tokens into (default `0`) |
| `DEPOSIT_FILE` | Mode B | Path to JSON file (see `scripts/deposit.example.json`); supports per-token multi-pack/tier assignments |
| `SKIP_DEPOSIT` | No | Set to `true` to skip deposit (FMV bounds + buyback only) |
| `TOKENS_OWNER` | No | Address holding the NFTs; defaults to deployer |
| `ASSET_NFT_PROXY` | No | AssetNFT proxy override; falls back to `deployments/<network>.json` |

```bash
npx hardhat run scripts/setup-pack-machine.ts --network <network>
```

Configures the most recently created clone:

1. *(if `BUYBACK_ALLOCATION_BPS` set)* `clone.setBuybackPool(buybackProxy)` + `packRegistry.setPackBuybackAllocation(clone, 0, bps)`
2. *(if `FMV_BOUNDS_FILE` set)* `packRegistry.setPackTierFmvBounds(clone, packId, minFmv, maxFmv)` for each entry — **must be done before first deposit**
3. `assetNFT.setApprovalForAll(clone, true)`
4. Batched `clone.deposit(tokenIds, packCounts, packIds, tiers, tokensOwner)` — up to 50 tokens per batch

**Mode A** (env vars): each token deposited into `PACK_ID` at its tier — simple, single-pack.
**Mode B** (`DEPOSIT_FILE`): each token can be assigned to multiple packs with a different tier per pack (see `scripts/deposit.example.json`).

Updates the matching `PackMachines[]` entry in `deployments/<network>.json` with deposited token IDs, pack assignments, and config.

> To enable the BuybackPool to re-deposit NFTs back into this machine after a buyback, also call `clone.setAuthorizedDepositor(buybackPoolProxy, true)` (requires `PACK_OPERATOR_ROLE`).

---

### Step 5a — Deploy PromoCodeRegistry *(optional)*

**Prerequisites:** PermissionManager deployed. PackMachineFactory and BuybackPool should already be deployed so the post-deploy wiring steps can be completed immediately. This step is only required if you intend to use discount or buyback-rate promo codes.

| Variable | Description |
| -------- | ----------- |
| `PERMISSION_MANAGER_PROXY` | *(optional)* Override PermissionManager proxy; falls back to `deployments/<network>.json`. Must be set explicitly on non-HTTP (local/simulated) networks. |

```bash
npx hardhat run scripts/deploy-promo-code-registry.ts --network <network>
```

Deploys the `PromoCodeRegistry` implementation and ERC1967 proxy in four steps: deploy impl → encode `initialize(permissionManager)` calldata → deploy proxy → verify on-chain state (`paused == false`, `factory == address(0)`, `buybackPool == address(0)`). Saves `PromoCodeRegistry.proxy`, `.implementation`, and `.permissionManager` to `deployments/<network>.json` (HTTP networks only).

> ⚠ **Manual steps after this script** (run as `DEFAULT_ADMIN_ROLE` / `PACK_OPERATOR_ROLE`):
>
> 1. `registry.setPackMachineFactory(<factoryProxy>)` — `DEFAULT_ADMIN_ROLE`
> 2. `registry.setBuybackPool(<buybackPoolProxy>)` — `DEFAULT_ADMIN_ROLE`
> 3. `factory.setPromoCodeRegistry(<registryProxy>)` — `DEFAULT_ADMIN_ROLE`
> 4. `buybackPool.setPromoCodeRegistry(<registryProxy>)` — `PACK_OPERATOR_ROLE`
> 5. Deploy a new PackMachine implementation and call `factory.setImplementation(newImpl)` so future clones support code-aware `openPack` calls.
> 6. Upgrade the BuybackPool and PackMachineFactory implementations in place (UUPS) if they are not already on the promo-aware version.

---

### Step 6 — Deploy AssetLendingPool

**Prerequisites:** AssetNFT + PackMachineFactory deployed; caller holds `DEFAULT_ADMIN_ROLE` on PermissionManager (for the automatic `STATE_MANAGER_ROLE` grant). Required env vars:

| Variable | Description |
|----------|-------------|
| `PAYMENT_TOKEN` | Same ERC-20 token used for loans (e.g. USDC) |
| `LTV_BPS` | Max loan-to-value in basis points (default `5000` = 50%) |
| `LENDER_SHARE_BPS` | Lender share of interest in bps (default `8000` = 80%) |

```bash
npx hardhat run scripts/deploy-asset-lending-pool.ts --network <network>
```

Deploys `AssetLendingPool` implementation and ERC1967 proxy, then **automatically** grants the pool address `STATE_MANAGER_ROLE` on `PermissionManager` so it can call `assetNFT.batchSetAssetState()` to flip collateral tokens between `Held` and `Loaned`.

> To enable the default-asset recycling path (where defaulted collateral is re-deposited into a PackMachine), call `targetClone.setAuthorizedDepositor(lendingPoolProxy, true)` on each target machine, and configure `pool.setDefaultPackMachine(cloneAddress)` or `pool.setPackMachineFactory(...)` via the pool owner.

---

### Step 7 — Deploy FeeController

**Prerequisites:** PermissionManager deployed. Required env vars:

| Variable | Description |
|----------|-------------|
| `TREASURY` | Platform fee recipient address |
| `PERMISSION_MANAGER_PROXY` | *(optional)* Override PermissionManager proxy; falls back to `deployments/<network>.json` |

```bash
npx hardhat run scripts/deploy-fee-controller.ts --network <network>
```

Deploys `FeeController` implementation and ERC1967 proxy, initialising both fees at 5% (500 bps) with both fee types enabled. Saves `FeeController.proxy` and `.implementation` to `deployments/<network>.json`.

---

### Step 8 — Deploy NettyWorthMarketplace

**Prerequisites:** PermissionManager, FeeController, AssetLendingPool, and AssetNFT deployed. Required env vars:

| Variable | Description |
|----------|-------------|
| `PAYMENT_TOKEN` | ERC-20 payment token address (e.g. USDC) |
| `TREASURY` | Platform treasury that receives collectible fees |
| `FEE_CONTROLLER_PROXY` | *(optional)* Override FeeController proxy; falls back to `deployments/<network>.json` |
| `LENDING_POOL_PROXY` | *(optional)* Override AssetLendingPool proxy; falls back to `deployments/<network>.json` |
| `ASSET_NFT_PROXY` | *(optional)* Override AssetNFT proxy; falls back to `deployments/<network>.json` |
| `PERMISSION_MANAGER_PROXY` | *(optional)* Override PermissionManager proxy; falls back to `deployments/<network>.json` |
| `SKIP_NFT_WIRING` | Set to `true` to skip auto-wiring AssetNFT (call setters manually) |

```bash
npx hardhat run scripts/deploy-marketplace.ts --network <network>
```

Deploys `NettyWorthMarketplace` implementation and ERC1967 proxy, then automatically:

- `pool.setMarketplace(marketplaceProxy)` — authorizes the marketplace to call `settleLoanRepaymentOnSale`
- `assetNFT.setPaymentToken / setTreasury / setFeeController / setLendingPool` — wires AssetNFT to the fee and lending subsystems (skipped if `SKIP_NFT_WIRING=true`)

Saves `NettyWorthMarketplace.proxy` and `.implementation` to `deployments/<network>.json`.

> ⚠ **Manual step after this script:** Grant `MARKETPLACE_ROLE` to the marketplace proxy address on `PermissionManager` to enable auction force-close and loan repayment authorization. The keeper bot (or admin) that calls `settleAuction` for forced closes also needs this role.

---

### Step 9 — Deploy P2PTradeEscrow

**Prerequisites:** none — fully standalone, no protocol deps.

```bash
npx hardhat run scripts/deploy-p2p-trade-escrow.ts --network <network>
```

Deploys the `P2PTradeEscrow` implementation and ERC1967 proxy. `initialize(owner)` is called with the `OWNER` env var, or the deployer address if unset — set `OWNER` to a multi-sig for production. Saves `P2PTradeEscrow.proxy`, `.implementation`, and `.owner` to `deployments/<network>.json`.

---

### Maintenance scripts

| Script | Purpose | Required role |
|--------|---------|---------------|
| `upgrade-asset-nft.ts` | Deploy new AssetNFT impl and call `upgradeToAndCall` on the proxy | `UPGRADER_ROLE` |
| `upgrade-pack-vrf-router.ts` | Deploy new PackVRFRouter impl and upgrade proxy | `UPGRADER_ROLE` |
| `set-callback-gas-limit.ts` | Update the Chainlink VRF callback gas limit on PackVRFRouter | `DEFAULT_ADMIN_ROLE` |
| `set-key-hash.ts` | Update the Chainlink VRF key hash (gas lane) on PackVRFRouter; env: `VRF_KEY_HASH` (required, 0x-prefixed 32-byte hex), `PACK_VRF_ROUTER_PROXY` (opt) | `DEFAULT_ADMIN_ROLE` |
| `grant-role.ts` | Grant any protocol role to any wallet via PermissionManager | `DEFAULT_ADMIN_ROLE` |
| `burn-asset-nft.ts` | Permanently burn AssetNFT tokens by token ID | `BURNER_ROLE` |
| `seed-asset-nft.ts` | Dev/test helper — mint sample AssetNFT cards and set appraisals | `MINTER_ROLE` |
| `batch-set-appraisals.ts` | Bulk-write NFT appraisal data (value, grade, category) to `AssetLendingPool` for collateral valuation; batches of ≤ 50; value in whole token units | Pool owner |
| `set-eligibility-controls.ts` | Set minimum appraisal value, minimum grade, and allowed-category add/remove lists on `AssetLendingPool` | Pool owner |
| `set-finance-wallet.ts` | Set the finance wallet address on `AssetLendingPoolConfig`; env: `FINANCE_WALLET` (required), `CONFIG_PROXY` (opt), `ASSET_LENDING_POOL_PROXY` (opt) | Config owner |
| `set-lender-config.ts` | Set lender revenue-share bps and toggle lender deposits open/closed on `AssetLendingPool` | Pool owner |
| `set-term-config.ts` | Create or update a loan term slot (duration, APR, active flag) on `AssetLendingPoolConfig`; env: `TERM_ID` (default 3), `DURATION_SECONDS`, `APR_BPS`, `ACTIVE`, `CONFIG_PROXY` (opt), `ASSET_LENDING_POOL_PROXY` (opt) | Config owner |
| `set-collectible-fee.ts` | Set `collectibleFeesBps` on `FeeController` and optionally enable it; env: `COLLECTIBLE_FEES_BPS` (required, 0–1000), `FEE_CONTROLLER_PROXY` (opt), `SKIP_ENABLE` (opt) | `DEFAULT_ADMIN_ROLE` |
| `set-marketplace-allowlist.ts` | Toggle allowed collections / payment tokens on `NettyWorthMarketplace` via `setAllowedCollection` / `setAllowedPaymentToken`; env: `COLLECTIONS` and/or `PAYMENT_TOKENS` (≥1 required), `ALLOWED` (default `true`), `MARKETPLACE_PROXY` (opt), `SKIP_CONFIRM` (opt) | `DEFAULT_ADMIN_ROLE` |
| `set-marketplace-lending-pool.ts` | Point the marketplace at the lending pool via `setLendingPool`; env: `MARKETPLACE_PROXY` (opt), `LENDING_POOL` (opt), `SKIP_CONFIRM` (opt) | `DEFAULT_ADMIN_ROLE` |
| `set-pack-machine-implementation.ts` | Deploy new `PackMachine` logic + call `factory.setImplementation`; only new clones use the new logic — existing clones are unaffected | `DEFAULT_ADMIN_ROLE` |
| `relink-buyback-pool.ts` | Deploy a fresh `BuybackPool` (new impl + proxy) and relink every existing PackMachine clone to it; use when ERC-7201 storage slot changed and in-place upgrade would corrupt state | `DEFAULT_ADMIN_ROLE` + `PACK_OPERATOR_ROLE` |
| `check-buyback-registration.ts` | *(read-only)* Report BuybackPool registration status and buyback rates for one or more PackMachine clones | — |
| `check-lending-pool-config.ts` | *(read-only)* Print full `AssetLendingPool` / `AssetLendingPoolConfig` configuration; optionally inspect per-token appraisal + eligibility | — |
| `check-pack-buyback.ts` | *(read-only)* Print `buybackPool` address and `buybackAllocationBps` for one or more pack IDs on a PackMachine clone | — |
| `debug-token-eligibility.ts` | *(read-only)* Trace every `_isEligible()` condition for given AssetNFT token IDs and show exactly why each passes or fails | — |

```bash
# Example: update callback gas limit
CALLBACK_GAS_LIMIT=250000 npx hardhat run scripts/set-callback-gas-limit.ts --network <network>

# Example: update VRF key hash (gas lane)
VRF_KEY_HASH=0x00b81b5a... npx hardhat run scripts/set-key-hash.ts --network <network>

# Example: upgrade AssetNFT
npx hardhat run scripts/upgrade-asset-nft.ts --network <network>

# Example: toggle an allowed collection on the marketplace
COLLECTIONS=0x<collection> ALLOWED=true \
  npx hardhat run scripts/set-marketplace-allowlist.ts --network sepolia

# Example: update the marketplace's lending pool reference
npx hardhat run scripts/set-marketplace-lending-pool.ts --network sepolia

# Example: deploy new PackMachine logic and update factory clone target
npx hardhat run scripts/set-pack-machine-implementation.ts --network base

# Example: deploy fresh BuybackPool and relink all PackMachine clones
npx hardhat run scripts/relink-buyback-pool.ts --network base

# Example: check buyback registration for all clones
npx hardhat run scripts/check-buyback-registration.ts --network base

# Example: inspect lending pool config and token eligibility
TOKEN_IDS=1,2,3 npx hardhat run scripts/check-lending-pool-config.ts --network base

# Example: trace eligibility for specific tokens
TOKEN_ID=42 npx hardhat run scripts/debug-token-eligibility.ts --network base
```

---

### `grant-role.ts` — Grant a protocol role

Grants any role defined in `contracts/lib/Roles.sol` to a wallet address via `PermissionManager.grantRole`. The caller must hold `DEFAULT_ADMIN_ROLE`. Idempotent — exits cleanly if the account already holds the role.

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `ROLE` | Yes | Role name: `MINTER_ROLE`, `BURNER_ROLE`, `STATE_MANAGER_ROLE`, `URI_SETTER_ROLE`, `PAUSER_ROLE`, `UPGRADER_ROLE`, `BLACKLIST_ROLE`, `PACK_OPERATOR_ROLE`, `BUYBACK_POOL_ROLE`, `MARKETPLACE_ROLE`, `DEFAULT_ADMIN_ROLE` |
| `ACCOUNT` | Yes | Wallet address to grant the role to |
| `PERMISSION_MANAGER_PROXY` | No | Override PermissionManager proxy; falls back to `deployments/<network>.json` |

```bash
# Grant MINTER_ROLE to a backend signer
ROLE=MINTER_ROLE ACCOUNT=0x<wallet> \
  npx hardhat run scripts/grant-role.ts --network sepolia

# Grant MARKETPLACE_ROLE to the marketplace contract
ROLE=MARKETPLACE_ROLE ACCOUNT=0x<marketplace-proxy> \
  npx hardhat run scripts/grant-role.ts --network sepolia

# Grant PACK_OPERATOR_ROLE with an explicit PermissionManager override
ROLE=PACK_OPERATOR_ROLE ACCOUNT=0x<wallet> PERMISSION_MANAGER_PROXY=0x<proxy> \
  npx hardhat run scripts/grant-role.ts --network sepolia
```

On live networks (`sepolia`, `mainnet`, `base`) the script prints a confirmation summary and requires `yes` before sending. It appends an audit entry `{ role, roleHash, account, grantedBy, txHash, grantedAt }` to the `RoleGrants` array in `deployments/<network>.json`.

---

### `burn-asset-nft.ts` — Burn AssetNFT tokens

Permanently destroys AssetNFT tokens by calling `batchBurn` in batches of ≤ 50. Only tokens in `Held` or `RemovedFromPlatform` state can be burned (contract enforces this). The caller must hold `BURNER_ROLE`.

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `TOKEN_IDS` | Yes | Token IDs to burn. Accepts ranges (`1-50`), comma lists (`1,2,5`), or combinations (`1-10,15,20-25`) |
| `ASSET_NFT_PROXY` | No | Override AssetNFT proxy; falls back to `deployments/<network>.json` |
| `PERMISSION_MANAGER_PROXY` | No | Override PermissionManager proxy; falls back to `deployments/<network>.json` |

```bash
# Burn a range of tokens
TOKEN_IDS=1-10 npx hardhat run scripts/burn-asset-nft.ts --network sepolia

# Burn specific token IDs
TOKEN_IDS=5,12,37 npx hardhat run scripts/burn-asset-nft.ts --network sepolia

# Burn with explicit proxy addresses
TOKEN_IDS=1-50 ASSET_NFT_PROXY=0x<proxy> PERMISSION_MANAGER_PROXY=0x<proxy> \
  npx hardhat run scripts/burn-asset-nft.ts --network sepolia
```

On live networks the script prints a confirmation summary (with an irreversibility warning) and requires `yes` before sending. It appends a `BurnHistory` entry `{ burnedBy, tokenIds, txHashes, burnedAt }` to `deployments/<network>.json`.

> **Note:** If a token is in `Loaned` or `InPack` state the contract reverts with `AssetNFT__TokenNotBurnable`. Ensure collateral is released and pack deposits are withdrawn before burning.

---

### `batch-set-appraisals.ts` — Bulk-write NFT appraisals

Writes appraisal data (appraised value, grade, category) for AssetNFT tokens to `AssetLendingPool` in batches of ≤ 50. The pool uses this data to compute maximum loan amounts and enforce eligibility. The caller must be the pool **owner** (`Ownable2StepUpgradeable`).

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `APPRAISALS_FILE` | Yes | Path to JSON appraisal data (see `scripts/appraisals.example.json`). `value` is in **whole token units** (e.g. `1000` = $1,000 USDC); the script scales by `10^decimals` |
| `ASSET_LENDING_POOL_PROXY` | No | Override AssetLendingPool proxy; falls back to `deployments/<network>.json` |
| `SKIP_CONFIRM` | No | Set to `true`/`1` to skip the interactive confirmation prompt on live networks |

Input file format (`appraisals.example.json`):

```json
[
  { "tokenId": 1, "value": 1000, "grade": 8, "category": 2 },
  { "tokenId": 2, "value": 500,  "grade": 6, "category": 1 }
]
```

Fields: `tokenId` (uint256), `value` (whole token units), `grade` (integer; 0 = ungraded), `category` (integer; 0 = uncategorized).

```bash
APPRAISALS_FILE=scripts/appraisals.example.json \
  npx hardhat run scripts/batch-set-appraisals.ts --network sepolia
```

The script verifies each appraisal was stored correctly after sending. On success it reports the number of tokens updated; on any mismatch it exits with code 1.

---

### `set-eligibility-controls.ts` — Set loan eligibility gates

Configures which AssetNFT tokens are eligible as loan collateral on `AssetLendingPool`. The caller must be the pool **owner**.

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `MIN_APPRAISAL_VALUE` | Yes | Minimum appraised value in **whole token units** (e.g. `100` = $100); `0` disables the check |
| `MIN_GRADE` | Yes | Minimum grade integer; `0` disables grade filtering |
| `ADD_CATEGORIES` | No | Comma-separated category IDs to add to the whitelist (e.g. `1,2,3`) |
| `REMOVE_CATEGORIES` | No | Comma-separated category IDs to remove from the whitelist |
| `ASSET_LENDING_POOL_PROXY` | No | Override AssetLendingPool proxy; falls back to `deployments/<network>.json` |
| `SKIP_CONFIRM` | No | Set to `true`/`1` to skip the interactive confirmation on live networks |

```bash
MIN_APPRAISAL_VALUE=100 MIN_GRADE=1 ADD_CATEGORIES=1,2 \
  npx hardhat run scripts/set-eligibility-controls.ts --network sepolia
```

On live networks the script verifies the changes via `getPoolInfo()` and persists `minAppraisalValue`, `minGrade`, and `eligibilityUpdatedAt` to `deployments/<network>.json`.

---

### `set-lender-config.ts` — Configure lender economics

Sets the lender revenue-share percentage and whether external lender deposits are open on `AssetLendingPool`. The caller must be the pool **owner**.

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `SHARE_BPS` | Yes | Lender revenue share in basis points (0–10000; e.g. `8000` = 80%) |
| `ENABLED` | Yes | `true`/`false` or `1`/`0` — toggle lender deposits open or closed |
| `ASSET_LENDING_POOL_PROXY` | No | Override AssetLendingPool proxy; falls back to `deployments/<network>.json` |

```bash
SHARE_BPS=8000 ENABLED=true \
  npx hardhat run scripts/set-lender-config.ts --network sepolia
```

On live networks the script verifies the changes and persists `lenderShareBps`, `lenderDepositsEnabled`, and `lenderConfigUpdatedAt` to `deployments/<network>.json`.

---

### `set-finance-wallet.ts` — Set the finance wallet

Sets the finance wallet address on `AssetLendingPoolConfig`. The finance wallet is used in the Phase-1 defaulted-asset acquisition path; the lending pool reverts `AssetLendingPool__FinanceWalletNotSet` if it is `address(0)`. The caller must be the config contract **owner**.

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `FINANCE_WALLET` | Yes | New finance wallet address (non-zero) |
| `ASSET_LENDING_POOL_PROXY` | No | Override AssetLendingPool proxy; falls back to `deployments/<network>.json` |
| `CONFIG_PROXY` | No | Override `AssetLendingPoolConfig` proxy directly (takes precedence over pool proxy resolution) |

```bash
FINANCE_WALLET=0x<addr> npx hardhat run scripts/set-finance-wallet.ts --network base
```

On live networks the script prints the old → new wallet, prompts for confirmation, verifies the on-chain state after the transaction, and persists `financeWallet` and `financeWalletUpdatedAt` to `deployments/<network>.json`.

---

### `set-collectible-fee.ts` — Update collectible sale fee

Sets the collectible sale fee rate on `FeeController` and ensures the fee type is enabled. Caller must hold `DEFAULT_ADMIN_ROLE` on `PermissionManager`.

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `COLLECTIBLE_FEES_BPS` | Yes | New fee rate in basis points (0–1000; e.g. `300` = 3%). Validated client-side — script exits before sending if the value exceeds the on-chain maximum of `1000` (10%). |
| `FEE_CONTROLLER_PROXY` | No | Override FeeController proxy; falls back to `deployments/<network>.json` |
| `SKIP_ENABLE` | No | Set to any truthy value to skip the `setCollectibleFeesEnabled(true)` call — only the bps value is updated |

```bash
# Set fee to 3% and ensure enabled:
COLLECTIBLE_FEES_BPS=300 npx hardhat run scripts/set-collectible-fee.ts --network base

# Dry-run on a fork (no prompt, no JSON write):
COLLECTIBLE_FEES_BPS=250 npx hardhat run scripts/set-collectible-fee.ts --network forkBase

# Update rate only, don't touch the enabled flag:
COLLECTIBLE_FEES_BPS=300 SKIP_ENABLE=1 npx hardhat run scripts/set-collectible-fee.ts --network base
```

On live networks the script prints a confirmation summary (current vs new rate, enable action) and requires `yes` before sending. After the transaction(s) it re-reads both `collectibleFeesBps` and `collectibleFeesEnabled` and exits with code 1 on any mismatch. Persists `collectibleFeesBps`, `collectibleFeesEnabled`, and `collectibleFeesUpdatedAt` to `deployments/<network>.json`.

---

### `set-term-config.ts` — Configure a loan term slot

Creates or updates a loan term slot (duration, APR, active flag) on `AssetLendingPoolConfig`. The three production terms are slots 0 (7 days), 1 (15 days), and 2 (30 days); slot 3 is conventionally used for short-duration test terms. The caller must be the config contract **owner**.

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `TERM_ID` | No | Term slot index (uint8, default: `3`) |
| `DURATION_SECONDS` | No | Term duration in seconds (default: `300` = 5 min) |
| `APR_BPS` | No | Annual interest rate in basis points (default: `1000` = 10%) |
| `ACTIVE` | No | `true`/`false` or `1`/`0` (default: `true`) |
| `ASSET_LENDING_POOL_PROXY` | No | Override AssetLendingPool proxy; falls back to `deployments/<network>.json` |
| `CONFIG_PROXY` | No | Override `AssetLendingPoolConfig` proxy directly (takes precedence) |

```bash
# Add a 5-minute test term at slot 3 with 10% APR:
npx hardhat run scripts/set-term-config.ts --network base

# Fully parameterised:
TERM_ID=3 DURATION_SECONDS=300 APR_BPS=1000 ACTIVE=true \
  npx hardhat run scripts/set-term-config.ts --network base

# Deactivate the test term after testing:
TERM_ID=3 DURATION_SECONDS=300 APR_BPS=1000 ACTIVE=false \
  npx hardhat run scripts/set-term-config.ts --network base
```

On live networks the script shows current vs new values, prompts for confirmation, verifies the on-chain state after the transaction, and persists the term record and `termCount` to `deployments/<network>.json`.

---

### `set-pack-machine-implementation.ts` — Update PackMachine clone target

Deploys a new `PackMachine` logic contract and updates `PackMachineFactory.setImplementation` so that future `createPackMachine()` clones use the new logic.

> **Important:** EIP-1167 clones are immutable. Existing PackMachine instances are **not** upgraded — only clones created after this script runs will use the new implementation.

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `NEW_PACK_MACHINE_IMPL` | No | Reuse a pre-deployed implementation address; skip the deploy step |
| `TRUSTED_FORWARDER` | No | ERC-2771 forwarder baked into the impl at construction; defaults to the value recorded in `deployments/<network>.json` or `0x00…00` |
| `PACK_MACHINE_FACTORY_PROXY` | No | Override PackMachineFactory proxy; falls back to `deployments/<network>.json` |
| `PERMISSION_MANAGER_PROXY` | No | Override PermissionManager proxy; falls back to `factory.getPermissionManager()` |
| `DEPLOY_STEP_DELAY_MS` | No | Ms to wait between transactions (default `3000`) |

```bash
# Deploy new impl + update factory (live — interactive confirmation required):
npx hardhat run scripts/set-pack-machine-implementation.ts --network base

# Dry-run on a fork (no prompt, no JSON write):
npx hardhat run scripts/set-pack-machine-implementation.ts --network forkBase

# Reuse a pre-deployed implementation (skip deploy step):
NEW_PACK_MACHINE_IMPL=0x<impl> \
  npx hardhat run scripts/set-pack-machine-implementation.ts --network base
```

The script verifies the change via the `ImplementationUpdated` event in the receipt, then updates `deployments/<network>.json`: the `PackMachineImplementation` top-level entry and the `packMachineImplementation` field in `PackMachineFactory`. An `implementationHistory` array records `previousImplementation`, `newImplementation`, `changedAt`, and `txHash` for auditability.

---

### `relink-buyback-pool.ts` — Deploy fresh BuybackPool and relink clones

Deploys a brand-new `BuybackPool` (implementation + ERC1967 proxy) and rewires every existing PackMachine clone to use it. Use this instead of the normal UUPS upgrade when the ERC-7201 storage layout has changed in a way that would corrupt state on an in-place upgrade.

What it does (idempotent / resume-safe across 4 steps):

1. Deploy new `BuybackPool` impl + proxy, initialized with `permissionManager`, `assetNFT`, `paymentToken`, `financeWallet`, `factory`.
2. `factory.setBuybackPool(newPool)` — repoints the factory's pool reference.
3. For each clone: `newPool.registerPackMachine(clone, true)` + `clone.setBuybackPool(newPool)`.
4. Verify: asserts `pool.getDefaultBuybackBps()`, `pool.getPermissionManager()`, `factory.buybackPool()`, and each clone's `getMachineInfo().buybackPool` match expectations.

**Environment variables:**

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `PACK_MACHINE_FACTORY` | No | Override PackMachineFactory proxy; falls back to `deployments/<network>.json` |
| `PERMISSION_MANAGER` | No | Override PermissionManager proxy |
| `ASSET_NFT` | No | Override AssetNFT proxy |
| `PAYMENT_TOKEN` | No | Override payment token address; falls back to existing `BuybackPool` deployment record |
| `FINANCE_WALLET` | No | Override finance wallet address; falls back to existing deployment record |
| `BUYBACK_POOL` | No | Skip deploy; use this pre-deployed pool address instead |
| `CLONES` | No | Comma-separated clone addresses to relink; defaults to `PackMachines[]` in `deployments/<network>.json` |
| `DEPLOY_STEP_DELAY_MS` | No | Ms to wait between transactions (default `3000`) |

```bash
# Dry-run on a fork:
npx hardhat run scripts/relink-buyback-pool.ts --network forkBase

# Live (interactive confirmation):
npx hardhat run scripts/relink-buyback-pool.ts --network base

# Relink a specific subset of clones:
CLONES=0x<clone1>,0x<clone2> \
  npx hardhat run scripts/relink-buyback-pool.ts --network base
```

Saves the new `BuybackPool` entry to `deployments/<network>.json` after step 1 as a checkpoint — re-running with `BUYBACK_POOL=<new-address>` skips the deploy step and resumes at step 2.

---

### Diagnostic / read-only scripts

These scripts make no on-chain writes and require no special roles. They are safe to run against any network at any time.

#### `check-buyback-registration.ts`

Reports the BuybackPool registration status and buyback config (default/protected rates, per-tier overrides) for one or more PackMachine clones.

```bash
# All machines from event logs:
npx hardhat run scripts/check-buyback-registration.ts --network base

# Specific machine(s):
PACK_MACHINE=0x<addr>[,0x<addr>] \
  npx hardhat run scripts/check-buyback-registration.ts --network base

# Override BuybackPool address:
BUYBACK_POOL_PROXY=0x<addr> \
  npx hardhat run scripts/check-buyback-registration.ts --network base
```

#### `check-lending-pool-config.ts`

Prints the full configuration of `AssetLendingPool` / `AssetLendingPoolConfig`: LTV, APR, term lengths, utilization cap, eligibility thresholds, lender config, default phase durations, and more. With `TOKEN_IDS` also shows per-token appraisal value, grade, category, and eligibility verdict.

```bash
npx hardhat run scripts/check-lending-pool-config.ts --network base

# Also inspect specific tokens:
TOKEN_IDS=1,2,3 \
  npx hardhat run scripts/check-lending-pool-config.ts --network base
```

#### `check-pack-buyback.ts`

Prints the `buybackPool` address and `buybackAllocationBps` for one or more pack IDs on a PackMachine clone.

```bash
# Default machine + pack 0:
npx hardhat run scripts/check-pack-buyback.ts --network base

# Specific machine and packs:
PACK_MACHINE=0x<addr> PACK_IDS=0,1,2 \
  npx hardhat run scripts/check-pack-buyback.ts --network base
```

#### `debug-token-eligibility.ts`

Traces every condition of `_isEligible()` for one or more AssetNFT token IDs and shows exactly why each token passes or fails collateral eligibility: appraisal present, value ≥ minimum, grade ≥ minimum, category whitelisted.

```bash
TOKEN_ID=42 npx hardhat run scripts/debug-token-eligibility.ts --network base

# Multiple tokens:
TOKEN_ID=1,2,3 npx hardhat run scripts/debug-token-eligibility.ts --network base
```

---

### Contract verification (Tenderly)

`verify-tenderly.ts` verifies every deployed implementation and its ERC1967 proxy on Tenderly using `forge verify-contract`. It reads `deployments/<network>.json`, reconstructs each contract's constructor / `initialize()` calldata, and submits with `--watch`.

**Prerequisites:** `forge` installed (matches compiler settings in `foundry.toml`: solc 0.8.28, 200 runs, viaIR, evm cancun).

**Required environment variables:**

| Variable | Description |
| -------- | ----------- |
| `TENDERLY_ACCOUNT` | Account slug from the Tenderly dashboard URL (case-sensitive) |
| `TENDERLY_PROJECT` | Project slug |
| `TENDERLY_ACCESS_KEY` | From Account Settings → Authorization → Generate Access Token |
| `TENDERLY_VERIFIER_SUFFIX` | *(optional)* Set to `"/public"` to make verifications public (irreversible) |

```bash
pnpm verify:tenderly --network sepolia
# or
pnpm verify:tenderly --network mainnet
pnpm verify:tenderly --network base
```

On completion the script prints a passed/failed/skipped tally and exits 1 if any verification failed.

> **Note:** If bytecode mismatches occur, ensure your local `foundry.toml` settings exactly mirror the Hardhat compiler settings used for deployment (solc version, optimizer runs, viaIR, evm version).

---

## Networks

| Name | Type | Chain |
| ---- | ---- | ----- |
| `hardhatMainnet` | Local simulated | L1 |
| `hardhatOp` | Local simulated | OP |
| `forkMainnet` | Mainnet fork | L1 |
| `forkBase` | Base fork | OP |
| `forkSepolia` | Sepolia fork | L1 |
| `sepolia` | Live testnet | L1 |
| `mainnet` | Live | L1 |
| `base` | Live | OP (Base L2) |

## License

UNLICENSED — All rights reserved, NettyWorth.
