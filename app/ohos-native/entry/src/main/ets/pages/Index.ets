import common from '@ohos.app.ability.common';
import display from '@ohos.display';
import window from '@ohos.window';
import { SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';
import { ChatPage } from './ChatPage';
import { appStore } from '../state/AppStore';
import { ConversationsTab } from './ConversationsTab';
import { HostTab } from './HostTab';
import { RemoteConnection } from './RemoteConnection';
import { SettingsTab } from './SettingsTab';
import { LocalSettingsPage } from './LocalSettingsPage';
import { HostSettingsPage } from './HostSettingsPage';
import { nativeLocalSettings } from '../state/NativeLocalSettings';
import { remoteConnectionManager } from '../state/RemoteConnectionManager';
import { FLOATING_BOTTOM_MARGIN, GAP_LARGE, IMMERSIVE, MARGIN_EDGE } from '../common/Style';

function tabIcon(normal: Resource, selected: Resource): TabBarSymbol {
  return {
    normal: new SymbolGlyphModifier(normal).fontColor([$r('app.color.text_tertiary')]),
    selected: new SymbolGlyphModifier(selected).fontColor([$r('app.color.accent')])
  };
}

@Entry
@Component
struct Index {
  @State stack: NavPathStack = new NavPathStack();
  @StorageLink('selectedTab') tab: number = 1;
  @StorageLink('bottomSafe') bottomSafe: number = 0;

  aboutToAppear(): void {
    this.readSafeArea();
    const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    appStore.initialize(context).then(async (): Promise<void> => {
      await nativeLocalSettings.initialize(context);
      await remoteConnectionManager.initialize(context);
    }).catch(() => {});
  }

  private readSafeArea(): void {
    window.getLastWindow(getContext(this) as common.UIAbilityContext).then((win: window.Window) => {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate('topSafe', sys.topRect.height / density);
      AppStorage.setOrCreate('bottomSafe', nav.bottomRect.height / density);
    }).catch(() => {
    });
  }

  @Builder
  destination(name: string, param: ESObject) {
    if (name === 'chat') {
      ChatPage({ stack: this.stack })
    } else if (name === 'remote') {
      RemoteConnection({ stack: this.stack })
    } else if (name === 'settings') {
      LocalSettingsPage({ stack: this.stack, page: param as string })
    } else if (name === 'host-settings') {
      HostSettingsPage({ stack: this.stack, page: param as string })
    }
  }

  build() {
    Navigation(this.stack) {
      // Official floating TabBar with THIN immersive material; leave the content visible.
      Tabs({ barPosition: BarPosition.End, index: this.tab }) {
        TabContent() {
          HostTab({ stack: this.stack })
        }
        .tabBar(new BottomTabBarStyle(tabIcon($r('sys.symbol.desktop'), $r('sys.symbol.desktop_fill')), '主机'))

        TabContent() {
          ConversationsTab({ stack: this.stack })
        }
        .tabBar(new BottomTabBarStyle(tabIcon($r('sys.symbol.message'), $r('sys.symbol.message_fill')), '对话'))

        TabContent() {
          SettingsTab({ stack: this.stack })
        }
        .tabBar(new BottomTabBarStyle(tabIcon($r('sys.symbol.gearshape'), $r('sys.symbol.gearshape_fill')), '设置'))
      }
      .barMode(BarMode.Fixed)
      .scrollable(false)
      .barOverlap(true)
      .barFloatingStyle({
        barSideMargin: MARGIN_EDGE * 2,
        // Sit just above the gesture bar: the window is edge to edge now.
        barBottomMargin: FLOATING_BOTTOM_MARGIN,
        maskColor: Color.Transparent,
        maskHeight: 0,
        systemMaterial: IMMERSIVE
          ? new uiMaterial.ImmersiveMaterial({
            style: uiMaterial.ImmersiveStyle.THIN,
            interactive: true,
            lightEffect: { color: Color.White }
          })
          : undefined
      })
      .onChange((index: number) => {
        this.tab = index;
      })
      .width('100%')
      .height('100%')
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .navDestination(this.destination)
    .backgroundColor($r('app.color.bg'))
    .width('100%')
    .height('100%')
  }
}
