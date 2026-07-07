# PackMachine Admin — Frontend Integration Reference

> Machine-readable reference for building admin UI / scripts against the
> PackMachine subsystem. Covers pack configuration, FMV bounds, card deposit,
> and eligibility management.

---

## Contracts involved

| Name | Role | Address source |
|---|---|---|
| `PackMachine` clone | Holds custody, prize pools | `deployments/<network>.json → PackMachines[i].address` |
| `PackRegistry` | Pack definitions, FMV bounds | `deployments/<network>.json → PackRegistry.proxy` |
| `PackMachineFactory` | Reads `paymentToken()`, `isPackMachine()` | `deployments/<network>.json → PackMachineFactory.proxy` |
| `AssetNFT` | ERC-721 for cards | `deployments/<network>.json → AssetNFT.proxy` |

All ABIs are compiled artifacts under `artifacts/contracts/`.

---

## Access control

Every write function below requires the caller to hold **`PACK_OPERATOR_ROLE`**
in `PermissionManager`. The UI should check this before rendering admin
controls:

```ts
// Roles.PACK_OPERATOR_ROLE constant
const PACK_OPERATOR_ROLE =
  "0x" + /* hash of "PACK_OPERATOR_ROLE" — read from Roles.sol */ "...";

const hasRole = await permissionManager.read.hasProtocolRole([
  PACK_OPERATOR_ROLE,
  walletAddress,
]);
```

---

## Tier index reference

```ts
const TIERS = ["Base", "Common", "Uncommon", "Rare", "Ultra Rare", "Grail"];
// index:       0        1         2           3       4             5
```

Six tiers, `uint8` values 0–5. No Solidity enum — pass raw numbers.

---

## 1. Pack state — read functions

### Get all packs for a machine

```ts
const info = await clone.read.getMachineInfo();
// info.packCount   → number of packs (always ≥ 1; pack 0 is auto-created)
// info.buybackPool → address
// info.effectivePrizePoolSize → bigint (decremented on VRF request, not fulfillment)
// info.factory     → address

// Iterate packs:
for (let i = 0; i < info.packCount; i++) {
  const pack = await clone.read.getPack([BigInt(i)]);
  // pack.pricePerPack         bigint  (payment-token base units)
  // pack.cardsPerPack         number
  // pack.startTime            bigint  (Unix timestamp; 0 = no restriction)
  // pack.buybackAllocationBps number  (0–10000)
  // pack.active               bool
  // pack.finished             bool    (irreversible)
  // pack.tierWeights          uint32[6]  (sum = 10000)
}
```

### Get available cards per pack

```ts
const available = await clone.read.getPackAvailable([BigInt(packId)]);
// bigint — how many cards are in this pack's pool right now
```

### Get FMV bounds for a pack

```ts
const [minFmv, maxFmv] = await packRegistry.read.getPackTierFmvBounds([
  cloneAddress,
  BigInt(packId),
]);
// minFmv: bigint[6], maxFmv: bigint[6] — in payment-token base units
// maxFmv[tier] === 0n means that tier is disabled (deposits into it revert)
```

### Get payment token decimals (needed to display/scale FMV values)

```ts
const factoryAddress = (await clone.read.getMachineInfo()).factory;
const factory = getContract({ address: factoryAddress, abi: PackMachineFactoryAbi, client });
const paymentTokenAddress = await factory.read.paymentToken();

const decimals = await publicClient.readContract({
  address: paymentTokenAddress,
  abi: [{ name: "decimals", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] }],
  functionName: "decimals",
});
const scale = 10n ** BigInt(decimals); // multiply whole-token values by this
```

---

## 2. Create / configure a pack

### Pack 0 is auto-created

`PackMachineFactory.createPackMachine` bootstraps pack 0 automatically with
weights `[7040, 2500, 400, 50, 9, 1]`, `active = false`, and zero price. Do
not call `addPack` for pack 0 — only configure it.

### `addPack` — create a new pack

```ts
// PackRegistry
const hash = await packRegistry.write.addPack([
  cloneAddress,       // address machine
  pricePerPack,       // bigint — payment-token base units (e.g. USDC: $5 = 5_000_000n)
  cardsPerPack,       // number  1–255
  startTime,          // bigint  Unix timestamp; 0n = no restriction
  buybackAllocationBps, // number 0–10000
  tierWeights,        // [number, number, number, number, number, number] — must sum to 10000
]);
const receipt = await publicClient.waitForTransactionReceipt({ hash });
```

Returns `packId` via event — parse it from the receipt:

```ts
import { parseEventLogs } from "viem";

const logs = parseEventLogs({
  abi: PackRegistryAbi,
  eventName: "PackAdded",
  logs: receipt.logs,
});
const newPackId = logs[0].args.packId; // bigint
```

**Input validation (run before the call):**

```ts
if (cardsPerPack === 0) throw "cardsPerPack must be ≥ 1";
if (buybackAllocationBps > 10000) throw "buybackAllocationBps max 10000";
if (tierWeights.reduce((a, b) => a + b, 0) !== 10000) throw "tierWeights must sum to 10000";
if (tierWeights.length !== 6) throw "tierWeights must have 6 elements";
```

### Pack config setters (all on `PackRegistry`, all need `PACK_OPERATOR_ROLE`)

```ts
// Update price
await packRegistry.write.setPackPrice([cloneAddress, BigInt(packId), newPrice]);

// Update tier weights (must sum to 10000)
await packRegistry.write.setPackTierWeights([cloneAddress, BigInt(packId), newWeights]);

// Update buyback split
await packRegistry.write.setPackBuybackAllocation([cloneAddress, BigInt(packId), bps]);

// Set start time (0 = no restriction)
await packRegistry.write.setPackStartTime([cloneAddress, BigInt(packId), BigInt(startTime)]);

// Activate / deactivate (activating with maxCards != 0 requires pool to be full)
await packRegistry.write.setPackActive([cloneAddress, BigInt(packId), true]);

// IRREVERSIBLE — permanently stops the pack
await packRegistry.write.stopPack([cloneAddress, BigInt(packId)]);
```

---

## 3. Set FMV bounds per tier per pack

Must be called **before** any deposit into that (pack, tier) pair, or deposit reverts.

```ts
// PackRegistry
const hash = await packRegistry.write.setPackTierFmvBounds([
  cloneAddress,       // address machine
  BigInt(packId),     // uint256 packId
  minFmv,             // [bigint × 6] — inclusive lower bound per tier, base units
  maxFmv,             // [bigint × 6] — inclusive upper bound per tier, base units
]);
```

**Rules:**

- Pass `[0n, 0n, 0n, 0n, 0n, 0n]` for both arrays to clear all bounds (all tiers disabled).
- `(0n, 0n)` for a tier index = that tier is disabled. Depositing into it reverts `PackMachine__TierFmvUnset`.
- `minFmv[i] <= maxFmv[i]` required when `maxFmv[i] !== 0n`.
- Values are in payment-token base units. To convert from whole-token UI input: `BigInt(Math.round(wholeTokenValue)) * scale`.

**Input validation:**

```ts
for (let i = 0; i < 6; i++) {
  if (maxFmv[i] !== 0n && minFmv[i] > maxFmv[i]) {
    throw `tier ${i}: minFmv (${minFmv[i]}) > maxFmv (${maxFmv[i]})`;
  }
}
```

---

## 4. Deposit new cards

### Prerequisites (check before calling)

1. FMV bounds set for every (packId, tier) pair used in this deposit — otherwise reverts.
2. `AssetNFT.setApprovalForAll(cloneAddress, true)` called by the token owner.
3. Each token's appraisal value (from `AssetNFT.getAppraisalValue(tokenId)`) must fall within the bounds.

```ts
// Check / set approval
const isApproved = await assetNFT.read.isApprovedForAll([tokensOwner, cloneAddress]);
if (!isApproved) {
  const hash = await assetNFT.write.setApprovalForAll([cloneAddress, true]);
  await publicClient.waitForTransactionReceipt({ hash });
}
```

### Function signature

```ts
// PackMachine clone
await clone.write.deposit([
  tokenIds,    // bigint[]   — tokens to deposit (max 50 per call)
  packCounts,  // bigint[]   — parallel to tokenIds: how many (pack,tier) assignments per token
  packIds,     // bigint[]   — flat list of pack IDs
  tiers,       // number[]   — flat list of tier indices (parallel to packIds)
  tokensOwner, // address    — address currently holding the NFTs
]);
```

### Flat-encoding — how to build the arrays

Each token can be assigned to multiple packs in a single deposit call. For token `tokenIds[i]`, `packCounts[i]` consecutive entries in `packIds` / `tiers` define its assignments.

```ts
// Example: token 1 → pack0 (Rare), pack1 (Common)
//          token 2 → pack0 (Base)
//          token 3 → pack0 (Uncommon), pack1 (Base), pack2 (Common)

const tokenIds   = [1n, 2n, 3n];
const packCounts = [2n, 1n, 3n];
const packIds    = [0n, 1n,  0n,  0n, 1n, 2n];
const tiers      = [3,  1,   0,   2,  0,  1 ];
//                  ^-- token 1  ^-- t2 ^-- token 3

await clone.write.deposit([tokenIds, packCounts, packIds, tiers, tokensOwner]);
```

**Helper to build arrays from a structured input:**

```ts
interface DepositRecord {
  tokenId: bigint;
  assignments: { packId: bigint; tier: number }[];
}

function buildDepositArrays(records: DepositRecord[]) {
  const tokenIds: bigint[]  = [];
  const packCounts: bigint[] = [];
  const packIds: bigint[]   = [];
  const tiers: number[]     = [];

  for (const r of records) {
    tokenIds.push(r.tokenId);
    packCounts.push(BigInt(r.assignments.length));
    for (const a of r.assignments) {
      packIds.push(a.packId);
      tiers.push(a.tier);
    }
  }
  return { tokenIds, packCounts, packIds, tiers };
}
```

**Batch limit:** max **50 tokens per call**. Split large sets:

```ts
const BATCH_SIZE = 50;
for (let i = 0; i < records.length; i += BATCH_SIZE) {
  const batch = records.slice(i, i + BATCH_SIZE);
  const arrays = buildDepositArrays(batch);
  const hash = await clone.write.deposit([
    arrays.tokenIds, arrays.packCounts, arrays.packIds, arrays.tiers, tokensOwner,
  ]);
  await publicClient.waitForTransactionReceipt({ hash });
}
```

**Input validation:**

```ts
if (records.length > 50) /* split into batches */;

for (const r of records) {
  const packsSeen = new Set<bigint>();
  for (const a of r.assignments) {
    if (a.tier >= 6) throw `tokenId ${r.tokenId}: invalid tier ${a.tier}`;
    if (packsSeen.has(a.packId)) throw `tokenId ${r.tokenId}: duplicate packId ${a.packId}`;
    packsSeen.add(a.packId);
  }
}
```

---

## 5. Set up already-deposited cards (`setPackEligibility`)

Use this to add a new pack assignment, change a tier, or remove a pack from cards already held by the clone.

```ts
// PackMachine clone
await clone.write.setPackEligibility([
  BigInt(packId),  // pack to add/remove
  tokenIds,        // bigint[] — must all be inCustody (held by clone)
  tiers,           // number[] — tier per token; ignored when eligible = false
  eligible,        // bool — true = add/update, false = remove
]);
```

**Semantics:**

| `eligible` | Effect |
|---|---|
| `true` | Adds `packId` to the token's pool with the given tier. If already eligible for this pack, re-slots to the new tier (tier change in-place). |
| `false` | Removes `packId` from the token's eligibility. Idempotent — silent no-op if not eligible. |

- Max **50 tokens per call** (same `MAX_BATCH` cap).
- Add path runs full FMV validation — bounds must be set for the (pack, tier) pair.

**Typical flow — enroll existing cards into a newly added pack:**

```ts
// 1. Create the new pack
const addHash = await packRegistry.write.addPack([cloneAddress, price, cardsPerPack, startTime, bps, weights]);
const addReceipt = await publicClient.waitForTransactionReceipt({ hash: addHash });
const newPackId = parseEventLogs({ abi: PackRegistryAbi, eventName: "PackAdded", logs: addReceipt.logs })[0].args.packId;

// 2. Set FMV bounds for the new pack
await packRegistry.write.setPackTierFmvBounds([cloneAddress, newPackId, minFmv, maxFmv]);

// 3. Assign already-deposited cards to the new pack (batch if > 50)
await clone.write.setPackEligibility([newPackId, tokenIds, tiers, true]);

// 4. Activate the pack
await packRegistry.write.setPackActive([cloneAddress, newPackId, true]);
```

> `setPackEligibility` is **not** wrapped by any existing TypeScript script.
> Call it directly via viem `writeContract`.

---

## 6. Error handling

Decode custom errors from reverted transactions:

```ts
import { decodeErrorResult } from "viem";

function decodePackMachineError(err: unknown): string {
  try {
    const data = (err as { cause?: { data?: `0x${string}` } })?.cause?.data;
    if (!data) return String(err);
    const decoded = decodeErrorResult({ abi: PackMachineAbi, data });
    switch (decoded.errorName) {
      case "PackMachine__TierFmvUnset":
        return `Tier FMV bounds not set for pack ${decoded.args[0]}, tier ${decoded.args[1]}. Call setPackTierFmvBounds first.`;
      case "PackMachine__FmvOutOfRange":
        return `Token ${decoded.args[0]} appraisal ${decoded.args[3]} is outside bounds for pack ${decoded.args[1]}, tier ${decoded.args[2]}.`;
      case "PackMachine__InvalidPackRef":
        return `Pack ID ${decoded.args[0]} does not exist or is duplicated for this token.`;
      case "PackMachine__InvalidTier":
        return `Tier ${decoded.args[0]} is invalid — must be 0–5.`;
      case "PackMachine__BatchTooLarge":
        return `Batch too large (${decoded.args[0]}); max is ${decoded.args[1]} tokens per call.`;
      case "PackMachine__TokenNotInCustody":
        return `Token ${decoded.args[0]} is not held by this PackMachine clone.`;
      case "PackMachine__ArrayLengthMismatch":
        return "Array length mismatch — check that packCounts sums match packIds/tiers length.";
      default:
        return `PackMachine error: ${decoded.errorName}`;
    }
  } catch {
    return String(err);
  }
}

function decodePackRegistryError(err: unknown): string {
  try {
    const data = (err as { cause?: { data?: `0x${string}` } })?.cause?.data;
    if (!data) return String(err);
    const decoded = decodeErrorResult({ abi: PackRegistryAbi, data });
    switch (decoded.errorName) {
      case "PackRegistry__InvalidPackId":      return "Pack ID does not exist.";
      case "PackRegistry__PackFinished":       return "Pack is permanently stopped.";
      case "PackRegistry__InvalidWeights":     return "Tier weights must sum to exactly 10000.";
      case "PackRegistry__InvalidFmvBounds":   return `FMV bounds invalid at tier index ${decoded.args[0]}: min > max.`;
      case "PackRegistry__InvalidBps":         return "Basis points value must be 0–10000.";
      case "PackRegistry__InvalidCardsPerPack":return "cardsPerPack must be ≥ 1.";
      case "PackRegistry__MaxCardsNotReached": return "Pack pool not full yet — deposit more cards or set maxCards = 0.";
      case "PackRegistry__TooManyPacks":       return "Machine already has 256 packs.";
      default:                                  return `PackRegistry error: ${decoded.errorName}`;
    }
  } catch {
    return String(err);
  }
}
```

---

## 7. Mandatory call ordering

```text
addPack  (or use auto-created pack 0)
    ↓
setPackTierFmvBounds  ← required for every tier index you will deposit into
    ↓
deposit  (new cards)   OR   setPackEligibility  (already-deposited cards)
    ↓
setPackActive(true)   ← only after cards are in the pool
```

Any attempt to deposit before setting FMV bounds reverts `PackMachine__TierFmvUnset`.
Activating before the pool has cards works when `maxCards = 0` (no minimum); if `maxCards != 0` the activate call itself reverts `PackRegistry__MaxCardsNotReached`.

---

## 8. Complete admin flow example (viem)

```ts
import { getContract, parseEventLogs } from "viem";

// --- Contracts ---
const clone       = getContract({ address: cloneAddress,       abi: PackMachineAbi,       client: walletClient });
const packReg     = getContract({ address: packRegistryAddress, abi: PackRegistryAbi,       client: walletClient });
const assetNFT    = getContract({ address: assetNFTAddress,     abi: AssetNFTAbi,           client: walletClient });

// --- 1. Read payment token scale ---
const factoryAddress = (await clone.read.getMachineInfo()).factory;
const paymentToken   = await getContract({ address: factoryAddress, abi: PackMachineFactoryAbi, client }).read.paymentToken();
const decimals       = await publicClient.readContract({ address: paymentToken, abi: erc20DecimalsAbi, functionName: "decimals" });
const scale          = 10n ** BigInt(decimals);

// --- 2. Create a new pack ---
const addHash = await packReg.write.addPack([
  cloneAddress, 5n * scale, 5, 0n, 8000,
  [7040, 2500, 400, 50, 9, 1],
]);
const addReceipt = await publicClient.waitForTransactionReceipt({ hash: addHash });
const newPackId  = parseEventLogs({ abi: PackRegistryAbi, eventName: "PackAdded", logs: addReceipt.logs })[0].args.packId;

// --- 3. Set FMV bounds (whole-token values × scale) ---
await packReg.write.setPackTierFmvBounds([
  cloneAddress, newPackId,
  [0n, 100n * scale, 500n * scale, 2000n * scale, 10000n * scale, 50000n * scale],
  [99n * scale, 499n * scale, 1999n * scale, 9999n * scale, 49999n * scale, 999999n * scale],
]);

// --- 4. Approve clone to pull NFTs ---
const isApproved = await assetNFT.read.isApprovedForAll([tokensOwner, cloneAddress]);
if (!isApproved) await publicClient.waitForTransactionReceipt({ hash: await assetNFT.write.setApprovalForAll([cloneAddress, true]) });

// --- 5. Deposit cards (batch ≤ 50) ---
const records: DepositRecord[] = [
  { tokenId: 1n, assignments: [{ packId: newPackId, tier: 3 }] },
  { tokenId: 2n, assignments: [{ packId: newPackId, tier: 1 }] },
];
const { tokenIds, packCounts, packIds, tiers } = buildDepositArrays(records);
await publicClient.waitForTransactionReceipt({
  hash: await clone.write.deposit([tokenIds, packCounts, packIds, tiers, tokensOwner]),
});

// --- 6. Activate the pack ---
await publicClient.waitForTransactionReceipt({
  hash: await packReg.write.setPackActive([cloneAddress, newPackId, true]),
});

// --- 7. Verify ---
const pack      = await clone.read.getPack([newPackId]);
const available = await clone.read.getPackAvailable([newPackId]);
console.log("Pack active:", pack.active, "| Cards available:", available);
```
