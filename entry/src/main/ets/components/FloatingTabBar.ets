/**
 * components/FloatingTabBar.ets —— 悬浮胶囊底部导航
 *
 * 对位小程序 custom-tab-bar/index.wxss（原生 wxml/wxss，不是 .vue）。
 * 视觉目标：胶囊**浮在页面之上**，露一圈页面底色，而不是贴底的一条栏。
 *
 * ⚠ 需要补齐的 5 个图标（同事正在配）。放到
 *   entry/src/main/resources/base/media/
 *     ic_today.png    ic_launch.png   ic_gallery.png
 *     ic_rocket.png   ic_mine.png
 *   建议尺寸 96×96（@3x，即 32vp 显示）；若要多倍图，用
 *   media/ic_today.png + media/ic_today@2x.png 这种目录约定。
 *
 * 第一阶段**故意不用 Image**：资源没到位时 Image($r('app.media.ic_today'))
 * 会让编译直接失败（找不到资源 id），五人并行开发阶段会挡住所有人。
 * 所以这里用「几何图形 + 文字」的临时方案：
 *   选中   → 实心圆点（强调色）+ 细描边外环 + 文字强调色加粗
 *   未选中 → 空心圆环（次要色）+ 文字次要色
 * 图标补齐后，把 iconOf() 里的 Circle 换成
 *   Image(this.currentIndex === i ? $r('app.media.ic_today_on') : $r('app.media.ic_today'))
 *   .width(22).height(22).objectFit(ImageFit.Contain)
 * 即可，其余布局不用动。
 *
 * 底部安全区：现在固定 margin bottom 20。有手势条的机型（以及横屏、
 * 折叠屏展开）需要动态读避让区：
 *   const avoid = window.getLastWindow(getContext(this)).getWindowAvoidArea(
 *     window.AvoidAreaType.TYPE_SYSTEM)   // 底部手势条约 24~34vp
 *   bottom = 20 + px2vp(avoid.bottomRect.height)
 * 第一阶段先不引，避免在没真机的情况下写出取不到值的代码。
 */

/** 一个 tab 的静态描述。用普通 class 而不是对象字面量：ArkTS 不允许无类型的对象字面量 */
class TabItem {
  label: string = '';
  /** 图标资源名，仅用于日志/将来替换，第一阶段不参与渲染 */
  icon: string = '';

  constructor(label: string, icon: string) {
    this.label = label;
    this.icon = icon;
  }
}

@Component
export struct FloatingTabBar {
  /** 当前选中项，父级单向传入 */
  @Prop currentIndex: number = 0;
  /** 点击回调。@Prop 不用于函数，这里用普通成员 + 默认空实现 */
  onSelect: (index: number) => void = () => {};

  /** 五项顺序必须与 Index.ets 的 TabContent 顺序严格一致 */
  private items: TabItem[] = [
    new TabItem('今日', 'ic_today'),
    new TabItem('发射', 'ic_launch'),
    new TabItem('图库', 'ic_gallery'),
    new TabItem('火箭', 'ic_rocket'),
    new TabItem('我的', 'ic_mine')
  ];

  /** 未选中：空心圆环（代替图标） */
  @Builder
  idleDot() {
    Circle({ width: 18, height: 18 })
      .fill(Color.Transparent)
      .stroke('#7C8AA5')
      .strokeWidth(1.5)
  }

  /** 选中：细描边外环（代替图标），与下面的实心点叠成「靶心」 */
  @Builder
  activeRing() {
    Circle({ width: 18, height: 18 })
      .fill(Color.Transparent)
      .stroke('#38BDF8')
      .strokeWidth(1.5)
  }

  @Builder
  tabCell(index: number, label: string) {
    Column() {
      Stack() {
        if (this.currentIndex === index) {
          this.activeRing()
          Circle({ width: 7, height: 7 }).fill('#38BDF8')
        } else {
          this.idleDot()
        }
      }
      .width(22)
      .height(22)

      Text(label)
        .fontSize(10)
        .lineHeight(14)
        .margin({ top: 2 })
        .fontWeight(this.currentIndex === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.currentIndex === index ? '#38BDF8' : '#7C8AA5')
    }
    // 单元格占满剩余宽度，内部居中；高度 = 胶囊 58 - 上下留白 8*2 = 42
    .layoutWeight(1)
    .height(42)
    .margin({ left: 4, right: 4 })
    .borderRadius(21)
    // 选中态淡蓝底，对位 wxss 的 .ctb-on { background: rgba(56,189,248,0.16) }
    .backgroundColor(this.currentIndex === index ? '#2938BDF8' : Color.Transparent)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      // 点当前项也回调：让父级统一处理，避免「点了没反应」时还要在外面判重
      this.onSelect(index);
    })
  }

  build() {
    Column() {
      Row() {
        ForEach(this.items, (item: TabItem, index: number) => {
          this.tabCell(index, item.label);
        }, (item: TabItem, index: number) => item.icon + '_' + index)
      }
      .width('100%')
      .height(58)
      .padding({ left: 6, right: 6 })
      .borderRadius(29)
      // 半透明深色 + 背景模糊 = 内容从胶囊底下滚过时能看到糊化的色块，
      // 这是小程序里 backdrop-filter 的效果，ArkUI 用 backdropBlur 对位
      .backgroundColor('#9E1E283C') // rgba(30,40,60,0.62)
      .backdropBlur(24)
      // 1px 半透明白边：让胶囊在深色页面上有「玻璃边缘」的高光。
      // 注意原 wxss **没有** border，这是本次有意加的（用户 prompt 指定），
      // 对照表里已注明差异
      .border({ width: 1, color: '#1AFFFFFF' })
      .shadow({ radius: 20, color: '#80000000', offsetX: 0, offsetY: 6 })
    }
    .width('88%')
    // 底部间距 20：胶囊与屏幕底边留白，形成「浮起来」的观感（原 wxss 是 12rpx+安全区）。
    // 有手势条的机型要改成动态计算，见文件头注释
    .margin({ bottom: 20 })
  }
}
