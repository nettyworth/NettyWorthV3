// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";
import {PackTypes} from "./lib/PackTypes.sol";
import {IPackRegistry} from "./interfaces/IPackRegistry.sol";
import {IPackMachine} from "./interfaces/IPackMachine.sol";

/// @title PackRegistry
/// @author NettyWorth
/// @notice UUPS-upgradeable singleton that is the single source of truth for pack definitions
///         across all PackMachine clones. Operators manage all packs (price, tier weights,
///         buyback allocation, start time, active/finished state) through this one contract
///         rather than calling individual clone setters.
/// @dev Pack definitions are stored in `packs[machine][packId]`. PackMachine clones hold no
///      local Pack array — they fetch a `PackTypes.Pack memory` from here at the top of every
///      open flow and in `fulfillRandomness`.
///      Bootstrap path: PackMachineFactory calls `registerMachine` (onlyFactory) immediately
///      after cloning, which creates pack 0 with default weights and activates the machine.
/// @custom:security-contact security@nettyworth.io
contract PackRegistry is UUPSUpgradeable, PermissionConsumer {
    // =========================================================================
    // Constants
    // =========================================================================

    uint256 private constant NUM_TIERS = 6;

    /// @dev Tier weights are expressed in basis points; all six must sum to this value.
    uint16 private constant WEIGHT_PRECISION = 10000;

    /// @dev Returns the default pack-0 tier weight distribution:
    ///      Base 70.40% / Common 25% / Uncommon 4% / Rare 0.50% / Ultra Rare 0.09% / Grail 0.01%.
    function _defaultTierWeights() private pure returns (uint32[6] memory) {
        return [uint32(7040), 2500, 400, 50, 9, 1];
    }

    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.PackRegistry
    struct PackRegistryStorage {
        /// @dev PackMachineFactory address — only it can call registerMachine.
        address factory;
        /// @dev Set of machines registered (bootstrapped) by the factory.
        mapping(address machine => bool) registered;
        /// @dev Pack definitions keyed by machine address; packId == array index.
        mapping(address machine => PackTypes.Pack[]) packs;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.PackRegistry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PACK_REGISTRY_STORAGE_SLOT =
        0x051948dd914a2e26cbeb540527ddd2a939cd898f59c5a55b473376d6422dd400;

    function _getStorage()
        private
        pure
        returns (PackRegistryStorage storage $)
    {
        assembly {
            $.slot := PACK_REGISTRY_STORAGE_SLOT
        }
    }

    // =========================================================================
    // Events
    // =========================================================================

    event MachineRegistered(address indexed machine);
    event FactoryUpdated(
        address indexed oldFactory,
        address indexed newFactory
    );
    // Pack events (mirror the old per-clone events, extended with `machine`).
    event PackAdded(
        address indexed machine,
        uint256 indexed packId,
        uint128 pricePerPack,
        uint8 cardsPerPack
    );
    event PackStopped(address indexed machine, uint256 indexed packId);
    event PackActiveUpdated(
        address indexed machine,
        uint256 indexed packId,
        bool active
    );
    event PackPriceUpdated(
        address indexed machine,
        uint256 indexed packId,
        uint128 oldPrice,
        uint128 newPrice
    );
    event PackTierWeightsUpdated(
        address indexed machine,
        uint256 indexed packId,
        uint32[6] weights
    );
    event PackBuybackAllocationUpdated(
        address indexed machine,
        uint256 indexed packId,
        uint16 oldBps,
        uint16 newBps
    );
    event PackStartTimeUpdated(
        address indexed machine,
        uint256 indexed packId,
        uint40 startTime
    );
    event PackTierFmvBoundsUpdated(
        address indexed machine,
        uint256 indexed packId,
        uint128[6] minFmv,
        uint128[6] maxFmv
    );
    event PackCardBoundsUpdated(
        address indexed machine,
        uint256 indexed packId,
        uint32 minCards,
        uint32 maxCards
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error PackRegistry__OnlyFactory(address caller);
    error PackRegistry__MachineNotRegistered(address machine);
    error PackRegistry__AlreadyRegistered(address machine);
    error PackRegistry__InvalidPackId(address machine, uint256 packId);
    error PackRegistry__InvalidWeights(uint256 total);
    error PackRegistry__InvalidBps(uint16 given);
    error PackRegistry__PackFinished(address machine, uint256 packId);
    error PackRegistry__ZeroAddress();
    error PackRegistry__InvalidCardsPerPack();
    error PackRegistry__TooManyPacks();
    error PackRegistry__InvalidFmvBounds(uint256 tier);
    error PackRegistry__InvalidCardBounds(uint32 minCards, uint32 maxCards);
    error PackRegistry__MaxCardsNotReached(uint256 available, uint32 maxCards);

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyFactory() {
        PackRegistryStorage storage $ = _getStorage();
        if ($.factory == address(0) || msg.sender != $.factory) {
            revert PackRegistry__OnlyFactory(msg.sender);
        }
        _;
    }

    modifier onlyRegistered(address machine) {
        if (!_getStorage().registered[machine]) {
            revert PackRegistry__MachineNotRegistered(machine);
        }
        _;
    }

    // =========================================================================
    // Constructor & initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the registry.
    /// @param permissionManager_ Protocol PermissionManager address.
    /// @dev Factory is wired post-deploy via setFactory to avoid deploy-ordering circularity.
    function initialize(address permissionManager_) external initializer {
        __PermissionConsumer_init(permissionManager_);
    }

    // =========================================================================
    // Admin — factory wiring
    // =========================================================================

    /// @notice Set the PackMachineFactory address. Only it may call registerMachine.
    function setFactory(
        address factory_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (factory_ == address(0)) revert PackRegistry__ZeroAddress();
        PackRegistryStorage storage $ = _getStorage();
        emit FactoryUpdated($.factory, factory_);
        $.factory = factory_;
    }

    // =========================================================================
    // Bootstrap (factory-only)
    // =========================================================================

    /// @notice Register a newly-cloned PackMachine and create its pack 0.
    ///         Called by PackMachineFactory immediately after cloning.
    /// @param machine       Address of the newly-cloned PackMachine.
    /// @param pricePerPack  USDC cost per pack (6-decimal precision) for pack 0.
    /// @param cardsPerPack  Number of cards dispensed per pack open for pack 0.
    /// @param startTime     Unix timestamp from which pack opens are permitted for pack 0.
    function registerMachine(
        address machine,
        uint128 pricePerPack,
        uint8 cardsPerPack,
        uint40 startTime
    ) external onlyFactory {
        PackRegistryStorage storage $ = _getStorage();
        if ($.registered[machine])
            revert PackRegistry__AlreadyRegistered(machine);
        if (cardsPerPack == 0) revert PackRegistry__InvalidCardsPerPack();

        $.registered[machine] = true;

        // Bootstrap pack 0 with default weights: Base 75% / Common 19.5% / Uncommon 4% / Rare 1% / Ultra 0.5%.
        PackTypes.Pack memory pack;
        pack.pricePerPack = pricePerPack;
        pack.cardsPerPack = cardsPerPack;
        pack.startTime = startTime;
        pack.buybackAllocationBps = 0;
        pack.active = true;
        pack.finished = false;
        pack.tierWeights = _defaultTierWeights();
        $.packs[machine].push(pack);

        emit MachineRegistered(machine);
        emit PackAdded(machine, 0, pricePerPack, cardsPerPack);
    }

    // =========================================================================
    // Pack-config admin (PACK_OPERATOR_ROLE)
    // =========================================================================

    /// @notice Add a new pack to a registered machine. All packs share the machine's card pool.
    /// @param machine              Address of the registered PackMachine.
    /// @param pricePerPack_        USDC cost per pack (6-decimal precision).
    /// @param cardsPerPack_        Number of cards dispensed per pack open (must be > 0).
    /// @param startTime_           Unix timestamp from which pack opens are permitted.
    /// @param buybackAllocationBps_ Basis points of price routed to BuybackPool (0–10000).
    /// @param tierWeights_          Five weights in bps summing to 10000: [Base,Common,Uncommon,Rare,Ultra].
    /// @return packId The index of the new pack.
    function addPack(
        address machine,
        uint128 pricePerPack_,
        uint8 cardsPerPack_,
        uint40 startTime_,
        uint16 buybackAllocationBps_,
        uint32[6] calldata tierWeights_
    )
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
        onlyRegistered(machine)
        returns (uint256 packId)
    {
        if (cardsPerPack_ == 0) revert PackRegistry__InvalidCardsPerPack();
        if (buybackAllocationBps_ > WEIGHT_PRECISION)
            revert PackRegistry__InvalidBps(buybackAllocationBps_);
        uint256 total;
        for (uint256 i; i < NUM_TIERS; ++i) {
            total += tierWeights_[i];
        }
        if (total != WEIGHT_PRECISION)
            revert PackRegistry__InvalidWeights(total);

        PackRegistryStorage storage $ = _getStorage();
        if ($.packs[machine].length >= 256) revert PackRegistry__TooManyPacks();
        packId = $.packs[machine].length;

        PackTypes.Pack memory pack;
        pack.pricePerPack = pricePerPack_;
        pack.cardsPerPack = cardsPerPack_;
        pack.startTime = startTime_;
        pack.buybackAllocationBps = buybackAllocationBps_;
        pack.active = true;
        pack.finished = false;
        pack.tierWeights = tierWeights_;
        $.packs[machine].push(pack);

        emit PackAdded(machine, packId, pricePerPack_, cardsPerPack_);
    }

    /// @notice Permanently stop a single pack. Irreversible. Other packs on the machine are unaffected.
    function stopPack(
        address machine,
        uint256 packId
    )
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
        onlyRegistered(machine)
    {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        $.packs[machine][packId].finished = true;
        emit PackStopped(machine, packId);
    }

    /// @notice Pause or unpause a single pack (reversible).
    ///         When enabling (active = true) and pack.maxCards > 0, the pack's current eligible
    ///         card count (availablePerPack) must be >= maxCards. This ensures the pack is fully
    ///         stocked before opening to buyers. Disabling is never gated.
    function setPackActive(
        address machine,
        uint256 packId,
        bool active
    )
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
        onlyRegistered(machine)
    {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        PackTypes.Pack storage pack = $.packs[machine][packId];
        if (pack.finished) revert PackRegistry__PackFinished(machine, packId);
        // Enforce maxCards gate only when enabling.
        if (active && pack.maxCards != 0) {
            uint256 available = IPackMachine(machine).getPackAvailable(packId);
            if (available < pack.maxCards)
                revert PackRegistry__MaxCardsNotReached(
                    available,
                    pack.maxCards
                );
        }
        pack.active = active;
        emit PackActiveUpdated(machine, packId, active);
    }

    /// @notice Update the price of a pack.
    /// @dev Unlike the old per-clone setter, this does NOT require the machine to be paused.
    ///      PackMachine reads pack config live on every open, so the new price takes effect
    ///      immediately on the next call.
    function setPackPrice(
        address machine,
        uint256 packId,
        uint128 newPrice
    )
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
        onlyRegistered(machine)
    {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        PackTypes.Pack storage pack = $.packs[machine][packId];
        if (pack.finished) revert PackRegistry__PackFinished(machine, packId);
        emit PackPriceUpdated(machine, packId, pack.pricePerPack, newPrice);
        pack.pricePerPack = newPrice;
    }

    /// @notice Update the tier weights for a pack. Weights must sum to 10000.
    function setPackTierWeights(
        address machine,
        uint256 packId,
        uint32[6] calldata weights
    )
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
        onlyRegistered(machine)
    {
        uint256 total;
        for (uint256 i; i < NUM_TIERS; ++i) {
            total += weights[i];
        }
        if (total != WEIGHT_PRECISION)
            revert PackRegistry__InvalidWeights(total);

        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        PackTypes.Pack storage pack = $.packs[machine][packId];
        if (pack.finished) revert PackRegistry__PackFinished(machine, packId);
        pack.tierWeights = weights;
        emit PackTierWeightsUpdated(machine, packId, weights);
    }

    /// @notice Update the buyback allocation for a pack (0–10000 bps).
    function setPackBuybackAllocation(
        address machine,
        uint256 packId,
        uint16 bps
    )
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
        onlyRegistered(machine)
    {
        if (bps > WEIGHT_PRECISION) revert PackRegistry__InvalidBps(bps);

        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        PackTypes.Pack storage pack = $.packs[machine][packId];
        if (pack.finished) revert PackRegistry__PackFinished(machine, packId);
        emit PackBuybackAllocationUpdated(
            machine,
            packId,
            pack.buybackAllocationBps,
            bps
        );
        pack.buybackAllocationBps = bps;
    }

    /// @notice Update the start time of a pack.
    function setPackStartTime(
        address machine,
        uint256 packId,
        uint40 startTime
    )
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
        onlyRegistered(machine)
    {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        PackTypes.Pack storage pack = $.packs[machine][packId];
        if (pack.finished) revert PackRegistry__PackFinished(machine, packId);
        pack.startTime = startTime;
        emit PackStartTimeUpdated(machine, packId, startTime);
    }

    /// @notice Update per-tier FMV bounds for a pack.
    ///         min=0 and max=0 for a tier means "unset" — PackMachine will reject deposits into
    ///         that tier until bounds are configured.
    /// @param machine  Registered PackMachine address.
    /// @param packId   Target pack index.
    /// @param minFmv   Inclusive lower bound per tier (payment-token units).
    /// @param maxFmv   Inclusive upper bound per tier (must be >= minFmv unless both are 0).
    function setPackTierFmvBounds(
        address machine,
        uint256 packId,
        uint128[6] calldata minFmv,
        uint128[6] calldata maxFmv
    )
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
        onlyRegistered(machine)
    {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        PackTypes.Pack storage pack = $.packs[machine][packId];
        if (pack.finished) revert PackRegistry__PackFinished(machine, packId);
        for (uint256 i; i < NUM_TIERS; ++i) {
            // Allow (0,0) = unset. Any other combination requires min <= max.
            if (maxFmv[i] != 0 && minFmv[i] > maxFmv[i])
                revert PackRegistry__InvalidFmvBounds(i);
        }
        pack.tierMinFmv = minFmv;
        pack.tierMaxFmv = maxFmv;
        emit PackTierFmvBoundsUpdated(machine, packId, minFmv, maxFmv);
    }

    /// @notice Set the minimum and maximum eligible card-count bounds for a pack.
    ///         minCards: opens revert when availablePerPack < minCards (0 = no floor).
    ///         maxCards: setPackActive(true) reverts until availablePerPack >= maxCards (0 = no gate).
    ///         Requires minCards <= maxCards unless either is 0.
    function setPackCardBounds(
        address machine,
        uint256 packId,
        uint32 minCards,
        uint32 maxCards
    )
        external
        onlyProtocolRole(Roles.PACK_OPERATOR_ROLE)
        onlyRegistered(machine)
    {
        if (maxCards != 0 && minCards > maxCards)
            revert PackRegistry__InvalidCardBounds(minCards, maxCards);
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        PackTypes.Pack storage pack = $.packs[machine][packId];
        if (pack.finished) revert PackRegistry__PackFinished(machine, packId);
        pack.minCards = minCards;
        pack.maxCards = maxCards;
        emit PackCardBoundsUpdated(machine, packId, minCards, maxCards);
    }

    // =========================================================================
    // Views
    // =========================================================================

    function factory() external view returns (address) {
        return _getStorage().factory;
    }

    function isRegistered(address machine) external view returns (bool) {
        return _getStorage().registered[machine];
    }

    function getPack(
        address machine,
        uint256 packId
    ) external view returns (PackTypes.Pack memory) {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        return $.packs[machine][packId];
    }

    function getPackCount(address machine) external view returns (uint256) {
        return _getStorage().packs[machine].length;
    }

    function getPackPrice(
        address machine,
        uint256 packId
    ) external view returns (uint128) {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        return $.packs[machine][packId].pricePerPack;
    }

    function getPackCardsPerPack(
        address machine,
        uint256 packId
    ) external view returns (uint8) {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        return $.packs[machine][packId].cardsPerPack;
    }

    function getPackTierWeights(
        address machine,
        uint256 packId
    ) external view returns (uint32[6] memory) {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        return $.packs[machine][packId].tierWeights;
    }

    /// @notice Returns the per-tier FMV bounds for a pack.
    ///         (0,0) for a tier means unset — deposits into that tier are rejected.
    function getPackTierFmvBounds(
        address machine,
        uint256 packId
    )
        external
        view
        returns (uint128[6] memory minFmv, uint128[6] memory maxFmv)
    {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        PackTypes.Pack storage pack = $.packs[machine][packId];
        return (pack.tierMinFmv, pack.tierMaxFmv);
    }

    /// @notice Returns the min/max eligible card-count bounds for a pack.
    ///         (0,0) means no bounds configured.
    function getPackCardBounds(
        address machine,
        uint256 packId
    ) external view returns (uint32 minCards, uint32 maxCards) {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        PackTypes.Pack storage pack = $.packs[machine][packId];
        return (pack.minCards, pack.maxCards);
    }

    function getPackBuybackAllocationBps(
        address machine,
        uint256 packId
    ) external view returns (uint16) {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        return $.packs[machine][packId].buybackAllocationBps;
    }

    function isPackActive(
        address machine,
        uint256 packId
    ) external view returns (bool) {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        return $.packs[machine][packId].active;
    }

    function isPackFinished(
        address machine,
        uint256 packId
    ) external view returns (bool) {
        PackRegistryStorage storage $ = _getStorage();
        if (packId >= $.packs[machine].length)
            revert PackRegistry__InvalidPackId(machine, packId);
        return $.packs[machine][packId].finished;
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    function _authorizeUpgrade(
        address
    ) internal override onlyProtocolRole(Roles.UPGRADER_ROLE) {}
}
