const test = require('node:test');
const assert = require('node:assert/strict');
const { createLoader, deferred, flush } = require('./ets-loader.cjs');

// Synthetic HarmonyOS seams exercise the unchanged NativeLocalSettings.ets logic.
// They are not Android/device capability mocks and do not establish ArkTS compilation,
// real notification delivery, ShareKit availability or clipboard behavior on a phone.
function harness() {
  const storage = new Map();
  const storageReads = [];
  const localDisk = new Map();
  const uiDisk = new Map();
  const writes = [];
  const preferenceReads = [];
  const published = [];
  const clipboard = [];
  const calls = { request: 0, open: 0, addSlot: 0 };
  const controls = {
    systemEnabled: true,
    slotEnabled: true,
    slotMissing: false,
    slotGate: undefined,
    failStatus: false,
    failOpen: false,
    denyRequest: false,
    publishError: undefined,
    failFlush: false,
    failClipboard: false,
    bundleName: 'ccchimneyyy.dsh.go',
    versionName: '1.2.3',
    versionCode: 42,
    initializationGate: undefined,
    failInitialize: false
  };

  function preferenceFile(name) {
    const disk = name === 'native-local-settings' ? localDisk : uiDisk;
    const pending = new Map();
    return {
      async get(key, fallback) {
        preferenceReads.push({ store: name, key });
        if (pending.has(key)) return pending.get(key);
        return disk.has(key) ? disk.get(key) : fallback;
      },
      async put(key, value) {
        if (name !== 'native-local-settings') throw new Error('UI metadata is read-only in this module');
        writes.push({ key, value });
        pending.set(key, value);
      },
      async flush() {
        if (controls.failFlush) throw new Error('synthetic flush failure');
        for (const [key, value] of pending) disk.set(key, value);
        pending.clear();
      }
    };
  }
  const preferences = {
    async getPreferences(_context, options) {
      if (options.name === 'native-local-settings') {
        if (controls.initializationGate) await controls.initializationGate;
        if (controls.failInitialize) throw new Error('synthetic initialization failure');
      }
      return preferenceFile(options.name);
    }
  };
  const notificationManager = {
    SlotType: { SERVICE_INFORMATION: 'service' },
    SlotLevel: { LEVEL_NONE: 0 },
    ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 'basic' },
    async isNotificationEnabled() {
      if (controls.failStatus) throw new Error('synthetic status failure');
      return controls.systemEnabled;
    },
    async getSlot() {
      if (controls.slotGate) await controls.slotGate;
      if (controls.failStatus) throw new Error('synthetic slot failure');
      if (controls.slotMissing) return null;
      return { enabled: controls.slotEnabled, notificationLevel: controls.slotEnabled ? 1 : 0 };
    },
    async addSlot() { calls.addSlot++; controls.slotMissing = false; },
    async requestEnableNotification(_context) {
      calls.request++;
      if (controls.denyRequest) throw Object.assign(new Error('synthetic refusal'), { code: 1600004 });
      controls.systemEnabled = true;
      controls.slotEnabled = true;
    },
    async openNotificationSettingsWithResult(_context) {
      calls.open++;
      if (controls.failOpen) throw new Error('synthetic settings failure');
    },
    async publish(request) {
      published.push(request);
      if (controls.publishError) throw controls.publishError;
    }
  };
  const bundleManager = {
    BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0 },
    async getBundleInfoForSelf() {
      return { name: controls.bundleName, versionName: controls.versionName, versionCode: controls.versionCode };
    }
  };
  const pasteboard = {
    MIMETYPE_TEXT_PLAIN: 'text/plain',
    createData: (mime, value) => ({ mime, value }),
    getSystemPasteboard: () => ({
      async setData(data) {
        if (controls.failClipboard) throw new Error('synthetic clipboard failure');
        clipboard.push(data);
      }
    })
  };
  const load = createLoader({
    '@ohos.data.preferences': { default: preferences },
    '@ohos.notificationManager': { default: notificationManager },
    '@ohos.bundle.bundleManager': { default: bundleManager },
    '@kit.BasicServicesKit': { pasteboard }
  }, {
    AppStorage: {
      get: key => { storageReads.push(key); return storage.get(key); },
      setOrCreate: (key, value) => { storage.set(key, value); return true; }
    }
  });
  const module = load('state/NativeLocalSettings');
  const store = module.nativeLocalSettings;
  const context = { synthetic: 'UIAbilityContext seam' };
  return {
    module, store, context, storage, storageReads, localDisk, uiDisk, writes, preferenceReads,
    published, clipboard, calls, controls,
    initialize: () => store.initialize(context)
  };
}

test('preference defaults, durable writes and real AppStorage performance contract', async () => {
  const h = harness();
  h.localDisk.set('failed', 'false');
  h.localDisk.set('listCacheCount', '99'); // Invalid persisted values fall back instead of reaching ArkUI.
  assert.equal(h.store.getPreference('enabled'), 'true');
  assert.equal(h.store.getPreference('done'), 'true');
  assert.equal(h.store.getPreference('failed'), 'true');
  assert.equal(h.store.getPreference('approval'), 'true');
  assert.equal(h.store.getPreference('question'), 'true');
  assert.equal(h.store.getPreference('unknown', 'fallback'), 'fallback');
  await h.initialize();
  assert.equal(h.store.getPreference('failed'), 'false');
  assert.equal(h.store.getPreference('listCacheCount'), '3');
  assert.equal(h.storage.get('blurEnabled'), true);
  assert.equal(h.storage.get('animationsEnabled'), true);
  assert.equal(h.storage.get('listCacheCount'), 3);
  assert.equal(h.storage.get('nativeVersionName'), '1.2.3');
  assert.equal(h.storage.get('nativeBuild'), '42');

  await h.store.setPreference('enabled', 'false');
  await h.store.setPreference('blurEnabled', 'false');
  await h.store.setPreference('animationsEnabled', 'false');
  await h.store.setPreference('listCacheCount', '0');
  assert.equal(h.localDisk.get('enabled'), 'false');
  assert.equal(h.localDisk.get('blurEnabled'), 'false');
  assert.equal(h.localDisk.get('animationsEnabled'), 'false');
  assert.equal(h.localDisk.get('listCacheCount'), '0');
  assert.equal(h.storage.get('blurEnabled'), false);
  assert.equal(h.storage.get('animationsEnabled'), false);
  assert.equal(h.storage.get('listCacheCount'), 0);
  assert.equal(h.storage.get('nativeSettingsRevision'), 4);

  for (const [key, value] of [['token', 'synthetic-secret'], ['enabled', 'yes'], ['listCacheCount', '60fps']]) {
    await assert.rejects(h.store.setPreference(key, value), /INVALID_PREFERENCE/);
  }
  assert.ok(!JSON.stringify(h.writes).includes('synthetic-secret'));
});

test('failed preference flush neither publishes nor commits the new value', async () => {
  const h = harness();
  await h.initialize();
  h.controls.failFlush = true;
  await assert.rejects(h.store.setPreference('blurEnabled', 'false'), /PREFERENCE_SAVE_FAILED/);
  assert.equal(h.store.getPreference('blurEnabled'), 'true');
  assert.equal(h.storage.get('blurEnabled'), true);
  assert.equal(h.localDisk.has('blurEnabled'), false);
  assert.equal(h.storage.get('nativeSettingsRevision'), 0);
  h.controls.failFlush = false;
  await h.store.setPreference('animationsEnabled', 'false');
  assert.equal(h.localDisk.get('blurEnabled'), 'true', 'an unrelated later flush must not commit the failed choice');
  assert.equal(h.storage.get('blurEnabled'), true);
  await h.store.setPreference('blurEnabled', 'false');
  assert.equal(h.localDisk.get('blurEnabled'), 'false');
  assert.equal(h.storage.get('blurEnabled'), false);
});

test('publish before initialization is false, while an in-flight read is awaited safely', async () => {
  const before = harness();
  assert.equal(await before.store.publish('done', 'Fixture', 'Too early'), false);
  assert.equal(before.store.lastPublishFailure, 'NOT_READY');
  assert.equal(before.published.length, 0);
  assert.equal(before.calls.request, 0);

  const h = harness();
  h.localDisk.set('enabled', 'false');
  const gate = deferred();
  h.controls.initializationGate = gate.promise;
  const initializing = h.initialize();
  const publishing = h.store.publish('done', 'Fixture', 'Waits for persisted opt-out');
  let settled = false;
  publishing.then(() => { settled = true; });
  await flush();
  assert.equal(settled, false, 'publish must not race ahead with optimistic defaults');
  assert.equal(h.published.length, 0);
  gate.resolve();
  await initializing;
  assert.equal(await publishing, false);
  assert.equal(h.published.length, 0, 'the persisted opt-out must win over constructor defaults');

  const failed = harness();
  failed.controls.failInitialize = true;
  await assert.rejects(failed.initialize(), /NATIVE_SETTINGS_INIT_FAILED/);
  assert.equal(await failed.store.publish('done', 'Fixture', 'No storage'), false);
  assert.equal(failed.published.length, 0);
});

test('notification filter defaults and per-kind switches gate actual publish calls', async () => {
  const h = harness();
  await h.initialize();
  const defaults = { enabled: true, done: true, failed: true, approval: true, question: true };
  for (const kind of ['done', 'failed', 'approval', 'question']) {
    assert.equal(h.module.notificationAllowed(kind, defaults), true);
  }
  assert.equal(h.module.notificationAllowed('done', { ...defaults, enabled: false }), false);
  assert.equal(h.module.notificationAllowed('done', { ...defaults, done: false }), false);
  assert.equal(h.module.notificationAllowed('failed', { ...defaults, failed: false }), false);
  assert.equal(h.module.notificationAllowed('approval', { ...defaults, approval: false }), false);
  assert.equal(h.module.notificationAllowed('question', { ...defaults, question: false }), false);
  assert.equal(h.module.notificationAllowed('unknown', defaults), false);

  assert.equal(await h.store.publish('done', 'Fixture', 'Finished'), true);
  assert.equal(h.published.length, 1);
  assert.equal(h.published[0].notificationSlotType, 'service');
  assert.equal(h.published[0].content.normal.text, 'Finished');
  assert.equal(h.calls.request, 0, 'publishing must never trigger the authorization prompt');

  await h.store.setPreference('enabled', 'false');
  assert.equal(await h.store.publish('done', 'Fixture', 'Filtered'), false);
  assert.equal(h.store.lastPublishFailure, 'PREFERENCE_DISABLED');
  await h.store.setPreference('enabled', 'true');
  await h.store.setPreference('done', 'false');
  assert.equal(await h.store.publish('done', 'Fixture', 'Filtered'), false);
  assert.equal(h.published.length, 1);
  await assert.rejects(h.store.publish('unknown', 'Fixture', 'No'), /INVALID_NOTIFICATION_KIND/);
});

test('system denial or a disabled slot returns false without fabricating publication', async () => {
  const h = harness();
  await h.initialize();
  h.controls.systemEnabled = false;
  assert.equal(await h.store.publish('done', 'Fixture', 'Blocked'), false);
  assert.equal(h.published.length, 0);
  assert.equal(h.calls.request, 0, 'a denied publish must not silently request permission');
  assert.equal(h.storage.get('nativeNotificationSystemKnown'), true);
  assert.equal(h.store.notificationSystemKnown, true);
  assert.equal(h.store.notificationSystemEnabled, false);
  assert.equal(h.store.lastPublishFailure, 'SYSTEM_DISABLED');

  h.controls.systemEnabled = true;
  h.controls.slotEnabled = false;
  assert.equal(await h.store.publish('approval', 'Fixture', 'Blocked'), false);
  assert.equal(h.published.length, 0);

  h.controls.slotEnabled = true;
  h.controls.publishError = Object.assign(new Error('synthetic publish refusal'), { code: 1600004 });
  assert.equal(await h.store.publish('approval', 'Fixture', 'Rejected by system'), false);
  assert.equal(h.published.length, 1, 'the API was attempted, but its rejection is not success');
  h.controls.publishError = new Error('synthetic publish outage');
  await assert.rejects(h.store.publish('approval', 'Fixture', 'Outage'), /NOTIFICATION_PUBLISH_FAILED/);
});

test('missing notification slots are created and a stuck status query fails within its deadline', { timeout: 12000 }, async () => {
  const h = harness(); await h.initialize(); h.controls.slotMissing = true;
  assert.equal(await h.store.refreshNotifications(), true);
  assert.equal(h.calls.addSlot, 1);
  h.controls.slotGate = new Promise(() => {});
  await assert.rejects(h.store.refreshNotifications(), /NOTIFICATION_STATUS_FAILED/);
  assert.equal(h.store.notificationSystemKnown, false);
});

test('permission request is explicit, refusal is false, and settings navigation is real API success only', async () => {
  const h = harness();
  h.controls.systemEnabled = false;
  h.controls.slotEnabled = false;
  await h.initialize();
  assert.equal(h.calls.request, 0, 'initialization cannot show a permission prompt');
  h.controls.denyRequest = true;
  assert.equal(await h.store.requestNotifications(), false);
  assert.equal(h.calls.request, 1);
  assert.equal(h.storage.get('nativeNotificationSystemEnabled'), false);

  h.controls.denyRequest = false;
  assert.equal(await h.store.requestNotifications(), true);
  assert.equal(h.calls.request, 2);
  assert.equal(h.storage.get('nativeNotificationSystemEnabled'), true);
  assert.equal(await h.store.openNotificationSettings(), true);
  assert.equal(h.calls.open, 1);

  h.controls.failOpen = true;
  await assert.rejects(h.store.openNotificationSettings(), /NOTIFICATION_SETTINGS_FAILED/);
  h.controls.failStatus = true;
  await assert.rejects(h.store.refreshNotifications(), /NOTIFICATION_STATUS_FAILED/);
  assert.equal(h.storage.get('nativeNotificationSystemKnown'), false);
  assert.equal(h.store.lastPublishFailure, 'STATUS_FAILED');
});

test('safe diagnostics has a fixed field allowlist, reads only three UI preferences and strips URL credentials', async () => {
  const h = harness();
  h.uiDisk.set('theme', '2');
  h.uiDisk.set('font', '3');
  h.uiDisk.set('fold', 'false');
  h.uiDisk.set('endpoints', 'synthetic-endpoint-must-not-be-read');
  await h.initialize();
  h.storage.set('connectionState', 'ready');
  h.storage.set('connectionError', 'synthetic safe connection error');
  h.storage.set('activeHostName', 'Fixture host');
  h.storage.set('activeHostAddress', 'https://example.invalid:8443/a/path?token=synthetic-secret-token#synthetic-fragment');
  h.storage.set('activeHostId', 'synthetic-host-id');
  h.storage.set('cookie', 'synthetic-secret-cookie');
  h.storage.set('token', 'synthetic-secret-token');
  h.storage.set('apiKey', 'synthetic-secret-api-key');
  h.storage.set('profile', 'synthetic-profile');
  h.storage.set('messages', ['synthetic-message']);

  const json = await h.store.diagnosticsJson();
  const report = JSON.parse(json);
  assert.deepEqual(Object.keys(report).sort(), [
    'activeHostAddress', 'activeHostName', 'app', 'connectionError', 'connectionState',
    'fold', 'font', 'notifications', 'theme'
  ]);
  assert.deepEqual(report.app, { version: '1.2.3', build: '42' });
  assert.equal(report.activeHostAddress, 'https://example.invalid:8443');
  assert.equal(report.theme, '2');
  assert.equal(report.font, '3');
  assert.equal(report.fold, 'false');
  assert.deepEqual(report.notifications, { enabled: true, done: true, failed: true, approval: true, question: true });
  for (const secret of ['synthetic-secret-token', 'synthetic-fragment', 'synthetic-secret-cookie',
    'synthetic-secret-api-key', 'synthetic-profile', 'synthetic-message', 'synthetic-host-id',
    'synthetic-endpoint-must-not-be-read']) {
    assert.ok(!json.includes(secret), 'diagnostics leaked ' + secret);
  }
  assert.deepEqual(h.preferenceReads.filter(row => row.store === 'native-host-metadata').map(row => row.key).sort(),
    ['fold', 'font', 'theme']);
  const forbiddenStorageReads = h.storageReads.filter(key => ['activeHostId', 'cookie', 'token', 'apiKey', 'profile', 'messages'].includes(key));
  assert.deepEqual(forbiddenStorageReads, []);

  assert.equal(h.module.safeDiagnosticOrigin('http://user:password@example.invalid/?token=secret'), '');
  assert.equal(h.module.safeDiagnosticOrigin('ftp://example.invalid/path'), '');
  assert.equal(h.module.safeDiagnosticOrigin('https://example.invalid/path?token=secret'), 'https://example.invalid');
  assert.equal(await h.store.copyDiagnostics(), true);
  assert.equal(h.clipboard.length, 1);
  assert.equal(h.clipboard[0].mime, 'text/plain');
  assert.deepEqual(Object.keys(JSON.parse(h.clipboard[0].value)).sort(), Object.keys(report).sort());
  assert.equal(h.storage.get('nativeDiagnosticAction'), 'copied');

  assert.equal(await h.store.shareDiagnostics(), true, 'true here means the explicit copy fallback completed');
  assert.equal(h.clipboard.length, 2);
  assert.equal(h.storage.get('nativeDiagnosticAction'), 'copied-for-sharing');
});

test('clipboard failures are failures for both copy and the labeled share fallback', async () => {
  const h = harness();
  await h.initialize();
  h.controls.failClipboard = true;
  await assert.rejects(h.store.copyDiagnostics(), /CLIPBOARD_WRITE_FAILED/);
  await assert.rejects(h.store.shareDiagnostics(), /CLIPBOARD_WRITE_FAILED/);
  assert.equal(h.clipboard.length, 0);
  assert.equal(h.storage.get('nativeDiagnosticAction'), 'copy-failed');
});

test('version facts come from the known bundle and are never invented on mismatch', async () => {
  const h = harness();
  h.controls.bundleName = 'different.invalid.bundle';
  h.controls.versionName = '999.0.0-should-not-be-used';
  await h.initialize();
  const report = JSON.parse(await h.store.diagnosticsJson());
  assert.deepEqual(report.app, { version: 'unavailable', build: 'unavailable' });
  assert.equal(h.storage.get('nativeVersionName'), 'unavailable');
});
