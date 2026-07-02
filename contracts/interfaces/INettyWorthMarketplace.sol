// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title INettyWorthMarketplace
/// @notice Interface for the NettyWorth v3 marketplace — fixed-price sales and signature-based auctions
///         for AssetNFT tokens with loan-aware pricing and atomic loan settlement on sale.
interface INettyWorthMarketplace {
    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Off-chain signed buy offer submitted by the buyer (EIP-712).
    ///         The buyer pre-approves the marketplace for `price` of `paymentToken`;
    ///         the token owner (or loan borrower) calls acceptOffer to execute.
    struct SignedOffer {
        address buyer;
        address collection; // NFT contract address (must be in allowedCollections)
        uint256 tokenId;
        address paymentToken; // ERC20 payment token (must be in allowedPaymentTokens)
        uint256 price; // gross offer amount in payment token units
        uint256 nonce; // per-signer nonce; invalidated on use or cancel
        uint256 expiry; // unix timestamp; must be > block.timestamp at acceptance
    }

    /// @notice Off-chain signed fixed-price listing (EIP-712).
    struct SignedListing {
        address seller;
        address collection; // NFT contract address (must be in allowedCollections)
        uint256 tokenId;
        address paymentToken; // ERC20 payment token (must be in allowedPaymentTokens)
        uint256 price; // gross sale price in payment token units
        uint256 nonce; // per-signer nonce; invalidated on use or cancel
        uint256 expiry; // unix timestamp; must be > block.timestamp at execution
        address buyer; // address(0) = open listing (anyone can fill); non-zero = private sale (H004 fix)
    }

    /// @notice Off-chain signed auction created by the seller (EIP-712).
    struct SignedAuction {
        address seller;
        address collection;
        uint256 tokenId;
        address paymentToken;
        uint256 reservePrice; // minimum first-bid amount
        uint256 minIncrement; // each subsequent bid must beat previous by at least this
        uint256 startTime; // auction opens; bids before this are rejected
        uint256 endTime; // initial auction close time
        uint256 extensionWindow; // if a bid lands within this many seconds of endTime …
        uint256 extensionDuration; // … endTime is extended by this many seconds
        uint256 nonce;
    }

    /// @notice Off-chain signed bid submitted by a bidder (EIP-712).
    struct SignedBid {
        bytes32 auctionId; // keccak256 of the EIP-712 hash of the SignedAuction
        address bidder;
        uint256 amount; // bid amount in the auction's paymentToken
        uint256 nonce; // per-bidder nonce
        uint256 expiry; // unix timestamp; bid rejected after this
    }

    /// @notice On-chain auction state materialized when the first valid bid is committed.
    struct AuctionState {
        address seller;
        address collection;
        uint256 tokenId;
        address paymentToken;
        uint256 endTime; // mutable — extended on last-minute bids
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

    /// @notice Emitted when a seller accepts a buyer's off-chain offer.
    ///         SaleExecuted is also emitted by _executeSale with full fee breakdown.
    event OfferAccepted(
        address indexed buyer,
        address indexed seller,
        address indexed collection,
        uint256 tokenId,
        address paymentToken,
        uint256 price
    );

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
    event AuctionSettled(
        bytes32 indexed auctionId,
        address indexed winner,
        uint256 amount
    );

    /// @notice Emitted when an auction is cancelled before settlement.
    event AuctionCancelled(
        bytes32 indexed auctionId,
        address indexed cancelledBy
    );

    /// @notice Emitted on every push-based purchase (Coinflow onramp path).
    ///         SaleExecuted is also emitted with the full fee breakdown for the same sale;
    ///         this marker event allows indexers to distinguish onramp sales without parsing calldata.
    event PushedSaleSettled(
        address indexed seller,
        address indexed recipient,
        uint256 indexed tokenId,
        uint256 gross
    );

    /// @notice Emitted when a signer invalidates a nonce off-chain.
    event NonceCancelled(address indexed signer, uint256 nonce);

    // Admin config events
    event FeeControllerUpdated(address indexed newController);
    event LendingPoolUpdated(address indexed newPool);
    event TreasuryUpdated(address indexed newTreasury);
    event AllowedCollectionUpdated(address indexed collection, bool allowed);
    event AllowedPaymentTokenUpdated(address indexed token, bool allowed);

    /// @notice Emitted when a pool-owned defaulted asset is listed for auction via listDefaultedAsset.
    event DefaultedAssetListed(
        uint256 indexed loanId,
        uint256 indexed tokenId,
        bytes32 indexed auctionId,
        uint256 reservePrice,
        uint256 endTime
    );

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
    error Marketplace__ReserveBelowOutstanding(
        uint256 reservePrice,
        uint256 outstanding
    );
    error Marketplace__NotPoolDefaultAuction();
    error Marketplace__PoolDefaultSingleTokenOnly();
    /// @notice Thrown when a caller tries to accept an offer on a collateralised token they do not own as borrower.
    error Marketplace__NotTokenOwner();
    /// @notice Thrown when listing.seller != loan.borrower in the loan-settlement branch (C004 fix).
    error Marketplace__SellerNotBorrower(address seller, address borrower);
    /// @notice Thrown when a single-token sale is attempted on a multi-NFT bundle loan (H003 fix).
    error Marketplace__CannotPartiallySettleBundleLoan(uint256 loanId);
    /// @notice Thrown when listing.buyer is set and recipient is not that buyer (H004 fix).
    error Marketplace__NotIntendedBuyer(address intended, address actual);
    /// @notice Thrown when _executeSale receives less than gross after a safeTransferFrom (M005 fix).
    error Marketplace__InsufficientReceived(uint256 expected, uint256 actual);
    /// @notice Thrown when buyWithSignatureFor is called with a zero recipient address.
    error Marketplace__ZeroRecipient();
    /// @notice Thrown when a non-admin seller tries to cancel an auction that already has a committed bid (M007 fix).
    error Marketplace__CannotCancelWithActiveBid(address currentBidder);
    /// @notice Thrown when buyWithSignaturePushed is called but the contract balance is less than listing.price.
    ///         Indicates Coinflow's settlement transfer did not arrive before the call (or was insufficient).
    error Marketplace__InsufficientPushedBalance(
        uint256 expected,
        uint256 actual
    );

    // =========================================================================
    // Core functions
    // =========================================================================

    /// @notice Seller accepts a buyer's off-chain signed offer (EIP-712 SignedOffer).
    /// @dev Caller must be the token owner (or the loan borrower if collateralised).
    ///      Pulls offer.price in paymentToken from offer.buyer (who must have pre-approved the
    ///      marketplace). Handles loan auto-repay if the token has an active AssetLendingPool loan;
    ///      delivers NFT to buyer atomically. Fees, royalties, and loan settlement follow the same
    ///      path as buyWithSignature.
    function acceptOffer(
        SignedOffer calldata offer,
        bytes calldata sig
    ) external;

    /// @notice Execute a fixed-price purchase against the seller's off-chain signed listing.
    /// @dev Pulls `listing.price` in paymentToken from msg.sender (buyer). Handles loan auto-repay
    ///      if the token has an active AssetLendingPool loan; delivers NFT to msg.sender atomically.
    ///      Equivalent to buyWithSignatureFor(listing, sig, msg.sender).
    function buyWithSignature(
        SignedListing calldata listing,
        bytes calldata sig
    ) external;

    /// @notice Execute a fixed-price purchase, delivering the NFT to a specified recipient.
    /// @dev Pulls `listing.price` in paymentToken from msg.sender (payer). Delivers the NFT to
    ///      `recipient` — enabling platform contracts to buy on behalf of their end users in a
    ///      single transaction. Handles loan auto-repay if the token has an active AssetLendingPool
    ///      loan; NFT is released directly to `recipient` by the pool.
    ///      For a private listing (listing.buyer != address(0)), `recipient` must equal
    ///      `listing.buyer` — the seller targets who ultimately receives the NFT (H004 fix).
    /// @param listing   Seller's EIP-712 signed fixed-price listing.
    /// @param sig       Seller's signature over `listing`.
    /// @param recipient Address that will receive the NFT (must not be address(0)).
    function buyWithSignatureFor(
        SignedListing calldata listing,
        bytes calldata sig,
        address recipient
    ) external;

    /// @notice Coinflow onramp entry point: execute a fixed-price purchase where USDC has already
    ///         been transferred to this contract by Coinflow's settlement contract in the same
    ///         atomic transaction ("transfer-then-call" / push model).
    ///
    /// @dev Unlike buyWithSignature/buyWithSignatureFor (pull model), this function does NOT call
    ///      transferFrom — it verifies that `listing.price` of `listing.paymentToken` is already
    ///      present in the contract's balance before distributing fees, royalties, loan repayment,
    ///      and seller proceeds. Exactly `listing.price` is distributed; any surplus balance is
    ///      intentionally left in the contract.
    ///
    ///      SECURITY: Callable ONLY by an address holding COINFLOW_SETTLER_ROLE. This gate is
    ///      critical because the function consumes the contract's existing balance — an ungated
    ///      push entry point would allow any caller with a valid seller-signed listing to drain
    ///      residual USDC. Unauthorized calls revert with PermissionConsumer__Unauthorized.
    ///
    ///      Seller EIP-712 signature validation, nonce replay protection, expiry, collection
    ///      and payment-token allowlisting, and private-listing buyer enforcement are all
    ///      identical to buyWithSignature/buyWithSignatureFor.
    ///
    ///      Emits both SaleExecuted (full fee breakdown) and PushedSaleSettled (onramp marker).
    ///
    /// @param listing   Seller's EIP-712 signed fixed-price listing.
    /// @param sig       Seller's signature over `listing`.
    /// @param recipient End-user wallet that receives the NFT. Coinflow passes the buyer's
    ///                  wallet here. Must not be address(0). For a private listing
    ///                  (listing.buyer != address(0)), `recipient` must equal `listing.buyer`.
    function buyWithSignaturePushed(
        SignedListing calldata listing,
        bytes calldata sig,
        address recipient
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
    // Pool-default auction functions
    // =========================================================================

    /// @notice List a pool-owned defaulted asset as an on-chain auction without a seller signature.
    ///         Only callable by MARKETPLACE_ROLE. The lending pool is the implicit seller.
    ///         Fees and royalties are waived; proceeds go to the pool in full.
    ///         Restricted to single-token loans in v1 (bundle support is a future extension).
    /// @param loanId            Loan ID whose defaulted collateral to auction.
    /// @param tokenId           The single collateral token ID to auction.
    /// @param reservePrice      Minimum winning bid — must be >= principal + interest.
    /// @param minIncrement      Each subsequent bid must exceed the current highest by at least this.
    /// @param startTime         Unix timestamp when bidding opens.
    /// @param endTime           Initial auction close time.
    /// @param extensionWindow   Seconds before endTime within which a bid triggers an extension.
    /// @param extensionDuration Seconds added to endTime on a last-minute bid.
    function listDefaultedAsset(
        uint256 loanId,
        uint256 tokenId,
        uint256 reservePrice,
        uint256 minIncrement,
        uint256 startTime,
        uint256 endTime,
        uint256 extensionWindow,
        uint256 extensionDuration
    ) external;

    /// @notice Submit a bid on a pool-default auction (pre-materialized by listDefaultedAsset).
    ///         Only the bidder's signature is required — no seller signature.
    ///         First bid must meet reservePrice; subsequent bids must beat highestBid + minIncrement.
    ///         No funds move at this point; funds are pulled at settleAuction.
    function commitPoolBid(
        bytes32 auctionId,
        SignedBid calldata bid,
        bytes calldata bidSig
    ) external;

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
    function getAuction(
        bytes32 auctionId
    ) external view returns (AuctionState memory);

    /// @notice Returns true if the given nonce has been used or cancelled by the signer.
    function isNonceUsed(
        address signer,
        uint256 nonce
    ) external view returns (bool);

    /// @notice Computes the auctionId for a given SignedAuction (EIP-712 struct hash).
    function hashAuction(
        SignedAuction calldata auction
    ) external view returns (bytes32);
}
