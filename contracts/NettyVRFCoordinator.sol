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
///
///      Lifecycle of a request:
///        Pending --fulfill(valid proof)--> Fulfilled            (callback succeeded)
///        Pending --fulfill(valid proof)--> CallbackFailed       (callback reverted; words kept)
///        CallbackFailed --retry()--------> Fulfilled            (callback succeeded)
///      `fulfill` needs blockhash(requestBlock), readable for 256 blocks (~8.5 min on Base).
///      A request not fulfilled in that window can never be proven; the user is made whole by
///      PackMachine.adminForceRefundPendingOpen after 24 h. `retry` does not need the block
///      hash (the randomness is already stored), so a CallbackFailed request stays deliverable.
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
        CallbackFailed
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
    mapping(uint256 requestId => Request) private _requests;
    /// @dev VRF output kept for requests whose callback reverted, so `retry` can redeliver.
    mapping(uint256 requestId => uint256) private _storedRandomness;

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
    /// @notice Emitted when a proof is accepted. `success` is the router callback result.
    event RandomWordsFulfilled(
        uint256 indexed requestId,
        uint256 randomness,
        bool success
    );
    /// @notice Emitted when a previously failed callback is redelivered successfully.
    event RandomWordsRedelivered(uint256 indexed requestId);
    event KeyRegistered(bytes32 indexed keyHash, uint256[2] publicKey);
    event RouterAuthorized(address indexed router, bool authorized);

    // =========================================================================
    // Errors
    // =========================================================================

    error NettyVRFCoordinator__UnauthorizedRouter(address caller);
    error NettyVRFCoordinator__NoKeyRegistered();
    error NettyVRFCoordinator__InvalidNumWords(uint32 numWords);
    error NettyVRFCoordinator__InvalidCallbackGasLimit(uint32 callbackGasLimit);
    error NettyVRFCoordinator__UnknownRequest(uint256 requestId);
    error NettyVRFCoordinator__TooEarly(uint256 requestId);
    error NettyVRFCoordinator__BlockhashUnavailable(uint256 requestId);
    error NettyVRFCoordinator__WrongKey(uint256 requestId);
    error NettyVRFCoordinator__WrongPreSeed(uint256 requestId);
    error NettyVRFCoordinator__NotRetryable(uint256 requestId);
    error NettyVRFCoordinator__CallbackReverted(uint256 requestId);
    error NettyVRFCoordinator__ZeroAddress();
    error NettyVRFCoordinator__InvalidPublicKey();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param initialOwner The admin (protocol Safe). Keys and routers are registered by it.
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
    // Fulfilment (permissionless: only a valid proof can pass)
    // =========================================================================

    /// @notice Verify a VRF proof for a pending request and deliver its words to the router.
    /// @dev `proof.seed` must be the request's preSeed; the proof itself is over
    ///      keccak256(abi.encodePacked(preSeed, blockhash(requestBlock))). A request that is
    ///      already Fulfilled or CallbackFailed is a no-op (returns false), so concurrent
    ///      fulfillers cannot double-deliver. A reverting router callback does not revert
    ///      this call: the words are stored and the request becomes retryable.
    /// @return delivered True if this call delivered the words successfully.
    function fulfill(
        uint256 requestId,
        Proof memory proof
    ) external returns (bool delivered) {
        Request storage r = _requests[requestId];
        Status status = r.status;
        if (status == Status.None)
            revert NettyVRFCoordinator__UnknownRequest(requestId);
        if (status != Status.Pending) return false;

        uint256 blockNum = r.blockNum;
        if (block.number <= blockNum)
            revert NettyVRFCoordinator__TooEarly(requestId);
        bytes32 blockHash = blockhash(blockNum);
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

        // Effects before the external call.
        r.status = Status.Fulfilled;
        delivered = _deliver(requestId, r, randomness);
        if (!delivered) {
            r.status = Status.CallbackFailed;
            _storedRandomness[requestId] = randomness;
        }
        emit RandomWordsFulfilled(requestId, randomness, delivered);
    }

    /// @notice Redeliver the stored words of a request whose callback reverted.
    /// @dev Permissionless and deterministic: the words were fixed by the verified proof.
    ///      Works after the 256-block window. `gasLimit` may raise (never lower) the gas
    ///      forwarded, so an undersized router gas limit cannot strand a request. Reverts,
    ///      leaving the request retryable, if the callback reverts again. After an admin
    ///      force-refund the PackMachine rejects the callback, so retry reverts harmlessly.
    function retry(uint256 requestId, uint32 gasLimit) external {
        Request storage r = _requests[requestId];
        if (r.status != Status.CallbackFailed)
            revert NettyVRFCoordinator__NotRetryable(requestId);
        if (
            gasLimit < r.callbackGasLimit || gasLimit > MAX_CALLBACK_GAS_LIMIT
        ) {
            revert NettyVRFCoordinator__InvalidCallbackGasLimit(gasLimit);
        }
        uint256 randomness = _storedRandomness[requestId];

        r.status = Status.Fulfilled;
        delete _storedRandomness[requestId];
        if (!_deliverWithGas(requestId, r, randomness, gasLimit)) {
            revert NettyVRFCoordinator__CallbackReverted(requestId);
        }
        emit RandomWordsRedelivered(requestId);
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Set the public key that NEW requests are bound to. Pending requests keep the
    ///         key recorded when they were made, so rotating never strands them.
    function registerKey(uint256[2] calldata publicKey) external onlyOwner {
        uint256[2] memory pk = publicKey;
        if (!_isOnCurve(pk)) revert NettyVRFCoordinator__InvalidPublicKey();
        bytes32 keyHash = keccak256(abi.encode(pk));
        currentKeyHash = keyHash;
        emit KeyRegistered(keyHash, pk);
    }

    /// @notice Allow or revoke a router. Revoking stops new requests only; pending requests
    ///         remain fulfillable and deliver to the router recorded on the request.
    function setRouter(address router, bool authorized) external onlyOwner {
        if (router == address(0)) revert NettyVRFCoordinator__ZeroAddress();
        _authorizedRouters[router] = authorized;
        emit RouterAuthorized(router, authorized);
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

    /// @notice keccak256(abi.encode(publicKey)), the value recorded as a request's keyHash.
    function hashOfKey(
        uint256[2] calldata publicKey
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(publicKey));
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _deliver(
        uint256 requestId,
        Request storage r,
        uint256 randomness
    ) private returns (bool) {
        return _deliverWithGas(requestId, r, randomness, r.callbackGasLimit);
    }

    /// @dev Calls router.rawFulfillRandomWords with exactly `gasLimit` gas. CallWithExactGas
    ///      reverts the whole transaction (rather than returning false) if the caller did not
    ///      supply enough gas, so a fulfiller cannot starve the callback to force a failure.
    function _deliverWithGas(
        uint256 requestId,
        Request storage r,
        uint256 randomness,
        uint256 gasLimit
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
                gasLimit,
                GAS_FOR_CALL_EXACT_CHECK
            );
    }
}
