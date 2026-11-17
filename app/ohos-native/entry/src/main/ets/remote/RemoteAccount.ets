import { util } from '@kit.ArkTS';
import { RemoteKeyPair } from './RemoteCrypto';
import { base64url, unbase64url, fromHex, equalBytes } from './RemoteBytes';
import { RemoteServer } from './RemoteServer';
import { RemoteApiError, RemoteProvider, RemoteLogin, RemoteTokens, RemoteCredentials,
  RemoteDeviceRegistration, RemoteHost, RemoteHostDescriptor, RemoteConnectParameters,
  parseRemoteTokens, remoteObject, remoteString } from './RemoteDtos';

class LoginState {
  login: RemoteLogin;
  qrId: string;
  epoch: number;
  failure: string = '';
  failureStatus: number = 0;
  failurePhase: string = '';
  complete: boolean = false;
  inFlight?: Promise<boolean>;
  constructor(login: RemoteLogin, qrId: string, epoch: number) {
    this.login = login; this.qrId = qrId; this.epoch = epoch;
  }
}
function authFailure(error: Error): boolean {
  return ['AUTH_INVALID', 'TOKEN_EXPIRED', 'AUTH_REQUIRED', 'ACCOUNT_AUTH_REQUIRED'].indexOf(error.message) >= 0;
}
function checkIdentityKey(key: string): void {
  if (!/^[A-Za-z0-9_-]{43}$/.test(key)) throw new RemoteApiError('INVALID_MESSAGE');
  try {
    const raw = unbase64url(key);
    let nonzero = 0; for (const value of raw) nonzero |= value;
    if (raw.length !== 32 || !nonzero || base64url(raw) !== key) throw new Error('INVALID_MESSAGE');
  } catch (_) { throw new RemoteApiError('INVALID_MESSAGE'); }
}
function credentials(tokens: RemoteTokens, deviceId: string, account: string, provider: string, serverUrl: string): RemoteCredentials {
  const result = new RemoteCredentials();
  result.deviceId = deviceId; result.account = account; result.provider = provider; result.serverUrl = serverUrl;
  result.accessToken = tokens.accessToken; result.accessTokenExpiresAt = tokens.accessTokenExpiresAt;
  result.refreshToken = tokens.refreshToken; result.refreshTokenExpiresAt = tokens.refreshTokenExpiresAt;
  return result;
}

class SecureHostPin {
  hostId: string = '';
  identityKey: string = '';
}
class SecureAccountSnapshot {
  version: number = 1;
  serverUrl: string = '';
  session: RemoteCredentials = new RemoteCredentials();
  privateKey: string = '';
  publicKey: string = '';
  pins: SecureHostPin[] = [];
}

// One server account, identity and trust domain. Secret snapshots are only for the OS vault.
export class RemoteAccount {
  onSessionChanged?: () => Promise<void>;
  readonly serverUrl: string;
  private server: RemoteServer;
  private keyPair?: RemoteKeyPair;
  private deviceId: string = '';
  private current?: RemoteCredentials;
  private closed: boolean = false;
  private epoch: number = 0;
  private authRevision: number = 0;
  private activeLogin?: LoginState;
  private refreshOwner?: RemoteCredentials;
  private refreshing?: Promise<string>;
  private pins: Map<string, string> = new Map();
  private pinnedAccount: string = '';
  private observedKeys: Map<string, string> = new Map();
  private mutationRevision: number = 0;
  private savedRevision: number = 0;
  private saving?: Promise<void>;

  constructor(serverUrl: string) {
    this.server = new RemoteServer(serverUrl); this.serverUrl = this.server.serverUrl;
  }
  get session(): RemoteCredentials | undefined {
    const value = this.current;
    return value ? credentials(value, value.deviceId, value.account, value.provider, value.serverUrl) : undefined;
  }
  get identity(): RemoteKeyPair {
    this.ensureOpen();
    if (!this.keyPair) {
      try { this.keyPair = RemoteKeyPair.generate(); this.deviceId = util.generateRandomUUID(true); }
      catch (_) { this.keyPair?.destroy(); this.keyPair = undefined; throw new RemoteApiError('CRYPTO_UNAVAILABLE'); }
    }
    return this.keyPair;
  }
  // Never pass these serialized secrets to UI state, diagnostics or ordinary preferences.
  exportSecureSnapshot(): string | undefined {
    this.ensureOpen();
    const owner = this.current;
    if (!owner) return undefined;
    if (!this.keyPair) throw new RemoteApiError('CRYPTO_UNAVAILABLE');
    let encoded = new Uint8Array(0);
    let raw = new Uint8Array(0);
    try {
      // getEncoded may return SDK-owned storage; only scrub our own copy.
      encoded = new Uint8Array(this.keyPair.nativeKey.priKey.getEncoded().data);
      if (encoded.length === 32) raw = new Uint8Array(encoded);
      else if (encoded.length === 48 && equalBytes(encoded.slice(0, 16), fromHex('302e020100300506032b656e04220420'))) raw = encoded.slice(16);
      else throw new RemoteApiError('CRYPTO_UNAVAILABLE');
      const snapshot = new SecureAccountSnapshot();
      snapshot.serverUrl = this.serverUrl;
      snapshot.session = credentials(owner, owner.deviceId, owner.account, owner.provider, owner.serverUrl);
      snapshot.privateKey = base64url(raw); snapshot.publicKey = base64url(this.keyPair.publicKey);
      this.pins.forEach((identityKey: string, hostId: string): void => {
        const pin = new SecureHostPin(); pin.hostId = hostId; pin.identityKey = identityKey; snapshot.pins.push(pin);
      });
      return JSON.stringify(snapshot);
    } catch (_) { throw new RemoteApiError('CRYPTO_UNAVAILABLE'); }
    finally { raw.fill(0); encoded.fill(0); }
  }
  restoreSecureSnapshot(serialized: string): void {
    this.ensureOpen();
    if (this.current || this.activeLogin || this.keyPair) throw new RemoteApiError('SECURE_SESSION_INVALID');
    let privateKey = new Uint8Array(0);
    let identity: RemoteKeyPair | undefined;
    try {
      if (typeof serialized !== 'string' || serialized.length > 262144) throw new Error('INVALID');
      const raw: ESObject = remoteObject(JSON.parse(serialized));
      const value: ESObject = remoteObject(raw.session);
      if (raw.version !== 1 || raw.serverUrl !== this.serverUrl || value.serverUrl !== this.serverUrl ||
        !remoteString(value.account) || !remoteString(value.provider) || !remoteString(value.deviceId) ||
        !Array.isArray(raw.pins) || raw.pins.length > 1024) throw new Error('INVALID');
      const tokens = new RemoteTokens();
      tokens.accessToken = value.accessToken; tokens.accessTokenExpiresAt = value.accessTokenExpiresAt;
      tokens.refreshToken = value.refreshToken; tokens.refreshTokenExpiresAt = value.refreshTokenExpiresAt;
      const checked = parseRemoteTokens(tokens);
      if (checked.refreshTokenExpiresAt <= Date.now()) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
      checkIdentityKey(raw.publicKey); checkIdentityKey(raw.privateKey);
      privateKey = unbase64url(raw.privateKey);
      const pins: Map<string, string> = new Map();
      const rawRows: ESObject[] = raw.pins;
      for (let index = 0; index < rawRows.length; index++) {
        const entry: ESObject = rawRows[index];
        const pin: ESObject = remoteObject(entry);
        if (!remoteString(pin.hostId) || pins.has(pin.hostId)) throw new Error('INVALID');
        checkIdentityKey(pin.identityKey); pins.set(pin.hostId, pin.identityKey);
      }
      identity = RemoteKeyPair.fromRaw(privateKey, unbase64url(raw.publicKey));
      this.current = credentials(checked, value.deviceId, value.account, value.provider, this.serverUrl);
      this.keyPair = identity; identity = undefined; this.deviceId = value.deviceId;
      this.pins = pins; this.pinnedAccount = value.account; this.observedKeys.clear(); this.authRevision++;
    } catch (error) {
      identity?.destroy();
      if (error instanceof RemoteApiError && error.code === 'ACCOUNT_AUTH_REQUIRED') throw error;
      throw new RemoteApiError('SECURE_SESSION_INVALID');
    } finally { privateKey.fill(0); }
  }
  private async sessionChanged(): Promise<void> {
    this.mutationRevision++;
    await this.persistSession();
  }
  private async persistSession(): Promise<void> {
    while (this.savedRevision !== this.mutationRevision) {
      this.ensureOpen();
      if (!this.onSessionChanged) { this.savedRevision = this.mutationRevision; return; }
      if (this.saving) { await this.saving; continue; }
      const revision = this.mutationRevision;
      const pending = this.onSessionChanged(); this.saving = pending;
      try { await pending; this.savedRevision = revision; }
      finally { if (this.saving === pending) this.saving = undefined; }
      this.ensureOpen();
    }
  }
  async persistCurrentSession(): Promise<void> {
    this.ensureOpen();
    if (!this.current) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
    await this.sessionChanged();
  }
  async logout(): Promise<void> {
    this.ensureOpen(); this.epoch++; this.authRevision++; this.activeLogin = undefined;
    this.current = undefined; this.pins.clear(); this.pinnedAccount = ''; this.observedKeys.clear();
    this.keyPair?.destroy(); this.keyPair = undefined; this.deviceId = '';
    await this.sessionChanged();
  }
  private ensureOpen(): void { if (this.closed) throw new RemoteApiError('CLIENT_CLOSED'); }
  private checkLogin(state: LoginState): void {
    this.ensureOpen();
    if (this.activeLogin !== state || state.epoch !== this.epoch) throw new RemoteApiError('LOGIN_CANCELLED');
    if (state.failure) {
      const failure = new RemoteApiError(state.failure, state.failureStatus); failure.phase = state.failurePhase; throw failure;
    }
  }
  async loginProviders(): Promise<RemoteProvider[]> {
    this.ensureOpen();
    const result = await this.server.providers(); this.ensureOpen();
    return result.filter((provider: RemoteProvider): boolean => provider.qrStartUrl.length > 0);
  }
  async beginLogin(providerId: string): Promise<RemoteLogin> {
    this.ensureOpen();
    const epoch = ++this.epoch; this.activeLogin = undefined;
    const providers = await this.loginProviders();
    if (this.epoch !== epoch) throw new RemoteApiError('LOGIN_CANCELLED');
    const provider = providers.find((value: RemoteProvider): boolean => value.id === providerId);
    if (!provider) throw new RemoteApiError('OAUTH_PROVIDER_UNAVAILABLE');
    const qr = await this.server.startLogin(provider); this.ensureOpen();
    if (this.epoch !== epoch) throw new RemoteApiError('LOGIN_CANCELLED');
    const login = new RemoteLogin(); login.loginUrl = qr.scanUrl; login.providerId = provider.id;
    login.expiresAt = Date.now() + qr.expiresIn * 1000;
    this.activeLogin = new LoginState(login, qr.qrId, epoch);
    return login;
  }
  pollLogin(login: RemoteLogin): Promise<boolean> {
    try { this.ensureOpen(); } catch (error) { return Promise.reject(error); }
    const state = this.activeLogin;
    if (!state || state.login !== login) return Promise.reject(new RemoteApiError('LOGIN_CANCELLED'));
    if (state.complete) return Promise.resolve(true);
    if (state.inFlight) return state.inFlight;
    const pending = this.poll(state); state.inFlight = pending;
    pending.then(() => { if (state.inFlight === pending) state.inFlight = undefined; },
      () => { if (state.inFlight === pending) state.inFlight = undefined; });
    return pending;
  }
  private async poll(state: LoginState): Promise<boolean> {
    this.checkLogin(state);
    if (Date.now() >= state.login.expiresAt) { state.failure = 'LOGIN_EXPIRED'; throw new RemoteApiError(state.failure); }
    const result = await this.server.pollLogin(state.qrId); this.checkLogin(state);
    if (result.status === 'pending') return false;
    if (result.status === 'expired') { state.failure = 'LOGIN_EXPIRED'; throw new RemoteApiError(state.failure); }
    // The account token is returned once. Never poll/replay that consumed authorization
    // after a registration failure, and never publish a retired/cancelled login.
    let phase: string = 'ACCOUNT_ME';
    try {
      const account = await this.server.accountMe(result.token); this.checkLogin(state);
      phase = 'IDENTITY';
      let identity = this.identity;
      let tokens: RemoteTokens;
      phase = 'REGISTER';
      try { tokens = await this.server.register(this.registration(identity), result.token); }
      catch (error) {
        this.checkLogin(state);
        if (!(error instanceof Error) || ['DEVICE_REVOKED', 'PEER_IDENTITY_MISMATCH'].indexOf(error.message) < 0) throw error as Error;
        // Explicit login is the only identity replacement boundary.
        this.current = undefined; this.keyPair?.destroy(); this.keyPair = undefined;
        identity = this.identity;
        tokens = await this.server.register(this.registration(identity), result.token);
      }
      this.checkLogin(state);
      if (this.pinnedAccount !== account) this.pins.clear();
      this.pinnedAccount = account;
      this.current = credentials(tokens, this.deviceId, account, state.login.providerId, this.serverUrl);
      this.authRevision++; this.observedKeys.clear(); state.qrId = '';
      phase = 'SAVE_SESSION';
      await this.sessionChanged(); this.checkLogin(state); state.complete = true;
      return true;
    } catch (error) {
      const rawFailure: ESObject = remoteObject(error);
      const rawCode: string = remoteString(rawFailure.message);
      const safeCode: string = /^[A-Z][A-Z0-9_]{0,63}$/.test(rawCode) ? rawCode : 'CONNECTION_FAILED';
      const failure: RemoteApiError = error instanceof RemoteApiError ? error : new RemoteApiError(safeCode);
      failure.phase = phase;
      if (this.activeLogin === state && !state.complete) {
        state.failure = failure.code; state.failureStatus = failure.status; state.failurePhase = phase; state.qrId = '';
      }
      throw failure;
    } finally { result.token = ''; }
  }
  private registration(identity: RemoteKeyPair): RemoteDeviceRegistration {
    const result = new RemoteDeviceRegistration(); result.deviceId = this.deviceId;
    result.identityKey = base64url(identity.publicKey); checkIdentityKey(result.identityKey);
    return result;
  }
  cancelLogin(login: RemoteLogin): void {
    const state = this.activeLogin;
    if (state && state.login === login && !state.complete) {
      state.failure = 'LOGIN_CANCELLED'; state.qrId = ''; this.activeLogin = undefined; this.epoch++;
    }
  }
  private async accessToken(force: boolean = false, refusedToken: string = ''): Promise<string> {
    this.ensureOpen(); await this.persistSession(); this.ensureOpen(); const owner = this.current;
    if (!owner) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
    if ((!force || (refusedToken && refusedToken !== owner.accessToken)) && owner.accessTokenExpiresAt > Date.now() + 60000) return owner.accessToken;
    if (this.refreshing && this.refreshOwner === owner) return this.refreshing;
    const pending = this.rotate(owner); this.refreshOwner = owner; this.refreshing = pending;
    pending.then(() => { if (this.refreshing === pending) { this.refreshing = undefined; this.refreshOwner = undefined; } },
      () => { if (this.refreshing === pending) { this.refreshing = undefined; this.refreshOwner = undefined; } });
    return pending;
  }
  private async retire(owner: RemoteCredentials): Promise<void> {
    if (this.current !== owner) return;
    this.current = undefined; this.authRevision++; this.observedKeys.clear();
    await this.sessionChanged();
  }
  private async rotate(owner: RemoteCredentials): Promise<string> {
    if (owner.refreshTokenExpiresAt <= Date.now()) {
      await this.retire(owner);
      throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
    }
    let tokens: RemoteTokens;
    try { tokens = await this.server.refresh(owner.deviceId, owner.refreshToken); }
    catch (error) {
      if (error instanceof RemoteApiError && !error.retryable && error.code !== 'CLIENT_CLOSED' && this.current === owner) {
        await this.retire(owner);
        throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
      }
      throw error as Error;
    }
    this.ensureOpen();
    if (this.current !== owner) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
    const updated = credentials(tokens, owner.deviceId, owner.account, owner.provider, owner.serverUrl);
    this.current = updated;
    await this.sessionChanged();
    if (this.current !== updated) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
    return tokens.accessToken;
  }
  private async authorized<T>(request: (token: string) => Promise<T>): Promise<T> {
    const revision = this.authRevision;
    const token = await this.accessToken();
    this.ensureOpen();
    if (revision !== this.authRevision) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
    try {
      const result = await request(token); this.ensureOpen();
      if (!this.current || revision !== this.authRevision) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
      return result;
    } catch (error) {
      this.ensureOpen();
      if (revision !== this.authRevision) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
      if (error instanceof RemoteApiError && error.code === 'DEVICE_REVOKED') {
        if (this.current) await this.retire(this.current);
        throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
      }
      if (!(error instanceof Error) || !authFailure(error)) throw error as Error;
      const retry = await this.accessToken(true, token);
      if (revision !== this.authRevision) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
      try {
        const result = await request(retry); this.ensureOpen();
        if (!this.current || revision !== this.authRevision) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
        return result;
      } catch (refusal) {
        if (this.current && revision === this.authRevision && refusal instanceof Error &&
          (authFailure(refusal) || refusal.message === 'DEVICE_REVOKED')) await this.retire(this.current);
        throw refusal as Error;
      }
    }
  }
  async descriptor(hostId: string): Promise<RemoteHostDescriptor> {
    this.ensureOpen();
    if (!hostId) throw new RemoteApiError('INVALID_MESSAGE');
    const peer = await this.authorized<RemoteHostDescriptor>((token: string) => this.server.descriptor(token, hostId));
    checkIdentityKey(peer.identityKey); this.observedKeys.set(hostId, peer.identityKey);
    return peer;
  }
  async trustHost(hostId: string, identityKey: string): Promise<void> {
    this.ensureOpen(); checkIdentityKey(identityKey);
    const revision = this.authRevision;
    if (!this.current) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
    if (this.observedKeys.get(hostId) !== identityKey) throw new RemoteApiError('PEER_IDENTITY_MISMATCH');
    const existing = this.pins.get(hostId);
    if (existing && existing !== identityKey) throw new RemoteApiError('PEER_IDENTITY_MISMATCH');
    this.pins.set(hostId, identityKey);
    await this.sessionChanged();
    if (revision !== this.authRevision) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
  }
  async hosts(): Promise<RemoteHost[]> {
    const listings = await this.authorized<RemoteHost[]>((token: string) => this.server.hosts(token));
    const result: RemoteHost[] = [];
    for (const listing of listings) {
      const peer = await this.descriptor(listing.id);
      const pin = this.pins.get(listing.id) || '';
      if (peer.onlineKnown) listing.online = peer.online;
      listing.identityKey = peer.identityKey; listing.pinnedIdentityKey = pin;
      listing.trust = !pin ? 'unpinned' : pin === peer.identityKey ? 'pinned' : 'keyChanged';
      listing.lastSeenAt = peer.lastSeenAt || listing.lastSeenAt;
      listing.harnessVersion = listing.harnessVersion || peer.harnessVersion;
      listing.pluginVersion = listing.pluginVersion || peer.clientVersion;
      result.push(listing);
    }
    return result;
  }
  async connectionParameters(hostId: string): Promise<RemoteConnectParameters> {
    const revision = this.authRevision;
    const peer = await this.descriptor(hostId);
    const pin = this.pins.get(hostId);
    if (!pin) throw new RemoteApiError('HOST_TRUST_REQUIRED');
    if (pin !== peer.identityKey) throw new RemoteApiError('PEER_IDENTITY_MISMATCH');
    if (peer.onlineKnown && !peer.online) throw new RemoteApiError('HOST_OFFLINE');
    const token = await this.accessToken(); this.ensureOpen();
    if (revision !== this.authRevision) throw new RemoteApiError('ACCOUNT_AUTH_REQUIRED');
    const result = new RemoteConnectParameters(); result.serverUrl = this.serverUrl;
    result.controlUrl = this.serverUrl.replace(/^http/, 'ws') + '/ws/v1/connect';
    result.deviceId = this.deviceId; result.accessToken = token; result.hostDeviceId = hostId; result.hostIdentityKey = pin;
    return result;
  }
  close(): void {
    if (this.closed) return;
    this.closed = true; this.epoch++; this.activeLogin = undefined; this.current = undefined;
    this.pins.clear(); this.observedKeys.clear(); this.server.close();
    this.keyPair?.destroy(); this.keyPair = undefined; this.deviceId = '';
  }
}
