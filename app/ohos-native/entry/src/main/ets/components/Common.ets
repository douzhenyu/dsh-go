import {
  GAP_NORMAL, IMMERSIVE, RADIUS_CONTROL, RADIUS_ICON, RADIUS_TAG, barMaterial, buttonMaterial, fallbackBlur,
  floatingMaterial
} from '../common/Style';
import { SymbolIcon } from './Symbols';

const ACCENT_MATERIAL: ResourceColor = $r('app.color.accent_material');

// A floating surface. With the system immersive material it is the material that draws the
// background, border and shadow; without it the same thickness of BlurStyle stands in.
@Component
export struct GlassSurface {
  @BuilderParam content: () => void = this.placeholder;
  radius: number = RADIUS_CONTROL;
  // 0 ULTRA_THIN, 1 THIN, 2 REGULAR, 3 THICK, 4 ULTRA_THICK
  level: number = 1;
  accent: boolean = false;
  fullWidth: boolean = false;
  // Only inside a Navigation/NavDestination title bar does the system draw the material.
  inTitleBar: boolean = false;

  @Builder
  placeholder() {
  }

  build() {
    if (IMMERSIVE && this.inTitleBar) {
      // The material draws background, border and shadow itself; setting them as well
      // would override it.
      Column() {
        this.content()
      }
      .constraintSize({ minWidth: this.fullWidth ? '100%' : 0 })
      .borderRadius(this.radius)
      .systemMaterial(floatingMaterial(this.level, this.accent ? ACCENT_MATERIAL : undefined))
    } else {
      Column() {
        this.content()
      }
      .constraintSize({ minWidth: this.fullWidth ? '100%' : 0 })
      .borderRadius(this.radius)
      .backgroundColor(this.accent ? $r('app.color.accent') : $r('app.color.glass'))
      .backgroundBlurStyle(this.accent ? BlurStyle.NONE : fallbackBlur(this.level))
      .border({ width: 1, color: this.accent ? '#00000000' : $r('app.color.divider') })
    }
  }
}

@Component
export struct GlassIconButton {
  icon: Resource = $r('sys.symbol.plus');
  tint: ResourceColor = $r('app.color.text_primary');
  iconSize: number = 20;
  diameter: number = 40;
  filled: boolean = false;
  inTitleBar: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    if (IMMERSIVE && this.inTitleBar) {
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolIcon({ icon: this.icon, color: this.tint, iconSize: this.iconSize })
      }
      .width(this.diameter)
      .height(this.diameter)
      .systemMaterial(this.filled ? floatingMaterial(1, ACCENT_MATERIAL) : buttonMaterial())
      .onClick(() => this.onTap())
    } else {
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolIcon({ icon: this.icon, color: this.tint, iconSize: this.iconSize })
      }
      .width(this.diameter)
      .height(this.diameter)
      .backgroundColor(this.filled ? $r('app.color.accent') : $r('app.color.glass'))
      .backgroundBlurStyle(this.filled ? BlurStyle.NONE : fallbackBlur(1))
      .border({ width: 1, color: this.filled ? '#00000000' : $r('app.color.divider') })
      .shadow(this.filled ? { radius: 20, color: $r('app.color.accent_shadow'), offsetY: 6 } : { radius: 0 })
      .onClick(() => this.onTap())
    }
  }
}

// Status dot: running breathes, the rest are still. 'idle' draws nothing.
@Component
export struct StatusDot {
  kind: string = 'idle';
  diameter: number = 8;
  @State pulse: number = 1;

  private color(): ResourceColor {
    if (this.kind === 'running') {
      return $r('app.color.accent');
    } else if (this.kind === 'pending') {
      return $r('app.color.warning');
    } else if (this.kind === 'failed') {
      return $r('app.color.danger');
    }
    return $r('app.color.success');
  }

  build() {
    if (this.kind !== 'idle') {
      Circle()
        .width(this.diameter)
        .height(this.diameter)
        .fill(this.color())
        .opacity(this.pulse)
        .animation({ duration: AppStorage.get<boolean>('animationsEnabled') === false ? 0 : 900, iterations: -1, curve: Curve.EaseInOut, playMode: PlayMode.Alternate })
        .onAppear(() => {
          if (this.kind === 'running') {
            this.pulse = 0.3;
          }
        })
    }
  }
}

// 标签、角标: 4vp.
@Component
export struct Tag {
  label: string = '';
  accent: boolean = false;

  build() {
    Text(this.label)
      .fontSize(11)
      .fontColor(this.accent ? $r('app.color.accent') : $r('app.color.text_secondary'))
      .padding({ left: GAP_NORMAL, right: GAP_NORMAL, top: 3, bottom: 3 })
      .borderRadius(RADIUS_TAG)
      .backgroundColor(this.accent ? $r('app.color.accent_soft') : $r('app.color.surface_alt'))
  }
}

// 图标: 8vp. The first character of a title on a tinted tile.
@Component
export struct InitialTile {
  label: string = '';
  tileSize: number = 48;

  build() {
    Stack() {
      Text(this.label.length > 0 ? this.label.substring(0, 1) : '·')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
    }
    .width(this.tileSize)
    .height(this.tileSize)
    .borderRadius(RADIUS_ICON)
    .backgroundColor($r('app.color.accent_soft'))
  }
}
