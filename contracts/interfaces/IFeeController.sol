// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IFeeController
/// @notice Interface for the NettyWorth v3 FeeController — manages collectible sale fees
///         and physical redemption/shipment fees for the Base marketplace.
interface IFeeController {
    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when the collectible sale fee bps is updated.
    event CollectibleFeesUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when the redemption/shipment fee bps is updated.
    event RedemptionFeeUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when the collectible fees enabled flag changes.
    event CollectibleFeesEnabledUpdated(bool enabled);

    /// @notice Emitted when the redemption fees enabled flag changes.
    event RedemptionFeeEnabledUpdated(bool enabled);

    /// @notice Emitted when the protocol fee recipient (treasury) changes.
    event ProtocolFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // =========================================================================
    // Errors
    // =========================================================================

    error FeeController__ZeroAddress();
    error FeeController__FeeTooHigh(uint256 bps, uint256 max);

    // =========================================================================
    // Admin setters
    // =========================================================================

    /// @notice Set the collectible sale fee in basis points (max 1000 = 10%).
    function setCollectibleFeesBps(uint16 bps) external;

    /// @notice Set the redemption/shipment fee in basis points (max 10000 = 100%).
    function setRedemptionFeeBps(uint16 bps) external;

    /// @notice Enable or disable collectible fees without changing the bps value.
    function setCollectibleFeesEnabled(bool enabled) external;

    /// @notice Enable or disable redemption fees without changing the bps value.
    function setRedemptionFeeEnabled(bool enabled) external;

    /// @notice Set the protocol fee recipient (platform treasury).
    function setProtocolFeeRecipient(address recipient) external;

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Compute the collectible sale fee for a given gross sale amount.
    /// @param amount Gross sale price in payment token units.
    /// @return fee Fee amount (0 if disabled).
    /// @return enabled Current enabled state of collectible fees.
    function getCollectibleFee(uint256 amount) external view returns (uint256 fee, bool enabled);

    /// @notice Compute the redemption fee for a given base value (e.g. appraisal value).
    /// @param baseValue Base amount in payment token units.
    /// @return fee Fee amount (0 if disabled or baseValue == 0).
    /// @return enabled Current enabled state of redemption fees.
    function getRedemptionFee(uint256 baseValue) external view returns (uint256 fee, bool enabled);

    /// @notice Current collectible fee rate in basis points.
    function collectibleFeesBps() external view returns (uint16);

    /// @notice Current redemption fee rate in basis points.
    function redemptionFeeBps() external view returns (uint16);

    /// @notice Whether collectible fees are currently enabled.
    function collectibleFeesEnabled() external view returns (bool);

    /// @notice Whether redemption fees are currently enabled.
    function redemptionFeeEnabled() external view returns (bool);

    /// @notice Address that receives collected fees.
    function protocolFeeRecipient() external view returns (address);
}
