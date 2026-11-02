/**
 * components/DailyCards.ets —— 「每日一览」三卡横滑（每日一图 / 每日天文 / 每日地球）
 *
 * 对位文件：SpaceLaunch/pages/today/today.vue
 *   模板 13-57 行（<swiper class="daily-swiper"> 整块，含 swiper-item / daily-card 结构）
 *   样式 810-965 行（.daily-swiper / .daily-card / .daily-card-earth / .daily-img /
 *                     .daily-img-earth / .daily-shade / .daily-top / .daily-tag /
 *                     .daily-body / .daily-name / .daily-meta / .daily-credit /
 *                     .daily-acts / .daily-link / .daily-link-text / .daily-link-arrow /
 *                     .daily-desc，以及 963-965 行对 .daily-body 的 bottom 覆写）
 *
 * ── 单位换算（rpx ÷ 2 = vp，逐条写明，方便以后对着 wxss 复核）──
 *   轮播高 500rpx → 250vp      圆角 24rpx → 12vp
 *   margin-top 16rpx → 8vp     margin-bottom 30rpx → 15vp
 *   tag 内边距 6/16rpx → 3/8vp   tag 圆角 20rpx → 10vp   字号 21rpx → 10.5vp   字距 2rpx → 1vp
 *   tag 偏移 24rpx → 12vp
 *   文字区 left/right 26rpx → 13vp，bottom 46rpx（963 行覆写）→ 23vp
 *   标题 34rpx → 17vp（600 粗）   日期 23rpx → 11.5vp
 *   署名 20rpx → 10vp（marginTop 4rpx → 2vp）
 *   正文 21rpx → 10.5vp（marginTop 10rpx → 5vp，行高 1.42）
 *   出口行 marginTop 12rpx → 6vp；单个出口 padding 8rpx 0 8rpx 34rpx → 上/下 4vp、左 17vp
 *   出口文字/箭头 23rpx → 11.5vp，箭头 marginLeft 4rpx → 2vp
 *
 * ── 有意差异（相对小程序，逐条说明）──
 *   1. **数据来源**：小程序在页面里自己算 dailyCards；这里按任务书约定**只吃父级传入的
 *      cards，不发任何请求**。空数组时整块不渲染（对位 `v-if="dailyCards.length"`）。
 *   2. **整卡点击去掉，只保留两个出口按钮**。原模板 `@click="openCard(c)"` 加上按钮的
 *      `@click.stop`，靠 DOM 的 stopPropagation 防双触发；ArkUI 里父/子同时挂 onClick
 *      的冒泡行为与 Web 不同（同一次点击可能两边都回调），照抄会出现「点了详情又顺手
 *      触发一次卡片点击」。两个动作在视觉上就是那两个按钮，故只在按钮上挂事件，
 *      不在卡片根节点挂 onClick。
 *   3. **图片失败态**：原模板用 `dailyErr[i]` + `v-if` 移掉 <image>，用自建数组标记；
 *      这里同样维护 `@State imgErr: boolean[]`，但**整体替换数组**而不是 `imgErr[i] = true`
 *      —— ArkUI 的 @State 不观察下标赋值，只改下标不会触发重绘。
 *      失败或 src 为空时直接不生成 Image 节点，只留底色 + 压黑 + 文字，不会出现破图框。
 *   4. **渐变角度**：css 的 `to top` 对应 ArkUI `linearGradient({angle: 0})`
 *      （ArkUI 的 0° 是从下往上，与工程内 InSpaceRow.ets 的用法一致）。
 *      若真机上发现渐变上下颠倒，把 angle 改成 180 即可，两处颜色位置不用动。
 *   5. **tag 的 backdrop-blur(20rpx)** → `.backdropBlur(10)`。小程序是 -webkit 前缀的
 *      backdrop-filter，iOS 上有、部分安卓无效；ArkUI 的 backdropBlur 需要背景本身半透明
 *      才看得出来，故 tag 背景仍保留 rgba(10,14,23,0.62)。
 *   6. **激活态**：原 wxss 的 `.daily-card:active { opacity: .92 }` 与 `hover-class`
 *      是触摸反馈，ArkUI 侧本轮不做（没有可靠的「按下」视觉钩子，且卡片已不可点）。
 *   7. **正文 `max-height: 92rpx`** 在 ArkUI 里由 `maxLines(3) + lineHeight` 表达，
 *      语义等价（3 行 × 14.9 ≈ 44.7vp ≈ 89.4rpx，接近原来的 92rpx）。
 *
 * ── 用法（父级 TodayView）──
 *   DailyCards({
 *     cards: this.dailyCards,
 *     onOpen: (item: DailyCardItem) => { ... },
 *     onMore: (item: DailyCardItem) => { ... }
 *   })
 * sl 卡额外携带 launchId / net：构造后直接赋值（`c.launchId = d.id; c.net = d.net`），
 * 与小程序 dailyCards 计算属性里的字段一一对应。
 *
 * ⚠ 本文件不打控制台日志，一律走 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'DailyCards';

/** 轮播高 500rpx ÷ 2 */
const CARD_H: number = 250;
/** 圆角 24rpx ÷ 2 */
const RADIUS: number = 12;

/**
 * 一张每日卡的视图模型。
 *
 * 用普通 class：ArkTS 禁止无类型对象字面量，父级拼卡片时只能 `new DailyCardItem(...)`
 * 再补字段，不能直接丢 `{ type: 'apod', ... }`。
 *
 * 构造器只覆盖小程序 dailyCards 计算属性里**每条都有的 7 个字段**；
 * launchId / net 只有 sl 卡有值，所以留成可赋值字段而不是构造参数，
 * 否则 apod / epic 卡每次都要传两个空串（调用面变脏）。
 */
export class DailyCardItem {
  /** 'sl' | 'apod' | 'epic'：决定配图裁切方式、底色边框、以及署名是否显示 */
  type: string = '';
  /** 左上角胶囊文案：每日一图 / 每日天文 / 每日地球 */
  tag: string = '';
  /** 已经格式化好的日期文案（不是 ISO 串），由父级决定口径 */
  date: string = '';
  title: string = '';
  desc: string = '';
  src: string = '';
  /** 署名，仅 sl 卡展示（对位 `v-if="c.credit && c.type === 'sl'"`） */
  credit: string = '';
  /** sl 卡才有：查看详情时父级要的发射 id */
  launchId: string = '';
  /** sl 卡才有：发射时刻 ISO，配合 launchId 定位 */
  net: string = '';

  constructor(type: string, tag: string, date: string, title: string, desc: string,
    src: string, credit: string) {
    this.type = type;
    this.tag = tag;
    this.date = date;
    this.title = title;
    this.desc = desc;
    this.src = src;
    this.credit = credit;
  }
}

@Component
export struct DailyCards {
  /** 三张卡，父级单向传入（@Prop 会深拷贝，父级换数组即刷新） */
  @Prop cards: DailyCardItem[] = [];

  /** 点击「查看详情」。@Prop 不用于函数，普通成员 + 默认空实现 */
  onOpen: (item: DailyCardItem) => void = () => {};
  /** 点击「更多图片」 */
  onMore: (item: DailyCardItem) => void = () => {};

  /**
   * 每张图的加载失败标记，下标与 cards 对齐。
   *
   * 必须整体替换数组（ArkUI 的 @State 不观察 `arr[i] = v`），见文件头「有意差异 3」。
   */
  @State imgErr: boolean[] = [];

  // ============ 小工具 ============

  /** 该卡配图是否应该画出来：有地址 && 没失败过 */
  private showImage(index: number): boolean {
    if (index < 0 || index >= this.cards.length) {
      return false;
    }
    const item: DailyCardItem = this.cards[index];
    if (item.src.length === 0) {
      return false;
    }
    // 失败表可能比 cards 短（父级换数据后长度变化），越界即视为「没失败过」
    if (index < this.imgErr.length) {
      return !this.imgErr[index];
    }
    return true;
  }

  /** 标记第 index 张图加载失败。整表重建，保证 @State 一定能观察到 */
  private markErr(index: number): void {
    hilog.warn(DOMAIN, TAG, 'image load failed, index=' + String(index));
    const next: boolean[] = [];
    for (let i = 0; i < this.cards.length; i++) {
      const wasErr: boolean = i < this.imgErr.length ? this.imgErr[i] : false;
      next.push(i === index ? true : wasErr);
    }
    this.imgErr = next;
  }

  /** epic 卡：纯黑底 + 更淡的描边（方形地球 aspectFit 后左右留白，需要黑色兜住） */
  private isEarth(item: DailyCardItem): boolean {
    return item.type === 'epic';
  }

  // ============ 卡片 ============

  @Builder
  topTag(item: DailyCardItem) {
    // 胶囊：padding 3/8vp、圆角 10vp、10.5vp 字、1vp 字距
    Text(item.tag)
      .fontSize(10.5)
      .fontColor('#FFFFFF')
      .letterSpacing(1)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(10)
      .backgroundColor('#9E0A0E17') // rgba(10,14,23,0.62)
      .border({ width: 1, color: '#38FFFFFF' }) // rgba(255,255,255,0.22)
      .backdropBlur(10) // 20rpx ÷ 2
      // 对位 .daily-top { left: 24rpx; top: 24rpx }
      .margin({ left: 12, top: 12 })
  }

  /** 两个出口：靠右、居中，间距靠左内边距 17vp 拉开（原 34rpx），防误触 */
  @Builder
  acts(item: DailyCardItem) {
    Row() {
      Row() {
        Text('查看详情')
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor('#7DD3FC')
          .textShadow({ radius: 3, color: '#99000000', offsetX: 0, offsetY: 1 })
        Text('›')
          .fontSize(11.5)
          .fontColor('#7DD3FC')
          .lineHeight(11.5)
          .margin({ left: 2 })
          .textShadow({ radius: 3, color: '#99000000', offsetX: 0, offsetY: 1 })
      }
      .padding({ left: 17, top: 4, bottom: 4 })
      .onClick(() => {
        this.onOpen(item);
      })

      Row() {
        Text('更多图片')
          .fontSize(11.5)
          .fontWeight(FontWeight.Medium)
          .fontColor('#7DD3FC')
          .textShadow({ radius: 3, color: '#99000000', offsetX: 0, offsetY: 1 })
        Text('›')
          .fontSize(11.5)
          .fontColor('#7DD3FC')
          .lineHeight(11.5)
          .margin({ left: 2 })
          .textShadow({ radius: 3, color: '#99000000', offsetX: 0, offsetY: 1 })
      }
      .padding({ left: 17, top: 4, bottom: 4 })
      .onClick(() => {
        this.onMore(item);
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(VerticalAlign.Center)
    .margin({ top: 6 }) // 12rpx ÷ 2
  }

  /** 底部压黑：满高渐变，下 60% 从 rgba(6,9,15,0.92) 收到全透明（见「有意差异 4」） */
  @Builder
  shade() {
    // 空容器只做渐变填充：属性链直接跟在 Column() 后面（与工程内 NewsSection.ets 同写法）
    Column()
      .width('100%')
      .height('100%')
      .linearGradient({
        // angle 0 = 从下往上：位置 0 在底部，0.6 以上全透明
        angle: 0,
        colors: [
          ['#EB06090F', 0.0], // rgba(6,9,15,0.92)
          ['#0006090F', 0.6] // rgba(6,9,15,0)
        ]
      })
      // 纯装饰层，不参与命中测试（免得挡住将来可能加回的手势）
      .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  card(item: DailyCardItem, index: number) {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1 配图：epic 用 Contain（方形地球不裁边），其余 Cover 铺满
      if (this.showImage(index)) {
        Image(item.src)
          .width('100%')
          .height('100%')
          .objectFit(this.isEarth(item) ? ImageFit.Contain : ImageFit.Cover)
          .backgroundColor(this.isEarth(item) ? '#000000' : '#141A26')
          .onError(() => {
            this.markErr(index);
          })
      }

      // 2 压黑层
      this.shade()

      // 3 左上角 tag
      this.topTag(item)

      // 4 底部文字区：整块铺满 + 底部对齐，等价 css 的 absolute + bottom: 46rpx
      Column() {
        Text(item.title)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .lineHeight(22.4) // 17 × 1.32
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (item.date.length > 0) {
          Text(item.date)
            .fontSize(11.5)
            .fontColor('#ADFFFFFF') // rgba(255,255,255,0.68)
            .margin({ top: 4 }) // 8rpx ÷ 2
            .maxLines(1)
            .width('100%')
        }

        if (item.desc.length > 0) {
          Text(item.desc)
            .fontSize(10.5)
            .fontColor('#A3FFFFFF') // rgba(255,255,255,0.64)
            .lineHeight(14.9) // 10.5 × 1.42
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 5 }) // 10rpx ÷ 2
            .width('100%')
        }

        // 署名只给 sl 卡（对位 v-if="c.credit && c.type === 'sl'"）
        if (item.credit.length > 0 && item.type === 'sl') {
          Text(item.credit)
            .fontSize(10)
            .fontColor('#6BFFFFFF') // rgba(255,255,255,0.42)
            .margin({ top: 2 }) // 4rpx ÷ 2
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }

        this.acts(item)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      // 左右 13vp（26rpx）；底部 23vp（46rpx，见 today.vue 963-965 行的覆写）
      .padding({ left: 13, right: 13, bottom: 23 })
    }
    .width('100%')
    .height('100%')
    .borderRadius(RADIUS)
    .clip(true)
    .backgroundColor(this.isEarth(item) ? '#000000' : '#141A26')
    .border({
      width: 1,
      // rgba(255,255,255,0.05) → 0x0D；0.07 → 0x12
      color: this.isEarth(item) ? '#0DFFFFFF' : '#12FFFFFF'
    })
  }

  build() {
    // 空数组：等价于 v-if="dailyCards.length" 不渲染 —— Swiper 整块被 if 包住，
    // 空时 Column 无子节点、高 0、也不带 margin，不占任何视觉空间。
    // （根节点保持唯一的 Column：ArkUI 对「if 直接作 build 根节点」的宽容度各版本
    //   不一致，改用唯一根节点 + 条件子块更保险，与工程内 InSpaceRow.ets 一致。）
    Column() {
      if (this.cards.length > 0) {
        Swiper() {
          ForEach(this.cards, (item: DailyCardItem, index: number) => {
            this.card(item, index);
          }, (item: DailyCardItem, index: number) => item.type + '_' + item.src + '_' + String(index))
        }
        .width('100%')
        .height(CARD_H)
        .autoPlay(true)
        .interval(5000)
        .loop(true)
        .duration(450)
        .indicator(new DotIndicator()
          .color('rgba(255,255,255,0.28)')
          .selectedColor('#38BDF8'))
        .borderRadius(RADIUS)
        .clip(true)
        // margin-top 16rpx → 8vp；margin-bottom 30rpx → 15vp
        .margin({ top: 8, bottom: 15 })
      }
    }
    .width('100%')
  }
}
