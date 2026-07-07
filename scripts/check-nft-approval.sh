#!/usr/bin/env bash
# check-nft-approval.sh — quick read-only approval check for AssetNFT
#
# Usage:
#   OWNER=0x... SPENDER=0x... ./scripts/check-nft-approval.sh
#   OWNER=0x... SPENDER=0x... TOKEN_ID=42 ./scripts/check-nft-approval.sh
#
# Env vars:
#   OWNER      (required) — token owner address
#   SPENDER    (required) — operator / spender address to check
#   TOKEN_ID   (optional) — if set, also checks getApproved + ownerOf for this token
#   ASSET_NFT  (optional) — AssetNFT proxy address; resolved from deployments/<NETWORK>.json if unset
#   NETWORK    (optional) — deployment network name, default: base
#   RPC_URL    (optional) — RPC endpoint; defaults to public Base RPC if NETWORK=base
#
# Requires: cast (Foundry), jq

set -euo pipefail

NETWORK="${NETWORK:-base}"

# Default public RPC per network
if [[ -z "${RPC_URL:-}" ]]; then
    case "$NETWORK" in
        base)        RPC_URL="https://mainnet.base.org" ;;
        baseSepolia) RPC_URL="https://sepolia.base.org" ;;
        sepolia)     RPC_URL="https://rpc.sepolia.org" ;;
        mainnet)     RPC_URL="https://ethereum-rpc.publicnode.com" ;;
        *)
            echo "ERROR: No default RPC_URL for network '$NETWORK'. Set RPC_URL manually." >&2
            exit 1
            ;;
    esac
fi

# Resolve AssetNFT proxy address
if [[ -n "${ASSET_NFT:-}" ]]; then
    ASSET_NFT_ADDR="$ASSET_NFT"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DEPLOYMENTS_FILE="$SCRIPT_DIR/../deployments/${NETWORK}.json"
    if [[ ! -f "$DEPLOYMENTS_FILE" ]]; then
        echo "ERROR: deployments/${NETWORK}.json not found. Set ASSET_NFT to override." >&2
        exit 1
    fi
    ASSET_NFT_ADDR="$(jq -r '.AssetNFT.proxy // empty' "$DEPLOYMENTS_FILE")"
    if [[ -z "$ASSET_NFT_ADDR" ]]; then
        echo "ERROR: AssetNFT.proxy not found in deployments/${NETWORK}.json. Set ASSET_NFT to override." >&2
        exit 1
    fi
fi

# Validate required env vars
if [[ -z "${OWNER:-}" ]]; then
    echo "ERROR: OWNER is required (token owner address)" >&2
    exit 1
fi
if [[ -z "${SPENDER:-}" ]]; then
    echo "ERROR: SPENDER is required (operator / spender address)" >&2
    exit 1
fi

echo "Network  : $NETWORK"
echo "RPC      : $RPC_URL"
echo "AssetNFT : $ASSET_NFT_ADDR"
echo "Owner    : $OWNER"
echo "Spender  : $SPENDER"
echo "---"

# --- isApprovedForAll ---
APPROVED_FOR_ALL="$(cast call "$ASSET_NFT_ADDR" \
    "isApprovedForAll(address,address)(bool)" \
    "$OWNER" "$SPENDER" \
    --rpc-url "$RPC_URL")"
echo "Spender approved (isApprovedForAll) : $APPROVED_FOR_ALL"

# --- paused ---
PAUSED="$(cast call "$ASSET_NFT_ADDR" \
    "paused()(bool)" \
    --rpc-url "$RPC_URL")"
echo "Contract paused                      : $PAUSED"

# --- per-token checks ---
if [[ -n "${TOKEN_ID:-}" ]]; then
    echo "---"
    echo "Token ID : $TOKEN_ID"

    TOKEN_OWNER="$(cast call "$ASSET_NFT_ADDR" \
        "ownerOf(uint256)(address)" \
        "$TOKEN_ID" \
        --rpc-url "$RPC_URL")"
    echo "Token owner                          : $TOKEN_OWNER"

    TOKEN_APPROVED="$(cast call "$ASSET_NFT_ADDR" \
        "getApproved(uint256)(address)" \
        "$TOKEN_ID" \
        --rpc-url "$RPC_URL")"
    echo "Per-token approved spender           : $TOKEN_APPROVED"

    # Normalize to lowercase for comparison
    SPENDER_LOWER="${SPENDER,,}"
    TOKEN_APPROVED_LOWER="${TOKEN_APPROVED,,}"
    APPROVED_FOR_ALL_LOWER="${APPROVED_FOR_ALL,,}"

    if [[ "$APPROVED_FOR_ALL_LOWER" == "true" ]] || [[ "$TOKEN_APPROVED_LOWER" == "$SPENDER_LOWER" ]]; then
        echo "Spender can transfer token $TOKEN_ID   : YES"
    else
        echo "Spender can transfer token $TOKEN_ID   : NO"
    fi

    # AssetNFT state — transfers require Held (0)
    ASSET_STATE="$(cast call "$ASSET_NFT_ADDR" \
        "getAssetState(uint256)(uint8)" \
        "$TOKEN_ID" \
        --rpc-url "$RPC_URL")"
    case "$ASSET_STATE" in
        0) STATE_NAME="Held" ;;
        1) STATE_NAME="Listed" ;;
        2) STATE_NAME="Loaned" ;;
        3) STATE_NAME="Traded" ;;
        4) STATE_NAME="InShipment" ;;
        5) STATE_NAME="RemovedFromPlatform" ;;
        *) STATE_NAME="Unknown($ASSET_STATE)" ;;
    esac
    echo "Asset state                          : $STATE_NAME ($ASSET_STATE)"
    if [[ "$ASSET_STATE" != "0" ]]; then
        echo "NOTE: transfer will revert — token must be in Held state (0) to be transferable"
    fi
fi
