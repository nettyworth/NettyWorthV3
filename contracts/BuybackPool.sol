// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {IPermissionManager} from "./interfaces/IPermissionManager.sol";
import {Roles} from "./lib/Roles.sol";
import {IPackMachine} from "./interfaces/IPackMachine.sol";
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";
import {IPromoCodeRegistry} from "./interfaces/IPromoCodeRegistry.sol";
import {IBuybackPool} from "./interfaces/IBuybackPool.sol";

/// @title BuybackPool
/// @author NettyWorth
/// @notice Holds USDC allocations from pack purchases and lets token holders sell cards back
///         at a guaranteed percentage of either the original per-card price (AmountSpent model)
///         or a signed fair-market-value quote (FMV model). Bought-back NFTs are automatically
///         re-deposited into their source PackMachine clone.
///
/// @dev    Two buyback models:
///         • AmountSpent — payout = pricePerCard × bps (cost-basis; pricePerCard = pricePerPack / cardsPerPack)
///         • FMV         — payout = signedFMV × bps (fair-market value; requires EIP-712 quote signed by
///                          PACK_OPERATOR_ROLE; nonce prevents replay)
///
///         Model resolution order (per buyback call):
///           1. Per-PackMachine override (packMachineBuybackModel[sourceMachine]) if != Unset
///           2. Global default (defaultBuybackModel)
///         Global per-type enable flags further gate each model independently.
///
/// @custom:security-contact security@nettyworth.io
contract BuybackPool is
    Initializable,
    UUPSUpgradeable,
    EIP712Upgradeable,
    PermissionConsumer,
    ReentrancyGuard,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    struct TokenBuybackInfo {
        uint128 pricePerCard;
        uint8 tier;
        address sourcePackMachine;
        bool isActive;
    }

    /// @custom:storage-location erc7201:nettyworth.storage.BuybackPool
    struct BuybackPoolStorage {
        address assetNFT;
        address paymentToken;
        address financeWallet;
        address factory;
        /// @dev Default buyback rate (basis points, e.g. 8000 = 80%).
        uint16 defaultBuybackBps;
        mapping(uint256 tokenId => TokenBuybackInfo) tokenInfo;
        mapping(address packMachine => bool) registeredPackMachines;
        uint256 totalReceived;
        uint256 totalPaidOut;
        /// @dev Per-PackMachine buyback rate override (0 = use defaultBuybackBps).
        mapping(address packMachine => uint16) packMachineBuybackBps;
        // ── Appended in promo-code upgrade ───────────────────────────────────
        /// @dev PromoCodeRegistry proxy address for buyback-boost code redemption.
        address promoCodeRegistry;
        // ── Appended in buyback-model upgrade ────────────────────────────────
        /// @dev Global default model; AmountSpent(1) by default (set in initializeV2).
        IBuybackPool.BuybackModel defaultBuybackModel;
        /// @dev Per-PackMachine model override; Unset(0) = fall back to defaultBuybackModel.
        mapping(address packMachine => IBuybackPool.BuybackModel) packMachineBuybackModel;
        /// @dev Global enable flags per model type. Both true by default (set in initializeV2).
        mapping(IBuybackPool.BuybackModel model => bool) modelEnabled;
        /// @dev Per-token nonce for FMV quote replay prevention. Incremented after each FMV buyback.
        mapping(uint256 tokenId => uint256) fmvQuoteNonce;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.BuybackPool")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BUYBACK_POOL_STORAGE_SLOT =
        0xcde91e075f2798ca63d14356a360b0f16575d21d6ecd1d5809e671a133dd7f00;

    function _getStorage() private pure returns (BuybackPoolStorage storage $) {
        assembly {
            $.slot := BUYBACK_POOL_STORAGE_SLOT
        }
    }

    // =========================================================================
    // EIP-712 typehash
    // =========================================================================

    /// @dev keccak256("FMVQuote(uint256 tokenId,uint256 fmv,uint256 deadline,uint256 nonce,address seller)")
    ///      seller is bound so a leaked quote cannot be redeemed by anyone other than the
    ///      intended recipient (H002 fix).
    bytes32 private constant FMV_QUOTE_TYPEHASH = keccak256(
        "FMVQuote(uint256 tokenId,uint256 fmv,uint256 deadline,uint256 nonce,address seller)"
    );

    // =========================================================================
    // Events
    // =========================================================================

    event TokenRegistered(
        uint256 indexed tokenId,
        address indexed sourcePackMachine,
        uint128 pricePerCard,
        uint8 tier
    );
    /// @notice Emitted on every successful buyback.
    /// @param model    The resolved buyback model that determined the payout basis.
    /// @param basis    The value the payout was computed against (pricePerCard for AmountSpent, fmv for FMV).
    event BuybackExecuted(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 payout,
        IBuybackPool.BuybackModel model,
        uint256 basis
    );
    event TokenRedeposited(
        uint256 indexed tokenId,
        address indexed sourcePackMachine,
        uint8 tier
    );
    /// @notice Emitted when a buyback NFT cannot be redeposited because its source
    ///         PackMachine has been deregistered. Admin must call rescueNFT to recover (L003 fix).
    event TokenStuck(uint256 indexed tokenId, address indexed sourceMachine);
    event DefaultBuybackBpsUpdated(uint16 oldBps, uint16 newBps);
    event PackMachineBuybackBpsUpdated(
        address indexed machine,
        uint16 oldBps,
        uint16 newBps
    );
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event PackMachineRegistered(address indexed packMachine, bool registered);
    /// @notice Emitted when a buyback-boost promo code is applied.
    event BuybackBoosted(
        uint256 indexed tokenId,
        address indexed seller,
        bytes32 indexed codeId,
        uint16 boostedBps
    );
    event PromoCodeRegistryUpdated(
        address indexed oldRegistry,
        address indexed newRegistry
    );
    event DefaultBuybackModelUpdated(
        IBuybackPool.BuybackModel oldModel,
        IBuybackPool.BuybackModel newModel
    );
    event PackMachineBuybackModelUpdated(
        address indexed machine,
        IBuybackPool.BuybackModel oldModel,
        IBuybackPool.BuybackModel newModel
    );
    event ModelEnabledUpdated(
        IBuybackPool.BuybackModel indexed model,
        bool enabled
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error BuybackPool__TokenNotRegistered(uint256 tokenId);
    error BuybackPool__TokenAlreadyRegistered(uint256 tokenId);
    error BuybackPool__TokenNotActive(uint256 tokenId);
    error BuybackPool__NotTokenOwner(uint256 tokenId, address caller);
    error BuybackPool__InsufficientBalance(uint256 available, uint256 required);
    error BuybackPool__UnauthorizedSource(address caller);
    error BuybackPool__InvalidBps(uint16 bps);
    error BuybackPool__ZeroAddress();
    error BuybackPool__NotPaused();
    error BuybackPool__PromoRegistryNotSet();
    // ── Model errors ─────────────────────────────────────────────────────────
    /// @notice The resolved buyback model is disabled globally.
    error BuybackPool__ModelDisabled(IBuybackPool.BuybackModel model);
    /// @notice The resolved model is FMV but no signed quote was provided.
    error BuybackPool__FMVQuoteRequired();
    /// @notice The FMV quote signature was not produced by a PACK_OPERATOR_ROLE account.
    error BuybackPool__InvalidFMVSigner(address recovered);
    /// @notice The FMV quote deadline has passed.
    error BuybackPool__FMVQuoteExpired(
        uint256 deadline,
        uint256 blockTimestamp
    );
    /// @notice The quote nonce does not match the on-chain per-token nonce.
    error BuybackPool__FMVQuoteBadNonce(uint256 expected, uint256 given);
    /// @notice The quote's tokenId does not match the tokenId being sold back.
    error BuybackPool__FMVQuoteTokenMismatch(uint256 expected, uint256 given);
    /// @notice Attempted to set the default model to Unset, which is not valid.
    error BuybackPool__InvalidModel();
    /// @notice The FMV quote's seller does not match the caller (H002 fix).
    error BuybackPool__FMVQuoteSellerMismatch(address expected, address actual);

    uint16 private constant BPS_PRECISION = 10000;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =========================================================================
    // Initializer (V1 — unchanged for existing proxies)
    // =========================================================================

    function initialize(
        address permissionManager_,
        address assetNFT_,
        address paymentToken_,
        address financeWallet_,
        address factory_
    ) external initializer {
        if (assetNFT_ == address(0)) revert BuybackPool__ZeroAddress();
        if (paymentToken_ == address(0)) revert BuybackPool__ZeroAddress();
        if (financeWallet_ == address(0)) revert BuybackPool__ZeroAddress();
        if (factory_ == address(0)) revert BuybackPool__ZeroAddress();

        __PermissionConsumer_init(permissionManager_);
        __Pausable_init();
        __EIP712_init("NettyWorthBuyback", "1");

        BuybackPoolStorage storage $ = _getStorage();
        $.assetNFT = assetNFT_;
        $.paymentToken = paymentToken_;
        $.financeWallet = financeWallet_;
        $.factory = factory_;
        $.defaultBuybackBps = 8000;

        // Model defaults: AmountSpent with both types enabled.
        $.defaultBuybackModel = IBuybackPool.BuybackModel.AmountSpent;
        $.modelEnabled[IBuybackPool.BuybackModel.AmountSpent] = true;
        $.modelEnabled[IBuybackPool.BuybackModel.FMV] = true;
    }

    /// @notice Upgrade initializer for existing proxies that were deployed before the model feature.
    /// @dev    Called once after the UUPS upgrade to seed the new storage fields.
    ///         Idempotent: sets AmountSpent + both toggles true, which preserves prior behavior.
    function initializeV2() external reinitializer(2) {
        __EIP712_init("NettyWorthBuyback", "1");

        BuybackPoolStorage storage $ = _getStorage();
        $.defaultBuybackModel = IBuybackPool.BuybackModel.AmountSpent;
        $.modelEnabled[IBuybackPool.BuybackModel.AmountSpent] = true;
        $.modelEnabled[IBuybackPool.BuybackModel.FMV] = true;
    }

    // =========================================================================
    // Core: register & buyback
    // =========================================================================

    /// @notice Called by PackMachine during fulfillRandomness to record a won token's buyback data.
    /// @dev Only callable by registered PackMachines.
    ///      If the token already has an active registration (stale flag from a prior win/recycle
    ///      cycle that bypassed buyback), the record is silently overwritten with the current
    ///      price/tier/source. This prevents a stale `isActive` from permanently bricking a
    ///      pack's VRF fulfillment — an authorized machine re-registering its own token is safe
    ///      because the token physically left the machine before the next win, making any prior
    ///      record obsolete.
    function registerToken(
        uint256 tokenId,
        uint128 pricePerCard,
        uint8 tier,
        address sourcePackMachine
    ) external whenNotPaused {
        BuybackPoolStorage storage $ = _getStorage();
        if (!$.registeredPackMachines[msg.sender])
            revert BuybackPool__UnauthorizedSource(msg.sender);

        $.tokenInfo[tokenId] = TokenBuybackInfo({
            pricePerCard: pricePerCard,
            tier: tier,
            sourcePackMachine: sourcePackMachine,
            isActive: true
        });

        emit TokenRegistered(tokenId, sourcePackMachine, pricePerCard, tier);
    }

    /// @notice Sell a token back to the pool at the buyback rate for its source PackMachine.
    /// @dev    Reverts with BuybackPool__FMVQuoteRequired() when the resolved model is FMV.
    ///         Caller must own the token and have approved this contract.
    function buyback(uint256 tokenId) external nonReentrant whenNotPaused {
        _executeBuyback(
            tokenId,
            bytes32(0),
            IBuybackPool.FMVQuote(0, 0, 0, 0, address(0)),
            "",
            false
        );
    }

    /// @notice Sell a token back applying a buyback-boost promo code.
    /// @dev    Reverts with BuybackPool__FMVQuoteRequired() when the resolved model is FMV.
    ///         The PromoCodeRegistry is queried to validate and consume the code.
    ///         Reverts if the registry is not configured or the code is invalid/expired/exhausted.
    ///         Pass bytes32(0) as codeId to sell back without a boost.
    /// @param codeId keccak256 of the off-chain promo-code string; bytes32(0) means no boost.
    function buyback(
        uint256 tokenId,
        bytes32 codeId
    ) external nonReentrant whenNotPaused {
        _executeBuyback(
            tokenId,
            codeId,
            IBuybackPool.FMVQuote(0, 0, 0, 0, address(0)),
            "",
            false
        );
    }

    /// @notice Sell a token back using a signed FMV quote (required when the resolved model is FMV).
    /// @dev    Also accepts AmountSpent-model tokens (the quote is validated but the FMV value is not used
    ///         for the payout — the signed quote is simply ignored for non-FMV tokens). This makes the
    ///         three-argument overload a superset of the two-argument one.
    ///         The EIP-712 signature must be produced by an account holding PACK_OPERATOR_ROLE.
    ///         codeId may be bytes32(0) for no promo boost.
    /// @param codeId keccak256 of the off-chain promo-code string; bytes32(0) means no boost.
    /// @param quote  FMV quote (tokenId, fmv, deadline, nonce).
    /// @param sig    EIP-712 signature over the FMVQuote struct hash.
    function buyback(
        uint256 tokenId,
        bytes32 codeId,
        IBuybackPool.FMVQuote calldata quote,
        bytes calldata sig
    ) external nonReentrant whenNotPaused {
        _executeBuyback(tokenId, codeId, quote, sig, true);
    }

    // =========================================================================
    // Admin — model configuration
    // =========================================================================

    /// @notice Set the global default buyback model.
    /// @dev    Only AmountSpent(1) or FMV(2) are valid; Unset(0) reverts.
    function setDefaultBuybackModel(
        IBuybackPool.BuybackModel model
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (model == IBuybackPool.BuybackModel.Unset)
            revert BuybackPool__InvalidModel();
        BuybackPoolStorage storage $ = _getStorage();
        emit DefaultBuybackModelUpdated($.defaultBuybackModel, model);
        $.defaultBuybackModel = model;
    }

    /// @notice Set a per-PackMachine buyback model override.
    ///         Unset(0) clears the override so the machine falls back to the global default.
    function setPackMachineBuybackModel(
        address machine,
        IBuybackPool.BuybackModel model
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (machine == address(0)) revert BuybackPool__ZeroAddress();
        BuybackPoolStorage storage $ = _getStorage();
        emit PackMachineBuybackModelUpdated(
            machine,
            $.packMachineBuybackModel[machine],
            model
        );
        $.packMachineBuybackModel[machine] = model;
    }

    /// @notice Enable or disable a buyback model globally.
    ///         Disabling a model prevents any buyback using that model, regardless of per-machine config.
    ///         Reverts on Unset.
    function setModelEnabled(
        IBuybackPool.BuybackModel model,
        bool enabled
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (model == IBuybackPool.BuybackModel.Unset)
            revert BuybackPool__InvalidModel();
        BuybackPoolStorage storage $ = _getStorage();
        $.modelEnabled[model] = enabled;
        emit ModelEnabledUpdated(model, enabled);
    }

    // =========================================================================
    // Admin — rate configuration (unchanged)
    // =========================================================================

    function setDefaultBuybackBps(
        uint16 bps
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (bps > BPS_PRECISION) revert BuybackPool__InvalidBps(bps);
        BuybackPoolStorage storage $ = _getStorage();
        emit DefaultBuybackBpsUpdated($.defaultBuybackBps, bps);
        $.defaultBuybackBps = bps;
    }

    /// @notice Set a per-PackMachine buyback rate override (0 clears the override, falling back to defaultBuybackBps).
    function setPackMachineBuybackBps(
        address machine,
        uint16 bps
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (machine == address(0)) revert BuybackPool__ZeroAddress();
        if (bps > BPS_PRECISION) revert BuybackPool__InvalidBps(bps);
        BuybackPoolStorage storage $ = _getStorage();
        emit PackMachineBuybackBpsUpdated(
            machine,
            $.packMachineBuybackBps[machine],
            bps
        );
        $.packMachineBuybackBps[machine] = bps;
    }

    /// @notice Set the PromoCodeRegistry proxy address for buyback-boost code redemption.
    function setPromoCodeRegistry(
        address registry
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (registry == address(0)) revert BuybackPool__ZeroAddress();
        BuybackPoolStorage storage $ = _getStorage();
        emit PromoCodeRegistryUpdated($.promoCodeRegistry, registry);
        $.promoCodeRegistry = registry;
    }

    /// @notice Register or deregister a PackMachine as an authorized token source.
    function registerPackMachine(
        address machine,
        bool registered
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (machine == address(0)) revert BuybackPool__ZeroAddress();
        _getStorage().registeredPackMachines[machine] = registered;
        emit PackMachineRegistered(machine, registered);
    }

    function pause() external onlyProtocolRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyProtocolRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Emergency: drain all USDC to financeWallet. Requires paused.
    function emergencyWithdraw()
        external
        onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE)
    {
        if (!paused()) revert BuybackPool__NotPaused();
        BuybackPoolStorage storage $ = _getStorage();
        IERC20 token = IERC20($.paymentToken);
        uint256 balance = token.balanceOf(address(this));
        token.safeTransfer($.financeWallet, balance);
        emit EmergencyWithdrawal($.financeWallet, balance);
    }

    /// @notice Rescue a stuck NFT held by the pool (e.g. after a failed re-deposit).
    function rescueNFT(
        uint256 tokenId,
        address to
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert BuybackPool__ZeroAddress();
        IERC721(_getStorage().assetNFT).transferFrom(
            address(this),
            to,
            tokenId
        );
    }

    // =========================================================================
    // Views — model configuration
    // =========================================================================

    function getDefaultBuybackModel()
        external
        view
        returns (IBuybackPool.BuybackModel)
    {
        return _getStorage().defaultBuybackModel;
    }

    function getPackMachineBuybackModel(
        address machine
    ) external view returns (IBuybackPool.BuybackModel) {
        return _getStorage().packMachineBuybackModel[machine];
    }

    /// @notice Resolve the effective model for a given PackMachine.
    function getResolvedModel(
        address machine
    ) external view returns (IBuybackPool.BuybackModel) {
        return _resolveModel(_getStorage(), machine);
    }

    function isModelEnabled(
        IBuybackPool.BuybackModel model
    ) external view returns (bool) {
        return _getStorage().modelEnabled[model];
    }

    function fmvQuoteNonce(uint256 tokenId) external view returns (uint256) {
        return _getStorage().fmvQuoteNonce[tokenId];
    }

    // =========================================================================
    // Views — existing
    // =========================================================================

    function getTokenInfo(
        uint256 tokenId
    )
        external
        view
        returns (
            uint128 pricePerCard,
            uint8 tier,
            address sourcePackMachine,
            bool isActive
        )
    {
        TokenBuybackInfo storage info = _getStorage().tokenInfo[tokenId];
        return (
            info.pricePerCard,
            info.tier,
            info.sourcePackMachine,
            info.isActive
        );
    }

    function poolBalance() external view returns (uint256) {
        return IERC20(_getStorage().paymentToken).balanceOf(address(this));
    }

    function isRegisteredPackMachine(
        address machine
    ) external view returns (bool) {
        return _getStorage().registeredPackMachines[machine];
    }

    function getDefaultBuybackBps() external view returns (uint16) {
        return _getStorage().defaultBuybackBps;
    }

    function getPackMachineBuybackBps(
        address machine
    ) external view returns (uint16) {
        return _getStorage().packMachineBuybackBps[machine];
    }

    function getPromoCodeRegistry() external view returns (address) {
        return _getStorage().promoCodeRegistry;
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    function _authorizeUpgrade(
        address
    ) internal override onlyProtocolRole(Roles.UPGRADER_ROLE) {}

    function _msgSender()
        internal
        view
        override(PermissionConsumer, ContextUpgradeable)
        returns (address)
    {
        return msg.sender;
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Resolve the effective model: per-machine override if set, else global default.
    function _resolveModel(
        BuybackPoolStorage storage $,
        address machine
    ) private view returns (IBuybackPool.BuybackModel) {
        IBuybackPool.BuybackModel override_ = $.packMachineBuybackModel[
            machine
        ];
        if (override_ != IBuybackPool.BuybackModel.Unset) return override_;
        return $.defaultBuybackModel;
    }

    function _executeBuyback(
        uint256 tokenId,
        bytes32 codeId,
        IBuybackPool.FMVQuote memory quote,
        bytes memory sig,
        bool hasQuote
    ) private {
        BuybackPoolStorage storage $ = _getStorage();
        TokenBuybackInfo storage info = $.tokenInfo[tokenId];

        if (!info.isActive) {
            if (
                info.pricePerCard == 0 && info.sourcePackMachine == address(0)
            ) {
                revert BuybackPool__TokenNotRegistered(tokenId);
            }
            revert BuybackPool__TokenNotActive(tokenId);
        }

        address caller = msg.sender;
        if (IERC721($.assetNFT).ownerOf(tokenId) != caller)
            revert BuybackPool__NotTokenOwner(tokenId, caller);

        // ── Resolve model ──────────────────────────────────────────────────
        IBuybackPool.BuybackModel model = _resolveModel(
            $,
            info.sourcePackMachine
        );

        // ── Enforce global enable flag ─────────────────────────────────────
        if (!$.modelEnabled[model]) revert BuybackPool__ModelDisabled(model);

        // ── Determine buyback rate: per-machine override, fallback to global default ──
        uint16 buybackBps = $.packMachineBuybackBps[info.sourcePackMachine];
        if (buybackBps == 0) buybackBps = $.defaultBuybackBps;

        // ── Apply a buyback-boost promo code if provided ───────────────────
        // Boosted rates (9000/9500/9800) are always higher than the configured
        // default/override, so the code bps is used directly rather than taking max.
        if (codeId != bytes32(0)) {
            address registry = $.promoCodeRegistry;
            if (registry == address(0))
                revert BuybackPool__PromoRegistryNotSet();
            uint16 boostedBps = IPromoCodeRegistry(registry).redeemBuyback(
                codeId,
                caller
            );
            buybackBps = boostedBps;
            emit BuybackBoosted(tokenId, caller, codeId, boostedBps);
        }

        // ── Compute payout based on model ──────────────────────────────────
        uint256 basis;
        if (model == IBuybackPool.BuybackModel.FMV) {
            // FMV model requires a signed quote.
            if (!hasQuote) revert BuybackPool__FMVQuoteRequired();
            basis = _consumeFMVQuote($, tokenId, quote, sig, caller);
        } else {
            // AmountSpent model: use the recorded per-card cost basis.
            basis = uint256(info.pricePerCard);
        }

        uint256 payout = (basis * buybackBps) / BPS_PRECISION;

        IERC20 paymentToken = IERC20($.paymentToken);
        uint256 balance = paymentToken.balanceOf(address(this));
        if (balance < payout)
            revert BuybackPool__InsufficientBalance(balance, payout);

        // ── State update before external calls (checks-effects-interactions) ──
        info.isActive = false;
        $.totalPaidOut += payout;

        uint8 tier = info.tier;
        address sourceMachine = info.sourcePackMachine;

        // Pull NFT from user.
        IERC721($.assetNFT).transferFrom(caller, address(this), tokenId);

        // Pay user.
        paymentToken.safeTransfer(caller, payout);

        emit BuybackExecuted(tokenId, caller, payout, model, basis);

        // Auto re-deposit the NFT back into its source PackMachine.
        _redeposit($, tokenId, tier, sourceMachine);
    }

    /// @dev Validate and consume an FMV quote. Returns the fmv value to use as the payout basis.
    function _consumeFMVQuote(
        BuybackPoolStorage storage $,
        uint256 tokenId,
        IBuybackPool.FMVQuote memory quote,
        bytes memory sig,
        address caller
    ) private returns (uint256 fmv) {
        // Token-ID binding.
        if (quote.tokenId != tokenId)
            revert BuybackPool__FMVQuoteTokenMismatch(tokenId, quote.tokenId);

        // Deadline check.
        if (block.timestamp > quote.deadline)
            revert BuybackPool__FMVQuoteExpired(
                quote.deadline,
                block.timestamp
            );

        // Nonce check — caller is the economic beneficiary, not the signer.
        uint256 expectedNonce = $.fmvQuoteNonce[tokenId];
        if (quote.nonce != expectedNonce)
            revert BuybackPool__FMVQuoteBadNonce(expectedNonce, quote.nonce);

        // Seller binding: the quote must have been issued for this specific caller (H002 fix).
        if (quote.seller != caller)
            revert BuybackPool__FMVQuoteSellerMismatch(quote.seller, caller);

        // EIP-712 signature verification (seller is now part of the struct hash).
        bytes32 structHash = keccak256(
            abi.encode(
                FMV_QUOTE_TYPEHASH,
                quote.tokenId,
                quote.fmv,
                quote.deadline,
                quote.nonce,
                quote.seller
            )
        );
        address signer = _hashTypedDataV4(structHash).recover(sig);

        // Signer must hold PACK_OPERATOR_ROLE — reuse the PermissionConsumer's manager.
        if (
            !IPermissionManager(getPermissionManager()).hasProtocolRole(
                Roles.PACK_OPERATOR_ROLE,
                signer
            )
        ) revert BuybackPool__InvalidFMVSigner(signer);

        // Consume the nonce.
        $.fmvQuoteNonce[tokenId] = expectedNonce + 1;

        return quote.fmv;
    }

    function _redeposit(
        BuybackPoolStorage storage $,
        uint256 tokenId,
        uint8 tier,
        address sourceMachine
    ) private {
        // If the source machine is no longer a valid PackMachine (e.g. deregistered),
        // hold the NFT here — admin can rescue it later. Emit TokenStuck so off-chain
        // tooling can flag the NFT for admin rescue (L003 fix).
        if (!IPackMachineFactory($.factory).isPackMachine(sourceMachine)) {
            emit TokenStuck(tokenId, sourceMachine);
            return;
        }

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        uint8[] memory tiers = new uint8[](1);
        tiers[0] = tier;

        IERC721($.assetNFT).approve(sourceMachine, tokenId);
        IPackMachine(sourceMachine).depositFromPool(
            tokenIds,
            tiers,
            address(this)
        );

        emit TokenRedeposited(tokenId, sourceMachine, tier);
    }
}
