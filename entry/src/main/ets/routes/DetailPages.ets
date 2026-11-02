/**
 * routes/DetailPages.ets —— 第一阶段详情页骨架
 *
 * 目的：**只证明路由链路通**（参数传得过来、返回能回），不实现真实内容。
 * 真实详情页（发射详情五件套、看图器、火箭详情）留到下一轮，避免一次改太多。
 *
 * 为什么用全局 @Builder 而不是 @Component：
 *   NavPathStack 的 navDestination 需要「按 name 分发」的 builder，
 *   ArkUI 的约定就是 `@Builder PageMap(name: string, param: object)`。
 *   用 @Component 会多一层嵌套，且拿不到分发处的统一签名。
 *
 * ⚠ 这些 @Builder 里**不能有 @State**（@Builder 不是组件，没有自己的状态）。
 *   它们是纯展示，数据全部来自入参。要交互就调全局 Nav 门面。
 */

import { Nav } from './Nav';
import { LaunchNavParam, PhotoNavParam, RocketNavParam } from './NavParam';

const BG: string = '#0A0E17';
const CARD: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const ACCENT: string = '#38BDF8';

/** 通用页头：返回按钮 + 标题。三个骨架页共用，避免重复 */
@Builder
function detailHeader(title: string) {
  Row() {
    Text('‹')
      .fontSize(26)
      .fontColor(ACCENT)
      .fontWeight(FontWeight.Medium)
      .width(28)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        Nav.pop();
      })

    Text(title)
      .fontSize(17)
      .fontWeight(FontWeight.Bold)
      .fontColor(TEXT_MAIN)
      .margin({ left: 8 })

    Blank()
  }
  .width('100%')
  .height(48)
  .padding({ left: 8, right: 16 })
  .alignItems(VerticalAlign.Center)
}

/** 骨架页共用的一行「参数已收到」 */
@Builder
function paramRow(label: string, value: string) {
  Row() {
    Text(label)
      .fontSize(12)
      .fontColor(TEXT_SUB)
      .width(64)

    Text(value.length > 0 ? value : '（空）')
      .fontSize(13)
      .fontColor(TEXT_MAIN)
      .layoutWeight(1)
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
  }
  .width('100%')
  .padding({ top: 8, bottom: 8 })
  .alignItems(VerticalAlign.Top)
}

/** 发射详情页骨架 */
@Builder
export function LaunchDetailPage(name: string, param: LaunchNavParam) {
  NavDestination() {
    Column() {
      detailHeader('发射详情')

      Column() {
        paramRow('id', param.id)
        paramRow('net', param.net)
        paramRow('title', param.title)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
      .backgroundColor(CARD)
      .borderRadius(12)
      .margin({ left: 12, right: 12 })

      Text('骨架页：真实内容待实现')
        .fontSize(12)
        .fontColor('#55617A')
        .margin({ top: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .alignItems(HorizontalAlign.Start)
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
}

/** 图片详情页骨架（看图器） */
@Builder
export function PhotoDetailPage(name: string, param: PhotoNavParam) {
  NavDestination() {
    Column() {
      detailHeader(param.title.length > 0 ? param.title : '图片')

      Column() {
        paramRow('title', param.title)
        paramRow('url', param.url)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
      .backgroundColor(CARD)
      .borderRadius(12)
      .margin({ left: 12, right: 12 })

      Text('骨架页：真实看图器待实现')
        .fontSize(12)
        .fontColor('#55617A')
        .margin({ top: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .alignItems(HorizontalAlign.Start)
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
}

/** 火箭详情页骨架 */
@Builder
export function RocketDetailPage(name: string, param: RocketNavParam) {
  NavDestination() {
    Column() {
      detailHeader('火箭详情')

      Column() {
        paramRow('name', param.name)
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
      .backgroundColor(CARD)
      .borderRadius(12)
      .margin({ left: 12, right: 12 })

      Text('骨架页：真实内容待实现')
        .fontSize(12)
        .fontColor('#55617A')
        .margin({ top: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .alignItems(HorizontalAlign.Start)
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
}
