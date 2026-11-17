import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import notificationManager from '@ohos.notificationManager';
import bundleManager from '@ohos.bundle.bundleManager';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';

export const NATIVE_BUNDLE_NAME: string = 'ccchimneyyy.dsh.go';
const NOTIFICATION_REFUSED: number = 1600004;
const LOCAL_STORE: string = 'native-local-settings';
const UI_STORE: string = 'native-host-metadata';
const NOTIFICATION_KINDS: string[] = ['done', 'failed', 'approval', 'question'];
const BOOLEAN_KEYS: string[] = ['enabled', 'done', 'failed', 'approval', 'question', 'blurEnabled', 'animationsEnabled'];
const LOCAL_KEYS: string[] = ['enabled', 'done', 'failed', 'approval', 'question', 'blurEnabled', 'animationsEnabled', 'listCacheCount'];
const UI_KEYS: string[] = ['theme', 'font', 'fold'];

export interface LocalNotificationPreferences {
  enabled: boolean;
  done: boolean;
  failed: boolean;
  approval: boolean;
  question: boolean;
}

interface NativeAppVersion {
  version: string;
  build: string;
}

interface NativeDiagnostics {
  app: NativeAppVersion;
  connectionState: string;
  connectionError: string;
  activeHostName: string;
  activeHostAddress: string;
  theme: string;
  font: string;
  fold: string;
  notifications: LocalNotificationPreferences;
}

export function defaultLocalPreference(key: string): string {
  if (key === 'listCacheCount') return '3';
  if (key === 'theme') return '0';
  if (key === 'font') return '1';
  if (LOCAL_KEYS.indexOf(key) >= 0 || key === 'fold') return 'true';
  return '';
}

function validPreference(key: string, value: string): boolean {
  if (BOOLEAN_KEYS.indexOf(key) >= 0) return value === 'true' || value === 'false';
  if (key === 'listCacheCount') return value === '0' || value === '1' || value === '3';
  return false;
}

export function notificationAllowed(kind: string, prefs: LocalNotificationPreferences): boolean {
  if (!prefs.enabled) return false;
  if (kind === 'done') return prefs.done;
  if (kind === 'failed') return prefs.failed;
  if (kind === 'approval') return prefs.approval;
  if (kind === 'question') return prefs.question;
  return false;
}

// AppStore already persists login URLs without their query/fragment. This second boundary
// deliberately keeps only scheme/host/port so a malformed AppStorage value cannot leak one.
export function safeDiagnosticOrigin(value: string): string {
  const match = /^https?:\/\/(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+)(?::\d{1,5})?(?=$|\/)/.exec(value.trim());
  return match ? match[0] : '';
}

function diagnosticText(value: string | undefined, fallback: string = ''): string {
  if (typeof value !== 'string') return fallback;
  return value.length > 1000 ? value.substring(0, 1000) : value;
}

export function nativeSettingsErrorCode(error: Error, fallback: string = 'NATIVE_SETTINGS_ACTION_FAILED'): string {
  return /^[A-Z][A-Z0-9_]{2,63}$/.test(error.message) ? error.message : fallback;
}

class NativeLocalSettings {
  private context?: common.UIAbilityContext;
  private prefs?: preferences.Preferences;
  private prefCache: Map<string, string> = new Map<string, string>();
  private uiCache: Map<string, string> = new Map<string, string>();
  private initialized: boolean = false;
  private initializing?: Promise<void>;
  private notificationSequence: number = 0;
  private systemKnown: boolean = false;
  private systemEnabled: boolean = false;
  private publishFailure: string = '';
  private versionName: string = 'unavailable';
  private build: string = 'unavailable';

  constructor() {
    this.resetDefaults();
    AppStorage.setOrCreate('nativeVersionName', this.versionName);
    AppStorage.setOrCreate('nativeBuild', this.build);
    AppStorage.setOrCreate('nativeNotificationSystemEnabled', false);
    AppStorage.setOrCreate('nativeNotificationSystemKnown', false);
    AppStorage.setOrCreate('nativeSettingsRevision', 0);
    AppStorage.setOrCreate('nativeDiagnosticAction', '');
    AppStorage.setOrCreate('nativeNotificationFailure', '');
    this.applyPerformance();
  }

  private resetDefaults(): void {
    this.prefCache.clear();
    for (const key of LOCAL_KEYS) this.prefCache.set(key, defaultLocalPreference(key));
    this.uiCache.clear();
    for (const key of UI_KEYS) this.uiCache.set(key, defaultLocalPreference(key));
  }

  initialize(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    if (this.initialized) return Promise.resolve();
    if (this.initializing) return this.initializing;
    const pending = this.load(context);
    this.initializing = pending;
    return pending;
  }

  private async load(context: common.UIAbilityContext): Promise<void> {
    try {
      let initializationFailed: boolean = false;
      try {
        const store = await preferences.getPreferences(context, { name: LOCAL_STORE });
        const loaded: Map<string, string> = new Map<string, string>();
        for (const key of LOCAL_KEYS) {
          const fallback = defaultLocalPreference(key);
          const value = String(await store.get(key, fallback));
          loaded.set(key, validPreference(key, value) ? value : fallback);
        }
        this.prefCache = loaded;
        this.prefs = store;
        this.initialized = true;
      } catch (_) {
        this.prefs = undefined;
        this.initialized = false;
        this.resetDefaults();
        initializationFailed = true;
      }
      this.applyPerformance();
      // Read only the three public UI choices. In particular, never enumerate this store or
      // read its endpoints, and never open any DSH profile, cookie, token or API-key store.
      try {
        const ui = await preferences.getPreferences(context, { name: UI_STORE });
        for (const key of UI_KEYS) {
          const value = String(await ui.get(key, defaultLocalPreference(key)));
          this.uiCache.set(key, diagnosticText(value, defaultLocalPreference(key)));
        }
      } catch (_) {
        // Safe defaults remain useful when the other non-secret preference file is unavailable.
      }
      await this.readVersion();
      if (initializationFailed) throw new Error('NATIVE_SETTINGS_INIT_FAILED');
    } finally {
      this.initializing = undefined;
    }
  }

  getPreference(key: string, fallback: string = ''): string {
    const value = this.prefCache.get(key);
    return value === undefined ? fallback : value;
  }

  async setPreference(key: string, value: string): Promise<void> {
    if (LOCAL_KEYS.indexOf(key) < 0 || !validPreference(key, value)) throw new Error('INVALID_PREFERENCE');
    if (!this.initialized || !this.prefs) throw new Error('NATIVE_SETTINGS_NOT_READY');
    const previous = this.getPreference(key, defaultLocalPreference(key));
    try {
      await this.prefs.put(key, value);
      await this.prefs.flush();
    } catch (_) {
      // Preferences keeps a put in its memory even when flush rejects. Restore the last
      // published value so a later unrelated flush cannot silently persist this failure.
      try { await this.prefs.put(key, previous); await this.prefs.flush(); } catch (_) { /* Storage remains unavailable. */ }
      throw new Error('PREFERENCE_SAVE_FAILED');
    }
    this.prefCache.set(key, value);
    this.applyPerformance();
    AppStorage.setOrCreate('nativeSettingsRevision', (AppStorage.get<number>('nativeSettingsRevision') || 0) + 1);
  }

  private applyPerformance(): void {
    AppStorage.setOrCreate('blurEnabled', this.getPreference('blurEnabled', 'true') !== 'false');
    AppStorage.setOrCreate('animationsEnabled', this.getPreference('animationsEnabled', 'true') !== 'false');
    AppStorage.setOrCreate('listCacheCount', Number(this.getPreference('listCacheCount', '3')));
  }

  private async readVersion(): Promise<void> {
    try {
      const info = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      if (info.name !== NATIVE_BUNDLE_NAME || typeof info.versionName !== 'string' || info.versionName.length === 0 ||
        info.versionName.length > 128 || !Number.isSafeInteger(info.versionCode) || info.versionCode < 0) {
        throw new Error('VERSION_UNAVAILABLE');
      }
      this.versionName = info.versionName;
      this.build = String(info.versionCode);
    } catch (_) {
      this.versionName = 'unavailable';
      this.build = 'unavailable';
    }
    AppStorage.setOrCreate('nativeVersionName', this.versionName);
    AppStorage.setOrCreate('nativeBuild', this.build);
  }

  private requireContext(): common.UIAbilityContext {
    if (!this.context) throw new Error('NATIVE_SETTINGS_NO_CONTEXT');
    return this.context;
  }

  get notificationSystemKnown(): boolean { return this.systemKnown; }
  get notificationSystemEnabled(): boolean { return this.systemEnabled; }
  get lastPublishFailure(): string { return this.publishFailure; }
  private recordPublishFailure(code: string): void {
    this.publishFailure = code;
    AppStorage.setOrCreate('nativeNotificationFailure', code);
  }
  private async systemCall<T>(operation: Promise<T>): Promise<T> {
    let timer: number = -1;
    const timeout = new Promise<T>((_resolve, reject) => {
      timer = setTimeout(() => reject(new Error('NOTIFICATION_STATUS_FAILED')), 8000);
    });
    try { return await Promise.race<T>([operation, timeout]); }
    finally { if (timer >= 0) clearTimeout(timer); }
  }
  private setSystemStatus(enabled: boolean, known: boolean): void {
    this.systemEnabled = enabled; this.systemKnown = known;
    AppStorage.setOrCreate('nativeNotificationSystemEnabled', enabled);
    AppStorage.setOrCreate('nativeNotificationSystemKnown', known);
  }

  async refreshNotifications(): Promise<boolean> {
    try {
      const enabled = await this.systemCall(notificationManager.isNotificationEnabled());
      if (!enabled) {
        this.setSystemStatus(false, true);
        return false;
      }
      let slotEnabled = true;
      let slot = await this.systemCall(notificationManager.getSlot(notificationManager.SlotType.SERVICE_INFORMATION));
      if (slot === null) {
        await this.systemCall(notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION));
        slot = await this.systemCall(notificationManager.getSlot(notificationManager.SlotType.SERVICE_INFORMATION));
      }
      if (slot && (slot.enabled === false || slot.notificationLevel === notificationManager.SlotLevel.LEVEL_NONE)) {
        slotEnabled = false;
      }
      const allowed = enabled && slotEnabled;
      this.setSystemStatus(allowed, true);
      return allowed;
    } catch (_) {
      this.setSystemStatus(false, false);
      this.recordPublishFailure('STATUS_FAILED');
      throw new Error('NOTIFICATION_STATUS_FAILED');
    }
  }

  // The settings page calls this only from its explicit permission button. Publishing,
  // initialization and preference changes never display the system authorization prompt.
  async requestNotifications(): Promise<boolean> {
    const context = this.requireContext();
    try {
      await notificationManager.requestEnableNotification(context);
    } catch (error) {
      if ((error as BusinessError).code === NOTIFICATION_REFUSED) {
        this.setSystemStatus(false, true);
        return false;
      }
      throw new Error('NOTIFICATION_REQUEST_FAILED');
    }
    return await this.refreshNotifications();
  }

  async openNotificationSettings(): Promise<boolean> {
    const context = this.requireContext();
    try {
      await notificationManager.openNotificationSettingsWithResult(context);
    } catch (_) {
      throw new Error('NOTIFICATION_SETTINGS_FAILED');
    }
    // A resolved open call means the system accepted the navigation, not that the user
    // enabled anything. Re-read the actual state when the settings surface closes.
    await this.refreshNotifications();
    return true;
  }

  private notificationPreferences(): LocalNotificationPreferences {
    return {
      enabled: this.getPreference('enabled', 'true') !== 'false',
      done: this.getPreference('done', 'true') !== 'false',
      failed: this.getPreference('failed', 'true') !== 'false',
      approval: this.getPreference('approval', 'true') !== 'false',
      question: this.getPreference('question', 'true') !== 'false'
    };
  }

  async publish(kind: string, title: string, body: string): Promise<boolean> {
    if (NOTIFICATION_KINDS.indexOf(kind) < 0) throw new Error('INVALID_NOTIFICATION_KIND');
    this.recordPublishFailure('');
    if (!this.initialized) {
      const pending = this.initializing;
      if (!pending) { this.recordPublishFailure('NOT_READY'); return false; }
      try { await pending; } catch (_) { this.recordPublishFailure('NOT_READY'); return false; }
    }
    // Never use optimistic defaults to publish before persisted opt-outs have been read.
    if (!this.initialized || !notificationAllowed(kind, this.notificationPreferences())) {
      this.recordPublishFailure(this.initialized ? 'PREFERENCE_DISABLED' : 'NOT_READY'); return false;
    }
    if (!await this.refreshNotifications()) { this.recordPublishFailure('SYSTEM_DISABLED'); return false; }
    // A preference may have changed while the system state was being read.
    if (!notificationAllowed(kind, this.notificationPreferences())) { this.recordPublishFailure('PREFERENCE_DISABLED'); return false; }
    this.notificationSequence = (this.notificationSequence % 2147483646) + 1;
    const fallback = kind === 'approval' ? '有一项操作等待确认' : kind === 'question' ? '主机向你提问' :
      kind === 'failed' ? '一轮对话出错或已停止' : '一轮对话已完成';
    const request: notificationManager.NotificationRequest = {
      id: this.notificationSequence,
      label: 'dsh-local:' + Date.now() + ':' + this.notificationSequence,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      tapDismissed: true,
      isAlertOnce: true,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: diagnosticText(title, 'DSH Go').trim() || 'DSH Go',
          text: diagnosticText(body, fallback).trim() || fallback
        }
      }
    };
    try {
      await notificationManager.publish(request);
      return true;
    } catch (error) {
      if ((error as BusinessError).code === NOTIFICATION_REFUSED) {
        this.setSystemStatus(false, true);
        this.recordPublishFailure('SYSTEM_DISABLED');
        return false;
      }
      throw new Error('NOTIFICATION_PUBLISH_FAILED');
    }
  }

  private currentDiagnostics(): NativeDiagnostics {
    const address = AppStorage.get<string>('activeHostAddress');
    return {
      app: { version: this.versionName, build: this.build },
      connectionState: diagnosticText(AppStorage.get<string>('connectionState'), 'unknown'),
      connectionError: diagnosticText(AppStorage.get<string>('connectionError')),
      activeHostName: diagnosticText(AppStorage.get<string>('activeHostName')),
      activeHostAddress: safeDiagnosticOrigin(typeof address === 'string' ? address : ''),
      theme: this.uiCache.get('theme') || '0',
      font: this.uiCache.get('font') || '1',
      fold: this.uiCache.get('fold') || 'true',
      notifications: this.notificationPreferences()
    };
  }

  async diagnosticsJson(): Promise<string> {
    if (this.versionName === 'unavailable') await this.readVersion();
    return JSON.stringify(this.currentDiagnostics(), null, 2);
  }

  private async copyText(value: string, action: string): Promise<boolean> {
    try {
      const board = pasteboard.getSystemPasteboard();
      await board.setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value));
      AppStorage.setOrCreate('nativeDiagnosticAction', action);
      return true;
    } catch (_) {
      AppStorage.setOrCreate('nativeDiagnosticAction', 'copy-failed');
      throw new Error('CLIPBOARD_WRITE_FAILED');
    }
  }

  async copyDiagnostics(): Promise<boolean> {
    return await this.copyText(await this.diagnosticsJson(), 'copied');
  }

  // No verified ShareKit file-export seam exists in this three-file native change. The
  // honest fallback is a clipboard copy; LocalSettingsPage always labels it "已复制",
  // never as a completed system share. A rejected clipboard write remains a failure.
  async shareDiagnostics(): Promise<boolean> {
    return await this.copyText(await this.diagnosticsJson(), 'copied-for-sharing');
  }
}

export const nativeLocalSettings: NativeLocalSettings = new NativeLocalSettings();
