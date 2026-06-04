// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AssetLendingPool} from "../AssetLendingPool.sol";
import {IAssetLendingPool} from "../interfaces/IAssetLendingPool.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {Roles} from "../lib/Roles.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

// Minimal mock PackMachine: accepts depositFromPool and pulls the NFT.
contract MockPackMachine {
    address public assetNFT;

    constructor(address nft) {
        assetNFT = nft;
    }

    function depositFromPool(
        uint256[] calldata tokenIds,
        uint8[] calldata,
        address tokensOwner
    ) external {
        for (uint256 i; i < tokenIds.length; i++) {
            IERC721(assetNFT).transferFrom(
                tokensOwner,
                address(this),
                tokenIds[i]
            );
        }
    }
}

// Minimal mock PackMachineFactory: whitelist-based isPackMachine.
contract MockPackMachineFactory {
    mapping(address => bool) private _machines;

    function register(address machine) external {
        _machines[machine] = true;
    }

    function isPackMachine(address machine) external view returns (bool) {
        return _machines[machine];
    }
}

contract AssetLendingPoolTest is Test {
    AssetLendingPool internal pool;
    AssetNFT internal assetNFT;
    PermissionManager internal pm;
    MockERC20 internal usdc;
    MockPackMachine internal mockMachine;
    MockPackMachineFactory internal mockFactory;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal forwarder = makeAddr("forwarder");
    address internal borrower = makeAddr("borrower");
    address internal seller = makeAddr("seller");
    address internal unauthorized = makeAddr("unauthorized");
    address internal lender1 = makeAddr("lender1");
    address internal lender2 = makeAddr("lender2");

    // Default appraisal values
    uint256 internal constant APPRAISAL_VALUE = 1000e6; // 1000 USDC
    uint256 internal constant MAX_LOAN = 500e6; // 50% LTV
    uint256 internal constant LTV_BPS = 5000; // 50%
    uint256 internal constant POOL_SEED = 10_000e6; // 10k USDC

    function setUp() public {
        // PermissionManager
        PermissionManager pmImpl = new PermissionManager();
        ERC1967Proxy pmProxy = new ERC1967Proxy(
            address(pmImpl),
            abi.encodeCall(PermissionManager.initialize, (admin))
        );
        pm = PermissionManager(address(pmProxy));

        vm.startPrank(admin);
        pm.grantRole(pm.MINTER_ROLE(), minter);
        vm.stopPrank();

        // USDC mock
        usdc = new MockERC20();

        // AssetNFT
        AssetNFT assetNFTImpl = new AssetNFT(forwarder);
        ERC1967Proxy assetNFTProxy = new ERC1967Proxy(
            address(assetNFTImpl),
            abi.encodeCall(
                AssetNFT.initialize,
                (
                    address(pm),
                    "NettyWorth Assets",
                    "NWA",
                    "ipfs://contract",
                    makeAddr("royalty"),
                    250
                )
            )
        );
        assetNFT = AssetNFT(address(assetNFTProxy));

        // Deploy mock PackMachine infrastructure (needed for initialize)
        mockMachine = new MockPackMachine(address(assetNFT));
        mockFactory = new MockPackMachineFactory();
        mockFactory.register(address(mockMachine));

        // AssetLendingPool (24h acquisition window, 7d auction window, 80% lender share)
        AssetLendingPool poolImpl = new AssetLendingPool();
        ERC1967Proxy poolProxy = new ERC1967Proxy(
            address(poolImpl),
            abi.encodeCall(
                AssetLendingPool.initialize,
                (admin, address(usdc), address(assetNFT), LTV_BPS, 8000, 24 hours, 7 days, address(mockFactory))
            )
        );
        pool = AssetLendingPool(address(poolProxy));

        // Grant STATE_MANAGER_ROLE to pool so it can call batchSetAssetState
        vm.startPrank(admin);
        pm.grantRole(pm.STATE_MANAGER_ROLE(), address(pool));
        vm.stopPrank();

        // Fund the pool
        usdc.mint(admin, POOL_SEED);
        vm.startPrank(admin);
        usdc.approve(address(pool), POOL_SEED);
        pool.deposit(POOL_SEED);
        vm.stopPrank();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _mintNFT(address recipient) internal returns (uint256 tokenId) {
        tokenId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](1);
        string[] memory uris = new string[](1);
        recipients[0] = recipient;
        uris[0] = "";
        vm.prank(minter);
        assetNFT.batchMint(recipients, uris);
    }

    function _appraise(uint256 tokenId) internal {
        vm.prank(admin);
        pool.setAppraisal(tokenId, APPRAISAL_VALUE, 0, 0);
    }

    function _borrow(
        address user,
        uint256 tokenId,
        uint256 amount,
        uint8 termId
    ) internal returns (uint256 loanId) {
        vm.prank(user);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(user);
        pool.borrow(tokenId, amount, termId);
        loanId = pool
            .getLoan(
                pool.getBorrowerLoans(user)[
                    pool.getBorrowerLoans(user).length - 1
                ]
            )
            .loanId;
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    function test_Initialize_SetsOwner() public view {
        assertEq(pool.owner(), admin);
    }

    function test_Initialize_SetsLtvBps() public view {
        assertEq(pool.getPoolInfo().ltvBps, LTV_BPS);
    }

    function test_Initialize_DefaultTermsConfigured() public view {
        AssetLendingPool.TermConfig memory t0 = pool.getTermConfig(0);
        assertEq(t0.duration, 7 days);
        assertEq(t0.aprBps, 1000);
        assertTrue(t0.active);

        AssetLendingPool.TermConfig memory t1 = pool.getTermConfig(1);
        assertEq(t1.duration, 15 days);
        assertEq(t1.aprBps, 1500);
        assertTrue(t1.active);

        AssetLendingPool.TermConfig memory t2 = pool.getTermConfig(2);
        assertEq(t2.duration, 30 days);
        assertEq(t2.aprBps, 2000);
        assertTrue(t2.active);
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert();
        pool.initialize(admin, address(usdc), address(assetNFT), LTV_BPS, 8000, 24 hours, 7 days, address(mockFactory));
    }

    function test_Initialize_RevertsOnZeroAddress() public {
        AssetLendingPool impl = new AssetLendingPool();
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ZeroAddress.selector
        );
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                AssetLendingPool.initialize,
                (address(0), address(usdc), address(assetNFT), LTV_BPS, 8000, 24 hours, 7 days, address(mockFactory))
            )
        );
    }

    function test_Initialize_RevertsOnInvalidLTV() public {
        AssetLendingPool impl = new AssetLendingPool();
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InvalidLTV.selector
        );
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                AssetLendingPool.initialize,
                (admin, address(usdc), address(assetNFT), 0, 8000, 24 hours, 7 days, address(mockFactory))
            )
        );
    }

    // =========================================================================
    // Pool funding
    // =========================================================================

    function test_Deposit_IncreasesTotalDeposited() public {
        uint256 before = pool.getPoolInfo().totalDeposited;
        usdc.mint(admin, 100e6);
        vm.startPrank(admin);
        usdc.approve(address(pool), 100e6);
        pool.deposit(100e6);
        vm.stopPrank();
        assertEq(pool.getPoolInfo().totalDeposited, before + 100e6);
    }

    function test_Deposit_OnlyOwner() public {
        usdc.mint(unauthorized, 100e6);
        vm.startPrank(unauthorized);
        usdc.approve(address(pool), 100e6);
        vm.expectRevert();
        pool.deposit(100e6);
        vm.stopPrank();
    }

    function test_Withdraw_DecreasesTotalDeposited() public {
        uint256 before = pool.getPoolInfo().totalDeposited;
        vm.prank(admin);
        pool.withdraw(100e6);
        assertEq(pool.getPoolInfo().totalDeposited, before - 100e6);
    }

    function test_Withdraw_RevertsIfExceedsOwnerDeposits() public {
        vm.expectRevert(
            IAssetLendingPool
                .AssetLendingPool__OwnerWithdrawExceedsOwnerDeposits
                .selector
        );
        vm.prank(admin);
        pool.withdraw(POOL_SEED + 1);
    }

    function test_Withdraw_RevertsIfExceedsAvailableLiquidity() public {
        // Borrow most of the pool so available < ownerDeposited
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, POOL_SEED * 3, 0, 0);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, POOL_SEED - 1e6, 0); // almost all liquidity borrowed

        vm.expectRevert(
            IAssetLendingPool
                .AssetLendingPool__WithdrawExceedsAvailable
                .selector
        );
        vm.prank(admin);
        pool.withdraw(2e6); // 2 USDC not available
    }

    // =========================================================================
    // Appraisals
    // =========================================================================

    function test_SetAppraisal_StoresValues() public {
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, 500e6, 8, 1);

        AssetLendingPool.AssetAppraisal memory a = pool.getAppraisal(tokenId);
        assertEq(a.value, 500e6);
        assertEq(a.grade, 8);
        assertEq(a.category, 1);
        assertGt(a.updatedAt, 0);
    }

    function test_SetAppraisal_OnlyOwner() public {
        uint256 tokenId = _mintNFT(borrower);
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setAppraisal(tokenId, 500e6, 8, 1);
    }

    function test_BatchSetAppraisals_Works() public {
        uint256 t1 = _mintNFT(borrower);
        uint256 t2 = _mintNFT(borrower);
        uint256[] memory ids = new uint256[](2);
        uint256[] memory vals = new uint256[](2);
        uint256[] memory grades = new uint256[](2);
        uint256[] memory cats = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;
        vals[0] = 100e6;
        vals[1] = 200e6;
        grades[0] = 5;
        grades[1] = 7;
        cats[0] = 0;
        cats[1] = 0;

        vm.prank(admin);
        pool.batchSetAppraisals(ids, vals, grades, cats);

        assertEq(pool.getAppraisal(t1).value, 100e6);
        assertEq(pool.getAppraisal(t2).value, 200e6);
    }

    function test_BatchSetAppraisals_RevertsIfTooLarge() public {
        uint256[] memory ids = new uint256[](51);
        uint256[] memory vals = new uint256[](51);
        uint256[] memory grades = new uint256[](51);
        uint256[] memory cats = new uint256[](51);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetLendingPool.AssetLendingPool__BatchTooLarge.selector,
                51,
                50
            )
        );
        vm.prank(admin);
        pool.batchSetAppraisals(ids, vals, grades, cats);
    }

    // =========================================================================
    // borrow — happy path
    // =========================================================================

    function test_Borrow_HappyPath_7Day() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);

        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);

        uint256 borrowAmount = 400e6;
        uint256 balBefore = usdc.balanceOf(borrower);

        vm.prank(borrower);
        pool.borrow(tokenId, borrowAmount, 0);

        // NFT transferred to pool, state = Loaned
        assertEq(assetNFT.ownerOf(tokenId), address(pool));
        assertEq(
            uint8(assetNFT.getAssetState(tokenId)),
            uint8(AssetNFT.AssetState.Loaned)
        );

        // Borrower received principal
        assertEq(usdc.balanceOf(borrower), balBefore + borrowAmount);

        // Loan recorded
        uint256[] memory loanIds = pool.getBorrowerLoans(borrower);
        assertEq(loanIds.length, 1);
        AssetLendingPool.Loan memory loan = pool.getLoan(loanIds[0]);
        assertEq(loan.borrower, borrower);
        assertEq(loan.tokenIds[0], tokenId);
        assertEq(loan.principal, borrowAmount);
        assertEq(
            loan.interest,
            (borrowAmount * 1000 * 7 days) / (365 days * 10_000)
        ); // 10% APR × 7d
        assertEq(loan.termId, 0);
        assertFalse(loan.isPaid);
        assertFalse(loan.isDefaulted);
    }

    function test_Borrow_HappyPath_AllThreeTerms() public {
        for (uint8 i; i < 3; i++) {
            uint256 tokenId = _mintNFT(borrower);
            _appraise(tokenId);
            vm.prank(borrower);
            assetNFT.approve(address(pool), tokenId);
            vm.prank(borrower);
            pool.borrow(tokenId, 100e6, i);
            AssetLendingPool.Loan memory loan = pool.getLoan(
                pool.getBorrowerLoans(borrower)[i]
            );
            assertEq(loan.termId, i);
        }
    }

    // =========================================================================
    // borrow — reverts
    // =========================================================================

    function test_Borrow_RevertsIfInvalidTerm() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InvalidTerm.selector
        );
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 99);
    }

    function test_Borrow_RevertsIfNoAppraisal() public {
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__NoAppraisal.selector
        );
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 0);
    }

    function test_Borrow_RevertsIfExceedsLTV() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId); // appraisal = 1000 USDC, max = 500
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ExceedsLTV.selector
        );
        vm.prank(borrower);
        pool.borrow(tokenId, 501e6, 0);
    }

    function test_Borrow_RevertsIfInsufficientLiquidity() public {
        // Drain all liquidity first by borrowing several tokens
        uint256 poolLiquidity = pool.getAvailableLiquidity();

        // Borrow a big amount close to pool capacity
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, poolLiquidity * 3, 0, 0); // high appraisal
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, poolLiquidity, 0); // borrow full pool

        // Now try to borrow again
        uint256 tokenId2 = _mintNFT(borrower);
        _appraise(tokenId2);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId2);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InsufficientLiquidity.selector
        );
        vm.prank(borrower);
        pool.borrow(tokenId2, 100e6, 0);
    }

    function test_Borrow_RevertsIfActiveLoanExists() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 0);

        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ActiveLoanExists.selector
        );
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 0);
    }

    function test_Borrow_RevertsIfIneligible_BelowMinGrade() public {
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, APPRAISAL_VALUE, 5, 0);

        // Set minimum grade to 7
        uint256[] memory add = new uint256[](0);
        uint256[] memory rem = new uint256[](0);
        vm.prank(admin);
        pool.setEligibilityControls(0, 7, add, rem);

        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__IneligibleAsset.selector
        );
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 0);
    }

    function test_Borrow_RevertsIfPaused() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(admin);
        pool.pause();
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert();
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 0);
    }

    function test_Borrow_RevertsIfZeroAmount() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ZeroAmount.selector
        );
        vm.prank(borrower);
        pool.borrow(tokenId, 0, 0);
    }

    // =========================================================================
    // repay
    // =========================================================================

    function test_Repay_HappyPath() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 400e6, 0);

        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        AssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        uint256 repayAmount = loan.principal + loan.interest; // 400 + 40 = 440 USDC

        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanId);
        vm.stopPrank();

        // NFT returned to borrower, state = Held
        assertEq(assetNFT.ownerOf(tokenId), borrower);
        assertEq(
            uint8(assetNFT.getAssetState(tokenId)),
            uint8(AssetNFT.AssetState.Held)
        );

        // Loan marked paid
        assertTrue(pool.getLoan(loanId).isPaid);

        // Interest tracked
        assertEq(pool.getPoolInfo().totalInterestEarned, loan.interest);
    }

    function test_Repay_AllowedAfterExpiry() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 400e6, 0);

        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        AssetLendingPool.Loan memory loan = pool.getLoan(loanId);

        // Warp past expiry
        vm.warp(loan.expireTime + 1 days);

        uint256 repayAmount = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanId);
        vm.stopPrank();

        assertTrue(pool.getLoan(loanId).isPaid);
    }

    function test_Repay_RevertsIfAlreadyPaid() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 400e6, 0);

        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        AssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        uint256 repayAmount = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount * 2);
        pool.repay(loanId);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__LoanAlreadyPaid.selector
        );
        pool.repay(loanId);
        vm.stopPrank();
    }

    function test_Repay_RevertsIfNotBorrower() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 400e6, 0);
        uint256 loanId = pool.getBorrowerLoans(borrower)[0];

        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__NotBorrower.selector
        );
        vm.prank(unauthorized);
        pool.repay(loanId);
    }

    function test_Repay_RevertsIfLoanNotFound() public {
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__LoanNotFound.selector
        );
        vm.prank(borrower);
        pool.repay(999);
    }

    // =========================================================================
    // liquidate
    // =========================================================================

    function test_Liquidate_HappyPath() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 400e6, 0);

        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        AssetLendingPool.Loan memory loan = pool.getLoan(loanId);

        vm.warp(loan.expireTime + 1);

        vm.prank(admin);
        pool.liquidate(loanId);

        // Loan marked defaulted
        assertTrue(pool.getLoan(loanId).isDefaulted);
        // NFT stays in pool, state = Held
        assertEq(assetNFT.ownerOf(tokenId), address(pool));
        assertEq(
            uint8(assetNFT.getAssetState(tokenId)),
            uint8(AssetNFT.AssetState.Held)
        );
    }

    function test_Liquidate_RevertsIfNotExpired() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 400e6, 0);
        uint256 loanId = pool.getBorrowerLoans(borrower)[0];

        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__LoanNotExpired.selector
        );
        vm.prank(admin);
        pool.liquidate(loanId);
    }

    function test_Liquidate_RevertsIfAlreadyPaid() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 400e6, 0);

        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        AssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        uint256 repayAmount = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanId);
        vm.stopPrank();

        vm.warp(loan.expireTime + 1);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__LoanAlreadyPaid.selector
        );
        vm.prank(admin);
        pool.liquidate(loanId);
    }

    function test_Liquidate_ReducesTotalDeposited() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);

        uint256 principal = 400e6;
        vm.prank(borrower);
        pool.borrow(tokenId, principal, 0);

        uint256 depositedBefore = pool.getPoolInfo().totalDeposited;
        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        vm.warp(pool.getLoan(loanId).expireTime + 1);

        vm.prank(admin);
        pool.liquidate(loanId);

        // Pool absorbed the loss: totalDeposited decreases by principal
        assertEq(
            pool.getPoolInfo().totalDeposited,
            depositedBefore - principal
        );
        // Available liquidity matches actual token balance
        assertEq(pool.getAvailableLiquidity(), usdc.balanceOf(address(pool)));
    }

    function test_Liquidate_OnlyOwner() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 400e6, 0);
        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        vm.warp(pool.getLoan(loanId).expireTime + 1);
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.liquidate(loanId);
    }

    function test_RescueNFT_MovesNFTToRecipient() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 400e6, 0);
        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        vm.warp(pool.getLoan(loanId).expireTime + 1);
        vm.prank(admin);
        pool.liquidate(loanId);

        address treasury = makeAddr("treasury");
        vm.prank(admin);
        pool.rescueNFT(tokenId, treasury);
        assertEq(assetNFT.ownerOf(tokenId), treasury);
    }

    // =========================================================================
    // financeMarketplacePurchase
    // =========================================================================

    function test_FinanceMarketplace_HappyPath() public {
        uint256 tokenId = _mintNFT(seller);
        _appraise(tokenId); // 1000 USDC

        // Seller approves pool
        vm.prank(seller);
        assetNFT.approve(address(pool), tokenId);

        // Buyer provides 50% deposit (500 USDC), pool loans 500 USDC
        uint256 depositAmount = 500e6;
        uint256 loanAmount = APPRAISAL_VALUE - depositAmount;

        usdc.mint(borrower, depositAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), depositAmount);
        vm.stopPrank();

        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(borrower);
        pool.financeMarketplacePurchase(tokenId, depositAmount, 0, seller);

        // Seller received full purchase price (500 deposit + 500 loan)
        assertEq(usdc.balanceOf(seller), sellerBefore + APPRAISAL_VALUE);
        // NFT in pool, Loaned state
        assertEq(assetNFT.ownerOf(tokenId), address(pool));
        assertEq(
            uint8(assetNFT.getAssetState(tokenId)),
            uint8(AssetNFT.AssetState.Loaned)
        );
        // Loan created for buyer
        uint256[] memory loanIds = pool.getBorrowerLoans(borrower);
        assertEq(loanIds.length, 1);
        assertEq(pool.getLoan(loanIds[0]).principal, loanAmount);
        assertTrue(pool.getLoan(loanIds[0]).isMarketplaceFinanced);
    }

    function test_FinanceMarketplace_RepayGivesNFTToBuyer() public {
        uint256 tokenId = _mintNFT(seller);
        _appraise(tokenId);
        vm.prank(seller);
        assetNFT.approve(address(pool), tokenId);
        uint256 depositAmount = 500e6;
        usdc.mint(borrower, depositAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), depositAmount);
        pool.financeMarketplacePurchase(tokenId, depositAmount, 0, seller);
        vm.stopPrank();

        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        AssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        uint256 repayAmount = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanId);
        vm.stopPrank();

        // NFT goes to buyer (borrower), not seller
        assertEq(assetNFT.ownerOf(tokenId), borrower);
    }

    function test_FinanceMarketplace_RevertsIfDepositTooLow() public {
        uint256 tokenId = _mintNFT(seller);
        _appraise(tokenId); // 1000 USDC, max loan = 500
        vm.prank(seller);
        assetNFT.approve(address(pool), tokenId);
        // Deposit only 400 USDC (below the 500 minimum)
        usdc.mint(borrower, 400e6);
        vm.startPrank(borrower);
        usdc.approve(address(pool), 400e6);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InsufficientDeposit.selector
        );
        pool.financeMarketplacePurchase(tokenId, 400e6, 0, seller);
        vm.stopPrank();
    }

    function test_FinanceMarketplace_RevertsIfInvalidTerm() public {
        uint256 tokenId = _mintNFT(seller);
        _appraise(tokenId);
        vm.prank(seller);
        assetNFT.approve(address(pool), tokenId);
        usdc.mint(borrower, 500e6);
        vm.startPrank(borrower);
        usdc.approve(address(pool), 500e6);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InvalidTerm.selector
        );
        pool.financeMarketplacePurchase(tokenId, 500e6, 99, seller);
        vm.stopPrank();
    }

    // =========================================================================
    // Interest withdrawal
    // =========================================================================

    function test_WithdrawInterest_AfterRepayment() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 400e6, 0);
        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        AssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        uint256 repayAmount = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanId);
        vm.stopPrank();

        uint256 earned = pool.getPoolInfo().totalInterestEarned;
        assertEq(earned, loan.interest);

        uint256 adminBefore = usdc.balanceOf(admin);
        vm.prank(admin);
        pool.withdrawInterest(earned);
        assertEq(usdc.balanceOf(admin), adminBefore + earned);
    }

    function test_WithdrawInterest_RevertsIfExceedsAvailable() public {
        vm.expectRevert(
            IAssetLendingPool
                .AssetLendingPool__WithdrawExceedsAvailable
                .selector
        );
        vm.prank(admin);
        pool.withdrawInterest(1);
    }

    // =========================================================================
    // Origination fee
    // =========================================================================

    function test_OriginationFee_DeductedFromDisbursement() public {
        address feeWallet = makeAddr("feeWallet");
        vm.prank(admin);
        pool.setOriginationFee(200, feeWallet); // 2%

        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);

        uint256 borrowAmount = 400e6;
        uint256 expectedFee = (borrowAmount * 200) / 10_000; // 8 USDC
        uint256 expectedDisbursement = borrowAmount - expectedFee;

        uint256 balBefore = usdc.balanceOf(borrower);
        vm.prank(borrower);
        pool.borrow(tokenId, borrowAmount, 0);

        assertEq(usdc.balanceOf(borrower), balBefore + expectedDisbursement);
        assertEq(usdc.balanceOf(feeWallet), expectedFee);
    }

    // =========================================================================
    // Term config
    // =========================================================================

    function test_SetTermConfig_UpdatesAndAddsTerms() public {
        vm.prank(admin);
        pool.setTermConfig(5, 60 days, 3000, true);
        AssetLendingPool.TermConfig memory t = pool.getTermConfig(5);
        assertEq(t.duration, 60 days);
        assertEq(t.aprBps, 3000);
        assertTrue(t.active);
        assertEq(pool.getPoolInfo().termCount, 6);
    }

    function test_SetTermConfig_DeactivatesTerm() public {
        vm.prank(admin);
        pool.setTermConfig(0, 7 days, 1000, false);
        assertFalse(pool.getTermConfig(0).active);

        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InvalidTerm.selector
        );
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 0);
    }

    // =========================================================================
    // View helpers
    // =========================================================================

    function test_GetMaxLoanAmount() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId); // 1000 USDC
        assertEq(pool.getMaxLoanAmount(tokenId), 500e6); // 50%
    }

    function test_IsEligible_TrueWhenAppraisalSet() public {
        uint256 tokenId = _mintNFT(borrower);
        assertFalse(pool.isEligible(tokenId));
        _appraise(tokenId);
        assertTrue(pool.isEligible(tokenId));
    }

    function test_GetAvailableLiquidity_DecreasesOnBorrow() public {
        uint256 before = pool.getAvailableLiquidity();
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 200e6, 0);
        assertEq(pool.getAvailableLiquidity(), before - 200e6);
    }

    // =========================================================================
    // UUPS upgrade
    // =========================================================================

    function test_AuthorizeUpgrade_OnlyOwner() public {
        AssetLendingPool newImpl = new AssetLendingPool();
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.upgradeToAndCall(address(newImpl), "");
    }

    // =========================================================================
    // Appraisal staleness
    // =========================================================================

    function test_Initialize_SetsDefaultMaxAppraisalAge() public view {
        assertEq(pool.getPoolInfo().maxAppraisalAge, 7 days);
    }

    function test_SetMaxAppraisalAge_UpdatesValue() public {
        vm.prank(admin);
        pool.setMaxAppraisalAge(14 days);
        assertEq(pool.getPoolInfo().maxAppraisalAge, 14 days);
    }

    function test_SetMaxAppraisalAge_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IAssetLendingPool.MaxAppraisalAgeUpdated(7 days, 14 days);
        vm.prank(admin);
        pool.setMaxAppraisalAge(14 days);
    }

    function test_SetMaxAppraisalAge_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setMaxAppraisalAge(14 days);
    }

    function test_Borrow_RevertsIfAppraisalStale() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        uint256 appraisedAt = pool.getAppraisal(tokenId).updatedAt;

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetLendingPool.AssetLendingPool__AppraisalStale.selector,
                tokenId,
                appraisedAt,
                7 days
            )
        );
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 0);
    }

    function test_Borrow_SucceedsAtExactMaxAge() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);

        vm.warp(block.timestamp + 7 days); // exactly at boundary — not stale

        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 0); // should not revert
    }

    function test_Borrow_SucceedsAfterAppraisalRefresh() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);

        vm.warp(block.timestamp + 7 days + 1); // now stale

        // Refresh appraisal
        _appraise(tokenId);

        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 0); // should not revert
    }

    function test_SetMaxAppraisalAge_ZeroDisablesCheck() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);

        vm.prank(admin);
        pool.setMaxAppraisalAge(0); // disable check

        vm.warp(block.timestamp + 365 days); // very stale

        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, 100e6, 0); // should not revert
    }

    function test_FinanceMarketplace_RevertsIfAppraisalStale() public {
        uint256 tokenId = _mintNFT(seller);
        _appraise(tokenId);
        uint256 appraisedAt = pool.getAppraisal(tokenId).updatedAt;

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(seller);
        assetNFT.approve(address(pool), tokenId);
        usdc.mint(borrower, 500e6);
        vm.startPrank(borrower);
        usdc.approve(address(pool), 500e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetLendingPool.AssetLendingPool__AppraisalStale.selector,
                tokenId,
                appraisedAt,
                7 days
            )
        );
        pool.financeMarketplacePurchase(tokenId, 500e6, 0, seller);
        vm.stopPrank();
    }

    function test_IsEligible_NotAffectedByStaleness() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);

        vm.warp(block.timestamp + 7 days + 1); // stale

        // isEligible is a view — staleness must NOT affect it
        assertTrue(pool.isEligible(tokenId));
    }

    // =========================================================================
    // Helpers (V2)
    // =========================================================================

    function _enableLenders() internal {
        vm.prank(admin);
        pool.setLenderConfig(8000, true); // already set in initializeV2 but enable deposits
    }

    /// @dev Mints `amount` USDC to `lender` and deposits it into the pool.
    function _lenderDeposit(address lender, uint256 amount) internal {
        usdc.mint(lender, amount);
        vm.startPrank(lender);
        usdc.approve(address(pool), amount);
        pool.lenderDeposit(amount);
        vm.stopPrank();
    }

    /// @dev Originates a loan for `borrower` and immediately repays it, realizing
    ///      its fixed interest into the distribution accumulator. Returns the loan.
    function _borrowAndRepay(
        uint256 principal,
        uint8 termId
    ) internal returns (IAssetLendingPool.Loan memory loan) {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        uint256 loanId = _borrow(borrower, tokenId, principal, termId);
        loan = pool.getLoan(loanId);

        uint256 repayAmount = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanId);
        vm.stopPrank();
    }

    /// @dev Creates an active loan and warps past its expiry, then calls initiateDefault.
    function _createDefaultedLoan(
        uint256 principal
    ) internal returns (uint256 loanId, uint256 tokenId) {
        tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        loanId = _borrow(borrower, tokenId, principal, 0);
        vm.warp(pool.getLoan(loanId).expireTime + 1);
        vm.prank(admin);
        pool.initiateDefault(loanId);
    }

    // =========================================================================
    // initializeV2
    // =========================================================================

    function test_Initialize_SetsLenderShareBps() public view {
        assertEq(pool.getPoolInfo().lenderShareBps, 8000);
    }

    function test_Initialize_SetsAcquisitionWindow() public view {
        assertEq(pool.getPoolInfo().acquisitionWindow, 24 hours);
    }

    function test_Initialize_SetsAuctionWindow() public view {
        assertEq(pool.getPoolInfo().auctionWindow, 7 days);
    }

    // =========================================================================
    // Lender: deposit
    // =========================================================================

    function test_LenderDeposit_IncreasesBalances() public {
        _enableLenders();
        usdc.mint(lender1, 1000e6);
        vm.startPrank(lender1);
        usdc.approve(address(pool), 1000e6);
        pool.lenderDeposit(1000e6);
        vm.stopPrank();

        assertEq(pool.getLenderInfo(lender1).deposited, 1000e6);
        assertEq(pool.getPoolInfo().totalLenderDeposits, 1000e6);
        assertEq(pool.getPoolInfo().totalDeposited, POOL_SEED + 1000e6);
    }

    function test_LenderDeposit_RevertsIfDisabled() public {
        // lenderDepositsEnabled = false by default after initializeV2 (enable not called)
        vm.prank(admin);
        pool.setLenderConfig(8000, false);

        usdc.mint(lender1, 1000e6);
        vm.startPrank(lender1);
        usdc.approve(address(pool), 1000e6);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__LenderDepositsDisabled.selector
        );
        pool.lenderDeposit(1000e6);
        vm.stopPrank();
    }

    function test_LenderDeposit_RevertsIfZeroAmount() public {
        _enableLenders();
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ZeroAmount.selector
        );
        vm.prank(lender1);
        pool.lenderDeposit(0);
    }

    // =========================================================================
    // Lender: withdraw
    // =========================================================================

    function test_LenderWithdraw_DecreasesBalances() public {
        _enableLenders();
        usdc.mint(lender1, 1000e6);
        vm.startPrank(lender1);
        usdc.approve(address(pool), 1000e6);
        pool.lenderDeposit(1000e6);
        pool.lenderWithdraw(600e6);
        vm.stopPrank();

        assertEq(pool.getLenderInfo(lender1).deposited, 400e6);
        assertEq(pool.getPoolInfo().totalLenderDeposits, 400e6);
        assertEq(pool.getPoolInfo().totalDeposited, POOL_SEED + 400e6);
    }

    function test_LenderWithdraw_RevertsIfExceedsDeposit() public {
        _enableLenders();
        usdc.mint(lender1, 100e6);
        vm.startPrank(lender1);
        usdc.approve(address(pool), 100e6);
        pool.lenderDeposit(100e6);
        vm.expectRevert(
            IAssetLendingPool
                .AssetLendingPool__InsufficientLenderBalance
                .selector
        );
        pool.lenderWithdraw(200e6);
        vm.stopPrank();
    }

    function test_LenderWithdraw_RevertsIfCapitalLocked() public {
        _enableLenders();
        // Lender deposits 1000
        usdc.mint(lender1, 1000e6);
        vm.startPrank(lender1);
        usdc.approve(address(pool), 1000e6);
        pool.lenderDeposit(1000e6);
        vm.stopPrank();

        // Borrow 10k (almost all of owner's capital) + lender's 1000 → pool is depleted
        uint256 tokenId = _mintNFT(borrower);
        uint256 bigAppraisal = POOL_SEED + 1000e6;
        vm.prank(admin);
        pool.setAppraisal(tokenId, bigAppraisal * 3, 0, 0);
        vm.prank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.prank(borrower);
        pool.borrow(tokenId, bigAppraisal, 0); // borrow all available

        // Lender can't withdraw: no available liquidity
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InsufficientLiquidity.selector
        );
        vm.prank(lender1);
        pool.lenderWithdraw(1000e6);
    }

    // =========================================================================
    // Lender: interest accrual (reward-per-share)
    // =========================================================================

    function test_LenderInterest_EarnedOnRepay() public {
        _enableLenders();
        // Lender deposits 10k (equal to pool seed)
        usdc.mint(lender1, POOL_SEED);
        vm.startPrank(lender1);
        usdc.approve(address(pool), POOL_SEED);
        pool.lenderDeposit(POOL_SEED);
        vm.stopPrank();

        // Borrow and repay
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId); // 1000 USDC
        uint256 loanId = _borrow(borrower, tokenId, 400e6, 0);
        AssetLendingPool.Loan memory loan = pool.getLoan(loanId);

        uint256 repayAmount = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanId);
        vm.stopPrank();

        // Lender should have earned 80% of interest
        uint256 expectedLenderInterest = (loan.interest * 8000) / 10_000;
        assertEq(
            pool.getLenderInfo(lender1).claimableInterest,
            expectedLenderInterest
        );
        // Protocol should have earned 20%
        assertEq(
            pool.getPoolInfo().totalInterestEarned,
            loan.interest - expectedLenderInterest
        );
    }

    function test_LenderInterest_ClaimTransfersFunds() public {
        _enableLenders();
        usdc.mint(lender1, POOL_SEED);
        vm.startPrank(lender1);
        usdc.approve(address(pool), POOL_SEED);
        pool.lenderDeposit(POOL_SEED);
        vm.stopPrank();

        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        uint256 loanId = _borrow(borrower, tokenId, 400e6, 0);
        AssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        uint256 repayAmount = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanId);
        vm.stopPrank();

        uint256 lender1Before = usdc.balanceOf(lender1);
        uint256 claimable = pool.getLenderInfo(lender1).claimableInterest;
        assertGt(claimable, 0);

        vm.prank(lender1);
        pool.claimLenderInterest();

        assertEq(usdc.balanceOf(lender1), lender1Before + claimable);
        assertEq(pool.getLenderInfo(lender1).claimableInterest, 0);
    }

    function test_LenderInterest_TwoLendersProRata() public {
        _enableLenders();
        // lender1: 3000, lender2: 1000 → 75% / 25% split
        usdc.mint(lender1, 3000e6);
        usdc.mint(lender2, 1000e6);
        vm.startPrank(lender1);
        usdc.approve(address(pool), 3000e6);
        pool.lenderDeposit(3000e6);
        vm.stopPrank();
        vm.startPrank(lender2);
        usdc.approve(address(pool), 1000e6);
        pool.lenderDeposit(1000e6);
        vm.stopPrank();

        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);
        uint256 loanId = _borrow(borrower, tokenId, 400e6, 0);
        AssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        uint256 repayAmount = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanId);
        vm.stopPrank();

        uint256 totalLenderInterest = (loan.interest * 8000) / 10_000;
        uint256 lender1Claimable = pool.getLenderInfo(lender1).claimableInterest;
        uint256 lender2Claimable = pool.getLenderInfo(lender2).claimableInterest;

        // lender1 gets 75%, lender2 gets 25%
        assertApproxEqAbs(lender1Claimable, (totalLenderInterest * 3) / 4, 1);
        assertApproxEqAbs(lender2Claimable, totalLenderInterest / 4, 1);
        assertApproxEqAbs(
            lender1Claimable + lender2Claimable,
            totalLenderInterest,
            1
        );
    }

    function test_LenderInterest_NoInterestBeforeRepay() public {
        _enableLenders();
        usdc.mint(lender1, 1000e6);
        vm.startPrank(lender1);
        usdc.approve(address(pool), 1000e6);
        pool.lenderDeposit(1000e6);
        vm.stopPrank();

        assertEq(pool.getLenderInfo(lender1).claimableInterest, 0);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__NoInterestToClaim.selector
        );
        vm.prank(lender1);
        pool.claimLenderInterest();
    }

    // =========================================================================
    // Lender: pro-rata distribution — requirement worked example
    // =========================================================================

    /// @dev Mirrors the requirement's 5-lender example exactly:
    ///      Deposits A=50, B=100, C=250, D=600, E=1000 (total 2000); a 100 loan
    ///      pays 20 interest; NettyWorth keeps 10% (lenderShareBps=9000) → 18 to
    ///      lenders, split pro-rata: 0.45 / 0.90 / 2.25 / 5.40 / 9.00.
    function test_LenderInterest_FiveLenderProRata_RequirementExample() public {
        // 90% to lenders so the protocol fee on 20 interest is exactly 2.
        vm.prank(admin);
        pool.setLenderConfig(9000, true);

        // Owner seed would otherwise co-fund loans and earn nothing (it isn't a
        // lender); withdraw it so totalLenderDeposits == total pool capital and
        // the shares match the requirement table exactly.
        vm.prank(admin);
        pool.withdraw(POOL_SEED);

        address lA = makeAddr("lenderA");
        address lB = makeAddr("lenderB");
        address lC = makeAddr("lenderC");
        address lD = makeAddr("lenderD");
        address lE = makeAddr("lenderE");

        _lenderDeposit(lA, 50e6);
        _lenderDeposit(lB, 100e6);
        _lenderDeposit(lC, 250e6);
        _lenderDeposit(lD, 600e6);
        _lenderDeposit(lE, 1000e6);

        assertEq(pool.getPoolInfo().totalLenderDeposits, 2000e6);

        // A 100 loan whose fixed interest is exactly 20 (20% over the term).
        // Term 2 = 30d @ 20% APR → interest = 100 * 2000 * 30d / (365d*1e4),
        // which is not exactly 20, so set a custom term of 365d @ 20% APR.
        vm.prank(admin);
        pool.setTermConfig(3, 365 days, 2000, true); // 20% over exactly one year

        IAssetLendingPool.Loan memory loan = _borrowAndRepay(100e6, 3);
        assertEq(loan.interest, 20e6); // sanity: interest is exactly $20

        // Protocol fee = 10% of 20 = 2; lenders share 18.
        assertEq(pool.getPoolInfo().totalInterestEarned, 2e6);

        // Pro-rata earnings per the requirement table (1 wei tolerance for the
        // per-share truncation).
        assertApproxEqAbs(pool.getLenderInfo(lA).claimableInterest, 0.45e6, 1);
        assertApproxEqAbs(pool.getLenderInfo(lB).claimableInterest, 0.90e6, 1);
        assertApproxEqAbs(pool.getLenderInfo(lC).claimableInterest, 2.25e6, 1);
        assertApproxEqAbs(pool.getLenderInfo(lD).claimableInterest, 5.40e6, 1);
        assertApproxEqAbs(pool.getLenderInfo(lE).claimableInterest, 9.00e6, 1);

        // The five shares sum to the full 18 lender portion.
        uint256 sum = pool.getLenderInfo(lA).claimableInterest +
            pool.getLenderInfo(lB).claimableInterest +
            pool.getLenderInfo(lC).claimableInterest +
            pool.getLenderInfo(lD).claimableInterest +
            pool.getLenderInfo(lE).claimableInterest;
        assertApproxEqAbs(sum, 18e6, 5);
    }

    /// @dev A lender who deposits AFTER interest is already distributed must not
    ///      retroactively capture that past interest (reward-debt seeding).
    function test_LenderInterest_LateDepositorEarnsNoPastInterest() public {
        _enableLenders();
        _lenderDeposit(lender1, 1000e6);

        // First loan repaid — interest distributed to lender1 only.
        _borrowAndRepay(400e6, 0);
        uint256 lender1AfterFirst = pool
            .getLenderInfo(lender1)
            .claimableInterest;
        assertGt(lender1AfterFirst, 0);

        // lender2 arrives only now, equal size.
        _lenderDeposit(lender2, 1000e6);
        // No interest distributed yet → lender2 has zero.
        assertEq(pool.getLenderInfo(lender2).claimableInterest, 0);
        // lender1's already-earned interest is untouched by the new deposit.
        assertEq(
            pool.getLenderInfo(lender1).claimableInterest,
            lender1AfterFirst
        );

        // Second loan, equal interest, now split 50/50 between the two lenders.
        IAssetLendingPool.Loan memory loan2 = _borrowAndRepay(400e6, 0);
        uint256 secondLenderPortion = (loan2.interest * 8000) / 10_000;

        // lender2 earns only half of the SECOND loan's interest, nothing of the first.
        assertApproxEqAbs(
            pool.getLenderInfo(lender2).claimableInterest,
            secondLenderPortion / 2,
            1
        );
        // lender1 = first loan (full) + half of second loan.
        assertApproxEqAbs(
            pool.getLenderInfo(lender1).claimableInterest,
            lender1AfterFirst + secondLenderPortion / 2,
            1
        );
    }

    /// @dev Withdrawing principal auto-claims accrued interest and stops further
    ///      accrual on the withdrawn capital.
    function test_LenderInterest_WithdrawAutoClaimsAndStopsAccrual() public {
        _enableLenders();
        _lenderDeposit(lender1, 1000e6);

        // First loan accrues interest to lender1.
        _borrowAndRepay(400e6, 0);
        uint256 earned = pool.getLenderInfo(lender1).claimableInterest;
        assertGt(earned, 0);

        // Full withdrawal auto-claims the earned interest into lender1's wallet.
        uint256 balBefore = usdc.balanceOf(lender1);
        vm.prank(lender1);
        pool.lenderWithdraw(1000e6);
        assertEq(usdc.balanceOf(lender1), balBefore + 1000e6 + earned);
        assertEq(pool.getLenderInfo(lender1).deposited, 0);
        assertEq(pool.getLenderInfo(lender1).claimableInterest, 0);

        // A subsequent loan must not accrue anything to the exited lender.
        _borrowAndRepay(400e6, 0);
        assertEq(pool.getLenderInfo(lender1).claimableInterest, 0);
    }

    /// @dev Documents intended economics: a defaulted loan distributes NO interest
    ///      to lenders, even though its fixed interest was set at origination.
    function test_LenderInterest_DefaultDistributesNoInterest() public {
        _enableLenders();
        _lenderDeposit(lender1, POOL_SEED);

        (uint256 loanId, ) = _createDefaultedLoan(400e6);
        assertTrue(pool.getLoan(loanId).isDefaulted);

        // No interest realized on default → lender has nothing to claim.
        assertEq(pool.getLenderInfo(lender1).claimableInterest, 0);
        assertEq(pool.getPoolInfo().totalInterestEarned, 0);
    }

    // =========================================================================
    // Owner deposit/withdraw (V2 separation from lender capital)
    // =========================================================================

    function test_OwnerWithdraw_OnlyOwnerDeposited() public {
        _enableLenders();
        // Lender deposits 1000
        usdc.mint(lender1, 1000e6);
        vm.startPrank(lender1);
        usdc.approve(address(pool), 1000e6);
        pool.lenderDeposit(1000e6);
        vm.stopPrank();

        // Owner can only withdraw ownerDeposited (POOL_SEED), not lender capital
        vm.expectRevert(
            IAssetLendingPool
                .AssetLendingPool__OwnerWithdrawExceedsOwnerDeposits
                .selector
        );
        vm.prank(admin);
        pool.withdraw(POOL_SEED + 1);

        // But can withdraw up to POOL_SEED
        vm.prank(admin);
        pool.withdraw(POOL_SEED);
        assertEq(pool.getPoolInfo().ownerDeposited, 0);
    }

    // =========================================================================
    // Default lifecycle: initiateDefault
    // =========================================================================

    function test_InitiateDefault_CreatesDefaultRecord() public {
        (uint256 loanId, uint256 tokenId) = _createDefaultedLoan(400e6);

        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(
            loanId
        );
        assertEq(rec.loanId, loanId);
        assertEq(rec.tokenIds[0], tokenId);
        assertEq(rec.outstandingValue, 400e6);
        assertFalse(rec.resolved);
        assertGt(rec.defaultedAt, 0);
    }

    function test_InitiateDefault_TracksTotalDefaultedPrincipal() public {
        (uint256 loanId, ) = _createDefaultedLoan(400e6);
        assertEq(pool.getPoolInfo().totalDefaultedPrincipal, 400e6);
        // Also verify it's in acquisition phase
        assertEq(
            uint8(pool.getDefaultPhase(loanId)),
            uint8(IAssetLendingPool.DefaultPhase.Acquisition)
        );
    }

    function test_InitiateDefault_PhaseTransitionsOverTime() public {
        (uint256 loanId, ) = _createDefaultedLoan(400e6);
        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(
            loanId
        );

        // Phase 1: within 24h
        assertEq(
            uint8(pool.getDefaultPhase(loanId)),
            uint8(IAssetLendingPool.DefaultPhase.Acquisition)
        );

        // Phase 2: after 24h, within 7 days
        vm.warp(rec.defaultedAt + 24 hours + 1);
        assertEq(
            uint8(pool.getDefaultPhase(loanId)),
            uint8(IAssetLendingPool.DefaultPhase.Auction)
        );

        // Phase 3: after 7 days
        vm.warp(rec.defaultedAt + 24 hours + 7 days + 1);
        assertEq(
            uint8(pool.getDefaultPhase(loanId)),
            uint8(IAssetLendingPool.DefaultPhase.FixedListing)
        );
    }

    function test_InitiateDefault_NonexistentLoanReturnsNone() public view {
        assertEq(
            uint8(pool.getDefaultPhase(999)),
            uint8(IAssetLendingPool.DefaultPhase.None)
        );
    }

    // =========================================================================
    // Default lifecycle: acquireDefaultedAsset (Phase 1)
    // =========================================================================

    function test_AcquireDefaultedAsset_RecyclesNFTToPackMachine() public {
        (uint256 loanId, uint256 tokenId) = _createDefaultedLoan(400e6);

        uint256 depositedBefore = pool.getPoolInfo().totalDeposited;

        vm.prank(admin);
        pool.acquireDefaultedAsset(loanId, address(mockMachine), 0);

        // Default resolved
        assertTrue(pool.getDefaultRecord(loanId).resolved);
        assertEq(
            uint8(pool.getDefaultPhase(loanId)),
            uint8(IAssetLendingPool.DefaultPhase.Resolved)
        );

        // Pool made whole
        assertEq(pool.getPoolInfo().totalDeposited, depositedBefore + 400e6);
        assertEq(pool.getPoolInfo().totalDefaultedPrincipal, 0);

        // NFT transferred to mock machine
        assertEq(assetNFT.ownerOf(tokenId), address(mockMachine));
    }

    function test_AcquireDefaultedAsset_RevertsAfterAcquisitionWindow() public {
        (uint256 loanId, ) = _createDefaultedLoan(400e6);
        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(
            loanId
        );

        // Warp past acquisition window
        vm.warp(rec.defaultedAt + 24 hours + 1);

        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__NotInAcquisitionPhase.selector
        );
        vm.prank(admin);
        pool.acquireDefaultedAsset(loanId, address(mockMachine), 0);
    }

    function test_AcquireDefaultedAsset_RevertsIfInvalidMachine() public {
        (uint256 loanId, ) = _createDefaultedLoan(400e6);

        address fakeMachine = makeAddr("fakeMachine");
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InvalidPackMachine.selector
        );
        vm.prank(admin);
        pool.acquireDefaultedAsset(loanId, fakeMachine, 0);
    }

    function test_AcquireDefaultedAsset_RevertsIfAlreadyResolved() public {
        (uint256 loanId, ) = _createDefaultedLoan(400e6);

        vm.prank(admin);
        pool.acquireDefaultedAsset(loanId, address(mockMachine), 0);

        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__DefaultAlreadyResolved.selector
        );
        vm.prank(admin);
        pool.acquireDefaultedAsset(loanId, address(mockMachine), 0);
    }

    // =========================================================================
    // Default lifecycle: purchaseDefaultedAsset (Phase 2 & 3)
    // =========================================================================

    function test_PurchaseDefaultedAsset_Phase2_TransfersNFTToBuyer() public {
        address buyer = makeAddr("buyer");
        (uint256 loanId, uint256 tokenId) = _createDefaultedLoan(400e6);
        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(
            loanId
        );

        // Warp into Phase 2
        vm.warp(rec.defaultedAt + 24 hours + 1);

        uint256 depositedBefore = pool.getPoolInfo().totalDeposited;

        usdc.mint(buyer, 400e6);
        vm.startPrank(buyer);
        usdc.approve(address(pool), 400e6);
        pool.purchaseDefaultedAsset(loanId);
        vm.stopPrank();

        // NFT transferred to buyer
        assertEq(assetNFT.ownerOf(tokenId), buyer);
        // Pool made whole
        assertEq(pool.getPoolInfo().totalDeposited, depositedBefore + 400e6);
        assertEq(pool.getPoolInfo().totalDefaultedPrincipal, 0);
        assertTrue(pool.getDefaultRecord(loanId).resolved);
    }

    function test_PurchaseDefaultedAsset_Phase3_Works() public {
        address buyer = makeAddr("buyer");
        (uint256 loanId, uint256 tokenId) = _createDefaultedLoan(400e6);
        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(
            loanId
        );

        // Warp into Phase 3 (past auction window too)
        vm.warp(rec.defaultedAt + 24 hours + 7 days + 1);

        usdc.mint(buyer, 400e6);
        vm.startPrank(buyer);
        usdc.approve(address(pool), 400e6);
        pool.purchaseDefaultedAsset(loanId);
        vm.stopPrank();

        assertEq(assetNFT.ownerOf(tokenId), buyer);
    }

    function test_PurchaseDefaultedAsset_RevertsInPhase1() public {
        (uint256 loanId, ) = _createDefaultedLoan(400e6);

        // Still in Phase 1
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__NotInPurchasePhase.selector
        );
        vm.prank(makeAddr("buyer"));
        pool.purchaseDefaultedAsset(loanId);
    }

    function test_PurchaseDefaultedAsset_RevertsIfAlreadyResolved() public {
        address buyer = makeAddr("buyer");
        (uint256 loanId, ) = _createDefaultedLoan(400e6);
        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(
            loanId
        );
        vm.warp(rec.defaultedAt + 24 hours + 1);

        usdc.mint(buyer, 800e6);
        vm.startPrank(buyer);
        usdc.approve(address(pool), 800e6);
        pool.purchaseDefaultedAsset(loanId);

        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__DefaultAlreadyResolved.selector
        );
        pool.purchaseDefaultedAsset(loanId);
        vm.stopPrank();
    }

    // =========================================================================
    // Default lifecycle: capital recovery restores lender value
    // =========================================================================

    function test_DefaultRecovery_MakesLendersWhole() public {
        _enableLenders();
        // Lender deposits 10k
        usdc.mint(lender1, POOL_SEED);
        vm.startPrank(lender1);
        usdc.approve(address(pool), POOL_SEED);
        pool.lenderDeposit(POOL_SEED);
        vm.stopPrank();

        uint256 liquidityBefore = pool.getAvailableLiquidity();

        // Default a loan of 400
        (uint256 loanId, ) = _createDefaultedLoan(400e6);
        // After default, liquidity drops by principal
        assertEq(pool.getAvailableLiquidity(), liquidityBefore - 400e6);

        // Buyer purchases in Phase 2
        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(
            loanId
        );
        vm.warp(rec.defaultedAt + 24 hours + 1);

        address buyer = makeAddr("buyer");
        usdc.mint(buyer, 400e6);
        vm.startPrank(buyer);
        usdc.approve(address(pool), 400e6);
        pool.purchaseDefaultedAsset(loanId);
        vm.stopPrank();

        // Liquidity restored
        assertEq(pool.getAvailableLiquidity(), liquidityBefore);
    }

    // =========================================================================
    // $100 Default Minimum Appraisal Value
    // =========================================================================

    function test_Initialize_SetsDefaultMinAppraisalValue() public view {
        // USDC has 6 decimals → default should be 100e6
        assertEq(pool.getPoolInfo().minAppraisalValue, 100e6);
    }

    function test_Borrow_RevertsIfBelowDefaultMinAppraisal() public {
        uint256 tokenId = _mintNFT(borrower);
        // Appraise below the $100 default minimum
        vm.prank(admin);
        pool.setAppraisal(tokenId, 50e6, 0, 0);

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(IAssetLendingPool.AssetLendingPool__IneligibleAsset.selector);
        pool.borrow(tokenId, 25e6, 0);
        vm.stopPrank();
    }

    function test_MinAppraisal_AdminCanLower() public {
        // Admin lowers the minimum to 0 — a sub-$100 appraisal should then be borrowable
        vm.prank(admin);
        uint256[] memory empty = new uint256[](0);
        pool.setEligibilityControls(0, 0, empty, empty);

        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, 50e6, 0, 0);

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, 10e6, 0); // 50e6 * 50% LTV = 25e6 max
        vm.stopPrank();

        assertEq(pool.getAvailableLiquidity(), POOL_SEED - 10e6);
    }

    // =========================================================================
    // Bundle Loans — borrowBundle
    // =========================================================================

    function _mintAndAppraise(
        address recipient,
        uint256 value
    ) internal returns (uint256 tokenId) {
        tokenId = _mintNFT(recipient);
        vm.prank(admin);
        pool.setAppraisal(tokenId, value, 0, 0);
    }

    function test_BorrowBundle_HappyPath_AndRepay() public {
        // Mint 3 NFTs, each appraised at 1000 USDC → summed 3000 USDC, max loan 1500 USDC
        uint256 t1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        uint256 t2 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        uint256 t3 = _mintAndAppraise(borrower, APPRAISAL_VALUE);

        uint256[] memory ids = new uint256[](3);
        ids[0] = t1;
        ids[1] = t2;
        ids[2] = t3;

        uint256 borrowAmount = 1200e6; // within 1500e6 max

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), t1);
        assetNFT.approve(address(pool), t2);
        assetNFT.approve(address(pool), t3);
        pool.borrowBundle(ids, borrowAmount, 0);
        vm.stopPrank();

        // Pool owns all three, all in Loaned state
        assertEq(assetNFT.ownerOf(t1), address(pool));
        assertEq(assetNFT.ownerOf(t2), address(pool));
        assertEq(assetNFT.ownerOf(t3), address(pool));

        // Single loan recorded with 3 collateral tokens
        uint256[] memory loanIds = pool.getBorrowerLoans(borrower);
        assertEq(loanIds.length, 1);
        IAssetLendingPool.Loan memory loan = pool.getLoan(loanIds[0]);
        assertEq(loan.tokenIds.length, 3);
        assertEq(loan.tokenIds[0], t1);
        assertEq(loan.tokenIds[1], t2);
        assertEq(loan.tokenIds[2], t3);
        assertEq(loan.principal, borrowAmount);
        assertFalse(loan.isPaid);

        // getLoanTokenIds view
        uint256[] memory fetched = pool.getLoanTokenIds(loanIds[0]);
        assertEq(fetched.length, 3);

        // Liquidity reduced
        assertEq(pool.getAvailableLiquidity(), POOL_SEED - borrowAmount);

        // Repay
        uint256 repayAmount = borrowAmount + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanIds[0]);
        vm.stopPrank();

        // All NFTs returned to borrower
        assertEq(assetNFT.ownerOf(t1), borrower);
        assertEq(assetNFT.ownerOf(t2), borrower);
        assertEq(assetNFT.ownerOf(t3), borrower);

        assertTrue(pool.getLoan(loanIds[0]).isPaid);
        assertEq(pool.getAvailableLiquidity(), POOL_SEED); // principal returned (interest goes to protocol)
    }

    function test_BorrowBundle_SummedAppraisalDrivesLTV() public {
        // Two tokens at 1000 USDC each → summed 2000, max 1000
        uint256 t1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        uint256 t2 = _mintAndAppraise(borrower, APPRAISAL_VALUE);

        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), t1);
        assetNFT.approve(address(pool), t2);

        // Exactly at max — should succeed
        pool.borrowBundle(ids, MAX_LOAN * 2, 0); // 1000e6
        vm.stopPrank();

        assertEq(pool.getAvailableLiquidity(), POOL_SEED - MAX_LOAN * 2);
    }

    function test_BorrowBundle_RevertsIfExceedsLTV() public {
        uint256 t1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        uint256 t2 = _mintAndAppraise(borrower, APPRAISAL_VALUE);

        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), t1);
        assetNFT.approve(address(pool), t2);
        vm.expectRevert(IAssetLendingPool.AssetLendingPool__ExceedsLTV.selector);
        pool.borrowBundle(ids, MAX_LOAN * 2 + 1, 0);
        vm.stopPrank();
    }

    function test_BorrowBundle_DefaultAndAcquire() public {
        uint256 t1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        uint256 t2 = _mintAndAppraise(borrower, APPRAISAL_VALUE);

        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), t1);
        assetNFT.approve(address(pool), t2);
        pool.borrowBundle(ids, 800e6, 0);
        vm.stopPrank();

        uint256 loanId = pool.getBorrowerLoans(borrower)[0];

        // Warp past term expiry
        IAssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        vm.warp(loan.expireTime + 1);

        vm.prank(admin);
        pool.initiateDefault(loanId);

        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(loanId);
        assertEq(rec.tokenIds.length, 2);
        assertEq(rec.tokenIds[0], t1);
        assertEq(rec.tokenIds[1], t2);
        assertFalse(rec.resolved);

        // Acquire within 24h window
        uint256 liquidityBefore = pool.getAvailableLiquidity();
        vm.prank(admin);
        pool.acquireDefaultedAsset(loanId, address(mockMachine), 1);

        assertTrue(pool.getDefaultRecord(loanId).resolved);
        // Both NFTs owned by mock machine
        assertEq(assetNFT.ownerOf(t1), address(mockMachine));
        assertEq(assetNFT.ownerOf(t2), address(mockMachine));
        // Pool credited back outstanding principal
        assertEq(pool.getAvailableLiquidity(), liquidityBefore + 800e6);
    }

    function test_BorrowBundle_DefaultAndPurchase() public {
        uint256 t1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        uint256 t2 = _mintAndAppraise(borrower, APPRAISAL_VALUE);

        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), t1);
        assetNFT.approve(address(pool), t2);
        pool.borrowBundle(ids, 800e6, 0);
        vm.stopPrank();

        uint256 loanId = pool.getBorrowerLoans(borrower)[0];
        IAssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        vm.warp(loan.expireTime + 1);

        vm.prank(admin);
        pool.initiateDefault(loanId);

        // Warp into Phase 2 (past acquisition window)
        IAssetLendingPool.DefaultRecord memory rec = pool.getDefaultRecord(loanId);
        vm.warp(rec.defaultedAt + 24 hours + 1);

        address buyer = makeAddr("bundleBuyer");
        usdc.mint(buyer, 800e6);
        vm.startPrank(buyer);
        usdc.approve(address(pool), 800e6);
        pool.purchaseDefaultedAsset(loanId);
        vm.stopPrank();

        // Buyer receives both NFTs
        assertEq(assetNFT.ownerOf(t1), buyer);
        assertEq(assetNFT.ownerOf(t2), buyer);
        assertTrue(pool.getDefaultRecord(loanId).resolved);
    }

    function test_BorrowBundle_RevertsIfPerAssetIneligible() public {
        uint256 t1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        uint256 t2 = _mintNFT(borrower); // no appraisal set

        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), t1);
        assetNFT.approve(address(pool), t2);
        vm.expectRevert(IAssetLendingPool.AssetLendingPool__NoAppraisal.selector);
        pool.borrowBundle(ids, 100e6, 0);
        vm.stopPrank();

        // Neither NFT was pulled
        assertEq(assetNFT.ownerOf(t1), borrower);
        assertEq(assetNFT.ownerOf(t2), borrower);
    }

    function test_BorrowBundle_RevertsIfBelowMinAppraisal() public {
        uint256 t1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        uint256 t2 = _mintNFT(borrower);
        // Appraise t2 below the $100 default minimum
        vm.prank(admin);
        pool.setAppraisal(t2, 50e6, 0, 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), t1);
        assetNFT.approve(address(pool), t2);
        vm.expectRevert(IAssetLendingPool.AssetLendingPool__IneligibleAsset.selector);
        pool.borrowBundle(ids, 100e6, 0);
        vm.stopPrank();
    }

    function test_BorrowBundle_RevertsIfOneTokenAlreadyLoaned() public {
        uint256 t1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        uint256 t2 = _mintAndAppraise(borrower, APPRAISAL_VALUE);

        // Borrow t1 single
        _borrow(borrower, t1, 200e6, 0);

        uint256[] memory ids = new uint256[](2);
        ids[0] = t1;
        ids[1] = t2;

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), t2);
        vm.expectRevert(IAssetLendingPool.AssetLendingPool__ActiveLoanExists.selector);
        pool.borrowBundle(ids, 200e6, 0);
        vm.stopPrank();
    }

    function test_BorrowBundle_RevertsIfEmpty() public {
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(IAssetLendingPool.AssetLendingPool__EmptyBundle.selector);
        vm.prank(borrower);
        pool.borrowBundle(ids, 100e6, 0);
    }

    function test_BorrowBundle_RevertsIfTooLarge() public {
        uint256[] memory ids = new uint256[](51);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetLendingPool.AssetLendingPool__BatchTooLarge.selector,
                51,
                50
            )
        );
        vm.prank(borrower);
        pool.borrowBundle(ids, 100e6, 0);
    }
}
