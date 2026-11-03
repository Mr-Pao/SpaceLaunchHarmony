/**
 * components/NewsSection.ets —— 首页底部「航天资讯」区块
 *
 * 对位文件：components/news-section/news-section.vue（379 行，全文对读）
 *   模板 1-72 行、script 90-200 行、样式 201-379 行
 *   数据源：NewsItem[]（news.json，CI 每 3 小时一轮，线上实测 100 余条）
 *
 * ── 展开量为什么用 Math.max 语义 ──
 *   小程序 applyNews() 写的是 `const want = Math.max(this.shown || 0, this.limit)`，
 *   目的只有一个：**后台刷新回来的新 list 不许把用户已经展开的条数收回去**
 *   （用户展开到 9 条，一次静默刷新变回 3 条 = 刷新把阅读位置弄丢了）。
 *   本实现把这个语义收进 shownCount()：
 *     shownCount = min( max(shown, limit), list.length )
 *   shown 初始 0，于是「还没触底过」时结果恒等于 limit；
 *   触底后 shown 只会变大，刷新换 list 也不会被压回 limit。
 *
 * ── 本轮按小程序对齐的改动（逐条对应审计项）──
 *   1. **删掉卡片里的摘要两行**。wxss 的 .row 只有「标题 + 来源·时间」，
 *      摘要只在 news-detail 弹层里出现；之前按任务书补的两行摘要属于自创，已删。
 *   2. **补骨架屏**（news-section.vue 的 `<template v-if="loading">`）。
 *      loading 时按 limit 条画占位行：88×66 缩略块 + 两条呼吸线（92% / 58% 宽）。
 *      呼吸用 opacity 两条 keyframe 拼（0.45 ↔ 1，1.4s），不引入重复动画 ——
 *      工程里没有 `.animation({ iterations: -1 })` 的先例，StarField 也是用
 *      「两档值 + setInterval 翻转 + .animation 补间」拼出来的，同法照办。
 *   3. **触底加载改由宿主驱动**。小程序是 onReachBottom → news.loadMore()；
 *      鸿蒙侧滚动容器在 TodayView，故宿主每次触底把 growSignal +1，
 *      本组件 @Watch 到变化就 expand()。展开量仍归组件管（它知道步长与上限）。
 *   4. **footer 换回「查看全部资讯 ›」胶囊**（wxss 的 .news-foot：76rpx 高、
 *      38vp 圆角 8vp、#7fb6dc 字、rgba(56,189,248,0.08) 底、0.18 描边）。
 *      原来那个「展开更多」按钮是小程序没有的，删掉。
 *   5. **提示文案改回「上拉加载更多 · 已显示 x/y」**。原 wxss 是
 *      `上拉加载更多 · 已显示 {shown}/{total}`，到底后是 `已显示全部 N 条`。
 *      之前写的「已显示 x / y 条」少了「上拉加载更多 ·」前缀。鸿蒙侧触底是
 *      List.onReachEnd，语义与「上拉」一致，故文案照抄不改。
 *   6. 头部右侧「查看全部 ›」与小程序 `.news-more` 的「全部 ›」在**文案上有意不同**：
 *      任务书要求写「查看全部 ›」，两字之差、跳转目标一致，按任务书。
 *
 * ── 其余既有取舍（保留）──
 *   A. 封面加载失败：wxss 用 imgErr 状态表 + 🛰 占位；本实现把占位垫在图层下，
 *      不额外维护失败表（少一份 @State，也避开 ArkTS 对索引签名的限制）。
 *   B. 点卡片只回调 onOpen，由宿主决定后续（不打开 web-view：小程序因未配
 *      业务域名也不许打开，鸿蒙更没有内置浏览器）。
 *   C. 「发射」小标签判据只认 launchRefs（NewsItem 里没有旧版的单值 launchRef）。
 *   D. 卡片圆角 12vp、间距 10vp（wxss 是 20rpx=10vp / 16rpx=8vp），沿用既有值。
 *
 * ⚠ 本文件不使用 console.*，目前无需日志。
 */

import { NewsItem, NewsLaunchRef } from '../model/News';
import { strOf } from '../utils/Format';

/** 封面 176rpx ÷ 2 */
const THUMB_W: number = 88;
/** 封面 132rpx ÷ 2 */
const THUMB_H: number = 66;

/** 呼吸动画半周期：1.4s 一整轮 → 半程 700ms（对位 @keyframes news-breathe） */
const BREATHE_HALF_MS: number = 700;

/** 骨架屏两条线的宽度占比（wxss：92% / 58%） */
const SK_LINE_WIDE: string = '92%';
const SK_LINE_NARROW: string = '58%';

@Component
export struct NewsSection {
  /** 全量资讯，只控制露几条（几十 KB，全部留在内存即可） */
  @Prop list: NewsItem[] = [];
  /** 首屏露几条，同时也是每次触底的步长 */
  @Prop limit: number = 3;
  /**
   * 是否还在首次加载：true 时画骨架屏（对位 v-if="loading"）。
   * 挂 @Watch 是因为呼吸节拍器要随它启停 —— 骨架屏撤掉后还留着 interval 就是空跑。
   */
  @Prop @Watch('onLoadingChange') loading: boolean = false;

  /**
   * 宿主触底信号：每 +1 就多露一批（对位 onReachBottom → loadMore()）。
   *
   * 传数字而不是布尔：连续两次触底要各生效一次，布尔值第二次不变化、@Watch 不触发。
   */
  @Prop @Watch('onGrow') growSignal: number = 0;

  /** 用户已展开的条数。0 = 还没触底过，实际生效值由 shownCount() 夹出来 */
  @State shown: number = 0;

  /**
   * 骨架屏的呼吸相位。false = 0.45，true = 1。
   * 只用两档值 + .animation 补间，不依赖重复动画标记（见文件头第 2 条）。
   */
  @State breathe: boolean = false;

  /** 点某一条。函数类型成员不加 @Prop，普通成员 + 默认空实现 */
  onOpen: (item: NewsItem) => void = (item: NewsItem) => {};

  /** 点「查看全部资讯 ›」。宿主决定去哪，组件不自己跳 */
  onViewAll: () => void = () => {};

  /** 呼吸节拍器句柄。-1 表示没在跑 */
  private breatheTimer: number = -1;

  // ============ 生命周期 ============

  aboutToAppear(): void {
    if (this.loading) {
      this.startBreathe();
    }
  }

  /**
   * 必须清定时器。
   * Tabs 有 keepAlive，切 tab 不销毁组件；但页面真正销毁后残留的 interval
   * 会让回调打到已卸载的实例上（工程里踩过）。
   */
  aboutToDisappear(): void {
    this.stopBreathe();
  }

  /** 首屏加载结束后停掉骨架屏节拍，别让空跑的光标一直占着定时器 */
  onLoadingChange(propName: string): void {
    if (this.loading) {
      this.startBreathe();
    } else {
      this.stopBreathe();
    }
  }

  private startBreathe(): void {
    if (this.breatheTimer !== -1) {
      return;
    }
    this.breatheTimer = setInterval(() => {
      this.breathe = !this.breathe;
    }, BREATHE_HALF_MS);
  }

  private stopBreathe(): void {
    if (this.breatheTimer !== -1) {
      clearInterval(this.breatheTimer);
      this.breatheTimer = -1;
    }
    // 归到暗档，下次进骨架屏从 0.45 起呼吸，不会先跳亮一下
    this.breathe = false;
  }

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
    if (!this.hasMore()) {
      return;
    }
    // 夹一层 list.length：列表变短时不会越界；已到底则不动
    const next: number = this.shownCount() + this.step();
    this.shown = next < this.list.length ? next : this.list.length;
  }

  /** 宿主触底：再多露一批（@Watch 回调，形参由框架传入，必须留着） */
  onGrow(propName: string): void {
    this.expand();
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

  /** 骨架屏画几条：与首屏露出量一致，数据到了正好被同样条数的真实行替换 */
  private skeletonRows(): number[] {
    const rows: number[] = [];
    const n: number = this.step();
    for (let i = 0; i < n; i++) {
      rows.push(i);
    }
    return rows;
  }

  /** 骨架屏当前透明度：两档之间来回，补间交给 build 里的 .animation */
  private breatheOpacity(): number {
    return this.breathe ? 1.0 : 0.45;
  }

  // ============ 区块头 ============

  @Builder
  header() {
    Row() {
      Text('航天资讯')
        .fontSize(17) // 34rpx ÷ 2
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(0.5) // 1rpx ÷ 2
        .layoutWeight(1)

      Row() {
        Text('查看全部')
          .fontSize(12) // 24rpx ÷ 2
          .fontColor('#6B7891')
        Text('›')
          .fontSize(15) // 30rpx ÷ 2
          .fontColor('#6B7891')
          .margin({ left: 2 }) // 4rpx ÷ 2
      }
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.onViewAll();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 10 }) // 20rpx ÷ 2
  }

  // ============ 骨架屏单行 ============

  /**
   * 骨架行（wxss 的 .sk-row / .sk-thumb / .sk-info / .sk-line）。
   * 与真实行同高同构图，切换时不会跳动。
   */
  @Builder
  skeletonRow() {
    Row() {
      Column()
        .width(THUMB_W)
        .height(THUMB_H)
        .borderRadius(7) // 14rpx ÷ 2
        .backgroundColor('#1A2231')

      Column() {
        Column()
          .width(SK_LINE_WIDE)
          .height(12) // 24rpx ÷ 2
          .borderRadius(4) // 8rpx ÷ 2
          .backgroundColor('#1A2231')
          .margin({ bottom: 8 }) // 16rpx ÷ 2

        Column()
          .width(SK_LINE_NARROW)
          .height(12)
          .borderRadius(4)
          .backgroundColor('#1A2231')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .margin({ left: 10 }) // 20rpx ÷ 2
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 与真实行同一套内边距/底色，骨架屏看起来才是「同一张卡的占位」
    .padding({ left: 11, right: 11, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor('#141A26')
    .border({ width: 1, color: '#0DFFFFFF' })
    .margin({ bottom: 10 })
    // 呼吸：0.45 ↔ 1 之间补间（对位 @keyframes news-breathe 1.4s infinite）
    .opacity(this.breatheOpacity())
    .animation({ duration: BREATHE_HALF_MS, curve: Curve.EaseInOut })
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
          .fontSize(20) // 44rpx ÷ 2，wxss 另有 opacity .35
          .opacity(0.35)
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
          .lineHeight(20) // 1.42 倍
          .fontWeight(FontWeight.Medium)
          .fontColor('#EAF0F6')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 来源 · 时间 +「发射」标签。wxss 没有摘要行，这里也不放（见文件头第 1 条）
        Row() {
          Text(strOf(item.site))
            .fontSize(11) // 22rpx ÷ 2
            .fontColor('#6B7891')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 120 }) // 240rpx ÷ 2
          Text('·')
            .fontSize(11)
            .fontColor('#4D596B')
            .opacity(0.6) // wxss 的 .sep { opacity: .6 }
            .margin({ left: 4, right: 4 }) // 8rpx ÷ 2
          Text(strOf(item.atShort))
            .fontSize(11)
            .fontColor('#6B7891')
            .maxLines(1)

          if (this.hasLaunch(item)) {
            Text('发射')
              .fontSize(10) // 20rpx ÷ 2
              .fontColor('#7BB8E0')
              .padding({ left: 6, right: 6, top: 1, bottom: 1 }) // 12rpx / 2rpx
              .borderRadius(3) // 6rpx ÷ 2
              // rgba(56,189,248,0.12)
              .backgroundColor('#1F38BDF8')
              .margin({ left: 6 }) // 12rpx ÷ 2
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 5 }) // 10rpx ÷ 2
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
    // 点击反馈：对位 .row-hover { opacity: 0.82 }。
    // 用系统 Highlight 而不是 stateStyles：后者要在 .ets 里写无类型对象字面量，ArkTS 挑剔
    .hoverEffect(HoverEffect.Highlight)
    .onClick(() => {
      this.onOpen(item);
    })
  }

  // ============ 底部：提示 + 查看全部资讯 ============

  /**
   * 提示行 + 「查看全部资讯 ›」胶囊。
   *
   * wxss 的 .news-hint：hasMore ? '上拉加载更多 · 已显示 x/y' : '已显示全部 N 条'；
   * .news-foot 只在 items.length && !loading 时渲染 —— 骨架屏期间不画底部。
   */
  @Builder
  footer() {
    Column() {
      Text(this.hasMore()
        ? ('上拉加载更多 · 已显示 ' + String(this.shownCount()) + '/' + String(this.list.length))
        : ('已显示全部 ' + String(this.list.length) + ' 条'))
        .fontSize(11) // 22rpx ÷ 2
        .fontColor('#4D596B')
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: 2, bottom: 10 }) // wxss: margin 4rpx 0 20rpx

      Row() {
        Text('查看全部资讯')
          .fontSize(13) // 26rpx ÷ 2
          .fontColor('#7FB6DC')
        Text('›')
          .fontSize(13)
          .fontColor('#7FB6DC')
          .margin({ left: 2 })
      }
      .width('100%')
      .height(38) // 76rpx ÷ 2
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      // wxss: background rgba(56,189,248,0.08) / border 1rpx rgba(56,189,248,0.18)
      .backgroundColor('#1438BDF8')
      .border({ width: 1, color: '#2E38BDF8' })
      .borderRadius(8) // 16rpx ÷ 2
      .margin({ top: 2 }) // 4rpx ÷ 2
      .onClick(() => {
        this.onViewAll();
      })
    }
    .width('100%')
  }

  build() {
    // 整块出现条件对位 `v-if="loading || visible.length"`：
    // 骨架屏期间即使 list 还是空的，也要把标题 + 占位行画出来。
    // 用「唯一 Column 根节点 + 内部 if」而不是 if 直接当根节点 ——
    // ArkUI 对后者在各版本上宽容度不一致，条件 margin 更好控。
    Column() {
      if (this.loading || this.visible().length > 0) {
        this.header()

        if (this.loading) {
          ForEach(this.skeletonRows(), (i: number) => {
            this.skeletonRow()
          }, (i: number) => 'sk_' + String(i))
        } else {
          ForEach(this.visible(), (item: NewsItem) => {
            this.row(item);
          }, (item: NewsItem) => String(item.id))

          // 底部只在有数据且不在加载时出现（wxss 的 v-if="items.length && !loading"）
          if (this.list.length > 0) {
            this.footer()
          }
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: (this.loading || this.list.length > 0) ? 15 : 0 }) // 30rpx ÷ 2
  }
}
