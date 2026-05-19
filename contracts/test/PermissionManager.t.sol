// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {Roles} from "../lib/Roles.sol";

contract PermissionManagerTest is Test {
    PermissionManager internal pm;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        PermissionManager impl = new PermissionManager();
        bytes memory data = abi.encodeCall(
            PermissionManager.initialize,
            (admin)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        pm = PermissionManager(address(proxy));
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    function test_Initialize_AdminHasAllRoles() public view {
        assertTrue(pm.hasProtocolRole(pm.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(pm.hasProtocolRole(pm.MINTER_ROLE(), admin));
        assertTrue(pm.hasProtocolRole(pm.BURNER_ROLE(), admin));
        assertTrue(pm.hasProtocolRole(pm.STATE_MANAGER_ROLE(), admin));
        assertTrue(pm.hasProtocolRole(pm.URI_SETTER_ROLE(), admin));
        assertTrue(pm.hasProtocolRole(pm.PAUSER_ROLE(), admin));
        assertTrue(pm.hasProtocolRole(pm.UPGRADER_ROLE(), admin));
        assertTrue(pm.hasProtocolRole(pm.BLACKLIST_ROLE(), admin));
    }

    function test_Initialize_RevertsOnZeroAdmin() public {
        PermissionManager impl = new PermissionManager();
        bytes memory data = abi.encodeCall(
            PermissionManager.initialize,
            (address(0))
        );
        vm.expectRevert(
            PermissionManager.PermissionManager__ZeroAddress.selector
        );
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_CannotInitializeTwice() public {
        vm.expectRevert();
        pm.initialize(admin);
    }

    function test_Initialize_RoleConstantsMatchLibrary() public view {
        assertEq(pm.MINTER_ROLE(), Roles.MINTER_ROLE);
        assertEq(pm.BURNER_ROLE(), Roles.BURNER_ROLE);
        assertEq(pm.STATE_MANAGER_ROLE(), Roles.STATE_MANAGER_ROLE);
        assertEq(pm.URI_SETTER_ROLE(), Roles.URI_SETTER_ROLE);
        assertEq(pm.PAUSER_ROLE(), Roles.PAUSER_ROLE);
        assertEq(pm.UPGRADER_ROLE(), Roles.UPGRADER_ROLE);
        assertEq(pm.BLACKLIST_ROLE(), Roles.BLACKLIST_ROLE);
    }

    // =========================================================================
    // hasProtocolRole
    // =========================================================================

    function test_HasProtocolRole_ReturnsTrueForHolder() public view {
        assertTrue(pm.hasProtocolRole(pm.MINTER_ROLE(), admin));
    }

    function test_HasProtocolRole_ReturnsFalseForNonHolder() public view {
        assertFalse(pm.hasProtocolRole(pm.MINTER_ROLE(), alice));
    }

    function test_HasProtocolRole_TrueAfterGrant() public {
        bytes32 role = pm.MINTER_ROLE();
        vm.prank(admin);
        pm.grantRole(role, alice);
        assertTrue(pm.hasProtocolRole(role, alice));
    }

    function test_HasProtocolRole_FalseAfterRevoke() public {
        bytes32 role = pm.MINTER_ROLE();
        vm.startPrank(admin);
        pm.grantRole(role, alice);
        pm.revokeRole(role, alice);
        vm.stopPrank();
        assertFalse(pm.hasProtocolRole(role, alice));
    }

    // =========================================================================
    // Role grant / revoke
    // =========================================================================

    function test_GrantRole_Success() public {
        bytes32 role = pm.MINTER_ROLE();
        vm.prank(admin);
        pm.grantRole(role, alice);
        assertTrue(pm.hasRole(role, alice));
    }

    function test_GrantRole_RevertsWhenUnauthorized() public {
        bytes32 role = pm.MINTER_ROLE();
        vm.prank(alice);
        vm.expectRevert();
        pm.grantRole(role, bob);
    }

    function test_RevokeRole_Success() public {
        bytes32 role = pm.MINTER_ROLE();
        vm.startPrank(admin);
        pm.grantRole(role, alice);
        pm.revokeRole(role, alice);
        vm.stopPrank();
        assertFalse(pm.hasRole(role, alice));
    }

    function test_RenounceRole_Success() public {
        bytes32 role = pm.MINTER_ROLE();
        vm.prank(admin);
        pm.grantRole(role, alice);
        vm.prank(alice);
        pm.renounceRole(role, alice);
        assertFalse(pm.hasRole(role, alice));
    }

    // =========================================================================
    // Role enumeration (AccessControlEnumerable)
    // =========================================================================

    function test_GetRoleMemberCount_ReturnsCorrectCount() public view {
        assertEq(pm.getRoleMemberCount(pm.MINTER_ROLE()), 1); // admin granted in init
    }

    function test_GetRoleMemberCount_IncreasesOnGrant() public {
        bytes32 role = pm.MINTER_ROLE();
        vm.prank(admin);
        pm.grantRole(role, alice);
        assertEq(pm.getRoleMemberCount(role), 2);
    }

    function test_GetRoleMemberCount_DecreasesOnRevoke() public {
        bytes32 role = pm.MINTER_ROLE();
        vm.startPrank(admin);
        pm.grantRole(role, alice);
        pm.revokeRole(role, alice);
        vm.stopPrank();
        assertEq(pm.getRoleMemberCount(role), 1);
    }

    function test_GetRoleMember_ReturnsCorrectAddress() public view {
        assertEq(pm.getRoleMember(pm.MINTER_ROLE(), 0), admin);
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    function test_Upgrade_AdminCanUpgrade() public {
        PermissionManager newImpl = new PermissionManager();
        vm.prank(admin);
        pm.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_RevertsWhenUnauthorized() public {
        PermissionManager newImpl = new PermissionManager();
        vm.prank(alice);
        vm.expectRevert();
        pm.upgradeToAndCall(address(newImpl), "");
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_HasProtocolRole_OnlyGrantedHolderReturnsTrue(
        address account
    ) public {
        vm.assume(account != admin && account != address(0));
        bytes32 role = pm.MINTER_ROLE();
        assertFalse(pm.hasProtocolRole(role, account));
        vm.prank(admin);
        pm.grantRole(role, account);
        assertTrue(pm.hasProtocolRole(role, account));
    }
}
