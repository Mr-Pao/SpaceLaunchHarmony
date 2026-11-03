/**
 * 全局搜索页 —— 严格按小程序 `pages/search/search.vue` 1:1 对齐。
 *
 * 本次对齐（2026-11-03）修掉的 16 条差异：
 *   1. 删掉整条 topBar（小程序根本没有标题栏，只有搜索行里一个 `‹`）；
 *   2. 只留一个返回热区 32vp（原先 topBar 与搜索行各有一个返回，重复）；
 *   3. 输入框改用 wxss 精确值：高 36vp、圆角 18vp、padding 0 10vp、
 *      字号 14vp、占位色 #4a5568、🔍 13vp 且 opacity .6；
 *   4. 恢复 400ms 防抖（对应小程序 `watch keyword` + setTimeout(400)）；
 *   5. 分组顺序改回 即将发射 → 已发射 → 火箭 → 宇航员 → 工位 → 机构；
 *   6. 删掉「资讯」组（小程序没有）；
 *   7. 组头拆成两段：标题 13vp #8a97a8 + 计数 11vp #4a5568 margin-left 6；
 *      非宇航员 / 工位组显示**截断后**的条数（≤8），与小程序 `total ?? items.length` 一致；
 *   8. 删掉「还有 N 条」组尾；
 *   9. 发射行副标题只剩 formatShort(net)，去掉「 · 场地」；
 *  10. 工位行副标题改成 `placeZh · agencyLabel`；
 *  11. 机构点击已按 id；火箭页路由只收 name（见 NavParam 注释），改传 full_name 优先；
 *  12. 空结果文案改成「没有找到「kw」相关内容」；
 *  13. 空态加可点的青色胶囊，跳太空资产页（小程序 goCatalogSearch）；
 *  14. 未输入提示改成「可以搜这些」+ 5 条带示例的长文案；
 *  15. 加载态去掉 spinner，只留 11.5vp 纯文字；
 *  16. 行圆角 8vp、徽标圆角 4vp / margin-left 6vp / padding 1 5vp（照 12rpx/8rpx/2rpx 10rpx ÷2）。
 * 第 17 条（onShareAppMessage / onShareTimeline）**跳过**：鸿蒙没有系统分享面板，
 * 且改分享要动 model 与全局分享封装，超出本文件作用域。
 *
 * 数据侧不做任何异步请求：六份 CI 预生成静态 JSON 全部内存过滤。
 * 防抖只是为了跟小程序的手感一致（中文输入法连打时不至于每键重排一次列表），
 * 不是为了省算力 —— 所以定时器只在 onChange 里起，数据落地时立即补跑一次。
 *
 * 字段口径（线上 v14 实测）：
 *   agencies.json   350 条：id / name / abbrev / type / country_code / founding_year
 *                   —— **没有 nameZh**（小程序里那个 hit(x.nameZh) 恒为假，这里保留同口径）
 *   pads.json       251 条：id / name / location{id,name} / agencies[{id,name}] /
 *                   total_launch_count / country_code / active
 *   astronautsSearch 862 条：id / name / nameZh / nation / agencyName / days / inSpace / img
 *   launchers.json  532 条：id(number) / name / full_name / variant / families / manufacturer
 *                   —— **没有 desc、没有 agencyName**
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { repo } from '../data/Repository';
import {
  LaunchSummary, LaunchMission, LaunchPad, LaunchRocket, RocketConfig, PadLocation, ListPayload
} from '../model/Common';
import { UpcomingPayload, PreviousPayload } from '../model/Launch';
import { Astronaut, AstronautCard, AstronautsPayload, AstronautsSearchPayload } from '../model/Astronaut';
import {
  strOf, missionLabelOf, formatShort, rocketName, astroName, launchTitle,
  nationZh, agencyLabel, placeZh, padShort
} from '../utils/Format';
import { Nav, ROUTE_ASSETS } from '../routes/Nav';
import { LaunchNavParam, RocketNavParam, AstronautNavParam, AgencyNavParam, PadNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'SearchView';

// ============ 视觉常量（全部取自 search.vue 的 scss，rpx ÷ 2 = vp） ============

const BG_PRIMARY: string = '#0A0E17';
/** 输入框 / 结果行底色 */
const CARD_BG: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
/** 组标题 #8a97a8 */
const GROUP_TITLE: string = '#8A97A8';
/** 占位符 / 组计数 / 行箭头 / 提示小标题，统一 #4a5568 */
const MUTED: string = '#4A5568';
/** 行副标题 / 空态正文 / 提示条目，统一 #6b7891 */
const MUTED_TEXT: string = '#6B7891';
/** 在轨徽标绿 */
const BADGE_ON: string = '#4ADE80';
const ACCENT: string = '#38BDF8';
/** rgba(255,255,255,0.08)：输入框描边 */
const BORDER_SOFT: string = '#14FFFFFF';
/** rgba(255,255,255,0.12)：徽标描边 */
const BORDER_BADGE: string = '#1FFFFFFF';
/** rgba(56,189,248,0.35) / rgba(56,189,248,0.08)：空态胶囊 */
const ACCENT_BORDER: string = '#5938BDF8';
const ACCENT_WASH: string = '#1438BDF8';
/** rgba(74,222,128,0.35)：在轨徽标描边 */
const BADGE_ON_BORDER: string = '#594ADE80';

/** 页面左右留白 = 小程序 .search-bar / .groups 的 24rpx */
const PAGE_PAD: number = 12;
/** 底部留白：NavDestination 二级页，胶囊已被摘掉，32 只够最后一行不贴边 */
const BOTTOM_PAD: number = 32;

/** 每组最多 8 条（小程序 GROUP_LIMIT = 8） */
const GROUP_LIMIT: number = 8;

/** 输入防抖 400ms（小程序 watch keyword 里的 setTimeout） */
const DEBOUNCE_MS: number = 400;

// 结果行类型（字符串常量而不是 enum：enum 跨文件要 import，这里只在页内用）
const KIND_LAUNCH: string = 'launch';
const KIND_ROCKET: string = 'rocket';
const KIND_AGENCY: string = 'agency';
const KIND_ASTRO: string = 'astronaut';
const KIND_PAD: string = 'pad';

// ============ 原始数据类型（只声明本页真正读到的字段） ============
//
// 为什么不用 model/*.ets 里现成的 interface：agencies / pads / launchers 三份数据
// 在鸿蒙侧没有对应 model，为搜索页临时扩 model 会牵动别处；按「本页读到哪几个键」
// 就地声明更安全。前缀 Se2 避开已有的 Se / St / Sa 等前缀。

interface Se2AgencyRaw {
  id: number;
  name?: string;
  abbrev?: string;
  type?: string;
  country_code?: string;
  /** 线上不存在，保留只为与小程序同口径（命中恒为空，不影响结果） */
  nameZh?: string;
}

interface Se2PadAgencyRef {
  id?: number;
  name?: string;
}

interface Se2PadRaw {
  id: number;
  name?: string;
  location?: PadLocation;
  agencies?: Se2PadAgencyRef[];
  total_launch_count?: number;
  country_code?: string;
  /** 线上不存在，同上 */
  nameZh?: string;
  countryZh?: string;
}

interface Se2RocketRaw {
  /** 注意是 number，不是 string */
  id: number;
  name?: string;
  full_name?: string;
  variant?: string;
  families?: string[];
  manufacturer?: string;
  descriptionZh?: string;
}

// ============ 页面内部状态类型 ============

/**
 * 一条结果行。
 *
 * 为什么不是「每种类型一个数组」：模板只写一套行式样，
 * 用 kind 分派点击行为即可；分类数组会让 build 里出现六段几乎相同的 ForEach。
 */
class Se2Row {
  key: string = '';
  kind: string = '';
  /** 主标题：任务名 / 火箭名 / 机构名 / 人名 / 工位名 */
  primary: string = '';
  sub: string = '';
  badge: string = '';
  badgeOn: boolean = false;
  /** 头像，只有宇航员有 */
  avatar: string = '';
  /** 发射行：整条摘要带过去，点击时不用再回查 */
  launch: LaunchSummary | null = null;
  /** 火箭行：路由只认 name，优先用 full_name（同型号不同构型才分得开） */
  rocketName: string = '';
  /** 宇航员行 */
  astroId: string = '';
  astroPerson: string = '';
  /** 机构行：LL2 agency id（number 的字符串形式） */
  agencyId: string = '';
  agencyName: string = '';
  /** 工位行：id + 名字 + 场地（PadNavParam 三参） */
  padId: string = '';
  padName: string = '';
  padPlace: string = '';
}

/**
 * 一个结果分组。
 *
 * `count` 就是组头要显示的**那个数字**：宇航员 / 工位给全量命中数，
 * 其余组给截断后的条数（≤8）—— 这正是小程序 `g.total != null ? g.total : g.items.length`
 * 的语义，放到构造期算清楚，模板里就不用再判空。
 */
class Se2Group {
  title: string = '';
  count: number = 0;
  rows: Se2Row[] = [];
  /**
   * ForEach 的 key。
   *
   * 不能直接用 title 当 key：搜「星」和搜「星链」时组标题一模一样，
   * ArkUI 的 ForEach 认为 key 没变就复用旧节点，组内行会停在上一轮的结果上
   * （表现为「改了关键词、组头数字变了、行还是旧的」）。
   * 所以每个组都带一个全局自增序号，保证每次 search 都是新 key。
   */
  token: string = '';
}

/** 组序号自增源：只用于 key，不参与渲染，模块级变量足够 */
let se2GroupSeq: number = 0;

/**
 * 六份数据的本页副本。
 *
 * 放普通 class 实例而不是 @State 数组：这些是「搜索的输入」，
 * 变化时不需要单独重绘，runSearch() 会把结果算进 @State groups 里。
 * 用 @State 反而会多触发一轮无意义的重绘。
 */
class Se2Store {
  up: LaunchSummary[] = [];
  prev: LaunchSummary[] = [];
  rockets: Se2RocketRaw[] = [];
  agencies: Se2AgencyRaw[] = [];
  astros: AstronautCard[] = [];
  pads: Se2PadRaw[] = [];
}

// ============ 匹配（纯函数） ============

/**
 * 单个字段是否命中。
 *
 * 关键词已经统一小写，字段在比较时再转 —— 数据量下这个转换成本可以忽略，
 * 而「先建小写索引表」会多占一倍内存、还得处理数据更新，不划算。
 */
function se2Hit(v: string | undefined | null, kw: string): boolean {
  const s: string = strOf(v);
  if (s.length === 0 || kw.length === 0) {
    return false;
  }
  return s.toLowerCase().indexOf(kw) !== -1;
}

/**
 * 发射任务：中文名、任务名、火箭名、工位、发射方都算命中面。
 *
 * 中英各判一次是必须的（原项目 P1-1）：`mission.name` 恒存在，
 * 写成 `name || nameZh` 再命中，中文名永远轮不到，「嫦娥」「星链」会整组落空。
 */
function se2LaunchMatch(x: LaunchSummary, kw: string): boolean {
  if (se2Hit(x.name, kw)) {
    return true;
  }
  const m: LaunchMission | undefined = x.mission;
  if (m !== undefined && m !== null) {
    if (se2Hit(m.name, kw) || se2Hit(m.nameZh, kw)) {
      return true;
    }
  }
  const rk: LaunchRocket | undefined = x.rocket;
  if (rk !== undefined && rk !== null) {
    const c: RocketConfig | undefined = rk.configuration;
    if (c !== undefined && c !== null) {
      if (se2Hit(c.name, kw) || se2Hit(c.full_name, kw) || se2Hit(rocketName(c), kw)) {
        return true;
      }
    }
  }
  const pad: LaunchPad | undefined = x.pad;
  if (pad !== undefined && pad !== null) {
    if (se2Hit(pad.name, kw)) {
      return true;
    }
    const loc: PadLocation | undefined = pad.location;
    if (loc !== undefined && loc !== null && se2Hit(loc.name, kw)) {
      return true;
    }
  }
  const p: string = strOf(x.launch_service_provider !== undefined &&
    x.launch_service_provider !== null ? x.launch_service_provider.name : '');
  if (se2Hit(p, kw)) {
    return true;
  }
  // 展示标题「猎鹰 9 号 | 星链 G7-12」是拼出来的，两半各自都已判过，
  // 但术语修正只体现在这一串里（如「星链」修正后的写法），所以整串再判一次。
  return se2Hit(launchTitle(x), kw);
}

/**
 * 火箭型号：原始名 + 完整名 + 构型 + 系列 + 制造商 + 中文名。
 *
 * variant / families 是 search-match.js 里 rocketMatch 的命中面之一，
 * 少了它们搜「Block 5」「Falcon」会漏 —— 线上 532 条里这两种写法很常见。
 */
function se2RocketMatch(x: Se2RocketRaw, kw: string): boolean {
  if (se2Hit(x.name, kw) || se2Hit(x.full_name, kw)) {
    return true;
  }
  if (se2Hit(x.variant, kw) || se2Hit(x.manufacturer, kw)) {
    return true;
  }
  const fams: string[] | undefined = x.families;
  if (fams !== undefined && fams !== null) {
    for (let i = 0; i < fams.length; i++) {
      if (se2Hit(fams[i], kw)) {
        return true;
      }
    }
  }
  return se2Hit(se2RocketLabel(x), kw);
}

/** 机构：name / abbrev / nameZh（后者线上为空，与小程序同口径） */
function se2AgencyMatch(x: Se2AgencyRaw, kw: string): boolean {
  return se2Hit(x.name, kw) || se2Hit(x.abbrev, kw) || se2Hit(x.nameZh, kw);
}

/**
 * 宇航员：中英文姓名、国籍、机构。
 *
 * astronautsSearch 是精简集但**带 nameZh**（实测 830/862 非空），
 * 所以优先用 nameZh；astroName() 是 CHINA_ASTRO_ZH 专名表兜底。
 */
function se2AstroMatch(x: AstronautCard, kw: string): boolean {
  if (se2Hit(x.name, kw) || se2Hit(x.nameZh, kw)) {
    return true;
  }
  if (se2Hit(astroName(strOf(x.name), strOf(x.nation)), kw)) {
    return true;
  }
  if (se2Hit(x.nation, kw) || se2Hit(nationZh(strOf(x.nation)), kw)) {
    return true;
  }
  return se2Hit(x.agencyName, kw) || se2Hit(agencyLabel(strOf(x.agencyName)), kw);
}

/**
 * 发射工位：名字 / 缩写 / 场地 / 国家 / 运营机构。
 *
 * pads 里**没有任何中文字段**，中文命中完全靠 Format.ets 的 PLACE_ZH / AGENCY_ZH；
 * 国家要单独判一次，否则搜「中国」只能碰到机构名里带中国的零星工位。
 */
function se2PadMatch(x: Se2PadRaw, kw: string): boolean {
  if (se2Hit(x.name, kw) || se2Hit(padShort(strOf(x.name)), kw)) {
    return true;
  }
  const loc: PadLocation | undefined = x.location;
  if (loc !== undefined && loc !== null) {
    const raw: string = strOf(loc.name);
    if (se2Hit(raw, kw) || se2Hit(placeZh(raw), kw)) {
      return true;
    }
    // location.name 是「场地, 州, 国」整串（"Cape Canaveral SFS, FL, USA"）。
    // 小程序用 countryOf() 取末段再查国名表，这里做同样的事：
    // 不这么判，搜「美国」「中国」只能碰到机构名里恰好带国名的零星工位。
    const segs: string[] = raw.split(',');
    if (segs.length > 1) {
      const last: string = segs[segs.length - 1].trim();
      if (se2Hit(last, kw) || se2Hit(placeZh(last), kw)) {
        return true;
      }
    }
  }
  const ags: Se2PadAgencyRef[] | undefined = x.agencies;
  if (ags !== undefined && ags !== null) {
    for (let i = 0; i < ags.length; i++) {
      const a: Se2PadAgencyRef = ags[i];
      if (se2Hit(a.name, kw) || se2Hit(agencyLabel(strOf(a.name)), kw)) {
        return true;
      }
    }
  }
  return se2Hit(x.country_code, kw) || se2Hit(x.countryZh, kw);
}

// ============ 行 / 组构造 ============

/** 火箭展示名：中文表 → 完整名 → 原名 */
function se2RocketLabel(x: Se2RocketRaw): string {
  const cfg: RocketConfig = {
    name: strOf(x.name),
    full_name: x.full_name,
    variant: x.variant,
    families: x.families
  };
  const zh: string = rocketName(cfg);
  if (zh.length > 0) {
    return zh;
  }
  const full: string = strOf(x.full_name);
  return full.length > 0 ? full : strOf(x.name);
}

/** 发射行：副标题只有时间（小程序 `sub: formatShort(x.net)`，没有场地） */
function se2LaunchRow(x: LaunchSummary): Se2Row {
  const r: Se2Row = new Se2Row();
  r.kind = KIND_LAUNCH;
  r.key = 'launch:' + strOf(x.id);
  r.primary = missionLabelOf(x);
  r.sub = formatShort(strOf(x.net));
  r.launch = x;
  return r;
}

function se2RocketRow(x: Se2RocketRaw): Se2Row {
  const r: Se2Row = new Se2Row();
  r.kind = KIND_ROCKET;
  r.key = 'rocket:' + String(x.id);
  r.primary = se2RocketLabel(x);
  // launchers 没有 agencyName，机构只有 manufacturer（原文长名，不做截断）
  r.sub = strOf(x.manufacturer);
  // 路由只收 name：full_name 更精确（同名不同构型靠它区分），空则退回 name
  const full: string = strOf(x.full_name);
  r.rocketName = full.length > 0 ? full : strOf(x.name);
  return r;
}

function se2AgencyRow(x: Se2AgencyRaw): Se2Row {
  const r: Se2Row = new Se2Row();
  r.kind = KIND_AGENCY;
  r.key = 'agency:' + String(x.id);
  r.primary = strOf(x.name);
  const abbrev: string = strOf(x.abbrev);
  const type: string = strOf(x.type);
  r.sub = abbrev.length > 0 ? abbrev : type;
  r.agencyId = String(x.id);
  r.agencyName = r.primary;
  return r;
}

function se2AstroRow(x: AstronautCard): Se2Row {
  const r: Se2Row = new Se2Row();
  r.kind = KIND_ASTRO;
  r.key = 'astro:' + String(x.id);
  const zh: string = strOf(x.nameZh);
  r.primary = zh.length > 0 ? zh : astroName(strOf(x.name), strOf(x.nation));
  if (r.primary.length === 0) {
    r.primary = strOf(x.name);
  }
  const nation: string = nationZh(strOf(x.nation));
  const agency: string = agencyLabel(strOf(x.agencyName));
  if (nation.length > 0 && agency.length > 0) {
    r.sub = nation + ' · ' + agency;
  } else {
    r.sub = nation.length > 0 ? nation : agency;
  }
  r.avatar = strOf(x.img);
  if (x.inSpace) {
    r.badge = '在轨';
    r.badgeOn = true;
  }
  r.astroId = String(x.id);
  r.astroPerson = strOf(x.name);
  return r;
}

/**
 * 工位行：副标题 `placeZh · agencyLabel`（小程序 padRow 的拼法）。
 *
 * 原先这里只放 placeZh、空则退 country_code，**丢掉了运营机构** ——
 * 搜「SpaceX」命中一堆工位，行里却看不出哪个是 SpaceX 的。
 */
function se2PadRow(x: Se2PadRaw): Se2Row {
  const r: Se2Row = new Se2Row();
  r.kind = KIND_PAD;
  r.key = 'pad:' + String(x.id);
  const short: string = padShort(strOf(x.name));
  r.primary = short.length > 0 ? short : strOf(x.name);

  const loc: PadLocation | undefined = x.location;
  let place: string = '';
  let rawPlace: string = '';
  if (loc !== undefined && loc !== null) {
    rawPlace = strOf(loc.name);
    place = placeZh(rawPlace);
  }
  let agency: string = '';
  const ags: Se2PadAgencyRef[] | undefined = x.agencies;
  if (ags !== undefined && ags !== null && ags.length > 0) {
    agency = agencyLabel(strOf(ags[0].name));
  }
  if (place.length > 0 && agency.length > 0) {
    r.sub = place + ' · ' + agency;
  } else {
    r.sub = place.length > 0 ? place : agency;
  }
  r.padPlace = rawPlace;

  // 先落到局部变量再判空：ArkTS 对属性访问路径的收窄不如局部变量稳
  const raw: number | undefined | null = x.total_launch_count;
  const n: number = raw !== undefined && raw !== null ? raw : 0;
  if (n > 0) {
    r.badge = '共 ' + String(n) + ' 次';
  }
  r.padId = String(x.id);
  r.padName = strOf(x.name);
  return r;
}

function se2Group(title: string, count: number, rows: Se2Row[]): Se2Group {
  const g: Se2Group = new Se2Group();
  g.title = title;
  g.count = count;
  g.rows = rows;
  se2GroupSeq = se2GroupSeq + 1;
  g.token = title + '#' + String(se2GroupSeq);
  return g;
}

// ============ 组件 ============

@Component
export struct SearchView {
  /** 进页时的初始关键词（来自发射 tab 的搜索框），可为空 */
  @Prop initialKeyword: string = '';

  /** 输入框内容。输入经 400ms 防抖后才真正过滤 */
  @State kw: string = '';
  /** 分组结果；空数组 + 有关键词 = 还没搜出东西 */
  @State groups: Se2Group[] = [];
  /** 首屏四份（即将 / 已发 / 火箭 / 机构）还没落地 */
  @State coreLoading: boolean = false;
  /** 宇航员 / 工位两份还在路上（小程序 extrasLoading） */
  @State extrasLoading: boolean = false;

  // ============ 私有成员（不参与渲染） ============

  private store: Se2Store = new Se2Store();
  /** 首屏四份数据只拉一次（本页实例内） */
  private coreLoaded: boolean = false;
  private coreTask: Promise<void> | null = null;
  /** 宇航员 / 工位懒加载：第一次输入关键词时才拉 */
  private extrasLoaded: boolean = false;
  private extrasTask: Promise<void> | null = null;
  /** 防抖句柄。-1 表示当前没有待触发的定时器 */
  private debounceTimer: number = -1;

  // ============ 生命周期 ============

  aboutToAppear(): void {
    const seed: string = strOf(this.initialKeyword).trim();
    if (seed.length > 0) {
      this.kw = seed;
      // 带词进页：宇航员 / 工位要跟着拉，否则第一屏结果不完整
      this.loadExtras();
      this.runSearch();
    }
    this.loadCore();
  }

  /**
   * 必须清定时器：400ms 的回调可能落在已销毁的实例上。
   * 虽然只是改一次 @State（不会崩），但那是脏写，而且小程序 onUnload 也做了同样的清理。
   */
  aboutToDisappear(): void {
    this.cancelDebounce();
  }

  // ============ 防抖 ============

  private cancelDebounce(): void {
    if (this.debounceTimer >= 0) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
  }

  private scheduleDebounce(): void {
    this.cancelDebounce();
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = -1;
      this.runSearch();
    }, DEBOUNCE_MS);
  }

  // ============ 数据加载 ============

  private loadCore(): void {
    if (this.coreLoaded || this.coreTask !== null) {
      return;
    }
    this.coreLoading = true;
    this.coreTask = this.loadCoreInner();
  }

  /**
   * 首屏四份数据并发拉。
   *
   * 每份各自 catch：其中一份 404 / 断网不能把其它组的搜索结果也带走 ——
   * 搜索页的价值就在于「总有一组能用」，整页失败是最差的结果。
   */
  private async loadCoreInner(): Promise<void> {
    await Promise.all([
      this.loadUpcoming(),
      this.loadPrevious(),
      this.loadRockets(),
      this.loadAgencies()
    ]);
    this.coreLoaded = true;
    this.coreTask = null;
    this.coreLoading = false;
    // 数据落地时立即补跑，不走 400ms 防抖（用户多半已经打完字在等结果）
    if (this.kw.trim().length > 0) {
      this.runSearch();
    }
  }

  private async loadUpcoming(): Promise<void> {
    try {
      const p: UpcomingPayload = await repo.load<UpcomingPayload>('upcoming');
      const l: LaunchSummary[] | undefined = p.list;
      const arr: LaunchSummary[] = l !== undefined ? l : [];
      this.store.up = arr;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'upcoming 读取失败，本页缺少即将发射');
    }
  }

  private async loadPrevious(): Promise<void> {
    try {
      const p: PreviousPayload = await repo.load<PreviousPayload>('previous');
      const l: LaunchSummary[] | undefined = p.list;
      const arr: LaunchSummary[] = l !== undefined ? l : [];
      this.store.prev = arr;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'previous 读取失败，本页缺少历史发射');
    }
  }

  private async loadRockets(): Promise<void> {
    try {
      const p: ListPayload<Se2RocketRaw> = await repo.load<ListPayload<Se2RocketRaw>>('launchers');
      const l: Se2RocketRaw[] | undefined = p.list;
      const arr: Se2RocketRaw[] = l !== undefined ? l : [];
      this.store.rockets = arr;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'launchers 读取失败，本页缺少火箭型号');
    }
  }

  private async loadAgencies(): Promise<void> {
    try {
      const p: ListPayload<Se2AgencyRaw> = await repo.load<ListPayload<Se2AgencyRaw>>('agencies');
      const l: Se2AgencyRaw[] | undefined = p.list;
      const arr: Se2AgencyRaw[] = l !== undefined ? l : [];
      this.store.agencies = arr;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'agencies 读取失败，本页缺少机构');
    }
  }

  // ============ 宇航员 / 工位（懒加载） ============

  private loadExtras(): void {
    if (this.extrasLoaded || this.extrasTask !== null) {
      return;
    }
    this.extrasLoading = true;
    this.extrasTask = this.loadExtrasInner();
  }

  /**
   * 宇航员优先用 astronautsSearch（862 条精简集，带 nameZh），
   * 拿不到再退回全量 astronauts。
   *
   * **降级必须 try/catch 兜住**：astronautsSearch 在 FILES 里注册了，
   * 但 COS 上文件没传时 load 会 reject；把异常冒出去会让整个搜索页跟着挂。
   * 两档都失败时静默跳过 —— 少一组结果，好过整页空态。
   */
  private async loadExtrasInner(): Promise<void> {
    let astros: AstronautCard[] = [];
    try {
      const p: AstronautsSearchPayload = await repo.load<AstronautsSearchPayload>('astronautsSearch');
      const l: AstronautCard[] | undefined = p.list;
      if (l !== undefined) {
        astros = l;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'astronautsSearch 不可用，降级全量 astronauts');
    }

    if (astros.length === 0) {
      try {
        const full: AstronautsPayload = await repo.load<AstronautsPayload>('astronauts');
        const l2: Astronaut[] | undefined = full.list;
        if (l2 !== undefined) {
          const out: AstronautCard[] = [];
          for (let i = 0; i < l2.length; i++) {
            const a: Astronaut = l2[i];
            // Astronaut → AstronautCard：卡片只要这几字段，
            // 全量里的 missions / evas / bio 在搜索页一个字都用不上。
            const c: AstronautCard = {
              id: a.id,
              name: a.name,
              nation: a.nation,
              agencyName: a.agencyName,
              days: a.days,
              inSpace: a.inSpace,
              img: a.img
            };
            out.push(c);
          }
          astros = out;
        }
      } catch (e) {
        hilog.warn(DOMAIN, TAG, '全量 astronauts 也不可用，搜索缺少宇航员一组');
      }
    }
    this.store.astros = astros;

    try {
      const pp: ListPayload<Se2PadRaw> = await repo.load<ListPayload<Se2PadRaw>>('pads');
      const lp: Se2PadRaw[] | undefined = pp.list;
      const arr: Se2PadRaw[] = lp !== undefined ? lp : [];
      this.store.pads = arr;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'pads 读取失败，搜索缺少工位一组');
    }

    this.extrasLoaded = true;
    this.extrasTask = null;
    this.extrasLoading = false;
    if (this.kw.trim().length > 0) {
      this.runSearch();
    }
  }

  // ============ 搜索主流程 ============

  /**
   * 内存过滤 + 分组，顺序严格照小程序：
   *   即将发射 → 已发射 → 火箭型号 → 宇航员 → 发射工位 → 机构。
   *
   * 每组只留前 GROUP_LIMIT 条进 @State。total 不再单独存「全量命中数」：
   * 组头对非宇航员 / 工位组要显示的就是截断后的条数，直接算好塞进 count，
   * 模板里不必再区分「有没有 total」。
   */
  private runSearch(): void {
    const kw: string = this.kw.trim().toLowerCase();
    if (kw.length === 0) {
      this.groups = [];
      return;
    }

    const out: Se2Group[] = [];

    // ---- 即将发射 ----
    const upRows: Se2Row[] = [];
    const ups: LaunchSummary[] = this.store.up;
    for (let i = 0; i < ups.length; i++) {
      if (upRows.length >= GROUP_LIMIT) {
        break;
      }
      const item: LaunchSummary = ups[i];
      if (se2LaunchMatch(item, kw)) {
        upRows.push(se2LaunchRow(item));
      }
    }
    if (upRows.length > 0) {
      out.push(se2Group('即将发射', upRows.length, upRows));
    }

    // ---- 已发射 ----
    const prevRows: Se2Row[] = [];
    const prevs: LaunchSummary[] = this.store.prev;
    for (let i = 0; i < prevs.length; i++) {
      if (prevRows.length >= GROUP_LIMIT) {
        break;
      }
      const item: LaunchSummary = prevs[i];
      if (se2LaunchMatch(item, kw)) {
        prevRows.push(se2LaunchRow(item));
      }
    }
    if (prevRows.length > 0) {
      out.push(se2Group('已发射', prevRows.length, prevRows));
    }

    // ---- 火箭型号 ----
    const rocketRows: Se2Row[] = [];
    const rks: Se2RocketRaw[] = this.store.rockets;
    for (let i = 0; i < rks.length; i++) {
      if (rocketRows.length >= GROUP_LIMIT) {
        break;
      }
      const item: Se2RocketRaw = rks[i];
      if (se2RocketMatch(item, kw)) {
        rocketRows.push(se2RocketRow(item));
      }
    }
    if (rocketRows.length > 0) {
      out.push(se2Group('火箭型号', rocketRows.length, rocketRows));
    }

    // ---- 宇航员（组头显示全量命中数）----
    const astroRows: Se2Row[] = [];
    let astroTotal: number = 0;
    const asts: AstronautCard[] = this.store.astros;
    for (let i = 0; i < asts.length; i++) {
      const item: AstronautCard = asts[i];
      if (!se2AstroMatch(item, kw)) {
        continue;
      }
      astroTotal = astroTotal + 1;
      if (astroRows.length < GROUP_LIMIT) {
        astroRows.push(se2AstroRow(item));
      }
    }
    if (astroTotal > 0) {
      out.push(se2Group('宇航员', astroTotal, astroRows));
    }

    // ---- 发射工位（同上，显示全量命中数）----
    const padRows: Se2Row[] = [];
    let padTotal: number = 0;
    const pds: Se2PadRaw[] = this.store.pads;
    for (let i = 0; i < pds.length; i++) {
      const item: Se2PadRaw = pds[i];
      if (!se2PadMatch(item, kw)) {
        continue;
      }
      padTotal = padTotal + 1;
      if (padRows.length < GROUP_LIMIT) {
        padRows.push(se2PadRow(item));
      }
    }
    if (padTotal > 0) {
      out.push(se2Group('发射工位', padTotal, padRows));
    }

    // ---- 机构 ----
    const agencyRows: Se2Row[] = [];
    const ags: Se2AgencyRaw[] = this.store.agencies;
    for (let i = 0; i < ags.length; i++) {
      if (agencyRows.length >= GROUP_LIMIT) {
        break;
      }
      const item: Se2AgencyRaw = ags[i];
      if (se2AgencyMatch(item, kw)) {
        agencyRows.push(se2AgencyRow(item));
      }
    }
    if (agencyRows.length > 0) {
      out.push(se2Group('机构', agencyRows.length, agencyRows));
    }

    this.groups = out;
  }

  // ============ 交互 ============

  /** 清空关键词：取消待触发的防抖，避免清完 400ms 后又搜出旧结果 */
  private clearKw(): void {
    this.cancelDebounce();
    this.kw = '';
    this.groups = [];
  }

  /**
   * 点行跳转。
   *
   * 机构 / 工位都按 id 跳（小程序同口径）；火箭页路由只有 name 一参、
   * 页内按 name / full_name 精确匹配，所以这里传 full_name 优先，
   * 相当于用「最接近唯一键」的字段代替 id。
   */
  private onRowClick(r: Se2Row): void {
    if (r.kind === KIND_LAUNCH) {
      const item: LaunchSummary | null = r.launch;
      if (item === null) {
        return;
      }
      Nav.pushLaunch(new LaunchNavParam(strOf(item.id), strOf(item.net), r.primary));
      return;
    }
    if (r.kind === KIND_ROCKET) {
      Nav.pushRocket(new RocketNavParam(r.rocketName));
      return;
    }
    if (r.kind === KIND_ASTRO) {
      Nav.pushAstronaut(new AstronautNavParam(r.astroId, r.astroPerson));
      return;
    }
    if (r.kind === KIND_AGENCY) {
      Nav.pushAgency(new AgencyNavParam(r.agencyId, r.agencyName));
      return;
    }
    if (r.kind === KIND_PAD) {
      // 三参：id 精确匹配优先；place 给场地原文，PadView 在只按名字找时才拿它消歧
      Nav.pushPad(new PadNavParam(r.padId, r.padName, r.padPlace));
    }
  }

  /** 空态引导：卫星不在全局搜索范围内，去太空资产页（那边的搜索覆盖全量分片） */
  private goAssetSearch(): void {
    Nav.pushBlank(ROUTE_ASSETS);
  }

  // ============ UI：搜索行 ============

  /**
   * 搜索行：`‹` + 输入框。**没有标题栏** —— 小程序 search.vue 顶部只有这一行。
   *
   * 尺寸全部按 scss：bar padding 6/12/10、返回热区 32×32（64rpx）、
   * 箭头 23vp（46rpx）、输入框 36vp 高 / 18vp 圆角 / 左右 10vp 内边距。
   *
   * defaultFocus(true)：进页即聚焦、直接能打字。不用 focusControl.requestFocus，
   * 那个要自己在 aboutToAppear 里传 id，多一层字符串常量维护，还容易和首次渲染抢时序。
   */
  @Builder
  searchBar() {
    Row() {
      Row() {
        Text('‹')
          .fontSize(23).fontColor(TEXT_MAIN).lineHeight(23).margin({ top: -3 })
      }
      .width(32).height(32)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ right: 4 })
      .onClick(() => {
        Nav.pop();
      })

      Row() {
        Text('🔍').fontSize(13).opacity(0.6).margin({ right: 6 })

        TextInput({ text: this.kw, placeholder: '搜任务 / 火箭 / 宇航员 / 工位 / 机构' })
          .type(InputType.Normal)
          .enterKeyType(EnterKeyType.Search)
          .fontSize(14)
          .fontColor(TEXT_MAIN)
          .placeholderColor(MUTED)
          .placeholderFont({ size: 14 })
          .backgroundColor('#00000000')
          .padding(0)
          .height(36)
          .layoutWeight(1)
          .defaultFocus(true)
          // 400ms 防抖照小程序：输入法连打时每个字符都重排整页会闪，
          // 且组头数字跟着跳；这里只在停手后搜一次。
          .onChange((v: string) => {
            this.kw = v;
            if (v.trim().length === 0) {
              // 清空是「立刻要看到引导页」的动作，不能等 400ms
              this.cancelDebounce();
              this.groups = [];
              return;
            }
            // 第一次输入才去拉宇航员 / 工位（约 190KB），不进页就拉
            this.loadExtras();
            this.scheduleDebounce();
          })

        if (this.kw.length > 0) {
          Text('✕')
            .fontSize(13)
            .fontColor(MUTED_TEXT)
            .padding({ left: 8, top: 5, bottom: 5 })
            .onClick(() => {
              this.clearKw();
            })
        }
      }
      .layoutWeight(1)
      .height(36)
      .padding({ left: 10, right: 10 })
      .backgroundColor(CARD_BG)
      .borderRadius(18)
      .border({ width: 1, color: BORDER_SOFT })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 6, bottom: 10 })
  }

  // ============ UI：结果 ============

  /**
   * 一个分组。
   *
   * 组头两段（标题 + 计数），**没有**「还有 N 条」组尾 —— 小程序也没有。
   * 这里按值收 g：ForEach 在 groups 换新数组时会重建整块，
   * 不依赖 @Builder 形参的响应式（依赖的是这一层 ForEach）。
   */
  @Builder
  groupBlock(g: Se2Group) {
    Column() {
      Row() {
        Text(g.title)
          .fontSize(13).fontColor(GROUP_TITLE)
        Text(String(g.count))
          .fontSize(11).fontColor(MUTED).margin({ left: 6 })
      }
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 4, right: 4, top: 4, bottom: 6 })

      ForEach(g.rows, (r: Se2Row) => {
        Row() {
          if (r.avatar.length > 0) {
            Image(r.avatar)
              .width(34).height(34)
              .borderRadius(17)
              .margin({ right: 9 })
              .objectFit(ImageFit.Cover)
              .backgroundColor('#1A2231')
          }

          Column() {
            Text(r.primary)
              .fontSize(14).fontColor(TEXT_MAIN).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (r.sub.length > 0) {
              Text(r.sub)
                .fontSize(11.5).fontColor(MUTED_TEXT).margin({ top: 2 }).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (r.badge.length > 0) {
            Text(r.badge)
              .fontSize(10)
              .fontColor(r.badgeOn ? BADGE_ON : MUTED_TEXT)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(4)
              .border({ width: 1, color: r.badgeOn ? BADGE_ON_BORDER : BORDER_BADGE })
              .margin({ left: 6 })
          }

          Text('›')
            .fontSize(16).fontColor(MUTED).margin({ left: 8 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 10, right: 10, top: 11, bottom: 11 })
        .backgroundColor(CARD_BG)
        .borderRadius(8)
        .margin({ bottom: 6 })
        .onClick(() => {
          this.onRowClick(r);
        })
      }, (r: Se2Row) => r.key)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 15 })
  }

  // ============ UI：空态 / 提示 ============

  /** 纯文字加载提示（小程序没有 spinner，只有一行 11.5vp 小字） */
  @Builder
  extraHint() {
    Row() {
      Text('正在加载宇航员 / 工位…')
        .fontSize(11.5).fontColor(MUTED)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 2, bottom: 15 })
  }

  /** 还没有任何分组、但数据在路上：居中一行小字，别急着说「没有找到」 */
  @Builder
  hintBlock() {
    Column() {
      Text('正在加载宇航员 / 工位…')
        .fontSize(11.5).fontColor(MUTED)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 有关键词但零命中。
   *
   * 卫星（GCAT 两万多颗分 26 片约 8MB）**不在全局搜索范围**：
   * 本页只拿得到第 0 片 800 条，搜「哈勃」命中与否纯看运气，
   * 半截结果比没有更误导。所以小程序在这里给了一个可点的青色胶囊，
   * 直接跳到「太空资产 · 卫星百科」——那边是逐片加载的真实全量搜索。
   * 鸿蒙侧对应路由是 ROUTE_ASSETS（pushBlank 无入参，进去落在第一个 tab）。
   */
  @Builder
  emptyBlock() {
    Column() {
      Text('🔍').fontSize(36)
      Text('没有找到「' + this.kw.trim() + '」相关内容')
        .fontSize(14).fontColor(MUTED_TEXT).margin({ top: 12 })
        .maxLines(2)
        .textAlign(TextAlign.Center)

      Text('去「太空资产 · 卫星百科」搜卫星 ›')
        .fontSize(13).fontColor(ACCENT)
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .borderRadius(999)
        .border({ width: 1, color: ACCENT_BORDER })
        .backgroundColor(ACCENT_WASH)
        .margin({ top: 14 })
        .onClick(() => {
          this.goAssetSearch();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 20, right: 20 })
  }

  /**
   * 无关键词：告诉用户能搜什么。
   *
   * 文案与小程序逐字一致（含示例），标题 12vp + letter-spacing 1vp（2rpx），
   * 条目 13.5vp、行高 2.1 —— 行高不写死像素，按字号倍率给 28.5。
   */
  @Builder
  tipsBlock() {
    Column() {
      Text('可以搜这些')
        .fontSize(12).fontColor(MUTED).letterSpacing(1)
        .margin({ bottom: 10 })

      Text('· 任务名（如「星链」「嫦娥」）')
        .fontSize(13.5).fontColor(MUTED_TEXT).lineHeight(28.5)
      Text('· 火箭型号（如「猎鹰 9」「长征」）')
        .fontSize(13.5).fontColor(MUTED_TEXT).lineHeight(28.5)
      Text('· 宇航员（如「杨利伟」「Wang」）')
        .fontSize(13.5).fontColor(MUTED_TEXT).lineHeight(28.5)
      Text('· 发射工位（如「文昌」「SpaceX」）')
        .fontSize(13.5).fontColor(MUTED_TEXT).lineHeight(28.5)
      Text('· 机构（如「NASA」「中国航天」）')
        .fontSize(13.5).fontColor(MUTED_TEXT).lineHeight(28.5)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 24, right: 24, top: 40 })
  }

  build() {
    Column() {
      this.searchBar()

      if (this.kw.trim().length === 0) {
        this.tipsBlock()
      } else if (this.groups.length > 0) {
        Scroll() {
          Column() {
            ForEach(this.groups, (g: Se2Group) => {
              this.groupBlock(g)
            }, (g: Se2Group) => g.token)

            // 有结果但宇航员 / 工位还没到位：组尾给一行小字，别让用户以为搜完了
            if (this.extrasLoading) {
              this.extraHint()
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 5 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      } else if (this.coreLoading || this.extrasLoading) {
        this.hintBlock()
      } else {
        this.emptyBlock()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    .padding({ bottom: BOTTOM_PAD })
    .alignItems(HorizontalAlign.Start)
  }
}
