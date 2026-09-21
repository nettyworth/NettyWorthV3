/**
 * FFI entry point for the NettyVRFCoordinator fork tests (forge `vm.ffi`).
 *
 *   node --experimental-strip-types scripts/vrf/prove-ffi.ts prove <sk> <preSeed> <blockHash>
 *     -> abi.encode(VRF.Proof) for the request, the proof computed over
 *        keccak256(abi.encodePacked(preSeed, blockHash)) and proof.seed = preSeed.
 *   node --experimental-strip-types scripts/vrf/prove-ffi.ts output <sk> <preSeed> <blockHash>
 *     -> abi.encode(uint256 output), the expected VRF output for that request.
 *   node --experimental-strip-types scripts/vrf/prove-ffi.ts register <sk> <chainId> <coordinator>
 *     -> abi.encode(VRF.Proof), the registerKey proof of possession (key-possession.ts).
 *
 * TEST TOOLING ONLY: the secret key is passed on the command line.
 */
import { encodeAbiParameters } from "viem";
import { proveForRequest, type VrfProof } from "./ecvrf.ts";
import { proveKeyPossession } from "./key-possession.ts";

const PROOF_ABI = [
  {
    type: "tuple",
    components: [
      { name: "pk", type: "uint256[2]" },
      { name: "gamma", type: "uint256[2]" },
      { name: "c", type: "uint256" },
      { name: "s", type: "uint256" },
      { name: "seed", type: "uint256" },
      { name: "uWitness", type: "address" },
      { name: "cGammaWitness", type: "uint256[2]" },
      { name: "sHashWitness", type: "uint256[2]" },
      { name: "zInv", type: "uint256" },
    ],
  },
] as const;

function encodeProof(p: VrfProof): string {
  return encodeAbiParameters(PROOF_ABI, [
    {
      pk: [p.pk[0], p.pk[1]],
      gamma: [p.gamma[0], p.gamma[1]],
      c: p.c,
      s: p.s,
      seed: p.seed,
      uWitness: p.uWitness as `0x${string}`,
      cGammaWitness: [p.cGammaWitness[0], p.cGammaWitness[1]],
      sHashWitness: [p.sHashWitness[0], p.sHashWitness[1]],
      zInv: p.zInv,
    },
  ]);
}

const [mode, skArg, preSeedArg, blockHash] = process.argv.slice(2);
if (!mode || !skArg || !preSeedArg || !blockHash) {
  process.stderr.write("usage: prove-ffi.ts <prove|output> <sk> <preSeed> <blockHash> | register <sk> <chainId> <coordinator>\n");
  process.exit(2);
}
if (mode === "register") {
  process.stdout.write(encodeProof(proveKeyPossession(BigInt(skArg), BigInt(preSeedArg), blockHash).proof));
  process.exit(0);
}
const result = proveForRequest(BigInt(skArg), BigInt(preSeedArg), blockHash);
if (mode === "prove") {
  process.stdout.write(encodeProof(result.proof));
} else if (mode === "output") {
  process.stdout.write(encodeAbiParameters([{ type: "uint256" }], [result.output]));
} else {
  process.stderr.write(`unknown mode ${mode}\n`);
  process.exit(2);
}
