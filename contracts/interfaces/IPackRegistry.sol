// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {PackTypes} from "../lib/PackTypes.sol";

/// @title IPackRegistry
/// @notice Interface for the PackRegistry singleton — single source of truth for per-machine
///         pack definitions across all PackMachine clones.
interface IPackRegistry {
    // =========================================================================
    // Bootstrap (factory-only)
    // =========================================================================

    /// @notice Called by the PackMachineFactory immediately after cloning a new PackMachine.
    ///         Registers the machine and creates its pack 0 with the supplied parameters and
    ///         default tier weights.
    /// @dev Only callable by the stored factory address (`onlyFactory`).
    function registerMachine(
        address machine,
        uint128 pricePerPack,
        uint8 cardsPerPack,
        uint40 startTime
    ) external;

    // =========================================================================
    // Pack-config admin (PACK_OPERATOR_ROLE), keyed by (machine, packId)
    // =========================================================================

    /// @notice Add a new pack to a registered machine.
    /// @return packId The index of the new pack.
    function addPack(
        address machine,
        uint128 pricePerPack,
        uint8 cardsPerPack,
        uint40 startTime,
        uint16 buybackAllocationBps,
        uint32[5] calldata tierWeights
    ) external returns (uint256 packId);

    /// @notice Permanently stop a pack. Irreversible.
    function stopPack(address machine, uint256 packId) external;

    /// @notice Pause or unpause a pack (reversible).
    function setPackActive(
        address machine,
        uint256 packId,
        bool active
    ) external;

    /// @notice Update a pack's USDC price.
    function setPackPrice(
        address machine,
        uint256 packId,
        uint128 newPrice
    ) external;

    /// @notice Update a pack's tier weights. Must sum to 10000.
    function setPackTierWeights(
        address machine,
        uint256 packId,
        uint32[5] calldata weights
    ) external;

    /// @notice Update a pack's buyback allocation in basis points (0–10000).
    function setPackBuybackAllocation(
        address machine,
        uint256 packId,
        uint16 bps
    ) external;

    /// @notice Update a pack's open start timestamp.
    function setPackStartTime(
        address machine,
        uint256 packId,
        uint40 startTime
    ) external;

    // =========================================================================
    // Views
    // =========================================================================

    function isRegistered(address machine) external view returns (bool);

    function getPack(
        address machine,
        uint256 packId
    ) external view returns (PackTypes.Pack memory);

    function getPackCount(address machine) external view returns (uint256);

    function getPackPrice(
        address machine,
        uint256 packId
    ) external view returns (uint128);

    function getPackCardsPerPack(
        address machine,
        uint256 packId
    ) external view returns (uint8);

    function getPackTierWeights(
        address machine,
        uint256 packId
    ) external view returns (uint32[5] memory);

    function getPackBuybackAllocationBps(
        address machine,
        uint256 packId
    ) external view returns (uint16);

    function isPackActive(
        address machine,
        uint256 packId
    ) external view returns (bool);

    function isPackFinished(
        address machine,
        uint256 packId
    ) external view returns (bool);

    function factory() external view returns (address);

    // =========================================================================
    // Errors (for client-side decoding)
    // =========================================================================

    error PackRegistry__TooManyPacks();
}
