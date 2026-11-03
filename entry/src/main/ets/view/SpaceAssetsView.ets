/**
 * view/SpaceAssetsView.ets —— 「太空资产」页（三个 tab：全球在轨 / 卫星百科 / 解体·再入）
 *
 * 对位小程序：pages/space-assets/space-assets.vue（三 tab）+ 三个 section 组件：
 *   components/orbit-section    → statsPanel()
 *   components/catalog-section  → catalogPanel() + detailSheet()
 *   components/debris-section   → debrisPanel()
 *
 * ── 尺寸口径 ──
 *   小程序 wxss 的 rpx ÷ 2 = 鸿蒙 vp。颜色、字号、间距、圆角、进度条高度一律照抄，
 *   不按「工程约定」二次换算，否则截图比对永远差一截。
 *   例：hero-title 44rpx=22vp、tab 高 64rpx=32vp、col-slot 220rpx=110vp。
 *
 * ── 为什么三段切换不用 Tabs 组件 ──
 *   小程序的 tab 是「选中即实底 #38bdf8 + 深色字 #06121f」，Tabs 的默认样式要一路
 *   覆盖到 tabBar 内部节点，反而更脆。这里用手写 Row + Text，视觉逐值照抄。
 *
 * ── 为什么三个 tab 各自懒加载 ──
 *   satellites 索引自带 800 条（约 220KB），debris-events 1600 条，
 *   一进页就把三个数据集全拉一遍，弱网下首屏要等三份 JSON。
 *
 * ── 为什么全量不进 @State ──
 *   卫星目录全量 20109 条 × 23 个字段。塞 @State 意味着每条都被代理包一层、
 *   每次刷新全量脏检查，滚动会明显掉帧。所以全量放普通成员 all / allDebris，
 *   @State 只留「当前要画的那几十条」与计数。
 *
 * ── 为什么 @Builder 分两层 ──
 *   ArkTS 里按值传参的 @Builder **不建立响应式依赖**：父层不读取 @State 时，
 *   子 builder 拿到的永远是首帧的值。所以凡是「跟着 @State 变」的卡片，
 *   外层必须是**无参** @Builder（内部直接读 this.distState 等），
 *   再把值传给内层的纯展示 builder（barCardBody / debrisItem 等）。
 *
 * ── 为什么分片收口用 nextIndex >= chunks ──
 *   Repository.toChunk() 在 index > 0 时上层传的是 undefined（Repository.ets:610-624），
 *   于是 `chunks` 恒为 1、`end` 恒为 true。若用 res.end 判断「还有没有下一片」，
 *   第一次触底就会认为加载完了，目录永远停在 800 条。
 *   唯一可靠的收口是：**chunk 0 拿到的 chunks 总数** + 自己维护的 nextIndex。
 *
 * ── 为什么 catch 里绝不置 loaded = true ──
 *   弱网无缓存时 repo.load 是 reject 而不是返回空。曾把 loaded 一起置 true，
 *   结果首屏变成永久空 tab，用户不重进页面就再也看不到数据。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions, ChunkResult } from '../data/Repository';
import {
  SaItem,
  SaKv,
  SaKvNum,
  SaDebrisItem,
  SaOrbitStatsPayload,
  SaDebrisPayload,
  saDecadeLabel,
  saKvOf,
  saTake,
  saJoin
} from '../model/Satellite';

const DOMAIN: number = 0x0000;
const TAG: string = 'SpaceAssetsView';

// ============ 设计变量（数值 = 小程序 rpx ÷ 2） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TXT_DIM: string = '#55617A';
const TXT_HINT: string = '#6B7891';
/** 卡片正文（bar-name / d-v）：小程序 #cbd5e0 / #cbd5e1 */
const TXT_BODY: string = '#CBD5E0';
const ACCENT: string = '#38BDF8';

/** 条形图轨道底色 = rgba(255,255,255,0.05)。0.05×255 ≈ 13 = 0x0D */
const BAR_TRACK: string = '#0DFFFFFF';
/** chip / 卡片描边 = rgba(255,255,255,0.05) */
const HAIRLINE: string = '#0DFFFFFF';
/** 时间线竖线 = rgba(255,255,255,0.08)，0.08×255 ≈ 20 = 0x14 */
const RAIL_LINE: string = '#14FFFFFF';

/** 分布条三色（小程序 .bar-fill / .fill-gold / .fill-green 的渐变两端） */
const BAR_BLUE_A: string = '#1E5F86';
const BAR_BLUE_B: string = '#38BDF8';
const BAR_GOLD_A: string = '#7A5A20';
const BAR_GOLD_B: string = '#E0B64A';
const BAR_GREEN_A: string = '#2F6F4F';
const BAR_GREEN_B: string = '#34C759';

/** 时间线圆点三色（.dot.boom / .fall / .land） */
const DOT_BOOM: string = '#FF6B6B';
const DOT_FALL: string = '#38BDF8';
const DOT_LAND: string = '#34C759';

/** 底部留白：本页是 NavDestination 二级页，胶囊已摘掉，32 只够最后一行不贴边 */
const BOTTOM_PAD: number = 32;

// ============ 三个 tab 的下标 ============

const TAB_STATS: number = 0;
const TAB_CATALOG: number = 1;
const TAB_DEBRIS: number = 2;

/**
 * 每张分布卡最多画 12 项（小程序 MAX_BARS = 12）。
 * 第 13 名往后占比都不到 1%，条形图已经看不出差别。
 */
const DIST_ROWS: number = 12;
/** 卫星目录每次多画 60 条（小程序 renderCap 步进 60） */
const CATALOG_STEP: number = 60;
/** 搜索命中上限：再多也不是「找一颗卫星」，而是把 @State 撑爆 */
const SEARCH_LIMIT: number = 200;
/** 筛选后无命中时自动续拉的片数上限（小程序 autoExpand 的 guard < 8） */
const AUTO_PULL_MAX: number = 8;
/** 解体再入每次展示 80 条（小程序 renderCount 初始 80，步进 60） */
const DEBRIS_STEP: number = 80;
const DEBRIS_GROW: number = 60;

// ============ 筛选值 ============

const KIND_ALL: string = '';
const KIND_BREAKUP: string = 'breakup';
const KIND_REENTRY: string = 'reentry';
const KIND_DEORBIT: string = 'deorbit';
const KIND_LANDING: string = 'landing';

const ORBIT_ALL: string = '';

/**
 * 三段切换的配置。
 *
 * 用 class 而不是对象字面量：ArkTS 禁止无类型对象字面量直接作为值赋给数组
 * （"Object literal must correspond to some explicitly declared class or interface"）。
 */
class SxTabOption {
  key: number = 0;
  label: string = '';

  constructor(key: number, label: string) {
    this.key = key;
    this.label = label;
  }
}

/** 三段文案照抄小程序 space-assets.vue:tabs（不是工程里原来的「在轨统计 / 卫星目录」） */
const TABS: SxTabOption[] = [
  new SxTabOption(TAB_STATS, '全球在轨'),
  new SxTabOption(TAB_CATALOG, '卫星百科'),
  new SxTabOption(TAB_DEBRIS, '解体 / 再入')
];

/** 筛选 chip 的配置（新增类型统一用 Sx 前缀，避开 model 里已有的 Sa 族） */
class SxChipOption {
  value: string = '';
  label: string = '';

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

/** 卫星百科·轨道大类（小程序 ORBIT_CATS：用 orbitZh 的中文关键字归类） */
const ORBIT_CATS: SxChipOption[] = [
  new SxChipOption(ORBIT_ALL, '全部轨道'),
  new SxChipOption('near', '近地'),
  new SxChipOption('geo', '同步轨道'),
  new SxChipOption('meo', '中地球'),
  new SxChipOption('heo', '大椭圆'),
  new SxChipOption('deep', '深空 / 月球')
];

/** 卫星百科·国家（小程序 STATE_CATS：stateZh 精确匹配） */
const STATE_CATS: SxChipOption[] = [
  new SxChipOption('', '全部国家'),
  new SxChipOption('美国', '美国'),
  new SxChipOption('中国', '中国'),
  new SxChipOption('俄罗斯', '俄罗斯'),
  new SxChipOption('欧空局', '欧空局'),
  new SxChipOption('日本', '日本'),
  new SxChipOption('印度', '印度')
];

/** 解体再入·事件分型（小程序 KIND_CATS 五项，value '' = 全部） */
const KIND_CATS: SxChipOption[] = [
  new SxChipOption(KIND_ALL, '全部'),
  new SxChipOption(KIND_BREAKUP, '解体'),
  new SxChipOption(KIND_REENTRY, '再入'),
  new SxChipOption(KIND_DEORBIT, '离轨'),
  new SxChipOption(KIND_LANDING, '落地')
];

/** 解体再入·国家（与卫星百科同一份 STATE_CATS，单独引用方便阅读） */
const DEBRIS_STATE_CATS: SxChipOption[] = STATE_CATS;

/**
 * satellites 索引里除 list 之外的元信息。
 *
 * 为什么要单独 peek 一次：Repository 的 ChunkResult 不含 total / generatedAt，
 * 而标题区要显示「共 N 颗」、注脚要显示新鲜度。peek 是同步读缓存，
 * chunk 成功后必然命中，不会多一次网络请求。
 */
interface SxSatellitesIndex {
  v?: number;
  generatedAt?: string;
  total?: number;
  chunks?: number;
  chunkSize?: number;
}

/**
 * 详情抽屉的展开数据。
 *
 * 为什么把 SaItem 拍平成这个 class：@Builder 里对 `SaItem | null` 做判空后
 * ArkTS 不保证收窄，每个字段都要 `!` 或 as，既啰嗦又容易在空值上崩。
 * 这里在点击时一次性取值、缺字段落空串，抽屉里只做 `length > 0` 判断。
 */
class SxDetail {
  name: string = '';
  alt: string = '';
  status: string = '';
  statusZh: string = '';
  orbitZh: string = '';
  intl: string = '';
  owner: string = '';
  state: string = '';
  launch: string = '';
  reentry: string = '';
  perigee: string = '';
  apogee: string = '';
  inc: string = '';
  mass: string = '';
}

/**
 * 新鲜度文案（对位 utils/data.js:freshnessText）。
 *
 * 鸿蒙侧没有这个函数，而三个面板的注脚都要它。
 * 解析失败返回空串 —— 注脚宁可不显示，也不能出现 "NaN 天前更新"。
 */
function saFresh(iso: string): string {
  if (iso.length === 0) {
    return '';
  }
  const t: number = Date.parse(iso);
  if (Number.isNaN(t)) {
    return '';
  }
  const mins: number = Math.floor((Date.now() - t) / 60000);
  if (mins < 1) {
    return '刚刚更新';
  }
  if (mins < 60) {
    return mins.toString() + ' 分钟前更新';
  }
  const hours: number = Math.floor(mins / 60);
  if (hours < 24) {
    return hours.toString() + ' 小时前更新';
  }
  return Math.floor(hours / 24).toString() + ' 天前更新';
}

@Component
export struct SpaceAssetsView {
  // ============ 公共状态 ============

  @State activeTab: number = TAB_STATS;

  // ============ Tab A：全球在轨 ============

  @State statsLoaded: boolean = false;
  @State statsLoading: boolean = false;
  @State statsFailed: boolean = false;
  @State statsTotal: number = 0;
  /** 下拉刷新中（Refresh 的 $$ 双向绑定） */
  @State statsRefreshing: boolean = false;
  @State statsFresh: string = '';
  /**
   * 四组分布。byDecade 在 applyStats() 里就转成 SaKv（k 带 s），
   * 这样四张卡只有一种入参类型，少一层类型分叉。
   */
  @State distState: SaKv[] = [];
  @State distClass: SaKv[] = [];
  @State distOrbit: SaKv[] = [];
  @State distDecade: SaKv[] = [];

  // ============ Tab B：卫星百科 ============

  @State catalogLoaded: boolean = false;
  @State catalogLoading: boolean = false;
  @State catalogFailed: boolean = false;
  @State keyword: string = '';
  /** 轨道大类：'' = 全部 */
  @State orbitCat: string = ORBIT_ALL;
  /** 国家 / 地区：'' = 全部 */
  @State stateCat: string = '';
  /** 当前要画的这一页（60 / 120 / …，或搜索命中的前 200） */
  @State catalogShown: SaItem[] = [];
  /** 已经展开到多少条 */
  @State catalogNum: number = CATALOG_STEP;
  /** 下一片的下标，从 1 开始 */
  @State nextIndex: number = 1;
  /** 分片总数，**只在 chunk 0 时写入**（见文件头说明） */
  @State chunksTotal: number = 1;
  /** 每片条数（chunk 0 返回的 chunkSize，实测 800）。用它算总量，别写死 */
  @State chunkSize: number = 0;
  /** 索引里的权威总数（实测 20109）。拿不到时退回 chunks × chunkSize */
  @State catalogSum: number = 0;
  @State catalogFresh: string = '';

  /** 卫星全量（普通成员，改了不重绘） */
  private all: SaItem[] = [];
  /** 当前筛选结果（普通成员） */
  private pool: SaItem[] = [];
  /** 追加锁：防 onReachEnd 连发导致同一片拉两次 */
  private moreLock: boolean = false;

  // ============ Tab C：解体 · 再入 ============

  @State debrisLoaded: boolean = false;
  @State debrisLoading: boolean = false;
  @State debrisFailed: boolean = false;
  @State debrisKind: string = KIND_ALL;
  @State debrisState: string = '';
  @State debrisKw: string = '';
  @State debrisShown: SaDebrisItem[] = [];
  @State debrisTotal: number = 0;
  @State debrisBreakup: number = 0;
  @State debrisFresh: string = '';
  /** 已展示条数（每次 +80，之后 +60） */
  @State debrisNum: number = DEBRIS_STEP;

  /** 事件全量（普通成员） */
  private allDebris: SaDebrisItem[] = [];
  /** 当前筛选结果（普通成员） */
  private debrisPool: SaDebrisItem[] = [];

  // ============ 详情抽屉 ============

  @State sheetOpen: boolean = false;
  @State detail: SxDetail = new SxDetail();

  // ============ 生命周期 ============

  aboutToAppear(): void {
    // 只预载第一个 tab；另外两个等切过去再说（见文件头「懒加载」）
    this.ensureStats(false);
  }

  // ============ 数据：Tab A 全球在轨 ============

  /**
   * 在轨统计加载。
   *
   * peek 先上屏的理由：这是「聚合数字」而不是逐条列表，缓存里的 20/10/4/8 项
   * 分布与线上的差异要以天为单位，几乎不会过期到影响观感。先画再刷，
   * 切 tab 回来是零等待。
   */
  private ensureStats(force: boolean): void {
    if (this.statsLoading) {
      // 已有请求在飞：把下拉动画收掉，否则用户会一直看到转圈
      this.statsRefreshing = false;
      return;
    }
    if (this.statsLoaded && !force) {
      return;
    }

    const cached: SaOrbitStatsPayload | null = repo.peek<SaOrbitStatsPayload>('orbitStats');
    if (cached !== null) {
      this.applyStats(cached);
    }

    this.statsLoading = true;
    this.statsFailed = false;

    const opts: LoadOptions<SaOrbitStatsPayload> = {
      force: force,
      onCache: (data: SaOrbitStatsPayload) => {
        this.applyStats(data);
      },
      onUpdate: (data: SaOrbitStatsPayload) => {
        this.applyStats(data);
      }
    };

    repo.load<SaOrbitStatsPayload>('orbitStats', opts)
      .then((data: SaOrbitStatsPayload) => {
        this.applyStats(data);
        this.statsLoaded = true;
      })
      .catch((e: BusinessError) => {
        // 有缓存时 repo 不会 reject；走到这里说明冷启动且断网。
        // 不置 loaded —— 否则切走再切回也不会重试，页面永远停在失败态
        this.statsFailed = true;
        hilog.warn(DOMAIN, TAG, 'orbitStats 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.statsLoading = false;
        this.statsRefreshing = false;
      });
  }

  /**
   * 落地：四组分布各自取前 12 项。
   *
   * byDecade 的 k 是 number，不能直接塞进 SaKv（k: string），必须重建。
   * 顺序按小程序 orbit-section.vue 的模板：国家 → 对象类型 → 轨道类型 → 年代。
   */
  private applyStats(data: SaOrbitStatsPayload): void {
    const total: number = data.total !== undefined ? data.total : 0;
    if (total > 0) {
      this.statsTotal = total;
    }
    const at: string = data.generatedAt !== undefined ? data.generatedAt : '';
    const fresh: string = saFresh(at);
    if (fresh.length > 0) {
      this.statsFresh = fresh;
    }

    const byState: SaKv[] = data.byState !== undefined ? data.byState : [];
    const byOrbit: SaKv[] = data.byOrbit !== undefined ? data.byOrbit : [];
    const byClass: SaKv[] = data.byClass !== undefined ? data.byClass : [];
    const byDecade: SaKvNum[] = data.byDecade !== undefined ? data.byDecade : [];

    this.distState = saTake(byState, DIST_ROWS);
    this.distClass = saTake(byClass, DIST_ROWS);
    this.distOrbit = saTake(byOrbit, DIST_ROWS);

    // byDecade 只有 8 项（1950~2020），不裁剪；但仍走同一份 DIST_ROWS 上限保护
    const decades: SaKv[] = [];
    const limit: number = byDecade.length < DIST_ROWS ? byDecade.length : DIST_ROWS;
    for (let i = 0; i < limit; i++) {
      const row: SaKvNum = byDecade[i];
      decades.push(saKvOf(saDecadeLabel(row.k), row.v));
    }
    this.distDecade = decades;
  }

  // ============ 数据：Tab B 卫星百科 ============

  /**
   * 首屏：只拉第 0 片（索引文件自带 800 条），只画前 60 条。
   *
   * 为什么不一次把 26 片全拉完：26 × 800 ≈ 2 万条、约 5MB，
   * 用户可能只想搜一颗卫星，没必要为一次浏览付出全量流量。
   */
  private ensureCatalog(): void {
    if (this.catalogLoading) {
      return;
    }
    if (this.catalogLoaded) {
      return;
    }

    this.catalogLoading = true;
    this.catalogFailed = false;

    repo.chunk<SaItem>('satellites', 0)
      .then((res: ChunkResult<SaItem>) => {
        this.all = res.list;
        // chunks 与 chunkSize 只有这一片是可信的（Repository.toChunk 的已知缺陷）
        this.chunksTotal = res.chunks > 0 ? res.chunks : 1;
        this.chunkSize = res.chunkSize > 0 ? res.chunkSize : res.list.length;
        this.nextIndex = 1;
        this.catalogNum = CATALOG_STEP;
        this.readCatalogIndex();
        this.rebuildCatalog();
        this.catalogLoaded = true;
      })
      .catch((e: BusinessError) => {
        this.catalogFailed = true;
        hilog.warn(DOMAIN, TAG, 'satellites 第 0 片加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.catalogLoading = false;
      });
  }

  /** 从缓存索引里补 total / generatedAt（ChunkResult 没有这两个字段） */
  private readCatalogIndex(): void {
    const idx: SxSatellitesIndex | null = repo.peek<SxSatellitesIndex>('satellites');
    if (idx === null) {
      return;
    }
    if (idx.total !== undefined && idx.total > 0) {
      this.catalogSum = idx.total;
    }
    const at: string = idx.generatedAt !== undefined ? idx.generatedAt : '';
    const fresh: string = saFresh(at);
    if (fresh.length > 0) {
      this.catalogFresh = fresh;
    }
  }

  /**
   * 触底 / 点「加载更多」。三道闸，顺序不能换：
   *   ① 本地还有没展示的（60 → 120 …）先本地放，放完才值得发请求
   *   ② 已在拉片 —— boolean 锁，onReachEnd 会连发好几次
   *   ③ 片已经拉完 —— 用 nextIndex 与 chunksTotal 比，绝不用 res.end
   */
  private loadMoreCatalog(): void {
    if (this.catalogNum < this.pool.length) {
      this.catalogNum = this.catalogNum + CATALOG_STEP;
      this.rebuildCatalog();
      return;
    }
    this.pullNextChunk();
  }

  /** 真正拉下一片；返回是否发起了请求 */
  private pullNextChunk(): boolean {
    if (this.moreLock) {
      return false;
    }
    if (this.nextIndex >= this.chunksTotal) {
      return false;
    }

    this.moreLock = true;
    const idx: number = this.nextIndex;

    repo.chunk<SaItem>('satellites', idx)
      .then((res: ChunkResult<SaItem>) => {
        const add: SaItem[] = res.list;
        if (add.length > 0) {
          // 整体替换才能触发后续 @State 的 diff（all 本身不参与渲染）
          this.all = this.all.concat(add);
        }
        // 失败时不动 nextIndex，下次触底还能重拉这一片
        this.nextIndex = idx + 1;
        this.catalogNum = this.catalogNum + CATALOG_STEP;
        this.rebuildCatalog();
      })
      .catch((e: BusinessError) => {
        // 只 warn，绝不清空已展示的列表（弱网下清空是最糟的体验）
        hilog.warn(DOMAIN, TAG, 'satellites 第 %{public}d 片加载失败: %{public}s', idx, e.message);
      })
      .then(() => {
        this.moreLock = false;
      });
    return true;
  }

  /**
   * 重算当前要画的切片。
   *
   * 筛选口径完全照抄小程序 catalog-section.vue 的 displayList：
   *   hay = name + alt + intl + owner + ownerZh + stateZh（全小写）
   *   + 轨道大类（orbitZh 关键字）
   *   + 国家（stateZh 精确等于）
   */
  private rebuildCatalog(): void {
    const kw: string = this.keyword.trim().toLowerCase();
    const orbit: string = this.orbitCat;
    const state: string = this.stateCat;
    const noFilter: boolean = kw.length === 0 && orbit.length === 0 && state.length === 0;

    if (noFilter) {
      this.pool = this.all;
      this.catalogShown = saTake(this.all, this.catalogNum);
      return;
    }

    const hits: SaItem[] = [];
    for (let i = 0; i < this.all.length; i++) {
      if (hits.length >= SEARCH_LIMIT) {
        break;
      }
      const item: SaItem = this.all[i];
      if (kw.length > 0) {
        const hay: string = (item.name + ' ' + item.alt + ' ' + item.intl + ' ' +
          item.owner + ' ' + item.ownerZh + ' ' + item.stateZh).toLowerCase();
        if (hay.indexOf(kw) < 0) {
          continue;
        }
      }
      if (!this.orbitMatch(item.orbitZh, orbit)) {
        continue;
      }
      if (state.length > 0 && item.stateZh !== state) {
        continue;
      }
      hits.push(item);
    }
    this.pool = hits;
    this.catalogShown = saTake(hits, this.catalogNum);
  }

  /** 轨道大类判定：与小程序 ORBIT_CATS 的 test() 逐字一致 */
  private orbitMatch(orbitZh: string, cat: string): boolean {
    if (cat.length === 0) {
      return true;
    }
    if (cat === 'near') {
      return orbitZh.indexOf('近地') >= 0;
    }
    if (cat === 'geo') {
      return orbitZh.indexOf('同步') >= 0;
    }
    if (cat === 'meo') {
      return orbitZh.indexOf('中地球') >= 0;
    }
    if (cat === 'heo') {
      return orbitZh.indexOf('大椭圆') >= 0;
    }
    // deep：深空 / 太阳 / 月球
    return orbitZh.indexOf('深空') >= 0 || orbitZh.indexOf('太阳') >= 0 ||
      orbitZh.indexOf('月') >= 0;
  }

  /**
   * 筛选条件变化：窗口回到顶部，并在**没有任何命中**时自动续拉下一片。
   *
   * 为什么必须自动续拉：首屏只有 800 条（占全量 4%），用户点「欧空局」很可能
   * 一片都命中不了，直接显示「没有匹配」会让人以为数据缺失。
   * 上限 8 片 —— 再多就是用户在乱点，白白吃掉 4MB 流量。
   */
  private onCatalogFilter(): void {
    this.catalogNum = CATALOG_STEP;
    this.rebuildCatalog();
    this.pullChunkThenExpand(0);
  }

  /** 筛选态专用：拉一片，落地后若无命中继续拉（递归深度受 AUTO_PULL_MAX 限制） */
  private pullChunkThenExpand(guard: number): void {
    if (guard >= AUTO_PULL_MAX || this.pool.length > 0) {
      return;
    }
    if (this.moreLock || this.nextIndex >= this.chunksTotal) {
      return;
    }
    this.moreLock = true;
    const idx: number = this.nextIndex;
    repo.chunk<SaItem>('satellites', idx)
      .then((res: ChunkResult<SaItem>) => {
        const add: SaItem[] = res.list;
        if (add.length > 0) {
          this.all = this.all.concat(add);
        }
        this.nextIndex = idx + 1;
        this.rebuildCatalog();
        this.moreLock = false;
        this.pullChunkThenExpand(guard + 1);
      })
      .catch((e: BusinessError) => {
        this.moreLock = false;
        hilog.warn(DOMAIN, TAG, '筛选续拉第 %{public}d 片失败: %{public}s', idx, e.message);
      });
  }

  private onKeyword(value: string): void {
    if (value === this.keyword) {
      return;
    }
    this.keyword = value;
    this.onCatalogFilter();
  }

  private setOrbit(cat: string): void {
    if (this.orbitCat === cat) {
      return;
    }
    this.orbitCat = cat;
    this.onCatalogFilter();
  }

  private setState(cat: string): void {
    if (this.stateCat === cat) {
      return;
    }
    this.stateCat = cat;
    this.onCatalogFilter();
  }

  // ============ 数据：Tab C 解体 · 再入 ============

  /**
   * 事件流加载：一次 1600 条全进内存（约 260KB），没有分片。
   *
   * 为什么不切片：这份数据的价值在「筛」而不在「翻」——
   * 用户要看的是「今年的解体事件」，本地全量筛选才有意义。
   */
  private ensureDebris(force: boolean): void {
    if (this.debrisLoading) {
      return;
    }
    if (this.debrisLoaded && !force) {
      return;
    }

    const cached: SaDebrisPayload | null = repo.peek<SaDebrisPayload>('debrisEvents');
    if (cached !== null) {
      this.applyDebris(cached);
    }

    this.debrisLoading = true;
    this.debrisFailed = false;

    const opts: LoadOptions<SaDebrisPayload> = {
      force: force,
      onCache: (data: SaDebrisPayload) => {
        this.applyDebris(data);
      },
      onUpdate: (data: SaDebrisPayload) => {
        this.applyDebris(data);
      }
    };

    repo.load<SaDebrisPayload>('debrisEvents', opts)
      .then((data: SaDebrisPayload) => {
        this.applyDebris(data);
        this.debrisLoaded = true;
      })
      .catch((e: BusinessError) => {
        this.debrisFailed = true;
        hilog.warn(DOMAIN, TAG, 'debrisEvents 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.debrisLoading = false;
      });
  }

  private applyDebris(data: SaDebrisPayload): void {
    const list: SaDebrisItem[] = data.list !== undefined ? data.list : [];
    if (list.length > 0) {
      this.allDebris = list;
    }
    // count 是权威总数（1600），list.length 只是「这次下发了几条」，两者可能不等
    const total: number = data.count !== undefined ? data.count : list.length;
    if (total > 0) {
      this.debrisTotal = total;
    }
    if (data.breakupCount !== undefined) {
      this.debrisBreakup = data.breakupCount;
    }
    const at: string = data.generatedAt !== undefined ? data.generatedAt : '';
    const fresh: string = saFresh(at);
    if (fresh.length > 0) {
      this.debrisFresh = fresh;
    }
    this.rebuildDebris();
  }

  /**
   * 三段筛选：kind（精确）→ stateZh（精确）→ 关键词（name + intl + stateZh）。
   * 只做一次遍历，结果进普通成员；@State 只留切片。
   */
  private rebuildDebris(): void {
    const kw: string = this.debrisKw.trim().toLowerCase();
    const kind: string = this.debrisKind;
    const state: string = this.debrisState;
    const out: SaDebrisItem[] = [];
    for (let i = 0; i < this.allDebris.length; i++) {
      const item: SaDebrisItem = this.allDebris[i];
      if (kind.length > 0 && item.kind !== kind) {
        continue;
      }
      if (state.length > 0 && item.stateZh !== state) {
        continue;
      }
      if (kw.length > 0) {
        const hay: string = (item.name + ' ' + item.intl + ' ' + item.stateZh).toLowerCase();
        if (hay.indexOf(kw) < 0) {
          continue;
        }
      }
      out.push(item);
    }
    this.debrisPool = out;
    this.debrisShown = saTake(out, this.debrisNum);
  }

  private switchKind(value: string): void {
    if (this.debrisKind === value) {
      return;
    }
    this.debrisKind = value;
    this.debrisNum = DEBRIS_STEP;
    this.rebuildDebris();
  }

  private switchDebrisState(value: string): void {
    if (this.debrisState === value) {
      return;
    }
    this.debrisState = value;
    this.debrisNum = DEBRIS_STEP;
    this.rebuildDebris();
  }

  private onDebrisKeyword(value: string): void {
    if (value === this.debrisKw) {
      return;
    }
    this.debrisKw = value;
    this.debrisNum = DEBRIS_STEP;
    this.rebuildDebris();
  }

  /** 触底再放 60 条；已放完就不动 */
  private loadMoreDebris(): void {
    if (this.debrisShown.length >= this.debrisPool.length) {
      return;
    }
    this.debrisNum = this.debrisNum + DEBRIS_GROW;
    this.debrisShown = saTake(this.debrisPool, this.debrisNum);
  }

  // ============ 交互 ============

  private switchTab(tab: number): void {
    if (this.activeTab === tab) {
      return;
    }
    this.activeTab = tab;
    this.statsRefreshing = false;
    // 切到哪个才拉哪个（懒加载的唯一入口）
    if (tab === TAB_STATS) {
      this.ensureStats(false);
    } else if (tab === TAB_CATALOG) {
      this.ensureCatalog();
    } else {
      this.ensureDebris(false);
    }
  }

  /** 点卡片：一次性把 SaItem 拍平进 SxDetail（避免 @Builder 里对可空对象做收窄） */
  private openDetail(item: SaItem): void {
    const d: SxDetail = new SxDetail();
    d.name = item.name;
    d.alt = item.alt;
    d.status = item.status;
    d.statusZh = item.statusZh;
    d.orbitZh = item.orbitZh;
    d.intl = item.intl;
    d.owner = item.ownerZh.length > 0 ? item.ownerZh : item.owner;
    d.state = item.stateZh.length > 0 ? item.stateZh : item.state;
    d.launch = item.launch;
    d.reentry = item.reentry;
    d.perigee = item.perigee;
    d.apogee = item.apogee;
    d.inc = item.inc;
    d.mass = item.mass;
    this.detail = d;
    this.sheetOpen = true;
  }

  // ============ 小工具 ============

  /** 一组分布项里的最大值（用于条形归一化） */
  private maxOf(list: SaKv[]): number {
    let max: number = 0;
    for (let i = 0; i < list.length; i++) {
      const v: number = list[i].v;
      if (v > max) {
        max = v;
      }
    }
    return max;
  }

  /**
   * 条形宽度（百分比字符串）。
   *
   * 口径照抄小程序 withPct：pct = max(5, round(v / max * 100))，max 取首项
   * ——数据已按 v 降序，首项就是最大值，不必再遍历一遍。
   * 最小值锁 5%：占比 0.1% 的条目算出来是 0%，条会彻底消失，
   * 看起来像「这一行坏了」，而不是「这一项很少」。
   */
  private barPct(v: number, maxV: number): string {
    if (maxV <= 0) {
      return '5%';
    }
    const raw: number = Math.round((v / maxV) * 100);
    const pct: number = raw < 5 ? 5 : (raw > 100 ? 100 : raw);
    return pct.toString() + '%';
  }

  /**
   * 年代柱高（vp）。
   *
   * 小程序 .col-bar 是 `height: pct%` + `min-height: 4rpx`，
   * 鸿蒙侧父容器 .col-slot 高度固定 110vp，所以直接用「百分比 × 110」算数值，
   * 比给子组件写百分比高度稳（百分比高度在 Column 里会回溯父高）。
   */
  private colH(v: number, maxV: number): number {
    if (maxV <= 0) {
      return 2;
    }
    // 小程序 withDecadePct：pct = max(4, round(v / max * 100))，柱高 = pct% × 110vp
    const pct: number = Math.max(4, Math.round((v / maxV) * 100));
    const h: number = pct * 1.1;
    // 兜住 .col-bar 的 min-height: 4rpx = 2vp
    return h < 2 ? 2 : h;
  }

  /** 卫星总量：优先索引里的 total，拿不到才用 片数 × 每片条数 */
  private catalogTotal(): number {
    if (this.catalogSum > 0) {
      return this.catalogSum;
    }
    const size: number = this.chunkSize > 0 ? this.chunkSize : 1;
    return this.chunksTotal * size;
  }

  /** 卫星卡第二行：ownerZh · intl（对位小程序 `s.ownerZh || s.owner` + ` · {{ intl }}`） */
  private ownerLine(item: SaItem): string {
    const owner: string = item.ownerZh.length > 0 ? item.ownerZh : item.owner;
    return item.intl.length > 0 ? owner + ' · ' + item.intl : owner;
  }

  /** 卫星卡第三行：orbitZh · launch 入轨 */
  private orbitLine(item: SaItem): string {
    const orbit: string = item.orbitZh.length > 0 ? item.orbitZh : '未知轨道';
    return item.launch.length > 0 ? orbit + ' · ' + item.launch + ' 入轨' : orbit;
  }

  /** 解体卡 meta：[clsZh, intl, stateZh, orbitZh] 用 · 连接（对位 debris-section.vue:43） */
  private debrisMeta(item: SaDebrisItem): string {
    return saJoin([item.clsZh, item.intl, item.stateZh, item.orbitZh]);
  }

  /** 圆点颜色：解体红 / 离轨·落地绿 / 普通再入蓝 */
  private dotColor(kind: string): string {
    if (kind === KIND_BREAKUP) {
      return DOT_BOOM;
    }
    if (kind === KIND_LANDING || kind === KIND_DEORBIT) {
      return DOT_LAND;
    }
    return DOT_FALL;
  }

  /** badge 底色：对应 wxss 的 rgba(…, 0.14)，0.14 × 255 ≈ 0x24 */
  private badgeBg(kind: string): string {
    if (kind === KIND_BREAKUP) {
      return '#24FF6B6B';
    }
    if (kind === KIND_LANDING || kind === KIND_DEORBIT) {
      return '#2434C759';
    }
    return '#2438BDF8';
  }

  private badgeColor(kind: string): string {
    if (kind === KIND_BREAKUP) {
      return '#FF8A8A';
    }
    if (kind === KIND_LANDING || kind === KIND_DEORBIT) {
      return DOT_LAND;
    }
    return DOT_FALL;
  }

  /** 卫星状态 badge 底色：只有失联 / 已对接 / 深空等例外才显示 */
  private statBadgeBg(status: string): string {
    if (status === 'OX') {
      return '#2434D399';
    }
    if (status === 'DK' || status === 'DSO' || status === 'DSA') {
      return '#2938BDF8';
    }
    return '#0DFFFFFF';
  }

  private statBadgeColor(status: string): string {
    if (status === 'OX') {
      return '#34D399';
    }
    if (status === 'DK' || status === 'DSO' || status === 'DSA') {
      return ACCENT;
    }
    return TXT_DIM;
  }

  /** 卫星列表底部提示（对位 catalog-section.vue:45-48 的四种文案） */
  private catalogFootText(): string {
    if (this.catalogShown.length < this.pool.length) {
      return '加载更多 · 已显示 ' + this.catalogShown.length.toString() + ' / ' +
        this.pool.length.toString() + ' 颗';
    }
    if (this.nextIndex >= this.chunksTotal) {
      return '已加载全部 ' + this.catalogTotal().toString() + ' 颗';
    }
    return '下滑加载更多…';
  }

  /** 解体列表底部提示 */
  private debrisFootText(): string {
    if (this.debrisShown.length < this.debrisPool.length) {
      return '加载更多 · 已显示 ' + this.debrisShown.length.toString() + ' / ' +
        this.debrisPool.length.toString() + ' 起';
    }
    return '已显示全部 ' + this.debrisPool.length.toString() + ' 起';
  }

  // ============ UI：页头与切换 ============

  /** 页头：22vp w700 #e2e8f0 + 11.5vp #6b7891（hero padding 28/32/18rpx → 14/16/9） */
  @Builder
  pageHead() {
    Column() {
      Text('太空资产')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#E2E8F0')
        .maxLines(1)
        .width('100%')

      Text('天上有什么、后来怎么样 · GCAT 在轨编目')
        .fontSize(11.5)
        .fontColor(TXT_HINT)
        .maxLines(1)
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 14, left: 16, right: 16, bottom: 9 })
  }

  /**
   * 三段切换：容器 padding 2vp / radius 9vp；tab 高 32vp / radius 7vp。
   * 选中态是**实底 #38bdf8 + 深色字 #06121f**（不是半透明底 + 青色字）。
   */
  @Builder
  segmented() {
    Row() {
      ForEach(TABS, (opt: SxTabOption) => {
        Text(opt.label)
          .fontSize(12.5)
          .fontWeight(this.activeTab === opt.key ? 600 : 400)
          .fontColor(this.activeTab === opt.key ? '#06121F' : '#8A97AD')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(32)
          .borderRadius(7)
          .backgroundColor(this.activeTab === opt.key ? ACCENT : '#00000000')
          .onClick(() => {
            this.switchTab(opt.key);
          })
      }, (opt: SxTabOption) => 'tab' + opt.key.toString())
    }
    .width('100%')
    .padding(2)
    .backgroundColor(CARD_BG)
    .borderRadius(9)
    .border({ width: 1, color: HAIRLINE })
    .margin({ left: 16, right: 16, top: 4 })
  }

  // ============ UI：通用状态 ============

  /** 加载态：转圈 + 一句话（小程序文案「统计中...」/「加载中...」） */
  @Builder
  loadingBlock(text: string) {
    Column() {
      LoadingProgress()
        .width(26)
        .height(26)
        .color(ACCENT)
      Text(text)
        .fontSize(13)
        .fontColor(TXT_HINT)
        .margin({ top: 10 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 卫星 / 事件的空态（无按钮，纯提示）。padding 160rpx 40rpx → 80 / 20 */
  @Builder
  emptyText(main: string, sub: string) {
    Column() {
      Text(main)
        .fontSize(14)
        .fontColor('#8A97AD')
        .maxLines(2)
        .textAlign(TextAlign.Center)
      if (sub.length > 0) {
        Text(sub)
          .fontSize(11)
          .fontColor(TXT_DIM)
          .maxLines(2)
          .textAlign(TextAlign.Center)
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 80, bottom: 80, left: 20, right: 20 })
  }

  /**
   * 在轨统计空态：🛰️ + 说明 + **重新加载按钮**。
   * 小程序空态是带按钮的（.btn），而原鸿蒙版只有一句文案 —— 断网后无路可走。
   */
  @Builder
  statsEmpty() {
    Column() {
      Text('🛰️')
        .fontSize(32)
        .opacity(0.9)
        .margin({ bottom: 8 })
      Text('在轨资产数据还没生成，稍后再来看看')
        .fontSize(13)
        .fontColor(TXT_HINT)
        .maxLines(2)
        .textAlign(TextAlign.Center)
      Text('重新加载')
        .fontSize(12)
        .fontColor(ACCENT)
        .padding({ left: 20, right: 20, top: 7, bottom: 7 })
        .backgroundColor('#2438BDF8')
        .borderRadius(15)
        .margin({ top: 12 })
        .onClick(() => {
          this.ensureStats(true);
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 100, bottom: 100, left: 20, right: 20 })
  }

  // ============ UI：Tab A 全球在轨 ============

  /**
   * 大数字头。
   *
   * 这个数不是从 list 里数出来的（list 恒为空），而是 payload.total ——
   * 也就是 CI 侧 GCAT 全量在轨物体的计数（实测 34925）。
   * 数字**不加千分位**：小程序模板是 `{{ total }}` 直出。
   */
  @Builder
  statsHead() {
    Column() {
      Row() {
        Text(this.statsTotal.toString())
          .fontSize(36)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .height(36)

        Text('个在轨物体')
          .fontSize(13)
          .fontColor(TXT_HINT)
          .maxLines(1)
          .margin({ left: 7, bottom: 3 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Text('数据来自 GCAT 季度编目快照（含火箭体、载荷与残骸）')
        .fontSize(11)
        .fontColor('#4A5568')
        .lineHeight(16.5)
        .maxLines(2)
        .width('100%')
        .margin({ top: 7 })
    }
    .width('100%')
    .padding({ top: 20, left: 12, right: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 一张分布卡的卡壳 + 标题（卡片 padding 30/28rpx → 15/14，radius 20rpx → 10）。
   * 真正的内容由调用方拼进来，避免再套一层 builder 传参。
   */
  @Builder
  barCardBody(title: string, list: SaKv[], colorFrom: string, colorTo: string) {
    Column() {
      Text(title)
        .fontSize(15)
        .fontWeight(600)
        .fontColor(ACCENT)
        .maxLines(1)
        .width('100%')
        .margin({ bottom: 13 })

      if (list.length === 0) {
        Text('暂无数据')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .width('100%')
      } else {
        ForEach(list, (row: SaKv, index: number) => {
          Row() {
            // 名称定宽 75vp（150rpx）：定宽才能让四张卡的条起点对齐，
            // 用 layoutWeight 会因为名字长短不同而条长短不齐
            Text(row.k)
              .fontSize(11.5)
              .fontColor(TXT_BODY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width(75)

            Row() {
              // 条的填充用空 Text 而不是空 Row()：容器组件的子块不能留空，
              // 而 Text 支持百分比宽度 + 背景色，是最稳的「纯色矩形」
              Text('')
                .height(6)
                .borderRadius(3)
                .width(this.barPct(row.v, list[0].v))
                .linearGradient({
                  angle: 90,
                  colors: [[colorFrom, 0.0], [colorTo, 1.0]]
                })
            }
            .layoutWeight(1)
            .height(6)
            .borderRadius(3)
            .backgroundColor(BAR_TRACK)
            .clip(true)
            .margin({ left: 8, right: 8 })

            Text(row.v.toString())
              .fontSize(11.5)
              .fontColor('#8A97A8')
              .maxLines(1)
              .textAlign(TextAlign.End)
              .width(35)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: index === list.length - 1 ? 0 : 10 })
        }, (row: SaKv, index: number) => title + '#' + index.toString() + '#' + row.k)
      }
    }
    .width('100%')
    .padding({ top: 15, left: 14, right: 14, bottom: 15 })
    .backgroundColor(CARD_BG)
    .borderRadius(10)
    .border({ width: 1, color: HAIRLINE })
    .alignItems(HorizontalAlign.Start)
  }

  /** 按国家 / 地区（蓝）。无参 builder 才能吃到 distState 的变化（见文件头） */
  @Builder
  cardState() {
    Column() {
      this.barCardBody('按国家 / 地区', this.distState, BAR_BLUE_A, BAR_BLUE_B)
    }
    .width('100%')
    .margin({ left: 12, right: 12, top: 12 })
  }

  /** 按对象类型（金） */
  @Builder
  cardClass() {
    Column() {
      this.barCardBody('按对象类型', this.distClass, BAR_GOLD_A, BAR_GOLD_B)
    }
    .width('100%')
    .margin({ left: 12, right: 12, top: 12 })
  }

  /** 按轨道类型（绿） */
  @Builder
  cardOrbit() {
    Column() {
      this.barCardBody('按轨道类型', this.distOrbit, BAR_GREEN_A, BAR_GREEN_B)
    }
    .width('100%')
    .margin({ left: 12, right: 12, top: 12 })
  }

  /**
   * 按年代入轨：**竖向柱状图**（小程序 .chart），不是横向条。
   *
   * col-slot 高 220rpx = 110vp，柱宽 56%，顶部数值 17rpx = 8.5vp，
   * 标签 19rpx = 9.5vp。柱色是「从下往上」的渐变，所以 angle: 0。
   */
  @Builder
  cardDecade() {
    Column() {
      Text('按年代入轨')
        .fontSize(15)
        .fontWeight(600)
        .fontColor(ACCENT)
        .maxLines(1)
        .width('100%')
        .margin({ bottom: 13 })

      if (this.distDecade.length === 0) {
        Text('暂无数据')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .width('100%')
      } else {
        Row() {
          ForEach(this.distDecade, (row: SaKv) => {
            Column() {
              // 数值为 0 时不画数字（小程序 v-if="d.v"），但保留占位高度防止柱子高度跳动
              Text(row.v > 0 ? row.v.toString() : '')
                .fontSize(8.5)
                .fontColor('#8A97A8')
                .maxLines(1)
                .height(12)
                .margin({ bottom: 3 })

              Column() {
                Text('')
                  .width('56%')
                  .height(this.colH(row.v, this.maxOf(this.distDecade)))
                  .borderRadius({
                    topLeft: 3,
                    topRight: 3,
                    bottomLeft: 1,
                    bottomRight: 1
                  })
                  .linearGradient({
                    angle: 0,
                    colors: [[BAR_BLUE_A, 0.0], [BAR_BLUE_B, 1.0]]
                  })
              }
              .width('100%')
              .height(110)
              .justifyContent(FlexAlign.End)

              Text(row.k)
                .fontSize(9.5)
                .fontColor('#4A5568')
                .maxLines(1)
                .margin({ top: 5 })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Center)
          }, (row: SaKv) => 'dec#' + row.k)
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }
    }
    .width('100%')
    .padding({ top: 15, left: 14, right: 14, bottom: 15 })
    .backgroundColor(CARD_BG)
    .borderRadius(10)
    .border({ width: 1, color: HAIRLINE })
    .alignItems(HorizontalAlign.Start)
    .margin({ left: 12, right: 12, top: 12 })
  }

  /** 数据源注脚（10vp #3d4a5c，居中，含新鲜度） */
  @Builder
  statsNote() {
    Column() {
      Text('数据源：GCAT (J. McDowell, planet4589.org/space/gcat) · CC-BY')
        .fontSize(10)
        .fontColor('#3D4A5C')
        .textAlign(TextAlign.Center)
        .width('100%')
      if (this.statsFresh.length > 0) {
        Text(this.statsFresh)
          .fontSize(10)
          .fontColor('#3D4A5C')
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: 3 })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 15 })
  }

  @Builder
  statsPanel() {
    Column() {
      if (this.statsTotal === 0 && this.distState.length === 0) {
        if (this.statsLoading) {
          this.loadingBlock('统计中...')
        } else {
          // 失败与「上游还没生成」在用户视角是同一件事：没数据 + 可重试
          this.statsEmpty()
        }
      } else {
        // 下拉刷新只在这个 tab 有（小程序只有 orbit-section 暴露 refresh）
        Refresh({ refreshing: $$this.statsRefreshing }) {
          Scroll() {
            Column() {
              this.statsHead()
              // 小程序四张卡都是 `v-if="xxx.length"`：某组分布为空就整卡不渲染，
              // 而不是渲染一张写着「暂无数据」的空卡。这里沿用同一口径。
              if (this.distState.length > 0) {
                this.cardState()
              }
              if (this.distClass.length > 0) {
                this.cardClass()
              }
              if (this.distOrbit.length > 0) {
                this.cardOrbit()
              }
              if (this.distDecade.length > 0) {
                this.cardDecade()
              }
              this.statsNote()
            }
            .width('100%')
            .padding({ bottom: BOTTOM_PAD })
          }
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.Top)
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => {
          this.statsRefreshing = true;
          this.ensureStats(true);
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ============ UI：搜索框（两个面板各一份，见文件头 @Builder 说明） ============

  /** 卫星搜索框：高 36vp / radius 18vp / bg #141a26（对位 .search 72rpx） */
  @Builder
  catalogSearch() {
    Row() {
      Text('🔍')
        .fontSize(13)
        .opacity(0.6)
        .margin({ right: 6 })

      TextInput({ text: this.keyword, placeholder: '搜名称 / 国际编号 / 运营方 / 国家' })
        .layoutWeight(1)
        .type(InputType.Normal)
        .enterKeyType(EnterKeyType.Search)
        .placeholderColor(TXT_DIM)
        .placeholderFont({ size: 13 })
        .fontSize(13)
        .fontColor('#E2E8F0')
        .caretColor(ACCENT)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .height(36)
        .onChange((value: string) => {
          this.onKeyword(value);
        })

      if (this.keyword.length > 0) {
        Text('✕')
          .fontSize(13)
          .fontColor(TXT_HINT)
          .padding({ left: 4, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.onKeyword('');
          })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 6 })
    .height(36)
    .backgroundColor(CARD_BG)
    .borderRadius(18)
    .border({ width: 1, color: '#0FFFFFFF' })
    .alignItems(VerticalAlign.Center)
    .margin({ top: 9 })
  }

  /** 解体搜索框：文案只到「国家」（对位 debris-section.vue:10） */
  @Builder
  debrisSearch() {
    Row() {
      Text('🔍')
        .fontSize(13)
        .opacity(0.6)
        .margin({ right: 6 })

      TextInput({ text: this.debrisKw, placeholder: '搜名称 / 国际编号 / 国家' })
        .layoutWeight(1)
        .type(InputType.Normal)
        .enterKeyType(EnterKeyType.Search)
        .placeholderColor(TXT_DIM)
        .placeholderFont({ size: 13 })
        .fontSize(13)
        .fontColor('#E2E8F0')
        .caretColor(ACCENT)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .height(36)
        .onChange((value: string) => {
          this.onDebrisKeyword(value);
        })

      if (this.debrisKw.length > 0) {
        Text('✕')
          .fontSize(13)
          .fontColor(TXT_HINT)
          .padding({ left: 4, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.onDebrisKeyword('');
          })
      }
    }
    .width('100%')
    .padding({ left: 10, right: 6 })
    .height(36)
    .backgroundColor(CARD_BG)
    .borderRadius(18)
    .border({ width: 1, color: '#0FFFFFFF' })
    .alignItems(VerticalAlign.Center)
    .margin({ top: 9 })
  }

  // ============ UI：Tab B 卫星百科 ============

  /** 标题区：20vp w700 + 11vp 副标题（原版完全没有，只有一行「已加载 N / M」） */
  @Builder
  catalogHead() {
    Column() {
      Text('航天器 / 卫星百科')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#E2E8F0')
        .maxLines(1)
        .width('100%')

      Text('在轨航天器与载荷编目 · 共 ' + this.catalogTotal().toString() + ' 颗')
        .fontSize(11)
        .fontColor(TXT_HINT)
        .maxLines(1)
        .width('100%')
        .margin({ top: 3 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 12, left: 4, right: 4, bottom: 4 })
  }

  /**
   * 一行 chips：横向滚动（小程序是 scroll-view scroll-x）。
   *
   * 为什么用 Scroll 而不是 Flex 折行：小程序是横向滚动，折行会让两行变成四行，
   * 把列表起点整体推下去。
   */
  @Builder
  orbitChips() {
    Scroll() {
      Row() {
        ForEach(ORBIT_CATS, (c: SxChipOption) => {
          Text(c.label)
            .fontSize(11.5)
            .fontWeight(this.orbitCat === c.value ? 600 : 400)
            .fontColor(this.orbitCat === c.value ? '#06121F' : '#8A97AD')
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .backgroundColor(this.orbitCat === c.value ? ACCENT : CARD_BG)
            .borderRadius(15)
            .border({
              width: 1,
              color: this.orbitCat === c.value ? ACCENT : HAIRLINE
            })
            .margin({ right: 7 })
            .onClick(() => {
              this.setOrbit(c.value);
            })
        }, (c: SxChipOption) => 'orb#' + c.value)
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: 8 })
  }

  /** 国家 chips（卫星百科） */
  @Builder
  stateChips() {
    Scroll() {
      Row() {
        ForEach(STATE_CATS, (c: SxChipOption) => {
          Text(c.label)
            .fontSize(11.5)
            .fontWeight(this.stateCat === c.value ? 600 : 400)
            .fontColor(this.stateCat === c.value ? '#06121F' : '#8A97AD')
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .backgroundColor(this.stateCat === c.value ? ACCENT : CARD_BG)
            .borderRadius(15)
            .border({ width: 1, color: this.stateCat === c.value ? ACCENT : HAIRLINE })
            .margin({ right: 7 })
            .onClick(() => {
              this.setState(c.value);
            })
        }, (c: SxChipOption) => 'st#' + c.value)
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: 8 })
  }

  /**
   * 卫星卡：名称 15vp w600 #e2e8f0；两行 meta 11vp #6b7891（ownerZh · intl /
   * orbitZh · launch 入轨）；状态 badge（仅非 'O' 才显示）；右侧 › 17vp。
   * 整卡可点 → 底部详情抽屉。
   */
  @Builder
  catalogCard(item: SaItem) {
    Row() {
      Column() {
        Row() {
          Text(item.name)
            .fontSize(15)
            .fontWeight(600)
            .fontColor('#E2E8F0')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          // 绝大多数载荷是「在轨(O)」，卡片默认不显示徽标；只有失联/已对接/深空例外才有意义
          if (item.status !== 'O' && item.statusZh.length > 0) {
            Text(item.statusZh)
              .fontSize(9.5)
              .fontColor(this.statBadgeColor(item.status))
              .maxLines(1)
              .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
              .backgroundColor(this.statBadgeBg(item.status))
              .borderRadius(3)
              .margin({ left: 6 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.ownerLine(item))
          .fontSize(11)
          .fontColor(TXT_HINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })

        Text(this.orbitLine(item))
          .fontSize(11)
          .fontColor(TXT_HINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(17)
        .fontColor('#3D4A5C')
        .margin({ left: 7 })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 11, bottom: 11 })
    .backgroundColor(CARD_BG)
    .borderRadius(10)
    .border({ width: 1, color: HAIRLINE })
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 8 })
    .onClick(() => {
      this.openDetail(item);
    })
  }

  /** 列表底部提示（可点：与小程序一样点了就继续展开 / 拉片） */
  @Builder
  catalogFoot() {
    Row() {
      Text(this.catalogFootText())
        .fontSize(11)
        .fontColor(TXT_HINT)
        .maxLines(2)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 4 })
    .onClick(() => {
      this.loadMoreCatalog();
    })
  }

  /** 注脚带新鲜度：小程序 `.gcat-note` 里是 `· {{ freshText() }}` 同行追加 */
  @Builder
  catalogNote() {
    Text('数据来源：GCAT (J. McDowell, planet4589.org/space/gcat) · CC-BY' +
      (this.catalogFresh.length > 0 ? ' · ' + this.catalogFresh : ''))
      .fontSize(10)
      .fontColor('#4A5670')
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ top: 15, bottom: BOTTOM_PAD })
  }

  @Builder
  catalogPanel() {
    if (this.catalogLoading && this.all.length === 0) {
      this.loadingBlock('加载中...')
    } else if (this.all.length === 0) {
      // 失败与「文件未生成」都落这里：给一句可操作的自检提示，不给假数据的空列表
      this.emptyText('没有匹配的航天器', this.catalogFailed ? '网络不佳，切走再切回可重试' : '上游编目文件尚未生成')
    } else {
      List() {
        ListItem() {
          this.catalogHead()
        }
        ListItem() {
          this.catalogSearch()
        }
        ListItem() {
          this.orbitChips()
        }
        ListItem() {
          this.stateChips()
        }

        if (this.catalogShown.length === 0) {
          // 空态放在 ListItem 里时必须自己给高度：ListItem 高度由内容撑，
          // emptyText 的 layoutWeight(1) 在无高度父级里无处可伸，会挤成贴顶一条
          ListItem() {
            Column() {
              this.emptyText('没有匹配的航天器',
                '已加载 ' + this.chunksTotal.toString() + ' 片中的同批数据，下滑可加载更多再筛选')
            }
            .width('100%')
            .height(220)
          }
        } else {
          ForEach(this.catalogShown, (item: SaItem, index: number) => {
            ListItem() {
              this.catalogCard(item)
            }
          }, (item: SaItem, index: number) => 'sat#' + item.id + '@' + index.toString())
        }

        ListItem() {
          this.catalogFoot()
        }
        ListItem() {
          this.catalogNote()
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(8)
      .onReachEnd(() => {
        this.loadMoreCatalog();
      })
    }
  }

  // ============ UI：底部详情抽屉 ============

  /** 一行「标签 + 值」，两列布局（每格 50%） */
  @Builder
  dCell(k: string, v: string) {
    Column() {
      Text(k)
        .fontSize(10)
        .fontColor(TXT_DIM)
        .width('100%')
      Text(v)
        .fontSize(13)
        .fontColor(TXT_BODY)
        .width('100%')
        .margin({ top: 2 })
    }
    .width('50%')
    .padding({ top: 7, bottom: 7, right: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 详情抽屉内容（对位 catalog-section.vue 的 .sheet，78vh）。
   *
   * 高度用 SheetSize.LARGE 而不是精确 78%：bindSheet 的 height 只接受
   * SheetSize | Length，百分比字符串不是合法入参；LARGE 在手机上的落点
   * 与 78vh 视觉接近，且与全工程抽屉口径一致（见 LaunchView.ets:1940）。
   * 顶部的拖拽条由 dragBar: true 提供，不再自绘 .sheet-handle。
   */
  @Builder
  detailSheet() {
    Column() {
      Scroll() {
        Column() {
          Text(this.detail.name)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#E2E8F0')
            .maxLines(2)
            .width('100%')

          if (this.detail.alt.length > 0 && this.detail.alt !== this.detail.name) {
            Text(this.detail.alt)
              .fontSize(11.5)
              .fontColor(TXT_HINT)
              .maxLines(2)
              .width('100%')
              .margin({ top: 3 })
          }

          Row() {
            Text(this.detail.statusZh.length > 0 ? this.detail.statusZh : '未知状态')
              .fontSize(10.5)
              .fontColor(this.statBadgeColor(this.detail.status))
              .maxLines(1)
              .padding({ left: 8, right: 8, top: 2.5, bottom: 2.5 })
              .backgroundColor(this.statBadgeBg(this.detail.status))
              .borderRadius(4)

            Text(this.detail.orbitZh.length > 0 ? this.detail.orbitZh : '未知轨道')
              .fontSize(10.5)
              .fontColor(TXT_HINT)
              .maxLines(1)
              .padding({ left: 8, right: 8, top: 2.5, bottom: 2.5 })
              .backgroundColor('#0DFFFFFF')
              .borderRadius(4)
              .margin({ left: 6 })
          }
          .width('100%')
          .margin({ top: 8 })
          .alignItems(VerticalAlign.Center)

          // 两列字段：Flex 折行 + 每格 50%，与小程序 .d-grid 的 flex-wrap 一致
          Flex({ wrap: FlexWrap.Wrap }) {
            if (this.detail.intl.length > 0) {
              this.dCell('国际编号', this.detail.intl)
            }
            if (this.detail.owner.length > 0) {
              this.dCell('运营方', this.detail.owner)
            }
            if (this.detail.state.length > 0) {
              this.dCell('国家 / 地区', this.detail.state)
            }
            if (this.detail.launch.length > 0) {
              this.dCell('发射时间', this.detail.launch)
            }
            if (this.detail.reentry.length > 0) {
              this.dCell('再入时间', this.detail.reentry)
            }
            if (this.detail.perigee.length > 0) {
              this.dCell('近地点', this.detail.perigee + ' km')
            }
            if (this.detail.apogee.length > 0) {
              this.dCell('远地点', this.detail.apogee + ' km')
            }
            if (this.detail.inc.length > 0) {
              this.dCell('轨道倾角', this.detail.inc + '°')
            }
            if (this.detail.mass.length > 0) {
              this.dCell('质量', this.detail.mass + ' kg')
            }
          }
          .width('100%')
          .margin({ top: 11 })

          Text('数据来源：GCAT (J. McDowell, planet4589.org/space/gcat) · CC-BY')
            .fontSize(9.5)
            .fontColor('#4A5670')
            .width('100%')
            .margin({ top: 12 })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 8, bottom: 30 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#10151F')
  }

  // ============ UI：Tab C 解体 · 再入 ============

  /**
   * 统计行：`共 1600 起（含解体 N）` + 新鲜度。
   *
   * 注意这是**全量**口径（payload.count / breakupCount），不随筛选变化 ——
   * 原版把右侧写成「当前筛选结果的条数」，与小程序语义完全不同。
   */
  @Builder
  debrisStatLine() {
    Row() {
      Text('共 ' + this.debrisTotal.toString() + ' 起（含解体 ' +
        this.debrisBreakup.toString() + '）')
        .fontSize(11)
        .fontColor(TXT_HINT)
        .maxLines(1)

      if (this.debrisFresh.length > 0) {
        Text('· ' + this.debrisFresh)
          .fontSize(11)
          .fontColor(TXT_HINT)
          .maxLines(1)
          .margin({ left: 4 })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 2, left: 4, right: 4 })
  }

  /** 解体分型 chips：五项（全部 / 解体 / 再入 / 离轨 / 落地） */
  @Builder
  kindChips() {
    Scroll() {
      Row() {
        ForEach(KIND_CATS, (c: SxChipOption) => {
          Text(c.label)
            .fontSize(11.5)
            .fontWeight(this.debrisKind === c.value ? 600 : 400)
            .fontColor(this.debrisKind === c.value ? '#06121F' : '#8A97AD')
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .backgroundColor(this.debrisKind === c.value ? ACCENT : CARD_BG)
            .borderRadius(15)
            .border({
              width: 1,
              color: this.debrisKind === c.value ? ACCENT : HAIRLINE
            })
            .margin({ right: 7 })
            .onClick(() => {
              this.switchKind(c.value);
            })
        }, (c: SxChipOption) => 'kind#' + c.value)
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: 8 })
  }

  /** 解体国家 chips（原版完全没有这一行） */
  @Builder
  debrisStateChips() {
    Scroll() {
      Row() {
        ForEach(DEBRIS_STATE_CATS, (c: SxChipOption) => {
          Text(c.label)
            .fontSize(11.5)
            .fontWeight(this.debrisState === c.value ? 600 : 400)
            .fontColor(this.debrisState === c.value ? '#06121F' : '#8A97AD')
            .padding({ left: 11, right: 11, top: 5, bottom: 5 })
            .backgroundColor(this.debrisState === c.value ? ACCENT : CARD_BG)
            .borderRadius(15)
            .border({
              width: 1,
              color: this.debrisState === c.value ? ACCENT : HAIRLINE
            })
            .margin({ right: 7 })
            .onClick(() => {
              this.switchDebrisState(c.value);
            })
        }, (c: SxChipOption) => 'dst#' + c.value)
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: 8 })
  }

  /**
   * 一条时间线事件：左侧 rail（20vp）+ 圆点（9vp）+ 竖线（1vp），右侧卡片。
   *
   * 竖线要跟着卡片高度走，所以外层用 Flex + ItemAlign.Stretch：
   * Row 的 VerticalAlign 没有 Stretch，而 Flex 的交叉轴拉伸能把 rail 撑到
   * 与卡片等高，线段的 layoutWeight(1) 才有「剩余高度」可分。
   * Flex 默认方向就是 Row，不写 direction 少一处枚举依赖。
   */
  @Builder
  debrisItem(item: SaDebrisItem, last: boolean, first: boolean) {
    Flex({ alignItems: ItemAlign.Stretch }) {
      Column() {
        // 圆点：只有解体的红点带 12rpx=6vp 光晕（box-shadow），其余纯色。
        // 分两条分支而不是给 shadow 传 radius: 0 —— 0 半径的光晕在部分机型上
        // 会留下一个极淡的色边，不如干脆不加阴影
        if (item.kind === KIND_BREAKUP) {
          Text('')
            .width(9)
            .height(9)
            .borderRadius(5)
            .backgroundColor(DOT_BOOM)
            .shadow({ radius: 6, color: '#99FF6B6B', offsetX: 0, offsetY: 0 })
            .margin({ top: 15 })
        } else {
          Text('')
            .width(9)
            .height(9)
            .borderRadius(5)
            .backgroundColor(this.dotColor(item.kind))
            .margin({ top: 15 })
        }

        if (!last) {
          Text('')
            .width(1)
            .layoutWeight(1)
            .backgroundColor(RAIL_LINE)
            .margin({ top: 3, bottom: 3 })
        }
      }
      .width(20)
      .alignItems(HorizontalAlign.Center)

      Column() {
        Row() {
          Text(item.reentry.length > 0 ? item.reentry : '日期未知')
            .fontSize(12)
            .fontColor('#8A97AD')
            .maxLines(1)
            .layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(item.statusZh)
            .fontSize(9.5)
            .fontColor(this.badgeColor(item.kind))
            .maxLines(1)
            .padding({ left: 7, right: 7, top: 1.5, bottom: 1.5 })
            .backgroundColor(this.badgeBg(item.kind))
            .borderRadius(3)
            .margin({ left: 6 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(item.name)
          .fontSize(14.5)
          .fontWeight(600)
          .fontColor('#E2E8F0')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 5 })

        Text(this.debrisMeta(item))
          .fontSize(11)
          .fontColor(TXT_HINT)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding(11)
      .backgroundColor(CARD_BG)
      .borderRadius(9)
      .border({ width: 1, color: HAIRLINE })
      .margin({ left: 8, top: 9, bottom: 9 })
    }
    .width('100%')
    // 小程序 .timeline 有 margin-top 12rpx=6，整段时间线整体下移；
    // 这里挂在首项上，效果等同且不用再包一层容器
    .margin({ top: first ? 6 : 0 })
  }

  @Builder
  debrisFoot() {
    Row() {
      Text(this.debrisFootText())
        .fontSize(11)
        .fontColor(TXT_HINT)
        .maxLines(3)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 12, bottom: 4 })
    .onClick(() => {
      this.loadMoreDebris();
    })
  }

  @Builder
  debrisNote() {
    Text('数据来源：GCAT (J. McDowell, planet4589.org/space/gcat) · CC-BY')
      .fontSize(10)
      .fontColor('#4A5670')
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ top: 15, bottom: BOTTOM_PAD })
  }

  @Builder
  debrisPanel() {
    if (this.debrisLoading && this.allDebris.length === 0) {
      this.loadingBlock('加载中...')
    } else if (this.allDebris.length === 0) {
      this.emptyText('没有匹配的事件', this.debrisFailed ? '网络不佳，切走再切回可重试' : '上游事件文件尚未生成')
    } else {
      List() {
        ListItem() {
          this.debrisStatLine()
        }
        ListItem() {
          this.debrisSearch()
        }
        ListItem() {
          this.kindChips()
        }
        ListItem() {
          this.debrisStateChips()
        }

        if (this.debrisShown.length === 0) {
          // 同 catalogPanel：ListItem 内的 layoutWeight 不可靠，给固定高度兜底
          ListItem() {
            Column() {
              this.emptyText('没有匹配的事件', '换个分型或国家看看')
            }
            .width('100%')
            .height(220)
          }
        } else {
          ForEach(this.debrisShown, (item: SaDebrisItem, index: number) => {
            ListItem() {
              this.debrisItem(item, index === this.debrisShown.length - 1, index === 0)
            }
          }, (item: SaDebrisItem, index: number) => 'deb#' + item.id + '@' + index.toString())
        }

        ListItem() {
          this.debrisFoot()
        }
        ListItem() {
          this.debrisNote()
        }
      }
      .width('100%')
      .layoutWeight(1)
      // 小程序 debris-section 没有外层左右 padding，卡片贴边；这里统一 12，
      // 与「全球在轨」的卡片外边距对齐，避免三个 tab 左右边线乱跳
      .padding({ left: 12, right: 12 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(8)
      .onReachEnd(() => {
        this.loadMoreDebris();
      })
    }
  }

  // ============ build ============

  build() {
    Column() {
      this.pageHead()
      this.segmented()

      if (this.activeTab === TAB_STATS) {
        this.statsPanel()
      } else if (this.activeTab === TAB_CATALOG) {
        this.catalogPanel()
      } else {
        this.debrisPanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    // 抽屉挂在页面根上而不是某张卡片上：卡片会被列表回收重绘，挂在根上时序更稳。
    // onDisappear 负责把状态同步回来 —— 用户下滑关闭时 isShow 不会自己变 false。
    .bindSheet(this.sheetOpen, this.detailSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      backgroundColor: '#10151F',
      onDisappear: () => {
        this.sheetOpen = false;
      }
    })
  }
}
