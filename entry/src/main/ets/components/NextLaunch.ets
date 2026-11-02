/**
 * components/NextLaunch.ets —— 「下次发射」大卡
 *
 * 对位小程序：components/next-launch/next-launch.vue（246 行）
 *   template   1-37   （hero 图 / 状态徽章 / 标题 / 机构·场地 / 倒计时 / 时间 + 出口）
 *   script    39-81   （title / status / provider / padName / metaText / timeText）
 *   style     83-246  （.nl / .nl-hover / .nl-hero / .nl-mask / .nl-badge.* /
 *                       .nl-body / .nl-title / .nl-meta / .nl-cd / .nl-foot / .nl-more）
 * 外层容器对位 pages/today/today.vue 59-74 行（.next-wrap + .sec-head）
 *
 * 换算：rpx ÷ 2 = vp
 *   图片区 300rpx → 150vp；圆角 24rpx → 12vp；标题 34rpx → 17vp；
 *   机构行 24rpx → 12vp；时间 23rpx → 11.5vp；内边距 28rpx → 14vp
 *
 * 有意差异（相对 next-launch.vue）：
 *   1. **不显示国旗图片**：小程序用 flagSrc() 拼一张国旗 png，鸿蒙侧还没有
 *      国旗资源，`$r('app.media.flag_*')` 会直接编译失败（资源 id 不存在）。
 *      按「机构 · 场地」一行文字呈现，补资源后再加 Image。
 *   2. 倒计时放在**图片底部叠层右侧**（任务书第 1 条要求），而不是像 vue 那样
 *      在正文里另起一行。理由：两个位置都放 = 两个 Countdown 实例 = 两个
 *      每秒定时器；图片右侧已经够用，正文不再重复。
 *   3. 状态 chip 改成「淡色底 + 同色字」（statusToneBg / statusToneColor），
 *      不复刻 vue 的高饱和实心块：实心块在 150vp 的深色头图上太抢，且
 *      ArkUI 没有 backdrop-filter，实心块边缘会和图片硬切。
 *   4. 「更多发射 ›」出口没做：今日页需要它，但那是父级路由的事，组件只管
 *      回调。onSelect 给整卡点击、onMore 留给父级决定要不要显示（默认空实现）。
 *   5. 卡片常驻 opacity 0.92：vue 是 hover-class 的按下态，ArkUI 无 hover-class，
 *      第一阶段用静态透明度近似（要真按下态得引 stateStyles，先不引）。
 *   6. 无数据时渲染「暂无待发任务」占位块（vue 里该卡由父级 v-if 控制、
 *      组件自己从不处理空数据）。占位块保持同样高度，父级换数据时页面不跳。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { LaunchSummary } from '../model/Common';
import {
  strOf, formatLaunchTime, statusOf, statusToneColor, statusToneBg,
  missionLabelOf, rocketLabelOf, providerLabelOf, placeLabelOf
} from '../utils/Format';
import { Countdown } from './Countdown';

const DOMAIN: number = 0x0001;
const TAG: string = 'NextLaunch';

/** 图片区高度：300rpx ÷ 2 */
const HERO_H: number = 150;

/**
 * 空 item 的哨兵值。
 *
 * @Prop 的对象类型必须有默认值，而 LaunchSummary 是 interface，
 * 只能给一个显式标注了类型的字面量（ArkTS 禁止**无类型**对象字面量，
 * 有 interface 标注的是合法的）。
 */
const EMPTY_LAUNCH: LaunchSummary = {
  id: '',
  name: '',
  net: ''
};

@Component
export struct NextLaunch {
  /** 下次发射。父级没数据时传 EMPTY_LAUNCH 或不传，都走占位块 */
  @Prop item: LaunchSummary = EMPTY_LAUNCH;
  /** 点击整卡的回调。@Prop 不用于函数，用普通成员 + 默认空实现 */
  onSelect: (item: LaunchSummary) => void = () => {};
  /** 「更多发射」出口，默认空实现（父级不接就不显示按钮） */
  onMore: () => void = () => {};
  /** 是否显示「更多发射」出口（对位 vue 的 more 开关） */
  @Prop more: boolean = false;

  // ============ 数据判空 ============

  /**
   * 有没有真实数据。
   *
   * 判 id 而不是判 net：id 来自 LL2 UUID，是这条记录存在的最小证据；
   * net 有可能为空（TBD 任务），判 net 会把有效任务误判成空。
   */
  private hasData(): boolean {
    const it: LaunchSummary = this.item;
    if (it === undefined || it === null) {
      return false;
    }
    return strOf(it.id).length > 0;
  }

  private imageUrl(): string {
    // 主图优先，回退缩略图（两者同源同值，但旧数据可能只有其中一个）
    const full: string = strOf(this.item.image);
    if (full.length > 0) {
      return full;
    }
    return strOf(this.item.imageThumb);
  }

  private titleText(): string {
    return missionLabelOf(this.item);
  }

  private rocketText(): string {
    return rocketLabelOf(this.item);
  }

  private placeText(): string {
    return placeLabelOf(this.item);
  }

  private providerText(): string {
    return providerLabelOf(this.item);
  }

  private timeText(): string {
    const t: string = formatLaunchTime(strOf(this.item.net));
    return t.length > 0 ? ('发射时间 ' + t) : '发射时间待定';
  }

  /** 「机构 · 场地」：任一侧为空就不留分隔符（对位 vue 的 metaText） */
  private metaText(): string {
    const p: string = this.providerText();
    const loc: string = this.placeText();
    if (p.length > 0 && loc.length > 0) {
      return p + ' · ' + loc;
    }
    if (p.length > 0) {
      return p;
    }
    return loc;
  }

  // 状态三件套各自取一次：@Builder 里不能声明局部变量，
  // 所以拆成三个方法，由调用处分别取（statusOf 是纯函数，重复调用无副作用）
  private statusText(): string {
    return statusOf(this.item).text;
  }

  private statusColor(): string {
    return statusToneColor(statusOf(this.item).tone);
  }

  private statusBg(): string {
    return statusToneBg(statusOf(this.item).tone);
  }

  // ============ 区块头 ============

  @Builder
  header() {
    Row() {
      Text('下次发射')
        .fontSize(17) // 34rpx ÷ 2
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(0.5)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ bottom: 7 }) // 14rpx ÷ 2
  }

  // ============ 图片区 ============

  /** 图底部渐变压黑，让 chip / 倒计时不直接压在原图上（对位 .nl-mask 140rpx→70vp） */
  @Builder
  heroMask() {
    Column()
      .width('100%')
      .height(70)
      .linearGradient({
        // ArkUI：angle 180 = 从上到下，与 css 的 to bottom 一致
        angle: 180,
        colors: [
          ['#00141A26', 0.0], // rgba(20,26,38,0)
          ['#141A26', 1.0]
        ]
      })
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  heroImage() {
    if (this.imageUrl().length > 0) {
      Image(this.imageUrl())
        .width('100%')
        .height(HERO_H)
        .objectFit(ImageFit.Cover)
        // 兜底：图挂掉时不露出白/灰块，垫一层卡片底色
        .backgroundColor('#141A26')
    } else {
      Column() {
        Text('🚀')
          .fontSize(45) // 90rpx ÷ 2
          .opacity(0.4)
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
  }

  /** 图片底部那一行：状态 chip（左）+ 倒计时（右） */
  @Builder
  heroOverlay() {
    Row() {
      Text(this.statusText())
        .fontSize(11) // 22rpx ÷ 2
        .fontColor(this.statusColor())
        .padding({ left: 9, right: 9, top: 3, bottom: 3 }) // 18rpx/6rpx ÷ 2
        .borderRadius(4) // 8rpx ÷ 2
        .backgroundColor(this.statusBg())
        .maxLines(1)

      Blank()

      // 宽度给死 168：Countdown 是 width('100%') 的四等分布局，
      // 不给容器宽度它会和 chip 抢满整行，把 chip 挤成竖排
      Column() {
        Countdown({ net: strOf(this.item.net), size: 'md', showLabel: true })
      }
      .width(168)
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding({ left: 12, right: 12, bottom: 6, top: 6 })
    .alignItems(VerticalAlign.Center)
  }

  // ============ 正文 ============

  @Builder
  bodyTitle() {
    Text(this.titleText())
      .fontSize(17) // 34rpx ÷ 2
      .fontWeight(FontWeight.Bold)
      .fontColor('#FFFFFF')
      .lineHeight(24)
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
  }

  @Builder
  bodyMeta() {
    // 机构 · 场地（对位 .nl-meta，无国旗版）
    if (this.metaText().length > 0) {
      Text(this.metaText())
        .fontSize(12) // 24rpx ÷ 2
        .fontColor('#7A8598')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 5 })
    }

    // 火箭型号：没有就是没有，不占一行
    if (this.rocketText().length > 0) {
      Text(this.rocketText())
        .fontSize(12)
        .fontColor('#A7B4C7')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 5 })
    }
  }

  @Builder
  bodyFoot() {
    Row() {
      Text(this.timeText())
        .fontSize(11.5) // 23rpx ÷ 2
        .fontColor('#55617A')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Text('查看详情 ›')
        .fontSize(12.5) // 25rpx ÷ 2
        .fontColor('#38BDF8')
        .maxLines(1)
        .margin({ left: 8 })

      if (this.more) {
        Text('更多发射 ›')
          .fontSize(12.5)
          .fontColor('#38BDF8')
          .maxLines(1)
          .margin({ left: 11 }) // 22rpx ÷ 2
          .onClick(() => {
            this.onMore();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 11 }) // 22rpx ÷ 2
    .padding({ top: 10 }) // 20rpx ÷ 2
    .border({ width: { top: 1 }, color: '#0DFFFFFF' }) // rgba(255,255,255,0.05)
  }

  // ============ 空数据占位 ============

  @Builder
  emptyBlock() {
    Column() {
      Text('🛰️')
        .fontSize(26)
        .opacity(0.5)
      Text('暂无待发任务')
        .fontSize(13)
        .fontColor('#7A8598')
        .margin({ top: 8 })
      Text('发射计划为空时这里会保持占位，不会塌成一条线')
        .fontSize(10.5)
        .fontColor('#55617A')
        .margin({ top: 5 })
        .textAlign(TextAlign.Center)
        .maxLines(2)
    }
    .width('100%')
    .height(HERO_H + 76) // 与有数据时高度接近，换数据时页面不跳
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#141A26')
    .borderRadius(12) // 24rpx ÷ 2
    .border({ width: 1, color: '#2438BDF8' }) // rgba(56,189,248,0.14)
    .opacity(0.92)
    .padding({ left: 16, right: 16 })
  }

  // ============ 主卡 ============

  @Builder
  card() {
    Column() {
      Stack({ alignContent: Alignment.Bottom }) {
        this.heroImage()
        this.heroMask()

        // 叠层整体压在图片底边；Bottom 对齐后高度随内容走
        Column() {
          this.heroOverlay()
        }
        .width('100%')
      }
      .width('100%')
      .height(HERO_H)

      Column() {
        this.bodyTitle()
        this.bodyMeta()
        this.bodyFoot()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      // 4rpx / 28rpx / 26rpx ÷ 2
      .padding({ left: 14, right: 14, top: 2, bottom: 13 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor('#141A26')
    .borderRadius(12) // 24rpx ÷ 2
    .border({ width: 1, color: '#2438BDF8' }) // 1rpx rgba(56,189,248,0.14)
    .overflow(Overflow.Hidden)
    .opacity(0.92) // 见文件头「有意差异 5」
    .onClick(() => {
      if (this.hasData()) {
        hilog.debug(DOMAIN, TAG, '点击下次发射卡 id=%{public}s', strOf(this.item.id));
        this.onSelect(this.item);
      }
    })
  }

  build() {
    Column() {
      this.header()

      if (this.hasData()) {
        this.card()
      } else {
        this.emptyBlock()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 15 }) // 30rpx ÷ 2
  }
}
