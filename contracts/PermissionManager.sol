// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IPermissionManager} from "./interfaces/IPermissionManager.sol";
import {Roles} from "./lib/Roles.sol";

/// @title PermissionManager
/// @author NettyWorth
/// @notice Centralized role registry for the NettyWorth protocol. Manages all role grants and revocations
///         across every consumer contract. Consumer contracts call `hasProtocolRole` to authorize callers.
/// @dev UUPS upgradeable. All role constants are re-exported here as public constants for off-chain readability.
///      Role admin hierarchy uses default OpenZeppelin behaviour: DEFAULT_ADMIN_ROLE administers all roles.
/// @custom:security-contact security@nettyworth.io
contract PermissionManager is AccessControlEnumerableUpgradeable, UUPSUpgradeable, IPermissionManager {
    // =========================================================================
    // Role constants (re-exported from Roles library for external readability)
    // =========================================================================

    bytes32 public constant MINTER_ROLE = Roles.MINTER_ROLE;
    bytes32 public constant BURNER_ROLE = Roles.BURNER_ROLE;
    bytes32 public constant STATE_MANAGER_ROLE = Roles.STATE_MANAGER_ROLE;
    bytes32 public constant URI_SETTER_ROLE = Roles.URI_SETTER_ROLE;
    bytes32 public constant PAUSER_ROLE = Roles.PAUSER_ROLE;
    bytes32 public constant UPGRADER_ROLE = Roles.UPGRADER_ROLE;
    bytes32 public constant BLACKLIST_ROLE = Roles.BLACKLIST_ROLE;

    // =========================================================================
    // Errors
    // =========================================================================

    error PermissionManager__ZeroAddress();

    // =========================================================================
    // Constructor & initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the PermissionManager and grants all protocol roles to `defaultAdmin`.
    /// @param defaultAdmin Address that receives DEFAULT_ADMIN_ROLE and all operational roles.
    function initialize(address defaultAdmin) external initializer {
        if (defaultAdmin == address(0)) revert PermissionManager__ZeroAddress();

        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(Roles.MINTER_ROLE, defaultAdmin);
        _grantRole(Roles.BURNER_ROLE, defaultAdmin);
        _grantRole(Roles.STATE_MANAGER_ROLE, defaultAdmin);
        _grantRole(Roles.URI_SETTER_ROLE, defaultAdmin);
        _grantRole(Roles.PAUSER_ROLE, defaultAdmin);
        _grantRole(Roles.UPGRADER_ROLE, defaultAdmin);
        _grantRole(Roles.BLACKLIST_ROLE, defaultAdmin);
    }

    // =========================================================================
    // IPermissionManager
    // =========================================================================

    /// @inheritdoc IPermissionManager
    function hasProtocolRole(bytes32 role, address account) external view returns (bool) {
        return hasRole(role, account);
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
