// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackMachine} from "../PackMachine.sol";
import {PackMachineFactory} from "../PackMachineFactory.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PackRegistry} from "../PackRegistry.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {PermissionConsumer} from "../PermissionConsumer.sol";
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {MockERC721} from "../test-helpers/MockERC721.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";

contract PackMachineFactoryTest is Test {
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
    PackRegistry internal packRegistry;
    PermissionManager internal pm;
    MockERC20 internal usdc;
    MockERC721 internal assetNFT;
    MockVRFCoordinatorV2Plus internal coordinator;
    PackMachine internal packMachineImpl;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal upgrader = makeAddr("upgrader");
    address internal financeWallet = makeAddr("financeWallet");
    address internal forwarder = makeAddr("forwarder");
    address internal unauthorized = makeAddr("unauthorized");

    bytes32 internal constant KEY_HASH = keccak256("key-hash");

    function setUp() public {
        // PermissionManager
        PermissionManager pmImpl = new PermissionManager();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl),
            abi.encodeCall(PermissionManager.initialize, (admin))
        );
        pm = PermissionManager(address(pmProxy));

        vm.startPrank(admin);
        pm.grantRole(pm.PACK_OPERATOR_ROLE(), operator);
        pm.grantRole(pm.UPGRADER_ROLE(), upgrader);
        vm.stopPrank();

        // Mocks
        usdc = new MockERC20();
        assetNFT = new MockERC721();
        coordinator = new MockVRFCoordinatorV2Plus();

        // PackVRFRouter proxy
        PackVRFRouter routerImpl = new PackVRFRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                PackVRFRouter.initialize,
                (address(pm), address(coordinator), 1, KEY_HASH, 500_000, 3)
            )
        );
        vrfRouter = PackVRFRouter(address(routerProxy));

        // PackMachine implementation
        packMachineImpl = new PackMachine(forwarder);

        // PackMachineFactory proxy
        PackMachineFactory factoryImpl = new PackMachineFactory(forwarder);
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                PackMachineFactory.initialize,
                (address(pm), address(assetNFT), address(usdc), financeWallet)
            )
        );
        factory = PackMachineFactory(address(factoryProxy));

        // Wire up factory
        vm.startPrank(admin);
        factory.setImplementation(address(packMachineImpl));
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
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    function test_Initialize_AssetNFTStored() public view {
        assertEq(factory.assetNFT(), address(assetNFT));
    }

    function test_Initialize_PaymentTokenStored() public view {
        assertEq(factory.paymentToken(), address(usdc));
    }

    function test_Initialize_FinanceWalletStored() public view {
        assertEq(factory.financeWallet(), financeWallet);
    }

    function test_Initialize_RevertsOnZeroAssetNFT() public {
        PackMachineFactory impl = new PackMachineFactory(forwarder);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__ZeroAddress.selector
        );
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                PackMachineFactory.initialize,
                (address(pm), address(0), address(usdc), financeWallet)
            )
        );
    }

    function test_Initialize_RevertsOnZeroPaymentToken() public {
        PackMachineFactory impl = new PackMachineFactory(forwarder);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__ZeroAddress.selector
        );
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                PackMachineFactory.initialize,
                (address(pm), address(assetNFT), address(0), financeWallet)
            )
        );
    }

    function test_Initialize_RevertsOnZeroFinanceWallet() public {
        PackMachineFactory impl = new PackMachineFactory(forwarder);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__ZeroAddress.selector
        );
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                PackMachineFactory.initialize,
                (address(pm), address(assetNFT), address(usdc), address(0))
            )
        );
    }

    // =========================================================================
    // createPackMachine
    // =========================================================================

    function test_CreatePackMachine_OperatorSucceeds() public {
        vm.prank(operator);
        address machine = factory.createPackMachine(
            10e6,
            5,
            uint40(block.timestamp)
        );
        assertNotEq(machine, address(0));
    }

    function test_CreatePackMachine_ReturnsValidClone() public {
        vm.prank(operator);
        address machine = factory.createPackMachine(
            10e6,
            5,
            uint40(block.timestamp)
        );
        assertTrue(factory.isPackMachine(machine));
    }

    function test_CreatePackMachine_RegistersInMapping() public {
        vm.prank(operator);
        address machine = factory.createPackMachine(
            10e6,
            5,
            uint40(block.timestamp)
        );
        assertTrue(factory.isPackMachine(machine));

        address[] memory all = factory.getAllPackMachines();
        assertEq(all.length, 1);
        assertEq(all[0], machine);
    }

    function test_CreatePackMachine_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(factory));
        emit PackMachineCreated(address(0), 10e6, 5); // address not known yet
        vm.prank(operator);
        factory.createPackMachine(10e6, 5, uint40(block.timestamp));
    }

    function test_CreatePackMachine_CloneInitializedCorrectly() public {
        uint128 price = 7e6;
        uint8 cards = 3;
        uint40 start = uint40(block.timestamp + 100);

        vm.prank(operator);
        address machine = factory.createPackMachine(price, cards, start);

        PackMachine pm_ = PackMachine(machine);
        assertEq(pm_.getPackPrice(0), price);
        assertEq(pm_.getPackCardsPerPack(0), cards);
        assertEq(pm_.factory(), address(factory));
    }

    function test_CreatePackMachine_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        factory.createPackMachine(10e6, 5, uint40(block.timestamp));
    }

    function test_CreatePackMachine_RevertsIfImplementationNotSet() public {
        // Deploy fresh factory without setImplementation
        PackMachineFactory impl = new PackMachineFactory(forwarder);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                PackMachineFactory.initialize,
                (address(pm), address(assetNFT), address(usdc), financeWallet)
            )
        );
        PackMachineFactory freshFactory = PackMachineFactory(address(proxy));
        vm.prank(admin);
        freshFactory.setPackVRFRouter(address(vrfRouter));

        vm.prank(operator);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__ImplementationNotSet.selector
        );
        freshFactory.createPackMachine(10e6, 5, uint40(block.timestamp));
    }

    function test_CreatePackMachine_RevertsIfVRFRouterNotSet() public {
        PackMachineFactory impl = new PackMachineFactory(forwarder);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                PackMachineFactory.initialize,
                (address(pm), address(assetNFT), address(usdc), financeWallet)
            )
        );
        PackMachineFactory freshFactory = PackMachineFactory(address(proxy));
        vm.prank(admin);
        freshFactory.setImplementation(address(packMachineImpl));

        vm.prank(operator);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__VRFRouterNotSet.selector
        );
        freshFactory.createPackMachine(10e6, 5, uint40(block.timestamp));
    }

    function test_CreatePackMachine_RevertsIfPackRegistryNotSet() public {
        PackMachineFactory impl = new PackMachineFactory(forwarder);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                PackMachineFactory.initialize,
                (address(pm), address(assetNFT), address(usdc), financeWallet)
            )
        );
        PackMachineFactory freshFactory = PackMachineFactory(address(proxy));
        vm.startPrank(admin);
        freshFactory.setImplementation(address(packMachineImpl));
        freshFactory.setPackVRFRouter(address(vrfRouter));
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__PackRegistryNotSet.selector
        );
        freshFactory.createPackMachine(10e6, 5, uint40(block.timestamp));
    }

    function test_RegisterMachine_OnlyFactoryCanCall() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackRegistry.PackRegistry__OnlyFactory.selector,
                operator
            )
        );
        packRegistry.registerMachine(makeAddr("machine"), 10e6, 3, 0);
    }

    function test_CreatePackMachine_MultipleCreationsTracked() public {
        vm.startPrank(operator);
        factory.createPackMachine(10e6, 5, uint40(block.timestamp));
        factory.createPackMachine(20e6, 3, uint40(block.timestamp));
        factory.createPackMachine(5e6, 1, uint40(block.timestamp));
        vm.stopPrank();

        assertEq(factory.getAllPackMachines().length, 3);
    }

    // =========================================================================
    // Transfer validator relay
    // =========================================================================

    function test_BeforeTransfer_OnlyPackMachineCanCall() public {
        vm.prank(operator);
        address machine = factory.createPackMachine(
            10e6,
            5,
            uint40(block.timestamp)
        );

        // Calling from the registered clone should not revert (no validator set → staticcall silently fails)
        vm.prank(machine);
        factory.beforeTransfer(address(assetNFT));
    }

    function test_BeforeTransfer_UnregisteredReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachineFactory.PackMachineFactory__OnlyPackMachine.selector,
                unauthorized
            )
        );
        factory.beforeTransfer(address(assetNFT));
    }

    function test_AfterTransfer_OnlyPackMachineCanCall() public {
        vm.prank(operator);
        address machine = factory.createPackMachine(
            10e6,
            5,
            uint40(block.timestamp)
        );

        vm.prank(machine);
        factory.afterTransfer(address(assetNFT));
    }

    // =========================================================================
    // Admin setters
    // =========================================================================

    function test_SetImplementation_AdminSucceeds() public {
        PackMachine newImpl = new PackMachine(forwarder);
        vm.prank(admin);
        factory.setImplementation(address(newImpl));
    }

    function test_SetImplementation_EmitsEvent() public {
        PackMachine newImpl = new PackMachine(forwarder);
        vm.expectEmit(true, true, false, false, address(factory));
        emit ImplementationUpdated(address(packMachineImpl), address(newImpl));
        vm.prank(admin);
        factory.setImplementation(address(newImpl));
    }

    function test_SetImplementation_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        factory.setImplementation(address(packMachineImpl));
    }

    function test_SetImplementation_ZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__ZeroAddress.selector
        );
        factory.setImplementation(address(0));
    }

    function test_SetPackVRFRouter_AdminSucceeds() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(admin);
        factory.setPackVRFRouter(newRouter);
        assertEq(factory.packVRFRouter(), newRouter);
    }

    function test_SetPackVRFRouter_EmitsEvent() public {
        address newRouter = makeAddr("newRouter");
        vm.expectEmit(true, true, false, false, address(factory));
        emit VRFRouterUpdated(address(vrfRouter), newRouter);
        vm.prank(admin);
        factory.setPackVRFRouter(newRouter);
    }

    function test_SetPackVRFRouter_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        factory.setPackVRFRouter(makeAddr("x"));
    }

    function test_SetPackVRFRouter_ZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__ZeroAddress.selector
        );
        factory.setPackVRFRouter(address(0));
    }

    function test_SetFinanceWallet_AdminSucceeds() public {
        address newWallet = makeAddr("newWallet");
        vm.prank(admin);
        factory.setFinanceWallet(newWallet);
        assertEq(factory.financeWallet(), newWallet);
    }

    function test_SetFinanceWallet_EmitsEvent() public {
        address newWallet = makeAddr("newWallet");
        vm.expectEmit(true, true, false, false, address(factory));
        emit FinanceWalletUpdated(financeWallet, newWallet);
        vm.prank(admin);
        factory.setFinanceWallet(newWallet);
    }

    function test_SetFinanceWallet_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        factory.setFinanceWallet(makeAddr("x"));
    }

    function test_SetFinanceWallet_ZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__ZeroAddress.selector
        );
        factory.setFinanceWallet(address(0));
    }

    function test_SetAssetNFT_AdminSucceeds() public {
        address newNFT = makeAddr("newNFT");
        vm.prank(admin);
        factory.setAssetNFT(newNFT);
        assertEq(factory.assetNFT(), newNFT);
    }

    function test_SetAssetNFT_ZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__ZeroAddress.selector
        );
        factory.setAssetNFT(address(0));
    }

    function test_SetPaymentToken_AdminSucceeds() public {
        address newToken = makeAddr("newToken");
        vm.prank(admin);
        factory.setPaymentToken(newToken);
        assertEq(factory.paymentToken(), newToken);
    }

    function test_SetPaymentToken_ZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(
            PackMachineFactory.PackMachineFactory__ZeroAddress.selector
        );
        factory.setPaymentToken(address(0));
    }

    function test_SetTrustedForwarder_AdminSucceeds() public {
        address newFwd = makeAddr("newFwd");
        vm.prank(admin);
        factory.setTrustedForwarder(newFwd, true);
        assertTrue(factory.isTrustedForwarder(newFwd));
    }

    function test_SetTrustedForwarder_EmitsEvent() public {
        address newFwd = makeAddr("newFwd");
        vm.expectEmit(true, false, false, true, address(factory));
        emit TrustedForwarderUpdated(newFwd, true);
        vm.prank(admin);
        factory.setTrustedForwarder(newFwd, true);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function test_GetAllPackMachines_ReturnsAll() public {
        assertEq(factory.getAllPackMachines().length, 0);
        vm.prank(operator);
        factory.createPackMachine(10e6, 5, uint40(block.timestamp));
        assertEq(factory.getAllPackMachines().length, 1);
    }

    function test_IsTrustedForwarder_CustomMappingWorks() public {
        address fwd = makeAddr("fwd");
        assertFalse(factory.isTrustedForwarder(fwd));
        vm.prank(admin);
        factory.setTrustedForwarder(fwd, true);
        assertTrue(factory.isTrustedForwarder(fwd));
    }

    function test_IsTrustedForwarder_UnknownReturnsFalse() public {
        assertFalse(factory.isTrustedForwarder(makeAddr("random")));
    }

    // =========================================================================
    // UUPS upgrade
    // =========================================================================

    function test_Upgrade_UpgraderSucceeds() public {
        PackMachineFactory newImpl = new PackMachineFactory(forwarder);
        vm.prank(upgrader);
        factory.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_UnauthorizedReverts() public {
        PackMachineFactory newImpl = new PackMachineFactory(forwarder);
        vm.prank(unauthorized);
        vm.expectRevert();
        factory.upgradeToAndCall(address(newImpl), "");
    }

    // =========================================================================
    // Event declarations
    // =========================================================================

    event PackMachineCreated(
        address indexed packMachine,
        uint128 pricePerPack,
        uint8 cardsPerPack
    );
    event ImplementationUpdated(
        address indexed oldImpl,
        address indexed newImpl
    );
    event FinanceWalletUpdated(
        address indexed oldWallet,
        address indexed newWallet
    );
    event VRFRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );
    event TrustedForwarderUpdated(address indexed forwarder, bool trusted);
}
