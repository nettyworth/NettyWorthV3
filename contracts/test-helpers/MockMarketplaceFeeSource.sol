// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @title MockMarketplaceFeeSource
/// @notice Minimal stand-in for NettyWorthMarketplace in AssetLendingPool tests.
/// @dev AssetLendingPool.financeMarketplacePurchase uses the configured marketplace address for
///      two things: as the EIP-712 `verifyingContract` when recovering the listing signature, and
///      as the source of the FeeController + treasury used to price the collectible fee. The
///      lending-pool test suites do not deploy a full marketplace, so this exposes just those two
///      getters. Its own address is what the tests sign listings against.
contract MockMarketplaceFeeSource {
    address public feeController;
    address public treasury;

    constructor(address feeController_, address treasury_) {
        feeController = feeController_;
        treasury = treasury_;
    }

    function setFeeController(address feeController_) external {
        feeController = feeController_;
    }

    function setTreasury(address treasury_) external {
        treasury = treasury_;
    }
}
