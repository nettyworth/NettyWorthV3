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

/// @title BuybackPool
/// @author NettyWorth
/// @notice Holds USDC allocations from pack purchases and lets token holders sell cards back
///         at a guaranteed percentage of the original per-card price. Bought-back NFTs are
///         automatically re-deposited into their source PackMachine clone.
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
        // ── Appended ──────────────────────────────────────────────────────────
        /// @dev PromoCodeRegistry proxy address for buyback-boost code redemption.
        address promoCodeRegistry;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.BuybackPool")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BUYBACK_POOL_STORAGE_SLOT =
        0x3f1a2b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f00;

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
        uint128 pricePerCard,
        uint8 tier
    );
    event BuybackExecuted(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 payout
    );
    event TokenRedeposited(
        uint256 indexed tokenId,
        address indexed sourcePackMachine,
        uint8 tier
    );
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
    /// @dev Only callable by registered PackMachines.
    function registerToken(
        uint256 tokenId,
        uint128 pricePerCard,
        uint8 tier,
        address sourcePackMachine
    ) external whenNotPaused {
        BuybackPoolStorage storage $ = _getStorage();
        if (!$.registeredPackMachines[msg.sender])
            revert BuybackPool__UnauthorizedSource(msg.sender);
        if ($.tokenInfo[tokenId].isActive)
            revert BuybackPool__TokenAlreadyRegistered(tokenId);

        $.tokenInfo[tokenId] = TokenBuybackInfo({
            pricePerCard: pricePerCard,
            tier: tier,
            sourcePackMachine: sourcePackMachine,
            isActive: true
        });

        emit TokenRegistered(tokenId, sourcePackMachine, pricePerCard, tier);
    }

    /// @notice Sell a token back to the pool at the buyback rate for its source PackMachine.
    /// @dev Caller must own the token and have approved this contract (or use setApprovalForAll).
    function buyback(uint256 tokenId) external nonReentrant whenNotPaused {
        _executeBuyback(tokenId, bytes32(0));
    }

    /// @notice Sell a token back to the pool applying a buyback-boost promo code.
    /// @dev    The PromoCodeRegistry is queried to validate and consume the code.
    ///         Reverts if the registry is not configured or the code is invalid/expired/exhausted.
    ///         Boosted rates (90/95/98%) are always higher than the configured default (80%) so the
    ///         code bps is used directly — the pool must hold sufficient USDC to cover the higher payout.
    ///         Pass bytes32(0) as codeId to sell back without a boost (equivalent to the no-code overload).
    /// @param codeId keccak256 of the off-chain promo-code string; bytes32(0) means no boost.
    function buyback(
        uint256 tokenId,
        bytes32 codeId
    ) external nonReentrant whenNotPaused {
        _executeBuyback(tokenId, codeId);
    }

    // =========================================================================
    // Admin — configuration
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
    // Views
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

    function _executeBuyback(uint256 tokenId, bytes32 codeId) private {
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

        // Determine buyback rate: per-machine override, fallback to global default.
        uint16 buybackBps = $.packMachineBuybackBps[info.sourcePackMachine];
        if (buybackBps == 0) buybackBps = $.defaultBuybackBps;

        // Apply a buyback-boost promo code if provided.
        // Boosted rates (9000/9500/9800) are always higher than the configured default/override,
        // so the code bps is used directly rather than taking the max.
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

        uint256 payout =
            (uint256(info.pricePerCard) * buybackBps) / BPS_PRECISION;

        IERC20 paymentToken = IERC20($.paymentToken);
        uint256 balance = paymentToken.balanceOf(address(this));
        if (balance < payout)
            revert BuybackPool__InsufficientBalance(balance, payout);

        // State update before external calls (checks-effects-interactions).
        info.isActive = false;
        $.totalPaidOut += payout;

        uint8 tier = info.tier;
        address sourceMachine = info.sourcePackMachine;

        // Pull NFT from user.
        IERC721($.assetNFT).transferFrom(caller, address(this), tokenId);

        // Pay user.
        paymentToken.safeTransfer(caller, payout);

        emit BuybackExecuted(tokenId, caller, payout);

        // Auto re-deposit the NFT back into its source PackMachine.
        _redeposit($, tokenId, tier, sourceMachine);
    }

    function _redeposit(
        BuybackPoolStorage storage $,
        uint256 tokenId,
        uint8 tier,
        address sourceMachine
    ) private {
        // If the source machine is no longer a valid PackMachine (e.g. deregistered),
        // hold the NFT here — admin can rescue it later.
        if (!IPackMachineFactory($.factory).isPackMachine(sourceMachine)) {
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
