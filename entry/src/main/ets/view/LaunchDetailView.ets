/**
 * view/LaunchDetailView.ets —— 发射详情页（对位小程序 components/launch-detail/*）
 *
 * 为什么要有这个文件：
 *   routes/DetailPages.ets 里的详情页是全局 @Builder，而 @Builder 不是组件、
 *   不能挂 @State。详情页要「先出缓存再后台刷新」、要「展开全文」、要倒计时，
 *   这些都必须有状态，所以真实内容整体搬进这个 @Component，
 *   @Builder 只留一层 `LaunchDetailView({ param: param })` 的包装。
 *
 * 本轮（2026-11-03）按小程序原版整体重排了一遍，逐项对位关系写在各段注释里。
 * 结构对照：
 *   launchInfo.vue        → 本文件的 nav（滚动 200 变实色）与看图器开关
 *   nav-bar.vue           → navBar()      固定透明顶栏 / 32vp 圆形返回 / 23vp 居中标题
 *   launch-hero.vue       → heroBlock()   330vp 轮播 + 指示点 + 图片库胶囊
 *   launch-photo.vue      → photoViewer() 全屏 #04060a 看图器
 *   launch-content.vue    → headBlock / countdownCard / timelineCard / whenCard /
 *                           winCard / missionCard / infoCard / rocketCard / craftCard /
 *                           conditionCard / failCard / padCard / statCard / newsCard
 *   launch-detail.vue     → loadingBlock / notFoundBlock / footerHint / body 的 -20vp 上提
 *
 * 数据链路（与 TodayView / RocketDetailView 同口径：缓存先上屏，网络后补）：
 *   1. repo.findById<T>('upcoming' | 'previous' | 'upcomingMore', id)
 *      —— 同步、只读缓存、绝不发网络，所以能同步出首屏；
 *        真实签名是 findById<T>(name: DatasetName, id: string): T | null，没有 net 参数。
 *   2. repo.load<DataSet>(name, { onUpdate }) —— 后台刷新，新数据到了才回填。
 *   3. repo.load<NewsPayload>('news') / repo.load<AgAgenciesPayload>('agencies')
 *      —— 首屏之后才发，不阻塞正文。
 *   4. repo.findById<LdTimelineItem>('timelines', id) —— 只读缓存，不主动 load（见取舍 2）。
 *
 * 字段口径（实测，别按任务书里的旧写法改）：
 *   · 发射时刻是 `net`（不是 window_start）；
 *   · 任务名 `mission.nameZh || mission.name`；
 *   · timelines 一条记录 = { id, name, net, at, items: [{ a, d, t, az?, z? }], craft }，
 *     其中 `t` 是 **ISO 8601 时长串**（-PT38M / PT45S / P2H... / P0D / P1DT2H），不是秒数；
 *   · craft 是航天器卡唯一的来源（timeline 与航天器由 CI 同一趟抓回）。
 *
 * 有意取舍（逐条写清，方便复核）：
 *   1. **不做「历史归档分片」反查**。小程序 findById 找不到会去 previous 的分片里翻，
 *      鸿蒙侧的 Repository 只有 chunk('gallery' | 'satellites')，没有发射归档分片，
 *      拿不到就显示「未找到该发射任务」，不假装加载中。
 *   2. **「发射周期」只查缓存、绝不主动 load**。timelines 是「一次发射一条」的大对象，
 *      为一条发射把整份 timelines.json 拉下来，等于用首屏流量换一张可看可不看的卡。
 *      代价是首次进入（缓存里还没有 timelines）看不到这张卡 —— 认为可以接受。
 *   3. **首图轮播的「同系列」取自本机已缓存的发射快照**（upcoming / previous / upcomingMore
 *      里 rocket.configuration 相同的那些条目的首图），**不额外下载 gallery**。
 *      小程序走的是媒体页的 collectMedia（按型号 id 聚合 + 火箭图库），鸿蒙侧没有
 *      utils/media 的 collectMedia，也没有「型号→图片」聚合接口；为了不为了首屏轮播
 *      去拉整份 gallery 索引（那是图库 tab 的活），这里用已缓存的发射快照做同系列。
 *      代价：没进过发射列表 / 图库时轮播只有一张 —— 不影响主体信息。
 *   4. **首图点击分两种**：只有一张时 `Nav.pushPhoto`（2000px 原图，对位小程序
 *      uni.previewImage）；多张时打开本页的全屏看图器（launch-photo 的对位实现，
 *      一样是 2000px 原图 + 左滑切换 + 图片计数）。这样两条高清看图路径都成立。
 *   5. **「图片库 N」胶囊跳到视频库**（Nav.pushVideos('')）。小程序跳的是 media 页的
 *      图片 tab，鸿蒙侧没有 media 页；视频库是本工程已有的媒体聚合页，先顶上。
 *   6. **参数格 / 统计格的值无效就整格不画**。0 在这份数据里大量存在
 *      （launch_mass、gto_capacity 经常是 0），拿 0 当有值会看到一屏「0」。
 *   7. **@State 只存一个 LaunchSummary**，派生值（参数格、统计格、窗口文案）每次
 *      build 现算。整体重新赋值可被 ArkUI 观察到，拆成二十个 @State 反而容易漏同步。
 *   8. **火箭卡不做整卡点击**。小程序整卡进型号页、机构行用 @click.stop 拦冒泡；
 *      ArkUI 的 onClick 没有可靠的 stopPropagation，整卡可点会让点机构行时
 *      连带跳一次型号页。所以可点区域收在卡标题行与缩略图/型号名这一块，
 *      机构行独立可点 —— 两个跳转都成立，不会互相打架。
 *   9. **本页不持有任何定时器**（轮播由 Swiper 内部驱动），所以没有 aboutToDisappear
 *      需要清理的资源；将来加轮播计时/自动刷新，必须在这里补清理。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog；不使用 AppStorage；不使用 any/unknown。
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
  RocketBrief,
  RocketConfig,
  LaunchProvider
} from '../model/Common';
import { NewsItem, NewsLaunchRef, NewsPayload } from '../model/News';
import { AgAgency, AgAgenciesPayload } from '../model/Agency';
import {
  strOf,
  parseTime,
  relativeTime,
  spanText,
  statusOf,
  orbitLabelOf,
  rocketLabelOf,
  missionTypeName,
  craftTypeName,
  craftStatusName,
  destName,
  agencyLabel,
  flagSrc,
  clock,
  longDate,
  countryOf
} from '../utils/Format';
import { fullImageOf, thumbOf } from '../utils/Media';
import { Countdown } from '../components/Countdown';
import { Nav } from '../routes/Nav';
import {
  LaunchNavParam,
  PhotoNavParam,
  RocketNavParam,
  PadNavParam,
  AgencyNavParam,
  ArticleNavParam
} from '../routes/NavParam';
import { FavItem, favInit, favHas, favToggle } from '../data/Favorites';
import { RemindTarget, remindInit, remindHas, remindToggle } from '../data/Reminders';
import { common } from '@kit.AbilityKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'LaunchDetailView';

// ============ 视觉常量 ============
//
// 全部按小程序 rpx ÷ 2 折算（750rpx 设计稿 → 375vp）：
//   页面底 #0a0e17 / 卡片 #141a26 / 卡片圆角 20rpx=10vp 保持工程既有 12
//   卡内边距 28rpx≈14 / 卡间距 14rpx≈7（工程既有 10）
//   正文左右留白 32rpx=16

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const CARD_RADIUS: number = 12;
const CARD_PAD: number = 14;
const CARD_GAP: number = 10;
/** 详情页正文左右留白，对位 launch-detail.vue 的 .body padding 0 32rpx（=16vp） */
const PAGE_PAD: number = 16;
/** 首图高度：launch-hero.vue 的 660rpx */
const HERO_H: number = 330;
/** 详情页不在 tab 内，底部只留 32（不用给悬浮胶囊让位的 92） */
const BOTTOM_PAD: number = 32;
/** 顶栏高度：nav-bar.vue 的 .nav-inner height 44px */
const NAV_H: number = 44;
/** 滚动超过这个距离顶栏变实色（launchInfo.vue 的 200） */
const NAV_SOLID_Y: number = 200;
/** 正文上提，压住首图底部的渐隐带：.body margin-top -40rpx = -20vp */
const BODY_LIFT: number = -20;
/** 顶栏实色：rgba(10,14,23,.96) → alpha 0xF5 */
const NAV_SOLID_BG: string = '#F50A0E17';

/** 主文字 */
const TEXT_MAIN: string = '#FFFFFF';
/** 正文 / 描述（launch-content.vue 的 #cbd5e0） */
const TEXT_SUB: string = '#CBD5E0';
/** 次要标签（#6b7891） */
const TEXT_DIM: string = '#6B7891';
/** 页脚（#3d4a5c） */
const TEXT_FAINT: string = '#3D4A5C';
const ACCENT: string = '#38BDF8';
/** 收藏星亮色，与「我的」页虚线卡、收藏页保持一致 */
const STAR: string = '#F5C33B';
const CHIP_BG: string = '#16222F';
const CHIP_BORDER: string = '#22303F';
const DIVIDER: string = '#1E2836';
/** 图与卡的占位底：比 CARD_BG 亮一点，缺图时不会糊成一片黑 */
const MEDIA_BG: string = '#0F1621';
/** 看图器底色（launch-photo.vue 的 .stage） */
const OVERLAY_BG: string = '#04060A';
/** 首图占位渐变（launch-hero.vue 的 .hero-placeholder） */
const HERO_FROM: string = '#16233A';
const HERO_TO: string = '#0D1420';

/** 列表卡片同款空壳，给 @State 一个安全的初始值（LaunchCard.ets 同一写法） */
const EMPTY_LAUNCH: LaunchSummary = { id: '', name: '', net: '' };

/** 「相关报道」最多展示几条：详情页不是资讯流，多到十几条会把正文挤没 */
const NEWS_LIMIT: number = 6;

/** 描述超过这个长度才值得折叠（沿用小程序 launch-content.vue 的 120） */
const DESC_FOLD_LIMIT: number = 120;
/** 折叠时显示 4 行；展开给一个足够大但不至于让布局测量异常的数 */
const DESC_FOLD_LINES: number = 4;
const DESC_OPEN_LINES: number = 100;

/** 首图最多几张：5 张是首屏流量与「轮播」观感的折中（与小程序一致） */
const HERO_MAX: number = 5;
/** 时间线折叠态显示几步（小程序的 pickTimeline(..., 4)） */
const TL_PICK: number = 4;

// ============ 本文件私有的格式化小工具 ============
//
// 不塞进 utils/Format.ets：那是「全工程共用」的口径，加进去就得对所有页面负责。
// 下面这几个只在发射详情页用得上，留在本文件里改名、改文案都不会波及列表页。

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

/** 造价文案（对位 format.js 的 costText）：亿 / 万 / 美元 三档 */
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

/** 英文副标题只在「与中文名不同」时显示（否则两行一样的字） */
function ldSubTitle(en: string, zh: string): string {
  const a: string = strOf(en).trim();
  const b: string = strOf(zh).trim();
  if (a.length === 0 || a === b) {
    return '';
  }
  return a;
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

// ============ 首图相册 ============
//
// 一张图 = 缩略图（首屏用，480px）+ 原图（点开才加载，2000px）+ 标题/副标题。
// 原图地址不是数据字段，靠 utils/Media 的 fullImageOf 从缩略图纯字符串推导。

class LdPhoto {
  /** 所属发射 UUID（用于 key，也用于将来跳转） */
  id: string = '';
  /** 480px 缩略图 */
  thumb: string = '';
  /** 2000px 原图；推导不出来时等于 thumb */
  full: string = '';
  /** 看图器大标题（任务名） */
  title: string = '';
  /** 看图器副行（型号 · 时间） */
  meta: string = '';

  constructor(id: string, thumb: string, full: string, title: string, meta: string) {
    this.id = id;
    this.thumb = thumb;
    this.full = full;
    this.title = title;
    this.meta = meta;
  }
}

// ============ 发射周期：类型与时长格式化 ============
//
// 为什么要本文件自建类型：工程 model/ 下没有 TimelineItem（grep 只命中 Dataset.ets 里的
// 数据集键名 'timelines'）。这里的数据只为这一张卡服务，为它单开一个 model 文件不值当。
// 名字统一加 Ld 前缀 —— 与已有的 LdCell / LdCellRow 同族，
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

/**
 * 本次发射的航天器（飞船本体）。
 *
 * 来源是 timelines 记录里的 `craft` 字段 —— scripts/timeline.js 的 slimCraft()：
 * 列表端点没有这个字段，只有单条详情才有，所以跟时间线同一趟抓回来。
 * 长征这类不公开载荷的任务恒为 null（整卡不显示）。
 */
class LdCraft {
  /** 飞船名（Crew Dragon C204） */
  name: string = '';
  /** 构型名（Crew Dragon 2） */
  config: string = '';
  /** 类型（载人舱 / 货运飞船 …），英文，需走 craftTypeName */
  type: string = '';
  /** 承制方英文名 */
  agency: string = '';
  /** 状态（Active / Retired / Destroyed …），英文，需走 craftStatusName */
  status: string = '';
  /** 目的地（LL2 的 destination），需走 destName */
  dest: string = '';
  desc: string = '';
  image: string = '';
  /** 载员（人），无人飞船是 0 */
  crew: number = 0;
  /** 运载能力（kg） */
  payload: number = 0;
  /** 高 / 直径（米） */
  height: number = 0;
  diameter: number = 0;
  /** 构型首飞（日期串） */
  maiden: string = '';
  /** 是否可载人 */
  human: boolean = false;
  /** 本次是第几次飞行（0 = 没有这个数） */
  flights: number = 0;
}

/** timelines 的一条记录：一次发射对应一份 items 时间表 + 一艘航天器 */
interface LdTimelineItem {
  id?: string;
  name?: string;
  net?: string;
  items?: LdTimelineEvent[];
  craft?: LdCraft | null;
}

/** 渲染用的一行：把 'a/t' 预先算成「给 Text 直接用的字符串」 */
class LdTimelineRow {
  /** 右侧相对时间，如 T-38 分 / T+2 时 48 分 / T-0 */
  tag: string = '';
  /** 事件中文名（表外保留英文） */
  name: string = '';
  /** 排序用的秒数（负=发射前），不参与展示 */
  sec: number = 0;
  /** 已经发生过：名字与圆点压暗（对应小程序 .tl-row.past） */
  past: boolean = false;

  constructor(tag: string, name: string, sec: number, past: boolean) {
    this.tag = tag;
    this.name = name;
    this.sec = sec;
    this.past = past;
  }
}

/**
 * 解析 ISO 8601 时长串，返回「秒」，发射前为负。
 *
 * 为什么手写扫描而不用正则：ArkTS 对 RegExpMatchArray 的下标访问很挑剔
 * （Media.ets 里为此专门加了注释），而时长串最多十几个字符，逐字符扫更稳。
 *
 * 支持的口径就是 LL2 实际会给出的那些：-PT38M / PT45S / PT2H48M28S / P0D / P1DT2H。
 * 解析不了（空串 / 格式不认识）一律返回 0，由调用方显示 T-0。
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
    // ArkTS 对字符串的大小比较运算符支持有限，数值比较稳（Format.ets 同写法）
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

  // 数字一律 String() 再拼：ArkTS 里 string + number 的隐式转换不可靠
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

/**
 * 时间线里常见节点的中文短名。
 *
 * 为什么不用 CI 回填的 az（机翻）：实测把 "Prop Load" 翻成「支柱负载」、
 * "GO for Prop Load" 翻成「GO 进行支柱负载」—— 这类节点名全是航天术语缩写，
 * 交给通用翻译只会更糟。表外宁可显示英文，也别显示错的（与小程序 TL_ZH 同口径）。
 */
const LD_TL_ZH_KEYS: string[] = [
  'go for prop load', 'prop load', 'lox load', 'stage 1 lox load', 'stage 2 lox load',
  'rp-1 load', 'go for launch', 'weather briefing', 'terminal count', 'strongback retract',
  'crew ingress', 'hatch close', 'engine chill', 'tank press', 'startup', 'ignition',
  'liftoff', 'max-q', 'meco', 'stage separation', 'stage 2 separation', 'ses-1', 'ses-2',
  'seco-1', 'seco-2', 'fairing deploy', 'fairing separation', 'entry burn',
  'entry burn startup', 'entry burn shutdown', 'landing burn', 'stage 1 landing burn',
  'landing', 'stage 1 landing', 'payload deploy', 'payload separation',
  'payload deployment sequence start', 'payload deployment sequence end',
  'dragon separation', 'docking', 'starlink deployment', 'starlink deploy', 'hold'
];
const LD_TL_ZH_VALUES: string[] = [
  '推进剂加注许可', '推进剂加注', '液氧加注', '一级液氧加注', '二级液氧加注',
  '煤油加注', '发射许可', '天气会商', '终端计数', '发射架撤收',
  '航天员进舱', '舱门关闭', '发动机预冷', '贮箱增压', '发动机启动', '点火',
  '起飞', '最大动压', '一级关机', '级间分离', '级间分离', '二级点火', '二级二次点火',
  '二级关机', '二级二次关机', '整流罩分离', '整流罩分离', '再入点火',
  '再入点火', '再入点火结束', '着陆点火', '一级着陆点火',
  '一级着陆', '一级着陆', '载荷分离', '载荷分离',
  '载荷部署开始', '载荷部署结束',
  '飞船分离', '对接', '星链部署', '星链部署', '暂缓'
];

/** 事件名中文化：命中表返回中文，表外保留英文原文 */
function ldTlLabel(raw: string): string {
  const s: string = strOf(raw).trim();
  if (s.length === 0) {
    return '';
  }
  const low: string = s.toLowerCase();
  for (let i = 0; i < LD_TL_ZH_KEYS.length; i++) {
    if (LD_TL_ZH_KEYS[i] === low) {
      return LD_TL_ZH_VALUES[i];
    }
  }
  return s;
}

@Component
export struct LaunchDetailView {
  /** 路由入参（id / net / title）。@Prop 深拷贝，页面内部不修改它 */
  @Prop param: LaunchNavParam = new LaunchNavParam('', '', '');

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，顶栏始终在） */
  @State loading: boolean = true;
  /** 是否拿到了这条发射 */
  @State found: boolean = false;
  /** 发射本体。派生值全部在 build 时现算，不拆成二十个 @State */
  @State item: LaunchSummary = EMPTY_LAUNCH;

  /** 提到过本次发射的报道（首屏之后才拉，空数组 = 整卡不显示） */
  @State news: NewsItem[] = [];

  /** 任务描述是否展开 */
  @State descExpanded: boolean = false;

  // 几张图各自的破图标记：一张加载失败不该让另外几张也退化成色块
  @State imgErr: boolean = false;
  @State rocketImgErr: boolean = false;
  @State mapErr: boolean = false;
  @State craftImgErr: boolean = false;
  /** 任务信息图破图：竖版长图本来就大，加载失败还留个空框很难看 → 整卡不显示 */
  @State infoErr: boolean = false;

  /** 首图相册（最多 5 张），第一张恒为本任务自己的主图 */
  @State photos: LdPhoto[] = [];
  /** 首图当前下标（只由 Swiper 的 onChange 回写） */
  @State heroIdx: number = 0;

  /** 全屏看图器是否打开（launch-photo 的对位实现） */
  @State viewerOn: boolean = false;
  /** 看图器当前下标 */
  @State viewerIdx: number = 0;

  /**
   * 发射周期（只读缓存，不主动 load）。
   * 用 @State 而不是每次 build 现算：解析 ISO 时长 + 排序是 O(n) 的活，
   * 放进 build 会在每次无关的状态变化（展开描述、破图标记）里重跑一遍。
   */
  @State tlRows: LdTimelineRow[] = [];
  /** 时间线总条数（右上角「展开全部 N 步」用它） */
  @State tlTotal: number = 0;
  /** 时间线是否展开（默认只给「接下来 4 步」） */
  @State tlOpen: boolean = false;

  /** 本次任务的航天器（timelines 的 craft 字段），null = 没有这张卡 */
  @State craft: LdCraft | null = null;

  /** 机构 logo（头部/机构行用；agencies 数据集里才有，异步补） */
  @State agencyLogo: string = '';

  /** 顶栏是否已变实色（滚动 > 200vp） */
  @State navSolid: boolean = false;

  /** 是否已收藏本页这条发射。顶栏星标与发射时刻卡里的「收藏」胶囊共用它 */
  @State faved: boolean = false;

  /**
   * 是否已为本页这条发射设置了提醒。三枚胶囊里的「提醒」读它。
   *
   * 与收藏分开存：收藏是「我关心这条」，提醒是「到点叫我」——
   * 两者可以只选一个，不该共用一个开关。
   */
  @State remindOn: boolean = false;

  /** 已经解析过时间线的发射 id；同一条发射不重复解析 */
  private tlIdCache: string = '';

  /** 还在跑的后台请求数（两份快照），归零才收 loading */
  private pending: number = 0;
  /** 报道 / 机构 / 相册各自只拉一次 */
  private newsStarted: boolean = false;
  private agencyStarted: boolean = false;
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
      remindInit(ctx);
    }
    // 读一次收藏状态。必须在 loadDetail 之前也无妨 —— 它只看 id，
    // 而 id 来自路由入参，不依赖数据是否已加载
    this.syncFaved();
    this.syncRemind();
    this.loadDetail();
  }

  /** 从存储层同步一次星标状态。 */
  private syncFaved(): void {
    this.faved = favHas(this.idText());
  }

  /** 从存储层同步一次提醒状态。 */
  private syncRemind(): void {
    this.remindOn = remindHas(this.idText());
  }

  /**
   * 拼一条要落盘的收藏。
   *
   * 字段来源：
   *   - `param` 只有 id / net / title 三个字段（路由入参刻意做小），id / net 直接用 param；
   *   - title 优先用页面显示的标题（missionName 可能已经把中文补上）；
   *   - rocketName / image / siteName 只能从已加载的 detail 里派生。
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
   * 收藏点击（顶栏星标与发射时刻卡里的胶囊共用）。
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
    // 「已收藏，列表里会置顶」是与小程序一致的文案（favorites 列表按 savedAt 倒序）
    this.toast(now ? '已收藏，列表里会置顶' : '已取消收藏');
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({
      message: msg,
      duration: 1500
    });
  }

  /**
   * 提醒胶囊的点击。
   *
   * 走异步：publishReminder 是一次系统 IPC，同步等会卡住首帧。
   * 成功才改界面状态 —— 失败（配额满 1700002 / 通知能力被关 1700001）
   * 保持原样并 toast 出来，**不能先乐观置 true**，否则用户看到「已提醒」
   * 但系统里什么都没有，比不提醒更坏。
   */
  private async onTapRemind(): Promise<void> {
    const id: string = this.idText();
    if (id.length === 0) {
      return;
    }
    const target: RemindTarget = new RemindTarget(
      id,
      strOf(this.param.net).trim(),
      this.missionName().length > 0 ? this.missionName() : this.titleText(),
      this.rocketName()
    );
    // ctx 只有 View 拿得到（UIContext 的 HostContext），存储层不去猜；
    // 日历授权与 getCalendarManager 都吃它。
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      this.toast('存储未就绪，请稍后重试');
      return;
    }
    const now: boolean = await remindToggle(ctx, target);
    this.remindOn = now;
    if (now) {
      this.toast('已加入日历，发射前 30 分钟提醒');
    } else {
      // 两种失败都走到这里：取消成功，或设置失败。用当前状态区分文案。
      this.toast(remindHas(id) ? '设置提醒失败，请检查日历权限' : '已取消提醒');
    }
  }

  // ============ 加载 ============

  /**
   * 加载主干：缓存同步出首屏 → 后台刷新快照 → 首屏之后再拉报道/机构。
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
      this.afterItem();
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
   * 这两份数据的信封结构完全一致，本页只关心 list 里的 id 能不能对上。
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
    this.afterItem();
  }

  /** 首屏落地之后才做的事：报道 / 机构 / 首图相册（都不阻塞正文） */
  private afterItem(): void {
    this.startNews();
    this.loadAgency();
    this.rebuildPhotos();
  }

  /**
   * 发射周期：只从缓存里按 id 取，**不 load**（取舍见文件头第 2 条）。
   *
   * findById 命中不了有两种情况（缓存里根本没 timelines、或有但没有这条发射），
   * 两者都表现为整卡不显示，不会出现转圈或「暂无数据」这种半吊子状态。
   * 同一份记录里还带着 craft（航天器），所以航天器卡也跟着一起落地。
   */
  private loadTimeline(): void {
    const id: string = this.idText();
    if (id.length === 0) {
      this.tlRows = [];
      this.tlTotal = 0;
      this.craft = null;
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
      this.craft = null;
      return;
    }

    // 航天器与时间线同源：有时只有 craft 没有 items（或不公开载荷时正好相反）
    const c: LdCraft | null | undefined = hit.craft;
    this.craft = c === undefined || c === null ? null : c;

    const raw: LdTimelineEvent[] | undefined = hit.items;
    if (raw === undefined || raw.length === 0) {
      this.tlRows = [];
      this.tlTotal = 0;
      this.tlIdCache = id;
      return;
    }

    const t0: number = parseTime(strOf(this.item.net));
    const now: number = Date.now();
    const all: LdTimelineRow[] = [];
    for (let i = 0; i < raw.length; i++) {
      const e: LdTimelineEvent = raw[i];
      const name: string = ldTlLabel(strOf(e.a));
      if (name.length === 0) {
        // 没事件名的条目画出来就是一个孤零零的时间，没有信息量
        continue;
      }
      const sec: number = ldDurationSec(strOf(e.t));
      // past 判定：发射时刻 + 相对秒数 < 现在。net 解析不出来时一律当作「还没发生」
      const past: boolean = t0 > 0 && t0 + sec * 1000 < now;
      all.push(new LdTimelineRow(ldTimelineTag(sec), name, sec, past));
    }

    // 升序：T-2 天 → T-0 → T+10 分。数据源本身多半已排好，但 CI 合并多条来源后
    // 顺序不保证，自己排一次才敢说「从上往下就是时间顺序」。
    all.sort((a: LdTimelineRow, b: LdTimelineRow) => a.sec - b.sec);

    this.tlTotal = all.length;
    this.tlRows = all;
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
      this.afterItem();
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

    repo.load<NewsPayload>('news')
      .then((data: NewsPayload) => {
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

  /**
   * 发射机构：launch_service_provider 只有 id + name（没有 logo），
   * logo 只在 agencies 数据集里，所以要异步补一次（小程序同样走 fetchAgency）。
   * 拉失败就不画 logo，机构名与国旗（emoji）照常显示。
   */
  private loadAgency(): void {
    if (this.agencyStarted) {
      return;
    }
    const p: LaunchProvider | undefined = this.item.launch_service_provider;
    if (p === undefined || p === null) {
      return;
    }
    this.agencyStarted = true;
    const pid: string = p.id === undefined || p.id === null ? '' : String(p.id);
    const pname: string = strOf(p.name);

    repo.load<AgAgenciesPayload>('agencies')
      .then((data: AgAgenciesPayload) => {
        const list: AgAgency[] = data.list;
        for (let i = 0; i < list.length; i++) {
          const a: AgAgency = list[i];
          const hitId: boolean = pid.length > 0 && String(a.id) === pid;
          const hitName: boolean = pid.length === 0 && strOf(a.name) === pname;
          if (hitId || hitName) {
            this.agencyLogo = strOf(a.logo_url);
            return;
          }
        }
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'agencies 加载失败: %{public}s', e.message);
      });
  }

  // ============ 首图相册 ============

  /** 主图缩略图（首屏用；点开时才换 2000px 原图） */
  private imageSrc(): string {
    return strOf(this.item.image);
  }

  private imageCredit(): string {
    return strOf(this.item.imageCredit);
  }

  /** 缩略图 → 原图；推导不出来就退回缩略图本身 */
  private fullOf(thumbUrl: string): string {
    const full: string = fullImageOf(thumbUrl);
    return full.length > 0 ? full : thumbUrl;
  }

  /** 火箭构型的数字 id（同系列判定用；可能为 null/缺） */
  private seriesId(): string {
    const r: LaunchRocket | undefined = this.item.rocket;
    if (r === undefined || r === null) {
      return '';
    }
    const cid: number | null | undefined = r.configuration.id;
    if (cid === undefined || cid === null) {
      return '';
    }
    return String(cid);
  }

  /** 火箭构型的英文名（同系列判定用） */
  private seriesName(): string {
    const r: LaunchRocket | undefined = this.item.rocket;
    if (r === undefined || r === null) {
      return '';
    }
    return strOf(r.configuration.name);
  }

  /** 另一条发射是否同系列：构型 id 相同，或 id 缺失时英文名相同 */
  private sameSeries(other: LaunchSummary, sid: string, sname: string): boolean {
    const r: LaunchRocket | undefined = other.rocket;
    if (r === undefined || r === null) {
      return false;
    }
    if (sid.length > 0) {
      const cid: number | null | undefined = r.configuration.id;
      if (cid !== undefined && cid !== null && String(cid) === sid) {
        return true;
      }
    }
    return sname.length > 0 && strOf(r.configuration.name) === sname;
  }

  /** 图片标题：LL2 的发射名是「型号 | 任务」，看图器只要任务那半段 */
  private photoTitleOf(raw: string): string {
    const s: string = strOf(raw);
    const parts: string[] = s.split('|');
    if (parts.length > 1) {
      return strOf(parts[1]).trim();
    }
    return s;
  }

  /**
   * 重建首图相册：主图 + 同系列首图（最多 5 张）。
   *
   * 「同系列」取自本机已缓存的发射快照（取舍见文件头第 3 条）——
   * 这一步是纯同步的 repo.peek，不发任何网络，所以可以在 applyItem 里直接调；
   * 后台快照刷新后再调一次，就能把新到的同系列图补进轮播。
   */
  private rebuildPhotos(): void {
    const out: LdPhoto[] = [];
    const raw: string = this.imageSrc();
    if (raw.length > 0) {
      const t: string = thumbOf(raw);
      out.push(new LdPhoto(this.idText(), t, this.fullOf(t), this.photoTitleOf(this.titleText()),
        this.rocketName()));
    }

    const sid: string = this.seriesId();
    const sname: string = this.seriesName();
    if (sid.length > 0 || sname.length > 0) {
      const names: DatasetName[] = ['upcoming', 'previous', 'upcomingMore'];
      for (let k = 0; k < names.length; k++) {
        if (out.length >= HERO_MAX) {
          break;
        }
        const d: DataSet | null = repo.peek<DataSet>(names[k]);
        if (d === null) {
          continue;
        }
        const list: Object[] | undefined = d.list;
        if (list === undefined) {
          continue;
        }
        for (let i = 0; i < list.length; i++) {
          if (out.length >= HERO_MAX) {
            break;
          }
          const rec: LaunchSummary = list[i] as Object as LaunchSummary;
          if (rec === undefined || rec === null) {
            continue;
          }
          if (strOf(rec.id) === this.idText()) {
            continue;
          }
          if (!this.sameSeries(rec, sid, sname)) {
            continue;
          }
          const img: string = thumbOf(strOf(rec.image));
          if (img.length === 0) {
            continue;
          }
          // 去重：同一张镜像图可能被多条记录引用（同一次任务的多次推迟）
          let dup: boolean = false;
          for (let j = 0; j < out.length; j++) {
            if (out[j].thumb === img) {
              dup = true;
              break;
            }
          }
          if (dup) {
            continue;
          }
          out.push(new LdPhoto(strOf(rec.id), img, this.fullOf(img),
            this.photoTitleOf(strOf(rec.name)), this.rocketNameOf(rec)));
        }
      }
    }

    this.photos = out;
    // 相册变短时把下标收回来，否则 Swiper 的 index 越界会显示空白
    if (this.heroIdx >= out.length) {
      this.heroIdx = 0;
    }
    if (this.viewerIdx >= out.length) {
      this.viewerIdx = 0;
    }
  }

  /** 从任意一条发射取型号名（同系列相册的副标题用） */
  private rocketNameOf(rec: LaunchSummary): string {
    const label: string = strOf(rocketLabelOf(rec));
    if (label.length > 0) {
      return label;
    }
    return '';
  }

  /** 看图器大标题 */
  private viewerTitle(): string {
    const cur: LdPhoto | null = this.currentPhoto();
    if (cur === null) {
      return this.titleText();
    }
    return cur.title.length > 0 ? cur.title : this.titleText();
  }

  /** 看图器副行：型号 · 时间 · @credit（与小程序 stage-meta 同口径） */
  private viewerMeta(): string {
    const parts: string[] = [];
    const cur: LdPhoto | null = this.currentPhoto();
    if (cur !== null && cur.meta.length > 0) {
      parts.push(cur.meta);
    }
    const when: string = longDate(this.item.net);
    if (when.length > 0) {
      parts.push(when);
    }
    const credit: string = this.imageCredit();
    if (credit.length > 0) {
      parts.push('@' + credit);
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

  private currentPhoto(): LdPhoto | null {
    if (this.viewerIdx < 0 || this.viewerIdx >= this.photos.length) {
      return null;
    }
    return this.photos[this.viewerIdx];
  }

  /** 首图点击：只有一张时走图片详情页；多张时打开本页看图器（取舍见文件头第 4 条） */
  private openHero(): void {
    if (this.photos.length > 1) {
      this.viewerIdx = this.heroIdx;
      this.viewerOn = true;
      return;
    }
    const url: string = this.photos.length > 0 ? this.photos[0].full : this.fullOf(thumbOf(this.imageSrc()));
    if (url.length === 0) {
      return;
    }
    Nav.pushPhoto(new PhotoNavParam(url, this.titleText()));
  }

  /**
   * 图片库入口 → 型号媒体库。
   *
   * 小程序 goMedia(tab) 传的是 rocket.configuration.id；鸿蒙侧只能传名字，
   * MediaView 会拿它回 launchers 里按 name / full_name 定位构型。
   * 名字取 `configuration.name`（英文原名），不用 rocketName() 的中文译名 ——
   * 中文名在 launchers 里查不到。
   */
  private goMedia(): void {
    const rk: LaunchRocket | undefined = this.item.rocket;
    const cfg: RocketConfig | undefined = rk !== undefined ? rk.configuration : undefined;
    const name: string = cfg !== undefined ? strOf(cfg.name).trim() : '';
    if (name.length === 0) {
      return;
    }
    Nav.pushMedia(name, 0);
  }

  // ============ 顶栏滚动状态 ============

  /**
   * 滚动时同步顶栏实色标记。
   *
   * 用 scroller.currentOffset() 取绝对偏移，而不是回调里的 scrollOffset 增量 ——
   * 增量在不同版本上有「本次位移」和「累计位移」两种解读，绝对偏移没有歧义。
   */
  private syncNavSolid(): void {
    // 不写 `: OffsetResult` 显式标注：它是 ArkUI 的全局内置接口，工程内没有第二处
    // currentOffset 用例可对拍，交给推断更不容易因为 SDK 改了返回类型就编译失败
    const off = this.scroller.currentOffset();
    const solid: boolean = off.yOffset > NAV_SOLID_Y;
    if (solid !== this.navSolid) {
      this.navSolid = solid;
    }
  }

  // ============ 派生数据：标题 / 状态 ============

  private idText(): string {
    return strOf(this.param.id).trim();
  }

  private missionName(): string {
    const m: LaunchMission | undefined = this.item.mission;
    if (m === undefined || m === null) {
      return '';
    }
    const zh: string = strOf(m.nameZh);
    if (zh.length > 0) {
      return zh;
    }
    return strOf(m.name);
  }

  /** 页头 / 首图 / 顶栏标题：任务名 → 入参标题 → 发射名，逐级回退 */
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
    if (m === undefined || m === null) {
      return '';
    }
    const zh: string = strOf(m.descriptionZh);
    if (zh.length > 0) {
      return zh;
    }
    return strOf(m.description);
  }

  /** 任务类型（中文化：Communications → 通信） */
  private missionType(): string {
    const m: LaunchMission | undefined = this.item.mission;
    if (m === undefined || m === null) {
      return '';
    }
    return missionTypeName(strOf(m.type));
  }

  private orbitText(): string {
    return orbitLabelOf(this.item);
  }

  /** 任务卡是否出现：任务名 / 类型 / 轨道 / 描述任一有值 */
  private hasMission(): boolean {
    return this.missionName().length > 0 || this.missionType().length > 0 ||
      this.orbitText().length > 0 || this.missionDesc().length > 0;
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

  /**
   * 状态徽章色（对位 launch-content.vue 的 .badge.*）：
   *   成功 #34c759 / 失败 #ff3b30 / 飞行中 #f5c33b / 其余（待发 · 未知）一律青色。
   * 不复用 statusToneColor：它对 pending 给的是灰 #8A97A8，
   * 而小程序详情页的待发徽章是青色，两处口径不同。
   */
  private badgeColor(): string {
    const tone: string = statusOf(this.item).tone;
    if (tone === 'success') {
      return '#34C759';
    }
    if (tone === 'failure') {
      return '#FF3B30';
    }
    if (tone === 'flying') {
      return '#F5C33B';
    }
    return '#38BDF8';
  }

  /** 徽章底色：同色系 0.15 alpha（rgba → #26RRGGBB） */
  private badgeBg(): string {
    const tone: string = statusOf(this.item).tone;
    if (tone === 'success') {
      return '#2634C759';
    }
    if (tone === 'failure') {
      return '#26FF3B30';
    }
    if (tone === 'flying') {
      return '#26F5C33B';
    }
    return '#2638BDF8';
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
    return spanText(this.winStart(), this.winEnd());
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
   * 列表页显示的是「猎鹰 9 号 Block 5」；两处口径不一致时，用户点进来会以为换了型号。
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
    if (r === undefined || r === null) {
      return '';
    }
    return strOf(r.configuration.name);
  }

  /** 英文副标题：LL2 的 full_name（含构型），与中文名相同则不显示 */
  private rocketSub(): string {
    const r: LaunchRocket | undefined = this.item.rocket;
    if (r === undefined || r === null) {
      return '';
    }
    const c: RocketConfig = r.configuration;
    const en: string = strOf(c.full_name).length > 0 ? strOf(c.full_name) : strOf(c.name);
    return ldSubTitle(en, this.rocketName());
  }

  /** 现役 / 已退役。没有 rocketBrief 时不画（不清楚就别猜） */
  private rocketActiveKnown(): boolean {
    return this.rocketBrief() !== null;
  }

  private rocketActive(): boolean {
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return false;
    }
    return rb.active === true;
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

  /** 小标签：可复用 / N 级（小程序 rocketFlags 两项都画，参数格里也有级数，属有意重复） */
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

  /**
   * 火箭六格参数（对位 launch-content.vue 的 rocketSpecs）：
   *   起飞推力 / 长度 / 直径 / 级数 / LEO 运力 / GTO 运力。
   * 值 0 或空一律跳过 —— 这份数据里 0 就是「没填」，画出来是一屏 0。
   */
  private rocketSpecCells(): LdCell[] {
    const out: LdCell[] = [];
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return out;
    }
    if (ldHas(rb.to_thrust)) {
      out.push(new LdCell('起飞推力', String(Math.round(ldNum(rb.to_thrust))) + ' 千牛'));
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
    const leo: string = ldMassText(rb.leo_capacity);
    if (leo.length > 0) {
      out.push(new LdCell('LEO 运力', leo));
    }
    const gto: string = ldMassText(rb.gto_capacity);
    if (gto.length > 0) {
      out.push(new LdCell('GTO 运力', gto));
    }
    return out;
  }

  /** 一行小字：起飞质量 · 单次造价 · 首飞（参数格放不下的三项） */
  private rocketMetaText(): string {
    const rb: RocketBrief | null = this.rocketBrief();
    if (rb === null) {
      return '';
    }
    const parts: string[] = [];
    // launch_mass 本身单位就是吨（slim.js 注释「起飞质量单位是吨」），
    // 不能走 ldMassText —— 那是给 kg 用的，549 吨会被判成 "549 kg" 少写三位。
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

  // ============ 派生数据：发射机构 ============

  private agencyName(): string {
    const p: LaunchProvider | undefined = this.item.launch_service_provider;
    if (p === undefined || p === null) {
      return '';
    }
    return agencyLabel(strOf(p.name));
  }

  /** 国旗 emoji（Format.flagSrc 返回 emoji，不是图片地址） */
  private agencyFlag(): string {
    const p: LaunchProvider | undefined = this.item.launch_service_provider;
    if (p === undefined || p === null) {
      return '';
    }
    return flagSrc(strOf(p.name));
  }

  private hasAgency(): boolean {
    return this.agencyName().length > 0;
  }

  private goAgency(): void {
    const p: LaunchProvider | undefined = this.item.launch_service_provider;
    if (p === undefined || p === null) {
      return;
    }
    const id: string = p.id === undefined || p.id === null ? '' : String(p.id);
    Nav.pushAgency(new AgencyNavParam(id, strOf(p.name)));
  }

  // ============ 派生数据：航天器 ============

  private craftTitle(): string {
    const c: LdCraft | null = this.craft;
    if (c === null) {
      return '';
    }
    const n: string = strOf(c.name);
    return n.length > 0 ? n : strOf(c.config);
  }

  /** 副行：构型 · 类型 · 承制方（名称里已经含构型时不重复） */
  private craftSub(): string {
    const c: LdCraft | null = this.craft;
    if (c === null) {
      return '';
    }
    const parts: string[] = [];
    const cfg: string = strOf(c.config);
    if (cfg.length > 0 && cfg !== this.craftTitle()) {
      parts.push(cfg);
    }
    const type: string = craftTypeName(strOf(c.type));
    if (type.length > 0) {
      parts.push(type);
    }
    const ag: string = agencyLabel(strOf(c.agency));
    if (ag.length > 0) {
      parts.push(ag);
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

  private craftStatusText(): string {
    const c: LdCraft | null = this.craft;
    if (c === null) {
      return '';
    }
    return craftStatusName(strOf(c.status));
  }

  /** 只有 Active 算「在役」；Destroyed / Lost / Retired 都用灰标签，别把已损毁染成绿色 */
  private craftLive(): boolean {
    const c: LdCraft | null = this.craft;
    if (c === null) {
      return false;
    }
    return strOf(c.status).toLowerCase() === 'active';
  }

  private craftDest(): string {
    const c: LdCraft | null = this.craft;
    if (c === null) {
      return '';
    }
    return destName(strOf(c.dest));
  }

  private craftDesc(): string {
    const c: LdCraft | null = this.craft;
    if (c === null) {
      return '';
    }
    return strOf(c.desc);
  }

  private craftImage(): string {
    const c: LdCraft | null = this.craft;
    if (c === null) {
      return '';
    }
    return strOf(c.image);
  }

  /** 乘员 / 载员：crew_capacity 是「能坐几个人」，无人飞船是 0，不显示 0 */
  private craftSpecCells(): LdCell[] {
    const out: LdCell[] = [];
    const c: LdCraft | null = this.craft;
    if (c === null) {
      return out;
    }
    if (ldHas(c.height)) {
      out.push(new LdCell('高度', String(ldRound1(ldNum(c.height))) + ' 米'));
    }
    if (ldHas(c.diameter)) {
      out.push(new LdCell('直径', String(ldRound1(ldNum(c.diameter))) + ' 米'));
    }
    if (ldHas(c.crew)) {
      out.push(new LdCell('载员', String(Math.round(ldNum(c.crew))) + ' 人'));
    }
    const payload: string = ldMassText(c.payload);
    if (payload.length > 0) {
      out.push(new LdCell('运载能力', payload));
    }
    // 值和标签上下排：写成「本次是第 / 1 次飞行」会把主谓拆到两行
    if (ldHas(c.flights)) {
      out.push(new LdCell('本次飞行', '第 ' + String(Math.round(ldNum(c.flights))) + ' 次'));
    }
    return out;
  }

  private craftMetaText(): string {
    const c: LdCraft | null = this.craft;
    if (c === null) {
      return '';
    }
    const parts: string[] = [];
    if (c.human === true) {
      parts.push('可载人');
    }
    const maiden: string = strOf(c.maiden);
    if (maiden.length > 0) {
      parts.push('构型首飞 ' + maiden);
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
    if (pad === undefined || pad === null) {
      return '';
    }
    return strOf(pad.name);
  }

  /**
   * 场地写法（对位小程序 padPlace）：设施名第一段 + 中文国家。
   * 直接铺 "Jiuquan Satellite Launch Center, People's Republic of China" 会占两行且全英文。
   */
  private padPlace(): string {
    const pad: LaunchPad | undefined = this.item.pad;
    if (pad === undefined || pad === null) {
      return '';
    }
    const loc: PadLocation | undefined = pad.location;
    if (loc === undefined || loc === null) {
      return '';
    }
    const name: string = strOf(loc.name);
    if (name.length === 0) {
      return '';
    }
    const parts: string[] = name.split(',');
    const first: string = strOf(parts[0]).trim();
    const country: string = countryOf(this.item);
    if (country.length === 0 || first === country) {
      return first.length > 0 ? first : country;
    }
    return first.length > 0 ? first + ' · ' + country : country;
  }

  /** 发射场原文（PadNavParam 的 place 用，PadView 靠它给 "Unknown Pad" 消歧） */
  private padLocationName(): string {
    const pad: LaunchPad | undefined = this.item.pad;
    if (pad === undefined || pad === null) {
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
    if (pad === undefined || pad === null) {
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
    if (pad === undefined || pad === null) {
      return '';
    }
    return strOf(pad.map_image);
  }

  /** 工位累计发射数：pad.total_launch_count 优先，回退 location.total_launch_count */
  private padLaunchCount(): number {
    const pad: LaunchPad | undefined = this.item.pad;
    if (pad === undefined || pad === null) {
      return 0;
    }
    if (ldHas(pad.total_launch_count)) {
      return ldNum(pad.total_launch_count);
    }
    const loc: PadLocation | undefined = pad.location;
    if (loc === undefined || loc === null) {
      return 0;
    }
    return ldHas(loc.total_launch_count) ? ldNum(loc.total_launch_count) : 0;
  }

  private goPad(): void {
    const name: string = this.padName();
    if (name.length === 0) {
      return;
    }
    // LL2 的 pad 对象没带 id，只能拿名字去 pads 数据集反查，所以 id 传空串；
    // 带上 location.name 做二次消歧（"Unknown Pad" 有好几条）。
    Nav.pushPad(new PadNavParam('', name, this.padLocationName()));
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
    const agencyAll: number | undefined = this.item.agency_launch_attempt_count;
    if (ldHas(agencyAll)) {
      out.push(new LdCell('机构累计', ldNumText(ldNum(agencyAll))));
    }
    const agencyYear: number | undefined = this.item.agency_launch_attempt_count_year;
    if (ldHas(agencyYear)) {
      out.push(new LdCell('本年机构', ldNumText(ldNum(agencyYear))));
    }
    const padAll: number | undefined = this.item.pad_launch_attempt_count;
    if (ldHas(padAll)) {
      out.push(new LdCell('工位累计', ldNumText(ldNum(padAll))));
    }
    const padYear: number | undefined = this.item.pad_launch_attempt_count_year;
    if (ldHas(padYear)) {
      out.push(new LdCell('本年工位', ldNumText(ldNum(padYear))));
    }
    return out;
  }

  /** 一格数组 → 两列行数组（末行可能只有左边） */
  private gridRows(cells: LdCell[]): LdCellRow[] {
    const rows: LdCellRow[] = [];
    for (let i = 0; i < cells.length; i = i + 2) {
      const left: LdCell = cells[i];
      const hasRight: boolean = i + 1 < cells.length;
      const right: LdCell = hasRight ? cells[i + 1] : new LdCell('', '');
      rows.push(new LdCellRow(left, right, hasRight));
    }
    return rows;
  }

  // ============ 派生数据：任务信息图 ============

  private infoSrc(): string {
    return strOf(this.item.infographic).trim();
  }

  /** 信息图整卡是否显示：有地址、且没加载失败过 */
  private hasInfo(): boolean {
    return this.infoSrc().length > 0 && !this.infoErr;
  }

  // ============ 派生数据：时间线折叠 ============

  /**
   * 折叠态从哪一条开始：第一个「还没发生」的节点。
   * 全部已过（发射完成）则退回到最后 4 条，把起飞到入轨这段留下来 ——
   * 与小程序 pickTimeline 的 start 计算完全一致。
   */
  private tlStart(): number {
    const n: number = this.tlRows.length;
    if (n === 0) {
      return 0;
    }
    const t0: number = parseTime(this.item.net);
    if (t0 <= 0) {
      return 0;
    }
    const now: number = Date.now();
    for (let i = 0; i < n; i++) {
      if (t0 + this.tlRows[i].sec * 1000 >= now) {
        return i;
      }
    }
    return Math.max(0, n - TL_PICK);
  }

  /** 要画的节点：展开时全给，折叠时只给「接下来 4 步」 */
  private tlDisplay(): LdTimelineRow[] {
    const n: number = this.tlRows.length;
    if (n === 0) {
      return [];
    }
    if (this.tlOpen) {
      return this.tlRows;
    }
    const start: number = this.tlStart();
    const out: LdTimelineRow[] = [];
    for (let i = start; i < n && out.length < TL_PICK; i++) {
      out.push(this.tlRows[i]);
    }
    return out;
  }

  /** 折叠时还没显示出来的条数（0 = 不出现「展开全部」） */
  private tlMoreCount(): number {
    if (this.tlOpen) {
      return 0;
    }
    return Math.max(0, this.tlTotal - this.tlStart() - TL_PICK);
  }

  // ============ 派生数据：相关报道 ============

  /**
   * 打开资讯详情。
   *
   * 小程序是在详情页就地弹 news-detail 弹窗；鸿蒙侧有独立的 ArticleDetailView
   * （ROUTE_ARTICLE 已在 PageMap 注册），所以改成正常压栈 —— 返回后还能回到本页。
   * ArticleNavParam 是「无参构造 + 逐字段赋值」（10 个字段里 9 个都是 string，
   * 全参构造写错顺序编译器不会报），见 routes/NavParam.ets 的注释。
   */
  private openArticle(n: NewsItem): void {
    const p: ArticleNavParam = new ArticleNavParam();
    p.id = String(n.id);
    p.title = strOf(n.title);
    p.titleZh = strOf(n.titleZh);
    p.summary = strOf(n.summary);
    p.summaryZh = strOf(n.summaryZh);
    p.image = strOf(n.image);
    p.site = strOf(n.site);
    p.url = strOf(n.url);
    p.at = strOf(n.at);
    const refs: NewsLaunchRef[] | undefined = n.launchRefs;
    p.launchRefs = refs === undefined ? [] : refs;
    Nav.pushArticle(p);
  }

  // ============ UI：固定顶栏 ============

  /**
   * 自绘顶栏（对位 nav-bar.vue）。
   *
   * 三段式：左 32vp 圆形返回 / 中 23vp w600 居中标题 / 右 20vp 收藏星标。
   * 左右两侧容器都定宽 32，标题才是真正居中（不是「剩余空间居中」）。
   * 标题只在滚动变实色后出现 —— 透明时压在首图上，文字会与图打架。
   */
  @Builder
  navBar() {
    Row() {
      // 返回：半透明黑底圆形 + ‹；变实色后圆底去掉（nav-bar.vue 的 .nav.solid .nav-back）
      Row() {
        Text('‹')
          .fontSize(23)
          .fontColor(TEXT_MAIN)
          .lineHeight(23)
          .margin({ top: -2 })
      }
      .width(32)
      .height(32)
      .borderRadius(16)
      .backgroundColor(this.navSolid ? '#00000000' : '#52000000')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        Nav.pop();
      })

      Row() {
        if (this.navSolid) {
          Text(this.titleText())
            .fontSize(23)
            .fontWeight(600)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)

      Row() {
        if (this.found) {
          Text(this.faved ? '★' : '☆')
            .fontSize(20)
            .fontColor(this.faved ? STAR : TEXT_SUB)
        }
      }
      .width(32)
      .justifyContent(FlexAlign.End)
      .onClick(() => {
        if (this.found) {
          this.onTapFav();
        }
      })
    }
    .width('100%')
    .height(NAV_H)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 10, right: 10 })
    .backgroundColor(this.navSolid ? NAV_SOLID_BG : '#00000000')
    .border({ width: { bottom: this.navSolid ? 0.5 : 0 }, color: '#0DFFFFFF' })
  }

  // ============ UI：首图 ============

  /**
   * 首图区（对位 launch-hero.vue）：330vp 高、通栏、压在顶栏下面。
   *
   * 三层：
   *   1. 图（多图走 Swiper 自动轮播 5s；单图直接 Image；无图是 135° 渐变、**无文字**）
   *   2. 底部 100vp 渐隐遮罩（把图融进 #0A0E17，正文就压在这段上）
   *   3. 右上指示点 / 右下「图片库 N」磨砂胶囊
   *
   * 有意差异：首图**不画 imageCredit**（小程序首图也不画，署名只在看图器副行里）。
   */
  @Builder
  heroBlock() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.photos.length > 1) {
        Swiper() {
          ForEach(this.photos, (p: LdPhoto, i: number) => {
            Image(p.thumb)
              .width('100%')
              .height(HERO_H)
              .objectFit(ImageFit.Cover)
              .backgroundColor(MEDIA_BG)
              .onError(() => {
                // 破图只影响这一张：多图时其余几张照常轮播
                this.imgErr = true;
              })
              .onClick(() => {
                this.heroIdx = i;
                this.openHero();
              })
          }, (p: LdPhoto, i: number) => 'hero' + p.thumb + String(i))
        }
        .width('100%')
        .height(HERO_H)
        .autoPlay(true)
        .interval(5000)
        .loop(true)
        .duration(400)
        .indicator(false)
        .onChange((idx: number) => {
          this.heroIdx = idx;
        })
      } else if (this.photos.length === 1 && !this.imgErr) {
        Image(this.photos[0].thumb)
          .width('100%')
          .height(HERO_H)
          .objectFit(ImageFit.Cover)
          .backgroundColor(MEDIA_BG)
          .onError(() => {
            this.imgErr = true;
          })
          .onClick(() => {
            this.openHero();
          })
      } else {
        // 无图占位：135° 渐变，**不写字**（小程序 .hero-placeholder 里是空的 view）
        Column()
          .width('100%')
          .height(HERO_H)
          .linearGradient({
            angle: 135,
            colors: [
              [HERO_FROM, 0.0],
              [HERO_TO, 1.0]
            ]
          })
      }

      // 底部渐隐：to bottom → angle 180；纯装饰，必须让事件穿透
      Column()
        .width('100%')
        .height(100)
        .align(Alignment.BottomStart)
        .linearGradient({
          angle: 180,
          colors: [
            ['#000A0E17', 0.0],
            ['#FF0A0E17', 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      // 轮播指示点：5vp，当前那张拉成 13vp 短胶囊（launch-hero.vue 的 .hero-dot）
      if (this.photos.length > 1) {
        Row() {
          ForEach(this.photos, (p: LdPhoto, i: number) => {
            Row()
              .width(this.heroIdx === i ? 13 : 5)
              .height(5)
              .borderRadius(3)
              .backgroundColor(this.heroIdx === i ? '#F2FFFFFF' : '#61FFFFFF')
              .margin({ right: 5 })
          }, (p: LdPhoto, i: number) => 'dot' + String(i))
        }
        .align(Alignment.TopEnd)
        .margin({ top: NAV_H + 10, right: 16 })
      }

      // 图片库入口：磨砂胶囊「2×2 点阵 + 图片库 + N」
      // 鸿蒙侧没有 media 页，点了进视频库（见文件头取舍 5）
      if (this.photos.length > 0) {
        Row() {
          Column() {
            Row() {
              Row().width(3).height(3).borderRadius(1.5).backgroundColor('#E6FFFFFF').margin({ right: 2 })
              Row().width(3).height(3).borderRadius(1.5).backgroundColor('#E6FFFFFF')
            }
            Row() {
              Row().width(3).height(3).borderRadius(1.5).backgroundColor('#E6FFFFFF').margin({ right: 2 })
              Row().width(3).height(3).borderRadius(1.5).backgroundColor('#E6FFFFFF')
            }
            .margin({ top: 2 })
          }
          .width(8)
          .height(8)
          .margin({ right: 5 })

          Text('图片库')
            .fontSize(11)
            .fontColor('#EBFFFFFF')

          Text(String(this.photos.length))
            .fontSize(11)
            .fontColor('#99FFFFFF')
            .margin({ left: 4 })
        }
        .align(Alignment.BottomEnd)
        .padding({ left: 9, right: 9, top: 3.5, bottom: 3.5 })
        .borderRadius(999)
        .backgroundColor('#24FFFFFF')
        .border({ width: 1, color: '#38FFFFFF' })
        // 磨砂：blur 20rpx = 10vp（半透明底 + 背景模糊，压在任何亮度的图上都能读）
        .backdropBlur(10)
        .margin({ right: 12, bottom: 40 })
        .onClick(() => {
          this.goMedia();
        })
      }
    }
    .width('100%')
    .height(HERO_H)
    .clip(true)
  }

  // ============ UI：标题行 ============

  @Builder
  headBlock() {
    Row() {
      Text(this.titleText())
        .fontSize(20)
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
        .lineHeight(28)
        .layoutWeight(1)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(this.statusText())
        .fontSize(12)
        .fontWeight(600)
        .fontColor(this.badgeColor())
        .backgroundColor(this.badgeBg())
        .padding({ left: 9, right: 9, top: 3, bottom: 3 })
        .borderRadius(4)
        .margin({ left: 10, top: 4 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  // ============ UI：通用卡标题 / 标签 ============

  /**
   * 卡标题。**不设 width('100%')**：它经常和 Blank() 同处一个 Row
   * （右侧挂「展开全部」「N 篇」这类小字），标题占满整行会把右边挤掉。
   * 卡片是 alignItems(Start) 的 Column，Text 自然左对齐。
   */
  @Builder
  cardTitle(text: string) {
    Text(text)
      .fontSize(15)
      .fontWeight(600)
      // 小程序 .card-title 是青色 #38bdf8（30rpx w600），不是白字
      .fontColor(ACCENT)
      // margin-bottom 20rpx = 10vp；这里取 6，因为各块自己还带 4~6vp 的 margin-top
      .margin({ bottom: 6 })
  }

  /** 小胶囊（轨道 / 可复用 / 几级这类标签） */
  @Builder
  chipTag(text: string, accent: boolean) {
    Text(text)
      .fontSize(11.5)
      .fontColor(accent ? ACCENT : '#7DD3FC')
      .backgroundColor(accent ? '#2E38BDF8' : '#1A38BDF8')
      .borderRadius(4)
      .padding({ left: 9, right: 9, top: 3, bottom: 3 })
      .margin({ right: 6, bottom: 6 })
  }

  // ============ UI：倒计时 ============

  /**
   * 倒计时。
   *
   * 小程序这张卡里**只有一行 Countdown**（launch-content.vue:14-16）：
   * 没有「距离发射」标题、也没有「北京时间」角标 —— 两者都删掉。
   */
  @Builder
  countdownCard() {
    Column() {
      // 自定义组件不能用 .margin()，外面套一层 Row 再给边距（各 SDK 版本差异最小的写法）
      Row() {
        Countdown({ net: this.item.net, sizeMode: 'lg' })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: 13 })
  }

  // ============ UI：发射周期 ============

  /**
   * 发射周期（对位 launch-content.vue:18-35）。
   *
   * 行结构：左 5vp 圆点 + 名称 + 右侧相对时间。折叠态只给接下来 4 步，
   * 右上角「展开全部 N 步 / 收起」切换；**没有「共 N 条」尾注**。
   */
  @Builder
  timelineCard() {
    Column() {
      Row() {
        Text('发射周期')
          .fontSize(15)
          .fontWeight(600)
          .fontColor('#E2E8F0')

        Blank()

        if (this.tlOpen) {
          Text('收起')
            .fontSize(12)
            .fontColor(ACCENT)
            .padding({ left: 6, top: 4, bottom: 4 })
            .onClick(() => {
              this.tlOpen = false;
            })
        } else if (this.tlMoreCount() > 0) {
          Text('展开全部 ' + String(this.tlTotal) + ' 步')
            .fontSize(12)
            .fontColor(ACCENT)
            .padding({ left: 6, top: 4, bottom: 4 })
            .onClick(() => {
              this.tlOpen = true;
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      ForEach(this.tlDisplay(), (row: LdTimelineRow, idx: number) => {
        Row() {
          // 圆点：5vp（10rpx），已发生的压成 #3B4658
          Column() {
            Column()
              .width(5)
              .height(5)
              .borderRadius(2.5)
              .backgroundColor(row.past ? '#3B4658' : ACCENT)
          }
          .width(9)
          .height(5)
          .justifyContent(FlexAlign.Start)

          Text(row.name)
            .fontSize(13.5)
            .fontColor(row.past ? '#5A6478' : TEXT_SUB)
            .lineHeight(18)
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 9 })

          Text(row.tag)
            .fontSize(12)
            .fontColor(row.past ? '#5A6478' : '#7D8BA0')
            .lineHeight(18)
            .margin({ left: 8 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 5.5, bottom: 5.5 })
      }, (row: LdTimelineRow, idx: number) => 'tl' + String(idx) + row.tag + row.name)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 13, bottom: 6 })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: 12 })
  }

  // ============ UI：分享 / 收藏 / 提醒 ============

  /**
   * 三枚胶囊（对位 launch-content.vue:44-57 的 .meta-acts）。
   *
   * 三者都必须读 this.faved / this.remindOn 这类状态，且**不通过 @Builder 传参**取文本 ——
   * @Builder 按值传参不建立响应式依赖，收藏后「收藏 → 已收藏」会不刷新。
   *
   * 两处鸿蒙差异（注释在此，报告里也写一遍）：
   *   · 分享：小程序是 <button open-type="share"> 走微信转发；鸿蒙没有系统分享面板，
   *     改成 toast 提示（不假装能分享，也不静默无反应）。
   *   · 提醒：数据层没有提醒队列（没有定时任务，也不该由一个页面私发通知），
   *     点了一律 toast「提醒功能开发中」，不做「已提醒」这种假状态。
   */
  @Builder
  metaActs() {
    Row() {
      // 分享：⤴ + 分享（.share-btn，灰字、白 6% 底）
      Row() {
        Text('⤴')
          .fontSize(13)
          .fontColor(TEXT_DIM)
        Text('分享')
          .fontSize(12)
          .fontColor(TEXT_DIM)
          .margin({ left: 4 })
      }
      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
      .borderRadius(20)
      .backgroundColor('#0FFFFFFF')
      .border({ width: 1, color: '#14FFFFFF' })
      .margin({ left: 10 })
      .onClick(() => {
        this.toast('鸿蒙版暂不支持系统分享');
      })

      // 收藏：★/☆ + 收藏/已收藏（.fav；on = 琥珀底 + 琥珀字，与顶栏星标共用 faved）
      Row() {
        Text(this.faved ? '★' : '☆')
          .fontSize(13)
          .fontColor(this.faved ? STAR : TEXT_DIM)
        Text(this.faved ? '已收藏' : '收藏')
          .fontSize(12)
          .fontColor(this.faved ? STAR : TEXT_DIM)
          .margin({ left: 4 })
      }
      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
      .borderRadius(20)
      .backgroundColor(this.faved ? '#24F5C33B' : '#0FFFFFFF')
      .border({ width: 1, color: this.faved ? '#59F5C33B' : '#14FFFFFF' })
      .margin({ left: 10 })
      .onClick(() => {
        this.onTapFid();
      })

      // 提醒：纯 CSS 钟形（上圆角矩形 + 底部横线），不用 emoji。
      // 基线 .remind 本身就是蓝底蓝线（rgba(56,189,248,.1) / .28），不是灰胶囊
      Row() {
        Column() {
          Column()
            .width(10)
            .height(9.5)
            .border({ width: { left: 1, right: 1, top: 1 }, color: ACCENT })
            .borderRadius({ topLeft: 5, topRight: 5 })
          Column()
            .width(13)
            .height(1)
            .borderRadius(1)
            .backgroundColor(ACCENT)
        }
        .width(13)
        .height(11)
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.End)

        Text(this.remindOn ? '已提醒' : '提醒')
          .fontSize(12)
          .fontColor(ACCENT)
          .margin({ left: 4 })
      }
      .padding({ left: 5, right: 5, top: 2, bottom: 2 })
      .borderRadius(20)
      .backgroundColor(this.remindOn ? '#3338BDF8' : '#1A38BDF8')
      .border({ width: 1, color: this.remindOn ? '#8038BDF8' : '#4738BDF8' })
      .margin({ left: 10 })
      .onClick(() => {
        this.onTapRemind();
      })
    }
    .alignItems(VerticalAlign.Center)
  }

  /** 收藏胶囊的点击入口（与 onTapFav 同一个实现，单独一层是为了注释能写在这里） */
  private onTapFid(): void {
    this.onTapFav();
  }

  // ============ UI：发射时刻 ============

  /**
   * 发射时刻卡（对位 launch-content.vue:37-64）。
   *
   * 大字是**钟点**（76rpx → 38vp w700、letter-spacing 2rpx → 1vp），
   * 下面一行拆成「日期 13vp #a0aec0 + 相对时间 12vp #38bdf8」——
   * 小程序里日期与相对时间是同一行的两个 text，不是一行「M月D日 HH:mm」。
   * 顶行左侧「发射时间 + 北京时间」，右侧三胶囊。
   */
  @Builder
  whenCard() {
    Column() {
      Row() {
        Text('发射时间')
          .fontSize(13)
          .fontColor(TEXT_SUB)
        Text('北京时间')
          .fontSize(11)
          .fontColor(TEXT_DIM)
          .margin({ left: 6 })

        Blank()

        this.metaActs()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(clock(this.item.net).length > 0 ? clock(this.item.net) : '待定')
        .fontSize(38)
        .fontWeight(700)
        .fontColor(TEXT_MAIN)
        .lineHeight(43)
        .letterSpacing(1)
        .margin({ top: 2 })

      Row() {
        Text(longDate(this.item.net).length > 0 ? longDate(this.item.net) : '时间待定')
          .fontSize(13)
          .fontColor('#A0AEC0')

        if (relativeTime(this.item.net).length > 0) {
          Text(relativeTime(this.item.net))
            .fontSize(12)
            .fontColor(ACCENT)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 15, right: 15, top: 13, bottom: 12 })
    .borderRadius(CARD_RADIUS)
    .linearGradient({
      angle: 135,
      colors: [
        ['#17243A', 0.0],
        ['#141A26', 1.0]
      ]
    })
    .border({ width: 1, color: '#1F38BDF8' })
    .margin({ top: 10 })
  }

  // ============ UI：计划发射窗口 ============

  /**
   * 计划发射窗口（对位 launch-content.vue:68-88）。
   *
   * 结构是「标题 + 轴（两节点一连线）+ 两端时刻」：
   *   节点 6vp、连线 1vp rgba(56,189,248,.45)、两端时刻 17vp w600。
   * 原来只有一条 Divider + 两列小字，读不出「这是一段窗口」。
   */
  @Builder
  winCard() {
    Column() {
      Row() {
        Text('计划发射窗口')
          .fontSize(13)
          .fontColor(TEXT_SUB)

        Blank()

        if (this.windowSpan().length > 0) {
          Text(this.windowSpan())
            .fontSize(11)
            .fontColor(TEXT_DIM)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 轴：节点 6vp + 连线 1vp
      Row() {
        Column()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(ACCENT)

        Column()
          .layoutWeight(1)
          .height(1)
          .backgroundColor('#7338BDF8')
          .margin({ left: 3, right: 3 })

        Column()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor(ACCENT)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 11 })

      Row() {
        Column() {
          Text(clock(this.winStart()).length > 0 ? clock(this.winStart()) : '--:--')
            .fontSize(17)
            .fontWeight(600)
            .fontColor('#E2E8F0')
            .lineHeight(20)
          Text('开始')
            .fontSize(11)
            .fontColor(TEXT_DIM)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        Column() {
          Text(clock(this.winEnd()).length > 0 ? clock(this.winEnd()) : '--:--')
            .fontSize(17)
            .fontWeight(600)
            .fontColor('#E2E8F0')
            .lineHeight(20)
          Text('结束')
            .fontSize(11)
            .fontColor(TEXT_DIM)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 5 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 15, right: 15, top: 12, bottom: 11 })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: 10 })
  }

  // ============ UI：任务详情 ============

  /**
   * 任务详情卡（对位 launch-content.vue:91-117）。
   *
   * 本轮补上「任务名 / 任务类型」两条 label-value 行（宽 85vp、14vp），
   * 类型不再只以 chip 形式出现；轨道仍用 chip（缩写 + 全称并排更好扫）。
   * 描述 29rpx → 14.5vp、lh1.75、#cbd5e0，超过 120 字折叠 4 行 + 展开全文。
   */
  @Builder
  missionCard() {
    Column() {
      this.cardTitle('任务详情')

      if (this.missionName().length > 0) {
        Row() {
          Text('任务名')
            .fontSize(14)
            .fontColor(TEXT_DIM)
            .width(85)
          Text(this.missionName())
            .fontSize(14)
            .fontColor('#E2E8F0')
            .lineHeight(21)
            .textAlign(TextAlign.End)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ top: 7, bottom: 7 })
        .border({ width: { top: 0.5 }, color: '#0AFFFFFF' })
        .margin({ top: 6 })
      }

      if (this.missionType().length > 0) {
        Row() {
          Text('任务类型')
            .fontSize(14)
            .fontColor(TEXT_DIM)
            .width(85)
          Text(this.missionType())
            .fontSize(14)
            .fontColor('#E2E8F0')
            .lineHeight(21)
            .textAlign(TextAlign.End)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ top: 7, bottom: 7 })
        .border({ width: { top: 0.5 }, color: '#0AFFFFFF' })
      }

      if (this.orbitText().length > 0) {
        // 必须用 Flex 而不是 Row：Row 是线性布局、没有 flexWrap，
        // 轨道名 + 全称挤不下时会被压缩变形而不是折行。
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          this.chipTag(this.orbitText(), true)
        }
        .width('100%')
        .margin({ top: 8 })
      }

      if (this.missionDesc().length > 0) {
        Text(this.missionDesc())
          .fontSize(14.5)
          .fontColor(TEXT_SUB)
          .lineHeight(25)
          .width('100%')
          .maxLines(this.descLines())
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 10 })

        if (this.canExpandDesc()) {
          Row() {
            Text(this.descExpanded ? '收起' : '展开全文')
              .fontSize(13)
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
   * 任务信息图是竖版长图（小程序 mode="widthFix"，即宽度撑满、高度按原图比例）。
   * Image 不设 height 时 ArkUI 就按 intrinsic 比例自适应，所以这里只给 width。
   * 圆角按任务书取 6vp（小程序 .infographic 是 12rpx）。
   */
  @Builder
  infoCard() {
    Column() {
      this.cardTitle('任务信息图')

      Column() {
        Image(this.infoSrc())
          .width('100%')
          .objectFit(ImageFit.Contain)
          .borderRadius(6)
          .backgroundColor('#0F1520')
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

  // ============ UI：火箭介绍 ============

  /**
   * 火箭卡（对位 launch-content.vue:131-186）。
   *
   * 相对上一版补齐了：90×90 缩略图、16vp w600 型号名、英文副标题、
   * 现役/已退役胶囊、可复用/N 级胶囊、**六格参数**（起飞推力 / 长度 / 直径 /
   * 级数 / LEO / GTO）、发射机构行（logo + 国旗 + 名称 + ›）。
   * 可点区域收在标题行与缩略图这一块（整卡可点会和机构行打架，见文件头取舍 8）。
   */
  @Builder
  rocketCard() {
    Column() {
      Row() {
        Text('火箭介绍')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(TEXT_MAIN)
        Blank()
        Text('›')
          .fontSize(17)
          .fontColor('#4A5568')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.goRocket();
      })

      Row() {
        if (this.rocketImage().length > 0 && !this.rocketImgErr) {
          Image(this.rocketImage())
            .width(90)
            .height(90)
            .objectFit(ImageFit.Cover)
            .backgroundColor(MEDIA_BG)
            .borderRadius(7)
            .onError(() => {
              this.rocketImgErr = true;
            })
        }

        Column() {
          Row() {
            Text(this.rocketName())
              .fontSize(16)
              .fontWeight(600)
              .fontColor(TEXT_MAIN)
              .lineHeight(22)
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (this.rocketActiveKnown()) {
              Text(this.rocketActive() ? '现役' : '已退役')
                .fontSize(10)
                .fontColor(this.rocketActive() ? '#34C759' : '#7D8BA0')
                .backgroundColor(this.rocketActive() ? '#2434C759' : '#0FFFFFFF')
                .borderRadius(3)
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                .margin({ left: 6 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          // 英文副标题（中英不同才显示）
          if (this.rocketSub().length > 0) {
            Text(this.rocketSub())
              .fontSize(11)
              .fontColor(TEXT_DIM)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }

          // 可复用 / N 级
          if (this.rocketFlags().length > 0) {
            // chip 可能折行，用 Flex(wrap)；Row 没有 flexWrap
            Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
              ForEach(this.rocketFlags(), (flag: string) => {
                Text(flag)
                  .fontSize(10)
                  .fontColor('#8B98AD')
                  .backgroundColor('#12FFFFFF')
                  .borderRadius(3)
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .margin({ right: 5, top: 5 })
              }, (flag: string) => 'rf' + flag)
            }
            .width('100%')
            .margin({ top: 2 })
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
          .fontSize(13)
          .fontColor('#A9B6C8')
          .lineHeight(22)
          .width('100%')
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 9 })
      }

      // 六格参数：两列三行
      if (this.rocketSpecCells().length > 0) {
        Column() {
          ForEach(this.gridRows(this.rocketSpecCells()), (row: LdCellRow, idx: number) => {
            Row() {
              Column() {
                Text(row.left.v)
                  .fontSize(15)
                  .fontWeight(600)
                  .fontColor('#E2E8F0')
                  .lineHeight(19)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(row.left.k)
                  .fontSize(11)
                  .fontColor(TEXT_DIM)
                  .margin({ top: 1 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .padding({ top: 6 })

              if (row.hasRight) {
                Column() {
                  Text(row.right.v)
                    .fontSize(15)
                    .fontWeight(600)
                    .fontColor('#E2E8F0')
                    .lineHeight(19)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(row.right.k)
                    .fontSize(11)
                    .fontColor(TEXT_DIM)
                    .margin({ top: 1 })
                    .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .padding({ top: 6 })
              } else {
                // 奇数格：右侧补同权重的空位，否则左格会被拉成整行宽
                Blank().layoutWeight(1)
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (row: LdCellRow, idx: number) => 'rs' + String(idx))
        }
        .width('100%')
        .margin({ top: 8 })
        .padding({ top: 5 })
        .border({ width: { top: 0.5 }, color: '#0FFFFFFF' })
      }

      if (this.rocketMetaText().length > 0) {
        Text(this.rocketMetaText())
          .fontSize(11)
          .fontColor('#7D8BA0')
          .width('100%')
          .margin({ top: 8 })
      }

      // 发射机构：logo（异步补）+ 国旗 emoji + 中文名 + ›
      if (this.hasAgency()) {
        Row() {
          if (this.agencyLogoOf().length > 0) {
            Image(this.agencyLogoOf())
              .width(20)
              .height(20)
              .objectFit(ImageFit.Contain)
              .borderRadius(3)
              .margin({ right: 7 })
          }

          if (this.agencyFlag().length > 0) {
            Text(this.agencyFlag())
              .fontSize(12)
              .margin({ right: 5 })
          }

          Text(this.agencyName())
            .fontSize(12.5)
            .fontColor(TEXT_SUB)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text('›')
            .fontSize(15)
            .fontColor('#4A5568')
            .margin({ left: 6 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 10 })
        .margin({ top: 10 })
        .border({ width: { top: 0.5 }, color: '#0FFFFFFF' })
        .onClick(() => {
          this.goAgency();
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  /** 机构 logo 的私有读取（@Builder 里直接读 this，保证异步补到后会刷新） */
  private agencyLogoOf(): string {
    return this.agencyLogo;
  }

  // ============ UI：航天器 ============

  /**
   * 航天器卡（对位 launch-content.vue:188-229）。
   *
   * 整块是本轮新补的：数据来自 timelines 记录的 craft 字段，没有就整卡不显示。
   * 排版直接复用火箭卡的 head + 六格，两张卡视觉保持一致。
   */
  @Builder
  craftCard() {
    Column() {
      this.cardTitle('航天器')

      Row() {
        if (this.craftImage().length > 0 && !this.craftImgErr) {
          Image(this.craftImage())
            .width(90)
            .height(90)
            .objectFit(ImageFit.Cover)
            .backgroundColor(MEDIA_BG)
            .borderRadius(7)
            .onError(() => {
              this.craftImgErr = true;
            })
            .onClick(() => {
              Nav.pushPhoto(new PhotoNavParam(this.craftImage(), this.craftTitle()));
            })
        }

        Column() {
          Row() {
            Text(this.craftTitle())
              .fontSize(16)
              .fontWeight(600)
              .fontColor(TEXT_MAIN)
              .lineHeight(22)
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            if (this.craftStatusText().length > 0) {
              Text(this.craftStatusText())
                .fontSize(10)
                .fontColor(this.craftLive() ? '#34C759' : '#7D8BA0')
                .backgroundColor(this.craftLive() ? '#2434C759' : '#0FFFFFFF')
                .borderRadius(3)
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                .margin({ left: 6 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)

          if (this.craftSub().length > 0) {
            Text(this.craftSub())
              .fontSize(11)
              .fontColor(TEXT_DIM)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }

          if (this.craftDest().length > 0) {
            Row() {
              Text('目的地 · ' + this.craftDest())
                .fontSize(10)
                .fontColor('#8B98AD')
                .backgroundColor('#12FFFFFF')
                .borderRadius(3)
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
            }
            .margin({ top: 5 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: this.craftImage().length > 0 && !this.craftImgErr ? 10 : 0 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .margin({ top: 10 })

      if (this.craftDesc().length > 0) {
        Text(this.craftDesc())
          .fontSize(13)
          .fontColor('#A9B6C8')
          .lineHeight(22)
          .width('100%')
          .maxLines(4)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 9 })
      }

      if (this.craftSpecCells().length > 0) {
        Column() {
          ForEach(this.gridRows(this.craftSpecCells()), (row: LdCellRow, idx: number) => {
            Row() {
              Column() {
                Text(row.left.v)
                  .fontSize(15)
                  .fontWeight(600)
                  .fontColor('#E2E8F0')
                  .lineHeight(19)
                  .maxLines(1)
                  .width('100%')
                Text(row.left.k)
                  .fontSize(11)
                  .fontColor(TEXT_DIM)
                  .margin({ top: 1 })
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .padding({ top: 6 })

              if (row.hasRight) {
                Column() {
                  Text(row.right.v)
                    .fontSize(15)
                    .fontWeight(600)
                    .fontColor('#E2E8F0')
                    .lineHeight(19)
                    .maxLines(1)
                    .width('100%')
                  Text(row.right.k)
                    .fontSize(11)
                    .fontColor(TEXT_DIM)
                    .margin({ top: 1 })
                    .width('100%')
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .padding({ top: 6 })
              } else {
                Blank().layoutWeight(1)
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }, (row: LdCellRow, idx: number) => 'cs' + String(idx))
        }
        .width('100%')
        .margin({ top: 8 })
        .padding({ top: 5 })
        .border({ width: { top: 0.5 }, color: '#0FFFFFFF' })
      }

      if (this.craftMetaText().length > 0) {
        Text(this.craftMetaText())
          .fontSize(11)
          .fontColor('#7D8BA0')
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

  // ============ UI：发射条件 / 失败原因 ============

  @Builder
  conditionCard() {
    Column() {
      this.cardTitle('发射条件')

      if (this.probabilityText().length > 0) {
        Row() {
          Text('预报概率')
            .fontSize(14)
            .fontColor(TEXT_DIM)
            .width(85)
          Text(this.probabilityText())
            .fontSize(14)
            .fontColor('#E2E8F0')
            .textAlign(TextAlign.End)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 7, bottom: 7 })
        .border({ width: { top: 0.5 }, color: '#0AFFFFFF' })
        .margin({ top: 6 })
      }

      if (this.weatherText().length > 0) {
        Text(this.weatherText())
          .fontSize(14.5)
          .fontColor(TEXT_SUB)
          .lineHeight(25)
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
        .fontSize(14.5)
        .fontColor(TEXT_SUB)
        .lineHeight(25)
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

  /**
   * 发射场地（对位 launch-content.vue:248-274）。
   *
   * 卫星图改成**原比例**（小程序 mode="widthFix"）：原来固定 150vp Cover 会把
   * 一张扁长的场区图裁得只剩中间一条。半径 6、底 #0f1621。
   * 另外补上「该工位累计 / N 次发射」一行，经纬度改成 label 85 + 值右对齐。
   */
  @Builder
  padCard() {
    Column() {
      this.cardTitle('发射场地')

      if (this.padMap().length > 0 && !this.mapErr) {
        Image(this.padMap())
          .width('100%')
          .objectFit(ImageFit.Contain)
          .backgroundColor('#0F1621')
          .borderRadius(6)
          .margin({ top: 10 })
          .onError(() => {
            this.mapErr = true;
          })
          .onClick(() => {
            Nav.pushPhoto(new PhotoNavParam(this.padMap(), this.padName()));
          })
      }

      Row() {
        Column() {
          Text(this.padName())
            .fontSize(15)
            .fontWeight(500)
            .fontColor(TEXT_MAIN)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.padPlace().length > 0) {
            Text(this.padPlace())
              .fontSize(12)
              .fontColor(TEXT_SUB)
              .margin({ top: 2 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.padName().length > 0) {
          Text('›')
            .fontSize(17)
            .fontColor(ACCENT)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 10 })
      .onClick(() => {
        this.goPad();
      })

      if (this.padLaunchCount() > 0) {
        Row() {
          Text('该工位累计')
            .fontSize(14)
            .fontColor(TEXT_DIM)
            .width(85)
          Text(String(Math.round(this.padLaunchCount())) + ' 次发射')
            .fontSize(14)
            .fontColor('#E2E8F0')
            .textAlign(TextAlign.End)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 7, bottom: 7 })
        .border({ width: { top: 0.5 }, color: '#0AFFFFFF' })
        .margin({ top: 6 })
      }

      if (this.padCoord().length > 0) {
        Row() {
          Text('经纬度')
            .fontSize(14)
            .fontColor(TEXT_DIM)
            .width(85)
          Text(this.padCoord())
            .fontSize(14)
            .fontColor('#E2E8F0')
            .textAlign(TextAlign.End)
            .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 7, bottom: 7 })
        .border({ width: { top: 0.5 }, color: '#0AFFFFFF' })
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

  /** 统计概览：值 20vp w600 + 标签 11vp，**每格居中**（小程序 .stat-cell align-items:center） */
  @Builder
  statCard() {
    Column() {
      this.cardTitle('统计概览')

      Column() {
        ForEach(this.gridRows(this.countCells()), (row: LdCellRow, idx: number) => {
          Row() {
            Column() {
              Text(row.left.v)
                .fontSize(20)
                .fontWeight(600)
                .fontColor('#E2E8F0')
                .lineHeight(24)
                .maxLines(1)
              Text(row.left.k)
                .fontSize(11)
                .fontColor(TEXT_DIM)
                .margin({ top: 3 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Center)
            .padding({ top: 9, bottom: 9 })

            if (row.hasRight) {
              Column() {
                Text(row.right.v)
                  .fontSize(20)
                  .fontWeight(600)
                  .fontColor('#E2E8F0')
                  .lineHeight(24)
                  .maxLines(1)
                Text(row.right.k)
                  .fontSize(11)
                  .fontColor(TEXT_DIM)
                  .margin({ top: 3 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Center)
              .padding({ top: 9, bottom: 9 })
            } else {
              // 奇数格：右侧补空位，避免左格被拉成整行宽（三格时会很明显）
              Blank().layoutWeight(1)
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (row: LdCellRow, idx: number) => 'st' + String(idx))
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

  /**
   * 相关报道（对位 launch-content.vue:290-308）。
   *
   * 行可点 → Nav.pushArticle（见 openArticle 的注释）；
   * 标题 14vp #dfe7f0 lh1.5（原来是 13vp 纯白），右侧一个 › 提示可点。
   */
  @Builder
  newsCard() {
    Column() {
      Row() {
        this.cardTitle('相关报道')
        Blank()
        Text(String(this.news.length) + ' 篇')
          .fontSize(11)
          .fontColor(TEXT_DIM)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      ForEach(this.news, (n: NewsItem, idx: number) => {
        Row() {
          Column() {
            Text(ldNewsTitle(n))
              .fontSize(14)
              .fontColor('#DFE7F0')
              .lineHeight(21)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(ldNewsMeta(n))
              .fontSize(11)
              .fontColor(TEXT_DIM)
              .maxLines(1)
              .margin({ top: 4 })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Text('›')
            .fontSize(17)
            .fontColor('#4A5568')
            .margin({ left: 8 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 7, bottom: 7 })
        .onClick(() => {
          this.openArticle(n);
        })
      }, (n: NewsItem) => 'news' + String(n.id))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  /** 页脚数据来源（launch-detail.vue 的 .footer-hint） */
  @Builder
  footerHint() {
    Text('数据来源 The Space Devs · 中文翻译由同步任务生成')
      .fontSize(11)
      .fontColor(TEXT_FAINT)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ top: 20 })
  }

  // ============ UI：加载中 / 未找到 ============

  /**
   * 加载态：文案是 `加载中...`（英文三点，对位 launch-detail.vue 的 .loading-text），
   * 15vp #6b7891、整块上下 120vp（240rpx）留白。
   */
  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ACCENT)
      Text('加载中...')
        .fontSize(15)
        .fontColor(TEXT_DIM)
        .margin({ top: 12 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 30, right: 30, top: 120 })
  }

  /**
   * 空态：🛰️ 40vp + `未找到该发射任务` 15vp + 返回胶囊。
   * 胶囊 padding 10/30、radius 30、底 rgba(56,189,248,.15)、描边 rgba(56,189,248,.4)。
   * 小程序的空态只有一个「返回」，没有「重试」——这里对齐。
   */
  @Builder
  notFoundBlock() {
    Column() {
      Text('🛰️')
        .fontSize(40)
        .margin({ bottom: 15 })

      Text('未找到该发射任务')
        .fontSize(15)
        .fontColor(TEXT_DIM)

      if (this.idText().length > 0) {
        Text(this.idText())
          .fontSize(11)
          .fontColor(TEXT_FAINT)
          .maxLines(2)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }

      Row() {
        Text('返回')
          .fontSize(15)
          .fontColor(ACCENT)
      }
      .padding({ left: 30, right: 30, top: 10, bottom: 10 })
      .borderRadius(30)
      .backgroundColor('#2638BDF8')
      .border({ width: 1, color: '#6638BDF8' })
      .margin({ top: 25 })
      .onClick(() => {
        Nav.pop();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 30, right: 30, top: 120 })
  }

  // ============ UI：全屏看图器（launch-photo.vue 的对位实现） ============

  /**
   * 全屏看图器。
   *
   * 对位小程序 components/launch-detail/launch-photo.vue：
   *   · 底色 #04060a，铺满整屏，压在页面之上；
   *   · 图片层用 Swiper 实现**左滑切换**（小程序是手写 touch 手势 + translateX，
   *     ArkUI 的 Swiper 就是同一件事的官方实现，且在首尾会自动停住，
   *     不需要再写 0.28 阻尼那套）；
   *   · 底部一条渐隐栏：左标题 + 副行（型号 · 时间 · @credit），
   *     右侧「cur+1 / N」计数 + 「查看发射详情 ›」胶囊；
   *   · 图片一律 2000px 原图（fullImageOf 推导，推导失败退回缩略图）。
   *
   * 有意差异：小程序的「查看发射详情」是切到本条发射的详情视图；
   * 本页本身就是详情页，所以这个按钮的语义变成「收起看图器，回到详情」。
   */
  @Builder
  photoViewer() {
    Stack({ alignContent: Alignment.Bottom }) {
      Swiper() {
        ForEach(this.photos, (p: LdPhoto, i: number) => {
          Image(p.full)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
        }, (p: LdPhoto, i: number) => 'view' + p.full + String(i))
      }
      .width('100%')
      .height('100%')
      .index(this.viewerIdx)
      .loop(false)
      .indicator(false)
      .duration(260)
      .onChange((idx: number) => {
        this.viewerIdx = idx;
      })

      // 底部信息栏
      Column() {
        Row() {
          Column() {
            Text(this.viewerTitle())
              .fontSize(16)
              .fontWeight(600)
              .fontColor('#EEF3FA')
              .lineHeight(22)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            if (this.viewerMeta().length > 0) {
              Text(this.viewerMeta())
                .fontSize(11.5)
                .fontColor('#B8D6E2F0')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 4 })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Column() {
            if (this.photos.length > 1) {
              Text(String(this.viewerIdx + 1) + ' / ' + String(this.photos.length))
                .fontSize(10.5)
                .fontColor('#9EFFFFFF')
                .margin({ bottom: 6 })
            }

            Row() {
              Text('查看发射详情')
                .fontSize(12.5)
                .fontWeight(600)
                .fontColor('#7DD3FC')
              Text('›')
                .fontSize(15)
                .fontColor('#7DD3FC')
                .margin({ left: 2 })
            }
            .padding({ left: 15, right: 15, top: 7, bottom: 7 })
            .borderRadius(999)
            .backgroundColor('#2938BDF8')
            .border({ width: 1, color: '#7338BDF8' })
            .onClick(() => {
              this.viewerOn = false;
            })
          }
          .alignItems(HorizontalAlign.End)
          .margin({ left: 12 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }
      .width('100%')
      .padding({ left: 22, right: 22, top: 20, bottom: 28 })
      .linearGradient({
        angle: 180,
        colors: [
          ['#0004060A', 0.0],
          ['#D104060A', 1.0]
        ]
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(OVERLAY_BG)
  }

  // ============ build ============

  /**
   * 整页结构：Stack[内容层, 固定顶栏, 看图器]。
   *
   * 顶栏与看图器必须是 Stack 的兄弟层：顶栏要 fixed 压在首图上（不占文档流，
   * 否则首图会被顶下去 44vp，沉浸感没了）；看图器要盖住包括顶栏在内的一切。
   */
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---- 内容层 ----
      Column() {
        if (this.loading && !this.found) {
          this.loadingBlock()
        } else if (!this.found) {
          this.notFoundBlock()
        } else {
          Scroll(this.scroller) {
            Column() {
              this.heroBlock()

              Column() {
                this.headBlock()

                if (this.isUpcoming()) {
                  this.countdownCard()
                }
                // 发射周期紧跟倒计时：发射前它是这页最有用的一块
                if (this.tlRows.length > 0) {
                  this.timelineCard()
                }
                this.whenCard()
                if (this.hasWindow()) {
                  this.winCard()
                }
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
                if (this.craftTitle().length > 0) {
                  this.craftCard()
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
                this.footerHint()
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: PAGE_PAD, right: PAGE_PAD })
              // 正文上提 20vp，压住首图底部的渐隐带（.body margin-top -40rpx）
              .margin({ top: BODY_LIFT })
            }
            .width('100%')
            .padding({ bottom: BOTTOM_PAD })
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          // 滚动驱动顶栏变实色。这里读 scroller 的绝对偏移，不用回调参数
          // （Scroll 的回调在「2 参 xOffset/yOffset」与「3 参 + scrollState」两套签名之间有过变动，
          //   零参 lambda 对两者都可赋值，彻底绕开版本差异）
          .onDidScroll(() => {
            this.syncNavSolid();
          })
        }
      }
      .width('100%')
      .height('100%')

      // ---- 固定顶栏（压在首图上，不占文档流） ----
      this.navBar()

      // ---- 全屏看图器（最后画 = 最上层） ----
      if (this.viewerOn) {
        this.photoViewer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }
}
