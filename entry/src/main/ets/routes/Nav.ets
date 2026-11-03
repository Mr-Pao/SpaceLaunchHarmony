/**
 * routes/Nav.ets —— 全局导航门面
 *
 * 设计动机：
 *   A1 方案下每个 tab 有一个独立的 NavPathStack，但子视图（TodayView 等）
 *   不该知道自己是挂在哪条栈上的。所以由 Index.ets 在切 tab 时把「当前活跃栈」
 *   写进 Nav.current，子视图只调 Nav.pushLaunch(...) 这类无参门面。
 *
 * 为什么用静态类而不是单例对象：
 *   ArkTS 对模块级可变状态支持有限，`export class Nav { static ... }` 是
 *   官方示例里最常用的写法，不需要 new，也不会有实例生命周期问题。
 *
 * 注意：这里只做「转发」，不做任何 UI。所有跳转最终都落在 NavPathStack 上。
 */

import { LaunchNavParam, PhotoNavParam, RocketNavParam, ArticleNavParam, AstronautNavParam, AgencyNavParam, PadNavParam, VideoNavParam, SearchNavParam, StationNavParam, ExpeditionNavParam, EventNavParam, MediaNavParam } from './NavParam';

/** 路由名常量 —— 与 Index.ets 的 PageMap 必须严格一致 */
export const ROUTE_LAUNCH: string = 'launchDetail';
export const ROUTE_PHOTO: string = 'photoDetail';
export const ROUTE_ROCKET: string = 'rocketDetail';
export const ROUTE_ARTICLE: string = 'articleDetail';
/** 资讯列表页。它与 ROUTE_ARTICLE 是两个独立的页：列表 → 详情还能再压一层 */
export const ROUTE_NEWSLIST: string = 'newsList';

/**
 * 「我的 → 探索」四个功能页的路由名。
 *
 * 这四页都不需要入参（数据全从 COS 拉、各按自己的数据集加载），
 * 所以走同一个 pushBlank(name) 门面而不是各写一个 push。
 * 对位小程序：pages/stats、pages/space-assets、pages/neo、pages/event。
 */
export const ROUTE_STATS: string = 'statsPage';
export const ROUTE_ASSETS: string = 'assetsPage';
export const ROUTE_NEO: string = 'neoPage';
export const ROUTE_EVENTS: string = 'eventsPage';

/**
 * 收藏清单页。
 *
 * 与上面四页同样无入参（数据来自本机 preferences，不碰网络），
 * 所以也走 pushBlank。单独声明而不是复用某个常量：路由名是持久化契约，
 * 将来给收藏页加入参时不会连带影响其它页。
 */
export const ROUTE_FAVORITES: string = 'favoritesPage';

/**
 * 航天员详情页。
 *
 * 有入参（id + 姓名），所以不能走 pushBlank；单独声明常量 + 独立 push 方法。
 */
export const ROUTE_ASTRONAUT: string = 'astronautDetail';

/** 机构详情 / 工位详情 / 视频库。三者都有入参，各走独立 push 方法 */
export const ROUTE_AGENCY: string = 'agencyDetail';
export const ROUTE_PAD: string = 'padDetail';
export const ROUTE_VIDEOS: string = 'videoGallery';
/** 型号媒体库（图片库 / 视频库）。与 ROUTE_VIDEOS 不同：那个是全局视频列表，这个是按型号聚合 */
export const ROUTE_MEDIA: string = 'mediaGallery';

/** 全局搜索页。入参只有初始关键词，走 pushSearch */
export const ROUTE_SEARCH: string = 'searchPage';

/**
 * 空间站列表 / 空间站详情 / 远征队详情 / 活动详情。
 *
 * 空间站列表无入参（走 pushBlank），后三个各带 id、走独立 push。
 * 这四页都不是「我的 → 探索」的直系入口，而是从航天员页、活动列表页、
 * 空间站详情互相跳转过去的二三级页面。
 */
export const ROUTE_STATIONS: string = 'stationsList';
export const ROUTE_STATION: string = 'stationDetail';
export const ROUTE_EXPEDITION: string = 'expeditionDetail';
export const ROUTE_EVENT: string = 'eventDetail';

/**
 * 版本记录页。
 *
 * 无入参（数据是编译期常量 constants/Changelog.ets），走 pushBlank。
 * 单独声明而不是复用别的常量：它与「我的」页里那几格在语义上无关，
 * 只是恰好都没有入参。
 */
export const ROUTE_VERSION: string = 'versionPage';

/**
 * 详情页层数写进 AppStorage 用的 key。
 * Index.ets 用 @StorageProp 订阅它，>0 时把底部悬浮胶囊整个摘掉。
 */
export const NAV_DETAIL_DEPTH_KEY: string = 'nav_detail_depth';

export class Nav {
  /** 当前活跃 tab 的路由栈。Index.ets 在 onChange 与首次 onAppear 时写入 */
  static current: NavPathStack | null = null;

  /**
   * 当前压了几层详情页。
   *
   * 为什么需要它：详情页 push 在 **tab 内部**的 Navigation 里，只覆盖 TabContent
   * 那一块；而底部悬浮胶囊是 Index.ets 里 Tabs 的兄弟节点，层级更高、永远盖不住 ——
   * 结果就是详情页打开后胶囊还浮在内容上（实测截图确认）。
   *
   * 为什么用 NavDestination 的 onShown/onHidden 计数，而不是在 push/pop 门面里加减：
   * 系统返回手势、物理返回键都不经过 Nav.pop，只在门面里加减会漏、越用越偏。
   */
  private static detailDepth: number = 0;

  static markDetailShown(): void {
    Nav.detailDepth = Nav.detailDepth + 1;
    AppStorage.setOrCreate(NAV_DETAIL_DEPTH_KEY, Nav.detailDepth);
  }

  static markDetailHidden(): void {
    Nav.detailDepth = Nav.detailDepth > 0 ? Nav.detailDepth - 1 : 0;
    AppStorage.setOrCreate(NAV_DETAIL_DEPTH_KEY, Nav.detailDepth);
  }

  /** 跳到发射详情 */
  static pushLaunch(param: LaunchNavParam): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_LAUNCH, param);
  }

  /** 跳到图片详情（看图器） */
  static pushPhoto(param: PhotoNavParam): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_PHOTO, param);
  }

  /** 跳到火箭详情 */
  static pushRocket(param: RocketNavParam): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_ROCKET, param);
  }

  /**
   * 跳到资讯详情。
   *
   * 入参是「整个 NewsItem 摊平后的 ArticleNavParam」，不是 id ——
   * 详情页因此不需要再拉一次全量 news.json，点开即渲染。
   */
  static pushArticle(param: ArticleNavParam): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_ARTICLE, param);
  }

  /** 跳到资讯列表（首页「查看全部 ›」的落点） */
  static pushNewsList(): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_NEWSLIST, null);
  }

  /**
   * 跳到航天员详情。
   *
   * AstronautCard.id 是 number，这里统一 String() 一次再进路由 ——
   * 详情页内部只做字符串比较，入口收敛一处，避免两边都转。
   */
  static pushAstronaut(param: AstronautNavParam): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_ASTRONAUT, param);
  }

  /** 机构详情 */
  static pushAgency(param: AgencyNavParam): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_AGENCY, param);
  }

  /** 工位详情 */
  static pushPad(param: PadNavParam): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_PAD, param);
  }

  /** 空间站列表（无入参） */
  static pushStations(): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_STATIONS, null);
  }

  /** 空间站详情 */
  static pushStation(param: StationNavParam): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_STATION, param);
  }

  /** 远征队详情 */
  static pushExpedition(param: ExpeditionNavParam): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_EXPEDITION, param);
  }

  /** 活动详情 */
  static pushEvent(param: EventNavParam): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_EVENT, param);
  }

  /** 视频库。launchId 为空串 = 看全量 */
  /**
   * 打开型号媒体库。`tab` 0=图片库 1=视频库。
   *
   * 小程序是从 launch-hero / rocket.vue 的 goMedia(tab) 进，传 config.id；
   * 鸿蒙侧全工程只有名字可用（RocketNavParam 也只有 name），故传名字。
   */
  static pushMedia(name: string, tab: number): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_MEDIA, new MediaNavParam(name, tab));
  }

  static pushVideos(launchId: string): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_VIDEOS, new VideoNavParam(launchId));
  }

  /** 全局搜索。kw 为空串 = 进页后只显示「能搜什么」的引导 */
  static pushSearch(kw: string): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(ROUTE_SEARCH, new SearchNavParam(kw));
  }

  /**
   * 跳到「我的 → 探索」里的无参页面。
   *
   * 四个功能页共用这一个门面：它们的入参只有「自己是谁」，
   * 参数已经编码在 routeName 里，没有额外要传的业务数据。
   * 传 null 而不是空对象 —— NavPathStack 对 null 有专门处理，空对象反而不合法。
   */
  static pushBlank(routeName: string): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pushPathByName(routeName, null);
  }

  /** 返回上一页。栈为空时什么都不做（根页不能 pop） */
  static pop(): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.pop();
  }

  /** 清空当前栈回到根（切 tab 时不需要，Tabs 自己保活；留给「回到首页」用） */
  static clear(): void {
    const stack: NavPathStack | null = Nav.current;
    if (stack === null) {
      return;
    }
    stack.clear();
  }
}
