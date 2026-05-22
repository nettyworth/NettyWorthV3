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
  lib/
    Roles.sol                     # Protocol role constants library
  test-helpers/                   # Mocks (MockPermit2, MockVRFCoordinatorV2Plus, etc.)
  test/                           # Foundry-style Solidity unit tests (.t.sol)
test/                             # TypeScript integration tests (node:test + viem)
scripts/
  deploy-permission-manager.ts    # Deploy PermissionManager + ERC1967 proxy
  deploy-asset-nft.ts             # Deploy AssetNFT + ERC1967 proxy
  upgrade-asset-nft.ts            # UUPS upgrade for AssetNFT proxy
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

# Optional — used by deploy-asset-nft.ts
PERMISSION_MANAGER_PROXY=
ASSET_NFT_NAME=
ASSET_NFT_SYMBOL=
ASSET_NFT_CONTRACT_URI=
ASSET_NFT_ROYALTY_RECEIVER=
ASSET_NFT_ROYALTY_FEE=
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

### 1. Deploy PermissionManager

```bash
npx hardhat run scripts/deploy-permission-manager.ts --network <network>
```

Deploys the PermissionManager implementation and ERC1967 proxy. Saves addresses to `deployments/<network>.json`.

### 2. Deploy AssetNFT

```bash
npx hardhat run scripts/deploy-asset-nft.ts --network <network>
```

Deploys AssetNFT implementation and ERC1967 proxy. Resolves `PERMISSION_MANAGER_PROXY` from env or prior deployment in `deployments/<network>.json`.

### 3. Upgrade AssetNFT

```bash
npx hardhat run scripts/upgrade-asset-nft.ts --network <network>
```

Deploys a new AssetNFT implementation and calls `upgradeToAndCall` on the existing proxy. Requires `UPGRADER_ROLE`.

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
