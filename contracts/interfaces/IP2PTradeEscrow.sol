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
    enum TradeStatus {
        Active,
        Accepted,
        Cancelled,
        Expired
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

    // =========================================================================
    // Admin functions
    // =========================================================================

    /// @notice Pause the contract — blocks createTrade and acceptTrade.
    function pause() external;

    /// @notice Unpause the contract.
    function unpause() external;

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Returns the full on-chain record for a trade offer.
    function getTrade(uint256 tradeId) external view returns (Trade memory);

    /// @notice Returns the next trade ID that will be assigned (i.e. the current offer count).
    function nextTradeId() external view returns (uint256);
}
