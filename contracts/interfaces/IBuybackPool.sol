// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IBuybackPool {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Determines how a buyback payout is valued.
    /// @dev    Unset(0) means "fall through to the global default model."
    ///         AmountSpent — payout = pricePerCard × bps (cost-basis, original pack price).
    ///         FMV         — payout = signedFMV × bps (fair-market value supplied via signed quote).
    enum BuybackModel {
        Unset,       // 0 — inherit global default
        AmountSpent, // 1 — percentage of original per-card pack price
        FMV          // 2 — percentage of card's current fair-market value (requires signed FMVQuote)
    }

    /// @notice Off-chain FMV quote signed by an account holding PACK_OPERATOR_ROLE.
    /// @dev    codeId MUST be keccak256("FMVQuote(uint256 tokenId,uint256 fmv,uint256 deadline,uint256 nonce)").
    ///         nonce is per-token; incremented after each use to prevent replay.
    struct FMVQuote {
        uint256 tokenId;
        uint256 fmv;      // USDC, 6-decimal precision
        uint256 deadline; // Unix seconds; revert if block.timestamp > deadline
        uint256 nonce;    // must equal on-chain fmvQuoteNonce[tokenId]
    }

    // =========================================================================
    // Pack-opening registration
    // =========================================================================

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

    // =========================================================================
    // Buyback — user-facing
    // =========================================================================

    /// @notice Sell a token back to the pool at the buyback rate configured for its source PackMachine.
    /// @dev    Caller must own the token and have approved this contract.
    ///         Reverts with BuybackPool__FMVQuoteRequired() when the resolved model is FMV —
    ///         use the three-argument overload in that case.
    /// @param tokenId The AssetNFT token ID to sell back.
    function buyback(uint256 tokenId) external;

    /// @notice Sell a token back applying a buyback-boost promo code.
    /// @dev    The PromoCodeRegistry is queried to validate and consume the code.
    ///         Reverts if the registry is not configured or the code is invalid.
    ///         Reverts with BuybackPool__FMVQuoteRequired() when the resolved model is FMV.
    ///         Pass bytes32(0) as codeId to sell back without a boost (equivalent to the no-code overload).
    /// @param tokenId The AssetNFT token ID to sell back.
    /// @param codeId  keccak256 of the off-chain promo-code string; bytes32(0) means no boost.
    function buyback(uint256 tokenId, bytes32 codeId) external;

    /// @notice Sell a token back using a signed FMV quote (required when the resolved model is FMV).
    /// @dev    Works for both AmountSpent and FMV models; the quote is only consumed when the model is FMV.
    ///         The EIP-712 signature must be produced by an account holding PACK_OPERATOR_ROLE.
    ///         codeId may be bytes32(0) for no promo boost.
    /// @param tokenId The AssetNFT token ID to sell back.
    /// @param codeId  keccak256 of the off-chain promo-code string; bytes32(0) means no boost.
    /// @param quote   FMV quote struct (tokenId, fmv, deadline, nonce).
    /// @param sig     EIP-712 signature over the FMVQuote struct hash.
    function buyback(
        uint256 tokenId,
        bytes32 codeId,
        FMVQuote calldata quote,
        bytes calldata sig
    ) external;

    // =========================================================================
    // Admin — model configuration
    // =========================================================================

    /// @notice Set the global default buyback model used when a PackMachine has no per-machine override.
    /// @dev    Only AmountSpent or FMV are valid; reverts on Unset.
    function setDefaultBuybackModel(BuybackModel model) external;

    /// @notice Set a per-PackMachine buyback model override.
    ///         Unset(0) clears the override so the machine falls back to the global default.
    function setPackMachineBuybackModel(
        address machine,
        BuybackModel model
    ) external;

    /// @notice Enable or disable a buyback model globally.
    ///         Disabling a model prevents any buyback using that model, regardless of per-machine config.
    function setModelEnabled(BuybackModel model, bool enabled) external;

    // =========================================================================
    // Views — model configuration
    // =========================================================================

    function getDefaultBuybackModel() external view returns (BuybackModel);

    function getPackMachineBuybackModel(
        address machine
    ) external view returns (BuybackModel);

    /// @notice Resolve the effective model for a given PackMachine.
    ///         Returns the per-machine override if set, otherwise the global default.
    function getResolvedModel(address machine) external view returns (BuybackModel);

    function isModelEnabled(BuybackModel model) external view returns (bool);

    /// @notice Current per-token FMV quote nonce. Each FMV buyback increments this by 1.
    function fmvQuoteNonce(uint256 tokenId) external view returns (uint256);

    // =========================================================================
    // Views — existing
    // =========================================================================

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
