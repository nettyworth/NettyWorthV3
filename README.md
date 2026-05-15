# NettyWorth Smart Contracts V3

Solidity smart contracts for physical asset tokenization, targeting Ethereum mainnet and Base L2 (OP-stack).

## Tech Stack

| Layer | Technology |
| ----- | ---------- |
| Language | Solidity 0.8.28 |
| Framework | Hardhat 3 (beta) |
| Libraries | OpenZeppelin Contracts Upgradeable v5.6.1 |
| Test runner | Foundry-style `.t.sol` + Node.js `node:test` |
| Chain interaction | viem |
| Package manager | pnpm |

## Project Layout

```text
contracts/
  AssetNFT.sol              # Main ERC-721 asset tokenization contract
  test-helpers/             # Thin proxy wrappers used in tests
  test/                     # Foundry-style Solidity unit tests (.t.sol)
test/                       # TypeScript integration tests (node:test + viem)
scripts/
  deploy-asset-nft.ts       # Deployment script (implementation + ERC1967 proxy)
  send-op-tx.ts             # OP chain transaction example
```

## AssetNFT Contract

`AssetNFT` is an ERC-721 NFT representing tokenized physical assets. Each token tracks a lifecycle state and enforces allowed transitions.

### Roles

| Role | Permission |
| ---- | ---------- |
| `DEFAULT_ADMIN_ROLE` | Manage all roles |
| `MINTER_ROLE` | Mint new tokens |
| `BURNER_ROLE` | Burn tokens |
| `STATE_MANAGER_ROLE` | Transition asset lifecycle states |
| `URI_SETTER_ROLE` | Update token and contract metadata URIs |
| `PAUSER_ROLE` | Pause and unpause transfers |
| `UPGRADER_ROLE` | Authorize UUPS contract upgrades |

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

- **UUPS upgradeable** (EIP-1822) — logic can be upgraded without changing the proxy address
- **Role-based access control** — fine-grained permissions via `AccessControlUpgradeable`
- **Batch operations** — `batchMint` (up to 50) and `batchSetAssetState`
- **Pausable transfers** — emergency stop via `PAUSER_ROLE`
- **ERC-7201 namespaced storage** — collision-safe across upgrades
- **ERC-7572 contract URI** — collection-level metadata

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
ASSET_NFT_NAME=
ASSET_NFT_SYMBOL=
ASSET_NFT_CONTRACT_URI=
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

`scripts/deploy-asset-nft.ts` deploys the implementation contract and an ERC1967 proxy in a single run. On success it saves addresses to `deployments/<network>.json`.

```bash
npx hardhat run scripts/deploy-asset-nft.ts --network <network>
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
