// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title INettyWorthMarketplace
/// @notice Interface for the NettyWorth v3 marketplace — fixed-price sales and signature-based auctions
///         for AssetNFT tokens with loan-aware pricing and atomic loan settlement on sale.
interface INettyWorthMarketplace {
    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Off-chain signed fixed-price listing (EIP-712).
    struct SignedListing {
        address seller;
        address collection;    // NFT contract address (must be in allowedCollections)
        uint256 tokenId;
        address paymentToken;  // ERC20 payment token (must be in allowedPaymentTokens)
        uint256 price;         // gross sale price in payment token units
        uint256 nonce;         // per-signer nonce; invalidated on use or cancel
        uint256 expiry;        // unix timestamp; must be > block.timestamp at execution
    }

    /// @notice Off-chain signed auction created by the seller (EIP-712).
    struct SignedAuction {
        address seller;
        address collection;
        uint256 tokenId;
        address paymentToken;
        uint256 reservePrice;       // minimum first-bid amount
        uint256 minIncrement;       // each subsequent bid must beat previous by at least this
        uint256 startTime;          // auction opens; bids before this are rejected
        uint256 endTime;            // initial auction close time
        uint256 extensionWindow;    // if a bid lands within this many seconds of endTime …
        uint256 extensionDuration;  // … endTime is extended by this many seconds
        uint256 nonce;
    }

    /// @notice Off-chain signed bid submitted by a bidder (EIP-712).
    struct SignedBid {
        bytes32 auctionId;  // keccak256 of the EIP-712 hash of the SignedAuction
        address bidder;
        uint256 amount;     // bid amount in the auction's paymentToken
        uint256 nonce;      // per-bidder nonce
        uint256 expiry;     // unix timestamp; bid rejected after this
    }

    /// @notice On-chain auction state materialized when the first valid bid is committed.
    struct AuctionState {
        address seller;
        address collection;
        uint256 tokenId;
        address paymentToken;
        uint256 endTime;            // mutable — extended on last-minute bids
        uint256 extensionWindow;
        uint256 extensionDuration;
        uint256 minIncrement;
        uint256 reservePrice;
        address highestBidder;
        uint256 highestBid;
        bool settled;
        bool exists;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a fixed-price sale or auction settlement completes.
    event SaleExecuted(
        address indexed seller,
        address indexed buyer,
        address indexed collection,
        uint256 tokenId,
        address paymentToken,
        uint256 gross,
        uint256 collectibleFee,
        uint256 royalty,
        uint256 loanRepaid,
        uint256 sellerProceeds
    );

    /// @notice Emitted each time a valid bid is committed to an auction on-chain.
    event BidCommitted(
        bytes32 indexed auctionId,
        address indexed bidder,
        uint256 amount,
        uint256 newEndTime
    );

    /// @notice Emitted when an auction is settled and a winner is declared.
    event AuctionSettled(bytes32 indexed auctionId, address indexed winner, uint256 amount);

    /// @notice Emitted when an auction is cancelled before settlement.
    event AuctionCancelled(bytes32 indexed auctionId, address indexed cancelledBy);

    /// @notice Emitted when a signer invalidates a nonce off-chain.
    event NonceCancelled(address indexed signer, uint256 nonce);

    // Admin config events
    event FeeControllerUpdated(address indexed newController);
    event LendingPoolUpdated(address indexed newPool);
    event TreasuryUpdated(address indexed newTreasury);
    event AllowedCollectionUpdated(address indexed collection, bool allowed);
    event AllowedPaymentTokenUpdated(address indexed token, bool allowed);

    // =========================================================================
    // Errors
    // =========================================================================

    error Marketplace__ZeroAddress();
    error Marketplace__InvalidSignature();
    error Marketplace__NonceUsed(address signer, uint256 nonce);
    error Marketplace__Expired();
    error Marketplace__NotStarted();
    error Marketplace__PriceBelowMinimum(uint256 gross, uint256 required);
    error Marketplace__AuctionNotFound();
    error Marketplace__AuctionEnded();
    error Marketplace__AuctionNotEnded();
    error Marketplace__AuctionAlreadySettled();
    error Marketplace__BidTooLow(uint256 amount, uint256 minRequired);
    error Marketplace__NotSeller();
    error Marketplace__NoBids();
    error Marketplace__CollectionNotAllowed(address collection);
    error Marketplace__PaymentTokenNotAllowed(address token);

    // =========================================================================
    // Core functions
    // =========================================================================

    /// @notice Execute a fixed-price purchase against the seller's off-chain signed listing.
    /// @dev Pulls `listing.price` in paymentToken from msg.sender (buyer). Handles loan auto-repay
    ///      if the token has an active AssetLendingPool loan; delivers NFT to buyer atomically.
    function buyWithSignature(
        SignedListing calldata listing,
        bytes calldata sig
    ) external;

    /// @notice Commit a signed bid to an on-chain auction, enforcing reserve, min-increment,
    ///         and last-minute time extension. No funds are moved at this stage.
    function commitBid(
        SignedAuction calldata auction,
        bytes calldata auctionSig,
        SignedBid calldata bid,
        bytes calldata bidSig
    ) external;

    /// @notice Settle an ended auction: pull funds from the highest bidder, run fee+loan+proceeds
    ///         flow, and deliver the NFT to the winner.
    /// @dev Callable by anyone after endTime, or immediately by MARKETPLACE_ROLE for forced close.
    function settleAuction(bytes32 auctionId) external;

    /// @notice Invalidate a nonce so the corresponding off-chain message can no longer be used.
    function cancelNonce(uint256 nonce) external;

    /// @notice Cancel an on-chain auction record (seller or MARKETPLACE_ROLE; only if unsettled).
    function cancelAuction(bytes32 auctionId) external;

    // =========================================================================
    // Admin functions
    // =========================================================================

    function setFeeController(address feeController_) external;
    function setLendingPool(address lendingPool_) external;
    function setTreasury(address treasury_) external;
    function setAllowedCollection(address collection, bool allowed) external;
    function setAllowedPaymentToken(address token, bool allowed) external;
    function pause() external;
    function unpause() external;

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Returns the on-chain state for a materialized auction.
    function getAuction(bytes32 auctionId) external view returns (AuctionState memory);

    /// @notice Returns true if the given nonce has been used or cancelled by the signer.
    function isNonceUsed(address signer, uint256 nonce) external view returns (bool);

    /// @notice Computes the auctionId for a given SignedAuction (EIP-712 struct hash).
    function hashAuction(SignedAuction calldata auction) external view returns (bytes32);
}
