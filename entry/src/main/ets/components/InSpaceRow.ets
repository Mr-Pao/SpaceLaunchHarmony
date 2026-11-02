/**
 * components/InSpaceRow.ets —— 「此刻在天上」横滑条
 *
 * 对位文件：pages/today/today.vue
 *   模板 124-160 行（<view class="inspace"> 整块）
 *   样式 967-1074 行（.inspace / .inspace-wrap / .inspace-scroll / .inspace-row /
 *                     .inspace-fade / .inspace-nudge / .acard / .acard-img /
 *                     .acard-name / .acard-days）
 * 数据源：AstronautCard[]（astronauts-inspace.json，实测 11 条 2.2KB）
 *
 * ── 滚动容器为什么选 Scroll + Row，而不是 List(Axis.Horizontal) ──
 *   1. 小程序这一块就是 scroll-view + 一行 flex，Scroll+Row 是逐节点对位，
 *      不存在 List 的 item 复用/回收语义差异；
 *   2. 在轨人数是个位数~十几条，List 的虚拟化收益为零，
 *      而 List 还要每个卡片再套一层 ListItem，多一层无谓的布局节点；
 *   3. 渐隐层要压在滚动区**之上**，Stack 直接叠 Scroll 最省事；
 *      List 也可以，但 List 自带 contentsize/占位逻辑，横滑时末卡右留白不好控。
 *   结论：Scroll(Scroller) + Row。
 *
 * ── 有意差异（相对小程序）──
 *   1. 头像：小程序是 140rpx 正方形、圆角 16rpx（8vp）；本实现按要求做**圆形**
 *      （borderRadius = 35 = 半边长），ImageFit.Cover。
 *   2. 卡片内边距：wxss 是 14rpx 14rpx 18rpx（7/7/9vp），任务书要求 10vp。
 *      但卡片固定宽 168rpx→84vp，若左右各留 10vp，内容区只剩 64vp，
 *      装不下 140rpx→70vp 的头像（会溢出）。故**按 wxss 取 7vp**，
 *      下边距保留 9vp；圆角按任务书 12vp（wxss 是 20rpx=10vp，纯视觉、不影响布局）。
 *   3. 卡片点击态：小程序有 hover-class（底色变 #1B2231）+ 跳宇航员详情。
 *      本组件自己不做跳转，但**向父级抛 onSelect 回调**（2026-11-03 补：
 *      AstronautView 落地后才接上；此前无详情页时是纯静态卡片）。
 *   4. 右边缘只保留渐隐，**去掉那个「›」箭头**：任务书要求整层
 *      hitTestBehavior(HitTestMode.None)，而箭头在原实现里是 pointer-events:auto
 *      的可点元素；两者共存会要么箭头吃手势、要么箭头点不动，不如只留渐隐。
 *      对应的 astroLeft / slideAstro / onAstroScroll 逻辑一并省略。
 *   5. 多显示一行「所属机构」（item.agencyName）：wxss 里没有这一行，
 *      但 AstronautCard 带该字段、任务书要求显示。
 *   6. 头像缺失时用圆形底 + 🧑‍🚀 占位，对位 wxss 的 .acard-ph。
 *
 * 空列表：整个区块不渲染（对应 wxss 的 v-if="inSpace.length"）。
 *
 * ⚠ 本文件不使用 console.*，目前无需日志。
 */

import { AstronautCard } from '../model/Astronaut';
import { strOf } from '../utils/Format';

/** 卡片固定宽度 168rpx ÷ 2 */
const CARD_W: number = 84;
/** 头像 140rpx ÷ 2 */
const AVATAR: number = 70;
/** 卡片间距 16rpx ÷ 2（wxss 的 margin-right） */
const CARD_GAP: number = 8;
/** 卡片高度（内容量估算：7+70+4+29+2+15+1+14 上下内边距与文本行高，留 3vp 余量） */
const CARD_H: number = 154;

@Component
export struct InSpaceRow {
  /** 在轨人员卡片列表，父级单向传入 */
  @Prop list: AstronautCard[] = [];

  /**
   * 点某张卡片。早期没有详情页所以刻意不加 onClick（避免假按钮），
   * 现在 AstronautView 已就位，补上回调由父级决定跳哪条栈。
   */
  onSelect: (item: AstronautCard) => void = () => {};

  /** 横滑控制器。当前只用于关闭滚动条/回弹，保留引用方便以后做「滑到末尾」 */
  private scroller: Scroller = new Scroller();

  /** 空名单 → 整块不渲染 */
  private hasData(): boolean {
    return this.list.length > 0;
  }

  /** 在轨天数：字段可选，缺省按 0 天显示，不留「undefined 天」 */
  private daysOf(item: AstronautCard): number {
    const d: number | undefined = item.days;
    return d === undefined ? 0 : d;
  }

  // ============ 区块头 ============

  @Builder
  header() {
    Row() {
      Text('此刻在天上')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(0.5)
      Text('在轨 ' + String(this.list.length) + ' 人')
        .fontSize(11)
        .fontColor('#6B7891')
        .margin({ left: 6 })
        .maxLines(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ bottom: 7 })
  }

  // ============ 头像 ============

  @Builder
  avatar(item: AstronautCard) {
    // 占位垫在图底下：图加载失败/地址为空时露出来的就是这个圆底 + 占位符，
    // 不需要额外维护「每条是否加载失败」的状态（对位 wxss 的 .acard-ph）
    Stack() {
      Column() {
        Text('🧑‍🚀')
          .fontSize(20)
          .fontColor('#5D6A7D')
      }
      .width(AVATAR)
      .height(AVATAR)
      .borderRadius(AVATAR / 2)
      .backgroundColor('#1B2231')
      .justifyContent(FlexAlign.Center)

      if (strOf(item.img).length > 0) {
        Image(strOf(item.img))
          .width(AVATAR)
          .height(AVATAR)
          .borderRadius(AVATAR / 2)
          .objectFit(ImageFit.Cover)
      }
    }
    .width(AVATAR)
    .height(AVATAR)
  }

  // ============ 单张卡片 ============

  @Builder
  card(item: AstronautCard) {
    Column() {
      this.avatar(item)

      Text(strOf(item.name))
        .fontSize(11)
        .lineHeight(14.5)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .width('100%')
        .height(29) // 58rpx ÷ 2：外文长名最多两行
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 })

      Text('在轨 ' + String(this.daysOf(item)) + ' 天')
        .fontSize(10.5)
        .fontColor('#38BDF8')
        .width('100%')
        .maxLines(1)
        .margin({ top: 2 })

      Text(strOf(item.agencyName))
        .fontSize(10)
        .fontColor('#55617A')
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 1 })
    }
    .width(CARD_W)
    .height(CARD_H)
    // 7 = 14rpx ÷ 2；下 9 = 18rpx ÷ 2（见文件头「有意差异 2」）
    .padding({ left: 7, right: 7, top: 7, bottom: 9 })
    .borderRadius(12)
    .backgroundColor('#141A26')
    // 对位 border: 1rpx solid rgba(255,255,255,0.07) → 0x12FFFFFF
    .border({ width: 1, color: '#12FFFFFF' })
    .alignItems(HorizontalAlign.Start)
    .margin({ right: CARD_GAP })
    .onClick(() => {
      this.onSelect(item);
    })
  }

  // ============ 右边缘渐隐 ============

  @Builder
  fadeEdge() {
    Column()
      .width(65) // 130rpx ÷ 2
      .height('100%')
      .linearGradient({
        // ArkUI 里 angle 0 是从下到上，90 = 从左到右，与 css 的 to right 一致
        angle: 90,
        colors: [
          ['#000A0E17', 0.0],
          ['#DB0A0E17', 0.58], // rgba(10,14,23,0.86)
          ['#0A0E17', 1.0]
        ]
      })
      // ★ 必须穿透触摸：这一层压在横滑列表右端，若参与命中测试，
      //   从右半段起手的横滑会全部被它吃掉（对应原 pointer-events:none）
      .hitTestBehavior(HitTestMode.None)
  }

  build() {
    // 空名单：等价于 v-if="inSpace.length" 不渲染 —— 内容全部由 if 包住，
    // 空列表时 Column 无子节点、高度为 0、margin 也为 0，不占任何视觉空间。
    // （根节点保持唯一的 Column：ArkUI 对「if 直接作 build 根节点」的宽容度
    //   在各版本上不一致，用唯一根节点 + 条件 margin 更保险，效果完全等价。）
    Column() {
      if (this.hasData()) {
        this.header()

        Stack({ alignContent: Alignment.TopEnd }) {
          Scroll(this.scroller) {
            Row() {
              ForEach(this.list, (item: AstronautCard) => {
                this.card(item);
              }, (item: AstronautCard) => String(item.id))
            }
            .alignItems(VerticalAlign.Top)
          }
          .width('100%')
          .height(CARD_H + 2) // 多 2vp 留给 1vp 描边，避免底边被裁
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)

          this.fadeEdge()
        }
        .width('100%')
        .height(CARD_H + 2)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: this.hasData() ? 15 : 0 })
  }
}
