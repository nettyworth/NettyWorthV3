/**
 * Safe batches that freeze and unfreeze every staging pool mutator for the manual recovery
 * (audit N-01). Runbook: aws/docs/runbooks/vrf-staging-manual-recovery.md.
 *
 *   node --experimental-strip-types scripts/vrf/build-recovery-freeze.ts [--resume | --baseline-block <n> [--baseline-frozen-ok]]
 *         [--rpc <url>] [--out dir] [--chunk <blocks>] [--delay <ms>]
 *   node --experimental-strip-types scripts/vrf/build-recovery-freeze.ts --finish [--rpc <url>] [--out dir]
 *
 * The unfreeze must give back the state from BEFORE the incident, not the state found when the
 * builder runs: rerunning it while partly frozen (runbook step 6, "restore the freeze") would
 * otherwise produce a partial inverse and leave the machine paused and the AssetLendingPool
 * de-authorized after "unfreeze" (re-audit R-01). So the pre-incident state is recorded once, in
 * deployments/safe/vrf-staging/recovery-baseline.json, and every unfreeze is built from it:
 *   - first run of an incident (no baseline file): the state now is the baseline. If anything is
 *     already paused or de-authorized, the builder cannot tell a partial freeze from the normal
 *     state and refuses; pass --baseline-block <n> (a block before the freeze) to read it there.
 *   - later runs (baseline file present): if the state now differs from the baseline, a freeze
 *     is in effect or was partly lifted; pass --resume to rebuild against the recorded baseline.
 *     --baseline-block replaces the file instead (only for a stale baseline from an old incident).
 *   - --baseline-block refuses a block whose state already looks frozen (a pause or a
 *     de-authorized depositor), unless --baseline-frozen-ok confirms it was the normal state.
 *   - --finish, after recovery-unfreeze.json executed: checks the state equals the baseline, then
 *     deletes the baseline file, closing the incident.
 *
 * Writes, into deployments/safe/vrf-staging/:
 *   recovery-freeze.json    only the calls still needed, in this order (removed if none are):
 *                             machine.pause()                          (openPack)
 *                             BuybackPool.pause()                      (buyback -> depositFromPool)
 *                             machine.setAuthorizedDepositor(d, false) for every authorized depositor
 *                               (the AssetLendingPool; needs the machine paused, hence after pause)
 *   recovery-unfreeze.json  from the fully frozen state back to the baseline:
 *                             machine.setAuthorizedDepositor(d, true) for each baseline depositor (while paused)
 *                             BuybackPool.unpause(), machine.unpause() (only what was unpaused at the baseline)
 * Both are simulated as the Safe with eth_simulateV1 before anything is written: the freeze must
 * leave the state frozen (freezeProblems empty, each de-authorized depositor refused by
 * depositFromPool), and freeze + unfreeze must restore the baseline exactly.
 * Read-only: no keys, no transactions.
 */
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeFunctionData, getAddress, type Address, type Hex } from "viem";
import { createScanClient } from "./log-scan.ts";
import {
  decodeBool,
  depositorCandidates,
  emptyDepositFromPool,
  freezeProblems,
  implementationProblems,
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
  type FreezeState,
  type SimCall,
} from "./recovery-freeze.ts";

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : undefined;
}
const flag = (name: string) => process.argv.includes(`--${name}`);
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
const baselineBlock = uintArg("baseline-block");
const baselineFrozenOk = flag("baseline-frozen-ok");
if (baselineFrozenOk && baselineBlock === undefined) fail("--baseline-frozen-ok only applies with --baseline-block");
const resume = flag("resume");
const finish = flag("finish");
if ([resume, finish, baselineBlock !== undefined].filter(Boolean).length > 1) fail("pass at most one of --resume, --finish, --baseline-block");
const client = createScanClient(rpc);

const freezeFile = join(outDir, "recovery-freeze.json");
const unfreezeFile = join(outDir, "recovery-unfreeze.json");
const baselineFile = join(outDir, "recovery-baseline.json");
const BASELINE_KIND = "nettyworth-vrf-staging-recovery-baseline";

/** The pre-incident state the unfreeze restores. Depositors not listed were not authorized. */
interface Baseline {
  block: bigint;
  blockHash: Hex;
  machinePaused: boolean;
  buybackPoolPaused: boolean;
  depositors: { address: Address; authorized: boolean }[];
}

const call = (to: Address, data: `0x${string}`): BatchTx => ({ to, data });
const pauseTx = (to: Address) => call(to, encodeFunctionData({ abi: pausableAbi, functionName: "pause" }));
const unpauseTx = (to: Address) => call(to, encodeFunctionData({ abi: pausableAbi, functionName: "unpause" }));
const setDepositor = (d: Address, on: boolean) =>
  call(STAGING_MACHINE, encodeFunctionData({ abi: machineAbi, functionName: "setAuthorizedDepositor", args: [d, on] }));

const authorizedAt = (b: Baseline, d: Address) => b.depositors.some((x) => x.address === d && x.authorized);

function baselineFromState(s: FreezeState, blockHash: Hex): Baseline {
  return { block: s.block, blockHash, machinePaused: s.machinePaused, buybackPoolPaused: s.buybackPoolPaused, depositors: s.depositors };
}

/** Differences between a state and the baseline, over every known depositor. */
function differences(s: FreezeState, b: Baseline): string[] {
  const d: string[] = [];
  if (s.machinePaused !== b.machinePaused) d.push(`machine paused ${s.machinePaused}, baseline ${b.machinePaused}`);
  if (s.buybackPoolPaused !== b.buybackPoolPaused) d.push(`BuybackPool paused ${s.buybackPoolPaused}, baseline ${b.buybackPoolPaused}`);
  const all = new Set<Address>([...s.depositors.map((x) => x.address), ...b.depositors.map((x) => x.address)]);
  for (const a of all) {
    const now = s.depositors.some((x) => x.address === a && x.authorized);
    if (now !== authorizedAt(b, a)) d.push(`depositor ${a} authorized ${now}, baseline ${authorizedAt(b, a)}`);
  }
  return d;
}

function readBaseline(): Baseline {
  let raw: {
    kind?: string;
    version?: number;
    chainId?: number;
    block?: string;
    blockHash?: Hex;
    machine?: string;
    machinePaused?: boolean;
    buybackPoolPaused?: boolean;
    depositors?: { address: string; authorized: boolean }[];
  };
  try {
    raw = JSON.parse(readFileSync(baselineFile, "utf8"));
  } catch {
    fail(`cannot read ${baselineFile}`);
  }
  if (raw.kind !== BASELINE_KIND || raw.version !== 1 || raw.chainId !== 8453) fail(`${baselineFile} is not a staging recovery baseline (v1, chain 8453)`);
  if (!raw.machine || getAddress(raw.machine) !== STAGING_MACHINE) fail(`${baselineFile} is not for the staging machine`);
  if (typeof raw.block !== "string" || !/^\d+$/.test(raw.block) || typeof raw.blockHash !== "string") fail(`${baselineFile} has no valid block`);
  if (typeof raw.machinePaused !== "boolean" || typeof raw.buybackPoolPaused !== "boolean" || !Array.isArray(raw.depositors)) fail(`${baselineFile} is malformed`);
  return {
    block: BigInt(raw.block),
    blockHash: raw.blockHash,
    machinePaused: raw.machinePaused,
    buybackPoolPaused: raw.buybackPoolPaused,
    depositors: raw.depositors.map((x) => ({ address: getAddress(x.address), authorized: x.authorized === true })),
  };
}

function writeBaseline(b: Baseline): void {
  mkdirSync(outDir, { recursive: true });
  writeFileSync(
    baselineFile,
    JSON.stringify(
      {
        kind: BASELINE_KIND,
        version: 1,
        chainId: 8453,
        machine: STAGING_MACHINE,
        buybackPool: STAGING_BUYBACK_POOL,
        block: b.block.toString(),
        blockHash: b.blockHash,
        machinePaused: b.machinePaused,
        buybackPoolPaused: b.buybackPoolPaused,
        depositors: b.depositors,
      },
      null,
      2,
    ) + "\n",
  );
}

try {
  if (BigInt(await client.getChainId()) !== 8453n) fail("RPC is not Base mainnet");
  const latest = await client.getBlockNumber();
  const depositors = await depositorCandidates(client, STAGING_MACHINE, latest, tuning);
  const now = await readFreezeState(client, STAGING_MACHINE, depositors, latest);
  if (now.buybackPool !== STAGING_BUYBACK_POOL) fail(`machine buybackPool is ${now.buybackPool}, expected ${STAGING_BUYBACK_POOL}; review before freezing`);
  const upgraded = implementationProblems(now);
  if (upgraded.length) fail(`a proxy the freeze depends on is not at its pinned implementation (re-audit R-04):\n  ${upgraded.join("\n  ")}`);

  console.log(`block ${latest}: machine paused ${now.machinePaused}, BuybackPool paused ${now.buybackPoolPaused}`);
  for (const d of now.depositors) console.log(`  depositor ${d.address}: ${d.authorized ? "AUTHORIZED" : "not authorized"}`);

  // --finish: close the incident once the unfreeze has executed.
  if (finish) {
    if (!existsSync(baselineFile)) fail(`no ${baselineFile}: nothing to finish`);
    const b = readBaseline();
    const diff = differences(now, b);
    if (diff.length) fail(`the state is not back to the baseline of block ${b.block}; execute recovery-unfreeze.json first:\n  ${diff.join("\n  ")}`);
    rmSync(baselineFile);
    console.log(`state equals the baseline of block ${b.block}: removed ${baselineFile}. The incident's freeze is closed.`);
    process.exit(0);
  }

  // Which pre-incident state the unfreeze must restore.
  let baseline: Baseline;
  if (baselineBlock !== undefined) {
    if (baselineBlock > latest) fail(`--baseline-block ${baselineBlock} is after the latest block ${latest}`);
    const at = await readFreezeState(client, STAGING_MACHINE, depositors, baselineBlock);
    // A baseline must describe the state BEFORE the freeze. Recording a frozen state would give
    // an unfreeze that restores nothing, and --finish would then close with staging still
    // paused. A state that was genuinely paused before the incident needs the explicit flag.
    const frozenAt = [
      at.machinePaused && "the machine is paused",
      at.buybackPoolPaused && "the BuybackPool is paused",
      ...at.depositors.filter((d) => !d.authorized).map((d) => `depositor ${d.address} is not authorized`),
    ].filter(Boolean);
    if (frozenAt.length && !baselineFrozenOk) {
      fail(
        `block ${baselineBlock} already looks frozen (${frozenAt.join("; ")}). Pick a block before the freeze started.\n` +
          "If that really was the normal state before this incident, rerun with --baseline-frozen-ok.",
      );
    }
    const blk = await client.getBlock({ blockNumber: baselineBlock });
    baseline = baselineFromState(at, blk.hash as Hex);
    if (existsSync(baselineFile)) console.log(`  replacing ${baselineFile} with the state at block ${baselineBlock} (--baseline-block)`);
    writeBaseline(baseline);
  } else if (existsSync(baselineFile)) {
    baseline = readBaseline();
    const blk = await client.getBlock({ blockNumber: baseline.block });
    if (blk.hash !== baseline.blockHash) fail(`${baselineFile}: block ${baseline.block} hash is ${blk.hash}, recorded ${baseline.blockHash} (wrong chain or reorg)`);
    const diff = differences(now, baseline);
    if (diff.length && !resume) {
      fail(
        `${baselineFile} records the state at block ${baseline.block}, and the state now differs:\n  ${diff.join("\n  ")}\n` +
          "If this incident's freeze is in effect or was partly lifted, rerun with --resume. If the file is left over from an\n" +
          "earlier incident, rerun with --baseline-block <a block before this incident's freeze>.",
      );
    }
    console.log(`  restoring to the baseline of block ${baseline.block} (${baselineFile})`);
  } else {
    const alreadyFrozen = now.machinePaused || now.buybackPoolPaused || now.depositors.some((d) => !d.authorized);
    if (alreadyFrozen || resume) {
      fail(
        `no ${baselineFile}, and ${resume ? "--resume needs one" : "part of the freeze is already in effect (a pause or a de-authorized depositor)"}.\n` +
          "The builder cannot tell the normal state from a partial freeze. Rerun with --baseline-block <a block before the freeze>.",
      );
    }
    const blk = await client.getBlock({ blockNumber: latest });
    baseline = baselineFromState(now, blk.hash as Hex);
    writeBaseline(baseline);
    console.log(`  recorded the pre-incident state at block ${latest} in ${baselineFile}`);
  }

  const revoked = now.depositors.filter((d) => d.authorized).map((d) => d.address);
  const freeze: BatchTx[] = [];
  if (!now.machinePaused) freeze.push(pauseTx(STAGING_MACHINE));
  if (!now.buybackPoolPaused) freeze.push(pauseTx(STAGING_BUYBACK_POOL));
  for (const d of revoked) freeze.push(setDepositor(d, false));
  // From the fully frozen state back to the baseline. Depositors authorized after the baseline
  // are left de-authorized: that is the baseline state, and re-authorizing is a separate decision.
  const restore = depositors.filter((d) => authorizedAt(baseline, d));
  const unfreeze: BatchTx[] = [
    ...restore.map((d) => setDepositor(d, true)),
    ...(!baseline.buybackPoolPaused ? [unpauseTx(STAGING_BUYBACK_POOL)] : []),
    ...(!baseline.machinePaused ? [unpauseTx(STAGING_MACHINE)] : []),
  ];
  for (const d of revoked.filter((x) => !authorizedAt(baseline, x))) {
    console.log(`  NOTE: ${d} is authorized now but was not at the baseline; the unfreeze leaves it de-authorized`);
  }

  // Simulate as the Safe: freeze, then probe the frozen state inside the same simulated block.
  const safe = (t: BatchTx): SimCall => ({ from: SAFE, to: t.to, data: t.data });
  const probed = [...new Set<Address>([...revoked, ...restore])];
  const probes = (): SimCall[] => [
    { from: SAFE, to: STAGING_MACHINE, data: PAUSED_CALL },
    { from: SAFE, to: STAGING_BUYBACK_POOL, data: PAUSED_CALL },
    ...probed.map((d) => ({ from: d, to: STAGING_MACHINE, data: emptyDepositFromPool(d) })),
  ];
  const f = await simulateCalls(client, [...freeze.map(safe), ...probes()], latest);
  f.slice(0, freeze.length).forEach((r, i) => {
    if (!r.ok) fail(`simulated freeze call ${i + 1} reverts as the Safe: ${r.error ?? "no reason"} (does the Safe hold PAUSER_ROLE and PACK_OPERATOR_ROLE?)`);
  });
  const fp = f.slice(freeze.length);
  if (!decodeBool(fp[0].returnData)) fail("simulation: machine not paused after the freeze");
  if (!decodeBool(fp[1].returnData)) fail("simulation: BuybackPool not paused after the freeze");
  probed.forEach((d, i) => {
    if (fp[2 + i].ok) fail(`simulation: ${d} can still call depositFromPool after the freeze`);
  });

  // Freeze + unfreeze must give back the baseline.
  const u = await simulateCalls(client, [...freeze.map(safe), ...unfreeze.map(safe), ...probes()], latest);
  u.slice(0, freeze.length + unfreeze.length).forEach((r, i) => {
    if (!r.ok) fail(`simulated ${i < freeze.length ? "freeze" : "unfreeze"} call reverts as the Safe: ${r.error ?? "no reason"}`);
  });
  const up = u.slice(freeze.length + unfreeze.length);
  if (decodeBool(up[0].returnData) !== baseline.machinePaused) fail("simulation: unfreeze does not restore the baseline machine pause state");
  if (decodeBool(up[1].returnData) !== baseline.buybackPoolPaused) fail("simulation: unfreeze does not restore the baseline BuybackPool pause state");
  probed.forEach((d, i) => {
    if (up[2 + i].ok !== authorizedAt(baseline, d)) fail(`simulation: unfreeze does not restore ${d} to its baseline authorization`);
  });

  mkdirSync(outDir, { recursive: true });
  if (freeze.length) {
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
  } else {
    const problems = freezeProblems(now);
    if (problems.length) fail(`nothing to add, but not frozen:\n  ${problems.join("\n  ")}`);
    if (existsSync(freezeFile)) rmSync(freezeFile);
    console.log("already frozen: no freeze batch needed (any old recovery-freeze.json was removed)");
  }
  writeFileSync(
    unfreezeFile,
    txBuilderJson(
      "VRF staging recovery: unfreeze",
      `Restores the pre-incident state recorded at block ${baseline.block} (recovery-baseline.json), from the fully frozen state. Run only after every recovery batch has executed and check-pending.ts --only-router exits 0; then run build-recovery-freeze.ts --finish.`,
      unfreeze,
    ),
  );
  console.log(`simulated as the Safe: freeze leaves every mutator closed; freeze + unfreeze restores the baseline of block ${baseline.block}`);
  console.log(`wrote ${freeze.length ? `${freezeFile} (${freeze.length} call(s)) and ` : ""}${unfreezeFile} (${unfreeze.length} call(s))`);
} catch (err) {
  console.error(err instanceof Error ? err.message.split("\n")[0] : String(err));
  process.exit(2);
}
