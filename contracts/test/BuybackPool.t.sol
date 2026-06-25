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

contract BuybackPoolTest is Test {
    PackMachine internal packMachine;
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
    PackRegistry internal packRegistry;
    BuybackPool internal pool;
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

    address internal constant PERMIT2_ADDRESS =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 packId,uint256 nonce)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint128 internal constant PRICE = 10e6; // 10 USDC
    uint8 internal constant CARDS_PER_PACK = 2;
    uint128 internal constant PRICE_PER_CARD = PRICE / CARDS_PER_PACK; // 5 USDC
    // 20% allocation → 2 USDC per pack → 1 USDC per card goes to pool
    uint16 internal constant BUYBACK_ALLOC_BPS = 2000;

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
        vm.etch(PERMIT2_ADDRESS, address(permit2Impl).code);

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

        // Deploy BuybackPool
        BuybackPool poolImpl = new BuybackPool();
        ERC1967Proxy poolProxy = new ERC1967Proxy(
            address(poolImpl),
            abi.encodeCall(
                BuybackPool.initialize,
                (
                    address(pm),
                    address(assetNFT),
                    address(usdc),
                    financeWallet,
                    address(factory)
                )
            )
        );
        pool = BuybackPool(address(poolProxy));

        // Wire up: PackMachine → BuybackPool
        vm.prank(operator);
        packMachine.setBuybackPool(address(pool));
        vm.prank(operator);
        packRegistry.setPackBuybackAllocation(address(packMachine), 0, BUYBACK_ALLOC_BPS);

        // Disable cut-off so BuybackPool tests are not affected by it.
        vm.prank(operator);
        packMachine.setRetentionThreshold(0);

        // BuybackPool → PackMachine
        vm.prank(operator);
        pool.registerPackMachine(address(packMachine), true);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _depositNFTs(
        uint256 count
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
        address user_,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user_, uint256(0), nonce)
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                address(packMachine)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _seedPool(uint256 amount) internal {
        usdc.mint(address(pool), amount);
    }

    function _openPackAndFulfill()
        internal
        returns (uint256[] memory wonTokens)
    {
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, packMachine.openNonce(user));
        vm.prank(user);
        packMachine.openPack(user, 0, sig);

        uint256 requestId = 1; // MockVRFCoordinator assigns sequential IDs
        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        for (uint256 i; i < CARDS_PER_PACK; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(requestId, i)));
        }
        coordinator.fulfillRandomWords(address(vrfRouter), requestId, words);

        // Collect which tokens user received
        wonTokens = new uint256[](CARDS_PER_PACK);
        uint256 found;
        for (
            uint256 tokenId = 1;
            tokenId <= assetNFT.totalSupply();
            tokenId++
        ) {
            if (assetNFT.ownerOf(tokenId) == user) {
                wonTokens[found++] = tokenId;
                if (found == CARDS_PER_PACK) break;
            }
        }
    }

    // =========================================================================
    // registerToken
    // =========================================================================

    function test_RegisterToken_OnlyByRegisteredMachine() public {
        _depositNFTs(CARDS_PER_PACK);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__UnauthorizedSource.selector,
                unauthorized
            )
        );
        vm.prank(unauthorized);
        pool.registerToken(1, 5e6, 0, address(packMachine));
    }

    function test_RegisterToken_RevertsIfAlreadyActive() public {
        _depositNFTs(CARDS_PER_PACK);
        _openPackAndFulfill();

        // Find a token owned by user (which was registered)
        uint256 tokenId;
        for (uint256 i = 1; i <= assetNFT.totalSupply(); i++) {
            if (assetNFT.ownerOf(i) == user) {
                tokenId = i;
                break;
            }
        }
        require(tokenId > 0, "no token found");

        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__TokenAlreadyRegistered.selector,
                tokenId
            )
        );
        vm.prank(address(packMachine));
        pool.registerToken(tokenId, 5e6, 0, address(packMachine));
    }

    function test_RegisterToken_StoresCorrectData() public {
        _depositNFTs(CARDS_PER_PACK);
        _openPackAndFulfill();

        uint256 tokenId;
        for (uint256 i = 1; i <= assetNFT.totalSupply(); i++) {
            if (assetNFT.ownerOf(i) == user) {
                tokenId = i;
                break;
            }
        }
        require(tokenId > 0, "no token found");

        (uint128 price, uint8 tier, address src, bool active) = pool
            .getTokenInfo(tokenId);
        assertEq(price, PRICE_PER_CARD);
        assertEq(tier, 0);
        assertEq(src, address(packMachine));
        assertTrue(active);
    }

    // =========================================================================
    // buyback
    // =========================================================================

    function test_Buyback_RevertsIfNotRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__TokenNotRegistered.selector,
                999
            )
        );
        pool.buyback(999);
    }

    function test_Buyback_RevertsIfCallerNotOwner() public {
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__NotTokenOwner.selector,
                tokenId,
                unauthorized
            )
        );
        vm.prank(unauthorized);
        pool.buyback(tokenId);
    }

    function test_Buyback_RevertsIfInsufficientBalance() public {
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        // Drain the pool
        vm.prank(pauser);
        pool.pause();
        vm.prank(admin);
        pool.emergencyWithdraw();
        vm.prank(pauser);
        pool.unpause();

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        uint256 expected = (uint256(PRICE_PER_CARD) * 8000) / 10000;
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__InsufficientBalance.selector,
                0,
                expected
            )
        );
        vm.prank(user);
        pool.buyback(tokenId);
    }

    function test_Buyback_Pays80PercentByDefault() public {
        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 expectedPayout = (uint256(PRICE_PER_CARD) * 8000) / 10000; // 80% of 5 USDC = 4 USDC

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);

        uint256 userBefore = usdc.balanceOf(user);
        vm.prank(user);
        pool.buyback(tokenId);
        uint256 userAfter = usdc.balanceOf(user);

        assertEq(userAfter - userBefore, expectedPayout);
    }

    function test_Buyback_TransfersNFTFromUser() public {
        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        assertEq(assetNFT.ownerOf(tokenId), user);

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(user);
        pool.buyback(tokenId);

        // NFT should no longer be owned by user (redeposited into packMachine)
        assertNotEq(assetNFT.ownerOf(tokenId), user);
    }

    function test_Buyback_RedepositsNFTIntoPackMachine() public {
        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 poolSizeBefore = packMachine.effectivePrizePoolSize();

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(user);
        pool.buyback(tokenId);

        // effectivePrizePoolSize should have increased by 1
        assertEq(packMachine.effectivePrizePoolSize(), poolSizeBefore + 1);
        assertEq(assetNFT.ownerOf(tokenId), address(packMachine));
    }

    function test_Buyback_MarksTokenInactive() public {
        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(user);
        pool.buyback(tokenId);

        (, , , bool active) = pool.getTokenInfo(tokenId);
        assertFalse(active);
    }

    function test_Buyback_RevertsIfAlreadyBoughtBack() public {
        _seedPool(10e6);
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(user);
        pool.buyback(tokenId);

        // Token is now in packMachine, user no longer owns it
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__TokenNotActive.selector,
                tokenId
            )
        );
        vm.prank(user);
        pool.buyback(tokenId);
    }

    // =========================================================================
    // Per-PackMachine buyback rate overrides
    // =========================================================================

    function test_PackMachineBuybackBpsOverride() public {
        _seedPool(10e6);
        // Set this machine's buyback to 70% (override default 80%)
        vm.prank(operator);
        pool.setPackMachineBuybackBps(address(packMachine), 7000);

        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 expectedPayout = (uint256(PRICE_PER_CARD) * 7000) / 10000;

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        uint256 userBefore = usdc.balanceOf(user);
        vm.prank(user);
        pool.buyback(tokenId);

        assertEq(usdc.balanceOf(user) - userBefore, expectedPayout);
    }

    function test_PackMachineBuybackBps_FallsBackToDefault() public {
        _seedPool(10e6);
        // No per-machine override set — should use defaultBuybackBps (80%)
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 expectedPayout = (uint256(PRICE_PER_CARD) * 8000) / 10000;

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        uint256 userBefore = usdc.balanceOf(user);
        vm.prank(user);
        pool.buyback(tokenId);

        assertEq(usdc.balanceOf(user) - userBefore, expectedPayout);
    }

    function test_SetPackMachineBuybackBps_Validation() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__InvalidBps.selector,
                uint16(10001)
            )
        );
        vm.prank(operator);
        pool.setPackMachineBuybackBps(address(packMachine), 10001);

        vm.expectRevert(BuybackPool.BuybackPool__ZeroAddress.selector);
        vm.prank(operator);
        pool.setPackMachineBuybackBps(address(0), 9000);
    }

    function test_SetPackMachineBuybackBps_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit BuybackPool.PackMachineBuybackBpsUpdated(
            address(packMachine),
            0,
            9000
        );
        vm.prank(operator);
        pool.setPackMachineBuybackBps(address(packMachine), 9000);
        assertEq(pool.getPackMachineBuybackBps(address(packMachine)), 9000);
    }

    function test_DifferentMachines_DifferentRates() public {
        // Deploy a second PackMachine with a different rate
        vm.prank(operator);
        address clone2Addr = factory.createPackMachine(
            PRICE,
            CARDS_PER_PACK,
            uint40(block.timestamp)
        );
        PackMachine packMachine2 = PackMachine(clone2Addr);

        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(clone2Addr, true);
        vm.prank(operator);
        packMachine2.setBuybackPool(address(pool));
        vm.prank(operator);
        packRegistry.setPackBuybackAllocation(clone2Addr, 0, BUYBACK_ALLOC_BPS);
        vm.prank(operator);
        packMachine2.setRetentionThreshold(0);
        vm.prank(operator);
        pool.registerPackMachine(clone2Addr, true);

        // Set different rates: machine1 = 80% (default), machine2 = 90%
        vm.prank(operator);
        pool.setPackMachineBuybackBps(clone2Addr, 9000);

        assertEq(pool.getPackMachineBuybackBps(address(packMachine)), 0); // uses default 80%
        assertEq(pool.getPackMachineBuybackBps(clone2Addr), 9000);
    }

    function test_ClearPackMachineBuybackBps_FallsBackToDefault() public {
        _seedPool(10e6);
        vm.prank(operator);
        pool.setPackMachineBuybackBps(address(packMachine), 7000);

        // Clear override by setting to 0
        vm.prank(operator);
        pool.setPackMachineBuybackBps(address(packMachine), 0);

        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        uint256 expectedPayout = (uint256(PRICE_PER_CARD) * 8000) / 10000;

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        uint256 userBefore = usdc.balanceOf(user);
        vm.prank(user);
        pool.buyback(tokenId);

        assertEq(usdc.balanceOf(user) - userBefore, expectedPayout);
    }

    // =========================================================================
    // Payment split from PackMachine
    // =========================================================================

    function test_PaymentSplit_SendsCorrectAmountsToPoolAndTreasury() public {
        _depositNFTs(CARDS_PER_PACK);

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        uint256 expectedBuybackAmount =
            (uint256(PRICE) * BUYBACK_ALLOC_BPS) / 10000; // 20% = 2 USDC
        uint256 expectedTreasuryAmount = PRICE - expectedBuybackAmount; // 80% = 8 USDC

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, 0, sig);

        assertEq(usdc.balanceOf(address(pool)), expectedBuybackAmount);
        assertEq(usdc.balanceOf(financeWallet), expectedTreasuryAmount);
    }

    function test_PaymentSplit_ZeroAllocation_AllGoesToTreasury() public {
        // Disable allocation
        vm.prank(operator);
        packRegistry.setPackBuybackAllocation(address(packMachine), 0, 0);

        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, 0, sig);

        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(financeWallet), PRICE);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function test_EmergencyWithdraw_RequiresPaused() public {
        vm.expectRevert(BuybackPool.BuybackPool__NotPaused.selector);
        vm.prank(admin);
        pool.emergencyWithdraw();
    }

    function test_EmergencyWithdraw_DrainToFinanceWallet() public {
        // Seed the pool with some USDC
        usdc.mint(address(pool), 100e6);

        vm.prank(pauser);
        pool.pause();

        uint256 treasuryBefore = usdc.balanceOf(financeWallet);
        vm.prank(admin);
        pool.emergencyWithdraw();

        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(financeWallet), treasuryBefore + 100e6);
    }

    function test_RegisterPackMachine_UnauthorizedReverts() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.registerPackMachine(makeAddr("x"), true);
    }

    function test_SetDefaultBuybackBps_InvalidReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__InvalidBps.selector,
                uint16(10001)
            )
        );
        vm.prank(operator);
        pool.setDefaultBuybackBps(10001);
    }

    function test_Pause_BlocksBuyback() public {
        _depositNFTs(CARDS_PER_PACK);
        uint256[] memory wonTokens = _openPackAndFulfill();
        uint256 tokenId = wonTokens[0];

        vm.prank(pauser);
        pool.pause();

        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert();
        vm.prank(user);
        pool.buyback(tokenId);
    }

    function test_PoolBalance_ReflectsUSDCHeld() public {
        usdc.mint(address(pool), 50e6);
        assertEq(pool.poolBalance(), 50e6);
    }

    function test_RescueNFT_AdminCanRetrieveStuckNFT() public {
        // Simulate a stuck NFT in the pool
        uint256[] memory ids = new uint256[](1);
        string[] memory uris = new string[](1);
        address[] memory recipients = new address[](1);
        ids[0] = assetNFT.totalSupply() + 1;
        uris[0] = "";
        recipients[0] = admin;
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);

        vm.prank(admin);
        assetNFT.transferFrom(admin, address(pool), ids[0]);
        assertEq(assetNFT.ownerOf(ids[0]), address(pool));

        vm.prank(admin);
        pool.rescueNFT(ids[0], admin);
        assertEq(assetNFT.ownerOf(ids[0]), admin);
    }
}
