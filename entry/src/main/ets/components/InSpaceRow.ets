/**
 * components/InSpaceRow.ets —— 「此刻在天上」横滑条
 *
 * 对位文件：pages/today/today.vue
 *   模板 119-160 行（<view class="inspace"> 整块）
 *   样式 967-1074 行（.inspace / .inspace-wrap / .inspace-row /
 *                     .inspace-fade / .inspace-nudge / .acard / .acard-img /
 *                     .acard-name / .acard-days）
 *   数据源：AstronautCard[]（astronauts-inspace.json，实测 11 条 2.2KB）
 *
 * ── 本轮按小程序对齐的改动（逐条对应审计项）──
 *   1. 副标题「在轨 N 人」→「N 人」：wxss 的 .sec-sub 就是 `{{ inSpace.length }} 人`，
 *      多出来的「在轨」二字是自创。
 *   2. 卡片去掉第四行机构名：wxss 的 .acard 只有 img / name / days 三块，
 *      agencyName 没有位置（字段仍在 model 里，只是这张卡不显示）。
 *   3. 头像改回**圆角方形**（140rpx 方图、圆角 16rpx = 8vp）：之前做成圆形，
 *      与 .acard-img 的 border-radius 不符。
 *   4. 补回右边缘那个 56×56rpx（28vp）半透明「›」圆按钮（.inspace-nudge）：
 *      它压在渐隐层上、初次滑动前可见，滑过一次就消失（对位 v-if="!astroMoved"）。
 *
 * ── 为什么滚动容器改成 List(Axis.Horizontal)，不再是 Scroll ──
 *   箭头要「点一下滑一屏」（对位 slideAstro 的 astroLeft += 550）。Scroll 得用
 *   `scrollTo({ xOffset })` 并自己记账累加偏移；List 有 `scrollToIndex(idx, true)`
 *   这个**工程内已验证过的调用**（view/VideoGalleryView.ets:229），按卡片索引推进更稳，
 *   也不会因为卡片宽度换肤而漂移。本机没装 SDK、查不到 d.ts，只用验证过的 API 是底线。
 *   List 的节点回收在十几条的量级上无收益但也无害，卡片高度固定，不受影响。
 *
 * ── 手势与「滑过了」的判定 ──
 *   小程序用 @scroll 的 scrollLeft > 8 置 astroMoved。ArkUI 的 Scroll/List 的
 *   onDidScroll 工程里没人用过（RocketView.ets:81 明确写了「不依赖未验证的 onDidScroll 签名」），
 *   故改用 onTouch：手指在横滑区内产生 Move 即视为「滑过了」，等价于 scrollLeft > 8。
 *   触屏横滑必然先产生 Move，判定时机比 onScroll 还略早，体感一致。
 *   注意 List 的 onTouch 不会吃掉 ListItem 的 onClick —— 点按没有 Move。
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
/**
 * 卡片高度：7(上) + 70(头像) + 4(名距) + 29(名两行) + 2 + 15(天数行) + 9(下)
 * ≈ 136。比原来矮 18vp，去掉了机构名那一行。
 */
const CARD_H: number = 136;
/** 右边缘渐隐层宽 130rpx ÷ 2 */
const FADE_W: number = 65;
/** 「›」圆按钮直径 56rpx ÷ 2 */
const NUDGE: number = 28;
/** 点一次箭头推进几张卡（小程序 slideAstro 是 +550rpx ≈ 2.6 张卡） */
const NUDGE_CARDS: number = 2;

@Component
export struct InSpaceRow {
  /** 在轨人员卡片列表，父级单向传入 */
  @Prop list: AstronautCard[] = [];

  /**
   * 点某张卡片，由父级决定跳哪条栈。
   * 函数类型成员不加 @Prop，普通成员 + 默认空实现。
   */
  onSelect: (item: AstronautCard) => void = () => {};

  /** 横滑控制器：关滚动条、回弹，以及箭头按钮的 scrollToIndex */
  private scroller: Scroller = new Scroller();

  /**
   * 是否已经横向滑动过（对位 today.vue 的 astroMoved）。
   * 一旦为 true，右边缘的渐隐与「›」按钮一起撤掉 —— 用户已经知道这块能滑。
   */
  @State moved: boolean = false;

  /** 箭头下一次要滚到的索引（相对当前页首，只用来越滚越靠后） */
  private advanceTo: number = 0;

  /** 空名单 → 整块不渲染 */
  private hasData(): boolean {
    return this.list.length > 0;
  }

  /** 在轨天数：字段可选，缺省按 0 天显示，不留「undefined 天」 */
  private daysOf(item: AstronautCard): number {
    const d: number | undefined = item.days;
    return d === undefined ? 0 : d;
  }

  /** 点箭头：往后推进 NUDGE_CARDS 张，夹到末条，同时让箭头退休 */
  private slide(): void {
    const last: number = this.list.length - 1;
    if (last < 0) {
      return;
    }
    const next: number = this.advanceTo + NUDGE_CARDS;
    this.advanceTo = next < last ? next : last;
    // smooth = true：对位 wxss 的 scroll-with-animation
    this.scroller.scrollToIndex(this.advanceTo, true);
    this.moved = true;
  }

  // ============ 区块头 ============

  @Builder
  header() {
    Row() {
      Text('此刻在天上')
        .fontSize(17) // 34rpx ÷ 2
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(0.5) // 1rpx ÷ 2
      // wxss 是 `{{ inSpace.length }} 人`，没有「在轨」二字
      Text(String(this.list.length) + ' 人')
        .fontSize(11) // 22rpx ÷ 2
        .fontColor('#6B7891')
        .margin({ left: 6 }) // 12rpx ÷ 2
        .maxLines(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ bottom: 7 }) // 14rpx ÷ 2
  }

  // ============ 头像 ============

  @Builder
  avatar(item: AstronautCard) {
    // 占位垫在图底下：图加载失败/地址为空时露出来的就是这个方底 + 占位符，
    // 不需要额外维护「每条是否加载失败」的状态（对位 wxss 的 .acard-ph）
    Stack() {
      Column() {
        Text('🧑‍🚀')
          .fontSize(20) // 40rpx ÷ 2
          .fontColor('#5D6A7D')
      }
      .width(AVATAR)
      .height(AVATAR)
      // 16rpx ÷ 2：方图圆角，不是圆形（wxss 的 .acard-img）
      .borderRadius(8)
      .backgroundColor('#1B2231')
      .justifyContent(FlexAlign.Center)

      if (strOf(item.img).length > 0) {
        Image(strOf(item.img))
          .width(AVATAR)
          .height(AVATAR)
          .borderRadius(8)
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
        .fontSize(11) // 22rpx ÷ 2
        .lineHeight(14.5) // 29rpx ÷ 2
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .width('100%')
        .height(29) // 58rpx ÷ 2：外文长名最多两行
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 }) // 12rpx ÷ 2

      Text('在轨 ' + String(this.daysOf(item)) + ' 天')
        .fontSize(10.5) // 21rpx ÷ 2
        .fontColor('#38BDF8')
        .width('100%')
        .maxLines(1)
        .margin({ top: 2 }) // 4rpx ÷ 2

      // 第四行机构名已删：wxss 的 .acard 只到 .acard-days 为止
    }
    .width(CARD_W)
    .height(CARD_H)
    // 7 = 14rpx ÷ 2；下 9 = 18rpx ÷ 2
    .padding({ left: 7, right: 7, top: 7, bottom: 9 })
    .borderRadius(10) // 20rpx ÷ 2
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
      .width(FADE_W)
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
      //   从右半段起手的横滑会全部被它吃掉（对应原 pointer-events:none）。
      //   箭头按钮是它的兄弟节点、在上面单独吃点击。
      .hitTestBehavior(HitTestMode.None)
  }

  // ============ 右边缘「›」箭头 ============

  /**
   * wxss 的 .inspace-nudge：56rpx 圆、半透明深底 rgba(24,32,46,0.76)、
   * 白描边 rgba(255,255,255,0.18)、32rpx 字、垂直居中偏下（margin-bottom 40rpx）。
   * 它是整块里唯一 pointer-events:auto 的元素；滑过一次就消失。
   */
  @Builder
  nudge() {
    Row() {
      Text('›')
        .fontSize(16) // 32rpx ÷ 2
        .fontColor('#C7FFFFFF') // rgba(255,255,255,0.78)
    }
    .width(NUDGE)
    .height(NUDGE)
    .borderRadius(NUDGE / 2)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
    .backgroundColor('#C218202E') // rgba(24,32,46,0.76)
    .border({ width: 1, color: '#2EFFFFFF' }) // rgba(255,255,255,0.18)
    // right 2 = 4rpx ÷ 2（wxss 的 padding-right）；bottom 20 = 40rpx ÷ 2
    .margin({ right: 2, bottom: 20 })
    .onClick(() => {
      this.slide();
    })
  }

  build() {
    // 空名单：等价于 v-if="inSpace.length" 不渲染 —— 内容全部由 if 包住，
    // 空列表时 Column 无子节点、高度为 0、margin 也为 0，不占任何视觉空间。
    // （根节点保持唯一 Column：ArkUI 对「if 直接作 build 根节点」的宽容度
    //   在各版本上不一致，用唯一根节点 + 条件 margin 更保险，效果完全等价。）
    Column() {
      if (this.hasData()) {
        this.header()

        Stack({ alignContent: Alignment.End }) {
          // scroller 必须显式绑上来，否则 this.scroller.scrollToIndex() 找不到滚动容器，
          // 箭头点了不动（静默失败、不报错，是最难查的那种）
          List({ space: 0, scroller: this.scroller }) {
            ForEach(this.list, (item: AstronautCard) => {
              ListItem() {
                this.card(item);
              }
            }, (item: AstronautCard) => String(item.id))
          }
          .width('100%')
          .height(CARD_H + 2) // 多 2vp 留给 1vp 描边，避免底边被裁
          .listDirection(Axis.Horizontal)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          // 「滑过了」判定：见文件头「手势与滑过了的判定」。
          // 只认 Move，按下/抬起都不算（点卡片也会产生 Down/Up）。
          .onTouch((event: TouchEvent) => {
            if (!this.moved && event.type === TouchType.Move) {
              this.moved = true;
            }
          })

          // 顶层：渐隐（穿透）+ 箭头（吃点击）。两者都在 moved 后一起撤掉
          if (!this.moved) {
            Stack({ alignContent: Alignment.End }) {
              this.fadeEdge()
              this.nudge()
            }
            .width(FADE_W)
            .height('100%')
          }
        }
        .width('100%')
        .height(CARD_H + 2)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: this.hasData() ? 15 : 0 }) // 30rpx ÷ 2
  }
}
