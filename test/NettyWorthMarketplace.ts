import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import {
  encodeFunctionData,
  toHex,
  keccak256,
  hashTypedData,
  getAddress,
  zeroAddress,
  type Address,
  type WalletClient,
} from "viem";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const FORWARDER = "0x1234567890123456789012345678901234567890" as Address;
const LTV_BPS = 5000n; // 50%
const APPRAISAL = 1000n * 10n ** 6n; // 1000 USDC
const POOL_SEED = 10_000n * 10n ** 6n; // 10k USDC
const MAX_UINT = 2n ** 256n - 1n;
const RESERVE_PRICE = 800n * 10n ** 6n;
const MIN_INCREMENT = 10n * 10n ** 6n;
const EXTENSION_WINDOW = 300n; // 5 minutes in seconds
const EXTENSION_DURATION = 600n; // 10 minutes in seconds

const AssetState = {
  Held: 0,
  Listed: 1,
  Loaned: 2,
  Traded: 3,
  InShipment: 4,
  RemovedFromPlatform: 5,
} as const;

function roleHash(role: string): `0x${string}` {
  return keccak256(toHex(role));
}

const STATE_MANAGER_ROLE = roleHash("STATE_MANAGER_ROLE");
const MINTER_ROLE = roleHash("MINTER_ROLE");
const MARKETPLACE_ROLE = roleHash("MARKETPLACE_ROLE");

// ---------------------------------------------------------------------------
// EIP-712 type definitions (must match Solidity typehashes exactly)
// ---------------------------------------------------------------------------

const SIGNED_LISTING_TYPES = {
  SignedListing: [
    { name: "seller", type: "address" },
    { name: "collection", type: "address" },
    { name: "tokenId", type: "uint256" },
    { name: "paymentToken", type: "address" },
    { name: "price", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "expiry", type: "uint256" },
    { name: "buyer", type: "address" },
  ],
} as const;

const SIGNED_OFFER_TYPES = {
  SignedOffer: [
    { name: "buyer", type: "address" },
    { name: "collection", type: "address" },
    { name: "tokenId", type: "uint256" },
    { name: "paymentToken", type: "address" },
    { name: "price", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "expiry", type: "uint256" },
  ],
} as const;

const SIGNED_AUCTION_TYPES = {
  SignedAuction: [
    { name: "seller", type: "address" },
    { name: "collection", type: "address" },
    { name: "tokenId", type: "uint256" },
    { name: "paymentToken", type: "address" },
    { name: "reservePrice", type: "uint256" },
    { name: "minIncrement", type: "uint256" },
    { name: "startTime", type: "uint256" },
    { name: "endTime", type: "uint256" },
    { name: "extensionWindow", type: "uint256" },
    { name: "extensionDuration", type: "uint256" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

const SIGNED_BID_TYPES = {
  SignedBid: [
    { name: "auctionId", type: "bytes32" },
    { name: "bidder", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "expiry", type: "uint256" },
  ],
} as const;

type SignedListing = {
  seller: Address;
  collection: Address;
  tokenId: bigint;
  paymentToken: Address;
  price: bigint;
  nonce: bigint;
  expiry: bigint;
  buyer: Address; // zeroAddress = open listing; non-zero = private/targeted
};

type SignedOffer = {
  buyer: Address;
  collection: Address;
  tokenId: bigint;
  paymentToken: Address;
  price: bigint;
  nonce: bigint;
  expiry: bigint;
};

type SignedAuction = {
  seller: Address;
  collection: Address;
  tokenId: bigint;
  paymentToken: Address;
  reservePrice: bigint;
  minIncrement: bigint;
  startTime: bigint;
  endTime: bigint;
  extensionWindow: bigint;
  extensionDuration: bigint;
  nonce: bigint;
};

type SignedBid = {
  auctionId: `0x${string}`;
  bidder: Address;
  amount: bigint;
  nonce: bigint;
  expiry: bigint;
};

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

describe("NettyWorthMarketplace", async function () {
  const { viem } = await network.create();
  const testClient = await viem.getTestClient();
  const publicClient = await viem.getPublicClient();

  const [
    walletAdmin,
    walletSeller,
    walletBidder,
    walletBidder2,
    walletOperator,
    walletOther,
    walletBuyer,
  ] = await viem.getWalletClients();

  const adminAddress = walletAdmin.account.address;
  const sellerAddress = walletSeller.account.address;
  const bidderAddress = walletBidder.account.address;
  const bidder2Address = walletBidder2.account.address;
  const operatorAddress = walletOperator.account.address;
  const buyerAddress = walletBuyer.account.address;

  // treasury and royaltyReceiver are fixed addresses (not wallet clients)
  const treasuryAddress =
    "0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF" as Address;
  const royaltyReceiverAddress =
    "0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa" as Address;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  async function getBlockTimestamp(): Promise<bigint> {
    const block = await publicClient.getBlock({ blockTag: "latest" });
    return block.timestamp;
  }

  // M012 fix: auctionId is now the full EIP-712 domain-separated digest so that the
  // contract's hashAuction() view, commitBid(), and SignedBid.auctionId all agree.
  async function computeAuctionId(
    auction: SignedAuction,
    marketAddress: Address,
  ): Promise<`0x${string}`> {
    const chainId = await publicClient.getChainId();
    return hashTypedData({
      domain: {
        name: "NettyWorthMarketplace",
        version: "1",
        chainId: BigInt(chainId),
        verifyingContract: marketAddress,
      },
      types: SIGNED_AUCTION_TYPES,
      primaryType: "SignedAuction",
      message: auction,
    });
  }

  async function signAuction(
    wallet: WalletClient,
    auction: SignedAuction,
    marketAddress: Address,
  ): Promise<`0x${string}`> {
    const chainId = await wallet.getChainId();
    return wallet.signTypedData({
      account: wallet.account!,
      domain: {
        name: "NettyWorthMarketplace",
        version: "1",
        chainId,
        verifyingContract: marketAddress,
      },
      types: SIGNED_AUCTION_TYPES,
      primaryType: "SignedAuction",
      message: auction,
    });
  }

  async function signBid(
    wallet: WalletClient,
    bid: SignedBid,
    marketAddress: Address,
  ): Promise<`0x${string}`> {
    const chainId = await wallet.getChainId();
    return wallet.signTypedData({
      account: wallet.account!,
      domain: {
        name: "NettyWorthMarketplace",
        version: "1",
        chainId,
        verifyingContract: marketAddress,
      },
      types: SIGNED_BID_TYPES,
      primaryType: "SignedBid",
      message: bid,
    });
  }

  async function signOffer(
    wallet: WalletClient,
    offer: SignedOffer,
    marketAddress: Address,
  ): Promise<`0x${string}`> {
    const chainId = await wallet.getChainId();
    return wallet.signTypedData({
      account: wallet.account!,
      domain: {
        name: "NettyWorthMarketplace",
        version: "1",
        chainId,
        verifyingContract: marketAddress,
      },
      types: SIGNED_OFFER_TYPES,
      primaryType: "SignedOffer",
      message: offer,
    });
  }

  async function signListing(
    wallet: WalletClient,
    listing: SignedListing,
    marketAddress: Address,
  ): Promise<`0x${string}`> {
    const chainId = await wallet.getChainId();
    return wallet.signTypedData({
      account: wallet.account!,
      domain: {
        name: "NettyWorthMarketplace",
        version: "1",
        chainId,
        verifyingContract: marketAddress,
      },
      types: SIGNED_LISTING_TYPES,
      primaryType: "SignedListing",
      message: listing,
    });
  }

  function makeDefaultAuction(
    tokenId: bigint,
    seller: Address,
    collection: Address,
    paymentToken: Address,
    startTs: bigint,
    nonce: bigint,
  ): SignedAuction {
    return {
      seller,
      collection,
      tokenId,
      paymentToken,
      reservePrice: RESERVE_PRICE,
      minIncrement: MIN_INCREMENT,
      startTime: startTs,
      endTime: startTs + 86400n, // +1 day
      extensionWindow: EXTENSION_WINDOW,
      extensionDuration: EXTENSION_DURATION,
      nonce,
    };
  }

  // -------------------------------------------------------------------------
  // Full deployment fixture
  // -------------------------------------------------------------------------

  async function deploy() {
    // 1. MockERC20 (USDC, 6 decimals)
    const usdc = await viem.deployContract("MockERC20");

    // 2. PermissionManager (admin auto-gets all roles incl. MARKETPLACE_ROLE)
    const pmImpl = await viem.deployContract("PermissionManager");
    const pmProxy = await viem.deployContract("ERC1967ProxyHelper", [
      pmImpl.address,
      encodeFunctionData({
        abi: pmImpl.abi,
        functionName: "initialize",
        args: [adminAddress],
      }),
    ]);
    const pm = await viem.getContractAt("PermissionManager", pmProxy.address);

    // 3. AssetNFT
    const nftImpl = await viem.deployContract("AssetNFT", [FORWARDER]);
    const nftProxy = await viem.deployContract("ERC1967ProxyHelper", [
      nftImpl.address,
      encodeFunctionData({
        abi: nftImpl.abi,
        functionName: "initialize",
        args: [
          pm.address,
          "NW Assets",
          "NWA",
          "ipfs://c",
          royaltyReceiverAddress,
          500n, // 5% royalty
        ],
      }),
    ]);
    const nft = await viem.getContractAt("AssetNFT", nftProxy.address);

    // 4. AssetLendingPoolConfig + AssetLendingPool
    //    For auction flow tests, the factory only needs isPackMachine() — use MockPackMachineFactory.
    const factory = await viem.deployContract(
      "contracts/test-helpers/MockPackMachineFactory.sol:MockPackMachineFactory",
    );
    const configImpl = await viem.deployContract("AssetLendingPoolConfig");
    const configProxy = await viem.deployContract("ERC1967ProxyHelper", [
      configImpl.address,
      encodeFunctionData({
        abi: configImpl.abi,
        functionName: "initialize",
        args: [
          adminAddress,
          usdc.address,
          nft.address,
          LTV_BPS,
          8000n,
          BigInt(24 * 3600),
          BigInt(7 * 24 * 3600),
          factory.address,
        ],
      }),
    ]);
    const lendingConfig = await viem.getContractAt(
      "AssetLendingPoolConfig",
      configProxy.address,
    );

    const lendingLib = await viem.deployContract("LendingLib");
    const poolImpl = await viem.deployContract("AssetLendingPool", [], {
      libraries: {
        "project/contracts/lib/LendingLib.sol:LendingLib": lendingLib.address,
      },
    });
    const poolProxy = await viem.deployContract("ERC1967ProxyHelper", [
      poolImpl.address,
      encodeFunctionData({
        abi: poolImpl.abi,
        functionName: "initialize",
        args: [adminAddress, lendingConfig.address],
      }),
    ]);
    const pool = await viem.getContractAt(
      "AssetLendingPool",
      poolProxy.address,
    );

    // 5. FeeController
    const fcImpl = await viem.deployContract("FeeController");
    const fcProxy = await viem.deployContract("ERC1967ProxyHelper", [
      fcImpl.address,
      encodeFunctionData({
        abi: fcImpl.abi,
        functionName: "initialize",
        args: [pm.address, treasuryAddress],
      }),
    ]);
    const fc = await viem.getContractAt("FeeController", fcProxy.address);

    // 6. NettyWorthMarketplace
    const marketImpl = await viem.deployContract("NettyWorthMarketplace");
    const marketProxy = await viem.deployContract("ERC1967ProxyHelper", [
      marketImpl.address,
      encodeFunctionData({
        abi: marketImpl.abi,
        functionName: "initialize",
        args: [
          pm.address,
          fc.address,
          pool.address,
          nft.address,
          usdc.address,
          treasuryAddress,
        ],
      }),
    ]);
    const market = await viem.getContractAt(
      "NettyWorthMarketplace",
      marketProxy.address,
    );

    // -----------------------------------------------------------------------
    // Wiring
    // -----------------------------------------------------------------------
    // Pool: grant STATE_MANAGER_ROLE; authorize marketplace via config
    await pm.write.grantRole([STATE_MANAGER_ROLE, pool.address], {
      account: walletAdmin.account,
    });
    await lendingConfig.write.setMarketplace([market.address], {
      account: walletAdmin.account,
    });

    // Mint NFTs to seller (tokenIds 1 and 2)
    await pm.write.grantRole([MINTER_ROLE, adminAddress], {
      account: walletAdmin.account,
    });
    await nft.write.batchMint(
      [
        [sellerAddress, sellerAddress],
        ["ipfs://1", "ipfs://2"],
      ],
      { account: walletAdmin.account },
    );

    // Seed pool with USDC
    await usdc.write.mint([adminAddress, POOL_SEED]);
    await usdc.write.approve([pool.address, POOL_SEED], {
      account: walletAdmin.account,
    });
    await pool.write.deposit([POOL_SEED], { account: walletAdmin.account });

    // Set appraisals via config (category 0 = uncategorized)
    await lendingConfig.write.setAppraisal([1n, APPRAISAL, 80n, 0n], {
      account: walletAdmin.account,
    });
    await lendingConfig.write.setAppraisal([2n, APPRAISAL, 80n, 0n], {
      account: walletAdmin.account,
    });

    // Pre-fund bidder, buyer and operator; pre-approve marketplace
    for (const [addr, wallet] of [
      [bidderAddress, walletBidder],
      [bidder2Address, walletBidder2],
      [operatorAddress, walletOperator],
      [buyerAddress, walletBuyer],
    ] as [Address, WalletClient][]) {
      await usdc.write.mint([addr, 10_000n * 10n ** 6n]);
      await usdc.write.approve([market.address, MAX_UINT], {
        account: wallet.account,
      });
    }

    // admin already holds MARKETPLACE_ROLE (granted by PermissionManager.initialize)

    return { pm, usdc, nft, pool, fc, market };
  }

  // =========================================================================
  // Tests
  // =========================================================================

  describe("commitBid — below reserve reverts", async function () {
    it("reverts with BidTooLow and does not materialize AuctionState", async function () {
      const { usdc, nft, market } = await deploy();
      const ts = await getBlockTimestamp();
      const auction = makeDefaultAuction(
        2n,
        sellerAddress,
        nft.address,
        usdc.address,
        ts,
        1n,
      );
      const auctionId = await computeAuctionId(auction, market.address);
      const auctionSig = await signAuction(
        walletSeller,
        auction,
        market.address,
      );

      const bid: SignedBid = {
        auctionId,
        bidder: bidderAddress,
        amount: 500n * 10n ** 6n, // below 800e6 reserve
        nonce: 1n,
        expiry: ts + 3600n,
      };
      const bidSig = await signBid(walletBidder, bid, market.address);

      await assert.rejects(
        market.write.commitBid([auction, auctionSig, bid, bidSig], {
          account: walletBidder.account,
        }),
        /BidTooLow/,
      );

      const state = await market.read.getAuction([auctionId]);
      assert.equal(state.exists, false);
    });
  });

  describe("commitBid — first valid bid materializes state", async function () {
    it("stores highestBidder and highestBid on first qualifying bid", async function () {
      const { usdc, nft, market } = await deploy();
      const ts = await getBlockTimestamp();
      const auction = makeDefaultAuction(
        2n,
        sellerAddress,
        nft.address,
        usdc.address,
        ts,
        1n,
      );
      const auctionId = await computeAuctionId(auction, market.address);
      const auctionSig = await signAuction(
        walletSeller,
        auction,
        market.address,
      );

      const bid: SignedBid = {
        auctionId,
        bidder: bidderAddress,
        amount: 900n * 10n ** 6n,
        nonce: 1n,
        expiry: ts + 3600n,
      };
      const bidSig = await signBid(walletBidder, bid, market.address);

      await market.write.commitBid([auction, auctionSig, bid, bidSig], {
        account: walletBidder.account,
      });

      const state = await market.read.getAuction([auctionId]);
      assert.equal(state.exists, true);
      assert.equal(getAddress(state.highestBidder), getAddress(bidderAddress));
      assert.equal(state.highestBid, 900n * 10n ** 6n);
    });
  });

  describe("commitBid — second bid below min increment reverts", async function () {
    it("reverts BidTooLow for bid below highestBid + minIncrement", async function () {
      const { usdc, nft, market } = await deploy();
      const ts = await getBlockTimestamp();
      const auction = makeDefaultAuction(
        2n,
        sellerAddress,
        nft.address,
        usdc.address,
        ts,
        1n,
      );
      const auctionId = await computeAuctionId(auction, market.address);
      const auctionSig = await signAuction(
        walletSeller,
        auction,
        market.address,
      );

      // First bid: 900e6 (valid)
      const bid1: SignedBid = {
        auctionId,
        bidder: bidderAddress,
        amount: 900n * 10n ** 6n,
        nonce: 1n,
        expiry: ts + 3600n,
      };
      await market.write.commitBid(
        [
          auction,
          auctionSig,
          bid1,
          await signBid(walletBidder, bid1, market.address),
        ],
        { account: walletBidder.account },
      );

      // Second bid: 905e6 — only 5e6 above, but minIncrement = 10e6 → required = 910e6
      const bid2: SignedBid = {
        auctionId,
        bidder: bidder2Address,
        amount: 905n * 10n ** 6n,
        nonce: 1n,
        expiry: ts + 3600n,
      };
      await assert.rejects(
        market.write.commitBid(
          [
            auction,
            auctionSig,
            bid2,
            await signBid(walletBidder2, bid2, market.address),
          ],
          { account: walletBidder2.account },
        ),
        /BidTooLow/,
      );
    });
  });

  describe("commitBid — extension window pushes endTime", async function () {
    it("extends endTime when bid lands inside extensionWindow", async function () {
      const { usdc, nft, market } = await deploy();
      const ts = await getBlockTimestamp();
      const endTime = ts + 86400n;
      const auction: SignedAuction = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId: 2n,
        paymentToken: usdc.address,
        reservePrice: RESERVE_PRICE,
        minIncrement: MIN_INCREMENT,
        startTime: ts,
        endTime,
        extensionWindow: EXTENSION_WINDOW,
        extensionDuration: EXTENSION_DURATION,
        nonce: 1n,
      };
      const auctionId = await computeAuctionId(auction, market.address);
      const auctionSig = await signAuction(
        walletSeller,
        auction,
        market.address,
      );

      // Warp to 3 minutes before end (inside the 5-minute extensionWindow)
      const bidTs = endTime - 180n;
      await testClient.setNextBlockTimestamp({ timestamp: bidTs });
      await testClient.mine({ blocks: 1 });

      const bid: SignedBid = {
        auctionId,
        bidder: bidderAddress,
        amount: RESERVE_PRICE,
        nonce: 1n,
        expiry: endTime + 3600n, // expiry beyond original end
      };
      const bidSig = await signBid(walletBidder, bid, market.address);

      await market.write.commitBid([auction, auctionSig, bid, bidSig], {
        account: walletBidder.account,
      });

      const state = await market.read.getAuction([auctionId]);
      assert.equal(state.endTime, endTime + EXTENSION_DURATION);
    });
  });

  describe("settleAuction — reverts before auction ends", async function () {
    it("reverts AuctionNotEnded when called by non-role holder before endTime", async function () {
      const { usdc, nft, market } = await deploy();
      const ts = await getBlockTimestamp();
      const auction = makeDefaultAuction(
        2n,
        sellerAddress,
        nft.address,
        usdc.address,
        ts,
        1n,
      );
      const auctionId = await computeAuctionId(auction, market.address);
      const auctionSig = await signAuction(
        walletSeller,
        auction,
        market.address,
      );

      const bid: SignedBid = {
        auctionId,
        bidder: bidderAddress,
        amount: RESERVE_PRICE,
        nonce: 1n,
        expiry: ts + 2n * 86400n,
      };
      await market.write.commitBid(
        [
          auction,
          auctionSig,
          bid,
          await signBid(walletBidder, bid, market.address),
        ],
        { account: walletBidder.account },
      );

      // walletOther has no MARKETPLACE_ROLE → cannot force-close → revert
      await assert.rejects(
        market.write.settleAuction([auctionId], {
          account: walletOther.account,
        }),
        /AuctionNotEnded/,
      );
    });
  });

  describe("settleAuction — full happy path (no loan)", async function () {
    it("delivers NFT to bidder and distributes funds correctly after auction end", async function () {
      const { usdc, nft, market } = await deploy();

      // Seller approves marketplace to transfer token 2
      await nft.write.approve([market.address, 2n], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      const auction = makeDefaultAuction(
        2n,
        sellerAddress,
        nft.address,
        usdc.address,
        ts,
        1n,
      );
      const auctionId = await computeAuctionId(auction, market.address);
      const auctionSig = await signAuction(
        walletSeller,
        auction,
        market.address,
      );

      const bidAmount = 900n * 10n ** 6n;
      const bid: SignedBid = {
        auctionId,
        bidder: bidderAddress,
        amount: bidAmount,
        nonce: 1n,
        expiry: ts + 2n * 86400n,
      };
      await market.write.commitBid(
        [
          auction,
          auctionSig,
          bid,
          await signBid(walletBidder, bid, market.address),
        ],
        { account: walletBidder.account },
      );

      // Capture balances before settlement
      const treasuryBefore = await usdc.read.balanceOf([treasuryAddress]);
      const royaltyBefore = await usdc.read.balanceOf([royaltyReceiverAddress]);
      const sellerBefore = await usdc.read.balanceOf([sellerAddress]);
      const bidderBefore = await usdc.read.balanceOf([bidderAddress]);

      // Warp past endTime
      await testClient.increaseTime({ seconds: 86401 });
      await testClient.mine({ blocks: 1 });

      // Anyone can settle
      await market.write.settleAuction([auctionId], {
        account: walletOther.account,
      });

      // NFT delivered to bidder in Held state
      assert.equal(
        getAddress(await nft.read.ownerOf([2n])),
        getAddress(bidderAddress),
      );
      assert.equal(await nft.read.getAssetState([2n]), AssetState.Held);

      // Bidder paid gross
      const bidderAfter = await usdc.read.balanceOf([bidderAddress]);
      assert.equal(bidderBefore - bidderAfter, bidAmount);

      // Treasury received 5% collectible fee
      const expectedFee = (bidAmount * 500n) / 10_000n;
      assert.equal(
        await usdc.read.balanceOf([treasuryAddress]),
        treasuryBefore + expectedFee,
      );

      // Royalty receiver got 5% royalty (set in AssetNFT initialize as 500 bps)
      const expectedRoyalty = (bidAmount * 500n) / 10_000n;
      assert.equal(
        await usdc.read.balanceOf([royaltyReceiverAddress]),
        royaltyBefore + expectedRoyalty,
      );

      // Seller received net proceeds
      const sellerAfter = await usdc.read.balanceOf([sellerAddress]);
      assert.ok(sellerAfter > sellerBefore);
      // proceeds = gross - fee - royalty
      assert.equal(
        sellerAfter - sellerBefore,
        bidAmount - expectedFee - expectedRoyalty,
      );

      // Auction marked settled
      const state = await market.read.getAuction([auctionId]);
      assert.equal(state.settled, true);
    });
  });

  describe("settleAuction — force-close by MARKETPLACE_ROLE", async function () {
    it("allows MARKETPLACE_ROLE holder to settle before auction ends", async function () {
      const { usdc, nft, market } = await deploy();

      await nft.write.approve([market.address, 2n], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      const auction = makeDefaultAuction(
        2n,
        sellerAddress,
        nft.address,
        usdc.address,
        ts,
        1n,
      );
      const auctionId = await computeAuctionId(auction, market.address);
      const auctionSig = await signAuction(
        walletSeller,
        auction,
        market.address,
      );

      const bid: SignedBid = {
        auctionId,
        bidder: bidderAddress,
        amount: RESERVE_PRICE,
        nonce: 1n,
        expiry: ts + 2n * 86400n,
      };
      await market.write.commitBid(
        [
          auction,
          auctionSig,
          bid,
          await signBid(walletBidder, bid, market.address),
        ],
        { account: walletBidder.account },
      );

      // Auction still active — admin holds MARKETPLACE_ROLE, can force-close
      await market.write.settleAuction([auctionId], {
        account: walletAdmin.account,
      });

      const state = await market.read.getAuction([auctionId]);
      assert.equal(state.settled, true);
      assert.equal(
        getAddress(await nft.read.ownerOf([2n])),
        getAddress(bidderAddress),
      );
    });
  });

  describe("default → claim → auction → settle (full lifecycle)", async function () {
    it("operator claims defaulted asset, lists at auction, bidder wins", async function () {
      const { usdc, nft, pool, market } = await deploy();

      // ---- Step 1: seller borrows against token 1 ----
      const loanAmount = 400n * 10n ** 6n;
      await nft.write.approve([pool.address, 1n], {
        account: walletSeller.account,
      });
      await pool.write.borrow([1n, loanAmount, 0], {
        account: walletSeller.account,
      });

      const loanId = await pool.read.getActiveLoanId([1n]);
      const loan = await pool.read.getLoan([loanId]);
      const outstanding = loan.principal + loan.interest;

      // ---- Step 2: default the loan ----
      // Warp to expiry
      await testClient.setNextBlockTimestamp({
        timestamp: loan.expireTime + 1n,
      });
      await testClient.mine({ blocks: 1 });
      await pool.write.initiateDefault([loanId], {
        account: walletAdmin.account,
      });

      // Warp past 24h acquisition window
      await testClient.increaseTime({ seconds: 24 * 3600 + 1 });
      await testClient.mine({ blocks: 1 });

      // ---- Step 3: MARKETPLACE_ROLE admin lists the defaulted asset via the marketplace ----
      // market.listDefaultedAsset() calls pool.prepareDefaultedListing() internally.
      // Admin holds MARKETPLACE_ROLE from setUp.
      const rec = await pool.read.getDefaultRecord([loanId]);
      const outstandingWithInterest = rec.outstandingValue + rec.interestValue;
      const reservePrice = outstandingWithInterest;

      const auctionStart = await getBlockTimestamp();
      const endTime = auctionStart + 86400n;

      const listTxHash = await market.write.listDefaultedAsset(
        [
          loanId,
          1n, // tokenId
          reservePrice,
          MIN_INCREMENT,
          auctionStart,
          endTime,
          EXTENSION_WINDOW,
          EXTENSION_DURATION,
        ],
        { account: walletAdmin.account },
      );

      // Extract auctionId from DefaultedAssetListed event (topic[2])
      const listReceipt = await publicClient.waitForTransactionReceipt({ hash: listTxHash });
      const defaultedAssetListedSig = "0x" + Buffer.from(
        "DefaultedAssetListed(uint256,uint256,bytes32,uint256,uint256)"
      ).reduce((acc, b) => acc + b.toString(16).padStart(2, "0"), "") as `0x${string}`;
      // Use keccak256 of the event signature to find the log
      const { keccak256: keccak256fn, toBytes: toBytesViem } = await import("viem");
      const eventSig = keccak256fn(toBytesViem("DefaultedAssetListed(uint256,uint256,bytes32,uint256,uint256)"));
      const listedLog = listReceipt.logs.find(l => l.topics[0] === eventSig);
      assert.ok(listedLog, "DefaultedAssetListed event not found");
      const auctionId = listedLog!.topics[3] as `0x${string}`;

      // Pool still owns the NFT; NFT is in Held state
      assert.equal(await nft.read.getAssetState([1n]), AssetState.Held);

      // ---- Step 4: bidder approves marketplace and commits a pool bid ----
      await usdc.write.approve([market.address, 10_000n * 10n ** 6n], {
        account: walletBidder.account,
      });

      const bidAmount = outstandingWithInterest + 50n * 10n ** 6n;
      const bidExpiry = auctionStart + 2n * 86400n;
      const bid: SignedBid = {
        auctionId,
        bidder: bidderAddress,
        amount: bidAmount,
        nonce: 100n,
        expiry: bidExpiry,
      };
      const bidSig = await signBid(walletBidder, bid, market.address);

      const bidderTokensBefore = await usdc.read.balanceOf([bidderAddress]);
      const poolBefore = await usdc.read.balanceOf([pool.address]);

      // Pool-default bids use commitPoolBid (no SignedAuction required)
      await market.write.commitPoolBid([auctionId, bid, bidSig], {
        account: walletBidder.account,
      });

      // ---- Step 5: settle after end ----
      await testClient.increaseTime({ seconds: 86401 });
      await testClient.mine({ blocks: 1 });

      await market.write.settleAuction([auctionId], {
        account: walletOther.account,
      });

      // NFT delivered to bidder
      assert.equal(
        getAddress(await nft.read.ownerOf([1n])),
        getAddress(bidderAddress),
      );
      assert.equal(await nft.read.getAssetState([1n]), AssetState.Held);

      // Bidder paid bidAmount
      assert.equal(
        bidderTokensBefore - (await usdc.read.balanceOf([bidderAddress])),
        bidAmount,
      );

      // Pool received proceeds (fees/royalty waived for pool-default sales)
      assert.ok(await usdc.read.balanceOf([pool.address]) >= poolBefore + bidAmount);

      // Auction settled; default record resolved
      assert.equal((await market.read.getAuction([auctionId])).settled, true);
      assert.equal((await pool.read.getDefaultRecord([loanId])).resolved, true);
    });
  });

  // =========================================================================
  // acceptOffer — happy path, no loan
  // =========================================================================

  describe("acceptOffer — happy path, no loan", async function () {
    it("delivers NFT to buyer and distributes funds correctly", async function () {
      const { usdc, nft, market } = await deploy();
      const gross = 1_000n * 10n ** 6n;
      const tokenId = 1n;

      // Seller approves marketplace
      await nft.write.approve([market.address, tokenId], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      const offer: SignedOffer = {
        buyer: buyerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: gross,
        nonce: 1n,
        expiry: ts + 3600n,
      };
      const offerSig = await signOffer(walletBuyer, offer, market.address);

      const buyerBefore = await usdc.read.balanceOf([buyerAddress]);
      const treasuryBefore = await usdc.read.balanceOf([treasuryAddress]);
      const royaltyBefore = await usdc.read.balanceOf([royaltyReceiverAddress]);
      const sellerBefore = await usdc.read.balanceOf([sellerAddress]);

      // Seller accepts the offer
      await market.write.acceptOffer([offer, offerSig], {
        account: walletSeller.account,
      });

      // NFT delivered to buyer
      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(buyerAddress),
      );

      // Buyer paid gross
      assert.equal(
        buyerBefore - (await usdc.read.balanceOf([buyerAddress])),
        gross,
      );

      // Treasury received 5% collectible fee
      const expectedFee = (gross * 500n) / 10_000n;
      assert.equal(
        await usdc.read.balanceOf([treasuryAddress]),
        treasuryBefore + expectedFee,
      );

      // Royalty receiver received 5% royalty
      const expectedRoyalty = (gross * 500n) / 10_000n;
      assert.equal(
        await usdc.read.balanceOf([royaltyReceiverAddress]),
        royaltyBefore + expectedRoyalty,
      );

      // Seller received net proceeds (gross - fee - royalty)
      assert.equal(
        (await usdc.read.balanceOf([sellerAddress])) - sellerBefore,
        gross - expectedFee - expectedRoyalty,
      );
    });
  });

  // =========================================================================
  // acceptOffer — loan branch: borrower accepts, loan auto-repaid
  // =========================================================================

  describe("acceptOffer — with active loan, borrower accepts", async function () {
    it("repays loan atomically and delivers NFT to buyer", async function () {
      const { usdc, nft, pool, market } = await deploy();
      const tokenId = 1n;
      const loanAmount = 400n * 10n ** 6n;

      // Seller borrows against token 1
      await nft.write.approve([pool.address, tokenId], {
        account: walletSeller.account,
      });
      await pool.write.borrow([tokenId, loanAmount, 0], {
        account: walletSeller.account,
      });

      const loanDebt = await pool.read.getLoanDebt([tokenId]);
      const totalDebt = loanDebt[2]; // principal + interest

      // Gross must cover fee (5%) + royalty (5%) + loanDebt
      // gross = totalDebt / (1 - 0.10) + buffer
      const gross = (totalDebt * 10_000n) / 8_000n + 2_000_000n;

      const ts = await getBlockTimestamp();
      const offer: SignedOffer = {
        buyer: buyerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: gross,
        nonce: 10n,
        expiry: ts + 3600n,
      };
      const offerSig = await signOffer(walletBuyer, offer, market.address);

      const poolBefore = await usdc.read.balanceOf([pool.address]);
      const sellerBefore = await usdc.read.balanceOf([sellerAddress]);

      // Borrower (seller) accepts
      await market.write.acceptOffer([offer, offerSig], {
        account: walletSeller.account,
      });

      // NFT delivered to buyer
      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(buyerAddress),
      );
      // Active loan cleared
      assert.equal(await pool.read.getActiveLoanId([tokenId]), 0n);
      // Pool received at least the loan debt
      assert.ok(
        (await usdc.read.balanceOf([pool.address])) >= poolBefore + totalDebt,
      );
      // Seller received net proceeds
      assert.ok((await usdc.read.balanceOf([sellerAddress])) > sellerBefore);
    });
  });

  // =========================================================================
  // acceptOffer — non-borrower cannot accept on a collateralised token
  // =========================================================================

  describe("acceptOffer — non-borrower cannot accept on loaned token", async function () {
    it("reverts NotTokenOwner when caller is not the loan borrower", async function () {
      const { usdc, nft, pool, market } = await deploy();
      const tokenId = 1n;

      // Seller borrows against token 1
      await nft.write.approve([pool.address, tokenId], {
        account: walletSeller.account,
      });
      await pool.write.borrow([tokenId, 400n * 10n ** 6n, 0], {
        account: walletSeller.account,
      });

      const loanDebt = (await pool.read.getLoanDebt([tokenId]))[2];
      const gross = loanDebt * 2n;

      const ts = await getBlockTimestamp();
      const offer: SignedOffer = {
        buyer: buyerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: gross,
        nonce: 20n,
        expiry: ts + 3600n,
      };
      const offerSig = await signOffer(walletBuyer, offer, market.address);

      // walletOther (not the borrower) calls acceptOffer → must revert
      await assert.rejects(
        market.write.acceptOffer([offer, offerSig], {
          account: walletOther.account,
        }),
        /NotTokenOwner/,
      );
    });
  });

  // =========================================================================
  // acceptOffer — revert on bad signature
  // =========================================================================

  describe("acceptOffer — bad signature reverts", async function () {
    it("reverts InvalidSignature when sig was not made by offer.buyer", async function () {
      const { usdc, nft, market } = await deploy();

      await nft.write.approve([market.address, 1n], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      const offer: SignedOffer = {
        buyer: buyerAddress,
        collection: nft.address,
        tokenId: 1n,
        paymentToken: usdc.address,
        price: 1_000n * 10n ** 6n,
        nonce: 1n,
        expiry: ts + 3600n,
      };
      // Sign with a different wallet (bidder)
      const badSig = await signOffer(walletBidder, offer, market.address);

      await assert.rejects(
        market.write.acceptOffer([offer, badSig], {
          account: walletSeller.account,
        }),
        /InvalidSignature/,
      );
    });
  });

  // =========================================================================
  // acceptOffer — revert on expired offer
  // =========================================================================

  describe("acceptOffer — expired offer reverts", async function () {
    it("reverts Expired when block.timestamp > offer.expiry", async function () {
      const { usdc, nft, market } = await deploy();

      await nft.write.approve([market.address, 1n], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      const offer: SignedOffer = {
        buyer: buyerAddress,
        collection: nft.address,
        tokenId: 1n,
        paymentToken: usdc.address,
        price: 1_000n * 10n ** 6n,
        nonce: 1n,
        expiry: ts - 1n, // already expired
      };
      const offerSig = await signOffer(walletBuyer, offer, market.address);

      await assert.rejects(
        market.write.acceptOffer([offer, offerSig], {
          account: walletSeller.account,
        }),
        /Expired/,
      );
    });
  });

  // =========================================================================
  // acceptOffer — cancelNonce blocks acceptance
  // =========================================================================

  describe("acceptOffer — cancelNonce blocks future acceptance", async function () {
    it("buyer can invalidate their nonce to prevent acceptance", async function () {
      const { usdc, nft, market } = await deploy();

      await nft.write.approve([market.address, 1n], {
        account: walletSeller.account,
      });

      // Buyer cancels nonce 77
      await market.write.cancelNonce([77n], { account: walletBuyer.account });
      assert.equal(await market.read.isNonceUsed([buyerAddress, 77n]), true);

      const ts = await getBlockTimestamp();
      const offer: SignedOffer = {
        buyer: buyerAddress,
        collection: nft.address,
        tokenId: 1n,
        paymentToken: usdc.address,
        price: 1_000n * 10n ** 6n,
        nonce: 77n,
        expiry: ts + 3600n,
      };
      const offerSig = await signOffer(walletBuyer, offer, market.address);

      await assert.rejects(
        market.write.acceptOffer([offer, offerSig], {
          account: walletSeller.account,
        }),
        /NonceUsed/,
      );
    });
  });

  // =========================================================================
  // buyWithSignatureFor / buyWithSignature — fixed-price signed listing
  // =========================================================================

  describe("buyWithSignatureFor — happy path (payer ≠ recipient), open listing", async function () {
    it("delivers NFT to recipient and distributes funds correctly", async function () {
      const { usdc, nft, market } = await deploy();
      const gross = 1_000n * 10n ** 6n;
      const tokenId = 1n;

      // Seller approves the marketplace to pull the NFT
      await nft.write.approve([market.address, tokenId], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      // Open listing: buyer = zeroAddress so anyone can fill it
      const listing: SignedListing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: gross,
        nonce: 1n,
        expiry: ts + 3600n,
        buyer: zeroAddress,
      };
      const listingSig = await signListing(walletSeller, listing, market.address);

      const buyerBefore = await usdc.read.balanceOf([buyerAddress]);
      const treasuryBefore = await usdc.read.balanceOf([treasuryAddress]);
      const royaltyBefore = await usdc.read.balanceOf([royaltyReceiverAddress]);
      const sellerBefore = await usdc.read.balanceOf([sellerAddress]);

      // walletBuyer pays; walletOther receives the NFT (payer ≠ recipient)
      const otherAddress = walletOther.account.address;
      await market.write.buyWithSignatureFor(
        [listing, listingSig, otherAddress],
        { account: walletBuyer.account },
      );

      // NFT landed at the recipient, not the payer
      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(otherAddress),
      );

      // Payer (walletBuyer) was charged the full gross
      assert.equal(
        buyerBefore - (await usdc.read.balanceOf([buyerAddress])),
        gross,
      );

      // Treasury received 5% collectible fee
      const expectedFee = (gross * 500n) / 10_000n;
      assert.equal(
        await usdc.read.balanceOf([treasuryAddress]),
        treasuryBefore + expectedFee,
      );

      // Royalty receiver received 5% royalty (500 bps set in AssetNFT.initialize)
      const expectedRoyalty = (gross * 500n) / 10_000n;
      assert.equal(
        await usdc.read.balanceOf([royaltyReceiverAddress]),
        royaltyBefore + expectedRoyalty,
      );

      // Seller received net proceeds
      assert.equal(
        (await usdc.read.balanceOf([sellerAddress])) - sellerBefore,
        gross - expectedFee - expectedRoyalty,
      );
    });
  });

  describe("buyWithSignature — happy path (payer == recipient)", async function () {
    it("delivers NFT to buyer and distributes funds correctly", async function () {
      const { usdc, nft, market } = await deploy();
      const gross = 1_000n * 10n ** 6n;
      const tokenId = 1n;

      await nft.write.approve([market.address, tokenId], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      const listing: SignedListing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: gross,
        nonce: 2n,
        expiry: ts + 3600n,
        buyer: zeroAddress,
      };
      const listingSig = await signListing(walletSeller, listing, market.address);

      const buyerBefore = await usdc.read.balanceOf([buyerAddress]);
      const treasuryBefore = await usdc.read.balanceOf([treasuryAddress]);
      const royaltyBefore = await usdc.read.balanceOf([royaltyReceiverAddress]);
      const sellerBefore = await usdc.read.balanceOf([sellerAddress]);

      await market.write.buyWithSignature([listing, listingSig], {
        account: walletBuyer.account,
      });

      // NFT delivered to the caller/buyer
      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(buyerAddress),
      );

      // Buyer paid gross
      assert.equal(
        buyerBefore - (await usdc.read.balanceOf([buyerAddress])),
        gross,
      );

      const expectedFee = (gross * 500n) / 10_000n;
      assert.equal(
        await usdc.read.balanceOf([treasuryAddress]),
        treasuryBefore + expectedFee,
      );

      const expectedRoyalty = (gross * 500n) / 10_000n;
      assert.equal(
        await usdc.read.balanceOf([royaltyReceiverAddress]),
        royaltyBefore + expectedRoyalty,
      );

      assert.equal(
        (await usdc.read.balanceOf([sellerAddress])) - sellerBefore,
        gross - expectedFee - expectedRoyalty,
      );
    });
  });

  describe("buyWithSignatureFor — private listing enforces intended recipient", async function () {
    it("succeeds when recipient matches listing.buyer, reverts otherwise", async function () {
      const { usdc, nft, market } = await deploy();
      const gross = 1_000n * 10n ** 6n;
      const tokenId = 1n;
      const otherAddress = walletOther.account.address;

      await nft.write.approve([market.address, tokenId], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      // Private listing: only walletOther may receive the NFT
      const listing: SignedListing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: gross,
        nonce: 3n,
        expiry: ts + 3600n,
        buyer: otherAddress,
      };
      const listingSig = await signListing(walletSeller, listing, market.address);

      // Calling with the wrong recipient should revert
      await assert.rejects(
        market.write.buyWithSignatureFor(
          [listing, listingSig, buyerAddress],
          { account: walletBuyer.account },
        ),
        /NotIntendedBuyer/,
      );

      // Calling with the correct recipient (walletBuyer pays, walletOther receives) succeeds
      await market.write.buyWithSignatureFor(
        [listing, listingSig, otherAddress],
        { account: walletBuyer.account },
      );

      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(otherAddress),
      );
    });
  });

  describe("buyWithSignatureFor — zero recipient reverts", async function () {
    it("reverts ZeroRecipient when recipient is address(0)", async function () {
      const { usdc, nft, market } = await deploy();
      const gross = 1_000n * 10n ** 6n;
      const tokenId = 1n;

      await nft.write.approve([market.address, tokenId], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      const listing: SignedListing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: gross,
        nonce: 4n,
        expiry: ts + 3600n,
        buyer: zeroAddress,
      };
      const listingSig = await signListing(walletSeller, listing, market.address);

      await assert.rejects(
        market.write.buyWithSignatureFor(
          [listing, listingSig, zeroAddress],
          { account: walletBuyer.account },
        ),
        /ZeroRecipient/,
      );
    });
  });

  describe("buyWithSignature — bad signature reverts", async function () {
    it("reverts InvalidSignature when sig was not made by listing.seller", async function () {
      const { usdc, nft, market } = await deploy();

      await nft.write.approve([market.address, 1n], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      const listing: SignedListing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId: 1n,
        paymentToken: usdc.address,
        price: 1_000n * 10n ** 6n,
        nonce: 5n,
        expiry: ts + 3600n,
        buyer: zeroAddress,
      };
      // Sign with walletBidder (not the seller)
      const badSig = await signListing(walletBidder, listing, market.address);

      await assert.rejects(
        market.write.buyWithSignature([listing, badSig], {
          account: walletBuyer.account,
        }),
        /InvalidSignature/,
      );
    });
  });

  describe("buyWithSignature — expired listing reverts", async function () {
    it("reverts Expired when block.timestamp > listing.expiry", async function () {
      const { usdc, nft, market } = await deploy();

      await nft.write.approve([market.address, 1n], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      const listing: SignedListing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId: 1n,
        paymentToken: usdc.address,
        price: 1_000n * 10n ** 6n,
        nonce: 6n,
        expiry: ts - 1n, // already expired
        buyer: zeroAddress,
      };
      const listingSig = await signListing(walletSeller, listing, market.address);

      await assert.rejects(
        market.write.buyWithSignature([listing, listingSig], {
          account: walletBuyer.account,
        }),
        /Expired/,
      );
    });
  });

  describe("buyWithSignature — nonce replay reverts", async function () {
    it("reverts NonceUsed on a second fill of the same signed listing", async function () {
      const { usdc, nft, market } = await deploy();
      const gross = 1_000n * 10n ** 6n;

      // Token 2 for the first fill; token 1 for the re-use attempt (same nonce)
      await nft.write.approve([market.address, 2n], {
        account: walletSeller.account,
      });

      const ts = await getBlockTimestamp();
      const listing: SignedListing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId: 2n,
        paymentToken: usdc.address,
        price: gross,
        nonce: 7n,
        expiry: ts + 3600n,
        buyer: zeroAddress,
      };
      const listingSig = await signListing(walletSeller, listing, market.address);

      // First fill succeeds
      await market.write.buyWithSignature([listing, listingSig], {
        account: walletBuyer.account,
      });

      // Attempting to use the same signature again must revert (nonce is now consumed)
      await assert.rejects(
        market.write.buyWithSignature([listing, listingSig], {
          account: walletBuyer.account,
        }),
        /NonceUsed/,
      );
    });
  });
});
