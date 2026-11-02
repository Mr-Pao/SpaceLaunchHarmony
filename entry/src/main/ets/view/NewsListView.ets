/**
 * view/NewsListView.ets —— 航天资讯列表页
 *
 * 对位小程序 `pages/news` 列表态（components/news-section 的完整列表）。
 * 小程序是一个页面内「折叠前 N 条 + 展开」，鸿蒙侧做成**独立路由页**：
 * 首页那块 NewsSection 只露 3 条，点「查看全部 ›」进这里看全量。
 *
 * ── 数据链路（与 LaunchView / RocketDetailView 同口径）──
 *   repo.peek<NewsPayload>('news')  —— 同步、零网络，冷启动立刻有内容
 *   repo.load<NewsPayload>('news', {onCache, onUpdate})
 *     onCache  —— 命中原生缓存时立刻上屏
 *     onUpdate —— 缓存过期、后台静默刷新拿到新数据时回填（只有 generatedAt 变了才回调）
 *
 * ── 四态为什么必须分开（原项目踩过的坑）──
 *   小程序 utils/data.js 的 load() 在「弱网 + 无缓存」时是 **reject**。
 *   如果 catch 里直接置 loaded = true，页面就永久停在空列表，用户以为真的没有资讯。
 *   所以这里的失败态用独立的 @State failed 表示，与「空列表」严格分开：
 *     loading && 空    → 加载中
 *     failed  && 空    → 加载失败 + 重试
 *     !failed && 空    → 暂无资讯
 *     list 非空        → 列表（此时哪怕刷新失败也继续显示旧数据）
 *
 * ── 有意差异 ──
 *   1. **底部 padding 24，不是 92**。这一页在详情页栈里，底部没有悬浮胶囊
 *      （Index.ets 在 detailDepth > 0 时把胶囊整个摘掉了），照抄 92 会多出一块空白。
 *   2. **不用 LazyForEach**。news.json 线上实测 100 余条、几十 KB，
 *      List 自带的复用 + cachedCount(3) 足够；LazyForEach 要写 IDataSource，
 *      对这个体量是纯负担。
 *   3. **缩略图 onError 退到占位**。占位垫在图层下方（同 components/NewsSection
 *      的做法），失败时只把 Image 摘掉，不额外维护一张「失败 id 表」。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { NewsItem, NewsPayload, NewsLaunchRef } from '../model/News';
import { strOf, formatGeneratedAt } from '../utils/Format';
import { Nav } from '../routes/Nav';
import { ArticleNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'NewsListView';

// ============ 视觉常量（工程约定） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';

/** 页面左右内边距（与 TodayView / LaunchView 的 12 对齐） */
const PAGE_PAD: number = 12;
/**
 * 底部内边距：**24 不是 92**。
 * 本页属于详情页栈，底部没有悬浮胶囊（见文件头取舍 1）。
 */
const BOTTOM_PAD: number = 24;

/** 缩略图 96×72（任务书给定），比例 4:3 */
const THUMB_W: number = 96;
const THUMB_H: number = 72;

/**
 * 单条缩略图。
 *
 * 为什么单独拆一个 @Component：图片失败是**每条自己的**状态，
 * 挂在列表页上就得维护一张「失败 id 表」并处理集合的响应式更新（ArkTS 对 Set
 * 的元素增删不保证触发重绘）。拆成组件后每条一个 @State imgErr，最简单也最稳。
 */
@Component
struct NewsListThumb {
  /** 封面地址；空串直接画占位 */
  @Prop src: string = '';

  /** 加载失败 → 只撤掉 Image，露出下面的占位层 */
  @State imgErr: boolean = false;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 占位垫在最底下：图空 / 加载失败时露出来的就是这块渐变 + 🛰
      Column()
        .width(THUMB_W)
        .height(THUMB_H)
        .borderRadius(8)
        .linearGradient({
          angle: 135,
          colors: [['#16233A', 0.0], ['#0D1420', 1.0]]
        })

      Text('🛰')
        .fontSize(20)
        .fontColor('#5D6A7D')

      if (strOf(this.src).length > 0 && !this.imgErr) {
        Image(this.src)
          .width(THUMB_W)
          .height(THUMB_H)
          .borderRadius(8)
          .objectFit(ImageFit.Cover)
          .onError(() => {
            this.imgErr = true;
          })
      }
    }
    .width(THUMB_W)
    .height(THUMB_H)
  }
}

@Component
export struct NewsListView {
  // ============ 页面状态 ============

  /** 列表数据（按 CI 给的顺序，新的在前 —— 与 NewsSection 同口径，不重排） */
  @State list: NewsItem[] = [];
  /** 首屏等待（只挡内容区，返回栏始终在） */
  @State loading: boolean = true;
  /** 无缓存 + 网络失败。与「空列表」严格分开，见文件头四态说明 */
  @State failed: boolean = false;
  /** 数据生成时间，用于副标题「更新于 hh:mm」 */
  @State generatedAt: string = '';

  /** 列表滚动容器 */
  private scroller: Scroller = new Scroller();
  /** 防重入：返回再进来不应叠请求 */
  private loadingNow: boolean = false;

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadNews(false);
  }

  // ============ 加载 ============

  private loadNews(force: boolean): void {
    if (this.loadingNow) {
      return;
    }
    this.loadingNow = true;
    this.loading = true;
    this.failed = false;

    // 先 peek：同步、零网络，冷启动能立刻把列表画出来（缓存里有就直接不显示加载态）
    const cached: NewsPayload | null = repo.peek<NewsPayload>('news');
    if (cached !== null) {
      this.applyPayload(cached);
      if (this.list.length > 0) {
        this.loading = false;
      }
    }

    const opts: LoadOptions<NewsPayload> = {
      force: force,
      onCache: (data: NewsPayload) => {
        this.applyPayload(data);
      },
      onUpdate: (data: NewsPayload) => {
        this.applyPayload(data);
      }
    };

    repo.load<NewsPayload>('news', opts)
      .then((data: NewsPayload) => {
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有内容就别说失败，静默留在旧列表上（后台刷新失败不该打断阅读）
        this.failed = this.list.length === 0;
        hilog.warn(DOMAIN, TAG, 'news 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingNow = false;
      });
  }

  /** 数据落地：整体替换数组才能触发 @State 的数组重绘 */
  private applyPayload(data: NewsPayload): void {
    const raw: NewsItem[] | undefined = data.list;
    const next: NewsItem[] = raw !== undefined && raw !== null ? raw : [];
    // 一条都没有时保持原样：中途一次半截数据不该把已有列表清空
    if (next.length === 0 && this.list.length > 0) {
      return;
    }
    this.list = next;
    this.generatedAt = strOf(data.generatedAt);
  }

  private retry(): void {
    this.loadNews(true);
  }

  // ============ 派生值 ============

  private titleOf(item: NewsItem): string {
    const zh: string = strOf(item.titleZh);
    return zh.length > 0 ? zh : strOf(item.title);
  }

  private summaryOf(item: NewsItem): string {
    const zh: string = strOf(item.summaryZh);
    return zh.length > 0 ? zh : strOf(item.summary);
  }

  /** 「共 N 条 · 更新于 hh:mm」；更新时间拿不到就只留条数 */
  private subtitleText(): string {
    const parts: string[] = ['共 ' + this.list.length + ' 条'];
    const updated: string = formatGeneratedAt(this.generatedAt);
    if (updated.length > 0) {
      parts.push('更新于 ' + updated);
    }
    return parts.join(' · ');
  }

  /** 元信息：site · atShort，空值跳过（避免留下孤零零的分隔符） */
  private metaOf(item: NewsItem): string {
    const parts: string[] = [];
    const site: string = strOf(item.site).trim();
    if (site.length > 0) {
      parts.push(site);
    }
    const at: string = strOf(item.atShort).trim();
    if (at.length > 0) {
      parts.push(at);
    }
    return parts.join(' · ');
  }

  // ============ 交互 ============

  /**
   * 打开资讯详情。
   *
   * 字段逐条赋给 ArticleNavParam 而不是塞进 constructor：
   * 10 个字段的全参构造调用点会变得极长，且顺序错了编译器不报错
   * （同类型全是 string），逐字段赋值反而更难写错。
   */
  private openArticle(item: NewsItem): void {
    const p: ArticleNavParam = new ArticleNavParam();
    p.id = String(item.id);
    p.title = strOf(item.title);
    p.titleZh = strOf(item.titleZh);
    p.summary = strOf(item.summary);
    p.summaryZh = strOf(item.summaryZh);
    p.image = strOf(item.image);
    p.site = strOf(item.site);
    p.url = strOf(item.url);
    p.at = strOf(item.at);
    const refs: NewsLaunchRef[] | undefined = item.launchRefs;
    p.launchRefs = refs !== undefined && refs !== null ? refs : [];
    Nav.pushArticle(p);
  }

  // ============ UI：顶栏 ============

  /**
   * 自绘顶部栏（NavDestination 那边 hideTitleBar(true)）。
   * 结构与 RocketDetailView.topBar 一致：‹ 返回 + 标题 + 右侧留白。
   */
  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹')
          .fontSize(20)
          .fontColor(TEXT_MAIN)
          .lineHeight(20)
        Text('返回')
          .fontSize(14)
          .fontColor(TEXT_SUB)
          .margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Center)
      .padding({ right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        Nav.pop();
      })

      Text('航天资讯')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .backgroundColor(BG_PRIMARY)
  }

  /** 副标题行：19vp 主标题已在顶栏，这里只放「共 N 条 · 更新于 hh:mm」 */
  @Builder
  subHeader() {
    Text(this.loading && this.list.length === 0 ? '正在加载资讯…' : this.subtitleText())
      .fontSize(11)
      .fontColor('#6B7891')
      .width('100%')
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: 10 })
  }

  // ============ UI：单条 ============

  @Builder
  row(item: NewsItem) {
    Row() {
      NewsListThumb({ src: strOf(item.image) })

      Column() {
        Text(this.titleOf(item))
          .fontSize(14)
          .lineHeight(20)
          .fontWeight(FontWeight.Medium)
          .fontColor('#EAF0F6')
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.summaryOf(item).length > 0) {
          Text(this.summaryOf(item))
            .fontSize(11)
            .lineHeight(15)
            .fontColor(TEXT_SUB)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
        }

        if (this.metaOf(item).length > 0) {
          Text(this.metaOf(item))
            .fontSize(11)
            .fontColor(TEXT_DIM)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(10)
    .backgroundColor(CARD_BG)
    .borderRadius(12)
    .onClick(() => {
      this.openArticle(item);
    })
  }

  // ============ UI：三套占位 ============

  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ACCENT)
      Text('正在加载资讯…')
        .fontSize(12)
        .fontColor(TEXT_DIM)
        .margin({ top: 10 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  failedBlock() {
    Column() {
      Text('资讯加载失败')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      Text('网络不给力，或缓存已被清理')
        .fontSize(12)
        .fontColor(TEXT_DIM)
        .margin({ top: 8 })

      Row() {
        Text('重试')
          .fontSize(12.5)
          .fontColor(ACCENT)
      }
      .padding({ left: 18, right: 18, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor('#16222F')
      .margin({ top: 16 })
      .onClick(() => {
        this.retry();
      })

      Row() {
        Text('‹ 返回')
          .fontSize(12.5)
          .fontColor(TEXT_SUB)
      }
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(CARD_BG)
      .margin({ top: 12 })
      .onClick(() => {
        Nav.pop();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  @Builder
  emptyBlock() {
    Column() {
      Text('📰')
        .fontSize(34)
        .opacity(0.5)
      Text('暂无航天资讯')
        .fontSize(13)
        .fontColor(TEXT_SUB)
        .margin({ top: 10 })
      Text('数据每 3 小时更新一轮，稍后再来看看')
        .fontSize(11)
        .fontColor(TEXT_DIM)
        .margin({ top: 6 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ============ build ============

  build() {
    Column() {
      this.topBar()
      this.subHeader()

      if (this.list.length === 0) {
        // 空列表分成三种，绝不合并（见文件头四态说明）
        if (this.loading) {
          this.loadingBlock()
        } else if (this.failed) {
          this.failedBlock()
        } else {
          this.emptyBlock()
        }
      } else {
        List({ scroller: this.scroller }) {
          ForEach(this.list, (item: NewsItem) => {
            ListItem() {
              this.row(item)
            }
            .padding({ bottom: 10 })
          }, (item: NewsItem) => String(item.id))
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(3)
        // 底部 24 而不是 92：本页在详情页栈里，底部没有悬浮胶囊让位（见文件头取舍 1）
        .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    .alignItems(HorizontalAlign.Start)
  }
}
