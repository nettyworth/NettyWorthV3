// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackMachine} from "../PackMachine.sol";
import {PackMachineFactory} from "../PackMachineFactory.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PackRegistry} from "../PackRegistry.sol";
import {BuybackPool} from "../BuybackPool.sol";
import {IBuybackPool} from "../interfaces/IBuybackPool.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";
import {MockPermit2} from "../test-helpers/MockPermit2.sol";
import {MockAssetLendingPool} from "../test-helpers/MockAssetLendingPool.sol";

/// @title BuybackModelTest
/// @notice Tests for the two-model buyback system:
///         - AmountSpent: payout = pricePerCard × bps (existing behaviour)
///         - FMV: payout = signedFMV × bps (new EIP-712 signed-quote path)
contract BuybackModelTest is Test {
    PackMachine internal packMachine;
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
    PackRegistry internal packRegistry;
    BuybackPool internal pool;
    PermissionManager internal pm;
    MockERC20 internal usdc;
    AssetNFT internal assetNFT;
    MockVRFCoordinatorV2Plus internal coordinator;

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal upgrader = makeAddr("upgrader");
    address internal forwarder = makeAddr("forwarder");
    address internal financeWallet = makeAddr("financeWallet");
    address internal user = makeAddr("user");
    address internal unauthorized = makeAddr("unauthorized");

    uint256 internal operatorPk;
    address internal operator;

    // Separate key pair for signing FMV quotes (held by the operator, i.e. PACK_OPERATOR_ROLE).
    uint256 internal fmvSignerPk;
    address internal fmvSigner;

    // Tracks how many VRF requests have been made so we can pass the right requestId to fulfillRandomWords.
    uint256 internal _vrfRequestCounter;

    address internal constant PERMIT2_ADDRESS =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant OPEN_PACK_TYPEHASH =
        keccak256("OpenPack(address user,uint256 packId,uint256 nonce,bytes32 codeId)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 internal constant FMV_QUOTE_TYPEHASH =
        keccak256(
            "FMVQuote(uint256 tokenId,uint256 fmv,uint256 deadline,uint256 nonce,address seller)"
        );

    uint128 internal constant PRICE = 10e6; // 10 USDC
    uint8 internal constant CARDS_PER_PACK = 2;
    uint128 internal constant PRICE_PER_CARD = PRICE / CARDS_PER_PACK; // 5 USDC
    uint16 internal constant BUYBACK_ALLOC_BPS = 2000; // 20%

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        (operator, operatorPk) = makeAddrAndKey("operator");
        (fmvSigner, fmvSignerPk) = makeAddrAndKey("fmvSigner");

        // PermissionManager
        PermissionManager pmImpl = new PermissionManager();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl),
            abi.encodeCall(PermissionManager.initialize, (admin))
        );
        pm = PermissionManager(address(pmProxy));

        vm.startPrank(admin);
        pm.grantRole(pm.PACK_OPERATOR_ROLE(), operator);
        pm.grantRole(pm.PACK_OPERATOR_ROLE(), fmvSigner); // fmvSigner holds PACK_OPERATOR_ROLE
        pm.grantRole(pm.PAUSER_ROLE(), pauser);
        pm.grantRole(pm.UPGRADER_ROLE(), upgrader);
        pm.grantRole(pm.MINTER_ROLE(), operator);
        vm.stopPrank();

        usdc = new MockERC20();
        coordinator = new MockVRFCoordinatorV2Plus();

        AssetNFT assetNFTImpl = new AssetNFT(forwarder);
        ERC1967Proxy assetNFTProxy = new ERC1967Proxy(
            address(assetNFTImpl),
            abi.encodeCall(
                AssetNFT.initialize,
                (
                    address(pm),
                    "NettyWorth Assets",
                    "NWA",
                    "ipfs://contract",
                    makeAddr("royalty"),
                    250
                )
            )
        );
        assetNFT = AssetNFT(address(assetNFTProxy));

        MockPermit2 permit2Impl = new MockPermit2();
        vm.etch(PERMIT2_ADDRESS, address(permit2Impl).code);

        PackVRFRouter routerImpl = new PackVRFRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                PackVRFRouter.initialize,
                (
                    address(pm),
                    address(coordinator),
                    1,
                    keccak256("key"),
                    700_000,
                    3
                )
            )
        );
        vrfRouter = PackVRFRouter(address(routerProxy));

        PackMachine machineImpl = new PackMachine(forwarder);
        PackMachineFactory factoryImpl = new PackMachineFactory(forwarder);
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                PackMachineFactory.initialize,
                (address(pm), address(assetNFT), address(usdc), financeWallet)
            )
        );
        factory = PackMachineFactory(address(factoryProxy));

        vm.startPrank(admin);
        factory.setImplementation(address(machineImpl));
        factory.setPackVRFRouter(address(vrfRouter));
        vm.stopPrank();

        PackRegistry registryImpl = new PackRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(PackRegistry.initialize, (address(pm)))
        );
        packRegistry = PackRegistry(address(registryProxy));

        vm.startPrank(admin);
        factory.setPackRegistry(address(packRegistry));
        packRegistry.setFactory(address(factory));
        vm.stopPrank();

        vm.prank(operator);
        address cloneAddr = factory.createPackMachine(
            PRICE,
            CARDS_PER_PACK,
            uint40(block.timestamp)
        );
        packMachine = PackMachine(cloneAddr);

        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(cloneAddr, true);

        BuybackPool poolImpl = new BuybackPool();
        ERC1967Proxy poolProxy = new ERC1967Proxy(
            address(poolImpl),
            abi.encodeCall(
                BuybackPool.initialize,
                (
                    address(pm),
                    address(assetNFT),
                    address(usdc),
                    financeWallet,
                    address(factory)
                )
            )
        );
        pool = BuybackPool(address(poolProxy));

        vm.prank(pauser);
        packMachine.pause();
        vm.prank(operator);
        packMachine.setBuybackPool(address(pool));
        vm.prank(pauser);
        packMachine.unpause();
        vm.prank(operator);
        packRegistry.setPackBuybackAllocation(address(packMachine), 0, BUYBACK_ALLOC_BPS);

        // Wire mock lending pool so getAppraisalValue works
        MockAssetLendingPool mockLendingPool = new MockAssetLendingPool();
        vm.prank(admin);
        assetNFT.setLendingPool(address(mockLendingPool));

        // Wide-open FMV bounds so deposits don't require per-token appraisals
        uint128[6] memory minFmv;
        uint128[6] memory maxFmv;
        for (uint256 t; t < 6; ++t) maxFmv[t] = type(uint128).max;
        vm.prank(operator);
        packRegistry.setPackTierFmvBounds(address(packMachine), 0, minFmv, maxFmv);

        vm.prank(operator);
        pool.registerPackMachine(address(packMachine), true);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _depositNFTs(uint256 count) internal {
        uint256 startId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        uint8[] memory tiers = new uint8[](count);
        uint256[] memory tokenIds = new uint256[](count);
        for (uint256 i; i < count; i++) {
            recipients[i] = operator;
            uris[i] = "";
            tokenIds[i] = startId + i;
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        uint256[] memory masks = new uint256[](count);
        for (uint256 i; i < count; i++) masks[i] = 1;
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(tokenIds, tiers, masks, operator);
        vm.stopPrank();
    }

    function _signOpenPack(
        address user_,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user_, uint256(0), nonce, bytes32(0))
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                address(packMachine)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _openPackAndFulfill()
        internal
        returns (uint256[] memory wonTokens)
    {
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, packMachine.getUserInfo(user).openNonce);
        vm.prank(user);
        packMachine.openPack(user, 0, sig);

        // MockVRFCoordinator assigns sequential IDs starting from 1.
        uint256 requestId = ++_vrfRequestCounter;
        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        for (uint256 i; i < CARDS_PER_PACK; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(requestId, i)));
        }
        coordinator.fulfillRandomWords(address(vrfRouter), requestId, words);

        wonTokens = new uint256[](CARDS_PER_PACK);
        uint256 found;
        for (uint256 tokenId = 1; tokenId <= assetNFT.totalSupply(); tokenId++) {
            if (assetNFT.ownerOf(tokenId) == user) {
                wonTokens[found++] = tokenId;
                if (found == CARDS_PER_PACK) break;
            }
        }
    }

    function _seedPool(uint256 amount) internal {
        usdc.mint(address(pool), amount);
    }

    /// @dev Build and sign an FMVQuote using the fmvSignerPk key.
    function _signFMVQuote(
        uint256 tokenId,
        uint256 fmv,
        uint256 deadline,
        uint256 nonce,
        address seller
    ) internal view returns (IBuybackPool.FMVQuote memory quote, bytes memory sig) {
        quote = IBuybackPool.FMVQuote({
            tokenId: tokenId,
            fmv: fmv,
            deadline: deadline,
            nonce: nonce,
            seller: seller
        });
        // Build EIP-712 domain separator matching what BuybackPool uses:
        // name="NettyWorthBuyback", version="1"
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("NettyWorthBuyback"),
                keccak256("1"),
                block.chainid,
                address(pool)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(FMV_QUOTE_TYPEHASH, tokenId, fmv, deadline, nonce, seller)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fmvSignerPk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    // =========================================================================
    // Default model config (AmountSpent out of the box)
    // =========================================================================

    function test_DefaultModel_IsAmountSpent() public view {
        assertEq(
            uint8(pool.getDefaultBuybackModel()),
            uint8(IBuybackPool.BuybackModel.AmountSpent)
        );
    }

    function test_BothModelsEnabledByDefault() public view {
        assertTrue(pool.isModelEnabled(IBuybackPool.BuybackModel.AmountSpent));
        assertTrue(pool.isModelEnabled(IBuybackPool.BuybackModel.FMV));
    }

    function test_PerMachineModel_DefaultsToUnset() public view {
        assertEq(
            uint8(pool.getPackMachineBuybackModel(address(packMachine))),
            uint8(IBuybackPool.BuybackModel.Unset)
        );
    }

    function test_ResolvedModel_FallsToDefault_WhenUnset() public view {
        assertEq(
            uint8(pool.getResolvedModel(address(packMachine))),
            uint8(IBuybackPool.BuybackModel.AmountSpent)
        );
    }

    // =========================================================================
    // Option 2 — AmountSpent model (backwards-compatible)
    // =========================================================================

    function test_AmountSpent_Pays80PercentByDefault() public {
        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 expected = (uint256(PRICE_PER_CARD) * 8000) / 10000;

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        pool.buyback(tokenId);
        assertEq(usdc.balanceOf(user) - before, expected);
    }

    function test_AmountSpent_ExplicitlySet_Pays80Percent() public {
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.AmountSpent
        );

        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 expected = (uint256(PRICE_PER_CARD) * 8000) / 10000;

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        pool.buyback(tokenId);
        assertEq(usdc.balanceOf(user) - before, expected);
    }

    function test_AmountSpent_WithPromoBoost_Uses98PercentOfPackPrice() public {
        // 98% of PRICE_PER_CARD = 4.9 USDC
        _seedPool(20e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 expected = (uint256(PRICE_PER_CARD) * 9800) / 10000;

        // Override bps via a per-machine rate (simulating a high-rate pack)
        vm.prank(operator);
        pool.setPackMachineBuybackBps(address(packMachine), 9800);

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        pool.buyback(tokenId);
        assertEq(usdc.balanceOf(user) - before, expected);
    }

    // =========================================================================
    // Option 1 — FMV model
    // =========================================================================

    function test_FMV_Pays80PercentOfSignedFMV() public {
        // Set this machine to FMV model
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 fmv = 100e6; // card FMV = $100
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = pool.fmvQuoteNonce(tokenId); // should be 0

        (IBuybackPool.FMVQuote memory quote, bytes memory sig) = _signFMVQuote(
            tokenId,
            fmv,
            deadline,
            nonce,
            user
        );

        uint256 expected = (fmv * 8000) / 10000; // 80% of $100 = $80

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);
        assertEq(usdc.balanceOf(user) - before, expected);
    }

    function test_FMV_PayoutIsBasedOnFMV_NotPackPrice() public {
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 fmv = 100e6;
        uint256 deadline = block.timestamp + 1 hours;

        (IBuybackPool.FMVQuote memory quote, bytes memory sig) = _signFMVQuote(
            tokenId,
            fmv,
            deadline,
            pool.fmvQuoteNonce(tokenId),
            user
        );

        // FMV payout must differ from amount-spent payout
        uint256 fmvPayout = (fmv * 8000) / 10000;
        uint256 amountSpentPayout = (uint256(PRICE_PER_CARD) * 8000) / 10000;
        assertTrue(fmvPayout != amountSpentPayout, "payouts should differ");

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);
        assertEq(usdc.balanceOf(user) - before, fmvPayout);
    }

    function test_FMV_GlobalDefault_AllPacksMustUseSignedQuote() public {
        // Set global default to FMV
        vm.prank(operator);
        pool.setDefaultBuybackModel(IBuybackPool.BuybackModel.FMV);

        assertEq(
            uint8(pool.getResolvedModel(address(packMachine))),
            uint8(IBuybackPool.BuybackModel.FMV)
        );

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        // Without a quote: reverts
        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(BuybackPool.BuybackPool__FMVQuoteRequired.selector);
        vm.prank(user);
        pool.buyback(tokenId);
    }

    // =========================================================================
    // FMV quote validation — error cases
    // =========================================================================

    function test_FMV_RevertsIfModelNotFMV_ButQuoteProvided_OK() public {
        // Supplying a quote when model is AmountSpent is allowed (quote is ignored for payout).
        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        (IBuybackPool.FMVQuote memory quote, bytes memory sig) = _signFMVQuote(
            tokenId,
            999e6, // large FMV — should be ignored
            block.timestamp + 1 hours,
            pool.fmvQuoteNonce(tokenId),
            user
        );

        uint256 expectedAmountSpent = (uint256(PRICE_PER_CARD) * 8000) / 10000;

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        uint256 before = usdc.balanceOf(user);
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);
        // Payout is based on pack price, not the FMV in the quote
        assertEq(usdc.balanceOf(user) - before, expectedAmountSpent);
    }

    function test_FMV_RevertsOnBadSigner() public {
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        // Sign with an account that does NOT hold PACK_OPERATOR_ROLE
        (, uint256 badPk) = makeAddrAndKey("badSigner");
        IBuybackPool.FMVQuote memory quote = IBuybackPool.FMVQuote({
            tokenId: tokenId,
            fmv: 100e6,
            deadline: block.timestamp + 1 hours,
            nonce: pool.fmvQuoteNonce(tokenId),
            seller: user
        });
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("NettyWorthBuyback"),
                keccak256("1"),
                block.chainid,
                address(pool)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                FMV_QUOTE_TYPEHASH,
                quote.tokenId,
                quote.fmv,
                quote.deadline,
                quote.nonce,
                quote.seller
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                structHash
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(); // BuybackPool__InvalidFMVSigner
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);
    }

    function test_FMV_RevertsOnExpiredDeadline() public {
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 deadline = block.timestamp - 1; // already expired
        (IBuybackPool.FMVQuote memory quote, bytes memory sig) = _signFMVQuote(
            tokenId,
            100e6,
            deadline,
            pool.fmvQuoteNonce(tokenId),
            user
        );

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__FMVQuoteExpired.selector,
                deadline,
                block.timestamp
            )
        );
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);
    }

    function test_FMV_RevertsOnBadNonce() public {
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 wrongNonce = pool.fmvQuoteNonce(tokenId) + 999;
        (IBuybackPool.FMVQuote memory quote, bytes memory sig) = _signFMVQuote(
            tokenId,
            100e6,
            block.timestamp + 1 hours,
            wrongNonce,
            user
        );

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__FMVQuoteBadNonce.selector,
                pool.fmvQuoteNonce(tokenId),
                wrongNonce
            )
        );
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);
    }

    function test_FMV_RevertsOnTokenMismatch() public {
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 wrongTokenId = tokenId + 9999;
        // Sign a quote for a different tokenId
        (IBuybackPool.FMVQuote memory quote, bytes memory sig) = _signFMVQuote(
            wrongTokenId,
            100e6,
            block.timestamp + 1 hours,
            0,
            user
        );

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__FMVQuoteTokenMismatch.selector,
                tokenId,
                wrongTokenId
            )
        );
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);
    }

    function test_FMV_NonceIncrementsAfterUse() public {
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 nonceBefore = pool.fmvQuoteNonce(tokenId);
        assertEq(nonceBefore, 0);

        (IBuybackPool.FMVQuote memory quote, bytes memory sig) = _signFMVQuote(
            tokenId,
            100e6,
            block.timestamp + 1 hours,
            nonceBefore,
            user
        );

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);

        assertEq(pool.fmvQuoteNonce(tokenId), nonceBefore + 1);
    }

    function test_FMV_RevertsOnReplayWithSameNonce() public {
        // Even if the user re-wins the same tokenId (after buyback + re-deposit + re-win),
        // the old quote cannot be replayed because the nonce incremented.
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 nonce = pool.fmvQuoteNonce(tokenId);
        (IBuybackPool.FMVQuote memory quote, bytes memory sig) = _signFMVQuote(
            tokenId,
            100e6,
            block.timestamp + 1 hours,
            nonce,
            user
        );

        // First use: succeeds, nonce = 0 → 1
        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);
        assertEq(pool.fmvQuoteNonce(tokenId), nonce + 1);

        // Simulate user re-winning the same token (re-register manually)
        vm.prank(address(packMachine));
        pool.registerToken(tokenId, PRICE_PER_CARD, 0, address(packMachine));

        // Manually transfer token back to user for the scenario
        vm.prank(address(packMachine));
        assetNFT.transferFrom(address(packMachine), user, tokenId);

        // Replay same quote: nonce is now 1, quote has nonce=0 → reverts
        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__FMVQuoteBadNonce.selector,
                nonce + 1,
                nonce
            )
        );
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);
    }

    function test_FMV_RequiredReverts_OnNoQuoteOverload() public {
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);

        // buyback(tokenId) — no quote, FMV model → must revert
        vm.expectRevert(BuybackPool.BuybackPool__FMVQuoteRequired.selector);
        vm.prank(user);
        pool.buyback(tokenId);

        // buyback(tokenId, codeId) — no quote, FMV model → must revert
        vm.expectRevert(BuybackPool.BuybackPool__FMVQuoteRequired.selector);
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0));
    }

    // =========================================================================
    // Model override: per-machine beats global
    // =========================================================================

    function test_PerMachineOverride_BeatsGlobalDefault() public {
        // Global default = FMV
        vm.prank(operator);
        pool.setDefaultBuybackModel(IBuybackPool.BuybackModel.FMV);

        // This specific machine overrides to AmountSpent
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.AmountSpent
        );

        // Resolved model for this machine should be AmountSpent
        assertEq(
            uint8(pool.getResolvedModel(address(packMachine))),
            uint8(IBuybackPool.BuybackModel.AmountSpent)
        );

        // Buyback without quote should succeed
        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        // Should not revert (no quote needed for AmountSpent)
        vm.prank(user);
        pool.buyback(tokenId);
    }

    function test_ClearPerMachineOverride_FallsToGlobalDefault() public {
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );
        assertEq(
            uint8(pool.getResolvedModel(address(packMachine))),
            uint8(IBuybackPool.BuybackModel.FMV)
        );

        // Clear override with Unset
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.Unset
        );
        // Should fall back to global default (AmountSpent)
        assertEq(
            uint8(pool.getResolvedModel(address(packMachine))),
            uint8(IBuybackPool.BuybackModel.AmountSpent)
        );
    }

    // =========================================================================
    // Global model enable/disable
    // =========================================================================

    function test_DisableAmountSpentModel_Reverts() public {
        vm.prank(operator);
        pool.setModelEnabled(IBuybackPool.BuybackModel.AmountSpent, false);

        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__ModelDisabled.selector,
                IBuybackPool.BuybackModel.AmountSpent
            )
        );
        vm.prank(user);
        pool.buyback(tokenId);
    }

    function test_DisableFMVModel_Reverts() public {
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );
        vm.prank(operator);
        pool.setModelEnabled(IBuybackPool.BuybackModel.FMV, false);

        _seedPool(200e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        (IBuybackPool.FMVQuote memory quote, bytes memory sig) = _signFMVQuote(
            tokenId,
            100e6,
            block.timestamp + 1 hours,
            pool.fmvQuoteNonce(tokenId),
            user
        );

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__ModelDisabled.selector,
                IBuybackPool.BuybackModel.FMV
            )
        );
        vm.prank(user);
        pool.buyback(tokenId, bytes32(0), quote, sig);
    }

    function test_ReEnableModel_AllowsBuyback() public {
        vm.prank(operator);
        pool.setModelEnabled(IBuybackPool.BuybackModel.AmountSpent, false);
        vm.prank(operator);
        pool.setModelEnabled(IBuybackPool.BuybackModel.AmountSpent, true);

        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        // Should no longer revert
        vm.prank(user);
        pool.buyback(tokenId);
    }

    // =========================================================================
    // setDefaultBuybackModel validation
    // =========================================================================

    function test_SetDefaultModel_RejectsUnset() public {
        vm.expectRevert(BuybackPool.BuybackPool__InvalidModel.selector);
        vm.prank(operator);
        pool.setDefaultBuybackModel(IBuybackPool.BuybackModel.Unset);
    }

    function test_SetDefaultModel_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit BuybackPool.DefaultBuybackModelUpdated(
            IBuybackPool.BuybackModel.AmountSpent,
            IBuybackPool.BuybackModel.FMV
        );
        vm.prank(operator);
        pool.setDefaultBuybackModel(IBuybackPool.BuybackModel.FMV);
        assertEq(
            uint8(pool.getDefaultBuybackModel()),
            uint8(IBuybackPool.BuybackModel.FMV)
        );
    }

    function test_SetModelEnabled_RejectsUnset() public {
        vm.expectRevert(BuybackPool.BuybackPool__InvalidModel.selector);
        vm.prank(operator);
        pool.setModelEnabled(IBuybackPool.BuybackModel.Unset, false);
    }

    function test_SetPackMachineModel_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit BuybackPool.PackMachineBuybackModelUpdated(
            address(packMachine),
            IBuybackPool.BuybackModel.Unset,
            IBuybackPool.BuybackModel.FMV
        );
        vm.prank(operator);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );
    }

    function test_SetModelEnabled_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit BuybackPool.ModelEnabledUpdated(
            IBuybackPool.BuybackModel.FMV,
            false
        );
        vm.prank(operator);
        pool.setModelEnabled(IBuybackPool.BuybackModel.FMV, false);
    }

    function test_AdminFunctions_RevertForUnauthorized() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setDefaultBuybackModel(IBuybackPool.BuybackModel.FMV);

        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setPackMachineBuybackModel(
            address(packMachine),
            IBuybackPool.BuybackModel.FMV
        );

        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setModelEnabled(IBuybackPool.BuybackModel.FMV, false);
    }
}
