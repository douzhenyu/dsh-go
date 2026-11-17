// Execute the page's REAL controller. Only `struct` -> `class` and exclusion of
// ArkUI @Builder/render code are transformations; no controller method is copied.
// This seam checks the lifecycle policy, not whether a device emits onHidden.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { sdkTypeScript, deferred, flush } = require('./ets-loader.cjs');
const ts = require(sdkTypeScript);
const pagePath = path.resolve(__dirname, '../entry/src/main/ets/pages/RemoteConnection.ets');
const pageSource = fs.readFileSync(pagePath, 'utf8');
const builderAt = pageSource.search(/^\s*@Builder\b/m);
assert.ok(builderAt > 0, 'the extraction boundary must exist in the real page');
assert.equal((pageSource.slice(0, builderAt).match(/export struct RemoteConnection\b/g) || []).length, 1);
const controllerSource = pageSource.slice(0, builderAt).replace('export struct RemoteConnection', 'export class RemoteConnection') + '\n}\n';
const compiled = ts.transpileModule(controllerSource, {
  fileName: pagePath.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS,
    experimentalDecorators: true, useDefineForClassFields: false }
});
const compileErrors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
assert.equal(compileErrors.length, 0, ts.formatDiagnosticsWithColorAndContext(compileErrors, {
  getCanonicalFileName: name => name, getCurrentDirectory: () => __dirname, getNewLine: () => '\n'
}));

function harness(options = {}) {
  const accounts = [], browser = [], tunnels = [], polls = [], cancellations = [], storeOpens = [];
  const storage = new Map([['connectionState', 'disconnected'], ['activeHostId', ''], ['activeHostAddress', ''], ['activeHostName', '']]);
  const timers = new Map();
  const host = { id: 'fixture-host', name: 'Fixture host', online: true, trust: 'pinned',
    identityKey: 'synthetic-public-key', pinnedIdentityKey: 'synthetic-public-key' };
  let now = 1000, timerId = 0, flowId = 0, storeEpoch = 10, cryptoChecks = 0;
  const clock = {
    timers,
    setTimeout(fn, delay) { const id = ++timerId; timers.set(id, { fn, at: now + delay, delay }); return id; },
    clearTimeout(id) { timers.delete(id); },
    async fireNext() {
      const next = [...timers].sort((a, b) => a[1].at - b[1].at)[0];
      assert.ok(next, 'expected a scheduled controller timer');
      now = next[1].at; timers.delete(next[0]); next[1].fn(); await flush();
    }
  };
  class Account {
    constructor(serverUrl) {
      this.serverUrl = serverUrl; this.identity = { synthetic: true };
      this.session = options.signedIn ? { account: 'fixture-account', provider: 'github' } : undefined;
      this.cancelCalls = []; accounts.push(this);
    }
    async loginProviders() { return [{ id: 'github', displayName: 'GitHub', qrStartUrl: '/synthetic' }]; }
    async beginLogin() {
      const flow = { loginUrl: 'https://relay.test/authorize/synthetic-' + ++flowId, expiresAt: now + 120000, providerId: 'github' };
      this.activeLogin = flow; return flow;
    }
    cancelLogin(flow) {
      this.cancelCalls.push(flow);
      if (this.activeLogin === flow) this.activeLogin = undefined;
    }
    async pollLogin(flow) {
      polls.push(flow);
      assert.equal(this.activeLogin, flow, 'page must poll the account-owned active flow');
      return false;
    }
    async hosts() {
      if (options.hostReadFailures > 0) {
        options.hostReadFailures--;
        const error = new Error('CONNECTION_FAILED'); error.retryable = true; error.status = 503; throw error;
      }
      return [host];
    }
    async descriptor() { return { name: host.name, identityKey: host.identityKey, online: true, onlineKnown: true }; }
    trustHost() { throw new Error('Trusted-host lifecycle fixture should not open a trust prompt'); }
    async connectionParameters(id) {
      return { serverUrl: this.serverUrl, hostDeviceId: id, deviceId: 'synthetic-client', accessToken: 'synthetic-only' };
    }
    close() { this.closed = true; }
  }
  class Relay { constructor(parameters, identity) { this.parameters = parameters; this.identity = identity; } }
  class Tunnel {
    constructor(relay) { this.relay = relay; this.closeCount = 0; tunnels.push(this); }
    close() { if (!this.closed) { this.closed = true; this.closeCount++; } }
  }
  const store = {
    get connectionEpoch() { return storeEpoch; },
    connectCarrier(carrier, name, serverUrl, hostId) {
      storeEpoch++; storage.set('connectionState', 'connecting');
      const gate = deferred();
      storeOpens.push({ carrier, name, serverUrl, hostId, epoch: storeEpoch, gate });
      return gate.promise;
    },
    cancelConnection(epoch) {
      cancellations.push(epoch);
      if (epoch === storeEpoch) { storeEpoch++; storage.set('connectionState', 'disconnected'); }
    },
    disconnect() { throw new Error('Lifecycle tests must not disconnect an already-ready Store carrier'); }
  };
  const coordinator = {
    serverUrl: 'https://relay.test', account: undefined, lastHostId: '',
    async initialize() { if (!this.account) this.account = new Account(this.serverUrl); },
    async useServer(server) { if (server !== this.serverUrl) { this.account?.close(); this.serverUrl = server; this.account = new Account(server); } },
    pauseReconnect() {},
    async adopt(hostId) { this.lastHostId = hostId; },
    async logout() { this.account?.close(); this.account = new Account(this.serverUrl); this.lastHostId = ''; }
  };
  const imports = {
    '../state/RemoteConnectionManager': { remoteConnectionManager: coordinator },
    '../remote/RemoteAccount': { RemoteAccount: Account },
    '../remote/RemoteDtos': { DEFAULT_REMOTE_SERVER: 'https://relay.test' },
    '../remote/RemoteServer': { normalizeRemoteServer: value => value },
    '../remote/RemoteCrypto': {
      checkRemoteCrypto() { cryptoChecks++; if (options.cryptoFails) throw new Error('CRYPTO_VECTOR_MISMATCH'); },
      fingerprint: () => '0123456789AB'
    },
    '../remote/RemoteRelay': { RemoteRelay: Relay },
    '../remote/RemoteTunnel': { RemoteTunnel: Tunnel },
    '../state/AppStore': { appStore: store },
    '../common/Style': {}, '@ohos.app.ability.common': {}, '@kit.BasicServicesKit': {}
  };
  const exports = {};
  function storageLink(key) {
    return (target, property) => Object.defineProperty(target, property, {
      configurable: true,
      get() { return storage.get(key); },
      // Constructor field initializers establish defaults without replacing an existing StorageLink value.
      set(value) { if (!storage.has(key)) storage.set(key, value); }
    });
  }
  class Stack { pop() { this.pops = (this.pops || 0) + 1; } }
  vm.runInNewContext(compiled.outputText, {
    exports, Error, Uint8Array,
    require(name) { assert.ok(Object.hasOwn(imports, name), 'Unexpected controller dependency: ' + name); return imports[name]; },
    Component: target => target, State: () => {}, Watch: () => () => {}, StorageLink: storageLink, NavPathStack: Stack,
    AppStorage: { setOrCreate: (key, value) => storage.set(key, value), get: key => storage.get(key) },
    getContext: () => ({ openLink(url) { const gate = deferred(); browser.push({ url, gate }); return gate.promise; } }),
    setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout,
    Date: class extends Date { static now() { return now; } }
  }, { filename: pagePath + ':controller-test' });
  const page = new exports.RemoteConnection();
  page.getUIContext = () => ({ showAlertDialog() { throw new Error('Unexpected trust dialog in lifecycle-only fixture'); } });
  async function appear() { page.aboutToAppear(); await flush(); }
  async function startLogin() {
    const pending = page.login(); await flush();
    assert.equal(browser.length, flowId, 'each requested login must open the platform browser once');
    return { pending, flow: accounts.at(-1).activeLogin, launch: browser.at(-1) };
  }
  function completeStore() {
    const opening = storeOpens.at(-1); assert.ok(opening);
    storage.set('connectionState', 'ready'); storage.set('activeHostId', 'remote:' + opening.hostId + '@' + opening.serverUrl);
    storage.set('activeHostAddress', opening.serverUrl); storage.set('activeHostName', opening.name);
    opening.gate.resolve();
  }
  return { page, accounts, browser, tunnels, polls, cancellations, storeOpens, clock, storage, host,
    appear, startLogin, completeStore, get cryptoChecks() { return cryptoChecks; } };
}

test('browser hiding retains the same OAuth flow; activate resumes polling without cancel/restarting login', async () => {
  const h = harness(); await h.appear();
  const { pending, flow, launch } = await h.startLogin();
  h.page.deactivate();
  assert.equal(h.accounts[0].activeLogin, flow);
  assert.equal(h.accounts[0].cancelCalls.length, 0);
  assert.equal(h.clock.timers.size, 0);
  h.page.activate(); await flush();
  assert.equal(h.page.pendingLogin, flow);
  assert.equal(h.clock.timers.size, 1);
  assert.equal([...h.clock.timers.values()][0].delay, 2000);
  // openLink may finish after the app has returned: this must leave the resumed timer intact.
  launch.gate.resolve(); await pending;
  assert.equal(h.accounts[0].cancelCalls.length, 0);
  assert.equal(h.clock.timers.size, 1);
  await h.clock.fireNext();
  assert.equal(h.polls.length, 1); assert.equal(h.polls[0], flow);
  assert.equal(h.accounts.length, 1, 'the memory account survives hide/show');
  assert.equal(h.browser.length, 1, 'returning does not open a second authorization');
  h.page.aboutToDisappear();
});

test('late completion of an old openLink cannot cancel or clear a subsequently started OAuth flow', async () => {
  const h = harness(); await h.appear();
  const old = await h.startLogin();
  h.page.cancelLogin();
  const current = await h.startLogin();
  assert.notEqual(old.flow, current.flow);
  old.launch.gate.resolve(); await old.pending;
  assert.equal(h.accounts[0].activeLogin, current.flow);
  assert.equal(h.page.pendingLogin, current.flow);
  assert.equal(h.page.waitingLogin, true);
  assert.equal(h.page.launchingLogin, true, 'old finally must not finish the new browser launch');
  assert.equal(h.accounts[0].cancelCalls.filter(flow => flow === current.flow).length, 0);
  current.launch.gate.resolve(); await current.pending;
  await h.clock.fireNext();
  assert.equal(h.polls[0], current.flow);
  h.page.aboutToDisappear();
});

test('aboutToDisappear cancels pending authorization even if onHidden already deactivated the page', async () => {
  const h = harness(); await h.appear();
  const { pending, flow, launch } = await h.startLogin();
  launch.gate.resolve(); await pending;
  assert.equal(h.clock.timers.size, 1);
  h.page.deactivate();
  assert.equal(h.accounts[0].cancelCalls.length, 0);
  assert.equal(h.page.pendingLogin, flow);
  h.page.aboutToDisappear();
  assert.equal(h.accounts[0].activeLogin, undefined);
  assert.equal(h.accounts[0].cancelCalls.filter(value => value === flow).length, 1);
  assert.equal(h.page.pendingLogin, undefined);
  assert.equal(h.clock.timers.size, 0);
});

test('aboutToDisappear directly cancels an in-flight browser launch and prevents late reactivation', async () => {
  const h = harness(); await h.appear();
  const { pending, flow, launch } = await h.startLogin();
  h.page.aboutToDisappear();
  assert.ok(h.accounts[0].cancelCalls.includes(flow));
  assert.equal(h.accounts[0].activeLogin, undefined);
  launch.gate.resolve(); await pending;
  assert.equal(h.page.pendingLogin, undefined);
  assert.equal(h.clock.timers.size, 0);
  assert.equal(h.polls.length, 0);
});

test('cancelLogin removes the poll timer and a previously queued callback cannot poll the retired flow', async () => {
  const h = harness(); await h.appear();
  const { pending, flow, launch } = await h.startLogin();
  launch.gate.resolve(); await pending;
  const queued = [...h.clock.timers.values()][0]; assert.ok(queued);
  h.page.cancelLogin();
  assert.equal(h.clock.timers.size, 0);
  assert.equal(h.page.pendingLogin, undefined);
  assert.equal(h.page.waitingLogin, false);
  assert.ok(h.accounts[0].cancelCalls.includes(flow));
  queued.fn(); await flush();
  assert.equal(h.polls.length, 0);
  h.page.aboutToDisappear();
});

test('leaving during connect cancels its exact Store epoch and closes the pending tunnel despite late completion', async () => {
  const h = harness({ signedIn: true }); await h.appear();
  const opening = h.page.connectHost(h.host); await flush();
  assert.equal(h.storeOpens.length, 1);
  const epoch = h.storeOpens[0].epoch;
  h.page.aboutToDisappear();
  assert.deepEqual(h.cancellations, [epoch]);
  assert.equal(h.tunnels[0].closed, true);
  h.storeOpens[0].gate.resolve(); await opening;
  assert.equal(h.page.pendingConnectionEpoch, -1);
  assert.equal(h.tunnels[0].closeCount, 1);
  assert.equal(h.storage.get('connectionState'), 'disconnected');
});

test('a ready Store-owned connection survives hiding, disappearance and viewing conversations', async () => {
  const h = harness({ signedIn: true }); await h.appear();
  const opening = h.page.connectHost(h.host); await flush();
  h.completeStore(); await opening;
  assert.equal(h.page.pendingConnectionEpoch, -1);
  assert.equal(h.page.pendingTunnel, undefined);
  h.page.conversations();
  assert.equal(h.page.stack.pops, 1); assert.equal(h.storage.get('selectedTab'), 1);
  h.page.deactivate(); h.page.aboutToDisappear();
  assert.equal(h.cancellations.length, 0);
  assert.equal(h.tunnels[0].closed, undefined);
  assert.equal(h.storage.get('connectionState'), 'ready');
});

test('opening an already-authorized target Host connects without a second connection click', async () => {
  const h = harness({ signedIn: true });
  h.storage.set('remoteTargetHostId', h.host.id);
  await h.appear(); await flush();
  assert.equal(h.storeOpens.length, 1, `Host-row selection must start connection: error=${h.page.errorCode}, loading=${h.page.hostsLoading}, connecting=${h.page.connecting}, hosts=${h.page.hosts.length}, target=${h.storage.get('remoteTargetHostId')}`);
  h.completeStore(); await flush();
  assert.equal(h.storage.get('connectionState'), 'ready');
  assert.equal(h.storage.get('remoteTargetHostId'), '');
  h.page.aboutToDisappear();
});

test('successful OAuth with one online Host continues directly into connection', async () => {
  const h = harness(); await h.appear();
  const login = await h.startLogin(); login.launch.gate.resolve(); await login.pending;
  h.accounts[0].pollLogin = async () => { h.accounts[0].session = { account: 'fixture-account', provider: 'github' }; return true; };
  await h.clock.fireNext(); await flush();
  assert.equal(h.storeOpens.length, 1, 'successful login must not require a second connect click');
  h.completeStore(); await flush();
  assert.equal(h.storage.get('connectionState'), 'ready');
  h.page.aboutToDisappear();
});

test('transient directory errors reuse authorization and retry the target without another login or click', async () => {
  const h = harness({ signedIn: true, hostReadFailures: 2 });
  h.storage.set('remoteTargetHostId', h.host.id); await h.appear(); await flush();
  assert.equal(h.page.errorCode, 'CONNECTION_FAILED_HTTP_503');
  assert.equal([...h.clock.timers.values()][0].delay, 2000);
  await h.clock.fireNext(); await flush();
  assert.equal([...h.clock.timers.values()][0].delay, 4000);
  await h.clock.fireNext(); await flush();
  assert.equal(h.storeOpens.length, 1); assert.equal(h.browser.length, 0);
  h.completeStore(); await flush(); h.page.aboutToDisappear();
  assert.equal(h.clock.timers.size, 0);
});

test('native page distinguishes HTTP service failure from transport failure without showing server messages', async () => {
  const h = harness(); await h.appear();
  h.accounts[0].loginProviders = async () => { const e = new Error('CONNECTION_FAILED'); e.status = 503; throw e; };
  await h.page.loadProviders();
  assert.equal(h.page.errorCode, 'CONNECTION_FAILED_HTTP_503');
  h.page.aboutToDisappear();
});

test('platform crypto failure prevents creation of an account or browser login', async () => {
  const h = harness({ cryptoFails: true }); await h.appear();
  assert.equal(h.cryptoChecks, 1);
  assert.equal(h.page.cryptoReady, false);
  assert.equal(h.page.errorCode, 'CRYPTO_VECTOR_MISMATCH');
  await h.page.login();
  assert.equal(h.accounts.length, 0); assert.equal(h.browser.length, 0);
  h.page.aboutToDisappear();
});
