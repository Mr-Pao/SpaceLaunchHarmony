/**
 * pages/Index.ets —— 唯一宿主页（A1 路由架构）
 *
 * 全应用只有一个 @Entry（ArkTS 硬约束：路由栈里每个页面文件各自一个 @Entry，
 * 但本工程所有 tab 都是同一个页面的子视图，所以只有这一个）。
 *
 * 结构：Stack（底部对齐）
 *   ├─ Tabs（隐藏原生 bar，纯做容器 + 生命周期管理）
 *   │    └─ 每个 TabContent 内嵌一个独立 Navigation（各自的 NavPathStack）
 *   └─ FloatingTabBar（悬浮胶囊，浮在 Tabs 之上）
 *
 * 为什么每个 tab 一个独立 NavPathStack（A1 方案）：
 *   小程序 tabBar 的语义是「切 tab 关闭非 tab 页面的栈」。每个 tab 一个栈，
 *   切走时该栈保留（回来还在原详情页），切到别的 tab 时那个 tab 是它自己的栈，
 *   天然复刻了这个行为。如果全应用共用一个栈，切 tab 后还停在上个 tab 的详情页，
 *   与预期不符。
 *
 * 为什么用 Tabs 而不是自己 switch 组件：
 *   1. Tabs 自带 keepAlive —— 切走的 tab 不会被销毁，回来时列表滚动位置、
 *      已加载的数据都还在（原项目小程序 tabBar 也是这个行为）；
 *   2. TabContent 的懒加载是内建的：首次切到某 tab 才 build 它的内容，
 *      冷启动不会一次把五个页面的 aboutToAppear 全执行一遍。
 *
 * ⚠ ArkTS 硬约束：**TabContent 必须是 Tabs 的直接子组件**，
 *   中间不能包 Column / Row / Stack / If / ForEach 任何东西，
 *   否则编译报 "The component 'TabContent' can only be used as a child of 'Tabs'"。
 *   Navigation 包在 TabContent **里面**，不是外面，所以不违反这条。
 */

import { TodayView } from '../view/TodayView';
import { LaunchView } from '../view/LaunchView';
import { GalleryView } from '../view/GalleryView';
import { RocketView } from '../view/RocketView';
import { MineView } from '../view/MineView';
import { FloatingTabBar } from '../components/FloatingTabBar';
import { Nav, ROUTE_LAUNCH, ROUTE_PHOTO, ROUTE_ROCKET, ROUTE_ARTICLE, ROUTE_NEWSLIST, ROUTE_STATS, ROUTE_ASSETS, ROUTE_NEO, ROUTE_EVENTS, ROUTE_FAVORITES, NAV_DETAIL_DEPTH_KEY, ROUTE_ASTRONAUT, ROUTE_SEARCH } from '../routes/Nav';
import { LaunchDetailPage, PhotoDetailPage, RocketDetailPage, ArticleDetailPage, NewsListPage, StatsPage, AssetsPage, NeoPage, EventsPage, FavoritesPage, AstronautPage, SearchPage } from '../routes/DetailPages';
import { LaunchNavParam, PhotoNavParam, RocketNavParam, ArticleNavParam, AstronautNavParam, SearchNavParam } from '../routes/NavParam';

@Entry
@Component
struct Index {
  private tabsController: TabsController = new TabsController();
  @State currentIndex: number = 0;

  /**
   * 详情页层数（由 DetailPages 的 NavDestination.onShown/onHidden 写入）。
   *
   * 为什么需要：详情页 push 在 tab 内部的 Navigation 里，只覆盖 TabContent；
   * 而底部胶囊是 Tabs 的兄弟节点、层级更高，盖不住 —— 详情页打开后胶囊会浮在内容上。
   * 所以层数 >0 时直接把胶囊整个摘掉（不是设透明：透明了还会吃掉点击）。
   */
  @StorageProp(NAV_DETAIL_DEPTH_KEY) detailDepth: number = 0;

  /**
   * 五个 tab 各自的路由栈。
   *
   * 用五个独立成员而不是 `@State stacks: NavPathStack[]`：
   *   1. ArkTS 的 @State 对「对象数组的元素替换」不观察，但这里本来就不需要观察
   *      （栈变化由 Navigation 内部驱动重渲染）；
   *   2. 五个具名成员可读性远好于下标访问，且能直接当 Navigation(this.xxx) 的入参。
   *
   * 不用 @State 修饰：NavPathStack 是引用类型，其内部状态由 Navigation 组件自己
   * 跟踪，外加 @State 只会带来无意义的比较开销。
   */
  private stackToday: NavPathStack = new NavPathStack();
  private stackLaunch: NavPathStack = new NavPathStack();
  private stackGallery: NavPathStack = new NavPathStack();
  private stackRocket: NavPathStack = new NavPathStack();
  private stackMine: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    // 首帧就把「今日」栈交给全局门面，否则第一次点击详情时 Nav.current 还是 null
    Nav.current = this.stackToday;
    // 初始化层数，避免 @StorageProp 拿不到默认值
    AppStorage.setOrCreate(NAV_DETAIL_DEPTH_KEY, 0);
  }

  /** 按索引取栈，供 onChange 同步 Nav.current */
  private stackAt(index: number): NavPathStack {
    if (index === 0) {
      return this.stackToday;
    }
    if (index === 1) {
      return this.stackLaunch;
    }
    if (index === 2) {
      return this.stackGallery;
    }
    if (index === 3) {
      return this.stackRocket;
    }
    return this.stackMine;
  }

  /**
   * 路由分发表：NavPathStack 按 name 找对应页面。
   *
   * param 的类型是 object（NavPathStack 的签名如此），进到各页面前断言成具体 class。
   * 为什么第一阶段就用这张表而不是 route_map.json：
   *   route_map 是编译期生成的静态表，需要额外的 profile 配置与命名规范；
   *   手写 switch 更直观、改起来不用管配置，详情页定型后再考虑迁移。
   */
  @Builder
  PageMap(name: string, param: object) {
    if (name === ROUTE_LAUNCH) {
      LaunchDetailPage(name, param as LaunchNavParam)
    } else if (name === ROUTE_PHOTO) {
      PhotoDetailPage(name, param as PhotoNavParam)
    } else if (name === ROUTE_ROCKET) {
      RocketDetailPage(name, param as RocketNavParam)
    } else if (name === ROUTE_ARTICLE) {
      ArticleDetailPage(name, param as ArticleNavParam)
    } else if (name === ROUTE_NEWSLIST) {
      NewsListPage(name)
    } else if (name === ROUTE_STATS) {
      StatsPage(name)
    } else if (name === ROUTE_ASSETS) {
      AssetsPage(name)
    } else if (name === ROUTE_NEO) {
      NeoPage(name)
    } else if (name === ROUTE_EVENTS) {
      EventsPage(name)
    } else if (name === ROUTE_FAVORITES) {
      FavoritesPage(name)
    } else if (name === ROUTE_SEARCH) {
      SearchPage(name, param as SearchNavParam)
    } else if (name === ROUTE_ASTRONAUT) {
      // 航天员页有入参，必须把 param 一起传下去（其它无参页只传 name 就够）
      AstronautPage(name, param as AstronautNavParam)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
        // —— 以下五个 TabContent 必须与下方 FloatingTabBar 的 items 顺序一致 ——
        TabContent() {
          Navigation(this.stackToday) {
            TodayView()
          }
          .hideTitleBar(true)
          .hideToolBar(true)
          .mode(NavigationMode.Stack)
          .navDestination(this.PageMap)
          .width('100%')
          .height('100%')
        }

        TabContent() {
          Navigation(this.stackLaunch) {
            LaunchView()
          }
          .hideTitleBar(true)
          .hideToolBar(true)
          .mode(NavigationMode.Stack)
          .navDestination(this.PageMap)
          .width('100%')
          .height('100%')
        }

        TabContent() {
          Navigation(this.stackGallery) {
            GalleryView()
          }
          .hideTitleBar(true)
          .hideToolBar(true)
          .mode(NavigationMode.Stack)
          .navDestination(this.PageMap)
          .width('100%')
          .height('100%')
        }

        TabContent() {
          Navigation(this.stackRocket) {
            RocketView()
          }
          .hideTitleBar(true)
          .hideToolBar(true)
          .mode(NavigationMode.Stack)
          .navDestination(this.PageMap)
          .width('100%')
          .height('100%')
        }

        TabContent() {
          Navigation(this.stackMine) {
            MineView()
          }
          .hideTitleBar(true)
          .hideToolBar(true)
          .mode(NavigationMode.Stack)
          .navDestination(this.PageMap)
          .width('100%')
          .height('100%')
        }
      }
      // barHeight(0)：不渲染原生 tabBar，底部导航完全由 FloatingTabBar 接管。
      // 用 0 而不是隐藏，是因为 Tabs 内部仍按 barHeight 做内容区偏移计算
      .barHeight(0)
      // scrollable(false)：禁止左右滑动切 tab。
      // 理由是「图库」「发射」里都有横向滚动的内容（图墙横滑、日期条），
      // 允许滑切会和它们抢手势；小程序版同样只支持点按切换
      .scrollable(false)
      .animationDuration(0)
      .divider({ strokeWidth: 0, color: Color.Transparent })
      .onChange((index: number) => {
        // 切 tab 时把该 tab 的栈设为活跃栈。
        // 两个来源都会走到这里：胶囊点击（主动 changeIndex）与 Tabs 自身变化。
        this.currentIndex = index;
        Nav.current = this.stackAt(index);
      })
      .width('100%')
      .height('100%')

      // 详情页打开时摘掉胶囊：它是 Tabs 的兄弟节点，层级比 TabContent 里的
      // Navigation 高，光靠 zIndex 盖不住 —— 只能整个不渲染。
      if (this.detailDepth === 0) {
        FloatingTabBar({
          currentIndex: this.currentIndex,
          onSelect: (index: number) => {
            this.currentIndex = index;
            Nav.current = this.stackAt(index);
            this.tabsController.changeIndex(index);
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    // 全局底色。整棵树最外层铺满，任何子页留白处露出的都是这个色，
    // 不会出现白色或灰色断层（对位 App.vue 的 page { background-color: #0a0e17 }）
    .backgroundColor('#0a0e17')
  }
}
