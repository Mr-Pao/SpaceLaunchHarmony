/**
 * Launch.ets —— 发射相关类型
 *
 * 覆盖第一阶段要用的三个数据集：upcoming / previous / onthisday
 * （upcomingMore 与 upcoming 同构，共用 LaunchSummary，不另立类型）。
 *
 * 字段全部按线上 v14 真实样本来写：
 *   launches-upcoming.json  473 条 / launched-previous.json 7658 条，28 个键，两者完全同构
 *   onthisday.json          item 只有 11 个键，且 status / rocket / agency / site 是扁平字符串
 *
 * 写入端：scripts/lib/slim.js 的 slimLaunch() / scripts/lib/onthisday.js 的 normalize()
 */

import { BasePayload, LaunchSummary } from './Common';

/**
 * 转发 LaunchSummary。
 *
 * 为什么不在这里重新声明一遍：两个文件各写一份同名 interface 会立刻产生漂移
 * （改字段只改一边，另一个文件静默不同步，编译器也不会报）。定义放 Common.ets，
 * 这里只做 re-export，让 `import { LaunchSummary } from '../model/Launch'`
 * 与从 './Common' 导入完全等价。
 *
 * 万一某版本的 ArkTS 不接受 re-export 这种写法，退路只有一条：
 * 调用方改成从 './Common' 直接导入，然后删掉这一行 ——
 * 本文件其余定义全部依赖上面那条 import，删掉 re-export 不影响编译。
 */
export { LaunchSummary } from './Common';

// ============ 载荷 ============

/**
 * 即将发射（upcoming）。
 *
 * 线上样本：
 *   { "v":14, "dataset":"launches-upcoming", "generatedAt":"2026-11-02T03:12:11.000Z",
 *     "count":473, "served":100, "list":[...] }
 *
 * `served` 是本次实际下发条数（首页只取前 100 条），用它与 count 比较判断
 * 「还有更多」（剩余部分在 upcomingMore 里）。
 */
export interface UpcomingPayload extends BasePayload {
  dataset?: string;
  /** 全量待发总数 */
  count?: number;
  /** 本次下发的条数，通常 100 */
  served?: number;
  list: LaunchSummary[];
}

/**
 * 历史发射（previous）。
 *
 * 线上样本 count=7658、served=100，字段与 UpcomingPayload 完全一致，
 * 单独起名只是为了在页面代码里一眼看出语义、以及将来给历史专属字段留位置。
 */
export interface PreviousPayload extends BasePayload {
  dataset?: string;
  count?: number;
  served?: number;
  list: LaunchSummary[];
}

/** 即将发射的第 100 条之后（upcomingMore）。结构与 UpcomingPayload 相同，rocketBrief 恒为 null */
export interface UpcomingMorePayload extends BasePayload {
  dataset?: string;
  count?: number;
  served?: number;
  list: LaunchSummary[];
}

// ============ 往年今日 ============

/**
 * 往年今日的一条记录。
 *
 * 与 LaunchSummary 差别很大，**不要混用**：
 *   - 只有 11 个字段，没有图片/窗口/统计
 *   - status / rocket / agency / site 都是**扁平字符串**，不是对象
 *     （slim.js 的 slimLaunch 把它们做成嵌套对象，onthisday 的 normalize() 则是拍平的）
 *   - 用 `y` 单独存年份，net 仍是完整 ISO 时间
 *   - 图片字段叫 `img`（不是 image），署名叫 `credit`
 *
 * 写入端 scripts/lib/onthisday.js 的 normalize() 会 delete 掉 `md`（月-日）字段，
 * 所以这里没有 md。
 */
export interface OnThisDayItem {
  id: string;
  name: string;
  /** 任务中文名，CI 回填 */
  nameZh?: string;
  /** ISO 8601 发射时刻 */
  net: string;
  /** 年份（2026 表示这是今年的那次） */
  y: number;
  /** 状态名（扁平字符串，如 "Launch Successful"） */
  status?: string;
  /** 火箭名（扁平字符串） */
  rocket?: string;
  /** 发射机构名（扁平字符串） */
  agency?: string;
  /** 发射场名（扁平字符串） */
  site?: string;
  /** 图片地址 */
  img?: string;
  /** 图片署名 */
  credit?: string;
}

/**
 * 往年今日载荷。CI 按「月-日」筛好，最多 40 条（全量 7656 条前端筛要 2MB 起步）。
 */
export interface OnThisDayPayload extends BasePayload {
  dataset?: string;
  count?: number;
  served?: number;
  list: OnThisDayItem[];
}
