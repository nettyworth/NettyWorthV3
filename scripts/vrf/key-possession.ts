/**
 * Proof of possession for NettyVRFCoordinator.registerKey (audit F-04).
 *
 * registerKey(publicKey, proof) accepts a key only with a VRF proof by that key over
 *   registrationSeed = uint256(keccak256(abi.encode(
 *     keccak256("NettyVRFCoordinator.registerKey"), chainId, coordinator, pk[0], pk[1])))
 * so only the holder of the matching secret key can register it, and the proof cannot be
 * replayed on another chain, another coordinator or for another key.
 *
 * SECURITY: the secret key is an argument only; nothing here logs, prints or stores it.
 */
import { encodeAbiParameters, getAddress, keccak256, toHex } from "viem";
import { generateProof, keyHashFromPublicKey, publicKeyFromSecret, verifyProof, type VrfProof } from "./ecvrf.ts";

export const KEY_REGISTRATION_DOMAIN = keccak256(toHex("NettyVRFCoordinator.registerKey"));

export function registrationSeed(chainId: bigint, coordinator: string, pk: readonly [bigint, bigint]): bigint {
  return BigInt(
    keccak256(
      encodeAbiParameters(
        [{ type: "bytes32" }, { type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "uint256" }],
        [KEY_REGISTRATION_DOMAIN, chainId, getAddress(coordinator), pk[0], pk[1]],
      ),
    ),
  );
}

export interface KeyPossession {
  chainId: string;
  coordinator: string;
  publicKey: [string, string];
  keyHash: string;
  registrationSeed: string;
  proof: VrfProof;
}

/** Builds and self-verifies the registration proof. Public data only in the result. */
export function proveKeyPossession(sk: bigint, chainId: bigint, coordinator: string): KeyPossession {
  const pk = publicKeyFromSecret(sk);
  const seed = registrationSeed(chainId, coordinator, pk);
  const { proof } = generateProof(sk, seed); // proof.seed = seed, as registerKey requires
  verifyProof(proof, seed); // throws if the proof would not verify on-chain
  return {
    chainId: chainId.toString(),
    coordinator: getAddress(coordinator),
    publicKey: [pk[0].toString(), pk[1].toString()],
    keyHash: keyHashFromPublicKey(pk),
    registrationSeed: seed.toString(),
    proof,
  };
}

/** Re-checks a KeyPossession read from disk: seed binding, key match and proof validity. */
export function checkKeyPossession(kp: KeyPossession, chainId: bigint, coordinator: string): void {
  const pk: [bigint, bigint] = [BigInt(kp.publicKey[0]), BigInt(kp.publicKey[1])];
  const proof = kp.proof;
  if (BigInt(kp.chainId) !== chainId) throw new Error(`proof is for chain ${kp.chainId}, expected ${chainId}`);
  if (getAddress(kp.coordinator) !== getAddress(coordinator)) {
    throw new Error(`proof is for coordinator ${kp.coordinator}, expected ${getAddress(coordinator)}`);
  }
  if (proof.pk[0] !== pk[0] || proof.pk[1] !== pk[1]) throw new Error("proof.pk does not match publicKey");
  const seed = registrationSeed(chainId, coordinator, pk);
  if (proof.seed !== seed) throw new Error("proof.seed is not the registration seed");
  verifyProof(proof, seed);
  if (keyHashFromPublicKey(pk).toLowerCase() !== kp.keyHash.toLowerCase()) throw new Error("keyHash does not match publicKey");
}

/** JSON (de)serialisation with bigints as decimal strings. */
export function keyPossessionToJson(kp: KeyPossession): string {
  return JSON.stringify(kp, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n";
}

export function keyPossessionFromJson(text: string): KeyPossession {
  const raw = JSON.parse(text) as KeyPossession & { proof: Record<string, unknown> };
  const p = raw.proof as unknown as Record<string, string | string[]>;
  const pair = (v: string | string[]): [bigint, bigint] => {
    if (!Array.isArray(v) || v.length !== 2) throw new Error("malformed point in proof");
    return [BigInt(v[0]), BigInt(v[1])];
  };
  return {
    ...raw,
    proof: {
      pk: pair(p.pk),
      gamma: pair(p.gamma),
      c: BigInt(p.c as string),
      s: BigInt(p.s as string),
      seed: BigInt(p.seed as string),
      uWitness: getAddress(p.uWitness as string).toLowerCase(),
      cGammaWitness: pair(p.cGammaWitness),
      sHashWitness: pair(p.sHashWitness),
      zInv: BigInt(p.zInv as string),
    },
  };
}
