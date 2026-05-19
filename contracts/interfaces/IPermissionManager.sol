// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IPermissionManager {
    /// @notice Returns true if `account` holds `role` in the protocol.
    function hasProtocolRole(
        bytes32 role,
        address account
    ) external view returns (bool);
}
