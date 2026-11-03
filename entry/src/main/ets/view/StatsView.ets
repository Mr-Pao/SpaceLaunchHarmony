/**
 * view/StatsView.ets —— 「数据统计」页（历年发射量）
 *
 * 与小程序 pages/stats/stats.vue 逐节对齐，区块顺序：
 *   页头 → 年份 + 年度航天回顾 → 年份胶囊（折叠 12 个 + 更多年份）
 *   → 年度主数字卡 → 月度分布 → 火箭 TOP10 → 发射场 TOP10 → 国家 / 地区
 *   → 机构 TOP10 → 目标轨道 → 失败复盘 → 页脚
 *
 * ── 为什么年份改了胶囊、不再用柱状图切换 ──
 *   小程序把 1957~2026 共 70 个年份做成胶囊，一次能点到的年份比「近 15 根柱子」
 *   多一个数量级。柱状图在本页只能表达发射量，而发射量已经被主数字和月度分布
 *   讲清楚，再加一块属于重复信息，故整块删掉。
 *
 * ── 为什么派生值全部预先算好放进 State ──
 *   build() 里不能声明局部变量，Builder 按值传参又不建立响应式依赖 ——
 *   若在 Builder 里现算数组或百分比，异步赋值后界面不刷新（本工程踩过两次）。
 *   所以 selectYear() 里一次算完，Builder 一律无参，内部直接读 this.xxx。
 *
 * ── 三态 ──
 *   小程序只有「统计中」和空态，没有独立失败态：拉取失败在用户看来与「还没生成」
 *   无法区分，多一个错误页只会更吓人。这里照抄这个取舍，但空态保留「重新加载」
 *   按钮并走 force 重拉 —— 失败时仍留一条出路。
 *
 * 本文件不使用 console.*，日志一律 hilog；无定时器，故不必在 aboutToDisappear 清理。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import {
  StatsPayload, StYear, StRankItem, StFailure, StCountryRow,
  stNum, stFindYear, stLatestYear, stMonths, stSuccessRate,
  stRankTop, stCountries, stFailures
} from '../model/Stats';
import { strOf, formatShort, parseTime } from '../utils/Format';
import { Nav } from '../routes/Nav';
import { LaunchNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'StatsView';

// ============ 视觉常量（小程序 rpx 除以 2 得到的 vp） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#E2E8F0';
const TEXT_HINT: string = '#6B7891';
const TEXT_MUTED: string = '#8A97A8';
const TEXT_FAINT: string = '#4A5568';
const TEXT_FOOTER: string = '#3D4A5C';
const ACCENT: string = '#38BDF8';
const TRACK_BG: string = '#0DFFFFFF';
const OK_GREEN: string = '#34C759';
const BAD_RED: string = '#FF3B30';
const PARTIAL_AMBER: string = '#F5C33B';
const IDX_TOP_BG: string = '#29F5C33B';
const TAG_RED_BG: string = '#24FF3B30';
const TAG_AMBER_BG: string = '#24F5C33B';
const SEL_BG: string = '#2438BDF8';
const SEL_BORDER: string = '#7338BDF8';
const CARD_BORDER: string = '#0DFFFFFF';
const CHIP_BORDER: string = '#0FFFFFFF';
const HERO_BORDER: string = '#1F38BDF8';

/** 卡片：20rpx 圆角 / 30rpx 28rpx 内边距 / 24rpx 外边距 */
const CARD_RADIUS: number = 10;
const CARD_PAD_H: number = 14;
const CARD_PAD_V: number = 15;
const CARD_GAP: number = 12;
/** hero 卡单独一档：24rpx 圆角 / 40rpx 32rpx 内边距 */
const HERO_RADIUS: number = 12;
const HERO_PAD_H: number = 16;
const HERO_PAD_V: number = 20;

/** 柱区高度 200rpx = 100vp；标签 20rpx = 10vp */
const BAR_AREA_H: number = 100;
/** 榜单最多几行（CI 侧已按 TOP 10 预聚合） */
const MAX_ROWS: number = 10;
/** 国家聚合最多几条 */
const COUNTRY_ROWS: number = 8;
/** 年份胶囊折叠时只露一行（chip 高约 26vp + 5vp 间距，留 30 兜住行高误差） */
const CHIP_ROW_H: number = 30;
/** 折叠态默认露出的年份个数 */
const CHIP_HEAD: number = 12;

// ============ 页面内数据结构（Stx 前缀，避免与 model 层撞名） ============

/** 月度柱：等价于小程序 months 计算属性 */
class StxMonth {
  label: string = '';
  count: number = 0;
  /** 相对峰值的百分比，0 表示当月无发射 */
  pct: number = 0;

  constructor(label: string, count: number, pct: number) {
    this.label = label;
    this.count = count;
    this.pct = pct;
  }
}

/** 榜单一行：名称 + 次数 + 进度条百分比 */
class StxBar {
  name: string = '';
  count: number = 0;
  pct: number = 0;

  constructor(name: string, count: number, pct: number) {
    this.name = name;
    this.count = count;
    this.pct = pct;
  }
}

/** 失败复盘一行（字段已在 model/Stats.ets 的 StFailure 里实测确认） */
class StxFail {
  id: string = '';
  net: string = '';
  dateText: string = '';
  statusText: string = '';
  isPartial: boolean = false;
  name: string = '';
  meta: string = '';

  constructor(id: string, net: string, dateText: string, statusText: string,
    isPartial: boolean, name: string, meta: string) {
    this.id = id;
    this.net = net;
    this.dateText = dateText;
    this.statusText = statusText;
    this.isPartial = isPartial;
    this.name = name;
    this.meta = meta;
  }
}

@Component
export struct StatsView {
  // ============ 数据状态 ============

  /** 全量 70 条 */
  @State list: StYear[] = [];
  @State loading: boolean = true;
  /** 下拉刷新中；Refresh 的双向绑定变量必须进 State */
  @State refreshing: boolean = false;

  // ---- 年份入口 ----
  /** 可选年份，降序 */
  @State years: number[] = [];
  /** 当前实际渲染的胶囊（折叠 12 个 / 展开全部） */
  @State shown: number[] = [];
  @State yearExpanded: boolean = false;
  /** 选中年；初值取当前年，数据里没有时回落到最新一年（同小程序） */
  @State selectedYear: number = new Date().getFullYear();
  /** 最早一年：归档边界，页脚要额外说明 */
  @State earliestYear: number = 0;

  // ---- 年度主数字（mini hero-card）----
  @State hTotal: number = 0;
  @State hSuccess: number = 0;
  /** 失败 + 部分成功，小程序把两者合并成一个数 */
  @State hFail: number = 0;
  /** 成功率已格式化成文本：「—」/「99.2%」 */
  @State hRate: string = '—';
  @State hOrbital: number = 0;
  @State hSub: number = 0;

  // ---- 月度 ----
  @State months: StxMonth[] = [];

  // ---- 四张榜 ----
  @State rockets: StxBar[] = [];
  @State sites: StxBar[] = [];
  @State countries: StxBar[] = [];
  @State agencies: StxBar[] = [];
  @State orbits: StxBar[] = [];

  // ---- 失败复盘 ----
  @State fails: StxFail[] = [];

  // ---- 页脚 ----
  @State sourceCount: number = 0;
  @State footerLine: string = '';

  /** 防重入：连续下拉或点重试不该叠请求 */
  private loadingNow: boolean = false;

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadStats(false);
  }

  // ============ 加载 ============

  /**
   * 加载统计。
   *
   * 顺序是「peek 同步上屏 → load 后台刷新」：peek 只查内存与文件，零网络、
   * 同步返回，冷启动能立刻把上次的图亮出来；onUpdate 在后台刷新拿到新
   * generatedAt 时回填。
   */
  private loadStats(force: boolean): void {
    if (this.loadingNow) {
      // 已经在拉了，把下拉手势的转圈先收掉，别让它等到超时
      this.refreshing = false;
      return;
    }
    this.loadingNow = true;
    this.loading = true;

    const cached: StatsPayload | null = repo.peek<StatsPayload>('stats');
    if (cached !== null) {
      this.applyPayload(cached);
      if (this.list.length > 0) {
        this.loading = false;
      }
    }

    const opts: LoadOptions<StatsPayload> = {
      force: force,
      onCache: (data: StatsPayload) => {
        this.applyPayload(data);
      },
      onUpdate: (data: StatsPayload) => {
        this.applyPayload(data);
      }
    };

    repo.load<StatsPayload>('stats', opts)
      .then((data: StatsPayload) => {
        this.applyPayload(data);
        this.loading = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有数据就静默留在旧图上；没有数据则落到空态，由按钮重新拉
        hilog.warn(DOMAIN, TAG, 'stats 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingNow = false;
        this.refreshing = false;
      });
  }

  private retry(): void {
    this.loadStats(true);
  }

  // ============ 数据落地 ============

  /**
   * 把载荷铺到各个 State。
   *
   * 「中途变空不清屏」：一次半截数据（上游刚切分片）不该把已经画好的图清掉，
   * 所以新数组为空而旧数组非空时直接返回。
   */
  private applyPayload(data: StatsPayload): void {
    const raw: StYear[] | undefined = data.list;
    const next: StYear[] = raw !== undefined && raw !== null && Array.isArray(raw) ? raw : [];
    if (next.length === 0 && this.list.length > 0) {
      return;
    }
    this.list = next;

    this.sourceCount = data.count !== undefined ? stNum(data.count) : 0;
    this.footerLine = this.buildFooter(data.generatedAt);

    if (next.length === 0) {
      this.years = [];
      this.shown = [];
      this.selectedYear = 0;
      return;
    }

    // 年份降序（契约说 CI 已降序，但排序很便宜，不赌上游）
    const ys: number[] = [];
    for (let i = 0; i < next.length; i++) {
      ys.push(stNum(next[i].year));
    }
    ys.sort((a: number, b: number) => b - a);
    this.years = ys;
    this.earliestYear = ys[ys.length - 1];

    // 选中年：能保留就保留（后台刷新不该把用户正在看的年份跳走），
    // 保留不了（跨年 / 数据被截断）就回落到最新一年。
    let target: number = this.selectedYear;
    if (target <= 0 || stFindYear(next, target) === null) {
      const latest: StYear | null = stLatestYear(next);
      target = latest !== null ? stNum(latest.year) : ys[0];
    }
    this.selectYear(target);
  }

  /** 选中某一年，一次算完全部派生值（Builder 只读，原因见文件头） */
  private selectYear(year: number): void {
    if (year <= 0) {
      return;
    }
    this.selectedYear = year;
    this.refreshShown();

    const cur: StYear | null = stFindYear(this.list, year);
    if (cur === null) {
      this.hTotal = 0;
      this.hSuccess = 0;
      this.hFail = 0;
      this.hRate = '—';
      this.hOrbital = 0;
      this.hSub = 0;
      this.months = [];
      this.rockets = [];
      this.sites = [];
      this.countries = [];
      this.agencies = [];
      this.orbits = [];
      this.fails = [];
      return;
    }

    const success: number = stNum(cur.success);
    const fail: number = stNum(cur.fail);
    const partial: number = stNum(cur.partial);
    const decided: number = success + fail + partial;

    this.hTotal = stNum(cur.total);
    this.hSuccess = success;
    this.hFail = fail + partial;
    this.hRate = this.rateText(stSuccessRate(cur), decided);
    this.hOrbital = stNum(cur.orbital);
    this.hSub = stNum(cur.sub);

    // ---- 月度 ----
    const rawMonths: number[] = stMonths(cur);
    let mmax: number = 0;
    for (let i = 0; i < rawMonths.length; i++) {
      if (rawMonths[i] > mmax) {
        mmax = rawMonths[i];
      }
    }
    const mm: StxMonth[] = [];
    for (let i = 0; i < rawMonths.length; i++) {
      const c: number = rawMonths[i];
      // 最低留 8%，否则 1 次和 0 次在视觉上分不开（小程序同口径）
      const pct: number = c > 0 ? Math.max(8, Math.round(c / mmax * 100)) : 0;
      mm.push(new StxMonth(String(i + 1), c, pct));
    }
    this.months = mm;

    // ---- 四张榜 ----
    this.rockets = this.toBars(cur.rockets, MAX_ROWS);
    this.sites = this.toBars(cur.sites, MAX_ROWS);
    this.agencies = this.toBars(cur.agencies, MAX_ROWS);
    this.orbits = this.toBars(cur.orbits, MAX_ROWS);
    this.countries = this.toCountryBars(cur.agencies);

    // ---- 失败复盘 ----
    this.fails = this.toFails(cur);
  }

  /** 折叠态只露 12 个；选中的年份被收起来就追加在尾部，保证高亮可见 */
  private refreshShown(): void {
    const all: number[] = this.years;
    if (this.yearExpanded || all.length <= CHIP_HEAD) {
      this.shown = all.slice(0);
      return;
    }
    const head: number[] = all.slice(0, CHIP_HEAD);
    if (head.indexOf(this.selectedYear) === -1 && this.selectedYear > 0) {
      head.push(this.selectedYear);
    }
    this.shown = head;
  }

  // ============ 派生小工具 ============

  /** 成功率文本：没有已决记录给「—」；整数百分比去掉 .0（小程序会 strip） */
  private rateText(rate: number, decided: number): string {
    if (decided <= 0) {
      return '—';
    }
    const s: string = rate.toFixed(1);
    const body: string = s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    return body + '%';
  }

  /** 榜单数组 → 带百分比的渲染行；最低 6%，否则 1 次的小条几乎看不见 */
  private toBars(rows: StRankItem[] | undefined, limit: number): StxBar[] {
    const picked: StRankItem[] = stRankTop(rows, limit);
    const out: StxBar[] = [];
    if (picked.length === 0) {
      return out;
    }
    const max: number = stNum(picked[0].count) > 0 ? stNum(picked[0].count) : 1;
    for (let i = 0; i < picked.length; i++) {
      const c: number = stNum(picked[i].count);
      out.push(new StxBar(strOf(picked[i].name), c, Math.max(6, Math.round(c / max * 100))));
    }
    return out;
  }

  /** 国家聚合（机构榜按关键词归国，最多 8 条） */
  private toCountryBars(agencies: StRankItem[] | undefined): StxBar[] {
    const agg: StCountryRow[] = stCountries(agencies, COUNTRY_ROWS);
    const out: StxBar[] = [];
    if (agg.length === 0) {
      return out;
    }
    const max: number = agg[0].count > 0 ? agg[0].count : 1;
    for (let i = 0; i < agg.length; i++) {
      const c: number = agg[i].count;
      out.push(new StxBar(agg[i].name, c, Math.max(6, Math.round(c / max * 100))));
    }
    return out;
  }

  /** 失败 / 部分成功 → 渲染行；id 为空的行不可点（没有详情可跳） */
  private toFails(cur: StYear): StxFail[] {
    const rows: StFailure[] = stFailures(cur);
    const out: StxFail[] = [];
    for (let i = 0; i < rows.length; i++) {
      const f: StFailure = rows[i];
      const isPartial: boolean = strOf(f.status) === 'Partial';
      const rocket: string = strOf(f.rocket);
      const site: string = strOf(f.site);
      let meta: string = rocket;
      if (site.length > 0) {
        meta = rocket.length > 0 ? rocket + ' · ' + site : site;
      }
      const nm: string = strOf(f.name).length > 0 ? strOf(f.name) : '未知任务';
      out.push(new StxFail(strOf(f.id), strOf(f.net), formatShort(strOf(f.net)),
        isPartial ? '部分成功' : '发射失败', isPartial, nm, meta));
    }
    return out;
  }

  /** 数据新鲜度：刚刚 / N 分钟前 / N 小时前 / N 天前（同小程序 freshnessText） */
  private freshnessText(iso: string): string {
    const t: number = parseTime(iso);
    if (t <= 0) {
      return '';
    }
    const mins: number = Math.floor((Date.now() - t) / 60000);
    if (mins < 1) {
      return '刚刚更新';
    }
    if (mins < 60) {
      return String(mins) + ' 分钟前更新';
    }
    const hours: number = Math.floor(mins / 60);
    if (hours < 24) {
      return String(hours) + ' 小时前更新';
    }
    return String(Math.floor(hours / 24)) + ' 天前更新';
  }

  private buildFooter(generatedAt: string): string {
    const fresh: string = this.freshnessText(generatedAt);
    const head: string = '数据源：最新快照 + 历史归档，共 ' + String(this.sourceCount) + ' 条';
    return fresh.length > 0 ? head + ' · ' + fresh : head;
  }

  // ============ 交互 ============

  private pickYear(y: number): void {
    if (y === this.selectedYear) {
      return;
    }
    this.selectYear(y);
  }

  private toggleMore(): void {
    this.yearExpanded = !this.yearExpanded;
    this.refreshShown();
  }

  private openFailure(f: StxFail): void {
    if (f.id.length === 0) {
      return;
    }
    // net 一起带上：失败任务多半已滑出 previous 快照，详情页在归档里查找时
    // 可直接跳到对应分片（findById 的 netHint），与小程序 goDetail 同口径
    Nav.pushLaunch(new LaunchNavParam(f.id, f.net, f.name));
  }

  private back(): void {
    Nav.pop();
  }

  // ============ UI：页头 ============

  /**
   * 自绘顶部栏。NavDestination 侧 hideTitleBar(true)，返回箭头与标题都自己画：
   * 小程序 nav-title 是 36rpx(18vp) 而非全局的 46rpx，字号要能单独定。
   */
  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹')
          .fontSize(27)
          // 小程序 nav-arrow 是 font-weight 300、line-height 1
          .fontWeight(FontWeight.Lighter)
          .fontColor(TEXT_MAIN)
          .lineHeight(27)
          .margin({ top: -3 })
      }
      .width(30)
      .height(44)
      .justifyContent(FlexAlign.Center)
      // 小程序 nav-back 有 -10rpx 的负外边距，让箭头贴在文字块左侧
      .margin({ left: -5 })
      .onClick(() => {
        this.back();
      })

      Text('数据统计')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .letterSpacing(1)
        .margin({ left: 2 })
    }
    .width('100%')
    // 44vp：与小程序 nav-row 等高；左右 12vp 让箭头与下方的年份胶囊同一条竖线
    .height(44)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
  }

  // ============ UI：年份 + 年度航天回顾 ============

  @Builder
  headBlock() {
    Column() {
      Text(String(this.selectedYear))
        .fontSize(23)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .letterSpacing(1)

      Text('年度航天回顾')
        .fontSize(12)
        .fontColor(TEXT_HINT)
        .letterSpacing(1)
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 20, bottom: 12 })
  }

  // ============ UI：年份胶囊 ============

  /**
   * 70 个年份的入口。
   *
   * 折叠靠 maxHeight + clip 裁成一行，而不是另写一套「只渲染 12 个」的分支：
   * 两个分支会让展开 / 收起时整块重建，胶囊位置跳动。shown 本身也已限到 12 个，
   * 裁切只是兜住「12 个换行之后多出来的第二行」。
   */
  @Builder
  yearPicker() {
    Column() {
      Column() {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.shown, (y: number) => {
            Text(String(y))
              .fontSize(12)
              .fontColor(y === this.selectedYear ? ACCENT : TEXT_MUTED)
              .fontWeight(y === this.selectedYear ? FontWeight.Bold : FontWeight.Normal)
              .padding({ left: 12, right: 12, top: 4, bottom: 4 })
              .margin({ right: 7, bottom: 5 })
              .borderRadius(15)
              .backgroundColor(y === this.selectedYear ? SEL_BG : CARD_BG)
              .border({
                width: 0.5,
                color: y === this.selectedYear ? SEL_BORDER : CHIP_BORDER
              })
              .onClick(() => {
                this.pickYear(y);
              })
          }, (y: number) => 'y' + String(y))
        }
        .width('100%')
      }
      .width('100%')
      // 折叠态裁成一行；展开态给一个足够大的上限，等于不限制
      .constraintSize({ maxHeight: this.yearExpanded ? 2000 : CHIP_ROW_H })
      .clip(true)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    // 小程序 .year-picker 的 padding 是 4rpx 24rpx 22rpx；左右 24rpx 已由
    // 页面级 12vp 承担，这里只补上 2 / 11 的上下留白
    .padding({ top: 2, bottom: 11 })
  }

  /** 折叠开关。小程序在可选年份 > 6 时才出现 */
  @Builder
  yearMore() {
    Row() {
      Text(this.yearExpanded ? '收起年份 ▴' : '更多年份 ▾')
        .fontSize(12)
        .fontColor('#5D6A7D')
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 3, bottom: 3 })
    .margin({ bottom: 9 })
    .onClick(() => {
      this.toggleMore();
    })
  }

  // ============ UI：年度主数字卡 ============

  /**
   * hero 卡：主数字 + 次发射 + 成功 / 失败 / 成功率 + 轨道 / 亚轨道拆分。
   *
   * 拆分那行与小程序一样，亚轨道为 0 时整段不画（2026 年 sub=6，早年份没有）。
   */
  @Builder
  heroCard() {
    Column() {
      Row() {
        Text(String(this.hTotal))
          .fontSize(44)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_MAIN)
          .lineHeight(44)
        Text('次发射')
          .fontSize(13)
          .fontColor(TEXT_HINT)
          .margin({ left: 6, bottom: 6 })
      }
      .alignItems(VerticalAlign.Bottom)

      Flex({ wrap: FlexWrap.Wrap }) {
        Text('成功 ' + String(this.hSuccess))
          .fontSize(13)
          .fontColor(OK_GREEN)

        if (this.hFail > 0) {
          Text('·')
            .fontSize(11)
            .fontColor(TEXT_FOOTER)
            .margin({ left: 6, right: 6 })
          Text('失败 ' + String(this.hFail))
            .fontSize(13)
            .fontColor(BAD_RED)
        }

        Text('·')
          .fontSize(11)
          .fontColor(TEXT_FOOTER)
          .margin({ left: 6, right: 6 })
        Text('成功率 ' + this.hRate)
          .fontSize(13)
          .fontColor(ACCENT)
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Text('轨道发射 ' + String(this.hOrbital))
          .fontSize(11.5)
          .fontColor(TEXT_FAINT)
        if (this.hSub > 0) {
          Text(' · 亚轨道 ' + String(this.hSub))
            .fontSize(11.5)
            .fontColor(TEXT_FAINT)
        }
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: HERO_PAD_H, right: HERO_PAD_H, top: HERO_PAD_V, bottom: HERO_PAD_V })
    .borderRadius(HERO_RADIUS)
    .border({ width: 0.5, color: HERO_BORDER })
    .linearGradient({
      // css 135deg = 左上到右下（ArkUI 与 css 角度同向，90 = to right）
      angle: 135,
      colors: [['#17263D', 0.0], ['#141A26', 1.0]]
    })
  }

  // ============ UI：月度分布 ============

  /**
   * 月度柱：柱区固定 100vp，柱子按百分比高度贴底。
   *
   * 0 次的月份保留 2vp 的底座：完全不留会让人以为那一列没渲染（小程序靠
   * min-height 4rpx 达到同样效果）。
   */
  @Builder
  monthCard() {
    Column() {
      Text('月度分布')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(ACCENT)
        .margin({ bottom: 13 })

      Row() {
        ForEach(this.months, (m: StxMonth) => {
          Column() {
            if (m.count > 0) {
              Text(String(m.count))
                .fontSize(9)
                .fontColor(TEXT_MUTED)
                .margin({ bottom: 3 })
            }
            Column() {
              Column()
                .width('60%')
                // 统一给百分数字符串：ArkTS 的 Length 不接受 string|number 联合，
                // 0 次的月份给 1%（=100vp 里的 1vp），再靠 minHeight 兜到 2vp
                .height((m.pct > 0 ? m.pct : 1).toFixed(0) + '%')
                .constraintSize({ minHeight: 2 })
                .borderRadius({ topLeft: 3, topRight: 3, bottomLeft: 1, bottomRight: 1 })
                .linearGradient({
                  // css to top：底部深蓝 → 顶部亮青
                  angle: 0,
                  colors: [['#1E5F86', 0.0], ['#38BDF8', 1.0]]
                })
            }
            .width('100%')
            .height(BAR_AREA_H)
            .justifyContent(FlexAlign.End)
            .alignItems(HorizontalAlign.Center)

            Text(m.label)
              .fontSize(10)
              .fontColor(TEXT_FAINT)
              .margin({ top: 5 })
          }
          .layoutWeight(1)
        }, (m: StxMonth, index: number) => 'm' + String(index) + '_' + String(m.count))
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .backgroundColor(CARD_BG)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：排行卡（火箭 / 发射场 / 机构） ============

  /**
   * 一张排行卡。三张榜结构相同但颜色不同，且都必须是无参 Builder
   * （见文件头），所以各写一份，不做参数化。
   */
  @Builder
  rocketCard() {
    Column() {
      Text('火箭型号 TOP 10')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(ACCENT)
        .margin({ bottom: 13 })

      ForEach(this.rockets, (b: StxBar, index: number) => {
        Column() {
          Row() {
            Text(String(index + 1))
              .fontSize(11)
              .fontColor(index === 0 ? PARTIAL_AMBER : TEXT_HINT)
              .width(18)
              .height(18)
              .lineHeight(18)
              .textAlign(TextAlign.Center)
              .borderRadius(4)
              .backgroundColor(index === 0 ? IDX_TOP_BG : CARD_BORDER)
              .margin({ right: 7 })

            Text(b.name)
              .fontSize(13)
              .fontColor(TEXT_SUB)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text(String(b.count))
              .fontSize(13)
              .fontColor(ACCENT)
              .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 5 })

          Row() {
            Stack({ alignContent: Alignment.Start }) {
              Column()
                .width('100%')
                .height(4)
                .borderRadius(2)
                .backgroundColor(TRACK_BG)
              Column()
                .width(b.pct.toFixed(0) + '%')
                .height(4)
                .borderRadius(2)
                .linearGradient({
                  angle: 90,
                  colors: [['#1E5F86', 0.0], ['#38BDF8', 1.0]]
                })
            }
            .layoutWeight(1)
            .height(4)
          }
          .width('100%')
          // 进度条与名称左对齐（序号 18 + 间距 7 = 25vp），行本身仍占满整宽
          .padding({ left: 25 })
        }
        .width('100%')
        .margin({ bottom: index === this.rockets.length - 1 ? 0 : 12 })
      }, (b: StxBar, index: number) => 'r' + String(index) + '_' + b.name)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .backgroundColor(CARD_BG)
    .margin({ top: CARD_GAP })
  }

  @Builder
  siteCard() {
    Column() {
      Text('发射场 TOP 10')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(ACCENT)
        .margin({ bottom: 13 })

      ForEach(this.sites, (b: StxBar, index: number) => {
        Column() {
          Row() {
            Text(String(index + 1))
              .fontSize(11)
              .fontColor(index === 0 ? PARTIAL_AMBER : TEXT_HINT)
              .width(18)
              .height(18)
              .lineHeight(18)
              .textAlign(TextAlign.Center)
              .borderRadius(4)
              .backgroundColor(index === 0 ? IDX_TOP_BG : CARD_BORDER)
              .margin({ right: 7 })

            Text(b.name)
              .fontSize(13)
              .fontColor(TEXT_SUB)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text(String(b.count))
              .fontSize(13)
              .fontColor(ACCENT)
              .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 5 })

          Row() {
            Stack({ alignContent: Alignment.Start }) {
              Column()
                .width('100%')
                .height(4)
                .borderRadius(2)
                .backgroundColor(TRACK_BG)
              Column()
                .width(b.pct.toFixed(0) + '%')
                .height(4)
                .borderRadius(2)
                .linearGradient({
                  // 琥珀色：与小程序的 fill-amber 一致
                  angle: 90,
                  colors: [['#7A5C14', 0.0], ['#F5C33B', 1.0]]
                })
            }
            .layoutWeight(1)
            .height(4)
          }
          .width('100%')
          .padding({ left: 25 })
        }
        .width('100%')
        .margin({ bottom: index === this.sites.length - 1 ? 0 : 12 })
      }, (b: StxBar, index: number) => 's' + String(index) + '_' + b.name)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .backgroundColor(CARD_BG)
    .margin({ top: CARD_GAP })
  }

  @Builder
  agencyCard() {
    Column() {
      Text('机构排行')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(ACCENT)
        .margin({ bottom: 13 })

      ForEach(this.agencies, (b: StxBar, index: number) => {
        Column() {
          Row() {
            Text(String(index + 1))
              .fontSize(11)
              .fontColor(index === 0 ? PARTIAL_AMBER : TEXT_HINT)
              .width(18)
              .height(18)
              .lineHeight(18)
              .textAlign(TextAlign.Center)
              .borderRadius(4)
              .backgroundColor(index === 0 ? IDX_TOP_BG : CARD_BORDER)
              .margin({ right: 7 })

            Text(b.name)
              .fontSize(13)
              .fontColor(TEXT_SUB)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text(String(b.count))
              .fontSize(13)
              .fontColor(ACCENT)
              .margin({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ bottom: 5 })

          Row() {
            Stack({ alignContent: Alignment.Start }) {
              Column()
                .width('100%')
                .height(4)
                .borderRadius(2)
                .backgroundColor(TRACK_BG)
              Column()
                .width(b.pct.toFixed(0) + '%')
                .height(4)
                .borderRadius(2)
                .linearGradient({
                  angle: 90,
                  colors: [['#1E5F86', 0.0], ['#38BDF8', 1.0]]
                })
            }
            .layoutWeight(1)
            .height(4)
          }
          .width('100%')
          // 进度条与名称左对齐（序号 18 + 间距 7 = 25vp），行本身仍占满整宽
          .padding({ left: 25 })
        }
        .width('100%')
        .margin({ bottom: index === this.agencies.length - 1 ? 0 : 12 })
      }, (b: StxBar, index: number) => 'a' + String(index) + '_' + b.name)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .backgroundColor(CARD_BG)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：国家 / 地区 ============

  /**
   * 国家卡：机构榜按关键词归国后聚合（聚合逻辑在 model/Stats.ets）。
   * 名称定宽 60vp、次数定宽 30vp —— 条长随占比变化，两侧不定宽会左右抖。
   */
  @Builder
  countryCard() {
    Column() {
      Text('国家 / 地区')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(ACCENT)
        .margin({ bottom: 13 })

      ForEach(this.countries, (b: StxBar, index: number) => {
        Row() {
          Text(b.name)
            .fontSize(12)
            .fontColor('#CBD5E0')
            .width(60)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Stack({ alignContent: Alignment.Start }) {
            Column()
              .width('100%')
              .height(5)
              .borderRadius(2.5)
              .backgroundColor(TRACK_BG)
            Column()
              .width(b.pct.toFixed(0) + '%')
              .height(5)
              .borderRadius(2.5)
              .linearGradient({
                // 紫色渐变：国家与其他榜在颜色上再分一层
                angle: 90,
                colors: [['#4A2B5E', 0.0], ['#A06BD8', 1.0]]
              })
          }
          .layoutWeight(1)
          .height(5)
          .margin({ left: 8, right: 8 })

          Text(String(b.count))
            .fontSize(12)
            .fontColor(TEXT_MUTED)
            .width(30)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: index === this.countries.length - 1 ? 0 : 10 })
      }, (b: StxBar, index: number) => 'c' + String(index) + '_' + b.name)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .backgroundColor(CARD_BG)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：目标轨道 ============

  @Builder
  orbitCard() {
    Column() {
      Text('目标轨道')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(ACCENT)
        .margin({ bottom: 13 })

      ForEach(this.orbits, (b: StxBar, index: number) => {
        Row() {
          Text(b.name)
            .fontSize(12)
            .fontColor('#CBD5E0')
            .width(60)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Stack({ alignContent: Alignment.Start }) {
            Column()
              .width('100%')
              .height(5)
              .borderRadius(2.5)
              .backgroundColor(TRACK_BG)
            Column()
              .width(b.pct.toFixed(0) + '%')
              .height(5)
              .borderRadius(2.5)
              .linearGradient({
                angle: 90,
                colors: [['#2F6F4F', 0.0], ['#34C759', 1.0]]
              })
          }
          .layoutWeight(1)
          .height(5)
          .margin({ left: 8, right: 8 })

          Text(String(b.count))
            .fontSize(12)
            .fontColor(TEXT_MUTED)
            .width(30)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: index === this.orbits.length - 1 ? 0 : 10 })
      }, (b: StxBar, index: number) => 'o' + String(index) + '_' + b.name)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .backgroundColor(CARD_BG)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：失败 / 部分成功复盘 ============

  /**
   * 失败复盘。整行可点，跳发射详情。
   *
   * name / rocket / site 一律保留英文原名：小程序同样直出，且这三个字段
   * 的专名表覆盖不全，半截翻译比不翻更糟。
   */
  @Builder
  failCard() {
    Column() {
      Text('失败 / 部分成功复盘')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(ACCENT)
        .margin({ bottom: 13 })

      ForEach(this.fails, (f: StxFail, index: number) => {
        Column() {
          if (index > 0) {
            Divider()
              .strokeWidth(0.5)
              .color(CARD_BORDER)
              .margin({ bottom: 10 })
          }

          Row() {
            Text(f.dateText)
              .fontSize(11)
              .fontColor(TEXT_HINT)
            Blank()
            Text(f.statusText)
              .fontSize(10)
              .fontColor(f.isPartial ? PARTIAL_AMBER : BAD_RED)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(3)
              .backgroundColor(f.isPartial ? TAG_AMBER_BG : TAG_RED_BG)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          Text(f.name)
            .fontSize(13.5)
            .fontColor(TEXT_SUB)
            .lineHeight(20)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 4 })
            .textAlign(TextAlign.Start)

          if (f.meta.length > 0) {
            Text(f.meta)
              .fontSize(11)
              .fontColor(TEXT_FAINT)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 3 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ top: index === 0 ? 0 : 10, bottom: 10 })
        .onClick(() => {
          this.openFailure(f);
        })
      }, (f: StxFail, index: number) => 'f' + String(index) + '_' + f.id)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .backgroundColor(CARD_BG)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：页脚 ============

  @Builder
  footerHint() {
    Column() {
      Text(this.footerLine)
        .fontSize(11)
        .fontColor(TEXT_FOOTER)
        .lineHeight(18)
        .textAlign(TextAlign.Center)

      if (this.selectedYear === this.earliestYear && this.earliestYear > 0) {
        Text('该年度只覆盖到归档边界，非全年完整统计')
          .fontSize(11)
          .fontColor(TEXT_FOOTER)
          .lineHeight(18)
          .textAlign(TextAlign.Center)
          .margin({ top: 3 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 15 })
  }

  // ============ UI：三态 ============

  @Builder
  loadingBlock() {
    Column() {
      Text('统计中...')
        .fontSize(14)
        .fontColor(TEXT_HINT)
    }
    .width('100%')
    .padding({ top: 70, bottom: 70 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 空态。拉取失败也走这里 —— 见文件头三态说明：小程序没有独立失败页，
   * 多一个错误态只会让「网络抖动」看起来像「功能坏了」。
   */
  @Builder
  emptyBlock() {
    Column() {
      Text('📊')
        .fontSize(36)
        .margin({ bottom: 12 })
      Text('统计数据还没生成，稍后再来看看')
        .fontSize(14)
        .fontColor(TEXT_HINT)
        .textAlign(TextAlign.Center)

      Row() {
        Text('重新加载')
          .fontSize(14)
          .fontColor(ACCENT)
      }
      .padding({ left: 28, right: 28, top: 9, bottom: 9 })
      .margin({ top: 18 })
      .borderRadius(30)
      .backgroundColor('#2638BDF8')
      .border({ width: 0.5, color: '#6638BDF8' })
      .onClick(() => {
        this.retry();
      })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 70, bottom: 70 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ============ build ============

  build() {
    // 页头钉在外面：小程序 nav-row 就在 page 顶层、不随 scroll-view 滚动，
    // 跟着内容滚走会让「返回」在长列表里找不到
    Column() {
      this.topBar()

      Refresh({ refreshing: $$this.refreshing }) {
        Scroll() {
          Column() {
            if (this.list.length === 0) {
              if (this.loading) {
                this.loadingBlock()
              } else {
                this.emptyBlock()
              }
            } else {
              this.headBlock()
              this.yearPicker()
              if (this.years.length > 6) {
                this.yearMore()
              }

              this.heroCard()
              this.monthCard()

              if (this.rockets.length > 0) {
                this.rocketCard()
              }
              if (this.sites.length > 0) {
                this.siteCard()
              }
              if (this.countries.length > 0) {
                this.countryCard()
              }
              if (this.agencies.length > 0) {
                this.agencyCard()
              }
              if (this.orbits.length > 0) {
                this.orbitCard()
              }
              if (this.fails.length > 0) {
                this.failCard()
              }

              this.footerHint()
            }
          }
          .width('100%')
          // 左右 12vp = 小程序内容区 24rpx 的留白；bottom 32 因为本页是
          // NavDestination 二级页，底部没有悬浮胶囊需要让位
          .padding({ left: 12, right: 12, bottom: 32 })
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .layoutWeight(1)
      .onRefreshing(() => {
        // 下拉刷新：对位小程序 onPullDownRefresh → getData(true)
        this.refreshing = true;
        this.loadStats(true);
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    .alignItems(HorizontalAlign.Start)
  }
}
