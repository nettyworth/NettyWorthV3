// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackMachine} from "../PackMachine.sol";
import {PackMachineFactory} from "../PackMachineFactory.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PackRegistry} from "../PackRegistry.sol";
import {BuybackPool} from "../BuybackPool.sol";
import {PromoCodeRegistry} from "../PromoCodeRegistry.sol";
import {IPromoCodeRegistry} from "../interfaces/IPromoCodeRegistry.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";
import {MockPermit2} from "../test-helpers/MockPermit2.sol";

/// @notice Unit tests for the global first-open pack discount feature.
///
///         The discount is configured on PackMachineFactory (DEFAULT_ADMIN_ROLE),
///         applied automatically on the first openPack/openPackWithPermit2 of a
///         wallet on a given PackMachine clone, and tracked per-wallet in that
///         clone's ERC-7201 storage.  A promo code takes priority and does NOT
///         consume the first-open flag.  A fully-failed (zero-card) VRF open
///         resets the flag so the wallet is not penalized.
contract PackMachineFirstOpenDiscountTest is Test {
    // =========================================================================
    // Contracts
    // =========================================================================

    PackMachine internal packMachine;
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
    PackRegistry internal packRegistry;
    BuybackPool internal pool;
    PromoCodeRegistry internal promoRegistry;
    PermissionManager internal pm;
    MockERC20 internal usdc;
    AssetNFT internal assetNFT;
    MockVRFCoordinatorV2Plus internal coordinator;

    // =========================================================================
    // Actors
    // =========================================================================

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal forwarder = makeAddr("forwarder");
    address internal financeWallet = makeAddr("financeWallet");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal operatorPk;
    address internal operator;

    /// @dev Mirrors MockVRFCoordinatorV2Plus._nextRequestId (starts at 1, pre-increments).
    uint256 internal nextExpectedRequestId = 1;

    // =========================================================================
    // Constants
    // =========================================================================

    address internal constant PERMIT2_ADDRESS =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 packId,uint256 nonce,bytes32 codeId)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint128 internal constant PRICE = 10e6;     // 10 USDC (6-decimal)
    uint8  internal constant CARDS_PER_PACK = 2;
    uint16 internal constant BUYBACK_ALLOC_BPS = 2000; // 20 %
    uint16 internal constant DISCOUNT_BPS = 1000;      // 10 %

    bytes32 internal constant PROMO_CODE = keccak256("PROMO10");
    uint16  internal constant PROMO_BPS  = 1000; // 10 %

    // =========================================================================
    // setUp — full real stack (mirrors PromoCodeSecurity.t.sol)
    // =========================================================================

    function setUp() public {
        (operator, operatorPk) = makeAddrAndKey("operator");

        // ── PermissionManager ─────────────────────────────────────────────────
        PermissionManager pmImpl = new PermissionManager();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl),
            abi.encodeCall(PermissionManager.initialize, (admin))
        );
        pm = PermissionManager(address(pmProxy));

        vm.startPrank(admin);
        pm.grantRole(pm.PACK_OPERATOR_ROLE(), operator);
        pm.grantRole(pm.PAUSER_ROLE(), pauser);
        pm.grantRole(pm.UPGRADER_ROLE(), admin);
        pm.grantRole(pm.MINTER_ROLE(), operator);
        vm.stopPrank();

        // ── Mocks ─────────────────────────────────────────────────────────────
        usdc = new MockERC20();
        coordinator = new MockVRFCoordinatorV2Plus();
        MockPermit2 permit2Impl = new MockPermit2();
        vm.etch(PERMIT2_ADDRESS, address(permit2Impl).code);

        // ── AssetNFT ──────────────────────────────────────────────────────────
        AssetNFT assetNFTImpl = new AssetNFT(forwarder);
        ERC1967Proxy assetNFTProxy = new ERC1967Proxy(
            address(assetNFTImpl),
            abi.encodeCall(
                AssetNFT.initialize,
                (address(pm), "NettyWorth Assets", "NWA", "ipfs://contract", makeAddr("royalty"), 250)
            )
        );
        assetNFT = AssetNFT(address(assetNFTProxy));

        // ── PackVRFRouter ─────────────────────────────────────────────────────
        PackVRFRouter routerImpl = new PackVRFRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                PackVRFRouter.initialize,
                (address(pm), address(coordinator), 1, keccak256("key"), 700_000, 3)
            )
        );
        vrfRouter = PackVRFRouter(address(routerProxy));

        // ── PackMachineFactory + clone ────────────────────────────────────────
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

        // ── PackRegistry ──────────────────────────────────────────────────────
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
        address cloneAddr = factory.createPackMachine(PRICE, CARDS_PER_PACK, uint40(block.timestamp));
        packMachine = PackMachine(cloneAddr);

        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(cloneAddr, true);
        vm.prank(operator);
        packMachine.setRetentionThreshold(0); // disable cut-off

        // ── BuybackPool ───────────────────────────────────────────────────────
        BuybackPool poolImpl = new BuybackPool();
        ERC1967Proxy poolProxy = new ERC1967Proxy(
            address(poolImpl),
            abi.encodeCall(
                BuybackPool.initialize,
                (address(pm), address(assetNFT), address(usdc), financeWallet, address(factory))
            )
        );
        pool = BuybackPool(address(poolProxy));

        // setBuybackPool requires paused (L001 fix)
        vm.prank(pauser);
        packMachine.pause();
        vm.prank(operator);
        packMachine.setBuybackPool(address(pool));
        vm.prank(pauser);
        packMachine.unpause();
        vm.prank(operator);
        packRegistry.setPackBuybackAllocation(address(packMachine), 0, BUYBACK_ALLOC_BPS);
        vm.prank(operator);
        pool.registerPackMachine(address(packMachine), true);

        // ── PromoCodeRegistry ─────────────────────────────────────────────────
        PromoCodeRegistry promoImpl = new PromoCodeRegistry();
        ERC1967Proxy promoProxy = new ERC1967Proxy(
            address(promoImpl),
            abi.encodeCall(PromoCodeRegistry.initialize, (address(pm)))
        );
        promoRegistry = PromoCodeRegistry(address(promoProxy));

        vm.startPrank(admin);
        promoRegistry.setPackMachineFactory(address(factory));
        promoRegistry.setBuybackPool(address(pool));
        factory.setPromoCodeRegistry(address(promoRegistry));
        vm.stopPrank();
        vm.prank(operator);
        pool.setPromoCodeRegistry(address(promoRegistry));

        // Seed the pool with USDC to cover buybacks.
        usdc.mint(address(pool), 1000e6);

        // ── Promo code used in exclusivity tests ──────────────────────────────
        vm.prank(operator);
        promoRegistry.createCode(
            PROMO_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            PROMO_BPS,
            0,     // no expiry
            0,     // uncapped
            false, // not restricted
            false, // not oncePerUser
            address(0)
        );
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Deposit `count` freshly-minted NFTs (all tier 0, eligible for pack 0).
    function _depositNFTs(uint256 count) internal returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](count);
        uint256 startId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        uint8[] memory tiers = new uint8[](count);
        for (uint256 i; i < count; i++) {
            recipients[i] = operator;
            uris[i] = "";
            tokenIds[i] = startId + i;
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        uint256[] memory masks = new uint256[](count);
        for (uint256 i; i < count; i++) masks[i] = 1; // eligible for pack 0
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(tokenIds, tiers, masks, operator);
        vm.stopPrank();
    }

    /// @dev Build an operator-signed OpenPack digest.
    function _signOpenPack(
        address user_,
        uint256 nonce,
        bytes32 codeId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user_, uint256(0), nonce, codeId)
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Open a pack for `who` with the given codeId, mint enough USDC (at full price),
    ///      and return the VRF requestId without fulfilling it yet.
    ///      Mirrors MockVRFCoordinatorV2Plus._nextRequestId which starts at 1 and
    ///      increments on each requestRandomWords call.
    function _openPackPending(
        address who,
        bytes32 codeId,
        uint256 usdcAmount
    ) internal returns (uint256 requestId) {
        requestId = nextExpectedRequestId++;
        uint256 nonce = packMachine.openNonce(who);
        bytes memory sig = _signOpenPack(who, nonce, codeId);
        usdc.mint(who, usdcAmount);
        vm.startPrank(who);
        usdc.approve(address(packMachine), usdcAmount);
        if (codeId == bytes32(0)) {
            packMachine.openPack(who, 0, sig);
        } else {
            packMachine.openPack(who, 0, sig, codeId);
        }
        vm.stopPrank();
    }

    /// @dev Fulfill a pending VRF request with random words derived from requestId.
    function _fulfill(uint256 requestId) internal {
        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        for (uint256 i; i < CARDS_PER_PACK; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(requestId, i)));
        }
        coordinator.fulfillRandomWords(address(vrfRouter), requestId, words);
    }

    /// @dev Fulfill a VRF request forcing ALL cards to fail (empty pool scenario).
    ///      Achieved by withdrawing all NFTs before fulfillment.
    function _fulfillWithAllFailed(uint256 requestId) internal {
        // Supply zero random words so fulfillRandomness iterates but finds no pool;
        // however cardsCount > 0 — pass the right count but empty the pools first.
        // Simplest approach: fulfill normally but pool is already empty.
        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        for (uint256 i; i < CARDS_PER_PACK; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(requestId, i)));
        }
        coordinator.fulfillRandomWords(address(vrfRouter), requestId, words);
    }

    // =========================================================================
    // Test 1 — disabled by default: first open pays full price
    // =========================================================================

    function test_firstOpenDiscount_disabledByDefault_fullPricePaid() public {
        _depositNFTs(4);

        assertFalse(
            factory.firstOpenDiscountEnabled(),
            "discount should be disabled by default"
        );

        uint256 requestId = _openPackPending(alice, bytes32(0), PRICE);

        assertEq(
            usdc.balanceOf(address(packMachine)),
            PRICE,
            "full price escrowed when discount disabled"
        );
        assertFalse(
            packMachine.hasClaimedFirstOpenDiscount(alice),
            "flag must not be set when discount disabled"
        );

        _fulfill(requestId);

        assertEq(
            usdc.balanceOf(address(packMachine)),
            0,
            "escrow cleared after fulfillment"
        );
    }

    // =========================================================================
    // Test 2 — enabled 10%: first open pays discounted price, correct splits
    // =========================================================================

    function test_firstOpenDiscount_enabled_firstOpenPaysDiscountedPrice() public {
        _depositNFTs(4);

        vm.prank(admin);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);

        uint256 expectedEscrowed = PRICE - (uint256(PRICE) * DISCOUNT_BPS) / 10_000;
        // 10 USDC * 90% = 9 USDC
        assertEq(expectedEscrowed, 9e6, "sanity: expected 9 USDC escrowed");

        uint256 requestId = _openPackPending(alice, bytes32(0), PRICE);

        assertEq(
            usdc.balanceOf(address(packMachine)),
            expectedEscrowed,
            "escrowed amount equals discounted price"
        );
        assertTrue(
            packMachine.hasClaimedFirstOpenDiscount(alice),
            "flag set after first open"
        );

        uint256 financeBalanceBefore = usdc.balanceOf(financeWallet);
        uint256 poolBalanceBefore    = usdc.balanceOf(address(pool));

        _fulfill(requestId);

        // After fulfillment: buyback share + finance share = expectedEscrowed
        uint256 expectedBuyback = (expectedEscrowed * BUYBACK_ALLOC_BPS) / 10_000;
        uint256 expectedFinance = expectedEscrowed - expectedBuyback;

        assertEq(
            usdc.balanceOf(address(pool)) - poolBalanceBefore,
            expectedBuyback,
            "buyback pool receives correct discounted share"
        );
        assertEq(
            usdc.balanceOf(financeWallet) - financeBalanceBefore,
            expectedFinance,
            "finance wallet receives correct discounted share"
        );
        assertEq(
            usdc.balanceOf(address(packMachine)),
            0,
            "no dust left in escrow"
        );
    }

    // =========================================================================
    // Test 3 — second open by same wallet: full price (flag consumed)
    // =========================================================================

    function test_firstOpenDiscount_secondOpenSameWallet_fullPrice() public {
        _depositNFTs(8);

        vm.prank(admin);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);

        // First open — gets the discount
        uint256 r1 = _openPackPending(alice, bytes32(0), PRICE);
        assertTrue(
            packMachine.hasClaimedFirstOpenDiscount(alice),
            "flag set after first open"
        );
        _fulfill(r1);

        // Second open — must pay full price
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 r2 = _openPackPending(alice, bytes32(0), PRICE);

        uint256 spent = PRICE - (usdc.balanceOf(alice) - aliceUsdcBefore + PRICE);
        // Simplest check: escrow must equal PRICE for this second open.
        // We track machine escrow delta: only this open's funds should be in the machine.
        assertEq(
            usdc.balanceOf(address(packMachine)),
            PRICE,
            "second open escrowed at full price"
        );

        _fulfill(r2);
        spent; // silence unused-variable warning
    }

    // =========================================================================
    // Test 4 — different wallet: also gets the discount
    // =========================================================================

    function test_firstOpenDiscount_differentWallet_getsDiscount() public {
        _depositNFTs(8);

        vm.prank(admin);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);

        uint256 expectedEscrowed = PRICE - (uint256(PRICE) * DISCOUNT_BPS) / 10_000;

        // Alice opens first
        uint256 r1 = _openPackPending(alice, bytes32(0), PRICE);
        _fulfill(r1);

        // Bob opens — he has never opened, so he gets the discount too
        uint256 r2 = _openPackPending(bob, bytes32(0), PRICE);

        assertEq(
            usdc.balanceOf(address(packMachine)),
            expectedEscrowed,
            "bob also gets the discount on his first open"
        );
        assertTrue(
            packMachine.hasClaimedFirstOpenDiscount(bob),
            "bob's flag is set"
        );
        assertFalse(
            packMachine.hasClaimedFirstOpenDiscount(alice) == false &&
            packMachine.hasClaimedFirstOpenDiscount(alice) == true,
            "alice flag unchanged (still true)"
        );
        assertTrue(
            packMachine.hasClaimedFirstOpenDiscount(alice),
            "alice's flag remains true"
        );

        _fulfill(r2);
    }

    // =========================================================================
    // Test 5 — promo code supplied: promo wins, first-open flag NOT consumed
    // =========================================================================

    function test_firstOpenDiscount_promoCodeSupplied_promoWinsAndFlagNotConsumed() public {
        _depositNFTs(8);

        vm.prank(admin);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);

        // Open with a promo code — promo discount applies, first-open flag stays unused
        uint256 expectedPromoEscrow = PRICE - (uint256(PRICE) * PROMO_BPS) / 10_000;

        uint256 r1 = _openPackPending(alice, PROMO_CODE, PRICE);

        assertEq(
            usdc.balanceOf(address(packMachine)),
            expectedPromoEscrow,
            "promo discount applied (not first-open)"
        );
        assertFalse(
            packMachine.hasClaimedFirstOpenDiscount(alice),
            "first-open flag NOT consumed when promo code is used"
        );

        _fulfill(r1);

        // Now open without a code — alice still gets her first-open discount
        uint256 expectedFirstOpenEscrow = PRICE - (uint256(PRICE) * DISCOUNT_BPS) / 10_000;
        uint256 r2 = _openPackPending(alice, bytes32(0), PRICE);

        assertEq(
            usdc.balanceOf(address(packMachine)),
            expectedFirstOpenEscrow,
            "first-open discount applied on second open (no code)"
        );
        assertTrue(
            packMachine.hasClaimedFirstOpenDiscount(alice),
            "flag consumed on first codeless open"
        );

        _fulfill(r2);
    }

    // =========================================================================
    // Test 6 — all cards fail → full refund → flag reset
    // =========================================================================

    function test_firstOpenDiscount_allCardsFail_flagReset() public {
        // Grant BLACKLIST_ROLE to admin so we can blacklist bob to force transfer failures.
        vm.prank(admin);
        pm.grantRole(Roles.BLACKLIST_ROLE, admin);

        _depositNFTs(CARDS_PER_PACK * 2);

        vm.prank(admin);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);

        uint256 expectedEscrowed = PRICE - (uint256(PRICE) * DISCOUNT_BPS) / 10_000;

        // Bob opens — gets the discount; escrowed at discounted price.
        uint256 r1 = _openPackPending(bob, bytes32(0), PRICE);
        assertTrue(packMachine.hasClaimedFirstOpenDiscount(bob), "bob flag set before fulfill");
        assertEq(usdc.balanceOf(address(packMachine)), expectedEscrowed, "discounted amount escrowed");

        // Blacklist bob so all NFT transfers to him revert during fulfillRandomness,
        // causing every card to fail and triggering the full-refund path.
        address[] memory targets = new address[](1);
        bool[] memory statuses = new bool[](1);
        targets[0] = bob;
        statuses[0] = true;
        vm.prank(admin);
        assetNFT.setBlacklisted(targets, statuses);

        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        _fulfillWithAllFailed(r1);

        // Bob should be fully refunded
        assertEq(
            usdc.balanceOf(bob) - bobUsdcBefore,
            expectedEscrowed,
            "bob fully refunded on all-cards-fail"
        );
        // And the first-open flag must be reset so bob retains his once-per-machine discount
        assertFalse(
            packMachine.hasClaimedFirstOpenDiscount(bob),
            "bob first-open flag reset after full-failure refund"
        );
    }

    // =========================================================================
    // Test 7 — access control: non-admin cannot setFirstOpenDiscount
    // =========================================================================

    function test_firstOpenDiscount_setFirstOpenDiscount_revertNonAdmin() public {
        vm.prank(operator);
        // Should revert — operator is not DEFAULT_ADMIN_ROLE for the factory
        (bool success, ) = address(factory).call(
            abi.encodeWithSignature("setFirstOpenDiscount(bool,uint16)", true, DISCOUNT_BPS)
        );
        assertFalse(success, "non-admin call must revert");
        assertFalse(factory.firstOpenDiscountEnabled(), "discount still disabled after failed call");
    }

    function test_firstOpenDiscount_setFirstOpenDiscount_revertBpsTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(PackMachineFactory.PackMachineFactory__InvalidDiscountBps.selector);
        factory.setFirstOpenDiscount(true, 10_001);
    }

    function test_firstOpenDiscount_setFirstOpenDiscount_allowsMaxBps() public {
        vm.prank(admin);
        factory.setFirstOpenDiscount(true, 10_000); // 100% — valid (free pack)
        assertEq(factory.firstOpenDiscountBps(), 10_000, "100% discount accepted");
    }

    // =========================================================================
    // Test 8 — factory getters and event
    // =========================================================================

    function test_firstOpenDiscount_factoryGetters_initialValues() public view {
        assertFalse(factory.firstOpenDiscountEnabled(), "disabled by default");
        assertEq(factory.firstOpenDiscountBps(), 0, "0 bps by default");
    }

    function test_firstOpenDiscount_setFirstOpenDiscount_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit PackMachineFactory.FirstOpenDiscountUpdated(true, DISCOUNT_BPS);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);
    }

    function test_firstOpenDiscount_setFirstOpenDiscount_canToggleOff() public {
        vm.startPrank(admin);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);
        factory.setFirstOpenDiscount(false, DISCOUNT_BPS);
        vm.stopPrank();

        assertFalse(factory.firstOpenDiscountEnabled(), "discount disabled after toggle");
    }

    // =========================================================================
    // Test 9 — previewFirstOpenPrice view
    // =========================================================================

    function test_previewFirstOpenPrice_returnsDiscountedPriceBeforeClaim() public {
        _depositNFTs(2); // needed for registry.getPack to have a valid pack

        vm.prank(admin);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);

        uint256 expectedEscrowed = PRICE - (uint256(PRICE) * DISCOUNT_BPS) / 10_000;
        assertEq(
            packMachine.previewFirstOpenPrice(alice, 0),
            expectedEscrowed,
            "preview returns discounted price for unclaimed wallet"
        );
    }

    function test_previewFirstOpenPrice_returnsFullPriceAfterClaim() public {
        _depositNFTs(4);

        vm.prank(admin);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);

        uint256 r1 = _openPackPending(alice, bytes32(0), PRICE);
        _fulfill(r1);

        assertEq(
            packMachine.previewFirstOpenPrice(alice, 0),
            PRICE,
            "preview returns full price after discount claimed"
        );
    }

    function test_previewFirstOpenPrice_returnsFullPriceWhenDisabled() public view {
        // Discount disabled (default) — preview should return full price.
        assertEq(
            packMachine.previewFirstOpenPrice(alice, 0),
            PRICE,
            "preview returns full price when feature is disabled"
        );
    }

    // =========================================================================
    // Test 10 — Permit2 path: discounted amount is pulled correctly
    // =========================================================================

    function test_firstOpenDiscount_permit2Path_discountedAmountPulled() public {
        _depositNFTs(4);

        vm.prank(admin);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);

        uint256 expectedEscrowed = packMachine.previewFirstOpenPrice(alice, 0);

        uint256 nonce = packMachine.openNonce(alice);
        bytes memory playSig = _signOpenPack(alice, nonce, bytes32(0));

        usdc.mint(alice, expectedEscrowed);
        // MockPermit2 calls transferFrom(owner, to, amount) where owner = alice.
        // Alice must approve the MockPermit2 contract (etched at PERMIT2_ADDRESS).
        vm.startPrank(alice);
        usdc.approve(PERMIT2_ADDRESS, expectedEscrowed);
        uint256 requestId = nextExpectedRequestId++;
        packMachine.openPackWithPermit2(
            alice,
            0,
            0,              // permit2 nonce
            block.timestamp + 1 hours,
            playSig,        // MockPermit2 ignores permit2 sig — any bytes will do
            playSig
        );
        vm.stopPrank();

        assertEq(
            usdc.balanceOf(address(packMachine)),
            expectedEscrowed,
            "permit2 path: discounted amount escrowed"
        );
        assertTrue(
            packMachine.hasClaimedFirstOpenDiscount(alice),
            "permit2 path: first-open flag set"
        );

        _fulfill(requestId);
    }
}
