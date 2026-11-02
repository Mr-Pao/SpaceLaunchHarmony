/**
 * view/RocketView.ets —— 「全球火箭实力榜」
 *
 * 对位小程序：pages/rockets/rockets.vue（1277 行）。
 * 结构（自上而下，整页一个 List 滚动）：
 *   页头 kicker + 标题 + 「在役」chip → 大数字（在役型号数）→ 三格统计卡
 *   → 搜索框 → 「排序方式」+ 四个榜单切换 → 七个地区筛选 → 当前榜单说明行
 *   → 排名卡 × N → 底部提示
 *
 * ── 为什么整页用一个 List 而不是 Column + Scroll ──
 *   头部（页头 + 大数字 + 统计卡 + 搜索 + 两排筛选）差不多占据一屏，
 *   如果把它钉在 List 外面，卡片区就只剩半屏，榜单会显得很挤。
 *   小程序是整页滚动的，这里用「头部当 List 的第 0 项」复刻同一手感，
 *   顺带还能白拿 List 的节点回收与 onReachEnd。
 *
 * ── 为什么全量不进 @State ──
 *   在役 150+ 型（原始库 500+ 条）每条视图模型带 10 个字符串字段。
 *   塞进 @State 意味着代理包一层 + 每次刷新全量脏检查。
 *   所以：全量在私有成员 `all`，去重后的候选池在 `pool`，排序结果在 `filtered`
 *   （三个都是普通成员，改了不重绘）；@State 只放**当前真正要画的这 14 条**
 *   （`shown`）和几个驱动文案的标量。
 *
 * ── 为什么筛选/排序全在本地 ──
 *   launchers 是一份静态 JSON，load 一次就在内存里；派生字段（score / 搜索串 /
 *   地区码）在 rtBuildLib() 里一次算完，这里只做「筛 + 排 + 切片」。
 *   打字就发请求既没必要也会闪。
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
import { Nav } from '../routes/Nav';
import { RocketNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'RocketView';

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TXT_MAIN: string = '#E8EEF8';
const TXT_SUB: string = '#A7B4C7';
const TXT_DIM: string = '#55617A';
const TXT_HINT: string = '#6B7891';
const ACCENT: string = '#38BDF8';
const ACCENT_SOFT: string = '#1B2A3C';
const PAGE_PAD: number = 12;
/** 底部悬浮胶囊占位 */
const BOTTOM_PAD: number = 92;
const CARD_GAP: number = 8;

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
  /** 在役型号数（大数字） */
  @State total: number = 0;
  @State loading: boolean = true;
  @State failed: boolean = false;
  /** 真正要画的那一段，最多 listNum 条 */
  @State shown: RtRocket[] = [];

  // 头部三格（地区切换要跟着变，所以是 @State 字符串而不是每次 build 里现算）
  @State topLeoName: string = '—';
  @State topLeoText: string = '—';
  @State topLaunchName: string = '—';
  @State topLaunchText: string = '—';
  @State reusableText: string = '0 型';

  // ============ 全量数据（普通成员，改完必须显式 recompute） ============

  /** 原始库全量视图模型（含退役型号） */
  private all: RtRocket[] = [];
  /** 在役 + 按型号名去重后的候选池，所有榜单都从这里来 */
  private pool: RtRocket[] = [];
  /** 当前「地区 + 搜索 + 排序」后的完整结果，只用于切片 */
  private filtered: RtRocket[] = [];

  private scroller: Scroller = new Scroller();
  private sortScroller: Scroller = new Scroller();
  private regionScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.load();
  }

  // ============ 加载 ============

  private load(): void {
    this.loading = true;
    this.failed = false;

    const opts: LoadOptions<RtLauncherList> = {
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
        hilog.warn(DOMAIN, TAG, 'launchers 加载失败: %{public}s', e.message);
        if (this.all.length === 0) {
          this.failed = true;
        }
      })
      .then(() => {
        this.loading = false;
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
    this.total = this.pool.length;
    this.failed = false;
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
   * 头部三格。
   * 只看「地区」不看搜索词：搜索是找具体型号的手段，
   * 让统计跟着搜索词跳变会让人读不懂这一屏在讲什么。
   */
  private refreshStats(): void {
    let bestLeo: RtRocket | null = null;
    let bestLaunch: RtRocket | null = null;
    let reusable: number = 0;

    for (let i = 0; i < this.pool.length; i++) {
      const r: RtRocket = this.pool[i];
      if (this.activeRegion !== 'all' && r.region !== this.activeRegion) {
        continue;
      }
      if (r.reusable) {
        reusable++;
      }
      if (bestLeo === null || r.leo > bestLeo.leo) {
        bestLeo = r;
      }
      if (bestLaunch === null || r.launches > bestLaunch.launches) {
        bestLaunch = r;
      }
    }

    this.topLeoName = bestLeo !== null ? bestLeo.zh : '—';
    this.topLeoText = bestLeo !== null ? bestLeo.leoText : '—';
    this.topLaunchName = bestLaunch !== null ? bestLaunch.zh : '—';
    this.topLaunchText =
      bestLaunch !== null ? bestLaunch.launches.toString() + ' 次发射' : '—';
    this.reusableText = reusable.toString() + ' 型';
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
    List({ space: CARD_GAP, scroller: this.scroller }) {
      // 头部当第 0 项，整页一起滚（见文件头注释）
      ListItem() {
        this.pageHead()
      }

      if (this.shown.length === 0) {
        ListItem() {
          this.emptyState()
        }
      } else {
        ForEach(this.shown, (item: RtRocket, index: number) => {
          ListItem() {
            Column() {
              RocketCard({
                item: item,
                rankNo: index + 1,
                onOpen: (r: RtRocket) => {
                  this.openRocket(r);
                }
              })
            }
            .width('100%')
            .padding({ left: PAGE_PAD, right: PAGE_PAD })
          }
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
    // ★ 92vp：避开底部悬浮胶囊（胶囊是浮层，内容会铺到屏幕底）
    .padding({ bottom: BOTTOM_PAD })
    .backgroundColor(BG_PRIMARY)
    .onReachEnd(() => {
      this.loadMore();
    })
  }

  @Builder
  pageHead() {
    Column() {
      Row() {
        Text('SPACEDAILY / LAUNCH INDEX')
          .fontSize(10)
          .fontColor(TXT_HINT)
          .letterSpacing(1.5)
          .maxLines(1)
          .layoutWeight(1)

        Text('在役')
          .fontSize(10)
          .fontColor(ACCENT)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(4)
          .border({ width: 1, color: '#6638BDF8' })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('全球火箭实力榜')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(0.4)
        .margin({ top: 8 })

      Text('基于运力、可靠性、发射活跃度')
        .fontSize(11)
        .fontColor(TXT_HINT)
        .margin({ top: 4 })

      // 大数字区：数字与量词底部对齐，读起来是「153 型号火箭」一句话
      Row() {
        Text(this.total.toString())
          .fontSize(48)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .margin({ top: 10 })
        Text('型号火箭')
          .fontSize(11)
          .fontColor(TXT_HINT)
          .margin({ left: 6, bottom: 10 })
      }
      .alignItems(VerticalAlign.Bottom)

      this.statGrid()
      this.searchBar()

      Text('排序方式')
        .fontSize(11)
        .fontColor(TXT_HINT)
        .margin({ top: 14, bottom: 6 })
        .width('100%')
        .textAlign(TextAlign.Start)

      this.sortRow()
      this.regionRow()
      this.boardLine()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 12, bottom: 2 })
  }

  /** 三格统计卡：运力之最 / 最活跃 / 可复用型号数 */
  @Builder
  statGrid() {
    Row() {
      this.statCell('运力之最', this.topLeoName, this.topLeoText)
      this.statCell('最活跃', this.topLaunchName, this.topLaunchText)
      this.statCell('可复用', '在役型号', this.reusableText)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .backgroundColor(CARD_BG)
    .borderRadius(12)
    .margin({ top: 12 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  statCell(caption: string, name: string, value: string) {
    Column() {
      Text(caption)
        .fontSize(9)
        .fontColor(TXT_DIM)
        .maxLines(1)
      Text(name)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(TXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 3 })
      Text(value)
        .fontSize(10)
        .fontColor(ACCENT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 6 })
  }

  @Builder
  searchBar() {
    Row() {
      Text('🔍')
        .fontSize(12)
        .opacity(0.5)
        .margin({ right: 6 })

      TextInput({ text: this.keyword, placeholder: '搜索中文名、型号、制造商' })
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
    .margin({ top: 12 })
    .backgroundColor(CARD_BG)
    .borderRadius(10)
    .border({ width: 1, color: '#0DFFFFFF' })
    .alignItems(VerticalAlign.Center)
  }

  /** 四个榜单。横向 Scroll 而非 Tabs：条数少，Tabs 的滑动手感在这里是干扰 */
  @Builder
  sortRow() {
    Scroll(this.sortScroller) {
      Row() {
        ForEach(SORTS, (opt: RtSortOption) => {
          Text(opt.label)
            .fontSize(12)
            .fontWeight(this.activeSort === opt.value ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.activeSort === opt.value ? BG_PRIMARY : TXT_SUB)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.activeSort === opt.value ? ACCENT : CARD_BG)
            .borderRadius(8)
            .margin({ right: 8 })
            .onClick(() => {
              this.switchSort(opt.value);
            })
        }, (opt: RtSortOption) => opt.value)
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: 2 })
  }

  /** 七个地区。选中态用实心小胶囊，与榜单切换区分开（方块的层级更高） */
  @Builder
  regionRow() {
    Scroll(this.regionScroller) {
      Row() {
        ForEach(REGIONS, (opt: RtRegionOption) => {
          Text(opt.label)
            .fontSize(11)
            .fontColor(this.activeRegion === opt.value ? BG_PRIMARY : TXT_SUB)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(this.activeRegion === opt.value ? ACCENT : '#00000000')
            .borderRadius(11)
            .border({
              width: 1,
              color: this.activeRegion === opt.value ? ACCENT : '#1DFFFFFF'
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

  /** 当前榜单说明行：左「综合榜」+ 权重说明，右结果数 */
  @Builder
  boardLine() {
    Row() {
      Column() {
        Text(this.currentSort().label)
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(TXT_MAIN)
          .maxLines(1)
        Text(this.currentSort().desc)
          .fontSize(9)
          .fontColor(TXT_DIM)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.hitTotal.toString() + ' 个结果')
        .fontSize(10)
        .fontColor(TXT_DIM)
        .margin({ left: 8 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 12, bottom: 8 })
  }

  /** 底部状态：还有就提示继续滑，没有了就明确「已全部显示」 */
  @Builder
  footer() {
    Text(this.hasMore()
      ? `继续下滑 · 已显示 ${this.shown.length}/${this.hitTotal}`
      : `已显示全部 ${this.hitTotal} 个型号`)
      .fontSize(10)
      .fontColor(TXT_DIM)
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 10, bottom: 4 })
  }

  /** 空态三分支：加载中 / 加载失败 / 搜不到，文案不能混（混了用户不知道该干嘛） */
  @Builder
  emptyState() {
    Column() {
      if (this.loading) {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(ACCENT)
        Text('正在加载型号库…')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .margin({ top: 10 })
      } else if (this.failed) {
        Text('🚀')
          .fontSize(30)
          .opacity(0.3)
        Text('型号库加载失败')
          .fontSize(13)
          .fontColor(TXT_SUB)
          .margin({ top: 10 })
        Text('检查网络后重试')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .margin({ top: 6 })
        Text('重新加载')
          .fontSize(12)
          .fontColor(ACCENT)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor(ACCENT_SOFT)
          .margin({ top: 14 })
          .onClick(() => {
            this.load();
          })
      } else {
        Text('🔍')
          .fontSize(30)
          .opacity(0.3)
        Text('没有匹配的型号')
          .fontSize(13)
          .fontColor(TXT_SUB)
          .margin({ top: 10 })
        Text('换个关键词，或把地区切回「全球」')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .height(260)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
  }
}
