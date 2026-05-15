// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AssetNFT} from "../AssetNFT.sol";

contract AssetNFTTest is Test {
    AssetNFT internal nft;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal burner = makeAddr("burner");
    address internal stateManager = makeAddr("stateManager");
    address internal uriSetter = makeAddr("uriSetter");
    address internal pauser = makeAddr("pauser");
    address internal upgrader = makeAddr("upgrader");
    address internal user = makeAddr("user");
    address internal user2 = makeAddr("user2");

    string internal constant NAME = "NettyWorth Assets";
    string internal constant SYMBOL = "NWA";
    string internal constant CONTRACT_URI = "ipfs://contract-metadata";
    string internal constant TOKEN_URI = "ipfs://token/1";

    function setUp() public {
        AssetNFT impl = new AssetNFT();
        bytes memory data = abi.encodeCall(
            AssetNFT.initialize,
            (admin, NAME, SYMBOL, CONTRACT_URI)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        nft = AssetNFT(address(proxy));

        // Grant individual roles to dedicated test accounts
        vm.startPrank(admin);
        nft.grantRole(nft.MINTER_ROLE(), minter);
        nft.grantRole(nft.BURNER_ROLE(), burner);
        nft.grantRole(nft.STATE_MANAGER_ROLE(), stateManager);
        nft.grantRole(nft.URI_SETTER_ROLE(), uriSetter);
        nft.grantRole(nft.PAUSER_ROLE(), pauser);
        nft.grantRole(nft.UPGRADER_ROLE(), upgrader);
        vm.stopPrank();
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    function test_Initialize_Name() public view {
        assertEq(nft.name(), NAME);
    }

    function test_Initialize_Symbol() public view {
        assertEq(nft.symbol(), SYMBOL);
    }

    function test_Initialize_ContractURI() public view {
        assertEq(nft.contractURI(), CONTRACT_URI);
    }

    function test_Initialize_AdminHasAllRoles() public view {
        assertTrue(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(nft.hasRole(nft.MINTER_ROLE(), admin));
        assertTrue(nft.hasRole(nft.BURNER_ROLE(), admin));
        assertTrue(nft.hasRole(nft.STATE_MANAGER_ROLE(), admin));
        assertTrue(nft.hasRole(nft.URI_SETTER_ROLE(), admin));
        assertTrue(nft.hasRole(nft.PAUSER_ROLE(), admin));
        assertTrue(nft.hasRole(nft.UPGRADER_ROLE(), admin));
    }

    function test_Initialize_RevertsOnZeroAdmin() public {
        AssetNFT impl = new AssetNFT();
        bytes memory data = abi.encodeCall(
            AssetNFT.initialize,
            (address(0), NAME, SYMBOL, CONTRACT_URI)
        );
        vm.expectRevert(AssetNFT.AssetNFT__ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_CannotInitializeTwice() public {
        vm.expectRevert();
        nft.initialize(admin, NAME, SYMBOL, CONTRACT_URI);
    }

    // =========================================================================
    // Minting
    // =========================================================================

    function test_Mint_Success() public {
        vm.prank(minter);
        nft.mint(user, 1, TOKEN_URI);

        assertEq(nft.ownerOf(1), user);
        assertEq(nft.tokenURI(1), TOKEN_URI);
        assertEq(nft.totalSupply(), 1);
    }

    function test_Mint_StateIsHeld() public {
        vm.prank(minter);
        nft.mint(user, 1, TOKEN_URI);

        assertEq(uint8(nft.getAssetState(1)), uint8(AssetNFT.AssetState.Held));
    }

    function test_Mint_RevertsWhenUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        nft.mint(user, 1, TOKEN_URI);
    }

    function test_BatchMint_Success() public {
        address[] memory recipients = new address[](3);
        uint256[] memory ids = new uint256[](3);
        string[] memory uris = new string[](3);
        for (uint256 i; i < 3; i++) {
            recipients[i] = user;
            ids[i] = i + 1;
            uris[i] = TOKEN_URI;
        }

        vm.prank(minter);
        nft.batchMint(recipients, ids, uris);

        assertEq(nft.totalSupply(), 3);
        assertEq(nft.ownerOf(1), user);
        assertEq(nft.ownerOf(2), user);
        assertEq(nft.ownerOf(3), user);
    }

    function test_BatchMint_EmitsBatchMetadataUpdate() public {
        address[] memory recipients = new address[](2);
        uint256[] memory ids = new uint256[](2);
        string[] memory uris = new string[](2);
        recipients[0] = user;
        recipients[1] = user;
        ids[0] = 10;
        ids[1] = 20;
        uris[0] = TOKEN_URI;
        uris[1] = TOKEN_URI;

        vm.expectEmit(false, false, false, true, address(nft));
        emit BatchMetadataUpdate(10, 20);

        vm.prank(minter);
        nft.batchMint(recipients, ids, uris);
    }

    function test_BatchMint_RevertsWhenTooLarge() public {
        uint256 size = 51;
        address[] memory recipients = new address[](size);
        uint256[] memory ids = new uint256[](size);
        string[] memory uris = new string[](size);
        for (uint256 i; i < size; i++) {
            recipients[i] = user;
            ids[i] = i + 1;
            uris[i] = TOKEN_URI;
        }

        vm.prank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__BatchTooLarge.selector,
                size,
                50
            )
        );
        nft.batchMint(recipients, ids, uris);
    }

    function test_BatchMint_RevertsOnLengthMismatch() public {
        address[] memory recipients = new address[](2);
        uint256[] memory ids = new uint256[](1);
        string[] memory uris = new string[](2);

        vm.prank(minter);
        vm.expectRevert(AssetNFT.AssetNFT__ArrayLengthMismatch.selector);
        nft.batchMint(recipients, ids, uris);
    }

    // =========================================================================
    // Burning
    // =========================================================================

    function _mintToken(uint256 tokenId) internal {
        vm.prank(minter);
        nft.mint(user, tokenId, TOKEN_URI);
    }

    function test_Burn_FromHeld() public {
        _mintToken(1);

        vm.prank(burner);
        nft.burn(1);

        vm.expectRevert();
        nft.ownerOf(1);
    }

    function test_Burn_FromRemovedFromPlatform() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.RemovedFromPlatform);

        vm.prank(burner);
        nft.burn(1);

        vm.expectRevert();
        nft.ownerOf(1);
    }

    function test_Burn_EmitsMetadataUpdate() public {
        _mintToken(1);

        vm.expectEmit(false, false, false, true, address(nft));
        emit MetadataUpdate(1);

        vm.prank(burner);
        nft.burn(1);
    }

    function test_Burn_RevertsWhenUnauthorized() public {
        _mintToken(1);
        vm.prank(user);
        vm.expectRevert();
        nft.burn(1);
    }

    function test_Burn_RevertsWhenListed() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Listed);

        vm.prank(burner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotBurnable.selector,
                1,
                AssetNFT.AssetState.Listed
            )
        );
        nft.burn(1);
    }

    function test_Burn_RevertsWhenLoaned() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Loaned);

        vm.prank(burner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotBurnable.selector,
                1,
                AssetNFT.AssetState.Loaned
            )
        );
        nft.burn(1);
    }

    // =========================================================================
    // State machine
    // =========================================================================

    function test_SetAssetState_HeldToListed() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Listed);
        assertEq(
            uint8(nft.getAssetState(1)),
            uint8(AssetNFT.AssetState.Listed)
        );
    }

    function test_SetAssetState_HeldToLoaned() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Loaned);
        assertEq(
            uint8(nft.getAssetState(1)),
            uint8(AssetNFT.AssetState.Loaned)
        );
    }

    function test_SetAssetState_HeldToTraded() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Traded);
        assertEq(
            uint8(nft.getAssetState(1)),
            uint8(AssetNFT.AssetState.Traded)
        );
    }

    function test_SetAssetState_HeldToInShipment() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.InShipment);
        assertEq(
            uint8(nft.getAssetState(1)),
            uint8(AssetNFT.AssetState.InShipment)
        );
    }

    function test_SetAssetState_HeldToRemoved() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.RemovedFromPlatform);
        assertEq(
            uint8(nft.getAssetState(1)),
            uint8(AssetNFT.AssetState.RemovedFromPlatform)
        );
    }

    function test_SetAssetState_ListedToHeld() public {
        _mintToken(1);
        vm.startPrank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Listed);
        nft.setAssetState(1, AssetNFT.AssetState.Held);
        vm.stopPrank();
        assertEq(uint8(nft.getAssetState(1)), uint8(AssetNFT.AssetState.Held));
    }

    function test_SetAssetState_LoanedToHeld() public {
        _mintToken(1);
        vm.startPrank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Loaned);
        nft.setAssetState(1, AssetNFT.AssetState.Held);
        vm.stopPrank();
        assertEq(uint8(nft.getAssetState(1)), uint8(AssetNFT.AssetState.Held));
    }

    function test_SetAssetState_InShipmentToRemoved() public {
        _mintToken(1);
        vm.startPrank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.InShipment);
        nft.setAssetState(1, AssetNFT.AssetState.RemovedFromPlatform);
        vm.stopPrank();
        assertEq(
            uint8(nft.getAssetState(1)),
            uint8(AssetNFT.AssetState.RemovedFromPlatform)
        );
    }

    function test_SetAssetState_EmitsEvent() public {
        _mintToken(1);
        vm.expectEmit(true, true, true, false, address(nft));
        emit AssetStateChanged(
            1,
            AssetNFT.AssetState.Held,
            AssetNFT.AssetState.Listed
        );
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Listed);
    }

    function test_SetAssetState_RevertsInvalidTransition_ListedToLoaned()
        public
    {
        _mintToken(1);
        vm.startPrank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Listed);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__InvalidStateTransition.selector,
                1,
                AssetNFT.AssetState.Listed,
                AssetNFT.AssetState.Loaned
            )
        );
        nft.setAssetState(1, AssetNFT.AssetState.Loaned);
        vm.stopPrank();
    }

    function test_SetAssetState_RevertsFromTerminalState() public {
        _mintToken(1);
        vm.startPrank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.RemovedFromPlatform);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__InvalidStateTransition.selector,
                1,
                AssetNFT.AssetState.RemovedFromPlatform,
                AssetNFT.AssetState.Held
            )
        );
        nft.setAssetState(1, AssetNFT.AssetState.Held);
        vm.stopPrank();
    }

    function test_SetAssetState_RevertsWhenUnauthorized() public {
        _mintToken(1);
        vm.prank(user);
        vm.expectRevert();
        nft.setAssetState(1, AssetNFT.AssetState.Listed);
    }

    function test_BatchSetAssetState_Success() public {
        vm.startPrank(minter);
        nft.mint(user, 1, TOKEN_URI);
        nft.mint(user, 2, TOKEN_URI);
        nft.mint(user, 3, TOKEN_URI);
        vm.stopPrank();

        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;

        vm.prank(stateManager);
        nft.batchSetAssetState(ids, AssetNFT.AssetState.Listed);

        assertEq(
            uint8(nft.getAssetState(1)),
            uint8(AssetNFT.AssetState.Listed)
        );
        assertEq(
            uint8(nft.getAssetState(2)),
            uint8(AssetNFT.AssetState.Listed)
        );
        assertEq(
            uint8(nft.getAssetState(3)),
            uint8(AssetNFT.AssetState.Listed)
        );
    }

    // Fuzz: exhaustively validate transition matrix (30 cross-state combos + 6 same-state)
    function testFuzz_StateTransitions(uint8 rawFrom, uint8 rawTo) public {
        uint8 numStates = 6;
        vm.assume(rawFrom < numStates && rawTo < numStates);
        AssetNFT.AssetState from = AssetNFT.AssetState(rawFrom);
        AssetNFT.AssetState to = AssetNFT.AssetState(rawTo);

        // Expected validity per transition matrix
        bool expected = _expectedValid(rawFrom, rawTo);

        _mintToken(1);

        // Advance token to the 'from' state via a direct path if it isn't Held
        if (from != AssetNFT.AssetState.Held) {
            vm.prank(stateManager);
            // All non-Held states are reachable from Held directly
            if (from == AssetNFT.AssetState.RemovedFromPlatform) {
                nft.setAssetState(1, AssetNFT.AssetState.RemovedFromPlatform);
            } else {
                nft.setAssetState(1, from);
            }
        }

        if (expected) {
            vm.prank(stateManager);
            nft.setAssetState(1, to);
            assertEq(uint8(nft.getAssetState(1)), uint8(to));
        } else {
            vm.prank(stateManager);
            vm.expectRevert();
            nft.setAssetState(1, to);
        }
    }

    function _expectedValid(uint8 from, uint8 to) internal pure returns (bool) {
        if (from == to) return false;
        uint8[6] memory masks = [uint8(0x3E), 0x21, 0x01, 0x01, 0x21, 0x00];
        return (masks[from] & (1 << to)) != 0;
    }

    // =========================================================================
    // Transfer restrictions
    // =========================================================================

    function test_Transfer_SucceedsWhenHeld() public {
        _mintToken(1);
        vm.prank(user);
        nft.transferFrom(user, user2, 1);
        assertEq(nft.ownerOf(1), user2);
    }

    function test_Transfer_RevertsWhenListed() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Listed);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotTransferable.selector,
                1,
                AssetNFT.AssetState.Listed
            )
        );
        nft.transferFrom(user, user2, 1);
    }

    function test_Transfer_RevertsWhenLoaned() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.Loaned);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotTransferable.selector,
                1,
                AssetNFT.AssetState.Loaned
            )
        );
        nft.transferFrom(user, user2, 1);
    }

    function test_Transfer_RevertsWhenInShipment() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.InShipment);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotTransferable.selector,
                1,
                AssetNFT.AssetState.InShipment
            )
        );
        nft.transferFrom(user, user2, 1);
    }

    function test_Transfer_RevertsWhenRemovedFromPlatform() public {
        _mintToken(1);
        vm.prank(stateManager);
        nft.setAssetState(1, AssetNFT.AssetState.RemovedFromPlatform);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotTransferable.selector,
                1,
                AssetNFT.AssetState.RemovedFromPlatform
            )
        );
        nft.transferFrom(user, user2, 1);
    }

    // =========================================================================
    // Metadata
    // =========================================================================

    function test_SetTokenURI_UpdatesURI() public {
        _mintToken(1);
        vm.prank(uriSetter);
        nft.setTokenURI(1, "ipfs://updated");
        assertEq(nft.tokenURI(1), "ipfs://updated");
    }

    function test_SetTokenURI_EmitsMetadataUpdate() public {
        _mintToken(1);
        vm.expectEmit(false, false, false, true, address(nft));
        emit MetadataUpdate(1);
        vm.prank(uriSetter);
        nft.setTokenURI(1, "ipfs://updated");
    }

    function test_SetTokenURI_RevertsWhenUnauthorized() public {
        _mintToken(1);
        vm.prank(user);
        vm.expectRevert();
        nft.setTokenURI(1, "ipfs://hack");
    }

    function test_SetBaseURI_PrefixesTokenURI() public {
        _mintToken(1);
        vm.prank(uriSetter);
        nft.setBaseURI("https://api.nettyworth.io/assets/");

        // After setting a base URI, tokenURI returns baseURI + stored token suffix
        // ERC721URIStorageUpgradeable: if _tokenURIs[id] is set, returns _baseURI() + _tokenURIs[id]
        assertEq(
            nft.tokenURI(1),
            string.concat("https://api.nettyworth.io/assets/", TOKEN_URI)
        );
    }

    function test_SetContractURI_Updates() public {
        vm.prank(uriSetter);
        nft.setContractURI("ipfs://new-contract-metadata");
        assertEq(nft.contractURI(), "ipfs://new-contract-metadata");
    }

    function test_SetContractURI_EmitsEvent() public {
        vm.expectEmit(false, false, false, false, address(nft));
        emit ContractURIUpdated();
        vm.prank(uriSetter);
        nft.setContractURI("ipfs://new-contract-metadata");
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function test_Pause_BlocksMint() public {
        vm.prank(pauser);
        nft.pause();

        vm.prank(minter);
        vm.expectRevert();
        nft.mint(user, 1, TOKEN_URI);
    }

    function test_Pause_BlocksTransfer() public {
        _mintToken(1);
        vm.prank(pauser);
        nft.pause();

        vm.prank(user);
        vm.expectRevert();
        nft.transferFrom(user, user2, 1);
    }

    function test_Unpause_ResumesMint() public {
        vm.startPrank(pauser);
        nft.pause();
        nft.unpause();
        vm.stopPrank();

        vm.prank(minter);
        nft.mint(user, 1, TOKEN_URI);
        assertEq(nft.ownerOf(1), user);
    }

    function test_Pause_RevertsWhenUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        nft.pause();
    }

    // =========================================================================
    // UUPS upgrade
    // =========================================================================

    function test_Upgrade_AuthorizedSucceeds() public {
        AssetNFT newImpl = new AssetNFT();
        vm.prank(upgrader);
        nft.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_RevertsWhenUnauthorized() public {
        AssetNFT newImpl = new AssetNFT();
        vm.prank(user);
        vm.expectRevert();
        nft.upgradeToAndCall(address(newImpl), "");
    }

    // =========================================================================
    // supportsInterface
    // =========================================================================

    function test_SupportsInterface_ERC721() public view {
        assertTrue(nft.supportsInterface(0x80ac58cd)); // IERC721
    }

    function test_SupportsInterface_ERC721Metadata() public view {
        assertTrue(nft.supportsInterface(0x5b5e139f)); // IERC721Metadata
    }

    function test_SupportsInterface_ERC721Enumerable() public view {
        assertTrue(nft.supportsInterface(0x780e9d63)); // IERC721Enumerable
    }

    function test_SupportsInterface_ERC4906() public view {
        assertTrue(nft.supportsInterface(0x49064906)); // IERC4906
    }

    function test_SupportsInterface_AccessControl() public view {
        assertTrue(nft.supportsInterface(0x7965db0b)); // IAccessControl
    }

    // =========================================================================
    // Event declarations (matching contract)
    // =========================================================================

    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event AssetStateChanged(
        uint256 indexed tokenId,
        AssetNFT.AssetState indexed previousState,
        AssetNFT.AssetState indexed newState
    );
    event ContractURIUpdated();
}
