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
        uint256 outstandingValue; // principal to recover
        uint256 defaultedAt; // timestamp of initiateDefault()
        bool resolved;
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

    event PoolFunded(uint256 amount, uint256 newTotalDeposited);
    event PoolWithdrawn(uint256 amount, uint256 newTotalDeposited);
    event InterestWithdrawn(uint256 amount);
    event AppraisalSet(
        uint256 indexed tokenId,
        uint256 value,
        uint256 grade,
        uint256 category
    );
    event TermConfigUpdated(
        uint8 indexed termId,
        uint256 duration,
        uint256 aprBps,
        bool active
    );
    event EligibilityControlsUpdated(
        uint256 minAppraisalValue,
        uint256 minGrade
    );
    event LtvUpdated(uint256 oldLtv, uint256 newLtv);
    event OriginationFeeUpdated(uint256 bps, address wallet);
    event MaxAppraisalAgeUpdated(uint256 oldMaxAge, uint256 newMaxAge);

    // Lender events
    event LenderDeposited(address indexed lender, uint256 amount);
    event LenderWithdrawn(address indexed lender, uint256 amount);
    event LenderInterestClaimed(address indexed lender, uint256 amount);
    event LenderConfigUpdated(uint256 shareBps, bool enabled);

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
    event DefaultedAssetPurchased(
        uint256 indexed loanId,
        uint256 indexed tokenId,
        address indexed buyer,
        uint256 price
    );
    event DefaultLifecycleConfigUpdated(
        uint256 acquisitionWindow,
        uint256 auctionWindow
    );
    event PackMachineFactoryUpdated(address factory);
    event DefaultPackMachineUpdated(address machine);
    event TokenTierSet(uint256 indexed tokenId, uint8 tier);
    event NFTRescued(uint256 indexed tokenId, address indexed recipient);

    /// @notice Emitted when the authorized marketplace address is updated.
    event MarketplaceUpdated(address indexed marketplace);

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

    function setAppraisal(
        uint256 tokenId,
        uint256 value,
        uint256 grade,
        uint256 category
    ) external;

    function batchSetAppraisals(
        uint256[] calldata tokenIds,
        uint256[] calldata values,
        uint256[] calldata grades,
        uint256[] calldata categories
    ) external;

    function setTermConfig(
        uint8 termId,
        uint256 duration,
        uint256 aprBps,
        bool active
    ) external;

    function setEligibilityControls(
        uint256 minAppraisalValue,
        uint256 minGrade,
        uint256[] calldata addCategories,
        uint256[] calldata removeCategories
    ) external;

    function setLtvBps(uint256 newLtv) external;

    function setOriginationFee(uint256 bps, address wallet) external;

    function setMaxAppraisalAge(uint256 newMaxAge) external;

    function setLenderConfig(uint256 shareBps, bool enabled) external;

    function setDefaultLifecycleConfig(
        uint256 acquisitionWindow_,
        uint256 auctionWindow_
    ) external;

    function setPackMachineFactory(address factory_) external;

    function setDefaultPackMachine(address machine_) external;

    function setTokenTier(uint256 tokenId, uint8 tier) external;

    function batchSetTokenTiers(
        uint256[] calldata tokenIds,
        uint8[] calldata tiers
    ) external;

    /// @notice Initiate the default lifecycle for an expired loan.
    function initiateDefault(uint256 loanId) external;

    /// @notice Backward-compatible alias for initiateDefault.
    function liquidate(uint256 loanId) external;

    /// @notice NettyWorth acquires defaulted asset within the acquisition window and recycles it into packs.
    function acquireDefaultedAsset(
        uint256 loanId,
        address targetPackMachine,
        uint8 tier
    ) external;

    // =========================================================================
    // Public default lifecycle functions
    // =========================================================================

    /// @notice Purchase a defaulted asset at the outstanding loan value (Phase 2 or 3).
    function purchaseDefaultedAsset(uint256 loanId) external;

    // =========================================================================
    // View functions
    // =========================================================================

    function getLoan(uint256 loanId) external view returns (Loan memory);

    /// @notice Returns just the collateral token IDs for a loan.
    function getLoanTokenIds(uint256 loanId) external view returns (uint256[] memory);

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

    /// @notice Set the authorized marketplace address allowed to call settleLoanRepaymentOnSale.
    /// @dev onlyOwner. Pass the marketplace proxy address after deployment.
    function setMarketplace(address marketplace_) external;

    /// @notice Returns the currently authorized marketplace address (0 if not set).
    function getMarketplace() external view returns (address);

    /// @notice Atomically repay a loan from sale proceeds and release the collateral to the buyer.
    /// @dev Only callable by the authorized marketplace. Mirrors repay() accounting but pulls funds
    ///      from `payer` (the marketplace) and delivers NFT(s) to `buyer` instead of the borrower.
    ///      Reverts if the loan is not active, not found, or the pool is paused.
    /// @param loanId Loan to settle.
    /// @param payer  Address from which principal+interest is pulled (the marketplace contract).
    /// @param buyer  Address that receives the released collateral NFT(s).
    function settleLoanRepaymentOnSale(uint256 loanId, address payer, address buyer) external;

    /// @notice Active loan ID for a given token (0 if no active loan).
    function getActiveLoanId(uint256 tokenId) external view returns (uint256);

    /// @notice Debt components for the active loan collateralized by `tokenId`.
    /// @return principal Loan principal.
    /// @return interest  Fixed upfront interest (pre-calculated at origination).
    /// @return total     principal + interest (amount required to settle).
    ///                   Returns (0, 0, 0) if the token has no active loan.
    function getLoanDebt(
        uint256 tokenId
    ) external view returns (uint256 principal, uint256 interest, uint256 total);
}
