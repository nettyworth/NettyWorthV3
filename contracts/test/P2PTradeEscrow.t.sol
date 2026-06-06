// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {P2PTradeEscrow} from "../P2PTradeEscrow.sol";
import {IP2PTradeEscrow} from "../interfaces/IP2PTradeEscrow.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockERC721} from "../test-helpers/MockERC721.sol";
import {MockERC1155} from "../test-helpers/MockERC1155.sol";

contract P2PTradeEscrowTest is Test {
    // =========================================================================
    // Contracts
    // =========================================================================
    P2PTradeEscrow internal escrow;
    MockERC20 internal usdc;
    MockERC20 internal dai;
    MockERC721 internal nft;
    MockERC1155 internal erc1155;

    // =========================================================================
    // Actors
    // =========================================================================
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice"); // initiator
    address internal bob = makeAddr("bob"); // counterparty
    address internal carol = makeAddr("carol"); // unauthorized third party

    // =========================================================================
    // Constants
    // =========================================================================
    uint256 internal constant TOKEN_ID_1 = 1;
    uint256 internal constant TOKEN_ID_2 = 2;
    uint256 internal constant ERC1155_ID = 10;
    uint256 internal constant USDC_AMOUNT = 500e6;
    uint256 internal constant DAI_AMOUNT = 1000e18;
    uint256 internal constant ERC1155_AMOUNT = 5;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        usdc = new MockERC20();
        dai = new MockERC20();
        nft = new MockERC721();
        erc1155 = new MockERC1155();

        // Deploy escrow via UUPS proxy
        P2PTradeEscrow impl = new P2PTradeEscrow();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(P2PTradeEscrow.initialize, (admin))
        );
        escrow = P2PTradeEscrow(address(proxy));

        // Mint assets to alice (initiator)
        nft.mint(alice, TOKEN_ID_1);
        usdc.mint(alice, USDC_AMOUNT);
        erc1155.mint(alice, ERC1155_ID, ERC1155_AMOUNT);

        // Mint assets to bob (counterparty)
        nft.mint(bob, TOKEN_ID_2);
        usdc.mint(bob, USDC_AMOUNT);
        dai.mint(bob, DAI_AMOUNT);
        erc1155.mint(bob, ERC1155_ID, ERC1155_AMOUNT);

        // Approvals for alice
        vm.startPrank(alice);
        nft.approve(address(escrow), TOKEN_ID_1);
        usdc.approve(address(escrow), type(uint256).max);
        erc1155.setApprovalForAll(address(escrow), true);
        vm.stopPrank();

        // Approvals for bob
        vm.startPrank(bob);
        nft.approve(address(escrow), TOKEN_ID_2);
        usdc.approve(address(escrow), type(uint256).max);
        dai.approve(address(escrow), type(uint256).max);
        erc1155.setApprovalForAll(address(escrow), true);
        vm.stopPrank();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _singleNFTAsset(
        address token,
        uint256 tokenId
    ) internal pure returns (IP2PTradeEscrow.Asset[] memory) {
        IP2PTradeEscrow.Asset[] memory assets = new IP2PTradeEscrow.Asset[](1);
        assets[0] = IP2PTradeEscrow.Asset({
            assetType: IP2PTradeEscrow.AssetType.ERC721,
            token: token,
            tokenId: tokenId,
            amount: 0
        });
        return assets;
    }

    function _singleERC20Asset(
        address token,
        uint256 amount
    ) internal pure returns (IP2PTradeEscrow.Asset[] memory) {
        IP2PTradeEscrow.Asset[] memory assets = new IP2PTradeEscrow.Asset[](1);
        assets[0] = IP2PTradeEscrow.Asset({
            assetType: IP2PTradeEscrow.AssetType.ERC20,
            token: token,
            tokenId: 0,
            amount: amount
        });
        return assets;
    }

    function _singleERC1155Asset(
        address token,
        uint256 tokenId,
        uint256 amount
    ) internal pure returns (IP2PTradeEscrow.Asset[] memory) {
        IP2PTradeEscrow.Asset[] memory assets = new IP2PTradeEscrow.Asset[](1);
        assets[0] = IP2PTradeEscrow.Asset({
            assetType: IP2PTradeEscrow.AssetType.ERC1155,
            token: token,
            tokenId: tokenId,
            amount: amount
        });
        return assets;
    }

    // =========================================================================
    // ── Happy path: ERC721 ↔ ERC20 ──────────────────────────────────────────
    // =========================================================================

    function test_createAndAccept_NFTvsERC20() public {
        // Alice offers NFT #1, wants 500 USDC from Bob.
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );

        // NFT should be in escrow.
        assertEq(nft.ownerOf(TOKEN_ID_1), address(escrow));

        // Bob accepts — should receive NFT, Alice should receive USDC.
        vm.prank(bob);
        escrow.acceptTrade(tradeId);

        assertEq(nft.ownerOf(TOKEN_ID_1), bob);
        // Alice started with USDC_AMOUNT and received USDC_AMOUNT from Bob = 2×.
        assertEq(usdc.balanceOf(alice), USDC_AMOUNT * 2);
        assertEq(usdc.balanceOf(bob), 0);

        IP2PTradeEscrow.Trade memory t = escrow.getTrade(tradeId);
        assertEq(uint8(t.status), uint8(IP2PTradeEscrow.TradeStatus.Accepted));
    }

    // =========================================================================
    // ── Happy path: asset + USDC ↔ asset ────────────────────────────────────
    // =========================================================================

    function test_createAndAccept_NFTplusUSDCvsNFT() public {
        // Alice offers NFT #1 + 500 USDC; wants Bob's NFT #2.
        IP2PTradeEscrow.Asset[] memory offered = new IP2PTradeEscrow.Asset[](2);
        offered[0] = IP2PTradeEscrow.Asset({
            assetType: IP2PTradeEscrow.AssetType.ERC721,
            token: address(nft),
            tokenId: TOKEN_ID_1,
            amount: 0
        });
        offered[1] = IP2PTradeEscrow.Asset({
            assetType: IP2PTradeEscrow.AssetType.ERC20,
            token: address(usdc),
            tokenId: 0,
            amount: USDC_AMOUNT
        });

        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            offered,
            _singleNFTAsset(address(nft), TOKEN_ID_2),
            0
        );

        // Escrow holds both.
        assertEq(nft.ownerOf(TOKEN_ID_1), address(escrow));
        assertEq(usdc.balanceOf(address(escrow)), USDC_AMOUNT);

        vm.prank(bob);
        escrow.acceptTrade(tradeId);

        // Bob gets NFT #1 + USDC; Alice gets NFT #2.
        assertEq(nft.ownerOf(TOKEN_ID_1), bob);
        assertEq(nft.ownerOf(TOKEN_ID_2), alice);
        assertEq(usdc.balanceOf(bob), USDC_AMOUNT * 2); // original 500 + received 500
        assertEq(usdc.balanceOf(alice), 0);
    }

    // =========================================================================
    // ── Happy path: ERC20 ↔ ERC20 ───────────────────────────────────────────
    // =========================================================================

    function test_createAndAccept_ERC20vsERC20() public {
        // Alice offers 500 USDC; wants 1000 DAI.
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            _singleERC20Asset(address(dai), DAI_AMOUNT),
            0
        );

        assertEq(usdc.balanceOf(address(escrow)), USDC_AMOUNT);

        vm.prank(bob);
        escrow.acceptTrade(tradeId);

        assertEq(usdc.balanceOf(bob), USDC_AMOUNT * 2); // 500 original + 500 received
        assertEq(dai.balanceOf(alice), DAI_AMOUNT);
    }

    // =========================================================================
    // ── Happy path: ERC721 ↔ ERC1155 ────────────────────────────────────────
    // =========================================================================

    function test_createAndAccept_NFTvsERC1155() public {
        // Alice offers NFT #1; wants 5 of ERC1155 token #10 from Bob.
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC1155Asset(address(erc1155), ERC1155_ID, ERC1155_AMOUNT),
            0
        );

        assertEq(nft.ownerOf(TOKEN_ID_1), address(escrow));

        vm.prank(bob);
        escrow.acceptTrade(tradeId);

        assertEq(nft.ownerOf(TOKEN_ID_1), bob);
        // Alice started with ERC1155_AMOUNT and received ERC1155_AMOUNT from Bob = 2×.
        assertEq(erc1155.balanceOf(alice, ERC1155_ID), ERC1155_AMOUNT * 2);
        assertEq(erc1155.balanceOf(bob, ERC1155_ID), 0);
    }

    // =========================================================================
    // ── Happy path: nextTradeId increments ──────────────────────────────────
    // =========================================================================

    function test_nextTradeId_increments() public {
        assertEq(escrow.nextTradeId(), 0);

        vm.prank(alice);
        escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );

        assertEq(escrow.nextTradeId(), 1);
    }

    // =========================================================================
    // ── Cancel: initiator reclaims escrow ───────────────────────────────────
    // =========================================================================

    function test_cancel_returnsEscrowToInitiator() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );

        assertEq(nft.ownerOf(TOKEN_ID_1), address(escrow));

        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        assertEq(nft.ownerOf(TOKEN_ID_1), alice);

        IP2PTradeEscrow.Trade memory t = escrow.getTrade(tradeId);
        assertEq(uint8(t.status), uint8(IP2PTradeEscrow.TradeStatus.Cancelled));
    }

    // =========================================================================
    // ── Cancel works while paused ───────────────────────────────────────────
    // =========================================================================

    function test_cancel_worksWhenPaused() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );

        vm.prank(admin);
        escrow.pause();

        // Cancel should still work despite pause.
        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        assertEq(nft.ownerOf(TOKEN_ID_1), alice);
    }

    // =========================================================================
    // ── Expire: anyone can expire after deadline ─────────────────────────────
    // =========================================================================

    function test_expire_afterDeadline() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            deadline
        );

        // Warp past deadline.
        vm.warp(deadline + 1);

        // Carol (third party) can trigger expiry.
        vm.prank(carol);
        escrow.expireTrade(tradeId);

        assertEq(nft.ownerOf(TOKEN_ID_1), alice); // returned to initiator
        IP2PTradeEscrow.Trade memory t = escrow.getTrade(tradeId);
        assertEq(uint8(t.status), uint8(IP2PTradeEscrow.TradeStatus.Expired));
    }

    // =========================================================================
    // ── Expire works while paused ───────────────────────────────────────────
    // =========================================================================

    function test_expire_worksWhenPaused() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            deadline
        );

        vm.warp(deadline + 1);

        vm.prank(admin);
        escrow.pause();

        vm.prank(carol);
        escrow.expireTrade(tradeId);

        assertEq(nft.ownerOf(TOKEN_ID_1), alice);
    }

    // =========================================================================
    // ── Pause blocks createTrade and acceptTrade ─────────────────────────────
    // =========================================================================

    function test_pause_blocksCreate() public {
        vm.prank(admin);
        escrow.pause();

        vm.prank(alice);
        vm.expectRevert();
        escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );
    }

    function test_pause_blocksAccept() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );

        vm.prank(admin);
        escrow.pause();

        vm.prank(bob);
        vm.expectRevert();
        escrow.acceptTrade(tradeId);
    }

    // =========================================================================
    // ── Reverts: non-counterparty cannot accept ──────────────────────────────
    // =========================================================================

    function test_revert_accept_notCounterparty() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );

        vm.prank(carol);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotCounterparty.selector);
        escrow.acceptTrade(tradeId);
    }

    // =========================================================================
    // ── Reverts: accept after deadline ──────────────────────────────────────
    // =========================================================================

    function test_revert_accept_afterDeadline() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            deadline
        );

        vm.warp(deadline + 1);

        vm.prank(bob);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TradeExpired.selector);
        escrow.acceptTrade(tradeId);
    }

    // =========================================================================
    // ── Reverts: cancel by non-initiator ─────────────────────────────────────
    // =========================================================================

    function test_revert_cancel_notInitiator() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );

        vm.prank(bob);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotInitiator.selector);
        escrow.cancelTrade(tradeId);
    }

    // =========================================================================
    // ── Reverts: expire before deadline ──────────────────────────────────────
    // =========================================================================

    function test_revert_expire_beforeDeadline() public {
        uint64 deadline = uint64(block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            deadline
        );

        // Still within deadline.
        vm.prank(carol);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotYetExpired.selector);
        escrow.expireTrade(tradeId);
    }

    // =========================================================================
    // ── Reverts: expire a trade with no deadline ──────────────────────────────
    // =========================================================================

    function test_revert_expire_noDeadline() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0 // no deadline
        );

        vm.prank(carol);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotYetExpired.selector);
        escrow.expireTrade(tradeId);
    }

    // =========================================================================
    // ── Reverts: double-accept ───────────────────────────────────────────────
    // =========================================================================

    function test_revert_doubleAccept() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            _singleERC20Asset(address(dai), DAI_AMOUNT),
            0
        );

        vm.prank(bob);
        escrow.acceptTrade(tradeId);

        vm.prank(bob);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TradeNotActive.selector);
        escrow.acceptTrade(tradeId);
    }

    // =========================================================================
    // ── Reverts: cancel already-accepted trade ───────────────────────────────
    // =========================================================================

    function test_revert_cancelAccepted() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            _singleERC20Asset(address(dai), DAI_AMOUNT),
            0
        );

        vm.prank(bob);
        escrow.acceptTrade(tradeId);

        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TradeNotActive.selector);
        escrow.cancelTrade(tradeId);
    }

    // =========================================================================
    // ── Reverts: invalid inputs ──────────────────────────────────────────────
    // =========================================================================

    function test_revert_createTrade_zeroCounterparty() public {
        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__ZeroAddress.selector);
        escrow.createTrade(
            address(0),
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );
    }

    function test_revert_createTrade_selfCounterparty() public {
        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidCounterparty.selector);
        escrow.createTrade(
            alice, // same as msg.sender
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );
    }

    function test_revert_createTrade_pastDeadline() public {
        vm.warp(1000);
        uint64 pastDeadline = uint64(block.timestamp - 1);
        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidDeadline.selector);
        escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            pastDeadline
        );
    }

    function test_revert_createTrade_emptyOffered() public {
        IP2PTradeEscrow.Asset[] memory empty = new IP2PTradeEscrow.Asset[](0);
        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__EmptyBundle.selector);
        escrow.createTrade(
            bob,
            empty,
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );
    }

    function test_revert_createTrade_emptyRequested() public {
        IP2PTradeEscrow.Asset[] memory empty = new IP2PTradeEscrow.Asset[](0);
        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__EmptyBundle.selector);
        escrow.createTrade(
            bob,
            _singleNFTAsset(address(nft), TOKEN_ID_1),
            empty,
            0
        );
    }

    function test_revert_createTrade_invalidAsset_zeroToken() public {
        IP2PTradeEscrow.Asset[] memory bad = new IP2PTradeEscrow.Asset[](1);
        bad[0] = IP2PTradeEscrow.Asset({
            assetType: IP2PTradeEscrow.AssetType.ERC20,
            token: address(0), // invalid
            tokenId: 0,
            amount: 100
        });
        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidAsset.selector);
        escrow.createTrade(
            bob,
            bad,
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );
    }

    function test_revert_createTrade_invalidAsset_zeroAmount() public {
        IP2PTradeEscrow.Asset[] memory bad = new IP2PTradeEscrow.Asset[](1);
        bad[0] = IP2PTradeEscrow.Asset({
            assetType: IP2PTradeEscrow.AssetType.ERC20,
            token: address(usdc),
            tokenId: 0,
            amount: 0 // zero amount invalid for ERC20
        });
        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidAsset.selector);
        escrow.createTrade(
            bob,
            bad,
            _singleERC20Asset(address(usdc), USDC_AMOUNT),
            0
        );
    }

    // =========================================================================
    // ── Admin: only owner can pause/unpause/upgrade ──────────────────────────
    // =========================================================================

    function test_revert_pause_notOwner() public {
        vm.prank(carol);
        vm.expectRevert();
        escrow.pause();
    }

    function test_revert_unpause_notOwner() public {
        vm.prank(admin);
        escrow.pause();

        vm.prank(carol);
        vm.expectRevert();
        escrow.unpause();
    }

}
