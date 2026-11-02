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
import { LaunchNavParam, PhotoNavParam, RocketNavParam, ArticleNavParam, AstronautNavParam, SearchNavParam } from './NavParam';
import { RocketDetailView } from '../view/RocketDetailView';
import { PhotoDetailView } from '../view/PhotoDetailView';
import { LaunchDetailView } from '../view/LaunchDetailView';
import { ArticleDetailView } from '../view/ArticleDetailView';
import { NewsListView } from '../view/NewsListView';
import { StatsView } from '../view/StatsView';
import { SpaceAssetsView } from '../view/SpaceAssetsView';
import { NeoView } from '../view/NeoView';
import { EventsView } from '../view/EventsView';
import { FavoritesView } from '../view/FavoritesView';
import { AstronautView } from '../view/AstronautView';
import { SearchView } from '../view/SearchView';

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

/**
 * 发射详情页：真实内容在 LaunchDetailView。
 *
 * 为什么这里只留一层包装：@Builder 不是组件、挂不了 @State，
 * 而详情页要「缓存先上屏、后台再刷新」、要「展开全文」、要倒计时，全是状态。
 * 所以状态与内容整体放进独立 @Component，@Builder 只负责把路由入参递进去。
 */
@Builder
export function LaunchDetailPage(name: string, param: LaunchNavParam) {
  NavDestination() {
    LaunchDetailView({ param: param })
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  // 详情页出现/消失时同步「压了几层」，Index 据此隐藏底部悬浮胶囊。
  // 用这两个回调而不是在 push/pop 里加减，是因为系统返回手势与物理返回键都不经过 Nav.pop。
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

/** 图片详情页：真实内容在 PhotoDetailView（缩放/拖动/下滑关闭需要 @State） */
@Builder
export function PhotoDetailPage(name: string, param: PhotoNavParam) {
  NavDestination() {
    PhotoDetailView({ url: param.url, title: param.title })
  }
  .hideTitleBar(true)
  .backgroundColor('#000000')
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

/** 火箭详情页：真实内容在 RocketDetailView（@Builder 没有状态，装不下加载过程） */
@Builder
export function RocketDetailPage(name: string, param: RocketNavParam) {
  NavDestination() {
    RocketDetailView({ rocketName: param.name })
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

/**
 * 资讯详情页。
 * 整条新闻由列表页塞进入参，本页不拉网络 —— 点开即渲染，没有加载态可言。
 */
@Builder
export function ArticleDetailPage(name: string, param: ArticleNavParam) {
  NavDestination() {
    ArticleDetailView({ param: param })
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

/**
 * 资讯列表页。无入参，自己 load('news')。
 * 同样必须带 onShown/onHidden —— 漏了 detailDepth 不涨，底部悬浮胶囊会盖住列表。
 */
@Builder
export function NewsListPage(name: string) {
  NavDestination() {
    NewsListView()
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

/**
 * 「我的 → 探索」四个功能页。
 *
 * 这四个都**无入参**、各自从 COS 拉自己的数据集，所以共用一个模板式写法：
 * NavDestination + 对应 View + onShown/onHidden 计数。
 *
 * 为什么每个都要写 onShown/onHidden：
 *   漏一个，从那一页进入时 detailDepth 不涨，底部悬浮胶囊会浮在内容上（实测过）。
 */
@Builder
export function StatsPage(name: string) {
  NavDestination() {
    StatsView()
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

@Builder
export function AssetsPage(name: string) {
  NavDestination() {
    SpaceAssetsView()
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

@Builder
export function NeoPage(name: string) {
  NavDestination() {
    NeoView()
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

@Builder
export function EventsPage(name: string) {
  NavDestination() {
    EventsView()
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

/**
 * 收藏清单页。
 *
 * 与上面九个页面完全同构：`NavDestination` 包一层视图、隐藏系统标题栏
 * （自绘返回条）、背景统一 BG。
 *
 * onShown / onHidden 这两个钩子**不是可选的**：底部悬浮胶囊是 Index.ets 里
 * Tabs 的兄弟节点，层级比 TabContent 高，详情页压进来也盖不住；
 * 只有靠这两个钩子累加/减少 NAV_DETAIL_DEPTH_KEY 才能把它摘掉。
 * 漏写的话，收藏页底下会一直浮着五个 tab 图标。
 */
@Builder
export function FavoritesPage(name: string) {
  NavDestination() {
    FavoritesView()
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

/**
 * 航天员详情。
 *
 * 同样必须写 onShown/onHidden —— 否则底部悬浮胶囊会浮在页面内容上。
 */
@Builder
export function AstronautPage(name: string, param: object) {
  NavDestination() {
    AstronautView({ astronautId: (param as AstronautNavParam).id })
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}

/**
 * 全局搜索。
 *
 * 关键词只作为「初始值」传一次 —— 进页后键盘输入由 SearchView 自己管，
 * 不回调路由（否则每敲一个字都要 push 一次）。
 */
@Builder
export function SearchPage(name: string, param: object) {
  NavDestination() {
    SearchView({ initialKeyword: (param as SearchNavParam).keyword })
  }
  .hideTitleBar(true)
  .backgroundColor(BG)
  .onShown(() => {
    Nav.markDetailShown();
  })
  .onHidden(() => {
    Nav.markDetailHidden();
  })
}
