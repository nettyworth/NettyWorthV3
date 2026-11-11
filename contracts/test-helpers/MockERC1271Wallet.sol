// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

/// @notice Minimal smart-contract wallet for tests: accepts any signature its owner EOA
///         produced (ERC-1271) and lets the owner make arbitrary calls (approvals). Its owner
///         can make it refuse ERC1155 transfers, to model a recipient hook that blocks refunds.
contract MockERC1271Wallet is IERC1271, ERC721Holder, ERC1155Holder {
    address public immutable owner;
    bool public rejectERC1155;

    constructor(address owner_) {
        owner = owner_;
    }

    function setRejectERC1155(bool reject) external {
        require(msg.sender == owner, "not owner");
        rejectERC1155 = reject;
    }

    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes memory data
    ) public override returns (bytes4) {
        require(!rejectERC1155, "rejected");
        return super.onERC1155Received(operator, from, id, value, data);
    }

    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) external view returns (bytes4) {
        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(
            hash,
            signature
        );
        return
            err == ECDSA.RecoverError.NoError && recovered == owner
                ? IERC1271.isValidSignature.selector
                : bytes4(0xffffffff);
    }

    function execute(address to, bytes calldata data) external {
        require(msg.sender == owner, "not owner");
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
