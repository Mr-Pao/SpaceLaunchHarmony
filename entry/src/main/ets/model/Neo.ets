/**
 * Neo.ets —— 近地天体（未来一周掠过地球的小行星）类型
 *
 * 数据集：neoNears → neo-nears.json，CI 每天 UTC 02:20 抓 NASA NeoWs 的
 * 未来 7 天飞掠窗口，软 TTL 3 小时。线上实测 count 40~56 条，
 * 同一物体在窗口内可能被拆成两条（按「临时编号 + 接近时刻」去重后才入库）。
 *
 * ── 为什么这里处处可选（`?`）──
 * 写入端 scripts/neo.js 的字段是逐个挑出来赋值的，上游 NeoWs 某天缺
 * `estimated_diameter`、缺 `relative_velocity` 都很常见；缺了就不写这个键，
 * 于是 JSON 里干脆没有该字段。声明成必填会让页面在 undefined 上做算术，
 * 拿到的是 NaN，最后在界面上显示 "NaN LD" —— 比显示 "—" 难看得多。
 *
 * ── 三个容易误读的字段 ──
 *   1. `lunar` 是地月距离（LD），不是公里；`wkm` 才是与地球最近距离（万公里）。
 *      两个量的量级差 40 倍，混用会写出「最近 140 万公里」这种离谱数字。
 *   2. `haz`（PHA，潜在威胁小行星）**不等于会撞击地球**：判定阈值是
 *      「轨道最小交点距离 < 0.05 AU 且绝对星等 H < 22」，只是「值得持续观测」。
 *      所以小程序侧从不用警示红色，本页也只用琥珀色 chip。
 *   3. `sentry` 才是真正进了 JPL Sentry 风险表的，但它在本周窗口里几乎恒为
 *      false（线上实测 0 条），chip 保留只为将来真的出现时不漏报。
 *
 * 类型名统一加 `Ne` 前缀：ArkTS 没有命名空间，model 目录下的类型全在同一个
 * 全局作用域里，重名会直接编译失败（禁声明合并）。
 */

import { BasePayload } from './Common';

/**
 * 一条近地天体飞掠记录。
 *
 * 时间字段有两个，别混：
 *   at      → ISO 时刻 "2026-11-02T01:06:00.000Z"（分组判定用，必须 Date.parse）
 *   atShort → "11-02 09:06"（已按北京时间格式化好，列表直接用，不要再算一遍）
 *
 * 为什么 atShort 由 CI 生成而不是前端算：小程序与鸿蒙两端的时区处理必须完全一致，
 * 各自 new Date 会因运行时差异（尤其设备时区非东八区）分叉出一个小时。
 */
export interface NeItem {
  /** JPL 小天体编号，如 "3790060"；同一编号可能在本窗口出现两条（不同接近时刻） */
  id: string;
  /** 带括号的官方名，如 "(2017 WP28)" */
  name: string;
  /** 去括号的展示名 "2017 WP28"，列表标题用它 */
  disp: string;
  /** 接近时刻，ISO 8601（UTC） */
  at: string;
  /** 北京时间短格式 "MM-DD HH:mm"，已格式化，直接用 */
  atShort: string;
  /** 地月距离（LD，1 LD ≈ 38.44 万公里）。可能是小数，展示保留一位 */
  lunar?: number;
  /** 与地球最近距离（万公里）。量级上千，展示取整 + 千分位 */
  wkm?: number;
  /**
   * 相对速度 km/s。
   * ⚠ 上游偶尔给字符串（"19.57"），所以类型写成联合，
   * 消费端一律 Number() 兜底后再判 NaN —— 直接 toFixed 会拿到 "NaN"。
   */
  vkms?: number | string;
  /** 直径下限（米） */
  dmin?: number;
  /** 直径上限（米）。NeoWs 只给区间不给确定值 */
  dmax?: number;
  /** 视星等。同上，可能是字符串 */
  mag?: number | string;
  /** 潜在威胁小行星（PHA）。**不是**撞击预警，见文件头第 2 点 */
  haz?: boolean;
  /** 是否进了 JPL Sentry 风险表（本周窗口内实测恒 false） */
  sentry?: boolean;
  /** JPL 小天体查询页链接。本项目没有浏览器权限，只做「复制」 */
  jpl?: string;
}

/**
 * 窗口区间。
 *
 * 线上 v14 实测是 `{start: "2026-10-28", end: "2026-11-04"}`，但任务书要求
 * 防御式读取（历史上 CI 可能直接写字符串），所以这里同时给出 from/to 别名，
 * 并在 payload 里允许 `string` 联合类型 —— 页面只用它做副标题之外的诊断，
 * 拿不到也完全不影响主流程，因此不做运行时解析。
 */
export interface NeWindow {
  start?: string;
  end?: string;
  from?: string;
  to?: string;
}

/**
 * 窗口内最接近的那一条（CI 已挑好，前端不需要再遍历求最小）。
 *
 * 实测是精简对象 `{disp, at, lunar, dmax}`，**没有 id 也没有 wkm** ——
 * 这正是为什么它不能直接当 NeItem 用：字段是子集，多出来的字段不存在，
 * 声明成 NeItem 会在取 vkms / jpl 时拿到 undefined。
 */
export interface NeClosest {
  id?: string;
  disp?: string;
  at?: string;
  lunar?: number;
  dmax?: number;
}

/**
 * neoNears 载荷。
 *
 * `count` 是**本次窗口内的条数**，不是 totalKnown：
 *   totalKnown → 人类已知近地天体总数（实测 6 万余，一直在涨）
 *   count      → 未来 7 天掠过地球的条数（实测 40~56）
 *   pastCount  → 其中「已经过去」的条数（窗口跨过今天，前半段已成历史）
 * 概览卡的三格分别取 totalKnown / count / hazardous，别拿 count 冒充总数。
 */
export interface NePayload extends BasePayload {
  dataset?: string;
  /** 已知近地天体总数，展示要加千分位 */
  totalKnown?: number;
  /** 本窗口内条数 */
  count?: number;
  /** 其中潜在威胁（PHA）条数 */
  hazardous?: number;
  /** 窗口内已经掠过的条数 */
  pastCount?: number;
  /** 窗口区间，可能是对象也可能是字符串，见 NeWindow 注释 */
  window?: NeWindow | string;
  /** 最接近的那一条，可能缺失 */
  closest?: NeClosest;
  /** 逐条数据，CI 已按接近时间升序排好 —— 前端不再排序，分组时保持原序 */
  list: NeItem[];
}
