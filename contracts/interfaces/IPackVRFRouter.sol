// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IPackVRFRouter {
    /// @notice Request random words for a pack open. Only callable by authorized PackMachine instances.
    /// @param user The address that initiated the pack open.
    /// @param numWords Number of random words required (equal to cardsPerPack).
    /// @return requestId The Chainlink VRF request ID.
    function requestRandomWords(address user, uint8 numWords) external returns (uint256 requestId);
}
