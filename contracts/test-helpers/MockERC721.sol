// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockERC721 is ERC721 {
    uint256 private _nextId = 1;

    constructor() ERC721("Mock AssetNFT", "MNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function batchMint(
        address[] calldata recipients,
        string[] calldata /* uris */
    ) external {
        for (uint256 i; i < recipients.length; ) {
            _mint(recipients[i], _nextId++);
            unchecked {
                ++i;
            }
        }
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }
}
