// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPromoCodeRegistry} from "./interfaces/IPromoCodeRegistry.sol";
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";

/// @title PromoCodeRegistry
/// @author NettyWorth
/// @notice Central registry for all promotional codes (discount and buyback boosts).
///
///         Two kinds of code:
///           • Discount — reduces a PackMachine pack price by 1–100% (100–10000 bps).
///             Consumed by registered PackMachine clones via `redeemDiscount`.
///           • Buyback — overrides BuybackPool payout rate to any value 1–100% (100–10000 bps).
///             Consumed by the BuybackPool singleton via `redeemBuyback`.
///
///         Both kinds support:
///           • Expiration dates (unix timestamp; 0 = never)
///           • Total-redemption cap (0 = uncapped)
///           • Allowlist (restricted=true) or open-to-all (restricted=false)
///           • One-per-user guard (oncePerUser flag)
///           • Usage tracking and remaining-redemptions views
///
///         codeId = keccak256(bytes(codeString)), computed off-chain.
///         The plaintext code never touches the chain.  The hash is NOT a secret —
///         security rests on active/expiry/maxRedemptions/allowlist controls only.
///
/// @dev UUPS upgradeable. Access control via PermissionConsumer / PermissionManager.
///      All admin functions gated by PACK_OPERATOR_ROLE.
///      ERC-7201 namespaced storage prevents upgrade slot collisions.
/// @custom:security-contact security@nettyworth.io
contract PromoCodeRegistry is
    IPromoCodeRegistry,
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    PermissionConsumer
{
    // =========================================================================
    // Constants
    // =========================================================================

    uint256 internal constant BPS = 10_000;

    /// @dev Maximum number of addresses in a single allowlist batch call.
    uint256 internal constant MAX_BATCH = 50;

    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.PromoCodeRegistry
    struct PromoCodeRegistryStorage {
        /// @dev Address of the PackMachineFactory proxy (used to validate redeemDiscount callers).
        address packMachineFactory;
        /// @dev Address of the BuybackPool proxy (sole authorized redeemBuyback caller).
        address buybackPool;
        /// @dev All created codes keyed by their keccak256 id.
        mapping(bytes32 => PromoCode) codes;
        /// @dev Per-code allowlists.  Only relevant when codes[id].restricted == true.
        mapping(bytes32 => mapping(address => bool)) allowlisted;
        /// @dev Per-code per-user redemption flags.  Only relevant when codes[id].oncePerUser == true.
        mapping(bytes32 => mapping(address => bool)) hasRedeemed;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.PromoCodeRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PROMO_CODE_REGISTRY_STORAGE_SLOT =
        0x422483da3dc7add702c8ac5d4c2b4db1dac69e5bcdbe6279f8ec6dcd809d8600;

    function _getStorage()
        private
        pure
        returns (PromoCodeRegistryStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := PROMO_CODE_REGISTRY_STORAGE_SLOT
        }
    }

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

    /// @notice Initializes the registry.
    /// @param permissionManager_ Address of the deployed PermissionManager proxy.
    function initialize(address permissionManager_) external initializer {
        __PermissionConsumer_init(permissionManager_);
        __Pausable_init();
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    function _authorizeUpgrade(
        address
    ) internal override onlyProtocolRole(Roles.UPGRADER_ROLE) {}

    /// @dev Resolve _msgSender() ambiguity: PausableUpgradeable (via ContextUpgradeable)
    ///      and PermissionConsumer both declare the virtual. Since this contract has no
    ///      ERC-2771 meta-tx support, plain msg.sender is the correct resolution.
    function _msgSender()
        internal
        view
        override(PermissionConsumer, ContextUpgradeable)
        returns (address)
    {
        return msg.sender;
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function pause() external onlyProtocolRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyProtocolRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // Admin — wiring (DEFAULT_ADMIN_ROLE — tighter control over contract wiring)
    // =========================================================================

    /// @notice Set the PackMachineFactory proxy address.
    /// @dev Used to authorize discount redemptions via factory.isPackMachine(msg.sender).
    function setPackMachineFactory(
        address factory_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (factory_ == address(0)) revert PromoCodeRegistry__ZeroAddress();
        PromoCodeRegistryStorage storage $ = _getStorage();
        emit PackMachineFactorySet($.packMachineFactory, factory_);
        $.packMachineFactory = factory_;
    }

    /// @notice Set the BuybackPool proxy address.
    /// @dev Only this address may call redeemBuyback.
    function setBuybackPool(
        address pool_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (pool_ == address(0)) revert PromoCodeRegistry__ZeroAddress();
        PromoCodeRegistryStorage storage $ = _getStorage();
        emit BuybackPoolSet($.buybackPool, pool_);
        $.buybackPool = pool_;
    }

    // =========================================================================
    // Admin — code management (PACK_OPERATOR_ROLE)
    // =========================================================================

    /// @notice Create a new promo code.
    /// @param codeId         keccak256(bytes(codeString)) computed off-chain.
    /// @param kind           Discount or Buyback.
    /// @param bps            Discount or Buyback: any value in [100, 10000] (1%–100%).
    /// @param expiry         Unix seconds after which the code is expired; 0 = never.
    /// @param maxRedemptions Maximum total redemptions; 0 = uncapped.
    /// @param restricted     true = only addresses on the allowlist may redeem.
    /// @param oncePerUser    true = each address may redeem at most once.
    /// @param machine        Discount only: PackMachine clone this code is scoped to.
    ///                       address(0) = global code valid on any registered PackMachine.
    ///                       Ignored (stored as 0) for Buyback codes.
    function createCode(
        bytes32 codeId,
        PromoKind kind,
        uint16 bps,
        uint64 expiry,
        uint32 maxRedemptions,
        bool restricted,
        bool oncePerUser,
        address machine
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        PromoCodeRegistryStorage storage $ = _getStorage();
        if ($.codes[codeId].exists)
            revert PromoCodeRegistry__CodeExists(codeId);
        _validateBps(kind, bps);

        // Machine binding is only meaningful for Discount codes.
        address boundMachine =
            (kind == PromoKind.Discount) ? machine : address(0);

        $.codes[codeId] = PromoCode({
            kind: kind,
            bps: bps,
            expiry: expiry,
            maxRedemptions: maxRedemptions,
            redeemedCount: 0,
            restricted: restricted,
            active: true,
            oncePerUser: oncePerUser,
            exists: true,
            machine: boundMachine
        });

        emit CodeCreated(
            codeId,
            kind,
            bps,
            expiry,
            maxRedemptions,
            restricted,
            oncePerUser,
            boundMachine
        );
    }

    /// @notice Activate or deactivate a code.
    function setActive(
        bytes32 codeId,
        bool active
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        PromoCode storage c = _requireExists(codeId);
        c.active = active;
        emit CodeActiveSet(codeId, active);
    }

    /// @notice Update a code's expiry timestamp (0 = never expires).
    function setExpiry(
        bytes32 codeId,
        uint64 expiry
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        PromoCode storage c = _requireExists(codeId);
        c.expiry = expiry;
        emit CodeExpirySet(codeId, expiry);
    }

    /// @notice Update a code's maximum redemption cap (0 = uncapped).
    /// @dev Lowering below redeemedCount simply stops future redemptions.
    function setMaxRedemptions(
        bytes32 codeId,
        uint32 max
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        PromoCode storage c = _requireExists(codeId);
        c.maxRedemptions = max;
        emit CodeMaxRedemptionsSet(codeId, max);
    }

    /// @notice Add addresses to a code's allowlist (max 50 per call).
    function addToAllowlist(
        bytes32 codeId,
        address[] calldata users
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (users.length > MAX_BATCH)
            revert PromoCodeRegistry__BatchTooLarge(users.length, MAX_BATCH);
        _requireExists(codeId);
        PromoCodeRegistryStorage storage $ = _getStorage();
        for (uint256 i; i < users.length; ++i) {
            $.allowlisted[codeId][users[i]] = true;
            emit AllowlistUpdated(codeId, users[i], true);
        }
    }

    /// @notice Remove addresses from a code's allowlist (max 50 per call).
    function removeFromAllowlist(
        bytes32 codeId,
        address[] calldata users
    ) external onlyProtocolRole(Roles.PACK_OPERATOR_ROLE) {
        if (users.length > MAX_BATCH)
            revert PromoCodeRegistry__BatchTooLarge(users.length, MAX_BATCH);
        _requireExists(codeId);
        PromoCodeRegistryStorage storage $ = _getStorage();
        for (uint256 i; i < users.length; ++i) {
            $.allowlisted[codeId][users[i]] = false;
            emit AllowlistUpdated(codeId, users[i], false);
        }
    }

    // =========================================================================
    // Redemption — called by spokes mid-transaction
    // =========================================================================

    /// @inheritdoc IPromoCodeRegistry
    function redeemDiscount(
        bytes32 codeId,
        address user
    ) external override whenNotPaused returns (uint16 bps) {
        PromoCodeRegistryStorage storage $ = _getStorage();
        address factory = $.packMachineFactory;
        if (factory == address(0)) revert PromoCodeRegistry__NotConfigured();
        if (!IPackMachineFactory(factory).isPackMachine(msg.sender))
            revert PromoCodeRegistry__UnauthorizedRedeemer(msg.sender);
        // Enforce machine binding: if the code is scoped to a specific PackMachine,
        // only that clone may redeem it.
        address bound = $.codes[codeId].machine;
        if (bound != address(0) && msg.sender != bound)
            revert PromoCodeRegistry__WrongMachine(codeId, bound, msg.sender);
        return _validateAndConsume($, codeId, user, PromoKind.Discount);
    }

    /// @inheritdoc IPromoCodeRegistry
    function refundDiscount(
        bytes32 codeId,
        address user
    ) external override whenNotPaused {
        PromoCodeRegistryStorage storage $ = _getStorage();
        address factory = $.packMachineFactory;
        if (factory == address(0)) revert PromoCodeRegistry__NotConfigured();
        if (!IPackMachineFactory(factory).isPackMachine(msg.sender))
            revert PromoCodeRegistry__UnauthorizedRedeemer(msg.sender);
        // Only the machine that originally redeemed the code may refund it.
        address bound = $.codes[codeId].machine;
        if (bound != address(0) && msg.sender != bound)
            revert PromoCodeRegistry__WrongMachine(codeId, bound, msg.sender);

        PromoCode storage c = $.codes[codeId];
        if (!c.exists) revert PromoCodeRegistry__CodeNotFound(codeId);

        // Reverse the consumption: decrement count and clear oncePerUser flag.
        if (c.redeemedCount > 0) {
            unchecked {
                c.redeemedCount -= 1;
            }
        }
        if (c.oncePerUser) $.hasRedeemed[codeId][user] = false;

        emit CodeRefunded(codeId, user, c.kind, c.redeemedCount);
    }

    /// @inheritdoc IPromoCodeRegistry
    function redeemBuyback(
        bytes32 codeId,
        address user
    ) external override whenNotPaused returns (uint16 bps) {
        PromoCodeRegistryStorage storage $ = _getStorage();
        if (msg.sender != $.buybackPool)
            revert PromoCodeRegistry__UnauthorizedRedeemer(msg.sender);
        return _validateAndConsume($, codeId, user, PromoKind.Buyback);
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @inheritdoc IPromoCodeRegistry
    function getCode(
        bytes32 codeId
    ) external view override returns (PromoCode memory) {
        return _getStorage().codes[codeId];
    }

    /// @inheritdoc IPromoCodeRegistry
    function remainingRedemptions(
        bytes32 codeId
    ) external view override returns (uint256) {
        PromoCode storage c = _getStorage().codes[codeId];
        if (c.maxRedemptions == 0) return type(uint256).max;
        uint32 redeemed = c.redeemedCount;
        uint32 max = c.maxRedemptions;
        return redeemed >= max ? 0 : max - redeemed;
    }

    /// @inheritdoc IPromoCodeRegistry
    function isEligible(
        bytes32 codeId,
        address user
    ) external view override returns (bool) {
        PromoCodeRegistryStorage storage $ = _getStorage();
        PromoCode storage c = $.codes[codeId];
        if (!c.exists) return false;
        if (!c.active) return false;
        if (c.expiry != 0 && block.timestamp > c.expiry) return false;
        if (c.maxRedemptions != 0 && c.redeemedCount >= c.maxRedemptions)
            return false;
        if (c.restricted && !$.allowlisted[codeId][user]) return false;
        if (c.oncePerUser && $.hasRedeemed[codeId][user]) return false;
        return true;
    }

    /// @inheritdoc IPromoCodeRegistry
    function hasUserRedeemed(
        bytes32 codeId,
        address user
    ) external view override returns (bool) {
        return _getStorage().hasRedeemed[codeId][user];
    }

    /// @inheritdoc IPromoCodeRegistry
    function isAllowlisted(
        bytes32 codeId,
        address user
    ) external view override returns (bool) {
        return _getStorage().allowlisted[codeId][user];
    }

    /// @inheritdoc IPromoCodeRegistry
    function previewDiscount(
        bytes32 codeId,
        address user,
        uint256 price
    ) external view override returns (uint256 discountedPrice) {
        if (codeId == bytes32(0)) return price;
        PromoCodeRegistryStorage storage $ = _getStorage();
        PromoCode storage c = $.codes[codeId];
        // Return full price for any ineligible or non-discount code.
        if (!c.exists || c.kind != PromoKind.Discount) return price;
        if (!c.active) return price;
        if (c.expiry != 0 && block.timestamp > c.expiry) return price;
        if (c.maxRedemptions != 0 && c.redeemedCount >= c.maxRedemptions)
            return price;
        if (c.restricted && !$.allowlisted[codeId][user]) return price;
        if (c.oncePerUser && $.hasRedeemed[codeId][user]) return price;
        discountedPrice = price - (price * c.bps) / BPS;
    }

    /// @notice Address of the configured PackMachineFactory proxy.
    function packMachineFactory() external view returns (address) {
        return _getStorage().packMachineFactory;
    }

    /// @notice Address of the configured BuybackPool proxy.
    function buybackPool() external view returns (address) {
        return _getStorage().buybackPool;
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Validate bps is within the allowed range [100, 10000] (1%–100%).
    ///      Applies to both Discount and Buyback kinds.
    function _validateBps(PromoKind kind, uint16 bps) private pure {
        if (bps < 100 || bps > BPS)
            revert PromoCodeRegistry__InvalidBps(kind, bps);
    }

    /// @dev Revert if codeId does not exist; return storage ref otherwise.
    function _requireExists(
        bytes32 codeId
    ) private view returns (PromoCode storage c) {
        c = _getStorage().codes[codeId];
        if (!c.exists) revert PromoCodeRegistry__CodeNotFound(codeId);
    }

    /// @dev Fail-fast validator + state mutation.  Order:
    ///      exists → kind matches → active → not expired → under cap
    ///      → (restricted ⇒ allowlisted) → (oncePerUser ⇒ not yet redeemed)
    ///      → increment count → optionally mark redeemed → emit → return bps.
    function _validateAndConsume(
        PromoCodeRegistryStorage storage $,
        bytes32 codeId,
        address user,
        PromoKind expectedKind
    ) private returns (uint16 bps) {
        PromoCode storage c = $.codes[codeId];

        if (!c.exists) revert PromoCodeRegistry__CodeNotFound(codeId);
        if (c.kind != expectedKind)
            revert PromoCodeRegistry__WrongKind(codeId, expectedKind, c.kind);
        if (!c.active) revert PromoCodeRegistry__Inactive(codeId);
        if (c.expiry != 0 && block.timestamp > c.expiry)
            revert PromoCodeRegistry__Expired(codeId);
        if (c.maxRedemptions != 0 && c.redeemedCount >= c.maxRedemptions)
            revert PromoCodeRegistry__LimitReached(codeId);
        if (c.restricted && !$.allowlisted[codeId][user])
            revert PromoCodeRegistry__NotAllowlisted(codeId, user);
        if (c.oncePerUser && $.hasRedeemed[codeId][user])
            revert PromoCodeRegistry__AlreadyRedeemed(codeId, user);

        unchecked {
            c.redeemedCount += 1;
        }
        if (c.oncePerUser) $.hasRedeemed[codeId][user] = true;

        bps = c.bps;
        emit CodeRedeemed(codeId, user, expectedKind, bps, c.redeemedCount);
    }
}
