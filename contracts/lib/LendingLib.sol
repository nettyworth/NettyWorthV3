// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAssetNFT} from "../interfaces/IAssetNFT.sol";
import {IAssetLendingPool} from "../interfaces/IAssetLendingPool.sol";
import {IAssetLendingPoolConfig} from "../interfaces/IAssetLendingPoolConfig.sol";
import {INettyWorthMarketplace} from "../interfaces/INettyWorthMarketplace.sol";
import {IPackMachine} from "../interfaces/IPackMachine.sol";
import {IPackMachineFactory} from "../interfaces/IPackMachineFactory.sol";
import {AssetLendingPoolStorageLib} from "./AssetLendingPoolStorageLib.sol";

/// @title LendingLib
/// @notice Deployed library containing the heavy logic bodies of AssetLendingPool.
///         Deployed as a separate contract (called via DELEGATECALL) so its bytecode
///         does NOT count toward AssetLendingPool's 24 KiB EIP-170 limit.
/// @dev Receives an `AssetLendingPoolStorageLib.PoolStorage storage $` pointer from
///      AssetLendingPool. Under delegatecall the library operates on the proxy's own storage.
///      Events/errors are declared here (LOG opcode uses address(this) = proxy under delegatecall,
///      so they are attributed to the proxy; topic0 is signature-derived, indexers unaffected).
library LendingLib {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants (mirror AssetLendingPool to avoid cross-contract reads)
    // =========================================================================

    uint256 private constant YEAR = 365 days;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant MAX_BATCH = 50;

    // =========================================================================
    // EIP-712 typehashes (mirror AssetLendingPool — must match marketplace domain)
    // =========================================================================

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    bytes32 private constant _SIGNED_LISTING_TYPEHASH = keccak256(
        "SignedListing(address seller,address collection,uint256 tokenId,"
        "address paymentToken,uint256 price,uint256 nonce,uint256 expiry,address buyer)"
    );

    // =========================================================================
    // Events — declared here so LOG has them in scope under delegatecall.
    // The proxy address appears as emitter; topic0 is signature-derived.
    // =========================================================================

    event LoanOriginated(
        uint256 indexed loanId,
        address indexed borrower,
        uint256 indexed tokenId,
        uint256 principal,
        uint256 interest,
        uint8 termId,
        uint256 expireTime
    );
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
    event DefaultInitiated(
        uint256 indexed loanId,
        uint256 indexed tokenId,
        uint256 outstandingValue
    );
    event DefaultedAssetAcquired(
        uint256 indexed loanId,
        uint256 indexed tokenId,
        address targetPackMachine
    );
    event LenderInterestClaimed(address indexed lender, uint256 amount);
    event MarketplacePurchaseFinanced(
        uint256 indexed loanId,
        address indexed buyer,
        uint256 indexed tokenId,
        uint256 depositAmount,
        uint256 loanAmount
    );

    // =========================================================================
    // Errors — mirrored subset used inside this library
    // =========================================================================

    error AssetLendingPool__ZeroAmount();
    error AssetLendingPool__ZeroAddress();
    error AssetLendingPool__LoanNotFound();
    error AssetLendingPool__LoanAlreadyPaid();
    error AssetLendingPool__LoanAlreadyDefaulted();
    error AssetLendingPool__NotBorrower();
    error AssetLendingPool__EmptyBundle();
    error AssetLendingPool__BatchTooLarge(uint256 given, uint256 max);
    error AssetLendingPool__InvalidTerm();
    error AssetLendingPool__ExceedsLTV();
    error AssetLendingPool__ExceedsMaxUtilization();
    error AssetLendingPool__ActiveLoanExists();
    error AssetLendingPool__LoanNotExpired();
    error AssetLendingPool__DefaultNotFound();
    error AssetLendingPool__DefaultAlreadyResolved();
    error AssetLendingPool__FinanceWalletNotSet();
    error AssetLendingPool__InvalidPackMachine();
    error AssetLendingPool__NotInAcquisitionPhase();
    error AssetLendingPool__InvalidSeller();
    error AssetLendingPool__NotIntendedBuyer();
    error AssetLendingPool__ListingExpired();
    error AssetLendingPool__ListingCollectionMismatch();
    error AssetLendingPool__ListingPaymentTokenMismatch();
    error AssetLendingPool__ListingNonceUsed();
    error AssetLendingPool__InvalidSignature();

    // =========================================================================
    // Public entry points — DELEGATECALL dispatch
    // =========================================================================

    /// @notice Execute the borrow flow.
    ///         Caller (AssetLendingPool) is responsible for nonReentrant + whenNotPaused.
    function borrow(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256[] memory tokenIds,
        uint256 amount,
        uint8 termId,
        address sender
    ) public {
        if (amount == 0) revert AssetLendingPool__ZeroAmount();
        IAssetLendingPoolConfig cfg = $.config;

        IAssetLendingPool.TermConfig memory term = cfg.getTermConfig(termId);
        if (!term.active) revert AssetLendingPool__InvalidTerm();

        uint256 summedAppraisal = _validateBundle($, tokenIds);

        uint256 maxLoan = (summedAppraisal * cfg.ltvBps()) / BPS;
        if (amount > maxLoan) revert AssetLendingPool__ExceedsLTV();

        _checkUtilization($, amount);

        for (uint256 i; i < tokenIds.length; ) {
            $.assetNFT.transferFrom(sender, address(this), tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        uint256 loanId = _originateLoan($, sender, tokenIds, amount, termId, false);

        uint256 fee = _collectOriginationFee(
            $,
            amount,
            $.loans[loanId].originationFeeBpsSnapshot
        );
        $.paymentToken.safeTransfer(sender, amount - fee);
    }

    /// @notice Execute the financeMarketplacePurchase flow.
    ///         Caller (AssetLendingPool) is responsible for nonReentrant + whenNotPaused +
    ///         the InvalidSeller guard.
    function financeMarketplacePurchase(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        INettyWorthMarketplace.SignedListing calldata listing,
        bytes calldata sig,
        uint256 depositAmount,
        uint8 termId,
        address sender
    ) public {
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
                listing.buyer
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        if (ECDSA.recover(digest, sig) != listing.seller) {
            revert AssetLendingPool__InvalidSignature();
        }

        // --- Validate listing parameters ---
        if (listing.buyer != address(0) && listing.buyer != sender) {
            revert AssetLendingPool__NotIntendedBuyer();
        }
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
        IAssetLendingPool.TermConfig memory term = cfg.getTermConfig(termId);
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
        uint256 loanId = _originateLoan($, sender, ids, loanAmount, termId, true);

        // Buyer deposit -> seller, pool loan -> seller.
        $.paymentToken.safeTransferFrom(sender, listing.seller, depositAmount);
        $.paymentToken.safeTransfer(listing.seller, loanAmount);

        // Origination fee pulled from buyer on top of deposit.
        uint256 fee = (loanAmount * $.loans[loanId].originationFeeBpsSnapshot) / BPS;
        if (fee > 0) {
            $.paymentToken.safeTransferFrom(sender, cfg.feeWallet(), fee);
        }

        emit MarketplacePurchaseFinanced(loanId, sender, tokenId, depositAmount, loanAmount);
    }

    /// @notice Execute the loan repayment / settlement flow.
    ///         Caller (AssetLendingPool) is responsible for nonReentrant + whenNotPaused.
    function settleLoanRepayment(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256 loanId,
        address payer,
        address recipient,
        address requireBorrower
    ) public returns (uint256 principal, uint256 interest, address borrower) {
        IAssetLendingPool.Loan storage loan = _requireActiveLoan($, loanId);
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
        $.paymentToken.safeTransferFrom(payer, address(this), principal + interest);

        _setAssetStateBatch($, tokenIds, IAssetNFT.AssetState.Held);
        for (uint256 i; i < tokenIds.length; ) {
            $.assetNFT.transferFrom(address(this), recipient, tokenIds[i]);
            unchecked {
                ++i;
            }
        }

        emit LoanRepaid(loanId, borrower, principal, interest);
    }

    /// @notice Execute the initiateDefault flow.
    ///         Caller (AssetLendingPool) is responsible for onlyOwner guard.
    function initiateDefault(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256 loanId
    ) public {
        IAssetLendingPool.Loan storage loan = _requireActiveLoan($, loanId);

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

        $.defaults[loanId] = IAssetLendingPool.DefaultRecord({
            loanId: loanId,
            tokenIds: tokenIds,
            outstandingValue: principal,
            defaultedAt: block.timestamp,
            resolved: false,
            interestValue: loan.interest,
            listedOnMarketplace: false,
            acquisitionWindow: $.config.acquisitionWindow(),
            auctionWindow: $.config.auctionWindow()
        });

        _setAssetStateBatch($, tokenIds, IAssetNFT.AssetState.Held);

        emit LoanDefaulted(loanId, borrower, tokenIds[0]);
        emit DefaultInitiated(loanId, tokenIds[0], principal);
    }

    /// @notice Execute the acquireDefaultedAsset flow.
    ///         Caller (AssetLendingPool) is responsible for onlyOwner + nonReentrant.
    function acquireDefaultedAsset(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256 loanId,
        address targetPackMachine,
        uint8 tier
    ) public {
        IAssetLendingPoolConfig cfg = $.config;

        address fw = cfg.getFinanceWallet();
        if (fw == address(0)) revert AssetLendingPool__FinanceWalletNotSet();

        address factory = cfg.packMachineFactory();
        if (
            factory == address(0) ||
            !IPackMachineFactory(factory).isPackMachine(targetPackMachine)
        ) revert AssetLendingPool__InvalidPackMachine();

        {
            IAssetLendingPool.DefaultRecord storage rec = $.defaults[loanId];
            if (rec.defaultedAt == 0)
                revert AssetLendingPool__DefaultNotFound();
            if (block.timestamp >= rec.defaultedAt + rec.acquisitionWindow)
                revert AssetLendingPool__NotInAcquisitionPhase();
        }

        // ---- State writes (CEI) ----
        (
            uint256[] memory tokenIds,
            uint256 principal,
            uint256 interest
        ) = _resolveAndRecredit($, loanId);

        // ---- External interactions ----
        $.paymentToken.safeTransferFrom(fw, address(this), principal + interest);

        uint256 len = tokenIds.length;
        uint8[] memory tiers = new uint8[](len);
        for (uint256 i; i < len; ) {
            $.assetNFT.approve(targetPackMachine, tokenIds[i]);
            tiers[i] = tier;
            unchecked {
                ++i;
            }
        }
        IPackMachine(targetPackMachine).depositFromPool(tokenIds, tiers, address(this));

        emit DefaultedAssetAcquired(loanId, tokenIds[0], targetPackMachine);
    }

    /// @notice Resolve a default record and re-credit principal + distribute interest.
    ///         Used by acquireDefaultedAsset and onDefaultedAssetSold.
    function resolveAndRecredit(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256 loanId
    )
        public
        returns (uint256[] memory tokenIds, uint256 principal, uint256 interest)
    {
        return _resolveAndRecredit($, loanId);
    }

    /// @notice Claim all accrued interest for a lender and return the amount paid.
    function claimLenderInterestInternal(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        address lender
    ) public returns (uint256 pending) {
        return _claimLenderInterestInternal($, lender);
    }

    /// @notice Accrue reward debt for a new lender deposit (must be called before balance update).
    function accrueRewardDebtForDeposit(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        address lender,
        uint256 amount
    ) public {
        $.lenderRewardDebt[lender] += (amount * $.accInterestPerShare) / PRECISION;
    }

    /// @notice Return the pending interest for a lender (view).
    function pendingLenderInterest(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        address lender
    ) public view returns (uint256) {
        return _pendingLenderInterest($, lender);
    }

    // =========================================================================
    // Internal helpers (private — called only within this library)
    // =========================================================================

    function _setAssetStateBatch(
        AssetLendingPoolStorageLib.PoolStorage storage $,
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
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256[] memory tokenIds
    ) private {
        for (uint256 i; i < tokenIds.length; ) {
            $.tokenIdToActiveLoan[tokenIds[i]] = 0;
            unchecked {
                ++i;
            }
        }
    }

    function _removeBorrowerLoan(
        AssetLendingPoolStorageLib.PoolStorage storage $,
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

    function _requireActiveLoan(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256 loanId
    ) private view returns (IAssetLendingPool.Loan storage loan) {
        loan = $.loans[loanId];
        if (loan.loanId == 0) revert AssetLendingPool__LoanNotFound();
        if (loan.isPaid) revert AssetLendingPool__LoanAlreadyPaid();
        if (loan.isDefaulted) revert AssetLendingPool__LoanAlreadyDefaulted();
    }

    function _collectOriginationFee(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256 principal,
        uint256 feeBpsSnapshot
    ) private returns (uint256 fee) {
        fee = (principal * feeBpsSnapshot) / BPS;
        if (fee > 0) {
            $.paymentToken.safeTransfer($.config.feeWallet(), fee);
        }
    }

    function _validateBundle(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256[] memory tokenIds
    ) private view returns (uint256 summedAppraisal) {
        uint256 len = tokenIds.length;
        if (len == 0) revert AssetLendingPool__EmptyBundle();
        if (len > MAX_BATCH)
            revert AssetLendingPool__BatchTooLarge(len, MAX_BATCH);

        summedAppraisal = $.config.validateBundleAndSumAppraisals(tokenIds);

        for (uint256 i; i < len; ) {
            if ($.tokenIdToActiveLoan[tokenIds[i]] != 0)
                revert AssetLendingPool__ActiveLoanExists();
            unchecked {
                ++i;
            }
        }
    }

    function _originateLoan(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        address borrower,
        uint256[] memory tokenIds,
        uint256 principal,
        uint8 termId,
        bool isMarketplaceFinanced
    ) private returns (uint256 loanId) {
        IAssetLendingPool.TermConfig memory term = $.config.getTermConfig(termId);
        uint256 interest = (principal * term.aprBps * term.duration) / (YEAR * BPS);
        uint256 expireTime = block.timestamp + term.duration;

        uint256 lenderShareBpsSnap = $.config.lenderShareBps();
        uint256 lenderDepositsSnap = $.totalLenderDeposits;
        uint256 originationFeeBpsSnap = $.config.originationFeeBps();

        loanId = $.nextLoanId++;
        $.loans[loanId] = IAssetLendingPool.Loan({
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
            lenderDepositsSnapshot: lenderDepositsSnap,
            originationFeeBpsSnapshot: originationFeeBpsSnap
        });
        $.borrowerLoans[borrower].push(loanId);
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

        emit LoanOriginated(loanId, borrower, tokenIds[0], principal, interest, termId, expireTime);
        emit BundleLoanOriginated(loanId, borrower, tokenIds, principal, interest, termId, expireTime);
    }

    function _resolveAndRecredit(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256 loanId
    )
        private
        returns (uint256[] memory tokenIds, uint256 principal, uint256 interest)
    {
        IAssetLendingPool.DefaultRecord storage rec = $.defaults[loanId];
        if (rec.defaultedAt == 0) revert AssetLendingPool__DefaultNotFound();
        if (rec.resolved) revert AssetLendingPool__DefaultAlreadyResolved();

        tokenIds = rec.tokenIds;
        principal = rec.outstandingValue;
        interest = rec.interestValue;

        rec.resolved = true;

        $.totalDeposited += principal;
        $.totalDefaultedPrincipal -= principal;

        IAssetLendingPool.Loan storage loan = $.loans[loanId];
        _distributeInterest($, interest, loan.lenderShareBpsSnapshot, loan.lenderDepositsSnapshot);
    }

    function _distributeInterest(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256 interest,
        uint256 lenderShareBps,
        uint256 totalLenderDeposits
    ) private {
        if (interest == 0) return;
        if (totalLenderDeposits == 0)
            totalLenderDeposits = $.totalLenderDeposits;
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
        AssetLendingPoolStorageLib.PoolStorage storage $,
        address lender
    ) private view returns (uint256) {
        uint256 balance = $.lenderDeposits[lender];
        if (balance == 0) return 0;
        return
            (balance * $.accInterestPerShare) / PRECISION -
            $.lenderRewardDebt[lender];
    }

    function _claimLenderInterestInternal(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        address lender
    ) private returns (uint256 pending) {
        pending = _pendingLenderInterest($, lender);
        if (pending == 0) return 0;
        $.lenderRewardDebt[lender] += pending;
        $.totalLenderInterestPaid += pending;
        $.paymentToken.safeTransfer(lender, pending);
        emit LenderInterestClaimed(lender, pending);
    }

    function _checkUtilization(
        AssetLendingPoolStorageLib.PoolStorage storage $,
        uint256 amount
    ) private view {
        uint256 maxBorrowable =
            ($.totalDeposited * $.config.maxUtilizationBps()) / BPS;
        if ($.totalBorrowed + amount > maxBorrowable)
            revert AssetLendingPool__ExceedsMaxUtilization();
    }
}
