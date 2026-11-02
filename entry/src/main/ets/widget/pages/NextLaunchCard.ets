/**
 * widget/pages/NextLaunchCard.ets —— 「下次发射」服务卡片（2*2）
 *
 * 数据来源：EntryFormAbility.onAddForm / onUpdateForm 通过
 *   formBindingData.createFormBindingData({ mission, dd, hh, mm, stamp, status })
 * 注入到卡片自己的 LocalStorage，页面用 @LocalStorageProp 单向读取。
 *
 * 为什么不用 @State：
 *   卡片进程里的页面是「被喂数据」的一方，@State 的初值会盖掉注入值，
 *   而 @LocalStorageProp 是「外部赋值 → 页面重渲染」的正确方向。
 *
 * 卡片组件白名单（39 个）里没有 Swiper / Scroll / Grid / List 的横向滚动能力，
 * 也没有 setTimeout / setInterval —— 所以倒计时是**按更新周期刷新**的静态快照，
 * 不在这里跑秒级定时器（写了也编译能过但运行时不生效）。
 *
 * 注意：两个卡片页会编译进同一个 widget.abc，**类型/接口不能同名**
 * （同名会被当成 declaration merging，报 arkts-no-decl-merging）。
 */

/** postCardAction 的参数：显式 class（ArkTS 不允许无类型对象字面量） */
class NextLaunchParams {
  targetPage: string = 'launch';
}

class NextLaunchAction {
  action: string = 'router';
  abilityName: string = 'EntryAbility';
  params: NextLaunchParams = new NextLaunchParams();
}

@Entry
@Component
struct NextLaunchCard {
  @LocalStorageProp('mission') mission: string = '—';
  @LocalStorageProp('dd') dd: string = '--';
  @LocalStorageProp('hh') hh: string = '--';
  @LocalStorageProp('mm') mm: string = '--';
  @LocalStorageProp('stamp') stamp: string = '';
  @LocalStorageProp('status') status: string = '等待数据';

  /** 卡片主色，与 App 内 #38BDF8 的强调色一致 */
  private readonly ACCENT: string = '#38BDF8';
  private readonly BG: string = '#0A0E17';
  private readonly TEXT_MAIN: string = '#FFFFFF';
  private readonly TEXT_SUB: string = '#7A8598';

  /** 点击卡片 → 拉起 App 并落到「发射」tab */
  private goLaunch(): void {
    postCardAction(this, new NextLaunchAction());
  }

  build() {
    Column() {
      // 顶部：任务名，最多两行
      Text(this.mission)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.TEXT_MAIN)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)

      Blank()

      // 中部：大号倒计时
      Row() {
        Text(this.dd)
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ACCENT)
        Text(' 天 ')
          .fontSize(12)
          .fontColor(this.TEXT_SUB)
        Text(this.hh)
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ACCENT)
        Text(':')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ACCENT)
        Text(this.mm)
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.ACCENT)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Start)

      Blank()

      // 底部：发射时间 / 状态小字
      Row() {
        Text(this.stamp.length > 0 ? this.stamp : '时间待定')
          .fontSize(10)
          .fontColor(this.TEXT_SUB)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.status)
          .fontSize(10)
          .fontColor(this.ACCENT)
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor(this.BG)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.goLaunch();
    })
  }
}
