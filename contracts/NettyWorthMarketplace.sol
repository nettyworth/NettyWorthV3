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

    bytes32 private constant SIGNED_OFFER_TYPEHASH = keccak256(
        "SignedOffer(address buyer,address collection,uint256 tokenId,address paymentToken,"
        "uint256 price,uint256 nonce,uint256 expiry)"
    );

    /// @dev Domain tag for pool-default auction IDs. Distinct from the EIP-712 SIGNED_AUCTION_TYPEHASH
    ///      space so a pool auctionId can never alias a seller-signed auctionId.
    bytes32 private constant POOL_AUCTION_TAG = keccak256(
        "nettyworth.pool.default.auction"
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
        // ---- appended fields (append-only for upgrade safety) ----
        /// @dev For pool-default sales: maps collateral tokenId → loanId.
        ///      Non-zero means this tokenId is part of a defaulted-asset auction listed by
        ///      listDefaultedAsset. Used in _executeSale to detect pool-default sales and waive
        ///      fees/royalty. Cleared on settlement or cancellation.
        mapping(uint256 tokenId => uint256 loanId) poolDefaultLoanOf;
        /// @dev For pool-default sales: maps auctionId → loanId.
        ///      Used in settleAuction and cancelAuction to route the pool callback.
        ///      Cleared on settlement or cancellation.
        mapping(bytes32 auctionId => uint256 loanId) poolDefaultAuctionLoanOf;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.NettyWorthMarketplace")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MARKETPLACE_STORAGE_SLOT =
        0x1b62b54db2d4d5c73083078cc269c4036b01ae06fa994c0368f121e766c05600;

    function _getMarketplaceStorage()
        private
        pure
        returns (MarketplaceStorage storage $)
    {
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
    // Buy offer: accept
    // =========================================================================

    /// @inheritdoc INettyWorthMarketplace
    function acceptOffer(
        SignedOffer calldata offer,
        bytes calldata sig
    ) external override nonReentrant whenNotPaused {
        MarketplaceStorage storage $ = _getMarketplaceStorage();

        // --- Validate buyer's signature ---
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_OFFER_TYPEHASH,
                offer.buyer,
                offer.collection,
                offer.tokenId,
                offer.paymentToken,
                offer.price,
                offer.nonce,
                offer.expiry
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);
        if (signer != offer.buyer) revert Marketplace__InvalidSignature();

        // --- Replay protection (CEI: mark before external calls) ---
        if ($.usedNonces[offer.buyer][offer.nonce]) {
            revert Marketplace__NonceUsed(offer.buyer, offer.nonce);
        }
        $.usedNonces[offer.buyer][offer.nonce] = true;

        // --- Validate offer parameters ---
        if (block.timestamp > offer.expiry) revert Marketplace__Expired();
        if (!$.allowedCollections[offer.collection]) {
            revert Marketplace__CollectionNotAllowed(offer.collection);
        }
        if (!$.allowedPaymentTokens[offer.paymentToken]) {
            revert Marketplace__PaymentTokenNotAllowed(offer.paymentToken);
        }

        // --- Authorization guard for collateralised tokens ---
        // Non-loaned branch: transferFrom(seller, buyer) in _executeSale is self-enforcing
        // (msg.sender must own the NFT and have approved the marketplace).
        // Loaned branch: the pool delivers the NFT regardless of who calls, so we must
        // explicitly verify msg.sender is the borrower before external calls (CEI).
        uint256 activeLoanId = $.lendingPool.getActiveLoanId(offer.tokenId);
        if (activeLoanId != 0) {
            address borrower = $.lendingPool.getLoan(activeLoanId).borrower;
            if (msg.sender != borrower) revert Marketplace__NotTokenOwner();
        }

        _executeSale(
            $,
            msg.sender, // seller
            offer.collection,
            offer.tokenId,
            offer.paymentToken,
            offer.price,
            offer.buyer
        );

        emit OfferAccepted(
            offer.buyer,
            msg.sender,
            offer.collection,
            offer.tokenId,
            offer.paymentToken,
            offer.price
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
            address auctionSigner = _hashTypedDataV4(auctionId).recover(
                auctionSig
            );
            if (auctionSigner != auction.seller)
                revert Marketplace__InvalidSignature();
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
        if (block.timestamp < auction.startTime)
            revert Marketplace__NotStarted();
        if (bid.expiry != 0 && block.timestamp > bid.expiry)
            revert Marketplace__Expired();

        AuctionState storage state = $.auctions[auctionId];

        if (!state.exists) {
            // First bid: materialise auction state from the signed auction
            if (block.timestamp > auction.endTime)
                revert Marketplace__AuctionEnded();
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
            if (block.timestamp > state.endTime)
                revert Marketplace__AuctionEnded();
            uint256 minRequired = state.highestBid + state.minIncrement;
            if (bid.amount < minRequired)
                revert Marketplace__BidTooLow(bid.amount, minRequired);
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
    function settleAuction(
        bytes32 auctionId
    ) external override nonReentrant whenNotPaused {
        MarketplaceStorage storage $ = _getMarketplaceStorage();
        AuctionState storage state = $.auctions[auctionId];

        if (!state.exists) revert Marketplace__AuctionNotFound();
        if (state.settled) revert Marketplace__AuctionAlreadySettled();
        if (state.highestBidder == address(0)) revert Marketplace__NoBids();

        // Anyone may settle after endTime; MARKETPLACE_ROLE may force-close early
        bool isAdmin = _getPermissionManager().hasProtocolRole(
            Roles.MARKETPLACE_ROLE,
            msg.sender
        );
        if (!isAdmin && block.timestamp <= state.endTime)
            revert Marketplace__AuctionNotEnded();

        // Cache values needed after _executeSale (state.highestBid read before settled=true is fine;
        // settled is set first per CEI to prevent re-entry through the pool callback).
        uint256 winningBid = state.highestBid;
        address winner = state.highestBidder;
        uint256 tokenId = state.tokenId;

        // Mark settled before external calls (CEI)
        state.settled = true;

        _executeSale(
            $,
            state.seller,
            state.collection,
            tokenId,
            state.paymentToken,
            winningBid,
            winner
        );

        // Pool-default callback: if this was a pool-default auction, resolve the default record.
        // Called after _executeSale (proceeds already transferred to pool as sellerProceeds).
        uint256 poolLoanId = $.poolDefaultAuctionLoanOf[auctionId];
        if (poolLoanId != 0) {
            // Clear maps before the external callback (CEI).
            delete $.poolDefaultAuctionLoanOf[auctionId];
            delete $.poolDefaultLoanOf[tokenId];
            // Inform the pool: principal round-trip, interest distribution, surplus booking.
            $.lendingPool.onDefaultedAssetSold(poolLoanId, winningBid);
        }

        emit AuctionSettled(auctionId, winner, winningBid);
    }

    // =========================================================================
    // Pool-default auction: list + bid
    // =========================================================================

    /// @inheritdoc INettyWorthMarketplace
    function listDefaultedAsset(
        uint256 loanId,
        uint256 tokenId,
        uint256 reservePrice,
        uint256 minIncrement,
        uint256 /* startTime */, // not stored in AuctionState; bidders enforce via bid.expiry
        uint256 endTime,
        uint256 extensionWindow,
        uint256 extensionDuration
    ) external override onlyProtocolRole(Roles.MARKETPLACE_ROLE) whenNotPaused {
        MarketplaceStorage storage $ = _getMarketplaceStorage();

        // Validate via pool: must be past acquisition window, unresolved, single-token.
        // prepareDefaultedListing enforces all of the above and sets listedOnMarketplace=true.
        uint256[] memory tokenIds = $.lendingPool.prepareDefaultedListing(
            loanId
        );
        // prepareDefaultedListing already enforces tokenIds.length == 1, but confirm tokenId matches.
        if (tokenIds[0] != tokenId) revert Marketplace__InvalidSignature(); // reuse; means param mismatch

        // Validate reserve >= outstanding value.
        // outstanding = principal + interest; getLoanDebt returns 0 for defaulted tokens,
        // so we read directly from the pool's default record via a view added in the interface.
        {
            IAssetLendingPool.DefaultRecord memory rec = $
                .lendingPool
                .getDefaultRecord(loanId);
            uint256 outstanding = rec.outstandingValue + rec.interestValue;
            if (reservePrice < outstanding)
                revert Marketplace__ReserveBelowOutstanding(
                    reservePrice,
                    outstanding
                );
        }

        address lendingPool = address($.lendingPool);

        // Read collection + paymentToken from the pool's PoolInfo (avoids adding new getters).
        IAssetLendingPool.PoolInfo memory poolInfo = $
            .lendingPool
            .getPoolInfo();
        address collection = poolInfo.assetNFT;
        address paymentToken = poolInfo.paymentToken;

        // Compute a domain-separated auctionId distinct from the EIP-712 seller-signed space.
        bytes32 auctionId = keccak256(
            abi.encode(
                POOL_AUCTION_TAG,
                loanId,
                tokenId,
                endTime,
                block.timestamp
            )
        );

        // Materialize the AuctionState directly (no seller signature required).
        AuctionState storage state = $.auctions[auctionId];
        // Guard against an astronomically unlikely collision.
        if (state.exists) revert Marketplace__AuctionAlreadySettled();

        state.seller = lendingPool;
        state.collection = collection;
        state.tokenId = tokenId;
        state.paymentToken = paymentToken;
        state.endTime = endTime;
        state.extensionWindow = extensionWindow;
        state.extensionDuration = extensionDuration;
        state.minIncrement = minIncrement;
        state.reservePrice = reservePrice;
        state.exists = true;
        state.settled = false;

        // Record the loanId linkage for settleAuction/cancelAuction callbacks.
        $.poolDefaultLoanOf[tokenId] = loanId;
        $.poolDefaultAuctionLoanOf[auctionId] = loanId;

        emit DefaultedAssetListed(
            loanId,
            tokenId,
            auctionId,
            reservePrice,
            endTime
        );
    }

    /// @inheritdoc INettyWorthMarketplace
    function commitPoolBid(
        bytes32 auctionId,
        SignedBid calldata bid,
        bytes calldata bidSig
    ) external override nonReentrant whenNotPaused {
        MarketplaceStorage storage $ = _getMarketplaceStorage();
        AuctionState storage state = $.auctions[auctionId];

        // Must be a pre-materialized pool-default auction.
        if (!state.exists) revert Marketplace__AuctionNotFound();
        if ($.poolDefaultAuctionLoanOf[auctionId] == 0)
            revert Marketplace__NotPoolDefaultAuction();

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

        // Cross-reference: bid must target this auctionId.
        if (bid.auctionId != auctionId) revert Marketplace__InvalidSignature();

        // --- Bid nonce replay protection (CEI) ---
        if ($.usedNonces[bid.bidder][bid.nonce]) {
            revert Marketplace__NonceUsed(bid.bidder, bid.nonce);
        }
        $.usedNonces[bid.bidder][bid.nonce] = true;

        // --- Timing ---
        if (bid.expiry != 0 && block.timestamp > bid.expiry)
            revert Marketplace__Expired();
        if (state.settled) revert Marketplace__AuctionAlreadySettled();
        if (block.timestamp > state.endTime) revert Marketplace__AuctionEnded();

        // --- Reserve / increment enforcement ---
        if (state.highestBidder == address(0)) {
            // First bid: must meet reserve.
            if (bid.amount < state.reservePrice)
                revert Marketplace__BidTooLow(bid.amount, state.reservePrice);
        } else {
            // Subsequent bid: must beat current highest + minIncrement.
            uint256 minRequired = state.highestBid + state.minIncrement;
            if (bid.amount < minRequired)
                revert Marketplace__BidTooLow(bid.amount, minRequired);
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
    // Cancel functions
    // =========================================================================

    /// @inheritdoc INettyWorthMarketplace
    function cancelNonce(uint256 nonce) external override {
        MarketplaceStorage storage $ = _getMarketplaceStorage();
        if ($.usedNonces[msg.sender][nonce])
            revert Marketplace__NonceUsed(msg.sender, nonce);
        $.usedNonces[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    /// @inheritdoc INettyWorthMarketplace
    function cancelAuction(bytes32 auctionId) external override nonReentrant {
        MarketplaceStorage storage $ = _getMarketplaceStorage();
        AuctionState storage state = $.auctions[auctionId];

        if (!state.exists) revert Marketplace__AuctionNotFound();
        if (state.settled) revert Marketplace__AuctionAlreadySettled();

        bool isAdmin = _getPermissionManager().hasProtocolRole(
            Roles.MARKETPLACE_ROLE,
            msg.sender
        );
        if (!isAdmin && msg.sender != state.seller)
            revert Marketplace__NotSeller();

        uint256 tokenId = state.tokenId;
        state.settled = true; // mark as done so it can't be re-settled

        // Pool-default cleanup: reset the pool's listedOnMarketplace flag so the operator can relist.
        uint256 poolLoanId = $.poolDefaultAuctionLoanOf[auctionId];
        if (poolLoanId != 0) {
            // Clear maps before the external callback (CEI).
            delete $.poolDefaultAuctionLoanOf[auctionId];
            delete $.poolDefaultLoanOf[tokenId];
            // Notify the pool so it can reset listedOnMarketplace for relist.
            $.lendingPool.onDefaultedListingCancelled(poolLoanId);
        }

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
    function getAuction(
        bytes32 auctionId
    ) external view override returns (AuctionState memory) {
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
    ///        1. Detect pool-default sale (tokenId in poolDefaultLoanOf map) — waive fee+royalty.
    ///        2. Compute collectible fee from FeeController (skipped for pool-default).
    ///        3. Compute royalty from EIP-2981 (skipped for pool-default; capped otherwise).
    ///        4. Check minPrice (gross >= collectibleFee + royalty + loanDebt).
    ///        5. Pull gross from buyer into this contract.
    ///        6. Distribute collectible fee → treasury.
    ///        7. Distribute royalty → royalty receiver.
    ///        8a. If active loan: approve pool + call settleLoanRepaymentOnSale (pool delivers NFT).
    ///        8b. If no loan (incl. pool-default): transferFrom(seller, buyer).
    ///        9. Pay seller net proceeds.
    ///        Note: for pool-default sales, settleAuction calls onDefaultedAssetSold afterward
    ///        (after this function returns) to resolve the default record in the pool.
    function _executeSale(
        MarketplaceStorage storage $,
        address seller,
        address collection,
        uint256 tokenId,
        address paymentToken,
        uint256 gross,
        address buyer
    ) internal {
        // 1. Pool-default detection: if this tokenId was listed by listDefaultedAsset, waive
        //    collectible fee and royalty so the pool receives full gross proceeds (= winning bid).
        //    Reserve enforcement already ensured gross >= principal+interest at bid time.
        bool isPoolDefault = $.poolDefaultLoanOf[tokenId] != 0;

        uint256 collectibleFee = 0;
        uint256 royalty = 0;
        address royaltyReceiver = address(0);

        if (!isPoolDefault) {
            // 2. Collectible fee (normal path only)
            (collectibleFee, ) = $.feeController.getCollectibleFee(gross);

            // 3. Royalty (EIP-2981, try/catch, capped; normal path only)
            try IERC2981(collection).royaltyInfo(tokenId, gross) returns (
                address receiver,
                uint256 amount
            ) {
                royaltyReceiver = receiver;
                royalty = amount;
            } catch {} // solhint-disable-line no-empty-blocks
        }

        // 4. Loan debt (active loan check — always zero for pool-default since tokenIdToActiveLoan
        //    was cleared by _initiateDefault, but checked uniformly for correctness)
        (, , uint256 loanDebt) = $.lendingPool.getLoanDebt(tokenId);
        uint256 activeLoanId =
            loanDebt > 0 ? $.lendingPool.getActiveLoanId(tokenId) : 0;

        if (!isPoolDefault) {
            // Cap royalty: must not exceed (gross - collectibleFee - loanDebt)
            if (collectibleFee + loanDebt < gross) {
                uint256 maxRoyalty = gross - collectibleFee - loanDebt;
                if (royalty > maxRoyalty) royalty = maxRoyalty;
            } else {
                royalty = 0;
            }
        }

        // MinPrice enforcement: gross must cover fees + loan (for pool-default: fees=0, loanDebt=0)
        uint256 required = collectibleFee + royalty + loanDebt;
        if (gross < required)
            revert Marketplace__PriceBelowMinimum(gross, required);

        uint256 sellerProceeds = gross - collectibleFee - royalty - loanDebt;

        // 5. Pull gross from buyer
        IERC20(paymentToken).safeTransferFrom(buyer, address(this), gross);

        // 6. Collectible fee → treasury
        if (collectibleFee > 0) {
            IERC20(paymentToken).safeTransfer($.treasury, collectibleFee);
        }

        // 7. Royalty → receiver
        if (royalty > 0 && royaltyReceiver != address(0)) {
            IERC20(paymentToken).safeTransfer(royaltyReceiver, royalty);
        }

        // 8. NFT delivery
        if (loanDebt > 0) {
            // 8a. Active loan branch: approve pool then settle atomically.
            //     Pool pulls loanDebt from this contract, clears the loan, and delivers NFT to buyer.
            IERC20(paymentToken).forceApprove(address($.lendingPool), loanDebt);
            $.lendingPool.settleLoanRepaymentOnSale(
                activeLoanId,
                address(this),
                buyer
            );
        } else {
            // 8b. No active loan (normal seller or pool-default): transfer from seller directly.
            //     For pool-default, seller == lendingPool and the pool pre-approved this contract
            //     via prepareDefaultedListing.
            IAssetNFT(collection).transferFrom(seller, buyer, tokenId);
        }

        // 9. Seller proceeds → seller (for pool-default: sellerProceeds == gross → pool)
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

    function _hashAuction(
        SignedAuction calldata auction
    ) internal pure returns (bytes32) {
        return
            keccak256(
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
    function _getPermissionManager()
        internal
        view
        returns (IPermissionManager)
    {
        return IPermissionManager(getPermissionManager());
    }
}
