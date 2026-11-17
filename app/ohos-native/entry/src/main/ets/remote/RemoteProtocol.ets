// ds-harness-remote protocol v1. Derived from the MIT Dart implementation;
// see repository THIRD_PARTY_NOTICES.md and dsh_remote protocol/control.dart.
import { util } from '@kit.ArkTS';
import { parseObject, obj, str } from '../data/NativeDecode';
import { utf8, bytes, base64url, unbase64url } from './RemoteBytes';

export class RemoteEnvelope {
  v: number = 1;
  id: string = util.generateRandomUUID(true);
  timestamp: number = Date.now();
  type: string;
  payload: ESObject;
  constructor(type: string, payload: ESObject) { this.type = type; this.payload = payload; }
}

// JSON.parse validates syntax; this scanner additionally rejects duplicate object keys.
class JsonKeys {
  private source: string;
  private offset: number = 0;
  constructor(source: string) { this.source = source; }
  check(): void { this.value(0); }
  private space(): void { while (/\s/.test(this.source.charAt(this.offset)) && this.offset < this.source.length) this.offset++; }
  private string(): string {
    const start = this.offset++;
    while (this.offset < this.source.length) {
      const character = this.source.charAt(this.offset++);
      if (character === '\\') this.offset++;
      else if (character === '"') return JSON.parse(this.source.substring(start, this.offset)) as string;
    }
    throw new Error('PROTOCOL_MISMATCH');
  }
  private value(depth: number): void {
    if (depth > 128) throw new Error('PROTOCOL_MISMATCH');
    this.space(); const character = this.source.charAt(this.offset);
    if (character === '"') { this.string(); return; }
    if (character === '{') {
      this.offset++; this.space(); const keys: Set<string> = new Set();
      while (this.source.charAt(this.offset) !== '}') {
        this.space(); const key = this.string();
        if (keys.has(key)) throw new Error('PROTOCOL_MISMATCH');
        keys.add(key); this.space(); this.offset++; this.value(depth + 1); this.space();
        if (this.source.charAt(this.offset) !== ',') break;
        this.offset++;
      }
      this.offset++; return;
    }
    if (character === '[') {
      this.offset++; this.space();
      while (this.source.charAt(this.offset) !== ']') {
        this.value(depth + 1); this.space(); if (this.source.charAt(this.offset) !== ',') break;
        this.offset++;
      }
      this.offset++; return;
    }
    while (this.offset < this.source.length && !/[,}\]\s]/.test(this.source.charAt(this.offset))) this.offset++;
  }
}
export function remoteObject(json: string, limit: number = 4194304): ESObject {
  if (utf8(json).length > limit) throw new Error('FRAME_TOO_LARGE');
  const value: ESObject = parseObject(json);
  new JsonKeys(json).check(); return value;
}
export function requireString(value: ESObject): string {
  if (typeof value !== 'string' || !value.length) throw new Error('PROTOCOL_MISMATCH');
  return value;
}
export function canonicalBase64(value: ESObject): Uint8Array {
  const encoded = requireString(value);
  if (!/^[A-Za-z0-9_-]+$/.test(encoded)) throw new Error('PROTOCOL_MISMATCH');
  const decoded = unbase64url(encoded);
  if (base64url(decoded) !== encoded) throw new Error('PROTOCOL_MISMATCH');
  return decoded;
}
export function requireInteger(value: ESObject, minimum: number = 0, maximum: number = Number.MAX_SAFE_INTEGER): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error('PROTOCOL_MISMATCH');
  return value;
}
export function stableCode(value: ESObject, fallback: string = 'CONNECTION_FAILED'): string {
  const code = str(value); return /^[A-Z][A-Z0-9_]{0,99}$/.test(code) ? code : fallback;
}
export function envelope(json: string, control: boolean): ESObject {
  const value: ESObject = remoteObject(json, control ? 1048576 : 4194304);
  if (value.v !== 1) throw new Error('UNSUPPORTED_VERSION');
  requireString(value.id); requireString(value.type); requireInteger(value.timestamp, 1);
  if (value.payload === null || typeof value.payload !== 'object' || Array.isArray(value.payload)) throw new Error('PROTOCOL_MISMATCH');
  if (control) {
    const allowed: string[] = ['v', 'id', 'type', 'timestamp', 'payload'];
    for (const key of Object.keys(value)) if (allowed.indexOf(key) < 0) throw new Error('PROTOCOL_MISMATCH');
  } else if (['rpc.request', 'rpc.response', 'rpc.error', 'event'].indexOf(str(value.type)) < 0) throw new Error('PROTOCOL_MISMATCH');
  return value;
}

const CHUNK: number = 49152;
const MAX_MESSAGE: number = 4194304;
class Assembly {
  total: number;
  received: number = 0;
  buffer: Uint8Array;
  constructor(total: number, size: number) { this.total = total; this.buffer = new Uint8Array(size); }
}
export class RemoteFragments {
  private nextId: number = 1;
  private assemblies: Map<number, Assembly> = new Map();
  encode(message: Uint8Array): Uint8Array[] {
    if (message.length > MAX_MESSAGE) throw new Error('FRAME_TOO_LARGE');
    if (message.length <= CHUNK) return [message];
    const id = this.nextId; this.nextId = id === 4294967295 ? 1 : id + 1;
    const total = Math.ceil(message.length / CHUNK); const frames: Uint8Array[] = [];
    for (let index = 0; index < total; index++) {
      const part = message.slice(index * CHUNK, Math.min((index + 1) * CHUNK, message.length));
      const header = new Uint8Array(17); header.set(new Uint8Array([68, 83, 72, 70, 1]));
      const view = new DataView(header.buffer); view.setUint32(5, id); view.setUint16(9, index);
      view.setUint16(11, total); view.setUint32(13, message.length); frames.push(bytes(header, part));
    }
    return frames;
  }
  decode(frame: Uint8Array): Uint8Array | null {
    if (frame.length < 4 || frame[0] !== 68 || frame[1] !== 83 || frame[2] !== 72 || frame[3] !== 70) return frame;
    if (frame.length < 17 || frame[4] !== 1) throw new Error('PROTOCOL_MISMATCH');
    const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
    const id = view.getUint32(5); const index = view.getUint16(9); const total = view.getUint16(11); const size = view.getUint32(13);
    if (!id || total < 2 || index >= total || size <= CHUNK || size > MAX_MESSAGE || total !== Math.ceil(size / CHUNK) ||
      frame.length - 17 !== Math.min(CHUNK, size - index * CHUNK)) throw new Error('PROTOCOL_MISMATCH');
    let assembly = this.assemblies.get(id);
    if (!assembly) {
      if (index !== 0 || this.assemblies.size >= 8) throw new Error('PROTOCOL_MISMATCH');
      assembly = new Assembly(total, size); this.assemblies.set(id, assembly);
    }
    if (assembly.total !== total || assembly.buffer.length !== size || assembly.received !== index * CHUNK) throw new Error('PROTOCOL_MISMATCH');
    assembly.buffer.set(frame.subarray(17), assembly.received); assembly.received += frame.length - 17;
    if (index + 1 < total) return null;
    this.assemblies.delete(id); return assembly.buffer;
  }
  reset(): void { for (const value of this.assemblies.values()) value.buffer.fill(0); this.assemblies.clear(); this.nextId = 1; }
}
