// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackMachine} from "../PackMachine.sol";
import {PackMachineFactory} from "../PackMachineFactory.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PackRegistry} from "../PackRegistry.sol";
import {BuybackPool} from "../BuybackPool.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";
import {MockPermit2} from "../test-helpers/MockPermit2.sol";

/// @dev Tests for machine-wide cut-off logic: purchase gate at _assertOpenable().
contract PackMachineCutoffTest is Test {
    PackMachine internal packMachine;
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
    PackRegistry internal packRegistry;
    PermissionManager internal pm;
    MockERC20 internal usdc;
    AssetNFT internal assetNFT;
    MockVRFCoordinatorV2Plus internal coordinator;

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal upgrader = makeAddr("upgrader");
    address internal forwarder = makeAddr("forwarder");
    address internal financeWallet = makeAddr("financeWallet");
    address internal user = makeAddr("user");
    address internal unauthorized = makeAddr("unauthorized");

    uint256 internal operatorPk;
    address internal operator;

    bytes32 internal constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 packId,uint256 nonce)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint128 internal constant PRICE = 10e6;
    uint8 internal constant CARDS_PER_PACK = 1; // 1 card per pack for simpler cut-off math

    function setUp() public {
        (operator, operatorPk) = makeAddrAndKey("operator");

        PermissionManager pmImpl = new PermissionManager();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl),
            abi.encodeCall(PermissionManager.initialize, (admin))
        );
        pm = PermissionManager(address(pmProxy));

        vm.startPrank(admin);
        pm.grantRole(pm.PACK_OPERATOR_ROLE(), operator);
        pm.grantRole(pm.PAUSER_ROLE(), pauser);
        pm.grantRole(pm.UPGRADER_ROLE(), upgrader);
        pm.grantRole(pm.MINTER_ROLE(), operator);
        vm.stopPrank();

        usdc = new MockERC20();
        coordinator = new MockVRFCoordinatorV2Plus();

        AssetNFT assetNFTImpl = new AssetNFT(forwarder);
        ERC1967Proxy assetNFTProxy = new ERC1967Proxy(
            address(assetNFTImpl),
            abi.encodeCall(
                AssetNFT.initialize,
                (
                    address(pm),
                    "NettyWorth Assets",
                    "NWA",
                    "ipfs://contract",
                    makeAddr("royalty"),
                    250
                )
            )
        );
        assetNFT = AssetNFT(address(assetNFTProxy));

        MockPermit2 permit2Impl = new MockPermit2();
        vm.etch(
            0x000000000022D473030F116dDEE9F6B43aC78BA3,
            address(permit2Impl).code
        );

        PackVRFRouter routerImpl = new PackVRFRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                PackVRFRouter.initialize,
                (
                    address(pm),
                    address(coordinator),
                    1,
                    keccak256("key"),
                    700_000,
                    3
                )
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
            PRICE,
            CARDS_PER_PACK,
            uint40(block.timestamp)
        );
        packMachine = PackMachine(cloneAddr);

        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(cloneAddr, true);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _mintAndDeposit(
        uint256 count,
        uint8 tier
    ) internal returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](count);
        uint256 startId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        uint8[] memory tiers = new uint8[](count);
        for (uint256 i; i < count; i++) {
            recipients[i] = operator;
            uris[i] = "";
            tokenIds[i] = startId + i;
            tiers[i] = tier;
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        uint256[] memory masks = new uint256[](count);
        for (uint256 i; i < count; i++) masks[i] = 1;
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(tokenIds, tiers, masks, operator);
        vm.stopPrank();
    }

    function _signOpenPack(
        address machine,
        address user_,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user_, uint256(0), nonce)
        );
        bytes32 domainSep = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                machine
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSep, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _openPack(address machine_, address who) internal {
        usdc.mint(who, PRICE);
        vm.prank(who);
        usdc.approve(machine_, PRICE);
        bytes memory sig = _signOpenPack(
            machine_,
            who,
            PackMachine(machine_).openNonce(who)
        );
        vm.prank(who);
        PackMachine(machine_).openPack(who, 0, sig);
    }

    function _fulfillRequest(uint256 reqId, uint256 numWords) internal {
        uint256[] memory words = new uint256[](numWords);
        for (uint256 i; i < numWords; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(reqId, i)));
        }
        coordinator.fulfillRandomWords(address(vrfRouter), reqId, words);
    }

    // =========================================================================
    // totalInventory tracking
    // =========================================================================

    function test_TotalInventory_IncrementedOnDeposit() public {
        assertEq(packMachine.getTotalInventory(), 0);
        _mintAndDeposit(5, 0);
        assertEq(packMachine.getTotalInventory(), 5);
        _mintAndDeposit(3, 1);
        assertEq(packMachine.getTotalInventory(), 8);
    }

    function test_TotalInventory_NotIncrementedOnDepositFromPool() public {
        _mintAndDeposit(5, 0);
        assertEq(packMachine.getTotalInventory(), 5);

        // Set up a mock BuybackPool caller (just use a plain address with access)
        address mockPool = makeAddr("mockPool");
        vm.prank(operator);
        packMachine.setBuybackPool(mockPool);

        // Mint an NFT directly to mockPool and have it call depositFromPool
        uint256 startId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](1);
        string[] memory uris = new string[](1);
        recipients[0] = mockPool;
        uris[0] = "";
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);

        uint256[] memory tokenIds = new uint256[](1);
        uint8[] memory tiers = new uint8[](1);
        tokenIds[0] = startId;
        tiers[0] = 0;

        vm.startPrank(mockPool);
        assetNFT.approve(address(packMachine), startId);
        packMachine.depositFromPool(tokenIds, tiers, mockPool);
        vm.stopPrank();

        // totalInventory must NOT increase
        assertEq(packMachine.getTotalInventory(), 5);
        // But effective pool size did increase
        assertEq(packMachine.effectivePrizePoolSize(), 6);
    }

    // =========================================================================
    // isCutOff view
    // =========================================================================

    function test_IsCutOff_FalseWhenNoInventory() public view {
        assertFalse(packMachine.isCutOff());
    }

    function test_IsCutOff_FalseWhenThresholdZero() public {
        _mintAndDeposit(10, 0);
        vm.prank(operator);
        packMachine.setRetentionThreshold(0);
        assertFalse(packMachine.isCutOff());
    }

    function test_IsCutOff_FalseWhenAboveThreshold() public {
        // deposit 10, threshold 60% → cut-off at effective < 6; effective=10 → not cut off
        _mintAndDeposit(10, 0);
        assertFalse(packMachine.isCutOff());
    }

    function test_IsCutOff_TrueWhenBelowThreshold() public {
        // deposit 10, open 5 packs (fulfil each), effective drops to 5 (50% < 60%)
        _mintAndDeposit(10, 0);
        for (uint256 i = 1; i <= 5; i++) {
            _openPack(address(packMachine), user);
            _fulfillRequest(i, CARDS_PER_PACK);
        }
        // effective = 5, totalInventory = 10; 5*10000 < 10*6000 → true
        assertTrue(packMachine.isCutOff());
    }

    function test_IsCutOff_FalseAtExactBoundary() public {
        // deposit 10, open 4 packs → effective=6; 6*10000 = 10*6000 → boundary is NOT cut off (<, not <=)
        _mintAndDeposit(10, 0);
        for (uint256 i = 1; i <= 4; i++) {
            _openPack(address(packMachine), user);
            _fulfillRequest(i, CARDS_PER_PACK);
        }
        // effective = 6, totalInventory = 10; 6*10000 = 60000 >= 10*6000 = 60000 → not cut off (strict <)
        assertFalse(packMachine.isCutOff());
    }

    // =========================================================================
    // openPack cut-off gate
    // =========================================================================

    function test_OpenPack_SucceedsWhenAboveCutOff() public {
        // 10 deposited, none opened → 100% retained → should succeed
        _mintAndDeposit(10, 0);
        // no revert expected
        _openPack(address(packMachine), user);
    }

    function test_OpenPack_RevertsWhenBelowCutOff() public {
        // deposit 10, drain 5 packs → effective=5 (50% < 60%) — then next open reverts
        // Boundary: effective=6 → 6*10000 = 10*6000, NOT strictly less, so open 5 succeeds.
        // After fulfilling pack 5: effective=5. Pack 6 open → assertOpenable(5) → 5*10000 < 60000 → reverts.
        _mintAndDeposit(10, 0);
        for (uint256 i = 1; i <= 5; i++) {
            _openPack(address(packMachine), user);
            _fulfillRequest(i, CARDS_PER_PACK);
        }
        // effective = 5, totalInventory = 10; 5*10000=50000 < 10*6000=60000 → cut off
        assertTrue(packMachine.isCutOff());

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);
        bytes memory sig = _signOpenPack(
            address(packMachine),
            user,
            packMachine.openNonce(user)
        );
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__CutOff.selector,
                5,
                10
            )
        );
        packMachine.openPack(user, 0, sig);
    }

    function test_OpenPack_SucceedsWhenCutOffDisabled() public {
        _mintAndDeposit(10, 0);
        vm.prank(operator);
        packMachine.setRetentionThreshold(0);

        // Drain to 1 remaining
        for (uint256 i = 1; i <= 9; i++) {
            _openPack(address(packMachine), user);
            _fulfillRequest(i, CARDS_PER_PACK);
        }
        assertEq(packMachine.effectivePrizePoolSize(), 1);
        // threshold=0 so isCutOff() is false
        assertFalse(packMachine.isCutOff());
        // final open should succeed
        _openPack(address(packMachine), user);
    }

    function test_OpenPack_RevertsOneBelow60Boundary() public {
        // effective=6 is the boundary (6*10000 = 10*6000, not strictly less → allowed).
        // effective=5 is one below (5*10000 < 10*6000 → cut off).
        // Drain 4, verify not cut off. Drain 1 more, verify cut off.
        _mintAndDeposit(10, 0);
        for (uint256 i = 1; i <= 4; i++) {
            _openPack(address(packMachine), user);
            _fulfillRequest(i, CARDS_PER_PACK);
        }
        assertFalse(packMachine.isCutOff()); // effective=6, exactly at boundary → not cut off

        _openPack(address(packMachine), user);
        _fulfillRequest(5, CARDS_PER_PACK);
        assertTrue(packMachine.isCutOff()); // effective=5, below boundary → cut off

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);
        bytes memory sig = _signOpenPack(
            address(packMachine),
            user,
            packMachine.openNonce(user)
        );
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__CutOff.selector,
                5,
                10
            )
        );
        packMachine.openPack(user, 0, sig);
    }

    // =========================================================================
    // setRetentionThreshold admin
    // =========================================================================

    function test_SetRetentionThreshold_UpdatesValue() public {
        assertEq(packMachine.getRetentionThresholdBps(), 6000);
        vm.prank(operator);
        packMachine.setRetentionThreshold(5000);
        assertEq(packMachine.getRetentionThresholdBps(), 5000);
    }

    function test_SetRetentionThreshold_ZeroDisablesCutOff() public {
        vm.prank(operator);
        packMachine.setRetentionThreshold(0);
        assertEq(packMachine.getRetentionThresholdBps(), 0);
        assertFalse(packMachine.isCutOff());
    }

    function test_SetRetentionThreshold_RevertsIfOver10000() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__InvalidBps.selector,
                uint16(10001)
            )
        );
        packMachine.setRetentionThreshold(10001);
    }

    function test_SetRetentionThreshold_EmitsEvent() public {
        vm.prank(operator);
        vm.expectEmit(false, false, false, true);
        emit PackMachine.RetentionThresholdUpdated(6000, 7500);
        packMachine.setRetentionThreshold(7500);
    }

    function test_SetRetentionThreshold_RevertsIfUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        packMachine.setRetentionThreshold(5000);
    }

    // =========================================================================
    // depositFromPool access control
    // =========================================================================

    function test_DepositFromPool_RevertsIfNotBuybackPool() public {
        uint256[] memory tokenIds = new uint256[](1);
        uint8[] memory tiers = new uint8[](1);
        tokenIds[0] = 1;
        tiers[0] = 0;
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__UnauthorizedDepositor.selector,
                unauthorized
            )
        );
        packMachine.depositFromPool(tokenIds, tiers, unauthorized);
    }

    function test_DepositFromPool_SucceedsWhenCalledByBuybackPool() public {
        _mintAndDeposit(5, 0);
        assertEq(packMachine.getTotalInventory(), 5);

        address mockPool = makeAddr("mockPool");
        vm.prank(operator);
        packMachine.setBuybackPool(mockPool);

        uint256 startId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](1);
        string[] memory uris = new string[](1);
        recipients[0] = mockPool;
        uris[0] = "";
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);

        uint256[] memory tokenIds = new uint256[](1);
        uint8[] memory tiers = new uint8[](1);
        tokenIds[0] = startId;
        tiers[0] = 0;

        vm.startPrank(mockPool);
        assetNFT.approve(address(packMachine), startId);
        packMachine.depositFromPool(tokenIds, tiers, mockPool);
        vm.stopPrank();

        assertEq(packMachine.effectivePrizePoolSize(), 6);
        // totalInventory unchanged — re-deposit excluded
        assertEq(packMachine.getTotalInventory(), 5);
    }

    // =========================================================================
    // Custom threshold values
    // =========================================================================

    function test_CutOff_With100PercentThreshold() public {
        // 100% threshold means cut-off as soon as any card leaves the pool
        _mintAndDeposit(5, 0);
        vm.prank(operator);
        packMachine.setRetentionThreshold(10000);

        // Opening first pack triggers VRF reservation (effective 4) → 4*10000 < 5*10000 → cut off
        _openPack(address(packMachine), user);
        // effective is now 4 (reservation taken); cut-off check happens BEFORE decrement so first pack succeeded

        // Next open should revert
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);
        bytes memory sig = _signOpenPack(
            address(packMachine),
            user,
            packMachine.openNonce(user)
        );
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__CutOff.selector,
                4,
                5
            )
        );
        packMachine.openPack(user, 0, sig);
    }

    function test_CutOff_With50PercentThreshold() public {
        // 50% threshold: cut-off when effective < 5 (for 10 total)
        _mintAndDeposit(10, 0);
        vm.prank(operator);
        packMachine.setRetentionThreshold(5000);

        // drain to 5 exactly (boundary — strict < so 5*10000 = 10*5000 → NOT cut off)
        for (uint256 i = 1; i <= 5; i++) {
            _openPack(address(packMachine), user);
            _fulfillRequest(i, CARDS_PER_PACK);
        }
        assertFalse(packMachine.isCutOff());

        // drain one more (effective=4 → 4*10000 < 10*5000 → cut off)
        _openPack(address(packMachine), user);
        _fulfillRequest(6, CARDS_PER_PACK);
        assertTrue(packMachine.isCutOff());
    }
}
