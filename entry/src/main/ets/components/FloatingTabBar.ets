/**
 * components/FloatingTabBar.ets —— 悬浮胶囊底部导航
 *
 * 对位小程序 custom-tab-bar/index.wxss（原生 wxml/wxss，不是 .vue）。
 * 视觉目标：胶囊**浮在页面之上**，露一圈页面底色，而不是贴底的一条栏。
 *
 * 图标：五对双态 PNG，直接复制自小程序仓库 `static/image/tabbar/`
 * （today1/today2、huojian1/huojian2、tuku1/tuku2、rocket1/rocket2、guanyu1/guanyu2），
 * 一律 81×81，落 `resources/base/media/ic_*.png` 与 `ic_*_on.png`。
 * 不用重画：小程序那套已经是「未选中灰 / 选中蓝」双态，与胶囊配色天然一致。
 *
 * 早期用「空心圆环 + 实心点」几何占位，是因为资源未到位时
 * `Image($r('app.media.ic_today'))` 找不到资源 id 会让编译直接失败，
 * 五人并行开发阶段那会挡住所有人。资源到位后已全部换掉。
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
  /** 资源名，仅用于 ForEach 的 key（必须稳定且唯一） */
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

  /**
   * 按索引取双态图标的资源。
   *
   * 为什么不用 `$r('app.media.' + name)` 拼字符串：`$r` 的参数必须是编译期字面量，
   * 拼出来的资源名不会被资源编译器识别（运行时拿到的是 undefined）。
   * 所以这里只能每个图标写一条分支 —— ArkTS 的 switch 正好适合。
   */
  private iconOf(index: number, active: boolean): Resource {
    if (index === 0) {
      return active ? $r('app.media.ic_today_on') : $r('app.media.ic_today');
    } else if (index === 1) {
      return active ? $r('app.media.ic_launch_on') : $r('app.media.ic_launch');
    } else if (index === 2) {
      return active ? $r('app.media.ic_gallery_on') : $r('app.media.ic_gallery');
    } else if (index === 3) {
      return active ? $r('app.media.ic_rocket_on') : $r('app.media.ic_rocket');
    }
    return active ? $r('app.media.ic_mine_on') : $r('app.media.ic_mine');
  }

  @Builder
  tabCell(index: number, label: string) {
    Column() {
      // 22vp：对位小程序 .ctb-icon 的 44rpx（= 22vp）。
      // 原图 81×81 是 @3x 规格，直接 objectFit(Contain) 缩放即可，不必换多倍图。
      Image(this.iconOf(index, this.currentIndex === index))
        .width(22)
        .height(22)
        .objectFit(ImageFit.Contain)
        .draggable(false)

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
    // 外层是全宽的深色渐变遮罩，胶囊只是它里面居中的一条。
    //
    // 为什么不能只给胶囊上色：胶囊只有 88% 宽，两侧各 6% 和它下方 20vp 留白
    // 都是完全透明的，页面内容滚到该区域时会直接透出来（2026-11-02 截图底部
    // 那条模糊色带就是这么来的）。加一层整屏宽、从透明渐变到页面底色的遮罩后，
    // 滚到底的内容会被自然压暗淡出，胶囊边界也就干净了。
    Column() {
      Row() {
        ForEach(this.items, (item: TabItem, index: number) => {
          this.tabCell(index, item.label);
        }, (item: TabItem, index: number) => item.icon + '_' + index)
      }
      .width('88%')
      .height(58)
      .padding({ left: 6, right: 6 })
      .borderRadius(29)
      // 深色近实底 + 背景模糊：内容从胶囊底下滚过时只剩极淡的糊化色块。
      // 原先是 rgba(30,40,60,0.62)，实测胶囊边缘会透出底下图片的彩色色带
      // （2026-11-02 截图：胶囊下半截泛蓝），所以把不透明度提到 0.95。
      .backgroundColor('#F21E283C') // rgba(30,40,60,0.95)
      .backdropBlur(24)
      // 1px 半透明白边：让胶囊在深色页面上有「玻璃边缘」的高光。
      // 注意原 wxss **没有** border，这是本次有意加的（用户 prompt 指定），
      // 对照表里已注明差异
      .border({ width: 1, color: '#1AFFFFFF' })
      .shadow({ radius: 20, color: '#80000000', offsetX: 0, offsetY: 6 })
    }
    .width('100%')
    // 顶部 28 给渐变留出渐入高度，底部 20 保持胶囊与屏幕底边的「浮起」距离
    .padding({ top: 28, bottom: 20 })
    // 渐变遮罩必须收到完全不透明：胶囊本身的 backdropBlur 会把底下内容糊化后透上来，
    // 只要遮罩末端还有一丝透明度（原先是 #F2 = 95%），底部就能看到一条模糊彩带。
    // 实测 2026-11-02：改成 #FF（100%）后底部彻底干净，胶囊的「浮起」感靠阴影维持。
    .linearGradient({
      angle: 180,
      colors: [['#000A0E17', 0.0], ['#D00A0E17', 0.42], ['#FF0A0E17', 0.72], ['#FF0A0E17', 1.0]]
    })
  }
}
