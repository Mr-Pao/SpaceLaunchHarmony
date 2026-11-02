/**
 * view/TodayView.ets —— 「今日」tab（1:1 复刻 pages/today/today.vue）
 *
 * 结构（自上而下，全部压在 StarField 星空层之上）：
 *   顶部日期行 → 每日一览三卡（sl / apod / epic 横滑，DailyCards 自带轮播）→
 *   「下次发射」大卡（含秒级倒计时，NextLaunch 自带标题）→
 *   「往年今日」→「此刻在天上」→「航天资讯」（limit=3）→ 底部 padding 92vp。
 *
 * 注意：五个子组件**各自带区块标题**（17vp Bold 白 + 11vp 灰副标题），
 * 页面这一层不再重复画「下次发射 / 往年今日 / 此刻在天上 / 航天资讯」这四个标题，
 * 否则会标题叠标题。页内只保留顶部日期行这一处自绘文本。
 *
 * 数据链路（语义与 utils/data.js 的 load 对齐：谁先到谁先渲染，不 Promise.all 等齐）：
 *   gallery            → 过滤 thumb 非空 → pickDaily(list, daySeed(Date.now())) 选每日一图
 *   astronautsInspace  → 过滤 inSpace → 按 days 降序
 *   upcoming(onUpdate) → next() 取「net 非空且时刻 > now」的最早一条
 *   onthisday(onUpdate)→ 透传 OnThisDay
 *   apod(onUpdate)     → 取 list[0]（滤掉 NASA 的降级占位脏数据）
 *   epic(onUpdate)     → 取 list[0]
 *   news(onUpdate)     → 透传 NewsSection（组件只吃 list，所以由页面拉）
 * 每一路各自 catch，一路失败只影响自己，不拖垮整页。
 *
 * ── 相对任务书的取舍/偏差（逐条写清，方便复核）──
 *   1. **多了一路 news 加载**。任务书写「6 路各自独立 load」，但 NewsSection 的契约是
 *      `@Prop list: NewsItem[]`（组件自己不取数，见 components/NewsSection.ets:47-55），
 *      不拉 news 这一块永远空着。故按第 7 路独立加载，同样自带 catch、同样接 onUpdate。
 *   2. **apod 多一道脏数据过滤**。小程序 applyApod() 会丢掉 title === 'NASA Science'
 *      以及命中 `/wp-content/themes/` 的地址（nasa-daily 降级时的占位响应）。
 *      照抄会让「每日天文」卡变成破图，故保留这道过滤，其余取 [0] 的口径不变。
 *   3. **无路由**。全工程没有 router / Navigation / NavDestination，回调无处跳转；
 *      onOpen / onMore / onSelect / onViewAll 一律 hilog 记一条 + TODO 注释，
 *      等宿主层接上路由后把 logAction(...) 换成真实跳转即可。
 *   4. **每日一图用缩略图**（对位 dailyCards 的 `src: d.thumb`）。小程序在 photo-detail
 *      里才升到 fullImageOf 原图，鸿蒙侧还没有详情页，首屏就该用几十 KB 的缩略图。
 *   5. **三卡顺序按任务书 sl → apod → epic**。today.vue 的注释写的是
 *      「sl → epic → apod」但代码实际按 pushed 顺序是 sl → apod → epic（today.vue:312-338），
 *      两者一致，按代码口径。
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

const DOMAIN: number = 0x0000;
const TAG: string = 'TodayView';

/** 页面底色（与 Index.ets / EntryAbility 的窗口底色同一值，避免首帧色差） */
const BG_PRIMARY: string = '#0A0E17';

/**
 * 时钟节拍：30 秒一次。
 * 只服务 next() 的重算 —— 倒计时本身由 Countdown 组件内部每秒自转，
 * 页面不该每秒 rebuild 一次整棵子树。
 */
const TICK_MS: number = 30000;

/**
 * 底部内边距：悬浮胶囊让位。
 *
 * 胶囊本体 58 + 底部 margin 20 = 78，再加胶囊下方那层渐变遮罩的渐入高度
 * （FloatingTabBar 里 padding.top 28）。原先只留 92，滚到底时「往年今日」的
 * 最后一条会被胶囊压掉半行（2026-11-02 截图确认），改成 120 留出余量。
 */
const BOTTOM_PAD: number = 120;

/** 页面左右内边距（任务书视觉规范 12vp） */
const PAGE_PAD: number = 12;

/** 资讯首屏条数（任务书要求 limit=3） */
const NEWS_LIMIT: number = 3;

/**
 * 独立加载的路数。
 * 6 路（gallery/astronauts/upcoming/onthisday/apod/epic）+ 1 路 news = 7，
 * 全部结束后才把 loading 置 false（只影响顶部那句「正在加载…」）。
 */
const LOAD_TOTAL: number = 7;

/** apod 降级占位响应的识别特征（见文件头「取舍 2」） */
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

  /** 30 秒一拍的时钟，next() 用它判断「还没发射」 */
  @State nowTick: number = Date.now();
  /** 顶部日期行文案（「11月2日 星期日」）。跨零点时随 tick 一起更新 */
  @State today: string = todayLabel();
  /** 是否还在等数据（只用于顶部副标题文案，不挡渲染） */
  @State loading: boolean = true;

  /** 图库（已过滤 thumb 非空） */
  @State gallery: GalleryItem[] = [];
  /** 在轨宇航员（已过滤 inSpace，已按 days 降序） */
  @State astronauts: AstronautCard[] = [];
  /** 待发射列表（全量 100 条，next() 每次只挑一条） */
  @State upcoming: LaunchSummary[] = [];
  /** 往年今日 */
  @State otd: OnThisDayItem[] = [];
  /** 每日天文（通常 1 条；保留数组是为了与 onUpdate 回填结构一致） */
  @State apod: ApodItem[] = [];
  /** 每日地球 */
  @State epic: EpicItem[] = [];
  /** 资讯（NewsSection 自己只做「露几条」的折叠，数据由页面给） */
  @State news: NewsItem[] = [];

  /** 交给 DailyCards 的三张卡（sl → apod → epic）。@State 整体替换才能触发重绘 */
  @State dailyCards: DailyCardItem[] = [];

  // ============ 私有成员（不参与渲染） ============

  private scroller: Scroller = new Scroller();
  /** 30 秒节拍器句柄。-1 表示没在跑 */
  private tickTimer: number = -1;
  /** 还没结束的加载路数 */
  private pending: number = 0;

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

  /** 一路收尾：全部结束才关 loading */
  private settle(): void {
    this.pending = this.pending - 1;
    if (this.pending <= 0) {
      this.pending = 0;
      this.loading = false;
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

  /**
   * apod：接 onUpdate。
   * force 分支本身不回传，但命中缓存时 onUpdate 才能把后台刷新的结果补上屏。
   */
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

  /** news：见文件头「取舍 1」，组件不吃网络，必须页面拉 */
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
   * 过滤规则见文件头「取舍 2」。
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

  /** a 优先，空则退 b（对应原写的 `x.titleZh || x.title`） */
  private firstOf(a: string | undefined, b: string | undefined): string {
    const va: string = strOf(a);
    if (va.length > 0) {
      return va;
    }
    return strOf(b);
  }

  /**
   * 重建三张每日卡，顺序固定 sl → apod → epic。
   *
   * 三路数据谁后到都要重算一次（缩略图那路可能最慢），所以这里是幂等的：
   * 每次都从当前 @State 全量拼一遍，再整体替换数组。
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
    // 构造器只有 7 个参数，发射定位字段写后赋值（与今日页 openPhoto 的入参对应）
    card.launchId = strOf(daily.id);
    card.net = strOf(daily.net);
    cards.push(card);
  }

  /** 每日天文：只取 [0]；正文直接进 desc（小程序把它收进了 intro 详情层） */
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
      this.firstOf(x.explanationZh, x.explanation),
      thumb.length > 0 ? thumb : strOf(x.full),
      strOf(x.credit)
    );
    cards.push(card);
  }

  /** 每日地球：date 只留 YYYY-MM-DD（数据里可能带时刻），标题与署名写死 */
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
      this.firstOf(x.captionZh, x.caption),
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

  // ============ 交互（A1 路由：直接调全局 Nav 门面） ============

  private logAction(action: string, key: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s key=%{public}s', action, key);
  }

  /**
   * 每日卡点击：
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
   * 「更多图片」：同样进看图器。
   *
   * 小程序这里进的是图库对应分类（apod → nasa tab，epic → earth tab）；
   * 鸿蒙侧图库页还没做，先统一落到看图器，等 GalleryView 成型再改成切 tab。
   */
  private openDailyMore(item: DailyCardItem): void {
    if (item.src.length > 0) {
      Nav.pushPhoto(new PhotoNavParam(item.src, item.title));
      return;
    }
    this.logAction('每日卡更多图片无图 type=' + item.type, item.title);
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

  /**
   * 「更多发射」：本应切到「发射」tab。
   *
   * 切 tab 是宿主 Index 的能力，子视图拿不到 TabsController；
   * 第一阶段先不接（保留日志），等 Index 暴露 onSwitchTab 回调再接上。
   */
  private openLaunchList(): void {
    this.logAction('打开发射列表（待宿主提供 onSwitchTab）', '');
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
   * 小程序侧因未配业务域名，web-view 打不开、只能「复制链接」；鸿蒙侧同理没有内置浏览器，
   * 所以详情页不提供「打开原文」，只提供复制。
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
    // launchRefs 在 NewsItem 里是可选的，这里给空数组兜底，详情页就能直接判 length
    const refs: NewsLaunchRef[] | undefined = item.launchRefs;
    p.launchRefs = refs !== undefined && refs !== null ? refs : [];
    Nav.pushArticle(p);
  }

  private openNewsList(): void {
    Nav.pushNewsList();
  }

  // ============ UI ============

  /** 顶部日期行：19vp Bold 白 + 11vp 灰副标题（与 LaunchView / GalleryView 的页头同档） */
  @Builder
  dateRow() {
    Column() {
      Text(this.today)
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(0.5)

      Text(this.loading ? '正在加载今日数据…' : '每日一览 · 下次发射 · 往期回顾')
        .fontSize(11)
        .fontColor('#6B7891')
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 12, bottom: 12 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1 星空底层：绝对定位铺满、不参与命中测试，必须作为 Stack 的第一个子节点
      StarField()

      // 2 内容层
      Scroll(this.scroller) {
        Column() {
          this.dateRow()

          // 每日一览三卡（组件内部空数组即不渲染，不会留空壳）
          DailyCards({
            cards: this.dailyCards,
            onOpen: (item: DailyCardItem) => {
              this.openDailyCard(item);
            },
            onMore: (item: DailyCardItem) => {
              this.openDailyMore(item);
            }
          })

          // 下次发射：component 自带「下次发射」标题，取不到时自己出占位块
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

          // 往年今日：自带标题 / 条数 / 折叠，空列表出空态块
          OnThisDay({
            list: this.otd,
            onSelect: (item: OnThisDayItem) => {
              this.openHistory(item);
            }
          })

          // 此刻在天上：空名单整块高度 0，不占位
          // 点某位在轨航天员 → 详情页。id 是 number，统一 String() 一次再进路由
          InSpaceRow({
            list: this.astronauts,
            onSelect: (item: AstronautCard) => {
              Nav.pushAstronaut(new AstronautNavParam(String(item.id), strOf(item.name)));
            }
          })

          // 航天资讯：组件只露前 limit 条，「查看全部 ›」回调给宿主
          NewsSection({
            list: this.news,
            limit: NEWS_LIMIT,
            onOpen: (item: NewsItem) => {
              this.openNews(item);
            },
            onViewAll: () => {
              this.openNewsList();
            }
          })
        }
        .width('100%')
        // 左右 12vp 页面内边距 + 底部 92vp 胶囊让位
        .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }
}
