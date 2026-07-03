// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IPromoCodeRegistry
/// @author NettyWorth
/// @notice Interface for the central promo-code registry.
///         Callers: PackMachine clones (redeemDiscount) and BuybackPool (redeemBuyback).
interface IPromoCodeRegistry {
    // =========================================================================
    // Types
    // =========================================================================

    enum PromoKind {
        Discount, // 0 — reduces PackMachine pack price
        Buyback   // 1 — boosts BuybackPool payout rate
    }

    struct PromoCode {
        PromoKind kind;
        uint16 bps; // Discount: 1000/1500/2000/2500 ; Buyback: 9000/9500/9800
        uint64 expiry; // Unix seconds; 0 = never expires
        uint32 maxRedemptions; // 0 = uncapped
        uint32 redeemedCount;
        bool restricted; // true = allowlist enforced; false = open to all
        bool active; // admin kill switch
        bool oncePerUser; // true = each address may redeem at most once
        bool exists; // distinguishes a created code from a default-zero record
        /// @dev Discount codes only. If non-zero, only this PackMachine clone may redeem.
        ///      address(0) = valid on any registered PackMachine (global code).
        address machine;
    }

    // =========================================================================
    // Errors
    // =========================================================================

    error PromoCodeRegistry__ZeroAddress();
    error PromoCodeRegistry__CodeExists(bytes32 codeId);
    error PromoCodeRegistry__CodeNotFound(bytes32 codeId);
    error PromoCodeRegistry__InvalidBps(PromoKind kind, uint16 bps);
    error PromoCodeRegistry__WrongKind(
        bytes32 codeId,
        PromoKind expected,
        PromoKind actual
    );
    error PromoCodeRegistry__Inactive(bytes32 codeId);
    error PromoCodeRegistry__Expired(bytes32 codeId);
    error PromoCodeRegistry__LimitReached(bytes32 codeId);
    error PromoCodeRegistry__NotAllowlisted(bytes32 codeId, address user);
    error PromoCodeRegistry__AlreadyRedeemed(bytes32 codeId, address user);
    error PromoCodeRegistry__UnauthorizedRedeemer(address caller);
    error PromoCodeRegistry__WrongMachine(bytes32 codeId, address expected, address actual);
    error PromoCodeRegistry__BatchTooLarge(uint256 given, uint256 max);
    error PromoCodeRegistry__NotConfigured();

    // =========================================================================
    // Events
    // =========================================================================

    event CodeCreated(
        bytes32 indexed codeId,
        PromoKind kind,
        uint16 bps,
        uint64 expiry,
        uint32 maxRedemptions,
        bool restricted,
        bool oncePerUser,
        address machine
    );
    event CodeActiveSet(bytes32 indexed codeId, bool active);
    event CodeExpirySet(bytes32 indexed codeId, uint64 expiry);
    event CodeMaxRedemptionsSet(bytes32 indexed codeId, uint32 maxRedemptions);
    event AllowlistUpdated(
        bytes32 indexed codeId,
        address indexed user,
        bool allowed
    );
    event CodeRedeemed(
        bytes32 indexed codeId,
        address indexed user,
        PromoKind kind,
        uint16 bps,
        uint32 redeemedCount
    );
    event CodeRefunded(
        bytes32 indexed codeId,
        address indexed user,
        PromoKind kind,
        uint32 redeemedCount
    );
    event PackMachineFactorySet(
        address indexed oldFactory,
        address indexed newFactory
    );
    event BuybackPoolSet(
        address indexed oldPool,
        address indexed newPool
    );

    // =========================================================================
    // Redemption (called by spokes)
    // =========================================================================

    /// @notice Consume a discount code on behalf of `user`.
    /// @dev Only callable by a registered PackMachine clone (validated via factory.isPackMachine).
    ///      Reverts if the registry is not configured, the code is invalid/expired/exhausted,
    ///      or the caller is not an authorized PackMachine.
    /// @param codeId keccak256 hash of the off-chain promo-code string.
    /// @param user  Economic beneficiary (pack buyer). Used for allowlist and oncePerUser checks.
    /// @return bps  Discount in basis points (1000/1500/2000/2500 = 10/15/20/25%).
    function redeemDiscount(
        bytes32 codeId,
        address user
    ) external returns (uint16 bps);

    /// @notice Consume a buyback-boost code on behalf of `user`.
    /// @dev Only callable by the configured BuybackPool singleton.
    ///      Reverts under the same conditions as redeemDiscount plus caller-not-pool check.
    /// @param codeId keccak256 hash of the off-chain promo-code string.
    /// @param user  Economic beneficiary (token seller). Used for allowlist and oncePerUser checks.
    /// @return bps  Boosted buyback rate in basis points (9000/9500/9800 = 90/95/98%).
    function redeemBuyback(
        bytes32 codeId,
        address user
    ) external returns (uint16 bps);

    /// @notice Reverse a previously consumed discount code when a pack open yields zero cards
    ///         (all-cards-failed VRF path).
    /// @dev Only callable by the same PackMachine clone that originally redeemed the code
    ///      (validated via factory.isPackMachine + machine binding).
    ///      Decrements redeemedCount and clears the oncePerUser flag for `user`.
    ///      Called wrapped in try/catch in fulfillRandomness — must never revert to avoid
    ///      blocking the USDC refund.
    /// @param codeId keccak256 hash of the off-chain promo-code string.
    /// @param user  The user whose redemption is being reversed.
    function refundDiscount(bytes32 codeId, address user) external;

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Return the full on-chain record for a code.
    function getCode(bytes32 codeId) external view returns (PromoCode memory);

    /// @notice How many redemptions remain before the code is exhausted.
    /// @return Remaining count, or type(uint256).max when uncapped (maxRedemptions == 0).
    function remainingRedemptions(
        bytes32 codeId
    ) external view returns (uint256);

    /// @notice Check whether `user` is currently eligible to redeem `codeId`.
    ///         Mirrors the validator logic but returns false instead of reverting.
    function isEligible(
        bytes32 codeId,
        address user
    ) external view returns (bool);

    /// @notice True if `user` has already redeemed `codeId` (only meaningful when oncePerUser).
    function hasUserRedeemed(
        bytes32 codeId,
        address user
    ) external view returns (bool);

    /// @notice True if `user` is on the allowlist for `codeId`.
    function isAllowlisted(
        bytes32 codeId,
        address user
    ) external view returns (bool);

    /// @notice Compute the discounted price for `user` at the given `price`.
    ///         Returns `price` unchanged if `codeId` is zero, does not exist, or is not a Discount kind.
    ///         Useful for off-chain Permit2 signing: compute the exact amount to sign before calling openPackWithPermit2.
    function previewDiscount(
        bytes32 codeId,
        address user,
        uint256 price
    ) external view returns (uint256 discountedPrice);
}
