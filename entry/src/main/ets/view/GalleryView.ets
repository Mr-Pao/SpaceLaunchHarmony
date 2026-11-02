/**
 * view/GalleryView.ets —— 「图库」tab
 *
 * 对位小程序：
 *   pages/gallery/gallery.vue（六条 band 图墙 + 四路数据池 + 触底增量）
 *   pages/gallery-all/gallery-all.vue（分类浏览器）
 *
 * 结构（自上而下）：
 *   页头「图库」+ 副标题 → 横向可滚分段控件（精选 / NASA）→ 瀑布流 → 底部状态行
 *
 * ── 精选 / NASA 两档是怎么定的 ──
 *   小程序是「每日一图 / 每日天文 / 每日地球 / NASA」四档（apod / epic / gallery / nasaImages
 *   四路数据池合并去重）。鸿蒙侧按要求砍到两档，但不是随便砍：
 *     · 精选 = gallery 数据集（696 张发射影像，带分片，是唯一需要增量加载的一档）
 *     · NASA = nasaImages 数据集（316 张星云精选，一次性拿到，无分片）
 *   apod / epic 只各有一条「每日」内容，已经在 TodayView 的三卡里出现过，
 *   再放进图库 tab 只会重复。所以这两档不是漏做，是**有意不搬**。
 *
 * ── 为什么第 0 片用 load 而不是 chunk ──
 *   Repository.chunk('gallery', 0) 的返回值是 ChunkResult，**不带 count**（只有 chunks /
 *   chunkSize / list），而副标题要的是全量条数（696 而不是本片 500）。
 *   索引文件 gallery.json 本身就含第 0 片，用 load 一次拿全 count + chunks + list，
 *   比「chunk(0) 拿列表 + 再 load 一次拿 count」少一次解码。触底追加则一律走
 *   chunk('gallery', next) —— 分片的真正用途在那里。
 *
 * ── 终止条件为什么不用 res.end ──
 *   见 data/Repository.ets:610-627 的 toChunk：index > 0 时上层传 d=undefined，
 *   于是 chunks 恒为 1、**end 恒为 true**。直接信 res.end 会在第一片之后就停止加载。
 *   所以这里自己记住索引文件里的 chunks（当前 2），用 next >= chunks 收口。
 *
 * ── 其余有意差异 ──
 *   1. 点击一律进看图器（Nav.pushPhoto）。小程序发射图会进 launchInfo 的图片优先态，
 *      鸿蒙侧看图器只有一个入口。
 *   2. 不做 shuffle。瀑布流分片追加要求「已渲染前缀不重排」，一 shuffle 整墙就跳。
 *   3. NASA 首次切到才拉（节省流量）：316 条带 desc/descZh 的 payload 不小，
 *      用户可能整个会话都不看这一档。
 *
 * ⚠ 日志一律 hilog，不用 console。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions, ChunkResult } from '../data/Repository';
import { strOf } from '../utils/Format';
import { fullImageOf } from '../utils/Media';
import {
  GalleryGrid, GxDataSource, GxPhoto, gxPhotoHeight,
  GxGalleryRaw, GxGalleryPayload, GxNasaRaw, GxNasaPayload
} from '../components/GalleryGrid';
import { Nav } from '../routes/Nav';
import { PhotoNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'GalleryView';

/** 页面底色（与 Index.ets / EntryAbility 窗口底色同值，避免首帧色差） */
const BG_PRIMARY: string = '#0A0E17';
const TXT_MAIN: string = '#FFFFFF';
const TXT_SUB: string = '#A7B4C7';
const TXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
/** 左右安全边距，与 TodayView 的 PAGE_PAD 对齐 */
const PAGE_PAD: number = 12;
/** 底部留给悬浮胶囊的空白（胶囊是浮层，不是布局元素） */
const BOTTOM_PAD: number = 92;

/** 分段控件下标 */
const TAB_FEATURED: number = 0;
const TAB_NASA: number = 1;

/**
 * 骨架网格的形状。
 * 写成常量数组而不是 `ForEach([0, 1], ...)` 内联字面量：ArkTS 对裸字面量的元素类型
 * 推断在 ForEach 回调参数上不稳，显式声明 number[] 才不会被当成无类型对象。
 */
const SK_ROWS: number[] = [0, 1];
const SK_COLS: number[] = [0, 1, 2];

@Component
export struct GalleryView {
  // ============ 渲染状态 ============

  /** 当前档位 */
  @State tab: number = TAB_FEATURED;
  /** 精选是否还在等首片（只影响骨架，不影响已渲染内容） */
  @State loading: boolean = true;
  /** 精选已上屏条数（= ds.totalCount()，但状态变量才能驱动条件渲染） */
  @State featuredCount: number = 0;
  /** 精选全量条数（索引文件的 count，副标题用） */
  @State featuredTotal: number = 0;
  /** NASA 已上屏条数 */
  @State nasaCount: number = 0;
  @State nasaLoading: boolean = false;
  /** 精选首片失败：要和「真实空数据」区分开，否则弱网下会显示「暂无影像」误导用户 */
  @State failed: boolean = false;

  // ============ 数据源（普通成员，不进 @State） ============

  /**
   * 瀑布流数据源。
   * 不能放 @State：@State 会对对象做代理，而 LazyForEach 的增量刷新靠我们自己分发，
   * 代理会把一次 append 放大成整树重建，696 格直接卡死。
   */
  private featuredDs: GxDataSource = new GxDataSource();
  private nasaDs: GxDataSource = new GxDataSource();

  // ============ 分片与加载锁 ============

  /** 下一片索引（索引文件已含第 0 片，所以从 1 开始） */
  private nextIndex: number = 1;
  /** 总片数：只由索引文件更新，见文件头「终止条件」 */
  private chunks: number = 1;
  /** 追加锁：onReachEnd 会连续触发多次，没有这把锁会重复请求同一片 */
  private appending: boolean = false;
  /** 已到末尾（追加锁之外的第二个闸门，避免空转） */
  private ended: boolean = false;

  /** 还没结束的加载路数。收口逻辑同 TodayView：减到 0 才关 loading */
  private pending: number = 0;
  /** NASA 是否已经拉过（成功或失败都算，避免切 tab 时反复请求） */
  private nasaTried: boolean = false;
  private nasaInflight: boolean = false;

  // 只留分段控件的 Scroller：瀑布流自己的滚动由 WaterFlow 内部持有，
  // 页面这一层没有需要程序化控制的滚动目标
  private segScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.loadFeatured();
  }

  // ============ 加载 ============

  /** 精选首片（索引文件，同时带 count / chunks） */
  private loadFeatured(): void {
    this.pending = this.pending + 1;
    this.loading = true;
    this.failed = false;

    const opts: LoadOptions<GxGalleryPayload> = {};
    // 有缓存先渲染、再静默刷新：软 TTL 12 小时的图库没必要每次进页转圈
    opts.onUpdate = (data: GxGalleryPayload) => {
      this.applyFeatured(data);
    };

    repo.load<GxGalleryPayload>('gallery', opts)
      .then((data: GxGalleryPayload) => {
        this.applyFeatured(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'gallery 索引加载失败: %{public}s', e.message);
        if (this.featuredDs.totalCount() === 0) {
          this.failed = true;
        }
      })
      .then(() => {
        this.settle();
      });
  }

  /** 索引文件上屏：整份重置数据源，并把分片游标归零 */
  private applyFeatured(data: GxGalleryPayload): void {
    const raw: GxGalleryRaw[] = data.list !== undefined && data.list !== null ? data.list : [];
    const photos: GxPhoto[] = this.toFeatured(raw, 0);
    if (photos.length === 0) {
      return;
    }

    this.featuredDs.reset(photos);
    this.featuredCount = photos.length;
    // count 是全量（696），list.length 只是本片（500）
    this.featuredTotal = data.count !== undefined && data.count > 0 ? data.count : photos.length;
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

    repo.chunk<GxGalleryRaw>('gallery', idx)
      .then((res: ChunkResult<GxGalleryRaw>) => {
        const photos: GxPhoto[] = this.toFeatured(res.list, this.featuredDs.totalCount());
        if (photos.length === 0) {
          // 空片说明索引与真实分片对不上，直接收口，别让用户一直滑
          this.ended = true;
          return;
        }
        this.featuredDs.append(photos);
        this.featuredCount = this.featuredCount + photos.length;
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
    if (this.nasaTried || this.nasaInflight) {
      return;
    }
    this.nasaInflight = true;
    this.nasaLoading = true;
    // 先加计数再发请求：请求的回调可能早于下面的赋值执行（缓存命中时是微任务）
    this.pending = this.pending + 1;

    const opts: LoadOptions<GxNasaPayload> = {};
    opts.onUpdate = (data: GxNasaPayload) => {
      this.applyNasa(data);
    };

    repo.load<GxNasaPayload>('nasaImages', opts)
      .then((data: GxNasaPayload) => {
        this.applyNasa(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'nasaImages 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.nasaLoading = false;
        this.nasaInflight = false;
        this.nasaTried = true;
        this.pending = this.pending - 1;
        if (this.pending < 0) {
          this.pending = 0;
        }
      });
  }

  private applyNasa(data: GxNasaPayload): void {
    const raw: GxNasaRaw[] = data.list !== undefined && data.list !== null ? data.list : [];
    const photos: GxPhoto[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: GxNasaRaw = raw[i];
      const thumb: string = strOf(item.thumb);
      const full: string = strOf(item.full);
      // thumb 与 full 是两个不同 hash 的地址，不能互相推导（推出来的 _2000 是 404）
      const cover: string = thumb.length > 0 ? thumb : full;
      if (cover.length === 0) {
        continue;
      }
      const key: string = 'nasa-' + (strOf(item.id).length > 0 ? strOf(item.id) : String(i));
      const zh: string = strOf(item.titleZh);
      const en: string = strOf(item.title);
      const title: string = zh.length > 0 ? zh : en;
      const theme: string = strOf(item.themeName);
      const tag: string = theme.length > 0 ? theme : strOf(item.theme);
      photos.push(new GxPhoto(key, cover, full.length > 0 ? full : cover,
        title, strOf(item.center), tag, gxPhotoHeight(key)));
    }
    if (photos.length === 0) {
      return;
    }
    this.nasaDs.reset(photos);
    this.nasaCount = photos.length;
  }

  /**
   * 通用收尾：加载路数减一，归零才关骨架。
   * NASA 走自己的 inflight 锁，这里只管精选（含后续 force 刷新），
   * 但计数仍共用，避免以后加第三档时又造一套标志位。
   */
  private settle(): void {
    this.pending = this.pending - 1;
    if (this.pending <= 0) {
      this.pending = 0;
      this.loading = false;
    }
  }

  // ============ 数据整形 ============

  /**
   * gallery 原始条目 → 瀑布流视图模型。
   * offset 用来拼 key：不同片里 id 理论上唯一，但历史上出现过重复 id（同一发多图），
   * 加偏移保证 LazyForEach 的 key 绝对不冲突。
   */
  private toFeatured(raw: GxGalleryRaw[], offset: number): GxPhoto[] {
    const out: GxPhoto[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: GxGalleryRaw = raw[i];
      const thumb: string = strOf(item.thumb);
      if (thumb.length === 0) {
        // 没有缩略图在格子里就是一块黑，直接剔掉（同 TodayView 的过滤口径）
        continue;
      }
      const id: string = strOf(item.id);
      const key: string = (id.length > 0 ? id : 'g-' + String(offset + i)) + '#' + String(offset + i);
      // 发射图可从缩略图推出 _2000 原图；推不出来就退回缩略图
      const full: string = fullImageOf(thumb);
      out.push(new GxPhoto(key, thumb, full.length > 0 ? full : thumb,
        this.titleOf(item.name), strOf(item.cname), '', gxPhotoHeight(key)));
    }
    return out;
  }

  /** 'Falcon 9 Block 5 | Starlink Group 15-18' → 'Starlink Group 15-18'（Task 口径同 TodayView.ets:428） */
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

  /** 点格子进看图器。full 已在造数据时解析好，这里不做字符串运算 */
  private openPhoto(item: GxPhoto): void {
    const url: string = item.full.length > 0 ? item.full : item.thumb;
    if (url.length === 0) {
      return;
    }
    Nav.pushPhoto(new PhotoNavParam(url, item.title));
  }

  /** 副标题：跟着档位与数据量走，给用户一个「有多少东西」的量感 */
  private subtitle(): string {
    if (this.tab === TAB_FEATURED) {
      if (this.featuredTotal > 0) {
        return `发射影像精选 · 共 ${this.featuredTotal} 张`;
      }
      return this.loading ? '正在加载影像…' : '发射影像精选';
    }
    if (this.nasaCount > 0) {
      return `NASA 影像库 · ${this.nasaCount} 张`;
    }
    return this.nasaLoading ? '正在加载 NASA 影像…' : 'NASA 影像库';
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

  /** 页头：标题 + 副标题，字号/行距与 TodayView 的日期行同一套 */
  @Builder
  header() {
    Column() {
      Text('图库')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TXT_MAIN)
        .letterSpacing(0.5)
      Text(this.subtitle())
        .fontSize(11)
        .fontColor('#6B7891')
        .margin({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
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
    if (this.featuredCount === 0) {
      if (this.loading) {
        this.skeleton()
      } else if (this.failed) {
        this.hint('影像加载失败', '下拉或重新进入本页再试一次', true)
      } else {
        this.hint('暂无精选影像', '数据管道还没产出这一批', false)
      }
    } else {
      // 必须包一层 layoutWeight：GalleryGrid 内部 WaterFlow 是 height('100%')，
      // 直接和状态行并列会被撑满父级，把状态行挤出可视区
      Column() {
        GalleryGrid({
          ds: this.featuredDs,
          colCount: 3,
          onSelect: (item: GxPhoto) => {
            this.openPhoto(item);
          },
          onBottom: () => {
            this.loadMore();
          }
        })
      }
      .layoutWeight(1)
      .width('100%')

      this.statusRow()
    }
  }

  /** NASA：两列。一次性数据，没有触底逻辑，所以状态行只报总数 */
  @Builder
  nasaBody() {
    if (this.nasaCount === 0) {
      if (this.nasaLoading) {
        this.skeleton()
      } else {
        this.hint('暂无 NASA 影像', '第一次进入会联网拉取', false)
      }
    } else {
      Column() {
        GalleryGrid({
          ds: this.nasaDs,
          colCount: 2,
          onSelect: (item: GxPhoto) => {
            this.openPhoto(item);
          },
          onBottom: () => {
          }
        })
      }
      .layoutWeight(1)
      .width('100%')

      Text(`已加载全部 ${this.nasaCount} 张`)
        .fontSize(10)
        .fontColor(TXT_DIM)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 8, bottom: 4 })
    }
  }

  /**
   * 底部状态行。
   * 放在瀑布流外面而不是塞一个 FlowItem 当页脚：FlowItem 必须占一个格子，
   * 塞进去会让最后一行的列高被页脚拉长，视觉上是「破版」。
   */
  @Builder
  statusRow() {
    Text(this.appending ? '正在加载更多…' : (this.ended ? `共 ${this.featuredCount} 张 · 已全部加载`
      : `已加载 ${this.featuredCount} 张 · 继续下滑`))
      .fontSize(10)
      .fontColor(TXT_DIM)
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 8, bottom: 4 })
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
              .borderRadius(8)
              .backgroundColor('#141A26')
              .margin({ right: col === SK_COLS.length - 1 ? 0 : 6, bottom: 6 })
          }, (col: number) => 'sk-' + row + '-' + col)
        }
        .width('100%')
      }, (row: number) => 'sk-row-' + row)
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
