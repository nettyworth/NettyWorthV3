# NettyWorth V3 — Production Operations Runbook

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Contract Addresses](#2-contract-addresses)
3. [Role & Access Control Reference](#3-role--access-control-reference)
4. [Asset Lending Pool — Day-to-Day Operations](#4-asset-lending-pool--day-to-day-operations)
   - 4.1 [Set Eligibility Controls](#41-set-eligibility-controls)
   - 4.2 [Batch Set Appraisals (manual / cron)](#42-batch-set-appraisals-manual--cron)
   - 4.3 [Lender Config](#43-lender-config)
5. [Role Management](#5-role-management)
6. [Pack Machine Operations](#6-pack-machine-operations)
7. [Buyback Pool Operations](#7-buyback-pool-operations)
8. [Upgrades (UUPS)](#8-upgrades-uups)
9. [Emergency Procedures](#9-emergency-procedures)
10. [Cron Job Integration (Backend)](#10-cron-job-integration-backend)
11. [Verification Checklist After Any Operation](#11-verification-checklist-after-any-operation)

---

## 1. Prerequisites

### Environment

All scripts run via:
```bash
npx hardhat run scripts/<script>.ts --network <network>
```

Network names: `sepolia` (testnet) · `mainnet` · `base`

### Required env vars for live networks

| Var | Purpose |
|-----|---------|
| `SEPOLIA_RPC_URL` | Sepolia HTTP RPC |
| `SEPOLIA_PRIVATE_KEY` | Owner/admin wallet private key |
| `MAINNET_RPC_URL` | Mainnet HTTP RPC |
| `MAINNET_PRIVATE_KEY` | Owner/admin wallet private key |
| `BASE_RPC_URL` | Base L2 HTTP RPC |
| `BASE_PRIVATE_KEY` | Owner/admin wallet private key |

Store these in a `.env` file (never commit it). Hardhat loads them via `configVariable()`.

### Who signs what

| Contract | Admin mechanism | Signing key |
|----------|----------------|-------------|
| AssetLendingPool | `Ownable2StepUpgradeable` | Owner wallet |
| PermissionManager | `DEFAULT_ADMIN_ROLE` (role-based) | Admin wallet |
| AssetNFT, PackMachineFactory, PackVRFRouter, BuybackPool, FeeController, NettyWorthMarketplace | `PermissionConsumer` roles via PermissionManager | Wallet holding the required role |
| P2PTradeEscrow | `Ownable2StepUpgradeable` | Owner wallet |

On Sepolia the owner/admin is `0xC9e1A4D1F52aE8Dc52eb0642CbA1edc4c56E29Ef`.

---

## 2. Contract Addresses

### Sepolia (testnet)

| Contract | Proxy | Notes |
|----------|-------|-------|
| PermissionManager | `0x8aF208488d6198F4712FCA457dcE8259Ac141601` | Role hub |
| AssetNFT | `0x2f8BD4136edDEd19473448c24Da5C8aB9174b20C` | ERC721A |
| PackVRFRouter | `0x1126d2dd1641c06ecd26b75e379655b64fc7f8dc` | VRF consumer |
| PackMachineFactory | `0xe013F4BBd886460F0747d9A9fF7FEE473A272dd9` | Deploys clones |
| BuybackPool | `0x3c716e0d0a9863270978dd925f6b2a1dfd30cce8` | Buyback singleton |
| AssetLendingPool | `0xe0e07bfd17e86876a721fe0276471bde63936fb2` | Lending |
| FeeController | `0xcd6cda75b6ce21f5b83125f414607b9b8cd8c96f` | Fee config |
| NettyWorthMarketplace | `0x845d2d9421d3f31a47f2458c2b4eb935baab587a` | Marketplace |
| P2PTradeEscrow | `0xdae8112e2ce2c09f58eef507d502263b58398674` | P2P escrow |
| USDC (payment token) | `0x8545C5930F36aBE57ED4F5372f3fbB8b49E533DB` | 6 decimals |

Canonical source of truth: `deployments/sepolia.json` (updated by scripts after each operation).

---

## 3. Role & Access Control Reference

Roles live in `contracts/lib/Roles.sol` and are granted/revoked via `PermissionManager`.

| Role | Who holds it | What it unlocks |
|------|-------------|----------------|
| `DEFAULT_ADMIN_ROLE` | Owner wallet | Grant/revoke all roles, upgrade PermissionManager, config setters on FeeController/Marketplace |
| `UPGRADER_ROLE` | Owner wallet | UUPS upgrades on AssetNFT, PackMachineFactory, PackVRFRouter, BuybackPool, FeeController, Marketplace |
| `MINTER_ROLE` | Backend service (`0xA89D...0E3f`) | `AssetNFT.mint()` |
| `BURNER_ROLE` | Backend service | `AssetNFT.burn()` |
| `PACK_OPERATOR_ROLE` | Backend service | Sign `OpenPack` EIP-712 messages, set per-machine buyback rates, create pack machines |
| `STATE_MANAGER_ROLE` | AssetLendingPool proxy | `AssetNFT.batchSetAssetState()` — moves NFTs between Held/Loaned states |
| `MARKETPLACE_ROLE` | NettyWorthMarketplace proxy | `AssetLendingPool.settleLoanRepaymentOnSale()` |
| `PAUSER_ROLE` | Owner wallet | Pause AssetNFT, Marketplace |
| `BLACKLIST_ROLE` | Owner wallet | Block addresses from AssetNFT transfers |
| `BUYBACK_POOL_ROLE` | BuybackPool proxy | Internal — used by BuybackPool to call AssetNFT |
| `URI_SETTER_ROLE` | Backend service | `AssetNFT.setTokenURI()` / `setContractURI()` |

---

## 4. Asset Lending Pool — Day-to-Day Operations

### 4.1 Set Eligibility Controls

**When to run:** Initial setup, when adding new asset categories, or adjusting minimum collateral thresholds.

**Script:** `scripts/set-eligibility-controls.ts`  
**Auth:** Owner wallet (`onlyOwner`)

**Parameters:**

| Env var | Description | Example |
|---------|-------------|---------|
| `MIN_APPRAISAL_VALUE` | Minimum value in whole token units (auto-scaled) | `100` ($100) |
| `MIN_GRADE` | Minimum numeric grade (0 = no filter) | `1` |
| `ADD_CATEGORIES` | Comma-separated category IDs to whitelist | `1,2,3` |
| `REMOVE_CATEGORIES` | Comma-separated category IDs to de-list | `4,5` |
| `ASSET_LENDING_POOL_PROXY` | Override proxy address (optional) | `0xe0e0...` |
| `SKIP_CONFIRM` | Skip interactive prompt (for cron) | `true` |

**Key rule:** Category `0` is always allowed — no whitelist needed. Any non-zero category must be explicitly added before assets with that category ID can be used as collateral.

```bash
# Initial setup — whitelist categories 1,2,3; min $100 value; min grade 1
MIN_APPRAISAL_VALUE=100 MIN_GRADE=1 ADD_CATEGORIES=1,2,3 \
  npx hardhat run scripts/set-eligibility-controls.ts --network sepolia

# Add new category without changing thresholds
MIN_APPRAISAL_VALUE=100 MIN_GRADE=1 ADD_CATEGORIES=4 \
  npx hardhat run scripts/set-eligibility-controls.ts --network sepolia

# Raise minimum value to $500
MIN_APPRAISAL_VALUE=500 MIN_GRADE=1 \
  npx hardhat run scripts/set-eligibility-controls.ts --network sepolia
```

**Troubleshooting `AssetLendingPool__IneligibleAsset`:**
1. Check the token's appraisal: call `getAppraisal(tokenId)` — `updatedAt == 0` means it was never appraised.
2. Check `isEligible(tokenId)` — returns `false` if value < min, grade < min, or category not whitelisted.
3. Run `set-eligibility-controls` with `ADD_CATEGORIES=<category>` to whitelist the category.
4. Re-run `batch-set-appraisals` if the appraisal is stale (check `maxAppraisalAge` in `getPoolInfo()`).

---

### 4.2 Batch Set Appraisals (manual / cron)

**When to run:** After new AssetNFTs are minted, periodically to refresh valuations, or when `maxAppraisalAge` staleness would block a loan.

**Script:** `scripts/batch-set-appraisals.ts`  
**Auth:** Owner wallet (`onlyOwner`)

**Input file format** (`APPRAISALS_FILE`):
```json
[
  { "tokenId": 13, "value": 1000, "grade": 9, "category": 1 },
  { "tokenId": 14, "value": 2500, "grade": 10, "category": 2 }
]
```

- `value` — whole dollar units; script auto-scales by `paymentToken.decimals()` (6 for USDC → `1000 → 1000_000000`)
- `grade` — numeric (e.g. PSA/SGC scale, 1–10)
- `category` — must be `0` or a whitelisted category ID (see §4.1)
- Max 50 tokens per transaction; script auto-chunks larger files

**Parameters:**

| Env var | Description |
|---------|-------------|
| `APPRAISALS_FILE` | Path to JSON input file |
| `ASSET_LENDING_POOL_PROXY` | Override proxy address (optional) |
| `SKIP_CONFIRM` | Skip interactive prompt (`true` for cron) |

```bash
# Manual run
APPRAISALS_FILE=./scripts/appraisals.example.json \
  npx hardhat run scripts/batch-set-appraisals.ts --network sepolia

# Cron / non-interactive
APPRAISALS_FILE=/var/data/appraisals.json SKIP_CONFIRM=true \
  npx hardhat run scripts/batch-set-appraisals.ts --network mainnet
```

**Batching:** 336 tokens = 7 transactions (6×50 + 1×36). All batches are sent sequentially; if one fails, subsequent batches are skipped.

**Post-tx:** The script reads back every `getAppraisal(tokenId)` and exits `1` with a `CRITICAL:` message if any value doesn't match. Monitor exit code in cron.

---

### 4.3 Lender Config

**When to run:** Adjusting the share of interest paid to external lenders, or toggling lender deposit acceptance.

**Script:** `scripts/set-lender-config.ts`  
**Auth:** Owner wallet

| Env var | Description | Example |
|---------|-------------|---------|
| `SHARE_BPS` | Lender's share of interest in basis points (0–10000) | `8000` (80%) |
| `ENABLED` | Whether lender deposits are accepted | `true` / `false` |

```bash
SHARE_BPS=8000 ENABLED=true \
  npx hardhat run scripts/set-lender-config.ts --network mainnet
```

---

## 5. Role Management

**Script:** `scripts/grant-role.ts`  
**Auth:** `DEFAULT_ADMIN_ROLE` on PermissionManager

| Env var | Description | Example |
|---------|-------------|---------|
| `ROLE` | Role name string | `MINTER_ROLE` |
| `ACCOUNT` | Address to grant/revoke | `0xABCD...` |
| `ACTION` | `grant` or `revoke` | `grant` |
| `PERMISSION_MANAGER_PROXY` | Override address (optional) | |

```bash
# Grant MINTER_ROLE to backend service
ROLE=MINTER_ROLE ACCOUNT=0xA89Da886BAc2A60a99847E7e97e9b4ab047b0E3f ACTION=grant \
  npx hardhat run scripts/grant-role.ts --network mainnet

# Revoke a compromised key
ROLE=PACK_OPERATOR_ROLE ACCOUNT=0xOLD... ACTION=revoke \
  npx hardhat run scripts/grant-role.ts --network mainnet
```

Grants are appended to `RoleGrants` in `deployments/<network>.json` for audit.

**Required roles to grant on initial mainnet deploy (in order):**

| Role | Recipient |
|------|-----------|
| `MINTER_ROLE` | Backend minting service |
| `BURNER_ROLE` | Backend service |
| `URI_SETTER_ROLE` | Backend service |
| `PACK_OPERATOR_ROLE` | Backend signing service |
| `STATE_MANAGER_ROLE` | AssetLendingPool proxy address |
| `MARKETPLACE_ROLE` | NettyWorthMarketplace proxy address |
| `UPGRADER_ROLE` | Admin multisig (if using one) |

---

## 6. Pack Machine Operations

### Create a Pack Machine

**Script:** `scripts/create-pack-machine.ts`  
**Auth:** `PACK_OPERATOR_ROLE`

Creates a new EIP-1167 clone of PackMachineImplementation via PackMachineFactory. Registers it automatically with BuybackPool.

### Set Callback Gas Limit (VRF)

**Script:** `scripts/set-callback-gas-limit.ts`  
**Auth:** `DEFAULT_ADMIN_ROLE` on PackVRFRouter

```bash
CALLBACK_GAS_LIMIT=300000 \
  npx hardhat run scripts/set-callback-gas-limit.ts --network mainnet
```

Increase if VRF fulfillment transactions are running out of gas. Default is `250000`.

### Set Key Hash (VRF Gas Lane)

**Script:** `scripts/set-key-hash.ts`  
**Auth:** `DEFAULT_ADMIN_ROLE` on PackVRFRouter

```bash
VRF_KEY_HASH=0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab \
  npx hardhat run scripts/set-key-hash.ts --network mainnet
```

Updates the Chainlink VRF key hash used when requesting randomness. The key hash identifies the gas lane (speed/cost tier) for the VRF subscription. Use when switching to a different gas lane or after redeploying the VRF router on a new network.

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `VRF_KEY_HASH` | Yes | 0x-prefixed 32-byte hex string (66 characters) identifying the Chainlink gas lane |
| `PACK_VRF_ROUTER_PROXY` | No | Override the proxy address; defaults to `deployments/<network>.json` |

The script reads the current key hash from on-chain storage, short-circuits if it is already equal, prompts for confirmation on live networks, and persists the updated value to `deployments/<network>.json`.

---

## 7. Buyback Pool Operations

### Per-machine buyback rate

Set via `BuybackPool.setPackMachineBuybackBps(machineAddress, bps)` — requires `PACK_OPERATOR_ROLE`. A value of `0` falls back to `defaultBuybackBps` (currently 80%). Example: premium packs at 90% → `9000`.

No script exists yet; call directly via viem or Etherscan.

### Rescue stuck NFTs

If a PackMachine is deregistered while holding NFTs, use `BuybackPool.rescueNFT(tokenId, recipient)` — requires `DEFAULT_ADMIN_ROLE`.

---

## 8. Upgrades (UUPS)

All contracts except PackMachine (EIP-1167 clone — not upgradeable) use UUPS.

**Scripts:** `scripts/upgrade-asset-nft.ts`, `scripts/upgrade-pack-vrf-router.ts`  
**Auth:** `UPGRADER_ROLE` (except PermissionManager which uses `DEFAULT_ADMIN_ROLE`)

General upgrade process:
1. Deploy new implementation contract (`pnpm compile` first).
2. Run the upgrade script — it calls `upgradeToAndCall(newImpl, "")` through the proxy.
3. Verify: check `implementation` address in `deployments/<network>.json` updated.
4. Re-run integration tests against the upgraded proxy.

**Storage safety:** All contracts use ERC-7201 namespaced storage. Never add fields to the middle of a storage struct — only append to the end. The struct lives in `AssetLendingPoolConfig.sol` (`AssetLendingPoolStorage`).

---

## 9. Emergency Procedures

### Pause AssetNFT transfers

Requires `PAUSER_ROLE`. Call `AssetNFT.pause()` directly (no script — use Etherscan or viem).  
Blocks all token transfers. Does **not** affect lender withdrawals or trade cancellations.

### Pause Marketplace

Requires `PAUSER_ROLE`. Call `NettyWorthMarketplace.pause()`.  
Blocks `createListing`, `buyNow`, `commitBid`, `settleAuction`. Force-close/cancel operations remain available to `MARKETPLACE_ROLE`.

### Pause P2PTradeEscrow

Requires owner. Call `P2PTradeEscrow.pause()`.  
Blocks `createTrade` and `acceptTrade`. `cancelTrade`/`expireTrade` intentionally remain open so escrowed assets can always be reclaimed.

### Blacklist a wallet

Requires `BLACKLIST_ROLE`. Call `AssetNFT.setBlacklisted(address, true)`. Blocks that address from sending or receiving AssetNFTs.

### Freeze lender deposits

```bash
SHARE_BPS=<current_value> ENABLED=false \
  npx hardhat run scripts/set-lender-config.ts --network mainnet
```

Lenders can always withdraw even when deposits are disabled.

### Compromised signing key

1. Revoke the role immediately:
   ```bash
   ROLE=PACK_OPERATOR_ROLE ACCOUNT=0xCOMPROMISED ACTION=revoke \
     npx hardhat run scripts/grant-role.ts --network mainnet
   ```
2. Grant the role to a fresh key.
3. Rotate the key in the backend service.

---

## 10. Cron Job Integration (Backend)

The backend cron pattern for appraisals:

1. Backend queries its database for tokens needing fresh appraisals.
2. Writes a JSON file to a known path (e.g. `/var/data/appraisals.json`).
3. Invokes the script with `SKIP_CONFIRM=true`:
   ```bash
   APPRAISALS_FILE=/var/data/appraisals.json \
   SKIP_CONFIRM=true \
   SEPOLIA_PRIVATE_KEY=$OWNER_KEY \
   npx hardhat run scripts/batch-set-appraisals.ts --network mainnet
   ```
4. Checks the exit code: `0` = success, `1` = failure (critical mismatch or tx error).
5. On failure, page on-call — do **not** retry automatically, as a failure may indicate a chain issue or key problem.

**Recommended cron cadence:** Run appraisal updates on a schedule aligned with `maxAppraisalAge` in the pool config. Check `getPoolInfo().maxAppraisalAge` (seconds) — refresh before that window expires for any actively-collateralized token.

---

## 11. Verification Checklist After Any Operation

After every script run on a live network, confirm:

- [ ] Script exited with code `0`
- [ ] Tx hash logged and visible on Etherscan
- [ ] `deployments/<network>.json` updated with new state (where applicable)
- [ ] Read-back values match expected (scripts do this automatically and exit `1` on mismatch)
- [ ] For role grants: entry present in `RoleGrants` array in deployment file
- [ ] For appraisals: spot-check a few `getAppraisal(tokenId)` calls and `isEligible(tokenId)`
- [ ] For eligibility changes: attempt `isEligible` on a known token with the target category
- [ ] For upgrades: `implementation` address in deployment file matches newly deployed contract
