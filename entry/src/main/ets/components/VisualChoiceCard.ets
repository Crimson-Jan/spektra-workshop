@Component
export struct VisualChoiceCard {
  @Prop label: string = '';
  @Prop detail: string = '';
  @Prop accessibleLabel: string = '';
  @Prop artPath: string = '';
  @Prop isFrame: boolean = false;
  @Prop ratio: number = 0;
  @Prop borderPreview: string | undefined = undefined;
  @Prop compact: boolean = false;
  @Prop selected: boolean = false;
  onSelect: () => void = () => {};

  @Builder
  frameDiagram() {
    Row()
      .width(Math.min(this.compact ? 66 : 42, 32 * (this.ratio || 1.5)))
      .height(Math.min(32, (this.compact ? 66 : 42) / (this.ratio || 1.5)))
      .backgroundColor(this.ratio > 0 ? (this.selected ? '#493925' : '#312922') : Color.Transparent)
      .border({
        width: 1,
        color: this.selected ? '#E0B568' : '#B3A28B',
        style: this.ratio > 0 ? BorderStyle.Solid : BorderStyle.Dashed
      })
  }

  @Builder
  perforations() {
    Row() {
      ForEach([0, 1, 2, 3, 4, 5], (hole: number) => {
        Row()
          .width(4)
          .height(2.5)
          .backgroundColor('#EAE0D1')
          .borderRadius(0.5)
      }, (hole: number) => hole.toString())
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
  }

  @Builder
  borderDiagram() {
    if (this.borderPreview === '35mm') {
      Column({ space: 3 }) {
        this.perforations()
        Row().width('100%').height(16).backgroundColor('#FFFDF8')
        this.perforations()
      }
      .width(48)
      .height(32)
      .padding({ left: 4, right: 4 })
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#161310')
      .border({ width: 1, color: '#9F927E' })
      .borderRadius(2)
    } else {
      Stack() {
        if (this.borderPreview !== '') {
          Row()
            .width(32)
            .height(20)
            .backgroundColor('#BEB4A4')
            .border({
              width: this.borderPreview === 'keyline' ? 2.5 : 0.75,
              color: this.borderPreview === 'keyline' ? '#161310' : '#8C8171'
            })
        }
      }
      .width(48)
      .height(32)
      .backgroundColor(this.borderPreview === '' ? '#BEB4A4' : '#F4EEE3')
      .border({ width: 1, color: '#9F927E' })
      .borderRadius(2)
    }
  }

  private isDiagram(): boolean {
    return this.isFrame || this.borderPreview !== undefined;
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Column() {
        Stack() {
          if (this.borderPreview !== undefined) {
            this.borderDiagram()
          } else if (this.isFrame) {
            this.frameDiagram()
          } else if (this.artPath.length > 0) {
            Image($rawfile(this.artPath))
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Contain)
              .draggable(false)
          }
        }
        .width('100%')
        .height(this.borderPreview !== undefined ? 48 : (this.isFrame ? 42 : (this.compact ? 76 : 52)))
        .padding({ top: 4 })

        Divider()
          .color(this.selected ? '#624B30' : '#3A322A')
          .width('100%')

        Column({ space: 1 }) {
          Text(this.label)
            .width('100%')
            .fontSize(this.isDiagram() || !this.compact ? 11 : 12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.selected ? '#F7E7CA' : '#EAE0D1')
            .textAlign(this.isDiagram() ? TextAlign.Center : TextAlign.Start)
            .maxLines(this.isDiagram() ? 1 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.borderPreview === undefined) {
            Text(this.detail)
              .width('100%')
              .fontSize(this.isFrame || !this.compact ? 9 : 10)
              .fontColor('#B6A896')
              .textAlign(this.isFrame ? TextAlign.Center : TextAlign.Start)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .height(this.borderPreview !== undefined ? 27 : (this.isFrame ? 32 : 44))
        .padding({
          left: this.isFrame ? 2 : (this.compact ? 7 : 3),
          right: this.isFrame ? 2 : (this.compact ? 7 : 3)
        })
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
    }
    .width('100%')
    .padding(0)
    .backgroundColor(this.selected ? '#32271B' : '#211D19')
    .borderRadius(9)
    .border({ width: 1, color: this.selected ? '#CD9F5C' : '#3D342B' })
    .clip(true)
    .accessibilityText(this.selected ? this.accessibleLabel + '，已选中' : this.accessibleLabel)
    .onClick(() => { this.onSelect(); })
  }
}
