// Executes unchanged RemoteCrypto.ets seal/open AND RemoteBytes.ets through the SDK seam.
// The only crypto implementation here is Node/OpenSSL, not a copy of production adapters.
// Platform model: legacy Poly1305ParamsSpec submits AAD on update, not init/final;
// zero-length update is valid and returns JS null. Evidence pinned at:
// https://github.com/openharmony/security_crypto_framework/blob/fa3c4bdfbb274875e31cb97114922b94714a21fb/plugin/openssl_plugin/crypto_operation/cipher/src/cipher_chacha20_openssl.c#L332
// https://github.com/openharmony/security_crypto_framework/blob/fa3c4bdfbb274875e31cb97114922b94714a21fb/frameworks/js/napi/crypto/src/napi_utils.cpp#L202
// This is a regression contract for the observed adaptation bug, not a phone/SDK emulator.
// All keys and plaintexts are public fixed test material; no account credentials are read.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createLoader } = require('./ets-loader.cjs');
const { reference } = require('./crypto-vector-reference.cjs');
const vectors = reference();
const empty = vectors.chacha20Poly1305.find(v => v.label === 'Noise empty payload + handshake hash AAD');
const bytes = value => new Uint8Array(Buffer.from(value, 'hex'));
const hex = value => Buffer.from(value).toString('hex');

// Independent expected ciphertext: always explicitly submits AAD, including for
// empty messages. Does not import RemoteCrypto.noiseNonce or call the SDK model.
function independentVector(key, counter, aad, plaintext) {
  const nonce = Buffer.alloc(12); nonce.writeBigUInt64LE(BigInt(counter), 4);
  const cipher = crypto.createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 });
  cipher.setAAD(aad, { plaintextLength: plaintext.length });
  return { keyHex: hex(key), nonceHex: hex(nonce), aadHex: hex(aad), plaintextHex: hex(plaintext),
    ciphertextAndTagHex: hex(Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()])) };
}

function sdkHarness() {
  const keys = [], ciphers = [];
  const kit = {
    CryptoMode: { ENCRYPT_MODE: 0, DECRYPT_MODE: 1 },
    createSymKeyGenerator(algorithm) {
      assert.equal(algorithm, 'ChaCha20');
      return { convertKeySync(blob) {
        assert.equal(blob.data.length, 32);
        const key = { data: Buffer.from(blob.data), cleared: false,
          clearMem() { this.data.fill(0); this.cleared = true; } };
        keys.push(key); return key;
      } };
    },
    createCipher(algorithm) {
      assert.equal(algorithm, 'ChaCha20|Poly1305');
      const state = { calls: [], updates: [], results: [], finalized: false };
      ciphers.push(state);
      return {
        initSync(mode, key, params) {
          assert.equal(params.algName, 'Poly1305ParamsSpec');
          assert.equal(params.iv.data.length, 12); assert.equal(params.authTag.data.length, 16);
          state.calls.push('init'); state.encrypt = mode === kit.CryptoMode.ENCRYPT_MODE;
          state.aad = Buffer.from(params.aad.data); state.tag = Buffer.from(params.authTag.data);
          const factory = state.encrypt ? crypto.createCipheriv : crypto.createDecipheriv;
          state.native = factory('chacha20-poly1305', key.data, Buffer.from(params.iv.data), { authTagLength: 16 });
          // Deliberately do NOT setAAD here: the platform's legacy path waits for update.
        },
        updateSync(blob) {
          assert.equal(state.finalized, false); assert.ok(blob && blob.data);
          state.calls.push('update'); state.updates.push(blob.data.length);
          if (!state.aadSubmitted) { state.native.setAAD(state.aad); state.aadSubmitted = true; }
          const output = state.native.update(Buffer.from(blob.data));
          if (!output.length) return null;
          const data = new Uint8Array(output); state.results.push(data); return { data };
        },
        doFinalSync(input) {
          assert.equal(input, null, 'this legacy adapter seam expects update followed by final(null)');
          assert.equal(state.finalized, false); state.calls.push('final'); state.finalized = true;
          if (!state.encrypt) state.native.setAuthTag(state.tag);
          const final = state.native.final(); // verifies on decrypt; does NOT feed pending AAD.
          const output = state.encrypt ? Buffer.concat([final, state.native.getAuthTag()]) : final;
          return output.length ? { data: new Uint8Array(output) } : null;
        }
      };
    }
  };
  // SDK @ohos.util.d.ts explicitly returns undefined for empty input.
  class Encoder { encodeInto(value) { return value.length ? new Uint8Array(Buffer.from(value, 'utf8')) : undefined; } }
  const load = createLoader({
    '@kit.CryptoArchitectureKit': { cryptoFramework: kit },
    '@kit.ArkTS': { util: { TextEncoder: Encoder } }
  }, { Error });
  const adapter = load('remote/RemoteCrypto');
  return { kit, adapter, keys, ciphers, byteAdapter: load('remote/RemoteBytes') };
}
test('UTF-8 normalizes the SDK undefined result for an empty first-login Host id', () => {
  const { byteAdapter } = sdkHarness();
  assert.equal(byteAdapter.utf8('').length, 0);
  assert.equal(hex(byteAdapter.utf8('主机')), Buffer.from('主机').toString('hex'));
});

function params(v, decrypt = false) {
  return { algName: 'Poly1305ParamsSpec', iv: { data: bytes(v.nonceHex) }, aad: { data: bytes(v.aadHex) },
    authTag: { data: decrypt ? bytes(v.ciphertextAndTagHex).slice(-16) : new Uint8Array(16) } };
}
function rawCipher(h, vector, decrypt = false) {
  const key = h.kit.createSymKeyGenerator('ChaCha20').convertKeySync({ data: bytes(vector.keyHex) });
  const cipher = h.kit.createCipher('ChaCha20|Poly1305');
  cipher.initSync(decrypt ? h.kit.CryptoMode.DECRYPT_MODE : h.kit.CryptoMode.ENCRYPT_MODE, key, params(vector, decrypt));
  return { key, cipher };
}

test('SDK model control: skipping empty update reproduces wrong tag; empty update returns null and fixes AAD submission', () => {
  const h = sdkHarness();
  const old = rawCipher(h, empty), corrected = rawCipher(h, empty);
  try {
    // Setup control only: no production source/function is patched to obtain this failure.
    const wrong = old.cipher.doFinalSync(null).data;
    assert.notEqual(hex(wrong), empty.ciphertextAndTagHex);
    const ignoredAad = independentVector(Buffer.from(empty.keyHex, 'hex'), 0, Buffer.alloc(0), Buffer.alloc(0));
    assert.equal(hex(wrong), ignoredAad.ciphertextAndTagHex, 'missing update must specifically omit AAD, not invent another error');
    assert.equal(corrected.cipher.updateSync({ data: new Uint8Array(0) }), null);
    assert.equal(hex(corrected.cipher.doFinalSync(null).data), empty.ciphertextAndTagHex);
  } finally { old.key.clearMem(); corrected.key.clearMem(); }
});

test('actual seal: empty plaintext with nonempty hash AAD matches the independent public vector', () => {
  const h = sdkHarness();
  const encrypted = h.adapter.seal(bytes(empty.keyHex), 0, bytes(empty.aadHex), new Uint8Array(0));
  assert.equal(hex(encrypted), empty.ciphertextAndTagHex);
  assert.deepEqual(h.ciphers[0].updates, [0]);
  assert.deepEqual(h.ciphers[0].calls, ['init', 'update', 'final']);
  assert.equal(h.keys[0].cleared, true);
});

test('actual open: empty plaintext hash-AAD vector verifies successfully despite null update and final results', () => {
  const h = sdkHarness();
  const plaintext = h.adapter.open(bytes(empty.keyHex), 0, bytes(empty.aadHex), bytes(empty.ciphertextAndTagHex));
  assert.equal(plaintext.length, 0);
  assert.deepEqual(h.ciphers[0].updates, [0]);
  assert.deepEqual(h.ciphers[0].calls, ['init', 'update', 'final']);
  assert.equal(h.keys[0].cleared, true);
});

test('actual open: empty-payload tag tampering or AAD tampering rejects with a stable error and clears SDK key', () => {
  for (const tamper of ['tag', 'aad']) {
    const h = sdkHarness();
    const aad = bytes(empty.aadHex), encrypted = bytes(empty.ciphertextAndTagHex);
    if (tamper === 'tag') encrypted[encrypted.length - 1] ^= 1; else aad[0] ^= 1;
    assert.throws(() => h.adapter.open(bytes(empty.keyHex), 0, aad, encrypted), { message: 'NOISE_DECRYPT_FAILED' });
    assert.equal(h.keys[0].cleared, true);
    assert.deepEqual(h.ciphers[0].updates, [0]);
  }
});

test('actual adapters: nonempty plaintext with empty or nonempty AAD retains correct ciphertext, verification and counter encoding', () => {
  const fixedNoise = vectors.chacha20Poly1305.filter(v => v.label.startsWith('Noise nonce '));
  const rfc = vectors.chacha20Poly1305.find(v => v.label === 'RFC 8439 2.8.2');
  const nonemptyAad = independentVector(Buffer.from(rfc.keyHex, 'hex'), 0, Buffer.from(rfc.aadHex, 'hex'), Buffer.from(rfc.plaintextHex, 'hex'));
  const cases = fixedNoise.map(v => ({ vector: v, counter: Number(v.label.slice('Noise nonce '.length)) }));
  cases.push({ vector: nonemptyAad, counter: 0 });
  for (const { vector: v, counter } of cases) {
    const h = sdkHarness();
    const ciphertext = h.adapter.seal(bytes(v.keyHex), counter, bytes(v.aadHex), bytes(v.plaintextHex));
    assert.equal(hex(ciphertext), v.ciphertextAndTagHex);
    const plaintext = h.adapter.open(bytes(v.keyHex), counter, bytes(v.aadHex), bytes(v.ciphertextAndTagHex));
    assert.equal(hex(plaintext), v.plaintextHex);
    assert.ok(h.ciphers.every(c => c.updates.length === 1 && c.updates[0] > 0));
    assert.ok(h.keys.every(key => key.cleared));
  }
});

test('actual open: invalid nonempty message tag never returns tentative plaintext and scrubs the update buffer', () => {
  const h = sdkHarness();
  const v = vectors.chacha20Poly1305.find(v => v.label === 'Noise nonce 0');
  const encrypted = bytes(v.ciphertextAndTagHex); encrypted[encrypted.length - 1] ^= 1;
  assert.throws(() => h.adapter.open(bytes(v.keyHex), 0, bytes(v.aadHex), encrypted), { message: 'NOISE_DECRYPT_FAILED' });
  assert.equal(h.ciphers[0].results.length, 1, 'the SDK seam exposes tentative plaintext before final authentication');
  assert.ok(h.ciphers[0].results[0].every(value => value === 0));
  assert.equal(h.keys[0].cleared, true);
});

test('actual adapters: empty plaintext and empty AAD also handle null update/final results', () => {
  const h = sdkHarness();
  const v = independentVector(Buffer.from(empty.keyHex, 'hex'), 0, Buffer.alloc(0), Buffer.alloc(0));
  assert.equal(hex(h.adapter.seal(bytes(v.keyHex), 0, new Uint8Array(0), new Uint8Array(0))), v.ciphertextAndTagHex);
  assert.equal(h.adapter.open(bytes(v.keyHex), 0, new Uint8Array(0), bytes(v.ciphertextAndTagHex)).length, 0);
  assert.deepEqual(h.ciphers.map(c => c.updates), [[0], [0]]);
  assert.ok(h.keys.every(key => key.cleared));
});
