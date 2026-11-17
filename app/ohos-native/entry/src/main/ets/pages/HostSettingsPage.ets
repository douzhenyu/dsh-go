import {
  HostSettingsSnapshot, HostSettingsNamespace, HostSettingField, HostSettingsOp,
  AgentPresetInfo, AgentPresetDocument, NativePluginInfo, DefaultPermissionInfo, DefaultPermissionOption, DefaultModelInfo
} from '../state/NativeHostSettings';
import { appStore, ModelChoice } from '../state/AppStore';
import { DetailTitle } from '../components/DetailTitle';
import {
  GAP_CARD, GAP_LARGE, GAP_NORMAL, MARGIN_EDGE, RADIUS_CARD,
  barMaterial, floatingMaterial, titleBarOptions
} from '../common/Style';

function choices(items: string[]): SelectOption[] { return items.map((item: string): SelectOption => ({ value: item })); }
function errorCode(error: Error): string {
  if (/^[A-Za-z0-9_/-]{1,100}$/.test(error.message)) return error.message;
  const prefix = error.message.split(':')[0];
  return /^[A-Za-z0-9_/-]{1,100}$/.test(prefix) ? prefix : 'HOST_SETTINGS_FAILED';
}
function valueAt(root: ESObject, path: string[]): ESObject {
  let current: ESObject = root;
  for (const key of path) {
    if (current === null || typeof current !== 'object' || Array.isArray(current)) return undefined;
    current = current[key as keyof ESObject];
  }
  return current;
}

@Component
export struct HostSettingsPage {
  stack: NavPathStack = new NavPathStack();
  page: string = 'models';
  @StorageLink('topSafe') topSafe: number = 28;
  @StorageLink('connectionState') @Watch('connectionChanged') connectionState: string = '';
  @StorageLink('modelLabels') modelLabels: string[] = [];
  @StorageLink('activeHostId') @Watch('connectionChanged') activeHostId: string = '';
  @State bindingValid: boolean = false;
  @State snapshot: HostSettingsSnapshot = new HostSettingsSnapshot();
  @State presets: AgentPresetInfo[] = [];
  @State presetDocument: AgentPresetDocument = new AgentPresetDocument();
  @State plugins: NativePluginInfo[] = [];
  @State permission: DefaultPermissionInfo = new DefaultPermissionInfo();
  @State defaultModel: DefaultModelInfo = new DefaultModelInfo();
  @State loading: boolean = false;
  @State busy: string = '';
  @State errorText: string = '';
  @State noticeText: string = '';
  @State drafts: Map<string, string> = new Map();
  @State draftRevision: number = 0;
  @State modelIndex: number = -1;
  @State effortIndex: number = 0;
  @State presetExpanded: string = '';
  private alive: boolean = false;
  private viewEpoch: number = 0;
  private boundConnectionEpoch: number = -1;
  private boundHostId: string = '';
  private riskResolve?: (accepted: boolean) => void;

  aboutToAppear(): void {
    if (this.alive) return;
    this.alive = true; this.reload();
  }
  aboutToDisappear(): void {
    this.alive = false; this.invalidate();
  }
  private invalidate(): void {
    this.viewEpoch++; this.bindingValid = false; this.loading = false; this.busy = '';
    this.riskResolve?.(false); this.riskResolve = undefined;
    this.drafts.clear(); this.draftRevision++; this.presetExpanded = '';
    this.noticeText = '';
  }
  private connectionChanged(): void {
    if (this.alive && (!this.connected() || this.boundConnectionEpoch !== appStore.connectionEpoch || this.boundHostId !== this.activeHostId)) {
      this.invalidate(); this.errorText = '主机连接已变化，请刷新主机设置后再编辑。';
    }
  }
  private current(epoch: number): boolean { return this.alive && this.viewEpoch === epoch && this.ready(); }
  private title(): string {
    if (this.page === 'models') return '模型与思考深度';
    if (this.page === 'permission') return '权限';
    if (this.page === 'presets') return 'Agent 预设与个性化';
    if (this.page === 'engine') return '引擎参数';
    if (this.page === 'web-search') return '联网搜索';
    if (this.page === 'plugins') return '插件';
    if (this.page === 'media') return '图像与视频';
    if (this.page === 'privacy') return '主机日志上传';
    return '主机设置';
  }
  private textError(error: Error): string { return '操作结果未确认（' + errorCode(error) + '），请刷新核对主机实际值。'; }
  private connected(): boolean { return this.connectionState === 'ready'; }
  private ready(): boolean { return this.bindingValid && this.connected() && this.boundConnectionEpoch === appStore.connectionEpoch && this.boundHostId === this.activeHostId; }
  private namespace(name: string): HostSettingsNamespace | undefined {
    return this.snapshot.namespaces.find((row: HostSettingsNamespace): boolean => row.ns === name);
  }
  private visibleNamespaces(): HostSettingsNamespace[] {
    const core: string[] = ['agent-default-model', 'agent-preset-registry', 'permission', 'subagent', 'agent-loop', 'bash-sandbox', 'pwsh-sandbox', 'web', 'web-search-deepseek', 'web-deepseek-api', 'session-log-deepseek'];
    if (this.page === 'engine') return this.snapshot.namespaces.filter((row: HostSettingsNamespace): boolean => ['subagent', 'agent-loop', 'bash-sandbox', 'pwsh-sandbox'].indexOf(row.ns) >= 0);
    if (this.page === 'web-search') return this.snapshot.namespaces.filter((row: HostSettingsNamespace): boolean => ['web', 'web-search-deepseek', 'web-deepseek-api'].indexOf(row.ns) >= 0);
    if (this.page === 'media') return this.snapshot.namespaces.filter((row: HostSettingsNamespace): boolean => /(^|[-_])(media|image|video)/i.test(row.ns));
    if (this.page === 'privacy') return this.snapshot.namespaces.filter((row: HostSettingsNamespace): boolean => row.ns === 'session-log-deepseek');
    if (this.page === 'plugins') return this.snapshot.namespaces.filter((row: HostSettingsNamespace): boolean => core.indexOf(row.ns) < 0 && row.fields.length > 0);
    return [];
  }
  private namespaceTitle(ns: string): string {
    const names: Map<string, string> = new Map([['subagent', '子代理'], ['agent-loop', 'Agent 循环'], ['bash-sandbox', '命令执行'], ['pwsh-sandbox', '命令执行'], ['web', '搜索与抓取方式'], ['web-search-deepseek', 'DeepSeek 联网搜索'], ['web-deepseek-api', 'Search / Fetch API'], ['session-log-deepseek', '会话日志上传']]);
    return names.get(ns) || ns;
  }
  private async load(): Promise<void> {
    if (this.loading || !this.ready()) return;
    const epoch = this.viewEpoch; this.loading = true; this.errorText = '';
    try {
      if (this.page === 'presets') {
        const presets = await appStore.hostPresets();
        if (!this.current(epoch)) return;
        const snapshot = await appStore.hostDescribe();
        if (!this.current(epoch)) return;
        this.presets = presets; this.snapshot = snapshot;
      }
      else if (this.page === 'permission') {
        const permission = await appStore.hostDefaultPermission();
        if (!this.current(epoch)) return;
        this.permission = permission;
      }
      else if (this.page === 'models') {
        const defaultModel = await appStore.hostDefaultModel();
        if (!this.current(epoch)) return;
        this.defaultModel = defaultModel;
        this.modelIndex = appStore.hostModels.findIndex((row: ModelChoice): boolean => row.provider === this.defaultModel.provider && row.id === this.defaultModel.model);
        const model = appStore.hostModels[this.modelIndex];
        this.effortIndex = model ? model.effortIds.indexOf(this.defaultModel.reasoningEffort) : -1;
      } else {
        if (this.page === 'plugins') {
          const plugins = await appStore.hostPlugins();
          if (!this.current(epoch)) return;
          this.plugins = plugins;
        }
        const snapshot = await appStore.hostDescribe();
        if (!this.current(epoch)) return;
        this.snapshot = snapshot;
      }
      if (!this.current(epoch)) return;
    } catch (error) { if (this.current(epoch)) this.errorText = this.textError(error as Error); }
    finally { if (this.current(epoch)) this.loading = false; }
  }
  private async reload(): Promise<void> {
    if (!this.alive || !this.connected()) return;
    this.invalidate(); this.boundConnectionEpoch = appStore.connectionEpoch; this.boundHostId = this.activeHostId; this.bindingValid = true;
    this.snapshot = new HostSettingsSnapshot(); this.presets = []; this.plugins = [];
    this.permission = new DefaultPermissionInfo(); this.defaultModel = new DefaultModelInfo();
    this.presetDocument = new AgentPresetDocument(); this.modelIndex = -1; this.effortIndex = -1;
    await this.load();
  }
  private draft(ns: string, field: HostSettingField, _revision: number): string {
    const key = ns + ':' + field.path.join('.');
    const existing = this.drafts.get(key);
    if (existing !== undefined) return existing;
    try { const value: ESObject = JSON.parse(field.valueJson); return typeof value === 'string' || typeof value === 'number' ? String(value) : ''; }
    catch (_) { return ''; }
  }
  private setDraft(ns: string, field: HostSettingField, value: string): void {
    const current = this.namespace(ns);
    if (!this.ready() || !current || current.fields.indexOf(field) < 0) return;
    this.drafts.set(ns + ':' + field.path.join('.'), value); this.draftRevision++;
  }
  private async save(ns: HostSettingsNamespace, field: HostSettingField, raw?: string): Promise<void> {
    if (!this.ready() || this.loading || this.namespace(ns.ns) !== ns || ns.fields.indexOf(field) < 0 || this.busy || !ns.writable || field.disabled || field.secret || field.kind === 'readonly') return;
    const epoch = this.viewEpoch; this.busy = ns.ns + ':' + field.path.join('.'); this.errorText = ''; this.noticeText = '';
    try {
      let value: string = raw ?? this.draft(ns.ns, field, this.draftRevision);
      if (field.kind === 'number') {
        const numeric = Number(value);
        if (!value.trim() || !Number.isFinite(numeric) || (field.min !== undefined && numeric < field.min) || (field.max !== undefined && numeric > field.max)) throw new Error('INVALID_NUMBER');
        value = `${numeric}`;
      } else if (field.kind === 'boolean') value = value === 'true' ? 'true' : 'false';
      else if (field.kind === 'enum') {
        // choices contains display strings; the DTO has lost non-string const types.
        // Do not guess numeric/boolean JSON from a display label.
        if (typeof JSON.parse(field.valueJson) !== 'string' || value === 'undefined') throw new Error('ENUM_TYPE_UNAVAILABLE');
        let parsed: ESObject = value;
        try { parsed = JSON.parse(value); } catch (_) {}
        if (typeof parsed !== 'string') throw new Error('ENUM_TYPE_UNAVAILABLE');
        value = JSON.stringify(value);
      } else value = JSON.stringify(value);
      const op = new HostSettingsOp(); op.op = 'set'; op.path = field.path; op.valueJson = value;
      await appStore.hostMutate(ns.ns, [op], ns.revision);
      if (!this.current(epoch)) return;
      this.drafts.delete(ns.ns + ':' + field.path.join('.')); this.draftRevision++;
      this.noticeText = '主机已确认保存 · ' + field.title;
      await this.load();
    } catch (error) { if (this.current(epoch)) this.errorText = this.textError(error as Error); }
    finally { if (this.current(epoch)) this.busy = ''; }
  }
  private async setEnum(ns: HostSettingsNamespace, field: HostSettingField, index: number): Promise<void> {
    if (index < 0 || index >= field.choices.length) return;
    await this.save(ns, field, field.choices[index]);
  }
  private fieldIndex(field: HostSettingField): number {
    let value = '';
    try { value = JSON.stringify(JSON.parse(field.valueJson)); } catch (_) {}
    const index = field.choices.findIndex((item: string): boolean => JSON.stringify(item) === value || item === field.valueJson.replace(/^"|"$/g, ''));
    return Math.max(0, index);
  }
  private fieldLabels(field: HostSettingField): string[] {
    return field.choices.map((item: string, index: number): string => field.choiceLabels[index] || item);
  }

  private webNamespace(): HostSettingsNamespace | undefined { return this.namespace('web'); }
  private webApi(): boolean {
    const web = this.webNamespace(); if (!web) return false;
    try { return valueAt(JSON.parse(web.valueJson), ['searchProvider']) === 'deepseek-search-api'; } catch (_) { return false; }
  }
  private webAvailable(): boolean { return this.webNamespace() !== undefined && this.namespace('web-deepseek-api') !== undefined; }
  private async setWebApi(api: boolean): Promise<void> {
    const web = this.webNamespace(); if (!this.ready() || this.loading || !web || this.busy || !web.writable) return;
    const epoch = this.viewEpoch; this.busy = 'web-mode'; this.errorText = '';
    try {
      const base: ESObject = JSON.parse(web.baseJson); const ops: HostSettingsOp[] = [];
      const search = api ? 'deepseek-search-api' : 'deepseek-official'; const fetch = api ? 'deepseek-fetch-api' : 'http';
      for (const item of [['searchProvider', search], ['fetchProvider', fetch]] as string[][]) {
        const op = new HostSettingsOp(); op.path = [item[0]];
        if (valueAt(base, op.path) === item[1]) op.op = 'unset'; else { op.op = 'set'; op.valueJson = JSON.stringify(item[1]); }
        ops.push(op);
      }
      await appStore.hostMutate('web', ops, web.revision);
      if (!this.current(epoch)) return;
      this.noticeText = '主机已确认搜索与抓取方式'; await this.load();
    } catch (error) { if (this.current(epoch)) this.errorText = this.textError(error as Error); }
    finally { if (this.current(epoch)) this.busy = ''; }
  }

  private async askRisk(id: string): Promise<boolean> {
    if (id !== 'danger-full-access' && id !== 'auto') return true;
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      this.riskResolve = resolve;
      const finish = (accepted: boolean): void => {
        if (this.riskResolve !== resolve) return;
        this.riskResolve = undefined; resolve(accepted);
      };
      this.getUIContext().showAlertDialog({
        title: '确认降低操作确认保护？',
        message: id === 'danger-full-access' ? '新对话将默认允许主机执行命令，不再逐次请求确认。仅在你信任该主机与工作区时启用。' : '自动审核模式会减少确认。请确认你理解主机可能执行修改操作。',
        primaryButton: { value: '取消', action: () => finish(false) },
        secondaryButton: { value: '理解风险，继续', action: () => finish(true) },
        cancel: () => finish(false)
      });
    });
  }
  private async choosePermission(id: string): Promise<void> {
    if (!this.ready() || this.loading || this.busy || !this.permission.writable || this.permission.revision < 0) return;
    const epoch = this.viewEpoch; const revision = this.permission.revision;
    this.busy = 'permission'; this.errorText = '';
    try {
      if (!await this.askRisk(id) || !this.current(epoch)) return;
      await appStore.hostSetDefaultPermission(id, revision);
      if (this.current(epoch)) { this.noticeText = '主机已确认新对话默认权限'; await this.load(); }
    } catch (error) { if (this.current(epoch)) this.errorText = this.textError(error as Error); }
    finally { if (this.current(epoch)) this.busy = ''; }
  }
  private model(): ModelChoice | undefined { return appStore.hostModels[this.modelIndex]; }
  private async saveModel(): Promise<void> {
    const model = this.model();
    if (!this.ready() || this.loading || !model || this.busy || this.defaultModel.revision < 0 || !this.defaultModel.writable) return;
    const epoch = this.viewEpoch; this.busy = 'default-model'; this.errorText = '';
    try {
      const effort = model.effortIds[this.effortIndex] || '';
      await appStore.hostSetDefaultModel(model.provider, model.id, effort,
        this.defaultModel.rememberLastSelectionSupported ? this.defaultModel.rememberLastSelection : undefined, this.defaultModel.revision);
      if (this.current(epoch)) { this.noticeText = '主机已确认新对话默认模型与思考深度'; await this.load(); }
    } catch (error) { if (this.current(epoch)) this.errorText = this.textError(error as Error); }
    finally { if (this.current(epoch)) this.busy = ''; }
  }
  private async saveRemember(value: boolean): Promise<void> {
    if (!this.ready() || this.loading || this.busy || !this.defaultModel.writable || !this.defaultModel.rememberLastSelectionSupported || this.defaultModel.revision < 0) return;
    const epoch = this.viewEpoch; this.busy = 'remember-model'; this.errorText = '';
    const op = new HostSettingsOp(); op.path = ['rememberLastSelection']; op.valueJson = `${value}`;
    try {
      await appStore.hostMutate('agent-default-model', [op], this.defaultModel.revision);
      if (this.current(epoch)) await this.load();
    } catch (error) { if (this.current(epoch)) this.errorText = this.textError(error as Error); }
    finally { if (this.current(epoch)) this.busy = ''; }
  }
  private async readPreset(id: string): Promise<void> {
    if (!this.ready() || this.loading || this.busy) return;
    if (this.presetExpanded === id) { this.presetExpanded = ''; return; }
    const epoch = this.viewEpoch; this.busy = 'preset-read:' + id; this.errorText = '';
    try {
      const document = await appStore.hostReadPreset(id);
      if (this.current(epoch)) { this.presetDocument = document; this.presetExpanded = id; }
    }
    catch (error) { if (this.current(epoch)) this.errorText = this.textError(error as Error); }
    finally { if (this.current(epoch)) this.busy = ''; }
  }
  private async selectPreset(id: string): Promise<void> {
    if (!this.ready() || this.loading || this.busy) return;
    const epoch = this.viewEpoch; this.busy = 'preset-select:' + id; this.errorText = '';
    try {
      const registry = this.namespace('agent-preset-registry');
      if (!registry || !Number.isSafeInteger(registry.revision) || registry.revision < 0) throw new Error('PRESET_REVISION_UNAVAILABLE');
      if (!registry.writable) throw new Error('PRESET_READONLY');
      await appStore.hostSelectPreset(id, registry.revision);
      if (this.current(epoch)) { this.noticeText = '主机已确认新对话默认预设'; await this.load(); }
    } catch (error) { if (this.current(epoch)) this.errorText = this.textError(error as Error); }
    finally { if (this.current(epoch)) this.busy = ''; }
  }
  private pluginOperation(json: string): string {
    const result: ESObject = JSON.parse(json);
    if (result.application !== 'applied' && result.application !== 'restart-required') throw new Error('PLUGIN_NOT_APPLIED');
    return result.application === 'restart-required' ? '已应用 · 主机要求重启后完成切换' : '主机已确认插件状态';
  }
  private async togglePlugin(plugin: NativePluginInfo, enabled: boolean): Promise<void> {
    if (!this.ready() || this.loading || this.busy) return;
    const epoch = this.viewEpoch; this.busy = 'plugin:' + plugin.name; this.errorText = '';
    try {
      const message = this.pluginOperation(await appStore.hostSetBundleEnabled(plugin.name, enabled));
      if (this.current(epoch)) { this.noticeText = message; await this.load(); }
    } catch (error) { if (this.current(epoch)) this.errorText = this.textError(error as Error); }
    finally { if (this.current(epoch)) this.busy = ''; }
  }

  @Builder sectionTitle(title: string) {
    Text(title).fontSize(18).fontWeight(FontWeight.Medium).width('100%').padding({ bottom: GAP_NORMAL })
  }
  @Builder fieldRow(ns: HostSettingsNamespace, field: HostSettingField) {
    Column({ space: GAP_NORMAL }) {
      Row({ space: GAP_NORMAL }) {
        Column({ space: 3 }) {
          Text(field.title).fontSize(15).fontColor($r('app.color.text_primary'))
          if (field.description) Text(field.description).fontSize(11).fontColor($r('app.color.text_tertiary')).lineHeight(16)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (field.secret) Text(field.configured ? '已配置' : '未配置').fontSize(12).fontColor($r('app.color.text_secondary'))
        else if (field.kind === 'boolean') {
          Toggle({ type: ToggleType.Switch, isOn: field.valueJson === 'true' }).selectedColor($r('app.color.accent'))
            .enabled(this.ready() && !this.loading && !this.busy && ns.writable && !field.disabled)
            .onChange((value: boolean) => this.save(ns, field, `${value}`))
        } else if (field.kind === 'enum') {
          Select(choices(this.fieldLabels(field))).selected(this.fieldIndex(field)).value(this.fieldLabels(field)[this.fieldIndex(field)])
            .systemMaterial(barMaterial()).menuSystemMaterial(floatingMaterial(3)).backgroundColor(Color.Transparent)
            .constraintSize({ maxWidth: '55%' }).enabled(this.ready() && !this.loading && !this.busy && ns.writable && !field.disabled)
            .onSelect((index: number) => this.setEnum(ns, field, index))
        } else if (field.kind === 'readonly') {
          Text(field.valueJson.length > 160 ? field.valueJson.substring(0, 160) + '…' : field.valueJson)
            .fontSize(11).fontColor($r('app.color.text_secondary')).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '55%' })
        }
      }.width('100%')
      if (!field.secret && (field.kind === 'string' || field.kind === 'number')) {
        Row({ space: GAP_NORMAL }) {
          TextInput({ text: this.draft(ns.ns, field, this.draftRevision), placeholder: field.kind === 'number' ? '输入数值' : '输入配置值' })
            .layoutWeight(1).height(40).type(field.kind === 'number' ? InputType.Number : InputType.Normal)
            .enabled(this.ready() && !this.loading && !this.busy && ns.writable && !field.disabled)
            .onChange((value: string) => this.setDraft(ns.ns, field, value))
            .onSubmit(() => this.save(ns, field))
          Button('保存').enabled(this.ready() && !this.loading && !this.busy && ns.writable && !field.disabled).onClick(() => this.save(ns, field))
        }.width('100%')
      }
      if (field.disabled && !field.secret) Text('该字段被主机或部署配置锁定，只读').fontSize(11).fontColor($r('app.color.text_tertiary'))
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: GAP_NORMAL, bottom: GAP_NORMAL })
  }
  @Builder namespaceCard(ns: HostSettingsNamespace) {
    Column({ space: GAP_NORMAL }) {
      this.sectionTitle(this.namespaceTitle(ns.ns))
      if (this.page === 'web-search' && ns.ns === 'web' && this.webAvailable()) {
        Row({ space: GAP_NORMAL }) {
          Column({ space: 3 }) {
            Text('Search / Fetch API').fontSize(15)
            Text('搜索与抓取方式在同一次主机事务中修改').fontSize(11).fontColor($r('app.color.text_tertiary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.webApi() }).selectedColor($r('app.color.accent'))
            .enabled(this.ready() && !this.loading && !this.busy && ns.writable).onChange((value: boolean) => this.setWebApi(value))
        }.width('100%')
      }
      ForEach(ns.fields.filter((field: HostSettingField): boolean => !(this.page === 'web-search' && ns.ns === 'web' && (field.path[0] === 'searchProvider' || field.path[0] === 'fetchProvider'))), (field: HostSettingField) => {
        this.fieldRow(ns, field)
      }, (field: HostSettingField) => ns.ns + ':' + field.path.join('.'))
      if (!ns.writable) Text('当前主机配置为只读').fontSize(11).fontColor($r('app.color.text_tertiary'))
    }.width('100%').alignItems(HorizontalAlign.Start).padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
  }
  @Builder modelsContent() {
    Column({ space: GAP_NORMAL }) {
      this.sectionTitle('新对话默认模型')
      if (this.defaultModel.revision < 0) {
        Text('当前主机未提供 agent-default-model 配置；不会把当前会话选择冒充为默认值。').fontSize(13).fontColor($r('app.color.text_secondary'))
      } else if (appStore.hostModels.length) {
        Select(choices(appStore.hostModels.map((row: ModelChoice): string => row.name || row.id)))
          .selected(Math.max(0, this.modelIndex)).value(this.model()?.name || this.defaultModel.model || '请选择默认模型').systemMaterial(barMaterial()).menuSystemMaterial(floatingMaterial(3))
          .width('100%').enabled(this.ready() && !this.loading && !this.busy && this.defaultModel.writable).onSelect((index: number) => { this.modelIndex = index; this.effortIndex = -1; })
        if (this.model() && this.model()!.effortIds.length > 0) {
          Select(choices(['跟随模型默认'].concat(this.model()!.effortNames))).selected(this.effortIndex + 1)
            .value(this.effortIndex < 0 ? '跟随模型默认' : this.model()!.effortNames[this.effortIndex] || '')
            .systemMaterial(barMaterial()).menuSystemMaterial(floatingMaterial(3)).width('100%').enabled(this.ready() && !this.loading && !this.busy)
            .onSelect((index: number) => { this.effortIndex = index - 1; })
        }
        if (this.defaultModel.rememberLastSelectionSupported) {
          Row({ space: GAP_NORMAL }) {
            Text('记住最近选择').fontSize(14).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.defaultModel.rememberLastSelection }).selectedColor($r('app.color.accent'))
              .enabled(this.ready() && !this.loading && !this.busy && this.defaultModel.writable).onChange((value: boolean) => this.saveRemember(value))
          }.width('100%')
        }
        Button(this.busy === 'default-model' ? '正在保存…' : '保存新对话默认模型').width('100%')
          .backgroundColor($r('app.color.accent')).enabled(this.ready() && !this.loading && !this.busy && this.defaultModel.writable && this.model() !== undefined).onClick(() => this.saveModel())
      } else Text('无法读取主机模型目录').fontSize(13)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
    Column({ space: GAP_NORMAL }) {
      this.sectionTitle('主机模型目录')
      ForEach(this.modelLabels, (label: string) => { Text(label).fontSize(14).padding({ top: 5, bottom: 5 }) }, (label: string) => label)
      if (!this.modelLabels.length) Text('主机未提供模型目录').fontSize(13).fontColor($r('app.color.text_secondary'))
    }.width('100%').alignItems(HorizontalAlign.Start).padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
  }
  @Builder permissionContent() {
    Column({ space: GAP_NORMAL }) {
      this.sectionTitle('新对话默认权限')
      Text('默认权限只影响新会话；不会覆盖已有会话。').fontSize(12).fontColor($r('app.color.text_secondary'))
      ForEach(this.permission.options.filter((row: DefaultPermissionOption): boolean => row.defaultAllowed), (row: DefaultPermissionOption) => {
        Button({ type: ButtonType.Normal }) {
          Row({ space: GAP_NORMAL }) {
            Column({ space: 3 }) {
              Text(row.name || row.id).fontSize(15).fontColor($r('app.color.text_primary'))
              if (row.description) Text(row.description).fontSize(11).fontColor($r('app.color.text_tertiary'))
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            Text(this.permission.current === row.id ? '当前默认' : '').fontSize(12).fontColor($r('app.color.accent'))
          }.width('100%').padding(10)
        }.width('100%').padding(0).backgroundColor(Color.Transparent).enabled(this.ready() && !this.loading && !this.busy && this.permission.writable)
          .onClick(() => this.choosePermission(row.id))
      }, (row: DefaultPermissionOption) => row.id)
      if (!this.permission.writable) Text('当前主机未开放默认权限写入').fontSize(12).fontColor($r('app.color.text_secondary'))
    }.width('100%').alignItems(HorizontalAlign.Start).padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
  }
  @Builder presetsContent() {
    Column({ space: GAP_NORMAL }) {
      this.sectionTitle('Agent 预设')
      ForEach(this.presets, (preset: AgentPresetInfo) => {
        Column({ space: GAP_NORMAL }) {
          Text(preset.name || preset.id).fontSize(16).fontWeight(FontWeight.Medium)
          if (preset.description) Text(preset.description).fontSize(12).fontColor($r('app.color.text_secondary'))
          if (preset.broken) Text('加载失败：' + preset.broken).fontSize(12).fontColor($r('app.color.danger'))
          if (preset.isDefault) Text('新对话默认').fontSize(12).fontColor($r('app.color.accent'))
          Row({ space: GAP_NORMAL }) {
            Button(this.presetExpanded === preset.id ? '收起 YAML' : '查看 YAML').layoutWeight(1).enabled(this.ready() && !this.loading && !this.busy).onClick(() => this.readPreset(preset.id))
            Button('设为默认').layoutWeight(1).enabled(this.ready() && !this.loading && !this.busy && !preset.isDefault && !preset.broken).onClick(() => this.selectPreset(preset.id))
          }.width('100%')
          if (this.presetExpanded === preset.id) {
            Scroll() { Text(this.presetDocument.content).fontSize(12).fontFamily('monospace').width('100%') }.height(280)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(GAP_CARD).backgroundColor($r('app.color.surface_alt')).borderRadius(RADIUS_CARD)
      }, (preset: AgentPresetInfo) => preset.id)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
    Column({ space: GAP_NORMAL }) {
      this.sectionTitle('个人偏好与可视化回复')
      Text('Flutter 版本的个人偏好写入本机 Guest FS 的 AGENTS.md，Remote 没有对应的文件编辑接口。本页不提供只存手机、却不影响模型的伪编辑器。').fontSize(13).fontColor($r('app.color.text_secondary')).lineHeight(20)
      Text('预设新建、复制和删除需要完整 preset editor / bundle 管理，本页仅提供真实列表、YAML 与设默认。').fontSize(12).fontColor($r('app.color.text_tertiary')).lineHeight(18)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
  }
  @Builder pluginsContent() {
    Column({ space: GAP_NORMAL }) {
      this.sectionTitle('插件清单')
      ForEach(this.plugins, (plugin: NativePluginInfo) => {
        Row({ space: GAP_NORMAL }) {
          Column({ space: 3 }) {
            Text(plugin.name).fontSize(15)
            if (plugin.description) Text(plugin.description).fontSize(11).fontColor($r('app.color.text_tertiary'))
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: plugin.enabled }).selectedColor($r('app.color.accent'))
            .enabled(this.ready() && !this.loading && !this.busy).onChange((value: boolean) => this.togglePlugin(plugin, value))
        }.width('100%').padding({ top: GAP_NORMAL, bottom: GAP_NORMAL })
      }, (plugin: NativePluginInfo) => plugin.name)
      if (!this.plugins.length) Text('主机未返回插件包，或目录暂不可用').fontSize(13).fontColor($r('app.color.text_secondary'))
      Text('Remote 仅提供清单与启停；安装、移除和构建脚本批准不在此入口执行。').fontSize(11).fontColor($r('app.color.text_tertiary'))
    }.width('100%').alignItems(HorizontalAlign.Start).padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
  }
  @Builder bodyContent() {
    if (this.page === 'models') this.modelsContent()
    else if (this.page === 'permission') this.permissionContent()
    else if (this.page === 'presets') this.presetsContent()
    else {
      if (this.page === 'plugins') this.pluginsContent()
      ForEach(this.visibleNamespaces(), (ns: HostSettingsNamespace) => { this.namespaceCard(ns) }, (ns: HostSettingsNamespace) => ns.ns)
      if (!this.visibleNamespaces().length && this.page !== 'plugins') {
        Column({ space: GAP_NORMAL }) {
          Text('当前主机没有此分类的可配置项').fontSize(15)
          Text('这里只显示主机 settings/describe 实际提供的即时配置，不虚构插件或能力。').fontSize(12).fontColor($r('app.color.text_secondary'))
        }.width('100%').alignItems(HorizontalAlign.Start).padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
      }
    }
  }

  @Builder detailTitle() { DetailTitle({ stack: this.stack, title: this.title() }) }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: GAP_CARD }) {
          Row().height(this.topSafe + 64)
          if (!this.ready()) Text(this.connected() ? '主机连接已变化，请刷新后再编辑' : '请先连接主机，再读取或修改设置').fontSize(15).padding(GAP_LARGE).width('100%')
          else if (this.loading) Row({ space: GAP_NORMAL }) { LoadingProgress().width(22).height(22); Text('正在读取主机实际设置') }.padding(GAP_LARGE)
          else this.bodyContent()
          if (this.errorText) Text(this.errorText).fontSize(12).fontColor($r('app.color.danger')).width('100%')
          if (this.noticeText) Text(this.noticeText).fontSize(12).fontColor($r('app.color.accent')).width('100%')
          Button('刷新主机设置').width('100%').enabled(this.connected() && !this.loading && !this.busy).onClick(() => this.reload())
        }.width('100%').padding(MARGIN_EDGE).alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%').scrollBar(BarState.Off)
    }.title({ builder: this.detailTitle, height: this.topSafe + 64 }, titleBarOptions()).hideBackButton(true)
      .backgroundColor($r('app.color.bg'))
  }
}
