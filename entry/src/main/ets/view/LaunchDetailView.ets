/**
 * view/LaunchDetailView.ets —— 发射详情页（对位小程序 components/launch-detail/launch-content.vue）
 *
 * 为什么要有这个文件：
 *   routes/DetailPages.ets 里的三个详情页都是全局 @Builder，而 @Builder 不是组件、
 *   不能挂 @State。详情页要「先出缓存再后台刷新」、要「展开全文」、要倒计时，
 *   这些都必须有状态，所以真实内容整体搬进这个 @Component，
 *   @Builder 只留一层 `LaunchDetailView({ param: param })` 的包装。
 *
 * 数据链路（与 TodayView / RocketDetailView 同口径：缓存先上屏，网络后补）：
 *   1. repo.findById<T>('upcoming' | 'previous' | 'upcomingMore', id)
 *      —— **同步、只读缓存、绝不发网络**，所以能同步出首屏；
 *        真实签名是 findById<T>(name: DatasetName, id: string): T | null，没有 net 参数。
 *   2. repo.load<DataSet>('upcoming' / 'previous', { onUpdate })
 *      —— 后台刷新，新数据到了才回填。
 *   3. repo.load<NewsPayload>('news') —— 首屏之后才发，不阻塞。
 *
 * 有意取舍（逐条写清，方便复核）：
 *   1. **不做「历史归档分片」反查**。小程序 findById 找不到会去 previous 的分片里翻，
 *      鸿蒙侧的 Repository 只有 chunk('gallery' | 'satellites')，没有发射归档分片，
 *      拿不到就老老实实显示「未找到该发射任务」，不假装加载中。
 *   2. **「发射周期」只查缓存、绝不主动 load**。timelines 是「一次发射一条」的大对象
 *      （items 几十条、还带 craft 的整段结构），而详情页绝大多数用户不看它；
 *      为一条发射把整份 timelines.json 拉下来，等于用首屏流量换一张可看可不看的卡。
 *      所以只 repo.findById('timelines', id)：缓存命中就画，不命中整卡不显示。
 *      代价是首次进入（缓存里还没有 timelines）看不到这张卡 —— 认为可以接受。
 *   3. **「相关报道」行不可点**。资讯详情页（ROUTE_ARTICLE）还没在 Index.ets 的
 *      PageMap 里注册，硬点会 push 一个不存在的页面，所以只展示不可跳。
 *   4. **任务详情卡的显示条件是「描述或轨道或类型至少有一个」**。任务书说「描述为空
 *      整卡不显示」，但如果轨道标签有值、只是没写描述，把轨道信息一起藏掉反而丢信息；
 *      两者都空时整卡不出现，不出现空卡片。
 *   5. **参数格 / 统计格的值无效就整格不画**。0 在这份数据里大量存在
 *      （launch_mass、gto_capacity 经常是 0），拿 0 当有值会看到一屏「0」。
 *   6. **@State 只存一个 LaunchSummary**，派生值（参数格、统计格、窗口文案）每次
 *      build 现算。整体重新赋值可被 ArkUI 观察到，而拆成二十个 @State 反而容易漏同步。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog；不使用 AppStorage。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions, DataSet } from '../data/Repository';
import { DatasetName } from '../constants/Dataset';
import {
  LaunchSummary,
  LaunchMission,
  LaunchStatus,
  LaunchPad,
  PadLocation,
  LaunchRocket,
  RocketBrief
} from '../model/Common';
import { NewsItem, NewsPayload } from '../model/News';
import {
  strOf,
  parseTime,
  toDate,
  formatLaunchTime,
  relativeTime,
  statusOf,
  statusToneColor,
  statusToneBg,
  orbitLabelOf,
  rocketLabelOf
} from '../utils/Format';
import { Countdown } from '../components/Countdown';
import { Nav } from '../routes/Nav';
import { LaunchNavParam, PhotoNavParam, RocketNavParam } from '../routes/NavParam';
import { FavItem, favInit, favHas, favToggle } from '../data/Favorites';
import { common } from '@kit.AbilityKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'LaunchDetailView';

// ============ 视觉常量（工程约定：底 #0A0E17 / 卡 #141A26 / 圆角 12 / 间距 10） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const CARD_RADIUS: number = 12;
const CARD_PAD: number = 14;
const CARD_GAP: number = 10;
/** 详情页左右留白，与列表页 12 一致（比卡内 14 小，卡片才不会贴边） */
const PAGE_PAD: number = 12;
const HERO_H: number = 220;
/** 详情页不在 tab 内，胶囊不显示 —— 底部只留 32，不用 92 */
const BOTTOM_PAD: number = 32;

const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
/** 收藏星亮色。与「我的」页虚线卡、收藏页保持一致 */
const STAR: string = '#F5C33B';
const CHIP_BG: string = '#16222F';
const CHIP_BORDER: string = '#22303F';
const DIVIDER: string = '#1E2836';
/** 图与卡的占位底：比 CARD_BG 亮一点，缺图时不会糊成一片黑 */
const MEDIA_BG: string = '#0F1725';

/** 列表卡片同款空壳，给 @State 一个安全的初始值（LaunchCard.ets 同一写法） */
const EMPTY_LAUNCH: LaunchSummary = { id: '', name: '', net: '' };

/** 「相关报道」最多展示几条：详情页不是资讯流，多到十几条会把正文挤没 */
const NEWS_LIMIT: number = 6;

/** 描述超过这个长度才值得折叠（沿用小程序 launch-content.vue 的 120） */
const DESC_FOLD_LIMIT: number = 120;
/** 折叠时显示 4 行；展开给一个足够大但不至于让布局测量异常的数 */
const DESC_FOLD_LINES: number = 4;
const DESC_OPEN_LINES: number = 100;

// ============ 本文件私有的格式化小工具 ============
// 为什么不塞进 utils/Format.ets：
//   Format.ets 是「全工程共用」的口径，一旦加进去就得对所有页面负责（要不要改
//   卡片文案、要不要跟着 CI 数据变）。下面这几个只在发射详情页用得上，
//   而且口径来自小程序 utils/format.js 里详情页专用的那几条，
//   留在本文件里改名、改文案都不会波及列表页。

/** 两位补零。不用 padStart：老 SDK 的 ArkTS 标准库对 String.prototype 扩展不一致 */
function ldPad(n: number): string {
  return n < 10 ? '0' + n : '' + n;
}

/** ISO → HH:mm。窗口起止只要钟点，日期已由上面的大字给过 */
function ldClock(iso: string): string {
  const d: Date | null = toDate(iso);
  if (d === null) {
    return '--:--';
  }
  return ldPad(d.getHours()) + ':' + ldPad(d.getMinutes());
}

/** 保留 1 位小数（1.0 → 1）：吨 / 亿美元这类单位后面跟 ".0" 很啰嗦 */
function ldRound1(v: number): number {
  return Math.round(v * 10) / 10;
}

/** 千分位。手写循环而不用正则 lookahead：ArkTS 对 (?=) 的支持不如标准 JS 稳 */
function ldNumText(v: number): string {
  const s: string = String(Math.round(v));
  let out: string = '';
  let digits: number = 0;
  for (let i = s.length - 1; i >= 0; i--) {
    const ch: string = s.charAt(i);
    if (ch === '-') {
      out = ch + out;
    } else {
      if (digits > 0 && digits % 3 === 0) {
        out = ',' + out;
      }
      out = ch + out;
      digits = digits + 1;
    }
  }
  return out;
}

/** 数值是否「有内容」：undefined / null / 0 一律视为没有（0 在这份数据里=未填） */
function ldHas(v: number | null | undefined): boolean {
  if (v === undefined || v === null) {
    return false;
  }
  return v !== 0;
}

/** 取数值，缺省 0 */
function ldNum(v: number | null | undefined): number {
  if (v === undefined || v === null) {
    return 0;
  }
  return v;
}

/**
 * 质量文案（对位 format.js 的 massText）：
 *   ≥1000kg 折成吨（≥100 取整，否则留 1 位小数），<1000kg 用 kg。
 */
function ldMassText(kg: number | null | undefined): string {
  const v: number = ldNum(kg);
  if (v <= 0) {
    return '';
  }
  if (v >= 1000) {
    const t: number = v / 1000;
    return (t >= 100 ? String(Math.round(t)) : String(ldRound1(t))) + ' 吨';
  }
  return Math.round(v) + ' kg';
}

/** 造价文案（对位 format.js 的 costText）：亿 / 万 / 元 三档 */
function ldCostText(usd: number | null | undefined): string {
  const v: number = ldNum(usd);
  if (v <= 0) {
    return '';
  }
  if (v >= 100000000) {
    return String(ldRound1(v / 100000000)) + ' 亿美元';
  }
  if (v >= 10000) {
    return String(ldRound1(v / 10000)) + ' 万美元';
  }
  return Math.round(v) + ' 美元';
}

/** 窗口时长文案（对位 format.js 的 spanText）：<60 分钟只报分钟，否则「H 小时 M 分钟」 */
function ldSpanText(from: string, to: string): string {
  const a: number = parseTime(from);
  const b: number = parseTime(to);
  if (a <= 0 || b <= 0 || b <= a) {
    return '';
  }
  const mins: number = Math.round((b - a) / 60000);
  if (mins < 60) {
    return mins + ' 分钟';
  }
  const h: number = Math.floor(mins / 60);
  const m: number = mins % 60;
  if (m === 0) {
    return h + ' 小时';
  }
  return h + ' 小时 ' + m + ' 分钟';
}

/** 报道标题：中文优先，没翻出来回退英文 */
function ldNewsTitle(n: NewsItem): string {
  const zh: string = strOf(n.titleZh);
  return zh.length > 0 ? zh : strOf(n.title);
}

/** 报道副标题：站点 · 时间（atShort 缺失才用完整 at） */
function ldNewsMeta(n: NewsItem): string {
  const site: string = strOf(n.site);
  const short: string = strOf(n.atShort);
  const time: string = short.length > 0 ? short : strOf(n.at);
  if (site.length === 0) {
    return time;
  }
  if (time.length === 0) {
    return site;
  }
  return site + ' · ' + time;
}

// ============ 参数格 / 统计格（ArkTS 禁止无类型对象字面量，先建 class 再 new） ============

/** 一格参数：值在上、标签在下（与火箭详情页同构） */
class LdCell {
  k: string = '';
  v: string = '';

  constructor(k: string, v: string) {
    this.k = k;
    this.v = v;
  }
}

/**
 * 两列网格的一行。
 *
 * 右侧不用 `LdCell | null`：ArkTS 在 @Builder 参数上的类型收窄不可靠
 * （判过非 null 之后传进去仍可能被当成可空类型）。改成「一定有个 right + 布尔」。
 */
class LdCellRow {
  left: LdCell = new LdCell('', '');
  right: LdCell = new LdCell('', '');
  hasRight: boolean = false;

  constructor(left: LdCell, right: LdCell, hasRight: boolean) {
    this.left = left;
    this.right = right;
    this.hasRight = hasRight;
  }
}

// ============ 发射周期：类型与时长格式化 ============
//
// 为什么要本文件自建类型：工程 model/ 下没有 TimelineItem（grep 只命中 Dataset.ets 里的
// 数据集键名 'timelines'）。这里的数据只为这一张卡服务，为它单开一个 model 文件不值当，
// 所以定义在文件内。名字统一加 Ld 前缀 —— 与已有的 LdCell / LdCellRow 同族，
// 也避免将来 model/Common.ets 里补上同名类型时被 ArkTS 当成声明合并。

/**
 * timelines 里的一个事件。
 *
 * 字段名是 CI 产物里的最短口径（scripts/timeline.js 的 slim 只留 a/d/t），
 * 与小程序 utils/timeline.js 消费的字段完全一致：
 *   a = 事件名、d = 描述、t = ISO8601 时长串（不是秒数！）。
 * az / z 是 LL2 的方位角与天顶角，本卡不展示，只保留声明免得将来丢字段。
 */
interface LdTimelineEvent {
  a?: string;
  d?: string;
  t?: string;
  az?: number | null;
  z?: number | null;
}

/** timelines 的一条记录：一次发射对应一份 items 时间表 */
interface LdTimelineItem {
  id?: string;
  name?: string;
  net?: string;
  items?: LdTimelineEvent[];
}

/** 渲染用的一行：把 'a/d/t' 预先算成"给 Text 直接用的字符串" */
class LdTimelineRow {
  /** 左侧时间标签，如 T-38 分 / T+2 时 48 分 / T-0 */
  tag: string = '';
  name: string = '';
  desc: string = '';
  /** 排序用的秒数（负=发射前），不参与展示 */
  sec: number = 0;

  constructor(tag: string, name: string, desc: string, sec: number) {
    this.tag = tag;
    this.name = name;
    this.desc = desc;
    this.sec = sec;
  }
}

/** 时间线最多画 12 条：再多用户也不会读，卡会变成一屏滚动条 */
const LD_TIMELINE_SHOW: number = 12;

/**
 * 解析 ISO 8601 时长串，返回「秒」，发射前为负。
 *
 * 为什么手写扫描而不用正则：ArkTS 对 RegExpMatchArray 的下标访问很挑剔
 * （Media.ets 里为此专门加了注释），而时长串最多十几个字符，逐字符扫更稳，
 * 也不用担心正则字符串里的反斜杠要转义几层。
 *
 * 支持的口径就是 LL2 实际会给出的那些：-PT38M / PT45S / PT2H48M28S / P0D / P1DT2H。
 * 解析不了（空串 / 格式不认识）一律返回 0，由调用方显示 T-0 —— 宁可显示"零时刻"，
 * 也不要出现 NaN 或 "T- 分"这种残句。
 */
function ldDurationSec(raw: string): number {
  const s: string = strOf(raw).trim();
  if (s.length === 0) {
    return 0;
  }
  let i: number = 0;
  let sign: number = 1;
  if (s.charAt(0) === '-') {
    sign = -1;
    i = 1;
  } else if (s.charAt(0) === '+') {
    i = 1;
  }
  if (s.charAt(i) !== 'P') {
    return 0;
  }
  i = i + 1;

  let days: number = 0;
  let hours: number = 0;
  let mins: number = 0;
  let secs: number = 0;
  let num: string = '';
  while (i < s.length) {
    const c: string = s.charAt(i);
    // T 只是「日期部分到此为止」的分隔符，跳过即可（P1DT2H 里它没有数值含义）
    if (c === 'T') {
      num = '';
      i = i + 1;
      continue;
    }
    // 数字 / 小数点用 charCodeAt 判，不用 '0' <= c && c <= '9'：
    // ArkTS 对字符串的大小比较运算符支持有限，数值比较稳（工程内 Format.ets 同写法）
    const code: number = s.charCodeAt(i);
    const isDigit: boolean = code >= 48 && code <= 57;
    if (isDigit || code === 46) {
      num = num + c;
      i = i + 1;
      continue;
    }
    const v: number = num.length > 0 ? Number(num) : 0;
    if (c === 'D') {
      days = v;
    } else if (c === 'H') {
      hours = v;
    } else if (c === 'M') {
      mins = v;
    } else if (c === 'S') {
      secs = v;
    }
    // 不认识的单位（W / Y 之类）也把 num 清掉，避免下一个单位吃掉两个数
    num = '';
    i = i + 1;
  }

  const total: number = days * 86400 + hours * 3600 + mins * 60 + secs;
  return sign * total;
}

/**
 * 秒数 → 中文相对时刻。
 *
 * 口径照抄小程序 utils/timeline.js 的 tlRelative：
 *   有天数 → "T-2 天 3 时"；有小时 → "T+2 时 48 分"；有分钟 → "T-38 分"；否则 "T+45 秒"。
 * 0 单独处理成 "T-0"（P0D 就是起飞时刻，小程序里同样写 T-0）。
 * 前缀的正负看总秒数，不看原始串：-PT0S 这种写法归到 T-0，不出现 "T-"。
 */
function ldTimelineTag(sec: number): string {
  if (sec === 0) {
    return 'T-0';
  }
  const pre: string = sec < 0 ? 'T-' : 'T+';
  let left: number = Math.abs(sec);
  const d: number = Math.floor(left / 86400);
  left = left - d * 86400;
  const h: number = Math.floor(left / 3600);
  left = left - h * 3600;
  const m: number = Math.floor(left / 60);
  const s: number = Math.round(left - m * 60);

  // 数字一律 String() 再拼：ArkTS 里 string + number 的隐式转换不可靠，
  // 显式转一次既稳又不用想类型推导
  if (d > 0) {
    return h > 0 ? pre + String(d) + ' 天 ' + String(h) + ' 时' : pre + String(d) + ' 天';
  }
  if (h > 0) {
    return m > 0 ? pre + String(h) + ' 时 ' + String(m) + ' 分' : pre + String(h) + ' 时';
  }
  if (m > 0) {
    return pre + String(m) + ' 分';
  }
  return pre + String(s) + ' 秒';
}

@Component
export struct LaunchDetailView {
  /** 路由入参（id / net / title）。@Prop 深拷贝，页面内部不修改它 */
  @Prop param: LaunchNavParam = new LaunchNavParam('', '', '');

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，返回栏始终在） */
  @State loading: boolean = true;
  /** 是否拿到了这条发射 */
  @State found: boolean = false;
  /** 发射本体。派生值全部在 build 时现算，不拆成二十个 @State */
  @State item: LaunchSummary = EMPTY_LAUNCH;

  /** 提到过本次发射的报道（首屏之后才拉，空数组 = 整卡不显示） */
  @State news: NewsItem[] = [];

  /** 任务描述是否展开 */
  @State descExpanded: boolean = false;

  // 三张图各自的破图标记：一张加载失败不该让另外两张也退化成色块
  @State imgErr: boolean = false;
  @State rocketImgErr: boolean = false;
  @State mapErr: boolean = false;
  /** 任务信息图破图：竖版长图本来就大，加载失败还留个空框很难看 → 整卡不显示 */
  @State infoErr: boolean = false;

  /**
   * 发射周期（只读缓存，不主动 load）。
   * 用 @State 而不是每次 build 现算：解析 ISO 时长 + 排序是 O(n) 的活，
   * 放进 build 会在每次无关的状态变化（展开描述、破图标记）里重跑一遍。
   */
  @State tlRows: LdTimelineRow[] = [];
  /** 时间线原始条数（>12 时卡片底部显示「共 N 条」） */
  @State tlTotal: number = 0;

  /** 是否已收藏本页这条发射。顶栏星标靠它决定实心还是空心 */
  @State faved: boolean = false;

  /** 已经解析过时间线的发射 id；同一条发射不重复解析 */
  private tlIdCache: string = '';

  /** 还在跑的后台请求数（两份快照），归零才收 loading */
  private pending: number = 0;
  /** 报道只拉一次（onUpdate / settle 都可能触发） */
  private newsStarted: boolean = false;
  /**
   * 上一次落地时信息图的地址。用途只有一个：刷新后地址没变就别清破图标记，
   * 否则同一张坏图会在每次后台刷新时重新请求、重新闪一下空框。
   */
  private infoSrcCache: string = '';
  private scroller: Scroller = new Scroller();

  // ============ 生命周期 ============

  aboutToAppear(): void {
    // 收藏要先初始化：preferences 需要 Context，这里是本组件最早拿到 UIContext 的时机
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      favInit(ctx);
    }
    // 读一次收藏状态。必须在 loadDetail 之前也无妨 —— 它只看 id，
    // 而 id 来自路由入参，不依赖数据是否已加载
    this.syncFaved();
    this.loadDetail();
  }

  /** 从存储层同步一次星标状态。 */
  private syncFaved(): void {
    this.faved = favHas(this.idText());
  }

  /**
   * 拼一条要落盘的收藏。
   *
   * 为什么字段来源要分开取：
   *   - `param` 只有 id / net / title 三个字段（路由入参刻意做小），
   *     所以 id / net 直接用 param；
   *   - title 优先用页面显示的标题（missionName 可能已经把中文补上），
   *     它比 param.title 更贴近用户看到的东西；
   *   - rocketName / image / siteName 只能从已加载的 detail 里派生，
   *     取不到就让对应派生方法返回空串（它们本身都做了判空）。
   */
  private buildFav(): FavItem {
    const id: string = this.idText();
    const title: string = this.missionName().length > 0 ? this.missionName() : this.titleText();
    return new FavItem(
      id,
      strOf(this.param.net).trim(),
      title,
      this.rocketName(),
      this.imageSrc(),
      this.padName(),
      Date.now()
    );
  }

  /**
   * 顶栏星标点击。
   *
   * toast 文案分开写两个分支而不是拼字符串：中文里「已收藏」与「已取消收藏」
   * 不是简单的前缀关系，拼出来的「已」+「取消收藏」在语序上赌运气。
   */
  private onTapFav(): void {
    if (this.idText().length === 0) {
      return;
    }
    const now: boolean = favToggle(this.buildFav());
    this.faved = now;
    this.getUIContext().getPromptAction().showToast({
      message: now ? '已收藏' : '已取消收藏',
      duration: 1500
    });
  }

  // ============ 加载 ============

  /**
   * 加载主干：缓存同步出首屏 → 后台刷新快照 → 首屏之后再拉报道。
   *
   * 为什么两份快照都查：同一条发射跨过发射时刻后会从 upcoming 挪到 previous，
   * 用户刚在列表里看过就点进来时可能已经换边了；只查一边会出现「列表里有、点进去没有」。
   */
  private loadDetail(): void {
    const id: string = this.idText();
    if (id.length === 0) {
      // 没有 id 无从查起，直接走「未找到」，别让 loading 一直转
      this.loading = false;
      this.found = false;
      return;
    }

    // 1) 同步缓存三连：upcomingMore 也要查，第 100 条之后的待发任务只在那份里
    this.probe('upcoming');
    this.probe('previous');
    this.probe('upcomingMore');

    if (this.found) {
      this.loading = false;
      this.startNews();
    }

    // 2) 后台刷新两份主快照。不传 force：有缓存时 load 立刻 resolve 缓存、
    //    只在过期时才后台回源，首屏不会被网络拖住。
    this.pending = 2;
    this.loadSnapshot('upcoming');
    this.loadSnapshot('previous');
  }

  /**
   * 后台刷新一份快照。
   *
   * 泛型参数故意用 DataSet 而不是 UpcomingPayload/PreviousPayload：
   * 这两份数据的信封结构完全一致，本页只关心 list 里的 id 能不能对上，
   * 用 DataSet 就不用为两个同构载荷各抄一遍回调。
   */
  private loadSnapshot(name: DatasetName): void {
    const opts: LoadOptions<DataSet> = {
      onUpdate: () => {
        // 缓存过期后后台刷到了新数据：再探一次，命中就换上新内容
        this.probe(name);
      }
    };

    repo.load<DataSet>(name, opts)
      .then(() => {
        // resolve 的值是整份快照，本页不直接用，直接从缓存里按 id 取
        this.probe(name);
      })
      .catch((e: BusinessError) => {
        // 已经渲染出内容时不要弹错；没内容就维持「未找到」
        hilog.warn(DOMAIN, TAG, '%{public}s 加载失败: %{public}s', String(name), e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  /** 在指定数据集的缓存里按 id 找一条，命中就落地 */
  private probe(name: DatasetName): void {
    const id: string = this.idText();
    if (id.length === 0) {
      return;
    }
    const hit: LaunchSummary | null = repo.findById<LaunchSummary>(name, id);
    if (hit === null) {
      // 没命中不清空已有内容：两个快照谁先到都可能，中途一次空结果不该把页面打回空态
      return;
    }
    this.applyItem(hit);
  }

  private applyItem(hit: LaunchSummary): void {
    this.item = hit;
    this.found = true;
    this.loading = false;

    // 信息图换了地址才重置破图标记：同一张坏图反复重试只会让卡片闪一下空框
    const info: string = strOf(hit.infographic).trim();
    if (info !== this.infoSrcCache) {
      this.infoSrcCache = info;
      this.infoErr = false;
    }

    this.loadTimeline();
  }

  /**
   * 发射周期：只从缓存里按 id 取，**不 load**。
   *
   * 取舍写在文件头第 2 条。这里补一句实现细节：findById 命中不了有两种情况
   * （缓存里根本没 timelines、或有 timelines 但没有这条发射），两者都表现为
   * 空数组 → 整卡不显示，用户看到的就是「这页没有发射周期」，
   * 不会出现转圈或「暂无数据」这种半吊子状态。
   */
  private loadTimeline(): void {
    const id: string = this.idText();
    if (id.length === 0) {
      this.tlRows = [];
      this.tlTotal = 0;
      return;
    }
    if (this.tlIdCache === id) {
      // 同一条发射已经解析过，后台刷新不必重算（timeline 一天内基本不变）
      return;
    }

    const hit: LdTimelineItem | null = repo.findById<LdTimelineItem>('timelines', id);
    if (hit === null) {
      this.tlRows = [];
      this.tlTotal = 0;
      return;
    }

    const raw: LdTimelineEvent[] | undefined = hit.items;
    if (raw === undefined || raw.length === 0) {
      this.tlRows = [];
      this.tlTotal = 0;
      return;
    }

    const all: LdTimelineRow[] = [];
    for (let i = 0; i < raw.length; i++) {
      const e: LdTimelineEvent = raw[i];
      const name: string = strOf(e.a).trim();
      if (name.length === 0) {
        // 没事件名的条目画出来就是一个孤零零的时间，没有信息量
        continue;
      }
      const sec: number = ldDurationSec(strOf(e.t));
      all.push(new LdTimelineRow(ldTimelineTag(sec), name, strOf(e.d).trim(), sec));
    }

    // 升序：T-2 天 → T-0 → T+10 分。数据源本身多半已排好，但 CI 合并多条来源后
    // 顺序不保证，自己排一次才敢说「从上往下就是时间顺序」。
    all.sort((a: LdTimelineRow, b: LdTimelineRow) => a.sec - b.sec);

    this.tlTotal = all.length;
    this.tlRows = all.length > LD_TIMELINE_SHOW ? all.slice(0, LD_TIMELINE_SHOW) : all;
    this.tlIdCache = id;
  }

  /** 一路收尾：两个后台请求都结束才关 loading */
  private settle(): void {
    this.pending = this.pending - 1;
    if (this.pending > 0) {
      return;
    }
    this.pending = 0;
    this.loading = false;
    if (this.found) {
      this.startNews();
    }
  }

  /**
   * 相关报道：资讯的关联是单向的（文章 → launch id），只能把 news 拉回来反查。
   *
   * 为什么放在首屏之后：news.json 几十 KB，而绝大多数发射一条报道都没有，
   * 跟着首屏一起发只会把图片和正文挤在后面。
   */
  private startNews(): void {
    if (this.newsStarted) {
      return;
    }
    this.newsStarted = true;
    const id: string = this.idText();
    if (id.length === 0) {
      return;
    }

    // 不传 opts：报道只要「有就用、没有就整卡不显示」，不需要缓存回调，
    // 也不用 force（用户翻回来看同一页时不该重新下 news.json）。
    repo.load<NewsPayload>('news')
      .then((data: NewsPayload) => {
        // list 在 NewsPayload 里是必填字段，直接遍历即可
        const raw: NewsItem[] = data.list;
        const kept: NewsItem[] = [];
        for (let i = 0; i < raw.length; i++) {
          if (kept.length >= NEWS_LIMIT) {
            break;
          }
          const n: NewsItem = raw[i];
          const ids: string[] | undefined = n.launches;
          if (ids === undefined) {
            continue;
          }
          for (let j = 0; j < ids.length; j++) {
            if (String(ids[j]) === id) {
              kept.push(n);
              break;
            }
          }
        }
        this.news = kept;
      })
      .catch((e: BusinessError) => {
        // 报道拉失败不影响正文：当作没有报道，整卡不显示
        hilog.warn(DOMAIN, TAG, 'news 加载失败: %{public}s', e.message);
      });
  }

  private retry(): void {
    this.newsStarted = false;
    this.loading = true;
    this.loadDetail();
  }

  // ============ 派生数据：标题 / 状态 ============

  private idText(): string {
    return strOf(this.param.id).trim();
  }

  private missionName(): string {
    const m: LaunchMission | undefined = this.item.mission;
    if (m === undefined) {
      return '';
    }
    const zh: string = strOf(m.nameZh);
    if (zh.length > 0) {
      return zh;
    }
    return strOf(m.name);
  }

  /** 页头 / Hero 标题：任务名 → 入参标题 → 发射名，逐级回退 */
  private titleText(): string {
    const mission: string = this.missionName();
    if (mission.length > 0) {
      return mission;
    }
    const passed: string = strOf(this.param.title).trim();
    if (passed.length > 0) {
      return passed;
    }
    return strOf(this.item.name);
  }

  private missionDesc(): string {
    const m: LaunchMission | undefined = this.item.mission;
    if (m === undefined) {
      return '';
    }
    const zh: string = strOf(m.descriptionZh);
    if (zh.length > 0) {
      return zh;
    }
    return strOf(m.description);
  }

  private missionType(): string {
    const m: LaunchMission | undefined = this.item.mission;
    if (m === undefined) {
      return '';
    }
    return strOf(m.type);
  }

  private orbitText(): string {
    return orbitLabelOf(this.item);
  }

  /** 任务卡是否出现：描述 / 轨道 / 类型任一有值（见文件头取舍 4） */
  private hasMission(): boolean {
    return this.missionDesc().length > 0 || this.orbitText().length > 0 ||
      this.missionType().length > 0;
  }

  private canExpandDesc(): boolean {
    return this.missionDesc().length > DESC_FOLD_LIMIT;
  }

  private descLines(): number {
    return this.descExpanded ? DESC_OPEN_LINES : DESC_FOLD_LINES;
  }

  private statusText(): string {
    return statusOf(this.item).text;
  }

  private statusColor(): string {
    return statusToneColor(statusOf(this.item).tone);
  }

  private statusBg(): string {
    return statusToneBg(statusOf(this.item).tone);
  }

  // ============ 派生数据：时间 / 窗口 ============

  /**
   * 是否还在待发射。
   * 口径同小程序 isStillUpcoming：时间解析不出来当待发（宁可给倒计时）；
   * 时间已过但状态还没落终态（成功/失败/已部署/部分成功）也算待发 ——
   * 否则刚过点的任务会突然从「倒计时」变成一片空白。
   */
  private isUpcoming(): boolean {
    const t: number = parseTime(this.item.net);
    if (t <= 0) {
      return true;
    }
    if (t > Date.now()) {
      return true;
    }
    // 标注带上 null：LaunchStatus 本身不含 null，但 JSON 里 status 可能是显式 null，
    // 只标 undefined 却在下一行判 null，标准 TS 会报「两个类型不可能相等」。
    const st: LaunchStatus | null | undefined = this.item.status;
    const ab: string = st === undefined || st === null ? '' : strOf(st.abbrev);
    const final: boolean = ab === 'Success' || ab === 'Failure' || ab === 'Deployed' ||
      ab === 'Partial';
    return !final;
  }

  private winStart(): string {
    return strOf(this.item.window_start);
  }

  private winEnd(): string {
    return strOf(this.item.window_end);
  }

  /** 窗口起止**都有**才显示（只有一个的话画不出「起止」） */
  private hasWindow(): boolean {
    return this.winStart().length > 0 && this.winEnd().length > 0;
  }

  private windowSpan(): string {
    return ldSpanText(this.winStart(), this.winEnd());
  }

  // ============ 派生数据：火箭 ============

  private rocketBrief(): RocketBrief | null {
    const rb: RocketBrief | null | undefined = this.item.rocketBrief;
    if (rb === undefined || rb === null) {
      return null;
    }
    return rb;
  }

  /**
   * 火箭名。**口径必须与列表页一致**：先 rocketLabelOf（走 Format 的中文名表 +
   * 构型后缀推导），再回退 rocketBrief.name，最后 rocket.configuration.name。
   *
   * 为什么不是「rocketBrief.name 优先」：rocketBrief 的 name 是 LL2 英文原名，
   * 列表页（LaunchCard / LaunchView）显示的是 rocketLabelOf 的「猎鹰 9 号 Block 5」；
   * 两处口径不一致时，用户点进来会以为换了型号。中文名缺失时 rocketLabelOf 自己
   * 会回退英文原文，所以它放第一位不会造成"没名字"。
   */
  private rocketName(): string {
    const label: string = strOf(rocketLabelOf(this.item));
    if (label.length > 0) {
      return label;
    }
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb !== null) {
      const n: string = strOf(rb.name);
      if (n.length > 0) {
        return n;
      }
    }
    const r: LaunchRocket | undefined = this.item.rocket;
    if (r === undefined) {
      return '';
    }
    return strOf(r.configuration.name);
  }

  /**
   * 参数行：高度 · 直径 · LEO 运力 · 级数，缺哪段跳过哪段。
   *
   * 字段名以 model/Common.ets 的 RocketBrief 为准：length（不是 height）、
   * diameter、leo_capacity、max_stage。写成 height 会直接编译不过。
   */
  private rocketParamText(): string {
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return '';
    }
    const parts: string[] = [];
    if (ldHas(rb.length)) {
      parts.push('高 ' + String(ldRound1(ldNum(rb.length))) + ' 米');
    }
    if (ldHas(rb.diameter)) {
      parts.push('直径 ' + String(ldRound1(ldNum(rb.diameter))) + ' 米');
    }
    if (ldHas(rb.leo_capacity)) {
      parts.push('LEO ' + ldMassText(rb.leo_capacity));
    }
    if (ldHas(rb.max_stage)) {
      parts.push(String(Math.round(ldNum(rb.max_stage))) + ' 级');
    }
    let out: string = '';
    for (let i = 0; i < parts.length; i++) {
      if (i > 0) {
        out = out + ' · ';
      }
      out = out + parts[i];
    }
    return out;
  }

  /**
   * 火箭缩略图。只有 rocketBrief.image 一条来源 ——
   * 任务书里写的「或 rocket.image」在本工程不存在：LaunchRocket 只有
   * configuration（id / name / full_name / variant / families），没有 image 字段。
   * 所以拿不到就返回空串，卡片侧据此整张图不画（不留灰块）。
   */
  private rocketImage(): string {
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return '';
    }
    return strOf(rb.image);
  }

  private rocketDesc(): string {
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return '';
    }
    return strOf(rb.desc);
  }

  /**
   * 小标签。只留「可复用」——级数已经在 rocketParamText() 的参数行里出现过，
   * 同一张卡上「4 级」写两遍（参数行 + chip）纯属重复。
   */
  private rocketFlags(): string[] {
    const out: string[] = [];
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return out;
    }
    if (rb.reusable === true) {
      out.push('可复用');
    }
    return out;
  }

  // 原本这里还有一个 rocketSpecs()（六格：推力 / 长度 / 直径 / 级数 / LEO / GTO）。
  // 火箭卡改成「一行参数 + 两行简介」之后，长度 / 直径 / 级数 / LEO 四项与
  // rocketParamText() 完全重复，六格再画一遍等于同一组数字出现两次；
  // 剩下的推力与 GTO 点进火箭详情页就能看到。故整段删除，不保留死代码。
  // cellGrid() 仍被统计概览卡（countCells）使用，不能动。

  /** 一行小字：起飞质量 · 单次造价 · 首飞 */
  private rocketMeta(): string {
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return '';
    }
    const parts: string[] = [];
    // launch_mass 本身单位就是吨（slim.js:355 注释「起飞质量单位是吨」），
    // 不能走 ldMassText —— 那是给 kg 用的，549 吨会被判成 "549 kg" 少写三位。
    // 与小程序 launch-content.vue:449 一致：只保留一位小数、整数不显示 .0。
    const massNum: number = ldNum(rb.launch_mass);
    if (massNum > 0) {
      const mt: number = Math.round(massNum * 10) / 10;
      parts.push('起飞质量 ' + (mt === Math.round(mt) ? String(Math.round(mt)) : String(mt)) + ' 吨');
    }
    const cost: string = ldCostText(rb.launch_cost);
    if (cost.length > 0) {
      parts.push('单次造价 ' + cost);
    }
    const maiden: string = strOf(rb.maiden_flight);
    if (maiden.length > 0) {
      parts.push('首飞 ' + maiden);
    }
    let out: string = '';
    for (let i = 0; i < parts.length; i++) {
      if (i > 0) {
        out = out + ' · ';
      }
      out = out + parts[i];
    }
    return out;
  }

  private goRocket(): void {
    const name: string = this.rocketName();
    if (name.length === 0) {
      return;
    }
    Nav.pushRocket(new RocketNavParam(name));
  }

  // ============ 派生数据：发射条件 / 失败原因 / 场地 / 统计 ============

  private probabilityText(): string {
    const p: number | null | undefined = this.item.probability;
    if (p === undefined || p === null) {
      return '';
    }
    return Math.round(p) + '%';
  }

  private weatherText(): string {
    const zh: string = strOf(this.item.weather_concernsZh);
    if (zh.length > 0) {
      return zh;
    }
    return strOf(this.item.weather_concerns);
  }

  private hasCondition(): boolean {
    return this.probabilityText().length > 0 || this.weatherText().length > 0;
  }

  private failText(): string {
    const zh: string = strOf(this.item.failreasonZh);
    if (zh.length > 0) {
      return zh;
    }
    return strOf(this.item.failreason);
  }

  private padName(): string {
    const pad: LaunchPad | undefined = this.item.pad;
    if (pad === undefined) {
      return '';
    }
    return strOf(pad.name);
  }

  private padPlace(): string {
    const pad: LaunchPad | undefined = this.item.pad;
    if (pad === undefined) {
      return '';
    }
    const loc: PadLocation | undefined = pad.location;
    if (loc === undefined || loc === null) {
      return '';
    }
    return strOf(loc.name);
  }

  /** 经纬度：两个都有才显示（只有一个的话坐标没有意义） */
  private padCoord(): string {
    const pad: LaunchPad | undefined = this.item.pad;
    if (pad === undefined) {
      return '';
    }
    const lat: number | null | undefined = pad.latitude;
    const lon: number | null | undefined = pad.longitude;
    if (lat === undefined || lat === null || lon === undefined || lon === null) {
      return '';
    }
    return lat.toFixed(2) + ', ' + lon.toFixed(2);
  }

  private padMap(): string {
    const pad: LaunchPad | undefined = this.item.pad;
    if (pad === undefined) {
      return '';
    }
    return strOf(pad.map_image);
  }

  /** 六格统计概览；LL2 直接给了累计数，不用自己算。值为空/0 的格跳过 */
  private countCells(): LdCell[] {
    const out: LdCell[] = [];
    const globalAll: number | null | undefined = this.item.orbital_launch_attempt_count;
    if (ldHas(globalAll)) {
      out.push(new LdCell('全球累计', ldNumText(ldNum(globalAll))));
    }
    const globalYear: number | null | undefined = this.item.orbital_launch_attempt_count_year;
    if (ldHas(globalYear)) {
      out.push(new LdCell('本年全球', ldNumText(ldNum(globalYear))));
    }
    const agencyAll: number | null | undefined = this.item.agency_launch_attempt_count;
    if (ldHas(agencyAll)) {
      out.push(new LdCell('机构累计', ldNumText(ldNum(agencyAll))));
    }
    const agencyYear: number | null | undefined = this.item.agency_launch_attempt_count_year;
    if (ldHas(agencyYear)) {
      out.push(new LdCell('本年机构', ldNumText(ldNum(agencyYear))));
    }
    const padAll: number | null | undefined = this.item.pad_launch_attempt_count;
    if (ldHas(padAll)) {
      out.push(new LdCell('工位累计', ldNumText(ldNum(padAll))));
    }
    const padYear: number | null | undefined = this.item.pad_launch_attempt_count_year;
    if (ldHas(padYear)) {
      out.push(new LdCell('本年工位', ldNumText(ldNum(padYear))));
    }
    return out;
  }

  /** 一格数组 → 两列行数组（末行可能只有左边） */
  private toRows(cells: LdCell[]): LdCellRow[] {
    const rows: LdCellRow[] = [];
    for (let i = 0; i < cells.length; i = i + 2) {
      const left: LdCell = cells[i];
      const hasRight: boolean = i + 1 < cells.length;
      const right: LdCell = hasRight ? cells[i + 1] : new LdCell('', '');
      rows.push(new LdCellRow(left, right, hasRight));
    }
    return rows;
  }

  // ============ UI：返回栏 ============

  /**
   * 自绘顶部栏。NavDestination 那边 hideTitleBar(true)，标题由这里画，
   * 这样「‹ 返回」的热区、字号、颜色都能自己定（与火箭详情页同一套）。
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
      // 上下各 10vp 把热区撑到约 40vp，别让 14vp 的字直接当可点区域
      .padding({ right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        Nav.pop();
      })

      Text(this.titleText().length > 0 ? this.titleText() : '发射详情')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // 收藏星标。放最右而不是紧贴返回键：收藏是本页的「操作」，
      // 返回是「导航」，两者分居两端才不会点错。空态的引导文案也写的是「右上角 ☆」。
      //
      // 热区靠 padding 撑：20vp 的字直接当可点区域只有 20vp 见方，太难点。
      Text(this.faved ? '★' : '☆')
        .fontSize(20)
        .fontColor(this.faved ? STAR : TEXT_SUB)
        .padding({ left: 12, top: 8, bottom: 8, right: 2 })
        .onClick(() => {
          this.onTapFav();
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .backgroundColor(BG_PRIMARY)
  }

  // ============ UI：Hero ============

  @Builder
  hero() {
    Column() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.imageSrc().length > 0 && !this.imgErr) {
          Image(this.imageSrc())
            .width('100%')
            .height(HERO_H)
            .objectFit(ImageFit.Cover)
            .backgroundColor(MEDIA_BG)
            .onError(() => {
              // 破图退回色块：留一块 220vp 的空白比色块难看得多
              this.imgErr = true;
            })
        } else {
          Column() {
            Text('暂无任务图')
              .fontSize(11)
              .fontColor(TEXT_DIM)
          }
          .width('100%')
          .height(HERO_H)
          .backgroundColor(MEDIA_BG)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }

        // 署名压在右下角：半透明底保证压在任意亮度的图上都能读
        if (this.imageCredit().length > 0) {
          Text(this.imageCredit())
            .fontSize(9.5)
            .fontColor(TEXT_SUB)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // TextAttribute 上没有 maxWidth（那是通用属性里名字叫 constraintSize 的东西），
            // 用百分比宽度 + 右对齐等效实现「最多占 70% 宽」
            .width('70%')
            .textAlign(TextAlign.End)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .backgroundColor('#66000000')
            .margin({ right: 10, bottom: 10 })
        }
      }
      .width('100%')
      .height(HERO_H)
      // 圆角裁切用 clip，不用 overflow（Column 属性上没有 overflow）
      .clip(true)

      Row() {
        Text(this.titleText())
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_MAIN)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(this.statusText())
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.statusColor())
          .backgroundColor(this.statusBg())
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 12, bottom: 2 })
    }
    .width('100%')
  }

  /** 任务信息图地址（可能为空串，调用方自己判空） */
  private infoSrc(): string {
    return strOf(this.item.infographic).trim();
  }

  /** 信息图整卡是否显示：有地址、且没加载失败过 */
  private hasInfo(): boolean {
    return this.infoSrc().length > 0 && !this.infoErr;
  }

  private imageSrc(): string {
    return strOf(this.item.image);
  }

  private imageCredit(): string {
    return strOf(this.item.imageCredit);
  }

  // ============ UI：通用卡标题 / 标签 ============

  /**
   * 卡标题。**不设 width('100%')**：它经常和 Blank() 同处一个 Row
   * （右侧挂「北京时间」「N 篇」这类小字），标题占满整行会把右边挤掉。
   * 卡片是 alignItems(Start) 的 Column，Text 自然左对齐。
   */
  @Builder
  cardTitle(text: string) {
    Text(text)
      .fontSize(15)
      .fontWeight(FontWeight.Bold)
      .fontColor(TEXT_MAIN)
  }

  @Builder
  chip(text: string, accent: boolean) {
    Text(text)
      .fontSize(11)
      .fontColor(accent ? ACCENT : TEXT_SUB)
      .backgroundColor(CHIP_BG)
      .border({ width: 1, color: accent ? '#1E4560' : CHIP_BORDER })
      .borderRadius(6)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .margin({ right: 6, bottom: 6 })
  }

  // ============ UI：倒计时 ============

  @Builder
  countdownCard() {
    Column() {
      Row() {
        this.cardTitle('距离发射')
        Blank()
        Text('北京时间')
          .fontSize(11)
          .fontColor(TEXT_DIM)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 自定义组件不能用 .margin()，外面套一层 Row 再给边距（各 SDK 版本差异最小的写法）
      Row() {
        Countdown({ net: this.item.net, sizeMode: 'lg' })
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：发射时刻 ============

  @Builder
  whenCard() {
    Column() {
      Row() {
        this.cardTitle('发射时间')
        Blank()
        Text('北京时间')
          .fontSize(11)
          .fontColor(TEXT_DIM)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(formatLaunchTime(this.item.net))
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .margin({ top: 10 })

      Text(relativeTime(this.item.net))
        .fontSize(12)
        .fontColor(ACCENT)
        .margin({ top: 2 })

      if (this.hasWindow()) {
        Divider()
          .color(DIVIDER)
          .margin({ top: 12, bottom: 10 })

        Row() {
          Text('计划发射窗口')
            .fontSize(11)
            .fontColor(TEXT_DIM)
          Blank()
          Text(this.windowSpan())
            .fontSize(11)
            .fontColor(TEXT_DIM)
        }
        .width('100%')

        Row() {
          Column() {
            Text(ldClock(this.winStart()))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(TEXT_MAIN)
            Text('开始')
              .fontSize(10.5)
              .fontColor(TEXT_DIM)
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Column() {
            Text(ldClock(this.winEnd()))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(TEXT_MAIN)
            Text('结束')
              .fontSize(10.5)
              .fontColor(TEXT_DIM)
              .margin({ top: 2 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.End)
        }
        .width('100%')
        .margin({ top: 6 })
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：任务详情 ============

  @Builder
  missionCard() {
    Column() {
      this.cardTitle('任务详情')

      if (this.orbitText().length > 0 || this.missionType().length > 0) {
        // 必须用 Flex 而不是 Row：Row 是线性布局、没有 flexWrap，
        // 轨道名 + 任务类型两个 chip 挤不下时会被压缩变形而不是折行。
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          if (this.orbitText().length > 0) {
            this.chip(this.orbitText(), true)
          }
          if (this.missionType().length > 0) {
            this.chip(this.missionType(), false)
          }
        }
        .width('100%')
        .margin({ top: 8 })
      }

      if (this.missionDesc().length > 0) {
        Text(this.missionDesc())
          .fontSize(13)
          .fontColor(TEXT_SUB)
          .lineHeight(20)
          .width('100%')
          .maxLines(this.descLines())
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 10 })

        if (this.canExpandDesc()) {
          Row() {
            Text(this.descExpanded ? '收起' : '展开全文')
              .fontSize(12)
              .fontColor(ACCENT)
            Text(this.descExpanded ? '⌃' : '⌄')
              .fontSize(11)
              .fontColor(ACCENT)
              .margin({ left: 3 })
          }
          .alignItems(VerticalAlign.Center)
          .padding({ top: 8, bottom: 2 })
          .onClick(() => {
            this.descExpanded = !this.descExpanded;
          })
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：任务信息图 ============

  /**
   * 任务信息图是竖版长图（小程序用 mode="widthFix"，即宽度撑满、高度按原图比例）。
   * Image 不设 height 时 ArkUI 就按 intrinsic 比例自适应，所以这里只给 width，
   * 外层再包一个 width('100%') 的容器 —— 长图在滚动容器里不能设固定高度，
   * 否则要么压扁要么裁掉。
   */
  @Builder
  infoCard() {
    Column() {
      this.cardTitle('任务信息图')

      Column() {
        Image(this.infoSrc())
          .width('100%')
          .objectFit(ImageFit.Contain)
          .borderRadius(10)
          .onError(() => {
            // 破图不留在页面上占一大块空白：整卡直接不显示
            this.infoErr = true;
          })
      }
      .width('100%')
      .margin({ top: 10 })
      .onClick(() => {
        Nav.pushPhoto(new PhotoNavParam(this.infoSrc(), '任务信息图'));
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：发射周期 ============

  @Builder
  timelineCard() {
    Column() {
      Row() {
        this.cardTitle('发射周期')
        Blank()
        Text('T- 起飞前 / T+ 起飞后')
          .fontSize(11)
          .fontColor(TEXT_DIM)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      ForEach(this.tlRows, (row: LdTimelineRow, idx: number) => {
        Row() {
          // 时间标签定宽右对齐：左边参差不齐的话整列会像锯齿
          Text(row.tag)
            .fontSize(12)
            .fontColor(ACCENT)
            .width(84)
            .textAlign(TextAlign.End)

          Column() {
            Text(row.name)
              .fontSize(14)
              .fontColor(TEXT_MAIN)
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (row.desc.length > 0) {
              Text(row.desc)
                .fontSize(12)
                .fontColor(TEXT_SUB)
                .width('100%')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 2 })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .margin({ top: 10 })
      }, (row: LdTimelineRow, idx: number) => String(idx) + row.tag + row.name)

      // 只画前 12 条，剩下的用一行字数交代清楚，别让用户以为数据丢了
      if (this.tlTotal > this.tlRows.length) {
        Text('共 ' + String(this.tlTotal) + ' 条')
          .fontSize(11)
          .fontColor(TEXT_DIM)
          .width('100%')
          .margin({ top: 10 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：火箭 ============

  @Builder
  rocketCard() {
    Column() {
      Row() {
        this.cardTitle('运载火箭')
        Blank()
        // 卡片整体可点，这里只是给一个「可点」的视觉暗示
        Text('›')
          .fontSize(16)
          .fontColor(TEXT_DIM)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        if (this.rocketImage().length > 0 && !this.rocketImgErr) {
          Image(this.rocketImage())
            .width(48)
            .height(48)
            .objectFit(ImageFit.Cover)
            .backgroundColor(MEDIA_BG)
            .borderRadius(8)
            .onError(() => {
              this.rocketImgErr = true;
            })
        }

        Column() {
          Text(this.rocketName())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_MAIN)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          // 高度 · 直径 · LEO 运力 · 级数，缺哪段跳哪段
          if (this.rocketParamText().length > 0) {
            Text(this.rocketParamText())
              .fontSize(14)
              .fontColor(TEXT_DIM)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 4 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        // 没有火箭图时不要留 10vp 的空缩进，否则名字会浮在卡片中间
        .margin({ left: this.rocketImage().length > 0 && !this.rocketImgErr ? 10 : 0 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 10 })

      // desc 紧跟参数行（任务书要求「在参数行下面显示两行摘要」）
      if (this.rocketDesc().length > 0) {
        Text(this.rocketDesc())
          .fontSize(12)
          .fontColor(TEXT_SUB)
          .lineHeight(18)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8 })
      }

      if (this.rocketFlags().length > 0) {
        // chip 可能折行，用 Flex(wrap)；Row 没有 flexWrap
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(this.rocketFlags(), (flag: string) => {
            this.chip(flag, false)
          }, (flag: string) => flag)
        }
        .width('100%')
        .margin({ top: 4 })
      }

      // 起飞质量 · 单次造价 · 首飞：和上面那行参数不重复，留着
      if (this.rocketMeta().length > 0) {
        Text(this.rocketMeta())
          .fontSize(11)
          .fontColor(TEXT_DIM)
          .width('100%')
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
    .onClick(() => {
      this.goRocket();
    })
  }

  /** 两列参数格：值 14vp 粗体在上、标签 11vp 灰在下 */
  @Builder
  cellGrid(cells: LdCell[]) {
    Column() {
      ForEach(this.toRows(cells), (row: LdCellRow, idx: number) => {
        Row() {
          Column() {
            Text(row.left.v)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(TEXT_MAIN)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(row.left.k)
              .fontSize(11)
              .fontColor(TEXT_DIM)
              .maxLines(1)
              .margin({ top: 2 })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 7, bottom: 7 })

          if (row.hasRight) {
            Column() {
              Text(row.right.v)
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(TEXT_MAIN)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              Text(row.right.k)
                .fontSize(11)
                .fontColor(TEXT_DIM)
                .maxLines(1)
                .margin({ top: 2 })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .padding({ top: 7, bottom: 7 })
          } else {
            // 奇数格：右侧补同权重的空位，否则左格会被拉成整行宽，
            // 两列网格就变成「一行宽一行窄」的锯齿（RocketDetailView 同写法）
            Blank().layoutWeight(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (row: LdCellRow, idx: number) => String(idx))
    }
    .width('100%')
  }

  // ============ UI：发射条件 / 失败原因 ============

  @Builder
  conditionCard() {
    Column() {
      this.cardTitle('发射条件')

      if (this.probabilityText().length > 0) {
        Row() {
          Text('预报概率')
            .fontSize(12.5)
            .fontColor(TEXT_SUB)
            .width(72)
          Text(this.probabilityText())
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(ACCENT)
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 10 })
        .alignItems(VerticalAlign.Center)
      }

      if (this.weatherText().length > 0) {
        Text(this.weatherText())
          .fontSize(13)
          .fontColor(TEXT_SUB)
          .lineHeight(20)
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  @Builder
  failCard() {
    Column() {
      this.cardTitle('失败原因')
      Text(this.failText())
        .fontSize(13)
        .fontColor(TEXT_SUB)
        .lineHeight(20)
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：发射场地 ============

  @Builder
  padCard() {
    Column() {
      this.cardTitle('发射场地')

      if (this.padMap().length > 0 && !this.mapErr) {
        Image(this.padMap())
          .width('100%')
          .height(150)
          .objectFit(ImageFit.Cover)
          .backgroundColor(MEDIA_BG)
          .borderRadius(8)
          .margin({ top: 10 })
          .onError(() => {
            this.mapErr = true;
          })
      }

      Text(this.padName())
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
        .width('100%')
        .margin({ top: 10 })

      if (this.padPlace().length > 0) {
        Text(this.padPlace())
          .fontSize(12)
          .fontColor(TEXT_SUB)
          .width('100%')
          .margin({ top: 3 })
      }

      if (this.padCoord().length > 0) {
        Row() {
          Text('经纬度')
            .fontSize(11)
            .fontColor(TEXT_DIM)
            .width(56)
          Text(this.padCoord())
            .fontSize(12)
            .fontColor(TEXT_SUB)
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ top: 10 })
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：统计概览 ============

  @Builder
  statCard() {
    Column() {
      this.cardTitle('统计概览')

      Column() {
        ForEach(this.toRows(this.countCells()), (row: LdCellRow, idx: number) => {
          Row() {
            Column() {
              Text(row.left.v)
                .fontSize(17)
                .fontWeight(FontWeight.Bold)
                .fontColor(TEXT_MAIN)
                .maxLines(1)
              Text(row.left.k)
                .fontSize(11)
                .fontColor(TEXT_DIM)
                .margin({ top: 2 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .padding({ top: 6, bottom: 6 })

            if (row.hasRight) {
              Column() {
                Text(row.right.v)
                  .fontSize(17)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(TEXT_MAIN)
                  .maxLines(1)
                Text(row.right.k)
                  .fontSize(11)
                  .fontColor(TEXT_DIM)
                  .margin({ top: 2 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .padding({ top: 6, bottom: 6 })
            } else {
              // 同参数格：奇数格右侧补空位，避免左格被拉成整行宽（三格时会很明显）
              Blank().layoutWeight(1)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (row: LdCellRow, idx: number) => String(idx))
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：相关报道 ============

  @Builder
  newsCard() {
    Column() {
      Row() {
        this.cardTitle('相关报道')
        Blank()
        Text(this.news.length + ' 篇')
          .fontSize(11)
          .fontColor(TEXT_DIM)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      ForEach(this.news, (n: NewsItem, idx: number) => {
        Column() {
          Text(ldNewsTitle(n))
            .fontSize(13)
            .fontColor(TEXT_MAIN)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(ldNewsMeta(n))
            .fontSize(11)
            .fontColor(TEXT_DIM)
            .maxLines(1)
            .margin({ top: 3 })
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: 9, bottom: 9 })
      }, (n: NewsItem) => String(n.id))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：加载中 / 未找到 ============

  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ACCENT)
      Text('正在加载发射详情…')
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
  notFoundBlock() {
    Column() {
      Text('未找到该发射任务')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)

      Text(this.idText().length > 0 ? this.idText() : '（未提供发射 id）')
        .fontSize(11)
        .fontColor(TEXT_DIM)
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })

      Row() {
        Text('重试')
          .fontSize(12.5)
          .fontColor(ACCENT)
      }
      .padding({ left: 18, right: 18, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(CHIP_BG)
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

  // ============ build ============

  build() {
    Column() {
      this.topBar()

      if (this.loading && !this.found) {
        this.loadingBlock()
      } else if (!this.found) {
        this.notFoundBlock()
      } else {
        Scroll(this.scroller) {
          Column() {
            // Hero 通栏；卡片内容才留左右内边距
            this.hero()

            Column() {
              if (this.isUpcoming()) {
                this.countdownCard()
              }
              // 发射周期紧跟倒计时：发射前它是这页最有用的一块（下一步做什么、还有多久）
              if (this.tlRows.length > 0) {
                this.timelineCard()
              }
              this.whenCard()
              if (this.hasMission()) {
                this.missionCard()
              }
              // 任务信息图是竖版长图，放在任务详情之后，当「长文配图」看
              if (this.hasInfo()) {
                this.infoCard()
              }
              // 只要拿得到火箭名就画卡（rocketBrief 缺失时还有 rocket.configuration 兜底）
              if (this.rocketName().length > 0) {
                this.rocketCard()
              }
              if (this.hasCondition()) {
                this.conditionCard()
              }
              if (this.failText().length > 0) {
                this.failCard()
              }
              if (this.padName().length > 0) {
                this.padCard()
              }
              if (this.countCells().length > 0) {
                this.statCard()
              }
              if (this.news.length > 0) {
                this.newsCard()
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: PAGE_PAD, right: PAGE_PAD })
          }
          .width('100%')
          // 详情页不在 tab 内，底部留 32 即可（不用 92 的胶囊让位）
          .padding({ bottom: BOTTOM_PAD })
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }
}
