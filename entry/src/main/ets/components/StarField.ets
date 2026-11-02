/**
 * components/StarField.ets —— 全屏星空背景
 *
 * 对位文件：SpaceLaunch/components/star-field/star-field.vue（全文 73 行）
 *   · 160 颗星，坐标/大小/透明度逐条照抄原逻辑：
 *       x = Math.random() * width
 *       y = Math.random() * height
 *       size = Math.random() > 0.85 ? 1 : 0
 *       alpha = 0.3 + Math.random() * 0.7
 *   · 整层只跑一条 twinkle 动画：opacity 0.35 → 1，周期 3.2s，ease-in-out 无限循环。
 *
 * ── 有意差异（相对小程序，逐条说明）──
 *   1. **画法**：小程序把 160 颗星塞进一条 `box-shadow` 字符串（单节点的 160 个影子）。
 *      ArkUI 没有 box-shadow；若改用 160 个 Circle() 子节点，等于给这一层加 160 个
 *      渲染节点 + 160 次布局参与，代价远大于一次绘制。故改用 **Canvas 一次性画完**：
 *      160 个 arc 只占一次 draw call，节点数恒为 1，与小程序「合成开销恒为一条」的
 *      设计意图等价。
 *   2. **半径单位**：原 `box-shadow` 的 spread 是 `0 / 1px`（后台跑在 device pixel 上），
 *      Canvas 的坐标单位是 **vp**，所以大星取半径 1.1vp、小星 0.55vp —— 在 2x/3x 屏上
 *      视觉直径约等于原来的 1px 光晕点。这是换算，不是改设计。
 *   3. **闪烁实现**：原 CSS `@keyframes sf-twinkle 3.2s infinite ease-in-out`。
 *      ArkUI 侧用**定时器驱动 @State**：setInterval 1600ms 在 0.35 / 1 两档之间翻转，
 *      再配 `.animation({ duration: 1600, curve: Curve.EaseInOut })` 补间 ——
 *      两段各 1.6s 正好拼出 3.2s 的 0.35→1→0.35，比用 animateTo 递归简单可靠，
 *      也不会在页面切走时留下悬空的动画回调。
 *   4. **尺寸来源**：原组件 created() 里读 `uni.getSystemInfoSync()` 的
 *      windowWidth/windowHeight。ArkUI 侧刻意**不去查屏幕尺寸**（display 模块还要额外
 *      引一个 kit，且父容器未必就是全屏，按屏幕尺寸画会偏），改成两级：
 *        · aboutToAppear 先用 FALLBACK_W / FALLBACK_H 生成一版占位星图（只为让数组非空）；
 *        · Canvas 的 onReady 拿到**真实画布尺寸**后按实际宽高重建并绘制。
 *      画布尺寸无效（0 或取不到）时**不画、不崩**，视觉上就是父级底色（纯色），
 *      对位原实现「拿不到尺寸就退化为纯色背景」的 catch 分支。
 *   5. **层级**：原 `z-index: -1` 是相对页面根节点生效的。ArkUI 没有负 z-index，
 *      改用父级 **Stack 的子节点顺序**：把 StarField 放在 Stack 的**第一个**子节点即可
 *      （后画的盖在上面）。父级请用 Stack 承载本组件，见文件末的使用说明。
 *   6. **不接事件**：原 `pointer-events: none` → `.hitTestBehavior(HitTestMode.None)`。
 *      注意本组件的根节点自己不带 onClick，也不会挡住下层点击。
 *
 * ── 用法（父级 TodayView）──
 *   Stack() {
 *     StarField()                 // ← 第一个子节点 = 最底层
 *     Scroll() { ...页面内容... }
 *   }
 *   .width('100%').height('100%').backgroundColor('#0A0E17')
 * 本组件不接收任何 props（任务书要求），放在页面最底层即可。
 *
 * ⚠ 本文件不打控制台日志，一律走 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'StarField';

/** 星点数量，照抄 star-field.vue 的 160 */
const STAR_COUNT: number = 160;
/** 大星阈值，照抄原逻辑 `Math.random() > 0.85`（即约 15% 是 1px 光晕大星） */
const BIG_STAR_RATIO: number = 0.85;
/** 占位画布尺寸（vp）：onReady 之前先用它生成星图，保证数组非空且不崩 */
const FALLBACK_W: number = 360;
const FALLBACK_H: number = 780;
/** 闪烁周期 3.2s 的一半：0.35 ↔ 1 各 1.6s */
const TWINKLE_HALF_MS: number = 1600;

/**
 * 一颗星。
 *
 * 用 class 而不是对象字面量：ArkTS 禁止无类型对象字面量（`{x, y, ...}` 会直接编译失败），
 * 所以所有星点都必须经这个构造器产出。
 */
class StarPoint {
  /** 画布坐标，单位 vp（Canvas 的默认坐标系就是 vp） */
  x: number = 0;
  y: number = 0;
  /** 1 = 大星（原 box-shadow 的 spread 1px 光晕），0 = 普通小星 */
  size: number = 0;
  /** 0.3 ~ 1 的透明度，原样保留两位小数后写进 rgba() */
  alpha: number = 1;

  constructor(x: number, y: number, size: number, alpha: number) {
    this.x = x;
    this.y = y;
    this.size = size;
    this.alpha = alpha;
  }
}

@Component
export struct StarField {
  /** 整层透明度，定时器在两档之间翻转（对位 CSS keyframes 的 0%/50%/100%） */
  @State fade: number = 0.35;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  /** 星点表。普通成员即可：它只在绘制时被读取，不需要触发 UI 刷新 */
  private stars: StarPoint[] = [];

  /** setInterval 的句柄。-1 = 未启动 */
  private timerId: number = -1;
  /** 已按真实画布尺寸重算过，避免 onReady 重复重建（onReady 在某些机型会触发多次） */
  private sized: boolean = false;

  // ============ 生成 ============

  /**
   * 按给定宽高生成 STAR_COUNT 颗星。
   *
   * 逐行照抄原实现：坐标用 Math.random() * width/height，
   * 15% 概率是大星，alpha 落在 0.3~1。
   */
  private makeStars(w: number, h: number): void {
    const out: StarPoint[] = [];
    for (let i = 0; i < STAR_COUNT; i++) {
      const x: number = Math.random() * w;
      const y: number = Math.random() * h;
      const size: number = Math.random() > BIG_STAR_RATIO ? 1 : 0;
      const alpha: number = 0.3 + Math.random() * 0.7;
      out.push(new StarPoint(x, y, size, alpha));
    }
    this.stars = out;
  }

  // ============ 绘制 ============

  /**
   * 一次性把 stars 画到 Canvas 上。
   *
   * 颜色字符串严格按原实现的 `rgba(255,255,255,alpha)` 拼，
   * alpha 用 toFixed(2) 保留两位（原实现也是 `alpha.toFixed(2)`）。
   */
  private paint(): void {
    try {
      const w: number = this.ctx.width;
      const h: number = this.ctx.height;
      if (!(w > 0) || !(h > 0)) {
        // 画布尺寸无效：不画，留给父级底色兜底（等价原实现的 catch 分支）
        hilog.warn(DOMAIN, TAG, 'canvas size unavailable, fallback to solid background');
        return;
      }
      this.ctx.clearRect(0, 0, w, h);
      for (let i = 0; i < this.stars.length; i++) {
        const s: StarPoint = this.stars[i];
        // 见文件头「有意差异 2」：spread 1px / 0px 换算到 vp 半径
        const r: number = s.size > 0 ? 1.1 : 0.55;
        this.ctx.beginPath();
        this.ctx.arc(s.x, s.y, r, 0, Math.PI * 2);
        this.ctx.fillStyle = 'rgba(255,255,255,' + s.alpha.toFixed(2) + ')';
        this.ctx.fill();
      }
    } catch (e) {
      // 绘制异常绝不能让整页挂掉：这一层只是背景。
      // 刻意不在日志里序列化 e：ArkTS 的 catch 变量类型收得很紧，
      // 直接把它交给 JSON.stringify 有编译风险，收益又只是排错便利。
      hilog.error(DOMAIN, TAG, 'paint failed');
    }
  }

  /** Canvas 就绪：拿到真实尺寸后重建星图并绘制。尺寸无效则保持兜底星图不画 */
  private onCanvasReady(): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (!(w > 0) || !(h > 0)) {
      hilog.warn(DOMAIN, TAG, 'onReady with invalid size ' + String(w) + 'x' + String(h));
      return;
    }
    // 第一次就绪时按真实画布尺寸重算；已是按真实尺寸生成的就不重复随机
    if (!this.sized) {
      this.makeStars(w, h);
      this.sized = true;
    }
    this.paint();
  }

  // ============ 生命周期 ============

  aboutToAppear(): void {
    // onReady 之前先用占位尺寸生成一版星图：数组非空，且真机画布迟迟不来时也不空白。
    // 真实宽高在 Canvas 的 onReady 里拿到后会整体重建，这里生成的只是过渡。
    this.makeStars(FALLBACK_W, FALLBACK_H);

    // 闪烁：两档间翻转，补间交给下面 build() 里的 .animation()
    this.timerId = setInterval(() => {
      this.fade = this.fade > 0.5 ? 0.35 : 1;
    }, TWINKLE_HALF_MS);
  }

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  // ============ 渲染 ============

  build() {
    Stack() {
      Canvas(this.ctx)
        .width('100%')
        .height('100%')
        // onReady 时才知道画布真实宽高，星点必须在那里落位
        .onReady(() => {
          this.onCanvasReady();
        })
    }
    .width('100%')
    .height('100%')
    // 对位原 `position: absolute; top: 0; left: 0; width/height: 100%`
    .position({ x: 0, y: 0 })
    // 对位原 `pointer-events: none`：整层不参与命中测试，下层内容照常可点
    .hitTestBehavior(HitTestMode.None)
    .opacity(this.fade)
    // 1600ms 一档 + ease-in-out，两段拼成 3.2s 的 0.35 → 1 → 0.35
    .animation({ duration: TWINKLE_HALF_MS, curve: Curve.EaseInOut })
  }
}
