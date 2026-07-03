// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {NettyWorthMarketplace} from "../NettyWorthMarketplace.sol";
import {INettyWorthMarketplace} from "../interfaces/INettyWorthMarketplace.sol";
import {FeeController} from "../FeeController.sol";
import {IFeeController} from "../interfaces/IFeeController.sol";
import {AssetLendingPool} from "../AssetLendingPool.sol";
import {AssetLendingPoolConfig} from "../AssetLendingPoolConfig.sol";
import {IAssetLendingPool} from "../interfaces/IAssetLendingPool.sol";
import {IAssetLendingPoolConfig} from "../interfaces/IAssetLendingPoolConfig.sol";
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
    AssetLendingPoolConfig internal config;
    AssetNFT internal assetNFT;
    PermissionManager internal pm;
    MockERC20 internal usdc;

    // =========================================================================
    // Actors
    // =========================================================================
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal forwarder = makeAddr("forwarder");
    address internal unauthorized = makeAddr("unauthorized");
    address internal royaltyReceiver = makeAddr("royaltyReceiver");

    uint256 internal sellerPk;
    address internal seller;

    uint256 internal buyerPk;
    address internal buyer;

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
        "uint256 price,uint256 nonce,uint256 expiry,address buyer)"
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
        (buyer, buyerPk) = makeAddrAndKey("buyer");
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

        // AssetLendingPoolConfig + AssetLendingPool
        {
            MockPackMachineForMarket mm = new MockPackMachineForMarket(
                address(assetNFT)
            );
            MockPackMachineFactoryForMarket mf = new MockPackMachineFactoryForMarket();
            mf.register(address(mm));

            AssetLendingPoolConfig configImpl = new AssetLendingPoolConfig();
            ERC1967Proxy cp = new ERC1967Proxy(
                address(configImpl),
                abi.encodeCall(
                    AssetLendingPoolConfig.initialize,
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
            config = AssetLendingPoolConfig(address(cp));

            AssetLendingPool impl = new AssetLendingPool();
            ERC1967Proxy p = new ERC1967Proxy(
                address(impl),
                abi.encodeCall(
                    AssetLendingPool.initialize,
                    (admin, address(config))
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
        // Pool: grant STATE_MANAGER_ROLE + authorize marketplace via config
        pm.grantRole(Roles.STATE_MANAGER_ROLE, address(pool));
        config.setMarketplace(address(market));
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
        // Set appraisals for both tokens via config
        // category 0 = uncategorised (exempt from eligibleCategories whitelist)
        config.setAppraisal(1, APPRAISAL, 80, 0);
        config.setAppraisal(2, APPRAISAL, 80, 0);
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
                l.expiry,
                l.buyer
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
                expiry: block.timestamp + 1 hours,
                buyer: address(0)
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
                expiry: block.timestamp + 1 hours,
                buyer: address(0)
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
                expiry: block.timestamp - 1, // already expired
                buyer: address(0)
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
                expiry: block.timestamp + 1 hours,
                buyer: address(0)
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
                expiry: block.timestamp + 1 hours,
                buyer: address(0)
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
                expiry: block.timestamp + 1 hours,
                buyer: address(0)
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
    // Config: setMarketplace guards
    // =========================================================================

    function test_setMarketplace_revertIfNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        config.setMarketplace(unauthorized);
    }

    function test_setMarketplace_revertZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ZeroAddress.selector
        );
        config.setMarketplace(address(0));
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
    // Default lifecycle → pool-default marketplace auction
    //
    // Verifies the pool-default auction workflow:
    //   1. Loan expires  → initiateDefault  (collateral: Loaned → Held, stays in pool)
    //   2. Acquisition window passes
    //   3. MARKETPLACE_ROLE calls listDefaultedAsset → pool pre-approves marketplace
    //   4. Bidder commits a pool bid via commitPoolBid
    //   5. settleAuction delivers NFT to bidder, full proceeds to pool
    //   6. Relist: cancelAuction allows MARKETPLACE_ROLE to relist with fresh params
    // =========================================================================

    /// @dev Helper: originate a loan against tokenId 1 for `seller`.
    function _originateLoan()
        internal
        returns (uint256 loanId, uint256 outstanding)
    {
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

    /// @dev Steps 1 + 2: default the loan and warp past the acquisition window.
    function _defaultAndWarpPastAcquisition(uint256 loanId) internal {
        IAssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        // Warp to loan expiry
        vm.warp(loan.expireTime + 1);
        vm.prank(admin);
        pool.initiateDefault(loanId);
        // Warp past 24h acquisition window
        vm.warp(block.timestamp + 24 hours + 1);
    }

    // ----- test 1: pool-default auction — listDefaultedAsset and settleAuction ----

    function test_defaultedAsset_poolDefaultAuction_fullFlow() public {
        (uint256 loanId, uint256 outstanding) = _originateLoan();
        _defaultAndWarpPastAcquisition(loanId);

        uint256 tokenId = 1;
        uint256 reservePrice = outstanding; // pool.principal + pool.interest
        uint256 auctionStart = block.timestamp;
        uint256 auctionEnd = auctionStart + 48 hours; // 48h so bidding window is well after auctionStart

        // Capture the DefaultedAssetListed event to get the auctionId (includes block.timestamp so
        // we cannot pre-compute it reliably without snapshotting the storage slot).
        vm.recordLogs();
        vm.prank(admin);
        market.listDefaultedAsset(
            loanId,
            tokenId,
            reservePrice,
            10e6, // minIncrement
            auctionStart,
            auctionEnd,
            5 minutes,
            10 minutes
        );
        // Parse the DefaultedAssetListed event: topic[0] = sig, [1] = loanId, [2] = tokenId,
        // [3] = auctionId. The ABI layout is indexed(loanId, tokenId, auctionId) + non-indexed.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 auctionId;
        for (uint256 i; i < logs.length; i++) {
            // DefaultedAssetListed(uint256 indexed loanId, uint256 indexed tokenId,
            //                      bytes32 indexed auctionId, uint256, uint256)
            bytes32 sig = keccak256(
                "DefaultedAssetListed(uint256,uint256,bytes32,uint256,uint256)"
            );
            if (logs[i].topics[0] == sig) {
                auctionId = logs[i].topics[3];
                break;
            }
        }
        assertTrue(auctionId != bytes32(0), "auctionId not found in logs");
        assertTrue(market.getAuction(auctionId).exists);

        // Bidder commits a pool bid at reserve price
        uint256 bidAmount = reservePrice + 50e6;
        INettyWorthMarketplace.SignedBid memory b = INettyWorthMarketplace
            .SignedBid({
                auctionId: auctionId,
                bidder: bidder,
                amount: bidAmount,
                nonce: 100,
                expiry: auctionEnd + 1 days
            });
        bytes memory bSig = _signBid(b, bidderPk);

        vm.prank(bidder);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bidder);
        market.commitPoolBid(auctionId, b, bSig);

        // Warp past end; anyone can settle
        vm.warp(auctionEnd + 1);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        market.settleAuction(auctionId);

        // NFT delivered to bidder
        assertEq(assetNFT.ownerOf(tokenId), bidder);
        // Pool received full bid proceeds (fees/royalty waived for pool-default)
        assertGe(usdc.balanceOf(address(pool)), poolBefore + bidAmount);
        // Auction settled
        assertTrue(market.getAuction(auctionId).settled);
        // Default record resolved
        assertTrue(pool.getDefaultRecord(loanId).resolved);
    }

    // ----- test 2: listDefaultedAsset reverts during acquisition window ----

    function test_listDefaultedAsset_revertDuringAcquisitionWindow() public {
        (uint256 loanId, uint256 outstanding) = _originateLoan();
        IAssetLendingPool.Loan memory loan = pool.getLoan(loanId);

        // Warp to expiry and default — but stay inside the 24h acquisition window
        vm.warp(loan.expireTime + 1);
        vm.prank(admin);
        pool.initiateDefault(loanId);

        // Attempt to list before acquisition window passes
        vm.prank(admin);
        vm.expectRevert(); // AssetLendingPool__NotInPurchasePhase
        market.listDefaultedAsset(
            loanId,
            1,
            outstanding,
            10e6,
            block.timestamp,
            block.timestamp + 24 hours,
            5 minutes,
            10 minutes
        );
    }

    // =========================================================================
    // acceptOffer — EIP-712 typehash (redeclared for signing helpers)
    // =========================================================================

    bytes32 internal constant SIGNED_OFFER_TYPEHASH = keccak256(
        "SignedOffer(address buyer,address collection,uint256 tokenId,address paymentToken,"
        "uint256 price,uint256 nonce,uint256 expiry)"
    );

    // =========================================================================
    // acceptOffer — signing helpers
    // =========================================================================

    function _signOffer(
        INettyWorthMarketplace.SignedOffer memory o,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_OFFER_TYPEHASH,
                o.buyer,
                o.collection,
                o.tokenId,
                o.paymentToken,
                o.price,
                o.nonce,
                o.expiry
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _domainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _defaultOffer(
        address offerBuyer,
        uint256 tokenId,
        uint256 price,
        uint256 nonce
    ) internal view returns (INettyWorthMarketplace.SignedOffer memory) {
        return
            INettyWorthMarketplace.SignedOffer({
                buyer: offerBuyer,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: price,
                nonce: nonce,
                expiry: block.timestamp + 1 hours
            });
    }

    // =========================================================================
    // acceptOffer — happy path, no loan
    // =========================================================================

    function test_acceptOffer_noLoan_happyPath() public {
        uint256 tokenId = 1;
        uint256 gross = SALE_PRICE;

        uint256 collectibleFee = (gross * 500) / 10_000; // 5%
        uint256 royalty = (gross * 500) / 10_000; // 5%
        uint256 sellerProceeds = gross - collectibleFee - royalty;

        // Seller approves marketplace to transfer the NFT
        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        // Buyer funds + approves already set up in setUp
        INettyWorthMarketplace.SignedOffer memory o = _defaultOffer(
            buyer,
            tokenId,
            gross,
            1
        );
        bytes memory sig = _signOffer(o, buyerPk);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 treasBefore = usdc.balanceOf(treasury);
        uint256 royaltyBefore = usdc.balanceOf(royaltyReceiver);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.expectEmit(true, true, true, true);
        emit INettyWorthMarketplace.OfferAccepted(
            buyer,
            seller,
            address(assetNFT),
            tokenId,
            address(usdc),
            gross
        );

        vm.prank(seller);
        market.acceptOffer(o, sig);

        // NFT transferred to buyer
        assertEq(assetNFT.ownerOf(tokenId), buyer);
        // Buyer paid gross
        assertEq(usdc.balanceOf(buyer), buyerBefore - gross);
        // Treasury received collectible fee
        assertEq(usdc.balanceOf(treasury), treasBefore + collectibleFee);
        // Royalty receiver received royalty
        assertEq(usdc.balanceOf(royaltyReceiver), royaltyBefore + royalty);
        // Seller received net proceeds
        assertEq(usdc.balanceOf(seller), sellerBefore + sellerProceeds);
    }

    // =========================================================================
    // acceptOffer — loan branch: borrower accepts, loan auto-repaid
    // =========================================================================

    function test_acceptOffer_withActiveLoan_borrowerAccepts() public {
        uint256 tokenId = 1;
        uint256 loanAmount = 400e6;

        // Borrower (seller) puts tokenId into pool as collateral
        vm.startPrank(seller);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, loanAmount, 0);
        vm.stopPrank();

        (, , uint256 loanDebt) = pool.getLoanDebt(tokenId);
        // Gross must cover: collectibleFee (5%) + royalty (5%) + loanDebt
        uint256 gross = (loanDebt * 10_000) / 8000 + 2e6;

        INettyWorthMarketplace.SignedOffer memory o = _defaultOffer(
            buyer,
            tokenId,
            gross,
            10
        );
        bytes memory sig = _signOffer(o, buyerPk);

        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 sellerBefore = usdc.balanceOf(seller);

        // Seller (borrower) accepts
        vm.prank(seller);
        market.acceptOffer(o, sig);

        // NFT delivered to buyer
        assertEq(assetNFT.ownerOf(tokenId), buyer);
        // Loan cleared
        assertEq(pool.getActiveLoanId(tokenId), 0);
        // Pool received at least loanDebt
        assertGe(usdc.balanceOf(address(pool)), poolBefore + loanDebt);
        // Seller got net proceeds
        assertGt(usdc.balanceOf(seller), sellerBefore);
    }

    // =========================================================================
    // acceptOffer — non-borrower cannot accept on a collateralised token
    // =========================================================================

    function test_acceptOffer_withActiveLoan_revertIfNotBorrower() public {
        uint256 tokenId = 1;

        vm.startPrank(seller);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, 400e6, 0);
        vm.stopPrank();

        (, , uint256 loanDebt) = pool.getLoanDebt(tokenId);
        uint256 gross = loanDebt * 2;

        // A third party (buyer) tries to "accept" the offer on the collateralised token
        // — they are not the borrower, so it should revert.
        (address thirdParty, uint256 thirdPk) = makeAddrAndKey("thirdParty");
        usdc.mint(thirdParty, 20_000e6);
        vm.prank(thirdParty);
        usdc.approve(address(market), type(uint256).max);

        // Offer is signed by yet another buyer address
        INettyWorthMarketplace.SignedOffer memory o = _defaultOffer(
            buyer,
            tokenId,
            gross,
            20
        );
        bytes memory sig = _signOffer(o, buyerPk);

        // thirdParty (not the borrower) calls acceptOffer — must revert
        vm.prank(thirdParty);
        vm.expectRevert(
            INettyWorthMarketplace.Marketplace__NotTokenOwner.selector
        );
        market.acceptOffer(o, sig);
        (thirdPk); // silence unused variable warning
    }

    // =========================================================================
    // acceptOffer — revert: bad signature
    // =========================================================================

    function test_acceptOffer_revertBadSignature() public {
        vm.prank(seller);
        assetNFT.approve(address(market), 1);

        INettyWorthMarketplace.SignedOffer memory o = _defaultOffer(
            buyer,
            1,
            SALE_PRICE,
            1
        );
        // Sign with a different key
        (, uint256 wrongPk) = makeAddrAndKey("wrongKey");
        bytes memory sig = _signOffer(o, wrongPk);

        vm.prank(seller);
        vm.expectRevert(
            INettyWorthMarketplace.Marketplace__InvalidSignature.selector
        );
        market.acceptOffer(o, sig);
    }

    // =========================================================================
    // acceptOffer — revert: nonce already used (by buyer)
    // =========================================================================

    function test_acceptOffer_revertNonceReplay() public {
        uint256 tokenId = 1;

        // Seller approves marketplace for token 1
        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        INettyWorthMarketplace.SignedOffer memory o = _defaultOffer(
            buyer,
            tokenId,
            SALE_PRICE,
            5
        );
        bytes memory sig = _signOffer(o, buyerPk);

        // First accept succeeds
        vm.prank(seller);
        market.acceptOffer(o, sig);

        // Mint a second token to seller and try to reuse the same nonce
        vm.prank(admin);
        address[] memory r = new address[](1);
        r[0] = seller;
        string[] memory u = new string[](1);
        u[0] = "ipfs://replay";
        assetNFT.batchMint(r, u);
        uint256 tokenId2 = 3;

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId2);

        INettyWorthMarketplace.SignedOffer memory o2 = INettyWorthMarketplace
            .SignedOffer({
                buyer: buyer,
                collection: address(assetNFT),
                tokenId: tokenId2,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 5, // same nonce
                expiry: block.timestamp + 1 hours
            });
        bytes memory sig2 = _signOffer(o2, buyerPk);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace.Marketplace__NonceUsed.selector,
                buyer,
                5
            )
        );
        market.acceptOffer(o2, sig2);
    }

    // =========================================================================
    // acceptOffer — revert: expired
    // =========================================================================

    function test_acceptOffer_revertExpired() public {
        vm.prank(seller);
        assetNFT.approve(address(market), 1);

        INettyWorthMarketplace.SignedOffer memory o = INettyWorthMarketplace
            .SignedOffer({
                buyer: buyer,
                collection: address(assetNFT),
                tokenId: 1,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 1,
                expiry: block.timestamp - 1 // already expired
            });
        bytes memory sig = _signOffer(o, buyerPk);

        vm.prank(seller);
        vm.expectRevert(INettyWorthMarketplace.Marketplace__Expired.selector);
        market.acceptOffer(o, sig);
    }

    // =========================================================================
    // acceptOffer — revert: collection not allowed
    // =========================================================================

    function test_acceptOffer_revertCollectionNotAllowed() public {
        address badCollection = makeAddr("badNFT");
        INettyWorthMarketplace.SignedOffer memory o = INettyWorthMarketplace
            .SignedOffer({
                buyer: buyer,
                collection: badCollection,
                tokenId: 1,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 1,
                expiry: block.timestamp + 1 hours
            });
        bytes memory sig = _signOffer(o, buyerPk);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace
                    .Marketplace__CollectionNotAllowed
                    .selector,
                badCollection
            )
        );
        market.acceptOffer(o, sig);
    }

    // =========================================================================
    // acceptOffer — revert: price below minimum (loan debt exceeds offer - fees)
    // =========================================================================

    function test_acceptOffer_revertPriceBelowMinimum_whenLoaned() public {
        uint256 tokenId = 1;

        vm.startPrank(seller);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, 400e6, 0);
        vm.stopPrank();

        (, , uint256 loanDebt) = pool.getLoanDebt(tokenId);
        // Offer price equal to loanDebt — 5% fee pushes required above gross
        INettyWorthMarketplace.SignedOffer memory o = _defaultOffer(
            buyer,
            tokenId,
            loanDebt,
            30
        );
        bytes memory sig = _signOffer(o, buyerPk);

        vm.prank(seller);
        vm.expectRevert(); // Marketplace__PriceBelowMinimum
        market.acceptOffer(o, sig);
    }

    // =========================================================================
    // acceptOffer — cancelNonce blocks future accept
    // =========================================================================

    function test_acceptOffer_cancelNonce_blocksAcceptance() public {
        vm.prank(seller);
        assetNFT.approve(address(market), 1);

        // Buyer cancels their own nonce 77
        vm.prank(buyer);
        market.cancelNonce(77);

        assertTrue(market.isNonceUsed(buyer, 77));

        INettyWorthMarketplace.SignedOffer memory o = _defaultOffer(
            buyer,
            1,
            SALE_PRICE,
            77
        );
        bytes memory sig = _signOffer(o, buyerPk);

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace.Marketplace__NonceUsed.selector,
                buyer,
                77
            )
        );
        market.acceptOffer(o, sig);
    }

    // =========================================================================
    // acceptOffer — revert when paused
    // =========================================================================

    function test_acceptOffer_revertWhenPaused() public {
        vm.prank(seller);
        assetNFT.approve(address(market), 1);

        vm.prank(admin);
        market.pause();

        INettyWorthMarketplace.SignedOffer memory o = _defaultOffer(
            buyer,
            1,
            SALE_PRICE,
            1
        );
        bytes memory sig = _signOffer(o, buyerPk);

        vm.prank(seller);
        vm.expectRevert(); // EnforcedPause
        market.acceptOffer(o, sig);
    }

    // =========================================================================
    // buyWithSignatureFor — open listing: payer != recipient (platform pattern)
    // =========================================================================

    function test_buyWithSignatureFor_openListing_deliverToRecipient() public {
        uint256 tokenId = 1;
        address endUser = makeAddr("endUser");

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        uint256 gross = SALE_PRICE;
        uint256 collectibleFee = (gross * 500) / 10_000; // 5%
        uint256 royalty = (gross * 500) / 10_000; // 5%
        uint256 sellerProceeds = gross - collectibleFee - royalty;

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            gross,
            1
        );
        bytes memory sig = _signListing(l, sellerPk);

        uint256 payerBefore = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);
        uint256 treasBefore = usdc.balanceOf(treasury);
        uint256 royaltyBefore = usdc.balanceOf(royaltyReceiver);

        // buyer (platform) pays; endUser receives the NFT
        vm.prank(buyer);
        market.buyWithSignatureFor(l, sig, endUser);

        // NFT delivered to endUser, not to the payer
        assertEq(assetNFT.ownerOf(tokenId), endUser);
        // endUser spent no USDC
        assertEq(usdc.balanceOf(endUser), 0);
        // payer (buyer) paid gross
        assertEq(usdc.balanceOf(buyer), payerBefore - gross);
        // fee distribution unchanged
        assertEq(usdc.balanceOf(treasury), treasBefore + collectibleFee);
        assertEq(usdc.balanceOf(royaltyReceiver), royaltyBefore + royalty);
        assertEq(usdc.balanceOf(seller), sellerBefore + sellerProceeds);
    }

    // =========================================================================
    // buyWithSignatureFor — private listing: recipient == listing.buyer succeeds
    // even when msg.sender (payer) is different
    // =========================================================================

    function test_buyWithSignatureFor_privateListing_recipientMatchesBuyer_succeeds()
        public
    {
        uint256 tokenId = 1;
        address endUser = makeAddr("endUser");

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        // Seller targets endUser as the intended recipient (private listing)
        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 1,
                expiry: block.timestamp + 1 hours,
                buyer: endUser
            });
        bytes memory sig = _signListing(l, sellerPk);

        // Platform (buyer) funds the purchase; endUser is the recipient
        // msg.sender != listing.buyer, but recipient == listing.buyer → must succeed
        vm.prank(buyer);
        market.buyWithSignatureFor(l, sig, endUser);

        assertEq(assetNFT.ownerOf(tokenId), endUser);
    }

    // =========================================================================
    // buyWithSignatureFor — private listing: wrong recipient reverts
    // =========================================================================

    function test_buyWithSignatureFor_privateListing_wrongRecipient_reverts()
        public
    {
        uint256 tokenId = 1;
        address endUser = makeAddr("endUser");
        address wrongRecipient = makeAddr("wrongRecipient");

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 1,
                expiry: block.timestamp + 1 hours,
                buyer: endUser
            });
        bytes memory sig = _signListing(l, sellerPk);

        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace.Marketplace__NotIntendedBuyer.selector,
                endUser,
                wrongRecipient
            )
        );
        market.buyWithSignatureFor(l, sig, wrongRecipient);
    }

    // =========================================================================
    // buyWithSignatureFor — zero recipient reverts
    // =========================================================================

    function test_buyWithSignatureFor_zeroRecipient_reverts() public {
        uint256 tokenId = 1;

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            SALE_PRICE,
            1
        );
        bytes memory sig = _signListing(l, sellerPk);

        vm.prank(buyer);
        vm.expectRevert(
            INettyWorthMarketplace.Marketplace__ZeroRecipient.selector
        );
        market.buyWithSignatureFor(l, sig, address(0));
    }

    // =========================================================================
    // buyWithSignatureFor — loan auto-repay branch: NFT delivered to recipient
    // =========================================================================

    function test_buyWithSignatureFor_loanAutoRepay_deliverToRecipient()
        public
    {
        uint256 tokenId = 1;
        uint256 loanAmount = 400e6;
        address endUser = makeAddr("endUser");

        vm.startPrank(seller);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, loanAmount, 0);
        vm.stopPrank();

        IAssetLendingPool.Loan memory loan = pool.getLoan(
            pool.getActiveLoanId(tokenId)
        );
        uint256 loanDebt = loan.principal + loan.interest;
        uint256 gross = (loanDebt * 10_000) / 8000 + 1e6; // comfortable margin above fees+debt

        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: gross,
                nonce: 1,
                expiry: block.timestamp + 1 hours,
                buyer: address(0)
            });
        bytes memory sig = _signListing(l, sellerPk);

        uint256 payerBefore = usdc.balanceOf(buyer);
        uint256 poolBefore = usdc.balanceOf(address(pool));

        // Platform (buyer) pays; endUser receives the NFT
        vm.prank(buyer);
        market.buyWithSignatureFor(l, sig, endUser);

        // NFT goes to endUser (not payer)
        assertEq(assetNFT.ownerOf(tokenId), endUser);
        assertEq(
            uint8(assetNFT.getAssetState(tokenId)),
            uint8(IAssetNFT.AssetState.Held)
        );
        // Loan cleared
        assertEq(pool.getActiveLoanId(tokenId), 0);
        // Payer (buyer) paid gross
        assertEq(usdc.balanceOf(buyer), payerBefore - gross);
        // endUser received no USDC
        assertEq(usdc.balanceOf(endUser), 0);
        // Pool received at least loanDebt
        assertGe(usdc.balanceOf(address(pool)), poolBefore + loanDebt);
    }

    // =========================================================================
    // buyWithSignature (legacy) — private listing backward compat:
    // listing.buyer == msg.sender still succeeds
    // =========================================================================

    function test_buyWithSignature_privateListing_callerIsIntendedBuyer_succeeds()
        public
    {
        uint256 tokenId = 1;

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        // Private listing targeted at buyer
        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 1,
                expiry: block.timestamp + 1 hours,
                buyer: buyer
            });
        bytes memory sig = _signListing(l, sellerPk);

        vm.prank(buyer);
        market.buyWithSignature(l, sig);

        // NFT goes to msg.sender == listing.buyer == buyer
        assertEq(assetNFT.ownerOf(tokenId), buyer);
    }

    // =========================================================================
    // buyWithSignature (legacy) — private listing backward compat:
    // wrong caller reverts NotIntendedBuyer
    // =========================================================================

    function test_buyWithSignature_privateListing_wrongCaller_reverts() public {
        uint256 tokenId = 1;

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        // Private listing: only buyer may fill
        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 1,
                expiry: block.timestamp + 1 hours,
                buyer: buyer
            });
        bytes memory sig = _signListing(l, sellerPk);

        // bidder tries to fill — not the intended recipient
        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace.Marketplace__NotIntendedBuyer.selector,
                buyer,
                bidder
            )
        );
        market.buyWithSignature(l, sig);
    }

    // =========================================================================
    // buyWithSignaturePushed (Coinflow onramp)
    // =========================================================================

    /// @dev Address for the Coinflow settler actor; granted COINFLOW_SETTLER_ROLE in each test.
    address internal coinflowSettler = makeAddr("coinflowSettler");

    /// @dev Grant COINFLOW_SETTLER_ROLE to coinflowSettler for tests that require it.
    modifier withSettlerRole() {
        vm.prank(admin);
        pm.grantRole(Roles.COINFLOW_SETTLER_ROLE, coinflowSettler);
        _;
    }

    // ----- helper: simulate Coinflow's "transfer then call" by pre-funding the marketplace -----
    function _fundMarket(uint256 amount) internal {
        usdc.mint(address(market), amount);
    }

    // ----- 1. Happy path: fee + royalty + seller proceeds correctly distributed -----
    function test_buyWithSignaturePushed_success() public withSettlerRole {
        uint256 tokenId = 1;
        address endUser = makeAddr("endUser");

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        uint256 gross = SALE_PRICE;
        uint256 collectibleFee = (gross * 500) / 10_000; // 5%
        uint256 royalty = (gross * 500) / 10_000; // 5% from ERC-2981
        uint256 sellerProceeds = gross - collectibleFee - royalty;

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            gross,
            10
        );
        bytes memory sig = _signListing(l, sellerPk);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 royaltyBefore = usdc.balanceOf(royaltyReceiver);
        uint256 sellerBefore = usdc.balanceOf(seller);

        // Coinflow transfers USDC to marketplace, then calls the function
        _fundMarket(gross);

        vm.expectEmit(true, true, true, true, address(market));
        emit INettyWorthMarketplace.PushedSaleSettled(
            seller,
            endUser,
            tokenId,
            gross
        );

        vm.prank(coinflowSettler);
        market.buyWithSignaturePushed(l, sig, endUser);

        // NFT delivered to endUser, not to seller or settler
        assertEq(assetNFT.ownerOf(tokenId), endUser);
        // endUser has no USDC
        assertEq(usdc.balanceOf(endUser), 0);
        // coinflowSettler has no USDC
        assertEq(usdc.balanceOf(coinflowSettler), 0);
        // Fees distributed
        assertEq(usdc.balanceOf(treasury), treasuryBefore + collectibleFee);
        assertEq(
            usdc.balanceOf(royaltyReceiver),
            royaltyBefore + royalty
        );
        assertEq(usdc.balanceOf(seller), sellerBefore + sellerProceeds);
        // Market balance drained to zero (no surplus)
        assertEq(usdc.balanceOf(address(market)), 0);
    }

    // ----- 2. CRITICAL: unauthorized caller reverts even if market has balance -----
    function test_buyWithSignaturePushed_revertUnauthorizedCaller()
        public
    {
        uint256 tokenId = 1;

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            SALE_PRICE,
            10
        );
        bytes memory sig = _signListing(l, sellerPk);

        // Pre-fund so it isn't a balance failure
        _fundMarket(SALE_PRICE);

        // No COINFLOW_SETTLER_ROLE granted — must revert
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                // PermissionConsumer emits this error
                bytes4(
                    keccak256(
                        "PermissionConsumer__Unauthorized(address,bytes32)"
                    )
                ),
                unauthorized,
                Roles.COINFLOW_SETTLER_ROLE
            )
        );
        market.buyWithSignaturePushed(l, sig, buyer);
    }

    // ----- 3. Insufficient balance reverts with the dedicated error -----
    function test_buyWithSignaturePushed_revertInsufficientBalance()
        public
        withSettlerRole
    {
        uint256 tokenId = 1;

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        uint256 gross = SALE_PRICE;
        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            gross,
            10
        );
        bytes memory sig = _signListing(l, sellerPk);

        // Fund one less than required
        _fundMarket(gross - 1);

        vm.prank(coinflowSettler);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace
                    .Marketplace__InsufficientPushedBalance
                    .selector,
                gross,
                gross - 1
            )
        );
        market.buyWithSignaturePushed(l, sig, buyer);
    }

    // ----- 4. Zero recipient reverts -----
    function test_buyWithSignaturePushed_zeroRecipient_reverts()
        public
        withSettlerRole
    {
        uint256 tokenId = 1;

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            SALE_PRICE,
            10
        );
        bytes memory sig = _signListing(l, sellerPk);
        _fundMarket(SALE_PRICE);

        vm.prank(coinflowSettler);
        vm.expectRevert(
            INettyWorthMarketplace.Marketplace__ZeroRecipient.selector
        );
        market.buyWithSignaturePushed(l, sig, address(0));
    }

    // ----- 5. Private listing: recipient must match listing.buyer -----
    function test_buyWithSignaturePushed_privateListing_recipientMatches()
        public
        withSettlerRole
    {
        uint256 tokenId = 1;
        address endUser = makeAddr("endUser");

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 10,
                expiry: block.timestamp + 1 hours,
                buyer: endUser // private listing
            });
        bytes memory sig = _signListing(l, sellerPk);
        _fundMarket(SALE_PRICE);

        vm.prank(coinflowSettler);
        market.buyWithSignaturePushed(l, sig, endUser);

        assertEq(assetNFT.ownerOf(tokenId), endUser);
    }

    function test_buyWithSignaturePushed_privateListing_wrongRecipient_reverts()
        public
        withSettlerRole
    {
        uint256 tokenId = 1;
        address endUser = makeAddr("endUser");
        address wrongUser = makeAddr("wrongUser");

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: SALE_PRICE,
                nonce: 10,
                expiry: block.timestamp + 1 hours,
                buyer: endUser // private: only endUser may receive
            });
        bytes memory sig = _signListing(l, sellerPk);
        _fundMarket(SALE_PRICE);

        vm.prank(coinflowSettler);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace
                    .Marketplace__NotIntendedBuyer
                    .selector,
                endUser,
                wrongUser
            )
        );
        market.buyWithSignaturePushed(l, sig, wrongUser);
    }

    // ----- 6. Reverts when paused -----
    function test_buyWithSignaturePushed_revertWhenPaused()
        public
        withSettlerRole
    {
        uint256 tokenId = 1;

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            SALE_PRICE,
            10
        );
        bytes memory sig = _signListing(l, sellerPk);
        _fundMarket(SALE_PRICE);

        // Pause the market (admin has PAUSER_ROLE via default admin)
        vm.prank(admin);
        pm.grantRole(Roles.PAUSER_ROLE, admin);
        vm.prank(admin);
        market.pause();

        vm.prank(coinflowSettler);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("EnforcedPause()"))
            )
        );
        market.buyWithSignaturePushed(l, sig, buyer);
    }

    // ----- 7. Nonce replay reverts -----
    function test_buyWithSignaturePushed_revertNonceReplay()
        public
        withSettlerRole
    {
        uint256 tokenId = 1;

        vm.prank(seller);
        assetNFT.setApprovalForAll(address(market), true);

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            SALE_PRICE,
            10
        );
        bytes memory sig = _signListing(l, sellerPk);

        // First purchase succeeds
        _fundMarket(SALE_PRICE);
        vm.prank(coinflowSettler);
        market.buyWithSignaturePushed(l, sig, buyer);

        // Transfer NFT back so the second attempt wouldn't fail on NFT ownership
        vm.prank(buyer);
        assetNFT.transferFrom(buyer, seller, tokenId);

        // Replay must revert
        _fundMarket(SALE_PRICE);
        vm.prank(coinflowSettler);
        vm.expectRevert(
            abi.encodeWithSelector(
                INettyWorthMarketplace.Marketplace__NonceUsed.selector,
                seller,
                uint256(10)
            )
        );
        market.buyWithSignaturePushed(l, sig, buyer);
    }

    // ----- 8. Surplus balance left in contract -----
    function test_buyWithSignaturePushed_surplusLeftInContract()
        public
        withSettlerRole
    {
        uint256 tokenId = 1;
        address endUser = makeAddr("endUser");

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        uint256 gross = SALE_PRICE;
        uint256 surplus = 123e6;

        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            gross,
            10
        );
        bytes memory sig = _signListing(l, sellerPk);

        // Coinflow over-delivers
        _fundMarket(gross + surplus);

        vm.prank(coinflowSettler);
        market.buyWithSignaturePushed(l, sig, endUser);

        // Exactly `gross` distributed; surplus stays in the contract
        assertEq(usdc.balanceOf(address(market)), surplus);
        assertEq(assetNFT.ownerOf(tokenId), endUser);
    }

    // ----- 9. Loan auto-repay via push -----
    function test_buyWithSignaturePushed_loanAutoRepay()
        public
        withSettlerRole
    {
        uint256 tokenId = 1;
        address endUser = makeAddr("endUser");

        // seller takes a loan against token 1 (same pattern as other loan tests)
        vm.startPrank(seller);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, 400e6, 0); // 400 USDC, term 0
        vm.stopPrank();

        // Confirm token is now held as collateral (not in seller's wallet)
        (, , uint256 loanDebt) = pool.getLoanDebt(tokenId);
        assertGt(loanDebt, 0);

        // Create a listing at a price that covers the loan + fees
        uint256 gross = 700e6; // enough to cover loan + 5% fee + 5% royalty
        INettyWorthMarketplace.SignedListing memory l = INettyWorthMarketplace
            .SignedListing({
                seller: seller,
                collection: address(assetNFT),
                tokenId: tokenId,
                paymentToken: address(usdc),
                price: gross,
                nonce: 20,
                expiry: block.timestamp + 1 hours,
                buyer: address(0)
            });
        bytes memory sig = _signListing(l, sellerPk);

        _fundMarket(gross);

        vm.prank(coinflowSettler);
        market.buyWithSignaturePushed(l, sig, endUser);

        // NFT delivered to endUser
        assertEq(assetNFT.ownerOf(tokenId), endUser);
        // Loan cleared
        assertEq(pool.getActiveLoanId(tokenId), 0);
    }

    // ----- 10. Regression: existing pull path unchanged after _executeSale refactor -----
    function test_buyWithSignature_regression_afterRefactor() public {
        uint256 tokenId = 2; // use token 2 to avoid tokenId conflict with other tests
        address endUser = makeAddr("endUser2");

        vm.prank(seller);
        assetNFT.approve(address(market), tokenId);

        uint256 gross = SALE_PRICE;
        INettyWorthMarketplace.SignedListing memory l = _defaultListing(
            tokenId,
            gross,
            99
        );
        bytes memory sig = _signListing(l, sellerPk);

        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        market.buyWithSignature(l, sig);

        // NFT to buyer, USDC pulled from buyer
        assertEq(assetNFT.ownerOf(tokenId), buyer);
        assertEq(usdc.balanceOf(buyer), buyerBefore - gross);
        // Market has no USDC balance after distribution
        assertEq(usdc.balanceOf(address(market)), 0);
    }
}
