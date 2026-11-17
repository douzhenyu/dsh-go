import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import url from '@ohos.url';
import { text } from './RemoteBytes';
import { RemoteApiError, RemoteProvider, RemoteQrSession, RemoteQrResult, RemoteTokens,
  RemoteDeviceRegistration, RemoteHostDescriptor, RemoteHost, parseRemoteTokens,
  remoteObject, remoteString, remoteInteger } from './RemoteDtos';

interface RegisterArgs { v: number; device: RemoteDeviceRegistration; }
interface RefreshArgs { deviceId: string; refreshToken: string; }
interface RequestHeaders { Accept: string; 'Content-Type': string; Authorization?: string; }
class PendingRequest {
  request: http.HttpRequest;
  cancel: () => void = () => {};
  constructor(request: http.HttpRequest) { this.request = request; }
}
function privateHost(host: string): boolean {
  const name = host.toLowerCase().replace(/^\[|\]$/g, '');
  if (name === 'localhost' || name.endsWith('.localhost') || name.endsWith('.local') || name.endsWith('.test')) return true;
  if (name.indexOf(':') >= 0) {
    return name.replace(/:/g, '').replace(/^0+/, '') === '1' || /^(fc|fd)[0-9a-f]{0,2}:/.test(name) || /^fe[89ab][0-9a-f]:/.test(name);
  }
  const parts: string[] = name.split('.');
  if (parts.length !== 4 || parts.some((part: string): boolean => !/^\d{1,3}$/.test(part) || Number(part) > 255)) return false;
  const a = Number(parts[0]); const b = Number(parts[1]);
  return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
    (a === 169 && b === 254) || (a === 100 && b >= 64 && b <= 127);
}
export function normalizeRemoteServer(value: string): string {
  let input = value.trim();
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(input)) input = 'https://' + input;
  try {
    if (/[\u0000-\u0020\u007f\\]/.test(input)) throw new Error('INVALID_URL');
    const parsed = new url.URL(input);
    if (!parsed.hostname || parsed.username || parsed.password || parsed.search || parsed.hash ||
      (parsed.pathname !== '' && parsed.pathname !== '/') ||
      (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && privateHost(parsed.hostname)))) throw new Error('INVALID_URL');
    return parsed.origin;
  } catch (_) { throw new RemoteApiError('INVALID_URL'); }
}
function authPath(value: string): boolean {
  return value.startsWith('/api/v1/auth/') && !/[\u0000-\u0020\u007f\\#]/.test(value) &&
    !value.split('?')[0].split('/').some((part: string): boolean => part === '.' || part === '..' || part.includes('%'));
}
function statusCode(status: number): string {
  if (status === 401) return 'AUTH_INVALID';
  if (status === 403) return 'AUTH_REQUIRED';
  if (status === 404) return 'DEVICE_NOT_FOUND';
  if (status === 409) return 'DEVICE_OWNERSHIP_REQUIRED';
  if (status === 429) return 'RATE_LIMITED';
  return status >= 500 ? 'CONNECTION_FAILED' : 'INVALID_MESSAGE';
}

function networkFailure(error: BusinessError): RemoteApiError {
  // Never copy NetworkKit messages: they can include a credential-bearing URL.
  const code: number = error && Number.isSafeInteger(error.code) && error.code > 0 ? error.code : 0;
  return new RemoteApiError(code ? 'NETWORK_' + code : 'NETWORK_FAILED', 0, true);
}

// Native REST only: bearer credentials stay in request headers and memory.
export class RemoteServer {
  readonly serverUrl: string;
  private closed: boolean = false;
  private pending: Set<PendingRequest> = new Set();
  constructor(serverUrl: string) { this.serverUrl = normalizeRemoteServer(serverUrl); }

  private request(method: string, path: string, body: ESObject = undefined, token: string = ''): Promise<ESObject> {
    if (this.closed) return Promise.reject(new RemoteApiError('CLIENT_CLOSED'));
    if (!path.startsWith('/') || path.startsWith('//') || /[\u0000-\u0020\u007f\\#]/.test(path) || /[\r\n]/.test(token)) {
      return Promise.reject(new RemoteApiError('INVALID_MESSAGE'));
    }
    const destination = new url.URL(path, this.serverUrl);
    if (destination.origin !== this.serverUrl) return Promise.reject(new RemoteApiError('INVALID_MESSAGE'));
    return new Promise<ESObject>((resolve, reject) => {
      let nativeRequest: http.HttpRequest;
      try { nativeRequest = http.createHttp(); }
      catch (_) { reject(new RemoteApiError('CONNECTION_FAILED', 0, true)); return; }
      const active = new PendingRequest(nativeRequest);
      this.pending.add(active);
      let settled = false;
      let deadline: number = -1;
      const finish = (error?: RemoteApiError, value: ESObject = undefined): void => {
        if (settled) return;
        settled = true; clearTimeout(deadline); this.pending.delete(active); active.request.destroy();
        if (error) reject(error); else resolve(value);
      };
      active.cancel = () => finish(new RemoteApiError('CLIENT_CLOSED'));
      deadline = setTimeout(() => finish(new RemoteApiError('REQUEST_TIMEOUT', 0, true)), 12000);
      const headers: RequestHeaders = { Accept: 'application/json', 'Content-Type': 'application/json' };
      if (token) headers.Authorization = 'Bearer ' + token;
      const options: http.HttpRequestOptions = {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers, expectDataType: http.HttpDataType.STRING, maxRedirects: 0,
        usingCache: false, connectTimeout: 10000, readTimeout: 10000
      };
      if (body !== undefined) options.extraData = JSON.stringify(body);
      try {
        active.request.request(destination.toString(), options, (error: BusinessError, response: http.HttpResponse) => {
          if (settled) return;
          if ((error && error.code !== 0) || !response) { finish(networkFailure(error)); return; }
          const status = response.responseCode;
          let encoded: string = '';
          let value: ESObject = undefined;
          try {
            if (typeof response.result === 'string') encoded = response.result;
            else if (response.result instanceof ArrayBuffer) encoded = text(new Uint8Array(response.result));
            else throw new Error('INVALID_MESSAGE');
            if (encoded.length > 4 * 1024 * 1024) throw new Error('INVALID_MESSAGE');
            if (encoded) value = JSON.parse(encoded);
          } catch (_) {
            if (status >= 200 && status < 300) { finish(new RemoteApiError('INVALID_MESSAGE', status)); return; }
          }
          if (status >= 200 && status < 300) { finish(undefined, value); return; }
          const failure: ESObject = remoteObject(remoteObject(value).error);
          const code = remoteString(failure.code) || remoteString(remoteObject(value).code);
          finish(new RemoteApiError(/^[A-Z][A-Z0-9_]{0,63}$/.test(code) ? code : statusCode(status), status,
            failure.retryable === true || status >= 500 || status === 429));
        });
      } catch (_) { finish(new RemoteApiError('CONNECTION_FAILED', 0, true)); }
    });
  }
  async providers(): Promise<RemoteProvider[]> {
    let response: ESObject;
    try { response = await this.request('GET', '/api/v1/auth/oauth/providers'); }
    catch (error) {
      if (!(error instanceof RemoteApiError) || error.status !== 404) throw error as Error;
      const result: RemoteProvider[] = [];
      const ids: string[] = ['zhihu', 'github'];
      for (const id of ids) {
        const status = id === 'github' ? '/api/v1/auth/oauth/github/status' : '/api/v1/auth/oauth/status';
        try {
          const configured: ESObject = remoteObject(await this.request('GET', status));
          if (configured.configured === true) {
            const provider = new RemoteProvider(); provider.id = id;
            provider.displayName = id === 'github' ? 'GitHub' : '知乎';
            provider.startUrl = status.replace(/status$/, 'start');
            provider.qrStartUrl = '/api/v1/auth/oauth/qr/start?provider=' + id; result.push(provider);
          }
        } catch (error) { if (!(error instanceof RemoteApiError) || error.status !== 404) throw error as Error; }
      }
      return result;
    }
    const rows: ESObject = remoteObject(response).items;
    if (!Array.isArray(rows)) throw new RemoteApiError('INVALID_MESSAGE');
    const result: RemoteProvider[] = []; const ids: Set<string> = new Set();
    const values: ESObject[] = rows;
    for (let index = 0; index < values.length; index++) {
      const raw: ESObject = remoteObject(values[index]);
      const provider = new RemoteProvider(); provider.id = remoteString(raw.id); provider.displayName = remoteString(raw.displayName);
      provider.startUrl = remoteString(raw.startUrl); provider.qrStartUrl = remoteString(raw.qrStartUrl);
      if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(provider.id) || ids.has(provider.id) ||
        !provider.displayName.trim() || provider.displayName.length > 128 || !authPath(provider.startUrl) ||
        (raw.qrStartUrl !== undefined && raw.qrStartUrl !== null && !authPath(provider.qrStartUrl))) throw new RemoteApiError('INVALID_MESSAGE');
      ids.add(provider.id); result.push(provider);
    }
    return result;
  }
  async startLogin(provider: RemoteProvider): Promise<RemoteQrSession> {
    if (!authPath(provider.qrStartUrl)) throw new RemoteApiError('OAUTH_PROVIDER_UNAVAILABLE');
    const raw: ESObject = remoteObject(await this.request('POST', provider.qrStartUrl, {}));
    const result = new RemoteQrSession(); result.qrId = remoteString(raw.qrId);
    result.scanUrl = remoteString(raw.scanUrl); result.expiresIn = remoteInteger(raw.expiresIn);
    try {
      if (/[\u0000-\u0020\u007f\\]/.test(result.scanUrl)) throw new Error('INVALID_MESSAGE');
      const scan = new url.URL(result.scanUrl);
      if (scan.origin !== this.serverUrl || scan.username || scan.password) throw new Error('INVALID_MESSAGE');
    } catch (_) { throw new RemoteApiError('INVALID_MESSAGE'); }
    if (result.qrId.length < 20 || result.qrId.length > 8192 || !result.expiresIn ||
      !Number.isSafeInteger(Date.now() + result.expiresIn * 1000) ||
      (raw.provider !== undefined && raw.provider !== provider.id)) throw new RemoteApiError('INVALID_MESSAGE');
    return result;
  }
  async pollLogin(id: string): Promise<RemoteQrResult> {
    const raw: ESObject = remoteObject(await this.request('GET', '/api/v1/auth/oauth/qr/' + encodeURIComponent(id)));
    const result = new RemoteQrResult(); result.status = remoteString(raw.status); result.token = remoteString(raw.token);
    if (result.status !== 'pending' && result.status !== 'expired' && result.status !== 'complete') throw new RemoteApiError('INVALID_MESSAGE');
    if (result.status === 'complete' && (result.token.length < 16 || result.token.length > 8192 || /[\r\n]/.test(result.token))) throw new RemoteApiError('INVALID_MESSAGE');
    return result;
  }
  async accountMe(token: string): Promise<string> {
    const result = remoteString(remoteObject(await this.request('GET', '/api/v1/auth/me', undefined, token)).account);
    if (!result) throw new RemoteApiError('INVALID_MESSAGE');
    return result;
  }
  async register(device: RemoteDeviceRegistration, token: string): Promise<RemoteTokens> {
    const args: RegisterArgs = { v: 1, device: device };
    return parseRemoteTokens(await this.request('POST', '/api/v1/devices/register', args, token));
  }
  async refresh(deviceId: string, refreshToken: string): Promise<RemoteTokens> {
    const args: RefreshArgs = { deviceId: deviceId, refreshToken: refreshToken };
    return parseRemoteTokens(await this.request('POST', '/api/v1/auth/refresh', args));
  }
  async hosts(token: string): Promise<RemoteHost[]> {
    const rows: ESObject = remoteObject(await this.request('GET', '/api/v1/devices', undefined, token)).items;
    if (!Array.isArray(rows)) throw new RemoteApiError('INVALID_MESSAGE');
    const result: RemoteHost[] = []; const values: ESObject[] = rows;
    for (let index = 0; index < values.length; index++) {
      const raw: ESObject = remoteObject(values[index]);
      if (raw.role !== 'host' || !remoteString(raw.deviceId) || !remoteString(raw.name) ||
        typeof raw.platform !== 'string' || !remoteString(raw.membershipId)) continue;
      const host = new RemoteHost(); host.id = raw.deviceId; host.name = raw.name; host.platform = raw.platform;
      host.membershipId = raw.membershipId; host.online = raw.online === true;
      host.pluginVersion = remoteString(raw.clientVersion); host.harnessVersion = remoteString(raw.harnessVersion);
      host.lastSeenAt = remoteInteger(raw.lastSeenAt); result.push(host);
    }
    return result;
  }
  async descriptor(token: string, id: string): Promise<RemoteHostDescriptor> {
    const path = '/api/v1/devices/' + encodeURIComponent(id);
    const raw: ESObject = remoteObject(await this.request('GET', path, undefined, token));
    if (raw.deviceId !== id || raw.role !== 'host' || !remoteString(raw.name) || typeof raw.platform !== 'string' ||
      !remoteString(raw.identityKey) || !remoteString(raw.membershipId)) throw new RemoteApiError('INVALID_MESSAGE');
    let presence: ESObject = raw;
    if (typeof raw.online !== 'boolean') {
      presence = remoteObject(await this.request('GET', path + '/presence', undefined, token));
      if (typeof presence.online !== 'boolean' || (presence.deviceId !== undefined && presence.deviceId !== id)) throw new RemoteApiError('INVALID_MESSAGE');
    }
    const result = new RemoteHostDescriptor(); result.deviceId = id; result.name = raw.name; result.role = raw.role;
    result.platform = raw.platform; result.identityKey = raw.identityKey; result.membershipId = raw.membershipId;
    result.onlineKnown = true; result.online = presence.online === true;
    result.lastSeenAt = remoteInteger(presence.lastSeenAt);
    result.clientVersion = remoteString(raw.clientVersion); result.harnessVersion = remoteString(raw.harnessVersion);
    return result;
  }
  close(): void {
    this.closed = true;
    for (const active of Array.from(this.pending)) active.cancel();
    this.pending.clear();
  }
}
