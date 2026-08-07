import { keccak256, toBytes } from "viem";

// ─── Role map — canonical names from contracts/lib/Roles.sol ─────────────────
export const DEFAULT_ADMIN_ROLE =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

/**
 * All protocol roles registered on PermissionManager, keyed by canonical name.
 * Mirrors contracts/lib/Roles.sol — keep in sync when roles are added there.
 */
export const ROLES: Record<string, `0x${string}`> = {
  DEFAULT_ADMIN_ROLE,
  MINTER_ROLE: keccak256(toBytes("MINTER_ROLE")),
  BURNER_ROLE: keccak256(toBytes("BURNER_ROLE")),
  STATE_MANAGER_ROLE: keccak256(toBytes("STATE_MANAGER_ROLE")),
  URI_SETTER_ROLE: keccak256(toBytes("URI_SETTER_ROLE")),
  PAUSER_ROLE: keccak256(toBytes("PAUSER_ROLE")),
  UPGRADER_ROLE: keccak256(toBytes("UPGRADER_ROLE")),
  BLACKLIST_ROLE: keccak256(toBytes("BLACKLIST_ROLE")),
  PACK_OPERATOR_ROLE: keccak256(toBytes("PACK_OPERATOR_ROLE")),
  BUYBACK_POOL_ROLE: keccak256(toBytes("BUYBACK_POOL_ROLE")),
  MARKETPLACE_ROLE: keccak256(toBytes("MARKETPLACE_ROLE")),
};

// ─── Ownable2Step contracts (two-step ownership handoff) ─────────────────────
/**
 * Protocol contracts that inherit Ownable2StepUpgradeable. `key` is the
 * deployments-JSON entry name; `contract` is the artifact name for viem.
 */
export const OWNABLE_CONTRACTS: Array<{ key: string; contract: string }> = [
  { key: "AssetLendingPool", contract: "AssetLendingPool" },
  { key: "AssetLendingPoolConfig", contract: "AssetLendingPoolConfig" },
  { key: "P2PTradeEscrow", contract: "P2PTradeEscrow" },
];
