// Synthetic wire fixtures follow server_api.dart and remote_account.dart.
// Descriptor presence follows Dart Server.device: inline bool takes precedence;
// otherwise /presence must supply a valid bool, and errors never become offline.
// Only NetworkKit/platform primitives are replaced; account, server and DTO code execute unchanged.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createLoader, deferred, flush } = require('./ets-loader.cjs');
const key = Buffer.from(Array.from({ length: 32 }, (_, i) => i + 1)).toString('base64url');
const changedKey = Buffer.alloc(32, 42).toString('base64url');
const provider = { id: 'github', displayName: 'GitHub', startUrl: '/api/v1/auth/oauth/github/start', qrStartUrl: '/api/v1/auth/oauth/qr/start?provider=github' };
function tokenPair(suffix = 'original', expires = Date.now() + 3600000) {
  return { accessToken: 'synthetic-access-token-' + suffix, accessTokenExpiresAt: expires,
    refreshToken: 'synthetic-refresh-token-' + suffix, refreshTokenExpiresAt: Date.now() + 86400000 };
}
function setup() {
  const calls = [], requests = [], keys = [];
  const state = { providers: [provider], qrStatus: 'complete', account: 'fixture-account', hostKey: key,
    inlinePresence: false, online: true, listingOnline: true, presenceOnline: true, tokens: tokenPair(), routes: undefined, destroyedKeys: 0 };
  const peer = () => ({ deviceId: 'host-one', role: 'host', name: 'Fixture host', platform: 'linux', identityKey: state.hostKey,
    membershipId: 'member-1', clientVersion: '0.6.0', harnessVersion: '0.2.1-rc.1', ...(state.inlinePresence ? { online: state.online } : {}) });
  function route(call) {
    const p = new URL(call.url).pathname;
    if (p === '/api/v1/auth/oauth/providers') return { items: state.providers };
    if (p === '/api/v1/auth/oauth/qr/start') return { qrId: 'synthetic-private-poll-id-123456', scanUrl: 'https://relay.test/api/v1/auth/oauth/qr/scan?public=fixture', expiresIn: 120, provider: 'github' };
    if (p.startsWith('/api/v1/auth/oauth/qr/')) return { status: state.qrStatus, token: 'synthetic-one-time-account-token' };
    if (p === '/api/v1/auth/me') return { account: state.account };
    if (p === '/api/v1/devices/register') return state.tokens;
    if (p === '/api/v1/auth/refresh') return tokenPair('rotated');
    if (p === '/api/v1/devices') return { items: [{ ...peer(), identityKey: undefined, online: state.listingOnline }, { deviceId: 'not-host', role: 'client' }] };
    if (p === '/api/v1/devices/host-one/presence') return { deviceId: 'host-one', online: state.presenceOnline, lastSeenAt: 1234 };
    if (p === '/api/v1/devices/host-one') return peer();
    throw new Error('Unimplemented synthetic route: ' + p);
  }
  class Request {
    request(url, options, callback) {
      const call = { url, options, body: options.extraData ? JSON.parse(options.extraData) : undefined };
      calls.push(call); this.call = call;
      Promise.resolve().then(() => state.routes ? state.routes(call, route) : route(call)).then(result => {
        const status = result?.__status || 200;
        const body = result?.__status ? result.body : result;
        callback(undefined, { responseCode: status, result: typeof body === 'string' ? body : JSON.stringify(body) });
      }, error => callback(error, undefined));
    }
    destroy() { this.destroyed = true; }
  }
  class KeyPair {
    constructor() {
      this.publicKey = new Uint8Array(Buffer.from(key, 'base64url'));
      this.nativeKey = { priKey: { getEncoded: () => ({ data: new Uint8Array(Buffer.alloc(32, 7)) }) } };
      keys.push(this);
    }
    static generate() { return new KeyPair(); }
    static fromRaw(privateKey, publicKey) {
      assert.equal(Buffer.from(privateKey).toString('hex'), '07'.repeat(32));
      const pair = new KeyPair(); pair.publicKey = new Uint8Array(publicKey); return pair;
    }
    destroy() { this.publicKey.fill(0); state.destroyedKeys++; }
  }
  let serial = 0;
  const load = createLoader({
    '@kit.NetworkKit': { http: { createHttp: () => { const req = new Request(); requests.push(req); return req; }, RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { STRING: 0 } } },
    '@kit.BasicServicesKit': {},
    '@ohos.url': { default: { URL } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => '00000000-0000-4000-8000-' + String(++serial).padStart(12, '0') } },
    './RemoteCrypto': { RemoteKeyPair: KeyPair },
    './RemoteBytes': { utf8: value => new Uint8Array(Buffer.from(value, 'utf8')), text: bytes => Buffer.from(bytes).toString('utf8'), base64url: bytes => Buffer.from(bytes).toString('base64url'), unbase64url: value => new Uint8Array(Buffer.from(value, 'base64url')), fromHex: value => new Uint8Array(Buffer.from(value, 'hex')), equalBytes: (a, b) => Buffer.from(a).equals(Buffer.from(b)) }
  }, { Error, ArrayBuffer });
  const { RemoteAccount } = load('remote/RemoteAccount');
  const { RemoteServer, normalizeRemoteServer } = load('remote/RemoteServer');
  const account = new RemoteAccount('https://relay.test');
  async function login() { const flow = await account.beginLogin('github'); assert.equal(await account.pollLogin(flow), true); return flow; }
  return { account, state, calls, requests, keys, login, RemoteAccount, RemoteServer, normalizeRemoteServer };
}

test('network callback errors expose numeric code only and never echo the request or token', async t => {
  const h = setup(); t.after(() => h.account.close());
  h.state.routes = async () => { throw { code: 2300007, message: 'https://secret.invalid/?token=synthetic-secret' }; };
  await assert.rejects(h.account.loginProviders(), e => e.message === 'NETWORK_2300007' && e.retryable === true);
});

test('failed post-OAuth save preserves safe wrapped code and can save current session without repeating registration', async t => {
  const h = setup(); t.after(() => h.account.close()); let writes = 0;
  h.account.onSessionChanged = async () => { if (++writes === 1) throw { message: 'SECURE_STORAGE_UNAVAILABLE' }; };
  const flow = await h.account.beginLogin('github');
  await assert.rejects(h.account.pollLogin(flow), e => e.message === 'SECURE_STORAGE_UNAVAILABLE' && e.phase === 'SAVE_SESSION');
  assert.ok(h.account.session, 'authorized session must remain available for an explicit save retry');
  await h.account.persistCurrentSession();
  assert.equal(writes, 2); assert.equal((await h.account.hosts()).length, 1);
  assert.equal(h.calls.filter(c => c.url.endsWith('/devices/register')).length, 1);
});

test('secure account snapshot restores identity, credentials and pins, then rechecks the current descriptor', async t => {
  const h = setup(); t.after(() => h.account.close()); await h.login();
  await h.account.descriptor('host-one'); await h.account.trustHost('host-one', key);
  const snapshot = h.account.exportSecureSnapshot();
  const deviceId = h.account.session.deviceId;
  h.account.close();
  const restored = new h.RemoteAccount('https://relay.test/'); t.after(() => restored.close());
  restored.restoreSecureSnapshot(snapshot);
  assert.equal(restored.session.deviceId, deviceId);
  assert.equal(restored.session.refreshToken, 'synthetic-refresh-token-original');
  assert.equal((await restored.connectionParameters('host-one')).hostIdentityKey, key);
  h.state.hostKey = changedKey;
  await assert.rejects(restored.connectionParameters('host-one'), { message: 'PEER_IDENTITY_MISMATCH' });
  const other = new h.RemoteAccount('https://other.test'); t.after(() => other.close());
  assert.throws(() => other.restoreSecureSnapshot(snapshot), { message: 'SECURE_SESSION_INVALID' });
  assert.equal(other.session, undefined);
});

test('real wire sequence: OAuth QR completes with device registration, authenticated directory and explicit host pin', async t => {
  const h = setup(); t.after(() => h.account.close());
  assert.equal(h.account.session, undefined);
  const flow = await h.login();
  assert.equal(flow.loginUrl.startsWith('https://relay.test/'), true);
  assert.deepEqual(Object.keys(flow).sort(), ['expiresAt', 'loginUrl', 'providerId']);
  const registration = h.calls.find(c => c.url.endsWith('/devices/register'));
  assert.equal(registration.body.v, 1);
  assert.equal(registration.body.device.identityKey, key);
  assert.equal(registration.body.device.role, 'client');
  assert.equal(registration.body.device.platform, 'dsh-app-ohos');
  assert.equal(registration.options.header.Authorization, 'Bearer synthetic-one-time-account-token');
  const hosts = await h.account.hosts();
  assert.equal(hosts.length, 1); assert.equal(hosts[0].online, true); assert.equal(hosts[0].trust, 'unpinned');
  assert.equal(hosts[0].identityKey, key); assert.equal(hosts[0].pluginVersion, '0.6.0');
  await assert.rejects(h.account.connectionParameters('host-one'), { message: 'HOST_TRUST_REQUIRED' });
  await h.account.trustHost('host-one', key);
  const params = await h.account.connectionParameters('host-one');
  assert.deepEqual(Object.keys(params).sort(), ['accessToken', 'controlUrl', 'deviceId', 'hostDeviceId', 'hostIdentityKey', 'serverUrl']);
  assert.equal(params.controlUrl, 'wss://relay.test/ws/v1/connect');
  assert.equal(params.hostIdentityKey, key);
  assert.equal(params.accessToken, h.account.session.accessToken);
  for (const c of h.calls) {
    assert.equal(c.options.maxRedirects, 0); assert.equal(c.options.usingCache, false);
    assert.equal(c.options.header.Cookie, undefined);
    assert.ok(!c.url.includes('synthetic-access-token') && !c.url.includes('synthetic-one-time-account-token'));
  }
  const snapshot = h.account.session; snapshot.accessToken = 'mutated';
  assert.notEqual(h.account.session.accessToken, 'mutated');
});

test('Dart parity: inline descriptor online wins over listing and never queries /presence', async t => {
  for (const online of [true, false]) {
    const h = setup(); t.after(() => h.account.close());
    h.state.inlinePresence = true; h.state.online = online;
    h.state.listingOnline = !online; h.state.presenceOnline = !online;
    await h.login();
    const hosts = await h.account.hosts();
    assert.equal(hosts[0].online, online, 'explicit descriptor bool must override a stale listing');
    const descriptor = await h.account.descriptor('host-one');
    assert.equal(descriptor.onlineKnown, true); assert.equal(descriptor.online, online);
    await h.account.trustHost('host-one', key);
    if (online) assert.equal((await h.account.connectionParameters('host-one')).hostDeviceId, 'host-one');
    else await assert.rejects(h.account.connectionParameters('host-one'), { message: 'HOST_OFFLINE' });
    assert.equal(h.calls.filter(c => c.url.endsWith('/presence')).length, 0);
  }
});

test('Dart parity: absent descriptor online queries strict presence true/false before connection eligibility', async t => {
  for (const online of [true, false]) {
    const h = setup(); t.after(() => h.account.close());
    h.state.inlinePresence = false; h.state.listingOnline = !online; h.state.presenceOnline = online;
    await h.login();
    const hosts = await h.account.hosts();
    assert.equal(hosts[0].online, online, 'authorized presence must override the stale directory listing');
    assert.equal(hosts[0].lastSeenAt, 1234);
    const descriptor = await h.account.descriptor('host-one');
    assert.equal(descriptor.onlineKnown, true); assert.equal(descriptor.online, online);
    await h.account.trustHost('host-one', key);
    if (online) assert.equal((await h.account.connectionParameters('host-one')).hostIdentityKey, key);
    else await assert.rejects(h.account.connectionParameters('host-one'), { message: 'HOST_OFFLINE' });
    assert.equal(h.calls.filter(c => c.url.endsWith('/presence')).length, 3, 'hosts, descriptor and connect each authorize fresh presence');
  }
});

test('Dart parity: malformed presence cannot be downgraded to an offline host', async t => {
  for (const malformed of [{}, { online: 'false' }, [], null, { online: true, deviceId: 'wrong-host' }]) {
    const h = setup(); t.after(() => h.account.close()); await h.login();
    h.state.routes = (c, normal) => c.url.endsWith('/presence') ? malformed : normal(c);
    await assert.rejects(h.account.hosts(), { message: 'INVALID_MESSAGE' });
    await assert.rejects(h.account.descriptor('host-one'), { message: 'INVALID_MESSAGE' });
    await assert.rejects(h.account.trustHost('host-one', key), { message: 'PEER_IDENTITY_MISMATCH' });
    assert.ok(h.calls.some(c => c.url.endsWith('/presence')));
  }
});

test('Dart parity: presence authentication failure refreshes once and remains an error, never offline', async t => {
  const h = setup(); t.after(() => h.account.close()); await h.login();
  h.state.routes = (c, normal) => c.url.endsWith('/presence') ?
    { __status: 401, body: { error: { code: 'AUTH_INVALID', message: 'synthetic private detail' } } } : normal(c);
  await assert.rejects(h.account.hosts(), { message: 'AUTH_INVALID' });
  assert.equal(h.calls.filter(c => c.url.endsWith('/auth/refresh')).length, 1);
  const reads = h.calls.filter(c => c.url.endsWith('/presence'));
  assert.equal(reads.length, 2);
  assert.equal(reads[1].options.header.Authorization, 'Bearer synthetic-access-token-rotated');
  assert.equal(h.account.session, undefined, 'a permanent refusal must retire the saved authorization');
  await assert.rejects(h.account.trustHost('host-one', key), { message: 'ACCOUNT_AUTH_REQUIRED' });
});

test('provider auth paths and returned scan URL cannot redirect account authorization to another origin', async t => {
  const h = setup(); t.after(() => h.account.close());
  for (const path of ['https://evil.test/login', '//evil.test/login', '/api/v1/auth/../devices', '/api/v1/auth/%2e%2e/devices']) {
    h.state.providers = [{ ...provider, qrStartUrl: path }];
    await assert.rejects(h.account.loginProviders(), { message: 'INVALID_MESSAGE' });
  }
  h.state.providers = [provider];
  h.state.routes = (c, normal) => c.url.includes('/qr/start') ? { qrId: 'synthetic-private-id-long-enough', scanUrl: 'https://evil.test/login', expiresIn: 20 } : normal(c);
  await assert.rejects(h.account.beginLogin('github'), { message: 'INVALID_MESSAGE' });
});

test('server origin normalization allows HTTPS and private HTTP but rejects credentials, public cleartext and URL state', () => {
  const h = setup();
  assert.equal(h.normalizeRemoteServer('relay.test/'), 'https://relay.test');
  for (const value of ['http://127.0.0.1:8090', 'http://192.168.1.2', 'http://[::1]:8090', 'http://[fd12::1]']) assert.ok(h.normalizeRemoteServer(value));
  for (const value of ['http://public.example', 'https://user:pass@relay.test', 'https://relay.test/?token=x', 'https://relay.test/#x', 'https://relay.test/path']) assert.throws(() => h.normalizeRemoteServer(value), { message: 'INVALID_URL' });
  h.account.close();
});

test('cancelled in-flight QR completion never registers a device or publishes credentials', async t => {
  const h = setup(); t.after(() => h.account.close());
  const gate = deferred();
  h.state.routes = (c, normal) => /\/qr\/synthetic-private/.test(c.url) ? gate.promise : normal(c);
  const flow = await h.account.beginLogin('github');
  const pending = h.account.pollLogin(flow);
  const rejection = assert.rejects(pending, { message: 'LOGIN_CANCELLED' });
  h.account.cancelLogin(flow);
  gate.resolve({ status: 'complete', token: 'synthetic-one-time-account-token' });
  await rejection;
  assert.equal(h.account.session, undefined);
  assert.equal(h.calls.some(c => c.url.endsWith('/devices/register')), false);
});

test('concurrent polls consume the one-time token and register once', async t => {
  const h = setup(); t.after(() => h.account.close());
  const flow = await h.account.beginLogin('github');
  const a = h.account.pollLogin(flow), b = h.account.pollLogin(flow);
  assert.equal(a, b); assert.equal(await a, true); assert.equal(await b, true);
  assert.equal(h.calls.filter(c => c.url.endsWith('/devices/register')).length, 1);
  assert.equal(await h.account.pollLogin(flow), true);
  assert.equal(h.calls.filter(c => /\/qr\/synthetic-private/.test(c.url)).length, 1);
});

test('pending, expired and failed consumed authorizations have distinct stable outcomes', async t => {
  const h = setup(); t.after(() => h.account.close());
  h.state.qrStatus = 'pending'; const flow = await h.account.beginLogin('github');
  assert.equal(await h.account.pollLogin(flow), false);
  h.state.qrStatus = 'expired'; await assert.rejects(h.account.pollLogin(flow), { message: 'LOGIN_EXPIRED' });
  h.state.qrStatus = 'complete'; const next = await h.account.beginLogin('github');
  h.state.routes = (c, normal) => c.url.endsWith('/devices/register') ? { __status: 500, body: { error: { code: 'CONNECTION_FAILED', message: 'SECRET MUST NOT SURFACE' } } } : normal(c);
  await assert.rejects(h.account.pollLogin(next), e => e.message === 'CONNECTION_FAILED' && e.phase === 'REGISTER' && e.status === 500);
  const before = h.calls.length;
  await assert.rejects(h.account.pollLogin(next), e => e.message === 'CONNECTION_FAILED' && e.phase === 'REGISTER' && e.status === 500);
  assert.equal(h.calls.length, before, 'consumed one-shot authorization must require a new login');
});

test('rotating refresh token is single-flight across concurrent authenticated reads', async t => {
  const h = setup(); t.after(() => h.account.close());
  h.state.tokens = tokenPair('old-expiring', Date.now() + 1000); await h.login();
  const gate = deferred();
  h.state.routes = (c, normal) => c.url.endsWith('/auth/refresh') ? gate.promise : normal(c);
  const a = h.account.hosts(), b = h.account.descriptor('host-one');
  await flush();
  assert.equal(h.calls.filter(c => c.url.endsWith('/auth/refresh')).length, 1);
  gate.resolve(tokenPair('rotated')); await Promise.all([a, b]);
  assert.equal(h.account.session.refreshToken, 'synthetic-refresh-token-rotated');
});

test('server auth refusal refreshes once, retries with the new bearer, and never uses account token for host reads', async t => {
  const h = setup(); t.after(() => h.account.close()); await h.login();
  let rejected = false;
  h.state.routes = (c, normal) => {
    if (c.url.endsWith('/devices/host-one') && !rejected) { rejected = true; return { __status: 401, body: { error: { code: 'TOKEN_EXPIRED' } } }; }
    return normal(c);
  };
  await h.account.descriptor('host-one');
  const reads = h.calls.filter(c => c.url.endsWith('/devices/host-one'));
  assert.equal(reads.length, 2);
  assert.equal(reads[1].options.header.Authorization, 'Bearer synthetic-access-token-rotated');
});

test('host pin changes, mismatched descriptors and malformed identity keys fail closed', async t => {
  const h = setup(); t.after(() => h.account.close()); await h.login();
  await assert.rejects(h.account.trustHost('host-one', key), { message: 'PEER_IDENTITY_MISMATCH' });
  await h.account.descriptor('host-one'); await h.account.trustHost('host-one', key);
  h.state.hostKey = changedKey;
  assert.equal((await h.account.hosts())[0].trust, 'keyChanged');
  await assert.rejects(h.account.trustHost('host-one', changedKey), { message: 'PEER_IDENTITY_MISMATCH' });
  await assert.rejects(h.account.connectionParameters('host-one'), { message: 'PEER_IDENTITY_MISMATCH' });
  h.state.hostKey = 'not-a-key'; await assert.rejects(h.account.descriptor('host-one'), { message: 'INVALID_MESSAGE' });
});

test('close cancels pending native requests and destroys identity, without late publication', async () => {
  const h = setup(); await h.login();
  const gate = deferred(); h.state.routes = (c, normal) => c.url.endsWith('/devices') ? gate.promise : normal(c);
  const pending = h.account.hosts(); const rejection = assert.rejects(pending, { message: 'CLIENT_CLOSED' });
  await flush(); h.account.close(); await rejection;
  gate.resolve({ items: [] }); await flush();
  assert.equal(h.account.session, undefined); assert.equal(h.state.destroyedKeys, 1);
  assert.ok(h.requests.every(r => r.destroyed));
  assert.throws(() => h.account.identity, { message: 'CLIENT_CLOSED' });
});

test('late refresh cannot replace credentials from a newer completed login', async t => {
  const h = setup(); t.after(() => h.account.close());
  h.state.tokens = tokenPair('expiring', Date.now() + 1000); await h.login();
  const gate = deferred();
  h.state.routes = (c, normal) => c.url.endsWith('/auth/refresh') ? gate.promise : normal(c);
  const oldRead = h.account.hosts();
  const rejection = assert.rejects(oldRead, { message: 'ACCOUNT_AUTH_REQUIRED' });
  await flush();
  h.state.account = 'new-account'; h.state.tokens = tokenPair('new-account');
  await h.login();
  gate.resolve(tokenPair('WRONG-retired-refresh'));
  await rejection;
  assert.equal(h.account.session.account, 'new-account');
  assert.equal(h.account.session.accessToken, 'synthetic-access-token-new-account');
});

test('late old-account descriptor cannot authorize a pin in the new account', async t => {
  const h = setup(); t.after(() => h.account.close()); await h.login();
  const gate = deferred();
  h.state.routes = (c, normal) => c.url.endsWith('/devices/host-one') ? gate.promise : normal(c);
  const oldRead = h.account.descriptor('host-one');
  const rejection = assert.rejects(oldRead, { message: 'ACCOUNT_AUTH_REQUIRED' });
  await flush();
  h.state.account = 'new-account'; h.state.tokens = tokenPair('new-account'); await h.login();
  gate.resolve({ deviceId: 'host-one', role: 'host', name: 'Retired', platform: 'linux', identityKey: key, membershipId: 'member-old', online: true });
  await rejection;
  await assert.rejects(h.account.trustHost('host-one', key), { message: 'PEER_IDENTITY_MISMATCH' });
});

test('refresh token rotation waits for secure persistence before any authenticated request and retries a failed save', async t => {
  const h = setup(); t.after(() => h.account.close());
  h.state.tokens = tokenPair('expiring', Date.now() + 1000); await h.login();
  const gate = deferred(); let attempts = 0;
  h.account.onSessionChanged = () => { attempts++; return gate.promise; };
  const read = h.account.hosts(); const rejection = assert.rejects(read, { message: 'SECURE_STORAGE_UNAVAILABLE' });
  await flush();
  assert.equal(h.account.session.refreshToken, 'synthetic-refresh-token-rotated');
  assert.equal(h.calls.some(c => c.url.endsWith('/devices')), false, 'unsaved rotation must not authorize requests');
  gate.reject(new Error('SECURE_STORAGE_UNAVAILABLE')); await rejection;
  h.account.onSessionChanged = async () => { attempts++; };
  await h.account.hosts();
  assert.equal(attempts, 2, 'the next read must retry saving the already-rotated token');
  assert.equal(h.calls.filter(c => c.url.endsWith('/auth/refresh')).length, 1);
});

test('login, trust and logout await the persistence hook; close only destroys memory', async t => {
  const h = setup(); t.after(() => h.account.close());
  const events = []; const gate = deferred(); const entered = deferred();
  h.account.onSessionChanged = async () => { events.push(h.account.session?.account || 'cleared'); entered.resolve(); await gate.promise; };
  const pending = h.login(); let completed = false; pending.then(() => { completed = true; });
  await entered.promise; assert.equal(completed, false); assert.deepEqual(events, ['fixture-account']);
  gate.resolve(); await pending;
  await h.account.descriptor('host-one'); await h.account.trustHost('host-one', key);
  await h.account.logout();
  assert.deepEqual(events, ['fixture-account', 'fixture-account', 'cleared']);
  assert.equal(h.account.session, undefined); assert.equal(h.account.exportSecureSnapshot(), undefined);
  h.account.close(); assert.equal(events.length, 3);
});

test('expired and revoked sessions await secure cleanup and cannot masquerade as an offline host', async t => {
  for (const mode of ['expired', 'revoked', 'refused-twice']) {
    const h = setup(); t.after(() => h.account.close());
    h.state.tokens = tokenPair('expiring', Date.now() + 1000);
    if (mode === 'expired') h.state.tokens.refreshTokenExpiresAt = Date.now() - 1000;
    await h.login(); const persisted = [];
    h.account.onSessionChanged = async () => { persisted.push(h.account.session?.refreshToken || 'cleared'); };
    h.state.routes = (c, normal) => {
      if ((mode === 'revoked' && c.url.endsWith('/auth/refresh')) || (mode === 'refused-twice' && c.url.endsWith('/devices'))) {
        return { __status: 401, body: { error: { code: mode === 'revoked' ? 'DEVICE_REVOKED' : 'AUTH_INVALID' } } };
      }
      return normal(c);
    };
    await assert.rejects(h.account.hosts(), { message: mode === 'refused-twice' ? 'AUTH_INVALID' : 'ACCOUNT_AUTH_REQUIRED' });
    assert.equal(h.account.session, undefined); assert.equal(persisted.at(-1), 'cleared');
    assert.equal(h.account.exportSecureSnapshot(), undefined);
  }
});

test('a logout during a delayed save persists the newer cleared state before the old login can complete', async t => {
  const h = setup(); t.after(() => h.account.close()); const gate = deferred(); const entered = deferred(); const writes = [];
  h.account.onSessionChanged = async () => {
    writes.push(h.account.session?.account || 'cleared'); if (writes.length === 1) { entered.resolve(); await gate.promise; }
  };
  const pending = h.login(); const rejection = assert.rejects(pending, { message: 'LOGIN_CANCELLED' });
  await entered.promise; const logout = h.account.logout(); gate.resolve(); await logout; await rejection;
  assert.deepEqual(writes, ['fixture-account', 'cleared']); assert.equal(h.account.session, undefined);
});

test('stale refresh completion cannot persist over a newer login', async t => {
  const h = setup(); t.after(() => h.account.close());
  h.state.tokens = tokenPair('expiring', Date.now() + 1000); await h.login();
  const gate = deferred(); const writes = [];
  h.account.onSessionChanged = async () => { writes.push(h.account.session?.account || 'cleared'); };
  h.state.routes = (c, normal) => c.url.endsWith('/auth/refresh') ? gate.promise : normal(c);
  const oldRead = h.account.hosts(); const rejection = assert.rejects(oldRead, { message: 'ACCOUNT_AUTH_REQUIRED' });
  await flush(); h.state.account = 'new-account'; h.state.tokens = tokenPair('new-account'); await h.login();
  gate.resolve(tokenPair('retired')); await rejection;
  assert.deepEqual(writes, ['new-account']); assert.equal(h.account.session.account, 'new-account');
});

test('server errors expose only a stable code, never arbitrary detail or redirect body', async t => {
  const h = setup(); t.after(() => h.account.close());
  h.state.routes = () => ({ __status: 302, body: { error: { code: 'bad token SECRET', message: 'https://private/?token=secret' } } });
  await assert.rejects(h.account.loginProviders(), { message: 'INVALID_MESSAGE' });
});
