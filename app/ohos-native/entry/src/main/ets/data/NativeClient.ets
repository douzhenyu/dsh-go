import { http, webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { NativeWorkspace, NativeSession, NativeHistory, NativeSessionUpdate, NativeHostEvent, NativeAnswer } from './NativeDto';
import { parseObject, obj, arr, str, num, strings, workspace, session, history, sessionUpdate, hostEvent } from './NativeDecode';

import { NativeCarrier } from './NativeCarrier';
import { WireItem, WireFrame, WireRpc, WireRequest, WireFollow, WirePage, WirePrompt, WireAnswers, WireOutcome } from './NativeWire';

// Only errors created here carry safe local connection messages.
function nativeFailure(message: string): Error {
  const error: Error = new Error(message); error.name = 'NativeFailure'; return error;
}

function carrierFailure(failure: ESObject): Error {
  const raw: ESObject = obj(failure);
  // Carrier errors contain stable codes only. Preserve lower-case settings/*
  // business codes across this second boundary without accepting messages/URLs.
  const code: string = str(raw.message);
  return nativeFailure(/^[A-Za-z0-9_/-]{1,100}$/.test(code) ? code : 'CARRIER_FAILED');
}

class ConnectionDiagnostic {
  stage: string = 'login-http';
  status: number = 0;
  failure: string = '';
}

// Never read BusinessError.message: NetworkKit can include the credential-bearing URL.
function numericCode(failure: ESObject): number {
  const raw: ESObject = obj(failure);
  const code: number = num(raw.code);
  return Number.isInteger(code) && Math.abs(code) <= 2147483647 ? code : 0;
}
function diagnosticFailure(diagnostic: ConnectionDiagnostic, failure: ESObject): Error {
  diagnostic.failure = 'CONNECTION_FAILED: ' + diagnostic.stage + ' code=' + numericCode(failure).toString() +
    ' status=' + diagnostic.status.toString();
  return nativeFailure(diagnostic.failure);
}

class PendingHttp {
  request: http.HttpRequest;
  reject: (error: Error) => void;
  constructor(request: http.HttpRequest, reject: (error: Error) => void) {
    this.request = request; this.reject = reject;
  }
}
class NativeStream {
  id: string;
  onItem: (value: ESObject) => void;
  onError: (error: Error) => void;
  constructor(id: string, onItem: (value: ESObject) => void, onError: (error: Error) => void) {
    this.id = id; this.onItem = onItem; this.onError = onError;
  }
}

// One authenticated Host. No persistence, no wire tracing, no automatic write retry.
export class NativeClient {
  onState?: (state: string, message: string) => void;
  onHostEvent?: (event: NativeHostEvent) => void;
  private epoch: number = 0;
  private base: string = '';
  private authority: string = '';
  private cookieAuthority: string = '';
  private cookie: string = '';
  private socket?: webSocket.WebSocket;
  private carrier?: NativeCarrier;
  private pendingCarrier: Map<string, (error: Error) => void> = new Map();
  private eventsId: string = '';
  private clientId: string = '';
  private connected: boolean = false;
  private readyResolve?: () => void;
  private readyReject?: (error: Error) => void;
  private readyTimer: number = -1;
  private streams: Map<string, NativeStream> = new Map();
  private pendingHttp: Map<string, PendingHttp> = new Map();
  private pendingEvents: Set<string> = new Set();
  private workspaceRows: NativeWorkspace[] = [];
  private archivedIds: string[] = [];

  async connect(launchUrl: string): Promise<void> {
    this.disconnect();
    const epoch = this.epoch;
    const diagnostic: ConnectionDiagnostic = new ConnectionDiagnostic();
    // API 23 introduced maxRedirects. Older runtimes must not silently ignore it.
    if (deviceInfo.sdkApiVersion < 23) throw nativeFailure('UNSUPPORTED: secure HTTP redirect control requires API 23');
    this.onState?.('connecting', '');
    try {
      const match = launchUrl.trim().match(/https?:\/\/\S+/);
      if (!match) throw nativeFailure('INVALID_URL: enter a DSH launch URL');
      const url = match[0].match(/^(https?):\/\/([^/?#]+)([^?#]*)(?:\?([^#]*))?(?:#.*)?$/);
      if (!url || url[2].indexOf('@') >= 0 || /[\s\\]/.test(url[2])) {
        throw nativeFailure('INVALID_URL: invalid Host authority');
      }
      const query = url[4] || '';
      let token = '';
      for (const pair of query.split('&')) {
        const cut = pair.indexOf('=');
        if (cut >= 0 && pair.substring(0, cut) === 'token') {
          if (token) throw nativeFailure('INVALID_URL: duplicate token');
          try { token = decodeURIComponent(pair.substring(cut + 1)); } catch (_) {
            throw nativeFailure('INVALID_URL: invalid token encoding');
          }
        }
      }
      if (!token) throw nativeFailure('INVALID_URL: launch URL requires token');
      this.authority = url[2].toLowerCase();
      let path = url[3] || '';
      while (path.endsWith('/')) path = path.substring(0, path.length - 1);
      if (path.indexOf('..') >= 0 || path.indexOf('\\') >= 0) throw nativeFailure('INVALID_URL: invalid mount path');
      this.base = url[1] + '://' + this.authority + path;
      await this.login(token, epoch, diagnostic);
      this.assertEpoch(epoch);
      diagnostic.stage = 'ws-upgrade'; diagnostic.status = 0;
      await this.openSocket(epoch, diagnostic);
      this.assertEpoch(epoch);
      this.onState?.('connected', '');
    } catch (failure) {
      const error = failure instanceof Error && failure.name === 'NativeFailure' ? failure :
        diagnosticFailure(diagnostic, failure);
      if (epoch === this.epoch) {
        this.shutdown(error);
        this.onState?.('error', error.message);
      }
      throw error;
    }
  }

  async connectCarrier(carrier: NativeCarrier): Promise<void> {
    this.disconnect();
    const epoch: number = this.epoch;
    this.carrier = carrier;
    this.onState?.('connecting', '');
    carrier.onState = (state: string, code: string) => {
      if (epoch !== this.epoch || carrier !== this.carrier) return;
      if (state === 'error' || state === 'disconnected' || state === 'closed') {
        const safeCode: string = /^[A-Z][A-Z0-9_/-]{0,99}$/.test(code) ? code : 'CARRIER_DISCONNECTED';
        this.failSocket(epoch, safeCode);
      }
    };
    try {
      const id: string = this.id();
      await new Promise<void>((resolve, reject) => {
        this.pendingCarrier.set(id, reject);
        carrier.connect().then(() => {
          this.pendingCarrier.delete(id);
          if (epoch !== this.epoch) { reject(nativeFailure('DISCONNECTED')); return; }
          resolve();
        }).catch((failure: ESObject) => { this.pendingCarrier.delete(id); reject(carrierFailure(failure)); });
      });
      this.assertEpoch(epoch);
      const ready: Promise<void> = new Promise<void>((resolve, reject) => {
        this.readyResolve = resolve; this.readyReject = reject;
        this.readyTimer = setTimeout(() => this.failSocket(epoch, 'CARRIER_READY_TIMEOUT'), 15000);
      });
      ready.catch(() => {});
      this.eventsId = this.id();
      this.openCarrierStream(carrier, this.eventsId, '$events', '{}', epoch);
      await ready;
      this.assertEpoch(epoch);
      this.onState?.('connected', '');
    } catch (failure) {
      const error: Error = failure instanceof Error && failure.name === 'NativeFailure' ? failure : carrierFailure(failure);
      if (epoch === this.epoch) { this.shutdown(error); this.onState?.('error', error.message); }
      throw error;
    }
  }

  private openCarrierStream(carrier: NativeCarrier, id: string, endpoint: string, argsJson: string, epoch: number): void {
    carrier.open(id, endpoint, argsJson, (valueJson: string) => {
      // Always deliver after open returns, even for a carrier with a cached baseline.
      Promise.resolve().then(() => {
        if (epoch !== this.epoch || carrier !== this.carrier) return;
        try {
          const value: ESObject = JSON.parse(valueJson);
          this.receive(new WireItem(id, value), epoch);
        } catch (_) { this.failSocket(epoch, 'CARRIER_PROTOCOL'); }
      });
    }, (failure: Error) => {
      Promise.resolve().then(() => {
        if (epoch !== this.epoch || carrier !== this.carrier) return;
        const error: Error = carrierFailure(failure);
        if (id === this.eventsId) { this.failSocket(epoch, error.message); return; }
        const stream: NativeStream | undefined = this.streams.get(id);
        this.streams.delete(id);
        stream?.onError(error);
      });
    });
  }

  disconnect(): void {
    this.shutdown(nativeFailure('DISCONNECTED: client disconnected'));
    this.onState?.('disconnected', '');
  }

  private shutdown(error: Error): void {
    this.epoch++;
    if (this.readyTimer >= 0) clearTimeout(this.readyTimer);
    this.readyTimer = -1;
    const reject = this.readyReject;
    this.readyReject = undefined; this.readyResolve = undefined;
    reject?.(error);
    const socket = this.socket;
    this.socket = undefined;
    const carrier: NativeCarrier | undefined = this.carrier;
    this.carrier = undefined;
    if (carrier) {
      carrier.onState = undefined;
      for (const id of this.streams.keys()) { try { carrier.cancel(id); } catch (_) {} }
      if (this.eventsId) { try { carrier.cancel(this.eventsId); } catch (_) {} }
      try { carrier.close(); } catch (_) {}
    }
    for (const rejectPending of this.pendingCarrier.values()) rejectPending(error);
    this.pendingCarrier.clear();
    // Best-effort logical cancellation precedes physical close.
    if (socket) {
      for (const id of this.streams.keys()) {
        socket.send(JSON.stringify(new WireFrame('cancel', id))).catch(() => {});
      }
      if (this.eventsId) socket.send(JSON.stringify(new WireFrame('cancel', this.eventsId))).catch(() => {});
      socket.close({ code: 1000, reason: 'client closed' }).catch(() => {});
    }
    this.eventsId = ''; this.clientId = ''; this.connected = false;
    this.cookie = ''; this.cookieAuthority = ''; this.base = ''; this.authority = '';
    const streams = Array.from(this.streams.values()); this.streams.clear();
    for (const stream of streams) stream.onError(error);
    for (const pending of this.pendingHttp.values()) { pending.reject(error); pending.request.destroy(); }
    this.pendingHttp.clear(); this.pendingEvents.clear();
    this.workspaceRows = []; this.archivedIds = [];
  }

  private assertEpoch(epoch: number): void {
    if (epoch !== this.epoch) throw nativeFailure('DISCONNECTED: connection changed');
  }
  private requireReady(): void {
    // Logical mux readiness is independent of the carrier's authentication mechanism.
    if (!this.connected || !this.clientId) throw nativeFailure('DISCONNECTED: reconnect to Host');
  }
  private id(): string { return util.generateRandomUUID(true); }
  private failSocket(epoch: number, message: string): void {
    if (epoch !== this.epoch) return;
    this.shutdown(nativeFailure(message)); this.onState?.('error', message);
  }

  private async login(token: string, epoch: number, diagnostic: ConnectionDiagnostic): Promise<void> {
    const request = http.createHttp();
    let captured: string = '';
    // With maxRedirects=0 some SDKs report 2300047 after delivering headers.
    request.on('headersReceive', (headers: Object) => {
      const raw: ESObject = headers;
      if (epoch !== this.epoch) return;
      diagnostic.status = num(raw.responseCode, diagnostic.status);
      try { captured = this.findCookie(raw['set-cookie'] || raw['Set-Cookie']); } catch (failure) {
        this.failSocket(epoch, diagnosticFailure(diagnostic, failure).message);
      }
    });
    const id = this.id();
    await new Promise<void>((resolve, reject) => {
      this.pendingHttp.set(id, new PendingHttp(request, reject));
      request.request(this.base + '/?token=' + encodeURIComponent(token), {
        method: http.RequestMethod.GET, expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000, readTimeout: 15000, usingCache: false, maxRedirects: 0
      }, (error, response) => {
        this.pendingHttp.delete(id); request.destroy();
        if (epoch !== this.epoch) { reject(nativeFailure('DISCONNECTED')); return; }
        if (response) diagnostic.status = num(response.responseCode, diagnostic.status);
        if (!error) {
          if (response.responseCode !== 302 && response.responseCode !== 303) {
            reject(diagnosticFailure(diagnostic, undefined)); return;
          }
          const raw: ESObject = response.header;
          captured = captured || this.findCookie(raw['set-cookie'] || raw['Set-Cookie']) || this.findCookie(response.cookies);
        } else if (numericCode(error) !== 2300047) { reject(diagnosticFailure(diagnostic, error)); return; }
        if (!captured) { reject(diagnosticFailure(diagnostic, error)); return; }
        this.cookie = captured; this.cookieAuthority = this.authority; resolve();
      });
    });
  }

  private findCookie(value: ESObject): string {
    const values: string[] = typeof value === 'string' ? [value] : strings(value);
    for (const raw of values) {
      const match = raw.match(/(?:^|[\r\n,]\s*)(dsh-auth-[A-Za-z0-9_-]+=[^;\s,]+)/);
      if (match) return match[1];
    }
    return '';
  }

  private async openSocket(epoch: number, diagnostic: ConnectionDiagnostic): Promise<void> {
    const socket = webSocket.createWebSocket(); this.socket = socket;
    const ready = new Promise<void>((resolve, reject) => {
      this.readyResolve = resolve; this.readyReject = reject;
      this.readyTimer = setTimeout(() => this.failSocket(epoch, diagnosticFailure(diagnostic, undefined).message), 15000);
    });
    // Attach a rejection observer before awaiting the physical upgrade.
    ready.catch(() => {});
    socket.on('open', (failure) => {
      if (epoch !== this.epoch) return;
      if (failure && numericCode(failure) !== 0) {
        this.failSocket(epoch, diagnosticFailure(diagnostic, failure).message); return;
      }
      diagnostic.stage = 'events-ready'; diagnostic.status = 101;
      try {
        this.eventsId = this.id();
        socket.send(JSON.stringify(new WireFrame('open', this.eventsId, '$events')))
          .catch((failure: ESObject) => this.failSocket(epoch, diagnosticFailure(diagnostic, failure).message));
      } catch (failure) { this.failSocket(epoch, diagnosticFailure(diagnostic, failure).message); }
    });
    socket.on('message', (_error, message: string | ArrayBuffer) => {
      if (epoch !== this.epoch) return;
      if (typeof message !== 'string') { this.failSocket(epoch, 'UNSUPPORTED: binary mux message'); return; }
      try { this.receive(parseObject(message), epoch); } catch (_) {
        this.failSocket(epoch, 'PROTOCOL: invalid mux stream');
      }
    });
    socket.on('close', () => this.failSocket(epoch, 'DISCONNECTED: Host socket closed; reconnect required'));
    socket.on('error', (failure) => this.failSocket(epoch, diagnosticFailure(diagnostic, failure).message));
    if (!this.cookie || this.cookieAuthority !== this.authority) throw nativeFailure('AUTHORITY_MISMATCH');
    // Match Dart's GET upgrade: cookie plus the exact authority used at login.
    // Do not reuse POST Content-Type headers for the WebSocket handshake.
    const headers: ESObject = parseObject('{}');
    headers.Cookie = this.cookie; headers.Host = this.authority;
    try {
      const created: boolean = await socket.connect(this.base.replace(/^http/, 'ws') + '/api/remote.mux', { header: headers });
      if (!created) throw diagnosticFailure(diagnostic, undefined);
      this.assertEpoch(epoch);
      await ready;
    } catch (failure) {
      const error: Error = diagnostic.failure ? nativeFailure(diagnostic.failure) :
        (failure instanceof Error && failure.name === 'NativeFailure' ? failure : diagnosticFailure(diagnostic, failure));
      this.failSocket(epoch, error.message);
      throw error;
    }
  }

  private sendFrame(frame: ESObject): void {
    const epoch = this.epoch;
    if (!this.socket) throw nativeFailure('DISCONNECTED: no mux socket');
    this.socket.send(JSON.stringify(frame)).catch(() => this.failSocket(epoch, 'TRANSPORT: mux send failed'));
  }

  private receive(frame: ESObject, epoch: number): void {
    const type = str(frame.type); const id = str(frame.streamId);
    if (!id || (type !== 'item' && type !== 'end' && type !== 'error')) throw nativeFailure('PROTOCOL');
    if (id === this.eventsId) {
      if (type !== 'item') { this.failSocket(epoch, 'PROTOCOL: Host events stream ended'); return; }
      const value: ESObject = obj(frame.value);
      if (!this.connected) {
        if (value.type !== 'ready' || !str(value.clientId)) throw nativeFailure('PROTOCOL: missing ready');
        this.clientId = str(value.clientId); this.connected = true;
        if (this.readyTimer >= 0) clearTimeout(this.readyTimer);
        this.readyTimer = -1;
        const resolve = this.readyResolve; this.readyResolve = undefined; this.readyReject = undefined;
        resolve?.();
      } else if (value.type === 'ready') { throw nativeFailure('PROTOCOL: duplicate ready'); }
      const event = hostEvent(value);
      if (event.type === 'waterfall' && event.eventId) this.pendingEvents.add(event.eventId);
      if (event.type === 'cancel') this.pendingEvents.delete(event.eventId);
      this.onHostEvent?.(event);
      return;
    }
    const stream = this.streams.get(id); if (!stream) return;
    if (type === 'item') { stream.onItem(frame.value); return; }
    this.streams.delete(id);
    stream.onError(nativeFailure(type === 'error' ? 'REMOTE: stream request refused' : 'STREAM_ENDED: refresh required'));
  }

  private open(endpoint: string, args: ESObject, onItem: (value: ESObject) => void, onError: (error: Error) => void): string {
    this.requireReady();
    const id = this.id(); this.streams.set(id, new NativeStream(id, onItem, onError));
    const carrier: NativeCarrier | undefined = this.carrier;
    if (carrier) {
      try { this.openCarrierStream(carrier, id, endpoint, JSON.stringify(args), this.epoch); } catch (failure) {
        this.streams.delete(id); throw carrierFailure(failure);
      }
    } else this.sendFrame(new WireFrame('open', id, endpoint, args));
    return id;
  }
  // Generic stream values stay JSON so primitive/array items are preserved too.
  subscribe(endpoint: string, argsJson: string, onItem: (valueJson: string) => void,
    onError: (error: Error) => void): string {
    if (!/^[A-Za-z][A-Za-z0-9_-]*\/[A-Za-z][A-Za-z0-9_-]*$/.test(endpoint)) {
      throw nativeFailure('INVALID_ENDPOINT');
    }
    return this.open(endpoint, parseObject(argsJson), (value: ESObject) => {
      onItem(JSON.stringify(value === undefined ? null : value));
    }, onError);
  }

  // Explicit ownership: claim only while the question is visible; unfollow releases it.
  claimQuestionWait(sessionId: string, callId: string, onRemainingMs: (remainingMs: number) => void,
    onError: (error: Error) => void): string {
    if (!sessionId || !callId) throw nativeFailure('INVALID_QUESTION: missing wait identity');
    let id = '';
    id = this.open('userQuestions/attachWait', { agentId: sessionId, callId: callId }, (value: ESObject) => {
      const remaining = num(obj(value).remainingMs, -1);
      if (remaining < 0) {
        this.unfollow(id); onError(nativeFailure('PROTOCOL: invalid question wait duration')); return;
      }
      onRemainingMs(remaining);
    }, onError);
    return id;
  }

  unfollow(id: string): void {
    if (!this.streams.has(id)) return;
    this.streams.delete(id);
    if (this.carrier) { try { this.carrier.cancel(id); } catch (_) {} }
    else if (this.socket) this.sendFrame(new WireFrame('cancel', id));
  }

  async rpc(endpoint: string, argsJson: string = '{}'): Promise<string> {
    this.requireReady();
    if (!/^(?:[A-Za-z][A-Za-z0-9_-]*|\$events)\/[A-Za-z][A-Za-z0-9_-]*$/.test(endpoint)) {
      throw nativeFailure('INVALID_ENDPOINT');
    }
    const args: ESObject = parseObject(argsJson);
    const epoch = this.epoch; const rpcId = this.id();
    const carrier: NativeCarrier | undefined = this.carrier;
    if (carrier) {
      return new Promise<string>((resolve, reject) => {
        this.pendingCarrier.set(rpcId, reject);
        carrier.rpc(endpoint, JSON.stringify(args)).then((valueJson: string) => {
          this.pendingCarrier.delete(rpcId);
          if (epoch !== this.epoch || carrier !== this.carrier) { reject(nativeFailure('DISCONNECTED')); return; }
          try { JSON.parse(valueJson); resolve(valueJson); } catch (_) { reject(nativeFailure('CARRIER_PROTOCOL')); }
        }).catch((failure: ESObject) => { this.pendingCarrier.delete(rpcId); reject(carrierFailure(failure)); });
      });
    }
    const envelope: WireRpc = new WireRpc(rpcId, endpoint, args);
    const request = http.createHttp(); const headers: ESObject = parseObject('{"Content-Type":"application/json"}');
    if (!this.cookie || this.cookieAuthority !== this.authority) throw nativeFailure('AUTHORITY_MISMATCH');
    headers.Cookie = this.cookie;
    return new Promise<string>((resolve, reject) => {
      this.pendingHttp.set(rpcId, new PendingHttp(request, reject));
      request.request(this.base + '/api/' + endpoint, {
        method: http.RequestMethod.POST, header: headers, extraData: JSON.stringify(envelope),
        expectDataType: http.HttpDataType.STRING, connectTimeout: 10000, readTimeout: 120000,
        usingCache: false, maxRedirects: 0, maxLimit: 8 * 1024 * 1024
      }, (error, response) => {
        this.pendingHttp.delete(rpcId); request.destroy();
        if (epoch !== this.epoch) { reject(nativeFailure('DISCONNECTED: connection changed')); return; }
        if (error) { reject(nativeFailure('TRANSPORT: HTTP request failed; delivery may be uncertain')); return; }
        if (response.responseCode !== 200) {
          reject(nativeFailure('HTTP_' + response.responseCode.toString() + ': Host refused request')); return;
        }
        try {
          if (typeof response.result !== 'string') throw nativeFailure('UNSUPPORTED: binary RPC result');
          const decoded: ESObject = parseObject(response.result); const result: ESObject = obj(decoded.result);
          if (decoded.type !== 'server-response') throw nativeFailure('PROTOCOL: invalid RPC envelope');
          if (result.ok === false) {
            // Remote messages/details can echo arguments or credentials: expose only a bounded code.
            const code = str(obj(result.error).code);
            const safe = /^[A-Za-z0-9_/-]{1,100}$/.test(code) ? code : 'request-failed';
            throw nativeFailure('REMOTE: ' + safe);
          }
          if (result.ok !== true || decoded.rpcId !== rpcId) throw nativeFailure('PROTOCOL: RPC correlation mismatch');
          resolve(JSON.stringify(result.value === undefined ? null : result.value));
        } catch (failure) { reject(failure as Error); }
      });
    });
  }

  async workspaces(): Promise<NativeWorkspace[]> {
    return new Promise<NativeWorkspace[]>((resolve, reject) => {
      let id = '';
      const timer = setTimeout(() => { this.unfollow(id); reject(nativeFailure('TIMEOUT: workspace baseline')); }, 15000);
      try {
        id = this.open('workspace/follow', {}, (value: ESObject) => {
          if (value.type !== 'baseline' && value.type !== 'replace') {
            clearTimeout(timer); this.unfollow(id); reject(nativeFailure('PROTOCOL: workspace baseline required')); return;
          }
          clearTimeout(timer); this.unfollow(id);
          const baseline: ESObject = obj(value.value); const rows: NativeWorkspace[] = [];
          arr(baseline.items).forEach((item: ESObject) => { rows.push(workspace(item)); });
          this.workspaceRows = rows; this.archivedIds = strings(baseline.archivedSessionIds); resolve(rows);
        }, (error: Error) => { clearTimeout(timer); reject(error); });
      } catch (error) { clearTimeout(timer); reject(error as Error); }
    });
  }

  async sessions(workspaceId: string = ''): Promise<NativeSession[]> {
    const epoch = this.epoch;
    await this.workspaces(); this.assertEpoch(epoch);
    const result: ESObject = parseObject(await this.rpc('session/list', '{"_request":{}}'));
    this.assertEpoch(epoch);
    let allowed: string[] = [];
    if (workspaceId) {
      const selected = this.workspaceRows.find((row: NativeWorkspace) => row.workspaceId === workspaceId);
      if (!selected) return [];
      allowed = selected.sessionIds;
    }
    const rows: NativeSession[] = [];
    arr(result.items).forEach((item: ESObject) => {
      const row = session(item);
      if (row.origin === 'subagent' || this.archivedIds.indexOf(row.sessionId) >= 0) return;
      if (workspaceId && allowed.indexOf(row.sessionId) < 0) return;
      rows.push(row);
    });
    return rows;
  }

  async createSession(cwd: string, workspaceId: string = ''): Promise<string> {
    const request: ESObject = {};
    if (cwd.trim()) request.cwd = cwd.trim();
    if (workspaceId) request.workspaceId = workspaceId;
    const value: ESObject = parseObject(await this.rpc('session/create', JSON.stringify(new WireRequest(request))));
    if (!str(value.sessionId)) throw nativeFailure('PROTOCOL: missing session ID');
    return str(value.sessionId);
  }

  async read(sessionId: string, throughSeq: number, beforeSeq: number = -1): Promise<NativeHistory> {
    const request: WirePage = new WirePage(sessionId, throughSeq, beforeSeq);
    return history(parseObject(await this.rpc('session/page', JSON.stringify(new WireRequest(request)))));
  }

  follow(sessionId: string, onUpdate: (value: NativeSessionUpdate) => void, onError: (error: Error) => void): string {
    let cursor = -1; let opened = false; let revision = -1; let id = '';
    id = this.open('session/follow', new WireRequest(new WireFollow(sessionId)), (value: ESObject) => {
      try {
        const update = sessionUpdate(sessionId, value);
        if (!opened && update.type !== 'snapshot') throw nativeFailure('PROTOCOL: missing session snapshot');
        if (update.type === 'snapshot') {
          cursor = update.cursor; opened = true; revision = num(obj(value.assistantStream).revision, -1);
        } else if (update.type === 'event') {
          if (update.cursor <= cursor) return;
          if (update.cursor !== cursor + 1) throw nativeFailure('PROTOCOL: session log gap; refresh required');
          cursor = update.cursor;
        } else if (update.type === 'assistant-stream') {
          const next = num(obj(value.frame).revision, -1);
          if (next <= revision) return;
          if (revision >= 0 && next !== revision + 1) throw nativeFailure('PROTOCOL: assistant stream gap; refresh required');
          revision = next;
        }
        onUpdate(update);
      } catch (_) { this.unfollow(id); onError(nativeFailure('PROTOCOL: session stream requires refresh')); }
    }, onError);
    return id;
  }

  async send(sessionId: string, prompt: string, requestId: string = '', mode: string = 'queue'): Promise<string> {
    if (!prompt.trim()) throw nativeFailure('INVALID_PROMPT: message is empty');
    if (mode !== 'queue' && mode !== 'steer') throw nativeFailure('INVALID_PROMPT: unsupported mode');
    const id = requestId || this.id();
    await this.rpc('session/prompt', JSON.stringify(new WireRequest(new WirePrompt(id, sessionId, mode, prompt))));
    return id;
  }
  async cancel(sessionId: string): Promise<void> {
    await this.rpc('session/cancel', JSON.stringify(new WireRequest(JSON.parse('{"sessionId":' + JSON.stringify(sessionId) + '}'))));
  }
  private async respond(eventId: string, outcome: ESObject): Promise<void> {
    this.requireReady();
    if (!this.pendingEvents.has(eventId)) throw nativeFailure('STALE_REQUEST: request is no longer pending');
    const epoch = this.epoch;
    await this.rpc('$events/result', JSON.stringify({ clientId: this.clientId, eventId: eventId, outcome: outcome }));
    this.assertEpoch(epoch); this.pendingEvents.delete(eventId);
    const event = new NativeHostEvent(); event.type = 'cancel'; event.eventId = eventId;
    this.onHostEvent?.(event);
  }
  async respondApproval(eventId: string, decision: string): Promise<void> {
    if (decision === 'next') { await this.respond(eventId, new WireOutcome('next')); return; }
    if (decision !== 'allowed-once' && decision !== 'rejected') throw nativeFailure('INVALID_DECISION');
    await this.respond(eventId, new WireOutcome('result', decision));
  }
  async rejectQuestion(eventId: string, timedOut: boolean = false): Promise<void> {
    const error: ESObject = { name: 'UserQuestionError', message: timedOut ? 'timed out' : 'declined' };
    if (timedOut) error.code = 'ASK_TIMED_OUT';
    await this.respond(eventId, new WireOutcome('rejected', undefined, error));
  }

  async answerQuestion(eventId: string, answers: NativeAnswer[]): Promise<void> {
    await this.respond(eventId, new WireOutcome('result', new WireAnswers(answers)));
  }
}
