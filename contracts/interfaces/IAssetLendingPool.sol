// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {INettyWorthMarketplace} from "./INettyWorthMarketplace.sol";

/// @title IAssetLendingPool
/// @notice Interface for the NettyWorth-operated AssetNFT-backed lending pool.
interface IAssetLendingPool {
    // =========================================================================
    // Enums
    // =========================================================================

    enum DefaultPhase {
        None, // not defaulted
        Acquisition, // NettyWorth 24h acquisition window
        Auction, // marketplace auction window
        FixedListing, // perpetual fixed-price listing
        Resolved // sold or recycled
    }

    // =========================================================================
    // Structs
    // =========================================================================

    struct TermConfig {
        uint256 duration; // seconds
        uint256 aprBps; // annual rate in basis points, e.g. 1000 = 10% APR
        bool active;
    }

    struct Loan {
        uint256 loanId;
        address borrower;
        uint256[] tokenIds; // collateral token IDs (one for single-asset loans, many for bundles)
        uint256 principal;
        uint256 interest; // pre-calculated at origination
        uint256 startTime;
        uint256 expireTime;
        uint8 termId;
        bool isPaid;
        bool isDefaulted;
        bool isMarketplaceFinanced;
        // ---- appended fields (append-only for upgrade safety) ----
        /// @dev lenderShareBps captured at origination so mid-loan admin changes don't
        ///      retroactively reprice in-flight interest (M003 fix).
        uint256 lenderShareBpsSnapshot;
        /// @dev totalLenderDeposits captured at origination so JIT deposit sandwiches
        ///      cannot dilute honest lenders' share of a specific loan's interest (H001 fix).
        uint256 lenderDepositsSnapshot;
        /// @dev originationFeeBps captured at origination so an admin cannot
        ///      front-run an in-flight borrow by raising the fee after collateral is locked.
        ///      The fee is computed and collected from this snapshot rather than live config.
        uint256 originationFeeBpsSnapshot;
    }

    struct AssetAppraisal {
        uint256 value; // payment token units
        uint256 grade; // numeric PSA/SGC grade
        uint256 category; // category ID
        uint256 updatedAt;
    }

    struct DefaultRecord {
        uint256 loanId;
        uint256[] tokenIds; // collateral token IDs at the time of default
        uint256 outstandingValue; // principal to recover (interest is tracked separately via interestValue)
        uint256 defaultedAt; // timestamp of initiateDefault()
        bool resolved;
        // ---- appended fields (append-only for upgrade safety) ----
        /// @dev Snapshot of loan.interest taken at default time. Used by _resolveAndRecredit to
        ///      distribute interest to lenders/protocol on successful recovery.
        uint256 interestValue;
        /// @dev Set true by prepareDefaultedListing once the marketplace auction is live.
        ///      Prevents double-listing; reset by onDefaultedListingCancelled to allow relist.
        bool listedOnMarketplace;
        /// @dev acquisition and auction window durations captured at the time
        ///      initiateDefault() is called. Phase evaluation in getDefaultPhase(),
        ///      acquireDefaultedAsset(), and prepareDefaultedListing() uses these snapshots
        ///      instead of live config values, so admin changes to setDefaultLifecycleConfig
        ///      only affect future defaults — not defaults already in progress.
        uint256 acquisitionWindow;
        uint256 auctionWindow;
    }

    struct LenderInfo {
        uint256 deposited;
        uint256 claimableInterest;
        uint256 poolShareBps;
    }

    struct PoolInfo {
        address paymentToken;
        address assetNFT;
        uint8 termCount;
        uint256 nextLoanId;
        uint256 minAppraisalValue;
        uint256 minGrade;
        uint256 totalDeposited;
        uint256 totalBorrowed;
        uint256 totalInterestEarned;
        uint256 interestWithdrawn;
        uint256 activeLoanCount;
        uint256 originationFeeBps;
        address feeWallet;
        uint256 ltvBps;
        uint256 maxAppraisalAge;
        uint256 totalLenderDeposits;
        uint256 ownerDeposited;
        uint256 lenderShareBps;
        bool lenderDepositsEnabled;
        uint256 acquisitionWindow;
        uint256 auctionWindow;
        uint256 totalDefaultedPrincipal;
        uint256 maxUtilizationBps; // e.g. 8000 = 80% cap; 10000 = no reserve
    }

    // =========================================================================
    // Events
    // =========================================================================

    event LoanOriginated(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 indexed tokenId, // tokenIds[0] for convenience; use BundleLoanOriginated for the full list
        uint256 principal,
        uint256 interest,
        uint8 termId,
        uint256 expireTime
    );

    /// @notice Emitted for every loan (single-asset and bundle) with the complete token list.
    event BundleLoanOriginated(
        uint256 indexed loanId,
        address indexed borrower,
        uint256[] tokenIds,
        uint256 principal,
        uint256 interest,
        uint8 termId,
        uint256 expireTime
    );

    event LoanRepaid(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 principal,
        uint256 interest
    );

    event LoanDefaulted(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 indexed tokenId
    );

    event MarketplacePurchaseFinanced(
        uint256 indexed loanId,
        address indexed buyer,
        uint256 indexed tokenId,
        uint256 depositAmount,
        uint256 loanAmount
    );

    /// @notice Emitted when a seller revokes an unused marketplace-finance nonce (H010 fix).
    event FinanceNonceCancelled(address indexed seller, uint256 indexed nonce);

    event PoolFunded(uint256 amount, uint256 newTotalDeposited);
    event PoolWithdrawn(uint256 amount, uint256 newTotalDeposited);
    event InterestWithdrawn(uint256 amount);
    // Note: config-domain events (AppraisalSet, TermConfigUpdated, EligibilityControlsUpdated,
    // LtvUpdated, MaxUtilizationUpdated, OriginationFeeUpdated, MaxAppraisalAgeUpdated,
    // LenderConfigUpdated, DefaultLifecycleConfigUpdated, FinanceWalletUpdated,
    // PackMachineFactoryUpdated, DefaultPackMachineUpdated, TokenTierSet, MarketplaceUpdated)
    // are defined in IAssetLendingPoolConfig — they are emitted by the config contract.

    // Lender events
    event LenderDeposited(address indexed lender, uint256 amount);
    event LenderWithdrawn(address indexed lender, uint256 amount);
    event LenderInterestClaimed(address indexed lender, uint256 amount);

    // Default lifecycle events
    event DefaultInitiated(
        uint256 indexed loanId,
        uint256 indexed tokenId,
        uint256 outstandingValue
    );
    event DefaultedAssetAcquired(
        uint256 indexed loanId,
        uint256 indexed tokenId,
        address packMachine
    );
    /// @notice Emitted when a pool-default auction settlement resolves the default record.
    event DefaultedAssetSold(
        uint256 indexed loanId,
        uint256 indexed tokenId,
        uint256 proceeds,
        uint256 principal,
        uint256 interest,
        uint256 surplus
    );
    /// @notice Emitted when a defaulted asset is purchased via the old flat on-pool path (now deprecated).
    event DefaultedAssetPurchased(
        uint256 indexed loanId,
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 price
    );
    event NFTRescued(uint256 indexed tokenId, address indexed recipient);

    /// @notice Emitted when a loan is settled atomically as part of a marketplace sale.
    event LoanSettledOnSale(
        uint256 indexed loanId,
        address indexed borrower,
        address indexed buyer,
        uint256 totalRepaid
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error AssetLendingPool__EmptyBundle();
    error AssetLendingPool__InvalidTerm();
    error AssetLendingPool__IneligibleAsset();
    error AssetLendingPool__ExceedsLTV();
    error AssetLendingPool__InsufficientLiquidity();
    error AssetLendingPool__ExceedsMaxUtilization();
    error AssetLendingPool__ActiveLoanExists();
    error AssetLendingPool__LoanNotFound();
    error AssetLendingPool__LoanAlreadyPaid();
    error AssetLendingPool__LoanAlreadyDefaulted();
    error AssetLendingPool__LoanNotExpired();
    error AssetLendingPool__LoanNotDefaulted();
    error AssetLendingPool__InsufficientDeposit();
    error AssetLendingPool__ZeroAddress();
    error AssetLendingPool__ZeroAmount();
    error AssetLendingPool__NoAppraisal();
    error AssetLendingPool__WithdrawExceedsAvailable();
    error AssetLendingPool__InvalidLTV();
    error AssetLendingPool__InvalidBps();
    error AssetLendingPool__BatchTooLarge(uint256 size, uint256 maxSize);
    error AssetLendingPool__ArrayLengthMismatch();
    error AssetLendingPool__NotBorrower();
    error AssetLendingPool__NFTNotInPool();
    error AssetLendingPool__AppraisalStale(
        uint256 tokenId,
        uint256 updatedAt,
        uint256 maxAge
    );
    error AssetLendingPool__LenderDepositsDisabled();
    error AssetLendingPool__InsufficientLenderBalance();
    error AssetLendingPool__NoInterestToClaim();
    error AssetLendingPool__DefaultNotFound();
    error AssetLendingPool__DefaultAlreadyResolved();
    error AssetLendingPool__NotInAcquisitionPhase();
    error AssetLendingPool__NotInPurchasePhase();
    error AssetLendingPool__InvalidPackMachine();
    error AssetLendingPool__OwnerWithdrawExceedsOwnerDeposits();
    error AssetLendingPool__NotMarketplace();
    error AssetLendingPool__InvalidSignature();
    error AssetLendingPool__ListingExpired();
    error AssetLendingPool__ListingNonceUsed();
    error AssetLendingPool__ListingCollectionMismatch();
    error AssetLendingPool__ListingPaymentTokenMismatch();
    error AssetLendingPool__DefaultNotListed();
    error AssetLendingPool__AlreadyListed();
    error AssetLendingPool__InsufficientProceeds();
    error AssetLendingPool__FinanceWalletNotSet();
    /// @dev Thrown when purchaseDefaultedAsset is called (deprecated; use marketplace auction path).
    error AssetLendingPool__Deprecated();
    /// @dev Thrown by financeMarketplacePurchase when seller == address(this) (M009 fix).
    error AssetLendingPool__InvalidSeller();
    /// @dev Thrown by financeMarketplacePurchase when listing.buyer is set and != msg.sender (H009 fix).
    error AssetLendingPool__NotIntendedBuyer();

    // =========================================================================
    // Borrower functions
    // =========================================================================

    function borrow(uint256 tokenId, uint256 amount, uint8 termId) external;

    /// @notice Collateralize multiple AssetNFTs as a bundle and borrow against their summed appraisal value.
    /// @param tokenIds AssetNFT token IDs to use as collateral (max 50, each must be individually eligible).
    /// @param amount Loan principal requested (must be <= LTV of summed appraisal values).
    /// @param termId Term configuration index.
    function borrowBundle(
        uint256[] calldata tokenIds,
        uint256 amount,
        uint8 termId
    ) external;

    /// @notice Atomically purchase a marketplace-listed AssetNFT with partial deposit,
    ///         financing the remainder as a collateralized loan from this pool.
    ///
    ///         Price is taken from the seller's EIP-712 signed listing (verified on-chain
    ///         against the marketplace domain). The pool pays the seller the full listing
    ///         price (buyer deposit + pool loan). Loan exposure is capped at LTV × appraisalValue
    ///         so the pool never lends more than the collateral is worth.
    ///
    /// @param listing  The seller's signed listing struct (collection, tokenId, price, nonce, expiry).
    /// @param sig      EIP-712 signature over `listing` produced by `listing.seller`.
    /// @param depositAmount Buyer's upfront payment in payment-token units.
    ///                 Must satisfy: depositAmount >= listing.price - (appraisalValue * ltvBps / BPS).
    /// @param termId   Loan term index (must be active).
    function financeMarketplacePurchase(
        INettyWorthMarketplace.SignedListing calldata listing,
        bytes calldata sig,
        uint256 depositAmount,
        uint8 termId
    ) external;

    /// @notice Seller-side revocation of a marketplace-finance listing nonce (H010 fix).
    ///         Mirrors NettyWorthMarketplace.cancelNonce but for the pool's independent
    ///         financeNonces namespace. A leaked open-listing signature must be cancelled
    ///         at BOTH contracts to be fully dead; this closes the pool-side gap.
    ///         Reverts AssetLendingPool__ListingNonceUsed if nonce is already consumed or
    ///         previously cancelled. No role gate — self-service only (msg.sender = seller).
    ///         Intentionally omits whenNotPaused so revocation remains available while paused.
    function cancelFinanceNonce(uint256 nonce) external;

    /// @notice Returns true if a seller's finance nonce has been consumed (by a successful
    ///         financeMarketplacePurchase) or cancelled (by cancelFinanceNonce).
    function isFinanceNonceUsed(address seller, uint256 nonce)
        external
        view
        returns (bool);

    function repay(uint256 loanId) external;

    // =========================================================================
    // Lender functions
    // =========================================================================

    function lenderDeposit(uint256 amount) external;

    function lenderWithdraw(uint256 amount) external;

    function claimLenderInterest() external;

    function getLenderInfo(
        address lender
    ) external view returns (LenderInfo memory);

    // =========================================================================
    // Admin functions
    // =========================================================================

    function deposit(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function withdrawInterest(uint256 amount) external;

    // Note: all config setters (setAppraisal, batchSetAppraisals, setTermConfig,
    // setEligibilityControls, setLtvBps, setMaxUtilizationBps, setOriginationFee,
    // setMaxAppraisalAge, setLenderConfig, setDefaultLifecycleConfig, setPackMachineFactory,
    // setDefaultPackMachine, setTokenTier, batchSetTokenTiers, setFinanceWallet, setMarketplace)
    // are declared in IAssetLendingPoolConfig and must be called on the config contract.

    /// @notice Initiate the default lifecycle for an expired loan.
    function initiateDefault(uint256 loanId) external;

    /// @notice Backward-compatible alias for initiateDefault.
    function liquidate(uint256 loanId) external;

    /// @notice NettyWorth acquires defaulted asset within the acquisition window and recycles it into packs.
    ///         The financeWallet must have pre-approved the pool for principal + interest in paymentToken.
    function acquireDefaultedAsset(
        uint256 loanId,
        address targetPackMachine,
        uint8 tier
    ) external;

    // =========================================================================
    // Marketplace callbacks (onlyMarketplace)
    // =========================================================================

    /// @notice Called by the marketplace before listing a defaulted asset for auction.
    ///         Validates the phase, marks the record as listed, and approves the marketplace
    ///         to transfer each collateral token (NFTs are in Held state after default).
    ///         Restricted to single-token loans; bundle auctions are a future extension.
    /// @param loanId Loan ID whose default record should be prepared for listing.
    /// @return tokenIds The collateral token IDs approved for marketplace transfer.
    function prepareDefaultedListing(
        uint256 loanId
    ) external returns (uint256[] memory tokenIds);

    /// @notice Called by the marketplace after a pool-default auction settles.
    ///         Resolves the default record, re-credits principal, distributes interest,
    ///         and books any surplus to protocol earnings.
    ///         Proceeds must already have been transferred to this contract by the marketplace.
    /// @param loanId   The loan ID of the resolved default.
    /// @param proceeds USDC amount the pool received (= winning bid, fees waived for pool sales).
    function onDefaultedAssetSold(uint256 loanId, uint256 proceeds) external;

    /// @notice Called by the marketplace when a pool-default auction is cancelled (e.g. unsold).
    ///         Resets listedOnMarketplace so the operator can relist.
    /// @param loanId The loan ID whose listing is being cancelled.
    function onDefaultedListingCancelled(uint256 loanId) external;

    /// @notice Returns the currently configured finance wallet address.
    ///         Passthrough to the config contract.
    function getFinanceWallet() external view returns (address);

    // =========================================================================
    // View functions
    // =========================================================================

    function getLoan(uint256 loanId) external view returns (Loan memory);

    /// @notice Returns just the collateral token IDs for a loan.
    function getLoanTokenIds(
        uint256 loanId
    ) external view returns (uint256[] memory);

    function getBorrowerLoans(
        address borrower
    ) external view returns (uint256[] memory);

    function getAppraisal(
        uint256 tokenId
    ) external view returns (AssetAppraisal memory);

    function getTermConfig(
        uint8 termId
    ) external view returns (TermConfig memory);

    function getAvailableLiquidity() external view returns (uint256);

    function getMaxLoanAmount(uint256 tokenId) external view returns (uint256);

    function isEligible(uint256 tokenId) external view returns (bool);

    function getPoolInfo() external view returns (PoolInfo memory);

    function getDefaultPhase(
        uint256 loanId
    ) external view returns (DefaultPhase);

    function getDefaultRecord(
        uint256 loanId
    ) external view returns (DefaultRecord memory);

    // =========================================================================
    // Marketplace integration
    // =========================================================================

    /// @notice Returns the currently authorized marketplace address (0 if not set).
    ///         Passthrough to the config contract.
    function getMarketplace() external view returns (address);

    /// @notice Atomically repay a loan from sale proceeds and release the collateral to the buyer.
    /// @dev Only callable by the authorized marketplace. Mirrors repay() accounting but pulls funds
    ///      from `payer` (the marketplace) and delivers NFT(s) to `buyer` instead of the borrower.
    ///      Reverts if the loan is not active, not found, or the pool is paused.
    /// @param loanId Loan to settle.
    /// @param payer  Address from which principal+interest is pulled (the marketplace contract).
    /// @param buyer  Address that receives the released collateral NFT(s).
    function settleLoanRepaymentOnSale(
        uint256 loanId,
        address payer,
        address buyer
    ) external;

    /// @notice Active loan ID for a given token (0 if no active loan).
    function getActiveLoanId(uint256 tokenId) external view returns (uint256);

    /// @notice Returns the borrower address for a given loan (address(0) if not found).
    ///         Used by the marketplace to enforce seller == borrower on collateralized sales (C004 fix).
    function getLoanBorrower(uint256 loanId) external view returns (address);

    /// @notice Returns the number of collateral tokens in a loan.
    ///         Used by the marketplace to reject single-token sales of multi-NFT bundle loans (H003 fix).
    function getLoanCollateralCount(
        uint256 loanId
    ) external view returns (uint256);

    /// @notice Returns the AssetNFT contract address used by this pool.
    ///         Used by the marketplace to guard loan lookups to the correct collection (H005 fix).
    function getAssetNFT() external view returns (address);

    /// @notice Debt components for the active loan collateralized by `tokenId`.
    /// @return principal Loan principal.
    /// @return interest  Fixed upfront interest (pre-calculated at origination).
    /// @return total     principal + interest (amount required to settle).
    ///                   Returns (0, 0, 0) if the token has no active loan.
    function getLoanDebt(
        uint256 tokenId
    )
        external
        view
        returns (uint256 principal, uint256 interest, uint256 total);
}
