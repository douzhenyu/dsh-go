import { util } from '@kit.ArkTS';
import { parseObject } from '../data/NativeDecode';

// One NativeClient.rpc-compatible call. Transport/authentication and connection
// generations belong to the caller; this service never owns or replays a write.
export type HostRpc = (endpoint: string, argsJson: string) => Promise<string>;

export class HostSettingsOp {
  op: string = 'set'; // set | unset
  path: string[] = [];
  valueJson?: string;
}
export class HostSettingField {
  path: string[] = [];
  kind: string = 'readonly'; // boolean | string | number | enum | secret | readonly
  title: string = '';
  description: string = '';
  valueJson: string = 'null';
  choices: string[] = [];
  choiceLabels: string[] = [];
  min?: number;
  max?: number;
  secret: boolean = false;
  configured: boolean = false;
  disabled: boolean = true;
}
export class HostSettingsNamespace {
  ns: string = '';
  valueJson: string = '{}';
  baseJson: string = 'null';
  userJson: string = 'null';
  revision: number = 0;
  writable: boolean = false;
  fields: HostSettingField[] = [];
}
export class HostSettingsSnapshot {
  namespaces: HostSettingsNamespace[] = [];
  writable: boolean = false;
}
export class AgentPresetInfo {
  id: string = '';
  name: string = '';
  description: string = '';
  isDefault: boolean = false;
  broken: string = '';
}
export class AgentPresetDocument {
  id: string = '';
  name: string = '';
  description: string = '';
  content: string = '';
}
export class NativePluginInfo {
  name: string = '';
  enabled: boolean = false;
  description: string = '';
}
export class DefaultPermissionOption {
  id: string = '';
  name: string = '';
  description: string = '';
  defaultAllowed: boolean = false;
}
export class DefaultPermissionInfo {
  current: string = '';
  default: string = '';
  revision: number = -1;
  writable: boolean = false;
  options: DefaultPermissionOption[] = [];
}
export class DefaultModelInfo {
  provider: string = '';
  model: string = '';
  reasoningEffort: string = '';
  rememberLastSelection: boolean = true;
  rememberLastSelectionSupported: boolean = false;
  revision: number = -1;
  writable: boolean = false;
}

const MAX_PATH: number = 8;
const MAX_OPS: number = 64;
const MAX_FIELDS: number = 64;
const MAX_DEPTH: number = 4;
const MAX_ID: number = 256;
const MAX_JSON_BYTES: number = 256 * 1024;
const MISSING: ESObject = parseObject('{"missing":true}');

function emptyObject(): ESObject { return parseObject('{}'); }
function object(value: ESObject): ESObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? value : emptyObject();
}
function array(value: ESObject): ESObject[] { return Array.isArray(value) ? value as ESObject[] : []; }
function text(value: ESObject): string { return typeof value === 'string' ? value as string : ''; }
function bool(value: ESObject): boolean { return value === true; }
function finite(value: ESObject): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value as number : undefined;
}
function bytes(value: string): number { return new util.TextEncoder().encodeInto(value).length; }
function fail(code: string): Error { return new Error(code); }
function validCode(code: string): boolean { return /^[A-Za-z0-9_/-]{1,100}$/.test(code); }

// NativeClient currently carries its safe code in Error.message. Read that
// bounded code envelope only; never propagate an arbitrary Host message/detail.
function hostError(failure: ESObject): Error {
  const raw: ESObject = object(failure);
  const explicit: string = text(raw.code);
  if (validCode(explicit)) return fail(explicit);
  const message: string = text(raw.message);
  const match: RegExpExecArray | null = /^REMOTE: ([A-Za-z0-9_/-]{1,100})$/.exec(message);
  const code: string = match ? match[1] : message;
  return fail(validCode(code) ? code : 'REMOTE_ERROR');
}
async function call(rpc: HostRpc, endpoint: string, args: ESObject): Promise<ESObject> {
  let encoded: string;
  try { encoded = await rpc(endpoint, JSON.stringify(args)); }
  catch (failure) { throw hostError(failure); }
  try { return JSON.parse(encoded) as ESObject; }
  catch (_) { throw fail('PROTOCOL_ERROR'); }
}
async function callRaw(rpc: HostRpc, endpoint: string, args: ESObject): Promise<string> {
  let encoded: string;
  try { encoded = await rpc(endpoint, JSON.stringify(args)); }
  catch (failure) { throw hostError(failure); }
  try { JSON.parse(encoded); return encoded; }
  catch (_) { throw fail('PROTOCOL_ERROR'); }
}
function identifier(value: string, code: string = 'INVALID_ID'): string {
  if (!value || value.length > MAX_ID || /[\u0000-\u001f\u007f]/.test(value)) throw fail(code);
  return value;
}
function namespaceId(value: string): string {
  if (!value || value.length > 128 || /[\u0000-\u001f\u007f]/.test(value)) throw fail('INVALID_NS');
  return value;
}
function revision(value: ESObject, fallback: number = 0): number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0 ? value as number : fallback;
}
function expectedRevision(value?: number): number | undefined {
  if (value === undefined) return undefined;
  if (!Number.isSafeInteger(value) || value < 0) throw fail('INVALID_REVISION');
  return value;
}
function withRevision(args: ESObject, value?: number): ESObject {
  const checked: number | undefined = expectedRevision(value);
  if (checked !== undefined) args.expectedRevision = checked;
  return args;
}
function lookup(root: ESObject, path: string[]): ESObject {
  let current: ESObject = root;
  for (const key of path) {
    if (Array.isArray(current)) {
      if (!/^\d+$/.test(key)) return MISSING;
      const index: number = Number(key);
      const values: ESObject[] = current as ESObject[];
      if (index >= values.length) return MISSING;
      current = values[index];
    } else if (current !== null && typeof current === 'object') {
      const map: ESObject = object(current);
      if (Object.keys(map).indexOf(key) < 0) return MISSING;
      current = map[key];
    } else return MISSING;
  }
  return current;
}
function boundedJson(value: ESObject, cap: number = MAX_JSON_BYTES): string {
  if (value === undefined || value === MISSING) return 'null';
  let encoded: string;
  try { encoded = JSON.stringify(value === undefined ? null : value); }
  catch (_) { throw fail('PROTOCOL_ERROR'); }
  if (bytes(encoded) <= cap) return encoded;
  const truncated: ESObject = emptyObject();
  truncated.truncated = true;
  return JSON.stringify(truncated);
}
function localized(value: ESObject): string {
  if (typeof value === 'string') return (value as string).trim();
  const map: ESObject = object(value);
  const keys: string[] = Object.keys(map);
  const preferred: string[] = ['zh-CN', 'zh', 'en', 'default', ''];
  for (const key of preferred) {
    if (typeof map[key] === 'string' && (map[key] as string).trim()) return (map[key] as string).trim();
  }
  for (const key of keys) {
    if (/^zh(?:-|$)/i.test(key) && typeof map[key] === 'string' && (map[key] as string).trim()) return (map[key] as string).trim();
  }
  for (const key of keys) {
    if (/^en(?:-|$)/i.test(key) && typeof map[key] === 'string' && (map[key] as string).trim()) return (map[key] as string).trim();
  }
  for (const key of keys) {
    if (typeof map[key] === 'string' && (map[key] as string).trim()) return (map[key] as string).trim();
  }
  return '';
}
function humanize(key: string): string {
  const spaced: string = key.replace(/([a-z0-9])([A-Z])/g, '$1 $2').replace(/[_\-.]+/g, ' ').trim();
  return spaced ? spaced.charAt(0).toUpperCase() + spaced.substring(1) : key;
}

function nodeAt(schema: ESObject, ref: ESObject): ESObject {
  const refs: ESObject = object(schema.refs);
  if (Object.keys(refs).length > 0) return object(refs[String(ref)]);
  return object(ref);
}
function rootNode(schema: ESObject): ESObject {
  return Object.keys(object(schema.refs)).length > 0 ? nodeAt(schema, schema.uid) : schema;
}
function effective(schema: ESObject, source: ESObject): ESObject {
  let node: ESObject = source;
  const seen: Set<ESObject> = new Set<ESObject>();
  for (let depth: number = 0; depth < MAX_DEPTH; depth++) {
    if (seen.has(node)) break;
    seen.add(node);
    const type: string = text(node.type);
    if ((type !== 'transform' && type !== 'lazy') || node.inner === undefined) break;
    node = nodeAt(schema, node.inner);
  }
  return node;
}
function nullConst(node: ESObject): boolean {
  return text(node.type) === 'const' && (node.value === null || node.value === undefined);
}
function valueNode(schema: ESObject, source: ESObject): ESObject {
  const node: ESObject = effective(schema, source);
  if (text(node.type) !== 'union') return node;
  const members: ESObject[] = [];
  const refs: ESObject[] = array(node.list);
  for (let refIndex: number = 0; refIndex < refs.length; refIndex++) {
    const ref: ESObject = refs[refIndex];
    const member: ESObject = effective(schema, nodeAt(schema, ref));
    if (!nullConst(member)) members.push(member);
  }
  if (members.length === 1 && text(members[0].type) !== 'const') return members[0];
  return node;
}
function objectFields(schema: ESObject, source: ESObject): ESObject | undefined {
  const node: ESObject = valueNode(schema, source);
  const type: string = text(node.type);
  if (type === 'object') return object(node.dict);
  if (type !== 'intersect') return undefined;
  const merged: ESObject = emptyObject();
  const refs: ESObject[] = array(node.list);
  for (let refIndex: number = 0; refIndex < refs.length; refIndex++) {
    const ref: ESObject = refs[refIndex];
    const fields: ESObject | undefined = objectFields(schema, nodeAt(schema, ref));
    if (fields === undefined) return undefined;
    const keys: string[] = Object.keys(fields);
    for (const key of keys) merged[key] = fields[key];
  }
  return merged;
}
function secretNode(schema: ESObject, source: ESObject): boolean {
  const role: string = text(object(source.meta).role);
  const node: ESObject = effective(schema, source);
  const effectiveRole: string = text(object(node.meta).role);
  return role === 'secret' || role === 'credential-ref' || effectiveRole === 'secret' || effectiveRole === 'credential-ref';
}
function containsSecret(schema: ESObject, source: ESObject, depth: number = 0, seen: Set<ESObject> = new Set<ESObject>()): boolean {
  if (secretNode(schema, source)) return true;
  if (depth >= MAX_DEPTH || seen.has(source)) return false;
  seen.add(source);
  const node: ESObject = effective(schema, source);
  if (node !== source && containsSecret(schema, node, depth + 1, seen)) return true;
  const dict: ESObject = object(node.dict);
  const keys: string[] = Object.keys(dict);
  for (const key of keys) {
    if (containsSecret(schema, nodeAt(schema, dict[key]), depth + 1, seen)) return true;
  }
  const refs: ESObject[] = array(node.list);
  for (let refIndex: number = 0; refIndex < refs.length; refIndex++) {
    const ref: ESObject = refs[refIndex];
    if (containsSecret(schema, nodeAt(schema, ref), depth + 1, seen)) return true;
  }
  return node.inner !== undefined && containsSecret(schema, nodeAt(schema, node.inner), depth + 1, seen);
}
function secretPath(slot: ESObject): string[] {
  const result: string[] = [];
  const parts: ESObject[] = array(slot.path);
  for (let partIndex: number = 0; partIndex < parts.length; partIndex++) {
    const part: ESObject = parts[partIndex]; result.push(text(part));
  }
  return result;
}
function pathEqual(left: string[], right: string[]): boolean {
  if (left.length !== right.length) return false;
  for (let index: number = 0; index < left.length; index++) if (left[index] !== right[index]) return false;
  return true;
}
function pathPrefix(prefix: string[], path: string[]): boolean {
  if (path.length < prefix.length) return false;
  for (let index: number = 0; index < prefix.length; index++) if (prefix[index] !== path[index]) return false;
  return true;
}
function secretExact(path: string[], secrets: ESObject[]): boolean {
  for (let slotIndex: number = 0; slotIndex < secrets.length; slotIndex++) {
    const slot: ESObject = secrets[slotIndex];
    if (pathEqual(secretPath(slot), path)) return true;
  }
  return false;
}
function secretBelow(path: string[], secrets: ESObject[], configuredOnly: boolean = false): boolean {
  for (let slotIndex: number = 0; slotIndex < secrets.length; slotIndex++) {
    const slot: ESObject = secrets[slotIndex];
    if (configuredOnly && slot.set !== true) continue;
    if (pathPrefix(path, secretPath(slot))) return true;
  }
  return false;
}

interface Sanitized { keep: boolean; value: ESObject; }
function keep(value: ESObject): Sanitized { return { keep: true, value }; }
function drop(): Sanitized { return { keep: false, value: null }; }
function sanitize(value: ESObject, schema: ESObject, source: ESObject, path: string[], secrets: ESObject[], depth: number = 0): Sanitized {
  if (value === MISSING) return keep(MISSING);
  if (secretNode(schema, source) || secretExact(path, secrets)) return drop();
  const node: ESObject = valueNode(schema, source);
  if (depth >= MAX_DEPTH) return containsSecret(schema, source) || secretBelow(path, secrets) ? drop() : keep(value);
  const fields: ESObject | undefined = objectFields(schema, node);
  if (fields !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value)) {
    const result: ESObject = emptyObject();
    const input: ESObject = object(value);
    const keys: string[] = Object.keys(input);
    for (const key of keys) {
      const child: ESObject = fields[key];
      const childSchema: ESObject = child === undefined ? emptyObject() : nodeAt(schema, child);
      const clean: Sanitized = sanitize(input[key], schema, childSchema, path.concat([key]), secrets, depth + 1);
      if (clean.keep) result[key] = clean.value;
    }
    return keep(result);
  }
  const type: string = text(node.type);
  if (type === 'array' && Array.isArray(value) && node.inner !== undefined) {
    const result: ESObject[] = [];
    const values: ESObject[] = value as ESObject[];
    for (let index: number = 0; index < values.length; index++) {
      const clean: Sanitized = sanitize(values[index], schema, nodeAt(schema, node.inner), path.concat([`${index}`]), secrets, depth + 1);
      result.push(clean.keep ? clean.value : null);
    }
    return keep(result);
  }
  if (type === 'dict' && value !== null && typeof value === 'object' && !Array.isArray(value) && node.inner !== undefined) {
    const result: ESObject = emptyObject();
    const input: ESObject = object(value);
    const keys: string[] = Object.keys(input);
    for (const key of keys) {
      const clean: Sanitized = sanitize(input[key], schema, nodeAt(schema, node.inner), path.concat([key]), secrets, depth + 1);
      if (clean.keep) result[key] = clean.value;
    }
    return keep(result);
  }
  // secrets[] remains authoritative even when a damaged Host omitted schema.
  if (fields === undefined && node.inner === undefined && secretBelow(path, secrets) && value !== null && typeof value === 'object') {
    if (Array.isArray(value)) {
      const result: ESObject[] = [];
      const values: ESObject[] = value as ESObject[];
      for (let index: number = 0; index < values.length; index++) {
        const clean: Sanitized = sanitize(values[index], schema, emptyObject(), path.concat([`${index}`]), secrets, depth + 1);
        result.push(clean.keep ? clean.value : null);
      }
      return keep(result);
    }
    const result: ESObject = emptyObject();
    const input: ESObject = object(value);
    const keys: string[] = Object.keys(input);
    for (const key of keys) {
      const clean: Sanitized = sanitize(input[key], schema, emptyObject(), path.concat([key]), secrets, depth + 1);
      if (clean.keep) result[key] = clean.value;
    }
    return keep(result);
  }
  // An opaque union cannot be inspected branch-safely when any variant is secret.
  if ((type === 'union' || type === 'intersect' || type === 'tuple') &&
    (containsSecret(schema, source) || secretBelow(path, secrets))) return drop();
  return keep(value);
}
function enumMembers(schema: ESObject, node: ESObject): ESObject[] | undefined {
  const type: string = text(node.type);
  if (type === 'const') return [node];
  if (type !== 'union') return undefined;
  const members: ESObject[] = [];
  const refs: ESObject[] = array(node.list);
  for (let refIndex: number = 0; refIndex < refs.length; refIndex++) {
    const ref: ESObject = refs[refIndex];
    const member: ESObject = effective(schema, nodeAt(schema, ref));
    if (!nullConst(member)) members.push(member);
  }
  if (members.length === 0) return undefined;
  for (let memberIndex: number = 0; memberIndex < members.length; memberIndex++) {
    const member: ESObject = members[memberIndex];
    if (text(member.type) !== 'const') return undefined;
  }
  return members;
}
function choice(value: ESObject): string {
  if (value === null) return 'null';
  if (value === undefined) return 'undefined';
  return typeof value === 'string' ? value as string : JSON.stringify(value);
}
function addField(output: HostSettingField[], schema: ESObject, source: ESObject, path: string[],
  safeValue: ESObject, safeBase: ESObject, secrets: ESObject[], inheritedDisabled: boolean, writable: boolean): void {
  if (output.length >= MAX_FIELDS) return;
  const node: ESObject = valueNode(schema, source);
  if (bool(object(source.meta).hidden) || bool(object(node.meta).hidden)) return;
  const field: HostSettingField = new HostSettingField();
  field.path = path;
  field.title = localized(object(source.meta).title) || localized(object(node.meta).title) || humanize(path[path.length - 1]);
  field.description = localized(object(source.meta).description) || localized(object(node.meta).description);
  const complexSecret: boolean = containsSecret(schema, source);
  field.secret = secretNode(schema, source) || secretExact(path, secrets) || complexSecret;
  field.configured = field.secret && secretBelow(path, secrets, true);
  const disabled: boolean = inheritedDisabled || bool(object(source.meta).disabled) || bool(object(node.meta).disabled);
  let stored: ESObject = lookup(safeValue, path);
  if (stored === MISSING) stored = lookup(safeBase, path);
  if (stored === MISSING) {
    stored = object(source.meta).default !== undefined ? object(source.meta).default : object(node.meta).default;
  }
  if (field.secret) {
    field.kind = 'secret'; field.valueJson = 'null'; field.disabled = true;
    output.push(field); return;
  }
  const members: ESObject[] | undefined = enumMembers(schema, node);
  if (members !== undefined) {
    field.kind = 'enum';
    for (let memberIndex: number = 0; memberIndex < members.length; memberIndex++) {
      const member: ESObject = members[memberIndex];
      field.choices.push(choice(member.value));
      field.choiceLabels.push(localized(object(member.meta).description) || choice(member.value));
    }
  } else {
    const type: string = text(node.type);
    if (type === 'boolean' || type === 'string' || type === 'number') field.kind = type;
    else field.kind = 'readonly';
  }
  if (field.kind === 'number') {
    field.min = finite(object(node.meta).min) ?? finite(object(source.meta).min);
    field.max = finite(object(node.meta).max) ?? finite(object(source.meta).max);
  }
  field.valueJson = boundedJson(stored, field.kind === 'readonly' ? 64 * 1024 : MAX_JSON_BYTES);
  field.disabled = disabled || !writable || field.kind === 'readonly';
  output.push(field);
}
function walkFields(output: HostSettingField[], schema: ESObject, source: ESObject, path: string[],
  safeValue: ESObject, safeBase: ESObject, secrets: ESObject[], disabled: boolean, writable: boolean): void {
  if (output.length >= MAX_FIELDS || path.length > MAX_DEPTH) return;
  const node: ESObject = valueNode(schema, source);
  const fields: ESObject | undefined = objectFields(schema, node);
  const nextDisabled: boolean = disabled || bool(object(source.meta).disabled) || bool(object(node.meta).disabled);
  if (fields !== undefined && path.length < MAX_DEPTH) {
    const keys: string[] = Object.keys(fields);
    for (const key of keys) {
      walkFields(output, schema, nodeAt(schema, fields[key]), path.concat([key]), safeValue, safeBase, secrets, nextDisabled, writable);
      if (output.length >= MAX_FIELDS) break;
    }
    return;
  }
  if (path.length > 0) addField(output, schema, source, path, safeValue, safeBase, secrets, nextDisabled, writable);
}
function namespaceView(raw: ESObject, envelopeWritable: boolean): HostSettingsNamespace {
  const result: HostSettingsNamespace = new HostSettingsNamespace();
  result.ns = text(raw.ns);
  if (!result.ns) throw fail('PROTOCOL_ERROR');
  result.revision = revision(raw.revision);
  result.writable = envelopeWritable;
  const schema: ESObject = object(raw.schema);
  const root: ESObject = rootNode(schema);
  const secrets: ESObject[] = [];
  const rawSecrets: ESObject[] = array(raw.secrets);
  for (let slotIndex: number = 0; slotIndex < rawSecrets.length; slotIndex++) {
    const slot: ESObject = rawSecrets[slotIndex]; secrets.push(object(slot));
  }
  const value: Sanitized = sanitize(raw.value === undefined ? emptyObject() : raw.value, schema, root, [], secrets);
  const base: Sanitized = sanitize(raw.base === undefined ? null : raw.base, schema, root, [], secrets);
  const user: Sanitized = sanitize(raw.user === undefined ? null : raw.user, schema, root, [], secrets);
  const safeValue: ESObject = value.keep ? value.value : emptyObject();
  const safeBase: ESObject = base.keep ? base.value : null;
  result.valueJson = boundedJson(safeValue);
  result.baseJson = boundedJson(safeBase);
  result.userJson = boundedJson(user.keep ? user.value : null);
  walkFields(result.fields, schema, root, [], safeValue, safeBase, secrets, false, envelopeWritable);
  return result;
}
function description(raw: ESObject): ESObject {
  const root: ESObject = object(raw);
  if (!Array.isArray(root.namespaces)) throw fail('PROTOCOL_ERROR');
  return root;
}
async function readDescription(rpc: HostRpc): Promise<ESObject> { return description(await call(rpc, 'settings/describe', emptyObject())); }
function namespaceOf(described: ESObject, ns: string): ESObject | undefined {
  const rows: ESObject[] = array(described.namespaces);
  for (let itemIndex: number = 0; itemIndex < rows.length; itemIndex++) {
    const item: ESObject = rows[itemIndex];
    const row: ESObject = object(item);
    if (text(row.ns) === ns) return row;
  }
  return undefined;
}

export async function describe(rpc: HostRpc): Promise<HostSettingsSnapshot> {
  const raw: ESObject = await readDescription(rpc);
  const result: HostSettingsSnapshot = new HostSettingsSnapshot();
  result.writable = raw.writable !== false;
  const rows: ESObject[] = array(raw.namespaces);
  for (let rowIndex: number = 0; rowIndex < rows.length; rowIndex++) {
    const row: ESObject = rows[rowIndex];
    result.namespaces.push(namespaceView(object(row), result.writable));
  }
  return result;
}
export async function mutate(rpc: HostRpc, ns: string, ops: HostSettingsOp[], expected?: number): Promise<HostSettingsNamespace> {
  namespaceId(ns);
  const checkedRevision: number | undefined = expectedRevision(expected);
  if (!Array.isArray(ops) || ops.length < 1 || ops.length > MAX_OPS) throw fail('INVALID_OPS');
  const wireOps: ESObject[] = [];
  for (const op of ops) {
    if ((op.op !== 'set' && op.op !== 'unset') || !Array.isArray(op.path) || op.path.length < 1 || op.path.length > MAX_PATH) {
      throw fail('INVALID_OPERATION');
    }
    const path: string[] = [];
    for (const part of op.path) path.push(identifier(part, 'INVALID_PATH'));
    const wireOp: ESObject = emptyObject();
    wireOp.op = op.op;
    wireOp.path = path;
    if (op.op === 'set') {
      if (op.valueJson === undefined || bytes(op.valueJson) > MAX_JSON_BYTES) throw fail('INVALID_VALUE');
      let value: ESObject;
      try { value = JSON.parse(op.valueJson) as ESObject; }
      catch (_) { throw fail('INVALID_VALUE'); }
      wireOp.value = value;
    }
    wireOps.push(wireOp);
  }
  const args: ESObject = emptyObject();
  args.ns = ns;
  args.ops = wireOps;
  if (checkedRevision !== undefined) args.expectedRevision = checkedRevision;
  // Exactly one call: conflict/transport outcomes are for the caller to resolve.
  const raw: ESObject = object(await call(rpc, 'settings/mutate', args));
  if (text(raw.ns) !== ns || typeof raw.revision !== 'number' || !Number.isSafeInteger(raw.revision) || raw.revision < 0) {
    throw fail('PROTOCOL_ERROR');
  }
  return namespaceView(raw, raw.writable === undefined ? true : raw.writable === true);
}

export async function agentPresets(rpc: HostRpc): Promise<AgentPresetInfo[]> {
  const raw: ESObject = object(await call(rpc, 'agentPresets/list', emptyObject()));
  const output: AgentPresetInfo[] = [];
  const rows: ESObject[] = array(raw.presets);
  for (let itemIndex: number = 0; itemIndex < rows.length; itemIndex++) {
    const item: ESObject = rows[itemIndex];
    const row: ESObject = object(item);
    const result: AgentPresetInfo = new AgentPresetInfo();
    result.id = text(row.id); result.name = text(row.name); result.description = text(row.description);
    result.isDefault = row.isDefault === true; result.broken = text(row.broken);
    if (result.id) output.push(result);
  }
  return output;
}
export async function readAgentPreset(rpc: HostRpc, id: string): Promise<AgentPresetDocument> {
  identifier(id, 'INVALID_PRESET');
  const args: ESObject = emptyObject(); args.agentPreset = id;
  const raw: ESObject = object(await call(rpc, 'agentPresets/read', args));
  const result: AgentPresetDocument = new AgentPresetDocument();
  result.id = text(raw.agentPreset) || id; result.name = text(raw.name); result.description = text(raw.description);
  result.content = text(raw.content);
  if (bytes(result.content) > MAX_JSON_BYTES) throw fail('CONTENT_TOO_LARGE');
  return result;
}
export async function selectAgentPreset(rpc: HostRpc, id: string, expected?: number): Promise<string> {
  identifier(id, 'INVALID_PRESET');
  const patch: ESObject = emptyObject(); patch.selectedDefault = id;
  const args: ESObject = emptyObject(); args.ns = 'agent-preset-registry'; args.patch = patch;
  withRevision(args, expected);
  return callRaw(rpc, 'settings/update', args);
}

export async function plugins(rpc: HostRpc): Promise<NativePluginInfo[]> {
  const raw: ESObject = await call(rpc, 'pluginManager/listBundles', emptyObject());
  const output: NativePluginInfo[] = [];
  const rows: ESObject[] = array(raw);
  for (let itemIndex: number = 0; itemIndex < rows.length; itemIndex++) {
    const item: ESObject = rows[itemIndex];
    const row: ESObject = object(item);
    const result: NativePluginInfo = new NativePluginInfo();
    result.name = text(row.name); result.enabled = row.enabled === true;
    result.description = localized(object(row.meta).description) || text(row.description);
    if (result.name) output.push(result);
  }
  return output;
}
export async function setBundleEnabled(rpc: HostRpc, name: string, enabled: boolean): Promise<string> {
  identifier(name, 'INVALID_PLUGIN');
  const args: ESObject = emptyObject(); args.name = name; args.enabled = enabled;
  return callRaw(rpc, 'pluginManager/setBundleEnabled', args);
}
export async function setPluginEnabled(rpc: HostRpc, entryId: string, enabled: boolean): Promise<string> {
  identifier(entryId, 'INVALID_PLUGIN');
  const args: ESObject = emptyObject(); args.id = entryId; args.enabled = enabled;
  return callRaw(rpc, 'pluginManager/setPluginEnabled', args);
}

function permissionOptions(catalog: ESObject): DefaultPermissionOption[] {
  const output: DefaultPermissionOption[] = [];
  const defaults: string[] = [];
  if (Array.isArray(catalog.defaultOptions)) {
    const rows: ESObject[] = array(catalog.defaultOptions);
    for (let itemIndex: number = 0; itemIndex < rows.length; itemIndex++) {
      const item: ESObject = rows[itemIndex]; defaults.push(text(object(item).value));
    }
  } else {
    const rows: ESObject[] = array(catalog.options);
    for (let itemIndex: number = 0; itemIndex < rows.length; itemIndex++) {
    const item: ESObject = rows[itemIndex];
      const id: string = text(object(item).value);
      if (id !== 'auto') defaults.push(id);
    }
  }
  const rows: ESObject[] = array(catalog.options);
  for (let itemIndex: number = 0; itemIndex < rows.length; itemIndex++) {
    const item: ESObject = rows[itemIndex];
    const row: ESObject = object(item);
    const result: DefaultPermissionOption = new DefaultPermissionOption();
    result.id = text(row.value); result.name = text(row.name); result.description = text(row.description);
    // Auto is session-only; persisting it can prevent permission startup on older Hosts.
    result.defaultAllowed = result.id !== 'auto' && defaults.indexOf(result.id) >= 0;
    if (result.id) output.push(result);
  }
  return output;
}
export async function defaultPermission(rpc: HostRpc): Promise<DefaultPermissionInfo> {
  const catalog: ESObject = object(await call(rpc, 'permissionPresets/catalog', emptyObject()));
  const described: ESObject = await readDescription(rpc);
  const section: ESObject | undefined = namespaceOf(described, 'permission');
  const result: DefaultPermissionInfo = new DefaultPermissionInfo();
  result.default = text(catalog.defaultPreset);
  result.current = section === undefined ? result.default : text(object(section.value).defaultPreset) || result.default;
  result.revision = section === undefined ? -1 : revision(section.revision, -1);
  result.writable = described.writable !== false && section !== undefined;
  result.options = permissionOptions(catalog);
  return result;
}
export async function setDefaultPermission(rpc: HostRpc, id: string, expected?: number): Promise<HostSettingsNamespace> {
  identifier(id, 'INVALID_PERMISSION');
  const catalog: ESObject = object(await call(rpc, 'permissionPresets/catalog', emptyObject()));
  const options: DefaultPermissionOption[] = permissionOptions(catalog);
  let allowed: boolean = false;
  for (const option of options) if (option.id === id && option.defaultAllowed) allowed = true;
  if (!allowed) throw fail('PERMISSION_NOT_ALLOWED');
  const op: HostSettingsOp = new HostSettingsOp(); op.op = 'set'; op.path = ['defaultPreset']; op.valueJson = JSON.stringify(id);
  return mutate(rpc, 'permission', [op], expected);
}

export async function defaultModel(rpc: HostRpc): Promise<DefaultModelInfo> {
  const described: ESObject = await readDescription(rpc);
  const section: ESObject | undefined = namespaceOf(described, 'agent-default-model');
  const result: DefaultModelInfo = new DefaultModelInfo();
  if (section === undefined) return result;
  const value: ESObject = object(section.value);
  result.provider = text(value.provider); result.model = text(value.model); result.reasoningEffort = text(value.reasoningEffort);
  result.revision = revision(section.revision, -1); result.writable = described.writable !== false;
  const schema: ESObject = object(section.schema);
  const fields: ESObject = objectFields(schema, rootNode(schema)) || emptyObject();
  if (fields.rememberLastSelection !== undefined) {
    const node: ESObject = valueNode(schema, nodeAt(schema, fields.rememberLastSelection));
    result.rememberLastSelectionSupported = text(node.type) === 'boolean';
  }
  if (typeof value.rememberLastSelection === 'boolean') result.rememberLastSelection = value.rememberLastSelection as boolean;
  return result;
}
export async function setDefaultModel(rpc: HostRpc, provider: string, model: string, effort: string,
  remember?: boolean, expected?: number): Promise<HostSettingsNamespace> {
  identifier(provider, 'INVALID_PROVIDER'); identifier(model, 'INVALID_MODEL');
  if (effort.length > MAX_ID || /[\u0000-\u001f\u007f]/.test(effort)) throw fail('INVALID_EFFORT');
  const ops: HostSettingsOp[] = [];
  const providerOp: HostSettingsOp = new HostSettingsOp(); providerOp.op = 'set'; providerOp.path = ['provider']; providerOp.valueJson = JSON.stringify(provider);
  const modelOp: HostSettingsOp = new HostSettingsOp(); modelOp.op = 'set'; modelOp.path = ['model']; modelOp.valueJson = JSON.stringify(model);
  const effortOp: HostSettingsOp = new HostSettingsOp(); effortOp.op = effort ? 'set' : 'unset'; effortOp.path = ['reasoningEffort'];
  if (effort) effortOp.valueJson = JSON.stringify(effort);
  ops.push(providerOp, modelOp, effortOp);
  if (remember !== undefined) {
    const rememberOp: HostSettingsOp = new HostSettingsOp(); rememberOp.op = 'set'; rememberOp.path = ['rememberLastSelection'];
    rememberOp.valueJson = JSON.stringify(remember); ops.push(rememberOp);
  }
  return mutate(rpc, 'agent-default-model', ops, expected);
}
export async function setRememberLastModel(rpc: HostRpc, remember: boolean, expected?: number): Promise<HostSettingsNamespace> {
  const op: HostSettingsOp = new HostSettingsOp(); op.op = 'set'; op.path = ['rememberLastSelection']; op.valueJson = JSON.stringify(remember);
  return mutate(rpc, 'agent-default-model', [op], expected);
}

export class NativeHostSettingsService {
  describe: (rpc: HostRpc) => Promise<HostSettingsSnapshot> = describe;
  mutate: (rpc: HostRpc, ns: string, ops: HostSettingsOp[], expected?: number) => Promise<HostSettingsNamespace> = mutate;
  agentPresets: (rpc: HostRpc) => Promise<AgentPresetInfo[]> = agentPresets;
  readAgentPreset: (rpc: HostRpc, id: string) => Promise<AgentPresetDocument> = readAgentPreset;
  selectAgentPreset: (rpc: HostRpc, id: string, expected?: number) => Promise<string> = selectAgentPreset;
  plugins: (rpc: HostRpc) => Promise<NativePluginInfo[]> = plugins;
  setBundleEnabled: (rpc: HostRpc, name: string, enabled: boolean) => Promise<string> = setBundleEnabled;
  setPluginEnabled: (rpc: HostRpc, entryId: string, enabled: boolean) => Promise<string> = setPluginEnabled;
  defaultPermission: (rpc: HostRpc) => Promise<DefaultPermissionInfo> = defaultPermission;
  setDefaultPermission: (rpc: HostRpc, id: string, expected?: number) => Promise<HostSettingsNamespace> = setDefaultPermission;
  defaultModel: (rpc: HostRpc) => Promise<DefaultModelInfo> = defaultModel;
  setDefaultModel: (rpc: HostRpc, provider: string, model: string, effort: string,
    remember?: boolean, expected?: number) => Promise<HostSettingsNamespace> = setDefaultModel;
  setRememberLastModel: (rpc: HostRpc, remember: boolean, expected?: number) => Promise<HostSettingsNamespace> = setRememberLastModel;
}

// Stateless singleton for ArkUI. The standalone exports remain useful to tests.
export const nativeHostSettings: NativeHostSettingsService = new NativeHostSettingsService();
