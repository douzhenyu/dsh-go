const test = require('node:test');
const assert = require('node:assert/strict');
const { createLoader, deferred, flush } = require('./ets-loader.cjs');

// All URLs, tokens, cookies, UUIDs and prompts below are synthetic test values.
// Network/system seams are substituted; AppStore, Transcript and NativeDecode are unchanged.
function harness() {
  const storage = new Map();
  const disk = new Map();
  const writes = [];
  const clients = [];
  const notifications = [];
  const timers = new Map();
  const controls = { nextConnectGate: undefined };
  let serial = 0;
  const prefs = {
    async get(key, fallback) { return disk.has(key) ? disk.get(key) : fallback; },
    async put(key, value) { writes.push({ key, value }); disk.set(key, value); },
    async flush() {}
  };
  class FakeClient {
    constructor() {
      clients.push(this); this.follows = []; this.subscriptions = []; this.sends = []; this.settingsCalls = [];
      this.connectGate = controls.nextConnectGate; controls.nextConnectGate = undefined;
    }
    async connect(url) { this.launchUrl = url; if (this.connectGate) await this.connectGate.promise; }
    disconnect() { this.disconnected = true; }
    async sessions() { return this.sessionGate ? this.sessionGate.promise : this.sessionRows || []; }
    async workspaces() { return this.workspaceRows || []; }
    async rpc(endpoint, argsJson = '{}') {
      if (endpoint === 'settings/mutate') {
        const args = JSON.parse(argsJson); this.settingsCalls.push(args);
        if (this.settingsGate) await this.settingsGate.promise;
        return JSON.stringify({ ns: args.ns, revision: args.expectedRevision + 1,
          schema: { type: 'object' }, value: {}, base: {}, user: {}, secrets: [] });
      }
      if (endpoint === 'session/modelCatalog') return '{"groups":[],"default":{}}';
      if (endpoint === 'permissionPresets/catalog') return '{"options":[]}';
      return '{}';
    }
    subscribe(endpoint, args, next, error) {
      const sub = { id: 'sub-' + ++serial, endpoint, next, error }; this.subscriptions.push(sub); return sub.id;
    }
    follow(sessionId, next, error) {
      const sub = { id: 'follow-' + ++serial, sessionId, next, error }; this.follows.push(sub); return sub.id;
    }
    unfollow(id) { const sub = this.follows.find(f => f.id === id); if (sub) sub.closed = true; }
    async read() { return this.readGate ? this.readGate.promise : { records: [], hasMore: false }; }
    async send(sessionId, text, requestId) {
      const request = { sessionId, text, requestId }; this.sends.push(request);
      if (this.sendHook) return this.sendHook(request);
    }
    async respondApproval() {}
    async cancel() {}
  }
  const load = createLoader({
    '../data/NativeClient': { NativeClient: FakeClient },
    './NativeLocalSettings': { nativeLocalSettings: {
      async publish(kind, title, body) { notifications.push({ kind, title, body }); return true; },
      getPreference(_key, fallback) { return fallback; }
    } },
    '@ohos.data.preferences': { default: { getPreferences: async () => prefs } },
    '@ohos.app.ability.ConfigurationConstant': { default: { ColorMode: { COLOR_MODE_LIGHT: 1, COLOR_MODE_DARK: 2, COLOR_MODE_NOT_SET: 0 } } },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(value) { return new TextEncoder().encode(value); } }, generateRandomUUID: () => 'test-uuid-' + ++serial } }
  }, {
    AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => { storage.set(key, value); return true; } },
    setTimeout: fn => { const id = ++serial; timers.set(id, fn); return id; },
    clearTimeout: id => timers.delete(id)
  });
  const { appStore: store } = load('state/AppStore');
  const decode = load('data/NativeDecode');
  const context = { getApplicationContext: () => ({ setColorMode() {} }) };
  async function connect(host = 'one.invalid') {
    await store.connect('http://' + host + ':1234/?token=synthetic-login-token', 'Fixture host');
    return clients.at(-1);
  }
  return { store, storage, clients, disk, writes, prefs, context, connect, decode, controls, notifications };
}
function session(id) {
  return { sessionId: id, title: id, cwd: '/fixture', updatedAt: 1, running: false, blank: false, projectionsJson: '{}' };
}
function answer(h, text, seq = 1) {
  return h.decode.sessionUpdate('s', { type: 'event', event: {
    seq, type: 'assistant/message', data: { message: { content: [{ type: 'text', text }] } }
  } });
}

test('connection generation: a late authentication result cannot replace a newer connected host', async () => {
  const h = harness();
  const auth = deferred();
  h.controls.nextConnectGate = auth;
  const old = h.store.connect('http://old.invalid/?token=synthetic-old-token', 'Old host');
  await h.connect('new.invalid');
  const newId = h.storage.get('activeHostId');
  auth.resolve();
  await old;
  assert.equal(h.storage.get('activeHostId'), newId);
  assert.equal(h.storage.get('activeHostAddress'), 'http://new.invalid:1234');
  assert.equal(h.storage.get('hosts').length, 1, 'stale auth must not even persist old endpoint metadata');
  h.store.disconnect();
});

test('connection generation: a late old baseline cannot overwrite the newer host metadata or lists', async () => {
  const h = harness();
  // Pause the first connection at its initial session baseline before connecting another host.
  const old = h.store.connect('http://old.invalid/?token=synthetic-old-token', 'Old host');
  const oldClient = h.clients.at(-1);
  oldClient.sessionGate = deferred();
  await flush();
  await h.connect('new.invalid');
  const newId = h.storage.get('activeHostId');
  oldClient.sessionGate.resolve([session('old-session')]);
  await old;
  assert.equal(h.storage.get('activeHostId'), newId);
  assert.equal(h.storage.get('activeHostAddress'), 'http://new.invalid:1234');
  assert.equal(h.storage.get('connectionState'), 'ready');
  assert.equal(h.storage.get('sessions').length, 0);
  oldClient.onState('error', 'TIMEOUT: old request');
  assert.equal(h.storage.get('connectionState'), 'ready', 'retired client errors must also be ignored');
  h.store.disconnect();
});

test('refresh generation: stale lists and stale loading completion cannot replace a new connection', async () => {
  const h = harness();
  const oldClient = await h.connect();
  oldClient.sessionGate = deferred();
  const refresh = h.store.refresh();
  await h.connect('two.invalid');
  const snapshot = JSON.stringify(h.storage.get('sessions'));
  oldClient.sessionGate.resolve([session('stale-session')]);
  await refresh;
  assert.equal(JSON.stringify(h.storage.get('sessions')), snapshot);
  assert.equal(h.storage.get('activeHostAddress'), 'http://two.invalid:1234');
  assert.equal(h.storage.get('dataLoading'), false);
  h.store.disconnect();
});

test('session epoch: retired follow callbacks and errors cannot replace the active conversation', async () => {
  const h = harness();
  const client = await h.connect();
  h.store.openChat('old-session');
  const oldFollow = client.follows.at(-1);
  oldFollow.next(answer(h, 'old visible answer'));
  h.store.openChat('new-session');
  const current = client.follows.at(-1);
  assert.equal(oldFollow.closed, true);
  current.next(answer(h, 'current answer'));
  oldFollow.next(answer(h, 'WRONG stale answer', 2));
  oldFollow.error(new Error('TIMEOUT: old follow'));
  assert.equal(h.storage.get('chatMessages').length, 1);
  assert.equal(h.storage.get('chatMessages')[0].text, 'current answer');
  assert.equal(h.storage.get('chatError'), '');
  h.store.disconnect();
});

test('history epoch: delayed older history cannot leak into a newly opened conversation', async () => {
  const h = harness();
  const client = await h.connect();
  h.store.openChat('old-session');
  client.follows.at(-1).next(h.decode.sessionUpdate('old-session', { type: 'snapshot', cursor: 10, records: [], hasMore: true }));
  client.readGate = deferred();
  const older = h.store.loadOlder();
  h.store.openChat('new-session');
  client.follows.at(-1).next(answer(h, 'new conversation'));
  client.readGate.resolve({ records: answer(h, 'WRONG old history').records, hasMore: true });
  await older;
  assert.equal(h.storage.get('chatMessages').length, 1);
  assert.equal(h.storage.get('chatMessages')[0].text, 'new conversation');
  assert.equal(h.storage.get('chatHasMore'), false);
  h.store.disconnect();
});

test('unknown send result: retrying the same text reuses requestId until success; a new prompt gets a new id', async () => {
  const h = harness();
  const client = await h.connect();
  h.store.openChat('session-one');
  client.sendHook = () => { throw new Error('TIMEOUT: synthetic response lost'); };
  await assert.rejects(h.store.send('synthetic prompt'), /TIMEOUT/);
  assert.equal(h.storage.get('chatBusy'), false);
  assert.match(h.storage.get('chatError'), /复用请求编号/);
  client.sendHook = undefined;
  await h.store.send('synthetic prompt');
  assert.equal(client.sends[0].requestId, client.sends[1].requestId);
  assert.equal(client.sends[0].sessionId, client.sends[1].sessionId);
  await h.store.send('a new prompt');
  assert.notEqual(client.sends[1].requestId, client.sends[2].requestId);
  h.store.disconnect();
});

test('session epoch: old send completion does not clear a new send busy state or retry identity', async () => {
  const h = harness();
  const client = await h.connect();
  const oldGate = deferred(), newGate = deferred();
  client.sendHook = request => request.sessionId === 'old' ? oldGate.promise : newGate.promise;
  h.store.openChat('old');
  const oldSend = h.store.send('same text');
  h.store.openChat('new');
  const newSend = h.store.send('same text');
  oldGate.resolve(); await oldSend;
  assert.equal(h.storage.get('chatBusy'), true);
  newGate.reject(new Error('TIMEOUT: response lost'));
  await assert.rejects(newSend, /TIMEOUT/);
  client.sendHook = undefined;
  await h.store.send('same text');
  assert.equal(client.sends[1].requestId, client.sends[2].requestId);
  assert.notEqual(client.sends[0].requestId, client.sends[1].requestId);
  h.store.disconnect();
});

test('notifications: live turn outcomes and pending requests are deduplicated; snapshots stay silent', async () => {
  const h = harness(); const client = await h.connect();
  h.store.openChat('s'); const follow = client.follows.at(-1);
  follow.next(h.decode.sessionUpdate('s', { type: 'snapshot', cursor: 1,
    records: [{ seq: 1, type: 'turn/end', data: { reason: { kind: 'done' } } }] }));
  assert.equal(h.notifications.length, 0);
  const completed = h.decode.sessionUpdate('s', { type: 'event', event: { seq: 2, type: 'turn/end', data: { reason: { kind: 'done' } } } });
  follow.next(completed); follow.next(completed);
  assert.deepEqual(h.notifications.map(item => item.kind), ['done']);
  follow.next(h.decode.sessionUpdate('s', { type: 'event', event: { seq: 3, type: 'turn/end', data: { reason: { kind: 'aborted' } } } }));
  assert.deepEqual(h.notifications.map(item => item.kind), ['done', 'failed']);
  client.onHostEvent({ type: 'waterfall', event: 'approval/request', eventId: 'approval-1', sessionId: 's', toolName: 'bash', rawJson: '{}', argsJson: '{}' });
  client.onHostEvent({ type: 'waterfall', event: 'approval/request', eventId: 'approval-1', sessionId: 's', toolName: 'bash', rawJson: '{}', argsJson: '{}' });
  assert.deepEqual(h.notifications.map(item => item.kind), ['done', 'failed', 'approval']);
  h.store.disconnect();
});

test('settings generation: a retired Host response cannot become current success and is never replayed', async () => {
  const h = harness(); const old = await h.connect();
  old.settingsGate = deferred();
  const write = h.store.hostMutate('subagent', [{ op: 'set', path: ['maxDepth'], valueJson: '3' }], 7);
  await flush(); await h.connect('new.invalid'); old.settingsGate.resolve();
  await assert.rejects(write, /DISCONNECTED/);
  assert.equal(old.settingsCalls.length, 1); assert.equal(old.settingsCalls[0].expectedRevision, 7);
  assert.equal(h.clients.at(-1).settingsCalls.length, 0); h.store.disconnect();
});

test('metadata persistence excludes login query, fragment, token, and client cookie; selecting it requires reauthentication', async () => {
  const h = harness();
  await h.store.initialize(h.context);
  await h.store.connect('http://metadata.invalid:1234/?token=synthetic-secret-token#synthetic-fragment', 'Saved host');
  const client = h.clients.at(-1);
  client.cookie = 'synthetic-secret-cookie';
  await h.store.setPreference('font', '2');
  const written = JSON.stringify(h.writes);
  for (const secret of ['synthetic-secret-token', 'synthetic-secret-cookie', 'synthetic-fragment', '?token=']) assert.ok(!written.includes(secret));
  const endpoints = JSON.parse(h.disk.get('endpoints'));
  assert.equal(endpoints.length, 1);
  assert.deepEqual(Object.keys(endpoints[0]).sort(), ['id', 'kind', 'name', 'url']);
  assert.equal(endpoints[0].kind, 'direct');
  assert.equal(endpoints[0].url, 'http://metadata.invalid:1234');
  const id = endpoints[0].id;
  h.store.disconnect();
  await assert.rejects(h.store.selectHost(id), /登录地址重新连接/);
  assert.equal(h.storage.get('connectionState'), 'disconnected');
  assert.equal(h.storage.get('chatMessages').length, 0);
  assert.equal(h.storage.get('sessions').length, 0);
  assert.equal(h.storage.get('activeHostAddress'), endpoints[0].url);
});

test('failed preference flush does not publish a preference as persisted', async () => {
  const h = harness();
  await h.store.initialize(h.context);
  const before = h.storage.get('chatFontSize');
  h.prefs.flush = async () => { throw new Error('synthetic disk failure'); };
  await assert.rejects(h.store.setPreference('font', '3'), /disk failure/);
  assert.equal(h.storage.get('chatFontSize'), before);
  assert.equal(h.store.getPreference('font', '1'), '1');
});
