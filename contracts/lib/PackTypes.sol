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
        uint32[5] tierWeights;
    }
}
