/**
 * components/GalleryGrid.ets —— 图库「横向漂移图带」+「看全部」纵向清单
 *
 * 对位小程序 pages/gallery/gallery.vue：
 *   · 图墙：模板 3-30 行的 .stage/.bands/.band/.track/.cell，样式段 .band / .band-t /
 *     .track / t1..t8 / marqueeL / marqueeR / .cell / .wide / .tall / .cell-img / .cell-veil
 *   · 清单：小程序那一页是独立的 pages/gallery-all（分类浏览器），鸿蒙侧没有这个路由，
 *     见本文件末尾 MpAllGrid 的说明。
 *
 * ── 单位换算（rpx ÷ 2 = vp，逐条写明，方便对着 wxss 复核）──
 *   宽带 cell 336rpx → 168vp  窄带 cell 232rpx → 116vp
 *   cell 间距 8rpx → 4vp      cell 圆角 14rpx → 7vp
 *   带间距 8rpx → 4vp
 *   带高权重：.band flex 232 / .band-t flex 164（**没有换算，直接当 layoutWeight 用**，
 *   它本来就是「占剩余高度的比例」，换成 vp 反而会在不同屏高上失真）
 *
 * ── 为什么不用 animateTo 做 marquee ──
 *   小程序是 CSS `animation: marqueeL 52s linear infinite`。
 *   鸿蒙没有 keyframes，能做到无限循环的只有两条路：
 *     a) animateTo({ iterations: -1 })：位移跑在渲染线程上最顺，但它**没有句柄**，
 *        组件销毁后停不下来，也没法在 aboutToDisappear 里清 —— 违反本工程
 *        「定时器必须清理」的硬约束；
 *     b) 每条带自己一个 setInterval，按「总位移 ÷ 总时长 × 步长」递推 dx。
 *   这里选 b。每条带独立计时，一次 tick 只改自己那一个 @State，
 *   不会牵动整面墙（父级一个 tick 全墙重绘是绝对不能接受的）。
 *   16ms ≈ 60fps；2064vp / 52s ≈ 40vp/s，每帧只走 0.63vp，肉眼是连续滑动。
 *
 * ── 为什么位移是「算出来的半宽」而不是量出来的 ──
 *   CSS 的 translateX(-50%) 依赖 track 的 max-content 宽度。ArkUI 没有 max-content，
 *   所以给 Row 显式设宽 half × 2，位移量取 half：
 *     half = 每带张数 × (cell 宽 + 间距)
 *   数据侧把每条带的图**复制一份接在尾部**（首尾相接），位移到 -half 时画面与 0
 *   完全重合，回弹那一瞬看不出接缝 —— 这正是 CSS -50% 的语义。
 *
 * ── 为什么图带里不画标题、不做破图占位 ──
 *   小程序 .cell 里只有 image + .cell-veil，没有任何文字；加了文字就不是 1:1 了。
 *   破图占位需要一个 @State，一面墙 8 条带 × 24 格 = 192 个格子，
 *   192 个带状态的子组件会让首屏构建明显变慢；破图时露出 #101722 的格子底色即可。
 *
 * ⚠ 本文件不打日志（纯展示）。
 */

/** 每条带一半的张数（小程序 PER_ROW = 12） */
export const MP_PER_ROW: number = 12;
/** 带数（小程序 ROWS = 8） */
export const MP_ROWS: number = 8;

/** 宽带 cell 宽 336rpx */
const WIDE_CELL: number = 168;
/** 窄带 cell 宽 232rpx */
const TALL_CELL: number = 116;
/** cell 间距 8rpx */
const CELL_GAP: number = 4;
/** cell 圆角 14rpx */
const CELL_RADIUS: number = 7;
/** 带间距 8rpx */
const BAND_GAP: number = 4;
/** 计时器步长（≈60fps） */
const TICK_MS: number = 16;
/** 格子底色（.cell 的 background: #101722） */
const CELL_BG: string = '#101722';
/** 清单模式单格高度。**固定值**：小程序图墙的高度来自 flex 均分，
 *  这里不是瀑布流，不需要伪随机高度（上一版按 id 做 120~200vp 的 hash 定高，
 *  与小程序完全无关，已删除） */
const GRID_CELL_H: number = 120;
/** 清单三列 */
const GRID_COLS: number = 3;

/**
 * 一张图（视图模型）。
 *
 * 只留「上屏 + 点击」真正需要的 6 个字段：小程序 pool 里还有 tag / intro / credit /
 * date，但鸿蒙侧 photo-detail 的入参只有 (url, title) 两个字段（见 routes/NavParam.ets
 * 的 PhotoNavParam），带过去也没地方显示，所以不在这里造死字段。
 * kind 决定点击分流：'launch' 进发射详情的看图模式，其余进通用看图器。
 */
export class MpImage {
  /** 发射 UUID（gallery 数据集的 id）；epic/apod/nasa 条目是 'epic-...' 之类的本地键 */
  id: string = '';
  /** 480px 缩略图，墙面用它 */
  thumb: string = '';
  /** 原图，点开时交给看图器 */
  full: string = '';
  /** 点击后页面标题（发射名 / APOD 标题 / '地球 · DSCOVR' …） */
  title: string = '';
  /** 'launch' | 'photo'，决定点击走哪条路由 */
  kind: string = '';
  /** 发射时刻 ISO，只有 kind='launch' 有值；发射详情用它兜底反查 */
  net: string = '';

  constructor(id: string, thumb: string, full: string, title: string, kind: string, net: string) {
    this.id = id;
    this.thumb = thumb;
    this.full = full;
    this.title = title;
    this.kind = kind;
    this.net = net;
  }
}

/**
 * 一条带。
 *
 * images 已经是「首尾相接」的 2N 张（一半是复制品），MpBandView 拿到就画。
 * wide 同时决定两件事：cell 宽度 与 带高权重 —— wxss 里两者就是绑在同一个
 * .band/.band-t 类上的，拆开会错位。
 */
export class MpBand {
  /** 2N 张（N 张原图 + N 张副本），保证位移到 -half 时无缝 */
  images: MpImage[] = [];
  /** true = 宽带（cell 168vp / 权重 232），false = 窄带（cell 116vp / 权重 164） */
  wide: boolean = true;
  /** 跑完一趟的毫秒数（t1..t8 的 52000/44000/62000/48000/56000/40000/58000/46000） */
  durMs: number = 52000;
  /** true = 向左（marqueeL：0 → -50%），false = 向右（marqueeR：-50% → 0） */
  toLeft: boolean = true;
  /** ForEach 的 key。带号天然唯一且稳定，重绘时不会重建子组件（否则动画会从头开始） */
  key: string = '';

  constructor(images: MpImage[], wide: boolean, durMs: number, toLeft: boolean, key: string) {
    this.images = images;
    this.wide = wide;
    this.durMs = durMs;
    this.toLeft = toLeft;
    this.key = key;
  }
}

// ============ 数据集形状（按线上 COS 实测字段写，全部可选） ============

/** gallery 分片里的单条：{ id, name, net, thumb, credit, cname }（full 线上不一定有） */
export interface MpGalleryRaw {
  id?: string;
  name?: string;
  net?: string;
  thumb?: string;
  /** 原图。线上多数条目没有这个键，取不到时用 thumb 反推 _2000（见 utils/Media.ets） */
  full?: string;
  credit?: string;
  cname?: string;
}

export interface MpGalleryPayload {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  /** 全量张数（线上 1118），**不是**本片条数 */
  count?: number;
  /** 总片数；终止条件只信这个 */
  chunks?: number;
  chunkSize?: number;
  list?: MpGalleryRaw[];
  launchTotal?: number;
}

/**
 * nasaImages 单条。
 *
 * ⚠ thumb 与 full 是**两个不同 hash 的地址**（thumb 480px 镜像、full 是 _1080 预设），
 *   不能像 gallery 那样用 fullImageOf(thumb) 互推 —— 推出来的 _2000 是 404。
 */
export interface MpNasaRaw {
  id?: string;
  theme?: string;
  themeName?: string;
  title?: string;
  titleZh?: string;
  desc?: string;
  descZh?: string;
  date?: string;
  center?: string;
  thumb?: string;
  full?: string;
  nasaId?: string;
}

export interface MpNasaPayload {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  count?: number;
  list?: MpNasaRaw[];
}

/**
 * 一条漂移带。
 *
 * 结构：Row（定宽 half×2）里排 2N 个 cell，整条 Row 用 translate 平移。
 * 外面套 .clip(true) 把出屏的半个 cell 裁掉 —— 不裁的话相邻带之间会互相压边。
 */
@Component
export struct MpBandView {
  /** 首尾相接后的 2N 张 */
  @Prop images: MpImage[] = [];
  /** 宽带 / 窄带 */
  @Prop wide: boolean = true;
  /** 跑完一趟的毫秒数 */
  @Prop durMs: number = 52000;
  /** true = 左移 */
  @Prop toLeft: boolean = true;
  /** 带高权重（232 / 164），由父级按 wxss 的 flex 值传入 */
  @Prop weight: number = 232;
  /** 最后一条带不留底边距（wxss 的 .band:last-child { margin-bottom: 0 }） */
  @Prop isLast: boolean = false;
  /** 点任意一格。普通成员，@Prop 不用于函数 */
  onOpen: (item: MpImage) => void = () => {};

  /** 当前位移（vp，负数向左） */
  @State dx: number = 0;
  /** setInterval 句柄，-1 表示没在跑 */
  private timer: number = -1;

  /** 单格宽度 */
  private cellW(): number {
    return this.wide ? WIDE_CELL : TALL_CELL;
  }

  /** 半宽 = 一半张数 × (格宽 + 间距)；也就是 CSS translateX(-50%) 的那个 50% */
  private halfW(): number {
    const n: number = Math.floor(this.images.length / 2);
    return n > 0 ? n * (this.cellW() + CELL_GAP) : MP_PER_ROW * (this.cellW() + CELL_GAP);
  }

  aboutToAppear(): void {
    const half: number = this.halfW();
    // 向右跑的带起点在 -half（等价于 CSS 的 marqueeR：-50% → 0）
    this.dx = this.toLeft ? 0 : -half;
    // 每 tick 前进多少 vp：跑完 half 需要 durMs
    const step: number = half / (this.durMs / TICK_MS);

    this.timer = setInterval(() => {
      if (this.toLeft) {
        this.dx = this.dx - step;
        // 越界立刻 +half 回位：因为 images 是首尾相接的 2N 张，
        // 回位前后的画面逐像素相同，看不出跳变
        if (this.dx <= -half) {
          this.dx = this.dx + half;
        }
      } else {
        this.dx = this.dx + step;
        if (this.dx >= 0) {
          this.dx = this.dx - half;
        }
      }
    }, TICK_MS);
  }

  /** 退出 tab / 页面销毁时必须清——不清就是一个高频定时器永远在跑（工程里踩过） */
  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  build() {
    // 外层是 wxss 的 `.band`：定高、裁剪、留带间距。**裁剪必须在带这一层**——
    // 里层 track 被 translate 推到带外面时，只有带自己的 clip 会把它切掉；
    // 若把 clip 放在 track 上，裁的是 track 自己的 4128vp 边界，等于没裁，
    // 图会横向漫出屏幕盖到相邻区域。
    Column() {
      Row() {
        ForEach(this.images, (item: MpImage, index: number) => {
          Stack({ alignContent: Alignment.Bottom }) {
            Image(item.thumb)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .draggable(false)
            // .cell-veil：底部 46% 压一层从透明到微暗的渐变，让图与图交界处不发灰。
            // 纯装饰，必须放行点击，否则点格子会先命中这层
            Column()
              .width('100%')
              .height('46%')
              .linearGradient({
                angle: 0,
                colors: [
                  ['#5704080E', 0.0],
                  ['#0004080E', 1.0]
                ]
              })
              .hitTestBehavior(HitTestMode.None)
          }
          .width(this.cellW())
          .height('100%')
          .borderRadius(CELL_RADIUS)
          // 圆角裁切只能用 clip：Stack 没有 overflow
          .clip(true)
          .backgroundColor(CELL_BG)
          // 小程序用的是 inset box-shadow 描边，ArkUI 没有 inset，
          // 用 0.5vp 的极淡描边等效（1rpx 的一半，视觉上一样是「一层内发光」）
          .border({ width: 0.5, color: '#14FFFFFF' })
          .margin({ right: CELL_GAP })
          .onClick(() => {
            this.onOpen(item);
          })
        }, (item: MpImage, index: number) => item.id + '@' + String(index))
      }
      .width(this.halfW() * 2)
      .height('100%')
      // translate 不参与布局：track 仍然是 2N 格的自然宽度，只是画的时候整体偏移
      .translate({ x: this.dx })
    }
    .width('100%')
    // 左对齐：css 的 track 是从带的左边起排的。Columns 默认居中，
    // 会让 4128vp 的 track 有一半甩到屏幕左侧、首帧看到的不是第一张
    .alignItems(HorizontalAlign.Start)
    // 高度由父级的 layoutWeight 分配（对位 wxss 的 flex: 232/164），
    // 这里**不能再写 height('100%')**：两者同时存在时权重会失效，8 条带会平分高度
    .layoutWeight(this.weight)
    .margin({ bottom: this.isLast ? 0 : BAND_GAP })
    .clip(true)
  }
}

/**
 * 「看全部」纵向清单。
 *
 * 小程序这个入口跳的是独立页 pages/gallery-all（分类浏览器：全部/精选/NASA/视频
 * 四个 tab）。鸿蒙侧没有这条路由，而本次任务只允许改两个文件、不允许新增页面，
 * 所以退一步：在本页切到清单模式，把 gallery 全量分片按三列铺开。
 * 少了分类筛选，但「看全部 N 张」这个入口与「能一路滑到 1118 张」的核心目的达成。
 *
 * 用固定格高（GRID_CELL_H）而不是瀑布流：小程序图墙是 flex 均分的等高带，
 * 清单页也是等高卡片；上一版按 id 做 hash 定高（120~200vp）是凭空加的东西，已删。
 */
@Component
export struct MpAllGrid {
  /** 已加载的图（父级持分片游标，本组件只管画） */
  @Prop photos: MpImage[] = [];
  /** 点单格 */
  onOpen: (item: MpImage) => void = () => {};
  /** 触底。防重复请求的锁在父级 */
  onBottom: () => void = () => {};

  build() {
    WaterFlow() {
      ForEach(this.photos, (item: MpImage, index: number) => {
        FlowItem() {
          Stack() {
            Image(item.thumb)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .draggable(false)
          }
          .width('100%')
          .height(GRID_CELL_H)
          .borderRadius(CELL_RADIUS)
          .clip(true)
          .backgroundColor(CELL_BG)
          .onClick(() => {
            this.onOpen(item);
          })
        }
        .width('100%')
      }, (item: MpImage, index: number) => item.id + '#' + String(index))
    }
    .columnsTemplate(GRID_COLS >= 3 ? '1fr 1fr 1fr' : '1fr 1fr')
    .columnsGap(CELL_GAP)
    .rowsGap(CELL_GAP)
    // 预取 4 行：三列 × 4 = 一屏出头，再多缩略图会常驻白占内存
    .cachedCount(12)
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
