// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VRF} from "@chainlink/contracts/src/v0.8/vrf/VRF.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {NettyVRFCoordinator} from "../NettyVRFCoordinator.sol";
import {PackTypes} from "../lib/PackTypes.sol";

interface IRouterFork {
    function vrfCoordinator() external view returns (address);
    function setVRFCoordinator(address) external;
    function setRequestConfirmations(uint16) external;
    function setCallbackGasLimit(uint32) external;
    function setCoordinator(address) external;
}

interface IMachineFork {
    function openPack(
        address user,
        uint256 packId,
        bytes calldata signature
    ) external;
    function getUserInfo(
        address user
    ) external view returns (uint256 openNonce, bool claimedFirstOpenDiscount);
    function getPackAvailable(uint256 packId) external view returns (uint256);
    function pause() external;
    function paused() external view returns (bool);
    function adminForceRefundPendingOpen(uint256 requestId) external;
}

interface IRegistryFork {
    function getPack(
        address machine,
        uint256 packId
    ) external view returns (PackTypes.Pack memory);
}

interface IPermissionManagerFork {
    function grantRole(bytes32 role, address account) external;
}

/// @title NettyVRFCoordinator fork tests
/// @notice Runs against the DEPLOYED Base staging PackVRFRouter, PackMachine, PackFulfillLib,
///         registry and PermissionManager (no modified copies). Proofs come from the TypeScript
///         prover (scripts/vrf/ecvrf.ts) via FFI, the same code the fulfiller runs.
/// @dev Opt-in (needs an archive-capable Base RPC and FFI):
///        VRF_FORK_TESTS=1 BASE_FORK_RPC_URL=https://base.drpc.org \
///          forge test --ffi --match-path contracts/test/NettyVRFCoordinator.fork.t.sol -vv
///      Skipped otherwise, so `npx hardhat test solidity` is unaffected.
contract NettyVRFCoordinatorForkTest is Test {
    uint256 internal constant FORK_BLOCK = 51_612_545;
    address internal constant SAFE = 0xfe78E8aa8f4B9f616e05a94604aB86A7B192f456;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CHAINLINK_COORDINATOR =
        0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;

    // --- Base mainnet, staging deployment (the switch target) ---
    address internal constant STAGING_PM =
        0x3AED0BcDf2a578688d31ac394d99Fa710b780EC6;
    address internal constant STAGING_ROUTER =
        0xeA3aDEac6b82b9852a140E642BC10135638653E1;
    address internal constant STAGING_MACHINE =
        0x46999a9D321df9e752eCc007f5F67D2981183109;
    address internal constant STAGING_REGISTRY =
        0xb57233fbc2539dbD3285e95Dd28E3E40Ea670552;
    uint256 internal constant STAGING_PACK_ID = 13;

    // --- Base mainnet, production deployment. Used ONLY inside the local fork, for the
    //     refund-path tests: the staging PackMachine implementation (0xe8A1...09FA) predates
    //     adminForceRefundPendingOpen, the production one (0xFBBA...8829) has it. ---
    address internal constant PROD_PM =
        0xC4816911a267B27F4509929Be4Fc4516BDe7eC1D;
    address internal constant PROD_ROUTER =
        0x4aD5C628030546D12754F608081a6256D6c5FDc9;
    address internal constant PROD_MACHINE =
        0x8a021c02Ac5233164D7c44d87a344623A49197c5;
    address internal constant PROD_REGISTRY =
        0xb86217f0Ce896ce5bC2dC7c5B1813683f415092b;
    uint256 internal constant PROD_PACK_ID = 1;

    address internal ROUTER;
    address internal MACHINE;
    uint256 internal PACK_ID;

    bytes32 internal constant PACK_OPERATOR_ROLE = keccak256(
        "PACK_OPERATOR_ROLE"
    );
    bytes32 internal constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 packId,uint256 nonce,bytes32 codeId)"
    );

    // Test-only keys.
    uint256 internal constant VRF_SK =
        0x5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed;
    uint256 internal constant VRF_SK_2 =
        0x7a11ce7a11ce7a11ce7a11ce7a11ce7a11ce7a11ce7a11ce7a11ce7a11ce7a11;
    uint256 internal constant SIGNER_PK = 0xA11CE;

    bytes32 internal constant REQUESTED_SIG = keccak256(
        "RandomWordsRequested(uint256,address,bytes32,uint256,uint64,uint32,uint32)"
    );
    bytes32 internal constant CARD_WON_SIG = keccak256(
        "CardWon(address,uint256,uint256)"
    );
    bytes32 internal constant CARD_FAILED_SIG = keccak256(
        "CardFailed(address,uint256,uint256)"
    );
    bytes32 internal constant ROUTER_FULFILLED_SIG = keccak256(
        "RandomnessFulfilled(uint256,address)"
    );

    NettyVRFCoordinator internal coord;
    address internal signer;
    address internal user;
    uint256[2] internal pk1;
    uint256[2] internal pk2;
    PackTypes.Pack internal pack;

    function setUp() public {
        if (!vm.envOr("VRF_FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envString("BASE_FORK_RPC_URL"), FORK_BLOCK);

        coord = new NettyVRFCoordinator(SAFE);
        pk1 = _publicKey(VRF_SK);
        pk2 = _publicKey(VRF_SK_2);
        signer = vm.addr(SIGNER_PK);
        user = makeAddr("ripper");
        deal(USDC, user, 1_000_000e6);
        vm.prank(SAFE);
        coord.registerKey(pk1);
        _useDeployment(
            STAGING_PM,
            STAGING_ROUTER,
            STAGING_MACHINE,
            STAGING_REGISTRY,
            STAGING_PACK_ID
        );
    }

    /// @dev Performs, inside the fork, exactly the Safe batch the staging switch uses
    ///      (setRouter on the coordinator, then setVRFCoordinator + setRequestConfirmations(1)
    ///      on the router), plus a test-only PACK_OPERATOR signer for open signatures.
    function _useDeployment(
        address pm,
        address router,
        address machine,
        address registry,
        uint256 packId
    ) internal {
        ROUTER = router;
        MACHINE = machine;
        PACK_ID = packId;
        vm.startPrank(SAFE);
        coord.setRouter(router, true);
        IRouterFork(router).setVRFCoordinator(address(coord));
        IRouterFork(router).setRequestConfirmations(1);
        IPermissionManagerFork(pm).grantRole(PACK_OPERATOR_ROLE, signer);
        vm.stopPrank();
        pack = IRegistryFork(registry).getPack(machine, packId);
        vm.prank(user);
        IERC20(USDC).approve(machine, type(uint256).max);
    }

    function _useProd() internal {
        _useDeployment(
            PROD_PM,
            PROD_ROUTER,
            PROD_MACHINE,
            PROD_REGISTRY,
            PROD_PACK_ID
        );
    }

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

        vm.recordLogs();
        uint256 g = gasleft();
        bool delivered = coord.fulfill(requestId, proof);
        uint256 gasUsed = g - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        emit log_named_uint("fulfill gas (incl. callback)", gasUsed);

        assertTrue(delivered);
        assertEq(
            uint8(coord.getRequest(requestId).status),
            uint8(NettyVRFCoordinator.Status.Fulfilled)
        );
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

        // The emitted randomness is the VRF output the prover computed.
        uint256 expected = _output(VRF_SK, r.preSeed, reqBlock);
        assertEq(_fulfilledRandomness(logs, requestId), expected);
    }

    function test_twoRequestsSameBlock_bothFulfilNextBlock() public {
        (uint256 a, uint64 blockA) = _open();
        (uint256 b, uint64 blockB) = _open();
        assertEq(blockA, blockB);
        assertTrue(a != b);
        vm.roll(block.number + 1);
        assertTrue(
            coord.fulfill(
                b,
                _prove(VRF_SK, coord.getRequest(b).preSeed, blockB)
            )
        );
        assertTrue(
            coord.fulfill(
                a,
                _prove(VRF_SK, coord.getRequest(a).preSeed, blockA)
            )
        );
    }

    // =========================================================================
    // Duplicates, timing, the 256-block window
    // =========================================================================

    function test_duplicateFulfil_isNoop() public {
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        uint256 preSeed = coord.getRequest(requestId).preSeed;
        assertTrue(coord.fulfill(requestId, _prove(VRF_SK, preSeed, reqBlock)));

        // A second fulfiller's (different-nonce, equally valid) proof is a no-op.
        VRF.Proof memory second = _prove(VRF_SK, preSeed, reqBlock);
        vm.recordLogs();
        assertFalse(coord.fulfill(requestId, second));
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_fulfilInRequestBlock_revertsTooEarly() public {
        (uint256 requestId, uint64 reqBlock) = _open();
        // Proof built with a stand-in hash: the block's own hash is not available yet.
        VRF.Proof memory proof = _proveWithHash(
            VRF_SK,
            coord.getRequest(requestId).preSeed,
            bytes32(uint256(1))
        );
        reqBlock;
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator.NettyVRFCoordinator__TooEarly.selector,
                requestId
            )
        );
        coord.fulfill(requestId, proof);
    }

    function test_after256Blocks_unprovable_thenRefundPath_prodMachine()
        public
    {
        _useProd();
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        VRF.Proof memory proof = _prove(
            VRF_SK,
            coord.getRequest(requestId).preSeed,
            reqBlock
        );
        vm.roll(uint256(reqBlock) + 257);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__BlockhashUnavailable
                    .selector,
                requestId
            )
        );
        coord.fulfill(requestId, proof);

        // User is made whole by the existing 24 h admin refund (Safe holds admin + pauser).
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
        coord.fulfill(requestId, proof);
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
        coord.fulfill(requestId, proof);
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
        coord.fulfill(requestId, proof);
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
        coord.fulfill(requestId, proof);
        assertEq(
            uint8(coord.getRequest(requestId).status),
            uint8(NettyVRFCoordinator.Status.Pending)
        );
    }

    function test_keyRotation_appliesToNewRequestsOnly() public {
        (uint256 oldReq, uint64 oldBlock) = _open();
        vm.prank(SAFE);
        coord.registerKey(pk2);
        (uint256 newReq, uint64 newBlock) = _open();
        vm.roll(block.number + 1);

        // The pending request stays bound to the key in force when it was made.
        assertTrue(
            coord.fulfill(
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
        coord.fulfill(newReq, stale);
        assertTrue(
            coord.fulfill(
                newReq,
                _prove(VRF_SK_2, coord.getRequest(newReq).preSeed, newBlock)
            )
        );
    }

    // =========================================================================
    // Callback failure and retry
    // =========================================================================

    function test_revertedCallback_isStored_andRetryableWithMoreGas() public {
        vm.prank(SAFE);
        IRouterFork(ROUTER).setCallbackGasLimit(40_000); // far too little for PackMachine
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.roll(block.number + 1);
        uint256 preSeed = coord.getRequest(requestId).preSeed;

        assertFalse(
            coord.fulfill(requestId, _prove(VRF_SK, preSeed, reqBlock))
        );
        assertEq(
            uint8(coord.getRequest(requestId).status),
            uint8(NettyVRFCoordinator.Status.CallbackFailed)
        );

        // Lowering below the recorded limit is refused; same limit fails again (reverts, stays retryable).
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__InvalidCallbackGasLimit
                    .selector,
                39_999
            )
        );
        coord.retry(requestId, 39_999);
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__CallbackReverted
                    .selector,
                requestId
            )
        );
        coord.retry(requestId, 40_000);

        // Works after the 256-block window: no block hash needed.
        vm.roll(uint256(reqBlock) + 1_000);
        vm.recordLogs();
        coord.retry(requestId, 1_500_000);
        (uint256 won, uint256 failed, bool routerFulfilled) = _countOutcome(
            vm.getRecordedLogs(),
            requestId
        );
        assertEq(won + failed, pack.cardsPerPack);
        assertTrue(routerFulfilled);
        assertEq(
            uint8(coord.getRequest(requestId).status),
            uint8(NettyVRFCoordinator.Status.Fulfilled)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator.NettyVRFCoordinator__NotRetryable.selector,
                requestId
            )
        );
        coord.retry(requestId, 1_500_000);
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
        // coordinator records CallbackFailed and nothing else changes.
        assertFalse(
            coord.fulfill(
                requestId,
                _prove(VRF_SK, coord.getRequest(requestId).preSeed, reqBlock)
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                NettyVRFCoordinator
                    .NettyVRFCoordinator__CallbackReverted
                    .selector,
                requestId
            )
        );
        coord.retry(requestId, 500_000);
    }

    function test_rollbackToChainlink_strandsPendingInHouseRequest() public {
        (uint256 requestId, uint64 reqBlock) = _open();
        vm.prank(SAFE);
        IRouterFork(ROUTER).setVRFCoordinator(CHAINLINK_COORDINATOR);
        vm.roll(block.number + 1);
        // Router now only accepts Chainlink: the callback fails, the words are kept.
        assertFalse(
            coord.fulfill(
                requestId,
                _prove(VRF_SK, coord.getRequest(requestId).preSeed, reqBlock)
            )
        );
        assertEq(
            uint8(coord.getRequest(requestId).status),
            uint8(NettyVRFCoordinator.Status.CallbackFailed)
        );
    }

    // =========================================================================
    // Access control and the no-setCoordinator guarantee
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

    function test_adminIsOwnerOnly_andKeysMustBeOnCurve() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        coord.registerKey(pk2);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                address(this)
            )
        );
        coord.setRouter(address(this), true);

        uint256[2] memory bad = [pk1[0], pk1[1] + 1];
        vm.prank(SAFE);
        vm.expectRevert(
            NettyVRFCoordinator.NettyVRFCoordinator__InvalidPublicKey.selector
        );
        coord.registerKey(bad);

        NettyVRFCoordinator fresh = new NettyVRFCoordinator(SAFE);
        vm.prank(SAFE);
        fresh.setRouter(address(this), true);
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
            NettyVRFCoordinator.NettyVRFCoordinator__NoKeyRegistered.selector
        );
        fresh.requestRandomWords(req);
    }

    function test_bytecodeHasNoSetCoordinatorSelectors() public view {
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
        assertEq(IRouterFork(ROUTER).vrfCoordinator(), address(coord));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _open() internal returns (uint256 requestId, uint64 reqBlock) {
        bytes memory sig = _openSignature(user);
        vm.recordLogs();
        vm.prank(user);
        IMachineFork(MACHINE).openPack(user, PACK_ID, sig);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(coord) &&
                logs[i].topics[0] == REQUESTED_SIG
            ) {
                requestId = uint256(logs[i].topics[1]);
                (, reqBlock, , ) = abi.decode(
                    logs[i].data,
                    (uint256, uint64, uint32, uint32)
                );
                return (requestId, reqBlock);
            }
        }
        revert("no RandomWordsRequested");
    }

    function _openSignature(address who) internal view returns (bytes memory) {
        (uint256 nonce, ) = IMachineFork(MACHINE).getUserInfo(who);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                MACHINE
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, who, PACK_ID, nonce, bytes32(0))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            SIGNER_PK,
            keccak256(abi.encodePacked("\x19\x01", domain, structHash))
        );
        return abi.encodePacked(r, s, v);
    }

    function _publicKey(uint256 sk) internal returns (uint256[2] memory pk) {
        Vm.Wallet memory w = vm.createWallet(sk);
        pk = [w.publicKeyX, w.publicKeyY];
    }

    function _prove(
        uint256 sk,
        uint256 preSeed,
        uint64 reqBlock
    ) internal returns (VRF.Proof memory) {
        bytes32 bh = blockhash(reqBlock);
        require(bh != bytes32(0), "request block hash unavailable");
        return _proveWithHash(sk, preSeed, bh);
    }

    function _proveWithHash(
        uint256 sk,
        uint256 preSeed,
        bytes32 bh
    ) internal returns (VRF.Proof memory) {
        return
            abi.decode(vm.ffi(_ffiArgs("prove", sk, preSeed, bh)), (VRF.Proof));
    }

    function _output(
        uint256 sk,
        uint256 preSeed,
        uint64 reqBlock
    ) internal returns (uint256) {
        return
            abi.decode(
                vm.ffi(_ffiArgs("output", sk, preSeed, blockhash(reqBlock))),
                (uint256)
            );
    }

    function _ffiArgs(
        string memory mode,
        uint256 sk,
        uint256 preSeed,
        bytes32 bh
    ) internal pure returns (string[] memory a) {
        a = new string[](7);
        a[0] = "node";
        a[1] = "--experimental-strip-types";
        a[2] = "scripts/vrf/prove-ffi.ts";
        a[3] = mode;
        a[4] = vm.toString(bytes32(sk));
        a[5] = vm.toString(preSeed);
        a[6] = vm.toString(bh);
    }

    function _countOutcome(
        Vm.Log[] memory logs,
        uint256 requestId
    )
        internal
        view
        returns (uint256 won, uint256 failed, bool routerFulfilled)
    {
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            if (
                logs[i].emitter == MACHINE &&
                logs[i].topics.length == 4 &&
                uint256(logs[i].topics[3]) == requestId
            ) {
                if (t0 == CARD_WON_SIG) won++;
                else if (t0 == CARD_FAILED_SIG) failed++;
            }
            if (
                logs[i].emitter == ROUTER &&
                t0 == ROUTER_FULFILLED_SIG &&
                uint256(logs[i].topics[1]) == requestId
            ) {
                routerFulfilled = true;
            }
        }
    }

    function _fulfilledRandomness(
        Vm.Log[] memory logs,
        uint256 requestId
    ) internal view returns (uint256) {
        bytes32 sig = keccak256("RandomWordsFulfilled(uint256,uint256,bool)");
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(coord) &&
                logs[i].topics[0] == sig &&
                uint256(logs[i].topics[1]) == requestId
            ) {
                (uint256 randomness, ) = abi.decode(
                    logs[i].data,
                    (uint256, bool)
                );
                return randomness;
            }
        }
        revert("no RandomWordsFulfilled");
    }

    function _containsPush4(
        bytes memory code,
        bytes4 sel
    ) internal pure returns (bool) {
        for (uint256 i; i + 4 < code.length; ++i) {
            if (
                code[i] == 0x63 &&
                code[i + 1] == sel[0] &&
                code[i + 2] == sel[1] &&
                code[i + 3] == sel[2] &&
                code[i + 4] == sel[3]
            ) return true;
        }
        return false;
    }
}
