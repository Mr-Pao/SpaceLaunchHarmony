/**
 * widget/pages/TodayImageCard.ets —— 「今日一图」服务卡片（2*4）
 *
 * 数据来源：EntryFormAbility 注入的 { imgTitle, imgDate, imgUrl } → @LocalStorageProp。
 *
 * TODO（真机风险，已知未解决）：
 *   卡片里的 Image 组件**读网络直链 URL 可能被系统拦截**（Form Kit 的网络图片
 *   需要走 formImages，把图片下载到本地后用 fd 传进去才能稳定显示）。
 *   当前按直链写，若真机上卡片是一片深色背景、图不出来，改法见下：
 *     1) 在 Ability 里 fetch 图片字节，写入 this.context.filesDir 下的临时文件；
 *     2) 打开该文件拿 fd（DEFAULT_IMAGE_FD 名字的 key 放进 bindingData）；
 *     3) formBindingData.createFormBindingData({ imgFd: fd, imgName: 'apod' })；
 *     4) 卡片端 Image(this.imgName) 由系统按 formImages 约定解析。
 *   这条路要额外的图片下载与清理逻辑，先不引入，等真机验证失败再换。
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
      // 满幅底图。imgUrl 为空时只留深色底，不渲染 Image 以免出现破图占位
      if (this.imgUrl.length > 0) {
        Image(this.imgUrl)
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
