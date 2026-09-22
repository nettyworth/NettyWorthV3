/**
 * End-to-end rehearsal of the staging manual-recovery TOOLING on an anvil fork of Base
 * (audit N-01 / N-02, re-audit R-01 / R-02 / R-04). Runs the real scripts as subprocesses against the fork and checks that
 * they refuse when any pool mutator is left open or changes, and that a correctly frozen
 * recovery delivers exactly the recorded card.
 *
 *   forge build   # out/NettyVRFCoordinator.sol/NettyVRFCoordinator.json
 *   FORK_RPC_URL=https://mainnet.base.org node --experimental-strip-types scripts/vrf/rehearse-recovery.anvil.ts
 *
 * Needs anvil on PATH and an RPC that serves recent history (mainnet.base.org does). The fork
 * starts a few blocks behind the tip, which is after the depositor checkpoint in
 * recovery-freeze.ts. Nothing touches a real chain: every transaction goes to the local fork,
 * as impersonated accounts or anvil's public test keys.
 * TEST TOOLING ONLY: it uses a fixed test VRF key (the fork tests' VRF_SK).
 */
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createTestClient,
  encodeFunctionData,
  getAddress,
  hexToBigInt,
  http,
  keccak256,
  numberToHex,
  parseAbi,
  publicActions,
  toHex,
  walletActions,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { proofToAbiStruct, proveForRequest } from "./ecvrf.ts";
import { proveKeyPossession } from "./key-possession.ts";
import {
  MACHINE_STORAGE_SLOT,
  mappingSlot,
  SAFE,
  STAGING_ASSET_LENDING_POOL,
  STAGING_BUYBACK_POOL,
  STAGING_MACHINE,
  STAGING_PROXIES,
  STAGING_ROUTER,
  ERC1967_IMPLEMENTATION_SLOT,
} from "./recovery-freeze.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "../..");
const FORK_RPC = process.env.FORK_RPC_URL ?? process.env.BASE_FORK_RPC_URL ?? "https://mainnet.base.org";
const PORT = 18545 + Math.floor(Math.random() * 1000);
const URL = `http://127.0.0.1:${PORT}`;
const OUT = mkdtempSync(join(tmpdir(), "vrf-recovery-rehearsal-"));

const USDC = getAddress("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");
const STAGING_PM = getAddress("0x3AED0BcDf2a578688d31ac394d99Fa710b780EC6");
const STAGING_REGISTRY = getAddress("0xb57233fbc2539dbD3285e95Dd28E3E40Ea670552");
/** Production router: stands in for a second router sharing the coordinator (re-audit R-02). */
const OTHER_ROUTER = getAddress("0x4aD5C628030546D12754F608081a6256D6c5FDc9");
/** An older BuybackPool implementation with code, to fake an unreviewed upgrade (re-audit R-04). */
const OTHER_BUYBACK_IMPL = getAddress("0x591fb8f6377f4f629e41a132692a8931be1619e7");
const PACK_ID = 13n;
const VRF_SK = 0x5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eed5eedn;
// anvil's well-known, publicly documented dev keys (funded on the fork by anvil).
const deployer = privateKeyToAccount("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80");
const fulfiller = privateKeyToAccount("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d");
const victim = privateKeyToAccount("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a");
const signer = privateKeyToAccount("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6");

const coordArtifact = JSON.parse(readFileSync(join(ROOT, "out/NettyVRFCoordinator.sol/NettyVRFCoordinator.json"), "utf8")) as {
  abi: unknown[];
  bytecode: { object: Hex };
};
const routerAbi = parseAbi([
  "function setVRFCoordinator(address)",
  "function setRequestConfirmations(uint16)",
  "function setCallbackGasLimit(uint32)",
]);
const machineAbi = parseAbi([
  "function pause()",
  "function unpause()",
  "function paused() view returns (bool)",
  "function setAuthorizedDepositor(address,bool)",
  "function setPackEligibility(uint256,uint256[],uint8[],bool)",
  "function openPack(address user, uint256 packId, bytes signature)",
  "function getUserInfo(address) view returns ((uint256 openNonce, bool claimedFirstOpenDiscount))",
  "function getPackTierPoolSize(uint256,uint8) view returns (uint256)",
]);
const pausable = parseAbi(["function pause()", "function unpause()", "function paused() view returns (bool)"]);
const pmAbi = parseAbi(["function grantRole(bytes32,address)"]);
const erc20 = parseAbi(["function approve(address,uint256) returns (bool)"]);
const registryAbi = parseAbi(["function setPackTierWeights(address,uint256,uint32[6])"]);
const requestAbi = parseAbi([
  "struct RandomWordsRequest { bytes32 keyHash; uint256 subId; uint16 requestConfirmations; uint32 callbackGasLimit; uint32 numWords; bytes extraArgs; }",
  "function requestRandomWords(RandomWordsRequest req) returns (uint256)",
]);
const CARD_WON = keccak256(toHex("CardWon(address,uint256,uint256)"));

const client = createTestClient({ mode: "anvil", chain: base, transport: http(URL, { timeout: 120_000 }) })
  .extend(publicActions)
  .extend(walletActions);

let anvil: ChildProcess | undefined;
const results: { name: string; ok: boolean; detail: string }[] = [];
function expect(name: string, ok: boolean, detail: string): void {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? `: ${detail}` : ""}`);
}

async function send(from: Address | typeof deployer, to: Address, data: Hex): Promise<bigint> {
  const account = typeof from === "string" ? from : from;
  if (typeof account === "string") {
    await client.impersonateAccount({ address: account });
    await client.setBalance({ address: account, value: 10n ** 20n });
  }
  const hash = await client.sendTransaction({ account: account as never, to, data, chain: base });
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`tx to ${to} (${data.slice(0, 10)}) from ${typeof account === "string" ? account : account.address} reverted`);
  return receipt.blockNumber;
}
const asSafe = (to: Address, data: Hex) => send(SAFE, to, data);

function tool(script: string, args: string[]): { code: number; out: string } {
  const r = spawnSync("node", ["--experimental-strip-types", join(HERE, script), ...args, "--rpc", URL], {
    cwd: ROOT,
    encoding: "utf8",
    timeout: 600_000,
  });
  return { code: r.status ?? -1, out: `${r.stdout}\n${r.stderr}` };
}

async function waitForAnvil(): Promise<void> {
  for (let i = 0; i < 120; i++) {
    try {
      await client.getBlockNumber();
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 1000));
    }
  }
  throw new Error("anvil did not start");
}

async function announceAndMine(): Promise<bigint> {
  const announced = (await client.getBlockNumber()) + 2n;
  await client.mine({ blocks: 3 });
  return announced;
}

async function isAuthorized(d: Address): Promise<boolean> {
  const v = await client.getStorageAt({ address: STAGING_MACHINE, slot: numberToHex(mappingSlot(d, MACHINE_STORAGE_SLOT + 6n), { size: 32 }) });
  return hexToBigInt(v ?? "0x0") !== 0n;
}

async function executeBatchFile(file: string): Promise<{ won: bigint[] }> {
  const batch = JSON.parse(readFileSync(file, "utf8")) as { transactions: { to: Address; data: Hex }[] };
  const won: bigint[] = [];
  await client.impersonateAccount({ address: SAFE });
  for (const t of batch.transactions) {
    const hash = await client.sendTransaction({ account: SAFE, to: t.to, data: t.data, chain: base });
    const rc = await client.waitForTransactionReceipt({ hash });
    if (rc.status !== "success") throw new Error(`batch call to ${t.to} reverted`);
    for (const l of rc.logs) if (getAddress(l.address) === STAGING_MACHINE && l.topics[0] === CARD_WON) won.push(hexToBigInt(l.topics[2] as Hex));
  }
  return { won };
}

async function main(): Promise<void> {
  const tip = await createTestClient({ mode: "anvil", chain: base, transport: http(FORK_RPC) }).extend(publicActions).getBlockNumber();
  const forkBlock = tip - 5n;
  anvil = spawn(
    "anvil",
    ["--fork-url", FORK_RPC, "--fork-block-number", forkBlock.toString(), "--port", String(PORT), "--silent", "--fork-retry-backoff", "2000", "--retries", "10"],
    { stdio: "ignore" },
  );
  await waitForAnvil();
  console.log(`anvil fork of Base at block ${forkBlock} on ${URL}; outputs in ${OUT}`);

  // --- Deploy and switch, exactly as batches 01 and 03 do (the Safe impersonated) ---
  const deployHash = await client.deployContract({
    account: deployer,
    abi: coordArtifact.abi as never,
    bytecode: coordArtifact.bytecode.object,
    args: [SAFE] as never,
    chain: base,
  });
  const deployRc = await client.waitForTransactionReceipt({ hash: deployHash });
  const coord = getAddress(deployRc.contractAddress as Address);
  const coordAbi = coordArtifact.abi as never;
  const kp = proveKeyPossession(VRF_SK, 8453n, coord);
  await asSafe(coord, encodeFunctionData({ abi: coordAbi, functionName: "registerKey", args: [[BigInt(kp.publicKey[0]), BigInt(kp.publicKey[1])], proofToAbiStruct(kp.proof)] } as never));
  await asSafe(coord, encodeFunctionData({ abi: coordAbi, functionName: "setRouter", args: [STAGING_ROUTER, true] } as never));
  await asSafe(coord, encodeFunctionData({ abi: coordAbi, functionName: "setFulfiller", args: [fulfiller.address, true] } as never));
  await asSafe(STAGING_ROUTER, encodeFunctionData({ abi: routerAbi, functionName: "setVRFCoordinator", args: [coord] }));
  await asSafe(STAGING_ROUTER, encodeFunctionData({ abi: routerAbi, functionName: "setRequestConfirmations", args: [1] }));
  await asSafe(STAGING_PM, encodeFunctionData({ abi: pmAbi, functionName: "grantRole", args: [keccak256(toHex("PACK_OPERATOR_ROLE")), signer.address] }));
  console.log(`coordinator ${coord} deployed at block ${deployRc.blockNumber}, staging router switched`);

  // --- A stranded (Failed) staging open ---
  await client.request({ method: "anvil_dealERC20", params: [victim.address, USDC, numberToHex(1_000_000_000n)] } as never);
  await send(victim, USDC, encodeFunctionData({ abi: erc20, functionName: "approve", args: [STAGING_MACHINE, 2n ** 255n] }));
  await asSafe(STAGING_ROUTER, encodeFunctionData({ abi: routerAbi, functionName: "setCallbackGasLimit", args: [40_000] }));
  const info = await client.readContract({ address: STAGING_MACHINE, abi: machineAbi, functionName: "getUserInfo", args: [victim.address] });
  const sig = await signer.signTypedData({
    domain: { name: "PackMachine", version: "1", chainId: 8453, verifyingContract: STAGING_MACHINE },
    types: { OpenPack: [{ name: "user", type: "address" }, { name: "packId", type: "uint256" }, { name: "nonce", type: "uint256" }, { name: "codeId", type: "bytes32" }] },
    primaryType: "OpenPack",
    message: { user: victim.address, packId: PACK_ID, nonce: info.openNonce, codeId: `0x${"0".repeat(64)}` },
  });
  const openHash = await client.sendTransaction({
    account: victim,
    to: STAGING_MACHINE,
    data: encodeFunctionData({ abi: machineAbi, functionName: "openPack", args: [victim.address, PACK_ID, sig] }),
    chain: base,
  });
  const openRc = await client.waitForTransactionReceipt({ hash: openHash });
  const reqLog = openRc.logs.find((l) => getAddress(l.address) === coord && l.topics[0] === keccak256(toHex("RandomWordsRequested(uint256,address,bytes32,uint256,uint64,uint32,uint32)")));
  if (!reqLog) throw new Error("no RandomWordsRequested");
  const rid = hexToBigInt(reqLog.topics[1] as Hex);
  await client.mine({ blocks: 1 });
  const req = (await client.readContract({ address: coord, abi: coordAbi, functionName: "getRequest", args: [rid] } as never)) as { preSeed: bigint };
  const reqBlock = await client.getBlock({ blockNumber: openRc.blockNumber });
  const { proof } = proveForRequest(VRF_SK, req.preSeed, reqBlock.hash as string);
  await send(fulfiller, coord, encodeFunctionData({ abi: coordAbi, functionName: "fulfill", args: [rid, proofToAbiStruct(proof)] } as never));
  const status = ((await client.readContract({ address: coord, abi: coordAbi, functionName: "getRequest", args: [rid] } as never)) as { status: number }).status;
  if (status !== 3) throw new Error(`expected Failed, got ${status}`);
  await asSafe(STAGING_ROUTER, encodeFunctionData({ abi: routerAbi, functionName: "setCallbackGasLimit", args: [500_000] }));
  console.log(`request ${rid} is Failed (stranded)`);

  const builderArgs = (announced: bigint) => ["--coordinator", coord, "--request-id", rid.toString(), "--announced-block", announced.toString(), "--out", OUT];
  const pendingArgs = ["--coordinator", coord, "--from-block", deployRc.blockNumber.toString(), "--only-router", STAGING_ROUTER];
  const pending = tool("check-pending.ts", pendingArgs);
  expect("check-pending --coordinator reports the Failed request (exit 3)", pending.code === 3 && /needs manual recovery/.test(pending.out), `exit ${pending.code}`);

  const clean = await client.snapshot();

  // R1: nothing frozen.
  {
    const a = await announceAndMine();
    const r = tool("build-recovery-payload.ts", builderArgs(a));
    expect("builder refuses with nothing frozen", r.code === 2 && /PackMachine is not paused/.test(r.out) && /BuybackPool .* is not paused/.test(r.out), `exit ${r.code}`);
    await client.revert({ id: clean });
  }
  // R2: BuybackPool left open.
  let snap = await client.snapshot();
  {
    await asSafe(STAGING_MACHINE, encodeFunctionData({ abi: machineAbi, functionName: "pause" }));
    await asSafe(STAGING_MACHINE, encodeFunctionData({ abi: machineAbi, functionName: "setAuthorizedDepositor", args: [STAGING_ASSET_LENDING_POOL, false] }));
    const a = await announceAndMine();
    const r = tool("build-recovery-payload.ts", builderArgs(a));
    expect("builder refuses with the BuybackPool unpaused", r.code === 2 && /BuybackPool .* is not paused/.test(r.out) && !/PackMachine is not paused/.test(r.out), `exit ${r.code}`);
    await client.revert({ id: snap });
  }
  // R3: AssetLendingPool left authorized.
  snap = await client.snapshot();
  {
    await asSafe(STAGING_MACHINE, encodeFunctionData({ abi: machineAbi, functionName: "pause" }));
    await asSafe(STAGING_BUYBACK_POOL, encodeFunctionData({ abi: pausable, functionName: "pause" }));
    const a = await announceAndMine();
    const r = tool("build-recovery-payload.ts", builderArgs(a));
    expect("builder refuses with the AssetLendingPool still an authorized depositor", r.code === 2 && /still an authorized depositor/.test(r.out), `exit ${r.code}`);
    await client.revert({ id: snap });
  }
  // R4: frozen only after the announced block was mined.
  snap = await client.snapshot();
  {
    const a = await announceAndMine();
    const out4 = mkdtempSync(join(tmpdir(), "vrf-recovery-r4-"));
    const f = tool("build-recovery-freeze.ts", ["--out", out4]);
    await executeBatchFile(join(out4, "recovery-freeze.json"));
    await client.mine({ blocks: 2 });
    const r = tool("build-recovery-payload.ts", builderArgs(a));
    expect("builder refuses when the freeze came after the announced block", f.code === 0 && r.code === 2 && new RegExp(`block ${a}: .*not paused`).test(r.out), `freeze exit ${f.code}, builder exit ${r.code}`);
    await client.revert({ id: snap });
  }

  // R5: the procedure. Freeze, (drain: nothing Pending), announce, build, check.
  const f = tool("build-recovery-freeze.ts", ["--out", OUT]);
  expect("build-recovery-freeze writes freeze + unfreeze after simulating both", f.code === 0 && /simulated as the Safe/.test(f.out), `exit ${f.code}`);
  const unfreezeCalls = () => (JSON.parse(readFileSync(join(OUT, "recovery-unfreeze.json"), "utf8")) as { transactions: unknown[] }).transactions.length;
  const fullUnfreeze = unfreezeCalls();
  await executeBatchFile(join(OUT, "recovery-freeze.json"));
  const noResume = tool("build-recovery-freeze.ts", ["--out", OUT]);
  expect("build-recovery-freeze refuses to rebuild during a freeze without --resume", noResume.code === 2 && /--resume/.test(noResume.out), `exit ${noResume.code}`);
  const again = tool("build-recovery-freeze.ts", ["--out", OUT, "--resume"]);
  expect(
    "build-recovery-freeze --resume once frozen: no freeze batch, full unfreeze kept",
    again.code === 0 && /already frozen/.test(again.out) && unfreezeCalls() === fullUnfreeze,
    `exit ${again.code}, unfreeze ${unfreezeCalls()}/${fullUnfreeze} call(s)`,
  );
  // R-01: part of the freeze is lifted, then restored with --resume. The unfreeze must still be
  // the full inverse of the pre-incident state, not of the partly frozen one.
  await asSafe(STAGING_BUYBACK_POOL, encodeFunctionData({ abi: pausable, functionName: "unpause" }));
  const partial = tool("build-recovery-freeze.ts", ["--out", OUT, "--resume"]);
  const partialFreeze = (JSON.parse(readFileSync(join(OUT, "recovery-freeze.json"), "utf8")) as { transactions: unknown[] }).transactions.length;
  expect(
    "R-01: rebuilding a partly lifted freeze keeps the full unfreeze",
    partial.code === 0 && partialFreeze === 1 && unfreezeCalls() === fullUnfreeze,
    `exit ${partial.code}, freeze ${partialFreeze} call(s), unfreeze ${unfreezeCalls()}/${fullUnfreeze} call(s)`,
  );
  await executeBatchFile(join(OUT, "recovery-freeze.json"));
  // R-02: a request from another router stays Pending on the shared coordinator. It must not
  // block the staging recovery (the staging-router filter), while the unfiltered scan still sees it.
  await asSafe(coord, encodeFunctionData({ abi: coordAbi, functionName: "setRouter", args: [OTHER_ROUTER, true] } as never));
  await send(OTHER_ROUTER, coord, encodeFunctionData({
    abi: requestAbi,
    functionName: "requestRandomWords",
    args: [{ keyHash: `0x${"0".repeat(64)}`, subId: 0n, requestConfirmations: 1, callbackGasLimit: 500_000, numWords: 1, extraArgs: "0x" }],
  }));
  const unfiltered = tool("check-pending.ts", ["--coordinator", coord, "--from-block", deployRc.blockNumber.toString()]);
  const filtered = tool("check-pending.ts", pendingArgs);
  expect(
    "R-02: another router's Pending request blocks only the unfiltered drain",
    unfiltered.code === 1 && filtered.code === 3,
    `unfiltered exit ${unfiltered.code}, --only-router exit ${filtered.code}`,
  );
  const announced = await announceAndMine();
  const b = tool("build-recovery-payload.ts", builderArgs(announced));
  expect("builder accepts a correct freeze and records the draw state", b.code === 0 && /freeze held from block/.test(b.out), `exit ${b.code}${b.code ? `: ${b.out.trim().split("\n").slice(-3).join(" | ")}` : ""}`);
  const tag = rid.toString().slice(0, 12);
  const recordFile = join(OUT, `recovery-${tag}.record.json`);
  const batchFile = join(OUT, `recovery-${tag}.json`);
  const record = JSON.parse(readFileSync(recordFile, "utf8")) as { predicted: { won: string[] }; pools: string[][] };
  const ok = tool("check-recovery-payload.ts", ["--record", recordFile]);
  expect("pre-execution check passes on an untouched freeze", ok.code === 0 && /EXECUTE NOW/.test(ok.out), `exit ${ok.code}`);

  // R6-R9: anything that moves after the build makes the pre-execution check refuse.
  const built = await client.snapshot();
  const tok = BigInt(record.pools[1][0]);
  await asSafe(STAGING_MACHINE, encodeFunctionData({ abi: machineAbi, functionName: "setPackEligibility", args: [PACK_ID, [tok], [], false] }));
  let c = tool("check-recovery-payload.ts", ["--record", recordFile]);
  expect("check refuses after an operator setPackEligibility", c.code === 2 && /pools changed since the build/.test(c.out), `exit ${c.code}`);
  await client.revert({ id: built });
  let s2 = await client.snapshot();
  await asSafe(STAGING_REGISTRY, encodeFunctionData({ abi: registryAbi, functionName: "setPackTierWeights", args: [STAGING_MACHINE, PACK_ID, [0, 10_000, 0, 0, 0, 0]] }));
  c = tool("check-recovery-payload.ts", ["--record", recordFile]);
  expect("check refuses after a registry tier-weight change", c.code === 2 && /tier weights changed/.test(c.out), `exit ${c.code}`);
  await client.revert({ id: s2 });
  s2 = await client.snapshot();
  await asSafe(STAGING_BUYBACK_POOL, encodeFunctionData({ abi: pausable, functionName: "unpause" }));
  await asSafe(STAGING_BUYBACK_POOL, encodeFunctionData({ abi: pausable, functionName: "pause" }));
  c = tool("check-recovery-payload.ts", ["--record", recordFile]);
  expect("check refuses after the BuybackPool was unpaused and re-paused", c.code === 2 && /freeze changed after the announced block: Unpaused/.test(c.out), `exit ${c.code}`);
  await client.revert({ id: s2 });
  const original = readFileSync(batchFile, "utf8");
  writeFileSync(batchFile, original.replace(/"createdAt": \d+/, '"createdAt": 1'));
  c = tool("check-recovery-payload.ts", ["--record", recordFile]);
  expect("check refuses a modified batch file", c.code === 2 && /was modified after it was built/.test(c.out), `exit ${c.code}`);
  writeFileSync(batchFile, original);
  // R-04: an implementation change that emits no event (a raw storage write) is caught by the pin.
  s2 = await client.snapshot();
  const bb = STAGING_PROXIES.find((p) => p.name === "BuybackPool");
  if (!bb) throw new Error("no BuybackPool pin");
  await client.setStorageAt({
    address: bb.proxy,
    index: numberToHex(ERC1967_IMPLEMENTATION_SLOT, { size: 32 }),
    value: numberToHex(hexToBigInt(OTHER_BUYBACK_IMPL), { size: 32 }),
  });
  c = tool("check-recovery-payload.ts", ["--record", recordFile]);
  expect("R-04: check refuses when a pinned proxy's implementation changed", c.code === 2 && /BuybackPool .* implementation is/.test(c.out), `exit ${c.code}`);
  await client.revert({ id: s2 });

  // R10: execute as the final signer, verify, unfreeze.
  const { won } = await executeBatchFile(batchFile);
  expect(
    "executed batch delivers exactly the recorded card",
    won.length === record.predicted.won.length && won.every((w, i) => w.toString() === record.predicted.won[i]),
    `won [${won}] recorded [${record.predicted.won}]`,
  );
  const settledPending = tool("check-pending.ts", pendingArgs);
  expect("check-pending shows it settled by the router (exit 0)", settledPending.code === 0 && /settled by router/.test(settledPending.out), `exit ${settledPending.code}`);
  c = tool("check-recovery-payload.ts", ["--record", recordFile]);
  expect("check refuses to run the batch twice", c.code === 2 && /already settled/.test(c.out), `exit ${c.code}`);
  await executeBatchFile(join(OUT, "recovery-unfreeze.json"));
  const mPaused = await client.readContract({ address: STAGING_MACHINE, abi: machineAbi, functionName: "paused" });
  const bPaused = await client.readContract({ address: STAGING_BUYBACK_POOL, abi: pausable, functionName: "paused" });
  expect("unfreeze restores machine, BuybackPool and depositor", !mPaused && !bPaused && (await isAuthorized(STAGING_ASSET_LENDING_POOL)), `machine paused ${mPaused}, BuybackPool paused ${bPaused}`);
  const fin = tool("build-recovery-freeze.ts", ["--out", OUT, "--finish"]);
  let baselineGone = false;
  try {
    readFileSync(join(OUT, "recovery-baseline.json"));
  } catch {
    baselineGone = true;
  }
  expect("--finish confirms the baseline is restored and closes the incident", fin.code === 0 && baselineGone, `exit ${fin.code}`);
}

try {
  await main();
} catch (err) {
  results.push({ name: "rehearsal ran to completion", ok: false, detail: err instanceof Error ? err.message : String(err) });
  console.error(err);
} finally {
  anvil?.kill();
}
const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} rehearsal checks passed`);
process.exit(failed.length ? 1 : 0);
