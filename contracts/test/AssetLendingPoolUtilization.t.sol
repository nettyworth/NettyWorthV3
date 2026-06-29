// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AssetLendingPool} from "../AssetLendingPool.sol";
import {IAssetLendingPool} from "../interfaces/IAssetLendingPool.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

// Minimal mock PackMachineFactory — only isPackMachine is called in these tests.
contract MockFactoryForUtil {
    function isPackMachine(address) external pure returns (bool) {
        return false;
    }
}

/// @dev Test suite for the Maximum Pool Utilization cap introduced in V3.
///      Covers setMaxUtilizationBps admin setter and the origination enforcement
///      via _checkUtilization in both the borrow and marketplace paths.
contract AssetLendingPoolUtilizationTest is Test {
    AssetLendingPool internal pool;
    AssetNFT internal assetNFT;
    PermissionManager internal pm;
    MockERC20 internal usdc;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal forwarder = makeAddr("forwarder");
    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal unauthorized = makeAddr("unauthorized");

    // Pool seeded with 100 USDC (6 decimals → 100e6)
    uint256 internal constant POOL_DEPOSIT = 100e6;
    uint256 internal constant APPRAISAL_VALUE = 1000e6; // well above loan sizes
    uint256 internal constant LTV_BPS = 10_000; // 100% LTV so tests focus on utilization
    uint8 internal constant TERM_7D = 0; // term 0: 7 days / 10% APR

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

        // USDC mock (6 decimals)
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

        // AssetLendingPool
        MockFactoryForUtil mockFactory = new MockFactoryForUtil();
        AssetLendingPool poolImpl = new AssetLendingPool();
        ERC1967Proxy poolProxy = new ERC1967Proxy(
            address(poolImpl),
            abi.encodeCall(
                AssetLendingPool.initialize,
                (
                    admin,
                    address(usdc),
                    address(assetNFT),
                    LTV_BPS,
                    8000, // lenderShareBps
                    24 hours,
                    7 days,
                    address(mockFactory)
                )
            )
        );
        pool = AssetLendingPool(address(poolProxy));

        // Grant STATE_MANAGER_ROLE so the pool can flip NFT states
        vm.startPrank(admin);
        pm.grantRole(pm.STATE_MANAGER_ROLE(), address(pool));
        vm.stopPrank();

        // Seed the pool with 100 USDC from admin
        usdc.mint(admin, POOL_DEPOSIT);
        vm.startPrank(admin);
        usdc.approve(address(pool), POOL_DEPOSIT);
        pool.deposit(POOL_DEPOSIT);
        vm.stopPrank();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _mintAndAppraise(
        address recipient,
        uint256 appraisalValue
    ) internal returns (uint256 tokenId) {
        tokenId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](1);
        string[] memory uris = new string[](1);
        recipients[0] = recipient;
        uris[0] = "";
        vm.prank(minter);
        assetNFT.batchMint(recipients, uris);
        vm.prank(admin);
        pool.setAppraisal(tokenId, appraisalValue, 0, 0);
    }

    function _borrow(
        address who,
        uint256 tokenId,
        uint256 amount
    ) internal {
        usdc.mint(who, 0); // ensure account exists
        vm.startPrank(who);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, amount, TERM_7D);
        vm.stopPrank();
    }

    // =========================================================================
    // Initialisation
    // =========================================================================

    function test_DefaultMaxUtilizationIs8000() public view {
        IAssetLendingPool.PoolInfo memory info = pool.getPoolInfo();
        assertEq(info.maxUtilizationBps, 8000);
    }

    // =========================================================================
    // setMaxUtilizationBps — admin setter
    // =========================================================================

    function test_SetMaxUtilizationBps_OwnerCanUpdate() public {
        vm.prank(admin);
        pool.setMaxUtilizationBps(9000);

        IAssetLendingPool.PoolInfo memory info = pool.getPoolInfo();
        assertEq(info.maxUtilizationBps, 9000);
    }

    function test_SetMaxUtilizationBps_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IAssetLendingPool.MaxUtilizationUpdated(8000, 9500);
        vm.prank(admin);
        pool.setMaxUtilizationBps(9500);
    }

    function test_SetMaxUtilizationBps_AcceptsBoundaryValues() public {
        vm.prank(admin);
        pool.setMaxUtilizationBps(1); // minimum
        assertEq(pool.getPoolInfo().maxUtilizationBps, 1);

        vm.prank(admin);
        pool.setMaxUtilizationBps(10_000); // maximum (no reserve)
        assertEq(pool.getPoolInfo().maxUtilizationBps, 10_000);
    }

    function test_SetMaxUtilizationBps_RejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(IAssetLendingPool.AssetLendingPool__InvalidBps.selector);
        pool.setMaxUtilizationBps(0);
    }

    function test_SetMaxUtilizationBps_RejectsAboveBps() public {
        vm.prank(admin);
        vm.expectRevert(IAssetLendingPool.AssetLendingPool__InvalidBps.selector);
        pool.setMaxUtilizationBps(10_001);
    }

    function test_SetMaxUtilizationBps_NonOwnerReverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        pool.setMaxUtilizationBps(9000);
    }

    // =========================================================================
    // borrow — utilization enforcement
    // =========================================================================

    function test_Borrow_ExactlyAtCapSucceeds() public {
        // Pool = 100 USDC, cap = 80% → max borrow = 80 USDC
        uint256 tokenId = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        _borrow(borrower, tokenId, 80e6);
        assertEq(pool.getPoolInfo().totalBorrowed, 80e6);
    }

    function test_Borrow_OneWeiOverCapReverts() public {
        uint256 tokenId = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        vm.startPrank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ExceedsMaxUtilization.selector
        );
        pool.borrow(tokenId, 80e6 + 1, TERM_7D);
        vm.stopPrank();
    }

    function test_Borrow_SecondLoanBlockedWhenCapReached() public {
        // First loan fills to cap
        uint256 tokenId1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        _borrow(borrower, tokenId1, 80e6);

        // Any additional borrow should be blocked
        uint256 tokenId2 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        vm.startPrank(borrower);
        assetNFT.approve(address(pool), tokenId2);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ExceedsMaxUtilization.selector
        );
        pool.borrow(tokenId2, 1, TERM_7D);
        vm.stopPrank();
    }

    function test_Borrow_RepaymentRestoresHeadroom() public {
        // Fill to cap
        uint256 tokenId1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        _borrow(borrower, tokenId1, 80e6);

        // Repay (principal + interest for 7d/10% APR on 80e6)
        uint256 loanId = 1;
        IAssetLendingPool.Loan memory loan = pool.getLoan(loanId);
        uint256 repayAmt = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmt);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmt);
        pool.repay(loanId);
        vm.stopPrank();

        // Now a second borrow should succeed (totalBorrowed == 0 → full cap available)
        uint256 tokenId2 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        _borrow(borrower, tokenId2, 80e6);
        assertEq(pool.getPoolInfo().totalBorrowed, 80e6);
    }

    function test_Borrow_Cap10000_EqualsLegacyFullLiquidity() public {
        // With cap == 10000 (100%), borrowing exactly totalDeposited - totalBorrowed succeeds.
        vm.prank(admin);
        pool.setMaxUtilizationBps(10_000);

        uint256 tokenId = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        _borrow(borrower, tokenId, POOL_DEPOSIT); // 100% utilization — should succeed
        assertEq(pool.getPoolInfo().totalBorrowed, POOL_DEPOSIT);
    }

    function test_Borrow_Cap10000_OneWeiOverStillReverts() public {
        // Even with the reserve disabled, can't borrow more than deposited.
        vm.prank(admin);
        pool.setMaxUtilizationBps(10_000);

        uint256 tokenId = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        vm.startPrank(borrower);
        assetNFT.approve(address(pool), tokenId);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ExceedsMaxUtilization.selector
        );
        pool.borrow(tokenId, POOL_DEPOSIT + 1, TERM_7D);
        vm.stopPrank();
    }

    // =========================================================================
    // lenderWithdraw — can draw the reserved liquidity
    // =========================================================================

    function test_LenderWithdraw_CanAccessReserveCapital() public {
        // Enable lender deposits
        vm.prank(admin);
        pool.setLenderConfig(8000, true);

        // Lender deposits 100 USDC
        usdc.mint(lender, 100e6);
        vm.startPrank(lender);
        usdc.approve(address(pool), 100e6);
        pool.lenderDeposit(100e6);
        vm.stopPrank();

        // Borrow exactly at cap (80% of 200 total = 160 USDC)
        uint256 tokenId = _mintAndAppraise(borrower, APPRAISAL_VALUE * 2);
        _borrow(borrower, tokenId, 160e6);

        // Available idle: 200 - 160 = 40 USDC (the 20% reserve)
        // Lender should be able to withdraw up to their deposit share of idle capital (40 USDC)
        vm.startPrank(lender);
        pool.lenderWithdraw(40e6); // withdraws the reserved portion
        vm.stopPrank();

        // After withdrawal, originations are blocked (totalDeposited now 160, totalBorrowed 160)
        uint256 tokenId2 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        vm.startPrank(borrower);
        assetNFT.approve(address(pool), tokenId2);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ExceedsMaxUtilization.selector
        );
        pool.borrow(tokenId2, 1, TERM_7D);
        vm.stopPrank();
    }

    // =========================================================================
    // New deposit raises the cap ceiling proportionally
    // =========================================================================

    function test_NewDepositRaisesCapCeiling() public {
        // Fill to cap: 80 USDC of 100 deposited
        uint256 tokenId1 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        _borrow(borrower, tokenId1, 80e6);

        // Next borrow blocked
        uint256 tokenId2 = _mintAndAppraise(borrower, APPRAISAL_VALUE);
        vm.startPrank(borrower);
        assetNFT.approve(address(pool), tokenId2);
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ExceedsMaxUtilization.selector
        );
        pool.borrow(tokenId2, 1, TERM_7D);
        vm.stopPrank();

        // Admin deposits 25 more USDC → total = 125, cap = 100, headroom = 20
        usdc.mint(admin, 25e6);
        vm.startPrank(admin);
        usdc.approve(address(pool), 25e6);
        pool.deposit(25e6);
        vm.stopPrank();

        // Now up to 20 USDC can be borrowed (125 * 80% = 100, already at 80)
        _borrow(borrower, tokenId2, 20e6);
        assertEq(pool.getPoolInfo().totalBorrowed, 100e6);
    }
}
