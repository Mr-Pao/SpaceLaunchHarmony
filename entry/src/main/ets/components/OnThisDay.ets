/**
 * components/OnThisDay.ets —— 今日页「往年今日」区块
 *
 * 对位小程序：pages/today/today.vue
 *   template   75-116   （.sec-head 区块头 + .sec-acts 折叠入口；.otd-item 三行）
 *   script     205, 238 （const OTD_FOLD = 3；otdOpen = false）
 *   script     363-383  （otd 计算属性的 title / meta / yearsAgo 映射口径；otdShown()）
 *   style      766-808  （.sec-head / .sec-title / .sec-sub / .sec-acts / .more-inline / .more-arrow）
 *   style      1080-1180（.otd / .otd-item / .otd-hover / .otd-img / .otd-ph / .otd-body /
 *                        .otd-year / .otd-name / .otd-meta）
 *
 * 换算：rpx ÷ 2 = vp
 *   OTD_FOLD 3 条；缩略图 132×96rpx → 66×48vp；圆角 18rpx → 9vp；
 *   条目内边距 16rpx → 8vp；条间距 14rpx → 7vp；标题 34rpx → 17vp；
 *   年份/元信息 21rpx → 10.5vp；任务名 26rpx → 13vp；副标题 22rpx → 11vp
 *
 * ── 本轮按小程序对齐的改动（逐条对应审计项）──
 *   1. **折叠文案改回「收起 / 更多 N 条 ›」**。today.vue 是
 *      `{{ otdOpen ? '收起' : '更多 ' + (otd.length - OTD_FOLD) + ' 条' }}`，
 *      之前写成分两段的「展开」+「N 条」是自创文案。
 *   2. **箭头方向改回 rotate(-90deg)**：today.vue 的 `.more-arrow.is-up` 是
 *      `transform: rotate(-90deg)`，即展开时箭头朝上；之前写成 +90°（朝下）方向反了。
 *   3. **元信息去掉 site**：wxss/today.vue 的 otd 计算属性只拼 `rocket · agency`，
 *      地点是自创字段。字段仍在 model 里，只是这一行不显示。
 *   4. **去掉年份行末尾的 status**：today.vue 的第一行只有「N 年前的今天」，
 *      没有状态串；状态在发射详情页才有。
 *
 * ── 保留的既有取舍 ──
 *   A. 数据由父级通过 `list` 传入，组件不自己取数、也不自己算 otd 计算属性；
 *      title / meta / yearsAgo 的映射口径原样搬进来（titleText / metaText / yearText），
 *      保证同样的 JSON 进来长得一样。
 *   B. 原 vue 的 `hover-class="otd-hover"`（背景变 #1b2231）用 onTouch 按下态实现，
 *      按下时整条 opacity 0.92。深色底上改背景色的对比度太弱，看不出反馈；
 *      且本工程既有代码没用过 stateStyles，不冒险。
 *   C. 点击只回调 onSelect，跳转由父级接入（原 vue 是 goLaunch 直接 navigateTo）。
 *   D. 空数据整块不渲染（对位 `v-if="otd.length"`）：页面已经有整页空态兜底，
 *      这里再画一个占位块就是「空态叠空态」，故 build 里直接返回空 Column。
 *
 * ⚠ 本文件不使用 console.*；只在折叠切换时记一条 hilog.debug。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { OnThisDayItem } from '../model/Launch';
import { strOf } from '../utils/Format';

const DOMAIN: number = 0x0001;
const TAG: string = 'OnThisDay';

/** 折叠时最多露出的条数（对位 today.vue:205 的 const OTD_FOLD = 3） */
const OTD_FOLD: number = 3;

/** 按下 / 弹起的透明度（任务书指定 0.92） */
const PRESSED_OPACITY: number = 0.92;

@Component
export struct OnThisDay {
  /** 往年今日列表。父级没数据就传空数组，整块不渲染 */
  @Prop list: OnThisDayItem[] = [];
  /** 是否已展开 */
  @State expanded: boolean = false;
  /**
   * 当前被按下的条目 id。
   *
   * 用 onTouch 的 Down/Up 驱动，而不是 onClick 里翻转：
   * onClick 里翻转得靠 setTimeout 复位，那是定时器，还得在 aboutToDisappear 里清，
   * 为了一个按下态不值当。
   */
  @State pressedId: string = '';

  /** 点击某条的回调。函数类型成员不加 @Prop，普通成员 + 默认空实现 */
  onSelect: (item: OnThisDayItem) => void = () => {};

  // ============ 展示口径（搬自 today.vue:363-383） ============

  /** title = nameZh || name || '未命名任务' */
  private titleText(item: OnThisDayItem): string {
    const zh: string = strOf(item.nameZh);
    if (zh.length > 0) {
      return zh;
    }
    const en: string = strOf(item.name);
    if (en.length > 0) {
      return en;
    }
    return '未命名任务';
  }

  /** 当前年份。判空用 getFullYear()，不拿 Date 相减 */
  private currentYear(): number {
    return new Date().getFullYear();
  }

  /**
   * 「N 年前的今天」。
   *
   * 口径同 vue 的 `Math.max(1, thisYear - (x.y || thisYear))`：
   * y 缺失或就是今年时，最少也显示「1 年前」，不会出现「0 年前」这种怪话。
   */
  private yearsAgo(item: OnThisDayItem): number {
    const nowY: number = this.currentYear();
    const y: number = item.y > 0 ? item.y : nowY;
    const diff: number = nowY - y;
    return diff >= 1 ? diff : 1;
  }

  private yearText(item: OnThisDayItem): string {
    return this.yearsAgo(item).toString() + ' 年前的今天';
  }

  /**
   * 元信息：rocket · agency，空字段直接跳过（对位 otd 计算属性，**不含 site**）。
   *
   * 不用 `[a,b,c].filter(Boolean).join()` 那种写法 —— ArkTS 里数组字面量
   * 必须先有显式类型，手写判断反而更直白。
   */
  private metaText(item: OnThisDayItem): string {
    const parts: string[] = [];
    const rocket: string = strOf(item.rocket);
    const agency: string = strOf(item.agency);
    if (rocket.length > 0) {
      parts.push(rocket);
    }
    if (agency.length > 0) {
      parts.push(agency);
    }
    return parts.join(' · ');
  }

  private imageUrl(item: OnThisDayItem): string {
    // 图片字段在 OnThisDayItem 里叫 img（不是 image），别写错
    return strOf(item.img);
  }

  /** 稳定 key：id 优先，退化到 net，都没有用年份 + 下标兜（见 ForEach 第三参） */
  private keyOf(item: OnThisDayItem, index: number): string {
    const id: string = strOf(item.id);
    if (id.length > 0) {
      return id;
    }
    const net: string = strOf(item.net);
    if (net.length > 0) {
      return net;
    }
    // ArkTS 不做 number → string 的隐式转换，拼接一律显式 String()
    return 'otd_' + String(item.y) + '_' + String(index);
  }

  /** 折叠时只给前 OTD_FOLD 条（对位 otdShown()） */
  private visibleList(): OnThisDayItem[] {
    if (this.expanded) {
      return this.list;
    }
    return this.list.slice(0, OTD_FOLD);
  }

  private countText(): string {
    return this.list.length.toString() + ' 次发射';
  }

  /** 收起态多出来的条数 */
  private hiddenCount(): number {
    const n: number = this.list.length - OTD_FOLD;
    return n > 0 ? n : 0;
  }

  private canFold(): boolean {
    return this.list.length > OTD_FOLD;
  }

  /**
   * 折叠入口文案。today.vue：
   *   otdOpen ? '收起' : '更多 ' + (otd.length - OTD_FOLD) + ' 条'
   * 收起态条数直接编进文案，不再另挂一个「N 条」文本。
   */
  private toggleText(): string {
    if (this.expanded) {
      return '收起';
    }
    return '更多 ' + this.hiddenCount().toString() + ' 条';
  }

  // ============ 区块头 ============

  @Builder
  header() {
    Row() {
      Text('往年今日')
        .fontSize(17) // 34rpx ÷ 2
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(0.5) // 1rpx ÷ 2

      Text(this.countText())
        .fontSize(11) // 22rpx ÷ 2
        .fontColor('#6B7891')
        .margin({ left: 6 }) // 12rpx ÷ 2
        .maxLines(1)

      Blank()

      // 折叠入口：条数不超过 OTD_FOLD 时整块不出现（对位 v-if="otd.length > OTD_FOLD"）
      if (this.canFold()) {
        Row() {
          Text(this.toggleText())
            .fontSize(11.5) // 23rpx ÷ 2
            .fontColor('#38BDF8')
            .maxLines(1)

          Text('›')
            .fontSize(11.5)
            .fontColor('#38BDF8')
            .margin({ left: 2 }) // 4rpx ÷ 2
            // 对位 `.more-arrow.is-up { transform: rotate(-90deg) }`：
            // 收起态箭头朝右（0°）、展开态朝上（-90°）
            .rotate({ angle: this.expanded ? -90 : 0 })
        }
        .alignItems(VerticalAlign.Center)
        // 上下各留 3vp，把可点区域撑到约 40vp，别让 11vp 的字直接当热区
        .padding({ left: 6, right: 2, top: 3, bottom: 3 })
        .onClick(() => {
          this.expanded = !this.expanded;
          hilog.debug(DOMAIN, TAG, '往年今日 expanded=%{public}s', this.expanded.toString());
        })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ bottom: 7 }) // 14rpx ÷ 2
  }

  // ============ 单条 ============

  @Builder
  itemCell(item: OnThisDayItem, index: number) {
    Row() {
      // 缩略图：有图才画，没有就画占位块（对位 .otd-ph 的 🚀）
      if (this.imageUrl(item).length > 0) {
        Image(this.imageUrl(item))
          .width(66) // 132rpx ÷ 2
          .height(48) // 96rpx ÷ 2
          .objectFit(ImageFit.Cover)
          .borderRadius(6) // 12rpx ÷ 2
          .backgroundColor('#1B2231')
          .flexShrink(0)
      } else {
        Column() {
          Text('🚀')
            .fontSize(18) // 36rpx ÷ 2
            .opacity(0.45)
        }
        .width(66)
        .height(48)
        .borderRadius(6)
        .backgroundColor('#1B2231')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .flexShrink(0)
      }

      Column() {
        // 第一行只有年份，没有状态串（见文件头第 4 条）
        Text(this.yearText(item))
          .fontSize(10.5) // 21rpx ÷ 2
          .fontColor('#F5C33B')
          .letterSpacing(0.5) // 1rpx ÷ 2
          .maxLines(1)
          .width('100%')

        Text(this.titleText(item))
          .fontSize(13) // 26rpx ÷ 2
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .lineHeight(18) // 26rpx × 1.34 ÷ 2 ≈ 17.4
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 }) // 4rpx ÷ 2

        // 元信息：火箭 · 机构，全空就整行不画
        if (this.metaText(item).length > 0) {
          Text(this.metaText(item))
            .fontSize(10.5) // 21rpx ÷ 2
            .fontColor('#6B7891')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 2 }) // 4rpx ÷ 2
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 9 }) // 18rpx ÷ 2
    }
    .width('100%')
    // 16rpx ÷ 2
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor('#141A26')
    .borderRadius(9) // 18rpx ÷ 2
    .border({ width: 1, color: '#0FFFFFFF' }) // 1rpx rgba(255,255,255,0.06)
    .margin({ bottom: 7 }) // 14rpx ÷ 2
    // 按下态：整条降透明度（见文件头取舍 B）
    .opacity(this.pressedId === this.keyOf(item, index) ? PRESSED_OPACITY : 1.0)
    .onTouch((event: TouchEvent) => {
      const k: string = this.keyOf(item, index);
      if (event.type === TouchType.Down) {
        this.pressedId = k;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedId = '';
      }
    })
    .onClick(() => {
      hilog.debug(DOMAIN, TAG, '点击往年今日 id=%{public}s', strOf(item.id));
      this.pressedId = '';
      this.onSelect(item);
    })
  }

  build() {
    // 空列表整块不渲染（对位 `v-if="otd.length"`）：页面有整页空态兜底，
    // 这里再画占位块就是空态叠空态。根节点仍是唯一 Column，只是高度 0、margin 0。
    Column() {
      if (this.list.length > 0) {
        this.header()
        // key 用 id 优先的唯一串；ForEach 第三参给 key 生成器是 ArkTS 硬约束
        ForEach(this.visibleList(), (item: OnThisDayItem, index: number) => {
          this.itemCell(item, index)
        }, (item: OnThisDayItem, index: number) => this.keyOf(item, index))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: this.list.length > 0 ? 10 : 0 }) // 20rpx ÷ 2
  }
}
