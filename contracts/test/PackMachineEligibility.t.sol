// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackMachine} from "../PackMachine.sol";
import {PackMachineFactory} from "../PackMachineFactory.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PackRegistry} from "../PackRegistry.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";
import {MockPermit2} from "../test-helpers/MockPermit2.sol";

/// @title PackMachineEligibilityTest
/// @notice Covers per-pack card eligibility: deposit with masks, setPackEligibility,
///         setTokenEligibility, draw constraints, shared removal, and reservation accounting.
contract PackMachineEligibilityTest is Test {
    PackMachine internal packMachine;
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
    PackRegistry internal packRegistry;
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
        "OpenPack(address user,uint256 packId,uint256 nonce)"
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
        vm.stopPrank();

        vm.prank(operator);
        address cloneAddr = factory.createPackMachine(
            PRICE, CARDS_PER_PACK, uint40(block.timestamp)
        );
        packMachine = PackMachine(cloneAddr);

        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(cloneAddr, true);

        vm.prank(operator);
        packMachine.setRetentionThreshold(0);

        // Add Pro (pack 1) and Elite (pack 2)
        uint32[5] memory weights = [uint32(7500), 1950, 400, 100, 50];
        vm.startPrank(operator);
        packPro = packRegistry.addPack(
            cloneAddr, PRICE, CARDS_PER_PACK, uint40(block.timestamp), 0, weights
        );
        packElite = packRegistry.addPack(
            cloneAddr, PRICE * 2, CARDS_PER_PACK, uint40(block.timestamp), 0, weights
        );
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

    function _deposit(
        uint256[] memory tokenIds,
        uint8[] memory tiers,
        uint256[] memory masks
    ) internal {
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(tokenIds, tiers, masks, operator);
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
            abi.encode(OPEN_PACK_TYPEHASH, user_, packId, nonce)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _openPack(address user_, uint256 packId) internal returns (uint256 requestId) {
        uint256 nonce = packMachine.openNonce(user_);
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
        assertEq(packMachine.effectivePrizePoolSize(), 3);
        assertEq(packMachine.getTierPoolSize(0), 3);

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
        assertEq(packMachine.getTierPoolSize(0), 0);
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

        // Add both to Pro
        vm.prank(operator);
        packMachine.setPackEligibility(packPro, ids, true);

        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 2);
        assertEq(packMachine.getPackAvailable(packPro), 2);
        assertTrue(packMachine.isTokenEligibleForPack(ids[0], packPro));

        // Remove ids[0] from Pro
        uint256[] memory single = new uint256[](1);
        single[0] = ids[0];
        vm.prank(operator);
        packMachine.setPackEligibility(packPro, single, false);

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

        vm.prank(operator);
        packMachine.setPackEligibility(PACK_BASE, ids, true); // already in Base — no-op

        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 1); // still 1, not doubled
        assertEq(packMachine.getPackAvailable(PACK_BASE), 1);
    }

    // =========================================================================
    // Test: setTokenEligibility diff-apply
    // =========================================================================

    function test_SetTokenEligibility_DiffApply() public {
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = _maskFor(_arr(PACK_BASE, packPro)); // Base & Pro initially
        _deposit(ids, tiers, masks);

        // Change to Pro & Elite (remove Base, add Elite)
        uint256[] memory newMasks = new uint256[](1);
        newMasks[0] = _maskFor(_arr(packPro, packElite));
        vm.prank(operator);
        packMachine.setTokenEligibility(ids, newMasks);

        assertEq(packMachine.getPackTierPoolSize(PACK_BASE, 0), 0);  // removed
        assertEq(packMachine.getPackTierPoolSize(packPro, 0), 1);    // kept
        assertEq(packMachine.getPackTierPoolSize(packElite, 0), 1);  // added
        assertEq(packMachine.getTokenEligibility(ids[0]), newMasks[0]);

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

        uint256 nonce = packMachine.openNonce(user);
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
        assertEq(packMachine.getTierPoolSize(0), 0);
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
        assertEq(packMachine.effectivePrizePoolSize(), 0);
        assertEq(packMachine.getPackAvailable(PACK_BASE), 0);

        // Fulfill — card is in pool, normal win path. Check the winner got the card.
        _fulfill(reqId, 0);
        assertEq(assetNFT.ownerOf(ids[0]), user);

        // effectivePrizePoolSize stays 0 (machine-wide win reduced it).
        assertEq(packMachine.effectivePrizePoolSize(), 0);
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
        vm.prank(operator);
        packMachine.setAuthorizedDepositor(operator, true);

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
        uint32[5] memory weights = [uint32(7500), 1950, 400, 100, 50];
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
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = 1 << 200; // pack 200 doesn't exist (only 0,1,2)
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        vm.expectRevert();
        packMachine.deposit(ids, tiers, masks, operator);
        vm.stopPrank();
    }

    // =========================================================================
    // Test: zero eligibility mask reverts
    // =========================================================================

    function test_Deposit_ZeroMaskReverts() public {
        uint256[] memory ids = _mint(1);
        uint8[] memory tiers = new uint8[](1);
        uint256[] memory masks = new uint256[](1);
        masks[0] = 0;
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        vm.expectRevert(
            abi.encodeWithSelector(PackMachine.PackMachine__NoEligibility.selector, ids[0])
        );
        packMachine.deposit(ids, tiers, masks, operator);
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

        assertEq(packMachine.effectivePrizePoolSize(), 2);
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
        assertEq(packMachine.effectivePrizePoolSize(), 0);
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
}
