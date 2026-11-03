/**
 * view/EventsView.ets —— 「近期活动」页（EVA / 轨道插入 / 飞船对接 等航天事件）
 *
 * 对位小程序 `pages/event/event.vue`（301 行）。尺寸一律按 wcss 的 rpx ÷ 2 换算：
 *   封面 300rpx→150、标题 32rpx→16、类型/日期 24rpx→12、摘要 27rpx→13.5、
 *   标签 22rpx→11、卡圆角 20rpx→10、卡间距 24rpx→12。
 *
 * ── 为什么去掉「全部 / 未来 / 已结束」分段 ──
 *   那是我上一版自己加的交互，小程序没有。events 是「时间线资讯」，用户是
 *   顺着列表往下读的，不是来筛的；多一排控件只是把首屏内容又往下推 40vp。
 *   现在与小程序一致：进页面就是 计数行 + 卡片列表 + 下拉/触底。
 *
 * ── 为什么改回分页（pageSize = 8）──
 *   26 条一次全铺，等于让用户在一屏里翻 26 张 150vp 的图，首屏渲染成本也高。
 *   小程序用的是 createListMixin({pageSize: 8}) + onReachBottom 增量加载，
 *   底部再给一行「上拉加载更多 / 已显示 N 项」。这里按同样的节奏复刻。
 *
 * ── 数据链路（与 NewsListView / LaunchView 同口径）──
 *   repo.peek<EvPayload>('events')          —— 同步、零网络，冷启动立刻有内容
 *   repo.load<EvPayload>('events', {onCache, onUpdate})
 *     onCache  —— 命中原生缓存时立刻上屏
 *     onUpdate —— 缓存过期、后台刷新拿到新数据时回填
 *
 * ── 为什么「失败」与「没数据」必须是两个状态 ──
 *   原项目 utils/data.js 的 load() 在「弱网 + 无缓存」时是 **reject**，
 *   不是返回空数组。catch 里一旦置 loaded = true，页面就永久停在「活动数据整理中」，
 *   用户以为真的没有活动，而实际上是网络挂了。
 *   所以 failed 是独立状态，且 catch **只置 failed，绝不置 loaded**：
 *     list 非空                     → 列表（此时刷新失败也继续显示旧数据）
 *     list 空 && failed             → 加载失败 + 重试
 *     list 空 && !loaded && !failed → 骨架屏
 *     list 空 && loaded && !failed  → 🛰️ 活动数据整理中
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { EvItem, EvPayload, EvLaunchRef, evStr, evRefName, evTitle, evDesc } from '../model/Event';
import { formatShort, truncate, eventPlace, applyTermFix } from '../utils/Format';
import { Nav } from '../routes/Nav';

const DOMAIN: number = 0x0000;
const TAG: string = 'EventsView';

/** 分 → 毫秒。新鲜度换算只用得到这一级，小时与天都在下面用除法现算 */
const MIN_MS: number = 60 * 1000;

// ============ 视觉常量（照抄小程序 wcss ÷ 2） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
/** 卡片标题 #ffffff（小程序是纯白，不是工程默认的 #A7B4C7） */
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
/** 类型色 #38bdf8 */
const ACCENT: string = '#38BDF8';
/** 日期 #6b7891 */
const TEXT_DATE: string = '#6B7891';
/** 计数主行 #8a97a8 */
const TEXT_STAT: string = '#8A97A8';
/** 计数副行（新鲜度）#4a5568 */
const TEXT_STAT_SUB: string = '#4A5568';
/** 摘要 #8a97a8 */
const TEXT_DESC: string = '#8A97A8';
/** 底部提示 #3d4a5c */
const TEXT_FOOT: string = '#3D4A5C';
/** 地点标签字色 #7bb8e0 */
const TAG_PLACE_FG: string = '#7BB8E0';
/** 关联发射标签字色 #d9b45e */
const TAG_LINK_FG: string = '#D9B45E';

/** rgba(255,255,255,.05) → 0x0D */
const BORDER_FAINT: string = '#0DFFFFFF';
/** rgba(56,189,248,.1) → 0x1A */
const TAG_PLACE_BG: string = '#1A38BDF8';
/** rgba(245,195,59,.12) → 0x1F */
const TAG_LINK_BG: string = '#1FF5C33B';
/** 骨架块底色 #1a2231 */
const SK_BLOCK: string = '#1A2231';
/** 骨架呼吸：0%/100% 是 0.45，50% 是 1（小程序 sk-breathe 1.4s） */
const SK_OPACITY_LO: number = 0.45;
const SK_OPACITY_HI: number = 1.0;

/** 卡片圆角 20rpx → 10 */
const CARD_RADIUS: number = 10;
/** 封面 300rpx → 150 */
const COVER_H: number = 150;
/** 每页条数（与小程序 createListMixin 的 pageSize: 8 一致） */
const EV_PAGE: number = 8;

/** 页面左右 24rpx → 12 */
const PAGE_PAD: number = 12;
/** 二级页底部留白（工程约定）：小程序是 200rpx，那是给 tab 胶囊让位，这页用不上 */
const BOTTOM_PAD: number = 32;

// ============ 纯函数（放在 @Component 外面，避免每次重绘重建闭包） ============

/**
 * 正文压平。
 *
 * events 的 description 实测带 \r\n，直接丢进 Text 会在卡片里出现莫名的一行半空白
 * （ArkUI 按真实换行排版，maxLines 也救不了）。先把 \r\n / \n / \r / \t 换成空格，
 * 再把连续空格压成一个。
 *
 * 为什么用 split/join 而不是正则：正则里 \r\n 的转义在 ArkTS 的引号串里容易写错
 * 且不报错，split 语义直白、零解释成本。
 */
function flatText(raw: string): string {
  let s: string = raw.split('\r\n').join(' ');
  s = s.split('\n').join(' ');
  s = s.split('\r').join(' ');
  s = s.split('\t').join(' ');
  let guard: number = 0;
  while (s.indexOf('  ') >= 0 && guard < 32) {
    s = s.split('  ').join(' ');
    guard++;
  }
  return s.trim();
}

/**
 * 新鲜度文案：「刚刚更新 / N 分钟前更新 / N 小时前更新 / N 天前更新」。
 *
 * 为什么要自己写：原项目的 freshnessText 在 utils/data.js 里（不在 Format.ets），
 * 鸿蒙侧没有对应的数据层工具，就地实现一份最小版本即可 —— 口径与原文一字不差。
 * 解析失败返回空串，计数行就只显示条目数，不显示「undefined 前更新」。
 */
function freshTextOf(generatedAt: string): string {
  const s: string = evStr(generatedAt).trim();
  if (s.length === 0) {
    return '';
  }
  const t: number = Date.parse(s);
  if (Number.isNaN(t)) {
    return '';
  }
  const mins: number = Math.floor((Date.now() - t) / MIN_MS);
  if (mins < 1) {
    return '刚刚更新';
  }
  if (mins < 60) {
    return String(mins) + ' 分钟前更新';
  }
  const hours: number = Math.floor(mins / 60);
  if (hours < 24) {
    return String(hours) + ' 小时前更新';
  }
  return String(Math.floor(hours / 24)) + ' 天前更新';
}

@Component
export struct EventsView {
  // ============ 页面状态 ============

  /** 全量活动（CI 原序，不重排 —— 上游本来就按时间排好） */
  @State list: EvItem[] = [];
  /** 已展示条数：触底 += EV_PAGE，下拉刷新回到 EV_PAGE */
  @State shown: number = EV_PAGE;
  /** 是否已经成功拿到过一次数据。**失败时绝不置 true**（见文件头状态说明） */
  @State loaded: boolean = false;
  /** 正在等首屏数据（只挡内容区） */
  @State loading: boolean = true;
  /** 无缓存 + 网络失败。与「没数据」严格分开 */
  @State failed: boolean = false;
  /** 下拉刷新中（Refresh 组件的双向状态） */
  @State refreshing: boolean = false;
  /** 数据生成时刻，用于计数行右侧的新鲜度 */
  @State generatedAt: string = '';

  /**
   * 头图加载失败的活动 id。
   *
   * 为什么用数组 + 整体替换而不是 Map/Set：ArkTS 对 Set/Map 的元素增删
   * 不保证触发 @State 重绘，而 `concat([id])` 换的是引用，一定重新渲染。
   */
  @State hiddenImgs: number[] = [];

  /** 骨架屏呼吸透明度 */
  @State skOpacity: number = SK_OPACITY_LO;

  /** 防重入：返回再进来、或连点重试，不应叠请求 */
  private loadingNow: boolean = false;
  /** 骨架呼吸 interval 句柄。-1 = 未启动。**必须清理**（工程约束 11） */
  private skTimer: number = -1;

  /** 点击整卡。@Prop 不用于函数，普通成员 + 默认空实现（工程约定） */
  onOpen: (item: EvItem) => void = () => {};

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadEvents(false);
    this.breath();
  }

  aboutToDisappear(): void {
    // 掐掉骨架呼吸（工程约束：定时器必须清理，否则页面销毁后回调还在改 @State）
    if (this.skTimer !== -1) {
      clearInterval(this.skTimer);
      this.skTimer = -1;
    }
  }

  // ============ 骨架呼吸 ============

  /**
   * 0.45 ↔ 1.0 每 700ms 翻一档，配 build 里 skCard 的 `.animation({duration:700})`
   * 补间 —— 两段各 700ms 正好拼出 1.4s 的往返，与小程序
   * `animation: sk-breathe 1.4s ease-in-out infinite` 同频。
   *
   * 为什么用「定时器翻值 + .animation 补间」而不是 animateTo 递归：
   * 与 components/StarField.ets 同一套写法，全工程一致；
   * 而且 animateTo 的 onFinish 递归没有句柄，页面切走时会留下悬空回调。
   */
  private breath(): void {
    if (this.skTimer !== -1) {
      return;
    }
    this.skTimer = setInterval(() => {
      this.skOpacity = this.skOpacity > 0.5 ? SK_OPACITY_LO : SK_OPACITY_HI;
    }, 700);
  }

  // ============ 加载 ============

  private loadEvents(force: boolean): void {
    if (this.loadingNow) {
      // 已经在拉：把下拉刷新的圈收掉，否则它要等到下一次请求结束才会停
      this.refreshing = false;
      return;
    }
    this.loadingNow = true;
    this.loading = true;
    this.failed = false;

    // 先 peek：同步、零网络，冷启动能立刻把列表画出来（有缓存就不显示骨架）
    const cached: EvPayload | null = repo.peek<EvPayload>('events');
    if (cached !== null) {
      this.applyPayload(cached);
      if (this.list.length > 0) {
        this.loading = false;
      }
    }

    const opts: LoadOptions<EvPayload> = {
      force: force,
      onCache: (data: EvPayload) => {
        this.applyPayload(data);
      },
      onUpdate: (data: EvPayload) => {
        this.applyPayload(data);
      }
    };

    repo.load<EvPayload>('events', opts)
      .then((data: EvPayload) => {
        this.applyPayload(data);
        // 成功才配 loaded = true；失败分支一个字都不能改它
        this.loaded = true;
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有内容就别说失败，静默留在旧列表上（后台刷新失败不该打断阅读）
        this.failed = this.list.length === 0;
        hilog.warn(DOMAIN, TAG, 'events 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingNow = false;
        this.refreshing = false;
      });
  }

  /**
   * 数据落地：整体替换数组才能触发 @State 的数组重绘。
   * 一条都没有时保持原样 —— 中途一次半截数据不该把已有列表清空。
   */
  private applyPayload(data: EvPayload): void {
    // list 在载荷里是必填，但运行时不做校验（JSON.parse 只是断言），
    // 所以仍按「可能是 undefined」读。只判 undefined、不判 null：声明类型里没有 null。
    const raw: EvItem[] | undefined = data.list;
    const next: EvItem[] = raw !== undefined ? raw : [];
    if (next.length === 0 && this.list.length > 0) {
      return;
    }
    this.list = next;
    this.generatedAt = evStr(data.generatedAt);
    // 数据变短时（比如回源后只剩 5 条），已展示条数不能超过总数，否则底部提示算错
    if (this.shown > next.length && next.length > 0) {
      this.shown = next.length;
    }
  }

  private retry(): void {
    this.loadEvents(true);
  }

  // ============ 分页 ============

  /** 当前可见：前 shown 条（对应小程序 computed.visible） */
  private visibleItems(): EvItem[] {
    return this.list.slice(0, this.shown);
  }

  private hasMore(): boolean {
    return this.shown < this.list.length;
  }

  private loadMore(): void {
    if (!this.hasMore()) {
      return;
    }
    this.shown = this.shown + EV_PAGE;
  }

  private resetPaging(): void {
    this.shown = EV_PAGE;
  }

  // ============ 派生展示值 ============

  /** 类型名：evRefName 统一吃 EvRef | string | null，缺了给「活动」 */
  private typeTextOf(item: EvItem): string {
    const raw: string = evRefName(item.type).trim();
    return raw.length > 0 ? raw : '活动';
  }

  private dateTextOf(item: EvItem): string {
    return formatShort(evStr(item.date));
  }

  /** 地点：location 可能是空间站 / 轨道 / 发射场，统一过 eventPlace 查表 */
  private placeOf(item: EvItem): string {
    return eventPlace(evRefName(item.location)).trim();
  }

  /** 第一条关联发射的名字。没有 launches 时返回空串，整枚标签不画 */
  private launchTagOf(item: EvItem): string {
    const arr: EvLaunchRef[] | null | undefined = item.launches;
    if (arr === null || arr === undefined || arr.length === 0) {
      return '';
    }
    return evStr(arr[0].name).trim();
  }

  /** 摘要：先压平换行，再按小程序口径截 60 字（truncate 会补省略号） */
  private descOf(item: EvItem): string {
    return truncate(applyTermFix(flatText(evDesc(item))), 60);
  }

  private imgOf(item: EvItem): string {
    return evStr(item.feature_image).trim();
  }

  private showImg(item: EvItem): boolean {
    return this.imgOf(item).length > 0 && this.hiddenImgs.indexOf(item.id) < 0;
  }

  private freshLine(): string {
    return freshTextOf(this.generatedAt);
  }

  // ============ 交互 ============

  private openItem(item: EvItem): void {
    this.onOpen(item);
  }

  // ============ UI：返回键 ============

  /**
   * 返回键。
   *
   * 本页路由（DetailPages.ets:245）也是 `.hideTitleBar(true)`，系统标题栏连同返回
   * 箭头一起被抹掉；「近期活动」是从「我的/更多」这类入口点进来的三级页面，
   * 没有 tab 兜底，不给出口用户就困在这一页。小程序等价物是 nav-bar 组件的返回键。
   */
  @Builder
  backBar() {
    Row() {
      Text('‹ 返回')
        .fontSize(13)
        .fontColor('#A7B4C7')
        .padding({ right: 12, top: 8, bottom: 8 })
        .onClick(() => {
          Nav.pop();
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ top: 6 })
  }

  // ============ UI：页头 + 计数行 ============

  @Builder
  header() {
    Column() {
      // NavDestination 已经 hideTitleBar，标题得自己画
      Text('近期活动')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_SUB)
        .width('100%')
        .maxLines(1)

      // 计数行：小程序 nav 之外单独一条 stat（只在有数据时出现）
      if (this.list.length > 0) {
        Row() {
          Text('近期活动 ' + String(this.list.length) + ' 项')
            .fontSize(13)
            .fontColor(TEXT_STAT)
            .maxLines(1)
            .layoutWeight(1)

          if (this.freshLine().length > 0) {
            Text(this.freshLine())
              .fontSize(12)
              .fontColor(TEXT_STAT_SUB)
              .maxLines(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        // 小程序 .stat 是 padding: 10rpx 0 20rpx → 5/0/10，模板里再内联
        // padding-top: 8rpx → 覆盖成 4。所以最终上 4、下 10。
        .padding({ top: 4, bottom: 10 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8 })
  }

  // ============ UI：骨架屏 ============

  /**
   * 一张骨架卡：整宽图块 + 三条文字块（宽度 40% / 85% / 60%）。
   *
   * 形状刻意对齐真实卡片（同高封面 + 同内边距），加载完成时布局不跳动。
   */
  @Builder
  skCard() {
    Column() {
      Column()
        .width('100%')
        .height(COVER_H)
        .backgroundColor(SK_BLOCK)

      Column() {
        Column()
          .width('40%')
          .height(13)
          .borderRadius(4)
          .backgroundColor(SK_BLOCK)
          .margin({ bottom: 7 })

        Column()
          .width('85%')
          .height(13)
          .borderRadius(4)
          .backgroundColor(SK_BLOCK)
          .margin({ bottom: 7 })

        Column()
          .width('60%')
          .height(13)
          .borderRadius(4)
          .backgroundColor(SK_BLOCK)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      // 小程序 .body 是 padding: 24rpx 28rpx 28rpx → 12 / 14 / 14
      // 骨架里上边距用 20 是为了让三条线看起来居中，与真实卡片的 12 略不同
      .padding({ top: 20, bottom: 20, left: 14, right: 14 })
    }
    .width('100%')
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: BORDER_FAINT })
    .clip(true)
    .opacity(this.skOpacity)
    // 与 breath() 里 700ms 一翻的 @State 配对，补出连续的呼吸感
    .animation({ duration: 700, curve: Curve.EaseInOut })
  }

  @Builder
  skeleton() {
    Column() {
      // 小程序 v-for="i in 2"
      this.skCard()
      Column().height(12)
      this.skCard()
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  // ============ UI：单张卡 ============

  @Builder
  tag(text: string, bg: string, fg: string) {
    Text(text)
      .fontSize(11)
      .fontColor(fg)
      .backgroundColor(bg)
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      .borderRadius(3)
      .margin({ right: 6, bottom: 4 })
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

  @Builder
  card(item: EvItem) {
    Column() {
      // 封面：有图用图，没有就画渐变底 + 🛰️
      if (this.showImg(item)) {
        Image(this.imgOf(item))
          .width('100%')
          .height(COVER_H)
          .objectFit(ImageFit.Cover)
          .backgroundColor('#0F1520')
          .onError(() => {
            // 失败就记进隐藏表：回落成渐变占位，不留黑块、也不占 150vp 空白
            this.hiddenImgs = this.hiddenImgs.concat([item.id]);
          })
      } else {
        Column() {
          Text('🛰️')
            .fontSize(32)
            .opacity(0.35)
        }
        .width('100%')
        .height(COVER_H)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .linearGradient({
          angle: 135,
          colors: [['#16233A', 0.0], ['#0D1420', 1.0]]
        })
      }

      Column() {
        // 卡头两行制：类型在左、日期在右（小程序 .top 两端对齐）
        Row() {
          Text(this.typeTextOf(item))
            .fontSize(12)
            .fontColor(ACCENT)
            .maxLines(1)
            .layoutWeight(1)

          Text(this.dateTextOf(item))
            .fontSize(12)
            .fontColor(TEXT_DATE)
            .maxLines(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 标题 16vp / 600 / line-height 1.4 → 22
        Text(evTitle(item))
          .fontSize(16)
          // 小程序 .title 是 font-weight: 600
          .fontWeight(600)
          .fontColor(TEXT_MAIN)
          .lineHeight(22)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })

        // 标签行：地点 + 第一条关联发射。可能超宽，必须折行
        if (this.placeOf(item).length > 0 || this.launchTagOf(item).length > 0) {
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
            if (this.placeOf(item).length > 0) {
              this.tag(this.placeOf(item), TAG_PLACE_BG, TAG_PLACE_FG)
            }
            if (this.launchTagOf(item).length > 0) {
              this.tag(this.launchTagOf(item), TAG_LINK_BG, TAG_LINK_FG)
            }
          }
          .width('100%')
          .margin({ top: 7 })
        }

        // 摘要 13.5vp / line-height 1.7 → 23 / 3 行截断
        if (this.descOf(item).length > 0) {
          Text(this.descOf(item))
            .fontSize(13.5)
            .fontColor(TEXT_DESC)
            .lineHeight(23)
            .width('100%')
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 8 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 12, bottom: 14, left: 14, right: 14 })
    }
    .width('100%')
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: BORDER_FAINT })
    // 吃掉封面上下沿的溢出，同时让封面贴住卡片圆角
    .clip(true)
    .onClick(() => {
      this.openItem(item);
    })
  }

  // ============ UI：三态 ============
  //
  // 没有 loadingBlock：小程序加载时画的是**骨架屏**（2 张 sk-event），
  // 不是一行「加载中...」。骨架由上面的 skeleton() 负责，这里只剩失败与空态。

  @Builder
  failedBlock() {
    Column() {
      Text('活动加载失败')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_SUB)

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
      Text('🛰️')
        .fontSize(36)
        .opacity(0.35)
        .margin({ bottom: 12 })

      Text('活动数据整理中')
        .fontSize(14)
        .fontColor(TEXT_DATE)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    // 小程序 .empty 是 padding: 140rpx 40rpx → 70 / 20
    .padding({ top: 70, bottom: 70, left: 20, right: 20 })
  }

  /** 底部提示：还有 → 「上拉加载更多」；到底 → 「已显示 N 项」 */
  @Builder
  footHint() {
    Text(this.hasMore() ? '上拉加载更多' : '已显示 ' + String(this.visibleItems().length) + ' 项')
      .fontSize(12)
      .fontColor(TEXT_FOOT)
      .width('100%')
      .textAlign(TextAlign.Center)
      // 小程序 .foot-hint 是 padding: 20rpx 0 50rpx → 10 / 0 / 25
      .padding({ top: 10, bottom: 25 })
  }

  // ============ build ============

  build() {
    Column() {
      this.backBar()
      this.header()

      if (this.list.length === 0) {
        // 四种「空」绝不合并：失败 / 还在加载 / 真的没有（见文件头状态说明）
        if (this.failed) {
          this.failedBlock()
        } else if (this.loading || !this.loaded) {
          // 小程序条件就是 `loading && !visible.length`：还在拉、且一条都没有时才画骨架。
          // loaded 兜住「加载已结束但空」的情况，避免骨架屏一直闪。
          this.skeleton()
        } else {
          this.emptyBlock()
        }
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List() {
            ForEach(this.visibleItems(), (item: EvItem) => {
              ListItem() {
                this.card(item)
              }
              .padding({ bottom: 12 })
            }, (item: EvItem) => String(item.id))

            ListItem() {
              this.footHint()
            }
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(3)
          .onReachEnd(() => {
            this.loadMore();
          })
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => {
          this.refreshing = true;
          // 下拉刷新与小程序 onPullDownRefresh 同口径：回到第 1 页再回源
          this.resetPaging();
          this.retry();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
  }
}
