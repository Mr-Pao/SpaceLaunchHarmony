/**
 * view/NewsListView.ets —— 航天资讯列表（对位小程序 pages/news/news.vue）
 *
 * 结构（与小程序同序）：
 *   topBar（标题只在滚过一屏后才出现，对应 nav-bar 的 :solid）
 *   → hero：24vp「航天资讯」+ 12vp「N 条报道 · M 家媒体 · 已中文编译」
 *   → 两个筛选 tab：全部 / 关联发射
 *   → 列表（卡片 100×75 缩略图 + 两行标题 + 两行摘要 + 站点·时间·「发射」标签）
 *   → 页脚（上滑加载更多 x / y，或刷新时间）
 *   → 来源署名
 *
 * ── 为什么详情改成页内弹窗 ──
 * 小程序的详情是**页内底部弹层**（components/news-detail：mask .62 + 82vh 的 sheet），
 * 下滑即关、tabBar 仍在下面；鸿蒙原来是整页 NavDestination，体感是「跳进了另一个页面」，
 * 返回还得重新找位置。这里用 bindSheet 还原成弹层，是本轮对齐的主改动。
 *
 * ArticleDetailView.ets **不删**：routes/DetailPages.ets 仍在引用它（搜索结果等入口），
 * 删掉直接编译失败。它的正文样式也按同一版口径调过，两个入口观感一致。
 *
 * ── 分页 ──
 * 小程序 RENDER_STEP=30 + onReachBottom 追加；鸿蒙用 List.onReachEnd 触发同一步进。
 * 一次性 ForEach 全量在 44 条时看不出问题，但 news.json 上限 200 条，先做对。
 *
 * ── 与原版的差异（都是有意的）──
 *   1. 去掉了「资讯加载失败」三态里的重试胶囊：小程序根本没有失败态，加载失败就落到
 *      空态文案。多一个只有鸿蒙才有的错误页，等于自己造一个不对齐的界面。
 *   2. hero 与 tab 是固定头部（不随列表滚走）。小程序整页滚动会把 hero 滚掉，
 *      但鸿蒙这里 topBar 是自绘的、没有系统 nav-bar 兜底，hero 一滚走顶部就只剩一条
 *      返回箭头，反而更空。固定住换来的一屏高度约 98vp，可接受。
 *   3. 详情弹窗里「查看相关发射」的重叠层是本文件内的 Stack 覆盖层，不是第二个
 *      bindSheet —— 嵌套 sheet 在 HarmonyOS 上时序不稳（关上一层会连带关掉下一层）。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { NewsItem, NewsPayload, NewsLaunchRef } from '../model/News';
import { strOf, formatGeneratedAt } from '../utils/Format';
import { Nav } from '../routes/Nav';
import { LaunchNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'NewsListView';

// ============ 视觉常量（全部来自 wxss ÷ 2） ============

const BG_PRIMARY: string = '#0A0E17';
/** 弹层底色 #0a0f16（比页面底色略深一档，弹层才有「浮起来」的层次） */
const SHEET_BG: string = '#0A0F16';
/** 相关发射选择层底色 */
const PICK_BG: string = '#0F1520';
const ACCENT: string = '#38BDF8';
const ACCENT_DEEP: string = '#04121C';

const TEXT_HERO: string = '#F2F6FA';
const TEXT_HERO_SUB: string = '#7B8898';
const TEXT_TITLE: string = '#EAF0F6';
const TEXT_SUM: string = '#7F8C9C';
const TEXT_SITE: string = '#5C8FB3';
const TEXT_TIME: string = '#5D6A7A';
const TEXT_SEP: string = '#3D4A58';
const TEXT_FOOT: string = '#59667A';
const TEXT_SRC: string = '#44526A';
const TEXT_STATE: string = '#6B7787';

/** 卡片底 rgba(255,255,255,.035) */
const CARD_BG: string = '#09FFFFFF';
/** 卡片描边 rgba(255,255,255,.06) */
const CARD_BORDER: string = '#0FFFFFFF';
/** tab 未选中底 rgba(255,255,255,.05) / 描边 .07 */
const TAB_BG: string = '#0DFFFFFF';
const TAB_BORDER: string = '#12FFFFFF';
const TAB_TEXT: string = '#93A1B1';
const THUMB_BG: string = '#0B1118';

const THUMB_W: number = 100;
const THUMB_H: number = 75;
const PAGE_PAD: number = 16;
const LIST_PAD: number = 12;
const RENDER_STEP: number = 30;

/**
 * 弹窗里正在看的那一条。
 *
 * 不用 NewsItem 直接当 @State：interface 不能 new，`@State cur: NewsItem | null` 在
 * @Builder 里做非空收窄 ArkTS 不认（属性访问不收窄），会一路报「对象可能为空」。
 * 转成一个全字段带默认值的 class 最稳，也顺带把「弹窗只需要这几个字段」写清楚了。
 */
class Nw2Cur {
  id: string = '';
  title: string = '';
  summary: string = '';
  summaryZh: string = '';
  image: string = '';
  site: string = '';
  url: string = '';
  atShort: string = '';
  refs: NewsLaunchRef[] = [];
}

/** 缩略图：真图 + 加载失败回落到渐变占位。抽成组件是为了让 @State imgErr 各自独立 */
@Component
struct NewsListThumb {
  @Prop src: string = '';
  @State imgErr: boolean = false;

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(7)
        .linearGradient({
          angle: 135,
          colors: [['#0D1620', 0.0], ['#101C28', 1.0]]
        })

      Text('🛰')
        .fontSize(22)
        .opacity(0.4)

      if (strOf(this.src).length > 0 && !this.imgErr) {
        Image(this.src)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .borderRadius(7)
          .backgroundColor(THUMB_BG)
          .onError(() => {
            this.imgErr = true;
          })
      }
    }
    .width(THUMB_W)
    .height(THUMB_H)
    .borderRadius(7)
    .backgroundColor(THUMB_BG)
  }
}

@Component
export struct NewsListView {
  // ============ 状态 ============

  @State list: NewsItem[] = [];
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State generatedAt: string = '';

  /** false = 全部；true = 只看有关联发射的报道 */
  @State onlyLaunch: boolean = false;
  /** 已渲染条数（小程序 renderCount），触底 +RENDER_STEP */
  @State renderCount: number = RENDER_STEP;
  /** 滚过一张卡片后 topBar 才出标题（对应 nav-bar :solid） */
  @State navSolid: boolean = false;

  /** 详情弹窗开合 */
  @State sheetOn: boolean = false;
  @State cur: Nw2Cur = new Nw2Cur();
  /** 弹窗内封面加载失败 */
  @State imgErr: boolean = false;
  /** 多条相关发射时的选择层 */
  @State pickOn: boolean = false;

  private scroller: Scroller = new Scroller();
  /** 网络请求防重入（下拉刷新与 onReachEnd 可能同一帧都触发） */
  private loadingNow: boolean = false;
  /** 分页防重入 */
  private moreLock: boolean = false;

  aboutToAppear(): void {
    this.loadNews(false);
  }

  // ============ 数据 ============

  private loadNews(force: boolean): void {
    if (this.loadingNow) {
      // 正在跑就把下拉动画收掉，否则 Refresh 的转圈会一直挂着
      this.refreshing = false;
      return;
    }
    this.loadingNow = true;
    this.loading = true;

    const cached: NewsPayload | null = repo.peek<NewsPayload>('news');
    if (cached !== null) {
      this.applyPayload(cached);
      if (this.list.length > 0) {
        this.loading = false;
      }
    }

    const opts: LoadOptions<NewsPayload> = {
      force: force,
      onCache: (d: NewsPayload) => {
        this.applyPayload(d);
      },
      onUpdate: (d: NewsPayload) => {
        this.applyPayload(d);
      }
    };

    repo.load<NewsPayload>('news', opts)
      .then(() => {
        hilog.info(DOMAIN, TAG, '资讯加载完成');
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '资讯加载失败：%{public}s', JSON.stringify(e));
      })
      // 收尾必须挂在 catch 之后：成功与失败都要把两个锁放掉
      .then(() => {
        this.loadingNow = false;
        this.loading = false;
        this.refreshing = false;
      });
  }

  private applyPayload(data: NewsPayload): void {
    const raw: NewsItem[] | undefined = data.list;
    if (raw === undefined || raw.length === 0) {
      return;
    }
    this.list = raw;
    this.generatedAt = strOf(data.generatedAt);
  }

  private onPullRefresh(): void {
    // 下拉刷新把已渲染条数一起重置 —— 小程序 getData(true) 也重算 renderCount
    this.refreshing = true;
    this.renderCount = RENDER_STEP;
    this.loadNews(true);
  }

  private onReachEnd(): void {
    if (this.moreLock) {
      return;
    }
    const total: number = this.filtered().length;
    if (this.renderCount >= total) {
      return;
    }
    this.moreLock = true;
    const next: number = this.renderCount + RENDER_STEP;
    this.renderCount = next > total ? total : next;
    this.moreLock = false;
  }

  private switchTab(only: boolean): void {
    if (this.onlyLaunch === only) {
      return;
    }
    this.onlyLaunch = only;
    // 切 tab 必须重置分页，否则「全部」翻到 120 条后切到关联发射会直接显示 120 条
    this.renderCount = RENDER_STEP;
    this.navSolid = false;
  }

  // ============ 派生 ============

  /** 有关联发射：launchRefs 是 CI 补好的可跳转信息，launches 只有 UUID */
  private hasLaunch(item: NewsItem): boolean {
    const refs: NewsLaunchRef[] | undefined = item.launchRefs;
    if (refs !== undefined && refs.length > 0) {
      return true;
    }
    const ids: string[] | undefined = item.launches;
    return ids !== undefined && ids.length > 0;
  }

  private filtered(): NewsItem[] {
    if (!this.onlyLaunch) {
      return this.list;
    }
    const out: NewsItem[] = [];
    for (let i = 0; i < this.list.length; i++) {
      if (this.hasLaunch(this.list[i])) {
        out.push(this.list[i]);
      }
    }
    return out;
  }

  private visible(): NewsItem[] {
    const all: NewsItem[] = this.filtered();
    return all.length > this.renderCount ? all.slice(0, this.renderCount) : all;
  }

  private siteCount(): number {
    const seen: Set<string> = new Set<string>();
    for (let i = 0; i < this.list.length; i++) {
      const s: string = strOf(this.list[i].site);
      if (s.length > 0) {
        seen.add(s);
      }
    }
    return seen.size;
  }

  private heroSub(): string {
    return String(this.list.length) + ' 条报道 · ' + String(this.siteCount()) + ' 家媒体 · 已中文编译';
  }

  private titleOf(item: NewsItem): string {
    const zh: string = strOf(item.titleZh);
    return zh.length > 0 ? zh : strOf(item.title);
  }

  private summaryOf(item: NewsItem): string {
    const zh: string = strOf(item.summaryZh);
    return zh.length > 0 ? zh : strOf(item.summary);
  }

  private footText(): string {
    const total: number = this.filtered().length;
    if (this.renderCount < total) {
      return '上滑加载更多（' + String(this.renderCount) + ' / ' + String(total) + '）';
    }
    if (this.generatedAt.length > 0) {
      return '更新于 ' + formatGeneratedAt(this.generatedAt);
    }
    return '已显示全部';
  }

  // ============ 交互 ============

  private openSheet(item: NewsItem): void {
    const c: Nw2Cur = new Nw2Cur();
    c.id = String(item.id);
    c.title = this.titleOf(item);
    c.summary = strOf(item.summary);
    c.summaryZh = strOf(item.summaryZh);
    c.image = strOf(item.image);
    c.site = strOf(item.site);
    c.url = strOf(item.url);
    c.atShort = strOf(item.atShort);

    const refs: NewsLaunchRef[] | undefined = item.launchRefs;
    if (refs !== undefined) {
      const keep: NewsLaunchRef[] = [];
      for (let i = 0; i < refs.length; i++) {
        if (refs[i] !== undefined && strOf(refs[i].id).length > 0) {
          keep.push(refs[i]);
        }
      }
      c.refs = keep;
    }

    this.cur = c;
    this.imgErr = false;
    this.pickOn = false;
    this.sheetOn = true;
  }

  private copyUrl(): void {
    const url: string = this.cur.url;
    if (url.length === 0) {
      return;
    }
    const data: pasteboard.PasteData =
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.toast('原文链接已复制');
    }).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG, '复制失败：%{public}s', JSON.stringify(e));
      this.toast('复制失败，请稍后重试');
    });
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private refName(ref: NewsLaunchRef): string {
    const n: string = strOf(ref.name);
    return n.length > 0 ? n : '相关发射';
  }

  private primaryIsCopy(): boolean {
    return this.cur.refs.length === 0;
  }

  private openRefs(): void {
    if (this.cur.refs.length === 1) {
      this.goRef(this.cur.refs[0]);
      return;
    }
    this.pickOn = true;
  }

  private goRef(ref: NewsLaunchRef): void {
    // 先关弹层再跳：不关的话返回时 sheet 还盖在上面，看着像没跳成功
    this.sheetOn = false;
    this.pickOn = false;
    Nav.pushLaunch(new LaunchNavParam(strOf(ref.id), strOf(ref.net), this.refName(ref)));
  }

  // ============ UI：头部 ============

  /**
   * 顶栏。标题只在滚过一张卡之后出现 —— 小程序 nav-bar 的 solid 也是滚过 120 才给标题，
   * 静止时靠 hero 那颗 24vp 的大标题出声，两个标题不同时出现。
   */
  @Builder
  topBar() {
    Row() {
      Text('‹')
        .fontSize(20)
        .fontColor('#FFFFFF')
        .padding({ right: 8, top: 10, bottom: 10, left: 4 })
        .onClick(() => {
          Nav.pop();
        })

      if (this.navSolid) {
        Text('航天资讯')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: PAGE_PAD - 4, right: PAGE_PAD })
    .backgroundColor(BG_PRIMARY)
  }

  /** hero：24vp 大标题 + 12vp 统计副标题（小程序 .hero / .hero-title / .hero-sub） */
  @Builder
  heroBlock() {
    Column() {
      Text('航天资讯')
        .width('100%')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_HERO)
        .letterSpacing(0.5)

      Text(this.heroSub())
        .width('100%')
        .fontSize(12)
        .fontColor(TEXT_HERO_SUB)
        .margin({ top: 5 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10, bottom: 4, left: PAGE_PAD, right: PAGE_PAD })
  }

  /**
   * 两个筛选 chip。
   *
   * 颜色全部读 this.onlyLaunch，而不是把 `on` 当参数传进一个带参 @Builder ——
   * @Builder 的按值参数不建立响应式依赖，切换 tab 时 chip 会停在旧配色上。
   */
  @Builder
  tabsBlock() {
    Row() {
      Text('全部')
        .fontSize(12.5)
        .fontColor(this.onlyLaunch ? TAB_TEXT : ACCENT_DEEP)
        .fontWeight(this.onlyLaunch ? FontWeight.Normal : FontWeight.Medium)
        .padding({ top: 5, bottom: 5, left: 13, right: 13 })
        .borderRadius(999)
        .backgroundColor(this.onlyLaunch ? TAB_BG : ACCENT)
        .border({ width: 1, color: this.onlyLaunch ? TAB_BORDER : ACCENT })
        .margin({ right: 8 })
        .onClick(() => {
          this.switchTab(false);
        })

      Text('关联发射')
        .fontSize(12.5)
        .fontColor(this.onlyLaunch ? ACCENT_DEEP : TAB_TEXT)
        .fontWeight(this.onlyLaunch ? FontWeight.Medium : FontWeight.Normal)
        .padding({ top: 5, bottom: 5, left: 13, right: 13 })
        .borderRadius(999)
        .backgroundColor(this.onlyLaunch ? ACCENT : TAB_BG)
        .border({ width: 1, color: this.onlyLaunch ? ACCENT : TAB_BORDER })
        .onClick(() => {
          this.switchTab(true);
        })
    }
    .width('100%')
    .padding({ top: 9, bottom: 3, left: PAGE_PAD, right: PAGE_PAD })
  }

  // ============ UI：卡片 ============

  @Builder
  card(item: NewsItem) {
    Row() {
      NewsListThumb({ src: item.image === undefined ? '' : item.image })

      Column() {
        Text(this.titleOf(item))
          .width('100%')
          .fontSize(14)
          .lineHeight(19.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_TITLE)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 摘要两行：小程序 .sum 是 -webkit-line-clamp:2
        Text(this.summaryOf(item))
          .width('100%')
          .fontSize(11.5)
          .lineHeight(16.5)
          .fontColor(TEXT_SUM)
          .margin({ top: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        // 站点 · 时间 · 「发射」标签，三段不同色，必须拆三个 Text
        Row() {
          Text(strOf(item.site))
            .fontSize(10.5)
            .fontColor(TEXT_SITE)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text('·')
            .fontSize(10.5)
            .fontColor(TEXT_SEP)
            .margin({ left: 4, right: 4 })

          Text(strOf(item.atShort))
            .fontSize(10.5)
            .fontColor(TEXT_TIME)

          if (this.hasLaunch(item)) {
            Text('发射')
              .fontSize(9.5)
              .fontColor(ACCENT)
              .padding({ left: 4, right: 4, top: 0.5, bottom: 0.5 })
              .border({ width: 1, color: '#6638BDF8' })
              .borderRadius(3)
              .margin({ left: 7 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
      .clip(true)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding(11)
    .backgroundColor(CARD_BG)
    .borderRadius(10)
    .border({ width: 1, color: CARD_BORDER })
    .onClick(() => {
      this.openSheet(item);
    })
  }

  // ============ UI：三态 ============

  /** 加载态：小程序是纯文字（没有转圈），照抄 */
  @Builder
  loadingBlock() {
    Column() {
      Text('正在加载资讯…')
        .fontSize(13)
        .fontColor(TEXT_STATE)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 空态：单行文字，无图标（小程序 .empty 只有一句） */
  @Builder
  emptyBlock() {
    Column() {
      Text(this.onlyLaunch ? '暂无关联发射的报道' : '暂无资讯')
        .fontSize(13)
        .fontColor(TEXT_STATE)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ============ UI：详情弹窗 ============

  /** 顶部 grab 条：36×4，rgba(255,255,255,.18) */
  @Builder
  sheetGrab() {
    Row() {
      Row()
        .width(36)
        .height(4)
        .borderRadius(2)
        .backgroundColor('#2EFFFFFF')
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 9, bottom: 3 })
  }

  /** 弹窗正文。所有内容读 this.cur —— 无参 @Builder 才会跟着 @State 刷新 */
  @Builder
  sheetBody() {
    Column() {
      if (this.cur.image.length > 0 && !this.imgErr) {
        Image(this.cur.image)
          .width('100%')
          .height(200)
          .objectFit(ImageFit.Cover)
          .borderRadius(9)
          .backgroundColor(THUMB_BG)
          .margin({ bottom: 12 })
          .onError(() => {
            this.imgErr = true;
          })
      }

      // 标题 18vp / 行高 1.4 → 25.2，w600（小程序 .d-title 36rpx/1.4/600）
      Text(this.cur.title)
        .width('100%')
        .fontSize(18)
        .lineHeight(25.2)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_HERO)

      Row() {
        Text(this.cur.site)
          .fontSize(11.5)
          .fontColor(TEXT_SITE)

        Text('·')
          .fontSize(11.5)
          .fontColor(TEXT_SEP)
          .margin({ left: 5, right: 5 })

        Text(this.cur.atShort)
          .fontSize(11.5)
          .fontColor(TEXT_TIME)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8 })

      // 正文：中文 14vp lh1.72 #b9c6d4；回退到英文时换成 #8593a3（小程序 .d-en 分色）
      if (this.cur.summaryZh.length > 0) {
        Text(this.cur.summaryZh)
          .width('100%')
          .fontSize(14)
          .lineHeight(24)
          .fontColor('#B9C6D4')
          .margin({ top: 13 })
      } else if (this.cur.summary.length > 0) {
        Text(this.cur.summary)
          .width('100%')
          .fontSize(14)
          .lineHeight(24)
          .fontColor('#8593A3')
          .margin({ top: 13 })
      }

      // 两个按钮：有相关发射时「查看相关发射」才是主按钮
      Flex({ wrap: FlexWrap.Wrap }) {
        if (this.cur.url.length > 0) {
          Text('复制原文链接')
            .fontSize(13)
            .fontColor(this.primaryIsCopy() ? ACCENT_DEEP : '#CFE0EE')
            .fontWeight(this.primaryIsCopy() ? FontWeight.Medium : FontWeight.Normal)
            .padding({ top: 10, bottom: 10, left: 17, right: 17 })
            .borderRadius(999)
            .backgroundColor(this.primaryIsCopy() ? ACCENT : '#12FFFFFF')
            .border({ width: 1, color: this.primaryIsCopy() ? ACCENT : '#1AFFFFFF' })
            .margin({ right: 9, bottom: 8 })
            .onClick(() => {
              this.copyUrl();
            })
        }

        if (this.cur.refs.length > 0) {
          Text('查看相关发射')
            .fontSize(13)
            .fontColor(this.primaryIsCopy() ? '#CFE0EE' : ACCENT_DEEP)
            .fontWeight(this.primaryIsCopy() ? FontWeight.Normal : FontWeight.Medium)
            .padding({ top: 10, bottom: 10, left: 17, right: 17 })
            .borderRadius(999)
            .backgroundColor(this.primaryIsCopy() ? '#12FFFFFF' : ACCENT)
            .border({ width: 1, color: this.primaryIsCopy() ? '#1AFFFFFF' : ACCENT })
            .margin({ right: 9, bottom: 8 })
            .onClick(() => {
              this.openRefs();
            })
        }
      }
      .width('100%')
      .margin({ top: 18 })

      Text('小程序内不转载正文，复制链接到浏览器可读全文')
        .width('100%')
        .fontSize(10.5)
        .lineHeight(16.8)
        .fontColor('#4F5B6B')
        .margin({ top: 7 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 3, bottom: 20, left: 16, right: 16 })
  }

  /** 多条相关发射的选择层（小程序 .pick-mask + .pick-sheet） */
  @Builder
  pickerLayer() {
    Column() {
      // 上半屏是点击关闭区，别做成「点了没反应」
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => {
          this.pickOn = false;
        })

      Column() {
        Text('选择相关发射')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')

        Text('这篇报道提到了 ' + String(this.cur.refs.length) + ' 次发射')
          .fontSize(10.5)
          .fontColor(TEXT_TIME)
          .margin({ top: 4 })

        Column() {
          ForEach(this.cur.refs, (ref: NewsLaunchRef, idx: number) => {
            Row() {
              Text(String(idx + 1))
                .width(22)
                .fontSize(11)
                .fontColor(TEXT_SITE)
                .fontWeight(FontWeight.Medium)

              Column() {
                Text(this.refName(ref))
                  .width('100%')
                  .fontSize(13.5)
                  .fontColor(TEXT_TITLE)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                Text(strOf(ref.net))
                  .width('100%')
                  .fontSize(10.5)
                  .fontColor(TEXT_TIME)
                  .margin({ top: 2 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 10 })
              .clip(true)

              Text('›')
                .fontSize(17)
                .fontColor(TEXT_SEP)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ top: 11, bottom: 11, left: 10, right: 10 })
            .borderRadius(9)
            .backgroundColor('#0AFFFFFF')
            .margin({ top: 7 })
            .onClick(() => {
              this.goRef(ref);
            })
          }, (ref: NewsLaunchRef) => 'ref_' + ref.id)
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 16, bottom: 20, left: 14, right: 14 })
      .backgroundColor(PICK_BG)
      .borderRadius({ topLeft: 14, topRight: 14 })
    }
    .width('100%')
    .height('100%')
    // .72 黑遮罩：0.72 × 255 ≈ 184 = 0xB8
    .backgroundColor('#B8000000')
  }

  /** 弹窗壳：grab 条 + 正文，外加可能出现的 picker 覆盖层 */
  @Builder
  detailSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        this.sheetGrab()

        Scroll() {
          this.sheetBody()
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')

      if (this.pickOn) {
        this.pickerLayer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(SHEET_BG)
  }

  // ============ build ============

  build() {
    Column() {
      this.topBar()
      this.heroBlock()
      this.tabsBlock()

      if (this.loading && this.list.length === 0) {
        this.loadingBlock()
      } else if (this.visible().length === 0) {
        this.emptyBlock()
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List({ scroller: this.scroller }) {
            ForEach(this.visible(), (item: NewsItem) => {
              ListItem() {
                this.card(item)
              }
              .padding({ bottom: 9 })
            }, (item: NewsItem) => 'n' + String(item.id))

            ListItem() {
              Text(this.footText())
                .width('100%')
                .fontSize(11)
                .fontColor(TEXT_FOOT)
                .textAlign(TextAlign.Center)
                .padding({ top: 17, bottom: 5 })
            }

            ListItem() {
              Text('资讯来自 Spaceflight News API（The Space Devs），版权归各原始媒体所有')
                .width('100%')
                .fontSize(10)
                .lineHeight(15)
                .fontColor(TEXT_SRC)
                .textAlign(TextAlign.Center)
                .padding({ top: 4, bottom: 10, left: 12, right: 12 })
            }
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(3)
          .padding({ left: LIST_PAD, right: LIST_PAD })
          .onReachEnd(() => {
            this.onReachEnd();
          })
          .onScrollIndex((first: number) => {
            // 滚过第一张卡（≈ 106vp，接近小程序的 120 阈值）才给标题
            this.navSolid = first >= 1;
          })
        }
        .layoutWeight(1)
        .onRefreshing(() => {
          this.onPullRefresh();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    .alignItems(HorizontalAlign.Start)
    // 弹层挂根节点：挂在卡片上会被列表重绘牵连；onDisappear 必须回写 false，
    // 否则用户下滑关闭后 sheetOn 一直是 true，再点卡片再也打不开。
    .bindSheet(this.sheetOn, this.detailSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      backgroundColor: SHEET_BG,
      onDisappear: () => {
        this.sheetOn = false;
        this.pickOn = false;
      }
    })
  }
}
