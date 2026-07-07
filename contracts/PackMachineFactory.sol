// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";
import {IPackMachine} from "./interfaces/IPackMachine.sol";
import {IPackVRFRouter} from "./interfaces/IPackVRFRouter.sol";
import {IPackRegistry} from "./interfaces/IPackRegistry.sol";

/// @title PackMachineFactory
/// @author NettyWorth
/// @notice UUPS-upgradeable singleton factory. Deploys PackMachine clones (EIP-1167), registers them
///         with the PackVRFRouter, and acts as a transfer-validator relay for all pack machines.
/// @custom:security-contact security@nettyworth.io
contract PackMachineFactory is
    UUPSUpgradeable,
    PermissionConsumer,
    ERC2771ContextUpgradeable
{
    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.PackMachineFactory
    struct PackMachineFactoryStorage {
        address implementation;
        address packVRFRouter;
        address assetNFT;
        address paymentToken;
        address financeWallet;
        mapping(address => bool) isPackMachine;
        address[] allPackMachines;
        mapping(address => bool) trustedForwarders;
        address buybackPool;
        // ── Appended ──────────────────────────────────────────────────────────
        /// @dev PromoCodeRegistry proxy address.  Passed to PackMachine clones via
        ///      IPackMachineFactory.promoCodeRegistry() so they can call redeemDiscount.
        address promoCodeRegistry;
        // ── Appended ──────────────────────────────────────────────────────────
        /// @dev PackRegistry proxy address. Clones read pack definitions from here via
        ///      IPackMachineFactory.packRegistry(). Must be set before createPackMachine.
        address packRegistry;
        // ── Appended ──────────────────────────────────────────────────────────
        /// @dev Global first-open discount. When enabled, a wallet that has never opened
        ///      a pack on a given PackMachine receives `firstOpenDiscountBps` off its first
        ///      purchase. Discount flag is reset on a fully-failed (zero-card) VRF open.
        bool firstOpenDiscountEnabled;
        uint16 firstOpenDiscountBps;
        // ── Appended ──────────────────────────────────────────────────────────
        /// @dev PackTierRegistry proxy address. Clones read/write per-(token, pack) tier data
        ///      here via IPackMachineFactory.packTierRegistry() instead of carrying the storage
        ///      themselves — keeps PackMachine bytecode under the 24 KiB EVM limit.
        address packTierRegistry;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.PackMachineFactory")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PACK_MACHINE_FACTORY_STORAGE_SLOT =
        0x8e80552b741b8b80b7858148bf33ea537542bd5cd613b93df76c968fde960e00;

    function _getStorage()
        private
        pure
        returns (PackMachineFactoryStorage storage $)
    {
        assembly {
            $.slot := PACK_MACHINE_FACTORY_STORAGE_SLOT
        }
    }

    // =========================================================================
    // Events
    // =========================================================================

    event PackMachineCreated(
        address indexed packMachine,
        uint128 pricePerPack,
        uint8 cardsPerPack
    );
    event ImplementationUpdated(
        address indexed oldImpl,
        address indexed newImpl
    );
    event FinanceWalletUpdated(
        address indexed oldWallet,
        address indexed newWallet
    );
    event VRFRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );
    event TrustedForwarderUpdated(address indexed forwarder, bool trusted);
    event BuybackPoolUpdated(address indexed oldPool, address indexed newPool);
    event PromoCodeRegistryUpdated(
        address indexed oldRegistry,
        address indexed newRegistry
    );
    event PackRegistryUpdated(
        address indexed oldRegistry,
        address indexed newRegistry
    );
    event PackTierRegistryUpdated(
        address indexed oldRegistry,
        address indexed newRegistry
    );
    event FirstOpenDiscountUpdated(bool enabled, uint16 bps);

    // =========================================================================
    // Errors
    // =========================================================================

    error PackMachineFactory__ZeroAddress();
    error PackMachineFactory__ImplementationNotSet();
    error PackMachineFactory__FinanceWalletNotSet();
    error PackMachineFactory__VRFRouterNotSet();
    error PackMachineFactory__AssetNFTNotSet();
    error PackMachineFactory__PaymentTokenNotSet();
    error PackMachineFactory__OnlyPackMachine(address caller);
    error PackMachineFactory__InvalidCardsPerPack();
    error PackMachineFactory__PackRegistryNotSet();
    error PackMachineFactory__InvalidDiscountBps();

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyPackMachine() {
        if (!_getStorage().isPackMachine[msg.sender]) {
            revert PackMachineFactory__OnlyPackMachine(msg.sender);
        }
        _;
    }

    // =========================================================================
    // Constructor & initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder
    ) ERC2771ContextUpgradeable(trustedForwarder) {
        _disableInitializers();
    }

    /// @notice Initializes the factory.
    /// @param permissionManager_ Protocol PermissionManager address.
    /// @param assetNFT_ AssetNFT contract address (the NFT cards are drawn from).
    /// @param paymentToken_ ERC-20 token used for payment (USDC).
    /// @param financeWallet_ Address that receives payment from pack opens.
    function initialize(
        address permissionManager_,
        address assetNFT_,
        address paymentToken_,
        address financeWallet_
    ) external initializer {
        if (assetNFT_ == address(0)) revert PackMachineFactory__ZeroAddress();
        if (paymentToken_ == address(0))
            revert PackMachineFactory__ZeroAddress();
        if (financeWallet_ == address(0))
            revert PackMachineFactory__ZeroAddress();

        __PermissionConsumer_init(permissionManager_);

        PackMachineFactoryStorage storage $ = _getStorage();
        $.assetNFT = assetNFT_;
        $.paymentToken = paymentToken_;
        $.financeWallet = financeWallet_;
    }

    // =========================================================================
    // Factory
    // =========================================================================

    /// @notice Deploy a new PackMachine clone and register it with the VRF router.
    /// @param pricePerPack_ USDC cost per pack (6-decimal precision).
    /// @param cardsPerPack_ Number of cards dispensed per pack open.
    /// @param startTime_ Unix timestamp from which pack opens are permitted.
    /// @return packMachine Address of the newly created PackMachine clone.
    function createPackMachine(
        uint128 pricePerPack_,
        uint8 cardsPerPack_,
        uint40 startTime_
    )
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
        returns (address packMachine)
    {
        PackMachineFactoryStorage storage $ = _getStorage();

        if ($.implementation == address(0))
            revert PackMachineFactory__ImplementationNotSet();
        if ($.financeWallet == address(0))
            revert PackMachineFactory__FinanceWalletNotSet();
        if ($.packVRFRouter == address(0))
            revert PackMachineFactory__VRFRouterNotSet();
        if ($.assetNFT == address(0))
            revert PackMachineFactory__AssetNFTNotSet();
        if ($.paymentToken == address(0))
            revert PackMachineFactory__PaymentTokenNotSet();
        if ($.packRegistry == address(0))
            revert PackMachineFactory__PackRegistryNotSet();
        if (cardsPerPack_ == 0)
            revert PackMachineFactory__InvalidCardsPerPack();

        packMachine = Clones.clone($.implementation);
        IPackMachine(packMachine).initialize(
            getPermissionManager(),
            address(this),
            pricePerPack_,
            cardsPerPack_,
            startTime_
        );

        $.isPackMachine[packMachine] = true;
        $.allPackMachines.push(packMachine);

        // Bootstrap pack 0 in the registry. The registry is the source of truth for
        // all pack definitions; the clone holds no Pack array.
        IPackRegistry($.packRegistry).registerMachine(
            packMachine,
            pricePerPack_,
            cardsPerPack_,
            startTime_
        );

        // The PackVRFRouter.setAuthorizedPackMachine call must be done by an admin
        // (PACK_OPERATOR_ROLE) separately, because PackVRFRouter has its own access control.
        // Emitting the event here notifies off-chain tooling to complete that step.
        emit PackMachineCreated(packMachine, pricePerPack_, cardsPerPack_);
    }

    // =========================================================================
    // Transfer-validator relay (called by registered PackMachines)
    // =========================================================================

    /// @notice Called by a PackMachine before transferring an AssetNFT.
    ///         Relays to the NFT's transfer validator if one is configured (Creator Token Standard).
    function beforeTransfer(address token) external onlyPackMachine {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(0x098144d4)
        );
        if (success && data.length >= 32) {
            address transferValidator = abi.decode(data, (address));
            if (transferValidator != address(0)) {
                (bool ok, bytes memory revertData) = transferValidator.call(
                    abi.encodeWithSelector(0x50793315, _msgSender(), token)
                );
                if (!ok) {
                    // Bubble up the validator's revert payload.
                    assembly {
                        revert(add(revertData, 32), mload(revertData))
                    }
                }
            }
        }
    }

    /// @notice Called by a PackMachine after transferring an AssetNFT.
    function afterTransfer(address token) external onlyPackMachine {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(0x098144d4)
        );
        if (success && data.length >= 32) {
            address transferValidator = abi.decode(data, (address));
            if (transferValidator != address(0)) {
                (bool ok, bytes memory revertData) = transferValidator.call(
                    abi.encodeWithSelector(0x0ad38899, token)
                );
                if (!ok) {
                    assembly {
                        revert(add(revertData, 32), mload(revertData))
                    }
                }
            }
        }
    }

    // =========================================================================
    // Admin — configuration
    // =========================================================================

    function setImplementation(
        address impl
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (impl == address(0)) revert PackMachineFactory__ZeroAddress();
        PackMachineFactoryStorage storage $ = _getStorage();
        emit ImplementationUpdated($.implementation, impl);
        $.implementation = impl;
    }

    function setPackVRFRouter(
        address router
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (router == address(0)) revert PackMachineFactory__ZeroAddress();
        PackMachineFactoryStorage storage $ = _getStorage();
        emit VRFRouterUpdated($.packVRFRouter, router);
        $.packVRFRouter = router;
    }

    function setFinanceWallet(
        address wallet
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (wallet == address(0)) revert PackMachineFactory__ZeroAddress();
        PackMachineFactoryStorage storage $ = _getStorage();
        emit FinanceWalletUpdated($.financeWallet, wallet);
        $.financeWallet = wallet;
    }

    function setAssetNFT(
        address nft
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (nft == address(0)) revert PackMachineFactory__ZeroAddress();
        _getStorage().assetNFT = nft;
    }

    function setPaymentToken(
        address token
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert PackMachineFactory__ZeroAddress();
        _getStorage().paymentToken = token;
    }

    function setTrustedForwarder(
        address forwarder,
        bool trusted
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _getStorage().trustedForwarders[forwarder] = trusted;
        emit TrustedForwarderUpdated(forwarder, trusted);
    }

    function setBuybackPool(
        address pool
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (pool == address(0)) revert PackMachineFactory__ZeroAddress();
        PackMachineFactoryStorage storage $ = _getStorage();
        emit BuybackPoolUpdated($.buybackPool, pool);
        $.buybackPool = pool;
    }

    function setPromoCodeRegistry(
        address registry
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (registry == address(0)) revert PackMachineFactory__ZeroAddress();
        PackMachineFactoryStorage storage $ = _getStorage();
        emit PromoCodeRegistryUpdated($.promoCodeRegistry, registry);
        $.promoCodeRegistry = registry;
    }

    function setPackRegistry(
        address registry
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (registry == address(0)) revert PackMachineFactory__ZeroAddress();
        PackMachineFactoryStorage storage $ = _getStorage();
        emit PackRegistryUpdated($.packRegistry, registry);
        $.packRegistry = registry;
    }

    function setPackTierRegistry(
        address registry
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (registry == address(0)) revert PackMachineFactory__ZeroAddress();
        PackMachineFactoryStorage storage $ = _getStorage();
        emit PackTierRegistryUpdated($.packTierRegistry, registry);
        $.packTierRegistry = registry;
    }

    /// @notice Configure the global first-open pack discount.
    /// @param enabled Whether the discount is active.
    /// @param bps     Discount in basis points (max 10 000 = 100%).
    function setFirstOpenDiscount(
        bool enabled,
        uint16 bps
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert PackMachineFactory__InvalidDiscountBps();
        PackMachineFactoryStorage storage $ = _getStorage();
        $.firstOpenDiscountEnabled = enabled;
        $.firstOpenDiscountBps = bps;
        emit FirstOpenDiscountUpdated(enabled, bps);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function isPackMachine(address machine) external view returns (bool) {
        return _getStorage().isPackMachine[machine];
    }

    function financeWallet() external view returns (address) {
        return _getStorage().financeWallet;
    }

    function paymentToken() external view returns (address) {
        return _getStorage().paymentToken;
    }

    function assetNFT() external view returns (address) {
        return _getStorage().assetNFT;
    }

    function packVRFRouter() external view returns (address) {
        return _getStorage().packVRFRouter;
    }

    function buybackPool() external view returns (address) {
        return _getStorage().buybackPool;
    }

    function promoCodeRegistry() external view returns (address) {
        return _getStorage().promoCodeRegistry;
    }

    function packRegistry() external view returns (address) {
        return _getStorage().packRegistry;
    }

    function packTierRegistry() external view returns (address) {
        return _getStorage().packTierRegistry;
    }

    function getAllPackMachines() external view returns (address[] memory) {
        return _getStorage().allPackMachines;
    }

    function firstOpenDiscountEnabled() external view returns (bool) {
        return _getStorage().firstOpenDiscountEnabled;
    }

    function firstOpenDiscountBps() external view returns (uint16) {
        return _getStorage().firstOpenDiscountBps;
    }

    function isTrustedForwarder(
        address forwarder
    ) public view override returns (bool) {
        return
            super.isTrustedForwarder(forwarder) ||
            _getStorage().trustedForwarders[forwarder];
    }

    // =========================================================================
    // ERC-2771 overrides
    // =========================================================================

    function _msgSender()
        internal
        view
        override(PermissionConsumer, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        override(ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    function _authorizeUpgrade(
        address
    ) internal override onlyProtocolRole(Roles.UPGRADER_ROLE) {}
}
