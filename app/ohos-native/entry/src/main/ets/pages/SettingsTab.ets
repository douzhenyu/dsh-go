import common from '@ohos.app.ability.common';
import { ItemRestriction, LengthMetrics, SegmentButton, SegmentButtonOptions, SegmentButtonTextItem } from '@kit.ArkUI';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import {
  GAP_CARD, GAP_LARGE, GAP_NORMAL, MARGIN_EDGE, RADIUS_CARD, RADIUS_CONTROL, RADIUS_ICON,
  progressiveTopBlur, titleBarOptions, barMaterial, floatingMaterial, listCacheCount
} from '../common/Style';
import { GlassIconButton } from '../components/Common';
import { SymbolIcon } from '../components/Symbols';
import { appStore } from '../state/AppStore';
import { nativeLocalSettings } from '../state/NativeLocalSettings';

function options(items: string[]): SelectOption[] { return items.map((value: string): SelectOption => ({ value: value })); }

@Component
export struct SettingsTab {
  stack: NavPathStack = new NavPathStack();
  @StorageLink('topSafe') topSafe: number = 28;
  @StorageLink('bottomSafe') bottomSafe: number = 0;
  @StorageLink('activeHostName') activeHostName: string = '';
  @StorageLink('connectionState') connectionState: string = '';
  @StorageLink('modelLabels') modelLabels: string[] = [];
  @StorageLink('permissionLabels') permissionLabels: string[] = [];
  @StorageLink('catalogError') catalogError: string = '';
  @StorageLink('preferenceRevision') @Watch('restorePreferences') preferenceRevision: number = 0;
  @StorageLink('nativeSettingsRevision') nativeSettingsRevision: number = 0;
  @State viewportHeight: number = 900;
  @State query: string = '';
  @State searching: boolean = false;
  @State sectionIdx: number[] = [0];
  @State theme: number = 0;
  @State fontSize: number = 1;
  @State foldDone: boolean = true;
  @State preferenceError: string = '';
  @State sectionOptions: SegmentButtonOptions = SegmentButtonOptions.tab({
    buttons: [{ text: '全部' }, { text: 'AI' }, { text: '能力' }, { text: '外观' }, { text: '其他' }] as ItemRestriction<SegmentButtonTextItem>,
    fontSize: 14, selectedFontSize: 14,
    fontColor: $r('sys.color.font_secondary'), selectedFontColor: $r('sys.color.font_on_primary'),
    selectedBackgroundColor: $r('sys.color.comp_background_emphasize'),
    backgroundBorderRadius: LengthMetrics.vp(20), itemBorderRadius: LengthMetrics.vp(20),
    buttonPadding: { top: 10, bottom: 10 }, backgroundSystemMaterial: barMaterial()
  });

  aboutToAppear(): void { this.restorePreferences(); }
  private restorePreferences(): void {
    this.theme = this.preferenceIndex('theme', 0, 2); this.fontSize = this.preferenceIndex('font', 1, 3);
    this.foldDone = appStore.getPreference('fold', 'true') === 'true';
  }
  private preferenceIndex(key: string, fallback: number, max: number): number {
    const value: number = Number(appStore.getPreference(key, `${fallback}`));
    return Number.isInteger(value) && value >= 0 && value <= max ? value : fallback;
  }
  private connectionLabel(): string {
    if (this.connectionState === 'ready') return '已连接 · 主机设置直接读写当前主机';
    if (this.connectionState === 'connecting') return '连接中…';
    if (this.connectionState === 'error') return '连接失败，请前往主机页重新认证';
    return '未连接 · 本地设置仍可使用';
  }
  private matches(...texts: string[]): boolean {
    const query: string = this.query.trim().toLowerCase();
    return !query || texts.some((text: string): boolean => text.toLowerCase().includes(query));
  }
  private sectionOn(index: number): boolean { return (this.sectionIdx[0] ?? 0) === 0 || this.sectionIdx[0] === index; }
  private barBottom(): number { return this.topSafe + 96; }
  private hostValue(value: string): string { return this.connectionState === 'ready' ? value : '连接主机后读取与配置'; }
  private open(page: string): void {
    if (!page) return;
    if (page.startsWith('host:')) this.stack.pushPathByName('host-settings', page.substring(5));
    else this.stack.pushPathByName('settings', page);
  }
  private applyTheme(index: number): void {
    this.theme = index;
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const app = context.getApplicationContext();
    app.setColorMode(index === 1 ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT :
      index === 2 ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK : ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
  }
  private async setSelect(id: string, index: number): Promise<void> {
    this.preferenceError = '';
    try {
      await appStore.setPreference(id, `${index}`);
      if (id === 'theme') this.applyTheme(index); else this.fontSize = index;
    } catch (_) { this.restorePreferences(); this.preferenceError = '偏好保存失败，请重试。'; }
  }
  private async setFold(on: boolean): Promise<void> {
    this.preferenceError = '';
    try { await appStore.setPreference('fold', `${on}`); this.foldDone = on; }
    catch (_) { this.restorePreferences(); this.preferenceError = '偏好保存失败，请重试。'; }
  }
  private notificationSummary(): string {
    return this.nativeSettingsRevision >= 0 && nativeLocalSettings.getPreference('enabled', 'true') === 'true' ? '应用内提醒与系统通知设置' : '已关闭 · 查看选项';
  }

  @Builder settingsTitle() {
    Column() {
      Row({ space: GAP_NORMAL }) {
        Text('设置').fontSize(30).fontWeight(FontWeight.Bold).fontColor($r('app.color.text_primary'))
        Blank()
        GlassIconButton({ icon: $r('sys.symbol.magnifyingglass'), diameter: 40, inTitleBar: true,
          onTap: () => { this.searching = !this.searching; if (!this.searching) this.query = ''; } })
      }.width('100%').height(56).padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
      SegmentButton({ options: this.sectionOptions, selectedIndexes: $sectionIdx,
        onItemClicked: (index: number) => { this.sectionIdx = [index]; } })
        .width('100%').height(40).padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
    }.width('100%').height(this.barBottom()).padding({ top: this.topSafe }).alignItems(HorizontalAlign.Start)
  }

  @Builder tile(icon: Resource) {
    Stack() { SymbolIcon({ icon: icon, color: $r('app.color.accent'), iconSize: 16 }) }
      .width(32).height(32).borderRadius(RADIUS_ICON).backgroundColor($r('app.color.accent_soft'))
  }
  @Builder groupLabel(label: string) {
    Text(label).fontSize(12).fontColor($r('app.color.text_tertiary')).width('100%')
      .padding({ left: MARGIN_EDGE, top: GAP_CARD, bottom: GAP_NORMAL })
  }
  @Builder card() {
    Column() {}.width('100%').borderRadius(RADIUS_CARD).backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.divider') })
  }
  @Builder divider() { Divider().color($r('app.color.divider')).margin({ left: 58, right: 14 }) }
  @Builder navRow(icon: Resource, title: string, value: string, page: string) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 12 }) {
        this.tile(icon)
        Text(title).fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
        if (value) Text(page.startsWith('host:') ? (this.connectionState === 'ready' ? '当前主机 · 查看与配置' : '连接主机后读取与配置') : value)
          .fontSize(13).fontColor($r('app.color.text_secondary')).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '45%' })
        if (page) SymbolIcon({ icon: $r('sys.symbol.chevron_right'), color: $r('app.color.text_tertiary'), iconSize: 13 })
      }.width('100%').height(54).padding({ left: 14, right: 14 })
    }.width('100%').padding(0).borderRadius(0).backgroundColor(Color.Transparent)
      .enabled(page.length > 0).onClick(() => this.open(page))
  }
  @Builder selectRow(icon: Resource, title: string, id: string, items: string[]) {
    Row({ space: 12 }) {
      this.tile(icon)
      Text(title).fontSize(15).fontColor($r('app.color.text_primary')).layoutWeight(1)
      Select(options(items)).systemMaterial(barMaterial()).menuSystemMaterial(floatingMaterial(3))
        .selected(id === 'theme' ? this.theme : this.fontSize)
        .value(items[id === 'theme' ? this.theme : this.fontSize])
        .font({ size: 13 }).fontColor($r('app.color.text_secondary')).selectedOptionFont({ size: 13 })
        .optionFont({ size: 14 }).backgroundColor(Color.Transparent).width(140)
        .onSelect((index: number) => this.setSelect(id, index))
    }.width('100%').height(54).padding({ left: 14, right: 6 })
  }
  @Builder overview() {
    Row({ space: 14 }) {
      Stack() { Text('D').fontSize(20).fontWeight(FontWeight.Bold).fontColor($r('app.color.on_accent')) }
        .width(48).height(48).borderRadius(24)
        .linearGradient({ angle: 140, colors: [[$r('app.color.accent_gradient_start'), 0], [$r('app.color.accent'), 1]] })
      Column({ space: 3 }) {
        Text(this.activeHostName || '尚未连接主机').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(this.connectionLabel()).fontSize(12).fontColor($r('app.color.text_secondary'))
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding(16).borderRadius(RADIUS_CARD).backgroundColor($r('app.color.surface'))
      .border({ width: 1, color: $r('app.color.divider') })
  }

  @Builder aiSection() {
    if (this.sectionOn(1) && this.matches('模型', '权限', '思考深度', 'Agent', '预设', '引擎')) {
      Column() {
        this.groupLabel('AI')
        Column() {
          if (this.matches('模型', '默认模型')) {
            this.navRow($r('sys.symbol.lightbulb'), '模型与思考深度', this.hostValue(this.modelLabels.length + ' 个模型 · 含新对话默认值'), 'host:models')
            this.divider()
          }
          if (this.matches('权限')) {
            this.navRow($r('sys.symbol.lock_shield'), '权限', this.hostValue(this.permissionLabels.join('、') || this.catalogError || '读取主机目录'), 'host:permission')
            this.divider()
          }
          if (this.matches('Agent', '预设', '个人偏好')) {
            this.navRow($r('sys.symbol.square_grid_2x2'), 'Agent 预设', this.hostValue('预设、YAML 与新对话默认项'), 'host:presets')
            this.divider()
          }
          if (this.matches('引擎', '参数', '思考深度')) {
            this.navRow($r('sys.symbol.wand_and_stars'), '引擎参数', this.hostValue('子代理、Agent 循环与命令执行'), 'host:engine')
          }
        }.width('100%').borderRadius(RADIUS_CARD).backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.divider') })
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  @Builder abilitySection() {
    if (this.sectionOn(2) && this.matches('系统操作', '联网搜索', '插件', '图像与视频', '能力')) {
      Column() {
        this.groupLabel('能力')
        Column() {
          if (this.matches('系统操作')) {
            this.navRow($r('sys.symbol.hand_raised_hexagon_fill'), '系统操作', '本机系统操作尚未提供 · 查看边界', 'systemActions')
            this.divider()
          }
          if (this.matches('联网搜索')) {
            this.navRow($r('sys.symbol.globe_and_keyboard'), '联网搜索', this.hostValue('搜索服务、地址与调用上限'), 'host:web-search')
            this.divider()
          }
          if (this.matches('插件')) {
            this.navRow($r('sys.symbol.puzzle'), '插件', this.hostValue('真实清单、启停与即时配置'), 'host:plugins')
            this.divider()
          }
          if (this.matches('图像', '视频')) {
            this.navRow($r('sys.symbol.wand_and_stars'), '图像与视频', this.hostValue('按主机实际媒体插件配置'), 'host:media')
          }
        }.width('100%').borderRadius(RADIUS_CARD).backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.divider') })
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  @Builder appearanceSection() {
    if (this.sectionOn(3) && this.matches('主题', '字号', '折叠', '宠物', '外观')) {
      Column() {
        this.groupLabel('外观')
        Column() {
          if (this.matches('主题', '深色', '浅色')) { this.selectRow($r('sys.symbol.paintbrush_pointed'), '主题', 'theme', ['跟随系统', '浅色', '深色']); this.divider() }
          if (this.matches('字号')) { this.selectRow($r('sys.symbol.textformat'), '对话字号', 'font', ['小', '默认', '大', '特大']); this.divider() }
          if (this.matches('折叠', '收起过程')) {
            Row({ space: 12 }) {
              this.tile($r('sys.symbol.chevron_up'))
              Column({ space: 2 }) {
                Text('默认收起思考内容').fontSize(15).fontColor($r('app.color.text_primary'))
                Text('只控制思考文本，工具调用保持显示').fontSize(11).fontColor($r('app.color.text_tertiary'))
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Toggle({ type: ToggleType.Switch, isOn: this.foldDone }).systemMaterial(barMaterial())
                .selectedColor($r('app.color.accent')).onChange((value: boolean) => this.setFold(value))
            }.width('100%').height(58).padding({ left: 14, right: 14 })
            this.divider()
          }
          if (this.matches('宠物')) this.navRow($r('sys.symbol.star'), '宠物', '原生 ArkUI 版本未提供宠物', '')
        }.width('100%').borderRadius(RADIUS_CARD).backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.divider') })
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  @Builder generalSection() {
    if (this.sectionOn(4) && this.matches('语言', '通知', '语音', '性能', '后台', '隐私', '通用')) {
      Column() {
        this.groupLabel('通用')
        Column() {
          if (this.matches('语言')) { this.navRow($r('sys.symbol.globe_and_keyboard'), '语言', '简体中文（当前原生界面）', ''); this.divider() }
          if (this.matches('通知')) { this.navRow($r('sys.symbol.bell'), '通知', this.notificationSummary(), 'notifications'); this.divider() }
          if (this.matches('语音')) { this.navRow($r('sys.symbol.mic'), '语音输入', '原生语音识别尚未接入', ''); this.divider() }
          if (this.matches('性能')) { this.navRow($r('sys.symbol.stopwatch'), '性能与显示效果', '动效、渐进模糊与列表缓存', 'performance'); this.divider() }
          if (this.matches('后台')) { this.navRow($r('sys.symbol.clock'), '后台运行', '主机任务可继续 · 后台连接与提醒不保证', ''); this.divider() }
          if (this.matches('隐私')) this.navRow($r('sys.symbol.link'), '隐私与分享', '安全登录存储与诊断分享', 'privacy')
        }.width('100%').borderRadius(RADIUS_CARD).backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.divider') })
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  @Builder aboutSection() {
    if (this.sectionOn(4) && this.matches('帮助', '社区', '诊断', '版本', '更新', '许可', '关于', '沉浸光感')) {
      Column() {
        this.groupLabel('帮助与关于')
        Column() {
          if (this.matches('帮助')) { this.navRow($r('sys.symbol.questionmark_circle'), '使用帮助', '连接、会话、审批与安全边界', 'help'); this.divider() }
          if (this.matches('社区', '更新')) { this.navRow($r('sys.symbol.person_2'), '社区与发布', '项目、讨论与发布页', 'community'); this.divider() }
          if (this.matches('诊断')) { this.navRow($r('sys.symbol.info_circle'), '诊断', '安全摘要、复制与导出', 'diagnostics'); this.divider() }
          if (this.matches('版本', '关于')) { this.navRow($r('sys.symbol.info_circle'), '版本与关于', '读取原生应用信息', 'about'); this.divider() }
          if (this.matches('许可')) this.navRow($r('sys.symbol.doc_text'), '开源许可', '项目与第三方声明', 'licenses')
        }.width('100%').borderRadius(RADIUS_CARD).backgroundColor($r('app.color.surface'))
          .border({ width: 1, color: $r('app.color.divider') })
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
  }

  build() {
    Navigation() {
      List({ space: GAP_CARD }) {
        ListItem() { Row().width('100%').height(this.barBottom() + GAP_LARGE) }
        if (this.searching) {
          ListItem() {
            Search({ value: this.query, placeholder: '搜索设置' }).height(40).borderRadius(RADIUS_CONTROL)
              .backgroundColor($r('app.color.glass')).placeholderColor($r('app.color.text_tertiary'))
              .placeholderFont({ size: 14 }).onChange((value: string) => { this.query = value; })
          }.padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
        }
        if (!this.query) { ListItem() { this.overview() }.padding({ left: MARGIN_EDGE, right: MARGIN_EDGE }) }
        ListItem() { this.aiSection() }.padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
        ListItem() { this.abilitySection() }.padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
        ListItem() { this.appearanceSection() }.padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
        ListItem() { this.generalSection() }.padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
        ListItem() { this.aboutSection() }.padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
        ListItem() {
          Text(this.preferenceError || '主机设置以主机回答为准；个人偏好文件和本机系统操作不属于 Remote 设置接口。')
            .fontSize(11).fontColor($r('app.color.text_tertiary')).padding({ top: GAP_CARD, bottom: this.bottomSafe + 128 })
        }.padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
      }.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clip(false).cachedCount(listCacheCount(), true)
        .onAreaChange((_old: Area, area: Area) => { this.viewportHeight = Number(area.height); })
        .linearGradientBlur(30, progressiveTopBlur(this.barBottom(), this.viewportHeight))
    }.width('100%').height('100%')
    .title({ builder: this.settingsTitle, height: this.barBottom() }, titleBarOptions())
    .titleMode(NavigationTitleMode.Full).hideBackButton(true).mode(NavigationMode.Stack)
    .backgroundColor($r('app.color.bg'))
  }
}
