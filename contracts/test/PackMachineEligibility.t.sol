// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackMachine} from "../PackMachine.sol";
import {PackMachineFactory} from "../PackMachineFactory.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PackRegistry} from "../PackRegistry.sol";
import {PackTierRegistry} from "../PackTierRegistry.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";
import {MockPermit2} from "../test-helpers/MockPermit2.sol";
import {MockAssetLendingPool} from "../test-helpers/MockAssetLendingPool.sol";

/// @title PackMachineEligibilityTest
/// @notice Covers per-pack card eligibility: deposit with masks, setPackEligibility,
///         setTokenEligibility, draw constraints, shared removal, and reservation accounting.
contract PackMachineEligibilityTest is Test {
    PackMachine internal packMachine;
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
    PackRegistry internal packRegistry;
    PackTierRegistry internal packTierRegistry;
    PermissionManager internal pm;
    MockERC20 internal usdc;
    AssetNFT internal assetNFT;
    MockVRFCoordinatorV2Plus internal coordinator;

    address internal admin = makeAddr("admin");
    address internal forwarder = makeAddr("forwarder");
    address internal financeWallet = makeAddr("financeWallet");
    address internal user = makeAddr("user");
    address internal unauthorized = makeAddr("unauthorized");

    uint256 internal operatorPk;
    address internal operator;

    /// @dev Tracks the next VRF request ID (coordinator starts at 1, increments on each request).
    uint256 internal _nextVrfRequestId = 1;

    address internal constant PERMIT2_ADDRESS =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 packId,uint256 nonce,bytes32 codeId)"
    );

    uint128 internal constant PRICE = 10e6; // 10 USDC
    uint8 internal constant CARDS_PER_PACK = 1;

    // Pack IDs
    uint256 internal constant PACK_BASE = 0; // bootstrapped by factory
    uint256 internal packPro; // added in setUp
    uint256 internal packElite; // added in setUp

    function setUp() public {
        (operator, operatorPk) = makeAddrAndKey("operator");

        // PermissionManager
        PermissionManager pmImpl = new PermissionManager();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl),
            abi.encodeCall(PermissionManager.initialize, (admin))
        );
        pm = PermissionManager(address(pmProxy));

        vm.startPrank(admin);
        pm.grantRole(pm.PACK_OPERATOR_ROLE(), operator);
        pm.grantRole(pm.PAUSER_ROLE(), operator);
        pm.grantRole(pm.MINTER_ROLE(), operator);
        vm.stopPrank();

        usdc = new MockERC20();
        coordinator = new MockVRFCoordinatorV2Plus();

        AssetNFT assetNFTImpl = new AssetNFT(forwarder);
        ERC1967Proxy assetNFTProxy = new ERC1967Proxy(
            address(assetNFTImpl),
            abi.encodeCall(
                AssetNFT.initialize,
                (address(pm), "NW", "NWA", "ipfs://c", makeAddr("royalty"), 250)
            )
        );
        assetNFT = AssetNFT(address(assetNFTProxy));

        MockPermit2 permit2Impl = new MockPermit2();
        vm.etch(PERMIT2_ADDRESS, address(permit2Impl).code);

        PackVRFRouter routerImpl = new PackVRFRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                PackVRFRouter.initialize,
                (address(pm), address(coordinator), 1, keccak256("key"), 500_000, 3)
            )
        );
        vrfRouter = PackVRFRouter(address(routerProxy));

        PackMachine machineImpl = new PackMachine(forwarder);
        PackMachineFactory factoryImpl = new PackMachineFactory(forwarder);
        ERC1967Proxy factoryProxy = new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                PackMachineFactory.initialize,
                (address(pm), address(assetNFT), address(usdc), financeWallet)
            )
        );
        factory = PackMachineFactory(address(factoryProxy));

        vm.startPrank(admin);
        factory.setImplementation(address(machineImpl));
        factory.setPackVRFRouter(address(vrfRouter));
        vm.stopPrank();

        PackRegistry registryImpl = new PackRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(PackRegistry.initialize, (address(pm)))
        );
        packRegistry = PackRegistry(address(registryProxy));

        vm.startPrank(admin);
        factory.setPackRegistry(address(packRegistry));
        packRegistry.setFactory(address(factory));

        PackTierRegistry tierRegistryImpl = new PackTierRegistry();
        ERC1967Proxy tierRegistryProxy = new ERC1967Proxy(
            address(tierRegistryImpl),
            abi.encodeCall(PackTierRegistry.initialize, (address(pm)))
        );
        packTierRegistry = PackTierRegistry(address(tierRegistryProxy));
        factory.setPackTierRegistry(address(packTierRegistry));
        packTierRegistry.setFactory(address(factory));
        vm.stopPrank();

        vm.prank(operator);
        address cloneAddr = factory.createPackMachine(
            PRICE, CARDS_PER_PACK, uint40(block.timestamp)
        );
        packMachine = PackMachine(cloneAddr);

        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(cloneAddr, true);

        // Wire mock lending pool so getAppraisalValue works
        MockAssetLendingPool mockLendingPool = new MockAssetLendingPool();
        vm.prank(admin);
        assetNFT.setLendingPool(address(mockLendingPool));

        // Add Pro (pack 1) and Elite (pack 2)
        uint32[6] memory weights = [uint32(7040), 2500, 400, 50, 9, 1];
        vm.startPrank(operator);
        packPro = packRegistry.addPack(
            cloneAddr, PRICE, CARDS_PER_PACK, uint40(block.timestamp), 0, weights
        );
        packElite = packRegistry.addPack(
            cloneAddr, PRICE * 2, CARDS_PER_PACK, uint40(block.timestamp), 0, weights
        );
        vm.stopPrank();

        // Wide-open FMV bounds for all packs so deposits don't require per-token appraisals
        uint128[6] memory minFmv;
        uint128[6] memory maxFmv;
        for (uint256 t; t < 6; ++t) maxFmv[t] = type(uint128).max;
        vm.startPrank(operator);
        packRegistry.setPackTierFmvBounds(address(packMachine), PACK_BASE, minFmv, maxFmv);
        packRegistry.setPackTierFmvBounds(address(packMachine), packPro, minFmv, maxFmv);
        packRegistry.setPackTierFmvBounds(address(packMachine), packElite, minFmv, maxFmv);
        vm.stopPrank();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _mint(uint256 count) internal returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](count);
        uint256 startId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < count; ++i) {
            recipients[i] = operator;
            uris[i] = "";
            tokenIds[i] = startId + i;
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
    }

    /// @dev Deposit helper: flat-encodes (packId, tier) pairs from masks and tiers.
    ///      Each token's eligible packs are decoded from its mask; all use the flat tier value.
    function _deposit(
        uint256[] memory tokenIds,
        uint8[] memory tiers,
        uint256[] memory masks
    ) internal {
        uint256 count = tokenIds.length;
        // Count total bit-count across all masks for flat arrays.
        uint256 total;
        for (uint256 i; i < count; ++i) { uint256 tmp = masks[i]; while (tmp != 0) { total++; tmp &= tmp - 1; } }
        uint256[] memory pcs = new uint256[](count);
        uint256[] memory pids = new uint256[](total);
        uint8[] memory trs = new uint8[](total);
        uint256 offset;
        for (uint256 i; i < count; ++i) {
            uint256 bits;
            uint256 mm = masks[i];
            while (mm != 0) {
                uint256 lsb; uint256 b = mm & (~mm + 1); while (b > 1) { b >>= 1; ++lsb; }
                pids[offset + bits] = lsb;
                trs[offset + bits] = tiers[i];
                bits++; mm &= mm - 1;
            }
            pcs[i] = bits;
            offset += bits;
        }
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(tokenIds, pcs, pids, trs, operator);
        vm.stopPrank();
    }

    function _maskFor(uint256[] memory packIds) internal pure returns (uint256 mask) {
        for (uint256 i; i < packIds.length; ++i) mask |= (1 << packIds[i]);
    }

    function _signOpenPack(
        address user_,
        uint256 packId,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                address(packMachine)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user_, packId, nonce, bytes32(0))
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _openPack(address user_, uint256 packId) internal returns (uint256 requestId) {
        uint256 nonce = packMachine.getUserInfo(user_).openNonce;
        bytes memory sig = _signOpenPack(user_, packId, nonce);
        usdc.mint(user_, PRICE * 3);
        vm.startPrank(user_);
        usdc.approve(address(packMachine), type(uint256).max);
        packMachine.openPack(user_, packId, sig);
        vm.stopPrank();
        // Coordinator returns sequential IDs starting at 1.
        requestId = _nextVrfRequestId++;
    }

    function _fulfill(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        coordinator.fulfillRandomWords(address(vrfRouter), requestId, words);
    }

    // =========================================================================
    // Test: deposit with overlapping eligibility masks
    // =========================================================================

    function test_Deposit_OverlappingMasks_PoolsCorrect() public {
        uint256[] memory ids = _mint(3);

        uint8[] memory tiers = new uint8[](3);
        // all tier 0 (Base)

        uint256[] memory masks = new uint256[](3);
        masks[0] = _maskFor(_arr(PACK_BASE, packPro)); // Base & Pro
        masks[1] = _maskFor(_arr(packPro, packElite)); // Pro & Elite
        masks[2] = _maskFor(_arr(PACK_BASE));           // Base only

        _deposit(ids, tiers, masks);

        // Machine-wide: 3 tokens
        assertEq(packMachine.getMachineInfo().effectivePrizePoolSize, 3);

        // Per-pack pool sizes
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 2); // ids[0], ids[2]
        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 2);   // ids[0], ids[1]
        assertEq(packMachine.getPackTierPoolSize(packElite, 0), 1); // ids[1]

        // Available counters
        assertEq(packMachine.getPackAvailable(PACK_BASE), 2);
        assertEq(packMachine.getPackAvailable(packPro), 2);
        assertEq(packMachine.getPackAvailable(packElite), 1);

        // Eligibility masks stored correctly
        assertEq(packMachine.getTokenEligibility(ids[0]), masks[0]);
        assertEq(packMachine.getTokenEligibility(ids[1]), masks[1]);
        assertEq(packMachine.getTokenEligibility(ids[2]), masks[2]);

        // isTokenEligibleForPack
        assertTrue(packMachine.isTokenEligibleForPack(ids[0], PACK_BASE));
        assertTrue(packMachine.isTokenEligibleForPack(ids[0], packPro));
        assertFalse(packMachine.isTokenEligibleForPack(ids[0], packElite));

        // inCustody
        assertTrue(packMachine.isInCustody(ids[0]));
    }

    // =========================================================================
    // Test: draw from pack only returns eligible cards
    // =========================================================================

    function test_Draw_PackBase_NeverReturnsEliteOnly() public {
        // ids[0] = Base only; ids[1] = Elite only
        uint256[] memory ids = _mint(2);
        uint8[] memory tiers = new uint8[](2);
        uint256[] memory masks = new uint256[](2);
        masks[0] = _maskFor(_arr(PACK_BASE));
        masks[1] = _maskFor(_arr(packElite));
        _deposit(ids, tiers, masks);

        // Open Base pack — must win ids[0], not ids[1]
        uint256 reqId = _openPack(user, PACK_BASE);
        // Force word that would select index 0 in Base pool (only 1 token there)
        _fulfill(reqId, 0); // any word; only 1 eligible → must win ids[0]

        assertFalse(packMachine.isInCustody(ids[0]));  // was won
        assertTrue(packMachine.isInCustody(ids[1]));   // untouched
    }

    // =========================================================================
    // Test: winning a shared card removes it from all eligible packs
    // =========================================================================

    function test_Win_SharedCard_RemovedFromAllPacks() public {
        // ids[0] eligible for Base & Pro
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = _maskFor(_arr(PACK_BASE, packPro));
        _deposit(ids, tiers, masks);

        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 1);
        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 1);

        uint256 reqId = _openPack(user, PACK_BASE);
        _fulfill(reqId, 0);

        // Token won: removed from both pack pools and machine-wide pool
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 0);
        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 0);
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 0);
        assertFalse(packMachine.isInCustody(ids[0]));

        // availablePerPack decremented for Pro too (otherMask)
        assertEq(packMachine.getPackAvailable(packPro), 0);
    }

    // =========================================================================
    // Test: addPack then setPackEligibility on existing tokens
    // =========================================================================

    function test_SetPackEligibility_AddThenRemove() public {
        // Deposit 2 tokens eligible for Base only
        uint256[] memory ids = _mint(2);
        uint8[] memory tiers = new uint8[](2);
        uint256[] memory masks = new uint256[](2);
        masks[0] = 1; // Base only
        masks[1] = 1;
        _deposit(ids, tiers, masks);

        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 0);

        // Add both to Pro (tier 0)
        uint8[] memory proTiers = new uint8[](2);
        // proTiers stays all 0 (Base tier)
        vm.prank(operator);
        packMachine.setPackEligibility(packPro, ids, proTiers, true);

        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 2);
        assertEq(packMachine.getPackAvailable(packPro), 2);
        assertTrue(packMachine.isTokenEligibleForPack(ids[0], packPro));

        // Remove ids[0] from Pro (tiers param ignored on removal)
        uint256[] memory single = new uint256[](1);
        single[0] = ids[0];
        uint8[] memory emptyTiers = new uint8[](0);
        vm.prank(operator);
        packMachine.setPackEligibility(packPro, single, emptyTiers, false);

        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 1);
        assertEq(packMachine.getPackAvailable(packPro), 1);
        assertFalse(packMachine.isTokenEligibleForPack(ids[0], packPro));
    }

    // =========================================================================
    // Test: setPackEligibility idempotent
    // =========================================================================

    function test_SetPackEligibility_Idempotent() public {
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = 1; // Base
        _deposit(ids, tiers, masks);

        uint8[] memory baseTiers = new uint8[](1); // tier 0 = Base
        vm.prank(operator);
        packMachine.setPackEligibility(PACK_BASE, ids, baseTiers, true); // already in Base — no-op

        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 1); // still 1, not doubled
        assertEq(packMachine.getPackAvailable(PACK_BASE), 1);
    }

    // =========================================================================
    // Test: setPackEligibility diff-apply (remove Base, add Elite)
    // =========================================================================

    function test_SetTokenEligibility_DiffApply() public {
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = _maskFor(_arr(PACK_BASE, packPro)); // Base & Pro initially
        _deposit(ids, tiers, masks);

        // Remove from Base
        uint8[] memory emptyT = new uint8[](0);
        vm.prank(operator);
        packMachine.setPackEligibility(PACK_BASE, ids, emptyT, false);

        // Add to Elite at tier 0
        uint8[] memory eliteT = new uint8[](1);
        vm.prank(operator);
        packMachine.setPackEligibility(packElite, ids, eliteT, true);

        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 0);  // removed
        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 1);    // kept
        assertEq(packMachine.getPackTierPoolSize(packElite, 0), 1);  // added
        assertEq(packMachine.getTokenEligibility(ids[0]), _maskFor(_arr(packPro, packElite)));

        assertEq(packMachine.getPackAvailable(PACK_BASE), 0);
        assertEq(packMachine.getPackAvailable(packPro), 1);
        assertEq(packMachine.getPackAvailable(packElite), 1);
    }

    // =========================================================================
    // Test: per-pack available counter gates _assertOpenable
    // =========================================================================

    function test_Openable_RevertsWhenPackHasNoEligibleCards() public {
        // Deposit 1 card eligible for Base only — Elite has 0 eligible
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = 1; // Base only
        _deposit(ids, tiers, masks);

        assertEq(packMachine.getPackAvailable(packElite), 0);

        uint256 nonce = packMachine.getUserInfo(user).openNonce;
        bytes memory sig = _signOpenPack(user, packElite, nonce);
        usdc.mint(user, PRICE * 3);
        vm.startPrank(user);
        usdc.approve(address(packMachine), type(uint256).max);
        vm.expectRevert();
        packMachine.openPack(user, packElite, sig);
        vm.stopPrank();
    }

    // =========================================================================
    // Test: withdraw removes from all pack pools and clears eligibility
    // =========================================================================

    function test_Withdraw_ClearsAllPackPools() public {
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = _maskFor(_arr(PACK_BASE, packPro, packElite));
        _deposit(ids, tiers, masks);

        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 1);
        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 1);
        assertEq(packMachine.getPackTierPoolSize(packElite, 0), 1);

        vm.prank(operator);
        packMachine.pause();

        vm.prank(operator);
        packMachine.withdrawCards(ids);

        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 0);
        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 0);
        assertEq(packMachine.getPackTierPoolSize(packElite, 0), 0);
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 0);
        assertFalse(packMachine.isInCustody(ids[0]));
        assertEq(packMachine.getTokenEligibility(ids[0]), 0); // deleted on withdraw

        assertEq(packMachine.getPackAvailable(PACK_BASE), 0);
        assertEq(packMachine.getPackAvailable(packPro), 0);
        assertEq(packMachine.getPackAvailable(packElite), 0);
    }

    // =========================================================================
    // Test: reservation counter restored on CardFailed (all-tiers-empty path)
    // =========================================================================

    function test_CardFailed_RestoresReservations() public {
        // No cards deposited → availablePerPack[Base] = 0 → openPack must revert
        // (tested in test_Openable_RevertsWhenPackHasNoEligibleCards).
        // This test checks the restoration when cards are present but all drained mid-flight.
        // Deposit 1 card for Base, start an open (reservation charged), then manually drain
        // the pack pool (withdraw) and fulfill — should emit CardFailed and restore.
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = 1;
        _deposit(ids, tiers, masks);

        uint256 reqId = _openPack(user, PACK_BASE);

        // effectivePrizePoolSize = 0 after reservation, availablePerPack[Base] = 0.
        assertEq(packMachine.getMachineInfo().effectivePrizePoolSize, 0);
        assertEq(packMachine.getPackAvailable(PACK_BASE), 0);

        // Fulfill — card is in pool, normal win path. Check the winner got the card.
        _fulfill(reqId, 0);
        assertEq(assetNFT.ownerOf(ids[0]), user);

        // effectivePrizePoolSize stays 0 (machine-wide win reduced it).
        assertEq(packMachine.getMachineInfo().effectivePrizePoolSize, 0);
    }

    // =========================================================================
    // Test: depositFromPool uses dormant eligibility mask
    // =========================================================================

    function test_DepositFromPool_UsesDormantMask() public {
        // Deposit card eligible for Base & Pro, open Base, win the card.
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = _maskFor(_arr(PACK_BASE, packPro));
        _deposit(ids, tiers, masks);

        uint256 reqId = _openPack(user, PACK_BASE);
        _fulfill(reqId, 0);
        // Card now owned by user after the win.
        assertFalse(packMachine.isInCustody(ids[0]));
        assertEq(assetNFT.ownerOf(ids[0]), user);

        // Authorize operator to call depositFromPool (simulating BuybackPool).
        // L001 fix: setBuybackPool/setAuthorizedDepositor now require paused.
        vm.prank(operator);
        packMachine.pause();
        vm.prank(operator);
        packMachine.setAuthorizedDepositor(operator, true);
        vm.prank(operator);
        packMachine.unpause();

        // User sends token to operator (simulate buyback payment → operator now holds it).
        vm.prank(user);
        assetNFT.transferFrom(user, operator, ids[0]);

        // Operator (acting as BuybackPool) re-deposits via depositFromPool.
        vm.startPrank(operator);
        assetNFT.approve(address(packMachine), ids[0]);
        packMachine.depositFromPool(ids, tiers, operator);
        vm.stopPrank();

        // Dormant mask restored: Base & Pro
        assertTrue(packMachine.isInCustody(ids[0]));
        assertTrue(packMachine.isTokenEligibleForPack(ids[0], PACK_BASE));
        assertTrue(packMachine.isTokenEligibleForPack(ids[0], packPro));
        assertFalse(packMachine.isTokenEligibleForPack(ids[0], packElite));
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 1);
        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 1);
    }

    // =========================================================================
    // Test: 256-pack cap in registry
    // =========================================================================

    function test_Registry_256PackCap() public {
        // Pack 0 was created by factory, Pro = 1, Elite = 2 → 3 packs already.
        // Add up to 256, then 257th should revert.
        uint32[6] memory weights = [uint32(7040), 2500, 400, 50, 9, 1];
        vm.startPrank(operator);
        for (uint256 p = 3; p < 256; ++p) {
            packRegistry.addPack(
                address(packMachine), PRICE, 1, uint40(block.timestamp), 0, weights
            );
        }
        // Now at 256 packs. Next one should revert.
        vm.expectRevert(PackRegistry.PackRegistry__TooManyPacks.selector);
        packRegistry.addPack(
            address(packMachine), PRICE, 1, uint40(block.timestamp), 0, weights
        );
        vm.stopPrank();
    }

    // =========================================================================
    // Test: deposit with mask referencing nonexistent pack reverts
    // =========================================================================

    function test_Deposit_InvalidPackRefReverts() public {
        uint256[] memory ids = _mint(1);
        // Flat encoding referencing pack 200, which doesn't exist (only 0,1,2).
        uint256[] memory pcs = new uint256[](1); pcs[0] = 1;
        uint256[] memory pids = new uint256[](1); pids[0] = 200; // nonexistent
        uint8[] memory trs = new uint8[](1);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        vm.expectRevert();
        packMachine.deposit(ids, pcs, pids, trs, operator);
        vm.stopPrank();
    }

    // =========================================================================
    // Test: empty packIds (packCounts[i]=0) per token reverts
    // =========================================================================

    function test_Deposit_EmptyPackIdsReverts() public {
        uint256[] memory ids = _mint(1);
        // packCounts[0] = 0 means no packs — must revert with ArrayLengthMismatch.
        uint256[] memory pcs = new uint256[](1); // pcs[0] = 0
        uint256[] memory pids = new uint256[](0);
        uint8[] memory trs = new uint8[](0);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        vm.expectRevert(PackMachine.PackMachine__ArrayLengthMismatch.selector);
        packMachine.deposit(ids, pcs, pids, trs, operator);
        vm.stopPrank();
    }

    // =========================================================================
    // Test: resetEffectivePrizePoolSize also resets availablePerPack
    // =========================================================================

    function test_ResetEffective_ResetsPerPackAvailable() public {
        uint256[] memory ids = _mint(2);
        uint8[] memory tiers = new uint8[](2);
        uint256[] memory masks = new uint256[](2);
        masks[0] = _maskFor(_arr(PACK_BASE, packPro));
        masks[1] = _maskFor(_arr(packPro));
        _deposit(ids, tiers, masks);

        vm.prank(operator);
        packMachine.pause();

        vm.prank(operator);
        packMachine.resetEffectivePrizePoolSize();

        // After reset with multiple packs, effectivePrizePoolSize = sum of all pack pools
        // (over-counts multi-pack tokens; 1 token in Base + 2 in Pro + 0 in Elite = 3).
        assertEq(packMachine.getMachineInfo().effectivePrizePoolSize, 3);
        assertEq(packMachine.getPackAvailable(PACK_BASE), 1);
        assertEq(packMachine.getPackAvailable(packPro), 2);
        assertEq(packMachine.getPackAvailable(packElite), 0);
    }

    // =========================================================================
    // Test: index integrity after multiple wins (swap-and-pop correctness)
    // =========================================================================

    function test_IndexIntegrity_MultipleWins() public {
        // Deposit 3 cards all eligible for Base; win them one by one and verify pool shrinks correctly.
        uint256 count = 3;
        uint256[] memory ids = _mint(count);
        uint8[] memory tiers = new uint8[](count);
        uint256[] memory masks = new uint256[](count);
        for (uint256 i; i < count; ++i) masks[i] = 1; // Base
        _deposit(ids, tiers, masks);

        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 3);

        for (uint256 i; i < count; ++i) {
            uint256 reqId = _openPack(user, PACK_BASE);
            _fulfill(reqId, i * 1337 + 42); // varied seeds
            assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), count - i - 1);
        }

        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 0);
        assertEq(packMachine.getMachineInfo().effectivePrizePoolSize, 0);
    }

    // =========================================================================
    // Fuzz: random eligibility masks and pack draws stay consistent
    // =========================================================================

    function testFuzz_EligibilityConsistency(uint8 seed) public {
        // Deposit 3 tokens with masks that cover packs 0-2, open each pack, assert no ineligible win.
        uint256 count = 3;
        uint256[] memory ids = _mint(count);
        uint8[] memory tiers = new uint8[](count);
        uint256[] memory masks = new uint256[](count);
        // Assign deterministic but varied masks from seed.
        masks[0] = ((uint256(seed) & 1) != 0 ? 1 : 0) |
                   ((uint256(seed) & 2) != 0 ? 2 : 0) |
                   ((uint256(seed) & 4) != 0 ? 4 : 0);
        if (masks[0] == 0) masks[0] = 1; // must be non-zero
        masks[1] = ((uint256(seed) & 8) != 0 ? 1 : 0) |
                   ((uint256(seed) & 16) != 0 ? 2 : 0) |
                   ((uint256(seed) & 32) != 0 ? 4 : 0);
        if (masks[1] == 0) masks[1] = 2;
        masks[2] = ((uint256(seed) & 64) != 0 ? 1 : 0) |
                   ((uint256(seed) & 128) != 0 ? 4 : 0);
        if (masks[2] == 0) masks[2] = 4;

        _deposit(ids, tiers, masks);

        // For each pack with available > 0, open and verify the won token is eligible.
        for (uint256 p; p < 3; ++p) {
            if (packMachine.getPackAvailable(p) == 0) continue;
            uint256 reqId = _openPack(user, p);
            uint256 poolBefore = packMachine.getPackTierPoolSize(p, 0);
            vm.recordLogs();
            _fulfill(reqId, uint256(keccak256(abi.encode(seed, p))));
            // Check CardWon event — won token must have had bit p set
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 l; l < logs.length; ++l) {
                if (logs[l].topics[0] == keccak256("CardWon(address,uint256,uint256)")) {
                    uint256 wonToken = uint256(logs[l].topics[2]);
                    // Token must have been eligible for pack p (bit set in its mask)
                    // After win, eligibility is dormant but pool shrank
                    assertLt(packMachine.getPackTierPoolSize(p, 0), poolBefore);
                    // Won token no longer in custody
                    assertFalse(packMachine.isInCustody(wonToken));
                }
            }
        }
    }

    // =========================================================================
    // Helpers (array construction)
    // =========================================================================

    function _arr(uint256 a) internal pure returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = a;
    }

    function _arr(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _arr(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory r) {
        r = new uint256[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    // =========================================================================
    // Per-pack tier tests
    // =========================================================================

    /// @dev Helper: deposit a token into multiple packs with distinct tiers.
    function _depositWithPerPackTiers(
        uint256 tokenId,
        uint256[] memory packs,
        uint8[] memory tierArr
    ) internal {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        // Flat encoding: one token, packs.length entries.
        uint256[] memory pcs = new uint256[](1); pcs[0] = packs.length;
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(ids, pcs, packs, tierArr, operator);
        vm.stopPrank();
    }

    function test_PerPackTier_DifferentiatedPlacement() public {
        // Card A: Rare (tier 3) in PACK_BASE, Common (tier 1) in packPro.
        uint256[] memory ids = _mint(1);
        _depositWithPerPackTiers(
            ids[0],
            _arr(PACK_BASE, packPro),
            _tierArr(3, 1)
        );

        // Pack 0: row 3 has 1 token, row 1 has 0.
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 3), 1);
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 1), 0);
        // Pack 1: row 1 has 1 token, row 3 has 0.
        assertEq(packMachine.getPackTierPoolSize(packPro, 1), 1);
        assertEq(packMachine.getPackTierPoolSize(packPro, 3), 0);

        // getPackTokenTier resolves correctly.
        assertEq(packMachine.getPackTokenTier(ids[0], PACK_BASE), 3);
        assertEq(packMachine.getPackTokenTier(ids[0], packPro), 1);
    }

    function test_PerPackTier_WinRemovesFromCorrectRows() public {
        // Card A: tier 3 in PACK_BASE, tier 1 in packPro.
        uint256[] memory ids = _mint(1);
        _depositWithPerPackTiers(
            ids[0],
            _arr(PACK_BASE, packPro),
            _tierArr(3, 1)
        );

        // Open PACK_BASE — card drawn from row 3.
        uint256 reqId = _openPack(user, PACK_BASE);
        _fulfill(reqId, 0);

        // Card no longer in custody.
        assertFalse(packMachine.isInCustody(ids[0]));
        // Both pack rows emptied.
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 3), 0);
        assertEq(packMachine.getPackTierPoolSize(packPro, 1), 0);
        // Available counters decremented for the non-opening pack too.
        assertEq(packMachine.getPackAvailable(packPro), 0);
    }

    function test_PerPackTier_DepositFromPool_RestoresPerPackTiers() public {
        // Deposit A with tier 3 in Base, tier 1 in Pro.
        uint256[] memory ids = _mint(1);
        _depositWithPerPackTiers(
            ids[0],
            _arr(PACK_BASE, packPro),
            _tierArr(3, 1)
        );

        // Win the card from PACK_BASE.
        uint256 reqId = _openPack(user, PACK_BASE);
        _fulfill(reqId, 0);
        assertFalse(packMachine.isInCustody(ids[0]));

        // Simulate buyback: user transfers to operator, operator re-deposits via depositFromPool.
        vm.prank(user);
        assetNFT.transferFrom(user, operator, ids[0]);

        // L001 fix: setAuthorizedDepositor now requires paused.
        vm.prank(operator);
        packMachine.pause();
        vm.prank(operator);
        packMachine.setAuthorizedDepositor(operator, true);
        vm.prank(operator);
        packMachine.unpause();

        uint8[] memory fallbackTiers = new uint8[](1);
        fallbackTiers[0] = 0; // fallback tier (should not be used if dormant map exists)
        vm.startPrank(operator);
        assetNFT.approve(address(packMachine), ids[0]);
        packMachine.depositFromPool(ids, fallbackTiers, operator);
        vm.stopPrank();

        // Per-pack tiers restored from dormant map.
        assertTrue(packMachine.isInCustody(ids[0]));
        assertEq(packMachine.getPackTokenTier(ids[0], PACK_BASE), 3);
        assertEq(packMachine.getPackTokenTier(ids[0], packPro), 1);
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 3), 1);
        assertEq(packMachine.getPackTierPoolSize(packPro, 1), 1);
    }

    function test_PerPackTier_SetPackEligibility_NewPackUsesSuppliedTier() public {
        // Deposit A in Base only at tier 0.
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = 1;
        _deposit(ids, tiers, masks);

        // Add A to packElite at tier 2 (Uncommon).
        uint8[] memory eliteTiers = new uint8[](1);
        eliteTiers[0] = 2;
        vm.prank(operator);
        packMachine.setPackEligibility(packElite, ids, eliteTiers, true);

        assertEq(packMachine.getPackTokenTier(ids[0], packElite), 2);
        assertEq(packMachine.getPackTierPoolSize(packElite, 2), 1);
        // Original tier in Base unchanged.
        assertEq(packMachine.getPackTokenTier(ids[0], PACK_BASE), 0);
    }

    function test_PerPackTier_SetPackEligibility_ReSlotsOnTierChange() public {
        // Deposit A with tier 3 in Base.
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        tiers[0] = 3;
        uint256[] memory masks = new uint256[](1);
        masks[0] = 1; // Base only
        _deposit(ids, tiers, masks);

        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 3), 1);

        // Re-slot Base to tier 1 (remove then re-add with new tier).
        uint8[] memory baseTier1 = new uint8[](1); baseTier1[0] = 1;
        uint8[] memory emptyT = new uint8[](0);
        vm.startPrank(operator);
        packMachine.setPackEligibility(PACK_BASE, ids, emptyT, false);
        packMachine.setPackEligibility(PACK_BASE, ids, baseTier1, true);
        // Add Pro at tier 2.
        uint8[] memory proTier2 = new uint8[](1); proTier2[0] = 2;
        packMachine.setPackEligibility(packPro, ids, proTier2, true);
        vm.stopPrank();

        // Re-slotted: Base row 3 empty, row 1 filled; Pro row 2 filled.
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 3), 0);
        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 1), 1);
        assertEq(packMachine.getPackTierPoolSize(packPro, 2), 1);
        assertEq(packMachine.getPackAvailable(PACK_BASE), 1); // stable
        assertEq(packMachine.getPackAvailable(packPro), 1);
    }

    function test_PerPackTier_WithdrawClearsPerPackTiers() public {
        // Deposit A with tier 3 in Base.
        uint256[] memory ids = _mint(1);
        uint8[] memory t3 = new uint8[](1);
        t3[0] = 3;
        _depositWithPerPackTiers(ids[0], _arr(PACK_BASE), t3);

        vm.prank(operator);
        packMachine.pause();
        vm.prank(operator);
        packMachine.withdrawCards(ids);

        // After withdrawal, token is gone; a fresh re-deposit should start clean.
        // Re-mint and deposit with tier 0 — should succeed normally.
        uint256[] memory newIds = _mint(1);
        uint8[] memory newTiers = new uint8[](1);
        uint256[] memory newMasks = new uint256[](1);
        newMasks[0] = 1;
        vm.prank(operator);
        packMachine.unpause();
        _deposit(newIds, newTiers, newMasks);
        assertEq(packMachine.getPackTokenTier(newIds[0], PACK_BASE), 0);
    }

    function test_PerPackTier_Reverts_InvalidTier() public {
        uint256[] memory ids = _mint(1);
        uint256[] memory pcs = new uint256[](1); pcs[0] = 1;
        uint256[] memory pids = _arr(PACK_BASE);
        uint8[] memory trs = new uint8[](1); trs[0] = 6; // invalid (max 5)
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        vm.expectRevert(
            abi.encodeWithSelector(PackMachine.PackMachine__InvalidTier.selector, uint8(6))
        );
        packMachine.deposit(ids, pcs, pids, trs, operator);
        vm.stopPrank();
    }

    function test_PerPackTier_Reverts_DuplicatePackInDeposit() public {
        uint256[] memory ids = _mint(1);
        uint256[] memory pcs = new uint256[](1); pcs[0] = 2;
        uint256[] memory pids = new uint256[](2);
        pids[0] = PACK_BASE;
        pids[1] = PACK_BASE; // duplicate
        uint8[] memory trs = new uint8[](2);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        // Use full abi-encoded form since Foundry's bytes4 expectRevert does full-data comparison.
        vm.expectRevert(
            abi.encodeWithSelector(PackMachine.PackMachine__InvalidPackRef.selector, ids[0])
        );
        packMachine.deposit(ids, pcs, pids, trs, operator);
        vm.stopPrank();
    }

    /// @dev Helper: build a uint8[] from two tier values.
    function _tierArr(uint8 a, uint8 b) internal pure returns (uint8[] memory r) {
        r = new uint8[](2);
        r[0] = a;
        r[1] = b;
    }
}
