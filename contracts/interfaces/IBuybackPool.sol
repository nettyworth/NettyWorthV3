// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IBuybackPool {
    // =========================================================================
    // Types
    // =========================================================================

    /// @dev Buyback mode.
    ///      FMV   (0) — payout = on-chain appraisal value × buybackBps / 10000
    ///      Spend (1) — payout = amountPaidPerCard × buybackBps / 10000
    enum BuybackMode {
        FMV,
        Spend
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted on every successful buyback.
    /// @param payout       Gross payout = basis × buybackBps / BPS (before fee).
    /// @param sellerAmount Net USDC actually transferred to the seller (payout − fee).
    /// @param fee          Protocol fee routed to financeWallet (payout × buybackFeeBps / BPS).
    ///                     Zero when buybackFeeBps == 0.
    /// @param basis        The value the payout was computed against: the on-chain appraisal
    ///                     in FMV mode, or the amount paid per card in Spend mode.
    event BuybackExecuted(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 payout,
        uint256 sellerAmount,
        uint256 fee,
        uint256 basis
    );

    /// @notice Emitted when a buyback NFT cannot be redeposited because its source
    ///         PackMachine has been deregistered. Admin must call rescueNFT to recover.
    event TokenStuck(uint256 indexed tokenId, address indexed sourceMachine);

    // =========================================================================
    // Pack-opening registration
    // =========================================================================

    /// @notice Called by PackMachine during fulfillRandomness to record a won token's
    ///         buyback data, including the actual amount the buyer paid per card
    ///         (net of discounts). Used when the machine is in Spend mode.
    /// @param tokenId The AssetNFT token ID.
    /// @param tier Rarity tier the token came from (0-5).
    /// @param sourcePackMachine The PackMachine clone that fulfilled this pack opening.
    /// @param amountPaidPerCard Amount the buyer paid per card in payment-token units
    ///        (net of promo / first-open discounts). Pass 0 if unknown; Spend-mode
    ///        buybacks on such tokens will revert BuybackPool__NoPaidAmount.
    function registerToken(
        uint256 tokenId,
        uint8 tier,
        address sourcePackMachine,
        uint128 amountPaidPerCard
    ) external;

    /// @notice Compat overload for PackMachine clones that call the 3-arg selector
    ///         (deployed before the amountPaidPerCard field was added).
    ///         amountPaidPerCard is recorded as 0; these tokens can only be bought back
    ///         in FMV mode.
    function registerToken(
        uint256 tokenId,
        uint8 tier,
        address sourcePackMachine
    ) external;

    /// @notice Legacy 4-arg overload retained for already-deployed PackMachine clones
    ///         created before the price-based buyback model was removed. `pricePerCard`
    ///         is ignored — payout is now computed from on-chain appraisal (FMV mode) or
    ///         amountPaidPerCard (Spend mode) — but the selector must remain so immutable
    ///         clones can still register won cards.
    function registerToken(
        uint256 tokenId,
        uint128 pricePerCard,
        uint8 tier,
        address sourcePackMachine
    ) external;

    // =========================================================================
    // Buyback — user-facing
    // =========================================================================

    /// @notice Sell a token back to the pool at the buyback rate configured for its source
    ///         PackMachine.
    ///         FMV mode:   Payout = on-chain appraisal value × buybackBps / 10000
    ///         Spend mode: Payout = amountPaidPerCard × buybackBps / 10000
    /// @dev    Caller must own the token and have approved this contract.
    ///         Reverts with BuybackPool__NoAppraisal (FMV mode) if the token has no
    ///         on-chain appraisal, or BuybackPool__NoPaidAmount (Spend mode) if the
    ///         token was registered via a legacy overload.
    /// @param tokenId The AssetNFT token ID to sell back.
    function buyback(uint256 tokenId) external;

    /// @notice Sell a token back applying a buyback-boost promo code.
    /// @dev    The PromoCodeRegistry is queried to validate and consume the code.
    ///         Reverts if the registry is not configured or the code is invalid.
    ///         Pass bytes32(0) as codeId to sell back without a boost (equivalent to the
    ///         no-code overload).
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

    /// @notice Withdraw a specific amount of the payment token to a chosen destination.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Callable at any time (not gated by pause).
    ///         Reverts BuybackPool__InsufficientBalance if amount exceeds the pool balance.
    /// @param to     Recipient (must be non-zero).
    /// @param amount Amount of payment token to withdraw (must be > 0).
    function withdraw(address to, uint256 amount) external;

    // =========================================================================
    // Admin — rate configuration
    // =========================================================================

    /// @notice Set the global default buyback rate (basis points, e.g. 8000 = 80%).
    function setDefaultBuybackBps(uint16 bps) external;

    /// @notice Set a per-PackMachine buyback rate override (0 clears the override,
    ///         falling back to defaultBuybackBps).
    function setPackMachineBuybackBps(address machine, uint16 bps) external;

    /// @notice Set the protocol fee charged on every buyback payout (basis points).
    ///         The fee is deducted from the seller's payout and sent to financeWallet.
    ///         0 disables the fee entirely (default). Max 100% (10000).
    function setBuybackFeeBps(uint16 bps) external;

    // =========================================================================
    // Admin — mode configuration
    // =========================================================================

    /// @notice Set the global default buyback mode.
    /// @param mode 0 = FMV (appraisal-based), 1 = Spend (amount-paid-based).
    function setDefaultBuybackMode(uint8 mode) external;

    /// @notice Set a per-PackMachine buyback mode override.
    ///         Uses a +1 offset encoding: 0 = clear (inherit global), 1 = FMV, 2 = Spend.
    function setPackMachineBuybackMode(address machine, uint8 mode) external;

    // =========================================================================
    // Views
    // =========================================================================

    function getTokenInfo(
        uint256 tokenId
    )
        external
        view
        returns (uint8 tier, address sourcePackMachine, bool isActive);

    /// @notice Returns the amount paid per card recorded for a token (0 if registered
    ///         via a legacy overload that predates this field).
    function getTokenPaidAmount(
        uint256 tokenId
    ) external view returns (uint128);

    function poolBalance() external view returns (uint256);

    function getDefaultBuybackBps() external view returns (uint16);

    function getPackMachineBuybackBps(
        address machine
    ) external view returns (uint16);

    /// @notice Returns the current buyback fee rate in basis points (0 = no fee).
    function getBuybackFeeBps() external view returns (uint16);

    /// @notice Cumulative net USDC actually transferred to sellers across all buybacks.
    ///         Does not include protocol fees.
    function getTotalSellerPaid() external view returns (uint256);

    /// @notice Cumulative protocol fees routed to financeWallet across all buybacks.
    function getTotalFeesCollected() external view returns (uint256);

    /// @notice Returns the global default buyback mode (FMV=0, Spend=1).
    function getDefaultBuybackMode() external view returns (BuybackMode);

    /// @notice Returns the per-machine mode override using the +1 offset encoding
    ///         (0 = unset/inherit global, 1 = FMV, 2 = Spend).
    function getPackMachineBuybackMode(
        address machine
    ) external view returns (uint8);
}
