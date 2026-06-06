# NettyWorth Smart Contracts V3

Solidity smart contracts for physical asset tokenization, targeting Ethereum mainnet and Base L2 (OP-stack).

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
  PackMachine.sol                 # Loot-pack NFT distribution (EIP-1167 clone)
  PackMachineFactory.sol          # Deploys and manages PackMachine clones (UUPS)
  PackVRFRouter.sol               # Shared Chainlink VRF v2.5 consumer (UUPS)
  BuybackPool.sol                 # Guaranteed buyback pool for AssetNFTs (UUPS)
  AssetLendingPool.sol            # Asset-collateralized lending pool (UUPS, Ownable2Step)
  AssetLendingPoolConfig.sol      # Lending pool storage layout + admin config (abstract base)
  FeeController.sol               # Marketplace & redemption fee rates (UUPS)
  NettyWorthMarketplace.sol       # AssetNFT marketplace: fixed-price + English auctions (UUPS)
  P2PTradeEscrow.sol              # Atomic P2P asset-swap escrow: ERC20/721/1155 bundles (UUPS, Ownable2Step)
  PermissionManager.sol           # Centralized role registry (AccessControlEnumerable)
  PermissionConsumer.sol          # Abstract base for role-gated contracts
  interfaces/
    IPackMachine.sol              # PackMachine interface
    IPackMachineFactory.sol       # Factory interface
    IPackVRFRouter.sol            # VRF router interface
    IBuybackPool.sol              # BuybackPool interface
    IPermissionManager.sol        # Permission manager interface
    ISignatureTransfer.sol        # Uniswap Permit2 signature transfer interface
    ITransferValidator.sol        # External transfer validation hook
    IFeeController.sol            # FeeController interface
    INettyWorthMarketplace.sol    # Marketplace interface (structs, events, errors)
    IAssetLendingPool.sol         # Lending pool interface (structs, events, errors)
    IAssetNFT.sol                 # Minimal AssetNFT interface used by the lending pool
    IP2PTradeEscrow.sol           # P2P escrow interface (Asset/Trade structs, enums, events, errors)
  lib/
    Roles.sol                     # Protocol role constants library
  test-helpers/                   # Mocks (MockPermit2, MockVRFCoordinatorV2Plus, etc.)
  test/                           # Foundry-style Solidity unit tests (.t.sol)
test/                             # TypeScript integration tests (node:test + viem)
scripts/
  deploy-permission-manager.ts    # Deploy PermissionManager + ERC1967 proxy
  deploy-asset-nft.ts             # Deploy AssetNFT + ERC1967 proxy
  upgrade-asset-nft.ts            # UUPS upgrade for AssetNFT proxy
  deploy-pack-machine.ts          # Deploy PackVRFRouter + PackMachine impl + PackMachineFactory + BuybackPool
  create-pack-machine.ts          # Create a PackMachine clone via factory; register with VRFRouter + BuybackPool
  setup-pack-machine.ts           # Configure a PackMachine clone: set buyback rate, deposit NFTs
  set-callback-gas-limit.ts       # Update PackVRFRouter Chainlink callback gas limit
  upgrade-pack-vrf-router.ts      # UUPS upgrade for PackVRFRouter proxy
  deploy-asset-lending-pool.ts    # Deploy AssetLendingPool + ERC1967 proxy; grant STATE_MANAGER_ROLE
  deploy-fee-controller.ts        # Deploy FeeController + ERC1967 proxy
  deploy-marketplace.ts           # Deploy NettyWorthMarketplace + ERC1967 proxy; wire pool + AssetNFT
  deploy-p2p-trade-escrow.ts      # Deploy P2PTradeEscrow + ERC1967 proxy; standalone (no protocol deps)
  seed-asset-nft.ts               # Dev helper: mint sample AssetNFT cards and seed appraisals
  send-op-tx.ts                   # OP chain transaction example
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
| `PackMachine` | EIP-1167 minimal clone | Individual pack instance — holds prize pool, processes opens |
| `PackMachineFactory` | UUPS-upgradeable singleton | Deploys clones, stores shared config, relays transfer validator hooks |
| `PackVRFRouter` | UUPS-upgradeable singleton | Single Chainlink VRF consumer that routes callbacks to the correct clone |
| `BuybackPool` | UUPS-upgradeable singleton | Holds USDC from pack sales; pays guaranteed buyback to NFT holders; re-deposits NFTs into source machine |

### Pack Open Call Flow

```text
User ──► PackMachine.openPack() ──► PackVRFRouter.requestRandomWords() ──► Chainlink VRF
                                                                                  │
User ◄── NFT transferred ◄── PackMachine.fulfillRandomness() ◄── PackVRFRouter.rawFulfillRandomWords()
                                        │
                                        └──► BuybackPool.registerToken() (records per-card price + tier)
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
| `PACK_OPERATOR_ROLE` | Create pack machines, deposit/withdraw cards, set price, stop machine, authorize VRF |
| `BUYBACK_POOL_ROLE` | Reserved for BuybackPool contract to call `depositFromPool` on PackMachine instances |

`PACK_OPERATOR_ROLE` holders also sign the off-chain EIP-712 `OpenPack` authorization required per pack open.

### PackMachine Features

- **EIP-1167 minimal clones** — cheap per-machine deployment; each clone has its own ERC-7201 namespaced storage
- **Chainlink VRF v2.5** — verifiable on-chain randomness; shared router avoids Chainlink's per-subscription consumer cap
- **Permit2 gasless payments** — `openPackWithPermit2` uses Uniswap's canonical Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) for relayer-submitted USDC transfers
- **EIP-712 play signatures** — operator signs each pack open off-chain; per-user nonce prevents replay
- **Swap-and-pop prize pool** — O(1) random card selection and removal from the prize pool array
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
- **Emergency withdrawal** — admin can drain USDC to financeWallet while paused
- **NFT rescue** — admin can recover stuck NFTs (e.g. if source PackMachine is deregistered)

## AssetLendingPool Contract

`AssetLendingPool` is a UUPS-upgradeable, platform-operated lending pool that accepts `AssetNFT` tokens as collateral. It is funded by both the platform treasury (owner capital) and external lenders. Loans use fixed terms with interest computed upfront. The contract also supports an atomic marketplace-financing path (buyer pays a deposit, pool finances the remainder). Admin control uses `Ownable2StepUpgradeable` — a deliberate deviation from the `PermissionConsumer` pattern used by the rest of the protocol.

Configuration setters, the ERC-7201 storage layout, and eligibility helpers live in the abstract base `AssetLendingPoolConfig`; business logic lives in the concrete `AssetLendingPool`.

### How It Works

1. **Borrow** — a borrower collateralizes one token (`borrow`) or up to 50 tokens as a bundle (`borrowBundle`). The maximum loan amount is `LTV × Σ(appraisal values)`. Interest is fixed upfront and deducted from the disbursement.
2. **Repay** — the borrower repays principal + pre-fixed interest before the term deadline, reclaiming all collateral atomically.
3. **Marketplace financing** — `financeMarketplacePurchase` atomically purchases an NFT from a seller and opens a loan: the buyer pays the deposit, the pool finances `appraisalValue − deposit`, and the token becomes collateral immediately.
4. **Lender capital** — external lenders call `lenderDeposit` / `lenderWithdraw` / `claimLenderInterest`. Withdraw and claim deliberately omit `whenNotPaused` so lenders can always exit even during an emergency pause.

### Loan Terms (defaults)

| Term ID | Duration | APR |
| ------- | -------- | --- |
| `0` | 7 days | 10% (1000 bps) |
| `1` | 15 days | 15% (1500 bps) |
| `2` | 30 days | 20% (2000 bps) |

Interest formula: `principal × aprBps × duration / (365 days × BPS)`. Term configs are admin-adjustable via `setTermConfig`.

### Default Lifecycle

When the borrower misses repayment, the owner calls `initiateDefault`. The asset then passes through three phases (durations configurable):

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
- **Split capital accounting** — owner/treasury deposits tracked separately from lender capital and protocol interest
- **Configurable origination fee** — `originationFeeBps` deducted from disbursement (or pulled from buyer in marketplace path), sent to `feeWallet`
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

`NettyWorthMarketplace` is a UUPS-upgradeable marketplace for `AssetNFT` tokens. It supports two trade modes: **fixed-price sales** (off-chain EIP-712 signed listings) and **hybrid English auctions** (seller and bidders sign messages off-chain; minimal on-chain state enforces rules at commitment/settlement). USDC / ERC-20 only — no native ETH. Access control is via `PermissionConsumer` / `PermissionManager`.

### Trade Flows

#### Fixed-price sales

1. The seller signs a `SignedListing` EIP-712 message off-chain (collection, tokenId, price, payment token, expiry, nonce).
2. The buyer calls `buyWithSignature(listing, sig)` — the marketplace verifies the signature, marks the nonce used (CEI), then executes the sale atomically.

#### Hybrid English auctions

1. The seller signs a `SignedAuction` off-chain (reserve price, min increment, start/end times, extension window + duration, nonce).
2. Bidders sign `SignedBid` messages off-chain (auctionId, amount, nonce, expiry).
3. `commitBid(auctionSig, bidSig)` is called on-chain — the first valid bid **materialises** an `AuctionState` (reserve enforced); subsequent bids must exceed `highestBid + minIncrement`. If a bid lands within `extensionWindow` of `endTime`, the auction extends by `extensionDuration`. No funds move at commitment.
4. After `endTime`, anyone calls `settleAuction(auctionId)` — or `MARKETPLACE_ROLE` can force-close early. The winner's payment is pulled and the NFT is delivered atomically.

#### Loan-aware settlement

If the token is collateralised in `AssetLendingPool`, the minimum acceptable sale price equals principal + outstanding interest. On sale, the loan debt is repaid atomically via `settleLoanRepaymentOnSale` — the pool releases the NFT directly to the buyer, and the seller receives only the net proceeds.

### Fees & Royalties

Fees are deducted from gross proceeds before the seller receives anything:

1. **Collectible fee** — queried from `FeeController.getCollectibleFee(gross)` (default 5%), sent to `treasury`.
2. **ERC-2981 royalty** — queried via `try/catch` so a non-compliant collection cannot revert the sale; royalty is capped so `royalty + collectibleFee ≤ gross − loanDebt`.

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
- **ReentrancyGuard** — protects `buyWithSignature`, `commitBid`, and `settleAuction`
- **Pausable** — emergency stop via `PAUSER_ROLE`
- **EIP-712 signatures** — three typehashes: `SignedListing`, `SignedAuction`, `SignedBid`; domain `("NettyWorthMarketplace", "1")`
- **No-escrow hybrid auctions** — funds pulled from winner at settlement only; last-minute extension prevents sniping
- **Per-signer nonce replay protection** — `usedNonces` mapping consumed CEI-style; user-cancellable via `cancelNonce`
- **Collection + payment-token whitelists** — `allowedCollections` and `allowedPaymentTokens` mappings
- **Loan-aware settlement** — atomic loan repayment on sale; min price enforced against outstanding debt
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

# --- setup-pack-machine.ts (required) ---
TOKEN_IDS=                        # Comma-separated token IDs or range (e.g. 1-50 or 1,2,3) to deposit
TIERS=                            # Comma-separated tier values (0=Base … 4=Ultra) matching TOKEN_IDS
BUYBACK_ALLOCATION_BPS=           # Fraction of pack price allocated to buyback fund (e.g. 3000 = 30%)

# --- deploy-asset-lending-pool.ts (required) ---
# PAYMENT_TOKEN reused from above
LTV_BPS=                          # Max loan-to-value in basis points (default 5000 = 50%)
LENDER_SHARE_BPS=                 # Lender share of interest in bps (default 8000 = 80%)

# --- deploy-fee-controller.ts (required) ---
TREASURY=                         # Platform fee recipient address

# --- deploy-marketplace.ts (required) ---
# PAYMENT_TOKEN and TREASURY reused from above
FEE_CONTROLLER_PROXY=             # (optional) Override FeeController proxy; falls back to deployments/<network>.json
LENDING_POOL_PROXY=               # (optional) Override AssetLendingPool proxy; falls back to deployments/<network>.json
ASSET_NFT_PROXY=                  # (optional) Override AssetNFT proxy; falls back to deployments/<network>.json
SKIP_NFT_WIRING=                  # Set to true to skip AssetNFT wiring (call setters manually)

# --- deploy-p2p-trade-escrow.ts ---
OWNER=                            # (optional) Owner address; defaults to deployer
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
  ├── PackMachineFactory   depends on PermissionManager + AssetNFT
  │     └── PackMachine clones  EIP-1167, created by the factory
  ├── BuybackPool          depends on PermissionManager + AssetNFT + PackMachineFactory
  ├── AssetLendingPool     depends on AssetNFT + PackMachineFactory
  │                        ⚠ must be granted STATE_MANAGER_ROLE on PermissionManager post-deploy
  ├── FeeController        depends on PermissionManager
  └── NettyWorthMarketplace  depends on PermissionManager + FeeController + AssetLendingPool + AssetNFT
                             ⚠ marketplace contract address must be granted MARKETPLACE_ROLE for force-close

P2PTradeEscrow             (standalone — no protocol deps; deploy independently at any time)
```

> **Note:** `deploy-pack-machine.ts` is a composite script — it deploys `PackVRFRouter`, the `PackMachine` logic contract, `PackMachineFactory`, and `BuybackPool` in a single run, then wires the factory (`setImplementation` / `setPackVRFRouter` / `setBuybackPool`) automatically.

### Deployment order

| # | Step | Script | Contracts deployed | Depends on |
| - | ---- | ------ | ------------------ | ---------- |
| 1 | Permission registry | `deploy-permission-manager.ts` | PermissionManager (UUPS) | — |
| 2 | Asset NFT | `deploy-asset-nft.ts` | AssetNFT (UUPS) | PermissionManager |
| 3 | Pack system | `deploy-pack-machine.ts` | PackVRFRouter, PackMachine impl, PackMachineFactory, BuybackPool (all UUPS) | PermissionManager, AssetNFT |
| 4 | Create a pack | `create-pack-machine.ts` | PackMachine clone (EIP-1167) | PackMachineFactory, PackVRFRouter, BuybackPool |
| 5 | Configure pack | `setup-pack-machine.ts` | — (deposits NFTs, sets buyback rate) | PackMachine clone, BuybackPool, AssetNFT |
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

Deploys — in order — `PackVRFRouter` (UUPS), the `PackMachine` logic contract (clone target, no proxy), `PackMachineFactory` (UUPS), and `BuybackPool` (UUPS). After all four are live, the script wires the factory automatically by calling:

- `factory.setImplementation(packMachineImpl)`
- `factory.setPackVRFRouter(vrfRouterProxy)`
- `factory.setBuybackPool(buybackProxy)` *(also wires `factory.setBuybackPool` on BuybackPool side)*

Saves `PackVRFRouter`, `PackMachineImplementation`, `PackMachineFactory`, and `BuybackPool` to `deployments/<network>.json`.

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

Calls `factory.createPackMachine(...)` to deploy an EIP-1167 clone, then automatically:

- `vrfRouter.setAuthorizedPackMachine(clone, true)` — allows the clone to request VRF randomness
- `buybackPool.registerPackMachine(clone, true)` — allows the clone to register tokens in the buyback pool

Appends the clone address and config to the `PackMachines[]` array in `deployments/<network>.json`.

---

### Step 5 — Configure a PackMachine (deposit cards)

**Prerequisites:** Step 4 complete; AssetNFTs minted and owned by the operator. Required env vars:

| Variable | Description |
|----------|-------------|
| `TOKEN_IDS` | Comma-separated IDs or range (e.g. `1-50` or `1,2,3`) |
| `TIERS` | Comma-separated tier values (0=Base … 4=Ultra) matching `TOKEN_IDS` |
| `BUYBACK_ALLOCATION_BPS` | Fraction of pack price held for buybacks (e.g. `3000` = 30%) |

```bash
npx hardhat run scripts/setup-pack-machine.ts --network <network>
```

Configures the most recently created clone (or the address in env `PACK_MACHINE_PROXY`):

1. `clone.setBuybackPool(buybackProxy)` + `clone.setBuybackAllocation(bps)`
2. `assetNFT.setApprovalForAll(clone, true)`
3. Batched `clone.deposit(tokenIds, tiers, tokensOwner)` — up to 50 tokens per batch

Updates the matching `PackMachines[]` entry in `deployments/<network>.json` with deposited tokens and config.

> To enable the BuybackPool to re-deposit NFTs back into this machine after a buyback, also call `clone.setAuthorizedDepositor(buybackPoolProxy, true)` (requires `PACK_OPERATOR_ROLE`).

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
| `seed-asset-nft.ts` | Dev/test helper — mint sample AssetNFT cards and set appraisals | `MINTER_ROLE` |

```bash
# Example: update callback gas limit
CALLBACK_GAS_LIMIT=250000 npx hardhat run scripts/set-callback-gas-limit.ts --network <network>

# Example: upgrade AssetNFT
npx hardhat run scripts/upgrade-asset-nft.ts --network <network>
```

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
