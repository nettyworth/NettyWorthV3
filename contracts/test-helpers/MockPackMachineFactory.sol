// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @dev Minimal mock of IPackMachineFactory for testing PromoCodeRegistry.
///      Only exposes the isPackMachine() check that the registry uses to authorize
///      redeemDiscount callers.  All other factory methods are intentionally omitted.
contract MockPackMachineFactory {
    mapping(address => bool) private _isPackMachine;

    function setPackMachine(address machine, bool registered) external {
        _isPackMachine[machine] = registered;
    }

    function isPackMachine(address machine) external view returns (bool) {
        return _isPackMachine[machine];
    }
}
