const test = require('node:test');
const assert = require('node:assert/strict');
const { createLoader, deferred, flush } = require('./ets-loader.cjs');

function harness(options = {}) {
  const storage = new Map([['connectionState', 'disconnected']]);
  const timers = new Map(), opens = [], saves = [], clears = [], relays = [], tunnels = [];
  let epoch = 0, timerId = 0;
  class Account {
    constructor(serverUrl) { this.serverUrl = serverUrl; this.session = undefined; this.identity = {}; }
    async hosts() { if (this.readFailure) throw new Error(this.readFailure); return [{ id: 'host-1', name: 'Fixture Host', online: true, trust: this.changed ? 'keyChanged' : 'pinned' }]; }
    async connectionParameters(hostId) { return { hostId, synthetic: true }; }
    async logout() { this.session = undefined; if (this.onSessionChanged) await this.onSessionChanged(); }
    close() { this.closed = true; }
  }
  const restored = new Account('https://relay.test'); restored.session = { account: 'fixture' };
  const disk = new Map(options.empty ? [] : [['https://relay.test', { account: restored, lastHostId: 'host-1' }]]);
  const vault = {
    restoreGate: undefined,
    async restore(server) { return this.restoreGate ? this.restoreGate.promise : disk.get(server); },
    async save(account, lastHostId) { saves.push({ account, lastHostId }); disk.set(account.serverUrl, { account, lastHostId }); },
    async clear(server) { clears.push(server); disk.delete(server); if (this.clearGate) await this.clearGate.promise; }
  };
  const store = {
    get connectionEpoch() { return epoch; },
    async connectCarrier(tunnel, name, server, hostId) {
      ++epoch; opens.push({ tunnel, name, server, hostId, epoch });
      storage.set('connectionState', 'connecting'); this.onConnectionState?.('connecting', '');
      const openingEpoch = epoch;
      if (this.openGate) await this.openGate.promise;
      if (epoch !== openingEpoch) return;
      storage.set('activeHostId', 'remote:' + hostId + '@' + server); storage.set('activeHostAddress', server);
      storage.set('connectionState', 'ready'); this.onConnectionState?.('ready', '');
    },
    cancelConnection(owned) { if (owned === epoch) this.disconnect(); },
    disconnect() { epoch++; storage.set('connectionState', 'disconnected'); this.onConnectionState?.('disconnected', ''); },
    fail(code = 'RELAY_SILENCE') { storage.set('connectionState', 'error'); this.onConnectionState?.('error', code); },
    directIntent() { epoch++; storage.set('connectionState', 'connecting'); this.onConnectionState?.('connecting', ''); }
  };
  const prefs = { async get(_key, fallback) { return options.server || 'https://relay.test'; }, async put() {}, async flush() {} };
  const load = createLoader({
    '@ohos.app.ability.common': {},
    '@ohos.data.preferences': { default: { getPreferences: async () => prefs } },
    '../remote/RemoteAccount': { RemoteAccount: Account },
    '../remote/RemoteSessionVault': { RemoteSessionVault: class { constructor() { return vault; } } },
    '../remote/RemoteRelay': { RemoteRelay: class { constructor(params, identity) { this.params = params; relays.push(this); } } },
    '../remote/RemoteTunnel': { RemoteTunnel: class { constructor(relay) { this.relay = relay; tunnels.push(this); } close() { this.closed = true; } } },
    '../remote/RemoteDtos': { DEFAULT_REMOTE_SERVER: 'https://relay.test' },
    '../remote/RemoteServer': { normalizeRemoteServer: value => value },
    '../remote/RemoteCrypto': { checkRemoteCrypto() {} },
    './AppStore': { appStore: store }
  }, {
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) },
    setTimeout(fn, delay) { const id = ++timerId; timers.set(id, { fn, delay }); return id; },
    clearTimeout(id) { timers.delete(id); }
  });
  const { RemoteConnectionManager } = load('state/RemoteConnectionManager');
  const manager = new RemoteConnectionManager();
  async function initialize() { await manager.initialize({}); await flush(); }
  async function fire() { const [id, timer] = timers.entries().next().value; timers.delete(id); timer.fn(); await flush(); }
  return { manager, initialize, fire, timers, opens, saves, clears, vault, disk, store, storage, restored, Account, tunnels };
}

test('startup restores secure account and automatically connects remembered trusted Host exactly once', async () => {
  const h = harness(); await h.initialize();
  assert.equal(h.manager.account, h.restored);
  assert.equal(h.opens.length, 1); assert.equal(h.opens[0].hostId, 'host-1');
  assert.equal(h.storage.get('connectionState'), 'ready');
  assert.equal(h.storage.get('remoteReconnectState'), 'idle');
  assert.equal(h.saves.length, 1);
  await h.manager.initialize({}); h.manager.resume(); await flush();
  assert.equal(h.opens.length, 1, 'reopening the app/page must not replace an already-ready carrier');
});

test('temporary transport loss schedules bounded backoff and opens a fresh carrier without replaying writes', async () => {
  const h = harness(); await h.initialize();
  h.store.fail(); assert.equal(h.timers.size, 1); assert.equal([...h.timers.values()][0].delay, 2000);
  h.store.fail(); assert.equal(h.timers.size, 1, 'duplicate errors coalesce');
  await h.fire();
  assert.equal(h.opens.length, 2); assert.notEqual(h.opens[0].tunnel, h.opens[1].tunnel);
  assert.equal(h.storage.get('connectionState'), 'ready'); assert.equal(h.timers.size, 0);
});

test('changed identity and revoked authorization stop automatic reconnect without overwriting trust', async () => {
  const h = harness(); h.restored.changed = true; await h.initialize();
  assert.equal(h.opens.length, 0); assert.equal(h.timers.size, 0);
  assert.equal(h.storage.get('remoteReconnectError'), 'PEER_IDENTITY_MISMATCH');
  h.manager.resume(); await flush(); assert.equal(h.opens.length, 0);
  const revoked = harness(); await revoked.initialize(); revoked.store.fail('DEVICE_REVOKED');
  assert.equal(revoked.timers.size, 0); assert.equal(revoked.storage.get('remoteReconnectError'), 'DEVICE_REVOKED');
});

test('manual disconnect and direct-Host selection cancel queued reconnects, including retired timer callbacks', async () => {
  for (const action of ['disconnect', 'directIntent']) {
    const h = harness(); await h.initialize(); h.store.fail();
    const callback = [...h.timers.values()][0].fn;
    h.store[action](); assert.equal(h.timers.size, 0);
    callback(); await flush(); h.manager.resume(); await flush();
    assert.equal(h.opens.length, 1);
  }
});

test('a direct connection selected during in-flight Remote opening owns the new epoch', async () => {
  const h = harness(); h.store.openGate = deferred(); await h.initialize();
  assert.equal(h.opens.length, 1);
  h.store.directIntent(); const directEpoch = h.store.connectionEpoch;
  h.store.openGate.resolve(); await flush();
  assert.equal(h.store.connectionEpoch, directEpoch, 'retired Remote must not disconnect the direct attempt');
  assert.equal(h.storage.get('connectionState'), 'connecting');
  assert.equal(h.tunnels[0].closed, true); assert.equal(h.timers.size, 0);
  h.manager.resume(); await flush(); assert.equal(h.opens.length, 1);
});

test('logout clears saved authorization and a late account callback cannot recreate it', async () => {
  const h = harness(); await h.initialize();
  const callback = h.restored.onSessionChanged;
  h.vault.clearGate = deferred(); const pending = h.manager.logout(); await flush();
  const before = h.saves.length; await callback();
  assert.equal(h.saves.length, before); assert.equal(h.disk.has('https://relay.test'), false);
  h.vault.clearGate.resolve(); await pending;
  assert.equal(h.manager.account.session, undefined); assert.equal(h.manager.lastHostId, '');
  assert.equal(h.storage.get('connectionState'), 'disconnected');
  h.manager.resume(); await flush(); assert.equal(h.opens.length, 1);
});

test('transient Host-list errors retain secure login, stop after six retries, and resume on foreground', async () => {
  const h = harness(); h.restored.readFailure = 'NETWORK_FAILED'; await h.initialize();
  assert.equal(h.clears.length, 0); assert.equal(h.manager.account, h.restored);
  for (let i = 0; i < 6; i++) await h.fire();
  assert.equal(h.timers.size, 0); assert.equal(h.storage.get('remoteReconnectError'), 'RECONNECT_EXHAUSTED');
  h.restored.readFailure = ''; h.manager.resume(); await flush();
  assert.equal(h.opens.length, 1); assert.equal(h.storage.get('connectionState'), 'ready');
});

test('session rotation hook saves current credentials while invalidation clears the secure record', async () => {
  const h = harness(); await h.initialize();
  const before = h.saves.length;
  await h.restored.onSessionChanged(); assert.equal(h.saves.length, before + 1);
  h.restored.session = undefined; await h.restored.onSessionChanged();
  assert.equal(h.disk.has('https://relay.test'), false); assert.equal(h.manager.lastHostId, '');
});
