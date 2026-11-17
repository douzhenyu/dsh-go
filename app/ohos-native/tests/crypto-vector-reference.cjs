// Public fixed test material only. Never use these keys/nonces in a real connection.
// Run: node app/ohos-native/tests/crypto-vector-reference.cjs
// Uses only Node/OpenSSL, independently of production ArkTS and upstream JS libraries.
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const hex = value => Buffer.from(value, 'hex');
const out = bytes => Buffer.from(bytes).toString('hex');
const PKCS8_PREFIX = hex('302e020100300506032b656e04220420');
const SPKI_PREFIX = hex('302a300506032b656e032100');
function privateKey(raw) {
  assert.equal(raw.length, 32);
  return crypto.createPrivateKey({ key: Buffer.concat([PKCS8_PREFIX, raw]), format: 'der', type: 'pkcs8' });
}
function publicKey(raw) {
  assert.equal(raw.length, 32);
  return crypto.createPublicKey({ key: Buffer.concat([SPKI_PREFIX, raw]), format: 'der', type: 'spki' });
}
function encrypt(key, nonce, aad, plaintext) {
  const cipher = crypto.createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 });
  cipher.setAAD(aad, { plaintextLength: plaintext.length });
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  return { ciphertext, tag, combined: Buffer.concat([ciphertext, tag]) };
}
function decrypt(key, nonce, aad, ciphertext, tag) {
  const cipher = crypto.createDecipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 });
  cipher.setAAD(aad, { plaintextLength: ciphertext.length });
  cipher.setAuthTag(tag);
  return Buffer.concat([cipher.update(ciphertext), cipher.final()]);
}
function aeadVector(label, key, nonce, aad, plaintext) {
  const value = encrypt(key, nonce, aad, plaintext);
  assert.deepEqual(decrypt(key, nonce, aad, value.ciphertext, value.tag), plaintext);
  const badTag = Buffer.from(value.tag); badTag[0] ^= 1;
  assert.throws(() => decrypt(key, nonce, aad, value.ciphertext, badTag));
  return { label, keyHex: out(key), nonceHex: out(nonce), aadHex: out(aad), plaintextHex: out(plaintext),
    ciphertextHex: out(value.ciphertext), authTagHex: out(value.tag), ciphertextAndTagHex: out(value.combined), tamperedTagMustReject: true };
}
function noiseNonce(counter) {
  const bytes = Buffer.alloc(12);
  bytes.writeBigUInt64LE(counter, 4);
  return bytes;
}
function reference() {
  // RFC 7748 section 6.1: public X25519 test keys and agreement result.
  const alice = hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
  const bobPublic = hex('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
  const aliceKey = privateKey(alice);
  const aliceSpki = crypto.createPublicKey(aliceKey).export({ format: 'der', type: 'spki' });
  const alicePublic = aliceSpki.subarray(-32);
  assert.equal(out(alicePublic), '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');
  const secret = crypto.diffieHellman({ privateKey: aliceKey, publicKey: publicKey(bobPublic) });
  assert.equal(out(secret), '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');

  // RFC 8439 section 2.8.2: IETF 96-bit nonce, non-empty AAD, 128-bit tag.
  const rfc = aeadVector('RFC 8439 2.8.2', hex('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f'),
    hex('070000004041424344454647'), hex('50515253c0c1c2c3c4c5c6c7'),
    Buffer.from("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."));
  assert.equal(rfc.authTagHex, '1ae10b594f09e26a7e902ecbd0600691');
  assert.equal(rfc.ciphertextHex, 'd31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116');
  const key = Buffer.from(Array.from({ length: 32 }, (_, i) => i));
  const ikm = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 32));
  const hmac = (k, data) => crypto.createHmac('sha256', k).update(data).digest();
  const temp = hmac(key, ikm), first = hmac(temp, Buffer.from([1]));
  const second = hmac(temp, Buffer.concat([first, Buffer.from([2])]));
  return {
    warning: 'PUBLIC FIXED TEST KEYS ONLY; never use in production',
    sources: ['https://www.rfc-editor.org/rfc/rfc7748#section-6.1', 'https://www.rfc-editor.org/rfc/rfc8439#section-2.8.2', 'https://noiseprotocol.org/noise.html#the-hkdf-function'],
    x25519: { privateRawHex: out(alice), privatePkcs8DerHex: out(Buffer.concat([PKCS8_PREFIX, alice])),
      publicRawHex: out(alicePublic), publicX509SpkiDerHex: out(aliceSpki), peerPublicRawHex: out(bobPublic),
      peerPublicX509SpkiDerHex: out(Buffer.concat([SPKI_PREFIX, bobPublic])), sharedSecretHex: out(secret) },
    chacha20Poly1305: [rfc, ...[0n, 1n, 0x100000001n].map(counter => aeadVector(
      'Noise nonce ' + counter, key, noiseNonce(counter), Buffer.alloc(0), Buffer.from('DSH Remote fixed probe'))),
      aeadVector('Noise empty payload + handshake hash AAD', key, noiseNonce(0n), crypto.createHash('sha256').update('fixed transcript').digest(), Buffer.alloc(0))],
    noiseHkdf2: { chainingKeyHex: out(key), inputKeyMaterialHex: out(ikm), temporaryKeyHex: out(temp), output1Hex: out(first), output2Hex: out(second) }
  };
}
if (require.main === module) console.log(JSON.stringify(reference(), null, 2));
module.exports = { reference, noiseNonce };
