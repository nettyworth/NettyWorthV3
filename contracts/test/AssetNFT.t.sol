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
    address internal forwarder = makeAddr("forwarder");
    address internal royaltyReceiver = makeAddr("royaltyReceiver");

    string internal constant NAME = "NettyWorth Assets";
    string internal constant SYMBOL = "NWA";
    string internal constant CONTRACT_URI = "ipfs://contract-metadata";
    string internal constant TOKEN_URI = "ipfs://token/1";
    uint96 internal constant ROYALTY_FEE = 250; // 2.5%

    function setUp() public {
        AssetNFT impl = new AssetNFT(forwarder);
        bytes memory data = abi.encodeCall(
            AssetNFT.initialize,
            (admin, NAME, SYMBOL, CONTRACT_URI, royaltyReceiver, ROYALTY_FEE)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        nft = AssetNFT(address(proxy));

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
    // Helpers
    // =========================================================================

    /// @dev Mints one token to `user` and returns the assigned tokenId.
    function _mintToken() internal returns (uint256 tokenId) {
        address[] memory recipients = new address[](1);
        string[] memory uris = new string[](1);
        recipients[0] = user;
        uris[0] = TOKEN_URI;
        tokenId = nft.totalSupply() + 1;
        vm.prank(minter);
        nft.batchMint(recipients, uris);
    }

    /// @dev Transitions a single token state via batchSetAssetState.
    function _setAssetState(uint256 tokenId, AssetNFT.AssetState newState) internal {
        uint256[] memory ids = new uint256[](1);
        AssetNFT.AssetState[] memory states = new AssetNFT.AssetState[](1);
        ids[0] = tokenId;
        states[0] = newState;
        nft.batchSetAssetState(ids, states);
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
        AssetNFT impl = new AssetNFT(forwarder);
        bytes memory data = abi.encodeCall(
            AssetNFT.initialize,
            (address(0), NAME, SYMBOL, CONTRACT_URI, royaltyReceiver, ROYALTY_FEE)
        );
        vm.expectRevert(AssetNFT.AssetNFT__ZeroAddress.selector);
        new ERC1967Proxy(address(impl), data);
    }

    function test_Initialize_CannotInitializeTwice() public {
        vm.expectRevert();
        nft.initialize(admin, NAME, SYMBOL, CONTRACT_URI, royaltyReceiver, ROYALTY_FEE);
    }

    function test_Initialize_TrustedForwarder() public view {
        assertEq(nft.trustedForwarder(), forwarder);
    }

    function test_Initialize_RoyaltyInfo() public view {
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 10_000);
        assertEq(receiver, royaltyReceiver);
        assertEq(amount, 250); // 2.5% of 10_000
    }

    // =========================================================================
    // Minting
    // =========================================================================

    function test_BatchMint_Success() public {
        uint256 tokenId = _mintToken();

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(tokenId), user);
        assertEq(nft.tokenURI(tokenId), TOKEN_URI);
        assertEq(nft.totalSupply(), 1);
    }

    function test_BatchMint_SequentialIds() public {
        uint256 id1 = _mintToken();
        uint256 id2 = _mintToken();
        uint256 id3 = _mintToken();

        assertEq(id1, 1);
        assertEq(id2, 2);
        assertEq(id3, 3);
    }

    function test_BatchMint_StateIsHeld() public {
        uint256 tokenId = _mintToken();
        assertEq(uint8(nft.getAssetState(tokenId)), uint8(AssetNFT.AssetState.Held));
    }

    function test_BatchMint_MultipleRecipients() public {
        address[] memory recipients = new address[](3);
        string[] memory uris = new string[](3);
        for (uint256 i; i < 3; i++) {
            recipients[i] = user;
            uris[i] = TOKEN_URI;
        }

        vm.prank(minter);
        nft.batchMint(recipients, uris);

        assertEq(nft.totalSupply(), 3);
        assertEq(nft.ownerOf(1), user);
        assertEq(nft.ownerOf(2), user);
        assertEq(nft.ownerOf(3), user);
    }

    function test_BatchMint_EmitsBatchMetadataUpdate() public {
        address[] memory recipients = new address[](2);
        string[] memory uris = new string[](2);
        recipients[0] = user;
        recipients[1] = user;
        uris[0] = TOKEN_URI;
        uris[1] = TOKEN_URI;

        vm.expectEmit(false, false, false, true, address(nft));
        emit BatchMetadataUpdate(1, 2);

        vm.prank(minter);
        nft.batchMint(recipients, uris);
    }

    function test_BatchMint_RevertsWhenTooLarge() public {
        uint256 size = 51;
        address[] memory recipients = new address[](size);
        string[] memory uris = new string[](size);
        for (uint256 i; i < size; i++) {
            recipients[i] = user;
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
        nft.batchMint(recipients, uris);
    }

    function test_BatchMint_RevertsOnLengthMismatch() public {
        address[] memory recipients = new address[](2);
        string[] memory uris = new string[](1);

        vm.prank(minter);
        vm.expectRevert(AssetNFT.AssetNFT__ArrayLengthMismatch.selector);
        nft.batchMint(recipients, uris);
    }

    function test_BatchMint_RevertsWhenUnauthorized() public {
        address[] memory recipients = new address[](1);
        string[] memory uris = new string[](1);
        recipients[0] = user;
        uris[0] = TOKEN_URI;

        vm.prank(user);
        vm.expectRevert();
        nft.batchMint(recipients, uris);
    }

    // =========================================================================
    // Burning
    // =========================================================================

    function test_BatchBurn_FromHeld() public {
        uint256 tokenId = _mintToken();

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.prank(burner);
        nft.batchBurn(ids);

        vm.expectRevert();
        nft.ownerOf(tokenId);
    }

    function test_BatchBurn_FromRemovedFromPlatform() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.RemovedFromPlatform);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.prank(burner);
        nft.batchBurn(ids);

        vm.expectRevert();
        nft.ownerOf(tokenId);
    }

    function test_BatchBurn_EmitsMetadataUpdatePerToken() public {
        uint256 id1 = _mintToken();
        uint256 id2 = _mintToken();

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;

        vm.expectEmit(false, false, false, true, address(nft));
        emit MetadataUpdate(id1);
        vm.expectEmit(false, false, false, true, address(nft));
        emit MetadataUpdate(id2);

        vm.prank(burner);
        nft.batchBurn(ids);
    }

    function test_BatchBurn_MultipleTokens() public {
        uint256 id1 = _mintToken();
        uint256 id2 = _mintToken();
        uint256 id3 = _mintToken();

        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;

        vm.prank(burner);
        nft.batchBurn(ids);

        assertEq(nft.totalSupply(), 0);
    }

    function test_BatchBurn_RevertsWhenTooLarge() public {
        uint256 size = 51;
        uint256[] memory ids = new uint256[](size);
        for (uint256 i; i < size; i++) {
            ids[i] = i + 1;
        }

        vm.prank(burner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__BatchTooLarge.selector,
                size,
                50
            )
        );
        nft.batchBurn(ids);
    }

    function test_BatchBurn_RevertsOnNonExistentToken() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 999;

        vm.prank(burner);
        vm.expectRevert();
        nft.batchBurn(ids);
    }

    function test_BatchBurn_RevertsWhenUnauthorized() public {
        uint256 tokenId = _mintToken();
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.prank(user);
        vm.expectRevert();
        nft.batchBurn(ids);
    }

    function test_BatchBurn_RevertsWhenListed() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Listed);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.prank(burner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotBurnable.selector,
                tokenId,
                AssetNFT.AssetState.Listed
            )
        );
        nft.batchBurn(ids);
    }

    function test_BatchBurn_RevertsWhenLoaned() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Loaned);

        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.prank(burner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotBurnable.selector,
                tokenId,
                AssetNFT.AssetState.Loaned
            )
        );
        nft.batchBurn(ids);
    }

    function test_BatchBurn_RevertsPartialWhenOneFails() public {
        uint256 id1 = _mintToken();
        uint256 id2 = _mintToken();

        vm.prank(stateManager);
        _setAssetState(id2, AssetNFT.AssetState.Listed);

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;

        vm.prank(burner);
        vm.expectRevert();
        nft.batchBurn(ids);

        // id1 should still exist (tx reverted atomically)
        assertEq(nft.ownerOf(id1), user);
    }

    // =========================================================================
    // State machine
    // =========================================================================

    function test_SetAssetState_HeldToListed() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Listed);
        assertEq(uint8(nft.getAssetState(tokenId)), uint8(AssetNFT.AssetState.Listed));
    }

    function test_SetAssetState_HeldToLoaned() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Loaned);
        assertEq(uint8(nft.getAssetState(tokenId)), uint8(AssetNFT.AssetState.Loaned));
    }

    function test_SetAssetState_HeldToTraded() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Traded);
        assertEq(uint8(nft.getAssetState(tokenId)), uint8(AssetNFT.AssetState.Traded));
    }

    function test_SetAssetState_HeldToInShipment() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.InShipment);
        assertEq(uint8(nft.getAssetState(tokenId)), uint8(AssetNFT.AssetState.InShipment));
    }

    function test_SetAssetState_HeldToRemoved() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.RemovedFromPlatform);
        assertEq(uint8(nft.getAssetState(tokenId)), uint8(AssetNFT.AssetState.RemovedFromPlatform));
    }

    function test_SetAssetState_ListedToHeld() public {
        uint256 tokenId = _mintToken();
        vm.startPrank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Listed);
        _setAssetState(tokenId, AssetNFT.AssetState.Held);
        vm.stopPrank();
        assertEq(uint8(nft.getAssetState(tokenId)), uint8(AssetNFT.AssetState.Held));
    }

    function test_SetAssetState_LoanedToHeld() public {
        uint256 tokenId = _mintToken();
        vm.startPrank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Loaned);
        _setAssetState(tokenId, AssetNFT.AssetState.Held);
        vm.stopPrank();
        assertEq(uint8(nft.getAssetState(tokenId)), uint8(AssetNFT.AssetState.Held));
    }

    function test_SetAssetState_InShipmentToRemoved() public {
        uint256 tokenId = _mintToken();
        vm.startPrank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.InShipment);
        _setAssetState(tokenId, AssetNFT.AssetState.RemovedFromPlatform);
        vm.stopPrank();
        assertEq(uint8(nft.getAssetState(tokenId)), uint8(AssetNFT.AssetState.RemovedFromPlatform));
    }

    function test_SetAssetState_EmitsEvent() public {
        uint256 tokenId = _mintToken();
        vm.expectEmit(true, true, true, false, address(nft));
        emit AssetStateChanged(tokenId, AssetNFT.AssetState.Held, AssetNFT.AssetState.Listed);
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Listed);
    }

    function test_SetAssetState_RevertsInvalidTransition_ListedToLoaned() public {
        uint256 tokenId = _mintToken();
        vm.startPrank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Listed);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__InvalidStateTransition.selector,
                tokenId,
                AssetNFT.AssetState.Listed,
                AssetNFT.AssetState.Loaned
            )
        );
        _setAssetState(tokenId, AssetNFT.AssetState.Loaned);
        vm.stopPrank();
    }

    function test_SetAssetState_RevertsFromTerminalState() public {
        uint256 tokenId = _mintToken();
        vm.startPrank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.RemovedFromPlatform);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__InvalidStateTransition.selector,
                tokenId,
                AssetNFT.AssetState.RemovedFromPlatform,
                AssetNFT.AssetState.Held
            )
        );
        _setAssetState(tokenId, AssetNFT.AssetState.Held);
        vm.stopPrank();
    }

    function test_SetAssetState_RevertsWhenUnauthorized() public {
        uint256 tokenId = _mintToken();
        vm.prank(user);
        vm.expectRevert();
        _setAssetState(tokenId, AssetNFT.AssetState.Listed);
    }

    function test_BatchSetAssetState_Success() public {
        uint256 id1 = _mintToken();
        uint256 id2 = _mintToken();
        uint256 id3 = _mintToken();

        uint256[] memory ids = new uint256[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;

        AssetNFT.AssetState[] memory states = new AssetNFT.AssetState[](3);
        states[0] = AssetNFT.AssetState.Listed;
        states[1] = AssetNFT.AssetState.Listed;
        states[2] = AssetNFT.AssetState.Listed;

        vm.prank(stateManager);
        nft.batchSetAssetState(ids, states);

        assertEq(uint8(nft.getAssetState(id1)), uint8(AssetNFT.AssetState.Listed));
        assertEq(uint8(nft.getAssetState(id2)), uint8(AssetNFT.AssetState.Listed));
        assertEq(uint8(nft.getAssetState(id3)), uint8(AssetNFT.AssetState.Listed));
    }

    function test_BatchSetAssetState_RevertsWhenTooLarge() public {
        uint256 size = 51;
        uint256[] memory ids = new uint256[](size);
        AssetNFT.AssetState[] memory states = new AssetNFT.AssetState[](size);
        for (uint256 i; i < size; i++) {
            ids[i] = i + 1;
            states[i] = AssetNFT.AssetState.Listed;
        }

        vm.prank(stateManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__BatchTooLarge.selector,
                size,
                50
            )
        );
        nft.batchSetAssetState(ids, states);
    }

    function test_BatchSetAssetState_RevertsOnLengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        AssetNFT.AssetState[] memory states = new AssetNFT.AssetState[](1);
        ids[0] = 1;
        ids[1] = 2;
        states[0] = AssetNFT.AssetState.Listed;

        vm.prank(stateManager);
        vm.expectRevert(AssetNFT.AssetNFT__ArrayLengthMismatch.selector);
        nft.batchSetAssetState(ids, states);
    }

    function test_BatchSetAssetState_DifferentStatesPerToken() public {
        uint256 id1 = _mintToken();
        uint256 id2 = _mintToken();

        uint256[] memory ids = new uint256[](2);
        ids[0] = id1;
        ids[1] = id2;

        AssetNFT.AssetState[] memory states = new AssetNFT.AssetState[](2);
        states[0] = AssetNFT.AssetState.Listed;
        states[1] = AssetNFT.AssetState.Loaned;

        vm.prank(stateManager);
        nft.batchSetAssetState(ids, states);

        assertEq(uint8(nft.getAssetState(id1)), uint8(AssetNFT.AssetState.Listed));
        assertEq(uint8(nft.getAssetState(id2)), uint8(AssetNFT.AssetState.Loaned));
    }

    // Fuzz: exhaustively validate transition matrix (30 cross-state combos + 6 same-state)
    function testFuzz_StateTransitions(uint8 rawFrom, uint8 rawTo) public {
        uint8 numStates = 6;
        vm.assume(rawFrom < numStates && rawTo < numStates);
        AssetNFT.AssetState from = AssetNFT.AssetState(rawFrom);
        AssetNFT.AssetState to = AssetNFT.AssetState(rawTo);

        bool expected = _expectedValid(rawFrom, rawTo);

        uint256 tokenId = _mintToken();

        if (from != AssetNFT.AssetState.Held) {
            vm.prank(stateManager);
            _setAssetState(tokenId, from);
        }

        if (expected) {
            vm.prank(stateManager);
            _setAssetState(tokenId, to);
            assertEq(uint8(nft.getAssetState(tokenId)), uint8(to));
        } else {
            vm.prank(stateManager);
            vm.expectRevert();
            _setAssetState(tokenId, to);
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
        uint256 tokenId = _mintToken();
        vm.prank(user);
        nft.transferFrom(user, user2, tokenId);
        assertEq(nft.ownerOf(tokenId), user2);
    }

    function test_Transfer_RevertsWhenListed() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Listed);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotTransferable.selector,
                tokenId,
                AssetNFT.AssetState.Listed
            )
        );
        nft.transferFrom(user, user2, tokenId);
    }

    function test_Transfer_RevertsWhenLoaned() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.Loaned);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotTransferable.selector,
                tokenId,
                AssetNFT.AssetState.Loaned
            )
        );
        nft.transferFrom(user, user2, tokenId);
    }

    function test_Transfer_RevertsWhenInShipment() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.InShipment);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotTransferable.selector,
                tokenId,
                AssetNFT.AssetState.InShipment
            )
        );
        nft.transferFrom(user, user2, tokenId);
    }

    function test_Transfer_RevertsWhenRemovedFromPlatform() public {
        uint256 tokenId = _mintToken();
        vm.prank(stateManager);
        _setAssetState(tokenId, AssetNFT.AssetState.RemovedFromPlatform);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetNFT.AssetNFT__TokenNotTransferable.selector,
                tokenId,
                AssetNFT.AssetState.RemovedFromPlatform
            )
        );
        nft.transferFrom(user, user2, tokenId);
    }

    // =========================================================================
    // Metadata
    // =========================================================================

    function test_SetTokenURI_UpdatesURI() public {
        uint256 tokenId = _mintToken();
        vm.prank(uriSetter);
        nft.setTokenURI(tokenId, "ipfs://updated");
        assertEq(nft.tokenURI(tokenId), "ipfs://updated");
    }

    function test_SetTokenURI_EmitsMetadataUpdate() public {
        uint256 tokenId = _mintToken();
        vm.expectEmit(false, false, false, true, address(nft));
        emit MetadataUpdate(tokenId);
        vm.prank(uriSetter);
        nft.setTokenURI(tokenId, "ipfs://updated");
    }

    function test_SetTokenURI_RevertsWhenUnauthorized() public {
        uint256 tokenId = _mintToken();
        vm.prank(user);
        vm.expectRevert();
        nft.setTokenURI(tokenId, "ipfs://hack");
    }

    function test_SetBaseURI_PrefixesTokenURI() public {
        uint256 tokenId = _mintToken();
        vm.prank(uriSetter);
        nft.setBaseURI("https://api.nettyworth.io/assets/");

        assertEq(
            nft.tokenURI(tokenId),
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
    // ERC-2981 Royalties
    // =========================================================================

    function test_Royalty_DefaultInfo() public view {
        (address receiver, uint256 amount) = nft.royaltyInfo(1, 10_000);
        assertEq(receiver, royaltyReceiver);
        assertEq(amount, 250);
    }

    function test_Royalty_SetDefault() public {
        address newReceiver = makeAddr("newReceiver");
        vm.prank(admin);
        nft.setDefaultRoyalty(newReceiver, 500);

        (address receiver, uint256 amount) = nft.royaltyInfo(1, 10_000);
        assertEq(receiver, newReceiver);
        assertEq(amount, 500);
    }

    function test_Royalty_SetTokenOverride() public {
        uint256 tokenId = _mintToken();
        address tokenReceiver = makeAddr("tokenReceiver");
        vm.prank(admin);
        nft.setTokenRoyalty(tokenId, tokenReceiver, 1000);

        (address receiver, uint256 amount) = nft.royaltyInfo(tokenId, 10_000);
        assertEq(receiver, tokenReceiver);
        assertEq(amount, 1000);

        // Other tokens still use default
        (address defReceiver,) = nft.royaltyInfo(999, 10_000);
        assertEq(defReceiver, royaltyReceiver);
    }

    function test_Royalty_DeleteDefault() public {
        vm.prank(admin);
        nft.deleteDefaultRoyalty();

        (address receiver, uint256 amount) = nft.royaltyInfo(1, 10_000);
        assertEq(receiver, address(0));
        assertEq(amount, 0);
    }

    function test_Royalty_ResetTokenRoyalty() public {
        uint256 tokenId = _mintToken();
        address tokenReceiver = makeAddr("tokenReceiver");
        vm.startPrank(admin);
        nft.setTokenRoyalty(tokenId, tokenReceiver, 1000);
        nft.resetTokenRoyalty(tokenId);
        vm.stopPrank();

        // Falls back to default
        (address receiver,) = nft.royaltyInfo(tokenId, 10_000);
        assertEq(receiver, royaltyReceiver);
    }

    function test_Royalty_RevertsWhenUnauthorized() public {
        vm.prank(user);
        vm.expectRevert();
        nft.setDefaultRoyalty(user, 100);
    }

    // =========================================================================
    // ERC-2771 Meta-transactions
    // =========================================================================

    function test_MetaTx_TrustedForwarder() public view {
        assertTrue(nft.isTrustedForwarder(forwarder));
        assertFalse(nft.isTrustedForwarder(user));
    }

    function test_MetaTx_BatchMintViaForwarder() public {
        address[] memory recipients = new address[](1);
        string[] memory uris = new string[](1);
        recipients[0] = user;
        uris[0] = TOKEN_URI;

        bytes memory mintCall = abi.encodeWithSelector(
            AssetNFT.batchMint.selector,
            recipients,
            uris
        );
        bytes memory forwardedCall = bytes.concat(mintCall, bytes20(minter));

        vm.prank(forwarder);
        (bool ok,) = address(nft).call(forwardedCall);
        assertTrue(ok);

        assertEq(nft.ownerOf(1), user);
    }

    // =========================================================================
    // ERC721AQueryable
    // =========================================================================

    function test_TokensOfOwner_ReturnsCorrectList() public {
        _mintToken();
        _mintToken();
        _mintToken();

        uint256[] memory tokens = nft.tokensOfOwner(user);
        assertEq(tokens.length, 3);
        assertEq(tokens[0], 1);
        assertEq(tokens[1], 2);
        assertEq(tokens[2], 3);
    }

    function test_TokensOfOwner_AfterTransfer() public {
        _mintToken();
        _mintToken();

        vm.prank(user);
        nft.transferFrom(user, user2, 1);

        uint256[] memory userTokens = nft.tokensOfOwner(user);
        assertEq(userTokens.length, 1);
        assertEq(userTokens[0], 2);

        uint256[] memory user2Tokens = nft.tokensOfOwner(user2);
        assertEq(user2Tokens.length, 1);
        assertEq(user2Tokens[0], 1);
    }

    function test_ExplicitOwnershipOf() public {
        uint256 tokenId = _mintToken();
        assertEq(nft.explicitOwnershipOf(tokenId).addr, user);
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function test_Pause_BlocksBatchMint() public {
        vm.prank(pauser);
        nft.pause();

        address[] memory recipients = new address[](1);
        string[] memory uris = new string[](1);
        recipients[0] = user;
        uris[0] = TOKEN_URI;

        vm.prank(minter);
        vm.expectRevert();
        nft.batchMint(recipients, uris);
    }

    function test_Pause_BlocksTransfer() public {
        uint256 tokenId = _mintToken();
        vm.prank(pauser);
        nft.pause();

        vm.prank(user);
        vm.expectRevert();
        nft.transferFrom(user, user2, tokenId);
    }

    function test_Unpause_ResumesBatchMint() public {
        vm.startPrank(pauser);
        nft.pause();
        nft.unpause();
        vm.stopPrank();

        uint256 tokenId = _mintToken();
        assertEq(nft.ownerOf(tokenId), user);
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
        AssetNFT newImpl = new AssetNFT(forwarder);
        vm.prank(upgrader);
        nft.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_RevertsWhenUnauthorized() public {
        AssetNFT newImpl = new AssetNFT(forwarder);
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

    function test_SupportsInterface_ERC2981() public view {
        assertTrue(nft.supportsInterface(0x2a55205a)); // IERC2981
    }

    function test_SupportsInterface_AccessControl() public view {
        assertTrue(nft.supportsInterface(0x7965db0b)); // IAccessControl
    }

    function test_SupportsInterface_ERC165() public view {
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // IERC165
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
