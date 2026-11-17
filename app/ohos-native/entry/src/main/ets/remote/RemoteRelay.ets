// Native ds-harness-remote relay + Noise IK. No plaintext fallback or route claims.
// Protocol derived from packages/dsh_remote (MIT); this transport never persists account material.
import { webSocket } from '@kit.NetworkKit';
import { RemoteConnectParameters } from './RemoteDtos';
import { RemoteMessageLink } from './RemoteLink';
import { RemoteKeyPair } from './RemoteCrypto';
import { NoiseInitiator } from './RemoteNoise';
import { RemoteEnvelope, RemoteFragments, envelope, requireString, requireInteger, stableCode, canonicalBase64 } from './RemoteProtocol';
import { obj, str, arr } from '../data/NativeDecode';
import { utf8, text, base64url, unbase64url } from './RemoteBytes';

interface Hello { role: string; deviceId: string; accessToken: string; protocols: number[]; capabilities: string[]; }
interface ConnectRequest { hostDeviceId: string; preferredTransports: string[]; }
interface Attach { connectionId: string; deviceId: string; peerDeviceId: string; ticket: string; }
interface Selected { connectionId: string; targetDeviceId: string; transport: string; }
interface Handshake { connectionId: string; targetDeviceId: string; step: number; data: string; }
interface RelayPayload { connectionId: string; targetDeviceId: string; counter: number; ciphertext: string; }
interface Pong { nonce: string; }

class RelaySocket {
  private socket: webSocket.WebSocket = webSocket.createWebSocket();
  private closed: boolean = false;
  private opened: boolean = false;
  private resolve?: () => void;
  private reject?: (error: Error) => void;
  private timer: number = -1;
  private closedPromise: Promise<void>;
  private rejectClosed?: (error: Error) => void;
  private onFrame: (json: string) => void;
  private onLost: (code: string) => void;
  private lostCode: string = 'CONTROL_SOCKET_FAILED';
  constructor(onFrame: (json: string) => void, onLost: (code: string) => void, lostCode: string = 'CONTROL_SOCKET_FAILED') {
    this.onFrame = onFrame; this.onLost = onLost; this.lostCode = lostCode;
    this.closedPromise = new Promise<void>((_resolve, reject) => { this.rejectClosed = reject; });
    this.closedPromise.catch(() => {});
  }
  async connect(url: string): Promise<void> {
    const match = url.match(/^wss?:\/\/([^/?#]+)(?:\/[^#]*)?$/);
    if (!match || match[1].indexOf('@') >= 0 || /[\s\\]/.test(url)) throw new Error('INVALID_SERVER_URL');
    const ready = new Promise<void>((resolve, reject) => { this.resolve = resolve; this.reject = reject; });
    ready.catch(() => {});
    this.timer = setTimeout(() => this.fail(this.lostCode), 15000);
    this.socket.on('open', (error) => {
      if (this.closed) return;
      if (error && error.code) { this.fail(this.lostCode); return; }
      this.opened = true; clearTimeout(this.timer); this.timer = -1;
      const resolve = this.resolve; this.resolve = undefined; this.reject = undefined; resolve?.();
    });
    this.socket.on('message', (error, value: string | ArrayBuffer) => {
      if (this.closed) return;
      if ((error && error.code) || typeof value !== 'string') { this.fail('PROTOCOL_MISMATCH'); return; }
      try { this.onFrame(value); } catch (failure) { this.fail(stableCode((failure as Error).message, 'PROTOCOL_MISMATCH')); }
    });
    this.socket.on('error', () => this.fail(this.lostCode));
    this.socket.on('close', (_error, result) => {
      if (!this.closed) {
        const code: number = result && Number.isSafeInteger(result.code) && result.code >= 0 && result.code <= 65535 ? result.code : 0;
        this.fail(code === 4003 ? 'CONNECTION_REPLACED' : this.lostCode + '_CLOSE_' + code);
      }
    });
    try {
      const opening = this.socket.connect(url).then((accepted: boolean) => { if (!accepted) throw new Error(this.lostCode); });
      await Promise.race<void>([opening, this.closedPromise]).catch(() => { throw new Error(this.lostCode); });
      await ready;
    } catch (_) { this.fail(this.lostCode); throw new Error(this.lostCode); }
  }
  async send(frame: RemoteEnvelope): Promise<void> {
    if (this.closed || !this.opened) throw new Error('TRANSPORT_CLOSED');
    try {
      const write = this.socket.send(JSON.stringify(frame)).then((accepted: boolean) => { if (!accepted) throw new Error(this.lostCode); });
      await Promise.race<void>([write, this.closedPromise]);
    } catch (_) {
      const code = this.closed ? 'CLIENT_CLOSED' : this.lostCode; this.fail(code); throw new Error(code);
    }
  }
  private fail(code: string): void {
    if (this.closed) return;
    const reject = this.reject; this.reject = undefined; this.resolve = undefined;
    this.close(); reject?.(new Error(code)); this.onLost(code);
  }
  close(): void {
    if (this.closed) return;
    this.closed = true; this.rejectClosed?.(new Error('CLIENT_CLOSED')); this.rejectClosed = undefined;
    if (this.timer >= 0) clearTimeout(this.timer); this.timer = -1;
    const reject = this.reject; this.reject = undefined; this.resolve = undefined;
    reject?.(new Error('CLIENT_CLOSED'));
    this.socket.close({ code: 1000, reason: 'client closed' }).catch(() => {});
  }
}

export class RemoteRelay implements RemoteMessageLink {
  onMessage?: (message: Uint8Array) => void;
  onClosed?: (code: string) => void;
  private parameters: RemoteConnectParameters;
  private identity: RemoteKeyPair;
  private control?: RelaySocket;
  private data?: RelaySocket;
  private phase: string = 'new';
  private connectionId: string = '';
  private relayEpoch: number = -1;
  private noise?: NoiseInitiator;
  private outgoing: RemoteFragments = new RemoteFragments();
  private incoming: RemoteFragments = new RemoteFragments();
  private readyResolve?: () => void;
  private readyReject?: (error: Error) => void;
  private deadline: number = -1;
  private watchdog: number = -1;
  private lastReceived: number = Date.now();
  private controlLimit: number = 65536;
  private relayLimit: number = 1048576;
  private heartbeatMs: number = 25000;
  private sendTail: Promise<void> = Promise.resolve();

  constructor(parameters: RemoteConnectParameters, identity: RemoteKeyPair) {
    this.parameters = parameters; this.identity = identity;
  }
  async connect(): Promise<void> {
    if (this.phase !== 'new') throw new Error('CLIENT_CLOSED');
    this.phase = 'hello';
    const ready = new Promise<void>((resolve, reject) => { this.readyResolve = resolve; this.readyReject = reject; });
    ready.catch(() => {});
    this.deadline = setTimeout(() => this.fail(this.phase === 'hello' ? 'HELLO_TIMEOUT' : this.phase === 'accepted' ? 'ACCEPT_TIMEOUT' : this.phase === 'attaching' ? 'ATTACH_TIMEOUT' : 'HANDSHAKE_TIMEOUT'), 30000);
    const socket = new RelaySocket((json: string) => this.controlFrame(json), (code: string) => this.fail(code)); this.control = socket;
    try {
      await socket.connect(this.parameters.controlUrl);
      if (this.phase === 'closed') throw new Error('CLIENT_CLOSED');
      const hello: Hello = { role: 'client', deviceId: this.parameters.deviceId, accessToken: this.parameters.accessToken,
        protocols: [1], capabilities: ['transport.relay', 'transport.relay.attach'] };
      await this.sendControl('hello', hello); await ready;
    } catch (failure) { const code = stableCode((failure as Error).message); this.fail(code); throw new Error(code); }
  }
  private async sendControl(type: string, payload: ESObject): Promise<void> {
    if (!this.control || this.phase === 'closed') throw new Error('TRANSPORT_CLOSED');
    const frame = new RemoteEnvelope(type, payload);
    const limit = type === 'relay' ? this.relayLimit : this.controlLimit;
    if (utf8(JSON.stringify(frame)).length > limit) throw new Error('FRAME_TOO_LARGE');
    await this.control.send(frame);
  }
  private async sendData(type: string, payload: ESObject): Promise<void> {
    if (!this.data || this.phase === 'closed') throw new Error('TRANSPORT_CLOSED');
    const frame = new RemoteEnvelope(type, payload);
    if (utf8(JSON.stringify(frame)).length > this.relayLimit) throw new Error('FRAME_TOO_LARGE');
    await this.data.send(frame);
  }
  private controlFrame(json: string): void {
    if (this.phase === 'closed') return;
    this.lastReceived = Date.now();
    const frame: ESObject = envelope(json, true); const payload: ESObject = obj(frame.payload); const type = str(frame.type);
    if (utf8(json).length > (type === 'relay' ? this.relayLimit : this.controlLimit)) throw new Error('FRAME_TOO_LARGE');
    if (type === 'hello.ack') {
      if (this.phase !== 'hello' || payload.protocol !== 1) throw new Error('UNSUPPORTED_VERSION');
      requireString(payload.serverVersion); requireString(payload.connectionSessionId);
      this.controlLimit = requireInteger(payload.maxControlFrameBytes, 1, 65536);
      this.relayLimit = requireInteger(payload.maxRelayFrameBytes, 1, 1048576);
      this.heartbeatMs = requireInteger(payload.heartbeatIntervalMs, 1);
      const capabilities: ESObject[] = payload.capabilities === undefined ? ['transport.relay'] : arr(payload.capabilities);
      if (capabilities.length > 128 || !capabilities.length || !capabilities.includes('transport.relay')) throw new Error('CAPABILITY_NOT_SUPPORTED');
      const seen: Set<string> = new Set();
      capabilities.forEach((capability: ESObject) => {
        if (typeof capability !== 'string' || seen.has(capability) || ['transport.relay', 'transport.relay.attach'].indexOf(capability) < 0) throw new Error('CAPABILITY_NOT_SUPPORTED');
        seen.add(capability);
      });
      this.phase = 'accepted'; const request: ConnectRequest = { hostDeviceId: this.parameters.hostDeviceId, preferredTransports: ['relay'] };
      this.sendControl('connect.request', request).catch((error: Error) => this.fail(stableCode(error.message, 'RELAY_WRITE_FAILED')));
    } else if (type === 'connect.accepted') {
      if (this.phase !== 'accepted' || this.connectionId) throw new Error('PROTOCOL_MISMATCH');
      this.connectionId = requireString(payload.connectionId);
      this.watchdog = setInterval(() => { if (Date.now() - this.lastReceived > this.heartbeatMs * 3) this.fail('RELAY_SILENCE'); }, this.heartbeatMs);
      if (payload.relayEndpoint !== undefined || payload.relayTicket !== undefined) {
        const endpoint = requireString(payload.relayEndpoint); const ticket = requireString(payload.relayTicket);
        if (this.parameters.serverUrl.startsWith('https:') && !endpoint.startsWith('wss:')) throw new Error('PROTOCOL_MISMATCH');
        this.relayEpoch = payload.relayEpoch === undefined ? -1 : requireInteger(payload.relayEpoch);
        this.phase = 'attaching'; this.attach(endpoint, ticket).catch((error: Error) => this.fail(stableCode(error.message, 'RELAY_ATTACH_FAILED')));
      } else this.beginNoise();
    } else if (type === 'secure.handshake') this.handshake(payload);
    else if (type === 'relay') { if (!this.data) this.ciphertext(payload); }
    else if (type === 'ping') { const pong: Pong = { nonce: requireString(payload.nonce) }; this.sendControl('pong', pong).catch((error: Error) => this.fail(stableCode(error.message, 'RELAY_WRITE_FAILED'))); }
    else if (type === 'error' || type === 'connect.rejected') {
      if (payload.connectionId !== undefined && this.connectionId && payload.connectionId !== this.connectionId) return;
      const remoteCode: string = stableCode(payload.code, type === 'error' ? 'CONTROL_REMOTE_ERROR' : 'CONNECTION_REJECTED');
      this.fail(remoteCode === 'CONNECTION_FAILED' ? 'REMOTE_CONNECTION_FAILED' : remoteCode);
    } else if (type === 'transport.selected') {
      if (payload.connectionId !== this.connectionId || payload.targetDeviceId !== this.parameters.deviceId || payload.transport !== 'relay') throw new Error('PROTOCOL_MISMATCH');
    } else if (type !== 'pong' && type !== 'signal.answer' && type !== 'signal.ice') throw new Error('PROTOCOL_MISMATCH');
  }
  private async attach(endpoint: string, ticket: string): Promise<void> {
    const socket = new RelaySocket((json: string) => this.dataFrame(json), (code: string) => this.fail(code), 'RELAY_SOCKET_FAILED'); this.data = socket;
    await socket.connect(endpoint);
    if (this.phase !== 'attaching') { socket.close(); return; }
    const payload: Attach = { connectionId: this.connectionId, deviceId: this.parameters.deviceId, peerDeviceId: this.parameters.hostDeviceId, ticket: ticket };
    await this.sendData('relay.attach', payload);
  }
  private dataFrame(json: string): void {
    if (this.phase === 'closed') return;
    const frame: ESObject = envelope(json, true); const payload: ESObject = obj(frame.payload); const type = str(frame.type);
    if (utf8(json).length > this.relayLimit) throw new Error('FRAME_TOO_LARGE');
    if (type === 'relay.ready') {
      if (this.phase !== 'attaching' || payload.connectionId !== this.connectionId || (this.relayEpoch >= 0 && payload.epoch !== this.relayEpoch)) throw new Error('PROTOCOL_MISMATCH');
      const selected: Selected = { connectionId: this.connectionId, targetDeviceId: this.parameters.hostDeviceId, transport: 'relay' };
      this.sendControl('transport.selected', selected).then(() => { if (this.phase === 'attaching') this.beginNoise(); }).catch((error: Error) => this.fail(stableCode(error.message, 'RELAY_WRITE_FAILED')));
    } else if (type === 'secure.handshake') this.handshake(payload);
    else if (type === 'relay') this.ciphertext(payload);
    else if (type === 'relay.detach') this.fail('RELAY_DETACHED');
    else if (type === 'ping') { const pong: Pong = { nonce: requireString(payload.nonce) }; this.sendData('pong', pong).catch((error: Error) => this.fail(stableCode(error.message, 'RELAY_WRITE_FAILED'))); }
    else if (type !== 'pong') throw new Error('PROTOCOL_MISMATCH');
  }
  private beginNoise(): void {
    const parameters = this.parameters;
    for (const value of [this.connectionId, parameters.hostDeviceId, parameters.deviceId]) if (!value || value.indexOf('\u0000') >= 0) throw new Error('PROTOCOL_MISMATCH');
    this.phase = 'noise';
    const prologue = utf8('DSH-REMOTE\u0000v=1\u0000connection=' + this.connectionId + '\u0000host=' + parameters.hostDeviceId + '\u0000client=' + parameters.deviceId);
    const noise = new NoiseInitiator(this.identity, canonicalBase64(parameters.hostIdentityKey), prologue); this.noise = noise;
    const payload: Handshake = { connectionId: this.connectionId, targetDeviceId: parameters.hostDeviceId, step: 1, data: base64url(noise.writeMessage()) };
    this.sendControl('secure.handshake', payload).catch((error: Error) => this.fail(stableCode(error.message, 'RELAY_WRITE_FAILED')));
  }
  private owned(payload: ESObject): void {
    if (payload.connectionId !== this.connectionId || payload.targetDeviceId !== this.parameters.deviceId) throw new Error('PROTOCOL_MISMATCH');
  }
  private handshake(payload: ESObject): void {
    this.owned(payload);
    if (this.phase !== 'noise' || !this.noise || payload.step !== 2) throw new Error('NOISE_HANDSHAKE_ORDER');
    // The authenticated Noise payload may contain host metadata; Dart accepts it without interpretation.
    this.noise.readMessage(canonicalBase64(payload.data));
    if (!this.noise.ready) throw new Error('SECURE_CHANNEL_FAILED');
    this.phase = 'ready'; if (this.deadline >= 0) clearTimeout(this.deadline); this.deadline = -1;
    const resolve = this.readyResolve; this.readyResolve = undefined; this.readyReject = undefined; resolve?.();
  }
  private ciphertext(payload: ESObject): void {
    this.owned(payload);
    if (this.phase !== 'ready' || !this.noise || requireInteger(payload.counter) !== this.noise.receivingCounter) throw new Error('SECURE_CHANNEL_FAILED');
    const decrypted = this.noise.decrypt(canonicalBase64(payload.ciphertext));
    const message = this.incoming.decode(decrypted);
    if (message) {
      if (!this.onMessage) throw new Error('PROTOCOL_MISMATCH');
      this.onMessage(message);
    }
  }
  send(message: Uint8Array, canSend?: () => boolean): Promise<void> {
    if (message.length > 4194304) return Promise.reject(new Error('FRAME_TOO_LARGE'));
    const run = this.sendTail.then(async () => {
      if (canSend && !canSend()) return;
      if (this.phase !== 'ready' || !this.noise) throw new Error('TRANSPORT_CLOSED');
      try {
        for (const fragment of this.outgoing.encode(message)) {
          const counter = this.noise.sendingCounter; const ciphertext = this.noise.encrypt(fragment);
          const payload: RelayPayload = { connectionId: this.connectionId, targetDeviceId: this.parameters.hostDeviceId, counter: counter, ciphertext: base64url(ciphertext) };
          if (this.data) await this.sendData('relay', payload); else await this.sendControl('relay', payload);
        }
      } catch (failure) { this.fail(stableCode((failure as Error).message, 'SECURE_CHANNEL_FAILED')); throw new Error('TRANSPORT_CLOSED'); }
    });
    this.sendTail = run.catch(() => {}); return run;
  }
  private fail(code: string): void {
    if (this.phase === 'closed') return;
    const failure: string = code === 'CONNECTION_FAILED' ?
      (this.phase === 'hello' ? 'HELLO_FAILED' : this.phase === 'accepted' ? 'CONNECT_REQUEST_FAILED' :
        this.phase === 'attaching' ? 'RELAY_ATTACH_FAILED' : this.phase === 'noise' ? 'NOISE_HANDSHAKE_FAILED' : 'SECURE_CHANNEL_FAILED') : code;
    const reject = this.readyReject; this.readyReject = undefined; this.readyResolve = undefined;
    this.close(); reject?.(new Error(failure)); this.onClosed?.(failure);
  }
  close(): void {
    if (this.phase === 'closed') return;
    this.phase = 'closed';
    if (this.deadline >= 0) clearTimeout(this.deadline); if (this.watchdog >= 0) clearInterval(this.watchdog);
    this.deadline = -1; this.watchdog = -1; this.control?.close(); this.data?.close();
    this.noise?.destroy(); this.noise = undefined; this.incoming.reset(); this.outgoing.reset();
    this.parameters.accessToken = '';
    const reject = this.readyReject; this.readyReject = undefined; this.readyResolve = undefined; reject?.(new Error('CLIENT_CLOSED'));
  }
}
