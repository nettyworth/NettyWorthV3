// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IPermissionManager} from "./interfaces/IPermissionManager.sol";

/// @title PermissionConsumer
/// @author NettyWorth
/// @notice Abstract base for any protocol contract that delegates access control to the PermissionManager.
/// @dev Stores a reference to the PermissionManager and exposes the `onlyProtocolRole` modifier.
///      Supports two-step manager migration: propose → accept, to prevent accidental bricking.
///      Descendants that use ERC-2771 should override `_msgSender()` to return the meta-tx sender.
abstract contract PermissionConsumer is Initializable {
    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.PermissionConsumer
    struct PermissionConsumerStorage {
        IPermissionManager permissionManager;
        address pendingPermissionManager;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.PermissionConsumer")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PERMISSION_CONSUMER_STORAGE_SLOT =
        0xacb96b1cb32627f82a5b416623a4b3e81e836b810d7edb9c01060982fbd80b00;

    function _getPermissionConsumerStorage() private pure returns (PermissionConsumerStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := PERMISSION_CONSUMER_STORAGE_SLOT
        }
    }

    // =========================================================================
    // Events
    // =========================================================================

    event PermissionManagerProposed(address indexed proposed);
    event PermissionManagerUpdated(address indexed oldManager, address indexed newManager);

    // =========================================================================
    // Errors
    // =========================================================================

    error PermissionConsumer__Unauthorized(address caller, bytes32 role);
    error PermissionConsumer__ZeroAddress();
    error PermissionConsumer__NoPendingManager();
    error PermissionConsumer__NotPendingManagerAdmin();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyProtocolRole(bytes32 role) {
        _checkProtocolRole(role);
        _;
    }

    // =========================================================================
    // Initializer
    // =========================================================================

    function __PermissionConsumer_init(address manager) internal onlyInitializing {
        if (manager == address(0)) revert PermissionConsumer__ZeroAddress();
        _getPermissionConsumerStorage().permissionManager = IPermissionManager(manager);
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Returns the active PermissionManager address.
    function getPermissionManager() public view returns (address) {
        return address(_getPermissionConsumerStorage().permissionManager);
    }

    /// @notice Returns the pending PermissionManager address (zero if none proposed).
    function getPendingPermissionManager() public view returns (address) {
        return _getPermissionConsumerStorage().pendingPermissionManager;
    }

    // =========================================================================
    // Two-step manager migration
    // =========================================================================

    /// @notice Proposes a new PermissionManager. Must be accepted by the new manager's admin.
    /// @dev Protected by DEFAULT_ADMIN_ROLE on the current manager.
    function proposePermissionManager(address newManager) external onlyProtocolRole(0x00) {
        if (newManager == address(0)) revert PermissionConsumer__ZeroAddress();
        _getPermissionConsumerStorage().pendingPermissionManager = newManager;
        emit PermissionManagerProposed(newManager);
    }

    /// @notice Accepts the pending PermissionManager. Must be called by a DEFAULT_ADMIN_ROLE holder
    ///         on the *pending* manager.
    function acceptPermissionManager() external {
        PermissionConsumerStorage storage $ = _getPermissionConsumerStorage();
        address pending = $.pendingPermissionManager;
        if (pending == address(0)) revert PermissionConsumer__NoPendingManager();
        // Caller must hold DEFAULT_ADMIN_ROLE on the pending manager
        if (!IPermissionManager(pending).hasProtocolRole(0x00, _msgSender())) {
            revert PermissionConsumer__NotPendingManagerAdmin();
        }
        address old = address($.permissionManager);
        $.permissionManager = IPermissionManager(pending);
        $.pendingPermissionManager = address(0);
        emit PermissionManagerUpdated(old, pending);
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _checkProtocolRole(bytes32 role) internal view {
        if (!_getPermissionConsumerStorage().permissionManager.hasProtocolRole(role, _msgSender())) {
            revert PermissionConsumer__Unauthorized(_msgSender(), role);
        }
    }

    /// @dev Virtual sender hook. Override in descendants that use ERC-2771 meta-transactions.
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}
