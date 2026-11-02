/**
 * components/GalleryGrid.ets —— 图库瀑布流（WaterFlow + ForEach）
 *
 * 对位小程序 pages/gallery/gallery.vue 的图墙：**三列、图与图几乎无缝**
 * （列间距 4vp、行间距 4vp）、圆角只有 6vp。小程序的「六条横带横向漂移」不搬 ——
 * 鸿蒙这边是纵向浏览的完整列表，横向漂移会让 1000+ 张的浏览变成「看一屏再滑」，
 * 不如瀑布流一屏能扫到更多张。
 *
 * ── 为什么用 ForEach 而不是 LazyForEach ──
 *   LazyForEach 要自己实现 IDataSource + 监听器分发，最坑的是「触底追加时
 *   监听器里的下标与真实数据错位」——错一次就是半屏白块，且线上难复现。
 *   本页最多 1118 张、每片 500，WaterFlow 自己有 cachedCount 做节点复用，
 *   ForEach 全量建节点的内存开销实测可接受。先把墙跑通，性能真成问题再换。
 *   如果将来要换，接口不用变：本组件对外只吃 `photos: GlPhoto[]`。
 *
 * ── 高度为什么由数据侧算（且必须稳定）──
 *   WaterFlow 一旦等图片解码完再撑高，整墙会从「等高」突变到「错落」，
 *   滚动位置跟着跳。所以高度在造数据时就用 id 的字符 hash 定死（heightOf），
 *   图片只做 Cover 裁切，加载前后布局完全一致。
 *   **绝不能用 Math.random()**：每次重建组件高度都变，滚动时整页抖。
 *
 * ── 点击入口 ──
 *   一律进看图器（Nav.pushPhoto）。小程序按 kind 分流（发射图进 launchInfo 的
 *   图片优先态），鸿蒙侧看图器只有一个入口，不去搬那套分流。
 *
 * ⚠ 本文件不打日志（纯展示、无 IO）。
 */

/** 单格最小高度（任务口径 120~200vp） */
const H_MIN: number = 120;
/** 单格最大高度 */
const H_MAX: number = 200;
/** 列间距 / 行间距：小程序实测「几乎无缝」，4vp 是肉眼刚能分开的极限 */
const GAP: number = 4;
/** 单格圆角：小程序只有 6vp 与直角两种，这里取 6 */
const RADIUS: number = 6;
/** 格子底色：图片还没解码时露出的颜色，避免纯黑方块在深色底上像「破洞」 */
const BG_CARD: string = '#141A26';
/** 图片加载失败时的占位底色，比卡片底色亮一档，看得出「这里有一格、只是图坏了」 */
const BG_BROKEN: string = '#1B2230';

/**
 * 一张图（视图模型）。
 *
 * 不在 cell 里直接渲染原始 JSON：瀑布流要 h、点击要已解析好的 full、
 * 标题要「按 | 取后段」清洗过 —— 这些都在造数据时算一次，
 * 让 cell 的 build 里不再做字符串运算（滚动时每帧都会重跑 build）。
 */
export class GlPhoto {
  /** 唯一键。同一发多次出现时允许重复 id，所以 LazyForEach/ForEach 的 key 还要拼下标 */
  id: string = '';
  /** 列表里用缩略图：480px 镜像、几十 KB，弱网也能一格一格出图 */
  thumb: string = '';
  /** 点开交给看图器的地址（已按规则解析成原图，解析不出来等于 thumb） */
  full: string = '';
  /** 格子底部那一行字：任务名（name 按 | 取后段），没标题就不画遮罩 */
  title: string = '';
  /** 伪高度，由 id 的 hash 决定；同一张图每次进页都是同一个值 */
  h: number = H_MIN;

  constructor(id: string, thumb: string, full: string, title: string, h: number) {
    this.id = id;
    this.thumb = thumb;
    this.full = full;
    this.title = title;
    this.h = h;
  }
}

/**
 * 由 id 算 120~200vp 的稳定伪高度。
 *
 * 算法刻意简单：31 进制滚动 hash 取模 100000，再归一化到 [0,1) 映射到高度区间。
 * 不用 Math.random —— 那个每次调用都不一样，滚动时整页会跳；
 * 也不用图片真实宽高比 —— 那要等图下载完，加载中途必然抖一次。
 */
export function heightOf(id: string): number {
  let h: number = 0;
  for (let i = 0; i < id.length; i++) {
    h = (h * 31 + id.charCodeAt(i)) % 100000;
  }
  const r: number = (h % 80) / 80; // 0 .. 0.9875
  return Math.round(H_MIN + r * (H_MAX - H_MIN));
}

// ============ 数据集形状（按 2026-11-02 线上 COS 实测字段写，全部可选） ============

/**
 * gallery 分片里的单条。
 * 实测样本：{ id, name: 'Falcon 9 Block 5 | Starlink Group 15-18', net, thumb, credit, cname }
 * 索引文件额外带 count / chunks / chunkSize / launchTotal。
 */
export interface GlGalleryRaw {
  id?: string;
  name?: string;
  net?: string;
  thumb?: string;
  credit?: string;
  /** 火箭型号中文名（CI 回填），卡片不展示，留着给以后的详情条用 */
  cname?: string;
}

export interface GlGalleryPayload {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  /** 全量张数（线上 1118），**不是**本片条数 —— 页头「1118 张」要的是这个 */
  count?: number;
  /** 总片数；只信这个，不信 chunk 返回的 end（见 view/GalleryView.ets 注释） */
  chunks?: number;
  /** 每片条数（500） */
  chunkSize?: number;
  list?: GlGalleryRaw[];
  launchTotal?: number;
}

/**
 * nasaImages 单条。
 * 实测样本：{ id, theme, themeName, title, desc, date, center, thumb, full, nasaId, titleZh, descZh }
 *
 * ⚠ thumb 与 full 是**两个不同 hash 的地址**（thumb 480px 镜像、full 是 _1080 预设），
 *   不能像 gallery 那样用 fullImageOf(thumb) 互推 —— 推出来的 _2000 是 404。
 */
export interface GlNasaRaw {
  id?: string;
  theme?: string;
  themeName?: string;
  title?: string;
  titleZh?: string;
  date?: string;
  center?: string;
  thumb?: string;
  full?: string;
  nasaId?: string;
}

export interface GlNasaPayload {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  count?: number;
  list?: GlNasaRaw[];
}

/**
 * 单格。
 *
 * 单独拆成 @Component 是为了让「这一格图坏了」的 @State 只影响自己：
 * 直接在父级用一个 broken 数组，改下标 ArkUI 不观察（@State 不认 arr[i] = x），
 * 整体替换又会让整墙重建 —— 一格 404 拖垮 1000 格，不能这么写。
 */
@Component
struct GlCell {
  /** 图片数据。视图模型是只读的（永不原地改），所以用普通成员 + key 保证唯一即可 */
  photo: GlPhoto = new GlPhoto('', '', '', '', H_MIN);
  /** 该格图片是否加载失败。只影响本格，属于局部状态 */
  @State broken: boolean = false;
  /** 点击。普通成员，不能用 @Prop 承载函数 */
  onOpen: (item: GlPhoto) => void = () => {};

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.broken) {
        // 失败占位：不删格子。删了会让后面所有格子往前挪，正在看的图会跳走
        Column() {
          Text('🛰')
            .fontSize(16)
            .opacity(0.22)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(BG_BROKEN)
      } else {
        Image(this.photo.thumb)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          // 只改自己的 @State，不碰父级数组 —— 见结构体头部注释
          .onError(() => {
            this.broken = true;
          })
      }

      this.caption()
    }
    .width('100%')
    .height(this.photo.h)
    .borderRadius(RADIUS)
    // 圆角裁切用 clip：Column/Stack 上没有 overflow
    .clip(true)
    .backgroundColor(BG_CARD)
    .onClick(() => {
      this.onOpen(this.photo);
    })
  }

  /**
   * 底部标题条：只有任务名，没有别的。
   * 渐变 angle 0 = 从下往上（位置 0 是底部、不透明；1 是顶部、全透明），
   * 与工程内 DailyCards.ets 同口径。
   */
  @Builder
  caption() {
    if (this.photo.title.length > 0) {
      Column() {
        Text(this.photo.title)
          .fontSize(10)
          .fontColor('#E8EEF8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 6, right: 6, top: 16, bottom: 5 })
      .linearGradient({
        angle: 0,
        colors: [
          ['#CC05080F', 0.0],
          ['#6605080F', 0.6],
          ['#0005080F', 1.0]
        ]
      })
      // 纯装饰层，不吃点击，否则点格子会先命中文字条
      .hitTestBehavior(HitTestMode.None)
    }
  }
}

/**
 * 瀑布流。
 *
 * 用法（父级）：
 *   GalleryGrid({ photos: this.photos, colCount: 3,
 *                 onOpen: (p: GlPhoto) => { ... },
 *                 onBottom: () => { 拉下一片 } })
 *
 * `photos` 用 @Prop：父级每次分片追加都是 `concat` 出新数组，
 * @Prop 收到新引用才重建，ForEach 按 key 只补新格子，已渲染的不重排。
 */
@Component
export struct GalleryGrid {
  /** 已加载的图（父级持分片游标，本组件只管画） */
  @Prop photos: GlPhoto[] = [];
  /** 列数：精选 3、NASA 2 */
  @Prop colCount: number = 3;
  /** 点单格 */
  onOpen: (item: GlPhoto) => void = () => {};
  /** 触底。防重复请求的锁在父级（组件不持有加载状态） */
  onBottom: () => void = () => {};

  /** 列模板。写死字符串而不拼 '1fr '：ArkTS 对字符串 repeat 不友好 */
  private template(): string {
    return this.colCount >= 3 ? '1fr 1fr 1fr' : '1fr 1fr';
  }

  build() {
    WaterFlow() {
      // key 拼下标：同一发多次出现会出现重复 id，只用 id 会让 ForEach 吞掉重复项
      ForEach(this.photos, (item: GlPhoto, index: number) => {
        FlowItem() {
          GlCell({
            photo: item,
            onOpen: (p: GlPhoto) => {
              this.onOpen(p);
            }
          })
        }
        .width('100%')
      }, (item: GlPhoto, index: number) => item.id + '#' + String(index))
    }
    .columnsTemplate(this.template())
    .columnsGap(GAP)
    .rowsGap(GAP)
    // 预取 2 屏：3 列 × 6 ≈ 一屏出头，再多会白占内存（缩略图常驻）
    .cachedCount(6)
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    // 只「通知父级」，锁在页面侧 —— 组件不知道也不该知道还有没有下一片
    .onReachEnd(() => {
      this.onBottom();
    })
  }
}
