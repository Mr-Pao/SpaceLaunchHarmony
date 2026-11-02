/**
 * components/OnThisDay.ets —— 今日页「往年今日」区块
 *
 * 对位小程序：pages/today/today.vue 的「往年今日」区块
 *   template   81-95    （.sec-head 区块头 + .more-inline 折叠入口）
 *   template   99-116   （.otd / .otd-item / .otd-img / .otd-body 三行）
 *   script    205, 238  （const OTD_FOLD = 3；data.otdOpen = false）
 *   script    363-378   （otd 计算属性：title / meta / yearsAgo 的映射口径）
 *   script    381-383   （otdShown()：折叠时 slice(0, OTD_FOLD)）
 *   style     766-808   （.sec-head / .sec-title / .sec-sub / .sec-acts / .more-inline / .more-arrow）
 *   style    1080-1180  （.otd / .otd-item / .otd-hover / .otd-img / .otd-ph / .otd-body /
 *                        .otd-year / .otd-name / .otd-meta）
 *
 * 换算：rpx ÷ 2 = vp
 *   OTD_FOLD 3 条；缩略图 132×96rpx → 66×48vp；圆角 18rpx → 9vp；
 *   条目内边距 16rpx → 8vp；条间距 14rpx → 7vp；标题 34rpx → 17vp；
 *   年份/元信息 21rpx → 10.5vp；任务名 26rpx → 13vp；副标题 22rpx → 11vp
 *
 * 有意差异（相对 today.vue）：
 *   1. **数据由父级通过 `list` 传入**，组件不自己取数、也不自己算 otd 计算属性。
 *      today.vue 里 title/meta/yearsAgo 的映射口径原样搬进本组件（titleText/metText/yearText），
 *      保证同样的 JSON 进来长得一样。
 *   2. 元信息比原模板**多显示 status 与 site**（任务书要求四者都显示）。
 *      原 vue 只拼 `rocket · agency`；这里按 `rocket · agency · site` 拼接，
 *      status 单独放在年份那一行末尾（它是状态，和机构/地点不同类，混在一行会被读成一句）。
 *      **任一字段为空直接跳过，不产生 " · · " 这种空分隔符**。
 *   3. 折叠入口文案：原 vue 是「更多 N 条 ›」，任务书要求「展开/收起」，从任务书。
 *      箭头用 `›` 加 rotate 90° 表达展开态（原 vue 用 rotate(-90deg)，方向相反，
 *      因为原 vue 的箭头展开时朝上、这里朝下更符合「已展开」的直觉）。
 *   4. 原 vue 的 `hover-class="otd-hover"`（背景变 #1b2231）用 `onTouch` 的按下态实现，
 *      按下时整条 opacity 0.92（任务书指定），不回改背景色 —— 深色底上改背景的
 *      对比度太弱，看不出反馈。**没有引入 stateStyles**（本工程既有代码未用过，不冒险）。
 *   5. 点击只回调 `onSelect`，跳转由父级接入（原 vue 是 rowClick 直接 navigateTo）。
 *   6. 空数据渲染「暂无往年今日记录」占位块（原 vue 用 v-if 整块隐藏，
 *      组件自己拿不到父级上下文，只能自己兜底，否则父级漏判就是空白区）。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
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
  /** 往年今日列表。父级没数据就传空数组，走占位块 */
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

  // ============ 展示口径（搬自 today.vue:363-378） ============

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

  /** 状态：扁平字符串，没有就返回空 */
  private statusText(item: OnThisDayItem): string {
    return strOf(item.status);
  }

  /**
   * 元信息：rocket · agency · site，空字段直接跳过。
   *
   * 不用 `[a,b,c].filter(Boolean).join()` 那种写法 —— ArkTS 里数组字面量
   * 必须先有显式类型，手写三段判断反而更直白。
   */
  private metaText(item: OnThisDayItem): string {
    const parts: string[] = [];
    const rocket: string = strOf(item.rocket);
    const agency: string = strOf(item.agency);
    const site: string = strOf(item.site);
    if (rocket.length > 0) {
      parts.push(rocket);
    }
    if (agency.length > 0) {
      parts.push(agency);
    }
    if (site.length > 0) {
      parts.push(site);
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
    return 'otd_' + item.y + '_' + index;
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

  private toggleText(): string {
    return this.expanded ? '收起' : '展开';
  }

  // ============ 区块头 ============

  @Builder
  header() {
    Row() {
      Text('往年今日')
        .fontSize(17) // 34rpx ÷ 2
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(0.5)

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
            // 展开态箭头朝下，收起态朝右
            .rotate({ angle: this.expanded ? 90 : 0 })

          if (!this.expanded) {
            Text(this.hiddenCount().toString() + ' 条')
              .fontSize(10.5)
              .fontColor('#55617A')
              .margin({ left: 4 })
              .maxLines(1)
          }
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
        // 第一行：年份 + 状态（状态缺省就不占位）
        Row() {
          Text(this.yearText(item))
            .fontSize(10.5) // 21rpx ÷ 2
            .fontColor('#F5C33B')
            .letterSpacing(0.5)
            .maxLines(1)

          if (this.statusText(item).length > 0) {
            Text(this.statusText(item))
              .fontSize(10)
              .fontColor('#7A8598')
              .margin({ left: 5 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.titleText(item))
          .fontSize(13) // 26rpx ÷ 2
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .lineHeight(18)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 }) // 4rpx ÷ 2

        // 元信息：火箭 · 机构 · 地点，全空就整行不画
        if (this.metaText(item).length > 0) {
          Text(this.metaText(item))
            .fontSize(10.5) // 21rpx ÷ 2
            .fontColor('#6B7891')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 2 })
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
    // 按下态：整条降透明度（见文件头「有意差异 4」）
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

  // ============ 空数据占位 ============

  @Builder
  emptyBlock() {
    Column() {
      Text('暂无往年今日记录')
        .fontSize(12)
        .fontColor('#7A8598')
      Text('这一天还没有历史发射数据')
        .fontSize(10.5)
        .fontColor('#55617A')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding({ top: 22, bottom: 22 }) // 44rpx ÷ 2
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#141A26')
    .borderRadius(9)
    .border({ width: 1, color: '#0FFFFFFF' })
  }

  build() {
    Column() {
      this.header()

      if (this.list.length > 0) {
        // key 用 id 优先的唯一串；ForEach 第三参给 key 生成器是 ArkTS 硬约束
        ForEach(this.visibleList(), (item: OnThisDayItem, index: number) => {
          this.itemCell(item, index)
        }, (item: OnThisDayItem, index: number) => this.keyOf(item, index))
      } else {
        this.emptyBlock()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 15 }) // 30rpx ÷ 2
  }
}
