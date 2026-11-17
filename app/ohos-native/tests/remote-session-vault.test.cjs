// Production vault/account/crypto run unchanged; only native Asset and crypto primitives are replaced.
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createLoader, deferred, flush } = require('./ets-loader.cjs');
const publicKey = 'hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo';
const privateKey = Buffer.from('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a', 'hex').toString('base64url');
const hostKey = Buffer.alloc(32, 42).toString('base64url');
function snapshot(server = 'https://relay.test', expires = Date.now() + 86400000) {
  return JSON.stringify({ version: 1, serverUrl: server,
    session: { serverUrl: server, deviceId: 'synthetic-device', account: 'synthetic-account', provider: 'github',
      accessToken: 'synthetic-access-' + 'a'.repeat(1400), accessTokenExpiresAt: Date.now() + 3600000,
      refreshToken: 'synthetic-refresh-' + 'b'.repeat(1400), refreshTokenExpiresAt: expires },
    publicKey, privateKey, pins: [{ hostId: 'host-one', identityKey: hostKey }] });
}
function harness(disk = new Map()) {
  const calls = [], failures = {};
  const Tag = { SECRET: 1, ALIAS: 2, ACCESSIBILITY: 3, AUTH_TYPE: 5, SYNC_TYPE: 16,
    DATA_LABEL_NORMAL_1: 33, DATA_LABEL_NORMAL_2: 34, RETURN_TYPE: 65, CONFLICT_RESOLUTION: 68 };
  const nativeError = code => Object.assign(new Error('PRIVATE NATIVE DETAIL MUST NOT ESCAPE'), { code });
  const key = map => Buffer.from(map.get(Tag.ALIAS)).toString('hex');
  const matches = (entry, query) => [...query].every(([tag, value]) => tag === Tag.RETURN_TYPE ||
    (value instanceof Uint8Array ? Buffer.from(entry.get(tag) || []).equals(Buffer.from(value)) : entry.get(tag) === value));
  const clone = map => new Map([...map].map(([tag, value]) => [tag, value instanceof Uint8Array ? new Uint8Array(value) : value]));
  const asset = { Tag, Accessibility: { DEVICE_FIRST_UNLOCKED: 1 }, AuthType: { NONE: 0 }, SyncType: { NEVER: 0 },
    ConflictResolution: { OVERWRITE: 0 }, ReturnType: { ALL: 0, ATTRIBUTES: 1 },
    async add(map) {
      calls.push(['add', clone(map)]); if (failures.add) await failures.add(map);
      assert.ok(map.get(Tag.SECRET).length <= 1024, 'Asset SECRET must fit the native 1024-byte limit');
      assert.equal(map.get(Tag.ACCESSIBILITY), 1); assert.equal(map.get(Tag.AUTH_TYPE), 0); assert.equal(map.get(Tag.SYNC_TYPE), 0);
      disk.set(key(map), clone(map));
    },
    async query(query) {
      calls.push(['query', clone(query)]); if (failures.query) await failures.query(query);
      const result = [...disk.values()].filter(map => matches(map, query)).map(clone);
      if (!result.length) throw nativeError(24000002); return result;
    },
    async remove(query) {
      calls.push(['remove', clone(query)]); if (failures.remove) await failures.remove(query);
      let removed = false; for (const [alias, entry] of disk) if (matches(entry, query)) { disk.delete(alias); removed = true; }
      if (!removed) throw nativeError(24000002);
    }
  };
  const cryptoFramework = {
    createMd(algorithm) { assert.equal(algorithm, 'SHA256'); const hash = crypto.createHash('sha256');
      return { updateSync: blob => hash.update(Buffer.from(blob.data)), digestSync: () => ({ data: new Uint8Array(hash.digest()) }) }; },
    createAsyKeyGenerator(algorithm) { assert.equal(algorithm, 'X25519'); return {
      convertKeySync(pub, pri) {
        const native = crypto.createPrivateKey({ key: Buffer.from(pri.data), format: 'der', type: 'pkcs8' });
        const expected = crypto.createPublicKey(native).export({ format: 'der', type: 'spki' });
        assert.deepEqual(Buffer.from(pub.data), expected);
        const encodedPrivate = new Uint8Array(native.export({ format: 'der', type: 'pkcs8' }));
        return { pubKey: { getEncoded: () => ({ data: new Uint8Array(expected) }) },
          priKey: { getEncoded: () => ({ data: encodedPrivate }), clearMem() { encodedPrivate.fill(0); } } };
      }
    }; }
  };
  const clock = { now: Date.now() };
  class ClockDate extends Date { static now() { return clock.now; } }
  const load = createLoader({
    '@kit.AssetStoreKit': { asset }, '@kit.CryptoArchitectureKit': { cryptoFramework },
    '@kit.ArkTS': { util: { generateRandomUUID: () => crypto.randomUUID() } },
    '@kit.NetworkKit': { http: { createHttp() { throw new Error('Network is not used for local restoration'); } } },
    '@kit.BasicServicesKit': {}, '@ohos.url': { default: { URL } },
    './RemoteBytes': { utf8: value => new Uint8Array(Buffer.from(value)), text: value => Buffer.from(value).toString('utf8'),
      base64url: value => Buffer.from(value).toString('base64url'), unbase64url: value => new Uint8Array(Buffer.from(value, 'base64url')),
      fromHex: value => new Uint8Array(Buffer.from(value, 'hex')), equalBytes: (a, b) => Buffer.from(a).equals(Buffer.from(b)),
      bytes: (...values) => new Uint8Array(Buffer.concat(values.map(value => Buffer.from(value)))) }
  }, { Error, Uint8Array, ArrayBuffer, Date: ClockDate });
  const { RemoteSessionVault } = load('remote/RemoteSessionVault');
  const { RemoteAccount } = load('remote/RemoteAccount');
  const vault = new RemoteSessionVault();
  const account = new RemoteAccount('https://relay.test'); account.restoreSecureSnapshot(snapshot());
  return { vault, account, disk, calls, failures, asset, nativeError, RemoteAccount, RemoteSessionVault, clock };
}

test('restore status is readonly safe metadata and never includes secrets or native error detail', async t => {
  const h = harness(); t.after(() => h.account.close());
  assert.equal(h.vault.lastRestoreStatus, 'empty');
  assert.equal(Reflect.set(h.vault, 'lastRestoreStatus', 'synthetic-secret'), false);
  assert.equal(await h.vault.restore('https://relay.test'), undefined);
  assert.equal(h.vault.lastRestoreStatus, 'empty');
  await h.vault.save(h.account, 'host-one');
  const restored = await h.vault.restore('https://relay.test'); t.after(() => restored.account.close());
  assert.equal(h.vault.lastRestoreStatus, 'restored');
  await h.vault.save(h.account, 'host-one'); await h.vault.clear('https://relay.test');
  assert.equal(h.vault.lastRestoreStatus, 'restored', 'save/clear must not overwrite restore diagnostics');
  h.failures.query = () => { throw h.nativeError(24000001); };
  await assert.rejects(h.vault.restore('https://relay.test'), { message: 'SECURE_STORAGE_UNAVAILABLE' });
  assert.equal(h.vault.lastRestoreStatus, 'unavailable');
  assert.match(h.vault.lastRestoreStatus, /^(empty|expired|invalid|unavailable|restored)$/);
});

test('repeated production snapshot exports preserve the SDK-owned shared private key encoding', t => {
  const h = harness(); t.after(() => h.account.close());
  const shared = h.account.identity.nativeKey.priKey.getEncoded().data;
  const before = Buffer.from(shared);
  const first = JSON.parse(h.account.exportSecureSnapshot());
  assert.deepEqual(Buffer.from(shared), before, 'export must not zero an SDK-owned buffer');
  const second = JSON.parse(h.account.exportSecureSnapshot());
  assert.deepEqual(Buffer.from(shared), before);
  assert.equal(first.privateKey, privateKey); assert.equal(second.privateKey, privateKey);
  assert.equal(second.publicKey, publicKey);
});

test('production vault persists identity, long tokens, pins and last host across a fresh process seam', async t => {
  const h = harness(); t.after(() => h.account.close());
  await h.vault.save(h.account, 'host-one'); h.account.close();
  const restarted = harness(h.disk); t.after(() => restarted.account.close());
  const restored = await restarted.vault.restore('relay.test/'); t.after(() => restored.account.close());
  assert.equal(restored.lastHostId, 'host-one');
  assert.equal(restored.account.session.deviceId, 'synthetic-device');
  assert.equal(restored.account.session.refreshToken, 'synthetic-refresh-' + 'b'.repeat(1400));
  assert.equal(JSON.parse(restored.account.exportSecureSnapshot()).privateKey, privateKey);
  assert.equal(JSON.parse(restored.account.exportSecureSnapshot()).pins[0].identityKey, hostKey);
  assert.equal(await restarted.vault.restore('https://other.test'), undefined);
});

test('server scopes remain isolated when saving, restoring and clearing two accounts', async t => {
  const h = harness(); t.after(() => h.account.close());
  const other = new h.RemoteAccount('https://other.test'); t.after(() => other.close());
  other.restoreSecureSnapshot(snapshot('https://other.test'));
  await h.vault.save(h.account, 'host-one'); await h.vault.save(other, 'other-host');
  await h.vault.clear('relay.test/');
  assert.equal(await h.vault.restore('https://relay.test'), undefined);
  const restored = await h.vault.restore('https://other.test'); t.after(() => restored.account.close());
  assert.equal(restored.lastHostId, 'other-host'); assert.equal(restored.account.serverUrl, 'https://other.test');
  await h.vault.clear('https://other.test'); assert.equal(h.disk.size, 0);
});

test('corrupt/missing chunks fail closed and remove the entire server credential set', async t => {
  for (const mode of ['corrupt', 'missing', 'head', 'native-corruption']) {
    const h = harness(); t.after(() => h.account.close()); await h.vault.save(h.account, 'host-one');
    const first = [...h.disk][0];
    if (mode === 'missing') h.disk.delete(first[0]);
    if (mode === 'corrupt') first[1].get(h.asset.Tag.SECRET)[0] ^= 1;
    if (mode === 'head') [...h.disk.values()].at(-1).get(h.asset.Tag.SECRET).fill(123);
    if (mode === 'native-corruption') {
      h.failures.query = () => { throw h.nativeError(24000007); };
    }
    await assert.rejects(h.vault.restore('https://relay.test'), { message: 'SECURE_SESSION_INVALID' });
    assert.equal(h.vault.lastRestoreStatus, 'invalid');
    assert.equal(h.disk.size, 0, mode + ' must remove secrets and pins');
  }
});

test('expired refresh credentials are removed on restart rather than restored', async t => {
  const h = harness(); t.after(() => h.account.close()); await h.vault.save(h.account, 'host-one');
  h.clock.now += 2 * 86400000;
  assert.equal(await h.vault.restore('https://relay.test'), undefined); assert.equal(h.disk.size, 0);
  assert.equal(h.vault.lastRestoreStatus, 'expired');
});

test('unavailable or locked secure storage returns a stable explicit failure without a fallback', async t => {
  for (const code of [24000001, 24000005, 201, 24000008]) {
    const h = harness(); t.after(() => h.account.close());
    h.failures.query = () => { throw h.nativeError(code); };
    await assert.rejects(h.vault.restore('https://relay.test'), { message: 'SECURE_STORAGE_UNAVAILABLE' });
    await assert.rejects(h.vault.save(h.account, 'host-one'), { message: 'SECURE_STORAGE_UNAVAILABLE' });
    assert.equal(h.disk.size, 0);
  }
});

test('failed chunk/head writes never report success or replace the last complete saved login', async t => {
  for (const failHead of [false, true]) {
    const h = harness(); t.after(() => h.account.close()); await h.vault.save(h.account, 'old-host');
    const oldSize = h.disk.size;
    h.failures.add = map => {
      const isHead = Buffer.from(map.get(h.asset.Tag.ALIAS)).toString().endsWith('.head');
      if (isHead === failHead) throw h.nativeError(24000008);
    };
    await assert.rejects(h.vault.save(h.account, 'new-host'), { message: 'SECURE_STORAGE_UNAVAILABLE' });
    delete h.failures.add;
    const restored = await h.vault.restore('https://relay.test'); t.after(() => restored.account.close());
    assert.equal(restored.lastHostId, 'old-host'); assert.equal(h.disk.size, oldSize);
  }
});

test('save operations and logout clear serialize so a late native write cannot resurrect the login', async t => {
  const h = harness(); t.after(() => h.account.close());
  const gate = deferred(); let entered = false;
  h.failures.add = async () => { if (!entered) { entered = true; await gate.promise; } };
  const pending = h.vault.save(h.account, 'host-one'); await flush();
  h.account.onSessionChanged = () => h.vault.save(h.account, '');
  const logout = h.account.logout(); gate.resolve(); await pending; await logout;
  assert.equal(h.account.session, undefined); assert.equal(h.disk.size, 0);
  assert.equal(await h.vault.restore('https://relay.test'), undefined);
});

test('logout removal failures are explicit and retryable, while close preserves the saved login', async t => {
  const h = harness(); t.after(() => h.account.close()); await h.vault.save(h.account, 'host-one');
  h.account.close();
  const restored = await h.vault.restore('https://relay.test'); t.after(() => restored.account.close());
  restored.account.onSessionChanged = () => h.vault.save(restored.account, '');
  h.failures.remove = () => { throw h.nativeError(24000008); };
  await assert.rejects(restored.account.logout(), { message: 'SECURE_STORAGE_UNAVAILABLE' });
  assert.notEqual(h.disk.size, 0);
  delete h.failures.remove; await restored.account.logout();
  assert.equal(h.disk.size, 0); assert.equal(await h.vault.restore('https://relay.test'), undefined);
});
