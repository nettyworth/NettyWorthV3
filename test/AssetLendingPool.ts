import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import {
  encodeFunctionData,
  toHex,
  keccak256,
  getAddress,
  type Address,
  type WalletClient,
} from "viem";

const FORWARDER = "0x1234567890123456789012345678901234567890" as `0x${string}`;
const LTV_BPS = 5000n; // 50%
const APPRAISAL_VALUE = 1000n * 10n ** 6n; // 1000 USDC (6 decimals)
const MAX_LOAN = (APPRAISAL_VALUE * LTV_BPS) / 10000n; // 500 USDC
const POOL_SEED = 10000n * 10n ** 6n; // 10k USDC

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

describe("AssetLendingPool", async function () {
  const { viem } = await network.create();
  const testClient = await viem.getTestClient();
  const publicClient = await viem.getPublicClient();
  const [walletAdmin, walletBorrower, walletSeller, walletOther] =
    await viem.getWalletClients();

  async function getBlockTimestamp(): Promise<bigint> {
    const block = await publicClient.getBlock({ blockTag: "latest" });
    return block.timestamp;
  }

  const adminAddress = walletAdmin.account.address;
  const borrowerAddress = walletBorrower.account.address;
  const sellerAddress = walletSeller.account.address;

  async function deploy() {
    // PermissionManager
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

    // MockERC20 (USDC)
    const usdc = await viem.deployContract("MockERC20");

    // AssetNFT
    const nftImpl = await viem.deployContract("AssetNFT", [FORWARDER]);
    const nftProxy = await viem.deployContract("ERC1967ProxyHelper", [
      nftImpl.address,
      encodeFunctionData({
        abi: nftImpl.abi,
        functionName: "initialize",
        args: [
          pm.address,
          "NettyWorth Assets",
          "NWA",
          "ipfs://contract",
          adminAddress,
          250n,
        ],
      }),
    ]);
    const nft = await viem.getContractAt("AssetNFT", nftProxy.address);

    // AssetLendingPool
    const poolImpl = await viem.deployContract("AssetLendingPool");
    const poolProxy = await viem.deployContract("ERC1967ProxyHelper", [
      poolImpl.address,
      encodeFunctionData({
        abi: poolImpl.abi,
        functionName: "initialize",
        // 80% lender share, 24h acquisition window, 7d auction window
        // Use address(1) for factory (no PackMachine tests in TS layer)
        args: [
          adminAddress,
          usdc.address,
          nft.address,
          LTV_BPS,
          8000n,
          BigInt(24 * 3600),
          BigInt(7 * 24 * 3600),
          "0x0000000000000000000000000000000000000001",
        ],
      }),
    ]);
    const pool = await viem.getContractAt(
      "AssetLendingPool",
      poolProxy.address,
    );

    // Roles: pool needs STATE_MANAGER_ROLE; admin needs MINTER_ROLE for test minting
    await pm.write.grantRole([STATE_MANAGER_ROLE, pool.address], {
      account: walletAdmin.account,
    });
    await pm.write.grantRole([MINTER_ROLE, adminAddress], {
      account: walletAdmin.account,
    });

    // Fund pool
    await usdc.write.mint([adminAddress, POOL_SEED]);
    await usdc.write.approve([pool.address, POOL_SEED], {
      account: walletAdmin.account,
    });
    await pool.write.deposit([POOL_SEED], { account: walletAdmin.account });

    // Set a fake marketplace address so financeMarketplacePurchase can verify listing sigs.
    // The address just needs to be deterministic — it forms part of the EIP-712 domain.
    const fakeMarketplace = "0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF" as Address;
    await pool.write.setMarketplace([fakeMarketplace], {
      account: walletAdmin.account,
    });

    return { pm, usdc, nft, pool, fakeMarketplace };
  }

  // ---------------------------------------------------------------------------
  // EIP-712 listing signing helpers
  // ---------------------------------------------------------------------------

  async function signListing(
    wallet: WalletClient,
    listing: {
      seller: Address;
      collection: Address;
      tokenId: bigint;
      paymentToken: Address;
      price: bigint;
      nonce: bigint;
      expiry: bigint;
    },
    marketplaceAddress: Address,
  ): Promise<`0x${string}`> {
    const chainId = await wallet.getChainId();
    return wallet.signTypedData({
      account: wallet.account!,
      domain: {
        name: "NettyWorthMarketplace",
        version: "1",
        chainId,
        verifyingContract: marketplaceAddress,
      },
      types: {
        SignedListing: [
          { name: "seller", type: "address" },
          { name: "collection", type: "address" },
          { name: "tokenId", type: "uint256" },
          { name: "paymentToken", type: "address" },
          { name: "price", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "expiry", type: "uint256" },
        ],
      },
      primaryType: "SignedListing",
      message: listing,
    });
  }

  async function mintNFT(
    nft: Awaited<ReturnType<typeof deploy>>["nft"],
    recipient: `0x${string}`,
  ) {
    const supply = await nft.read.totalSupply();
    const tokenId = supply + 1n;
    await nft.write.batchMint([[recipient], [""]], {
      account: walletAdmin.account,
    });
    return tokenId;
  }

  // =========================================================================
  // Deployment
  // =========================================================================

  describe("Deployment", async function () {
    it("sets owner and default terms", async function () {
      const { pool } = await deploy();
      assert.equal(
        getAddress(await pool.read.owner()),
        getAddress(adminAddress),
      );
      assert.equal((await pool.read.getPoolInfo()).ltvBps, LTV_BPS);

      const t0 = await pool.read.getTermConfig([0]);
      assert.equal(t0.duration, BigInt(7 * 24 * 3600));
      assert.equal(t0.aprBps, 1000n);
      assert.equal(t0.active, true);

      const t2 = await pool.read.getTermConfig([2]);
      assert.equal(t2.duration, BigInt(30 * 24 * 3600));
      assert.equal(t2.aprBps, 2000n);
    });

    it("reflects deposited liquidity", async function () {
      const { pool } = await deploy();
      assert.equal((await pool.read.getPoolInfo()).totalDeposited, POOL_SEED);
      assert.equal(await pool.read.getAvailableLiquidity(), POOL_SEED);
    });
  });

  // =========================================================================
  // borrow → repay
  // =========================================================================

  describe("borrow and repay", async function () {
    it("full cycle: borrow, NFT in Loaned state, repay, NFT returned", async function () {
      const { usdc, nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);

      // Appraise and approve
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });

      const borrowAmount = MAX_LOAN;
      const borrowerBefore = await usdc.read.balanceOf([borrowerAddress]);
      await pool.write.borrow([tokenId, borrowAmount, 0], {
        account: walletBorrower.account,
      });

      // NFT is now in pool, state = Loaned
      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(pool.address),
      );
      assert.equal(await nft.read.getAssetState([tokenId]), AssetState.Loaned);

      // Borrower received principal
      const borrowerAfter = await usdc.read.balanceOf([borrowerAddress]);
      assert.equal(borrowerAfter - borrowerBefore, borrowAmount);

      // Loan recorded
      const loanIds = await pool.read.getBorrowerLoans([borrowerAddress]);
      assert.equal(loanIds.length, 1);
      const loan = await pool.read.getLoan([loanIds[0]]);
      assert.equal(loan.principal, borrowAmount);
      assert.equal(
        loan.interest,
        (borrowAmount * 1000n * BigInt(7 * 24 * 3600)) /
          (BigInt(365 * 24 * 3600) * 10000n),
      ); // 10% APR × 7d
      assert.equal(loan.isPaid, false);

      // Repay
      const repayAmount = loan.principal + loan.interest;
      await usdc.write.mint([borrowerAddress, repayAmount]);
      await usdc.write.approve([pool.address, repayAmount], {
        account: walletBorrower.account,
      });
      await pool.write.repay([loanIds[0]], { account: walletBorrower.account });

      // NFT returned to borrower, state = Held
      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(borrowerAddress),
      );
      assert.equal(await nft.read.getAssetState([tokenId]), AssetState.Held);
      assert.equal((await pool.read.getLoan([loanIds[0]])).isPaid, true);

      // Interest tracked
      assert.equal(
        (await pool.read.getPoolInfo()).totalInterestEarned,
        loan.interest,
      );
    });

    it("reverts on insufficient LTV", async function () {
      const { nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });

      await assert.rejects(
        pool.write.borrow([tokenId, MAX_LOAN + 1n, 0], {
          account: walletBorrower.account,
        }),
      );
    });

    it("reverts with no appraisal", async function () {
      const { nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });

      await assert.rejects(
        pool.write.borrow([tokenId, 100n * 10n ** 6n, 0], {
          account: walletBorrower.account,
        }),
      );
    });

    it("allows repayment after expiry (grace period before liquidation)", async function () {
      const { usdc, nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });

      const borrowAmount = 200n * 10n ** 6n;
      await pool.write.borrow([tokenId, borrowAmount, 0], {
        account: walletBorrower.account,
      });
      const loanIds = await pool.read.getBorrowerLoans([borrowerAddress]);
      const loan = await pool.read.getLoan([loanIds[0]]);

      const repayAmount = loan.principal + loan.interest;
      await usdc.write.mint([borrowerAddress, repayAmount]);
      await usdc.write.approve([pool.address, repayAmount], {
        account: walletBorrower.account,
      });

      // Should still succeed after expiry
      await pool.write.repay([loanIds[0]], { account: walletBorrower.account });
      assert.equal((await pool.read.getLoan([loanIds[0]])).isPaid, true);
    });
  });

  // =========================================================================
  // liquidate
  // =========================================================================

  describe("liquidate", async function () {
    it("owner claims NFT after expiry", async function () {
      const { nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });
      await pool.write.borrow([tokenId, MAX_LOAN, 0], {
        account: walletBorrower.account,
      });

      const loanId = (await pool.read.getBorrowerLoans([borrowerAddress]))[0];
      const loan = await pool.read.getLoan([loanId]);

      // Warp past expiry (Hardhat network allows time manipulation)
      await testClient.increaseTime({ seconds: Number(loan.expireTime) + 100 });
      await testClient.mine({ blocks: 1 });

      await pool.write.liquidate([loanId], { account: walletAdmin.account });

      assert.equal((await pool.read.getLoan([loanId])).isDefaulted, true);
      // NFT stays in pool, state = Held
      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(pool.address),
      );
      assert.equal(await nft.read.getAssetState([tokenId]), AssetState.Held);
    });

    it("rescueNFT transfers defaulted NFT to recipient", async function () {
      const { nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });
      await pool.write.borrow([tokenId, MAX_LOAN, 0], {
        account: walletBorrower.account,
      });

      const loanId = (await pool.read.getBorrowerLoans([borrowerAddress]))[0];
      const loan = await pool.read.getLoan([loanId]);

      await testClient.increaseTime({ seconds: Number(loan.expireTime) + 100 });
      await testClient.mine({ blocks: 1 });

      await pool.write.liquidate([loanId], { account: walletAdmin.account });
      await pool.write.rescueNFT([tokenId, adminAddress], {
        account: walletAdmin.account,
      });

      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(adminAddress),
      );
    });
  });

  // =========================================================================
  // financeMarketplacePurchase
  // =========================================================================

  describe("financeMarketplacePurchase", async function () {
    it("seller receives listing price, NFT loaned to buyer, repay returns NFT", async function () {
      const { usdc, nft, pool, fakeMarketplace } = await deploy();
      const tokenId = await mintNFT(nft, sellerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });

      // Seller approves pool for all so pool can pull the NFT
      await nft.write.setApprovalForAll([pool.address, true], {
        account: walletSeller.account,
      });

      const listingPrice = APPRAISAL_VALUE; // 1000 USDC
      const depositAmount = MAX_LOAN; // 500 USDC (50%)
      const loanAmount = listingPrice - depositAmount; // 500 USDC
      const expiry = (await getBlockTimestamp()) + 30n * 24n * 3600n;

      const listing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: listingPrice,
        nonce: 1n,
        expiry,
      };
      const sig = await signListing(walletSeller, listing, fakeMarketplace);

      await usdc.write.mint([borrowerAddress, depositAmount]);
      await usdc.write.approve([pool.address, depositAmount], {
        account: walletBorrower.account,
      });

      const sellerBefore = await usdc.read.balanceOf([sellerAddress]);
      await pool.write.financeMarketplacePurchase(
        [listing, sig, depositAmount, 0],
        { account: walletBorrower.account },
      );

      // Seller received full listing price
      assert.equal(
        (await usdc.read.balanceOf([sellerAddress])) - sellerBefore,
        listingPrice,
      );
      // NFT in pool, Loaned
      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(pool.address),
      );
      assert.equal(await nft.read.getAssetState([tokenId]), AssetState.Loaned);

      // Loan correct
      const loanId = (await pool.read.getBorrowerLoans([borrowerAddress]))[0];
      const loan = await pool.read.getLoan([loanId]);
      assert.equal(loan.principal, loanAmount);
      assert.equal(loan.isMarketplaceFinanced, true);

      // Repay → NFT goes to buyer
      const repayAmount = loan.principal + loan.interest;
      await usdc.write.mint([borrowerAddress, repayAmount]);
      await usdc.write.approve([pool.address, repayAmount], {
        account: walletBorrower.account,
      });
      await pool.write.repay([loanId], { account: walletBorrower.account });

      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(borrowerAddress),
      );
    });

    it("reverts if deposit too high (loanAmount == 0)", async function () {
      const { usdc, nft, pool, fakeMarketplace } = await deploy();
      const tokenId = await mintNFT(nft, sellerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.setApprovalForAll([pool.address, true], {
        account: walletSeller.account,
      });

      const expiry = (await getBlockTimestamp()) + 30n * 24n * 3600n;
      const listing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: APPRAISAL_VALUE,
        nonce: 1n,
        expiry,
      };
      const sig = await signListing(walletSeller, listing, fakeMarketplace);

      // Pay the full price — loanAmount = 0, reverts ZeroAmount
      await usdc.write.mint([borrowerAddress, APPRAISAL_VALUE]);
      await usdc.write.approve([pool.address, APPRAISAL_VALUE], {
        account: walletBorrower.account,
      });

      await assert.rejects(
        pool.write.financeMarketplacePurchase(
          [listing, sig, APPRAISAL_VALUE, 0],
          { account: walletBorrower.account },
        ),
      );
    });

    it("reverts if loan exceeds LTV (deposit too low)", async function () {
      const { usdc, nft, pool, fakeMarketplace } = await deploy();
      const tokenId = await mintNFT(nft, sellerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.setApprovalForAll([pool.address, true], {
        account: walletSeller.account,
      });

      const expiry = (await getBlockTimestamp()) + 30n * 24n * 3600n;
      const listing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: APPRAISAL_VALUE,
        nonce: 1n,
        expiry,
      };
      const sig = await signListing(walletSeller, listing, fakeMarketplace);

      // Deposit < MIN (500) → loanAmount > maxLoan → ExceedsLTV
      const tooLow = MAX_LOAN - 1n;
      await usdc.write.mint([borrowerAddress, tooLow]);
      await usdc.write.approve([pool.address, tooLow], {
        account: walletBorrower.account,
      });

      await assert.rejects(
        pool.write.financeMarketplacePurchase(
          [listing, sig, tooLow, 0],
          { account: walletBorrower.account },
        ),
      );
    });

    it("reverts if signature is invalid", async function () {
      const { usdc, nft, pool, fakeMarketplace } = await deploy();
      const tokenId = await mintNFT(nft, sellerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.setApprovalForAll([pool.address, true], {
        account: walletSeller.account,
      });

      const expiry = (await getBlockTimestamp()) + 30n * 24n * 3600n;
      const listing = {
        seller: sellerAddress,
        collection: nft.address,
        tokenId,
        paymentToken: usdc.address,
        price: APPRAISAL_VALUE,
        nonce: 1n,
        expiry,
      };
      // Sign with admin wallet (wrong signer)
      const badSig = await signListing(walletAdmin, listing, fakeMarketplace);

      await usdc.write.mint([borrowerAddress, MAX_LOAN]);
      await usdc.write.approve([pool.address, MAX_LOAN], {
        account: walletBorrower.account,
      });

      await assert.rejects(
        pool.write.financeMarketplacePurchase(
          [listing, badSig, MAX_LOAN, 0],
          { account: walletBorrower.account },
        ),
      );
    });
  });

  // =========================================================================
  // Admin operations
  // =========================================================================

  describe("admin operations", async function () {
    it("withdraw reduces totalDeposited", async function () {
      const { pool } = await deploy();
      const before = (await pool.read.getPoolInfo()).totalDeposited;
      await pool.write.withdraw([100n * 10n ** 6n], {
        account: walletAdmin.account,
      });
      assert.equal(
        (await pool.read.getPoolInfo()).totalDeposited,
        before - 100n * 10n ** 6n,
      );
    });

    it("withdrawInterest after repayment", async function () {
      const { usdc, nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });
      await pool.write.borrow([tokenId, MAX_LOAN, 0], {
        account: walletBorrower.account,
      });

      const loanId = (await pool.read.getBorrowerLoans([borrowerAddress]))[0];
      const loan = await pool.read.getLoan([loanId]);
      const repayAmount = loan.principal + loan.interest;
      await usdc.write.mint([borrowerAddress, repayAmount]);
      await usdc.write.approve([pool.address, repayAmount], {
        account: walletBorrower.account,
      });
      await pool.write.repay([loanId], { account: walletBorrower.account });

      const earned = (await pool.read.getPoolInfo()).totalInterestEarned;
      assert.equal(earned, loan.interest);

      const adminBefore = await usdc.read.balanceOf([adminAddress]);
      await pool.write.withdrawInterest([earned], {
        account: walletAdmin.account,
      });
      assert.equal(
        (await usdc.read.balanceOf([adminAddress])) - adminBefore,
        earned,
      );
    });

    it("origination fee deducted from disbursement", async function () {
      const { usdc, nft, pool } = await deploy();
      const feeWallet = walletOther.account.address;
      await pool.write.setOriginationFee([200n, feeWallet], {
        account: walletAdmin.account,
      }); // 2%

      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });

      const borrowAmount = 400n * 10n ** 6n;
      const expectedFee = (borrowAmount * 200n) / 10000n;
      const expectedDisbursement = borrowAmount - expectedFee;

      const borrowerBefore = await usdc.read.balanceOf([borrowerAddress]);
      await pool.write.borrow([tokenId, borrowAmount, 0], {
        account: walletBorrower.account,
      });

      assert.equal(
        (await usdc.read.balanceOf([borrowerAddress])) - borrowerBefore,
        expectedDisbursement,
      );
      assert.equal(await usdc.read.balanceOf([feeWallet]), expectedFee);
    });

    it("pause blocks borrow", async function () {
      const { nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await pool.write.pause({ account: walletAdmin.account });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });

      await assert.rejects(
        pool.write.borrow([tokenId, 100n * 10n ** 6n, 0], {
          account: walletBorrower.account,
        }),
      );
    });
  });

  // =========================================================================
  // Appraisal staleness
  // =========================================================================

  describe("appraisal staleness", async function () {
    const SEVEN_DAYS = 7 * 24 * 3600;

    it("default maxAppraisalAge is 7 days", async function () {
      const { pool } = await deploy();
      assert.equal(
        (await pool.read.getPoolInfo()).maxAppraisalAge,
        BigInt(SEVEN_DAYS),
      );
    });

    it("setMaxAppraisalAge updates value", async function () {
      const { pool } = await deploy();
      await pool.write.setMaxAppraisalAge([BigInt(SEVEN_DAYS * 2)], {
        account: walletAdmin.account,
      });
      assert.equal(
        (await pool.read.getPoolInfo()).maxAppraisalAge,
        BigInt(SEVEN_DAYS * 2),
      );
    });

    it("borrow reverts when appraisal is stale", async function () {
      const { nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });

      await testClient.increaseTime({ seconds: SEVEN_DAYS + 1 });
      await testClient.mine({ blocks: 1 });

      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });
      await assert.rejects(
        pool.write.borrow([tokenId, 100n * 10n ** 6n, 0], {
          account: walletBorrower.account,
        }),
      );
    });

    it("borrow succeeds after appraisal is refreshed", async function () {
      const { nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });

      await testClient.increaseTime({ seconds: SEVEN_DAYS + 1 });
      await testClient.mine({ blocks: 1 });

      // Refresh appraisal
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });

      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });
      await pool.write.borrow([tokenId, 100n * 10n ** 6n, 0], {
        account: walletBorrower.account,
      });
    });

    it("setMaxAppraisalAge(0) disables check even with very stale appraisal", async function () {
      const { nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });

      await pool.write.setMaxAppraisalAge([0n], {
        account: walletAdmin.account,
      });

      await testClient.increaseTime({ seconds: 365 * 24 * 3600 });
      await testClient.mine({ blocks: 1 });

      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });
      await pool.write.borrow([tokenId, 100n * 10n ** 6n, 0], {
        account: walletBorrower.account,
      });
    });

    it("isEligible is unaffected by staleness", async function () {
      const { nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });

      await testClient.increaseTime({ seconds: SEVEN_DAYS + 1 });
      await testClient.mine({ blocks: 1 });

      assert.equal(await pool.read.isEligible([tokenId]), true);
    });
  });

  // =========================================================================
  // Lender capital (V2)
  // =========================================================================

  const [, , , , walletLender1, walletLender2] = await viem.getWalletClients();
  const lender1Address = walletLender1.account.address;
  const lender2Address = walletLender2.account.address;

  describe("lender capital", async function () {
    it("lenderDeposit increases totalDeposited and lender balance", async function () {
      const { usdc, pool } = await deploy();
      await pool.write.setLenderConfig([8000n, true], {
        account: walletAdmin.account,
      });

      const depositAmt = 1000n * 10n ** 6n;
      await usdc.write.mint([lender1Address, depositAmt]);
      await usdc.write.approve([pool.address, depositAmt], {
        account: walletLender1.account,
      });
      await pool.write.lenderDeposit([depositAmt], {
        account: walletLender1.account,
      });

      const info = await pool.read.getLenderInfo([lender1Address]);
      assert.equal(info.deposited, depositAmt);
      assert.equal(
        (await pool.read.getPoolInfo()).totalDeposited,
        POOL_SEED + depositAmt,
      );
    });

    it("lenderWithdraw reverts when capital is locked in loans", async function () {
      const { usdc, nft, pool } = await deploy();
      await pool.write.setLenderConfig([8000n, true], {
        account: walletAdmin.account,
      });

      const depositAmt = 1000n * 10n ** 6n;
      await usdc.write.mint([lender1Address, depositAmt]);
      await usdc.write.approve([pool.address, depositAmt], {
        account: walletLender1.account,
      });
      await pool.write.lenderDeposit([depositAmt], {
        account: walletLender1.account,
      });

      // Temporarily disable utilization cap so the precondition borrow can fill the pool.
      await pool.write.setMaxUtilizationBps([10_000n], {
        account: walletAdmin.account,
      });

      // Borrow all available liquidity
      const tokenId = await mintNFT(nft, borrowerAddress);
      const bigVal = (POOL_SEED + depositAmt) * 3n;
      await pool.write.setAppraisal([tokenId, bigVal, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });
      await pool.write.borrow([tokenId, POOL_SEED + depositAmt, 0], {
        account: walletBorrower.account,
      });

      // Lender can't withdraw
      await assert.rejects(
        pool.write.lenderWithdraw([depositAmt], {
          account: walletLender1.account,
        }),
      );
    });

    it("lender earns 80% of interest on repay", async function () {
      const { usdc, nft, pool } = await deploy();
      await pool.write.setLenderConfig([8000n, true], {
        account: walletAdmin.account,
      });

      const depositAmt = POOL_SEED;
      await usdc.write.mint([lender1Address, depositAmt]);
      await usdc.write.approve([pool.address, depositAmt], {
        account: walletLender1.account,
      });
      await pool.write.lenderDeposit([depositAmt], {
        account: walletLender1.account,
      });

      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });
      await pool.write.borrow([tokenId, MAX_LOAN, 0], {
        account: walletBorrower.account,
      });

      const loanId = (await pool.read.getBorrowerLoans([borrowerAddress]))[0];
      const loan = await pool.read.getLoan([loanId]);
      const repayAmount = loan.principal + loan.interest;
      await usdc.write.mint([borrowerAddress, repayAmount]);
      await usdc.write.approve([pool.address, repayAmount], {
        account: walletBorrower.account,
      });
      await pool.write.repay([loanId], { account: walletBorrower.account });

      const expectedLenderInterest = (loan.interest * 8000n) / 10000n;
      const info = await pool.read.getLenderInfo([lender1Address]);
      assert.equal(info.claimableInterest, expectedLenderInterest);

      // Claim
      const lender1Before = await usdc.read.balanceOf([lender1Address]);
      await pool.write.claimLenderInterest({
        account: walletLender1.account,
      });
      assert.equal(
        (await usdc.read.balanceOf([lender1Address])) - lender1Before,
        expectedLenderInterest,
      );
      assert.equal(
        (await pool.read.getLenderInfo([lender1Address])).claimableInterest,
        0n,
      );
    });
  });

  // =========================================================================
  // Default lifecycle (V2)
  // =========================================================================

  describe("default lifecycle", async function () {
    const ACQUISITION_WINDOW = 24 * 3600;
    const AUCTION_WINDOW = 7 * 24 * 3600;

    async function createDefaultedLoan(
      usdc: Awaited<ReturnType<typeof deploy>>["usdc"],
      nft: Awaited<ReturnType<typeof deploy>>["nft"],
      pool: Awaited<ReturnType<typeof deploy>>["pool"],
      principal: bigint,
    ) {
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, APPRAISAL_VALUE, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });
      await pool.write.borrow([tokenId, principal, 0], {
        account: walletBorrower.account,
      });
      const loanId = (await pool.read.getBorrowerLoans([borrowerAddress]))[
        (await pool.read.getBorrowerLoans([borrowerAddress])).length - 1
      ];
      const loan = await pool.read.getLoan([loanId]);
      await testClient.increaseTime({
        seconds: Number(loan.expireTime) + 100,
      });
      await testClient.mine({ blocks: 1 });
      await pool.write.initiateDefault([loanId], {
        account: walletAdmin.account,
      });
      return { loanId, tokenId };
    }

    it("initiateDefault creates default record and tracks principal", async function () {
      const { usdc, nft, pool } = await deploy();
      const principal = 400n * 10n ** 6n;
      const { loanId, tokenId } = await createDefaultedLoan(
        usdc,
        nft,
        pool,
        principal,
      );

      const rec = await pool.read.getDefaultRecord([loanId]);
      assert.equal(rec.tokenIds[0], tokenId);
      assert.equal(rec.outstandingValue, principal);
      assert.equal(rec.resolved, false);

      assert.equal(
        (await pool.read.getPoolInfo()).totalDefaultedPrincipal,
        principal,
      );
      // Phase = Acquisition (0 = None, 1 = Acquisition)
      assert.equal(await pool.read.getDefaultPhase([loanId]), 1);
    });

    it("phase transitions to Auction after acquisition window", async function () {
      const { usdc, nft, pool } = await deploy();
      const { loanId } = await createDefaultedLoan(
        usdc,
        nft,
        pool,
        400n * 10n ** 6n,
      );

      await testClient.increaseTime({ seconds: ACQUISITION_WINDOW + 1 });
      await testClient.mine({ blocks: 1 });
      // Phase = Auction (2)
      assert.equal(await pool.read.getDefaultPhase([loanId]), 2);
    });

    it("phase transitions to FixedListing after auction window", async function () {
      const { usdc, nft, pool } = await deploy();
      const { loanId } = await createDefaultedLoan(
        usdc,
        nft,
        pool,
        400n * 10n ** 6n,
      );

      await testClient.increaseTime({
        seconds: ACQUISITION_WINDOW + AUCTION_WINDOW + 1,
      });
      await testClient.mine({ blocks: 1 });
      // Phase = FixedListing (3)
      assert.equal(await pool.read.getDefaultPhase([loanId]), 3);
    });

    it("purchaseDefaultedAsset in Phase 2 restores pool capital", async function () {
      const { usdc, nft, pool } = await deploy();
      const principal = 400n * 10n ** 6n;
      const { loanId, tokenId } = await createDefaultedLoan(
        usdc,
        nft,
        pool,
        principal,
      );

      const depositedBefore = (await pool.read.getPoolInfo()).totalDeposited;

      // Advance to Phase 2
      await testClient.increaseTime({ seconds: ACQUISITION_WINDOW + 1 });
      await testClient.mine({ blocks: 1 });

      const buyer = walletOther.account.address;
      await usdc.write.mint([buyer, principal]);
      await usdc.write.approve([pool.address, principal], {
        account: walletOther.account,
      });
      await pool.write.purchaseDefaultedAsset([loanId], {
        account: walletOther.account,
      });

      // NFT transferred to buyer
      assert.equal(
        getAddress(await nft.read.ownerOf([tokenId])),
        getAddress(buyer),
      );
      // Pool made whole
      assert.equal(
        (await pool.read.getPoolInfo()).totalDeposited,
        depositedBefore + principal,
      );
      assert.equal(
        (await pool.read.getPoolInfo()).totalDefaultedPrincipal,
        0n,
      );
      // Resolved
      assert.equal(await pool.read.getDefaultPhase([loanId]), 4); // Resolved
    });

    it("purchaseDefaultedAsset reverts in Phase 1", async function () {
      const { usdc, nft, pool } = await deploy();
      const { loanId } = await createDefaultedLoan(
        usdc,
        nft,
        pool,
        400n * 10n ** 6n,
      );

      await assert.rejects(
        pool.write.purchaseDefaultedAsset([loanId], {
          account: walletOther.account,
        }),
      );
    });
  });

  // =========================================================================
  // $100 default minimum appraisal value
  // =========================================================================

  describe("$100 default minimum appraisal", async function () {
    it("minAppraisalValue defaults to 100e6 on deployment", async function () {
      const { pool } = await deploy();
      assert.equal((await pool.read.getPoolInfo()).minAppraisalValue, 100n * 10n ** 6n);
    });

    it("borrow reverts if appraisal is below the $100 default", async function () {
      const { usdc: _usdc, nft, pool } = await deploy();
      const tokenId = await mintNFT(nft, borrowerAddress);
      await pool.write.setAppraisal([tokenId, 50n * 10n ** 6n, 0n, 0n], {
        account: walletAdmin.account,
      });
      await nft.write.approve([pool.address, tokenId], {
        account: walletBorrower.account,
      });
      await assert.rejects(
        pool.write.borrow([tokenId, 25n * 10n ** 6n, 0], {
          account: walletBorrower.account,
        }),
      );
    });
  });

  // =========================================================================
  // borrowBundle
  // =========================================================================

  describe("borrowBundle", async function () {
    it("happy path: 3-token bundle borrow then repay", async function () {
      const { usdc, nft, pool } = await deploy();

      const t1 = await mintNFT(nft, borrowerAddress);
      const t2 = await mintNFT(nft, borrowerAddress);
      const t3 = await mintNFT(nft, borrowerAddress);

      // Appraise each at 1000 USDC → summed 3000, max loan 1500
      for (const id of [t1, t2, t3]) {
        await pool.write.setAppraisal([id, APPRAISAL_VALUE, 0n, 0n], {
          account: walletAdmin.account,
        });
        await nft.write.approve([pool.address, id], {
          account: walletBorrower.account,
        });
      }

      const borrowAmount = 1200n * 10n ** 6n;
      await pool.write.borrowBundle([[t1, t2, t3], borrowAmount, 0], {
        account: walletBorrower.account,
      });

      // Pool owns all three NFTs
      assert.equal(getAddress(await nft.read.ownerOf([t1])), getAddress(pool.address));
      assert.equal(getAddress(await nft.read.ownerOf([t2])), getAddress(pool.address));
      assert.equal(getAddress(await nft.read.ownerOf([t3])), getAddress(pool.address));

      // Single loan with 3 tokenIds
      const loanIds = await pool.read.getBorrowerLoans([borrowerAddress]);
      assert.equal(loanIds.length, 1);
      const loan = await pool.read.getLoan([loanIds[0]]);
      assert.equal(loan.tokenIds.length, 3);
      assert.equal(loan.principal, borrowAmount);

      // getLoanTokenIds view
      const fetched = await pool.read.getLoanTokenIds([loanIds[0]]);
      assert.equal(fetched.length, 3);

      // Repay
      const repayAmount = borrowAmount + loan.interest;
      await usdc.write.mint([borrowerAddress, repayAmount]);
      await usdc.write.approve([pool.address, repayAmount], {
        account: walletBorrower.account,
      });
      await pool.write.repay([loanIds[0]], { account: walletBorrower.account });

      // All NFTs returned
      assert.equal(getAddress(await nft.read.ownerOf([t1])), getAddress(borrowerAddress));
      assert.equal(getAddress(await nft.read.ownerOf([t2])), getAddress(borrowerAddress));
      assert.equal(getAddress(await nft.read.ownerOf([t3])), getAddress(borrowerAddress));
      assert.equal((await pool.read.getLoan([loanIds[0]])).isPaid, true);
    });

    it("reverts with EmptyBundle if tokenIds array is empty", async function () {
      const { pool } = await deploy();
      await assert.rejects(
        pool.write.borrowBundle([[], 100n * 10n ** 6n, 0], {
          account: walletBorrower.account,
        }),
      );
    });
  });
});
