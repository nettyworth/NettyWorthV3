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
}
