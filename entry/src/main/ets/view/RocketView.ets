/**
 * view/RocketView.ets —— 「全球火箭实力榜」
 *
 * 对位小程序：pages/rockets/rockets.vue（1277 行，唯一权威基准）。
 * 结构（自上而下，整页一个 List 滚动）：
 *   星空层 → 滚动后才浮出的毛玻璃条 → hero 渐变大卡（kicker / 标题 +「在役」/
 *   副标题 + 型号总数 / 三格极值）→ 搜索框 →「排序方式」+ 四个榜单 →
 *   七个地区 chip → 当前榜单说明行 → 排名卡 × N → footer
 *
 * ── 本次按小程序对齐的 27 条差异（逐条标在代码旁）──
 *   高：hero 渐变大卡（158deg 三色 + 26rpx 圆角 + 24rpx 投影 + 径向青光 + 底部 2rpx 青线）、
 *       「在役」绿徽标、型号总数 66rpx 青字在右下、三格「连排 + 竖线分隔」且改回
 *       最近近地运力 / 发射最活跃 / 可复用型号、排序选中态青渐变、地区选中态近白、
 *       星空层、下拉刷新、卡片图区 228×216rpx。
 *   中：主标题 24vp 带青光、搜索框 39vp/radius 7、地区 chip 4vp 方角、
 *       「N 个结果」青色、nav-mask 毛玻璃条、卡片渐变底 + 阴影、前三名左侧青竖线、
 *       名次角标贴左上直角 + 前三金银铜、可复用角标挪回图左下、「详情」青边胶囊、
 *       空态图标 30vp 与文案、footer 文案。
 *   低：kicker 字距、标题字重；hover 态与暗门面板按「鸿蒙不需要」跳过（见文件末注释）。
 *
 * ── 为什么整页用一个 List 而不是 Column + Scroll ──
 *   头部（hero + 搜索 + 两排筛选）差不多占满一屏，钉在 List 外面的话卡片区只剩半屏。
 *   小程序本来就是整页滚动，用「头部当 List 的第 0..4 项」复刻同一手感，
 *   顺带白拿 List 的节点回收、onReachEnd 与 onScrollIndex。
 *
 * ── 为什么全量不进 @State ──
 *   launchers 原始库 500+ 条、在役 150+，每条视图模型带 10 个字符串字段。
 *   塞进 @State 等于代理包一层 + 每次刷新全量脏检查。所以：
 *   `all` / `pool` / `filtered` 是普通成员（改了不重绘），@State 只放
 *   **当前真正要画的这 14 条**（shown）和几个驱动文案的标量。别改这个设计。
 *
 * ── 为什么筛选/排序全在本地 ──
 *   launchers 是一份静态 JSON，load 一次就在内存里；派生字段（score / 搜索串 /
 *   地区码）在 rtBuildLib() 里一次算完，这里只做「筛 + 排 + 切片」。
 *
 * ⚠ 日志一律 hilog，不用 console。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { strOf } from '../utils/Format';
import {
  RocketCard,
  RtRocket,
  RtLauncherRaw,
  RtLauncherList,
  rtBuildLib
} from '../components/RocketCard';
import { StarField } from '../components/StarField';
import { Nav } from '../routes/Nav';
import { RocketNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'RocketView';

// ============ 配色（全部取自 rockets.vue，rpx ÷ 2 = vp） ============

const BG_PRIMARY: string = '#0A0E17';
/** 搜索框 / 排序块 / 地区 chip 的底，对位 #131926 */
const CHIP_BG: string = '#131926';
const TXT_DIM: string = '#55617A';
/** .hero-sub / .sort-label 那一档 */
const TXT_HINT: string = '#6B7891';
/** .hero-kicker / .hcell-k 那一档，比 TXT_HINT 再淡一点 */
const TXT_MUTE: string = '#5D6A7E';
const ACCENT: string = '#38BDF8';
/** 「在役」绿：这一页的红色只留给失败与告警，绿色表示仍在服役 */
const GREEN: string = '#34C759';

const PAGE_PAD: number = 12;
/** 底部悬浮胶囊让位：胶囊 58 + 下边距 20 + 渐变渐入 28，再留 14 余量 */
const BOTTOM_PAD: number = 120;
const CARD_GAP: number = 8;
/** 毛玻璃条高度：鸿蒙内容区默认已让开状态栏，只盖标题栏那 44 ≈ 52 足够 */
const NAV_MASK_H: number = 52;

/**
 * hero 大卡高度（vp）。
 *
 * 小程序 .hero 是内容撑高：padding 20rpx 26rpx 0 + 三行内容（kicker 19rpx、
 * 标题行 48rpx、副标题+大数字、三格 24rpx+ 合计），整个约 350rpx ≈ 175vp。
 * 这里**必须给死值**：卡里有 height('100%') 的径向光层，Stack 没高度时百分比
 * 会回溯到 ListItem 的整屏高度，把卡撑满一屏（实测踩过）。
 */
const HERO_H: number = 194;
/**
 * 毛玻璃条的触发索引。
 * 小程序按 scrollTop > 120px 判断；ArkUI 的 List 只给 onScrollIndex（索引，不是像素），
 * 所以改成「头部整块滚出可视区（start ≥ 1）才浮出」。阈值偏大一点点，
 * 换来的是不依赖未验证的 onDidScroll 签名 —— 宁可晚浮出，不能漏浮出。
 */
const NAV_SOLID_INDEX: number = 1;

/** 每次上拉追加多少条。14 约一屏：再多首屏建树就慢了 */
const STEP: number = 14;
/** 可靠榜门槛：只打过一两发的 100% 成功率没有说服力 */
const MIN_LAUNCH_FOR_RELIABILITY: number = 5;

// ============ 榜单 / 地区配置 ============

/** 用类而不是对象字面量：ArkTS 禁止无类型字面量直接当值 */
class RtSortOption {
  value: string = '';
  label: string = '';
  desc: string = '';

  constructor(value: string, label: string, desc: string) {
    this.value = value;
    this.label = label;
    this.desc = desc;
  }
}

class RtRegionOption {
  value: string = '';
  label: string = '';

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const SORTS: RtSortOption[] = [
  new RtSortOption('overall', '综合榜', '45% 活跃度 · 35% 可靠性 · 20% LEO 运力'),
  new RtSortOption('capacity', '运力榜', '按 LEO 运力从高到低'),
  new RtSortOption('launches', '发射榜', '按累计发射次数从高到低'),
  new RtSortOption('reliability', '可靠榜', '成功率优先，至少 5 次发射才参与排名')
];

const REGIONS: RtRegionOption[] = [
  new RtRegionOption('all', '全球'),
  new RtRegionOption('cn', '中国'),
  new RtRegionOption('us', '美国'),
  new RtRegionOption('ru', '俄罗斯'),
  new RtRegionOption('eu', '欧洲'),
  new RtRegionOption('asia', '亚洲其他'),
  new RtRegionOption('other', '其他')
];

@Component
export struct RocketView {
  // ============ 渲染状态（只放驱动 UI 的标量 + 当前这一页） ============

  @State keyword: string = '';
  @State activeSort: string = 'overall';
  @State activeRegion: string = 'all';
  /** 当前已展开到多少条（14 / 28 / 42…） */
  @State listNum: number = STEP;
  /** 当前条件下的命中总数 */
  @State hitTotal: number = 0;
  /** 在役型号数（hero 右下的大数字，随地区变化，对位 pool.length） */
  @State poolCount: number = 0;
  /** 品牌库总条数（含退役）。hero 不用它，只用来区分「库空」与「搜不到」 */
  @State libTotal: number = 0;
  @State loading: boolean = true;
  /** 下拉刷新中（Refresh 组件的双向绑定） */
  @State refreshing: boolean = false;
  /** 滚过头部后浮出毛玻璃条 */
  @State navSolid: boolean = false;
  /** 真正要画的那一段，最多 listNum 条 */
  @State shown: RtRocket[] = [];

  // 头部三格（地区切换要跟着变，所以是 @State 字符串而不是每次 build 里现算）
  @State topLeoName: string = '—';
  @State topLeoText: string = '暂无数据';
  @State topLaunchName: string = '—';
  @State topLaunchText: string = '暂无数据';
  /** 第三格：数字与量词分开存，量词固定是「型」（对位 hcell-v / hcell-n） */
  @State reusableCount: number = 0;

  // ============ 全量数据（普通成员，改完必须显式 recompute） ============

  /** 原始库全量视图模型（含退役型号） */
  private all: RtRocket[] = [];
  /** 在役 + 按型号名去重后的候选池，所有榜单都从这里来 */
  private pool: RtRocket[] = [];
  /** 当前「地区 + 搜索 + 排序」后的完整结果，只用于切片 */
  private filtered: RtRocket[] = [];

  private scroller: Scroller = new Scroller();
  private regionScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.load(false);
  }

  // ============ 加载 ============

  /**
   * force=true 走下拉刷新：跳过缓存直接回源。
   * 失败时不清空已有数据 —— 手上有一份旧榜单，比空屏好。
   */
  private load(force: boolean): void {
    this.loading = true;

    const opts: LoadOptions<RtLauncherList> = {
      force: force,
      // 有缓存先上屏再静默刷新：launchers 是静态库，不该每次进页转圈。
      // 刷新 keepScroll=true —— 用户可能已经翻到第 40 条，被弹回顶部比不刷新更糟。
      onUpdate: (data: RtLauncherList) => {
        this.applyPayload(data, true);
      }
    };

    repo.load<RtLauncherList>('launchers', opts)
      .then((data: RtLauncherList) => {
        this.applyPayload(data, false);
      })
      .catch((e: BusinessError) => {
        // 失败不置任何「错误」标志：libTotal 还是 0 就已经能区分
        // 「库没到」与「搜不到」，多一个 failed 只是又一个要同步的状态。
        hilog.warn(DOMAIN, TAG, 'launchers 加载失败: %{public}s', e.message);
      })
      .then(() => {
        // 两个转圈都要收：失败也必须收，否则下拉刷新会一直转
        this.loading = false;
        this.refreshing = false;
      });
  }

  /** 原始载荷 → 全量池。只在首屏/刷新时跑，不在滚动路径上 */
  private applyPayload(data: RtLauncherList, keepScroll: boolean): void {
    const raw: RtLauncherRaw[] =
      data.list !== undefined && data.list !== null ? data.list : [];
    const built: RtRocket[] = rtBuildLib(raw);
    if (built.length === 0) {
      return;
    }
    this.all = built;
    this.pool = this.buildPool();
    this.libTotal = built.length;
    this.recompute(!keepScroll);
  }

  /**
   * 候选池 = 只留 active，按型号名去重。
   *
   * 为什么必须去重：同一个型号在 LL2 里按构型分多条（Starship / Starship V2 / V3），
   * 不去重的话榜上会出现三行同名，看起来像数据重复。组内取综合分最高的那条代表，
   * 但最高分那条往往是数据最新、**没有镜像图**的构型 —— 所以缺图时从组内借一张。
   */
  private buildPool(): RtRocket[] {
    const groups: Map<string, RtRocket[]> = new Map<string, RtRocket[]>();
    const order: string[] = [];
    for (let i = 0; i < this.all.length; i++) {
      const x: RtRocket = this.all[i];
      if (!x.active) {
        continue;
      }
      // 英文型号名是 LL2 的稳定标识；万一缺失退回中文名，至少还能分组
      const k: string = x.name.length > 0 ? x.name : x.zh;
      let bucket: RtRocket[] | undefined = groups.get(k);
      if (bucket === undefined) {
        bucket = [];
        groups.set(k, bucket);
        order.push(k);
      }
      bucket.push(x);
    }

    const out: RtRocket[] = [];
    for (let i = 0; i < order.length; i++) {
      const bucket: RtRocket[] | undefined = groups.get(order[i]);
      if (bucket === undefined || bucket.length === 0) {
        continue;
      }
      let best: RtRocket = bucket[0];
      for (let j = 1; j < bucket.length; j++) {
        if (bucket[j].score > best.score) {
          best = bucket[j];
        }
      }
      if (best.img.length === 0) {
        for (let j = 0; j < bucket.length; j++) {
          if (bucket[j].img.length > 0) {
            // 借图只影响展示，不参与任何排序口径，所以直接改视图模型
            best.img = bucket[j].img;
            break;
          }
        }
      }
      out.push(best);
    }
    return out;
  }

  // ============ 筛选 + 排序 + 切片 ============

  /**
   * 重算 filtered / shown / 头部三格。
   * resetPage=false 用于「后台刷新」：用户已经翻到第 N 页就别把他缩回 14 条。
   */
  private recompute(resetPage: boolean): void {
    const kw: string = this.keyword.trim().toLowerCase();
    const arr: RtRocket[] = [];

    for (let i = 0; i < this.pool.length; i++) {
      const r: RtRocket = this.pool[i];
      if (this.activeRegion !== 'all' && r.region !== this.activeRegion) {
        continue;
      }
      // hay 已是小写拼接串，一次 indexOf 覆盖中文名/型号/全名/厂商/构型/家族
      if (kw.length > 0 && r.hay.indexOf(kw) < 0) {
        continue;
      }
      arr.push(r);
    }

    // slice() 建副本再排：pool 是共享的，就地排会污染下一次别的榜单
    const sorted: RtRocket[] = arr.slice(0);
    sorted.sort((a: RtRocket, b: RtRocket) => this.cmp(a, b));

    if (resetPage) {
      this.listNum = STEP;
    }
    this.filtered = sorted;
    this.hitTotal = sorted.length;
    this.shown = this.slice(sorted, 0, this.listNum);
    this.refreshStats();
  }

  /** 四种排序。规则与小程序逐条对齐，改动要两边一起改 */
  private cmp(a: RtRocket, b: RtRocket): number {
    const s: string = this.activeSort;
    if (s === 'capacity') {
      const d: number = b.leo - a.leo;
      return d !== 0 ? d : b.launches - a.launches;
    }
    if (s === 'launches') {
      return b.launches - a.launches;
    }
    if (s === 'reliability') {
      const qa: boolean = a.launches >= MIN_LAUNCH_FOR_RELIABILITY;
      const qb: boolean = b.launches >= MIN_LAUNCH_FOR_RELIABILITY;
      if (qa !== qb) {
        // 达标的一律排前面：2 发 2 中不该压过 100 发 98 中
        return qa ? -1 : 1;
      }
      if (qa && qb) {
        const d: number = b.rate - a.rate;
        if (d !== 0) {
          return d;
        }
      }
      return b.launches - a.launches;
    }
    // 综合榜：从没发射过的型号不占前排 —— 运力再大也没有实战检验
    const ta: number = a.launches > 0 ? 1 : 0;
    const tb: number = b.launches > 0 ? 1 : 0;
    if (ta !== tb) {
      return tb - ta;
    }
    const d: number = b.score - a.score;
    return d !== 0 ? d : b.launches - a.launches;
  }

  /** 取 [from, from+count)。手写循环而不是 slice：少一层数组复制 */
  private slice(src: RtRocket[], from: number, count: number): RtRocket[] {
    const out: RtRocket[] = [];
    const end: number = Math.min(from + count, src.length);
    for (let i = from; i < end; i++) {
      out.push(src[i]);
    }
    return out;
  }

  /**
   * 头部三格 + hero 大数字。
   * 只看「地区」不看搜索词：搜索是找具体型号的手段，
   * 让统计跟着搜索词跳变会让人读不懂这一屏在讲什么（与小程序的 pool 口径一致）。
   */
  private refreshStats(): void {
    let bestLeo: RtRocket | null = null;
    let bestLaunch: RtRocket | null = null;
    let reusable: number = 0;
    let count: number = 0;

    for (let i = 0; i < this.pool.length; i++) {
      const r: RtRocket = this.pool[i];
      if (this.activeRegion !== 'all' && r.region !== this.activeRegion) {
        continue;
      }
      count++;
      if (r.reusable) {
        reusable++;
      }
      // 运力为 0 的型号不参与「最近近地运力」：让一个没填运力的型号当冠军是错的
      if (r.leo > 0 && (bestLeo === null || r.leo > bestLeo.leo)) {
        bestLeo = r;
      }
      if (r.launches > 0 && (bestLaunch === null || r.launches > bestLaunch.launches)) {
        bestLaunch = r;
      }
    }

    this.poolCount = count;
    this.reusableCount = reusable;
    this.topLeoName = bestLeo !== null ? bestLeo.zh : '—';
    this.topLeoText = bestLeo !== null ? bestLeo.leoText : '暂无数据';
    this.topLaunchName = bestLaunch !== null ? bestLaunch.zh : '—';
    this.topLaunchText =
      bestLaunch !== null ? bestLaunch.launches.toString() + ' 次发射' : '暂无数据';
  }

  // ============ 交互 ============

  private onSearch(text: string): void {
    const v: string = strOf(text);
    if (v === this.keyword) {
      return;
    }
    this.keyword = v;
    this.recompute(true);
    this.backToTop();
  }

  private switchSort(value: string): void {
    if (value === this.activeSort) {
      return;
    }
    this.activeSort = value;
    this.recompute(true);
    this.backToTop();
  }

  private switchRegion(value: string): void {
    if (value === this.activeRegion) {
      return;
    }
    this.activeRegion = value;
    this.recompute(true);
    this.backToTop();
  }

  /** 换条件后回到顶部：停在原位会让人以为界面没响应 */
  private backToTop(): void {
    if (this.shown.length > 0) {
      this.scroller.scrollEdge(Edge.Top);
    }
  }

  /**
   * 触底追加一批。
   * 用重建数组（而不是 push）赋值给 @State：就地 push 在部分 ArkUI 版本上
   * 只刷新长度、不刷新子节点。
   */
  private loadMore(): void {
    if (this.shown.length >= this.filtered.length) {
      return;
    }
    this.listNum = this.listNum + STEP;
    this.shown = this.slice(this.filtered, 0, this.listNum);
  }

  private openRocket(item: RtRocket): void {
    if (item.name.length === 0) {
      return;
    }
    Nav.pushRocket(new RocketNavParam(item.name));
  }

  private currentSort(): RtSortOption {
    for (let i = 0; i < SORTS.length; i++) {
      if (SORTS[i].value === this.activeSort) {
        return SORTS[i];
      }
    }
    return SORTS[0];
  }

  private hasMore(): boolean {
    return this.shown.length < this.hitTotal;
  }

  // ============ UI ============

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1 星空底层：绝对铺满、不参与命中测试，必须是 Stack 的第一个子节点
      StarField()

      // 2 顶部青蓝光晕（对位 .page 的 radial-gradient）：压在屏幕上半区，
      //   让纯黑星空有个「光从上面下来」的方向感。只铺一层、不参与命中测试。
      this.pageGlow()

      // 3 内容层
      Refresh({ refreshing: $$this.refreshing }) {
        List({ space: 0, scroller: this.scroller }) {
          ListItem() {
            this.hero()
          }
          ListItem() {
            this.searchBar()
          }
          ListItem() {
            this.sortBlock()
          }
          ListItem() {
            this.regionRow()
          }
          ListItem() {
            this.boardLine()
          }

          if (this.libTotal === 0) {
            // 库还没到（加载中 / 加载失败）：与「搜不到」是两件事
            ListItem() {
              this.emptyBlock()
            }
          } else if (this.shown.length === 0) {
            ListItem() {
              this.noMatchBlock()
            }
          } else {
            ForEach(this.shown, (item: RtRocket, index: number) => {
              ListItem() {
                RocketCard({
                  item: item,
                  rankNo: index + 1,
                  onOpen: (r: RtRocket) => {
                    this.openRocket(r);
                  }
                })
              }
              .padding({ bottom: CARD_GAP })
            }, (item: RtRocket, index: number) => item.key + '@' + index.toString())

            ListItem() {
              this.footer()
            }
          }
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(6)
        // ⚠ 不设不透明背景：星空画在它下层，一盖上就整片看不见了
        // 左右 12vp 内边距 + 底部 120 胶囊让位（padding 直接缩内容区，
        // 列表最后一项能完整滚出来，不会被悬浮胶囊压住）
        .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
        .onReachEnd(() => {
          this.loadMore();
        })
        // 滚过 hero 之后才浮出毛玻璃条（对位 onPageScroll + navSolid）
        .onScrollIndex((start: number) => {
          const solid: boolean = start >= NAV_SOLID_INDEX;
          if (solid !== this.navSolid) {
            this.navSolid = solid;
          }
        })
      }
      .width('100%')
      .height('100%')
      .onRefreshing(() => {
        // 下拉刷新 = 回到第 1 页 + 强制回源（对位 onPullDownRefresh）
        this.refreshing = true;
        this.listNum = STEP;
        this.load(true);
      })

      // 4 nav-mask：只在滚动后浮出来挡一下内容，首屏一点高度都不浪费。
      //   fixed 不占文档流 → 用 Stack 叠在内容之上；pointer-events none → hitTestBehavior。
      if (this.navSolid) {
        Column()
          .width('100%')
          .height(NAV_MASK_H)
          .backgroundColor('#D60A0E17')
          // 对位 backdrop-filter: blur(24rpx) saturate(140%)。ArkUI 没有 saturate，
          // 只做模糊；底色不透明度提到 0.84 补偿饱和度那一点观感
          .backdropBlur(12)
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }

  /**
   * 页面级两团光晕，对位 .page 的两条 radial-gradient（rockets.vue:669-670）：
   *   ① 120% 55% at 50% -8%  rgba(56,189,248,.15) → 透明 62%
   *   ② 90% 45% at 100% 6%  rgba(56,189,248,.07) → 透明 58%
   * 上下叠两层而不是合成一层：两团的圆心一个在正中偏上、一个在右上角，
   * 单层渐变表达不了「两个光源」。透明度换算成 alpha：#26 ≈ .15、#12 ≈ .07。
   * 纯装饰、不接事件 —— 盖在星空之上，一接事件就把整页的点击都吃掉了。
   */
  @Builder
  pageGlow() {
    Stack() {
      // ① 主光：压住上半屏正中
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['50%', '0%'],
          radius: '62%',
          colors: [['#2638BDF8', 0.0], ['#0038BDF8', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      // ② 右上补光：给纵深，比纯黑底更像有空间
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['100%', '6%'],
          radius: '48%',
          colors: [['#1238BDF8', 0.0], ['#0038BDF8', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  // ============ hero 渐变大卡 ============

  /**
   * 对位 .hero：158deg 三色渐变 + 26rpx 圆角 + 1rpx 白边 +
   * 0 24rpx 60rpx 投影（内阴影 inset 0 1rpx 0 无法表达，用白边顶替上沿高光）。
   */
  @Builder
  hero() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // ::before 的径向青光。原来是一块 left -18% / top -58% 的 136%×130% 圆，
      // ArkUI 的 offset 不吃负百分比（不确定且无 SDK 可查），
      // 改成「同尺寸整层、圆心压到 22% 高处」—— 视觉同样是卡面上部被青光托住。
      //
      // ⚠ 外层 Stack 必须给固定高度（下面 .height(HERO_H)）。曾经这里 height('100%')
      //   而 Stack 自己没有高度：ArkUI 的 Stack 尺寸由子节点撑，百分比会一路回溯到
      //   ListItem 的可用高度（= 整屏），整张卡被撑成满屏，搜索框/排序/榜单全被挤
      //   到屏幕外，实测截图只剩一张空卡。小程序那边 .hero 也是内容撑高（padding
      //   20rpx 26rpx 0 + 三行内容），换算到 vp 约 170，故直接钉死。
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['50%', '22%'],
          radius: '78%',
          colors: [['#3D38BDF8', 0.0], ['#0038BDF8', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      Column() {
        // kicker：19rpx / 字距 1rpx
        Text('SPACEDAILY / LAUNCH INDEX')
          .fontSize(9.5)
          .fontColor(TXT_MUTE)
          .letterSpacing(0.5)
          .maxLines(1)

        // 标题行：24vp（48rpx）+「在役」绿徽标
        Row() {
          Text('全球火箭实力榜')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .letterSpacing(1)
            .maxLines(1)
            // 对位 text-shadow: 0 6rpx 28rpx rgba(56,189,248,0.34)
            .textShadow({ radius: 14, color: '#5738BDF8', offsetX: 0, offsetY: 3 })

          this.stateChip()
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 4 })

        // 副标题 + 型号总数（右下）：总数 66rpx 青字带青光
        Row() {
          Text('基于运力、可靠性、发射活跃度')
            .fontSize(11)
            .fontColor(TXT_HINT)
            .maxLines(1)
            .layoutWeight(1)

          Column() {
            Text(this.poolCount.toString())
              .fontSize(33)
              .fontWeight(FontWeight.Bold)
              .fontColor(ACCENT)
              .textAlign(TextAlign.End)
              // 对位 text-shadow: 0 0 30rpx rgba(56,189,248,0.55)
              .textShadow({ radius: 15, color: '#8C38BDF8', offsetX: 0, offsetY: 0 })
            Text('型号火箭')
              .fontSize(10)
              .fontColor(TXT_HINT)
              .textAlign(TextAlign.End)
              .margin({ top: 3 })
          }
          .alignItems(HorizontalAlign.End)
          .margin({ left: 10 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 5 })

        // 三格极值：连成一条，用竖线分隔，不各占一张卡
        Row() {
          this.cellLeo()
          this.cellActive()
          this.cellReuse()
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .margin({ top: 12 })
        .border({ width: { top: 1 }, color: '#12FFFFFF' })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 13, right: 13, top: 10 })

      // ::after 底部 2rpx 青线，两端渐隐，收住整张卡
      Column()
        .width('100%')
        .height(1)
        .linearGradient({
          angle: 90,
          colors: [['#0038BDF8', 0.0], ['#8C38BDF8', 0.5], ['#0038BDF8', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)
    }
    .width('100%')
    .height(HERO_H)
    .margin({ top: 4 })
    .borderRadius(13)
    .clip(true)
    .linearGradient({
      // css 的 158deg 与 ArkUI 的 angle 同一坐标系（0 = 从下往上）
      angle: 158,
      colors: [['#F51E273A', 0.0], ['#F0121824', 0.58], ['#F50F141F', 1.0]]
    })
    .border({ width: 1, color: '#14FFFFFF' })
    .shadow({ radius: 30, color: '#6B000000', offsetX: 0, offsetY: 12 })
  }

  /** 「在役」徽标：绿字 / 绿边 / 8% 绿底 / 青光晕（对位 .hero-state） */
  @Builder
  stateChip() {
    Text('在役')
      .fontSize(9.5)
      .fontColor(GREEN)
      .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
      .borderRadius(3)
      .border({ width: 1, color: '#8C34C759' })
      .backgroundColor('#1434C759')
      .shadow({ radius: 8, color: '#2E34C759', offsetX: 0, offsetY: 0 })
      .margin({ left: 8 })
  }

  // ---- 三格极值 ----
  //
  // ⚠⚠ 这里踩过一个很深的 React 式直觉坑，别再改回去：
  // 1. `@Builder` **按值传参**时不建立响应式依赖。曾经写成
  //    `this.statCell('最近近地运力', this.topLeoName, this.topLeoText)`，
  //    结果 statGrid 的依赖集里压根没有 topLeoName，异步算完之后不重绘，
  //    三格永远停在初值「— / 0 型」。
  // 2. 就算把外层改成无参 builder `cellLeo()`，只要它内部还在
  //    `this.statCellBody(..., this.topLeoName, ...)` 这样传值，**内层依然不刷新** ——
  //    参数一旦按值传进 @Builder，里面的 Text 就只认调用那一刻的字符串快照。
  // 3. 所以最终写法是：每格一个无参 @Builder，Text 里**直接读 this.topXxx 成员**，
  //    不再经过任何带参 builder。三格之间样式重复了一点，但这是能刷新的唯一稳妥写法。

  /** 最近近地运力（第一格）—— Text 直接读成员，别抽带参 builder */
  @Builder
  cellLeo() {
    Column() {
      Text('最近近地运力').fontSize(9.5).fontColor(TXT_MUTE).maxLines(1)
      Text(this.topLeoName)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F0F5FC')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 4 })
      Text(this.topLeoText)
        .fontSize(10)
        .fontColor('#8A97A8')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 9, bottom: 11, right: 4 })
    .border({ width: { right: 1 }, color: '#12FFFFFF' })
  }

  /** 发射最活跃（第二格） */
  @Builder
  cellActive() {
    Column() {
      Text('发射最活跃').fontSize(9.5).fontColor(TXT_MUTE).maxLines(1)
      Text(this.topLaunchName)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F0F5FC')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 4 })
      Text(this.topLaunchText)
        .fontSize(10)
        .fontColor('#8A97A8')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 9, bottom: 11, left: 8, right: 4 })
    .border({ width: { right: 1 }, color: '#12FFFFFF' })
  }

  /** 可复用型号数（第三格）：数值 + 「型」 */
  @Builder
  cellReuse() {
    Column() {
      Text('可复用型号').fontSize(9.5).fontColor(TXT_MUTE).maxLines(1)
      Text(this.reusableCount.toString())
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F0F5FC')
        .maxLines(1)
        .width('100%')
        .margin({ top: 4 })
      Text('型')
        .fontSize(10)
        .fontColor('#8A97A8')
        .maxLines(1)
        .width('100%')
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 9, bottom: 11, left: 8 })
  }

  // ============ 搜索 / 筛选 ============

  /** 对位 .search：39vp 高 / radius 7 / #131926 底 / inset 投影 */
  @Builder
  searchBar() {
    Row() {
      Text('🔍')
        .fontSize(12)
        .opacity(0.55)
        .margin({ right: 6 })

      TextInput({ text: this.keyword, placeholder: '搜索中文名、型号、制造商' })
        .layoutWeight(1)
        .type(InputType.Normal)
        .enterKeyType(EnterKeyType.Search)
        .placeholderColor('#4A5568')
        .placeholderFont({ size: 13 })
        .fontSize(13)
        .fontColor('#E2E8F0')
        .caretColor(ACCENT)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .height(36)
        .onChange((value: string) => {
          this.onSearch(value);
        })

      if (this.keyword.length > 0) {
        Text('✕')
          .fontSize(13)
          .fontColor('#4A5568')
          .padding({ left: 8, right: 0, top: 4, bottom: 4 })
          .onClick(() => {
            this.onSearch('');
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .height(39)
    .margin({ top: 9 })
    .backgroundColor('#EB131926')
    .borderRadius(7)
    .border({ width: 1, color: '#12FFFFFF' })
    // 原来的 inset 0 2rpx 10rpx rgba(0,0,0,0.28)（内阴影）ArkUI 的 shadow 没有 inset，
    // 用一条上沿更深的边 + 外阴影的极小半径近似，避免整块浮起来
    .shadow({ radius: 2, color: '#47000000', offsetX: 0, offsetY: 1 })
    .alignItems(VerticalAlign.Center)
  }

  /** 「排序方式」标签 + 四个等宽榜单块 */
  @Builder
  sortBlock() {
    Column() {
      Text('排序方式')
        .fontSize(10.5)
        .fontColor(TXT_HINT)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ bottom: 6 })

      Row() {
        ForEach(SORTS, (opt: RtSortOption, index: number) => {
          Text(opt.label)
            .fontSize(12.5)
            .fontWeight(this.activeSort === opt.value ? FontWeight.Medium : FontWeight.Normal)
            // 选中：青渐变 + #14181F 字；未选中：#131926 底 + #8A97A8 字
            .fontColor(this.activeSort === opt.value ? '#14181F' : '#8A97A8')
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(34)
            .borderRadius(4)
            .backgroundColor(this.activeSort === opt.value ? Color.Transparent : CHIP_BG)
            // 未选中也给 1vp 描边（透明）：否则选中瞬间多出一圈边，整行会跳一下
            .border({
              width: 1,
              color: this.activeSort === opt.value ? '#E67DD3FC' : '#0FFFFFFF'
            })
            .linearGradient(
              this.activeSort === opt.value
                ? {
                  angle: 135,
                  colors: [['#7DD3FC', 0.0], ['#0EA5E9', 1.0]]
                }
                : {
                  angle: 135,
                  colors: [['#00131926', 0.0], ['#00131926', 1.0]]
                }
            )
            .shadow({
              radius: this.activeSort === opt.value ? 12 : 0,
              color: '#4D38BDF8',
              offsetX: 0,
              offsetY: 4
            })
            .margin({ right: index < SORTS.length - 1 ? 6 : 0 })
            .onClick(() => {
              this.switchSort(opt.value);
            })
        }, (opt: RtSortOption) => opt.value)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 14 })
  }

  /** 七个地区：4vp 方角 chip（对位 .region 的 border-radius 8rpx），选中近白 */
  @Builder
  regionRow() {
    Scroll(this.regionScroller) {
      Row() {
        ForEach(REGIONS, (opt: RtRegionOption) => {
          Text(opt.label)
            .fontSize(11.5)
            .fontWeight(this.activeRegion === opt.value ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.activeRegion === opt.value ? '#14181F' : '#8A97A8')
            .padding({ left: 11, right: 11, top: 4, bottom: 4 })
            .backgroundColor(this.activeRegion === opt.value ? '#EEF3FA' : CHIP_BG)
            .borderRadius(4)
            .border({
              width: 1,
              color: this.activeRegion === opt.value ? '#EEF3FA' : '#0FFFFFFF'
            })
            .shadow({
              radius: this.activeRegion === opt.value ? 9 : 0,
              color: '#2ED2E2F6',
              offsetX: 0,
              offsetY: 3
            })
            .margin({ right: 6 })
            .onClick(() => {
              this.switchRegion(opt.value);
            })
        }, (opt: RtRegionOption) => opt.value)
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: 8 })
  }

  /** 榜单口径行：左「综合榜」+ 权重说明，右「N 个结果」（青色） */
  @Builder
  boardLine() {
    Row() {
      Row() {
        Text(this.currentSort().label)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(1)
        Text(this.currentSort().desc)
          .fontSize(10)
          .fontColor(TXT_HINT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 6 })
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Bottom)

      Text(this.hitTotal.toString() + ' 个结果')
        .fontSize(11)
        .fontColor(ACCENT)
        .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({ top: 5, bottom: 8 })
  }

  /**
   * footer：文案按小程序口径。
   * 还有就「上拉加载更多」，没有了就「已显示全部 N 个型号」。
   */
  @Builder
  footer() {
    Text(this.hasMore()
      ? '上拉加载更多'
      : '已显示全部 ' + this.hitTotal.toString() + ' 个型号')
      .fontSize(11)
      .fontColor('#3D4A5C')
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 12, bottom: 20 })
  }

  /**
   * 空态①：库还没到（加载中 / 加载失败）。
   * 小程序这里是 skeleton-card ×4；鸿蒙没有骨架屏组件，改用 LoadingProgress
   * + 一行说明，语义等价、不额外造组件。
   */
  @Builder
  emptyBlock() {
    Column() {
      if (this.loading) {
        LoadingProgress()
          .width(26)
          .height(26)
          .color(ACCENT)
        Text('正在加载型号库…')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .margin({ top: 10 })
      } else {
        // 图标 30vp（小程序 72rpx = 36vp，按审计口径收到 30）
        Text('🛰️')
          .fontSize(30)
          .opacity(0.45)
        Text('型号库还没同步好，稍后再来看看')
          .fontSize(14)
          .fontColor(TXT_HINT)
          .textAlign(TextAlign.Center)
          .margin({ top: 12 })
        Text('重新加载')
          .fontSize(14)
          .fontColor(ACCENT)
          .padding({ left: 28, right: 28, top: 9, bottom: 9 })
          .borderRadius(30)
          .backgroundColor('#2638BDF8')
          .border({ width: 1, color: '#6638BDF8' })
          .margin({ top: 18 })
          .onClick(() => {
            this.load(true);
          })
      }
    }
    .width('100%')
    .padding({ top: 70, bottom: 40, left: 20, right: 20 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 空态②：库有了，但当前筛选/搜索没有命中 */
  @Builder
  noMatchBlock() {
    Column() {
      Text('🔍')
        .fontSize(30)
        .opacity(0.45)
      Text('没有符合条件的型号')
        .fontSize(14)
        .fontColor(TXT_HINT)
        .textAlign(TextAlign.Center)
        .margin({ top: 12 })
    }
    .width('100%')
    .padding({ top: 70, bottom: 40 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}

/**
 * 相对小程序**有意不实现**的两条（审计里点名的低严重度项）：
 *
 * 1. **hover 态**（`.rank-card-hover`）。鸿蒙手机上没有鼠标悬停，
 *    ArkUI 的 .hoverEffect 只在有指针的设备上生效，属于多余的渲染分支，跳过。
 * 2. **暗门面板**（3 秒连点 5 次标题 → 填版本号模拟审核视角）。
 *    那是微信审核专用的开关（小程序 utils/config.js 的 reviewVersions 机制），
 *    鸿蒙应用不走微信审核，没有对应概念，不实现。
 *    因此 hero 上也没有 onClick 计数逻辑。
 */
