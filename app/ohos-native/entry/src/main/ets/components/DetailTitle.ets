import { GlassIconButton } from './Common';
import { MARGIN_EDGE } from '../common/Style';

// A detail-page title that participates in the app's edge-to-edge layout.
// The default NavDestination mini title does not reserve the status bar in this shell.
@Component
export struct DetailTitle {
  stack: NavPathStack = new NavPathStack();
  title: string = '';
  onBack?: () => void;
  @StorageLink('topSafe') topSafe: number = 28;

  build() {
    Row() {
      GlassIconButton({ icon: $r('sys.symbol.chevron_left'), diameter: 40, inTitleBar: true,
        onTap: () => { if (this.onBack) this.onBack(); else this.stack.pop(); } })
      Text(this.title).fontSize(20).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        .textAlign(TextAlign.Center).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row().width(40).height(40)
    }
    .width('100%').height(this.topSafe + 64).padding({ top: this.topSafe, left: 12, right: MARGIN_EDGE })
  }
}
