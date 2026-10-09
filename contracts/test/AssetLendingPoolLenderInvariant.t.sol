// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AssetLendingPool} from "../AssetLendingPool.sol";
import {AssetLendingPoolConfig} from "../AssetLendingPoolConfig.sol";
import {IAssetLendingPool} from "../interfaces/IAssetLendingPool.sol";
import {AssetNFT} from "../AssetNFT.sol";
import {PermissionManager} from "../PermissionManager.sol";
import {MockERC20} from "../test-helpers/MockERC20.sol";

contract InvariantMockPackMachineFactory {
    function isPackMachine(address) external pure returns (bool) {
        return false;
    }
}

/// @dev Drives random lender / borrower activity against the pool and keeps ghost
///      totals of the lender interest the pool has distributed and paid out.
contract LenderInterestHandler is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant APPRAISAL_VALUE = 1_000e6;

    AssetLendingPool internal pool;
    AssetLendingPoolConfig internal config;
    AssetNFT internal assetNFT;
    MockERC20 internal usdc;
    address internal admin;
    address internal minter;
    address internal borrower = makeAddr("borrower");

    address[] internal lenders;
    uint256[] internal openLoans;

    /// @dev Σ lender portion credited to accInterestPerShare across all repays.
    uint256 public ghostLenderPortion;
    /// @dev Σ lender interest actually transferred out (claims + withdraw auto-claims).
    uint256 public ghostLenderInterestPaid;
    /// @dev Deposits + withdrawals. Each floors a rewardDebt write, which can overstate
    ///      that lender's claimable interest by at most 1 wei (pre-existing dust).
    uint256 public ghostRoundingActions;

    constructor(
        AssetLendingPool pool_,
        AssetLendingPoolConfig config_,
        AssetNFT assetNFT_,
        MockERC20 usdc_,
        address admin_,
        address minter_
    ) {
        pool = pool_;
        config = config_;
        assetNFT = assetNFT_;
        usdc = usdc_;
        admin = admin_;
        minter = minter_;
        lenders.push(makeAddr("lenderA"));
        lenders.push(makeAddr("lenderB"));
        lenders.push(makeAddr("lenderC"));
    }

    function getLenders() external view returns (address[] memory) {
        return lenders;
    }

    function deposit(uint256 who, uint256 amount) external {
        address lender = lenders[who % lenders.length];
        amount = bound(amount, 1e6, 1_000_000e6);
        usdc.mint(lender, amount);
        vm.startPrank(lender);
        usdc.approve(address(pool), amount);
        pool.lenderDeposit(amount);
        vm.stopPrank();
        ghostRoundingActions++;
    }

    function withdraw(uint256 who, uint256 amount) external {
        address lender = lenders[who % lenders.length];
        uint256 balance = pool.getLenderInfo(lender).deposited;
        IAssetLendingPool.PoolInfo memory info = pool.getPoolInfo();
        uint256 available = info.totalDeposited - info.totalBorrowed;
        uint256 maxAmount = balance < available ? balance : available;
        if (maxAmount == 0) return;
        amount = bound(amount, 1, maxAmount);

        uint256 unlocksAt = pool.getLenderUnlockTime(lender);
        if (block.timestamp < unlocksAt) vm.warp(unlocksAt);

        ghostLenderInterestPaid += pool.getLenderInfo(lender).claimableInterest;
        vm.prank(lender);
        pool.lenderWithdraw(amount);
        ghostRoundingActions++;
    }

    function claim(uint256 who) external {
        address lender = lenders[who % lenders.length];
        uint256 pending = pool.getLenderInfo(lender).claimableInterest;
        if (pending == 0) return;
        ghostLenderInterestPaid += pending;
        vm.prank(lender);
        pool.claimLenderInterest();
    }

    function borrow(uint256 principal) external {
        principal = bound(principal, 1e6, (APPRAISAL_VALUE * 5000) / BPS);
        IAssetLendingPool.PoolInfo memory info = pool.getPoolInfo();
        if (
            info.totalBorrowed + principal >
            (info.totalDeposited * config.maxUtilizationBps()) / BPS
        ) return;

        uint256 tokenId = assetNFT.totalSupply() + 1;
        address[] memory recipients = new address[](1);
        string[] memory uris = new string[](1);
        recipients[0] = borrower;
        vm.prank(minter);
        assetNFT.batchMint(recipients, uris);
        vm.prank(admin);
        config.setAppraisal(tokenId, APPRAISAL_VALUE, 0, 0);

        vm.startPrank(borrower);
        assetNFT.approve(address(pool), tokenId);
        pool.borrow(tokenId, principal, 0);
        vm.stopPrank();

        uint256[] memory loans = pool.getBorrowerLoans(borrower);
        openLoans.push(loans[loans.length - 1]);
    }

    function repay(uint256 index) external {
        if (openLoans.length == 0) return;
        index = index % openLoans.length;
        uint256 loanId = openLoans[index];
        IAssetLendingPool.Loan memory loan = pool.getLoan(loanId);

        if (pool.getPoolInfo().totalLenderDeposits > 0) {
            ghostLenderPortion +=
                (loan.interest * loan.lenderShareBpsSnapshot) / BPS;
        }

        uint256 repayAmount = loan.principal + loan.interest;
        usdc.mint(borrower, repayAmount);
        vm.startPrank(borrower);
        usdc.approve(address(pool), repayAmount);
        pool.repay(loanId);
        vm.stopPrank();

        openLoans[index] = openLoans[openLoans.length - 1];
        openLoans.pop();
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 3 days));
    }
}

/// @notice Lender-accounting invariants for AssetLendingPool. The 2026-10-08 drain
///         broke both: claims exceeded the interest distributed, and the pool paid
///         them out of other lenders' principal.
contract AssetLendingPoolLenderInvariantTest is StdInvariant, Test {
    uint256 internal constant BPS = 10_000;

    AssetLendingPool internal pool;
    MockERC20 internal usdc;
    LenderInterestHandler internal handler;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");

    function setUp() public {
        PermissionManager pm = PermissionManager(
            address(
                new ERC1967Proxy(
                    address(new PermissionManager()),
                    abi.encodeCall(PermissionManager.initialize, (admin))
                )
            )
        );
        usdc = new MockERC20();

        AssetNFT assetNFT = AssetNFT(
            address(
                new ERC1967Proxy(
                    address(new AssetNFT(address(0))),
                    abi.encodeCall(
                        AssetNFT.initialize,
                        (
                            address(pm),
                            "NettyWorth Assets",
                            "NWA",
                            "ipfs://contract",
                            admin,
                            uint96(0)
                        )
                    )
                )
            )
        );

        AssetLendingPoolConfig config = AssetLendingPoolConfig(
            address(
                new ERC1967Proxy(
                    address(new AssetLendingPoolConfig()),
                    abi.encodeCall(
                        AssetLendingPoolConfig.initialize,
                        (
                            admin,
                            address(usdc),
                            address(assetNFT),
                            5000,
                            8000,
                            24 hours,
                            7 days,
                            address(new InvariantMockPackMachineFactory())
                        )
                    )
                )
            )
        );

        pool = AssetLendingPool(
            address(
                new ERC1967Proxy(
                    address(new AssetLendingPool()),
                    abi.encodeCall(
                        AssetLendingPool.initialize,
                        (admin, address(config))
                    )
                )
            )
        );

        vm.startPrank(admin);
        pm.grantRole(pm.MINTER_ROLE(), minter);
        pm.grantRole(pm.STATE_MANAGER_ROLE(), address(pool));
        config.setFinanceWallet(makeAddr("financeWallet"));
        config.setLenderConfig(8000, true);
        vm.stopPrank();

        // Protocol seed capital so borrows are possible before any lender deposits.
        usdc.mint(admin, 10_000e6);
        vm.startPrank(admin);
        usdc.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        vm.stopPrank();

        handler = new LenderInterestHandler(
            pool,
            config,
            assetNFT,
            usdc,
            admin,
            minter
        );

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LenderInterestHandler.deposit.selector;
        selectors[1] = LenderInterestHandler.withdraw.selector;
        selectors[2] = LenderInterestHandler.claim.selector;
        selectors[3] = LenderInterestHandler.borrow.selector;
        selectors[4] = LenderInterestHandler.repay.selector;
        selectors[5] = LenderInterestHandler.warp.selector;
        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    function _totalClaimable() internal view returns (uint256 total) {
        address[] memory lenders = handler.getLenders();
        for (uint256 i; i < lenders.length; i++) {
            total += pool.getLenderInfo(lenders[i]).claimableInterest;
        }
    }

    /// @dev Lenders can never be owed or paid more interest than was distributed
    ///      (up to 1 wei of rewardDebt rounding per deposit/withdraw).
    function invariant_LenderInterestNeverExceedsDistributed() public view {
        assertLe(
            _totalClaimable() + handler.ghostLenderInterestPaid(),
            handler.ghostLenderPortion() + handler.ghostRoundingActions()
        );
    }

    /// @dev Idle capital, unwithdrawn protocol interest and every unclaimed lender
    ///      interest are backed by tokens the pool actually holds.
    function invariant_PoolTokenBalanceCoversObligations() public view {
        IAssetLendingPool.PoolInfo memory info = pool.getPoolInfo();
        uint256 owed =
            info.totalDeposited -
                info.totalBorrowed +
                info.totalInterestEarned -
                info.interestWithdrawn +
                _totalClaimable();
        assertGe(
            usdc.balanceOf(address(pool)) + handler.ghostRoundingActions(),
            owed
        );
    }
}
