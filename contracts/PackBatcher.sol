// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PermissionConsumer} from "./PermissionConsumer.sol";
import {Roles} from "./lib/Roles.sol";
import {IPackMachine} from "./interfaces/IPackMachine.sol";
import {IPackMachineFactory} from "./interfaces/IPackMachineFactory.sol";

/// @title PackBatcher
/// @author NettyWorth
/// @notice Opens N packs on a single PackMachine clone in one transaction.
/// @dev Exists because card checkout (Coinflow) executes exactly one `{to, data}` per settlement,
///      while `PackMachine.openPack` opens exactly one pack and pulls USDC from `msg.sender`.
///      Buying N packs by card therefore charged N and delivered 1. Since `PackMachine` is an
///      EIP-1167 clone (not upgradeable), a batch entrypoint cannot be added to live machines —
///      so the batching contract must be the one named as `to`, receive the funds, and loop.
///
///      Generic batchers do not work here: Multicall3, ERC-4337 accounts and Safe's MultiSend all
///      make the batching contract the `msg.sender` seen by `openPack`, so they would have to hold
///      and approve the USDC themselves. For a permissionless shared contract that means a standing
///      allowance any third party can spend. This contract avoids that by pulling funds from
///      `msg.sender` inside the same call, approving exactly the target machine, and zeroing the
///      approval before returning — so a caller can only ever spend their own USDC.
///
///      UUPS upgradeable. Access control via PermissionConsumer/PermissionManager (not Ownable).
///      ERC-7201 namespaced storage prevents upgrade slot collisions.
/// @custom:security-contact security@nettyworth.io
contract PackBatcher is
    Initializable,
    UUPSUpgradeable,
    PermissionConsumer,
    ReentrancyGuard,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Maximum packs openable in a single batch. Bounds gas so a batch cannot exceed the
    ///         block limit or a relayer's per-transaction gas cap — each open makes its own VRF request.
    uint256 public constant MAX_BATCH = 20;

    // =========================================================================
    // Storage (ERC-7201)
    // =========================================================================

    /// @custom:storage-location erc7201:nettyworth.storage.PackBatcher
    struct PackBatcherStorage {
        /// @dev PackMachineFactory proxy — the source of truth for `isPackMachine` and `paymentToken`.
        address factory;
    }

    // keccak256(abi.encode(uint256(keccak256("nettyworth.storage.PackBatcher")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PACK_BATCHER_STORAGE_SLOT =
        0x93485f7f7f57f1dc5ee1642f92cf0cd34a374fbaa10671541809290a329ac900;

    function _getStorage()
        private
        pure
        returns (PackBatcherStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := PACK_BATCHER_STORAGE_SLOT
        }
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted once per successful batch.
    /// @param machine The PackMachine clone the packs were opened on.
    /// @param user    Recipient of the won cards.
    /// @param payer   Account the USDC was pulled from (`msg.sender`).
    /// @param packId  Which pack was opened.
    /// @param count   Number of packs opened.
    /// @param spent   USDC actually consumed by the machine, net of any refund.
    event PacksOpened(
        address indexed machine,
        address indexed user,
        address indexed payer,
        uint256 packId,
        uint256 count,
        uint256 spent
    );

    /// @notice Emitted when the configured PackMachineFactory changes.
    /// @param oldFactory Previously configured factory.
    /// @param newFactory Newly configured factory.
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);

    // =========================================================================
    // Errors
    // =========================================================================

    error PackBatcher__ZeroAddress();
    /// @dev Thrown when the batch is empty or exceeds MAX_BATCH.
    error PackBatcher__InvalidBatchSize(uint256 count, uint256 maxBatch);
    /// @dev Thrown when `machine` is not a clone produced by the configured factory.
    error PackBatcher__UnknownMachine(address machine);
    /// @dev Thrown when the payer has approved or holds no payment token at all.
    error PackBatcher__NoFunds();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @notice Initializes the batcher, binding it to a PermissionManager and a PackMachineFactory.
    /// @param permissionManager_ Address of the deployed PermissionManager proxy.
    /// @param factory_           Address of the deployed PackMachineFactory proxy.
    function initialize(
        address permissionManager_,
        address factory_
    ) external initializer {
        if (factory_ == address(0)) revert PackBatcher__ZeroAddress();

        __PermissionConsumer_init(permissionManager_);
        __Pausable_init();

        _getStorage().factory = factory_;
    }

    // =========================================================================
    // UUPS upgrade authorization
    // =========================================================================

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyProtocolRole(Roles.UPGRADER_ROLE) {}

    // =========================================================================
    // Batch open
    // =========================================================================

    /// @notice Open `signatures.length` packs on `machine`, paying from `msg.sender`.
    /// @dev Each element of `signatures` must be an EIP-712 `OpenPack` signature for the *consecutive*
    ///      nonce it will be checked against: `openNonces[user]`, `+1`, `+2`, … The machine reads and
    ///      increments that counter on every open (keyed on `user`, not on the caller), so the batch
    ///      reverts wholesale if the signatures are out of order or if `user` opened a pack elsewhere
    ///      between signing and execution.
    ///
    ///      `codeId` is applied to the FIRST open only; the rest pass `bytes32(0)`. A promo code is
    ///      redeemed on-chain by that first open, and a `oncePerUser` code would revert on the second.
    ///      This mirrors the wallet path, which sends the code only on pack #1.
    ///
    ///      Funds: pulls up to `maxSpend`, capped by what the payer has actually approved and holds,
    ///      so a rounding gap between an off-chain USD charge and the on-chain price cannot revert an
    ///      otherwise-valid batch. Anything the machine does not consume — e.g. a first-open discount
    ///      that applied to pack #0 only — is refunded to the payer before returning. If the amount
    ///      pulled is short of the true total, a later `openPack` reverts and the whole batch unwinds;
    ///      there are no partial opens.
    /// @param machine    PackMachine clone to open on. Must be registered with the configured factory.
    /// @param user       Recipient of the won cards. May differ from the payer.
    /// @param packId     Which pack to open, `count` times.
    /// @param signatures One play signature per pack, in consecutive-nonce order.
    /// @param codeId     Promo code id for the first open; `bytes32(0)` for none.
    /// @param maxSpend   Upper bound on payment-token pulled from `msg.sender`.
    function openPacks(
        address machine,
        address user,
        uint256 packId,
        bytes[] calldata signatures,
        bytes32 codeId,
        uint256 maxSpend
    ) external nonReentrant whenNotPaused {
        uint256 count = signatures.length;
        if (count == 0 || count > MAX_BATCH) {
            revert PackBatcher__InvalidBatchSize(count, MAX_BATCH);
        }

        IPackMachineFactory factory_ = IPackMachineFactory(
            _getStorage().factory
        );
        // Restricts approvals to genuine clones — this contract must never approve an arbitrary address.
        if (!factory_.isPackMachine(machine)) {
            revert PackBatcher__UnknownMachine(machine);
        }

        IERC20 token = IERC20(factory_.paymentToken());

        // Measure the delta rather than the raw balance, so USDC donated to this contract is not
        // swept to whoever calls next. Stranded dust is recoverable via `rescueERC20`.
        uint256 balanceBefore = token.balanceOf(address(this));

        uint256 pull = Math.min(
            maxSpend,
            Math.min(
                token.allowance(msg.sender, address(this)),
                token.balanceOf(msg.sender)
            )
        );
        if (pull == 0) revert PackBatcher__NoFunds();

        token.safeTransferFrom(msg.sender, address(this), pull);
        token.forceApprove(machine, pull);

        for (uint256 i; i < count; ++i) {
            IPackMachine(machine).openPack(
                user,
                packId,
                signatures[i],
                i == 0 ? codeId : bytes32(0)
            );
        }

        // Leave no allowance behind, whatever the machine consumed.
        token.forceApprove(machine, 0);

        uint256 remaining = token.balanceOf(address(this)) - balanceBefore;
        if (remaining > 0) {
            token.safeTransfer(msg.sender, remaining);
        }

        emit PacksOpened(
            machine,
            user,
            msg.sender,
            packId,
            count,
            pull - remaining
        );
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function pause() external onlyProtocolRole(Roles.PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyProtocolRole(Roles.PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Repoints this batcher at a new PackMachineFactory.
    function setFactory(
        address factory_
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        if (factory_ == address(0)) revert PackBatcher__ZeroAddress();
        PackBatcherStorage storage $ = _getStorage();
        address old = $.factory;
        $.factory = factory_;
        emit FactoryUpdated(old, factory_);
    }

    /// @notice Sweeps tokens stranded on this contract to the caller.
    /// @dev This contract holds no balance between calls by design — `openPacks` refunds whatever
    ///      the machine did not consume before returning. Anything here is a stray transfer.
    function rescueERC20(
        address token
    ) external onlyProtocolRole(Roles.DEFAULT_ADMIN_ROLE) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;
        IERC20(token).safeTransfer(msg.sender, balance);
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Returns the configured PackMachineFactory address.
    function factory() external view returns (address) {
        return _getStorage().factory;
    }

    // =========================================================================
    // Context resolution
    // =========================================================================

    /// @dev Not ERC-2771 — this contract is called directly by the payer (a card-settlement relayer
    ///      or a user wallet), and `msg.sender` must stay the account the USDC is pulled from.
    function _msgSender()
        internal
        view
        override(PermissionConsumer, ContextUpgradeable)
        returns (address)
    {
        return msg.sender;
    }
}
