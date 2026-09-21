// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vm, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NettyVRFCoordinator} from "../NettyVRFCoordinator.sol";
import {PackTypes} from "../lib/PackTypes.sol";
import {
    NettyVRFCoordinatorForkBase,
    IRouterFork,
    IMachineFork
} from "./NettyVRFCoordinatorForkBase.t.sol";

interface IBuybackPoolFreeze {
    function buyback(uint256 tokenId) external;
    function buyback(uint256 tokenId, bytes32 codeId) external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
}

interface IERC721Freeze {
    function setApprovalForAll(address operator, bool approved) external;
    function approve(address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IMachineFreeze {
    function getPackTierPoolSize(uint256 packId, uint8 tier) external view returns (uint256);
    function setAuthorizedDepositor(address depositor, bool authorized) external;
    function setBuybackPool(address pool) external;
    function depositFromPool(uint256[] calldata tokenIds, uint8[] calldata tiers, address tokensOwner) external;
    function deposit(
        uint256[] calldata tokenIds,
        uint256[] calldata packCounts,
        uint256[] calldata packIds,
        uint8[] calldata tiers,
        address tokensOwner
    ) external;
    function withdrawCards(uint256[] calldata tokenIds) external;
    function setPackEligibility(uint256 packId, uint256[] calldata tokenIds, uint8[] calldata tiers, bool eligible) external;
    function stop() external;
    function resetEffectivePrizePoolSize() external;
    function getPackTokenTier(uint256 tokenId, uint256 packId) external view returns (uint8);
    function getPack(uint256 packId) external view returns (PackTypes.Pack memory);
}

interface IRegistryFreeze {
    function setPackTierWeights(address machine, uint256 packId, uint32[6] calldata weights) external;
}

/// @title Audit N-01 (re-audit of 8964acb): the staging manual recovery cannot be steered once
///        the procedure's freeze is in effect.
/// @notice Runs against the DEPLOYED staging router, PackMachine (EIP-1167 clone of implementation
///         0xe8a11268434946e6918b068328cd29af10b609fa), registry, BuybackPool and AssetLendingPool
///         on a Base fork. That implementation predates current source: the draw is inlined (no
///         PackFulfillLib), it reads the pack's tier weights live from the registry at delivery,
///         and PendingOpen has no tierWeightsSnapshot (test_N01_deployedLayout...). The freeze is the Safe batch that
///         scripts/vrf/build-recovery-freeze.ts builds at FORK_BLOCK: pause the machine, pause
///         the BuybackPool, de-authorize the AssetLendingPool as a depositor. Pools are read from
///         storage with the same layout scripts/vrf/recovery-freeze.ts uses, and the card is
///         predicted by that module (via scripts/vrf/recovery-predict-ffi.ts).
/// @dev VRF_FORK_TESTS=1 BASE_FORK_RPC_URL=https://base.drpc.org \
///        forge test --ffi --match-path 'contracts/test/NettyVRFCoordinator*.t.sol' -vv
contract NettyVRFCoordinatorRecoveryFreezeForkTest is NettyVRFCoordinatorForkBase {
    address internal constant BUYBACK_POOL = 0x778e60808A37FAABD61446a4ed29C11fF6d64698;
    address internal constant ASSET_NFT = 0x27b125fB73094e53741b850ad779a746a59B089A;
    address internal constant ASSET_LENDING_POOL = 0xf3ffABb652e3DCa54b28A3f273013B72B31f385e;
    uint256 internal constant MACHINE_SLOT = 0xf65d8338bde3e030621995e09419bd24a6a0ace7a2660416b0681f35fe771000;
    bytes4 internal constant ENFORCED_PAUSE = bytes4(keccak256("EnforcedPause()"));

    address internal victim;

    function setUp() public override {
        super.setUp();
        if (address(coord) == address(0)) return;
        victim = makeAddr("victim");
        deal(USDC, victim, 1_000e6);
        vm.prank(victim);
        IERC20(USDC).approve(MACHINE, type(uint256).max);
        vm.prank(victim);
        IERC721Freeze(ASSET_NFT).setApprovalForAll(BUYBACK_POOL, true);
        // Fund the BuybackPool so a buyback can only fail because of the freeze, never for lack
        // of balance (the real pool held ~23 USDC at the audit).
        deal(USDC, BUYBACK_POOL, 1_000e6);
    }

    // =========================================================================
    // Control: the auditor's PoC, unchanged in substance (machine paused only)
    // =========================================================================

    /// @dev Keeps the harness honest: with only the machine paused (the 8964acb runbook), a card
    ///      holder still steers the recovery through buybacks.
    function test_N01_control_machinePauseAloneIsSteerable() public {
        (uint256[] memory owned, uint256 rid) = _victimWithCardsAndStrandedOpen();
        vm.prank(SAFE);
        IMachineFork(MACHINE).pause();
        uint256[] memory words = _announceAndDeriveWords(rid);

        uint256 distinct = _distinctOutcomesUnderBuybacks(rid, words, owned, false);
        assertGt(distinct, 1, "control: machine pause alone lets a card holder steer the recovery");
    }

    // =========================================================================
    // The fix: freeze first, announce after
    // =========================================================================

    function test_N01_recoveryNotSteerableOnceFrozen_andDeliversThePredictedCard() public {
        (uint256[] memory owned, uint256 rid) = _victimWithCardsAndStrandedOpen();

        // Runbook: freeze every mutator, drain (nothing Pending here), THEN announce.
        _freeze();
        uint256[] memory words = _announceAndDeriveWords(rid);
        (uint256 packId, uint8 cardsCount, uint32[6] memory weights) = _pendingOpen(rid);
        uint256[][] memory poolsAtBuild = _pools(packId);
        bytes32 fpAtBuild = keccak256(abi.encode(MACHINE, packId, poolsAtBuild));

        // The tooling's own fingerprint and prediction (recovery-freeze.ts) on these pools.
        (bytes32 fpTs, uint256[] memory predicted, uint256 failed) = _tsPredict(packId, poolsAtBuild, weights, cardsCount, words);
        assertEq(fpTs, fpAtBuild, "TS fingerprint == keccak256(abi.encode(machine, packId, pools))");
        assertEq(failed, 0);
        assertEq(predicted.length, cardsCount);

        // The victim tries every path it has; each is closed, so the outcome never moves.
        uint256 distinct = _distinctOutcomesUnderBuybacks(rid, words, owned, true);
        assertEq(distinct, 1, "once frozen, no card holder can change the recovery outcome");
        assertEq(keccak256(abi.encode(MACHINE, packId, _pools(packId))), fpAtBuild, "pools unchanged");

        // Final signer: re-check (fingerprint, prediction) and execute in the same sitting.
        vm.recordLogs();
        _executeRecovery(rid, words);
        uint256[] memory won = _wonTokens(vm.getRecordedLogs(), rid);
        assertEq(won.length, predicted.length);
        for (uint256 i; i < won.length; ++i) assertEq(won[i], predicted[i], "delivers exactly the predicted card");
        assertEq(IERC721Freeze(ASSET_NFT).ownerOf(won[0]), victim);

        // Unfreeze restores everything the freeze changed.
        _unfreeze();
        assertFalse(IMachineFork(MACHINE).paused());
        assertFalse(IBuybackPoolFreeze(BUYBACK_POOL).paused());
        assertTrue(_isAuthorizedDepositor(ASSET_LENDING_POOL), "AssetLendingPool re-authorized");
        vm.prank(victim);
        IBuybackPoolFreeze(BUYBACK_POOL).buyback(won[0]); // buybacks work again
        assertEq(IERC721Freeze(ASSET_NFT).ownerOf(won[0]), MACHINE);
    }

    /// @dev The tooling's prediction (TS) equals the deployed PackFulfillLib draw, over many words,
    ///      so a fingerprint + prediction match really pins the delivered card.
    function test_N01_tsPredictionMatchesDeployedDraw() public {
        (, uint256 rid) = _victimWithCardsAndStrandedOpen();
        _freeze();
        (uint256 packId, uint8 cardsCount, uint32[6] memory weights) = _pendingOpen(rid);
        uint256[][] memory pools = _pools(packId);
        for (uint256 k; k < 12; ++k) {
            uint256[] memory words = new uint256[](cardsCount);
            for (uint256 i; i < cardsCount; ++i) words[i] = uint256(keccak256(abi.encode("N-01 parity", k, i)));
            (, uint256[] memory predicted, ) = _tsPredict(packId, pools, weights, cardsCount, words);
            uint256 snap = vm.snapshotState();
            vm.recordLogs();
            _executeRecovery(rid, words);
            uint256[] memory won = _wonTokens(vm.getRecordedLogs(), rid);
            vm.revertToState(snap);
            assertEq(won.length, predicted.length);
            for (uint256 i; i < won.length; ++i) assertEq(won[i], predicted[i], "TS prediction == deployed draw");
        }
    }

    /// @dev pendingOpens layout on the deployed implementation, as recovery-freeze.ts reads it,
    ///      and where it differs from current source (no snapshot, no pendingRequestCount).
    function test_N01_deployedLayout_pendingOpenAndMachineFields() public {
        (, uint256 rid) = _victimWithCardsAndStrandedOpen();
        uint256 b = uint256(keccak256(abi.encode(rid, MACHINE_SLOT + 3)));
        uint256 s0 = uint256(vm.load(MACHINE, bytes32(b)));
        assertEq(address(uint160(s0)), victim, "slot 0: user");
        assertEq(uint8(s0 >> 160), pack.cardsPerPack, "slot 0: cardsCount");
        assertEq(s0 >> 168, 0, "slot 0: no requestTimestamp in the deployed struct");
        assertEq(uint256(vm.load(MACHINE, bytes32(b + 1))), PACK_ID, "slot 1: packId");
        uint256 escrowed = uint256(vm.load(MACHINE, bytes32(b + 2)));
        assertEq(escrowed, uint256(pack.pricePerPack) * pack.cardsPerPack, "slot 2: escrowedAmount");
        assertEq(uint256(vm.load(MACHINE, bytes32(b + 3))), (escrowed * pack.buybackAllocationBps) / 10_000, "slot 3: buybackAmount");
        assertEq(uint256(vm.load(MACHINE, bytes32(b + 4))), 0, "slot 4: no tierWeightsSnapshot in the deployed struct");
        // Field 16 is packTokenTier (a mapping root, always 0) in the deployed layout, not a counter.
        assertEq(uint256(vm.load(MACHINE, bytes32(MACHINE_SLOT + 16))), 0, "no pendingRequestCount field");
        assertEq(address(uint160(uint256(vm.load(MACHINE, bytes32(MACHINE_SLOT + 5))))), BUYBACK_POOL, "field 5: buybackPool");
        assertTrue(_isAuthorizedDepositor(ASSET_LENDING_POOL), "field 6: authorizedDepositors[ALP] at FORK_BLOCK");
        assertEq(keccak256(MACHINE.code), keccak256(hex"363d3d373d3d3d363d73e8a11268434946e6918b068328cd29af10b609fa5af43d82803e903d91602b57fd5bf3"), "verified clone");
        assertEq(keccak256(address(0xe8A11268434946E6918b068328CD29AF10B609FA).code), 0x5dd95dd199f88019b84519a9a155d36babb1540fd7d20c8188be0c68f38454a8, "verified implementation");
    }

    /// @dev The deployed draw reads tier weights from the registry at DELIVERY: changing them after
    ///      the announcement changes the card. The registry has no pause, so the tooling records
    ///      the weights and refuses if they differ (recovery-freeze.ts readTierWeights).
    function test_N01_deployedDraw_readsLiveRegistryWeights() public {
        (, uint256 rid) = _victimWithCardsAndStrandedOpen();
        _freeze();
        uint256[] memory words = _announceAndDeriveWords(rid);
        (uint256 packId, uint8 cardsCount, uint32[6] memory weights) = _pendingOpen(rid);
        uint256[][] memory pools = _pools(packId);
        (, uint256[] memory predicted, ) = _tsPredict(packId, pools, weights, cardsCount, words);
        uint8 predictedTier = IMachineFreeze(MACHINE).getPackTokenTier(predicted[0], packId);

        // All weight on a different non-empty tier.
        uint8 other = predictedTier == 0 ? 1 : 0;
        require(pools[other].length > 0, "fixture: other tier empty");
        uint32[6] memory changed;
        changed[other] = 10_000;
        vm.prank(SAFE); // PACK_OPERATOR_ROLE on the staging PermissionManager
        IRegistryFreeze(STAGING_REGISTRY).setPackTierWeights(MACHINE, packId, changed);
        (, , uint32[6] memory live) = _pendingOpen(rid);
        assertEq(live[other], 10_000, "machine resolves the new weights");

        (, uint256[] memory repredicted, ) = _tsPredict(packId, pools, live, cardsCount, words);
        vm.recordLogs();
        _executeRecovery(rid, words);
        uint256[] memory won = _wonTokens(vm.getRecordedLogs(), rid);
        assertEq(won[0], repredicted[0], "delivered card follows the live weights");
        assertTrue(won[0] != predicted[0], "a weight change after the announcement changes the card");
    }

    // =========================================================================
    // Pool-mutator map on the deployed staging machine (runbook table)
    // =========================================================================

    /// @dev Paths a third party can reach are closed by the freeze.
    function test_N01_mutatorMap_thirdPartyPathsClosedByFreeze() public {
        (uint256[] memory owned, uint256 rid) = _victimWithCardsAndStrandedOpen();

        // Before the freeze the AssetLendingPool and the BuybackPool may deposit.
        _assertCallOk(ASSET_LENDING_POOL, MACHINE, _emptyDepositFromPool(ASSET_LENDING_POOL));
        _freeze();
        (uint256 packId, , ) = _pendingOpen(rid);
        bytes32 fp = keccak256(abi.encode(MACHINE, packId, _pools(packId)));

        // openPack (both overloads) and openPackWithPermit2 (both overloads): pause-gated.
        _assertRevertsWith(victim, MACHINE, abi.encodeWithSignature("openPack(address,uint256,bytes)", victim, PACK_ID, ""), ENFORCED_PAUSE);
        _assertRevertsWith(victim, MACHINE, abi.encodeWithSignature("openPack(address,uint256,bytes,bytes32)", victim, PACK_ID, "", bytes32(0)), ENFORCED_PAUSE);
        _assertRevertsWith(
            victim, MACHINE,
            abi.encodeWithSignature("openPackWithPermit2(address,uint256,uint256,uint256,bytes,bytes)", victim, PACK_ID, 0, 0, "", ""),
            ENFORCED_PAUSE
        );
        _assertRevertsWith(
            victim, MACHINE,
            abi.encodeWithSignature("openPackWithPermit2(address,uint256,uint256,uint256,bytes,bytes,bytes32)", victim, PACK_ID, 0, 0, "", "", bytes32(0)),
            ENFORCED_PAUSE
        );
        // BuybackPool.buyback (both overloads) -> depositFromPool: closed by the BuybackPool pause.
        _assertRevertsWith(victim, BUYBACK_POOL, abi.encodeWithSignature("buyback(uint256)", owned[0]), ENFORCED_PAUSE);
        _assertRevertsWith(victim, BUYBACK_POOL, abi.encodeWithSignature("buyback(uint256,bytes32)", owned[0], bytes32(0)), ENFORCED_PAUSE);
        // depositFromPool itself has no pause gate: only the caller check.
        _assertRevertsWith(
            victim, MACHINE, _emptyDepositFromPool(victim),
            bytes4(keccak256("PackMachine__UnauthorizedDepositor(address)"))
        );
        _assertRevertsWith(
            ASSET_LENDING_POOL, MACHINE, _emptyDepositFromPool(ASSET_LENDING_POOL),
            bytes4(keccak256("PackMachine__UnauthorizedDepositor(address)"))
        );
        // The BuybackPool address itself still passes the machine's check: its own pause is the gate.
        _assertCallOk(BUYBACK_POOL, MACHINE, _emptyDepositFromPool(BUYBACK_POOL));
        // fulfillRandomness: router only.
        _assertRevertsWith(
            victim, MACHINE, abi.encodeWithSignature("fulfillRandomness(uint256,uint256[])", rid, new uint256[](1)),
            bytes4(keccak256("PackMachine__OnlyVRFRouter(address)"))
        );
        // The router takes words only from its coordinator; the coordinator never redelivers a Failed request.
        vm.prank(victim);
        (bool ok, ) = ROUTER.call(abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", rid, new uint256[](1)));
        assertFalse(ok, "router: only the coordinator delivers");
        // initialize: already initialized.
        vm.prank(victim);
        (ok, ) = MACHINE.call(abi.encodeWithSignature("initialize(address,address,uint128,uint8,uint40)", victim, victim, 0, 0, 0));
        assertFalse(ok, "initialize is closed");

        assertEq(keccak256(abi.encode(MACHINE, packId, _pools(packId))), fp, "no third-party path changed the pools");
    }

    /// @dev A provable request still Pending at the freeze is fulfilled regardless of the pause
    ///      (fulfillRandomness is not pause-gated) and changes the pools: that is why the runbook
    ///      drains before announcing and the tooling refuses while one is Pending.
    function test_N01_mutatorMap_inFlightFulfilmentChangesPools_henceDrain() public {
        (, uint256 rid) = _victimWithCardsAndStrandedOpen();
        (uint256 other, uint64 otherBlock) = _openAs(user);
        _freeze();
        (uint256 packId, , ) = _pendingOpen(rid);
        bytes32 fp = keccak256(abi.encode(MACHINE, packId, _pools(packId)));
        vm.roll(vm.getBlockNumber() + 1);
        assertTrue(_fulfil(other, _prove(VRF_SK, coord.getRequest(other).preSeed, otherBlock)), "fulfilled while frozen");
        assertTrue(keccak256(abi.encode(MACHINE, packId, _pools(packId))) != fp, "an in-flight fulfilment changes the pools");
    }

    /// @dev PACK_OPERATOR_ROLE paths are not stopped by any pause (or need it): procedurally
    ///      locked, and detected by the ORDERED fingerprint, including a change a size check misses.
    function test_N01_mutatorMap_operatorPathsDetectedByOrderedFingerprint() public {
        (, uint256 rid) = _victimWithCardsAndStrandedOpen();
        _freeze();
        (uint256 packId, , ) = _pendingOpen(rid);
        uint256[][] memory before = _pools(packId);
        bytes32 fp = keccak256(abi.encode(MACHINE, packId, before));
        uint8 tier = 1;
        require(before[tier].length > 1, "fixture: tier 1 needs two cards");
        uint256 tok = before[tier][0];

        // withdrawCards (needs the machine paused) then deposit the same card back: same set,
        // same sizes, different ORDER, different draw.
        uint256 snap = vm.snapshotState();
        uint256[] memory ids = new uint256[](1);
        ids[0] = tok;
        vm.prank(SAFE);
        IMachineFreeze(MACHINE).withdrawCards(ids);
        assertTrue(keccak256(abi.encode(MACHINE, packId, _pools(packId))) != fp, "withdrawCards detected");
        vm.prank(SAFE);
        IERC721Freeze(ASSET_NFT).approve(MACHINE, tok);
        uint256[] memory counts = new uint256[](1);
        counts[0] = 1;
        uint256[] memory packs = new uint256[](1);
        packs[0] = packId;
        uint8[] memory tiers = new uint8[](1);
        tiers[0] = tier;
        vm.prank(SAFE);
        IMachineFreeze(MACHINE).deposit(ids, counts, packs, tiers, SAFE);
        uint256[][] memory afterRedeposit = _pools(packId);
        for (uint256 t; t < 6; ++t) assertEq(afterRedeposit[t].length, before[t].length, "sizes identical");
        assertTrue(keccak256(abi.encode(MACHINE, packId, afterRedeposit)) != fp, "order change detected by the ordered fingerprint");
        vm.revertToState(snap);

        // setPackEligibility: not pause-gated.
        snap = vm.snapshotState();
        vm.prank(SAFE);
        IMachineFreeze(MACHINE).setPackEligibility(packId, ids, tiers, false);
        assertTrue(keccak256(abi.encode(MACHINE, packId, _pools(packId))) != fp, "setPackEligibility detected");
        vm.revertToState(snap);

        // setAuthorizedDepositor re-opens depositFromPool: the tooling sees the event and the flag.
        snap = vm.snapshotState();
        vm.expectEmit(true, false, false, true, MACHINE);
        emit AuthorizedDepositorUpdated(ASSET_LENDING_POOL, true);
        vm.prank(SAFE);
        IMachineFreeze(MACHINE).setAuthorizedDepositor(ASSET_LENDING_POOL, true);
        assertTrue(_isAuthorizedDepositor(ASSET_LENDING_POOL));
        vm.revertToState(snap);

        // resetEffectivePrizePoolSize (counters only; the deployed version has no pending-request
        // guard) and rescueERC20 leave the pools alone; stop() calls _pause() and so cannot run
        // while the machine is frozen.
        snap = vm.snapshotState();
        vm.prank(SAFE);
        IMachineFreeze(MACHINE).resetEffectivePrizePoolSize();
        vm.prank(SAFE);
        IMachineFork(MACHINE).rescueERC20(USDC);
        _assertRevertsWith(SAFE, MACHINE, abi.encodeWithSignature("stop()"), ENFORCED_PAUSE);
        assertEq(keccak256(abi.encode(MACHINE, packId, _pools(packId))), fp, "reset/rescue leave the pools unchanged");
        vm.revertToState(snap);
    }

    event AuthorizedDepositorUpdated(address indexed depositor, bool authorized);

    // =========================================================================
    // Helpers
    // =========================================================================

    function _victimWithCardsAndStrandedOpen() internal returns (uint256[] memory owned, uint256 rid) {
        owned = new uint256[](4);
        for (uint256 i; i < owned.length; ++i) {
            (uint256 r0, uint64 b0) = _openAs(victim);
            vm.roll(vm.getBlockNumber() + 1);
            vm.recordLogs();
            assertTrue(_fulfil(r0, _prove(VRF_SK, coord.getRequest(r0).preSeed, b0)));
            owned[i] = _wonTokens(vm.getRecordedLogs(), r0)[0];
        }
        vm.prank(SAFE);
        IRouterFork(ROUTER).setCallbackGasLimit(40_000); // stand-in trigger for a reverted callback
        uint64 reqBlock;
        (rid, reqBlock) = _openAs(victim);
        vm.roll(vm.getBlockNumber() + 1);
        assertFalse(_fulfil(rid, _prove(VRF_SK, coord.getRequest(rid).preSeed, reqBlock)));
        assertEq(_status(rid), uint8(NettyVRFCoordinator.Status.Failed));
        vm.prank(SAFE);
        IRouterFork(ROUTER).setCallbackGasLimit(500_000);
    }

    /// @dev recovery-freeze.json at FORK_BLOCK (machine and BuybackPool unpaused, ALP authorized).
    function _freeze() internal {
        vm.startPrank(SAFE);
        IMachineFork(MACHINE).pause();
        IBuybackPoolFreeze(BUYBACK_POOL).pause();
        IMachineFreeze(MACHINE).setAuthorizedDepositor(ASSET_LENDING_POOL, false);
        vm.stopPrank();
        assertFalse(_isAuthorizedDepositor(ASSET_LENDING_POOL));
    }

    /// @dev recovery-unfreeze.json: the inverse, depositor first (needs the machine paused).
    function _unfreeze() internal {
        vm.startPrank(SAFE);
        IMachineFreeze(MACHINE).setAuthorizedDepositor(ASSET_LENDING_POOL, true);
        IBuybackPoolFreeze(BUYBACK_POOL).unpause();
        IMachineFork(MACHINE).unpause();
        vm.stopPrank();
    }

    function _announceAndDeriveWords(uint256 rid) internal returns (uint256[] memory words) {
        uint256 announced = vm.getBlockNumber() + 30;
        vm.roll(announced + 1);
        words = new uint256[](pack.cardsPerPack);
        for (uint256 i; i < words.length; ++i) {
            words[i] = uint256(keccak256(abi.encode(blockhash(announced), rid, i)));
        }
    }

    /// @dev Sells each owned card back, one at a time, simulating the recovery before and after
    ///      each attempt (what anyone can eth_call once the words are public). Returns how many
    ///      distinct first cards the recovery could deliver.
    function _distinctOutcomesUnderBuybacks(
        uint256 rid,
        uint256[] memory words,
        uint256[] memory owned,
        bool expectFrozen
    ) internal returns (uint256 distinct) {
        uint256[] memory seen = new uint256[](owned.length + 1);
        for (uint256 step; step <= owned.length; ++step) {
            assertTrue(IMachineFork(MACHINE).paused(), "machine stays paused throughout");
            uint256 card = _simulateRecovery(rid, words);
            console.log("after", step, "buyback attempt(s): the recovery would deliver token", card);
            bool isNew = true;
            for (uint256 k; k < distinct; ++k) if (seen[k] == card) isNew = false;
            if (isNew) seen[distinct++] = card;
            if (step == owned.length) break;
            if (expectFrozen) {
                _assertRevertsWith(victim, BUYBACK_POOL, abi.encodeWithSignature("buyback(uint256)", owned[step]), ENFORCED_PAUSE);
                assertEq(IERC721Freeze(ASSET_NFT).ownerOf(owned[step]), victim, "card not sold");
            } else {
                vm.prank(victim);
                IBuybackPoolFreeze(BUYBACK_POOL).buyback(owned[step]);
                assertEq(IERC721Freeze(ASSET_NFT).ownerOf(owned[step]), MACHINE, "redeposited into the paused machine");
            }
        }
    }

    function _simulateRecovery(uint256 rid, uint256[] memory words) internal returns (uint256 tokenId) {
        uint256 snap = vm.snapshotState();
        vm.recordLogs();
        _executeRecovery(rid, words);
        tokenId = _wonTokens(vm.getRecordedLogs(), rid)[0];
        vm.revertToState(snap);
    }

    /// @dev The three calls of recovery-<id>.json, as the Safe.
    function _executeRecovery(uint256 rid, uint256[] memory words) internal {
        vm.startPrank(SAFE);
        IRouterFork(ROUTER).setVRFCoordinator(SAFE);
        (bool ok, ) = ROUTER.call(abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", rid, words));
        require(ok, "recovery reverted");
        IRouterFork(ROUTER).setVRFCoordinator(address(coord));
        vm.stopPrank();
    }

    function _wonTokens(Vm.Log[] memory logs, uint256 rid) internal view returns (uint256[] memory ids) {
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == MACHINE && logs[i].topics[0] == CARD_WON_SIG && uint256(logs[i].topics[3]) == rid) n++;
        }
        ids = new uint256[](n);
        n = 0;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == MACHINE && logs[i].topics[0] == CARD_WON_SIG && uint256(logs[i].topics[3]) == rid) {
                ids[n++] = uint256(logs[i].topics[2]);
            }
        }
        require(n > 0, "no CardWon");
    }

    /// @dev packTierPools[packId][0..5] read from storage exactly as recovery-freeze.ts readPools does.
    function _pools(uint256 packId) internal view returns (uint256[][] memory pools) {
        uint256 base = uint256(keccak256(abi.encode(packId, MACHINE_SLOT + 8)));
        pools = new uint256[][](6);
        for (uint256 t; t < 6; ++t) {
            uint256 lenSlot = base + t;
            uint256 len = uint256(vm.load(MACHINE, bytes32(lenSlot)));
            assertEq(len, IMachineFreeze(MACHINE).getPackTierPoolSize(packId, uint8(t)), "storage length == getPackTierPoolSize");
            uint256 data = uint256(keccak256(abi.encode(lenSlot)));
            pools[t] = new uint256[](len);
            for (uint256 i; i < len; ++i) {
                uint256 tok = uint256(vm.load(MACHINE, bytes32(data + i)));
                pools[t][i] = tok;
                uint256 idxSlot = uint256(keccak256(abi.encode(packId, keccak256(abi.encode(tok, MACHINE_SLOT + 9)))));
                assertEq(uint256(vm.load(MACHINE, bytes32(idxSlot))), i + 1, "packPoolIndex == position + 1");
                assertEq(IMachineFreeze(MACHINE).getPackTokenTier(tok, packId), t, "tier matches");
            }
        }
    }

    /// @dev pendingOpens[rid] as recovery-freeze.ts readPendingOpen reads it, plus the tier
    ///      weights the deployed machine will use at delivery (its registry's, live).
    function _pendingOpen(uint256 rid) internal view returns (uint256 packId, uint8 cardsCount, uint32[6] memory weights) {
        uint256 b = uint256(keccak256(abi.encode(rid, MACHINE_SLOT + 3)));
        cardsCount = uint8(uint256(vm.load(MACHINE, bytes32(b))) >> 160);
        packId = uint256(vm.load(MACHINE, bytes32(b + 1)));
        weights = IMachineFreeze(MACHINE).getPack(packId).tierWeights;
    }

    function _isAuthorizedDepositor(address d) internal view returns (bool) {
        return uint256(vm.load(MACHINE, keccak256(abi.encode(d, MACHINE_SLOT + 6)))) != 0;
    }

    function _tsPredict(
        uint256 packId,
        uint256[][] memory pools,
        uint32[6] memory weights,
        uint8 cardsCount,
        uint256[] memory words
    ) internal returns (bytes32 fp, uint256[] memory won, uint256 failed) {
        string[] memory a = new string[](4);
        a[0] = "node";
        a[1] = "--experimental-strip-types";
        a[2] = "scripts/vrf/recovery-predict-ffi.ts";
        a[3] = vm.toString(abi.encode(MACHINE, packId, pools, weights, uint256(cardsCount), words));
        (fp, won, failed) = abi.decode(vm.ffi(a), (bytes32, uint256[], uint256));
    }

    function _emptyDepositFromPool(address owner) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("depositFromPool(uint256[],uint8[],address)", new uint256[](0), new uint8[](0), owner);
    }

    function _assertRevertsWith(address from, address to, bytes memory data, bytes4 sel) internal {
        vm.prank(from);
        (bool ok, bytes memory ret) = to.call(data);
        assertFalse(ok, "expected a revert");
        assertGe(ret.length, 4, "revert carries a selector");
        assertEq(bytes4(ret), sel, "revert reason");
    }

    function _assertCallOk(address from, address to, bytes memory data) internal {
        vm.prank(from);
        (bool ok, ) = to.call(data);
        assertTrue(ok, "expected success");
    }
}
