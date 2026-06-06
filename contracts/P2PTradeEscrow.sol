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
///      All state-changing functions are protected by ReentrancyGuard; cancelTrade and
///      expireTrade intentionally omit whenNotPaused so initiators can always reclaim assets.
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

    /// @custom:storage-location erc7201:nettyworth.storage.P2PTradeEscrow
    struct P2PTradeEscrowStorage {
        /// @dev Monotonically incrementing counter; also equals the total number of trades created.
        uint256 nextTradeId;
        /// @dev Trade records indexed by trade ID.
        mapping(uint256 tradeId => Trade) trades;
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
        // --- Validate inputs ---
        if (counterparty_ == address(0)) revert P2PTradeEscrow__ZeroAddress();
        if (counterparty_ == msg.sender)
            revert P2PTradeEscrow__InvalidCounterparty();
        if (offered_.length == 0) revert P2PTradeEscrow__EmptyBundle();
        if (requested_.length == 0) revert P2PTradeEscrow__EmptyBundle();
        if (offered_.length > MAX_BUNDLE) revert P2PTradeEscrow__BundleTooLarge();
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

        // --- Allocate trade ID ---
        P2PTradeEscrowStorage storage $ = _getStorage();
        tradeId = $.nextTradeId++;

        // --- Write trade record (no arrays yet — push below) ---
        Trade storage t = $.trades[tradeId];
        t.initiator = msg.sender;
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

        // --- Pull offered assets from initiator into escrow ---
        for (uint256 i; i < offered_.length; ) {
            _pullIn(msg.sender, offered_[i]);
            unchecked {
                ++i;
            }
        }

        emit TradeCreated(tradeId, msg.sender, counterparty_, deadline_);
    }

    // =========================================================================
    // Core: acceptTrade
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    function acceptTrade(uint256 tradeId) external nonReentrant whenNotPaused {
        P2PTradeEscrowStorage storage $ = _getStorage();
        Trade storage t = $.trades[tradeId];

        // --- Checks ---
        if (t.status != TradeStatus.Active) revert P2PTradeEscrow__TradeNotActive();
        if (msg.sender != t.counterparty) revert P2PTradeEscrow__NotCounterparty();
        if (t.deadline != 0 && block.timestamp > t.deadline)
            revert P2PTradeEscrow__TradeExpired();

        address initiator = t.initiator;
        address counterparty = t.counterparty;

        // --- Effects: mark completed before any external calls (CEI) ---
        t.status = TradeStatus.Accepted;

        // --- Interactions ---
        // 1. Pull requested assets from counterparty directly to initiator.
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
        if (t.status != TradeStatus.Active) revert P2PTradeEscrow__TradeNotActive();
        if (msg.sender != t.initiator) revert P2PTradeEscrow__NotInitiator();

        address initiator = t.initiator;

        // --- Effects ---
        t.status = TradeStatus.Cancelled;

        // --- Interactions: return escrowed assets to initiator ---
        uint256 offLen = t.offered.length;
        for (uint256 i; i < offLen; ) {
            _transferOut(initiator, t.offered[i]);
            unchecked {
                ++i;
            }
        }

        emit TradeCancelled(tradeId, initiator);
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
        if (t.status != TradeStatus.Active) revert P2PTradeEscrow__TradeNotActive();
        if (t.deadline == 0 || block.timestamp <= t.deadline)
            revert P2PTradeEscrow__NotYetExpired();

        address initiator = t.initiator;

        // --- Effects ---
        t.status = TradeStatus.Expired;

        // --- Interactions: return escrowed assets to initiator ---
        uint256 offLen = t.offered.length;
        for (uint256 i; i < offLen; ) {
            _transferOut(initiator, t.offered[i]);
            unchecked {
                ++i;
            }
        }

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

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Validates that an Asset struct is well-formed.
    function _validateAsset(Asset calldata asset) internal pure {
        if (asset.token == address(0)) revert P2PTradeEscrow__InvalidAsset();
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
            IERC20(asset.token).safeTransferFrom(from, address(this), asset.amount);
        } else if (asset.assetType == AssetType.ERC721) {
            IERC721(asset.token).transferFrom(from, address(this), asset.tokenId);
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
