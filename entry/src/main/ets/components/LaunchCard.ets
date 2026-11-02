/**
 * components/LaunchCard.ets —— 发射列表单卡
 *
 * 对位小程序：components/launch-card/launch-card.vue（296 行）
 *   template   1-47    （缩略图 / 标题 / 时间行 / 机构 + 状态）
 *   script    50-106   （title / timeText / dateText / status / rocketName / providerName）
 *   style    108-296  （.card / .thumb / .info / .title / .meta / .time / .date /
 *                       .rocket / .foot / .status.* / .fav-mark）
 *
 * 换算：rpx ÷ 2 = vp
 *   缩略图 200rpx → 100vp（本文件改成整幅宽图，见「有意差异 1」）
 *   标题 30rpx → 15vp；时间 26rpx → 13vp；日期 24rpx → 12vp；圆角 20rpx → 10vp
 *
 * 有意差异（相对 launch-card.vue）：
 *   1. **缩略图从左侧 100×100 小方块改成整幅宽 150vp 头图**。任务书要求
 *      「顶部火箭图 150vp + ImageFit.Cover」。列表里一列大图会更吃重绘，
 *      但 List 只回收可视区，实际开销可控；观感上比小方块更像「发射事件卡」。
 *   2. **不再拼「火箭型号 | 任务名」一行**。ArkTS 侧 Format 的 missionLabelOf /
 *      rocketLabelOf 已经拆成两行不同字号，硬拼回一行会把中文型号和任务名混在一句里，
 *      英文型号过长时先被截断的恰好是任务名。
 *   3. **倒计时只有「3 天内」才跑秒级**（见 launchView 的 live 判据）。
 *      utils/Format.ets:161-163 记过原项目的教训：列表里几十张卡各起一个
 *      setInterval 会拖住主线程，所以原项目的列表卡只用 relativeTime 文字版。
 *      这里折中：临近发射（72h 内）才挂 Countdown 实例，其余用 relativeTime。
 *   4. **图片加载失败不留白块**：onError 置 broken，整块换成渐变 + 🚀 占位
 *      （小程序是 `v-else` 分支的 thumb-empty，逻辑一致，只是鸿蒙要自己记状态）。
 *   5. 没有收藏标记（fav）与国旗（flag）：收藏数据层与国旗资源都还没迁到鸿蒙侧，
 *      留空比画一个永远不亮的角标好。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog（本文件实际无需日志）。
 */

import { LaunchSummary } from '../model/Common';
import {
  strOf, formatLaunchTime, relativeTime, statusOf, statusToneColor, statusToneBg,
  missionLabelOf, rocketLabelOf, placeLabelOf
} from '../utils/Format';
import { Countdown } from './Countdown';

/** 头图高度：300rpx ÷ 2 */
const HERO_H: number = 150;

/** 卡片底色（任务书视觉规范） */
const CARD_BG: string = '#141A26';

/**
 * 空 item 的哨兵值。
 * @Prop 的对象类型必须有默认值，LaunchSummary 是 interface，
 * 只能给一个**显式标注了类型**的字面量（ArkTS 禁止无类型对象字面量）。
 */
const EMPTY_LAUNCH_CARD: LaunchSummary = {
  id: '',
  name: '',
  net: ''
};

@Component
export struct LaunchCard {
  /**
   * 这一条发射。父级 ForEach 逐条传入。
   *
   * 挂 @Watch 是因为 `broken` 是组件内部状态：List 回收节点后同一实例可能被复用给
   * 另一条数据，不重置的话新条目会顶着一块「图挂了」的占位块。
   */
  @Prop @Watch('onItemChange') item: LaunchSummary = EMPTY_LAUNCH_CARD;
  /**
   * 是否挂真实倒计时（秒级）。
   * 由父级决定而不是卡片自己算：父级才知道「这一页是待发射还是历史」，
   * 也只有它能控制同时存活几个定时器。
   */
  @Prop live: boolean = false;

  /** 整卡点击。普通成员不加装饰器（ArkTS 不让 @Prop 承载函数） */
  onSelect: (item: LaunchSummary) => void = () => {};

  /** 图片是否已加载失败。失败后不再重试，直接走占位块 */
  @State broken: boolean = false;

  /** 换了数据就重新给图一次机会（见 item 上的注解） */
  onItemChange(propName: string): void {
    // propName 由 @Watch 框架传入，本回调不区分具体属性，只做重置
    this.broken = false;
  }

  // ============ 取值（全部走 Format 的现成函数，不在这里重写判断） ============

  /** 主图优先、回退缩略图：两者同源同值，但旧数据可能只有其中一个 */
  private imageUrl(): string {
    const full: string = strOf(this.item.image);
    if (full.length > 0) {
      return full;
    }
    return strOf(this.item.imageThumb);
  }

  private titleText(): string {
    return missionLabelOf(this.item);
  }

  /** 「型号 · 发射场」：任一侧为空就不留分隔符，避免出现 " · " 这种空档 */
  private metaText(): string {
    const rocket: string = rocketLabelOf(this.item);
    const place: string = placeLabelOf(this.item);
    if (rocket.length > 0 && place.length > 0) {
      return rocket + ' · ' + place;
    }
    if (rocket.length > 0) {
      return rocket;
    }
    return place;
  }

  private timeText(): string {
    return formatLaunchTime(strOf(this.item.net));
  }

  /** 相对时间：待发射看「几天后」，历史看「几天前」，同一个纯函数两种语境都对 */
  private relativeText(): string {
    return relativeTime(strOf(this.item.net));
  }

  // 状态三件套各取一次：@Builder 里不能声明局部变量，所以拆成三个方法
  private statusText(): string {
    return statusOf(this.item).text;
  }

  private statusColor(): string {
    return statusToneColor(statusOf(this.item).tone);
  }

  private statusBg(): string {
    return statusToneBg(statusOf(this.item).tone);
  }

  // ============ 头图 ============

  /** 图底部渐变压黑：状态 chip 与倒计时直接压在照片上会读不清 */
  @Builder
  heroMask() {
    Column()
      .width('100%')
      .height(58)
      .linearGradient({
        // angle 180 = 从上到下（与 NextLaunch 同口径）。
        // 两端色值写成字面量：linearGradient 的 colors 要的是 [ResourceColor, number]
        // 元组，喂常量字符串会让 ArkTS 推成 (string|number)[]，元组断言反而更啰嗦
        angle: 180,
        colors: [
          ['#00141A26', 0.0],
          ['#141A26', 1.0]
        ]
      })
      .hitTestBehavior(HitTestMode.None)
  }

  /** 占位块：图挂了 / 本来就没图，两种情况长得一样，不留白块 */
  @Builder
  heroPlaceholder() {
    Column() {
      Text('🚀')
        .fontSize(34)
        .opacity(0.35)
    }
    .width('100%')
    .height(HERO_H)
    .justifyContent(FlexAlign.Center)
    .linearGradient({
      angle: 135,
      colors: [
        ['#16233A', 0.0],
        ['#0D1420', 1.0]
      ]
    })
  }

  /** 图底一行：状态 chip（左）+ 倒计时或相对时间（右） */
  @Builder
  heroOverlay() {
    Row() {
      Text(this.statusText())
        .fontSize(10.5)
        .fontColor(this.statusColor())
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .borderRadius(4)
        .backgroundColor(this.statusBg())
        .maxLines(1)

      Blank()

      if (this.live) {
        // 宽度给死：Countdown 是 width('100%') 的四等分布局，
        // 不给容器宽度它会和 chip 抢满整行，把 chip 挤成竖排（NextLaunch 踩过）
        Column() {
          Countdown({ net: strOf(this.item.net), sizeMode: 'sm', showLabel: true })
        }
        .width(132)
        .alignItems(HorizontalAlign.End)
      } else {
        Text(this.relativeText())
          .fontSize(11)
          .fontColor('#38BDF8')
          .maxLines(1)
      }
    }
    .width('100%')
    .padding({ left: 11, right: 11, top: 4, bottom: 7 })
    .alignItems(VerticalAlign.Bottom)
  }

  @Builder
  hero() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.imageUrl().length > 0 && !this.broken) {
        Image(this.imageUrl())
          .width('100%')
          .height(HERO_H)
          .objectFit(ImageFit.Cover)
          // 兜底底色：图片解码期间也不露白
          .backgroundColor(CARD_BG)
          .onError(() => {
            this.broken = true;
          })
      } else {
        this.heroPlaceholder()
      }

      this.heroMask()
      this.heroOverlay()
    }
    .width('100%')
    .height(HERO_H)
  }

  // ============ 正文 ============

  @Builder
  body() {
    Column() {
      Text(this.titleText())
        .fontSize(15) // 30rpx ÷ 2
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .lineHeight(21) // 15 × 1.4
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      // 型号 · 场地：没有就不占一行
      if (this.metaText().length > 0) {
        Text(this.metaText())
          .fontSize(11.5)
          .fontColor('#A7B4C7')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 6 })
      }

      Row() {
        Text(this.timeText())
          .fontSize(11.5)
          .fontColor('#38BDF8')
          .maxLines(1)

        Text(this.relativeText())
          .fontSize(11)
          .fontColor('#55617A')
          .maxLines(1)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 10, bottom: 12 })
  }

  build() {
    Column() {
      this.hero()
      this.body()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(CARD_BG)
    .borderRadius(12) // 24rpx ÷ 2
    .border({ width: 1, color: '#0DFFFFFF' }) // rgba(255,255,255,0.05)
    // .overflow(Overflow.Hidden) 在 ColumnAttribute 上不存在，圆角裁切只能用 clip
    .clip(true)
    .onClick(() => {
      this.onSelect(this.item);
    })
  }
}
