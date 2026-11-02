/**
 * view/RocketView.ets —— 「火箭」tab（占位）
 *
 * 第二阶段替换为对位 pages/rockets/rockets.vue：
 * 532 条火箭的分组列表（机构 → 系列 → 型号）+ 搜索。
 * 注意原项目那条教训：大集合不要塞进响应式状态（rockets 曾把 setData 顶到 734KB），
 * ArkUI 里对应做法是放在普通成员上、用版本号做 @State 依赖。
 */

@Component
export struct RocketView {
  build() {
    Column() {
      Column() {
        Text('火箭')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .letterSpacing(1)
        Text('运载火箭谱系 · 待实现')
          .fontSize(11)
          .fontColor('#6B7891')
          .margin({ top: 4 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Column() {
        Text('火箭')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text('待实现')
          .fontSize(13)
          .fontColor('#7A8598')
          .margin({ top: 8 })
        Text('机构分组 + 搜索 + 型号详情入口')
          .fontSize(11)
          .fontColor('#55617A')
          .margin({ top: 6 })
          .textAlign(TextAlign.Center)
      }
      .layoutWeight(1)
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0a0e17')
    // ★ 92vp：避开悬浮胶囊遮挡
    .padding({ bottom: 92 })
  }
}
