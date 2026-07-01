// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

interface IPackMachineFactory {
    function createPackMachine(
        uint128 pricePerPack,
        uint8 cardsPerPack,
        uint40 startTime
    ) external returns (address packMachine);

    function isPackMachine(address machine) external view returns (bool);

    /// @notice Called by registered PackMachines before an NFT transfer for transfer-validator integration.
    function beforeTransfer(address token) external;

    /// @notice Called by registered PackMachines after an NFT transfer for transfer-validator integration.
    function afterTransfer(address token) external;

    function financeWallet() external view returns (address);
    function paymentToken() external view returns (address);
    function assetNFT() external view returns (address);
    function packVRFRouter() external view returns (address);
    function buybackPool() external view returns (address);
    function promoCodeRegistry() external view returns (address);
    function packRegistry() external view returns (address);
    function getAllPackMachines() external view returns (address[] memory);
    function firstOpenDiscountEnabled() external view returns (bool);
    function firstOpenDiscountBps() external view returns (uint16);
}
