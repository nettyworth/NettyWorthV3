// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IP2PTradeEscrow} from "./interfaces/IP2PTradeEscrow.sol";

/// @title P2PTradeEscrow
/// @author NettyWorth
/// @notice Atomic peer-to-peer swap escrow enabling trades of any combination of ERC20,
///         ERC721 (including AssetNFT), and ERC1155 assets between a named initiator and
///         a designated counterparty. Independent of the NettyWorth marketplace and lending pool.
/// @dev UUPS upgradeable. Access control via Ownable2StepUpgradeable (single admin/owner).
///      Uses ERC-7201 namespaced storage. ERC1155Holder (stateless, OZ v5) enables receiving
///      ERC1155 tokens into escrow.
///      AssetNFT (ERC721) is treated as a generic ERC721: the token must be in Held state before
///      escrowing (enforced by AssetNFT's _beforeTokenTransfers). No STATE_MANAGER_ROLE required.
///      All state-changing functions are protected by ReentrancyGuard; cancelTrade,
///      expireTrade, rejectTrade and claimRefund intentionally omit whenNotPaused so
///      escrowed assets can always be reclaimed.
///      Every action is sent by the party itself (msg.sender): there is no signature-relayed
///      path, so nothing a user signs off-chain can move their assets. Each side's ERC20
///      items come from, and are refunded to, that side's own address.
/// @custom:security-contact security@nettyworth.io
contract P2PTradeEscrow is
    IP2PTradeEscrow,
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    ERC1155Holder
{
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev Maximum number of assets allowed in a single bundle side (offered or requested).
    uint256 private constant MAX_BUNDLE = 50;

    // =========================================================================
    // Storage (ERC-7201) — layout must never change across upgrades
    // =========================================================================

    // Layout v2: the funded path's fields (erc20Payer, usedNonces, refundRecipient) were removed
    // before production, so this layout does NOT match the retired staging proxy
    // 0x535dbd7b89ac69da91c1cdb71d0f04903e88ce60. Never upgrade that proxy to this
    // implementation — the allow-list and pending refunds would read the wrong slots. From here
    // on, append only.

    /// @custom:storage-location erc7201:nettyworth.storage.P2PTradeEscrow
    struct P2PTradeEscrowStorage {
        /// @dev Monotonically incrementing counter; also equals the total number of trades created.
        uint256 nextTradeId;
        /// @dev Trade records indexed by trade ID.
        mapping(uint256 tradeId => Trade) trades;
        /// @dev Tokens allowed in new trades: bit `uint8(AssetType)` set = allowed as that type.
        mapping(address token => uint256 typeMask) allowedTokenTypes;
        /// @dev Escrowed items whose return failed when their trade closed, and who they are
        ///      held for. Retried with claimRefund.
        mapping(uint256 tradeId => mapping(uint256 itemIndex => address)) pendingRefunds;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.P2PTradeEscrow")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant P2P_TRADE_ESCROW_STORAGE_SLOT =
        0x2abc3038c5fa10b507dd201453438855dadc9f08daf378fc4cc65ac1d08dbc00;

    function _getStorage()
        internal
        pure
        returns (P2PTradeEscrowStorage storage $)
    {
        assembly {
            $.slot := P2P_TRADE_ESCROW_STORAGE_SLOT
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

    /// @notice Initializes the proxy.
    /// @param initialOwner_ Address to receive ownership (admin).
    function initialize(address initialOwner_) external initializer {
        if (initialOwner_ == address(0)) revert P2PTradeEscrow__ZeroAddress();
        __Ownable_init(initialOwner_);
        __Ownable2Step_init();
        __Pausable_init();
    }

    // =========================================================================
    // Core: createTrade
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    function createTrade(
        address counterparty_,
        Asset[] calldata offered_,
        Asset[] calldata requested_,
        uint64 deadline_
    ) external nonReentrant whenNotPaused returns (uint256 tradeId) {
        tradeId = _createTrade(
            msg.sender,
            counterparty_,
            offered_,
            requested_,
            deadline_
        );
    }

    /// @dev Shared body of createTrade and counterTrade: validates the bundles, records the
    ///      trade and pulls every offered item from `initiator` into escrow.
    function _createTrade(
        address initiator,
        address counterparty_,
        Asset[] calldata offered_,
        Asset[] calldata requested_,
        uint64 deadline_
    ) internal returns (uint256 tradeId) {
        // --- Validate inputs ---
        if (counterparty_ == address(0)) revert P2PTradeEscrow__ZeroAddress();
        if (counterparty_ == initiator)
            revert P2PTradeEscrow__InvalidCounterparty();
        if (offered_.length == 0) revert P2PTradeEscrow__EmptyBundle();
        if (requested_.length == 0) revert P2PTradeEscrow__EmptyBundle();
        if (offered_.length > MAX_BUNDLE)
            revert P2PTradeEscrow__BundleTooLarge();
        if (requested_.length > MAX_BUNDLE)
            revert P2PTradeEscrow__BundleTooLarge();
        if (deadline_ != 0 && deadline_ <= block.timestamp)
            revert P2PTradeEscrow__InvalidDeadline();

        for (uint256 i; i < offered_.length; ) {
            _validateAsset(offered_[i]);
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < requested_.length; ) {
            _validateAsset(requested_[i]);
            unchecked {
                ++i;
            }
        }

        P2PTradeEscrowStorage storage $ = _getStorage();

        // --- Allocate trade ID ---
        tradeId = $.nextTradeId++;

        // --- Write trade record (no arrays yet — push below) ---
        Trade storage t = $.trades[tradeId];
        t.initiator = initiator;
        t.counterparty = counterparty_;
        t.deadline = deadline_;
        t.status = TradeStatus.Active;

        // Copy offered and requested arrays into storage
        for (uint256 i; i < offered_.length; ) {
            t.offered.push(offered_[i]);
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < requested_.length; ) {
            t.requested.push(requested_[i]);
            unchecked {
                ++i;
            }
        }

        // --- Pull offered assets into escrow from the initiator ---
        for (uint256 i; i < offered_.length; ) {
            _pullIn(initiator, offered_[i]);
            unchecked {
                ++i;
            }
        }

        emit TradeCreated(tradeId, initiator, counterparty_, deadline_);
    }

    // =========================================================================
    // Core: counterTrade
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    function counterTrade(
        uint256 tradeId,
        Asset[] calldata offered_,
        Asset[] calldata requested_,
        uint64 deadline_
    ) external nonReentrant whenNotPaused returns (uint256 newTradeId) {
        Trade storage t = _getStorage().trades[tradeId];
        if (t.status != TradeStatus.Active)
            revert P2PTradeEscrow__TradeNotActive();
        if (msg.sender != t.counterparty)
            revert P2PTradeEscrow__NotCounterparty();
        if (t.deadline != 0 && block.timestamp > t.deadline)
            revert P2PTradeEscrow__TradeExpired();

        // Close the original as Countered — its escrow returns to its initiator, so they can
        // accept the counter in one transaction — then open the counter with roles swapped.
        address originalInitiator = t.initiator;

        _closeAndRefund(tradeId, TradeStatus.Countered);

        newTradeId = _createTrade(
            msg.sender,
            originalInitiator,
            offered_,
            requested_,
            deadline_
        );
        emit TradeCountered(tradeId, newTradeId);
    }

    // =========================================================================
    // Core: acceptTrade
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    function acceptTrade(uint256 tradeId) external nonReentrant whenNotPaused {
        Trade storage t = _getStorage().trades[tradeId];

        // --- Checks ---
        if (t.status != TradeStatus.Active)
            revert P2PTradeEscrow__TradeNotActive();
        if (msg.sender != t.counterparty)
            revert P2PTradeEscrow__NotCounterparty();
        if (t.deadline != 0 && block.timestamp > t.deadline)
            revert P2PTradeEscrow__TradeExpired();

        address initiator = t.initiator;
        address counterparty = t.counterparty;

        // --- Effects: mark completed before any external calls (CEI) ---
        t.status = TradeStatus.Accepted;

        // --- Interactions ---
        // 1. Pull requested assets from the counterparty straight to the initiator.
        uint256 reqLen = t.requested.length;
        for (uint256 i; i < reqLen; ) {
            _transferDirect(counterparty, initiator, t.requested[i]);
            unchecked {
                ++i;
            }
        }

        // 2. Release escrowed offered assets from this contract to counterparty.
        uint256 offLen = t.offered.length;
        for (uint256 i; i < offLen; ) {
            _transferOut(counterparty, t.offered[i]);
            unchecked {
                ++i;
            }
        }

        emit TradeAccepted(tradeId, counterparty);
    }

    // =========================================================================
    // Core: cancelTrade
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    /// @dev Intentionally omits `whenNotPaused` — initiators can always reclaim assets.
    function cancelTrade(uint256 tradeId) external nonReentrant {
        P2PTradeEscrowStorage storage $ = _getStorage();
        Trade storage t = $.trades[tradeId];

        // --- Checks ---
        if (t.status != TradeStatus.Active)
            revert P2PTradeEscrow__TradeNotActive();
        if (msg.sender != t.initiator) revert P2PTradeEscrow__NotInitiator();

        _closeAndRefund(tradeId, TradeStatus.Cancelled);

        emit TradeCancelled(tradeId, msg.sender);
    }

    // =========================================================================
    // Core: rejectTrade
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    /// @dev Intentionally omits `whenNotPaused`, and allowed past the deadline — a declined
    ///      offer returns the initiator's assets whatever state the contract is in.
    function rejectTrade(uint256 tradeId) external nonReentrant {
        Trade storage t = _getStorage().trades[tradeId];

        // --- Checks ---
        if (t.status != TradeStatus.Active)
            revert P2PTradeEscrow__TradeNotActive();
        if (msg.sender != t.counterparty)
            revert P2PTradeEscrow__NotCounterparty();

        _closeAndRefund(tradeId, TradeStatus.Rejected);

        emit TradeRejected(tradeId, msg.sender);
    }

    // =========================================================================
    // Refunds: claimRefund
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    /// @dev Intentionally omits `whenNotPaused`. Anyone may trigger it, but the item only ever
    ///      goes to the recipient recorded when the trade closed — a blocked recipient (e.g.
    ///      blacklisted on AssetNFT) cannot redirect it elsewhere.
    function claimRefund(
        uint256 tradeId,
        uint256 itemIndex
    ) external nonReentrant {
        P2PTradeEscrowStorage storage $ = _getStorage();
        address to = $.pendingRefunds[tradeId][itemIndex];
        if (to == address(0)) revert P2PTradeEscrow__NoPendingRefund();

        // --- Effects ---
        delete $.pendingRefunds[tradeId][itemIndex];

        // --- Interactions --- (a failure reverts and leaves the refund pending)
        if (!_tryTransferOut(to, $.trades[tradeId].offered[itemIndex]))
            revert P2PTradeEscrow__RefundFailed();

        emit RefundClaimed(tradeId, itemIndex, to);
    }

    // =========================================================================
    // Core: expireTrade
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    /// @dev Intentionally omits `whenNotPaused` — anyone can free escrow after deadline.
    function expireTrade(uint256 tradeId) external nonReentrant {
        P2PTradeEscrowStorage storage $ = _getStorage();
        Trade storage t = $.trades[tradeId];

        // --- Checks ---
        if (t.status != TradeStatus.Active)
            revert P2PTradeEscrow__TradeNotActive();
        if (t.deadline == 0 || block.timestamp <= t.deadline)
            revert P2PTradeEscrow__NotYetExpired();

        _closeAndRefund(tradeId, TradeStatus.Expired);

        emit TradeExpired(tradeId);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IP2PTradeEscrow
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IP2PTradeEscrow
    function setTokenAllowed(
        address token,
        AssetType assetType,
        bool allowed
    ) external onlyOwner {
        if (token == address(0)) revert P2PTradeEscrow__ZeroAddress();
        P2PTradeEscrowStorage storage $ = _getStorage();
        uint256 bit = uint256(1) << uint8(assetType);
        $.allowedTokenTypes[token] =
            allowed
                ? $.allowedTokenTypes[token] | bit
                : $.allowedTokenTypes[token] & ~bit;
        emit TokenAllowedSet(token, assetType, allowed);
    }

    /// @notice Disabled: without an owner, the token allow-list, pausing and upgrades could
    ///         never be managed again.
    function renounceOwnership() public pure override {
        revert P2PTradeEscrow__RenounceDisabled();
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    function getTrade(uint256 tradeId) external view returns (Trade memory) {
        return _getStorage().trades[tradeId];
    }

    /// @inheritdoc IP2PTradeEscrow
    function nextTradeId() external view returns (uint256) {
        return _getStorage().nextTradeId;
    }

    /// @inheritdoc IP2PTradeEscrow
    function isTokenAllowed(
        address token,
        AssetType assetType
    ) external view returns (bool) {
        return _isTokenAllowed(token, assetType);
    }

    /// @inheritdoc IP2PTradeEscrow
    function pendingRefundOf(
        uint256 tradeId,
        uint256 itemIndex
    ) external view returns (address) {
        return _getStorage().pendingRefunds[tradeId][itemIndex];
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Closes an Active trade with `newStatus` and returns the escrowed bundle to the
    ///      initiator. Each item is returned independently: one that fails (recipient hook
    ///      reverts, AssetNFT paused or recipient blacklisted, token refuses) is left in escrow
    ///      as a pending refund for claimRefund instead of reverting the close. Otherwise one
    ///      undeliverable item would freeze the whole bundle, and block the counterparty's
    ///      reject and counter.
    ///      Note: an item's call forwards 63/64 of the remaining gas, so a recipient hook that
    ///      burns it all could still exhaust the transaction. Only ERC1155 has a recipient hook;
    ///      keep ERC1155 off the token allow-list unless that is acceptable.
    function _closeAndRefund(uint256 tradeId, TradeStatus newStatus) internal {
        P2PTradeEscrowStorage storage $ = _getStorage();
        Trade storage t = $.trades[tradeId];

        address initiator = t.initiator;

        // --- Effects ---
        t.status = newStatus;

        // --- Interactions ---
        uint256 offLen = t.offered.length;
        for (uint256 i; i < offLen; ) {
            if (!_tryTransferOut(initiator, t.offered[i])) {
                $.pendingRefunds[tradeId][i] = initiator;
                emit RefundPending(tradeId, i, initiator);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Like _transferOut, but reports failure instead of reverting.
    function _tryTransferOut(
        address to,
        Asset memory asset
    ) internal returns (bool) {
        if (asset.assetType == AssetType.ERC20) {
            return IERC20(asset.token).trySafeTransfer(to, asset.amount);
        } else if (asset.assetType == AssetType.ERC721) {
            try
                IERC721(asset.token).transferFrom(
                    address(this),
                    to,
                    asset.tokenId
                )
            {
                return true;
            } catch {
                return false;
            }
        } else {
            try
                IERC1155(asset.token).safeTransferFrom(
                    address(this),
                    to,
                    asset.tokenId,
                    asset.amount,
                    ""
                )
            {
                return true;
            } catch {
                return false;
            }
        }
    }

    /// @dev True when `token` is on the allow-list as `assetType`.
    function _isTokenAllowed(
        address token,
        AssetType assetType
    ) internal view returns (bool) {
        return
            (_getStorage().allowedTokenTypes[token] >> uint8(assetType)) & 1 ==
            1;
    }

    /// @dev Validates that an Asset struct is well-formed.
    ///      Only allow-listed (token, type) pairs may enter a trade: an arbitrary token could
    ///      lie about transfers, charge a fee or rebase (draining other trades' pooled balance
    ///      of it), or be declared as the wrong type and lock forever.
    function _validateAsset(Asset calldata asset) internal view {
        if (asset.token == address(0)) revert P2PTradeEscrow__InvalidAsset();
        if (!_isTokenAllowed(asset.token, asset.assetType))
            revert P2PTradeEscrow__TokenNotAllowed();
        if (asset.assetType == AssetType.ERC20) {
            if (asset.amount == 0) revert P2PTradeEscrow__InvalidAsset();
        } else if (asset.assetType == AssetType.ERC1155) {
            if (asset.amount == 0) revert P2PTradeEscrow__InvalidAsset();
        }
        // ERC721: amount is ignored; tokenId validity is enforced by the token contract itself.
    }

    /// @dev Pulls an asset from `from` into this contract (escrow).
    function _pullIn(address from, Asset memory asset) internal {
        if (asset.assetType == AssetType.ERC20) {
            IERC20(asset.token).safeTransferFrom(
                from,
                address(this),
                asset.amount
            );
        } else if (asset.assetType == AssetType.ERC721) {
            IERC721(asset.token).transferFrom(
                from,
                address(this),
                asset.tokenId
            );
        } else {
            // ERC1155
            IERC1155(asset.token).safeTransferFrom(
                from,
                address(this),
                asset.tokenId,
                asset.amount,
                ""
            );
        }
    }

    /// @dev Transfers an asset from this contract to `to` (releasing escrow).
    function _transferOut(address to, Asset memory asset) internal {
        if (asset.assetType == AssetType.ERC20) {
            IERC20(asset.token).safeTransfer(to, asset.amount);
        } else if (asset.assetType == AssetType.ERC721) {
            IERC721(asset.token).transferFrom(address(this), to, asset.tokenId);
        } else {
            // ERC1155
            IERC1155(asset.token).safeTransferFrom(
                address(this),
                to,
                asset.tokenId,
                asset.amount,
                ""
            );
        }
    }

    /// @dev Transfers an asset directly from `from` to `to` (no escrow leg).
    ///      Used at accept time: pulls requested assets from counterparty straight to initiator.
    function _transferDirect(
        address from,
        address to,
        Asset memory asset
    ) internal {
        if (asset.assetType == AssetType.ERC20) {
            IERC20(asset.token).safeTransferFrom(from, to, asset.amount);
        } else if (asset.assetType == AssetType.ERC721) {
            IERC721(asset.token).transferFrom(from, to, asset.tokenId);
        } else {
            // ERC1155
            IERC1155(asset.token).safeTransferFrom(
                from,
                to,
                asset.tokenId,
                asset.amount,
                ""
            );
        }
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    /// @dev Only the owner can authorize an upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}
}
