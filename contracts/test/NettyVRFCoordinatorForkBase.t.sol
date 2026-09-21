// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VRF} from "@chainlink/contracts/src/v0.8/vrf/VRF.sol";
import {NettyVRFCoordinator} from "../NettyVRFCoordinator.sol";
import {PackTypes} from "../lib/PackTypes.sol";

interface IRouterFork {
    function vrfCoordinator() external view returns (address);
    function setVRFCoordinator(address) external;
    function setRequestConfirmations(uint16) external;
    function setCallbackGasLimit(uint32) external;
    function setCoordinator(address) external;
}

interface IMachineFork {
    function openPack(
        address user,
        uint256 packId,
        bytes calldata signature
    ) external;
    function getUserInfo(
        address user
    ) external view returns (uint256 openNonce, bool claimedFirstOpenDiscount);
    function getPackAvailable(uint256 packId) external view returns (uint256);
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
    function adminForceRefundPendingOpen(uint256 requestId) external;
    function rescueERC20(address token) external;
}

interface IRegistryFork {
    function getPack(
        address machine,
        uint256 packId
    ) external view returns (PackTypes.Pack memory);
}

interface IPermissionManagerFork {
    function grantRole(bytes32 role, address account) external;
}

/// @title Shared fixture for the NettyVRFCoordinator fork tests
/// @notice Runs against the DEPLOYED Base staging PackVRFRouter, PackMachine, PackFulfillLib,
///         registry and PermissionManager (no modified copies). Proofs come from the TypeScript
///         prover (scripts/vrf/ecvrf.ts) via FFI, the same code the fulfiller runs.
/// @dev Opt-in (needs an archive-capable Base RPC and FFI):
///        VRF_FORK_TESTS=1 BASE_FORK_RPC_URL=https://base.drpc.org \
///          forge test --ffi --match-path 'contracts/test/NettyVRFCoordinator*.t.sol' -vv
///      Skipped otherwise, so `npx hardhat test solidity` is unaffected.
abstract contract NettyVRFCoordinatorForkBase is Test {
    uint256 internal constant FORK_BLOCK = 51_612_545;
    address internal constant SAFE = 0xfe78E8aa8f4B9f616e05a94604aB86A7B192f456;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant CHAINLINK_COORDINATOR =
        0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;
    address internal constant HISTORY =
        0x0000F90827F1C53a10cb7A02335B175320002935;

    // --- Base mainnet, staging deployment (the switch target) ---
    address internal constant STAGING_PM =
        0x3AED0BcDf2a578688d31ac394d99Fa710b780EC6;
    address internal constant STAGING_ROUTER =
        0xeA3aDEac6b82b9852a140E642BC10135638653E1;
    address internal constant STAGING_MACHINE =
        0x46999a9D321df9e752eCc007f5F67D2981183109;
    address internal constant STAGING_REGISTRY =
        0xb57233fbc2539dbD3285e95Dd28E3E40Ea670552;
    uint256 internal constant STAGING_PACK_ID = 13;

    // --- Base mainnet, production deployment. Used ONLY inside the local fork, for the
    //     refund-path tests: the staging PackMachine implementation (0xe8A1...09FA) predates
    //     adminForceRefundPendingOpen, the production one (0xFBBA...8829) has it. ---
    address internal constant PROD_PM =
        0xC4816911a267B27F4509929Be4Fc4516BDe7eC1D;
    address internal constant PROD_ROUTER =
        0x4aD5C628030546D12754F608081a6256D6c5FDc9;
    address internal constant PROD_MACHINE =
        0x8a021c02Ac5233164D7c44d87a344623A49197c5;
    address internal constant PROD_REGISTRY =
        0xb86217f0Ce896ce5bC2dC7c5B1813683f415092b;
    uint256 internal constant PROD_PACK_ID = 1;

    address internal ROUTER;
    address internal MACHINE;
    uint256 internal PACK_ID;

    bytes32 internal constant PACK_OPERATOR_ROLE = keccak256(
        "PACK_OPERATOR_ROLE"
    );
    bytes32 internal constant OPEN_PACK_TYPEHASH = keccak256(
        "OpenPack(address user,uint256 packId,uint256 nonce,bytes32 codeId)"
    );

    // Test-only keys.
    uint256 internal constant VRF_SK =
        0x5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed;
    uint256 internal constant VRF_SK_2 =
        0x7a11ce7a11ce7a11ce7a11ce7a11ce7a11ce7a11ce7a11ce7a11ce7a11ce7a11;
    uint256 internal constant SIGNER_PK = 0xA11CE;

    bytes32 internal constant REQUESTED_SIG = keccak256(
        "RandomWordsRequested(uint256,address,bytes32,uint256,uint64,uint32,uint32)"
    );
    bytes32 internal constant FULFILLED_SIG = keccak256(
        "RandomWordsFulfilled(uint256,bool)"
    );
    bytes32 internal constant CARD_WON_SIG = keccak256(
        "CardWon(address,uint256,uint256)"
    );
    bytes32 internal constant CARD_FAILED_SIG = keccak256(
        "CardFailed(address,uint256,uint256)"
    );
    bytes32 internal constant ROUTER_FULFILLED_SIG = keccak256(
        "RandomnessFulfilled(uint256,address)"
    );

    NettyVRFCoordinator internal coord;
    address internal signer;
    address internal user;
    /// @dev The allowlisted fulfiller (stands in for the fulfiller service's gas wallet).
    address internal fulfiller;
    uint256[2] internal pk1;
    uint256[2] internal pk2;
    PackTypes.Pack internal pack;

    function setUp() public virtual {
        if (!vm.envOr("VRF_FORK_TESTS", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(vm.envString("BASE_FORK_RPC_URL"), FORK_BLOCK);

        coord = new NettyVRFCoordinator(SAFE);
        pk1 = _publicKey(VRF_SK);
        pk2 = _publicKey(VRF_SK_2);
        signer = vm.addr(SIGNER_PK);
        user = makeAddr("ripper");
        fulfiller = makeAddr("fulfiller");
        deal(USDC, user, 1_000_000e6);
        vm.startPrank(SAFE);
        coord.registerKey(pk1, _registrationProof(VRF_SK, address(coord)));
        coord.setFulfiller(fulfiller, true);
        vm.stopPrank();
        _useDeployment(
            STAGING_PM,
            STAGING_ROUTER,
            STAGING_MACHINE,
            STAGING_REGISTRY,
            STAGING_PACK_ID
        );
    }

    /// @dev Performs, inside the fork, exactly the Safe batches the staging switch uses
    ///      (setRouter on the coordinator, then setVRFCoordinator + setRequestConfirmations(1)
    ///      on the router), plus a test-only PACK_OPERATOR signer for open signatures.
    function _useDeployment(
        address pm,
        address router,
        address machine,
        address registry,
        uint256 packId
    ) internal {
        ROUTER = router;
        MACHINE = machine;
        PACK_ID = packId;
        vm.startPrank(SAFE);
        coord.setRouter(router, true);
        IRouterFork(router).setVRFCoordinator(address(coord));
        IRouterFork(router).setRequestConfirmations(1);
        IPermissionManagerFork(pm).grantRole(PACK_OPERATOR_ROLE, signer);
        vm.stopPrank();
        pack = IRegistryFork(registry).getPack(machine, packId);
        vm.prank(user);
        IERC20(USDC).approve(machine, type(uint256).max);
    }

    function _useProd() internal {
        _useDeployment(
            PROD_PM,
            PROD_ROUTER,
            PROD_MACHINE,
            PROD_REGISTRY,
            PROD_PACK_ID
        );
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _fulfil(
        uint256 requestId,
        VRF.Proof memory proof
    ) internal returns (bool) {
        vm.prank(fulfiller);
        return coord.fulfill(requestId, proof);
    }

    function _open() internal returns (uint256 requestId, uint64 reqBlock) {
        return _openAs(user);
    }

    function _openAs(
        address who
    ) internal returns (uint256 requestId, uint64 reqBlock) {
        bytes memory sig = _openSignature(who);
        vm.recordLogs();
        vm.prank(who);
        IMachineFork(MACHINE).openPack(who, PACK_ID, sig);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(coord) &&
                logs[i].topics[0] == REQUESTED_SIG
            ) {
                requestId = uint256(logs[i].topics[1]);
                (, reqBlock, , ) = abi.decode(
                    logs[i].data,
                    (uint256, uint64, uint32, uint32)
                );
                return (requestId, reqBlock);
            }
        }
        revert("no RandomWordsRequested");
    }

    function _openSignature(address who) internal view returns (bytes memory) {
        (uint256 nonce, ) = IMachineFork(MACHINE).getUserInfo(who);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("PackMachine"),
                keccak256("1"),
                block.chainid,
                MACHINE
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(OPEN_PACK_TYPEHASH, who, PACK_ID, nonce, bytes32(0))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            SIGNER_PK,
            keccak256(abi.encodePacked("\x19\x01", domain, structHash))
        );
        return abi.encodePacked(r, s, v);
    }

    function _publicKey(uint256 sk) internal returns (uint256[2] memory pk) {
        Vm.Wallet memory w = vm.createWallet(sk);
        pk = [w.publicKeyX, w.publicKeyY];
    }

    function _prove(
        uint256 sk,
        uint256 preSeed,
        uint64 reqBlock
    ) internal returns (VRF.Proof memory) {
        bytes32 bh = blockhash(reqBlock);
        require(bh != bytes32(0), "request block hash unavailable");
        return _proveWithHash(sk, preSeed, bh);
    }

    function _proveWithHash(
        uint256 sk,
        uint256 preSeed,
        bytes32 bh
    ) internal returns (VRF.Proof memory) {
        return
            abi.decode(
                vm.ffi(_ffiArgs("prove", sk, vm.toString(preSeed), vm.toString(bh))),
                (VRF.Proof)
            );
    }

    function _output(
        uint256 sk,
        uint256 preSeed,
        bytes32 bh
    ) internal returns (uint256) {
        return
            abi.decode(
                vm.ffi(_ffiArgs("output", sk, vm.toString(preSeed), vm.toString(bh))),
                (uint256)
            );
    }

    /// @dev registerKey proof of possession, built by scripts/vrf/key-possession.ts.
    function _registrationProofFor(
        uint256 sk,
        uint256 chainId,
        address coordinator
    ) internal returns (VRF.Proof memory) {
        return
            abi.decode(
                vm.ffi(
                    _ffiArgs(
                        "register",
                        sk,
                        vm.toString(chainId),
                        vm.toString(coordinator)
                    )
                ),
                (VRF.Proof)
            );
    }

    function _registrationProof(
        uint256 sk,
        address coordinator
    ) internal returns (VRF.Proof memory) {
        return _registrationProofFor(sk, block.chainid, coordinator);
    }

    function _ffiArgs(
        string memory mode,
        uint256 sk,
        string memory a3,
        string memory a4
    ) internal pure returns (string[] memory a) {
        a = new string[](7);
        a[0] = "node";
        a[1] = "--experimental-strip-types";
        a[2] = "scripts/vrf/prove-ffi.ts";
        a[3] = mode;
        a[4] = vm.toString(bytes32(sk));
        a[5] = a3;
        a[6] = a4;
    }

    function _expectedWords(
        uint256 output,
        uint256 n
    ) internal pure returns (uint256[] memory words) {
        words = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            words[i] = uint256(keccak256(abi.encode(output, i)));
        }
    }

    function _countOutcome(
        Vm.Log[] memory logs,
        uint256 requestId
    )
        internal
        view
        returns (uint256 won, uint256 failed, bool routerFulfilled)
    {
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t0 = logs[i].topics[0];
            if (
                logs[i].emitter == MACHINE &&
                logs[i].topics.length == 4 &&
                uint256(logs[i].topics[3]) == requestId
            ) {
                if (t0 == CARD_WON_SIG) won++;
                else if (t0 == CARD_FAILED_SIG) failed++;
            }
            if (
                logs[i].emitter == ROUTER &&
                t0 == ROUTER_FULFILLED_SIG &&
                uint256(logs[i].topics[1]) == requestId
            ) {
                routerFulfilled = true;
            }
        }
    }

    /// @dev The RandomWordsFulfilled log for `requestId`: asserts it carries no randomness
    ///      (its data is exactly one ABI word, the success flag) and returns that flag.
    function _fulfilledLog(
        Vm.Log[] memory logs,
        uint256 requestId
    ) internal view returns (bool found, bool success) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(coord) &&
                logs[i].topics[0] == FULFILLED_SIG &&
                uint256(logs[i].topics[1]) == requestId
            ) {
                assertEq(logs[i].topics.length, 2, "only requestId indexed");
                assertEq(logs[i].data.length, 32, "event data is only the success flag");
                return (true, abi.decode(logs[i].data, (bool)));
            }
        }
    }

    function _containsPush4(
        bytes memory code,
        bytes4 sel
    ) internal pure returns (bool) {
        for (uint256 i; i + 4 < code.length; ++i) {
            if (
                code[i] == 0x63 &&
                code[i + 1] == sel[0] &&
                code[i + 2] == sel[1] &&
                code[i + 3] == sel[2] &&
                code[i + 4] == sel[3]
            ) return true;
        }
        return false;
    }

    function _status(uint256 requestId) internal view returns (uint8) {
        return uint8(coord.getRequest(requestId).status);
    }
}
