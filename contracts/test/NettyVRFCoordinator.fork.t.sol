// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VRF} from "@chainlink/contracts/src/v0.8/vrf/VRF.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {NettyVRFCoordinator, IVRFConsumerRawFulfill} from "../NettyVRFCoordinator.sol";
import {NettyVRFCoordinatorForkBase, IRouterFork, IMachineFork} from "./NettyVRFCoordinatorForkBase.t.sol";

/// @title NettyVRFCoordinator fork tests
/// @notice Against the DEPLOYED Base staging router and PackMachine (see the base fixture).
///         Audit PoC regressions live in NettyVRFCoordinator.auditRegression.fork.t.sol.
/// @dev VRF_FORK_TESTS=1 BASE_FORK_RPC_URL=https://base.drpc.org \
///        forge test --ffi --match-path 'contracts/test/NettyVRFCoordinator*.t.sol' -vv
contract NettyVRFCoordinatorForkTest is NettyVRFCoordinatorForkBase {
    // =========================================================================
    // Happy path against the deployed router + PackMachine
    // =========================================================================

    function test_openFulfil_deliversCardsThroughDeployedRouter() public {
        (uint256 requestId, uint64 reqBlock) = _open();
        NettyVRFCoordinator.Request memory r = coord.getRequest(requestId);
        assertEq(uint8(r.status), uint8(NettyVRFCoordinator.Status.Pending));
        assertEq(r.router, ROUTER);
        assertEq(r.numWords, pack.cardsPerPack);
        assertEq(r.blockNum, reqBlock);
        assertEq(r.keyHash, coord.currentKeyHash());

        vm.roll(block.number + 1); // N+1
        VRF.Proof memory proof = _prove(VRF_SK, r.preSeed, reqBlock);

        // The router receives exactly the words derived from the prover's VRF output.
        uint256 expected = _output(VRF_SK, r.preSeed, blockhash(reqBlock));
        vm.expectCall(
            ROUTER,
            abi.encodeCall(
                IVRFConsumerRawFulfill.rawFulfillRandomWords,
                (requestId, _expectedWords(expected, r.numWords))
            )
        );
        vm.recordLogs();
        uint256 g = gasleft();
        bool delivered = _fulfil(requestId, proof);
        uint256 gasUsed = g - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        emit log_named_uint("fulfill gas (incl. callback)", gasUsed);

        assertTrue(delivered);
        assertEq(_status(requestId), uint8(NettyVRFCoordinator.Status.Fulfilled));
        (uint256 won, uint256 failed, bool routerFulfilled) = _countOutcome(
            logs,
            requestId
        );
        assertEq(
            won + failed,
            pack.cardsPerPack,
            "every word resolves to CardWon or CardFailed"
        );
        assertGt(won, 0);
        assertTrue(routerFulfilled);
        (bool found, bool success) = _fulfilledLog(logs, requestId);
        assertTrue(found && success);
    }

    function test_twoRequestsSameBlock_bothFulfilNextBlock() public {
        (uint256 a, uint64 blockA) = _open();
        (uint256 b, uint64 blockB) = _open();
        assertEq(blockA, blockB);
        assertTrue(a != b);
        vm.roll(block.number + 1);
        assertTrue(
            _fulfil(b, _prove(VRF_SK, coord.getRequest(b).preSeed, blockB))
        );
        assertTrue(
            _fulfil(a, _prove(VRF_SK, coord.getRequest(a).preSeed, blockA))
        );
    }

    // =========================================================================
    // Duplicates and timing
    // =========================================================================

    function test_duplicateFulfil_isNoop() public {
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        uint256 preSeed = coord.getRequest(requestId).preSeed;
        assertTrue(_fulfil(requestId, _prove(VRF_SK, preSeed, reqBlock)));

        // A second fulfiller's (different-nonce, equally valid) proof is a no-op.
        address second = makeAddr("second fulfiller");
        vm.prank(SAFE);
        coord.setFulfiller(second, true);
        VRF.Proof memory again = _prove(VRF_SK, preSeed, reqBlock);
        vm.recordLogs();
        vm.prank(second);
        assertFalse(coord.fulfill(requestId, again));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_fulfilInRequestBlock_revertsTooEarly() public {
        (uint256 requestId, ) = _open();
        // Proof built with a stand-in hash: the block's own hash is not available yet.
        VRF.Proof memory proof = _proveWithHash(
            VRF_SK,
            coord.getRequest(requestId).preSeed,
            bytes32(uint256(1))
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator.NettyVRFCoordinator__TooEarly.selector,
                requestId
            )
        );
        _fulfil(requestId, proof);
    }

    // =========================================================================
    // Verification window: blockhash() for 256 blocks, EIP-2935 history to 8191
    // =========================================================================

    /// @dev The fork's history contract holds real hashes of the 8191 blocks before
    ///      FORK_BLOCK. Rolling back to R = FORK_BLOCK - 8100 and making the request there
    ///      lets the test age it up to 8191 blocks while its real hash is still served.
    uint256 internal constant HISTORY_REQ_BLOCK = FORK_BLOCK - 8_100;

    function _openInHistoryRange()
        internal
        returns (uint256 requestId, uint64 reqBlock, VRF.Proof memory proof, bytes32 bh)
    {
        vm.roll(HISTORY_REQ_BLOCK);
        (requestId, reqBlock) = _open();
        assertEq(reqBlock, HISTORY_REQ_BLOCK);
        vm.roll(uint256(reqBlock) + 1);
        bh = blockhash(reqBlock); // the real Base block hash, fetched from the fork RPC
        assertTrue(bh != bytes32(0));
        proof = _prove(VRF_SK, coord.getRequest(requestId).preSeed, reqBlock);
    }

    function _historyHash(uint256 n) internal view returns (bool ok, bytes32 h) {
        bytes memory ret;
        (ok, ret) = HISTORY.staticcall(abi.encode(n));
        if (ok && ret.length == 32) h = abi.decode(ret, (bytes32));
    }

    function _assertVerifiesAtAge(uint256 age) internal {
        (uint256 requestId, uint64 reqBlock, VRF.Proof memory proof, bytes32 bh) =
            _openInHistoryRange();
        vm.roll(uint256(reqBlock) + age);
        assertEq(blockhash(reqBlock), bytes32(0), "past the 256-block blockhash() window");
        (bool ok, bytes32 h) = _historyHash(reqBlock);
        assertTrue(ok);
        assertEq(h, bh, "EIP-2935 history returns the real block hash");
        vm.recordLogs();
        assertTrue(_fulfil(requestId, proof), "request still verifies via EIP-2935");
        (uint256 won, uint256 failed, bool routerFulfilled) = _countOutcome(
            vm.getRecordedLogs(),
            requestId
        );
        assertEq(won + failed, pack.cardsPerPack);
        assertTrue(routerFulfilled);
        assertEq(_status(requestId), uint8(NettyVRFCoordinator.Status.Fulfilled));
    }

    function test_history_requestAt257Blocks_verifies() public {
        _assertVerifiesAtAge(257);
    }

    function test_history_request1000BlocksOld_verifies() public {
        _assertVerifiesAtAge(1_000);
    }

    function test_history_request8000BlocksOld_verifies() public {
        _assertVerifiesAtAge(8_000);
    }

    function test_history_requestExactly8191BlocksOld_verifies() public {
        _assertVerifiesAtAge(8_191);
    }

    function test_history_pastWindow_failsCleanly() public {
        (uint256 requestId, uint64 reqBlock, VRF.Proof memory proof, ) =
            _openInHistoryRange();
        vm.roll(uint256(reqBlock) + 8_192);
        (bool ok, ) = _historyHash(reqBlock);
        assertFalse(ok, "history contract refuses blocks past its window");
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__BlockhashUnavailable
                    .selector,
                requestId
            )
        );
        _fulfil(requestId, proof);
        assertEq(_status(requestId), uint8(NettyVRFCoordinator.Status.Pending));
    }

    function test_pastWindow_unprovable_thenRefundPath_prodMachine() public {
        _useProd();
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        VRF.Proof memory proof = _prove(
            VRF_SK,
            coord.getRequest(requestId).preSeed,
            reqBlock
        );
        vm.roll(uint256(reqBlock) + 8_192);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__BlockhashUnavailable
                    .selector,
                requestId
            )
        );
        _fulfil(requestId, proof);

        // On the production machine the user is made whole by the 24 h admin refund.
        vm.warp(block.timestamp + 24 hours + 1);
        uint256 before = IERC20(USDC).balanceOf(user);
        vm.startPrank(SAFE);
        IMachineFork(MACHINE).pause();
        IMachineFork(MACHINE).adminForceRefundPendingOpen(requestId);
        vm.stopPrank();
        assertGt(IERC20(USDC).balanceOf(user), before);
    }

    // =========================================================================
    // Proof binding and tampering
    // =========================================================================

    function test_wrongKey_rejected() public {
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        VRF.Proof memory proof = _prove(
            VRF_SK_2,
            coord.getRequest(requestId).preSeed,
            reqBlock
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator.NettyVRFCoordinator__WrongKey.selector,
                requestId
            )
        );
        _fulfil(requestId, proof);
    }

    function test_wrongPreSeed_rejected() public {
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        VRF.Proof memory proof = _prove(
            VRF_SK,
            coord.getRequest(requestId).preSeed + 1,
            reqBlock
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator.NettyVRFCoordinator__WrongPreSeed.selector,
                requestId
            )
        );
        _fulfil(requestId, proof);
    }

    function test_proofForOtherBlockHash_rejected() public {
        (uint256 requestId, ) = _open();
        vm.roll(block.number + 1);
        VRF.Proof memory proof = _proveWithHash(
            VRF_SK,
            coord.getRequest(requestId).preSeed,
            keccak256("not the hash")
        );
        // Rejected by the verifier (a proof over another seed fails its first seed-dependent check).
        vm.expectRevert();
        _fulfil(requestId, proof);
    }

    /// forge-config: default.fuzz.runs = 24
    function testFuzz_mutatedProof_reverts(uint8 field, uint256 delta) public {
        delta = bound(delta, 1, type(uint128).max);
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        VRF.Proof memory proof = _prove(
            VRF_SK,
            coord.getRequest(requestId).preSeed,
            reqBlock
        );
        field = uint8(bound(field, 0, 8));
        if (field == 0) proof.gamma[0] ^= delta;
        else if (field == 1) proof.gamma[1] ^= delta;
        else if (field == 2) proof.c ^= delta;
        else if (field == 3) proof.s ^= delta;
        else if (field == 4)
            proof.uWitness = address(uint160(proof.uWitness) ^ uint160(delta));
        else if (field == 5) proof.cGammaWitness[0] ^= delta;
        else if (field == 6) proof.sHashWitness[1] ^= delta;
        else if (field == 7) proof.zInv ^= delta;
        else proof.pk[0] ^= delta;
        vm.expectRevert();
        _fulfil(requestId, proof);
        assertEq(_status(requestId), uint8(NettyVRFCoordinator.Status.Pending));
    }

    function test_keyRotation_appliesToNewRequestsOnly() public {
        (uint256 oldReq, uint64 oldBlock) = _open();
        VRF.Proof memory reg2 = _registrationProof(VRF_SK_2, address(coord));
        vm.prank(SAFE);
        coord.registerKey(pk2, reg2);
        (uint256 newReq, uint64 newBlock) = _open();
        vm.roll(block.number + 1);

        // The pending request stays bound to the key in force when it was made.
        assertTrue(
            _fulfil(
                oldReq,
                _prove(VRF_SK, coord.getRequest(oldReq).preSeed, oldBlock)
            )
        );
        VRF.Proof memory stale = _prove(
            VRF_SK,
            coord.getRequest(newReq).preSeed,
            newBlock
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator.NettyVRFCoordinator__WrongKey.selector,
                newReq
            )
        );
        _fulfil(newReq, stale);
        assertTrue(
            _fulfil(
                newReq,
                _prove(VRF_SK_2, coord.getRequest(newReq).preSeed, newBlock)
            )
        );
    }

    // =========================================================================
    // Callback failure is terminal (Chainlink semantics)
    // =========================================================================

    function test_revertedCallback_isTerminalFailed_noRandomnessRevealed() public {
        vm.prank(SAFE);
        IRouterFork(ROUTER).setCallbackGasLimit(40_000); // far too little for PackMachine
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        uint256 preSeed = coord.getRequest(requestId).preSeed;

        vm.recordLogs();
        assertFalse(_fulfil(requestId, _prove(VRF_SK, preSeed, reqBlock)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool found, bool success) = _fulfilledLog(logs, requestId);
        assertTrue(found);
        assertFalse(success);
        // (recordLogs also captures logs of the reverted callback frame, so the router's own
        // RandomnessFulfilled log is not a delivery signal here; no card was drawn.)
        (uint256 won, uint256 failed, ) = _countOutcome(logs, requestId);
        assertEq(won + failed, 0);
        assertEq(_status(requestId), uint8(NettyVRFCoordinator.Status.Failed));

        // With the router fixed, a fresh valid proof is still a no-op: Failed is final.
        vm.prank(SAFE);
        IRouterFork(ROUTER).setCallbackGasLimit(500_000);
        vm.recordLogs();
        assertFalse(_fulfil(requestId, _prove(VRF_SK, preSeed, reqBlock)));
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(_status(requestId), uint8(NettyVRFCoordinator.Status.Failed));
    }

    function test_lateFulfilAfterAdminRefund_isHarmless_prodMachine() public {
        _useProd();
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.startPrank(SAFE);
        IMachineFork(MACHINE).pause();
        IMachineFork(MACHINE).adminForceRefundPendingOpen(requestId);
        vm.stopPrank();

        // PackMachine rejects the unknown request; the router call reverts as a whole, so the
        // coordinator records Failed and nothing else changes.
        assertFalse(
            _fulfil(
                requestId,
                _prove(VRF_SK, coord.getRequest(requestId).preSeed, reqBlock)
            )
        );
        assertEq(_status(requestId), uint8(NettyVRFCoordinator.Status.Failed));
    }

    function test_rollbackToChainlink_failsPendingInHouseRequest() public {
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.prank(SAFE);
        IRouterFork(ROUTER).setVRFCoordinator(CHAINLINK_COORDINATOR);
        vm.roll(block.number + 1);
        // Router now only accepts Chainlink: the callback fails and the request is final.
        assertFalse(
            _fulfil(
                requestId,
                _prove(VRF_SK, coord.getRequest(requestId).preSeed, reqBlock)
            )
        );
        assertEq(_status(requestId), uint8(NettyVRFCoordinator.Status.Failed));
    }

    // =========================================================================
    // Fulfiller allowlist
    // =========================================================================

    function test_fulfil_onlyAllowlistedFulfiller() public {
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        VRF.Proof memory proof = _prove(
            VRF_SK,
            coord.getRequest(requestId).preSeed,
            reqBlock
        );
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__UnauthorizedFulfiller
                    .selector,
                stranger
            )
        );
        coord.fulfill(requestId, proof);
        // Checked before anything else: even an unknown request reveals nothing to a stranger.
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__UnauthorizedFulfiller
                    .selector,
                stranger
            )
        );
        coord.fulfill(12345, proof);

        // Revoked fulfillers are refused; re-allowed ones work.
        vm.expectEmit(address(coord));
        emit NettyVRFCoordinator.FulfillerSet(fulfiller, false);
        vm.prank(SAFE);
        coord.setFulfiller(fulfiller, false);
        assertFalse(coord.isFulfiller(fulfiller));
        vm.prank(fulfiller);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__UnauthorizedFulfiller
                    .selector,
                fulfiller
            )
        );
        coord.fulfill(requestId, proof);
        vm.expectEmit(address(coord));
        emit NettyVRFCoordinator.FulfillerSet(fulfiller, true);
        vm.prank(SAFE);
        coord.setFulfiller(fulfiller, true);
        assertTrue(_fulfil(requestId, proof));
    }

    // =========================================================================
    // Access control, admin validation and the no-setCoordinator guarantee
    // =========================================================================

    function test_onlyAuthorizedRouterMayRequest() public {
        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient
            .RandomWordsRequest({
                keyHash: bytes32(0),
                subId: 0,
                requestConfirmations: 1,
                callbackGasLimit: 500_000,
                numWords: 1,
                extraArgs: ""
            });
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__UnauthorizedRouter
                    .selector,
                address(this)
            )
        );
        coord.requestRandomWords(req);

        vm.prank(SAFE);
        coord.setRouter(ROUTER, false);
        bytes memory sig = _openSignature(user);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__UnauthorizedRouter
                    .selector,
                ROUTER
            )
        );
        IMachineFork(MACHINE).openPack(user, PACK_ID, sig);
    }

    function test_requestBounds() public {
        vm.prank(SAFE);
        coord.setRouter(address(this), true);
        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient
            .RandomWordsRequest({
                keyHash: bytes32(0),
                subId: 0,
                requestConfirmations: 1,
                callbackGasLimit: 500_000,
                numWords: 0,
                extraArgs: ""
            });
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__InvalidNumWords
                    .selector,
                0
            )
        );
        coord.requestRandomWords(req);
        req.numWords = 11;
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__InvalidNumWords
                    .selector,
                11
            )
        );
        coord.requestRandomWords(req);
        req.numWords = 1;
        req.callbackGasLimit = 2_500_001;
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__InvalidCallbackGasLimit
                    .selector,
                2_500_001
            )
        );
        coord.requestRandomWords(req);
        req.callbackGasLimit = 500_000;
        uint256 id1 = coord.requestRandomWords(req);
        uint256 id2 = coord.requestRandomWords(req);
        assertTrue(id1 != 0 && id2 != 0 && id1 != id2);
    }

    function test_adminIsOwnerOnly() public {
        VRF.Proof memory reg2 = _registrationProof(VRF_SK_2, address(coord));
        bytes memory unauthorized = abi.encodeWithSelector(
            Ownable.OwnableUnauthorizedAccount.selector,
            address(this)
        );
        vm.expectRevert(unauthorized);
        coord.registerKey(pk2, reg2);
        vm.expectRevert(unauthorized);
        coord.setRouter(ROUTER, true);
        vm.expectRevert(unauthorized);
        coord.setFulfiller(address(this), true);
    }

    function test_noKeyRegistered_rejectsRequests() public {
        NettyVRFCoordinator fresh = new NettyVRFCoordinator(SAFE);
        vm.prank(SAFE);
        fresh.setRouter(ROUTER, true);
        vm.prank(ROUTER);
        vm.expectRevert(
            NettyVRFCoordinator.NettyVRFCoordinator__NoKeyRegistered.selector
        );
        fresh.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: bytes32(0),
                subId: 0,
                requestConfirmations: 1,
                callbackGasLimit: 500_000,
                numWords: 1,
                extraArgs: ""
            })
        );
    }

    // --- F-04: proof of possession at key registration ---

    function test_registerKey_requiresProofOfPossession() public {
        VRF.Proof memory good = _registrationProof(VRF_SK_2, address(coord));

        // Off-curve key.
        uint256[2] memory bad = [pk1[0], pk1[1] + 1];
        vm.prank(SAFE);
        vm.expectRevert(
            NettyVRFCoordinator.NettyVRFCoordinator__InvalidPublicKey.selector
        );
        coord.registerKey(bad, good);

        // A valid proof by a different key (typo / wrong key file) is rejected.
        vm.prank(SAFE);
        vm.expectRevert(
            NettyVRFCoordinator
                .NettyVRFCoordinator__KeyPossessionNotProven
                .selector
        );
        coord.registerKey(pk1, good);

        // Proof bound to another coordinator or another chain is rejected.
        VRF.Proof memory otherCoord = _registrationProof(VRF_SK_2, address(0xBEEF));
        vm.prank(SAFE);
        vm.expectRevert(
            NettyVRFCoordinator
                .NettyVRFCoordinator__KeyPossessionNotProven
                .selector
        );
        coord.registerKey(pk2, otherCoord);
        VRF.Proof memory otherChain = _registrationProofFor(VRF_SK_2, 84532, address(coord));
        vm.prank(SAFE);
        vm.expectRevert(
            NettyVRFCoordinator
                .NettyVRFCoordinator__KeyPossessionNotProven
                .selector
        );
        coord.registerKey(pk2, otherChain);

        // Right seed claimed, but the proof itself is not over it (seed field swapped in).
        otherCoord.seed = coord.registrationSeed(pk2);
        vm.prank(SAFE);
        vm.expectRevert();
        coord.registerKey(pk2, otherCoord);

        // Any tampered field fails verification.
        VRF.Proof memory tampered = _registrationProof(VRF_SK_2, address(coord));
        tampered.c ^= 1;
        vm.prank(SAFE);
        vm.expectRevert();
        coord.registerKey(pk2, tampered);

        assertEq(coord.currentKeyHash(), keccak256(abi.encode(pk1)), "nothing registered");

        vm.expectEmit(address(coord));
        emit NettyVRFCoordinator.KeyRegistered(keccak256(abi.encode(pk2)), pk2);
        vm.prank(SAFE);
        coord.registerKey(pk2, good);
        assertEq(coord.currentKeyHash(), keccak256(abi.encode(pk2)));
    }

    // --- F-06: admin input validation ---

    function test_setRouter_rejectsCodelessAndZero() public {
        address eoa = makeAddr("not a router");
        vm.startPrank(SAFE);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator.NettyVRFCoordinator__NotAContract.selector,
                eoa
            )
        );
        coord.setRouter(eoa, true);
        vm.expectRevert(
            NettyVRFCoordinator.NettyVRFCoordinator__ZeroAddress.selector
        );
        coord.setRouter(address(0), true);
        // Revoking needs no code (clean-up of anything, including a self-destructed router).
        coord.setRouter(eoa, false);
        assertFalse(coord.isAuthorizedRouter(eoa));
        vm.stopPrank();
    }

    function test_setFulfiller_rejectsZero() public {
        vm.prank(SAFE);
        vm.expectRevert(
            NettyVRFCoordinator.NettyVRFCoordinator__ZeroAddress.selector
        );
        coord.setFulfiller(address(0), true);
    }

    function test_renounceOwnership_disabled() public {
        vm.prank(SAFE);
        vm.expectRevert(
            NettyVRFCoordinator
                .NettyVRFCoordinator__RenounceOwnershipDisabled
                .selector
        );
        coord.renounceOwnership();
        assertEq(coord.owner(), SAFE);
    }

    function test_bytecodeHasNoSetCoordinatorOrRetrySelectors() public view {
        bytes memory code = address(coord).code;
        // setCoordinator(address) 0x8ea98117, setVRFCoordinator(address) 0x44ff81ce.
        assertFalse(
            _containsPush4(code, 0x8ea98117),
            "setCoordinator selector present"
        );
        assertFalse(
            _containsPush4(code, 0x44ff81ce),
            "setVRFCoordinator selector present"
        );
        // The removed redelivery path: retry(uint256,uint32).
        assertFalse(
            _containsPush4(code, bytes4(keccak256("retry(uint256,uint32)"))),
            "retry selector present"
        );
        assertTrue(
            _containsPush4(code, NettyVRFCoordinator.fulfill.selector),
            "sanity: fulfill selector found by the scan"
        );
        assertEq(IRouterFork(ROUTER).vrfCoordinator(), address(coord));
    }
}
