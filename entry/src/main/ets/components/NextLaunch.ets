/**
 * components/NextLaunch.ets —— 「下次发射」大卡
 *
 * 对位小程序：components/next-launch/next-launch.vue（246 行）
 *   template   1-37   （hero 图 / 状态徽章 / 标题 / 机构·场地 / 倒计时 / 时间 + 出口）
 *   script    39-81   （title / status / provider / padName / metaText / timeText）
 *   style     83-246  （.nl / .nl-hero / .nl-mask / .nl-badge.* / .nl-body /
 *                       .nl-title / .nl-meta / .nl-cd / .nl-foot / .nl-more）
 * 外层容器对位 pages/today/today.vue 59-74 行（.next-wrap + .sec-head）
 *
 * 换算：rpx ÷ 2 = vp
 *   图片区 300rpx → 150vp；圆角 24rpx → 12vp；标题 34rpx → 17vp；
 *   机构行 24rpx → 12vp；时间 23rpx → 11.5vp；内边距 28rpx → 14vp；
 *   徽章 left/top 24rpx → 12vp；徽章字号 22rpx → 11vp；渐隐层 140rpx → 70vp
 *
 * ⚠ 2026-11-03 按小程序原图重排过一次，别再凭印象改：
 *   之前的版本把状态徽章和倒计时一起压在图片底部、标题只留任务名、
 *   还多画了一行火箭型号 —— 与小程序差了整整一个版式。现在的结构与 vue 一一对应：
 *     图片（徽章在**左上角**，实心高饱和底）
 *     正文：标题（型号 | 任务名，两行）/ 国旗 + 机构·场地 / 倒计时（lg 档）/
 *           分隔线 + 发射时间 + 「查看详情 ›」+「更多发射 ›」
 *
 * 有意差异（相对 next-launch.vue）：
 *   1. 国旗用 emoji（flagOf 返回 emoji），不是 png：鸿蒙侧没有 /static/flags/*.png。
 *   2. 卡片不做 hover 按下态（ArkUI 无 hover-class），要按下态得引 stateStyles。
 *   3. 无数据时渲染「暂无待发任务」占位块（vue 里该卡由父级 v-if 控制、
 *      组件自己从不处理空数据）。占位块保持同样高度，父级换数据时页面不跳。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { LaunchProvider, LaunchSummary } from '../model/Common';
import {
  strOf, formatDateTime, statusOf, launchTitle, providerLabelOf, placeLabelOf, flagOf
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

  /** 标题 = 型号 | 任务名（对位 vue 的 launchTitle(item)） */
  private titleText(): string {
    return launchTitle(this.item);
  }

  private providerText(): string {
    return providerLabelOf(this.item);
  }

  private placeText(): string {
    return placeLabelOf(this.item);
  }

  /** 国旗 emoji：与 vue 一样用机构**英文原名**认国家 */
  private flagText(): string {
    const p: LaunchProvider | undefined = this.item.launch_service_provider;
    const raw: string = p === undefined || p === null ? '' : strOf(p.name);
    return flagOf(raw);
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

  private timeText(): string {
    const t: string = formatDateTime(strOf(this.item.net));
    return t.length > 0 ? ('发射时间 ' + t) : '发射时间待定';
  }

  // 状态三件套各自取一次：@Builder 里不能声明局部变量，
  // 所以拆成三个方法，由调用处分别取（statusOf 是纯函数，重复调用无副作用）
  private statusText(): string {
    return statusOf(this.item).text;
  }

  /**
   * 徽章底色 —— **实心高饱和**，对位 .nl-badge.pending / .success / .failure / .flying / .normal。
   *
   * 这里不复用 Format 的 statusToneBg：那套是「淡色底 + 同色字」的列表 chip 口径，
   * 而大卡上的徽章压在实拍图上是另一套视觉（vue 用 rgba(...,0.9) 的近实心块）。
   * ArkUI 没有 backdrop-filter，实心块比半透明更稳。
   */
  private badgeBg(): string {
    const tone: string = statusOf(this.item).tone;
    if (tone === 'success') {
      return '#EB34C759'; // rgba(52,199,89,0.92)
    }
    if (tone === 'failure') {
      return '#EBFF3B30'; // rgba(255,59,48,0.92)
    }
    if (tone === 'flying') {
      return '#EBF5C33B'; // rgba(245,195,59,0.92)
    }
    if (tone === 'go') {
      return '#E638BDF8'; // rgba(56,189,248,0.9)
    }
    return '#D9FFFFFF'; // rgba(255,255,255,0.85)
  }

  /** 徽章文字色：深底浅字、浅底深字（对位 vue 的 color 声明） */
  private badgeColor(): string {
    const tone: string = statusOf(this.item).tone;
    if (tone === 'failure') {
      return '#FFFFFF';
    }
    if (tone === 'flying') {
      return '#241A00';
    }
    if (tone === 'pending') {
      return '#141A26';
    }
    return '#04121F';
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

  /** 图底部渐变压黑，让正文与图片过渡自然（对位 .nl-mask 140rpx → 70vp） */
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

  /** 状态徽章：压在图片**左上角**（对位 .nl-badge 的 left/top 24rpx） */
  @Builder
  statusBadge() {
    Text(this.statusText())
      .fontSize(11) // 22rpx ÷ 2
      .fontColor(this.badgeColor())
      .padding({ left: 9, right: 9, top: 3, bottom: 3 }) // 18rpx / 6rpx ÷ 2
      .borderRadius(4) // 8rpx ÷ 2
      .backgroundColor(this.badgeBg())
      .maxLines(1)
  }

  // ============ 正文 ============

  @Builder
  bodyTitle() {
    Text(this.titleText())
      .fontSize(17) // 34rpx ÷ 2
      .fontWeight(FontWeight.Bold)
      .fontColor('#FFFFFF')
      .lineHeight(24) // 1.4 倍行高
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
  }

  /**
   * 机构 · 场地行（对位 .nl-meta）。
   *
   * 国旗与文字必须同一行：vue 里专门补了 flex 才没让国旗独占一行。
   */
  @Builder
  bodyMeta() {
    if (this.metaText().length > 0) {
      Row() {
        if (this.flagText().length > 0) {
          Text(this.flagText())
            .fontSize(11) // 34×24rpx 的旗子，emoji 用字号近似
            .margin({ right: 5 }) // 10rpx ÷ 2
            .flexShrink(0)
        }
        Text(this.metaText())
          .fontSize(12) // 24rpx ÷ 2
          .fontColor('#6B7891')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1) // 对位 flex:1 + min-width:0
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 5 }) // 10rpx ÷ 2
    }
  }

  /** 倒计时：lg 档铺满整行（对位 .nl-cd 的 margin-top 26rpx） */
  @Builder
  bodyCountdown() {
    Row() {
      Countdown({ net: strOf(this.item.net), sizeMode: 'lg', showLabel: true })
    }
    .width('100%')
    .margin({ top: 13 }) // 26rpx ÷ 2
  }

  @Builder
  bodyFoot() {
    Row() {
      Text(this.timeText())
        .fontSize(11.5) // 23rpx ÷ 2
        .fontColor('#4A5568')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // 出口用 Row 包住再 flexShrink(0)：两个「›」紧贴会被读成一个词，
      // 中间留 11vp（对位 .nl-more + .nl-more 的 margin-left 22rpx）
      Row() {
        Text('查看详情 ›')
          .fontSize(12.5) // 25rpx ÷ 2
          .fontColor('#38BDF8')
          .maxLines(1)

        if (this.more) {
          Text('更多发射 ›')
            .fontSize(12.5)
            .fontColor('#38BDF8')
            .maxLines(1)
            .margin({ left: 11 })
            .onClick(() => {
              this.onMore();
            })
        }
      }
      .flexShrink(0)
      .margin({ left: 8 })
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
    .padding({ left: 16, right: 16 })
  }

  // ============ 主卡 ============

  @Builder
  card() {
    Column() {
      Stack({ alignContent: Alignment.TopStart }) {
        this.heroImage()
        this.heroMask()

        // 徽章在左上角，12vp 内边距（对位 .nl-badge 的 left/top 24rpx）
        Column() {
          this.statusBadge()
        }
        .padding({ left: 12, top: 12 })
      }
      .width('100%')
      .height(HERO_H)

      Column() {
        this.bodyTitle()
        this.bodyMeta()
        this.bodyCountdown()
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
    .clip(true)
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
