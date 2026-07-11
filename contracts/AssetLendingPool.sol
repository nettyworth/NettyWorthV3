// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAssetNFT} from "./interfaces/IAssetNFT.sol";
import {IAssetLendingPool} from "./interfaces/IAssetLendingPool.sol";
import {IAssetLendingPoolConfig} from "./interfaces/IAssetLendingPoolConfig.sol";
import {INettyWorthMarketplace} from "./interfaces/INettyWorthMarketplace.sol";
import {AssetLendingPoolStorageLib} from "./lib/AssetLendingPoolStorageLib.sol";
import {LendingLib} from "./lib/LendingLib.sol";

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
///      Heavy logic is offloaded to LendingLib (deployed externally, called via DELEGATECALL)
///      so this contract stays under the EIP-170 24,576-byte bytecode limit.
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

    uint256 private constant BPS = 10_000;

    // =========================================================================
    // Storage (ERC-7201 namespaced) — runtime state only; config lives in
    // the separate AssetLendingPoolConfig contract.
    // Layout defined in AssetLendingPoolStorageLib — both this contract and
    // LendingLib import that file to share the identical struct at the same slot.
    // =========================================================================

    function _getStorage()
        internal
        pure
        returns (AssetLendingPoolStorageLib.PoolStorage storage $)
    {
        return AssetLendingPoolStorageLib.getStorage();
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

        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
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
        LendingLib.borrow(_getStorage(), ids, amount, termId, msg.sender);
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
        LendingLib.borrow(_getStorage(), tokenIds, amount, termId, msg.sender);
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
        LendingLib.settleLoanRepayment(
            _getStorage(),
            loanId,
            msg.sender,
            msg.sender,
            msg.sender
        );
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

        (
            uint256 principal,
            uint256 interest,
            address borrower
        ) = LendingLib.settleLoanRepayment(
            _getStorage(),
            loanId,
            payer,
            buyer,
            address(0)
        );

        emit LoanSettledOnSale(loanId, borrower, buyer, principal + interest);
    }

    // =========================================================================
    // Borrower: financeMarketplacePurchase
    // =========================================================================

    /// @inheritdoc IAssetLendingPool
    function financeMarketplacePurchase(
        INettyWorthMarketplace.SignedListing calldata listing,
        bytes calldata sig,
        uint256 depositAmount,
        uint8 termId
    ) external override nonReentrant whenNotPaused {
        // Guard against self-financing: the pool cannot be both seller and lender (M009 fix).
        if (listing.seller == address(this))
            revert AssetLendingPool__InvalidSeller();

        LendingLib.financeMarketplacePurchase(
            _getStorage(),
            listing,
            sig,
            depositAmount,
            termId,
            msg.sender
        );
    }

    /// @inheritdoc IAssetLendingPool
    /// @dev Self-service nonce revocation — intentionally omits whenNotPaused so sellers
    ///      can always revoke a leaked listing signature even while the pool is paused.
    ///      Reuses AssetLendingPool__ListingNonceUsed for already-consumed/cancelled nonces,
    ///      consistent with the consume path in financeMarketplacePurchase (H010 fix).
    function cancelFinanceNonce(uint256 nonce) external override {
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
        if ($.financeNonces[msg.sender][nonce]) {
            revert AssetLendingPool__ListingNonceUsed();
        }
        $.financeNonces[msg.sender][nonce] = true;
        emit FinanceNonceCancelled(msg.sender, nonce);
    }

    /// @inheritdoc IAssetLendingPool
    function isFinanceNonceUsed(
        address seller,
        uint256 nonce
    ) external view override returns (bool) {
        return _getStorage().financeNonces[seller][nonce];
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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
        if (!$.config.lenderDepositsEnabled())
            revert AssetLendingPool__LenderDepositsDisabled();

        LendingLib.accrueRewardDebtForDeposit($, msg.sender, amount);

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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();

        if (amount > $.lenderDeposits[msg.sender])
            revert AssetLendingPool__InsufficientLenderBalance();

        uint256 available = $.totalDeposited - $.totalBorrowed;
        if (amount > available)
            revert AssetLendingPool__InsufficientLiquidity();

        LendingLib.claimLenderInterestInternal($, msg.sender);

        uint256 newBalance = $.lenderDeposits[msg.sender] - amount;
        $.lenderRewardDebt[msg.sender] =
            (newBalance * $.accInterestPerShare) / 1e18;

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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
        uint256 claimed = LendingLib.claimLenderInterestInternal($, msg.sender);
        if (claimed == 0) revert AssetLendingPool__NoInterestToClaim();
    }

    // =========================================================================
    // Admin: pool funding
    // =========================================================================

    /// @notice Fund the pool from treasury.
    function deposit(uint256 amount) external override onlyOwner {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
        $.ownerDeposited += amount;
        $.totalDeposited += amount;
        $.paymentToken.safeTransferFrom(msg.sender, address(this), amount);
        emit PoolFunded(amount, $.totalDeposited);
    }

    /// @notice Withdraw owner-deposited (unborrowed) capital.
    function withdraw(uint256 amount) external override onlyOwner {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
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
        LendingLib.initiateDefault(_getStorage(), loanId);
    }

    /// @notice Backward-compatible alias for initiateDefault().
    function liquidate(uint256 loanId) external override onlyOwner {
        LendingLib.initiateDefault(_getStorage(), loanId);
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
        LendingLib.acquireDefaultedAsset(_getStorage(), loanId, targetPackMachine, tier);
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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
        DefaultRecord storage rec = $.defaults[loanId];

        if (rec.defaultedAt == 0) revert AssetLendingPool__DefaultNotFound();
        if (rec.resolved) revert AssetLendingPool__DefaultAlreadyResolved();
        if (block.timestamp < rec.defaultedAt + rec.acquisitionWindow)
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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();

        {
            DefaultRecord storage rec = $.defaults[loanId];
            if (!rec.listedOnMarketplace)
                revert AssetLendingPool__DefaultNotListed();
        }

        (
            uint256[] memory tokenIds,
            uint256 principal,
            uint256 interest
        ) = LendingLib.resolveAndRecredit($, loanId);

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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
        return $.totalDeposited - $.totalBorrowed;
    }

    function getPoolInfo()
        external
        view
        override
        returns (PoolInfo memory info)
    {
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
        DefaultRecord storage rec = $.defaults[loanId];
        if (rec.defaultedAt == 0) return DefaultPhase.None;
        if (rec.resolved) return DefaultPhase.Resolved;
        uint256 elapsed = block.timestamp - rec.defaultedAt;
        uint256 acqW = rec.acquisitionWindow;
        uint256 aucW = rec.auctionWindow;
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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
        info.deposited = $.lenderDeposits[lender];
        info.claimableInterest = LendingLib.pendingLenderInterest($, lender);
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
        AssetLendingPoolStorageLib.PoolStorage storage $ = _getStorage();
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
}
