// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {ERC721URIStorageUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {ERC721PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AssetNFT
/// @author NettyWorth
/// @notice ERC-721 token representing tokenized physical assets with lifecycle state management and role-based access control.
/// @dev UUPS upgradeable proxy pattern (EIP-1822). Storage uses ERC-7201 namespaced slots to avoid collisions across
///      upgrades. Asset lifecycle transitions are validated via a packed 48-bit bitmask (one byte per state).
/// @custom:security-contact security@nettyworth.io
contract AssetNFT is
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721URIStorageUpgradeable,
    ERC721PausableUpgradeable,
    AccessControlUpgradeable,
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
    /// @dev Fields:
    ///   - `assetStates`: maps tokenId to its current AssetState
    ///   - `contractURIValue`: ERC-7572 collection-level metadata URI
    ///   - `baseURIValue`: optional base URI prepended to per-token URIs
    /// @custom:storage-location erc7201:nettyworth.storage.AssetNFT
    struct AssetNFTStorage {
        mapping(uint256 => AssetState) assetStates;
        string contractURIValue;
        string baseURIValue;
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
    // Events
    // =========================================================================

    /// @notice Emitted when a token's lifecycle state is updated.
    /// @param tokenId The token whose state changed.
    /// @param previousState The state before the transition.
    /// @param newState The state after the transition.
    event AssetStateChanged(
        uint256 indexed tokenId,
        AssetState indexed previousState,
        AssetState indexed newState
    );

    /// @notice Emitted when the collection-level contract URI is updated.
    event ContractURIUpdated();

    /// @notice Emitted when the base URI for token metadata is updated.
    /// @param uri The new base URI value.
    event BaseURIUpdated(string uri);

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when a requested state transition is not permitted by the state machine.
    /// @param tokenId The token for which the transition was attempted.
    /// @param currentState The token's current state.
    /// @param newState The disallowed target state.
    error AssetNFT__InvalidStateTransition(
        uint256 tokenId,
        AssetState currentState,
        AssetState newState
    );

    /// @notice Thrown when a transfer is attempted on a token that is not in the `Held` state.
    /// @param tokenId The token that cannot be transferred.
    /// @param currentState The token's current state blocking the transfer.
    error AssetNFT__TokenNotTransferable(
        uint256 tokenId,
        AssetState currentState
    );

    /// @notice Thrown when burn is attempted on a token that is not in `Held` or `RemovedFromPlatform` state.
    /// @param tokenId The token that cannot be burned.
    /// @param currentState The token's current state blocking the burn.
    error AssetNFT__TokenNotBurnable(uint256 tokenId, AssetState currentState);

    /// @notice Thrown when calldata arrays supplied to a batch function have different lengths.
    error AssetNFT__ArrayLengthMismatch();

    /// @notice Thrown when a zero address is provided where a non-zero address is required.
    error AssetNFT__ZeroAddress();

    /// @notice Thrown when a batch operation exceeds the maximum allowed size.
    /// @param size The number of elements provided.
    /// @param maxSize The maximum number of elements allowed.
    error AssetNFT__BatchTooLarge(uint256 size, uint256 maxSize);

    // =========================================================================
    // Constructor & initializer
    // =========================================================================

    /// @notice Locks the implementation contract so it cannot be initialized directly.
    /// @dev Calls `_disableInitializers()` to prevent anyone from calling `initialize` on
    ///      the bare implementation address (only the proxy should be initialized).
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy with token metadata, access control roles, and contract URI.
    /// @dev Grants all operational roles to `defaultAdmin`. Must be called exactly once via the proxy.
    /// @param defaultAdmin Address that receives `DEFAULT_ADMIN_ROLE` and all operational roles.
    /// @param name_ ERC-721 token name.
    /// @param symbol_ ERC-721 token symbol.
    /// @param contractURI_ Initial ERC-7572 collection-level metadata URI.
    function initialize(
        address defaultAdmin,
        string calldata name_,
        string calldata symbol_,
        string calldata contractURI_
    ) external initializer {
        if (defaultAdmin == address(0)) revert AssetNFT__ZeroAddress();

        __ERC721_init(name_, symbol_);
        __ERC721Enumerable_init();
        __ERC721URIStorage_init();
        __ERC721Pausable_init();
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, defaultAdmin);
        _grantRole(BURNER_ROLE, defaultAdmin);
        _grantRole(STATE_MANAGER_ROLE, defaultAdmin);
        _grantRole(URI_SETTER_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, defaultAdmin);

        _getAssetNFTStorage().contractURIValue = contractURI_;
    }

    // =========================================================================
    // Minting
    // =========================================================================

    /// @notice Mints a single asset token and assigns its metadata URI.
    /// @param to Recipient address.
    /// @param tokenId Token identifier to mint.
    /// @param uri Metadata URI for the token.
    function mint(
        address to,
        uint256 tokenId,
        string calldata uri
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    /// @notice Mints multiple asset tokens in a single transaction.
    /// @dev Limited to 50 tokens per batch to bound gas usage. Emits `BatchMetadataUpdate` after minting.
    /// @param recipients Array of recipient addresses, one per token.
    /// @param tokenIds Array of token identifiers to mint.
    /// @param uris Array of metadata URIs, one per token.
    function batchMint(
        address[] calldata recipients,
        uint256[] calldata tokenIds,
        string[] calldata uris
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        uint256 len = recipients.length;
        if (len != tokenIds.length || len != uris.length)
            revert AssetNFT__ArrayLengthMismatch();
        if (len > 50) revert AssetNFT__BatchTooLarge(len, 50);

        for (uint256 i; i < len; ) {
            _safeMint(recipients[i], tokenIds[i]);
            _setTokenURI(tokenIds[i], uris[i]);
            unchecked {
                ++i;
            }
        }

        if (len > 0) {
            emit BatchMetadataUpdate(tokenIds[0], tokenIds[len - 1]);
        }
    }

    // =========================================================================
    // Burning
    // =========================================================================

    /// @notice Burns an asset token, permanently removing it from supply.
    /// @dev Only tokens in `Held` or `RemovedFromPlatform` state may be burned. Deletes the stored state entry.
    /// @param tokenId Token to burn.
    function burn(uint256 tokenId) external onlyRole(BURNER_ROLE) nonReentrant {
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        AssetState state = $.assetStates[tokenId];
        if (
            state != AssetState.Held && state != AssetState.RemovedFromPlatform
        ) {
            revert AssetNFT__TokenNotBurnable(tokenId, state);
        }
        emit MetadataUpdate(tokenId);
        _burn(tokenId);
        delete $.assetStates[tokenId];
    }

    // =========================================================================
    // State machine
    // =========================================================================

    /// @notice Transitions a single token to a new lifecycle state.
    /// @param tokenId Token whose state is being updated.
    /// @param newState Target state; must be reachable from the current state per the transition rules.
    function setAssetState(
        uint256 tokenId,
        AssetState newState
    ) external onlyRole(STATE_MANAGER_ROLE) {
        _requireOwned(tokenId);
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        AssetState current = $.assetStates[tokenId];
        if (!_isValidTransition(current, newState)) {
            revert AssetNFT__InvalidStateTransition(tokenId, current, newState);
        }
        $.assetStates[tokenId] = newState;
        emit AssetStateChanged(tokenId, current, newState);
    }

    /// @notice Transitions multiple tokens to the same new lifecycle state in a single call.
    /// @param tokenIds Array of token identifiers to update.
    /// @param newState Target state applied to every token in the array.
    function batchSetAssetState(
        uint256[] calldata tokenIds,
        AssetState newState
    ) external onlyRole(STATE_MANAGER_ROLE) {
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        for (uint256 i; i < tokenIds.length; ) {
            uint256 tokenId = tokenIds[i];
            _requireOwned(tokenId);
            AssetState current = $.assetStates[tokenId];
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
    /// @param tokenId Token to query; must exist.
    /// @return The token's current `AssetState`.
    function getAssetState(uint256 tokenId) external view returns (AssetState) {
        _requireOwned(tokenId);
        return _getAssetNFTStorage().assetStates[tokenId];
    }

    /// @dev Validates a state transition using the packed `TRANSITIONS` bitmask.
    ///      Extracts the byte for `from` state, then checks whether bit `to` is set.
    ///      Self-transitions (from == to) are always rejected.
    /// @param from Current state of the token.
    /// @param to Desired target state.
    /// @return True if the transition is permitted, false otherwise.
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
    /// @param tokenId Token to update; must exist.
    /// @param uri New metadata URI.
    function setTokenURI(
        uint256 tokenId,
        string calldata uri
    ) external onlyRole(URI_SETTER_ROLE) {
        _requireOwned(tokenId);
        _setTokenURI(tokenId, uri);
    }

    /// @notice Sets the base URI prepended to all per-token URIs.
    /// @param baseURI_ New base URI string.
    function setBaseURI(
        string calldata baseURI_
    ) external onlyRole(URI_SETTER_ROLE) {
        _getAssetNFTStorage().baseURIValue = baseURI_;
        emit BaseURIUpdated(baseURI_);
    }

    /// @notice ERC-7572 collection-level metadata URI.
    /// @return The current contract URI string.
    function contractURI() external view returns (string memory) {
        return _getAssetNFTStorage().contractURIValue;
    }

    /// @notice Updates the ERC-7572 collection-level metadata URI.
    /// @param contractURI_ New contract URI string.
    function setContractURI(
        string calldata contractURI_
    ) external onlyRole(URI_SETTER_ROLE) {
        _getAssetNFTStorage().contractURIValue = contractURI_;
        emit ContractURIUpdated();
    }

    // =========================================================================
    // Pause
    // =========================================================================

    /// @notice Pauses all token transfers.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Unpauses token transfers.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADER_ROLE) {}

    // =========================================================================
    // Required overrides
    // =========================================================================

    /// @inheritdoc ERC721Upgradeable
    function _baseURI() internal view override returns (string memory) {
        return _getAssetNFTStorage().baseURIValue;
    }

    /// @inheritdoc ERC721Upgradeable
    /// @dev Blocks transfers (non-mint, non-burn) when the token is not in the `Held` state.
    function _update(
        address to,
        uint256 tokenId,
        address auth
    )
        internal
        override(
            ERC721Upgradeable,
            ERC721EnumerableUpgradeable,
            ERC721PausableUpgradeable
        )
        returns (address)
    {
        address from = _ownerOf(tokenId);

        // Block transfers (not mints or burns) when asset is not in Held state.
        if (from != address(0) && to != address(0)) {
            AssetState state = _getAssetNFTStorage().assetStates[tokenId];
            if (state != AssetState.Held) {
                revert AssetNFT__TokenNotTransferable(tokenId, state);
            }
        }

        return super._update(to, tokenId, auth);
    }

    /// @inheritdoc ERC721Upgradeable
    function _increaseBalance(
        address account,
        uint128 value
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) {
        super._increaseBalance(account, value);
    }

    /// @inheritdoc ERC721Upgradeable
    function tokenURI(
        uint256 tokenId
    )
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    /// @inheritdoc ERC721Upgradeable
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        override(
            ERC721Upgradeable,
            ERC721EnumerableUpgradeable,
            ERC721URIStorageUpgradeable,
            AccessControlUpgradeable
        )
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
