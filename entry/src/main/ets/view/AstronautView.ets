/**
 * view/AstronautView.ets —— 航天员详情页（对位小程序 pages/astronaut/astronaut.vue）
 *
 * 本文件由路由方（DetailPages.ets:298）以 `<AstronautView astronautId={id}>` 挂进 NavDestination，
 * 入参只有 id（string，调用方负责 toString）。返回走 Nav.pop()。
 *
 * ── 数据链路：先 peek 再 load ──
 *   repo.peek<T>(name)  同步、只查内存+文件，零网络
 *   repo.load<T>(name, { onUpdate })
 *     onUpdate 只在「缓存过期 + 后台刷新拿到新数据」时才回调，用来静默回填
 *
 *   astronauts.json 是 862 条 / 约 700KB 的大集合，进这一页**不该**再拉一遍全量：
 *   只要缓存里有，peek 就能立刻上屏；缓存为空时才真正走一次网络（冷启动首进）。
 *
 * ── 三个数据集，各自兜底 ──
 *   主线：astronauts（决定 found / 未找到）
 *   副线：spacestations + expeditions（只用于「所属空间站 / 参与远征队」两张反向索引卡）
 *   副线任何一个 404 都不能拖累主流程 —— 与小程序 onLoad 里两个独立 try 同口径：
 *   拿不到就那两张卡不画，人还是要显示出来。
 *
 * ── 「所属空间站」照抄小程序，且只照抄 ──
 *   小程序是 `allStations.filter(s => (s.crew||[]).some(m => m.id === id))`，
 *   线上 spacestations.json 的 15 条 crew 实测**全是空数组**（model/Station.ets:13
 *   写死了这条实测结论），所以这张卡在小程序里当前也永远不出现 —— 两边一致。
 *   曾经加过第二级「远征队 stationId 反推」，已撤掉：那会让老航天员凭空长出
 *   小程序没有的卡片，与「逐页对齐」相反。数据侧补齐 crew 后这里自动出卡，不用改。
 *
 * ── 姓名为什么可以读 nameZh ──
 *   model/Astronaut.ets 刻意没声明 nameZh（产品约定「中文名优先走前端专名表」），
 *   但线上 862 条里 830 条 nameZh 非空，是 CI 的 fillAstronautNames() 回填的，
 *   比 CHINA_ASTRO_ZH（只覆盖中国籍 31 人）全得多。本文件用 AstroFull 扩展一层拿到它，
 *   查不到再退 astroName()（中国人走专名表，其他人保留原文）—— 编错名字比显示拼音更糟。
 *
 * ── 三态（对齐小程序，不再区分「加载失败」）──
 *   小程序只有 loading / empty / content 三态，load 失败时 a 为空，落到同一个 empty。
 *   这里保持同口径；失败只打 hilog，不再单独给「点此重试」——
 *   一个只有 862 条静态数据的人，显示「未找到」比显示「网络不给力」更接近真相。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。不使用 AppStorage。无定时器。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { Astronaut, AstronautMission, AstronautEva, AstronautsPayload } from '../model/Astronaut';
import { BasePayload } from '../model/Common';
import { StnItem, StnCrew, StnPayload, stnStatusText } from '../model/Station';
import {
  strOf, astroName, nationZh, agencyLabel, destName, dayOf, descText, descNeedFold,
  expeditionName, stationName
} from '../utils/Format';
import { Nav } from '../routes/Nav';
import { LaunchNavParam, StationNavParam, ExpeditionNavParam, PhotoNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'AstronautView';

// ============ 视觉常量（数值取自小程序 wxss，rpx ÷ 2 = vp） ============

// 颜色一律用 #AARRGGBB：工程既有文件（FloatingTabBar.ets:100 的 '#2938BDF8'）就是这个写法，
// 而 CSS 的 rgba() 串在 ArkUI 里虽然多数场合能认，但 Divider/边框这类老接口上不稳，
// 统一转成 8 位 hex 最省心。换算方式：alpha×255 取整 → 两位 hex。
const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
/** 小程序卡片边框 1rpx rgba(255,255,255,.05) → 0.05×255 ≈ 0x0D */
const CARD_LINE: string = '#0DFFFFFF';
const CARD_RADIUS: number = 10;
/** 卡片自带左右边距 16（根容器不再统一 PAGE_PAD，卡片各管各的） */
const CARD_SIDE: number = 16;
const CARD_TOP: number = 12;
const CARD_PAD_V: number = 12;
const CARD_PAD_H: number = 16;

const TEXT_NAME: string = '#E2E8F0';
const TEXT_DIM: string = '#55617A';
/** 标签字 / KPI 标签 / 生卒行 / 副行：小程序统一 #6b7891 */
const TEXT_LABEL: string = '#6B7891';
const TEXT_DESC: string = '#C6CFDD';
const TEXT_MUTED: string = '#94A3B8';
/** 页脚 / 箭头：比三级灰再暗一档 */
const TEXT_FOOT: string = '#3D4A5C';
const ACCENT: string = '#38BDF8';

/** rgba(255,255,255,.06) → 0x0F */
const TAG_BG: string = '#0FFFFFFF';
/** rgba(56,189,248,.16) → 0x29；与 FloatingTabBar 选中态同值 */
const TAG_ON_BG: string = '#2938BDF8';
/** rgba(255,255,255,.05) → 0x0D */
const TAG_DIM_BG: string = '#0DFFFFFF';
/** rgba(56,189,248,.1) → 0x1A */
const DEST_BG: string = '#1A38BDF8';
/** rgba(56,189,248,.14) → 0x24 */
const DOT_HALO: string = '#2438BDF8';
/** rgba(255,255,255,.04) → 0x0A */
const ROW_LINE: string = '#0AFFFFFF';
/** 证件照描边 rgba(255,255,255,.06) → 0x0F */
const AVATAR_LINE: string = '#0FFFFFFF';
/** 顶栏返回键的圆形半透明黑底（小程序 nav-bar 的胶囊返回）：rgba(0,0,0,.35) → 0x59 */
const NAV_BTN_BG: string = '#59000000';

/** 证件照 84vp（小程序 168rpx） */
const AVATAR: number = 84;
/** 顶栏高度：32 圆钮 + 上下 8 */
const NAV_H: number = 48;
const BOTTOM_PAD: number = 32;

/** 简介折叠 4 行（小程序 -webkit-line-clamp: 4） */
const BIO_FOLD_LINES: number = 4;
/**
 * 超过 120 字符才给「展开全文」。
 * 与小程序 descNeedFoldOf(this.bioText) 不传 limit 时的默认阈值一致
 * （utils/Format.ets:1377 的 descNeedFold 缺省也是 120），按字符数比、不看 textUnits。
 */
const BIO_FOLD_MIN: number = 120;
const AVATAR_PLACEHOLDER: string = '🧑‍🚀';

// ============ 类型（本文件专用，统一 Astro 前缀） ============

/**
 * Astronaut 的扩展视图。
 * 只加一个 nameZh —— 数据里本来就有，只是 model 层按产品约定没声明。
 */
interface AstroFull extends Astronaut {
  nameZh?: string;
}

/** expeditions.json 的乘组成员。字段与 ExpeditionView.ets 的 ExpCrew 同构，这里重声明避免 view 互引 */
interface AstroExpCrew {
  id?: number;
  name?: string;
  role?: string;
  agency?: string;
  img?: string;
}

/** expeditions.json 的一条。id / stationId 是 number，路由参数是 string，比对统一 String() */
interface AstroExpItem {
  id?: number;
  name?: string;
  start?: string;
  end?: string;
  stationId?: number;
  stationName?: string;
  crew?: AstroExpCrew[];
}

interface AstroExpPayload extends BasePayload {
  list: AstroExpItem[];
}

/**
 * 反向索引的一行（空间站）。
 * 用 class 而不是对象字面量：ArkTS 禁止无类型对象字面量，先 new 再 push。
 */
class AstroStnRef {
  id: string = '';
  name: string = '';
  sub: string = '';

  constructor(id: string, name: string, sub: string) {
    this.id = id;
    this.name = name;
    this.sub = sub;
  }
}

/** 反向索引的一行（远征队） */
class AstroExpRef {
  id: string = '';
  name: string = '';
  sub: string = '';

  constructor(id: string, name: string, sub: string) {
    this.id = id;
    this.name = name;
    this.sub = sub;
  }
}

// ============ 纯函数（放模块级，避免每次重绘重建闭包） ============

/** 状态中文：LL2 枚举 Active/Retired/Deceased/In space/Unknown（与小程序 statusZh 一致） */
function astroStatusZh(status: string): string {
  const s: string = strOf(status).trim();
  if (s === 'Active') {
    return '现役';
  }
  if (s === 'Retired') {
    return '退役';
  }
  if (s === 'Deceased') {
    return '已故';
  }
  if (s === 'In space') {
    return '在轨';
  }
  if (s === 'Unknown') {
    return '未知';
  }
  return '';
}

/** undefined / <=0 一律 →「—」：0 天 / 0 小时在这份数据里表示「没统计到」，画成 0 会被读成事实 */
function numCell(v: number | undefined): string {
  if (v === undefined || v <= 0) {
    return '—';
  }
  return String(v);
}

/**
 * ISO 日期 → 「1978 年 2 月 27 日」。
 *
 * 为什么不构造 Date：数据是 UTC 零补位串，东八区会跨零点推一天——
 * 与 dayOf() 的注释同一个理由（utils/Format.ets:160-164）。
 * 也不做正则捕获组：纯 substring + Number 判定，ArkTS 对下标访问更宽容。
 */
function cnDay(v: string): string {
  const s: string = strOf(v).trim();
  if (s.length < 7) {
    return '';
  }
  const y: string = s.substring(0, 4);
  const year: number = Number(y);
  // NaN 参与任何比较都是 false，所以 !(year > 0) 同时挡住空串与非法年份
  if (!(year > 0)) {
    return '';
  }
  const mon: number = Number(s.substring(5, 7));
  if (!(mon > 0)) {
    return '';
  }
  const head: string = y + ' 年 ' + String(mon) + ' 月';
  if (s.length < 10) {
    return head;
  }
  const day: number = Number(s.substring(8, 10));
  if (!(day > 0)) {
    return head;
  }
  return head + ' ' + String(day) + ' 日';
}

/** 非空片段用 «空格 · 空格» 连起来，空串不占位置（不出 " ·  · ISS" 这种残缺分隔） */
function joinParts(parts: string[]): string {
  return parts.join(' · ');
}

/** 远征队起止：「2024-03-05 — 至今」；start 缺失时只给「至今」 */
function expRange(start: string, end: string): string {
  const s: string = dayOf(start);
  const tail: string = dayOf(end).length > 0 ? dayOf(end) : '至今';
  return s.length > 0 ? s + ' — ' + tail : tail;
}

/** 空间站名册里有没有我。crew 实测全空，这里做成通用函数等数据补齐 */
function stnCrewHas(crew: StnCrew[] | undefined, key: string): boolean {
  if (crew === undefined) {
    return false;
  }
  for (let i = 0; i < crew.length; i++) {
    const id: number | undefined = crew[i].id;
    if (id !== undefined && String(id) === key) {
      return true;
    }
  }
  return false;
}

/** 远征队名册里有没有我（expeditions.json 的 crew 实测是有内容的） */
function expCrewHas(crew: AstroExpCrew[] | undefined, key: string): boolean {
  if (crew === undefined) {
    return false;
  }
  for (let i = 0; i < crew.length; i++) {
    const id: number | undefined = crew[i].id;
    if (id !== undefined && String(id) === key) {
      return true;
    }
  }
  return false;
}

/** number → 非空字符串；undefined 返回空串（路由参数不接受 undefined） */
function idText(v: number | undefined): string {
  return v !== undefined ? String(v) : '';
}

@Component
export struct AstronautView {
  /** 航天员 id。注意是 string —— 入参由路由那边 toString 后传进来 */
  @Prop astronautId: string = '';

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，不挡返回栏） */
  @State loading: boolean = true;
  /** 是否拿到了这条记录 */
  @State found: boolean = false;

  /** 展示名（nameZh 优先，其次专名表，最后原名） */
  @State astName: string = '';
  /** 状态中文（现役 / 退役 / 已故 …） */
  @State astStatus: string = '';
  /** 此刻是否在轨 */
  @State astInSpace: boolean = false;
  /** 已故：状态章要压暗（小程序 tag-dim），年龄标签也随之隐藏 */
  @State astDeceased: boolean = false;
  /** 国籍中文 */
  @State astNation: string = '';
  /** 机构短名 */
  @State astAgency: string = '';
  /** 年龄标签（在世才显示，形如 "46 岁"；空串 = 不画这颗胶囊） */
  @State ageText: string = '';

  /** 头像地址 */
  @State avatarUrl: string = '';
  /** 头像加载失败 → 退回 emoji 占位，避免破图 */
  @State avatarErr: boolean = false;

  /** 生卒行（「生于 …」或「… — …」） */
  @State lifeText: string = '';

  /** KPI 四格（已格式化，— 表示无值） */
  @State daysText: string = '—';
  @State flightsText: string = '—';
  @State walkText: string = '—';
  @State evaHoursText: string = '—';

  /** 简介正文（bioZh || bio） */
  @State bioText: string = '';
  /** 简介是否已展开 */
  @State bioExpanded: boolean = false;

  /** 飞行任务（原样保留 model 结构，渲染时再取字段） */
  @State missionList: AstronautMission[] = [];
  /** 出舱记录 */
  @State evaList: AstronautEva[] = [];

  /** 资料卡：出生 / 逝世日期文本 */
  @State dobText: string = '';
  @State dodText: string = '';
  /** 三个外链原值，空串 = 不画那一行 */
  @State wikiUrl: string = '';
  @State twitterUrl: string = '';
  @State instaUrl: string = '';
  /** 资料卡是否有任何一行可画（小程序 hasProfile） */
  @State hasProfile: boolean = false;

  /** 反向索引：所属空间站 / 参与远征队 */
  @State stnRefs: AstroStnRef[] = [];
  @State expRefs: AstroExpRef[] = [];

  /** 反查原料（不参与渲染，故不做 @State，省掉无谓的重绘） */
  private allStations: StnItem[] = [];
  private allExps: AstroExpItem[] = [];
  /** 反查用的 id 文本（applyAstronaut 时落一次） */
  private astroKey: string = '';

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.reload(false);
    // 无定时器、无监听、无长连接，aboutToDisappear 无事可做，故不实现
  }

  // ============ 加载 ============

  /**
   * 先 peek 再 load。
   *
   * peek 是同步的（内存 + 文件），冷启动能立刻把详情画出来；
   * 三个数据集各自 peek 一次，谁有缓存谁先落地，互不阻塞。
   * force=true 只给将来可能的「绕过缓存」用（当前三态里没有重试入口，保留参数以免改签名）。
   */
  private reload(force: boolean): void {
    this.loading = true;

    const cachedAstro: AstronautsPayload | null = repo.peek<AstronautsPayload>('astronauts');
    if (cachedAstro !== null) {
      this.applyPayload(cachedAstro);
    }
    const cachedStn: StnPayload | null = repo.peek<StnPayload>('spacestations');
    if (cachedStn !== null) {
      this.applyStations(cachedStn);
    }
    const cachedExp: AstroExpPayload | null = repo.peek<AstroExpPayload>('expeditions');
    if (cachedExp !== null) {
      this.applyExpeditions(cachedExp);
    }
    if (this.found) {
      // 缓存就命中 → 立刻收掉 loading，不等网络（后台刷新照常进行）
      this.loading = false;
    }

    const astroOpts: LoadOptions<AstronautsPayload> = {
      force: force,
      onUpdate: (fresh: AstronautsPayload) => {
        // 后台刷新只做回填；找不到就保持现有画面，不把已渲染的页打回「未找到」
        this.applyPayload(fresh);
      }
    };
    repo.load<AstronautsPayload>('astronauts', astroOpts)
      .then((data: AstronautsPayload) => {
        // 命中缓存时 resolve 的就是缓存值，重复落地一次无害（幂等）
        this.applyPayload(data);
        this.loading = false;
      })
      .catch((e: BusinessError) => {
        // 小程序同口径：拿不到就当没有，落到 empty；不额外做「加载失败」态
        this.loading = false;
        hilog.warn(DOMAIN, TAG, 'astronauts 加载失败: %{public}s', e.message);
      });

    const stnOpts: LoadOptions<StnPayload> = {
      force: force,
      onUpdate: (fresh: StnPayload) => {
        this.applyStations(fresh);
      }
    };
    repo.load<StnPayload>('spacestations', stnOpts)
      .then((data: StnPayload) => {
        this.applyStations(data);
      })
      .catch((e: BusinessError) => {
        // 副线失败只影响「所属空间站」卡，不拖累主流程
        hilog.warn(DOMAIN, TAG, 'spacestations 加载失败（反向索引暂不显示）: %{public}s', e.message);
      });

    const expOpts: LoadOptions<AstroExpPayload> = {
      force: force,
      onUpdate: (fresh: AstroExpPayload) => {
        this.applyExpeditions(fresh);
      }
    };
    repo.load<AstroExpPayload>('expeditions', expOpts)
      .then((data: AstroExpPayload) => {
        this.applyExpeditions(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'expeditions 加载失败（反向索引暂不显示）: %{public}s', e.message);
      });
  }

  /**
   * 取载荷里的 list。
   *
   * 为什么不直接写 `data.list !== undefined ? data.list : []`：
   * 载荷里的 list 在 interface 上是**必填**的，拿必填类型和 undefined 做比较
   * 会被 ArkTS 判成「两个类型无重叠」而报错。先赋给显式可空的局部变量，
   * 既绕开类型层面，又保住运行时兜底（旧缓存里 list 真有可能缺）。
   */
  private listOf(data: AstronautsPayload): Astronaut[] {
    const maybe: Astronaut[] | undefined = data.list;
    return maybe !== undefined ? maybe : [];
  }

  private stnListOf(data: StnPayload): StnItem[] {
    const maybe: StnItem[] | undefined = data.list;
    return maybe !== undefined ? maybe : [];
  }

  private expListOf(data: AstroExpPayload): AstroExpItem[] {
    const maybe: AstroExpItem[] | undefined = data.list;
    return maybe !== undefined ? maybe : [];
  }

  /** 主数据落地：从载荷里找到这一条 → 拆到各个 @State */
  private applyPayload(data: AstronautsPayload): void {
    const hit: Astronaut | null = this.findAstronautIn(this.listOf(data));
    if (hit === null) {
      // 已找到过就保持原样：中途一次半截数据不该把整页清空
      return;
    }
    this.applyAstronaut(hit);
  }

  private applyStations(data: StnPayload): void {
    this.allStations = this.stnListOf(data);
    this.rebuildRefs();
  }

  private applyExpeditions(data: AstroExpPayload): void {
    this.allExps = this.expListOf(data);
    this.rebuildRefs();
  }

  /**
   * 按 id 定位。id 在 model 里是 number，入参是 string，统一 String() 比较。
   * 返回 null 表示「这一版载荷里没有他」，最终落到未找到态。
   */
  private findAstronautIn(list: Astronaut[]): Astronaut | null {
    const target: string = strOf(this.astronautId).trim();
    if (target.length === 0) {
      return null;
    }
    for (let i = 0; i < list.length; i++) {
      const item: Astronaut = list[i];
      // item.id 在 model 里是必填 number，所以不做 undefined 判定
      // （number 与 undefined 做 === 比较会被判成「两个类型无重叠」而报错）
      if (item !== null && item !== undefined && String(item.id) === target) {
        return item;
      }
    }
    return null;
  }

  /** 一条记录 → 页面状态。所有字段都过一遍空值判定，不留 undefined 到 UI */
  private applyAstronaut(a: Astronaut): void {
    // nameZh 是数据里有、model 层没声明的字段，靠 AstroFull 扩展读出来
    const full: AstroFull = a as AstroFull;
    const zhFromData: string = strOf(full.nameZh).trim();
    // 专名表兜底：China 籍走 CHINA_ASTRO_ZH，其余原样返回
    const zhFromTable: string = astroName(strOf(a.name), strOf(a.nation)).trim();
    this.astName = zhFromData.length > 0 ? zhFromData : (zhFromTable.length > 0 ? zhFromTable : strOf(a.name).trim());

    this.astStatus = astroStatusZh(strOf(a.status));
    this.astInSpace = a.inSpace === true;
    this.astDeceased = strOf(a.status).trim() === 'Deceased';
    this.astNation = nationZh(strOf(a.nation));
    this.astAgency = agencyLabel(strOf(a.agencyName));

    // 年龄只在世时给（小程序 `v-if="a.age && !a.dod"`）：
    // 已故的人显示「86 岁」会被读成「还活着的老先生」，这是硬错误
    const age: number | null | undefined = a.age;
    const alive: boolean = strOf(a.dod).trim().length === 0;
    this.ageText = age !== null && age !== undefined && age > 0 && alive ? String(age) + ' 岁' : '';

    const dobRaw: string = strOf(a.dob).trim();
    const dodRaw: string = strOf(a.dod).trim();
    // 解析失败就退回原始串（小程序的 fmtDayText 也是「非日期串原样返回」），
    // 否则一个格式异常的生卒日期会顺手把整张资料卡判成「没有资料」
    const dobCn: string = cnDay(dobRaw);
    const dodCn: string = cnDay(dodRaw);
    const dob: string = dobCn.length > 0 ? dobCn : dobRaw;
    const dod: string = dodCn.length > 0 ? dodCn : dodRaw;
    if (dob.length === 0) {
      this.lifeText = '';
    } else {
      // 健在只给生日，逝世给生卒区间 —— 与小程序的 birthText 一模一样
      this.lifeText = dod.length > 0 ? dob + ' — ' + dod : '生于 ' + dob;
    }

    this.avatarUrl = strOf(a.img).trim();
    // 换人时不继承上一条的破图标记
    this.avatarErr = false;

    this.daysText = numCell(a.days);
    this.flightsText = numCell(a.flights);
    this.walkText = numCell(a.spacewalks);
    const evaH: string = numCell(a.evaHours);
    // 「—」不加 h：没有数据时写「—h」像是「0 小时」
    this.evaHoursText = evaH === '—' ? '—' : evaH + 'h';

    this.bioText = descText(strOf(a.bioZh), strOf(a.bio)).trim();
    this.bioExpanded = false;

    const missions: AstronautMission[] = a.missions !== undefined ? a.missions : [];
    this.missionList = missions;

    const evas: AstronautEva[] = a.evas !== undefined ? a.evas : [];
    this.evaList = evas;

    // 资料卡：任一字段有值就出卡（小程序 hasProfile 同构）
    this.dobText = dob;
    this.dodText = dod;
    this.wikiUrl = strOf(a.wiki).trim();
    this.twitterUrl = strOf(a.twitter).trim();
    this.instaUrl = strOf(a.instagram).trim();
    this.hasProfile = this.dobText.length > 0 || this.dodText.length > 0
      || this.wikiUrl.length > 0 || this.twitterUrl.length > 0 || this.instaUrl.length > 0;

    this.astroKey = String(a.id);
    this.found = true;
    // 主数据可能晚于副线到达，这里补算一次
    this.rebuildRefs();
  }

  // ============ 反向索引 ============

  /**
   * 反向索引，两条独立：
   *   一、所属空间站：本宇航员出现在哪几座空间站的「当前乘组」里。
   *   二、参与远征队：expeditions.json 的 crew 里含我。
   *
   * ⚠ 空间站这一条**只按 crew 命中，不做任何次级反推**。
   * 小程序的 myStations()（astronaut.vue:266-270）就是
   * `allStations.filter(s => (s.crew || []).some(m => String(m.id) === id))`，
   * 一行业务逻辑都不多。曾经写过第二级「本人在远征队 crew 里 → 该远征队的 stationId → 反推站」，
   * 那是错的：spacestations.json 的 crew 当前 15 条实测全空，小程序因此**永远不显示这张卡**；
   * 我们靠远征队反推，会让历史上所有没在站的老航天员都凭空长出一张「所属空间站」，
   * 那是小程序没有的内容，与「逐页对齐」的目标正好相反。
   * 数据侧补齐 crew 之后，这里不需要改一个字就会自动出卡。
   *
   * 两个数据源都可能还没到，所以任何一个到达都重算一次（幂等，结果只由原料决定）。
   */
  private rebuildRefs(): void {
    const key: string = this.astroKey;
    if (key.length === 0) {
      this.stnRefs = [];
      this.expRefs = [];
      return;
    }

    const expOut: AstroExpRef[] = [];
    for (let i = 0; i < this.allExps.length; i++) {
      const e: AstroExpItem = this.allExps[i];
      if (!expCrewHas(e.crew, key)) {
        continue;
      }
      const eid: string = idText(e.id);
      if (eid.length > 0) {
        expOut.push(new AstroExpRef(eid, expeditionName(strOf(e.name)), expRange(strOf(e.start), strOf(e.end))));
      }
    }

    const stnOut: AstroStnRef[] = [];
    for (let i = 0; i < this.allStations.length; i++) {
      const s: StnItem = this.allStations[i];
      if (!stnCrewHas(s.crew, key)) {
        continue;
      }
      const sid: string = idText(s.id);
      if (sid.length === 0) {
        continue;
      }
      stnOut.push(new AstroStnRef(sid, stationName(strOf(s.name)), stnStatusText(s.status)));
    }

    this.stnRefs = stnOut;
    this.expRefs = expOut;
  }

  // ============ 交互 ============

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  /**
   * 复制链接。
   *
   * 详情页打不开外部网页（小程序 web-view 也受业务域名限制，源实现同样是「复制链接」），
   * 所以三处外链一律写剪贴板 + toast，用户在浏览器里粘贴。
   */
  private copyLink(url: string, label: string): void {
    const u: string = strOf(url).trim();
    if (u.length === 0) {
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, u);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => {
        this.toast(label + '链接已复制');
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '复制链接失败 code=%{public}d', e.code);
        this.toast('复制失败，请稍后重试');
      });
  }

  /** 点证件照 → 全屏看图（对应小程序 previewImage） */
  private openPhoto(): void {
    if (this.avatarUrl.length === 0 || this.avatarErr) {
      return;
    }
    Nav.pushPhoto(new PhotoNavParam(this.avatarUrl, this.astName));
  }

  /**
   * 点飞行任务 → 发射详情。
   * AstronautMission.id 就是 LL2 发射 UUID，有才跳；没有就整行不响应
   * （旧数据/归档缺失时点过去也只会看到「未找到」）。
   */
  private openMission(m: AstronautMission): void {
    const id: string = strOf(m.id).trim();
    if (id.length === 0) {
      return;
    }
    Nav.pushLaunch(new LaunchNavParam(id, strOf(m.net), this.missionName(m)));
  }

  private openStation(ref: AstroStnRef): void {
    if (ref.id.length === 0) {
      return;
    }
    Nav.pushStation(new StationNavParam(ref.id));
  }

  private openExpedition(ref: AstroExpRef): void {
    if (ref.id.length === 0) {
      return;
    }
    Nav.pushExpedition(new ExpeditionNavParam(ref.id));
  }

  // ============ 派生文案 ============

  private bioLines(): number {
    // 展开时给一个大而有效的行数（不用 Infinity，避免布局测量异常）
    return this.bioExpanded ? 400 : BIO_FOLD_LINES;
  }

  private canExpandBio(): boolean {
    return descNeedFold(this.bioText, BIO_FOLD_MIN);
  }

  /** 任务主标题：name（CI 已从 "火箭 | 任务" 里拆好）→ 火箭名 → 兜底 */
  private missionName(m: AstronautMission): string {
    const n: string = strOf(m.name).trim();
    if (n.length > 0) {
      return n;
    }
    const rk: string = strOf(m.rk).trim();
    return rk.length > 0 ? rk : '未命名任务';
  }

  /** 任务副行：只留「火箭 · 日期」，目的地单独做右侧胶囊（小程序 flight-side） */
  private missionSub(m: AstronautMission): string {
    const parts: string[] = [];
    const rk: string = strOf(m.rk).trim();
    if (rk.length > 0) {
      parts.push(rk);
    }
    const day: string = dayOf(strOf(m.net));
    if (day.length > 0) {
      parts.push(day);
    }
    return joinParts(parts);
  }

  /** 目的地胶囊文案；空串 = 不画胶囊 */
  private missionDest(m: AstronautMission): string {
    const raw: string = strOf(m.dest).trim();
    if (raw.length === 0) {
      return '';
    }
    return destName(raw).trim();
  }

  private evaName(e: AstronautEva): string {
    const n: string = strOf(e.name).trim();
    return n.length > 0 ? n : '出舱活动';
  }

  private evaSub(e: AstronautEva): string {
    const parts: string[] = [];
    const day: string = dayOf(strOf(e.start));
    if (day.length > 0) {
      parts.push(day);
    }
    const loc: string = strOf(e.loc).trim();
    if (loc.length > 0) {
      parts.push(loc);
    }
    return joinParts(parts);
  }

  private evaHoursTextOf(e: AstronautEva): string {
    // 先落局部变量再判：ArkTS 对可选属性的类型收窄不可靠
    const h: number | undefined = e.h;
    if (h === undefined || h <= 0) {
      return '';
    }
    return String(h) + ' 小时';
  }

  // ============ UI：顶栏（圆形返回键 + 居中标题，对位 nav-bar） ============

  @Builder
  topBar() {
    Stack({ alignContent: Alignment.Start }) {
      // 标题先画（处于底层），返回键后画浮在上面，点击不会被标题的空白区吞掉。
      // lineHeight 直接给 NAV_H：单行文字的垂直居中交给行高做，
      // 比在 Stack 上找「垂直居中」属性（Stack 没有 alignItems）稳。
      Text('航天员')
        .fontSize(23)
        .fontWeight(600)
        .fontColor(TEXT_NAME)
        .width('100%')
        .height(NAV_H)
        .lineHeight(NAV_H)
        .textAlign(TextAlign.Center)

      // Stack 的 alignContent 是 Start，所以 32 圆钮要自己压 (48-32)/2 = 8 才垂直居中
      Row() {
        Text('‹')
          .fontSize(23)
          .fontColor(TEXT_NAME)
          .lineHeight(23)
          // ‹ 的视觉重心偏上，压 2vp 才在圆钮里看着居中
          .margin({ top: -2 })
      }
      .width(32)
      .height(32)
      .borderRadius(16)
      .backgroundColor(NAV_BTN_BG)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .margin({ left: CARD_SIDE, top: (NAV_H - 32) / 2 })
      .onClick(() => {
        Nav.pop();
      })
    }
    .width('100%')
    .height(NAV_H)
  }

  // ============ UI：标签（四类胶囊横排，Flex 才能换行） ============

  @Builder
  tagRow() {
    // 多行 Flow 容器：Row 不支持换行（没有 flex-wrap 属性），换行只能用 Flex
    Flex({ wrap: FlexWrap.Wrap }) {
      if (this.astInSpace) {
        Text('在轨')
          .fontSize(10)
          .fontColor(ACCENT)
          .backgroundColor(TAG_ON_BG)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius(3)
          .margin({ right: 5, bottom: 4 })
      } else if (this.astStatus.length > 0) {
        // 已故用 tag-dim 压暗，别把「已故」染成任何亮色
        Text(this.astStatus)
          .fontSize(10)
          .fontColor(this.astDeceased ? TEXT_DIM : TEXT_LABEL)
          .backgroundColor(this.astDeceased ? TAG_DIM_BG : TAG_BG)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius(3)
          .margin({ right: 5, bottom: 4 })
      }

      if (this.astAgency.length > 0) {
        Text(this.astAgency)
          .fontSize(10)
          .fontColor(TEXT_LABEL)
          .backgroundColor(TAG_BG)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius(3)
          .margin({ right: 5, bottom: 4 })
      }

      if (this.astNation.length > 0) {
        Text(this.astNation)
          .fontSize(10)
          .fontColor(TEXT_LABEL)
          .backgroundColor(TAG_BG)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius(3)
          .margin({ right: 5, bottom: 4 })
      }

      if (this.ageText.length > 0) {
        Text(this.ageText)
          .fontSize(10)
          .fontColor(TEXT_LABEL)
          .backgroundColor(TAG_BG)
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius(3)
          .margin({ right: 5, bottom: 4 })
      }
    }
    .width('100%')
    .margin({ top: 7 })
  }

  // ============ UI：头部（横排证件照 + 姓名/标签/生卒） ============

  @Builder
  headBlock() {
    Row() {
      // 84×84 证件照，可点开大图；破图退回 emoji 占位
      if (this.avatarUrl.length > 0 && !this.avatarErr) {
        Image(this.avatarUrl)
          .width(AVATAR)
          .height(AVATAR)
          .objectFit(ImageFit.Cover)
          .borderRadius(CARD_RADIUS)
          .backgroundColor(CARD_BG)
          .border({ width: 1, color: AVATAR_LINE })
          .onError(() => {
            this.avatarErr = true;
          })
          .onClick(() => {
            this.openPhoto();
          })
      } else {
        Column() {
          Text(AVATAR_PLACEHOLDER)
            .fontSize(36)
        }
        .width(AVATAR)
        .height(AVATAR)
        .backgroundColor(CARD_BG)
        .borderRadius(CARD_RADIUS)
        .border({ width: 1, color: AVATAR_LINE })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      Column() {
        Text(this.astName)
          .fontSize(18)
          .fontWeight(600)
          .fontColor(TEXT_NAME)
          // 18 × 1.3 ≈ 23（ArkUI 的 lineHeight 是绝对 fp，不是倍数）
          .lineHeight(23)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        this.tagRow()

        if (this.lifeText.length > 0) {
          Text(this.lifeText)
            .fontSize(11)
            .fontColor(TEXT_LABEL)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 14 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: CARD_SIDE, right: CARD_SIDE, top: 8, bottom: 4 })
  }

  // ============ UI：KPI 四格 ============

  @Builder
  kpiBlock() {
    Row() {
      Column() {
        Text(this.daysText)
          .fontSize(16)
          .fontWeight(600)
          .fontColor(ACCENT)
        Text('累计在轨（天）')
          .fontSize(10)
          .fontColor(TEXT_LABEL)
          .maxLines(1)
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Column() {
        Text(this.flightsText)
          .fontSize(16)
          .fontWeight(600)
          .fontColor(ACCENT)
        Text('飞行次数')
          .fontSize(10)
          .fontColor(TEXT_LABEL)
          .maxLines(1)
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Column() {
        Text(this.walkText)
          .fontSize(16)
          .fontWeight(600)
          .fontColor(ACCENT)
        Text('出舱次数')
          .fontSize(10)
          .fontColor(TEXT_LABEL)
          .maxLines(1)
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)

      Column() {
        Text(this.evaHoursText)
          .fontSize(16)
          .fontWeight(600)
          .fontColor(ACCENT)
        Text('累计出舱')
          .fontSize(10)
          .fontColor(TEXT_LABEL)
          .maxLines(1)
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 小程序 kpi：padding 24rpx 0 → 上下 12、左右 0
    .padding({ left: 0, right: 0, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ left: CARD_SIDE, right: CARD_SIDE, top: 14 })
  }

  // ============ UI：简介 ============

  @Builder
  bioBlock() {
    Column() {
      Text('简介')
        .fontSize(12)
        .fontColor(TEXT_MUTED)
        .margin({ bottom: 7 })

      Text(this.bioText)
        .fontSize(13)
        .fontColor(TEXT_DESC)
        // 13 × 1.7 ≈ 22
        .lineHeight(22)
        .maxLines(this.bioLines())
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (this.canExpandBio()) {
        Text(this.bioExpanded ? '收起' : '展开全文')
          .fontSize(12)
          .fontColor(ACCENT)
          .margin({ top: 6 })
          .onClick(() => {
            this.bioExpanded = !this.bioExpanded;
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: CARD_LINE })
    .margin({ left: CARD_SIDE, right: CARD_SIDE, top: CARD_TOP })
  }

  // ============ UI：所属空间站 ============

  @Builder
  stationBlock() {
    Column() {
      Text('所属空间站')
        .fontSize(12)
        .fontColor(TEXT_MUTED)
        .margin({ bottom: 7 })

      ForEach(this.stnRefs, (ref: AstroStnRef, i: number) => {
        // 单根 Column：分隔线挂在行内，避免 ForEach 生成多个根节点
        Column() {
          Row() {
            Column() {
              Text(ref.name)
                .fontSize(13.5)
                .fontColor(TEXT_NAME)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              if (ref.sub.length > 0) {
                Text(ref.sub)
                  .fontSize(11)
                  .fontColor(TEXT_LABEL)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 2 })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text('›')
              .fontSize(15)
              .fontColor(TEXT_FOOT)
              .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            this.openStation(ref);
          })

          if (i < this.stnRefs.length - 1) {
            Divider()
              .color(ROW_LINE)
              .strokeWidth(1)
          }
        }
        .width('100%')
      }, (ref: AstroStnRef, i: number) => ref.id + '#' + String(i))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: CARD_LINE })
    .margin({ left: CARD_SIDE, right: CARD_SIDE, top: CARD_TOP })
  }

  // ============ UI：参与远征队 ============

  @Builder
  expBlock() {
    Column() {
      Text('参与远征队')
        .fontSize(12)
        .fontColor(TEXT_MUTED)
        .margin({ bottom: 7 })

      ForEach(this.expRefs, (ref: AstroExpRef, i: number) => {
        Column() {
          Row() {
            Column() {
              Text(ref.name)
                .fontSize(13.5)
                .fontColor(TEXT_NAME)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              if (ref.sub.length > 0) {
                Text(ref.sub)
                  .fontSize(11)
                  .fontColor(TEXT_LABEL)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 2 })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text('›')
              .fontSize(15)
              .fontColor(TEXT_FOOT)
              .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            this.openExpedition(ref);
          })

          if (i < this.expRefs.length - 1) {
            Divider()
              .color(ROW_LINE)
              .strokeWidth(1)
          }
        }
        .width('100%')
      }, (ref: AstroExpRef, i: number) => ref.id + '#' + String(i))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: CARD_LINE })
    .margin({ left: CARD_SIDE, right: CARD_SIDE, top: CARD_TOP })
  }

  // ============ UI：飞行任务 ============

  @Builder
  missionBlock() {
    Column() {
      Text('飞行任务')
        .fontSize(12)
        .fontColor(TEXT_MUTED)
        .margin({ bottom: 7 })

      ForEach(this.missionList, (m: AstronautMission, i: number) => {
        Column() {
          Row() {
            Column() {
              Text(this.missionName(m))
                .fontSize(13.5)
                .fontColor(TEXT_NAME)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              if (this.missionSub(m).length > 0) {
                Text(this.missionSub(m))
                  .fontSize(11)
                  .fontColor(TEXT_LABEL)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 2 })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Row() {
              // 目的地：右侧蓝色胶囊（小程序 flight-dest）
              if (this.missionDest(m).length > 0) {
                Text(this.missionDest(m))
                  .fontSize(10)
                  .fontColor(ACCENT)
                  .backgroundColor(DEST_BG)
                  .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
                  .borderRadius(3)
                  .maxLines(1)
              }
              // 有 LL2 发射 UUID 才给箭头，避免点了没反应
              if (strOf(m.id).trim().length > 0) {
                Text('›')
                  .fontSize(15)
                  .fontColor(TEXT_FOOT)
                  .margin({ left: 6 })
              }
            }
            .alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 8, bottom: 8 })
          .onClick(() => {
            this.openMission(m);
          })

          if (i < this.missionList.length - 1) {
            Divider()
              .color(ROW_LINE)
              .strokeWidth(1)
          }
        }
        .width('100%')
      }, (m: AstronautMission, i: number) => strOf(m.id) + '@' + strOf(m.net) + '#' + String(i))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: CARD_LINE })
    .margin({ left: CARD_SIDE, right: CARD_SIDE, top: CARD_TOP })
  }

  // ============ UI：出舱记录 ============

  @Builder
  evaBlock() {
    Column() {
      Text('出舱记录')
        .fontSize(12)
        .fontColor(TEXT_MUTED)
        .margin({ bottom: 7 })

      ForEach(this.evaList, (e: AstronautEva, i: number) => {
        Column() {
          Row() {
            // 时间线小圆点：10rpx 实心 + 4rpx 外发光。
            // ArkUI 没有 box-shadow，用「大而淡的圆 + 小的实心圆」两层叠出同一效果
            Stack() {
              Circle({ width: 13, height: 13 })
                .fill(DOT_HALO)
              Circle({ width: 5, height: 5 })
                .fill(ACCENT)
            }
            .width(13)
            .height(13)

            Column() {
              Text(this.evaName(e))
                .fontSize(13)
                .fontColor('#CBD5E0')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              if (this.evaSub(e).length > 0) {
                Text(this.evaSub(e))
                  .fontSize(10.5)
                  .fontColor(TEXT_LABEL)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 3 })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 9 })

            if (this.evaHoursTextOf(e).length > 0) {
              Text(this.evaHoursTextOf(e))
                .fontSize(11.5)
                .fontColor(ACCENT)
                .margin({ left: 7 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: 8, bottom: 8 })

          if (i < this.evaList.length - 1) {
            Divider()
              .color(ROW_LINE)
              .strokeWidth(1)
          }
        }
        .width('100%')
      }, (e: AstronautEva, i: number) => strOf(e.name) + '@' + strOf(e.start) + '#' + String(i))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: CARD_LINE })
    .margin({ left: CARD_SIDE, right: CARD_SIDE, top: CARD_TOP })
  }

  // ============ UI：资料（生卒 + 三个外链，点击复制） ============

  @Builder
  profileBlock() {
    Column() {
      Text('资料')
        .fontSize(12)
        .fontColor(TEXT_MUTED)
        .margin({ bottom: 7 })

      if (this.dobText.length > 0) {
        Row() {
          Text('出生')
            .fontSize(12.5)
            .fontColor(TEXT_LABEL)
          Blank()
          Text(this.dobText)
            .fontSize(12.5)
            .fontColor(TEXT_DESC)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 6, bottom: 6 })
      }

      if (this.dodText.length > 0) {
        Row() {
          Text('逝世')
            .fontSize(12.5)
            .fontColor(TEXT_LABEL)
          Blank()
          Text(this.dodText)
            .fontSize(12.5)
            .fontColor(TEXT_DESC)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 6, bottom: 6 })
      }

      if (this.wikiUrl.length > 0) {
        Row() {
          Text('维基百科')
            .fontSize(12.5)
            .fontColor(TEXT_LABEL)
          Blank()
          Text('复制链接')
            .fontSize(12.5)
            .fontColor(ACCENT)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 6, bottom: 6 })
        .onClick(() => {
          this.copyLink(this.wikiUrl, '维基百科');
        })
      }

      if (this.twitterUrl.length > 0) {
        Row() {
          Text('Twitter')
            .fontSize(12.5)
            .fontColor(TEXT_LABEL)
          Blank()
          Text('复制链接')
            .fontSize(12.5)
            .fontColor(ACCENT)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 6, bottom: 6 })
        .onClick(() => {
          this.copyLink(this.twitterUrl, 'Twitter');
        })
      }

      if (this.instaUrl.length > 0) {
        Row() {
          Text('Instagram')
            .fontSize(12.5)
            .fontColor(TEXT_LABEL)
          Blank()
          Text('复制链接')
            .fontSize(12.5)
            .fontColor(ACCENT)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 6, bottom: 6 })
        .onClick(() => {
          this.copyLink(this.instaUrl, 'Instagram');
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: CARD_LINE })
    .margin({ left: CARD_SIDE, right: CARD_SIDE, top: CARD_TOP })
  }

  // ============ UI：页脚 ============

  @Builder
  footerBlock() {
    Text('数据来源 The Space Devs')
      .fontSize(10)
      .fontColor(TEXT_FOOT)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ top: 24 })
  }

  // ============ UI：两态占位（对齐小程序 loading / empty） ============

  @Builder
  loadingBlock() {
    Column() {
      // 英文三点，不是全角省略号（小程序原文就是 "加载中..."）
      Text('加载中...')
        .fontSize(13)
        .fontColor(TEXT_LABEL)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 20, right: 20, top: 100, bottom: 20 })
  }

  @Builder
  emptyBlock() {
    Column() {
      Text(AVATAR_PLACEHOLDER)
        .fontSize(36)
        .margin({ bottom: 12 })
      Text('未找到该航天员信息')
        .fontSize(13)
        .fontColor(TEXT_LABEL)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 20, right: 20 })
  }

  // ============ build ============

  build() {
    // 根容器**不**统一加侧距：卡片各带 margin 16（任务书要求），
    // 顶栏自己给 16，这样卡片边框能贴到 16 而内容还有 16 的内边距
    Column() {
      this.topBar()

      if (this.loading && !this.found) {
        this.loadingBlock()
      } else if (!this.found) {
        this.emptyBlock()
      } else {
        Scroll() {
          Column() {
            this.headBlock()
            this.kpiBlock()

            if (this.bioText.length > 0) {
              this.bioBlock()
            }
            // 两张反向索引卡：数据没到就是空数组，整卡不出现
            if (this.stnRefs.length > 0) {
              this.stationBlock()
            }
            if (this.expRefs.length > 0) {
              this.expBlock()
            }
            if (this.missionList.length > 0) {
              this.missionBlock()
            }
            // 出舱卡：列表为空整卡不画（小程序同口径，没有「暂无逐条记录」）
            if (this.evaList.length > 0) {
              this.evaBlock()
            }
            if (this.hasProfile) {
              this.profileBlock()
            }

            this.footerBlock()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
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
