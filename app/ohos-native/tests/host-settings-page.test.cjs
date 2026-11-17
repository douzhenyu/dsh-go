// Execute the real page controller, using the same extraction seam as remote-page-lifecycle.
// ArkUI builders are excluded; controller methods are never copied into the fixture.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { sdkTypeScript, createLoader, deferred, flush } = require('./ets-loader.cjs');
const ts = require(sdkTypeScript);
const pagePath = path.resolve(__dirname, '../entry/src/main/ets/pages/HostSettingsPage.ets');
const source = fs.readFileSync(pagePath, 'utf8');
const builderAt = source.search(/^\s*@Builder\b/m);
assert.ok(builderAt > 0);
assert.equal((source.slice(0, builderAt).match(/export struct HostSettingsPage\b/g) || []).length, 1);
const controller = source.slice(0, builderAt).replace('export struct HostSettingsPage', 'export class HostSettingsPage') + '\n}\n';
const compiled = ts.transpileModule(controller, {
  fileName: pagePath.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS,
    experimentalDecorators: true, useDefineForClassFields: false }
});
const errors = (compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error);
assert.equal(errors.length, 0, JSON.stringify(errors.map(d => d.messageText)));
const dtos = createLoader({ '@kit.ArkTS': { util: { TextEncoder } } })('state/NativeHostSettings');

function field(kind = 'number', valueJson = '12') {
  return Object.assign(new dtos.HostSettingField(), { path: ['limit'], kind, valueJson, title: 'Limit', disabled: false });
}
function namespace(fields = [field()], ns = 'agent-loop', revision = 7) {
  return Object.assign(new dtos.HostSettingsNamespace(), { ns, fields, revision, writable: true });
}
function snapshot(namespaces = [namespace()]) {
  return Object.assign(new dtos.HostSettingsSnapshot(), { namespaces, writable: true });
}
function modelDefault() {
  return Object.assign(new dtos.DefaultModelInfo(), { provider: 'provider', model: 'model', revision: 9,
    writable: true, rememberLastSelectionSupported: true });
}
function harness(pageName = 'engine', overrides = {}) {
  const storage = new Map([['connectionState', 'ready'], ['activeHostId', 'host-a']]);
  const calls = [], dialogs = [], watches = new Map();
  let connectionEpoch = 10;
  const responses = {
    hostDescribe: () => snapshot(), hostPresets: () => [{ id: 'preset-a' }],
    hostPlugins: () => [{ name: 'plugin-a' }], hostDefaultModel: () => modelDefault(),
    hostDefaultPermission: () => Object.assign(new dtos.DefaultPermissionInfo(), { revision: 5, writable: true }),
    hostReadPreset: id => ({ id, content: 'fixture: true' }),
    hostMutate: ns => namespace([], ns, 8), hostSelectPreset: () => '{}',
    hostSetDefaultPermission: () => namespace([], 'permission'), hostSetDefaultModel: () => namespace([], 'agent-default-model'),
    hostSetBundleEnabled: () => '{"application":"applied"}', ...overrides
  };
  const store = { get connectionEpoch() { return connectionEpoch; }, hostModels: [
    { provider: 'provider', id: 'model', effortIds: ['high'], effortNames: ['High'] }
  ] };
  for (const method of Object.keys(responses)) store[method] = (...args) => {
    calls.push({ method, args, host: storage.get('activeHostId'), epoch: connectionEpoch });
    return Promise.resolve().then(() => responses[method](...args));
  };
  const exports = {};
  vm.runInNewContext(compiled.outputText, {
    exports, Error,
    require(name) {
      if (name === '../state/NativeHostSettings') return dtos;
      if (name === '../state/AppStore') return { appStore: store };
      if (name === '../components/DetailTitle' || name === '../common/Style') return {};
      throw new Error('Unexpected dependency: ' + name);
    },
    Component: target => target, State: () => {},
    Watch: method => (target, property) => watches.set(property, method),
    StorageLink: key => (target, property) => Object.defineProperty(target, property, {
      configurable: true, get() { return storage.get(key); },
      set(value) { if (!storage.has(key)) storage.set(key, value); }
    }),
    NavPathStack: class {}
  }, { filename: pagePath + ':controller-test' });
  const page = new exports.HostSettingsPage(); page.page = pageName;
  page.getUIContext = () => ({ showAlertDialog: dialog => dialogs.push(dialog) });
  function publish(key, value, notify = true) {
    storage.set(key, value);
    if (notify && watches.has(key)) page[watches.get(key)]();
  }
  function switchHost(id = 'host-b', notify = true) {
    connectionEpoch++; publish('activeHostId', id, notify);
  }
  function disconnect() {
    connectionEpoch++; publish('connectionState', 'disconnected');
  }
  const count = method => calls.filter(call => call.method === method).length;
  async function appear() { page.aboutToAppear(); await flush(); }
  return { page, calls, dialogs, store, responses, storage, publish, switchHost, disconnect, count, appear };
}

for (const pageName of ['engine', 'permission', 'models', 'presets', 'plugins']) {
  test(pageName + ': a load completing after disappearance cannot assign page state', async () => {
    const gate = deferred();
    const method = { engine: 'hostDescribe', permission: 'hostDefaultPermission', models: 'hostDefaultModel',
      presets: 'hostPresets', plugins: 'hostPlugins' }[pageName];
    const h = harness(pageName, { [method]: () => gate.promise });
    await h.appear(); h.page.aboutToDisappear();
    gate.resolve(method === 'hostDescribe' ? snapshot() : method === 'hostDefaultModel' ? modelDefault() :
      method === 'hostDefaultPermission' ? { revision: 5, writable: true } : [{ id: 'late', name: 'late' }]);
    await flush();
    assert.equal(h.page.snapshot.namespaces.length, 0);
    assert.equal(h.page.presets.length, 0); assert.equal(h.page.plugins.length, 0);
    assert.equal(h.page.permission.revision, -1); assert.equal(h.page.defaultModel.revision, -1);
    assert.equal(h.count('hostDescribe'), pageName === 'engine' ? 1 : 0, 'no second read after leaving');
  });
}

test('a host switch retires a load before it can start the second read on the new host', async () => {
  const gate = deferred(); const h = harness('presets', { hostPresets: () => gate.promise });
  await h.appear(); h.switchHost(); gate.resolve([{ id: 'old-host' }]); await flush();
  assert.equal(h.page.ready(), false); assert.equal(h.page.loading, false);
  assert.equal(h.page.presets.length, 0); assert.equal(h.count('hostDescribe'), 0);
  h.responses.hostPresets = () => [{ id: 'new-host' }];
  // Rebind only through explicit refresh, even though the transport stayed ready.
  await h.page.reload();
  assert.equal(h.page.ready(), true); assert.equal(h.page.presets[0].id, 'new-host');
  assert.equal(h.calls.at(-1).host, 'host-b');
});

test('the second preset read also checks its token before assigning either result', async () => {
  const gate = deferred(); const h = harness('presets', { hostDescribe: () => gate.promise });
  await h.appear(); assert.equal(h.count('hostDescribe'), 1);
  h.switchHost(); gate.resolve(snapshot()); await flush();
  assert.equal(h.page.snapshot.namespaces.length, 0); assert.equal(h.page.presets.length, 0);
});

test('connection epoch blocks stale writes even before StorageLink watchers run', async () => {
  const h = harness(); await h.appear();
  const ns = h.page.snapshot.namespaces[0], f = ns.fields[0];
  h.page.setDraft(ns.ns, f, '24'); h.switchHost('host-b', false);
  await h.page.save(ns, f); await h.page.setWebApi(true); await h.page.selectPreset('p');
  await h.page.readPreset('p'); await h.page.togglePlugin({ name: 'plugin' }, true);
  assert.equal(h.count('hostMutate'), 0); assert.equal(h.count('hostSelectPreset'), 0);
  assert.equal(h.count('hostReadPreset'), 0); assert.equal(h.count('hostSetBundleEnabled'), 0);
  assert.equal(h.page.ready(), false);
});

test('disconnect invalidates drafts; reconnect does not rebind until refresh, and old namespace handles cannot write', async () => {
  const h = harness(); await h.appear();
  const old = h.page.snapshot.namespaces[0], f = old.fields[0];
  h.page.setDraft(old.ns, f, '99'); h.disconnect();
  assert.equal(h.page.drafts.size, 0); assert.equal(h.page.bindingValid, false);
  h.publish('connectionState', 'ready'); await h.page.save(old, f);
  assert.equal(h.count('hostMutate'), 0);
  await h.page.reload(); await h.page.save(old, f);
  h.page.setDraft(old.ns, f, 'old input callback');
  assert.equal(h.page.drafts.size, 0, 'a retired input callback cannot inject its draft into the new host');
  assert.equal(h.count('hostMutate'), 0, 'old-host revision must never be sent after rebinding');
  const current = h.page.snapshot.namespaces[0]; await h.page.save(current, current.fields[0], '18');
  assert.equal(h.count('hostMutate'), 1);
  assert.equal(h.calls.find(c => c.method === 'hostMutate').epoch, 11);
});

test('numeric drafts show original zero/number, edited values save as JSON numbers and confirmed values are reread', async () => {
  const f = field('number', '0'), ns = namespace([f]);
  let describeCount = 0;
  const h = harness('engine', { hostDescribe: () => ++describeCount === 1 ? snapshot([ns]) : snapshot([namespace([field('number', '25')], ns.ns, 8)]) });
  await h.appear();
  assert.equal(h.page.draft(ns.ns, f, h.page.draftRevision), '0');
  assert.equal(h.page.draft(ns.ns, field('number', '-1.5'), h.page.draftRevision), '-1.5');
  const before = h.page.draftRevision; h.page.setDraft(ns.ns, f, '25');
  assert.ok(h.page.draftRevision > before); assert.equal(h.page.draft(ns.ns, f, h.page.draftRevision), '25');
  await h.page.save(ns, f);
  const write = h.calls.find(c => c.method === 'hostMutate');
  assert.equal(write.args[1][0].valueJson, '25'); assert.equal(write.args[2], 7);
  assert.equal(h.page.drafts.size, 0); assert.equal(h.count('hostDescribe'), 2);
  assert.equal(h.page.snapshot.namespaces[0].revision, 8);
  assert.match(source, /TextInput\(\{ text: this\.draft\(ns\.ns, field, this\.draftRevision\)/,
    'the actual TextInput expression must depend on draftRevision');
});

test('empty, nonfinite and out-of-range numeric drafts never dispatch a mutation', async () => {
  const f = Object.assign(field(), { min: 1, max: 20 }), ns = namespace([f]);
  const h = harness('engine', { hostDescribe: () => snapshot([ns]) }); await h.appear();
  for (const raw of ['', '  ', 'NaN', 'Infinity', '0', '21']) {
    await h.page.save(ns, f, raw); assert.match(h.page.errorText, /INVALID_NUMBER/);
  }
  assert.equal(h.count('hostMutate'), 0);
});

test('string enums preserve JSON strings while lossy numeric/boolean/object enum DTOs are explicitly rejected', async () => {
  for (const [original, options, allowed] of [
    ['"old"', ['old', 'new"value'], true], ['1', ['1', '2'], false],
    ['true', ['true', 'false'], false], ['{"x":1}', ['{"x":1}', '{"x":2}'], false],
    ['null', ['null', 'value'], false], ['"auto"', ['auto', '2'], false],
    ['"auto"', ['auto', 'false'], false], ['"auto"', ['auto', '{"x":2}'], false]
  ]) {
    const f = Object.assign(field('enum', original), { choices: options }); const ns = namespace([f]);
    const h = harness('engine', { hostDescribe: () => snapshot([ns]) }); await h.appear();
    await h.page.setEnum(ns, f, 1);
    if (allowed) assert.equal(h.calls.find(c => c.method === 'hostMutate').args[1][0].valueJson, JSON.stringify(options[1]));
    else { assert.equal(h.count('hostMutate'), 0); assert.match(h.page.errorText, /ENUM_TYPE_UNAVAILABLE/); }
  }
});

test('missing or invalid preset registry revision does not fabricate zero or dispatch a write', async () => {
  for (const registry of [undefined, { ns: 'agent-preset-registry', writable: true },
    namespace([], 'agent-preset-registry', -1), namespace([], 'agent-preset-registry', NaN)]) {
    const h = harness('presets', { hostDescribe: () => snapshot(registry ? [registry] : []) }); await h.appear();
    await h.page.selectPreset('preset-a');
    assert.equal(h.count('hostSelectPreset'), 0); assert.match(h.page.errorText, /PRESET_REVISION_UNAVAILABLE/);
  }
  const h = harness('presets', { hostDescribe: () => snapshot([namespace([], 'agent-preset-registry', 12)]) });
  await h.appear(); await h.page.selectPreset('preset-a');
  assert.equal(h.calls.find(c => c.method === 'hostSelectPreset').args[1], 12);
});

test('saveRemember serializes writes and an old completion cannot reload or clear new-host busy state', async () => {
  const gate = deferred(); const h = harness('models', { hostMutate: () => gate.promise }); await h.appear();
  const pending = h.page.saveRemember(false); await flush();
  assert.equal(h.page.busy, 'remember-model'); await h.page.saveRemember(true); await h.page.saveModel();
  assert.equal(h.count('hostMutate'), 1); assert.equal(h.count('hostSetDefaultModel'), 0);
  const op = h.calls.find(c => c.method === 'hostMutate');
  assert.equal(op.args[1][0].valueJson, 'false'); assert.equal(op.args[2], 9);
  h.switchHost(); await h.page.reload(); h.page.busy = 'new-host-operation';
  gate.resolve(namespace()); await pending;
  assert.equal(h.count('hostDefaultModel'), 2); assert.equal(h.page.busy, 'new-host-operation');
});

test('saveRemember reports unknown delivery neutrally and respects writable/support flags', async () => {
  const h = harness('models', { hostMutate: () => { throw new Error('RPC_TIMEOUT'); } }); await h.appear();
  await h.page.saveRemember(false);
  assert.match(h.page.errorText, /结果未确认.*RPC_TIMEOUT/); assert.doesNotMatch(h.page.errorText, /已保留主机值/);
  assert.equal(h.page.busy, '');
  h.page.defaultModel.writable = false; await h.page.saveRemember(false);
  h.page.defaultModel.writable = true; h.page.defaultModel.rememberLastSelectionSupported = false;
  await h.page.saveRemember(false); assert.equal(h.count('hostMutate'), 1);
});

test('a late preset document cannot overwrite a refreshed host document', async () => {
  const gate = deferred(); const h = harness('presets', { hostReadPreset: () => gate.promise }); await h.appear();
  const pending = h.page.readPreset('old'); await flush(); h.switchHost(); await h.page.reload();
  const currentDocument = h.page.presetDocument;
  gate.resolve({ id: 'old', content: 'wrong-host' }); await pending;
  assert.equal(h.page.presetDocument, currentDocument); assert.equal(h.page.presetExpanded, '');
});

test('permission approval is bound before the dialog await, and obsolete dialog buttons cannot approve a new operation', async () => {
  const h = harness('permission'); await h.appear();
  const old = h.page.choosePermission('danger-full-access'); await flush();
  assert.equal(h.page.busy, 'permission'); h.switchHost(); await old;
  assert.equal(h.count('hostSetDefaultPermission'), 0);
  await h.page.reload(); const pending = h.page.choosePermission('danger-full-access'); await flush();
  h.dialogs[0].secondaryButton.action(); await flush();
  assert.equal(h.count('hostSetDefaultPermission'), 0, 'old dialog must not resolve the current dialog');
  h.dialogs[1].secondaryButton.action(); await pending;
  const write = h.calls.find(c => c.method === 'hostSetDefaultPermission');
  assert.equal(write.host, 'host-b'); assert.equal(write.args[0], 'danger-full-access'); assert.equal(write.args[1], 5);
});

test('current-session permission editing is removed from this page; default-model editor precedes the long catalog', () => {
  const h = harness('permission');
  assert.equal(h.page.chooseCurrentPermission, undefined);
  assert.doesNotMatch(source, /selectPermission\(|@Builder card\(|nativeHostSettings,|listCacheCount/);
  assert.ok(source.indexOf("this.sectionTitle('新对话默认模型')") < source.indexOf("this.sectionTitle('主机模型目录')"));
});
