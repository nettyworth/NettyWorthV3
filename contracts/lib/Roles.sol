// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

library Roles {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant STATE_MANAGER_ROLE = keccak256(
        "STATE_MANAGER_ROLE"
    );
    bytes32 internal constant URI_SETTER_ROLE = keccak256("URI_SETTER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant BLACKLIST_ROLE = keccak256("BLACKLIST_ROLE");
    bytes32 internal constant PACK_OPERATOR_ROLE = keccak256(
        "PACK_OPERATOR_ROLE"
    );
    bytes32 internal constant BUYBACK_POOL_ROLE = keccak256("BUYBACK_POOL_ROLE");
    bytes32 internal constant MARKETPLACE_ROLE = keccak256("MARKETPLACE_ROLE");
}
