// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IFeeController} from "./interfaces/IFeeController.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";

/// @title FeeController
/// @author NettyWorth
/// @notice Manages marketplace and physical-redemption fee rates for the NettyWorth v3 Base deployment.
///         Tracks two fee types — collectible sale fees and redemption/shipment fees — with independent
///         enable/disable flags so one can be toggled without disturbing the other.
/// @dev UUPS upgradeable. Access control via PermissionConsumer/PermissionManager (not Ownable).
///      ERC-7201 namespaced storage prevents upgrade slot collisions.
///      This contract is deployed fresh on Base and does NOT affect the Ethereum V2 FeeController.
/// @custom:security-contact security@nettyworth.io
contract FeeController is IFeeController, Initializable, UUPSUpgradeable, PermissionConsumer {
    // =========================================================================
    // Constants
    // =========================================================================

    uint256 internal constant BPS = 10_000;

    /// @notice Maximum collectible sale fee: 10% (1000 bps).
    uint16 internal constant MAX_COLLECTIBLE_FEE = 1_000;

    /// @notice Maximum redemption fee: 100% (10000 bps = full BPS range, per requirement).
    uint16 internal constant MAX_REDEMPTION_FEE = 10_000;

    /// @notice Default collectible sale fee: 5% (500 bps).
    uint16 internal constant DEFAULT_COLLECTIBLE_BPS = 500;

    /// @notice Default redemption/shipment fee: 5% (500 bps).
    uint16 internal constant DEFAULT_REDEMPTION_BPS = 500;

    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.FeeController
    struct FeeControllerStorage {
        /// @dev Address that receives all protocol fees (platform treasury).
        address protocolFeeRecipient;
        /// @dev Collectible sale fee in basis points (default 500 = 5%).
        uint16 collectibleFeesBps;
        /// @dev Redemption/shipment fee in basis points (default 500 = 5%).
        uint16 redemptionFeeBps;
        /// @dev Independent toggle for collectible sale fees.
        bool collectibleFeesEnabled;
        /// @dev Independent toggle for redemption/shipment fees.
        bool redemptionFeeEnabled;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.FeeController")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FEE_CONTROLLER_STORAGE_SLOT =
        0x16282aa3535788a12f78176b028b84bac0775ab65d39753784b083cc58ab5800;

    function _getFeeControllerStorage() private pure returns (FeeControllerStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := FEE_CONTROLLER_STORAGE_SLOT
        }
    }

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

    /// @notice Initializes the FeeController with default fee rates (both enabled at 5%).
    /// @param permissionManager_ Address of the deployed PermissionManager proxy.
    /// @param protocolFeeRecipient_ Platform treasury address to receive collected fees.
    function initialize(
        address permissionManager_,
        address protocolFeeRecipient_
    ) external initializer {
        if (protocolFeeRecipient_ == address(0)) revert FeeController__ZeroAddress();

        __PermissionConsumer_init(permissionManager_);

        FeeControllerStorage storage $ = _getFeeControllerStorage();
        $.protocolFeeRecipient = protocolFeeRecipient_;
        $.collectibleFeesBps = DEFAULT_COLLECTIBLE_BPS;
        $.redemptionFeeBps = DEFAULT_REDEMPTION_BPS;
        $.collectibleFeesEnabled = true;
        $.redemptionFeeEnabled = true;
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyProtocolRole(Roles.UPGRADER_ROLE) {}

    // =========================================================================
    // Admin setters — each touches only its own field (independent)
    // =========================================================================

    /// @inheritdoc IFeeController
    function setCollectibleFeesBps(
        uint16 bps
    ) external override onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_COLLECTIBLE_FEE) {
            revert FeeController__FeeTooHigh(bps, MAX_COLLECTIBLE_FEE);
        }
        FeeControllerStorage storage $ = _getFeeControllerStorage();
        uint16 old = $.collectibleFeesBps;
        $.collectibleFeesBps = bps;
        emit CollectibleFeesUpdated(old, bps);
    }

    /// @inheritdoc IFeeController
    function setRedemptionFeeBps(
        uint16 bps
    ) external override onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (bps > MAX_REDEMPTION_FEE) {
            revert FeeController__FeeTooHigh(bps, MAX_REDEMPTION_FEE);
        }
        FeeControllerStorage storage $ = _getFeeControllerStorage();
        uint16 old = $.redemptionFeeBps;
        $.redemptionFeeBps = bps;
        emit RedemptionFeeUpdated(old, bps);
    }

    /// @inheritdoc IFeeController
    function setCollectibleFeesEnabled(
        bool enabled
    ) external override onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _getFeeControllerStorage().collectibleFeesEnabled = enabled;
        emit CollectibleFeesEnabledUpdated(enabled);
    }

    /// @inheritdoc IFeeController
    function setRedemptionFeeEnabled(
        bool enabled
    ) external override onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _getFeeControllerStorage().redemptionFeeEnabled = enabled;
        emit RedemptionFeeEnabledUpdated(enabled);
    }

    /// @inheritdoc IFeeController
    function setProtocolFeeRecipient(
        address recipient
    ) external override onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert FeeController__ZeroAddress();
        FeeControllerStorage storage $ = _getFeeControllerStorage();
        address old = $.protocolFeeRecipient;
        $.protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(old, recipient);
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @inheritdoc IFeeController
    function getCollectibleFee(
        uint256 amount
    ) external view override returns (uint256 fee, bool enabled) {
        FeeControllerStorage storage $ = _getFeeControllerStorage();
        enabled = $.collectibleFeesEnabled;
        fee = enabled ? (amount * $.collectibleFeesBps) / BPS : 0;
    }

    /// @inheritdoc IFeeController
    function getRedemptionFee(
        uint256 baseValue
    ) external view override returns (uint256 fee, bool enabled) {
        FeeControllerStorage storage $ = _getFeeControllerStorage();
        enabled = $.redemptionFeeEnabled;
        fee = (enabled && baseValue > 0) ? (baseValue * $.redemptionFeeBps) / BPS : 0;
    }

    /// @inheritdoc IFeeController
    function collectibleFeesBps() external view override returns (uint16) {
        return _getFeeControllerStorage().collectibleFeesBps;
    }

    /// @inheritdoc IFeeController
    function redemptionFeeBps() external view override returns (uint16) {
        return _getFeeControllerStorage().redemptionFeeBps;
    }

    /// @inheritdoc IFeeController
    function collectibleFeesEnabled() external view override returns (bool) {
        return _getFeeControllerStorage().collectibleFeesEnabled;
    }

    /// @inheritdoc IFeeController
    function redemptionFeeEnabled() external view override returns (bool) {
        return _getFeeControllerStorage().redemptionFeeEnabled;
    }

    /// @inheritdoc IFeeController
    function protocolFeeRecipient() external view override returns (address) {
        return _getFeeControllerStorage().protocolFeeRecipient;
    }
}
