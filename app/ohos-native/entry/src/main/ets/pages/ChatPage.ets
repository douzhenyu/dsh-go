import { FrameCallback, KeyboardAvoidMode } from '@kit.ArkUI';
import { Message, Session } from '../common/Models';
import { appStore } from '../state/AppStore';
import { NativeHostEvent } from '../data/NativeDto';
import { HostQuestions } from '../components/HostQuestions';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  GAP_CARD, GAP_LARGE, GAP_NORMAL, GAP_TEXT_H, GAP_TEXT_V, MARGIN_EDGE, RADIUS_CARD, RADIUS_CONTROL, RADIUS_ICON,
  progressiveChatBlur, titleBarOptions, barMaterial, floatingMaterial, RADIUS_SHEET, FLOATING_BOTTOM_MARGIN, listCacheCount
} from '../common/Style';
import { GlassIconButton, StatusDot } from '../components/Common';
import { SymbolIcon } from '../components/Symbols';

class AfterChatLayout extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(_time: number): void { this.action(); }
}

@Component
export struct ChatPage {
  stack: NavPathStack = new NavPathStack();
  @StorageLink('sessionTitle') sessionTitle: string = '对话';
  @StorageLink('sessionWorkspace') sessionWorkspace: string = 'dsh-Go';
  @StorageLink('sessionModel') sessionModel: string = '未选择模型';
  @StorageLink('sessionId') sessionId: string = '';
  @StorageLink('sessionStatus') sessionStatus: string = 'idle';
  @StorageLink('topSafe') topSafe: number = 28;
  @StorageLink('bottomSafe') bottomSafe: number = 0;
  @State viewportHeight: number = 900;
  @State composerHeight: number = 240;
  @State composerExpanded: boolean = false;
  @StorageLink('chatMessages') @Watch('messagesChanged') messages: Message[] = [];
  @StorageLink('chatLoading') chatLoading: boolean = false;
  @StorageLink('chatBusy') chatBusy: boolean = false;
  @StorageLink('chatError') chatError: string = '';
  @StorageLink('chatHasMore') chatHasMore: boolean = false;
  @StorageLink('connectionState') connectionState: string = 'disconnected';
  @StorageLink('catalogError') catalogError: string = '';
  @StorageLink('sessionStatusText') statusText: string = '';
  @StorageLink('pendingRequests') pendingRequests: NativeHostEvent[] = [];
  @StorageLink('modelLabels') modelLabels: string[] = [];
  @StorageLink('depthLabels') depthLabels: string[] = [];
  @StorageLink('permissionLabels') permissionLabels: string[] = [];
  @StorageLink('selectionBusy') selectionBusy: boolean = false;
  @StorageLink('chatFontSize') chatFontSize: number = 15;
  @StorageLink('foldCompleted') foldCompleted: boolean = true;
  @State actionError: string = '';
  @State creating: boolean = false;
  @State input: string = '';
  @State expanded: string[] = [];
  @StorageLink('modelIndex') modelIdx: number = -1;
  @StorageLink('depthIndex') depthIdx: number = -1;
  @StorageLink('permissionIndex') permIdx: number = -1;
  private activeSession: string = '';
  private alive: boolean = false;
  private followBottom: boolean = true;

  private previousKeyboardMode: KeyboardAvoidMode = KeyboardAvoidMode.OFFSET;
  private messageScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.previousKeyboardMode = this.getUIContext().getKeyboardAvoidMode();
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
    this.activeSession = this.sessionId; this.alive = true; this.followBottom = true;
    try { appStore.openChat(this.activeSession); }
    catch (_) { this.actionError = '请先连接主机再打开对话'; }
  }

  aboutToDisappear(): void {
    this.alive = false; appStore.closeChat(this.activeSession);
    this.getUIContext().setKeyboardAvoidMode(this.previousKeyboardMode);
  }

  private messagesChanged(): void {
    if (!this.alive || !this.followBottom) return;
    this.getUIContext().postFrameCallback(new AfterChatLayout(() => {
      if (this.alive && this.followBottom) this.messageScroller.scrollEdge(Edge.Bottom);
    }));
  }
  private async copy(text: string): Promise<void> {
    try { await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text)); }
    catch (_) { this.actionError = '复制失败'; }
  }
  private async send(): Promise<void> {
    const text = this.input;
    try { await appStore.send(text); if (this.input === text) this.input = ''; this.followBottom = true; this.messagesChanged(); }
    catch (_) { /* Store preserves the stable request ID and publishes the safe error. */ }
  }
  private async createChat(): Promise<void> {
    if (this.creating) return;
    this.creating = true; this.actionError = '';
    try {
      const current = (AppStorage.get<Session[]>('sessions') || []).find((row: Session): boolean => row.id === this.activeSession);
      const session = await appStore.createSession(current?.workspaceId || '');
      appStore.selectSession(session); this.stack.replacePathByName('chat', null);
    } catch (_) { this.actionError = '主机未确认新对话，请检查连接后重试'; }
    finally { this.creating = false; }
  }
  private async approve(eventId: string, decision: string): Promise<void> {
    try { await appStore.respondApproval(eventId, decision); }
    catch (_) { this.actionError = '主机未确认审批，请刷新检查请求是否仍有效'; }
  }
  private async choose(kind: string, index: number): Promise<void> {
    this.actionError = '';
    try {
      if (kind === 'model') await appStore.selectModel(index);
      else if (kind === 'depth') await appStore.selectDepth(index);
      else await appStore.selectPermission(index);
    } catch (_) { this.actionError = '主机未接受设置，保留主机当前值'; }
  }
  private refreshHistory(): void {
    this.actionError = ''; this.followBottom = true;
    try { appStore.openChat(this.activeSession); } catch (_) { this.actionError = '请重新连接主机'; }
  }
  private async older(): Promise<void> {
    this.followBottom = false;
    try { await appStore.loadOlder(); } catch (_) { this.actionError = '读取更早消息失败，请稍后重试'; }
  }
  private expandedMessage(message: Message): boolean {
    return this.expanded.indexOf(message.id) >= 0 || (!this.foldCompleted && message.thinkText.length > 0);
  }

  private toggle(id: string): void {
    const at: number = this.expanded.indexOf(id);
    if (at >= 0) {
      this.expanded = this.expanded.filter((e: string) => e !== id);
    } else {
      this.expanded = this.expanded.concat([id]);
    }
  }

  private toast(text: string): void {
    this.getUIContext().getPromptAction().showToast({ message: text });
  }

  // Actual height of the title bar: status bar + title row + control row.
  private barBottom(): number {
    return this.topSafe + 56;
  }

  @Builder
  chatTitle() {
    Row({ space: GAP_NORMAL }) {
      GlassIconButton({
        icon: $r('sys.symbol.chevron_backward'),
        diameter: 40,
        inTitleBar: true,
        onTap: () => this.stack.pop()
      })
      Column({ space: 2 }) {
        Text(this.sessionTitle)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${this.sessionWorkspace} · ${this.sessionModel}`)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      GlassIconButton({
        icon: $r('sys.symbol.square_and_pencil'),
        diameter: 40,
        inTitleBar: true,
        onTap: () => { this.createChat(); }
      })
      GlassIconButton({
        icon: $r('sys.symbol.ellipsis_circle'),
        diameter: 40,
        inTitleBar: true,
        onTap: () => {
          this.getUIContext().getPromptAction().showActionMenu({ title: '对话操作', buttons: [{ text: '刷新历史', color: $r('sys.color.font_primary') }, { text: '回到最新', color: $r('sys.color.font_primary') }] })
            .then((result) => { if (result.index === 0) this.refreshHistory(); else { this.followBottom = true; this.messageScroller.scrollEdge(Edge.Bottom); } });
        }
      })
    }
    .width('100%')
    .height(this.barBottom())
    .padding({ left: MARGIN_EDGE, right: MARGIN_EDGE, top: this.topSafe })
  }

  @Builder
  smallAction(icon: Resource, label: string, content: string = '') {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolIcon({ icon: icon, color: $r('app.color.text_tertiary'), iconSize: 16 })
    }
    .width(32)
    .height(32)
    .backgroundColor(Color.Transparent)
    .enabled(label.indexOf('复制') >= 0)
    .accessibilityText(label.indexOf('复制') >= 0 ? label : label + '尚未接入')
    .onClick(() => { this.copy(content); })
  }

  @Builder
  userMessage(m: Message) {
    Column({ space: 4 }) {
      Text(m.text)
        .fontSize(this.chatFontSize)
        .lineHeight(22)
        .fontColor($r('app.color.on_bubble'))
        .constraintSize({ maxWidth: '82%' })
        .padding({ left: GAP_LARGE, right: GAP_LARGE, top: 12, bottom: 12 })
        .borderRadius(RADIUS_CARD)
        .backgroundColor($r('app.color.bubble_user'))
      Row() {
        this.smallAction($r('sys.symbol.rectangle_on_rectangle'), '复制', m.text)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
  }

  @Builder
  thinkingHeader(m: Message) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row({ space: 6 }) {
        SymbolIcon({ icon: $r('sys.symbol.lightbulb'), color: $r('app.color.text_tertiary'), iconSize: 14 })
        Text(`用时 ${m.thinkSecs} 秒`)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        SymbolIcon({
          icon: this.expandedMessage(m) ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'),
          color: $r('app.color.text_tertiary'),
          iconSize: 13
        })
      }
    }
    .height(28)
    .padding({ left: GAP_NORMAL, right: GAP_NORMAL })
    .borderRadius(RADIUS_CONTROL)
    .backgroundColor($r('app.color.surface_alt'))
    .onClick(() => this.toggle(m.id))
  }

  @Builder
  codeCard(m: Message) {
    Column() {
      Row() {
        Text(m.codeLang)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        Text('复制')
          .fontSize(11)
          .fontColor($r('app.color.accent'))
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 6 })

      Divider().color($r('app.color.divider'))

      Scroll() {
        Text(m.code)
          .fontSize(12)
          .fontFamily('monospace')
          .lineHeight(19)
          .fontColor($r('app.color.text_primary'))
          .padding(12)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .backgroundColor($r('app.color.code_bg'))
    .borderRadius(RADIUS_ICON)
    .border({ width: 1, color: $r('app.color.divider') })
  }

  @Builder
  toolCard(m: Message) {
    Row({ space: 10 }) {
      Stack() {
        SymbolIcon({
          icon: $r('sys.symbol.wrench_and_screwdriver'),
          color: $r('app.color.accent'),
          iconSize: 14
        })
      }
      .width(32)
      .height(32)
      .borderRadius(RADIUS_ICON)
      .backgroundColor($r('app.color.accent_soft'))

      Column({ space: 2 }) {
        Text(m.toolName)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(m.toolDetail)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(m.toolStatus)
        .fontSize(11)
        .fontColor($r('app.color.success'))
    }
    .width('100%')
    .padding(GAP_CARD)
    .borderRadius(RADIUS_ICON)
    .backgroundColor($r('app.color.surface_alt'))
  }

  @Builder
  assistantMessage(m: Message) {
    Column({ space: 12 }) {
      if (m.thinkSecs > 0) {
        Column({ space: 8 }) {
          this.thinkingHeader(m)
          if (this.expandedMessage(m) && m.thinkText.length > 0) {
            Text(m.thinkText)
              .fontSize(12)
              .lineHeight(19)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 12, right: 12, top: 4, bottom: 4 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      Text(m.text)
        .fontSize(this.chatFontSize)
        .lineHeight(24)
        .fontColor($r('app.color.text_primary'))
        .copyOption(CopyOptions.LocalDevice)

      if (m.code.length > 0) {
        this.codeCard(m)
      }
      if (m.toolName.length > 0) {
        this.toolCard(m)
      }

      Row({ space: 2 }) {
        this.smallAction($r('sys.symbol.rectangle_on_rectangle'), '复制', m.text)
        this.smallAction($r('sys.symbol.arrow_clockwise'), '重新生成')
        this.smallAction($r('sys.symbol.share'), '分享')
      }
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(RADIUS_CARD)
    .backgroundColor($r('app.color.surface'))
    .border({ width: 1, color: $r('app.color.divider') })
  }

  @Builder
  statusStrip() {
    if (this.sessionStatus === 'running') {
      Select([{ value: '停止生成' }])
        .value(this.statusText || '正在生成')
        .font({ size: 12 }).fontColor($r('sys.color.font_secondary'))
        .width('100%').height(40).systemMaterial(barMaterial()).menuSystemMaterial(floatingMaterial(3))
        .onSelect(() => { appStore.cancel().catch(() => { this.actionError = '停止请求未确认，请检查连接'; }); })
    }
    ForEach(this.pendingRequests.filter((request: NativeHostEvent): boolean => request.sessionId === this.activeSession), (request: NativeHostEvent) => {
      if (request.event === 'approval/request') {
        Column({ space: GAP_NORMAL }) {
          Text('等待授权 · ' + request.toolName).fontSize(14).fontWeight(FontWeight.Medium)
          Text(request.reason || '主机请求执行该操作').fontSize(13).width('100%')
          Row({ space: GAP_NORMAL }) {
            Button('拒绝').layoutWeight(1).onClick(() => { this.approve(request.eventId, 'rejected'); })
            Button('允许一次').layoutWeight(1).onClick(() => { this.approve(request.eventId, 'allowed-once'); })
          }.width('100%')
        }
        .padding(GAP_LARGE).width('100%').alignItems(HorizontalAlign.Start)
        .borderRadius(RADIUS_CARD).backgroundColor($r('app.color.surface'))
      } else if (request.event === 'user-questions/request') {
        HostQuestions({ request: request })
      }
    }, (request: NativeHostEvent) => request.eventId)
  }

  @Builder
  optionChip(label: string, items: string[], selected: number, pick: (i: number) => void) {
    // Select supports immersive material in the content area; a Button here does not.
    Select(items.map((item: string): SelectOption => ({ value: item })))
      .selected(selected)
      .value(label)
      .font({ size: 12 })
      .fontColor($r('sys.color.font_emphasize'))
      .width('100%')
      .height(36)
      .space(GAP_NORMAL)
      .padding({ left: GAP_CARD, right: GAP_NORMAL })
      .systemMaterial(barMaterial())
      .menuSystemMaterial(floatingMaterial(3))
      .enabled(items.length > 0 && this.connectionState === 'ready' && !this.selectionBusy)
      .onSelect((index: number) => pick(index))
  }

  @Builder
  inputBar() {
    Column({ space: GAP_NORMAL }) {
      // All three native Select controls remain visible, outside the editor outline.
      Row({ space: GAP_NORMAL }) {
        Column() {
          this.optionChip('模型', this.modelLabels, this.modelIdx, (i: number) => { this.choose('model', i); })
        }
        .layoutWeight(1)
        Column() {
          this.optionChip('思考深度', this.depthLabels, this.depthIdx, (i: number) => { this.choose('depth', i); })
        }
        .layoutWeight(1)
        Column() {
          this.optionChip('权限', this.permissionLabels, this.permIdx, (i: number) => { this.choose('permission', i); })
        }
        .layoutWeight(1)
      }
      .width('100%')

      this.statusStrip()

      // Keep every control on one horizontal centreline, including when the editor grows.
      Row({ space: GAP_NORMAL }) {
        Button({ type: ButtonType.Circle }) {
          SymbolIcon({ icon: $r('sys.symbol.plus'), color: $r('app.color.text_secondary'), iconSize: 24 })
        }
        .width(44)
        .height(44)
        .backgroundColor($r('app.color.surface_alt'))
        .accessibilityText('附件与输入选项')
        .bindMenu([
          { value: '附件上传尚未接入', action: () => this.toast('当前支持文字消息，附件上传尚未接入') },
          { value: this.composerExpanded ? '收起输入框' : '展开输入框', action: () => {
            this.composerExpanded = !this.composerExpanded;
          } }
        ], { systemMaterial: floatingMaterial(3) })

        TextArea({ text: this.input, placeholder: '输入消息…' })
          .layoutWeight(1)
          .height(this.composerExpanded ? 240 : undefined)
          .minLines(1)
          .lineHeight(24)
          .constraintSize({ minHeight: 44, maxHeight: this.composerExpanded ? 240 : 144 })
          .backgroundColor(Color.Transparent)
          .placeholderColor($r('app.color.text_tertiary'))
          .placeholderFont({ size: 15 })
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .padding({ left: 0, right: 0, top: 10, bottom: 10 })
          .onChange((value: string) => {
            this.input = value;
          })

        Button({ type: ButtonType.Circle }) {
          SymbolIcon({ icon: $r('sys.symbol.mic'), color: $r('app.color.text_secondary'), iconSize: 18 })
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .enabled(false)
        .accessibilityText('语音输入尚未接入')
        Button({ type: ButtonType.Circle }) {
          SymbolIcon({
            icon: $r('sys.symbol.paperplane'),
            color: this.input.trim().length > 0 ? $r('app.color.on_accent') : $r('app.color.text_tertiary'),
            iconSize: 22
          })
        }
        .width(44)
        .height(44)
        .backgroundColor(this.input.trim().length > 0 ? $r('app.color.accent') : $r('app.color.surface_alt'))
        .enabled(this.input.trim().length > 0 && !this.chatBusy && this.connectionState === 'ready' && !this.chatLoading)
        .accessibilityText('发送消息')
        .onClick(() => {
          this.send();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding(GAP_NORMAL)
      .borderRadius(RADIUS_SHEET)
      .backgroundColor($r('app.color.glass'))
      .border({ width: 1, color: $r('sys.color.comp_divider') })
    }
    .width('100%')
    .padding({ left: MARGIN_EDGE, right: MARGIN_EDGE, bottom: FLOATING_BOTTOM_MARGIN })
    .onAreaChange((_old: Area, area: Area) => {
      this.composerHeight = Number(area.height);
    })
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        Stack({ alignContent: Alignment.TopStart }) {
          List({ space: GAP_CARD, initialIndex: this.messages.length + 2, scroller: this.messageScroller }) {
            ListItem() {
              Row().width('100%').height(this.barBottom() + GAP_LARGE)
            }

            ListItem() {
              Column({ space: GAP_NORMAL }) {
                if (this.chatLoading) { LoadingProgress().width(28).height(28) }
                if (this.chatHasMore) { Button('加载更早消息').onClick(() => { this.older(); }) }
                if (this.chatError || this.actionError) {
                  Text(this.actionError || this.chatError).fontSize(13).fontColor($r('app.color.danger'))
                  Button('刷新历史').onClick(() => { this.refreshHistory(); })
                }
                if (!this.chatLoading && this.messages.length === 0 && !this.chatError) {
                  Text('还没有消息，发送第一条消息开始对话').fontSize(14).fontColor($r('app.color.text_secondary'))
                }
                if (this.catalogError) { Text(this.catalogError).fontSize(12).fontColor($r('app.color.warning')) }
              }.width('100%').padding(GAP_NORMAL)
            }

            ForEach(this.messages, (m: Message) => {
              ListItem() {
                if (m.role === 'user') {
                  this.userMessage(m)
                } else {
                  this.assistantMessage(m)
                }
              }
            }, (m: Message) => m.id)

            ListItem() {
              Row().width('100%').height(this.composerHeight + GAP_LARGE)
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: MARGIN_EDGE, right: MARGIN_EDGE })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .clip(false)
          .cachedCount(listCacheCount(), true)
          .maintainVisibleContentPosition(true)
          .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) this.followBottom = false; })
          .onScrollStop(() => { this.followBottom = this.messageScroller.isAtEnd(); })
          .onAreaChange((_old: Area, area: Area) => {
            this.viewportHeight = Number(area.height);
          })
          .linearGradientBlur(30, progressiveChatBlur(this.barBottom(), this.composerHeight, this.viewportHeight))


        }
        .width('100%')
        .height('100%')

        this.inputBar()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg'))
    }
    .title({ builder: this.chatTitle, height: this.barBottom() }, titleBarOptions())
    .hideBackButton(true)
    .backgroundColor($r('app.color.bg'))
    .onShown(() => {
      // Destination layout and composer measurement are ready. Align the trailing spacer
      // with the viewport end so the newest message sits above the floating composer.
      this.messageScroller.scrollEdge(Edge.Bottom);
    })
    .onBackPressed(() => {
      this.stack.pop();
      return true;
    })
  }
}
