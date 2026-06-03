// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FeeController} from "../FeeController.sol";
import {IFeeController} from "../interfaces/IFeeController.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {Roles} from "../lib/Roles.sol";

contract FeeControllerTest is Test {
    FeeController internal fc;
    PermissionManager internal pm;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal unauthorized = makeAddr("unauthorized");

    uint16 internal constant DEFAULT_BPS = 500;

    function setUp() public {
        // PermissionManager
        PermissionManager pmImpl = new PermissionManager();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl),
            abi.encodeCall(PermissionManager.initialize, (admin))
        );
        pm = PermissionManager(address(pmProxy));

        // FeeController
        FeeController fcImpl = new FeeController();
        ERC1967Proxy fcProxy = new ERC1967Proxy(
            address(fcImpl),
            abi.encodeCall(FeeController.initialize, (address(pm), treasury))
        );
        fc = FeeController(address(fcProxy));
    }

    // =========================================================================
    // Defaults
    // =========================================================================

    function test_defaults() public view {
        assertEq(fc.collectibleFeesBps(), DEFAULT_BPS);
        assertEq(fc.redemptionFeeBps(), DEFAULT_BPS);
        assertTrue(fc.collectibleFeesEnabled());
        assertTrue(fc.redemptionFeeEnabled());
        assertEq(fc.protocolFeeRecipient(), treasury);
    }

    function test_getCollectibleFee_defaultRate() public view {
        (uint256 fee, bool enabled) = fc.getCollectibleFee(1000e6);
        assertTrue(enabled);
        assertEq(fee, 50e6); // 5% of 1000
    }

    function test_getRedemptionFee_defaultRate() public view {
        (uint256 fee, bool enabled) = fc.getRedemptionFee(1000e6);
        assertTrue(enabled);
        assertEq(fee, 50e6);
    }

    function test_getRedemptionFee_zeroBase_returnsZero() public view {
        (uint256 fee, bool enabled) = fc.getRedemptionFee(0);
        assertTrue(enabled);
        assertEq(fee, 0); // free shipment when no appraisal
    }

    // =========================================================================
    // Setters — access control
    // =========================================================================

    function test_setCollectibleFeesBps_revertIfUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        fc.setCollectibleFeesBps(300);
    }

    function test_setRedemptionFeeBps_revertIfUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        fc.setRedemptionFeeBps(300);
    }

    // =========================================================================
    // Setters — bps caps
    // =========================================================================

    function test_setCollectibleFeesBps_revertIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeController.FeeController__FeeTooHigh.selector, 1001, 1000)
        );
        fc.setCollectibleFeesBps(1001);
    }

    function test_setRedemptionFeeBps_revertIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IFeeController.FeeController__FeeTooHigh.selector, 10001, 10000)
        );
        fc.setRedemptionFeeBps(10001);
    }

    function test_setCollectibleFeesBps_maxAllowed() public {
        vm.prank(admin);
        fc.setCollectibleFeesBps(1000);
        assertEq(fc.collectibleFeesBps(), 1000);
    }

    function test_setRedemptionFeeBps_maxAllowed() public {
        vm.prank(admin);
        fc.setRedemptionFeeBps(10000);
        assertEq(fc.redemptionFeeBps(), 10000);
    }

    // =========================================================================
    // Enable / disable independence
    // =========================================================================

    function test_disableCollectibleFee_doesNotAffectRedemption() public {
        vm.prank(admin);
        fc.setCollectibleFeesEnabled(false);

        (uint256 fee, bool enabled) = fc.getCollectibleFee(1000e6);
        assertFalse(enabled);
        assertEq(fee, 0);

        // Redemption unaffected
        (uint256 rFee, bool rEnabled) = fc.getRedemptionFee(1000e6);
        assertTrue(rEnabled);
        assertEq(rFee, 50e6);
        // Bps value preserved
        assertEq(fc.collectibleFeesBps(), DEFAULT_BPS);
    }

    function test_disableRedemptionFee_doesNotAffectCollectible() public {
        vm.prank(admin);
        fc.setRedemptionFeeEnabled(false);

        (uint256 fee, bool enabled) = fc.getRedemptionFee(1000e6);
        assertFalse(enabled);
        assertEq(fee, 0);

        // Collectible unaffected
        (uint256 cFee, bool cEnabled) = fc.getCollectibleFee(1000e6);
        assertTrue(cEnabled);
        assertEq(cFee, 50e6);
        // Bps value preserved
        assertEq(fc.redemptionFeeBps(), DEFAULT_BPS);
    }

    function test_reenableCollectibleFee_preservesBps() public {
        vm.startPrank(admin);
        fc.setCollectibleFeesEnabled(false);
        fc.setCollectibleFeesEnabled(true);
        vm.stopPrank();

        (uint256 fee, bool enabled) = fc.getCollectibleFee(1000e6);
        assertTrue(enabled);
        assertEq(fee, 50e6);
    }

    // =========================================================================
    // Events
    // =========================================================================

    function test_setCollectibleFeesBps_emitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit IFeeController.CollectibleFeesUpdated(DEFAULT_BPS, 300);
        fc.setCollectibleFeesBps(300);
    }

    function test_setProtocolFeeRecipient_zeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(IFeeController.FeeController__ZeroAddress.selector);
        fc.setProtocolFeeRecipient(address(0));
    }

    function test_setProtocolFeeRecipient_updates() public {
        address newTreasury = makeAddr("newTreasury");
        vm.prank(admin);
        fc.setProtocolFeeRecipient(newTreasury);
        assertEq(fc.protocolFeeRecipient(), newTreasury);
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_getCollectibleFee_math(uint256 amount) public view {
        amount = bound(amount, 0, 1e30);
        (uint256 fee, bool enabled) = fc.getCollectibleFee(amount);
        assertTrue(enabled);
        assertEq(fee, (amount * DEFAULT_BPS) / 10_000);
    }
}
