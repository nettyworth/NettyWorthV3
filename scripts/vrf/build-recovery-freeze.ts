/**
 * Safe batches that freeze and unfreeze every staging pool mutator for the manual recovery
 * (audit N-01). Runbook: aws/docs/pack-rip-latency/RUNBOOK-vrf-staging-manual-recovery.md.
 *
 *   node --experimental-strip-types scripts/vrf/build-recovery-freeze.ts [--rpc <url>] [--out dir]
 *         [--chunk <blocks>] [--delay <ms>]
 *
 * Reads the current state and writes, into deployments/safe/vrf-staging/:
 *   recovery-freeze.json    only the calls still needed, in this order:
 *                             machine.pause()                          (openPack)
 *                             BuybackPool.pause()                      (buyback -> depositFromPool)
 *                             machine.setAuthorizedDepositor(d, false) for every authorized depositor
 *                               (the AssetLendingPool; needs the machine paused, hence after pause)
 *   recovery-unfreeze.json  the exact inverse, run after the last recovery batch executed:
 *                             machine.setAuthorizedDepositor(d, true) (while still paused)
 *                             BuybackPool.unpause(), machine.unpause() (only what the freeze paused)
 * Both are simulated as the Safe with eth_simulateV1 before anything is written: the freeze must
 * leave the state frozen (freezeProblems empty, each de-authorized depositor refused by
 * depositFromPool), and freeze + unfreeze must restore the state found now. If nothing needs
 * freezing it writes nothing, so an existing recovery-unfreeze.json is never overwritten.
 * Read-only: no keys, no transactions.
 */
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeFunctionData, type Address } from "viem";
import { createScanClient } from "./log-scan.ts";
import {
  decodeBool,
  depositorCandidates,
  emptyDepositFromPool,
  freezeProblems,
  machineAbi,
  PAUSED_CALL,
  pausableAbi,
  readFreezeState,
  SAFE,
  simulateCalls,
  STAGING_BUYBACK_POOL,
  STAGING_MACHINE,
  txBuilderJson,
  type BatchTx,
  type SimCall,
} from "./recovery-freeze.ts";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
function fail(msg: string): never {
  console.error(msg);
  process.exit(2);
}
function uintArg(name: string): bigint | undefined {
  const v = arg(name);
  if (v === undefined) return undefined;
  if (!/^\d+$/.test(v)) fail(`--${name} must be a non-negative integer`);
  return BigInt(v);
}

const rpc = arg("rpc") ?? process.env.BASE_RPC_URL ?? "https://mainnet.base.org";
const outDir = arg("out") ?? join(dirname(fileURLToPath(import.meta.url)), "../../deployments/safe/vrf-staging");
const chunk = uintArg("chunk");
if (chunk === 0n) fail("--chunk must be positive");
const delay = uintArg("delay");
const tuning = { chunk, delayMs: delay === undefined ? undefined : Number(delay) };
const client = createScanClient(rpc);

const call = (to: Address, data: `0x${string}`): BatchTx => ({ to, data });
const pauseTx = (to: Address) => call(to, encodeFunctionData({ abi: pausableAbi, functionName: "pause" }));
const unpauseTx = (to: Address) => call(to, encodeFunctionData({ abi: pausableAbi, functionName: "unpause" }));
const setDepositor = (d: Address, on: boolean) =>
  call(STAGING_MACHINE, encodeFunctionData({ abi: machineAbi, functionName: "setAuthorizedDepositor", args: [d, on] }));

try {
  if (BigInt(await client.getChainId()) !== 8453n) fail("RPC is not Base mainnet");
  const latest = await client.getBlockNumber();
  const depositors = await depositorCandidates(client, STAGING_MACHINE, latest, tuning);
  const now = await readFreezeState(client, STAGING_MACHINE, depositors, latest);
  if (now.buybackPool !== STAGING_BUYBACK_POOL) fail(`machine buybackPool is ${now.buybackPool}, expected ${STAGING_BUYBACK_POOL}; review before freezing`);

  const revoked = now.depositors.filter((d) => d.authorized).map((d) => d.address);
  const freeze: BatchTx[] = [];
  if (!now.machinePaused) freeze.push(pauseTx(STAGING_MACHINE));
  if (!now.buybackPoolPaused) freeze.push(pauseTx(STAGING_BUYBACK_POOL));
  for (const d of revoked) freeze.push(setDepositor(d, false));
  const unfreeze: BatchTx[] = [
    ...revoked.map((d) => setDepositor(d, true)),
    ...(!now.buybackPoolPaused ? [unpauseTx(STAGING_BUYBACK_POOL)] : []),
    ...(!now.machinePaused ? [unpauseTx(STAGING_MACHINE)] : []),
  ];

  console.log(`block ${latest}: machine paused ${now.machinePaused}, BuybackPool paused ${now.buybackPoolPaused}`);
  for (const d of now.depositors) console.log(`  depositor ${d.address}: ${d.authorized ? "AUTHORIZED" : "not authorized"}`);
  if (freeze.length === 0) {
    const problems = freezeProblems(now);
    if (problems.length) fail(`nothing to add, but not frozen:\n  ${problems.join("\n  ")}`);
    console.log("already frozen: nothing written. Use the recovery-unfreeze.json from the freeze that is in effect.");
    process.exit(0);
  }

  // Simulate as the Safe: freeze, then check the frozen state inside the same simulated block.
  const safe = (t: BatchTx): SimCall => ({ from: SAFE, to: t.to, data: t.data });
  const probes = (): SimCall[] => [
    { from: SAFE, to: STAGING_MACHINE, data: PAUSED_CALL },
    { from: SAFE, to: STAGING_BUYBACK_POOL, data: PAUSED_CALL },
    ...revoked.map((d) => ({ from: d, to: STAGING_MACHINE, data: emptyDepositFromPool(d) })),
  ];
  const f = await simulateCalls(client, [...freeze.map(safe), ...probes()], latest);
  f.slice(0, freeze.length).forEach((r, i) => {
    if (!r.ok) fail(`simulated freeze call ${i + 1} reverts as the Safe: ${r.error ?? "no reason"} (does the Safe hold PAUSER_ROLE and PACK_OPERATOR_ROLE?)`);
  });
  const fp = f.slice(freeze.length);
  if (!decodeBool(fp[0].returnData)) fail("simulation: machine not paused after the freeze");
  if (!decodeBool(fp[1].returnData)) fail("simulation: BuybackPool not paused after the freeze");
  revoked.forEach((d, i) => {
    if (fp[2 + i].ok) fail(`simulation: ${d} can still call depositFromPool after the freeze`);
  });

  // Freeze + unfreeze must give back the state found now.
  const u = await simulateCalls(client, [...freeze.map(safe), ...unfreeze.map(safe), ...probes()], latest);
  u.slice(0, freeze.length + unfreeze.length).forEach((r, i) => {
    if (!r.ok) fail(`simulated ${i < freeze.length ? "freeze" : "unfreeze"} call reverts as the Safe: ${r.error ?? "no reason"}`);
  });
  const up = u.slice(freeze.length + unfreeze.length);
  if (decodeBool(up[0].returnData) !== now.machinePaused) fail("simulation: unfreeze does not restore the machine pause state");
  if (decodeBool(up[1].returnData) !== now.buybackPoolPaused) fail("simulation: unfreeze does not restore the BuybackPool pause state");
  revoked.forEach((d, i) => {
    if (!up[2 + i].ok) fail(`simulation: unfreeze does not restore ${d} as a depositor`);
  });

  mkdirSync(outDir, { recursive: true });
  const freezeFile = join(outDir, "recovery-freeze.json");
  const unfreezeFile = join(outDir, "recovery-unfreeze.json");
  if (existsSync(unfreezeFile)) console.log(`  replacing ${unfreezeFile} (nothing was frozen, so the old one is stale)`);
  writeFileSync(
    freezeFile,
    txBuilderJson(
      "VRF staging recovery: freeze pool mutators",
      `Freeze every path that can change the staging PackMachine pools before announcing a recovery block (audit N-01): ${[
        !now.machinePaused && "pause machine",
        !now.buybackPoolPaused && "pause BuybackPool",
        ...revoked.map((d) => `de-authorize depositor ${d}`),
      ]
        .filter(Boolean)
        .join(", ")}. Built at block ${latest}.`,
      freeze,
    ),
  );
  writeFileSync(
    unfreezeFile,
    txBuilderJson(
      "VRF staging recovery: unfreeze",
      `Inverse of recovery-freeze.json built at block ${latest}. Run only after every recovery batch has executed and check-pending.ts --coordinator exits 0.`,
      unfreeze,
    ),
  );
  console.log(`simulated as the Safe: freeze leaves every mutator closed; freeze + unfreeze restores block ${latest}'s state`);
  console.log(`wrote ${freezeFile} (${freeze.length} call(s)) and ${unfreezeFile} (${unfreeze.length} call(s))`);
} catch (err) {
  console.error(err instanceof Error ? err.message.split("\n")[0] : String(err));
  process.exit(2);
}
