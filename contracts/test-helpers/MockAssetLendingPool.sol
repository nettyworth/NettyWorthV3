// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAssetLendingPool} from "../interfaces/IAssetLendingPool.sol";

/// @dev Minimal mock for AssetLendingPool.getAppraisal used in PackMachine FMV tests.
contract MockAssetLendingPool {
    mapping(uint256 tokenId => uint256 value) public appraisalValues;

    function setAppraisalValue(uint256 tokenId, uint256 value) external {
        appraisalValues[tokenId] = value;
    }

    function getAppraisal(
        uint256 tokenId
    ) external view returns (IAssetLendingPool.AssetAppraisal memory) {
        return
            IAssetLendingPool.AssetAppraisal({
                value: appraisalValues[tokenId],
                grade: 0,
                category: 0,
                updatedAt: 0
            });
    }
}
