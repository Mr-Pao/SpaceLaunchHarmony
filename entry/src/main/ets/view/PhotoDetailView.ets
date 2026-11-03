/**
 * view/PhotoDetailView.ets —— 全屏看图器（单图沉浸浏览）
 *
 * 对位小程序 pages/photo-detail/photo-detail.vue。2026-11-03 按审计表 8 条差异对齐，
 * 逐条取舍写在这里（行内注释只解释局部）：
 *
 *   · 底色改 #04060A：小程序 .page 就是这个值，纯黑会让底部信息条和画面焊成一片。
 *   · 顶栏按 nav-bar(solid) 复刻：44vp 实色条 + 0.5vp 分隔线，标题 23vp / w600 / 居中。
 *     原实现是 15vp 居中叠在渐变上的浮层，与小程序不符。
 *   · 底部信息条改成「标题 16vp w600 两行 + 副标题 11vp」；小程序还有一段 30vh 的
 *     可滚动中文介绍，但 PhotoNavParam 只有 (url, title) 两个字段，
 *     拿不到 explanationZh / explanation / captionZh / caption 里的任何一个。
 *     要补这段必须先扩 PhotoNavParam（routes/NavParam.ets 不在写作用域），本次不做。
 *   · 副标题不再从 URL 抠 host（审计判定为错），改成固定的一行来源说明 + 双击提示。
 *   · 删除「原图/缩略图」badge、失败层与重试按钮：小程序没有这些，只留
 *     13vp #4D5A6E 的「图片暂不可用」。原图 404 静默退回缩略图这一步不可见，保留。
 *   · 手势收窄到「只服务看图」：小程序的单击是交给 uni.previewImage 的系统看图器，
 *     鸿蒙没有等价组件，所以捏合 / 双击 / 放大后拖动留作替代；单击切顶底栏、
 *     1x 下滑关闭这两条小程序里根本没有，已删除。
 *   · 分享跳过：鸿蒙要接系统 Share Kit（Want + 分享面板），不在本次范围。
 *
 * ── 实现约束 ──
 *   · 不铺星空、不留 tab 的底边距：本页是 NavDestination 二级页。
 *   · 返回只走 Nav.pop()，不 push 新页面。
 *   · 本文件不碰 AppStorage，也不打日志。
 */

import { display } from '@kit.ArkUI';
import { Nav } from '../routes/Nav';
import { fullImageOf } from '../utils/Media';

// ============ 颜色（photo-detail.vue 的 wxss，rpx 一律除以 2）============

/** 页面底色 */
const BG: string = '#04060A';
/** 底部信息条底色：小程序写死纯黑，与图片区拉开层次 */
const BAR_BG: string = '#000000';
/** 顶栏底色：nav-bar solid 的 rgba(10,14,23,0.96) */
const TOP_BAR_BG: string = '#F50A0E17';
/** 顶栏底边分隔线：1rpx rgba(255,255,255,0.05) */
const DIVIDER: string = '#0DFFFFFF';
/** 主文字（标题、返回） */
const TEXT_MAIN: string = '#FFFFFF';
/** 副标题 .bar-sub 的 #6b7891 */
const TEXT_SUB: string = '#6B7891';
/** 空图提示 .tip 的 #4d5a6e */
const TEXT_TIP: string = '#4D5A6E';

// ============ 尺寸 ============

/** 顶栏高度：小程序 nav-inner 是 44px 固定值，不随屏宽走 */
const TOP_BAR_H: number = 44;

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
 * 判定「是拖动不是微抖」的最小位移（vp）。
 * 太小会把手指抖动当成拖动，点图时图会跳一下；太大则拖动起步发涩。
 */
const PAN_SLOP: number = 12;

/** 缩放 / 位移的过渡时长 */
const ANIM_MS: number = 200;

/** 取不到屏幕尺寸时的保守回退值（只影响放大后可拖动的范围） */
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
   * ⚠ 不能叫 `scale`：那是内置属性方法名，成员与之同名会编译失败。
   */
  @State zoomScale: number = MIN_ZOOM;
  /** 放大后的横向平移（vp） */
  @State panX: number = 0;
  /** 放大后的纵向平移（vp） */
  @State panY: number = 0;

  // ============ 界面状态 ============

  /** 实际渲染的图片地址（先原图，失败退回缩略图） */
  @State imgSrc: string = '';
  /** 当前 imgSrc 是不是「推导出来的原图」—— 失败回退缩略图时置 false */
  @State usingFull: boolean = true;
  /** 原图与缩略图都失败：只显示一行「图片暂不可用」，没有重试按钮 */
  @State failed: boolean = false;

  /** 视口宽高（vp），用来算放大后的拖动边界 */
  @State viewW: number = DEFAULT_VIEW_W;
  @State viewH: number = DEFAULT_VIEW_H;

  /** 拖动中动画时长要给 0（跟手不能有补间），松手才用 ANIM_MS 回弹 */
  @State dragZoom: boolean = false;

  // ============ 手势内部基准（不参与渲染，普通字段即可）============

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
    this.failed = false;
    this.zoomScale = MIN_ZOOM;
    this.panX = 0;
    this.panY = 0;
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

  /**
   * 屏幕尺寸 → 拖动边界。
   * 用 display 而不是 onAreaChange：后者返回的 Area.width 是 Length 联合类型，
   * 严格模式下还要再收窄一次，反而更容易写错；看图器恒全屏，屏幕尺寸够用。
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
   * 平移边界近似：放大 s 倍后图片视觉尺寸变成视口的 s 倍，
   * 可移动范围就是 (s-1) * 视口 / 2（两边各一半）。
   * 图片是 contain 的，真实视觉高度可能小于视口，按视口算会略微放宽 ——
   * 宁可让手指把边缘图拖到中间，也别把边界算得比实际还紧、拖不到角落。
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

  /** 捏合 / 拖动结束后的收敛：把缩放与平移压回合法区间 */
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

  /**
   * 图片加载失败。
   * 第一次失败先退回缩略图（原图 404 在 COS 上很常见：_2000 还没补齐），
   * 缩略图也失败才算真失败。小程序在真失败时只画一行「图片暂不可用」，
   * 这里保持一致：不给重试按钮，也不提示「原图还没同步」。
   */
  private onImageError(): void {
    if (this.usingFull && this.url.length > 0 && this.imgSrc !== this.url) {
      this.usingFull = false;
      this.imgSrc = this.url;
      return;
    }
    this.failed = true;
  }

  // ============ 视图 ============

  build() {
    Column() {
      this.topBar()
      this.stage()
      this.bottomBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .onAppear(() => {
      this.measureViewport();
    })
  }

  /**
   * 顶栏：小程序 nav-bar 是 solid（实色）+ placeholder（占位）。
   * 所以这里不叠在图上，而是占真实布局高度 —— 占位法在鸿蒙侧等价于直接放进 Column。
   */
  @Builder
  topBar() {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.title.length > 0 ? this.title : '图片')
        .fontSize(23)
        // nav-bar 的 .nav-title 是 w600；FontWeight.Bold 是 700，比小程序重一档
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        // 左右各 60：nav-bar 的 .nav-title 是 left/right 120rpx，给返回键让位
        .padding({ left: 60, right: 60 })

      Row() {
        Row() {
          Text('‹')
            .fontSize(23)
            .fontColor(TEXT_MAIN)
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          Nav.pop();
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ left: 10 })
    }
    .width('100%')
    .height(TOP_BAR_H)
    .backgroundColor(TOP_BAR_BG)
    .border({ width: { bottom: 0.5 }, color: DIVIDER })
  }

  /** 图片区：占满剩余高度，contain 完整显示不裁切 */
  @Builder
  stage() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.failed || this.imgSrc.length === 0) {
        Text('图片暂不可用')
          .fontSize(13)
          .fontColor(TEXT_TIP)
      } else {
        Image(this.imgSrc)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          // 原图 2000px 缩到手机屏，高档插值明显更干净
          .interpolation(ImageInterpolation.High)
          // 位移先于缩放声明：缩放以组件中心为原点，translate 在其上层叠加
          .translate({ x: this.panX, y: this.panY })
          .scale({ x: this.zoomScale, y: this.zoomScale })
          // animation 必须放在要动画的属性之后；拖动中 duration 0 = 跟手无补间
          .animation({ duration: this.dragZoom ? 0 : ANIM_MS, curve: Curve.EaseOut })
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
          // 拖动 + 双击收进一个 Exclusive 组：
          //   同一节点重复调 .gesture() 是**后者覆盖前者**，两个手势必须合成一组。
          //   单击不再绑手势（小程序那条路是系统看图器，鸿蒙侧没有对应动作）。
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
                  // 1 倍时不做任何位移（等价于没挂这个手势）
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
              })
            )
          )
      }
    }
    .width('100%')
    .layoutWeight(1)
    // 放大后图片会超出自身盒子，必须由这一层裁掉，否则会盖住顶栏与信息条
    .clip(true)
    .backgroundColor(BG)
  }

  /**
   * 底部信息条：标题（16vp w600、最多两行、行高 22）+ 副标题（11vp #6B7891）。
   * 小程序第三块「30vh 可滚动中文介绍」缺数据源，本次不做（详见文件头）。
   */
  @Builder
  bottomBar() {
    Column() {
      Text(this.title.length > 0 ? this.title : '图片')
        .fontSize(16)
        // .bar-title 是 w600
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
        .lineHeight(22)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)

      // 副标题不再从 URL 抠 host；PhotoNavParam 没有日期/版权字段，
      // 所以这里给一句固定的来源说明，顺带提示可以双击放大。
      Text('图片来自 SpaceLaunch 图库 · 双击放大')
        .fontSize(11)
        .fontColor(TEXT_SUB)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 5 })
    }
    .width('100%')
    // .bar 的 26rpx 32rpx 30rpx
    .padding({ left: 16, right: 16, top: 13, bottom: 15 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(BAR_BG)
  }
}
