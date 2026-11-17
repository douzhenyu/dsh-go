// Portions derived from ds-harness-remote (https://github.com/liguobao/ds-harness-remote), MIT,
// Copyright (c) 2026 DSH Remote contributors. See THIRD_PARTY_NOTICES.md.
// ArkTS port of packages/dsh_remote/lib/src/crypto/noise_ik.dart, Noise revision 34.
import { RemoteKeyPair, dh, sha256, hkdf2, seal, open } from './RemoteCrypto';
import { bytes, utf8, equalBytes } from './RemoteBytes';

export const NOISE_IK_PROTOCOL: string = 'Noise_IK_25519_ChaChaPoly_SHA256';
const MAX_MESSAGE: number = 65535;
const TAG_BYTES: number = 16;
// JS numbers must never round a nonce. The reserved Noise nonce is far above this cap.
const MAX_NONCE: number = 9007199254740991;

function noiseFailure(failure: ESObject, fallback: string): Error {
  // Native crypto may throw a BusinessError; do not propagate its original diagnostic.
  const code: string = failure instanceof Error ? failure.message : '';
  if (code === 'INVALID_KEY' || code === 'NOISE_MESSAGE_INVALID' || code === 'NOISE_NONCE_EXHAUSTED' ||
    code === 'NOISE_DECRYPT_FAILED' || code === 'NOISE_DESTROYED') return new Error(code);
  return new Error(fallback);
}

class NoiseCipher {
  private key?: Uint8Array;
  counter: number = 0;

  constructor(key?: Uint8Array) { this.key = key; }
  initialize(key: Uint8Array): void {
    this.destroy(); this.key = key; this.counter = 0;
  }
  private assertNonce(): void {
    if (!Number.isSafeInteger(this.counter) || this.counter < 0 || this.counter >= MAX_NONCE) {
      throw new Error('NOISE_NONCE_EXHAUSTED');
    }
  }
  encrypt(aad: Uint8Array, plaintext: Uint8Array): Uint8Array {
    const key: Uint8Array | undefined = this.key;
    if (!key) return new Uint8Array(plaintext);
    this.assertNonce();
    const result: Uint8Array = seal(key, this.counter, aad, plaintext);
    this.counter++;
    return result;
  }
  decrypt(aad: Uint8Array, ciphertext: Uint8Array): Uint8Array {
    const key: Uint8Array | undefined = this.key;
    if (!key) return new Uint8Array(ciphertext);
    if (ciphertext.length < TAG_BYTES) throw new Error('NOISE_MESSAGE_INVALID');
    this.assertNonce();
    let result: Uint8Array;
    try { result = open(key, this.counter, aad, ciphertext); } catch (failure) {
      throw noiseFailure(failure, 'NOISE_DECRYPT_FAILED');
    }
    this.counter++;
    return result;
  }
  destroy(): void { this.key?.fill(0); this.key = undefined; this.counter = 0; }
}

class NoiseSplit {
  sending: NoiseCipher;
  receiving: NoiseCipher;
  constructor(first: Uint8Array, second: Uint8Array) {
    this.sending = new NoiseCipher(first); this.receiving = new NoiseCipher(second);
  }
}

class NoiseSymmetric {
  private chainingKey: Uint8Array;
  private hash: Uint8Array;
  private cipher: NoiseCipher = new NoiseCipher();

  constructor() {
    const name: Uint8Array = utf8(NOISE_IK_PROTOCOL);
    if (name.length <= 32) { this.hash = new Uint8Array(32); this.hash.set(name); }
    else this.hash = sha256(name);
    this.chainingKey = new Uint8Array(this.hash);
  }
  mixHash(value: Uint8Array): void {
    const previous: Uint8Array = this.hash;
    this.hash = sha256(bytes(previous, value)); previous.fill(0);
  }
  mixKey(value: Uint8Array): void {
    const keys: Uint8Array[] = hkdf2(this.chainingKey, value);
    this.chainingKey.fill(0); this.chainingKey = keys[0]; this.cipher.initialize(keys[1]);
  }
  encryptAndHash(plaintext: Uint8Array): Uint8Array {
    const result: Uint8Array = this.cipher.encrypt(this.hash, plaintext);
    this.mixHash(result); return result;
  }
  decryptAndHash(ciphertext: Uint8Array): Uint8Array {
    const result: Uint8Array = this.cipher.decrypt(this.hash, ciphertext);
    this.mixHash(ciphertext); return result;
  }
  split(): NoiseSplit {
    const keys: Uint8Array[] = hkdf2(this.chainingKey, new Uint8Array(0));
    return new NoiseSplit(keys[0], keys[1]);
  }
  destroy(): void { this.chainingKey.fill(0); this.hash.fill(0); this.cipher.destroy(); }
}

// Initiator-only IK: -> e, es, s, ss; <- e, ee, se.
// The pinned responder key is mixed into the pre-message and authenticated by DH.
export class NoiseInitiator {
  private staticKey?: RemoteKeyPair;
  private localPublic: Uint8Array;
  private remotePublic: Uint8Array;
  private ephemeral?: RemoteKeyPair;
  private symmetric: NoiseSymmetric = new NoiseSymmetric();
  private sendCipher?: NoiseCipher;
  private receiveCipher?: NoiseCipher;
  private messageIndex: number = 0;
  private destroyed: boolean = false;

  constructor(staticKey: RemoteKeyPair, remotePublicKey: Uint8Array, prologue: Uint8Array = new Uint8Array(0)) {
    this.staticKey = staticKey;
    this.localPublic = new Uint8Array(staticKey.publicKey);
    this.remotePublic = new Uint8Array(remotePublicKey);
    try {
      if (this.localPublic.length !== 32 || this.remotePublic.length !== 32) throw new Error('INVALID_KEY');
      // RemoteKeyPair.fromRaw may receive a separately encoded public key. Verify the pair.
      const basePoint: Uint8Array = new Uint8Array(32); basePoint[0] = 9;
      const derived: Uint8Array = dh(staticKey, basePoint);
      const matches: boolean = equalBytes(derived, this.localPublic); derived.fill(0);
      if (!matches) throw new Error('INVALID_KEY');
      this.symmetric.mixHash(prologue);
      this.symmetric.mixHash(this.remotePublic);
    } catch (failure) {
      this.destroy(); throw noiseFailure(failure, 'INVALID_KEY');
    }
  }

  get ready(): boolean { return !this.destroyed && this.sendCipher !== undefined; }
  get isDestroyed(): boolean { return this.destroyed; }
  get sendingCounter(): number { return this.sendCipher ? this.sendCipher.counter : 0; }
  get receivingCounter(): number { return this.receiveCipher ? this.receiveCipher.counter : 0; }

  private assertLive(): void { if (this.destroyed) throw new Error('NOISE_DESTROYED'); }
  private assertHandshake(index: number): void {
    this.assertLive();
    if (this.ready) throw new Error('NOISE_ALREADY_READY');
    if (this.messageIndex !== index) throw new Error('NOISE_HANDSHAKE_ORDER');
  }
  private mixDh(pair: RemoteKeyPair, publicKey: Uint8Array): void {
    let shared: Uint8Array;
    try { shared = dh(pair, publicKey); } catch (_) { throw new Error('INVALID_KEY'); }
    try {
      let nonzero: number = 0;
      for (const value of shared) nonzero |= value;
      if (shared.length !== 32 || !nonzero) throw new Error('INVALID_KEY');
      this.symmetric.mixKey(shared);
    } finally { shared.fill(0); }
  }

  writeMessage(payload: Uint8Array = new Uint8Array(0)): Uint8Array {
    this.assertHandshake(0);
    try {
      if (payload.length + 96 > MAX_MESSAGE) throw new Error('NOISE_MESSAGE_INVALID');
      const local: RemoteKeyPair | undefined = this.staticKey;
      if (!local) throw new Error('NOISE_DESTROYED');
      const ephemeral: RemoteKeyPair = RemoteKeyPair.generate(); this.ephemeral = ephemeral;
      this.symmetric.mixHash(ephemeral.publicKey);
      this.mixDh(ephemeral, this.remotePublic);
      const encryptedStatic: Uint8Array = this.symmetric.encryptAndHash(this.localPublic);
      this.mixDh(local, this.remotePublic);
      const encryptedPayload: Uint8Array = this.symmetric.encryptAndHash(payload);
      const result: Uint8Array = bytes(ephemeral.publicKey, encryptedStatic, encryptedPayload);
      this.messageIndex = 1;
      return result;
    } catch (failure) { this.destroy(); throw noiseFailure(failure, 'NOISE_CRYPTO_FAILED'); }
  }

  readMessage(frame: Uint8Array): Uint8Array {
    this.assertHandshake(1);
    try {
      if (frame.length < 48 || frame.length > MAX_MESSAGE) throw new Error('NOISE_MESSAGE_INVALID');
      const local: RemoteKeyPair | undefined = this.staticKey;
      const ephemeral: RemoteKeyPair | undefined = this.ephemeral;
      if (!local || !ephemeral) throw new Error('NOISE_DESTROYED');
      const remoteEphemeral: Uint8Array = frame.slice(0, 32);
      this.symmetric.mixHash(remoteEphemeral);
      this.mixDh(ephemeral, remoteEphemeral);
      this.mixDh(local, remoteEphemeral);
      const result: Uint8Array = this.symmetric.decryptAndHash(frame.slice(32));
      const split: NoiseSplit = this.symmetric.split();
      this.sendCipher = split.sending; this.receiveCipher = split.receiving; this.messageIndex = 2;
      // Only transport keys are needed after Split. Never destroy the borrowed static key.
      ephemeral.destroy(); this.ephemeral = undefined; this.symmetric.destroy();
      this.staticKey = undefined;
      return result;
    } catch (failure) { this.destroy(); throw noiseFailure(failure, 'NOISE_DECRYPT_FAILED'); }
  }

  encrypt(data: Uint8Array): Uint8Array {
    this.assertLive();
    const cipher: NoiseCipher | undefined = this.sendCipher;
    if (!cipher) throw new Error('NOISE_NOT_READY');
    if (data.length + TAG_BYTES > MAX_MESSAGE) throw new Error('NOISE_MESSAGE_INVALID');
    try { return cipher.encrypt(new Uint8Array(0), data); } catch (failure) {
      // Exhaustion or a platform crypto failure must never leave reusable nonce state.
      this.destroy(); throw noiseFailure(failure, 'NOISE_CRYPTO_FAILED');
    }
  }
  decrypt(data: Uint8Array): Uint8Array {
    this.assertLive();
    const cipher: NoiseCipher | undefined = this.receiveCipher;
    if (!cipher) throw new Error('NOISE_NOT_READY');
    try {
      if (data.length > MAX_MESSAGE) throw new Error('NOISE_MESSAGE_INVALID');
      return cipher.decrypt(new Uint8Array(0), data);
    } catch (failure) { this.destroy(); throw noiseFailure(failure, 'NOISE_DECRYPT_FAILED'); }
  }
  destroy(): void {
    if (this.destroyed) return;
    this.destroyed = true;
    this.staticKey = undefined; // Borrowed; caller owns identity lifetime.
    this.ephemeral?.destroy(); this.ephemeral = undefined;
    this.localPublic.fill(0); this.remotePublic.fill(0);
    this.symmetric.destroy(); this.sendCipher?.destroy(); this.receiveCipher?.destroy();
    this.sendCipher = undefined; this.receiveCipher = undefined;
  }
}
