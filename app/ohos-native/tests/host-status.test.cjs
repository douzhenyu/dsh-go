// Execute actual page controllers; exclude only ArkUI render syntax.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { sdkTypeScript } = require('./ets-loader.cjs');
const ts = require(sdkTypeScript);
const source = fs.readFileSync(path.resolve(__dirname, '../entry/src/main/ets/pages/HostTab.ets'), 'utf8');
function harness() {
  const storage = new Map(), paths = [], calls = [];
  const noDecorator = () => () => {};
  const imports = {
    '@kit.ArkUI': { LengthMetrics: { vp: value => value }, SegmentButtonOptions: { tab: value => value } },
    '../common/Style': { barMaterial: () => 0 },
    '../state/AppStore': { appStore: { selectHost: async id => calls.push(id), disconnect: () => calls.push('disconnect') } }
  };
  const globals = { exports: {}, require: id => imports[id] || {},
    Component: value => value, StorageLink: key => (proto, name) => Object.defineProperty(proto, name, {
      get() { return storage.get(key); }, set(value) { storage.set(key, value); }, configurable: true
    }), State: noDecorator(), Prop: noDecorator(), Link: noDecorator(),
    NavPathStack: class { pushPathByName(...args) { paths.push(args); } },
    AppStorage: { setOrCreate: (key, value) => storage.set(key, value), get: key => storage.get(key) },
    $r: name => name, barMaterial: () => 0 };
  // Keep the imports and pure functions, then each component's real controller.
  const firstComponent = source.indexOf('@Component');
  let controllers = source.slice(0, firstComponent);
  for (const match of source.matchAll(/@Component\s+(?:export )?struct (\w+)\s*\{/g)) {
    const start = match.index;
    const boundary = source.indexOf('@Builder', start);
    const build = source.indexOf('  build()', start);
    const end = boundary >= 0 && boundary < build ? boundary : build;
    if (end < 0) continue;
    controllers += source.slice(start, end).replace(/(?:export )?struct (\w+)/, 'export class $1') + '\n}\n';
  }
  const compiled = ts.transpileModule(controllers, { fileName: 'HostTab.ts', reportDiagnostics: true,
    compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS, experimentalDecorators: true, useDefineForClassFields: false } });
  assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
  vm.runInNewContext(compiled.outputText, globals);
  const page = new globals.exports.HostTab();
  return { page, storage, paths, calls, Row: globals.exports.HostCard };
}
const remote = { id: 'remote:device@https://relay.test', name: 'Fixture', kind: 'remote', address: 'https://relay.test', state: 'offline', route: 'relay', latency: '—' };
test('ready Remote appears in connected filter even with stale offline metadata', () => {
  const { page } = harness();
  page.hosts = [remote]; page.currentId = remote.id; page.connectionState = 'ready'; page.hostFilterIdx = [1];
  assert.deepEqual(Array.from(page.visibleHosts(), h => h.id), [remote.id]);
  page.hostFilterIdx = [2]; assert.equal(page.visibleHosts().length, 0);
});
test('clicking an already connected Remote opens conversations without authentication navigation', async () => {
  const { page, Row, paths, calls, storage } = harness();
  const row = new Row(); row.host = remote; row.onSelect = host => page.selectHost(host);
  page.currentId = remote.id; page.connectionState = 'ready';
  await row.open();
  assert.equal(storage.get('selectedTab'), 1);
  assert.equal(paths.length, 0); assert.equal(calls.length, 0);
});
test('disconnected Remote row preserves target device metadata for manager navigation', async () => {
  const { page, Row, paths, storage, calls } = harness();
  const row = new Row(); row.host = remote; row.onSelect = host => page.selectHost(host);
  page.currentId = remote.id; page.connectionState = 'disconnected';
  await row.open();
  assert.equal(storage.get('remoteTargetHostId'), 'device');
  assert.equal(storage.get('remoteServerUrl'), 'https://relay.test');
  assert.equal(paths[0][0], 'remote'); assert.equal(calls.length, 0);
});
test('same row observes live StorageLink status and data while metadata stays frozen', () => {
  const { Row, storage } = harness();
  assert.equal(typeof Row, 'function', 'test must execute the actual rendered row controller');
  const row = new Row(); row.host = Object.freeze({ ...remote });
  storage.set('activeHostId', remote.id); storage.set('connectionState', 'connecting');
  assert.equal(row.statusLabel(), '连接中');
  storage.set('connectionState', 'ready');
  storage.set('sessions', [{ id: 'a' }]); storage.set('workspaces', [{ id: 'w' }]);
  storage.set('modelLabels', ['Model A']); storage.set('permissionLabels', ['Read']);
  storage.set('hostLatency', '25 ms');
  assert.equal(row.statusLabel(), '已连接');
  assert.equal(row.statValue('对话'), '1'); assert.equal(row.statValue('工作区'), '1');
  assert.equal(row.statValue('延迟'), '25 ms');
  assert.equal(row.catalogValue('模型目录'), 'Model A');
  assert.equal(row.catalogValue('权限目录'), 'Read');
  storage.set('sessions', [{ id: 'a' }, { id: 'b' }]);
  storage.set('modelLabels', ['Model B']);
  assert.equal(row.statValue('对话'), '2'); assert.equal(row.catalogValue('模型目录'), 'Model B');
  storage.set('dataLoading', true); assert.equal(row.statValue('对话'), '读取中…');
  storage.set('connectionState', 'error'); assert.equal(row.statusLabel(), '连接失败');
  assert.equal(row.catalogValue('模型目录'), '连接后读取');
  storage.set('connectionState', 'disconnected'); assert.equal(row.statusLabel(), '未连接');
  assert.equal(row.statValue('对话'), '—');
});
test('switching active host cannot report a stale connected endpoint as ready or offline', () => {
  const { page, Row, storage } = harness();
  const stale = Object.freeze({ ...remote, state: 'connected' });
  const row = new Row(); row.host = stale;
  page.hosts = [stale]; page.hostFilterIdx = [1];
  storage.set('activeHostId', 'another-host'); storage.set('connectionState', 'ready');
  assert.equal(row.statusLabel(), '未连接'); assert.equal(page.visibleHosts().length, 0);
  page.hostFilterIdx = [2]; assert.equal(page.visibleHosts().length, 1);
  storage.set('activeHostId', remote.id); storage.set('connectionState', 'ready');
  page.hostFilterIdx = [1]; assert.equal(page.visibleHosts().length, 1);
  storage.set('connectionState', 'disconnected'); assert.equal(page.visibleHosts().length, 0);
});
