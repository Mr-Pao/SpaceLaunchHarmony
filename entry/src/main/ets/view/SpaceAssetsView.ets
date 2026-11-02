/**
 * view/SpaceAssetsView.ets —— 「太空资产」页（三个 tab：在轨统计 / 卫星目录 / 解体再入）
 *
 * 对位小程序：pages/space-assets/space-assets.vue（三 tab）及其三个 *-section 组件。
 *
 * 结构（自上而下）：
 *   页头「太空资产」+ 副标题 → 三段切换 → 当前 tab 的内容区
 *
 * ── 为什么三段切换不用 Tabs 组件 ──
 *   工程其它页（LaunchView / MineView）都是「Row + 三个 Text + 手写选中态」，
 *   视觉口径（#141A26 底 + 圆角 16 + 选中 #2938BDF8 底 / #38BDF8 字）已经统一。
 *   这里沿用同一套：既不用为 Tabs 调 tabBar 的默认样式，也不会出现
 *   「切 tab 时容器高度跳一下」的抖动。
 *
 * ── 为什么三个 tab 各自懒加载 ──
 *   satellites 索引自带 800 条（约 220KB），debris-events 1600 条，
 *   一进页就把三个数据集全拉一遍，弱网下首屏要等三份 JSON。
 *   所以每个 tab 一个 *Loaded / *Loading / *Failed 三态，切到才发请求；
 *   加载态、空态、失败态各画各的，绝不共用「没数据」一种文案。
 *
 * ── 为什么全量不进 @State ──
 *   卫星目录全量 20109 条 × 22 个字段。塞 @State 意味着每个条目都被代理包一层、
 *   每次刷新全量脏检查，滚动会明显掉帧。所以：
 *     全量      → 普通成员 all（改了不重绘）
 *     搜索命中  → 普通成员 pool
 *     要画的    → @State shown（只放当前这 60 / 120 条）
 *   与 RocketView 的做法一致（那边是 150 型也这么处理）。
 *
 * ── 为什么分片收口用 nextIndex >= chunks ──
 *   Repository.toChunk() 在 index > 0 时上层传的是 undefined（见 Repository.ets:597-627），
 *   于是 `chunks` 恒为 1、`end` 恒为 true。若用 res.end 判断「还有没有下一片」，
 *   第一次触底就会认为加载完了，目录永远停在 800 条。
 *   唯一可靠的收口是：**chunk 0 拿到的 chunks 总数** + 自己维护的 nextIndex。
 *
 * ── 为什么 catch 里绝不置 loaded = true ──
 *   弱网无缓存时 repo.load 是 reject 而不是返回空。曾经的写法
 *   `.catch(() => null)` 后再置 loaded，结果首屏变成**永久空 tab**，
 *   用户不重进页面就再也看不到数据。这里失败只置 failed，loaded 保持 false，
 *   切走再切回会重新拉一次。
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
  saThousand,
  saDecadeLabel,
  saKvOf,
  saDash,
  saTake,
  saJoin
} from '../model/Satellite';

const DOMAIN: number = 0x0000;
const TAG: string = 'SpaceAssetsView';

// ============ 设计变量（与工程其它页同源） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TXT_MAIN: string = '#FFFFFF';
const TXT_SUB: string = '#A7B4C7';
const TXT_DIM: string = '#55617A';
const TXT_HINT: string = '#6B7891';
const ACCENT: string = '#38BDF8';
const BAR_TRACK: string = '#1E2637';
const CHIP_BG: string = '#1A2233';

const PAGE_PAD: number = 12;
/** 底部悬浮胶囊占位：胶囊是浮层，内容会铺到屏幕底，不垫就会压住最后一条 */
// 底部留白：本页是 NavDestination 二级页，胶囊在详情页打开时已被摘掉，
// 不需要按 tab 根页那样让位 92~120，32 只够滑到底时最后一行不贴边。
const BOTTOM_PAD: number = 32;
const CARD_GAP: number = 8;

// ============ 三个 tab 的下标 ============

const TAB_STATS: number = 0;
const TAB_CATALOG: number = 1;
const TAB_DEBRIS: number = 2;

/** 每张分布卡只画前 8 项：第 9 名往后占比都不到 1%，条形图已经看不出差别 */
const DIST_ROWS: number = 8;
/** 卫星目录首屏条数 */
const CATALOG_STEP: number = 60;
/** 搜索命中的上限：再多也不是「找一颗卫星」，而是把 @State 撑爆 */
const SEARCH_LIMIT: number = 200;
/** 解体再入每次展示 120 条 */
const DEBRIS_STEP: number = 120;

/** 筛选值：与 SaDebrisItem.kind 逐一对应 */
const KIND_ALL: string = 'all';
const KIND_BREAKUP: string = 'breakup';
const KIND_REENTRY: string = 'reentry';

/**
 * 三段切换的配置。
 *
 * 用 class 而不是对象字面量：ArkTS 禁止无类型对象字面量直接作为值赋给数组
 * （"Object literal must correspond to some explicitly declared class or interface"）。
 */
class SaTabOption {
  key: number = 0;
  label: string = '';

  constructor(key: number, label: string) {
    this.key = key;
    this.label = label;
  }
}

const TABS: SaTabOption[] = [
  new SaTabOption(TAB_STATS, '在轨统计'),
  new SaTabOption(TAB_CATALOG, '卫星目录'),
  new SaTabOption(TAB_DEBRIS, '解体再入')
];

/** 解体再入的筛选配置 */
class SaKindOption {
  value: string = '';
  label: string = '';

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const KINDS: SaKindOption[] = [
  new SaKindOption(KIND_ALL, '全部'),
  new SaKindOption(KIND_BREAKUP, '解体'),
  new SaKindOption(KIND_REENTRY, '再入')
];

@Component
export struct SpaceAssetsView {
  // ============ 公共状态 ============

  @State activeTab: number = TAB_STATS;

  // ============ Tab A：在轨统计 ============

  @State statsLoaded: boolean = false;
  @State statsLoading: boolean = false;
  @State statsFailed: boolean = false;
  @State statsTotal: number = 0;
  /** 四组分布。byDecade 在 applyStats() 里就转成了 SaKv（k 带 s），
   *  这样四个卡片的 @Builder 只有一种入参类型，少一层类型分叉 */
  @State distState: SaKv[] = [];
  @State distOrbit: SaKv[] = [];
  @State distClass: SaKv[] = [];
  @State distDecade: SaKv[] = [];

  // ============ Tab B：卫星目录 ============

  @State catalogLoaded: boolean = false;
  @State catalogLoading: boolean = false;
  @State catalogFailed: boolean = false;
  @State keyword: string = '';
  /** 当前要画的这一页（60 / 120 / …，或搜索命中的前 200） */
  @State catalogShown: SaItem[] = [];
  /** 当前条件下可见条数（无搜索 = all.length；搜索 = 命中数，上限 200） */
  @State catalogHit: number = 0;
  /** 已经展开到多少条 */
  @State catalogNum: number = CATALOG_STEP;
  /** 下一片的下标，从 1 开始 */
  @State nextIndex: number = 1;
  /** 分片总数，**只在 chunk 0 时写入**（见文件头说明） */
  @State chunksTotal: number = 1;
  /** 每片条数（chunk 0 返回的 chunkSize，实测 800）。用它算总量，别写死 */
  @State chunkSize: number = 0;

  /** 卫星全量（普通成员，改了不重绘） */
  private all: SaItem[] = [];
  /** 当前搜索结果（普通成员） */
  private pool: SaItem[] = [];
  /** 追加锁：boolean 防重入，避免 onReachEnd 连发导致同一片拉两次 */
  private moreLock: boolean = false;

  // ============ Tab C：解体再入 ============

  @State debrisLoaded: boolean = false;
  @State debrisLoading: boolean = false;
  @State debrisFailed: boolean = false;
  @State debrisKind: string = KIND_ALL;
  @State debrisShown: SaDebrisItem[] = [];
  @State debrisTotal: number = 0;
  @State debrisBreakup: number = 0;
  /** 当前筛选下的可见总数（用于底部「已显示 120 / 1600」） */
  @State debrisHit: number = 0;

  /** 事件全量（普通成员） */
  private allDebris: SaDebrisItem[] = [];
  /** 当前筛选结果（普通成员） */
  private debrisPool: SaDebrisItem[] = [];

  // ============ 生命周期 ============

  aboutToAppear(): void {
    // 只预载第一个 tab；另外两个等切过去再说（见文件头「懒加载」）
    this.ensureStats(false);
  }

  // ============ 数据：Tab A 在轨统计 ============

  /**
   * 在轨统计加载。
   *
   * peek 先上屏的理由：这是「聚合数字」而不是逐条列表，缓存里的 20/10/4/8 项
   * 分布与线上的差异要以天为单位，几乎不可能过期到影响观感。先画再刷，
   * 切 tab 回来是零等待。
   */
  private ensureStats(force: boolean): void {
    if (this.statsLoading) {
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
      });
  }

  /** 落地：四组分布各自取前 8 项，byDecade 顺便把数字键转成「1950s」 */
  private applyStats(data: SaOrbitStatsPayload): void {
    const total: number = data.total !== undefined ? data.total : 0;
    if (total > 0) {
      this.statsTotal = total;
    }

    const byState: SaKv[] = data.byState !== undefined ? data.byState : [];
    const byOrbit: SaKv[] = data.byOrbit !== undefined ? data.byOrbit : [];
    const byClass: SaKv[] = data.byClass !== undefined ? data.byClass : [];
    const byDecade: SaKvNum[] = data.byDecade !== undefined ? data.byDecade : [];

    this.distState = saTake(byState, DIST_ROWS);
    this.distOrbit = saTake(byOrbit, DIST_ROWS);
    this.distClass = saTake(byClass, DIST_ROWS);

    // byDecade 的 k 是 number，不能直接塞进 SaKv（k: string），必须重建
    const decades: SaKv[] = [];
    const decadeLimit: number = byDecade.length < DIST_ROWS ? byDecade.length : DIST_ROWS;
    for (let i = 0; i < decadeLimit; i++) {
      const row: SaKvNum = byDecade[i];
      decades.push(saKvOf(saDecadeLabel(row.k), row.v));
    }
    this.distDecade = decades;
  }

  // ============ 数据：Tab B 卫星目录 ============

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

  /**
   * 触底追加。三道闸，顺序不能换：
   *   ① 搜索态直接返回 —— 用户在搜「Starlink」，后台悄悄拉 26 片纯属浪费
   *   ② 已在拉片 —— boolean 锁，onReachEnd 会连发好几次
   *   ③ 本地还有没展示的（60 → 120 …）先本地放，放完才值得发请求
   */
  private loadMoreCatalog(): void {
    if (this.keyword.trim().length > 0) {
      return;
    }
    if (this.moreLock) {
      return;
    }
    if (this.catalogNum < this.all.length) {
      this.catalogNum = this.catalogNum + CATALOG_STEP;
      this.rebuildCatalog();
      return;
    }
    if (this.nextIndex >= this.chunksTotal) {
      return;
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
  }

  /**
   * 重算当前要画的切片。
   *
   * 搜索口径（与小程序一致，全部小写比较）：
   *   hay = name + satcat + intl + stateZh + orbitZh
   * 只搜这五个字段而不是全字段：alt / owner / status 搜出来的是噪音
   * （输入 "US" 会把所有美国卫星连同 owner 里的 US 全捞出来）。
   */
  private rebuildCatalog(): void {
    const kw: string = this.keyword.trim().toLowerCase();

    if (kw.length === 0) {
      this.pool = this.all;
      this.catalogHit = this.all.length;
      this.catalogShown = saTake(this.all, this.catalogNum);
      return;
    }

    const hits: SaItem[] = [];
    for (let i = 0; i < this.all.length; i++) {
      if (hits.length >= SEARCH_LIMIT) {
        break;
      }
      const item: SaItem = this.all[i];
      const hay: string = (item.name + ' ' + item.satcat + ' ' + item.intl + ' ' +
        item.stateZh + ' ' + item.orbitZh).toLowerCase();
      if (hay.indexOf(kw) >= 0) {
        hits.push(item);
      }
    }
    this.pool = hits;
    this.catalogHit = hits.length;
    this.catalogShown = hits;
  }

  private onSearch(value: string): void {
    if (value === this.keyword) {
      return;
    }
    this.keyword = value;
    this.rebuildCatalog();
  }

  // ============ 数据：Tab C 解体再入 ============

  /**
   * 事件流加载：一次 1600 条全进内存（约 260KB），没有分片。
   *
   * 为什么不做分片追加：这份数据的价值在「筛」而不在「翻」——
   * 用户要看的是「今年的解体事件」，本地全量筛选才有意义。
   * 首屏只画 120 条，剩下的靠触底分批放到 @State。
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
    this.rebuildDebris();
  }

  /** 筛选只做一次遍历，结果进普通成员；@State 只留切片与计数 */
  private rebuildDebris(): void {
    const out: SaDebrisItem[] = [];
    for (let i = 0; i < this.allDebris.length; i++) {
      const item: SaDebrisItem = this.allDebris[i];
      if (this.debrisKind !== KIND_ALL && item.kind !== this.debrisKind) {
        continue;
      }
      out.push(item);
    }
    this.debrisPool = out;
    this.debrisHit = out.length;
    this.debrisShown = saTake(out, DEBRIS_STEP);
  }

  private switchKind(value: string): void {
    if (this.debrisKind === value) {
      return;
    }
    this.debrisKind = value;
    this.rebuildDebris();
  }

  /** 触底再放 120 条；已放完就不动 */
  private loadMoreDebris(): void {
    if (this.debrisShown.length >= this.debrisPool.length) {
      return;
    }
    const next: number = this.debrisShown.length + DEBRIS_STEP;
    this.debrisShown = saTake(this.debrisPool, next);
  }

  // ============ 交互 ============

  private switchTab(tab: number): void {
    if (this.activeTab === tab) {
      return;
    }
    this.activeTab = tab;
    // 切到哪个才拉哪个（懒加载的唯一入口）
    if (tab === TAB_STATS) {
      this.ensureStats(false);
    } else if (tab === TAB_CATALOG) {
      this.ensureCatalog();
    } else {
      this.ensureDebris(false);
    }
  }

  // ============ 小工具 ============

  /** 一组分布项里的最大值，条形图按它归一化 */
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
   * 条形宽度（百分比字符串，静态赋值）。
   *
   * 最小值锁 2%：占比 0.1% 的条目如果算出来是 0%，条会彻底消失，
   * 看起来像「这一行坏了」，而不是「这一项很少」。
   * 不用动画（animateTo + 百分比宽度在 List 复用下会错位）。
   */
  private barWidth(v: number, maxV: number): string {
    if (maxV <= 0) {
      return '0%';
    }
    const raw: number = Math.round((v / maxV) * 1000) / 10;
    let pct: number = raw < 2 ? 2 : raw;
    if (pct > 100) {
      pct = 100;
    }
    return pct.toString() + '%';
  }

  /** 卫星总量估算：片数 × 每片条数（第 0 片拿到的两个元信息，不写死 800） */
  private catalogTotal(): number {
    const size: number = this.chunkSize > 0 ? this.chunkSize : 1;
    return this.chunksTotal * size;
  }

  /** 卫星第二行元信息：satcat · intl · stateZh · orbitZh */
  private catalogMeta(item: SaItem): string {
    return saJoin([item.satcat, item.intl, item.stateZh, item.orbitZh]);
  }

  /** 事件第二行元信息：intl · reentry · stateZh */
  private debrisMeta(item: SaDebrisItem): string {
    return saJoin([item.intl, saDash(item.reentry), item.stateZh]);
  }

  private kindChipBg(kind: string): string {
    return kind === KIND_BREAKUP ? '#33FF3B30' : '#3355617A';
  }

  private kindChipColor(kind: string): string {
    return kind === KIND_BREAKUP ? '#FF3B30' : '#A7B4C7';
  }

  /** 当前筛选下的总条数（右上角那个数字） */
  private kindCount(): number {
    if (this.debrisKind === KIND_BREAKUP) {
      return this.debrisBreakup;
    }
    if (this.debrisKind === KIND_REENTRY) {
      const rest: number = this.debrisTotal - this.debrisBreakup;
      return rest > 0 ? rest : 0;
    }
    return this.debrisTotal;
  }

  // ============ UI：页头与切换 ============

  @Builder
  pageHead() {
    Column() {
      Text('太空资产')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TXT_MAIN)
        .maxLines(1)
        .width('100%')

      Text('在轨统计 · 卫星百科 · 解体再入')
        .fontSize(11)
        .fontColor(TXT_HINT)
        .maxLines(1)
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8, bottom: 12 })
  }

  /** 三段切换外壳：底 #141A26 + 圆角 16 + 极淡描边（与 LaunchView 的 feed-seg 同款） */
  @Builder
  segmented() {
    Row() {
      ForEach(TABS, (opt: SaTabOption) => {
        Text(opt.label)
          .fontSize(12.5)
          .fontWeight(this.activeTab === opt.key ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.activeTab === opt.key ? ACCENT : TXT_HINT)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(13)
          .backgroundColor(this.activeTab === opt.key ? '#2938BDF8' : '#00000000')
          .onClick(() => {
            this.switchTab(opt.key);
          })
      }, (opt: SaTabOption) => 'tab' + opt.key.toString())
    }
    .width('100%')
    .padding(3)
    .backgroundColor(CARD_BG)
    .borderRadius(16)
    .border({ width: 1, color: '#0DFFFFFF' })
  }

  // ============ UI：通用状态 ============

  /** 加载态：转圈 + 一句话 */
  @Builder
  loadingState(text: string) {
    Column() {
      LoadingProgress()
        .width(26)
        .height(26)
        .color(ACCENT)
      Text(text)
        .fontSize(12)
        .fontColor(TXT_DIM)
        .margin({ top: 10 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 空态 / 失败态：图标 + 主文案 + 副文案（两者文案必须不同，别共用一句） */
  @Builder
  tipState(icon: string, title: string, sub: string) {
    Column() {
      Text(icon)
        .fontSize(32)
        .opacity(0.5)
      Text(title)
        .fontSize(13)
        .fontColor(TXT_SUB)
        .margin({ top: 10 })
      Text(sub)
        .fontSize(11)
        .fontColor(TXT_DIM)
        .margin({ top: 6 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ============ UI：Tab A 在轨统计 ============

  /**
   * 大数字卡。
   *
   * 这个数不是从 list 里数出来的（list 恒为空），而是 payload.total ——
   * 也就是 CI 侧 GCAT 全量在轨物体的计数（实测 34925）。
   */
  @Builder
  totalCard() {
    Column() {
      Row() {
        Text(saThousand(this.statsTotal))
          .fontSize(32)
          .fontWeight(FontWeight.Bold)
          .fontColor(TXT_MAIN)
          .maxLines(1)

        Text('在轨物体')
          .fontSize(12)
          .fontColor(TXT_SUB)
          .margin({ left: 8 })
          .padding({ bottom: 5 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Text('已知在轨物体总数')
        .fontSize(10)
        .fontColor(TXT_DIM)
        .maxLines(1)
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(CARD_BG)
    .borderRadius(12)
  }

  /**
   * 一张分布卡：标题 + 横向条形列表。
   *
   * 条形用「外层 Row 当轨道、内层 Text('') 当填充」，不用 Progress：
   * Progress 的圆角与高度在不同 API 版本上不一致，而 Row/Text 的两层圆角是确定的。
   * 填充为什么用 Text 而不是空容器 Row() {}：容器组件的子块不能留空（全工程 0 例），
   * 而 Text 支持百分比宽度 + 背景色，是最稳的「纯色矩形」。
   * 百分比宽度**静态赋值**（不做 animateTo），见 barWidth() 的注释。
   */
  @Builder
  distCard(title: string, list: SaKv[]) {
    Column() {
      Text(title)
        .fontSize(12)
        .fontColor(TXT_SUB)
        .maxLines(1)
        .width('100%')

      if (list.length === 0) {
        Text('暂无数据')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .width('100%')
          .margin({ top: 10 })
      } else {
        Column() {
          ForEach(list, (row: SaKv) => {
            Row() {
              // 名称定宽 110：定宽才能让四张卡的条起点对齐，
              // 用 layoutWeight 会因为名字长度不同而条长短不齐
              Text(row.k)
                .fontSize(11)
                .fontColor(TXT_SUB)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width(110)

              Row() {
                // 条的填充用空 Text 而不是空 Row()：容器组件的子块不能留空，
                // 而 Text 支持百分比宽度 + 背景色，是最稳的「纯色矩形」
                Text('')
                  .height(8)
                  .borderRadius(4)
                  .backgroundColor(ACCENT)
                  .width(this.barWidth(row.v, this.maxOf(list)))
              }
              .layoutWeight(1)
              .height(8)
              .borderRadius(4)
              .backgroundColor(BAR_TRACK)
              .clip(true)
              .margin({ left: 8, right: 8 })

              Text(saThousand(row.v))
                .fontSize(11)
                .fontColor(TXT_SUB)
                .maxLines(1)
                .textAlign(TextAlign.End)
                .width(52)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .margin({ top: 7 })
          }, (row: SaKv, index: number) => title + '#' + index.toString() + '#' + row.k)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(CARD_BG)
    .borderRadius(12)
  }

  @Builder
  statsPanel() {
    if (this.statsLoading && !this.statsLoaded && this.statsTotal === 0) {
      this.loadingState('正在读取在轨统计…')
    } else if (this.statsFailed && this.statsTotal === 0) {
      this.tipState('🛰', '在轨统计加载失败', '检查网络后切走再切回')
    } else if (this.statsTotal === 0 && this.distState.length === 0) {
      this.tipState('🛰', '暂无在轨统计数据', '上游统计文件尚未生成')
    } else {
      Scroll() {
        Column({ space: CARD_GAP }) {
          this.totalCard()
          this.distCard('按国家', this.distState)
          this.distCard('按轨道', this.distOrbit)
          this.distCard('按类别', this.distClass)
          this.distCard('按年代', this.distDecade)
          Text('数据来源：GCAT（Jonathan McDowell，CC-BY 4.0）')
            .fontSize(10)
            .fontColor('#3C4760')
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 6 })
        }
        .width('100%')
        .padding({ top: 12 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
  }

  // ============ UI：Tab B 卫星目录 ============

  @Builder
  searchBar() {
    Row() {
      Text('🔍')
        .fontSize(12)
        .opacity(0.5)
        .margin({ right: 6 })

      TextInput({ text: this.keyword, placeholder: '搜索卫星名、编号、国家' })
        .layoutWeight(1)
        .type(InputType.Normal)
        .enterKeyType(EnterKeyType.Search)
        .placeholderColor(TXT_DIM)
        .placeholderFont({ size: 12 })
        .fontSize(12)
        .fontColor(TXT_MAIN)
        .caretColor(ACCENT)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .height(34)
        .onChange((value: string) => {
          this.onSearch(value);
        })

      if (this.keyword.length > 0) {
        Text('✕')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .padding({ left: 8, right: 2, top: 4, bottom: 4 })
          .onClick(() => {
            this.onSearch('');
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 10 })
    .height(36)
    .backgroundColor('#0D1420')
    .borderRadius(10)
    .border({ width: 1, color: '#0DFFFFFF' })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  catalogRow(item: SaItem) {
    Row() {
      Column() {
        Text(item.name)
          .fontSize(13)
          .fontColor(TXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.catalogMeta(item))
          .fontSize(11)
          .fontColor(TXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(item.clsZh)
        .fontSize(10)
        .fontColor(ACCENT)
        .maxLines(1)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor(CHIP_BG)
        .borderRadius(4)
        .margin({ left: 10 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(CARD_BG)
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  catalogPanel() {
    if (this.catalogLoading && !this.catalogLoaded && this.all.length === 0) {
      this.loadingState('正在读取卫星目录…')
    } else if (this.catalogFailed && this.all.length === 0) {
      this.tipState('📡', '卫星目录加载失败', '检查网络后切走再切回')
    } else if (this.all.length === 0) {
      this.tipState('📡', '卫星目录为空', '上游编目文件尚未生成')
    } else {
      Column() {
        this.searchBar()

        Row() {
          Text(this.keyword.trim().length > 0
            ? '命中 ' + saThousand(this.catalogHit) + ' 条'
            : '已加载 ' + saThousand(this.all.length) + ' / ' + saThousand(this.catalogTotal()))
            .fontSize(10)
            .fontColor(TXT_DIM)
            .maxLines(1)
            .layoutWeight(1)

          if (this.keyword.trim().length > 0 && this.catalogHit >= SEARCH_LIMIT) {
            Text('仅显示前 ' + SEARCH_LIMIT.toString() + ' 条')
              .fontSize(10)
              .fontColor(TXT_HINT)
              .maxLines(1)
          }
        }
        .width('100%')
        .padding({ top: 8, bottom: 4 })

        if (this.catalogShown.length === 0) {
          this.tipState('🔎', '没有匹配的卫星', '换个关键词试试')
        } else {
          List({ space: CARD_GAP }) {
            ForEach(this.catalogShown, (item: SaItem, index: number) => {
              ListItem() {
                this.catalogRow(item)
              }
            }, (item: SaItem, index: number) => item.id + '@' + index.toString())

            ListItem() {
              Row() {
                Text(this.catalogNum >= this.all.length && this.nextIndex >= this.chunksTotal
                  ? '已加载全部 ' + saThousand(this.all.length) + ' 条'
                  : '上拉加载更多')
                  .fontSize(11)
                  .fontColor(TXT_DIM)
                  .maxLines(1)
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 12, bottom: 16 })
            }
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(8)
          .onReachEnd(() => {
            this.loadMoreCatalog();
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
  }

  // ============ UI：Tab C 解体再入 ============

  @Builder
  kindRow() {
    Row() {
      ForEach(KINDS, (opt: SaKindOption) => {
        Text(opt.label)
          .fontSize(11.5)
          .fontWeight(this.debrisKind === opt.value ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.debrisKind === opt.value ? '#0A0E17' : TXT_SUB)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .backgroundColor(this.debrisKind === opt.value ? ACCENT : CARD_BG)
          .borderRadius(8)
          .margin({ right: 8 })
          .onClick(() => {
            this.switchKind(opt.value);
          })
      }, (opt: SaKindOption) => 'kind' + opt.value)

      Blank()

      Text('共 ' + saThousand(this.kindCount()) + ' 条')
        .fontSize(10)
        .fontColor(TXT_DIM)
        .maxLines(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  debrisRow(item: SaDebrisItem) {
    Row() {
      Column() {
        Text(item.name)
          .fontSize(13)
          .fontColor(TXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(this.debrisMeta(item))
          .fontSize(11)
          .fontColor(TXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(item.statusZh)
        .fontSize(10)
        .fontColor(this.kindChipColor(item.kind))
        .maxLines(1)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .backgroundColor(this.kindChipBg(item.kind))
        .borderRadius(4)
        .margin({ left: 10 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(CARD_BG)
    .borderRadius(12)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  debrisPanel() {
    if (this.debrisLoading && !this.debrisLoaded && this.debrisShown.length === 0) {
      this.loadingState('正在读取解体再入事件…')
    } else if (this.debrisFailed && this.allDebris.length === 0) {
      this.tipState('💥', '解体再入数据加载失败', '检查网络后切走再切回')
    } else if (this.allDebris.length === 0) {
      this.tipState('💥', '暂无解体再入事件', '上游事件文件尚未生成')
    } else {
      Column() {
        this.kindRow()

        if (this.debrisShown.length === 0) {
          this.tipState('💥', '该类别暂无事件', '切到「全部」看看')
        } else {
          List({ space: CARD_GAP }) {
            ForEach(this.debrisShown, (item: SaDebrisItem, index: number) => {
              ListItem() {
                this.debrisRow(item)
              }
            }, (item: SaDebrisItem, index: number) => item.id + '@' + index.toString())

            ListItem() {
              Row() {
                Text(this.debrisShown.length >= this.debrisPool.length
                  ? '已显示全部 ' + saThousand(this.debrisShown.length) + ' 条'
                  : '已显示 ' + saThousand(this.debrisShown.length) + ' / ' +
                    saThousand(this.debrisPool.length) + '，继续下滑加载更多')
                  .fontSize(11)
                  .fontColor(TXT_DIM)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 12, bottom: 16 })
            }
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(8)
          .onReachEnd(() => {
            this.loadMoreDebris();
          })
        }
      }
      .width('100%')
      .layoutWeight(1)
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
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
    .backgroundColor(BG_PRIMARY)
  }
}
