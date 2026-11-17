const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createLoader } = require('./ets-loader.cjs');

const fixturePath = path.resolve(__dirname, '../../../packages/dsh_client/test/fixtures/settings_describe.json');
const recorded = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
const clone = value => JSON.parse(JSON.stringify(value));
const load = createLoader({
  '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(value) { return new Uint8Array(Buffer.from(value, 'utf8')); } } } }
});
const api = load('state/NativeHostSettings');

function wire(routes) {
  const calls = [];
  const rpc = async (endpoint, argsJson) => {
    const args = JSON.parse(argsJson);
    calls.push({ endpoint, args });
    const handler = routes[endpoint];
    if (!handler) throw new Error('METHOD_NOT_ALLOWED');
    const result = typeof handler === 'function' ? await handler(args, calls.length) : handler;
    if (result instanceof Error) throw result;
    return JSON.stringify(result === undefined ? null : result);
  };
  return { rpc, calls };
}
function namespace(recordedDescribe, ns) {
  return clone(recordedDescribe.namespaces.find(row => row.ns === ns));
}
function field(view, path) {
  return view.fields.find(row => JSON.stringify(row.path) === JSON.stringify(path));
}
function op(kind, path, value) {
  const result = { op: kind, path };
  if (kind === 'set') result.valueJson = JSON.stringify(value);
  return result;
}

test('recorded describe preserves every served namespace and extracts real primitive/enum/complex fields', async () => {
  const h = wire({ 'settings/describe': recorded });
  const snapshot = await api.describe(h.rpc);
  assert.equal(snapshot.writable, true);
  assert.equal(snapshot.namespaces.length, recorded.namespaces.length);
  assert.deepEqual(h.calls, [{ endpoint: 'settings/describe', args: {} }]);

  const subagent = snapshot.namespaces.find(row => row.ns === 'subagent');
  const depth = field(subagent, ['maxDepth']);
  assert.equal(depth.kind, 'number');
  assert.equal(depth.valueJson, '1');
  assert.equal(depth.min, 0);
  assert.equal(depth.disabled, false);
  assert.equal(field(subagent, ['maxActiveSubagents']).valueJson, '8');

  const chat = snapshot.namespaces.find(row => row.ns === 'ui-chat');
  const transcript = field(chat, ['transcriptView']);
  assert.equal(transcript.kind, 'enum');
  assert.deepEqual([...transcript.choices], ['compact', 'standard', 'detailed', 'verbose', 'normal', 'expanded']);
  assert.equal(transcript.choiceLabels.length, transcript.choices.length);
  assert.equal(field(chat, ['collapseTiming']).kind, 'enum');

  const log = snapshot.namespaces.find(row => row.ns === 'session-log-deepseek');
  assert.equal(field(log, ['enabled']).kind, 'boolean');
  assert.equal(field(log, ['enabled']).valueJson, 'true');

  const llm = snapshot.namespaces.find(row => row.ns === 'llm-deepseek');
  assert.equal(field(llm, ['retryPolicy']).kind, 'readonly');
  assert.equal(field(llm, ['retryPolicy']).disabled, true);
});

test('describe is Host-driven and never invents a fixed namespace', async () => {
  const only = { writable: false, namespaces: [namespace(recorded, 'subagent')] };
  const h = wire({ 'settings/describe': only });
  const snapshot = await api.describe(h.rpc);
  assert.equal(snapshot.namespaces.length, 1);
  assert.equal(snapshot.namespaces[0].ns, 'subagent');
  assert.equal(snapshot.writable, false);
  assert(snapshot.namespaces[0].fields.every(row => row.disabled));
});

test('secret and credential-ref values are redacted from fields and all three namespace layers', async () => {
  const input = clone(recorded);
  const search = input.namespaces.find(row => row.ns === 'web-search-deepseek');
  for (const layer of [search.value, search.base, search.user]) {
    layer.apiKey = 'DO_NOT_LEAK_API_KEY';
  }
  search.secrets[0].set = true;
  const h = wire({ 'settings/describe': input });
  const snapshot = await api.describe(h.rpc);
  const view = snapshot.namespaces.find(row => row.ns === 'web-search-deepseek');
  const secret = field(view, ['apiKey']);
  assert.equal(secret.kind, 'secret');
  assert.equal(secret.secret, true);
  assert.equal(secret.configured, true);
  assert.equal(secret.disabled, true);
  assert.equal(secret.valueJson, 'null');
  assert.equal(field(view, ['apiKeyEnv']).secret, true);
  assert.equal(field(view, ['apiKeyEnv']).valueJson, 'null');
  for (const encoded of [view.valueJson, view.baseJson, view.userJson]) {
    assert(!encoded.includes('DO_NOT_LEAK_API_KEY'));
    assert(!encoded.includes('DEEPSEEK_API_KEY'), 'credential reference is plumbing, not an editable text value');
  }
  assert(!JSON.stringify(view).includes('DO_NOT_LEAK_API_KEY'));
});

test('secrets[] still redacts nested values when the Host schema is missing or damaged', async () => {
  const ns = {
    ns: 'damaged', schema: {}, revision: 0,
    value: { credentials: { apiKey: 'DO_NOT_LEAK_NESTED' }, visible: true },
    base: { credentials: { apiKey: 'DO_NOT_LEAK_NESTED' } },
    user: {},
    secrets: [{ path: ['credentials', 'apiKey'], set: true }]
  };
  const h = wire({ 'settings/describe': { writable: true, namespaces: [ns] } });
  const view = (await api.describe(h.rpc)).namespaces[0];
  assert.deepEqual(JSON.parse(view.valueJson), { credentials: {}, visible: true });
  assert.deepEqual(JSON.parse(view.baseJson), { credentials: {} });
  assert(!JSON.stringify(view).includes('DO_NOT_LEAK_NESTED'));
});

test('field extraction is bounded to 64 fields and four path segments', async () => {
  const dict = {};
  const value = {};
  for (let index = 0; index < 70; index++) { dict['f' + index] = { type: 'boolean' }; value['f' + index] = true; }
  dict.nested = { type: 'object', dict: { level2: { type: 'object', dict: { level3: { type: 'object', dict: {
    level4: { type: 'object', dict: { tooDeep: { type: 'string' } } }
  } } } } } };
  value.nested = { level2: { level3: { level4: { tooDeep: 'not served' } } } };
  const ns = { ns: 'bounded', schema: { type: 'object', dict }, value, base: value, user: {}, secrets: [], revision: 0 };
  const h = wire({ 'settings/describe': { writable: true, namespaces: [ns] } });
  const view = (await api.describe(h.rpc)).namespaces[0];
  assert.equal(view.fields.length, 64);
  assert(view.fields.every(row => row.path.length <= 4));
  assert(!JSON.stringify(view.fields).includes('not served'));
});

test('mutate sends atomic multi-ops and exact revision once, with no read or replay', async () => {
  const updated = namespace(recorded, 'subagent');
  updated.revision = 4;
  updated.value.maxDepth = 3;
  updated.user = { maxDepth: 3 };
  const h = wire({ 'settings/mutate': updated });
  const result = await api.mutate(h.rpc, 'subagent', [op('set', ['maxDepth'], 3), op('unset', ['maxActiveSubagents'])], 3);
  assert.equal(h.calls.length, 1);
  assert.deepEqual(h.calls[0], { endpoint: 'settings/mutate', args: {
    ns: 'subagent', expectedRevision: 3,
    ops: [{ op: 'set', path: ['maxDepth'], value: 3 }, { op: 'unset', path: ['maxActiveSubagents'] }]
  } });
  assert.equal(result.revision, 4);
  assert.equal(field(result, ['maxDepth']).valueJson, '3');
});

test('mutate validates bounds before RPC and preserves only bounded business codes without replay', async () => {
  let attempts = 0;
  const h = wire({ 'settings/mutate': () => { attempts++; return new Error('settings/conflict'); } });
  await assert.rejects(api.mutate(h.rpc, 'subagent', [op('set', ['maxDepth'], 4)], 0), /settings\/conflict/);
  assert.equal(attempts, 1);
  assert.equal(h.calls.length, 1);

  const bad = wire({});
  await assert.rejects(api.mutate(bad.rpc, 'subagent', [op('set', ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i'], 1)]), /INVALID_OPERATION/);
  await assert.rejects(api.mutate(bad.rpc, 'subagent', Array.from({ length: 65 }, () => op('unset', ['x']))), /INVALID_OPS/);
  await assert.rejects(api.mutate(bad.rpc, 'subagent', [op('set', ['x'], 1)], -1), /INVALID_REVISION/);
  await assert.rejects(api.mutate(bad.rpc, 'subagent', [{ op: 'set', path: ['x'] }]), /INVALID_VALUE/);
  assert.equal(bad.calls.length, 0);

  const unsafe = wire({ 'settings/mutate': () => new Error('raw Host message with synthetic-secret') });
  await assert.rejects(api.mutate(unsafe.rpc, 'subagent', [op('unset', ['maxDepth'])]), error => {
    assert.equal(error.message, 'REMOTE_ERROR');
    assert(!error.message.includes('synthetic-secret'));
    return true;
  });
  assert.equal(unsafe.calls.length, 1);
});

test('agent presets list/read/default use real payloads and cap UTF-8 content at 256 KiB', async () => {
  const h = wire({
    'agentPresets/list': { presets: [{ id: 'standard', name: '标准', description: 'desc', isDefault: true }, { id: 'broken', broken: 'bad YAML' }] },
    'agentPresets/read': { agentPreset: 'standard', name: '标准', content: 'preset: true' },
    'settings/update': { applied: true }
  });
  const presets = await api.agentPresets(h.rpc);
  assert.deepEqual(Array.from(presets, row => row.id), ['standard', 'broken']);
  assert.equal(presets[0].isDefault, true);
  assert.equal(presets[1].broken, 'bad YAML');
  const document = await api.readAgentPreset(h.rpc, 'standard');
  assert.equal(document.id, 'standard');
  assert.equal(document.content, 'preset: true');
  const confirmation = await api.selectAgentPreset(h.rpc, 'standard', 7);
  assert.deepEqual(JSON.parse(confirmation), { applied: true });
  assert.deepEqual(h.calls.at(-1), { endpoint: 'settings/update', args: {
    ns: 'agent-preset-registry', patch: { selectedDefault: 'standard' }, expectedRevision: 7
  } });

  const large = wire({ 'agentPresets/read': { content: '🀄'.repeat(70000) } });
  await assert.rejects(api.readAgentPreset(large.rpc, 'standard'), /CONTENT_TOO_LARGE/);
});

test('plugin bundles keep localized descriptions and both enable APIs return unmodified confirmation JSON', async () => {
  const h = wire({
    'pluginManager/listBundles': [
      { name: '@example/bundle', enabled: true, description: 'fallback', meta: { description: { 'zh-CN': '插件包', en: 'bundle' } } },
      { name: 'plain', enabled: false, description: 'plain description' }
    ],
    'pluginManager/setBundleEnabled': { application: 'restart-required', changed: true },
    'pluginManager/setPluginEnabled': { application: 'applied', enabled: true }
  });
  const rows = await api.plugins(h.rpc);
  assert.deepEqual(Array.from(rows, row => [row.name, row.enabled, row.description]), [
    ['@example/bundle', true, '插件包'], ['plain', false, 'plain description']
  ]);
  assert.equal(await api.setBundleEnabled(h.rpc, '@example/bundle', false), JSON.stringify({ application: 'restart-required', changed: true }));
  assert.equal(await api.setPluginEnabled(h.rpc, 'include:demo', true), JSON.stringify({ application: 'applied', enabled: true }));
  assert.deepEqual(h.calls.at(-2), { endpoint: 'pluginManager/setBundleEnabled', args: { name: '@example/bundle', enabled: false } });
  assert.deepEqual(h.calls.at(-1), { endpoint: 'pluginManager/setPluginEnabled', args: { id: 'include:demo', enabled: true } });
});

test('defaultPermission combines catalog defaults with permission revision and rejects disallowed writes before mutate', async () => {
  const described = clone(recorded);
  const permission = described.namespaces.find(row => row.ns === 'permission');
  permission.value.defaultPreset = 'danger-full-access';
  permission.user.defaultPreset = 'danger-full-access';
  permission.revision = 9;
  const catalog = {
    defaultPreset: 'auto',
    options: [
      { value: 'auto', name: '自动审查' },
      { value: 'workspace-write', name: '工作区', description: '写入工作区' },
      { value: 'danger-full-access', name: '完全权限' }
    ],
    defaultOptions: [{ value: 'workspace-write' }, { value: 'danger-full-access' }]
  };
  const h = wire({ 'permissionPresets/catalog': catalog, 'settings/describe': described });
  const current = await api.defaultPermission(h.rpc);
  assert.equal(current.default, 'auto');
  assert.equal(current.current, 'danger-full-access');
  assert.equal(current.revision, 9);
  assert.equal(current.writable, true);
  assert.deepEqual(Array.from(current.options, row => [row.id, row.defaultAllowed]), [
    ['auto', false], ['workspace-write', true], ['danger-full-access', true]
  ]);

  const writer = wire({ 'permissionPresets/catalog': catalog, 'settings/mutate': permission });
  const saved = await api.setDefaultPermission(writer.rpc, 'workspace-write', 9);
  assert.equal(saved.ns, 'permission');
  assert.deepEqual(writer.calls.map(row => row.endpoint), ['permissionPresets/catalog', 'settings/mutate']);
  assert.deepEqual(writer.calls[1].args, { ns: 'permission', ops: [{ op: 'set', path: ['defaultPreset'], value: 'workspace-write' }], expectedRevision: 9 });

  // Even a catalog that erroneously includes session-only Auto must not persist it.
  const autoCatalog = clone(catalog);
  autoCatalog.defaultOptions.unshift({ value: 'auto' });
  const denied = wire({ 'permissionPresets/catalog': autoCatalog });
  await assert.rejects(api.setDefaultPermission(denied.rpc, 'auto', 9), /PERMISSION_NOT_ALLOWED/);
  assert.equal(denied.calls.length, 1);
  assert.equal(denied.calls[0].endpoint, 'permissionPresets/catalog');
});

test('defaultModel detects optional remember support and writes provider/model/effort atomically', async () => {
  const model = {
    ns: 'agent-default-model', revision: 5,
    schema: { type: 'object', dict: {
      provider: { type: 'string' }, model: { type: 'string' }, reasoningEffort: { type: 'string' },
      rememberLastSelection: { type: 'boolean' }
    } },
    value: { provider: 'deepseek-official', model: 'deepseek-flash', reasoningEffort: 'high', rememberLastSelection: false },
    base: {}, user: {}, secrets: []
  };
  const h = wire({ 'settings/describe': { writable: true, namespaces: [model] } });
  const current = await api.defaultModel(h.rpc);
  assert.equal(current.provider, 'deepseek-official');
  assert.equal(current.model, 'deepseek-flash');
  assert.equal(current.reasoningEffort, 'high');
  assert.equal(current.rememberLastSelection, false);
  assert.equal(current.rememberLastSelectionSupported, true);
  assert.equal(current.revision, 5);

  const old = clone(model); delete old.schema.dict.rememberLastSelection; delete old.value.rememberLastSelection;
  const oldReader = wire({ 'settings/describe': { writable: true, namespaces: [old] } });
  const oldInfo = await api.defaultModel(oldReader.rpc);
  assert.equal(oldInfo.rememberLastSelectionSupported, false);
  assert.equal(oldInfo.rememberLastSelection, true);

  const writer = wire({ 'settings/mutate': model });
  await api.setDefaultModel(writer.rpc, 'custom-route', 'model-x', '', true, 5);
  assert.deepEqual(writer.calls[0].args, {
    ns: 'agent-default-model', expectedRevision: 5,
    ops: [
      { op: 'set', path: ['provider'], value: 'custom-route' },
      { op: 'set', path: ['model'], value: 'model-x' },
      { op: 'unset', path: ['reasoningEffort'] },
      { op: 'set', path: ['rememberLastSelection'], value: true }
    ]
  });

  const noRemember = wire({ 'settings/mutate': model });
  await api.setDefaultModel(noRemember.rpc, 'p', 'm', 'max');
  assert.deepEqual(noRemember.calls[0].args.ops, [
    { op: 'set', path: ['provider'], value: 'p' },
    { op: 'set', path: ['model'], value: 'm' },
    { op: 'set', path: ['reasoningEffort'], value: 'max' }
  ]);
  assert(!Object.hasOwn(noRemember.calls[0].args, 'expectedRevision'));
});

test('missing defaultModel/defaultPermission namespaces are explicit, and singleton exposes the same API', async () => {
  const h = wire({
    'settings/describe': { writable: true, namespaces: [] },
    'permissionPresets/catalog': { defaultPreset: 'auto', options: [{ value: 'auto' }] }
  });
  const model = await api.defaultModel(h.rpc);
  assert.equal(model.provider, '');
  assert.equal(model.revision, -1);
  assert.equal(model.writable, false);
  const permission = await api.defaultPermission(h.rpc);
  assert.equal(permission.current, 'auto');
  assert.equal(permission.default, 'auto');
  assert.equal(permission.revision, -1);
  assert.equal(permission.writable, false);
  assert.equal(permission.options[0].defaultAllowed, false, 'catalog-only Auto is session-only by fallback');
  assert.equal(typeof api.nativeHostSettings.describe, 'function');
  assert.equal(api.nativeHostSettings.describe, api.describe);
  assert.equal(api.nativeHostSettings.setDefaultModel, api.setDefaultModel);
});
