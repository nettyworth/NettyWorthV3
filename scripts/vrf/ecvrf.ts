/**
 * ECVRF prover compatible with Chainlink's on-chain verifier
 * (`@chainlink/contracts` src/v0.8/vrf/VRF.sol, MIT), used by NettyVRFCoordinator.
 *
 * This is a TypeScript port of Chainlink's Go reference implementation (MIT):
 *   - chainlink-common keystore/corekeys/vrfkey: KeyV2.GenerateProofWithNonce, HashToCurve,
 *     ScalarFromCurvePoints, ProjectiveECAdd
 *   - chainlink core/services/vrf/proof/solidity_proof.go: SolidityPrecalculations and
 *     MarshalForSolidityVerifier
 * KEEP IN SYNC with nettyworth-api app/v2/lib/vrf/ecvrf.ts, which is the production copy
 * (the fulfiller) and carries the byte-for-byte differential tests against 1,000 vectors from
 * Chainlink's Go reference. This copy differs only in its keccak import (viem instead of
 * ethers) and exists so the fork tests here exercise the same prover against the deployed
 * contracts via FFI (scripts/vrf/prove-ffi.ts).
 *
 * VRF.sol is not the IETF ECVRF standard: it hashes with keccak256, uses a try-and-increment
 * hash-to-curve, and needs witnesses (uWitness, cGammaWitness, sHashWitness, zInv) so the
 * verifier can use ecrecover instead of EC multiplication. Generic ECVRF libraries do not
 * produce proofs it accepts.
 *
 * SECURITY: the secret key and the proof nonce must never be logged. A predictable or
 * reused nonce across different seeds leaks the secret key, so nonces are hedged: derived
 * from the secret key, the seed and fresh randomness (see deriveNonce).
 */
import { createHmac, randomBytes } from "crypto";
import { secp256k1 } from "@noble/curves/secp256k1";
import { keccak256 } from "viem";

type Point = InstanceType<typeof secp256k1.ProjectivePoint>;
const ProjectivePoint = secp256k1.ProjectivePoint;

/** secp256k1 base field size (VRF.sol FIELD_SIZE). */
export const FIELD_SIZE = BigInt("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F");
/** secp256k1 group order (VRF.sol GROUP_ORDER). */
export const GROUP_ORDER = BigInt("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");
const TWO_256 = BigInt(1) << BigInt(256);
const EULER_POWER = (FIELD_SIZE - BigInt(1)) / BigInt(2);
const SQRT_POWER = (FIELD_SIZE + BigInt(1)) / BigInt(4);

// Domain-separation prefixes, each a big-endian uint256 (VRF.sol *_HASH_PREFIX).
const HASH_TO_CURVE_HASH_PREFIX = BigInt(1);
const SCALAR_FROM_CURVE_POINTS_HASH_PREFIX = BigInt(2);
const VRF_RANDOM_OUTPUT_HASH_PREFIX = BigInt(3);

/** Length of MarshalForSolidityVerifier output. */
export const PROOF_LENGTH = 416;

export type AffinePoint = readonly [bigint, bigint];

/**
 * Field-for-field mirror of VRF.sol `struct Proof`. `seed` is the value the verifier
 * receives in the struct; for NettyVRFCoordinator that is the request's preSeed, while the
 * proof itself is computed over the block-hash-bound actual seed (see proveForRequest).
 */
export interface VrfProof {
  pk: AffinePoint;
  gamma: AffinePoint;
  c: bigint;
  s: bigint;
  seed: bigint;
  uWitness: string; // 0x-prefixed, 20-byte lowercase hex address
  cGammaWitness: AffinePoint;
  sHashWitness: AffinePoint;
  zInv: bigint;
}

export class VrfError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "VrfError";
  }
}

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

function mod(a: bigint, m: bigint): bigint {
  const r = a % m;
  return r >= BigInt(0) ? r : r + m;
}

function modPow(base: bigint, exponent: bigint, m: bigint): bigint {
  let result = BigInt(1);
  let b = mod(base, m);
  let e = exponent;
  while (e > BigInt(0)) {
    if (e & BigInt(1)) result = (result * b) % m;
    b = (b * b) % m;
    e >>= BigInt(1);
  }
  return result;
}

function modInverse(a: bigint, m: bigint): bigint {
  // Extended Euclid; a must be non-zero mod m (m prime).
  let [oldR, r] = [mod(a, m), m];
  let [oldS, s] = [BigInt(1), BigInt(0)];
  if (oldR === BigInt(0)) throw new VrfError("no inverse of zero");
  while (r !== BigInt(0)) {
    const q = oldR / r;
    [oldR, r] = [r, oldR - q * r];
    [oldS, s] = [s, oldS - q * s];
  }
  return mod(oldS, m);
}

/** Big-endian 32-byte encoding of a uint256. */
export function uint256ToBytes(n: bigint): Uint8Array {
  if (n < BigInt(0) || n >= TWO_256) throw new VrfError("value does not fit in uint256");
  const out = new Uint8Array(32);
  let v = n;
  for (let i = 31; i >= 0; i--) {
    out[i] = Number(v & BigInt(0xff));
    v >>= BigInt(8);
  }
  return out;
}

export function bytesToBigInt(b: Uint8Array): bigint {
  let v = BigInt(0);
  for (const byte of b) v = (v << BigInt(8)) | BigInt(byte);
  return v;
}

function concat(parts: Uint8Array[]): Uint8Array {
  const len = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(len);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

function keccak(bytes: Uint8Array): bigint {
  return BigInt(keccak256(bytes));
}

function hexToBytes(hex: string): Uint8Array {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (h.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(h)) throw new VrfError("invalid hex");
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function toHex(bytes: Uint8Array): string {
  return "0x" + Buffer.from(bytes).toString("hex");
}

function affine(p: Point): AffinePoint {
  const a = p.toAffine();
  return [a.x, a.y];
}

function pointFrom(a: AffinePoint): Point {
  const p = ProjectivePoint.fromAffine({ x: a[0], y: a[1] });
  p.assertValidity();
  return p;
}

/** secp256k1.LongMarshal: x ‖ y, each 32 bytes big-endian. */
function longMarshal(p: AffinePoint): Uint8Array {
  return concat([uint256ToBytes(p[0]), uint256ToBytes(p[1])]);
}

/** Bottom 160 bits of keccak256(x ‖ y), i.e. the Ethereum address of the point. */
function ethereumAddress(p: AffinePoint): string {
  const h = keccak256(longMarshal(p));
  return "0x" + h.slice(-40);
}

/** k·P with k reduced mod the group order, as kyber's IntToScalar does. */
function mul(p: Point, k: bigint): Point {
  const scalar = mod(k, GROUP_ORDER);
  if (scalar === BigInt(0)) throw new VrfError("zero scalar");
  return p.multiply(scalar);
}

// ---------------------------------------------------------------------------
// VRF.sol primitives
// ---------------------------------------------------------------------------

function ySquared(x: bigint): bigint {
  return mod(modPow(x, BigInt(3), FIELD_SIZE) + BigInt(7), FIELD_SIZE);
}

function isSquare(x: bigint): boolean {
  return modPow(x, EULER_POWER, FIELD_SIZE) === BigInt(1);
}

/** VRF.sol _fieldHash: keccak, rehashing until the value is below FIELD_SIZE. */
function fieldHash(b: Uint8Array): bigint {
  let x = keccak(b);
  while (x >= FIELD_SIZE) x = keccak(uint256ToBytes(x));
  return x;
}

/** VRF.sol _hashToCurve (try-and-increment, even y). */
export function hashToCurve(pk: AffinePoint, input: bigint): AffinePoint {
  if (input < BigInt(0) || input >= TWO_256) throw new VrfError("seed out of range");
  let x = fieldHash(concat([uint256ToBytes(HASH_TO_CURVE_HASH_PREFIX), longMarshal(pk), uint256ToBytes(input)]));
  while (!isSquare(ySquared(x))) x = fieldHash(uint256ToBytes(x));
  let y = modPow(ySquared(x), SQRT_POWER, FIELD_SIZE);
  if (y % BigInt(2) === BigInt(1)) y = FIELD_SIZE - y;
  return [x, y];
}

/** VRF.sol _scalarFromCurvePoints. Not reduced mod the group order, exactly as on-chain. */
function scalarFromCurvePoints(
  hash: AffinePoint,
  pk: AffinePoint,
  gamma: AffinePoint,
  uWitness: string,
  v: AffinePoint,
): bigint {
  return keccak(
    concat([
      uint256ToBytes(SCALAR_FROM_CURVE_POINTS_HASH_PREFIX),
      longMarshal(hash),
      longMarshal(pk),
      longMarshal(gamma),
      longMarshal(v),
      hexToBytes(uWitness),
    ]),
  );
}

/**
 * The z ordinate VRF.sol _projectiveECAdd produces for p + q. The verifier requires zInv to
 * be the inverse of exactly this z (not of any valid projective representation). Only the
 * denominators contribute to z; following the Solidity step by step:
 *   dx = lz·lz (projectiveMul), then ×1 twice (projectiveSub with z = 1)
 *   dy = dx (projectiveSub(px, 1, sx, dx)), ×lz (projectiveMul), ×1 (projectiveSub)
 *   z  = dx·dy, or dx when dx == dy (the Solidity short-cut, kept for exactness)
 */
function projectiveECAddZ(p: AffinePoint, q: AffinePoint): bigint {
  const lz = mod(q[0] + (FIELD_SIZE - p[0]), FIELD_SIZE);
  const dx = mod(lz * lz, FIELD_SIZE);
  const dy = mod(dx * lz, FIELD_SIZE);
  return dx !== dy ? mod(dx * dy, FIELD_SIZE) : dx;
}

/** Final VRF output: keccak256(abi.encode(3, gamma)). */
export function outputFromGamma(gamma: AffinePoint): bigint {
  return keccak(concat([uint256ToBytes(VRF_RANDOM_OUTPUT_HASH_PREFIX), longMarshal(gamma)]));
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

export function assertValidSecretKey(sk: bigint): void {
  if (sk <= BigInt(0) || sk >= GROUP_ORDER) throw new VrfError("secret key out of range");
}

export function parseSecretKey(hex: string): bigint {
  const trimmed = hex.trim();
  if (!/^(0x)?[0-9a-fA-F]{64}$/.test(trimmed)) throw new VrfError("VRF secret key must be 32 bytes of hex");
  const sk = BigInt(trimmed.startsWith("0x") ? trimmed : "0x" + trimmed);
  assertValidSecretKey(sk);
  return sk;
}

export function publicKeyFromSecret(sk: bigint): AffinePoint {
  assertValidSecretKey(sk);
  return affine(ProjectivePoint.BASE.multiply(sk));
}

/** keccak256(abi.encode(uint256[2] pk)), the key hash the coordinator records per request. */
export function keyHashFromPublicKey(pk: AffinePoint): string {
  return keccak256(longMarshal(pk));
}

/**
 * Hedged nonce: HMAC-SHA256 keyed by the secret key over the seed, fresh randomness and a
 * counter, rejection-sampled into [1, n-1]. Safe even if the RNG is weak (falls back to a
 * deterministic per-seed nonce) and never repeats across different seeds.
 */
function deriveNonce(sk: bigint, seed: bigint): bigint {
  const extra = randomBytes(32);
  for (let counter = 0; counter < 256; counter++) {
    const k = bytesToBigInt(
      createHmac("sha256", uint256ToBytes(sk))
        .update(uint256ToBytes(seed))
        .update(extra)
        .update(Uint8Array.of(counter))
        .digest(),
    );
    if (k > BigInt(0) && k < GROUP_ORDER) return k;
  }
  throw new VrfError("nonce derivation failed");
}

// ---------------------------------------------------------------------------
// Proving
// ---------------------------------------------------------------------------

export interface ProofResult {
  proof: VrfProof;
  /** The VRF output (VRF.sol _randomValueFromVRFProof return value). */
  output: bigint;
}

/**
 * Port of KeyV2.GenerateProofWithNonce followed by SolidityPrecalculations.
 * `nonce` is exposed for differential testing only; production callers omit it.
 */
export function generateProof(sk: bigint, seed: bigint, nonce?: bigint): ProofResult {
  assertValidSecretKey(sk);
  if (seed < BigInt(0) || seed >= TWO_256) throw new VrfError("seed out of range");
  const m = nonce ?? deriveNonce(sk, seed);
  if (m <= BigInt(0) || m >= GROUP_ORDER) throw new VrfError("nonce out of range");

  const pkPoint = ProjectivePoint.BASE.multiply(sk);
  const pk = affine(pkPoint);
  const h = hashToCurve(pk, seed);
  const hPoint = pointFrom(h);
  const gammaPoint = hPoint.multiply(sk);
  const gamma = affine(gammaPoint);
  const uWitness = ethereumAddress(affine(ProjectivePoint.BASE.multiply(m)));
  const v = affine(hPoint.multiply(m));
  const c = scalarFromCurvePoints(h, pk, gamma, uWitness, v);
  const s = mod(m - c * sk, GROUP_ORDER);

  // SolidityPrecalculations. uWitness recomputed as address(c·pk + s·G) equals address(m·G).
  const cGamma = mul(gammaPoint, c);
  const sHash = mul(hPoint, s);
  if (cGamma.equals(sHash)) {
    // Cryptographically impossible; the verifier rejects it, so retry with a fresh nonce.
    if (nonce !== undefined) throw new VrfError("c*gamma equals s*hash for this nonce");
    return generateProof(sk, seed);
  }
  const cGammaWitness = affine(cGamma);
  const sHashWitness = affine(sHash);
  const z = projectiveECAddZ(cGammaWitness, sHashWitness);
  const zInv = modInverse(z, FIELD_SIZE);

  return {
    proof: { pk, gamma, c, s, seed, uWitness, cGammaWitness, sHashWitness, zInv },
    output: outputFromGamma(gamma),
  };
}

/**
 * Independent re-verification mirroring VRF.sol _verifyVRFProof, computed with full EC
 * arithmetic. Returns the output or throws. Used as a pre-submission self-check.
 */
export function verifyProof(proof: VrfProof, seed: bigint): bigint {
  const pk = pointFrom(proof.pk);
  const gamma = pointFrom(proof.gamma);
  const cGammaWitness = pointFrom(proof.cGammaWitness);
  const sHashWitness = pointFrom(proof.sHashWitness);
  if (mod(proof.c, GROUP_ORDER) === BigInt(0) || mod(proof.s, GROUP_ORDER) === BigInt(0)) {
    throw new VrfError("zero scalar");
  }
  const u = ethereumAddress(affine(mul(pk, proof.c).add(mul(ProjectivePoint.BASE, proof.s))));
  if (u !== proof.uWitness.toLowerCase()) throw new VrfError("addr(c*pk+s*g)!=_uWitness");
  const h = hashToCurve(proof.pk, seed);
  const hPoint = pointFrom(h);
  if (!mul(gamma, proof.c).equals(cGammaWitness)) throw new VrfError("First mul check failed");
  if (!mul(hPoint, proof.s).equals(sHashWitness)) throw new VrfError("Second mul check failed");
  if (proof.cGammaWitness[0] === proof.sHashWitness[0]) throw new VrfError("points in sum must be distinct");
  const z = projectiveECAddZ(proof.cGammaWitness, proof.sHashWitness);
  if (mod(z * proof.zInv, FIELD_SIZE) !== BigInt(1)) throw new VrfError("invZ must be inverse of z");
  const v = affine(cGammaWitness.add(sHashWitness));
  if (scalarFromCurvePoints(h, proof.pk, proof.gamma, proof.uWitness, v) !== proof.c) {
    throw new VrfError("invalid proof");
  }
  return outputFromGamma(proof.gamma);
}

/** MarshalForSolidityVerifier: the 416-byte concatenation of the Proof struct fields. */
export function marshalProof(p: VrfProof): Uint8Array {
  const out = concat([
    longMarshal(p.pk),
    longMarshal(p.gamma),
    uint256ToBytes(p.c),
    uint256ToBytes(p.s),
    uint256ToBytes(p.seed),
    new Uint8Array(12),
    hexToBytes(p.uWitness),
    longMarshal(p.cGammaWitness),
    longMarshal(p.sHashWitness),
    uint256ToBytes(p.zInv),
  ]);
  if (out.length !== PROOF_LENGTH) throw new VrfError(`wrong proof length ${out.length}`);
  return out;
}

export function marshalProofHex(p: VrfProof): string {
  return toHex(marshalProof(p));
}

// ---------------------------------------------------------------------------
// NettyVRFCoordinator request binding (mirrors the Chainlink V2.5 coordinator)
// ---------------------------------------------------------------------------

/** actualSeed = uint256(keccak256(abi.encodePacked(preSeed, blockhash(requestBlock)))). */
export function actualSeedFor(preSeed: bigint, blockHash: string): bigint {
  const bh = hexToBytes(blockHash);
  if (bh.length !== 32) throw new VrfError("block hash must be 32 bytes");
  return keccak(concat([uint256ToBytes(preSeed), bh]));
}

/**
 * Proof for a coordinator request. The proof is over the actual seed; the struct's `seed`
 * field carries the preSeed, which the coordinator checks against its stored request.
 */
export function proveForRequest(sk: bigint, preSeed: bigint, blockHash: string): ProofResult {
  const actualSeed = actualSeedFor(preSeed, blockHash);
  const { proof, output } = generateProof(sk, actualSeed);
  return { proof: { ...proof, seed: preSeed }, output };
}

/** words[i] = uint256(keccak256(abi.encode(randomness, i))), as the coordinator derives them. */
export function randomWordsFromOutput(output: bigint, numWords: number): bigint[] {
  const words: bigint[] = [];
  for (let i = 0; i < numWords; i++) {
    words.push(keccak(concat([uint256ToBytes(output), uint256ToBytes(BigInt(i))])));
  }
  return words;
}

/** Shape expected by ethers when passing the Proof struct as a contract argument. */
export function proofToAbiStruct(p: VrfProof): {
  pk: [bigint, bigint];
  gamma: [bigint, bigint];
  c: bigint;
  s: bigint;
  seed: bigint;
  uWitness: string;
  cGammaWitness: [bigint, bigint];
  sHashWitness: [bigint, bigint];
  zInv: bigint;
} {
  return {
    pk: [p.pk[0], p.pk[1]],
    gamma: [p.gamma[0], p.gamma[1]],
    c: p.c,
    s: p.s,
    seed: p.seed,
    uWitness: p.uWitness,
    cGammaWitness: [p.cGammaWitness[0], p.cGammaWitness[1]],
    sHashWitness: [p.sHashWitness[0], p.sHashWitness[1]],
    zInv: p.zInv,
  };
}
