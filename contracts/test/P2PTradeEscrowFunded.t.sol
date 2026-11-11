// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {P2PTradeEscrow} from "../P2PTradeEscrow.sol";
import {IP2PTradeEscrow} from "../interfaces/IP2PTradeEscrow.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockERC721} from "../test-helpers/MockERC721.sol";
import {MockERC1155} from "../test-helpers/MockERC1155.sol";
import {MockERC1271Wallet} from "../test-helpers/MockERC1271Wallet.sol";

/// @notice P2PTradeEscrow v2 (WOR-2581): rejectTrade, counterTrade, the funded path
///         (createTradeFor / counterTradeFor / acceptTradeFor), refund routing to the refund
///         recipient, and cancelFundedTrade. `coinflow` stands for Coinflow's relayer — any
///         address may submit a user-signed action and pay its ERC20 side.
contract P2PTradeEscrowFundedTest is Test {
    // =========================================================================
    // Contracts
    // =========================================================================
    P2PTradeEscrow internal escrow;
    MockERC20 internal usdc;
    MockERC721 internal nft;
    MockERC1155 internal erc1155;

    // =========================================================================
    // Actors
    // =========================================================================
    address internal admin = makeAddr("admin");
    address internal coinflow = makeAddr("coinflowRelayer"); // pays card-funded USDC
    address internal refundVault = makeAddr("refundVault"); // NettyWorth refund recipient
    address internal carol = makeAddr("carol"); // unauthorized third party
    address internal alice; // initiator
    uint256 internal alicePk;
    address internal bob; // counterparty
    uint256 internal bobPk;

    // =========================================================================
    // Constants
    // =========================================================================
    uint256 internal constant ALICE_NFT = 1;
    uint256 internal constant BOB_NFT = 2;
    uint256 internal constant ERC1155_ID = 10;
    uint256 internal constant ERC1155_AMOUNT = 5;
    uint256 internal constant USDC_AMOUNT = 50e6;
    uint256 internal constant STARTING_USDC = 1_000e6;
    uint256 internal constant SIG_TTL = 30 minutes;

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 internal constant ASSET_TYPEHASH =
        keccak256("Asset(uint8 assetType,address token,uint256 tokenId,uint256 amount)");
    bytes32 internal constant CREATE_TRADE_TYPEHASH =
        keccak256(
            "CreateTrade(address initiator,address counterparty,Asset[] offered,Asset[] requested,uint64 deadline,uint256 nonce,uint256 validBefore,uint256 validAfter)Asset(uint8 assetType,address token,uint256 tokenId,uint256 amount)"
        );
    bytes32 internal constant COUNTER_TRADE_TYPEHASH =
        keccak256(
            "CounterTrade(uint256 tradeId,address counterparty,Asset[] offered,Asset[] requested,uint64 deadline,uint256 nonce,uint256 validBefore,uint256 validAfter)Asset(uint8 assetType,address token,uint256 tokenId,uint256 amount)"
        );
    bytes32 internal constant ACCEPT_TRADE_TYPEHASH =
        keccak256(
            "AcceptTrade(uint256 tradeId,address counterparty,Asset[] offered,Asset[] requested,uint256 nonce,uint256 validBefore,uint256 validAfter)Asset(uint8 assetType,address token,uint256 tokenId,uint256 amount)"
        );
    /// @dev secp256k1 group order, to build a high-s (malleated) signature.
    uint256 internal constant SECP256K1_N =
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    uint64 internal deadline;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");

        usdc = new MockERC20();
        nft = new MockERC721();
        erc1155 = new MockERC1155();
        escrow = _deployEscrow(true);

        nft.mint(alice, ALICE_NFT);
        nft.mint(bob, BOB_NFT);
        erc1155.mint(alice, ERC1155_ID, ERC1155_AMOUNT);
        usdc.mint(alice, STARTING_USDC);
        usdc.mint(bob, STARTING_USDC);
        usdc.mint(coinflow, STARTING_USDC);
        usdc.mint(carol, STARTING_USDC);

        _approveAll(alice, escrow);
        _approveAll(bob, escrow);
        _approveUsdc(coinflow, escrow);
        _approveUsdc(carol, escrow);

        deadline = uint64(block.timestamp + 7 days);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _deployEscrow(bool withRefundRecipient) internal returns (P2PTradeEscrow e) {
        P2PTradeEscrow impl = new P2PTradeEscrow();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(P2PTradeEscrow.initialize, (admin))
        );
        e = P2PTradeEscrow(address(proxy));
        vm.startPrank(admin);
        e.setTokenAllowed(address(usdc), IP2PTradeEscrow.AssetType.ERC20, true);
        e.setTokenAllowed(address(nft), IP2PTradeEscrow.AssetType.ERC721, true);
        e.setTokenAllowed(address(erc1155), IP2PTradeEscrow.AssetType.ERC1155, true);
        if (withRefundRecipient) e.setRefundRecipient(refundVault);
        vm.stopPrank();
    }

    function _approveAll(address who, P2PTradeEscrow e) internal {
        vm.startPrank(who);
        nft.setApprovalForAll(address(e), true);
        erc1155.setApprovalForAll(address(e), true);
        usdc.approve(address(e), type(uint256).max);
        vm.stopPrank();
    }

    function _approveUsdc(address who, P2PTradeEscrow e) internal {
        vm.prank(who);
        usdc.approve(address(e), type(uint256).max);
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

    /// @dev Alice offers her NFT + 50 USDC for Bob's NFT; the USDC is the card-funded part.
    function _defaultParams(
        uint256 nonce
    ) internal view returns (IP2PTradeEscrow.CreateTradeParams memory) {
        return
            IP2PTradeEscrow.CreateTradeParams({
                initiator: alice,
                counterparty: bob,
                offered: _two(_nft(ALICE_NFT), _usdc(USDC_AMOUNT)),
                requested: _one(_nft(BOB_NFT)),
                deadline: deadline,
                nonce: nonce,
                validBefore: block.timestamp + SIG_TTL,
                validAfter: block.timestamp
            });
    }

    /// @dev Bob counters `tradeId`: his NFT + 50 USDC (card-funded) for Alice's NFT.
    function _defaultCounterParams(
        uint256 tradeId,
        uint256 nonce
    ) internal view returns (IP2PTradeEscrow.CounterTradeParams memory) {
        return
            IP2PTradeEscrow.CounterTradeParams({
                tradeId: tradeId,
                offered: _two(_nft(BOB_NFT), _usdc(USDC_AMOUNT)),
                requested: _one(_nft(ALICE_NFT)),
                deadline: deadline,
                nonce: nonce,
                validBefore: block.timestamp + SIG_TTL,
                validAfter: block.timestamp
            });
    }

    function _domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    DOMAIN_TYPEHASH,
                    keccak256("P2PTradeEscrow"),
                    keccak256("1"),
                    block.chainid,
                    verifyingContract
                )
            );
    }

    function _typedDigest(
        address verifyingContract,
        bytes32 structHash
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked("\x19\x01", _domainSeparator(verifyingContract), structHash)
            );
    }

    /// @dev Independent re-implementation of the EIP-712 encoding off-chain signers use, so a
    ///      mismatch with the contract's own hashing fails these tests.
    function _hashAssets(IP2PTradeEscrow.Asset[] memory assets) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            hashes[i] = keccak256(
                abi.encode(
                    ASSET_TYPEHASH,
                    uint8(assets[i].assetType),
                    assets[i].token,
                    assets[i].tokenId,
                    assets[i].amount
                )
            );
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _createDigest(
        address verifyingContract,
        IP2PTradeEscrow.CreateTradeParams memory p
    ) internal view returns (bytes32) {
        return
            _typedDigest(
                verifyingContract,
                keccak256(
                    abi.encode(
                        CREATE_TRADE_TYPEHASH,
                        p.initiator,
                        p.counterparty,
                        _hashAssets(p.offered),
                        _hashAssets(p.requested),
                        p.deadline,
                        p.nonce,
                        p.validBefore,
                        p.validAfter
                    )
                )
            );
    }

    function _counterDigest(
        IP2PTradeEscrow.CounterTradeParams memory p,
        address signer
    ) internal view returns (bytes32) {
        return
            _typedDigest(
                address(escrow),
                keccak256(
                    abi.encode(
                        COUNTER_TRADE_TYPEHASH,
                        p.tradeId,
                        signer,
                        _hashAssets(p.offered),
                        _hashAssets(p.requested),
                        p.deadline,
                        p.nonce,
                        p.validBefore,
                        p.validAfter
                    )
                )
            );
    }

    /// @dev AcceptTrade digest over the bundles the trade holds on-chain.
    function _acceptDigest(
        uint256 tradeId,
        address counterparty,
        uint256 nonce,
        uint256 validBefore,
        uint256 validAfter
    ) internal view returns (bytes32) {
        IP2PTradeEscrow.Trade memory t = escrow.getTrade(tradeId);
        return
            _acceptDigestFor(
                tradeId,
                counterparty,
                t.offered,
                t.requested,
                nonce,
                validBefore,
                validAfter
            );
    }

    function _acceptDigestFor(
        uint256 tradeId,
        address counterparty,
        IP2PTradeEscrow.Asset[] memory offered,
        IP2PTradeEscrow.Asset[] memory requested,
        uint256 nonce,
        uint256 validBefore,
        uint256 validAfter
    ) internal view returns (bytes32) {
        return
            _typedDigest(
                address(escrow),
                keccak256(
                    abi.encode(
                        ACCEPT_TRADE_TYPEHASH,
                        tradeId,
                        counterparty,
                        _hashAssets(offered),
                        _hashAssets(requested),
                        nonce,
                        validBefore,
                        validAfter
                    )
                )
            );
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev createTradeFor from Coinflow with Alice's signature over the default params.
    function _createFor(uint256 nonce) internal returns (uint256 tradeId) {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(nonce);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));
        vm.prank(coinflow);
        tradeId = escrow.createTradeFor(p, sig);
    }

    /// @dev Plain createTrade from Alice: her NFT for Bob's NFT + 50 USDC.
    function _createWalletTradeRequestingUsdc() internal returns (uint256 tradeId) {
        vm.prank(alice);
        tradeId = escrow.createTrade(
            bob,
            _one(_nft(ALICE_NFT)),
            _two(_nft(BOB_NFT), _usdc(USDC_AMOUNT)),
            deadline
        );
    }

    /// @dev Plain createTrade from Alice: her NFT for Bob's NFT.
    function _createNftSwap() internal returns (uint256 tradeId) {
        vm.prank(alice);
        tradeId = escrow.createTrade(
            bob,
            _one(_nft(ALICE_NFT)),
            _one(_nft(BOB_NFT)),
            deadline
        );
    }

    function _status(uint256 tradeId) internal view returns (uint8) {
        return uint8(escrow.getTrade(tradeId).status);
    }

    // =========================================================================
    // Plain path keeps its behaviour
    // =========================================================================

    function test_createTrade_walletErc20_noPayer_cancelRefundsInitiator() public {
        vm.prank(alice);
        uint256 tradeId = escrow.createTrade(
            bob,
            _two(_nft(ALICE_NFT), _usdc(USDC_AMOUNT)),
            _one(_nft(BOB_NFT)),
            deadline
        );
        assertEq(escrow.erc20PayerOf(tradeId), address(0));
        assertEq(usdc.balanceOf(alice), STARTING_USDC - USDC_AMOUNT);

        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        assertEq(usdc.balanceOf(alice), STARTING_USDC);
        assertEq(nft.ownerOf(ALICE_NFT), alice);
        assertEq(usdc.balanceOf(refundVault), 0);
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
        uint256 tradeId = _createWalletTradeRequestingUsdc();

        vm.prank(carol);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotCounterparty.selector);
        escrow.rejectTrade(tradeId);

        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotCounterparty.selector);
        escrow.rejectTrade(tradeId);
    }

    function test_rejectTrade_notActive_reverts() public {
        uint256 tradeId = _createWalletTradeRequestingUsdc();
        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        vm.prank(bob);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TradeNotActive.selector);
        escrow.rejectTrade(tradeId);
    }

    function test_rejectTrade_worksWhenPausedAndPastDeadline() public {
        uint256 tradeId = _createWalletTradeRequestingUsdc();
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
        assertEq(escrow.erc20PayerOf(counter), address(0));

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
        vm.expectRevert();
        escrow.counterTrade(original, _one(_nft(BOB_NFT)), _one(_nft(ALICE_NFT)), deadline);
    }

    function test_counterTrade_ofFundedOriginal_refundsVault() public {
        uint256 original = _createFor(1); // Alice's 50 USDC paid by Coinflow

        vm.prank(bob);
        escrow.counterTrade(original, _one(_nft(BOB_NFT)), _one(_nft(ALICE_NFT)), deadline);

        assertEq(usdc.balanceOf(refundVault), USDC_AMOUNT, "card-funded USDC to the vault");
        assertEq(usdc.balanceOf(alice), STARTING_USDC, "never to the initiator");
        assertEq(nft.ownerOf(ALICE_NFT), alice);
    }

    // =========================================================================
    // createTradeFor
    // =========================================================================

    function test_createTradeFor_erc20FromCaller_nftFromInitiator() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IP2PTradeEscrow.TradeCreated(0, alice, bob, deadline);
        vm.expectEmit(true, true, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeCreatedFor(0, coinflow);
        vm.prank(coinflow);
        uint256 tradeId = escrow.createTradeFor(p, sig);

        assertEq(nft.ownerOf(ALICE_NFT), address(escrow));
        assertEq(usdc.balanceOf(address(escrow)), USDC_AMOUNT);
        assertEq(usdc.balanceOf(coinflow), STARTING_USDC - USDC_AMOUNT);
        assertEq(usdc.balanceOf(alice), STARTING_USDC, "initiator USDC untouched");
        assertEq(escrow.erc20PayerOf(tradeId), coinflow);
        assertTrue(escrow.isNonceUsed(alice, 1));

        IP2PTradeEscrow.Trade memory t = escrow.getTrade(tradeId);
        assertEq(t.initiator, alice);
        assertEq(t.counterparty, bob);
        assertEq(t.offered.length, 2);
    }

    /// @dev No allow-list: any address holding the user's signature may submit and pay.
    function test_createTradeFor_anyCallerMaySubmit() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        vm.prank(carol);
        uint256 tradeId = escrow.createTradeFor(p, sig);

        assertEq(escrow.erc20PayerOf(tradeId), carol);
        assertEq(usdc.balanceOf(carol), STARTING_USDC - USDC_AMOUNT);
    }

    /// @dev The initiator submitting their own signature is an ordinary wallet trade.
    function test_createTradeFor_initiatorPays_isWalletTrade() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        vm.prank(alice);
        uint256 tradeId = escrow.createTradeFor(p, sig);
        assertEq(escrow.erc20PayerOf(tradeId), address(0));

        vm.prank(alice);
        escrow.cancelTrade(tradeId);
        assertEq(usdc.balanceOf(alice), STARTING_USDC);
        assertEq(usdc.balanceOf(refundVault), 0);
    }

    function test_createTradeFor_nftOnly_notExternallyFunded() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        p.offered = _one(_nft(ALICE_NFT));
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        vm.prank(coinflow);
        uint256 tradeId = escrow.createTradeFor(p, sig);

        assertEq(escrow.erc20PayerOf(tradeId), address(0));
    }

    function test_createTradeFor_refundRecipientNotSet_reverts() public {
        P2PTradeEscrow bare = _deployEscrow(false);
        _approveAll(alice, bare);
        _approveUsdc(coinflow, bare);

        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes memory sig = _sign(alicePk, _createDigest(address(bare), p));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__RefundRecipientNotSet.selector);
        bare.createTradeFor(p, sig);
    }

    function test_createTradeFor_tamperedParams_reverts() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        // A different counterparty (steering the trade elsewhere).
        p.counterparty = carol;
        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.createTradeFor(p, sig);

        // A smaller requested bundle.
        p = _defaultParams(1);
        p.requested = _one(_usdc(1));
        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.createTradeFor(p, sig);

        // A changed offered amount.
        p = _defaultParams(1);
        p.offered = _two(_nft(ALICE_NFT), _usdc(USDC_AMOUNT + 1));
        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.createTradeFor(p, sig);

        // A different deadline.
        p = _defaultParams(1);
        p.deadline = 0;
        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.createTradeFor(p, sig);
    }

    function test_createTradeFor_wrongSigner_reverts() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes memory sig = _sign(bobPk, _createDigest(address(escrow), p));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.createTradeFor(p, sig);
    }

    function test_createTradeFor_expiredSignature_reverts() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));
        vm.warp(p.validBefore + 1);

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__SignatureExpired.selector);
        escrow.createTradeFor(p, sig);
    }

    function test_createTradeFor_nonceReuse_reverts() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));
        vm.prank(coinflow);
        uint256 tradeId = escrow.createTradeFor(p, sig);
        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        // Same signature again — the NFT is back with Alice, only the nonce stops it.
        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NonceUsed.selector);
        escrow.createTradeFor(p, sig);
    }

    function test_createTradeFor_cancelledNonce_reverts() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(7);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        vm.expectEmit(true, false, false, true, address(escrow));
        emit IP2PTradeEscrow.NonceCancelled(alice, 7);
        vm.prank(alice);
        escrow.cancelNonce(7);

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NonceUsed.selector);
        escrow.createTradeFor(p, sig);
    }

    function test_createTradeFor_signatureForOtherEscrow_reverts() public {
        P2PTradeEscrow other = _deployEscrow(true);
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        // Signed for `other` (e.g. staging), submitted to `escrow` (e.g. production).
        bytes memory sig = _sign(alicePk, _createDigest(address(other), p));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.createTradeFor(p, sig);
    }

    function test_createTradeFor_initiatorNotApproved_reverts() public {
        vm.prank(alice);
        nft.setApprovalForAll(address(escrow), false);

        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        vm.prank(coinflow);
        vm.expectRevert();
        escrow.createTradeFor(p, sig);
    }

    function test_createTradeFor_erc1271Wallet() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(alice);
        nft.mint(address(wallet), 99);
        vm.prank(alice);
        wallet.execute(
            address(nft),
            abi.encodeCall(nft.setApprovalForAll, (address(escrow), true))
        );

        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        p.initiator = address(wallet);
        p.offered = _two(_nft(99), _usdc(USDC_AMOUNT));
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        vm.prank(coinflow);
        uint256 tradeId = escrow.createTradeFor(p, sig);

        assertEq(escrow.getTrade(tradeId).initiator, address(wallet));
        assertEq(nft.ownerOf(99), address(escrow));
    }

    /// @dev An EIP-7702-delegated EOA has code (0xef0100 || delegate). OZ's
    ///      SignatureChecker.isValidSignatureNow then skips ECDSA and only tries ERC-1271;
    ///      the escrow must still accept the EOA's own ECDSA signature.
    function test_createTradeFor_eip7702DelegatedEoa() public {
        vm.etch(alice, abi.encodePacked(hex"ef0100", address(0xBEEF)));
        assertGt(alice.code.length, 0);

        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes32 digest = _createDigest(address(escrow), p);
        bytes memory sig = _sign(alicePk, digest);

        // The reason the escrow has its own check:
        assertFalse(SignatureChecker.isValidSignatureNow(alice, digest, sig));

        vm.prank(coinflow);
        uint256 tradeId = escrow.createTradeFor(p, sig);
        assertEq(escrow.getTrade(tradeId).initiator, alice);
    }

    function test_fundedPaths_blockedWhenPaused() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));
        vm.prank(admin);
        escrow.pause();

        vm.prank(coinflow);
        vm.expectRevert();
        escrow.createTradeFor(p, sig);
    }

    // =========================================================================
    // Refund routing of an externally funded trade
    // =========================================================================

    function test_createTradeFor_cancel_refundsErc20ToVault() public {
        uint256 tradeId = _createFor(1);

        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        assertEq(usdc.balanceOf(refundVault), USDC_AMOUNT);
        assertEq(usdc.balanceOf(alice), STARTING_USDC, "no USDC to the initiator");
        assertEq(usdc.balanceOf(coinflow), STARTING_USDC - USDC_AMOUNT, "nor back to the relayer");
        assertEq(nft.ownerOf(ALICE_NFT), alice);
    }

    function test_createTradeFor_expire_refundsErc20ToVault() public {
        uint256 tradeId = _createFor(1);
        vm.warp(uint256(deadline) + 1);

        vm.prank(carol);
        escrow.expireTrade(tradeId);

        assertEq(usdc.balanceOf(refundVault), USDC_AMOUNT);
        assertEq(usdc.balanceOf(alice), STARTING_USDC);
        assertEq(nft.ownerOf(ALICE_NFT), alice);
    }

    function test_createTradeFor_reject_refundsErc20ToVault() public {
        uint256 tradeId = _createFor(1);

        vm.prank(bob);
        escrow.rejectTrade(tradeId);

        assertEq(usdc.balanceOf(refundVault), USDC_AMOUNT);
        assertEq(usdc.balanceOf(alice), STARTING_USDC);
        assertEq(nft.ownerOf(ALICE_NFT), alice);
    }

    function test_createTradeFor_refundsGoToCurrentRecipient() public {
        uint256 tradeId = _createFor(1);
        address newVault = makeAddr("newVault");
        vm.prank(admin);
        escrow.setRefundRecipient(newVault);

        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        assertEq(usdc.balanceOf(newVault), USDC_AMOUNT);
        assertEq(usdc.balanceOf(refundVault), 0);
    }

    function test_createTradeFor_accept_releasesAllOfferedToCounterparty() public {
        uint256 tradeId = _createFor(1);

        vm.prank(bob);
        escrow.acceptTrade(tradeId);

        assertEq(nft.ownerOf(ALICE_NFT), bob);
        assertEq(usdc.balanceOf(bob), STARTING_USDC + USDC_AMOUNT);
        assertEq(nft.ownerOf(BOB_NFT), alice);
        assertEq(usdc.balanceOf(refundVault), 0);
    }

    // =========================================================================
    // counterTradeFor
    // =========================================================================

    function test_counterTradeFor_fundedCounter() public {
        uint256 original = _createNftSwap();
        IP2PTradeEscrow.CounterTradeParams memory p = _defaultCounterParams(original, 1);
        bytes memory sig = _sign(bobPk, _counterDigest(p, bob));

        vm.expectEmit(true, true, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeCreatedFor(original + 1, coinflow);
        vm.expectEmit(true, true, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeCountered(original, original + 1);
        vm.prank(coinflow);
        uint256 counter = escrow.counterTradeFor(p, sig);

        assertEq(_status(original), uint8(IP2PTradeEscrow.TradeStatus.Countered));
        assertEq(nft.ownerOf(ALICE_NFT), alice);
        assertEq(escrow.getTrade(counter).initiator, bob);
        assertEq(escrow.erc20PayerOf(counter), coinflow);
        assertEq(usdc.balanceOf(bob), STARTING_USDC, "Bob's USDC untouched");
        assertEq(usdc.balanceOf(coinflow), STARTING_USDC - USDC_AMOUNT);

        // Alice declines: card-funded USDC to the vault, Bob's NFT back to Bob.
        vm.prank(alice);
        escrow.rejectTrade(counter);
        assertEq(usdc.balanceOf(refundVault), USDC_AMOUNT);
        assertEq(usdc.balanceOf(bob), STARTING_USDC);
        assertEq(nft.ownerOf(BOB_NFT), bob);
    }

    function test_counterTradeFor_wrongSigner_reverts() public {
        uint256 original = _createNftSwap();
        IP2PTradeEscrow.CounterTradeParams memory p = _defaultCounterParams(original, 1);
        // Alice (the original initiator) cannot counter her own trade on Bob's behalf.
        bytes memory sig = _sign(alicePk, _counterDigest(p, bob));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.counterTradeFor(p, sig);
    }

    function test_counterTradeFor_tamperedOffer_reverts() public {
        uint256 original = _createNftSwap();
        IP2PTradeEscrow.CounterTradeParams memory p = _defaultCounterParams(original, 1);
        bytes memory sig = _sign(bobPk, _counterDigest(p, bob));
        p.offered = _two(_nft(BOB_NFT), _usdc(1));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.counterTradeFor(p, sig);
    }

    function test_counterTradeFor_closedOriginal_reverts_payerKeepsUsdc() public {
        uint256 original = _createNftSwap();
        IP2PTradeEscrow.CounterTradeParams memory p = _defaultCounterParams(original, 1);
        bytes memory sig = _sign(bobPk, _counterDigest(p, bob));
        vm.prank(alice);
        escrow.cancelTrade(original);

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TradeNotActive.selector);
        escrow.counterTradeFor(p, sig);
        assertEq(usdc.balanceOf(coinflow), STARTING_USDC);
    }

    // =========================================================================
    // acceptTradeFor
    // =========================================================================

    function test_acceptTradeFor_erc20FromCaller_nftFromCounterparty() public {
        uint256 tradeId = _createWalletTradeRequestingUsdc();
        uint256 validBefore = block.timestamp + SIG_TTL;
        uint256 validAfter = block.timestamp;
        bytes memory sig = _sign(bobPk, _acceptDigest(tradeId, bob, 1, validBefore, validAfter));

        vm.expectEmit(true, true, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeAccepted(tradeId, bob);
        vm.expectEmit(true, true, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeAcceptedFor(tradeId, coinflow);
        vm.prank(coinflow);
        escrow.acceptTradeFor(tradeId, 1, validBefore, validAfter, sig);

        assertEq(nft.ownerOf(BOB_NFT), alice);
        assertEq(usdc.balanceOf(alice), STARTING_USDC + USDC_AMOUNT);
        assertEq(usdc.balanceOf(coinflow), STARTING_USDC - USDC_AMOUNT);
        assertEq(usdc.balanceOf(bob), STARTING_USDC, "counterparty USDC untouched");
        assertEq(nft.ownerOf(ALICE_NFT), bob);
        assertTrue(escrow.isNonceUsed(bob, 1));
    }

    function test_acceptTradeFor_wrongSigner_reverts() public {
        uint256 tradeId = _createWalletTradeRequestingUsdc();
        uint256 validBefore = block.timestamp + SIG_TTL;
        uint256 validAfter = block.timestamp;
        bytes memory sig = _sign(alicePk, _acceptDigest(tradeId, bob, 1, validBefore, validAfter));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.acceptTradeFor(tradeId, 1, validBefore, validAfter, sig);
    }

    function test_acceptTradeFor_signatureForOtherTrade_reverts() public {
        uint256 first = _createWalletTradeRequestingUsdc();
        nft.mint(alice, 3);
        vm.prank(alice);
        uint256 second = escrow.createTrade(
            bob,
            _one(_nft(3)),
            _one(_usdc(USDC_AMOUNT)),
            deadline
        );
        uint256 validBefore = block.timestamp + SIG_TTL;
        uint256 validAfter = block.timestamp;
        bytes memory sig = _sign(bobPk, _acceptDigest(first, bob, 1, validBefore, validAfter));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.acceptTradeFor(second, 1, validBefore, validAfter, sig);
    }

    function test_acceptTradeFor_closedTrade_reverts_payerKeepsUsdc() public {
        uint256 tradeId = _createWalletTradeRequestingUsdc();
        uint256 validBefore = block.timestamp + SIG_TTL;
        uint256 validAfter = block.timestamp;
        bytes memory sig = _sign(bobPk, _acceptDigest(tradeId, bob, 1, validBefore, validAfter));
        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TradeNotActive.selector);
        escrow.acceptTradeFor(tradeId, 1, validBefore, validAfter, sig);

        assertEq(usdc.balanceOf(coinflow), STARTING_USDC);
        assertFalse(escrow.isNonceUsed(bob, 1));
    }

    function test_acceptTradeFor_pastDeadline_reverts() public {
        uint256 tradeId = _createWalletTradeRequestingUsdc();
        // A signature whose window covers the moment just past the trade's deadline.
        uint256 validBefore = uint256(deadline) + SIG_TTL;
        uint256 validAfter = uint256(deadline);
        bytes memory sig = _sign(bobPk, _acceptDigest(tradeId, bob, 1, validBefore, validAfter));
        vm.warp(uint256(deadline) + 1);

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__TradeExpired.selector);
        escrow.acceptTradeFor(tradeId, 1, validBefore, validAfter, sig);
    }

    // =========================================================================
    // cancelFundedTrade
    // =========================================================================

    function test_cancelFundedTrade_refundsVaultAndInitiator() public {
        uint256 tradeId = _createFor(1);

        vm.expectEmit(true, true, false, false, address(escrow));
        emit IP2PTradeEscrow.TradeCancelled(tradeId, alice);
        vm.expectEmit(true, false, false, false, address(escrow));
        emit IP2PTradeEscrow.FundedTradeCancelled(tradeId);
        vm.prank(refundVault);
        escrow.cancelFundedTrade(tradeId);

        assertEq(usdc.balanceOf(refundVault), USDC_AMOUNT);
        assertEq(nft.ownerOf(ALICE_NFT), alice);
        assertEq(_status(tradeId), uint8(IP2PTradeEscrow.TradeStatus.Cancelled));
    }

    function test_cancelFundedTrade_onlyRefundRecipient() public {
        uint256 tradeId = _createFor(1);

        // Not even the relayer that paid.
        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotRefundRecipient.selector);
        escrow.cancelFundedTrade(tradeId);

        vm.prank(alice);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotRefundRecipient.selector);
        escrow.cancelFundedTrade(tradeId);
    }

    function test_cancelFundedTrade_walletTrade_reverts() public {
        uint256 tradeId = _createWalletTradeRequestingUsdc();

        vm.prank(refundVault);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NotExternallyFunded.selector);
        escrow.cancelFundedTrade(tradeId);
    }

    function test_cancelFundedTrade_whenPaused() public {
        uint256 tradeId = _createFor(1);
        vm.prank(admin);
        escrow.pause();

        vm.prank(refundVault);
        escrow.cancelFundedTrade(tradeId);

        assertEq(usdc.balanceOf(refundVault), USDC_AMOUNT);
        assertEq(nft.ownerOf(ALICE_NFT), alice);
    }

    // =========================================================================
    // Admin / nonces
    // =========================================================================

    function test_setRefundRecipient_onlyOwner() public {
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, carol)
        );
        escrow.setRefundRecipient(carol);

        vm.expectEmit(true, false, false, false, address(escrow));
        emit IP2PTradeEscrow.RefundRecipientSet(carol);
        vm.prank(admin);
        escrow.setRefundRecipient(carol);
        assertEq(escrow.refundRecipient(), carol);
    }

    function test_setRefundRecipient_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__ZeroAddress.selector);
        escrow.setRefundRecipient(address(0));
    }

    function test_cancelNonce_twice_reverts() public {
        vm.startPrank(alice);
        escrow.cancelNonce(3);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NonceUsed.selector);
        escrow.cancelNonce(3);
        vm.stopPrank();
    }

    // =========================================================================
    // Audit fixes: token allow-list (M-1, L-3)
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
        uint256 tradeId = _createWalletTradeRequestingUsdc();
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
    // Audit fixes: non-blocking refunds (H-2)
    // =========================================================================

    /// @dev H-2 PoC: a contract-wallet initiator funds a trade through Coinflow, charges back,
    ///      and makes its own ERC1155 undeliverable. The close must still go through: the
    ///      card-funded USDC reaches the vault and the 1155 waits as a pending refund.
    function test_cancelFundedTrade_initiatorCannotBlockRefund() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(alice);
        erc1155.mint(address(wallet), ERC1155_ID, ERC1155_AMOUNT);
        vm.prank(alice);
        wallet.execute(
            address(erc1155),
            abi.encodeCall(erc1155.setApprovalForAll, (address(escrow), true))
        );

        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        p.initiator = address(wallet);
        p.offered = _two(_1155(ERC1155_AMOUNT), _usdc(USDC_AMOUNT));
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));
        vm.prank(coinflow);
        uint256 tradeId = escrow.createTradeFor(p, sig);

        vm.prank(alice);
        wallet.setRejectERC1155(true);

        vm.expectEmit(true, true, true, false, address(escrow));
        emit IP2PTradeEscrow.RefundPending(tradeId, 0, address(wallet));
        vm.prank(refundVault);
        escrow.cancelFundedTrade(tradeId);

        assertEq(usdc.balanceOf(refundVault), USDC_AMOUNT, "card-funded USDC recovered");
        assertEq(erc1155.balanceOf(address(escrow), ERC1155_ID), ERC1155_AMOUNT);
        assertEq(escrow.pendingRefundOf(tradeId, 0), address(wallet));
        assertEq(escrow.pendingRefundOf(tradeId, 1), address(0));

        // Still refusing: the retry fails and the refund stays pending.
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__RefundFailed.selector);
        escrow.claimRefund(tradeId, 0);
        assertEq(escrow.pendingRefundOf(tradeId, 0), address(wallet));

        // Once it accepts again, anyone can deliver it — only to the recorded recipient.
        vm.prank(alice);
        wallet.setRejectERC1155(false);
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
        uint256 tradeId = _createWalletTradeRequestingUsdc();
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__NoPendingRefund.selector);
        escrow.claimRefund(tradeId, 0);
    }

    // =========================================================================
    // Audit fixes: admin hardening (M-2, L-5)
    // =========================================================================

    function test_renounceOwnership_disabled() public {
        vm.prank(admin);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__RenounceDisabled.selector);
        escrow.renounceOwnership();
        assertEq(escrow.owner(), admin);
    }

    function test_setRefundRecipient_escrowItself_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__ZeroAddress.selector);
        escrow.setRefundRecipient(address(escrow));
    }

    function test_implementation_cannotBeInitialized() public {
        P2PTradeEscrow impl = new P2PTradeEscrow();
        vm.expectRevert();
        impl.initialize(carol);
    }

    // =========================================================================
    // Audit fixes: signature hardening (L-1, L-4) + coverage gaps
    // =========================================================================

    function test_signatureTtl_capped() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        p.validBefore = p.validAfter + escrow.MAX_SIGNATURE_TTL() + 1;
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__SignatureTtlTooLong.selector);
        escrow.createTradeFor(p, sig);

        // Exactly the cap is fine.
        p = _defaultParams(2);
        p.validBefore = p.validAfter + escrow.MAX_SIGNATURE_TTL();
        sig = _sign(alicePk, _createDigest(address(escrow), p));
        vm.prank(coinflow);
        escrow.createTradeFor(p, sig);
    }

    /// @dev LOW-3 (second audit): a long-lived signature must stay unusable for its whole life,
    ///      including the last hour before validBefore — the cap is on the signed window, not
    ///      on how far ahead of expiry it is submitted.
    function test_signatureTtl_longLivedSignatureNeverUsable() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        p.validBefore = p.validAfter + 30 days;
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__SignatureTtlTooLong.selector);
        escrow.createTradeFor(p, sig);

        vm.warp(p.validBefore - 30 minutes);
        vm.prank(carol);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__SignatureTtlTooLong.selector);
        escrow.createTradeFor(p, sig);
    }

    function test_signature_beforeValidAfter_reverts_thenUsableInsideWindow() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        p.validAfter = block.timestamp + 1 days;
        p.validBefore = p.validAfter + SIG_TTL;
        p.deadline = uint64(p.validBefore + 7 days);
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__SignatureNotYetValid.selector);
        escrow.createTradeFor(p, sig);

        // The signed window bounds when it can be used; inside it, it works.
        vm.warp(p.validAfter);
        vm.prank(coinflow);
        escrow.createTradeFor(p, sig);
    }

    function test_signatureWindow_enforcedOnCounterAndAccept() public {
        uint256 tradeId = _createWalletTradeRequestingUsdc();
        uint256 validAfter = block.timestamp;
        uint256 tooLate = validAfter + escrow.MAX_SIGNATURE_TTL() + 1;

        bytes memory acceptSig = _sign(bobPk, _acceptDigest(tradeId, bob, 1, tooLate, validAfter));
        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__SignatureTtlTooLong.selector);
        escrow.acceptTradeFor(tradeId, 1, tooLate, validAfter, acceptSig);

        IP2PTradeEscrow.CounterTradeParams memory c = _defaultCounterParams(tradeId, 2);
        c.validBefore = tooLate;
        bytes memory counterSig = _sign(bobPk, _counterDigest(c, bob));
        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__SignatureTtlTooLong.selector);
        escrow.counterTradeFor(c, counterSig);

        // validAfter is signed: submitting a different value breaks the signature.
        uint256 validBefore = validAfter + SIG_TTL;
        acceptSig = _sign(bobPk, _acceptDigest(tradeId, bob, 3, validBefore, validAfter));
        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.acceptTradeFor(tradeId, 3, validBefore, validAfter - 1, acceptSig);
    }

    /// @dev AcceptTrade binds both bundles: a signature over different contents is useless.
    function test_acceptTradeFor_signatureOverOtherBundle_reverts() public {
        uint256 tradeId = _createWalletTradeRequestingUsdc();
        uint256 validBefore = block.timestamp + SIG_TTL;
        uint256 validAfter = block.timestamp;
        bytes memory sig = _sign(
            bobPk,
            _acceptDigestFor(
                tradeId,
                bob,
                _one(_nft(ALICE_NFT)),
                _one(_nft(BOB_NFT)), // the user was shown no USDC request
                1,
                validBefore,
                validAfter
            )
        );

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.acceptTradeFor(tradeId, 1, validBefore, validAfter, sig);
    }

    /// @dev Nonces are shared across the three typed structs, but a signature of one type
    ///      never verifies as another.
    function test_signature_crossTypeReplay_reverts() public {
        uint256 tradeId = _createWalletTradeRequestingUsdc();
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        p.initiator = bob;
        p.counterparty = alice;
        p.offered = _one(_nft(BOB_NFT));
        p.requested = _one(_nft(ALICE_NFT));
        bytes memory createSig = _sign(bobPk, _createDigest(address(escrow), p));

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.acceptTradeFor(tradeId, 1, p.validBefore, p.validAfter, createSig);
    }

    function test_signature_highS_reverts() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, _createDigest(address(escrow), p));
        bytes memory malleated = abi.encodePacked(
            r,
            bytes32(SECP256K1_N - uint256(s)),
            v == 27 ? uint8(28) : uint8(27)
        );

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.createTradeFor(p, malleated);
    }

    function test_nonexistentTrade_actionsRevert() public {
        uint256 missing = 999;

        vm.prank(coinflow);
        vm.expectRevert(IP2PTradeEscrow.P2PTradeEscrow__InvalidSignature.selector);
        escrow.acceptTradeFor(missing, 1, block.timestamp + SIG_TTL, block.timestamp, hex"");

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

    function test_counterTradeFor_selfSubmitted_isWalletTrade() public {
        uint256 original = _createNftSwap();
        IP2PTradeEscrow.CounterTradeParams memory p = _defaultCounterParams(original, 1);
        bytes memory sig = _sign(bobPk, _counterDigest(p, bob));

        vm.prank(bob);
        uint256 counter = escrow.counterTradeFor(p, sig);

        assertEq(escrow.erc20PayerOf(counter), address(0));
        assertEq(usdc.balanceOf(bob), STARTING_USDC - USDC_AMOUNT);
    }

    function test_cancelFundedTrade_onFundedCounter() public {
        uint256 original = _createNftSwap();
        IP2PTradeEscrow.CounterTradeParams memory p = _defaultCounterParams(original, 1);
        bytes memory sig = _sign(bobPk, _counterDigest(p, bob));
        vm.prank(coinflow);
        uint256 counter = escrow.counterTradeFor(p, sig);

        vm.prank(refundVault);
        escrow.cancelFundedTrade(counter);

        assertEq(usdc.balanceOf(refundVault), USDC_AMOUNT);
        assertEq(nft.ownerOf(BOB_NFT), bob);
        assertEq(usdc.balanceOf(bob), STARTING_USDC);
    }

    function test_duplicateErc20Items_refundedInFull() public {
        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        IP2PTradeEscrow.Asset[] memory offered = new IP2PTradeEscrow.Asset[](3);
        offered[0] = _nft(ALICE_NFT);
        offered[1] = _usdc(10e6);
        offered[2] = _usdc(20e6);
        p.offered = offered;
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));
        vm.prank(coinflow);
        uint256 tradeId = escrow.createTradeFor(p, sig);

        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        assertEq(usdc.balanceOf(refundVault), 30e6);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    // =========================================================================
    // Fuzz: every asset returns to whoever supplied it
    // =========================================================================

    function testFuzz_createTradeFor_cancel_routesRefunds(
        uint256 usdcAmount,
        uint256 erc1155Amount
    ) public {
        usdcAmount = bound(usdcAmount, 1, STARTING_USDC);
        erc1155Amount = bound(erc1155Amount, 1, ERC1155_AMOUNT);

        IP2PTradeEscrow.Asset[] memory offered = new IP2PTradeEscrow.Asset[](3);
        offered[0] = _nft(ALICE_NFT);
        offered[1] = _1155(erc1155Amount);
        offered[2] = _usdc(usdcAmount);

        IP2PTradeEscrow.CreateTradeParams memory p = _defaultParams(1);
        p.offered = offered;
        bytes memory sig = _sign(alicePk, _createDigest(address(escrow), p));
        vm.prank(coinflow);
        uint256 tradeId = escrow.createTradeFor(p, sig);

        vm.prank(alice);
        escrow.cancelTrade(tradeId);

        assertEq(nft.ownerOf(ALICE_NFT), alice);
        assertEq(erc1155.balanceOf(alice, ERC1155_ID), ERC1155_AMOUNT);
        assertEq(usdc.balanceOf(alice), STARTING_USDC);
        assertEq(usdc.balanceOf(refundVault), usdcAmount);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
}
