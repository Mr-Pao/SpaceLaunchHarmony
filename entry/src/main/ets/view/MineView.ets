/**
 * view/MineView.ets —— 「我的」tab（占位）
 *
 * 第二阶段替换为对位 pages/mine/mine.vue：收藏（发射 / 火箭两套独立存储）、
 * 缓存管理（调 repo.stats() / repo.clearAll() / repo.vacuum()）、版本与关于。
 * 关于页必须带 GCAT（Jonathan McDowell, CC-BY）署名 —— 这是数据源的使用条件。
 */

@Component
export struct MineView {
  build() {
    Column() {
      Column() {
        Text('我的')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .letterSpacing(1)
        Text('收藏与设置 · 待实现')
          .fontSize(11)
          .fontColor('#6B7891')
          .margin({ top: 4 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Column() {
        Text('我的')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text('待实现')
          .fontSize(13)
          .fontColor('#7A8598')
          .margin({ top: 8 })
        Text('收藏 + 缓存管理 + 版本与关于（含 GCAT 署名）')
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
