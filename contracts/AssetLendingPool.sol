// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAssetNFT} from "./interfaces/IAssetNFT.sol";
import {IAssetLendingPool} from "./interfaces/IAssetLendingPool.sol";
import {IAssetLendingPoolConfig} from "./interfaces/IAssetLendingPoolConfig.sol";
import {INettyWorthMarketplace} from "./interfaces/INettyWorthMarketplace.sol";
import {IPackMachine} from "./interfaces/IPackMachine.sol";
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";

/// @title AssetLendingPool
/// @author NettyWorth
/// @notice Platform-operated lending pool that accepts AssetNFT tokens as collateral.
///         Funded by platform treasury and external lenders. Fixed loan terms with upfront interest.
///         Includes a marketplace financing path for atomic purchase+loan origination.
///         Defaulted assets follow a 3-phase lifecycle: NettyWorth acquisition window
///         (default 24h, configurable), then a public marketplace auction window (default 7 days,
///         configurable), then a perpetual fixed-price listing.
/// @dev UUPS upgradeable. Uses ERC-7201 namespaced runtime storage.
///      All admin configuration lives in the separate AssetLendingPoolConfig contract.
///      Access control via Ownable2StepUpgradeable (single admin). The pool contract address must
///      be granted STATE_MANAGER_ROLE on PermissionManager so it can call
///      assetNFT.batchSetAssetState() to transition tokens between Held and Loaned.
/// @custom:security-contact security@nettyworth.io
contract AssetLendingPool is
    IAssetLendingPool,
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 private constant YEAR = 365 days;
    /// @dev Scaling factor for reward-per-share accumulator to preserve precision.
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_BATCH = 50;

    // =========================================================================
    // Storage (ERC-7201 namespaced) — runtime state only; config lives in
    // the separate AssetLendingPoolConfig contract
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.AssetLendingPoolRuntime
    struct PoolStorage {
        // Reference to the config contract
        IAssetLendingPoolConfig config;
        // Cached token references (set once at initialize from config; immutable thereafter)
        IERC20 paymentToken;
        IAssetNFT assetNFT;
        // Loans
        uint256 nextLoanId;
        mapping(uint256 loanId => Loan) loans;
        mapping(address borrower => uint256[]) borrowerLoans;
        mapping(uint256 tokenId => uint256 loanId) tokenIdToActiveLoan;
        // Pool financial (protocol/owner capital)
        uint256 totalDeposited;
        uint256 totalBorrowed;
        uint256 totalInterestEarned; // protocol-only interest (excludes lender share)
        uint256 interestWithdrawn;
        uint256 activeLoanCount;
        // =====================================================================
        // External Lender Capital
        // =====================================================================
        mapping(address lender => uint256) lenderDeposits;
        uint256 totalLenderDeposits;
        uint256 ownerDeposited; // tracks admin's own capital separately from lender capital
        // Reward-per-share accounting (Synthetix pattern, scaled by PRECISION)
        uint256 accInterestPerShare;
        mapping(address lender => uint256) lenderRewardDebt;
        uint256 totalLenderInterestPaid;
        // =====================================================================
        // Default Lifecycle
        // =====================================================================
        mapping(uint256 loanId => DefaultRecord) defaults;
        uint256 totalDefaultedPrincipal;
        // =====================================================================
        // Marketplace financing replay protection
        // =====================================================================
        mapping(address seller => mapping(uint256 nonce => bool)) financeNonces;
        // =====================================================================
        // borrowerLoans O(1) removal support (M002 fix)
        // =====================================================================
        /// @dev Tracks the index of each loanId within borrowerLoans[borrower] for O(1)
        ///      swap-and-pop removal when a loan is closed (repaid or defaulted).
        mapping(uint256 loanId => uint256 index) borrowerLoanIndex;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.AssetLendingPoolRuntime")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASSET_LENDING_POOL_RUNTIME_STORAGE_SLOT =
        0xe550184268bc9f659edbb9c6b24d954d35d7ee2960ec89c48b5d88c17e160c00;

    function _getStorage() internal pure returns (PoolStorage storage $) {
        assembly {
            $.slot := ASSET_LENDING_POOL_RUNTIME_STORAGE_SLOT
        }
    }

    /// @dev Convenience accessor to the config contract.
    function _config() internal view returns (IAssetLendingPoolConfig) {
        return _getStorage().config;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @notice Initializes the pool proxy.
    /// @param initialOwner_ Address to receive ownership.
    /// @param config_ Address of the deployed AssetLendingPoolConfig proxy.
    function initialize(
        address initialOwner_,
        address config_
    ) external initializer {
        if (initialOwner_ == address(0)) revert AssetLendingPool__ZeroAddress();
        if (config_ == address(0)) revert AssetLendingPool__ZeroAddress();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();

        PoolStorage storage $ = _getStorage();
        $.config = IAssetLendingPoolConfig(config_);
        $.nextLoanId = 1;

        // Cache paymentToken and assetNFT locally — they are read on nearly every
        // function and are immutable after config init.
        $.paymentToken = IERC20(
            IAssetLendingPoolConfig(config_).paymentToken()
        );
        $.assetNFT = IAssetNFT(IAssetLendingPoolConfig(config_).assetNFT());
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Restricts a function to the authorized marketplace address only.
    modifier onlyMarketplace() {
        if (msg.sender != _config().getMarketplace()) {
            revert AssetLendingPool__NotMarketplace();
        }
        _;
    }

    // =========================================================================
    // Borrower: borrow / borrowBundle
    // =========================================================================

    /// @notice Collateralize an AssetNFT and borrow payment tokens.
    /// @dev NFT must be in Held state and borrower must have approved this contract.
    ///      Interest is fixed upfront using APR pro-rated over the term: amount * aprBps * duration / (365 days * BPS).
    ///      Origination fee (if set) is deducted from disbursement.
    /// @param tokenId AssetNFT token ID to use as collateral.
    /// @param amount Loan principal requested (must be <= LTV of appraisal value).
    /// @param termId Term configuration index (0, 1, or 2 by default).
    function borrow(
        uint256 tokenId,
        uint256 amount,
        uint8 termId
    ) external override nonReentrant whenNotPaused {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        _borrow(ids, amount, termId);
    }

    /// @notice Collateralize multiple AssetNFTs as a bundle and borrow against their summed appraisal value.
    /// @dev Each NFT must individually pass eligibility checks. Max bundle size is 50.
    /// @param tokenIds AssetNFT token IDs to use as collateral.
    /// @param amount Loan principal requested (must be <= LTV of summed appraisal values).
    /// @param termId Term configuration index (0, 1, or 2 by default).
    function borrowBundle(
        uint256[] calldata tokenIds,
        uint256 amount,
        uint8 termId
    ) external override nonReentrant whenNotPaused {
        _borrow(tokenIds, amount, termId);
    }

    // =========================================================================
    // Borrower: repay
    // =========================================================================

    /// @notice Repay a loan and reclaim all collateral NFTs.
    /// @dev Only the borrower can repay.
    /// @param loanId Loan ID to repay.
    function repay(
        uint256 loanId
    ) external override nonReentrant whenNotPaused {
        PoolStorage storage $ = _getStorage();
        _settleLoanRepayment($, loanId, msg.sender, msg.sender, msg.sender);
    }

    // =========================================================================
    // Marketplace: atomic loan settlement on sale
    // =========================================================================

    /// @notice Atomically settle a loan from marketplace sale proceeds and release collateral to the buyer.
    /// @dev Only callable by the authorized marketplace (set via config.setMarketplace).
    /// @param loanId Loan to settle.
    /// @param payer  Address from which principal+interest is pulled (the marketplace contract).
    /// @param buyer  Address that receives the released collateral NFT(s).
    function settleLoanRepaymentOnSale(
        uint256 loanId,
        address payer,
        address buyer
    ) external override nonReentrant whenNotPaused onlyMarketplace {
        if (buyer == address(0)) revert AssetLendingPool__ZeroAddress();
        PoolStorage storage $ = _getStorage();

        (
            uint256 principal,
            uint256 interest,
            address borrower
        ) = _settleLoanRepayment($, loanId, payer, buyer, address(0));

        emit LoanSettledOnSale(loanId, borrower, buyer, principal + interest);
    }

    // =========================================================================
    // Borrower: financeMarketplacePurchase
    // =========================================================================

    // EIP-712 domain typehash — matches the OpenZeppelin EIP712Upgradeable encoding.
    bytes32 private constant _EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    // Listing typehash — must match NettyWorthMarketplace.SIGNED_LISTING_TYPEHASH exactly.
    bytes32 private constant _SIGNED_LISTING_TYPEHASH = keccak256(
        "SignedListing(address seller,address collection,uint256 tokenId,"
        "address paymentToken,uint256 price,uint256 nonce,uint256 expiry,address buyer)"
    );

    /// @inheritdoc IAssetLendingPool
    function financeMarketplacePurchase(
        INettyWorthMarketplace.SignedListing calldata listing,
        bytes calldata sig,
        uint256 depositAmount,
        uint8 termId
    ) external override nonReentrant whenNotPaused {
        // Guard against self-financing: the pool cannot be both seller and lender (M009 fix).
        if (listing.seller == address(this)) revert AssetLendingPool__InvalidSeller();

        PoolStorage storage $ = _getStorage();
        IAssetLendingPoolConfig cfg = $.config;

        // --- Verify seller EIP-712 signature against the marketplace domain ---
        address marketplace = cfg.getMarketplace();
        if (marketplace == address(0)) revert AssetLendingPool__ZeroAddress();

        bytes32 domainSeparator = keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH,
                keccak256("NettyWorthMarketplace"),
                keccak256("1"),
                block.chainid,
                marketplace
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                _SIGNED_LISTING_TYPEHASH,
                listing.seller,
                listing.collection,
                listing.tokenId,
                listing.paymentToken,
                listing.price,
                listing.nonce,
                listing.expiry,
                listing.buyer  // must match new typehash that includes buyer field (H004 fix)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        if (ECDSA.recover(digest, sig) != listing.seller) {
            revert AssetLendingPool__InvalidSignature();
        }

        // --- Validate listing parameters (use cached pool-local refs for the comparison) ---
        if (block.timestamp > listing.expiry) {
            revert AssetLendingPool__ListingExpired();
        }
        if (listing.collection != address($.assetNFT)) {
            revert AssetLendingPool__ListingCollectionMismatch();
        }
        if (listing.paymentToken != address($.paymentToken)) {
            revert AssetLendingPool__ListingPaymentTokenMismatch();
        }

        // --- Replay protection (CEI: mark before external calls) ---
        if ($.financeNonces[listing.seller][listing.nonce]) {
            revert AssetLendingPool__ListingNonceUsed();
        }
        $.financeNonces[listing.seller][listing.nonce] = true;

        // --- Term check ---
        TermConfig memory term = cfg.getTermConfig(termId);
        if (!term.active) revert AssetLendingPool__InvalidTerm();

        // --- Eligibility & LTV ---
        uint256 tokenId = listing.tokenId;
        cfg.checkEligibility(tokenId);

        uint256 appraisalValue = cfg.getAppraisal(tokenId).value;
        uint256 maxLoan = (appraisalValue * cfg.ltvBps()) / BPS;

        uint256 purchasePrice = listing.price;
        if (depositAmount > purchasePrice)
            revert AssetLendingPool__ZeroAmount();
        uint256 loanAmount = purchasePrice - depositAmount;
        if (loanAmount == 0) revert AssetLendingPool__ZeroAmount();
        if (loanAmount > maxLoan) revert AssetLendingPool__ExceedsLTV();

        _checkUtilization($, loanAmount);

        if ($.tokenIdToActiveLoan[tokenId] != 0) {
            revert AssetLendingPool__ActiveLoanExists();
        }

        // --- Execute atomic purchase + loan origination ---
        $.assetNFT.transferFrom(listing.seller, address(this), tokenId);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        uint256 loanId = _originateLoan(
            $,
            msg.sender,
            ids,
            loanAmount,
            termId,
            true
        );

        // Buyer deposit -> seller, pool loan -> seller.
        $.paymentToken.safeTransferFrom(
            msg.sender,
            listing.seller,
            depositAmount
        );
        $.paymentToken.safeTransfer(listing.seller, loanAmount);

        // Origination fee pulled from buyer on top of deposit.
        uint256 fee = cfg.calculateOriginationFee(loanAmount);
        if (fee > 0) {
            $.paymentToken.safeTransferFrom(msg.sender, cfg.feeWallet(), fee);
        }

        emit MarketplacePurchaseFinanced(
            loanId,
            msg.sender,
            tokenId,
            depositAmount,
            loanAmount
        );
    }

    // =========================================================================
    // Lender: deposit
    // =========================================================================

    /// @notice Deposit USDC into the pool as an external lender.
    /// @param amount Amount of payment token to deposit.
    function lenderDeposit(
        uint256 amount
    ) external override nonReentrant whenNotPaused {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        PoolStorage storage $ = _getStorage();
        if (!$.config.lenderDepositsEnabled())
            revert AssetLendingPool__LenderDepositsDisabled();

        _accrueRewardDebtForDeposit($, msg.sender, amount);

        $.lenderDeposits[msg.sender] += amount;
        $.totalLenderDeposits += amount;
        $.totalDeposited += amount;

        $.paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        emit LenderDeposited(msg.sender, amount);
    }

    // =========================================================================
    // Lender: withdraw
    // =========================================================================

    /// @notice Withdraw idle (unborrowed) capital. Only available liquidity can be withdrawn.
    /// @dev Intentionally omits `whenNotPaused` so lenders can always exit.
    /// @param amount Amount to withdraw.
    function lenderWithdraw(uint256 amount) external override nonReentrant {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        PoolStorage storage $ = _getStorage();

        if (amount > $.lenderDeposits[msg.sender])
            revert AssetLendingPool__InsufficientLenderBalance();

        uint256 available = $.totalDeposited - $.totalBorrowed;
        if (amount > available)
            revert AssetLendingPool__InsufficientLiquidity();

        _claimLenderInterestInternal($, msg.sender);

        uint256 newBalance = $.lenderDeposits[msg.sender] - amount;
        $.lenderRewardDebt[msg.sender] =
            (newBalance * $.accInterestPerShare) / PRECISION;

        $.lenderDeposits[msg.sender] = newBalance;
        $.totalLenderDeposits -= amount;
        $.totalDeposited -= amount;

        $.paymentToken.safeTransfer(msg.sender, amount);
        emit LenderWithdrawn(msg.sender, amount);
    }

    // =========================================================================
    // Lender: claimLenderInterest
    // =========================================================================

    /// @notice Claim all accrued interest earnings.
    /// @dev Intentionally omits `whenNotPaused` so lenders can always withdraw earnings.
    function claimLenderInterest() external override nonReentrant {
        PoolStorage storage $ = _getStorage();
        uint256 claimed = _claimLenderInterestInternal($, msg.sender);
        if (claimed == 0) revert AssetLendingPool__NoInterestToClaim();
    }

    // =========================================================================
    // Admin: pool funding
    // =========================================================================

    /// @notice Fund the pool from treasury.
    function deposit(uint256 amount) external override onlyOwner {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        PoolStorage storage $ = _getStorage();
        $.ownerDeposited += amount;
        $.totalDeposited += amount;
        $.paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        emit PoolFunded(amount, $.totalDeposited);
    }

    /// @notice Withdraw owner-deposited (unborrowed) capital.
    function withdraw(uint256 amount) external override onlyOwner {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        PoolStorage storage $ = _getStorage();
        if (amount > $.ownerDeposited)
            revert AssetLendingPool__OwnerWithdrawExceedsOwnerDeposits();
        uint256 available = $.totalDeposited - $.totalBorrowed;
        if (amount > available)
            revert AssetLendingPool__WithdrawExceedsAvailable();
        $.ownerDeposited -= amount;
        $.totalDeposited -= amount;
        $.paymentToken.safeTransfer(msg.sender, amount);
        emit PoolWithdrawn(amount, $.totalDeposited);
    }

    /// @notice Withdraw accumulated protocol interest earnings (excludes lender share).
    function withdrawInterest(uint256 amount) external override onlyOwner {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        PoolStorage storage $ = _getStorage();
        uint256 available = $.totalInterestEarned - $.interestWithdrawn;
        if (amount > available)
            revert AssetLendingPool__WithdrawExceedsAvailable();
        $.interestWithdrawn += amount;
        $.paymentToken.safeTransfer(msg.sender, amount);
        emit InterestWithdrawn(amount);
    }

    // =========================================================================
    // Admin: default lifecycle — initiate
    // =========================================================================

    /// @notice Initiate the default lifecycle for an expired loan.
    function initiateDefault(uint256 loanId) external override onlyOwner {
        _initiateDefault(loanId);
    }

    /// @notice Backward-compatible alias for initiateDefault().
    function liquidate(uint256 loanId) external override onlyOwner {
        _initiateDefault(loanId);
    }

    // =========================================================================
    // Admin: default lifecycle — Phase 1 acquisition
    // =========================================================================

    /// @notice NettyWorth acquires the defaulted asset within the acquisition window (Phase 1)
    ///         and recycles it into a PackMachine.
    /// @param loanId Loan ID whose default record is in the Acquisition phase.
    /// @param targetPackMachine PackMachine to deposit the NFT into.
    /// @param tier Rarity tier for the NFT inside the PackMachine.
    function acquireDefaultedAsset(
        uint256 loanId,
        address targetPackMachine,
        uint8 tier
    ) external override onlyOwner nonReentrant {
        PoolStorage storage $ = _getStorage();
        IAssetLendingPoolConfig cfg = $.config;

        address fw = cfg.getFinanceWallet();
        if (fw == address(0)) revert AssetLendingPool__FinanceWalletNotSet();

        address factory = cfg.packMachineFactory();
        if (
            factory == address(0) ||
            !IPackMachineFactory(factory).isPackMachine(targetPackMachine)
        ) revert AssetLendingPool__InvalidPackMachine();

        // Enforce Phase 1 window before any state changes.
        {
            DefaultRecord storage rec = $.defaults[loanId];
            if (rec.defaultedAt == 0)
                revert AssetLendingPool__DefaultNotFound();
            if (block.timestamp >= rec.defaultedAt + cfg.acquisitionWindow())
                revert AssetLendingPool__NotInAcquisitionPhase();
        }

        // ---- State writes (CEI) ----
        (
            uint256[] memory tokenIds,
            uint256 principal,
            uint256 interest
        ) = _resolveAndRecredit($, loanId);

        // ---- External interactions ----
        $.paymentToken.safeTransferFrom(
            fw,
            address(this),
            principal + interest
        );

        uint256 len = tokenIds.length;
        uint8[] memory tiers = new uint8[](len);
        for (uint256 i; i < len; ) {
            $.assetNFT.approve(targetPackMachine, tokenIds[i]);
            tiers[i] = tier;
            unchecked {
                ++i;
            }
        }
        IPackMachine(targetPackMachine).depositFromPool(
            tokenIds,
            tiers,
            address(this)
        );

        emit DefaultedAssetAcquired(loanId, tokenIds[0], targetPackMachine);
    }

    // =========================================================================
    // Marketplace callbacks — pool-default auction lifecycle
    // =========================================================================

    /// @inheritdoc IAssetLendingPool
    function prepareDefaultedListing(
        uint256 loanId
    )
        external
        override
        onlyMarketplace
        nonReentrant
        returns (uint256[] memory tokenIds)
    {
        PoolStorage storage $ = _getStorage();
        DefaultRecord storage rec = $.defaults[loanId];

        if (rec.defaultedAt == 0) revert AssetLendingPool__DefaultNotFound();
        if (rec.resolved) revert AssetLendingPool__DefaultAlreadyResolved();
        if (block.timestamp < rec.defaultedAt + $.config.acquisitionWindow())
            revert AssetLendingPool__NotInPurchasePhase();
        if (rec.listedOnMarketplace) revert AssetLendingPool__AlreadyListed();

        tokenIds = rec.tokenIds;
        if (tokenIds.length != 1)
            revert AssetLendingPool__BatchTooLarge(tokenIds.length, 1);

        rec.listedOnMarketplace = true;

        address mkt = $.config.getMarketplace();
        $.assetNFT.approve(mkt, tokenIds[0]);
    }

    /// @inheritdoc IAssetLendingPool
    function onDefaultedAssetSold(
        uint256 loanId,
        uint256 proceeds
    ) external override onlyMarketplace nonReentrant {
        PoolStorage storage $ = _getStorage();

        {
            DefaultRecord storage rec = $.defaults[loanId];
            if (!rec.listedOnMarketplace)
                revert AssetLendingPool__DefaultNotListed();
        }

        (
            uint256[] memory tokenIds,
            uint256 principal,
            uint256 interest
        ) = _resolveAndRecredit($, loanId);

        if (proceeds < principal + interest)
            revert AssetLendingPool__InsufficientProceeds();

        uint256 surplus = proceeds - principal - interest;
        if (surplus > 0) {
            $.totalInterestEarned += surplus;
        }

        emit DefaultedAssetSold(
            loanId,
            tokenIds[0],
            proceeds,
            principal,
            interest,
            surplus
        );
    }

    /// @inheritdoc IAssetLendingPool
    function onDefaultedListingCancelled(
        uint256 loanId
    ) external override onlyMarketplace nonReentrant {
        PoolStorage storage $ = _getStorage();
        DefaultRecord storage rec = $.defaults[loanId];

        if (rec.defaultedAt == 0) revert AssetLendingPool__DefaultNotFound();
        if (rec.resolved) revert AssetLendingPool__DefaultAlreadyResolved();
        if (!rec.listedOnMarketplace)
            revert AssetLendingPool__DefaultNotListed();

        rec.listedOnMarketplace = false;
    }

    // =========================================================================
    // Admin: rescue NFT
    // =========================================================================

    /// @notice Transfer a pool-owned NFT to a recipient.
    function rescueNFT(uint256 tokenId, address recipient) external onlyOwner {
        if (recipient == address(0)) revert AssetLendingPool__ZeroAddress();
        PoolStorage storage $ = _getStorage();
        if ($.assetNFT.ownerOf(tokenId) != address(this)) {
            revert AssetLendingPool__NFTNotInPool();
        }
        $.assetNFT.transferFrom(address(this), recipient, tokenId);
        emit NFTRescued(tokenId, recipient);
    }

    // =========================================================================
    // Admin: pause
    // =========================================================================

    /// @notice Pause the pool.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the pool.
    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // View functions
    // =========================================================================

    function getLoan(
        uint256 loanId
    ) external view override returns (Loan memory) {
        return _getStorage().loans[loanId];
    }

    function getLoanTokenIds(
        uint256 loanId
    ) external view override returns (uint256[] memory) {
        return _getStorage().loans[loanId].tokenIds;
    }

    function getBorrowerLoans(
        address borrower
    ) external view override returns (uint256[] memory) {
        return _getStorage().borrowerLoans[borrower];
    }

    function getAvailableLiquidity() external view override returns (uint256) {
        PoolStorage storage $ = _getStorage();
        return $.totalDeposited - $.totalBorrowed;
    }

    function getPoolInfo()
        external
        view
        override
        returns (PoolInfo memory info)
    {
        PoolStorage storage $ = _getStorage();
        IAssetLendingPoolConfig.ConfigSnapshot memory snap = $
            .config
            .getConfigSnapshot();

        // Config fields (from config contract)
        info.paymentToken = snap.paymentToken;
        info.assetNFT = snap.assetNFT;
        info.termCount = snap.termCount;
        info.minAppraisalValue = snap.minAppraisalValue;
        info.minGrade = snap.minGrade;
        info.originationFeeBps = snap.originationFeeBps;
        info.feeWallet = snap.feeWallet;
        info.ltvBps = snap.ltvBps;
        info.maxAppraisalAge = snap.maxAppraisalAge;
        info.lenderShareBps = snap.lenderShareBps;
        info.lenderDepositsEnabled = snap.lenderDepositsEnabled;
        info.acquisitionWindow = snap.acquisitionWindow;
        info.auctionWindow = snap.auctionWindow;
        info.maxUtilizationBps = snap.maxUtilizationBps;

        // Runtime fields (from this contract)
        info.nextLoanId = $.nextLoanId;
        info.totalDeposited = $.totalDeposited;
        info.totalBorrowed = $.totalBorrowed;
        info.totalInterestEarned = $.totalInterestEarned;
        info.interestWithdrawn = $.interestWithdrawn;
        info.activeLoanCount = $.activeLoanCount;
        info.totalLenderDeposits = $.totalLenderDeposits;
        info.ownerDeposited = $.ownerDeposited;
        info.totalDefaultedPrincipal = $.totalDefaultedPrincipal;
    }

    /// @notice Returns the current default phase for a given loan.
    function getDefaultPhase(
        uint256 loanId
    ) external view override returns (DefaultPhase) {
        PoolStorage storage $ = _getStorage();
        DefaultRecord storage rec = $.defaults[loanId];
        if (rec.defaultedAt == 0) return DefaultPhase.None;
        if (rec.resolved) return DefaultPhase.Resolved;
        IAssetLendingPoolConfig cfg = $.config;
        uint256 elapsed = block.timestamp - rec.defaultedAt;
        uint256 acqW = cfg.acquisitionWindow();
        uint256 aucW = cfg.auctionWindow();
        if (elapsed < acqW) return DefaultPhase.Acquisition;
        if (elapsed < acqW + aucW) return DefaultPhase.Auction;
        return DefaultPhase.FixedListing;
    }

    /// @notice Returns the stored default record for a loan.
    function getDefaultRecord(
        uint256 loanId
    ) external view override returns (DefaultRecord memory) {
        return _getStorage().defaults[loanId];
    }

    /// @notice Returns lender deposit balance, claimable interest, and pool share.
    function getLenderInfo(
        address lender
    ) external view override returns (LenderInfo memory info) {
        PoolStorage storage $ = _getStorage();
        info.deposited = $.lenderDeposits[lender];
        info.claimableInterest = _pendingLenderInterest($, lender);
        info.poolShareBps =
            $.totalLenderDeposits == 0
                ? 0
                : (info.deposited * BPS) / $.totalLenderDeposits;
    }

    // =========================================================================
    // Passthrough view functions (so callers using the pool address keep working)
    // =========================================================================

    /// @notice Returns the appraisal for a token. Passthrough to the config contract.
    function getAppraisal(
        uint256 tokenId
    ) external view override returns (AssetAppraisal memory) {
        return _config().getAppraisal(tokenId);
    }

    /// @notice Returns the term configuration for a given term ID. Passthrough to config.
    function getTermConfig(
        uint8 termId
    ) external view override returns (TermConfig memory) {
        return _config().getTermConfig(termId);
    }

    /// @notice Returns the maximum loan amount for a token (LTV × appraisal value). Passthrough to config.
    function getMaxLoanAmount(
        uint256 tokenId
    ) external view override returns (uint256) {
        return _config().getMaxLoanAmount(tokenId);
    }

    /// @notice Returns whether a token is eligible for use as collateral. Passthrough to config.
    function isEligible(uint256 tokenId) external view override returns (bool) {
        return _config().isEligible(tokenId);
    }

    /// @notice Returns the active loan ID for a token (0 if none).
    function getActiveLoanId(
        uint256 tokenId
    ) external view override returns (uint256) {
        return _getStorage().tokenIdToActiveLoan[tokenId];
    }

    /// @notice Returns the debt components for the active loan on a token.
    function getLoanDebt(
        uint256 tokenId
    )
        external
        view
        override
        returns (uint256 principal, uint256 interest, uint256 total)
    {
        PoolStorage storage $ = _getStorage();
        uint256 loanId = $.tokenIdToActiveLoan[tokenId];
        if (loanId == 0) return (0, 0, 0);
        Loan storage loan = $.loans[loanId];
        principal = loan.principal;
        interest = loan.interest;
        total = principal + interest;
    }

    /// @notice Returns the borrower of a loan (address(0) if not found). (C004 fix)
    function getLoanBorrower(
        uint256 loanId
    ) external view override returns (address) {
        return _getStorage().loans[loanId].borrower;
    }

    /// @notice Returns the number of collateral tokens in a loan. (H003 fix)
    function getLoanCollateralCount(
        uint256 loanId
    ) external view override returns (uint256) {
        return _getStorage().loans[loanId].tokenIds.length;
    }

    /// @notice Returns the AssetNFT contract address used by this pool. (H005 fix)
    function getAssetNFT() external view override returns (address) {
        return address(_getStorage().assetNFT);
    }

    /// @notice Returns the authorized marketplace address. Passthrough to config.
    function getMarketplace() external view override returns (address) {
        return _config().getMarketplace();
    }

    /// @notice Returns the finance wallet address. Passthrough to config.
    function getFinanceWallet() external view override returns (address) {
        return _config().getFinanceWallet();
    }

    /// @notice Returns the address of the AssetLendingPoolConfig contract.
    function getConfig() external view returns (address) {
        return address(_getStorage().config);
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // =========================================================================
    // Internal helpers
    // =========================================================================

    function _setAssetStateBatch(
        PoolStorage storage $,
        uint256[] memory tokenIds,
        IAssetNFT.AssetState state
    ) private {
        uint256 len = tokenIds.length;
        IAssetNFT.AssetState[] memory states = new IAssetNFT.AssetState[](len);
        for (uint256 i; i < len; ) {
            states[i] = state;
            unchecked {
                ++i;
            }
        }
        $.assetNFT.batchSetAssetState(tokenIds, states);
    }

    function _clearActiveLoans(
        PoolStorage storage $,
        uint256[] memory tokenIds
    ) private {
        for (uint256 i; i < tokenIds.length; ) {
            $.tokenIdToActiveLoan[tokenIds[i]] = 0;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev O(1) swap-and-pop removal of `loanId` from `borrowerLoans[borrower]` (M002 fix).
    function _removeBorrowerLoan(
        PoolStorage storage $,
        address borrower,
        uint256 loanId
    ) private {
        uint256[] storage arr = $.borrowerLoans[borrower];
        uint256 idx = $.borrowerLoanIndex[loanId];
        uint256 last = arr.length - 1;
        if (idx != last) {
            uint256 lastId = arr[last];
            arr[idx] = lastId;
            $.borrowerLoanIndex[lastId] = idx;
        }
        arr.pop();
        delete $.borrowerLoanIndex[loanId];
    }

    function _settleLoanRepayment(
        PoolStorage storage $,
        uint256 loanId,
        address payer,
        address recipient,
        address requireBorrower
    ) private returns (uint256 principal, uint256 interest, address borrower) {
        Loan storage loan = _requireActiveLoan($, loanId);
        borrower = loan.borrower;
        if (requireBorrower != address(0) && borrower != requireBorrower)
            revert AssetLendingPool__NotBorrower();

        principal = loan.principal;
        interest = loan.interest;
        uint256[] memory tokenIds = loan.tokenIds;
        uint256 lenderShareBpsSnap = loan.lenderShareBpsSnapshot;
        uint256 lenderDepositsSnap = loan.lenderDepositsSnapshot;

        // ---- State writes (CEI) ----
        loan.isPaid = true;
        $.totalBorrowed -= principal;
        $.activeLoanCount--;
        _clearActiveLoans($, tokenIds);
        _removeBorrowerLoan($, borrower, loanId);

        _distributeInterest($, interest, lenderShareBpsSnap, lenderDepositsSnap);

        // ---- External interactions ----
        $.paymentToken.safeTransferFrom(
            payer,
            address(this),
            principal + interest
        );

        _setAssetStateBatch($, tokenIds, IAssetNFT.AssetState.Held);
        for (uint256 i; i < tokenIds.length; ) {
            $.assetNFT.transferFrom(address(this), recipient, tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        emit LoanRepaid(loanId, borrower, principal, interest);
    }

    function _resolveAndRecredit(
        PoolStorage storage $,
        uint256 loanId
    )
        private
        returns (uint256[] memory tokenIds, uint256 principal, uint256 interest)
    {
        DefaultRecord storage rec = $.defaults[loanId];
        if (rec.defaultedAt == 0) revert AssetLendingPool__DefaultNotFound();
        if (rec.resolved) revert AssetLendingPool__DefaultAlreadyResolved();

        tokenIds = rec.tokenIds;
        principal = rec.outstandingValue;
        interest = rec.interestValue;

        rec.resolved = true;

        $.totalDeposited += principal;
        $.totalDefaultedPrincipal -= principal;

        // Use the snapshots from the original loan so interest distribution cannot be
        // manipulated by admin config changes or JIT deposits after origination (H001/M003 fix).
        Loan storage loan = $.loans[loanId];
        _distributeInterest(
            $,
            interest,
            loan.lenderShareBpsSnapshot,
            loan.lenderDepositsSnapshot
        );
    }

    function _requireActiveLoan(
        PoolStorage storage $,
        uint256 loanId
    ) private view returns (Loan storage loan) {
        loan = $.loans[loanId];
        if (loan.loanId == 0) revert AssetLendingPool__LoanNotFound();
        if (loan.isPaid) revert AssetLendingPool__LoanAlreadyPaid();
        if (loan.isDefaulted) revert AssetLendingPool__LoanAlreadyDefaulted();
    }

    function _collectOriginationFee(
        PoolStorage storage $,
        uint256 principal
    ) private returns (uint256 fee) {
        IAssetLendingPoolConfig cfg = $.config;
        fee = cfg.calculateOriginationFee(principal);
        if (fee > 0) {
            $.paymentToken.safeTransfer(cfg.feeWallet(), fee);
        }
    }

    /// @dev Checks that the bundle is non-empty, within MAX_BATCH, each token passes config
    ///      eligibility (one external call for the whole bundle), and none already has an active
    ///      loan. Returns the summed appraisal value.
    function _validateBundle(
        PoolStorage storage $,
        uint256[] memory tokenIds
    ) private view returns (uint256 summedAppraisal) {
        uint256 len = tokenIds.length;
        if (len == 0) revert AssetLendingPool__EmptyBundle();
        if (len > MAX_BATCH)
            revert AssetLendingPool__BatchTooLarge(len, MAX_BATCH);

        // Single external call handles eligibility checks + appraisal sum for the whole bundle.
        summedAppraisal = $.config.validateBundleAndSumAppraisals(tokenIds);

        // Still check active-loan mapping locally (runtime state not visible to config).
        for (uint256 i; i < len; ) {
            if ($.tokenIdToActiveLoan[tokenIds[i]] != 0)
                revert AssetLendingPool__ActiveLoanExists();
            unchecked {
                ++i;
            }
        }
    }

    function _borrow(
        uint256[] memory tokenIds,
        uint256 amount,
        uint8 termId
    ) private {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        PoolStorage storage $ = _getStorage();
        IAssetLendingPoolConfig cfg = $.config;

        TermConfig memory term = cfg.getTermConfig(termId);
        if (!term.active) revert AssetLendingPool__InvalidTerm();

        uint256 summedAppraisal = _validateBundle($, tokenIds);

        uint256 maxLoan = (summedAppraisal * cfg.ltvBps()) / BPS;
        if (amount > maxLoan) revert AssetLendingPool__ExceedsLTV();

        _checkUtilization($, amount);

        for (uint256 i; i < tokenIds.length; ) {
            $.assetNFT.transferFrom(msg.sender, address(this), tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        _originateLoan($, msg.sender, tokenIds, amount, termId, false);

        uint256 fee = _collectOriginationFee($, amount);
        $.paymentToken.safeTransfer(msg.sender, amount - fee);
    }

    function _originateLoan(
        PoolStorage storage $,
        address borrower,
        uint256[] memory tokenIds,
        uint256 principal,
        uint8 termId,
        bool isMarketplaceFinanced
    ) private returns (uint256 loanId) {
        TermConfig memory term = $.config.getTermConfig(termId);
        uint256 interest =
            (principal * term.aprBps * term.duration) / (YEAR * BPS);
        uint256 expireTime = block.timestamp + term.duration;

        // Snapshot config values at origination so they cannot be retroactively changed
        // by the admin between origination and repayment (H001 / M003 fix).
        uint256 lenderShareBpsSnap = $.config.lenderShareBps();
        uint256 lenderDepositsSnap = $.totalLenderDeposits;

        loanId = $.nextLoanId++;
        $.loans[loanId] = Loan({
            loanId: loanId,
            borrower: borrower,
            tokenIds: tokenIds,
            principal: principal,
            interest: interest,
            startTime: block.timestamp,
            expireTime: expireTime,
            termId: termId,
            isPaid: false,
            isDefaulted: false,
            isMarketplaceFinanced: isMarketplaceFinanced,
            lenderShareBpsSnapshot: lenderShareBpsSnap,
            lenderDepositsSnapshot: lenderDepositsSnap
        });
        $.borrowerLoans[borrower].push(loanId);
        // Record index for O(1) removal on close (M002 fix).
        $.borrowerLoanIndex[loanId] = $.borrowerLoans[borrower].length - 1;

        for (uint256 i; i < tokenIds.length; ) {
            $.tokenIdToActiveLoan[tokenIds[i]] = loanId;
            unchecked {
                ++i;
            }
        }

        $.totalBorrowed += principal;
        $.activeLoanCount++;

        _setAssetStateBatch($, tokenIds, IAssetNFT.AssetState.Loaned);

        emit LoanOriginated(
            loanId,
            borrower,
            tokenIds[0],
            principal,
            interest,
            termId,
            expireTime
        );
        emit BundleLoanOriginated(
            loanId,
            borrower,
            tokenIds,
            principal,
            interest,
            termId,
            expireTime
        );
    }

    function _initiateDefault(uint256 loanId) private {
        PoolStorage storage $ = _getStorage();
        Loan storage loan = _requireActiveLoan($, loanId);

        if (block.timestamp <= loan.expireTime)
            revert AssetLendingPool__LoanNotExpired();

        uint256[] memory tokenIds = loan.tokenIds;
        address borrower = loan.borrower;
        uint256 principal = loan.principal;

        loan.isDefaulted = true;
        $.totalBorrowed -= principal;
        $.totalDeposited -= principal;
        $.activeLoanCount--;
        $.totalDefaultedPrincipal += principal;

        _clearActiveLoans($, tokenIds);
        _removeBorrowerLoan($, borrower, loanId);

        $.defaults[loanId] = DefaultRecord({
            loanId: loanId,
            tokenIds: tokenIds,
            outstandingValue: principal,
            defaultedAt: block.timestamp,
            resolved: false,
            interestValue: loan.interest,
            listedOnMarketplace: false
        });

        _setAssetStateBatch($, tokenIds, IAssetNFT.AssetState.Held);

        emit LoanDefaulted(loanId, borrower, tokenIds[0]);
        emit DefaultInitiated(loanId, tokenIds[0], principal);
    }

    /// @dev Local utilization check — reads totalDeposited/totalBorrowed from runtime
    ///      and maxUtilizationBps from the config contract.
    function _checkUtilization(
        PoolStorage storage $,
        uint256 amount
    ) private view {
        uint256 maxBorrowable =
            ($.totalDeposited * $.config.maxUtilizationBps()) / BPS;
        if ($.totalBorrowed + amount > maxBorrowable)
            revert AssetLendingPool__ExceedsMaxUtilization();
    }

    /// @dev Distribute `interest` between lenders (via accInterestPerShare) and protocol.
    ///      `lenderShareBps` and `totalLenderDeposits` are the values snapshotted at loan
    ///      origination — passing live values would allow JIT deposit sandwiches (H001) and
    ///      admin config changes to retroactively reprice in-flight interest (M003).
    ///      For pre-upgrade loans where lenderDepositsSnapshot == 0, fall back to live values
    ///      so old loans continue to work correctly after the upgrade.
    function _distributeInterest(
        PoolStorage storage $,
        uint256 interest,
        uint256 lenderShareBps,
        uint256 totalLenderDeposits
    ) private {
        if (interest == 0) return;
        // Fall back to live values for pre-upgrade loans (snapshot fields default to 0).
        if (totalLenderDeposits == 0) totalLenderDeposits = $.totalLenderDeposits;
        if (lenderShareBps == 0) lenderShareBps = $.config.lenderShareBps();
        uint256 lenderPortion;
        if (totalLenderDeposits > 0) {
            if (lenderShareBps > 0) {
                lenderPortion = (interest * lenderShareBps) / BPS;
                $.accInterestPerShare +=
                    (lenderPortion * PRECISION) / totalLenderDeposits;
            }
        }
        $.totalInterestEarned += interest - lenderPortion;
    }

    function _pendingLenderInterest(
        PoolStorage storage $,
        address lender
    ) private view returns (uint256) {
        uint256 balance = $.lenderDeposits[lender];
        if (balance == 0) return 0;
        return
            (balance * $.accInterestPerShare) / PRECISION -
            $.lenderRewardDebt[lender];
    }

    function _claimLenderInterestInternal(
        PoolStorage storage $,
        address lender
    ) private returns (uint256 pending) {
        pending = _pendingLenderInterest($, lender);
        if (pending == 0) return 0;
        $.lenderRewardDebt[lender] += pending;
        $.totalLenderInterestPaid += pending;
        $.paymentToken.safeTransfer(lender, pending);
        emit LenderInterestClaimed(lender, pending);
    }

    function _accrueRewardDebtForDeposit(
        PoolStorage storage $,
        address lender,
        uint256 amount
    ) private {
        $.lenderRewardDebt[lender] +=
            (amount * $.accInterestPerShare) / PRECISION;
    }
}
