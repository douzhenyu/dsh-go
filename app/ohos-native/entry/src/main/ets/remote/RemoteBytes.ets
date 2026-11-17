import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export function bytes(...parts: Uint8Array[]): Uint8Array {
  let size = 0;
  for (const part of parts) size += part.length;
  const result = new Uint8Array(size); let offset = 0;
  for (const part of parts) { result.set(part, offset); offset += part.length; }
  return result;
}
export function utf8(value: string): Uint8Array {
  // HarmonyOS TextEncoder returns undefined for empty input, rather than empty bytes.
  return value.length === 0 ? new Uint8Array(0) : new util.TextEncoder().encodeInto(value);
}
export function text(value: Uint8Array): string { return util.TextDecoder.create('utf-8', { fatal: true }).decodeWithStream(value); }
export function randomBytes(length: number): Uint8Array { return cryptoFramework.createRandom().generateRandomSync(length).data; }
export function base64url(value: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(value).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
export function unbase64url(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*={0,2}$/.test(value) || value.length % 4 === 1) throw new Error('INVALID_BASE64');
  let encoded = value.replace(/-/g, '+').replace(/_/g, '/');
  while (encoded.length % 4 !== 0) encoded += '=';
  return new util.Base64Helper().decodeSync(encoded);
}
export function fromHex(value: string): Uint8Array {
  if (!/^(?:[a-fA-F0-9]{2})*$/.test(value)) throw new Error('INVALID_HEX');
  const result = new Uint8Array(value.length / 2);
  for (let index = 0; index < result.length; index++) result[index] = parseInt(value.substring(index * 2, index * 2 + 2), 16);
  return result;
}
export function toHex(value: Uint8Array): string {
  let result = '';
  for (const byte of value) result += byte.toString(16).padStart(2, '0');
  return result;
}
export function equalBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let different = 0;
  for (let index = 0; index < left.length; index++) different |= left[index] ^ right[index];
  return different === 0;
}
