@Component
export struct SymbolIcon {
  icon: Resource = $r('sys.symbol.line_3_horizontal');
  color: ResourceColor = $r('app.color.text_primary');
  iconSize: number = 20;
  weight: number = 500;

  build() {
    SymbolGlyph(this.icon)
      .fontSize(this.iconSize)
      .fontColor([this.color])
      .fontWeight(this.weight)
  }
}
