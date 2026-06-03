// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IAssetNFT} from "./interfaces/IAssetNFT.sol";
import {IAssetLendingPool} from "./interfaces/IAssetLendingPool.sol";
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title AssetLendingPoolConfig
/// @author NettyWorth
/// @notice Abstract base contract that owns the ERC-7201 storage layout, all admin
///         configuration setters, and the pure config-read internal helpers for
///         AssetLendingPool. Business logic lives in the concrete contract.
/// @dev Inherits IAssetLendingPool so config functions can carry `override`. The
///      concrete AssetLendingPool contract re-declares `is IAssetLendingPool` (legal
///      in Solidity) and implements the remaining interface functions.
abstract contract AssetLendingPoolConfig is
    IAssetLendingPool,
    Initializable,
    Ownable2StepUpgradeable
{
    // =========================================================================
    // Constants (config-relevant; business-only constants live in the concrete contract)
    // =========================================================================

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_BATCH = 50;
    /// @dev Default minimum appraisal value in whole payment-token units ($100).
    ///      Scaled by paymentToken.decimals() in the initializer. Admin-adjustable afterward.
    uint256 internal constant DEFAULT_MIN_APPRAISAL_UNITS = 100;

    // =========================================================================
    // Storage (ERC-7201) — single unified struct; layout must never change
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.AssetLendingPool
    struct AssetLendingPoolStorage {
        IERC20 paymentToken;
        IAssetNFT assetNFT;
        // Term configs
        mapping(uint8 termId => TermConfig) termConfigs;
        uint8 termCount;
        // Loans
        uint256 nextLoanId;
        mapping(uint256 loanId => Loan) loans;
        mapping(address borrower => uint256[]) borrowerLoans;
        mapping(uint256 tokenId => uint256 loanId) tokenIdToActiveLoan;
        // Appraisals
        mapping(uint256 tokenId => AssetAppraisal) appraisals;
        // Eligibility
        uint256 minAppraisalValue;
        uint256 minGrade;
        mapping(uint256 categoryId => bool) eligibleCategories;
        // Pool financial (protocol/owner capital)
        uint256 totalDeposited;
        uint256 totalBorrowed;
        uint256 totalInterestEarned; // protocol-only interest (excludes lender share)
        uint256 interestWithdrawn;
        uint256 activeLoanCount;
        // Fee
        uint256 originationFeeBps;
        address feeWallet;
        // LTV
        uint256 ltvBps;
        // Staleness
        uint256 maxAppraisalAge; // 0 = disabled
        // =====================================================================
        // V2: External Lender Capital
        // =====================================================================
        mapping(address lender => uint256) lenderDeposits;
        uint256 totalLenderDeposits;
        uint256 lenderShareBps; // e.g. 8000 = lenders get 80% of interest
        bool lenderDepositsEnabled;
        uint256 ownerDeposited; // tracks admin's own capital separately from lender capital
        // Reward-per-share accounting (Synthetix pattern, scaled by PRECISION)
        uint256 accInterestPerShare; // accumulated lender interest per unit deposited
        mapping(address lender => uint256) lenderRewardDebt;
        uint256 totalLenderInterestPaid; // total interest paid out to lenders
        // =====================================================================
        // V2: Default Lifecycle
        // =====================================================================
        mapping(uint256 loanId => DefaultRecord) defaults;
        uint256 acquisitionWindow; // Phase 1 duration (default 24 hours)
        uint256 auctionWindow; // Phase 2 duration (default 7 days)
        uint256 totalDefaultedPrincipal; // unrecovered principal across all active defaults
        // =====================================================================
        // V2: PackMachine Integration
        // =====================================================================
        address packMachineFactory;
        address defaultPackMachine;
        mapping(uint256 tokenId => uint8) defaultTokenTiers;
        // =====================================================================
        // V3: Marketplace Integration
        // =====================================================================
        /// @dev Address of the authorized marketplace contract allowed to call settleLoanRepaymentOnSale.
        address marketplace;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.AssetLendingPool")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASSET_LENDING_POOL_STORAGE_SLOT =
        0xc51d85cdfca26408bedc9203b8e293ed787f8c84ae3aab3bfb78650d9d676d00;

    function _getStorage()
        internal
        pure
        returns (AssetLendingPoolStorage storage $)
    {
        assembly {
            $.slot := ASSET_LENDING_POOL_STORAGE_SLOT
        }
    }

    // =========================================================================
    // Config initializer (called by AssetLendingPool.initialize)
    // =========================================================================

    /// @dev Writes all configuration defaults. Called from the concrete initialize().
    ///      Validation of init args happens here so that the concrete initialize() stays
    ///      focused on OZ mixin init calls.
    function __AssetLendingPoolConfig_init(
        address paymentToken_,
        address assetNFT_,
        uint256 ltvBps_,
        uint256 lenderShareBps_,
        uint256 acquisitionWindow_,
        uint256 auctionWindow_,
        address packMachineFactory_
    ) internal onlyInitializing {
        if (paymentToken_ == address(0)) revert AssetLendingPool__ZeroAddress();
        if (assetNFT_ == address(0)) revert AssetLendingPool__ZeroAddress();
        if (ltvBps_ == 0 || ltvBps_ > BPS)
            revert AssetLendingPool__InvalidLTV();
        if (lenderShareBps_ > BPS) revert AssetLendingPool__InvalidBps();

        AssetLendingPoolStorage storage $ = _getStorage();
        $.paymentToken = IERC20(paymentToken_);
        $.assetNFT = IAssetNFT(assetNFT_);
        $.ltvBps = ltvBps_;
        // Default $100 minimum appraisal value, scaled to the payment token's decimals (e.g. 100e6 for USDC).
        // Admin can adjust or disable this via setEligibilityControls(0, ...).
        uint8 dec = IERC20Metadata(paymentToken_).decimals();
        $.minAppraisalValue = DEFAULT_MIN_APPRAISAL_UNITS * (10 ** dec);
        $.nextLoanId = 1;
        $.maxAppraisalAge = 7 days;

        // Initialize default term configs: 7d/10%, 15d/15%, 30d/20%
        $.termConfigs[0] = TermConfig({
            duration: 7 days,
            aprBps: 1000,
            active: true
        });
        $.termConfigs[1] = TermConfig({
            duration: 15 days,
            aprBps: 1500,
            active: true
        });
        $.termConfigs[2] = TermConfig({
            duration: 30 days,
            aprBps: 2000,
            active: true
        });
        $.termCount = 3;

        $.lenderShareBps = lenderShareBps_;
        $.acquisitionWindow = acquisitionWindow_;
        $.auctionWindow = auctionWindow_;
        $.packMachineFactory = packMachineFactory_;
        // lenderDepositsEnabled starts false; admin enables via setLenderConfig
    }

    // =========================================================================
    // Admin: appraisals
    // =========================================================================

    /// @notice Record or update an appraisal for a single AssetNFT token.
    /// @dev onlyOwner. Resets the `updatedAt` staleness clock.
    /// @param tokenId AssetNFT token ID to appraise.
    /// @param value Appraised fair-market value in payment-token units (e.g. USDC with 6 decimals).
    /// @param grade Numeric condition grade (e.g. PSA 1–10 scaled; higher is better).
    /// @param category Protocol category ID; 0 = uncategorized (exempt from category whitelist).
    function setAppraisal(
        uint256 tokenId,
        uint256 value,
        uint256 grade,
        uint256 category
    ) external override onlyOwner {
        _setAppraisal(_getStorage(), tokenId, value, grade, category);
    }

    /// @notice Batch-update appraisals for up to 50 tokens in one transaction.
    /// @dev onlyOwner. All four arrays must be the same length; max length is MAX_BATCH (50).
    /// @param tokenIds AssetNFT token IDs to appraise.
    /// @param values Appraised values in payment-token units, parallel to `tokenIds`.
    /// @param grades Numeric condition grades, parallel to `tokenIds`.
    /// @param categories Category IDs, parallel to `tokenIds`. 0 = uncategorized.
    function batchSetAppraisals(
        uint256[] calldata tokenIds,
        uint256[] calldata values,
        uint256[] calldata grades,
        uint256[] calldata categories
    ) external override onlyOwner {
        uint256 len = tokenIds.length;
        if (len > MAX_BATCH)
            revert AssetLendingPool__BatchTooLarge(len, MAX_BATCH);
        if (
            len != values.length ||
            len != grades.length ||
            len != categories.length
        ) {
            revert AssetLendingPool__ArrayLengthMismatch();
        }
        AssetLendingPoolStorage storage $ = _getStorage();
        for (uint256 i; i < len; ) {
            _setAppraisal($, tokenIds[i], values[i], grades[i], categories[i]);
            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // Admin: term configuration
    // =========================================================================

    /// @notice Create or update a loan term configuration.
    /// @dev onlyOwner. Extending `termCount` is allowed (termId >= current count auto-increments it).
    /// @param termId Index of the term slot to write (0-based; 0/1/2 are the protocol defaults).
    /// @param duration Loan length in seconds (must be > 0).
    /// @param aprBps Annual percentage rate in basis points (e.g. 1000 = 10% APR).
    /// @param active Whether borrowers can select this term.
    function setTermConfig(
        uint8 termId,
        uint256 duration,
        uint256 aprBps,
        bool active
    ) external override onlyOwner {
        if (duration == 0) revert AssetLendingPool__ZeroAmount();
        AssetLendingPoolStorage storage $ = _getStorage();
        $.termConfigs[termId] = TermConfig({
            duration: duration,
            aprBps: aprBps,
            active: active
        });
        if (termId >= $.termCount) $.termCount = termId + 1;
        emit TermConfigUpdated(termId, duration, aprBps, active);
    }

    // =========================================================================
    // Admin: eligibility
    // =========================================================================

    /// @notice Update global eligibility thresholds and the category whitelist.
    /// @dev onlyOwner. Categories are toggled atomically: removes are applied after adds.
    ///      Setting both thresholds to 0 effectively disables value/grade filtering.
    /// @param minAppraisalValue Minimum appraised value (in payment-token units) required for borrowing.
    /// @param minGrade Minimum numeric grade required for borrowing.
    /// @param addCategories Category IDs to mark as eligible collateral.
    /// @param removeCategories Category IDs to mark as ineligible collateral.
    function setEligibilityControls(
        uint256 minAppraisalValue,
        uint256 minGrade,
        uint256[] calldata addCategories,
        uint256[] calldata removeCategories
    ) external override onlyOwner {
        AssetLendingPoolStorage storage $ = _getStorage();
        $.minAppraisalValue = minAppraisalValue;
        $.minGrade = minGrade;
        for (uint256 i; i < addCategories.length; ) {
            $.eligibleCategories[addCategories[i]] = true;
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < removeCategories.length; ) {
            $.eligibleCategories[removeCategories[i]] = false;
            unchecked {
                ++i;
            }
        }
        emit EligibilityControlsUpdated(minAppraisalValue, minGrade);
    }

    /// @notice Update the loan-to-value ratio applied to all future loans.
    /// @dev onlyOwner. Does not affect loans already originated.
    /// @param newLtv New LTV in basis points (1–10000; e.g. 5000 = 50%).
    function setLtvBps(uint256 newLtv) external override onlyOwner {
        if (newLtv == 0 || newLtv > BPS) revert AssetLendingPool__InvalidLTV();
        AssetLendingPoolStorage storage $ = _getStorage();
        emit LtvUpdated($.ltvBps, newLtv);
        $.ltvBps = newLtv;
    }

    /// @notice Set the origination fee charged on each loan at disbursement.
    /// @dev onlyOwner. Fee is deducted from the borrower's disbursement (or pulled from the buyer
    ///      in `financeMarketplacePurchase`). Set `bps` to 0 to disable the fee; `wallet` is
    ///      ignored when `bps` is 0 but must be non-zero when `bps > 0`.
    /// @param bps Fee in basis points (0–10000; e.g. 100 = 1%).
    /// @param wallet Address that receives the collected fee.
    function setOriginationFee(
        uint256 bps,
        address wallet
    ) external override onlyOwner {
        if (bps > BPS) revert AssetLendingPool__InvalidBps();
        if (bps > 0 && wallet == address(0))
            revert AssetLendingPool__ZeroAddress();
        AssetLendingPoolStorage storage $ = _getStorage();
        $.originationFeeBps = bps;
        $.feeWallet = wallet;
        emit OriginationFeeUpdated(bps, wallet);
    }

    /// @notice Set the maximum allowed age for an appraisal before it is considered stale.
    /// @dev onlyOwner. Pass 0 to disable staleness checking entirely (any appraisal age accepted).
    /// @param newMaxAge Maximum age in seconds (e.g. 7 days = 604800). 0 = no staleness check.
    function setMaxAppraisalAge(uint256 newMaxAge) external override onlyOwner {
        AssetLendingPoolStorage storage $ = _getStorage();
        emit MaxAppraisalAgeUpdated($.maxAppraisalAge, newMaxAge);
        $.maxAppraisalAge = newMaxAge;
    }

    // =========================================================================
    // Admin: lender config
    // =========================================================================

    /// @notice Configure the lender interest share and enable/disable external deposits.
    /// @dev onlyOwner. Changes to `shareBps` take effect on the next loan repayment.
    /// @param shareBps Percentage of interest routed to lenders in basis points (e.g. 8000 = 80%).
    /// @param enabled Whether external lender deposits are accepted.
    function setLenderConfig(
        uint256 shareBps,
        bool enabled
    ) external override onlyOwner {
        if (shareBps > BPS) revert AssetLendingPool__InvalidBps();
        AssetLendingPoolStorage storage $ = _getStorage();
        $.lenderShareBps = shareBps;
        $.lenderDepositsEnabled = enabled;
        emit LenderConfigUpdated(shareBps, enabled);
    }

    // =========================================================================
    // Admin: default lifecycle config
    // =========================================================================

    /// @notice Set the durations for Phase 1 (acquisition) and Phase 2 (auction) of the default lifecycle.
    /// @dev onlyOwner. Changes apply to defaults initiated after this call; existing defaults
    ///      retain the windows that were active at the time of `initiateDefault`.
    /// @param acquisitionWindow_ Phase 1 duration in seconds (e.g. 1 days).
    /// @param auctionWindow_ Phase 2 duration in seconds (e.g. 7 days).
    function setDefaultLifecycleConfig(
        uint256 acquisitionWindow_,
        uint256 auctionWindow_
    ) external override onlyOwner {
        AssetLendingPoolStorage storage $ = _getStorage();
        $.acquisitionWindow = acquisitionWindow_;
        $.auctionWindow = auctionWindow_;
        emit DefaultLifecycleConfigUpdated(acquisitionWindow_, auctionWindow_);
    }

    /// @notice Set the PackMachineFactory address used to validate target machines.
    /// @dev onlyOwner. Only machines that pass `IPackMachineFactory.isPackMachine()` may be used
    ///      in `acquireDefaultedAsset`.
    /// @param factory_ New PackMachineFactory proxy address (must be non-zero).
    function setPackMachineFactory(
        address factory_
    ) external override onlyOwner {
        if (factory_ == address(0)) revert AssetLendingPool__ZeroAddress();
        _getStorage().packMachineFactory = factory_;
        emit PackMachineFactoryUpdated(factory_);
    }

    /// @notice Set the default PackMachine for recycling acquired defaulted assets.
    /// @dev onlyOwner. Pass address(0) to clear the default machine (acquisition calls must then
    ///      always specify a target explicitly).
    /// @param machine_ PackMachine clone address (or address(0) to clear).
    function setDefaultPackMachine(
        address machine_
    ) external override onlyOwner {
        _getStorage().defaultPackMachine = machine_;
        emit DefaultPackMachineUpdated(machine_);
    }

    /// @notice Record the rarity tier for a token (used when recycling into a PackMachine).
    /// @dev onlyOwner. The stored tier is passed to `IPackMachine.depositFromPool` during
    ///      `acquireDefaultedAsset` when no explicit tier is provided by the caller.
    /// @param tokenId AssetNFT token ID.
    /// @param tier Rarity tier value understood by the target PackMachine.
    function setTokenTier(
        uint256 tokenId,
        uint8 tier
    ) external override onlyOwner {
        _getStorage().defaultTokenTiers[tokenId] = tier;
        emit TokenTierSet(tokenId, tier);
    }

    /// @notice Batch version of setTokenTier (max 50 tokens per call).
    /// @dev onlyOwner. `tokenIds` and `tiers` must be the same length.
    /// @param tokenIds AssetNFT token IDs.
    /// @param tiers Rarity tier values, parallel to `tokenIds`.
    function batchSetTokenTiers(
        uint256[] calldata tokenIds,
        uint8[] calldata tiers
    ) external override onlyOwner {
        uint256 len = tokenIds.length;
        if (len > MAX_BATCH)
            revert AssetLendingPool__BatchTooLarge(len, MAX_BATCH);
        if (len != tiers.length) revert AssetLendingPool__ArrayLengthMismatch();
        AssetLendingPoolStorage storage $ = _getStorage();
        for (uint256 i; i < len; ) {
            $.defaultTokenTiers[tokenIds[i]] = tiers[i];
            emit TokenTierSet(tokenIds[i], tiers[i]);
            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // V3: Marketplace integration setters + views
    // =========================================================================

    /// @notice Set the authorized marketplace contract address.
    /// @dev onlyOwner. After deploying the marketplace proxy, call this to enable
    ///      the atomic loan-settlement path (settleLoanRepaymentOnSale).
    /// @param marketplace_ Address of the NettyWorthMarketplace proxy.
    function setMarketplace(address marketplace_) external override onlyOwner {
        if (marketplace_ == address(0)) revert AssetLendingPool__ZeroAddress();
        _getStorage().marketplace = marketplace_;
        emit MarketplaceUpdated(marketplace_);
    }

    /// @inheritdoc IAssetLendingPool
    function getMarketplace() external view override returns (address) {
        return _getStorage().marketplace;
    }

    /// @inheritdoc IAssetLendingPool
    function getActiveLoanId(uint256 tokenId) external view override returns (uint256) {
        return _getStorage().tokenIdToActiveLoan[tokenId];
    }

    /// @inheritdoc IAssetLendingPool
    function getLoanDebt(
        uint256 tokenId
    ) external view override returns (uint256 principal, uint256 interest, uint256 total) {
        AssetLendingPoolStorage storage $ = _getStorage();
        uint256 loanId = $.tokenIdToActiveLoan[tokenId];
        if (loanId == 0) return (0, 0, 0);
        Loan storage loan = $.loans[loanId];
        principal = loan.principal;
        interest = loan.interest;
        total = principal + interest;
    }

    // =========================================================================
    // Config view functions
    // =========================================================================

    function getAppraisal(
        uint256 tokenId
    ) external view override returns (AssetAppraisal memory) {
        return _getStorage().appraisals[tokenId];
    }

    function getTermConfig(
        uint8 termId
    ) external view override returns (TermConfig memory) {
        return _getStorage().termConfigs[termId];
    }

    function getMaxLoanAmount(
        uint256 tokenId
    ) external view override returns (uint256) {
        AssetLendingPoolStorage storage $ = _getStorage();
        return ($.appraisals[tokenId].value * $.ltvBps) / BPS;
    }

    function isEligible(uint256 tokenId) external view override returns (bool) {
        return _isEligible(_getStorage(), tokenId);
    }

    // =========================================================================
    // Internal config helpers (shared with business logic in the concrete contract)
    // =========================================================================

    function _setAppraisal(
        AssetLendingPoolStorage storage $,
        uint256 tokenId,
        uint256 value,
        uint256 grade,
        uint256 category
    ) internal {
        $.appraisals[tokenId] = AssetAppraisal({
            value: value,
            grade: grade,
            category: category,
            updatedAt: block.timestamp
        });
        emit AppraisalSet(tokenId, value, grade, category);
    }

    function _isEligible(
        AssetLendingPoolStorage storage $,
        uint256 tokenId
    ) internal view returns (bool) {
        AssetAppraisal storage appraisal = $.appraisals[tokenId];
        if (appraisal.updatedAt == 0) return false;
        if (appraisal.value < $.minAppraisalValue) return false;
        if (appraisal.grade < $.minGrade) return false;
        if (
            !$.eligibleCategories[appraisal.category] && appraisal.category != 0
        ) {
            // If the category is non-zero and not whitelisted, reject
            // (category 0 = uncategorised, allowed unless minGrade/minAppraisal block it)
            return false;
        }
        return true;
    }

    function _checkEligibility(
        AssetLendingPoolStorage storage $,
        uint256 tokenId
    ) internal view {
        AssetAppraisal storage appraisal = $.appraisals[tokenId];
        if (appraisal.updatedAt == 0) revert AssetLendingPool__NoAppraisal();
        uint256 maxAge = $.maxAppraisalAge;
        if (maxAge != 0 && block.timestamp - appraisal.updatedAt > maxAge) {
            revert AssetLendingPool__AppraisalStale(
                tokenId,
                appraisal.updatedAt,
                maxAge
            );
        }
        if (!_isEligible($, tokenId))
            revert AssetLendingPool__IneligibleAsset();
    }

    function _calculateOriginationFee(
        AssetLendingPoolStorage storage $,
        uint256 principal
    ) internal view returns (uint256) {
        if ($.originationFeeBps == 0) return 0;
        return (principal * $.originationFeeBps) / BPS;
    }
}
