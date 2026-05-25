// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PackMachine} from "../PackMachine.sol";
import {PackMachineFactory} from "../PackMachineFactory.sol";
import {PackVRFRouter} from "../PackVRFRouter.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {PermissionConsumer} from "../PermissionConsumer.sol";
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";
import {MockPermit2} from "../test-helpers/MockPermit2.sol";
import {ISignatureTransfer} from "../interfaces/ISignatureTransfer.sol";

contract PackMachineTest is Test {
    PackMachine internal packMachine;
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
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
    address internal user2 = makeAddr("user2");
    address internal unauthorized = makeAddr("unauthorized");

    uint256 internal operatorPk;
    address internal operator;

    address internal constant PERMIT2_ADDRESS =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 nonce)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint128 internal constant PRICE = 10e6; // 10 USDC
    uint8 internal constant CARDS_PER_PACK = 3;
    address internal royaltyReceiver = makeAddr("royaltyReceiver");
    uint96 internal constant ROYALTY_FEE = 250;

    function setUp() public {
        // Create operator with known private key for EIP-712 signing
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

        // Mock token contracts
        usdc = new MockERC20();
        coordinator = new MockVRFCoordinatorV2Plus();

        // AssetNFT proxy
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
                    royaltyReceiver,
                    ROYALTY_FEE
                )
            )
        );
        assetNFT = AssetNFT(address(assetNFTProxy));

        // Etch MockPermit2 at canonical address
        MockPermit2 permit2Impl = new MockPermit2();
        vm.etch(PERMIT2_ADDRESS, address(permit2Impl).code);

        // PackVRFRouter proxy
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

        // PackMachine implementation + factory
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

        // Create the PackMachine clone
        vm.prank(operator);
        address cloneAddr = factory.createPackMachine(
            PRICE,
            CARDS_PER_PACK,
            uint40(block.timestamp)
        );
        packMachine = PackMachine(cloneAddr);

        // Authorize clone on VRF router
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(cloneAddr, true);

        // Disable cut-off so existing tests that exhaust the pool work correctly.
        vm.prank(operator);
        packMachine.setRetentionThreshold(0);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Deposits `count` NFTs into packMachine, all in tier 0 (Base).
    function _depositNFTs(
        uint256 count
    ) internal returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](count);
        uint256 startId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        uint8[] memory tiers = new uint8[](count); // all Base = 0
        for (uint256 i; i < count; i++) {
            recipients[i] = operator;
            uris[i] = "";
            tokenIds[i] = startId + i;
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(tokenIds, tiers, operator);
        vm.stopPrank();
    }

    /// @dev Deposits `count` NFTs into packMachine with specified tiers.
    function _depositNFTsWithTiers(
        uint256 count,
        uint8[] memory tiers
    ) internal returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](count);
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
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(tokenIds, tiers, operator);
        vm.stopPrank();
    }

    function _signOpenPack(
        address user_,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user_, nonce)
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

    function _fulfillPendingRequest(
        uint256 requestId,
        uint256 numWords
    ) internal {
        uint256[] memory words = new uint256[](numWords);
        for (uint256 i; i < numWords; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(requestId, i)));
        }
        coordinator.fulfillRandomWords(address(vrfRouter), requestId, words);
    }

    function _createSingleCardMachine() internal returns (PackMachine) {
        vm.prank(operator);
        address cloneAddr = factory.createPackMachine(
            PRICE,
            1,
            uint40(block.timestamp)
        );
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(cloneAddr, true);
        // Disable cut-off so tests that exhaust the pool work correctly.
        vm.prank(operator);
        PackMachine(cloneAddr).setRetentionThreshold(0);
        return PackMachine(cloneAddr);
    }

    function _signOpenPackFor(
        address machine,
        address user_,
        uint256 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user_, nonce)
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

    function _depositNFTsTo(
        PackMachine machine,
        uint256,
        uint256 count
    ) internal returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](count);
        uint256 startId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        uint8[] memory tiers = new uint8[](count); // all Base = 0
        for (uint256 i; i < count; i++) {
            recipients[i] = operator;
            uris[i] = "";
            tokenIds[i] = startId + i;
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(machine), true);
        machine.deposit(tokenIds, tiers, operator);
        vm.stopPrank();
    }

    /// @dev Sum of all tier pool lengths.
    function _getTotalPoolLength(
        PackMachine machine
    ) internal view returns (uint256 total) {
        for (uint8 t = 0; t < 5; t++) {
            total += machine.getTierPoolSize(t);
        }
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    function test_Initialize_FactoryStored() public view {
        assertEq(packMachine.factory(), address(factory));
    }

    function test_Initialize_PriceStored() public view {
        assertEq(packMachine.pricePerPack(), PRICE);
    }

    function test_Initialize_CardsPerPackStored() public view {
        assertEq(packMachine.cardsPerPack(), CARDS_PER_PACK);
    }

    function test_Initialize_DefaultWeights() public view {
        uint16[5] memory weights = packMachine.getTierWeights();
        assertEq(weights[0], 7500); // Base 75%
        assertEq(weights[1], 1950); // Common 19.5%
        assertEq(weights[2], 400); // Uncommon 4%
        assertEq(weights[3], 100); // Rare 1%
        assertEq(weights[4], 50); // Ultra 0.5%
    }

    function test_Initialize_RevertsOnZeroFactory() public {
        PackMachine impl = new PackMachine(forwarder);
        vm.expectRevert(PackMachine.PackMachine__ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                PackMachine.initialize,
                (
                    address(pm),
                    address(0),
                    PRICE,
                    CARDS_PER_PACK,
                    uint40(block.timestamp)
                )
            )
        );
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert();
        packMachine.initialize(
            address(pm),
            address(factory),
            PRICE,
            CARDS_PER_PACK,
            uint40(block.timestamp)
        );
    }

    // =========================================================================
    // setTierWeights
    // =========================================================================

    function test_SetTierWeights_HappyPath() public {
        uint16[5] memory newWeights = [uint16(5000), 2000, 1500, 1000, 500];
        vm.prank(operator);
        packMachine.setTierWeights(newWeights);

        uint16[5] memory stored = packMachine.getTierWeights();
        assertEq(stored[0], 5000);
        assertEq(stored[1], 2000);
        assertEq(stored[2], 1500);
        assertEq(stored[3], 1000);
        assertEq(stored[4], 500);
    }

    function test_SetTierWeights_EmitsEvent() public {
        uint16[5] memory newWeights = [uint16(5000), 2000, 1500, 1000, 500];
        vm.expectEmit(false, false, false, true, address(packMachine));
        emit TierWeightsUpdated(newWeights);
        vm.prank(operator);
        packMachine.setTierWeights(newWeights);
    }

    function test_SetTierWeights_RevertsInvalidTotal() public {
        uint16[5] memory badWeights = [uint16(5000), 2000, 1500, 1000, 100]; // sums to 9600
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__InvalidWeights.selector,
                uint256(9600)
            )
        );
        packMachine.setTierWeights(badWeights);
    }

    function test_SetTierWeights_RevertsUnauthorized() public {
        uint16[5] memory weights = [uint16(5000), 2000, 1500, 1000, 500];
        vm.prank(unauthorized);
        vm.expectRevert();
        packMachine.setTierWeights(weights);
    }

    // =========================================================================
    // deposit
    // =========================================================================

    function test_Deposit_OperatorSucceeds() public {
        _depositNFTs(3);
        assertEq(packMachine.effectivePrizePoolSize(), 3);
    }

    function test_Deposit_IncreasesPoolAndEffectiveSize() public {
        _depositNFTs(5);
        // All tokens deposited to tier 0 (Base)
        assertEq(packMachine.getTierPoolSize(0), 5);
        assertEq(packMachine.effectivePrizePoolSize(), 5);
    }

    function test_Deposit_RoutesTokensToCorrectTier() public {
        uint256 count = 5;
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        // Deposit: 2 Base, 2 Common, 1 Rare
        tiers[0] = 0;
        tiers[1] = 0;
        tiers[2] = 1;
        tiers[3] = 1;
        tiers[4] = 3;
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(ids, tiers, operator);
        vm.stopPrank();

        assertEq(packMachine.getTierPoolSize(0), 2); // Base
        assertEq(packMachine.getTierPoolSize(1), 2); // Common
        assertEq(packMachine.getTierPoolSize(2), 0); // Uncommon
        assertEq(packMachine.getTierPoolSize(3), 1); // Rare
        assertEq(packMachine.getTierPoolSize(4), 0); // Ultra
        assertEq(packMachine.effectivePrizePoolSize(), 5);
    }

    function test_Deposit_EmitsEvent() public {
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256[] memory ids = new uint256[](2);
        uint8[] memory tiers = new uint8[](2);
        ids[0] = startId;
        ids[1] = startId + 1;
        address[] memory recipients = new address[](2);
        string[] memory uris = new string[](2);
        recipients[0] = operator;
        recipients[1] = operator;
        uris[0] = "";
        uris[1] = "";
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);

        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        vm.expectEmit(true, false, false, true, address(packMachine));
        emit CardsDeposited(operator, 2);
        packMachine.deposit(ids, tiers, operator);
        vm.stopPrank();
    }

    function test_Deposit_BatchTooLargeReverts() public {
        uint256 size = 51;
        uint256[] memory ids = new uint256[](size);
        uint8[] memory tiers = new uint8[](size);
        for (uint256 i; i < size; i++) {
            ids[i] = i + 1;
        }
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__BatchTooLarge.selector,
                size,
                50
            )
        );
        packMachine.deposit(ids, tiers, operator);
    }

    function test_Deposit_ArrayLengthMismatchReverts() public {
        uint256[] memory ids = new uint256[](3);
        uint8[] memory tiers = new uint8[](2); // mismatched
        vm.prank(operator);
        vm.expectRevert(PackMachine.PackMachine__ArrayLengthMismatch.selector);
        packMachine.deposit(ids, tiers, operator);
    }

    function test_Deposit_InvalidTierReverts() public {
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256[] memory ids = new uint256[](1);
        uint8[] memory tiers = new uint8[](1);
        ids[0] = startId;
        tiers[0] = 5; // invalid (max is 4)
        address[] memory recipients = new address[](1);
        string[] memory uris = new string[](1);
        recipients[0] = operator;
        uris[0] = "";
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__InvalidTier.selector,
                uint8(5)
            )
        );
        packMachine.deposit(ids, tiers, operator);
        vm.stopPrank();
    }

    function test_Deposit_UnauthorizedReverts() public {
        uint256[] memory ids = new uint256[](1);
        uint8[] memory tiers = new uint8[](1);
        ids[0] = 1;
        vm.prank(unauthorized);
        vm.expectRevert();
        packMachine.deposit(ids, tiers, unauthorized);
    }

    function test_Deposit_EmptyArrayNoOp() public {
        uint256[] memory ids = new uint256[](0);
        uint8[] memory tiers = new uint8[](0);
        vm.prank(operator);
        packMachine.deposit(ids, tiers, operator);
        assertEq(packMachine.effectivePrizePoolSize(), 0);
    }

    // =========================================================================
    // openPack
    // =========================================================================

    function test_OpenPack_TransfersUSDCToFinanceWallet() public {
        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);

        assertEq(usdc.balanceOf(financeWallet), PRICE);
        assertEq(usdc.balanceOf(user), 0);
    }

    function test_OpenPack_DecrementsEffectivePoolSize() public {
        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);

        // effectivePrizePoolSize decremented at request time
        assertEq(packMachine.effectivePrizePoolSize(), 0);
    }

    function test_OpenPack_IncrementsNonce() public {
        _depositNFTs(CARDS_PER_PACK * 2);
        usdc.mint(user, PRICE * 2);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE * 2);

        assertEq(packMachine.openNonce(user), 0);
        bytes memory sig0 = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig0);
        assertEq(packMachine.openNonce(user), 1);
    }

    function test_OpenPack_RevertsWhenNotStarted() public {
        // Deploy a machine with future startTime
        vm.prank(operator);
        address futureClone = factory.createPackMachine(
            PRICE,
            CARDS_PER_PACK,
            uint40(block.timestamp + 1000)
        );
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(futureClone, true);

        PackMachine futureMachine = PackMachine(futureClone);
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256[] memory ids = new uint256[](CARDS_PER_PACK);
        uint8[] memory tiers = new uint8[](CARDS_PER_PACK);
        address[] memory recipients = new address[](CARDS_PER_PACK);
        string[] memory uris = new string[](CARDS_PER_PACK);
        for (uint256 i; i < CARDS_PER_PACK; i++) {
            ids[i] = startId + i;
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(futureClone, true);
        futureMachine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(futureClone, PRICE);

        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user, uint256(0))
        );
        bytes32 domainSep = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                futureClone
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSep, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vm.expectRevert(PackMachine.PackMachine__NotStarted.selector);
        futureMachine.openPack(user, sig);
    }

    function test_OpenPack_RevertsWhenFinished() public {
        _depositNFTs(CARDS_PER_PACK);
        vm.prank(operator);
        packMachine.stop();
        // stop() also pauses; unpause so whenNotPaused passes and Finished is checked
        vm.prank(pauser);
        packMachine.unpause();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);
        bytes memory sig = _signOpenPack(user, 0);

        vm.prank(user);
        vm.expectRevert(PackMachine.PackMachine__Finished.selector);
        packMachine.openPack(user, sig);
    }

    function test_OpenPack_RevertsWhenPoolInsufficient() public {
        // Pool has fewer cards than cardsPerPack
        _depositNFTs(CARDS_PER_PACK - 1);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);
        bytes memory sig = _signOpenPack(user, 0);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__InsufficientPool.selector,
                CARDS_PER_PACK - 1,
                CARDS_PER_PACK
            )
        );
        packMachine.openPack(user, sig);
    }

    function test_OpenPack_RevertsWhenPaused() public {
        _depositNFTs(CARDS_PER_PACK);
        vm.prank(pauser);
        packMachine.pause();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);
        bytes memory sig = _signOpenPack(user, 0);

        vm.prank(user);
        vm.expectRevert();
        packMachine.openPack(user, sig);
    }

    function test_OpenPack_RevertsOnInvalidSignature() public {
        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        // Sign with unauthorized key
        (, uint256 badPk) = makeAddrAndKey("badSigner");
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user, uint256(0))
        );
        bytes32 domainSep = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                address(packMachine)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSep, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badPk, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vm.expectRevert(PackMachine.PackMachine__InvalidSignature.selector);
        packMachine.openPack(user, badSig);
    }

    function test_OpenPack_RevertsOnReplayedNonce() public {
        _depositNFTs(CARDS_PER_PACK * 2);
        usdc.mint(user, PRICE * 2);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE * 2);

        bytes memory sig0 = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig0);

        // Replaying same nonce 0 should fail (nonce is now 1)
        vm.prank(user);
        vm.expectRevert(PackMachine.PackMachine__InvalidSignature.selector);
        packMachine.openPack(user, sig0);
    }

    // =========================================================================
    // openPackWithPermit2
    // =========================================================================

    function test_OpenPackWithPermit2_HappyPath() public {
        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        // User approves Permit2 canonical address
        vm.prank(user);
        usdc.approve(PERMIT2_ADDRESS, type(uint256).max);

        bytes memory playSig = _signOpenPack(user, 0);
        // Permit2 signature is not verified by mock — pass empty bytes
        vm.prank(user);
        packMachine.openPackWithPermit2(
            user,
            0,
            block.timestamp + 3600,
            "",
            playSig
        );

        assertEq(usdc.balanceOf(financeWallet), PRICE);
        assertEq(packMachine.effectivePrizePoolSize(), 0);
    }

    function test_OpenPackWithPermit2_PullsUSDCViaPermit2() public {
        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(PERMIT2_ADDRESS, type(uint256).max);

        bytes memory playSig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPackWithPermit2(
            user,
            0,
            block.timestamp + 3600,
            "",
            playSig
        );

        assertEq(usdc.balanceOf(user), 0);
        assertEq(usdc.balanceOf(financeWallet), PRICE);
    }

    function test_OpenPackWithPermit2_RevertsOnInvalidPlaySignature() public {
        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(PERMIT2_ADDRESS, type(uint256).max);

        (, uint256 badPk) = makeAddrAndKey("badSigner");
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, user, uint256(0))
        );
        bytes32 domainSep = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                address(packMachine)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSep, structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badPk, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vm.expectRevert(PackMachine.PackMachine__InvalidSignature.selector);
        packMachine.openPackWithPermit2(
            user,
            0,
            block.timestamp + 3600,
            "",
            badSig
        );
    }

    // =========================================================================
    // fulfillRandomness
    // =========================================================================

    function test_FulfillRandomness_TransfersCardsToUser() public {
        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);

        uint256 requestId = 1; // coordinator returns 1 for first request
        _fulfillPendingRequest(requestId, CARDS_PER_PACK);

        // User should own all minted NFTs
        assertEq(assetNFT.balanceOf(user), CARDS_PER_PACK);
    }

    function test_FulfillRandomness_EmitsCardWonEvents() public {
        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);

        uint256 requestId = 1;
        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        for (uint256 i; i < CARDS_PER_PACK; i++) {
            words[i] = i; // deterministic indices
        }

        // Expect CardWon events (one per card)
        for (uint256 i; i < CARDS_PER_PACK; i++) {
            vm.expectEmit(true, false, true, false, address(packMachine));
            emit CardWon(user, 0, requestId); // tokenId unknown, check user + requestId
        }
        coordinator.fulfillRandomWords(address(vrfRouter), requestId, words);
    }

    function test_FulfillRandomness_EmitsPackOpenedEvent() public {
        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);

        uint256 requestId = 1;
        vm.expectEmit(true, true, false, true, address(packMachine));
        emit PackOpened(user, requestId, PRICE);
        _fulfillPendingRequest(requestId, CARDS_PER_PACK);
    }

    function test_FulfillRandomness_PoolShrinks() public {
        _depositNFTs(CARDS_PER_PACK * 2);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);
        _fulfillPendingRequest(1, CARDS_PER_PACK);

        // Pool should shrink from CARDS_PER_PACK*2 to CARDS_PER_PACK after fulfillment
        assertEq(_getTotalPoolLength(packMachine), CARDS_PER_PACK);
    }

    function test_FulfillRandomness_OnlyVRFRouterCanCall() public {
        _depositNFTs(CARDS_PER_PACK);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);

        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__OnlyVRFRouter.selector,
                unauthorized
            )
        );
        packMachine.fulfillRandomness(1, words);
    }

    function test_FulfillRandomness_MultipleCardsDistributed() public {
        uint256 poolSize = 10;
        _depositNFTs(poolSize);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);
        _fulfillPendingRequest(1, CARDS_PER_PACK);

        assertEq(assetNFT.balanceOf(user), CARDS_PER_PACK);
        assertEq(_getTotalPoolLength(packMachine), poolSize - CARDS_PER_PACK);
    }

    function test_FulfillRandomness_OnlyTierWithTokensSelected() public {
        // Only deposit into Rare tier (3) — all cards must come from that tier
        uint256 count = CARDS_PER_PACK;
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            tiers[i] = 3; // Rare
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);
        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);
        _fulfillPendingRequest(1, CARDS_PER_PACK);

        // All cards should have been drawn from Rare tier
        assertEq(assetNFT.balanceOf(user), CARDS_PER_PACK);
        assertEq(packMachine.getTierPoolSize(3), 0);
        // Other tiers remain empty
        assertEq(packMachine.getTierPoolSize(0), 0);
    }

    // =========================================================================
    // withdrawCards
    // =========================================================================

    function test_WithdrawCards_HappyPath() public {
        uint256[] memory ids = _depositNFTs(5);
        vm.prank(pauser);
        packMachine.pause();

        uint256[] memory toWithdraw = new uint256[](3);
        toWithdraw[0] = ids[0];
        toWithdraw[1] = ids[1];
        toWithdraw[2] = ids[2];

        vm.prank(operator);
        packMachine.withdrawCards(toWithdraw);

        assertEq(packMachine.effectivePrizePoolSize(), 2);
        assertEq(assetNFT.balanceOf(operator), 3);
    }

    function test_WithdrawCards_EmitsEvent() public {
        uint256[] memory ids = _depositNFTs(5);
        vm.prank(pauser);
        packMachine.pause();

        uint256[] memory toWithdraw = new uint256[](3);
        toWithdraw[0] = ids[0];
        toWithdraw[1] = ids[1];
        toWithdraw[2] = ids[2];

        vm.expectEmit(true, false, false, true, address(packMachine));
        emit CardsWithdrawn(operator, 3);
        vm.prank(operator);
        packMachine.withdrawCards(toWithdraw);
    }

    function test_WithdrawCards_RevertsIfNotPaused() public {
        uint256[] memory ids = _depositNFTs(5);

        uint256[] memory toWithdraw = new uint256[](1);
        toWithdraw[0] = ids[0];

        vm.prank(operator);
        vm.expectRevert(PackMachine.PackMachine__NotPaused.selector);
        packMachine.withdrawCards(toWithdraw);
    }

    function test_WithdrawCards_RevertsIfQuantityExceedsPool() public {
        _depositNFTs(3);
        vm.prank(pauser);
        packMachine.pause();

        // 10 token IDs — InsufficientPool fires before individual lookups
        uint256[] memory toWithdraw = new uint256[](10);
        for (uint256 i; i < 10; i++) {
            toWithdraw[i] = i + 1;
        }

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__InsufficientPool.selector,
                3,
                10
            )
        );
        packMachine.withdrawCards(toWithdraw);
    }

    function test_WithdrawCards_RevertsIfTokenNotInPool() public {
        uint256[] memory ids = _depositNFTs(3);
        vm.prank(pauser);
        packMachine.pause();

        uint256[] memory toWithdraw = new uint256[](1);
        toWithdraw[0] = ids[0] + 9999; // nonexistent token ID

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__TokenNotInPool.selector,
                toWithdraw[0]
            )
        );
        packMachine.withdrawCards(toWithdraw);
    }

    function test_WithdrawCards_UnauthorizedReverts() public {
        uint256[] memory ids = _depositNFTs(5);
        vm.prank(pauser);
        packMachine.pause();

        uint256[] memory toWithdraw = new uint256[](1);
        toWithdraw[0] = ids[0];

        vm.prank(unauthorized);
        vm.expectRevert();
        packMachine.withdrawCards(toWithdraw);
    }

    function test_WithdrawCards_AcrossMultipleTiers() public {
        uint256 count = 4;
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        // 2 Base, 1 Common, 1 Rare
        tiers[0] = 0;
        tiers[1] = 0;
        tiers[2] = 1;
        tiers[3] = 3;
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(ids, tiers, operator);
        vm.stopPrank();

        vm.prank(pauser);
        packMachine.pause();

        // Withdraw one Base and the Rare
        uint256[] memory toWithdraw = new uint256[](2);
        toWithdraw[0] = ids[0]; // Base
        toWithdraw[1] = ids[3]; // Rare

        vm.prank(operator);
        packMachine.withdrawCards(toWithdraw);

        assertEq(packMachine.getTierPoolSize(0), 1); // 1 Base remaining
        assertEq(packMachine.getTierPoolSize(1), 1); // Common untouched
        assertEq(packMachine.getTierPoolSize(3), 0); // Rare withdrawn
        assertEq(packMachine.effectivePrizePoolSize(), 2);
    }

    // =========================================================================
    // setPrice
    // =========================================================================

    function test_SetPrice_OperatorSucceeds() public {
        vm.prank(pauser);
        packMachine.pause();

        vm.prank(operator);
        packMachine.setPrice(20e6);

        assertEq(packMachine.pricePerPack(), 20e6);
    }

    function test_SetPrice_EmitsEvent() public {
        vm.prank(pauser);
        packMachine.pause();

        vm.expectEmit(false, false, false, true, address(packMachine));
        emit PriceUpdated(PRICE, 20e6);
        vm.prank(operator);
        packMachine.setPrice(20e6);
    }

    function test_SetPrice_RevertsIfNotPaused() public {
        vm.prank(operator);
        vm.expectRevert(PackMachine.PackMachine__NotPaused.selector);
        packMachine.setPrice(20e6);
    }

    function test_SetPrice_UnauthorizedReverts() public {
        vm.prank(pauser);
        packMachine.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        packMachine.setPrice(20e6);
    }

    // =========================================================================
    // pause / unpause
    // =========================================================================

    function test_Pause_PauserSucceeds() public {
        vm.prank(pauser);
        packMachine.pause();
        assertTrue(packMachine.paused());
    }

    function test_Pause_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        packMachine.pause();
    }

    function test_Unpause_PauserSucceeds() public {
        vm.startPrank(pauser);
        packMachine.pause();
        packMachine.unpause();
        vm.stopPrank();
        assertFalse(packMachine.paused());
    }

    function test_Unpause_UnauthorizedReverts() public {
        vm.prank(pauser);
        packMachine.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        packMachine.unpause();
    }

    // =========================================================================
    // stop
    // =========================================================================

    function test_Stop_SetsFinished() public {
        _depositNFTs(CARDS_PER_PACK);
        vm.prank(operator);
        packMachine.stop();
        // stop() also pauses; unpause so whenNotPaused passes and Finished is checked
        vm.prank(pauser);
        packMachine.unpause();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);
        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        vm.expectRevert(PackMachine.PackMachine__Finished.selector);
        packMachine.openPack(user, sig);
    }

    function test_Stop_Pauses() public {
        vm.prank(operator);
        packMachine.stop();
        assertTrue(packMachine.paused());
    }

    function test_Stop_EmitsEvent() public {
        vm.expectEmit(false, false, false, false, address(packMachine));
        emit PackMachineStopped();
        vm.prank(operator);
        packMachine.stop();
    }

    function test_Stop_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        packMachine.stop();
    }

    // =========================================================================
    // rescueERC20
    // =========================================================================

    function test_RescueERC20_AdminSucceeds() public {
        usdc.mint(address(packMachine), 100e6);
        vm.prank(admin);
        packMachine.rescueERC20(address(usdc));
        assertEq(usdc.balanceOf(admin), 100e6);
    }

    function test_RescueERC20_TransfersFullBalance() public {
        usdc.mint(address(packMachine), 55e6);
        vm.prank(admin);
        packMachine.rescueERC20(address(usdc));
        assertEq(usdc.balanceOf(address(packMachine)), 0);
    }

    function test_RescueERC20_UnauthorizedReverts() public {
        usdc.mint(address(packMachine), 1e6);
        vm.prank(unauthorized);
        vm.expectRevert();
        packMachine.rescueERC20(address(usdc));
    }

    // =========================================================================
    // resetEffectivePrizePoolSize
    // =========================================================================

    function test_ResetEffectivePrizePoolSize_ReconcilesProperly() public {
        _depositNFTs(5);
        vm.prank(pauser);
        packMachine.pause();
        vm.prank(operator);
        packMachine.resetEffectivePrizePoolSize();
        assertEq(
            packMachine.effectivePrizePoolSize(),
            _getTotalPoolLength(packMachine)
        );
    }

    function test_ResetEffectivePrizePoolSize_UnauthorizedReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        packMachine.resetEffectivePrizePoolSize();
    }

    // =========================================================================
    // getTierPool / getTierPoolSize view guards
    // =========================================================================

    function test_GetTierPoolSize_InvalidTierReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__InvalidTier.selector,
                uint8(5)
            )
        );
        packMachine.getTierPoolSize(5);
    }

    function test_GetTierPool_InvalidTierReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__InvalidTier.selector,
                uint8(5)
            )
        );
        packMachine.getTierPool(5);
    }

    function test_GetTierPool_ReturnsCorrectTokens() public {
        uint256[] memory ids = _depositNFTs(3);
        uint256[] memory pool = packMachine.getTierPool(0);
        assertEq(pool.length, 3);
        // All three IDs should be present (order may vary)
        bool[3] memory found;
        for (uint256 i; i < pool.length; i++) {
            for (uint256 j; j < ids.length; j++) {
                if (pool[i] == ids[j]) found[j] = true;
            }
        }
        assertTrue(found[0] && found[1] && found[2]);
    }

    // =========================================================================
    // Nonce behavior
    // =========================================================================

    function test_OpenNonce_IndependentPerUser() public {
        _depositNFTs(CARDS_PER_PACK * 2);
        // Give both users USDC
        usdc.mint(user, PRICE);
        usdc.mint(user2, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);
        vm.prank(user2);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig1 = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig1);

        // user nonce advanced; user2 nonce still 0
        assertEq(packMachine.openNonce(user), 1);
        assertEq(packMachine.openNonce(user2), 0);
    }

    // =========================================================================
    // Full integration flow
    // =========================================================================

    function test_FullFlow_OpenPackAndFulfill() public {
        uint256 poolSize = 9;
        _depositNFTs(poolSize);

        usdc.mint(user, PRICE * 3);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE * 3);

        // Open 3 packs (3 cards each = all 9 NFTs)
        for (uint256 i; i < 3; i++) {
            bytes memory sig = _signOpenPack(user, i);
            vm.prank(user);
            packMachine.openPack(user, sig);
            _fulfillPendingRequest(i + 1, CARDS_PER_PACK);
        }

        assertEq(assetNFT.balanceOf(user), poolSize);
        assertEq(usdc.balanceOf(financeWallet), PRICE * 3);
        assertEq(_getTotalPoolLength(packMachine), 0);
    }

    function test_FullFlow_MixedTiers() public {
        // Deposit 3 Base, 3 Common, 3 Rare — open 3 packs
        uint256 count = 9;
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < 3; i++) {
            ids[i] = startId + i;
            tiers[i] = 0; // Base
            ids[i + 3] = startId + i + 3;
            tiers[i + 3] = 1; // Common
            ids[i + 6] = startId + i + 6;
            tiers[i + 6] = 3; // Rare
            recipients[i] = operator;
            recipients[i + 3] = operator;
            recipients[i + 6] = operator;
            uris[i] = "";
            uris[i + 3] = "";
            uris[i + 6] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(ids, tiers, operator);
        vm.stopPrank();

        assertEq(packMachine.effectivePrizePoolSize(), 9);

        usdc.mint(user, PRICE * 3);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE * 3);

        for (uint256 i; i < 3; i++) {
            bytes memory sig = _signOpenPack(user, i);
            vm.prank(user);
            packMachine.openPack(user, sig);
            _fulfillPendingRequest(i + 1, CARDS_PER_PACK);
        }

        assertEq(assetNFT.balanceOf(user), 9);
        assertEq(_getTotalPoolLength(packMachine), 0);
    }

    // =========================================================================
    // Prize pool with single-card packs (cardsPerPack = 1)
    // =========================================================================

    function test_SingleCard_PoolHas9AfterOnePlay() public {
        PackMachine machine = _createSingleCardMachine();
        _depositNFTsTo(machine, 100, 10); // token IDs 100-109

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(machine), PRICE);

        bytes memory sig = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig);

        // effectivePrizePoolSize decrements at request time (before VRF)
        assertEq(machine.effectivePrizePoolSize(), 9);

        // After VRF fulfillment the actual pool array also shrinks
        _fulfillPendingRequest(1, 1);
        assertEq(_getTotalPoolLength(machine), 9);
        assertEq(assetNFT.balanceOf(user), 1);
    }

    function test_SingleCard_SequentialPlaysDecrementPool() public {
        PackMachine machine = _createSingleCardMachine();
        _depositNFTsTo(machine, 100, 10);

        usdc.mint(user, PRICE * 3);
        vm.prank(user);
        usdc.approve(address(machine), PRICE * 3);

        for (uint256 i; i < 3; i++) {
            bytes memory sig = _signOpenPackFor(address(machine), user, i);
            vm.prank(user);
            machine.openPack(user, sig);
            _fulfillPendingRequest(i + 1, 1);
        }

        assertEq(_getTotalPoolLength(machine), 7);
        assertEq(machine.effectivePrizePoolSize(), 7);
        assertEq(assetNFT.balanceOf(user), 3);
    }

    function test_SingleCard_ExhaustEntirePool() public {
        PackMachine machine = _createSingleCardMachine();
        _depositNFTsTo(machine, 100, 10);

        usdc.mint(user, PRICE * 10);
        vm.prank(user);
        usdc.approve(address(machine), PRICE * 10);

        for (uint256 i; i < 10; i++) {
            bytes memory sig = _signOpenPackFor(address(machine), user, i);
            vm.prank(user);
            machine.openPack(user, sig);
            _fulfillPendingRequest(i + 1, 1);
        }

        assertEq(_getTotalPoolLength(machine), 0);
        assertEq(machine.effectivePrizePoolSize(), 0);
        assertEq(assetNFT.balanceOf(user), 10);
    }

    function test_SingleCard_RevertsOnEmptyPool() public {
        PackMachine machine = _createSingleCardMachine();
        _depositNFTsTo(machine, 100, 1);

        usdc.mint(user, PRICE * 2);
        vm.prank(user);
        usdc.approve(address(machine), PRICE * 2);

        // First play exhausts the pool
        bytes memory sig1 = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig1);
        _fulfillPendingRequest(1, 1);

        // Second play reverts — pool empty (0 cards, needs 1)
        bytes memory sig2 = _signOpenPackFor(address(machine), user, 1);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                PackMachine.PackMachine__InsufficientPool.selector,
                0,
                1
            )
        );
        machine.openPack(user, sig2);
    }

    // =========================================================================
    // Tier selection — deterministic random word crafting
    //
    // The algorithm uses the upper 128 bits of each random word to pick a tier:
    //   tierRand = (word >> 128) % totalActiveWeight
    // With default weights [7500, 1950, 400, 100, 50] (sum = 10000):
    //   tierRand in [0,    7500) → Base     (tier 0)
    //   tierRand in [7500, 9450) → Common   (tier 1)
    //   tierRand in [9450, 9850) → Uncommon (tier 2)
    //   tierRand in [9850, 9950) → Rare     (tier 3)
    //   tierRand in [9950,10000) → Ultra    (tier 4)
    //
    // The lower 128 bits pick the index within the selected tier pool.
    // We craft random words so that (word >> 128) % 10000 == targetTierRand,
    // and uint128(word) % poolSize == 0 (always picks the first slot).
    // =========================================================================

    /// @dev Returns a random word whose upper 128 bits produce `tierRand % 10000 == targetTierRand`
    ///      and whose lower 128 bits produce `index % poolSize == 0`.
    function _craftWord(
        uint256 targetTierRand,
        uint256 poolSize
    ) private pure returns (uint256) {
        // Upper 128 bits: we need (upper % 10000) == targetTierRand.
        // Simplest: set upper = targetTierRand (already < 10000 < 2^128).
        uint256 upper = targetTierRand;
        // Lower 128 bits: we need (lower % poolSize) == 0. Use 0.
        uint256 lower = 0;
        // Combine: word = (upper << 128) | lower
        return (upper << 128) | lower;
    }

    function test_TierSelection_BaseCard() public {
        // Deposit exactly 1 card per tier (5 total). cardsPerPack = 3.
        // We'll use a single-card machine to isolate one draw per test.
        PackMachine machine = _createSingleCardMachine();
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 5;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        // Deposit one card into each tier
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            tiers[i] = uint8(i);
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(machine), true);
        machine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(machine), PRICE);
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(address(machine), true);

        bytes memory sig = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig);

        // tierRand = 0 → Base (tier 0)
        uint256[] memory words = new uint256[](1);
        words[0] = _craftWord(0, 1); // tierRand=0 → Base; poolSize=1 → index=0
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        // User receives the Base card (ids[0])
        assertEq(assetNFT.ownerOf(ids[0]), user, "Base card not received");
        assertEq(machine.getTierPoolSize(0), 0, "Base pool not empty");
        // Other tiers untouched
        assertEq(machine.getTierPoolSize(1), 1);
        assertEq(machine.getTierPoolSize(4), 1);
    }

    function test_TierSelection_CommonCard() public {
        PackMachine machine = _createSingleCardMachine();
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 5;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            tiers[i] = uint8(i);
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(machine), true);
        machine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(machine), PRICE);
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(address(machine), true);

        bytes memory sig = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig);

        // tierRand = 7500 → Common (cumulative 7500+1950=9450; 7500 < 9450)
        uint256[] memory words = new uint256[](1);
        words[0] = _craftWord(7500, 1); // tierRand=7500 → Common
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        assertEq(assetNFT.ownerOf(ids[1]), user, "Common card not received");
        assertEq(machine.getTierPoolSize(1), 0, "Common pool not empty");
    }

    function test_TierSelection_UncommonCard() public {
        PackMachine machine = _createSingleCardMachine();
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 5;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            tiers[i] = uint8(i);
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(machine), true);
        machine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(machine), PRICE);
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(address(machine), true);

        bytes memory sig = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig);

        // tierRand = 9450 → Uncommon (cumulative 7500+1950+400=9850; 9450 < 9850)
        uint256[] memory words = new uint256[](1);
        words[0] = _craftWord(9450, 1); // tierRand=9450 → Uncommon
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        assertEq(assetNFT.ownerOf(ids[2]), user, "Uncommon card not received");
        assertEq(machine.getTierPoolSize(2), 0, "Uncommon pool not empty");
    }

    function test_TierSelection_RareCard() public {
        PackMachine machine = _createSingleCardMachine();
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 5;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            tiers[i] = uint8(i);
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(machine), true);
        machine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(machine), PRICE);
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(address(machine), true);

        bytes memory sig = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig);

        // tierRand = 9850 → Rare (cumulative 7500+1950+400+100=9950; 9850 < 9950)
        uint256[] memory words = new uint256[](1);
        words[0] = _craftWord(9850, 1); // tierRand=9850 → Rare
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        assertEq(assetNFT.ownerOf(ids[3]), user, "Rare card not received");
        assertEq(machine.getTierPoolSize(3), 0, "Rare pool not empty");
    }

    function test_TierSelection_UltraCard() public {
        PackMachine machine = _createSingleCardMachine();
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 5;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            tiers[i] = uint8(i);
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(machine), true);
        machine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(machine), PRICE);
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(address(machine), true);

        bytes memory sig = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig);

        // tierRand = 9950 → Ultra (cumulative sum = 10000; 9950 < 10000)
        uint256[] memory words = new uint256[](1);
        words[0] = _craftWord(9950, 1); // tierRand=9950 → Ultra
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        assertEq(assetNFT.ownerOf(ids[4]), user, "Ultra card not received");
        assertEq(machine.getTierPoolSize(4), 0, "Ultra pool not empty");
    }

    function test_TierSelection_BoundaryBase_JustBelowCommon() public {
        // tierRand = 7499 is the last value that hits Base
        PackMachine machine = _createSingleCardMachine();
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 2;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        ids[0] = startId;
        tiers[0] = 0; // Base
        ids[1] = startId + 1;
        tiers[1] = 1; // Common
        recipients[0] = operator;
        recipients[1] = operator;
        uris[0] = "";
        uris[1] = "";
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(machine), true);
        machine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(machine), PRICE);
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(address(machine), true);

        bytes memory sig = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig);

        uint256[] memory words = new uint256[](1);
        words[0] = _craftWord(7499, 1); // last Base value
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        assertEq(
            assetNFT.ownerOf(ids[0]),
            user,
            "Should be Base at boundary 7499"
        );
    }

    function test_TierSelection_BoundaryCommon_FirstValue() public {
        // tierRand = 7500 is the first value that hits Common
        PackMachine machine = _createSingleCardMachine();
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 2;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        ids[0] = startId;
        tiers[0] = 0; // Base
        ids[1] = startId + 1;
        tiers[1] = 1; // Common
        recipients[0] = operator;
        recipients[1] = operator;
        uris[0] = "";
        uris[1] = "";
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(machine), true);
        machine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(machine), PRICE);
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(address(machine), true);

        bytes memory sig = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig);

        uint256[] memory words = new uint256[](1);
        words[0] = _craftWord(7500, 1); // first Common value
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        assertEq(
            assetNFT.ownerOf(ids[1]),
            user,
            "Should be Common at boundary 7500"
        );
    }

    function test_TierSelection_EmptyTierSkippedRedistributes() public {
        // Only Base and Ultra tokens exist; Common/Uncommon/Rare are empty.
        // A tierRand that would hit Common (7500) must fall through to the next populated tier.
        // Active weights: Base=7500, Ultra=50 → totalActive=7550
        // tierRand = 7500 % 7550 = 7500 → cumulative: Base=7500 → 7500 >= 7500, so Common next,
        // but Common is empty (activeWeights[1]=0), then Uncommon=0, Rare=0,
        // cumulative after Ultra=7550 → 7500 < 7550 → Ultra wins.
        PackMachine machine = _createSingleCardMachine();
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 2;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        ids[0] = startId;
        tiers[0] = 0; // Base
        ids[1] = startId + 1;
        tiers[1] = 4; // Ultra
        recipients[0] = operator;
        recipients[1] = operator;
        uris[0] = "";
        uris[1] = "";
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(machine), true);
        machine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(machine), PRICE);
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(address(machine), true);

        bytes memory sig = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig);

        // totalActive = 7500+50 = 7550
        // tierRand = 7500 % 7550 = 7500
        // Cumulative walk: Base=7500 → 7500 >= 7500 (not <), Common=0, Uncommon=0, Rare=0, Ultra=7550 → 7500 < 7550 → Ultra
        uint256[] memory words = new uint256[](1);
        words[0] = _craftWord(7500, 1);
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        assertEq(
            assetNFT.ownerOf(ids[1]),
            user,
            "Ultra should win when Common/Uncommon/Rare empty"
        );
    }

    function test_TierSelection_IndexSelectionWithinTier() public {
        // Deposit 3 Base cards. Verify the lower 128 bits pick the correct index.
        PackMachine machine = _createSingleCardMachine();
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 3;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            tiers[i] = 0; // all Base
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(machine), true);
        machine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(machine), PRICE);
        vm.prank(operator);
        vrfRouter.setAuthorizedPackMachine(address(machine), true);

        bytes memory sig = _signOpenPackFor(address(machine), user, 0);
        vm.prank(user);
        machine.openPack(user, sig);

        // tierRand = 0 → Base. Lower bits = 2 → index = 2 % 3 = 2 → ids[2].
        uint256 upper = 0; // → tierRand = 0 → Base
        uint256 lower = 2; // → index = 2 % 3 = 2
        uint256[] memory words = new uint256[](1);
        words[0] = (upper << 128) | lower;
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        // ids[2] was at index 2 in the Base pool
        assertEq(
            assetNFT.ownerOf(ids[2]),
            user,
            "Should pick index 2 from Base pool"
        );
    }

    function test_TierSelection_TwoDifferentTiersInOnePack() public {
        // cardsPerPack = 3: first word → Base, second word → Rare, third word → Base
        // Deposit: 2 Base, 1 Rare
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 3;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        ids[0] = startId;
        tiers[0] = 0; // Base
        ids[1] = startId + 1;
        tiers[1] = 0; // Base
        ids[2] = startId + 2;
        tiers[2] = 3; // Rare
        recipients[0] = operator;
        recipients[1] = operator;
        recipients[2] = operator;
        uris[0] = "";
        uris[1] = "";
        uris[2] = "";
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);

        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        words[0] = _craftWord(0, 2); // tierRand=0    → Base (2 in pool), index=0
        words[1] = _craftWord(9850, 1); // tierRand=9850 → Rare (1 in pool), index=0
        words[2] = _craftWord(0, 1); // tierRand=0    → Base (1 remaining), index=0
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        assertEq(assetNFT.balanceOf(user), 3);
        assertEq(
            packMachine.getTierPoolSize(0),
            0,
            "Base pool should be empty"
        );
        assertEq(
            packMachine.getTierPoolSize(3),
            0,
            "Rare pool should be empty"
        );
    }

    function test_TierSelection_CustomWeights_AllGoToSingleTier() public {
        // Set all weight to Rare (tier 3). Every draw must be Rare.
        vm.prank(operator);
        uint16[5] memory weights = [uint16(0), 0, 0, 10000, 0];
        packMachine.setTierWeights(weights);

        uint256 startId = assetNFT.totalSupply() + 1;
        uint256 count = 3;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            tiers[i] = 3; // all Rare
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(ids, tiers, operator);
        vm.stopPrank();

        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);

        // Any tierRand value will land on Rare since totalActive = 10000 = Rare weight
        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        words[0] = _craftWord(0, 3); // → Rare, index=0
        words[1] = _craftWord(5000, 2); // → Rare, index=0
        words[2] = _craftWord(9999, 1); // → Rare, index=0
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        assertEq(
            packMachine.getTierPoolSize(3),
            0,
            "All Rare cards should be drawn"
        );
        assertEq(assetNFT.balanceOf(user), 3);
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_FulfillRandomness_CardSelection(uint256 seed) public {
        uint256 poolSize = 6;
        _depositNFTs(poolSize);
        usdc.mint(user, PRICE);
        vm.prank(user);
        usdc.approve(address(packMachine), PRICE);

        bytes memory sig = _signOpenPack(user, 0);
        vm.prank(user);
        packMachine.openPack(user, sig);

        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        for (uint256 i; i < CARDS_PER_PACK; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(seed, i)));
        }
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        assertEq(assetNFT.balanceOf(user), CARDS_PER_PACK);
        assertEq(_getTotalPoolLength(packMachine), poolSize - CARDS_PER_PACK);
    }

    function testFuzz_Deposit_VariousBatchSizes(uint8 count) public {
        vm.assume(count > 0 && count <= 50);
        uint256 startId = assetNFT.totalSupply() + 1;
        uint256[] memory ids = new uint256[](count);
        uint8[] memory tiers = new uint8[](count);
        address[] memory recipients = new address[](count);
        string[] memory uris = new string[](count);
        for (uint256 i; i < count; i++) {
            ids[i] = startId + i;
            recipients[i] = operator;
            uris[i] = "";
        }
        vm.prank(operator);
        assetNFT.batchMint(recipients, uris);
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(ids, tiers, operator);
        vm.stopPrank();
        assertEq(packMachine.effectivePrizePoolSize(), count);
    }

    function testFuzz_SetTierWeights_SumMustBe10000(
        uint16 w0,
        uint16 w1,
        uint16 w2,
        uint16 w3
    ) public {
        vm.assume(uint256(w0) + w1 + w2 + w3 <= 10000);
        uint16 w4 = uint16(10000 - uint256(w0) - w1 - w2 - w3);
        uint16[5] memory weights = [w0, w1, w2, w3, w4];
        vm.prank(operator);
        packMachine.setTierWeights(weights);
        uint16[5] memory stored = packMachine.getTierWeights();
        assertEq(stored[0], w0);
        assertEq(stored[4], w4);
    }

    // =========================================================================
    // Event declarations
    // =========================================================================

    event PackOpened(
        address indexed user,
        uint256 indexed requestId,
        uint128 pricePaid
    );
    event CardWon(
        address indexed user,
        uint256 indexed tokenId,
        uint256 indexed requestId
    );
    event CardsDeposited(address indexed operator, uint256 count);
    event CardsWithdrawn(address indexed operator, uint256 count);
    event PriceUpdated(uint128 oldPrice, uint128 newPrice);
    event PackMachineStopped();
    event TierWeightsUpdated(uint16[5] weights);
}
