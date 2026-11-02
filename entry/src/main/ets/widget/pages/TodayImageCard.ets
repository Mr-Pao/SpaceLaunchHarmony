/**
 * widget/pages/TodayImageCard.ets —— 「今日一图」服务卡片（2*4）
 *
 * 数据来源：EntryFormAbility 注入的 LocalStorage → @LocalStorageProp。
 *
 * ⚠ 图片为什么不用 URL：
 *   卡片进程（Form Kit 的渲染 sandbox）**没有网络权限**，Image('https://...')
 *   在桌面上恒为一块纯黑 —— 2026-11-02 桌面实测：标题「火星上的长云」和日期
 *   2026-11-02 正常，图区全黑。官方通路只有 formImages：
 *     Ability 侧把图片下载到 filesDir，openSync 拿 fd，
 *     createFormBindingData({ formImages: { img: fd } })；
 *     卡片侧写 Image(this.img)，系统会把 'img' 这个键解析成那张图。
 *   所以这里的 imgUrl 字段**已废弃**，仅保留兼容（旧版 Ability 可能还在喂它）。
 *
 * 注意：两个卡片页会编译进同一个 widget.abc，**类型/接口不能同名**
 * （同名会被当成 declaration merging，报 arkts-no-decl-merging）。
 */

/** postCardAction 的参数：显式 class（ArkTS 不允许无类型对象字面量） */
class TodayImageParams {
  targetPage: string = 'today';
}

class TodayImageAction {
  action: string = 'router';
  abilityName: string = 'EntryAbility';
  params: TodayImageParams = new TodayImageParams();
}

@Entry
@Component
struct TodayImageCard {
  @LocalStorageProp('imgTitle') imgTitle: string = '今日一图';
  @LocalStorageProp('imgDate') imgDate: string = '';
  /**
   * 图片键：由 formImages 注入。
   *
   * 值是 Ability 侧 formImages 里的 key 名（固定 'img'），**不是 URL 也不是本地路径**。
   * 系统在把 bindingData 交给卡片之前已经把它换成了可渲染的图片资源。
   * 没有图时它是空串，此时不渲染 Image，避免出现破图占位。
   */
  @LocalStorageProp('img') img: string = '';
  /** @deprecated 卡片进程无网络权限，URL 加载不出来；保留只为兼容旧版 Ability */
  @LocalStorageProp('imgUrl') imgUrl: string = '';

  private readonly BG: string = '#0A0E17';
  private readonly TEXT_MAIN: string = '#FFFFFF';
  private readonly TEXT_SUB: string = '#A8B3C4';

  /** 点击卡片 → 拉起 App 的「今日」页（每日一图在今日页首屏） */
  private goToday(): void {
    postCardAction(this, new TodayImageAction());
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 满幅底图。img 为空时只留深色底
      if (this.img.length > 0) {
        // 不要加 .draggable(false)：Form Kit 卡片不支持该属性，编译期直接报 11706006
        Image(this.img)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      }

      // 底部压黑条：渐变从透明到不透明，保证白字可读
      Column() {
        Text(this.imgTitle)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.TEXT_MAIN)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        Text(this.imgDate)
          .fontSize(10)
          .fontColor(this.TEXT_SUB)
          .maxLines(1)
          .margin({ top: 2 })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 18, bottom: 10 })
      .linearGradient({
        angle: 180,
        colors: [['#00000000', 0.0], ['#CC0A0E17', 0.55], ['#F20A0E17', 1.0]]
      })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.BG)
    .clip(true)
    .onClick(() => {
      this.goToday();
    })
  }
}
