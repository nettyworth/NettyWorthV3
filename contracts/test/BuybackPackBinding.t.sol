// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackMachine} from "../PackMachine.sol";
import {PackMachineFactory} from "../PackMachineFactory.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PackRegistry} from "../PackRegistry.sol";
import {PackTierRegistry} from "../PackTierRegistry.sol";
import {BuybackPool} from "../BuybackPool.sol";
import {PromoCodeRegistry} from "../PromoCodeRegistry.sol";
import {IPromoCodeRegistry} from "../interfaces/IPromoCodeRegistry.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";
import {MockPermit2} from "../test-helpers/MockPermit2.sol";
import {MockAssetLendingPool} from "../test-helpers/MockAssetLendingPool.sol";

/// @notice Pack-bound buyback codes on the real stack: one machine, a cheap pack (0, "Core")
///         and an expensive pack (1, "Elite"), each with its own auto-applied sell-back code.
///
///         Regression for the Base exploit: a wallet opened Core 498 times and sold every
///         card back with Elite's 95% code, because buyback codes were not bound to a pack
///         and BuybackPool never checked which pack a card came from.
contract BuybackPackBindingTest is Test {
    PackMachine internal packMachine;
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
    PackRegistry internal packRegistry;
    BuybackPool internal pool;
    PromoCodeRegistry internal registry;
    PermissionManager internal pm;
    MockERC20 internal usdc;
    AssetNFT internal assetNFT;
    MockVRFCoordinatorV2Plus internal coordinator;
    MockAssetLendingPool internal appraisals;

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal forwarder = makeAddr("forwarder");
    address internal financeWallet = makeAddr("financeWallet");
    address internal ripper = makeAddr("ripper");

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

    uint256 internal constant CORE = 0;
    uint256 internal constant ELITE = 1;
    uint128 internal constant PRICE = 50e6;
    uint256 internal constant FMV = 50e6;

    bytes32 internal constant CORE_CODE = keccak256("PACKRATE:core:v1");
    bytes32 internal constant ELITE_CODE = keccak256("PACKRATE:elite:v1");
    uint16 internal constant CORE_BPS = 8500;
    uint16 internal constant ELITE_BPS = 9500;
    uint16 internal constant DEFAULT_BPS = 8000;

    uint256 internal nextRequestId = 1;

    function setUp() public {
        (operator, operatorPk) = makeAddrAndKey("operator");

        PermissionManager pmImpl = new PermissionManager();
        pm = PermissionManager(
            address(
                new ERC1967Proxy(
                    address(pmImpl),
                    abi.encodeCall(PermissionManager.initialize, (admin))
                )
            )
        );
        vm.startPrank(admin);
        pm.grantRole(pm.PACK_OPERATOR_ROLE(), operator);
        pm.grantRole(pm.PAUSER_ROLE(), pauser);
        pm.grantRole(pm.MINTER_ROLE(), operator);
        vm.stopPrank();

        usdc = new MockERC20();
        coordinator = new MockVRFCoordinatorV2Plus();
        vm.etch(PERMIT2_ADDRESS, address(new MockPermit2()).code);

        AssetNFT assetNFTImpl = new AssetNFT(forwarder);
        assetNFT = AssetNFT(
            address(
                new ERC1967Proxy(
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
                )
            )
        );
        appraisals = new MockAssetLendingPool();
        vm.prank(admin);
        assetNFT.setLendingPool(address(appraisals));

        PackVRFRouter routerImpl = new PackVRFRouter();
        vrfRouter = PackVRFRouter(
            address(
                new ERC1967Proxy(
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
                )
            )
        );

        PackMachineFactory factoryImpl = new PackMachineFactory(forwarder);
        factory = PackMachineFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl),
                    abi.encodeCall(
                        PackMachineFactory.initialize,
                        (
                            address(pm),
                            address(assetNFT),
                            address(usdc),
                            financeWallet
                        )
                    )
                )
            )
        );
        PackRegistry packRegistryImpl = new PackRegistry();
        packRegistry = PackRegistry(
            address(
                new ERC1967Proxy(
                    address(packRegistryImpl),
                    abi.encodeCall(PackRegistry.initialize, (address(pm)))
                )
            )
        );
        PackTierRegistry tierRegistryImpl = new PackTierRegistry();
        PackTierRegistry tierRegistry = PackTierRegistry(
            address(
                new ERC1967Proxy(
                    address(tierRegistryImpl),
                    abi.encodeCall(PackTierRegistry.initialize, (address(pm)))
                )
            )
        );
        vm.startPrank(admin);
        factory.setImplementation(address(new PackMachine(forwarder)));
        factory.setPackVRFRouter(address(vrfRouter));
        factory.setPackRegistry(address(packRegistry));
        packRegistry.setFactory(address(factory));
        factory.setPackTierRegistry(address(tierRegistry));
        tierRegistry.setFactory(address(factory));
        vm.stopPrank();

        packMachine = PackMachine(_createMachine());

        // Pack 1 (Elite) next to the bootstrap pack 0 (Core), same tier weights.
        uint32[6] memory weights = packRegistry
            .getPack(address(packMachine), CORE)
            .tierWeights;
        uint128[6] memory minFmv;
        uint128[6] memory maxFmv;
        for (uint256 t; t < 6; ++t) maxFmv[t] = type(uint128).max;
        vm.startPrank(operator);
        packRegistry.addPack(
            address(packMachine),
            PRICE,
            1,
            uint40(block.timestamp),
            2000,
            weights
        );
        packRegistry.setPackTierFmvBounds(
            address(packMachine),
            ELITE,
            minFmv,
            maxFmv
        );
        vm.stopPrank();

        BuybackPool poolImpl = new BuybackPool();
        pool = BuybackPool(
            address(
                new ERC1967Proxy(
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
                )
            )
        );
        vm.prank(pauser);
        packMachine.pause();
        vm.prank(operator);
        packMachine.setBuybackPool(address(pool));
        vm.prank(pauser);
        packMachine.unpause();
        vm.startPrank(operator);
        packRegistry.setPackBuybackAllocation(address(packMachine), CORE, 2000);
        pool.registerPackMachine(address(packMachine), true);
        vm.stopPrank();

        PromoCodeRegistry regImpl = new PromoCodeRegistry();
        registry = PromoCodeRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl),
                    abi.encodeCall(PromoCodeRegistry.initialize, (address(pm)))
                )
            )
        );
        vm.startPrank(admin);
        registry.setPackMachineFactory(address(factory));
        registry.setBuybackPool(address(pool));
        factory.setPromoCodeRegistry(address(registry));
        vm.stopPrank();
        vm.startPrank(operator);
        pool.setPromoCodeRegistry(address(registry));
        registry.createPackBuybackCode(
            CORE_CODE,
            CORE_BPS,
            0,
            address(packMachine),
            CORE
        );
        registry.createPackBuybackCode(
            ELITE_CODE,
            ELITE_BPS,
            0,
            address(packMachine),
            ELITE
        );
        vm.stopPrank();

        usdc.mint(address(pool), 1_000e6);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createMachine() internal returns (address machine) {
        vm.prank(operator);
        machine = factory.createPackMachine(PRICE, 1, uint40(block.timestamp));
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(machine, true);

        uint128[6] memory minFmv;
        uint128[6] memory maxFmv;
        for (uint256 t; t < 6; ++t) maxFmv[t] = type(uint128).max;
        vm.prank(operator);
        packRegistry.setPackTierFmvBounds(machine, CORE, minFmv, maxFmv);
    }

    /// @dev Mint one card and deposit it into every pack in `packIds` at tier 0.
    function _depositCard(
        uint256[] memory packIds
    ) internal returns (uint256 tokenId) {
        tokenId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](1);
        recipients[0] = operator;
        string[] memory uris = new string[](1);
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        appraisals.setAppraisalValue(tokenId, FMV);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        uint256[] memory packCounts = new uint256[](1);
        packCounts[0] = packIds.length;
        uint8[] memory tiers = new uint8[](packIds.length);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(tokenIds, packCounts, packIds, tiers, operator);
        vm.stopPrank();
    }

    function _packs(uint256 a) internal pure returns (uint256[] memory p) {
        p = new uint256[](1);
        p[0] = a;
    }

    function _packs(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = a;
        p[1] = b;
    }

    /// @dev Open `packId` as the ripper and fulfil VRF. The machine holds one card per
    ///      test, so the card won is the one just deposited.
    function _rip(uint256 packId) internal {
        uint256 nonce = packMachine.getUserInfo(ripper).openNonce;
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, ripper, packId, nonce, bytes32(0))
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            operatorPk,
            keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash))
        );

        usdc.mint(ripper, PRICE);
        vm.startPrank(ripper);
        usdc.approve(address(packMachine), PRICE);
        packMachine.openPack(ripper, packId, abi.encodePacked(r, s, v));
        vm.stopPrank();

        uint256[] memory words = new uint256[](1);
        words[0] = uint256(keccak256(abi.encodePacked(nextRequestId)));
        coordinator.fulfillRandomWords(
            address(vrfRouter),
            nextRequestId++,
            words
        );
    }

    function _approvePool() internal {
        vm.prank(ripper);
        assetNFT.setApprovalForAll(address(pool), true);
    }

    function _expectWrongPack(bytes32 codeId, uint256 packMask) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__WrongPack.selector,
                codeId,
                address(packMachine),
                packMask
            )
        );
    }

    // =========================================================================
    // The exploit
    // =========================================================================

    /// @notice A Core card sold with Elite's code reverts and leaves the code unconsumed;
    ///         the seller still gets the base rate without a code.
    function test_eliteCodeOnCoreCard_reverts() public {
        uint256 tokenId = _depositCard(_packs(CORE));
        _rip(CORE);
        assertEq(assetNFT.ownerOf(tokenId), ripper);
        _approvePool();

        _expectWrongPack(ELITE_CODE, 1 << CORE);
        vm.prank(ripper);
        pool.buyback(tokenId, ELITE_CODE);
        assertEq(
            registry.getCode(ELITE_CODE).redeemedCount,
            0,
            "code must not be consumed"
        );

        uint256 before = usdc.balanceOf(ripper);
        vm.prank(ripper);
        pool.buyback(tokenId);
        assertEq(usdc.balanceOf(ripper) - before, (FMV * DEFAULT_BPS) / 10_000);
    }

    function test_coreCodeOnCoreCard_paysCoreRate() public {
        uint256 tokenId = _depositCard(_packs(CORE));
        _rip(CORE);
        _approvePool();

        uint256 before = usdc.balanceOf(ripper);
        vm.prank(ripper);
        pool.buyback(tokenId, CORE_CODE);
        assertEq(usdc.balanceOf(ripper) - before, (FMV * CORE_BPS) / 10_000);
        assertEq(registry.getCode(CORE_CODE).redeemedCount, 1);
    }

    /// @notice A code bound to the same packId on a different machine does not apply.
    function test_codeForOtherMachine_reverts() public {
        address otherMachine = _createMachine();
        bytes32 otherCode = keccak256("PACKRATE:other:core:v1");
        vm.prank(operator);
        registry.createPackBuybackCode(otherCode, 9800, 0, otherMachine, CORE);

        uint256 tokenId = _depositCard(_packs(CORE));
        _rip(CORE);
        _approvePool();

        _expectWrongPack(otherCode, 1 << CORE);
        vm.prank(ripper);
        pool.buyback(tokenId, otherCode);
    }

    /// @notice Codes made with createCode stay unbound and apply to any card.
    function test_unboundCode_appliesToAnyCard() public {
        bytes32 boost = keccak256("BOOST98");
        vm.prank(operator);
        registry.createCode(
            boost,
            IPromoCodeRegistry.PromoKind.Buyback,
            9800,
            0,
            0,
            false,
            false,
            address(0)
        );

        uint256 tokenId = _depositCard(_packs(CORE));
        _rip(CORE);
        _approvePool();

        uint256 before = usdc.balanceOf(ripper);
        vm.prank(ripper);
        pool.buyback(tokenId, boost);
        assertEq(usdc.balanceOf(ripper) - before, (FMV * 9800) / 10_000);
    }

    // =========================================================================
    // Pack attribution at win time
    // =========================================================================

    /// @notice A card listed in both packs and won from Core is recorded as Core, so
    ///         Elite's code is refused even though the card is eligible for Elite.
    function test_rip_recordsWonPack_forMultiPackCard() public {
        uint256 tokenId = _depositCard(_packs(CORE, ELITE));
        _rip(CORE);
        _approvePool();

        (bool known, uint256 packId) = pool.getTokenPackId(tokenId);
        assertTrue(known, "the machine records the pack at win time");
        assertEq(packId, CORE);

        _expectWrongPack(ELITE_CODE, 1 << CORE);
        vm.prank(ripper);
        pool.buyback(tokenId, ELITE_CODE);

        uint256 before = usdc.balanceOf(ripper);
        vm.prank(ripper);
        pool.buyback(tokenId, CORE_CODE);
        assertEq(usdc.balanceOf(ripper) - before, (FMV * CORE_BPS) / 10_000);
    }

    /// @notice A token with no recorded pack (registered by an older machine) gets no
    ///         pack rate: its eligibility list cannot say which pack it was won from.
    ///         The seller still gets the base rate without a code.
    function test_unrecordedPack_rejectsPackBoundCode() public {
        uint256 tokenId = _depositCard(_packs(CORE));
        _rip(CORE);
        vm.prank(address(packMachine));
        pool.registerToken(tokenId, 0, address(packMachine), PRICE);
        _approvePool();

        _expectWrongPack(CORE_CODE, 0);
        vm.prank(ripper);
        pool.buyback(tokenId, CORE_CODE);

        uint256 before = usdc.balanceOf(ripper);
        vm.prank(ripper);
        pool.buyback(tokenId);
        assertEq(usdc.balanceOf(ripper) - before, (FMV * DEFAULT_BPS) / 10_000);
    }

    // =========================================================================
    // Tokens registered with a pack (5-arg registerToken): exact match
    // =========================================================================

    /// @dev Re-register `tokenId` as the machine would with the pack-aware overload.
    function _recordPack(uint256 tokenId, uint256 packId) internal {
        vm.prank(address(packMachine));
        pool.registerToken(tokenId, 0, address(packMachine), PRICE, packId);
    }

    function test_recordedPack_rejectsOtherPackCode_evenIfEligible() public {
        uint256 tokenId = _depositCard(_packs(CORE, ELITE));
        _rip(CORE);
        _recordPack(tokenId, CORE);
        _approvePool();

        (bool known, uint256 packId) = pool.getTokenPackId(tokenId);
        assertTrue(known);
        assertEq(packId, CORE);

        _expectWrongPack(ELITE_CODE, 1 << CORE);
        vm.prank(ripper);
        pool.buyback(tokenId, ELITE_CODE);

        uint256 before = usdc.balanceOf(ripper);
        vm.prank(ripper);
        pool.buyback(tokenId, CORE_CODE);
        assertEq(usdc.balanceOf(ripper) - before, (FMV * CORE_BPS) / 10_000);
    }

    /// @notice A later registration through an overload without the pack must not keep
    ///         the pack recorded for an earlier win.
    function test_legacyReRegistration_clearsRecordedPack() public {
        uint256 tokenId = _depositCard(_packs(CORE));
        _rip(CORE);
        _recordPack(tokenId, ELITE);

        vm.prank(address(packMachine));
        pool.registerToken(tokenId, 0, address(packMachine), PRICE);

        (bool known, ) = pool.getTokenPackId(tokenId);
        assertFalse(known);
    }

    function test_registerToken_revertsOnPackIdOutsideMask() public {
        vm.prank(address(packMachine));
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__InvalidPackId.selector,
                256
            )
        );
        pool.registerToken(1, 0, address(packMachine), PRICE, 256);
    }

    function test_registerToken_withPack_revertsForUnregisteredCaller() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__UnauthorizedSource.selector,
                stranger
            )
        );
        pool.registerToken(1, 0, address(packMachine), PRICE, CORE);
    }

    // =========================================================================
    // Upgrade safety
    // =========================================================================

    /// @notice packIdPlusOne must pack into the slot it shares with amountPaidPerCard, so a
    ///         TokenBuybackInfo stays two slots and records written before the upgrade read
    ///         back unchanged with packIdPlusOne == 0.
    function test_storageLayout_packIdSharesSlotWithPaidAmount() public {
        bytes32 base =
            0xcde91e075f2798ca63d14356a360b0f16575d21d6ecd1d5809e671a133dd7f00;
        uint256 tokenId = 42;
        // tokenInfo is the 5th field: assetNFT, paymentToken, financeWallet,
        // (factory, defaultBuybackBps), tokenInfo.
        bytes32 entry = keccak256(abi.encode(tokenId, uint256(base) + 4));

        vm.prank(address(packMachine));
        pool.registerToken(tokenId, 3, address(packMachine), 7e6, 9);

        uint256 slot0 = uint256(vm.load(address(pool), entry));
        uint256 slot1 = uint256(
            vm.load(address(pool), bytes32(uint256(entry) + 1))
        );
        uint256 slot2 = uint256(
            vm.load(address(pool), bytes32(uint256(entry) + 2))
        );

        assertEq(uint8(slot0), 3, "tier");
        assertEq(address(uint160(slot0 >> 8)), address(packMachine), "source");
        assertEq(uint8(slot0 >> 168), 1, "isActive");
        assertEq(uint128(slot1), 7e6, "amountPaidPerCard");
        assertEq(uint32(slot1 >> 128), 10, "packIdPlusOne");
        assertEq(slot2, 0, "struct must not grow into a third slot");
    }
}
