// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {PackTypes} from "../lib/PackTypes.sol";

interface IPackMachine {
    // =========================================================================
    // View return types
    // =========================================================================

    struct MachineInfo {
        address factory;
        address buybackPool;
        uint256 effectivePrizePoolSize;
    }

    struct UserInfo {
        uint256 openNonce;
        bool claimedFirstOpenDiscount;
    }

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @notice Called by the factory immediately after cloning.
    ///         Pack 0 is created in the PackRegistry by the factory; the clone itself holds
    ///         no pack array.
    function initialize(
        address permissionManager,
        address factory,
        uint128 pricePerPack,
        uint8 cardsPerPack,
        uint40 startTime
    ) external;

    // =========================================================================
    // VRF callback
    // =========================================================================

    /// @notice Called by the PackVRFRouter to deliver random words and complete a pack open.
    function fulfillRandomness(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external;

    // =========================================================================
    // Pack-open flows
    // =========================================================================

    /// @notice Open a pack by pulling USDC directly from msg.sender.
    /// @param user      Recipient of the won cards.
    /// @param packId  Which pack to open.
    /// @param signature EIP-712 `OpenPack(address user, uint256 packId, uint256 nonce)`.
    function openPack(
        address user,
        uint256 packId,
        bytes calldata signature
    ) external;

    /// @notice Open a pack by pulling USDC directly from msg.sender, applying a promo discount.
    /// @param codeId keccak256 of the promo-code string; bytes32(0) means no discount.
    function openPack(
        address user,
        uint256 packId,
        bytes calldata signature,
        bytes32 codeId
    ) external;

    /// @notice Open a pack paying via Uniswap Permit2.
    function openPackWithPermit2(
        address user,
        uint256 packId,
        uint256 permit2Nonce,
        uint256 permit2Deadline,
        bytes calldata permit2Signature,
        bytes calldata playSignature
    ) external;

    /// @notice Open a pack via Uniswap Permit2 with a promo discount code.
    function openPackWithPermit2(
        address user,
        uint256 packId,
        uint256 permit2Nonce,
        uint256 permit2Deadline,
        bytes calldata permit2Signature,
        bytes calldata playSignature,
        bytes32 codeId
    ) external;

    // =========================================================================
    // Deposit / withdraw (machine-wide shared pool)
    // =========================================================================

    /// @notice Deposit tokens into per-pack tiered prize pools.
    ///         Uses flat encoding: packCounts[i] entries from packIds/tiers belong to tokenIds[i].
    /// @param packCounts Number of (pack, tier) entries per token.
    /// @param packIds    Flat array of pack indices; contiguous blocks per token per packCounts.
    /// @param tiers      Flat array of tiers, parallel to packIds.
    function deposit(
        uint256[] calldata tokenIds,
        uint256[] calldata packCounts,
        uint256[] calldata packIds,
        uint8[] calldata tiers,
        address tokensOwner
    ) external;

    /// @notice Re-deposit NFTs from BuybackPool or AssetLendingPool back into pack pools.
    ///         The dormant packTokenTier map restores per-pack tiers automatically.
    ///         The tiers param provides a fallback for any pack with no dormant tier record.
    function depositFromPool(
        uint256[] calldata tokenIds,
        uint8[] calldata tiers,
        address tokensOwner
    ) external;

    /// @notice Withdraw specific tokens by ID. Requires paused.
    function withdrawCards(uint256[] calldata tokenIds) external;

    // =========================================================================
    // Machine-wide admin (stays on the clone)
    // =========================================================================

    /// @notice Set the BuybackPool address (machine-wide).
    function setBuybackPool(address pool) external;

    /// @notice Authorize or revoke a pool contract's ability to call depositFromPool.
    function setAuthorizedDepositor(
        address depositor,
        bool authorized
    ) external;

    // =========================================================================
    // Views — pack (pass-throughs to PackRegistry)
    // =========================================================================

    function getPack(
        uint256 packId
    ) external view returns (PackTypes.Pack memory);

    // =========================================================================
    // Views — machine-wide pool
    // =========================================================================

    /// @notice Returns all machine-wide config and pool state in one call.
    function getMachineInfo() external view returns (MachineInfo memory);

    /// @notice Returns per-user nonce and first-open discount status in one call.
    function getUserInfo(address user) external view returns (UserInfo memory);

    /// @notice Returns the resolved tier for a token in a specific pack.
    function getPackTokenTier(
        uint256 tokenId,
        uint256 packId
    ) external view returns (uint8);

    // =========================================================================
    // Eligibility setters (per-pack card membership)
    // =========================================================================

    /// @notice Add or remove a single pack's eligibility for a batch of tokens.
    ///         When adding (eligible=true), tiers must be supplied (one per token).
    function setPackEligibility(
        uint256 packId,
        uint256[] calldata tokenIds,
        uint8[] calldata tiers,
        bool eligible
    ) external;

    // =========================================================================
    // Views — per-pack eligibility
    // =========================================================================

    function getTokenEligibility(
        uint256 tokenId
    ) external view returns (uint256);

    function isTokenEligibleForPack(
        uint256 tokenId,
        uint256 packId
    ) external view returns (bool);

    function getPackTierPoolSize(
        uint256 packId,
        uint8 tier
    ) external view returns (uint256);

    function getPackAvailable(uint256 packId) external view returns (uint256);

    function isInCustody(uint256 tokenId) external view returns (bool);
}
