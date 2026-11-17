// Wire fields follow packages/dsh_remote/lib/src/server/server_api.dart (MIT-derived protocol).
import { utf8 } from './RemoteBytes';
export const DEFAULT_REMOTE_SERVER: string = 'https://dsh.r2049.cn'; // app/lib/state/hosts_state.dart:419

export class RemoteProvider {
  id: string = '';
  displayName: string = '';
  startUrl: string = '';
  qrStartUrl: string = '';
}
export class RemoteLogin {
  loginUrl: string = '';
  providerId: string = '';
  expiresAt: number = 0;
}
export class RemoteQrSession {
  qrId: string = '';
  scanUrl: string = '';
  expiresIn: number = 0;
}
export class RemoteQrResult {
  status: string = '';
  token: string = '';
}
export class RemoteTokens {
  accessToken: string = '';
  accessTokenExpiresAt: number = 0;
  refreshToken: string = '';
  refreshTokenExpiresAt: number = 0;
}
export class RemoteCredentials extends RemoteTokens {
  deviceId: string = '';
  account: string = '';
  provider: string = '';
  serverUrl: string = '';
}
export class RemoteDeviceRegistration {
  deviceId: string = '';
  name: string = 'DSH Harmony';
  role: string = 'client';
  platform: string = 'dsh-app-ohos';
  identityKey: string = '';
  clientVersion: string = '0.1.0';
}
export class RemoteHostDescriptor {
  deviceId: string = '';
  name: string = '';
  role: string = '';
  platform: string = '';
  identityKey: string = '';
  membershipId: string = '';
  online: boolean = false;
  onlineKnown: boolean = false;
  lastSeenAt: number = 0;
  clientVersion: string = '';
  harnessVersion: string = '';
}
export class RemoteHost {
  id: string = '';
  name: string = '';
  platform: string = '';
  online: boolean = false;
  trust: string = 'unknown';
  membershipId: string = '';
  harnessVersion: string = '';
  pluginVersion: string = '';
  lastSeenAt: number = 0;
  identityKey: string = '';
  pinnedIdentityKey: string = '';
}
// Opening parameters, NOT a server-issued relay ticket. The actual ticket is issued
// by the control WebSocket's connect.accepted frame, never by an invented REST API.
export class RemoteConnectParameters {
  serverUrl: string = '';
  controlUrl: string = '';
  deviceId: string = '';
  accessToken: string = '';
  hostDeviceId: string = '';
  hostIdentityKey: string = '';
}
export class RemoteApiError extends Error {
  code: string;
  status: number;
  retryable: boolean;
  phase: string = '';
  constructor(code: string, status: number = 0, retryable: boolean = false) {
    super(/^[A-Z][A-Z0-9_]{0,63}$/.test(code) ? code : 'CONNECTION_FAILED');
    this.code = this.message; this.status = status; this.retryable = retryable;
  }
}
export function remoteObject(value: ESObject): ESObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : {};
}
export function remoteString(value: ESObject): string { return typeof value === 'string' ? value : ''; }
export function remoteInteger(value: ESObject): number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : 0;
}
export function parseRemoteTokens(value: ESObject): RemoteTokens {
  const raw: ESObject = remoteObject(value);
  const keys: string[] = Object.keys(raw);
  const allowed: string[] = ['accessToken', 'accessTokenExpiresAt', 'refreshToken', 'refreshTokenExpiresAt'];
  if (keys.some((key: string): boolean => allowed.indexOf(key) < 0)) throw new RemoteApiError('INVALID_MESSAGE');
  const result = new RemoteTokens();
  result.accessToken = remoteString(raw.accessToken); result.refreshToken = remoteString(raw.refreshToken);
  result.accessTokenExpiresAt = remoteInteger(raw.accessTokenExpiresAt);
  result.refreshTokenExpiresAt = remoteInteger(raw.refreshTokenExpiresAt);
  const accessBytes = utf8(result.accessToken).length; const refreshBytes = utf8(result.refreshToken).length;
  if (accessBytes < 16 || accessBytes > 8192 || /[\r\n]/.test(result.accessToken) ||
    refreshBytes < 16 || refreshBytes > 8192 || /[\r\n]/.test(result.refreshToken) ||
    !result.accessTokenExpiresAt || !result.refreshTokenExpiresAt) throw new RemoteApiError('INVALID_MESSAGE');
  return result;
}
