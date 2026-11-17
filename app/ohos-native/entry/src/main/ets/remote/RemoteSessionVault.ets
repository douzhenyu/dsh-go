import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { RemoteAccount } from './RemoteAccount';
import { RemoteApiError, remoteObject, remoteString } from './RemoteDtos';
import { normalizeRemoteServer } from './RemoteServer';
import { sha256 } from './RemoteCrypto';
import { utf8, text, base64url } from './RemoteBytes';

class VaultHead {
  version: number = 1;
  serverUrl: string = '';
  generation: string = '';
  count: number = 0;
  length: number = 0;
  digest: string = '';
}
class VaultEnvelope {
  version: number = 1;
  serverUrl: string = '';
  accountSnapshot: string = '';
  lastHostId: string = '';
}
export class RemoteRestoredSession {
  account: RemoteAccount;
  lastHostId: string;
  constructor(account: RemoteAccount, lastHostId: string) {
    this.account = account; this.lastHostId = lastHostId;
  }
}
function nativeCode(error: ESObject): number {
  const value: ESObject = remoteObject(error);
  return typeof value.code === 'number' ? value.code : 0;
}
function invalid(): RemoteApiError { return new RemoteApiError('SECURE_SESSION_INVALID'); }
function unavailable(): RemoteApiError { return new RemoteApiError('SECURE_STORAGE_UNAVAILABLE'); }

// App-private OS-encrypted assets. No preference/file fallback and no per-launch biometric prompt.
// Each SECRET fits Asset's 1024-byte limit. Publish one head only after all new chunks exist;
// a failed/interrupted write therefore cannot replace a previously complete credential set.
export class RemoteSessionVault {
  private restoreStatus: string = 'empty';
  // Safe metadata only; retain the last restore outcome through later save/clear calls.
  get lastRestoreStatus(): string { return this.restoreStatus; }
  private queue: Promise<void> = Promise.resolve();
  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const pending = this.queue.then(operation);
    this.queue = pending.then(() => {}, () => {});
    return pending;
  }
  private digest(data: Uint8Array): string {
    try { return base64url(sha256(data)); } catch (_) { throw unavailable(); }
  }
  private scope(server: string): string { return this.digest(utf8(server)); }
  private alias(scope: string, suffix: string): Uint8Array { return utf8('dsh.remote.session.v1.' + scope + '.' + suffix); }
  private query(scope: string, suffix?: string): asset.AssetMap {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.DATA_LABEL_NORMAL_1, utf8(scope));
    if (suffix !== undefined) query.set(asset.Tag.ALIAS, this.alias(scope, suffix));
    return query;
  }
  private async read(scope: string, suffix: string): Promise<Uint8Array | undefined> {
    const query = this.query(scope, suffix); query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const values = await asset.query(query);
      if (values.length !== 1) throw invalid();
      const secret = values[0].get(asset.Tag.SECRET);
      if (!(secret instanceof Uint8Array) || secret.length < 1 || secret.length > 1024) throw invalid();
      return secret;
    } catch (error) {
      if (nativeCode(error) === 24000002) return undefined;
      if (nativeCode(error) === 24000007 || (error instanceof RemoteApiError && error.code === 'SECURE_SESSION_INVALID')) throw invalid();
      throw unavailable();
    }
  }
  private async write(scope: string, suffix: string, generation: string, secret: Uint8Array): Promise<void> {
    const attributes = this.query(scope, suffix);
    attributes.set(asset.Tag.DATA_LABEL_NORMAL_2, utf8(generation));
    attributes.set(asset.Tag.SECRET, secret);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try { await asset.add(attributes); } catch (_) { throw unavailable(); }
  }
  private async remove(query: asset.AssetMap): Promise<void> {
    try { await asset.remove(query); }
    catch (error) { if (nativeCode(error) !== 24000002) throw unavailable(); }
  }
  private async head(server: string, scope: string): Promise<VaultHead | undefined> {
    const secret = await this.read(scope, 'head');
    if (!secret) return undefined;
    try {
      const raw: ESObject = remoteObject(JSON.parse(text(secret)));
      if (raw.version !== 1 || raw.serverUrl !== server || !/^[a-zA-Z0-9-]{16,64}$/.test(remoteString(raw.generation)) ||
        !Number.isSafeInteger(raw.count) || raw.count < 1 || raw.count > 512 ||
        !Number.isSafeInteger(raw.length) || raw.length < 1 || raw.length > 524288 ||
        raw.count !== Math.ceil(raw.length / 1024) || !/^[A-Za-z0-9_-]{43}$/.test(remoteString(raw.digest))) throw invalid();
      const head = new VaultHead(); head.serverUrl = server; head.generation = raw.generation;
      head.count = raw.count; head.length = raw.length; head.digest = raw.digest; return head;
    } catch (_) { throw invalid(); }
    finally { secret.fill(0); }
  }
  async save(account: RemoteAccount, lastHostId: string): Promise<void> {
    const server = normalizeRemoteServer(account.serverUrl);
    const snapshot = account.exportSecureSnapshot();
    if (typeof lastHostId !== 'string' || utf8(lastHostId).length > 1024) throw invalid();
    // Capture before queueing: a later logout/rotation must never be overwritten by a late snapshot.
    if (snapshot === undefined) return this.clear(server);
    const envelope = new VaultEnvelope(); envelope.serverUrl = server;
    envelope.accountSnapshot = snapshot; envelope.lastHostId = lastHostId;
    const data = utf8(JSON.stringify(envelope));
    if (data.length > 524288) { data.fill(0); throw invalid(); }
    return this.enqueue<void>(async (): Promise<void> => {
      let scope = ''; let generation = ''; let committed = false;
      try {
        scope = this.scope(server); generation = util.generateRandomUUID(true);
        const old = await this.head(server, scope);
        const head = new VaultHead(); head.serverUrl = server; head.generation = generation;
        head.count = Math.ceil(data.length / 1024); head.length = data.length; head.digest = this.digest(data);
        for (let index = 0; index < head.count; index++) {
          const chunk = data.slice(index * 1024, (index + 1) * 1024);
          try { await this.write(scope, generation + '.' + index, generation, chunk); }
          finally { chunk.fill(0); }
        }
        const headBytes = utf8(JSON.stringify(head));
        try { await this.write(scope, 'head', 'head', headBytes); committed = true; }
        finally { headBytes.fill(0); }
        if (old) {
          const query = this.query(scope); query.set(asset.Tag.DATA_LABEL_NORMAL_2, utf8(old.generation));
          await this.remove(query);
        }
      } catch (error) {
        if (!committed && scope && generation) {
          const query = this.query(scope); query.set(asset.Tag.DATA_LABEL_NORMAL_2, utf8(generation));
          await this.remove(query);
        }
        if (error instanceof RemoteApiError) throw error;
        throw unavailable();
      } finally { data.fill(0); }
    });
  }
  async restore(serverUrl: string): Promise<RemoteRestoredSession | undefined> {
    let server = '';
    try { server = normalizeRemoteServer(serverUrl); }
    catch (error) { this.restoreStatus = 'invalid'; throw error as Error; }
    return this.enqueue<RemoteRestoredSession | undefined>(async (): Promise<RemoteRestoredSession | undefined> => {
      let scope = ''; let data = new Uint8Array(0); let account: RemoteAccount | undefined;
      try {
        scope = this.scope(server);
        const head = await this.head(server, scope);
        if (!head) { this.restoreStatus = 'empty'; return undefined; }
        data = new Uint8Array(head.length);
        for (let index = 0; index < head.count; index++) {
          const chunk = await this.read(scope, head.generation + '.' + index);
          if (!chunk) throw invalid();
          try {
            if (chunk.length !== Math.min(1024, head.length - index * 1024)) throw invalid();
            data.set(chunk, index * 1024);
          } finally { chunk.fill(0); }
        }
        if (this.digest(data) !== head.digest) throw invalid();
        const raw: ESObject = remoteObject(JSON.parse(text(data)));
        if (raw.version !== 1 || raw.serverUrl !== server || typeof raw.lastHostId !== 'string' ||
          utf8(raw.lastHostId).length > 1024 || !remoteString(raw.accountSnapshot)) throw invalid();
        account = new RemoteAccount(server); account.restoreSecureSnapshot(raw.accountSnapshot);
        this.restoreStatus = 'restored';
        return new RemoteRestoredSession(account, raw.lastHostId);
      } catch (error) {
        account?.close();
        if (error instanceof RemoteApiError && error.code === 'SECURE_STORAGE_UNAVAILABLE') {
          this.restoreStatus = 'unavailable'; throw error;
        }
        try { await this.remove(this.query(scope)); }
        catch (cleanupError) { this.restoreStatus = 'unavailable'; throw cleanupError as Error; }
        if (error instanceof RemoteApiError && error.code === 'ACCOUNT_AUTH_REQUIRED') {
          this.restoreStatus = 'expired'; return undefined;
        }
        this.restoreStatus = 'invalid'; throw invalid();
      } finally { data.fill(0); }
    });
  }
  async clear(serverUrl: string): Promise<void> {
    const server = normalizeRemoteServer(serverUrl);
    return this.enqueue<void>((): Promise<void> => this.remove(this.query(this.scope(server))));
  }
}
