// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IBuybackPool {
    /// @notice Called by PackMachine during fulfillRandomness to record a won token's buyback data.
    /// @param tokenId The AssetNFT token ID.
    /// @param pricePerCard USDC per-card price (pricePerPack / cardsPerPack), 6-decimal precision.
    /// @param tier Rarity tier the token came from (0-4).
    /// @param sourcePackMachine The PackMachine clone that minted this pack opening.
    function registerToken(
        uint256 tokenId,
        uint128 pricePerCard,
        uint8 tier,
        address sourcePackMachine
    ) external;

    /// @notice Sell a token back to the pool at the buyback rate configured for its source PackMachine.
    /// @dev Caller must own the token and have approved this contract.
    /// @param tokenId The AssetNFT token ID to sell back.
    function buyback(uint256 tokenId) external;

    function getTokenInfo(
        uint256 tokenId
    )
        external
        view
        returns (
            uint128 pricePerCard,
            uint8 tier,
            address sourcePackMachine,
            bool isActive
        );

    function poolBalance() external view returns (uint256);

    function getPackMachineBuybackBps(
        address machine
    ) external view returns (uint16);
}
