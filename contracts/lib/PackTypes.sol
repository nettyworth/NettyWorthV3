// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title PackTypes
/// @notice Shared struct definitions for pack definitions used by PackRegistry and PackMachine.
library PackTypes {
    /// @notice Per-pack definition. Stored in PackRegistry keyed by (machine, packId).
    ///         All packs within a machine share the same card pool held by that machine.
    struct Pack {
        uint128 pricePerPack;
        uint8 cardsPerPack;
        uint40 startTime;
        uint16 buybackAllocationBps;
        /// @dev Reversible: operator can pause/unpause via setPackActive.
        bool active;
        /// @dev Permanent: once finished, opens on this pack revert forever. Set by stopPack.
        bool finished;
        /// @dev Weights in basis points per tier for this pack. Must sum to 10000.
        ///      Index order: 0=Base, 1=Common, 2=Uncommon, 3=Rare, 4=Ultra Rare, 5=Grail.
        uint32[6] tierWeights;
        /// @dev Inclusive lower FMV bound per tier (payment-token units, e.g. USDC 6-dec).
        ///      0 in BOTH min and max means unset — deposits into that tier are rejected.
        uint128[6] tierMinFmv;
        /// @dev Inclusive upper FMV bound per tier. 0 = unset (see tierMinFmv).
        uint128[6] tierMaxFmv;
        /// @dev Minimum eligible card count for this pack. Opens revert when
        ///      availablePerPack < minCards. 0 = no floor (any count allowed).
        uint32 minCards;
        /// @dev Maximum card count required before the pack can be enabled.
        ///      setPackActive(true) reverts when availablePerPack < maxCards. 0 = no gate.
        uint32 maxCards;
    }
}
