import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { network } from "hardhat";
import { encodeFunctionData, getAddress } from "viem";

// AssetType and TradeStatus enum values mirrored from IP2PTradeEscrow.sol
const AssetType = {
  ERC20: 0,
  ERC721: 1,
  ERC1155: 2,
} as const;

const TradeStatus = {
  Active: 0,
  Accepted: 1,
  Cancelled: 2,
  Expired: 3,
} as const;

const USDC_AMOUNT = 500n * 10n ** 6n; // 500 USDC (6 decimals)
const DAI_AMOUNT = 1000n * 10n ** 18n; // 1000 DAI (18 decimals)
const ERC1155_ID = 10n;
const ERC1155_AMOUNT = 5n;
const TOKEN_ID_1 = 1n;
const TOKEN_ID_2 = 2n;

describe("P2PTradeEscrow", async function () {
  const { viem } = await network.create();
  const testClient = await viem.getTestClient();
  const [walletAdmin, walletAlice, walletBob, walletCarol] =
    await viem.getWalletClients();

  const adminAddress = walletAdmin.account.address;
  const aliceAddress = walletAlice.account.address;
  const bobAddress = walletBob.account.address;
  const carolAddress = walletCarol.account.address;

  async function deploy() {
    // MockERC20 (USDC, 6 decimals)
    const usdc = await viem.deployContract("MockERC20");
    // MockERC20 (DAI, 18 decimals) — we override MockERC20 for both; DAI decimals differ
    // but for swap purposes we just need two distinct ERC20s.
    const dai = await viem.deployContract("MockERC20");

    // MockERC721
    const nft = await viem.deployContract("MockERC721");

    // MockERC1155
    const erc1155 = await viem.deployContract("MockERC1155");

    // P2PTradeEscrow — deploy impl + proxy
    const escrowImpl = await viem.deployContract("P2PTradeEscrow");
    const escrowProxy = await viem.deployContract("ERC1967ProxyHelper", [
      escrowImpl.address,
      encodeFunctionData({
        abi: escrowImpl.abi,
        functionName: "initialize",
        args: [adminAddress],
      }),
    ]);
    const escrow = await viem.getContractAt(
      "P2PTradeEscrow",
      escrowProxy.address,
    );

    // ── Setup: mint assets to alice ──
    await nft.write.mint([aliceAddress, TOKEN_ID_1]);
    await usdc.write.mint([aliceAddress, USDC_AMOUNT]);
    await erc1155.write.mint([aliceAddress, ERC1155_ID, ERC1155_AMOUNT]);

    // ── Setup: mint assets to bob ──
    await nft.write.mint([bobAddress, TOKEN_ID_2]);
    await usdc.write.mint([bobAddress, USDC_AMOUNT]);
    await dai.write.mint([bobAddress, DAI_AMOUNT]);
    await erc1155.write.mint([bobAddress, ERC1155_ID, ERC1155_AMOUNT]);

    // ── Approvals: alice → escrow ──
    await nft.write.approve([escrow.address, TOKEN_ID_1], {
      account: walletAlice.account,
    });
    await usdc.write.approve([escrow.address, 2n ** 256n - 1n], {
      account: walletAlice.account,
    });
    await erc1155.write.setApprovalForAll([escrow.address, true], {
      account: walletAlice.account,
    });

    // ── Approvals: bob → escrow ──
    await nft.write.approve([escrow.address, TOKEN_ID_2], {
      account: walletBob.account,
    });
    await usdc.write.approve([escrow.address, 2n ** 256n - 1n], {
      account: walletBob.account,
    });
    await dai.write.approve([escrow.address, 2n ** 256n - 1n], {
      account: walletBob.account,
    });
    await erc1155.write.setApprovalForAll([escrow.address, true], {
      account: walletBob.account,
    });

    return { escrow, usdc, dai, nft, erc1155 };
  }

  // ── asset helpers ──
  function nftAsset(token: `0x${string}`, tokenId: bigint) {
    return {
      assetType: AssetType.ERC721,
      token,
      tokenId,
      amount: 0n,
    };
  }

  function erc20Asset(token: `0x${string}`, amount: bigint) {
    return { assetType: AssetType.ERC20, token, tokenId: 0n, amount };
  }

  function erc1155Asset(
    token: `0x${string}`,
    tokenId: bigint,
    amount: bigint,
  ) {
    return { assetType: AssetType.ERC1155, token, tokenId, amount };
  }

  // =========================================================================
  // Happy path: ERC721 ↔ ERC20
  // =========================================================================

  it("createTrade + acceptTrade: NFT ↔ ERC20", async () => {
    const { escrow, usdc, nft } = await deploy();

    const tx = await escrow.write.createTrade(
      [bobAddress, [nftAsset(nft.address, TOKEN_ID_1)], [erc20Asset(usdc.address, USDC_AMOUNT)], 0n],
      { account: walletAlice.account },
    );

    // NFT should be in escrow
    const owner = await nft.read.ownerOf([TOKEN_ID_1]);
    assert.equal(getAddress(owner), getAddress(escrow.address));

    // nextTradeId should now be 1
    assert.equal(await escrow.read.nextTradeId(), 1n);

    // Bob accepts
    await escrow.write.acceptTrade([0n], { account: walletBob.account });

    // Bob gets NFT; Alice started with USDC_AMOUNT and received USDC_AMOUNT from Bob = 2×.
    assert.equal(
      getAddress(await nft.read.ownerOf([TOKEN_ID_1])),
      getAddress(bobAddress),
    );
    assert.equal(await usdc.read.balanceOf([aliceAddress]), USDC_AMOUNT * 2n);
    assert.equal(await usdc.read.balanceOf([bobAddress]), 0n);

    const trade = await escrow.read.getTrade([0n]);
    assert.equal(trade.status, TradeStatus.Accepted);
  });

  // =========================================================================
  // Happy path: asset+USDC ↔ asset
  // =========================================================================

  it("createTrade + acceptTrade: NFT+USDC ↔ NFT", async () => {
    const { escrow, usdc, nft } = await deploy();

    const offered = [
      nftAsset(nft.address, TOKEN_ID_1),
      erc20Asset(usdc.address, USDC_AMOUNT),
    ];
    const requested = [nftAsset(nft.address, TOKEN_ID_2)];

    await escrow.write.createTrade([bobAddress, offered, requested, 0n], {
      account: walletAlice.account,
    });

    // Escrow holds NFT #1 and USDC
    assert.equal(
      getAddress(await nft.read.ownerOf([TOKEN_ID_1])),
      getAddress(escrow.address),
    );
    assert.equal(await usdc.read.balanceOf([escrow.address]), USDC_AMOUNT);

    await escrow.write.acceptTrade([0n], { account: walletBob.account });

    assert.equal(
      getAddress(await nft.read.ownerOf([TOKEN_ID_1])),
      getAddress(bobAddress),
    );
    assert.equal(
      getAddress(await nft.read.ownerOf([TOKEN_ID_2])),
      getAddress(aliceAddress),
    );
    // Bob gets Alice's USDC; Alice had 500 and spent it, Bob had 500 and receives 500 more
    assert.equal(await usdc.read.balanceOf([bobAddress]), USDC_AMOUNT * 2n);
  });

  // =========================================================================
  // Happy path: ERC20 ↔ ERC20
  // =========================================================================

  it("createTrade + acceptTrade: ERC20 ↔ ERC20", async () => {
    const { escrow, usdc, dai } = await deploy();

    await escrow.write.createTrade(
      [
        bobAddress,
        [erc20Asset(usdc.address, USDC_AMOUNT)],
        [erc20Asset(dai.address, DAI_AMOUNT)],
        0n,
      ],
      { account: walletAlice.account },
    );

    assert.equal(await usdc.read.balanceOf([escrow.address]), USDC_AMOUNT);

    await escrow.write.acceptTrade([0n], { account: walletBob.account });

    assert.equal(await usdc.read.balanceOf([bobAddress]), USDC_AMOUNT * 2n);
    assert.equal(await dai.read.balanceOf([aliceAddress]), DAI_AMOUNT);
  });

  // =========================================================================
  // Happy path: ERC721 ↔ ERC1155
  // =========================================================================

  it("createTrade + acceptTrade: NFT ↔ ERC1155", async () => {
    const { escrow, nft, erc1155 } = await deploy();

    await escrow.write.createTrade(
      [
        bobAddress,
        [nftAsset(nft.address, TOKEN_ID_1)],
        [erc1155Asset(erc1155.address, ERC1155_ID, ERC1155_AMOUNT)],
        0n,
      ],
      { account: walletAlice.account },
    );

    await escrow.write.acceptTrade([0n], { account: walletBob.account });

    assert.equal(
      getAddress(await nft.read.ownerOf([TOKEN_ID_1])),
      getAddress(bobAddress),
    );
    // Alice started with ERC1155_AMOUNT and received ERC1155_AMOUNT from Bob = 2×.
    assert.equal(
      await erc1155.read.balanceOf([aliceAddress, ERC1155_ID]),
      ERC1155_AMOUNT * 2n,
    );
    assert.equal(
      await erc1155.read.balanceOf([bobAddress, ERC1155_ID]),
      0n,
    );
  });

  // =========================================================================
  // Cancel: initiator reclaims escrow
  // =========================================================================

  it("cancelTrade returns escrowed assets to initiator", async () => {
    const { escrow, usdc, nft } = await deploy();

    await escrow.write.createTrade(
      [bobAddress, [nftAsset(nft.address, TOKEN_ID_1)], [erc20Asset(usdc.address, USDC_AMOUNT)], 0n],
      { account: walletAlice.account },
    );

    await escrow.write.cancelTrade([0n], { account: walletAlice.account });

    assert.equal(
      getAddress(await nft.read.ownerOf([TOKEN_ID_1])),
      getAddress(aliceAddress),
    );
    const trade = await escrow.read.getTrade([0n]);
    assert.equal(trade.status, TradeStatus.Cancelled);
  });

  // =========================================================================
  // Cancel works while paused
  // =========================================================================

  it("cancelTrade works while contract is paused", async () => {
    const { escrow, usdc, nft } = await deploy();

    await escrow.write.createTrade(
      [bobAddress, [nftAsset(nft.address, TOKEN_ID_1)], [erc20Asset(usdc.address, USDC_AMOUNT)], 0n],
      { account: walletAlice.account },
    );

    await escrow.write.pause({ account: walletAdmin.account });

    await escrow.write.cancelTrade([0n], { account: walletAlice.account });

    assert.equal(
      getAddress(await nft.read.ownerOf([TOKEN_ID_1])),
      getAddress(aliceAddress),
    );
  });

  // =========================================================================
  // Expire: anyone can expire after deadline
  // =========================================================================

  it("expireTrade returns escrowed assets after deadline (callable by anyone)", async () => {
    const { escrow, usdc, nft } = await deploy();

    // Advance one block so timestamp is stable, then read it.
    const ONE_HOUR = 3600;
    await testClient.increaseTime({ seconds: 1 });
    await testClient.mine({ blocks: 1 });

    const publicClient = await viem.getPublicClient();
    const block = await publicClient.getBlock();
    const deadline = block.timestamp + BigInt(ONE_HOUR);

    await escrow.write.createTrade(
      [bobAddress, [nftAsset(nft.address, TOKEN_ID_1)], [erc20Asset(usdc.address, USDC_AMOUNT)], deadline],
      { account: walletAlice.account },
    );

    // Warp past deadline
    await testClient.increaseTime({ seconds: ONE_HOUR * 2 });
    await testClient.mine({ blocks: 1 });

    // Carol (third party) calls expireTrade
    await escrow.write.expireTrade([0n], { account: walletCarol.account });

    assert.equal(
      getAddress(await nft.read.ownerOf([TOKEN_ID_1])),
      getAddress(aliceAddress),
    );
    const trade = await escrow.read.getTrade([0n]);
    assert.equal(trade.status, TradeStatus.Expired);
  });

  // =========================================================================
  // Revert: non-counterparty cannot accept
  // =========================================================================

  it("revert: non-counterparty cannot acceptTrade", async () => {
    const { escrow, usdc, nft } = await deploy();

    await escrow.write.createTrade(
      [bobAddress, [nftAsset(nft.address, TOKEN_ID_1)], [erc20Asset(usdc.address, USDC_AMOUNT)], 0n],
      { account: walletAlice.account },
    );

    await assert.rejects(
      () =>
        escrow.write.acceptTrade([0n], { account: walletCarol.account }),
      /P2PTradeEscrow__NotCounterparty/,
    );
  });

  // =========================================================================
  // Revert: accept after deadline
  // =========================================================================

  it("revert: counterparty cannot acceptTrade after deadline", async () => {
    const { escrow, usdc, nft } = await deploy();

    // Use a deadline 1 hour from now in EVM time, then warp 2 hours past it.
    const ONE_HOUR = 3600;
    await testClient.increaseTime({ seconds: 1 });
    await testClient.mine({ blocks: 1 });

    // deadline = now + 1h (large enough for createTrade to accept, small enough to warp past)
    const publicClient = await viem.getPublicClient();
    const block = await publicClient.getBlock();
    const deadline = block.timestamp + BigInt(ONE_HOUR);

    await escrow.write.createTrade(
      [bobAddress, [nftAsset(nft.address, TOKEN_ID_1)], [erc20Asset(usdc.address, USDC_AMOUNT)], deadline],
      { account: walletAlice.account },
    );

    // Warp past deadline
    await testClient.increaseTime({ seconds: ONE_HOUR * 2 });
    await testClient.mine({ blocks: 1 });

    await assert.rejects(
      () =>
        escrow.write.acceptTrade([0n], { account: walletBob.account }),
      /P2PTradeEscrow__TradeExpired/,
    );
  });

  // =========================================================================
  // Revert: non-initiator cannot cancel
  // =========================================================================

  it("revert: non-initiator cannot cancelTrade", async () => {
    const { escrow, usdc, nft } = await deploy();

    await escrow.write.createTrade(
      [bobAddress, [nftAsset(nft.address, TOKEN_ID_1)], [erc20Asset(usdc.address, USDC_AMOUNT)], 0n],
      { account: walletAlice.account },
    );

    await assert.rejects(
      () =>
        escrow.write.cancelTrade([0n], { account: walletBob.account }),
      /P2PTradeEscrow__NotInitiator/,
    );
  });

  // =========================================================================
  // Revert: double-accept
  // =========================================================================

  it("revert: double-accept on the same trade", async () => {
    const { escrow, usdc, dai } = await deploy();

    await escrow.write.createTrade(
      [
        bobAddress,
        [erc20Asset(usdc.address, USDC_AMOUNT)],
        [erc20Asset(dai.address, DAI_AMOUNT)],
        0n,
      ],
      { account: walletAlice.account },
    );

    await escrow.write.acceptTrade([0n], { account: walletBob.account });

    await assert.rejects(
      () =>
        escrow.write.acceptTrade([0n], { account: walletBob.account }),
      /P2PTradeEscrow__TradeNotActive/,
    );
  });

  // =========================================================================
  // Revert: pause blocks create and accept
  // =========================================================================

  it("revert: createTrade blocked when paused", async () => {
    const { escrow, usdc, nft } = await deploy();

    await escrow.write.pause({ account: walletAdmin.account });

    await assert.rejects(
      () =>
        escrow.write.createTrade(
          [bobAddress, [nftAsset(nft.address, TOKEN_ID_1)], [erc20Asset(usdc.address, USDC_AMOUNT)], 0n],
          { account: walletAlice.account },
        ),
      /EnforcedPause|paused/i,
    );
  });

  it("revert: acceptTrade blocked when paused", async () => {
    const { escrow, usdc, nft } = await deploy();

    await escrow.write.createTrade(
      [bobAddress, [nftAsset(nft.address, TOKEN_ID_1)], [erc20Asset(usdc.address, USDC_AMOUNT)], 0n],
      { account: walletAlice.account },
    );

    await escrow.write.pause({ account: walletAdmin.account });

    await assert.rejects(
      () =>
        escrow.write.acceptTrade([0n], { account: walletBob.account }),
      /EnforcedPause|paused/i,
    );
  });
});
