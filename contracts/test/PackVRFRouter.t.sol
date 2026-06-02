// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {PermissionConsumer} from "../PermissionConsumer.sol";
import {Roles} from "../lib/Roles.sol";
import {IPackMachine} from "../interfaces/IPackMachine.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";

/// @dev Minimal PackMachine stub that records the last fulfillRandomness call.
contract MockPackMachine {
    uint256 public lastRequestId;
    uint256[] public lastRandomWords;
    bool public fulfilled;

    function fulfillRandomness(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external {
        lastRequestId = requestId;
        lastRandomWords = randomWords;
        fulfilled = true;
    }

    // IPackMachine stubs
    function initialize(address, address, uint128, uint8, uint40) external {}
    function pricePerPack() external pure returns (uint128) {
        return 0;
    }
    function cardsPerPack() external pure returns (uint8) {
        return 0;
    }
    function effectivePrizePoolSize() external pure returns (uint256) {
        return 0;
    }
    function getPrizePool() external pure returns (uint256[] memory) {
        return new uint256[](0);
    }
}

contract PackVRFRouterTest is Test {
    PackVRFRouter internal router;
    PermissionManager internal pm;
    MockVRFCoordinatorV2Plus internal coordinator;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal upgrader = makeAddr("upgrader");
    address internal unauthorized = makeAddr("unauthorized");

    uint256 internal constant SUB_ID = 42;
    bytes32 internal constant KEY_HASH = keccak256("key-hash");
    uint32 internal constant CALLBACK_GAS = 500_000;
    uint16 internal constant CONFIRMATIONS = 3;

    function setUp() public {
        // Deploy PermissionManager
        PermissionManager pmImpl = new PermissionManager();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl),
            abi.encodeCall(PermissionManager.initialize, (admin))
        );
        pm = PermissionManager(address(pmProxy));

        bytes32 packOpRole = pm.PACK_OPERATOR_ROLE();
        bytes32 upgraderRole = pm.UPGRADER_ROLE();
        vm.startPrank(admin);
        pm.grantRole(packOpRole, operator);
        pm.grantRole(upgraderRole, upgrader);
        vm.stopPrank();

        // Deploy mock VRF coordinator
        coordinator = new MockVRFCoordinatorV2Plus();

        // Deploy PackVRFRouter proxy
        PackVRFRouter routerImpl = new PackVRFRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                PackVRFRouter.initialize,
                (
                    address(pm),
                    address(coordinator),
                    SUB_ID,
                    KEY_HASH,
                    CALLBACK_GAS,
                    CONFIRMATIONS
                )
            )
        );
        router = PackVRFRouter(address(routerProxy));
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    function test_Initialize_VRFCoordinatorStored() public view {
        assertEq(router.vrfCoordinator(), address(coordinator));
    }

    function test_Initialize_SubscriptionIdStored() public view {
        assertEq(router.subscriptionId(), SUB_ID);
    }

    function test_Initialize_RevertsOnZeroVRFCoordinator() public {
        PackVRFRouter impl = new PackVRFRouter();
        vm.expectRevert(PackVRFRouter.PackVRFRouter__ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                PackVRFRouter.initialize,
                (
                    address(pm),
                    address(0),
                    SUB_ID,
                    KEY_HASH,
                    CALLBACK_GAS,
                    CONFIRMATIONS
                )
            )
        );
    }

    // =========================================================================
    // setAuthorizedPackMachine
    // =========================================================================

    function test_SetAuthorizedPackMachine_OperatorSucceeds() public {
        address machine = makeAddr("machine");
        vm.prank(operator);
        router.setAuthorizedPackMachine(machine, true);
        assertTrue(router.isAuthorizedPackMachine(machine));
    }

    function test_SetAuthorizedPackMachine_EmitsEvent() public {
        address machine = makeAddr("machine");
        vm.expectEmit(true, false, false, true, address(router));
        emit PackMachineAuthorized(machine, true);
        vm.prank(operator);
        router.setAuthorizedPackMachine(machine, true);
    }

    function test_SetAuthorizedPackMachine_Deauthorize() public {
        address machine = makeAddr("machine");
        vm.startPrank(operator);
        router.setAuthorizedPackMachine(machine, true);
        router.setAuthorizedPackMachine(machine, false);
        vm.stopPrank();
        assertFalse(router.isAuthorizedPackMachine(machine));
    }

    function test_SetAuthorizedPackMachine_UnauthorizedReverts() public {
        address machine = makeAddr("machine");
        vm.prank(unauthorized);
        vm.expectRevert();
        router.setAuthorizedPackMachine(machine, true);
    }

    function test_SetAuthorizedPackMachine_ZeroAddressReverts() public {
        vm.prank(operator);
        vm.expectRevert(PackVRFRouter.PackVRFRouter__ZeroAddress.selector);
        router.setAuthorizedPackMachine(address(0), true);
    }

    // =========================================================================
    // requestRandomWords
    // =========================================================================

    function test_RequestRandomWords_AuthorizedMachineSucceeds() public {
        address machine = makeAddr("machine");
        vm.prank(operator);
        router.setAuthorizedPackMachine(machine, true);

        vm.prank(machine);
        uint256 requestId = router.requestRandomWords(makeAddr("user"), 3);
        assertGt(requestId, 0);
    }

    function test_RequestRandomWords_EmitsEvent() public {
        address machine = makeAddr("machine");
        address user = makeAddr("user");
        vm.prank(operator);
        router.setAuthorizedPackMachine(machine, true);

        vm.expectEmit(false, true, false, true, address(router));
        emit RandomnessRequested(1, machine, user);
        vm.prank(machine);
        router.requestRandomWords(user, 3);
    }

    function test_RequestRandomWords_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackVRFRouter.PackVRFRouter__UnauthorizedPackMachine.selector,
                unauthorized
            )
        );
        router.requestRandomWords(makeAddr("user"), 3);
    }

    // =========================================================================
    // rawFulfillRandomWords
    // =========================================================================

    function test_RawFulfillRandomWords_ForwardsToPackMachine() public {
        MockPackMachine machine = new MockPackMachine();
        vm.prank(operator);
        router.setAuthorizedPackMachine(address(machine), true);

        vm.prank(address(machine));
        uint256 requestId = router.requestRandomWords(makeAddr("user"), 2);

        uint256[] memory words = new uint256[](2);
        words[0] = 111;
        words[1] = 222;

        vm.prank(address(coordinator));
        router.rawFulfillRandomWords(requestId, words);

        assertTrue(machine.fulfilled());
        assertEq(machine.lastRequestId(), requestId);
        assertEq(machine.lastRandomWords(0), 111);
        assertEq(machine.lastRandomWords(1), 222);
    }

    function test_RawFulfillRandomWords_EmitsEvent() public {
        MockPackMachine machine = new MockPackMachine();
        vm.prank(operator);
        router.setAuthorizedPackMachine(address(machine), true);

        vm.prank(address(machine));
        uint256 requestId = router.requestRandomWords(makeAddr("user"), 1);

        uint256[] memory words = new uint256[](1);
        words[0] = 999;

        vm.expectEmit(true, true, false, false, address(router));
        emit RandomnessFulfilled(requestId, address(machine));

        vm.prank(address(coordinator));
        router.rawFulfillRandomWords(requestId, words);
    }

    function test_RawFulfillRandomWords_DeletesRequest() public {
        MockPackMachine machine = new MockPackMachine();
        vm.prank(operator);
        router.setAuthorizedPackMachine(address(machine), true);

        vm.prank(address(machine));
        uint256 requestId = router.requestRandomWords(makeAddr("user"), 1);

        uint256[] memory words = new uint256[](1);
        words[0] = 1;

        vm.prank(address(coordinator));
        router.rawFulfillRandomWords(requestId, words);

        // Second fulfill on same requestId should revert (deleted → packMachine == address(0))
        vm.prank(address(coordinator));
        vm.expectRevert(
            abi.encodeWithSelector(
                PackVRFRouter.PackVRFRouter__UnknownRequest.selector,
                requestId
            )
        );
        router.rawFulfillRandomWords(requestId, words);
    }

    function test_RawFulfillRandomWords_NonCoordinatorReverts() public {
        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackVRFRouter.PackVRFRouter__OnlyCoordinator.selector,
                unauthorized
            )
        );
        router.rawFulfillRandomWords(1, words);
    }

    function test_RawFulfillRandomWords_UnknownRequestReverts() public {
        uint256[] memory words = new uint256[](1);
        words[0] = 1;
        vm.prank(address(coordinator));
        vm.expectRevert(
            abi.encodeWithSelector(
                PackVRFRouter.PackVRFRouter__UnknownRequest.selector,
                999
            )
        );
        router.rawFulfillRandomWords(999, words);
    }

    // =========================================================================
    // Admin setters (DEFAULT_ADMIN only)
    // =========================================================================

    function test_SetVRFCoordinator_AdminSucceeds() public {
        address newCoord = makeAddr("newCoord");
        vm.prank(admin);
        router.setVRFCoordinator(newCoord);
        assertEq(router.vrfCoordinator(), newCoord);
    }

    function test_SetVRFCoordinator_EmitsEvent() public {
        address newCoord = makeAddr("newCoord");
        vm.expectEmit(true, true, false, false, address(router));
        emit VRFCoordinatorUpdated(address(coordinator), newCoord);
        vm.prank(admin);
        router.setVRFCoordinator(newCoord);
    }

    function test_SetVRFCoordinator_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        router.setVRFCoordinator(makeAddr("x"));
    }

    function test_SetVRFCoordinator_ZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(PackVRFRouter.PackVRFRouter__ZeroAddress.selector);
        router.setVRFCoordinator(address(0));
    }

    function test_SetSubscriptionId_AdminSucceeds() public {
        vm.prank(admin);
        router.setSubscriptionId(999);
        assertEq(router.subscriptionId(), 999);
    }

    function test_SetSubscriptionId_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        router.setSubscriptionId(999);
    }

    function test_SetKeyHash_AdminSucceeds() public {
        bytes32 newHash = keccak256("new-key");
        vm.prank(admin);
        router.setKeyHash(newHash);
    }

    function test_SetKeyHash_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        router.setKeyHash(keccak256("new-key"));
    }

    function test_SetCallbackGasLimit_AdminSucceeds() public {
        vm.prank(admin);
        router.setCallbackGasLimit(1_000_000);
    }

    function test_SetCallbackGasLimit_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        router.setCallbackGasLimit(1_000_000);
    }

    function test_SetRequestConfirmations_AdminSucceeds() public {
        vm.prank(admin);
        router.setRequestConfirmations(6);
    }

    function test_SetRequestConfirmations_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        router.setRequestConfirmations(6);
    }

    // =========================================================================
    // UUPS upgrade
    // =========================================================================

    function test_Upgrade_UpgraderSucceeds() public {
        PackVRFRouter newImpl = new PackVRFRouter();
        vm.prank(upgrader);
        router.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_UnauthorizedReverts() public {
        PackVRFRouter newImpl = new PackVRFRouter();
        vm.prank(unauthorized);
        vm.expectRevert();
        router.upgradeToAndCall(address(newImpl), "");
    }

    // =========================================================================
    // setCoordinator (IVRFMigratableConsumerV2Plus)
    // =========================================================================

    function test_SetCoordinator_CoordinatorCanCall() public {
        address newCoord = makeAddr("newCoord");
        vm.expectEmit(true, true, false, false, address(router));
        emit VRFCoordinatorUpdated(address(coordinator), newCoord);
        vm.expectEmit(true, false, false, false, address(router));
        emit CoordinatorSet(newCoord);
        vm.prank(address(coordinator));
        router.setCoordinator(newCoord);
        assertEq(router.vrfCoordinator(), newCoord);
    }

    function test_SetCoordinator_AdminCanCall() public {
        address newCoord = makeAddr("newCoord");
        vm.expectEmit(true, true, false, false, address(router));
        emit VRFCoordinatorUpdated(address(coordinator), newCoord);
        vm.expectEmit(true, false, false, false, address(router));
        emit CoordinatorSet(newCoord);
        vm.prank(admin);
        router.setCoordinator(newCoord);
        assertEq(router.vrfCoordinator(), newCoord);
    }

    function test_SetCoordinator_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackVRFRouter.PackVRFRouter__OnlyCoordinatorOrAdmin.selector,
                unauthorized
            )
        );
        router.setCoordinator(makeAddr("newCoord"));
    }

    function test_SetCoordinator_ZeroAddressReverts() public {
        vm.prank(admin);
        vm.expectRevert(PackVRFRouter.PackVRFRouter__ZeroAddress.selector);
        router.setCoordinator(address(0));
    }

    // =========================================================================
    // setRequestConfirmations bounds
    // =========================================================================

    function test_SetRequestConfirmations_RevertsOnZero() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackVRFRouter.PackVRFRouter__InvalidConfirmations.selector,
                uint16(0)
            )
        );
        router.setRequestConfirmations(0);
    }

    function test_SetRequestConfirmations_RevertsAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackVRFRouter.PackVRFRouter__InvalidConfirmations.selector,
                uint16(201)
            )
        );
        router.setRequestConfirmations(201);
    }

    function test_SetRequestConfirmations_MaxValueSucceeds() public {
        vm.prank(admin);
        router.setRequestConfirmations(200);
    }

    // =========================================================================
    // Event declarations
    // =========================================================================

    event RandomnessRequested(
        uint256 indexed requestId,
        address indexed packMachine,
        address user
    );
    event RandomnessFulfilled(
        uint256 indexed requestId,
        address indexed packMachine
    );
    event PackMachineAuthorized(address indexed packMachine, bool authorized);
    event VRFCoordinatorUpdated(
        address indexed oldCoordinator,
        address indexed newCoordinator
    );
    event CoordinatorSet(address vrfCoordinator);
}
