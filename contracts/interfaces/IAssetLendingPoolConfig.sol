// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAssetLendingPool} from "./IAssetLendingPool.sol";

/// @title IAssetLendingPoolConfig
/// @notice Interface for the standalone AssetLendingPoolConfig contract.
///         Structs, errors, and runtime events are defined in IAssetLendingPool to keep one
///         canonical type identity across the protocol. Only config-domain events and the
///         config-specific view helpers are declared here.
interface IAssetLendingPoolConfig {
    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice Snapshot of all config fields returned by getConfigSnapshot().
    ///         Used by AssetLendingPool.getPoolInfo() to merge config + runtime in one call.
    struct ConfigSnapshot {
        address paymentToken;
        address assetNFT;
        uint8 termCount;
        uint256 minAppraisalValue;
        uint256 minGrade;
        uint256 originationFeeBps;
        address feeWallet;
        uint256 ltvBps;
        uint256 maxAppraisalAge;
        uint256 lenderShareBps;
        bool lenderDepositsEnabled;
        uint256 acquisitionWindow;
        uint256 auctionWindow;
        uint256 maxUtilizationBps;
    }

    // =========================================================================
    // Config-domain events (emitted by this contract, not AssetLendingPool)
    // =========================================================================

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
    event MaxUtilizationUpdated(
        uint256 oldMaxUtilization,
        uint256 newMaxUtilization
    );
    event OriginationFeeUpdated(uint256 bps, address wallet);
    event MaxAppraisalAgeUpdated(uint256 oldMaxAge, uint256 newMaxAge);
    event LenderConfigUpdated(uint256 shareBps, bool enabled);
    event DefaultLifecycleConfigUpdated(
        uint256 acquisitionWindow,
        uint256 auctionWindow
    );
    event FinanceWalletUpdated(address indexed newFinanceWallet);
    event PackMachineFactoryUpdated(address factory);
    event DefaultPackMachineUpdated(address machine);
    event TokenTierSet(uint256 indexed tokenId, uint8 tier);
    event MarketplaceUpdated(address indexed marketplace);

    // =========================================================================
    // Admin setters
    // =========================================================================

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

    function setMaxUtilizationBps(uint256 newMaxUtilization) external;

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

    function setFinanceWallet(address wallet) external;

    function setMarketplace(address marketplace_) external;

    // =========================================================================
    // Config getters
    // =========================================================================

    function getAppraisal(
        uint256 tokenId
    ) external view returns (IAssetLendingPool.AssetAppraisal memory);

    function getTermConfig(
        uint8 termId
    ) external view returns (IAssetLendingPool.TermConfig memory);

    function getMaxLoanAmount(uint256 tokenId) external view returns (uint256);

    function isEligible(uint256 tokenId) external view returns (bool);

    function getMarketplace() external view returns (address);

    function getFinanceWallet() external view returns (address);

    // =========================================================================
    // Scalar field getters
    // =========================================================================

    function paymentToken() external view returns (address);

    function assetNFT() external view returns (address);

    function ltvBps() external view returns (uint256);

    function maxUtilizationBps() external view returns (uint256);

    function feeWallet() external view returns (address);

    function originationFeeBps() external view returns (uint256);

    function lenderShareBps() external view returns (uint256);

    function lenderDepositsEnabled() external view returns (bool);

    function acquisitionWindow() external view returns (uint256);

    function auctionWindow() external view returns (uint256);

    function packMachineFactory() external view returns (address);

    function defaultPackMachine() external view returns (address);

    function defaultTokenTier(uint256 tokenId) external view returns (uint8);

    function minAppraisalValue() external view returns (uint256);

    function minGrade() external view returns (uint256);

    function maxAppraisalAge() external view returns (uint256);

    function termCount() external view returns (uint8);

    // =========================================================================
    // Batch / composite helpers (called by AssetLendingPool to minimize cross-
    // contract calls on hot paths)
    // =========================================================================

    /// @notice Checks eligibility for every token in the bundle and returns the
    ///         sum of their appraised values. Reverts with the same errors as
    ///         the per-token checkEligibility() if any token fails. Does NOT
    ///         check tokenIdToActiveLoan (runtime state — the pool keeps that loop).
    /// @param tokenIds AssetNFT token IDs to validate.
    /// @return summedAppraisal Sum of appraisal values across all tokens.
    function validateBundleAndSumAppraisals(
        uint256[] calldata tokenIds
    ) external view returns (uint256 summedAppraisal);

    /// @notice Single-token eligibility check that reverts on failure.
    ///         Mirrors the old internal _checkEligibility helper.
    function checkEligibility(uint256 tokenId) external view;

    /// @notice Returns the origination fee for a given principal amount.
    ///         Returns 0 when originationFeeBps is 0.
    function calculateOriginationFee(
        uint256 principal
    ) external view returns (uint256);

    /// @notice Returns a snapshot of all config fields needed by
    ///         AssetLendingPool.getPoolInfo() in a single external call.
    function getConfigSnapshot()
        external
        view
        returns (ConfigSnapshot memory);
}
