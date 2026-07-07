// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IAssetNFT} from "./interfaces/IAssetNFT.sol";
import {IAssetLendingPool} from "./interfaces/IAssetLendingPool.sol";
import {IAssetLendingPoolConfig} from "./interfaces/IAssetLendingPoolConfig.sol";
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title AssetLendingPoolConfig
/// @author NettyWorth
/// @notice Standalone UUPS-upgradeable contract that stores all admin-controlled
///         configuration for AssetLendingPool. Business logic and runtime accounting
///         live in AssetLendingPool; this contract owns only the config storage and
///         exposes setters + view helpers for the pool to consume via IAssetLendingPoolConfig.
/// @dev Errors and shared structs (TermConfig, AssetAppraisal) are defined in
///      IAssetLendingPool to maintain a single canonical type identity across the protocol.
/// @custom:security-contact security@nettyworth.io
contract AssetLendingPoolConfig is
    IAssetLendingPoolConfig,
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable
{
    // =========================================================================
    // Constants
    // =========================================================================

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_BATCH = 50;
    /// @dev Default minimum appraisal value in whole payment-token units ($5).
    ///      Scaled by paymentToken.decimals() in the initializer. Admin-adjustable afterward.
    uint256 internal constant DEFAULT_MIN_APPRAISAL_UNITS = 5;

    // =========================================================================
    // Storage (ERC-7201 namespaced) — config fields only; no runtime state
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.AssetLendingPoolConfig
    struct ConfigStorage {
        IERC20 paymentToken;
        IAssetNFT assetNFT;
        // Term configs
        mapping(uint8 termId => IAssetLendingPool.TermConfig) termConfigs;
        uint8 termCount;
        // Appraisals
        mapping(uint256 tokenId => IAssetLendingPool.AssetAppraisal) appraisals;
        // Eligibility
        uint256 minAppraisalValue;
        uint256 minGrade;
        mapping(uint256 categoryId => bool) eligibleCategories;
        // Fee
        uint256 originationFeeBps;
        address feeWallet;
        // LTV
        uint256 ltvBps;
        // Staleness
        uint256 maxAppraisalAge; // 0 = disabled
        // Lender config
        uint256 lenderShareBps;
        bool lenderDepositsEnabled;
        // Default lifecycle windows
        uint256 acquisitionWindow;
        uint256 auctionWindow;
        // PackMachine integration
        address packMachineFactory;
        address defaultPackMachine;
        mapping(uint256 tokenId => uint8) defaultTokenTiers;
        // Marketplace integration
        address marketplace;
        // Maximum pool utilization cap
        uint256 maxUtilizationBps;
        // Finance wallet (Phase-1 acquisition cash leg)
        address financeWallet;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.AssetLendingPoolConfig")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASSET_LENDING_POOL_CONFIG_STORAGE_SLOT =
        0x44360b8816dcda47227a5f760c5ec3f2cdf3eef6a97dfd570813ac50da6e4200;

    function _getConfigStorage()
        internal
        pure
        returns (ConfigStorage storage $)
    {
        assembly {
            $.slot := ASSET_LENDING_POOL_CONFIG_STORAGE_SLOT
        }
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

    /// @notice Initializes the config proxy with default values.
    /// @param initialOwner_ Address to receive ownership (admin controls all setters).
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
        if (initialOwner_ == address(0))
            revert IAssetLendingPool.AssetLendingPool__ZeroAddress();
        if (paymentToken_ == address(0))
            revert IAssetLendingPool.AssetLendingPool__ZeroAddress();
        if (assetNFT_ == address(0))
            revert IAssetLendingPool.AssetLendingPool__ZeroAddress();
        if (ltvBps_ == 0 || ltvBps_ > BPS)
            revert IAssetLendingPool.AssetLendingPool__InvalidLTV();
        if (lenderShareBps_ > BPS)
            revert IAssetLendingPool.AssetLendingPool__InvalidBps();

        __Ownable_init(initialOwner_);
        __Ownable2Step_init();

        ConfigStorage storage $ = _getConfigStorage();
        $.paymentToken = IERC20(paymentToken_);
        $.assetNFT = IAssetNFT(assetNFT_);
        $.ltvBps = ltvBps_;

        // Default $100 minimum appraisal value, scaled to the payment token's decimals.
        uint8 dec = IERC20Metadata(paymentToken_).decimals();
        $.minAppraisalValue = DEFAULT_MIN_APPRAISAL_UNITS * (10 ** dec);
        $.maxAppraisalAge = 7 days;

        // Initialize default term configs: 7d/10%, 15d/15%, 30d/20%
        $.termConfigs[0] = IAssetLendingPool.TermConfig({
            duration: 7 days,
            aprBps: 1000,
            active: true
        });
        $.termConfigs[1] = IAssetLendingPool.TermConfig({
            duration: 15 days,
            aprBps: 1500,
            active: true
        });
        $.termConfigs[2] = IAssetLendingPool.TermConfig({
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
        // 80% maximum utilization by default; 20% reserved for lender withdrawals
        $.maxUtilizationBps = 8000;
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // =========================================================================
    // Admin: appraisals
    // =========================================================================

    /// @notice Record or update an appraisal for a single AssetNFT token.
    /// @dev onlyOwner. Resets the `updatedAt` staleness clock.
    /// @param tokenId AssetNFT token ID to appraise.
    /// @param value Appraised fair-market value in payment-token units.
    /// @param grade Numeric condition grade (higher is better).
    /// @param category Protocol category ID; 0 = uncategorized.
    function setAppraisal(
        uint256 tokenId,
        uint256 value,
        uint256 grade,
        uint256 category
    ) external override onlyOwner {
        _setAppraisal(_getConfigStorage(), tokenId, value, grade, category);
    }

    /// @notice Batch-update appraisals for up to 50 tokens in one transaction.
    /// @dev onlyOwner. All four arrays must be the same length; max length is MAX_BATCH (50).
    function batchSetAppraisals(
        uint256[] calldata tokenIds,
        uint256[] calldata values,
        uint256[] calldata grades,
        uint256[] calldata categories
    ) external override onlyOwner {
        uint256 len = tokenIds.length;
        if (len > MAX_BATCH)
            revert IAssetLendingPool.AssetLendingPool__BatchTooLarge(
                len,
                MAX_BATCH
            );
        if (
            len != values.length ||
            len != grades.length ||
            len != categories.length
        ) {
            revert IAssetLendingPool.AssetLendingPool__ArrayLengthMismatch();
        }
        ConfigStorage storage $ = _getConfigStorage();
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
    /// @dev onlyOwner.
    function setTermConfig(
        uint8 termId,
        uint256 duration,
        uint256 aprBps,
        bool active
    ) external override onlyOwner {
        if (duration == 0)
            revert IAssetLendingPool.AssetLendingPool__ZeroAmount();
        ConfigStorage storage $ = _getConfigStorage();
        $.termConfigs[termId] = IAssetLendingPool.TermConfig({
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
    /// @dev onlyOwner.
    function setEligibilityControls(
        uint256 minAppraisalValue_,
        uint256 minGrade_,
        uint256[] calldata addCategories,
        uint256[] calldata removeCategories
    ) external override onlyOwner {
        ConfigStorage storage $ = _getConfigStorage();
        $.minAppraisalValue = minAppraisalValue_;
        $.minGrade = minGrade_;
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
        emit EligibilityControlsUpdated(minAppraisalValue_, minGrade_);
    }

    /// @notice Update the loan-to-value ratio applied to all future loans.
    /// @dev onlyOwner.
    function setLtvBps(uint256 newLtv) external override onlyOwner {
        if (newLtv == 0 || newLtv > BPS)
            revert IAssetLendingPool.AssetLendingPool__InvalidLTV();
        ConfigStorage storage $ = _getConfigStorage();
        emit LtvUpdated($.ltvBps, newLtv);
        $.ltvBps = newLtv;
    }

    /// @notice Set the maximum fraction of pool capital that may be committed to active loans.
    /// @dev onlyOwner.
    function setMaxUtilizationBps(
        uint256 newMaxUtilization
    ) external override onlyOwner {
        if (newMaxUtilization == 0 || newMaxUtilization > BPS)
            revert IAssetLendingPool.AssetLendingPool__InvalidBps();
        ConfigStorage storage $ = _getConfigStorage();
        emit MaxUtilizationUpdated($.maxUtilizationBps, newMaxUtilization);
        $.maxUtilizationBps = newMaxUtilization;
    }

    /// @notice Set the origination fee charged on each loan at disbursement.
    /// @dev onlyOwner.
    function setOriginationFee(
        uint256 bps,
        address wallet
    ) external override onlyOwner {
        if (bps > BPS) revert IAssetLendingPool.AssetLendingPool__InvalidBps();
        if (bps > 0 && wallet == address(0))
            revert IAssetLendingPool.AssetLendingPool__ZeroAddress();
        ConfigStorage storage $ = _getConfigStorage();
        $.originationFeeBps = bps;
        $.feeWallet = wallet;
        emit OriginationFeeUpdated(bps, wallet);
    }

    /// @notice Set the maximum allowed age for an appraisal before it is considered stale.
    /// @dev onlyOwner. Pass 0 to disable staleness checking.
    function setMaxAppraisalAge(uint256 newMaxAge) external override onlyOwner {
        ConfigStorage storage $ = _getConfigStorage();
        emit MaxAppraisalAgeUpdated($.maxAppraisalAge, newMaxAge);
        $.maxAppraisalAge = newMaxAge;
    }

    // =========================================================================
    // Admin: lender config
    // =========================================================================

    /// @notice Configure the lender interest share and enable/disable external deposits.
    /// @dev onlyOwner.
    function setLenderConfig(
        uint256 shareBps,
        bool enabled
    ) external override onlyOwner {
        if (shareBps > BPS)
            revert IAssetLendingPool.AssetLendingPool__InvalidBps();
        ConfigStorage storage $ = _getConfigStorage();
        $.lenderShareBps = shareBps;
        $.lenderDepositsEnabled = enabled;
        emit LenderConfigUpdated(shareBps, enabled);
    }

    // =========================================================================
    // Admin: default lifecycle config
    // =========================================================================

    /// @notice Set the durations for Phase 1 (acquisition) and Phase 2 (auction).
    /// @dev onlyOwner.
    function setDefaultLifecycleConfig(
        uint256 acquisitionWindow_,
        uint256 auctionWindow_
    ) external override onlyOwner {
        ConfigStorage storage $ = _getConfigStorage();
        $.acquisitionWindow = acquisitionWindow_;
        $.auctionWindow = auctionWindow_;
        emit DefaultLifecycleConfigUpdated(acquisitionWindow_, auctionWindow_);
    }

    /// @notice Set the PackMachineFactory address used to validate target machines.
    /// @dev onlyOwner.
    function setPackMachineFactory(
        address factory_
    ) external override onlyOwner {
        if (factory_ == address(0))
            revert IAssetLendingPool.AssetLendingPool__ZeroAddress();
        _getConfigStorage().packMachineFactory = factory_;
        emit PackMachineFactoryUpdated(factory_);
    }

    /// @notice Set the default PackMachine for recycling acquired defaulted assets.
    /// @dev onlyOwner. Pass address(0) to clear the default machine.
    function setDefaultPackMachine(
        address machine_
    ) external override onlyOwner {
        _getConfigStorage().defaultPackMachine = machine_;
        emit DefaultPackMachineUpdated(machine_);
    }

    /// @notice Record the rarity tier for a token.
    /// @dev onlyOwner.
    function setTokenTier(
        uint256 tokenId,
        uint8 tier
    ) external override onlyOwner {
        _getConfigStorage().defaultTokenTiers[tokenId] = tier;
        emit TokenTierSet(tokenId, tier);
    }

    /// @notice Batch version of setTokenTier (max 50 tokens per call).
    /// @dev onlyOwner.
    function batchSetTokenTiers(
        uint256[] calldata tokenIds,
        uint8[] calldata tiers
    ) external override onlyOwner {
        uint256 len = tokenIds.length;
        if (len > MAX_BATCH)
            revert IAssetLendingPool.AssetLendingPool__BatchTooLarge(
                len,
                MAX_BATCH
            );
        if (len != tiers.length)
            revert IAssetLendingPool.AssetLendingPool__ArrayLengthMismatch();
        ConfigStorage storage $ = _getConfigStorage();
        for (uint256 i; i < len; ) {
            $.defaultTokenTiers[tokenIds[i]] = tiers[i];
            emit TokenTierSet(tokenIds[i], tiers[i]);
            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // Admin: finance wallet
    // =========================================================================

    /// @notice Set the finance wallet that funds Phase-1 defaulted-asset acquisition.
    /// @dev onlyOwner.
    function setFinanceWallet(address wallet) external override onlyOwner {
        if (wallet == address(0))
            revert IAssetLendingPool.AssetLendingPool__ZeroAddress();
        _getConfigStorage().financeWallet = wallet;
        emit FinanceWalletUpdated(wallet);
    }

    // =========================================================================
    // Admin: marketplace
    // =========================================================================

    /// @notice Set the authorized marketplace contract address.
    /// @dev onlyOwner.
    function setMarketplace(address marketplace_) external override onlyOwner {
        if (marketplace_ == address(0))
            revert IAssetLendingPool.AssetLendingPool__ZeroAddress();
        _getConfigStorage().marketplace = marketplace_;
        emit MarketplaceUpdated(marketplace_);
    }

    // =========================================================================
    // Config view functions
    // =========================================================================

    function getAppraisal(
        uint256 tokenId
    ) external view override returns (IAssetLendingPool.AssetAppraisal memory) {
        return _getConfigStorage().appraisals[tokenId];
    }

    function getTermConfig(
        uint8 termId
    ) external view override returns (IAssetLendingPool.TermConfig memory) {
        return _getConfigStorage().termConfigs[termId];
    }

    function getMaxLoanAmount(
        uint256 tokenId
    ) external view override returns (uint256) {
        ConfigStorage storage $ = _getConfigStorage();
        return ($.appraisals[tokenId].value * $.ltvBps) / BPS;
    }

    function isEligible(uint256 tokenId) external view override returns (bool) {
        return _isEligible(_getConfigStorage(), tokenId);
    }

    function getMarketplace() external view override returns (address) {
        return _getConfigStorage().marketplace;
    }

    function getFinanceWallet() external view override returns (address) {
        return _getConfigStorage().financeWallet;
    }

    // =========================================================================
    // Scalar field getters
    // =========================================================================

    function paymentToken() external view override returns (address) {
        return address(_getConfigStorage().paymentToken);
    }

    function assetNFT() external view override returns (address) {
        return address(_getConfigStorage().assetNFT);
    }

    function ltvBps() external view override returns (uint256) {
        return _getConfigStorage().ltvBps;
    }

    function maxUtilizationBps() external view override returns (uint256) {
        return _getConfigStorage().maxUtilizationBps;
    }

    function feeWallet() external view override returns (address) {
        return _getConfigStorage().feeWallet;
    }

    function originationFeeBps() external view override returns (uint256) {
        return _getConfigStorage().originationFeeBps;
    }

    function lenderShareBps() external view override returns (uint256) {
        return _getConfigStorage().lenderShareBps;
    }

    function lenderDepositsEnabled() external view override returns (bool) {
        return _getConfigStorage().lenderDepositsEnabled;
    }

    function acquisitionWindow() external view override returns (uint256) {
        return _getConfigStorage().acquisitionWindow;
    }

    function auctionWindow() external view override returns (uint256) {
        return _getConfigStorage().auctionWindow;
    }

    function packMachineFactory() external view override returns (address) {
        return _getConfigStorage().packMachineFactory;
    }

    function defaultPackMachine() external view override returns (address) {
        return _getConfigStorage().defaultPackMachine;
    }

    function defaultTokenTier(
        uint256 tokenId
    ) external view override returns (uint8) {
        return _getConfigStorage().defaultTokenTiers[tokenId];
    }

    function minAppraisalValue() external view override returns (uint256) {
        return _getConfigStorage().minAppraisalValue;
    }

    function minGrade() external view override returns (uint256) {
        return _getConfigStorage().minGrade;
    }

    function maxAppraisalAge() external view override returns (uint256) {
        return _getConfigStorage().maxAppraisalAge;
    }

    function termCount() external view override returns (uint8) {
        return _getConfigStorage().termCount;
    }

    // =========================================================================
    // Composite helpers (minimize external calls from AssetLendingPool)
    // =========================================================================

    /// @inheritdoc IAssetLendingPoolConfig
    function validateBundleAndSumAppraisals(
        uint256[] calldata tokenIds
    ) external view override returns (uint256 summedAppraisal) {
        uint256 len = tokenIds.length;
        if (len == 0) revert IAssetLendingPool.AssetLendingPool__EmptyBundle();
        if (len > MAX_BATCH)
            revert IAssetLendingPool.AssetLendingPool__BatchTooLarge(
                len,
                MAX_BATCH
            );
        ConfigStorage storage $ = _getConfigStorage();
        for (uint256 i; i < len; ) {
            uint256 t = tokenIds[i];
            _checkEligibility($, t);
            summedAppraisal += $.appraisals[t].value;
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc IAssetLendingPoolConfig
    function checkEligibility(uint256 tokenId) external view override {
        _checkEligibility(_getConfigStorage(), tokenId);
    }

    /// @inheritdoc IAssetLendingPoolConfig
    function calculateOriginationFee(
        uint256 principal
    ) external view override returns (uint256) {
        return _calculateOriginationFee(_getConfigStorage(), principal);
    }

    /// @inheritdoc IAssetLendingPoolConfig
    function getConfigSnapshot()
        external
        view
        override
        returns (ConfigSnapshot memory snap)
    {
        ConfigStorage storage $ = _getConfigStorage();
        snap.paymentToken = address($.paymentToken);
        snap.assetNFT = address($.assetNFT);
        snap.termCount = $.termCount;
        snap.minAppraisalValue = $.minAppraisalValue;
        snap.minGrade = $.minGrade;
        snap.originationFeeBps = $.originationFeeBps;
        snap.feeWallet = $.feeWallet;
        snap.ltvBps = $.ltvBps;
        snap.maxAppraisalAge = $.maxAppraisalAge;
        snap.lenderShareBps = $.lenderShareBps;
        snap.lenderDepositsEnabled = $.lenderDepositsEnabled;
        snap.acquisitionWindow = $.acquisitionWindow;
        snap.auctionWindow = $.auctionWindow;
        snap.maxUtilizationBps = $.maxUtilizationBps;
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    function _setAppraisal(
        ConfigStorage storage $,
        uint256 tokenId,
        uint256 value,
        uint256 grade,
        uint256 category
    ) internal {
        $.appraisals[tokenId] = IAssetLendingPool.AssetAppraisal({
            value: value,
            grade: grade,
            category: category,
            updatedAt: block.timestamp
        });
        emit AppraisalSet(tokenId, value, grade, category);
    }

    function _isEligible(
        ConfigStorage storage $,
        uint256 tokenId
    ) internal view returns (bool) {
        IAssetLendingPool.AssetAppraisal storage appraisal = $.appraisals[
            tokenId
        ];
        if (appraisal.updatedAt == 0) return false;
        if (appraisal.value < $.minAppraisalValue) return false;
        if (appraisal.grade < $.minGrade) return false;
        if (
            !$.eligibleCategories[appraisal.category] && appraisal.category != 0
        ) {
            return false;
        }
        return true;
    }

    function _checkEligibility(
        ConfigStorage storage $,
        uint256 tokenId
    ) internal view {
        IAssetLendingPool.AssetAppraisal storage appraisal = $.appraisals[
            tokenId
        ];
        if (appraisal.updatedAt == 0)
            revert IAssetLendingPool.AssetLendingPool__NoAppraisal();
        uint256 maxAge = $.maxAppraisalAge;
        if (maxAge != 0 && block.timestamp - appraisal.updatedAt > maxAge) {
            revert IAssetLendingPool.AssetLendingPool__AppraisalStale(
                tokenId,
                appraisal.updatedAt,
                maxAge
            );
        }
        if (!_isEligible($, tokenId))
            revert IAssetLendingPool.AssetLendingPool__IneligibleAsset();
    }

    function _calculateOriginationFee(
        ConfigStorage storage $,
        uint256 principal
    ) internal view returns (uint256) {
        if ($.originationFeeBps == 0) return 0;
        return (principal * $.originationFeeBps) / BPS;
    }
}
