# NettyWorthMarketplace — Frontend Integration Guide

> **Stack:** wagmi `^2.14` · viem `^2.47` · Next.js `^16` · TypeScript  
> **Contract:** `NettyWorthMarketplace` (UUPS proxy, Solidity 0.8.28)  
> **Network:** Sepolia testnet (chainId `11155111`) — replace addresses for mainnet/Base when available.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Deployed Addresses](#2-deployed-addresses)
3. [EIP-712 Domain](#3-eip-712-domain)
4. [Message Types & EIP-712 Definitions](#4-message-types--eip-712-definitions)
5. [Prerequisite Approvals](#5-prerequisite-approvals)
6. [Flow A — Fixed-Price Sale](#6-flow-a--fixed-price-sale)
7. [Flow B — English Auction](#7-flow-b--english-auction)
8. [Pricing & Fee Preview](#8-pricing--fee-preview)
9. [Read / View Functions](#9-read--view-functions)
10. [Events](#10-events)
11. [Error Reference](#11-error-reference)
12. [ABI Reference](#12-abi-reference)

---

## 1. Overview

`NettyWorthMarketplace` is a no-escrow, ERC-20 only (USDC) marketplace for
`AssetNFT` tokens. It supports two trading flows:

| Flow | How it works |
|------|-------------|
| **Fixed-price sale** | Seller signs a `SignedListing` off-chain. Buyer calls `buyWithSignature` on-chain; funds are pulled from the buyer at that moment. |
| **English auction** | Seller signs a `SignedAuction` off-chain. Bidders sign `SignedBid` messages off-chain. Anyone relays the best bid to `commitBid` on-chain. Funds are pulled from the **winner** only at `settleAuction` — no upfront escrow. |

**Key design points:**

- **USDC only** — no native ETH accepted.
- **Not ERC-2771** — `msg.sender` is always the direct caller. There is no
  meta-transaction relayer. The buyer/bidder must send the transaction themselves.
- **Loan-aware** — if the listed NFT has an active `AssetLendingPool` loan,
  the minimum acceptable price is `principal + outstanding interest`. The loan
  is repaid atomically on sale; the buyer receives the NFT free of lien.
- **Off-chain orderbook** — listing and auction messages live off-chain
  (your backend). On-chain state is minimal (auction state only, and only
  after the first bid).
- **Paused state** — when the contract is paused, `buyWithSignature`,
  `commitBid`, and `settleAuction` all revert. Always check `paused()` before
  presenting UI actions.

---

## 2. Deployed Addresses

> Always use the **proxy** address in your frontend. Never interact with the
> implementation address directly.

### Sepolia (chainId 11155111)

| Contract | Address |
|----------|---------|
| **NettyWorthMarketplace** (proxy) | `0x845d2d9421d3f31a47f2458c2b4eb935baab587a` |
| AssetNFT (proxy) | `0x2f8BD4136edDEd19473448c24Da5C8aB9174b20C` |
| Payment Token (USDC, 6 dec) | `0x8545C5930F36aBE57ED4F5372f3fbB8b49E533DB` |
| FeeController (proxy) | `0xCd6CdA75B6Ce21f5B83125f414607b9B8Cd8c96F` |
| AssetLendingPool (proxy) | `0xe0e07bFD17E86876a721FE0276471BdE63936FB2` |
| PermissionManager (proxy) | `0x8aF208488d6198F4712FCA457dcE8259Ac141601` |
| Treasury | `0x0ed8BDFbb4803CD29d3C436AeaCdb48A9fa22A74` |

```ts
// constants/addresses.ts
export const ADDRESSES = {
  marketplace:   '0x845d2d9421d3f31a47f2458c2b4eb935baab587a',
  assetNFT:      '0x2f8BD4136edDEd19473448c24Da5C8aB9174b20C',
  usdc:          '0x8545C5930F36aBE57ED4F5372f3fbB8b49E533DB',
  feeController: '0xCd6CdA75B6Ce21f5B83125f414607b9B8Cd8c96F',
  lendingPool:   '0xe0e07bFD17E86876a721FE0276471BdE63936FB2',
} as const
```

---

## 3. EIP-712 Domain

All three message types (`SignedListing`, `SignedAuction`, `SignedBid`) are
signed under the same domain. The `verifyingContract` is the marketplace
**proxy** address.

```ts
// lib/marketplace-domain.ts
import { type TypedDataDomain } from 'viem'

export const marketplaceDomain = (chainId: number, proxyAddress: `0x${string}`): TypedDataDomain => ({
  name:              'NettyWorthMarketplace',
  version:           '1',
  chainId,
  verifyingContract: proxyAddress,
})
```

For Sepolia:

```ts
const domain = marketplaceDomain(11155111, '0x845d2d9421d3f31a47f2458c2b4eb935baab587a')
```

---

## 4. Message Types & EIP-712 Definitions

> **Critical:** The field order in each `types` array must match the
> on-chain typehash string exactly, or `ECDSA.recover` will return the wrong
> address and the transaction will revert with `Marketplace__InvalidSignature`.

### 4.1 `SignedListing` (fixed-price)

```ts
export const SIGNED_LISTING_TYPES = {
  SignedListing: [
    { name: 'seller',       type: 'address' },
    { name: 'collection',   type: 'address' },
    { name: 'tokenId',      type: 'uint256' },
    { name: 'paymentToken', type: 'address' },
    { name: 'price',        type: 'uint256' },
    { name: 'nonce',        type: 'uint256' },
    { name: 'expiry',       type: 'uint256' },
  ],
} as const

export type SignedListingMessage = {
  seller:       `0x${string}`  // must match the wallet signing
  collection:   `0x${string}`  // must be in allowedCollections (AssetNFT proxy)
  tokenId:      bigint
  paymentToken: `0x${string}`  // must be in allowedPaymentTokens (USDC)
  price:        bigint          // gross sale price in USDC smallest unit (6 decimals)
  nonce:        bigint          // pick a fresh random uint256; consumed on use
  expiry:       bigint          // unix timestamp in seconds; 0 is NOT allowed (would be expired)
}
```

**Field notes:**
- `price` is gross (buyer pays this amount). Fees + loan debt are deducted
  from this amount before the seller receives proceeds.
- `expiry`: set to e.g. `BigInt(Math.floor(Date.now() / 1000) + 7 * 86400)`
  for a 7-day listing.
- `nonce`: use a random large uint256 (e.g. `crypto.getRandomValues`). Nonces
  are shared across listing and bid cancellations for the same address — never
  reuse one.

### 4.2 `SignedAuction` (seller's auction parameters)

```ts
export const SIGNED_AUCTION_TYPES = {
  SignedAuction: [
    { name: 'seller',            type: 'address' },
    { name: 'collection',        type: 'address' },
    { name: 'tokenId',           type: 'uint256' },
    { name: 'paymentToken',      type: 'address' },
    { name: 'reservePrice',      type: 'uint256' },
    { name: 'minIncrement',      type: 'uint256' },
    { name: 'startTime',         type: 'uint256' },
    { name: 'endTime',           type: 'uint256' },
    { name: 'extensionWindow',   type: 'uint256' },
    { name: 'extensionDuration', type: 'uint256' },
    { name: 'nonce',             type: 'uint256' },
  ],
} as const

export type SignedAuctionMessage = {
  seller:            `0x${string}`
  collection:        `0x${string}`
  tokenId:           bigint
  paymentToken:      `0x${string}`
  reservePrice:      bigint   // minimum amount for the first bid
  minIncrement:      bigint   // each subsequent bid must exceed previous by at least this
  startTime:         bigint   // unix seconds; bids before this revert with NotStarted
  endTime:           bigint   // initial auction close time (unix seconds)
  extensionWindow:   bigint   // seconds before endTime that triggers an extension (0 = no extension)
  extensionDuration: bigint   // seconds added to endTime when a last-minute bid lands
  nonce:             bigint
}
```

**Field notes:**
- `extensionWindow` / `extensionDuration`: set e.g. `extensionWindow = 300n`
  (5 min) and `extensionDuration = 600n` (10 min) for anti-sniping.  
  Set both to `0n` to disable extensions.
- The seller's `nonce` is consumed the moment the auction is first committed
  on-chain (when the first `commitBid` call creates the `AuctionState`). To
  cancel before any bids land, call `cancelNonce(nonce)`.
- **`SignedAuction` has no `expiry` field.** Timing is controlled by
  `startTime` / `endTime`.

### 4.3 `SignedBid` (bidder's bid)

```ts
export const SIGNED_BID_TYPES = {
  SignedBid: [
    { name: 'auctionId', type: 'bytes32' },
    { name: 'bidder',    type: 'address' },
    { name: 'amount',    type: 'uint256' },
    { name: 'nonce',     type: 'uint256' },
    { name: 'expiry',    type: 'uint256' },
  ],
} as const

export type SignedBidMessage = {
  auctionId: `0x${string}`  // returned by hashAuction() view on the contract
  bidder:    `0x${string}`
  amount:    bigint          // bid amount in USDC smallest unit
  nonce:     bigint          // fresh per-bidder nonce
  expiry:    bigint          // unix seconds; use 0n for no expiry
}
```

**Field notes:**
- `auctionId` is the **full EIP-712 digest** of the auction, i.e.
  `hashTypedDataV4(keccak256(abi.encode(SIGNED_AUCTION_TYPEHASH, ...)))`.
  Retrieve it with the contract view `hashAuction(auction)` (see
  [§9](#9-read--view-functions)).
- `expiry = 0n` means the bid never expires on-chain (only the auction's
  `endTime` limits it). Non-zero expiry lets a bidder auto-invalidate a stale
  bid without calling `cancelNonce`.

---

## 5. Prerequisite Approvals

### 5.1 Buyer / winner — USDC approval

The marketplace calls `IERC20(paymentToken).safeTransferFrom(buyer, this, gross)`.
The buyer must have approved the marketplace for at least the gross price.

```tsx
// hooks/useApprovUSDC.ts
import { useWriteContract, useReadContract } from 'wagmi'
import { erc20Abi, maxUint256 } from 'viem'
import { ADDRESSES } from '@/constants/addresses'

export function useUsdcAllowance(owner: `0x${string}` | undefined) {
  return useReadContract({
    address: ADDRESSES.usdc,
    abi: erc20Abi,
    functionName: 'allowance',
    args: owner ? [owner, ADDRESSES.marketplace] : undefined,
    query: { enabled: !!owner },
  })
}

export function useApproveUsdc() {
  return useWriteContract()
}

// Usage in a component:
// const { writeContract } = useApproveUsdc()
// writeContract({
//   address: ADDRESSES.usdc,
//   abi: erc20Abi,
//   functionName: 'approve',
//   args: [ADDRESSES.marketplace, maxUint256],  // or exact amount
// })
```

> **Tip for auctions:** The bidder's USDC approval must stay ≥ their winning
> bid until `settleAuction` is called (possibly days later). Approving
> `maxUint256` once is the smoothest UX, but you may choose to approve the
> exact bid amount and warn users not to revoke it.

### 5.2 Seller — NFT approval (no-loan branch only)

When the NFT is **not** collateralised in `AssetLendingPool`, the marketplace
calls `IAssetNFT(collection).transferFrom(seller, buyer, tokenId)`. The seller
must have approved the marketplace.

```tsx
import { useWriteContract } from 'wagmi'
import { ADDRESSES } from '@/constants/addresses'

const ASSET_NFT_ABI = [
  {
    type: 'function',
    name: 'setApprovalForAll',
    inputs: [
      { name: 'operator', type: 'address' },
      { name: 'approved', type: 'bool' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'isApprovedForAll',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'operator', type: 'address' },
    ],
    outputs: [{ type: 'bool' }],
    stateMutability: 'view',
  },
] as const

// Grant approval
const { writeContract } = useWriteContract()
writeContract({
  address: ADDRESSES.assetNFT,
  abi: ASSET_NFT_ABI,
  functionName: 'setApprovalForAll',
  args: [ADDRESSES.marketplace, true],
})
```

> **Loan branch:** If the NFT has an active loan, it is held by
> `AssetLendingPool`, not the seller. The pool delivers the NFT directly to
> the buyer. **No seller NFT approval is needed in this case.**

### 5.3 Nonce management

- Nonces are **per-address, shared** across all listing and bid messages.
- A nonce is consumed (used) the first time it appears in a valid on-chain
  transaction, or when `cancelNonce` is called.
- To check if a nonce is already consumed: `isNonceUsed(address, nonce)`.
- **Best practice:** generate nonces with `crypto.getRandomValues`:

```ts
function freshNonce(): bigint {
  const buf = new Uint8Array(32)
  crypto.getRandomValues(buf)
  return BigInt('0x' + Array.from(buf).map(b => b.toString(16).padStart(2, '0')).join(''))
}
```

---

## 6. Flow A — Fixed-Price Sale

### 6.1 Seller: sign a listing (off-chain)

```tsx
// hooks/useSignListing.ts
import { useSignTypedData, useChainId } from 'wagmi'
import { SIGNED_LISTING_TYPES, type SignedListingMessage } from '@/lib/marketplace-types'
import { marketplaceDomain } from '@/lib/marketplace-domain'
import { ADDRESSES } from '@/constants/addresses'

export function useSignListing() {
  const chainId = useChainId()
  const { signTypedDataAsync } = useSignTypedData()

  const signListing = async (message: SignedListingMessage): Promise<`0x${string}`> => {
    return signTypedDataAsync({
      domain: marketplaceDomain(chainId, ADDRESSES.marketplace),
      types: SIGNED_LISTING_TYPES,
      primaryType: 'SignedListing',
      message,
    })
  }

  return { signListing }
}
```

**Example usage (seller creates a listing):**

```ts
const { signListing } = useSignListing()

const listing: SignedListingMessage = {
  seller:       sellerAddress,
  collection:   ADDRESSES.assetNFT,
  tokenId:      42n,
  paymentToken: ADDRESSES.usdc,
  price:        100_000_000n, // 100 USDC (6 decimals)
  nonce:        freshNonce(),
  expiry:       BigInt(Math.floor(Date.now() / 1000) + 7 * 86400), // 7 days
}

const signature = await signListing(listing)

// POST { listing, signature } to your backend / orderbook
```

### 6.2 Buyer: purchase a listing (on-chain)

```tsx
// hooks/useBuyWithSignature.ts
import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { MARKETPLACE_ABI } from '@/lib/marketplace-abi'
import { ADDRESSES } from '@/constants/addresses'
import type { SignedListingMessage } from '@/lib/marketplace-types'

export function useBuyWithSignature() {
  const { writeContract, data: hash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const buy = (listing: SignedListingMessage, sig: `0x${string}`) => {
    writeContract({
      address: ADDRESSES.marketplace,
      abi: MARKETPLACE_ABI,
      functionName: 'buyWithSignature',
      args: [listing, sig],
    })
  }

  return { buy, hash, isPending, isConfirming, isSuccess }
}
```

**Pre-flight checklist before calling `buyWithSignature`:**

1. `isNonceUsed(seller, listing.nonce)` → must be `false`.
2. `listing.expiry > Date.now() / 1000` → not expired.
3. USDC `allowance(buyer, marketplace)` ≥ `listing.price`.
4. (Optional) preview fees via fee/loan reads — see [§8](#8-pricing--fee-preview).

### 6.3 Seller: cancel a listing (on-chain)

```tsx
const { writeContract } = useWriteContract()

// Invalidate the listing's nonce so it can never be executed
writeContract({
  address: ADDRESSES.marketplace,
  abi: MARKETPLACE_ABI,
  functionName: 'cancelNonce',
  args: [listing.nonce],
})
```

---

## 7. Flow B — English Auction

### 7.1 Seller: sign an auction (off-chain)

```tsx
// hooks/useSignAuction.ts
import { useSignTypedData, useChainId } from 'wagmi'
import { SIGNED_AUCTION_TYPES, type SignedAuctionMessage } from '@/lib/marketplace-types'
import { marketplaceDomain } from '@/lib/marketplace-domain'
import { ADDRESSES } from '@/constants/addresses'

export function useSignAuction() {
  const chainId = useChainId()
  const { signTypedDataAsync } = useSignTypedData()

  const signAuction = async (message: SignedAuctionMessage): Promise<`0x${string}`> => {
    return signTypedDataAsync({
      domain: marketplaceDomain(chainId, ADDRESSES.marketplace),
      types: SIGNED_AUCTION_TYPES,
      primaryType: 'SignedAuction',
      message,
    })
  }

  return { signAuction }
}
```

**Example:**

```ts
const now = BigInt(Math.floor(Date.now() / 1000))

const auction: SignedAuctionMessage = {
  seller:            sellerAddress,
  collection:        ADDRESSES.assetNFT,
  tokenId:           42n,
  paymentToken:      ADDRESSES.usdc,
  reservePrice:      50_000_000n,   // 50 USDC minimum first bid
  minIncrement:      5_000_000n,    // each bid must beat previous by ≥ 5 USDC
  startTime:         now + 60n,     // starts in 1 min
  endTime:           now + 86400n,  // 24-hour auction
  extensionWindow:   300n,          // last 5 min triggers extension
  extensionDuration: 600n,          // extends by 10 min
  nonce:             freshNonce(),
}

const auctionSig = await signAuction(auction)
```

### 7.2 Retrieve `auctionId`

The `auctionId` is a `bytes32` — the full EIP-712 typed data hash of the
auction. Bidders must include the correct `auctionId` in their `SignedBid`.

```tsx
// hooks/useHashAuction.ts
import { useReadContract } from 'wagmi'
import { MARKETPLACE_ABI } from '@/lib/marketplace-abi'
import { ADDRESSES } from '@/constants/addresses'
import type { SignedAuctionMessage } from '@/lib/marketplace-types'

export function useHashAuction(auction: SignedAuctionMessage) {
  return useReadContract({
    address: ADDRESSES.marketplace,
    abi: MARKETPLACE_ABI,
    functionName: 'hashAuction',
    args: [auction],
  })
}
```

> You can also compute `auctionId` entirely client-side with viem's
> `hashTypedData`:
>
> ```ts
> import { hashTypedData } from 'viem'
> const auctionId = hashTypedData({
>   domain: marketplaceDomain(chainId, ADDRESSES.marketplace),
>   types: SIGNED_AUCTION_TYPES,
>   primaryType: 'SignedAuction',
>   message: auction,
> })
> ```
>
> Using the on-chain view is the safest way to confirm the value before storing
> it.

### 7.3 Bidder: sign a bid (off-chain)

```tsx
// hooks/useSignBid.ts
import { useSignTypedData, useChainId } from 'wagmi'
import { SIGNED_BID_TYPES, type SignedBidMessage } from '@/lib/marketplace-types'
import { marketplaceDomain } from '@/lib/marketplace-domain'
import { ADDRESSES } from '@/constants/addresses'

export function useSignBid() {
  const chainId = useChainId()
  const { signTypedDataAsync } = useSignTypedData()

  const signBid = async (message: SignedBidMessage): Promise<`0x${string}`> => {
    return signTypedDataAsync({
      domain: marketplaceDomain(chainId, ADDRESSES.marketplace),
      types: SIGNED_BID_TYPES,
      primaryType: 'SignedBid',
      message,
    })
  }

  return { signBid }
}
```

**Example:**

```ts
const bid: SignedBidMessage = {
  auctionId: auctionId,           // bytes32 from hashAuction()
  bidder:    bidderAddress,
  amount:    75_000_000n,          // 75 USDC
  nonce:     freshNonce(),
  expiry:    0n,                   // no expiry — valid until auction ends
}

const bidSig = await signBid(bid)
// POST { bid, bidSig } to your backend
```

### 7.4 Commit a bid on-chain

```tsx
// hooks/useCommitBid.ts
import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { MARKETPLACE_ABI } from '@/lib/marketplace-abi'
import { ADDRESSES } from '@/constants/addresses'
import type { SignedAuctionMessage, SignedBidMessage } from '@/lib/marketplace-types'

export function useCommitBid() {
  const { writeContract, data: hash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const commitBid = (
    auction: SignedAuctionMessage,
    auctionSig: `0x${string}`,
    bid: SignedBidMessage,
    bidSig: `0x${string}`,
  ) => {
    writeContract({
      address: ADDRESSES.marketplace,
      abi: MARKETPLACE_ABI,
      functionName: 'commitBid',
      args: [auction, auctionSig, bid, bidSig],
    })
  }

  return { commitBid, hash, isPending, isConfirming, isSuccess }
}
```

**Bid rules enforced on-chain:**

| Condition | Rule |
|-----------|------|
| First bid | `bid.amount ≥ auction.reservePrice` |
| Subsequent bid | `bid.amount ≥ state.highestBid + state.minIncrement` |
| Timing | `auction.startTime ≤ block.timestamp < endTime` |
| Last-minute extension | If bid lands within `extensionWindow` seconds of `endTime`, `endTime += extensionDuration` |

> **No funds move at this step.** The bidder only needs USDC approval ≥
> `bid.amount` to remain in place until `settleAuction` pulls the funds.

### 7.5 Settle an auction (on-chain)

Callable by **anyone** after `state.endTime` has passed. Pulls USDC from the
winner, handles fees/loan, delivers NFT to winner.

```tsx
// hooks/useSettleAuction.ts
import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { MARKETPLACE_ABI } from '@/lib/marketplace-abi'
import { ADDRESSES } from '@/constants/addresses'

export function useSettleAuction() {
  const { writeContract, data: hash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash })

  const settle = (auctionId: `0x${string}`) => {
    writeContract({
      address: ADDRESSES.marketplace,
      abi: MARKETPLACE_ABI,
      functionName: 'settleAuction',
      args: [auctionId],
    })
  }

  return { settle, hash, isPending, isConfirming, isSuccess }
}
```

### 7.6 Cancel an auction (on-chain)

Only the **seller** or an address holding `MARKETPLACE_ROLE` can cancel.
Once cancelled, `state.settled = true` and `settleAuction` will revert.

```tsx
const { writeContract } = useWriteContract()

writeContract({
  address: ADDRESSES.marketplace,
  abi: MARKETPLACE_ABI,
  functionName: 'cancelAuction',
  args: [auctionId],
})
```

---

## 8. Pricing & Fee Preview

Show users an accurate price breakdown before they sign or buy.

### 8.1 Fee math

```
gross = collectibleFee + royalty + loanDebt + sellerProceeds
```

| Component | Source | Default |
|-----------|--------|---------|
| `collectibleFee` | `FeeController.getCollectibleFee(gross)` | 5% of gross |
| `royalty` | ERC-2981 `royaltyInfo(tokenId, gross)`, capped | varies |
| `loanDebt` | `AssetLendingPool.getLoanDebt(tokenId)` | 0 if no active loan |
| `sellerProceeds` | remainder | — |

**Minimum price rule:** `gross ≥ collectibleFee + royalty + loanDebt`.  
If `gross < required`, the contract reverts with
`Marketplace__PriceBelowMinimum(gross, required)`.

### 8.2 Read snippet — preview before listing/bidding

```tsx
// hooks/usePricePreview.ts
import { useReadContracts } from 'wagmi'
import { ADDRESSES } from '@/constants/addresses'

const FEE_CONTROLLER_ABI = [
  {
    type: 'function',
    name: 'getCollectibleFee',
    inputs: [{ name: 'amount', type: 'uint256' }],
    outputs: [
      { name: 'fee', type: 'uint256' },
      { name: 'enabled', type: 'bool' },
    ],
    stateMutability: 'view',
  },
] as const

const LENDING_POOL_ABI = [
  {
    type: 'function',
    name: 'getLoanDebt',
    inputs: [{ name: 'tokenId', type: 'uint256' }],
    outputs: [
      { name: 'principal', type: 'uint256' },
      { name: 'interest',  type: 'uint256' },
      { name: 'total',     type: 'uint256' },
    ],
    stateMutability: 'view',
  },
] as const

const ASSET_NFT_ABI_ROYALTY = [
  {
    type: 'function',
    name: 'royaltyInfo',
    inputs: [
      { name: 'tokenId',   type: 'uint256' },
      { name: 'salePrice', type: 'uint256' },
    ],
    outputs: [
      { name: 'receiver', type: 'address' },
      { name: 'amount',   type: 'uint256' },
    ],
    stateMutability: 'view',
  },
] as const

export function usePricePreview(tokenId: bigint, gross: bigint) {
  return useReadContracts({
    contracts: [
      {
        address: ADDRESSES.feeController,
        abi: FEE_CONTROLLER_ABI,
        functionName: 'getCollectibleFee',
        args: [gross],
      },
      {
        address: ADDRESSES.lendingPool,
        abi: LENDING_POOL_ABI,
        functionName: 'getLoanDebt',
        args: [tokenId],
      },
      {
        address: ADDRESSES.assetNFT,
        abi: ASSET_NFT_ABI_ROYALTY,
        functionName: 'royaltyInfo',
        args: [tokenId, gross],
      },
    ],
    query: { enabled: gross > 0n },
  })
}

// Compute breakdown from results:
export function computeBreakdown(
  gross: bigint,
  collectibleFee: bigint,
  royaltyRaw: bigint,
  loanDebt: bigint,
): { collectibleFee: bigint; royalty: bigint; loanDebt: bigint; sellerProceeds: bigint; minPrice: bigint } {
  // Apply on-chain royalty cap: royalty ≤ gross - collectibleFee - loanDebt
  let royalty = royaltyRaw
  if (collectibleFee + loanDebt < gross) {
    const maxRoyalty = gross - collectibleFee - loanDebt
    if (royalty > maxRoyalty) royalty = maxRoyalty
  } else {
    royalty = 0n
  }
  const minPrice = collectibleFee + royalty + loanDebt
  const sellerProceeds = gross > minPrice ? gross - minPrice : 0n
  return { collectibleFee, royalty, loanDebt, sellerProceeds, minPrice }
}
```

---

## 9. Read / View Functions

### `getAuction(auctionId)` — fetch on-chain auction state

Returns `AuctionState`. `state.exists = false` means no bid has been committed
yet (the auction only materialises on first `commitBid`).

```tsx
import { useReadContract } from 'wagmi'
import { MARKETPLACE_ABI } from '@/lib/marketplace-abi'
import { ADDRESSES } from '@/constants/addresses'

export function useAuction(auctionId: `0x${string}` | undefined) {
  return useReadContract({
    address: ADDRESSES.marketplace,
    abi: MARKETPLACE_ABI,
    functionName: 'getAuction',
    args: auctionId ? [auctionId] : undefined,
    query: { enabled: !!auctionId },
  })
}
```

**`AuctionState` shape:**

| Field | Type | Description |
|-------|------|-------------|
| `seller` | `address` | NFT seller |
| `collection` | `address` | NFT contract |
| `tokenId` | `uint256` | |
| `paymentToken` | `address` | USDC |
| `endTime` | `uint256` | Current auction end (may have been extended) |
| `extensionWindow` | `uint256` | Seconds before endTime that triggers extension |
| `extensionDuration` | `uint256` | Seconds added on last-minute bid |
| `minIncrement` | `uint256` | Minimum bid step |
| `reservePrice` | `uint256` | Minimum first bid |
| `highestBidder` | `address` | `address(0)` if no bids yet |
| `highestBid` | `uint256` | |
| `settled` | `bool` | `true` = settled or cancelled |
| `exists` | `bool` | `false` = not yet materialised |

### `isNonceUsed(signer, nonce)` — replay check

```tsx
export function useIsNonceUsed(signer: `0x${string}` | undefined, nonce: bigint | undefined) {
  return useReadContract({
    address: ADDRESSES.marketplace,
    abi: MARKETPLACE_ABI,
    functionName: 'isNonceUsed',
    args: signer && nonce !== undefined ? [signer, nonce] : undefined,
    query: { enabled: !!signer && nonce !== undefined },
  })
}
```

### `hashAuction(auction)` — compute auctionId

```tsx
export function useHashAuction(auction: SignedAuctionMessage | undefined) {
  return useReadContract({
    address: ADDRESSES.marketplace,
    abi: MARKETPLACE_ABI,
    functionName: 'hashAuction',
    args: auction ? [auction] : undefined,
    query: { enabled: !!auction },
  })
}
```

---

## 10. Events

### 10.1 `SaleExecuted` — fixed-price or auction settlement completed

```solidity
event SaleExecuted(
  address indexed seller,
  address indexed buyer,
  address indexed collection,
  uint256 tokenId,
  address paymentToken,
  uint256 gross,
  uint256 collectibleFee,
  uint256 royalty,
  uint256 loanRepaid,
  uint256 sellerProceeds
)
```

```tsx
import { useWatchContractEvent } from 'wagmi'
import { MARKETPLACE_ABI } from '@/lib/marketplace-abi'
import { ADDRESSES } from '@/constants/addresses'

useWatchContractEvent({
  address: ADDRESSES.marketplace,
  abi: MARKETPLACE_ABI,
  eventName: 'SaleExecuted',
  onLogs(logs) {
    for (const log of logs) {
      const { seller, buyer, collection, tokenId, gross, sellerProceeds } = log.args
      console.log(`Sale: token ${tokenId} sold for ${gross} → seller got ${sellerProceeds}`)
    }
  },
})
```

### 10.2 `BidCommitted` — new highest bid recorded

```solidity
event BidCommitted(
  bytes32 indexed auctionId,
  address indexed bidder,
  uint256 amount,
  uint256 newEndTime   // may be extended
)
```

```tsx
useWatchContractEvent({
  address: ADDRESSES.marketplace,
  abi: MARKETPLACE_ABI,
  eventName: 'BidCommitted',
  args: { auctionId: myAuctionId },  // filter by specific auction
  onLogs(logs) {
    for (const log of logs) {
      const { bidder, amount, newEndTime } = log.args
      console.log(`New bid: ${amount} by ${bidder}, ends at ${newEndTime}`)
    }
  },
})
```

### 10.3 All Events Reference

| Event | Indexed fields | When emitted |
|-------|---------------|-------------|
| `SaleExecuted` | `seller`, `buyer`, `collection` | Fixed-price purchase or auction settlement |
| `BidCommitted` | `auctionId`, `bidder` | Every valid on-chain bid |
| `AuctionSettled` | `auctionId`, `winner` | Auction settled (winner declared) |
| `AuctionCancelled` | `auctionId`, `cancelledBy` | Seller or admin cancels |
| `NonceCancelled` | `signer` | `cancelNonce` called |
| `FeeControllerUpdated` | `newController` | Admin config change |
| `LendingPoolUpdated` | `newPool` | Admin config change |
| `TreasuryUpdated` | `newTreasury` | Admin config change |
| `AllowedCollectionUpdated` | `collection` | Admin whitelist change |
| `AllowedPaymentTokenUpdated` | `token` | Admin whitelist change |

---

## 11. Error Reference

All errors are **ABI custom errors**. Decode them from viem's
`ContractFunctionRevertedError`:

```ts
import { BaseError, ContractFunctionRevertedError } from 'viem'

try {
  await simulateContract(...)
} catch (err) {
  if (err instanceof BaseError) {
    const revertError = err.walk(e => e instanceof ContractFunctionRevertedError)
    if (revertError instanceof ContractFunctionRevertedError) {
      console.error(revertError.data?.errorName, revertError.data?.args)
    }
  }
}
```

| Error | Args | User-facing message | Likely cause |
|-------|------|---------------------|-------------|
| `Marketplace__InvalidSignature` | — | "Listing/bid signature is invalid." | Signer doesn't match; wrong domain, wrong field order, or wrong address. |
| `Marketplace__NonceUsed` | `signer`, `nonce` | "This listing has already been used or cancelled." | Nonce was consumed by a previous transaction or `cancelNonce`. |
| `Marketplace__Expired` | — | "This listing has expired." | `listing.expiry < block.timestamp`. |
| `Marketplace__NotStarted` | — | "The auction has not started yet." | `block.timestamp < auction.startTime`. |
| `Marketplace__AuctionEnded` | — | "The auction has already ended." | Bid committed after `state.endTime`. |
| `Marketplace__AuctionNotEnded` | — | "The auction is still ongoing." | Calling `settleAuction` before `endTime` without `MARKETPLACE_ROLE`. |
| `Marketplace__AuctionAlreadySettled` | — | "This auction is already settled." | Calling settle or commit on an already-settled auction. |
| `Marketplace__AuctionNotFound` | — | "Auction not found." | `auctionId` has no on-chain state (no bids committed yet). |
| `Marketplace__BidTooLow` | `amount`, `minRequired` | `"Bid too low. Minimum required: ${minRequired}."` | First bid below `reservePrice`, or subsequent bid doesn't meet `highestBid + minIncrement`. |
| `Marketplace__NoBids` | — | "No bids were placed on this auction." | Settling an auction where `highestBidder == address(0)`. |
| `Marketplace__NotSeller` | — | "Only the seller can cancel this auction." | Non-seller, non-admin calling `cancelAuction`. |
| `Marketplace__PriceBelowMinimum` | `gross`, `required` | `"Price too low. Minimum required: ${required}."` | `gross < collectibleFee + royalty + loanDebt`. Often a loan-bearing NFT where price doesn't cover the debt. |
| `Marketplace__CollectionNotAllowed` | `collection` | "This NFT collection is not supported." | Collection not whitelisted by admin. |
| `Marketplace__PaymentTokenNotAllowed` | `token` | "This payment token is not supported." | Token not whitelisted (only USDC is whitelisted by default). |
| `Marketplace__ZeroAddress` | — | Internal config error. | Admin set a zero address — surface to devs, not end users. |

---

## 12. ABI Reference

### Full ABI

Import the compiled artifact (generated by `pnpm compile`):

```ts
// lib/marketplace-abi.ts
import NettyWorthMarketplaceArtifact from '@/artifacts/contracts/NettyWorthMarketplace.sol/NettyWorthMarketplace.json'

export const MARKETPLACE_ABI = NettyWorthMarketplaceArtifact.abi as const
```

The artifact path assumes you symlink or copy `artifacts/` into `nettyworth-next/`.
Alternatively, export and version the ABI as a static file.

### Trimmed inline ABI

A self-contained subset covering the four write functions and three view
functions needed by this guide:

```ts
// lib/marketplace-abi-slim.ts
export const MARKETPLACE_ABI_SLIM = [
  // ── Write functions ──────────────────────────────────────────────────────
  {
    type: 'function',
    name: 'buyWithSignature',
    inputs: [
      {
        name: 'listing', type: 'tuple',
        components: [
          { name: 'seller',       type: 'address' },
          { name: 'collection',   type: 'address' },
          { name: 'tokenId',      type: 'uint256' },
          { name: 'paymentToken', type: 'address' },
          { name: 'price',        type: 'uint256' },
          { name: 'nonce',        type: 'uint256' },
          { name: 'expiry',       type: 'uint256' },
        ],
      },
      { name: 'sig', type: 'bytes' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'commitBid',
    inputs: [
      {
        name: 'auction', type: 'tuple',
        components: [
          { name: 'seller',            type: 'address' },
          { name: 'collection',        type: 'address' },
          { name: 'tokenId',           type: 'uint256' },
          { name: 'paymentToken',      type: 'address' },
          { name: 'reservePrice',      type: 'uint256' },
          { name: 'minIncrement',      type: 'uint256' },
          { name: 'startTime',         type: 'uint256' },
          { name: 'endTime',           type: 'uint256' },
          { name: 'extensionWindow',   type: 'uint256' },
          { name: 'extensionDuration', type: 'uint256' },
          { name: 'nonce',             type: 'uint256' },
        ],
      },
      { name: 'auctionSig', type: 'bytes' },
      {
        name: 'bid', type: 'tuple',
        components: [
          { name: 'auctionId', type: 'bytes32' },
          { name: 'bidder',    type: 'address' },
          { name: 'amount',    type: 'uint256' },
          { name: 'nonce',     type: 'uint256' },
          { name: 'expiry',    type: 'uint256' },
        ],
      },
      { name: 'bidSig', type: 'bytes' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'settleAuction',
    inputs: [{ name: 'auctionId', type: 'bytes32' }],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'cancelNonce',
    inputs: [{ name: 'nonce', type: 'uint256' }],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'cancelAuction',
    inputs: [{ name: 'auctionId', type: 'bytes32' }],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  // ── View functions ───────────────────────────────────────────────────────
  {
    type: 'function',
    name: 'getAuction',
    inputs: [{ name: 'auctionId', type: 'bytes32' }],
    outputs: [
      {
        name: '', type: 'tuple',
        components: [
          { name: 'seller',            type: 'address' },
          { name: 'collection',        type: 'address' },
          { name: 'tokenId',           type: 'uint256' },
          { name: 'paymentToken',      type: 'address' },
          { name: 'endTime',           type: 'uint256' },
          { name: 'extensionWindow',   type: 'uint256' },
          { name: 'extensionDuration', type: 'uint256' },
          { name: 'minIncrement',      type: 'uint256' },
          { name: 'reservePrice',      type: 'uint256' },
          { name: 'highestBidder',     type: 'address' },
          { name: 'highestBid',        type: 'uint256' },
          { name: 'settled',           type: 'bool'    },
          { name: 'exists',            type: 'bool'    },
        ],
      },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'isNonceUsed',
    inputs: [
      { name: 'signer', type: 'address' },
      { name: 'nonce',  type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'hashAuction',
    inputs: [
      {
        name: 'auction', type: 'tuple',
        components: [
          { name: 'seller',            type: 'address' },
          { name: 'collection',        type: 'address' },
          { name: 'tokenId',           type: 'uint256' },
          { name: 'paymentToken',      type: 'address' },
          { name: 'reservePrice',      type: 'uint256' },
          { name: 'minIncrement',      type: 'uint256' },
          { name: 'startTime',         type: 'uint256' },
          { name: 'endTime',           type: 'uint256' },
          { name: 'extensionWindow',   type: 'uint256' },
          { name: 'extensionDuration', type: 'uint256' },
          { name: 'nonce',             type: 'uint256' },
        ],
      },
    ],
    outputs: [{ name: '', type: 'bytes32' }],
    stateMutability: 'view',
  },
  // ── Events ───────────────────────────────────────────────────────────────
  {
    type: 'event',
    name: 'SaleExecuted',
    inputs: [
      { name: 'seller',          type: 'address', indexed: true  },
      { name: 'buyer',           type: 'address', indexed: true  },
      { name: 'collection',      type: 'address', indexed: true  },
      { name: 'tokenId',         type: 'uint256', indexed: false },
      { name: 'paymentToken',    type: 'address', indexed: false },
      { name: 'gross',           type: 'uint256', indexed: false },
      { name: 'collectibleFee',  type: 'uint256', indexed: false },
      { name: 'royalty',         type: 'uint256', indexed: false },
      { name: 'loanRepaid',      type: 'uint256', indexed: false },
      { name: 'sellerProceeds',  type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'BidCommitted',
    inputs: [
      { name: 'auctionId',  type: 'bytes32', indexed: true  },
      { name: 'bidder',     type: 'address', indexed: true  },
      { name: 'amount',     type: 'uint256', indexed: false },
      { name: 'newEndTime', type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'AuctionSettled',
    inputs: [
      { name: 'auctionId', type: 'bytes32', indexed: true  },
      { name: 'winner',    type: 'address', indexed: true  },
      { name: 'amount',    type: 'uint256', indexed: false },
    ],
  },
  {
    type: 'event',
    name: 'AuctionCancelled',
    inputs: [
      { name: 'auctionId',   type: 'bytes32', indexed: true },
      { name: 'cancelledBy', type: 'address', indexed: true },
    ],
  },
  {
    type: 'event',
    name: 'NonceCancelled',
    inputs: [
      { name: 'signer', type: 'address', indexed: true  },
      { name: 'nonce',  type: 'uint256', indexed: false },
    ],
  },
  // ── Custom errors ────────────────────────────────────────────────────────
  { type: 'error', name: 'Marketplace__ZeroAddress',          inputs: [] },
  { type: 'error', name: 'Marketplace__InvalidSignature',     inputs: [] },
  { type: 'error', name: 'Marketplace__NonceUsed',            inputs: [{ name: 'signer', type: 'address' }, { name: 'nonce', type: 'uint256' }] },
  { type: 'error', name: 'Marketplace__Expired',              inputs: [] },
  { type: 'error', name: 'Marketplace__NotStarted',           inputs: [] },
  { type: 'error', name: 'Marketplace__PriceBelowMinimum',    inputs: [{ name: 'gross', type: 'uint256' }, { name: 'required', type: 'uint256' }] },
  { type: 'error', name: 'Marketplace__AuctionNotFound',      inputs: [] },
  { type: 'error', name: 'Marketplace__AuctionEnded',         inputs: [] },
  { type: 'error', name: 'Marketplace__AuctionNotEnded',      inputs: [] },
  { type: 'error', name: 'Marketplace__AuctionAlreadySettled',inputs: [] },
  { type: 'error', name: 'Marketplace__BidTooLow',            inputs: [{ name: 'amount', type: 'uint256' }, { name: 'minRequired', type: 'uint256' }] },
  { type: 'error', name: 'Marketplace__NotSeller',            inputs: [] },
  { type: 'error', name: 'Marketplace__NoBids',               inputs: [] },
  { type: 'error', name: 'Marketplace__CollectionNotAllowed', inputs: [{ name: 'collection', type: 'address' }] },
  { type: 'error', name: 'Marketplace__PaymentTokenNotAllowed',inputs: [{ name: 'token', type: 'address' }] },
] as const
```

---

*Source of truth: [contracts/interfaces/INettyWorthMarketplace.sol](../contracts/interfaces/INettyWorthMarketplace.sol) · [contracts/NettyWorthMarketplace.sol](../contracts/NettyWorthMarketplace.sol) · [deployments/sepolia.json](../deployments/sepolia.json)*
