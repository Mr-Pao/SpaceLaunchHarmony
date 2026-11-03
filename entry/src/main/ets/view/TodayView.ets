/**
 * view/TodayView.ets —— 「今日」tab（按 pages/today/today.vue 逐块对齐）
 *
 * 结构（自上而下，全部压在 StarField 星空层之上）：
 *   日期行 → 每日一览三卡（sl / apod / epic 横滑）→ 「下次发射」大卡 →
 *   「往年今日」→「此刻在天上」→「航天资讯」→ 四路全空时的整页空态 → 底部让位。
 *   五个子组件各自带区块标题，页面这层不重复画标题，只保留顶部日期行这一处自绘文本。
 *
 * ── 本轮对齐 today.vue 做的改动（逐条对应审计项）──
 *   1. **整页空态**（today.vue:165-173）。四路（dailyCards / astronauts / next / otd）
 *      全空时出 🛰️ + 「今天的数据还没准备好」+「重新加载」胶囊按钮；
 *      还在加载时文案换成「正在拉取今日数据…」且不画按钮 —— 与小程序同一套条件。
 *   2. **下拉刷新**（today.vue 的 enablePullDownRefresh + onPullDownRefresh）。
 *      用 Refresh 包住列表，onRefreshing 里重跑 loadAll(true)（七路全 force）；
 *      七路全部 settle 之后再把 refreshing 归位，否则转圈会在数据到齐前提前收掉。
 *   3. **「更多发射」真跳转**（today.vue 的 goFeed → uni.switchTab('/pages/index/index')）。
 *      子视图拿不到宿主的 TabsController，故照 FAV_VERSION_KEY 的既有广播范式：
 *      TodayView 往 AppStorage 写 TAB_REQUEST_KEY，Index.ets 订阅后 changeIndex。
 *      写入值是「序号 × 10 + tab 下标」——必须让每次写入都变（连点两次同一个 tab
 *      也要生效），纯写下标会被 @Watch 的同值去重吞掉。
 *   4. **删掉页头副标题**（today.vue 的 .nav-row 里只有一行 .nav-date）。
 *   5. **apod / epic 卡不再带摘要**：小程序 dailyCards 里 desc 恒为 ''，
 *      .daily-desc 永远不渲染；正文只进详情层。故构造卡时 desc 传空串。
 *   6. **触底加载**（today.vue 的 onReachBottom → news.loadMore()）。
 *      外层滚动容器改成 List 就是为了拿 onReachEnd —— 工程里 onReachEnd 只在
 *      List/WaterFlow 上用过，Scroll 上没有先例，不赌它的签名。触底只发一个自增信号，
 *      展开量仍由 NewsSection 自己夹（它知道 list 长度与步长）。
 *   7. **「更多图片」按类型分流**（today.vue 的 moreImgs）。小程序是
 *      sl→gallery-all?tab=image、apod→?tab=astro、epic→?tab=earth；
 *      鸿蒙侧没有 gallery-all 这个分类浏览器页（图库主 tab 只有「精选 / NASA」两段），
 *      所以三类统一落到「图库」tab。**这不是逐字节复刻**，只保证「点了有去处」，
 *      等 GalleryView 补上分类段再细化。
 *   8. 页头字重 Bold；其余颜色/字号按 today.vue 的 rpx ÷ 2 取。
 *
 * ── 数据链路（语义与 utils/data.js 的 load 对齐：谁先到谁先上屏）──
 *   gallery            → 过滤 thumb 非空 → pickDaily(list, daySeed(Date.now())) 选每日一图
 *   astronautsInspace  → 过滤 inSpace → 按 days 降序
 *   upcoming(onUpdate) → nextLaunch() 取「net 非空且时刻 > now」的最早一条
 *   onthisday(onUpdate)→ 透传 OnThisDay
 *   apod(onUpdate)     → 过滤 NASA 降级占位后取 [0]
 *   epic(onUpdate)     → 取 [0]
 *   news(onUpdate)     → 透传 NewsSection
 * 每一路各自 catch，一路失败只影响自己，不拖垮整页。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions, DataSet } from '../data/Repository';
import { strOf, formatDateTime, todayLabel, parseTime } from '../utils/Format';
import { GalleryItem, pickDaily, daySeed } from '../utils/Daily';
import { DailyCardItem, DailyCards } from '../components/DailyCards';
import { NextLaunch } from '../components/NextLaunch';
import { OnThisDay } from '../components/OnThisDay';
import { InSpaceRow } from '../components/InSpaceRow';
import { NewsSection } from '../components/NewsSection';
import { StarField } from '../components/StarField';
import { LaunchSummary, UpcomingPayload, OnThisDayItem, OnThisDayPayload } from '../model/Launch';
import { AstronautCard, AstronautsInspacePayload } from '../model/Astronaut';
import { ApodItem, EpicItem, ApodPayload, EpicPayload } from '../model/Apod';
import { NewsItem, NewsPayload, NewsLaunchRef } from '../model/News';
import { Nav } from '../routes/Nav';
import { LaunchNavParam, PhotoNavParam, ArticleNavParam, AstronautNavParam } from '../routes/NavParam';

/**
 * 「请求切到某个 tab」的广播键。
 *
 * 为什么定义在这里而不是 routes/Nav.ets：写方只有今日页，读方只有 Index.ets，
 * 而 Index 本来就要 import TodayView，放在这里不会多一条依赖边；
 * 反过来 TodayView 若 import Index 就是循环依赖。
 *
 * 值编码见 requestTab()：raw = 序号 × 10 + tab 下标，读方用 raw % 10 取下标。
 */
export const TAB_REQUEST_KEY: string = 'sl_tab_request';

/** tab 下标，与 Index.ets 的 TabContent 顺序严格一致 */
export const TAB_LAUNCH: number = 1;
export const TAB_GALLERY: number = 2;

/** 编码基数：序号 × 10 + 下标（下标只有 0~4，10 够用） */
const TAB_SEQ_BASE: number = 10;

const DOMAIN: number = 0x0000;
const TAG: string = 'TodayView';

/** 页面底色（与 Index.ets / EntryAbility 的窗口底色同值，避免首帧色差） */
const BG_PRIMARY: string = '#0A0E17';

/**
 * 时钟节拍：30 秒一次。
 * 只服务 nextLaunch() 的重算 —— 倒计时本身由 Countdown 组件内部每秒自转，
 * 页面不该每秒 rebuild 一次整棵子树。
 */
const TICK_MS: number = 30000;

/**
 * 底部内边距：悬浮胶囊让位。
 * 胶囊本体 58 + 底部 margin 20 = 78，再加渐变遮罩渐入高度（FloatingTabBar 的 padding.top 28）。
 * 留 92 时滚到底最后一条会被压掉半行（2026-11-02 截图确认），故 120。
 */
const BOTTOM_PAD: number = 120;

/** 页面左右内边距（工程约定 12vp） */
const PAGE_PAD: number = 12;

/** 资讯首屏条数（对位 `<news-section :limit="3" />`） */
const NEWS_LIMIT: number = 3;

/** 独立加载的路数：六路 + 资讯 = 7 */
const LOAD_TOTAL: number = 7;

/** apod 降级占位响应的识别特征 */
const WP_THEME_RE: RegExp = new RegExp('/wp-content/themes/');

/**
 * 空发射。NextLaunch 的 @Prop 默认值就是同形状的 EMPTY_LAUNCH，
 * 页面自己也需要一个「取不到」的返回值，故在页面侧再定义一份。
 */
const EMPTY_LAUNCH: LaunchSummary = {
  id: '',
  name: '',
  net: ''
};

@Component
export struct TodayView {
  // ============ 状态 ============

  /** 30 秒一拍的时钟，nextLaunch() 用它判断「还没发射」 */
  @State nowTick: number = Date.now();
  /** 顶部日期行文案（「11月2日 星期日」）。跨零点时随 tick 一起更新 */
  @State today: string = todayLabel();
  /** 是否还在等数据（空态文案 + 骨架屏之外的一处提示） */
  @State loading: boolean = true;
  /** 下拉刷新中。Refresh 的双向绑定变量，必须进 @State */
  @State refreshing: boolean = false;

  /** 图库（已过滤 thumb 非空） */
  @State gallery: GalleryItem[] = [];
  /** 在轨宇航员（已过滤 inSpace，已按 days 降序） */
  @State astronauts: AstronautCard[] = [];
  /** 待发射列表（全量 100 条，nextLaunch() 每次只挑一条） */
  @State upcoming: LaunchSummary[] = [];
  /** 往年今日 */
  @State otd: OnThisDayItem[] = [];
  /** 每日天文（通常 1 条；保留数组是为了与 onUpdate 回填结构一致） */
  @State apod: ApodItem[] = [];
  /** 每日地球 */
  @State epic: EpicItem[] = [];
  /** 资讯（NewsSection 只做「露几条」的折叠，数据由页面给） */
  @State news: NewsItem[] = [];

  /** 交给 DailyCards 的三张卡（sl → apod → epic）。@State 整体替换才触发重绘 */
  @State dailyCards: DailyCardItem[] = [];

  /**
   * 触底自增信号。每 +1 让 NewsSection 多露一批。
   *
   * 为什么不把 shown 提到页面：展开量是纯视图态，只有组件自己知道步长与上限；
   * 页面每次列表重排都要读它，反而多一次跨层依赖。这里只发「再来一点」的意图。
   */
  @State newsGrow: number = 0;

  // ============ 私有成员（不参与渲染） ============

  /** 30 秒节拍器句柄。-1 表示没在跑 */
  private tickTimer: number = -1;
  /** 还没结束的加载路数 */
  private pending: number = 0;
  /** 切 tab 请求序号：保证同值连发也能触发宿主的 @Watch */
  private tabSeq: number = 0;

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadAll(false);
    this.startTick();
  }

  /**
   * 必须清定时器。
   * Tabs 有 keepAlive，切到别的 tab 不会销毁本组件，但一旦页面被真正销毁
   * （Index 重建 / ability 退出），残留的 interval 会让回调调到已卸载的实例上。
   */
  aboutToDisappear(): void {
    this.stopTick();
  }

  private startTick(): void {
    if (this.tickTimer !== -1) {
      return;
    }
    this.tickTimer = setInterval(() => {
      this.nowTick = Date.now();
      // 跨零点时日期行要跟着变，否则停在页面上永远是昨天
      const label: string = todayLabel();
      if (label !== this.today) {
        this.today = label;
      }
    }, TICK_MS);
  }

  private stopTick(): void {
    if (this.tickTimer !== -1) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  // ============ 加载 ============

  /**
   * 七路各自加载、各自上屏。
   *
   * 刻意不用 Promise.all 等齐：宇航员/图库/资讯三份体量差着两个数量级，
   * 等最慢那份会把「往年今日」这种 9KB 的内容一起拖住。
   * 每一路都在自己的 catch 里收尾，所以 pending 一定会走到 0。
   */
  private loadAll(force: boolean): void {
    this.pending = LOAD_TOTAL;
    this.loading = true;

    this.loadGallery(force);
    this.loadAstronauts(force);
    this.loadUpcoming(force);
    this.loadOnThisDay(force);
    this.loadApod(force);
    this.loadEpic(force);
    this.loadNews(force);
  }

  /** 一路收尾：全部结束才关 loading / 停下拉转圈 */
  private settle(): void {
    this.pending = this.pending - 1;
    if (this.pending <= 0) {
      this.pending = 0;
      this.loading = false;
      // 下拉手势已经结束、数据也到齐了，才把 refreshing 交还给 Refresh，
      // 提前归位会让转圈在内容还是旧的时候消失，看起来像「没刷新」。
      this.refreshing = false;
    }
  }

  /** gallery：DataHub 里没有专门的 GalleryPayload，用 DataSet 的 list: Object[] 断言 */
  private loadGallery(force: boolean): void {
    const opts: LoadOptions<DataSet> = { force: force };
    repo.load<DataSet>('gallery', opts)
      .then((data: DataSet) => {
        const raw: Object[] = data.list !== undefined ? data.list : [];
        const kept: GalleryItem[] = [];
        for (let i = 0; i < raw.length; i++) {
          const item: GalleryItem = raw[i] as GalleryItem;
          // 没有缩略图的条目在卡片上就是一块黑，直接剔掉
          if (strOf(item.thumb).length > 0) {
            kept.push(item);
          }
        }
        this.gallery = kept;
        this.rebuildCards();
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'gallery 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  /** astronautsInspace：数据集本身只有 inSpace 的十来条，仍做一次过滤兜脏数据 */
  private loadAstronauts(force: boolean): void {
    const opts: LoadOptions<AstronautsInspacePayload> = { force: force };
    repo.load<AstronautsInspacePayload>('astronautsInspace', opts)
      .then((data: AstronautsInspacePayload) => {
        const raw: AstronautCard[] = data.list !== undefined ? data.list : [];
        const kept: AstronautCard[] = [];
        for (let i = 0; i < raw.length; i++) {
          const a: AstronautCard = raw[i];
          if (a.inSpace) {
            kept.push(a);
          }
        }
        // 在轨天数降序：资历最老的排前面（对位 today.vue 的 inSpace 计算属性）
        kept.sort((x: AstronautCard, y: AstronautCard) => {
          const dx: number = x.days === undefined ? 0 : x.days;
          const dy: number = y.days === undefined ? 0 : y.days;
          return dy - dx;
        });
        this.astronauts = kept;
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'astronautsInspace 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  /** upcoming：接 onUpdate，停在今日页时后台刷到新排期也能自己顶上 */
  private loadUpcoming(force: boolean): void {
    const opts: LoadOptions<UpcomingPayload> = {
      force: force,
      onUpdate: (fresh: UpcomingPayload) => {
        this.upcoming = fresh.list !== undefined ? fresh.list : [];
      }
    };
    repo.load<UpcomingPayload>('upcoming', opts)
      .then((data: UpcomingPayload) => {
        this.upcoming = data.list !== undefined ? data.list : [];
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'upcoming 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  /** onthisday：同样接 onUpdate（每日 UTC 23:10 由 CI 产出新的一天） */
  private loadOnThisDay(force: boolean): void {
    const opts: LoadOptions<OnThisDayPayload> = {
      force: force,
      onUpdate: (fresh: OnThisDayPayload) => {
        this.otd = fresh.list !== undefined ? fresh.list : [];
      }
    };
    repo.load<OnThisDayPayload>('onthisday', opts)
      .then((data: OnThisDayPayload) => {
        this.otd = data.list !== undefined ? data.list : [];
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'onthisday 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  /** apod：接 onUpdate。force 分支本身不回传，命中缓存时 onUpdate 才能把后台结果补上屏 */
  private loadApod(force: boolean): void {
    const opts: LoadOptions<ApodPayload> = {
      force: force,
      onUpdate: (fresh: ApodPayload) => {
        this.applyApod(fresh);
      }
    };
    repo.load<ApodPayload>('apod', opts)
      .then((data: ApodPayload) => {
        this.applyApod(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'apod 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  /** epic：接 onUpdate（EPIC 从 4 张扩到 13 张后，不接就停在旧缓存上） */
  private loadEpic(force: boolean): void {
    const opts: LoadOptions<EpicPayload> = {
      force: force,
      onUpdate: (fresh: EpicPayload) => {
        this.epic = fresh.list !== undefined ? fresh.list : [];
        this.rebuildCards();
      }
    };
    repo.load<EpicPayload>('epic', opts)
      .then((data: EpicPayload) => {
        this.epic = data.list !== undefined ? data.list : [];
        this.rebuildCards();
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'epic 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  /** news：组件不吃网络，必须页面拉 */
  private loadNews(force: boolean): void {
    const opts: LoadOptions<NewsPayload> = {
      force: force,
      onUpdate: (fresh: NewsPayload) => {
        this.news = fresh.list !== undefined ? fresh.list : [];
      }
    };
    repo.load<NewsPayload>('news', opts)
      .then((data: NewsPayload) => {
        this.news = data.list !== undefined ? data.list : [];
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'news 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  /**
   * apod 落地：前台返回值与后台 onUpdate 都走这里，保证同一套过滤。
   * 丢掉 title === 'NASA Science'（上游降级时的占位）与命中 /wp-content/themes/ 的破图地址。
   */
  private applyApod(data: ApodPayload): void {
    const raw: ApodItem[] = data.list !== undefined ? data.list : [];
    const kept: ApodItem[] = [];
    for (let i = 0; i < raw.length; i++) {
      const x: ApodItem = raw[i];
      if (strOf(x.title) === 'NASA Science') {
        continue;
      }
      const full: string = strOf(x.full);
      const url: string = full.length > 0 ? full : strOf(x.thumb);
      if (WP_THEME_RE.test(url)) {
        continue;
      }
      kept.push(x);
    }
    this.apod = kept;
    this.rebuildCards();
  }

  // ============ 每日一览三卡 ============

  /** a 优先，空则退 b（对应 `x.titleZh || x.title`） */
  private firstOf(a: string | undefined, b: string | undefined): string {
    const va: string = strOf(a);
    if (va.length > 0) {
      return va;
    }
    return strOf(b);
  }

  /**
   * 重建三张每日卡，顺序固定 sl → apod → epic。
   * 三路数据谁后到都要重算一次（缩略图那路可能最慢），所以每次全量拼一遍再整体替换。
   */
  private rebuildCards(): void {
    const cards: DailyCardItem[] = [];
    this.pushSlCard(cards);
    this.pushApodCard(cards);
    this.pushEpicCard(cards);
    this.dailyCards = cards;
  }

  /** 每日一图：按北京天序号哈希抽图，同一天恒定（见 utils/Daily.ets 的 pickDaily） */
  private pushSlCard(cards: DailyCardItem[]): void {
    const daily: GalleryItem | null = pickDaily(this.gallery, daySeed(Date.now()));
    if (daily === null) {
      return;
    }

    // LL2 的 name 是「火箭型号 | 任务名」，卡片只留任务名（型号在 meta 行已单独出现）
    const parts: string[] = strOf(daily.name).split('|');
    const rawTitle: string = parts.length > 1 ? parts[1] : parts[0];

    // meta = [机构中文名, 发射时刻].filter(非空).join(' · ')
    const metaParts: string[] = [];
    const cname: string = strOf(daily.cname).trim();
    if (cname.length > 0) {
      metaParts.push(cname);
    }
    const when: string = formatDateTime(strOf(daily.net));
    if (when.length > 0) {
      metaParts.push(when);
    }

    const credit: string = strOf(daily.credit).trim();
    const card: DailyCardItem = new DailyCardItem(
      'sl',
      '每日一图',
      metaParts.join(' · '),
      rawTitle.trim(),
      '',
      strOf(daily.thumb),
      credit.length > 0 ? '@' + credit : ''
    );
    // 构造器只有 7 个参数，发射定位字段写后赋值（与 openDailyCard 的入参对应）
    card.launchId = strOf(daily.id);
    card.net = strOf(daily.net);
    cards.push(card);
  }

  /**
   * 每日天文：取 [0]。
   * desc 传空串 —— 小程序 dailyCards 里 apod 的 desc 恒为 ''，`.daily-desc`
   * （v-if="c.desc"）永远不渲染，正文只在 photo-detail 里出现。
   * 之前把 explanation 塞进 desc，卡片上就多出三行摘要，与小程序不一致。
   */
  private pushApodCard(cards: DailyCardItem[]): void {
    if (this.apod.length === 0) {
      return;
    }
    const x: ApodItem = this.apod[0];
    const thumb: string = strOf(x.thumb);
    const card: DailyCardItem = new DailyCardItem(
      'apod',
      '每日天文',
      strOf(x.date),
      this.firstOf(x.titleZh, x.title),
      '',
      thumb.length > 0 ? thumb : strOf(x.full),
      strOf(x.credit)
    );
    cards.push(card);
  }

  /** 每日地球：date 只留 YYYY-MM-DD（数据里可能带时刻），标题与署名写死；desc 同 apod 传空 */
  private pushEpicCard(cards: DailyCardItem[]): void {
    if (this.epic.length === 0) {
      return;
    }
    const x: EpicItem = this.epic[0];
    const thumb: string = strOf(x.thumb);
    const card: DailyCardItem = new DailyCardItem(
      'epic',
      '每日地球',
      strOf(x.date).slice(0, 10),
      '地球 · DSCOVR',
      '',
      thumb.length > 0 ? thumb : strOf(x.full),
      'NASA EPIC'
    );
    cards.push(card);
  }

  // ============ 下次发射 ============

  /**
   * 下一次发射：net 非空且时刻晚于当前时钟，取最早一条。
   *
   * 用 parseTime 而不是 new Date(net) —— 解析失败返回 0，天然被 `> nowTick` 拦下，
   * 不会出现 NaN 比较恒 false 的静默错误。
   */
  private nextLaunch(): LaunchSummary {
    let best: LaunchSummary | null = null;
    let bestAt: number = 0;
    for (let i = 0; i < this.upcoming.length; i++) {
      const item: LaunchSummary = this.upcoming[i];
      const net: string = strOf(item.net);
      if (net.length === 0 || strOf(item.id).length === 0) {
        continue;
      }
      const at: number = parseTime(net);
      if (at <= this.nowTick) {
        continue;
      }
      if (best === null || at < bestAt) {
        best = item;
        bestAt = at;
      }
    }
    return best === null ? EMPTY_LAUNCH : best;
  }

  /** 有没有下一次发射（空态条件要用，避免 build 里重复调 nextLaunch） */
  private hasNext(): boolean {
    return strOf(this.nextLaunch().id).length > 0;
  }

  /**
   * 整页空态条件，逐字对位 today.vue：
   *   v-if="!daily && !inSpace.length && !next && !otd.length"
   * daily 是 dailyCards 数组（三张卡都没凑出来才算空）。
   */
  private isEmpty(): boolean {
    return this.dailyCards.length === 0 && this.astronauts.length === 0 &&
      !this.hasNext() && this.otd.length === 0;
  }

  // ============ 交互（A1 路由：直接调全局 Nav 门面） ============

  private logAction(action: string, key: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s key=%{public}s', action, key);
  }

  /**
   * 广播「请宿主切到第 index 个 tab」。
   *
   * 值 = 序号 × 10 + 下标：@Watch 对同值不触发，纯写下标时「连点两次更多发射」
   * 第二次会失效；带上自增序号则每次都是新值。
   */
  private requestTab(index: number): void {
    this.tabSeq = this.tabSeq + 1;
    AppStorage.setOrCreate(TAB_REQUEST_KEY, this.tabSeq * TAB_SEQ_BASE + index);
  }

  /**
   * 每日卡点击（对位 openCard）：
   *   sl 卡（每日一图）→ 发射详情页，带 launchId + net
   *   apod / epic    → 图片详情页（src 非空才有图可看）
   */
  private openDailyCard(item: DailyCardItem): void {
    if (item.type === 'sl' && item.launchId.length > 0) {
      Nav.pushLaunch(new LaunchNavParam(item.launchId, item.net, item.title));
      return;
    }
    if (item.src.length > 0) {
      Nav.pushPhoto(new PhotoNavParam(item.src, item.title));
      return;
    }
    this.logAction('每日卡无可跳目标 type=' + item.type, item.title);
  }

  /**
   * 「更多图片」（对位 moreImgs）。
   *
   * 小程序三类各进 gallery-all 的不同分类（image / astro / earth）；
   * 鸿蒙侧没有 gallery-all 这个分类浏览器页，图库主 tab 只有「精选 / NASA」两段，
   * 所以统一切到「图库」tab。**不是逐字节复刻**，只保证点了有去处；
   * 等 GalleryView 补上分类段（或在广播里带上子分类）再细分。
   */
  private openDailyMore(item: DailyCardItem): void {
    this.logAction('更多图片 → 图库 tab type=' + item.type, item.title);
    this.requestTab(TAB_GALLERY);
  }

  private openLaunch(item: LaunchSummary): void {
    const id: string = strOf(item.id);
    if (id.length === 0) {
      this.logAction('下次发射缺 id，无法跳详情', strOf(item.net));
      return;
    }
    const title: string = this.launchTitleOf(item);
    Nav.pushLaunch(new LaunchNavParam(id, strOf(item.net), title));
  }

  /** 任务名口径与小程序一致：mission.nameZh || mission.name，兜底 item.name */
  private launchTitleOf(item: LaunchSummary): string {
    const mission = item.mission;
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

  /** 「更多发射」→ 切到「发射」tab（对位 goFeed → switchTab('/pages/index/index')） */
  private openLaunchList(): void {
    this.logAction('更多发射 → 发射 tab', '');
    this.requestTab(TAB_LAUNCH);
  }

  private openHistory(item: OnThisDayItem): void {
    const id: string = strOf(item.id);
    if (id.length === 0) {
      this.logAction('往年今日缺 id，无法跳详情', strOf(item.name));
      return;
    }
    const zh: string = strOf(item.nameZh);
    const title: string = zh.length > 0 ? zh : strOf(item.name);
    Nav.pushLaunch(new LaunchNavParam(id, strOf(item.net), title));
  }

  /**
   * 资讯详情：把列表里那条新闻整条摊进入参，详情页就不再拉一次全量 news.json。
   * 鸿蒙侧没有内置浏览器，详情页只提供复制链接，不提供「打开原文」。
   */
  private openNews(item: NewsItem): void {
    const p: ArticleNavParam = new ArticleNavParam();
    p.id = item.id.toString();
    p.title = strOf(item.title);
    p.titleZh = strOf(item.titleZh);
    p.summary = strOf(item.summary);
    p.summaryZh = strOf(item.summaryZh);
    p.image = strOf(item.image);
    p.site = strOf(item.site);
    p.url = strOf(item.url);
    p.at = strOf(item.at);
    // launchRefs 在 NewsItem 里是可选的，给空数组兜底，详情页就能直接判 length
    const refs: NewsLaunchRef[] | undefined = item.launchRefs;
    p.launchRefs = refs !== undefined && refs !== null ? refs : [];
    Nav.pushArticle(p);
  }

  private openNewsList(): void {
    Nav.pushNewsList();
  }

  // ============ 交互：刷新与触底 ============

  /** 空态的「重新加载」与下拉刷新走同一条路：七路全 force */
  private reload(): void {
    this.loadAll(true);
  }

  private onRefresh(): void {
    this.refreshing = true;
    this.loadAll(true);
  }

  /**
   * 触底（对位 onReachBottom → news.loadMore()）。
   *
   * 只发信号不自增条数：NewsSection 才知道步长与上限，它自己夹到 list.length。
   * 到底之后继续触底也无害（expand 里已到底则不动）。
   */
  private onReachBottom(): void {
    this.newsGrow = this.newsGrow + 1;
  }

  // ============ UI ============

  /**
   * 顶部日期行。
   * 小程序 .nav-row 里只有这一行 .nav-date（38rpx/600），没有副标题 ——
   * 之前多出的「每日一览 · 下次发射 · 往期回顾」是自创，已删。
   * padding-right 180rpx 是给微信胶囊让位，鸿蒙没有胶囊，故不留。
   */
  @Builder
  dateRow() {
    Text(this.today)
      .fontSize(19) // 38rpx ÷ 2
      .fontWeight(FontWeight.Bold)
      .fontColor('#FFFFFF')
      .letterSpacing(0.5) // 1rpx ÷ 2
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({ top: 12, bottom: 12 })
  }

  /**
   * 整页空态（today.vue:165-173）。
   * 文案随 loading 变；转圈期间不画按钮，避免点了重复请求。
   */
  @Builder
  emptyBlock() {
    Column() {
      Text('🛰️')
        .fontSize(36) // 72rpx ÷ 2
        .margin({ bottom: 10 }) // 20rpx ÷ 2

      Text(this.loading ? '正在拉取今日数据…' : '今天的数据还没准备好')
        .fontSize(13) // 26rpx ÷ 2
        .fontColor('#6B7891')
        .lineHeight(21) // 1.6 倍
        .textAlign(TextAlign.Center)

      if (!this.loading) {
        Row() {
          Text('重新加载')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor('#0A0E17')
        }
        .padding({ left: 24, right: 24, top: 8, bottom: 8 }) // 48rpx / 16rpx
        .backgroundColor('#38BDF8')
        .borderRadius(20) // 40rpx ÷ 2
        .margin({ top: 14 }) // 28rpx ÷ 2
        .onClick(() => {
          this.reload();
        })
      }
    }
    .width('100%')
    .padding({ top: 80, bottom: 80, left: 20, right: 20 })
    .alignItems(HorizontalAlign.Center)
  }

  /** 底部让位块：胶囊浮在列表之上，留一块空白比给 List 加 padding-bottom 可靠 */
  @Builder
  bottomSpacer() {
    Column().width('100%').height(BOTTOM_PAD)
  }

  /**
   * 内容区。
   *
   * 用 List 而不是 Scroll：onReachEnd 是 List 的原生能力（工程里 GalleryGrid /
   * LaunchView / RocketView 都这么用），Scroll 上没有先例、签名也没处查（本机没装 SDK）。
   * 每块内容一个 ListItem，等价于原来的纵向 Column 堆叠。
   */
  @Builder
  contentList() {
    List({ space: 0 }) {
      ListItem() {
        this.dateRow()
      }

      // 每日一览三卡（组件内部空数组即不渲染，不会留空壳）
      ListItem() {
        DailyCards({
          cards: this.dailyCards,
          onOpen: (item: DailyCardItem) => {
            this.openDailyCard(item);
          },
          onMore: (item: DailyCardItem) => {
            this.openDailyMore(item);
          }
        })
      }

      // 下次发射：组件自带「下次发射」标题，取不到时自己出占位块
      ListItem() {
        NextLaunch({
          item: this.nextLaunch(),
          more: true,
          onSelect: (item: LaunchSummary) => {
            this.openLaunch(item);
          },
          onMore: () => {
            this.openLaunchList();
          }
        })
      }

      // 往年今日：自带标题 / 条数 / 折叠入口，空列表整块不渲染（对位 v-if="otd.length"）
      ListItem() {
        OnThisDay({
          list: this.otd,
          onSelect: (item: OnThisDayItem) => {
            this.openHistory(item);
          }
        })
      }

      // 此刻在天上：空名单整块高度 0，不占位
      ListItem() {
        InSpaceRow({
          list: this.astronauts,
          onSelect: (item: AstronautCard) => {
            Nav.pushAstronaut(new AstronautNavParam(String(item.id), strOf(item.name)));
          }
        })
      }

      // 航天资讯：组件只露前 limit 条，「查看全部资讯 ›」跳资讯列表，
      // 触底由上面的 onReachEnd 发信号让它再露一批
      ListItem() {
        NewsSection({
          list: this.news,
          limit: NEWS_LIMIT,
          loading: this.loading,
          growSignal: this.newsGrow,
          onOpen: (item: NewsItem) => {
            this.openNews(item);
          },
          onViewAll: () => {
            this.openNewsList();
          }
        })
      }

      // 四路全空 → 整页空态（位置在最后，与小程序 DOM 顺序一致）
      if (this.isEmpty()) {
        ListItem() {
          this.emptyBlock()
        }
      }

      ListItem() {
        this.bottomSpacer()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(2)
    .onReachEnd(() => {
      this.onReachBottom();
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1 星空底层：绝对定位铺满、不参与命中测试，必须作为 Stack 的第一个子节点
      StarField()

      // 2 内容层：Refresh 包住滚动容器，对位小程序的 enablePullDownRefresh
      Refresh({ refreshing: $$this.refreshing }) {
        this.contentList()
      }
      .width('100%')
      .height('100%')
      .onRefreshing(() => {
        this.onRefresh();
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }
}
