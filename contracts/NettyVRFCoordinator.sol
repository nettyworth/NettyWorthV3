// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {
    Ownable,
    Ownable2Step
} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {VRF} from "@chainlink/contracts/src/v0.8/vrf/VRF.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {CallWithExactGas} from "@chainlink/contracts/src/v0.8/shared/call/CallWithExactGas.sol";

/// @dev The consumer callback PackVRFRouter implements (Chainlink VRF v2.5 consumer ABI).
interface IVRFConsumerRawFulfill {
    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external;
}

/// @title NettyVRFCoordinator
/// @author NettyWorth
/// @notice In-house stand-in for the Chainlink VRF v2.5 coordinator. It speaks the exact
///         `requestRandomWords(RandomWordsRequest)` ABI and `rawFulfillRandomWords` callback
///         that the deployed PackVRFRouter uses, so a router can be switched to it with
///         `setVRFCoordinator` and back again without any contract upgrade.
///
///         Randomness is an ECVRF output verified on-chain with Chainlink's own verifier
///         (VRF.sol from the Chainlink contracts package, v1.1.0, MIT). Each request is bound to:
///           - the VRF public key in force when it was made (recorded as `keyHash`), and
///           - the hash of the block that contains it, so the result cannot be known before
///             the purchase transaction is sealed.
///         Given those, exactly one output is provable per request, so the key holder cannot
///         choose the result; it can only delay it.
///
/// @dev Deliberately standalone and NOT upgradeable (an exception to the repo's UUPS rule):
///      the trust argument above depends on the fulfilment logic being immutable. Access
///      control is a plain Ownable2Step owner (the protocol Safe) rather than
///      PermissionManager so this contract has no dependency on the protocol it serves.
///      Ownership cannot be renounced (that would freeze key rotation and router changes).
///
///      Lifecycle of a request (as in Chainlink VRF, a failed callback is terminal):
///        Pending --fulfill(valid proof)--> Fulfilled   (callback succeeded)
///        Pending --fulfill(valid proof)--> Failed      (callback reverted; terminal)
///      A Failed request is never redelivered and its randomness is neither stored nor
///      emitted. PackMachine draws the card from the words AND the prize pool at delivery,
///      so letting anyone choose when fixed words are delivered would let them choose the
///      card (audit F-01). The words of a Failed request are therefore discarded for good.
///
///      Who may fulfil: only allowlisted fulfillers (`setFulfiller`, owner-managed). Only the
///      VRF key holder can produce a proof, so permissionless submission gives no liveness
///      benefit; it would only let a third party replay a proof leaked by a reverted fulfil
///      transaction at a moment of its choosing (audit F-01, second trigger).
///
///      Verification window: `fulfill` needs the request block's hash. It uses `blockhash()`
///      for the last 256 blocks and, beyond that, the EIP-2935 block-hash history contract,
///      which serves the last 8191 blocks (~4.5 h on Base at 2 s blocks). A request not
///      fulfilled within BLOCKHASH_WINDOW blocks can never be proven and stays Pending.
///
///      Settling a request that can no longer be delivered (Failed, or unfulfilled past the
///      window) depends on the PackMachine behind the router, not on this contract:
///        - a PackMachine that implements adminForceRefundPendingOpen (the production
///          implementation) lets the admin refund the user 24 h after the request, with the
///          machine paused;
///        - the staging PackMachine implementation has no refund function. There the only
///          recovery is the documented manual procedure (docs: VRF staging manual-recovery
///          runbook), in which the Safe temporarily becomes the router's coordinator.
///
///      Randomness trust boundaries (audit F-05):
///        - Reorgs: fulfilment needs only one block after the request (unsafe head on Base).
///          If the request block is reorged, the request lands in a block with another hash
///          and re-rolls; any words revealed on the abandoned branch are void. Nobody gains
///          control of the outcome without the VRF key.
///        - Sequencer: it can grind the request block's hash, but cannot evaluate outcomes
///          without the VRF secret key, so grinding alone gives no advantage.
///        - Sequencer and key holder colluding could pick a block hash with a known outcome.
///          That is outside the accepted trust assumptions (the key holder is trusted not to
///          collude); this contract does not defend against it.
///
///      This contract has no function that calls the router's `setCoordinator` or
///      `setVRFCoordinator`, and no generic call/execute. The router lets its current
///      coordinator call `setCoordinator`, so the absence is load-bearing (asserted in tests).
/// @custom:security-contact security@nettyworth.io
contract NettyVRFCoordinator is VRF, Ownable2Step {
    // =========================================================================
    // Types
    // =========================================================================

    enum Status {
        None,
        Pending,
        Fulfilled,
        Failed
    }

    struct Request {
        address router;
        uint32 numWords;
        uint32 callbackGasLimit;
        uint64 blockNum;
        Status status;
        bytes32 keyHash;
        uint256 preSeed;
    }

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Upper bound on words per request (PackMachine asks for cardsPerPack words).
    uint32 public constant MAX_NUM_WORDS = 10;
    /// @notice Upper bound on the callback gas a router may request.
    uint32 public constant MAX_CALLBACK_GAS_LIMIT = 2_500_000;
    /// @notice EIP-2935 block-hash history contract (same address on every chain that has it).
    address public constant BLOCKHASH_HISTORY =
        0x0000F90827F1C53a10cb7A02335B175320002935;
    /// @notice Blocks after the request block within which a request can be proven
    ///         (EIP-2935 HISTORY_SERVE_WINDOW).
    uint256 public constant BLOCKHASH_WINDOW = 8191;
    /// @notice Domain tag of the key-registration (proof of possession) seed.
    bytes32 public constant KEY_REGISTRATION_DOMAIN =
        keccak256("NettyVRFCoordinator.registerKey");
    /// @dev Gas reserved to perform the exact-gas check before the callback (Chainlink value).
    uint16 private constant GAS_FOR_CALL_EXACT_CHECK = 5_000;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice keccak256(abi.encode(publicKey)) of the key new requests are bound to.
    bytes32 public currentKeyHash;
    /// @notice Monotonic request counter; part of every preSeed so preSeeds never repeat.
    uint256 public requestNonce;

    mapping(address router => bool) private _authorizedRouters;
    mapping(address fulfiller => bool) private _fulfillers;
    mapping(uint256 requestId => Request) private _requests;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted for every accepted request. The fulfiller needs exactly these fields.
    event RandomWordsRequested(
        uint256 indexed requestId,
        address indexed router,
        bytes32 indexed keyHash,
        uint256 preSeed,
        uint64 blockNum,
        uint32 numWords,
        uint32 callbackGasLimit
    );
    /// @notice Emitted when a proof is accepted. `success` is the router callback result;
    ///         false means the request is terminally Failed. The randomness is never emitted.
    event RandomWordsFulfilled(uint256 indexed requestId, bool success);
    event KeyRegistered(bytes32 indexed keyHash, uint256[2] publicKey);
    event RouterAuthorized(address indexed router, bool authorized);
    event FulfillerSet(address indexed fulfiller, bool allowed);

    // =========================================================================
    // Errors
    // =========================================================================

    error NettyVRFCoordinator__UnauthorizedRouter(address caller);
    error NettyVRFCoordinator__UnauthorizedFulfiller(address caller);
    error NettyVRFCoordinator__NoKeyRegistered();
    error NettyVRFCoordinator__InvalidNumWords(uint32 numWords);
    error NettyVRFCoordinator__InvalidCallbackGasLimit(uint32 callbackGasLimit);
    error NettyVRFCoordinator__UnknownRequest(uint256 requestId);
    error NettyVRFCoordinator__TooEarly(uint256 requestId);
    error NettyVRFCoordinator__BlockhashUnavailable(uint256 requestId);
    error NettyVRFCoordinator__WrongKey(uint256 requestId);
    error NettyVRFCoordinator__WrongPreSeed(uint256 requestId);
    error NettyVRFCoordinator__ZeroAddress();
    error NettyVRFCoordinator__NotAContract(address account);
    error NettyVRFCoordinator__InvalidPublicKey();
    error NettyVRFCoordinator__KeyPossessionNotProven();
    error NettyVRFCoordinator__RenounceOwnershipDisabled();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param initialOwner The admin (protocol Safe). Keys, routers and fulfillers are set by it.
    constructor(address initialOwner) Ownable(initialOwner) {}

    // =========================================================================
    // Router-facing API (Chainlink VRF v2.5 coordinator ABI)
    // =========================================================================

    /// @notice Request randomness. Same selector and struct as IVRFCoordinatorV2Plus.
    /// @dev keyHash, subId, requestConfirmations and extraArgs are accepted and ignored: the
    ///      key is the coordinator's current key, there is no billing, and fulfilment always
    ///      waits for at least one block (the request block's hash is part of the seed).
    function requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest calldata req
    ) external returns (uint256 requestId) {
        if (!_authorizedRouters[msg.sender]) {
            revert NettyVRFCoordinator__UnauthorizedRouter(msg.sender);
        }
        bytes32 keyHash = currentKeyHash;
        if (keyHash == bytes32(0))
            revert NettyVRFCoordinator__NoKeyRegistered();
        if (req.numWords == 0 || req.numWords > MAX_NUM_WORDS) {
            revert NettyVRFCoordinator__InvalidNumWords(req.numWords);
        }
        if (
            req.callbackGasLimit == 0 ||
            req.callbackGasLimit > MAX_CALLBACK_GAS_LIMIT
        ) {
            revert NettyVRFCoordinator__InvalidCallbackGasLimit(
                req.callbackGasLimit
            );
        }

        uint256 preSeed = uint256(
            keccak256(
                abi.encode(
                    block.chainid,
                    address(this),
                    msg.sender,
                    ++requestNonce
                )
            )
        );
        // Mirrors VRFCoordinatorV2_5._computeRequestId: bound to the key and the preSeed.
        requestId = uint256(keccak256(abi.encode(keyHash, preSeed)));

        _requests[requestId] = Request({
            router: msg.sender,
            numWords: req.numWords,
            callbackGasLimit: req.callbackGasLimit,
            blockNum: uint64(block.number),
            status: Status.Pending,
            keyHash: keyHash,
            preSeed: preSeed
        });

        emit RandomWordsRequested(
            requestId,
            msg.sender,
            keyHash,
            preSeed,
            uint64(block.number),
            req.numWords,
            req.callbackGasLimit
        );
    }

    // =========================================================================
    // Fulfilment (allowlisted fulfillers; only a valid proof can pass)
    // =========================================================================

    /// @notice Verify a VRF proof for a pending request and deliver its words to the router.
    /// @dev Only allowlisted fulfillers may call. `proof.seed` must be the request's preSeed;
    ///      the proof itself is over keccak256(abi.encodePacked(preSeed, blockhash(requestBlock))).
    ///      A request that is already Fulfilled or Failed is a no-op (returns false), so
    ///      concurrent fulfillers cannot double-deliver. A reverting router callback does not
    ///      revert this call: the request becomes Failed, terminally, and its randomness is
    ///      discarded. CallWithExactGas reverts the whole transaction if the caller did not
    ///      supply enough gas for the full callback limit, so a fulfiller cannot starve the
    ///      callback to force a failure.
    /// @return delivered True if this call delivered the words successfully.
    function fulfill(
        uint256 requestId,
        Proof memory proof
    ) external returns (bool delivered) {
        if (!_fulfillers[msg.sender])
            revert NettyVRFCoordinator__UnauthorizedFulfiller(msg.sender);
        Request storage r = _requests[requestId];
        Status status = r.status;
        if (status == Status.None)
            revert NettyVRFCoordinator__UnknownRequest(requestId);
        if (status != Status.Pending) return false;

        uint256 blockNum = r.blockNum;
        if (block.number <= blockNum)
            revert NettyVRFCoordinator__TooEarly(requestId);
        bytes32 blockHash = _requestBlockHash(blockNum);
        if (blockHash == bytes32(0))
            revert NettyVRFCoordinator__BlockhashUnavailable(requestId);
        if (keccak256(abi.encode(proof.pk)) != r.keyHash)
            revert NettyVRFCoordinator__WrongKey(requestId);
        if (proof.seed != r.preSeed)
            revert NettyVRFCoordinator__WrongPreSeed(requestId);

        uint256 actualSeed = uint256(
            keccak256(abi.encodePacked(r.preSeed, blockHash))
        );
        uint256 randomness = _randomValueFromVRFProof(proof, actualSeed); // reverts if invalid

        // Effects before the external call: a re-entrant fulfil sees a non-Pending request.
        r.status = Status.Fulfilled;
        delivered = _deliver(requestId, r, randomness);
        if (!delivered) r.status = Status.Failed;
        emit RandomWordsFulfilled(requestId, delivered);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Set the public key that NEW requests are bound to. Pending requests keep the
    ///         key recorded when they were made, so rotating never strands them.
    /// @dev Proof of possession: `proof` must be a valid VRF proof by `publicKey` over
    ///      `registrationSeed(publicKey)`, which binds it to this chain, this contract and this
    ///      key. Only the holder of the matching secret key can produce it, so a typo or wrong
    ///      key file cannot be registered (audit F-04). Produce it with
    ///      scripts/vrf/key-possession-proof.ts.
    function registerKey(
        uint256[2] calldata publicKey,
        Proof memory proof
    ) external onlyOwner {
        uint256[2] memory pk = publicKey;
        if (!_isOnCurve(pk)) revert NettyVRFCoordinator__InvalidPublicKey();
        uint256 seed = registrationSeed(pk);
        if (
            proof.pk[0] != pk[0] ||
            proof.pk[1] != pk[1] ||
            proof.seed != seed
        ) revert NettyVRFCoordinator__KeyPossessionNotProven();
        _randomValueFromVRFProof(proof, seed); // reverts if the proof is invalid
        bytes32 keyHash = keccak256(abi.encode(pk));
        currentKeyHash = keyHash;
        emit KeyRegistered(keyHash, pk);
    }

    /// @notice Allow or revoke a router. Revoking stops new requests only; pending requests
    ///         remain fulfillable and deliver to the router recorded on the request.
    /// @dev An authorized router must have code: a callback to a codeless address would make
    ///      every fulfil revert and strand its requests (audit F-06). Revoking accepts any
    ///      non-zero address.
    function setRouter(address router, bool authorized) external onlyOwner {
        if (router == address(0)) revert NettyVRFCoordinator__ZeroAddress();
        if (authorized && router.code.length == 0)
            revert NettyVRFCoordinator__NotAContract(router);
        _authorizedRouters[router] = authorized;
        emit RouterAuthorized(router, authorized);
    }

    /// @notice Allow or revoke an address that may submit `fulfill` transactions (the
    ///         fulfiller service's gas wallets).
    function setFulfiller(address fulfiller, bool allowed) external onlyOwner {
        if (fulfiller == address(0)) revert NettyVRFCoordinator__ZeroAddress();
        _fulfillers[fulfiller] = allowed;
        emit FulfillerSet(fulfiller, allowed);
    }

    /// @notice Disabled: without an owner, keys, routers and fulfillers could never change.
    function renounceOwnership() public pure override {
        revert NettyVRFCoordinator__RenounceOwnershipDisabled();
    }

    // =========================================================================
    // Views
    // =========================================================================

    function getRequest(
        uint256 requestId
    ) external view returns (Request memory) {
        return _requests[requestId];
    }

    function isAuthorizedRouter(address router) external view returns (bool) {
        return _authorizedRouters[router];
    }

    function isFulfiller(address fulfiller) external view returns (bool) {
        return _fulfillers[fulfiller];
    }

    /// @notice keccak256(abi.encode(publicKey)), the value recorded as a request's keyHash.
    function hashOfKey(
        uint256[2] calldata publicKey
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(publicKey));
    }

    /// @notice The seed a key-registration proof must be over:
    ///         keccak256(abi.encode(KEY_REGISTRATION_DOMAIN, chainid, this, pk[0], pk[1])).
    function registrationSeed(
        uint256[2] memory publicKey
    ) public view returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encode(
                        KEY_REGISTRATION_DOMAIN,
                        block.chainid,
                        address(this),
                        publicKey[0],
                        publicKey[1]
                    )
                )
            );
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /// @dev Hash of `blockNum`, or zero if it can no longer be read. `blockhash()` covers the
    ///      last 256 blocks. Beyond that, the EIP-2935 history contract is asked with the
    ///      32-byte block number; only a successful, exactly 32-byte, non-zero answer counts.
    ///      It reverts outside its window and has no code on chains without EIP-2935, which
    ///      both read as unavailable. Callers ensure block.number > blockNum.
    function _requestBlockHash(
        uint256 blockNum
    ) private view returns (bytes32 h) {
        h = blockhash(blockNum);
        if (h != bytes32(0)) return h;
        if (block.number - blockNum > BLOCKHASH_WINDOW) return bytes32(0);
        address history = BLOCKHASH_HISTORY;
        assembly ("memory-safe") {
            mstore(0x00, blockNum)
            let ok := staticcall(gas(), history, 0x00, 0x20, 0x00, 0x20)
            if and(ok, eq(returndatasize(), 0x20)) {
                h := mload(0x00)
            }
        }
    }

    /// @dev Calls router.rawFulfillRandomWords with exactly the request's callback gas limit.
    ///      CallWithExactGas reverts the whole transaction (rather than returning false) if
    ///      the caller did not supply enough gas.
    function _deliver(
        uint256 requestId,
        Request storage r,
        uint256 randomness
    ) private returns (bool) {
        uint256 n = r.numWords;
        uint256[] memory words = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            words[i] = uint256(keccak256(abi.encode(randomness, i)));
        }
        bytes memory payload = abi.encodeCall(
            IVRFConsumerRawFulfill.rawFulfillRandomWords,
            (requestId, words)
        );
        return
            CallWithExactGas._callWithExactGas(
                payload,
                r.router,
                r.callbackGasLimit,
                GAS_FOR_CALL_EXACT_CHECK
            );
    }
}
