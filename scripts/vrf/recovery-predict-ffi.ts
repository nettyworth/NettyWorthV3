/**
 * FFI entry point for contracts/test/NettyVRFCoordinator.recoveryFreeze.fork.t.sol (forge vm.ffi):
 * runs the recovery tooling's own fingerprint and card prediction (recovery-freeze.ts) on pools
 * read from the forked deployed machine, so the test can compare them with what the deployed
 * PackFulfillLib actually delivers.
 *
 *   node --experimental-strip-types scripts/vrf/recovery-predict-ffi.ts <hex>
 *     <hex> = abi.encode(address machine, uint256 packId, uint256[][] pools, uint32[6] tierWeights,
 *                        uint256 cardsCount, uint256[] words)
 *     -> abi.encode(bytes32 fingerprint, uint256[] won, uint256 failedCount)
 *
 * TEST TOOLING ONLY. Public data in, public data out.
 */
import { decodeAbiParameters, encodeAbiParameters, type Hex } from "viem";
import { drawsAsOutcome, poolFingerprint, predictDraws } from "./recovery-freeze.ts";

const input = process.argv[2];
if (!input || !/^0x[0-9a-fA-F]*$/.test(input)) {
  console.error("usage: recovery-predict-ffi.ts <abi-encoded hex>");
  process.exit(2);
}
const [machine, packId, pools, weights, cardsCount, words] = decodeAbiParameters(
  [
    { type: "address" },
    { type: "uint256" },
    { type: "uint256[][]" },
    { type: "uint32[6]" },
    { type: "uint256" },
    { type: "uint256[]" },
  ],
  input as Hex,
);
const fp = poolFingerprint(machine, packId, pools.map((p) => [...p]));
const out = drawsAsOutcome(predictDraws(pools.map((p) => [...p]), [...weights].map(Number), [...words], Number(cardsCount)));
process.stdout.write(
  encodeAbiParameters([{ type: "bytes32" }, { type: "uint256[]" }, { type: "uint256" }], [fp, out.won, BigInt(out.failed.length)]),
);
