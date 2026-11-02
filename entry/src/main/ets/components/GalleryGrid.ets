/**
 * components/GalleryGrid.ets —— 图库瀑布流（WaterFlow + LazyForEach + IDataSource）
 *
 * 对位小程序：
 *   pages/gallery/gallery.vue 的六条 band 图墙 + pages/gallery-all/gallery-all.vue 的格子
 *   utils/data.js 的 galleryChunk() 增量分片（键名 chunks / chunkSize / total，见 data.js 注释）
 *
 * ── 为什么数据源放在页面、组件只拿一个引用 ──
 *   `@Prop list: GxPhoto[]` 在 ArkUI 里是**深拷贝**：696 条每次触底追加都要整份复制一遍，
 *   追加一次就白烧一次 696 次对象拷贝，还会让整棵 WaterFlow 重排。
 *   所以这里把「数据 + 监听器」封成 GxDataSource（实现 IDataSource），
 *   页面持有一个实例、直接 append()，LazyForEach 通过监听器增量刷新 ——
 *   组件层只负责画，不做任何数组搬运。切换 精选/NASA 时组件被 if/else 重建，
 *   LazyForEach 会重新 registerDataChangeListener，实例里的数据不丢。
 *
 * ── 瀑布流高度为什么由数据侧算 ──
 *   小程序用 `height` 写死的行高 + `aspectFill` 裁切。ArkUI 的 WaterFlow 一旦
 *   等图片加载完再撑高，整墙会从「等高」突变到「错落」，滚动位置也跟着跳。
 *   所以高度在造数据时就用 id 的稳定 hash 定死（gxPhotoHeight），图片只做 Cover 裁切，
 *   加载前后布局完全一致 —— 代价是同一张图的高度与真实比例无关，接受。
 *
 * ── 有意差异（相对小程序） ──
 *   1. 小程序是「六条横带 + 每带横向滚动」，这里按要求改成 **三列瀑布流**（精选）
 *      与 **两列**（NASA）。横带靠 shuffle 让每次进页不同，瀑布流不 shuffle：
 *      分片追加要求「已渲染的前缀不能重排」，否则触底一加载整墙就跳。
 *   2. 点击入口统一走 Nav.pushPhoto（看图器），不再像小程序那样按 kind 分流
 *      （发射图进 launchInfo 的图片优先态）—— 鸿蒙侧看图器只有一个入口。
 *   3. 底部标题条：小程序是整块遮罩 + 多行文字，这里只叠一条 48vp 的渐变 + 单行标题，
 *      格子最小 120vp × ¾ 列宽（≈82vp），放不下两行字。
 *
 * ⚠ 本文件不打控制台日志（纯展示，无 IO）。
 */

/** 单格最小高度（任务书：120~200vp 之间取稳定伪高度） */
const H_MIN: number = 120;
/** 单格最大高度 */
const H_MAX: number = 196;
/** 列间距 / 行间距（任务书 6vp） */
const COL_GAP: number = 6;
/** 单格圆角（任务书 8vp） */
const RADIUS: number = 8;
/** 格子底色：图片未解码时露出的颜色，避免出现纯黑方块 */
const BG_CARD: string = '#141A26';

/**
 * 一张图（视图模型）。
 *
 * 不用原始 JSON 直接渲染：瀑布流需要 h、点击需要已解析好的 full、
 * 标题需要「按 | 取后段」清洗过 —— 这些都在造数据时算一次，
 * 让 cell 里不再有字符串运算（滚动时每帧都会重跑 build）。
 */
export class GxPhoto {
  /** LazyForEach 的 key。缺 id 时退化用地址，保证唯一 */
  key: string = '';
  /** 列表用缩略图（几十 KB，弱网也能一格一格出图） */
  thumb: string = '';
  /** 点击后交给看图器的地址（已按规则解析成原图） */
  full: string = '';
  /** 格子底部那一行标题（已清洗） */
  title: string = '';
  /** 署名（精选是发射商，NASA 是中心名），当前只用于副标题留白，先存着 */
  credit: string = '';
  /** 角标文案：NASA 用主题名（星云/星系…），精选为空 */
  tag: string = '';
  /** 伪高度，由 key 的 hash 决定，同一张图每次进页都一致 */
  h: number = H_MIN;

  constructor(key: string, thumb: string, full: string, title: string,
    credit: string, tag: string, h: number) {
    this.key = key;
    this.thumb = thumb;
    this.full = full;
    this.title = title;
    this.credit = credit;
    this.tag = tag;
    this.h = h;
  }
}

/** getData 越界时的兜底值（LazyForEach 偶尔会在删除瞬间取到越界下标） */
const EMPTY_PHOTO: GxPhoto = new GxPhoto('', '', '', '', '', '', H_MIN);

/**
 * 懒加载数据源。
 *
 * 只实现 LazyForEach 需要的四个方法 + 两个我们自己用的增量口子：
 *   reset(list)  —— 整份换掉（首次加载 / 后台刷新回填），走 onDataReloaded
 *   append(list) —— 触底追加，走 onDatasetChange(ADD)，
 *                  不再用已废弃的 onDataAdd（API 11 起标记 deprecated）
 */
export class GxDataSource implements IDataSource {
  private items: GxPhoto[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): GxPhoto {
    if (index < 0 || index >= this.items.length) {
      return EMPTY_PHOTO;
    }
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const at: number = this.listeners.indexOf(listener);
    if (at >= 0) {
      this.listeners.splice(at, 1);
    }
  }

  /** 整份替换。回调里不许改 items，否则 LazyForEach 的下标会和真实数据错位 */
  reset(list: GxPhoto[]): void {
    this.items = [];
    for (let i = 0; i < list.length; i++) {
      this.items.push(list[i]);
    }
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }

  /** 尾部追加。只有「追加」语义，页面的分片加载天然满足（永不重排已渲染前缀） */
  append(list: GxPhoto[]): void {
    if (list.length === 0) {
      return;
    }
    const start: number = this.items.length;
    for (let i = 0; i < list.length; i++) {
      this.items.push(list[i]);
    }
    const ops: DataOperation[] = [];
    const op: DataOperation = {
      type: DataOperationType.ADD,
      index: start,
      count: list.length
    };
    ops.push(op);
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDatasetChange(ops);
    }
  }
}

/**
 * 稳定 hash：只用来定高度，不做安全用途。
 * 取模 1000003（质数）压住溢出，同一 key 在任何设备上都得同一个数。
 */
function gxHash(key: string): number {
  let h: number = 0;
  for (let i = 0; i < key.length; i++) {
    h = (h * 31 + key.charCodeAt(i)) % 1000003;
  }
  return h;
}

/**
 * 由 key 推一个 120~196vp 的伪高度。
 * 刻意不用图片真实宽高比：图还没下载完时布局就已经定死，滚到底不会抖。
 */
export function gxPhotoHeight(key: string): number {
  const span: number = H_MAX - H_MIN + 1;
  return H_MIN + (gxHash(key) % span);
}

// ============ 数据集形状（按 2026-11-02 线上 COS 实测字段写，全部可选） ============

/**
 * gallery 分片里的单条。
 * 实测样本：{ id, name: 'Falcon 9 Block 5 | Starlink Group 15-18', net, thumb, credit, cname }
 * 索引文件额外带 chunks / chunkSize / count / launchTotal。
 */
export interface GxGalleryRaw {
  id?: string;
  name?: string;
  net?: string;
  thumb?: string;
  credit?: string;
  /** 火箭型号中文名（CI 回填，缺了不影响展示） */
  cname?: string;
}

export interface GxGalleryPayload {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  /** 全量条数（696），不是本片条数 —— 副标题要的是这个 */
  count?: number;
  /** 总片数（2） */
  chunks?: number;
  /** 每片条数（500） */
  chunkSize?: number;
  list?: GxGalleryRaw[];
}

/**
 * nasaImages 单条（NASA Image Library 主题精选）。
 * 实测样本：{ id, theme, themeName, title, desc, date, center, thumb, full,
 *             nasaId, titleZh, descZh }
 *
 * 注意：**thumb 与 full 是两个不同 hash 的地址**（thumb 480px 镜像、full 是 _1080 预设），
 * 不能像 gallery 那样用 fullImageOf(thumb) 互推（互推出来的 _2000 地址是 404）。
 */
export interface GxNasaRaw {
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

export interface GxNasaPayload {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  count?: number;
  /** 主题清单（当前只有一个 nebula），本期不消费，只保证不因多余字段报错 */
  list?: GxNasaRaw[];
}

/**
 * 瀑布流组件。
 *
 * 用法（父级）：
 *   GalleryGrid({ ds: this.galleryDs, colCount: 3,
 *                 onSelect: (p: GxPhoto) => { ... },
 *                 onBottom: () => { 拉下一片 } })
 */
@Component
export struct GalleryGrid {
  /** 数据源引用（不深拷贝，父级 append 后本组件自动增量刷新） */
  ds: GxDataSource = new GxDataSource();
  /** 列数：精选 3、NASA 2。用 @Prop 是为了切 tab 重建时能立刻生效 */
  @Prop colCount: number = 3;
  /** 点击单格。普通成员 + 默认空实现（不能用 @Prop 承载函数） */
  onSelect: (item: GxPhoto) => void = () => {};
  /** 触底。父级负责分片拉取与防重复请求 */
  onBottom: () => void = () => {};

  /** 列模板：3 列 / 2 列。写死字符串而不拼 '1fr '，ArkTS 对字符串 repeat 也不友好 */
  private template(): string {
    return this.colCount >= 3 ? '1fr 1fr 1fr' : '1fr 1fr';
  }

  build() {
    WaterFlow() {
      LazyForEach(this.ds, (item: GxPhoto) => {
        FlowItem() {
          Stack({ alignContent: Alignment.Bottom }) {
            Image(item.thumb)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .draggable(false)

            this.caption(item)
          }
          .width('100%')
          .height(item.h)
          .borderRadius(RADIUS)
          // 圆角裁切用 clip：ColumnAttribute 上没有 overflow
          .clip(true)
          .backgroundColor(BG_CARD)
          .onClick(() => {
            this.onSelect(item);
          })
        }
      }, (item: GxPhoto, index: number) => item.key + '#' + index)
    }
    .columnsTemplate(this.template())
    .columnsGap(COL_GAP)
    .rowsGap(COL_GAP)
    .cachedCount(6)
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    // 触底回调只做「通知父级」，防重复请求的锁在页面侧（组件不持有加载状态）
    .onReachEnd(() => {
      this.onBottom();
    })
  }

  /**
   * 底部渐变 + 标题。
   * 渐变 angle 0 = 从下往上（与工程内 DailyCards.ets / InSpaceRow.ets 同口径），
   * 位置 0 是底部、不透明；位置 1 是顶部、全透明。
   */
  @Builder
  caption(item: GxPhoto) {
    Column() {
      if (item.tag.length > 0) {
        Text(item.tag)
          .fontSize(9)
          .fontColor('#38BDF8')
          .margin({ bottom: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      if (item.title.length > 0) {
        Text(item.title)
          .fontSize(10)
          .fontColor('#E8EEF8')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 6, right: 6, top: 14, bottom: 6 })
    .linearGradient({
      angle: 0,
      colors: [
        ['#E6060A12', 0.0],
        ['#99060A12', 0.55],
        ['#00060A12', 1.0]
      ]
    })
    // 纯装饰层，不吃点击，否则点格子会先命中文字条
    .hitTestBehavior(HitTestMode.None)
  }
}
