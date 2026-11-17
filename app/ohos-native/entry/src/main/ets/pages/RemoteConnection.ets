import common from '@ohos.app.ability.common';
import { BusinessError } from '@kit.BasicServicesKit';
import { RemoteAccount } from '../remote/RemoteAccount';
import { DEFAULT_REMOTE_SERVER, RemoteProvider, RemoteLogin, RemoteHost, RemoteApiError } from '../remote/RemoteDtos';
import { normalizeRemoteServer } from '../remote/RemoteServer';
import { checkRemoteCrypto, fingerprint } from '../remote/RemoteCrypto';
import { RemoteRelay } from '../remote/RemoteRelay';
import { RemoteTunnel } from '../remote/RemoteTunnel';
import { appStore } from '../state/AppStore';
import { DetailTitle } from '../components/DetailTitle';
import { GAP_CARD, GAP_LARGE, GAP_NORMAL, MARGIN_EDGE, RADIUS_CARD, titleBarOptions } from '../common/Style';

import { remoteConnectionManager } from '../state/RemoteConnectionManager';

// The coordinator owns account recovery and transport reconnects across page lifetimes.
// Account secrets live in the system vault; AppStorage contains status/metadata only.

function localCode(error: Error): string {
  const prefix: string = error.message.split(':')[0];
  if (/^[A-Z][A-Z0-9_/-]{1,63}$/.test(prefix)) {
    const status: number = (error as RemoteApiError).status;
    const code: string = Number.isSafeInteger(status) && status >= 100 && status <= 599 ? prefix + '_HTTP_' + status : prefix;
    const phase: string = (error as RemoteApiError).phase;
    return typeof phase === 'string' && /^[A-Z_]{1,20}$/.test(phase) ? code + '_AT_' + phase : code;
  }
  if (/^[A-Z][A-Z0-9_]{0,63}$/.test(error.message)) return error.message;
  const system = (error as BusinessError).code;
  if (typeof system === 'number' && Number.isSafeInteger(system) && system > 0) return 'SYSTEM_' + system;
  return 'CONNECTION_FAILED';
}
function hostState(host: RemoteHost): string {
  if (host.trust === 'keyChanged') return '身份密钥已变化';
  if (!host.online) return '离线';
  return host.trust === 'pinned' ? '在线 · 已信任' : '在线 · 尚未信任';
}

@Component
export struct RemoteConnection {
  stack: NavPathStack = new NavPathStack();
  @StorageLink('connectionState') connectionState: string = '';
  @StorageLink('activeHostId') activeHostId: string = '';
  @StorageLink('activeHostAddress') activeHostAddress: string = '';
  @StorageLink('activeHostName') activeHostName: string = '';
  @StorageLink('bottomSafe') bottomSafe: number = 0;
  @StorageLink('topSafe') topSafe: number = 28;
  @State serverInput: string = DEFAULT_REMOTE_SERVER;
  @State cryptoReady: boolean = false;
  @State providers: RemoteProvider[] = [];
  @State providerIndex: number = 0;
  @State providersLoading: boolean = false;
  @State accountName: string = '';
  @State accountProvider: string = '';
  @State hosts: RemoteHost[] = [];
  @State hostsLoading: boolean = false;
  @State waitingLogin: boolean = false;
  @State launchingLogin: boolean = false;
  @State savingLogin: boolean = false;
  @State connecting: boolean = false;
  @State connectingHostId: string = '';
  @State errorCode: string = '';
  private alive: boolean = false;
  private viewEpoch: number = 0;
  private pollTimer: number = -1;
  private hostRetryTimer: number = -1;
  private hostRetries: number = 0;
  private pendingLogin?: RemoteLogin;
  private pendingAccount?: RemoteAccount;
  private pendingTunnel?: RemoteTunnel;
  private pendingConnectionEpoch: number = -1;
  private confirmTrust?: (accepted: boolean) => void;
  private autoConnectPending: boolean = false;
  @StorageLink('remoteReconnectState') reconnectState: string = '';
  @StorageLink('remoteReconnectError') reconnectError: string = '';
  @StorageLink('remoteSessionState') @Watch('restoreAccount') sessionState: string = '';

  aboutToAppear(): void { this.activate(); }
  aboutToDisappear(): void { this.deactivate(); this.stopWork(); }

  private async activate(): Promise<void> {
    if (this.alive) return;
    this.alive = true; this.viewEpoch++; this.errorCode = ''; this.cryptoReady = false;
    const epoch: number = this.viewEpoch;
    try { checkRemoteCrypto(); this.cryptoReady = true; }
    catch (error) { this.errorCode = localCode(error as Error); return; }
    try {
      await remoteConnectionManager.initialize(getContext(this) as common.UIAbilityContext);
      if (!this.alive || this.viewEpoch !== epoch) return;
      const server: string = AppStorage.get<string>('remoteServerUrl') || remoteConnectionManager.serverUrl;
      await remoteConnectionManager.useServer(server);
      if (!this.alive || this.viewEpoch !== epoch) return;
      this.serverInput = remoteConnectionManager.serverUrl;
      this.restoreAccount();
      // A browser authorization always hides this page; resume its polling instead of restarting.
      if (this.pendingLogin && this.pendingAccount) {
        this.waitingLogin = true;
        this.schedulePoll(this.pendingAccount, this.pendingLogin, this.viewEpoch);
      } else if (this.accountName) this.refreshHosts(); else this.loadProviders();
    } catch (error) { this.errorCode = localCode(error as Error); }
  }
  private current(epoch: number, account: RemoteAccount): boolean {
    return this.alive && this.viewEpoch === epoch && remoteConnectionManager.account === account;
  }
  private restoreAccount(): void {
    const session = remoteConnectionManager.account?.session;
    this.accountName = session ? session.account : '';
    this.accountProvider = session ? session.provider : '';
  }
  private stopWork(cancelPendingLogin: boolean = true): void {
    this.viewEpoch++;
    if (this.pollTimer >= 0) clearTimeout(this.pollTimer);
    this.pollTimer = -1;
    if (this.hostRetryTimer >= 0) clearTimeout(this.hostRetryTimer);
    this.hostRetryTimer = -1; this.hostRetries = 0;
    const login = this.pendingLogin; const account = this.pendingAccount;
    if (cancelPendingLogin) {
      if (login && account) account.cancelLogin(login);
      this.pendingLogin = undefined; this.pendingAccount = undefined; this.waitingLogin = false;
    }
    const resolve = this.confirmTrust; this.confirmTrust = undefined; resolve?.(false);
    if (this.pendingConnectionEpoch >= 0) appStore.cancelConnection(this.pendingConnectionEpoch);
    this.pendingConnectionEpoch = -1;
    this.pendingTunnel?.close(); this.pendingTunnel = undefined;
    this.launchingLogin = false; this.connecting = false;
    this.connectingHostId = ''; this.providersLoading = false; this.hostsLoading = false;
  }
  private deactivate(): void {
    if (!this.alive) return;
    this.alive = false; this.stopWork(false);
  }
  private disconnectOwnedAccount(): void {
    if (this.activeHostId.startsWith('remote:') && this.activeHostAddress === remoteConnectionManager.serverUrl) appStore.disconnect();
  }
  private async applyServer(): Promise<void> {
    if (!this.alive || !this.cryptoReady || this.connecting) return;
    try {
      const origin = normalizeRemoteServer(this.serverInput);
      this.stopWork(); this.errorCode = '';
      const epoch: number = this.viewEpoch;
      if (origin !== remoteConnectionManager.serverUrl) this.disconnectOwnedAccount();
      await remoteConnectionManager.useServer(origin);
      if (!this.alive || this.viewEpoch !== epoch) return;
      this.serverInput = origin; this.hosts = []; this.providers = []; this.providerIndex = 0;
      this.restoreAccount();
      if (this.accountName) this.refreshHosts(); else this.loadProviders();
    } catch (error) { this.errorCode = localCode(error as Error); }
  }
  private async loadProviders(): Promise<void> {
    const account = remoteConnectionManager.account; const epoch = this.viewEpoch;
    if (!account || !this.alive || !this.cryptoReady || this.providersLoading) return;
    this.providersLoading = true; this.errorCode = '';
    try {
      const providers = await account.loginProviders();
      if (!this.current(epoch, account)) return;
      this.providers = providers; this.providerIndex = 0;
      if (!providers.length) this.errorCode = 'OAUTH_PROVIDER_UNAVAILABLE';
    } catch (error) { if (this.current(epoch, account)) this.errorCode = localCode(error as Error); }
    finally { if (this.current(epoch, account)) this.providersLoading = false; }
  }
  private providerOptions(): SelectOption[] {
    return this.providers.map((provider: RemoteProvider): SelectOption => ({ value: provider.displayName }));
  }
  private async login(): Promise<void> {
    const account = remoteConnectionManager.account; const epoch = this.viewEpoch;
    if (!account || !this.alive || !this.cryptoReady || this.launchingLogin || this.waitingLogin || this.connecting) return;
    const provider = this.providers[this.providerIndex];
    if (!provider) { this.errorCode = 'OAUTH_PROVIDER_UNAVAILABLE'; return; }
    this.launchingLogin = true; this.errorCode = '';
    let login: RemoteLogin | undefined = undefined;
    let phase: string = 'AUTHORIZE_START';
    try {
      login = await account.beginLogin(provider.id);
      if (!this.current(epoch, account)) { account.cancelLogin(login); return; }
      this.pendingLogin = login; this.pendingAccount = account; this.waitingLogin = true;
      const context = getContext(this) as common.UIAbilityContext;
      // Only the system browser receives this URL. It is never rendered, logged or stored.
      phase = 'OPEN_BROWSER';
      await context.openLink(login.loginUrl);
      // openLink always hides this page; the login survives that. Only a login the
      // page replaced or cancelled (pendingLogin no longer this one) is discarded.
      if (this.pendingLogin !== login || this.pendingAccount !== account) { account.cancelLogin(login); return; }
      this.schedulePoll(account, login, epoch);
    } catch (error) {
      if (login) account.cancelLogin(login);
      if (this.current(epoch, account)) {
        this.errorCode = phase + '_' + localCode(error as Error); this.waitingLogin = false;
        this.pendingLogin = undefined; this.pendingAccount = undefined;
      }
    } finally { if (this.current(epoch, account)) this.launchingLogin = false; }
  }
  private schedulePoll(account: RemoteAccount, login: RemoteLogin, epoch: number): void {
    if (!this.current(epoch, account) || this.pendingLogin !== login) return;
    if (this.pollTimer >= 0) clearTimeout(this.pollTimer);
    this.pollTimer = setTimeout(() => {
      this.pollTimer = -1; this.poll(account, login, epoch);
    }, 2000);
  }
  private async poll(account: RemoteAccount, login: RemoteLogin, epoch: number): Promise<void> {
    if (!this.current(epoch, account) || this.pendingLogin !== login) return;
    try {
      const complete = await account.pollLogin(login);
      if (!this.current(epoch, account) || this.pendingLogin !== login) return;
      if (!complete) { this.schedulePoll(account, login, epoch); return; }
      this.waitingLogin = false; this.pendingLogin = undefined; this.pendingAccount = undefined;
      this.errorCode = ''; this.restoreAccount(); this.autoConnectPending = true; await this.refreshHosts();
    } catch (error) {
      if (!this.current(epoch, account) || this.pendingLogin !== login) return;
      this.errorCode = localCode(error as Error);
      if ((error as RemoteApiError).retryable === true && Date.now() < login.expiresAt) {
        this.schedulePoll(account, login, epoch);
      } else {
        account.cancelLogin(login); this.pendingLogin = undefined; this.pendingAccount = undefined; this.waitingLogin = false;
        this.restoreAccount();
      }
    }
  }
  private async retrySessionSave(): Promise<void> {
    const account = remoteConnectionManager.account; const epoch: number = this.viewEpoch;
    if (!account?.session || !this.current(epoch, account) || this.savingLogin || this.connecting) return;
    this.savingLogin = true; this.errorCode = '';
    try {
      await account.persistCurrentSession();
      if (!this.current(epoch, account)) return;
      this.restoreAccount(); this.autoConnectPending = true; await this.refreshHosts();
    } catch (error) { if (this.current(epoch, account)) this.errorCode = 'SAVE_SESSION_' + localCode(error as Error); }
    finally { if (this.current(epoch, account)) this.savingLogin = false; }
  }
  private cancelLogin(): void {
    // Retire callbacks as well as the timer: a previous openLink completion must
    // never clear or restart a subsequently requested authorization.
    this.stopWork(); this.errorCode = '';
  }
  private async refreshHosts(): Promise<void> {
    const account = remoteConnectionManager.account; const epoch = this.viewEpoch;
    if (!account || !this.alive || !this.cryptoReady || !account.session || this.hostsLoading || this.connecting) return;
    if (this.hostRetryTimer >= 0) clearTimeout(this.hostRetryTimer);
    this.hostRetryTimer = -1;
    this.hostsLoading = true; this.errorCode = '';
    try {
      const hosts = await account.hosts();
      if (this.current(epoch, account)) { this.hosts = hosts; this.hostRetries = 0; this.restoreAccount(); }
    } catch (error) {
      if (this.current(epoch, account)) {
        this.errorCode = localCode(error as Error); this.restoreAccount();
        // Directory reads are safe to retry; OAuth registration and RPC writes are not replayed.
        if ((error as RemoteApiError).retryable === true && account.session && this.hostRetries < 3) {
          const delay: number = 2000 * Math.pow(2, this.hostRetries++);
          this.hostRetryTimer = setTimeout(() => {
            this.hostRetryTimer = -1;
            if (this.current(epoch, account)) this.refreshHosts();
          }, delay);
        }
      }
    } finally { if (this.current(epoch, account)) this.hostsLoading = false; }
    if (!this.current(epoch, account) || this.errorCode) return;
    const target: string = AppStorage.get<string>('remoteTargetHostId') || '';
    const online: RemoteHost[] = this.hosts.filter((host: RemoteHost): boolean => host.online);
    const candidate: RemoteHost | undefined = target ? this.hosts.find((host: RemoteHost): boolean => host.id === target) :
      (this.autoConnectPending && online.length === 1 ? online[0] : undefined);
    this.autoConnectPending = false;
    if (target) AppStorage.setOrCreate('remoteTargetHostId', '');
    if (candidate) await this.connectHost(candidate);
  }
  private async logout(): Promise<void> {
    if (!this.alive || this.connecting) return;
    this.stopWork(); this.errorCode = '';
    const epoch: number = this.viewEpoch;
    try {
      await remoteConnectionManager.logout();
      if (!this.alive || this.viewEpoch !== epoch) return;
      this.hosts = []; this.providers = []; this.accountName = ''; this.accountProvider = '';
      if (this.cryptoReady) this.loadProviders();
    } catch (error) { if (this.alive && this.viewEpoch === epoch) this.errorCode = localCode(error as Error); }
  }
  private connectedTo(hostId: string): boolean {
    return this.connectionState === 'ready' && this.activeHostId === 'remote:' + hostId + '@' + remoteConnectionManager.serverUrl;
  }
  private ownConnectionReady(): boolean {
    return this.connectionState === 'ready' && this.activeHostId.startsWith('remote:') && this.activeHostAddress === remoteConnectionManager.serverUrl;
  }
  private async askTrust(host: RemoteHost, publicKey: string, account: RemoteAccount, epoch: number): Promise<boolean> {
    const display = fingerprint(publicKey).replace(/(.{4})(?=.)/g, '$1 ');
    return new Promise<boolean>((resolve) => {
      let settled = false;
      const finish = (accepted: boolean): void => {
        if (settled) return;
        settled = true; this.confirmTrust = undefined;
        resolve(accepted && this.current(epoch, account));
      };
      this.confirmTrust = finish;
      this.getUIContext().showAlertDialog({
        title: '核验主机身份',
        message: '主机：' + host.name + '\n指纹：' + display +
          '\n\n请与主机端显示的指纹核对。一致后才信任；确认的身份会安全保存，密钥变化时仍会阻止连接。',
        primaryButton: { value: '取消', action: () => finish(false) },
        secondaryButton: { value: '核验一致，保存信任', action: () => finish(true) },
        cancel: () => finish(false)
      });
    });
  }
  private async connectHost(host: RemoteHost): Promise<void> {
    const account = remoteConnectionManager.account; const epoch = this.viewEpoch;
    if (!account || !this.alive || !this.cryptoReady || this.connecting || this.waitingLogin || this.connectedTo(host.id)) return;
    if (host.trust === 'keyChanged') { this.errorCode = 'PEER_IDENTITY_MISMATCH'; return; }
    if (!host.online) { this.errorCode = 'HOST_OFFLINE'; return; }
    remoteConnectionManager.pauseReconnect();
    this.connecting = true; this.connectingHostId = host.id; this.errorCode = '';
    let tunnel: RemoteTunnel | undefined = undefined;
    try {
      const peer = await account.descriptor(host.id);
      if (!this.current(epoch, account)) return;
      if (peer.onlineKnown && !peer.online) throw new Error('HOST_OFFLINE');
      if (host.pinnedIdentityKey && host.pinnedIdentityKey !== peer.identityKey) throw new Error('PEER_IDENTITY_MISMATCH');
      if (host.trust !== 'pinned' || host.identityKey !== peer.identityKey) {
        if (!await this.askTrust(host, peer.identityKey, account, epoch)) return;
        if (!this.current(epoch, account)) return;
        await account.trustHost(host.id, peer.identityKey);
        if (!this.current(epoch, account)) return;
        host.trust = 'pinned'; host.pinnedIdentityKey = peer.identityKey; host.identityKey = peer.identityKey;
        this.hosts = this.hosts.slice();
      }
      const parameters = await account.connectionParameters(host.id);
      if (!this.current(epoch, account)) return;
      tunnel = new RemoteTunnel(new RemoteRelay(parameters, account.identity));
      this.pendingTunnel = tunnel;
      const opening = appStore.connectCarrier(tunnel, peer.name, account.serverUrl, host.id);
      const connectionEpoch = appStore.connectionEpoch;
      this.pendingConnectionEpoch = connectionEpoch;
      await opening;
      if (!this.current(epoch, account)) { tunnel.close(); return; }
      if (appStore.connectionEpoch !== connectionEpoch || !this.connectedTo(host.id)) throw new Error('CONNECTION_REPLACED');
      // A successful carrier belongs to Store. Leaving this page must not cancel it.
      this.pendingConnectionEpoch = -1; this.pendingTunnel = undefined; tunnel = undefined;
      await remoteConnectionManager.adopt(host.id);
    } catch (error) {
      tunnel?.close();
      if (this.current(epoch, account)) this.errorCode = localCode(error as Error);
    } finally {
      if (this.current(epoch, account)) {
        this.pendingConnectionEpoch = -1;
        if (this.pendingTunnel === tunnel) this.pendingTunnel = undefined;
        this.connecting = false; this.connectingHostId = '';
      }
    }
  }
  private conversations(): void {
    if (!this.ownConnectionReady() || this.connecting) return;
    this.stack.pop(); AppStorage.setOrCreate('selectedTab', 1);
  }

  private sessionStatusText(): string {
    if (this.sessionState === 'saved') return '登录已安全保存，可在重启后恢复。';
    if (this.sessionState === 'restored') return '已从系统安全存储恢复登录。';
    if (this.sessionState === 'expired') return '保存的授权已过期，请重新登录。';
    if (this.sessionState.startsWith('error:')) return '安全登录恢复未完成：' + this.sessionState.substring(6);
    if (this.sessionState === 'empty') return '此服务器尚无可恢复的登录。';
    if (this.sessionState === 'signed-out') return '已清除保存的登录。';
    return '授权成功后会保存登录，安全存储失败会明确提示。';
  }

  @Builder
  serverCard() {
    Column({ space: GAP_NORMAL }) {
      Text('远程服务器').fontSize(18).fontWeight(FontWeight.Medium)
      TextInput({ text: this.serverInput, placeholder: 'HTTPS 服务器地址' })
        .enabled(this.cryptoReady && !this.connecting && !this.launchingLogin)
        .onChange((value: string) => { this.serverInput = value; })
      Button('应用服务器地址').width('100%').backgroundColor($r('app.color.accent'))
        .enabled(this.cryptoReady && !this.connecting && !this.launchingLogin)
        .onClick(() => this.applyServer())
      Text('每个服务器分别保存授权。切换服务器会断开当前连接；已有授权可直接恢复，退出登录才会清除它。')
        .fontSize(12).fontColor($r('app.color.text_secondary'))
    }.alignItems(HorizontalAlign.Start).width('100%').padding(MARGIN_EDGE)
    .backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
  }
  @Builder
  accountCard() {
    Column({ space: GAP_NORMAL }) {
      Text('账号授权').fontSize(18).fontWeight(FontWeight.Medium)
      if (this.accountName) {
        Text(this.accountName).fontSize(16).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('授权方式：' + this.accountProvider).fontSize(13).fontColor($r('app.color.text_secondary'))
        Button('退出登录').enabled(!this.connecting).onClick(() => this.logout())
      } else {
        if (this.providersLoading) {
          Row({ space: GAP_NORMAL }) {
            LoadingProgress().width(24).height(24)
            Text('正在读取登录方式…').fontSize(14)
          }
        } else if (this.providers.length > 0) {
          Select(this.providerOptions()).selected(this.providerIndex)
            .value(this.providers[this.providerIndex]?.displayName || '选择授权方式')
            .enabled(this.cryptoReady && !this.waitingLogin && !this.launchingLogin)
            .onSelect((index: number) => { this.providerIndex = index; })
          Button(this.launchingLogin ? '正在打开系统浏览器…' : '使用系统浏览器授权')
            .width('100%').backgroundColor($r('app.color.accent'))
            .enabled(this.cryptoReady && !this.waitingLogin && !this.launchingLogin)
            .onClick(() => { this.login(); })
        } else {
          Text('此服务器暂无可用的浏览器授权方式。').fontSize(14).fontColor($r('app.color.text_secondary'))
          Button('重新读取登录方式').enabled(this.cryptoReady).onClick(() => { this.loadProviders(); })
        }
        if (this.waitingLogin) {
          Row({ space: GAP_NORMAL }) {
            LoadingProgress().width(24).height(24).color($r('app.color.accent'))
            Text('请在系统浏览器完成授权，返回后会自动读取结果。').fontSize(13).layoutWeight(1)
          }
          Button('取消本次授权').onClick(() => this.cancelLogin())
        }
      }
      Text(this.sessionStatusText()).fontSize(12).fontColor($r('app.color.text_secondary'))
      if (this.accountName && this.sessionState !== 'saved' && this.sessionState !== 'restored') {
        Button(this.savingLogin ? '正在安全保存…' : '重试安全保存').width('100%')
          .enabled(!this.savingLogin && !this.connecting && !this.waitingLogin).onClick(() => this.retrySessionSave())
      }
      Text('登录和已核验身份由系统安全凭据存储保护。重启后自动恢复上次主机；授权过期或撤销后需重新登录。退出登录会清除保存的授权。')
        .fontSize(12).fontColor($r('app.color.text_secondary'))
    }.alignItems(HorizontalAlign.Start).width('100%').padding(MARGIN_EDGE)
    .backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
  }
  @Builder
  hostCard(host: RemoteHost) {
    Column({ space: GAP_NORMAL }) {
      Row({ space: GAP_NORMAL }) {
        Text(host.name).fontSize(17).fontWeight(FontWeight.Medium).layoutWeight(1)
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.connectedTo(host.id) ? '已连接' : hostState(host)).fontSize(12)
          .fontColor(host.trust === 'keyChanged' ? $r('app.color.danger') :
            (host.online ? $r('app.color.success') : $r('app.color.text_secondary')))
      }.width('100%')
      Text(host.platform).fontSize(13).fontColor($r('app.color.text_secondary'))
      if (host.trust === 'keyChanged') {
        Text('主机身份与已确认的密钥不同。连接已禁用，请先核验主机端身份；不会自动覆盖信任。')
          .fontSize(13).fontColor($r('app.color.danger'))
      }
      Button(this.connectedTo(host.id) ? '当前已连接' : (this.connectingHostId === host.id ? '正在连接…' : '连接主机'))
        .width('100%').backgroundColor($r('app.color.accent'))
        .enabled(this.cryptoReady && host.online && host.trust !== 'keyChanged' && !this.connecting && !this.waitingLogin && !this.connectedTo(host.id))
        .onClick(() => { this.connectHost(host); })
    }.alignItems(HorizontalAlign.Start).width('100%').padding(MARGIN_EDGE)
    .backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
  }
  @Builder detailTitle() {
    DetailTitle({ stack: this.stack, title: '远程连接', onBack: () => { this.deactivate(); this.stopWork(); this.stack.pop(); } })
  }
  build() {
    NavDestination() {
      Scroll() {
        Column({ space: GAP_CARD }) {
          Row().height(this.topSafe + 64)
          Text('通过账号连接 DSH Remote 主机').fontSize(21).fontWeight(FontWeight.Bold).width('100%')
          Text('此入口仅支持 Relay 中继；连接建立后，主机与手机之间使用 Noise 端到端加密。')
            .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
          if (!this.cryptoReady) {
            Text('平台加密自检未通过，远程登录与连接已禁用。')
              .fontSize(14).fontColor($r('app.color.danger')).width('100%')
          }
          if (this.errorCode) {
            Text('操作未完成：' + this.errorCode).fontSize(14).fontColor($r('app.color.danger')).width('100%')
          }
          this.serverCard()
          this.accountCard()
          if (this.accountName) {
            Row() {
              Text('可连接主机').fontSize(18).fontWeight(FontWeight.Medium).layoutWeight(1)
              Button(this.hostsLoading ? '刷新中…' : '刷新').enabled(!this.hostsLoading && !this.connecting)
                .onClick(() => { this.refreshHosts(); })
            }.width('100%')
            if (this.hostsLoading) {
              LoadingProgress().width(32).height(32)
            } else if (!this.hosts.length) {
              Text('账号下暂无主机。请先在电脑启用 DSH Remote 并登录同一账号，再刷新。')
                .fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
            }
            ForEach(this.hosts, (host: RemoteHost) => { this.hostCard(host) }, (host: RemoteHost) => host.id)
          }
          if (this.ownConnectionReady()) {
            Text('已连接：' + this.activeHostName).fontSize(15).fontColor($r('app.color.success')).width('100%')
            Button('查看对话').width('100%').backgroundColor($r('app.color.accent'))
              .enabled(!this.connecting).onClick(() => this.conversations())
          }
          Row().height(this.bottomSafe + GAP_LARGE)
        }.width('100%').padding(MARGIN_EDGE).alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%').scrollBar(BarState.Off)
    }
    .title({ builder: this.detailTitle, height: this.topSafe + 64 }, titleBarOptions()).hideBackButton(true)
    .backgroundColor($r('app.color.bg'))
    .onShown(() => this.activate())
    .onHidden(() => this.deactivate())
    .onBackPressed(() => { this.deactivate(); this.stack.pop(); return true; })
  }
}
