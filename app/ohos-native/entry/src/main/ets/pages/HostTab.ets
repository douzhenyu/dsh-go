import { ItemRestriction, LengthMetrics, SegmentButton, SegmentButtonOptions, SegmentButtonTextItem } from '@kit.ArkUI';
import { HostInfo, Session, Workspace, hostKindLabel } from '../common/Models';
import { appStore } from '../state/AppStore';
import {
  GAP_CARD, GAP_LARGE, GAP_NORMAL, GAP_TEXT_V, MARGIN_EDGE, RADIUS_CARD, RADIUS_CONTROL, RADIUS_ICON,
  progressiveTopBlur, titleBarOptions,
  barMaterial, listCacheCount
} from '../common/Style';
import { GlassIconButton, Tag } from '../components/Common';
import { SymbolIcon } from '../components/Symbols';

function kindIcon(kind: string): Resource {
  if (kind === 'relay') {
    return $r('sys.symbol.desktop_fill');
  } else if (kind === 'ssh') {
    return $r('sys.symbol.desktop');
  }
  return $r('sys.symbol.display');
}

function stateColor(state: string): ResourceColor {
  if (state === 'connected') {
    return $r('app.color.success');
  } else if (state === 'error') {
    return $r('app.color.danger');
  }
  return $r('app.color.text_tertiary');
}

function stateText(state: string): string {
  if (state === 'connected') {
    return '已连接';
  } else if (state === 'connecting') {
    return '连接中';
  } else if (state === 'error') {
    return '连接失败';
  }
  return '未连接';
}

// A saved endpoint is not a presence signal. Only the active ready carrier is connected.
function hostConnectionState(hostId: string, activeId: string, state: string): string {
  if (hostId !== activeId) return 'disconnected';
  if (state === 'ready') return 'connected';
  if (state === 'connecting' || state === 'error') return state;
  return 'disconnected';
}

@Component
export struct HostTab {
  stack: NavPathStack = new NavPathStack();
  @StorageLink('topSafe') topSafe: number = 36;
  @StorageLink('bottomSafe') bottomSafe: number = 28;
  @State viewportHeight: number = 900;
  @StorageLink('hosts') hosts: HostInfo[] = [];
  @StorageLink('activeHostId') currentId: string = '';
  @StorageLink('connectionState') connectionState: string = '';
  @StorageLink('connectionError') connectionError: string = '';
  @State showConnect: boolean = false;
  @State launchUrl: string = '';
  @State hostName: string = '';
  @State connecting: boolean = false;
  @State measuring: boolean = false;
  @State actionError: string = '';
  @State expandedHost: string = '';
  @State hostFilterIdx: number[] = [0];
  @State hostFilterOptions: SegmentButtonOptions = SegmentButtonOptions.tab({
    buttons: [{ text: '全部' }, { text: '已连接' }, { text: '未连接' }] as ItemRestriction<SegmentButtonTextItem>,
    fontSize: 14,
    selectedFontSize: 14,
    // System colours: the material inverts them automatically (hard-coded colours do not).
    fontColor: $r('sys.color.font_secondary'),
    selectedFontColor: $r('sys.color.font_on_primary'),
    selectedBackgroundColor: $r('sys.color.comp_background_emphasize'),
    backgroundBorderRadius: LengthMetrics.vp(20),
    itemBorderRadius: LengthMetrics.vp(20),
    buttonPadding: { top: 10, bottom: 10 },
    backgroundSystemMaterial: barMaterial()
  });
  private async measure(): Promise<void> {
    if (this.measuring || this.connectionState !== 'ready') {
      return;
    }
    this.measuring = true;
    this.actionError = '';
    try {
      await appStore.measure();
    } catch (_) {
      this.actionError = '延迟测量失败，请检查主机连接后重试。';
    } finally {
      this.measuring = false;
    }
  }

  private remoteConnection(server: string = ''): void {
    if (server) AppStorage.setOrCreate('remoteServerUrl', server);
    this.stack.pushPathByName('remote', null);
  }

  private addHost(): void {
    this.getUIContext().getPromptAction().showActionMenu({
      title: '添加主机', buttons: [
        { text: 'DSH Remote', color: $r('sys.color.font_primary') },
        { text: 'HTTP 直连', color: $r('sys.color.font_primary') }
      ]
    }).then((result) => { if (result.index === 0) this.remoteConnection(); else this.openConnection(); }).catch(() => {});
  }

  private openConnection(): void {
    this.launchUrl = '';
    this.hostName = '';
    this.actionError = '';
    this.showConnect = true;
  }

  private async connect(): Promise<void> {
    if (this.connecting || this.launchUrl.trim().length === 0) {
      return;
    }
    this.connecting = true;
    this.actionError = '';
    try {
      await appStore.connect(this.launchUrl.trim(), this.hostName.trim());
      this.launchUrl = '';
      this.hostName = '';
      if (this.connectionState === 'ready') {
        this.showConnect = false;
      } else {
        this.actionError = '连接未完成，请检查主机和登录链接。';
      }
    } catch (_) {
      this.launchUrl = '';
      this.actionError = AppStorage.get<string>('connectionError') || '连接失败，请检查主机是否在线并重新粘贴登录链接。';
    } finally {
      this.connecting = false;
    }
  }

  private async selectHost(host: HostInfo): Promise<void> {
    if (hostConnectionState(host.id, this.currentId, this.connectionState) === 'connected') {
      AppStorage.setOrCreate('selectedTab', 1);
      return;
    }
    if (host.kind === 'remote') {
      const end: number = host.id.lastIndexOf('@');
      const target: string = host.id.startsWith('remote:') && end > 7 ? host.id.substring(7, end) : '';
      AppStorage.setOrCreate('remoteTargetHostId', target);
      this.remoteConnection(host.address);
      return;
    }
    this.actionError = '';
    try {
      await appStore.selectHost(host.id);
    } catch (_) {
      this.actionError = '此主机需要重新认证，请粘贴新的登录链接。';
    }
    if (this.connectionState !== 'ready') {
      this.launchUrl = '';
      this.hostName = host.name;
      this.showConnect = true;
    }
  }

  private visibleHosts(): HostInfo[] {
    const idx: number = this.hostFilterIdx.length > 0 ? this.hostFilterIdx[0] : 0;
    if (idx === 1) {
      return this.hosts.filter((h: HostInfo) => hostConnectionState(h.id, this.currentId, this.connectionState) === 'connected');
    } else if (idx === 2) {
      return this.hosts.filter((h: HostInfo) => hostConnectionState(h.id, this.currentId, this.connectionState) !== 'connected');
    }
    return this.hosts;
  }

  // Actual height of the title bar: status bar + title row + control row.
  private barBottom(): number {
    return this.topSafe + 96;
  }

  // Whole top bar: title row with the two round buttons, then the segmented filter.
  // It is the Navigation title bar, so the system draws the immersive material behind
  // it and blurs the content that scrolls under it.
  @Builder
  hostTitle() {
    Column() {
      Row({ space: GAP_NORMAL }) {
        Text('主机')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        GlassIconButton({
          icon: $r('sys.symbol.plus'),
          diameter: 40,
          inTitleBar: true,
          onTap: () => this.addHost()
        })
        GlassIconButton({
          icon: $r('sys.symbol.link'),
          diameter: 40,
          inTitleBar: true,
          onTap: () => this.remoteConnection()
        })
      }
      .width('100%')
      .height(56)
      .padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })

      SegmentButton({
        options: this.hostFilterOptions,
        selectedIndexes: $hostFilterIdx,
        onItemClicked: (index: number) => {
          this.hostFilterIdx = [index];
        }
      })
        .width('100%')
        .height(40)
        .padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
    }
    .width('100%')
    .height(this.barBottom())
    .padding({ top: this.topSafe })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  connectionForm() {
    Column({ space: GAP_LARGE }) {
      Text('连接直连主机').fontSize(22).fontWeight(FontWeight.Bold)
      Text('在电脑运行 dsh web，粘贴输出的登录 URL。凭据仅在内存中使用，重新打开应用需再次认证。')
        .fontSize(13).fontColor($r('app.color.text_secondary'))
      TextInput({ text: this.hostName, placeholder: '主机名称（可选）' })
        .enabled(!this.connecting)
        .onChange((value: string) => { this.hostName = value; })
      TextInput({ text: this.launchUrl, placeholder: '粘贴 dsh web 登录 URL' })
        .type(InputType.Password)
        .showPasswordIcon(false)
        .enabled(!this.connecting)
        .onChange((value: string) => { this.launchUrl = value; })
      if (this.actionError.length > 0 || this.connectionState === 'error') {
        Text(this.actionError || this.connectionError || '连接失败，请重新认证。')
          .fontSize(13).fontColor($r('app.color.danger'))
      }
      Button(this.connecting ? '连接中…' : '连接')
        .width('100%')
        .backgroundColor($r('app.color.accent'))
        .enabled(!this.connecting && this.launchUrl.trim().length > 0)
        .onClick(() => { this.connect(); })
    }
    .width('100%')
    .padding(MARGIN_EDGE)
    .alignItems(HorizontalAlign.Start)
  }


  build() {
    Navigation() {
      Stack({ alignContent: Alignment.TopStart }) {
        List({ space: GAP_CARD }) {
          ListItem() {
            Row().width('100%').height(this.barBottom() + GAP_LARGE)
          }

          if (this.connectionState === 'connecting') {
            ListItem() {
              Row({ space: GAP_NORMAL }) {
                LoadingProgress().width(24).height(24).color($r('app.color.accent'))
                Text('正在认证并读取主机数据…').fontSize(14)
              }.padding(MARGIN_EDGE)
            }
          }
          if (this.connectionState === 'error' || this.connectionError.length > 0 || this.actionError.length > 0) {
            ListItem() {
              Text(this.actionError || this.connectionError || '连接失败，请重新认证。')
                .fontSize(13).fontColor($r('app.color.danger')).padding(MARGIN_EDGE)
            }
          }
          if (this.visibleHosts().length === 0) {
            ListItem() {
              Column({ space: GAP_LARGE }) {
                Text(this.hosts.length === 0 ? '添加你的第一台主机' : '此分组暂无主机')
                  .fontSize(18).fontWeight(FontWeight.Medium)
                Text('登录 DSH Remote，选择账号下的主机，安全访问工作区与会话。')
                  .fontSize(13).fontColor($r('app.color.text_secondary'))
                Button('连接远程主机').backgroundColor($r('app.color.accent'))
                  .onClick(() => this.remoteConnection())
                Button('HTTP 直连').onClick(() => this.openConnection())
              }.width('100%').padding(MARGIN_EDGE).alignItems(HorizontalAlign.Start)
            }.padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
          }

          ForEach(this.visibleHosts(), (host: HostInfo) => {
            ListItem() {
              HostCard({
                host: host, measuring: this.measuring, expandedHost: $expandedHost,
                onSelect: (selected: HostInfo) => { this.selectHost(selected); },
                onMeasure: () => { this.measure(); },
                onDisconnect: () => { appStore.disconnect(); this.expandedHost = ''; this.actionError = ''; }
              })
            }
            .padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
          }, (host: HostInfo) => host.id)

          ListItem() {
            Row().width('100%').height(this.bottomSafe + 128)
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clip(false)
        .cachedCount(listCacheCount(), true)
          .onAreaChange((_old: Area, area: Area) => {
            this.viewportHeight = Number(area.height);
          })
          .linearGradientBlur(30, progressiveTopBlur(this.barBottom(), this.viewportHeight))


      }
      .width('100%')
      .height('100%')
    }
    .title({ builder: this.hostTitle, height: this.barBottom() }, titleBarOptions())
    .titleMode(NavigationTitleMode.Full)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .backgroundColor($r('app.color.bg'))
    .bindSheet($$this.showConnect, this.connectionForm(), {
      height: SheetSize.LARGE,
      showClose: true,
      onDisappear: () => {
        this.launchUrl = '';
        this.hostName = '';
      }
    })
  }
}

@Component
struct HostCard {
  @Prop host: HostInfo = { id: '', name: '', kind: '', address: '', state: '', route: '', latency: '' };
  @Prop measuring: boolean = false;
  @Link expandedHost: string;
  onSelect: (host: HostInfo) => void = () => {};
  onMeasure: () => void = () => {};
  onDisconnect: () => void = () => {};
  @StorageLink('activeHostId') currentId: string = '';
  @StorageLink('connectionState') connectionState: string = '';
  @StorageLink('sessions') sessions: Session[] = [];
  @StorageLink('workspaces') workspaces: Workspace[] = [];
  @StorageLink('dataLoading') dataLoading: boolean = false;
  @StorageLink('modelLabels') modelLabels: string[] = [];
  @StorageLink('permissionLabels') permissionLabels: string[] = [];
  @StorageLink('catalogError') catalogError: string = '';
  @StorageLink('hostLatency') hostLatency: string = '—';

  private state(): string {
    return hostConnectionState(this.host.id, this.currentId, this.connectionState);
  }
  private statusLabel(): string { return stateText(this.state()); }
  private statValue(label: string): string {
    if (this.state() !== 'connected') return '—';
    if (label === '网络路径') return this.host.route || '—';
    if (label === '延迟') return this.measuring ? '测量中…' : (this.hostLatency || '—');
    return this.dataLoading ? '读取中…' : `${label === '对话' ? this.sessions.length : this.workspaces.length}`;
  }
  private catalogValue(title: string): string {
    if (this.state() !== 'connected') return '连接后读取';
    const labels: string[] = title === '模型目录' ? this.modelLabels : this.permissionLabels;
    return labels.length > 0 ? labels.join('、') : (this.catalogError || '主机未提供目录');
  }
  private toggle(): void { this.expandedHost = this.expandedHost === this.host.id ? '' : this.host.id; }
  private open(): void {
    if (this.state() === 'connecting') return;
    if (this.state() === 'connected' || this.host.kind === 'remote') this.onSelect(this.host);
    else this.toggle();
  }

  @Builder
  stat(label: string) {
    Column({ space: GAP_TEXT_V }) {
      Text(this.statValue(label))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(label)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  smallButton(icon: Resource, label: string, danger: boolean) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: GAP_NORMAL }) {
        SymbolIcon({
          icon: icon,
          color: danger ? $r('app.color.danger') : $r('app.color.text_primary'),
          iconSize: 16
        })
        Text(label)
          .fontSize(14)
          .fontColor(danger ? $r('app.color.danger') : $r('app.color.text_primary'))
      }
    }
    .height(36)
    .layoutWeight(1)
    .padding({ left: GAP_NORMAL, right: GAP_NORMAL })
    .borderRadius(RADIUS_CONTROL)
    .backgroundColor($r('app.color.surface_alt'))
    .enabled(this.connectionState !== 'connecting' && (!this.measuring || label !== '测试延迟'))
    .onClick(() => {
      if (label === '测试延迟') {
        this.onMeasure();
      } else if (label === '断开') {
        this.onDisconnect();
      } else if (label === '连接') {
        this.onSelect(this.host);
      } else {
        this.toggle();
      }
    })
  }

  @Builder
  configRow(icon: Resource, title: string, value: string) {
    Row({ space: GAP_LARGE }) {
      SymbolIcon({ icon: icon, color: $r('app.color.accent'), iconSize: 16 })
      Text(title)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text(title === '模型目录' || title === '权限目录' ? this.catalogValue(title) : value)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '48%' })

    }
    .width('100%')
    .height(48)
  }

  build() {
    Column() {
      Row({ space: GAP_CARD }) {
        Stack() {
          SymbolIcon({ icon: kindIcon(this.host.kind), color: $r('app.color.accent'), iconSize: 22 })
        }
        .width(44)
        .height(44)
        .borderRadius(RADIUS_ICON)
        .backgroundColor($r('app.color.accent_soft'))

        Column({ space: GAP_NORMAL }) {
          Text(this.host.name)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: GAP_NORMAL }) {
            Text(hostKindLabel(this.host.kind))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
            if (this.host.id === this.currentId) {
              Tag({ label: '当前', accent: true })
            }
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Row({ space: 6 }) {
          Circle().width(6).height(6).fill(stateColor(this.state()))
          Text(this.statusLabel())
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(stateColor(this.state()))
        }
        .padding({ left: GAP_NORMAL, right: GAP_NORMAL, top: 4, bottom: 4 })
        .borderRadius(RADIUS_CONTROL)
        .backgroundColor($r('app.color.surface_alt'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.state() === 'connected') {
        Row() {
          this.stat('网络路径')
          this.stat('延迟')
          this.stat('对话')
          this.stat('工作区')
        }
        .width('100%')
        .padding(GAP_CARD)
        .borderRadius(RADIUS_ICON)
        .backgroundColor($r('app.color.surface_alt'))
        .margin({ top: GAP_LARGE })
      } else {
        Text('连接后查看对话与工作区')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: GAP_LARGE })
      }

      Row({ space: GAP_NORMAL }) {
        if (this.state() === 'connected') {
          this.smallButton($r('sys.symbol.stopwatch'), '测试延迟', false)
          this.smallButton($r('sys.symbol.xmark_circle'), '断开', true)
        } else if (this.state() !== 'connecting') {
          this.smallButton($r('sys.symbol.link'), '连接', false)
        }
        this.smallButton($r('sys.symbol.gearshape'), '设置', false)
      }
      .width('100%')
      .margin({ top: GAP_LARGE })

      if (this.expandedHost === this.host.id) {
        Column() {
          Divider().color($r('app.color.divider'))
          Text('此主机的配置')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding({ top: GAP_NORMAL, bottom: GAP_TEXT_V })
          this.configRow($r('sys.symbol.key'), '模型目录', '')
          this.configRow($r('sys.symbol.lock_shield'), '权限目录', '')
          this.configRow($r('sys.symbol.slider_horizontal_2'), '引擎参数', '设置页 · 读取当前主机配置')
          this.configRow($r('sys.symbol.puzzle'), '插件管理', '设置页 · 读取与管理当前主机')
          this.configRow($r('sys.symbol.globe_and_keyboard'), '联网搜索', '设置页 · 读取当前主机配置')
          this.configRow($r('sys.symbol.wand_and_stars'), '图像与视频', '设置页 · 按主机实际提供')
        }
        .width('100%')
        .margin({ top: GAP_LARGE })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .padding(MARGIN_EDGE)
    .borderRadius(RADIUS_CARD)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.divider') })
    .stateStyles({
      pressed: { opacity: 0.88 },
      normal: { opacity: 1.0 }
    })
    .onClick(() => this.open())
  }

}
