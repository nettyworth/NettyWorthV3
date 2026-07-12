// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";
import {IPackMachine} from "./interfaces/IPackMachine.sol";
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";
import {IPromoCodeRegistry} from "./interfaces/IPromoCodeRegistry.sol";
import {IAssetNFT} from "./interfaces/IAssetNFT.sol";
import {IBuybackPool} from "./interfaces/IBuybackPool.sol";

/// @title BuybackPool
/// @author NettyWorth
/// @notice Holds USDC allocations from pack purchases and lets token holders sell cards back
///         at a guaranteed percentage of either (a) the card's on-chain appraised fair-market
///         value (FMV mode) or (b) the amount the buyer actually paid per card at open time
///         (Spend mode).
///
///         FMV mode:   Payout = appraisalValue      × buybackBps / 10000
///         Spend mode: Payout = amountPaidPerCard   × buybackBps / 10000
///
///         Bought-back NFTs are automatically re-deposited into their source PackMachine clone.
///
/// @dev    Buyback rate can be set globally (defaultBuybackBps) or per-PackMachine
///         (packMachineBuybackBps); per-machine override takes precedence.
///         Buyback mode (FMV vs Spend) can be set globally (defaultBuybackMode) or
///         per-PackMachine (packMachineBuybackMode); per-machine override takes precedence.
///         Mode override encoding: 0 = unset (inherit global default), 1 = FMV, 2 = Spend.
///         Promo-code boosts (via PromoCodeRegistry) are supported on top of the base rate.
///
/// @custom:security-contact security@nettyworth.io
contract BuybackPool is
    Initializable,
    UUPSUpgradeable,
    PermissionConsumer,
    ReentrancyGuard,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @dev Buyback mode stored as a uint8.
    ///      0 = FMV (payout based on on-chain appraisal value)
    ///      1 = Spend (payout based on amount paid per card at open time)
    enum BuybackMode {
        FMV,
        Spend
    }

    struct TokenBuybackInfo {
        uint8 tier;
        address sourcePackMachine;
        bool isActive;
        /// @dev Amount the buyer actually paid per card (net of discounts), in payment-token
        ///      units. Set to 0 for tokens registered via legacy overloads that predate this
        ///      field. A Spend-mode buyback on a token with amountPaidPerCard == 0 reverts
        ///      BuybackPool__NoPaidAmount.
        uint128 amountPaidPerCard;
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
        /// @dev PromoCodeRegistry proxy address for buyback-boost code redemption.
        address promoCodeRegistry;
        /// @dev Global default buyback mode. 0 = FMV, 1 = Spend.
        BuybackMode defaultBuybackMode;
        /// @dev Per-PackMachine mode override using a +1 offset so that 0 means "unset,
        ///      inherit defaultBuybackMode", 1 means FMV, and 2 means Spend.
        ///      Decode: if value == 0 → use defaultBuybackMode; else mode = BuybackMode(value - 1).
        mapping(address packMachine => uint8) packMachineBuybackMode;
        /// @dev Fee deducted from each buyback payout and sent to financeWallet (basis points).
        ///      0 = no fee (default after upgrade). E.g. 500 = 5%.
        uint16 buybackFeeBps;
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
    // Events
    // =========================================================================

    event TokenRegistered(
        uint256 indexed tokenId,
        address indexed sourcePackMachine,
        uint8 tier
    );
    /// @notice Emitted on every successful buyback.
    /// @param basis The value the payout was computed against: the on-chain appraisal in FMV
    ///              mode, or the amount paid per card in Spend mode.
    event BuybackExecuted(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 payout,
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
    event DefaultBuybackModeUpdated(BuybackMode oldMode, BuybackMode newMode);
    event PackMachineBuybackModeUpdated(
        address indexed machine,
        BuybackMode oldMode,
        BuybackMode newMode
    );
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    /// @notice Emitted on a partial admin withdrawal to a chosen destination.
    event Withdrawal(address indexed to, uint256 amount);
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
    /// @notice Emitted when the pool is funded by an operator.
    event PoolFunded(address indexed from, uint256 amount);
    /// @notice Emitted when the buyback fee rate is updated.
    event BuybackFeeBpsUpdated(uint16 oldBps, uint16 newBps);
    /// @notice Emitted when a buyback fee is charged and transferred to the financeWallet.
    event BuybackFeeCharged(
        uint256 indexed tokenId,
        address indexed feeWallet,
        uint256 fee
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error BuybackPool__TokenNotRegistered(uint256 tokenId);
    error BuybackPool__TokenNotActive(uint256 tokenId);
    error BuybackPool__NotTokenOwner(uint256 tokenId, address caller);
    error BuybackPool__InsufficientBalance(uint256 available, uint256 required);
    error BuybackPool__UnauthorizedSource(address caller);
    error BuybackPool__InvalidBps(uint16 bps);
    error BuybackPool__ZeroAddress();
    error BuybackPool__ZeroAmount();
    error BuybackPool__NotPaused();
    error BuybackPool__PromoRegistryNotSet();
    /// @notice The token has no on-chain appraisal — buyback cannot be priced.
    error BuybackPool__NoAppraisal(uint256 tokenId);
    /// @notice The token was registered without a paid amount (via a legacy overload) but
    ///         its source machine is configured for Spend mode.
    error BuybackPool__NoPaidAmount(uint256 tokenId);
    /// @notice The supplied mode value is not a valid BuybackMode.
    error BuybackPool__InvalidMode(uint8 mode);

    uint16 private constant BPS_PRECISION = 10000;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =========================================================================
    // Initializer
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

        BuybackPoolStorage storage $ = _getStorage();
        $.assetNFT = assetNFT_;
        $.paymentToken = paymentToken_;
        $.financeWallet = financeWallet_;
        $.factory = factory_;
        $.defaultBuybackBps = 8000;
    }

    // =========================================================================
    // Core: register & buyback
    // =========================================================================

    /// @notice Called by PackMachine during fulfillRandomness to record a won token's buyback data.
    ///         Passes `amountPaidPerCard` (net-of-discount USDC the buyer paid per card) for
    ///         use when the machine is in Spend mode.
    /// @dev Only callable by registered PackMachines.
    ///      Registration is intentionally NOT gated by `whenNotPaused`: it is a pure bookkeeping
    ///      write that moves no funds, and blocking it while paused would silently strip buyback
    ///      rights from cards won during the pause window (the user already paid the buyback
    ///      allocation but the VRF callback's try/catch swallows the revert). Redemptions via
    ///      `buyback` remain paused independently to freeze fund flows during incidents.
    ///      If the token already has an active registration (stale flag from a prior win/recycle
    ///      cycle that bypassed buyback), the record is silently overwritten with the current
    ///      tier/source/amount. This prevents a stale `isActive` from permanently bricking a
    ///      pack's VRF fulfillment — an authorized machine re-registering its own token is safe
    ///      because the token physically left the machine before the next win, making any prior
    ///      record obsolete.
    function registerToken(
        uint256 tokenId,
        uint8 tier,
        address sourcePackMachine,
        uint128 amountPaidPerCard
    ) external {
        _registerToken(tokenId, tier, sourcePackMachine, amountPaidPerCard);
    }

    /// @notice Compat overload for PackMachine clones that call the 3-arg selector
    ///         (deployed before the amountPaidPerCard field was added).
    ///         amountPaidPerCard is recorded as 0; these tokens can only be bought back
    ///         in FMV mode.
    function registerToken(
        uint256 tokenId,
        uint8 tier,
        address sourcePackMachine
    ) external {
        _registerToken(tokenId, tier, sourcePackMachine, 0);
    }

    /// @notice Legacy 4-arg overload for already-deployed PackMachine clones that were
    ///         created before the price-based buyback model was removed. `pricePerCard`
    ///         is ignored — payout is now driven by on-chain appraisal (FMV mode) or
    ///         the separately tracked amountPaidPerCard (Spend mode) — but the selector
    ///         must be present so immutable clones can still register won cards.
    function registerToken(
        uint256 tokenId,
        uint128 /* pricePerCard */,
        uint8 tier,
        address sourcePackMachine
    ) external {
        _registerToken(tokenId, tier, sourcePackMachine, 0);
    }

    function _registerToken(
        uint256 tokenId,
        uint8 tier,
        address sourcePackMachine,
        uint128 amountPaidPerCard
    ) private {
        BuybackPoolStorage storage $ = _getStorage();
        if (!$.registeredPackMachines[msg.sender])
            revert BuybackPool__UnauthorizedSource(msg.sender);

        $.tokenInfo[tokenId] = TokenBuybackInfo({
            tier: tier,
            sourcePackMachine: sourcePackMachine,
            isActive: true,
            amountPaidPerCard: amountPaidPerCard
        });

        emit TokenRegistered(tokenId, sourcePackMachine, tier);
    }

    /// @notice Sell a token back to the pool.
    ///         Payout = on-chain appraisal × buybackBps / 10000.
    /// @dev    Caller must own the token and have approved this contract.
    function buyback(uint256 tokenId) external nonReentrant whenNotPaused {
        _executeBuyback(tokenId, bytes32(0));
    }

    /// @notice Sell a token back applying a buyback-boost promo code.
    /// @dev    The PromoCodeRegistry is queried to validate and consume the code.
    ///         Reverts if the registry is not configured or the code is invalid/expired/exhausted.
    ///         Pass bytes32(0) as codeId to sell back without a boost.
    /// @param codeId keccak256 of the off-chain promo-code string; bytes32(0) means no boost.
    function buyback(
        uint256 tokenId,
        bytes32 codeId
    ) external nonReentrant whenNotPaused {
        _executeBuyback(tokenId, codeId);
    }

    // =========================================================================
    // Admin — funding
    // =========================================================================

    /// @notice Deposit payment token (USDC) into the pool to back future buybacks.
    /// @dev    Caller must have approved this contract for `amount` before calling.
    /// @param amount Amount of payment token to deposit (must be > 0).
    function depositFunds(
        uint256 amount
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) whenNotPaused {
        if (amount == 0) revert BuybackPool__ZeroAmount();
        BuybackPoolStorage storage $ = _getStorage();
        IERC20($.paymentToken).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );
        $.totalReceived += amount;
        emit PoolFunded(msg.sender, amount);
    }

    // =========================================================================
    // Admin — rate configuration
    // =========================================================================

    function setDefaultBuybackBps(
        uint16 bps
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        // C008 equivalent: disallow 0 so the pool cannot be configured to take NFTs
        // for zero payment. Also cap at 100% (BPS_PRECISION).
        if (bps == 0 || bps > BPS_PRECISION)
            revert BuybackPool__InvalidBps(bps);
        BuybackPoolStorage storage $ = _getStorage();
        emit DefaultBuybackBpsUpdated($.defaultBuybackBps, bps);
        $.defaultBuybackBps = bps;
    }

    /// @notice Set the protocol fee charged on every buyback payout (basis points).
    ///         The fee is deducted from the seller's payout and sent to financeWallet.
    ///         0 disables the fee entirely. Max 100% (BPS_PRECISION).
    ///         Example: 500 = 5% fee.  payout 31.99 → fee 1.60 → seller receives 30.39.
    function setBuybackFeeBps(
        uint16 bps
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (bps > BPS_PRECISION) revert BuybackPool__InvalidBps(bps);
        BuybackPoolStorage storage $ = _getStorage();
        emit BuybackFeeBpsUpdated($.buybackFeeBps, bps);
        $.buybackFeeBps = bps;
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

    /// @notice Set the global default buyback mode (FMV or Spend).
    /// @param mode 0 = FMV (payout based on on-chain appraisal), 1 = Spend (payout based on amount paid per card).
    function setDefaultBuybackMode(
        uint8 mode
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (mode > uint8(type(BuybackMode).max))
            revert BuybackPool__InvalidMode(mode);
        BuybackPoolStorage storage $ = _getStorage();
        BuybackMode newMode = BuybackMode(mode);
        emit DefaultBuybackModeUpdated($.defaultBuybackMode, newMode);
        $.defaultBuybackMode = newMode;
    }

    /// @notice Set a per-PackMachine buyback mode override.
    /// @param mode 0 = clear override (inherit global default),
    ///             1 = FMV (appraisal-based),
    ///             2 = Spend (amount-paid-based).
    function setPackMachineBuybackMode(
        address machine,
        uint8 mode
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (machine == address(0)) revert BuybackPool__ZeroAddress();
        // Valid values: 0 (unset), 1 (FMV), 2 (Spend). Max = BuybackMode count + 1.
        if (mode > uint8(type(BuybackMode).max) + 1)
            revert BuybackPool__InvalidMode(mode);
        BuybackPoolStorage storage $ = _getStorage();
        uint8 old = $.packMachineBuybackMode[machine];
        BuybackMode oldDecoded =
            old == 0 ? $.defaultBuybackMode : BuybackMode(old - 1);
        BuybackMode newDecoded =
            mode == 0 ? $.defaultBuybackMode : BuybackMode(mode - 1);
        $.packMachineBuybackMode[machine] = mode;
        emit PackMachineBuybackModeUpdated(machine, oldDecoded, newDecoded);
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

    /// @notice Withdraw a specific amount of the payment token to a chosen destination.
    /// @dev    Admin-only operational withdrawal; callable at any time (not gated by pause).
    ///         For a full drain-to-financeWallet during an incident, use emergencyWithdraw.
    /// @param to     Recipient of the funds (must be non-zero).
    /// @param amount Amount of payment token to withdraw (must be > 0 and <= pool balance).
    function withdraw(
        address to,
        uint256 amount
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert BuybackPool__ZeroAddress();
        if (amount == 0) revert BuybackPool__ZeroAmount();
        BuybackPoolStorage storage $ = _getStorage();
        IERC20 token = IERC20($.paymentToken);
        uint256 balance = token.balanceOf(address(this));
        if (balance < amount)
            revert BuybackPool__InsufficientBalance(balance, amount);
        token.safeTransfer(to, amount);
        emit Withdrawal(to, amount);
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
    // Views
    // =========================================================================

    function getTokenInfo(
        uint256 tokenId
    )
        external
        view
        returns (uint8 tier, address sourcePackMachine, bool isActive)
    {
        TokenBuybackInfo storage info = _getStorage().tokenInfo[tokenId];
        return (info.tier, info.sourcePackMachine, info.isActive);
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

    /// @notice Returns the current buyback fee rate in basis points (0 = no fee).
    function getBuybackFeeBps() external view returns (uint16) {
        return _getStorage().buybackFeeBps;
    }

    function getPromoCodeRegistry() external view returns (address) {
        return _getStorage().promoCodeRegistry;
    }

    /// @notice Returns the global default buyback mode (FMV=0, Spend=1).
    function getDefaultBuybackMode() external view returns (BuybackMode) {
        return _getStorage().defaultBuybackMode;
    }

    /// @notice Returns the per-machine mode override encoded with the +1 offset
    ///         (0 = unset/inherit global, 1 = FMV, 2 = Spend).
    function getPackMachineBuybackMode(
        address machine
    ) external view returns (uint8) {
        return _getStorage().packMachineBuybackMode[machine];
    }

    /// @notice Returns the amount paid per card recorded for a token (0 if registered
    ///         via a legacy overload that predates this field).
    function getTokenPaidAmount(
        uint256 tokenId
    ) external view returns (uint128) {
        return _getStorage().tokenInfo[tokenId].amountPaidPerCard;
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

    function _executeBuyback(uint256 tokenId, bytes32 codeId) private {
        BuybackPoolStorage storage $ = _getStorage();
        TokenBuybackInfo storage info = $.tokenInfo[tokenId];

        if (!info.isActive) {
            if (info.sourcePackMachine == address(0)) {
                revert BuybackPool__TokenNotRegistered(tokenId);
            }
            revert BuybackPool__TokenNotActive(tokenId);
        }

        address caller = msg.sender;
        if (IERC721($.assetNFT).ownerOf(tokenId) != caller)
            revert BuybackPool__NotTokenOwner(tokenId, caller);

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

        // ── Resolve buyback mode: per-machine override (+1 encoded), fallback to global ──
        uint8 modeRaw = $.packMachineBuybackMode[info.sourcePackMachine];
        BuybackMode mode =
            modeRaw == 0 ? $.defaultBuybackMode : BuybackMode(modeRaw - 1);

        // ── Payout basis = appraisal (FMV mode) or amount paid per card (Spend mode) ──
        uint256 basis;
        if (mode == BuybackMode.Spend) {
            basis = info.amountPaidPerCard;
            if (basis == 0) revert BuybackPool__NoPaidAmount(tokenId);
        } else {
            basis = IAssetNFT($.assetNFT).getAppraisalValue(tokenId);
            if (basis == 0) revert BuybackPool__NoAppraisal(tokenId);
        }

        uint256 payout = (basis * buybackBps) / BPS_PRECISION;
        if (payout == 0) revert BuybackPool__ZeroAmount();

        // ── Compute fee deducted from payout and routed to financeWallet ──────
        uint16 feeBps = $.buybackFeeBps;
        uint256 fee = feeBps == 0 ? 0 : (payout * feeBps) / BPS_PRECISION;
        uint256 sellerAmount = payout - fee;

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

        // Pay seller (payout minus fee).
        paymentToken.safeTransfer(caller, sellerAmount);

        // Route fee to financeWallet.
        if (fee > 0) {
            address feeWallet = $.financeWallet;
            paymentToken.safeTransfer(feeWallet, fee);
            emit BuybackFeeCharged(tokenId, feeWallet, fee);
        }

        // Emit with the gross payout and basis; fee is separately auditable via BuybackFeeCharged.
        emit BuybackExecuted(tokenId, caller, payout, basis);

        // Auto re-deposit the NFT back into its source PackMachine.
        _redeposit($, tokenId, tier, sourceMachine);
    }

    function _redeposit(
        BuybackPoolStorage storage $,
        uint256 tokenId,
        uint8 tier,
        address sourceMachine
    ) private {
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
