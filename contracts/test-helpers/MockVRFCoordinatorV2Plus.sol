// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/// @dev Minimal mock VRF coordinator for tests. Returns sequential request IDs.
///      Call fulfillRandomWords() to simulate a Chainlink callback.
contract MockVRFCoordinatorV2Plus is IVRFCoordinatorV2Plus {
    uint256 private _nextRequestId = 1;
    mapping(uint256 => address) public requestConsumer;

    function requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest calldata
    ) external override returns (uint256 requestId) {
        requestId = _nextRequestId++;
        requestConsumer[requestId] = msg.sender;
    }

    /// @notice Simulate VRF fulfillment — calls rawFulfillRandomWords on the consumer.
    function fulfillRandomWords(
        address consumer,
        uint256 requestId,
        uint256[] memory randomWords
    ) external {
        (bool ok, ) = consumer.call(
            abi.encodeWithSignature(
                "rawFulfillRandomWords(uint256,uint256[])",
                requestId,
                randomWords
            )
        );
        require(ok, "MockVRFCoordinator: fulfill failed");
    }

    // -------------------------------------------------------------------------
    // IVRFCoordinatorV2Plus / IVRFSubscriptionV2Plus stubs (unused in tests)
    // -------------------------------------------------------------------------

    function getRequestConfig()
        external
        pure
        returns (uint16, uint32, bytes32[] memory)
    {
        bytes32[] memory hashes = new bytes32[](0);
        return (3, 2_500_000, hashes);
    }

    function addConsumer(uint256, address) external override {}
    function removeConsumer(uint256, address) external override {}
    function cancelSubscription(uint256, address) external override {}
    function pendingRequestExists(
        uint256
    ) external pure override returns (bool) {
        return false;
    }
    function createSubscription() external pure override returns (uint256) {
        return 1;
    }

    function getSubscription(
        uint256
    )
        external
        pure
        override
        returns (uint96, uint96, uint64, address, address[] memory)
    {
        address[] memory consumers = new address[](0);
        return (0, 0, 0, address(0), consumers);
    }

    function requestSubscriptionOwnerTransfer(
        uint256,
        address
    ) external override {}
    function acceptSubscriptionOwnerTransfer(uint256) external override {}
    function fundSubscriptionWithNative(uint256) external payable override {}

    function getActiveSubscriptionIds(
        uint256,
        uint256
    ) external pure override returns (uint256[] memory) {
        return new uint256[](0);
    }
}
