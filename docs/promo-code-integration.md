# PromoCodeRegistry — Frontend & Admin Integration Reference

> Machine-readable reference for building admin UI / scripts and frontend flows
> against the `PromoCodeRegistry` contract. Covers code creation, allowlist
> management, discount previews, and how to pass a promo code through the pack
> and buyback entry points.

---

## Contracts involved

| Name | Role | Address source |
|---|---|---|
| `PromoCodeRegistry` proxy | Registry, allowlists, redemption state | `deployments/<network>.json → PromoCodeRegistry.proxy` |
| `PackMachineFactory` proxy | Identifies registered PackMachine clones; exposes `promoCodeRegistry()` getter | `deployments/<network>.json → PackMachineFactory.proxy` |
| `BuybackPool` proxy | Calls `redeemBuyback`; holds `promoCodeRegistry` reference | `deployments/<network>.json → BuybackPool.proxy` |
| `PackMachine` clone | Calls `redeemDiscount`/`refundDiscount` during `openPack*` flows | `deployments/<network>.json → PackMachines[i].address` |

All ABIs are compiled artifacts under `artifacts/contracts/`.

---

## 1. Two code kinds

| Kind | `PromoKind` value | Effect | Redeemed by |
|---|---|---|---|
| **Discount** | `0` | Reduces the pack price before USDC pull | PackMachine clone (inside `openPack*`) |
| **Buyback** | `1` | Replaces the BuybackPool payout rate (default 80%) with a higher rate | BuybackPool (inside `buyback(tokenId, codeId)`) |

### Off-chain code ID model

`codeId = keccak256(bytes(codeString))`, computed **off-chain**. The plaintext string never touches the chain and the hash is **not** a secret — security rests entirely on `active` / `expiry` / `maxRedemptions` / `restricted` allowlist / `oncePerUser` controls, plus the EIP-712 operator signature that binds `codeId` to every `openPack*` call.

The backend is responsible for storing the human-readable string ↔ `codeId` mapping and all code parameters.

---

## 2. Access control

| Role | Constant | Functions |
|---|---|---|
| `PACK_OPERATOR_ROLE` | `keccak256("PACK_OPERATOR_ROLE")` | `createCode`, `setActive`, `setExpiry`, `setMaxRedemptions`, `addToAllowlist`, `removeFromAllowlist`, `setPromoCodeRegistry` on BuybackPool |
| `DEFAULT_ADMIN_ROLE` | `bytes32(0)` | `setPackMachineFactory`, `setBuybackPool` (wiring), `proposePermissionManager` |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` | `pause`, `unpause` |
| `UPGRADER_ROLE` | `keccak256("UPGRADER_ROLE")` | UUPS `upgradeToAndCall` |
| *(no role)* | — | `redeemDiscount`, `refundDiscount`, `redeemBuyback` — caller-identity gated (see § 8, § 9) |

Check role before rendering admin controls:

```ts
import { keccak256, toBytes } from "viem";

const PACK_OPERATOR_ROLE = keccak256(toBytes("PACK_OPERATOR_ROLE"));

const hasRole = await permissionManager.read.hasProtocolRole([
  PACK_OPERATOR_ROLE,
  walletAddress,
]);
```

---

## 3. Computing `codeId`

```ts
import { keccak256, toBytes } from "viem";

// Human-readable string → bytes32 id
const codeId = keccak256(toBytes("SAVE20"));
// → "0x..."  (32-byte hex string, use as-is for contract calls)

// Example: buyback boost code
const buybackCodeId = keccak256(toBytes("BOOST95"));
```

`codeId` is the only identifier on-chain. The backend must persist the mapping
`{ codeString: "SAVE20", codeId: "0x...", kind, bps, expiry, ... }`.

---

## 4. BPS reference

### Discount codes

| `bps` | Discount | Resulting price |
|---|---|---|
| `1000` | 10% | 90% of pack price |
| `1500` | 15% | 85% of pack price |
| `2000` | 20% | 80% of pack price |
| `2500` | 25% | 75% of pack price |

### Buyback codes

| `bps` | Payout rate | vs. default 80% |
|---|---|---|
| `9000` | 90% | +10 pp |
| `9500` | 95% | +15 pp |
| `9800` | 98% | +18 pp |

Any other `bps` value reverts `PromoCodeRegistry__InvalidBps(kind, bps)` at `createCode` time.

---

## 5. Admin — create & manage codes

### 5.1 Create a code

```ts
await promoCodeRegistry.write.createCode([
  codeId,          // bytes32 — keccak256 of the code string, computed off-chain
  0,               // PromoKind.Discount = 0  |  PromoKind.Buyback = 1
  2000,            // uint16 bps — see § 4; only exact values 1000/1500/2000/2500 (Discount)
                   //             or 9000/9500/9800 (Buyback) are accepted
  1_753_920_000n,  // uint64 expiry — Unix timestamp; 0n = never expires
  500,             // uint32 maxRedemptions — total cap; 0 = uncapped
  false,           // bool restricted — false = anyone may redeem; true = allowlist enforced
  true,            // bool oncePerUser — each wallet may redeem at most once
  machineAddress,  // address machine — Discount only: zero address = global (any PackMachine);
                   //                  non-zero = only that clone may redeem this code.
                   //                  Ignored (stored as address(0)) for Buyback codes.
]);
// Emits: CodeCreated(codeId, kind, bps, expiry, maxRedemptions, restricted, oncePerUser, machine)
```

**Reverts:**
- `PromoCodeRegistry__CodeExists(codeId)` — `codeId` already registered.
- `PromoCodeRegistry__InvalidBps(kind, bps)` — bps value not in the allowed set.
- `PermissionConsumer__Unauthorized(caller, PACK_OPERATOR_ROLE)` — missing role.

A code starts with `active = true` and `redeemedCount = 0`. There is no `setBps` — to change the discount level, create a new `codeId`.

### 5.2 Activate / deactivate (kill switch)

```ts
await promoCodeRegistry.write.setActive([codeId, false]); // deactivate
await promoCodeRegistry.write.setActive([codeId, true]);  // reactivate
// Emits: CodeActiveSet(codeId, active)
```

Reverts `PromoCodeRegistry__CodeNotFound(codeId)` if the code was never created.

### 5.3 Update expiry

```ts
await promoCodeRegistry.write.setExpiry([
  codeId,
  1_756_512_000n, // new Unix expiry; 0n = remove expiry (never expires)
]);
// Emits: CodeExpirySet(codeId, expiry)
```

### 5.4 Update redemption cap

```ts
await promoCodeRegistry.write.setMaxRedemptions([
  codeId,
  1000, // 0 = uncapped; lowering below redeemedCount stops future redemptions immediately
]);
// Emits: CodeMaxRedemptionsSet(codeId, maxRedemptions)
```

---

## 6. Admin — allowlist management

Only relevant when `restricted = true`. Up to **50 addresses per call** (hard cap `MAX_BATCH`).

```ts
// Add addresses
await promoCodeRegistry.write.addToAllowlist([
  codeId,
  ["0xAbc...", "0xDef...", /* ... up to 50 */],
]);
// Emits per address: AllowlistUpdated(codeId, user, true)

// Remove addresses
await promoCodeRegistry.write.removeFromAllowlist([
  codeId,
  ["0xAbc..."],
]);
// Emits per address: AllowlistUpdated(codeId, user, false)
```

**Reverts:**
- `PromoCodeRegistry__BatchTooLarge(given, 50)` — more than 50 addresses.
- `PromoCodeRegistry__CodeNotFound(codeId)` — code does not exist.

The `restricted` flag is set at creation and cannot be changed after the fact — create a new code to change this property.

---

## 7. Frontend — read / preview before purchase

### 7.1 Check eligibility (non-reverting)

```ts
const eligible = await promoCodeRegistry.read.isEligible([codeId, userAddress]);
// Returns false (never throws) if: code does not exist, inactive, expired,
// cap reached, user not allowlisted (restricted code), user already redeemed (oncePerUser).
// Returns true only when all checks pass.
```

### 7.2 Preview discounted price

```ts
// Returns the post-discount price. Safe to call with bytes32(0) or any
// ineligible code — always returns `price` unchanged when the code can't apply.
const discountedPrice = await promoCodeRegistry.read.previewDiscount([
  codeId,       // bytes32(0) = no discount
  userAddress,
  packPrice,    // bigint — pack.pricePerPack in payment-token units (USDC, 6 decimals)
]);
// discountedPrice = packPrice - (packPrice * bps / 10_000)
```

This is required on the **Permit2 path**: the user's Permit2 signature must cover the exact post-discount amount. Compute `discountedPrice` here, then use it as `permit2Amount`.

### 7.3 Remaining redemptions

```ts
const remaining = await promoCodeRegistry.read.remainingRedemptions([codeId]);
// Returns type(uint256).max (i.e. 2n**256n - 1n) when uncapped (maxRedemptions == 0).
// Returns 0n when exhausted.
```

### 7.4 Per-user checks

```ts
const alreadyUsed   = await promoCodeRegistry.read.hasUserRedeemed([codeId, userAddress]);
const onAllowlist   = await promoCodeRegistry.read.isAllowlisted([codeId, userAddress]);
```

### 7.5 Full code record

```ts
const code = await promoCodeRegistry.read.getCode([codeId]);
// Returns PromoCode struct:
// {
//   kind: 0 | 1,          // PromoKind.Discount | PromoKind.Buyback
//   bps: number,           // discount/boost rate
//   expiry: bigint,        // 0n = never
//   maxRedemptions: number,// 0 = uncapped
//   redeemedCount: number,
//   restricted: boolean,
//   active: boolean,
//   oncePerUser: boolean,
//   exists: boolean,       // false → code was never created
//   machine: string,       // address; Discount scope (0x0 = global)
// }
```

---

## 8. Frontend — applying a Discount code at open

The PackMachine exposes **overloaded** entry points. Pass `bytes32(0)` or omit `codeId` entirely to use the codeless (first-open discount) path.

### 8.1 Direct USDC transfer

```ts
// Without discount code (uses first-open discount if enabled):
await packMachine.write.openPack([user, packId, operatorSignature]);

// With discount code:
await packMachine.write.openPack([user, packId, operatorSignature, codeId]);
```

`msg.sender` (the payer) must have approved the PackMachine for at least `discountedPrice` USDC before calling.

### 8.2 Permit2 (gasless relayer path)

```ts
// 1. Compute exact amount to sign
const discountedPrice = await promoCodeRegistry.read.previewDiscount([
  codeId, user, packPrice,
]);

// 2. User signs Permit2 authorization off-chain for `discountedPrice`
// 3. Relayer submits:
await packMachine.write.openPackWithPermit2([
  user,
  packId,
  permit2Nonce,
  permit2Deadline,
  permit2Signature,   // signed by `user` for `discountedPrice`
  operatorSignature,  // signed by PACK_OPERATOR_ROLE holder — must include codeId
  codeId,             // bytes32; bytes32(0) = no discount
]);
```

### EIP-712 operator signature

The backend must sign the `codeId` into the `OpenPack` struct. Typehash:

```
OpenPack(address user, uint256 packId, uint256 nonce, bytes32 codeId)
```

A signature generated for `codeId = bytes32(0)` cannot be reused with a different `codeId`, and vice versa. The nonce is per-user and per-machine.

### What happens on the all-cards-failed VRF path

If Chainlink VRF returns randomness but **all cards** fail (empty pool), the contract:
1. Refunds the full escrowed USDC to the user.
2. Calls `promoCodeRegistry.refundDiscount(codeId, user)` wrapped in `try/catch` — this reverses the consumption (decrements `redeemedCount`, clears `oncePerUser` flag) so the user can reuse their code.

The frontend does not need to handle this case explicitly — it surfaces as a successful transaction with a refund event. The promo code is restored automatically.

---

## 9. Frontend — applying a Buyback code

```ts
// Without boost (uses per-machine or global default rate, typically 80%):
await buybackPool.write.buyback([tokenId]);

// With buyback-boost code (replaces base rate with boosted bps):
await buybackPool.write.buyback([tokenId, codeId]);
```

`msg.sender` must own the `tokenId` and have approved `BuybackPool` to transfer it (ERC-721 `setApprovalForAll` or `approve`).

The boosted payout rate (`bps` from the code, e.g. `9500` = 95%) **replaces** the base rate outright — it is always higher, so there is no cap check. Payout = `appraisal × boostedBps / 10_000`.

Allowlist and `oncePerUser` checks use `msg.sender` (the token owner / seller) as the beneficiary.

---

## 10. Events reference

| Event | Indexed params | Other params | When emitted |
|---|---|---|---|
| `CodeCreated` | `codeId` | `kind, bps, expiry, maxRedemptions, restricted, oncePerUser, machine` | `createCode` |
| `CodeActiveSet` | `codeId` | `active` | `setActive` |
| `CodeExpirySet` | `codeId` | `expiry` | `setExpiry` |
| `CodeMaxRedemptionsSet` | `codeId` | `maxRedemptions` | `setMaxRedemptions` |
| `AllowlistUpdated` | `codeId`, `user` | `allowed` | `addToAllowlist` / `removeFromAllowlist` (once per address) |
| `CodeRedeemed` | `codeId`, `user` | `kind, bps, redeemedCount` | Successful `redeemDiscount` or `redeemBuyback` |
| `CodeRefunded` | `codeId`, `user` | `kind, redeemedCount` | Successful `refundDiscount` (all-cards-failed VRF path) |
| `PackMachineFactorySet` | `oldFactory`, `newFactory` | — | `setPackMachineFactory` |
| `BuybackPoolSet` | `oldPool`, `newPool` | — | `setBuybackPool` |

`CodeRedeemed` is the primary event for usage analytics. `redeemedCount` in the event is the **post-increment** value.

---

## 11. Errors reference

| Error | Thrown by | Meaning |
|---|---|---|
| `PromoCodeRegistry__ZeroAddress()` | `setPackMachineFactory`, `setBuybackPool` | Zero address passed to a wiring setter |
| `PromoCodeRegistry__CodeExists(codeId)` | `createCode` | A code with this `codeId` already exists |
| `PromoCodeRegistry__CodeNotFound(codeId)` | `setActive`, `setExpiry`, `setMaxRedemptions`, allowlist fns, `refundDiscount`, `_validateAndConsume` | `codeId` was never created |
| `PromoCodeRegistry__InvalidBps(kind, bps)` | `createCode` | `bps` is not in the allowed set for the given kind (§ 4) |
| `PromoCodeRegistry__WrongKind(codeId, expected, actual)` | `redeemDiscount`, `redeemBuyback` | Code exists but is a different kind (e.g. Buyback code passed to `redeemDiscount`) |
| `PromoCodeRegistry__Inactive(codeId)` | `redeemDiscount`, `redeemBuyback` | `active = false` |
| `PromoCodeRegistry__Expired(codeId)` | `redeemDiscount`, `redeemBuyback` | `block.timestamp > expiry` |
| `PromoCodeRegistry__LimitReached(codeId)` | `redeemDiscount`, `redeemBuyback` | `redeemedCount >= maxRedemptions` |
| `PromoCodeRegistry__NotAllowlisted(codeId, user)` | `redeemDiscount`, `redeemBuyback` | Code is `restricted` and the user is not on the allowlist |
| `PromoCodeRegistry__AlreadyRedeemed(codeId, user)` | `redeemDiscount`, `redeemBuyback` | Code is `oncePerUser` and the user has already redeemed |
| `PromoCodeRegistry__UnauthorizedRedeemer(caller)` | `redeemDiscount`, `refundDiscount`, `redeemBuyback` | Caller is not a registered PackMachine clone (discount) or not the configured BuybackPool (buyback) |
| `PromoCodeRegistry__WrongMachine(codeId, expected, actual)` | `redeemDiscount`, `refundDiscount` | Code is scoped to a specific machine and a different clone is calling |
| `PromoCodeRegistry__BatchTooLarge(given, max)` | `addToAllowlist`, `removeFromAllowlist` | More than 50 addresses in one call |
| `PromoCodeRegistry__NotConfigured()` | `redeemDiscount`, `refundDiscount` | `packMachineFactory` has not been set yet |

Additional errors from base contracts:
- `PermissionConsumer__Unauthorized(caller, role)` — caller lacks the required protocol role.
- `EnforcedPause()` (OZ Pausable) — contract is paused; affects all three redemption functions.

---

## 12. Deployment & wiring

The deploy script [scripts/deploy-promo-code-registry.ts](../scripts/deploy-promo-code-registry.ts) handles the full setup. Wiring is **bidirectional** — both sides must point at each other before redemptions work:

| Step | Call | Role required |
|---|---|---|
| 5a | `registry.setPackMachineFactory(factoryProxy)` | `DEFAULT_ADMIN_ROLE` |
| 5b | `registry.setBuybackPool(buybackPoolProxy)` | `DEFAULT_ADMIN_ROLE` |
| 6a | `factory.setPromoCodeRegistry(registryProxy)` | `DEFAULT_ADMIN_ROLE` |
| 6b | `buybackPool.setPromoCodeRegistry(registryProxy)` | `PACK_OPERATOR_ROLE` |

**Post-deploy manual step (always required):** deploy a new `PackMachine` implementation that includes the code-aware `openPack(user, packId, signature, codeId)` overloads, then call `factory.setImplementation(newImpl)` so **future clones** support promo codes. Existing clones deployed from the old implementation will not have these overloads.

To verify wiring on any network:

```ts
const registryFactory = await promoCodeRegistry.read.packMachineFactory();
const registryPool    = await promoCodeRegistry.read.buybackPool();
const factoryRegistry = await packMachineFactory.read.promoCodeRegistry();
const poolRegistry    = await buybackPool.read.getPromoCodeRegistry();

console.assert(registryFactory === factoryProxy);
console.assert(registryPool    === buybackPoolProxy);
console.assert(factoryRegistry === registryProxy);
console.assert(poolRegistry    === registryProxy);
```
