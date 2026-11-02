/**
 * view/GalleryView.ets —— 「图库」tab
 *
 * 对位小程序 pages/gallery/gallery.vue（804 行）。
 *
 * 视觉基准（按小程序截图实测，这是复刻目标）：
 *   顶部：`SPACE GALLERY`（10vp 青蓝 #38BDF8，letterSpacing 1.5，大写）
 *         + `1118 张`（11vp #6B7891，紧跟其后，同一行）
 *   主体：**3 列瀑布流，图与图几乎无缝**（列间距 4vp、行间距 4vp），圆角 6vp
 *   底部：半透明黑条提示「👁 点任一张看详情」+ 右侧加载进度
 *
 * ── 与小程序的有意差异 ──
 *   1. 小程序是「8 条横带 + translateX 循环漂移」，每次进页 shuffle 96 张铺满。
 *      鸿蒙这边改成**纵向三列瀑布流**：这里是完整列表（1118 张），
 *      横带漂移只适合「看不完的墙」，清单式浏览反而要能一路滑到底。
 *   2. 小程序中央的「看全部 1118 ›」胶囊不搬 —— 鸿蒙侧已经在看全部了，
 *      多一个胶囊只会挡住图。它的信息量（总张数）挪进页头与底部提示条。
 *   3. 不做 shuffle。分片追加要求「已渲染前缀不重排」，一 shuffle 整墙就跳。
 *   4. 保留 `精选 / NASA` 双段（小程序主 tab 没有 NASA 段，那是 gallery-all 的），
 *      但 NASA 段独立读 nasaImages 的 thumb / full，见 applyNasa 注释。
 *
 * ── 分片加载（关键） ──
 *   第 0 片在索引文件 gallery.json 里（load 一次拿到 list + count + chunks）；
 *   后续片走 repo.chunk('gallery', next)。
 *   **终止条件只认索引文件的 chunks（nextIndex >= chunks），不用 res.end**：
 *   见 data/Repository.ets:610-627 的 toChunk —— index>0 时上层传 d=undefined，
 *   于是 chunks 恒为 1、**end 恒为 true**。信 res.end 会在第一片后就停。
 *
 * ── 数据量与状态 ──
 *   全量放普通成员 `private all: GlPhoto[]`（不进 @State，避免 1000+ 条被代理）；
 *   `@State photos` 只放已加载、要上屏的那一份，追加时整体换成新数组（concat），
 *   这样 ArkUI 才会观察到变化。
 *
 * ⚠ 日志一律 hilog，不用 console。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions, ChunkResult } from '../data/Repository';
import { strOf } from '../utils/Format';
import { fullImageOf } from '../utils/Media';
import {
  GalleryGrid, GlPhoto, heightOf,
  GlGalleryRaw, GlGalleryPayload, GlNasaRaw, GlNasaPayload
} from '../components/GalleryGrid';
import { Nav } from '../routes/Nav';
import { PhotoNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'GalleryView';

/** 页面底色（与 Index.ets / EntryAbility 窗口底色同值，避免首帧色差） */
const BG_PRIMARY: string = '#0A0E17';
const TXT_SUB: string = '#A7B4C7';
const TXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
/** 页头左右边距：比内容区大一点，标题不要贴着瀑布流 */
const PAGE_PAD: number = 12;
/** 底部留给悬浮胶囊的空白（胶囊是浮层，不是布局元素） */
const BOTTOM_PAD: number = 92;

/** 分段控件下标 */
const TAB_FEATURED: number = 0;
const TAB_NASA: number = 1;

/**
 * 骨架网格的形状。
 * 写成常量数组而不是 `ForEach([0, 1], ...)` 内联字面量：ArkTS 对裸字面量的
 * 元素类型推断在 ForEach 回调参数上不稳，显式声明 number[] 才不会报错。
 */
const SK_ROWS: number[] = [0, 1];
const SK_COLS: number[] = [0, 1, 2];
/** NASA 是两列，骨架也两列，切档时不出现「3 列灰块变 2 列图」的错位感 */
const SK_COLS2: number[] = [0, 1];

@Component
export struct GalleryView {
  // ============ 渲染状态 ============

  /** 当前档位 */
  @State tab: number = TAB_FEATURED;
  /** 已加载、要上屏的图。追加时整份替换（concat 返回新数组） */
  @State photos: GlPhoto[] = [];
  /** 精选是否还在等首片（只影响骨架，不影响已渲染内容） */
  @State loading: boolean = true;
  /** 精选全量张数（索引文件的 count，页头「1118 张」用它） */
  @State total: number = 0;
  /** 追加中 / 已到末尾。底部提示条照它们换文案，所以必须进 @State */
  @State appending: boolean = false;
  @State ended: boolean = false;
  /** 首片失败：要和「真实空数据」区分开，否则弱网下显示「暂无影像」会误导 */
  @State failed: boolean = false;

  /** NASA 档 */
  @State nasaPhotos: GlPhoto[] = [];
  @State nasaTotal: number = 0;
  @State nasaLoading: boolean = false;

  // ============ 数据（普通成员，不进 @State） ============

  /**
   * 全量已加载图片的母本。
   * 不直接拿 @State photos 当母本：每次追加都要从母本 concat 出新数组给 @State，
   * 母本自己必须是普通成员，才不会被状态代理拖慢（1000+ 条对象）。
   */
  private all: GlPhoto[] = [];
  /** 下一片索引（第 0 片已在索引文件里，所以从 1 开始） */
  private nextIndex: number = 1;
  /** 总片数：只由索引文件更新，见文件头「终止条件」 */
  private chunks: number = 1;
  /** 精选索引文件的 generatedAt，用来识别「同一份数据的重复回调」 */
  private featuredStamp: string = '';
  /** NASA 是否拉过（成功或失败都算，避免切 tab 反复请求） */
  private nasaTried: boolean = false;
  private nasaStamp: string = '';

  // 只留分段控件的 Scroller：瀑布流自己的滚动由 WaterFlow 内部持有
  private segScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.loadFeatured();
  }

  /**
   * 本页没有定时器 / 动画句柄 / 监听器，无需清理。
   * 故意留这个空实现并写明原因：以后若加了轮播或 debounce，必须在这里清掉，
   * 否则退出 tab 后定时器还在跑（工程里踩过一次）。
   */
  aboutToDisappear(): void {
  }

  // ============ 加载 ============

  /** 精选第 0 片（索引文件，同时带 count / chunks） */
  private loadFeatured(): void {
    this.loading = true;
    this.failed = false;

    const opts: LoadOptions<GlGalleryPayload> = {
      // 有缓存先渲染、再静默刷新：图库软 TTL 很长，没必要每次进页转圈。
      // applyFeatured 按 generatedAt 去重，后台刷新不会把已追加的分片冲掉。
      onUpdate: (data: GlGalleryPayload) => {
        this.applyFeatured(data);
      }
    };

    repo.load<GlGalleryPayload>('gallery', opts)
      .then((data: GlGalleryPayload) => {
        this.applyFeatured(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'gallery 索引加载失败: %{public}s', e.message);
        if (this.all.length === 0) {
          this.failed = true;
        }
      })
      .then(() => {
        this.loading = false;
      });
  }

  /** 索引文件上屏：整份重置，并把分片游标归零 */
  private applyFeatured(data: GlGalleryPayload): void {
    const stamp: string = strOf(data.generatedAt);
    // onUpdate 是「后台刷新」回调，同一份 generatedAt 会重复进来。
    // 每次都 reset 会把用户已触底追加的分片全部退回第 0 片，滚动位置也跟着跳。
    if (this.all.length > 0 && stamp.length > 0 && stamp === this.featuredStamp) {
      return;
    }
    this.featuredStamp = stamp;

    const raw: GlGalleryRaw[] = data.list !== undefined && data.list !== null ? data.list : [];
    const first: GlPhoto[] = this.toPhotos(raw);
    if (first.length === 0) {
      return;
    }

    this.all = first;
    this.photos = first;
    // count 是全量（1118），list.length 只是本片（500）
    this.total = data.count !== undefined && data.count > 0 ? data.count : first.length;
    this.chunks = data.chunks !== undefined && data.chunks > 0 ? data.chunks : 1;
    this.nextIndex = 1;
    this.ended = this.nextIndex >= this.chunks;
    this.failed = false;
  }

  /**
   * 触底追加。
   * 三道闸门：锁、末尾、片号越界 —— 缺任何一个都会在快速滑动时重复拉同一片
   * 或反复空转请求。
   */
  private loadMore(): void {
    if (this.appending || this.ended || this.tab !== TAB_FEATURED) {
      return;
    }
    if (this.nextIndex >= this.chunks) {
      this.ended = true;
      return;
    }

    this.appending = true;
    const idx: number = this.nextIndex;

    repo.chunk<GlGalleryRaw>('gallery', idx)
      .then((res: ChunkResult<GlGalleryRaw>) => {
        const more: GlPhoto[] = this.toPhotos(res.list);
        if (more.length === 0) {
          // 空片说明索引与真实分片对不上，直接收口，别让用户一直往下滑
          this.ended = true;
          return;
        }
        // concat 返回新数组 → 赋值给 @State 才会触发重绘。
        // 不能 push（push 改的是同一个引用，ArkUI 观察不到）
        const next: GlPhoto[] = this.all.concat(more);
        this.all = next;
        this.photos = next;
        this.nextIndex = idx + 1;
        if (this.nextIndex >= this.chunks) {
          this.ended = true;
        }
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'gallery 第 %{public}d 片失败: %{public}s', idx, e.message);
        // 失败不置 ended：下次触底还能重试这一片（chunk 内部有 inflight 去重）
      })
      .then(() => {
        this.appending = false;
      });
  }

  /** NASA 一次性拉全量。只有第一次切到该档才触发 */
  private loadNasa(): void {
    if (this.nasaTried) {
      return;
    }
    this.nasaTried = true;
    this.nasaLoading = true;

    const opts: LoadOptions<GlNasaPayload> = {
      onUpdate: (data: GlNasaPayload) => {
        this.applyNasa(data);
      }
    };

    repo.load<GlNasaPayload>('nasaImages', opts)
      .then((data: GlNasaPayload) => {
        this.applyNasa(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'nasaImages 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.nasaLoading = false;
      });
  }

  private applyNasa(data: GlNasaPayload): void {
    const stamp: string = strOf(data.generatedAt);
    // 同 applyFeatured：onUpdate 会把同一份数据再送一次，重铺会跳滚动位置
    if (this.nasaPhotos.length > 0 && stamp.length > 0 && stamp === this.nasaStamp) {
      return;
    }
    this.nasaStamp = stamp;

    const raw: GlNasaRaw[] = data.list !== undefined && data.list !== null ? data.list : [];
    const out: GlPhoto[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: GlNasaRaw = raw[i];
      const thumb: string = strOf(item.thumb);
      const full: string = strOf(item.full);
      // thumb 与 full 是两个不同 hash 的地址，不能互相推导（推出来的 _2000 是 404）。
      // 两个都缺才丢：缺 thumb 时用 full 也能显示，只是多耗流量
      const cover: string = thumb.length > 0 ? thumb : full;
      if (cover.length === 0) {
        continue;
      }
      const rawId: string = strOf(item.id);
      const key: string = 'nasa-' + (rawId.length > 0 ? rawId : String(i));
      const zh: string = strOf(item.titleZh);
      const title: string = zh.length > 0 ? zh : strOf(item.title);
      // 高度按 key 算：同一张图每次进页一致，不会因重排跳动
      out.push(new GlPhoto(key, cover, full.length > 0 ? full : cover, title, heightOf(key)));
    }
    if (out.length === 0) {
      return;
    }
    this.nasaPhotos = out;
    this.nasaTotal = data.count !== undefined && data.count > 0 ? data.count : out.length;
  }

  // ============ 数据整形 ============

  /**
   * gallery 原始条目 → 视图模型。
   * 直接遍历原数组而不拼 offset key：ForEach 的 key 由组件侧拼下标，
   * 这里只用 id 算高度，保证同一张图在任何片里高度都一样。
   */
  private toPhotos(raw: GlGalleryRaw[]): GlPhoto[] {
    const out: GlPhoto[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: GlGalleryRaw = raw[i];
      const thumb: string = strOf(item.thumb);
      if (thumb.length === 0) {
        // 没有缩略图在格子里就是一块黑，直接剔掉（同 TodayView 的过滤口径）
        continue;
      }
      const id: string = strOf(item.id);
      const key: string = id.length > 0 ? id : 'g-' + String(i);
      // 发射图可从缩略图推出 _2000 原图；推不出来就退回缩略图
      const full: string = fullImageOf(thumb);
      out.push(new GlPhoto(key, thumb, full.length > 0 ? full : thumb,
        this.titleOf(item.name), heightOf(key)));
    }
    return out;
  }

  /** 'Falcon 9 Block 5 | Starlink Group 15-18' → 'Starlink Group 15-18' */
  private titleOf(name: string | undefined): string {
    const raw: string = strOf(name);
    if (raw.length === 0) {
      return '';
    }
    const parts: string[] = raw.split('|');
    const picked: string = parts.length > 1 ? parts[1] : parts[0];
    return picked.trim();
  }

  // ============ 交互 ============

  private switchTab(i: number): void {
    if (this.tab === i) {
      return;
    }
    this.tab = i;
    if (i === TAB_NASA) {
      this.loadNasa();
    }
  }

  /** 点格子进看图器。看图器自己还会再试一次 fullImageOf，这里给最可能是原图的地址 */
  private openPhoto(item: GlPhoto): void {
    const url: string = item.full.length > 0 ? item.full : item.thumb;
    if (url.length === 0) {
      return;
    }
    Nav.pushPhoto(new PhotoNavParam(url, item.title));
  }

  /** 页头右侧的「N 张」 */
  private countLabel(): string {
    if (this.tab === TAB_FEATURED) {
      const n: number = this.total > 0 ? this.total : this.photos.length;
      return n > 0 ? `${n} 张` : '';
    }
    const m: number = this.nasaTotal > 0 ? this.nasaTotal : this.nasaPhotos.length;
    return m > 0 ? `${m} 张` : '';
  }

  /**
   * 底部提示条文案。
   * 小程序这里是「👁 点任一张看详情」一行，鸿蒙侧再挂上进度：
   * 1118 张分 3 片，不告诉用户「还能再加载」他会在第一片末尾以为到底了。
   */
  private tipText(): string {
    if (this.tab === TAB_FEATURED) {
      const loaded: number = this.photos.length;
      if (this.appending) {
        return '正在加载更多…';
      }
      if (this.ended || (this.total > 0 && loaded >= this.total)) {
        return `已全部加载 ${loaded} 张`;
      }
      return `已加载 ${loaded} 张 · 继续下滑`;
    }
    return this.nasaLoading ? '正在加载 NASA 影像…' : '已全部加载';
  }

  // ============ UI ============

  build() {
    Column() {
      this.header()
      this.segments()

      Column() {
        if (this.tab === TAB_FEATURED) {
          this.featuredBody()
        } else {
          this.nasaBody()
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: PAGE_PAD, right: PAGE_PAD })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    // ★ 92vp：避开底部悬浮胶囊。胶囊是 Stack 浮层，内容区会一路铺到屏幕底
    .padding({ bottom: BOTTOM_PAD })
  }

  /**
   * 页头：`SPACE GALLERY` + `N 张`。
   * 与小程序一致 —— 不写「图库」两个字，用英文 kicker 当标识，
   * 张数紧跟其后同色阶下降，形成一条极轻的信息行。
   */
  @Builder
  header() {
    Row() {
      Row() {
        Text('SPACE GALLERY')
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(ACCENT)
          .letterSpacing(1.5)
        Text(this.countLabel())
          .fontSize(11)
          .fontColor('#6B7891')
          .margin({ left: 8 })
          .maxLines(1)
      }
      .alignItems(VerticalAlign.Center)
      .layoutWeight(1)

      // 视频库入口。小程序那边视频库挂在 gallery-all 的第四个分段里，
      // 鸿蒙侧图库主 tab 只有精选/NASA 两段，把入口放页头右侧比塞第三段更直接：
      // 视频和图片是两种完全不同的浏览节奏，混在一个分段条里反而互相拖累。
      Row() {
        Text('▶')
          .fontSize(9)
          .fontColor(ACCENT)
        Text('视频')
          .fontSize(11.5)
          .fontColor(ACCENT)
          .margin({ left: 3 })
        Text('›')
          .fontSize(13)
          .fontColor('#55617A')
          .margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 9, right: 7, top: 4, bottom: 4 })
      .borderRadius(11)
      .backgroundColor('#1A2437')
      .onClick(() => {
        Nav.pushVideos('');
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 12, bottom: 10 })
  }

  /**
   * 分段控件。
   * 用小胶囊而不是 Tabs：档位只有两个，Tabs 的滑动惯性在这里是干扰；
   * 外面套横向 Scroll 是为了以后加档时不用改布局（两个档时它就是不可滚的）。
   */
  @Builder
  segments() {
    Scroll(this.segScroller) {
      Row() {
        this.segItem('精选', TAB_FEATURED)
        this.segItem('NASA', TAB_NASA)
      }
      .alignItems(VerticalAlign.Center)
      .margin({ left: PAGE_PAD, right: PAGE_PAD })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ bottom: 10 })
  }

  @Builder
  segItem(label: string, idx: number) {
    Text(label)
      .fontSize(12)
      .fontWeight(this.tab === idx ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.tab === idx ? ACCENT : TXT_SUB)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .backgroundColor(this.tab === idx ? '#1B2A3C' : '#141A26')
      .borderRadius(14)
      .margin({ right: 8 })
      .onClick(() => {
        this.switchTab(idx);
      })
  }

  /** 精选：骨架 / 失败 / 空 / 瀑布流 四态 */
  @Builder
  featuredBody() {
    if (this.photos.length === 0) {
      if (this.loading) {
        this.skeleton()
      } else if (this.failed) {
        this.hint('影像加载失败', '重新进入本页再试一次', true)
      } else {
        this.hint('暂无精选影像', '数据管道还没产出这一批', false)
      }
    } else {
      // 外层 Column 是 @Builder 的唯一根节点（ArkUI 要求分支内只能有一个根），
      // 内层 Column 是为了给 WaterFlow 的 height('100%') 一个受约束的父级：
      // 直接和提示条并列会被撑满，把提示条挤出可视区
      Column() {
        Column() {
          GalleryGrid({
            photos: this.photos,
            colCount: 3,
            onOpen: (item: GlPhoto) => {
              this.openPhoto(item);
            },
            onBottom: () => {
              this.loadMore();
            }
          })
        }
        .layoutWeight(1)
        .width('100%')

        this.tipBar()
      }
      .layoutWeight(1)
      .width('100%')
    }
  }

  /** NASA：两列。一次性数据，没有触底逻辑，提示条只报总数 */
  @Builder
  nasaBody() {
    if (this.nasaPhotos.length === 0) {
      if (this.nasaLoading) {
        this.skeletonTwo()
      } else {
        this.hint('暂无 NASA 影像', '第一次进入会联网拉取', false)
      }
    } else {
      Column() {
        Column() {
          GalleryGrid({
            photos: this.nasaPhotos,
            colCount: 2,
            onOpen: (item: GlPhoto) => {
              this.openPhoto(item);
            },
            onBottom: () => {
            }
          })
        }
        .layoutWeight(1)
        .width('100%')

        this.tipBar()
      }
      .layoutWeight(1)
      .width('100%')
    }
  }

  /**
   * 底部提示条：半透明黑条 + 一行小字。
   * 放在瀑布流外面而不是塞一个 FlowItem 当页脚：FlowItem 必须占一个格子，
   * 塞进去会让最后一行的列高被页脚拉长，视觉上是「破版」。
   */
  @Builder
  tipBar() {
    Row() {
      Text('👁  点任一张看详情')
        .fontSize(10)
        .fontColor(TXT_SUB)
        .maxLines(1)
        .layoutWeight(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.tipText())
        .fontSize(10)
        .fontColor(TXT_DIM)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 10, right: 10, top: 7, bottom: 7 })
    .backgroundColor('#0D000000')
    .borderRadius(999)
    .margin({ top: 8, bottom: 4 })
  }

  /** 骨架：两排灰块，形状尽量接近真实格子，避免加载完成后大幅跳版 */
  @Builder
  skeleton() {
    Column() {
      ForEach(SK_ROWS, (row: number) => {
        Row() {
          ForEach(SK_COLS, (col: number) => {
            Column()
              .layoutWeight(1)
              .height(120)
              .borderRadius(6)
              .backgroundColor('#141A26')
              .margin({ right: col === SK_COLS.length - 1 ? 0 : 4, bottom: 4 })
          }, (col: number) => 'sk-' + row + '-' + col)
        }
        .width('100%')
      }, (row: number) => 'sk-row-' + row)
    }
    .width('100%')
  }

  /** NASA 骨架：两列，与真实列数一致，切档时不出现「3 列灰块变 2 列图」的错位感 */
  @Builder
  skeletonTwo() {
    Column() {
      ForEach(SK_ROWS, (row: number) => {
        Row() {
          ForEach(SK_COLS2, (col: number) => {
            Column()
              .layoutWeight(1)
              .height(140)
              .borderRadius(6)
              .backgroundColor('#141A26')
              .margin({ right: col === SK_COLS2.length - 1 ? 0 : 4, bottom: 4 })
          }, (col: number) => 'sk2-' + row + '-' + col)
        }
        .width('100%')
      }, (row: number) => 'sk2-row-' + row)
    }
    .width('100%')
  }

  /** 空态 / 错态。带图标位，别让整屏只剩一行小字 */
  @Builder
  hint(title: string, desc: string, retry: boolean) {
    Column() {
      Text('🛰')
        .fontSize(30)
        .opacity(0.3)
      Text(title)
        .fontSize(13)
        .fontColor(TXT_SUB)
        .margin({ top: 10 })
      Text(desc)
        .fontSize(11)
        .fontColor(TXT_DIM)
        .margin({ top: 6 })

      if (retry) {
        Text('重新加载')
          .fontSize(12)
          .fontColor(ACCENT)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor('#1B2A3C')
          .margin({ top: 14 })
          .onClick(() => {
            this.loadFeatured();
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
