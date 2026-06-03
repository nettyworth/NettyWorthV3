// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {NettyWorthMarketplace} from "../NettyWorthMarketplace.sol";
import {INettyWorthMarketplace} from "../interfaces/INettyWorthMarketplace.sol";
import {FeeController} from "../FeeController.sol";
import {IFeeController} from "../interfaces/IFeeController.sol";
import {AssetLendingPool} from "../AssetLendingPool.sol";
import {IAssetLendingPool} from "../interfaces/IAssetLendingPool.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {IAssetNFT} from "../interfaces/IAssetNFT.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

// Minimal PackMachine mock needed to initialise AssetLendingPool
contract MockPackMachineForMarket {
    address public assetNFT;
    constructor(address nft) {
        assetNFT = nft;
    }
    function depositFromPool(
        uint256[] calldata tokenIds,
        uint8[] calldata,
        address from
    ) external {
        for (uint256 i; i < tokenIds.length; i++) {
            IERC721(assetNFT).transferFrom(from, address(this), tokenIds[i]);
        }
    }
}
contract MockPackMachineFactoryForMarket {
    mapping(address => bool) private _m;
    function register(address m) external {
        _m[m] = true;
    }
    function isPackMachine(address m) external view returns (bool) {
        return _m[m];
    }
}

contract NettyWorthMarketplaceTest is Test {
    // =========================================================================
    // Contracts
    // =========================================================================
    NettyWorthMarketplace internal market;
    FeeController internal fc;
    AssetLendingPool internal pool;
    AssetNFT internal assetNFT;
    PermissionManager internal pm;
    MockERC20 internal usdc;

    // =========================================================================
    // Actors
    // =========================================================================
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal forwarder = makeAddr("forwarder");
    address internal buyer = makeAddr("buyer");
    address internal unauthorized = makeAddr("unauthorized");
    address internal royaltyReceiver = makeAddr("royaltyReceiver");

    uint256 internal sellerPk;
    address internal seller;

    uint256 internal bidderPk;
    address internal bidder;

    uint256 internal operatorPk;
    address internal operator;

    // =========================================================================
    // Constants
    // =========================================================================
    uint256 internal constant APPRAISAL = 1000e6;
    uint256 internal constant LTV_BPS = 5000; // 50%
    uint256 internal constant POOL_SEED = 10_000e6;
    uint256 internal constant SALE_PRICE = 1000e6;

    bytes32 internal constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 internal constant SIGNED_LISTING_TYPEHASH = keccak256(
        "SignedListing(address seller,address collection,uint256 tokenId,address paymentToken,"
        "uint256 price,uint256 nonce,uint256 expiry)"
    );
    bytes32 internal constant SIGNED_AUCTION_TYPEHASH = keccak256(
        "SignedAuction(address seller,address collection,uint256 tokenId,address paymentToken,"
        "uint256 reservePrice,uint256 minIncrement,uint256 startTime,uint256 endTime,"
        "uint256 extensionWindow,uint256 extensionDuration,uint256 nonce)"
    );
    bytes32 internal constant SIGNED_BID_TYPEHASH = keccak256(
        "SignedBid(bytes32 auctionId,address bidder,uint256 amount,uint256 nonce,uint256 expiry)"
    );

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        (seller, sellerPk) = makeAddrAndKey("seller");
        (bidder, bidderPk) = makeAddrAndKey("bidder");
        (operator, operatorPk) = makeAddrAndKey("operator");

        usdc = new MockERC20();

        // PermissionManager
        {
            PermissionManager pmImpl = new PermissionManager();
            ERC1967Proxy p = new ERC1967Proxy(
                address(pmImpl),
                abi.encodeCall(PermissionManager.initialize, (admin))
            );
            pm = PermissionManager(address(p));
        }

        // AssetNFT
        {
            AssetNFT impl = new AssetNFT(forwarder);
            ERC1967Proxy p = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    AssetNFT.initialize,
                    (
                        address(pm),
                        "NW Assets",
                        "NWA",
                        "ipfs://c",
                        royaltyReceiver,
                        500
                    )
                )
            );
            assetNFT = AssetNFT(address(p));
        }

        // AssetLendingPool
        {
            MockPackMachineForMarket mm = new MockPackMachineForMarket(
                address(assetNFT)
            );
            MockPackMachineFactoryForMarket mf = new MockPackMachineFactoryForMarket();
            mf.register(address(mm));

            AssetLendingPool impl = new AssetLendingPool();
            ERC1967Proxy p = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    AssetLendingPool.initialize,
                    (
                        admin,
                        address(usdc),
                        address(assetNFT),
                        LTV_BPS,
                        8000,
                        24 hours,
                        7 days,
                        address(mf)
                    )
                )
            );
            pool = AssetLendingPool(address(p));
        }

        // FeeController
        {
            FeeController impl = new FeeController();
            ERC1967Proxy p = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    FeeController.initialize,
                    (address(pm), treasury)
                )
            );
            fc = FeeController(address(p));
        }

        // NettyWorthMarketplace
        {
            NettyWorthMarketplace impl = new NettyWorthMarketplace();
            ERC1967Proxy p = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    NettyWorthMarketplace.initialize,
                    (
                        address(pm),
                        address(fc),
                        address(pool),
                        address(assetNFT),
                        address(usdc),
                        treasury
                    )
                )
            );
            market = NettyWorthMarketplace(address(p));
        }

        // Wiring
        vm.startPrank(admin);
        // Pool: grant STATE_MANAGER_ROLE + authorize marketplace
        pm.grantRole(Roles.STATE_MANAGER_ROLE, address(pool));
        pool.setMarketplace(address(market));
        // Mint some tokens to seller
        pm.grantRole(Roles.MINTER_ROLE, admin);
        address[] memory recipients = new address[](2);
        recipients[0] = seller;
        recipients[1] = seller;
        string[] memory uris = new string[](2);
        uris[0] = "ipfs://1";
        uris[1] = "ipfs://2";
        assetNFT.batchMint(recipients, uris);
        // Seed pool with USDC
        usdc.mint(admin, POOL_SEED);
        usdc.approve(address(pool), POOL_SEED);
        pool.deposit(POOL_SEED);
        // Set appraisals for both tokens
        // category 0 = uncategorised (exempt from eligibleCategories whitelist)
        pool.setAppraisal(1, APPRAISAL, 80, 0);
        pool.setAppraisal(2, APPRAISAL, 80, 0);
        vm.stopPrank();

        // Pre-fund buyer, bidder and operator
        usdc.mint(buyer, 10_000e6);
        usdc.mint(bidder, 10_000e6);
        usdc.mint(operator, 10_000e6);
        vm.prank(buyer);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bidder);
        usdc.approve(address(market), type(uint256).max);
        // Grant MARKETPLACE_ROLE to admin so force-close tests work
        vm.prank(admin);
        pm.grantRole(Roles.MARKETPLACE_ROLE, admin);
    }

    // =========================================================================
    // EIP-712 signing helpers
    // =========================================================================

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    keccak256("NettyWorthMarketplace"),
                    keccak256("1"),
                    block.chainid,
                    address(market)
                )
            );
    }

    function _signListing(
        INettyWorthMarketplace.SignedListing memory l,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_LISTING_TYPEHASH,
                l.seller,
                l.collection,
                l.tokenId,
                l.paymentToken,
                l.price,
                l.nonce,
                l.expiry
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signAuction(
        INettyWorthMarketplace.SignedAuction memory a,
        uint256 pk
    ) internal view returns (bytes memory sig, bytes32 auctionId) {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_AUCTION_TYPEHASH,
                a.seller,
                a.collection,
                a.tokenId,
                a.paymentToken,
                a.reservePrice,
                a.minIncrement,
                a.startTime,
                a.endTime,
                a.extensionWindow,
                a.extensionDuration,
                a.nonce
            )
        );
        auctionId = structHash;
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _signBid(
        INettyWorthMarketplace.SignedBid memory b,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_BID_TYPEHASH,
                b.auctionId,
                b.bidder,
                b.amount,
                b.nonce,
                b.expiry
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _defaultListing(
        uint256 tokenId,
        uint256 price,
        uint256 nonce
    ) internal view returns (INettyWorthMarketplace.SignedListing memory) {
        return
            INettyWorthMarketplace.SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: price,
                nonce: nonce,
                expiry: block.timestamp + 1 hours
            });
    }

    // =========================================================================
    // Fixed-price sale — no loan
    // =========================================================================

    function test_buyWithSignature_noLoan() public {
        uint256 tokenId = 1;
        // seller approves marketplace
        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        uint256 gross = SALE_PRICE;
        // collectible fee = 5% = 50e6; royalty = 5% (royaltyFee from ERC2981 = 50e6)
        // royalty cap = gross - collectibleFee - loanDebt = 1000 - 50 - 0 = 950; 50 < 950 ok
        // sellerProceeds = 1000 - 50 - 50 = 900
        uint256 collectibleFee = (gross * 500) / 10_000; // 50e6
        uint256 royalty = (gross * 500) / 10_000; // 50e6 (5% royalty set in setUp)
        uint256 sellerProceeds = gross - collectibleFee - royalty;

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            gross,
            1
        );
        bytes memory sig = _signListing(l, sellerPk);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 royaltyBefore = usdc.balanceOf(royaltyReceiver);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);
        market.buyWithSignature(l, sig);

        // NFT delivered to buyer
        assertEq(assetNFT.ownerOf(tokenId), buyer);
        // Buyer paid gross
        assertEq(usdc.balanceOf(buyer), buyerBefore - gross);
        // Treasury got collectible fee
        assertEq(usdc.balanceOf(treasury), treasuryBefore + collectibleFee);
        // Royalty receiver got royalty
        assertEq(usdc.balanceOf(royaltyReceiver), royaltyBefore + royalty);
        // Seller got proceeds
        assertEq(usdc.balanceOf(seller), sellerBefore + sellerProceeds);
    }

    // =========================================================================
    // Fixed-price sale — nonce replay
    // =========================================================================

    function test_buyWithSignature_revertNonceReplay() public {
        vm.prank(seller);
        assetNFT.approve(address(market), 1);

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            1,
            SALE_PRICE,
            42
        );
        bytes memory sig = _signListing(l, sellerPk);

        vm.prank(buyer);
        market.buyWithSignature(l, sig);

        // Mint another token to seller and try again with same nonce
        vm.prank(admin);
        address[] memory r = new address[](1);
        r[0] = seller;
        string[] memory u = new string[](1);
        u[0] = "ipfs://3";
        assetNFT.batchMint(r, u);
        uint256 tokenId2 = 3;
        vm.prank(seller);
        assetNFT.approve(address(market), tokenId2);

        INettyWorthMarketplace.SignedListing memory l2 = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId2,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 42,
                expiry: block.timestamp + 1 hours
            });
        bytes memory sig2 = _signListing(l2, sellerPk);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace.Marketplace__NonceUsed.selector,
                seller,
                42
            )
        );
        market.buyWithSignature(l2, sig2);
    }

    // =========================================================================
    // Fixed-price sale — expired listing
    // =========================================================================

    function test_buyWithSignature_revertExpired() public {
        vm.prank(seller);
        assetNFT.approve(address(market), 1);

        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: 1,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 1,
                expiry: block.timestamp - 1 // already expired
            });
        bytes memory sig = _signListing(l, sellerPk);

        vm.prank(buyer);
        vm.expectRevert(INettyWorthMarketplace.Marketplace__Expired.selector);
        market.buyWithSignature(l, sig);
    }

    // =========================================================================
    // Fixed-price sale — bad signature
    // =========================================================================

    function test_buyWithSignature_revertBadSig() public {
        vm.prank(seller);
        assetNFT.approve(address(market), 1);

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            1,
            SALE_PRICE,
            1
        );
        // sign with wrong key (buyer's key)
        (, uint256 wrongPk) = makeAddrAndKey("wrongSigner");
        bytes memory sig = _signListing(l, wrongPk);

        vm.prank(buyer);
        vm.expectRevert(
            INettyWorthMarketplace.Marketplace__InvalidSignature.selector
        );
        market.buyWithSignature(l, sig);
    }

    // =========================================================================
    // Fixed-price sale — collection not allowed
    // =========================================================================

    function test_buyWithSignature_revertCollectionNotAllowed() public {
        address badCollection = makeAddr("badNFT");
        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: badCollection,
                tokenId: 1,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
        bytes memory sig = _signListing(l, sellerPk);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace
                    .Marketplace__CollectionNotAllowed
                    .selector,
                badCollection
            )
        );
        market.buyWithSignature(l, sig);
    }

    // =========================================================================
    // Loan-aware: minPrice enforcement
    // =========================================================================

    function test_buyWithSignature_revertPriceBelowMinimum_whenLoaned() public {
        uint256 tokenId = 1;
        // Borrower takes a loan against token 1
        uint256 loanAmount = 400e6; // < MAX_LOAN = 500e6
        vm.startPrank(seller);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, loanAmount, 0);
        vm.stopPrank();

        (, , uint256 loanDebt) = pool.getLoanDebt(tokenId);
        // gross exactly = loanDebt — collectibleFee (5%) + loanDebt > gross → revert
        uint256 tooLow = loanDebt; // 5% fee will push required above this

        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: tooLow,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
        bytes memory sig = _signListing(l, sellerPk);

        vm.prank(buyer);
        vm.expectRevert(); // Marketplace__PriceBelowMinimum
        market.buyWithSignature(l, sig);
    }

    // =========================================================================
    // Loan auto-repay on sale — atomicity
    // =========================================================================

    function test_buyWithSignature_loanAutoRepay() public {
        uint256 tokenId = 1;
        uint256 loanAmount = 400e6;
        uint8 termId = 0;

        // Borrower takes out loan; pool custodies NFT
        vm.startPrank(seller);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, loanAmount, termId);
        vm.stopPrank();

        IAssetLendingPool.Loan memory loan = pool.getLoan(
            pool.getActiveLoanId(tokenId)
        );
        uint256 loanDebt = loan.principal + loan.interest;

        // Price = must cover collectibleFee (5%) + royalty (5%) + loanDebt
        // royalty is 5% of gross. Let gross = loanDebt / (1 - 0.05 - 0.05) = loanDebt / 0.9 + buffer
        uint256 gross = (loanDebt * 10_000) / 8000 + 1e6; // comfortable margin

        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: gross,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
        bytes memory sig = _signListing(l, sellerPk);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);
        market.buyWithSignature(l, sig);

        // NFT delivered to buyer
        assertEq(assetNFT.ownerOf(tokenId), buyer);
        // NFT state is Held
        assertEq(
            uint8(assetNFT.getAssetState(tokenId)),
            uint8(IAssetNFT.AssetState.Held)
        );
        // Loan is repaid
        IAssetLendingPool.Loan memory loanAfter = pool.getLoan(
            pool.getActiveLoanId(tokenId) != 0
                ? pool.getActiveLoanId(tokenId)
                : loan.loanId
        );
        assertTrue(loanAfter.isPaid);
        // tokenIdToActiveLoan cleared
        assertEq(pool.getActiveLoanId(tokenId), 0);
        // Pool received loanDebt
        assertGe(usdc.balanceOf(address(pool)), poolBefore + loanDebt);
        // Seller received something (net proceeds > 0)
        assertGt(usdc.balanceOf(seller), sellerBefore);
    }

    function test_buyWithSignature_loanAutoRepay_revertIfBuyerInsufficientAllowance()
        public
    {
        uint256 tokenId = 1;
        vm.startPrank(seller);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, 400e6, 0);
        vm.stopPrank();

        (, , uint256 loanDebt) = pool.getLoanDebt(tokenId);
        uint256 gross = loanDebt * 2;

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            gross,
            1
        );
        bytes memory sig = _signListing(l, sellerPk);

        // Revoke buyer allowance
        vm.prank(buyer);
        usdc.approve(address(market), 0);

        uint256 loanIdBefore = pool.getActiveLoanId(tokenId);

        vm.prank(buyer);
        vm.expectRevert(); // insufficient allowance
        market.buyWithSignature(l, sig);

        // Loan still active
        assertEq(pool.getActiveLoanId(tokenId), loanIdBefore);
    }

    // =========================================================================
    // Auction — below reserve reverts
    // =========================================================================

    function _defaultAuction(
        uint256 tokenId
    ) internal view returns (INettyWorthMarketplace.SignedAuction memory) {
        return
            INettyWorthMarketplace.SignedAuction({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                reservePrice: 800e6,
                minIncrement: 10e6,
                startTime: block.timestamp,
                endTime: block.timestamp + 1 days,
                extensionWindow: 5 minutes,
                extensionDuration: 10 minutes,
                nonce: 1
            });
    }

    function test_commitBid_revertBelowReserve() public {
        INettyWorthMarketplace.SignedAuction memory a = _defaultAuction(2);
        (bytes memory aSig, bytes32 aId) = _signAuction(a, sellerPk);

        INettyWorthMarketplace.SignedBid memory b = INettyWorthMarketplace
            .SignedBid({
                auctionId: aId,
                bidder: bidder,
                amount: 500e6,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
        bytes memory bSig = _signBid(b, bidderPk);

        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace.Marketplace__BidTooLow.selector,
                500e6,
                800e6
            )
        );
        market.commitBid(a, aSig, b, bSig);
    }

    function test_commitBid_firstBid_materializesState() public {
        INettyWorthMarketplace.SignedAuction memory a = _defaultAuction(2);
        (bytes memory aSig, bytes32 aId) = _signAuction(a, sellerPk);

        INettyWorthMarketplace.SignedBid memory b = INettyWorthMarketplace
            .SignedBid({
                auctionId: aId,
                bidder: bidder,
                amount: 900e6,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
        bytes memory bSig = _signBid(b, bidderPk);

        vm.prank(bidder);
        market.commitBid(a, aSig, b, bSig);

        INettyWorthMarketplace.AuctionState memory state = market.getAuction(
            aId
        );
        assertTrue(state.exists);
        assertEq(state.highestBidder, bidder);
        assertEq(state.highestBid, 900e6);
    }

    function test_commitBid_revertBelowMinIncrement() public {
        INettyWorthMarketplace.SignedAuction memory a = _defaultAuction(2);
        (bytes memory aSig, bytes32 aId) = _signAuction(a, sellerPk);

        // First bid: 900
        INettyWorthMarketplace.SignedBid memory b1 = INettyWorthMarketplace
            .SignedBid({
                auctionId: aId,
                bidder: bidder,
                amount: 900e6,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
        vm.prank(bidder);
        market.commitBid(a, aSig, b1, _signBid(b1, bidderPk));

        // Second bid only 5 above (minIncrement = 10)
        (address bidder2, uint256 pk2) = makeAddrAndKey("bidder2");
        usdc.mint(bidder2, 10_000e6);
        vm.prank(bidder2);
        usdc.approve(address(market), type(uint256).max);

        INettyWorthMarketplace.SignedBid memory b2 = INettyWorthMarketplace
            .SignedBid({
                auctionId: aId,
                bidder: bidder2,
                amount: 905e6,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
        vm.prank(bidder2);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace.Marketplace__BidTooLow.selector,
                905e6,
                910e6
            )
        );
        market.commitBid(a, aSig, b2, _signBid(b2, pk2));
    }

    function test_commitBid_extensionWindow_pushesEndTime() public {
        INettyWorthMarketplace.SignedAuction memory a = _defaultAuction(2);
        (bytes memory aSig, bytes32 aId) = _signAuction(a, sellerPk);

        // Jump to 3 minutes before endTime (within extensionWindow of 5 min)
        vm.warp(a.endTime - 3 minutes);

        INettyWorthMarketplace.SignedBid memory b = INettyWorthMarketplace
            .SignedBid({
                auctionId: aId,
                bidder: bidder,
                amount: 900e6,
                nonce: 1,
                expiry: a.endTime + 1 hours
            });
        vm.prank(bidder);
        market.commitBid(a, aSig, b, _signBid(b, bidderPk));

        INettyWorthMarketplace.AuctionState memory state = market.getAuction(
            aId
        );
        assertEq(state.endTime, a.endTime + 10 minutes);
    }

    function test_settleAuction_revertBeforeEnd() public {
        INettyWorthMarketplace.SignedAuction memory a = _defaultAuction(2);
        (bytes memory aSig, bytes32 aId) = _signAuction(a, sellerPk);

        INettyWorthMarketplace.SignedBid memory b = INettyWorthMarketplace
            .SignedBid({
                auctionId: aId,
                bidder: bidder,
                amount: 900e6,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
        vm.prank(bidder);
        market.commitBid(a, aSig, b, _signBid(b, bidderPk));

        // Try settle before end
        vm.prank(unauthorized);
        vm.expectRevert(
            INettyWorthMarketplace.Marketplace__AuctionNotEnded.selector
        );
        market.settleAuction(aId);
    }

    function test_settleAuction_afterEnd_noLoan() public {
        uint256 tokenId = 2;
        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        INettyWorthMarketplace.SignedAuction memory a = _defaultAuction(
            tokenId
        );
        (bytes memory aSig, bytes32 aId) = _signAuction(a, sellerPk);

        INettyWorthMarketplace.SignedBid memory b = INettyWorthMarketplace
            .SignedBid({
                auctionId: aId,
                bidder: bidder,
                amount: 900e6,
                nonce: 1,
                expiry: block.timestamp + 2 days
            });
        vm.prank(bidder);
        market.commitBid(a, aSig, b, _signBid(b, bidderPk));

        // Fast-forward past end
        vm.warp(a.endTime + 1);

        uint256 sellerBefore = usdc.balanceOf(seller);
        vm.prank(unauthorized); // anyone can settle
        market.settleAuction(aId);

        assertEq(assetNFT.ownerOf(tokenId), bidder);
        assertGt(usdc.balanceOf(seller), sellerBefore);
        assertTrue(market.getAuction(aId).settled);
    }

    function test_settleAuction_forcedCloseByMarketplaceRole() public {
        uint256 tokenId = 2;
        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        INettyWorthMarketplace.SignedAuction memory a = _defaultAuction(
            tokenId
        );
        (bytes memory aSig, bytes32 aId) = _signAuction(a, sellerPk);

        INettyWorthMarketplace.SignedBid memory b = INettyWorthMarketplace
            .SignedBid({
                auctionId: aId,
                bidder: bidder,
                amount: 900e6,
                nonce: 1,
                expiry: block.timestamp + 2 days
            });
        vm.prank(bidder);
        market.commitBid(a, aSig, b, _signBid(b, bidderPk));

        // Auction still active — only MARKETPLACE_ROLE can force close
        vm.prank(admin); // admin has MARKETPLACE_ROLE
        market.settleAuction(aId);
        assertTrue(market.getAuction(aId).settled);
    }

    // =========================================================================
    // Pool: onlyMarketplace guard
    // =========================================================================

    function test_settleLoanRepaymentOnSale_revertFromNonMarketplace() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__NotMarketplace.selector
        );
        pool.settleLoanRepaymentOnSale(1, unauthorized, unauthorized);
    }

    // =========================================================================
    // Pool: debt views
    // =========================================================================

    function test_getActiveLoanId_noLoan_returnsZero() public view {
        assertEq(pool.getActiveLoanId(1), 0);
    }

    function test_getLoanDebt_noLoan_returnsZero() public view {
        (uint256 p, uint256 i, uint256 t) = pool.getLoanDebt(1);
        assertEq(p, 0);
        assertEq(i, 0);
        assertEq(t, 0);
    }

    function test_getLoanDebt_withActiveLoan() public {
        uint256 tokenId = 1;
        uint256 loanAmt = 400e6;
        vm.startPrank(seller);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, loanAmt, 0);
        vm.stopPrank();

        (uint256 p, uint256 i, uint256 total) = pool.getLoanDebt(tokenId);
        assertEq(p, loanAmt);
        assertGt(i, 0);
        assertEq(total, p + i);
    }

    // =========================================================================
    // Pool: setMarketplace guards
    // =========================================================================

    function test_setMarketplace_revertIfNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        pool.setMarketplace(unauthorized);
    }

    function test_setMarketplace_revertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ZeroAddress.selector
        );
        pool.setMarketplace(address(0));
    }

    // =========================================================================
    // Pause gating
    // =========================================================================

    function test_buyWithSignature_revertWhenPaused() public {
        vm.prank(seller);
        assetNFT.approve(address(market), 1);

        vm.prank(admin);
        market.pause();

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            1,
            SALE_PRICE,
            1
        );
        bytes memory sig = _signListing(l, sellerPk);

        vm.prank(buyer);
        vm.expectRevert();
        market.buyWithSignature(l, sig);
    }

    // =========================================================================
    // cancelNonce
    // =========================================================================

    function test_cancelNonce_preventsLaterUse() public {
        vm.prank(seller);
        market.cancelNonce(99);

        assertTrue(market.isNonceUsed(seller, 99));

        vm.prank(seller);
        assetNFT.approve(address(market), 1);
        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            1,
            SALE_PRICE,
            99
        );
        bytes memory sig = _signListing(l, sellerPk);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace.Marketplace__NonceUsed.selector,
                seller,
                99
            )
        );
        market.buyWithSignature(l, sig);
    }

    // =========================================================================
    // Default lifecycle → operator claim → marketplace auction
    //
    // Verifies the manual operational workflow for defaulted assets:
    //   1. Loan expires  → initiateDefault  (collateral: Loaned → Held, stays in pool)
    //   2. Acquisition window passes
    //   3. Operator calls purchaseDefaultedAsset (pays outstanding value, receives NFT in Held)
    //   4. Operator lists on marketplace as a 24h signed auction at reservePrice = outstanding value
    //   5. Bidder wins; settleAuction delivers NFT to bidder, proceeds to operator (net of fees)
    //   6. Relist: a round with no qualifying bids never materializes an AuctionState on-chain;
    //      operator simply re-signs with a fresh nonce for the next 24h window
    // =========================================================================

    /// @dev Helper: originate a loan against tokenId 1 for `seller`.
    function _originateLoan() internal returns (uint256 loanId, uint256 outstanding) {
        uint256 tokenId = 1;
        uint256 loanAmount = 400e6;

        vm.startPrank(seller);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, loanAmount, 0);
        vm.stopPrank();

        loanId = pool.getActiveLoanId(tokenId);
        IAssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        outstanding = loan.principal + loan.interest;
    }

    /// @dev Step 1 + 2: default the loan and warp past the acquisition window.
    function _defaultAndWarpPastAcquisition(uint256 loanId) internal {
        IAssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        // Warp to loan expiry
        vm.warp(loan.expireTime + 1);
        vm.prank(admin);
        pool.initiateDefault(loanId);
        // Warp past 24h acquisition window
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // ----- test 1: operator claims defaulted NFT ----

    function test_defaultedAsset_operatorClaims_poolRecredited_accountingRestored() public {
        (uint256 loanId, ) = _originateLoan();
        _defaultAndWarpPastAcquisition(loanId);

        // rec.outstandingValue == loan.principal (interest is NOT included in the default record)
        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(loanId);
        uint256 claimPrice = rec.outstandingValue;

        uint256 poolBefore = usdc.balanceOf(address(pool));
        IAssetLendingPool.PoolInfo memory infoBefore = pool.getPoolInfo();

        // Operator claims: pays exactly the outstanding principal
        vm.startPrank(operator);
        usdc.approve(address(pool), claimPrice);
        pool.purchaseDefaultedAsset(loanId);
        vm.stopPrank();

        // Default record resolved
        IAssetLendingPool.DefaultRecord memory recAfter = pool.getDefaultRecord(loanId);
        assertTrue(recAfter.resolved);

        // Pool received exact claim price (principal only)
        assertEq(usdc.balanceOf(address(pool)), poolBefore + claimPrice);

        // Pool accounting re-credited
        IAssetLendingPool.PoolInfo memory infoAfter = pool.getPoolInfo();
        assertEq(
            infoAfter.totalDeposited,
            infoBefore.totalDeposited + claimPrice
        );
        assertEq(
            infoAfter.totalDefaultedPrincipal,
            infoBefore.totalDefaultedPrincipal - claimPrice
        );

        // Operator owns the NFT in Held state — ready to list
        assertEq(assetNFT.ownerOf(1), operator);
        assertEq(
            uint8(assetNFT.getAssetState(1)),
            uint8(IAssetNFT.AssetState.Held)
        );
    }

    // ----- test 2: full flow — default → claim → auction → settle ----

    function test_defaultedAsset_fullFlow_auctionAndSettle() public {
        (uint256 loanId, uint256 outstanding) = _originateLoan();
        _defaultAndWarpPastAcquisition(loanId);

        // Operator claims NFT
        vm.startPrank(operator);
        usdc.approve(address(pool), outstanding);
        pool.purchaseDefaultedAsset(loanId);
        // Operator approves marketplace
        assetNFT.approve(address(market), 1);
        vm.stopPrank();

        // --- Operator signs a 24h auction at reserve = outstanding value ---
        uint256 auctionStart = block.timestamp;
        INettyWorthMarketplace.SignedAuction memory a = INettyWorthMarketplace
            .SignedAuction({
                seller: operator,
                collection: address(assetNFT),
                tokenId: 1,
                paymentToken: address(usdc),
                reservePrice: outstanding, // == outstanding loan value (the "loan price")
                minIncrement: 10e6,
                startTime: auctionStart,
                endTime: auctionStart + 24 hours,
                extensionWindow: 5 minutes,
                extensionDuration: 10 minutes,
                nonce: 1
            });
        (bytes memory aSig, bytes32 aId) = _signAuction(a, operatorPk);

        // Bidder bids at reserve + some increment (reserve = 400e6 + interest)
        uint256 bidAmount = outstanding + 50e6;
        INettyWorthMarketplace.SignedBid memory b = INettyWorthMarketplace
            .SignedBid({
                auctionId: aId,
                bidder: bidder,
                amount: bidAmount,
                nonce: 1,
                expiry: auctionStart + 2 days
            });
        bytes memory bSig = _signBid(b, bidderPk);

        uint256 operatorBefore = usdc.balanceOf(operator);
        uint256 bidderBefore = usdc.balanceOf(bidder);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.prank(bidder);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bidder);
        market.commitBid(a, aSig, b, bSig);

        // Warp past end; anyone can settle
        vm.warp(auctionStart + 24 hours + 1);
        market.settleAuction(aId);

        // Bidder received the NFT
        assertEq(assetNFT.ownerOf(1), bidder);
        assertEq(
            uint8(assetNFT.getAssetState(1)),
            uint8(IAssetNFT.AssetState.Held)
        );

        // Bidder paid bidAmount
        assertEq(usdc.balanceOf(bidder), bidderBefore - bidAmount);

        // Treasury received collectible fee (5% of bidAmount)
        uint256 expectedFee = (bidAmount * 500) / 10_000;
        assertEq(usdc.balanceOf(treasury), treasuryBefore + expectedFee);

        // Operator received net proceeds (bidAmount - fee - royalty)
        assertGt(usdc.balanceOf(operator), operatorBefore);

        // Auction settled
        assertTrue(market.getAuction(aId).settled);
    }

    // ----- test 3: bid below reserve never materializes AuctionState (relist scenario) ----

    function test_defaultedAsset_bidBelowReserve_neverMaterializesState_operatorRelists()
        public
    {
        (uint256 loanId, ) = _originateLoan();
        _defaultAndWarpPastAcquisition(loanId);

        // Use rec.outstandingValue (== principal) as the claim price, not principal+interest
        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(loanId);
        uint256 claimPrice = rec.outstandingValue;

        vm.startPrank(operator);
        usdc.approve(address(pool), claimPrice);
        pool.purchaseDefaultedAsset(loanId);
        assetNFT.approve(address(market), 1);
        vm.stopPrank();

        // Round 1: operator signs a 24h auction at reserve = outstanding principal
        uint256 round1Start = block.timestamp;
        INettyWorthMarketplace.SignedAuction memory a1 = INettyWorthMarketplace
            .SignedAuction({
                seller: operator,
                collection: address(assetNFT),
                tokenId: 1,
                paymentToken: address(usdc),
                reservePrice: claimPrice,
                minIncrement: 10e6,
                startTime: round1Start,
                endTime: round1Start + 24 hours,
                extensionWindow: 5 minutes,
                extensionDuration: 10 minutes,
                nonce: 10
            });
        (bytes memory a1Sig, bytes32 a1Id) = _signAuction(a1, operatorPk);

        // Bid BELOW reserve reverts; AuctionState never written
        uint256 lowBid = claimPrice - 1;
        INettyWorthMarketplace.SignedBid memory bLow = INettyWorthMarketplace
            .SignedBid({
                auctionId: a1Id,
                bidder: bidder,
                amount: lowBid,
                nonce: 10,
                expiry: round1Start + 2 days
            });

        vm.prank(bidder);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace.Marketplace__BidTooLow.selector,
                lowBid,
                claimPrice
            )
        );
        market.commitBid(a1, a1Sig, bLow, _signBid(bLow, bidderPk));

        // AuctionState not materialized — round 1 never created on-chain
        assertFalse(market.getAuction(a1Id).exists);

        // Off-chain: window expires; operator re-signs for round 2 with same reserve + fresh nonce.
        // We keep endTime computation in a local var to avoid viaIR stack-slot reuse.
        uint256 round2End = round1Start + 24 hours + 1 + 24 hours; // = round1Start + 48h + 1
        vm.warp(round1Start + 24 hours + 1);

        INettyWorthMarketplace.SignedAuction memory a2 = INettyWorthMarketplace
            .SignedAuction({
                seller: operator,
                collection: address(assetNFT),
                tokenId: 1,
                paymentToken: address(usdc),
                reservePrice: claimPrice, // same reserve — relisted unchanged
                minIncrement: 10e6,
                startTime: block.timestamp,
                endTime: round2End,
                extensionWindow: 5 minutes,
                extensionDuration: 10 minutes,
                nonce: 11 // fresh nonce
            });
        (bytes memory a2Sig, bytes32 a2Id) = _signAuction(a2, operatorPk);

        // Round 2: qualifying bid at or above reserve succeeds
        uint256 qualifyingBid = claimPrice + 20e6;
        INettyWorthMarketplace.SignedBid memory bWin = INettyWorthMarketplace
            .SignedBid({
                auctionId: a2Id,
                bidder: bidder,
                amount: qualifyingBid,
                nonce: 11,
                expiry: round2End + 1 days
            });
        bytes memory bWinSig = _signBid(bWin, bidderPk);

        vm.prank(bidder);
        market.commitBid(a2, a2Sig, bWin, bWinSig);

        INettyWorthMarketplace.AuctionState memory s2 = market.getAuction(a2Id);
        assertTrue(s2.exists);
        assertEq(s2.highestBidder, bidder);
        assertEq(s2.highestBid, qualifyingBid);

        // Settle round 2 after its window
        vm.warp(round2End + 1);
        market.settleAuction(a2Id);
        assertEq(assetNFT.ownerOf(1), bidder);
        assertTrue(market.getAuction(a2Id).settled);
    }

    // ----- test 4: purchaseDefaultedAsset reverts during acquisition window ----

    function test_purchaseDefaultedAsset_revertDuringAcquisitionWindow() public {
        (uint256 loanId, ) = _originateLoan();
        IAssetLendingPool.Loan memory loan = pool.getLoan(loanId);

        // Warp to expiry and default — but stay inside the acquisition window
        vm.warp(loan.expireTime + 1);
        vm.prank(admin);
        pool.initiateDefault(loanId);

        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(loanId);
        uint256 outstanding = rec.outstandingValue;

        vm.startPrank(operator);
        usdc.approve(address(pool), outstanding);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__NotInPurchasePhase.selector
        );
        pool.purchaseDefaultedAsset(loanId);
        vm.stopPrank();
    }
}
