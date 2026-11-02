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

import { LaunchNavParam, PhotoNavParam, RocketNavParam, ArticleNavParam } from './NavParam';

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
