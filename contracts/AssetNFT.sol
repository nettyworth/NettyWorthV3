// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant STATE_MANAGER_ROLE = keccak256("STATE_MANAGER_ROLE");
    bytes32 public constant URI_SETTER_ROLE = keccak256("URI_SETTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // =========================================================================
    // State machine
    // =========================================================================

    enum AssetState {
        Held,               // 0 — in Brinks custody, available for platform actions
        Listed,             // 1 — listed on marketplace
        Loaned,             // 2 — locked as loan collateral
        Traded,             // 3 — locked in an active trade/swap
        InShipment,         // 4 — physically in transit
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

    /// @custom:storage-location erc7201:nettyworth.storage.AssetNFT
    struct AssetNFTStorage {
        mapping(uint256 => AssetState) assetStates;
        string contractURIValue;
        string baseURIValue;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.AssetNFT")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASSET_NFT_STORAGE_SLOT =
        0x675aac697fe56d36fbae4d3e62e7ee038891694765a00c8d87dcb6940159f900;

    function _getAssetNFTStorage() private pure returns (AssetNFTStorage storage $) {
        assembly {
            $.slot := ASSET_NFT_STORAGE_SLOT
        }
    }

    // =========================================================================
    // Events
    // =========================================================================

    event AssetStateChanged(
        uint256 indexed tokenId,
        AssetState indexed previousState,
        AssetState indexed newState
    );
    event ContractURIUpdated();
    event BaseURIUpdated(string uri);

    // =========================================================================
    // Errors
    // =========================================================================

    error AssetNFT__InvalidStateTransition(uint256 tokenId, AssetState currentState, AssetState newState);
    error AssetNFT__TokenNotTransferable(uint256 tokenId, AssetState currentState);
    error AssetNFT__TokenNotBurnable(uint256 tokenId, AssetState currentState);
    error AssetNFT__ArrayLengthMismatch();
    error AssetNFT__ZeroAddress();
    error AssetNFT__BatchTooLarge(uint256 size, uint256 maxSize);

    // =========================================================================
    // Constructor & initializer
    // =========================================================================

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address defaultAdmin,
        string memory name_,
        string memory symbol_,
        string memory contractURI_
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

    function mint(address to, uint256 tokenId, string calldata uri)
        external
        onlyRole(MINTER_ROLE)
        nonReentrant
    {
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function batchMint(
        address[] calldata recipients,
        uint256[] calldata tokenIds,
        string[] calldata uris
    ) external onlyRole(MINTER_ROLE) nonReentrant {
        uint256 len = recipients.length;
        if (len != tokenIds.length || len != uris.length) revert AssetNFT__ArrayLengthMismatch();
        if (len > 50) revert AssetNFT__BatchTooLarge(len, 50);

        for (uint256 i; i < len; ) {
            _safeMint(recipients[i], tokenIds[i]);
            _setTokenURI(tokenIds[i], uris[i]);
            unchecked { ++i; }
        }

        if (len > 0) {
            emit BatchMetadataUpdate(tokenIds[0], tokenIds[len - 1]);
        }
    }

    // =========================================================================
    // Burning
    // =========================================================================

    function burn(uint256 tokenId) external onlyRole(BURNER_ROLE) nonReentrant {
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        AssetState state = $.assetStates[tokenId];
        if (state != AssetState.Held && state != AssetState.RemovedFromPlatform) {
            revert AssetNFT__TokenNotBurnable(tokenId, state);
        }
        emit MetadataUpdate(tokenId);
        _burn(tokenId);
        delete $.assetStates[tokenId];
    }

    // =========================================================================
    // State machine
    // =========================================================================

    function setAssetState(uint256 tokenId, AssetState newState)
        external
        onlyRole(STATE_MANAGER_ROLE)
    {
        _requireOwned(tokenId);
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        AssetState current = $.assetStates[tokenId];
        if (!_isValidTransition(current, newState)) {
            revert AssetNFT__InvalidStateTransition(tokenId, current, newState);
        }
        $.assetStates[tokenId] = newState;
        emit AssetStateChanged(tokenId, current, newState);
    }

    function batchSetAssetState(uint256[] calldata tokenIds, AssetState newState)
        external
        onlyRole(STATE_MANAGER_ROLE)
    {
        AssetNFTStorage storage $ = _getAssetNFTStorage();
        for (uint256 i; i < tokenIds.length; ) {
            uint256 tokenId = tokenIds[i];
            _requireOwned(tokenId);
            AssetState current = $.assetStates[tokenId];
            if (!_isValidTransition(current, newState)) {
                revert AssetNFT__InvalidStateTransition(tokenId, current, newState);
            }
            $.assetStates[tokenId] = newState;
            emit AssetStateChanged(tokenId, current, newState);
            unchecked { ++i; }
        }
    }

    function getAssetState(uint256 tokenId) external view returns (AssetState) {
        _requireOwned(tokenId);
        return _getAssetNFTStorage().assetStates[tokenId];
    }

    function _isValidTransition(AssetState from, AssetState to) internal pure returns (bool) {
        if (from == to) return false;
        uint8 mask = uint8(TRANSITIONS >> (uint8(from) * 8));
        return (mask & (1 << uint8(to))) != 0;
    }

    // =========================================================================
    // Metadata
    // =========================================================================

    function setTokenURI(uint256 tokenId, string calldata uri)
        external
        onlyRole(URI_SETTER_ROLE)
    {
        _requireOwned(tokenId);
        _setTokenURI(tokenId, uri);
    }

    function setBaseURI(string calldata baseURI_) external onlyRole(URI_SETTER_ROLE) {
        _getAssetNFTStorage().baseURIValue = baseURI_;
        emit BaseURIUpdated(baseURI_);
    }

    /// @notice ERC-7572 collection-level metadata URI.
    function contractURI() external view returns (string memory) {
        return _getAssetNFTStorage().contractURIValue;
    }

    function setContractURI(string calldata contractURI_) external onlyRole(URI_SETTER_ROLE) {
        _getAssetNFTStorage().contractURIValue = contractURI_;
        emit ContractURIUpdated();
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

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // =========================================================================
    // Required overrides
    // =========================================================================

    function _baseURI() internal view override returns (string memory) {
        return _getAssetNFTStorage().baseURIValue;
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable, ERC721PausableUpgradeable)
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

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable, ERC721URIStorageUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
