// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {P2PTradeEscrow} from "../P2PTradeEscrow.sol";
import {IP2PTradeEscrow} from "../interfaces/IP2PTradeEscrow.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockERC721} from "../test-helpers/MockERC721.sol";
import {MockERC1155} from "../test-helpers/MockERC1155.sol";

/// @notice A contract account that trades through the escrow and can refuse ERC1155 deliveries,
///         to exercise non-blocking refunds.
contract ContractInitiator {
    address public immutable owner;
    bool public rejectErc1155;

    constructor(address owner_) {
        owner = owner_;
    }

    function setRejectErc1155(bool reject) external {
        require(msg.sender == owner, "not owner");
        rejectErc1155 = reject;
    }

    function execute(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == owner, "not owner");
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external view returns (bytes4) {
        require(!rejectErc1155, "rejecting ERC1155");
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external view returns (bytes4) {
        require(!rejectErc1155, "rejecting ERC1155");
        return this.onERC1155BatchReceived.selector;
    }
}

/// @notice P2PTradeEscrow lifecycle beyond create/accept/cancel/expire (WOR-2581): reject,
///         counter, the token allow-list, non-blocking refunds and admin hardening. Every action
///         is sent by the party itself — the signature-relayed (Coinflow) path was removed.
contract P2PTradeEscrowLifecycleTest is Test {
    P2PTradeEscrow internal escrow;
    MockERC20 internal usdc;
    MockERC721 internal nft;
    MockERC1155 internal erc1155;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice"); // initiator
    address internal bob = makeAddr("bob"); // counterparty
    address internal carol = makeAddr("carol"); // unauthorized third party

    uint256 internal constant ALICE_NFT = 1;
    uint256 internal constant BOB_NFT = 2;
    uint256 internal constant ERC1155_ID = 10;
    uint256 internal constant ERC1155_AMOUNT = 5;
    uint256 internal constant USDC_AMOUNT = 50e6;
    uint256 internal constant STARTING_USDC = 1_000e6;

    uint64 internal deadline;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        usdc = new MockERC20();
        nft = new MockERC721();
        erc1155 = new MockERC1155();

        P2PTradeEscrow impl = new P2PTradeEscrow();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(P2PTradeEscrow.initialize, (admin))
        );
        escrow = P2PTradeEscrow(address(proxy));
        vm.startPrank(admin);
        escrow.setTokenAllowed(address(usdc), IP2PTradeEscrow.AssetType.ERC20, true);
        escrow.setTokenAllowed(address(nft), IP2PTradeEscrow.AssetType.ERC721, true);
        escrow.setTokenAllowed(address(erc1155), IP2PTradeEscrow.AssetType.ERC1155, true);
        vm.stopPrank();

        nft.mint(alice, ALICE_NFT);
        nft.mint(bob, BOB_NFT);
        erc1155.mint(alice, ERC1155_ID, ERC1155_AMOUNT);
        usdc.mint(alice, STARTING_USDC);
        usdc.mint(bob, STARTING_USDC);

        _approveAll(alice);
        _approveAll(bob);

        deadline = uint64(block.timestamp + 7 days);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _approveAll(address who) internal {
        vm.startPrank(who);
        nft.setApprovalForAll(address(escrow), true);
        erc1155.setApprovalForAll(address(escrow), true);
        usdc.approve(address(escrow), type(uint256).max);
        vm.stopPrank();
    }

    function _nft(uint256 tokenId) internal view returns (IP2PTradeEscrow.Asset memory) {
        return
            IP2PTradeEscrow.Asset({
                assetType: IP2PTradeEscrow.AssetType.ERC721,
                token: address(nft),
                tokenId: tokenId,
                amount: 0
            });
    }

    function _usdc(uint256 amount) internal view returns (IP2PTradeEscrow.Asset memory) {
        return
            IP2PTradeEscrow.Asset({
                assetType: IP2PTradeEscrow.AssetType.ERC20,
                token: address(usdc),
                tokenId: 0,
                amount: amount
            });
    }

    function _1155(uint256 amount) internal view returns (IP2PTradeEscrow.Asset memory) {
        return
            IP2PTradeEscrow.Asset({
                assetType: IP2PTradeEscrow.AssetType.ERC1155,
                token: address(erc1155),
                tokenId: ERC1155_ID,
                amount: amount
            });
    }

    function _one(
        IP2PTradeEscrow.Asset memory a
    ) internal pure returns (IP2PTradeEscrow.Asset[] memory out) {
        out = new IP2PTradeEscrow.Asset[](1);
        out[0] = a;
    }

    function _two(
        IP2PTradeEscrow.Asset memory a,
        IP2PTradeEscrow.Asset memory b
    ) internal pure returns (IP2PTradeEscrow.Asset[] memory out) {
        out = new IP2PTradeEscrow.Asset[](2);
        out[0] = a;
        out[1] = b;
    }

    /// @dev Alice: her NFT for Bob's NFT + 50 USDC.
    function _createTradeRequestingUsdc() internal returns (uint256 tradeId) {
        vm.prank(alice);
        tradeId = escrow.createTrade(
            bob,
            _one(_nft(ALICE_NFT)),
            _two(_nft(BOB_NFT), _usdc(USDC_AMOUNT)),
            deadline
        );
    }

    /// @dev Alice: her NFT for Bob's NFT.
    function _createNftSwap() internal returns (uint256 tradeId) {
        vm.prank(alice);
        tradeId = escrow.createTrade(bob, _one(_nft(ALICE_NFT)), _one(_nft(BOB_NFT)), deadline);
    }

    function _status(uint256 tradeId) internal view returns (uint8) {
        return uint8(escrow.getTrade(tradeId).status);
    }

    // =========================================================================
    // No signature-relayed path
    // =========================================================================

    /// @dev The Coinflow funded path is gone: nothing a user signs off-chain can move their
    ///      assets. None of its selectors may appear in the implementation's dispatcher.
    ///      Checked on the bytecode (PUSH4 <selector>) rather than by calling: a call with
    ///      made-up arguments would revert even if the function were still there.
    function test_signatureRelayedEntryPoints_removed() public {
        bytes memory code = address(new P2PTradeEscrow()).code;

        string[14] memory removed = [
            "createTradeFor((address,address,(uint8,address,uint256,uint256)[],(uint8,address,uint256,uint256)[],uint64,uint256,uint256,uint256),bytes)",
            "counterTradeFor((uint256,(uint8,address,uint256,uint256)[],(uint8,address,uint256,uint256)[],uint64,uint256,uint256,uint256),bytes)",
            "acceptTradeFor(uint256,uint256,uint256,uint256,bytes)",
            "cancelFundedTrade(uint256)",
            "cancelNonce(uint256)",
            "setRefundRecipient(address)",
            "erc20PayerOf(uint256)",
            "isNonceUsed(address,uint256)",
            "refundRecipient()",
            "eip712Domain()",
            "MAX_SIGNATURE_TTL()",
            "CREATE_TRADE_TYPEHASH()",
            "COUNTER_TRADE_TYPEHASH()",
            "ACCEPT_TRADE_TYPEHASH()"
        ];
        for (uint256 i; i < removed.length; ++i) {
            assertFalse(
                _dispatches(code, bytes4(keccak256(bytes(removed[i])))),
                removed[i]
            );
        }

        // The check itself works: a kept function is found.
        assertTrue(_dispatches(code, P2PTradeEscrow.acceptTrade.selector));
    }

    /// @dev True when `code` contains PUSH4 `selector`, the dispatcher's comparison.
    function _dispatches(bytes memory code, bytes4 selector) internal pure returns (bool) {
        for (uint256 i; i + 4 < code.length; ++i) {
            if (
                code[i] == 0x63 &&
                code[i + 1] == selector[0] &&
                code[i + 2] == selector[1] &&
                code[i + 3] == selector[2] &&
                code[i + 4] == selector[3]
            ) return true;
        }
        return false;
    }

    // =========================================================================
    // ERC20 always returns to the side that supplied it
    // =========================================================================

    function test_createTrade_withUsdc_cancelRefundsInitiator() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _two(_nft(ALICE_NFT), _usdc(USDC_AMOUNT)),
            _one(_nft(BOB_NFT)),
            deadline
        );
        assertEq(usdc.balanceOf(alice), STARTING_USDC - USDC_AMOUNT);

        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        assertEq(usdc.balanceOf(alice), STARTING_USDC);
        assertEq(nft.ownerOf(ALICE_NFT), alice);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function test_duplicateErc20Items_refundedInFull() public {
        IP2PTradeEscrow.Asset[] memory offered = new IP2PTradeEscrow.Asset[](3);
        offered[0] = _nft(ALICE_NFT);
        offered[1] = _usdc(10e6);
        offered[2] = _usdc(20e6);
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(bob, offered, _one(_nft(BOB_NFT)), deadline);

        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        assertEq(usdc.balanceOf(alice), STARTING_USDC);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testFuzz_cancel_returnsEveryOfferedAssetToInitiator(
        uint256 usdcAmount,
        uint256 erc1155Amount
    ) public {
        usdcAmount = bound(usdcAmount, 1, STARTING_USDC);
        erc1155Amount = bound(erc1155Amount, 1, ERC1155_AMOUNT);

        IP2PTradeEscrow.Asset[] memory offered = new IP2PTradeEscrow.Asset[](3);
        offered[0] = _nft(ALICE_NFT);
        offered[1] = _1155(erc1155Amount);
        offered[2] = _usdc(usdcAmount);
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(bob, offered, _one(_nft(BOB_NFT)), deadline);

        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        assertEq(nft.ownerOf(ALICE_NFT), alice);
        assertEq(erc1155.balanceOf(alice, ERC1155_ID), ERC1155_AMOUNT);
        assertEq(usdc.balanceOf(alice), STARTING_USDC);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // =========================================================================
    // rejectTrade
    // =========================================================================

    function test_rejectTrade_returnsEscrowToInitiator() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _two(_nft(ALICE_NFT), _usdc(USDC_AMOUNT)),
            _one(_nft(BOB_NFT)),
            deadline
        );

        vm.expectEmit(true, true, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeRejected(tradeId, bob);
        vm.prank(bob);
        escrow.rejectTrade(tradeId);

        assertEq(nft.ownerOf(ALICE_NFT), alice);
        assertEq(usdc.balanceOf(alice), STARTING_USDC);
        assertEq(nft.ownerOf(BOB_NFT), bob);
        assertEq(_status(tradeId), uint8(IP2PTradeEscrow.TradeStatus.Rejected));
    }

    function test_rejectTrade_notCounterparty_reverts() public {
        uint256 tradeId = _createTradeRequestingUsdc();

        vm.prank(carol);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotCounterparty.selector);
        escrow.rejectTrade(tradeId);

        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotCounterparty.selector);
        escrow.rejectTrade(tradeId);
    }

    function test_rejectTrade_notActive_reverts() public {
        uint256 tradeId = _createTradeRequestingUsdc();
        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        vm.prank(bob);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TradeNotActive.selector);
        escrow.rejectTrade(tradeId);
    }

    function test_rejectTrade_worksWhenPausedAndPastDeadline() public {
        uint256 tradeId = _createTradeRequestingUsdc();
        vm.prank(admin);
        escrow.pause();
        vm.warp(uint256(deadline) + 1);

        vm.prank(bob);
        escrow.rejectTrade(tradeId);

        assertEq(nft.ownerOf(ALICE_NFT), alice);
    }

    // =========================================================================
    // counterTrade
    // =========================================================================

    function test_counterTrade_closesOriginal_opensSwappedCounter() public {
        uint256 original = _createNftSwap();

        vm.expectEmit(true, true, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeCountered(original, original + 1);
        vm.prank(bob);
        uint256 counter = escrow.counterTrade(
            original,
            _two(_nft(BOB_NFT), _usdc(USDC_AMOUNT)),
            _one(_nft(ALICE_NFT)),
            deadline
        );

        // Original closed, Alice's escrow back with her.
        assertEq(_status(original), uint8(IP2PTradeEscrow.TradeStatus.Countered));
        assertEq(nft.ownerOf(ALICE_NFT), alice);

        // Counter: Bob is the initiator, his side escrowed.
        IP2PTradeEscrow.Trade memory t = escrow.getTrade(counter);
        assertEq(t.initiator, bob);
        assertEq(t.counterparty, alice);
        assertEq(nft.ownerOf(BOB_NFT), address(escrow));
        assertEq(usdc.balanceOf(bob), STARTING_USDC - USDC_AMOUNT);

        // Alice accepts the counter in a single transaction.
        vm.prank(alice);
        escrow.acceptTrade(counter);

        assertEq(nft.ownerOf(BOB_NFT), alice);
        assertEq(usdc.balanceOf(alice), STARTING_USDC + USDC_AMOUNT);
        assertEq(nft.ownerOf(ALICE_NFT), bob);
    }

    function test_counterTrade_counterOfCounter() public {
        uint256 original = _createNftSwap();
        vm.prank(bob);
        uint256 first = escrow.counterTrade(
            original,
            _two(_nft(BOB_NFT), _usdc(USDC_AMOUNT)),
            _one(_nft(ALICE_NFT)),
            deadline
        );

        // Alice counters back: NFT for NFT, no cash.
        vm.prank(alice);
        uint256 second = escrow.counterTrade(
            first,
            _one(_nft(ALICE_NFT)),
            _one(_nft(BOB_NFT)),
            deadline
        );

        assertEq(_status(first), uint8(IP2PTradeEscrow.TradeStatus.Countered));
        assertEq(usdc.balanceOf(bob), STARTING_USDC, "Bob's USDC back from the first counter");
        assertEq(nft.ownerOf(BOB_NFT), bob);
        assertEq(escrow.getTrade(second).initiator, alice);
        assertEq(nft.ownerOf(ALICE_NFT), address(escrow));
    }

    function test_counterTrade_notCounterparty_reverts() public {
        uint256 original = _createNftSwap();

        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotCounterparty.selector);
        escrow.counterTrade(original, _one(_nft(ALICE_NFT)), _one(_nft(BOB_NFT)), deadline);

        vm.prank(carol);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotCounterparty.selector);
        escrow.counterTrade(original, _one(_usdc(1)), _one(_nft(ALICE_NFT)), deadline);
    }

    function test_counterTrade_closedOrExpired_reverts() public {
        uint256 original = _createNftSwap();
        vm.warp(uint256(deadline) + 1);

        vm.prank(bob);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TradeExpired.selector);
        escrow.counterTrade(original, _one(_nft(BOB_NFT)), _one(_nft(ALICE_NFT)), 0);

        escrow.expireTrade(original);
        vm.prank(bob);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TradeNotActive.selector);
        escrow.counterTrade(original, _one(_nft(BOB_NFT)), _one(_nft(ALICE_NFT)), 0);
    }

    function test_counterTrade_blockedWhenPaused() public {
        uint256 original = _createNftSwap();
        vm.prank(admin);
        escrow.pause();

        vm.prank(bob);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        escrow.counterTrade(original, _one(_nft(BOB_NFT)), _one(_nft(ALICE_NFT)), deadline);
    }

    // =========================================================================
    // Event arguments the API indexes trades by
    // =========================================================================

    function test_events_carryTheirArguments() public {
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IP2PTradeEscrow.TradeCreated(0, alice, bob, deadline);
        uint256 accepted = _createNftSwap();

        vm.expectEmit(true, true, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeAccepted(accepted, bob);
        vm.prank(bob);
        escrow.acceptTrade(accepted);

        // Swap the NFTs back so Alice can offer hers again.
        vm.prank(bob);
        nft.transferFrom(bob, alice, ALICE_NFT);
        vm.prank(alice);
        nft.transferFrom(alice, bob, BOB_NFT);

        uint256 cancelled = _createNftSwap();
        vm.expectEmit(true, true, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeCancelled(cancelled, alice);
        vm.prank(alice);
        escrow.cancelTrade(cancelled);

        uint256 expired = _createNftSwap();
        vm.warp(uint256(deadline) + 1);
        vm.expectEmit(true, false, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeExpired(expired);
        escrow.expireTrade(expired);
    }

    // =========================================================================
    // Token allow-list (audit M-1, L-3)
    // =========================================================================

    function test_allowList_unlistedToken_reverts() public {
        MockERC20 fot = new MockERC20(); // stands for any unlisted (fee-on-transfer, fake…) token
        fot.mint(alice, 100);
        vm.prank(alice);
        fot.approve(address(escrow), type(uint256).max);

        IP2PTradeEscrow.Asset memory unlisted = IP2PTradeEscrow.Asset({
            assetType: IP2PTradeEscrow.AssetType.ERC20,
            token: address(fot),
            tokenId: 0,
            amount: 100
        });

        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TokenNotAllowed.selector);
        escrow.createTrade(bob, _one(unlisted), _one(_nft(BOB_NFT)), deadline);

        // Requested side too.
        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TokenNotAllowed.selector);
        escrow.createTrade(bob, _one(_nft(ALICE_NFT)), _one(unlisted), deadline);
    }

    /// @dev An allowed token declared as the wrong type is refused (an AssetNFT declared as
    ///      ERC20 would be pulled by transferFrom and then be impossible to release).
    function test_allowList_wrongType_reverts() public {
        IP2PTradeEscrow.Asset memory nftAsErc20 = IP2PTradeEscrow.Asset({
            assetType: IP2PTradeEscrow.AssetType.ERC20,
            token: address(nft),
            tokenId: 0,
            amount: ALICE_NFT
        });

        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TokenNotAllowed.selector);
        escrow.createTrade(bob, _one(nftAsErc20), _one(_nft(BOB_NFT)), deadline);
    }

    function test_allowList_delistingKeepsOpenTradesClosable() public {
        uint256 tradeId = _createTradeRequestingUsdc();
        vm.prank(admin);
        escrow.setTokenAllowed(address(nft), IP2PTradeEscrow.AssetType.ERC721, false);

        assertFalse(escrow.isTokenAllowed(address(nft), IP2PTradeEscrow.AssetType.ERC721));
        vm.prank(bob);
        escrow.acceptTrade(tradeId);
        assertEq(nft.ownerOf(ALICE_NFT), bob);
    }

    function test_setTokenAllowed_onlyOwner_andPerType() public {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, carol)
        );
        escrow.setTokenAllowed(carol, IP2PTradeEscrow.AssetType.ERC20, true);

        vm.prank(admin);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__ZeroAddress.selector);
        escrow.setTokenAllowed(address(0), IP2PTradeEscrow.AssetType.ERC20, true);

        // Allowing one type does not allow the others.
        assertTrue(escrow.isTokenAllowed(address(usdc), IP2PTradeEscrow.AssetType.ERC20));
        assertFalse(escrow.isTokenAllowed(address(usdc), IP2PTradeEscrow.AssetType.ERC721));
    }

    // =========================================================================
    // Non-blocking refunds (audit H-2)
    // =========================================================================

    /// @dev An initiator whose ERC1155 delivery fails must not freeze the close: the rest of
    ///      the bundle returns, and the 1155 waits as a pending refund anyone can retry — only
    ///      ever to the recorded recipient.
    function test_undeliverableItem_becomesPendingRefund() public {
        ContractInitiator wallet = new ContractInitiator(alice);
        erc1155.mint(address(wallet), ERC1155_ID, ERC1155_AMOUNT);
        usdc.mint(address(wallet), USDC_AMOUNT);
        vm.startPrank(alice);
        wallet.execute(
            address(erc1155),
            abi.encodeCall(erc1155.setApprovalForAll, (address(escrow), true))
        );
        wallet.execute(address(usdc), abi.encodeCall(usdc.approve, (address(escrow), USDC_AMOUNT)));
        uint256 tradeId = abi.decode(
            wallet.execute(
                address(escrow),
                abi.encodeCall(
                    escrow.createTrade,
                    (bob, _two(_1155(ERC1155_AMOUNT), _usdc(USDC_AMOUNT)), _one(_nft(BOB_NFT)), deadline)
                )
            ),
            (uint256)
        );
        wallet.setRejectErc1155(true);
        vm.stopPrank();

        // Bob declines; the 1155 can't be delivered, the USDC can.
        vm.expectEmit(true, true, true, false, address(escrow));
        emit IP2PTradeEscrow.RefundPending(tradeId, 0, address(wallet));
        vm.prank(bob);
        escrow.rejectTrade(tradeId);

        assertEq(_status(tradeId), uint8(IP2PTradeEscrow.TradeStatus.Rejected));
        assertEq(usdc.balanceOf(address(wallet)), USDC_AMOUNT);
        assertEq(erc1155.balanceOf(address(escrow), ERC1155_ID), ERC1155_AMOUNT);
        assertEq(escrow.pendingRefundOf(tradeId, 0), address(wallet));
        assertEq(escrow.pendingRefundOf(tradeId, 1), address(0));

        // Still refusing: the retry fails and the refund stays pending.
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__RefundFailed.selector);
        escrow.claimRefund(tradeId, 0);
        assertEq(escrow.pendingRefundOf(tradeId, 0), address(wallet));

        // Once it accepts again, anyone can deliver it — only to the recorded recipient.
        vm.prank(alice);
        wallet.setRejectErc1155(false);
        vm.expectEmit(true, true, true, false, address(escrow));
        emit IP2PTradeEscrow.RefundClaimed(tradeId, 0, address(wallet));
        vm.prank(carol);
        escrow.claimRefund(tradeId, 0);

        assertEq(erc1155.balanceOf(address(wallet), ERC1155_ID), ERC1155_AMOUNT);
        assertEq(erc1155.balanceOf(carol, ERC1155_ID), 0);

        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NoPendingRefund.selector);
        escrow.claimRefund(tradeId, 0);
    }

    function test_claimRefund_nothingPending_reverts() public {
        uint256 tradeId = _createTradeRequestingUsdc();
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NoPendingRefund.selector);
        escrow.claimRefund(tradeId, 0);
    }

    // =========================================================================
    // Admin hardening (audit M-2, L-5)
    // =========================================================================

    function test_renounceOwnership_disabled() public {
        vm.prank(admin);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__RenounceDisabled.selector);
        escrow.renounceOwnership();
        assertEq(escrow.owner(), admin);
    }

    function test_implementation_cannotBeInitialized() public {
        P2PTradeEscrow impl = new P2PTradeEscrow();
        vm.expectRevert();
        impl.initialize(carol);
    }

    function test_nonexistentTrade_actionsRevert() public {
        uint256 missing = 999;

        // An unassigned id reads as an Active trade with no parties, so every party check fails.
        vm.prank(bob);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotCounterparty.selector);
        escrow.acceptTrade(missing);

        vm.prank(bob);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotCounterparty.selector);
        escrow.rejectTrade(missing);

        vm.prank(bob);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotCounterparty.selector);
        escrow.counterTrade(missing, _one(_nft(BOB_NFT)), _one(_nft(ALICE_NFT)), 0);

        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotInitiator.selector);
        escrow.cancelTrade(missing);

        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotYetExpired.selector);
        escrow.expireTrade(missing);
    }
}
