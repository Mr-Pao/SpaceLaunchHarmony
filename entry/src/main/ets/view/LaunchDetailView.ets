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
 *   2. **不铺时间线卡**。任务书的功能清单里没有「发射周期」，timelines 数据虽已核实
 *      结构（list[{id,name,net,at,items[{a,d,t,az,z}],craft}]、t 是 ISO8601 时长），
 *      但没在这版需求里，留着下一轮加，避免一次改太多。
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
  orbitLabelOf
} from '../utils/Format';
import { Countdown } from '../components/Countdown';
import { Nav } from '../routes/Nav';
import { LaunchNavParam, RocketNavParam } from '../routes/NavParam';

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

  /** 还在跑的后台请求数（两份快照），归零才收 loading */
  private pending: number = 0;
  /** 报道只拉一次（onUpdate / settle 都可能触发） */
  private newsStarted: boolean = false;
  private scroller: Scroller = new Scroller();

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadDetail();
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
      onUpdate: (fresh: DataSet) => {
        // 缓存过期后后台刷到了新数据：再探一次，命中就换上新内容
        this.probe(name);
      }
    };

    repo.load<DataSet>(name, opts)
      .then((data: DataSet) => {
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

    const opts: LoadOptions<NewsPayload> = {};
    repo.load<NewsPayload>('news', opts)
      .then((data: NewsPayload) => {
        const raw: NewsItem[] = data.list !== undefined ? data.list : [];
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
    const st: LaunchStatus | undefined = this.item.status;
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

  /** 火箭名：rocketBrief.name 优先，回退 LL2 的 rocket.configuration.name */
  private rocketName(): string {
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

  /** 小标签：可复用 / 级数。都是「有才显示」，不占位 */
  private rocketFlags(): string[] {
    const out: string[] = [];
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return out;
    }
    if (rb.reusable === true) {
      out.push('可复用');
    }
    if (ldHas(rb.max_stage)) {
      out.push(String(Math.round(ldNum(rb.max_stage))) + ' 级');
    }
    return out;
  }

  /** 六格技术参数；值为 0 / 空 / undefined 的格整格跳过 */
  private rocketSpecs(): LdCell[] {
    const out: LdCell[] = [];
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return out;
    }
    if (ldHas(rb.to_thrust)) {
      out.push(new LdCell('起飞推力', ldNumText(ldNum(rb.to_thrust)) + ' 千牛'));
    }
    if (ldHas(rb.length)) {
      out.push(new LdCell('长度', String(ldRound1(ldNum(rb.length))) + ' 米'));
    }
    if (ldHas(rb.diameter)) {
      out.push(new LdCell('直径', String(ldRound1(ldNum(rb.diameter))) + ' 米'));
    }
    if (ldHas(rb.max_stage)) {
      out.push(new LdCell('级数', String(Math.round(ldNum(rb.max_stage))) + ' 级'));
    }
    if (ldHas(rb.leo_capacity)) {
      out.push(new LdCell('LEO 运力', ldMassText(rb.leo_capacity)));
    }
    if (ldHas(rb.gto_capacity)) {
      out.push(new LdCell('GTO 运力', ldMassText(rb.gto_capacity)));
    }
    return out;
  }

  /** 一行小字：起飞质量 · 单次造价 · 首飞 */
  private rocketMeta(): string {
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return '';
    }
    const parts: string[] = [];
    const mass: string = ldMassText(rb.launch_mass);
    if (mass.length > 0) {
      parts.push('起飞质量 ' + mass);
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

  // ============ UI：火箭 ============

  @Builder
  rocketCard() {
    Column() {
      Row() {
        Text('运载火箭')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_MAIN)
        Blank()
        Text('详情 ›')
          .fontSize(11)
          .fontColor(ACCENT)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        if (this.rocketImage().length > 0 && !this.rocketImgErr) {
          Image(this.rocketImage())
            .width(64)
            .height(64)
            .objectFit(ImageFit.Cover)
            .backgroundColor(MEDIA_BG)
            .borderRadius(8)
            .onError(() => {
              this.rocketImgErr = true;
            })
        }

        Column() {
          Text(this.rocketName())
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_MAIN)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          if (this.rocketFlags().length > 0) {
            // 同上：chip 可能折行，用 Flex(wrap)；宽度跟随父 Column，不抢整行
            Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
              ForEach(this.rocketFlags(), (flag: string) => {
                this.chip(flag, false)
              }, (flag: string) => flag)
            }
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

      if (this.rocketDesc().length > 0) {
        Text(this.rocketDesc())
          .fontSize(12.5)
          .fontColor(TEXT_SUB)
          .lineHeight(19)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 10 })
      }

      if (this.rocketSpecs().length > 0) {
        Divider()
          .color(DIVIDER)
          .margin({ top: 10, bottom: 4 })
        this.cellGrid(this.rocketSpecs())
      }

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
              this.whenCard()
              if (this.hasMission()) {
                this.missionCard()
              }
              // rocketBrief 为 null 时整卡不显示（绝不渲染 "undefined"）
              if (this.rocketBrief() !== null) {
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
