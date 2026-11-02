/**
 * view/GalleryView.ets —— 「图库」tab（占位）
 *
 * 第二阶段替换为对位 pages/gallery/gallery.vue + gallery-all：
 * 顶部 tab（image/video/earth/astro/nasa）+ 三列瀑布流 + galleryChunk 增量。
 *
 * 占位页同样带 padding bottom 92，理由见文件末尾注释。
 */

@Component
export struct GalleryView {
  build() {
    Column() {
      Column() {
        Text('图库')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .letterSpacing(1)
        Text('影像与视频 · 待实现')
          .fontSize(11)
          .fontColor('#6B7891')
          .margin({ top: 4 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      Column() {
        Text('图库')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text('待实现')
          .fontSize(13)
          .fontColor('#7A8598')
          .margin({ top: 8 })
        Text('五分类 tab + 三列瀑布流 + 分片增量加载')
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
    // ★ 92vp：避开悬浮胶囊遮挡（胶囊不是布局元素，内容区会一路铺到屏幕底）
    .padding({ bottom: 92 })
  }
}
