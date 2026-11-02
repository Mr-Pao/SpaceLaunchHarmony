/**
 * view/StatsView.ets —— 「数据统计」页（历年发射量）
 *
 * 对位小程序 pages/stats/stats.vue 的观感，但结构按鸿蒙侧重排：
 *   页头 → 总览卡（最新一年大数字 + 成功率 / 累计）
 *        → 柱状图卡（近 15 年，点柱子切年）
 *        → 选中年明细卡（四格 + 成功率进度条 + 12 个月迷你柱）
 *        → 三张 Top 榜（火箭 / 发射场 / 机构，各前 5）
 *        → 轨道分布卡（选中年的 orbits 前 5，横向条）
 *
 * ── 为什么不用 Canvas 画柱状图 ──
 *   Canvas 要自己算 DPR、自己画文字、还要处理重绘时机，页面里没有第二个
 *   图表能复用这套代码，纯负担。`Row` + `layoutWeight(1)` 每根柱子等分宽度，
 *   高度直接给 vp 数值，点哪根都能用 onClick 精确命中 —— 交互还更简单。
 *
 * ── 三态为什么必须分开（原项目踩过的坑）──
 *   repo.load 在「无缓存 + 网络失败」时是 **reject**。如果在 catch 里把
 *   loading 置 false 的同时当作「已加载」，页面就永久停在空列表上，
 *   用户会以为统计数据真的没有。所以：
 *     loading && 无数据            → 加载中
 *     failed && 无数据             → 加载失败 + 重试（loaded 不置位）
 *     非 failed && 无数据           → 真的没有数据（CI 还没产出）
 *     有数据                       → 正常渲染（此时刷新失败继续用旧数据）
 *
 * ── 为什么明细的派生值全部预先算好放进 @State ──
 *   ArkTS 的 build() 里不能声明局部变量，@Builder 的参数又是按值传递。
 *   如果每次渲染都在 Builder 里现算「选中年的月份数组 / 榜单 / 峰值」，
 *   一是每次都要重新分配数组，二是 ForEach 的 key 生成器会拿到新数组。
 *   所以在 selectYear() 里一次算完，渲染层只读。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。定时器：无（不需要清理）。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import {
  StatsPayload, StYear, StRankItem,
  stNum, stFindYear, stLatestYear, stSumTotal, stSuccessRate, stMonths, stRankTop
} from '../model/Stats';
import { strOf } from '../utils/Format';

const DOMAIN: number = 0x0000;
const TAG: string = 'StatsView';

// ============ 视觉常量（工程约定） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const TEXT_HINT: string = '#6B7891';
const ACCENT: string = '#38BDF8';
const TRACK_BG: string = '#1E2637';
const OK_GREEN: string = '#34C759';
const BAD_RED: string = '#FF3B30';
const PARTIAL_AMBER: string = '#F5C33B';

/** 卡片内边距与圆角（工程约定 14 / 12） */
const CARD_PAD: number = 14;
const CARD_RADIUS: number = 12;
/** 卡片之间的竖向间距 */
const CARD_GAP: number = 10;

/** 柱状图区域高度：每根柱最高 100vp（需求给定），标签另占一行 */
const BAR_AREA_H: number = 100;
const BAR_GAP: number = 4;
const BAR_RADIUS: number = 3;

/** 12 个月迷你柱的最大高度 */
const MONTH_BAR_H: number = 36;
/** 横向条（轨道分布）高度 */
const ORBIT_BAR_H: number = 6;

/** 柱状图 / 榜单各取几条 */
const CHART_YEARS: number = 15;
const TOP_N: number = 5;

@Component
export struct StatsView {
  // ============ 数据状态 ============

  /** 全量 70 条（按 year 降序由 CI 给出，但下面排序逻辑不依赖它） */
  @State list: StYear[] = [];
  @State loading: boolean = true;
  /** 无缓存 + 网络失败。与「真的没有数据」严格分开，见文件头三态说明 */
  @State failed: boolean = false;

  /** 选中年份；0 表示还没选（首屏按最新一年自动选） */
  @State selectedYear: number = 0;
  /** 选中年是否有可用记录：为 false 时整块明细不渲染 */
  @State hasDetail: boolean = false;

  // ---- 总览 ----
  @State latestYear: number = 0;
  @State latestTotal: number = 0;
  @State latestRate: number = 0;
  /** 最新一年已决出结果的次数（成功+失败+部分）；为 0 时成功率显示「--」而不是 0.0% */
  @State latestDecided: number = 0;
  /** 全部年份 total 求和（总览卡「累计 N 次」） */
  @State totalAll: number = 0;

  // ---- 柱状图 ----
  /** 近 15 年（year 降序） */
  @State recent: StYear[] = [];
  /** 这 15 年里的最大值，柱高按它归一 */
  @State recentMax: number = 1;

  // ---- 选中年明细 ----
  @State dTotal: number = 0;
  @State dSuccess: number = 0;
  @State dFail: number = 0;
  @State dPartial: number = 0;
  @State dRate: number = 0;
  @State dMonths: number[] = [];
  @State dMonthsMax: number = 1;
  @State dRockets: StRankItem[] = [];
  @State dSites: StRankItem[] = [];
  @State dAgencies: StRankItem[] = [];
  @State dOrbits: StRankItem[] = [];
  @State dOrbitsMax: number = 1;

  /** 防重入：连续点重试不该叠请求 */
  private loadingNow: boolean = false;

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadStats(false);
  }

  // ============ 加载 ============

  /**
   * 加载统计。
   *
   * 顺序严格是「peek 同步上屏 → load 后台刷新」：
   *   peek 只查内存 + 文件，零网络、同步返回，冷启动能立刻把上次的图亮出来；
   *   load 的 onCache 再给一次（同一份数据，但携带缓存年龄），onUpdate 在
   *   后台刷新拿到新 generatedAt 时回填。
   */
  private loadStats(force: boolean): void {
    if (this.loadingNow) {
      return;
    }
    this.loadingNow = true;
    this.loading = true;
    this.failed = false;

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
        // 成功分支才清失败态；catch 里绝不清
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有数据就静默留在旧图上：后台刷新失败不该把整页变成错误页
        this.failed = this.list.length === 0;
        hilog.warn(DOMAIN, TAG, 'stats 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingNow = false;
      });
  }

  private retry(): void {
    this.loadStats(true);
  }

  // ============ 数据落地 ============

  /**
   * 把载荷铺到各个 @State。
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
    this.totalAll = stSumTotal(next);

    // 最新一年：不赌 CI 的排序（见 model/Stats.ets 的 stLatestYear 注释）
    const latest: StYear | null = stLatestYear(next);
    this.latestYear = latest !== null ? stNum(latest.year) : 0;
    this.latestTotal = latest !== null ? stNum(latest.total) : 0;
    this.latestRate = stSuccessRate(latest);
    this.latestDecided = latest !== null
      ? stNum(latest.success) + stNum(latest.fail) + stNum(latest.partial)
      : 0;

    // 近 15 年：先按 year 降序排一份副本，再切前 15
    const sorted: StYear[] = next.slice(0);
    sorted.sort((a: StYear, b: StYear) => stNum(b.year) - stNum(a.year));
    const recent: StYear[] = sorted.slice(0, CHART_YEARS);
    let mx: number = 0;
    for (let i = 0; i < recent.length; i++) {
      const t: number = stNum(recent[i].total);
      if (t > mx) {
        mx = t;
      }
    }
    this.recent = recent;
    this.recentMax = mx > 0 ? mx : 1;

    // 选中年的选择：能保留就保留（后台刷新不该把用户正在看的年份跳走），
    // 保留不了（跨年 / 数据被截断）就回落到最新一年。
    if (next.length === 0) {
      this.selectedYear = 0;
      this.hasDetail = false;
      return;
    }
    let target: number = this.selectedYear;
    if (target <= 0 || stFindYear(next, target) === null) {
      target = this.latestYear;
    }
    this.selectYear(target);
  }

  /**
   * 选中某一年并一次算完明细。
   *
   * 所有派生值都在这里落地，build() 里只读 —— 原因见文件头「为什么预先算好」。
   */
  private selectYear(year: number): void {
    if (year <= 0) {
      return;
    }
    this.selectedYear = year;

    const cur: StYear | null = stFindYear(this.list, year);
    if (cur === null) {
      this.hasDetail = false;
      this.dTotal = 0;
      this.dSuccess = 0;
      this.dFail = 0;
      this.dPartial = 0;
      this.dRate = 0;
      this.dMonths = [];
      this.dMonthsMax = 1;
      this.dRockets = [];
      this.dSites = [];
      this.dAgencies = [];
      this.dOrbits = [];
      this.dOrbitsMax = 1;
      return;
    }

    this.hasDetail = true;
    this.dTotal = stNum(cur.total);
    this.dSuccess = stNum(cur.success);
    this.dFail = stNum(cur.fail);
    this.dPartial = stNum(cur.partial);
    this.dRate = stSuccessRate(cur);

    const months: number[] = stMonths(cur);
    let mmax: number = 0;
    for (let i = 0; i < months.length; i++) {
      if (months[i] > mmax) {
        mmax = months[i];
      }
    }
    this.dMonths = months;
    this.dMonthsMax = mmax > 0 ? mmax : 1;

    this.dRockets = stRankTop(cur.rockets, TOP_N);
    this.dSites = stRankTop(cur.sites, TOP_N);
    this.dAgencies = stRankTop(cur.agencies, TOP_N);

    const orbits: StRankItem[] = stRankTop(cur.orbits, TOP_N);
    let omax: number = 1;
    if (orbits.length > 0) {
      const top: number = stNum(orbits[0].count);
      omax = top > 0 ? top : 1;
    }
    this.dOrbits = orbits;
    this.dOrbitsMax = omax;
  }

  // ============ 派生小工具 ============

  /** 成功率文本，保留一位小数；没有已决记录时给「--」而不是 0.0% */
  private rateText(rate: number, decided: number): string {
    if (decided <= 0) {
      return '--';
    }
    return rate.toFixed(1) + '%';
  }

  /** 年份后两位：2026 → "26"，2005 → "05" */
  private yy(year: number): string {
    const v: number = year % 100;
    return v < 10 ? '0' + String(v) : String(v);
  }

  /** 柱高：total / 峰值 × 100vp；为 0 时不画（留白比画一根假柱子诚实） */
  private barH(y: StYear): number {
    const t: number = stNum(y.total);
    if (t <= 0) {
      return 0;
    }
    const h: number = t / this.recentMax * BAR_AREA_H;
    return h < 3 ? 3 : h;
  }

  /** 12 个月迷你柱高度：0 次给 2vp 的底座，非 0 最低 3vp（否则 1 次和 2 次分不开） */
  private monthH(v: number): number {
    if (v <= 0) {
      return 2;
    }
    const h: number = v / this.dMonthsMax * MONTH_BAR_H;
    return h < 3 ? 3 : h;
  }

  /** 横向条宽度百分比：最低 6%，否则 1 次的小条几乎看不见 */
  private orbitPct(count: number): string {
    const pct: number = count <= 0 ? 0 : count / this.dOrbitsMax * 100;
    const shown: number = pct < 6 ? 6 : pct;
    return shown.toFixed(2) + '%';
  }

  private isPicked(year: number): boolean {
    return this.selectedYear === year;
  }

  // ============ UI：页头 ============

  @Builder
  pageHead() {
    Column() {
      Text('数据统计')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .letterSpacing(1)

      Text('历年发射量 · 成功率趋势')
        .fontSize(11)
        .fontColor(TEXT_HINT)
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10, bottom: 12 })
  }

  // ============ UI：总览卡 ============

  @Builder
  overviewCard() {
    Row() {
      Column() {
        Row() {
          Text(String(this.latestTotal))
            .fontSize(36)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_MAIN)
            .lineHeight(40)
          Text('次')
            .fontSize(12)
            .fontColor(TEXT_SUB)
            .margin({ left: 4, bottom: 4 })
        }
        .alignItems(VerticalAlign.Bottom)

        Text(String(this.latestYear) + ' 年发射总数')
          .fontSize(11)
          .fontColor(TEXT_HINT)
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column() {
        // 右侧两格：成功率 / 累计。数值统一右对齐，避免和左侧大数字抢视觉焦点
        Column() {
          Text('成功率')
            .fontSize(10)
            .fontColor(TEXT_DIM)
          Text(this.rateText(this.latestRate, this.latestDecided))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(OK_GREEN)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.End)

        Column() {
          Text('累计')
            .fontSize(10)
            .fontColor(TEXT_DIM)
          Text(String(this.totalAll) + ' 次')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ACCENT)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.End)
        .margin({ top: 8 })
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .padding(CARD_PAD)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(CARD_BG)
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: CARD_GAP })
  }

  // ============ UI：柱状图卡 ============

  @Builder
  volumeCard() {
    Column() {
      Row() {
        Text('历年发射量')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_MAIN)
          .layoutWeight(1)
        Text('近 15 年 · 点击切换')
          .fontSize(10)
          .fontColor(TEXT_DIM)
      }
      .width('100%')
      .margin({ bottom: 12 })

      Row({ space: BAR_GAP }) {
        ForEach(this.recent, (y: StYear) => {
          Column() {
            // 柱体：空 Column + 渐变填充，高度是运行期算出来的 vp
            Column()
              .width('100%')
              .height(this.barH(y))
              .borderRadius(BAR_RADIUS)
              .linearGradient({
                // angle 180 = 从上往下：顶部亮青，底部深蓝（需求给的两端色）
                angle: 180,
                colors: [['#38BDF8', 0.0], ['#1E6FA8', 1.0]]
              })
              // 选中的柱子顶上再加一道高光，靠颜色之外多一重信号（不能只靠粗细）
              .border({
                width: this.isPicked(stNum(y.year)) ? 1 : 0,
                color: '#7DD3FC'
              })

            Text(this.yy(stNum(y.year)))
              .fontSize(11)
              .fontColor(this.isPicked(stNum(y.year)) ? ACCENT : TEXT_DIM)
              .fontWeight(this.isPicked(stNum(y.year)) ? FontWeight.Bold : FontWeight.Normal)
              .margin({ top: 6 })
          }
          .layoutWeight(1)
          .height('100%')
          .justifyContent(FlexAlign.End)
          .onClick(() => {
            this.selectYear(stNum(y.year));
          })
        }, (y: StYear, index: number) => String(stNum(y.year)) + '@' + String(index))
      }
      .width('100%')
      // 柱区 100 + 标签行 ~20 + 间距，整体给足，柱子才能贴底
      .height(BAR_AREA_H + 26)
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .padding(CARD_PAD)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(CARD_BG)
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: CARD_GAP })
  }

  // ============ UI：选中年明细卡 ============ 

  @Builder
  detailCard() {
    Column() {
      Row() {
        Text(String(this.selectedYear) + ' 年明细')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_MAIN)
          .layoutWeight(1)
        Text(this.rateText(this.dRate, this.dSuccess + this.dFail + this.dPartial) + ' 成功率')
          .fontSize(11)
          .fontColor(OK_GREEN)
      }
      .width('100%')
      .margin({ bottom: 12 })

      // ---- 四格 ----
      Row() {
        this.statCell('发射总数', String(this.dTotal), TEXT_MAIN)
        this.statCell('成功', String(this.dSuccess), OK_GREEN)
        this.statCell('失败', String(this.dFail), BAD_RED)
        this.statCell('部分成功', String(this.dPartial), PARTIAL_AMBER)
      }
      .width('100%')

      // ---- 成功率进度条 ----
      Row() {
        Text('成功率')
          .fontSize(10)
          .fontColor(TEXT_DIM)
        Text(this.rateText(this.dRate, this.dSuccess + this.dFail + this.dPartial))
          .fontSize(10)
          .fontColor(OK_GREEN)
          .layoutWeight(1)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .margin({ top: 12, bottom: 5 })

      Stack({ alignContent: Alignment.Start }) {
        // 底槽先铺满，前景条盖在上面按百分比收窄
        Column()
          .width('100%')
          .height(ORBIT_BAR_H)
          .borderRadius(3)
          .backgroundColor(TRACK_BG)
        Column()
          .width(this.dRate.toFixed(1) + '%')
          .height(ORBIT_BAR_H)
          .borderRadius(3)
          .backgroundColor(OK_GREEN)
      }
      .width('100%')
      .height(ORBIT_BAR_H)

      // ---- 12 个月迷你柱 ----
      Row() {
        Text('月度分布')
          .fontSize(10)
          .fontColor(TEXT_DIM)
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 14, bottom: 8 })

      Row({ space: 3 }) {
        ForEach(this.dMonths, (v: number, index: number) => {
          Column() {
            Column()
              .width('100%')
              .height(this.monthH(v))
              .borderRadius(2)
              .backgroundColor(v > 0 ? ACCENT : TRACK_BG)
            Text(String(index + 1))
              .fontSize(9)
              .fontColor(TEXT_DIM)
              .margin({ top: 4 })
          }
          .layoutWeight(1)
          .height('100%')
          .justifyContent(FlexAlign.End)
        }, (v: number, index: number) => String(index) + ':' + String(v))
      }
      .width('100%')
      .height(MONTH_BAR_H + 18)
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .padding(CARD_PAD)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(CARD_BG)
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: CARD_GAP })
  }

  /** 明细四格里的一格。值单独一个 @Builder 参数而不是读成员：四格结构完全一样 */
  @Builder
  statCell(label: string, value: string, tone: string) {
    Column() {
      Text(value)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(tone)
      Text(label)
        .fontSize(10)
        .fontColor(TEXT_DIM)
        .margin({ top: 3 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  // ============ UI：Top 榜 ============

  /**
   * 一张 Top 榜卡。
   *
   * 行内只有「名称 + 右对齐次数」，不画进度条：三张榜并排出现时，条会变成
   * 一堆长度不同的色块，反而看不清排名，名称本身已经足够说明问题。
   * 名称为空 / 次数为 0 的行在 stRankTop 里已经滤掉，这里不再判空。
   */
  @Builder
  rankCard(title: string, rows: StRankItem[], tone: string) {
    Column() {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
        .width('100%')
        .margin({ bottom: 6 })

      ForEach(rows, (r: StRankItem, index: number) => {
        Row() {
          Text(String(index + 1))
            .fontSize(10)
            .fontColor(index === 0 ? tone : TEXT_DIM)
            .width(16)

          Text(strOf(r.name))
            .fontSize(12.5)
            .fontColor(TEXT_SUB)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(String(stNum(r.count)) + ' 次')
            .fontSize(11.5)
            .fontColor(TEXT_MAIN)
            .margin({ left: 8 })
        }
        .width('100%')
        .padding({ top: 6, bottom: 6 })
        .alignItems(VerticalAlign.Center)
      }, (r: StRankItem, index: number) => strOf(r.name) + '#' + String(index))
    }
    .width('100%')
    .padding(CARD_PAD)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(CARD_BG)
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: CARD_GAP })
  }

  // ============ UI：轨道分布 ============

  @Builder
  orbitCard() {
    Column() {
      Text('轨道分布')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
        .width('100%')
        .margin({ bottom: 8 })

      ForEach(this.dOrbits, (r: StRankItem, index: number) => {
        Row() {
          Text(strOf(r.name))
            .fontSize(11.5)
            .fontColor(TEXT_SUB)
            .width('30%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Stack({ alignContent: Alignment.Start }) {
            Column()
              .width('100%')
              .height(ORBIT_BAR_H)
              .borderRadius(3)
              .backgroundColor(TRACK_BG)
            Column()
              .width(this.orbitPct(stNum(r.count)))
              .height(ORBIT_BAR_H)
              .borderRadius(3)
              .backgroundColor(ACCENT)
          }
          .layoutWeight(1)
          .height(ORBIT_BAR_H)
          .margin({ left: 8, right: 8 })

          // 次数右对齐、定宽，避免个位数与三位数把条挤得长短不一
          Text(String(stNum(r.count)))
            .fontSize(11)
            .fontColor(TEXT_MAIN)
            .width(32)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .padding({ top: 5, bottom: 5 })
        .alignItems(VerticalAlign.Center)
      }, (r: StRankItem, index: number) => strOf(r.name) + '&' + String(index))
    }
    .width('100%')
    .padding(CARD_PAD)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(CARD_BG)
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: CARD_GAP })
  }

  // ============ UI：三态 ============

  @Builder
  loadingBlock() {
    Column() {
      Text('统计中…')
        .fontSize(12)
        .fontColor(TEXT_HINT)
    }
    .width('100%')
    .height(240)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyBlock() {
    Column() {
      Text('📊')
        .fontSize(34)
        .opacity(0.5)
      Text('统计数据还没生成')
        .fontSize(13)
        .fontColor(TEXT_SUB)
        .margin({ top: 10 })
      Text('CI 按年聚合完成后这里会自动出现')
        .fontSize(11)
        .fontColor(TEXT_DIM)
        .margin({ top: 6 })
    }
    .width('100%')
    .height(240)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  failedBlock() {
    Column() {
      Text('统计加载失败')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      Text('网络不给力，或缓存已被清理')
        .fontSize(12)
        .fontColor(TEXT_DIM)
        .margin({ top: 8 })

      Row() {
        Text('重试')
          .fontSize(12.5)
          .fontColor(ACCENT)
      }
      .padding({ left: 18, right: 18, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor('#16222F')
      .margin({ top: 16 })
      .onClick(() => {
        this.retry();
      })
    }
    .width('100%')
    .height(260)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ============ build ============

  build() {
    Scroll() {
      Column() {
        this.pageHead()

        if (this.list.length === 0) {
          // 三态严格分开（见文件头）：失败不置「已加载」，否则永久空页
          if (this.loading) {
            this.loadingBlock()
          } else if (this.failed) {
            this.failedBlock()
          } else {
            this.emptyBlock()
          }
        } else {
          this.overviewCard()
          this.volumeCard()

          if (this.hasDetail) {
            this.detailCard()
            this.rankCard('热门火箭', this.dRockets, ACCENT)
            this.rankCard('发射场', this.dSites, PARTIAL_AMBER)
            this.rankCard('机构', this.dAgencies, OK_GREEN)

            if (this.dOrbits.length > 0) {
              this.orbitCard()
            }
          }
        }
      }
      .width('100%')
      // 底部 120vp：本页在详情页栈里可能盖到悬浮胶囊之上，留足让位
      .padding({ left: 12, right: 12, bottom: 120 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .backgroundColor(BG_PRIMARY)
  }
}
