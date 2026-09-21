// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VRF} from "@chainlink/contracts/src/v0.8/vrf/VRF.sol";
import {NettyVRFCoordinator} from "../NettyVRFCoordinator.sol";
import {NettyVRFCoordinatorForkBase, IRouterFork, IMachineFork} from "./NettyVRFCoordinatorForkBase.t.sol";

/// @title Regression tests for the NettyVRFCoordinator audit at 6fef692
/// @notice Each test replays one of the auditor's PoCs (audit/6fef692/poc/AuditPoC.fork.t.sol)
///         step for step against the deployed staging router and PackMachine, and asserts
///         that the exploit no longer works.
/// @dev VRF_FORK_TESTS=1 BASE_FORK_RPC_URL=https://base.drpc.org \
///        forge test --ffi --match-path 'contracts/test/NettyVRFCoordinator*.t.sol' -vv
contract NettyVRFCoordinatorAuditRegressionTest is NettyVRFCoordinatorForkBase {
    address internal victim;
    address internal bystander;
    address internal anyone;

    function setUp() public override {
        super.setUp();
        if (address(coord) == address(0)) return; // skipped (no fork)
        victim = makeAddr("victim");
        bystander = makeAddr("bystander");
        anyone = makeAddr("anyone");
        address[2] memory us = [victim, bystander];
        for (uint256 i; i < 2; ++i) {
            deal(USDC, us[i], 1_000e6);
            vm.prank(us[i]);
            IERC20(USDC).approve(MACHINE, type(uint256).max);
        }
    }

    /// PoC test_F01_retryTimingLetsAnyoneChooseTheCard. The attack needed (1) the randomness
    /// of a CallbackFailed request to be public and (2) a permissionless `retry` that delivers
    /// the stored words at a time of the caller's choosing. Now: the callback failure is
    /// terminal, nothing about the randomness is emitted or stored, and there is no
    /// redelivery entry point for anyone, including the allowlisted fulfiller.
    function test_F01_failedCallbackCannotBeRedeliveredAtAChosenTime() public {
        vm.prank(SAFE);
        IRouterFork(ROUTER).setCallbackGasLimit(40_000); // same stand-in trigger as the PoC
        (uint256 rid, uint64 reqBlock) = _openAs(victim);
        vm.roll(vm.getBlockNumber() + 1);
        VRF.Proof memory proof = _prove(VRF_SK, coord.getRequest(rid).preSeed, reqBlock);

        vm.recordLogs();
        assertFalse(_fulfil(rid, proof));
        (bool found, bool success) = _fulfilledLog(vm.getRecordedLogs(), rid); // asserts no randomness in the log
        assertTrue(found);
        assertFalse(success);
        assertEq(_status(rid), uint8(NettyVRFCoordinator.Status.Failed));
        vm.prank(SAFE);
        IRouterFork(ROUTER).setCallbackGasLimit(500_000); // operator fixes the config

        // The PoC's redelivery call no longer exists.
        vm.prank(anyone);
        (bool ok, ) = address(coord).call(
            abi.encodeWithSignature("retry(uint256,uint32)", rid, uint32(500_000))
        );
        assertFalse(ok, "retry entry point is gone");

        // While the pool moves (bystanders' opens are fulfilled normally), no caller at any
        // step can get the victim's request delivered: not a stranger replaying the proof,
        // not the allowlisted fulfiller with the same or a fresh proof.
        for (uint256 step; step < 4; ++step) {
            vm.prank(anyone);
            vm.expectRevert(
                abi.encodeWithSelector(
                    NettyVRFCoordinator
                        .NettyVRFCoordinator__UnauthorizedFulfiller
                        .selector,
                    anyone
                )
            );
            coord.fulfill(rid, proof);

            vm.recordLogs();
            assertFalse(_fulfil(rid, _prove(VRF_SK, coord.getRequest(rid).preSeed, reqBlock)));
            assertEq(vm.getRecordedLogs().length, 0, "no delivery, no event");
            assertEq(_status(rid), uint8(NettyVRFCoordinator.Status.Failed));

            (uint256 b, uint64 bBlock) = _openAs(bystander);
            vm.roll(vm.getBlockNumber() + 1);
            assertTrue(_fulfil(b, _prove(VRF_SK, coord.getRequest(b).preSeed, bBlock)));
        }
    }

    /// PoC test_F01_revertedFulfilLeavesReplayableProof. A fulfil that reverts after inclusion
    /// still publishes its proof in calldata; the PoC had a third party land it 200 blocks
    /// later at a pool state of its choosing. Now only allowlisted fulfillers may submit.
    function test_F01_leakedProofFromRevertedFulfilCannotBeReplayedByAThirdParty() public {
        (uint256 rid, uint64 reqBlock) = _openAs(victim);
        vm.roll(vm.getBlockNumber() + 1);
        VRF.Proof memory proof = _prove(VRF_SK, coord.getRequest(rid).preSeed, reqBlock);

        // The fulfiller underestimates gas: its tx reverts, the proof is now public.
        vm.prank(fulfiller);
        (bool ok, ) = address(coord).call{gas: 300_000}(
            abi.encodeCall(NettyVRFCoordinator.fulfill, (rid, proof))
        );
        assertFalse(ok);
        assertEq(_status(rid), uint8(NettyVRFCoordinator.Status.Pending));

        // 200 blocks later, after the pool has moved, a third party tries to land it.
        (uint256 b, uint64 bBlock) = _openAs(bystander);
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(_fulfil(b, _prove(VRF_SK, coord.getRequest(b).preSeed, bBlock)));
        vm.roll(uint256(reqBlock) + 200);
        vm.prank(anyone);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__UnauthorizedFulfiller
                    .selector,
                anyone
            )
        );
        coord.fulfill(rid, proof);
        assertEq(_status(rid), uint8(NettyVRFCoordinator.Status.Pending));
    }

    /// PoC test_F02_stagingMissedWindowHasNoRefundPath. F-02 is accepted by Ivan (option a:
    /// no new PackMachine clone; alerting plus the manual-recovery runbook). What changed is
    /// the window: the PoC's request 257 blocks old (fulfiller down ~8.5 min) now still
    /// verifies through EIP-2935, so the stranding threshold moves from 256 to 8191 blocks.
    function test_F02_requestPast256BlocksNowStillFulfils() public {
        uint256 userBefore = IERC20(USDC).balanceOf(victim);
        // Request in a block whose real hash the fork's EIP-2935 history contract holds.
        vm.roll(FORK_BLOCK - 8_100);
        (uint256 rid, uint64 reqBlock) = _openAs(victim);
        uint256 paid = userBefore - IERC20(USDC).balanceOf(victim);
        assertGt(paid, 0);

        vm.roll(uint256(reqBlock) + 1);
        VRF.Proof memory proof = _prove(VRF_SK, coord.getRequest(rid).preSeed, reqBlock);
        vm.roll(uint256(reqBlock) + 257); // the PoC's "fulfiller down ~8.5 min"
        vm.recordLogs();
        assertTrue(_fulfil(rid, proof), "still provable at 257 blocks");
        (uint256 won, uint256 failed, bool routerFulfilled) = _countOutcome(vm.getRecordedLogs(), rid);
        assertEq(won + failed, pack.cardsPerPack, "escrow settled: the user gets the card");
        assertTrue(routerFulfilled);
    }

    /// The residual F-02 case, past the 8191-block window, on staging: the coordinator fails
    /// cleanly (BlockhashUnavailable, request stays Pending, no state change) and the staging
    /// machine still has no refund function. Accepted; the runbook covers it.
    function test_F02_pastWindowFailsCleanly_stagingStillHasNoRefund() public {
        (uint256 rid, uint64 reqBlock) = _openAs(victim);
        vm.roll(vm.getBlockNumber() + 1);
        VRF.Proof memory proof = _prove(VRF_SK, coord.getRequest(rid).preSeed, reqBlock);
        vm.roll(uint256(reqBlock) + 8_192);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator.NettyVRFCoordinator__BlockhashUnavailable.selector,
                rid
            )
        );
        _fulfil(rid, proof);
        assertEq(_status(rid), uint8(NettyVRFCoordinator.Status.Pending));

        vm.warp(block.timestamp + 30 days);
        vm.startPrank(SAFE);
        IMachineFork(MACHINE).pause();
        (bool refundOk, ) = MACHINE.call(
            abi.encodeWithSignature("adminForceRefundPendingOpen(uint256)", rid)
        );
        vm.stopPrank();
        assertFalse(refundOk, "accepted (F-02 option a): staging impl has no refund function");
    }

    /// PoC test_F02_onlyRecoveryIsAdminInjectedWords, kept as the executable form of the
    /// staging manual-recovery runbook (docs/pack-rip-latency/RUNBOOK-vrf-staging-manual-recovery.md):
    /// pause, drain, the Safe becomes the router's coordinator, delivers words derived from a
    /// pre-announced future block hash, points the router back, unpauses. Also shows why the
    /// runbook drains first: an in-house request fulfilled mid-recovery would fail terminally.
    function test_F02_runbookRecovery_settlesStrandedStagingRequest() public {
        (uint256 rid, uint64 reqBlock) = _openAs(victim);
        vm.roll(vm.getBlockNumber() + 1);
        VRF.Proof memory proof = _prove(VRF_SK, coord.getRequest(rid).preSeed, reqBlock);
        vm.roll(uint256(reqBlock) + 8_192); // unprovable
        uint256 machineBal = IERC20(USDC).balanceOf(MACHINE);

        // Runbook step: words from a block announced in advance (scripts/vrf/build-recovery-payload.ts
        // derives word i as keccak256(abi.encode(blockhash(announced), requestId, i))).
        uint256 announcedBlock = block.number - 1; // stands in for the announced, now-mined block
        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256(abi.encode(blockhash(announcedBlock), rid, uint256(0))));

        vm.startPrank(SAFE);
        IMachineFork(MACHINE).pause();
        IRouterFork(ROUTER).setVRFCoordinator(SAFE);
        vm.recordLogs();
        (bool ok, ) = ROUTER.call(
            abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", rid, words)
        );
        IRouterFork(ROUTER).setVRFCoordinator(address(coord));
        IMachineFork(MACHINE).unpause();
        vm.stopPrank();
        assertTrue(ok, "Safe-delivered words settle the stranded request");
        assertLt(IERC20(USDC).balanceOf(MACHINE), machineBal, "escrow released");
        (uint256 won, , ) = _countOutcome(vm.getRecordedLogs(), rid);
        assertEq(won, 1);

        // The coordinator's own record stays Pending (unprovable); nothing can deliver twice:
        // a proof is refused (past window) and the router no longer knows the request.
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator.NettyVRFCoordinator__BlockhashUnavailable.selector,
                rid
            )
        );
        _fulfil(rid, proof);
    }
}
