// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";
import {PackTypes} from "./lib/PackTypes.sol";
import {IPackMachine} from "./interfaces/IPackMachine.sol";
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";
import {IPackRegistry} from "./interfaces/IPackRegistry.sol";
import {IPackVRFRouter} from "./interfaces/IPackVRFRouter.sol";
import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";
import {IBuybackPool} from "./interfaces/IBuybackPool.sol";
import {IPromoCodeRegistry} from "./interfaces/IPromoCodeRegistry.sol";
import {IAssetNFT} from "./interfaces/IAssetNFT.sol";

/// @title PackMachine
/// @author NettyWorth
/// @notice EIP-1167 clone instance. Users pay USDC to open a pack of randomly selected AssetNFTs.
///         One machine can host multiple packs — each with its own price, cardsPerPack, startTime,
///         tier weights, and buyback allocation. All packs draw from the same shared card pool held by
///         this machine. A card won by any pack is immediately removed from the pool for all others.
///         Randomness is provided by Chainlink VRF v2.5 via the shared PackVRFRouter.
/// @dev Deployed by PackMachineFactory via Clones.clone(). Not UUPS-upgradeable (clone pattern).
///      Uses ERC-7201 namespaced storage to avoid slot collisions in the shared implementation.
///      Pack definitions (price, tier weights, buyback allocation, etc.) are stored in PackRegistry,
///      not here. This machine holds only custody state: prize pools, pending opens, nonces,
///      and machine-wide config (buybackPool, authorizedDepositors).
/// @custom:security-contact security@nettyworth.io
contract PackMachine is
    Initializable,
    PermissionConsumer,
    ERC2771ContextUpgradeable,
    EIP712Upgradeable,
    ReentrancyGuard,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev Uniswap Permit2 canonical address (same on all EVM chains).
    ISignatureTransfer private constant PERMIT2 = ISignatureTransfer(
        0x000000000022D473030F116dDEE9F6B43aC78BA3
    );

    uint256 private constant MAX_BATCH = 50;

    /// @dev EIP-712 type hash for the open-pack authorization signature.
    ///      packId is included so a signature for one pack cannot be replayed on another.
    ///      codeId is included so a leaked signature cannot burn a user's oncePerUser code
    ///      on an unintended promo code. Use bytes32(0) for codeless opens.
    bytes32 private constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 packId,uint256 nonce,bytes32 codeId)"
    );

    uint256 private constant NUM_TIERS = 6;

    /// @dev Tier weights are expressed in basis points; all six must sum to this value.
    uint16 private constant WEIGHT_PRECISION = 10000;

    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.PackMachine
    struct PackMachineStorage {
        address factory;
        address assetNFT;
        bool isFinished;
        // === Shared card pool ===
        uint256 effectivePrizePoolSize;
        mapping(uint256 requestId => PendingOpen) pendingOpens;
        mapping(address user => uint256) openNonces;
        // === Shared Payment ===
        /// @dev BuybackPool contract address (machine-wide; per-pack buybackAllocationBps in registry controls routing).
        address buybackPool;
        // === Authorized Pool Depositors ===
        /// @dev Addresses permitted to call depositFromPool (BuybackPool + AssetLendingPool).
        mapping(address depositor => bool) authorizedDepositors;
        // ── Per-pack eligibility ────────────────────────────────────────────
        /// @dev Eligibility bitmask per token. Bit p set ⇒ token is eligible for packId p.
        ///      Capped at 256 packs (enforced in PackRegistry.addPack).
        ///      Retained as a "dormant mask" after a win so depositFromPool can restore it.
        mapping(uint256 tokenId => uint256 mask) eligibility;
        /// @dev Per-(pack,tier) tokenId pools used for O(1) weighted random draw.
        ///      packTierPools[packId] is a fixed-size array[6] of dynamic arrays of tokenIds.
        mapping(uint256 packId => uint256[][6]) packTierPools;
        /// @dev Index+1 of token in packTierPools[packId][packTokenTier[token][packId]].
        ///      0 means the token is not in that pack's pool.
        ///      Used for O(1) swap-and-pop removal across all eligible packs on a win.
        mapping(uint256 tokenId => mapping(uint256 packId => uint256 indexPlus1)) packPoolIndex;
        /// @dev True while a token is physically held by this machine.
        ///      Set true on deposit, false on win / withdrawCards.
        mapping(uint256 tokenId => bool) inCustody;
        /// @dev Per-pack available counter for reservation (Scheme B).
        ///      = eligible-tokens-in-custody for pack p minus pending reservations.
        ///      Decremented on _requestVRF, restored on CardFailed, decremented further on win.
        mapping(uint256 packId => uint256) availablePerPack;
        // === Escrow ===
        /// @dev Sum of all escrowed payments for pending VRF requests. rescueERC20 must
        ///      never sweep below this floor so user funds are always recoverable.
        uint256 totalEscrowed;
        /// @dev Promo code (if any) used for a pending open, keyed by VRF requestId.
        ///      Written only when a discount code is applied; omitted (default bytes32(0))
        ///      for opens without a code. Cleared alongside pendingOpens in fulfillRandomness.
        mapping(uint256 requestId => bytes32 codeId) pendingCodeIds;
        // ── Appended ──────────────────────────────────────────────────────────
        /// @dev Tracks whether a wallet has already consumed the global first-open discount
        ///      on this machine. Reset on a fully-failed (zero-card) VRF open so the wallet
        ///      is not penalized for a bad randomness outcome.
        mapping(address wallet => bool) hasClaimedFirstOpenDiscount;
        /// @dev Records whether the first-open discount was consumed for a pending VRF request,
        ///      so it can be restored in fulfillRandomness on a full-refund (all-cards-failed).
        ///      Written only when the discount is applied; cleared alongside pendingOpens.
        mapping(uint256 requestId => bool) pendingFirstOpen;
        /// @dev Running count of VRF requests that have been submitted but whose
        ///      fulfillRandomness has not yet completed. Incremented in _requestVRF, decremented
        ///      at the end of every fulfillRandomness invocation. resetEffectivePrizePoolSize
        ///      reverts if this counter is non-zero to prevent double-counting reservations that
        ///      are still in-flight but already subtracted from effectivePrizePoolSize.
        uint256 pendingRequestCount;
        /// @dev Per-(token,pack) tier. Tier is purely a per-pack property.
        ///      Survives a win as a DORMANT map (not deleted on win) so depositFromPool
        ///      restores per-pack tiers automatically. Cleared only on withdrawCards.
        mapping(uint256 tokenId => mapping(uint256 packId => uint8 tier)) packTokenTier;
    }

    struct PendingOpen {
        address user;
        uint8 cardsCount;
        uint256 packId;
        /// @dev Total USDC (post-discount) held in escrow for this open.
        uint256 escrowedAmount;
        /// @dev Buyback allocation portion of escrowedAmount (routed to BuybackPool on settle).
        uint256 buybackAmount;
        /// @dev Tier weights at the moment the user paid. fulfillRandomness uses these
        ///      instead of reading live registry values so a mid-flight operator change
        ///      cannot alter the distribution of cards the user receives.
        uint32[6] tierWeightsSnapshot;
        /// @dev buybackAllocationBps at the moment the user paid. Ensures the buyback
        ///      routing fraction cannot be changed between payment and settlement.
        uint16 buybackAllocationBpsSnapshot;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.PackMachine")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PACK_MACHINE_STORAGE_SLOT =
        0xf65d8338bde3e030621995e09419bd24a6a0ace7a2660416b0681f35fe771000;

    function _getStorage() private pure returns (PackMachineStorage storage $) {
        assembly {
            $.slot := PACK_MACHINE_STORAGE_SLOT
        }
    }

    // =========================================================================
    // Events
    // =========================================================================

    event PackOpened(
        address indexed user,
        uint256 indexed requestId,
        uint256 indexed packId,
        uint128 pricePaid
    );
    event CardWon(
        address indexed user,
        uint256 indexed tokenId,
        uint256 indexed requestId
    );
    event CardFailed(
        address indexed user,
        uint256 indexed tokenId,
        uint256 indexed requestId
    );
    event CardsDeposited(address indexed operator, uint256 count);
    event CardsWithdrawn(address indexed operator, uint256 count);
    event PackMachineStopped();
    event BuybackPoolUpdated(address indexed oldPool, address indexed newPool);
    event AuthorizedDepositorUpdated(
        address indexed depositor,
        bool authorized
    );
    /// @dev Emitted when BuybackPool.registerToken reverts after a successful card transfer.
    ///      The user already received the card; buyback registration is best-effort.
    event BuybackRegistrationFailed(
        uint256 indexed tokenId,
        uint256 indexed requestId
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error PackMachine__NotStarted();
    error PackMachine__Finished();
    error PackMachine__PackFinished(uint256 packId);
    error PackMachine__PackNotActive(uint256 packId);
    error PackMachine__InvalidPackId(uint256 packId);
    error PackMachine__InsufficientPool(uint256 available, uint256 required);
    error PackMachine__NotPaused();
    error PackMachine__InvalidSignature();
    error PackMachine__BatchTooLarge(uint256 given, uint256 max);
    error PackMachine__OnlyVRFRouter(address caller);
    error PackMachine__ZeroAddress();
    error PackMachine__InvalidTier(uint8 tier);
    error PackMachine__TokenNotInPool(uint256 tokenId);
    error PackMachine__ArrayLengthMismatch();
    error PackMachine__InvalidBps(uint16 given);
    error PackMachine__UnauthorizedDepositor(address caller);
    error PackMachine__PromoRegistryNotSet();
    error PackMachine__RegistryNotSet();
    error PackMachine__NoEligibility(uint256 tokenId);
    error PackMachine__InvalidPackRef(uint256 packId);
    error PackMachine__TokenNotInCustody(uint256 tokenId);
    error PackMachine__TierFmvUnset(uint256 packId, uint8 tier);
    error PackMachine__FmvOutOfRange(
        uint256 tokenId,
        uint256 packId,
        uint8 tier,
        uint256 fmv
    );
    error PackMachine__BelowMinCards(
        uint256 packId,
        uint256 available,
        uint32 minCards
    );
    error PackMachine__PendingRequests(uint256 count);

    // =========================================================================
    // Constructor (disables initializers on the implementation)
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder
    ) ERC2771ContextUpgradeable(trustedForwarder) {
        _disableInitializers();
    }

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @notice Called by the factory immediately after cloning.
    ///         Pack 0 is created by the factory in PackRegistry — the clone itself holds no pack array.
    /// @param permissionManager_ Protocol PermissionManager address.
    /// @param factory_ PackMachineFactory address (payment & transfer-validator routing).
    /// @param pricePerPack_ USDC cost per pack for pack 0 (forwarded to PackRegistry via factory).
    /// @param cardsPerPack_ Cards per pack open for pack 0 (forwarded to PackRegistry via factory).
    /// @param startTime_ Unix timestamp from which pack opens are permitted for pack 0 (forwarded).
    function initialize(
        address permissionManager_,
        address factory_,
        uint128 pricePerPack_,
        uint8 cardsPerPack_,
        uint40 startTime_
    ) external initializer {
        if (factory_ == address(0)) revert PackMachine__ZeroAddress();
        // pricePerPack_, cardsPerPack_, startTime_ are accepted for interface compatibility
        // and forwarded to PackRegistry by the factory; validation occurs there.
        pricePerPack_;
        cardsPerPack_;
        startTime_;

        __PermissionConsumer_init(permissionManager_);
        __EIP712_init("PackMachine", "1");
        __Pausable_init();

        PackMachineStorage storage $ = _getStorage();
        $.factory = factory_;
        $.assetNFT = IPackMachineFactory(factory_).assetNFT();
    }

    // =========================================================================
    // Internal registry helper
    // =========================================================================

    /// @dev Resolves the PackRegistry via the factory. Reverts if not set.
    function _registry() private view returns (IPackRegistry reg) {
        address r = IPackMachineFactory(_getStorage().factory).packRegistry();
        if (r == address(0)) revert PackMachine__RegistryNotSet();
        reg = IPackRegistry(r);
    }

    // =========================================================================
    // Pack-open flows
    // =========================================================================

    /// @notice Open a pack by pulling USDC directly from `msg.sender`.
    /// @param user      The recipient of the won cards (subject to blacklist check in AssetNFT).
    /// @param packId  Which pack to open.
    /// @param signature EIP-712 `OpenPack(address user, uint256 packId, uint256 nonce)` signed by a PACK_OPERATOR_ROLE holder.
    function openPack(
        address user,
        uint256 packId,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        _openPackDirect(user, packId, signature, bytes32(0));
    }

    /// @notice Open a pack by pulling USDC directly from `msg.sender`, applying a promo discount code.
    /// @param user      The recipient of the won cards.
    /// @param packId  Which pack to open.
    /// @param signature EIP-712 `OpenPack(address user, uint256 packId, uint256 nonce)` signed by a PACK_OPERATOR_ROLE holder.
    /// @param codeId    keccak256 of the off-chain promo-code string; bytes32(0) means no discount.
    function openPack(
        address user,
        uint256 packId,
        bytes calldata signature,
        bytes32 codeId
    ) external nonReentrant whenNotPaused {
        _openPackDirect(user, packId, signature, codeId);
    }

    /// @dev Shared implementation for both direct-USDC openPack overloads.
    function _openPackDirect(
        address user,
        uint256 packId,
        bytes calldata signature,
        bytes32 codeId
    ) private {
        PackMachineStorage storage $ = _getStorage();
        PackTypes.Pack memory pack = _registry().getPack(address(this), packId);
        _assertOpenable($, pack, packId);
        _verifySignature($, user, packId, codeId, signature);
        (
            uint256 escrowed,
            uint256 buyback,
            bool firstOpenApplied
        ) = _handlePayment($, pack, _msgSender(), user, codeId);
        _requestVRF(
            $,
            pack,
            user,
            packId,
            IPackMachineFactory($.factory),
            escrowed,
            buyback,
            codeId,
            firstOpenApplied
        );
    }

    /// @notice Open a pack paying via Uniswap Permit2 (gasless for user — relayer pays gas).
    /// @param user             The recipient of the won cards.
    /// @param packId         Which pack to open.
    /// @param permit2Nonce     Permit2 nonce (unique per permit).
    /// @param permit2Deadline  Permit2 expiry timestamp.
    /// @param permit2Signature Permit2 authorization signature from `user`.
    /// @param playSignature    EIP-712 `OpenPack` signature from a PACK_OPERATOR_ROLE holder.
    function openPackWithPermit2(
        address user,
        uint256 packId,
        uint256 permit2Nonce,
        uint256 permit2Deadline,
        bytes calldata permit2Signature,
        bytes calldata playSignature
    ) external nonReentrant whenNotPaused {
        _openPackWithPermit2Internal(
            user,
            packId,
            permit2Nonce,
            permit2Deadline,
            permit2Signature,
            playSignature,
            bytes32(0)
        );
    }

    /// @notice Open a pack via Uniswap Permit2 with a promo discount code.
    /// @param user             The recipient of the won cards.
    /// @param packId         Which pack to open.
    /// @param codeId           keccak256 of the off-chain promo-code string; bytes32(0) means no discount.
    function openPackWithPermit2(
        address user,
        uint256 packId,
        uint256 permit2Nonce,
        uint256 permit2Deadline,
        bytes calldata permit2Signature,
        bytes calldata playSignature,
        bytes32 codeId
    ) external nonReentrant whenNotPaused {
        _openPackWithPermit2Internal(
            user,
            packId,
            permit2Nonce,
            permit2Deadline,
            permit2Signature,
            playSignature,
            codeId
        );
    }

    /// @dev Shared Permit2 implementation for both code-aware and codeless overloads.
    function _openPackWithPermit2Internal(
        address user,
        uint256 packId,
        uint256 permit2Nonce,
        uint256 permit2Deadline,
        bytes calldata permit2Signature,
        bytes calldata playSignature,
        bytes32 codeId
    ) private {
        PackMachineStorage storage $ = _getStorage();
        // Fetch pack config once into memory (validates packId via registry).
        PackTypes.Pack memory pack = _registry().getPack(address(this), packId);
        _assertOpenable($, pack, packId);
        _verifySignature($, user, packId, codeId, playSignature);

        IPackMachineFactory iFactory = IPackMachineFactory($.factory);

        // Resolve discount and buyback allocation (redeems promo code when codeId is non-zero,
        // or applies the global first-open discount when no code is supplied).
        (
            uint256 escrowedAmount,
            uint256 buybackAmount,
            bool firstOpenApplied
        ) = _resolveAmounts($, pack, user, codeId);

        // Pull the discounted amount from the user via Permit2 into this contract (escrow).
        // Funds remain here until fulfillRandomness distributes them per-card or refunds failures.
        PERMIT2.permitTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: iFactory.paymentToken(),
                    amount: escrowedAmount
                }),
                nonce: permit2Nonce,
                deadline: permit2Deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({
                to: address(this),
                requestedAmount: escrowedAmount
            }),
            user,
            permit2Signature
        );

        _requestVRF(
            $,
            pack,
            user,
            packId,
            iFactory,
            escrowedAmount,
            buybackAmount,
            codeId,
            firstOpenApplied
        );
    }

    // =========================================================================
    // VRF callback
    // =========================================================================

    /// @notice Called by PackVRFRouter to deliver random words and complete a pack open.
    /// @dev Must only be callable by the trusted PackVRFRouter.
    ///      Each card is drawn exclusively from the pack's eligible per-(pack,tier) pools.
    ///      Winning a card removes it from ALL packs it belongs to (O(eligibility popcount)).
    ///      Under concurrent opens on packs with overlapping eligibility, a card reserved for
    ///      pack P but drawn by a racing open may not be available at fulfillment; in that case
    ///      CardFailed is emitted and reservations are restored gracefully — USDC is NOT refunded.
    function fulfillRandomness(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external nonReentrant {
        PackMachineStorage storage $ = _getStorage();
        address vrfRouter = IPackMachineFactory($.factory).packVRFRouter();
        if (msg.sender != vrfRouter)
            revert PackMachine__OnlyVRFRouter(msg.sender);

        PendingOpen memory pending = $.pendingOpens[requestId];
        bytes32 pendingCodeId = $.pendingCodeIds[requestId];
        bool pendingFirstOpenDiscount = $.pendingFirstOpen[requestId];
        delete $.pendingOpens[requestId];
        delete $.pendingCodeIds[requestId];
        delete $.pendingFirstOpen[requestId];

        // Fetch pack config from registry at fulfill-time (used for pricePerPack in the
        // PackOpened event and any fields not snapshotted at request time).
        PackTypes.Pack memory pack = _registry().getPack(
            address(this),
            pending.packId
        );

        IPackMachineFactory iFactory = IPackMachineFactory($.factory);
        address assetNFT = $.assetNFT;
        address pool = $.buybackPool;
        bool poolActive =
            pool != address(0) && pending.buybackAllocationBpsSnapshot > 0;

        // Compute the per-card paid amount (net of any promo / first-open discount)
        // once before the card loop. escrowedAmount is the actual USDC the buyer paid
        // for the entire open, divided equally across the requested card count.
        // Stored so the BuybackPool can price Spend-mode buybacks correctly.
        uint128 paidPerCard =
            pending.cardsCount > 0
                ? uint128(pending.escrowedAmount / pending.cardsCount)
                : 0;

        iFactory.beforeTransfer(assetNFT);

        uint256 wonCards;
        for (uint256 i; i < pending.cardsCount; ++i) {
            uint256 word = randomWords[i];

            // Compute active weights — exclude tiers empty for THIS PACK.
            uint32[6] memory activeWeights;
            uint256 totalActiveWeight;
            for (uint256 t; t < NUM_TIERS; ++t) {
                if ($.packTierPools[pending.packId][t].length == 0) continue;
                activeWeights[t] = pending.tierWeightsSnapshot[t];
                totalActiveWeight += pending.tierWeightsSnapshot[t];
            }

            if (totalActiveWeight == 0) {
                // All eligible tiers empty — restore reservations and skip.
                $.effectivePrizePoolSize++;
                $.availablePerPack[pending.packId]++;
                emit CardFailed(pending.user, 0, requestId);
                continue;
            }

            // Select tier using upper 128 bits of the random word.
            uint256 tierRand = (word >> 128) % totalActiveWeight;
            uint256 selectedTier;
            uint256 cumulative;
            for (uint256 t; t < NUM_TIERS; ++t) {
                cumulative += activeWeights[t];
                if (tierRand < cumulative) {
                    selectedTier = t;
                    break;
                }
            }

            // Select token within this pack's tier pool using lower 128 bits.
            uint256 selectedPoolLen = $
                .packTierPools[pending.packId][selectedTier]
                .length;
            uint256 index = uint128(word) % selectedPoolLen;
            uint256 tokenId = $.packTierPools[pending.packId][selectedTier][
                index
            ];

            // Remove from every pack pool it belongs to.
            // Machine-wide tier pool is intentionally absent — tier is per-pack only.
            uint256 tokenMask = $.eligibility[tokenId];
            _removeFromAllPacks($, tokenId, tokenMask);
            $.inCustody[tokenId] = false;
            // Eligibility mask and packTokenTier kept dormant for depositFromPool restoration.

            // Decrement available counters for all other overlapping packs
            // (this pack's reservation was already charged at _requestVRF time).
            uint256 otherMask = tokenMask & ~(uint256(1) << pending.packId);
            _decrementAvailableForMask($, otherMask);

            try
                IERC721(assetNFT).transferFrom(
                    address(this),
                    pending.user,
                    tokenId
                )
            {
                ++wonCards;
                emit CardWon(pending.user, tokenId, requestId);
                // Register with BuybackPool so the user can sell the card back.
                // paidPerCard is the net USDC the buyer paid per card — used by
                // BuybackPool when the machine is in Spend mode.
                // Wrapped in try/catch: a registration failure must never revert card
                // delivery — the user already owns the NFT at this point.
                if (poolActive) {
                    try
                        IBuybackPool(pool).registerToken(
                            tokenId,
                            uint8(selectedTier),
                            address(this),
                            paidPerCard
                        )
                    {} catch {
                        emit BuybackRegistrationFailed(tokenId, requestId);
                    }
                }
            } catch {
                // Transfer failed — return the card to all its pools.
                // Per-pack tiers are still in the dormant packTokenTier map, so
                // _addToEligiblePacks resolves the correct tier for each pack.
                _addToEligiblePacks($, tokenId, tokenMask);
                $.inCustody[tokenId] = true;
                // Restore available counters for other packs we decremented.
                _incrementAvailableForMask($, otherMask);
                // Restore reservation for this pack.
                $.effectivePrizePoolSize++;
                $.availablePerPack[pending.packId]++;
                emit CardFailed(pending.user, tokenId, requestId);
            }
        }

        iFactory.afterTransfer(assetNFT);

        // ── Settle escrowed payment ──────────────────────────────────────────
        // Distribute the held USDC proportionally to the cards that were actually
        // won; refund the remainder to the user (failed cards are not charged).
        // Integer-division dust (at most cardsCount-1 wei) stays in the contract
        // and is sweepable via rescueERC20 (which protects totalEscrowed).
        $.totalEscrowed -= pending.escrowedAmount;
        uint256 n = pending.cardsCount;
        IERC20 paymentToken = IERC20(iFactory.paymentToken());
        if (wonCards > 0 && pending.escrowedAmount > 0) {
            uint256 settled = (pending.escrowedAmount * wonCards) / n;
            uint256 buybackShare = (pending.buybackAmount * wonCards) / n;
            uint256 financeShare = settled - buybackShare;
            if (buybackShare > 0 && pool != address(0)) {
                paymentToken.safeTransfer(pool, buybackShare);
            }
            if (financeShare > 0) {
                paymentToken.safeTransfer(
                    iFactory.financeWallet(),
                    financeShare
                );
            }
            uint256 refund = pending.escrowedAmount - settled;
            if (refund > 0) {
                paymentToken.safeTransfer(pending.user, refund);
            }
        } else if (pending.escrowedAmount > 0) {
            // All cards failed — refund the full escrowed amount.
            paymentToken.safeTransfer(pending.user, pending.escrowedAmount);
            // Reverse the promo code consumption so the user can reuse their code.
            if (pendingCodeId != bytes32(0)) {
                address promoReg = iFactory.promoCodeRegistry();
                if (promoReg != address(0)) {
                    try
                        IPromoCodeRegistry(promoReg).refundDiscount(
                            pendingCodeId,
                            pending.user
                        )
                    {} catch {} // solhint-disable-line no-empty-blocks
                }
            }
            // Reverse the first-open discount consumption so the wallet retains its
            // once-per-machine discount after a fully-failed (zero-card) open.
            if (pendingFirstOpenDiscount) {
                $.hasClaimedFirstOpenDiscount[pending.user] = false;
            }
        }
        $.pendingRequestCount--;

        emit PackOpened(
            pending.user,
            requestId,
            pending.packId,
            pack.pricePerPack
        );
    }

    // =========================================================================
    // Admin — deposit / withdraw (machine-wide, shared pool)
    // =========================================================================

    /// @notice Deposit AssetNFTs into per-pack tiered prize pools.
    ///         Tier is a first-class per-(token, pack) property: the same card can be a
    ///         different tier in different packs. Eligibility and tier are set together.
    ///
    ///         Flat encoding for efficient calldata: all (packId, tier) pairs for ALL tokens
    ///         are concatenated into two flat arrays (`packIds` and `tiers`), and `packCounts`
    ///         gives how many entries belong to each token.
    ///
    ///         Example: 2 tokens, token A in packs [0,1] at tiers [3,1], token B in pack [0] at tier [2]:
    ///           tokenIds   = [A, B]
    ///           packCounts = [2, 1]      // 2 entries for A, 1 for B
    ///           packIds    = [0, 1, 0]   // A-pack0, A-pack1, B-pack0
    ///           tiers      = [3, 1, 2]   // A in pack0=Rare, A in pack1=Common, B in pack0=Uncommon
    ///
    /// @param tokenIds   Array of token IDs to deposit (max 50).
    /// @param packCounts Number of (pack, tier) entries per token. Sum must equal packIds.length.
    /// @param packIds    Flat array of pack indices; contiguous blocks per token per packCounts.
    /// @param tiers      Flat array of tiers, parallel to packIds.
    /// @param tokensOwner Current owner of the tokens (must have approved this contract).
    function deposit(
        uint256[] calldata tokenIds,
        uint256[] calldata packCounts,
        uint256[] calldata packIds,
        uint8[] calldata tiers,
        address tokensOwner
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        uint256 count = tokenIds.length;
        if (count != packCounts.length || packIds.length != tiers.length)
            revert PackMachine__ArrayLengthMismatch();
        if (count > MAX_BATCH)
            revert PackMachine__BatchTooLarge(count, MAX_BATCH);
        if (count == 0) return;

        PackMachineStorage storage $ = _getStorage();
        uint256 packCount = _registry().getPackCount(address(this));
        address assetNFT = $.assetNFT;

        IPackMachineFactory($.factory).beforeTransfer(assetNFT);
        uint256 offset;
        for (uint256 i; i < count; ++i) {
            uint256 tokenId = tokenIds[i];
            uint256 nPacks = packCounts[i];
            if (nPacks == 0) revert PackMachine__ArrayLengthMismatch();

            // Transfer NFT into custody first (CEI: external call before storage writes).
            IERC721(assetNFT).transferFrom(tokensOwner, address(this), tokenId);
            $.inCustody[tokenId] = true;

            // Register each (pack, tier) pair.
            uint256 mask;
            for (uint256 j; j < nPacks; ++j) {
                uint256 p = packIds[offset + j];
                uint8 t = tiers[offset + j];
                if (p >= packCount) revert PackMachine__InvalidPackRef(tokenId);
                if (t >= NUM_TIERS) revert PackMachine__InvalidTier(t);
                if ((mask >> p) & 1 == 1)
                    revert PackMachine__InvalidPackRef(tokenId); // duplicate pack
                _validateFmvForPack(assetNFT, tokenId, p, t);
                $.packTokenTier[tokenId][p] = t;
                _addToPackPool($, tokenId, p, t);
                mask |= uint256(1) << p;
            }
            $.eligibility[tokenId] = mask;
            offset += nPacks;
        }
        if (offset != packIds.length) revert PackMachine__ArrayLengthMismatch();
        IPackMachineFactory($.factory).afterTransfer(assetNFT);

        $.effectivePrizePoolSize += count;
        emit CardsDeposited(_msgSender(), count);
    }

    /// @notice Re-deposit NFTs from BuybackPool or AssetLendingPool back into pack pools.
    /// @dev Only callable by authorized pool depositors (BuybackPool or AssetLendingPool).
    ///      The dormant `eligibility[tokenId]` mask and `packTokenTier[tokenId][p]` records
    ///      retained from the token's previous win are used to restore it to the correct
    ///      per-(pack,tier) pools automatically. The `tiers` param provides a fallback tier
    ///      for any pack whose dormant tier record was not set (e.g. first deposit via this path).
    ///      Any mask bits referencing packs added after the win are silently cleared.
    function depositFromPool(
        uint256[] calldata tokenIds,
        uint8[] calldata tiers,
        address tokensOwner
    ) external {
        PackMachineStorage storage $ = _getStorage();
        if (msg.sender != $.buybackPool && !$.authorizedDepositors[msg.sender])
            revert PackMachine__UnauthorizedDepositor(msg.sender);

        uint256 count = tokenIds.length;
        if (count != tiers.length) revert PackMachine__ArrayLengthMismatch();
        if (count > MAX_BATCH)
            revert PackMachine__BatchTooLarge(count, MAX_BATCH);
        if (count == 0) return;

        uint256 packCount = _registry().getPackCount(address(this));
        address assetNFT = $.assetNFT;

        IPackMachineFactory($.factory).beforeTransfer(assetNFT);
        for (uint256 i; i < count; ++i) {
            uint256 tokenId = tokenIds[i];
            // Restore eligibility mask, clamped to current pack count.
            uint256 mask = $.eligibility[tokenId] & _validPackMask(packCount);
            if (mask == 0) {
                // No eligible packs remain — default to pack 0 with the supplied fallback tier.
                mask = 1;
                $.packTokenTier[tokenId][0] = tiers[i];
            }

            IERC721(assetNFT).transferFrom(tokensOwner, address(this), tokenId);
            $.inCustody[tokenId] = true;
            // eligibility mask is already set (dormant); no need to re-write.

            // Re-add to each eligible pack, resolving tier from the dormant registry with fallback.
            uint256 m = mask;
            while (m != 0) {
                uint256 p = _lsb(m);
                uint8 t = $.packTokenTier[tokenId][p];
                if (t == 0 && tiers[i] < NUM_TIERS) {
                    // No dormant tier for this pack — use the supplied fallback and persist it.
                    // (getTier returns 0 for unset AND for Base tier, so we only apply the
                    // fallback when the token hasn't been placed in this pack before. For Base
                    // tier (0) the dormant registry already returns 0 correctly — no override.)
                    $.packTokenTier[tokenId][p] = tiers[i];
                    t = tiers[i];
                }
                _addToPackPool($, tokenId, p, t);
                m &= m - 1;
            }
            $.eligibility[tokenId] = mask;
        }
        IPackMachineFactory($.factory).afterTransfer(assetNFT);

        $.effectivePrizePoolSize += count;
        emit CardsDeposited(msg.sender, count);
    }

    /// @notice Withdraw specific cards by token ID. Requires contract to be paused.
    /// @param tokenIds Token IDs to withdraw (max 50). Each must currently be in custody.
    function withdrawCards(
        uint256[] calldata tokenIds
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        PackMachineStorage storage $ = _getStorage();
        if (!paused()) revert PackMachine__NotPaused();

        uint256 count = tokenIds.length;
        if (count > MAX_BATCH)
            revert PackMachine__BatchTooLarge(count, MAX_BATCH);
        if (count > $.effectivePrizePoolSize)
            revert PackMachine__InsufficientPool(
                $.effectivePrizePoolSize,
                count
            );

        address assetNFT = $.assetNFT;
        address recipient = _msgSender();

        IPackMachineFactory($.factory).beforeTransfer(assetNFT);
        for (uint256 i; i < count; ++i) {
            uint256 tokenId = tokenIds[i];
            if (!$.inCustody[tokenId])
                revert PackMachine__TokenNotInPool(tokenId);

            // Remove from every eligible pack pool.
            uint256 mask = $.eligibility[tokenId];
            _removeFromAllPacks($, tokenId, mask);

            // Decrement per-pack available counters.
            _decrementAvailableForMask($, mask);

            // Clear all custody state — token is leaving the machine entirely.
            $.inCustody[tokenId] = false;
            delete $.eligibility[tokenId];

            // Clear per-pack tier records so a future re-deposit starts clean.
            {
                uint256 m2 = mask;
                while (m2 != 0) {
                    uint256 p2 = _lsb(m2);
                    delete $.packTokenTier[tokenId][p2];
                    m2 &= m2 - 1;
                }
            }

            IERC721(assetNFT).transferFrom(address(this), recipient, tokenId);
        }
        IPackMachineFactory($.factory).afterTransfer(assetNFT);

        $.effectivePrizePoolSize -= count;
        emit CardsWithdrawn(recipient, count);
    }

    // =========================================================================
    // Admin — machine-wide configuration (custody-adjacent; stays on the clone)
    // =========================================================================

    function setBuybackPool(
        address pool
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (!paused()) revert PackMachine__NotPaused();
        if (pool == address(0)) revert PackMachine__ZeroAddress();
        PackMachineStorage storage $ = _getStorage();
        emit BuybackPoolUpdated($.buybackPool, pool);
        $.buybackPool = pool;
    }

    /// @notice Authorize or revoke a pool contract's ability to call depositFromPool.
    function setAuthorizedDepositor(
        address depositor,
        bool authorized
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (!paused()) revert PackMachine__NotPaused();
        if (depositor == address(0)) revert PackMachine__ZeroAddress();
        _getStorage().authorizedDepositors[depositor] = authorized;
        emit AuthorizedDepositorUpdated(depositor, authorized);
    }

    function pause() external onlyProtocolRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyProtocolRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Permanently stop this entire pack machine. Cannot be undone.
    function stop() external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        _getStorage().isFinished = true;
        _pause();
        emit PackMachineStopped();
    }

    /// @notice Recover ERC-20 tokens accidentally sent to this contract.
    /// @dev For the payment token, only the amount above `totalEscrowed` is swept so
    ///      pending user funds are never at risk.
    function rescueERC20(
        address token
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 escrowed =
            (token == IPackMachineFactory(_getStorage().factory).paymentToken())
                ? _getStorage().totalEscrowed
                : 0;
        if (balance <= escrowed) return;
        IERC20(token).safeTransfer(_msgSender(), balance - escrowed);
    }

    // =========================================================================
    // Views — pack (pass-throughs to PackRegistry)
    // =========================================================================

    function getPack(
        uint256 packId
    ) external view returns (PackTypes.Pack memory) {
        return _registry().getPack(address(this), packId);
    }

    // =========================================================================
    // Views — machine-wide pool
    // =========================================================================

    /// @notice Returns all machine-wide config and pool state in one call.
    function getMachineInfo()
        external
        view
        returns (IPackMachine.MachineInfo memory)
    {
        PackMachineStorage storage $ = _getStorage();
        return
            IPackMachine.MachineInfo({
                factory: $.factory,
                buybackPool: $.buybackPool,
                effectivePrizePoolSize: $.effectivePrizePoolSize
            });
    }

    /// @notice Returns per-user nonce and first-open discount claim status in one call.
    function getUserInfo(
        address user
    ) external view returns (IPackMachine.UserInfo memory) {
        PackMachineStorage storage $ = _getStorage();
        return
            IPackMachine.UserInfo({
                openNonce: $.openNonces[user],
                claimedFirstOpenDiscount: $.hasClaimedFirstOpenDiscount[user]
            });
    }

    /// @notice Returns the resolved tier for a token in a specific pack.
    ///         Reverts if the token is not in custody or not eligible for the pack.
    function getPackTokenTier(
        uint256 tokenId,
        uint256 packId
    ) external view returns (uint8) {
        PackMachineStorage storage $ = _getStorage();
        if (!$.inCustody[tokenId]) revert PackMachine__TokenNotInPool(tokenId);
        if ($.eligibility[tokenId] & (uint256(1) << packId) == 0)
            revert PackMachine__InvalidPackRef(tokenId);
        return $.packTokenTier[tokenId][packId];
    }

    // =========================================================================
    // ERC-2771 override
    // =========================================================================

    function _msgSender()
        internal
        view
        override(
            PermissionConsumer,
            ContextUpgradeable,
            ERC2771ContextUpgradeable
        )
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    function _assertOpenable(
        PackMachineStorage storage $,
        PackTypes.Pack memory pack,
        uint256 packId
    ) private view {
        if ($.isFinished) revert PackMachine__Finished();

        if (pack.finished) revert PackMachine__PackFinished(packId);
        if (!pack.active) revert PackMachine__PackNotActive(packId);
        if (block.timestamp < pack.startTime) revert PackMachine__NotStarted();

        uint256 available = $.availablePerPack[packId];
        if (available < pack.cardsPerPack) {
            revert PackMachine__InsufficientPool(available, pack.cardsPerPack);
        }

        if (pack.minCards != 0 && available < pack.minCards)
            revert PackMachine__BelowMinCards(packId, available, pack.minCards);
    }

    function _verifySignature(
        PackMachineStorage storage $,
        address user,
        uint256 packId,
        bytes32 codeId,
        bytes calldata signature
    ) private {
        uint256 nonce = $.openNonces[user]++;
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(OPEN_PACK_TYPEHASH, user, packId, nonce, codeId)
            )
        );
        // The signature must come from a PACK_OPERATOR_ROLE holder on the PermissionManager.
        address signer = digest.recover(signature);
        if (
            !IPackMachineFactory($.factory).isPackMachine(address(this)) // sanity: only valid pack machines
        ) revert PackMachine__InvalidSignature();
        // Check signer holds PACK_OPERATOR_ROLE
        _checkSignerRole(signer);
    }

    function _checkSignerRole(address signer) private view {
        bytes32 role = Roles.PACK_OPERATOR_ROLE;
        // slither-disable-next-line calls-loop
        (bool success, bytes memory data) = getPermissionManager().staticcall(
            abi.encodeWithSignature(
                "hasProtocolRole(bytes32,address)",
                role,
                signer
            )
        );
        if (!success || !abi.decode(data, (bool)))
            revert PackMachine__InvalidSignature();
    }

    /// @dev Compute the post-discount escrow amount and the buyback allocation within it.
    ///      Calls `redeemDiscount` when codeId is non-zero (state-changing — must be called
    ///      exactly once per open flow, before any token transfer).
    ///      Also applies the global first-open discount when no promo code is supplied,
    ///      the discount is enabled, and the wallet has not yet claimed it.
    ///      Returns `firstOpenApplied = true` when the first-open discount was consumed so
    ///      callers can record it in the pending-open slot for potential refund on full failure.
    function _resolveAmounts(
        PackMachineStorage storage $,
        PackTypes.Pack memory pack,
        address user,
        bytes32 codeId
    )
        private
        returns (
            uint256 escrowedAmount,
            uint256 buybackAmount,
            bool firstOpenApplied
        )
    {
        IPackMachineFactory iFactory = IPackMachineFactory($.factory);
        uint256 price = pack.pricePerPack;

        uint16 discountBps = 0;
        if (codeId != bytes32(0)) {
            address promoReg = iFactory.promoCodeRegistry();
            if (promoReg == address(0))
                revert PackMachine__PromoRegistryNotSet();
            discountBps = IPromoCodeRegistry(promoReg).redeemDiscount(
                codeId,
                user
            );
        } else if (
            iFactory.firstOpenDiscountEnabled() &&
            !$.hasClaimedFirstOpenDiscount[user]
        ) {
            discountBps = iFactory.firstOpenDiscountBps();
            $.hasClaimedFirstOpenDiscount[user] = true;
            firstOpenApplied = true;
        }
        escrowedAmount = price - (price * discountBps) / WEIGHT_PRECISION;

        address pool = $.buybackPool;
        buybackAmount =
            pool != address(0)
                ? (escrowedAmount * pack.buybackAllocationBps) /
                    WEIGHT_PRECISION
                : 0;
    }

    /// @dev Pull payment from `payer` into this contract (escrow), applying an optional promo
    ///      discount code or the global first-open discount. Returns the total escrowed amount,
    ///      the buyback allocation within it, and whether the first-open discount was consumed.
    ///      Funds are held here until fulfillRandomness settles them per-card; any cards
    ///      that fail (empty pool or transfer revert) are refunded proportionally to the user.
    function _handlePayment(
        PackMachineStorage storage $,
        PackTypes.Pack memory pack,
        address payer,
        address user,
        bytes32 codeId
    )
        private
        returns (
            uint256 escrowedAmount,
            uint256 buybackAmount,
            bool firstOpenApplied
        )
    {
        (escrowedAmount, buybackAmount, firstOpenApplied) = _resolveAmounts(
            $,
            pack,
            user,
            codeId
        );

        // Pull the full (post-discount) payment into this contract. Funds stay here
        // until fulfillRandomness distributes them to pool/finance or refunds to user.
        IERC20(IPackMachineFactory($.factory).paymentToken()).safeTransferFrom(
            payer,
            address(this),
            escrowedAmount
        );
    }

    function _requestVRF(
        PackMachineStorage storage $,
        PackTypes.Pack memory pack,
        address user,
        uint256 packId,
        IPackMachineFactory factory_,
        uint256 escrowedAmount,
        uint256 buybackAmount,
        bytes32 codeId,
        bool firstOpenApplied
    ) private {
        uint8 cards = pack.cardsPerPack;
        // Decrement both machine-wide and per-pack reservation counters.
        $.effectivePrizePoolSize -= cards;
        $.availablePerPack[packId] -= cards;

        uint256 requestId = IPackVRFRouter(factory_.packVRFRouter())
            .requestRandomWords(user, cards);
        $.pendingOpens[requestId] = PendingOpen({
            user: user,
            cardsCount: cards,
            packId: packId,
            escrowedAmount: escrowedAmount,
            buybackAmount: buybackAmount,
            tierWeightsSnapshot: pack.tierWeights,
            buybackAllocationBpsSnapshot: pack.buybackAllocationBps
        });
        // Store the promo code separately (sparse mapping — only written when non-zero).
        if (codeId != bytes32(0)) $.pendingCodeIds[requestId] = codeId;
        // Record first-open discount usage so it can be refunded on a full-failure open.
        if (firstOpenApplied) $.pendingFirstOpen[requestId] = true;
        $.totalEscrowed += escrowedAmount;
        $.pendingRequestCount++;
    }

    /// @dev Add tokenId to every pack pool indicated by mask.
    ///      Tier is resolved per-pack from the dormant packTokenTier map.
    ///      O(popcount(mask)).
    function _addToEligiblePacks(
        PackMachineStorage storage $,
        uint256 tokenId,
        uint256 mask
    ) private {
        uint256 m = mask;
        while (m != 0) {
            uint256 p = _lsb(m);
            // Guard against double-add.
            if ($.packPoolIndex[tokenId][p] == 0) {
                _addToPackPool($, tokenId, p, $.packTokenTier[tokenId][p]);
            }
            m &= m - 1; // clear lowest set bit
        }
    }

    /// @dev Remove tokenId from every pack pool indicated by mask.
    ///      Tier is resolved per-pack from the PackTierRegistry.
    ///      O(popcount(mask)).
    function _removeFromAllPacks(
        PackMachineStorage storage $,
        uint256 tokenId,
        uint256 mask
    ) private {
        uint256 m = mask;
        while (m != 0) {
            uint256 p = _lsb(m);
            _removeFromPackPool($, tokenId, p, $.packTokenTier[tokenId][p]);
            m &= m - 1;
        }
    }

    /// @dev O(1) add of tokenId to packTierPools[packId][tier] and bump availablePerPack.
    ///      Caller must ensure the token is not already present in this pack pool.
    function _addToPackPool(
        PackMachineStorage storage $,
        uint256 tokenId,
        uint256 packId,
        uint256 tier
    ) private {
        $.packTierPools[packId][tier].push(tokenId);
        $.packPoolIndex[tokenId][packId] = $.packTierPools[packId][tier].length; // index+1
        $.availablePerPack[packId]++;
    }

    /// @dev O(1) swap-and-pop removal of tokenId from packTierPools[packId][tier].
    function _removeFromPackPool(
        PackMachineStorage storage $,
        uint256 tokenId,
        uint256 packId,
        uint256 tier
    ) private {
        uint256 idxPlus1 = $.packPoolIndex[tokenId][packId];
        if (idxPlus1 == 0) return; // already absent
        uint256 idx = idxPlus1 - 1;
        uint256 last = $.packTierPools[packId][tier].length - 1;
        if (idx != last) {
            uint256 moved = $.packTierPools[packId][tier][last];
            $.packTierPools[packId][tier][idx] = moved;
            $.packPoolIndex[moved][packId] = idx + 1;
        }
        $.packTierPools[packId][tier].pop();
        $.packPoolIndex[tokenId][packId] = 0;
    }

    /// @dev Adjust availablePerPack for each pack bit in mask.
    ///      increment=true adds 1 (CardFailed restore path); false subtracts 1 (win path),
    ///      guarded against underflow.
    function _adjustAvailableForMask(
        PackMachineStorage storage $,
        uint256 mask,
        bool increment
    ) private {
        uint256 m = mask;
        while (m != 0) {
            uint256 p = _lsb(m);
            if (increment) {
                $.availablePerPack[p]++;
            } else if ($.availablePerPack[p] > 0) {
                $.availablePerPack[p]--;
            }
            m &= m - 1;
        }
    }

    /// @dev Decrement availablePerPack for each pack bit in mask (used when a winning token
    ///      is removed from packs it was eligible for but did NOT originate the open).
    function _decrementAvailableForMask(
        PackMachineStorage storage $,
        uint256 mask
    ) private {
        _adjustAvailableForMask($, mask, false);
    }

    /// @dev Increment availablePerPack for each pack bit in mask (CardFailed restore path).
    function _incrementAvailableForMask(
        PackMachineStorage storage $,
        uint256 mask
    ) private {
        _adjustAvailableForMask($, mask, true);
    }

    /// @dev All-ones mask covering bits [0, packCount). Returns full uint256 when packCount >= 256.
    function _validPackMask(uint256 packCount) private pure returns (uint256) {
        if (packCount >= 256) return type(uint256).max;
        return (uint256(1) << packCount) - 1;
    }

    /// @dev Validate every set bit in mask references an existing packId (< packCount).
    function _validateMaskBits(
        uint256 mask,
        uint256 packCount,
        uint256 tokenId
    ) private pure {
        // Reject any bit >= packCount (no-op when packCount >= 256: all bits are valid).
        if (packCount < 256 && mask & ~_validPackMask(packCount) != 0)
            revert PackMachine__InvalidPackRef(tokenId);
    }

    /// @dev Validate a single (token, pack, tier) triple against the pack's FMV bounds.
    ///      A tier with (minFmv, maxFmv) == (0, 0) is "unset" and always reverts.
    ///      Called per (pack, tier) pair at deposit / eligibility-setter time.
    function _validateFmvForPack(
        address assetNFT,
        uint256 tokenId,
        uint256 packId,
        uint8 tier
    ) private view {
        uint256 fmv = IAssetNFT(assetNFT).getAppraisalValue(tokenId);
        (uint128[6] memory minFmv, uint128[6] memory maxFmv) = _registry()
            .getPackTierFmvBounds(address(this), packId);
        // (0,0) means unset — reject the deposit.
        if (maxFmv[tier] == 0) revert PackMachine__TierFmvUnset(packId, tier);
        if (fmv < minFmv[tier] || fmv > maxFmv[tier])
            revert PackMachine__FmvOutOfRange(tokenId, packId, tier, fmv);
    }

    /// @dev Return the index (0-based) of the lowest set bit in x. x must be != 0.
    function _lsb(uint256 x) private pure returns (uint256 pos) {
        // Isolate lowest set bit then count trailing zeros.
        uint256 bit = x & (~x + 1);
        // De Bruijn sequence method is overkill; simple linear scan is fine for <= 256 bits
        // and will be called at most ~3 times per token in practice (small popcount).
        while (bit > 1) {
            bit >>= 1;
            ++pos;
        }
    }

    // =========================================================================
    // Admin — eligibility setters
    // =========================================================================

    /// @notice Add or remove a single pack's eligibility for a batch of tokens.
    ///         When adding, a tier must be supplied for each token (per-pack tier model).
    ///         Idempotent on removal; on addition, re-specifying with a different tier re-slots
    ///         the token.
    ///         Primary use: `addPack(Elite)` → `setPackEligibility(elitePackId, tokenIds, tiers, true)`.
    /// @param packId   Target pack index (must be < current pack count).
    /// @param tokenIds In-custody token IDs to update (max 50).
    /// @param tiers    Tier per token in this pack (ignored when eligible=false).
    /// @param eligible True to add eligibility, false to remove.
    function setPackEligibility(
        uint256 packId,
        uint256[] calldata tokenIds,
        uint8[] calldata tiers,
        bool eligible
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (tokenIds.length > MAX_BATCH)
            revert PackMachine__BatchTooLarge(tokenIds.length, MAX_BATCH);
        if (eligible && tokenIds.length != tiers.length)
            revert PackMachine__ArrayLengthMismatch();

        PackMachineStorage storage $ = _getStorage();
        uint256 packCount = _registry().getPackCount(address(this));
        if (packId >= packCount) revert PackMachine__InvalidPackRef(packId);

        address assetNFT = $.assetNFT;
        uint256 bit = uint256(1) << packId;

        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (!$.inCustody[tokenId])
                revert PackMachine__TokenNotInCustody(tokenId);

            uint256 oldMask = $.eligibility[tokenId];

            if (eligible) {
                uint8 t = tiers[i];
                if (t >= NUM_TIERS) revert PackMachine__InvalidTier(t);
                _validateFmvForPack(assetNFT, tokenId, packId, t);
                if (oldMask & bit != 0) {
                    // Already eligible — re-slot if tier changed.
                    uint8 oldTier = $.packTokenTier[tokenId][packId];
                    if (oldTier != t) {
                        _removeFromPackPool($, tokenId, packId, oldTier);
                        _addToPackPool($, tokenId, packId, t);
                        $.packTokenTier[tokenId][packId] = t;
                    }
                } else {
                    $.eligibility[tokenId] = oldMask | bit;
                    $.packTokenTier[tokenId][packId] = t;
                    _addToPackPool($, tokenId, packId, t);
                }
            } else {
                if (oldMask & bit == 0) continue; // already absent — no-op
                uint8 oldTier = $.packTokenTier[tokenId][packId];
                $.eligibility[tokenId] = oldMask & ~bit;
                _removeFromPackPool($, tokenId, packId, oldTier);
                delete $.packTokenTier[tokenId][packId];
                if ($.availablePerPack[packId] > 0)
                    $.availablePerPack[packId]--;
            }
        }
    }

    // =========================================================================
    // Views — per-pack eligibility
    // =========================================================================

    /// @notice Eligibility bitmask for a token (dormant when token is not in custody).
    function getTokenEligibility(
        uint256 tokenId
    ) external view returns (uint256) {
        return _getStorage().eligibility[tokenId];
    }

    /// @notice Whether a specific token is eligible for a specific pack AND currently in custody.
    function isTokenEligibleForPack(
        uint256 tokenId,
        uint256 packId
    ) external view returns (bool) {
        PackMachineStorage storage $ = _getStorage();
        return
            $.inCustody[tokenId] &&
            ($.eligibility[tokenId] & (uint256(1) << packId)) != 0;
    }

    /// @notice Number of in-custody tokens eligible for packId in a given tier.
    function getPackTierPoolSize(
        uint256 packId,
        uint8 tier
    ) external view returns (uint256) {
        if (tier >= NUM_TIERS) revert PackMachine__InvalidTier(tier);
        return _getStorage().packTierPools[packId][tier].length;
    }

    /// @notice Available counter for packId (eligible tokens minus pending reservations).
    function getPackAvailable(uint256 packId) external view returns (uint256) {
        return _getStorage().availablePerPack[packId];
    }

    /// @notice Whether a token is currently held by this machine.
    function isInCustody(uint256 tokenId) external view returns (bool) {
        return _getStorage().inCustody[tokenId];
    }

    // =========================================================================
    // Admin escape hatch (updated for new pools)
    // =========================================================================

    /// @notice Resets availablePerPack for all packs to actual per-pack pool sizes, and
    ///         resets effectivePrizePoolSize to the sum of all per-pack pool sizes.
    ///         Note: if tokens are eligible for multiple packs, effectivePrizePoolSize will
    ///         over-count (each token counted once per eligible pack). This is a conservative
    ///         estimate — it prevents the withdrawal guard from blocking valid withdrawals.
    ///         The primary open-gate guard is per-pack availablePerPack, which is exact.
    ///         Requires the machine to be paused.
    function resetEffectivePrizePoolSize()
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
    {
        if (!paused()) revert PackMachine__NotPaused();
        PackMachineStorage storage $ = _getStorage();

        if ($.pendingRequestCount != 0)
            revert PackMachine__PendingRequests($.pendingRequestCount);

        // Recompute per-pack available from pool sizes (no pending reservations while paused).
        uint256 packCount = _registry().getPackCount(address(this));
        uint256 machineTotal;
        for (uint256 p; p < packCount; ++p) {
            uint256 packTotal;
            for (uint256 t; t < NUM_TIERS; ++t) {
                packTotal += $.packTierPools[p][t].length;
            }
            $.availablePerPack[p] = packTotal;
            machineTotal += packTotal;
        }
        // Use the pack-0 pool size as the machine-wide counter when there is only one pack,
        // otherwise fall back to the summed total (conservative over-count for multi-pack tokens).
        $.effectivePrizePoolSize =
            packCount == 1 ? $.availablePerPack[0] : machineTotal;
    }
}
