// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
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
import {MockAssetLendingPool} from "../test-helpers/MockAssetLendingPool.sol";

/// @notice Security regression tests — each test demonstrates a known vulnerability.
///         After applying the corresponding fix, the test outcome should invert as documented.
contract PackMachineSecurityTest is Test {
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
    address internal forwarder = makeAddr("forwarder");
    address internal financeWallet = makeAddr("financeWallet");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");

    uint256 internal operatorPk;
    address internal operator;

    address internal constant PERMIT2_ADDRESS =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 packId,uint256 nonce,bytes32 codeId)"
    );

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint128 internal constant PRICE = 10e6; // 10 USDC
    uint8 internal constant CARDS_PER_PACK = 3;

    // =========================================================================
    // Setup
    // =========================================================================

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
        pm.grantRole(pm.UPGRADER_ROLE(), admin);
        pm.grantRole(pm.MINTER_ROLE(), operator);
        pm.grantRole(pm.BLACKLIST_ROLE(), admin);
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
                    500_000,
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

        // Wire mock lending pool so getAppraisalValue works
        MockAssetLendingPool mockLendingPool = new MockAssetLendingPool();
        vm.prank(admin);
        assetNFT.setLendingPool(address(mockLendingPool));

        // Wide-open FMV bounds so deposits don't require per-token appraisals
        uint128[6] memory minFmv;
        uint128[6] memory maxFmv;
        for (uint256 t; t < 6; ++t) maxFmv[t] = type(uint128).max;
        vm.prank(operator);
        packRegistry.setPackTierFmvBounds(address(packMachine), 0, minFmv, maxFmv);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _depositNFTs(uint256 count) internal {
        uint256 startId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        uint256[] memory tokenIds = new uint256[](count);
        uint8[] memory tiers = new uint8[](count); // all Base = 0
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

    function _signOpenPackFor(
        address machine,
        address user_,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user_, uint256(0), nonce, bytes32(0))
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                machine
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _openPackAsUser(address who, uint256 nonce) internal {
        bytes memory sig = _signOpenPackFor(address(packMachine), who, nonce);
        usdc.mint(who, PRICE);
        vm.startPrank(who);
        usdc.approve(address(packMachine), PRICE);
        packMachine.openPack(who, 0, sig);
        vm.stopPrank();
    }

    function _fulfillRequest(uint256 requestId, uint256 numWords) internal {
        uint256[] memory words = new uint256[](numWords);
        for (uint256 i; i < numWords; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(requestId, i)));
        }
        coordinator.fulfillRandomWords(address(vrfRouter), requestId, words);
    }

    // =========================================================================
    // [HIGH] resetEffectivePrizePoolSize over-commitment → division-by-zero panic
    //
    // Fix applied: resetEffectivePrizePoolSize() now requires the machine to be
    // paused, preventing the reset while opens are in-flight.
    // This test verifies the fix: calling reset without pausing must revert.
    // =========================================================================

    function test_ResetEffectivePoolSize_RevertsWhenNotPaused() public {
        _depositNFTs(6);

        _openPackAsUser(user, 0);
        _openPackAsUser(user2, 0);

        // Reset without pausing must now revert
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(PackMachine.PackMachine__NotPaused.selector)
        );
        packMachine.resetEffectivePrizePoolSize();
    }

    function test_ResetEffectivePoolSize_SucceedsWhenPaused() public {
        _depositNFTs(6);

        _openPackAsUser(user, 0);
        _openPackAsUser(user2, 0);

        // Fulfill both to remove cards from the pool
        _fulfillRequest(1, CARDS_PER_PACK);
        _fulfillRequest(2, CARDS_PER_PACK);

        // Pool is now empty; pause and reset
        vm.prank(pauser);
        packMachine.pause();

        vm.prank(operator);
        packMachine.resetEffectivePrizePoolSize();

        assertEq(packMachine.getMachineInfo().effectivePrizePoolSize, 0);
    }

    // =========================================================================
    // [MEDIUM] Blacklisted recipient permanently DOS-es VRF fulfillment
    //
    // Fix applied: IERC721.transferFrom is now wrapped in try/catch. Failed
    // transfers return the card to the pool instead of reverting the callback.
    // This test verifies the fix: fulfillment succeeds and cards return to pool.
    // =========================================================================

    function test_FulfillRandomness_BlacklistedRecipient_CardsReturnToPool()
        public
    {
        _depositNFTs(6);

        _openPackAsUser(user, 0); // requestId 1, user paid PRICE

        // Admin blacklists the user before VRF callback arrives
        address[] memory accounts = new address[](1);
        bool[] memory statuses = new bool[](1);
        accounts[0] = user;
        statuses[0] = true;
        vm.prank(admin);
        assetNFT.setBlacklisted(accounts, statuses);

        // Fulfillment no longer reverts — try/catch absorbs the failed transfers
        _fulfillRequest(1, CARDS_PER_PACK);

        // All 3 cards were returned to the pool
        assertEq(assetNFT.balanceOf(address(packMachine)), 6);
        assertEq(packMachine.getTierPoolSize(0), 6);
        // User still received nothing
        assertEq(assetNFT.balanceOf(user), 0);
    }

    // =========================================================================
    // [MEDIUM] setAssetNFT retroactively bricks all existing clone fulfillments
    //
    // Fix applied: assetNFT is snapshotted into clone storage at initialize().
    // fulfillRandomness() now reads $.assetNFT (the original address), so a
    // factory-level setAssetNFT() no longer affects existing clones.
    // This test verifies the fix: fulfillment succeeds after factory config change.
    // =========================================================================

    function test_FulfillRandomness_SucceedsAfterFactoryAssetNFTChanged()
        public
    {
        _depositNFTs(6);

        _openPackAsUser(user, 0); // requestId 1

        // Admin points the factory at a brand-new (empty) AssetNFT
        AssetNFT newNFT = new AssetNFT(forwarder);
        vm.prank(admin);
        factory.setAssetNFT(address(newNFT));

        // fulfillRandomness uses the clone-local assetNFT snapshot → succeeds
        _fulfillRequest(1, CARDS_PER_PACK);

        assertEq(assetNFT.balanceOf(user), CARDS_PER_PACK);
    }

    // =========================================================================
    // [LOW] cardsPerPack = 0 allows a pack machine that charges USDC but
    //       delivers no cards
    //
    // Fix applied: createPackMachine() now reverts with
    // PackMachineFactory__InvalidCardsPerPack when cardsPerPack == 0.
    // This test verifies the fix: the deployment itself must revert.
    // =========================================================================

    function test_CreatePackMachine_RevertsOnZeroCardsPerPack() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachineFactory
                    .PackMachineFactory__InvalidCardsPerPack
                    .selector
            )
        );
        factory.createPackMachine(PRICE, 0, uint40(block.timestamp));
    }
}
