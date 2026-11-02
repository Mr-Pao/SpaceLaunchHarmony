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

import { LaunchNavParam, PhotoNavParam, RocketNavParam } from './NavParam';

/** 路由名常量 —— 与 Index.ets 的 PageMap 必须严格一致 */
export const ROUTE_LAUNCH: string = 'launchDetail';
export const ROUTE_PHOTO: string = 'photoDetail';
export const ROUTE_ROCKET: string = 'rocketDetail';
export const ROUTE_ARTICLE: string = 'articleDetail';

export class Nav {
  /** 当前活跃 tab 的路由栈。Index.ets 在 onChange 与首次 onAppear 时写入 */
  static current: NavPathStack | null = null;

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
