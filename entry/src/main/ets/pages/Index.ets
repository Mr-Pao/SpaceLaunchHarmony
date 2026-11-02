/**
 * pages/Index.ets —— 唯一宿主页
 *
 * 全应用只有一个 @Entry（ArkTS 硬约束：路由栈里每个页面文件各自一个 @Entry，
 * 但本工程所有 tab 都是同一个页面的子视图，所以只有这一个）。
 *
 * 结构：Stack（底部对齐）
 *   ├─ Tabs（隐藏原生 bar，纯做容器 + 生命周期管理）
 *   └─ FloatingTabBar（悬浮胶囊，浮在 Tabs 之上）
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
 */

import { TodayView } from '../view/TodayView';
import { LaunchView } from '../view/LaunchView';
import { GalleryView } from '../view/GalleryView';
import { RocketView } from '../view/RocketView';
import { MineView } from '../view/MineView';
import { FloatingTabBar } from '../components/FloatingTabBar';

@Entry
@Component
struct Index {
  private tabsController: TabsController = new TabsController();
  @State currentIndex: number = 0;

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
        // —— 以下五个 TabContent 必须与下方 FloatingTabBar 的 items 顺序一致 ——
        TabContent() {
          TodayView()
        }

        TabContent() {
          LaunchView()
        }

        TabContent() {
          GalleryView()
        }

        TabContent() {
          RocketView()
        }

        TabContent() {
          MineView()
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
        // 双保险：FloatingTabBar 点击时已同步过一次，这里接住
        // controller 被外部（如将来 deep link）改变的情况
        this.currentIndex = index;
      })
      .width('100%')
      .height('100%')

      FloatingTabBar({
        currentIndex: this.currentIndex,
        onSelect: (index: number) => {
          this.currentIndex = index;
          this.tabsController.changeIndex(index);
        }
      })
    }
    .width('100%')
    .height('100%')
    // 全局底色。整棵树最外层铺满，任何子页留白处露出的都是这个色，
    // 不会出现白色或灰色断层（对位 App.vue 的 page { background-color: #0a0e17 }）
    .backgroundColor('#0a0e17')
  }
}
