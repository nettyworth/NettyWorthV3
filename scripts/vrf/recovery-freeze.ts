/**
 * Staging manual recovery: the pool freeze and its proof (audit N-01, re-audit of 8964acb).
 *
 * The recovery words keccak256(abi.encode(blockhash(announced), requestId, i)) are public from
 * the moment the announced block is mined. The card the machine draws depends on those words
 * AND, at delivery, on the ORDERED contents of packTierPools[packId][0..5] (tier = weighted pick
 * over the non-empty tiers with word >> 128; index = uint128(word) % poolLen; swap-and-pop) and
 * on the pack's tier weights. So from the announcement until the batch executes neither may change.
 *
 * The deployed staging machine is an EIP-1167 clone of implementation
 * 0xe8a11268434946e6918b068328cd29af10b609fa, which predates the current source: its draw is
 * inlined (no PackFulfillLib) and reads the pack's tier weights LIVE from the registry at
 * delivery (current source snapshots them at request time); its PendingOpen is
 * {user, cardsCount, packId, escrowedAmount, buybackAmount}; it has no pendingRequestCount. This
 * module reads that layout and refuses unless the machine's code is exactly that clone of that
 * implementation (assertDeployedCode). Checked on a fork by
 * contracts/test/NettyVRFCoordinator.recoveryFreeze.fork.t.sol.
 *
 * Every path that can change the draw state is frozen as follows:
 *   - openPack*                  pause-gated (machine paused by the freeze batch)
 *   - fulfillRandomness          router only; the router accepts only its coordinator; the
 *                                coordinator must have 0 Pending requests (drained), and other
 *                                stranded requests are only ever delivered by a Safe batch
 *   - depositFromPool            NOT pause-gated. Callers: the machine's buybackPool
 *                                (BuybackPool.buyback, any card holder) -> BuybackPool paused by
 *                                the freeze batch; authorized depositors (the staging
 *                                AssetLendingPool) -> de-authorized by the freeze batch
 *   - deposit, setPackEligibility, withdrawCards (PACK_OPERATOR_ROLE; not pause-gated, or
 *     only allowed while paused): procedurally locked, detected here by the ordered-pool
 *     fingerprint, which must be identical at the announced block, at build time and right
 *     before execution
 *   - registry setPackTierWeights (PACK_OPERATOR_ROLE; the registry has no pause), or a factory
 *     or registry change: procedurally locked, detected by recording the weights the machine
 *     resolves (machine.getPack(packId).tierWeights) at the same three points
 * This module reads that state; build-recovery-freeze.ts, build-recovery-payload.ts and
 * check-recovery-payload.ts act on it. Read-only: no keys, no transactions.
 */
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  hexToBigInt,
  keccak256,
  numberToHex,
  parseAbi,
  parseAbiItem,
  toHex,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { scanLogs, type ScanOptions } from "./log-scan.ts";

export const SAFE = getAddress("0xfe78E8aa8f4B9f616e05a94604aB86A7B192f456");
export const STAGING_ROUTER = getAddress("0xeA3aDEac6b82b9852a140E642BC10135638653E1");
export const STAGING_MACHINE = getAddress("0x46999a9D321df9e752eCc007f5F67D2981183109");
export const STAGING_BUYBACK_POOL = getAddress("0x778e60808A37FAABD61446a4ed29C11fF6d64698");
/** Staging AssetLendingPool: an authorized depositor of the staging machine since block 48,361,979. */
export const STAGING_ASSET_LENDING_POOL = getAddress("0xf3ffabb652e3dca54b28a3f273013b72b31f385e");
export const NUM_TIERS = 6;

/**
 * Every address ever passed to setAuthorizedDepositor on the staging machine, from its creation
 * (block 48,132,247) through `block`: one AuthorizedDepositorUpdated event, the AssetLendingPool
 * authorized at block 48,361,979 (tx 0x3756e651…40c3). Established 2026-09-21 by a full-history
 * log query (Blockscout) and cross-checked on chain (authorizedDepositors[ALP] = true). The tools
 * scan AuthorizedDepositorUpdated from block + 1 to the latest block for anything newer, and check
 * `hash` so a fork or a different chain cannot reuse the checkpoint.
 */
export const DEPOSITOR_CHECKPOINT = {
  block: 51_621_500n,
  hash: "0x1081c9f2e6ae569ce099983cefd9eb786f1a436afacc4da1021b5a990cd381c8" as Hex,
  depositors: [STAGING_ASSET_LENDING_POOL] as Address[],
};

// PackMachineStorageLib, ERC-7201 "nettyworth.storage.PackMachine". Field offsets verified on the
// deployed staging clone (fork test and the runtime self-checks in readPools/readPendingOpen).
export const MACHINE_STORAGE_SLOT = 0xf65d8338bde3e030621995e09419bd24a6a0ace7a2660416b0681f35fe771000n;
// These offsets are the same in the deployed implementation and in current source.
const F_PENDING_OPENS = 3n;
const F_BUYBACK_POOL = 5n;
const F_AUTHORIZED_DEPOSITORS = 6n;
const F_PACK_TIER_POOLS = 8n;
const F_PACK_POOL_INDEX = 9n;

/** The staging machine's runtime code: EIP-1167 minimal proxy to the verified implementation. */
export const STAGING_MACHINE_IMPLEMENTATION = getAddress("0xe8a11268434946e6918b068328cd29af10b609fa");
export const STAGING_MACHINE_CODE: Hex = "0x363d3d373d3d3d363d73e8a11268434946e6918b068328cd29af10b609fa5af43d82803e903d91602b57fd5bf3";
/** keccak256 of that implementation's runtime code (the code the fork tests ran against). */
export const STAGING_MACHINE_IMPLEMENTATION_CODEHASH: Hex = "0x5dd95dd199f88019b84519a9a155d36babb1540fd7d20c8188be0c68f38454a8";

export const machineAbi = parseAbi([
  "function paused() view returns (bool)",
  "function pause()",
  "function unpause()",
  "function setAuthorizedDepositor(address depositor, bool authorized)",
  "function getPackTierPoolSize(uint256 packId, uint8 tier) view returns (uint256)",
  "function isTokenEligibleForPack(uint256 tokenId, uint256 packId) view returns (bool)",
  "function getPackTokenTier(uint256 tokenId, uint256 packId) view returns (uint8)",
  "struct Pack { uint128 pricePerPack; uint8 cardsPerPack; uint40 startTime; uint16 buybackAllocationBps; bool active; bool finished; uint32[6] tierWeights; uint128[6] tierMinFmv; uint128[6] tierMaxFmv; uint32 minCards; uint32 maxCards; }",
  "function getPack(uint256 packId) view returns (Pack)",
]);
export const pausableAbi = parseAbi(["function paused() view returns (bool)", "function pause()", "function unpause()"]);
export const routerAbi = parseAbi([
  "function setVRFCoordinator(address newCoordinator)",
  "function rawFulfillRandomWords(uint256 requestId, uint256[] randomWords)",
  "function vrfCoordinator() view returns (address)",
]);

export const EV_PAUSED = parseAbiItem("event Paused(address account)");
export const EV_UNPAUSED = parseAbiItem("event Unpaused(address account)");
export const EV_DEPOSITOR = parseAbiItem("event AuthorizedDepositorUpdated(address indexed depositor, bool authorized)");
export const EV_BUYBACK_POOL = parseAbiItem("event BuybackPoolUpdated(address indexed oldPool, address indexed newPool)");
export const EV_ROUTER_REQUESTED = parseAbiItem(
  "event RandomnessRequested(uint256 indexed requestId, address indexed packMachine, address user)",
);
const CARD_WON = keccak256(toHex("CardWon(address,uint256,uint256)"));
const CARD_FAILED = keccak256(toHex("CardFailed(address,uint256,uint256)"));

export type ScanTuning = Pick<ScanOptions, "chunk" | "delayMs">;

// ---------------------------------------------------------------------------------------------
// Storage reads
// ---------------------------------------------------------------------------------------------

/** Refuses unless the machine is exactly the verified clone of the verified implementation. */
export async function assertDeployedCode(client: PublicClient, machine: Address, blockNumber: bigint): Promise<void> {
  const [code, implCode] = await Promise.all([
    client.getCode({ address: machine, blockNumber }),
    client.getCode({ address: STAGING_MACHINE_IMPLEMENTATION, blockNumber }),
  ]);
  if (code?.toLowerCase() !== STAGING_MACHINE_CODE) throw new Error(`machine ${machine} code is not the verified clone of ${STAGING_MACHINE_IMPLEMENTATION}`);
  if (!implCode || keccak256(implCode) !== STAGING_MACHINE_IMPLEMENTATION_CODEHASH) {
    throw new Error(`implementation ${STAGING_MACHINE_IMPLEMENTATION} code hash is not the verified one`);
  }
}

export function mappingSlot(key: bigint | Address, slot: bigint): bigint {
  const keyType = typeof key === "bigint" ? "uint256" : "address";
  return hexToBigInt(keccak256(encodeAbiParameters([{ type: keyType }, { type: "uint256" }], [key as never, slot])));
}

export function arrayDataSlot(lengthSlot: bigint): bigint {
  return hexToBigInt(keccak256(encodeAbiParameters([{ type: "uint256" }], [lengthSlot])));
}

/**
 * Runtime code for an eth_call state override: returns sload(word i of calldata) for every
 * 32-byte word of calldata. Installed at the machine's address for one eth_call only, so it reads
 * the machine's own storage, all at one block, in one request. Assembly:
 *   PUSH0; loop: JUMPDEST DUP1 CALLDATASIZE GT PUSH1 0x0b JUMPI CALLDATASIZE PUSH0 RETURN;
 *   0x0b: JUMPDEST DUP1 CALLDATALOAD SLOAD DUP2 MSTORE PUSH1 0x20 ADD PUSH1 0x01 JUMP
 */
export const SLOT_READER_CODE: Hex = "0x5f5b803611600b57365ff35b8035548152602001600156";

/** Storage words at `slots` of `address`, all at `blockNumber`. */
export async function readSlots(client: PublicClient, address: Address, slots: bigint[], blockNumber: bigint): Promise<bigint[]> {
  const out: bigint[] = [];
  const BATCH = 512;
  for (let i = 0; i < slots.length; i += BATCH) {
    const part = slots.slice(i, i + BATCH);
    const data = ("0x" + part.map((s) => s.toString(16).padStart(64, "0")).join("")) as Hex;
    let ret: Hex | undefined;
    try {
      // eslint-disable-next-line no-await-in-loop
      ret = (await client.request({
        method: "eth_call",
        params: [{ to: address, data }, numberToHex(blockNumber), { [address]: { code: SLOT_READER_CODE } }],
      } as never)) as Hex;
    } catch {
      ret = undefined; // provider without state overrides: fall back to eth_getStorageAt below
    }
    if (ret !== undefined && ret.length === 2 + 64 * part.length) {
      for (let k = 0; k < part.length; k++) out.push(hexToBigInt(("0x" + ret.slice(2 + 64 * k, 2 + 64 * (k + 1))) as Hex));
      continue;
    }
    for (const s of part) {
      // eslint-disable-next-line no-await-in-loop
      const v = await client.getStorageAt({ address, slot: numberToHex(s, { size: 32 }), blockNumber });
      out.push(v ? hexToBigInt(v) : 0n);
    }
  }
  return out;
}

/** Deployed Multicall3 on Base; used to read many view results at one block. */
async function views(
  client: PublicClient,
  blockNumber: bigint,
  calls: { address: Address; abi: typeof machineAbi; functionName: string; args: readonly unknown[] }[],
): Promise<unknown[]> {
  const out: unknown[] = [];
  const BATCH = 200;
  for (let i = 0; i < calls.length; i += BATCH) {
    // eslint-disable-next-line no-await-in-loop
    const res = await client.multicall({ contracts: calls.slice(i, i + BATCH) as never, blockNumber, allowFailure: true });
    for (const r of res as { status: string; result?: unknown }[]) out.push(r.status === "success" ? r.result : undefined);
  }
  return out;
}

export type Pools = bigint[][]; // [tier 0..5] -> ordered token ids

/**
 * Ordered contents of packTierPools[packId][0..5] at `blockNumber`, read from storage and
 * self-checked against the machine's own getters at the same block: each length equals
 * getPackTierPoolSize, each token is eligible for the pack in that tier, its packPoolIndex is
 * its position + 1, and no token appears twice. Any mismatch throws (layout or state not what
 * this tool assumes).
 */
export async function readPools(client: PublicClient, machine: Address, packId: bigint, blockNumber: bigint): Promise<Pools> {
  const base = mappingSlot(packId, MACHINE_STORAGE_SLOT + F_PACK_TIER_POOLS);
  const lengths = await readSlots(client, machine, [...Array(NUM_TIERS).keys()].map((t) => base + BigInt(t)), blockNumber);
  const sizes = await views(
    client,
    blockNumber,
    [...Array(NUM_TIERS).keys()].map((t) => ({ address: machine, abi: machineAbi, functionName: "getPackTierPoolSize", args: [packId, t] })),
  );
  for (let t = 0; t < NUM_TIERS; t++) {
    if (sizes[t] !== lengths[t]) throw new Error(`pool layout check failed: tier ${t} storage length ${lengths[t]} != getPackTierPoolSize ${String(sizes[t])}`);
    if (lengths[t] > 100_000n) throw new Error(`pool tier ${t} length ${lengths[t]} is implausible`);
  }
  const slots: bigint[] = [];
  for (let t = 0; t < NUM_TIERS; t++) {
    const data = arrayDataSlot(base + BigInt(t));
    for (let i = 0n; i < lengths[t]; i++) slots.push(data + i);
  }
  const flat = await readSlots(client, machine, slots, blockNumber);
  const pools: Pools = [];
  let k = 0;
  for (let t = 0; t < NUM_TIERS; t++) {
    pools.push(flat.slice(k, k + Number(lengths[t])));
    k += Number(lengths[t]);
  }
  const all = pools.flat();
  if (new Set(all.map(String)).size !== all.length) throw new Error("pool check failed: a token appears twice in the pack's pools");
  const idxBase = MACHINE_STORAGE_SLOT + F_PACK_POOL_INDEX;
  const idx = await readSlots(client, machine, all.map((tok) => mappingSlot(packId, mappingSlot(tok, idxBase))), blockNumber);
  const checks = await views(
    client,
    blockNumber,
    all.flatMap((tok) => [
      { address: machine, abi: machineAbi, functionName: "isTokenEligibleForPack", args: [tok, packId] },
      { address: machine, abi: machineAbi, functionName: "getPackTokenTier", args: [tok, packId] },
    ]),
  );
  k = 0;
  for (let t = 0; t < NUM_TIERS; t++) {
    for (let i = 0; i < pools[t].length; i++, k++) {
      const tok = pools[t][i];
      if (checks[2 * k] !== true) throw new Error(`pool check failed: token ${tok} (tier ${t}) is not eligible for pack ${packId}`);
      if (checks[2 * k + 1] !== t) throw new Error(`pool check failed: token ${tok} has tier ${String(checks[2 * k + 1])}, found in tier ${t}`);
      if (idx[k] !== BigInt(i + 1)) throw new Error(`pool check failed: token ${tok} packPoolIndex ${idx[k]} != position ${i + 1}`);
    }
  }
  return pools;
}

/** keccak256(abi.encode(machine, packId, uint256[][] pools)) over tiers 0..5 in pool order. */
export function poolFingerprint(machine: Address, packId: bigint, pools: Pools): Hex {
  return keccak256(
    encodeAbiParameters([{ type: "address" }, { type: "uint256" }, { type: "uint256[][]" }], [getAddress(machine), packId, pools]),
  );
}

export interface PendingOpen {
  user: Address;
  cardsCount: number;
  packId: bigint;
}

/**
 * PackMachine pendingOpens[requestId] on the deployed implementation (slot 0: user | cardsCount;
 * 1: packId). Cross-checked against the router's RandomnessRequested(requestId, machine, user)
 * in the request block.
 */
export async function readPendingOpen(
  client: PublicClient,
  machine: Address,
  router: Address,
  requestId: bigint,
  requestBlock: bigint,
  blockNumber: bigint,
): Promise<PendingOpen> {
  const base = mappingSlot(requestId, MACHINE_STORAGE_SLOT + F_PENDING_OPENS);
  const [s0, s1] = await readSlots(client, machine, [base, base + 1n], blockNumber);
  const user = getAddress(numberToHex(s0 & ((1n << 160n) - 1n), { size: 20 }));
  const cardsCount = Number((s0 >> 160n) & 0xffn);
  if (BigInt(user) === 0n) throw new Error(`the machine has no pending open for request ${requestId} (already settled?)`);
  if (cardsCount < 1) throw new Error(`pending open ${requestId} has cardsCount 0`);
  const req = await client.getLogs({ address: router, event: EV_ROUTER_REQUESTED, args: { requestId }, fromBlock: requestBlock, toBlock: requestBlock });
  if (req.length !== 1) throw new Error(`router RandomnessRequested for ${requestId} not found in block ${requestBlock}`);
  if (getAddress(req[0].args.packMachine as Address) !== getAddress(machine)) throw new Error(`request ${requestId} belongs to machine ${req[0].args.packMachine}`);
  if (getAddress(req[0].args.user as Address) !== user) throw new Error(`pending-open layout check failed: user ${user} != router event user ${req[0].args.user}`);
  return { user, cardsCount, packId: s1 };
}

/** The tier weights the deployed machine will use at delivery: its registry's, read live. */
export async function readTierWeights(client: PublicClient, machine: Address, packId: bigint, blockNumber: bigint): Promise<number[]> {
  const p = await client.readContract({ address: machine, abi: machineAbi, functionName: "getPack", args: [packId], blockNumber });
  return [...p.tierWeights].map(Number);
}

/** Everything the draw reads besides the words, at one block. */
export interface DrawState {
  pools: Pools;
  tierWeights: number[];
  poolFingerprint: Hex;
}

export async function readDrawState(client: PublicClient, machine: Address, packId: bigint, blockNumber: bigint): Promise<DrawState> {
  await assertDeployedCode(client, machine, blockNumber);
  const pools = await readPools(client, machine, packId, blockNumber);
  const tierWeights = await readTierWeights(client, machine, packId, blockNumber);
  return { pools, tierWeights, poolFingerprint: poolFingerprint(machine, packId, pools) };
}

export function sameWeights(a: number[], b: number[]): boolean {
  return a.length === NUM_TIERS && b.length === NUM_TIERS && a.every((w, i) => w === b[i]);
}

// ---------------------------------------------------------------------------------------------
// Outcome
// ---------------------------------------------------------------------------------------------

export interface Draw {
  tokenId: bigint | null; // null: CardFailed(0), every tier of the pack empty
  tier: number | null;
}

/**
 * The deployed machine's draw (same as PackFulfillLib.fulfillRandomness), assuming each card transfer succeeds (the simulation
 * checks that): weighted tier over non-empty tiers with word >> 128, index uint128(word) % len,
 * then the won token leaves the pool by swap-and-pop.
 */
export function predictDraws(poolsIn: Pools, tierWeights: number[], words: bigint[], cardsCount: number): Draw[] {
  if (words.length < cardsCount) throw new Error(`need ${cardsCount} words, have ${words.length}`);
  const pools = poolsIn.map((p) => [...p]);
  const draws: Draw[] = [];
  const U128 = (1n << 128n) - 1n;
  for (let i = 0; i < cardsCount; i++) {
    const word = words[i];
    const active = pools.map((p, t) => (p.length ? BigInt(tierWeights[t]) : 0n));
    const total = active.reduce((a, b) => a + b, 0n);
    if (total === 0n) {
      draws.push({ tokenId: null, tier: null });
      continue;
    }
    const r = (word >> 128n) % total;
    let cum = 0n;
    let tier = 0;
    for (let t = 0; t < NUM_TIERS; t++) {
      cum += active[t];
      if (r < cum) {
        tier = t;
        break;
      }
    }
    const pool = pools[tier];
    const index = Number((word & U128) % BigInt(pool.length));
    const tokenId = pool[index];
    pool[index] = pool[pool.length - 1];
    pool.pop();
    draws.push({ tokenId, tier });
  }
  return draws;
}

export interface BatchTx {
  to: Address;
  data: Hex;
}

export interface SimulatedOutcome {
  won: bigint[];
  failed: bigint[];
}

export interface SimCall {
  from: Address;
  to: Address;
  data: Hex;
}

export interface SimResult {
  ok: boolean;
  returnData: Hex;
  logs: { address: Address; topics: Hex[]; data: Hex }[];
  error?: string;
}

/** eth_simulateV1: `calls` in order, in one simulated block on top of `blockNumber`. */
export async function simulateCalls(client: PublicClient, calls: SimCall[], blockNumber: bigint): Promise<SimResult[]> {
  const res = (await client.request({
    method: "eth_simulateV1",
    params: [{ blockStateCalls: [{ calls }], validation: false }, numberToHex(blockNumber)],
  } as never)) as { calls: { status: Hex; returnData: Hex; logs?: SimResult["logs"]; error?: { message?: string } }[] }[];
  const out = res?.[0]?.calls;
  if (!Array.isArray(out) || out.length !== calls.length) throw new Error("eth_simulateV1 returned an unexpected result");
  return out.map((c) => ({ ok: hexToBigInt(c.status) === 1n, returnData: c.returnData, logs: c.logs ?? [], error: c.error?.message }));
}

/**
 * The exact batch simulated as the Safe on top of `blockNumber`: every call must succeed.
 * Returns the CardWon / CardFailed token ids the machine emits for `requestId`.
 */
export async function simulateBatch(
  client: PublicClient,
  txs: BatchTx[],
  machine: Address,
  requestId: bigint,
  blockNumber: bigint,
): Promise<SimulatedOutcome> {
  const calls = await simulateCalls(client, txs.map((t) => ({ from: SAFE, to: t.to, data: t.data })), blockNumber);
  const won: bigint[] = [];
  const failed: bigint[] = [];
  calls.forEach((c, i) => {
    if (!c.ok) throw new Error(`simulated call ${i + 1} of the batch reverts: ${c.error ?? "no reason"}`);
    for (const l of c.logs) {
      if (getAddress(l.address) !== getAddress(machine) || l.topics.length !== 4) continue;
      if (hexToBigInt(l.topics[3]) !== requestId) continue;
      if (l.topics[0] === CARD_WON) won.push(hexToBigInt(l.topics[2]));
      if (l.topics[0] === CARD_FAILED) failed.push(hexToBigInt(l.topics[2]));
    }
  });
  return { won, failed };
}

/** The draws as the simulation reports them, for comparison. */
export function drawsAsOutcome(draws: Draw[]): SimulatedOutcome {
  return {
    won: draws.filter((d) => d.tokenId !== null).map((d) => d.tokenId as bigint),
    failed: draws.filter((d) => d.tokenId === null).map(() => 0n),
  };
}

export function sameOutcome(a: SimulatedOutcome, b: SimulatedOutcome): boolean {
  const eq = (x: bigint[], y: bigint[]) => x.length === y.length && x.every((v, i) => v === y[i]);
  return eq(a.won, b.won) && eq(a.failed, b.failed);
}

// ---------------------------------------------------------------------------------------------
// Freeze state
// ---------------------------------------------------------------------------------------------

export interface FreezeState {
  block: bigint;
  machinePaused: boolean;
  buybackPool: Address;
  buybackPoolPaused: boolean;
  /** Every address ever authorized as a depositor (checkpoint + later events) and its status. */
  depositors: { address: Address; authorized: boolean }[];
}

/**
 * Every address that has ever been passed to setAuthorizedDepositor on the machine, from the
 * checkpoint plus AuthorizedDepositorUpdated events after it (chunked scan up to `latest`).
 */
export async function depositorCandidates(client: PublicClient, machine: Address, latest: bigint, tuning: ScanTuning): Promise<Address[]> {
  if (getAddress(machine) !== STAGING_MACHINE) throw new Error("the depositor checkpoint covers only the staging machine");
  if (latest < DEPOSITOR_CHECKPOINT.block) throw new Error(`latest block ${latest} is before the depositor checkpoint ${DEPOSITOR_CHECKPOINT.block}`);
  const cp = await client.getBlock({ blockNumber: DEPOSITOR_CHECKPOINT.block });
  if (cp.hash !== DEPOSITOR_CHECKPOINT.hash) throw new Error(`block ${DEPOSITOR_CHECKPOINT.block} hash ${cp.hash} is not the checkpoint's; wrong chain`);
  const set = new Set<Address>(DEPOSITOR_CHECKPOINT.depositors.map((a) => getAddress(a)));
  if (latest > DEPOSITOR_CHECKPOINT.block) {
    const logs = await scanLogs(client, { address: machine, events: EV_DEPOSITOR, fromBlock: DEPOSITOR_CHECKPOINT.block + 1n, toBlock: latest, ...tuning });
    for (const l of logs) set.add(getAddress(("0x" + (l.topics[1] as string).slice(26)) as Address));
  }
  return [...set];
}

export async function readFreezeState(client: PublicClient, machine: Address, depositors: Address[], blockNumber: bigint): Promise<FreezeState> {
  const [machinePaused, bbSlot] = await Promise.all([
    client.readContract({ address: machine, abi: machineAbi, functionName: "paused", blockNumber }),
    readSlots(client, machine, [MACHINE_STORAGE_SLOT + F_BUYBACK_POOL], blockNumber),
  ]);
  const buybackPool = getAddress(numberToHex(bbSlot[0] & ((1n << 160n) - 1n), { size: 20 }));
  const buybackPoolPaused =
    BigInt(buybackPool) === 0n ? true : await client.readContract({ address: buybackPool, abi: pausableAbi, functionName: "paused", blockNumber });
  const statuses = await readSlots(
    client,
    machine,
    depositors.map((d) => mappingSlot(d, MACHINE_STORAGE_SLOT + F_AUTHORIZED_DEPOSITORS)),
    blockNumber,
  );
  return {
    block: blockNumber,
    machinePaused,
    buybackPool,
    buybackPoolPaused,
    depositors: depositors.map((address, i) => ({ address, authorized: statuses[i] !== 0n })),
  };
}

/** Why the state is not frozen; empty when every mutator reachable without a trusted role is closed. */
export function freezeProblems(s: FreezeState): string[] {
  const p: string[] = [];
  if (!s.machinePaused) p.push(`block ${s.block}: the staging PackMachine is not paused (openPack is open)`);
  if (s.buybackPool !== STAGING_BUYBACK_POOL) p.push(`block ${s.block}: machine buybackPool is ${s.buybackPool}, expected ${STAGING_BUYBACK_POOL}`);
  if (!s.buybackPoolPaused) p.push(`block ${s.block}: BuybackPool ${s.buybackPool} is not paused (buyback -> depositFromPool is open to any card holder)`);
  for (const d of s.depositors) {
    if (d.authorized) p.push(`block ${s.block}: ${d.address} is still an authorized depositor of the machine (depositFromPool is open to it)`);
  }
  return p;
}

/**
 * Pause and depositor transitions in [fromBlock, toBlock]. With the state frozen at fromBlock - 1
 * and at toBlock, none may exist: that proves the freeze held for every block in between.
 */
export async function freezeTransitions(
  client: PublicClient,
  machine: Address,
  buybackPool: Address,
  fromBlock: bigint,
  toBlock: bigint,
  tuning: ScanTuning,
): Promise<string[]> {
  if (fromBlock > toBlock) return [];
  const logs = await scanLogs(client, {
    address: [machine, buybackPool],
    events: [EV_PAUSED, EV_UNPAUSED, EV_DEPOSITOR, EV_BUYBACK_POOL],
    fromBlock,
    toBlock,
    ...tuning,
  });
  const names: Record<string, string> = {
    [keccak256(toHex("Paused(address)"))]: "Paused",
    [keccak256(toHex("Unpaused(address)"))]: "Unpaused",
    [keccak256(toHex("AuthorizedDepositorUpdated(address,bool)"))]: "AuthorizedDepositorUpdated",
    [keccak256(toHex("BuybackPoolUpdated(address,address)"))]: "BuybackPoolUpdated",
  };
  return logs.map((l) => `${names[l.topics[0] as string] ?? l.topics[0]} on ${l.address} in block ${l.blockNumber} (tx ${l.transactionHash})`);
}

// ---------------------------------------------------------------------------------------------
// Batches
// ---------------------------------------------------------------------------------------------

export function recoveryTxs(requestId: bigint, words: bigint[], coordinator: Address): BatchTx[] {
  return [
    { to: STAGING_ROUTER, data: encodeFunctionData({ abi: routerAbi, functionName: "setVRFCoordinator", args: [SAFE] }) },
    { to: STAGING_ROUTER, data: encodeFunctionData({ abi: routerAbi, functionName: "rawFulfillRandomWords", args: [requestId, words] }) },
    { to: STAGING_ROUTER, data: encodeFunctionData({ abi: routerAbi, functionName: "setVRFCoordinator", args: [getAddress(coordinator)] }) },
  ];
}

export function recoveryWords(blockHash: Hex, requestId: bigint, numWords: number): bigint[] {
  const words: bigint[] = [];
  for (let i = 0n; i < BigInt(numWords); i++) {
    words.push(hexToBigInt(keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }, { type: "uint256" }], [blockHash, requestId, i]))));
  }
  return words;
}

/** Decodes a paused() return (for eth_simulateV1 checks of post-batch state). */
export function decodeBool(data: Hex): boolean {
  return decodeFunctionResult({ abi: pausableAbi, functionName: "paused", data }) as boolean;
}

export const depositFromPoolAbi = parseAbi(["function depositFromPool(uint256[] tokenIds, uint8[] tiers, address tokensOwner)"]);

/**
 * Calldata that reaches depositFromPool's authorization check and nothing else: with empty
 * arrays the function returns right after it. Simulated from a depositor, it succeeds exactly
 * when that address may deposit.
 */
export function emptyDepositFromPool(owner: Address): Hex {
  return encodeFunctionData({ abi: depositFromPoolAbi, functionName: "depositFromPool", args: [[], [], owner] });
}

export const PAUSED_CALL: Hex = encodeFunctionData({ abi: pausableAbi, functionName: "paused" });

/** Safe Transaction Builder JSON (same shape as build-safe-payloads.ts). */
export function txBuilderJson(name: string, description: string, txs: BatchTx[]): string {
  return (
    JSON.stringify(
      {
        version: "1.0",
        chainId: "8453",
        createdAt: Date.now(),
        meta: { name, description, txBuilderVersion: "1.16.5", createdFromSafeAddress: SAFE, createdFromOwnerAddress: "" },
        transactions: txs.map((t) => ({ to: getAddress(t.to), value: "0", data: t.data, contractMethod: null, contractInputsValues: null })),
      },
      null,
      2,
    ) + "\n"
  );
}
