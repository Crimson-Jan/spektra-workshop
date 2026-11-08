/**
 * About / attribution.
 *
 * Not decoration: this app ships GPL-3.0 code and CC BY-SA 4.0 data, and both
 * licences oblige us to credit the authors, name the licences, point at the
 * source, and state that the files were modified. AppGallery review and the
 * upstream community will both look for this page.
 */

import { router } from '@kit.ArkUI';

interface CreditRow {
  title: string;
  body: string;
}

const CREDITS: CreditRow[] = [
  {
    title: 'spektrafilm — 光谱模型与胶片数据',
    body: 'Andrea Volpato 与贡献者。每款胶片的叶层灵敏度和相纸数据都来自这个项目。\n' +
      '代码 GPL-3.0 · 数据 CC BY-SA 4.0\n' +
      'github.com/andreavolpato/spektrafilm'
  },
  {
    title: 'negs — Rust 引擎与移植基础',
    body: 'Noah Haasis。本应用的引擎层是 negs 的 Rust 实现，仅移除 BLAS、GPU 与 macOS RAW 桥。\n' +
      'GPL-3.0-only\n' +
      'github.com/noahhaasis/negs'
  },
  {
    title: '本移植 — HarmonyOS 适配',
    body: '针对鸿蒙的交叉编译、NAPI 桥接与 ArkUI 界面由本项目作者完成。\n' +
      '代码按 GPL-3.0-only 发布，完整源码随应用一同提供。\n' +
      '引擎改动点见项目 README 的「相对上游的改动」一节。'
  }
];

@Entry
@Component
struct About {
  build() {
    Column() {
      Row({ space: 12 }) {
        Text('‹').fontSize(26).fontColor('#C9BDA6').width(28)
          .onClick(() => {
            router.back();
          })
        Text('关于 Spektrafilm').fontSize(18).fontColor('#F3EFE7').fontWeight(FontWeight.Medium)
        Blank()
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 14, bottom: 14 })

      Divider().color('#241F19')

      Scroll() {
        Column({ space: 18 }) {
          Column({ space: 6 }) {
            Text('Spektrafilm').fontSize(22).fontColor('#F3EFE7').fontWeight(FontWeight.Bold)
            Text('光谱胶片仿真 · HarmonyOS').fontSize(12).fontColor('#8C8578')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // --- licences ---------------------------------------------------
          ForEach(CREDITS, (row: CreditRow) => {
            Column({ space: 6 }) {
              Text(row.title).fontSize(13).fontColor('#E6D9C2').fontWeight(FontWeight.Medium)
              Text(row.body)
                .fontSize(11)
                .fontColor('#A79E8E')
                .lineHeight(18)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(14)
            .backgroundColor('#12100D')
            .borderRadius(8)
          }, (row: CreditRow) => row.title)

          // --- privacy ----------------------------------------------------
          Column({ space: 6 }) {
            Text('隐私').fontSize(13).fontColor('#E6D9C2').fontWeight(FontWeight.Medium)
            Text(
              '全部计算在本机完成。应用不联网、不上传照片、不含统计或广告 SDK，' +
              '也不需要任何隐私权限：选图与保存都经由系统提供的选择器，' +
              '应用只能看到你明确选中的那个文件。'
            )
              .fontSize(11)
              .fontColor('#A79E8E')
              .lineHeight(18)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .backgroundColor('#12100D')
          .borderRadius(8)

          // --- source -----------------------------------------------------
          Column({ space: 6 }) {
            Text('源码').fontSize(13).fontColor('#E6D9C2').fontWeight(FontWeight.Medium)
            Text(
              '按 GPL-3.0 要求，本项目完整源码公开。若你收到本应用的二进制包，' +
              '可向分发者索取对应源码，或从下列上游项目获取基础实现。'
            )
              .fontSize(11)
              .fontColor('#A79E8E')
              .lineHeight(18)
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(14)
          .backgroundColor('#12100D')
          .borderRadius(8)

          Text('spektrafilm © Andrea Volpato · negs © Noah Haasis · this port, GPL-3.0-only')
            .fontSize(9)
            .fontColor('#4A453C')
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 4, bottom: 24 })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 18 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B0A08')
  }
}
