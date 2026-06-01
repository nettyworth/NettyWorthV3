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

// Minimal mock PackMachine: accepts depositFromPool and pulls the NFT.
contract MockPackMachineForConfig {
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
contract MockPackMachineFactoryForConfig {
    mapping(address => bool) private _machines;

    function register(address machine) external {
        _machines[machine] = true;
    }

    function isPackMachine(address machine) external view returns (bool) {
        return _machines[machine];
    }
}

/// @dev Focused test suite for AssetLendingPoolConfig — the abstract storage +
///      admin-config base that AssetLendingPool inherits. Exercised through an
///      AssetLendingPool proxy following the same deployment conventions as
///      AssetLendingPool.t.sol. Concentrates on functions not already covered
///      by the AssetLendingPool integration tests.
contract AssetLendingPoolConfigTest is Test {
    AssetLendingPool internal pool;
    AssetNFT internal assetNFT;
    PermissionManager internal pm;
    MockERC20 internal usdc;
    MockPackMachineForConfig internal mockMachine;
    MockPackMachineFactoryForConfig internal mockFactory;

    address internal admin = makeAddr("admin");
    address internal minter = makeAddr("minter");
    address internal forwarder = makeAddr("forwarder");
    address internal borrower = makeAddr("borrower");
    address internal unauthorized = makeAddr("unauthorized");

    uint256 internal constant APPRAISAL_VALUE = 1000e6; // 1000 USDC
    uint256 internal constant LTV_BPS = 5000; // 50%

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

        // Deploy mock PackMachine infrastructure (required by initialize)
        mockMachine = new MockPackMachineForConfig(address(assetNFT));
        mockFactory = new MockPackMachineFactoryForConfig();
        mockFactory.register(address(mockMachine));

        // AssetLendingPool
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
                    8000,
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

    // =========================================================================
    // setEligibilityControls
    // =========================================================================

    function test_SetEligibilityControls_SetsMinValues() public {
        uint256[] memory add = new uint256[](0);
        uint256[] memory rem = new uint256[](0);
        vm.prank(admin);
        pool.setEligibilityControls(500e6, 8, add, rem);

        IAssetLendingPool.PoolInfo memory info = pool.getPoolInfo();
        assertEq(info.minAppraisalValue, 500e6);
        assertEq(info.minGrade, 8);
    }

    function test_SetEligibilityControls_EmitsEvent() public {
        uint256[] memory empty = new uint256[](0);
        vm.expectEmit(false, false, false, true);
        emit IAssetLendingPool.EligibilityControlsUpdated(300e6, 5);
        vm.prank(admin);
        pool.setEligibilityControls(300e6, 5, empty, empty);
    }

    function test_SetEligibilityControls_AddCategoryMakesTokenEligible()
        public
    {
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, APPRAISAL_VALUE, 5, 1); // category 1

        // category 1 not yet whitelisted → ineligible
        assertFalse(pool.isEligible(tokenId));

        uint256[] memory add = new uint256[](1);
        uint256[] memory rem = new uint256[](0);
        add[0] = 1;
        vm.prank(admin);
        pool.setEligibilityControls(0, 0, add, rem);

        assertTrue(pool.isEligible(tokenId));
    }

    function test_SetEligibilityControls_RemoveCategoryMakesTokenIneligible()
        public
    {
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, APPRAISAL_VALUE, 5, 1); // category 1

        // First whitelist category 1
        uint256[] memory add = new uint256[](1);
        uint256[] memory empty = new uint256[](0);
        add[0] = 1;
        vm.prank(admin);
        pool.setEligibilityControls(0, 0, add, empty);
        assertTrue(pool.isEligible(tokenId));

        // Then remove it
        uint256[] memory rem = new uint256[](1);
        rem[0] = 1;
        vm.prank(admin);
        pool.setEligibilityControls(0, 0, empty, rem);
        assertFalse(pool.isEligible(tokenId));
    }

    function test_SetEligibilityControls_CategoryZeroAlwaysAllowed() public {
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, APPRAISAL_VALUE, 0, 0); // category 0

        // No categories whitelisted; category 0 is exempt from whitelist check
        uint256[] memory empty = new uint256[](0);
        vm.prank(admin);
        pool.setEligibilityControls(0, 0, empty, empty);

        assertTrue(pool.isEligible(tokenId));
    }

    function test_SetEligibilityControls_BelowMinAppraisalValueIneligible()
        public
    {
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, 100e6, 0, 0); // value = 100 USDC

        uint256[] memory empty = new uint256[](0);
        vm.prank(admin);
        pool.setEligibilityControls(200e6, 0, empty, empty); // require >= 200

        assertFalse(pool.isEligible(tokenId));
    }

    function test_SetEligibilityControls_BelowMinGradeIneligible() public {
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, APPRAISAL_VALUE, 3, 0); // grade = 3

        uint256[] memory empty = new uint256[](0);
        vm.prank(admin);
        pool.setEligibilityControls(0, 7, empty, empty); // require grade >= 7

        assertFalse(pool.isEligible(tokenId));
    }

    function test_SetEligibilityControls_OnlyOwner() public {
        uint256[] memory empty = new uint256[](0);
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setEligibilityControls(0, 0, empty, empty);
    }

    // =========================================================================
    // setLtvBps
    // =========================================================================

    function test_SetLtvBps_UpdatesValue() public {
        vm.prank(admin);
        pool.setLtvBps(7000);
        assertEq(pool.getPoolInfo().ltvBps, 7000);
    }

    function test_SetLtvBps_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IAssetLendingPool.LtvUpdated(LTV_BPS, 7000);
        vm.prank(admin);
        pool.setLtvBps(7000);
    }

    function test_SetLtvBps_RecalculatesGetMaxLoanAmount() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId); // 1000 USDC at 50% LTV → max = 500

        assertEq(pool.getMaxLoanAmount(tokenId), 500e6);

        vm.prank(admin);
        pool.setLtvBps(7000); // raise to 70%

        assertEq(pool.getMaxLoanAmount(tokenId), 700e6);
    }

    function test_SetLtvBps_RevertsOnZero() public {
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InvalidLTV.selector
        );
        vm.prank(admin);
        pool.setLtvBps(0);
    }

    function test_SetLtvBps_RevertsIfExceedsBps() public {
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InvalidLTV.selector
        );
        vm.prank(admin);
        pool.setLtvBps(10_001);
    }

    function test_SetLtvBps_AllowsExactMaxBps() public {
        // 10_000 == 100% LTV — should be accepted (boundary)
        vm.prank(admin);
        pool.setLtvBps(10_000);
        assertEq(pool.getPoolInfo().ltvBps, 10_000);
    }

    function test_SetLtvBps_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setLtvBps(7000);
    }

    // =========================================================================
    // setOriginationFee
    // =========================================================================

    function test_SetOriginationFee_StoresValues() public {
        address feeWallet = makeAddr("feeWallet");
        vm.prank(admin);
        pool.setOriginationFee(200, feeWallet);

        IAssetLendingPool.PoolInfo memory info = pool.getPoolInfo();
        assertEq(info.originationFeeBps, 200);
        assertEq(info.feeWallet, feeWallet);
    }

    function test_SetOriginationFee_EmitsEvent() public {
        address feeWallet = makeAddr("feeWallet");
        vm.expectEmit(false, false, false, true);
        emit IAssetLendingPool.OriginationFeeUpdated(200, feeWallet);
        vm.prank(admin);
        pool.setOriginationFee(200, feeWallet);
    }

    function test_SetOriginationFee_ZeroBpsWithZeroWalletAllowed() public {
        // bps = 0 → wallet is ignored; address(0) must not revert
        vm.prank(admin);
        pool.setOriginationFee(0, address(0));
        assertEq(pool.getPoolInfo().originationFeeBps, 0);
    }

    function test_SetOriginationFee_RevertsIfBpsExceedsBps() public {
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__InvalidBps.selector
        );
        vm.prank(admin);
        pool.setOriginationFee(10_001, makeAddr("feeWallet"));
    }

    function test_SetOriginationFee_RevertsIfNonZeroBpsAndZeroWallet() public {
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ZeroAddress.selector
        );
        vm.prank(admin);
        pool.setOriginationFee(100, address(0));
    }

    function test_SetOriginationFee_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setOriginationFee(100, makeAddr("feeWallet"));
    }

    // =========================================================================
    // setTermConfig
    // =========================================================================

    function test_SetTermConfig_RevertsOnZeroDuration() public {
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ZeroAmount.selector
        );
        vm.prank(admin);
        pool.setTermConfig(0, 0, 1000, true);
    }

    function test_SetTermConfig_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setTermConfig(0, 7 days, 1000, true);
    }

    // =========================================================================
    // batchSetAppraisals
    // =========================================================================

    function test_BatchSetAppraisals_RevertsIfArrayLengthMismatch() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory vals = new uint256[](1); // mismatched length
        uint256[] memory grades = new uint256[](2);
        uint256[] memory cats = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        vals[0] = 100e6;

        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ArrayLengthMismatch.selector
        );
        vm.prank(admin);
        pool.batchSetAppraisals(ids, vals, grades, cats);
    }

    function test_BatchSetAppraisals_OnlyOwner() public {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory vals = new uint256[](1);
        uint256[] memory grades = new uint256[](1);
        uint256[] memory cats = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.batchSetAppraisals(ids, vals, grades, cats);
    }

    // =========================================================================
    // setDefaultLifecycleConfig
    // =========================================================================

    function test_SetDefaultLifecycleConfig_UpdatesWindows() public {
        vm.prank(admin);
        pool.setDefaultLifecycleConfig(48 hours, 14 days);

        IAssetLendingPool.PoolInfo memory info = pool.getPoolInfo();
        assertEq(info.acquisitionWindow, 48 hours);
        assertEq(info.auctionWindow, 14 days);
    }

    function test_SetDefaultLifecycleConfig_EmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit IAssetLendingPool.DefaultLifecycleConfigUpdated(48 hours, 14 days);
        vm.prank(admin);
        pool.setDefaultLifecycleConfig(48 hours, 14 days);
    }

    function test_SetDefaultLifecycleConfig_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setDefaultLifecycleConfig(48 hours, 14 days);
    }

    // =========================================================================
    // setPackMachineFactory
    // =========================================================================

    function test_SetPackMachineFactory_RevertsOnZeroAddress() public {
        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ZeroAddress.selector
        );
        vm.prank(admin);
        pool.setPackMachineFactory(address(0));
    }

    function test_SetPackMachineFactory_EmitsEvent() public {
        address newFactory = makeAddr("newFactory");
        vm.expectEmit(false, false, false, true);
        emit IAssetLendingPool.PackMachineFactoryUpdated(newFactory);
        vm.prank(admin);
        pool.setPackMachineFactory(newFactory);
    }

    function test_SetPackMachineFactory_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setPackMachineFactory(makeAddr("newFactory"));
    }

    // =========================================================================
    // setDefaultPackMachine
    // =========================================================================

    function test_SetDefaultPackMachine_SetsMachineAndEmitsEvent() public {
        address machine = makeAddr("machine");
        vm.expectEmit(false, false, false, true);
        emit IAssetLendingPool.DefaultPackMachineUpdated(machine);
        vm.prank(admin);
        pool.setDefaultPackMachine(machine);
    }

    function test_SetDefaultPackMachine_ClearsWithZeroAddress() public {
        // address(0) is valid (clears the default machine)
        vm.expectEmit(false, false, false, true);
        emit IAssetLendingPool.DefaultPackMachineUpdated(address(0));
        vm.prank(admin);
        pool.setDefaultPackMachine(address(0));
    }

    function test_SetDefaultPackMachine_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setDefaultPackMachine(makeAddr("machine"));
    }

    // =========================================================================
    // setTokenTier
    // =========================================================================

    function test_SetTokenTier_EmitsEvent() public {
        uint256 tokenId = 42;
        uint8 tier = 3;
        vm.expectEmit(true, false, false, true);
        emit IAssetLendingPool.TokenTierSet(tokenId, tier);
        vm.prank(admin);
        pool.setTokenTier(tokenId, tier);
    }

    function test_SetTokenTier_OnlyOwner() public {
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.setTokenTier(1, 1);
    }

    // =========================================================================
    // batchSetTokenTiers
    // =========================================================================

    function test_BatchSetTokenTiers_HappyPath() public {
        uint256[] memory tokenIds = new uint256[](2);
        uint8[] memory tiers = new uint8[](2);
        tokenIds[0] = 10;
        tokenIds[1] = 20;
        tiers[0] = 1;
        tiers[1] = 2;

        // Verify both TokenTierSet events are emitted
        vm.expectEmit(true, false, false, true);
        emit IAssetLendingPool.TokenTierSet(10, 1);
        vm.expectEmit(true, false, false, true);
        emit IAssetLendingPool.TokenTierSet(20, 2);
        vm.prank(admin);
        pool.batchSetTokenTiers(tokenIds, tiers);
    }

    function test_BatchSetTokenTiers_RevertsIfTooLarge() public {
        uint256[] memory tokenIds = new uint256[](51);
        uint8[] memory tiers = new uint8[](51);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAssetLendingPool.AssetLendingPool__BatchTooLarge.selector,
                51,
                50
            )
        );
        vm.prank(admin);
        pool.batchSetTokenTiers(tokenIds, tiers);
    }

    function test_BatchSetTokenTiers_RevertsIfArrayLengthMismatch() public {
        uint256[] memory tokenIds = new uint256[](2);
        uint8[] memory tiers = new uint8[](1); // mismatched length
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        tiers[0] = 1;

        vm.expectRevert(
            IAssetLendingPool.AssetLendingPool__ArrayLengthMismatch.selector
        );
        vm.prank(admin);
        pool.batchSetTokenTiers(tokenIds, tiers);
    }

    function test_BatchSetTokenTiers_OnlyOwner() public {
        uint256[] memory tokenIds = new uint256[](1);
        uint8[] memory tiers = new uint8[](1);
        tokenIds[0] = 1;
        tiers[0] = 1;
        vm.expectRevert();
        vm.prank(unauthorized);
        pool.batchSetTokenTiers(tokenIds, tiers);
    }

    // =========================================================================
    // View: getAppraisal
    // =========================================================================

    function test_GetAppraisal_ReturnsStoredValues() public {
        uint256 tokenId = _mintNFT(borrower);
        vm.prank(admin);
        pool.setAppraisal(tokenId, 800e6, 9, 2);

        IAssetLendingPool.AssetAppraisal memory a = pool.getAppraisal(tokenId);
        assertEq(a.value, 800e6);
        assertEq(a.grade, 9);
        assertEq(a.category, 2);
        assertGt(a.updatedAt, 0);
    }

    function test_GetAppraisal_ReturnsZeroStructForUnknownToken() public view {
        IAssetLendingPool.AssetAppraisal memory a = pool.getAppraisal(999);
        assertEq(a.value, 0);
        assertEq(a.updatedAt, 0);
    }

    // =========================================================================
    // View: getMaxLoanAmount
    // =========================================================================

    function test_GetMaxLoanAmount_ReflectsCurrentLtv() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId); // 1000 USDC, LTV = 50%
        assertEq(pool.getMaxLoanAmount(tokenId), 500e6);
    }

    function test_GetMaxLoanAmount_ZeroForUnappraisedToken() public view {
        assertEq(pool.getMaxLoanAmount(999), 0);
    }

    // =========================================================================
    // View: isEligible
    // =========================================================================

    function test_IsEligible_FalseBeforeAppraisal() public view {
        assertFalse(pool.isEligible(999));
    }

    function test_IsEligible_TrueAfterAppraisal() public {
        uint256 tokenId = _mintNFT(borrower);
        assertFalse(pool.isEligible(tokenId));
        _appraise(tokenId);
        assertTrue(pool.isEligible(tokenId));
    }

    function test_IsEligible_NotAffectedByStaleness() public {
        uint256 tokenId = _mintNFT(borrower);
        _appraise(tokenId);

        vm.warp(block.timestamp + 365 days); // far past the default 7-day max age

        // isEligible only checks value/grade/category — staleness is a borrow-time check
        assertTrue(pool.isEligible(tokenId));
    }
}
