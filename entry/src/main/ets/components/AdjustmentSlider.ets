@Component
export struct AdjustmentSlider {
  @Link @Watch('syncDisplay') value: number;
  @Prop label: string = '';
  @Prop min: number = -1;
  @Prop max: number = 1;
  @Prop step: number = 0.05;
  @Prop decimals: number = 2;
  @Prop displayScale: number = 1;
  @Prop unit: string = '';
  @Prop signed: boolean = false;
  @Prop inline: boolean = false;
  @Prop labelWidth: number = 62;
  @Prop inset: number = 0;
  @Prop automatic: boolean = false;
  @Prop hint: string = '';
  @Prop rampStart: string = '';
  @Prop rampEnd: string = '';
  onReset?: () => void;
  onCommit?: () => void;

  @State private displayValue: number = 0;
  @State private interacting: boolean = false;

  aboutToAppear(): void {
    this.syncDisplay();
  }

  private syncDisplay(): void {
    this.interacting = false;
    this.displayValue = Math.min(this.max, Math.max(this.min, this.value));
  }

  private change(next: number, mode: SliderChangeMode): void {
    if (mode === SliderChangeMode.Begin) {
      this.interacting = true;
      return;
    }
    if (mode === SliderChangeMode.Moving || (mode === SliderChangeMode.Click && this.interacting)) {
      this.displayValue = next;
      return;
    }

    // Native touch and keyboard gestures end here. Ignore unsolicited End
    // notifications when ArkUI corrects an out-of-range programmatic value.
    const commit = this.interacting || mode === SliderChangeMode.Click;
    this.interacting = false;
    if (!commit || Math.abs(next - this.value) < 0.000001) {
      this.syncDisplay();
      return;
    }
    this.displayValue = next;
    this.value = next;
    this.onCommit?.();
  }

  private readout(): string {
    if (this.automatic && !this.interacting) {
      return '自动';
    }
    const display = (this.interacting ? this.displayValue : this.value) * this.displayScale;
    const sign = this.signed && display > 0 ? '+' : '';
    return `${sign}${display.toFixed(this.decimals)}${this.unit}`;
  }

  @Builder
  caption() {
    Row({ space: 5 }) {
      Text(this.label)
        .fontSize(11)
        .fontColor('#CEC1AA')
        .maxLines(1)

      if (this.hint.length > 0) {
        Text(this.hint).fontSize(9).fontColor('#9A8D79')
      }

      if (this.onReset !== undefined) {
        Text('自动')
          .fontSize(10)
          .fontColor(this.automatic ? '#E0B66C' : '#B8A98F')
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(4)
          .backgroundColor(this.automatic ? '#3A2D20' : '#241E19')
          .onClick(() => { this.onReset?.(); })
      }
    }
    .width(this.inline ? this.labelWidth : 'auto')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  valueBadge() {
    Text(this.readout())
      .fontSize(11)
      .fontFamily('monospace')
      .fontWeight(FontWeight.Medium)
      .fontColor(this.interacting ? '#F7D89E' : '#EEE3CF')
      .textAlign(TextAlign.Center)
      .maxLines(1)
      .height(22)
      .width(this.unit.length > 0 ? 59 : 45)
      .backgroundColor(this.interacting ? '#392D20' : '#211C17')
      .border({ width: 1, color: this.interacting ? '#876238' : '#3A3027' })
      .borderRadius(5)
  }

  @Builder
  track() {
    Slider({ value: $$this.displayValue, min: this.min, max: this.max, step: this.step, style: SliderStyle.OutSet })
      .width('100%')
      .height(this.inline ? 40 : 32)
      .trackThickness(3)
      .trackBorderRadius(1.5)
      .trackColor(this.rampStart.length > 0
        ? new LinearGradient([{ color: this.rampStart, offset: 0 }, { color: this.rampEnd, offset: 1 }])
        : '#44382C')
      .selectedColor(this.rampStart.length > 0 ? Color.Transparent : '#C39A59')
      .blockSize({ width: 13, height: 13 })
      .blockColor(this.interacting ? '#F7D396' : '#EFE4D0')
      .blockBorderWidth(1)
      .blockBorderColor('#6E4E31')
      .sliderInteractionMode(SliderInteraction.SLIDE_AND_CLICK_UP)
      .accessibilityText(this.label)
      .onChange((next: number, mode: SliderChangeMode) => { this.change(next, mode); })
  }

  build() {
    if (this.inline) {
      Row({ space: 6 }) {
        this.caption()
        Column() {
          this.track()
        }
        .layoutWeight(1)
        this.valueBadge()
      }
      .width('100%')
      .padding({ left: this.inset, right: this.inset })
    } else {
      Column() {
        Row() {
          this.caption()
          Blank()
          this.valueBadge()
        }
        .width('100%')

        this.track()
      }
      .width('100%')
      .padding({ left: this.inset, right: this.inset })
    }
  }
}
