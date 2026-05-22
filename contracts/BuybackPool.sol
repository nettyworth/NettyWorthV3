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
        bool hasProtection;
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
        /// @dev Buyback rate when protection was purchased (e.g. 9000 = 90%).
        uint16 protectedBuybackBps;
        /// @dev Per-tier buyback rate overrides (0 = use defaultBuybackBps).
        uint16[5] tierBuybackBps;
        /// @dev Per-tier protected buyback rate overrides (0 = use protectedBuybackBps).
        uint16[5] tierProtectedBuybackBps;
        mapping(uint256 tokenId => TokenBuybackInfo) tokenInfo;
        mapping(address packMachine => bool) registeredPackMachines;
        uint256 totalReceived;
        uint256 totalPaidOut;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.BuybackPool")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BUYBACK_POOL_STORAGE_SLOT =
        0x3f1a2b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f00;

    function _getStorage()
        private
        pure
        returns (BuybackPoolStorage storage $)
    {
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
        uint8 tier,
        bool hasProtection
    );
    event BuybackExecuted(
        uint256 indexed tokenId,
        address indexed seller,
        uint256 payout,
        bool withProtection
    );
    event TokenRedeposited(
        uint256 indexed tokenId,
        address indexed sourcePackMachine,
        uint8 tier
    );
    event DefaultBuybackBpsUpdated(uint16 oldBps, uint16 newBps);
    event ProtectedBuybackBpsUpdated(uint16 oldBps, uint16 newBps);
    event TierBuybackBpsUpdated(uint8 indexed tier, uint16 oldBps, uint16 newBps);
    event TierProtectedBuybackBpsUpdated(uint8 indexed tier, uint16 oldBps, uint16 newBps);
    event EmergencyWithdrawal(address indexed to, uint256 amount);
    event PackMachineRegistered(address indexed packMachine, bool registered);

    // =========================================================================
    // Errors
    // =========================================================================

    error BuybackPool__TokenNotRegistered(uint256 tokenId);
    error BuybackPool__TokenAlreadyRegistered(uint256 tokenId);
    error BuybackPool__TokenNotActive(uint256 tokenId);
    error BuybackPool__NotTokenOwner(uint256 tokenId, address caller);
    error BuybackPool__InsufficientBalance(uint256 available, uint256 required);
    error BuybackPool__ProtectionNotPurchased(uint256 tokenId);
    error BuybackPool__UnauthorizedSource(address caller);
    error BuybackPool__InvalidBps(uint16 bps);
    error BuybackPool__ZeroAddress();
    error BuybackPool__NotPaused();
    error BuybackPool__InvalidTier(uint8 tier);

    uint256 private constant NUM_TIERS = 5;
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
        $.protectedBuybackBps = 9000;
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
        bool hasProtection,
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
            hasProtection: hasProtection,
            sourcePackMachine: sourcePackMachine,
            isActive: true
        });

        emit TokenRegistered(tokenId, sourcePackMachine, pricePerCard, tier, hasProtection);
    }

    /// @notice Sell a token back to the pool at the standard rate (default 80%).
    /// @dev Caller must own the token and have approved this contract (or use setApprovalForAll).
    function buyback(uint256 tokenId) external nonReentrant whenNotPaused {
        _executeBuyback(tokenId, false);
    }

    /// @notice Sell a token back at the protection rate (default 90%).
    /// @dev Reverts if protection was not purchased for this token's pack.
    function buybackWithProtection(
        uint256 tokenId
    ) external nonReentrant whenNotPaused {
        _executeBuyback(tokenId, true);
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

    function setProtectedBuybackBps(
        uint16 bps
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (bps > BPS_PRECISION) revert BuybackPool__InvalidBps(bps);
        BuybackPoolStorage storage $ = _getStorage();
        emit ProtectedBuybackBpsUpdated($.protectedBuybackBps, bps);
        $.protectedBuybackBps = bps;
    }

    function setTierBuybackBps(
        uint8 tier,
        uint16 bps
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (tier >= NUM_TIERS) revert BuybackPool__InvalidTier(tier);
        if (bps > BPS_PRECISION) revert BuybackPool__InvalidBps(bps);
        BuybackPoolStorage storage $ = _getStorage();
        emit TierBuybackBpsUpdated(tier, $.tierBuybackBps[tier], bps);
        $.tierBuybackBps[tier] = bps;
    }

    function setTierProtectedBuybackBps(
        uint8 tier,
        uint16 bps
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (tier >= NUM_TIERS) revert BuybackPool__InvalidTier(tier);
        if (bps > BPS_PRECISION) revert BuybackPool__InvalidBps(bps);
        BuybackPoolStorage storage $ = _getStorage();
        emit TierProtectedBuybackBpsUpdated(tier, $.tierProtectedBuybackBps[tier], bps);
        $.tierProtectedBuybackBps[tier] = bps;
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
        IERC721(_getStorage().assetNFT).transferFrom(address(this), to, tokenId);
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
            bool hasProtection,
            address sourcePackMachine,
            bool isActive
        )
    {
        TokenBuybackInfo storage info = _getStorage().tokenInfo[tokenId];
        return (
            info.pricePerCard,
            info.tier,
            info.hasProtection,
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

    function getProtectedBuybackBps() external view returns (uint16) {
        return _getStorage().protectedBuybackBps;
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

    function _executeBuyback(uint256 tokenId, bool useProtection) private {
        BuybackPoolStorage storage $ = _getStorage();
        TokenBuybackInfo storage info = $.tokenInfo[tokenId];

        if (!info.isActive) {
            if (info.pricePerCard == 0 && info.sourcePackMachine == address(0)) {
                revert BuybackPool__TokenNotRegistered(tokenId);
            }
            revert BuybackPool__TokenNotActive(tokenId);
        }

        address caller = msg.sender;
        if (IERC721($.assetNFT).ownerOf(tokenId) != caller)
            revert BuybackPool__NotTokenOwner(tokenId, caller);

        if (useProtection && !info.hasProtection)
            revert BuybackPool__ProtectionNotPurchased(tokenId);

        // Determine buyback rate (tier override takes precedence).
        uint16 buybackBps;
        if (useProtection) {
            buybackBps = $.tierProtectedBuybackBps[info.tier];
            if (buybackBps == 0) buybackBps = $.protectedBuybackBps;
        } else {
            buybackBps = $.tierBuybackBps[info.tier];
            if (buybackBps == 0) buybackBps = $.defaultBuybackBps;
        }

        uint256 payout = (uint256(info.pricePerCard) * buybackBps) / BPS_PRECISION;

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

        emit BuybackExecuted(tokenId, caller, payout, useProtection);

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
        IPackMachine(sourceMachine).depositFromPool(tokenIds, tiers, address(this));

        emit TokenRedeposited(tokenId, sourceMachine, tier);
    }
}
