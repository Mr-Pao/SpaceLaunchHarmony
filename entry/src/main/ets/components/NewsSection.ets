/**
 * components/NewsSection.ets —— 首页底部「航天资讯」区块
 *
 * 对位文件：components/news-section/news-section.vue（379 行，全文对读）
 *   模板 1-69 行、样式 201-379 行（.news / .news-head / .news-title / .news-more /
 *   .row / .thumb / .info / .title / .meta / .site / .sep / .tag / .news-hint / .news-foot）
 * 数据源：NewsItem[]（news.json，CI 每 3 小时一轮，线上实测 100 余条）
 *
 * ── 展开量为什么用 Math.max 语义 ──
 *   小程序 applyNews() 里写的是 `const want = Math.max(this.shown || 0, this.limit)`，
 *   目的只有一个：**后台刷新回来的新 list 不许把用户已经展开的条数收回去**
 *   （用户展开到 9 条，一次静默刷新变回 3 条 = 刷新把阅读位置弄丢了）。
 *   本实现把这个语义收进 shownCount()：
 *     shownCount = min( max(shown, limit), list.length )
 *   shown 初始为 0，于是「还没点过展开」时结果恒等于 limit；
 *   点过展开后 shown 只会变大，刷新换 list 也不会被压回 limit。
 *   上限额外夹一层 list.length —— 新数据条目变少时不会越界。
 *
 * ── 有意差异（相对小程序）──
 *   1. 卡片加了**摘要两行**（item.summaryZh || item.summary）：小程序卡片只有
 *      「标题 + 来源·时间」，首页看一眼就知道说什么的需求，本实现按任务书补上。
 *   2. 展开方式：小程序靠宿主页 onReachBottom 自动续 + 一行只读提示；鸿蒙本组件
 *      自己管状态，所以改成底部一个**「展开更多」按钮**，并保留「已显示 x/y」提示。
 *   3. 卡片圆角 12vp、卡片间距 10vp（wxss 是 20rpx=10vp / 16rpx=8vp），按任务书统一。
 *   4. 骨架屏、news-detail 弹层、下拉刷新 reload() 都**不做**：宿主页（TodayView）
 *      还没有这些能力，组件里先只保留「list 进来就渲染」的纯展示职责。
 *   5. 「查看全部 ›」不做页面跳转（资讯页尚未迁移）：只回调 onViewAll，
 *      由宿主决定；默认空实现。
 *   6. 点卡片**不打开 web-view**（小程序都不许，因为未配业务域名；鸿蒙更没有
 *      这个前提）。点击只做视觉反馈 + 回调 onOpen(item)，由宿主决定后续。
 *   7. 「发射」小标签判据只认 launchRefs（NewsItem 里没有旧版的单值 launchRef）。
 *   8. 封面加载失败：wxss 用 imgErr 状态表 + 🛰 占位；本实现改为**占位垫在图层下**，
 *      不额外维护失败表（少一份 @State，也不会有 id 类型 map 的 ArkTS 限制）。
 *
 * ⚠ 本文件不使用 console.*，目前无需日志。
 */

import { NewsItem, NewsLaunchRef } from '../model/News';
import { strOf } from '../utils/Format';

/** 封面 176rpx ÷ 2 */
const THUMB_W: number = 88;
/** 封面 132rpx ÷ 2 */
const THUMB_H: number = 66;

@Component
export struct NewsSection {
  /** 全量资讯，只控制露几条（几十 KB，全部留在内存即可） */
  @Prop list: NewsItem[] = [];
  /** 首屏露几条，同时也是每次「展开更多」的步长 */
  @Prop limit: number = 3;

  /** 用户已展开的条数。0 = 还没展开过，实际生效值由 shownCount() 夹出来 */
  @State shown: number = 0;

  /** 点某一条。函数类型成员不加 @Prop，普通成员 + 默认空实现 */
  onOpen: (item: NewsItem) => void = (item: NewsItem) => {};

  /** 点「查看全部 ›」。宿主决定去哪，组件不自己跳 */
  onViewAll: () => void = () => {};

  // ============ 计数 ============

  private step(): number {
    return this.limit > 0 ? this.limit : 1;
  }

  /**
   * 当前该露几条。Math.max 语义见文件头：
   * 展开量只增不减，且不越界。
   */
  private shownCount(): number {
    const base: number = this.shown > this.step() ? this.shown : this.step();
    return base < this.list.length ? base : this.list.length;
  }

  private hasMore(): boolean {
    return this.shownCount() < this.list.length;
  }

  /** 当前可见的切片。ArkTS 的 slice 返回同类型数组，直接交给 ForEach */
  private visible(): NewsItem[] {
    return this.list.slice(0, this.shownCount());
  }

  private expand(): void {
    // 夹一层 list.length：列表变短时不会越界；已到底则不动
    const next: number = this.shownCount() + this.step();
    this.shown = next < this.list.length ? next : this.list.length;
  }

  private hasLaunch(item: NewsItem): boolean {
    const refs: NewsLaunchRef[] | undefined = item.launchRefs;
    if (refs === undefined) {
      return false;
    }
    return refs.length > 0;
  }

  private titleOf(item: NewsItem): string {
    const zh: string = strOf(item.titleZh);
    return zh.length > 0 ? zh : strOf(item.title);
  }

  private summaryOf(item: NewsItem): string {
    const zh: string = strOf(item.summaryZh);
    return zh.length > 0 ? zh : strOf(item.summary);
  }

  // ============ 区块头 ============

  @Builder
  header() {
    Row() {
      Text('航天资讯')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(0.5)
        .layoutWeight(1)

      Row() {
        Text('查看全部')
          .fontSize(12)
          .fontColor('#6B7891')
        Text('›')
          .fontSize(15)
          .fontColor('#6B7891')
          .margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.onViewAll();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 10 })
  }

  // ============ 单条 ============

  @Builder
  row(item: NewsItem) {
    Row() {
      // 占位垫在底下：图空/加载失败时露出来的是这块渐变 + 🛰
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width(THUMB_W)
          .height(THUMB_H)
          .borderRadius(7) // 14rpx ÷ 2
          .linearGradient({
            angle: 135,
            colors: [['#16233A', 0.0], ['#0D1420', 1.0]]
          })
        Text('🛰')
          .fontSize(20)
          .fontColor('#5D6A7D')
        if (strOf(item.image).length > 0) {
          Image(strOf(item.image))
            .width(THUMB_W)
            .height(THUMB_H)
            .borderRadius(7)
            .objectFit(ImageFit.Cover)
        }
      }
      .width(THUMB_W)
      .height(THUMB_H)

      Column() {
        Text(this.titleOf(item))
          .fontSize(14) // 28rpx ÷ 2
          .lineHeight(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#EAF0F6')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 摘要：任务书要求的「两行截断」，wxss 里没有这一行
        if (this.summaryOf(item).length > 0) {
          Text(this.summaryOf(item))
            .fontSize(11)
            .lineHeight(15)
            .fontColor('#A7B4C7')
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
        }

        Row() {
          Text(strOf(item.site))
            .fontSize(11)
            .fontColor('#6B7891')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 120 }) // 240rpx ÷ 2
          Text('·')
            .fontSize(11)
            .fontColor('#4D596B')
            .margin({ left: 4, right: 4 })
          Text(strOf(item.atShort))
            .fontSize(11)
            .fontColor('#6B7891')
            .maxLines(1)

          if (this.hasLaunch(item)) {
            Text('发射')
              .fontSize(10)
              .fontColor('#7BB8E0')
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(3)
              .backgroundColor('#1F38BDF8')
              .margin({ left: 6 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 5 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 }) // 20rpx ÷ 2
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // wxss: padding 20rpx 22rpx → 10vp / 11vp
    .padding({ left: 11, right: 11, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor('#141A26')
    .border({ width: 1, color: '#0DFFFFFF' })
    .margin({ bottom: 10 })
    // 点击的视觉反馈：对位 wxss 的 .row-hover { opacity: 0.82 }。
    // 用系统 Highlight 而不是 stateStyles：后者要在 .ets 里写「半截声明」的对象字面量，
    // ArkTS 对无类型字面量挑剔，这一行零风险且按压反馈一样有
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => {
      this.onOpen(item);
    })
  }

  // ============ 底部：提示 + 展开更多 ============

  @Builder
  footer() {
    Column() {
      Text(this.hasMore()
        ? ('已显示 ' + String(this.shownCount()) + ' / ' + String(this.list.length) + ' 条')
        : ('已显示全部 ' + String(this.list.length) + ' 条'))
        .fontSize(11)
        .fontColor('#4D596B')
        .margin({ bottom: 8 })

      if (this.hasMore()) {
        Row() {
          Text('展开更多')
            .fontSize(13)
            .fontColor('#7FB6DC')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height(38) // 76rpx ÷ 2
        .backgroundColor('#1438BDF8')
        .border({ width: 1, color: '#2E38BDF8' })
        .borderRadius(8)
        .onClick(() => {
          this.expand();
        })
      }
    }
    .width('100%')
  }

  build() {
    // 没数据就整块不渲染（对应模板首行 v-if="loading || visible.length"）：
    // 否则首页会出现「空标题 + 空列表」的空壳。这里同样用「唯一 Column 根节点
    // + 内部 if」的写法，空列表时高度为 0、margin 为 0，视觉上完全等价于不渲染。
    Column() {
      if (this.list.length > 0) {
        this.header()

        ForEach(this.visible(), (item: NewsItem) => {
          this.row(item);
        }, (item: NewsItem) => String(item.id))

        this.footer()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: this.list.length > 0 ? 15 : 0 })
  }
}
