/**
 * view/LaunchView.ets —— 「发射」tab
 *
 * 对位小程序 pages/index/index.vue（967 行）。那一页实际包含：
 *   日历条 + 筛选（机构/年份/状态）+ 分段（待发射/已发射）+ 统计行 + 分页列表 + 触底加载
 * 本文件覆盖：
 *   ① 待发射 / 已发射 分段切换   ② 统计行
 *   ③ 列表卡片（components/LaunchCard.ets）  ④ 触底加载 upcomingMore
 *   ⑤ 搜索 + 三维筛选（国家 / 机构 / 火箭）底部抽屉   ⑥ 右下角搜索 / 统计悬浮钮
 *
 * 筛选候选只从**当前 feed 已加载的条目**里现算：数据是渐进加载的，候选跟着列表
 * 一起长，用户不会遇到「选了必然 0 条」的死选项。
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
 *   5. **筛选只保留国家 / 机构 / 火箭三维**（对位小程序 FILTER_KEYS 的三个键）。
 *      年份、轨道上线后几乎没人点，白占面板高度。抽屉里 chips 立即生效，
 *      不做「草稿 + 确定」，底部按钮实时回显「查看 N 个结果」。
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
import { LaunchStatus, LaunchMission, LaunchProvider, LaunchRocket, RocketConfig } from '../model/Common';
import { LaunchCard } from '../components/LaunchCard';
import { LaunchCalendar } from '../components/LaunchCalendar';
import { NextLaunch } from '../components/NextLaunch';
import { StarField } from '../components/StarField';
import { Nav, ROUTE_STATS, ROUTE_VERSION } from '../routes/Nav';
import { LaunchNavParam } from '../routes/NavParam';
import {
  strOf, parseTime, formatGeneratedAt, countryOf, providerLabelOf, rocketLabelOf, placeLabelOf
} from '../utils/Format';

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

/**
 * 「下次发射」的空哨兵。
 *
 * NextLaunch 的 @Prop item 必须有非空默认值（interface 不能当默认值），
 * 父级也不能传 undefined。判断「有没有下次发射」一律用 `nextItem.id.length > 0`，
 * 不要拿 net 判空 —— 真实数据里确实存在 net 为空待定的条目。
 */
const EMPTY_NEXT: LaunchSummary = {
  id: '',
  name: '',
  net: ''
};

/**
 * 三个筛选维度的键。
 * 与小程序 `FILTER_KEYS`（index.vue:194）逐字对齐 —— 键名同时是「已选值」的
 * 存放位置，改字符串等于改协议，所以集中在这里而不是散在 build 里。
 */
const FILT_COUNTRY: string = 'country';
const FILT_AGENCY: string = 'agency';
const FILT_ROCKET: string = 'rocket';

/** 每个维度最多给多少个候选（对位 OPT_LIMIT，index.vue:196） */
const OPT_LIMIT_COUNTRY: number = 20;
const OPT_LIMIT_AGENCY: number = 24;
const OPT_LIMIT_ROCKET: number = 24;

/** 悬浮圆钮直径 / 右边距 / 底部让位（胶囊 58 + margin 20 + 自身间隙） */
/**
 * 右下角两枚悬浮圆钮的尺寸与位置，逐条对位小程序 .fab：
 *   宽高 68rpx → 34vp；right 30rpx → 15vp；bottom 166rpx → 83vp
 *   统计球叠在筛选球正上方，间距 24rpx → 12vp（68+24=92，166+92=258rpx）
 * 我原先写的 48vp / bottom 104 是凭空放的，比小程序大一圈、还贴着胶囊。
 */
const FAB_SIZE: number = 34;
const FAB_RIGHT: number = 15;
const FAB_BOTTOM: number = 83;
const FAB_GAP: number = 12;
/** 面板与按钮的强调色（任务书视觉规范） */
const ACCENT: string = '#38BDF8';

/**
 * 筛选候选项。
 *
 * 用 class 而不是 interface：面板 chips 要 `new` 出来塞进数组，
 * ArkTS 禁无类型对象字面量，interface 无法实例化。
 */
class FiltOption {
  value: string = '';
  label: string = '';
  count: number = 0;

  constructor(value: string, label: string, count: number) {
    this.value = value;
    this.label = label;
    this.count = count;
  }
}

/** 一个筛选维度：key 用于回写状态，label 是段标题，options 是按出现次数降序的前 N 个 */
class FiltGroup {
  key: string = '';
  label: string = '';
  options: FiltOption[] = [];

  constructor(key: string, label: string, options: FiltOption[]) {
    this.key = key;
    this.label = label;
    this.options = options;
  }
}

@Component
export struct LaunchView {
  // ============ 状态 ============

  /** 当前分段：TAB_UPCOMING / TAB_PREVIOUS */
  @State activeTab: number = TAB_UPCOMING;

  /** 待发射列表（首屏 + upcomingMore 追加） */
  @State upcoming: LaunchSummary[] = [];
  /** 已发射列表（只有首屏，历史不做增量） */
  @State previous: LaunchSummary[] = [];

  /**
   * 「下次发射」那条，给列表上方的大卡用。
   *
   * 对位小程序 pages/index/index.vue 的计算属性 nextLaunch：
   *   `list.value.find(x => x.net && new Date(x.net).getTime() > nowTick)`
   * 小程序是遍历待发射列表找第一条过点即止（列表本身按 net 升序，等价于「最近一条」）。
   * 这里同样取第一条 net > now 的记录，不 sort 全表 —— 100+ 条每次重绘都 sort 是白开销。
   *
   * 空值用 EMPTY_NEXT 哨兵（而不是 undefined），因为 @State 承载对象、
   * 且 NextLaunch 组件的 @Prop 需要非空默认值。
   */
  @State nextItem: LaunchSummary = EMPTY_NEXT;

  /** 首屏是否还在等数据。只在「列表为空」时用来决定露骨架还是露空态 */
  @State loading: boolean = true;

  /** 待发射全量条数（payload.count，473）；served 只给 100，靠它算进度 */
  @State upcomingCount: number = 0;

  /** 数据生成时间（两种分段共用一份展示，谁后到用谁） */
  @State generatedAt: string = '';

  /** upcomingMore 是否已经没得加载了（加载过一次 / 回来是空） */
  @State moreDone: boolean = false;

  /**
   * 首屏加载失败文案（空串 = 没失败）。
   *
   * 只有「列表本来是空的且拉数据 reject」才置：有缓存时 repo 不会 reject，
   * 后台刷新失败也不该把已有内容换成错误页 —— 那等于拿一次网络抖动惩罚用户。
   * 对位小程序 pages/index/index.vue:41 的 `error && list.length === 0`。
   */
  @State loadError: string = '';

  /**
   * 下拉刷新状态。
   *
   * 对位小程序 pages/index/index.vue 的 enablePullDownRefresh + onPullDownRefresh：
   * 重拉当前分段（force）。**必须只是「当前分段」**——把两段一起重拉会让
   * 另一个 tab 的列表在后台替换，切过去时闪一下，得不偿失。
   */
  @State refreshing: boolean = false;

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

  // ---- 搜索 / 筛选 ----

  /** 底部抽屉是否展开（bindSheet 的 isShow 绑定它） */
  @State sheetOpen: boolean = false;
  /** 搜索关键词。**输入即生效**，没有「确定」这一步 */
  @State keyword: string = '';
  /** 国家 / 地区。空串 = 不筛（与小程序 `filters.country === ''` 同语义） */
  @State filtCountry: string = '';
  /** 发射机构 */
  @State filtAgency: string = '';
  /** 运载火箭 */
  @State filtRocket: string = '';

  // ============ 私有成员（不参与渲染） ============

  private scroller: Scroller = new Scroller();
  /** 待发射是否已经有一轮在飞，防切换来切换去叠请求 */
  private loadingUpcoming: boolean = false;
  /** 已发射同上 */
  private loadingPrevious: boolean = false;
  /** 已追加过的 id，防止 upcomingMore 与首屏重叠时出现重复卡片 */
  private seenIds: Set<string> = new Set<string>();

  /**
   * 筛选候选缓存（普通成员，不进 @State）。
   *
   * 候选要遍历整表并排序，几十条到几百条无所谓，但它在 build 里被 read 到 ——
   * 若换成 @State 每次重算都会再触发一轮重绘，形成「算 → 画 → 算」的循环。
   * 所以只在列表真正变化时（applyUpcoming / applyPrevious / appendMore）重算，
   * 用 filtDirty 标记「缓存过期」。
   */
  private filtGroups: FiltGroup[] = [];
  /** 候选缓存是否过期。切段与数据落地时置 true，读取时按需重算 */
  private filtDirty: boolean = true;

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
        this.loadError = '';
      })
      .catch((e: BusinessError) => {
        // 有缓存时 repo 不会 reject；走到这里说明首次冷启动且断网。
        // 只有真的一条都没拿到才置错误态，否则保留已有列表（一次抖动不该清屏）
        hilog.warn(DOMAIN, TAG, 'upcoming 加载失败: %{public}s', e.message);
        if (this.upcoming.length === 0) {
          this.loadError = '网络不太顺，请稍后重试';
        }
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
    // 列表换了，候选必须重算 —— 否则筛选面板还挂着上一版数据的机构名
    this.filtDirty = true;
    // 首屏条数已经够全量（served >= count）就没必要再挂 more；
    // 反之说明还有 upcomingMore 可翻 —— 两次判断都要写，否则后台刷新把
    // 已追加的 373 条换回 100 条后，moreDone 还停在 true，列表永远补不回来
    this.moreDone = list.length >= total;
    // 列表换了，下次发射跟着重挑（后台 onUpdate 也会走这里）
    this.nextItem = this.pickNext(list);
  }

  /**
   * 从待发射列表里挑出「下次发射」。
   *
   * 对位小程序 index.vue 的 nextLaunch：按顺序找第一条 net > now 的记录。
   * 列表本身由 CI 按 net 升序产出，所以第一条命中就是最近的一次 ——
   * 不做全表 sort（100+ 条每次重绘都排一遍是白开销）。
   *
   * 用 parseTime 而不是 new Date(net)：解析失败返 0，天然被 `> now` 拦下，
   * 不会出现 NaN 比较恒 false 的隐蔽 bug。id 为空也跳过 —— 没有 id 进不了详情页。
   */
  private pickNext(list: LaunchSummary[]): LaunchSummary {
    const now: number = Date.now();
    for (let i = 0; i < list.length; i++) {
      const it: LaunchSummary = list[i];
      if (it.id.length === 0) {
        continue;
      }
      const at: number = parseTime(it.net);
      if (at > now) {
        return it;
      }
    }
    return EMPTY_NEXT;
  }

  private applyPrevious(data: PreviousPayload): void {
    const list: LaunchSummary[] = data.list !== undefined ? data.list : [];
    this.previous = list;
    this.stampOf(data.generatedAt);
    this.filtDirty = true;
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
      // 追加也会带来新的机构 / 型号，候选同样过期
      this.filtDirty = true;
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
    // 换段等于换候选源（待发射 ↔ 已发射），候选缓存必须作废；
    // 已选的维度值**保留** —— 两个 feed 里 SpaceX / 猎鹰 9 号 都存在，
    // 强行清空反而让用户在两个 tab 之间反复重选同一家机构
    this.filtDirty = true;
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

  // ============ 搜索 / 筛选 ============

  /**
   * 某个维度在一条数据上的原始取值（空串 = 这条没有该维度的信息）。
   *
   * country 直接存中文名：USA / United States 两种写法经 countryOf 归一后
   * 自然合并成一个选项，这正是我们要的（对位 index.vue:202 的 dimValue）。
   */
  private dimValueOf(item: LaunchSummary, key: string): string {
    if (key === FILT_COUNTRY) {
      return countryOf(item);
    }
    if (key === FILT_AGENCY) {
      const p: LaunchProvider | undefined = item.launch_service_provider;
      return (p !== undefined && p !== null) ? strOf(p.name).trim() : '';
    }
    if (key === FILT_ROCKET) {
      const r: LaunchRocket | undefined = item.rocket;
      if (r === undefined || r === null) {
        return '';
      }
      const c: RocketConfig = r.configuration;
      if (c === undefined || c === null) {
        return '';
      }
      return strOf(c.name).trim();
    }
    return '';
  }

  /**
   * 维度的中文显示名。
   *
   * 值始终保持原始英文（等于筛选协议），只有展示走标签表 ——
   * 否则「猎鹰 9 号」写进 filtRocket 后，下一版标签表一改就全对不上了。
   */
  private dimLabelOf(key: string, item: LaunchSummary): string {
    if (key === FILT_AGENCY) {
      const label: string = providerLabelOf(item);
      return label.length > 0 ? label : this.dimValueOf(item, key);
    }
    if (key === FILT_ROCKET) {
      const label: string = rocketLabelOf(item);
      return label.length > 0 ? label : this.dimValueOf(item, key);
    }
    return this.dimValueOf(item, key);
  }

  /** 维度段标题 */
  private dimTitleOf(key: string): string {
    if (key === FILT_COUNTRY) {
      return '国家 / 地区';
    }
    if (key === FILT_AGENCY) {
      return '发射机构';
    }
    return '运载火箭';
  }

  /** 维度候选上限（对位 OPT_LIMIT） */
  private dimLimitOf(key: string): number {
    if (key === FILT_COUNTRY) {
      return OPT_LIMIT_COUNTRY;
    }
    if (key === FILT_AGENCY) {
      return OPT_LIMIT_AGENCY;
    }
    return OPT_LIMIT_ROCKET;
  }

  /**
   * 算某一份数据的某一维候选。
   *
   * 走 Map 而不是 index signature —— ArkTS 禁动态下标，`acc[value]++` 编译不过。
   * 排序先按出现次数降序，次数相同时按取值字典序，保证同一份数据每次算出来的
   * 顺序完全一致（否则 chips 会在两次重算之间莫名换位）。
   */
  private buildGroup(list: LaunchSummary[], key: string): FiltGroup {
    const hits: Map<string, number> = new Map<string, number>();
    // value → 该维度上第一次出现的样本，用来取中文显示名。
    // 同一个 value 的显示名是确定的，但 Format 里那些函数吃整个 LaunchSummary，
    // 所以留一条样本比再开一个「值 → 标签」函数便宜
    const samples: Map<string, LaunchSummary> = new Map<string, LaunchSummary>();

    for (let i = 0; i < list.length; i++) {
      const item: LaunchSummary = list[i];
      const v: string = this.dimValueOf(item, key);
      if (v.length === 0) {
        continue;
      }
      // "Unknown" 是 LL2 的占位值，选它等于「没有机构」，进候选只是噪音
      if (key === FILT_AGENCY && v.toLowerCase() === 'unknown') {
        continue;
      }
      const prev: number | undefined = hits.get(v);
      hits.set(v, prev === undefined ? 1 : prev + 1);
      if (!samples.has(v)) {
        samples.set(v, item);
      }
    }

    // Map 没有 sort，先摊平成数组再排
    const values: string[] = [];
    hits.forEach((n: number, v: string) => {
      values.push(v);
    });
    const counts: number[] = [];
    for (let i = 0; i < values.length; i++) {
      const n: number | undefined = hits.get(values[i]);
      counts.push(n === undefined ? 0 : n);
    }
    // 两个平行数组同步排序：ArkTS 没有稳定 sort 保证，先按次数排，
    // 相同时按值排，结果与顺序无关地确定
    const order: number[] = [];
    for (let i = 0; i < values.length; i++) {
      order.push(i);
    }
    order.sort((a: number, b: number) => {
      if (counts[b] !== counts[a]) {
        return counts[b] - counts[a];
      }
      return values[a] < values[b] ? -1 : (values[a] > values[b] ? 1 : 0);
    });

    const limit: number = this.dimLimitOf(key);
    const options: FiltOption[] = [];
    for (let i = 0; i < order.length && i < limit; i++) {
      const idx: number = order[i];
      const v: string = values[idx];
      const sample: LaunchSummary | undefined = samples.get(v);
      let label: string = v;
      if (sample !== undefined) {
        const zh: string = this.dimLabelOf(key, sample);
        if (zh.length > 0) {
          label = zh;
        }
      }
      options.push(new FiltOption(v, label, counts[idx]));
    }
    return new FiltGroup(key, this.dimTitleOf(key), options);
  }

  /**
   * 三个维度的候选（带缓存）。
   *
   * `候选少于 2 个的维度整组不显示` —— 只剩一个选项的维度筛了也是全选，
   * 白占一块面板高度。
   */
  private groups(): FiltGroup[] {
    if (!this.filtDirty) {
      return this.filtGroups;
    }
    const list: LaunchSummary[] = this.currentList();
    const keys: string[] = [FILT_COUNTRY, FILT_AGENCY, FILT_ROCKET];
    const out: FiltGroup[] = [];
    for (let i = 0; i < keys.length; i++) {
      const g: FiltGroup = this.buildGroup(list, keys[i]);
      if (g.options.length > 1) {
        out.push(g);
      }
    }
    this.filtGroups = out;
    this.filtDirty = false;
    return out;
  }

  /** 某维度当前选中的值 */
  private pickedOf(key: string): string {
    if (key === FILT_COUNTRY) {
      return this.filtCountry;
    }
    if (key === FILT_AGENCY) {
      return this.filtAgency;
    }
    if (key === FILT_ROCKET) {
      return this.filtRocket;
    }
    return '';
  }

  /** 选中某维度的某个值（空串 = 取消该维度） */
  private pickDim(key: string, value: string): void {
    // 再点一次已选中的 chip 就取消 —— 面板上没有单独的「全部」按钮，
    // 靠这个手势给出退出路径
    const next: string = this.pickedOf(key) === value ? '' : value;
    if (key === FILT_COUNTRY) {
      this.filtCountry = next;
    } else if (key === FILT_AGENCY) {
      this.filtAgency = next;
    } else if (key === FILT_ROCKET) {
      this.filtRocket = next;
    }
  }

  /** 是否处于「筛过」状态：关键词或任一维度非空 */
  private hasFilter(): boolean {
    return this.keyword.length > 0 || this.filtCountry.length > 0 ||
      this.filtAgency.length > 0 || this.filtRocket.length > 0;
  }

  /** 生效条件数（悬浮钮角标）：关键词算 1，三个维度各算 1 */
  private activeFilterCount(): number {
    let n: number = 0;
    if (this.keyword.length > 0) {
      n = n + 1;
    }
    if (this.filtCountry.length > 0) {
      n = n + 1;
    }
    if (this.filtAgency.length > 0) {
      n = n + 1;
    }
    if (this.filtRocket.length > 0) {
      n = n + 1;
    }
    return n;
  }

  /**
   * 一条数据的关键词命中面。
   *
   * 任务名要**中英文各自判断**：name 恒存在，写成 `nameZh || name` 再匹配的话
   * 中文名永远轮不到，搜「嫦娥」整组落空（原项目 2026-10-24 复审的 P1-1）。
   * 火箭 / 机构同时喂英文原名和中文标签，这样「猎鹰」「SpaceX」「星链」都有人接。
   */
  private hayOf(item: LaunchSummary): string {
    const parts: string[] = [];
    const mission: LaunchMission | undefined = item.mission;
    if (mission !== undefined && mission !== null) {
      parts.push(strOf(mission.nameZh));
      parts.push(strOf(mission.name));
    }
    parts.push(strOf(item.name));
    parts.push(strOf(rocketLabelOf(item)));
    const r: LaunchRocket | undefined = item.rocket;
    if (r !== undefined && r !== null) {
      const c: RocketConfig = r.configuration;
      if (c !== undefined && c !== null) {
        parts.push(strOf(c.name));
        parts.push(strOf(c.full_name));
      }
    }
    parts.push(strOf(providerLabelOf(item)));
    const p: LaunchProvider | undefined = item.launch_service_provider;
    if (p !== undefined && p !== null) {
      parts.push(strOf(p.name));
    }
    parts.push(strOf(placeLabelOf(item)));
    return parts.join(' ').toLowerCase();
  }

  /** 当前列表按三维 + 关键词过滤后的结果。空条件直接跳过，不做无谓遍历 */
  private filteredList(): LaunchSummary[] {
    const base: LaunchSummary[] = this.currentList();
    if (!this.hasFilter()) {
      return base;
    }
    const kw: string = this.keyword.trim().toLowerCase();
    const out: LaunchSummary[] = [];
    for (let i = 0; i < base.length; i++) {
      const item: LaunchSummary = base[i];
      if (this.filtCountry.length > 0 && this.dimValueOf(item, FILT_COUNTRY) !== this.filtCountry) {
        continue;
      }
      if (this.filtAgency.length > 0 && this.dimValueOf(item, FILT_AGENCY) !== this.filtAgency) {
        continue;
      }
      if (this.filtRocket.length > 0 && this.dimValueOf(item, FILT_ROCKET) !== this.filtRocket) {
        continue;
      }
      if (kw.length > 0 && this.hayOf(item).indexOf(kw) < 0) {
        continue;
      }
      out.push(item);
    }
    return out;
  }

  /** 重置：关键词与三维一起清（对用户来说「重置」= 回到最初的样子） */
  private resetFilter(): void {
    this.keyword = '';
    this.filtCountry = '';
    this.filtAgency = '';
    this.filtRocket = '';
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

  /** 统计行副文（对位 .stat-sub；有筛选时追加「已筛出 x 条」） */
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
    // 主文恒为「共 N 次发射」的总数，过滤信息只放副文 ——
    // 用户扫一眼就知道「筛了但总数没变」，不会以为数据被筛丢了
    if (this.hasFilter()) {
      parts.push('已筛出 ' + this.filteredList().length + ' 条');
    }
    const updated: string = formatGeneratedAt(this.generatedAt);
    if (updated.length > 0) {
      parts.push('更新于 ' + updated);
    }
    return parts.join(' · ');
  }

  // ============ UI ============

  /**
   * 页头：logo + 「太空发射任务」。
   *
   * 对位小程序 pages/index/index.vue:7-16 的 .nav-row：
   *   nav-logo 60rpx → 30vp，圆形 + 天蓝光晕 box-shadow 24rpx → radius 12 / color #4D38BDF8
   *   nav-title 46rpx → 23vp，600 / letter-spacing 2rpx → 1vp
   * 小程序那边点 logo 进版本记录（goVersion），这里同样接 Nav.pushBlank(ROUTE_VERSION)。
   *
   * ⚠ 我第一版写成「发射 / 全部发射任务 · 点击卡片查看详情」两行小标题 —— 用户对比后
   * 说「这完全不一样」。小程序是个品牌页头：30vp 圆形 logo + 23vp 大字项目名。
   * 副标题只保留加载态提示，正常态不再占一行（小程序也没有）。
   */
  @Builder
  header() {
    Row() {
      Image($r('app.media.app_icon'))
        .width(30)
        .height(30)
        .borderRadius(15)
        .objectFit(ImageFit.Cover)
        // 小程序是 box-shadow: 0 0 24rpx rgba(56,189,248,0.3)。
        // ArkUI 的 shadow radius 是模糊半径（不是扩散），24rpx→12，30% alpha→#4D。
        .shadow({ radius: 12, color: '#4D38BDF8', offsetX: 0, offsetY: 0 })
        .margin({ right: 8 })
        .onClick(() => {
          Nav.pushBlank(ROUTE_VERSION);
        })

      Text('太空发射任务')
        .fontSize(23) // 46rpx ÷ 2
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .letterSpacing(1) // 2rpx ÷ 2
        .maxLines(1)
        .layoutWeight(1)

      if (this.loading && this.currentList().length === 0) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color('#38BDF8')
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 12 })
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
   * 视图模式切换项（排期 / 日历）。
   *
   * **选中态是中性灰白，不是天蓝** —— 对位小程序 .mode-opt.on：
   *   background: rgba(255,255,255,0.08); color: #cbd5e0;
   * 左边那组「待发射/已发射」才是天蓝（.feed-opt.on 用 #38bdf8）。
   * 两组控件刻意不同色：天蓝表示「在看哪一批数据」，灰白只是视图切换，
   * 两边都染天蓝会让「当前在哪一档」这个最要紧的信息被稀释。
   *
   * 切到日历要顺手把 upcoming/previous 都拉起来：日历横跨未来与历史，
   * 只加载待发射的话，往前翻月份会一片空白（用户会以为是数据缺失）。
   */
  @Builder
  modeOption(label: string, mode: number) {
    Text(label)
      .fontSize(12.5)
      .fontWeight(this.viewMode === mode ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.viewMode === mode ? '#CBD5E0' : '#6B7891')
      .textAlign(TextAlign.Center)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(13)
      .backgroundColor(this.viewMode === mode ? '#14FFFFFF' : '#00000000')
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
  /**
   * 已生效筛选的概览条：一行摘要 + 一个 ×。
   *
   * 对位小程序 .on-filter（pages/index/index.vue:104-111）。
   * 为什么要这条：筛选藏在右下角抽屉里，收起后界面上看不出「现在看到的是筛过的」，
   * 用户会以为数据丢了。这条条子既是说明也是唯一的清空入口。
   */
  @Builder
  onFilterBar() {
    Row() {
      Text(this.filterSummary())
        .fontSize(12)
        .fontColor('#7FB6DC')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      // × 用两个 45° 细条拼，不用 Text('✕')：文字叉的字重和基线在不同字体下会偏，
      // 而这两个条的位置是硬编码的相对坐标，哪台机器都一样
      Stack() {
        Row()
          .width(10)
          .height(1)
          .backgroundColor('#7FB6DC')
          .rotate({ angle: 45 })
        Row()
          .width(10)
          .height(1)
          .backgroundColor('#7FB6DC')
          .rotate({ angle: -45 })
      }
      .width(22)
      .height(22)
      .borderRadius(11)
      .onClick(() => {
        this.resetFilter();
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: 10, right: 7, top: 6, bottom: 6 })
    .margin({ bottom: 7 })
    .borderRadius(8)
    .backgroundColor('#1438BDF8')
    .border({ width: 1, color: '#3838BDF8' })
  }

  /**
   * 概览条文案：`「关键词」 · 国家 · 机构 · 火箭`。
   *
   * 三个维度的 value 都是中文显示名（见 dimValueOf 的注释），直接拼即可，
   * 不用再走 dimLabelOf 反查 —— 反查要拿一条样本数据，筛空了样本就没了。
   */
  private filterSummary(): string {
    const parts: string[] = [];
    if (this.keyword.length > 0) {
      parts.push('「' + this.keyword + '」');
    }
    if (this.filtCountry.length > 0) {
      parts.push(this.filtCountry);
    }
    if (this.filtAgency.length > 0) {
      parts.push(this.filtAgency);
    }
    if (this.filtRocket.length > 0) {
      parts.push(this.filtRocket);
    }
    return parts.join(' · ');
  }

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

  /** 单张骨架卡：形状按 LaunchCard 的横向卡搭（100vp 方图 + 右侧三行），避免落屏时跳动 */
  @Builder
  skeletonCard() {
    Row() {
      Row()
        .width(100)
        .height(100)
        .borderRadius(7)
        .backgroundColor('#1A2231')

      Column() {
        Row()
          .width('82%')
          .height(13)
          .borderRadius(4)
          .backgroundColor('#1A2231')
        Row()
          .width('52%')
          .height(11)
          .borderRadius(4)
          .backgroundColor('#161D2A')
          .margin({ top: 8 })
        Blank()
        Row()
          .width('38%')
          .height(10)
          .borderRadius(4)
          .backgroundColor('#161D2A')
      }
      .layoutWeight(1)
      .height(100)
      .margin({ left: 11 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(10)
    .backgroundColor(CARD_BG)
    .borderRadius(10)
    .border({ width: 1, color: '#0DFFFFFF' })
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
  /**
   * 首屏错误态：⚠️ + 错误文案 + 「重新尝试」。
   *
   * 对位小程序 .error（pages/index/index.vue:41-45）。之前我把失败也落到空态里，
   * 文案是「下拉或稍后重试」—— 但空态没有可点的东西，用户只能干等；
   * 错误态必须给一个按钮，否则他没法自救。
   */
  @Builder
  errorState() {
    Column() {
      Text('⚠️')
        .fontSize(30)
        .opacity(0.75)
      Text(this.loadError)
        .fontSize(13)
        .fontColor('#A7B4C7')
        .textAlign(TextAlign.Center)
        .margin({ top: 12, left: 24, right: 24 })
      Text('重新尝试')
        .fontSize(12.5)
        .fontColor(ACCENT)
        .padding({ left: 20, right: 20, top: 8, bottom: 8 })
        .margin({ top: 14 })
        .borderRadius(999)
        .backgroundColor('#2938BDF8')
        .border({ width: 1, color: '#6638BDF8' })
        .onClick(() => {
          this.loadError = '';
          this.reloadCurrent();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 重拉当前分段（错误态的「重新尝试」与空态的「重新获取」共用） */
  private reloadCurrent(): void {
    if (this.activeTab === TAB_UPCOMING) {
      this.ensureUpcoming(true);
    } else {
      this.ensurePrevious(true);
    }
  }

  /**
   * 下拉刷新收口。
   *
   * 不能用 load 的 then 收尾：ensureUpcoming/ensurePrevious 是 void（内部自带
   * 三道闸与 catch），拿不到「什么时候结束」。这里按一个短延时收口即可 ——
   * 刷新指示器只要「转一会儿就停」，精确对齐最后一字节没有意义，
   * 反而会让弱网下的转圈卡到十几秒不停。
   */
  private onPullRefresh(): void {
    this.reloadCurrent();
    setTimeout(() => {
      this.refreshing = false;
    }, 700);
  }

  @Builder
  emptyState() {
    Column() {
      Text(this.activeTab === TAB_UPCOMING ? '🛰' : '📜')
        .fontSize(34)
        .opacity(0.5)
      Text(this.hasFilter()
        ? '没有符合条件的发射'
        : (this.activeTab === TAB_UPCOMING ? '暂无待发射任务' : '暂无已发射记录'))
        .fontSize(13)
        .fontColor('#A7B4C7')
        .margin({ top: 10 })
      Text(this.hasFilter() ? '试试重置关键词或换一个筛选' : '下拉或稍后重试')
        .fontSize(11)
        .fontColor('#55617A')
        .margin({ top: 6 })
      if (this.hasFilter()) {
        Text('重置筛选')
          .fontSize(12)
          .fontColor(ACCENT)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .margin({ top: 12 })
          .borderRadius(999)
          .border({ width: 1, color: '#6638BDF8' })
          .onClick(() => {
            this.resetFilter();
          })
      } else {
        // 没有筛选却空了 = 数据侧真没东西，给一个重新拉取的出口。
        // 对位小程序空态的「重新获取」按钮（.btn @click="reload"）。
        Text('重新获取')
          .fontSize(12)
          .fontColor(ACCENT)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .margin({ top: 12 })
          .borderRadius(999)
          .border({ width: 1, color: '#6638BDF8' })
          .onClick(() => {
            this.reloadCurrent();
          })
      }
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
      // 文案逐条对位小程序 pages/index/index.vue:133-138 的四态链。
      // 「上拉」是微信的措辞，鸿蒙这边手势一样（List 触底自动加载），保留原词
      // 反而让两端文案一致，用户从微信过来不会有认知落差。
      if (this.activeTab === TAB_UPCOMING && !this.moreDone) {
        Text(this.loadingMore ? '正在加载后续排期…' : '上拉加载更多')
          .fontSize(11)
          .fontColor('#55617A')
      } else if (this.activeTab === TAB_UPCOMING) {
        Text('已显示全部 ' + this.filteredList().length + ' 条')
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

  // ---- 筛选面板（底部抽屉内容） ----

  /**
   * 抽屉内容：标题行 → 搜索框 → 三维 chips → 结果按钮。
   *
   * chips 点击**立即生效**，抽屉里没有「确定」草稿态 —— 后面的列表同步在变，
   * 底部按钮只回显结果数顺手关面板，用户中途放弃也不会留下半应用的状态。
   */
  @Builder
  filterSheet() {
    Column() {
      // 重置只在真的筛过时出现：常驻一个点了没反应的按钮比不放更糟
      Row() {
        Text('筛选与搜索')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .layoutWeight(1)

        if (this.hasFilter()) {
          Text('重置')
            .fontSize(12.5)
            .fontColor(ACCENT)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(999)
            .backgroundColor('#2938BDF8')
            .onClick(() => {
              this.resetFilter();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // 右侧留 40vp：bindSheet 自带一个系统关闭钮固定在右上角，
      // 不留位置时「重置」会和它叠在一起（2026-11-03 截图实测重叠）。
      .padding({ top: 2, bottom: 14, right: 40 })

      this.searchBox()

      // 全局搜索入口。
      // 抽屉里的搜索框只过滤「已加载的发射」，够不到航天员 / 工位 / 资讯；
      // 想看全库就点这一行（替代小程序那个独立 search 页的入口）。
      Row() {
        Text('🔍')
          .fontSize(12)
        Text('去全局搜索：火箭 / 机构 / 航天员 / 工位 / 资讯')
          .fontSize(12)
          .fontColor('#A7B4C7')
          .layoutWeight(1)
          .margin({ left: 6 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('›')
          .fontSize(13)
          .fontColor(ACCENT)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 9, bottom: 9 })
      .borderRadius(10)
      .backgroundColor('#0D1420')
      .margin({ top: 8 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        // 先把抽屉关掉再跳，否则返回时抽屉还开着，视觉上像没跳成功
        this.sheetOpen = false;
        Nav.pushSearch(this.keyword);
      })

      if (this.groups().length === 0) {
        this.panelEmpty()
      } else {
        Scroll() {
          Column() {
            ForEach(this.groups(), (g: FiltGroup) => {
              this.dimSection(g)
            }, (g: FiltGroup) => 'fg_' + g.key)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
        .margin({ top: 6 })
      }

      Text('查看 ' + this.filteredList().length + ' 个结果')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#04121C')
        .textAlign(TextAlign.Center)
        .width('100%')
        .height(46)
        .borderRadius(23)
        .backgroundColor(ACCENT)
        .margin({ top: 12 })
        .onClick(() => {
          this.sheetOpen = false;
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 14, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 搜索框：输入即生效，右侧清除钮只在有内容时出现 */
  @Builder
  searchBox() {
    Row() {
      // 单向 text 绑定够用：清除按钮改 keyword 后组件会随状态重绘清空，
      // 反之输入走 onChange 回写，两条路径最终都收敛到同一个 @State
      TextInput({ text: this.keyword, placeholder: '搜索任务名、火箭、机构' })
        .type(InputType.Normal)
        .fontSize(13)
        .fontColor('#FFFFFF')
        .placeholderColor('#6B7891')
        .placeholderFont({ size: 13 })
        .backgroundColor('#00000000')
        .padding(0)
        .height(38)
        .layoutWeight(1)
        // 不做防抖：过滤只是一次本地数组遍历，而「查看 N 个结果」要跟着
        // 每个字符即时变，加延迟反而像卡了
        .onChange((v: string) => {
          this.keyword = v;
        })

      if (this.keyword.length > 0) {
        Text('✕')
          .fontSize(12)
          .fontColor('#6B7891')
          .width(26)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            this.keyword = '';
          })
      }
    }
    .width('100%')
    .padding({ left: 14, right: 6 })
    .backgroundColor('#0D1420')
    .borderRadius(999)
    .border({ width: 1, color: '#14FFFFFF' })
  }

  /** 抽屉空态：首屏还没到、或这批数据压根没有可筛字段 */
  @Builder
  panelEmpty() {
    Column() {
      Text('当前列表没有可筛选的维度')
        .fontSize(12)
        .fontColor('#55617A')
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 一个维度：段标题 + 可折行 chips */
  @Builder
  dimSection(g: FiltGroup) {
    Column() {
      Text(g.label)
        .fontSize(12)
        .fontColor('#55617A')
        .letterSpacing(0.5)
        .margin({ top: 12, bottom: 8 })

      // Row 不支持折行，要换行只能用 Flex(Wrap)；Flex 不认 space，
      // 间距靠每个 chip 自己的 margin 撑
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(g.options, (opt: FiltOption) => {
          Text(opt.label)
            .fontSize(12)
            .fontColor(this.pickedOf(g.key) === opt.value ? ACCENT : '#A7B4C7')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // Text 没有 maxWidth，长中文机构名靠 constraintSize 封顶
            .constraintSize({ maxWidth: 200 })
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .borderRadius(999)
            .backgroundColor(this.pickedOf(g.key) === opt.value ? '#2938BDF8' : CARD_BG)
            // 未选中也给 1vp 透明描边：否则选中瞬间多出一圈边，整行 chip 会跳一下
            .border({
              width: 1,
              color: this.pickedOf(g.key) === opt.value ? '#6638BDF8' : '#00000000'
            })
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.pickDim(g.key, opt.value);
            })
        }, (opt: FiltOption) => 'fo_' + g.key + '_' + opt.value)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  // ---- 右下角两个悬浮圆钮 ----

  /**
   * 悬浮钮①：搜索。
   *
   * 图标是**纯几何画的**，不用 emoji —— 小程序也是这么做的（.fab-lens + .fab-handle
   * 两个 div 拼放大镜）。原因很实在：emoji 在深色玻璃球上会跳出彩色，跟旁边那颗球不搭。
   * 也不用 $r('app.media.*')：工程里没有搜索图标资源，引不存在的 media 直接编译失败。
   *
   * 尺寸对位：圆环外径 22rpx→11vp、描边 2.5rpx→1.25vp、手柄 10×2.5rpx→5×1.25vp、45°。
   */
  @Builder
  fabSearch() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        Stack({ alignContent: Alignment.TopStart }) {
          Circle({ width: 11, height: 11 })
            .fillOpacity(0)
            .stroke('#F0FFFFFF')
            .strokeWidth(1.25)
            .offset({ x: 1.5, y: 1.5 })

          Row()
            .width(5)
            .height(1.25)
            .borderRadius(1)
            .backgroundColor('#F0FFFFFF')
            .offset({ x: 11, y: 12 })
            .rotate({ angle: 45 })
        }
        .width(16)
        .height(16)
      }
      .width(FAB_SIZE)
      .height(FAB_SIZE)
      .borderRadius(FAB_SIZE / 2)
      // 对位 .fab：rgba(255,255,255,0.06) 底 + blur(26rpx) + 0.16 描边 + 双层阴影
      .backgroundColor('#0FFFFFFF')
      .backdropBlur(13)
      .border({ width: 1, color: '#29FFFFFF' })
      .shadow({ radius: 16, color: '#42000000', offsetY: 6 })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        this.sheetOpen = true;
      })

      if (this.activeFilterCount() > 0) {
        // 角标用琥珀黄，对位 .fab-badge 的 rgba(245,195,59,0.94)。
        // 不用天蓝：天蓝在这套界面里是主色/选中色，拿它当角标会跟选中态混起来；
        // 琥珀在深色底上跳得出来又不抢主视觉。24rpx→12vp，字 15rpx→7.5vp。
        Text(this.activeFilterCount().toString())
          .fontSize(7.5)
          .fontWeight(FontWeight.Medium)
          .fontColor('#10151F')
          .textAlign(TextAlign.Center)
          .constraintSize({ minWidth: 12 })
          .height(12)
          .padding({ left: 2.5, right: 2.5 })
          .borderRadius(6)
          .backgroundColor('#F0F5C33B')
          .border({ width: 1, color: '#47FFFFFF' })
          .offset({ x: 1, y: -1 })
      }
    }
    .width(FAB_SIZE)
    .height(FAB_SIZE)
  }

  /**
   * 悬浮钮②：柱状图。
   *
   * 三根**递增的白竖条**（14/22/30rpx → 7/11/15vp，宽 5rpx → 2.5vp，间距 2.5rpx → 1.25vp）。
   * 小程序里三根**全是** rgba(255,255,255,0.94)，我之前把第三根染成天蓝是自作主张 ——
   * 两颗球的图标同属「白色线框」家族，混一个彩色进去就破了。
   */
  @Builder
  fabStats() {
    Column() {
      Row() {
        Column()
          .width(2.5)
          .height(7)
          .borderRadius(1)
          .backgroundColor('#F0FFFFFF')
          .margin({ left: 1.25, right: 1.25 })
        Column()
          .width(2.5)
          .height(11)
          .borderRadius(1)
          .backgroundColor('#F0FFFFFF')
          .margin({ left: 1.25, right: 1.25 })
        Column()
          .width(2.5)
          .height(15)
          .borderRadius(1)
          .backgroundColor('#F0FFFFFF')
          .margin({ left: 1.25, right: 1.25 })
      }
      .height(15)
      // 底对齐：三条高度不同，靠这个让它们在一条基线上长出来
      .alignItems(VerticalAlign.Bottom)
    }
    .width(FAB_SIZE)
    .height(FAB_SIZE)
    .borderRadius(FAB_SIZE / 2)
    .backgroundColor('#0FFFFFFF')
    .backdropBlur(13)
    .border({ width: 1, color: '#29FFFFFF' })
    .shadow({ radius: 16, color: '#42000000', offsetY: 6 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      // 走空白页栈：统计页是独立工具页，不该挤进发射页的返回历史
      Nav.pushBlank(ROUTE_STATS);
    })
  }

  // ============ build ============

  /**
   * 页面主体。
   *
   * 从 build 里整体拆出来，是因为 build 现在要叠三层：主体 + 两个悬浮钮 + 抽屉，
   * 而 `bindSheet` 要挂在主体上（锚点是页面而不是窗口）。
   */
  @Builder
  feedPage() {
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
                    // 列表卡不再挂倒计时（改回小程序的横向紧凑卡，倒计时只在「下次发射」大卡上）
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

        // 「下次发射」大卡：待发射分段、挑得出来、列表非空、且没开筛选时才挂。
        //
        // 对位小程序 pages/index/index.vue:99 的
        //   v-if="nextLaunch && visible.length && !hasFilter"
        // 四个条件缺一不可：
        //   · 有下次发射
        //   · 列表非空（否则卡还在、列表空着，页面看着像加载失败）
        //   · 没开筛选 —— 用户已在找具体的某几次发射，倒计时只会把结果往下挤；
        //     hasFilter() 同时含关键词与三维筛选，一个条件覆盖两种状态
        // **不传 more**：小程序发射页那张卡是
        //   `<next-launch :item="nextLaunch" @select="goDetail" />`
        // 没有 more 开关（这页本来就是全部发射，「更多发射」无处可去）。
        // more 只有今日页那张卡才有。
        if (this.activeTab === TAB_UPCOMING && this.nextItem.id.length > 0 &&
          this.filteredList().length > 0 && !this.hasFilter()) {
          NextLaunch({
            item: this.nextItem,
            onSelect: (picked: LaunchSummary) => {
              this.openLaunch(picked);
            }
          })
            .margin({ bottom: 10 })
        }

        if (this.hasFilter()) {
          this.onFilterBar()
        }

        if (this.filteredList().length === 0) {
          // 三选一，顺序有讲究（对位小程序 v-if 链）：
          //   1. 首屏失败（有文案）→ 错误态，给「重新尝试」
          //   2. 首屏还在路上   → 骨架
          //   3. 真的没有       → 空态
          // 错误态必须排在骨架前面，否则断网时会永远停在骨架、用户不知道发生了什么
          if (this.loadError.length > 0) {
            this.errorState()
          } else if (this.loading) {
            this.skeletonList()
          } else {
            this.emptyState()
          }
        } else {
          // Refresh 包住 List：对位小程序 enablePullDownRefresh。
          // 只包列表不包整页 —— 日历模式是 Scroll，下拉刷新对它没意义
          // （日历的数据来自同一批 upcoming/previous，已经在列表模式维护着）。
          Refresh({ refreshing: $$this.refreshing }) {
            List({ scroller: this.scroller }) {
              ForEach(this.filteredList(), (item: LaunchSummary) => {
                ListItem() {
                  LaunchCard({
                    item: item,
                    // 列表卡不再挂倒计时（改回小程序的横向紧凑卡，倒计时只在「下次发射」大卡上）
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
            .height('100%')
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .cachedCount(3)
            // 触底加载：List 自带 onReachEnd，比手算 offset 稳（见 loadMore 的三道闸）
            .onReachEnd(() => {
              this.loadMore();
            })
          }
          .layoutWeight(1)
          .onRefreshing(() => {
            this.onPullRefresh();
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    // ⚠ 这里不能设不透明背景：星空画在它下层，一旦盖上就整片看不见了。
    // 底色统一由 build() 最外层 Stack 提供。
    .alignItems(HorizontalAlign.Start)
    // 左右 12vp 页面内边距 + 底部 120 胶囊让位（padding 直接缩内容区，
    // 列表最后一项能完整滚出来，不会被悬浮胶囊压住）
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
  }

  build() {
    // 根从 Column 换成 Stack：两枚悬浮钮要浮在列表之上，且不能被列表裁剪。
    // Stack 内的子节点按 BottomEnd 对齐，主体自己撑满，悬浮层只占右下角。
    Stack({ alignContent: Alignment.TopStart }) {
      // 1 星空底层。小程序 pages/index/index.vue 顶部就有 <star-field />，
      //   我之前只给今日页和我的页铺了，发射页漏了 —— 这次补上。
      //   必须作为 Stack 第一个子节点（绝对定位铺满、hitTestBehavior None）。
      StarField()

      // 2 主体（原来直接当 Stack 根用，现在多包一层对齐）
      Stack({ alignContent: Alignment.BottomEnd }) {
        this.feedPage()

        Column({ space: FAB_GAP }) {
          this.fabSearch()
          this.fabStats()
        }
        .margin({ right: FAB_RIGHT, bottom: FAB_BOTTOM })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    // 抽屉挂在根上而不是挂在某个按钮上：按钮在 Stack 里会被列表重绘牵连，
    // 挂在页面上时序更稳。onDisappear 负责把状态同步回来 —— 用户下滑关闭时
    // isShow 不会自己变 false，不接这个回调按钮就成了「开一次之后永久失效」。
    .bindSheet(this.sheetOpen, this.filterSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      backgroundColor: CARD_BG,
      onDisappear: () => {
        this.sheetOpen = false;
      }
    })
  }
}
