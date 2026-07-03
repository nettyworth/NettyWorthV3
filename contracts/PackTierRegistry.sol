// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";
import {IPackTierRegistry} from "./interfaces/IPackTierRegistry.sol";
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";

/// @title PackTierRegistry
/// @author NettyWorth
/// @notice UUPS-upgradeable singleton that stores per-(machine, tokenId, packId) tier assignments.
///         PackMachine clones call this contract to read/write tier data instead of carrying the
///         storage themselves — this keeps PackMachine's bytecode under the 24 KiB EVM limit.
///         Only registered PackMachine clones (verified via the factory) may write.
/// @dev Storage slot is deterministic via ERC-7201. The factory address is the single wiring point:
///      any contract whose address `IPackMachineFactory(factory).isPackMachine(msg.sender)` returns
///      true is allowed to call the write functions.
/// @custom:security-contact security@nettyworth.io
contract PackTierRegistry is UUPSUpgradeable, PermissionConsumer {
    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.PackTierRegistry
    struct PackTierRegistryStorage {
        /// @dev PackMachineFactory address — used to gate write access to registered machines.
        address factory;
        /// @dev Per-(machine, tokenId, packId) tier. 0 = Base (also the default for unset entries).
        mapping(address machine => mapping(uint256 tokenId => mapping(uint256 packId => uint8 tier))) tiers;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.PackTierRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PACK_TIER_REGISTRY_STORAGE_SLOT =
        0x9c6d1f1bcd9a74b23a58d2d0476f4bb4d3ad2efb8a4d7893620a4e7b45b05900;

    function _getStorage()
        private
        pure
        returns (PackTierRegistryStorage storage $)
    {
        assembly {
            $.slot := PACK_TIER_REGISTRY_STORAGE_SLOT
        }
    }

    // =========================================================================
    // Events
    // =========================================================================

    event FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error PackTierRegistry__Unauthorized(address caller);
    error PackTierRegistry__ZeroAddress();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =========================================================================
    // Initializer
    // =========================================================================

    function initialize(address permissionManager_) external initializer {
        __PermissionConsumer_init(permissionManager_);
    }

    // =========================================================================
    // Access modifier
    // =========================================================================

    /// @dev Only registered PackMachine clones may write tier data.
    ///      Uses the factory's `isPackMachine` check, which is the same gate used
    ///      across the rest of the protocol (BuybackPool, PackVRFRouter, etc.).
    modifier onlyRegisteredMachine() {
        address factory = _getStorage().factory;
        if (
            factory == address(0) ||
            !IPackMachineFactory(factory).isPackMachine(msg.sender)
        ) revert PackTierRegistry__Unauthorized(msg.sender);
        _;
    }

    // =========================================================================
    // Write (registered pack machines only)
    // =========================================================================

    /// @notice Record or update the tier for a token in a specific pack.
    ///         msg.sender is the machine; machine address is implicit from msg.sender.
    function setTier(
        uint256 tokenId,
        uint256 packId,
        uint8 tier
    ) external onlyRegisteredMachine {
        _getStorage().tiers[msg.sender][tokenId][packId] = tier;
    }

    /// @notice Delete the tier record for a token in a specific pack.
    ///         Resets to default 0 (Base). Dormant records cleared on withdrawCards.
    function deleteTier(
        uint256 tokenId,
        uint256 packId
    ) external onlyRegisteredMachine {
        delete _getStorage().tiers[msg.sender][tokenId][packId];
    }

    /// @notice Delete tier records for a token across multiple packs in one call.
    ///         Used by withdrawCards to clear all dormant records efficiently.
    function deleteAllTiers(
        uint256 tokenId,
        uint256[] calldata packIds
    ) external onlyRegisteredMachine {
        PackTierRegistryStorage storage $ = _getStorage();
        for (uint256 i; i < packIds.length; ++i) {
            delete $.tiers[msg.sender][tokenId][packIds[i]];
        }
    }

    // =========================================================================
    // Read (public)
    // =========================================================================

    /// @notice Returns the tier for a token in a specific pack on a specific machine.
    ///         Returns 0 (Base) when no tier has been explicitly set.
    function getTier(
        address machine,
        uint256 tokenId,
        uint256 packId
    ) external view returns (uint8) {
        return _getStorage().tiers[machine][tokenId][packId];
    }

    // =========================================================================
    // Admin — factory wiring
    // =========================================================================

    /// @notice Set the factory address used to verify registered machines.
    function setFactory(
        address factory_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (factory_ == address(0)) revert PackTierRegistry__ZeroAddress();
        PackTierRegistryStorage storage $ = _getStorage();
        emit FactoryUpdated($.factory, factory_);
        $.factory = factory_;
    }

    /// @notice Returns the factory address.
    function factory() external view returns (address) {
        return _getStorage().factory;
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    function _authorizeUpgrade(
        address
    ) internal override onlyProtocolRole(Roles.UPGRADER_ROLE) {}
}
