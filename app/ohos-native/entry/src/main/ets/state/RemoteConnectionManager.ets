import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';
import { RemoteAccount } from '../remote/RemoteAccount';
import { RemoteSessionVault, RemoteRestoredSession } from '../remote/RemoteSessionVault';
import { RemoteRelay } from '../remote/RemoteRelay';
import { RemoteTunnel } from '../remote/RemoteTunnel';
import { DEFAULT_REMOTE_SERVER, RemoteHost } from '../remote/RemoteDtos';
import { normalizeRemoteServer } from '../remote/RemoteServer';
import { checkRemoteCrypto } from '../remote/RemoteCrypto';
import { appStore } from './AppStore';

function stableFailure(error: Error): string {
  return /^[A-Z][A-Z0-9_/-]{0,99}$/.test(error.message) ? error.message : 'REMOTE_CONNECTION_FAILED';
}
function terminalFailure(code: string): boolean {
  return /AUTH|TOKEN|DEVICE_REVOKED|IDENTITY|CONNECTION_REPLACED|SECURE_STORAGE/.test(code);
}

// Owns reconnects independently of a navigation page. Only authentication and
// fresh carriers are retried: prompts, settings writes and approvals never are.
export class RemoteConnectionManager {
  account?: RemoteAccount;
  serverUrl: string = DEFAULT_REMOTE_SERVER;
  lastHostId: string = '';
  private vault: RemoteSessionVault = new RemoteSessionVault();
  private prefs?: preferences.Preferences;
  private initialization?: Promise<void>;
  private generation: number = 0;
  private enabled: boolean = false;
  private opening: boolean = false;
  private pendingEpoch: number = -1;
  private pendingTunnel?: RemoteTunnel;
  private retryTimer: number = -1;
  private retries: number = 0;

  constructor() {
    appStore.onConnectionState = (state: string, code: string): void => {
      if (state === 'disconnected' || (state === 'connecting' && (!this.opening || this.pendingEpoch !== appStore.connectionEpoch))) this.pauseReconnect();
      else if (state === 'error' && this.enabled && !this.opening) {
        const failure: string = code.split(':')[0];
        if (terminalFailure(failure)) { this.enabled = false; this.status('error', failure); }
        else this.schedule();
      }
    };
  }
  initialize(context: common.UIAbilityContext): Promise<void> {
    if (!this.initialization) this.initialization = this.start(context);
    return this.initialization;
  }
  private async start(context: common.UIAbilityContext): Promise<void> {
    try {
      checkRemoteCrypto();
      this.prefs = await preferences.getPreferences(context, { name: 'native-remote-metadata' });
      const server: string = normalizeRemoteServer(String(await this.prefs.get('server', DEFAULT_REMOTE_SERVER)));
      await this.useServer(server);
    } catch (error) { this.status('error', stableFailure(error as Error)); }
  }
  async useServer(server: string): Promise<void> {
    const normalized: string = normalizeRemoteServer(server);
    if (this.account && normalized === this.serverUrl) return;
    this.pauseReconnect();
    const generation: number = ++this.generation;
    this.account?.close(); this.account = undefined; this.lastHostId = ''; this.serverUrl = normalized;
    AppStorage.setOrCreate('remoteServerUrl', normalized);
    let restored: RemoteRestoredSession | undefined = undefined;
    try {
      restored = await this.vault.restore(normalized);
      if (generation === this.generation && AppStorage.get<string>('remoteSessionState')?.indexOf('error:') !== 0) {
        AppStorage.setOrCreate('remoteSessionState', restored ? 'restored' : this.vault.lastRestoreStatus);
      }
    } catch (error) {
      if (generation === this.generation) AppStorage.setOrCreate('remoteSessionState', 'error:' + stableFailure(error as Error));
      throw error as Error;
    }
    if (generation !== this.generation) { restored?.account.close(); return; }
    this.account = restored ? restored.account : new RemoteAccount(normalized);
    this.lastHostId = restored ? restored.lastHostId : '';
    this.bindAccount(this.account);
    if (this.prefs) { await this.prefs.put('server', normalized); await this.prefs.flush(); }
    if (generation !== this.generation) return;
    this.status('idle');
    if (this.account?.session && this.lastHostId) { this.enabled = true; this.retries = 0; this.reconnect(); }
  }
  private bindAccount(account: RemoteAccount): void {
    account.onSessionChanged = async (): Promise<void> => {
      if (this.account !== account) return;
      if (account.session) {
        await this.vault.save(account, this.lastHostId);
        if (this.account === account) AppStorage.setOrCreate('remoteSessionState', 'saved');
      } else {
        this.enabled = false; this.lastHostId = ''; await this.vault.clear(account.serverUrl);
        if (this.account === account) AppStorage.setOrCreate('remoteSessionState', 'signed-out');
      }
    };
  }
  async persist(): Promise<void> {
    const account: RemoteAccount | undefined = this.account;
    if (account?.session) {
      await this.vault.save(account, this.lastHostId);
      if (this.account === account) AppStorage.setOrCreate('remoteSessionState', 'saved');
    }
  }
  async adopt(hostId: string): Promise<void> {
    this.lastHostId = hostId; this.enabled = true; this.retries = 0; this.clearTimer(); this.status('idle');
    await this.persist();
  }
  private clearTimer(): void {
    if (this.retryTimer >= 0) clearTimeout(this.retryTimer);
    this.retryTimer = -1;
  }
  pauseReconnect(): void {
    this.enabled = false; this.generation++; this.clearTimer();
    const pending: number = this.pendingEpoch; this.pendingEpoch = -1;
    const tunnel: RemoteTunnel | undefined = this.pendingTunnel; this.pendingTunnel = undefined;
    this.opening = false;
    if (pending >= 0) appStore.cancelConnection(pending);
    tunnel?.close(); this.status('idle');
  }
  async logout(): Promise<void> {
    this.pauseReconnect();
    const account: RemoteAccount | undefined = this.account;
    // Detach before clearing: a late refresh callback must not recreate the record.
    this.account = undefined;
    try { await this.vault.clear(this.serverUrl); }
    catch (error) { this.account = account; throw error as Error; }
    if (account) { account.onSessionChanged = undefined; await account.logout(); account.close(); }
    this.account = new RemoteAccount(this.serverUrl); this.lastHostId = ''; this.bindAccount(this.account);
    AppStorage.setOrCreate('remoteSessionState', 'signed-out');
    if (AppStorage.get<string>('activeHostAddress') === this.serverUrl) appStore.disconnect();
    this.status('idle');
  }
  resume(): void {
    if (this.enabled && this.account?.session && this.lastHostId && !this.opening && !this.connected()) {
      this.clearTimer(); this.retries = 0; this.reconnect();
    }
  }
  private connected(): boolean {
    return AppStorage.get<string>('connectionState') === 'ready' &&
      AppStorage.get<string>('activeHostId') === 'remote:' + this.lastHostId + '@' + this.serverUrl;
  }
  private status(state: string, code: string = ''): void {
    AppStorage.setOrCreate('remoteReconnectState', state);
    AppStorage.setOrCreate('remoteReconnectError', code);
  }
  private schedule(): void {
    if (!this.enabled || !this.account?.session || !this.lastHostId || this.retryTimer >= 0) return;
    if (this.retries >= 6) { this.status('error', 'RECONNECT_EXHAUSTED'); return; }
    const delay: number = Math.min(30000, 2000 * Math.pow(2, this.retries++));
    this.status('waiting');
    this.retryTimer = setTimeout(() => { this.retryTimer = -1; this.reconnect(); }, delay);
  }
  private async reconnect(): Promise<void> {
    if (!this.enabled || this.opening || !this.account?.session || !this.lastHostId || this.connected()) return;
    const generation: number = this.generation; const account: RemoteAccount = this.account; const hostId: string = this.lastHostId;
    this.opening = true; this.status('connecting');
    let tunnel: RemoteTunnel | undefined = undefined;
    try {
      const hosts = await account.hosts();
      if (generation !== this.generation || account !== this.account) return;
      const host = hosts.find((row: RemoteHost): boolean => row.id === hostId);
      if (!host || !host.online) throw new Error('HOST_OFFLINE');
      if (host.trust !== 'pinned') throw new Error('PEER_IDENTITY_MISMATCH');
      // connectionParameters re-fetches the descriptor and compares it to the pin.
      const parameters = await account.connectionParameters(hostId);
      if (generation !== this.generation || account !== this.account) return;
      tunnel = new RemoteTunnel(new RemoteRelay(parameters, account.identity)); this.pendingTunnel = tunnel;
      // beginConnection publishes synchronously. Claim its expected epoch before that
      // callback so an unrelated direct connection can still cancel this attempt.
      this.pendingEpoch = appStore.connectionEpoch + 1;
      const opening: Promise<void> = appStore.connectCarrier(tunnel, host.name, this.serverUrl, hostId);
      const epoch: number = appStore.connectionEpoch; this.pendingEpoch = epoch;
      await opening;
      if (generation !== this.generation || account !== this.account) { tunnel.close(); return; }
      if (appStore.connectionEpoch !== epoch || !this.connected()) throw new Error('CONNECTION_REPLACED');
      this.pendingEpoch = -1; this.pendingTunnel = undefined; tunnel = undefined;
      this.retries = 0; this.status('idle'); await this.persist();
    } catch (error) {
      tunnel?.close();
      if (generation !== this.generation || account !== this.account) return;
      const code: string = stableFailure(error as Error);
      this.status('error', code);
      if (terminalFailure(code)) this.enabled = false;
      else this.schedule();
    } finally {
      if (generation === this.generation) { this.opening = false; this.pendingEpoch = -1; this.pendingTunnel = undefined; }
    }
  }
}
export const remoteConnectionManager: RemoteConnectionManager = new RemoteConnectionManager();
