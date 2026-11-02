/**
 * 全局搜索页。
 *
 * 对位小程序 `pages/search/search.vue`：一个输入框对六份数据一把梭。
 * 数据全是 CI 预生成的静态 JSON，搜索就是**内存过滤**，不发任何搜索请求，
 * 所以这里没有防抖定时器 —— 几千条字符串 indexOf 是微秒级，
 * 定时器只会让「打字时结果跳一下」，反而更差。也没有 aboutToDisappear 要清理的东西。
 *
 * 与小程序的差异（有意）：
 *   1. 小程序把「即将发射 / 已发射」拆成两组；这里按任务书合并成「发射 · N」一组，
 *      因为鸿蒙侧结果组更少、横向更省一屏。
 *   2. 小程序靠 `astronautsSearch` 的降级 catch 兜全量；这里同样降级，但另外
 *      保留了「连全量都失败」的静默路径 —— 搜索页缺一组不该整页变空态。
 *   3. 机构 / 工位**没有详情页**（鸿蒙侧尚未做 pages/agencies、pages/pad 的对位页），
 *      点了给 toast，不做假跳转 —— 跳到空白页比没反应更伤。
 *
 * 字段口径（线上 v14 实测，2026-11-02 抓样）：
 *   agencies.json   350 条：id / name / abbrev / type / country_code / founding_year / launchers
 *                   —— **没有 nameZh**（小程序 search.vue 里那个 hit(x.nameZh) 恒为假）
 *   pads.json       251 条：id / name / location{id,name} / agencies[{id,name}] /
 *                   total_launch_count / country_code / active
 *                   —— **没有 nameZh、没有 countryZh**，中文只能靠 placeZh/agencyLabel 查表
 *   astronautsSearch 862 条：id / name / nameZh / nation / agencyName / days / inSpace / img
 *                   —— 轻量集**确实带 nameZh**（830 条非空），中文名优先用它
 *   launchers.json  532 条：id(number) / name / full_name / variant / families /
 *                   manufacturer / description / descriptionZh
 *                   —— **没有 desc、没有 agencyName**，机构只有 manufacturer
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { repo } from '../data/Repository';
import {
  LaunchSummary, LaunchMission, LaunchPad, LaunchRocket, RocketConfig, PadLocation, ListPayload
} from '../model/Common';
import { UpcomingPayload, PreviousPayload } from '../model/Launch';
import { Astronaut, AstronautCard, AstronautsPayload, AstronautsSearchPayload } from '../model/Astronaut';
import { NewsItem, NewsPayload, NewsLaunchRef } from '../model/News';
import {
  strOf, missionLabelOf, formatShort, placeLabelOf, rocketName, astroName,
  nationZh, agencyLabel, placeZh, padShort
} from '../utils/Format';
import { Nav } from '../routes/Nav';
import { LaunchNavParam, RocketNavParam, ArticleNavParam, AstronautNavParam, AgencyNavParam, PadNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'SearchView';

// ============ 视觉常量（与 LaunchView / FavoritesView 同口径） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
const DIVIDER: string = '#12FFFFFF';

const PAGE_PAD: number = 12;
/** 底部留 120：搜索页在 tab 栈里，下面压着悬浮胶囊 */
// 底部留白：本页是 NavDestination 二级页，胶囊在详情页打开时已被摘掉，
// 不需要按 tab 根页那样让位 92~120，32 只够滑到底时最后一行不贴边。
const BOTTOM_PAD: number = 32;

/** 每组最多显示 8 条，超出折成「还有 N 条」 */
const GROUP_LIMIT: number = 8;

// 结果行类型（字符串常量而不是 enum：enum 跨文件要 import，这里只在页内用）
const KIND_LAUNCH: string = 'launch';
const KIND_ROCKET: string = 'rocket';
const KIND_AGENCY: string = 'agency';
const KIND_ASTRO: string = 'astronaut';
const KIND_PAD: string = 'pad';
const KIND_ARTICLE: string = 'article';

// ============ 原始数据类型（只声明本页真正读到的字段） ============
//
// 为什么不用 model/*.ets 里现成的 interface：
//   agencies / pads / launchers 三份数据在鸿蒙侧还没有对应的 model 文件，
//   与其为搜索页临时扩 model（会牵动别处），不如按「本页读到哪几个键」就地声明。
//   前缀 Se 是为了避开 ArkTS 的声明合并限制（同名 interface 不允许重复声明）。

interface SeAgencyRaw {
  id: number;
  name?: string;
  abbrev?: string;
  type?: string;
  country_code?: string;
  /** 线上不存在，保留只为对齐小程序口径（命中时为空，不影响任何结果） */
  nameZh?: string;
}

interface SePadAgencyRef {
  id?: number;
  name?: string;
}

interface SePadRaw {
  id: number;
  name?: string;
  location?: PadLocation;
  agencies?: SePadAgencyRef[];
  total_launch_count?: number;
  country_code?: string;
  /** 线上不存在，同上 */
  nameZh?: string;
  countryZh?: string;
}

interface SeRocketRaw {
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
class SeRow {
  key: string = '';
  kind: string = '';
  /** 主标题：任务名 / 火箭名 / 机构名 / 人名 / 工位名 / 资讯标题 */
  primary: string = '';
  sub: string = '';
  badge: string = '';
  badgeOn: boolean = false;
  /** 头像，只有航天员有 */
  avatar: string = '';
  /** 发射行：整条摘要带过去，点击时不用再回查 */
  launch: LaunchSummary | null = null;
  /** 火箭行：RocketNavParam 只认 name */
  rocketName: string = '';
  /** 航天员行：id 转字符串 + 姓名 */
  astroId: string = '';
  astroPerson: string = '';
  /** 资讯行：整条 NewsItem 摊平进 ArticleNavParam */
  article: NewsItem | null = null;
  /** 机构行：LL2 agency id（number 的字符串形式） */
  agencyId: string = '';
  /** 工位行：LL2 pad id（number 的字符串形式） */
  padId: string = '';
}

/** 一个结果分组 */
class SeGroup {
  title: string = '';
  /** 命中总数（可能大于 rows.length） */
  total: number = 0;
  rows: SeRow[] = [];
  /** total - rows.length，>0 时显示「还有 N 条」 */
  hidden: number = 0;
}

/**
 * 六份数据的本页副本。
 *
 * 放普通 class 实例而不是 @State 数组：这些是「搜索的输入」，
 * 变化时不需要单独重绘，runSearch() 会把结果算进 @State groups 里。
 * 用 @State 反而会多触发一轮无意义的重绘。
 */
class SeStore {
  up: LaunchSummary[] = [];
  prev: LaunchSummary[] = [];
  rockets: SeRocketRaw[] = [];
  agencies: SeAgencyRaw[] = [];
  astros: AstronautCard[] = [];
  pads: SePadRaw[] = [];
  news: NewsItem[] = [];
}

// ============ 匹配（纯函数，与 utils/search-match.js 同口径） ============

/**
 * 单个字段是否命中。
 *
 * 关键词已经统一小写，字段在比较时再转 —— 数据量下这个转换成本可以忽略，
 * 而「先建小写索引表」会多占一倍内存、还得处理数据更新，不划算。
 */
function seHit(v: string | undefined | null, kw: string): boolean {
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
function seLaunchMatch(x: LaunchSummary, kw: string): boolean {
  if (seHit(x.name, kw)) {
    return true;
  }
  const m: LaunchMission | undefined = x.mission;
  if (m !== undefined && m !== null) {
    if (seHit(m.name, kw) || seHit(m.nameZh, kw)) {
      return true;
    }
  }
  const rk: LaunchRocket | undefined = x.rocket;
  if (rk !== undefined && rk !== null) {
    const c: RocketConfig | undefined = rk.configuration;
    if (c !== undefined && c !== null) {
      if (seHit(c.name, kw) || seHit(c.full_name, kw) || seHit(rocketName(c), kw)) {
        return true;
      }
    }
  }
  const pad: LaunchPad | undefined = x.pad;
  if (pad !== undefined && pad !== null) {
    if (seHit(pad.name, kw)) {
      return true;
    }
    const loc: PadLocation | undefined = pad.location;
    if (loc !== undefined && loc !== null && seHit(loc.name, kw)) {
      return true;
    }
  }
  const p: string = strOf(x.launch_service_provider !== undefined &&
    x.launch_service_provider !== null ? x.launch_service_provider.name : '');
  return seHit(p, kw);
}

/** 火箭型号：原始名 + 完整名 + 中文名（rocketName 内含 ROCKET_ZH 与长征推导） */
function seRocketMatch(x: SeRocketRaw, kw: string): boolean {
  if (seHit(x.name, kw) || seHit(x.full_name, kw) || seHit(x.manufacturer, kw)) {
    return true;
  }
  return seHit(seRocketLabel(x), kw);
}

/** 机构：name / abbrev / nameZh（后者线上为空，口径对齐小程序） */
function seAgencyMatch(x: SeAgencyRaw, kw: string): boolean {
  return seHit(x.name, kw) || seHit(x.abbrev, kw) || seHit(x.nameZh, kw);
}

/**
 * 航天员：中英文姓名、国籍、机构。
 *
 * astronautsSearch 是精简集但**带 nameZh**（实测 830/862 非空），
 * 所以这里优先用 nameZh 显示；astroName() 是 CHINA_ASTRO_ZH 专名表兜底，
 * 两者都查不到才显示拼音原文。
 */
function seAstroMatch(x: AstronautCard, kw: string): boolean {
  if (seHit(x.name, kw) || seHit(x.nameZh, kw)) {
    return true;
  }
  if (seHit(astroName(strOf(x.name), strOf(x.nation)), kw)) {
    return true;
  }
  if (seHit(x.nation, kw) || seHit(nationZh(strOf(x.nation)), kw)) {
    return true;
  }
  return seHit(x.agencyName, kw) || seHit(agencyLabel(strOf(x.agencyName)), kw);
}

/**
 * 发射工位：名字 / 缩写 / 场地 / 国家 / 运营机构。
 *
 * pads 里**没有任何中文字段**（无 nameZh、无 countryZh），中文命中完全靠
 * Format.ets 的 PLACE_ZH / AGENCY_ZH 两张表；placeZh 命中即返回，
 * 所以国家要单独判一次，否则搜「中国」只能碰到机构名里带中国的零星工位。
 */
function sePadMatch(x: SePadRaw, kw: string): boolean {
  if (seHit(x.name, kw) || seHit(padShort(strOf(x.name)), kw)) {
    return true;
  }
  const loc: PadLocation | undefined = x.location;
  if (loc !== undefined && loc !== null) {
    if (seHit(loc.name, kw) || seHit(placeZh(strOf(loc.name)), kw)) {
      return true;
    }
  }
  const ags: SePadAgencyRef[] | undefined = x.agencies;
  if (ags !== undefined && ags !== null) {
    for (let i = 0; i < ags.length; i++) {
      const a: SePadAgencyRef = ags[i];
      if (seHit(a.name, kw) || seHit(agencyLabel(strOf(a.name)), kw)) {
        return true;
      }
    }
  }
  return seHit(x.country_code, kw) || seHit(x.countryZh, kw);
}

/** 资讯：中英标题 + 中英摘要都看（标题命中率最高，但摘要里常出现具体型号名） */
function seNewsMatch(x: NewsItem, kw: string): boolean {
  if (seHit(x.title, kw) || seHit(x.titleZh, kw)) {
    return true;
  }
  return seHit(x.summary, kw) || seHit(x.summaryZh, kw);
}

// ============ 行 / 组构造 ============

/** 火箭展示名：中文表 → 完整名 → 原名 */
function seRocketLabel(x: SeRocketRaw): string {
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

function seLaunchRow(x: LaunchSummary): SeRow {
  const r: SeRow = new SeRow();
  r.kind = KIND_LAUNCH;
  r.key = 'launch:' + strOf(x.id);
  r.primary = missionLabelOf(x);
  let sub: string = formatShort(strOf(x.net));
  const place: string = placeLabelOf(x);
  if (place.length > 0) {
    sub = sub + ' · ' + place;
  }
  r.sub = sub;
  r.launch = x;
  return r;
}

function seRocketRow(x: SeRocketRaw): SeRow {
  const r: SeRow = new SeRow();
  r.kind = KIND_ROCKET;
  r.key = 'rocket:' + String(x.id);
  r.primary = seRocketLabel(x);
  // launchers 没有 agencyName，机构只有 manufacturer（原文长名，不做截断）
  r.sub = strOf(x.manufacturer);
  r.rocketName = strOf(x.name);
  return r;
}

function seAgencyRow(x: SeAgencyRaw): SeRow {
  const r: SeRow = new SeRow();
  r.kind = KIND_AGENCY;
  r.key = 'agency:' + String(x.id);
  r.primary = strOf(x.name);
  const abbrev: string = strOf(x.abbrev);
  const type: string = strOf(x.type);
  r.sub = abbrev.length > 0 ? abbrev : type;
  r.agencyId = String(x.id);
  return r;
}

function seAstroRow(x: AstronautCard): SeRow {
  const r: SeRow = new SeRow();
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

function sePadRow(x: SePadRaw): SeRow {
  const r: SeRow = new SeRow();
  r.kind = KIND_PAD;
  r.key = 'pad:' + String(x.id);
  const short: string = padShort(strOf(x.name));
  r.primary = short.length > 0 ? short : strOf(x.name);
  const loc: PadLocation | undefined = x.location;
  let sub: string = '';
  if (loc !== undefined && loc !== null) {
    sub = placeZh(strOf(loc.name));
  }
  if (sub.length === 0) {
    sub = strOf(x.country_code);
  }
  r.sub = sub;
  // 先落到局部变量再判空：ArkTS 对「属性访问路径」的收窄不如局部变量稳，
  // 直接写 x.total_launch_count !== undefined ? x.total_launch_count : 0 可能仍被当成 number | undefined
  const raw: number | undefined | null = x.total_launch_count;
  const n: number = raw !== undefined && raw !== null ? raw : 0;
  if (n > 0) {
    r.badge = '共 ' + String(n) + ' 次';
  }
  r.padId = String(x.id);
  return r;
}

function seArticleRow(x: NewsItem): SeRow {
  const r: SeRow = new SeRow();
  r.kind = KIND_ARTICLE;
  r.key = 'news:' + String(x.id);
  const zh: string = strOf(x.titleZh);
  r.primary = zh.length > 0 ? zh : strOf(x.title);
  const site: string = strOf(x.site);
  const at: string = strOf(x.at);
  if (site.length > 0 && at.length > 0) {
    r.sub = site + ' · ' + at;
  } else {
    r.sub = site.length > 0 ? site : at;
  }
  r.article = x;
  return r;
}

function seGroup(title: string, total: number, rows: SeRow[]): SeGroup {
  const g: SeGroup = new SeGroup();
  g.title = title;
  g.total = total;
  g.rows = rows;
  g.hidden = total > rows.length ? total - rows.length : 0;
  return g;
}

// ============ 组件 ============

@Component
export struct SearchView {
  /** 进页时的初始关键词（来自发射 tab 的搜索框），可为空 */
  @Prop initialKeyword: string = '';

  /** 输入框内容。**输入即搜**，没有「确定」这一步 */
  @State kw: string = '';
  /** 分组结果；空数组 + 有关键词 + 未加载 = 还在路上 */
  @State groups: SeGroup[] = [];
  /** 首屏（发射 / 火箭 / 机构 / 资讯）还没落地 */
  @State loading: boolean = false;

  // ============ 私有成员（不参与渲染） ============

  private store: SeStore = new SeStore();
  /** 首屏四份数据只拉一次（本页实例内） */
  private coreLoaded: boolean = false;
  private coreTask: Promise<void> | null = null;
  /** 宇航员 / 工位懒加载：第一次输入关键词时才拉 */
  private extrasLoaded: boolean = false;
  private extrasTask: Promise<void> | null = null;

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

  // ============ 数据加载 ============

  private loadCore(): void {
    if (this.coreLoaded || this.coreTask !== null) {
      return;
    }
    this.loading = true;
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
      this.loadAgencies(),
      this.loadNews()
    ]);
    this.coreLoaded = true;
    this.coreTask = null;
    this.loading = this.extrasTask !== null;
    if (this.kw.trim().length > 0) {
      this.runSearch();
    }
  }

  private async loadUpcoming(): Promise<void> {
    try {
      const p: UpcomingPayload = await repo.load<UpcomingPayload>('upcoming');
      const l: LaunchSummary[] | undefined = p.list;
      this.store.up = l !== undefined ? l : [];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'upcoming 读取失败，本页缺少即将发射');
    }
  }

  private async loadPrevious(): Promise<void> {
    try {
      const p: PreviousPayload = await repo.load<PreviousPayload>('previous');
      const l: LaunchSummary[] | undefined = p.list;
      this.store.prev = l !== undefined ? l : [];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'previous 读取失败，本页缺少历史发射');
    }
  }

  private async loadRockets(): Promise<void> {
    try {
      const p: ListPayload<SeRocketRaw> = await repo.load<ListPayload<SeRocketRaw>>('launchers');
      const l: SeRocketRaw[] | undefined = p.list;
      this.store.rockets = l !== undefined ? l : [];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'launchers 读取失败，本页缺少火箭型号');
    }
  }

  private async loadAgencies(): Promise<void> {
    try {
      const p: ListPayload<SeAgencyRaw> = await repo.load<ListPayload<SeAgencyRaw>>('agencies');
      const l: SeAgencyRaw[] | undefined = p.list;
      this.store.agencies = l !== undefined ? l : [];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'agencies 读取失败，本页缺少机构');
    }
  }

  private async loadNews(): Promise<void> {
    try {
      const p: NewsPayload = await repo.load<NewsPayload>('news');
      const l: NewsItem[] | undefined = p.list;
      this.store.news = l !== undefined ? l : [];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'news 读取失败，本页缺少资讯');
    }
  }

  // ============ 宇航员 / 工位（懒加载） ============

  private loadExtras(): void {
    if (this.extrasLoaded || this.extrasTask !== null) {
      return;
    }
    this.loading = true;
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
            // Astronaut → AstronautCard：卡片只要这 8 个字段，
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
        hilog.warn(DOMAIN, TAG, '全量 astronauts 也不可用，搜索缺少航天员一组');
      }
    }
    this.store.astros = astros;

    try {
      const pp: ListPayload<SePadRaw> = await repo.load<ListPayload<SePadRaw>>('pads');
      const lp: SePadRaw[] | undefined = pp.list;
      this.store.pads = lp !== undefined ? lp : [];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'pads 读取失败，搜索缺少工位一组');
    }

    this.extrasLoaded = true;
    this.extrasTask = null;
    this.loading = this.coreTask !== null;
    // 数据到位时用户多半已经打完字了：补跑一次，把两组补进结果
    if (this.kw.trim().length > 0) {
      this.runSearch();
    }
  }

  // ============ 搜索主流程 ============

  /**
   * 内存过滤 + 分组。
   *
   * 每组只留前 GROUP_LIMIT 条进 @State，但 total 记全量 ——
   * 结果集可能上千（搜「a」能命中几百个火箭），
   * 全塞进状态里每次重绘都要走一遍 diff，而用户根本翻不到第 9 条之后。
   */
  private runSearch(): void {
    const kw: string = this.kw.trim().toLowerCase();
    if (kw.length === 0) {
      this.groups = [];
      return;
    }

    const out: SeGroup[] = [];

    // ---- 发射（即将 + 历史，合并一组）----
    const launchRows: SeRow[] = [];
    let launchTotal: number = 0;
    const up: LaunchSummary[] = this.store.up;
    for (let i = 0; i < up.length; i++) {
      const item: LaunchSummary = up[i];
      if (!seLaunchMatch(item, kw)) {
        continue;
      }
      launchTotal = launchTotal + 1;
      if (launchRows.length < GROUP_LIMIT) {
        launchRows.push(seLaunchRow(item));
      }
    }
    const prev: LaunchSummary[] = this.store.prev;
    for (let i = 0; i < prev.length; i++) {
      const item: LaunchSummary = prev[i];
      if (!seLaunchMatch(item, kw)) {
        continue;
      }
      launchTotal = launchTotal + 1;
      if (launchRows.length < GROUP_LIMIT) {
        launchRows.push(seLaunchRow(item));
      }
    }
    if (launchTotal > 0) {
      out.push(seGroup('发射', launchTotal, launchRows));
    }

    // ---- 火箭 ----
    const rocketRows: SeRow[] = [];
    let rocketTotal: number = 0;
    const rks: SeRocketRaw[] = this.store.rockets;
    for (let i = 0; i < rks.length; i++) {
      const item: SeRocketRaw = rks[i];
      if (!seRocketMatch(item, kw)) {
        continue;
      }
      rocketTotal = rocketTotal + 1;
      if (rocketRows.length < GROUP_LIMIT) {
        rocketRows.push(seRocketRow(item));
      }
    }
    if (rocketTotal > 0) {
      out.push(seGroup('火箭', rocketTotal, rocketRows));
    }

    // ---- 机构 ----
    const agencyRows: SeRow[] = [];
    let agencyTotal: number = 0;
    const ags: SeAgencyRaw[] = this.store.agencies;
    for (let i = 0; i < ags.length; i++) {
      const item: SeAgencyRaw = ags[i];
      if (!seAgencyMatch(item, kw)) {
        continue;
      }
      agencyTotal = agencyTotal + 1;
      if (agencyRows.length < GROUP_LIMIT) {
        agencyRows.push(seAgencyRow(item));
      }
    }
    if (agencyTotal > 0) {
      out.push(seGroup('机构', agencyTotal, agencyRows));
    }

    // ---- 航天员 ----
    const astroRows: SeRow[] = [];
    let astroTotal: number = 0;
    const asts: AstronautCard[] = this.store.astros;
    for (let i = 0; i < asts.length; i++) {
      const item: AstronautCard = asts[i];
      if (!seAstroMatch(item, kw)) {
        continue;
      }
      astroTotal = astroTotal + 1;
      if (astroRows.length < GROUP_LIMIT) {
        astroRows.push(seAstroRow(item));
      }
    }
    if (astroTotal > 0) {
      out.push(seGroup('航天员', astroTotal, astroRows));
    }

    // ---- 工位 ----
    const padRows: SeRow[] = [];
    let padTotal: number = 0;
    const pds: SePadRaw[] = this.store.pads;
    for (let i = 0; i < pds.length; i++) {
      const item: SePadRaw = pds[i];
      if (!sePadMatch(item, kw)) {
        continue;
      }
      padTotal = padTotal + 1;
      if (padRows.length < GROUP_LIMIT) {
        padRows.push(sePadRow(item));
      }
    }
    if (padTotal > 0) {
      out.push(seGroup('工位', padTotal, padRows));
    }

    // ---- 资讯 ----
    const newsRows: SeRow[] = [];
    let newsTotal: number = 0;
    const ns: NewsItem[] = this.store.news;
    for (let i = 0; i < ns.length; i++) {
      const item: NewsItem = ns[i];
      if (!seNewsMatch(item, kw)) {
        continue;
      }
      newsTotal = newsTotal + 1;
      if (newsRows.length < GROUP_LIMIT) {
        newsRows.push(seArticleRow(item));
      }
    }
    if (newsTotal > 0) {
      out.push(seGroup('资讯', newsTotal, newsRows));
    }

    this.groups = out;
  }

  // ============ 交互 ============

  /** 清空关键词：只改 @State，TextInput 的单向绑定会跟着重绘 */
  private clearKw(): void {
    this.kw = '';
    this.groups = [];
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  /**
   * 点行跳转。
   *
   * 六类结果全部落到真实详情页（2026-11-03 补齐机构页与工位页后）。
   */
  private onRowClick(r: SeRow): void {
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
    if (r.kind === KIND_ARTICLE) {
      const n: NewsItem | null = r.article;
      if (n !== null) {
        this.openArticle(n);
      }
      return;
    }
    if (r.kind === KIND_AGENCY) {
      // 机构页先按 id 找、找不到再按名字匹配，所以两个都传
      Nav.pushAgency(new AgencyNavParam(r.agencyId, r.primary));
      return;
    }
    if (r.kind === KIND_PAD) {
      Nav.pushPad(new PadNavParam(r.padId, r.primary));
    }
  }

  /**
   * 资讯详情入参有 10 个字段，**全部要填**（详情页不重新拉 news.json，
   * 少填一个就等于那一段内容丢掉）。字段映射照 NewsListView.openArticle 的口径。
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

  // ============ UI：页头 ============

  /** 页头照 FavoritesView：‹ 返回 + 19vp Bold 标题 */
  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹').fontSize(20).fontColor(TEXT_MAIN).lineHeight(20)
        Text('返回').fontSize(14).fontColor(TEXT_SUB).margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Center)
      .padding({ right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        Nav.pop();
      })

      Text('全局搜索')
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor(TEXT_MAIN)
        .maxLines(1).layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .backgroundColor(BG_PRIMARY)
  }

  /**
   * 搜索行：返回箭头在输入框左侧（小程序把返回放在更外层，
   * 鸿蒙侧这里没做「返回 + 输入框」两行，一行更省高度）。
   *
   * defaultFocus(true)：进页即聚焦、直接能打字。不用 focusControl.requestFocus，
   * 那个要自己在 aboutToAppear 里传 id，多一层字符串常量维护，还容易和首次渲染抢时序。
   */
  @Builder
  searchBar() {
    Row() {
      Row() {
        Text('‹')
          .fontSize(22).fontColor(TEXT_MAIN).lineHeight(22).margin({ top: -2 })
      }
      .width(26).height(26)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ right: 8 })
      .onClick(() => {
        Nav.pop();
      })

      Row() {
        Text('🔍').fontSize(12).fontColor(TEXT_DIM).margin({ right: 6 })

        TextInput({ text: this.kw, placeholder: '搜任务 / 火箭 / 宇航员 / 工位 / 机构' })
          .type(InputType.Normal)
          .enterKeyType(EnterKeyType.Search)
          .fontSize(13)
          .fontColor(TEXT_MAIN)
          .placeholderColor(TEXT_DIM)
          .placeholderFont({ size: 13 })
          .backgroundColor('#00000000')
          .padding(0)
          .height(38)
          .layoutWeight(1)
          .defaultFocus(true)
          // 不做防抖：过滤只是几次本地数组遍历，而分组标题里的数字要跟着
          // 每个字符即时变；加 400ms 延迟会出现「字打完了结果才跳」的观感。
          .onChange((v: string) => {
            this.kw = v;
            if (v.trim().length > 0) {
              this.loadExtras();
            }
            this.runSearch();
          })

        if (this.kw.length > 0) {
          Text('✕')
            .fontSize(12)
            .fontColor(TEXT_DIM)
            .width(26)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.clearKw();
            })
        }
      }
      .layoutWeight(1)
      .padding({ left: 12, right: 6 })
      .backgroundColor(CARD_BG)
      .borderRadius(999)
      .border({ width: 1, color: DIVIDER })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 2, bottom: 10 })
  }

  // ============ UI：结果 ============

  @Builder
  groupBlock(g: SeGroup) {
    Column() {
      Text(g.title + ' · ' + String(g.total))
        .fontSize(12)
        .fontColor(TEXT_SUB)
        .padding({ left: 4, top: 12, bottom: 8 })

      ForEach(g.rows, (r: SeRow) => {
        Row() {
          if (r.avatar.length > 0) {
            Image(r.avatar)
              .width(34).height(34)
              .borderRadius(17)
              .margin({ right: 10 })
              .objectFit(ImageFit.Cover)
              .backgroundColor('#1A2231')
          }

          Column() {
            Text(r.primary)
              .fontSize(14).fontColor(TEXT_MAIN).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (r.sub.length > 0) {
              Text(r.sub)
                .fontSize(11).fontColor(TEXT_DIM).margin({ top: 3 }).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          if (r.badge.length > 0) {
            Text(r.badge)
              .fontSize(10)
              .fontColor(r.badgeOn ? '#4ADE80' : TEXT_DIM)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(6)
              .border({ width: 1, color: DIVIDER })
              .margin({ left: 8 })
          }

          Text('›')
            .fontSize(16).fontColor('#3A4459').margin({ left: 6 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 12, right: 10, top: 10, bottom: 10 })
        .backgroundColor(CARD_BG)
        .borderRadius(10)
        .margin({ bottom: 6 })
        .onClick(() => {
          this.onRowClick(r);
        })
      }, (r: SeRow) => r.key)

      if (g.hidden > 0) {
        Text('还有 ' + String(g.hidden) + ' 条')
          .fontSize(11)
          .fontColor(TEXT_DIM)
          .padding({ left: 4, top: 2, bottom: 4 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ============ UI：空态 / 提示 ============

  /** 首屏数据还在路上：不能先说「没有找到」，那是在骗用户 */
  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress().width(30).height(30).color(ACCENT)
      Text('正在加载数据…')
        .fontSize(12).fontColor(TEXT_DIM).margin({ top: 10 })
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
   * 半截结果比没有更误导。所以这里只给一行文字引导去太空资产页，
   * 不做成按钮 —— 那是另一条导航路径，不该在空态里抢主视觉。
   */
  @Builder
  emptyBlock() {
    Column() {
      Text('🔍').fontSize(34).fontColor(TEXT_DIM)
      Text('没有找到「' + this.kw.trim() + '」')
        .fontSize(14).fontColor(TEXT_SUB).margin({ top: 12 })
        .maxLines(2)
        .textAlign(TextAlign.Center)
      Text('试试更短的关键词，或用英文原名')
        .fontSize(11).fontColor(TEXT_DIM).margin({ top: 6 })
      Text('卫星不在全局搜索里，请到「太空资产 · 卫星百科」页内搜')
        .fontSize(11).fontColor(TEXT_DIM).margin({ top: 18 })
        .constraintSize({ maxWidth: '86%' })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 20, right: 20 })
  }

  /** 无关键词：告诉用户能搜什么 */
  @Builder
  tipsBlock() {
    Column() {
      Text('可以搜：任务名 / 火箭型号 / 机构 / 宇航员 / 工位')
        .fontSize(13).fontColor(TEXT_SUB)
        .constraintSize({ maxWidth: '92%' })
        .textAlign(TextAlign.Center)

      Column() {
        Text('· 任务名，如「星链」「嫦娥」').fontSize(12).fontColor(TEXT_DIM).padding({ top: 12 })
        Text('· 火箭型号，如「猎鹰 9」「长征」').fontSize(12).fontColor(TEXT_DIM).padding({ top: 8 })
        Text('· 宇航员，如「杨利伟」「Wang」').fontSize(12).fontColor(TEXT_DIM).padding({ top: 8 })
        Text('· 发射工位，如「文昌」「SpaceX」').fontSize(12).fontColor(TEXT_DIM).padding({ top: 8 })
        Text('· 机构，如「NASA」「中国航天」').fontSize(12).fontColor(TEXT_DIM).padding({ top: 8 })
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 4 })

      Text('卫星请到「太空资产 · 卫星百科」页内搜索')
        .fontSize(11).fontColor(TEXT_DIM).margin({ top: 22 })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  build() {
    Column() {
      this.topBar()
      this.searchBar()

      if (this.kw.trim().length === 0) {
        this.tipsBlock()
      } else if (this.groups.length === 0) {
        if (this.loading) {
          this.loadingBlock()
        } else {
          this.emptyBlock()
        }
      } else {
        Scroll() {
          Column() {
            ForEach(this.groups, (g: SeGroup) => {
              this.groupBlock(g)
            }, (g: SeGroup) => g.title)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
    .alignItems(HorizontalAlign.Start)
  }
}
