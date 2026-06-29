import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import {
  encodeFunctionData,
  toHex,
  keccak256,
  hashStruct,
  getAddress,
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
  ] = await viem.getWalletClients();

  const adminAddress = walletAdmin.account.address;
  const sellerAddress = walletSeller.account.address;
  const bidderAddress = walletBidder.account.address;
  const bidder2Address = walletBidder2.account.address;
  const operatorAddress = walletOperator.account.address;

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

  // auctionId = bare EIP-712 struct hash (NOT the full typed-data digest)
  // This must match what the contract stores: _hashAuction() = keccak256(abi.encode(typehash, ...))
  function computeAuctionId(auction: SignedAuction): `0x${string}` {
    return hashStruct({
      primaryType: "SignedAuction",
      types: SIGNED_AUCTION_TYPES,
      data: auction,
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

    // 4. AssetLendingPool
    //    For auction flow tests, the factory only needs isPackMachine() — use MockPackMachineFactory.
    const factory = await viem.deployContract(
      "contracts/test-helpers/MockPackMachineFactory.sol:MockPackMachineFactory",
    );
    const poolImpl = await viem.deployContract("AssetLendingPool");
    const poolProxy = await viem.deployContract("ERC1967ProxyHelper", [
      poolImpl.address,
      encodeFunctionData({
        abi: poolImpl.abi,
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
    // Pool: grant STATE_MANAGER_ROLE, authorize marketplace
    await pm.write.grantRole([STATE_MANAGER_ROLE, pool.address], {
      account: walletAdmin.account,
    });
    await pool.write.setMarketplace([market.address], {
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

    // Set appraisals (category 0 = uncategorized)
    await pool.write.setAppraisal([1n, APPRAISAL, 80n, 0n], {
      account: walletAdmin.account,
    });
    await pool.write.setAppraisal([2n, APPRAISAL, 80n, 0n], {
      account: walletAdmin.account,
    });

    // Pre-fund bidder and operator; pre-approve marketplace
    for (const [addr, wallet] of [
      [bidderAddress, walletBidder],
      [bidder2Address, walletBidder2],
      [operatorAddress, walletOperator],
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
      const auctionId = computeAuctionId(auction);
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
      const auctionId = computeAuctionId(auction);
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
      const auctionId = computeAuctionId(auction);
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
      const auctionId = computeAuctionId(auction);
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
      const auctionId = computeAuctionId(auction);
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
      const auctionId = computeAuctionId(auction);
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
      const auctionId = computeAuctionId(auction);
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

      // ---- Step 3: operator purchases the defaulted asset ----
      // DefaultRecord.outstandingValue == principal (interest not included in default record)
      const rec = await pool.read.getDefaultRecord([loanId]);
      const claimPrice = rec.outstandingValue;

      await usdc.write.approve([pool.address, claimPrice], {
        account: walletOperator.account,
      });
      await pool.write.purchaseDefaultedAsset([loanId], {
        account: walletOperator.account,
      });

      // Operator now owns token 1 in Held state
      assert.equal(
        getAddress(await nft.read.ownerOf([1n])),
        getAddress(operatorAddress),
      );
      assert.equal(await nft.read.getAssetState([1n]), AssetState.Held);

      // ---- Step 4: operator lists at auction (reserve = outstanding principal+interest) ----
      await nft.write.approve([market.address, 1n], {
        account: walletOperator.account,
      });

      const auctionStart = await getBlockTimestamp();
      const auction: SignedAuction = {
        seller: operatorAddress,
        collection: nft.address,
        tokenId: 1n,
        paymentToken: usdc.address,
        reservePrice: outstanding,
        minIncrement: MIN_INCREMENT,
        startTime: auctionStart,
        endTime: auctionStart + 86400n,
        extensionWindow: EXTENSION_WINDOW,
        extensionDuration: EXTENSION_DURATION,
        nonce: 1n,
      };
      const auctionId = computeAuctionId(auction);
      const auctionSig = await signAuction(
        walletOperator,
        auction,
        market.address,
      );

      // ---- Step 5: bidder commits a winning bid ----
      const bidAmount = outstanding + 50n * 10n ** 6n;
      const bid: SignedBid = {
        auctionId,
        bidder: bidderAddress,
        amount: bidAmount,
        nonce: 1n,
        expiry: auctionStart + 2n * 86400n,
      };
      const bidSig = await signBid(walletBidder, bid, market.address);

      const operatorBefore = await usdc.read.balanceOf([operatorAddress]);
      const bidderTokensBefore = await usdc.read.balanceOf([bidderAddress]);
      const treasuryBefore = await usdc.read.balanceOf([treasuryAddress]);

      await market.write.commitBid([auction, auctionSig, bid, bidSig], {
        account: walletBidder.account,
      });

      // ---- Step 6: settle after end ----
      await testClient.increaseTime({ seconds: 86401 });
      await testClient.mine({ blocks: 1 });

      await market.write.settleAuction([auctionId], {
        account: walletOther.account,
      });

      // NFT delivered to bidder in Held state
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

      // Treasury received collectible fee (5% of bidAmount)
      const expectedFee = (bidAmount * 500n) / 10_000n;
      assert.equal(
        await usdc.read.balanceOf([treasuryAddress]),
        treasuryBefore + expectedFee,
      );

      // Operator received net proceeds (bid - fee - royalty)
      const operatorAfter = await usdc.read.balanceOf([operatorAddress]);
      assert.ok(operatorAfter > operatorBefore);

      // Auction settled
      assert.equal((await market.read.getAuction([auctionId])).settled, true);
    });
  });
});
