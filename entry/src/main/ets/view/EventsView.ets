/**
 * view/EventsView.ets —— 「近期活动」页（EVA / 轨道插入 / 飞船对接 等航天事件）
 *
 * 对位小程序 `pages/event/event.vue`（301 行）的观感：页头 → 时间筛选分段 → 活动卡列表。
 * 鸿蒙侧不铺星空（这一页是纯信息流，星空只会让 26 张卡的图片与文字更难读），
 * 底色用全站统一的 #0A0E17。
 *
 * ── 数据链路（与 NewsListView / LaunchView 同口径）──
 *   repo.peek<EvPayload>('events')          —— 同步、零网络，冷启动立刻有内容
 *   repo.load<EvPayload>('events', {onCache, onUpdate})
 *     onCache  —— 命中原生缓存时立刻上屏
 *     onUpdate —— 缓存过期、后台刷新拿到新数据时回填（只有 generatedAt 变了才回调）
 *
 * ── 为什么「失败」与「没数据」必须是两个状态 ──
 *   原项目 utils/data.js 的 load() 在「弱网 + 无缓存」时是 **reject**，
 *   不是返回空数组。catch 里一旦置 loaded = true，页面就永久停在「暂无活动」，
 *   用户以为真的没有活动，而实际上是网络挂了。
 *   所以这里 failed 是独立状态，且 catch **只置 failed，绝不置 loaded**：
 *     list 非空                     → 列表（此时刷新失败也继续显示旧数据）
 *     list 空 && failed             → 加载失败 + 重试
 *     list 空 && !loaded && !failed → 加载中
 *     list 空 && loaded && !failed  → 暂无活动
 *
 * ── 时间筛选为什么在本地算 ──
 *   events 一次就 26 条、几十 KB，全量在内存里；「全部 / 未来 / 已结束」只是
 *   拿 date 跟 nowMs 比大小，再发请求既没必要也会闪。nowMs 在进入页面时取一次，
 *   避免同一帧里「即将」chip 与「已结束」透明度用了两个不同时刻而互相矛盾。
 *
 * ── 有意差异（不是漏做）──
 *   1. 卡片**不排序**，保持 CI 给的顺序：小程序也是直接用 list 顺序，
 *      本地重排会在上游改序时让整页跳动，且「未来 7 天」的 chip 才是真正的引导。
 *   2. 卡片**不画** location / launches：这两个字段的结构未实测确认（见 model/Event.ets），
 *      硬猜字段名会把整张卡变成空白块；类型（type）能取到才画，取不到就只留日期。
 *   3. 点击整卡走成员回调 onOpen（页面无路由权限），由父级接详情跳转。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { EvItem, EvPayload, evStr, evRefName, evTitle, evDesc } from '../model/Event';
import { parseTime, formatShort, eventTypeName } from '../utils/Format';

const DOMAIN: number = 0x0000;
const TAG: string = 'EventsView';

const DAY_MS: number = 24 * 60 * 60 * 1000;

// ============ 视觉常量（工程约定） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
/** 分段控件未选中字色（与 LaunchView 的 #6B7891 同源） */
const TEXT_LABEL: string = '#6B7891';
const ACCENT: string = '#38BDF8';

/** 卡片圆角 12vp（工程约定），图片靠外层 clip(true) 吃掉上沿圆角 */
const CARD_RADIUS: number = 12;
/** 卡片内边距 14vp（工程约定） */
const CARD_PAD: number = 14;
/** 卡间距 10vp（工程约定） */
const CARD_GAP: number = 10;
/** 头图高度 140vp（任务书给定） */
const IMG_H: number = 140;

/** 页面左右内边距 12（与 TodayView / LaunchView / MineView 对齐） */
const PAGE_PAD: number = 12;
/** 底部预留 120：这一页可能在带悬浮胶囊的容器里，留够不让最后一张卡被压住 */
// 底部留白：本页是 NavDestination 二级页，胶囊在详情页打开时已被摘掉，
// 不需要按 tab 根页那样让位 92~120，32 只够滑到底时最后一行不贴边。
const BOTTOM_PAD: number = 32;

// ============ 筛选枚举 ============

/** 用数字常量而不是 enum：与 LaunchView 的 TAB_UPCOMING / MODE_LIST 写法一致 */
const FLT_ALL: number = 0;
const FLT_FUTURE: number = 1;
const FLT_PAST: number = 2;

@Component
export struct EventsView {
  // ============ 页面状态 ============

  /** 全量活动（CI 原序，不重排 —— 见文件头「有意差异」1） */
  @State list: EvItem[] = [];
  /** 当前筛选：全部 / 未来 / 已结束 */
  @State filter: number = FLT_ALL;
  /** 是否已经成功拿到过一次数据。**失败时绝不置 true**（见文件头状态说明） */
  @State loaded: boolean = false;
  /** 正在等首屏数据（只挡内容区） */
  @State loading: boolean = true;
  /** 无缓存 + 网络失败。与「没数据」严格分开 */
  @State failed: boolean = false;
  /** 下拉刷新中（Refresh 组件的双向状态） */
  @State refreshing: boolean = false;
  /**
   * 头图加载失败的活动 id。
   *
   * 为什么用数组 + 整体替换而不是 Map/Set：ArkTS 对 Set/Map 的元素增删
   * 不保证触发 @State 重绘，而 `this.xxx = this.xxx.concat([id])` 换的是引用，
   * 一定重新渲染。26 张卡的体量，线性 indexOf 的成本可以忽略。
   */
  @State hiddenImgs: number[] = [];

  /** 「未来 / 已结束 / 即将」的统一基准时刻，进页时取一次 */
  private nowMs: number = Date.now();
  /** 防重入：返回再进来、或连点重试，不应叠请求 */
  private loadingNow: boolean = false;

  /** 点击整卡。@Prop 不用于函数，普通成员 + 默认空实现（工程约定） */
  onOpen: (item: EvItem) => void = () => {};

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.nowMs = Date.now();
    this.loadEvents(false);
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
    // 每次加载都刷新时间基准：页面可能停在后台很久，回来时「已结束」应该已经变了
    this.nowMs = Date.now();

    // 先 peek：同步、零网络，冷启动能立刻把列表画出来（有缓存就不显示加载态）
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
    // 所以这里仍按「可能是 undefined」读，缺了就当成空数组。
    // 只判 undefined、不判 null：声明类型里没有 null，多写一个不等比较会触发
    // 「no overlap」类报错。
    const raw: EvItem[] | undefined = data.list;
    const next: EvItem[] = raw !== undefined ? raw : [];
    if (next.length === 0 && this.list.length > 0) {
      return;
    }
    this.list = next;
  }

  private retry(): void {
    this.loadEvents(true);
  }

  // ============ 派生值 ============

  /** 活动时刻（毫秒）；解析失败返回 0，由调用方决定怎么兜 */
  private timeOf(item: EvItem): number {
    return parseTime(evStr(item.date));
  }

  /** 已经过去：有合法时间且早于基准时刻。时间缺失的活动归到「未来」，不至于整条消失 */
  private isPast(item: EvItem): boolean {
    const t: number = this.timeOf(item);
    return t > 0 && t < this.nowMs;
  }

  /** 未来 7 天内：卡片右上角挂「即将」chip */
  private isSoon(item: EvItem): boolean {
    const t: number = this.timeOf(item);
    return t > this.nowMs && t - this.nowMs <= 7 * DAY_MS;
  }

  /** 当前筛选下的列表。26 条的线性过滤，不值得做缓存 */
  private visibleList(): EvItem[] {
    if (this.filter === FLT_ALL) {
      return this.list;
    }
    const out: EvItem[] = [];
    for (let i = 0; i < this.list.length; i++) {
      const item: EvItem = this.list[i];
      const past: boolean = this.isPast(item);
      if (this.filter === FLT_FUTURE && !past) {
        out.push(item);
      } else if (this.filter === FLT_PAST && past) {
        out.push(item);
      }
    }
    return out;
  }

  /** 日期文案：解析不出来就留空，别让「时间待定」占满第二行 */
  private dateTextOf(item: EvItem): string {
    return this.timeOf(item) > 0 ? formatShort(evStr(item.date)) : '';
  }

  /** 第二行：日期 · 类型。任一段取不到就跳过，避免留下孤零零的分隔符 */
  private metaOf(item: EvItem): string {
    const parts: string[] = [];
    const dateText: string = this.dateTextOf(item);
    if (dateText.length > 0) {
      parts.push(dateText);
    }
    // type 可能是对象也可能是字符串，evRefName 统一取到名字；再查一次中文表
    const typeText: string = eventTypeName(evRefName(item.type));
    if (typeText.length > 0) {
      parts.push(typeText);
    }
    return parts.join(' · ');
  }

  /** 头图地址（去掉首尾空白，空串等于没有图） */
  private imgOf(item: EvItem): string {
    return evStr(item.feature_image).trim();
  }

  private showImg(item: EvItem): boolean {
    return this.imgOf(item).length > 0 && this.hiddenImgs.indexOf(item.id) < 0;
  }

  /**
   * 摘要压平。
   *
   * events 的 description 实测带 \r\n，直接丢进 Text 会在卡片里出现
   * 莫名的一行半空白（ArkUI 按真实换行排版，maxLines 也没法救）。
   * 所以先把 \r\n / \n / \r / \t 全部换成空格，再把连续空格压成一个。
   *
   * 为什么用 split/join 而不是正则：正则里 \r\n 的转义在 ArkTS 的单引号串里
   * 容易写错且不报错，split 语义直白、零解释成本。
   */
  private flatText(text: string): string {
    let s: string = text.split('\r\n').join(' ');
    s = s.split('\n').join(' ');
    s = s.split('\r').join(' ');
    s = s.split('\t').join(' ');
    // 压连续空格：上一步换行变空格后常留下 "。  Next" 这种双空格
    let guard: number = 0;
    while (s.indexOf('  ') >= 0 && guard < 32) {
      s = s.split('  ').join(' ');
      guard++;
    }
    return s.trim();
  }

  private descTextOf(item: EvItem): string {
    return this.flatText(evDesc(item));
  }

  /** 当前筛选下一条都没有时的说明：数据有、只是被筛掉了，与「暂无活动」不是一回事 */
  private filteredEmpty(): boolean {
    return this.list.length > 0 && this.visibleList().length === 0;
  }

  // ============ 交互 ============

  private openItem(item: EvItem): void {
    this.onOpen(item);
  }

  // ============ UI：页头 ============

  @Builder
  header() {
    Column() {
      Text('近期活动')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .letterSpacing(1)
        .width('100%')
        .maxLines(1)

      Text('EVA · 轨道插入 · 飞船对接')
        .fontSize(11)
        .fontColor(TEXT_LABEL)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8, bottom: 12 })
  }

  // ============ UI：筛选分段 ============

  /** 分段外壳：底 #141A26 + 圆角 16 + 极淡描边（与 LaunchView.segmented 同款） */
  @Builder
  segmented() {
    Row() {
      this.segOption('全部', FLT_ALL)
      this.segOption('未来', FLT_FUTURE)
      this.segOption('已结束', FLT_PAST)
    }
    .width('100%')
    .padding(3)
    .backgroundColor(CARD_BG)
    .borderRadius(16)
    .border({ width: 1, color: '#0DFFFFFF' })
  }

  /**
   * 单个分段。
   * 选中态 = 天蓝文字 + rgba(56,189,248,0.16) 底色（0x29 ≈ 16%），
   * 与工程其它页完全同口径，只是没有 CSS 过渡动画。
   */
  @Builder
  segOption(label: string, value: number) {
    Text(label)
      .fontSize(12.5)
      .fontWeight(this.filter === value ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.filter === value ? ACCENT : TEXT_LABEL)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: 7, bottom: 7 })
      .borderRadius(13)
      .backgroundColor(this.filter === value ? '#2938BDF8' : '#00000000')
      .onClick(() => {
        this.filter = value;
      })
  }

  // ============ UI：单张卡 ============

  @Builder
  card(item: EvItem) {
    Stack({ alignContent: Alignment.TopEnd }) {
      // 先画内容列（图 + 文字），chip 后画才能压在上面
      Column() {
        if (this.showImg(item)) {
          Image(this.imgOf(item))
            .width('100%')
            .height(IMG_H)
            .objectFit(ImageFit.Cover)
            // 失败就把这条 id 记进隐藏表：不留黑块、也不占 140vp 空白
            .onError(() => {
              this.hiddenImgs = this.hiddenImgs.concat([item.id]);
            })
        }

        Column() {
          // 首行 = 标题 + 「即将」。chip 用 layout 放在标题右侧的同一行会挤占两行标题，
          // 所以 chip 由外层 Stack 的右上角定位，这里只留标题
          Text(evTitle(item))
            .fontSize(14)
            .lineHeight(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_MAIN)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.metaOf(item).length > 0) {
            Text(this.metaOf(item))
              .fontSize(11)
              .fontColor(TEXT_DIM)
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 5 })
          }

          if (this.descTextOf(item).length > 0) {
            Text(this.descTextOf(item))
              .fontSize(12)
              .lineHeight(18)
              .fontColor(TEXT_SUB)
              .width('100%')
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 7 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(CARD_PAD)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      if (this.isSoon(item)) {
        Text('即将')
          .fontSize(10)
          .fontColor(ACCENT)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor('#2438BDF8')
          .borderRadius(4)
          .margin({ top: 10, right: 10 })
      }
    }
    .width('100%')
    .borderRadius(CARD_RADIUS)
    .backgroundColor(CARD_BG)
    // clip 同时干两件事：吃掉图片上沿的圆角，并保证 chip / 图片不溢出卡片
    .clip(true)
    // 已结束整卡压暗，与「即将」形成一前一后的时间对照
    .opacity(this.isPast(item) ? 0.6 : 1)
    .onClick(() => {
      this.openItem(item);
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
      Text('正在加载活动…')
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
      Text('活动加载失败')
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
      Text('📅')
        .fontSize(34)
        .opacity(0.5)
      Text('暂无活动')
        .fontSize(13)
        .fontColor(TEXT_SUB)
        .margin({ top: 10 })
      Text('稍后下拉重试')
        .fontSize(11)
        .fontColor(TEXT_DIM)
        .margin({ top: 6 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 被筛选清空：数据其实有，只是这个时间范围是空的 —— 给一条回「全部」的出口 */
  @Builder
  filteredEmptyBlock() {
    Column() {
      Text('📅')
        .fontSize(34)
        .opacity(0.5)
      Text('此时间范围暂无活动')
        .fontSize(13)
        .fontColor(TEXT_SUB)
        .margin({ top: 10 })

      Row() {
        Text('查看全部')
          .fontSize(12.5)
          .fontColor(ACCENT)
      }
      .padding({ left: 18, right: 18, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor('#16222F')
      .margin({ top: 16 })
      .onClick(() => {
        this.filter = FLT_ALL;
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  // ============ build ============

  build() {
    Column() {
      this.header()
      this.segmented()

      if (this.visibleList().length === 0) {
        // 三种「空」绝不合并：失败 / 还在加载 / 真的没有（见文件头状态说明）
        if (this.filteredEmpty()) {
          this.filteredEmptyBlock()
        } else if (this.failed) {
          this.failedBlock()
        } else if (!this.loaded) {
          this.loadingBlock()
        } else {
          this.emptyBlock()
        }
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List() {
            ForEach(this.visibleList(), (item: EvItem) => {
              ListItem() {
                this.card(item)
              }
              .padding({ bottom: CARD_GAP })
            }, (item: EvItem) => String(item.id))
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(3)
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => {
          this.refreshing = true;
          this.retry();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: PAGE_PAD,
      right: PAGE_PAD,
      bottom: BOTTOM_PAD
    })
  }
}
