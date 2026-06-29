// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PromoCodeRegistry} from "../PromoCodeRegistry.sol";
import {IPromoCodeRegistry} from "../interfaces/IPromoCodeRegistry.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {Roles} from "../lib/Roles.sol";
import {FakePackMachine} from "../test-helpers/FakePackMachine.sol";

// ─── Minimal mock so we can impersonate a registered PackMachine ──────────────

contract MockPackMachineFactoryForPromo {
    mapping(address => bool) public isPackMachineMap;

    function setPackMachine(address machine, bool registered) external {
        isPackMachineMap[machine] = registered;
    }

    function isPackMachine(address machine) external view returns (bool) {
        return isPackMachineMap[machine];
    }
}

// ─── Test contract ────────────────────────────────────────────────────────────

contract PromoCodeRegistryTest is Test {
    PromoCodeRegistry internal registry;
    PermissionManager internal pm;
    MockPackMachineFactoryForPromo internal factory;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");  // PACK_OPERATOR_ROLE
    address internal upgrader = makeAddr("upgrader");  // UPGRADER_ROLE
    address internal pauser = makeAddr("pauser");      // PAUSER_ROLE
    address internal unauthorized = makeAddr("unauthorized");
    address internal packMachine = makeAddr("packMachine");
    address internal buybackPool = makeAddr("buybackPool");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");

    bytes32 internal constant DISCOUNT_CODE = keccak256("SAVE20");
    bytes32 internal constant BUYBACK_CODE  = keccak256("BOOST95");

    uint16 internal constant DISCOUNT_BPS_20  = 2000;
    uint16 internal constant BUYBACK_BPS_95   = 9500;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        // Deploy PermissionManager
        PermissionManager pmImpl = new PermissionManager();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl),
            abi.encodeCall(PermissionManager.initialize, (admin))
        );
        pm = PermissionManager(address(pmProxy));

        // Grant roles
        vm.startPrank(admin);
        pm.grantRole(Roles.PACK_OPERATOR_ROLE, operator);
        pm.grantRole(Roles.UPGRADER_ROLE, upgrader);
        pm.grantRole(Roles.PAUSER_ROLE, pauser);
        vm.stopPrank();

        // Deploy mock factory
        factory = new MockPackMachineFactoryForPromo();
        factory.setPackMachine(packMachine, true);

        // Deploy PromoCodeRegistry
        PromoCodeRegistry regImpl = new PromoCodeRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(PromoCodeRegistry.initialize, (address(pm)))
        );
        registry = PromoCodeRegistry(address(regProxy));

        // Wire factory and pool
        vm.startPrank(admin);
        registry.setPackMachineFactory(address(factory));
        registry.setBuybackPool(buybackPool);
        vm.stopPrank();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createDiscountCode(bytes32 codeId, uint16 bps) internal {
        vm.prank(operator);
        registry.createCode(codeId, IPromoCodeRegistry.PromoKind.Discount, bps, 0, 0, false, false, address(0));
    }

    function _createBuybackCode(bytes32 codeId, uint16 bps) internal {
        vm.prank(operator);
        registry.createCode(codeId, IPromoCodeRegistry.PromoKind.Buyback, bps, 0, 0, false, false, address(0));
    }

    function _redeemDiscount(bytes32 codeId, address _user) internal returns (uint16) {
        vm.prank(packMachine);
        return registry.redeemDiscount(codeId, _user);
    }

    function _redeemBuyback(bytes32 codeId, address _user) internal returns (uint16) {
        vm.prank(buybackPool);
        return registry.redeemBuyback(codeId, _user);
    }

    // =========================================================================
    // createCode — valid bps
    // =========================================================================

    function test_createCode_discount_validBps() public {
        uint16[4] memory validBps = [uint16(1000), 1500, 2000, 2500];
        for (uint256 i; i < validBps.length; ++i) {
            bytes32 id = keccak256(abi.encodePacked("D", i));
            vm.prank(operator);
            registry.createCode(id, IPromoCodeRegistry.PromoKind.Discount, validBps[i], 0, 0, false, false, address(0));
            IPromoCodeRegistry.PromoCode memory c = registry.getCode(id);
            assertEq(c.bps, validBps[i]);
            assertTrue(c.active);
            assertTrue(c.exists);
        }
    }

    function test_createCode_buyback_validBps() public {
        uint16[3] memory validBps = [uint16(9000), 9500, 9800];
        for (uint256 i; i < validBps.length; ++i) {
            bytes32 id = keccak256(abi.encodePacked("B", i));
            vm.prank(operator);
            registry.createCode(id, IPromoCodeRegistry.PromoKind.Buyback, validBps[i], 0, 0, false, false, address(0));
            IPromoCodeRegistry.PromoCode memory c = registry.getCode(id);
            assertEq(c.bps, validBps[i]);
        }
    }

    // =========================================================================
    // createCode — invalid bps
    // =========================================================================

    function test_createCode_revertInvalidBps_discount_buybackValue() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__InvalidBps.selector,
                IPromoCodeRegistry.PromoKind.Discount,
                uint16(9000)
            )
        );
        registry.createCode(DISCOUNT_CODE, IPromoCodeRegistry.PromoKind.Discount, 9000, 0, 0, false, false, address(0));
    }

    function test_createCode_revertInvalidBps_buyback_discountValue() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__InvalidBps.selector,
                IPromoCodeRegistry.PromoKind.Buyback,
                uint16(2000)
            )
        );
        registry.createCode(BUYBACK_CODE, IPromoCodeRegistry.PromoKind.Buyback, 2000, 0, 0, false, false, address(0));
    }

    function test_createCode_revertInvalidBps_discount_arbitrary() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__InvalidBps.selector,
                IPromoCodeRegistry.PromoKind.Discount,
                uint16(500)
            )
        );
        registry.createCode(DISCOUNT_CODE, IPromoCodeRegistry.PromoKind.Discount, 500, 0, 0, false, false, address(0));
    }

    // =========================================================================
    // createCode — duplicate
    // =========================================================================

    function test_createCode_revertDuplicate() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__CodeExists.selector,
                DISCOUNT_CODE
            )
        );
        registry.createCode(DISCOUNT_CODE, IPromoCodeRegistry.PromoKind.Discount, 2000, 0, 0, false, false, address(0));
    }

    // =========================================================================
    // createCode — access control
    // =========================================================================

    function test_createCode_revertIfUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        registry.createCode(DISCOUNT_CODE, IPromoCodeRegistry.PromoKind.Discount, 2000, 0, 0, false, false, address(0));
    }

    // =========================================================================
    // redeemDiscount — happy path
    // =========================================================================

    function test_redeemDiscount_happyPath_returnsCorrectBps() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        uint16 bps = _redeemDiscount(DISCOUNT_CODE, user);
        assertEq(bps, DISCOUNT_BPS_20);
    }

    function test_redeemDiscount_incrementsRedeemedCount() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        _redeemDiscount(DISCOUNT_CODE, user);
        IPromoCodeRegistry.PromoCode memory c = registry.getCode(DISCOUNT_CODE);
        assertEq(c.redeemedCount, 1);
    }

    function test_redeemDiscount_emitsCodeRedeemed() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        vm.prank(packMachine);
        vm.expectEmit(true, true, false, true);
        emit IPromoCodeRegistry.CodeRedeemed(
            DISCOUNT_CODE, user, IPromoCodeRegistry.PromoKind.Discount, DISCOUNT_BPS_20, 1
        );
        registry.redeemDiscount(DISCOUNT_CODE, user);
    }

    // =========================================================================
    // redeemDiscount — unauthorized caller
    // =========================================================================

    function test_redeemDiscount_revertIfCallerNotPackMachine() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                unauthorized
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, user);
    }

    function test_redeemDiscount_revertIfBuybackPoolCalls() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        vm.prank(buybackPool);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                buybackPool
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, user);
    }

    // =========================================================================
    // redeemBuyback — happy path
    // =========================================================================

    function test_redeemBuyback_happyPath_returnsCorrectBps() public {
        _createBuybackCode(BUYBACK_CODE, BUYBACK_BPS_95);
        uint16 bps = _redeemBuyback(BUYBACK_CODE, user);
        assertEq(bps, BUYBACK_BPS_95);
    }

    function test_redeemBuyback_incrementsRedeemedCount() public {
        _createBuybackCode(BUYBACK_CODE, BUYBACK_BPS_95);
        _redeemBuyback(BUYBACK_CODE, user);
        assertEq(registry.getCode(BUYBACK_CODE).redeemedCount, 1);
    }

    // =========================================================================
    // redeemBuyback — unauthorized caller
    // =========================================================================

    function test_redeemBuyback_revertIfNotBuybackPool() public {
        _createBuybackCode(BUYBACK_CODE, BUYBACK_BPS_95);
        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                packMachine
            )
        );
        registry.redeemBuyback(BUYBACK_CODE, user);
    }

    // =========================================================================
    // redeemDiscount — wrong kind
    // =========================================================================

    function test_redeem_revertWrongKind_buybackViaDiscount() public {
        _createBuybackCode(BUYBACK_CODE, BUYBACK_BPS_95);
        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__WrongKind.selector,
                BUYBACK_CODE,
                IPromoCodeRegistry.PromoKind.Discount,
                IPromoCodeRegistry.PromoKind.Buyback
            )
        );
        registry.redeemDiscount(BUYBACK_CODE, user);
    }

    function test_redeem_revertWrongKind_discountViaBuyback() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        vm.prank(buybackPool);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__WrongKind.selector,
                DISCOUNT_CODE,
                IPromoCodeRegistry.PromoKind.Buyback,
                IPromoCodeRegistry.PromoKind.Discount
            )
        );
        registry.redeemBuyback(DISCOUNT_CODE, user);
    }

    // =========================================================================
    // redeemDiscount — inactive
    // =========================================================================

    function test_redeem_revertInactive() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        vm.prank(operator);
        registry.setActive(DISCOUNT_CODE, false);

        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__Inactive.selector,
                DISCOUNT_CODE
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, user);
    }

    // =========================================================================
    // redeemDiscount — expired
    // =========================================================================

    function test_redeem_revertExpired() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            uint64(block.timestamp + 100), // expires in 100 seconds
            0,
            false,
            false,
            address(0)
        );

        vm.warp(block.timestamp + 101);

        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__Expired.selector,
                DISCOUNT_CODE
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, user);
    }

    function test_redeem_happyPath_beforeExpiry() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            uint64(block.timestamp + 100),
            0,
            false,
            false,
            address(0)
        );
        vm.warp(block.timestamp + 99);
        uint16 bps = _redeemDiscount(DISCOUNT_CODE, user);
        assertEq(bps, DISCOUNT_BPS_20);
    }

    // =========================================================================
    // redeemDiscount — limit reached
    // =========================================================================

    function test_redeem_revertLimitReached() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            2,   // maxRedemptions = 2
            false,
            false,
            address(0)
        );

        _redeemDiscount(DISCOUNT_CODE, user);
        _redeemDiscount(DISCOUNT_CODE, user2);

        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__LimitReached.selector,
                DISCOUNT_CODE
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, makeAddr("user3"));
    }

    // =========================================================================
    // redeemDiscount — restricted allowlist
    // =========================================================================

    function test_redeem_restricted_revertNotAllowlisted() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            0,
            true,   // restricted
            false,
            address(0)
        );

        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__NotAllowlisted.selector,
                DISCOUNT_CODE,
                user
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, user);
    }

    function test_redeem_restricted_allowlistThenSucceeds() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            0,
            true,
            false,
            address(0)
        );

        address[] memory users = new address[](1);
        users[0] = user;
        vm.prank(operator);
        registry.addToAllowlist(DISCOUNT_CODE, users);

        uint16 bps = _redeemDiscount(DISCOUNT_CODE, user);
        assertEq(bps, DISCOUNT_BPS_20);
    }

    function test_redeem_restricted_removeFromAllowlist_reverts() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            0,
            true,
            false,
            address(0)
        );
        address[] memory users = new address[](1);
        users[0] = user;
        vm.startPrank(operator);
        registry.addToAllowlist(DISCOUNT_CODE, users);
        registry.removeFromAllowlist(DISCOUNT_CODE, users);
        vm.stopPrank();

        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__NotAllowlisted.selector,
                DISCOUNT_CODE,
                user
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, user);
    }

    // =========================================================================
    // oncePerUser
    // =========================================================================

    function test_oncePerUser_revertSecondRedeem() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            0,
            false,
            true,  // oncePerUser
            address(0)
        );

        _redeemDiscount(DISCOUNT_CODE, user);

        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__AlreadyRedeemed.selector,
                DISCOUNT_CODE,
                user
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, user);
    }

    function test_oncePerUser_differentUsersCanRedeem() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            0,
            false,
            true,
            address(0)
        );
        _redeemDiscount(DISCOUNT_CODE, user);
        _redeemDiscount(DISCOUNT_CODE, user2);  // should not revert
        assertTrue(registry.hasUserRedeemed(DISCOUNT_CODE, user));
        assertTrue(registry.hasUserRedeemed(DISCOUNT_CODE, user2));
    }

    // =========================================================================
    // Batch allowlist cap at 50
    // =========================================================================

    function test_addToAllowlist_revertBatchTooLarge() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        address[] memory users = new address[](51);
        for (uint256 i; i < 51; ++i) users[i] = makeAddr(string(abi.encodePacked("u", i)));

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__BatchTooLarge.selector,
                uint256(51),
                uint256(50)
            )
        );
        registry.addToAllowlist(DISCOUNT_CODE, users);
    }

    function test_addToAllowlist_maxBatch50_succeeds() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        address[] memory users = new address[](50);
        for (uint256 i; i < 50; ++i) users[i] = makeAddr(string(abi.encodePacked("u", i)));
        vm.prank(operator);
        registry.addToAllowlist(DISCOUNT_CODE, users);  // should not revert
        assertTrue(registry.isAllowlisted(DISCOUNT_CODE, users[0]));
    }

    // =========================================================================
    // pause — blocks redeems
    // =========================================================================

    function test_pause_blocksRedeemDiscount() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        vm.prank(pauser);
        registry.pause();

        vm.prank(packMachine);
        vm.expectRevert();
        registry.redeemDiscount(DISCOUNT_CODE, user);
    }

    function test_pause_blocksRedeemBuyback() public {
        _createBuybackCode(BUYBACK_CODE, BUYBACK_BPS_95);
        vm.prank(pauser);
        registry.pause();

        vm.prank(buybackPool);
        vm.expectRevert();
        registry.redeemBuyback(BUYBACK_CODE, user);
    }

    function test_unpause_allowsRedeem() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        vm.prank(pauser);
        registry.pause();
        vm.prank(pauser);
        registry.unpause();

        uint16 bps = _redeemDiscount(DISCOUNT_CODE, user);
        assertEq(bps, DISCOUNT_BPS_20);
    }

    // =========================================================================
    // remainingRedemptions view
    // =========================================================================

    function test_remainingRedemptions_uncapped_returnsMaxUint() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        assertEq(registry.remainingRedemptions(DISCOUNT_CODE), type(uint256).max);
    }

    function test_remainingRedemptions_capped_decrementsOnRedeem() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            3,
            false,
            false,
            address(0)
        );
        assertEq(registry.remainingRedemptions(DISCOUNT_CODE), 3);
        _redeemDiscount(DISCOUNT_CODE, user);
        assertEq(registry.remainingRedemptions(DISCOUNT_CODE), 2);
        _redeemDiscount(DISCOUNT_CODE, user2);
        assertEq(registry.remainingRedemptions(DISCOUNT_CODE), 1);
    }

    function test_remainingRedemptions_exhausted_returnsZero() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            1,
            false,
            false,
            address(0)
        );
        _redeemDiscount(DISCOUNT_CODE, user);
        assertEq(registry.remainingRedemptions(DISCOUNT_CODE), 0);
    }

    function testFuzz_remainingRedemptions(uint32 cap, uint32 redeems) public {
        cap = uint32(bound(cap, 1, 100));
        redeems = uint32(bound(redeems, 0, cap));

        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            cap,
            false,
            false,
            address(0)
        );
        for (uint32 i; i < redeems; ++i) {
            address u = makeAddr(string(abi.encodePacked("fuzz", i)));
            vm.prank(packMachine);
            registry.redeemDiscount(DISCOUNT_CODE, u);
        }
        assertEq(registry.remainingRedemptions(DISCOUNT_CODE), cap - redeems);
    }

    // =========================================================================
    // isEligible view
    // =========================================================================

    function test_isEligible_returnsTrue_forEligibleUser() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        assertTrue(registry.isEligible(DISCOUNT_CODE, user));
    }

    function test_isEligible_returnsFalse_inactive() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        vm.prank(operator);
        registry.setActive(DISCOUNT_CODE, false);
        assertFalse(registry.isEligible(DISCOUNT_CODE, user));
    }

    function test_isEligible_returnsFalse_expired() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            uint64(block.timestamp + 10),
            0,
            false,
            false,
            address(0)
        );
        vm.warp(block.timestamp + 11);
        assertFalse(registry.isEligible(DISCOUNT_CODE, user));
    }

    function test_isEligible_returnsFalse_notAllowlisted() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            0,
            true,
            false,
            address(0)
        );
        assertFalse(registry.isEligible(DISCOUNT_CODE, user));
    }

    // =========================================================================
    // previewDiscount view
    // =========================================================================

    function test_previewDiscount_returnsDiscountedPrice() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        uint256 price = 100e6; // 100 USDC
        uint256 expected = price - (price * 2000) / 10_000; // 80 USDC
        assertEq(registry.previewDiscount(DISCOUNT_CODE, user, price), expected);
    }

    function test_previewDiscount_zeroCodeId_returnsFullPrice() public view {
        uint256 price = 100e6;
        assertEq(registry.previewDiscount(bytes32(0), user, price), price);
    }

    function test_previewDiscount_buybackCode_returnsFullPrice() public {
        _createBuybackCode(BUYBACK_CODE, BUYBACK_BPS_95);
        uint256 price = 100e6;
        assertEq(registry.previewDiscount(BUYBACK_CODE, user, price), price);
    }

    function test_previewDiscount_expiredCode_returnsFullPrice() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            uint64(block.timestamp + 10),
            0,
            false,
            false,
            address(0)
        );
        vm.warp(block.timestamp + 11);
        uint256 price = 100e6;
        assertEq(registry.previewDiscount(DISCOUNT_CODE, user, price), price);
    }

    // =========================================================================
    // setActive / setExpiry / setMaxRedemptions — access control
    // =========================================================================

    function test_setActive_revertIfUnauthorized() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        vm.prank(unauthorized);
        vm.expectRevert();
        registry.setActive(DISCOUNT_CODE, false);
    }

    function test_setExpiry_revertIfCodeNotFound() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__CodeNotFound.selector,
                DISCOUNT_CODE
            )
        );
        registry.setExpiry(DISCOUNT_CODE, 12345);
    }

    function test_setMaxRedemptions_loweringBelowRedeemed_stopsNewRedemptions() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            10,
            false,
            false,
            address(0)
        );
        _redeemDiscount(DISCOUNT_CODE, user);

        // Lower cap below current redeemed count
        vm.prank(operator);
        registry.setMaxRedemptions(DISCOUNT_CODE, 1);

        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__LimitReached.selector,
                DISCOUNT_CODE
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, user2);
    }

    // =========================================================================
    // Wiring setters
    // =========================================================================

    function test_setPackMachineFactory_revertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IPromoCodeRegistry.PromoCodeRegistry__ZeroAddress.selector);
        registry.setPackMachineFactory(address(0));
    }

    function test_setBuybackPool_revertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IPromoCodeRegistry.PromoCodeRegistry__ZeroAddress.selector);
        registry.setBuybackPool(address(0));
    }

    function test_setPackMachineFactory_revertIfUnauthorized() public {
        vm.prank(operator);
        vm.expectRevert();
        registry.setPackMachineFactory(address(factory));
    }

    // =========================================================================
    // redeemDiscount — NotConfigured when factory is zero
    // =========================================================================

    function test_redeemDiscount_revertNotConfigured_factoryUnset() public {
        // Deploy a fresh registry with no factory set
        PromoCodeRegistry regImpl2 = new PromoCodeRegistry();
        ERC1967Proxy regProxy2 = new ERC1967Proxy(
            address(regImpl2),
            abi.encodeCall(PromoCodeRegistry.initialize, (address(pm)))
        );
        PromoCodeRegistry reg2 = PromoCodeRegistry(address(regProxy2));

        vm.prank(operator);
        reg2.createCode(DISCOUNT_CODE, IPromoCodeRegistry.PromoKind.Discount, DISCOUNT_BPS_20, 0, 0, false, false, address(0));

        vm.prank(packMachine);
        vm.expectRevert(IPromoCodeRegistry.PromoCodeRegistry__NotConfigured.selector);
        reg2.redeemDiscount(DISCOUNT_CODE, user);
    }

    // =========================================================================
    // Atomic rollback — increment reverts with the surrounding tx
    // =========================================================================

    function test_atomicRollback_redeemCountUnchangedOnRevert() public {
        vm.prank(operator);
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            1,
            false,
            false,
            address(0)
        );

        // Consume the single redemption
        _redeemDiscount(DISCOUNT_CODE, user);
        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, 1);

        // A second redeem should fail — count should stay at 1 (not 2)
        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__LimitReached.selector,
                DISCOUNT_CODE
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, user2);
        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, 1);
    }

    // =========================================================================
    // Events — createCode
    // =========================================================================

    function test_createCode_emitsCodeCreated() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true);
        emit IPromoCodeRegistry.CodeCreated(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS_20,
            0,
            0,
            false,
            false,
            address(0)
        );
        registry.createCode(DISCOUNT_CODE, IPromoCodeRegistry.PromoKind.Discount, DISCOUNT_BPS_20, 0, 0, false, false, address(0));
    }

    // =========================================================================
    // Security: theft resistance (unit layer — uses the mock factory)
    // =========================================================================

    /// @notice FakePackMachine is a contract (not an EOA) but is NOT registered in
    ///         the mock factory.  Proves that "being a contract" grants nothing —
    ///         only factory membership matters.
    function test_security_fakeContractCallerRejected() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        FakePackMachine fake = new FakePackMachine();

        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                address(fake)
            )
        );
        fake.attack(address(registry), DISCOUNT_CODE, user);
    }

    /// @notice Every failed (unauthorized) redeemDiscount attempt leaves redeemedCount at 0.
    ///         Tests EOA, unregistered contract, and wrong-address variants in sequence.
    function test_security_failedRedeemLeavesCountZero() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);

        // EOA attempt
        vm.prank(unauthorized);
        try registry.redeemDiscount(DISCOUNT_CODE, user) {} catch {}
        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, 0,
            "count non-zero after EOA attempt");

        // Unregistered contract attempt
        FakePackMachine fake = new FakePackMachine();
        try fake.attack(address(registry), DISCOUNT_CODE, user) {} catch {}
        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, 0,
            "count non-zero after fake-contract attempt");

        // BuybackPool attempting a discount redeem (unauthorized redeemer — it is not a pack machine)
        vm.prank(buybackPool);
        try registry.redeemDiscount(DISCOUNT_CODE, user) {} catch {}
        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, 0,
            "count non-zero after buybackPool-as-discount-redeemer attempt");
    }

    /// @notice Cross-spoke confusion: the registered buyback-pool address cannot call
    ///         redeemDiscount, and the registered pack-machine address cannot call
    ///         redeemBuyback.  Defense-in-depth on top of the kind check.
    function test_security_buybackPoolCannotRedeemDiscountAndViceVersa() public {
        _createDiscountCode(DISCOUNT_CODE, DISCOUNT_BPS_20);
        _createBuybackCode(BUYBACK_CODE, BUYBACK_BPS_95);

        // buybackPool is the sole authorized redeemBuyback caller, NOT a pack machine →
        // calling redeemDiscount must be rejected as UnauthorizedRedeemer.
        vm.prank(buybackPool);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                buybackPool
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, user);

        // packMachine IS an authorized redeemDiscount caller but NOT the buyback pool →
        // calling redeemBuyback must be rejected as UnauthorizedRedeemer.
        vm.prank(packMachine);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                packMachine
            )
        );
        registry.redeemBuyback(BUYBACK_CODE, user);

        // Both counts untouched.
        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, 0);
        assertEq(registry.getCode(BUYBACK_CODE).redeemedCount, 0);
    }
}
