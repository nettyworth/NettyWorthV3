// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IBuybackPool {
    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a buyback NFT cannot be redeposited because its source
    ///         PackMachine has been deregistered. Admin must call rescueNFT to recover.
    event TokenStuck(uint256 indexed tokenId, address indexed sourceMachine);

    // =========================================================================
    // Pack-opening registration
    // =========================================================================

    /// @notice Called by PackMachine during fulfillRandomness to record a won token's buyback data.
    /// @param tokenId The AssetNFT token ID.
    /// @param tier Rarity tier the token came from (0-5).
    /// @param sourcePackMachine The PackMachine clone that minted this pack opening.
    function registerToken(
        uint256 tokenId,
        uint8 tier,
        address sourcePackMachine
    ) external;

    // =========================================================================
    // Buyback — user-facing
    // =========================================================================

    /// @notice Sell a token back to the pool at the buyback rate configured for its source
    ///         PackMachine. Payout = on-chain appraisal value × buybackBps / 10000.
    /// @dev    Caller must own the token and have approved this contract.
    ///         Reverts with BuybackPool__NoAppraisal if the token has no on-chain appraisal.
    /// @param tokenId The AssetNFT token ID to sell back.
    function buyback(uint256 tokenId) external;

    /// @notice Sell a token back applying a buyback-boost promo code.
    /// @dev    The PromoCodeRegistry is queried to validate and consume the code.
    ///         Reverts if the registry is not configured or the code is invalid.
    ///         Pass bytes32(0) as codeId to sell back without a boost (equivalent to the no-code overload).
    /// @param tokenId The AssetNFT token ID to sell back.
    /// @param codeId  keccak256 of the off-chain promo-code string; bytes32(0) means no boost.
    function buyback(uint256 tokenId, bytes32 codeId) external;

    // =========================================================================
    // Admin — funding
    // =========================================================================

    /// @notice Deposit payment token (USDC) into the pool to back future buybacks.
    /// @dev    Caller must hold PACK_OPERATOR_ROLE and have approved this contract for `amount`.
    ///         Increments totalReceived and emits PoolFunded.
    /// @param amount Amount of payment token to deposit (must be > 0).
    function depositFunds(uint256 amount) external;

    // =========================================================================
    // Admin — rate configuration
    // =========================================================================

    /// @notice Set the global default buyback rate (basis points, e.g. 8000 = 80%).
    function setDefaultBuybackBps(uint16 bps) external;

    /// @notice Set a per-PackMachine buyback rate override (0 clears the override,
    ///         falling back to defaultBuybackBps).
    function setPackMachineBuybackBps(address machine, uint16 bps) external;

    // =========================================================================
    // Views
    // =========================================================================

    function getTokenInfo(
        uint256 tokenId
    )
        external
        view
        returns (uint8 tier, address sourcePackMachine, bool isActive);

    function poolBalance() external view returns (uint256);

    function getDefaultBuybackBps() external view returns (uint16);

    function getPackMachineBuybackBps(
        address machine
    ) external view returns (uint16);
}
