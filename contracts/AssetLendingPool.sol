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
import {INettyWorthMarketplace} from "./interfaces/INettyWorthMarketplace.sol";
import {IPackMachine} from "./interfaces/IPackMachine.sol";
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";
import {AssetLendingPoolConfig} from "./AssetLendingPoolConfig.sol";

/// @title AssetLendingPool
/// @author NettyWorth
/// @notice Platform-operated lending pool that accepts AssetNFT tokens as collateral.
///         Funded by platform treasury and external lenders. Fixed loan terms with upfront interest.
///         Includes a marketplace financing path for atomic purchase+loan origination.
///         Defaulted assets follow a 3-phase lifecycle: NettyWorth acquisition window
///         (default 24h, configurable), then a public marketplace auction window (default 7 days,
///         configurable), then a perpetual fixed-price listing.
/// @dev UUPS upgradeable. Uses ERC-7201 namespaced storage (slot owned by AssetLendingPoolConfig).
///      Access control via Ownable2StepUpgradeable (single admin). The pool contract address must
///      be granted STATE_MANAGER_ROLE on PermissionManager so it can call
///      assetNFT.batchSetAssetState() to transition tokens between Held and Loaned.
///      Configuration setters and storage layout live in AssetLendingPoolConfig.
/// @custom:security-contact security@nettyworth.io
contract AssetLendingPool is
    AssetLendingPoolConfig,
    UUPSUpgradeable,
    ReentrancyGuard,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants (business-math only; config constants live in AssetLendingPoolConfig)
    // =========================================================================

    uint256 private constant YEAR = 365 days;
    /// @dev Scaling factor for reward-per-share accumulator to preserve precision.
    uint256 private constant PRECISION = 1e18;

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

    /// @notice Initializes the proxy.
    /// @param initialOwner_ Address to receive ownership.
    /// @param paymentToken_ ERC20 token used for loans (e.g. USDC).
    /// @param assetNFT_ AssetNFT proxy address.
    /// @param ltvBps_ Initial LTV in basis points (e.g. 5000 = 50%).
    /// @param lenderShareBps_ Percentage of interest allocated to lenders (e.g. 8000 = 80%).
    /// @param acquisitionWindow_ Phase 1 duration in seconds (e.g. 24 hours).
    /// @param auctionWindow_ Phase 2 duration in seconds (e.g. 7 days).
    /// @param packMachineFactory_ PackMachineFactory address for validating target machines.
    function initialize(
        address initialOwner_,
        address paymentToken_,
        address assetNFT_,
        uint256 ltvBps_,
        uint256 lenderShareBps_,
        uint256 acquisitionWindow_,
        uint256 auctionWindow_,
        address packMachineFactory_
    ) external initializer {
        if (initialOwner_ == address(0)) revert AssetLendingPool__ZeroAddress();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();

        __AssetLendingPoolConfig_init(
            paymentToken_,
            assetNFT_,
            ltvBps_,
            lenderShareBps_,
            acquisitionWindow_,
            auctionWindow_,
            packMachineFactory_
        );
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Restricts a function to the authorized marketplace address only.
    modifier onlyMarketplace() {
        if (msg.sender != _getStorage().marketplace) {
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
    /// @dev Each NFT must individually pass eligibility checks (value >= $100 min, grade, category, staleness).
    ///      All NFTs must be in Held state and the borrower must have approved this contract for each.
    ///      The maximum loan amount is LTV * sum(appraisal values). Max bundle size is 50.
    ///      Interest is fixed upfront; origination fee (if set) is deducted from disbursement.
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
    /// @dev Allowed after expiry as long as admin has not called initiateDefault().
    ///      Only the borrower can repay. All collateral NFTs are returned atomically.
    /// @param loanId Loan ID to repay.
    function repay(
        uint256 loanId
    ) external override nonReentrant whenNotPaused {
        AssetLendingPoolStorage storage $ = _getStorage();
        // Pull repayment from the borrower and return collateral to the borrower.
        // `requireBorrower = msg.sender` enforces that only the borrower may repay
        // (checked after loan validity so LoanNotFound takes precedence).
        _settleLoanRepayment($, loanId, msg.sender, msg.sender, msg.sender);
    }

    // =========================================================================
    // Marketplace: atomic loan settlement on sale
    // =========================================================================

    /// @notice Atomically settle a loan from marketplace sale proceeds and release collateral to the buyer.
    /// @dev Only callable by the authorized marketplace (set via setMarketplace). Mirrors repay()
    ///      accounting exactly — totalBorrowed -=, activeLoanCount--, _distributeInterest —
    ///      with three differences: (1) funds are pulled from `payer` (the marketplace, which already
    ///      holds the buyer's gross payment); (2) collateral NFTs are delivered to `buyer`, not the
    ///      borrower; (3) authorized by onlyMarketplace, not onlyBorrower.
    ///      CEI: all state writes complete before external token transfers.
    /// @param loanId Loan to settle.
    /// @param payer  Address from which principal+interest is pulled (the marketplace contract).
    /// @param buyer  Address that receives the released collateral NFT(s).
    function settleLoanRepaymentOnSale(
        uint256 loanId,
        address payer,
        address buyer
    ) external override nonReentrant whenNotPaused onlyMarketplace {
        if (buyer == address(0)) revert AssetLendingPool__ZeroAddress();
        AssetLendingPoolStorage storage $ = _getStorage();

        // Shared settlement core: pull principal+interest from the marketplace
        // (`payer`) and release collateral to the `buyer`. Mirrors repay() exactly.
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
        "address paymentToken,uint256 price,uint256 nonce,uint256 expiry)"
    );

    /// @inheritdoc IAssetLendingPool
    function financeMarketplacePurchase(
        INettyWorthMarketplace.SignedListing calldata listing,
        bytes calldata sig,
        uint256 depositAmount,
        uint8 termId
    ) external override nonReentrant whenNotPaused {
        AssetLendingPoolStorage storage $ = _getStorage();

        // --- Verify seller EIP-712 signature against the marketplace domain ---
        address marketplace = $.marketplace;
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
                listing.expiry
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        if (ECDSA.recover(digest, sig) != listing.seller) {
            revert AssetLendingPool__InvalidSignature();
        }

        // --- Validate listing parameters ---
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
        TermConfig storage term = $.termConfigs[termId];
        if (!term.active) revert AssetLendingPool__InvalidTerm();

        // --- Eligibility & LTV ---
        uint256 tokenId = listing.tokenId;
        _checkEligibility($, tokenId);

        uint256 appraisalValue = $.appraisals[tokenId].value;
        uint256 maxLoan = (appraisalValue * $.ltvBps) / BPS;

        // Purchase price is the listing price; min deposit ensures loan <= maxLoan.
        uint256 purchasePrice = listing.price;
        if (depositAmount > purchasePrice)
            revert AssetLendingPool__ZeroAmount();
        uint256 loanAmount = purchasePrice - depositAmount;
        if (loanAmount == 0) revert AssetLendingPool__ZeroAmount();
        // Buyer must cover any gap between listing price and max-financed amount.
        if (loanAmount > maxLoan) revert AssetLendingPool__ExceedsLTV();

        if (loanAmount > $.totalDeposited - $.totalBorrowed) {
            revert AssetLendingPool__InsufficientLiquidity();
        }

        if ($.tokenIdToActiveLoan[tokenId] != 0) {
            revert AssetLendingPool__ActiveLoanExists();
        }

        // --- Execute atomic purchase + loan origination ---
        // Transfer NFT from seller to pool (seller must have approved the pool).
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

        // Buyer deposit -> seller, pool loan -> seller: seller receives full listing price.
        $.paymentToken.safeTransferFrom(
            msg.sender,
            listing.seller,
            depositAmount
        );
        $.paymentToken.safeTransfer(listing.seller, loanAmount);

        // Origination fee pulled from buyer on top of deposit.
        uint256 fee = _calculateOriginationFee($, loanAmount);
        if (fee > 0) {
            $.paymentToken.safeTransferFrom(msg.sender, $.feeWallet, fee);
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

    /// @notice Deposit USDC into the pool as an external lender. Capital earns a pro-rata
    ///         share of interest from loans originated after your deposit.
    /// @param amount Amount of payment token to deposit.
    function lenderDeposit(
        uint256 amount
    ) external override nonReentrant whenNotPaused {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        AssetLendingPoolStorage storage $ = _getStorage();
        if (!$.lenderDepositsEnabled)
            revert AssetLendingPool__LenderDepositsDisabled();

        // Settle any pending interest before changing the deposit balance.
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

    /// @notice Withdraw idle (unborrowed) capital. Only available liquidity can be withdrawn —
    ///         capital funding active loans remains locked until repayment.
    /// @dev Intentionally omits `whenNotPaused` so lenders can always exit, even during a pause.
    ///      Auto-claims any pending interest before reducing the deposit balance.
    /// @param amount Amount to withdraw.
    function lenderWithdraw(uint256 amount) external override nonReentrant {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        AssetLendingPoolStorage storage $ = _getStorage();

        if (amount > $.lenderDeposits[msg.sender])
            revert AssetLendingPool__InsufficientLenderBalance();

        uint256 available = $.totalDeposited - $.totalBorrowed;
        if (amount > available)
            revert AssetLendingPool__InsufficientLiquidity();

        // Auto-claim pending interest before adjusting balance.
        _claimLenderInterestInternal($, msg.sender);

        // Adjust reward debt proportionally after the interest claim.
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
    /// @dev Intentionally omits `whenNotPaused` so lenders can always withdraw earnings,
    ///      even during a pause. Reverts if there is no interest to claim.
    function claimLenderInterest() external override nonReentrant {
        AssetLendingPoolStorage storage $ = _getStorage();
        uint256 claimed = _claimLenderInterestInternal($, msg.sender);
        if (claimed == 0) revert AssetLendingPool__NoInterestToClaim();
    }

    // =========================================================================
    // Admin: pool funding
    // =========================================================================

    /// @notice Fund the pool from treasury.
    function deposit(uint256 amount) external override onlyOwner {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        AssetLendingPoolStorage storage $ = _getStorage();
        $.ownerDeposited += amount;
        $.totalDeposited += amount;
        $.paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        emit PoolFunded(amount, $.totalDeposited);
    }

    /// @notice Withdraw owner-deposited (unborrowed) capital.
    /// @dev Owner can only withdraw their own deposited capital, not lender capital.
    function withdraw(uint256 amount) external override onlyOwner {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        AssetLendingPoolStorage storage $ = _getStorage();
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
        AssetLendingPoolStorage storage $ = _getStorage();
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
    ///         Opens the NettyWorth acquisition window (Phase 1).
    ///         Pool absorbs the principal loss immediately; recovery credits it back on resolution.
    /// @dev onlyOwner. Accounting round-trip: `totalDeposited -= principal` here;
    ///      `totalDeposited += outstandingValue` in `acquireDefaultedAsset` or
    ///      `purchaseDefaultedAsset` when the asset is eventually recovered.
    /// @param loanId Loan ID that has expired without repayment.
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

    /// @notice NettyWorth acquires the defaulted asset within the acquisition window (Phase 1,
    ///         default 24h) and recycles it into a PackMachine. Recovers the outstanding loan value.
    /// @dev onlyOwner. Reverts if called after the acquisition window has elapsed; use
    ///      `purchaseDefaultedAsset` for Phase 2/3 resolution.
    /// @param loanId Loan ID whose default record is in the Acquisition phase.
    /// @param targetPackMachine PackMachine to deposit the NFT into (must pass factory validation).
    /// @param tier Rarity tier for the NFT inside the PackMachine.
    function acquireDefaultedAsset(
        uint256 loanId,
        address targetPackMachine,
        uint8 tier
    ) external override onlyOwner nonReentrant {
        AssetLendingPoolStorage storage $ = _getStorage();

        address factory = $.packMachineFactory;
        if (
            factory == address(0) ||
            !IPackMachineFactory(factory).isPackMachine(targetPackMachine)
        ) revert AssetLendingPool__InvalidPackMachine();

        // Resolve the default record (Phase 1 window) and re-credit the pool.
        (uint256[] memory tokenIds, ) = _loadResolvableDefault($, loanId, true);

        // Approve and deposit all collateral NFTs into the PackMachine.
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
    // Public: default lifecycle — Phase 2 & 3 purchase
    // =========================================================================

    /// @notice Purchase a defaulted asset at the outstanding loan value.
    ///         Available in Phase 2 (auction, default 7 days after the acquisition window)
    ///         and Phase 3 (fixed-price listing, perpetual thereafter).
    /// @param loanId Loan ID whose default record is in Auction or FixedListing phase.
    function purchaseDefaultedAsset(
        uint256 loanId
    ) external override nonReentrant whenNotPaused {
        AssetLendingPoolStorage storage $ = _getStorage();

        // Resolve the default record (Phase 2/3 window) and re-credit the pool.
        (uint256[] memory tokenIds, uint256 price) = _loadResolvableDefault(
            $,
            loanId,
            false
        );

        // Pull single payment from buyer and transfer all collateral NFTs.
        $.paymentToken.safeTransferFrom(msg.sender, address(this), price);
        for (uint256 i; i < tokenIds.length; ) {
            $.assetNFT.transferFrom(address(this), msg.sender, tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        emit DefaultedAssetPurchased(loanId, tokenIds[0], msg.sender, price);
    }

    // =========================================================================
    // Admin: rescue NFT (safety escape hatch for edge cases)
    // =========================================================================

    /// @notice Transfer a pool-owned NFT to a recipient. Use only for edge cases where
    ///         the default lifecycle cannot resolve (e.g. the default record was never created).
    function rescueNFT(uint256 tokenId, address recipient) external onlyOwner {
        if (recipient == address(0)) revert AssetLendingPool__ZeroAddress();
        AssetLendingPoolStorage storage $ = _getStorage();
        if ($.assetNFT.ownerOf(tokenId) != address(this)) {
            revert AssetLendingPool__NFTNotInPool();
        }
        $.assetNFT.transferFrom(address(this), recipient, tokenId);
        emit NFTRescued(tokenId, recipient);
    }

    // =========================================================================
    // Admin: pause
    // =========================================================================

    /// @notice Pause the pool, blocking new borrows, repayments, and marketplace purchases.
    /// @dev onlyOwner. Lender withdrawals and interest claims remain available while paused.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the pool, restoring full functionality.
    /// @dev onlyOwner.
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
        AssetLendingPoolStorage storage $ = _getStorage();
        return $.totalDeposited - $.totalBorrowed;
    }

    function getPoolInfo()
        external
        view
        override
        returns (PoolInfo memory info)
    {
        AssetLendingPoolStorage storage $ = _getStorage();
        info.paymentToken = address($.paymentToken);
        info.assetNFT = address($.assetNFT);
        info.termCount = $.termCount;
        info.nextLoanId = $.nextLoanId;
        info.minAppraisalValue = $.minAppraisalValue;
        info.minGrade = $.minGrade;
        info.totalDeposited = $.totalDeposited;
        info.totalBorrowed = $.totalBorrowed;
        info.totalInterestEarned = $.totalInterestEarned;
        info.interestWithdrawn = $.interestWithdrawn;
        info.activeLoanCount = $.activeLoanCount;
        info.originationFeeBps = $.originationFeeBps;
        info.feeWallet = $.feeWallet;
        info.ltvBps = $.ltvBps;
        info.maxAppraisalAge = $.maxAppraisalAge;
        info.totalLenderDeposits = $.totalLenderDeposits;
        info.ownerDeposited = $.ownerDeposited;
        info.lenderShareBps = $.lenderShareBps;
        info.lenderDepositsEnabled = $.lenderDepositsEnabled;
        info.acquisitionWindow = $.acquisitionWindow;
        info.auctionWindow = $.auctionWindow;
        info.totalDefaultedPrincipal = $.totalDefaultedPrincipal;
    }

    /// @notice Returns the current default phase for a given loan, computed from timestamps.
    function getDefaultPhase(
        uint256 loanId
    ) external view override returns (DefaultPhase) {
        AssetLendingPoolStorage storage $ = _getStorage();
        DefaultRecord storage rec = $.defaults[loanId];
        if (rec.defaultedAt == 0) return DefaultPhase.None;
        if (rec.resolved) return DefaultPhase.Resolved;
        uint256 elapsed = block.timestamp - rec.defaultedAt;
        if (elapsed < $.acquisitionWindow) return DefaultPhase.Acquisition;
        if (elapsed < $.acquisitionWindow + $.auctionWindow)
            return DefaultPhase.Auction;
        return DefaultPhase.FixedListing;
    }

    /// @notice Returns the stored default record for a loan.
    function getDefaultRecord(
        uint256 loanId
    ) external view override returns (DefaultRecord memory) {
        return _getStorage().defaults[loanId];
    }

    /// @notice Returns lender deposit balance, claimable interest, and pool share for a given address.
    function getLenderInfo(
        address lender
    ) external view override returns (LenderInfo memory info) {
        AssetLendingPoolStorage storage $ = _getStorage();
        info.deposited = $.lenderDeposits[lender];
        info.claimableInterest = _pendingLenderInterest($, lender);
        info.poolShareBps =
            $.totalLenderDeposits == 0
                ? 0
                : (info.deposited * BPS) / $.totalLenderDeposits;
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Sets the same AssetState on every token in the array via a single batchSetAssetState call.
    function _setAssetStateBatch(
        AssetLendingPoolStorage storage $,
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

    /// @dev Clears the active-loan mapping for every collateral token in the array.
    function _clearActiveLoans(
        AssetLendingPoolStorage storage $,
        uint256[] memory tokenIds
    ) private {
        for (uint256 i; i < tokenIds.length; ) {
            $.tokenIdToActiveLoan[tokenIds[i]] = 0;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Shared settlement core for `repay` and `settleLoanRepaymentOnSale`.
    ///      Pulls principal+interest from `payer` and releases all collateral to
    ///      `recipient`. CEI: all state writes complete before external transfers.
    ///      Returns the loan's principal, interest, and borrower for event emission.
    /// @param requireBorrower If non-zero, reverts unless the loan borrower matches
    ///        (the borrower-only check for `repay`); pass address(0) to skip.
    function _settleLoanRepayment(
        AssetLendingPoolStorage storage $,
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

        // ---- State writes (CEI) ----
        loan.isPaid = true;
        $.totalBorrowed -= principal;
        $.activeLoanCount--;
        _clearActiveLoans($, tokenIds);

        // Split interest between lenders and protocol.
        _distributeInterest($, interest);

        // ---- External interactions ----
        $.paymentToken.safeTransferFrom(
            payer,
            address(this),
            principal + interest
        );

        // Unlock all NFTs (Loaned -> Held) and transfer each to the recipient.
        _setAssetStateBatch($, tokenIds, IAssetNFT.AssetState.Held);
        for (uint256 i; i < tokenIds.length; ) {
            $.assetNFT.transferFrom(address(this), recipient, tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        emit LoanRepaid(loanId, borrower, principal, interest);
    }

    /// @dev Shared default-record resolution for `acquireDefaultedAsset` (Phase 1)
    ///      and `purchaseDefaultedAsset` (Phase 2/3). Validates the record exists and
    ///      is unresolved, enforces the phase window, marks it resolved, and re-credits
    ///      the recovered principal to the pool. Returns the collateral token IDs and
    ///      the outstanding value.
    /// @param acquisitionPhase True to require the acquisition window (Phase 1);
    ///        false to require past the acquisition window (Phase 2/3).
    function _loadResolvableDefault(
        AssetLendingPoolStorage storage $,
        uint256 loanId,
        bool acquisitionPhase
    ) private returns (uint256[] memory tokenIds, uint256 outstandingValue) {
        DefaultRecord storage rec = $.defaults[loanId];
        if (rec.defaultedAt == 0) revert AssetLendingPool__DefaultNotFound();
        if (rec.resolved) revert AssetLendingPool__DefaultAlreadyResolved();

        if (acquisitionPhase) {
            if (block.timestamp >= rec.defaultedAt + $.acquisitionWindow)
                revert AssetLendingPool__NotInAcquisitionPhase();
        } else {
            if (block.timestamp < rec.defaultedAt + $.acquisitionWindow)
                revert AssetLendingPool__NotInPurchasePhase();
        }

        tokenIds = rec.tokenIds;
        outstandingValue = rec.outstandingValue;

        rec.resolved = true;

        // Re-credit the pool with the recovered principal.
        $.totalDeposited += outstandingValue;
        $.totalDefaultedPrincipal -= outstandingValue;
    }

    function _requireActiveLoan(
        AssetLendingPoolStorage storage $,
        uint256 loanId
    ) private view returns (Loan storage loan) {
        loan = $.loans[loanId];
        if (loan.loanId == 0) revert AssetLendingPool__LoanNotFound();
        if (loan.isPaid) revert AssetLendingPool__LoanAlreadyPaid();
        if (loan.isDefaulted) revert AssetLendingPool__LoanAlreadyDefaulted();
    }

    function _collectOriginationFee(
        AssetLendingPoolStorage storage $,
        uint256 principal
    ) private returns (uint256 fee) {
        fee = _calculateOriginationFee($, principal);
        if (fee > 0) {
            $.paymentToken.safeTransfer($.feeWallet, fee);
        }
    }

    /// @dev Shared borrow core used by both `borrow` (single-asset) and `borrowBundle`.
    ///      All validations run before any NFT is pulled or state is mutated.
    function _borrow(
        uint256[] memory tokenIds,
        uint256 amount,
        uint8 termId
    ) private {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        AssetLendingPoolStorage storage $ = _getStorage();

        TermConfig storage term = $.termConfigs[termId];
        if (!term.active) revert AssetLendingPool__InvalidTerm();

        // Validate all tokens and compute summed appraisal — no state changes yet.
        uint256 summedAppraisal = _validateBundle($, tokenIds);

        uint256 maxLoan = (summedAppraisal * $.ltvBps) / BPS;
        if (amount > maxLoan) revert AssetLendingPool__ExceedsLTV();

        if (amount > $.totalDeposited - $.totalBorrowed) {
            revert AssetLendingPool__InsufficientLiquidity();
        }

        // Pull all NFTs from borrower (each transferFrom enforces Held state via AssetNFT).
        for (uint256 i; i < tokenIds.length; ) {
            $.assetNFT.transferFrom(msg.sender, address(this), tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        _originateLoan($, msg.sender, tokenIds, amount, termId, false);

        // Disburse (minus origination fee)
        uint256 fee = _collectOriginationFee($, amount);
        $.paymentToken.safeTransfer(msg.sender, amount - fee);
    }

    /// @dev Checks that the bundle is non-empty, within MAX_BATCH, each token is individually
    ///      eligible, and none already has an active loan. Returns the summed appraisal value.
    ///      Pure validation — no state mutations, no NFT transfers.
    function _validateBundle(
        AssetLendingPoolStorage storage $,
        uint256[] memory tokenIds
    ) private view returns (uint256 summedAppraisal) {
        uint256 len = tokenIds.length;
        if (len == 0) revert AssetLendingPool__EmptyBundle();
        if (len > MAX_BATCH)
            revert AssetLendingPool__BatchTooLarge(len, MAX_BATCH);
        for (uint256 i; i < len; ) {
            uint256 t = tokenIds[i];
            _checkEligibility($, t);
            if ($.tokenIdToActiveLoan[t] != 0)
                revert AssetLendingPool__ActiveLoanExists();
            summedAppraisal += $.appraisals[t].value;
            unchecked {
                ++i;
            }
        }
    }

    function _originateLoan(
        AssetLendingPoolStorage storage $,
        address borrower,
        uint256[] memory tokenIds,
        uint256 principal,
        uint8 termId,
        bool isMarketplaceFinanced
    ) private returns (uint256 loanId) {
        TermConfig storage term = $.termConfigs[termId];
        uint256 interest =
            (principal * term.aprBps * term.duration) / (YEAR * BPS);
        uint256 expireTime = block.timestamp + term.duration;

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
            isMarketplaceFinanced: isMarketplaceFinanced
        });
        $.borrowerLoans[borrower].push(loanId);

        // Register every collateral token in the active-loan mapping.
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
        AssetLendingPoolStorage storage $ = _getStorage();
        Loan storage loan = _requireActiveLoan($, loanId);

        if (block.timestamp <= loan.expireTime)
            revert AssetLendingPool__LoanNotExpired();

        uint256[] memory tokenIds = loan.tokenIds;
        address borrower = loan.borrower;
        uint256 principal = loan.principal;

        loan.isDefaulted = true;
        $.totalBorrowed -= principal;
        $.totalDeposited -= principal; // pool absorbs loss; re-credited on resolution
        $.activeLoanCount--;
        $.totalDefaultedPrincipal += principal;

        // Clear active-loan mapping for every collateral token
        _clearActiveLoans($, tokenIds);

        // Create the default record to track the lifecycle.
        $.defaults[loanId] = DefaultRecord({
            loanId: loanId,
            tokenIds: tokenIds,
            outstandingValue: principal,
            defaultedAt: block.timestamp,
            resolved: false
        });

        // Transition all NFTs back to Held so they can be transferred during resolution.
        _setAssetStateBatch($, tokenIds, IAssetNFT.AssetState.Held);

        emit LoanDefaulted(loanId, borrower, tokenIds[0]);
        emit DefaultInitiated(loanId, tokenIds[0], principal);
    }

    /// @dev Splits repaid interest between lenders (accInterestPerShare) and protocol (totalInterestEarned).
    function _distributeInterest(
        AssetLendingPoolStorage storage $,
        uint256 interest
    ) private {
        if (interest == 0) return;
        uint256 lenderPortion;
        if ($.totalLenderDeposits > 0 && $.lenderShareBps > 0) {
            lenderPortion = (interest * $.lenderShareBps) / BPS;
            // Accumulate per-share reward (scaled by PRECISION to avoid rounding to zero).
            $.accInterestPerShare +=
                (lenderPortion * PRECISION) / $.totalLenderDeposits;
        }
        $.totalInterestEarned += interest - lenderPortion;
    }

    /// @dev Returns the pending (unclaimed) lender interest for an address.
    function _pendingLenderInterest(
        AssetLendingPoolStorage storage $,
        address lender
    ) private view returns (uint256) {
        uint256 balance = $.lenderDeposits[lender];
        if (balance == 0) return 0;
        return
            (balance * $.accInterestPerShare) / PRECISION -
            $.lenderRewardDebt[lender];
    }

    /// @dev Claims all pending lender interest and resets the reward debt. Returns amount claimed.
    function _claimLenderInterestInternal(
        AssetLendingPoolStorage storage $,
        address lender
    ) private returns (uint256 pending) {
        pending = _pendingLenderInterest($, lender);
        if (pending == 0) return 0;
        $.lenderRewardDebt[lender] += pending;
        $.totalLenderInterestPaid += pending;
        $.paymentToken.safeTransfer(lender, pending);
        emit LenderInterestClaimed(lender, pending);
    }

    /// @dev Adds the new deposit's share of the current accumulator to reward debt
    ///      so only future interest accrual counts toward this lender's new capital.
    ///      Call BEFORE updating the deposit balance.
    function _accrueRewardDebtForDeposit(
        AssetLendingPoolStorage storage $,
        address lender,
        uint256 amount
    ) private {
        $.lenderRewardDebt[lender] +=
            (amount * $.accInterestPerShare) / PRECISION;
    }
}
