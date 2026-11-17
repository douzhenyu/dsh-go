import UIAbility from '@ohos.app.ability.UIAbility';
import Configuration from '@ohos.app.ability.Configuration';
import window from '@ohos.window';
import resourceManager from '@ohos.resourceManager';
import { BusinessError } from '@ohos.base';
import { remoteConnectionManager } from '../state/RemoteConnectionManager';

// Immersive window: the page draws edge to edge, both system bars are transparent,
// and the gesture indicator is hidden. Page roots add their own safe-area padding
// from getWindowAvoidArea so content never sits under a bar.
export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | undefined = undefined;


  private isDark(): boolean {
    try {
      return this.context.resourceManager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK;
    } catch (e) {
      return true;
    }
  }

  private applySystemBars(): void {
    if (this.mainWindow === undefined) {
      return;
    }
    const dark: boolean = this.isDark();
    this.mainWindow.setWindowSystemBarProperties({
      statusBarColor: '#00000000',
      statusBarContentColor: dark ? '#FFFFFF' : '#000000',
      navigationBarColor: '#00000000',
      navigationBarContentColor: dark ? '#FFFFFF' : '#000000'
    }).catch(() => {
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        console.error(`Failed to load the content. Code: ${err.code}, message: ${err.message}`);
        return;
      }
      windowStage.getMainWindow().then((win: window.Window) => {
        this.mainWindow = win;
        // Edge to edge: the page background (and the blurred top bar) runs behind the
        // status bar again.
        win.setWindowLayoutFullScreen(true).catch(() => {
        });
        this.applySystemBars();
        win.on('avoidAreaChange', () => {
          this.applySystemBars();
        });
      }).catch(() => {
      });
    });
  }

  onForeground(): void {
    remoteConnectionManager.resume();
  }

  onConfigurationUpdated(config: Configuration): void {
    this.applySystemBars();
  }
}
