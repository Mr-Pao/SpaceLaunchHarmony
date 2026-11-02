/**
 * view/PhotoDetailView.ets —— 全屏看图器（沉浸式单图）
 *
 * 对位小程序 components/launch-detail/launch-photo.vue（330 行）的「看图」部分。
 * 原实现是「横滑相册 + 两层图（contain 完整 / cover 裁切）随滚动交叉 + 底部
 * 查看发射详情按钮」；鸿蒙这一版按任务书收窄成**单图全屏浏览**：
 *   · 没有相册数据（契约只有 url / title），所以不做左右换图；
 *   · 不随滚动收缩（它是独立 NavDestination 页，不是压在详情页上的浮层），
 *     两层交叉的 fillOpacity 逻辑随之消失，只留 contain 一层；
 *   · 底部按钮换成信息条（标题 + 来源），跳转由宿主页负责，这里不 push。
 *
 * 与小程序的核心差异是**手势**：小程序靠 touchstart/move/end 手写横向位移，
 * 鸿蒙这版要的是「相册类 App 的原生手感」，所以拆成四个独立手势：
 *   1) PinchGesture       双指捏合，1x ~ 4x
 *   2) TapGesture(count 2) 双击 1x <-> 2.5x
 *   3) PanGesture(图片上)  放大后单指拖动，边界按 (scale-1)*viewport/2 收
 *   4) PanGesture(整页)    1 倍时下滑关闭（跟手位移 + 降透明度，超阈值 pop）
 *
 * ── 与任务书的一处取舍（重要，复核请看这里）──
 * 任务书写「scale === 1 时不挂 PanGesture」。ArkTS 的 `.gesture()` 无法条件化：
 *   唯一能按状态切换挂载的办法是用 `if (放大) { Stack(){图}.gesture(拖动) } else { ... }`，
 *   但那会让 Image 节点在跨越 1 倍时被销毁重建，2000px 原图重新解码，肉眼可见地闪一下
 *   （弱网下更明显）。所以这里改成「始终挂载，回调首行短路」：
 *   `if (this.zoomScale <= 1) { return; }` —— 1 倍时这个 PanGesture 不做任何位移、
 *   不改任何状态，效果上等价于没挂；下滑关闭走的是**整页**的 parallelGesture，
 *   二者方向与职责互不重叠（图片内 All / 整页 Vertical）。见 imageLayer() 里的注释。
 *
 * ── 其它约定 ──
 *   · 底色是纯黑 #000000，不是 App 主色 #0A0E17：看图器要衬图，不用背景色。
 *   · 不铺星空、不留 tab 的 92vp 底边距（它不在 tab 内）。
 *   · 页面自己负责返回：Nav.pop()。不 push 新页面。
 *   · 本文件不使用 console.*，也不碰 AppStorage。
 */

import { display } from '@kit.ArkUI';
import { Nav } from '../routes/Nav';
import { fullImageOf } from '../utils/Media';

// ============ 颜色 ============

/** 看图器底色：纯黑最不抢图片的注意力 */
const BG: string = '#000000';
/** 主文字（标题、返回） */
const TEXT_MAIN: string = '#FFFFFF';
/** 次要文字（来源说明、badge） */
const TEXT_SUB: string = '#A7B4C7';
/** 工具条底色：半透明黑，压在图上也不切断画面 */
const BAR_BG: string = '#CC000000';

// ============ 缩放 ============

/** 常态缩放：1 倍（整图完整显示） */
const MIN_ZOOM: number = 1;
/** 最大缩放：4 倍（再大就只剩马赛克） */
const MAX_ZOOM: number = 4;
/** 捏合过程中的超调下限：允许捏到 0.8 再回弹，手感比硬卡在 1 更接近相册 */
const PINCH_FLOOR: number = 0.8;
/** 捏合过程中的超调上限：4.4 = 4 之外留一点回弹余量 */
const PINCH_CEIL: number = 4.4;
/** 双击放大的档位 */
const DOUBLE_ZOOM: number = 2.5;

/**
 * 判定「是拖动不是点击」的最小位移（vp）。
 * 太小会把手指微抖当成拖动，点一下切不掉工具栏；太大则拖动起步发涩。
 */
const PAN_SLOP: number = 12;

// ============ 下滑关闭 ============

/** 下滑超过这个距离就关（vp）。120 约等于单手拇指自然下滑的一小段 */
const DISMISS_LIMIT: number = 120;
/** 位移到这个值透明度降到最低（分母） */
const DISMISS_FADE_SPAN: number = 400;
/** 透明度最多降这么多，留 40% 让用户还看得见拖的是哪张图 */
const DISMISS_MAX_FADE: number = 0.6;

// ============ 动画 ============

/** 缩放 / 位移的过渡时长 */
const ANIM_MS: number = 200;
/** 顶底栏淡入淡出时长，比缩放短一点，显得利落 */
const CHROME_ANIM_MS: number = 160;

// ============ 图片加载状态 ============

const LOAD_LOADING: number = 0;
const LOAD_DONE: number = 1;
const LOAD_FAIL: number = 2;

/** 取不到屏幕尺寸时的保守回退值（只影响放大后的可拖动范围） */
const DEFAULT_VIEW_W: number = 360;
const DEFAULT_VIEW_H: number = 640;

@Component
export struct PhotoDetailView {
  /** 当前图片地址（缩略图或原图都行，组件内部优先升到原图） */
  @Prop @Watch('onUrlChange') url: string = '';
  /** 图注 / 标题 */
  @Prop title: string = '';

  // ============ 缩放与位移状态 ============

  /**
   * 当前缩放倍数。
   * ⚠ 不能叫 `scale`：那是内置属性方法名，组件成员与之同名会编译失败。
   */
  @State zoomScale: number = MIN_ZOOM;
  /** 放大后的横向平移（vp） */
  @State panX: number = 0;
  /** 放大后的纵向平移（vp） */
  @State panY: number = 0;
  /** 下滑关闭时的跟手位移（vp），只在 zoomScale === 1 时有值 */
  @State dismissY: number = 0;

  // ============ 界面状态 ============

  /** 顶/底工具条是否可见（单击图片切换） */
  @State chromeVisible: boolean = true;
  /** 实际渲染的图片地址（先原图，失败退回缩略图） */
  @State imgSrc: string = '';
  /** LOAD_LOADING / LOAD_DONE / LOAD_FAIL */
  @State loadState: number = LOAD_LOADING;
  /** 当前 imgSrc 是不是「推导出来的原图」—— 失败回退缩略图时置 false */
  @State usingFull: boolean = true;

  /** 视口宽高（vp），用来算放大后的拖动边界 */
  @State viewW: number = DEFAULT_VIEW_W;
  @State viewH: number = DEFAULT_VIEW_H;

  /**
   * 两个「是否正在拖动」的标记，只服务动画时长：
   * 拖动中必须 duration 0（跟手不能有补间），松手才用 200ms 回弹。
   * 分开两个是因为放大拖动与下滑关闭是两条独立手势，不能互相把对方的标记清掉。
   */
  @State dragZoom: boolean = false;
  @State dragDismiss: boolean = false;

  // ============ 手势内部基准（不参与渲染，用普通字段即可）============

  /** 捏合开始时的缩放倍数：每次 update 都基于它乘手势比例，避免误差累积 */
  private pinchBase: number = MIN_ZOOM;
  /** 拖动开始时的平移量：同上，用「基准 + 累计位移」而不是逐帧累加 */
  private panBaseX: number = 0;
  private panBaseY: number = 0;
  /** 捏合进行中：此时单指 PanGesture 要闭嘴，否则两指缩放会被拖动手势抢走 */
  private pinching: boolean = false;

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.imgSrc = this.resolveSrc();
  }

  /**
   * url 变了（宿主复用同一个 NavDestination 换图）：
   * 所有手势状态必须归零，否则新图会带着上一张的缩放/位移出现。
   */
  onUrlChange(): void {
    this.usingFull = true;
    this.loadState = LOAD_LOADING;
    this.zoomScale = MIN_ZOOM;
    this.panX = 0;
    this.panY = 0;
    this.dismissY = 0;
    this.imgSrc = this.resolveSrc();
  }

  // ============ 工具方法 ============

  /**
   * 看图器优先显示原图：COS 上缩略图是 space-img/<hash>.<ext>，
   * 原图是同一 hash 的 _2000 版本（见 utils/Media.ets 的注释）。
   * 不是可推导的镜像地址（APOD 原始直链、信息图 _1080 等）时 fullImageOf 返回空串，
   * 这时就用 url 本身 —— 千万别盲目拼 _2000，会 404。
   */
  private resolveSrc(): string {
    const full: string = fullImageOf(this.url);
    return full.length > 0 ? full : this.url;
  }

  /** 是否有「原图/缩略图」这个概念可标记（非镜像地址不显示 badge） */
  private showBadge(): boolean {
    return fullImageOf(this.url).length > 0;
  }

  private badgeText(): string {
    return this.usingFull ? '原图' : '缩略图';
  }

  /** 底部来源说明：从地址里抠 host，抠不出来就给产品名兜底 */
  private sourceText(): string {
    const s: string = this.url;
    const scheme: number = s.indexOf('://');
    if (scheme < 0) {
      return 'SpaceLaunch · 航天发射跟踪';
    }
    const rest: string = s.substring(scheme + 3);
    const slash: number = rest.indexOf('/');
    const host: string = slash < 0 ? rest : rest.substring(0, slash);
    if (host.length === 0) {
      return 'SpaceLaunch · 航天发射跟踪';
    }
    return '来源：' + host;
  }

  /**
   * 屏幕尺寸 → 拖动边界。
   * 用 display 而不是 onAreaChange：后者返回的 Area.width 是 Length 联合类型，
   * ArkTS 严格模式下要再做一次收窄，反而更容易写错；看图器恒全屏，屏幕尺寸够用。
   */
  private measureViewport(): void {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      const w: number = this.getUIContext().px2vp(info.width);
      const h: number = this.getUIContext().px2vp(info.height);
      if (w > 0) {
        this.viewW = w;
      }
      if (h > 0) {
        this.viewH = h;
      }
    } catch (e) {
      // 拿不到屏幕信息就沿用默认值：只影响放大后能拖多远，不影响主链路
    }
  }

  private clampTo(v: number, lo: number, hi: number): number {
    if (v < lo) {
      return lo;
    }
    if (v > hi) {
      return hi;
    }
    return v;
  }

  /**
   * 平移边界近似：放大 s 倍后，图片视觉尺寸变成视口 s 倍，
   * 可移动范围就是 (s-1) * 视口 / 2（两边各一半）。
   * 图片是 contain 的，真实视觉高度可能小于视口，这里按视口算会略微放宽 ——
   * 宁可让手指能把边缘图拖到中间，也别把边界算得比实际还紧、拖不到角落。
   */
  private maxPanX(): number {
    return Math.max(0, (this.zoomScale - 1) * this.viewW / 2);
  }

  private maxPanY(): number {
    return Math.max(0, (this.zoomScale - 1) * this.viewH / 2);
  }

  private clampPan(): void {
    const mx: number = this.maxPanX();
    const my: number = this.maxPanY();
    this.panX = this.clampTo(this.panX, -mx, mx);
    this.panY = this.clampTo(this.panY, -my, my);
  }

  // ============ 手势动作 ============

  /** 捏合结束 / 拖动结束后的收敛：把缩放与平移压回合法区间 */
  private settleZoom(): void {
    this.pinching = false;
    this.dragZoom = false;
    if (this.zoomScale < MIN_ZOOM) {
      this.zoomScale = MIN_ZOOM;
    }
    if (this.zoomScale > MAX_ZOOM) {
      this.zoomScale = MAX_ZOOM;
    }
    if (this.zoomScale <= MIN_ZOOM + 0.001) {
      // 回到 1 倍：平移必须归零，否则图会停在被拖走的偏移位置
      this.zoomScale = MIN_ZOOM;
      this.panX = 0;
      this.panY = 0;
      return;
    }
    this.clampPan();
  }

  /** 双击：已在放大态就还原，否则放到 2.5 倍 */
  private toggleDoubleZoom(): void {
    if (this.zoomScale > MIN_ZOOM + 0.01) {
      this.zoomScale = MIN_ZOOM;
      this.panX = 0;
      this.panY = 0;
      return;
    }
    this.zoomScale = DOUBLE_ZOOM;
    this.clampPan();
  }

  /** 单击图片：切换顶底栏（沉浸浏览） */
  private toggleChrome(): void {
    this.chromeVisible = !this.chromeVisible;
  }

  /** 下滑松手：过阈值就返回，没过就弹回原位 */
  private settleDismiss(): void {
    this.dragDismiss = false;
    if (this.zoomScale > MIN_ZOOM + 0.01) {
      // 放大态下纵向拖动是「看图的另一半」，不该触发关闭
      this.dismissY = 0;
      return;
    }
    if (this.dismissY > DISMISS_LIMIT) {
      Nav.pop();
      return;
    }
    this.dismissY = 0;
  }

  /**
   * 图片加载失败。
   * 第一次失败先退回缩略图（原图 404 在 COS 上很常见：_2000 还没补齐），
   * 缩略图也失败才算真失败，出「重试」。
   */
  private onImageError(): void {
    if (this.usingFull && this.url.length > 0 && this.imgSrc !== this.url) {
      this.usingFull = false;
      this.imgSrc = this.url;
      return;
    }
    this.loadState = LOAD_FAIL;
  }

  /**
   * 重试：把 loadState 拨回 LOADING 会让 if 分支重建 Image 节点，从而重新发请求。
   * 同时在有原图可推导时切一次地址（原图 <-> 缩略图），提高命中概率 ——
   * 上次可能只是原图那一刻网络抖了，缩略图反而在缓存里。
   */
  private retryLoad(): void {
    this.loadState = LOAD_LOADING;
    if (fullImageOf(this.url).length > 0) {
      if (this.usingFull) {
        this.usingFull = false;
        this.imgSrc = this.url;
      } else {
        this.usingFull = true;
        this.imgSrc = this.resolveSrc();
      }
      return;
    }
    this.imgSrc = this.resolveSrc();
  }

  // ============ 视图 ============

  build() {
    Stack({ alignContent: Alignment.Top }) {
      this.imageLayer()

      // 顶部栏：叠在图片上，不占布局
      this.topBar()

      // 底部栏：用整屏高 + 底部对齐把它压到底，外层 hitTest None 让空白处点击穿透到图片
      Column() {
        this.bottomBar()
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .parallelGesture(
      // 整页下滑关闭：用 parallelGesture 而不是 gesture，
      // 这样图片自己的放大拖动（子是 gesture）与它并行识别，互不吞事件。
      PanGesture({ fingers: 1, direction: PanDirection.Vertical, distance: PAN_SLOP })
        .onActionStart(() => {
          if (this.zoomScale > MIN_ZOOM + 0.01) {
            return;
          }
          this.dragDismiss = true;
        })
        .onActionUpdate((event: GestureEvent) => {
          if (this.zoomScale > MIN_ZOOM + 0.01) {
            return;
          }
          // 只跟向下；向上拖没有语义，直接钉在 0
          this.dismissY = event.offsetY > 0 ? event.offsetY : 0;
        })
        .onActionEnd(() => {
          if (this.zoomScale > MIN_ZOOM + 0.01) {
            return;
          }
          this.settleDismiss();
        })
    )
    .onAppear(() => {
      this.measureViewport();
    })
  }

  /** 图片层：黑底 + 居中 contain + 手势 */
  @Builder
  imageLayer() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.loadState === LOAD_FAIL || this.imgSrc.length === 0) {
        this.failLayer()
      } else {
        Image(this.imgSrc)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          // 原图 2000px 缩到手机屏，高档插值明显更干净
          .interpolation(ImageInterpolation.High)
          // 位移先于缩放声明：缩放以组件中心为原点，translate 在其上层叠加
          .translate({ x: this.panX, y: this.panY + this.dismissY })
          .scale({ x: this.zoomScale, y: this.zoomScale })
          .opacity(1 - Math.min(this.dismissY / DISMISS_FADE_SPAN, DISMISS_MAX_FADE))
          // animation 必须放在要动画的属性之后；拖动中 duration 0 = 跟手无补间
          .animation({
            duration: (this.dragZoom || this.dragDismiss) ? 0 : ANIM_MS,
            curve: Curve.EaseOut
          })
          .onComplete(() => {
            this.loadState = LOAD_DONE;
          })
          .onError(() => {
            this.onImageError();
          })
          // 捏合用 priorityGesture：两指同时平移时 Pinch 必须优先于下面的 Pan 被识别，
          // 否则 Pan 先抢到、捏合就完全失效（实测最容易踩的就是这个）。
          .priorityGesture(
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.pinching = true;
                this.dragZoom = true;
                this.pinchBase = this.zoomScale;
              })
              .onActionUpdate((event: GestureEvent) => {
                // 以「起始倍数 × 手势比例」计算，而不是每帧乘一次，避免误差滚雪球
                const next: number = this.pinchBase * event.scale;
                this.zoomScale = this.clampTo(next, PINCH_FLOOR, PINCH_CEIL);
                this.clampPan();
              })
              .onActionEnd(() => {
                // 松手收敛：> 4 收到 4，< 1 回到 1（超调区间的存在就是为了这一步回弹）
                this.settleZoom();
              })
          )
          // 拖动 / 双击 / 单击收进一个 Exclusive 组：
          //   同一节点重复调 .gesture() 是**后者覆盖前者**，三个手势必须合成一组。
          //   Exclusive 下双击排在单击前面 —— 单击要等双击的判定窗口（约 300ms）
          //   过去才触发，这正是「单击切栏、双击缩放」能共存的原因；
          //   把单击放前面会变成双击先切了一次栏再缩放。
          .gesture(
            GestureGroup(
              GestureMode.Exclusive,
              PanGesture({ fingers: 1, direction: PanDirection.All, distance: PAN_SLOP })
                .onActionStart(() => {
                  this.panBaseX = this.panX;
                  this.panBaseY = this.panY;
                  if (this.zoomScale > MIN_ZOOM + 0.01) {
                    this.dragZoom = true;
                  }
                })
                .onActionUpdate((event: GestureEvent) => {
                  // 1 倍时不做任何位移（等价于没挂这个手势，见文件头「取舍」）
                  if (this.zoomScale <= MIN_ZOOM + 0.01) {
                    return;
                  }
                  // 捏合中：两指移动产生的 offset 不该被当成平移，否则图会跟着手指甩
                  if (this.pinching) {
                    return;
                  }
                  this.panX = this.clampTo(this.panBaseX + event.offsetX, -this.maxPanX(), this.maxPanX());
                  this.panY = this.clampTo(this.panBaseY + event.offsetY, -this.maxPanY(), this.maxPanY());
                })
                .onActionEnd(() => {
                  this.dragZoom = false;
                  this.clampPan();
                }),
              TapGesture({ count: 2 }).onAction(() => {
                this.toggleDoubleZoom();
              }),
              TapGesture({ count: 1 }).onAction(() => {
                this.toggleChrome();
              })
            )
          )
      }

      if (this.loadState === LOAD_LOADING) {
        LoadingProgress()
          .width(40)
          .height(40)
          .color(TEXT_MAIN)
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 顶部自绘栏：返回 + 标题 + 原图/缩略图标记 */
  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹')
          .fontSize(24)
          .fontColor(TEXT_MAIN)
          .fontWeight(FontWeight.Medium)
        Text('返回')
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .margin({ left: 2 })
      }
      .height(44)
      .padding({ left: 12, right: 12 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        Nav.pop();
      })

      Text(this.title.length > 0 ? this.title : '图片')
        .fontSize(15)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .margin({ left: 4, right: 4 })

      // 右侧与左侧大致等宽，标题才真的居中；宽度给死而不是 Blank：
      // Blank 在 Row 里会抢满剩余空间，把中间标题压没
      Row() {
        if (this.showBadge()) {
          Text(this.badgeText())
            .fontSize(10)
            .fontColor(TEXT_SUB)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .backgroundColor('#33000000')
        }
      }
      .width(68)
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height(88)
    .padding({ right: 12, top: 4 })
    .alignItems(VerticalAlign.Top)
    // 顶栏用渐变而不是实心条：图片顶部的高光/星点不被一条黑块切断
    .linearGradient({
      angle: 180,
      colors: [['#CC000000', 0.0], ['#00000000', 1.0]]
    })
    .opacity(this.chromeVisible ? 1 : 0)
    // 隐藏时连命中测试一起关掉，否则摸到看不见的返回按钮会直接退出页面。
    // 可见时用 Transparent 而不是 Default：整条栏横跨 88vp，用 Default 会把
    // 中间那段渐变也吃掉，用户点栏上空白处切不出工具栏；Transparent 让事件
    // 继续传到下面的图片（子节点「返回」仍是 Default，照常响应并 pop）。
    .hitTestBehavior(this.chromeVisible ? HitTestMode.Transparent : HitTestMode.None)
    .animation({ duration: CHROME_ANIM_MS, curve: Curve.EaseOut })
  }

  /** 底部信息条：标题 + 来源（半透明黑，压在图上） */
  @Builder
  bottomBar() {
    Column() {
      Text(this.title.length > 0 ? this.title : '图片')
        .fontSize(13)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text(this.sourceText())
        .fontSize(11)
        .fontColor(TEXT_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(BAR_BG)
    .opacity(this.chromeVisible ? 1 : 0)
    // 底部没有可点元素，整块穿透：点它也应该能切回顶栏
    .hitTestBehavior(HitTestMode.None)
    .animation({ duration: CHROME_ANIM_MS, curve: Curve.EaseOut })
  }

  /** 加载失败占位：文案 + 重试 */
  @Builder
  failLayer() {
    Column() {
      Text('图片加载失败')
        .fontSize(15)
        .fontColor(TEXT_SUB)

      Text('重试')
        .fontSize(13)
        .fontColor(TEXT_MAIN)
        .padding({ left: 20, right: 20, top: 8, bottom: 8 })
        .borderRadius(16)
        .borderWidth(1)
        .borderColor('#55FFFFFF')
        .margin({ top: 14 })
        .onClick(() => {
          this.retryLoad();
        })

      Text('原图可能还没同步到镜像，稍后再试')
        .fontSize(11)
        .fontColor('#55617A')
        .margin({ top: 12 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
