/**
 * view/LaunchView.ets —— 「发射」tab
 *
 * 对位小程序 pages/index/index.vue（967 行）。那一页实际包含：
 *   日历条 + 筛选（机构/年份/状态）+ 分段（待发射/已发射）+ 统计行 + 分页列表 + 触底加载
 * 本文件先做**任务书要求的四件必做项**：
 *   ① 待发射 / 已发射 分段切换   ② 统计行
 *   ③ 列表卡片（components/LaunchCard.ets）  ④ 触底加载 upcomingMore
 * 日历条与筛选面板留在下一阶段（需要新的交互组件与筛选状态机，不适合塞进本次改动）。
 *
 * ── 结构（自上而下）──
 *   页头「发射」19vp Bold + 11vp 灰副标题（与 TodayView.dateRow 同档）
 *   分段控件（.feed-seg 对位：底 #141A26 / 圆角 16 / 选中 rgba(56,189,248,0.16) + #38BDF8）
 *   统计行（.stat 对位：#8A97A8 13vp 主文 + #55617A 12vp 副文）
 *   可滚动 List（ForEach + LaunchCard，底部一个 footer 项）
 *
 * ── 相对小程序的有意差异（逐条写清，方便复核）──
 *   1. **不铺星空**。任务书明确「只有今日页铺星空」，发射页用纯 #0A0E17 底。
 *      列表里全是 150vp 大图，再叠一层星点会糊成噪点。
 *   2. **用 List 而不是 Scroll + Column**。Scroll 不回收、几百张卡全量构建；
 *      List 只实例化可视区，这是本项目 AGENTS.md 的硬约定。
 *   3. **列表头不跟随滚动**（页头/分段/统计固定在 List 之上）。小程序那套是
 *      整页滚，但鸿蒙这里把分段控件钉住更好用 —— 翻到第 40 条还能直接切「已发射」，
 *      不用先滚回顶部。信息层级没变，只是把控件从滚动流里抬了出来。
 *   4. **只做一段 more**。upcomingMore 是一个静态文件，不是游标分页，
 *      所以加载成功一次即 moreDone，不做「无限滚动」的假象。
 *   5. **不做筛选**（机构/年份/状态），故小程序里 `hasFilter ? '筛选出 N 条'` 那一支
 *      在这里恒不成立，副文改成「已载入 x / 总数 + 数据更新时间」。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { LaunchSummary, UpcomingPayload, PreviousPayload, UpcomingMorePayload } from '../model/Launch';
// LaunchStatus / LaunchMission 只为给局部变量补显式类型 —— ArkTS 严格模式下
// `const x = obj.prop` 的属性访问推断在可选链上容易收窄成 undefined 联合，
// 显式标注比事后排查便宜
import { LaunchStatus, LaunchMission } from '../model/Common';
import { LaunchCard } from '../components/LaunchCard';
import { LaunchCalendar } from '../components/LaunchCalendar';
import { Nav } from '../routes/Nav';
import { LaunchNavParam } from '../routes/NavParam';
import { strOf, parseTime, formatGeneratedAt } from '../utils/Format';

const DOMAIN: number = 0x0000;
const TAG: string = 'LaunchView';

/** 页面底色（与 Index.ets 窗口底色同值，避免首帧色差） */
const BG_PRIMARY: string = '#0A0E17';
/** 卡片色 */
const CARD_BG: string = '#141A26';
/** 页面左右内边距 */
const PAGE_PAD: number = 12;

/**
 * 底部内边距：悬浮胶囊让位。
 *
 * 胶囊 58 + margin 20 = 78，再加它上方渐变遮罩的渐入高度，92 会压掉最后一行
 * （TodayView 2026-11-02 截图确认过），统一用 120。
 */
const BOTTOM_PAD: number = 120;

/** 分段枚举。用 number 常量而不是 enum：ArkTS 的 enum 在模板里比较时容易踩类型收窄 */
const TAB_UPCOMING: number = 0;
const TAB_PREVIOUS: number = 1;

/** 视图模式：排期列表 / 日历。与 activeTab 正交，日历只画待发射 */
const MODE_LIST: number = 0;
const MODE_CALENDAR: number = 1;

/**
 * 「已结束」状态白名单（对位 utils/format.js:979-988 的 FINAL_STATUS）。
 *
 * upcomingMore 里混着「排期已过但状态还没更新」的条目，这些仍然算待发射；
 * 只有状态明确终结的才该被滤掉 —— 否则会把「推迟发射」的任务从列表里删掉。
 */
const FINAL_STATUS: string[] = ['Success', 'Failure', 'Deployed', 'Partial'];

/**
 * 秒级倒计时的启用窗口：72 小时。
 *
 * 列表里同时可能挂着几十张卡，每张一个 setInterval 会拖住主线程
 * （utils/Format.ets:161-163 记过这个教训）。只有临近发射的那几条值得每秒跳，
 * 其余的用 relativeTime 文字（「13 天后」），观感差别不大、开销差一个数量级。
 */
const LIVE_WINDOW_MS: number = 72 * 3600 * 1000;

/**
 * 骨架屏占位序号（够铺满一屏即可，多了浪费）。
 * 写成常量数组而不是在 build 里现场 `[0,1,2]`：ForEach 的数据源要求稳定引用，
 * 每次 build 新建数组会让 ArkUI 判定数据源变化、白白重建全部骨架节点。
 */
const SKELETON_SLOTS: number[] = [0, 1, 2];

@Component
export struct LaunchView {
  // ============ 状态 ============

  /** 当前分段：TAB_UPCOMING / TAB_PREVIOUS */
  @State activeTab: number = TAB_UPCOMING;

  /** 待发射列表（首屏 + upcomingMore 追加） */
  @State upcoming: LaunchSummary[] = [];
  /** 已发射列表（只有首屏，历史不做增量） */
  @State previous: LaunchSummary[] = [];

  /** 首屏是否还在等数据。只在「列表为空」时用来决定露骨架还是露空态 */
  @State loading: boolean = true;

  /** 待发射全量条数（payload.count，473）；served 只给 100，靠它算进度 */
  @State upcomingCount: number = 0;

  /** 数据生成时间（两种分段共用一份展示，谁后到用谁） */
  @State generatedAt: string = '';

  /** upcomingMore 是否已经没得加载了（加载过一次 / 回来是空） */
  @State moreDone: boolean = false;

  /**
   * 触底加载锁。
   * 既是防重复请求的锁，也驱动 footer 那行文案，所以挂 @State 而不是普通成员。
   */
  @State loadingMore: boolean = false;

  /**
   * 视图模式：MODE_LIST（排期） / MODE_CALENDAR（日历）。
   * 与 activeTab（待发射/已发射）正交 —— 日历只画待发射，
   * 但分段控件要保留，否则从日历切回来时用户会丢失上下文。
   */
  @State viewMode: number = MODE_LIST;

  /** 日历里点中的日期（空串 = 未选），仅用于高亮和「当日列表」标题 */
  @State pickedDate: string = '';
  /** 日历里点中那天对应的发射，点空白日期时清空 */
  @State pickedLaunches: LaunchSummary[] = [];

  // ============ 私有成员（不参与渲染） ============

  private scroller: Scroller = new Scroller();
  /** 待发射是否已经有一轮在飞，防切换来切换去叠请求 */
  private loadingUpcoming: boolean = false;
  /** 已发射同上 */
  private loadingPrevious: boolean = false;
  /** 已追加过的 id，防止 upcomingMore 与首屏重叠时出现重复卡片 */
  private seenIds: Set<string> = new Set<string>();

  // ============ 生命周期 ============

  aboutToAppear(): void {
    // 默认落在「待发射」，与小程序首页一致
    this.ensureUpcoming(false);
  }

  // ============ 加载 ============

  /**
   * 待发射：首屏。
   *
   * 同时挂 onCache 和 onUpdate：
   *   onCache  —— 命中原生缓存时立刻上屏，切 tab 回来是零等待；
   *   onUpdate —— 缓存过期、后台静默刷新拿到新数据时回填，页面停在原地看着列表自己变新。
   * 两条路径与 `.then` 的回调都走 applyUpcoming，保证过滤口径只有一份。
   */
  private ensureUpcoming(force: boolean): void {
    if (this.loadingUpcoming) {
      return;
    }
    this.loadingUpcoming = true;
    this.loading = true;

    const opts: LoadOptions<UpcomingPayload> = {
      force: force,
      onCache: (data: UpcomingPayload) => {
        this.applyUpcoming(data);
      },
      onUpdate: (data: UpcomingPayload) => {
        this.applyUpcoming(data);
      }
    };
    repo.load<UpcomingPayload>('upcoming', opts)
      .then((data: UpcomingPayload) => {
        this.applyUpcoming(data);
      })
      .catch((e: BusinessError) => {
        // 有缓存时 repo 不会 reject；走到这里说明首次冷启动且断网，
        // 列表保持空 → build 里自然落到空态，不会白屏
        hilog.warn(DOMAIN, TAG, 'upcoming 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingUpcoming = false;
        this.loading = false;
      });
  }

  /** 已发射：首屏。历史数据一小时一更，onUpdate 同样接上 */
  private ensurePrevious(force: boolean): void {
    if (this.loadingPrevious) {
      return;
    }
    this.loadingPrevious = true;
    this.loading = true;

    const opts: LoadOptions<PreviousPayload> = {
      force: force,
      onCache: (data: PreviousPayload) => {
        this.applyPrevious(data);
      },
      onUpdate: (data: PreviousPayload) => {
        this.applyPrevious(data);
      }
    };
    repo.load<PreviousPayload>('previous', opts)
      .then((data: PreviousPayload) => {
        this.applyPrevious(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'previous 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingPrevious = false;
        this.loading = false;
      });
  }

  /**
   * 待发射落地：清空陈旧列表并重建 seenIds。
   *
   * 这里是**整体替换**而不是增量合并 —— 首屏与后台刷新都可能返回不同的一批，
   * 合并会让已经取消的任务永远留在列表里。
   */
  private applyUpcoming(data: UpcomingPayload): void {
    const list: LaunchSummary[] = data.list !== undefined ? data.list : [];
    this.upcoming = list;
    this.seenIds.clear();
    for (let i = 0; i < list.length; i++) {
      this.seenIds.add(this.keyOf(list[i]));
    }
    const total: number = data.count !== undefined ? data.count : list.length;
    this.upcomingCount = total;
    this.stampOf(data.generatedAt);
    // 首屏条数已经够全量（served >= count）就没必要再挂 more；
    // 反之说明还有 upcomingMore 可翻 —— 两次判断都要写，否则后台刷新把
    // 已追加的 373 条换回 100 条后，moreDone 还停在 true，列表永远补不回来
    this.moreDone = list.length >= total;
  }

  private applyPrevious(data: PreviousPayload): void {
    const list: LaunchSummary[] = data.list !== undefined ? data.list : [];
    this.previous = list;
    this.stampOf(data.generatedAt);
  }

  /** 只在新时间非空时才覆盖，避免某一路没带 generatedAt 把已有时间冲掉 */
  private stampOf(value: string | undefined): void {
    const v: string = strOf(value);
    if (v.length > 0) {
      this.generatedAt = v;
    }
  }

  /**
   * 触底加载：upcomingMore。
   *
   * 三道闸：不是待发射段、已经在飞、已经加载完 —— 任一命中直接返回。
   * 失败只 warn，**绝不清空已有列表**（弱网下把 100 条清成 0 条是最糟的体验）。
   */
  private loadMore(): void {
    if (this.activeTab !== TAB_UPCOMING) {
      return;
    }
    if (this.loadingMore || this.moreDone) {
      return;
    }
    this.loadingMore = true;

    const opts: LoadOptions<UpcomingMorePayload> = {};
    repo.load<UpcomingMorePayload>('upcomingMore', opts)
      .then((data: UpcomingMorePayload) => {
        this.appendMore(data);
      })
      .catch((e: BusinessError) => {
        // 不改 moreDone：这次失败下次滚到底还能再试
        hilog.warn(DOMAIN, TAG, 'upcomingMore 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingMore = false;
      });
  }

  /**
   * 追加一页。
   *
   * 两个过滤不能省：
   *   ① isStillUpcoming —— 这份文件是「首屏之后的那 373 条」的静态快照，
   *      里面已经发射完的条目会随着时间越积越多，直接追加会在待发射列表尾部
   *      冒出一堆「3 天前发射成功」的卡；
   *   ② seenIds 去重 —— 数据侧排期变动时首屏和 more 可能短暂重叠。
   */
  private appendMore(data: UpcomingMorePayload): void {
    const raw: LaunchSummary[] = data.list !== undefined ? data.list : [];
    const kept: LaunchSummary[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: LaunchSummary = raw[i];
      const key: string = this.keyOf(item);
      if (this.seenIds.has(key)) {
        continue;
      }
      if (!this.isStillUpcoming(item)) {
        continue;
      }
      this.seenIds.add(key);
      kept.push(item);
    }

    if (kept.length > 0) {
      // 整体替换才能触发 @State 数组的重绘
      this.upcoming = this.upcoming.concat(kept);
    }
    const total: number = data.count !== undefined ? data.count : this.upcomingCount;
    if (total > this.upcomingCount) {
      this.upcomingCount = total;
    }
    // 一个静态文件只翻一页；即使过滤后一条不剩也算「到底了」
    this.moreDone = true;
  }

  /** 卡片身份：id 优先，缺 id 的脏数据退回 net + 名字，避免 key 撞成空串 */
  private keyOf(item: LaunchSummary): string {
    const id: string = strOf(item.id);
    if (id.length > 0) {
      return id;
    }
    return strOf(item.net) + '|' + strOf(item.name);
  }

  /**
   * 是否仍然算「待发射」（对位 utils/format.js:979-988）。
   *
   *   net 解析不出来 → 保留（时间待定也是待发射）
   *   net 在未来     → 保留
   *   net 已过去     → 只有状态明确终结才剔掉
   */
  private isStillUpcoming(item: LaunchSummary): boolean {
    const at: number = parseTime(strOf(item.net));
    if (at <= 0) {
      return true;
    }
    if (at > Date.now()) {
      return true;
    }
    const st: LaunchStatus | undefined = item.status;
    const abbrev: string = (st !== undefined && st !== null) ? strOf(st.abbrev) : '';
    for (let i = 0; i < FINAL_STATUS.length; i++) {
      if (abbrev === FINAL_STATUS[i]) {
        return false;
      }
    }
    return true;
  }

  // ============ 交互 ============

  private switchTab(tab: number): void {
    if (this.activeTab === tab) {
      return;
    }
    this.activeTab = tab;
    // 切段回顶：另一段的第一条应该从屏幕顶端开始，而不是沿用上一段的滚动位置。
    // 只有目标段已有数据时 List 才存在；空段落的 Scroller 还没绑上节点，
    // 这时调 scrollEdge 拿不到目标，直接跳过
    if (this.currentList().length > 0) {
      this.scroller.scrollEdge(Edge.Top);
    }

    if (tab === TAB_UPCOMING) {
      this.ensureUpcoming(false);
    } else {
      this.ensurePrevious(false);
    }
  }

  private openLaunch(item: LaunchSummary): void {
    const id: string = strOf(item.id);
    if (id.length === 0) {
      hilog.debug(DOMAIN, TAG, '缺 id 无法跳详情 net=%{public}s', strOf(item.net));
      return;
    }
    Nav.pushLaunch(new LaunchNavParam(id, strOf(item.net), this.titleOf(item)));
  }

  /** 任务名口径：mission.nameZh || mission.name，兜底 item.name（与 Format.missionLabelOf 一致） */
  private titleOf(item: LaunchSummary): string {
    const mission: LaunchMission | undefined = item.mission;
    if (mission !== undefined && mission !== null) {
      const zh: string = strOf(mission.nameZh);
      if (zh.length > 0) {
        return zh;
      }
      const en: string = strOf(mission.name);
      if (en.length > 0) {
        return en;
      }
    }
    return strOf(item.name);
  }

  // ============ 派生值 ============

  /** 当前段要渲染的列表。返回引用而不是拷贝，ForEach 靠它做 diff */
  private currentList(): LaunchSummary[] {
    return this.activeTab === TAB_UPCOMING ? this.upcoming : this.previous;
  }

  /**
   * 日历要用的全集：待发射 + 已发射。
   *
   * 两段各自维护自己的数组，日历必须合起来看，否则只能翻未来、翻不到历史。
   * 已发射在上（历史），待发射在下 —— 拼接顺序不重要，日历内部按 net 的日期串分组。
   * 同一 id 可能两边都有（发射后从 upcoming 挪到 previous 的过渡期），用 Set 去掉。
   */
  private calendarItems(): LaunchSummary[] {
    const merged: LaunchSummary[] = [];
    const seen: Set<string> = new Set<string>();
    let i: number = 0;
    while (i < this.previous.length) {
      const item: LaunchSummary = this.previous[i];
      const key: string = this.keyOf(item);
      if (!seen.has(key)) {
        seen.add(key);
        merged.push(item);
      }
      i = i + 1;
    }
    let j: number = 0;
    while (j < this.upcoming.length) {
      const item: LaunchSummary = this.upcoming[j];
      const key: string = this.keyOf(item);
      if (!seen.has(key)) {
        seen.add(key);
        merged.push(item);
      }
      j = j + 1;
    }
    return merged;
  }

  /** 这一条该不该跑秒级倒计时（见 LIVE_WINDOW_MS 的说明） */
  private isLive(item: LaunchSummary): boolean {
    const at: number = parseTime(strOf(item.net));
    if (at <= 0) {
      return false;
    }
    const delta: number = at - Date.now();
    return delta > 0 && delta <= LIVE_WINDOW_MS;
  }

  /** 统计行主文（对位 .stat-main：待发射「共 N 次发射」/ 已发射「已发射 N 次」） */
  private statMain(): string {
    if (this.activeTab === TAB_UPCOMING) {
      const total: number = this.upcomingCount > 0 ? this.upcomingCount : this.upcoming.length;
      return '共 ' + total + ' 次发射';
    }
    return '已发射 ' + this.previous.length + ' 次';
  }

  /** 统计行副文（对位 .stat-sub；没有筛选功能，改成载入进度 + 数据时间） */
  private statSub(): string {
    const parts: string[] = [];
    if (this.activeTab === TAB_UPCOMING) {
      if (this.upcomingCount > 0) {
        parts.push('已载入 ' + this.upcoming.length + ' / ' + this.upcomingCount);
      } else {
        parts.push('已载入 ' + this.upcoming.length + ' 条');
      }
    } else {
      parts.push('最近 ' + this.previous.length + ' 条');
    }
    const updated: string = formatGeneratedAt(this.generatedAt);
    if (updated.length > 0) {
      parts.push('更新于 ' + updated);
    }
    return parts.join(' · ');
  }

  // ============ UI ============

  /** 页头：19vp Bold 白 + 11vp 灰副标题（与 TodayView.dateRow 同档，只是标题换成固定词） */
  @Builder
  header() {
    Column() {
      Text('发射')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(1)

      Text(this.loading && this.currentList().length === 0
        ? '正在加载发射数据…'
        : '全部发射任务 · 点击卡片查看详情')
        .fontSize(11)
        .fontColor('#6B7891')
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 12, bottom: 12 })
  }

  /**
   * 双分段栏：左边「待发射/已发射」，右边「排期/日历」。
   *
   * 对位小程序 .mode-bar（一个 Row 里并排两组 seg）。两边都用同款胶囊分段，
   * 左边撑满剩余宽度、右边按内容定宽 —— 微信里也是这个比例。
   */
  @Builder
  modeBar() {
    Row({ space: 8 }) {
      Row() {
        this.segOption('待发射', TAB_UPCOMING)
        this.segOption('已发射', TAB_PREVIOUS)
      }
      .layoutWeight(1)
      .padding(3)
      .backgroundColor(CARD_BG)
      .borderRadius(16)
      .border({ width: 1, color: '#0DFFFFFF' })

      Row() {
        this.modeOption('排期', MODE_LIST)
        this.modeOption('日历', MODE_CALENDAR)
      }
      .padding(3)
      .backgroundColor(CARD_BG)
      .borderRadius(16)
      .border({ width: 1, color: '#0DFFFFFF' })
    }
    .width('100%')
  }

  /**
   * 视图模式切换项。
   *
   * 切到日历要顺手把 upcoming/previous 都拉起来：日历横跨未来与历史，
   * 只加载待发射的话，往前翻月份会一片空白（用户会以为是数据缺失）。
   */
  @Builder
  modeOption(label: string, mode: number) {
    Text(label)
      .fontSize(12.5)
      .fontWeight(this.viewMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.viewMode === mode ? '#38BDF8' : '#6B7891')
      .textAlign(TextAlign.Center)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(13)
      .backgroundColor(this.viewMode === mode ? '#2938BDF8' : '#00000000')
      .onClick(() => {
        this.viewMode = mode;
        if (mode === MODE_CALENDAR) {
          this.ensureUpcoming(false);
          this.ensurePrevious(false);
        }
      })
  }

  /** 分段控件外壳：底 #141A26 + 圆角 16 + 极淡描边（对位 .feed-seg） */
  @Builder
  segmented() {
    Row() {
      this.segOption('待发射', TAB_UPCOMING)
      this.segOption('已发射', TAB_PREVIOUS)
    }
    .width('100%')
    .padding(3)
    .backgroundColor(CARD_BG)
    .borderRadius(16)
    .border({ width: 1, color: '#0DFFFFFF' })
  }

  /**
   * 单个分段。
   * 选中态 = 天蓝文字 + rgba(56,189,248,0.16) 底色（0x29 ≈ 16%），
   * 与小程序 .feed-opt.on 完全同口径，只是没有 CSS 的过渡动画。
   */
  @Builder
  segOption(label: string, tab: number) {
    Text(label)
      .fontSize(12.5)
      .fontWeight(this.activeTab === tab ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.activeTab === tab ? '#38BDF8' : '#6B7891')
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: 7, bottom: 7 })
      .borderRadius(13)
      .backgroundColor(this.activeTab === tab ? '#2938BDF8' : '#00000000')
      .onClick(() => {
        this.switchTab(tab);
      })
  }

  /** 统计行：主轴两端对齐，数字在左、更新状态在右（对位 .stat） */
  @Builder
  statRow() {
    Row() {
      Text(this.statMain())
        .fontSize(13)
        .fontColor('#8A97A8')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Text(this.statSub())
        .fontSize(12)
        .fontColor('#55617A')
        .maxLines(1)
        .margin({ left: 8 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({ top: 10, bottom: 10 })
  }

  // ---- 三套占位：骨架 / 空态 / 列表 footer ----

  /** 单张骨架卡：形状按 LaunchCard 的头图 150 + 两行文字搭，避免落屏时跳动 */
  @Builder
  skeletonCard() {
    Column() {
      Row()
        .width('100%')
        .height(150)
        .backgroundColor('#1A2231')
      Column() {
        Row()
          .width('72%')
          .height(13)
          .borderRadius(4)
          .backgroundColor('#1A2231')
        Row()
          .width('46%')
          .height(11)
          .borderRadius(4)
          .backgroundColor('#161D2A')
          .margin({ top: 8 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 12, right: 12, top: 12, bottom: 14 })
    }
    .width('100%')
    .backgroundColor(CARD_BG)
    .borderRadius(12)
    .clip(true)
  }

  /**
   * 日历模式下的「选中日标题」。
   *
   * dateStr 是 YYYY-MM-DD（LaunchCalendar 内部按本地时区拼的），这里只做显示格式化，
   * 不重算日期 —— 两个地方各自算一次容易出现跨时区差一天的经典问题。
   */
  @Builder
  pickedDayHeader() {
    Row() {
      Text(this.pickedDate)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .layoutWeight(1)

      Text(this.pickedLaunches.length > 0 ? this.pickedLaunches.length + ' 次发射' : '无发射')
        .fontSize(11)
        .fontColor('#55617A')
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 18, bottom: 4 })
  }

  /** 选中日确实没发射。理论上 onPick 只对有点的日子回调，这里是防御 */
  @Builder
  pickedDayEmpty() {
    Column() {
      Text('这一天没有发射任务')
        .fontSize(12)
        .fontColor('#55617A')
    }
    .width('100%')
    .padding({ top: 20, bottom: 20 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 还没点任何日子时的引导文案（对位小程序「点有黄点的日期」那行小字） */
  @Builder
  pickedDayHint() {
    Column() {
      Text('点有黄点的日期，看当天的发射任务')
        .fontSize(11)
        .fontColor('#55617A')
    }
    .width('100%')
    .padding({ top: 18, bottom: 24 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 骨架列表：只在「列表为空 + 正在加载」时出现 */
  @Builder
  skeletonList() {
    // 用 Column 的 space 而不是在每张卡后面塞间隔节点：
    // 间隔用 Blank 会抢剩余空间，用空 Row 又多一层无意义节点
    Column({ space: 10 }) {
      ForEach(SKELETON_SLOTS, (i: number) => {
        this.skeletonCard()
      }, (i: number) => 'sk' + i)
    }
    .width('100%')
    .padding({ top: 2 })
  }

  /** 空态：图标 + 一句话 + 提示。断网冷启动 / 过滤后为空都会落到这里 */
  @Builder
  emptyState() {
    Column() {
      Text(this.activeTab === TAB_UPCOMING ? '🛰' : '📜')
        .fontSize(34)
        .opacity(0.5)
      Text(this.activeTab === TAB_UPCOMING ? '暂无待发射任务' : '暂无已发射记录')
        .fontSize(13)
        .fontColor('#A7B4C7')
        .margin({ top: 10 })
      Text('下拉或稍后重试')
        .fontSize(11)
        .fontColor('#55617A')
        .margin({ top: 6 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 列表 footer。
   *
   * 三种状态分开写而不是拼一个字符串：加载中文案要跟着 loadingMore 一起变，
   * 拼字符串会让整段 Text 在每次状态变化时重建文案节点。
   */
  @Builder
  footer() {
    Row() {
      if (this.activeTab === TAB_UPCOMING && !this.moreDone) {
        Text(this.loadingMore ? '正在加载更多…' : '上拉加载更多')
          .fontSize(11)
          .fontColor('#55617A')
      } else if (this.activeTab === TAB_UPCOMING) {
        Text('已加载全部待发射任务')
          .fontSize(11)
          .fontColor('#3C4760')
      } else {
        Text('仅展示最近 ' + this.previous.length + ' 次发射')
          .fontSize(11)
          .fontColor('#3C4760')
      }
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 14, bottom: 14 })
  }

  // ============ build ============

  build() {
    Column() {
      this.header()
      this.modeBar()

      if (this.viewMode === MODE_CALENDAR) {
        // 日历模式：月网格 + 选中日当天的列表。
        // items 传「待发射 + 已发射」的并集 —— 日历要能往前翻看历史发射。
        Scroll() {
          Column() {
            LaunchCalendar({
              items: this.calendarItems(),
              onPick: (dateStr: string, launches: LaunchSummary[]) => {
                this.pickedDate = dateStr;
                this.pickedLaunches = launches;
              }
            })

            if (this.pickedDate.length > 0) {
              this.pickedDayHeader()
              if (this.pickedLaunches.length === 0) {
                this.pickedDayEmpty()
              } else {
                ForEach(this.pickedLaunches, (item: LaunchSummary) => {
                  LaunchCard({
                    item: item,
                    live: this.isLive(item),
                    onSelect: (picked: LaunchSummary) => {
                      this.openLaunch(picked);
                    }
                  })
                  .margin({ top: 10 })
                }, (item: LaunchSummary) => 'cal_' + this.keyOf(item))
              }
            } else {
              this.pickedDayHint()
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      } else {
        this.statRow()

        if (this.currentList().length === 0) {
          // 空列表：要么还在等首屏（骨架），要么真的没有（空态）
          if (this.loading) {
            this.skeletonList()
          } else {
            this.emptyState()
          }
        } else {
          List({ scroller: this.scroller }) {
            ForEach(this.currentList(), (item: LaunchSummary) => {
              ListItem() {
                LaunchCard({
                  item: item,
                  live: this.isLive(item),
                  onSelect: (picked: LaunchSummary) => {
                    this.openLaunch(picked);
                  }
                })
              }
              .padding({ bottom: 10 })
            }, (item: LaunchSummary) => this.keyOf(item))

            ListItem() {
              this.footer()
            }
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .cachedCount(3)
          // 触底加载：List 自带 onReachEnd，比手算 offset 稳（见 loadMore 的三道闸）
          .onReachEnd(() => {
            this.loadMore();
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    .alignItems(HorizontalAlign.Start)
    // 左右 12vp 页面内边距 + 底部 120 胶囊让位（padding 直接缩内容区，
    // 列表最后一项能完整滚出来，不会被悬浮胶囊压住）
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
  }
}
