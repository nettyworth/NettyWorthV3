// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title IP2PTradeEscrow
/// @author NettyWorth
/// @notice Interface for the P2P atomic swap escrow — peer-to-peer trades of any combination
///         of ERC20, ERC721, and ERC1155 assets between a named initiator and counterparty.
interface IP2PTradeEscrow {
    // =========================================================================
    // Enums
    // =========================================================================

    /// @notice The type of asset in a trade bundle item.
    enum AssetType {
        ERC20,
        ERC721,
        ERC1155
    }

    /// @notice Lifecycle state of a trade offer.
    /// @dev Append-only: values are stored on-chain and read by the API by index.
    enum TradeStatus {
        Active,
        Accepted,
        Cancelled,
        Expired,
        Rejected,
        Countered
    }

    // =========================================================================
    // Structs
    // =========================================================================

    /// @notice A single asset item within a trade bundle.
    /// @param assetType  Token standard of the asset.
    /// @param token      Contract address of the token.
    /// @param tokenId    Token ID for ERC721 / ERC1155; ignored for ERC20 (pass 0).
    /// @param amount     Token amount for ERC20 / ERC1155; ignored for ERC721 (pass 0).
    struct Asset {
        AssetType assetType;
        address token;
        uint256 tokenId;
        uint256 amount;
    }

    /// @notice On-chain record of a trade offer.
    /// @param initiator    Address that created the offer and escrowed `offered` assets.
    /// @param counterparty Address designated to accept the offer.
    /// @param deadline     Unix timestamp after which the offer is expired; 0 = never.
    /// @param status       Current lifecycle state.
    /// @param offered      Assets locked in escrow by the initiator.
    /// @param requested    Assets the counterparty must supply to complete the swap.
    struct Trade {
        address initiator;
        address counterparty;
        uint64 deadline;
        TradeStatus status;
        Asset[] offered;
        Asset[] requested;
    }

    /// @notice A trade offer signed by the initiator and submitted by whoever pays its ERC20
    ///         items (createTradeFor), e.g. Coinflow's relayer for a card-funded offer.
    /// @param initiator    Signer; owner of the offered ERC721 / ERC1155 assets.
    /// @param counterparty Address designated to accept the offer.
    /// @param offered      Offered bundle. ERC20 items are paid by the caller.
    /// @param requested    Requested bundle.
    /// @param deadline     Unix timestamp after which the offer is expired; 0 = never.
    /// @param nonce        Initiator's single-use signature nonce.
    /// @param validBefore  Unix timestamp after which the signature can no longer be used.
    /// @param validAfter   Unix timestamp before which the signature cannot be used (the
    ///                     signing time); validBefore - validAfter <= MAX_SIGNATURE_TTL.
    struct CreateTradeParams {
        address initiator;
        address counterparty;
        Asset[] offered;
        Asset[] requested;
        uint64 deadline;
        uint256 nonce;
        uint256 validBefore;
        uint256 validAfter;
    }

    /// @notice A counter-offer signed by the original trade's counterparty and submitted by
    ///         whoever pays its ERC20 items (counterTradeFor).
    /// @param tradeId      The Active trade being countered; the signer must be its counterparty.
    /// @param offered      The counter's offered bundle. ERC20 items are paid by the caller.
    /// @param requested    The counter's requested bundle, asked of the original initiator.
    /// @param deadline     Unix timestamp after which the counter is expired; 0 = never.
    /// @param nonce        Signer's single-use signature nonce.
    /// @param validBefore  Unix timestamp after which the signature can no longer be used.
    /// @param validAfter   Unix timestamp before which the signature cannot be used (the
    ///                     signing time); validBefore - validAfter <= MAX_SIGNATURE_TTL.
    struct CounterTradeParams {
        uint256 tradeId;
        Asset[] offered;
        Asset[] requested;
        uint64 deadline;
        uint256 nonce;
        uint256 validBefore;
        uint256 validAfter;
    }

    // =========================================================================
    // Events (consumed by API)
    // =========================================================================

    /// @notice Emitted when a new trade offer is created and escrow is funded.
    event TradeCreated(
        uint256 indexed tradeId,
        address indexed initiator,
        address indexed counterparty,
        uint64 deadline
    );

    /// @notice Emitted when the designated counterparty accepts and the swap executes.
    event TradeAccepted(uint256 indexed tradeId, address indexed counterparty);

    /// @notice Emitted when the initiator cancels the offer; escrowed assets returned.
    event TradeCancelled(uint256 indexed tradeId, address indexed initiator);

    /// @notice Emitted when anyone expires an offer that has passed its deadline.
    event TradeExpired(uint256 indexed tradeId);

    /// @notice Emitted when the counterparty declines the offer; escrowed assets returned.
    event TradeRejected(uint256 indexed tradeId, address indexed counterparty);

    /// @notice Emitted alongside TradeCreated when someone other than the initiator paid the
    ///         offered ERC20 items (createTradeFor / counterTradeFor). Those items are
    ///         refunded to the refund recipient, never to the initiator.
    event TradeCreatedFor(uint256 indexed tradeId, address indexed payer);

    /// @notice Emitted alongside TradeAccepted when someone other than the counterparty paid
    ///         the requested ERC20 items (acceptTradeFor).
    event TradeAcceptedFor(uint256 indexed tradeId, address indexed payer);

    /// @notice Emitted when the counterparty counters: `originalTradeId` closes as Countered
    ///         and `newTradeId` is the counter-offer, with the roles swapped.
    event TradeCountered(
        uint256 indexed originalTradeId,
        uint256 indexed newTradeId
    );

    /// @notice Emitted alongside TradeCancelled when the refund recipient cancelled an
    ///         externally funded trade (cancelFundedTrade), e.g. after a chargeback.
    event FundedTradeCancelled(uint256 indexed tradeId);

    /// @notice Emitted when the owner changes where externally funded ERC20 refunds go.
    event RefundRecipientSet(address indexed refundRecipient);

    /// @notice Emitted when the owner allows or disallows `token` as `assetType` in new trades.
    event TokenAllowedSet(
        address indexed token,
        AssetType assetType,
        bool allowed
    );

    /// @notice Emitted when returning an escrowed item failed while closing a trade; the item
    ///         stays in escrow for `recipient` and anyone can retry it with claimRefund.
    event RefundPending(
        uint256 indexed tradeId,
        uint256 indexed itemIndex,
        address indexed recipient
    );

    /// @notice Emitted when a pending refund is delivered.
    event RefundClaimed(
        uint256 indexed tradeId,
        uint256 indexed itemIndex,
        address indexed recipient
    );

    /// @notice Emitted when a signer invalidates one of their unused signature nonces.
    event NonceCancelled(address indexed signer, uint256 nonce);

    // =========================================================================
    // Errors
    // =========================================================================

    error P2PTradeEscrow__ZeroAddress();
    error P2PTradeEscrow__InvalidCounterparty();
    error P2PTradeEscrow__EmptyBundle();
    error P2PTradeEscrow__BundleTooLarge();
    error P2PTradeEscrow__InvalidDeadline();
    error P2PTradeEscrow__InvalidAsset();
    error P2PTradeEscrow__TradeNotActive();
    error P2PTradeEscrow__NotCounterparty();
    error P2PTradeEscrow__NotInitiator();
    error P2PTradeEscrow__TradeExpired();
    error P2PTradeEscrow__NotYetExpired();
    error P2PTradeEscrow__NotRefundRecipient();
    error P2PTradeEscrow__NotExternallyFunded();
    error P2PTradeEscrow__RefundRecipientNotSet();
    error P2PTradeEscrow__TokenNotAllowed();
    error P2PTradeEscrow__SignatureTtlTooLong();
    error P2PTradeEscrow__SignatureNotYetValid();
    error P2PTradeEscrow__RenounceDisabled();
    error P2PTradeEscrow__NoPendingRefund();
    error P2PTradeEscrow__RefundFailed();
    error P2PTradeEscrow__InvalidSignature();
    error P2PTradeEscrow__SignatureExpired();
    error P2PTradeEscrow__NonceUsed();

    // =========================================================================
    // Core functions
    // =========================================================================

    /// @notice Create a trade offer: locks `offered` assets in escrow and records the
    ///         requested bundle that the counterparty must supply.
    /// @param counterparty_ Address designated to accept this offer.
    /// @param offered_      Assets the initiator is offering (will be escrowed immediately).
    /// @param requested_    Assets the initiator requests from the counterparty.
    /// @param deadline_     Unix timestamp after which the offer is expired; pass 0 for none.
    /// @return tradeId      Identifier for the new trade offer.
    function createTrade(
        address counterparty_,
        Asset[] calldata offered_,
        Asset[] calldata requested_,
        uint64 deadline_
    ) external returns (uint256 tradeId);

    /// @notice Accept a trade offer: atomically swaps the requested bundle from the
    ///         counterparty to the initiator and releases the escrowed bundle to the
    ///         counterparty. Only callable by the designated counterparty.
    /// @param tradeId  ID of the trade to accept.
    function acceptTrade(uint256 tradeId) external;

    /// @notice Cancel a trade offer and return all escrowed assets to the initiator.
    ///         Only callable by the initiator. No penalty. Works even when paused.
    /// @param tradeId  ID of the trade to cancel.
    function cancelTrade(uint256 tradeId) external;

    /// @notice Mark an expired offer as expired and return escrowed assets to the initiator.
    ///         Callable by anyone after the deadline has passed. Works even when paused.
    /// @param tradeId  ID of the trade to expire.
    function expireTrade(uint256 tradeId) external;

    /// @notice Decline a trade offer and return all escrowed assets. Only callable by the
    ///         counterparty. Works even when paused and after the deadline.
    /// @param tradeId  ID of the trade to decline.
    function rejectTrade(uint256 tradeId) external;

    /// @notice Counter a trade offer: closes it as Countered (escrow back to its initiator) and
    ///         opens the counter-offer with the roles swapped — the caller becomes the new
    ///         initiator and escrows `offered_`. Only callable by the original counterparty,
    ///         before the original's deadline.
    /// @param tradeId      ID of the Active trade to counter.
    /// @param offered_     Assets the caller offers (escrowed immediately).
    /// @param requested_   Assets the caller requests from the original initiator.
    /// @param deadline_    Unix timestamp after which the counter is expired; pass 0 for none.
    /// @return newTradeId  Identifier of the counter-offer.
    function counterTrade(
        uint256 tradeId,
        Asset[] calldata offered_,
        Asset[] calldata requested_,
        uint64 deadline_
    ) external returns (uint256 newTradeId);

    /// @notice Create a trade offer on the initiator's behalf from their EIP-712 signature.
    ///         Offered ERC20 items are paid by the caller (e.g. Coinflow's relayer) and, if the
    ///         trade closes without being accepted, refunded to the refund recipient — never
    ///         to the initiator. ERC721 / ERC1155 items are pulled from the initiator.
    /// @param params   The signed offer.
    /// @param sig      Initiator's signature over `params` (ECDSA or ERC-1271).
    /// @return tradeId Identifier for the new trade offer.
    function createTradeFor(
        CreateTradeParams calldata params,
        bytes calldata sig
    ) external returns (uint256 tradeId);

    /// @notice Counter a trade offer on the counterparty's behalf from their EIP-712 signature
    ///         (see counterTrade). The counter's offered ERC20 items are paid by the caller and
    ///         refunded to the refund recipient if the counter closes without being accepted.
    /// @param params       The signed counter-offer.
    /// @param sig          Original counterparty's signature over `params` (ECDSA or ERC-1271).
    /// @return newTradeId  Identifier of the counter-offer.
    function counterTradeFor(
        CounterTradeParams calldata params,
        bytes calldata sig
    ) external returns (uint256 newTradeId);

    /// @notice Accept a trade offer on the counterparty's behalf from their EIP-712 signature,
    ///         which covers both bundles as they stand on-chain. Requested ERC20 items are paid
    ///         by the caller (e.g. Coinflow's relayer); ERC721 / ERC1155 items are pulled from
    ///         the counterparty.
    /// @param tradeId      ID of the trade to accept.
    /// @param nonce        Counterparty's single-use signature nonce.
    /// @param validBefore  Unix timestamp after which the signature can no longer be used.
    /// @param validAfter   Unix timestamp before which the signature cannot be used (the
    ///                     signing time); validBefore - validAfter <= MAX_SIGNATURE_TTL.
    /// @param sig          Counterparty's signature (ECDSA or ERC-1271).
    function acceptTradeFor(
        uint256 tradeId,
        uint256 nonce,
        uint256 validBefore,
        uint256 validAfter,
        bytes calldata sig
    ) external;

    /// @notice Cancel an externally funded trade (createTradeFor / counterTradeFor), e.g. after
    ///         the card payment behind it is charged back: ERC20 items go to the refund
    ///         recipient, everything else to the initiator. Only callable by the refund
    ///         recipient. Works even when paused.
    /// @param tradeId  ID of the trade to cancel.
    function cancelFundedTrade(uint256 tradeId) external;

    /// @notice Invalidate one of the caller's unused signature nonces.
    /// @param nonce    The nonce to invalidate.
    function cancelNonce(uint256 nonce) external;

    /// @notice Retry delivering an escrowed item whose return failed when its trade closed.
    ///         Callable by anyone; the item always goes to the recipient recorded at close.
    /// @param tradeId    ID of the closed trade.
    /// @param itemIndex  Index of the item in the trade's offered bundle.
    function claimRefund(uint256 tradeId, uint256 itemIndex) external;

    // =========================================================================
    // Admin functions
    // =========================================================================

    /// @notice Pause the contract — blocks createTrade and acceptTrade.
    function pause() external;

    /// @notice Unpause the contract.
    function unpause() external;

    /// @notice Set where offered ERC20 items paid by someone other than the initiator are
    ///         refunded (a NettyWorth wallet; the API turns the refund into store credit).
    function setRefundRecipient(address refundRecipient_) external;

    /// @notice Allow or disallow `token` as `assetType` in new trades. Trades already open are
    ///         unaffected: they can always be accepted or closed.
    function setTokenAllowed(
        address token,
        AssetType assetType,
        bool allowed
    ) external;

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Returns the full on-chain record for a trade offer.
    function getTrade(uint256 tradeId) external view returns (Trade memory);

    /// @notice Returns the next trade ID that will be assigned (i.e. the current offer count).
    function nextTradeId() external view returns (uint256);

    /// @notice The address that paid the offered ERC20 items, when it is not the initiator
    ///         (createTradeFor / counterTradeFor); address(0) otherwise.
    function erc20PayerOf(uint256 tradeId) external view returns (address);

    /// @notice True when `nonce` has been used or cancelled by `signer`.
    function isNonceUsed(address signer, uint256 nonce) external view returns (bool);

    /// @notice Where externally funded offered ERC20 items are refunded.
    function refundRecipient() external view returns (address);

    /// @notice True when `token` may be used as `assetType` in new trades.
    function isTokenAllowed(
        address token,
        AssetType assetType
    ) external view returns (bool);

    /// @notice The recipient a failed refund of item `itemIndex` is held for; address(0) when
    ///         nothing is pending.
    function pendingRefundOf(
        uint256 tradeId,
        uint256 itemIndex
    ) external view returns (address);
}
