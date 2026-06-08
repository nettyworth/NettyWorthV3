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

    /// @notice Sell a token back to the pool applying a buyback-boost promo code.
    /// @dev The PromoCodeRegistry is queried to validate and consume the code.
    ///      Reverts if the registry is not configured or the code is invalid.
    ///      Pass bytes32(0) as codeId to sell back without a boost (equivalent to the no-code overload).
    /// @param tokenId The AssetNFT token ID to sell back.
    /// @param codeId  keccak256 of the off-chain promo-code string; bytes32(0) means no boost.
    function buyback(uint256 tokenId, bytes32 codeId) external;

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
