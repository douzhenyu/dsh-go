import { ItemRestriction, LengthMetrics, SegmentButton, SegmentButtonOptions, SegmentButtonTextItem } from '@kit.ArkUI';
import { Session, SessionGroup, Workspace, statusLabel } from '../common/Models';
import { appStore } from '../state/AppStore';
import {
  GAP_CARD, GAP_LARGE, GAP_NORMAL, GAP_TEXT_H, GAP_TEXT_V, MARGIN_EDGE, RADIUS_CARD, RADIUS_CONTROL,
  progressiveTopBlur, titleBarOptions,
  barMaterial, floatingMaterial, listCacheCount
} from '../common/Style';
import { GlassIconButton, InitialTile, StatusDot } from '../components/Common';
import { SymbolIcon } from '../components/Symbols';

const FILTERS: string[] = ['全部', '运行中', '待确认', '未读'];
const TITLE_ROW: number = 56;
const TITLE_H: number = 112;
const SEARCH_H: number = 40;

@Component
export struct ConversationsTab {
  stack: NavPathStack = new NavPathStack();
  @StorageLink('topSafe') topSafe: number = 36;
  @StorageLink('bottomSafe') bottomSafe: number = 28;
  @StorageLink('sessions') sessions: Session[] = [];
  @StorageLink('workspaces') workspaces: Workspace[] = [];
  @StorageLink('connectionState') connectionState: string = 'disconnected';
  @StorageLink('connectionError') connectionError: string = '';
  @StorageLink('dataLoading') dataLoading: boolean = false;
  @State showNew: boolean = false;
  @State newWorkspace: number = 0;
  @State newPath: string = '';
  @State creating: boolean = false;
  @State actionError: string = '';
  @State viewportHeight: number = 900;
  @State workspace: string = '全部';
  @State filterIdx: number[] = [0];
  @State wsIdx: number = 0;
  @State query: string = '';
  @State searching: boolean = false;
  @State filterOptions: SegmentButtonOptions = SegmentButtonOptions.tab({
    buttons: [{ text: '全部' }, { text: '运行中' }, { text: '待确认' }, { text: '未读' }] as ItemRestriction<SegmentButtonTextItem>,
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
  private scroller: Scroller = new Scroller();
  private matches(s: Session): boolean {
    if (this.workspace !== '全部' && s.workspaceId !== this.workspace) {
      return false;
    }
    const idx: number = this.filterIdx.length > 0 ? this.filterIdx[0] : 0;
    if (idx === 1 && s.status !== 'running') {
      return false;
    }
    if (idx === 2 && s.status !== 'pending') {
      return false;
    }
    if (idx === 3 && s.status !== 'unread') {
      return false;
    }
    const q: string = this.query.trim().toLowerCase();
    return q.length === 0 || s.title.toLowerCase().includes(q) || s.preview.toLowerCase().includes(q);
  }

  private visible(): Session[] {
    return this.sessions.filter((s: Session) => this.matches(s));
  }

  private count(f: string): number {
    if (f === '运行中') {
      return this.sessions.filter((s: Session) => s.status === 'running').length;
    } else if (f === '待确认') {
      return this.sessions.filter((s: Session) => s.status === 'pending').length;
    } else if (f === '未读') {
      return this.sessions.filter((s: Session) => s.status === 'unread').length;
    }
    return 0;
  }

  private statusColor(status: string): ResourceColor {
    if (status === 'running') {
      return $r('app.color.accent');
    } else if (status === 'pending') {
      return $r('app.color.warning');
    } else if (status === 'failed') {
      return $r('app.color.danger');
    }
    return $r('app.color.success');
  }

  private openChat(s: Session): void {
    appStore.selectSession(s);
    this.stack.pushPathByName('chat', null);
  }

  private workspaceOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '全部项目' }];
    return options.concat(this.workspaces.map((row: Workspace): SelectOption => ({ value: row.title })));
  }

  private newWorkspaceOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '未分组 · 主机当前目录' }];
    return options.concat(this.workspaces.map((row: Workspace): SelectOption => ({ value: row.title })));
  }

  private groups(): SessionGroup[] {
    const visible = this.visible();
    const groups: SessionGroup[] = [];
    for (const workspace of this.workspaces) {
      const items = visible.filter((row: Session): boolean => row.workspaceId === workspace.id);
      if (items.length > 0) groups.push({ name: workspace.title, path: workspace.path, items: items });
    }
    const ungrouped = visible.filter((row: Session): boolean => !row.workspaceId);
    if (ungrouped.length > 0) groups.push({ name: '未分组', path: '', items: ungrouped });
    return groups;
  }

  private async refresh(): Promise<void> {
    this.actionError = '';
    try { await appStore.refresh(); } catch (_) { this.actionError = '刷新失败，请检查主机连接'; }
  }

  private async createConversation(): Promise<void> {
    if (this.creating) return;
    this.creating = true; this.actionError = '';
    try {
      let id = this.newWorkspace > 0 && this.workspaces[this.newWorkspace - 1] ? this.workspaces[this.newWorkspace - 1].id : '';
      if (this.newPath.trim()) id = await appStore.createWorkspace(this.newPath.trim());
      const session = await appStore.createSession(id);
      this.showNew = false; this.newPath = ''; this.openChat(session);
    } catch (error) { this.actionError = '创建失败：' + (error as Error).message; }
    finally { this.creating = false; }
  }

  @Builder
  newConversation() {
    Column({ space: GAP_LARGE }) {
      Text('新建对话').fontSize(22).fontWeight(FontWeight.Bold)
      Text('选择主机工作区，或填写主机上的绝对目录创建工作区。')
        .fontSize(14).fontColor($r('app.color.text_secondary')).width('100%')
      Select(this.newWorkspaceOptions())
        .selected(this.newWorkspace).width('100%').height(44)
        .systemMaterial(barMaterial()).menuSystemMaterial(floatingMaterial(3))
        .onSelect((index: number) => { this.newWorkspace = index; this.newPath = ''; })
      TextInput({ text: this.newPath, placeholder: '新工作区目录（可选）' })
        .height(48).onChange((value: string) => { this.newPath = value; })
      if (this.actionError) { Text(this.actionError).fontSize(13).fontColor($r('app.color.danger')).width('100%') }
      Button(this.creating ? '正在创建…' : '创建对话')
        .width('100%').height(44).enabled(!this.creating && this.connectionState === 'ready')
        .backgroundColor($r('app.color.accent')).fontColor(Color.White)
        .onClick(() => { this.createConversation(); })
    }
    .width('100%').padding(24).alignItems(HorizontalAlign.Start)
  }

  @Builder
  dataState() {
    if (this.dataLoading) {
      Row({ space: GAP_NORMAL }) { LoadingProgress().width(20).height(20); Text('正在读取主机会话').fontSize(14) }
        .width('100%').justifyContent(FlexAlign.Center).padding(24)
    }
    if (this.connectionError || this.actionError) {
      Text(this.actionError || this.connectionError).fontSize(13).fontColor($r('app.color.danger')).padding(16).width('100%')
    }
    if (!this.dataLoading && this.visible().length === 0) {
      Column({ space: GAP_LARGE }) {
        Text(this.connectionState === 'ready' ? '暂无符合条件的对话' : '连接主机后查看真实会话')
          .fontSize(16).fontColor($r('app.color.text_secondary'))
        Button(this.connectionState === 'ready' ? '新建对话' : '前往主机')
          .onClick(() => {
            if (this.connectionState === 'ready') this.showNew = true;
            else AppStorage.setOrCreate('selectedTab', 0);
          })
      }
      .padding(24).width('100%')
    }
  }

  @Builder
  convTitle() {
    Column() {
      Row({ space: GAP_NORMAL }) {
        Text('对话')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        GlassIconButton({
          icon: $r('sys.symbol.square_and_pencil'),
          diameter: 40,
          inTitleBar: true,
          onTap: () => {
            if (this.connectionState === 'ready') { this.actionError = ''; this.showNew = true; }
            else AppStorage.setOrCreate('selectedTab', 0);
          }
        })
        .accessibilityText('新建对话')
        GlassIconButton({
          icon: $r('sys.symbol.arrow_clockwise'), diameter: 40, inTitleBar: true,
          onTap: () => { this.refresh(); }
        })
        .accessibilityText('刷新会话')
        GlassIconButton({
          icon: $r('sys.symbol.magnifyingglass'),
          diameter: 40,
          inTitleBar: true,
          onTap: () => {
            this.searching = !this.searching;
            if (!this.searching) {
              this.query = '';
            }
          }
        })
      }
      .width('100%')
      .height(TITLE_ROW)
      .padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })

      Row({ space: GAP_NORMAL }) {
        SegmentButton({
          options: this.filterOptions,
          selectedIndexes: $filterIdx,
          onItemClicked: (index: number) => {
            this.filterIdx = [index];
          }
        })
        .layoutWeight(1)
        .height(40)
        Select(this.workspaceOptions())
          .systemMaterial(barMaterial())
          .menuSystemMaterial(floatingMaterial(3))
          .selected(this.wsIdx)
          .value(this.workspace === '全部' ? '全部项目' : (this.workspaces.find((row: Workspace): boolean => row.id === this.workspace)?.title || '全部项目'))
          .font({ size: 14 })
          .selectedOptionFont({ size: 14 })
          .optionFont({ size: 14 })
          .width(112)
          .height(40)
          .onSelect((index: number) => {
            this.wsIdx = index;
            this.workspace = index === 0 || !this.workspaces[index - 1] ? '全部' : this.workspaces[index - 1].id;
          })
      }
      .width('100%')
      .padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
    }
    .width('100%')
    .height(this.barBottom())
    .padding({ top: this.topSafe })
    .alignItems(HorizontalAlign.Start)
  }

  // Actual height of the title bar: status bar + title row + control row.
  private barBottom(): number {
    return this.topSafe + 96;
  }

  @Builder
  listHead() {
    if (this.searching) {
      Search({ value: this.query, placeholder: '搜索对话标题或内容' })
        .height(SEARCH_H)
        .borderRadius(RADIUS_CONTROL)
        .backgroundColor($r('app.color.glass'))
        .placeholderColor($r('app.color.text_tertiary'))
        .placeholderFont({ size: 14 })
        .searchIcon({ src: $r('sys.symbol.magnifyingglass') })
        .margin({ left: MARGIN_EDGE, right: MARGIN_EDGE })
        .onChange((value: string) => {
          this.query = value;
        })
    }
  }

  @Builder
  groupHeader(g: SessionGroup) {
    Row({ space: GAP_TEXT_H }) {
      Text(g.name)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
      Text(`${g.items.length}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
      Blank()
      Text(g.path)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '55%' })
    }
    .width('100%')
    .padding({ left: MARGIN_EDGE, right: MARGIN_EDGE, bottom: GAP_NORMAL })
  }

  @Builder
  sessionCard(s: Session) {
    Row({ space: GAP_LARGE }) {
      InitialTile({ label: s.title })

      Column() {
        Row({ space: GAP_TEXT_H }) {
          Text(s.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(s.time)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')

        Text(s.preview)
          .fontSize(14)
          .lineHeight(20)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: GAP_TEXT_V })

        Row({ space: GAP_TEXT_H }) {
          if (s.status !== 'idle') {
            StatusDot({ kind: s.status, diameter: 8 })
            Text(statusLabel(s.status))
              .fontSize(12)
              .fontColor(this.statusColor(s.status))
            Text('·')
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
          }
          Text(s.model)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(VerticalAlign.Center)
        .margin({ top: GAP_NORMAL })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(MARGIN_EDGE)
    .alignItems(VerticalAlign.Center)
    .borderRadius(RADIUS_CARD)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.divider') })
    .stateStyles({
      pressed: { opacity: 0.88 },
      normal: { opacity: 1.0 }
    })
    .onClick(() => this.openChat(s))
  }

  build() {
    Stack() {
      Navigation() {
        Stack({ alignContent: Alignment.TopStart }) {
          List({ space: GAP_CARD }) {
            ListItem() {
              Row().width('100%').height(this.barBottom() + GAP_LARGE)
            }

            ListItem() {
              this.listHead()
            }
            ListItem() { this.dataState() }

            ForEach(this.groups(), (g: SessionGroup) => {
              ListItemGroup({ header: this.groupHeader(g), space: GAP_CARD }) {
                ForEach(g.items, (s: Session) => {
                  ListItem() {
                    this.sessionCard(s)
                  }
                  .padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
                }, (s: Session) => s.id)
              }
            }, (g: SessionGroup) => `${g.name}:${g.items.map((s: Session) => s.id).join(',')}`)

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
      .title({ builder: this.convTitle, height: this.barBottom() }, titleBarOptions())
      .titleMode(NavigationTitleMode.Full)
      .hideBackButton(true)
      .mode(NavigationMode.Stack)
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height('100%')

    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg'))
    .bindSheet($$this.showNew, this.newConversation(), { height: 420, showClose: true })
  }

}
