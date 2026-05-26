// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";
import {IPackMachine} from "./interfaces/IPackMachine.sol";
import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @title PackVRFRouter
/// @author NettyWorth
/// @notice Singleton Chainlink VRF v2.5 consumer that routes randomness callbacks to PackMachine clones.
/// @dev Because Chainlink VRF subscriptions cap consumers at ~100, all PackMachine instances share this
///      single consumer. When a PackMachine needs randomness it calls `requestRandomWords`; the router
///      stores the requestId→PackMachine mapping and forwards `fulfillRandomWords` callbacks.
///      Implements rawFulfillRandomWords directly (without inheriting VRFConsumerBaseV2Plus) to remain
///      compatible with UUPS upgradeability — VRFConsumerBaseV2Plus inherits ConfirmedOwner which uses
///      constructor-based initialization incompatible with the proxy pattern.
/// @custom:security-contact security@nettyworth.io
contract PackVRFRouter is UUPSUpgradeable, PermissionConsumer {
    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.PackVRFRouter
    struct PackVRFRouterStorage {
        IVRFCoordinatorV2Plus vrfCoordinator;
        uint256 subscriptionId;
        bytes32 keyHash;
        uint32 callbackGasLimit;
        uint16 requestConfirmations;
        mapping(uint256 requestId => VRFRequest) requests;
        mapping(address packMachine => bool) authorizedPackMachines;
        bool nativePayment;
    }

    struct VRFRequest {
        address packMachine;
        address user;
        uint8 numWords;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.PackVRFRouter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PACK_VRF_ROUTER_STORAGE_SLOT =
        0x9e3c7d59c2c1e1a6a0a24454f70b7c4ed3a3a9a9f6e3b3a1c8e7d6c5b4a3a200;

    function _getStorage()
        private
        pure
        returns (PackVRFRouterStorage storage $)
    {
        assembly {
            $.slot := PACK_VRF_ROUTER_STORAGE_SLOT
        }
    }

    // =========================================================================
    // Events
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

    // =========================================================================
    // Errors
    // =========================================================================

    error PackVRFRouter__OnlyCoordinator(address caller);
    error PackVRFRouter__UnauthorizedPackMachine(address caller);
    error PackVRFRouter__UnknownRequest(uint256 requestId);
    error PackVRFRouter__ZeroAddress();

    // =========================================================================
    // Constructor & initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the router.
    /// @param permissionManager_ Address of the protocol PermissionManager.
    /// @param vrfCoordinator_ Chainlink VRF v2.5 coordinator address.
    /// @param subscriptionId_ Funded Chainlink VRF subscription ID.
    /// @param keyHash_ VRF key hash (gas lane).
    /// @param callbackGasLimit_ Gas limit forwarded to PackMachine.fulfillRandomness.
    /// @param requestConfirmations_ Block confirmations before VRF fulfillment.
    function initialize(
        address permissionManager_,
        address vrfCoordinator_,
        uint256 subscriptionId_,
        bytes32 keyHash_,
        uint32 callbackGasLimit_,
        uint16 requestConfirmations_
    ) external initializer {
        if (vrfCoordinator_ == address(0)) revert PackVRFRouter__ZeroAddress();
        __PermissionConsumer_init(permissionManager_);

        PackVRFRouterStorage storage $ = _getStorage();
        $.vrfCoordinator = IVRFCoordinatorV2Plus(vrfCoordinator_);
        $.subscriptionId = subscriptionId_;
        $.keyHash = keyHash_;
        $.callbackGasLimit = callbackGasLimit_;
        $.requestConfirmations = requestConfirmations_;
    }

    // =========================================================================
    // PackMachine-facing API
    // =========================================================================

    /// @notice Request random words on behalf of a PackMachine. Only authorized PackMachines may call.
    /// @param user Address of the user opening the pack (stored for event emission).
    /// @param numWords Number of random uint256 values required.
    /// @return requestId The Chainlink VRF request ID.
    function requestRandomWords(
        address user,
        uint8 numWords
    ) external returns (uint256 requestId) {
        PackVRFRouterStorage storage $ = _getStorage();
        if (!$.authorizedPackMachines[msg.sender]) {
            revert PackVRFRouter__UnauthorizedPackMachine(msg.sender);
        }

        requestId = $.vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: $.keyHash,
                subId: $.subscriptionId,
                requestConfirmations: $.requestConfirmations,
                callbackGasLimit: $.callbackGasLimit,
                numWords: uint32(numWords),
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({
                        nativePayment: $.nativePayment
                    })
                )
            })
        );

        $.requests[requestId] = VRFRequest({
            packMachine: msg.sender,
            user: user,
            numWords: numWords
        });
        emit RandomnessRequested(requestId, msg.sender, user);
    }

    // =========================================================================
    // Chainlink VRF callback
    // =========================================================================

    /// @notice Entry point called by the Chainlink VRF coordinator.
    /// @dev Replaces inheriting VRFConsumerBaseV2Plus to stay UUPS-compatible.
    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) external {
        PackVRFRouterStorage storage $ = _getStorage();
        if (msg.sender != address($.vrfCoordinator)) {
            revert PackVRFRouter__OnlyCoordinator(msg.sender);
        }

        VRFRequest memory req = $.requests[requestId];
        if (req.packMachine == address(0))
            revert PackVRFRouter__UnknownRequest(requestId);

        delete $.requests[requestId];

        emit RandomnessFulfilled(requestId, req.packMachine);
        IPackMachine(req.packMachine).fulfillRandomness(requestId, randomWords);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Register or deregister a PackMachine clone as an authorized caller.
    function setAuthorizedPackMachine(
        address packMachine,
        bool authorized
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (packMachine == address(0)) revert PackVRFRouter__ZeroAddress();
        _getStorage().authorizedPackMachines[packMachine] = authorized;
        emit PackMachineAuthorized(packMachine, authorized);
    }

    /// @notice Update the Chainlink VRF coordinator address (e.g. after Chainlink migration).
    function setVRFCoordinator(
        address newCoordinator
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (newCoordinator == address(0)) revert PackVRFRouter__ZeroAddress();
        PackVRFRouterStorage storage $ = _getStorage();
        emit VRFCoordinatorUpdated(address($.vrfCoordinator), newCoordinator);
        $.vrfCoordinator = IVRFCoordinatorV2Plus(newCoordinator);
    }

    function setSubscriptionId(
        uint256 subscriptionId_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _getStorage().subscriptionId = subscriptionId_;
    }

    function setKeyHash(
        bytes32 keyHash_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _getStorage().keyHash = keyHash_;
    }

    function setCallbackGasLimit(
        uint32 limit
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _getStorage().callbackGasLimit = limit;
    }

    function setRequestConfirmations(
        uint16 confirmations
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _getStorage().requestConfirmations = confirmations;
    }

    function setNativePayment(
        bool nativePayment_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _getStorage().nativePayment = nativePayment_;
    }

    // =========================================================================
    // Views
    // =========================================================================

    function vrfCoordinator() external view returns (address) {
        return address(_getStorage().vrfCoordinator);
    }

    function subscriptionId() external view returns (uint256) {
        return _getStorage().subscriptionId;
    }

    function isAuthorizedPackMachine(
        address machine
    ) external view returns (bool) {
        return _getStorage().authorizedPackMachines[machine];
    }

    function nativePayment() external view returns (bool) {
        return _getStorage().nativePayment;
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    function _authorizeUpgrade(
        address
    ) internal override onlyProtocolRole(Roles.UPGRADER_ROLE) {}
}
