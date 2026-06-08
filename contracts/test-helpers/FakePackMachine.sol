// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IPromoCodeRegistry} from "../interfaces/IPromoCodeRegistry.sol";

/// @dev Test helper: an unregistered contract that attempts to call
///      redeemDiscount directly on the PromoCodeRegistry.
///      Used to prove that deploying a contract does not grant pack-machine
///      privileges — only membership in the factory's registeredPackMachines
///      mapping matters.
contract FakePackMachine {
    function attack(
        address registry,
        bytes32 codeId,
        address beneficiary
    ) external returns (uint16 bps) {
        return IPromoCodeRegistry(registry).redeemDiscount(codeId, beneficiary);
    }

    function attackBuyback(
        address registry,
        bytes32 codeId,
        address beneficiary
    ) external returns (uint16 bps) {
        return IPromoCodeRegistry(registry).redeemBuyback(codeId, beneficiary);
    }
}
