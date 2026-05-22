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
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";
import {IPackVRFRouter} from "./interfaces/IPackVRFRouter.sol";
import {ISignatureTransfer} from "./interfaces/ISignatureTransfer.sol";
import {IBuybackPool} from "./interfaces/IBuybackPool.sol";

/// @title PackMachine
/// @author NettyWorth
/// @notice EIP-1167 clone instance. Users pay USDC to open a pack of randomly selected AssetNFTs.
///         Randomness is provided by Chainlink VRF v2.5 via the shared PackVRFRouter.
///         Prize selection uses weighted probability across five rarity tiers (Base/Common/Uncommon/Rare/Ultra).
/// @dev Deployed by PackMachineFactory via Clones.clone(). Not UUPS-upgradeable (clone pattern).
///      Uses ERC-7201 namespaced storage to avoid slot collisions in the shared implementation.
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
    bytes32 private constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 nonce)"
    );

    uint256 private constant NUM_TIERS = 5;

    /// @dev Tier weights are expressed in basis points; all five must sum to this value.
    uint16 private constant WEIGHT_PRECISION = 10000;

    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.PackMachine
    struct PackMachineStorage {
        address factory;
        address assetNFT;
        uint128 pricePerPack;
        uint8 cardsPerPack;
        uint40 startTime;
        bool isFinished;
        /// @dev One prize pool per tier: index 0=Base, 1=Common, 2=Uncommon, 3=Rare, 4=Ultra.
        uint256[][5] tierPools;
        /// @dev Weights in basis points per tier. Must sum to WEIGHT_PRECISION (10000).
        uint16[5] tierWeights;
        /// @dev Reverse lookup: which tier a deposited token belongs to (for withdrawal).
        mapping(uint256 tokenId => uint8 tier) tokenTiers;
        uint256 effectivePrizePoolSize;
        mapping(uint256 requestId => PendingOpen) pendingOpens;
        mapping(address user => uint256) openNonces;
        // === Cut-off Logic ===
        /// @dev Total cards ever deposited by operators (monotonically increasing; re-deposits excluded).
        uint256 totalInventory;
        /// @dev Machine-wide retention threshold bps (e.g. 6000 = 60%). Sales stop when
        ///      effectivePrizePoolSize / totalInventory < threshold.
        uint16 retentionThresholdBps;
        // === Payment Split & Buyback ===
        /// @dev Basis points of pricePerPack allocated to BuybackPool (0-10000).
        uint16 buybackAllocationBps;
        /// @dev BuybackPool contract address.
        address buybackPool;
        /// @dev Protection surcharge in basis points (e.g., 1000 = 10% extra, paid to treasury).
        uint16 protectionFeeBps;
        /// @dev Whether buyback protection was purchased for a given VRF request.
        mapping(uint256 requestId => bool) requestProtection;
    }

    struct PendingOpen {
        address user;
        uint8 cardsCount;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.PackMachine")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PACK_MACHINE_STORAGE_SLOT =
        0x7a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a00;

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
    event PriceUpdated(uint128 oldPrice, uint128 newPrice);
    event PackMachineStopped();
    event TierWeightsUpdated(uint16[5] weights);
    event BuybackAllocationUpdated(uint16 oldBps, uint16 newBps);
    event BuybackPoolUpdated(address indexed oldPool, address indexed newPool);
    event ProtectionFeeUpdated(uint16 oldBps, uint16 newBps);
    event RetentionThresholdUpdated(uint16 oldBps, uint16 newBps);

    // =========================================================================
    // Errors
    // =========================================================================

    error PackMachine__NotStarted();
    error PackMachine__Finished();
    error PackMachine__InsufficientPool(uint256 available, uint256 required);
    error PackMachine__NotPaused();
    error PackMachine__InvalidSignature();
    error PackMachine__BatchTooLarge(uint256 given, uint256 max);
    error PackMachine__OnlyVRFRouter(address caller);
    error PackMachine__ZeroAddress();
    error PackMachine__InvalidWeights(uint256 total);
    error PackMachine__InvalidTier(uint8 tier);
    error PackMachine__TokenNotInPool(uint256 tokenId);
    error PackMachine__ArrayLengthMismatch();
    error PackMachine__InvalidBps(uint16 given);
    error PackMachine__OnlyBuybackPool(address caller);
    error PackMachine__CutOff(uint256 retained, uint256 total);

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
    /// @param permissionManager_ Protocol PermissionManager address.
    /// @param factory_ PackMachineFactory address (payment & transfer-validator routing).
    /// @param pricePerPack_ USDC cost per pack (6-decimal precision).
    /// @param cardsPerPack_ Number of cards dispensed per pack open.
    /// @param startTime_ Unix timestamp from which pack opens are permitted.
    function initialize(
        address permissionManager_,
        address factory_,
        uint128 pricePerPack_,
        uint8 cardsPerPack_,
        uint40 startTime_
    ) external initializer {
        if (factory_ == address(0)) revert PackMachine__ZeroAddress();
        __PermissionConsumer_init(permissionManager_);
        __EIP712_init("PackMachine", "1");
        __Pausable_init();

        PackMachineStorage storage $ = _getStorage();
        $.factory = factory_;
        $.assetNFT = IPackMachineFactory(factory_).assetNFT();
        $.pricePerPack = pricePerPack_;
        $.cardsPerPack = cardsPerPack_;
        $.startTime = startTime_;
        // Default weights: Base 75% / Common 19.5% / Uncommon 4% / Rare 1% / Ultra 0.5%
        $.tierWeights = [uint16(7500), 1950, 400, 100, 50];
        // Default 60% machine-wide retention threshold.
        $.retentionThresholdBps = 6000;
        // Default 10% protection surcharge.
        $.protectionFeeBps = 1000;
        // buybackAllocationBps defaults to 0 (backwards-compatible; no split until configured).
    }

    // =========================================================================
    // Pack-open flows
    // =========================================================================

    /// @notice Open a pack by pulling USDC directly from `msg.sender`.
    /// @param user The recipient of the won cards (subject to blacklist check in AssetNFT).
    /// @param signature EIP-712 `OpenPack(address user, uint256 nonce)` signed by a PACK_OPERATOR_ROLE holder.
    /// @param withProtection Whether to purchase buyback protection (+protectionFeeBps surcharge to treasury).
    function openPack(
        address user,
        bytes calldata signature,
        bool withProtection
    ) external nonReentrant whenNotPaused {
        PackMachineStorage storage $ = _getStorage();
        _assertOpenable($);
        _verifySignature($, user, signature);
        _handlePayment($, _msgSender(), withProtection);
        _requestVRF($, user, IPackMachineFactory($.factory), withProtection);
    }

    /// @notice Open a pack paying via Uniswap Permit2 (gasless for user — relayer pays gas).
    /// @param user The recipient of the won cards.
    /// @param permit2Nonce Permit2 nonce (unique per permit).
    /// @param permit2Deadline Permit2 expiry timestamp.
    /// @param permit2Signature Permit2 authorization signature from `user`.
    /// @param playSignature EIP-712 `OpenPack` signature from a PACK_OPERATOR_ROLE holder.
    /// @param withProtection Whether to purchase buyback protection (+protectionFeeBps surcharge to treasury).
    function openPackWithPermit2(
        address user,
        uint256 permit2Nonce,
        uint256 permit2Deadline,
        bytes calldata permit2Signature,
        bytes calldata playSignature,
        bool withProtection
    ) external nonReentrant whenNotPaused {
        PackMachineStorage storage $ = _getStorage();
        _assertOpenable($);
        _verifySignature($, user, playSignature);

        IPackMachineFactory iFactory = IPackMachineFactory($.factory);
        uint256 price = $.pricePerPack;
        uint256 protectionFee =
            withProtection
                ? (price * $.protectionFeeBps) / WEIGHT_PRECISION
                : 0;
        uint256 totalAmount = price + protectionFee;
        uint256 buybackAmount =
            (price * $.buybackAllocationBps) / WEIGHT_PRECISION;
        address pool = $.buybackPool;

        // Pull full amount to this contract, then distribute.
        PERMIT2.permitTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({
                    token: iFactory.paymentToken(),
                    amount: totalAmount
                }),
                nonce: permit2Nonce,
                deadline: permit2Deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({
                to: address(this),
                requestedAmount: totalAmount
            }),
            user,
            permit2Signature
        );

        IERC20 token = IERC20(iFactory.paymentToken());
        if (buybackAmount > 0 && pool != address(0)) {
            token.safeTransfer(pool, buybackAmount);
        } else {
            buybackAmount = 0;
        }
        token.safeTransfer(
            iFactory.financeWallet(),
            totalAmount - buybackAmount
        );

        _requestVRF($, user, iFactory, withProtection);
    }

    // =========================================================================
    // VRF callback
    // =========================================================================

    /// @notice Called by PackVRFRouter to deliver random words and complete a pack open.
    /// @dev Must only be callable by the trusted PackVRFRouter.
    function fulfillRandomness(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external nonReentrant {
        PackMachineStorage storage $ = _getStorage();
        address vrfRouter = IPackMachineFactory($.factory).packVRFRouter();
        if (msg.sender != vrfRouter)
            revert PackMachine__OnlyVRFRouter(msg.sender);

        PendingOpen memory pending = $.pendingOpens[requestId];
        delete $.pendingOpens[requestId];

        bool hasProtection = $.requestProtection[requestId];
        if (hasProtection) delete $.requestProtection[requestId];

        IPackMachineFactory iFactory = IPackMachineFactory($.factory);
        address assetNFT = $.assetNFT;
        address pool = $.buybackPool;
        bool poolActive = pool != address(0) && $.buybackAllocationBps > 0;

        iFactory.beforeTransfer(assetNFT);

        for (uint256 i; i < pending.cardsCount; ++i) {
            uint256 word = randomWords[i];

            // Compute active weights — exclude empty tiers only.
            uint16[5] memory activeWeights;
            uint256 totalActiveWeight;
            for (uint256 t; t < NUM_TIERS; ++t) {
                if ($.tierPools[t].length == 0) continue;
                activeWeights[t] = $.tierWeights[t];
                totalActiveWeight += $.tierWeights[t];
            }

            if (totalActiveWeight == 0) {
                // All tiers unexpectedly empty or cut off — restore the reservation and skip.
                $.effectivePrizePoolSize++;
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

            // Select token within the tier using lower 128 bits.
            uint256 selectedPoolLen = $.tierPools[selectedTier].length;
            uint256 index = uint128(word) % selectedPoolLen;
            uint256 tokenId = $.tierPools[selectedTier][index];
            _swapAndPopTier($, selectedTier, index);
            delete $.tokenTiers[tokenId];

            try
                IERC721(assetNFT).transferFrom(
                    address(this),
                    pending.user,
                    tokenId
                )
            {
                emit CardWon(pending.user, tokenId, requestId);
                // Register with BuybackPool so the user can sell the card back.
                if (poolActive) {
                    IBuybackPool(pool).registerToken(
                        tokenId,
                        uint128(uint256($.pricePerPack) / $.cardsPerPack),
                        uint8(selectedTier),
                        hasProtection,
                        address(this)
                    );
                }
            } catch {
                // Return the card to its tier pool so it can be won by future users.
                $.tierPools[selectedTier].push(tokenId);
                $.tokenTiers[tokenId] = uint8(selectedTier);
                $.effectivePrizePoolSize++;
                emit CardFailed(pending.user, tokenId, requestId);
            }
        }

        iFactory.afterTransfer(assetNFT);
        emit PackOpened(pending.user, requestId, $.pricePerPack);
    }

    // =========================================================================
    // Admin — deposit / withdraw
    // =========================================================================

    /// @notice Deposit AssetNFTs into tiered prize pools. Caller must have approved this contract.
    /// @param tokenIds Array of token IDs to deposit (max 50).
    /// @param tiers Rarity tier for each token (0=Base, 1=Common, 2=Uncommon, 3=Rare, 4=Ultra).
    /// @param tokensOwner Current owner of the tokens (must have approved this contract).
    function deposit(
        uint256[] calldata tokenIds,
        uint8[] calldata tiers,
        address tokensOwner
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        uint256 count = tokenIds.length;
        if (count != tiers.length) revert PackMachine__ArrayLengthMismatch();
        if (count > MAX_BATCH)
            revert PackMachine__BatchTooLarge(count, MAX_BATCH);
        if (count == 0) return;

        PackMachineStorage storage $ = _getStorage();
        address assetNFT = $.assetNFT;

        IPackMachineFactory($.factory).beforeTransfer(assetNFT);
        for (uint256 i; i < count; ++i) {
            uint8 tier = tiers[i];
            if (tier >= NUM_TIERS) revert PackMachine__InvalidTier(tier);
            uint256 tokenId = tokenIds[i];
            $.tierPools[tier].push(tokenId);
            $.tokenTiers[tokenId] = tier;
            IERC721(assetNFT).transferFrom(tokensOwner, address(this), tokenId);
        }
        IPackMachineFactory($.factory).afterTransfer(assetNFT);

        $.effectivePrizePoolSize += count;
        $.totalInventory += count;
        emit CardsDeposited(_msgSender(), count);
    }

    /// @notice Re-deposit NFTs from BuybackPool back into tier pools.
    /// @dev Only callable by the configured BuybackPool address. Does NOT update peak pool sizes.
    /// @param tokenIds Array of token IDs to deposit (max 50).
    /// @param tiers Rarity tier for each token (0=Base, 1=Common, 2=Uncommon, 3=Rare, 4=Ultra).
    /// @param tokensOwner Current owner of the tokens (the BuybackPool, must have approved this contract).
    function depositFromPool(
        uint256[] calldata tokenIds,
        uint8[] calldata tiers,
        address tokensOwner
    ) external {
        PackMachineStorage storage $ = _getStorage();
        if (msg.sender != $.buybackPool)
            revert PackMachine__OnlyBuybackPool(msg.sender);

        uint256 count = tokenIds.length;
        if (count != tiers.length) revert PackMachine__ArrayLengthMismatch();
        if (count > MAX_BATCH)
            revert PackMachine__BatchTooLarge(count, MAX_BATCH);
        if (count == 0) return;

        address assetNFT = $.assetNFT;

        IPackMachineFactory($.factory).beforeTransfer(assetNFT);
        for (uint256 i; i < count; ++i) {
            uint8 tier = tiers[i];
            if (tier >= NUM_TIERS) revert PackMachine__InvalidTier(tier);
            uint256 tokenId = tokenIds[i];
            $.tierPools[tier].push(tokenId);
            $.tokenTiers[tokenId] = tier;
            IERC721(assetNFT).transferFrom(tokensOwner, address(this), tokenId);
            // Intentionally does NOT increment totalInventory — re-deposits don't count as new inventory.
        }
        IPackMachineFactory($.factory).afterTransfer(assetNFT);

        $.effectivePrizePoolSize += count;
        emit CardsDeposited(msg.sender, count);
    }

    /// @notice Withdraw specific cards by token ID. Requires contract to be paused.
    /// @param tokenIds Token IDs to withdraw (max 50). Each must currently be in a tier pool.
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
            uint8 tier = $.tokenTiers[tokenId];
            if (!_removeFromTierPool($, tier, tokenId))
                revert PackMachine__TokenNotInPool(tokenId);
            delete $.tokenTiers[tokenId];
            IERC721(assetNFT).transferFrom(address(this), recipient, tokenId);
        }
        IPackMachineFactory($.factory).afterTransfer(assetNFT);

        $.effectivePrizePoolSize -= count;
        emit CardsWithdrawn(recipient, count);
    }

    // =========================================================================
    // Admin — configuration
    // =========================================================================

    /// @notice Update the weighted probability table. Weights must sum to 10000 basis points.
    /// @param weights Five weights in basis points: [Base, Common, Uncommon, Rare, Ultra].
    function setTierWeights(
        uint16[5] calldata weights
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        uint256 total;
        for (uint256 i; i < NUM_TIERS; ++i) {
            total += weights[i];
        }
        if (total != WEIGHT_PRECISION)
            revert PackMachine__InvalidWeights(total);
        _getStorage().tierWeights = weights;
        emit TierWeightsUpdated(weights);
    }

    function setPrice(
        uint128 newPrice
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (!paused()) revert PackMachine__NotPaused();
        PackMachineStorage storage $ = _getStorage();
        emit PriceUpdated($.pricePerPack, newPrice);
        $.pricePerPack = newPrice;
    }

    /// @notice Set the BuybackPool contract address.
    function setBuybackPool(
        address pool
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        PackMachineStorage storage $ = _getStorage();
        emit BuybackPoolUpdated($.buybackPool, pool);
        $.buybackPool = pool;
    }

    /// @notice Set the percentage of pricePerPack routed to BuybackPool.
    /// @param bps Basis points (0-10000). 0 disables the split.
    function setBuybackAllocation(
        uint16 bps
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (bps > WEIGHT_PRECISION) revert PackMachine__InvalidBps(bps);
        PackMachineStorage storage $ = _getStorage();
        emit BuybackAllocationUpdated($.buybackAllocationBps, bps);
        $.buybackAllocationBps = bps;
    }

    /// @notice Set the protection fee surcharge in basis points.
    /// @param bps Basis points added on top of pricePerPack when withProtection=true (cap: 5000).
    function setProtectionFee(
        uint16 bps
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (bps > 5000) revert PackMachine__InvalidBps(bps);
        PackMachineStorage storage $ = _getStorage();
        emit ProtectionFeeUpdated($.protectionFeeBps, bps);
        $.protectionFeeBps = bps;
    }

    /// @notice Set the machine-wide retention threshold.
    /// @param bps Sales are blocked when effectivePrizePoolSize/totalInventory < bps/10000. (0 = disabled).
    function setRetentionThreshold(
        uint16 bps
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (bps > WEIGHT_PRECISION) revert PackMachine__InvalidBps(bps);
        PackMachineStorage storage $ = _getStorage();
        emit RetentionThresholdUpdated($.retentionThresholdBps, bps);
        $.retentionThresholdBps = bps;
    }

    function pause() external onlyProtocolRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyProtocolRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Permanently stop this pack machine. Cannot be undone.
    function stop() external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        _getStorage().isFinished = true;
        _pause();
        emit PackMachineStopped();
    }

    /// @notice Recover ERC-20 tokens accidentally sent to this contract.
    function rescueERC20(
        address token
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(_msgSender(), balance);
    }

    /// @notice Admin escape hatch to reconcile effectivePrizePoolSize with actual pool lengths
    ///         if VRF requests are permanently stuck (e.g. Chainlink outage).
    ///         Requires the machine to be paused so no new opens can race the reset.
    function resetEffectivePrizePoolSize()
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
    {
        if (!paused()) revert PackMachine__NotPaused();
        PackMachineStorage storage $ = _getStorage();
        uint256 total;
        for (uint256 t; t < NUM_TIERS; ++t) {
            total += $.tierPools[t].length;
        }
        $.effectivePrizePoolSize = total;
    }

    // =========================================================================
    // Views
    // =========================================================================

    function pricePerPack() external view returns (uint128) {
        return _getStorage().pricePerPack;
    }

    function cardsPerPack() external view returns (uint8) {
        return _getStorage().cardsPerPack;
    }

    function effectivePrizePoolSize() external view returns (uint256) {
        return _getStorage().effectivePrizePoolSize;
    }

    function getTierWeights() external view returns (uint16[5] memory) {
        return _getStorage().tierWeights;
    }

    function getTierPoolSize(uint8 tier) external view returns (uint256) {
        if (tier >= NUM_TIERS) revert PackMachine__InvalidTier(tier);
        return _getStorage().tierPools[tier].length;
    }

    function getTierPool(uint8 tier) external view returns (uint256[] memory) {
        if (tier >= NUM_TIERS) revert PackMachine__InvalidTier(tier);
        return _getStorage().tierPools[tier];
    }

    function factory() external view returns (address) {
        return _getStorage().factory;
    }

    function openNonce(address user) external view returns (uint256) {
        return _getStorage().openNonces[user];
    }

    function getBuybackPool() external view returns (address) {
        return _getStorage().buybackPool;
    }

    function getBuybackAllocationBps() external view returns (uint16) {
        return _getStorage().buybackAllocationBps;
    }

    function getProtectionFeeBps() external view returns (uint16) {
        return _getStorage().protectionFeeBps;
    }

    function getRetentionThresholdBps() external view returns (uint16) {
        return _getStorage().retentionThresholdBps;
    }

    function getTotalInventory() external view returns (uint256) {
        return _getStorage().totalInventory;
    }

    function isCutOff() external view returns (bool) {
        PackMachineStorage storage $ = _getStorage();
        if ($.totalInventory == 0 || $.retentionThresholdBps == 0) return false;
        return
            $.effectivePrizePoolSize * WEIGHT_PRECISION <
            $.totalInventory * uint256($.retentionThresholdBps);
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

    function _assertOpenable(PackMachineStorage storage $) private view {
        if ($.isFinished) revert PackMachine__Finished();
        if (block.timestamp < $.startTime) revert PackMachine__NotStarted();
        if ($.effectivePrizePoolSize < $.cardsPerPack) {
            revert PackMachine__InsufficientPool(
                $.effectivePrizePoolSize,
                $.cardsPerPack
            );
        }
        // Machine-wide cut-off: block sales if retained inventory < threshold.
        if ($.totalInventory > 0 && $.retentionThresholdBps > 0) {
            if (
                $.effectivePrizePoolSize * WEIGHT_PRECISION <
                $.totalInventory * uint256($.retentionThresholdBps)
            ) {
                revert PackMachine__CutOff(
                    $.effectivePrizePoolSize,
                    $.totalInventory
                );
            }
        }
    }

    function _verifySignature(
        PackMachineStorage storage $,
        address user,
        bytes calldata signature
    ) private {
        uint256 nonce = $.openNonces[user]++;
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(OPEN_PACK_TYPEHASH, user, nonce))
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

    function _handlePayment(
        PackMachineStorage storage $,
        address payer,
        bool withProtection
    ) private {
        IPackMachineFactory iFactory = IPackMachineFactory($.factory);
        IERC20 token = IERC20(iFactory.paymentToken());
        uint256 price = $.pricePerPack;

        uint256 protectionFee =
            withProtection
                ? (price * $.protectionFeeBps) / WEIGHT_PRECISION
                : 0;
        uint256 totalAmount = price + protectionFee;

        uint256 buybackAmount =
            (price * $.buybackAllocationBps) / WEIGHT_PRECISION;
        address pool = $.buybackPool;

        if (buybackAmount > 0 && pool != address(0)) {
            token.safeTransferFrom(payer, pool, buybackAmount);
        } else {
            buybackAmount = 0;
        }
        token.safeTransferFrom(
            payer,
            iFactory.financeWallet(),
            totalAmount - buybackAmount
        );
    }

    function _requestVRF(
        PackMachineStorage storage $,
        address user,
        IPackMachineFactory factory_,
        bool withProtection
    ) private {
        uint8 cards = $.cardsPerPack;
        $.effectivePrizePoolSize -= cards;

        uint256 requestId = IPackVRFRouter(factory_.packVRFRouter())
            .requestRandomWords(user, cards);
        $.pendingOpens[requestId] = PendingOpen({
            user: user,
            cardsCount: cards
        });
        if (withProtection) {
            $.requestProtection[requestId] = true;
        }
    }

    function _swapAndPopTier(
        PackMachineStorage storage $,
        uint256 tier,
        uint256 index
    ) private {
        uint256 last = $.tierPools[tier].length - 1;
        if (index != last) {
            $.tierPools[tier][index] = $.tierPools[tier][last];
        }
        $.tierPools[tier].pop();
    }

    /// @dev Linear scan to find and remove a specific tokenId from a tier pool. O(n) but only
    ///      used during paused admin withdrawal (max 50 tokens per call, pools bounded in practice).
    function _removeFromTierPool(
        PackMachineStorage storage $,
        uint256 tier,
        uint256 tokenId
    ) private returns (bool) {
        uint256 len = $.tierPools[tier].length;
        for (uint256 j; j < len; ++j) {
            if ($.tierPools[tier][j] == tokenId) {
                _swapAndPopTier($, tier, j);
                return true;
            }
        }
        return false;
    }
}
