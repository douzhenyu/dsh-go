// Portions derived from ds-harness-remote (https://github.com/liguobao/ds-harness-remote), MIT,
// Copyright (c) 2026 DSH Remote contributors. See THIRD_PARTY_NOTICES.md.
// Native carrier over an authenticated plaintext RemoteMessageLink. Link owns Noise/DSHF.
import { util } from '@kit.ArkTS';
import { NativeCarrier } from '../data/NativeCarrier';
import { obj, str } from '../data/NativeDecode';
import { RemoteMessageLink } from './RemoteLink';
import { RemoteEnvelope, envelope, remoteObject, requireString, requireInteger, stableCode } from './RemoteProtocol';
import { utf8, text, base64url, unbase64url } from './RemoteBytes';

const MAX_PENDING: number = 128;
const DIRECT_BYTES: number = 2 * 1024 * 1024;
const CHUNK_BYTES: number = 512 * 1024;
const MAX_TRANSFER: number = 288 * 1024 * 1024;
const CALL_TIMEOUT: number = 65000;
const CONTROL_TIMEOUT: number = 15000;

function failureCode(failure: ESObject, fallback: string = 'TRANSPORT_CLOSED'): string {
  const value: ESObject = obj(failure);
  return stableCode(value.message, fallback);
}
function businessCode(value: ESObject): string {
  const code: string = requireString(value);
  // Settings and credential APIs intentionally use lower-case/slashed codes.
  // Preserve only a bounded code, never a server message which may echo secrets.
  if (!/^[A-Za-z0-9_/-]{1,100}$/.test(code)) throw new Error('REMOTE_ERROR');
  return code;
}
function endpointValid(endpoint: string): boolean {
  return /^(?:\$events(?:\/result)?|[A-Za-z][A-Za-z0-9_-]*\/[A-Za-z][A-Za-z0-9_-]*)$/.test(endpoint);
}
function canonical64(value: Uint8Array): string {
  let encoded: string = base64url(value).replace(/-/g, '+').replace(/_/g, '/');
  while (encoded.length % 4) encoded += '=';
  return encoded;
}
function decode64(value: string): Uint8Array {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    throw new Error('PROTOCOL_MISMATCH');
  }
  const result: Uint8Array = unbase64url(value.replace(/\+/g, '-').replace(/\//g, '_'));
  if (canonical64(result) !== value) throw new Error('PROTOCOL_MISMATCH');
  return result;
}
class RpcPayload {
  method: string;
  params: ESObject;
  constructor(method: string, params: ESObject) { this.method = method; this.params = params; }
}
class GatewayPayload {
  args: ESObject;
  constructor(args: ESObject) { this.args = args; }
}
class GatewayRequest {
  endpoint: string;
  payload: GatewayPayload;
  constructor(endpoint: string, args: ESObject) { this.endpoint = endpoint; this.payload = new GatewayPayload(args); }
}
class StreamRequest extends GatewayRequest {
  streamId: string;
  transferFrames?: boolean;
  constructor(id: string, endpoint: string, args: ESObject, transfer: boolean) {
    super(endpoint, args); this.streamId = id;
    if (transfer) this.transferFrames = true;
  }
}
class Pending {
  resolve: (value: ESObject) => void;
  reject: (error: Error) => void;
  timer: number;
  owner: string;
  constructor(resolve: (value: ESObject) => void, reject: (error: Error) => void, timer: number, owner: string) {
    this.resolve = resolve; this.reject = reject; this.timer = timer; this.owner = owner;
  }
}
class TunnelStream {
  onItem: (valueJson: string) => void;
  onError: (error: Error) => void;
  queue: Promise<void> = Promise.resolve();
  queued: number = 0;
  constructor(onItem: (valueJson: string) => void, onError: (error: Error) => void) {
    this.onItem = onItem; this.onError = onError;
  }
}

export class RemoteTunnel implements NativeCarrier {
  onState?: (state: string, code: string) => void;
  private link: RemoteMessageLink;
  private pending: Map<string, Pending> = new Map();
  private streams: Map<string, TunnelStream> = new Map();
  private epoch: number = 1;
  private closed: boolean = false;
  private linked: boolean = false;
  private negotiated: boolean = false;
  private opening?: Promise<void>;
  private connectReject?: (error: Error) => void;
  private caps: string[] = [];

  constructor(link: RemoteMessageLink) { this.link = link; }
  get capabilities(): string[] { return this.caps.slice(); }

  connect(): Promise<void> {
    if (this.closed) return Promise.reject(new Error('CLIENT_CLOSED'));
    if (this.negotiated) return Promise.resolve();
    if (this.opening) return this.opening;
    const epoch: number = this.epoch;
    this.link.onMessage = (message: Uint8Array) => {
      if (this.closed || epoch !== this.epoch) return;
      try { this.receive(envelope(text(message), false)); } catch (_) { this.stop('PROTOCOL_MISMATCH'); }
    };
    this.link.onClosed = (code: string) => {
      if (!this.closed && epoch === this.epoch) this.stop(stableCode(code, 'TRANSPORT_CLOSED'));
    };
    this.onState?.('connecting', '');
    const opening: Promise<void> = new Promise<void>((resolve, reject) => {
      this.connectReject = reject;
      this.start(epoch).then(() => {
        this.connectReject = undefined; resolve();
      }).catch((failure: ESObject) => {
        const code: string = failureCode(failure, 'CONNECTION_FAILED');
        this.stop(code); reject(new Error(code));
      });
    });
    this.opening = opening;
    return opening;
  }
  private async start(epoch: number): Promise<void> {
    await this.link.connect();
    this.assertEpoch(epoch); this.linked = true;
    // This MUST be the first RPC on every authenticated secure link.
    const description: ESObject = obj(await this.call('harness.transport.describe', JSON.parse('{}'), 10000));
    this.assertEpoch(epoch);
    const raw: ESObject = description.capabilities;
    if (!Array.isArray(raw) || raw.length > 128) throw new Error('INVALID_MESSAGE');
    const caps: string[] = [];
    const entries: ESObject[] = raw;
    entries.forEach((entry: ESObject) => {
      const capability: string = requireString(entry);
      if (caps.indexOf(capability) >= 0) throw new Error('INVALID_MESSAGE');
      caps.push(capability);
    });
    if (caps.indexOf('harness.remote.v3') >= 0 && caps.indexOf('harness.remote.v1') >= 0) throw new Error('INVALID_MESSAGE');
    if (caps.indexOf('harness.remote.v3') < 0) throw new Error('HARNESS_VERSION_INCOMPATIBLE');
    if (caps.indexOf('remote.history.compact.v1') >= 0) {
      // Native DTOs consume full history. Never silently accept compact records.
      const configured: ESObject = obj(await this.call('remote.history.configure', { compact: false }, 10000));
      if (Object.keys(configured).length !== 1 || configured.compact !== false) throw new Error('INVALID_MESSAGE');
    }
    this.assertEpoch(epoch); this.caps = caps; this.negotiated = true;
    this.onState?.('connected', '');
  }
  private assertEpoch(epoch: number): void {
    if (this.closed || epoch !== this.epoch) throw new Error('TRANSPORT_CLOSED');
  }
  private requireConnected(): void {
    if (this.closed) throw new Error('CLIENT_CLOSED');
    if (!this.negotiated) throw new Error('NOT_CONNECTED');
  }
  private take(id: string): Pending | undefined {
    const pending: Pending | undefined = this.pending.get(id);
    if (pending) { clearTimeout(pending.timer); this.pending.delete(id); }
    return pending;
  }
  private reject(id: string, code: string): void { this.take(id)?.reject(new Error(code)); }
  private call(method: string, params: ESObject, timeout: number = CALL_TIMEOUT, owner: string = ''): Promise<ESObject> {
    if (this.closed || !this.linked) return Promise.reject(new Error('TRANSPORT_CLOSED'));
    if (this.pending.size >= MAX_PENDING) return Promise.reject(new Error('RATE_LIMITED'));
    if (owner && !this.streams.has(owner)) return Promise.reject(new Error('STREAM_CANCELLED'));
    const epoch: number = this.epoch;
    const request: RemoteEnvelope = new RemoteEnvelope('rpc.request', new RpcPayload(method, params));
    let encoded: Uint8Array;
    try {
      encoded = utf8(JSON.stringify(request));
      if (encoded.length > 4194304) throw new Error('FRAME_TOO_LARGE');
    } catch (_) { return Promise.reject(new Error('FRAME_TOO_LARGE')); }
    return new Promise<ESObject>((resolve, reject) => {
      const timer: number = setTimeout(() => this.reject(request.id, 'RPC_TIMEOUT'), timeout);
      this.pending.set(request.id, new Pending(resolve, reject, timer, owner));
      // Link checks once immediately before the first Noise fragment; never replay writes.
      try {
        this.link.send(encoded, () => !this.closed && epoch === this.epoch && this.pending.has(request.id) &&
          (!owner || this.streams.has(owner))).catch((failure: ESObject) => {
          this.reject(request.id, failureCode(failure, 'TRANSPORT_CLOSED'));
        });
      } catch (failure) { this.reject(request.id, failureCode(failure, 'TRANSPORT_CLOSED')); }
    });
  }
  private receive(message: ESObject): void {
    const payload: ESObject = obj(message.payload);
    if (message.type === 'rpc.response') {
      const id: string = requireString(payload.requestId);
      this.take(id)?.resolve(payload.result);
    } else if (message.type === 'rpc.error') {
      const id: string = requireString(payload.requestId);
      this.reject(id, stableCode(payload.code, 'REMOTE_ERROR'));
    } else if (message.type === 'event') {
      const name: string = str(payload.event);
      if (name !== 'harness.remote.frame' && name !== 'harness.remote.stream.closed') return;
      const data: ESObject = obj(payload.data);
      const id: string = requireString(data.streamId);
      const stream: TunnelStream | undefined = this.streams.get(id);
      if (!stream) return;
      if (++stream.queued > 128) { this.endStream(id, stream, 'RATE_LIMITED', true); return; }
      // A transfer can block one stream while other streams continue independently.
      const task: Promise<void> = stream.queue.then(async () => {
        if (this.closed || this.streams.get(id) !== stream) return;
        await this.deliver(id, stream, name, data);
      });
      stream.queue = task.catch((failure: ESObject) => {
        this.endStream(id, stream, failureCode(failure, 'PROTOCOL_MISMATCH'), true);
      }).then(() => { stream.queued--; });
    }
  }
  private async deliver(id: string, stream: TunnelStream, event: string, data: ESObject): Promise<void> {
    if (event === 'harness.remote.frame') {
      if (data.hasValue !== true) return;
      const frame: ESObject = data.transfer !== undefined ? await this.readStreamFrame(id, data) : data;
      if (!this.closed && this.streams.get(id) === stream) {
        stream.onItem(JSON.stringify(frame.value === undefined ? null : frame.value));
      }
      return;
    }
    if (data.reason === 'peer-disconnected') { this.stop('TRANSPORT_CLOSED'); return; }
    const code: string = data.reason === 'failed' ? stableCode(obj(data.failure).code, 'REMOTE_ERROR') : 'STREAM_ENDED';
    this.endStream(id, stream, code, false);
  }
  private endStream(id: string, stream: TunnelStream, code: string, closeRemote: boolean): void {
    if (this.streams.get(id) !== stream) return;
    this.streams.delete(id); this.cancelOwned(id);
    if (closeRemote) this.closeRemote(id);
    stream.onError(new Error(code));
  }
  private cancelOwned(id: string): void {
    const owned: string[] = [];
    this.pending.forEach((pending: Pending, requestId: string) => { if (pending.owner === id) owned.push(requestId); });
    for (const requestId of owned) this.reject(requestId, 'STREAM_CANCELLED');
  }
  private closeRemote(id: string): void {
    if (!this.closed) this.call('harness.remote.stream.close', { streamId: id }, CONTROL_TIMEOUT).catch(() => {});
  }
  open(streamId: string, endpoint: string, argsJson: string,
    onItem: (valueJson: string) => void, onError: (error: Error) => void): void {
    this.requireConnected();
    if (!streamId || !endpointValid(endpoint) || this.streams.has(streamId)) throw new Error('INVALID_MESSAGE');
    const args: ESObject = remoteObject(argsJson);
    const stream: TunnelStream = new TunnelStream(onItem, onError);
    this.streams.set(streamId, stream); // Must precede send: frames may arrive before open ack.
    this.call('harness.remote.stream.open', new StreamRequest(streamId, endpoint, args,
      this.caps.indexOf('harness.remote.stream.transfer.v1') >= 0), CONTROL_TIMEOUT, streamId)
      .catch((failure: ESObject) => this.endStream(streamId, stream, failureCode(failure), true));
  }
  cancel(streamId: string): void {
    if (!this.streams.has(streamId)) return;
    this.streams.delete(streamId); this.cancelOwned(streamId); this.closeRemote(streamId);
  }
  async rpc(endpoint: string, argsJson: string): Promise<string> {
    this.requireConnected();
    if (!endpointValid(endpoint) || endpoint === '$events') throw new Error('METHOD_NOT_ALLOWED');
    const epoch: number = this.epoch;
    const args: ESObject = remoteObject(argsJson, MAX_TRANSFER);
    const request: GatewayRequest = new GatewayRequest(endpoint, args);
    const encoded: Uint8Array = utf8(JSON.stringify(request));
    const response: ESObject = encoded.length > DIRECT_BYTES ? await this.callTransferred(encoded) :
      await this.call('harness.remote.call', request);
    this.assertEpoch(epoch);
    const result: ESObject = obj(response);
    if (result.ok === true) return JSON.stringify(result.value === undefined ? null : result.value);
    if (result.ok === false) throw new Error(businessCode(obj(result.error).code));
    throw new Error('PROTOCOL_MISMATCH');
  }
  private transferDescriptor(value: ESObject, expectedId: string = ''): ESObject {
    const descriptor: ESObject = obj(value);
    const id: string = requireString(descriptor.transferId);
    if (!/^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/.test(id) || (expectedId && id !== expectedId) ||
      descriptor.kind !== 'chunked') throw new Error('PROTOCOL_MISMATCH');
    const count: number = requireInteger(descriptor.totalBytes, 1, MAX_TRANSFER);
    if (requireInteger(descriptor.totalChunks, 1) !== Math.ceil(count / CHUNK_BYTES)) throw new Error('PROTOCOL_MISMATCH');
    return descriptor;
  }
  private async readTransfer(descriptor: ESObject, owner: string = ''): Promise<Uint8Array> {
    const epoch: number = this.epoch;
    const id: string = requireString(descriptor.transferId);
    const size: number = requireInteger(descriptor.totalBytes, 1, MAX_TRANSFER);
    const chunks: number = requireInteger(descriptor.totalChunks, 1);
    const result: Uint8Array = new Uint8Array(size);
    const deadline: number = Date.now() + CALL_TIMEOUT;
    for (let index: number = 0; index < chunks; index++) {
      this.assertEpoch(epoch);
      if (owner && !this.streams.has(owner)) throw new Error('STREAM_CANCELLED');
      const remaining: number = deadline - Date.now();
      if (remaining <= 0) throw new Error('RPC_TIMEOUT');
      const chunk: ESObject = obj(await this.call('harness.remote.transfer.read', { transferId: id, index: index }, remaining, owner));
      if (chunk.transferId !== id || chunk.index !== index) throw new Error('PROTOCOL_MISMATCH');
      const data: Uint8Array = decode64(requireString(chunk.data));
      if (data.length !== Math.min(CHUNK_BYTES, size - index * CHUNK_BYTES)) throw new Error('PROTOCOL_MISMATCH');
      result.set(data, index * CHUNK_BYTES);
    }
    this.assertEpoch(epoch); return result;
  }
  private async releaseTransfer(id: string): Promise<void> {
    if (!this.closed) {
      try { await this.call('harness.remote.transfer.close', { transferId: id }, 5000); } catch (_) {}
    }
  }
  private async readStreamFrame(streamId: string, data: ESObject): Promise<ESObject> {
    if (this.caps.indexOf('harness.remote.stream.transfer.v1') < 0 || Object.keys(data).indexOf('value') >= 0) {
      throw new Error('PROTOCOL_MISMATCH');
    }
    const descriptor: ESObject = obj(data.transfer);
    const id: string = requireString(descriptor.transferId);
    // Never send a cleanup request for an unvalidated Host-controlled identifier.
    if (!/^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$/.test(id)) throw new Error('PROTOCOL_MISMATCH');
    try {
      this.transferDescriptor(descriptor);
      const frame: ESObject = remoteObject(text(await this.readTransfer(descriptor, streamId)), MAX_TRANSFER);
      if (frame.streamId !== streamId || frame.hasValue !== true || frame.transfer !== undefined) throw new Error('PROTOCOL_MISMATCH');
      return frame;
    } finally { await this.releaseTransfer(id); }
  }
  private async callTransferred(encoded: Uint8Array): Promise<ESObject> {
    if (this.caps.indexOf('harness.remote.transfer.v1') < 0 || encoded.length > MAX_TRANSFER) throw new Error('FRAME_TOO_LARGE');
    const epoch: number = this.epoch;
    const id: string = util.generateRandomUUID(true);
    const count: number = Math.ceil(encoded.length / CHUNK_BYTES);
    try {
      await this.call('harness.remote.transfer.open', { transferId: id, totalBytes: encoded.length, totalChunks: count });
      for (let index: number = 0; index < count; index++) {
        this.assertEpoch(epoch);
        await this.call('harness.remote.transfer.chunk', { transferId: id, index: index,
          data: canonical64(encoded.slice(index * CHUNK_BYTES, Math.min((index + 1) * CHUNK_BYTES, encoded.length))) });
      }
      const committed: ESObject = obj(await this.call('harness.remote.transfer.commit', { transferId: id }));
      if (committed.kind === 'inline') return committed.response;
      const descriptor: ESObject = this.transferDescriptor(committed, id);
      return remoteObject(text(await this.readTransfer(descriptor)), MAX_TRANSFER);
    } finally { await this.releaseTransfer(id); }
  }
  private stop(code: string): void {
    if (this.closed) return;
    this.closed = true; this.epoch++; this.negotiated = false; this.linked = false; this.caps = [];
    const stable: string = stableCode(code, 'TRANSPORT_CLOSED');
    const pendingCode: string = stable === 'CLIENT_CLOSED' ? 'CLIENT_CLOSED' : 'TRANSPORT_CLOSED';
    const rejectConnect = this.connectReject; this.connectReject = undefined;
    rejectConnect?.(new Error(stable));
    const pending: Pending[] = Array.from(this.pending.values()); this.pending.clear();
    const streams: TunnelStream[] = Array.from(this.streams.values()); this.streams.clear();
    this.link.onMessage = undefined; this.link.onClosed = undefined;
    try { this.link.close(); } catch (_) {}
    for (const request of pending) { clearTimeout(request.timer); request.reject(new Error(pendingCode)); }
    for (const stream of streams) { try { stream.onError(new Error(pendingCode)); } catch (_) {} }
    this.onState?.(stable === 'CLIENT_CLOSED' ? 'closed' : 'error', stable);
  }
  close(): void { this.stop('CLIENT_CLOSED'); }
}
