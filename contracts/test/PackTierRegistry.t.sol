// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackTierRegistry} from "../PackTierRegistry.sol";
import {PackMachineFactory} from "../PackMachineFactory.sol";
import {PackMachine} from "../PackMachine.sol";
import {PackRegistry} from "../PackRegistry.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";
import {MockPermit2} from "../test-helpers/MockPermit2.sol";

contract PackTierRegistryTest is Test {
    PackTierRegistry internal tierRegistry;
    PackMachineFactory internal factory;
    PackRegistry internal packRegistry;
    PermissionManager internal pm;
    PackMachine internal packMachine;

    address internal admin = makeAddr("admin");
    address internal upgrader = makeAddr("upgrader");
    address internal forwarder = makeAddr("forwarder");
    address internal financeWallet = makeAddr("financeWallet");
    address internal unauthorized = makeAddr("unauthorized");

    uint256 internal operatorPk;
    address internal operator;

    address internal constant PERMIT2_ADDRESS =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {
        (operator, operatorPk) = makeAddrAndKey("operator");

        PermissionManager pmImpl = new PermissionManager();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl),
            abi.encodeCall(PermissionManager.initialize, (admin))
        );
        pm = PermissionManager(address(pmProxy));

        vm.startPrank(admin);
        pm.grantRole(pm.PACK_OPERATOR_ROLE(), operator);
        pm.grantRole(pm.UPGRADER_ROLE(), upgrader);
        pm.grantRole(pm.MINTER_ROLE(), operator);
        vm.stopPrank();

        MockERC20 usdc = new MockERC20();
        MockVRFCoordinatorV2Plus coordinator = new MockVRFCoordinatorV2Plus();

        AssetNFT assetNFTImpl = new AssetNFT(forwarder);
        ERC1967Proxy assetNFTProxy = new ERC1967Proxy(
            address(assetNFTImpl),
            abi.encodeCall(
                AssetNFT.initialize,
                (address(pm), "NW", "NWA", "ipfs://c", makeAddr("royalty"), 250)
            )
        );
        AssetNFT assetNFT = AssetNFT(address(assetNFTProxy));

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
                    500_000,
                    3
                )
            )
        );

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
        factory.setPackVRFRouter(address(routerProxy));
        vm.stopPrank();

        PackRegistry registryImpl = new PackRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(PackRegistry.initialize, (address(pm)))
        );
        packRegistry = PackRegistry(address(registryProxy));

        PackTierRegistry tierRegistryImpl = new PackTierRegistry();
        ERC1967Proxy tierRegistryProxy = new ERC1967Proxy(
            address(tierRegistryImpl),
            abi.encodeCall(PackTierRegistry.initialize, (address(pm)))
        );
        tierRegistry = PackTierRegistry(address(tierRegistryProxy));

        vm.startPrank(admin);
        factory.setPackRegistry(address(packRegistry));
        packRegistry.setFactory(address(factory));
        factory.setPackTierRegistry(address(tierRegistry));
        tierRegistry.setFactory(address(factory));
        vm.stopPrank();

        vm.prank(operator);
        address cloneAddr = factory.createPackMachine(
            10e6,
            1,
            uint40(block.timestamp)
        );
        packMachine = PackMachine(cloneAddr);

        vm.prank(admin);
        PackVRFRouter(address(routerProxy)).setAuthorizedPackMachine(
            cloneAddr,
            true
        );
    }

    // =========================================================================
    // Tests
    // =========================================================================

    function test_SetTier_GetTier_RoundTrip() public {
        vm.prank(address(packMachine));
        tierRegistry.setTier(1, 0, 3);
        assertEq(tierRegistry.getTier(address(packMachine), 1, 0), 3);
    }

    function test_SetTier_Unauthorized_Reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackTierRegistry.PackTierRegistry__Unauthorized.selector,
                unauthorized
            )
        );
        tierRegistry.setTier(1, 0, 3);
    }

    function test_DeleteTier_ClearsValue() public {
        vm.startPrank(address(packMachine));
        tierRegistry.setTier(1, 0, 3);
        assertEq(tierRegistry.getTier(address(packMachine), 1, 0), 3);
        tierRegistry.deleteTier(1, 0);
        assertEq(tierRegistry.getTier(address(packMachine), 1, 0), 0);
        vm.stopPrank();
    }

    function test_DeleteAllTiers_BatchClear() public {
        vm.startPrank(address(packMachine));
        tierRegistry.setTier(5, 0, 1);
        tierRegistry.setTier(5, 1, 2);
        tierRegistry.setTier(5, 2, 3);

        uint256[] memory packs = new uint256[](3);
        packs[0] = 0;
        packs[1] = 1;
        packs[2] = 2;
        tierRegistry.deleteAllTiers(5, packs);

        assertEq(tierRegistry.getTier(address(packMachine), 5, 0), 0);
        assertEq(tierRegistry.getTier(address(packMachine), 5, 1), 0);
        assertEq(tierRegistry.getTier(address(packMachine), 5, 2), 0);
        vm.stopPrank();
    }

    function test_GetTier_Unset_ReturnsZero() public view {
        assertEq(tierRegistry.getTier(address(packMachine), 999, 0), 0);
    }

    function test_MachinesAreSeparate() public {
        address machine2 = makeAddr("machine2");
        // Only real pack machines can write — machine2 is not registered.
        // Verify that different machine addresses get independent storage.
        vm.prank(address(packMachine));
        tierRegistry.setTier(1, 0, 5);
        // machine2's slot should be independent (still 0).
        assertEq(tierRegistry.getTier(machine2, 1, 0), 0);
        assertEq(tierRegistry.getTier(address(packMachine), 1, 0), 5);
    }

    function test_SetFactory_AdminOnly() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        tierRegistry.setFactory(makeAddr("newFactory"));
    }

    function test_DeleteTier_Unauthorized_Reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackTierRegistry.PackTierRegistry__Unauthorized.selector,
                unauthorized
            )
        );
        tierRegistry.deleteTier(1, 0);
    }

    function test_DeleteAllTiers_Unauthorized_Reverts() public {
        uint256[] memory packs = new uint256[](1);
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackTierRegistry.PackTierRegistry__Unauthorized.selector,
                unauthorized
            )
        );
        tierRegistry.deleteAllTiers(1, packs);
    }
}
