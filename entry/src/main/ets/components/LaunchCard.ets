/**
 * components/LaunchCard.ets —— 发射列表单卡（横向紧凑卡）
 *
 * 对位小程序：components/launch-card/launch-card.vue（296 行）
 *   template   1-47    （缩略图左 / 标题 / 时间行 / 机构 + 状态右）
 *   script    50-106   （title / timeText / dateText / showDate / providerName / providerFlag / status）
 *   style    108-296  （.card / .thumb / .info / .title / .meta / .time / .date /
 *                       .foot / .flag / .provider / .status.* / .fav-mark）
 *
 * 换算：rpx ÷ 2 = vp
 *   卡片 padding 20rpx → 10vp；圆角 20rpx → 10vp；下间距 20rpx → 10vp
 *   缩略图 200rpx → 100vp（圆角 14rpx → 7vp）
 *   标题 30rpx → 15vp；相对时间 26rpx → 13vp；日期 24rpx → 12vp；机构 22rpx → 11vp；状态 21rpx → 10.5vp
 *
 * 2026-11-03 重写说明（用户实测对比「这完全不一样」）：
 *   上一版把卡片做成了**竖向大图卡**——150vp 头图 + 状态 chip 压在图上 +
 *   独立的大号秒级倒计时 + 下面再一块正文。那是我按「发射事件卡」的想象画的，
 *   与小程序完全是两种设计。小程序列表卡是**横向小卡**：左边 100vp 方图，
 *   右边三行文字（型号|任务名 → 相对时间·日期 → 国旗+机构+状态），信息密度高、
 *   一屏能看四五条。列表里**没有倒计时**（倒计时只在「下次发射」大卡上）。
 *   现在按小程序 1:1 还原。
 *
 * 有意差异（相对 launch-card.vue）：
 *   1. **国旗用 emoji 文本而不是 png**。小程序有 /static/flags/*.png，
 *      鸿蒙侧 media 目录只有 app_icon / startIcon，搬路径会 404。
 *      utils/Format.ets 的 flagOf(name) 已返回 emoji（见该函数注释）。
 *   2. **没有收藏竖条（fav-mark / card-fav）**。收藏数据层已迁（data/Favorites.ets），
 *      但列表页每次刷新要给几百条算 fav 状态，收益（一道 3vp 的竖条）与开销不匹配；
 *      详情页右上角的 ★ 才是收藏的真实入口。将来要加在这里传一个 @Prop fav: boolean 即可。
 *   3. **没有 plain（审核模式）分支**。审核暗门是微信特有的审核员环境判断，
 *      鸿蒙版上架华为市场不存在这个概念，整条分支不迁。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog（本文件实际无需日志）。
 */

import { LaunchSummary, LaunchProvider } from '../model/Common';
import {
  strOf, formatShort, relativeTime, statusOf, statusToneColor, statusToneBg,
  launchTitle, agencyLabel, flagOf
} from '../utils/Format';

/** 缩略图边长：200rpx ÷ 2 */
const THUMB: number = 100;

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

  /**
   * 缩略图。
   * 优先 imageThumb：这里只显示 100×100，用 480px 的 image 是白烧流量。
   * 两者同源同值，旧数据可能只有其中一个。
   */
  private imageUrl(): string {
    const thumb: string = strOf(this.item.imageThumb);
    if (thumb.length > 0) {
      return thumb;
    }
    return strOf(this.item.image);
  }

  /** 「电子号 | 海神调查（iQPS 发布 9）」——型号与任务名合成一行，与小程序的 launchTitle 同口径 */
  private titleText(): string {
    return launchTitle(this.item);
  }

  /** 相对时间：待发射看「几天后」，历史看「几天前」，同一个纯函数两种语境都对 */
  private timeText(): string {
    return relativeTime(strOf(this.item.net));
  }

  private dateText(): string {
    return formatShort(strOf(this.item.net));
  }

  /**
   * 是否再显示一份日期。
   * 时间待定没有日期；老任务（>30 天）relativeTime 会回退成带年份的完整时间，
   * 这时再跟一个日期就是重复信息。
   */
  private showDate(): boolean {
    const d: string = this.dateText();
    return d.length > 0 && d !== '时间待定' && d !== this.timeText();
  }

  /** 机构名：命中中文表就用中文（中国航天科技 / 蓝箭航天…） */
  private providerName(): string {
    const p: LaunchProvider | undefined = this.item.launch_service_provider;
    if (p === undefined || p === null) {
      return '';
    }
    return agencyLabel(strOf(p.name));
  }

  /** 国旗：必须用英文原名去认，中文名里没有国籍信息 */
  private providerFlag(): string {
    const p: LaunchProvider | undefined = this.item.launch_service_provider;
    if (p === undefined || p === null) {
      return '';
    }
    return flagOf(strOf(p.name));
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

  // ============ 缩略图 ============

  /** 占位块：图挂了 / 本来就没图，两种情况长得一样，不留白块 */
  @Builder
  thumbPlaceholder() {
    Column() {
      Text('🚀')
        .fontSize(28)
        .opacity(0.35)
    }
    .width(THUMB)
    .height(THUMB)
    .justifyContent(FlexAlign.Center)
    .borderRadius(7)
    .linearGradient({
      angle: 135,
      colors: [
        ['#16233A', 0.0],
        ['#0D1420', 1.0]
      ]
    })
  }

  @Builder
  thumb() {
    if (this.imageUrl().length > 0 && !this.broken) {
      Image(this.imageUrl())
        .width(THUMB)
        .height(THUMB)
        .objectFit(ImageFit.Cover)
        // 兜底底色：图片解码期间也不露白
        .backgroundColor('#0F1520')
        .borderRadius(7)
        .onError(() => {
          this.broken = true;
        })
    } else {
      this.thumbPlaceholder()
    }
  }

  // ============ 右侧文字区 ============

  /** 时间行：相对时间 · 日期 */
  @Builder
  metaRow() {
    Row() {
      Text(this.timeText())
        .fontSize(13) // 26rpx ÷ 2
        .fontColor('#38BDF8')
        .maxLines(1)

      if (this.showDate()) {
        Text('·')
          .fontSize(11) // 22rpx ÷ 2
          .fontColor('#3D4A5C')
          .margin({ left: 5, right: 5 })

        Text(this.dateText())
          .fontSize(12) // 24rpx ÷ 2
          .fontColor('#6B7891')
          .maxLines(1)
      }
    }
    .alignItems(VerticalAlign.Center)
    .margin({ top: 5 })
  }

  /** 脚行：国旗 + 机构（可省略）+ 状态（永远靠右、不换行） */
  @Builder
  footRow() {
    Row() {
      if (this.providerFlag().length > 0) {
        Text(this.providerFlag())
          .fontSize(9)
          .margin({ right: 4 })
      }

      if (this.providerName().length > 0) {
        Text(this.providerName())
          .fontSize(11) // 22rpx ÷ 2
          .fontColor('#5D6A7D')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // layoutWeight(1) 等价于小程序的 flex:1 + min-width:0：
          // 不给权重的话长机构名会把状态 chip 顶出卡片
          .layoutWeight(1)
          .margin({ right: 7 })
      } else {
        Blank()
      }

      Text(this.statusText())
        .fontSize(10.5) // 21rpx ÷ 2
        .fontColor(this.statusColor())
        .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
        .borderRadius(3) // 6rpx ÷ 2
        .backgroundColor(this.statusBg())
        .maxLines(1)
        .flexShrink(0)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4 })
  }

  @Builder
  info() {
    Column() {
      Text(this.titleText())
        .fontSize(15) // 30rpx ÷ 2
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .lineHeight(21) // 15 × 1.4
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      this.metaRow()

      Blank()

      this.footRow()
    }
    .layoutWeight(1)
    .height(THUMB) // 与缩略图等高；中间 Blank 把脚行压到底，标题只有一行时状态也不浮在中间
    .alignItems(HorizontalAlign.Start)
    .margin({ left: 11 }) // 22rpx ÷ 2
  }

  build() {
    Row() {
      this.thumb()
      this.info()
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(10) // 20rpx ÷ 2
    .backgroundColor(CARD_BG)
    .borderRadius(10) // 20rpx ÷ 2
    .border({ width: 1, color: '#0DFFFFFF' }) // rgba(255,255,255,0.05)
    // .overflow(Overflow.Hidden) 在 RowAttribute 上不存在，圆角裁切只能用 clip
    .clip(true)
    .onClick(() => {
      this.onSelect(this.item);
    })
  }
}
