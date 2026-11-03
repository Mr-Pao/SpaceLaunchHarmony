/**
 * view/RocketDetailView.ets —— 火箭详情页（对位小程序 pages/rocket/rocket.vue）
 *
 * 2026-11-03 按小程序原版整体重写：原来只有「技术参数卡 + 简介卡」，
 * 现在补齐 切换构型 / 发射战绩 / 回收记录 / 芯级 / 发射场地 / 即将发射 / 历史发射 /
 * 外部资料 八个区块，外加制造方面包屑、图片库入口、简介卡收藏胶囊、发射机构行。
 *
 * 数据来源（2026-11-02 实测快照）：
 *   launchers.json  532 条，id 是 number，`manufacturer` 有、`agencyName` 没有，
 *                   简介字段是 description / descriptionZh（**没有 desc**）
 *   cores.json      196 枚真实第一级硬件，按 configId 与型号 id 关联
 *   previous/upcoming  各下发 100 条（served=100，count 是全量），
 *                   本页按「同系列各构型 id」筛出这个型号的发射记录
 *
 * 数据链路（与 TodayView / LaunchDetailView 同口径：缓存先上屏，网络后补）：
 *   repo.peek<T>() 同步取值 → 立刻渲染；repo.load<T>(...) 后台刷新 → onUpdate 回填。
 *
 * 有意取舍（逐条写清，方便复核）：
 *   1. **定位先精确、后忽略大小写**。调用方传进来的 name 来自 LL2 的
 *      rocket.configuration.name，理论上与 launchers 的 name 一致；上游偶尔会大小写不一致，
 *      所以第二遍用 toLowerCase 兜底。
 *   2. **副标题只在 full_name 与标题不同时显示**。launchers 里绝大多数记录的
 *      full_name === name，照抄会在大字下面再重复一遍同样的字。
 *   3. **后端没数据 ≠ 没找到**。repo.load 在「无缓存 + 网络失败」时是 reject，
 *      所以 failed 单独出一个「加载失败 + 重试」，不与「未找到该型号」混为一谈。
 *   4. **参数格按「值无效就整格不画」过滤**，绝不出现 undefined / NaN / 0 值格。
 *      0 在这份数据里确实存在（pending_launches、attempted_landings 大面积是 0）。
 *   5. **简介优先 descriptionZh**，翻不出来时 CI 留空串，这里自然回退英文。
 *   6. **简介卡永远显示**（即使没有简介）。小程序的 v-if 是 `descText || !reviewMode`，
 *      鸿蒙不迁 reviewMode（微信审核暗门在华为市场不存在），等价于恒定显示；
 *      更重要的是收藏入口挂在标题行，卡片消失会让入口跟着消失。
 *   7. **分享胶囊不做**。小程序分享是原生 button(open-type=share)，ArkUI 侧没有等价能力
 *      （系统分享面板需要主动唤起 Share Kit，且本工程未接入），只保留收藏一枚。
 *   8. **「图片库」入口跳视频库**。鸿蒙侧的 media 页（图片瀑布流）还没做，
 *      先用 Nav.pushVideos('') 落到视频库；数字仍按 collectMedia 口径统计（图片张数），
 *      与小程序一致，等 media 页做出来再换目标。
 *   9. **机构跳转把原始英文名交给 AgencyView**，不在这里预加载 agencies 做三级模糊匹配
 *      （全等 → 双向 includes → abbrev）。那需要拿整个 agencies 列表在调用方过滤，
 *      而 AgencyView 自身已按 id → 名字（小写全等）两级匹配；只改本文件时做不了第三级，
 *      取舍记在这里：极少见的「名字略有出入」会落到机构页的未找到态。
 *  10. **收藏键是型号名**（RocketNavParam 唯一入参），切换构型换名字 = 换收藏项，
 *      与小程序 hasRocket(rocketId) 的粒度一致（不同构型本来就是不同条目）。
 *  11. **发射场地的 count 只在有值时显示**，且 pads 优先用 CI 回填的 config.pads
 *      （覆盖全历史），老缓存没这个字段时退回发射记录现场聚合、按次数降序取 5 条。
 *  12. **不铺 StarField**。小程序火箭列表页有星空，但这一版对位的是 rocket.vue 详情页，
 *      源码里详情页没有 StarField —— 按源码来。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。不使用 AppStorage。
 * ⚠ 本文件无定时器（Swiper 的自动轮播由组件自身管理），故 aboutToDisappear 无清理动作。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { repo, LoadOptions } from '../data/Repository';
import {
  strOf, textUnits, coreStatus, agencyLabel, flagOf, placeZh, padShort,
  rocketName, rocketFullName, seriesKey, massText, costText, compareByNet,
  isStillUpcoming, launchTitle
} from '../utils/Format';
import { fullImageOf } from '../utils/Media';
import { CoreStatusEntry } from '../constants/ZhMaps';
import {
  RocketConfig, LaunchSummary, LaunchPad, PadLocation, LaunchProvider, LaunchRocket
} from '../model/Common';
import { PreviousPayload, UpcomingPayload } from '../model/Launch';
import { Nav } from '../routes/Nav';
import {
  PhotoNavParam, AgencyNavParam, PadNavParam, LaunchNavParam
} from '../routes/NavParam';
import { LaunchCard } from '../components/LaunchCard';
import { rocketFavInit, rocketFavHas, rocketFavToggle, MvRocketFav } from '../data/RocketFavorites';

const DOMAIN: number = 0x0000;
const TAG: string = 'RocketDetailView';

// ============ 视觉常量（任务书 + 小程序 rpx÷2） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
/** 卡片：radius 20rpx / padding 26rpx 28rpx / 上间距 22rpx */
const CARD_RADIUS: number = 10;
const CARD_PAD_H: number = 14;
const CARD_PAD_V: number = 13;
const CARD_MT: number = 11;

const TEXT_MAIN: string = '#FFFFFF';
/** 简介正文（小程序 .desc 的 #cbd5e0） */
const TEXT_BODY: string = '#CBD5E0';
/** 参数值 / 战绩数值（小程序 .pc-value / .rg-value） */
const TEXT_STRONG: string = '#E6EDF6';
/** 卡片标题右侧的小字、标签、场地点位（小程序 #6b7891） */
const TEXT_MUTED: string = '#6B7891';
/** 战绩右侧两行（小程序 .rh-line 的 #7d8ba0） */
const TEXT_SOFT: string = '#7D8BA0';
const ACCENT: string = '#38BDF8';

/** Hero 高度：小程序 .hero height 560rpx = 280vp */
const HERO_H: number = 280;
/** 底图压暗层高度：小程序 .hero-mask 400rpx = 200vp */
const HERO_MASK_H: number = 200;
/** 页面左右内边距：小程序 .body padding 0 24rpx = 12vp */
const PAGE_PAD: number = 12;
/** body 上浮压图：小程序 .body margin-top -16rpx = -8vp */
const BODY_LIFT: number = -8;
/** 详情页不在 tab 内，不留 92 的胶囊让位 */
const BOTTOM_PAD: number = 32;

/** 即将发射 / 历史发射一次展示几条（小程序 FOLD） */
const FOLD: number = 3;
/** 芯级一次展示几枚（小程序 CORE_FOLD） */
const CORE_FOLD: number = 6;
/** 简介折叠行数（小程序 .desc-fold 的 -webkit-line-clamp: 4） */
const DESC_FOLD_LINES: number = 4;
/**
 * 简介「要不要给展开按钮」的阈值。
 * 不能用纯字符数：同样 160 字，英文约 3 行、中文已 6 行。小程序统一换算成视觉宽度
 * （CJK 记 2、半角记 1），4 行约等于 200 个单位 —— 与源码 `textUnits(desc) > 200` 一致。
 */
const DESC_UNITS_MAX: number = 200;
/** 图片库最多收多少张（小程序 MAX_IMAGES） */
const MEDIA_MAX: number = 60;
/** Hero 轮播最多几张（小程序 heroSlides = images.slice(0, 5)） */
const HERO_SLIDES_MAX: number = 5;

const STAR_YELLOW: string = '#FFD60A';

// ============ 类型（launchers.json / cores.json 真实结构） ============

/**
 * launchers.json 的单条记录。
 *
 * 字段清单来自线上快照（36 个键）。全部可选：上游对不同型号的缺字段情况很普遍
 * （gto/geo/sso_capacity、launch_cost、fastest_turnaround 都可能为 null）。
 *
 * 为什么不复用 model/Common.ets 的 RocketBrief：
 *   1) 字段名不同 —— launchers 是 description / descriptionZh，RocketBrief 是 desc；
 *   2) launchers 还带 total_launch_count / attempted_landings / pads 等 20 个
 *      RocketBrief 里没有的字段，用 RocketBrief 断言等于逼人写 any；
 *   3) 按工程约定，新增类型统一加前缀，本文件用 Rk。
 */
export interface RkLauncher {
  /** LL2 数字 id */
  id?: number;
  name?: string;
  full_name?: string;
  variant?: string;
  /** 所属系列，如 ["Falcon", "Falcon 9"] */
  families?: string[];
  manufacturer?: string;

  // ---- 尺寸与运力（LL2 单位：length/diameter 米，launch_mass 吨，to_thrust 千牛，运力 千克）----
  length?: number;
  diameter?: number;
  launch_mass?: number;
  to_thrust?: number;
  leo_capacity?: number;
  gto_capacity?: number;
  geo_capacity?: number;
  sso_capacity?: number;

  /** 首飞日期，形如 "2014-07-09" */
  maiden_flight?: string;
  min_stage?: number;
  max_stage?: number;
  /** 单次造价（美元），可能为 null */
  launch_cost?: number | null;

  reusable?: boolean;
  active?: boolean;

  // ---- 累计统计（发射战绩 / 回收记录两个卡的数据源）----
  total_launch_count?: number;
  successful_launches?: number;
  failed_launches?: number;
  pending_launches?: number;
  consecutive_successful_launches?: number;
  attempted_landings?: number;
  successful_landings?: number;
  failed_landings?: number;
  consecutive_successful_landings?: number;
  fastest_turnaround?: number | null;

  description?: string;
  descriptionZh?: string;

  image?: string;
  info_url?: string;
  wiki_url?: string;
  /** 发射工位（CI 在 sync.js 里按发射记录聚合好，按次数降序前 5 条） */
  pads?: RkPadRef[];
}

/** launchers 里 pads 的单项：{ name, location, count }。location 是「场地, 州, 国」整串 */
export interface RkPadRef {
  name?: string;
  location?: string;
  count?: number;
}

/**
 * 芯级个体（cores.json）。
 *
 * 与 slim.js 的 slimCore 一一对应：id/serial/status/proven/flights/landed/landedTry/
 * first/last/configId/configName/img/credit/details/detailsZh。
 * 这里只声明页面用得到的字段 —— 其余字段 JSON 里仍在，只是类型层面不读。
 */
export interface RkCore {
  /** LL2 数字 id，slim 里可能是 null */
  id?: number | null;
  serial?: string;
  status?: string;
  flights?: number;
  /** 成功回收次数 */
  landed?: number;
  /** 尝试回收次数 */
  landedTry?: number;
  first?: string;
  last?: string;
  configId?: number | null;
  configName?: string;
  details?: string;
  detailsZh?: string;
}

/** 数据集信封（launchers / cores 同形） */
export interface RkListPayload {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  count?: number;
  served?: number;
  list?: RkLauncher[];
}

export interface RkCoresPayload {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  count?: number;
  served?: number;
  list?: RkCore[];
}

// ============ 视图模型（ArkTS 禁止无类型对象字面量，一律先建 class） ============

/** 一个参数格：10vp 灰标签 + 14vp 粗体值（小程序 .param-cell） */
class RkSpecCell {
  label: string = '';
  value: string = '';
  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/**
 * 两列网格的一行。
 *
 * 右侧为什么不用 `RkSpecCell | null`：ArkTS 的收窄在 @Builder 调用参数上不可靠
 * （判空之后传进去仍可能被判成可空类型而编译失败）。
 * 改成「必有 right 对象 + hasRight 布尔」，渲染按布尔分支，类型上零可空。
 */
class RkSpecRow {
  left: RkSpecCell = new RkSpecCell('', '');
  right: RkSpecCell = new RkSpecCell('', '');
  hasRight: boolean = false;
  constructor(left: RkSpecCell, right: RkSpecCell, hasRight: boolean) {
    this.left = left;
    this.right = right;
    this.hasRight = hasRight;
  }
}

/** 战绩 / 回收的一格：17vp 数值 + 10vp 标签，tone 决定数值色 */
class RkMetric {
  label: string = '';
  value: string = '';
  /** good / bad / warn / plain */
  tone: string = 'plain';
  constructor(label: string, value: string, tone: string) {
    this.label = label;
    this.value = value;
    this.tone = tone;
  }
}

/** 芯级一行的渲染模型：原始字段 + 中文化后的状态 + 是否显示回收行 */
class RkCoreItem {
  key: string = '';
  serial: string = '';
  statusText: string = '';
  /** ok / bad / dim */
  statusCls: string = 'dim';
  flights: number = 0;
  landed: number = 0;
  landedTry: number = 0;
  /** expended（设计上不回收）不显示回收行，避免误导 */
  showLanding: boolean = false;
  last: string = '';
  details: string = '';
}

/** 构型 chip：只做下拉切换，不画构型大卡（小程序这里的卡没用上，模板只渲染 chip） */
class RkVariant {
  key: string = '';
  chipName: string = '';
  cur: boolean = false;
  active: boolean = false;
  /**
   * 该 chip 对应的完整记录。用可空而不是空对象哨兵：
   * ArkTS 对「接口类型 + 空对象字面量」的容忍度很低，判空更保险。
   */
  ref: RkLauncher | null = null;
  constructor(key: string, chipName: string, cur: boolean, active: boolean, ref: RkLauncher) {
    this.key = key;
    this.chipName = chipName;
    this.cur = cur;
    this.active = active;
    this.ref = ref;
  }
}

/** 发射场地一行：短名 + 地点 + 次数，raw 用于跳转消歧 */
class RkPadItem {
  name: string = '';
  short: string = '';
  locationZh: string = '';
  locationRaw: string = '';
  count: number = 0;
  constructor(name: string, short: string, locationZh: string, locationRaw: string, count: number) {
    this.name = name;
    this.short = short;
    this.locationZh = locationZh;
    this.locationRaw = locationRaw;
    this.count = count;
  }
}

/** Hero 轮播一张：thumb 给 Swiper，full 给看图器 */
class RkSlide {
  thumb: string = '';
  full: string = '';
  constructor(thumb: string, full: string) {
    this.thumb = thumb;
    this.full = full;
  }
}

@Component
export struct RocketDetailView {
  /** 火箭型号名（DetailPages 从 RocketNavParam.name 传进来） */
  @Prop rocketName: string = '';

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，不挡返回栏） */
  @State loading: boolean = true;
  /** 是否拿到了这条记录 */
  @State found: boolean = false;
  /** 加载失败（无缓存 + 网络失败）。与「未找到」分开，见文件头取舍 3 */
  @State failed: boolean = false;

  /** 当前构型（切换构型的唯一入口就是替换它） */
  @State cur: RkLauncher | null = null;
  /** 型号库全量：系列内其它构型、图片库都要从这里找 */
  @State all: RkLauncher[] = [];

  /** 历史发射 / 即将发射两个快照的原始 list（按系列 id 过滤在 records() 里做） */
  @State prevList: LaunchSummary[] = [];
  @State upList: LaunchSummary[] = [];

  /** 芯级库全量（按 configId 过滤） */
  @State coresAll: RkCore[] = [];

  /** 参数格（已按「值无效就跳过」过滤，两列成行） */
  @State specs: RkSpecRow[] = [];

  /** 简介（descriptionZh || description） */
  @State desc: string = '';
  @State descExpanded: boolean = false;

  /** Hero 图片加载失败 → 单图时退回渐变占位 */
  @State imgErr: boolean = false;
  /** 轮播当前页（自绘圆点要跟着走） */
  @State slide: number = 0;

  /** 三个折叠开关 */
  @State coresOpen: boolean = false;
  @State upcomingOpen: boolean = false;
  @State historyOpen: boolean = false;
  /** 当前展开简介的芯级 id（空串 = 都收起） */
  @State openCoreKey: string = '';

  /** 是否已收藏（顶栏星标与简介卡胶囊共用这一个状态） */
  @State faved: boolean = false;

  /** 滚动容器 */
  private scroller: Scroller = new Scroller();

  // ============ 生命周期 ============

  aboutToAppear(): void {
    // preferences 需要 Context，这是首个拿得到它的时机（与 LaunchDetailView 同口径）
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      rocketFavInit(ctx);
    }
    this.syncFaved();
    // 三个数据集互不依赖，一起发出去：launchers 走网络失败时，
    // 「即将 / 历史发射」与「芯级」仍能靠缓存或独立请求上屏
    this.loadLauncher(false);
    this.loadRecords();
    this.loadCores();
  }

  // ============ 加载 ============

  /**
   * 先 peek 再 load（与 MineView.loadLastSync 同一套写法）：
   *   peek 只查内存 + 文件、绝不发网络，冷启动能立刻把详情画出来；
   *   随后 load 走正常链路，命中过期缓存时由 onUpdate 把新数据补上屏。
   */
  private loadLauncher(force: boolean): void {
    this.loading = true;
    this.failed = false;

    const cached: RkListPayload | null = repo.peek<RkListPayload>('launchers');
    if (cached !== null) {
      this.applyPayload(cached);
      if (this.found) {
        this.loading = false;
      }
    }

    const opts: LoadOptions<RkListPayload> = {
      force: force,
      onUpdate: (fresh: RkListPayload) => {
        this.applyPayload(fresh);
      }
    };

    repo.load<RkListPayload>('launchers', opts)
      .then((data: RkListPayload) => {
        // load 的 resolve 在「命中缓存」时给的就是缓存值，重复落地一次无害（幂等）
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有缓存内容就别说「失败」，静默留在已有页面上
        this.failed = !this.found;
        hilog.warn(DOMAIN, TAG, 'launchers 加载失败: %{public}s', e.message);
      });
  }

  /** 数据落地：找记录 → 拆到各个 @State */
  private applyPayload(data: RkListPayload): void {
    const raw: RkLauncher[] = data.list !== undefined ? data.list : [];
    if (raw.length > 0) {
      this.all = raw;
    }
    const hit: RkLauncher | null = this.findLauncher(raw);
    if (hit === null) {
      // 已渲染过就保持原样：中途一次半截数据不该把整页打回「未找到」
      if (!this.found) {
        this.found = false;
      }
      return;
    }
    this.applyLauncher(hit);
  }

  /**
   * 定位型号：先精确匹配 name / full_name，再忽略大小写与首尾空格来一遍。
   * 两遍都空 → null（调用方据此显示「未找到该型号」）。
   */
  private findLauncher(list: RkLauncher[]): RkLauncher | null {
    const target: string = strOf(this.rocketName).trim();
    if (target.length === 0) {
      return null;
    }

    const exact: RkLauncher | undefined =
      list.find((x: RkLauncher) => strOf(x.name) === target || strOf(x.full_name) === target);
    if (exact !== undefined) {
      return exact;
    }

    const lower: string = target.toLowerCase();
    const loose: RkLauncher | undefined = list.find((x: RkLauncher) => {
      const n: string = strOf(x.name).trim().toLowerCase();
      const f: string = strOf(x.full_name).trim().toLowerCase();
      return n === lower || f === lower;
    });
    return loose !== undefined ? loose : null;
  }

  /** 一条记录 → 页面状态。所有字段都过一遍空值判定，不留 undefined 下去的缝 */
  private applyLauncher(x: RkLauncher): void {
    this.cur = x;
    this.imgErr = false;
    this.slide = 0;
    this.descExpanded = false;
    this.coresOpen = false;
    this.upcomingOpen = false;
    this.historyOpen = false;
    this.openCoreKey = '';

    const zh: string = strOf(x.descriptionZh).trim();
    this.desc = zh.length > 0 ? zh : strOf(x.description).trim();

    this.specs = this.buildSpecs(x);
    this.found = true;
    this.loading = false;
    this.failed = false;

    // 定位成功、name 归一化之后重读一次星标：aboutToAppear 那一刻 name 还是空的，
    // 那时读的是路由入参的名字。两份名字在绝大多数情况下相同，但归一化过的
    // 才是清单里能点回来的那个键，所以这里必须以它为准。
    this.syncFaved();
  }

  /**
   * 发射记录：同时扫 previous 与 upcoming 两个快照。
   *
   * 为什么不 await：两个数据集各自有 15/60 分钟 TTL，谁先回来谁先上屏；
   * 失败也只影响「即将/历史」两段，不能因此卡住整页（小程序同样 catch 掉）。
   */
  private loadRecords(): void {
    const cachedPrev: PreviousPayload | null = repo.peek<PreviousPayload>('previous');
    if (cachedPrev !== null) {
      this.prevList = cachedPrev.list;
    }
    const cachedUp: UpcomingPayload | null = repo.peek<UpcomingPayload>('upcoming');
    if (cachedUp !== null) {
      this.upList = cachedUp.list;
    }

    const optsPrev: LoadOptions<PreviousPayload> = {
      onUpdate: (fresh: PreviousPayload) => {
        this.prevList = fresh.list;
      }
    };
    repo.load<PreviousPayload>('previous', optsPrev)
      .then((data: PreviousPayload) => {
        this.prevList = data.list;
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'previous 加载失败: %{public}s', e.message);
      });

    const optsUp: LoadOptions<UpcomingPayload> = {
      onUpdate: (fresh: UpcomingPayload) => {
        this.upList = fresh.list;
      }
    };
    repo.load<UpcomingPayload>('upcoming', optsUp)
      .then((data: UpcomingPayload) => {
        this.upList = data.list;
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'upcoming 加载失败: %{public}s', e.message);
      });
  }

  /** 芯级库：失败静默降级（只是少一段，不能因此卡住整页） */
  private loadCores(): void {
    const cached: RkCoresPayload | null = repo.peek<RkCoresPayload>('cores');
    if (cached !== null && cached.list !== undefined) {
      this.coresAll = cached.list;
    }
    const opts: LoadOptions<RkCoresPayload> = {
      onUpdate: (fresh: RkCoresPayload) => {
        this.coresAll = fresh.list !== undefined ? fresh.list : [];
      }
    };
    repo.load<RkCoresPayload>('cores', opts)
      .then((data: RkCoresPayload) => {
        this.coresAll = data.list !== undefined ? data.list : [];
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'cores 加载失败: %{public}s', e.message);
      });
  }

  // ============ 派生数据 ============

  /** 当前构型转成 Format 系列函数吃的 RocketConfig（rocketName / seriesKey 都只认它） */
  private configOf(x: RkLauncher): RocketConfig {
    const idv: number | null = x.id !== undefined ? x.id : null;
    const cfg: RocketConfig = {
      id: idv,
      name: strOf(x.name),
      full_name: strOf(x.full_name),
      variant: strOf(x.variant),
      families: x.families
    };
    return cfg;
  }

  /** 当前构型（带空值收口：所有取值方法都先过这里） */
  private curOrNull(): RkLauncher | null {
    return this.cur;
  }

  /**
   * 同系列的其它构型（含自己）。
   * 用 seriesKey 聚合：`families[1]` 恰好是「型号系列」这一级，
   * 猎鹰 9 的 Block 5 / v1.0 就能落进同一组。
   */
  private siblings(): RkLauncher[] {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return [];
    }
    if (this.all.length === 0) {
      return [cur];
    }
    const key: string = seriesKey(this.configOf(cur));
    if (key.length === 0) {
      return [cur];
    }
    const out: RkLauncher[] = [];
    for (let i = 0; i < this.all.length; i++) {
      const x: RkLauncher = this.all[i];
      if (seriesKey(this.configOf(x)) === key) {
        out.push(x);
      }
    }
    return out.length > 0 ? out : [cur];
  }

  /** 该系列各构型的 id（字符串），用来从发射快照里筛记录 */
  private seriesIdSet(): string[] {
    const list: RkLauncher[] = this.siblings();
    const out: string[] = [];
    for (let i = 0; i < list.length; i++) {
      const idv: number | undefined = list[i].id;
      if (idv !== undefined && idv !== null) {
        const k: string = String(idv);
        if (out.indexOf(k) < 0) {
          out.push(k);
        }
      }
    }
    return out;
  }

  /**
   * 本型号（整系列）的发射记录，upcoming 在前、previous 在后，按 id 去重。
   * 两个快照各自只下发 100 条，所以历史远不完整 —— 标题「近期 N 次」就是这么来的。
   */
  private records(): LaunchSummary[] {
    const ids: string[] = this.seriesIdSet();
    const out: LaunchSummary[] = [];
    const seen: string[] = [];
    this.collectFrom(this.upList, ids, out, seen);
    this.collectFrom(this.prevList, ids, out, seen);
    return out;
  }

  private collectFrom(src: LaunchSummary[], ids: string[], out: LaunchSummary[], seen: string[]): void {
    for (let i = 0; i < src.length; i++) {
      const it: LaunchSummary = src[i];
      const cfgId: string = this.launchConfigId(it);
      if (cfgId.length === 0 || ids.indexOf(cfgId) < 0) {
        continue;
      }
      const uid: string = strOf(it.id);
      if (uid.length > 0 && seen.indexOf(uid) >= 0) {
        continue;
      }
      if (uid.length > 0) {
        seen.push(uid);
      }
      out.push(it);
    }
  }

  /** 一条发射记录的 configuration.id（缺失返回空串） */
  private launchConfigId(item: LaunchSummary): string {
    const rocket: LaunchRocket | undefined = item.rocket;
    if (rocket === undefined || rocket === null) {
      return '';
    }
    const cfg: RocketConfig = rocket.configuration;
    const idv: number | null | undefined = cfg.id;
    return idv === undefined || idv === null ? '' : String(idv);
  }

  /**
   * Hero 轮播源 = 构型官方图 + 历次发射实拍 + 工位图 + 信息图（去重后取前 5）。
   * 与小程序的 collectMedia 同口径，只是视频那一路用不到（本页只做图片库入口）。
   */
  private slides(): RkSlide[] {
    const all: RkSlide[] = [];
    const seen: string[] = [];

    // 1 构型官方图放最前：它是这个型号本身，比某一次发射的现场图更像封面
    const sibs: RkLauncher[] = this.siblings();
    for (let i = 0; i < sibs.length; i++) {
      this.pushSlide(all, seen, strOf(sibs[i].image));
    }

    // 2 发射实拍按时间倒序：最近一次的照片最有新鲜感
    const recs: LaunchSummary[] = this.records();
    const sorted: LaunchSummary[] = recs.slice();
    sorted.sort((a: LaunchSummary, b: LaunchSummary): number => compareByNet(b, a));
    for (let i = 0; i < sorted.length; i++) {
      const it: LaunchSummary = sorted[i];
      this.pushSlide(all, seen, strOf(it.imageThumb).length > 0 ? strOf(it.imageThumb) : strOf(it.image));
      const pad: LaunchPad | undefined = it.pad;
      if (pad !== undefined && pad !== null) {
        this.pushSlide(all, seen,
          strOf(pad.imageThumb).length > 0 ? strOf(pad.imageThumb) : strOf(pad.image));
      }
      this.pushSlide(all, seen, strOf(it.infographic));
    }

    if (all.length > HERO_SLIDES_MAX) {
      return all.slice(0, HERO_SLIDES_MAX);
    }
    return all;
  }

  /** 图片库总数（不截到 5；口径与小程序 mediaStats.images 一致） */
  private mediaCount(): number {
    const sibs: RkLauncher[] = this.siblings();
    const recs: LaunchSummary[] = this.records();
    const seen: string[] = [];
    const out: RkSlide[] = [];
    for (let i = 0; i < sibs.length; i++) {
      this.pushSlide(out, seen, strOf(sibs[i].image));
    }
    for (let i = 0; i < recs.length; i++) {
      const it: LaunchSummary = recs[i];
      this.pushSlide(out, seen, strOf(it.imageThumb).length > 0 ? strOf(it.imageThumb) : strOf(it.image));
      const pad: LaunchPad | undefined = it.pad;
      if (pad !== undefined && pad !== null) {
        this.pushSlide(out, seen,
          strOf(pad.imageThumb).length > 0 ? strOf(pad.imageThumb) : strOf(pad.image));
      }
      this.pushSlide(out, seen, strOf(it.infographic));
    }
    return out.length > MEDIA_MAX ? MEDIA_MAX : out.length;
  }

  /** 去重压入：thumb 是 COS 上的缩略图，同一张图只留一份 */
  private pushSlide(out: RkSlide[], seen: string[], thumb: string): void {
    const t: string = thumb.trim();
    if (t.length === 0 || seen.indexOf(t) >= 0 || out.length >= MEDIA_MAX) {
      return;
    }
    seen.push(t);
    const full: string = fullImageOf(t);
    out.push(new RkSlide(t, full.length > 0 ? full : t));
  }

  /** 标题：full_name 优先，再 name（对齐 rocketFullName || rocketName || name） */
  private titleText(): string {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      const n: string = strOf(this.rocketName).trim();
      return n.length > 0 ? n : '火箭详情';
    }
    const cfg: RocketConfig = this.configOf(cur);
    const full: string = rocketFullName(cfg);
    if (full.length > 0) {
      return full;
    }
    const base: string = rocketName(cfg);
    if (base.length > 0) {
      return base;
    }
    const n: string = strOf(cur.name).trim();
    return n.length > 0 ? n : '火箭详情';
  }

  /** 副标题：英文全名，与标题完全一致时不重复（见取舍 2） */
  private subName(): string {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return '';
    }
    const full: string = strOf(cur.full_name).trim();
    const en: string = full.length > 0 ? full : strOf(cur.name).trim();
    if (en.length === 0) {
      return '';
    }
    return en === this.titleText() ? '' : en;
  }

  /** 顶部小标题（返回栏用）：型号名，取不到就用 prop */
  private barTitle(): string {
    const t: string = this.titleText();
    return t.length > 0 ? t : '火箭详情';
  }

  /** 制造方展示名：走机构中文表，未收录则截断（agencyLabel 内部处理） */
  private makerText(): string {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return '';
    }
    return agencyLabel(strOf(cur.manufacturer));
  }

  /** 制造方原始英文名：跳转机构页要用原名匹配 */
  private makerRaw(): string {
    const cur: RkLauncher | null = this.curOrNull();
    return cur === null ? '' : strOf(cur.manufacturer).trim();
  }

  /** 参数卡 / 战绩卡标题右侧的小字：variant 优先，否则 name */
  private variantNote(): string {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return '';
    }
    const v: string = strOf(cur.variant).trim();
    return v.length > 0 ? v : strOf(cur.name).trim();
  }

  /** 切换构型 chip 列表；只有 1 型时调用方不渲染整块 */
  private variants(): RkVariant[] {
    const list: RkLauncher[] = this.siblings().slice();
    if (list.length === 0) {
      return [];
    }
    const cur: RkLauncher | null = this.curOrNull();
    const curId: string = cur === null || cur.id === undefined ? '' : String(cur.id);

    // 现役优先 → 首飞新的在前 → 发射次数多的在前（与小程序一致）
    list.sort((a: RkLauncher, b: RkLauncher): number => {
      const aa: boolean = a.active === true;
      const bb: boolean = b.active === true;
      if (aa !== bb) {
        return aa ? -1 : 1;
      }
      const ma: string = strOf(a.maiden_flight);
      const mb: string = strOf(b.maiden_flight);
      if (ma !== mb) {
        return ma > mb ? -1 : 1;
      }
      const ca: number = a.total_launch_count !== undefined ? a.total_launch_count : 0;
      const cb: number = b.total_launch_count !== undefined ? b.total_launch_count : 0;
      return cb - ca;
    });

    const out: RkVariant[] = [];
    for (let i = 0; i < list.length; i++) {
      const x: RkLauncher = list[i];
      const idv: number | undefined = x.id;
      const key: string = idv === undefined || idv === null ? String(i) : String(idv);
      const zhName: string = rocketName(this.configOf(x));
      const v: string = strOf(x.variant).trim();
      const chip: string = v.length > 0 ? v : (zhName.length > 0 ? zhName : strOf(x.name));
      out.push(new RkVariant(
        key,
        chip,
        key === curId,
        x.active === true,
        x
      ));
    }
    return out;
  }

  /** 切换构型：整页数据跟着换（参数、战绩、回收、芯级、图片库都在当前构型上算） */
  private switchTo(v: RkVariant): void {
    if (v.cur || v.ref === null) {
      return;
    }
    this.applyLauncher(v.ref);
    // 换型号要回到顶部附近？不跳滚动位置 —— 小程序原地换数据，滚动位置保留，
    // 用户通常正在看「切换构型」那一行，跳走反而突兀。
  }

  // ============ 战绩 / 回收 ============

  /** 成功率：主指标。100% 不写成 100.0%，99.8% 保留一位；一次没飞过给「—」 */
  private rateText(): string {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return '—';
    }
    const ok: number = cur.successful_launches !== undefined ? cur.successful_launches : 0;
    const fail: number = cur.failed_launches !== undefined ? cur.failed_launches : 0;
    const flown: number = ok + fail;
    if (flown <= 0) {
      return '—';
    }
    const v: number = (ok / flown) * 100;
    return (v === 100 ? '100' : v.toFixed(1)) + '%';
  }

  /** 总发射次数（带千分位）；没有就「—」 */
  private statsTotal(): string {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return '—';
    }
    const total: number = cur.total_launch_count !== undefined ? cur.total_launch_count : 0;
    return total > 0 ? this.fmtInt(total) : '—';
  }

  /** 连续成功次数；没有就「—」 */
  private streakText(): string {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return '—';
    }
    const s: number =
      cur.consecutive_successful_launches !== undefined ? cur.consecutive_successful_launches : 0;
    return s > 0 ? this.fmtInt(s) : '—';
  }

  /** 成功 / 失败 / 待发射 三格，值为 0 的格直接不出现（小程序 filter(value !== '0')） */
  private stats(): RkMetric[] {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return [];
    }
    const ok: number = cur.successful_launches !== undefined ? cur.successful_launches : 0;
    const fail: number = cur.failed_launches !== undefined ? cur.failed_launches : 0;
    const pending: number = cur.pending_launches !== undefined ? cur.pending_launches : 0;
    const raw: RkMetric[] = [
      new RkMetric('成功', this.fmtInt(ok), 'good'),
      new RkMetric('失败', this.fmtInt(fail), 'bad'),
      new RkMetric('待发射', this.fmtInt(pending), 'warn')
    ];
    const out: RkMetric[] = [];
    for (let i = 0; i < raw.length; i++) {
      if (raw[i].value !== '0') {
        out.push(raw[i]);
      }
    }
    return out;
  }

  private hasRecord(): boolean {
    return this.rateText() !== '—' || this.stats().length > 0;
  }

  /**
   * 回收记录：尝试回收为 0 的型号整块卡片都不出现。
   * attempted_landings 是「有没有做过回收」的总开关 —— 只判几个分项是否为 0 不够，
   * expended（设计上就不回收）的型号三项全是 0，会渲染出一张全空的卡。
   */
  private landingStats(): RkMetric[] {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return [];
    }
    const attempted: number = cur.attempted_landings !== undefined ? cur.attempted_landings : 0;
    if (attempted <= 0) {
      return [];
    }
    const ok: number = cur.successful_landings !== undefined ? cur.successful_landings : 0;
    const fail: number = cur.failed_landings !== undefined ? cur.failed_landings : 0;
    const streak: number =
      cur.consecutive_successful_landings !== undefined ? cur.consecutive_successful_landings : 0;
    const turnaround: number =
      cur.fastest_turnaround !== undefined && cur.fastest_turnaround !== null ? cur.fastest_turnaround : 0;

    const raw: RkMetric[] = [
      new RkMetric('尝试回收', this.fmtInt(attempted), 'plain'),
      new RkMetric('成功', this.fmtInt(ok), 'good'),
      new RkMetric('失败', this.fmtInt(fail), 'bad'),
      new RkMetric('连续成功', this.fmtInt(streak), 'good')
    ];
    if (turnaround > 0) {
      raw.push(new RkMetric('最快周转', String(turnaround) + ' 天', 'plain'));
    }
    const out: RkMetric[] = [];
    for (let i = 0; i < raw.length; i++) {
      if (raw[i].value !== '0') {
        out.push(raw[i]);
      }
    }
    return out;
  }

  /** 回收卡右上角 note：只有可复用的型号才标 */
  private reusableNote(): string {
    const cur: RkLauncher | null = this.curOrNull();
    return cur !== null && cur.reusable === true ? '可复用' : '';
  }

  // ============ 发射机构 ============

  /**
   * 该系列发射记录里出现过的机构，去重后按出现顺序拼。
   * 注意 slimLaunch 里带的是 launch_service_provider 对象（不是顶层 agency 字符串）。
   */
  private agencyRawNames(): string[] {
    const recs: LaunchSummary[] = this.records();
    const out: string[] = [];
    for (let i = 0; i < recs.length; i++) {
      const p: LaunchProvider | undefined = recs[i].launch_service_provider;
      if (p === undefined || p === null) {
        continue;
      }
      const n: string = strOf(p.name).trim();
      if (n.length > 0 && out.indexOf(n) < 0) {
        out.push(n);
      }
    }
    return out;
  }

  /** 展示用：逐段走机构中文表，再用「、」拼 */
  private agencyZhText(): string {
    const names: string[] = this.agencyRawNames();
    const parts: string[] = [];
    for (let i = 0; i < names.length; i++) {
      parts.push(agencyLabel(names[i]));
    }
    return parts.join('、');
  }

  /** 只取第一个机构的国旗 emoji：一行挂三面旗会糊成一片（工程无 png，flagOf 返回 emoji） */
  private agencyFlagText(): string {
    const names: string[] = this.agencyRawNames();
    return names.length > 0 ? flagOf(names[0]) : '';
  }

  // ============ 芯级 ============

  /** 型号 id 与 cores.configId 同源，直接字符串比较 */
  private cores(): RkCoreItem[] {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null || cur.id === undefined || this.coresAll.length === 0) {
      return [];
    }
    const idKey: string = String(cur.id);
    const items: RkCoreItem[] = [];
    for (let i = 0; i < this.coresAll.length; i++) {
      const c: RkCore = this.coresAll[i];
      const cid: number | null | undefined = c.configId;
      if (cid === undefined || cid === null || String(cid) !== idKey) {
        continue;
      }
      const st: CoreStatusEntry = coreStatus(strOf(c.status));
      const landedTry: number = c.landedTry !== undefined ? c.landedTry : 0;
      const it: RkCoreItem = new RkCoreItem();
      const serial: string = strOf(c.serial).trim();
      const fallback: string = c.id === undefined || c.id === null ? '' : '#' + String(c.id);
      it.key = serial.length > 0 ? serial : fallback;
      it.serial = it.key;
      it.statusText = st.text;
      it.statusCls = st.cls;
      it.flights = c.flights !== undefined ? c.flights : 0;
      it.landed = c.landed !== undefined ? c.landed : 0;
      it.landedTry = landedTry;
      it.showLanding = landedTry > 0;
      it.last = this.dateText(strOf(c.last));
      const dz: string = strOf(c.detailsZh).trim();
      it.details = dz.length > 0 ? dz : strOf(c.details).trim();
      items.push(it);
    }

    // 现役优先 → 已飞次数降序 → 编号里的数字升序（B10 排在 B1067 前）
    items.sort((a: RkCoreItem, b: RkCoreItem): number => {
      const ao: number = a.statusCls === 'ok' ? 0 : 1;
      const bo: number = b.statusCls === 'ok' ? 0 : 1;
      if (ao !== bo) {
        return ao - bo;
      }
      if (b.flights !== a.flights) {
        return b.flights - a.flights;
      }
      const na: number = this.serialNum(a.serial);
      const nb: number = this.serialNum(b.serial);
      if (na !== nb) {
        return na - nb;
      }
      return a.serial > b.serial ? 1 : -1;
    });
    return items;
  }

  /** 取编号里第一段数字：'B1067' → 1067，'B10' → 10，没有数字给 0 */
  private serialNum(s: string): number {
    let digits: string = '';
    for (let i = 0; i < s.length; i++) {
      const code: number = s.charCodeAt(i);
      if (code >= 48 && code <= 57) {
        digits = digits + s.charAt(i);
      } else if (digits.length > 0) {
        break;
      }
    }
    return digits.length > 0 ? Number(digits) : 0;
  }

  /** 当前展示的芯级（收起时只给前 6 枚） */
  private coresShown(): RkCoreItem[] {
    const list: RkCoreItem[] = this.cores();
    return this.coresOpen ? list : list.slice(0, CORE_FOLD);
  }

  // ============ 发射场地 ============

  /**
   * 发射场地：优先用 CI 在型号库上聚合好的 config.pads（覆盖全历史），
   * 老缓存没这个字段时退回发射记录现场聚合、按次数降序取 5 条。
   */
  private pads(): RkPadItem[] {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return [];
    }
    const out: RkPadItem[] = [];
    const pre: RkPadRef[] = cur.pads !== undefined ? cur.pads : [];
    if (pre.length > 0) {
      for (let i = 0; i < pre.length; i++) {
        const p: RkPadRef = pre[i];
        const name: string = strOf(p.name).trim();
        // LL2 里有一批工位名就叫 "Unknown Pad"，聚出来是纯噪音
        if (name.length === 0 || name.toLowerCase().indexOf('unknown') >= 0) {
          continue;
        }
        const short: string = padShort(name);
        const rawLoc: string = strOf(p.location).trim();
        out.push(new RkPadItem(
          name,
          short.length > 0 ? short : name,
          placeZh(rawLoc),
          rawLoc,
          p.count !== undefined ? p.count : 0
        ));
      }
      return out;
    }

    // 兜底：从发射记录现场聚合（小程序同样按出现顺序累计再排序）
    const names: string[] = [];
    const counts: number[] = [];
    const locs: string[] = [];
    const recs: LaunchSummary[] = this.records();
    for (let i = 0; i < recs.length; i++) {
      const pad: LaunchPad | undefined = recs[i].pad;
      if (pad === undefined || pad === null) {
        continue;
      }
      const name: string = strOf(pad.name).trim();
      if (name.length === 0 || name.toLowerCase().indexOf('unknown') >= 0) {
        continue;
      }
      const at: number = names.indexOf(name);
      if (at < 0) {
        names.push(name);
        counts.push(1);
        const loc: PadLocation | undefined = pad.location;
        locs.push(loc === undefined || loc === null ? '' : strOf(loc.name).trim());
      } else {
        counts[at] = counts[at] + 1;
      }
    }
    const order: number[] = [];
    for (let i = 0; i < names.length; i++) {
      order.push(i);
    }
    order.sort((a: number, b: number): number => counts[b] - counts[a]);
    for (let i = 0; i < order.length && i < 5; i++) {
      const idx: number = order[i];
      const short: string = padShort(names[idx]);
      out.push(new RkPadItem(
        names[idx],
        short.length > 0 ? short : names[idx],
        placeZh(locs[idx]),
        locs[idx],
        counts[idx]
      ));
    }
    return out;
  }

  // ============ 即将 / 历史发射 ============

  /** 尚未发射的（口径与小程序 isStillUpcoming 一致：net 在未来，或状态未终结） */
  private upcoming(): LaunchSummary[] {
    const recs: LaunchSummary[] = this.records();
    const out: LaunchSummary[] = [];
    for (let i = 0; i < recs.length; i++) {
      if (isStillUpcoming(recs[i])) {
        out.push(recs[i]);
      }
    }
    out.sort((a: LaunchSummary, b: LaunchSummary): number => compareByNet(a, b));
    return out;
  }

  /** 已发射的，最近的在前 */
  private history(): LaunchSummary[] {
    const recs: LaunchSummary[] = this.records();
    const out: LaunchSummary[] = [];
    for (let i = 0; i < recs.length; i++) {
      if (!isStillUpcoming(recs[i])) {
        out.push(recs[i]);
      }
    }
    out.sort((a: LaunchSummary, b: LaunchSummary): number => compareByNet(b, a));
    return out;
  }

  private upcomingShown(): LaunchSummary[] {
    const list: LaunchSummary[] = this.upcoming();
    return this.upcomingOpen ? list : list.slice(0, FOLD);
  }

  private historyShown(): LaunchSummary[] {
    const list: LaunchSummary[] = this.history();
    return this.historyOpen ? list : list.slice(0, FOLD);
  }

  // ============ 简介 ============

  /** 超过视觉宽度阈值才给「展开全部」（对齐小程序 textUnits(descText) > 200） */
  private needFold(): boolean {
    return textUnits(this.desc) > DESC_UNITS_MAX;
  }

  /** 折叠态 4 行；展开态给一个足够大的行数（不写 Infinity，避免布局测量异常） */
  private descLines(): number {
    if (!this.needFold()) {
      return 1000;
    }
    return this.descExpanded ? 1000 : DESC_FOLD_LINES;
  }

  private descToggleText(): string {
    return this.descExpanded ? '收起' : '展开全部';
  }

  // ============ 数值格式化 ============

  /**
   * 数字转展示串：整数不带小数点，非整数保留 1 位。
   * 不用 toFixed 一刀切 —— 40 会变成 "40.0"，在「长度 40 米」里很别扭。
   */
  private oneDec(v: number): string {
    if (Number.isNaN(v)) {
      return '';
    }
    const r: number = Math.round(v * 10) / 10;
    if (r === Math.floor(r)) {
      return String(r);
    }
    return r.toFixed(1);
  }

  /** 千分位：1920 → "1,920" */
  private commaOf(n: number): string {
    const s: string = String(Math.round(n));
    let out: string = '';
    let count: number = 0;
    for (let i = s.length - 1; i >= 0; i--) {
      out = s.charAt(i) + out;
      count = count + 1;
      if (count % 3 === 0 && i > 0) {
        out = ',' + out;
      }
    }
    return out;
  }

  /** 小程序 fmtInt：<=0 直接给 '0'，否则四舍五入加千分位 */
  private fmtInt(n: number): string {
    if (Number.isNaN(n) || n <= 0) {
      return '0';
    }
    return this.commaOf(n);
  }

  /**
   * 日期只留 YYYY-MM-DD。
   * 数据本身就是 "2014-07-09"，但首飞/末飞偶尔带时分，按 10 位截断最省事。
   */
  private dateText(v: string): string {
    return v.length >= 10 ? v.slice(0, 10) : v;
  }

  // ============ 参数格组装 ============

  /**
   * 技术参数：顺序按「看火箭最先想知道的」排 —— 推力、粗细、运力、首飞、质量、造价。
   * 制造商**不在这里**：它已经变成战绩卡里的「发射机构」行，重复一遍是噪音。
   * 缺值直接不出现（小程序 paramList 的 push 只在 value 为真时才 push）。
   */
  private buildSpecs(x: RkLauncher): RkSpecRow[] {
    const cells: RkSpecCell[] = [];

    const thrust: number = x.to_thrust !== undefined ? x.to_thrust : 0;
    if (thrust > 0) {
      cells.push(new RkSpecCell('起飞推力', this.commaOf(thrust) + ' kN'));
    }

    const len: number = x.length !== undefined ? x.length : 0;
    if (len > 0) {
      cells.push(new RkSpecCell('长度', this.oneDec(len) + ' m'));
    }

    const dia: number = x.diameter !== undefined ? x.diameter : 0;
    if (dia > 0) {
      cells.push(new RkSpecCell('直径', this.oneDec(dia) + ' m'));
    }

    const stage: number = x.max_stage !== undefined ? x.max_stage : 0;
    if (stage > 0) {
      cells.push(new RkSpecCell('级数', String(stage) + ' 级'));
    }

    // 运力单位是千克，massText 内部会折成吨
    const leo: string = massText(x.leo_capacity !== undefined ? x.leo_capacity : 0);
    if (leo.length > 0) {
      cells.push(new RkSpecCell('LEO 运力', leo));
    }
    const gto: string = massText(x.gto_capacity !== undefined ? x.gto_capacity : 0);
    if (gto.length > 0) {
      cells.push(new RkSpecCell('GTO 运力', gto));
    }
    const geo: string = massText(x.geo_capacity !== undefined ? x.geo_capacity : 0);
    if (geo.length > 0) {
      cells.push(new RkSpecCell('GEO 运力', geo));
    }
    const sso: string = massText(x.sso_capacity !== undefined ? x.sso_capacity : 0);
    if (sso.length > 0) {
      cells.push(new RkSpecCell('SSO 运力', sso));
    }

    const maiden: string = this.dateText(strOf(x.maiden_flight).trim());
    if (maiden.length > 0) {
      cells.push(new RkSpecCell('首飞', maiden));
    }

    const mass: number = x.launch_mass !== undefined ? x.launch_mass : 0;
    if (mass > 0) {
      cells.push(new RkSpecCell('起飞质量', this.oneDec(mass) + ' 吨'));
    }

    // launch_cost 可能显式为 null（LL2 对部分型号没填），两个都要判
    const costVal: number = x.launch_cost !== undefined && x.launch_cost !== null ? x.launch_cost : 0;
    const costStr: string = costText(costVal);
    if (costStr.length > 0) {
      cells.push(new RkSpecCell('造价', costStr));
    }

    return this.toRows(cells);
  }

  /** 一维格子按 2 个一行切；奇数末行 hasRight=false，渲染时补 Blank 占位 */
  private toRows(cells: RkSpecCell[]): RkSpecRow[] {
    const rows: RkSpecRow[] = [];
    for (let i = 0; i < cells.length; i = i + 2) {
      const hasRight: boolean = i + 1 < cells.length;
      const right: RkSpecCell = hasRight ? cells[i + 1] : new RkSpecCell('', '');
      rows.push(new RkSpecRow(cells[i], right, hasRight));
    }
    return rows;
  }

  // ============ 状态徽章 / 托色 ============

  /** 状态文案（现役 / 已退役） */
  private statusText(): string {
    const cur: RkLauncher | null = this.curOrNull();
    return cur !== null && cur.active === true ? '现役' : '已退役';
  }

  private isActive(): boolean {
    const cur: RkLauncher | null = this.curOrNull();
    return cur !== null && cur.active === true;
  }

  private isReusable(): boolean {
    const cur: RkLauncher | null = this.curOrNull();
    return cur !== null && cur.reusable === true;
  }

  private stageCount(): number {
    const cur: RkLauncher | null = this.curOrNull();
    return cur !== null && cur.max_stage !== undefined ? cur.max_stage : 0;
  }

  /** 指标数值的托色：good 绿 / bad 红 / warn 金 / plain 主文字色 */
  private toneColor(tone: string): string {
    if (tone === 'good') {
      return '#4ADE80';
    }
    if (tone === 'bad') {
      return '#F87171';
    }
    if (tone === 'warn') {
      return '#F5C33B';
    }
    return TEXT_STRONG;
  }

  // ============ 交互 ============

  private back(): void {
    Nav.pop();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  /** 从存储层同步一次星标状态。键是型号名（RocketNavParam 的唯一入参）。 */
  private syncFaved(): void {
    this.faved = rocketFavHas(this.nameKey());
  }

  /**
   * 收藏用的键。
   *
   * 为什么不直接用 this.rocketName：它是路由入参，可能在 launchers 里还没定位到时
   * 就点了星标。this.cur 的 name 是定位成功后的名字，二者绝大多数情况相同，
   * 但归一化过的那个才是「清单里能点回来」的那个，所以优先用它。
   */
  private nameKey(): string {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur !== null) {
      const n: string = strOf(cur.name).trim();
      if (n.length > 0) {
        return n;
      }
    }
    return strOf(this.rocketName).trim();
  }

  /** 收藏切换。顶栏星标与简介卡胶囊共用这一个入口，状态同源 */
  private onTapFav(): void {
    const key: string = this.nameKey();
    if (key.length === 0) {
      return;
    }
    const cur: RkLauncher | null = this.curOrNull();
    const img: string = cur === null ? '' : strOf(cur.image).trim();
    const now: boolean = rocketFavToggle(new MvRocketFav(key, img, Date.now()));
    this.faved = now;
    this.toast(now ? '已收藏，可在「我的」查看' : '已取消收藏');
  }

  /** Hero 第 i 张点开看大图：优先原图（full），推不出来就用缩略图自己 */
  private openPhoto(i: number): void {
    const list: RkSlide[] = this.slides();
    if (i < 0 || i >= list.length) {
      return;
    }
    const s: RkSlide = list[i];
    const url: string = s.full.length > 0 ? s.full : s.thumb;
    if (url.length === 0) {
      return;
    }
    Nav.pushPhoto(new PhotoNavParam(url, this.titleText()));
  }

  /**
   * 「图片库 N」入口 → 型号媒体库的图片库分页。
   *
   * 小程序会带 tab（图片库 / 视频库两个入口），鸿蒙侧把两个入口合成一个：
   * hero 上那颗胶囊默认落图片库，用户进去自己切 —— 省一颗胶囊，行为一致。
   * 入参用型号英文原名（launchers 的 name），因为 MediaView 靠它回 launchers 找构型。
   */
  private goMedia(): void {
    const cur: RkLauncher | null = this.curOrNull();
    const name: string = cur === null ? '' : strOf(this.configOf(cur).name).trim();
    if (name.length === 0) {
      return;
    }
    Nav.pushMedia(name, 0);
  }

  /** 制造方面包屑 → 机构页。只带名字，AgencyView 自己按 id → 名字匹配（见取舍 9） */
  private goAgency(): void {
    const raw: string = this.makerRaw();
    if (raw.length === 0) {
      return;
    }
    Nav.pushAgency(new AgencyNavParam('', raw));
  }

  /** 发射机构行 → 机构页（用记录里第一个机构的英文原名） */
  private goAgencyOfRecord(): void {
    const names: string[] = this.agencyRawNames();
    if (names.length === 0) {
      return;
    }
    Nav.pushAgency(new AgencyNavParam('', names[0]));
  }

  /** 发射场地 → 工位页。place 用来消歧同名工位（pads.json 里有多条 "Unknown Pad"） */
  private goPad(p: RkPadItem): void {
    if (p.name.length === 0) {
      return;
    }
    Nav.pushPad(new PadNavParam('', p.name, p.locationRaw));
  }

  /** 发射卡 → 发射详情 */
  private openLaunch(item: LaunchSummary): void {
    Nav.pushLaunch(new LaunchNavParam(strOf(item.id), strOf(item.net), launchTitle(item)));
  }

  /** 复制外链 + toast。小程序打不开外链（web-view 需业务域名），只能复制 */
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
        hilog.warn(DOMAIN, TAG, '剪贴板写入失败: %{public}s', e.message);
        this.toast('复制失败');
      });
  }

  private retry(): void {
    this.loadLauncher(true);
  }

  // ============ UI：返回栏 ============

  /**
   * 自绘顶部栏。NavDestination 那边 hideTitleBar(true)，标题由这里画
   * （这样「‹ 返回」的热区和字号都能自己定）。
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
          .fontColor('#A7B4C7')
          .margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Center)
      // 上下各 10vp 把热区撑到约 40vp，别让 14vp 的字直接当可点区域
      .padding({ right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        this.back();
      })

      Text(this.barTitle())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // 收藏星标（鸿蒙增量，小程序只在简介卡里有入口）。
      // 只在定位到型号之后才可点 —— 没定位到时 nameKey() 是空串，收藏进去也点不回来。
      if (this.found) {
        Text(this.faved ? '★' : '☆')
          .fontSize(20)
          .fontColor(this.faved ? STAR_YELLOW : '#A7B4C7')
          .padding({ left: 10, top: 10, bottom: 10 })
          .onClick(() => {
            this.onTapFav();
          })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .backgroundColor(BG_PRIMARY)
  }

  // ============ UI：Hero ============

  /** 2×2 点阵（小程序 .hm-icon 的四个小方块），用两个 Row 拼 */
  @Builder
  mediaIcon() {
    Column() {
      Row() {
        Row().width(3).height(3).borderRadius(1).backgroundColor('#E6FFFFFF').margin({ right: 2 })
        Row().width(3).height(3).borderRadius(1).backgroundColor('#E6FFFFFF')
      }
      Row() {
        Row().width(3).height(3).borderRadius(1).backgroundColor('#E6FFFFFF').margin({ right: 2 })
        Row().width(3).height(3).borderRadius(1).backgroundColor('#E6FFFFFF')
      }
      .margin({ top: 2 })
    }
    .width(8)
    .height(8)
    .margin({ right: 5 })
  }

  /** 无图占位：160deg 渐变 + 80vp 的 🚀（opacity .18） */
  @Builder
  heroPlaceholder() {
    Column() {
      Text('🚀')
        .fontSize(80)
        .opacity(0.18)
    }
    .width('100%')
    .height(HERO_H)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .linearGradient({
      angle: 160,
      colors: [['#FF1B2C47', 0.0], ['#FF0D1420', 1.0]]
    })
  }

  /**
   * Hero：通栏、280vp、信息压在底部渐变上。
   *
   * 小程序这一块是 absolute 定位 + swiper；ArkUI 用 Stack 的 BottomStart 对齐，
   * 轮播/占位铺满，遮罩只在底部 200vp，面包屑与圆点各自 .align 到上角。
   * 遮罩要 hitTestBehavior(None)，否则右上角那一小条会截走 Swiper 的滑动手势。
   */
  @Builder
  hero() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 1 轮播 / 单图 / 占位
      if (this.slides().length > 1) {
        Swiper() {
          ForEach(this.slides(), (s: RkSlide, i: number) => {
            Image(s.thumb)
              .width('100%')
              .height(HERO_H)
              .objectFit(ImageFit.Cover)
              .backgroundColor('#0F1520')
              .onClick(() => {
                this.openPhoto(i);
              })
          }, (s: RkSlide, i: number) => 'hero' + s.thumb + String(i))
        }
        .width('100%')
        .height(HERO_H)
        .autoPlay(true)
        .interval(5200)
        .duration(600)
        .loop(true)
        // 指示点自绘（小程序 .hero-dots 在右上角，且当前页拉成 13vp 短胶囊）
        .indicator(false)
        .onChange((idx: number) => {
          this.slide = idx;
        })
      } else if (this.slides().length === 1 && !this.imgErr) {
        Image(this.slides()[0].thumb)
          .width('100%')
          .height(HERO_H)
          .objectFit(ImageFit.Cover)
          .backgroundColor('#0F1520')
          .onError(() => {
            // 破图退回渐变占位，比留一块 280vp 的空白好
            this.imgErr = true;
          })
          .onClick(() => {
            this.openPhoto(0);
          })
      } else {
        this.heroPlaceholder()
      }

      // 2 底部压黑：to bottom = angle 180，从透明的 #0A0E17 到实心
      Column()
        .width('100%')
        .height(HERO_MASK_H)
        .align(Alignment.BottomStart)
        .linearGradient({
          angle: 180,
          colors: [
            ['#000A0E17', 0.0],
            ['#CC0A0E17', 0.5],
            ['#FF0A0E17', 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      // 3 制造方面包屑（左上）：点了去机构详情
      if (this.makerText().length > 0) {
        Row() {
          Text(this.makerText())
            .fontSize(11.5)
            .fontColor('#DBE6F5')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Row()
            .width(6)
            .height(6)
            .border({ width: { right: 1, bottom: 1 }, color: '#9FB0C6' })
            .rotate({ angle: 45 })
            .margin({ left: 5 })
        }
        .alignItems(VerticalAlign.Center)
        .padding({ left: 9, right: 9, top: 4, bottom: 4 })
        .borderRadius(15)
        .backgroundColor('#6B080C14')
        .align(Alignment.TopStart)
        .margin({ left: 12, top: 10 })
        .onClick(() => {
          this.goAgency();
        })
      }

      // 4 轮播圆点（右上）：只有多图才画，与面包屑同高对称
      if (this.slides().length > 1) {
        Row() {
          ForEach(this.slides(), (s: RkSlide, i: number) => {
            Row()
              .width(this.slide === i ? 13 : 5)
              .height(5)
              .borderRadius(3)
              .backgroundColor(this.slide === i ? '#F2FFFFFF' : '#61FFFFFF')
              .margin({ right: 5 })
          }, (s: RkSlide, i: number) => 'dot' + String(i))
        }
        .alignItems(VerticalAlign.Center)
        .align(Alignment.TopEnd)
        .margin({ right: 12, top: 10 })
        // 纯指示，不接事件 —— 否则右上角那一小条会截走滑动
        .hitTestBehavior(HitTestMode.None)
      }

      // 5 底部文字块：标题 / 副标题 / （状态标签 + 图片库入口）同一行
      Column() {
        Text(this.titleText())
          .fontSize(26)
          .fontWeight(600)
          .fontColor(TEXT_MAIN)
          .lineHeight(33)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textShadow({ radius: 8, color: '#80000000', offsetX: 0, offsetY: 1 })

        if (this.subName().length > 0) {
          Text(this.subName())
            .fontSize(13)
            .fontColor('#A8B6C8')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 5 })
        }

        // 状态标签靠左、图片库入口靠右，共用一行：
        // 入口放这里比放页面中部更早看到，也不再占一整张卡
        Row() {
          // 用 Flex 而不是 Row：Row 不支持自动换行，标签 2~3 个宽度不一时会被压缩
          Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
            Text(this.statusText())
              .fontSize(11)
              .fontColor(this.isActive() ? '#4ADE80' : '#8A97A8')
              .backgroundColor(this.isActive() ? '#2934C759' : '#12FFFFFF')
              .borderRadius(4)
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .margin({ right: 6, bottom: 2 })

            if (this.isReusable()) {
              Text('可复用')
                .fontSize(11)
                .fontColor('#C3CEDD')
                .backgroundColor('#14FFFFFF')
                .borderRadius(4)
                .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                .margin({ right: 6, bottom: 2 })
            }

            if (this.stageCount() > 0) {
              Text(String(this.stageCount()) + ' 级')
                .fontSize(11)
                .fontColor('#C3CEDD')
                .backgroundColor('#14FFFFFF')
                .borderRadius(4)
                .padding({ left: 9, right: 9, top: 3, bottom: 3 })
                .margin({ right: 6, bottom: 2 })
            }
          }
          .layoutWeight(1)

          // 「图片库 N」磨砂胶囊。数字是图片张数（mediaCount），目的地是视频库（见取舍 8）
          if (this.mediaCount() > 0) {
            Row() {
              this.mediaIcon()
              Text('图片库')
                .fontSize(11)
                .fontColor('#FFFFFF')
              Text(String(this.mediaCount()))
                .fontSize(11)
                .fontColor('#99FFFFFF')
                .margin({ left: 4 })
            }
            .alignItems(VerticalAlign.Center)
            .padding({ left: 9, right: 9, top: 3.5, bottom: 3.5 })
            .borderRadius(999)
            .backgroundColor('#24FFFFFF')
            .border({ width: 1, color: '#38FFFFFF' })
            // 磨砂：blur 20rpx = 10vp（半透明底 + 背景模糊，压在任何亮度的图上都能读）
            .backdropBlur(10)
            .margin({ left: 8, bottom: 2 })
            .onClick(() => {
              this.goMedia();
            })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 9 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, bottom: 17 })
    }
    .width('100%')
    .height(HERO_H)
    // 通栏：不留边距、不裁圆角、不加 clip（小程序 .hero 直接顶到屏幕两侧，
    // 裁切只会让 Swiper 边缘的字描边被切掉，没有收益）
  }

  // ============ UI：通用小件 ============

  /**
   * 卡片 / 区块标题的统一排版件：左标题 + 右小字。
   *
   * ⚠ 下面这一整组标题**必须各自是无参 @Builder**，不能做成 `head(title, note)`
   *   这种按值传参的通用件：本工程踩过两次 —— @Builder 按值传参不建立响应式依赖，
   *   切构型后标题右侧的 variant / 计数会停在旧值，而左边文字却变了。
   *   所以每处标题各写一个无参 builder，直接读 this.xxx。
   */
  @Builder
  specHead() {
    Row() {
      Text('技术参数')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
      Blank()
      Text(this.variantNote())
        .fontSize(11)
        .fontColor(TEXT_MUTED)
        .maxLines(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ bottom: 8 })
  }

  @Builder
  recordHead() {
    Row() {
      Text('发射战绩')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
      Blank()
      Text(this.variantNote())
        .fontSize(11)
        .fontColor(TEXT_MUTED)
        .maxLines(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ bottom: 8 })
  }

  @Builder
  landingHead() {
    Row() {
      Text('回收记录')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
      Blank()
      // 只有可复用的型号才标；不可复用时不画空 Text（会占一行高）
      if (this.reusableNote().length > 0) {
        Text(this.reusableNote())
          .fontSize(11)
          .fontColor(TEXT_MUTED)
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ bottom: 8 })
  }

  @Builder
  linksHead() {
    Row() {
      Text('外部资料')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .margin({ bottom: 8 })
  }

  /** 区块标题行（无卡片底的 section）：左标题 + 右小字，底部留 7vp */
  @Builder
  variantsHead() {
    Row() {
      Text('切换构型')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
      Blank()
      Text(String(this.variants().length) + ' 型')
        .fontSize(11)
        .fontColor(TEXT_MUTED)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: 3, right: 3, bottom: 7 })
  }

  @Builder
  coresHead() {
    Row() {
      Text('芯级')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
      Blank()
      Text(String(this.cores().length) + ' 枚')
        .fontSize(11)
        .fontColor(TEXT_MUTED)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: 3, right: 3, bottom: 7 })
  }

  @Builder
  padsHead() {
    Row() {
      Text('发射场地')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
      Blank()
      Text('按发射次数')
        .fontSize(11)
        .fontColor(TEXT_MUTED)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: 3, right: 3, bottom: 7 })
  }

  @Builder
  upcomingHead() {
    Row() {
      Text('即将发射')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
      Blank()
      Text(String(this.upcoming().length) + ' 次')
        .fontSize(11)
        .fontColor(TEXT_MUTED)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: 3, right: 3, bottom: 7 })
  }

  @Builder
  historyHead() {
    Row() {
      Text('历史发射')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(TEXT_MAIN)
      Blank()
      // 快照只有最近 100 条，标题如实写「近期」，别让人以为是全历史
      Text('近期 ' + String(this.history().length) + ' 次')
        .fontSize(11)
        .fontColor(TEXT_MUTED)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: 3, right: 3, bottom: 7 })
  }

  /** 一格指标：17vp 数值 + 10vp 标签，宽度 1/3（5 格时自然排成 3+2） */
  @Builder
  metricCell(m: RkMetric) {
    Column() {
      Text(m.value)
        .fontSize(17)
        .fontWeight(600)
        .fontColor(this.toneColor(m.tone))
        .maxLines(1)
      Text(m.label)
        .fontSize(10)
        .fontColor(TEXT_MUTED)
        .maxLines(1)
        .margin({ top: 2 })
    }
    .width('33.33%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 5, bottom: 5 })
  }

  /** 参数格：10vp 标签（0.5 字距）+ 14vp 值，带极淡底色 */
  @Builder
  specCell(cell: RkSpecCell) {
    Column() {
      Text(cell.label)
        .fontSize(10)
        .fontColor(TEXT_MUTED)
        .letterSpacing(0.5)
        .maxLines(1)
        .width('100%')
      Text(cell.value)
        .fontSize(14)
        .fontWeight(600)
        .fontColor(TEXT_STRONG)
        .lineHeight(19)
        // 机构名/运力这类长串在半列宽里放不下，给 2 行比截成 "Khrunichev…" 有用
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 3 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 9, right: 9, top: 8, bottom: 8 })
    .backgroundColor('#08FFFFFF')
    .borderRadius(6)
  }

  /**
   * 展开/收起胶囊按钮。
   *
   * ⚠ 同样不能写成 `moreButton(text, onTap)`：文案依赖 xxxOpen 这个 @State，
   *   按值传参后点击不会刷新文字（会永久停在「展开全部」）。
   *   所以三处各一个无参 builder，直接读 this.xxxOpen。
   */
  @Builder
  coresMore() {
    Row() {
      Text(this.coresOpen ? '收起' : '展开全部 ' + String(this.cores().length) + ' 枚')
        .fontSize(12)
        .fontColor('#8A97A8')
    }
    .width('100%')
    .height(38)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#0AFFFFFF')
    .borderRadius(19)
    // 小程序 .more-btn margin-top 4rpx = 2vp
    .margin({ top: 2 })
    .onClick(() => {
      this.coresOpen = !this.coresOpen;
    })
  }

  @Builder
  upcomingMore() {
    Row() {
      Text(this.upcomingOpen ? '收起' : '展开全部 ' + String(this.upcoming().length) + ' 次')
        .fontSize(12)
        .fontColor('#8A97A8')
    }
    .width('100%')
    .height(38)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#0AFFFFFF')
    .borderRadius(19)
    // 小程序 .more-btn margin-top 4rpx = 2vp
    .margin({ top: 2 })
    .onClick(() => {
      this.upcomingOpen = !this.upcomingOpen;
    })
  }

  @Builder
  historyMore() {
    Row() {
      Text(this.historyOpen ? '收起' : '展开全部 ' + String(this.history().length) + ' 次')
        .fontSize(12)
        .fontColor('#8A97A8')
    }
    .width('100%')
    .height(38)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#0AFFFFFF')
    .borderRadius(19)
    // 小程序 .more-btn margin-top 4rpx = 2vp
    .margin({ top: 2 })
    .onClick(() => {
      this.historyOpen = !this.historyOpen;
    })
  }

  // ============ UI：切换构型 ============

  @Builder
  variantSection() {
    Column() {
      this.variantsHead()

      // 横滑：Scroll 比 List 轻，chip 数量最多十几个
      Scroll() {
        Row() {
          ForEach(this.variants(), (v: RkVariant) => {
            Text(v.chipName)
              .fontSize(12)
              .fontWeight(v.cur ? 600 : 400)
              .fontColor(v.cur ? ACCENT : '#9AA8BA')
              .padding({ left: 13, right: 13, top: 6, bottom: 6 })
              .borderRadius(999)
              .backgroundColor(v.cur ? '#2438BDF8' : CARD_BG)
              .border({
                width: 1,
                color: v.cur ? '#7338BDF8' : '#12FFFFFF'
              })
              // 已退役且不是当前构型的灰下去（小程序 .vchip.off opacity .5）
              .opacity(!v.active && !v.cur ? 0.5 : 1)
              .margin({ right: 6 })
              .onClick(() => {
                this.switchTo(v);
              })
          }, (v: RkVariant) => v.key)
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(38)

      // 当前构型全名：chip 里只有构型短名，这里补全名消歧
      if (this.currentFullName().length > 0) {
        Text(this.currentFullName())
          .fontSize(10.5)
          .fontColor('#5D6A7E')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 7 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 15 })
  }

  /** 当前构型的全名（小程序 .vchip-cur 的 config.full_name || config.name） */
  private currentFullName(): string {
    const cur: RkLauncher | null = this.curOrNull();
    if (cur === null) {
      return '';
    }
    const full: string = strOf(cur.full_name).trim();
    return full.length > 0 ? full : strOf(cur.name).trim();
  }

  // ============ UI：简介卡 ============

  @Builder
  descCard() {
    Column() {
      Row() {
        Text('简介')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(TEXT_MAIN)

        Blank()

        // 收藏胶囊（与顶栏星标共用 faved）。
        // 小程序的分享胶囊不迁：ArkUI 没有 open-type=share 的等价物（见取舍 7）。
        Row() {
          Text(this.faved ? '★' : '☆')
            .fontSize(11.5)
            .fontColor(this.faved ? STAR_YELLOW : '#A8B6C8')
            .margin({ right: 3 })
          Text(this.faved ? '已收藏' : '收藏')
            .fontSize(11)
            .fontColor(this.faved ? STAR_YELLOW : '#A8B6C8')
        }
        .alignItems(VerticalAlign.Center)
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .borderRadius(999)
        .backgroundColor(this.faved ? '#24FFD60A' : '#12FFFFFF')
        .border({ width: 1, color: this.faved ? '#66FFD60A' : '#1FFFFFFF' })
        .margin({ left: 8 })
        .onClick(() => {
          this.onTapFav();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 8 })

      if (this.desc.length > 0) {
        Text(this.desc)
          .fontSize(13.5)
          .fontColor(TEXT_BODY)
          .lineHeight(24)
          .maxLines(this.descLines())
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      } else {
        // 约 11% 的型号没有简介：卡片还得在，否则收藏入口跟着消失
        Text('暂无简介')
          .fontSize(13)
          .fontColor(TEXT_MUTED)
          .width('100%')
      }

      if (this.needFold()) {
        // 展开按钮居中 + 上边框：与正文之间有一条分割线，点了不会误触正文
        Row() {
          Text(this.descToggleText())
            .fontSize(12)
            .fontColor(ACCENT)
          Row()
            .width(6)
            .height(6)
            .border({ width: { right: 1.5, bottom: 1.5 }, color: ACCENT })
            .rotate({ angle: this.descExpanded ? -135 : 45 })
            .margin({ left: 5 })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .padding({ top: 7, bottom: 2 })
        .margin({ top: 8 })
        .border({ width: { top: 1 }, color: '#0DFFFFFF' })
        .onClick(() => {
          this.descExpanded = !this.descExpanded;
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: '#0DFFFFFF' })
    .margin({ top: CARD_MT })
  }

  // ============ UI：技术参数卡 ============

  @Builder
  specCard() {
    Column() {
      this.specHead()

      ForEach(this.specs, (row: RkSpecRow) => {
        Row() {
          this.specCell(row.left)
          if (row.hasRight) {
            Row().width(6)
            this.specCell(row.right)
          } else {
            // 奇数个参数：右侧留同权重空位，保证左列不被拉宽
            Blank().layoutWeight(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .margin({ bottom: 6 })
      }, (row: RkSpecRow) => row.left.label)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: '#0DFFFFFF' })
    .margin({ top: CARD_MT })
  }

  // ============ UI：发射战绩 ============

  @Builder
  recordCard() {
    Column() {
      this.recordHead()

      // 发射机构：从该系列全部发射记录聚合，单机构可点进机构页。
      // 3.1.3 系列视角重构时旧版把这一行弄丢了，用户找不到入口。
      if (this.agencyRawNames().length > 0) {
        Row() {
          Text('发射机构')
            .fontSize(11.5)
            .fontColor(TEXT_MUTED)
          if (this.agencyFlagText().length > 0) {
            // 工程里没有国旗 png，flagOf 返回 emoji
            Text(this.agencyFlagText())
              .fontSize(13)
              .margin({ left: 5 })
          }
          Text(this.agencyZhText())
            .fontSize(12.5)
            .fontColor(TEXT_BODY)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .margin({ left: 5 })
          Row()
            .width(6)
            .height(6)
            .border({ width: { right: 1, bottom: 1 }, color: TEXT_MUTED })
            .rotate({ angle: 45 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 9, right: 9, top: 7, bottom: 7 })
        .borderRadius(6)
        .backgroundColor('#0AFFFFFF')
        .margin({ bottom: 9 })
        .onClick(() => {
          this.goAgencyOfRecord();
        })
      }

      // 主指标：成功率放大，右侧挂总发射与连续成功
      Row() {
        Row() {
          Text(this.rateText())
            .fontSize(32)
            .fontWeight(700)
            .fontColor('#4ADE80')
            .lineHeight(32)
            .letterSpacing(-0.5)
          // 小程序是 align-items:baseline；ArkUI 的 ItemAlign.Baseline 只在 Flex 上有先例，
          // 这里用 Row 底对齐 + 2vp 下移近似，视觉差 < 1vp
          Text('成功率')
            .fontSize(11)
            .fontColor(TEXT_MUTED)
            .margin({ left: 6, bottom: 2 })
        }
        .alignItems(VerticalAlign.Bottom)

        Blank()

        Column() {
          Row() {
            Text('总发射')
              .fontSize(11)
              .fontColor(TEXT_SOFT)
            Text(this.statsTotal())
              .fontSize(11)
              .fontWeight(600)
              .fontColor(TEXT_STRONG)
              .margin({ left: 3 })
          }
          .alignItems(VerticalAlign.Center)

          Row() {
            Text('连续成功')
              .fontSize(11)
              .fontColor(TEXT_SOFT)
            Text(this.streakText())
              .fontSize(11)
              .fontWeight(600)
              .fontColor(TEXT_STRONG)
              .margin({ left: 3 })
          }
          .alignItems(VerticalAlign.Center)
          .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ top: 2, bottom: 10 })

      if (this.stats().length > 0) {
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          ForEach(this.stats(), (m: RkMetric) => {
            this.metricCell(m)
          }, (m: RkMetric) => 'stat' + m.label)
        }
        .width('100%')
        .padding({ top: 8 })
        .border({ width: { top: 1 }, color: '#0FFFFFFF' })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: '#0DFFFFFF' })
    .margin({ top: CARD_MT })
  }

  // ============ UI：回收记录 ============

  @Builder
  landingCard() {
    Column() {
      this.landingHead()

      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        ForEach(this.landingStats(), (m: RkMetric) => {
          this.metricCell(m)
        }, (m: RkMetric) => 'land' + m.label)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: '#0DFFFFFF' })
    .margin({ top: CARD_MT })
  }

  // ============ UI：芯级 ============

  /** 芯级一行：编号 + 状态徽章 / 已飞 / 回收 / 末飞 / 可展开简介 */
  @Builder
  coreRow(item: RkCoreItem, first: boolean) {
    Column() {
      Column() {
        Row() {
          Text(item.serial)
            .fontSize(14)
            .fontWeight(600)
            .fontColor('#E2E8F0')
          Text(item.statusText)
            .fontSize(10)
            .fontColor(item.statusCls === 'ok' ? ACCENT : (item.statusCls === 'bad' ? '#F87171' : TEXT_MUTED))
            .backgroundColor(item.statusCls === 'ok'
              ? '#2938BDF8'
              : (item.statusCls === 'bad' ? '#24F87171' : '#0FFFFFFF'))
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .borderRadius(3)
            .margin({ left: 7 })
          Blank()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          Text('已飞 ' + String(item.flights) + ' 次')
            .fontSize(11)
            .fontColor('#94A3B8')
          if (item.showLanding) {
            Text('回收成功 ' + String(item.landed) + '/' + String(item.landedTry))
              .fontSize(11)
              .fontColor('#94A3B8')
              .margin({ left: 10 })
          }
          Blank()
          if (item.last.length > 0) {
            Text('末飞 ' + item.last)
              .fontSize(11)
              .fontColor(TEXT_MUTED)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 4 })

        // 简介按需展开：只有点开的那一枚才画，避免一次性铺 196 条长文
        if (this.openCoreKey === item.key && item.details.length > 0) {
          Text(item.details)
            .fontSize(11)
            .fontColor('#94A3B8')
            .lineHeight(17.6)
            .width('100%')
            .padding({ left: 9, right: 9, top: 7, bottom: 7 })
            .backgroundColor('#08FFFFFF')
            .borderRadius(6)
            .margin({ top: 6 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ top: 11, bottom: 11 })
      .border({ width: { top: first ? 0 : 1 }, color: '#0AFFFFFF' })
    }
    .width('100%')
    .onClick(() => {
      this.openCoreKey = this.openCoreKey === item.key ? '' : item.key;
    })
  }

  @Builder
  coresSection() {
    Column() {
      this.coresHead()

      // 展开按钮在小程序里是 .core-card 的子节点（在卡片内部，左右留 12vp）
      Column() {
        ForEach(this.coresShown(), (item: RkCoreItem, idx: number) => {
          this.coreRow(item, idx === 0)
        }, (item: RkCoreItem) => 'core' + item.key)

        if (this.cores().length > CORE_FOLD) {
          this.coresMore()
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 3, bottom: 3 })
      .backgroundColor(CARD_BG)
      .borderRadius(CARD_RADIUS)
      .border({ width: 1, color: '#0DFFFFFF' })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 15 })
  }

  // ============ UI：发射场地 ============

  @Builder
  padRow(item: RkPadItem, first: boolean) {
    Row() {
      Column() {
        Text(item.short)
          .fontSize(13)
          .fontColor('#E2E8F0')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row() {
          if (item.locationZh.length > 0) {
            Text(item.locationZh)
              .fontSize(11)
              .fontColor(TEXT_MUTED)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          if (item.count > 0) {
            Text(String(item.count) + ' 次')
              .fontSize(11)
              .fontColor(ACCENT)
              .margin({ left: 7 })
          }
        }
        .alignItems(VerticalAlign.Center)
        .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Row()
        .width(7)
        .height(7)
        .border({ width: { right: 1, bottom: 1 }, color: '#3D4A5C' })
        .rotate({ angle: 45 })
        .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 11, bottom: 11 })
    .border({ width: { top: first ? 0 : 1 }, color: '#0AFFFFFF' })
    .onClick(() => {
      this.goPad(item);
    })
  }

  @Builder
  padsSection() {
    Column() {
      this.padsHead()

      Column() {
        ForEach(this.pads(), (item: RkPadItem, idx: number) => {
          this.padRow(item, idx === 0)
        }, (item: RkPadItem) => 'pad' + item.name)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 3, bottom: 3 })
      .backgroundColor(CARD_BG)
      .borderRadius(CARD_RADIUS)
      .border({ width: 1, color: '#0DFFFFFF' })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 15 })
  }

  // ============ UI：即将 / 历史发射 ============

  @Builder
  upcomingSection() {
    Column() {
      this.upcomingHead()

      ForEach(this.upcomingShown(), (item: LaunchSummary) => {
        Column() {
          LaunchCard({
            item: item,
            onSelect: (picked: LaunchSummary) => {
              this.openLaunch(picked);
            }
          })
        }
        .width('100%')
        .margin({ top: 8 })
      }, (item: LaunchSummary) => 'up' + strOf(item.id))

      if (this.upcoming().length > FOLD) {
        this.upcomingMore()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 15 })
  }

  @Builder
  historySection() {
    Column() {
      this.historyHead()

      ForEach(this.historyShown(), (item: LaunchSummary) => {
        Column() {
          LaunchCard({
            item: item,
            onSelect: (picked: LaunchSummary) => {
              this.openLaunch(picked);
            }
          })
        }
        .width('100%')
        .margin({ top: 8 })
      }, (item: LaunchSummary) => 'his' + strOf(item.id))

      if (this.history().length > FOLD) {
        this.historyMore()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 15 })
  }

  // ============ UI：外部资料 ============

  /**
   * 两行外链各一个无参 builder。
   * 原来写成 `linkRow(name, url, label, first)` 时，`first` 由 this.infoUrl() 推出，
   * 而按值传参不会跟着 @State 走 —— 切换构型后「有没有上边框」会停在旧构型。
   * 现在分隔线由 linksCard 自己画，行内不再需要 first。
   */
  @Builder
  infoLink() {
    Row() {
      Text('官方网站')
        .fontSize(13.5)
        .fontColor('#E2E8F0')
      Blank()
      Text('复制链接')
        .fontSize(12)
        .fontColor(ACCENT)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 9, bottom: 9 })
    .onClick(() => {
      this.copyLink(this.infoUrl(), '官网');
    })
  }

  @Builder
  wikiLink() {
    Row() {
      Text('维基百科')
        .fontSize(13.5)
        .fontColor('#E2E8F0')
      Blank()
      Text('复制链接')
        .fontSize(12)
        .fontColor(ACCENT)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 9, bottom: 9 })
    .onClick(() => {
      this.copyLink(this.wikiUrl(), '维基百科');
    })
  }

  @Builder
  linksCard() {
    Column() {
      this.linksHead()

      if (this.infoUrl().length > 0) {
        this.infoLink()
      }
      // 两条都在时补一条 1vp 分隔线；只画在第二行上方，与小程序的 border-top 一致
      if (this.infoUrl().length > 0 && this.wikiUrl().length > 0) {
        Row()
          .width('100%')
          .height(1)
          .backgroundColor('#0DFFFFFF')
      }
      if (this.wikiUrl().length > 0) {
        this.wikiLink()
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: '#0DFFFFFF' })
    .margin({ top: CARD_MT })
  }

  private infoUrl(): string {
    const cur: RkLauncher | null = this.curOrNull();
    return cur === null ? '' : strOf(cur.info_url).trim();
  }

  private wikiUrl(): string {
    const cur: RkLauncher | null = this.curOrNull();
    return cur === null ? '' : strOf(cur.wiki_url).trim();
  }

  // ============ UI：三态占位 ============

  /** 加载态：小程序就是一行英文三点的 `加载中...`，不是菊花 + 中文省略号 */
  @Builder
  loadingBlock() {
    Column() {
      Text('加载中...')
        .fontSize(14)
        .fontColor(TEXT_MUTED)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  notFoundBlock() {
    Column() {
      Text('🛰️')
        .fontSize(36)
      Text('未找到该型号')
        .fontSize(14)
        .fontColor('#A7B4C7')
        .margin({ top: 8 })
      Row() {
        Text('返回')
          .fontSize(13)
          .fontColor(ACCENT)
      }
      .padding({ left: 28, right: 28, top: 9, bottom: 9 })
      .borderRadius(30)
      .backgroundColor('#2438BDF8')
      .margin({ top: 16 })
      .onClick(() => {
        this.back();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  failedBlock() {
    Column() {
      Text('火箭数据加载失败')
        .fontSize(14)
        .fontColor('#A7B4C7')
      Text('网络不给力，或缓存已被清理')
        .fontSize(12)
        .fontColor(TEXT_MUTED)
        .margin({ top: 8 })

      Row() {
        Text('重试')
          .fontSize(13)
          .fontColor(ACCENT)
      }
      .padding({ left: 24, right: 24, top: 9, bottom: 9 })
      .borderRadius(30)
      .backgroundColor('#2438BDF8')
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

  // ============ build ============

  build() {
    Column() {
      this.topBar()

      if (this.loading && !this.found) {
        this.loadingBlock()
      } else if (this.failed && !this.found) {
        this.failedBlock()
      } else if (!this.found) {
        this.notFoundBlock()
      } else {
        Scroll(this.scroller) {
          Column() {
            // Hero 通栏（无左右边距、无圆角）
            this.hero()

            // body 上浮 8vp 压住 Hero 底部渐变，内容区才留左右内边距
            Column() {
              // 1 切换构型（只有 1 型时整块不出现）
              if (this.variants().length > 1) {
                this.variantSection()
              }
              // 2 简介（永远在，见取舍 6）
              this.descCard()
              // 3 技术参数
              if (this.specs.length > 0) {
                this.specCard()
              }
              // 4 发射战绩
              if (this.hasRecord()) {
                this.recordCard()
              }
              // 5 回收记录
              if (this.landingStats().length > 0) {
                this.landingCard()
              }
              // 6 芯级
              if (this.cores().length > 0) {
                this.coresSection()
              }
              // 7 发射场地
              if (this.pads().length > 0) {
                this.padsSection()
              }
              // 8 即将发射
              if (this.upcoming().length > 0) {
                this.upcomingSection()
              }
              // 9 历史发射
              if (this.history().length > 0) {
                this.historySection()
              }
              // 10 外部资料
              if (this.infoUrl().length > 0 || this.wikiUrl().length > 0) {
                this.linksCard()
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: PAGE_PAD, right: PAGE_PAD })
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
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }
}
