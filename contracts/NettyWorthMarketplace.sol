// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

import {INettyWorthMarketplace} from "./interfaces/INettyWorthMarketplace.sol";
import {IFeeController} from "./interfaces/IFeeController.sol";
import {IAssetLendingPool} from "./interfaces/IAssetLendingPool.sol";
import {IAssetNFT} from "./interfaces/IAssetNFT.sol";
import {IPermissionManager} from "./interfaces/IPermissionManager.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";

/// @title NettyWorthMarketplace
/// @author NettyWorth
/// @notice v3 marketplace for AssetNFT tokens. Supports fixed-price sales (off-chain signed listings)
///         and English auctions (hybrid model: seller and bidders sign EIP-712 messages; minimal
///         on-chain auction state enforces reserve price, min-increment, and last-minute time extension;
///         funds pulled from the winner only at settlement — no upfront escrow).
///
///         Loan-aware: if the listed asset is collateralised in AssetLendingPool, the minimum
///         acceptable price is principal + interest. On sale, the loan is repaid atomically before
///         the seller receives net proceeds — the NFT is released directly to the buyer by the pool.
///
///         Collectible (5% default) and royalty (EIP-2981) fees are deducted before seller proceeds.
///
/// @dev UUPS upgradeable. Access control via PermissionConsumer/PermissionManager.
///      ERC-7201 namespaced storage. Not ERC-2771 (_msgSender == msg.sender).
///      USDC/ERC-20 only — no native ETH.
/// @custom:security-contact security@nettyworth.io
contract NettyWorthMarketplace is
    INettyWorthMarketplace,
    Initializable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    PermissionConsumer,
    PausableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_BATCH = 50;

    // =========================================================================
    // EIP-712 typehashes
    // =========================================================================

    bytes32 private constant SIGNED_LISTING_TYPEHASH = keccak256(
        "SignedListing(address seller,address collection,uint256 tokenId,address paymentToken,"
        "uint256 price,uint256 nonce,uint256 expiry)"
    );

    bytes32 private constant SIGNED_AUCTION_TYPEHASH = keccak256(
        "SignedAuction(address seller,address collection,uint256 tokenId,address paymentToken,"
        "uint256 reservePrice,uint256 minIncrement,uint256 startTime,uint256 endTime,"
        "uint256 extensionWindow,uint256 extensionDuration,uint256 nonce)"
    );

    bytes32 private constant SIGNED_BID_TYPEHASH = keccak256(
        "SignedBid(bytes32 auctionId,address bidder,uint256 amount,uint256 nonce,uint256 expiry)"
    );

    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.NettyWorthMarketplace
    struct MarketplaceStorage {
        IFeeController feeController;
        IAssetLendingPool lendingPool;
        address treasury;
        /// @dev Minimal collection whitelist — multi-collection future-proofing.
        mapping(address collection => bool) allowedCollections;
        /// @dev Minimal payment-token whitelist.
        mapping(address token => bool) allowedPaymentTokens;
        /// @dev Per-signer nonce consumption for replay protection.
        mapping(address signer => mapping(uint256 nonce => bool)) usedNonces;
        /// @dev On-chain auction state keyed by auctionId (materialised on first valid bid).
        mapping(bytes32 auctionId => AuctionState) auctions;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.NettyWorthMarketplace")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MARKETPLACE_STORAGE_SLOT =
        0x68ba5196c25fc959bc0fb3ec3cc9a4e3d693169bd32406f4511fd2704f2d7000;

    function _getMarketplaceStorage() private pure returns (MarketplaceStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := MARKETPLACE_STORAGE_SLOT
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

    /// @notice Initializes the marketplace.
    /// @param permissionManager_ PermissionManager proxy address.
    /// @param feeController_     FeeController proxy address.
    /// @param lendingPool_       AssetLendingPool proxy address.
    /// @param assetNFT_          Canonical AssetNFT proxy address (added to allowedCollections).
    /// @param paymentToken_      ERC20 payment token (USDC; added to allowedPaymentTokens).
    /// @param treasury_          Platform treasury that receives collectible fees.
    function initialize(
        address permissionManager_,
        address feeController_,
        address lendingPool_,
        address assetNFT_,
        address paymentToken_,
        address treasury_
    ) external initializer {
        if (
            feeController_ == address(0) ||
            lendingPool_ == address(0) ||
            assetNFT_ == address(0) ||
            paymentToken_ == address(0) ||
            treasury_ == address(0)
        ) revert Marketplace__ZeroAddress();

        __EIP712_init("NettyWorthMarketplace", "1");
        __Pausable_init();
        __PermissionConsumer_init(permissionManager_);

        MarketplaceStorage storage $ = _getMarketplaceStorage();
        $.feeController = IFeeController(feeController_);
        $.lendingPool = IAssetLendingPool(lendingPool_);
        $.treasury = treasury_;
        $.allowedCollections[assetNFT_] = true;
        $.allowedPaymentTokens[paymentToken_] = true;
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyProtocolRole(Roles.UPGRADER_ROLE) {}

    // =========================================================================
    // Fixed-price sale
    // =========================================================================

    /// @inheritdoc INettyWorthMarketplace
    function buyWithSignature(
        SignedListing calldata listing,
        bytes calldata sig
    ) external override nonReentrant whenNotPaused {
        MarketplaceStorage storage $ = _getMarketplaceStorage();

        // --- Validate signature ---
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_LISTING_TYPEHASH,
                listing.seller,
                listing.collection,
                listing.tokenId,
                listing.paymentToken,
                listing.price,
                listing.nonce,
                listing.expiry
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        if (signer != listing.seller) revert Marketplace__InvalidSignature();

        // --- Replay protection (CEI: mark before external calls) ---
        if ($.usedNonces[listing.seller][listing.nonce]) {
            revert Marketplace__NonceUsed(listing.seller, listing.nonce);
        }
        $.usedNonces[listing.seller][listing.nonce] = true;

        // --- Validate listing parameters ---
        if (block.timestamp > listing.expiry) revert Marketplace__Expired();
        if (!$.allowedCollections[listing.collection]) {
            revert Marketplace__CollectionNotAllowed(listing.collection);
        }
        if (!$.allowedPaymentTokens[listing.paymentToken]) {
            revert Marketplace__PaymentTokenNotAllowed(listing.paymentToken);
        }

        _executeSale(
            $,
            listing.seller,
            listing.collection,
            listing.tokenId,
            listing.paymentToken,
            listing.price,
            msg.sender // buyer
        );
    }

    // =========================================================================
    // Auction: commit bid
    // =========================================================================

    /// @inheritdoc INettyWorthMarketplace
    function commitBid(
        SignedAuction calldata auction,
        bytes calldata auctionSig,
        SignedBid calldata bid,
        bytes calldata bidSig
    ) external override nonReentrant whenNotPaused {
        MarketplaceStorage storage $ = _getMarketplaceStorage();

        // --- Validate auction signature ---
        bytes32 auctionId = _hashAuction(auction);
        {
            address auctionSigner = _hashTypedDataV4(auctionId).recover(auctionSig);
            if (auctionSigner != auction.seller) revert Marketplace__InvalidSignature();
        }

        // --- Validate bid signature ---
        bytes32 bidStructHash = keccak256(
            abi.encode(
                SIGNED_BID_TYPEHASH,
                bid.auctionId,
                bid.bidder,
                bid.amount,
                bid.nonce,
                bid.expiry
            )
        );
        {
            address bidSigner = _hashTypedDataV4(bidStructHash).recover(bidSig);
            if (bidSigner != bid.bidder) revert Marketplace__InvalidSignature();
        }

        // --- Cross-reference check ---
        if (bid.auctionId != auctionId) revert Marketplace__InvalidSignature();

        // --- Bid nonce replay protection (CEI) ---
        if ($.usedNonces[bid.bidder][bid.nonce]) {
            revert Marketplace__NonceUsed(bid.bidder, bid.nonce);
        }
        $.usedNonces[bid.bidder][bid.nonce] = true;

        // --- Validate collection / payment token ---
        if (!$.allowedCollections[auction.collection]) {
            revert Marketplace__CollectionNotAllowed(auction.collection);
        }
        if (!$.allowedPaymentTokens[auction.paymentToken]) {
            revert Marketplace__PaymentTokenNotAllowed(auction.paymentToken);
        }

        // --- Validate bid timing ---
        if (block.timestamp < auction.startTime) revert Marketplace__NotStarted();
        if (bid.expiry != 0 && block.timestamp > bid.expiry) revert Marketplace__Expired();

        AuctionState storage state = $.auctions[auctionId];

        if (!state.exists) {
            // First bid: materialise auction state from the signed auction
            if (block.timestamp > auction.endTime) revert Marketplace__AuctionEnded();
            if (bid.amount < auction.reservePrice) {
                revert Marketplace__BidTooLow(bid.amount, auction.reservePrice);
            }
            state.seller = auction.seller;
            state.collection = auction.collection;
            state.tokenId = auction.tokenId;
            state.paymentToken = auction.paymentToken;
            state.endTime = auction.endTime;
            state.extensionWindow = auction.extensionWindow;
            state.extensionDuration = auction.extensionDuration;
            state.minIncrement = auction.minIncrement;
            state.reservePrice = auction.reservePrice;
            state.exists = true;
        } else {
            // Subsequent bid: must beat current highest + minIncrement
            if (state.settled) revert Marketplace__AuctionAlreadySettled();
            if (block.timestamp > state.endTime) revert Marketplace__AuctionEnded();
            uint256 minRequired = state.highestBid + state.minIncrement;
            if (bid.amount < minRequired) revert Marketplace__BidTooLow(bid.amount, minRequired);
        }

        state.highestBidder = bid.bidder;
        state.highestBid = bid.amount;

        // --- Last-minute time extension ---
        uint256 newEndTime = state.endTime;
        if (
            state.extensionWindow > 0 &&
            block.timestamp > state.endTime - state.extensionWindow
        ) {
            newEndTime = state.endTime + state.extensionDuration;
            state.endTime = newEndTime;
        }

        emit BidCommitted(auctionId, bid.bidder, bid.amount, newEndTime);
    }

    // =========================================================================
    // Auction: settle
    // =========================================================================

    /// @inheritdoc INettyWorthMarketplace
    function settleAuction(bytes32 auctionId) external override nonReentrant whenNotPaused {
        MarketplaceStorage storage $ = _getMarketplaceStorage();
        AuctionState storage state = $.auctions[auctionId];

        if (!state.exists) revert Marketplace__AuctionNotFound();
        if (state.settled) revert Marketplace__AuctionAlreadySettled();
        if (state.highestBidder == address(0)) revert Marketplace__NoBids();

        // Anyone may settle after endTime; MARKETPLACE_ROLE may force-close early
        bool isAdmin = _getPermissionManager().hasProtocolRole(Roles.MARKETPLACE_ROLE, msg.sender);
        if (!isAdmin && block.timestamp <= state.endTime) revert Marketplace__AuctionNotEnded();

        // Mark settled before external calls (CEI)
        state.settled = true;

        _executeSale(
            $,
            state.seller,
            state.collection,
            state.tokenId,
            state.paymentToken,
            state.highestBid,
            state.highestBidder
        );

        emit AuctionSettled(auctionId, state.highestBidder, state.highestBid);
    }

    // =========================================================================
    // Cancel functions
    // =========================================================================

    /// @inheritdoc INettyWorthMarketplace
    function cancelNonce(uint256 nonce) external override {
        MarketplaceStorage storage $ = _getMarketplaceStorage();
        if ($.usedNonces[msg.sender][nonce]) revert Marketplace__NonceUsed(msg.sender, nonce);
        $.usedNonces[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    /// @inheritdoc INettyWorthMarketplace
    function cancelAuction(bytes32 auctionId) external override {
        MarketplaceStorage storage $ = _getMarketplaceStorage();
        AuctionState storage state = $.auctions[auctionId];

        if (!state.exists) revert Marketplace__AuctionNotFound();
        if (state.settled) revert Marketplace__AuctionAlreadySettled();

        bool isAdmin = _getPermissionManager().hasProtocolRole(Roles.MARKETPLACE_ROLE, msg.sender);
        if (!isAdmin && msg.sender != state.seller) revert Marketplace__NotSeller();

        state.settled = true; // mark as done so it can't be re-settled
        emit AuctionCancelled(auctionId, msg.sender);
    }

    // =========================================================================
    // Admin setters
    // =========================================================================

    /// @inheritdoc INettyWorthMarketplace
    function setFeeController(
        address feeController_
    ) external override onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (feeController_ == address(0)) revert Marketplace__ZeroAddress();
        _getMarketplaceStorage().feeController = IFeeController(feeController_);
        emit FeeControllerUpdated(feeController_);
    }

    /// @inheritdoc INettyWorthMarketplace
    function setLendingPool(
        address lendingPool_
    ) external override onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (lendingPool_ == address(0)) revert Marketplace__ZeroAddress();
        _getMarketplaceStorage().lendingPool = IAssetLendingPool(lendingPool_);
        emit LendingPoolUpdated(lendingPool_);
    }

    /// @inheritdoc INettyWorthMarketplace
    function setTreasury(
        address treasury_
    ) external override onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert Marketplace__ZeroAddress();
        _getMarketplaceStorage().treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    /// @inheritdoc INettyWorthMarketplace
    function setAllowedCollection(
        address collection,
        bool allowed
    ) external override onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _getMarketplaceStorage().allowedCollections[collection] = allowed;
        emit AllowedCollectionUpdated(collection, allowed);
    }

    /// @inheritdoc INettyWorthMarketplace
    function setAllowedPaymentToken(
        address token,
        bool allowed
    ) external override onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _getMarketplaceStorage().allowedPaymentTokens[token] = allowed;
        emit AllowedPaymentTokenUpdated(token, allowed);
    }

    /// @inheritdoc INettyWorthMarketplace
    function pause() external override onlyProtocolRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc INettyWorthMarketplace
    function unpause() external override onlyProtocolRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @inheritdoc INettyWorthMarketplace
    function getAuction(bytes32 auctionId) external view override returns (AuctionState memory) {
        return _getMarketplaceStorage().auctions[auctionId];
    }

    /// @inheritdoc INettyWorthMarketplace
    function isNonceUsed(
        address signer,
        uint256 nonce
    ) external view override returns (bool) {
        return _getMarketplaceStorage().usedNonces[signer][nonce];
    }

    /// @inheritdoc INettyWorthMarketplace
    function hashAuction(
        SignedAuction calldata auction
    ) external view override returns (bytes32) {
        return _hashTypedDataV4(_hashAuction(auction));
    }

    // =========================================================================
    // Internal: sale execution core
    // =========================================================================

    /// @dev Shared sale path for both fixed-price and auction settlement.
    ///      Steps (CEI respected — nonce/settled flag set before this call):
    ///        1. Compute collectible fee from FeeController.
    ///        2. Compute royalty from EIP-2981 (capped).
    ///        3. Check minPrice (gross >= collectibleFee + royalty + loanDebt).
    ///        4. Pull gross from buyer into this contract.
    ///        5. Distribute collectible fee → treasury.
    ///        6. Distribute royalty → royalty receiver.
    ///        7a. If loan: approve pool + call settleLoanRepaymentOnSale (pool delivers NFT).
    ///        7b. If no loan: transferFrom(seller, buyer).
    ///        8. Pay seller net proceeds.
    function _executeSale(
        MarketplaceStorage storage $,
        address seller,
        address collection,
        uint256 tokenId,
        address paymentToken,
        uint256 gross,
        address buyer
    ) internal {
        // 1. Collectible fee
        (uint256 collectibleFee, ) = $.feeController.getCollectibleFee(gross);

        // 2. Royalty (EIP-2981, try/catch, capped so it can't consume all proceeds)
        uint256 royalty = 0;
        address royaltyReceiver = address(0);
        try IERC2981(collection).royaltyInfo(tokenId, gross) returns (
            address receiver,
            uint256 amount
        ) {
            // Cap: royalty + collectible fee must not exceed gross - loanDebt
            // (we re-cap after loan lookup below; preliminary cap to avoid overflow)
            royaltyReceiver = receiver;
            royalty = amount;
        } catch {} // solhint-disable-line no-empty-blocks

        // 3. Loan debt
        ( , , uint256 loanDebt) = $.lendingPool.getLoanDebt(tokenId);
        uint256 loanId = loanDebt > 0 ? $.lendingPool.getActiveLoanId(tokenId) : 0;

        // Cap royalty: royalty must not exceed (gross - collectibleFee - loanDebt)
        if (collectibleFee + loanDebt < gross) {
            uint256 maxRoyalty = gross - collectibleFee - loanDebt;
            if (royalty > maxRoyalty) royalty = maxRoyalty;
        } else {
            royalty = 0;
        }

        // MinPrice enforcement: gross must cover fees + loan
        uint256 required = collectibleFee + royalty + loanDebt;
        if (gross < required) revert Marketplace__PriceBelowMinimum(gross, required);

        uint256 sellerProceeds = gross - collectibleFee - royalty - loanDebt;

        // 4. Pull gross from buyer
        IERC20(paymentToken).safeTransferFrom(buyer, address(this), gross);

        // 5. Collectible fee → treasury
        if (collectibleFee > 0) {
            IERC20(paymentToken).safeTransfer($.treasury, collectibleFee);
        }

        // 6. Royalty → receiver
        if (royalty > 0 && royaltyReceiver != address(0)) {
            IERC20(paymentToken).safeTransfer(royaltyReceiver, royalty);
        }

        // 7. NFT delivery
        if (loanDebt > 0) {
            // 7a. Loan branch: approve pool then settle atomically
            //     Pool pulls loanDebt from this contract, clears the loan, and delivers NFT to buyer.
            IERC20(paymentToken).forceApprove(address($.lendingPool), loanDebt);
            $.lendingPool.settleLoanRepaymentOnSale(loanId, address(this), buyer);
        } else {
            // 7b. No loan: seller still holds the NFT in Held state; transfer directly.
            IAssetNFT(collection).transferFrom(seller, buyer, tokenId);
        }

        // 8. Seller proceeds
        if (sellerProceeds > 0) {
            IERC20(paymentToken).safeTransfer(seller, sellerProceeds);
        }

        emit SaleExecuted(
            seller,
            buyer,
            collection,
            tokenId,
            paymentToken,
            gross,
            collectibleFee,
            royalty,
            loanDebt,
            sellerProceeds
        );
    }

    // =========================================================================
    // Internal: EIP-712 struct hashing helpers
    // =========================================================================

    function _hashAuction(SignedAuction calldata auction) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SIGNED_AUCTION_TYPEHASH,
                auction.seller,
                auction.collection,
                auction.tokenId,
                auction.paymentToken,
                auction.reservePrice,
                auction.minIncrement,
                auction.startTime,
                auction.endTime,
                auction.extensionWindow,
                auction.extensionDuration,
                auction.nonce
            )
        );
    }

    // =========================================================================
    // Context overrides
    // =========================================================================

    /// @dev Not ERC-2771 — msg.sender is always the direct caller.
    ///      Overrides the conflict between ContextUpgradeable (via EIP712Upgradeable)
    ///      and PermissionConsumer, both of which declare _msgSender().
    function _msgSender()
        internal
        view
        override(PermissionConsumer, ContextUpgradeable)
        returns (address)
    {
        return msg.sender;
    }

    // =========================================================================
    // Internal: PermissionManager accessor (for role checks outside onlyProtocolRole)
    // =========================================================================

    /// @dev Returns the active PermissionManager as IPermissionManager, for ad-hoc role checks.
    function _getPermissionManager() internal view returns (IPermissionManager) {
        return IPermissionManager(getPermissionManager());
    }
}
