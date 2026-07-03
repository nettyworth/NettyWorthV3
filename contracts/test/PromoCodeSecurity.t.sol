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
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {MockVRFCoordinatorV2Plus} from "../test-helpers/MockVRFCoordinatorV2Plus.sol";
import {MockPermit2} from "../test-helpers/MockPermit2.sol";
import {FakePackMachine} from "../test-helpers/FakePackMachine.sol";
import {MockAssetLendingPool} from "../test-helpers/MockAssetLendingPool.sol";

/// @notice Adversarial test suite proving that a publicly-visible promo codeId
///         cannot be stolen or misused by a third party.
///
///         A promo codeId = keccak256(bytes(codeString)) — a non-secret hash
///         visible in calldata / the mempool as soon as a code is first used.
///         Security rests entirely on the access guards in PromoCodeRegistry and
///         the EIP-712 play-signature mechanism in PackMachine.  This file tests
///         all eight public attack vectors enumerated in the design plan.
///
///         For every threat:
///         (1) the attack attempt must REVERT with the correct custom error, AND
///         (2) registry.getCode(codeId).redeemedCount must remain UNCHANGED
///             (consume-only-on-success; a failed attempt cannot burn a code).
contract PromoCodeSecurityTest is Test {
    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------

    PackMachine internal packMachine;
    PackMachineFactory internal factory;
    PackVRFRouter internal vrfRouter;
    PackRegistry internal packRegistry;
    PackTierRegistry internal packTierRegistry;
    BuybackPool internal pool;
    PromoCodeRegistry internal registry;
    PermissionManager internal pm;
    MockERC20 internal usdc;
    AssetNFT internal assetNFT;
    MockVRFCoordinatorV2Plus internal coordinator;

    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------

    address internal admin = makeAddr("admin");
    address internal pauser = makeAddr("pauser");
    address internal forwarder = makeAddr("forwarder");
    address internal financeWallet = makeAddr("financeWallet");
    address internal victim = makeAddr("victim");     // legitimate pack buyer
    address internal attacker = makeAddr("attacker"); // adversary

    uint256 internal operatorPk;
    address internal operator;

    uint256 internal attackerPk;
    // (attacker address derived below)

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    address internal constant PERMIT2_ADDRESS =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    bytes32 internal constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 packId,uint256 nonce,bytes32 codeId)"
    );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint128 internal constant PRICE = 10e6; // 10 USDC
    uint8  internal constant CARDS_PER_PACK = 2;
    // 20 % buyback allocation so pool gets funded for buyback tests.
    uint16 internal constant BUYBACK_ALLOC_BPS = 2000;

    // Code identifiers (non-secret hashes, exactly what goes on-chain).
    bytes32 internal constant DISCOUNT_CODE = keccak256("SAVE20");       // 20 % discount
    bytes32 internal constant BUYBACK_CODE  = keccak256("BOOST95");      // 95 % buyback boost
    bytes32 internal constant RESTRICTED_CODE = keccak256("VIP_ONLY");   // restricted to allowlist

    uint16 internal constant DISCOUNT_BPS = 2000;
    uint16 internal constant BUYBACK_BPS  = 9500;

    // =========================================================================
    // setUp — full real stack, no mocks except VRF/Permit2
    // =========================================================================

    function setUp() public {
        (operator, operatorPk) = makeAddrAndKey("operator");
        (attacker,  attackerPk)  = makeAddrAndKey("attacker");

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

        // ── Mocks: ERC20, VRF, Permit2 ────────────────────────────────────────
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
                (address(pm), "NettyWorth Assets", "NWA", "ipfs://contract", makeAddr("royalty"), 250)
            )
        );
        assetNFT = AssetNFT(address(assetNFTProxy));

        // ── PackVRFRouter ─────────────────────────────────────────────────────
        PackVRFRouter routerImpl = new PackVRFRouter();
        ERC1967Proxy routerProxy = new ERC1967Proxy(
            address(routerImpl),
            abi.encodeCall(
                PackVRFRouter.initialize,
                (address(pm), address(coordinator), 1, keccak256("key"), 700_000, 3)
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

        PackRegistry registryImpl2 = new PackRegistry();
        ERC1967Proxy registryProxy2 = new ERC1967Proxy(
            address(registryImpl2),
            abi.encodeCall(PackRegistry.initialize, (address(pm)))
        );
        packRegistry = PackRegistry(address(registryProxy2));

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
        address cloneAddr = factory.createPackMachine(PRICE, CARDS_PER_PACK, uint40(block.timestamp));
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

        // ── BuybackPool ───────────────────────────────────────────────────────
        BuybackPool poolImpl = new BuybackPool();
        ERC1967Proxy poolProxy = new ERC1967Proxy(
            address(poolImpl),
            abi.encodeCall(
                BuybackPool.initialize,
                (address(pm), address(assetNFT), address(usdc), financeWallet, address(factory))
            )
        );
        pool = BuybackPool(address(poolProxy));

        // setBuybackPool requires paused (L001 fix)
        vm.prank(pauser);
        packMachine.pause();
        vm.prank(operator);
        packMachine.setBuybackPool(address(pool));
        vm.prank(pauser);
        packMachine.unpause();
        vm.prank(operator);
        packRegistry.setPackBuybackAllocation(address(packMachine), 0, BUYBACK_ALLOC_BPS);
        vm.prank(operator);
        pool.registerPackMachine(address(packMachine), true);

        // ── PromoCodeRegistry (REAL, fully wired) ─────────────────────────────
        PromoCodeRegistry regImpl = new PromoCodeRegistry();
        ERC1967Proxy regProxy = new ERC1967Proxy(
            address(regImpl),
            abi.encodeCall(PromoCodeRegistry.initialize, (address(pm)))
        );
        registry = PromoCodeRegistry(address(regProxy));

        // Wire: registry ↔ factory ↔ pool
        vm.startPrank(admin);
        registry.setPackMachineFactory(address(factory));
        registry.setBuybackPool(address(pool));
        factory.setPromoCodeRegistry(address(registry));
        vm.stopPrank();
        vm.prank(operator);
        pool.setPromoCodeRegistry(address(registry));

        // Seed pool with enough USDC to pay out boosted buybacks.
        usdc.mint(address(pool), 1000e6);

        // ── Create codes ──────────────────────────────────────────────────────
        vm.startPrank(operator);
        // Open discount code — anyone can redeem (restricted=false)
        registry.createCode(
            DISCOUNT_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS,
            0,  // no expiry
            0,  // uncapped
            false, // not restricted
            false, // not oncePerUser
            address(0)
        );
        // Open buyback boost code
        registry.createCode(
            BUYBACK_CODE,
            IPromoCodeRegistry.PromoKind.Buyback,
            BUYBACK_BPS,
            0,
            0,
            false,
            false,
            address(0)
        );
        // Restricted discount code — allowlist gated
        registry.createCode(
            RESTRICTED_CODE,
            IPromoCodeRegistry.PromoKind.Discount,
            DISCOUNT_BPS,
            0,
            0,
            true,  // restricted
            false,
            address(0)
        );
        vm.stopPrank();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _depositNFTs(uint256 count) internal returns (uint256[] memory tokenIds) {
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
        uint256[] memory _pcs = new uint256[](count);
        uint256[] memory _pids = new uint256[](count);
        uint8[] memory _trs = new uint8[](count);
        for (uint256 i; i < count; i++) { _pcs[i] = 1; _trs[i] = tiers[i]; }
        vm.startPrank(operator);
        assetNFT.setApprovalForAll(address(packMachine), true);
        packMachine.deposit(tokenIds, _pcs, _pids, _trs, operator);
        vm.stopPrank();
    }

    /// @dev Build an operator-signed OpenPack digest for a given (machine, user, nonce, codeId).
    ///      codeId must match the code passed to openPack() — it is bound in the digest (L004 fix).
    function _signOpenPackFor(
        address machine,
        address user_,
        uint256 nonce,
        uint256 signerPk,
        bytes32 codeId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(OPEN_PACK_TYPEHASH, user_, uint256(0), nonce, codeId));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                machine
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Open a pack as `who` with a valid operator signature, fulfil the VRF request,
    ///      and return the tokenIds won.
    function _openPackAndFulfill(
        address who,
        bytes32 codeId,
        uint256 requestId
    ) internal returns (uint256[] memory wonTokens) {
        uint256 nonce = packMachine.getUserInfo(who).openNonce;
        bytes memory sig = _signOpenPackFor(address(packMachine), who, nonce, operatorPk, codeId);

        usdc.mint(who, PRICE);
        vm.startPrank(who);
        usdc.approve(address(packMachine), PRICE);
        if (codeId == bytes32(0)) {
            packMachine.openPack(who, 0, sig);
        } else {
            packMachine.openPack(who, 0, sig, codeId);
        }
        vm.stopPrank();

        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        for (uint256 i; i < CARDS_PER_PACK; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(requestId, i)));
        }
        coordinator.fulfillRandomWords(address(vrfRouter), requestId, words);

        wonTokens = new uint256[](CARDS_PER_PACK);
        uint256 found;
        for (uint256 tokenId = 1; tokenId <= assetNFT.totalSupply(); tokenId++) {
            if (assetNFT.ownerOf(tokenId) == who) {
                wonTokens[found++] = tokenId;
                if (found == CARDS_PER_PACK) break;
            }
        }
    }

    // =========================================================================
    // Threat 1 — EOA calls redeemDiscount directly
    // =========================================================================

    /// @notice An EOA knowing a codeId cannot call redeemDiscount directly on the
    ///         registry.  Only a registered PackMachine clone is authorized.
    ///         redeemedCount must stay 0 after the attempt.
    function test_security_publicEOACannotRedeemDiscountDirectly() public {
        uint32 countBefore = registry.getCode(DISCOUNT_CODE).redeemedCount;

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                attacker
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, attacker);

        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, countBefore,
            "count must not change on failed EOA redemption");
    }

    // =========================================================================
    // Threat 2 — Unregistered contract calls redeemDiscount
    // =========================================================================

    /// @notice A malicious contract (not in factory.registeredPackMachines) cannot
    ///         redeem a discount code even though it is a contract, not an EOA.
    ///         Being "contract-shaped" is insufficient — factory membership is required.
    function test_security_unregisteredContractCannotRedeemDiscount() public {
        FakePackMachine fake = new FakePackMachine();
        uint32 countBefore = registry.getCode(DISCOUNT_CODE).redeemedCount;

        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                address(fake)
            )
        );
        fake.attack(address(registry), DISCOUNT_CODE, attacker);

        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, countBefore,
            "count must not change when an unregistered contract attacks");
    }

    // =========================================================================
    // Threat 3 — EOA (or contract) calls redeemBuyback directly
    // =========================================================================

    /// @notice Neither an EOA nor an unregistered contract can call redeemBuyback.
    ///         Only the configured BuybackPool singleton is authorized.
    function test_security_publicCannotRedeemBuybackDirectly() public {
        uint32 countBefore = registry.getCode(BUYBACK_CODE).redeemedCount;

        // EOA attempt
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                attacker
            )
        );
        registry.redeemBuyback(BUYBACK_CODE, attacker);

        assertEq(registry.getCode(BUYBACK_CODE).redeemedCount, countBefore,
            "count unchanged after EOA buyback attack");

        // Unregistered contract attempt
        FakePackMachine fake = new FakePackMachine();
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                address(fake)
            )
        );
        fake.attackBuyback(address(registry), BUYBACK_CODE, attacker);

        assertEq(registry.getCode(BUYBACK_CODE).redeemedCount, countBefore,
            "count unchanged after unregistered contract buyback attack");
    }

    // =========================================================================
    // Threat 4 — Stolen codeId + forged operator signature via openPack
    // =========================================================================

    /// @notice Attacker sees a codeId in the mempool, tries to open a pack for
    ///         themselves using a self-signed (forged) OpenPack play signature.
    ///         The signature check rejects it because the attacker does not hold
    ///         PACK_OPERATOR_ROLE; the code is NOT consumed.
    function test_security_stolenCodeWithForgedOperatorSigReverts_codeNotConsumed()
        public
    {
        _depositNFTs(CARDS_PER_PACK);
        uint32 countBefore = registry.getCode(DISCOUNT_CODE).redeemedCount;

        usdc.mint(attacker, PRICE);
        // Attacker signs the OpenPack message with their OWN key — not PACK_OPERATOR_ROLE.
        bytes memory forgedSig = _signOpenPackFor(
            address(packMachine), attacker, packMachine.getUserInfo(attacker).openNonce, attackerPk, DISCOUNT_CODE
        );

        vm.startPrank(attacker);
        usdc.approve(address(packMachine), PRICE);
        vm.expectRevert(PackMachine.PackMachine__InvalidSignature.selector);
        packMachine.openPack(attacker, 0, forgedSig, DISCOUNT_CODE);
        vm.stopPrank();

        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, countBefore,
            "code must NOT be consumed when the play signature is forged");
    }

    // =========================================================================
    // Threat 5 — Attacker relays/replays victim's signed openPack transaction
    // =========================================================================

    /// @notice Attacker copies a victim's valid `openPack(victim, sig, codeId)` from
    ///         the mempool and attempts to relay it themselves.  Two sub-cases:
    ///
    ///         5a. First relay: the pack STILL opens, but cards go to victim, not
    ///             attacker.  Attacker gets nothing; victim gets their cards.
    ///             Code is consumed exactly once.
    ///
    ///         5b. Replay: second attempt with the same (victim, nonce) signature
    ///             reverts because the nonce has already been consumed.
    function test_security_relayedVictimOpenMintsToVictim_replayReverts()
        public
    {
        _depositNFTs(CARDS_PER_PACK * 2); // enough for two potential opens

        uint256 victimNonce = packMachine.getUserInfo(victim).openNonce;
        bytes memory sig = _signOpenPackFor(
            address(packMachine), victim, victimNonce, operatorPk, DISCOUNT_CODE
        );

        // 5a. Attacker relays the victim's signed transaction.
        //     Cards must go to `victim`, not `attacker`.
        usdc.mint(attacker, PRICE); // attacker pays (they're the msg.sender / payer)
        vm.startPrank(attacker);
        usdc.approve(address(packMachine), PRICE);
        packMachine.openPack(victim, 0, sig, DISCOUNT_CODE); // attacker relays, victim is user
        vm.stopPrank();

        // VRF fulfillment — request 1
        uint256[] memory words = new uint256[](CARDS_PER_PACK);
        for (uint256 i; i < CARDS_PER_PACK; i++) {
            words[i] = uint256(keccak256(abi.encodePacked(uint256(1), i)));
        }
        coordinator.fulfillRandomWords(address(vrfRouter), 1, words);

        // Cards were minted to victim, not attacker.
        assertGt(assetNFT.balanceOf(victim), 0,   "victim must receive the cards");
        assertEq(assetNFT.balanceOf(attacker), 0, "attacker must receive nothing");
        // Code consumed once.
        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, 1,
            "code consumed exactly once after first relay");

        // 5b. Second attempt with the same signature must revert (nonce already used).
        usdc.mint(attacker, PRICE);
        vm.startPrank(attacker);
        usdc.approve(address(packMachine), PRICE);
        vm.expectRevert(PackMachine.PackMachine__InvalidSignature.selector);
        packMachine.openPack(victim, 0, sig, DISCOUNT_CODE); // same stale sig
        vm.stopPrank();

        // Count must not increment on the rejected replay.
        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, 1,
            "code must not be consumed again on failed replay");
    }

    // =========================================================================
    // Threat 6 — Attacker calls buyback for a token they do not own
    // =========================================================================

    /// @notice Attacker knows a buyback codeId and tries to consume it by calling
    ///         pool.buyback(someTokenId, BUYBACK_CODE) for a token they don't own.
    ///         The ownerOf check rejects it BEFORE redeemBuyback is called.
    ///         Code is NOT consumed.
    function test_security_buybackCodeRevertsForNonOwner_codeNotConsumed()
        public
    {
        _depositNFTs(CARDS_PER_PACK);
        _openPackAndFulfill(victim, bytes32(0), 1);

        // Find a token owned by victim
        uint256 victimToken;
        for (uint256 tokenId = 1; tokenId <= assetNFT.totalSupply(); tokenId++) {
            if (assetNFT.ownerOf(tokenId) == victim) {
                victimToken = tokenId;
                break;
            }
        }
        require(victimToken != 0, "no victim token found");

        uint32 countBefore = registry.getCode(BUYBACK_CODE).redeemedCount;

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuybackPool.BuybackPool__NotTokenOwner.selector,
                victimToken,
                attacker
            )
        );
        pool.buyback(victimToken, BUYBACK_CODE);

        assertEq(registry.getCode(BUYBACK_CODE).redeemedCount, countBefore,
            "code must NOT be consumed when attacker doesn't own the token");
    }

    // =========================================================================
    // Threat 7 — Non-allowlisted user redeems restricted code through openPack
    // =========================================================================

    /// @notice A restricted code is visible on-chain (codes are not secret).
    ///         Any public user who calls openPack with a restricted codeId they
    ///         are NOT on the allowlist for must be rejected — the code must not
    ///         be consumed even though the play signature is valid.
    function test_security_restrictedCode_nonAllowlistedPublicUserReverts_codeNotConsumed()
        public
    {
        _depositNFTs(CARDS_PER_PACK);
        uint32 countBefore = registry.getCode(RESTRICTED_CODE).redeemedCount;

        uint256 nonce = packMachine.getUserInfo(attacker).openNonce;
        bytes memory sig = _signOpenPackFor(address(packMachine), attacker, nonce, operatorPk, RESTRICTED_CODE);

        usdc.mint(attacker, PRICE);
        vm.startPrank(attacker);
        usdc.approve(address(packMachine), PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__NotAllowlisted.selector,
                RESTRICTED_CODE,
                attacker
            )
        );
        packMachine.openPack(attacker, 0, sig, RESTRICTED_CODE);
        vm.stopPrank();

        assertEq(registry.getCode(RESTRICTED_CODE).redeemedCount, countBefore,
            "code must NOT be consumed when caller is not allowlisted");
    }

    // =========================================================================
    // Threat 7b — Allowlisted user CAN redeem the restricted code (positive control)
    // =========================================================================

    /// @notice Positive control for threat 7: after being added to the allowlist,
    ///         the same restricted code successfully grants the discount.
    function test_security_restrictedCode_allowlistedUserSucceeds() public {
        _depositNFTs(CARDS_PER_PACK);

        address[] memory users = new address[](1);
        users[0] = victim;
        vm.prank(operator);
        registry.addToAllowlist(RESTRICTED_CODE, users);

        uint256 nonce = packMachine.getUserInfo(victim).openNonce;
        bytes memory sig = _signOpenPackFor(address(packMachine), victim, nonce, operatorPk, RESTRICTED_CODE);

        usdc.mint(victim, PRICE);
        vm.startPrank(victim);
        usdc.approve(address(packMachine), PRICE);
        packMachine.openPack(victim, 0, sig, RESTRICTED_CODE); // must not revert
        vm.stopPrank();

        assertEq(registry.getCode(RESTRICTED_CODE).redeemedCount, 1,
            "code consumed exactly once for an allowlisted user");
    }

    // =========================================================================
    // Threat 8 — Deregistered PackMachine clone can no longer redeem
    // =========================================================================

    /// @notice A clone that was removed from the factory's isPackMachine mapping
    ///         (e.g. after it reaches end-of-life) can no longer consume codes.
    ///         The registry delegates the caller-validity check to the real factory,
    ///         so deregistration is sufficient to revoke redemption rights.
    ///
    ///         NOTE: PackMachineFactory's public `isPackMachine` mapping is set to
    ///         true only on clone creation (no public deregistration function exists
    ///         yet).  We simulate deregistration by forking the factory storage slot
    ///         directly via `vm.store`, which is the intended low-level testing path
    ///         for this invariant.
    function test_security_deregisteredPackMachineCannotRedeem() public {
        // Confirm the clone is currently registered.
        assertTrue(factory.isPackMachine(address(packMachine)),
            "pre-condition: clone must be registered");

        // The real PackMachineFactory does not expose a public deregistration function;
        // once a clone is created, its isPackMachine flag is permanently true in the original
        // factory.  The equivalent real-world deregistration is to point the registry at a
        // NEW factory instance that has no record of the old clone.
        //
        // This scenario arises in practice when:
        //   (a) a factory is upgraded to a new proxy and old clones are sunset, or
        //   (b) the registry's factory reference is updated to a stricter allowlist.
        //
        // We simulate it by deploying a fresh factory (no clones) and re-wiring the registry.
        PackMachineFactory factoryImpl2 = new PackMachineFactory(forwarder);
        ERC1967Proxy factoryProxy2 = new ERC1967Proxy(
            address(factoryImpl2),
            abi.encodeCall(
                PackMachineFactory.initialize,
                (address(pm), address(assetNFT), address(usdc), financeWallet)
            )
        );
        PackMachineFactory newFactory = PackMachineFactory(address(factoryProxy2));

        // The old clone is NOT registered in newFactory — isPackMachine returns false.
        assertFalse(newFactory.isPackMachine(address(packMachine)),
            "old clone must not be in the new factory");

        // Re-wire registry to the new factory.
        vm.prank(admin);
        registry.setPackMachineFactory(address(newFactory));

        // Now the old clone cannot redeem codes.
        uint32 countBefore = registry.getCode(DISCOUNT_CODE).redeemedCount;

        vm.prank(address(packMachine));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__UnauthorizedRedeemer.selector,
                address(packMachine)
            )
        );
        registry.redeemDiscount(DISCOUNT_CODE, attacker);

        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, countBefore,
            "effectively-deregistered clone must not consume a code");
    }

    // =========================================================================
    // Compound: public user learns TWO codes, uses wrong code for buyback
    // =========================================================================

    /// @notice Defense-in-depth: even if attacker correctly identifies that a code
    ///         is a BuybackKind code, they cannot use it via redeemDiscount (wrong kind)
    ///         and cannot use a DiscountKind code via redeemBuyback (wrong kind).
    ///         Cross-spoke code misuse is independently blocked by the kind check.
    function test_security_crossSpokeCodeMisuse_wrongKindReverts() public {
        uint32 discountCountBefore = registry.getCode(DISCOUNT_CODE).redeemedCount;
        uint32 buybackCountBefore  = registry.getCode(BUYBACK_CODE).redeemedCount;

        // Attacker tries to use the buyback code as a discount via a valid pack machine prank
        vm.prank(address(packMachine));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__WrongKind.selector,
                BUYBACK_CODE,
                IPromoCodeRegistry.PromoKind.Discount,
                IPromoCodeRegistry.PromoKind.Buyback
            )
        );
        registry.redeemDiscount(BUYBACK_CODE, attacker);

        // Attacker tries to use the discount code as a buyback boost via the pool address prank
        vm.prank(address(pool));
        vm.expectRevert(
            abi.encodeWithSelector(
                IPromoCodeRegistry.PromoCodeRegistry__WrongKind.selector,
                DISCOUNT_CODE,
                IPromoCodeRegistry.PromoKind.Buyback,
                IPromoCodeRegistry.PromoKind.Discount
            )
        );
        registry.redeemBuyback(DISCOUNT_CODE, attacker);

        // Both counts unchanged
        assertEq(registry.getCode(DISCOUNT_CODE).redeemedCount, discountCountBefore);
        assertEq(registry.getCode(BUYBACK_CODE).redeemedCount,  buybackCountBefore);
    }
}
