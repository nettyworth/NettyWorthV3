// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC721AQueryableUpgradeable} from "erc721a-upgradeable/contracts/extensions/ERC721AQueryableUpgradeable.sol";
import {
    ERC721AUpgradeable,
    IERC721AUpgradeable
} from "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITransferValidator} from "./interfaces/ITransferValidator.sol";
import {IFeeController} from "./interfaces/IFeeController.sol";
import {IAssetLendingPool} from "./interfaces/IAssetLendingPool.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";

/// @title AssetNFT
/// @author NettyWorth
/// @notice ERC-721A token representing tokenized physical assets with lifecycle state management and role-based access control.
/// @dev UUPS upgradeable proxy pattern (EIP-1822). Storage uses ERC-7201 namespaced slots to avoid collisions across
///      upgrades. Asset lifecycle transitions are validated via a packed 48-bit bitmask (one byte per state).
///      ERC-2771 meta-transaction support: trusted forwarder is immutable per implementation — change by upgrading.
///      Access control is delegated to the protocol-wide PermissionManager via PermissionConsumer.
/// @custom:security-contact security@nettyworth.io
contract AssetNFT is
    ERC721AQueryableUpgradeable,
    ERC2771ContextUpgradeable,
    ERC2981Upgradeable,
    PermissionConsumer,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // =========================================================================
    // State machine
    // =========================================================================

    /// @notice Lifecycle states an asset token can occupy on the platform.
    enum AssetState {
        Held, // 0 — in Brinks custody, available for platform actions
        Listed, // 1 — listed on marketplace
        Loaned, // 2 — locked as loan collateral
        Traded, // 3 — locked in an active trade/swap
        InShipment, // 4 — physically in transit
        RemovedFromPlatform // 5 — retired; terminal state
    }

    // Packed transition bitmasks: byte N = allowed target states from AssetState(N).
    // Bit K set in byte N means transition from state N to state K is valid.
    // Held(0):        Listed,Loaned,Traded,InShipment,Removed → 0x3E  (byte 0, LSB)
    // Listed(1):      Held,Removed                            → 0x21  (byte 1)
    // Loaned(2):      Held                                    → 0x01  (byte 2)
    // Traded(3):      Held                                    → 0x01  (byte 3)
    // InShipment(4):  Held,Removed                            → 0x21  (byte 4)
    // Removed(5):     (terminal)                              → 0x00  (byte 5, MSB)
    uint48 private constant TRANSITIONS = 0x00210101213E;

    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @notice Namespaced storage struct for AssetNFT to avoid upgrade slot collisions.
    /// @custom:storage-location erc7201:nettyworth.storage.AssetNFT
    struct AssetNFTStorage {
        mapping(uint256 => AssetState) assetStates;
        string contractURIValue;
        string baseURIValue;
        /// @dev Per-token URI storage (replaces ERC721URIStorageUpgradeable).
        mapping(uint256 => string) tokenURIs;
        /// @dev Address-level blacklist for blocking transfers.
        mapping(address => bool) isBlacklisted;
        /// @dev External transfer validator contract (address(0) = disabled).
        address transferValidator;
        // =====================================================================
        // V3: Physical redemption / shipment fee config
        // =====================================================================
        /// @dev ERC20 payment token used to collect the redemption fee (e.g. USDC).
        IERC20 paymentToken;
        /// @dev Platform treasury that receives the redemption fee.
        address treasury;
        /// @dev FeeController that supplies the redemptionFeeBps and enabled flag.
        address feeController;
        /// @dev AssetLendingPool used to look up appraisal value for fee calculation.
        address lendingPool;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.AssetNFT")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASSET_NFT_STORAGE_SLOT =
        0xdf981ac21670c8d86950dabc51999eae0654f62defa8cd0d5ce4ac3696fabe00;

    function _getAssetNFTStorage()
        private
        pure
        returns (AssetNFTStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := ASSET_NFT_STORAGE_SLOT
        }
    }

    // =========================================================================
    // EIP-4906 events (not defined by ERC721A)
    // =========================================================================

    /// @dev EIP-4906: emitted when metadata for a single token is updated.
    event MetadataUpdate(uint256 _tokenId);

    /// @dev EIP-4906: emitted when metadata for a range of tokens is updated.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a token's lifecycle state is updated.
    event AssetStateChanged(
        uint256 indexed tokenId,
        AssetState indexed previousState,
        AssetState indexed newState
    );

    /// @notice Emitted when the collection-level contract URI is updated.
    event ContractURIUpdated();

    /// @notice Emitted when the base URI for token metadata is updated.
    event BaseURIUpdated(string uri);

    /// @notice Emitted when an address's blacklist status is changed.
    event BlacklistUpdated(address indexed account, bool indexed status);

    /// @notice Emitted when the transfer validator address is changed.
    event TransferValidatorUpdated(
        address indexed oldValidator,
        address indexed newValidator
    );

    /// @notice Emitted when a user initiates physical shipment of their asset.
    event ShipmentInitiated(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 fee
    );

    /// @notice Emitted when the payment token for redemption fees is updated.
    event PaymentTokenUpdated(
        address indexed oldToken,
        address indexed newToken
    );

    /// @notice Emitted when the platform treasury address is updated.
    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    /// @notice Emitted when the FeeController address is updated.
    event FeeControllerUpdated(
        address indexed oldController,
        address indexed newController
    );

    /// @notice Emitted when the AssetLendingPool address is updated.
    event LendingPoolUpdated(address indexed oldPool, address indexed newPool);

    // =========================================================================
    // Errors
    // =========================================================================

    error AssetNFT__InvalidStateTransition(
        uint256 tokenId,
        AssetState currentState,
        AssetState newState
    );

    error AssetNFT__TokenNotTransferable(
        uint256 tokenId,
        AssetState currentState
    );

    error AssetNFT__TokenNotBurnable(uint256 tokenId, AssetState currentState);

    error AssetNFT__ArrayLengthMismatch();

    error AssetNFT__ZeroAddress();

    error AssetNFT__BatchTooLarge(uint256 size, uint256 maxSize);

    error AssetNFT__TokenNotFound(uint256 tokenId);

    error AssetNFT__UserBlacklisted(address account);

    error AssetNFT__NotTokenOwner(uint256 tokenId, address caller);

    error AssetNFT__ShipmentConfigNotSet();

    // =========================================================================
    // Constructor & initializer
    // =========================================================================

    /// @notice Sets the immutable trusted forwarder and locks the implementation.
    /// @dev The trusted forwarder is stored as an immutable in the implementation bytecode.
    ///      To change it, deploy a new implementation via UUPS upgrade.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
        _disableInitializers();
    }

    /// @notice Initializes the proxy with token metadata, royalties, permission manager, and contract URI.
    /// @dev Must be called exactly once via the proxy. Uses both ERC721A and OZ initializer guards.
    /// @param permissionManager_ Address of the deployed PermissionManager proxy.
    /// @param name_ ERC-721 token name.
    /// @param symbol_ ERC-721 token symbol.
    /// @param contractURI_ Initial ERC-7572 collection-level metadata URI.
    /// @param royaltyReceiver_ Address to receive royalty payments.
    /// @param royaltyFeeNumerator_ Royalty fee in basis points (e.g. 250 = 2.5%). Denominator is 10_000.
    function initialize(
        address permissionManager_,
        string calldata name_,
        string calldata symbol_,
        string calldata contractURI_,
        address royaltyReceiver_,
        uint96 royaltyFeeNumerator_
    ) external initializerERC721A initializer {
        __ERC721A_init(name_, symbol_);
        __ERC721AQueryable_init();
        __PermissionConsumer_init(permissionManager_);
        __Pausable_init();
        __ERC2981_init();

        _getAssetNFTStorage().contractURIValue = contractURI_;

        if (royaltyReceiver_ != address(0)) {
            _setDefaultRoyalty(royaltyReceiver_, royaltyFeeNumerator_);
        }
    }

    // =========================================================================
    // ERC721A overrides
    // =========================================================================

    /// @dev Token IDs start at 1 for 1-based indexing UX.
    function _startTokenId() internal pure override returns (uint256) {
        return 1;
    }

    // =========================================================================
    // Minting
    // =========================================================================

    /// @notice Mints multiple asset tokens in a single transaction.
    /// @dev Limited to 50 tokens per batch. Token IDs are assigned sequentially. Emits BatchMetadataUpdate.
    /// @param recipients Array of recipient addresses, one per token.
    /// @param uris Array of metadata URIs, one per token.
    function batchMint(
        address[] calldata recipients,
        string[] calldata uris
    ) external onlyProtocolRole(Roles.MINTER_ROLE) nonReentrant whenNotPaused {
        uint256 len = recipients.length;
        if (len != uris.length) revert AssetNFT__ArrayLengthMismatch();
        if (len > 50) revert AssetNFT__BatchTooLarge(len, 50);

        AssetNFTStorage storage $ = _getAssetNFTStorage();
        uint256 startId = _nextTokenId();

        for (uint256 i; i < len; ) {
            uint256 tokenId = startId + i;
            _mint(recipients[i], 1);
            $.tokenURIs[tokenId] = uris[i];
            unchecked {
                ++i;
            }
        }

        if (len > 0) {
            emit BatchMetadataUpdate(startId, startId + len - 1);
        }
    }

    // =========================================================================
    // Burning
    // =========================================================================

    /// @notice Burns multiple asset tokens in a single transaction.
    /// @dev Only tokens in `Held` or `RemovedFromPlatform` state may be burned. Limited to 50 tokens per batch.
    /// @param tokenIds Array of token IDs to burn.
    function batchBurn(
        uint256[] calldata tokenIds
    ) external onlyProtocolRole(Roles.BURNER_ROLE) nonReentrant {
        uint256 len = tokenIds.length;
        if (len > 50) revert AssetNFT__BatchTooLarge(len, 50);

        AssetNFTStorage storage $ = _getAssetNFTStorage();
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            if (!_exists(tokenId)) revert AssetNFT__TokenNotFound(tokenId);
            AssetState state = $.assetStates[tokenId];
            if (
                state != AssetState.Held &&
                state != AssetState.RemovedFromPlatform
            ) {
                revert AssetNFT__TokenNotBurnable(tokenId, state);
            }
            emit MetadataUpdate(tokenId);
            _burn(tokenId);
            delete $.assetStates[tokenId];
            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // State machine
    // =========================================================================

    /// @notice Transitions multiple tokens to individual new lifecycle states in a single call.
    /// @dev Arrays must have equal length and at most 50 elements. Pass arrays of length 1 for single-token transitions.
    function batchSetAssetState(
        uint256[] calldata tokenIds,
        AssetState[] calldata newStates
    ) external onlyProtocolRole(Roles.STATE_MANAGER_ROLE) {
        uint256 len = tokenIds.length;
        if (len != newStates.length) revert AssetNFT__ArrayLengthMismatch();
        if (len > 50) revert AssetNFT__BatchTooLarge(len, 50);
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            if (!_exists(tokenId)) revert AssetNFT__TokenNotFound(tokenId);
            AssetState current = $.assetStates[tokenId];
            AssetState newState = newStates[i];
            if (!_isValidTransition(current, newState)) {
                revert AssetNFT__InvalidStateTransition(
                    tokenId,
                    current,
                    newState
                );
            }
            $.assetStates[tokenId] = newState;
            emit AssetStateChanged(tokenId, current, newState);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns the current lifecycle state of a token.
    function getAssetState(uint256 tokenId) external view returns (AssetState) {
        if (!_exists(tokenId)) revert AssetNFT__TokenNotFound(tokenId);
        return _getAssetNFTStorage().assetStates[tokenId];
    }

    function _isValidTransition(
        AssetState from,
        AssetState to
    ) internal pure returns (bool) {
        if (from == to) return false;
        uint8 mask = uint8(TRANSITIONS >> (uint8(from) * 8));
        return (mask & (1 << uint8(to))) != 0;
    }

    // =========================================================================
    // Metadata
    // =========================================================================

    /// @notice Updates the metadata URI for a specific token.
    function setTokenURI(
        uint256 tokenId,
        string calldata uri
    ) external onlyProtocolRole(Roles.URI_SETTER_ROLE) {
        if (!_exists(tokenId)) revert AssetNFT__TokenNotFound(tokenId);
        _getAssetNFTStorage().tokenURIs[tokenId] = uri;
        emit MetadataUpdate(tokenId);
    }

    /// @notice Sets the base URI prepended to all per-token URIs when no per-token URI is set.
    function setBaseURI(
        string calldata baseURI_
    ) external onlyProtocolRole(Roles.URI_SETTER_ROLE) {
        _getAssetNFTStorage().baseURIValue = baseURI_;
        emit BaseURIUpdated(baseURI_);
    }

    /// @notice ERC-7572 collection-level metadata URI.
    function contractURI() external view returns (string memory) {
        return _getAssetNFTStorage().contractURIValue;
    }

    /// @notice Updates the ERC-7572 collection-level metadata URI.
    function setContractURI(
        string calldata contractURI_
    ) external onlyProtocolRole(Roles.URI_SETTER_ROLE) {
        _getAssetNFTStorage().contractURIValue = contractURI_;
        emit ContractURIUpdated();
    }

    // =========================================================================
    // ERC-2981 royalty admin
    // =========================================================================

    /// @notice Sets the default royalty receiver and fee for all tokens.
    function setDefaultRoyalty(
        address receiver,
        uint96 feeNumerator
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    /// @notice Sets a per-token royalty override.
    function setTokenRoyalty(
        uint256 tokenId,
        address receiver,
        uint96 feeNumerator
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
    }

    /// @notice Deletes the default royalty configuration.
    function deleteDefaultRoyalty()
        external
        onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE)
    {
        _deleteDefaultRoyalty();
    }

    /// @notice Removes the per-token royalty override, falling back to the default.
    function resetTokenRoyalty(
        uint256 tokenId
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        _resetTokenRoyalty(tokenId);
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
    // Blacklist
    // =========================================================================

    /// @notice Updates the blacklist status of one or more addresses.
    /// @dev Arrays must have equal length and at most 50 elements.
    /// @param accounts Array of addresses to update.
    /// @param statuses Array of blacklist statuses (true = blacklisted, false = removed).
    function setBlacklisted(
        address[] calldata accounts,
        bool[] calldata statuses
    ) external onlyProtocolRole(Roles.BLACKLIST_ROLE) {
        uint256 len = accounts.length;
        if (len != statuses.length) revert AssetNFT__ArrayLengthMismatch();
        if (len > 50) revert AssetNFT__BatchTooLarge(len, 50);
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        for (uint256 i; i < len; ) {
            address account = accounts[i];
            if (account == address(0)) revert AssetNFT__ZeroAddress();
            $.isBlacklisted[account] = statuses[i];
            emit BlacklistUpdated(account, statuses[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Returns whether an address is blacklisted from transfers.
    function isBlacklisted(address account) external view returns (bool) {
        return _getAssetNFTStorage().isBlacklisted[account];
    }

    // =========================================================================
    // Transfer Validator
    // =========================================================================

    /// @notice Sets the external transfer validator contract.
    /// @dev Pass address(0) to disable validation.
    function setTransferValidator(
        address validator
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        address old = $.transferValidator;
        $.transferValidator = validator;
        emit TransferValidatorUpdated(old, validator);
    }

    /// @notice Returns the current transfer validator address.
    function getTransferValidator() external view returns (address) {
        return _getAssetNFTStorage().transferValidator;
    }

    // =========================================================================
    // Physical redemption / shipment
    // =========================================================================

    /// @notice Pay the redemption fee and transition the caller's asset into physical shipment.
    /// @dev Caller must own the token. Token must be in Held state (Loaned / Listed tokens are
    ///      blocked by the state check). Fee = appraisalValue * redemptionFeeBps / BPS, pulled
    ///      in paymentToken from the caller to the treasury. If appraisal value is 0 (not appraised),
    ///      fee is 0 and the asset ships free. Requires feeController and lendingPool to be set.
    /// @param tokenId AssetNFT token to ship.
    function initiateShipment(
        uint256 tokenId
    ) external nonReentrant whenNotPaused {
        if (!_exists(tokenId)) revert AssetNFT__TokenNotFound(tokenId);
        address caller = _msgSender();
        if (ownerOf(tokenId) != caller)
            revert AssetNFT__NotTokenOwner(tokenId, caller);

        AssetNFTStorage storage $ = _getAssetNFTStorage();

        // Validate current state is Held (transition check mirrors _isValidTransition)
        AssetState current = $.assetStates[tokenId];
        if (current != AssetState.Held) {
            revert AssetNFT__InvalidStateTransition(
                tokenId,
                current,
                AssetState.InShipment
            );
        }

        if ($.feeController == address(0) || $.lendingPool == address(0)) {
            revert AssetNFT__ShipmentConfigNotSet();
        }

        // Compute fee: base = appraisal value from lending pool; fee = 0 when appraisal is 0
        uint256 appraisalValue = IAssetLendingPool($.lendingPool)
            .getAppraisal(tokenId)
            .value;
        (uint256 fee, bool enabled) = IFeeController($.feeController)
            .getRedemptionFee(appraisalValue);

        if (enabled && fee > 0) {
            if (
                address($.paymentToken) == address(0) ||
                $.treasury == address(0)
            ) {
                revert AssetNFT__ShipmentConfigNotSet();
            }
            $.paymentToken.safeTransferFrom(caller, $.treasury, fee);
        }

        // Transition Held -> InShipment (internal write; no batchSetAssetState needed)
        $.assetStates[tokenId] = AssetState.InShipment;
        emit AssetStateChanged(tokenId, current, AssetState.InShipment);
        emit ShipmentInitiated(tokenId, caller, fee);
    }

    // =========================================================================
    // Shipment config setters (DEFAULT_ADMIN_ROLE)
    // =========================================================================

    /// @notice Set the ERC20 payment token used to collect redemption fees (e.g. USDC).
    function setPaymentToken(
        address token_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        address old = address($.paymentToken);
        $.paymentToken = IERC20(token_);
        emit PaymentTokenUpdated(old, token_);
    }

    /// @notice Set the platform treasury that receives the redemption fee.
    function setTreasury(
        address treasury_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert AssetNFT__ZeroAddress();
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        address old = $.treasury;
        $.treasury = treasury_;
        emit TreasuryUpdated(old, treasury_);
    }

    /// @notice Set the FeeController that supplies the redemption fee rate.
    function setFeeController(
        address feeController_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (feeController_ == address(0)) revert AssetNFT__ZeroAddress();
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        address old = $.feeController;
        $.feeController = feeController_;
        emit FeeControllerUpdated(old, feeController_);
    }

    /// @notice Returns the appraisal value for a token from the lending pool.
    ///         Returns 0 if the lending pool is not configured or the token has no appraisal.
    ///         Used by PackMachine to validate FMV bounds at deposit time.
    function getAppraisalValue(
        uint256 tokenId
    ) external view returns (uint256) {
        address pool = _getAssetNFTStorage().lendingPool;
        if (pool == address(0)) return 0;
        return IAssetLendingPool(pool).getAppraisal(tokenId).value;
    }

    /// @notice Set the AssetLendingPool used to look up appraisal values for the redemption fee.
    function setLendingPool(
        address lendingPool_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (lendingPool_ == address(0)) revert AssetNFT__ZeroAddress();
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        address old = $.lendingPool;
        $.lendingPool = lendingPool_;
        emit LendingPoolUpdated(old, lendingPool_);
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyProtocolRole(Roles.UPGRADER_ROLE) {}

    // =========================================================================
    // Required overrides
    // =========================================================================

    /// @dev Returns per-token URI if set, otherwise falls back to baseURI + tokenId string.
    function tokenURI(
        uint256 tokenId
    )
        public
        view
        override(ERC721AUpgradeable, IERC721AUpgradeable)
        returns (string memory)
    {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        string memory _tokenURI = $.tokenURIs[tokenId];
        string memory base = $.baseURIValue;
        if (bytes(base).length == 0) return _tokenURI;
        if (bytes(_tokenURI).length > 0) return string.concat(base, _tokenURI);
        return string.concat(base, _toString(tokenId));
    }

    /// @dev Blocks all operations when paused; blocks blacklisted addresses; blocks transfers
    ///      (not mints/burns) when asset state != Held; invokes external transfer validator if set.
    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 startTokenId_,
        uint256 quantity
    ) internal override {
        super._beforeTokenTransfers(from, to, startTokenId_, quantity);

        if (paused()) revert EnforcedPause();

        AssetNFTStorage storage $ = _getAssetNFTStorage();

        if (from != address(0) && $.isBlacklisted[from]) {
            revert AssetNFT__UserBlacklisted(from);
        }
        if (to != address(0) && $.isBlacklisted[to]) {
            revert AssetNFT__UserBlacklisted(to);
        }

        if (from != address(0) && to != address(0)) {
            for (uint256 i; i < quantity; ) {
                uint256 tokenId = startTokenId_ + i;
                AssetState state = $.assetStates[tokenId];
                if (state != AssetState.Held) {
                    revert AssetNFT__TokenNotTransferable(tokenId, state);
                }
                unchecked {
                    ++i;
                }
            }

            address validator = $.transferValidator;
            if (validator != address(0)) {
                address caller = _msgSender();
                for (uint256 i; i < quantity; ++i) {
                    ITransferValidator(validator).validateTransfer(
                        caller,
                        from,
                        to,
                        startTokenId_ + i
                    );
                }
            }
        }
    }

    /// @dev Bridges ERC721A's sender resolution to the ERC-2771-aware _msgSender().
    function _msgSenderERC721A() internal view override returns (address) {
        return _msgSender();
    }

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

    /// @dev Combines ERC721A and ERC2981 interface support.
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(ERC721AUpgradeable, IERC721AUpgradeable, ERC2981Upgradeable)
        returns (bool)
    {
        return
            ERC721AUpgradeable.supportsInterface(interfaceId) ||
            ERC2981Upgradeable.supportsInterface(interfaceId);
    }
}
