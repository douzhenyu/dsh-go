import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { bytes, fromHex, equalBytes, toHex, utf8, unbase64url } from './RemoteBytes';

const X25519_SPKI: Uint8Array = fromHex('302a300506032b656e032100');
const X25519_PKCS8: Uint8Array = fromHex('302e020100300506032b656e04220420');

export class RemoteKeyPair {
  publicKey: Uint8Array;
  nativeKey: cryptoFramework.KeyPair;
  constructor(nativeKey: cryptoFramework.KeyPair, rawPublic: Uint8Array) {
    this.nativeKey = nativeKey; this.publicKey = new Uint8Array(rawPublic);
  }
  static generate(): RemoteKeyPair {
    const pair = cryptoFramework.createAsyKeyGenerator('X25519').generateKeyPairSync();
    const encoded = pair.pubKey.getEncoded().data;
    if (encoded.length === 32) return new RemoteKeyPair(pair, encoded);
    if (encoded.length !== 44 || !equalBytes(encoded.slice(0, 12), X25519_SPKI)) {
      pair.priKey.clearMem(); throw new Error('UNSUPPORTED_KEY_ENCODING');
    }
    return new RemoteKeyPair(pair, encoded.slice(12));
  }
  static fromRaw(privateKey: Uint8Array, publicKey: Uint8Array): RemoteKeyPair {
    if (privateKey.length !== 32 || publicKey.length !== 32) throw new Error('INVALID_KEY');
    const encodedPrivate = bytes(X25519_PKCS8, privateKey);
    try {
      const pair = cryptoFramework.createAsyKeyGenerator('X25519').convertKeySync(
        { data: bytes(X25519_SPKI, publicKey) }, { data: encodedPrivate });
      return new RemoteKeyPair(pair, publicKey);
    } finally { encodedPrivate.fill(0); }
  }
  destroy(): void { this.nativeKey.priKey.clearMem(); this.publicKey.fill(0); }
}
export function dh(pair: RemoteKeyPair, publicKey: Uint8Array): Uint8Array {
  if (publicKey.length !== 32) throw new Error('INVALID_KEY');
  const peer = cryptoFramework.createAsyKeyGenerator('X25519').convertKeySync({ data: bytes(X25519_SPKI, publicKey) }, null);
  const secret = cryptoFramework.createKeyAgreement('X25519').generateSecretSync(pair.nativeKey.priKey, peer.pubKey).data;
  let nonzero = 0;
  for (const value of secret) nonzero |= value;
  if (!nonzero || secret.length !== 32) { secret.fill(0); throw new Error('INVALID_KEY'); }
  return secret;
}
export function sha256(value: Uint8Array): Uint8Array {
  const digest = cryptoFramework.createMd('SHA256'); if (value.length) digest.updateSync({ data: value }); return digest.digestSync().data;
}
export function hmac(key: Uint8Array, value: Uint8Array): Uint8Array {
  const secret = cryptoFramework.createSymKeyGenerator('HMAC|SHA256').convertKeySync({ data: key });
  try {
    const mac = cryptoFramework.createMac('SHA256'); mac.initSync(secret); if (value.length) mac.updateSync({ data: value });
    return mac.doFinalSync().data;
  } finally { secret.clearMem(); }
}
export function hkdf2(chainingKey: Uint8Array, input: Uint8Array): Uint8Array[] {
  const temporary = hmac(chainingKey, input);
  try {
    const first = hmac(temporary, new Uint8Array([1]));
    return [first, hmac(temporary, bytes(first, new Uint8Array([2])))];
  } finally { temporary.fill(0); }
}
export function noiseNonce(counter: number): Uint8Array {
  if (!Number.isSafeInteger(counter) || counter < 0) throw new Error('NOISE_NONCE_EXHAUSTED');
  const result = new Uint8Array(12);
  const low = counter % 4294967296; const high = Math.floor(counter / 4294967296);
  for (let index = 0; index < 4; index++) {
    result[4 + index] = (low >>> (index * 8)) & 255;
    result[8 + index] = (high >>> (index * 8)) & 255;
  }
  return result;
}
export function seal(key: Uint8Array, counter: number, aad: Uint8Array, plaintext: Uint8Array): Uint8Array {
  if (key.length !== 32 || plaintext.length + 16 > 65535) throw new Error('NOISE_MESSAGE_INVALID');
  const secret = cryptoFramework.createSymKeyGenerator('ChaCha20').convertKeySync({ data: key });
  try {
    const cipher = cryptoFramework.createCipher('ChaCha20|Poly1305');
    const params: cryptoFramework.Poly1305ParamsSpec = { algName: 'Poly1305ParamsSpec',
      iv: { data: noiseNonce(counter) }, aad: { data: aad }, authTag: { data: new Uint8Array(16) } };
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, secret, params);
    // Even an empty update feeds AAD into the legacy Poly1305 context before finalization.
    const updated = cipher.updateSync({ data: plaintext });
    const encrypted = updated ? updated.data : new Uint8Array(0);
    const final = cipher.doFinalSync(null);
    return bytes(encrypted, final ? final.data : new Uint8Array(0));
  } finally { secret.clearMem(); }
}
export function open(key: Uint8Array, counter: number, aad: Uint8Array, ciphertext: Uint8Array): Uint8Array {
  if (key.length !== 32 || ciphertext.length < 16 || ciphertext.length > 65535) throw new Error('NOISE_MESSAGE_INVALID');
  const secret = cryptoFramework.createSymKeyGenerator('ChaCha20').convertKeySync({ data: key });
  let unverified = new Uint8Array(0);
  try {
    const cipher = cryptoFramework.createCipher('ChaCha20|Poly1305');
    const params: cryptoFramework.Poly1305ParamsSpec = { algName: 'Poly1305ParamsSpec',
      iv: { data: noiseNonce(counter) }, aad: { data: aad }, authTag: { data: ciphertext.slice(-16) } };
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, secret, params);
    const payload = ciphertext.slice(0, -16);
    const updated = cipher.updateSync({ data: payload });
    if (updated) unverified = updated.data;
    const final = cipher.doFinalSync(null); // Authentication must finish before any plaintext leaves this function.
    return bytes(unverified, final ? final.data : new Uint8Array(0));
  } catch (_) { unverified.fill(0); throw new Error('NOISE_DECRYPT_FAILED'); }
  finally { secret.clearMem(); }
}
export function fingerprint(publicKey: string): string {
  const raw = unbase64url(publicKey);
  if (raw.length !== 32) throw new Error('INVALID_KEY');
  return toHex(sha256(raw).slice(0, 6)).toUpperCase();
}

// Fixed public vectors test platform primitives; no device identity or account secret is inspected.
export function checkRemoteCrypto(): void {
  const alice = RemoteKeyPair.fromRaw(
    fromHex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a'),
    fromHex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a'));
  try {
    const shared = dh(alice, fromHex('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f'));
    if (toHex(shared) !== '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742') throw new Error('CRYPTO_VECTOR_MISMATCH');
    shared.fill(0);
    const key = fromHex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
    const plain = utf8('DSH Remote fixed probe'); const aad = new Uint8Array(0);
    const encrypted = seal(key, 0, aad, plain);
    if (toHex(encrypted) !== '5ceb0a11ff83cbbe67047c07c63b2b43d8c1819a83c86fd6be1fe7983c8de55555bc937fcf5e' ||
      !equalBytes(open(key, 0, aad, encrypted), plain)) throw new Error('CRYPTO_VECTOR_MISMATCH');
    encrypted[encrypted.length - 1] ^= 1;
    let rejected = false;
    try { open(key, 0, aad, encrypted); } catch (_) { rejected = true; }
    key.fill(0);
    if (!rejected) throw new Error('CRYPTO_AUTHENTICATION_MISSING');
  } finally { alice.destroy(); }

  // Independently computed by tests/crypto-vector-reference.cjs (Node/OpenSSL).
  const chainingKey = fromHex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
  const input = fromHex('202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f');
  let mac = new Uint8Array(0);
  let derived: Uint8Array[] = [];
  try {
    try {
      mac = hmac(chainingKey, input);
      if (toHex(mac) !== '62215de7bddcea7e2c4047ff6bb94f8d18262fc8b3f3648134bb7d44158ff84d') throw new Error('MISMATCH');
    } catch (_) { throw new Error('CRYPTO_HMAC_MISMATCH'); }
    try {
      derived = hkdf2(chainingKey, input);
      if (derived.length !== 2 ||
        toHex(derived[0]) !== '2607f5d05b268e0057684567787ed2f250fdb6e5b0572df9ef57a29539e5b5f8' ||
        toHex(derived[1]) !== 'ccc538566c93ab32f7106fbee1e0e9fa5501f6363b63ce894b3a27385f13c86c') throw new Error('MISMATCH');
    } catch (_) { throw new Error('CRYPTO_HKDF_MISMATCH'); }
  } finally {
    mac.fill(0); for (const value of derived) value.fill(0); chainingKey.fill(0); input.fill(0);
  }

  const emptyKey = fromHex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
  let hashAad = new Uint8Array(0);
  let emptyCiphertext = new Uint8Array(0);
  try {
    try {
      hashAad = sha256(utf8('fixed transcript'));
      if (toHex(hashAad) !== 'fec962d2b3bff61eaf19b0736c2f15b19183faebb0c05f40d57e70101d10c0ee') throw new Error('MISMATCH');
    } catch (_) { throw new Error('CRYPTO_SHA256_MISMATCH'); }
    try {
      emptyCiphertext = seal(emptyKey, 0, hashAad, new Uint8Array(0));
      if (toHex(emptyCiphertext) !== 'd5573ed4c4753bbf14bfdabf2768b87c' ||
        open(emptyKey, 0, hashAad, emptyCiphertext).length !== 0) throw new Error('MISMATCH');
    } catch (_) { throw new Error('CRYPTO_EMPTY_AEAD_MISMATCH'); }
    emptyCiphertext[emptyCiphertext.length - 1] ^= 1;
    let rejected = false;
    try { open(emptyKey, 0, hashAad, emptyCiphertext); } catch (_) { rejected = true; }
    if (!rejected) throw new Error('CRYPTO_EMPTY_AUTHENTICATION_MISSING');
  } finally { emptyKey.fill(0); hashAad.fill(0); emptyCiphertext.fill(0); }

  let generatedA: RemoteKeyPair | undefined = undefined;
  let generatedB: RemoteKeyPair | undefined = undefined;
  let secretA = new Uint8Array(0);
  let secretB = new Uint8Array(0);
  try {
    try { generatedA = RemoteKeyPair.generate(); generatedB = RemoteKeyPair.generate(); }
    catch (_) { throw new Error('CRYPTO_GENERATED_KEY_FAILED'); }
    try {
      secretA = dh(generatedA, generatedB.publicKey);
      secretB = dh(generatedB, generatedA.publicKey);
      if (secretA.length !== 32 || secretB.length !== 32 || !equalBytes(secretA, secretB)) throw new Error('MISMATCH');
    } catch (_) { throw new Error('CRYPTO_GENERATED_DH_MISMATCH'); }
  } finally {
    secretA.fill(0); secretB.fill(0);
    try { generatedB?.destroy(); } finally { generatedA?.destroy(); }
  }
}
