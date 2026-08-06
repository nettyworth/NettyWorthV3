// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PackBatcher} from "../PackBatcher.sol";
import {PackMachine} from "../PackMachine.sol";
import {PackMachineFactory} from "../PackMachineFactory.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PackRegistry} from "../PackRegistry.sol";
import {PackTierRegistry} from "../PackTierRegistry.sol";
import {BuybackPool} from "../BuybackPool.sol";
import {PromoCodeRegistry} from "../PromoCodeRegistry.sol";
import {IPromoCodeRegistry} from "../interfaces/IPromoCodeRegistry.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {PermissionConsumer} from "../PermissionConsumer.sol";
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";
import {MockPermit2} from "../test-helpers/MockPermit2.sol";
import {MockAssetLendingPool} from "../test-helpers/MockAssetLendingPool.sol";

/// @notice Tests for PackBatcher — opening N packs on one PackMachine clone in a single call.
///
///         The batcher exists because card checkout executes exactly one `{to, data}` per
///         settlement, so a multi-pack card purchase previously charged N and opened 1.
///         The invariants that matter here: the payer is always `msg.sender`, no allowance
///         or balance survives the call, the promo code applies to the first open only, and
///         an under-funded batch unwinds completely rather than opening some of the packs.
contract PackBatcherTest is Test {
    // =========================================================================
    // Contracts
    // =========================================================================

    PackBatcher internal batcher;
    PackMachine internal packMachine;
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
    PackRegistry internal packRegistry;
    PackTierRegistry internal packTierRegistry;
    BuybackPool internal pool;
    PromoCodeRegistry internal promoRegistry;
    PermissionManager internal pm;
    MockERC20 internal usdc;
    AssetNFT internal assetNFT;
    MockVRFCoordinatorV2Plus internal coordinator;

    // =========================================================================
    // Actors
    // =========================================================================

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal forwarder = makeAddr("forwarder");
    address internal financeWallet = makeAddr("financeWallet");
    address internal alice = makeAddr("alice");
    /// @dev Stands in for the card-settlement relayer: pays the USDC, receives no cards.
    address internal payer = makeAddr("payer");

    uint256 internal operatorPk;
    address internal operator;

    // =========================================================================
    // Constants
    // =========================================================================

    address internal constant PERMIT2_ADDRESS =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 packId,uint256 nonce,bytes32 codeId)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint128 internal constant PRICE = 10e6; // 10 USDC (6-decimal)
    uint8 internal constant CARDS_PER_PACK = 2;
    uint16 internal constant BUYBACK_ALLOC_BPS = 2000; // 20 %
    uint16 internal constant DISCOUNT_BPS = 1000; // 10 %

    bytes32 internal constant PROMO_CODE = keccak256("PROMO10");
    uint16 internal constant PROMO_BPS = 1000; // 10 %

    uint256 internal constant QTY = 4;

    // =========================================================================
    // setUp — full real stack (mirrors PackMachineFirstOpenDiscount.t.sol)
    // =========================================================================

    function setUp() public {
        (operator, operatorPk) = makeAddrAndKey("operator");

        // ── PermissionManager ─────────────────────────────────────────────────
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
        vm.stopPrank();

        // ── Mocks ─────────────────────────────────────────────────────────────
        usdc = new MockERC20();
        coordinator = new MockVRFCoordinatorV2Plus();
        MockPermit2 permit2Impl = new MockPermit2();
        vm.etch(PERMIT2_ADDRESS, address(permit2Impl).code);

        // ── AssetNFT ──────────────────────────────────────────────────────────
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

        // ── PackVRFRouter ─────────────────────────────────────────────────────
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

        // ── PackMachineFactory + clone ────────────────────────────────────────
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

        // ── PackRegistry + PackTierRegistry ───────────────────────────────────
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
            PRICE,
            CARDS_PER_PACK,
            uint40(block.timestamp)
        );
        packMachine = PackMachine(cloneAddr);

        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(cloneAddr, true);

        MockAssetLendingPool mockLendingPool = new MockAssetLendingPool();
        vm.prank(admin);
        assetNFT.setLendingPool(address(mockLendingPool));

        // Wide-open FMV bounds so deposits don't require per-token appraisals
        uint128[6] memory minFmv;
        uint128[6] memory maxFmv;
        for (uint256 t; t < 6; ++t) maxFmv[t] = type(uint128).max;
        vm.prank(operator);
        packRegistry.setPackTierFmvBounds(
            address(packMachine),
            0,
            minFmv,
            maxFmv
        );

        // ── BuybackPool ───────────────────────────────────────────────────────
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

        vm.prank(pauser);
        packMachine.pause();
        vm.prank(operator);
        packMachine.setBuybackPool(address(pool));
        vm.prank(pauser);
        packMachine.unpause();
        vm.prank(operator);
        packRegistry.setPackBuybackAllocation(
            address(packMachine),
            0,
            BUYBACK_ALLOC_BPS
        );
        vm.prank(operator);
        pool.registerPackMachine(address(packMachine), true);

        // ── PromoCodeRegistry ─────────────────────────────────────────────────
        PromoCodeRegistry promoImpl = new PromoCodeRegistry();
        ERC1967Proxy promoProxy = new ERC1967Proxy(
            address(promoImpl),
            abi.encodeCall(PromoCodeRegistry.initialize, (address(pm)))
        );
        promoRegistry = PromoCodeRegistry(address(promoProxy));

        vm.startPrank(admin);
        promoRegistry.setPackMachineFactory(address(factory));
        promoRegistry.setBuybackPool(address(pool));
        factory.setPromoCodeRegistry(address(promoRegistry));
        vm.stopPrank();
        vm.prank(operator);
        pool.setPromoCodeRegistry(address(promoRegistry));

        usdc.mint(address(pool), 1000e6);

        // A oncePerUser code — proves the batcher applies it to the first open only.
        vm.prank(operator);
        promoRegistry.createCode(
            PROMO_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            PROMO_BPS,
            0, // no expiry
            0, // uncapped
            false, // not restricted
            true, // oncePerUser
            address(0)
        );

        // ── PackBatcher (the system under test) ───────────────────────────────
        PackBatcher batcherImpl = new PackBatcher();
        ERC1967Proxy batcherProxy = new ERC1967Proxy(
            address(batcherImpl),
            abi.encodeCall(
                PackBatcher.initialize,
                (address(pm), address(factory))
            )
        );
        batcher = PackBatcher(address(batcherProxy));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Deposit `count` freshly-minted NFTs (all tier 0, eligible for pack 0).
    function _depositNFTs(uint256 count) internal {
        uint256[] memory tokenIds = new uint256[](count);
        uint256 startId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < count; i++) {
            recipients[i] = operator;
            uris[i] = "";
            tokenIds[i] = startId + i;
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);

        uint256[] memory packCounts = new uint256[](count);
        uint256[] memory packIds = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        for (uint256 i; i < count; i++) packCounts[i] = 1;

        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(tokenIds, packCounts, packIds, tiers, operator);
        vm.stopPrank();
    }

    /// @dev Build an operator-signed OpenPack digest for an explicit nonce.
    function _signOpenPack(
        address user_,
        uint256 nonce,
        bytes32 codeId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user_, uint256(0), nonce, codeId)
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

    /// @dev Build `count` signatures for consecutive nonces starting at the user's current one.
    ///      `codeId` goes on the first only — exactly how the batcher dispatches them.
    function _signBatch(
        address user_,
        uint256 count,
        bytes32 codeId
    ) internal view returns (bytes[] memory signatures) {
        uint256 startNonce = packMachine.getUserInfo(user_).openNonce;
        signatures = new bytes[](count);
        for (uint256 i; i < count; ++i) {
            signatures[i] = _signOpenPack(
                user_,
                startNonce + i,
                i == 0 ? codeId : bytes32(0)
            );
        }
    }

    /// @dev Fund `payer` with `amount` USDC and approve the batcher for it.
    function _fundPayer(uint256 amount) internal {
        usdc.mint(payer, amount);
        vm.prank(payer);
        usdc.approve(address(batcher), amount);
    }

    /// @dev Fulfill VRF requests `1..count` (MockVRFCoordinatorV2Plus ids start at 1).
    function _fulfillAll(uint256 count) internal {
        for (uint256 id = 1; id <= count; ++id) {
            uint256[] memory words = new uint256[](CARDS_PER_PACK);
            for (uint256 i; i < CARDS_PER_PACK; i++) {
                words[i] = uint256(keccak256(abi.encodePacked(id, i)));
            }
            coordinator.fulfillRandomWords(address(vrfRouter), id, words);
        }
    }

    // =========================================================================
    // Happy path
    // =========================================================================

    function test_openPacks_opensEveryPackAndPullsExactTotal() public {
        _depositNFTs(QTY * CARDS_PER_PACK * 2);

        uint256 total = PRICE * QTY;
        _fundPayer(total);
        bytes[] memory signatures = _signBatch(alice, QTY, bytes32(0));

        vm.prank(payer);
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            total
        );

        assertEq(
            usdc.balanceOf(address(packMachine)),
            total,
            "machine escrowed the full price of every pack"
        );
        assertEq(usdc.balanceOf(payer), 0, "payer debited exactly the total");
        assertEq(
            packMachine.getUserInfo(alice).openNonce,
            QTY,
            "one nonce consumed per pack"
        );
    }

    function test_openPacks_deliversCardsToUserNotPayer() public {
        _depositNFTs(QTY * CARDS_PER_PACK * 2);

        uint256 total = PRICE * QTY;
        _fundPayer(total);
        bytes[] memory signatures = _signBatch(alice, QTY, bytes32(0));

        vm.prank(payer);
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            total
        );
        _fulfillAll(QTY);

        assertEq(
            assetNFT.balanceOf(alice),
            QTY * CARDS_PER_PACK,
            "every card from every pack lands on the recipient"
        );
        assertEq(assetNFT.balanceOf(payer), 0, "payer receives no cards");
    }

    function test_openPacks_leavesNoAllowanceOrBalanceBehind() public {
        _depositNFTs(QTY * CARDS_PER_PACK * 2);

        uint256 total = PRICE * QTY;
        _fundPayer(total);
        bytes[] memory signatures = _signBatch(alice, QTY, bytes32(0));

        vm.prank(payer);
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            total
        );

        assertEq(
            usdc.allowance(address(batcher), address(packMachine)),
            0,
            "no allowance survives the call"
        );
        assertEq(
            usdc.balanceOf(address(batcher)),
            0,
            "batcher holds no balance between calls"
        );
    }

    // =========================================================================
    // Refunds
    // =========================================================================

    function test_openPacks_refundsUnspentRemainderToPayer() public {
        _depositNFTs(QTY * CARDS_PER_PACK * 2);

        // The first-open discount applies to pack #0 only, so the machine consumes
        // less than the sticker total — the difference must come back to the payer.
        vm.prank(admin);
        factory.setFirstOpenDiscount(true, DISCOUNT_BPS);

        uint256 maxSpend = PRICE * QTY;
        uint256 discount = (uint256(PRICE) * DISCOUNT_BPS) / 10_000;
        _fundPayer(maxSpend);
        bytes[] memory signatures = _signBatch(alice, QTY, bytes32(0));

        vm.prank(payer);
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            maxSpend
        );

        assertEq(
            usdc.balanceOf(address(packMachine)),
            maxSpend - discount,
            "machine escrowed the discounted total"
        );
        assertEq(
            usdc.balanceOf(payer),
            discount,
            "unspent remainder refunded to the payer"
        );
        assertEq(usdc.balanceOf(address(batcher)), 0, "no dust retained");
    }

    function test_openPacks_doesNotSweepDonatedTokens() public {
        _depositNFTs(QTY * CARDS_PER_PACK * 2);

        // A stray transfer to the batcher must not be handed to the next caller.
        uint256 donation = 123e6;
        usdc.mint(address(batcher), donation);

        uint256 total = PRICE * QTY;
        _fundPayer(total);
        bytes[] memory signatures = _signBatch(alice, QTY, bytes32(0));

        vm.prank(payer);
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            total
        );

        assertEq(
            usdc.balanceOf(address(batcher)),
            donation,
            "donation untouched by the batch"
        );
        assertEq(usdc.balanceOf(payer), 0, "payer got no windfall");
    }

    function test_openPacks_capsPullByPayerAllowance() public {
        _depositNFTs(QTY * CARDS_PER_PACK * 2);

        uint256 total = PRICE * QTY;
        _fundPayer(total);

        // maxSpend far above what the payer approved — the pull must be capped,
        // so an over-stated bound can never drain more than the payer authorised.
        bytes[] memory signatures = _signBatch(alice, QTY, bytes32(0));
        vm.prank(payer);
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            type(uint256).max
        );

        assertEq(
            usdc.balanceOf(address(packMachine)),
            total,
            "machine escrowed the true total"
        );
        assertEq(usdc.balanceOf(payer), 0, "payer debited only what it approved");
    }

    // =========================================================================
    // Promo code — first open only
    // =========================================================================

    function test_openPacks_appliesCodeToFirstOpenOnly() public {
        _depositNFTs(QTY * CARDS_PER_PACK * 2);

        uint256 discount = (uint256(PRICE) * PROMO_BPS) / 10_000;
        uint256 maxSpend = PRICE * QTY;
        _fundPayer(maxSpend);
        bytes[] memory signatures = _signBatch(alice, QTY, PROMO_CODE);

        // A oncePerUser code would revert on the second open if it were passed again.
        vm.prank(payer);
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            PROMO_CODE,
            maxSpend
        );

        assertEq(
            usdc.balanceOf(address(packMachine)),
            maxSpend - discount,
            "exactly one pack discounted"
        );
        assertEq(
            usdc.balanceOf(payer),
            discount,
            "the undiscounted remainder is refunded"
        );
    }

    // =========================================================================
    // Reverts
    // =========================================================================

    function test_openPacks_revertsOnUnknownMachine() public {
        address impostor = makeAddr("impostor");
        _fundPayer(PRICE);
        bytes[] memory signatures = _signBatch(alice, 1, bytes32(0));

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackBatcher.PackBatcher__UnknownMachine.selector,
                impostor
            )
        );
        batcher.openPacks(impostor, alice, 0, signatures, bytes32(0), PRICE);
    }

    function test_openPacks_revertsOnEmptyBatch() public {
        bytes[] memory signatures = new bytes[](0);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackBatcher.PackBatcher__InvalidBatchSize.selector,
                0,
                batcher.MAX_BATCH()
            )
        );
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            PRICE
        );
    }

    function test_openPacks_revertsAboveMaxBatch() public {
        uint256 maxBatch = batcher.MAX_BATCH();
        bytes[] memory signatures = new bytes[](maxBatch + 1);

        vm.prank(payer);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackBatcher.PackBatcher__InvalidBatchSize.selector,
                maxBatch + 1,
                maxBatch
            )
        );
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            PRICE * (maxBatch + 1)
        );
    }

    function test_openPacks_revertsWhenPayerHasNothingApproved() public {
        bytes[] memory signatures = _signBatch(alice, 1, bytes32(0));

        vm.prank(payer);
        vm.expectRevert(PackBatcher.PackBatcher__NoFunds.selector);
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            PRICE
        );
    }

    /// @dev An under-funded batch must unwind entirely — no partial opens, because a
    ///      partially-opened batch is exactly the charge/deliver mismatch being fixed.
    function test_openPacks_underfundedBatchUnwindsCompletely() public {
        _depositNFTs(QTY * CARDS_PER_PACK * 2);

        uint256 short = PRICE * 2; // funds only 2 of the 4 packs
        _fundPayer(short);
        bytes[] memory signatures = _signBatch(alice, QTY, bytes32(0));

        vm.prank(payer);
        vm.expectRevert();
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            short
        );

        assertEq(
            usdc.balanceOf(address(packMachine)),
            0,
            "no pack was opened"
        );
        assertEq(usdc.balanceOf(payer), short, "payer was not debited");
        assertEq(
            packMachine.getUserInfo(alice).openNonce,
            0,
            "no nonce consumed"
        );
    }

    function test_openPacks_revertsOnOutOfOrderSignatures() public {
        _depositNFTs(QTY * CARDS_PER_PACK * 2);

        uint256 total = PRICE * QTY;
        _fundPayer(total);

        // Every signature bound to the same (current) nonce — only the first can verify.
        uint256 startNonce = packMachine.getUserInfo(alice).openNonce;
        bytes[] memory signatures = new bytes[](QTY);
        for (uint256 i; i < QTY; ++i) {
            signatures[i] = _signOpenPack(alice, startNonce, bytes32(0));
        }

        vm.prank(payer);
        vm.expectRevert();
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            total
        );

        assertEq(usdc.balanceOf(payer), total, "payer was not debited");
    }

    function test_openPacks_revertsWhenPaused() public {
        _depositNFTs(QTY * CARDS_PER_PACK * 2);

        uint256 total = PRICE * QTY;
        _fundPayer(total);
        bytes[] memory signatures = _signBatch(alice, QTY, bytes32(0));

        vm.prank(pauser);
        batcher.pause();

        vm.prank(payer);
        vm.expectRevert();
        batcher.openPacks(
            address(packMachine),
            alice,
            0,
            signatures,
            bytes32(0),
            total
        );
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function test_pause_revertsForNonPauser() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionConsumer.PermissionConsumer__Unauthorized.selector,
                alice,
                Roles.PAUSER_ROLE
            )
        );
        batcher.pause();
    }

    function test_setFactory_revertsForNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionConsumer.PermissionConsumer__Unauthorized.selector,
                alice,
                Roles.DEFAULT_ADMIN_ROLE
            )
        );
        batcher.setFactory(makeAddr("newFactory"));
    }

    function test_setFactory_rejectsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(PackBatcher.PackBatcher__ZeroAddress.selector);
        batcher.setFactory(address(0));
    }

    function test_setFactory_updatesFactory() public {
        address newFactory = makeAddr("newFactory");
        vm.prank(admin);
        batcher.setFactory(newFactory);
        assertEq(batcher.factory(), newFactory, "factory repointed");
    }

    function test_rescueERC20_recoversStrandedTokens() public {
        uint256 donation = 42e6;
        usdc.mint(address(batcher), donation);

        vm.prank(admin);
        batcher.rescueERC20(address(usdc));

        assertEq(usdc.balanceOf(admin), donation, "admin recovered the dust");
        assertEq(usdc.balanceOf(address(batcher)), 0, "batcher emptied");
    }

    function test_rescueERC20_revertsForNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PermissionConsumer.PermissionConsumer__Unauthorized.selector,
                alice,
                Roles.DEFAULT_ADMIN_ROLE
            )
        );
        batcher.rescueERC20(address(usdc));
    }

    function test_initialize_rejectsZeroFactory() public {
        PackBatcher impl = new PackBatcher();
        vm.expectRevert(PackBatcher.PackBatcher__ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(PackBatcher.initialize, (address(pm), address(0)))
        );
    }
}
