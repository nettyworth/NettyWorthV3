// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Minimal interface for AssetNFT interactions used by AssetLendingPool.
interface IAssetNFT {
    enum AssetState {
        Held,
        Listed,
        Loaned,
        Traded,
        InShipment,
        RemovedFromPlatform
    }

    function batchSetAssetState(
        uint256[] calldata tokenIds,
        AssetState[] calldata newStates
    ) external;

    function getAssetState(uint256 tokenId) external view returns (AssetState);

    function ownerOf(uint256 tokenId) external view returns (address);

    function transferFrom(address from, address to, uint256 tokenId) external;

    function approve(address to, uint256 tokenId) external;

    /// @notice Pay the redemption fee and transition the caller's asset into physical shipment.
    /// @dev Fee = redemptionFeeBps * appraisalValue / BPS, pulled in payment token from caller → treasury.
    ///      Fee is 0 (free shipment) when appraisal value is 0. Token must be in Held state.
    /// @param tokenId AssetNFT token to ship.
    /// @param maxFee  Upper bound on the fee the caller is willing to pay (H007 slippage guard).
    ///                Pass type(uint256).max to accept any fee.
    function initiateShipment(uint256 tokenId, uint256 maxFee) external;

    /// @notice Returns ERC-2981 royalty info for a given sale price (implemented by AssetNFT via ERC2981).
    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) external view returns (address receiver, uint256 royaltyAmount);

    /// @notice Returns the appraisal value for a token from the lending pool.
    ///         Returns 0 if the lending pool is not configured or the token has no appraisal.
    function getAppraisalValue(uint256 tokenId) external view returns (uint256);
}
