// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title PackMachineStorageLib
/// @notice Shared ERC-7201 storage struct for PackMachine and its linked libraries.
///         Importing this file gives both the contract and any external library the
///         identical struct layout and the canonical slot accessor.
library PackMachineStorageLib {
    // =========================================================================
    // Structs
    // =========================================================================

    struct PendingOpen {
        address user;
        uint8 cardsCount;
        /// @dev Timestamp of the VRF request. Used by adminForceRefundPendingOpen to enforce
        ///      a minimum staleness age before allowing an admin refund, ensuring Chainlink has
        ///      had sufficient time to fulfill before the request is force-cleared.
        ///      Packed with user (20 bytes) + cardsCount (1 byte) = 21 bytes; uint40 adds 5 bytes
        ///      → 26 bytes total, fits in one 32-byte slot alongside cardsCount.
        uint40 requestTimestamp;
        uint256 packId;
        /// @dev Total USDC (post-discount) held in escrow for this open.
        uint256 escrowedAmount;
        /// @dev Buyback allocation portion of escrowedAmount (routed to BuybackPool on settle).
        uint256 buybackAmount;
        /// @dev Tier weights at the moment the user paid. fulfillRandomness uses these
        ///      instead of reading live registry values so a mid-flight operator change
        ///      cannot alter the distribution of cards the user receives.
        uint32[6] tierWeightsSnapshot;
        /// @dev buybackAllocationBps at the moment the user paid. Ensures the buyback
        ///      routing fraction cannot be changed between payment and settlement.
        uint16 buybackAllocationBpsSnapshot;
    }

    /// @custom:storage-location erc7201:nettyworth.storage.PackMachine
    struct PackMachineStorage {
        address factory;
        address assetNFT;
        bool isFinished;
        // === Shared card pool ===
        uint256 effectivePrizePoolSize;
        mapping(uint256 requestId => PendingOpen) pendingOpens;
        mapping(address user => uint256) openNonces;
        // === Shared Payment ===
        /// @dev BuybackPool contract address (machine-wide; per-pack buybackAllocationBps in registry controls routing).
        address buybackPool;
        // === Authorized Pool Depositors ===
        /// @dev Addresses permitted to call depositFromPool (BuybackPool + AssetLendingPool).
        mapping(address depositor => bool) authorizedDepositors;
        // ── Per-pack eligibility ────────────────────────────────────────────
        /// @dev Eligibility bitmask per token. Bit p set ⇒ token is eligible for packId p.
        ///      Capped at 256 packs (enforced in PackRegistry.addPack).
        ///      Retained as a "dormant mask" after a win so depositFromPool can restore it.
        mapping(uint256 tokenId => uint256 mask) eligibility;
        /// @dev Per-(pack,tier) tokenId pools used for O(1) weighted random draw.
        ///      packTierPools[packId] is a fixed-size array[6] of dynamic arrays of tokenIds.
        mapping(uint256 packId => uint256[][6]) packTierPools;
        /// @dev Index+1 of token in packTierPools[packId][packTokenTier[token][packId]].
        ///      0 means the token is not in that pack's pool.
        ///      Used for O(1) swap-and-pop removal across all eligible packs on a win.
        mapping(uint256 tokenId => mapping(uint256 packId => uint256 indexPlus1)) packPoolIndex;
        /// @dev True while a token is physically held by this machine.
        ///      Set true on deposit, false on win / withdrawCards.
        mapping(uint256 tokenId => bool) inCustody;
        /// @dev Per-pack available counter for reservation (Scheme B).
        ///      = eligible-tokens-in-custody for pack p minus pending reservations.
        ///      Decremented on _requestVRF, restored on CardFailed, decremented further on win.
        mapping(uint256 packId => uint256) availablePerPack;
        // === Escrow ===
        /// @dev Sum of all escrowed payments for pending VRF requests. rescueERC20 must
        ///      never sweep below this floor so user funds are always recoverable.
        uint256 totalEscrowed;
        /// @dev Promo code (if any) used for a pending open, keyed by VRF requestId.
        ///      Written only when a discount code is applied; omitted (default bytes32(0))
        ///      for opens without a code. Cleared alongside pendingOpens in fulfillRandomness.
        mapping(uint256 requestId => bytes32 codeId) pendingCodeIds;
        // ── Appended ──────────────────────────────────────────────────────────
        /// @dev Tracks whether a wallet has already consumed the global first-open discount
        ///      on this machine. Reset on a fully-failed (zero-card) VRF open so the wallet
        ///      is not penalized for a bad randomness outcome.
        mapping(address wallet => bool) hasClaimedFirstOpenDiscount;
        /// @dev Records whether the first-open discount was consumed for a pending VRF request,
        ///      so it can be restored in fulfillRandomness on a full-refund (all-cards-failed).
        ///      Written only when the discount is applied; cleared alongside pendingOpens.
        mapping(uint256 requestId => bool) pendingFirstOpen;
        /// @dev Running count of VRF requests that have been submitted but whose
        ///      fulfillRandomness has not yet completed. Incremented in _requestVRF, decremented
        ///      at the end of every fulfillRandomness invocation. resetEffectivePrizePoolSize
        ///      reverts if this counter is non-zero to prevent double-counting reservations that
        ///      are still in-flight but already subtracted from effectivePrizePoolSize.
        uint256 pendingRequestCount;
        /// @dev Per-(token,pack) tier. Tier is purely a per-pack property.
        ///      Survives a win as a DORMANT map (not deleted on win) so depositFromPool
        ///      restores per-pack tiers automatically. Cleared only on withdrawCards.
        mapping(uint256 tokenId => mapping(uint256 packId => uint8 tier)) packTokenTier;
    }

    // =========================================================================
    // Slot + accessor
    // =========================================================================

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.PackMachine")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant PACK_MACHINE_STORAGE_SLOT =
        0xf65d8338bde3e030621995e09419bd24a6a0ace7a2660416b0681f35fe771000;

    function getStorage()
        internal
        pure
        returns (PackMachineStorage storage $)
    {
        assembly {
            $.slot := PACK_MACHINE_STORAGE_SLOT
        }
    }
}
