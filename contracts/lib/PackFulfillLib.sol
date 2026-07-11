// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PackTypes} from "./PackTypes.sol";
import {PackMachineStorageLib} from "./PackMachineStorageLib.sol";
import {PackPoolLib} from "./PackPoolLib.sol";
import {IPackMachineFactory} from "../interfaces/IPackMachineFactory.sol";
import {IPackRegistry} from "../interfaces/IPackRegistry.sol";
import {IBuybackPool} from "../interfaces/IBuybackPool.sol";
import {IPromoCodeRegistry} from "../interfaces/IPromoCodeRegistry.sol";

/// @title PackFulfillLib
/// @notice Deployed library containing the body of PackMachine.fulfillRandomness.
///         Deployed as a separate contract (called via DELEGATECALL) so its bytecode
///         does NOT count toward PackMachine's 24 KiB EIP-170 limit.
/// @dev Receives a `PackMachineStorageLib.PackMachineStorage storage $` pointer from
///      PackMachine. Under delegatecall the library operates on the clone's own storage.
///      Events are declared here (LOG opcode uses address(this) = clone under delegatecall,
///      so they are attributed to the clone; topic0 is signature-derived, indexers unaffected).
library PackFulfillLib {
    using SafeERC20 for IERC20;

    uint256 private constant NUM_TIERS = 6;

    // =========================================================================
    // Events (only emitted inside fulfillRandomness; declared here so LOG has them in scope)
    // =========================================================================

    event PackOpened(
        address indexed user,
        uint256 indexed requestId,
        uint256 indexed packId,
        uint128 pricePaid
    );
    event CardWon(
        address indexed user,
        uint256 indexed tokenId,
        uint256 indexed requestId
    );
    event CardFailed(
        address indexed user,
        uint256 indexed tokenId,
        uint256 indexed requestId
    );
    /// @dev Emitted when BuybackPool.registerToken reverts after a successful card transfer.
    ///      The user already received the card; buyback registration is best-effort.
    event BuybackRegistrationFailed(
        uint256 indexed tokenId,
        uint256 indexed requestId
    );

    // =========================================================================
    // Errors (mirrored subset used inside fulfillRandomness)
    // =========================================================================

    error PackMachine__UnknownRequest();

    // =========================================================================
    // Public entry point — DELEGATECALL dispatch
    // =========================================================================

    /// @notice Execute the fulfillRandomness body.
    ///         Caller (PackMachine) is responsible for the VRF-router guard and nonReentrant.
    /// @param $        PackMachine's ERC-7201 storage pointer (operates on clone storage).
    /// @param registry Resolved PackRegistry address (from PackMachine._registry()).
    /// @param requestId  The Chainlink VRF request ID being fulfilled.
    /// @param randomWords Array of random words from VRF (one per card in the pack open).
    function fulfillRandomness(
        PackMachineStorageLib.PackMachineStorage storage $,
        address registry,
        uint256 requestId,
        uint256[] calldata randomWords
    ) public {
        PackMachineStorageLib.PendingOpen memory pending = $.pendingOpens[
            requestId
        ];
        // Guard against a late or duplicate fulfillment for a request that was already
        // settled (normally or via adminForceRefundPendingOpen). Without this check a
        // stale callback would reach `pendingRequestCount--` and double-decrement the
        // counter, potentially allowing resetEffectivePrizePoolSize to run while another
        // request is still genuinely in-flight.
        if (pending.user == address(0)) revert PackMachine__UnknownRequest();
        bytes32 pendingCodeId = $.pendingCodeIds[requestId];
        bool pendingFirstOpenDiscount = $.pendingFirstOpen[requestId];
        delete $.pendingOpens[requestId];
        delete $.pendingCodeIds[requestId];
        delete $.pendingFirstOpen[requestId];

        // Fetch pack config from registry at fulfill-time (used for pricePerPack in the
        // PackOpened event and any fields not snapshotted at request time).
        PackTypes.Pack memory pack = IPackRegistry(registry).getPack(
            address(this),
            pending.packId
        );

        IPackMachineFactory iFactory = IPackMachineFactory($.factory);
        address assetNFT = $.assetNFT;
        address pool = $.buybackPool;
        bool poolActive =
            pool != address(0) && pending.buybackAllocationBpsSnapshot > 0;

        // Compute the per-card paid amount (net of any promo / first-open discount)
        // once before the card loop. escrowedAmount is the actual USDC the buyer paid
        // for the entire open, divided equally across the requested card count.
        // Stored so the BuybackPool can price Spend-mode buybacks correctly.
        uint128 paidPerCard =
            pending.cardsCount > 0
                ? uint128(pending.escrowedAmount / pending.cardsCount)
                : 0;

        iFactory.beforeTransfer(assetNFT);

        uint256 wonCards;
        for (uint256 i; i < pending.cardsCount; ++i) {
            uint256 word = randomWords[i];

            // Compute active weights — exclude tiers empty for THIS PACK.
            uint32[6] memory activeWeights;
            uint256 totalActiveWeight;
            for (uint256 t; t < NUM_TIERS; ++t) {
                if ($.packTierPools[pending.packId][t].length == 0) continue;
                activeWeights[t] = pending.tierWeightsSnapshot[t];
                totalActiveWeight += pending.tierWeightsSnapshot[t];
            }

            if (totalActiveWeight == 0) {
                // All eligible tiers empty — restore reservations and skip.
                $.effectivePrizePoolSize++;
                $.availablePerPack[pending.packId]++;
                emit CardFailed(pending.user, 0, requestId);
                continue;
            }

            // Select tier using upper 128 bits of the random word.
            uint256 tierRand = (word >> 128) % totalActiveWeight;
            uint256 selectedTier;
            uint256 cumulative;
            for (uint256 t; t < NUM_TIERS; ++t) {
                cumulative += activeWeights[t];
                if (tierRand < cumulative) {
                    selectedTier = t;
                    break;
                }
            }

            // Select token within this pack's tier pool using lower 128 bits.
            uint256 selectedPoolLen = $
                .packTierPools[pending.packId][selectedTier]
                .length;
            uint256 index = uint128(word) % selectedPoolLen;
            uint256 tokenId = $.packTierPools[pending.packId][selectedTier][
                index
            ];

            // Remove from every pack pool it belongs to.
            // Machine-wide tier pool is intentionally absent — tier is per-pack only.
            uint256 tokenMask = $.eligibility[tokenId];
            PackPoolLib.removeFromAllPacks($, tokenId, tokenMask);
            $.inCustody[tokenId] = false;
            // Eligibility mask and packTokenTier kept dormant for depositFromPool restoration.

            // Decrement available counters for all other overlapping packs
            // (this pack's reservation was already charged at _requestVRF time).
            uint256 otherMask = tokenMask & ~(uint256(1) << pending.packId);
            PackPoolLib.adjustAvailableForMask($, otherMask, false);

            try
                IERC721(assetNFT).transferFrom(
                    address(this),
                    pending.user,
                    tokenId
                )
            {
                ++wonCards;
                emit CardWon(pending.user, tokenId, requestId);
                // Register with BuybackPool so the user can sell the card back.
                // paidPerCard is the net USDC the buyer paid per card — used by
                // BuybackPool when the machine is in Spend mode.
                // Wrapped in try/catch: a registration failure must never revert card
                // delivery — the user already owns the NFT at this point.
                if (poolActive) {
                    try
                        IBuybackPool(pool).registerToken(
                            tokenId,
                            uint8(selectedTier),
                            address(this),
                            paidPerCard
                        )
                    {} catch {
                        emit BuybackRegistrationFailed(tokenId, requestId);
                    }
                }
            } catch {
                // Transfer failed — return the card to all its pools.
                // Per-pack tiers are still in the dormant packTokenTier map, so
                // addToEligiblePacks resolves the correct tier for each pack.
                PackPoolLib.addToEligiblePacks($, tokenId, tokenMask);
                $.inCustody[tokenId] = true;
                // Restore available counters for other packs we decremented.
                PackPoolLib.adjustAvailableForMask($, otherMask, true);
                // Restore reservation for this pack.
                $.effectivePrizePoolSize++;
                $.availablePerPack[pending.packId]++;
                emit CardFailed(pending.user, tokenId, requestId);
            }
        }

        iFactory.afterTransfer(assetNFT);

        // ── Settle escrowed payment ──────────────────────────────────────────
        // Distribute the held USDC proportionally to the cards that were actually
        // won; refund the remainder to the user (failed cards are not charged).
        // Integer-division dust (at most cardsCount-1 wei) stays in the contract
        // and is sweepable via rescueERC20 (which protects totalEscrowed).
        $.totalEscrowed -= pending.escrowedAmount;
        uint256 n = pending.cardsCount;
        IERC20 paymentToken = IERC20(iFactory.paymentToken());
        if (wonCards > 0 && pending.escrowedAmount > 0) {
            uint256 settled = (pending.escrowedAmount * wonCards) / n;
            uint256 buybackShare = (pending.buybackAmount * wonCards) / n;
            uint256 financeShare = settled - buybackShare;
            if (buybackShare > 0 && pool != address(0)) {
                paymentToken.safeTransfer(pool, buybackShare);
            }
            if (financeShare > 0) {
                paymentToken.safeTransfer(
                    iFactory.financeWallet(),
                    financeShare
                );
            }
            uint256 refund = pending.escrowedAmount - settled;
            if (refund > 0) {
                paymentToken.safeTransfer(pending.user, refund);
            }
        } else if (pending.escrowedAmount > 0) {
            // All cards failed — refund the full escrowed amount.
            paymentToken.safeTransfer(pending.user, pending.escrowedAmount);
            // Reverse the promo code consumption so the user can reuse their code.
            if (pendingCodeId != bytes32(0)) {
                address promoReg = iFactory.promoCodeRegistry();
                if (promoReg != address(0)) {
                    try
                        IPromoCodeRegistry(promoReg).refundDiscount(
                            pendingCodeId,
                            pending.user
                        )
                    {} catch {} // solhint-disable-line no-empty-blocks
                }
            }
            // Reverse the first-open discount consumption so the wallet retains its
            // once-per-machine discount after a fully-failed (zero-card) open.
            if (pendingFirstOpenDiscount) {
                $.hasClaimedFirstOpenDiscount[pending.user] = false;
            }
        }
        $.pendingRequestCount--;

        emit PackOpened(
            pending.user,
            requestId,
            pending.packId,
            pack.pricePerPack
        );
    }
}
