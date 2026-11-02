/**
 * entryability/EntryAbility.ets —— 应用入口 Ability
 *
 * 标准模板 + 三件事（相对默认模板的全部改动）：
 *   1) onCreate：fileStore.init(this.context) —— 必须在任何数据调用之前完成，
 *      否则 Repository 拿不到 filesDir，L2 文件缓存会静默退化成「每次都走网络」。
 *   2) onWindowStageCreate：加载 pages/Index + 把窗口底色设成 #0a0e17。
 *   3) 顺手把导航栏/状态栏设成沉浸式，否则默认白色状态栏在深色页头上会很刺眼。
 *
 * 为什么强调窗口底色：
 *   小程序的「白闪」坑（见项目记忆第三节）在鸿蒙上同样存在 ——
 *   startWindowBackground 管的是启动页（已配 $color:start_window_background），
 *   但 ability 首帧渲染到 ArkUI 内容上屏之间有几十毫秒的空窗，
 *   这段时间显示的是**窗口自身背景**，默认是白色。
 *   所以 onWindowStageCreate 里必须显式 setWindowBackgroundColor，
 *   两层都压成 #0a0e17 才真正不会闪。
 */

import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileStore } from '../data/FileStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'EntryAbility';

/** 与 App.vue 的 page background-color 一致 */
const BG_PRIMARY: string = '#0a0e17';

export default class EntryAbility extends UIAbility {
  /**
   * onCreate 早于窗口创建，是唯一能保证「数据层先于 UI 就绪」的时机。
   * 这里只做初始化，不发起任何网络请求 —— 请求一律由各 View 的
   * aboutToAppear 触发，避免冷启动时五个数据集一起抢带宽。
   */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate, windowStage 尚未创建');
    try {
      fileStore.init(this.context);
    } catch (e) {
      // 初始化失败不能让应用起不来：Repository 内部对 fileStore 不可用
      // 是有兜底的（降级为纯内存 + 直连 CDN），这里只记录
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'fileStore.init failed: %{public}s', err.message);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  /**
   * 只在首次冷启动、系统为应用新开窗口时调用；
   * 从后台切回来（onForeground）不会走这里，所以窗口设置放这里不会重复执行。
   */
  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 1) 窗口底色：堵住「启动页退场 → 首帧内容上屏」之间的白窗口
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowBackgroundColor(BG_PRIMARY);

      // 状态栏 / 导航栏沉浸式：内容是深色的，系统栏跟着透出来才连续。
      // `window.getWindowSystemBarProperties` 在 API 12 里是异步的，
      // 这里不 await（不阻塞首帧），失败也只是状态栏颜色不对，不影响功能
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: BG_PRIMARY,
        statusBarContentColor: '#FFFFFF',
        navigationBarColor: BG_PRIMARY,
        navigationBarContentColor: '#FFFFFF'
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', err.message);
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'getMainWindowSync failed: %{public}s', err.message);
    }

    // 2) 加载唯一宿主页
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', err.message);
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
