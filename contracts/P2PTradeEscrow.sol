// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
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
///      expireTrade, rejectTrade and cancelFundedTrade intentionally omit whenNotPaused so
///      escrowed assets can always be reclaimed.
///      Funded path (createTradeFor / counterTradeFor / acceptTradeFor): anyone may submit a
///      trade action the user signed (EIP-712) and pay that side's ERC20 items itself — in
///      practice Coinflow's relayer, whose addresses are not fixed, so there is no allow-list.
///      The signature binds the trade to the user; the caller only pays. Offered ERC20 items
///      paid by someone other than the initiator are refunded to the owner-set refund
///      recipient — never to the initiator, so a card charge can't become withdrawable USDC —
///      when the trade closes without being accepted; the API turns that into store credit.
/// @custom:security-contact security@nettyworth.io
contract P2PTradeEscrow is
    IP2PTradeEscrow,
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuard,
    ERC1155Holder
{
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev Maximum number of assets allowed in a single bundle side (offered or requested).
    uint256 private constant MAX_BUNDLE = 50;

    /// @dev Longest window a signature may be usable in (validBefore - validAfter). An unused
    ///      signature is a firm option anyone can exercise, so it must not outlive the checkout
    ///      it was for. The window is signed, so it bounds the signature itself — not just how
    ///      long before expiry it is submitted.
    uint256 public constant MAX_SIGNATURE_TTL = 1 hours;

    /// @notice EIP-712 typehash of a bundle item.
    bytes32 public constant ASSET_TYPEHASH = keccak256(
        "Asset(uint8 assetType,address token,uint256 tokenId,uint256 amount)"
    );

    /// @notice EIP-712 typehash of a trade offer signed by its initiator (createTradeFor).
    bytes32 public constant CREATE_TRADE_TYPEHASH = keccak256(
        "CreateTrade(address initiator,address counterparty,Asset[] offered,Asset[] requested,uint64 deadline,uint256 nonce,uint256 validBefore,uint256 validAfter)"
        "Asset(uint8 assetType,address token,uint256 tokenId,uint256 amount)"
    );

    /// @notice EIP-712 typehash of a counter-offer signed by the original counterparty
    ///         (counterTradeFor).
    bytes32 public constant COUNTER_TRADE_TYPEHASH = keccak256(
        "CounterTrade(uint256 tradeId,address counterparty,Asset[] offered,Asset[] requested,uint64 deadline,uint256 nonce,uint256 validBefore,uint256 validAfter)"
        "Asset(uint8 assetType,address token,uint256 tokenId,uint256 amount)"
    );

    /// @notice EIP-712 typehash of an acceptance signed by the counterparty (acceptTradeFor).
    ///         Binds both bundles, so the signer approves exactly what they were shown.
    bytes32 public constant ACCEPT_TRADE_TYPEHASH = keccak256(
        "AcceptTrade(uint256 tradeId,address counterparty,Asset[] offered,Asset[] requested,uint256 nonce,uint256 validBefore,uint256 validAfter)"
        "Asset(uint8 assetType,address token,uint256 tokenId,uint256 amount)"
    );

    // =========================================================================
    // Storage (ERC-7201) — layout must never change across upgrades
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.P2PTradeEscrow
    struct P2PTradeEscrowStorage {
        /// @dev Monotonically incrementing counter; also equals the total number of trades created.
        uint256 nextTradeId;
        /// @dev Trade records indexed by trade ID.
        mapping(uint256 tradeId => Trade) trades;
        /// @dev Who paid a trade's offered ERC20 items, when not the initiator (createTradeFor /
        ///      counterTradeFor). address(0) = the initiator paid, or no ERC20 was offered.
        ///      Non-zero means those items are refunded to `refundRecipient`.
        mapping(uint256 tradeId => address) erc20Payer;
        /// @dev EIP-712 signature nonces used or cancelled, per signer.
        mapping(address signer => mapping(uint256 nonce => bool)) usedNonces;
        /// @dev NettyWorth wallet that receives externally funded ERC20 refunds and may cancel
        ///      externally funded trades (chargebacks).
        address refundRecipient;
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
        __EIP712_init("P2PTradeEscrow", "1");
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
            msg.sender,
            counterparty_,
            offered_,
            requested_,
            deadline_
        );
    }

    /// @inheritdoc IP2PTradeEscrow
    function createTradeFor(
        CreateTradeParams calldata params,
        bytes calldata sig
    ) external nonReentrant whenNotPaused returns (uint256 tradeId) {
        bytes32 structHash = keccak256(
            abi.encode(
                CREATE_TRADE_TYPEHASH,
                params.initiator,
                params.counterparty,
                _hashAssets(params.offered),
                _hashAssets(params.requested),
                params.deadline,
                params.nonce,
                params.validBefore,
                params.validAfter
            )
        );
        _useSignature(
            params.initiator,
            structHash,
            params.nonce,
            params.validBefore,
            params.validAfter,
            sig
        );

        tradeId = _createTrade(
            params.initiator,
            msg.sender,
            params.counterparty,
            params.offered,
            params.requested,
            params.deadline
        );
    }

    /// @dev Shared body of every trade-opening path. Offered ERC20 items are pulled from
    ///      `payer`, ERC721 / ERC1155 items from `initiator`. When someone other than the
    ///      initiator pays ERC20 items, `payer` is recorded and those items are refunded to the
    ///      refund recipient rather than to the initiator.
    function _createTrade(
        address initiator,
        address payer,
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
        bool externallyFunded = payer != initiator && _hasErc20(offered_);
        if (externallyFunded && $.refundRecipient == address(0))
            revert P2PTradeEscrow__RefundRecipientNotSet();

        // --- Allocate trade ID ---
        tradeId = $.nextTradeId++;

        // --- Write trade record (no arrays yet — push below) ---
        Trade storage t = $.trades[tradeId];
        t.initiator = initiator;
        t.counterparty = counterparty_;
        t.deadline = deadline_;
        t.status = TradeStatus.Active;
        if (externallyFunded) $.erc20Payer[tradeId] = payer;

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

        // --- Pull offered assets into escrow: ERC20 from payer, the rest from initiator ---
        for (uint256 i; i < offered_.length; ) {
            _pullIn(
                offered_[i].assetType == AssetType.ERC20 ? payer : initiator,
                offered_[i]
            );
            unchecked {
                ++i;
            }
        }

        emit TradeCreated(tradeId, initiator, counterparty_, deadline_);
        if (externallyFunded) emit TradeCreatedFor(tradeId, payer);
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

        newTradeId = _counterTrade(
            tradeId,
            msg.sender,
            offered_,
            requested_,
            deadline_
        );
    }

    /// @inheritdoc IP2PTradeEscrow
    function counterTradeFor(
        CounterTradeParams calldata params,
        bytes calldata sig
    ) external nonReentrant whenNotPaused returns (uint256 newTradeId) {
        Trade storage t = _getStorage().trades[params.tradeId];
        // Status first: a closed trade fails before any signature work.
        if (t.status != TradeStatus.Active)
            revert P2PTradeEscrow__TradeNotActive();
        address counterparty = t.counterparty;

        bytes32 structHash = keccak256(
            abi.encode(
                COUNTER_TRADE_TYPEHASH,
                params.tradeId,
                counterparty,
                _hashAssets(params.offered),
                _hashAssets(params.requested),
                params.deadline,
                params.nonce,
                params.validBefore,
                params.validAfter
            )
        );
        _useSignature(
            counterparty,
            structHash,
            params.nonce,
            params.validBefore,
            params.validAfter,
            sig
        );

        newTradeId = _counterTrade(
            params.tradeId,
            msg.sender,
            params.offered,
            params.requested,
            params.deadline
        );
    }

    /// @dev Shared body of counterTrade / counterTradeFor; the caller has checked the trade
    ///      is Active and authorised the counter. Closes the original as Countered — its escrow
    ///      returns to its initiator, so they can accept the counter in one transaction — and
    ///      opens the counter with the roles swapped, its ERC20 items paid by `payer`.
    function _counterTrade(
        uint256 tradeId,
        address payer,
        Asset[] calldata offered_,
        Asset[] calldata requested_,
        uint64 deadline_
    ) internal returns (uint256 newTradeId) {
        Trade storage t = _getStorage().trades[tradeId];
        if (t.deadline != 0 && block.timestamp > t.deadline)
            revert P2PTradeEscrow__TradeExpired();

        address originalInitiator = t.initiator;
        address originalCounterparty = t.counterparty;

        _closeAndRefund(tradeId, TradeStatus.Countered);

        newTradeId = _createTrade(
            originalCounterparty,
            payer,
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

        _acceptTrade(tradeId, msg.sender);
    }

    /// @inheritdoc IP2PTradeEscrow
    function acceptTradeFor(
        uint256 tradeId,
        uint256 nonce,
        uint256 validBefore,
        uint256 validAfter,
        bytes calldata sig
    ) external nonReentrant whenNotPaused {
        Trade storage t = _getStorage().trades[tradeId];

        // --- Checks --- (status first: a closed trade fails before any signature work)
        if (t.status != TradeStatus.Active)
            revert P2PTradeEscrow__TradeNotActive();
        address counterparty = t.counterparty;
        _useSignature(
            counterparty,
            keccak256(
                abi.encode(
                    ACCEPT_TRADE_TYPEHASH,
                    tradeId,
                    counterparty,
                    _hashAssets(t.offered),
                    _hashAssets(t.requested),
                    nonce,
                    validBefore,
                    validAfter
                )
            ),
            nonce,
            validBefore,
            validAfter,
            sig
        );

        _acceptTrade(tradeId, msg.sender);
        emit TradeAcceptedFor(tradeId, msg.sender);
    }

    /// @dev Shared body of acceptTrade / acceptTradeFor; the caller has checked the trade is
    ///      Active and authorised the acceptance. Requested ERC20 items are pulled from
    ///      `erc20Source`, requested ERC721 / ERC1155 items from the counterparty.
    function _acceptTrade(uint256 tradeId, address erc20Source) internal {
        Trade storage t = _getStorage().trades[tradeId];

        if (t.deadline != 0 && block.timestamp > t.deadline)
            revert P2PTradeEscrow__TradeExpired();

        address initiator = t.initiator;
        address counterparty = t.counterparty;

        // --- Effects: mark completed before any external calls (CEI) ---
        t.status = TradeStatus.Accepted;

        // --- Interactions ---
        // 1. Pull requested assets straight to the initiator: ERC20 from erc20Source,
        //    the rest from the counterparty.
        uint256 reqLen = t.requested.length;
        for (uint256 i; i < reqLen; ) {
            Asset memory asset = t.requested[i];
            _transferDirect(
                asset.assetType == AssetType.ERC20 ? erc20Source : counterparty,
                initiator,
                asset
            );
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
    // Core: cancelFundedTrade
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    /// @dev Intentionally omits `whenNotPaused`. Limited to externally funded trades: the money
    ///      at stake is NettyWorth's (it refunds the user as credit), so it may take it back
    ///      when the card payment behind it is charged back. NFTs still go to the initiator.
    function cancelFundedTrade(uint256 tradeId) external nonReentrant {
        P2PTradeEscrowStorage storage $ = _getStorage();
        Trade storage t = $.trades[tradeId];

        // --- Checks ---
        if (msg.sender != $.refundRecipient)
            revert P2PTradeEscrow__NotRefundRecipient();
        if (t.status != TradeStatus.Active)
            revert P2PTradeEscrow__TradeNotActive();
        if ($.erc20Payer[tradeId] == address(0))
            revert P2PTradeEscrow__NotExternallyFunded();

        _closeAndRefund(tradeId, TradeStatus.Cancelled);

        emit TradeCancelled(tradeId, t.initiator);
        emit FundedTradeCancelled(tradeId);
    }

    // =========================================================================
    // Signatures: cancelNonce
    // =========================================================================

    /// @inheritdoc IP2PTradeEscrow
    function cancelNonce(uint256 nonce) external {
        P2PTradeEscrowStorage storage $ = _getStorage();
        if ($.usedNonces[msg.sender][nonce]) revert P2PTradeEscrow__NonceUsed();
        $.usedNonces[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
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
    function setRefundRecipient(address refundRecipient_) external onlyOwner {
        // The escrow itself would turn refunds into untracked, unrecoverable surplus.
        if (refundRecipient_ == address(0) || refundRecipient_ == address(this))
            revert P2PTradeEscrow__ZeroAddress();
        _getStorage().refundRecipient = refundRecipient_;
        emit RefundRecipientSet(refundRecipient_);
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

    /// @notice Disabled: without an owner, the refund recipient, token allow-list and
    ///         upgrades could never be managed again.
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
    function erc20PayerOf(uint256 tradeId) external view returns (address) {
        return _getStorage().erc20Payer[tradeId];
    }

    /// @inheritdoc IP2PTradeEscrow
    function isNonceUsed(
        address signer,
        uint256 nonce
    ) external view returns (bool) {
        return _getStorage().usedNonces[signer][nonce];
    }

    /// @inheritdoc IP2PTradeEscrow
    function refundRecipient() external view returns (address) {
        return _getStorage().refundRecipient;
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

    /// @dev Closes an Active trade with `newStatus` and returns the escrowed bundle: ERC20
    ///      items to the refund recipient when someone other than the initiator paid them,
    ///      everything else — and ERC20 items the initiator paid for — to the initiator.
    ///      Each item is returned independently: one that fails (recipient hook reverts,
    ///      AssetNFT paused or recipient blacklisted, token refuses) is left in escrow as a
    ///      pending refund for claimRefund instead of reverting the close. Otherwise the
    ///      initiator could keep a card-funded stake frozen (and cancelFundedTrade unusable)
    ///      just by making one of their own items undeliverable.
    ///      Note: an item's call forwards 63/64 of the remaining gas, so a recipient hook that
    ///      burns it all could still exhaust the transaction. Only ERC1155 has a recipient hook;
    ///      keep ERC1155 off the token allow-list unless that is acceptable.
    function _closeAndRefund(uint256 tradeId, TradeStatus newStatus) internal {
        P2PTradeEscrowStorage storage $ = _getStorage();
        Trade storage t = $.trades[tradeId];

        address initiator = t.initiator;
        address erc20Recipient =
            $.erc20Payer[tradeId] == address(0) ? initiator : $.refundRecipient;

        // --- Effects ---
        t.status = newStatus;

        // --- Interactions ---
        uint256 offLen = t.offered.length;
        for (uint256 i; i < offLen; ) {
            Asset memory asset = t.offered[i];
            address to =
                asset.assetType == AssetType.ERC20 ? erc20Recipient : initiator;
            if (!_tryTransferOut(to, asset)) {
                $.pendingRefunds[tradeId][i] = to;
                emit RefundPending(tradeId, i, to);
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

    /// @dev True when the bundle contains at least one ERC20 item.
    function _hasErc20(Asset[] calldata assets) internal pure returns (bool) {
        for (uint256 i; i < assets.length; ) {
            if (assets[i].assetType == AssetType.ERC20) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev EIP-712 hash of an Asset[]: keccak256 of the concatenated item struct hashes.
    function _hashAssets(
        Asset[] memory assets
    ) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](assets.length);
        for (uint256 i; i < assets.length; ) {
            hashes[i] = keccak256(
                abi.encode(
                    ASSET_TYPEHASH,
                    assets[i].assetType,
                    assets[i].token,
                    assets[i].tokenId,
                    assets[i].amount
                )
            );
            unchecked {
                ++i;
            }
        }
        return keccak256(abi.encodePacked(hashes));
    }

    /// @dev Verifies `signer` signed `structHash` under this contract's EIP-712 domain, that
    ///      now is inside the signed window [validAfter, validBefore] and that window is at
    ///      most MAX_SIGNATURE_TTL long, and that the nonce is unused; then consumes the nonce.
    function _useSignature(
        address signer,
        bytes32 structHash,
        uint256 nonce,
        uint256 validBefore,
        uint256 validAfter,
        bytes calldata sig
    ) internal {
        if (block.timestamp < validAfter)
            revert P2PTradeEscrow__SignatureNotYetValid();
        if (block.timestamp > validBefore)
            revert P2PTradeEscrow__SignatureExpired();
        // validAfter <= now <= validBefore here, so the subtraction cannot underflow.
        if (validBefore - validAfter > MAX_SIGNATURE_TTL)
            revert P2PTradeEscrow__SignatureTtlTooLong();
        P2PTradeEscrowStorage storage $ = _getStorage();
        if ($.usedNonces[signer][nonce]) revert P2PTradeEscrow__NonceUsed();
        if (!_isValidSignature(signer, _hashTypedDataV4(structHash), sig))
            revert P2PTradeEscrow__InvalidSignature();
        $.usedNonces[signer][nonce] = true;
    }

    /// @dev ECDSA first, then ERC-1271. OZ SignatureChecker.isValidSignatureNow goes straight
    ///      to ERC-1271 whenever the signer has code, which rejects a plain ECDSA signature
    ///      from an EIP-7702-delegated EOA (code = 0xef0100 || delegate). Such an EOA's key
    ///      still controls the account, so a signature that recovers to it is accepted.
    function _isValidSignature(
        address signer,
        bytes32 digest,
        bytes calldata sig
    ) internal view returns (bool) {
        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(
            digest,
            sig
        );
        if (err == ECDSA.RecoverError.NoError && recovered == signer)
            return true;
        return
            signer.code.length != 0 &&
            SignatureChecker.isValidERC1271SignatureNow(signer, digest, sig);
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
