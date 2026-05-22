// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "../interfaces/ISignatureTransfer.sol";

/// @dev Mock Permit2 for tests. Performs the ERC-20 transfer without verifying signatures.
///      Etch at canonical address 0x000000000022D473030F116dDEE9F6B43aC78BA3 via vm.etch.
contract MockPermit2 {
    function permitTransferFrom(
        ISignatureTransfer.PermitTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata /* signature — not verified in mock */
    ) external {
        IERC20(permit.permitted.token).transferFrom(
            owner,
            transferDetails.to,
            transferDetails.requestedAmount
        );
    }
}
