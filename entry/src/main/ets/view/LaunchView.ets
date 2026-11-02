/**
 * view/LaunchView.ets —— 「发射」tab（占位）
 *
 * 第二阶段替换为对位 pages/index/index.vue 的发射总览：
 * 日历条 + 筛选（机构/年份/状态）+ 分页列表 + 触底加载 upcomingMore。
 *
 * 占位页也遵守两条工程约定，方便将来直接换内容不动外壳：
 *   1) 根容器 padding bottom 92（见下）；
 *   2) 顶部标题区结构与 TodayView 一致（大标题 + 右侧说明），换掉中间内容即可。
 */

@Component
export struct LaunchView {
  build() {
    Column() {
      // —— 顶部标题栏 ——
      Column() {
        Text('发射')
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .letterSpacing(1)
        Text('全部发射任务 · 待实现')
          .fontSize(11)
          .fontColor('#6B7891')
          .margin({ top: 4 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      // —— 占位内容 ——
      Column() {
        Text('发射')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text('待实现')
          .fontSize(13)
          .fontColor('#7A8598')
          .margin({ top: 8 })
        Text('日历条 + 筛选 + 分页列表 + 触底加载 upcomingMore')
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
    // ★ 必须留 92vp 底部内边距：
    //   FloatingTabBar 是浮在内容之上的（Stack 底部对齐），不是占位的布局元素，
    //   所以 Tabs 的内容区一直延伸到屏幕最底部。不留这个 padding，
    //   列表最后一项 / 居中占位内容就会被胶囊压住，而且滚到底也露不出来。
    //   92 = 胶囊高 58 + 底部 margin 20 + 14 的呼吸余量
    .padding({ bottom: 92 })
  }
}
