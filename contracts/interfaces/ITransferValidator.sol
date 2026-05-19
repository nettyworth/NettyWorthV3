// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title ITransferValidator
/// @notice Interface for an external contract that validates NFT transfers.
/// @dev Implementations MUST revert to block a transfer; returning silently means approval.
interface ITransferValidator {
    /// @notice Validates whether a transfer is permitted.
    /// @param caller The address initiating the transfer (msg.sender / operator).
    /// @param from The current token owner.
    /// @param to The intended recipient.
    /// @param tokenId The token being transferred.
    function validateTransfer(
        address caller,
        address from,
        address to,
        uint256 tokenId
    ) external view;
}
