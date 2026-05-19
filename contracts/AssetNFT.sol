// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC721AQueryableUpgradeable} from "erc721a-upgradeable/contracts/extensions/ERC721AQueryableUpgradeable.sol";
import {
    ERC721AUpgradeable,
    IERC721AUpgradeable
} from "erc721a-upgradeable/contracts/ERC721AUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ERC2981Upgradeable} from "@openzeppelin/contracts-upgradeable/token/common/ERC2981Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AssetNFT
/// @author NettyWorth
/// @notice ERC-721A token representing tokenized physical assets with lifecycle state management and role-based access control.
/// @dev UUPS upgradeable proxy pattern (EIP-1822). Storage uses ERC-7201 namespaced slots to avoid collisions across
///      upgrades. Asset lifecycle transitions are validated via a packed 48-bit bitmask (one byte per state).
///      ERC-2771 meta-transaction support: trusted forwarder is immutable per implementation — change by upgrading.
/// @custom:security-contact security@nettyworth.io
contract AssetNFT is
    ERC721AQueryableUpgradeable,
    ERC2771ContextUpgradeable,
    ERC2981Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuard
{
    // =========================================================================
    // Roles
    // =========================================================================

    /// @notice Grants permission to mint new asset tokens.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Grants permission to burn asset tokens.
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @notice Grants permission to transition asset lifecycle states.
    bytes32 public constant STATE_MANAGER_ROLE = keccak256(
        "STATE_MANAGER_ROLE"
    );

    /// @notice Grants permission to update token and contract-level metadata URIs.
    bytes32 public constant URI_SETTER_ROLE = keccak256("URI_SETTER_ROLE");

    /// @notice Grants permission to pause and unpause token transfers.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice Grants permission to authorize contract upgrades via UUPS.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

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
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.AssetNFT")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASSET_NFT_STORAGE_SLOT =
        0x675aac697fe56d36fbae4d3e62e7ee038891694765a00c8d87dcb6940159f900;

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

    /// @notice Initializes the proxy with token metadata, royalties, access control roles, and contract URI.
    /// @dev Must be called exactly once via the proxy. Uses both ERC721A and OZ initializer guards.
    /// @param defaultAdmin Address that receives DEFAULT_ADMIN_ROLE and all operational roles.
    /// @param name_ ERC-721 token name.
    /// @param symbol_ ERC-721 token symbol.
    /// @param contractURI_ Initial ERC-7572 collection-level metadata URI.
    /// @param royaltyReceiver_ Address to receive royalty payments.
    /// @param royaltyFeeNumerator_ Royalty fee in basis points (e.g. 250 = 2.5%). Denominator is 10_000.
    function initialize(
        address defaultAdmin,
        string calldata name_,
        string calldata symbol_,
        string calldata contractURI_,
        address royaltyReceiver_,
        uint96 royaltyFeeNumerator_
    ) external initializerERC721A initializer {
        if (defaultAdmin == address(0)) revert AssetNFT__ZeroAddress();

        __ERC721A_init(name_, symbol_);
        __ERC721AQueryable_init();
        __AccessControl_init();
        __Pausable_init();
        __ERC2981_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, defaultAdmin);
        _grantRole(BURNER_ROLE, defaultAdmin);
        _grantRole(STATE_MANAGER_ROLE, defaultAdmin);
        _grantRole(URI_SETTER_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, defaultAdmin);

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
    ) external onlyRole(MINTER_ROLE) nonReentrant whenNotPaused {
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
    ) external onlyRole(BURNER_ROLE) nonReentrant {
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
    ) external onlyRole(STATE_MANAGER_ROLE) {
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
    ) external onlyRole(URI_SETTER_ROLE) {
        if (!_exists(tokenId)) revert AssetNFT__TokenNotFound(tokenId);
        _getAssetNFTStorage().tokenURIs[tokenId] = uri;
        emit MetadataUpdate(tokenId);
    }

    /// @notice Sets the base URI prepended to all per-token URIs when no per-token URI is set.
    function setBaseURI(
        string calldata baseURI_
    ) external onlyRole(URI_SETTER_ROLE) {
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
    ) external onlyRole(URI_SETTER_ROLE) {
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
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    /// @notice Sets a per-token royalty override.
    function setTokenRoyalty(
        uint256 tokenId,
        address receiver,
        uint96 feeNumerator
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setTokenRoyalty(tokenId, receiver, feeNumerator);
    }

    /// @notice Deletes the default royalty configuration.
    function deleteDefaultRoyalty() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _deleteDefaultRoyalty();
    }

    /// @notice Removes the per-token royalty override, falling back to the default.
    function resetTokenRoyalty(
        uint256 tokenId
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _resetTokenRoyalty(tokenId);
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

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

    /// @dev Blocks all operations when paused; blocks transfers (not mints/burns) when asset state != Held.
    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 startTokenId_,
        uint256 quantity
    ) internal override {
        super._beforeTokenTransfers(from, to, startTokenId_, quantity);

        if (paused()) revert EnforcedPause();

        if (from != address(0) && to != address(0)) {
            AssetNFTStorage storage $ = _getAssetNFTStorage();
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
        }
    }

    /// @dev Bridges ERC721A's sender resolution to the ERC-2771-aware _msgSender().
    function _msgSenderERC721A() internal view override returns (address) {
        return _msgSender();
    }

    function _msgSender()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
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

    /// @dev Combines ERC721A, ERC2981, and AccessControl interface support.
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(
            ERC721AUpgradeable,
            IERC721AUpgradeable,
            ERC2981Upgradeable,
            AccessControlUpgradeable
        )
        returns (bool)
    {
        return
            ERC721AUpgradeable.supportsInterface(interfaceId) ||
            ERC2981Upgradeable.supportsInterface(interfaceId) ||
            AccessControlUpgradeable.supportsInterface(interfaceId);
    }
}
