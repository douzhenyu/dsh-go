import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import { util } from '@kit.ArkTS';
import { HostInfo, Session, Workspace, Message } from '../common/Models';
import { NativeClient } from '../data/NativeClient';
import { NativeCarrier } from '../data/NativeCarrier';
import { NativeSession, NativeWorkspace, NativeRecord, NativeSessionUpdate, NativeHostEvent, NativeAnswer } from '../data/NativeDto';
import { obj, arr, str, num, parseObject } from '../data/NativeDecode';
import { Transcript } from './Transcript';
import { nativeLocalSettings } from './NativeLocalSettings';
import {
  nativeHostSettings, HostRpc, HostSettingsSnapshot, HostSettingsNamespace, HostSettingsOp,
  AgentPresetInfo, AgentPresetDocument, NativePluginInfo, DefaultPermissionInfo, DefaultModelInfo
} from './NativeHostSettings';

interface ControlChange { key: string; val: ESObject; }
interface WorkspaceRequest { path: string; }
interface WorkspaceArgs { request: WorkspaceRequest; }
interface SelectRequest { sessionId: string; provider: string; model: string; reasoningEffort?: string; }
interface SelectArgs { request: SelectRequest; }
interface CommandArgs { agentId: string; line: string; submittedAttachments: string[]; }

class Endpoint {
  id: string = '';
  name: string = '';
  url: string = '';
  kind: string = 'direct';
}
export class ModelChoice {
  provider: string = '';
  id: string = '';
  name: string = '';
  effortIds: string[] = [];
  effortNames: string[] = [];
  defaultEffort: string = '';
}
class PermissionChoice { id: string = ''; name: string = ''; }

function safeError(error: Error): string {
  // Transport errors are constructed by NativeClient, never raw URLs or credentials.
  const prefix = error.message.split(':')[0];
  if (/^[A-Z][A-Z0-9_]{0,99}$/.test(error.message) && ['INVALID_URL', 'AUTH_FAILED', 'UNSUPPORTED', 'DISCONNECTED', 'TIMEOUT', 'PROTOCOL'].indexOf(error.message) < 0) return '远程连接失败（' + error.message + '）';
  if (prefix === 'INVALID_URL') return '登录地址无效，请粘贴 dsh web 输出的完整登录地址（INVALID_URL）';
  if (prefix === 'AUTH_FAILED') return '认证失败，请使用主机当前的登录地址（AUTH_FAILED）';
  if (prefix === 'UNSUPPORTED') return '当前系统或主机不支持所需协议（UNSUPPORTED）';
  if (prefix === 'DISCONNECTED') return '与主机的连接已断开，请重新连接（DISCONNECTED）';
  if (prefix === 'TIMEOUT') return '主机响应超时，请检查网络后重试（TIMEOUT）';
  if (prefix === 'PROTOCOL') return '数据流不连续或协议不匹配，请刷新（PROTOCOL）';
  if (prefix === 'REMOTE') {
    const code = error.message.substring(7).trim();
    return '主机拒绝了请求（' + (/^[A-Za-z0-9_/-]{1,100}$/.test(code) ? code : 'REMOTE') + '）';
  }
  if (/^CONNECTION_FAILED: (login-http|ws-upgrade|events-ready) code=-?\d+ status=\d+$/.test(error.message)) return error.message;
  return '连接或请求失败，请检查主机与网络（CONNECTION_FAILED）';
}
function projectionModel(json: string): string {
  const values: ESObject = obj(parseObject(json).values);
  const selection: ESObject = obj(values.modelSelection);
  const model: ESObject = obj(selection.next || selection.lastUsed);
  return str(model.model);
}

// UI state is published only for the owning connection and session generation.
// Authentication stays in NativeClient memory; preferences contain non-secret metadata only.
class AppStore {
  // Observes connection lifecycle only; the Remote coordinator never replays RPC writes.
  onConnectionState?: (state: string, code: string) => void;
  private publishConnection(state: string, code: string = ''): void {
    AppStorage.setOrCreate('connectionState', state);
    AppStorage.setOrCreate('connectionError', code);
    this.onConnectionState?.(state, code);
  }
  private client: NativeClient = new NativeClient();
  private generation: number = 0;
  private chatEpoch: number = 0;
  private endpoints: Endpoint[] = [];
  private activeId: string = '';
  private ready: boolean = false;
  private prefs?: preferences.Preferences;
  private prefCache: Map<string, string> = new Map();
  private context?: common.UIAbilityContext;
  private initialized: boolean = false;
  private refreshing: boolean = false;
  private refreshTimer: number = -1;
  private selectedSession: string = '';
  private followId: string = '';
  private transcript: Transcript = new Transcript();
  private models: ModelChoice[] = [];
  private permissions: PermissionChoice[] = [];
  private pending: NativeHostEvent[] = [];
  private pendingSendId: string = '';
  private pendingSendText: string = '';
  private pendingSendSession: string = '';
  private alertedEvents: Set<string> = new Set();

  constructor() {
    AppStorage.setOrCreate<HostInfo[]>('hosts', []);
    AppStorage.setOrCreate<Session[]>('sessions', []);
    AppStorage.setOrCreate<Workspace[]>('workspaces', []);
    AppStorage.setOrCreate<Message[]>('chatMessages', []);
    AppStorage.setOrCreate<NativeHostEvent[]>('pendingRequests', []);
    AppStorage.setOrCreate('connectionState', 'disconnected');
    AppStorage.setOrCreate('connectionError', '');
    AppStorage.setOrCreate('activeHostId', '');
    AppStorage.setOrCreate('activeHostName', '');
    AppStorage.setOrCreate('activeHostAddress', '');
    AppStorage.setOrCreate('sessionId', '');
    AppStorage.setOrCreate('sessionTitle', '对话');
    AppStorage.setOrCreate('sessionWorkspace', '');
    AppStorage.setOrCreate('sessionModel', '未选择模型');
    AppStorage.setOrCreate('sessionStatus', 'idle');
    AppStorage.setOrCreate('sessionStatusText', '');
    AppStorage.setOrCreate('chatLoading', false);
    AppStorage.setOrCreate('chatBusy', false);
    AppStorage.setOrCreate('chatError', '');
    AppStorage.setOrCreate('chatHasMore', false);
    AppStorage.setOrCreate('dataLoading', false);
    AppStorage.setOrCreate('selectionBusy', false);
    AppStorage.setOrCreate<string[]>('modelLabels', []);
    AppStorage.setOrCreate<string[]>('depthLabels', []);
    AppStorage.setOrCreate<string[]>('permissionLabels', []);
    AppStorage.setOrCreate('modelIndex', -1);
    AppStorage.setOrCreate('depthIndex', -1);
    AppStorage.setOrCreate('permissionIndex', -1);
    AppStorage.setOrCreate('catalogError', '');
    AppStorage.setOrCreate('preferenceRevision', 0);
    AppStorage.setOrCreate('chatFontSize', 15);
    AppStorage.setOrCreate('foldCompleted', true);
    AppStorage.setOrCreate('blurEnabled', true);
    AppStorage.setOrCreate('animationsEnabled', true);
    AppStorage.setOrCreate('listCacheCount', 3);
  }
  async initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialized) return;
    this.initialized = true; this.context = context;
    try {
      this.prefs = await preferences.getPreferences(context, { name: 'native-host-metadata' });
      const encoded = await this.prefs.get('endpoints', '[]');
      const values: ESObject = JSON.parse(String(encoded));
      { const jsonRows0: ESObject[] = arr(values); for (let jsonIndex0 = 0; jsonIndex0 < jsonRows0.length; jsonIndex0++) { const raw: ESObject = jsonRows0[jsonIndex0];
        const endpoint = new Endpoint(); endpoint.id = str(raw.id); endpoint.name = str(raw.name);
        endpoint.url = str(raw.url).split('?')[0].split('#')[0];
        endpoint.kind = raw.kind === 'remote' ? 'remote' : 'direct';
        if (/^https?:\/\/[^/@?#]+(?::\d+)?(?:\/[^?#]*)?$/.test(endpoint.url) && endpoint.id) this.endpoints.push(endpoint);
      } }
      for (const key of ['theme', 'font', 'fold', 'lang', 'perf', 'autoUpdate']) {
        const value = await this.prefs.get(key, ''); this.prefCache.set(key, String(value));
      }
      this.applyPreferences(); this.publishHosts();
    } catch (_) {
      AppStorage.setOrCreate('connectionError', '本地偏好不可用，连接仍可正常使用');
    }
  }
  getPreference(key: string, fallback: string = ''): string { return this.prefCache.get(key) || fallback; }
  async setPreference(key: string, value: string): Promise<void> {
    if (['theme', 'font', 'fold', 'lang', 'perf', 'autoUpdate'].indexOf(key) < 0) throw new Error('INVALID_PREFERENCE');
    if (!this.prefs) throw new Error('本地偏好存储尚未就绪，暂未保存');
    await this.prefs.put(key, value); await this.prefs.flush();
    this.prefCache.set(key, value); this.applyPreferences();
  }
  private applyPreferences(): void {
    const theme = this.getPreference('theme', '0');
    this.context?.getApplicationContext().setColorMode(theme === '1' ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
      theme === '2' ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    const index = Number(this.getPreference('font', '1'));
    const sizes: number[] = [14, 15, 17, 19];
    AppStorage.setOrCreate('chatFontSize', sizes[index] || 15);
    AppStorage.setOrCreate('foldCompleted', this.getPreference('fold', 'true') !== 'false');
    AppStorage.setOrCreate('preferenceRevision', (AppStorage.get<number>('preferenceRevision') || 0) + 1);
  }
  private publishHosts(): void {
    const rows: HostInfo[] = this.endpoints.map((endpoint: Endpoint): HostInfo => ({
      id: endpoint.id, name: endpoint.name, kind: endpoint.kind, address: endpoint.url,
      state: endpoint.id === this.activeId && this.ready ? 'connected' : 'offline',
      route: endpoint.kind === 'remote' ? 'Relay · Noise IK' : 'HTTP / WebSocket', latency: endpoint.id === this.activeId ? AppStorage.get<string>('hostLatency') || '—' : '—'
    }));
    AppStorage.setOrCreate('hosts', rows);
  }
  private clearChat(): void {
    this.chatEpoch++;
    if (this.followId) this.client.unfollow(this.followId);
    this.followId = ''; this.selectedSession = ''; this.transcript.reset();
    this.pendingSendId = ''; this.pendingSendText = ''; this.pendingSendSession = '';
    AppStorage.setOrCreate<Message[]>('chatMessages', []);
    AppStorage.setOrCreate('chatLoading', false); AppStorage.setOrCreate('chatBusy', false);
    AppStorage.setOrCreate('chatHasMore', false); AppStorage.setOrCreate('chatError', '');
    AppStorage.setOrCreate('sessionId', ''); AppStorage.setOrCreate('sessionTitle', '对话');
    AppStorage.setOrCreate('sessionWorkspace', ''); AppStorage.setOrCreate('sessionStatus', 'idle');
    AppStorage.setOrCreate('sessionModel', '未选择模型');
  }
  private clearData(): void {
    this.clearChat(); this.pending = [];
    AppStorage.setOrCreate<NativeHostEvent[]>('pendingRequests', []);
    AppStorage.setOrCreate<Session[]>('sessions', []); AppStorage.setOrCreate<Workspace[]>('workspaces', []);
    AppStorage.setOrCreate<string[]>('modelLabels', []); AppStorage.setOrCreate<string[]>('depthLabels', []);
    AppStorage.setOrCreate<string[]>('permissionLabels', []);
    AppStorage.setOrCreate('modelIndex', -1); AppStorage.setOrCreate('depthIndex', -1); AppStorage.setOrCreate('permissionIndex', -1);
    this.models = []; this.permissions = []; this.refreshing = false;
    AppStorage.setOrCreate('dataLoading', false); AppStorage.setOrCreate('selectionBusy', false);
  }
  private beginConnection(): NativeClient {
    const generation = ++this.generation;
    this.client.disconnect(); this.clearData(); this.ready = false;
    this.client = new NativeClient(); const client = this.client;
    this.publishHosts(); this.publishConnection('connecting');
    client.onState = (state: string, message: string) => {
      if (generation !== this.generation || client !== this.client) return;
      if (state === 'connected') return; // Publish ready only after the initial data baseline.
      if (state === 'connecting') { AppStorage.setOrCreate('connectionState', state); return; }
      if (state === 'error') {
        this.ready = false; this.clearData(); this.publishHosts();
        this.publishConnection('error', safeError(new Error(message)));
      }
    };
    client.onHostEvent = (event: NativeHostEvent) => {
      if (generation === this.generation && client === this.client) this.hostEvent(event);
    };
    return client;
  }
  get connectionEpoch(): number { return this.generation; }
  cancelConnection(epoch: number): void { if (epoch === this.generation) this.disconnect(); }
  private async finishConnection(endpoint: Endpoint, generation: number): Promise<void> {
    if (generation !== this.generation) return;
    this.activeId = endpoint.id; this.ready = true;
    AppStorage.setOrCreate('activeHostId', endpoint.id); AppStorage.setOrCreate('activeHostName', endpoint.name);
    AppStorage.setOrCreate('activeHostAddress', endpoint.url); AppStorage.setOrCreate('hostLatency', '—');
    await this.refresh();
    if (generation !== this.generation) return;
    await this.loadCatalog();
    if (generation !== this.generation) return;
    this.publishHosts(); this.publishConnection('ready'); this.watchLists(generation);
    if (this.prefs) {
      try { await this.prefs.put('endpoints', JSON.stringify(this.endpoints)); await this.prefs.flush(); }
      catch (_) { if (generation === this.generation) AppStorage.setOrCreate('connectionError', '主机已连接，但未能保存无密钥的主机地址'); }
    }
  }
  private failedConnection(client: NativeClient, generation: number, error: Error): void {
    if (generation !== this.generation) return;
    this.ready = false; client.disconnect(); this.clearData(); this.publishHosts();
    const text = safeError(error);
    this.publishConnection('error', text);
  }
  async connect(launchUrl: string, name: string = ''): Promise<void> {
    const client = this.beginConnection(); const generation = this.generation;
    try {
      await client.connect(launchUrl);
      if (generation !== this.generation) return;
      const match = launchUrl.trim().match(/https?:\/\/[^\s?#]+/);
      if (!match) throw new Error('INVALID_URL');
      const address = match[0].replace(/\/$/, '');
      let endpoint = this.endpoints.find((row: Endpoint): boolean => row.kind === 'direct' && row.url === address);
      if (!endpoint) { endpoint = new Endpoint(); endpoint.id = util.generateRandomUUID(true); endpoint.url = address; this.endpoints.push(endpoint); }
      endpoint.name = name.trim() || address.replace(/^https?:\/\//, '');
      await this.finishConnection(endpoint, generation);
    } catch (error) {
      if (generation !== this.generation) return;
      this.failedConnection(client, generation, error as Error); throw error as Error;
    }
  }
  async connectCarrier(carrier: NativeCarrier, name: string, serverUrl: string, hostId: string): Promise<void> {
    const address = serverUrl.split('?')[0].split('#')[0].replace(/\/$/, '');
    if (!/^https?:\/\/[^/@?#]+(?:\/[^?#]*)?$/.test(address) || !hostId) throw new Error('INVALID_URL');
    const id = 'remote:' + hostId + '@' + address;
    const client = this.beginConnection(); const generation = this.generation;
    this.activeId = id;
    AppStorage.setOrCreate('activeHostId', id); AppStorage.setOrCreate('activeHostName', name || hostId);
    AppStorage.setOrCreate('activeHostAddress', address); this.publishHosts();
    try {
      await client.connectCarrier(carrier);
      if (generation !== this.generation) return;
      let endpoint = this.endpoints.find((row: Endpoint): boolean => row.id === id);
      if (!endpoint) { endpoint = new Endpoint(); endpoint.id = id; this.endpoints.push(endpoint); }
      endpoint.name = name || hostId; endpoint.url = address; endpoint.kind = 'remote';
      await this.finishConnection(endpoint, generation);
    } catch (error) {
      if (generation !== this.generation) return;
      this.failedConnection(client, generation, error as Error); throw error as Error;
    }
  }

  disconnect(): void {
    this.generation++; this.ready = false;
    if (this.refreshTimer >= 0) clearTimeout(this.refreshTimer);
    this.refreshTimer = -1; this.client.disconnect(); this.clearData(); this.publishHosts();
    this.publishConnection('disconnected');
  }
  async selectHost(id: string): Promise<void> {
    if (this.activeId === id && this.ready) return;
    const endpoint = this.endpoints.find((row: Endpoint): boolean => row.id === id);
    if (!endpoint) throw new Error('主机不存在');
    this.disconnect(); this.activeId = id;
    AppStorage.setOrCreate('activeHostId', id); AppStorage.setOrCreate('activeHostName', endpoint.name);
    AppStorage.setOrCreate('activeHostAddress', endpoint.url);
    throw new Error('请使用该主机当前的登录地址重新连接');
  }
  private requireReady(): void { if (!this.ready) throw new Error('DISCONNECTED: connect to Host'); }
  private settingsCall<T>(operation: (rpc: HostRpc) => Promise<T>): Promise<T> {
    this.requireReady(); const generation = this.generation; const client = this.client;
    const rpc: HostRpc = (endpoint: string, argsJson: string): Promise<string> => {
      if (generation !== this.generation || client !== this.client) return Promise.reject(new Error('DISCONNECTED'));
      return client.rpc(endpoint, argsJson);
    };
    return operation(rpc).then((value: T): T => {
      if (generation !== this.generation || client !== this.client) throw new Error('DISCONNECTED');
      return value;
    });
  }
  hostDescribe(): Promise<HostSettingsSnapshot> { return this.settingsCall((rpc: HostRpc) => nativeHostSettings.describe(rpc)); }
  hostMutate(ns: string, ops: HostSettingsOp[], revision: number): Promise<HostSettingsNamespace> {
    return this.settingsCall((rpc: HostRpc) => nativeHostSettings.mutate(rpc, ns, ops, revision));
  }
  hostPresets(): Promise<AgentPresetInfo[]> { return this.settingsCall((rpc: HostRpc) => nativeHostSettings.agentPresets(rpc)); }
  hostReadPreset(id: string): Promise<AgentPresetDocument> { return this.settingsCall((rpc: HostRpc) => nativeHostSettings.readAgentPreset(rpc, id)); }
  hostSelectPreset(id: string, revision: number): Promise<string> {
    return this.settingsCall((rpc: HostRpc) => nativeHostSettings.selectAgentPreset(rpc, id, revision));
  }
  hostPlugins(): Promise<NativePluginInfo[]> { return this.settingsCall((rpc: HostRpc) => nativeHostSettings.plugins(rpc)); }
  hostSetBundleEnabled(name: string, enabled: boolean): Promise<string> {
    return this.settingsCall((rpc: HostRpc) => nativeHostSettings.setBundleEnabled(rpc, name, enabled));
  }
  hostSetPluginEnabled(id: string, enabled: boolean): Promise<string> {
    return this.settingsCall((rpc: HostRpc) => nativeHostSettings.setPluginEnabled(rpc, id, enabled));
  }
  hostDefaultPermission(): Promise<DefaultPermissionInfo> { return this.settingsCall((rpc: HostRpc) => nativeHostSettings.defaultPermission(rpc)); }
  hostSetDefaultPermission(id: string, revision: number): Promise<HostSettingsNamespace> {
    return this.settingsCall((rpc: HostRpc) => nativeHostSettings.setDefaultPermission(rpc, id, revision));
  }
  hostDefaultModel(): Promise<DefaultModelInfo> { return this.settingsCall((rpc: HostRpc) => nativeHostSettings.defaultModel(rpc)); }
  hostSetDefaultModel(provider: string, model: string, effort: string, remember: boolean | undefined, revision: number): Promise<HostSettingsNamespace> {
    return this.settingsCall((rpc: HostRpc) => nativeHostSettings.setDefaultModel(rpc, provider, model, effort, remember, revision));
  }
  get hostModels(): ModelChoice[] { return this.models.slice(); }
  async measure(): Promise<void> {
    this.requireReady(); const generation = this.generation;
    const start = Date.now(); AppStorage.setOrCreate('hostLatency', '测量中…'); this.publishHosts();
    try {
      await this.client.rpc('session/list', '{"_request":{}}');
      if (generation === this.generation) { AppStorage.setOrCreate('hostLatency', (Date.now() - start) + ' ms'); this.publishHosts(); }
    } catch (error) {
      if (generation === this.generation) { AppStorage.setOrCreate('hostLatency', '测量失败'); this.publishHosts(); }
      throw error as Error;
    }
  }
  async refresh(): Promise<void> {
    this.requireReady(); if (this.refreshing) return;
    const generation = this.generation; const client = this.client;
    this.refreshing = true; AppStorage.setOrCreate('dataLoading', true);
    try {
      const sessions = await client.sessions(); const workspaces = await client.workspaces();
      if (generation !== this.generation) return;
      const projects: Workspace[] = workspaces.map((row: NativeWorkspace): Workspace => ({ id: row.workspaceId, title: row.title, path: row.path, sessionIds: row.sessionIds }));
      AppStorage.setOrCreate('workspaces', projects);
      const rows: Session[] = sessions.map((row: NativeSession): Session => {
        const project = projects.find((value: Workspace): boolean => value.sessionIds.indexOf(row.sessionId) >= 0);
        const status = this.pending.some((event: NativeHostEvent): boolean => event.sessionId === row.sessionId) ? 'pending' : row.running ? 'running' : 'idle';
        return { id: row.sessionId, title: row.title || (row.blank ? '新对话' : '未命名对话'), preview: row.blank ? '尚无消息' : '',
          time: row.updatedAt ? new Date(row.updatedAt).toLocaleString() : '', workspace: project ? project.title : '未分组',
          workspaceId: project ? project.id : '', cwd: row.cwd, model: projectionModel(row.projectionsJson) || '', status: status };
      });
      rows.sort((a: Session, b: Session): number => {
        const left = sessions.find((v: NativeSession): boolean => v.sessionId === a.id);
        const right = sessions.find((v: NativeSession): boolean => v.sessionId === b.id);
        return (right ? right.updatedAt : 0) - (left ? left.updatedAt : 0);
      });
      AppStorage.setOrCreate('sessions', rows); AppStorage.setOrCreate('connectionError', '');
    } catch (error) {
      if (generation === this.generation) AppStorage.setOrCreate('connectionError', safeError(error as Error));
      throw error as Error;
    } finally {
      if (generation === this.generation) { this.refreshing = false; AppStorage.setOrCreate('dataLoading', false); }
    }
  }
  private watchLists(generation: number): void {
    this.client.subscribe('workspace/follow', '{}', (json: string) => {
      if (generation !== this.generation) return;
      const value: ESObject = parseObject(json);
      if (value.type !== 'baseline') this.scheduleRefresh();
    }, () => { if (generation === this.generation && this.ready) AppStorage.setOrCreate('connectionError', '工作区实时列表不可用，请手动刷新'); });
    this.client.subscribe('session/control', '{}', (json: string) => {
      if (generation !== this.generation) return;
      const value: ESObject = parseObject(json);
      if (value.type === 'baseline') return;
      const changes: ESObject[] = value.changes ? arr(value.changes) : [];
      if (!value.changes) { const change: ControlChange = { key: str(value.key), val: value.value }; changes.push(change); }
      { const jsonRows1: ESObject[] = changes; for (let jsonIndex1 = 0; jsonIndex1 < jsonRows1.length; jsonIndex1++) { const change: ESObject = jsonRows1[jsonIndex1];
        const key = str(change.key);
        if (str(value.sessionId) === this.selectedSession) {
          if (key === 'title') AppStorage.setOrCreate('sessionTitle', str(change.val));
          if (key === 'permissions') this.applyPermission(str(obj(change.val).currentValue));
          if (key === 'modelSelection') {
            const selection: ESObject = obj(change.val); this.applySelection(obj(selection.next || selection.lastUsed));
          }
        }
        if (['title', 'modelSelection', 'permissions', 'sessionListMetadata'].indexOf(key) >= 0) this.scheduleRefresh();
      } }
    }, () => { if (generation === this.generation && this.ready) AppStorage.setOrCreate('connectionError', '会话实时列表不可用，请手动刷新'); });
  }
  private scheduleRefresh(): void {
    if (!this.ready || this.refreshTimer >= 0) return;
    this.refreshTimer = setTimeout(() => {
      this.refreshTimer = -1;
      this.refresh().catch(() => {}); // refresh publishes a stable error; the last good list remains visible.
    }, 300);
  }
  async createWorkspace(path: string): Promise<string> {
    this.requireReady();
    const args: WorkspaceArgs = { request: { path: path.trim() } };
    const value: ESObject = parseObject(await this.client.rpc('workspace/create', JSON.stringify(args)));
    const id = str(obj(value.workspace).workspaceId);
    if (!id) throw new Error('PROTOCOL: missing workspace ID');
    await this.refresh(); return id;
  }
  async createSession(workspaceId: string = '', cwd: string = ''): Promise<Session> {
    this.requireReady(); const generation = this.generation;
    const id = await this.client.createSession(cwd, workspaceId);
    if (generation !== this.generation) throw new Error('DISCONNECTED');
    await this.refresh();
    const row = (AppStorage.get<Session[]>('sessions') || []).find((value: Session): boolean => value.id === id);
    if (!row) throw new Error('PROTOCOL: created session not present in Host list');
    return row;
  }
  selectSession(session: Session): void {
    AppStorage.setOrCreate('sessionId', session.id); AppStorage.setOrCreate('sessionTitle', session.title);
    AppStorage.setOrCreate('sessionWorkspace', session.workspace); AppStorage.setOrCreate('sessionModel', session.model || '未选择模型');
    AppStorage.setOrCreate('sessionStatus', session.status);
  }
  openChat(sessionId: string): void {
    this.requireReady();
    if (this.followId) this.client.unfollow(this.followId);
    this.transcript.reset(); this.selectedSession = sessionId;
    const epoch = ++this.chatEpoch; const generation = this.generation;
    AppStorage.setOrCreate<Message[]>('chatMessages', []); AppStorage.setOrCreate('chatLoading', true);
    AppStorage.setOrCreate('chatError', ''); AppStorage.setOrCreate('chatHasMore', false);
    this.followId = this.client.follow(sessionId, (update: NativeSessionUpdate) => {
      if (generation !== this.generation || epoch !== this.chatEpoch || this.selectedSession !== sessionId) return;
      this.transcript.apply(update);
      if (update.title) AppStorage.setOrCreate('sessionTitle', update.title);
      if (update.type === 'snapshot') this.applyProjection(update.projectionsJson);
      for (const record of update.records) {
        if (update.type === 'event' && record.type === 'turn/end') {
          const reason: ESObject = obj(parseObject(record.dataJson).reason);
          const failed = str(reason.kind) === 'error' || str(reason.kind) === 'aborted';
          this.notifyOnce(failed ? 'failed' : 'done', sessionId + ':turn:' + record.seq,
            failed ? '对话已停止或失败' : '回复已完成', AppStorage.get<string>('sessionTitle') || '远程对话');
        }
        if (record.type === 'session/title') AppStorage.setOrCreate('sessionTitle', str(parseObject(record.dataJson).title));
        if (record.type === 'model/selection') this.applySelection(parseObject(record.dataJson));
        if (record.type === 'permission/preset') this.applyPermission(str(parseObject(record.dataJson).preset));
        if (record.type === 'user/message' && str(obj(parseObject(record.dataJson).source).rpcId) === this.pendingSendId) this.pendingSendId = '';
      }
      AppStorage.setOrCreate('chatLoading', false); this.publishTranscript();
    }, (error: Error) => {
      if (generation !== this.generation || epoch !== this.chatEpoch) return;
      AppStorage.setOrCreate('chatLoading', false); AppStorage.setOrCreate('chatError', safeError(error));
    });
  }
  closeChat(sessionId: string): void {
    if (this.selectedSession !== sessionId) return;
    this.chatEpoch++; if (this.followId) this.client.unfollow(this.followId);
    this.followId = ''; this.selectedSession = '';
  }
  private publishTranscript(): void {
    AppStorage.setOrCreate('chatMessages', this.transcript.messages());
    AppStorage.setOrCreate('chatHasMore', this.transcript.hasMore);
    const waiting = this.pending.some((event: NativeHostEvent): boolean => event.sessionId === this.selectedSession);
    AppStorage.setOrCreate('sessionStatus', waiting ? 'pending' : this.transcript.running ? 'running' : 'idle');
    AppStorage.setOrCreate('sessionStatusText', this.transcript.statusText || '正在生成');
  }
  async loadOlder(): Promise<void> {
    this.requireReady(); if (!this.selectedSession || !this.transcript.hasMore) return;
    const epoch = this.chatEpoch; const generation = this.generation;
    const page = await this.client.read(this.selectedSession, this.transcript.cursor, this.transcript.oldest());
    if (epoch !== this.chatEpoch || generation !== this.generation) return;
    this.transcript.merge(page.records); this.transcript.hasMore = page.hasMore; this.publishTranscript();
  }
  async send(text: string): Promise<void> {
    this.requireReady(); const sessionId = this.selectedSession;
    if (!sessionId || !text.trim()) throw new Error('请选择对话并输入消息');
    const generation = this.generation; const epoch = this.chatEpoch;
    if (!this.pendingSendId || this.pendingSendSession !== sessionId || this.pendingSendText !== text) {
      this.pendingSendId = util.generateRandomUUID(true); this.pendingSendSession = sessionId; this.pendingSendText = text;
    }
    const requestId = this.pendingSendId;
    AppStorage.setOrCreate('chatBusy', true); AppStorage.setOrCreate('chatError', '');
    try {
      await this.client.send(sessionId, text, requestId);
      if (epoch !== this.chatEpoch || generation !== this.generation) return;
      this.pendingSendId = ''; this.scheduleRefresh();
    } catch (error) {
      if (epoch === this.chatEpoch && generation === this.generation) AppStorage.setOrCreate('chatError', safeError(error as Error) + '；结果未确认时重试会复用请求编号');
      throw error as Error;
    } finally { if (epoch === this.chatEpoch && generation === this.generation) AppStorage.setOrCreate('chatBusy', false); }
  }
  async cancel(): Promise<void> {
    this.requireReady(); if (!this.selectedSession) return;
    await this.client.cancel(this.selectedSession); // Only durable turn/end confirms that execution stopped.
  }
  private notifyOnce(kind: string, key: string, title: string, body: string): void {
    if (this.alertedEvents.has(key)) return;
    if (this.alertedEvents.size >= 512) this.alertedEvents.clear();
    this.alertedEvents.add(key);
    nativeLocalSettings.publish(kind, title, body).catch(() => {});
  }
  private hostEvent(event: NativeHostEvent): void {
    if (event.type === 'waterfall' && event.event === 'approval/request') {
      this.notifyOnce('approval', event.eventId, '等待你的授权', event.toolName || '主机请求确认操作');
    } else if (event.type === 'waterfall' && event.event === 'user-questions/request') {
      this.notifyOnce('question', event.eventId, '主机正在等待你的回答', AppStorage.get<string>('sessionTitle') || '远程对话');
    }
    if (event.type === 'waterfall' && (event.event === 'approval/request' || event.event === 'user-questions/request')) {
      this.pending = this.pending.filter((row: NativeHostEvent): boolean => row.eventId !== event.eventId).concat([event]);
    } else if (event.type === 'cancel') this.pending = this.pending.filter((row: NativeHostEvent): boolean => row.eventId !== event.eventId);
    if (event.type === 'emit' && event.event === 'api-session/status' && event.sessionId === this.selectedSession) this.transcript.running = event.running;
    AppStorage.setOrCreate('pendingRequests', this.pending.slice()); this.publishTranscript();
    if (event.type !== 'ready') this.scheduleRefresh();
  }
  async respondApproval(eventId: string, decision: string): Promise<void> {
    this.requireReady(); const generation = this.generation;
    await this.client.respondApproval(eventId, decision);
    if (generation !== this.generation) return;
    this.pending = this.pending.filter((row: NativeHostEvent): boolean => row.eventId !== eventId);
    AppStorage.setOrCreate('pendingRequests', this.pending.slice()); this.publishTranscript();
  }
  async answerQuestion(eventId: string, answers: NativeAnswer[]): Promise<void> {
    this.requireReady(); const generation = this.generation;
    await this.client.answerQuestion(eventId, answers);
    if (generation !== this.generation) return;
    this.pending = this.pending.filter((row: NativeHostEvent): boolean => row.eventId !== eventId);
    AppStorage.setOrCreate('pendingRequests', this.pending.slice()); this.publishTranscript();
  }
  async loadCatalog(): Promise<void> {
    this.requireReady(); const generation = this.generation;
    try {
      const catalog: ESObject = parseObject(await this.client.rpc('session/modelCatalog'));
      const choices: ModelChoice[] = [];
      { const jsonRows2: ESObject[] = arr(catalog.groups); for (let jsonIndex2 = 0; jsonIndex2 < jsonRows2.length; jsonIndex2++) { const group: ESObject = jsonRows2[jsonIndex2]; { const jsonRows3: ESObject[] = arr(group.models); for (let jsonIndex3 = 0; jsonIndex3 < jsonRows3.length; jsonIndex3++) { const model: ESObject = jsonRows3[jsonIndex3];
        const choice = new ModelChoice(); choice.provider = str(group.id); choice.id = str(model.id);
        choice.name = str(model.name) || choice.id;
        const reasoning: ESObject = obj(model.reasoning); choice.defaultEffort = str(reasoning.defaultEffort);
        { const jsonRows4: ESObject[] = arr(reasoning.efforts); for (let jsonIndex4 = 0; jsonIndex4 < jsonRows4.length; jsonIndex4++) { const effort: ESObject = jsonRows4[jsonIndex4];  choice.effortIds.push(str(effort.id)); choice.effortNames.push(str(effort.name) || str(effort.id)); } }
        choices.push(choice);
      } } }}
      const permissionCatalog: ESObject = parseObject(await this.client.rpc('permissionPresets/catalog'));
      const permissions: PermissionChoice[] = [];
      { const jsonRows5: ESObject[] = arr(permissionCatalog.options); for (let jsonIndex5 = 0; jsonIndex5 < jsonRows5.length; jsonIndex5++) { const raw: ESObject = jsonRows5[jsonIndex5];  const choice = new PermissionChoice(); choice.id = str(raw.value); choice.name = str(raw.name) || choice.id; permissions.push(choice); } }
      if (generation !== this.generation) return;
      this.models = choices; this.permissions = permissions;
      AppStorage.setOrCreate('modelLabels', choices.map((row: ModelChoice): string => row.name));
      AppStorage.setOrCreate('permissionLabels', permissions.map((row: PermissionChoice): string => row.name));
      this.applySelection(obj(catalog.default)); this.applyPermission(str(permissionCatalog.defaultPreset));
      AppStorage.setOrCreate('catalogError', choices.length === 0 ? '主机未配置可用模型，请在主机设置模型与凭据' : '');
    } catch (error) {
      if (generation === this.generation) AppStorage.setOrCreate('catalogError', safeError(error as Error));
    }
  }
  private applySelection(selection: ESObject): void {
    const index = this.models.findIndex((row: ModelChoice): boolean => row.provider === str(selection.provider) && row.id === str(selection.model));
    AppStorage.setOrCreate('modelIndex', index);
    AppStorage.setOrCreate('sessionModel', index >= 0 ? this.models[index].name : str(selection.model) || '未选择模型');
    const model = this.models[index];
    AppStorage.setOrCreate('depthLabels', model ? model.effortNames : []);
    AppStorage.setOrCreate('depthIndex', model ? model.effortIds.indexOf(str(selection.reasoningEffort) || model.defaultEffort) : -1);
  }
  private applyPermission(value: string): void {
    AppStorage.setOrCreate('permissionIndex', this.permissions.findIndex((row: PermissionChoice): boolean => row.id === value));
  }
  private applyProjection(json: string): void {
    const values: ESObject = obj(parseObject(json).values); const selection: ESObject = obj(values.modelSelection);
    if (selection.next || selection.lastUsed) this.applySelection(obj(selection.next || selection.lastUsed));
    if (values.permissions) this.applyPermission(str(obj(values.permissions).currentValue));
  }
  async selectModel(index: number, effortIndex: number = -1): Promise<void> {
    this.requireReady(); const model = this.models[index]; const sessionId = this.selectedSession;
    if (!model || !sessionId) throw new Error('请选择有效会话和模型');
    const generation = this.generation; const epoch = this.chatEpoch;
    const request: SelectRequest = { sessionId: sessionId, provider: model.provider, model: model.id };
    const effort = effortIndex >= 0 ? model.effortIds[effortIndex] : model.defaultEffort;
    if (effort) request.reasoningEffort = effort;
    AppStorage.setOrCreate('selectionBusy', true);
    try {
      const args: SelectArgs = { request: request };
      const value: ESObject = parseObject(await this.client.rpc('session/selectModel', JSON.stringify(args)));
      if (generation === this.generation && epoch === this.chatEpoch) this.applySelection(obj(value.selected));
    } finally { if (generation === this.generation && epoch === this.chatEpoch) AppStorage.setOrCreate('selectionBusy', false); }
  }
  async selectDepth(index: number): Promise<void> { await this.selectModel(AppStorage.get<number>('modelIndex') ?? -1, index); }
  async selectPermission(index: number): Promise<void> {
    this.requireReady(); const permission = this.permissions[index]; const sessionId = this.selectedSession;
    if (!permission || !sessionId || !/^[a-z][a-z-]*$/.test(permission.id)) throw new Error('请选择有效会话与权限预设');
    const generation = this.generation; const epoch = this.chatEpoch;
    const args: CommandArgs = { agentId: sessionId, line: '/permission ' + permission.id, submittedAttachments: [] };
    const value: ESObject = parseObject(await this.client.rpc('commands/execute', JSON.stringify(args)));
    if (obj(value.result).kind !== 'success') throw new Error('主机未接受权限预设');
    if (generation === this.generation && epoch === this.chatEpoch) this.applyPermission(permission.id);
  }
  claimQuestionWait(eventId: string, onRemaining: (remaining: number) => void, onError: (error: Error) => void): string {
    this.requireReady();
    const request = this.pending.find((row: NativeHostEvent): boolean => row.eventId === eventId);
    if (!request || !request.timed || !request.waitCallId) throw new Error('问题等待已失效');
    return this.client.claimQuestionWait(request.sessionId, request.waitCallId, onRemaining, onError);
  }
  releaseQuestionWait(id: string): void { this.client.unfollow(id); }
  async loadHostConfig(section: string): Promise<string> {
    this.requireReady();
    if (section === 'models') return JSON.stringify(parseObject(await this.client.rpc('session/modelCatalog')), null, 2);
    if (section === 'permissions') return JSON.stringify(parseObject(await this.client.rpc('permissionPresets/catalog')), null, 2);
    if (section === 'providers') return await this.client.rpc('llm/listProviders');
    throw new Error('该项主机配置尚未接入，未修改主机');
  }
}
export const appStore: AppStore = new AppStore();
