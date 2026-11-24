@Component
export struct PreviewActivity {
  @State private sweepX: number = -16;

  build() {
    Row({ space: 8 }) {
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width(16)
          .height(2)
          .linearGradient({ angle: 90, colors: [['#33DEAE68', 0], ['#E2B471', 0.65], ['#33DEAE68', 1]] })
          .translate({ x: this.sweepX })
          .onAppear(() => {
            this.getUIContext().animateTo({ duration: 1350, iterations: -1, curve: Curve.Linear }, () => {
              this.sweepX = 38;
            });
          })
      }
      .width(38)
      .height(2)
      .backgroundColor('#4C3B28')
      .borderRadius(1)
      .clip(true)
      .accessibilityLevel('no')

      Text('正在显影')
        .fontSize(11)
        .fontColor('#E6D2AF')
    }
    .padding({ left: 10, right: 11, top: 7, bottom: 7 })
    .backgroundColor('#EC191510')
    .border({ width: 1, color: '#493827' })
    .borderRadius(6)
    .accessibilityGroup(true)
    .hitTestBehavior(HitTestMode.None)
  }
}
