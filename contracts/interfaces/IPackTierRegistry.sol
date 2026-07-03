// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IPackTierRegistry
/// @notice Interface for the PackTierRegistry singleton — stores per-(machine, token, pack) tier
///         assignments so PackMachine clones do not need to carry this storage themselves.
interface IPackTierRegistry {
    // =========================================================================
    // Write (only callable by registered PackMachine clones)
    // =========================================================================

    /// @notice Record or update the tier for a token in a specific pack.
    /// @dev msg.sender must be a registered PackMachine.
    function setTier(uint256 tokenId, uint256 packId, uint8 tier) external;

    /// @notice Delete the tier record for a token in a specific pack.
    /// @dev msg.sender must be a registered PackMachine.
    function deleteTier(uint256 tokenId, uint256 packId) external;

    /// @notice Delete tier records for a token across multiple packs in one call.
    ///         Used by withdrawCards to clear all dormant records efficiently.
    /// @dev msg.sender must be a registered PackMachine.
    function deleteAllTiers(
        uint256 tokenId,
        uint256[] calldata packIds
    ) external;

    // =========================================================================
    // Read (public)
    // =========================================================================

    /// @notice Returns the tier for a token in a specific pack on a specific machine.
    ///         Returns 0 (Base) when no tier has been set — callers relying on the
    ///         absence of a record should check whether the token is actually eligible.
    function getTier(
        address machine,
        uint256 tokenId,
        uint256 packId
    ) external view returns (uint8);

    // =========================================================================
    // Errors
    // =========================================================================

    error PackTierRegistry__Unauthorized(address caller);
    error PackTierRegistry__ZeroAddress();
}
