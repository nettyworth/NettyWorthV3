# NettyWorth V3 — Deployment Checklist

Use this checklist when deploying to a live network (Base / Sepolia / Base Sepolia / Mainnet).
It captures the exact order, commands, env vars, and manual post-deploy steps the scripts
expect, plus on-chain wiring/role grants that must be verified before the protocol is live.

**Resume safety.** Scripts re-use addresses already in `deployments/<network>.json` (if
bytecode exists on chain) and skip wiring setters that are already correct — re-running after
a failure is safe. Deploys and setters only write the JSON and prompt for `yes` on live
(`http`) networks; fork networks are the intended dry-run target and never mutate the JSON.
Env vars are read from `.env` (scripts import `dotenv/config`) or the Hardhat keystore.

---

## 0. Pre-deploy — environment & sanity

- [ ] Correct branch checked out; `git status` clean or intentional.
- [ ] `pnpm install` done.
- [ ] `pnpm compile` succeeds (also runs contract-sizer — confirm no size overflow).
- [ ] `pnpm lint` clean (`solhint 'contracts/**/*.sol'`).
- [ ] `pnpm test` (TypeScript) and `npx hardhat test solidity` (Foundry) pass.
- [ ] `.env` populated with config variables for the target network:
  - Sepolia: `SEPOLIA_RPC_URL`, `SEPOLIA_PRIVATE_KEY`
  - Base: `BASE_RPC_URL`, `BASE_PRIVATE_KEY`
  - Base Sepolia: `BASE_SEPOLIA_RPC_URL`, `BASE_SEPOLIA_PRIVATE_KEY`
  - Mainnet: `MAINNET_RPC_URL`, `MAINNET_PRIVATE_KEY`
- [ ] Deployer wallet funded with native gas on the target chain.
- [ ] Decide & record the operational addresses before starting:

  | Variable | Description |
  |---|---|
  | `PAYMENT_TOKEN` | USDC address on the chain (Base mainnet: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`) |
  | `FINANCE_WALLET` | Address that receives pack-open payments |
  | `TREASURY` | Fee recipient address |
  | `TRUSTED_FORWARDER` | ERC-2771 forwarder (`0x0` if none) |
  | `VRF_COORDINATOR` | Chainlink VRF v2.5 coordinator address |
  | `VRF_SUBSCRIPTION_ID` | Funded Chainlink subscription ID |
  | `VRF_KEY_HASH` | VRF key hash / gas lane (0x-prefixed 32-byte hex) |

- [ ] `DEPLOY_STEP_DELAY_MS` tuned if the RPC rate-limits (default 3000 ms).
- [ ] Back up the existing `deployments/<network>.json` before re-deploying.

> **Deploy command form** (all scripts):
> `npx hardhat run scripts/<script>.ts --network <network>`
>
> Live networks prompt `Proceed with deployment? (yes/no)` and write to
> `deployments/<network>.json`.  **Dry-run first** on the matching fork network
> (e.g. `--network forkBase`) — exercises the full flow without spending real gas.

---

## 1. Deploy sequence

Order matters — each script reads earlier contract addresses from
`deployments/<network>.json`. Override with the matching `*_PROXY` env var if needed.

1. [ ] **PermissionManager** — `scripts/deploy-permission-manager.ts`
   - No prerequisites. Deployer becomes `DEFAULT_ADMIN_ROLE`.
   - Verifies admin role on-chain before exiting.

2. [ ] **AssetNFT** — `scripts/deploy-asset-nft.ts`
   - Reads `PermissionManager.proxy` from deployments (or `PERMISSION_MANAGER_PROXY`).
   - Sets name / symbol / contractURI / trustedForwarder.
   - ⚠️ The `setBaseURI` call in step 4 of this script requires `URI_SETTER_ROLE` on
     the deployer. Grant it first (see §2), or accept the warning and run
     `set-base-uri.ts` afterward.

3. [ ] **FeeController** — `scripts/deploy-fee-controller.ts`
   - Needs `PERMISSION_MANAGER_PROXY` (or from JSON) and `TREASURY`.

4. [ ] **PackMachine stack** — `scripts/deploy-pack-machine.ts` (8 internal steps, 6 contracts)
   - Required env vars: `PAYMENT_TOKEN`, `FINANCE_WALLET`, `VRF_COORDINATOR`,
     `VRF_SUBSCRIPTION_ID`, `VRF_KEY_HASH`.
   - Reads `PermissionManager.proxy` + `AssetNFT.proxy` from deployments JSON.
   - Deploys: PackVRFRouter, PackMachine implementation (EIP-1167 clone target),
     PackMachineFactory, PackRegistry, PackTierRegistry, BuybackPool.
   - Auto-wires all six and runs a full on-chain verification block.
   - Prints remaining manual steps at the end.

5. [ ] **AssetLendingPool** — `scripts/deploy-asset-lending-pool.ts`
   - Deploys `AssetLendingPoolConfig` + `AssetLendingPool`.
   - **Auto-grants `STATE_MANAGER_ROLE`** to the pool proxy on PermissionManager.
   - LTV / lender-share / default windows configurable via:
     `LENDING_POOL_LTV_BPS` (default 5000), `LENDING_POOL_LENDER_SHARE_BPS`
     (default 8000), `LENDING_POOL_ACQUISITION_WINDOW` (default 86400),
     `LENDING_POOL_AUCTION_WINDOW` (default 604800).
   - ⚠️ If deployed **before** step 4, it writes a placeholder factory address
     (`0x…0001`) — run `scripts/set-pack-machine-factory.ts` afterward.

6. [ ] **NettyWorthMarketplace** — `scripts/deploy-marketplace.ts`
   - Needs FeeController + AssetLendingPool + AssetNFT.
   - Auto-calls `pool.setMarketplace(marketplace)` and `assetNFT.setFeeController(...)`
     (skip with `SKIP_NFT_WIRING=true`).

7. [ ] **P2PTradeEscrow** — `scripts/deploy-p2p-trade-escrow.ts`
   - Fully standalone (Ownable2Step, no PermissionManager).
   - `OWNER` env var optional (defaults to deployer).

8. [ ] **PromoCodeRegistry** — `scripts/deploy-promo-code-registry.ts` *(optional)*
   - Reads PackMachineFactory + BuybackPool from JSON.
   - Extra manual wiring required (see §2 below).

---

## 2. Post-deploy wiring & role grants

The pack-machine script auto-wires factory ↔ registries ↔ buyback pool and verifies them.
Everything else below is **manual**. Use `grant-role.ts` for role grants:

```
ROLE=<name> ACCOUNT=0x<addr> npx hardhat run scripts/grant-role.ts --network <network>
```

Valid role names: `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, `BURNER_ROLE`, `STATE_MANAGER_ROLE`,
`URI_SETTER_ROLE`, `PAUSER_ROLE`, `UPGRADER_ROLE`, `BLACKLIST_ROLE`, `PACK_OPERATOR_ROLE`,
`BUYBACK_POOL_ROLE`, `MARKETPLACE_ROLE`.

- [ ] **`URI_SETTER_ROLE`** → deployer (needed before or immediately after step 2; required
      for `setBaseURI`).
- [ ] **`MINTER_ROLE` / `BURNER_ROLE`** → minter/backend account(s) for AssetNFT.
- [ ] **`BLACKLIST_ROLE`**, **`PAUSER_ROLE`**, **`UPGRADER_ROLE`** → ops/multisig as needed.
- [ ] **`PACK_OPERATOR_ROLE`** → backend account that signs `OpenPack` EIP-712 messages
      and manages pack configuration.
- [ ] **`MARKETPLACE_ROLE`** → **marketplace proxy address** (not just the admin). The
      deploy script only reports whether the *admin* holds it. Grant the proxy explicitly:
      `ROLE=MARKETPLACE_ROLE ACCOUNT=<marketplace proxy>`.
- [ ] **`STATE_MANAGER_ROLE`** → confirmed auto-granted to the lending pool proxy (§1 step 5).
- [ ] **Marketplace ↔ lending pool link** — auto-set by `deploy-marketplace.ts`; if it was
      skipped, run `scripts/set-marketplace-lending-pool.ts` with
      `MARKETPLACE_PROXY` + `LENDING_POOL`.
- [ ] **Lending default-recycling path** (if defaulted collateral should recycle into packs):
      - `targetClone.setAuthorizedDepositor(lendingPoolProxy, true)`
      - `pool.setDefaultPackMachine(<clone>)`
      - `pool.setPackMachineFactory(<factory proxy>)`
- [ ] **PromoCodeRegistry wiring** (if deployed):
      `registry.setPackMachineFactory`, `registry.setBuybackPool`,
      `factory.setPromoCodeRegistry`, `buybackPool.setPromoCodeRegistry`, and deploy a
      promo-aware PackMachine implementation.
- [ ] Confirm factory wiring on-chain (verified by `deploy-pack-machine.ts`, but double-check):
  - `factory.packVRFRouter`, `factory.buybackPool`, `factory.packRegistry`,
    `factory.packTierRegistry`
  - `packRegistry.factory`, `packTierRegistry.factory`

---

## 3. Chainlink VRF setup

Pack opens will revert until this is done.

- [ ] Add the **PackVRFRouter proxy** as a consumer on the VRF subscription
      (Chainlink dashboard or coordinator contract):
      subscription `<VRF_SUBSCRIPTION_ID>` → add consumer `<PackVRFRouter proxy>`.
- [ ] Confirm the subscription is funded with LINK / native tokens.
- [ ] Adjust VRF params if needed:
  - `scripts/set-callback-gas-limit.ts`
  - `scripts/set-key-hash.ts`

---

## 4. Pack machine go-live (per clone)

Repeat for each new PackMachine clone.

- [ ] Create the clone (requires `PACK_OPERATOR_ROLE`):
  ```
  npx hardhat run scripts/create-pack-machine.ts --network <network>
  ```
- [ ] Register clone with VRF router: `packVRFRouter.setAuthorizedPackMachine(clone, true)`.
- [ ] Register clone with BuybackPool: `buybackPool.registerPackMachine(clone, true)`.
- [ ] Set per-pack tier FMV bounds (**required before any deposit**; deposits revert without it):
  ```
  packRegistry.setPackTierFmvBounds(clone, packId, [minFmv×6], [maxFmv×6])
  ```
  Use `scripts/fmv-bounds.example.json` as a template.
- [ ] Set buyback allocation per pack:
  `packRegistry.setPackBuybackAllocation(clone, packId, <bps>)` (e.g. 2000 = 20%).
- [ ] Authorize depositor accounts: `scripts/set-authorized-depositor.ts`.
- [ ] Deposit NFT inventory and configure tiers:
  ```
  npx hardhat run scripts/setup-pack-machine.ts --network <network>
  ```
  Reference: `scripts/deposit.example.json`.
- [ ] Set appraisals (required if lending is enabled):
  ```
  npx hardhat run scripts/batch-set-appraisals.ts --network <network>
  ```
  Reference: `scripts/appraisals.json` / `scripts/appraisals.example.json`.

---

## 5. Verification & records

- [ ] **Storage layout check**: `pnpm verify:slots` — confirms ERC-7201 slots are correct.
- [ ] **Source verification**: `pnpm verify:tenderly --network <network>`
  - Requires Foundry installed.
  - Artifacts must match: solc 0.8.28, optimizer 200 runs, `viaIR: true`, `cancun`.
  - Set `TENDERLY_ACCOUNT`, `TENDERLY_PROJECT`, `TENDERLY_ACCESS_KEY`.
  - ⚠️ Most `CONTRACT_META` entries in `scripts/verify-tenderly.ts` are **commented out**
    (only `BuybackPool` + `NettyWorthMarketplace` active) — uncomment the contracts to
    verify before running.
- [ ] **Deployments JSON audit**: diff `deployments/<network>.json` — every deployed
      contract should have `proxy`, `implementation`, wiring fields, and a recent
      `deployedAt`.
- [ ] **Read-only health checks**:
  - `scripts/check-lending-pool-config.ts`
  - `scripts/check-buyback-registration.ts`
  - `scripts/check-pack-buyback.ts`
  - `scripts/debug-token-eligibility.ts`
- [ ] **Smoke test end-to-end** on the live network:
  - Mint an AssetNFT.
  - Open a pack (VRF request → fulfillment callback).
  - Open a small collateralized loan (if lending is live).
- [ ] Commit the updated `deployments/<network>.json` to version control.

---

## Notes

- **No `deploy` npm script** — deploys are always
  `npx hardhat run scripts/<file>.ts --network <network>`.
- **Always dry-run first** on the matching fork network (`--network forkBase`, etc.)
  before spending real gas.
- **AssetLendingPool** and **P2PTradeEscrow** use `Ownable2StepUpgradeable` instead
  of PermissionConsumer. Their only tie to PermissionManager is the external
  `STATE_MANAGER_ROLE` grant (lending pool) — there is none for P2PTradeEscrow.
- `scripts/lib/deployments.ts` — shared helpers: `readDeployments`, `saveDeployment`
  (atomic write via temp file), `waitForCode` (closes read-after-write gap on
  load-balanced RPCs, 60 s timeout).
