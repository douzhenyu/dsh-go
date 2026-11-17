import { LengthMetrics, SymbolGlyphModifier, uiMaterial } from '@kit.ArkUI';

// HarmonyOS visual tokens. Values come from the official design pages (phone column):
//   圆角参数  developer.huawei.com/consumer/cn/doc/doccenter-ux-design/corner-radius-parameter-0000002556468705
//   间隔参数  developer.huawei.com/consumer/cn/doc/doccenter-ux-design/interval-parameter-0000002562577161
//   沉浸光感  developer.huawei.com/consumer/cn/doc/doccenter-ux-design/immersivelight-0000002612101053
// Same layer, same radius; a higher layer gets a larger radius.

// Corner radius (vp)
export const RADIUS_TAG: number = 4;       // 标签、角标
export const RADIUS_ICON: number = 8;      // 图片、图标、列表内模块
export const RADIUS_CARD: number = 16;     // 通知卡片、普通卡片、内容容器
export const RADIUS_CONTROL: number = 20;  // 按钮、菜单、选项卡
export const RADIUS_SHEET: number = 32;    // 半模态、弹出框

// Spacing (vp)
export const MARGIN_EDGE: number = 16;     // 屏幕左右边距（手机）
export const MARGIN_TOP: number = 36;      // 屏幕顶部边距（手机）
export const MARGIN_BOTTOM: number = 28;   // 屏幕底部边距（手机）
export const FLOATING_BOTTOM_MARGIN: number = 18; // Floating TabBar and chat composer share a bottom edge.
export const GAP_CARD: number = 12;        // 卡片之间
export const GAP_LARGE: number = 16;       // 控件之间，有明显边界
export const GAP_NORMAL: number = 8;       // 控件之间，无明显边界
export const GAP_TEXT_V: number = 2;       // 主次文本上下
export const GAP_TEXT_H: number = 8;       // 主次文本左右

// Immersive light. The material is a system feature: the device decides whether it exists.
// When it is not supported, `systemMaterial` has no effect, so callers fall back to the
// BlurStyle of the same thickness (the same five levels).
export function immersiveSupported(): boolean {
  try {
    return uiMaterial.isImmersiveMaterialSupported();
  } catch (e) {
    return false;
  }
}

export const IMMERSIVE: boolean = immersiveSupported();

// 0 ULTRA_THIN, 1 THIN, 2 REGULAR, 3 THICK, 4 ULTRA_THICK
export function immersiveStyle(level: number): uiMaterial.ImmersiveStyle {
  if (level <= 0) {
    return uiMaterial.ImmersiveStyle.ULTRA_THIN;
  } else if (level === 1) {
    return uiMaterial.ImmersiveStyle.THIN;
  } else if (level === 2) {
    return uiMaterial.ImmersiveStyle.REGULAR;
  } else if (level === 3) {
    return uiMaterial.ImmersiveStyle.THICK;
  }
  return uiMaterial.ImmersiveStyle.ULTRA_THICK;
}

export function fallbackBlur(level: number): BlurStyle {
  if (level <= 0) {
    return BlurStyle.COMPONENT_ULTRA_THIN;
  } else if (level === 1) {
    return BlurStyle.COMPONENT_THIN;
  } else if (level === 2) {
    return BlurStyle.COMPONENT_REGULAR;
  } else if (level === 3) {
    return BlurStyle.COMPONENT_THICK;
  }
  return BlurStyle.COMPONENT_ULTRA_THICK;
}

// Title-bar buttons share the neutral material with the segment track and Select.
export function buttonMaterial(): uiMaterial.ImmersiveMaterial {
  return barMaterial();
}

// Mirrors the Select's documented defaults (ULTRA_THIN + interactive + light feedback) so
// the segment control and the round buttons render with exactly the same material.
export function animationsEnabled(): boolean { return AppStorage.get<boolean>('animationsEnabled') !== false; }
export function listCacheCount(): number { return AppStorage.get<number>('listCacheCount') ?? 3; }

export function barMaterial(): uiMaterial.ImmersiveMaterial {
  // One material for every control in the bar. Color.Transparent is deliberate: with no
  // colour each component adds its own default tint (that is what made the segment look
  // whiter than the select), while a transparent colour keeps them all the same glass.
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
    materialColor: Color.Transparent,
    interactive: animationsEnabled(),
    lightEffect: { color: Color.White }
  });
}

// `interactive` is the press deformation, `lightEffect` the light-sensing feedback.
export function floatingMaterial(level: number, tint?: ResourceColor): uiMaterial.ImmersiveMaterial {
  return new uiMaterial.ImmersiveMaterial({
    style: immersiveStyle(level),
    materialColor: tint,
    interactive: true,
    lightEffect: { color: Color.White }
  });
}

// Apply to the scroll viewport, never to the title controls. The blur radius fades to zero
// across the lower edge of the title bar; no coloured layer covers the page content.
export function progressiveTopBlur(headerHeight: number, viewportHeight: number): LinearGradientBlurOptions {
  const height: number = Math.max(viewportHeight, headerHeight + 32);
  return {
    direction: GradientDirection.Bottom,
    fractionStops: AppStorage.get<boolean>('blurEnabled') === false ? [[0, 0], [0, 1]] : [
      [1, 0],
      [1, Math.max(0.001, (headerHeight - 32) / height)],
      [0.5, (headerHeight - 8) / height],
      [0, (headerHeight + 16) / height],
      [0, 1]
    ]
  };
}

// The message viewport stays clear in the middle and progressively blurs underneath both
// floating regions. Measure the composer because its height changes with status and editing.
export function progressiveChatBlur(headerHeight: number, composerHeight: number,
  viewportHeight: number): LinearGradientBlurOptions {
  const height: number = Math.max(1, viewportHeight);
  const topEnd: number = Math.min(0.4, (headerHeight + 16) / height);
  const topHold: number = Math.max(0.001, Math.min(topEnd - 0.001, (headerHeight - 32) / height));
  const bottomStart: number = Math.min(0.97, Math.max(topEnd + 0.01, 1 - (composerHeight + 16) / height));
  const bottomFull: number = Math.min(0.999, Math.max(bottomStart + 0.001, 1 - (composerHeight - 32) / height));
  return {
    direction: GradientDirection.Bottom,
    fractionStops: AppStorage.get<boolean>('blurEnabled') === false ? [[0, 0], [0, 1]] : [
      [1, 0], [1, topHold], [0, topEnd],
      [0, bottomStart], [0.5, (bottomStart + bottomFull) / 2], [1, bottomFull], [1, 1]
    ]
  };
}

// Keep the Navigation title bar transparent. Controls use system materials in this supported
// region; progressiveTopBlur is applied separately to the scrolling content underneath.
export function titleBarOptions(): NavigationTitleOptions {
  return {
    // Native back/menu controls use the system title material; custom controls have their
    // own material. No opaque title background or content-covering mask is added.
    systemMaterial: IMMERSIVE ? new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN
    }) : undefined,
    backgroundColor: Color.Transparent,
    barStyle: BarStyle.STACK
  };
}

export function menuItem(icon: Resource, label: string, action: () => void): NavigationMenuItem {
  return { value: label, symbolIcon: new SymbolGlyphModifier(icon), action: action };
}
