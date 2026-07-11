// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {PackMachineStorageLib} from "./PackMachineStorageLib.sol";

/// @title PackPoolLib
/// @notice Deployed library holding all per-(pack,tier) pool management helpers for PackMachine.
///         Deployed as a separate contract (called via DELEGATECALL for `public` functions) so its
///         bytecode does NOT count toward PackMachine's 24 KiB size limit.
/// @dev The library exposes `public` functions so the linker generates a DELEGATECALL dispatch —
///      PackMachine's bytecode only contains a jump stub (~34 bytes) per public library call.
///      All helpers receive a `PackMachineStorageLib.PackMachineStorage storage $` reference
///      from PackMachine (the shared ERC-7201 storage struct at the canonical slot).
library PackPoolLib {
    uint256 private constant NUM_TIERS = 6;

    // =========================================================================
    // Public helpers — DELEGATECALL dispatch (bytecode lives in this contract)
    // =========================================================================

    /// @notice O(1) add of tokenId to packTierPools[packId][tier] and bump availablePerPack.
    function addToPackPool(
        PackMachineStorageLib.PackMachineStorage storage $,
        uint256 tokenId,
        uint256 packId,
        uint256 tier
    ) public {
        $.packTierPools[packId][tier].push(tokenId);
        $.packPoolIndex[tokenId][packId] = $.packTierPools[packId][tier].length; // index+1
        $.availablePerPack[packId]++;
    }

    /// @notice O(1) swap-and-pop removal of tokenId from packTierPools[packId][tier].
    function removeFromPackPool(
        PackMachineStorageLib.PackMachineStorage storage $,
        uint256 tokenId,
        uint256 packId,
        uint256 tier
    ) public {
        uint256 idxPlus1 = $.packPoolIndex[tokenId][packId];
        if (idxPlus1 == 0) return; // already absent
        uint256 idx = idxPlus1 - 1;
        uint256 last = $.packTierPools[packId][tier].length - 1;
        if (idx != last) {
            uint256 moved = $.packTierPools[packId][tier][last];
            $.packTierPools[packId][tier][idx] = moved;
            $.packPoolIndex[moved][packId] = idx + 1;
        }
        $.packTierPools[packId][tier].pop();
        $.packPoolIndex[tokenId][packId] = 0;
    }

    /// @notice Add tokenId to every pack pool indicated by mask, resolving tier per-pack.
    function addToEligiblePacks(
        PackMachineStorageLib.PackMachineStorage storage $,
        uint256 tokenId,
        uint256 mask
    ) public {
        uint256 m = mask;
        while (m != 0) {
            uint256 p = lsb(m);
            if ($.packPoolIndex[tokenId][p] == 0) {
                addToPackPool($, tokenId, p, $.packTokenTier[tokenId][p]);
            }
            m &= m - 1;
        }
    }

    /// @notice Remove tokenId from every pack pool indicated by mask, resolving tier per-pack.
    function removeFromAllPacks(
        PackMachineStorageLib.PackMachineStorage storage $,
        uint256 tokenId,
        uint256 mask
    ) public {
        uint256 m = mask;
        while (m != 0) {
            uint256 p = lsb(m);
            removeFromPackPool($, tokenId, p, $.packTokenTier[tokenId][p]);
            m &= m - 1;
        }
    }

    /// @notice Re-slot a token into packId at a new tier, or add it if not yet eligible.
    function slotTokenInPack(
        PackMachineStorageLib.PackMachineStorage storage $,
        uint256 tokenId,
        uint256 packId,
        uint8 newTier
    ) public {
        uint8 oldTier = $.packTokenTier[tokenId][packId];
        bool alreadyEligible = $.packPoolIndex[tokenId][packId] != 0;
        if (alreadyEligible && oldTier != newTier) {
            removeFromPackPool($, tokenId, packId, oldTier);
            addToPackPool($, tokenId, packId, newTier);
        } else if (!alreadyEligible) {
            addToPackPool($, tokenId, packId, newTier);
        }
        $.packTokenTier[tokenId][packId] = newTier;
    }

    /// @notice Adjust availablePerPack for each pack bit in mask.
    function adjustAvailableForMask(
        PackMachineStorageLib.PackMachineStorage storage $,
        uint256 mask,
        bool increment
    ) public {
        uint256 m = mask;
        while (m != 0) {
            uint256 p = lsb(m);
            if (increment) {
                $.availablePerPack[p]++;
            } else if ($.availablePerPack[p] > 0) {
                $.availablePerPack[p]--;
            }
            m &= m - 1;
        }
    }

    // =========================================================================
    // Pure helpers — kept internal so the optimizer inlines them (no DELEGATECALL
    // overhead on hot-path bit-walking loops).
    // =========================================================================

    /// @notice Return the index (0-based) of the lowest set bit in x. x must be != 0.
    function lsb(uint256 x) internal pure returns (uint256 pos) {
        uint256 bit = x & (~x + 1);
        while (bit > 1) {
            bit >>= 1;
            ++pos;
        }
    }

    /// @notice All-ones mask covering bits [0, packCount).
    function validPackMask(uint256 packCount) internal pure returns (uint256) {
        if (packCount >= 256) return type(uint256).max;
        return (uint256(1) << packCount) - 1;
    }
}
