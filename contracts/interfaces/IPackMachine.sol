// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IPackMachine {
    function initialize(
        address permissionManager,
        address factory,
        uint128 pricePerPack,
        uint8 cardsPerPack,
        uint40 startTime
    ) external;

    /// @notice Called by the PackVRFRouter to deliver random words and complete a pack open.
    function fulfillRandomness(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external;

    /// @notice Open a pack by pulling USDC directly from msg.sender.
    function openPack(address user, bytes calldata signature) external;

    /// @notice Open a pack paying via Uniswap Permit2.
    function openPackWithPermit2(
        address user,
        uint256 permit2Nonce,
        uint256 permit2Deadline,
        bytes calldata permit2Signature,
        bytes calldata playSignature
    ) external;

    /// @notice Deposit tokens into tiered prize pools.
    function deposit(
        uint256[] calldata tokenIds,
        uint8[] calldata tiers,
        address tokensOwner
    ) external;

    /// @notice Re-deposit NFTs from BuybackPool back into tier pools. Only callable by the BuybackPool.
    function depositFromPool(
        uint256[] calldata tokenIds,
        uint8[] calldata tiers,
        address tokensOwner
    ) external;

    /// @notice Withdraw specific tokens by ID. Requires paused.
    function withdrawCards(uint256[] calldata tokenIds) external;

    /// @notice Update weighted probability table. Weights must sum to 10000.
    function setTierWeights(uint16[5] calldata weights) external;

    function pricePerPack() external view returns (uint128);
    function cardsPerPack() external view returns (uint8);
    function effectivePrizePoolSize() external view returns (uint256);
    function getTierWeights() external view returns (uint16[5] memory);
    function getTierPoolSize(uint8 tier) external view returns (uint256);
    function getTierPool(uint8 tier) external view returns (uint256[] memory);
    function getBuybackPool() external view returns (address);
}
