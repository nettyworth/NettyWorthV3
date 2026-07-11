// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAssetNFT} from "../interfaces/IAssetNFT.sol";
import {IAssetLendingPool} from "../interfaces/IAssetLendingPool.sol";
import {IAssetLendingPoolConfig} from "../interfaces/IAssetLendingPoolConfig.sol";

/// @title AssetLendingPoolStorageLib
/// @notice Shared ERC-7201 storage struct for AssetLendingPool and its linked libraries.
///         Importing this file gives both the contract and any external library the
///         identical struct layout and the canonical slot accessor.
library AssetLendingPoolStorageLib {
    // =========================================================================
    // Struct
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
        mapping(uint256 loanId => IAssetLendingPool.Loan) loans;
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
        mapping(uint256 loanId => IAssetLendingPool.DefaultRecord) defaults;
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

    // =========================================================================
    // Slot + accessor
    // =========================================================================

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.AssetLendingPoolRuntime")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant ASSET_LENDING_POOL_RUNTIME_STORAGE_SLOT =
        0xe550184268bc9f659edbb9c6b24d954d35d7ee2960ec89c48b5d88c17e160c00;

    function getStorage() internal pure returns (PoolStorage storage $) {
        assembly {
            $.slot := ASSET_LENDING_POOL_RUNTIME_STORAGE_SLOT
        }
    }
}
