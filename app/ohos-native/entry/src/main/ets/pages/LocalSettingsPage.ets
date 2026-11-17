import common from '@ohos.app.ability.common';
import { DetailTitle } from '../components/DetailTitle';
import {
  nativeLocalSettings, nativeSettingsErrorCode
} from '../state/NativeLocalSettings';
import {
  GAP_CARD, GAP_LARGE, GAP_NORMAL, MARGIN_EDGE, RADIUS_CARD,
  barMaterial, floatingMaterial, titleBarOptions
} from '../common/Style';

const CACHE_VALUES: string[] = ['0', '1', '3'];
const CACHE_LABELS: string[] = ['0 · 不预缓存', '1 · 较少', '3 · 默认'];
const GITHUB_URL: string = 'https://github.com/ccch1mneyyy/dsh-Go';
const SITE_URL: string = 'https://go.dshtui.com/';
const RELEASES_URL: string = 'https://github.com/ccch1mneyyy/dsh-Go/releases';
const NOTICES_URL: string = 'https://github.com/ccch1mneyyy/dsh-Go/blob/main/THIRD_PARTY_NOTICES.md';
const LICENSE_URL: string = 'https://github.com/ccch1mneyyy/dsh-Go/blob/main/LICENSE';
const REMOTE_LICENSE_URL: string = 'https://github.com/liguobao/ds-harness-remote';
const EXTERNAL_LINKS: string[] = [GITHUB_URL, SITE_URL, RELEASES_URL, NOTICES_URL, LICENSE_URL, REMOTE_LICENSE_URL];

function selectOptions(items: string[]): SelectOption[] {
  return items.map((item: string): SelectOption => ({ value: item }));
}

function readableSettingsError(error: Error): string {
  const code = nativeSettingsErrorCode(error);
  if (code === 'NATIVE_SETTINGS_INIT_FAILED') return '本地设置读取失败，当前显示默认值；保存前请重试（NATIVE_SETTINGS_INIT_FAILED）';
  if (code === 'NATIVE_SETTINGS_NOT_READY') return '本地设置尚未就绪，此次更改未保存（NATIVE_SETTINGS_NOT_READY）';
  if (code === 'NATIVE_SETTINGS_NO_CONTEXT') return '当前页面无法访问系统能力，请重新打开（NATIVE_SETTINGS_NO_CONTEXT）';
  if (code === 'INVALID_PREFERENCE') return '设置项或取值无效，未保存（INVALID_PREFERENCE）';
  if (code === 'PREFERENCE_SAVE_FAILED') return '设置保存失败，未应用此次更改（PREFERENCE_SAVE_FAILED）';
  if (code === 'NOTIFICATION_STATUS_FAILED') return '无法读取系统通知状态，请稍后重试（NOTIFICATION_STATUS_FAILED）';
  if (code === 'NOTIFICATION_REQUEST_FAILED') return '系统通知授权未完成，请重试或打开系统设置（NOTIFICATION_REQUEST_FAILED）';
  if (code === 'NOTIFICATION_SETTINGS_FAILED') return '无法打开系统通知设置（NOTIFICATION_SETTINGS_FAILED）';
  if (code === 'NOTIFICATION_PUBLISH_FAILED') return '系统未接受通知发布，请检查设置后重试（NOTIFICATION_PUBLISH_FAILED）';
  if (code === 'INVALID_NOTIFICATION_KIND') return '提醒类型无效，未发布（INVALID_NOTIFICATION_KIND）';
  if (code === 'CLIPBOARD_WRITE_FAILED') return '诊断复制失败，未报告成功（CLIPBOARD_WRITE_FAILED）';
  if (code === 'LINK_OPEN_FAILED') return '无法打开外部链接（LINK_OPEN_FAILED）';
  return '操作未完成，请重试（' + code + '）';
}

@Component
export struct LocalSettingsPage {
  stack: NavPathStack = new NavPathStack();
  page: string = 'about';
  @StorageLink('bottomSafe') bottomSafe: number = 0;
  @StorageLink('topSafe') topSafe: number = 28;
  @StorageLink('nativeVersionName') versionName: string = 'unavailable';
  @StorageLink('nativeBuild') versionBuild: string = 'unavailable';
  @StorageLink('nativeNotificationSystemKnown') systemStatusKnown: boolean = false;
  @StorageLink('nativeNotificationSystemEnabled') systemEnabled: boolean = false;
  @StorageLink('nativeNotificationFailure') notificationFailure: string = '';
  private publishFailureMessage(): string {
    const code = nativeLocalSettings.lastPublishFailure;
    if (code === 'NOT_READY') return '本地设置尚未初始化，未发布测试提醒';
    if (code === 'PREFERENCE_DISABLED') return '应用内通知开关已关闭，未发布测试提醒';
    if (code === 'SYSTEM_DISABLED') return '系统通知或服务通知通道未允许，未发布测试提醒';
    if (code === 'STATUS_FAILED') return '系统通知状态读取失败，未发布测试提醒';
    return '测试通知未发布，请检查应用与系统通知开关';
  }
  @StorageLink('connectionState') connectionState: string = 'unknown';
  @StorageLink('activeHostName') activeHostName: string = '';
  @State notifyEnabled: boolean = true;
  @State notifyDone: boolean = true;
  @State notifyFailed: boolean = true;
  @State notifyApproval: boolean = true;
  @State notifyQuestion: boolean = true;
  @State blurEnabled: boolean = true;
  @State animationsEnabled: boolean = true;
  @State cacheIndex: number = 2;
  @State diagnosticText: string = '';
  @State errorText: string = '';
  @State noticeText: string = '';
  @State busy: string = '';
  private alive: boolean = false;
  private viewEpoch: number = 0;

  aboutToAppear(): void { this.activate(); }
  aboutToDisappear(): void { this.deactivate(); }

  private current(epoch: number): boolean { return this.alive && this.viewEpoch === epoch; }
  private activate(): void {
    if (this.alive) return;
    this.alive = true;
    const epoch = ++this.viewEpoch;
    this.errorText = '';
    this.noticeText = '';
    this.restorePreferences();
    this.boot(epoch);
  }
  private deactivate(): void { this.alive = false; this.viewEpoch++; this.busy = ''; }

  private async boot(epoch: number): Promise<void> {
    try {
      await nativeLocalSettings.initialize(getContext(this) as common.UIAbilityContext);
      if (!this.current(epoch)) return;
      this.restorePreferences();
      if (this.page === 'diagnostics') await this.refreshDiagnostics();
    } catch (error) {
      if (this.current(epoch)) this.errorText = readableSettingsError(error as Error);
    }
    if (this.current(epoch) && this.page === 'notifications') await this.refreshSystemNotifications();
  }

  private restorePreferences(): void {
    this.notifyEnabled = nativeLocalSettings.getPreference('enabled', 'true') !== 'false';
    this.notifyDone = nativeLocalSettings.getPreference('done', 'true') !== 'false';
    this.notifyFailed = nativeLocalSettings.getPreference('failed', 'true') !== 'false';
    this.notifyApproval = nativeLocalSettings.getPreference('approval', 'true') !== 'false';
    this.notifyQuestion = nativeLocalSettings.getPreference('question', 'true') !== 'false';
    this.blurEnabled = nativeLocalSettings.getPreference('blurEnabled', 'true') !== 'false';
    this.animationsEnabled = nativeLocalSettings.getPreference('animationsEnabled', 'true') !== 'false';
    const cache = nativeLocalSettings.getPreference('listCacheCount', '3');
    const index = CACHE_VALUES.indexOf(cache);
    this.cacheIndex = index >= 0 ? index : 2;
  }

  private notificationValue(key: string): boolean {
    if (key === 'enabled') return this.notifyEnabled;
    if (key === 'done') return this.notifyDone;
    if (key === 'failed') return this.notifyFailed;
    if (key === 'approval') return this.notifyApproval;
    return this.notifyQuestion;
  }

  private toggleValue(key: string): boolean {
    if (key === 'blurEnabled') return this.blurEnabled;
    if (key === 'animationsEnabled') return this.animationsEnabled;
    return this.notificationValue(key);
  }

  private async savePreference(key: string, value: string): Promise<void> {
    if (this.busy) return;
    const epoch = this.viewEpoch;
    this.busy = 'preference:' + key;
    this.errorText = '';
    this.noticeText = '';
    try {
      await nativeLocalSettings.setPreference(key, value);
      if (this.current(epoch)) {
        this.restorePreferences();
        this.noticeText = '设置已保存';
      }
    } catch (error) {
      if (this.current(epoch)) {
        this.restorePreferences();
        this.errorText = readableSettingsError(error as Error);
      }
    } finally {
      if (this.current(epoch)) this.busy = '';
    }
  }

  private async refreshSystemNotifications(): Promise<void> {
    if (!this.alive) return;
    const epoch = this.viewEpoch;
    try {
      await nativeLocalSettings.refreshNotifications();
    } catch (error) {
      if (this.current(epoch)) this.errorText = readableSettingsError(error as Error);
    }
  }

  private async requestNotifications(): Promise<void> {
    if (this.busy) return;
    const epoch = this.viewEpoch;
    this.busy = 'request-notifications';
    this.errorText = '';
    this.noticeText = '';
    try {
      const allowed = await nativeLocalSettings.requestNotifications();
      if (this.current(epoch)) {
        this.noticeText = allowed ? '系统通知已允许' : '未获得系统通知权限；可打开系统设置修改';
      }
    } catch (error) {
      if (this.current(epoch)) this.errorText = readableSettingsError(error as Error);
    } finally {
      if (this.current(epoch)) this.busy = '';
    }
  }

  private async openNotificationSettings(): Promise<void> {
    if (this.busy) return;
    const epoch = this.viewEpoch;
    this.busy = 'notification-settings';
    this.errorText = '';
    this.noticeText = '';
    try {
      await nativeLocalSettings.openNotificationSettings();
      if (this.current(epoch)) this.noticeText = '已调用系统通知设置，并重新读取实际状态';
    } catch (error) {
      if (this.current(epoch)) this.errorText = readableSettingsError(error as Error);
    } finally {
      if (this.current(epoch)) this.busy = '';
    }
  }

  private async publishTest(): Promise<void> {
    if (this.busy) return;
    const epoch = this.viewEpoch;
    this.busy = 'test-notification';
    this.errorText = '';
    this.noticeText = '';
    try {
      const published = await nativeLocalSettings.publish('done', 'DSH Go', '这是一条应用运行期间发布的测试提醒');
      if (this.current(epoch)) {
        if (published) this.noticeText = '系统已接受测试通知发布';
        else this.errorText = this.publishFailureMessage();
      }
    } catch (error) {
      if (this.current(epoch)) this.errorText = readableSettingsError(error as Error);
    } finally {
      if (this.current(epoch)) this.busy = '';
    }
  }

  private async refreshDiagnostics(): Promise<void> {
    if (!this.alive) return;
    const epoch = this.viewEpoch;
    this.errorText = '';
    try {
      const value = await nativeLocalSettings.diagnosticsJson();
      if (this.current(epoch)) this.diagnosticText = value;
    } catch (error) {
      if (this.current(epoch)) this.errorText = readableSettingsError(error as Error);
    }
  }

  private async copyDiagnostics(forSharing: boolean): Promise<void> {
    if (this.busy) return;
    const epoch = this.viewEpoch;
    this.busy = forSharing ? 'share-diagnostics' : 'copy-diagnostics';
    this.errorText = '';
    this.noticeText = '';
    try {
      if (forSharing) await nativeLocalSettings.shareDiagnostics();
      else await nativeLocalSettings.copyDiagnostics();
      if (this.current(epoch)) {
        this.noticeText = forSharing ?
          '已复制诊断；此原生端未调用系统分享面板，请手动粘贴分享' : '已复制安全诊断 JSON';
      }
    } catch (error) {
      if (this.current(epoch)) this.errorText = readableSettingsError(error as Error);
    } finally {
      if (this.current(epoch)) this.busy = '';
    }
  }

  private async openExternal(url: string): Promise<void> {
    if (this.busy || EXTERNAL_LINKS.indexOf(url) < 0) return;
    const epoch = this.viewEpoch;
    this.busy = 'external-link';
    this.errorText = '';
    this.noticeText = '';
    try {
      await (getContext(this) as common.UIAbilityContext).openLink(url);
      if (this.current(epoch)) this.noticeText = '已请求系统浏览器打开链接';
    } catch (_) {
      if (this.current(epoch)) this.errorText = readableSettingsError(new Error('LINK_OPEN_FAILED'));
    } finally {
      if (this.current(epoch)) this.busy = '';
    }
  }

  private openPage(page: string): void { this.stack.pushPathByName('settings', page); }

  private pageTitle(): string {
    if (this.page === 'notifications') return '通知';
    if (this.page === 'performance') return '性能';
    if (this.page === 'privacy') return '隐私与分享';
    if (this.page === 'help') return '使用帮助';
    if (this.page === 'community') return '社区';
    if (this.page === 'diagnostics') return '诊断';
    if (this.page === 'licenses') return '开源许可';
    if (this.page === 'systemActions') return '系统操作';
    if (this.page === 'language') return '语言';
    return '关于';
  }

  private versionLabel(): string {
    if (this.versionName === 'unavailable') return '版本读取不可用';
    return this.versionName + ' (' + this.versionBuild + ')';
  }

  @Builder
  card(title: string, lines: string[]) {
    Column({ space: GAP_NORMAL }) {
      if (title) {
        Text(title).fontSize(18).fontWeight(FontWeight.Medium).width('100%')
      }
      ForEach(lines, (line: string) => {
        Text(line).fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').lineHeight(20)
      }, (line: string) => line)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(MARGIN_EDGE)
    .backgroundColor($r('app.color.surface'))
    .borderRadius(RADIUS_CARD)
  }

  @Builder
  notificationStatusCard() {
    Column({ space: GAP_NORMAL }) {
      Text('系统通知').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
      Text(this.systemStatusKnown ? (this.systemEnabled ? '系统当前允许本应用的服务通知。' : '系统通知或服务通知通道当前未允许。') : '尚未取得可靠的系统通知状态。')
        .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').lineHeight(20)
      Text('应用内开关与系统权限都允许时才会发布；请求权限只由下面的用户按钮触发。')
        .fontSize(13).fontColor($r('app.color.text_secondary')).width('100%').lineHeight(20)
    }.alignItems(HorizontalAlign.Start).width('100%').padding(MARGIN_EDGE)
      .backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
  }

  @Builder
  infoRow(label: string, value: string) {
    Row({ space: GAP_NORMAL }) {
      Text(label).fontSize(14).fontColor($r('app.color.text_secondary'))
      Blank()
      Text(value).fontSize(14).maxLines(4).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '65%' })
    }.width('100%').padding({ top: 6, bottom: 6 })
  }

  @Builder
  toggleRow(title: string, detail: string, key: string, enabled: boolean = true) {
    Row({ space: GAP_NORMAL }) {
      Column({ space: 3 }) {
        Text(title).fontSize(15).fontColor($r('app.color.text_primary'))
        if (detail) {
          Text(detail).fontSize(11).fontColor($r('app.color.text_tertiary')).lineHeight(16)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: this.toggleValue(key) })
        .systemMaterial(barMaterial())
        .selectedColor($r('app.color.accent'))
        .enabled(enabled && !this.busy)
        .onChange((next: boolean) => { this.savePreference(key, String(next)); })
    }.width('100%').padding({ top: 10, bottom: 10 })
  }

  @Builder
  notificationsContent() {
    this.notificationStatusCard()
    Column() {
      this.toggleRow('允许通知', '本应用内的通知总开关', 'enabled')
      Divider().color($r('app.color.divider'))
      this.toggleRow('一轮完成', '正常完成时提醒', 'done', this.notifyEnabled)
      Divider().color($r('app.color.divider'))
      this.toggleRow('出错或被停下', '失败或停止时提醒', 'failed', this.notifyEnabled)
      Divider().color($r('app.color.divider'))
      this.toggleRow('等你确认', '审批请求等待处理时提醒', 'approval', this.notifyEnabled)
      Divider().color($r('app.color.divider'))
      this.toggleRow('向你提问', '主机请求回答时提醒', 'question', this.notifyEnabled)
    }
    .width('100%').padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)

    Column({ space: GAP_NORMAL }) {
      Button(this.busy === 'request-notifications' ? '正在请求…' : '请求系统通知权限')
        .width('100%').backgroundColor($r('app.color.accent')).enabled(!this.busy)
        .onClick(() => { this.requestNotifications(); })
      Button('打开系统通知设置').width('100%').enabled(!this.busy)
        .onClick(() => { this.openNotificationSettings(); })
      Button('发布测试提醒').width('100%').enabled(!this.busy && this.notifyEnabled && this.notifyDone)
        .onClick(() => { this.publishTest(); })
    }.width('100%')
    this.card('运行边界', [
      '提醒只在应用进程运行且主机连接可用时发布；本原生端没有后台保活能力。',
      '系统挂起或结束应用后不保证收到提醒；测试发布成功只表示系统 API 接受发布，不证明用户已经看到。'
    ])
  }

  @Builder
  performanceContent() {
    Column() {
      this.toggleRow('渐进模糊', '关闭后，原生页面应跳过渐进模糊效果', 'blurEnabled')
      Divider().color($r('app.color.divider'))
      this.toggleRow('应用内动画', '关闭后，原生界面应减少自绘过渡动画', 'animationsEnabled')
      Divider().color($r('app.color.divider'))
      Row({ space: GAP_NORMAL }) {
        Column({ space: 3 }) {
          Text('列表预缓存').fontSize(15)
          Text('减少屏幕外列表项的预创建数量').fontSize(11).fontColor($r('app.color.text_tertiary'))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Select(selectOptions(CACHE_LABELS))
          .selected(this.cacheIndex).value(CACHE_LABELS[this.cacheIndex])
          .systemMaterial(barMaterial()).menuSystemMaterial(floatingMaterial(3))
          .backgroundColor(Color.Transparent).width(150).enabled(!this.busy)
          .onSelect((index: number) => {
            if (index >= 0 && index < CACHE_VALUES.length) this.savePreference('listCacheCount', CACHE_VALUES[index]);
          })
      }.width('100%').padding({ top: 10, bottom: 10 })
    }.width('100%').padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
    this.card('实际范围', [
      '这些选项只设置 blurEnabled、animationsEnabled 与 listCacheCount，由原生列表和材质渲染读取。',
      '不提供虚构的帧率解锁、后台运行或系统级性能模式；系统动画与省电策略仍由系统控制。'
    ])
  }

  @Builder
  privacyContent() {
    this.card('本地数据边界', [
      '通知与显示偏好保存在普通偏好中；Remote 登录与设备身份由系统安全凭据存储加密保护，不写入诊断。',
      '诊断生成过程不读取 Cookie、Token、API Key、DSH profile、消息或 host id，也不读取剪贴板内容。'
    ])
    this.card('分享前检查', [
      '安全诊断只含版本、连接摘要、主机显示名与无查询参数 origin，以及主题、字号、折叠和通知偏好。',
      '复制后仍建议人工检查再外发。清除保存的 Remote 授权，请到远程连接页退出登录；这里不提供主机配置分享。'
    ])
    Button('主机日志上传设置（按主机实际提供）').width('100%')
      .onClick(() => this.stack.pushPathByName('host-settings', 'privacy'))
    Button('查看安全诊断与复制入口').width('100%').backgroundColor($r('app.color.accent'))
      .onClick(() => this.openPage('diagnostics'))
  }

  @Builder
  helpContent() {
    this.card('主要方式：DSH Remote（推荐）', [
      '1. 在电脑或服务器的 DSH 中安装并启用远程插件，登录你的远程账号。',
      '2. 在本应用主机页打开“远程连接”，用同一账号授权，选择在线主机。',
      '3. 首次连接核对并保存主机指纹；重启后恢复登录并自动连接上次主机。主机身份变化时仍会阻止连接。',
      '提醒与操作仍要求应用进程正在运行、远程连接在线。'
    ])
    this.card('额外方式：直接连接 dsh web', [
      '在可达的电脑或服务器运行 dsh web，复制它本次输出的完整登录地址，再到主机页使用直接连接。',
      '完整登录地址含临时凭据，不要发到社区或诊断中；主机保存与诊断只使用不含查询参数的地址。',
      '直连需要网络可达与有效登录地址；它不是 DSH Remote 账号连接的替代品。'
    ])
    Button('查看项目与网站').width('100%').onClick(() => this.openPage('community'))
  }

  @Builder
  communityContent() {
    this.card('DSH Go 社区', ['源码、问题与项目说明以 GitHub 仓库为准；展示网站提供产品信息。外部链接不携带登录地址或任何凭据。'])
    Button('打开 GitHub · ccch1mneyyy/dsh-Go').width('100%').backgroundColor($r('app.color.accent'))
      .enabled(!this.busy).onClick(() => { this.openExternal(GITHUB_URL); })
    Text(GITHUB_URL).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
    Button('打开项目网站 · go.dshtui.com').width('100%').enabled(!this.busy)
      .onClick(() => { this.openExternal(SITE_URL); })
    Text(SITE_URL).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
    Button('手动查看发布页 · 不自动检查更新').width('100%').enabled(!this.busy)
      .onClick(() => { this.openExternal(RELEASES_URL); })
    Text(RELEASES_URL).fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
  }

  @Builder
  diagnosticsContent() {
    Column({ space: GAP_NORMAL }) {
      this.infoRow('应用版本', this.versionLabel())
      this.infoRow('连接状态', this.connectionState || 'unknown')
      this.infoRow('当前主机', this.activeHostName || '未连接')
    }.width('100%').padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
    if (this.diagnosticText) {
      Text(this.diagnosticText)
        .fontSize(11).fontFamily('monospace').fontColor($r('app.color.text_secondary')).width('100%')
        .padding(MARGIN_EDGE).backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
    } else {
      Button('读取安全诊断').width('100%').onClick(() => { this.refreshDiagnostics(); })
    }
    Row({ space: GAP_NORMAL }) {
      Button('刷新').layoutWeight(1).enabled(!this.busy).onClick(() => { this.refreshDiagnostics(); })
      Button('复制').layoutWeight(1).enabled(!this.busy).onClick(() => { this.copyDiagnostics(false); })
    }.width('100%')
    Button('复制诊断以便手动分享').width('100%').backgroundColor($r('app.color.accent')).enabled(!this.busy)
      .onClick(() => { this.copyDiagnostics(true); })
    this.card('导出说明', [
      '分享按钮采用真实的剪贴板回退，成功文案只会是“已复制”；此改动未宣称 ShareKit 文件导出成功。',
      'JSON 不含消息、profile、host id、Cookie、Token 或 API Key；主机地址只保留 HTTP(S) origin。'
    ])
  }

  @Builder
  aboutContent() {
    Column({ space: GAP_NORMAL }) {
      Text('DSH Go').fontSize(28).fontWeight(FontWeight.Bold).width('100%')
      Text(this.versionLabel()).fontSize(15).fontColor($r('app.color.text_secondary')).width('100%')
      Text('项目作者：ccch1mneyyy').fontSize(14).width('100%')
      Text('原生 ArkUI 端；此安装包不是 Flutter 打包版本。').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
      Text('基于 DeepSeek Harness 的非官方手机应用。').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
    }.alignItems(HorizontalAlign.Start).width('100%').padding(MARGIN_EDGE)
      .backgroundColor($r('app.color.surface')).borderRadius(RADIUS_CARD)
    Button('安全诊断').width('100%').backgroundColor($r('app.color.accent')).onClick(() => this.openPage('diagnostics'))
    Button('开源许可与第三方声明').width('100%').onClick(() => this.openPage('licenses'))
    Button('项目仓库').width('100%').enabled(!this.busy).onClick(() => { this.openExternal(GITHUB_URL); })
  }

  @Builder
  licensesContent() {
    this.card('本项目', [
      'dsh-Go 仓库声明 AGPL-3.0；品牌与素材的特殊范围以仓库 LICENSE、ASSETS.md 为准。',
      '这里提供可核对摘要与原始链接，不把摘要冒充完整许可文本。'
    ])
    Button('查看仓库 LICENSE').width('100%').enabled(!this.busy).onClick(() => { this.openExternal(LICENSE_URL); })
    this.card('ds-harness-remote · MIT', [
      'Copyright (c) 2026 DSH Remote contributors。',
      '远程连接相关第三方声明已在 THIRD_PARTY_NOTICES.md 登记；MIT 要求保留版权和许可声明，软件按原样提供且无担保。'
    ])
    Button('打开 ds-harness-remote 上游').width('100%').enabled(!this.busy)
      .onClick(() => { this.openExternal(REMOTE_LICENSE_URL); })
    this.card('完整声明边界', [
      '此原生端不是 Flutter APK，因此不在这里罗列 Flutter/Dart 包许可或声称它们已打入本安装包。',
      '仓库 THIRD_PARTY_NOTICES.md 已覆盖第三方来源与许可；最终发行物仍需按实际文件核验通知。'
    ])
    Button('查看 THIRD_PARTY_NOTICES.md').width('100%').backgroundColor($r('app.color.accent'))
      .enabled(!this.busy).onClick(() => { this.openExternal(NOTICES_URL); })
  }

  @Builder
  systemActionsContent() {
    this.card('当前可用的本机操作', [
      '这里只提供已有真实系统接口的入口，不提供无障碍读屏、跨应用控制、后台保活或未经确认的权限开关。'
    ])
    Button('打开本应用通知设置').width('100%').backgroundColor($r('app.color.accent')).enabled(!this.busy)
      .onClick(() => { this.openNotificationSettings(); })
    Button('复制安全诊断').width('100%').enabled(!this.busy).onClick(() => { this.copyDiagnostics(false); })
    Button('打开项目 GitHub').width('100%').enabled(!this.busy).onClick(() => { this.openExternal(GITHUB_URL); })
  }

  @Builder
  languageContent() {
    this.card('当前语言：中文', [
      '此原生界面目前只有中文文案，尚未完成全量本地化，因此不提供伪装成可用的语言选择。',
      '这里不会修改系统语言，也不会改变主机或其他应用的locale。'
    ])
  }

  @Builder
  content() {
    if (this.page === 'notifications') {
      this.notificationsContent()
    } else if (this.page === 'performance') {
      this.performanceContent()
    } else if (this.page === 'privacy') {
      this.privacyContent()
    } else if (this.page === 'help') {
      this.helpContent()
    } else if (this.page === 'community') {
      this.communityContent()
    } else if (this.page === 'diagnostics') {
      this.diagnosticsContent()
    } else if (this.page === 'licenses') {
      this.licensesContent()
    } else if (this.page === 'systemActions') {
      this.systemActionsContent()
    } else if (this.page === 'language') {
      this.languageContent()
    } else {
      this.aboutContent()
    }
  }

  @Builder detailTitle() { DetailTitle({ stack: this.stack, title: this.pageTitle() }) }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: GAP_CARD }) {
          Row().height(this.topSafe + 64)
          this.content()
          if (this.errorText) {
            Text(this.errorText).fontSize(13).fontColor($r('app.color.danger')).width('100%').lineHeight(19)
          }
          if (this.notificationFailure && !this.errorText) {
            Text(this.publishFailureMessage()).fontSize(13).fontColor($r('app.color.danger')).width('100%').lineHeight(19)
          }
          if (this.noticeText) {
            Text(this.noticeText).fontSize(13).fontColor($r('app.color.success')).width('100%').lineHeight(19)
          }
          Row().height(this.bottomSafe + GAP_LARGE)
        }.width('100%').padding(MARGIN_EDGE).alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring)
    }
    .title({ builder: this.detailTitle, height: this.topSafe + 64 }, titleBarOptions()).hideBackButton(true)
    .backgroundColor($r('app.color.bg'))
    .onShown(() => {
      this.activate();
      if (this.page === 'notifications') this.refreshSystemNotifications();
    })
    .onBackPressed(() => { this.deactivate(); this.stack.pop(); return true; })
  }
}
