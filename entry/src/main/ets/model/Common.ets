/**
 * Common.ets —— 全数据集共用的公共类型
 *
 * 字段来源：线上 COS 实际产出的 v14 数据（2026-11-02 抓样），
 * 以及 CI 侧写入端的 scripts/lib/slim.js、scripts/news.js、scripts/nasa-daily.js。
 * 凡是上游可能缺的字段一律标 `?`。
 *
 * ArkTS 约束：只写 interface / type / const，不写 @Component；
 * 不使用 any、不使用索引签名（`[key: string]: T`）。
 */

/**
 * 所有数据 JSON 的外层信封（载荷头）。
 *
 * 线上样本形如：
 *   { "v": 14, "dataset": "launches-upcoming", "generatedAt": "2026-11-02T...", "count": 473, "served": 100, "list": [...] }
 *
 * 注意 `served` 不是每个数据集都有（只有发布类的分页快照带），因此可选。
 */
export interface BasePayload {
  /** 数据结构版本，对应 DATA_VERSION（当前 14） */
  v: number;
  /** ISO 时间；后台刷新时用它判断「线上有没有更新」，只有变了才回填页面 */
  generatedAt: string;
}

/**
 * 带 list 的载荷。绝大多数数据集都是这个形状。
 *
 * 泛型在 ArkTS 里可用，但 interface 上的泛型参数在 JSON.parse 断言时需要显式写出，
 * 所以这里保留泛型、由各具体载荷（UpcomingPayload 等）给 T 填好。
 */
export interface ListPayload<T> extends BasePayload {
  /** 数据集名，CI 写入；旧数据可能没有 */
  dataset?: string;
  /** 条目数，多数数据集有 */
  count?: number;
  /** 本次实际下发的条数（发布类快照带，用于「还有更多」判断） */
  served?: number;
  list: T[];
}

/**
 * 发射摘要 —— 今日页、发射列表页、搜索页、收藏页都用同一份。
 *
 * 这就是 slim.js 的 slimLaunch() 的产出（upcoming / previous / upcomingMore
 * 三个数据集字段完全一致，实测 473 / 7658 条同构，共 28 个键）。
 * 详情页在此基础上额外用 rocketBrief 与 rocket.configuration。
 *
 * 字段命名刻意保留 LL2 / slim.js 的 snake_case（imageThumb、full_name、
 * window_start …），不改成驼峰：一是与线上 JSON 一一对应，断言零成本；
 * 二是将来对照 CI 脚本排查时不用做心算转换。
 */
export interface LaunchSummary {
  /** LL2 的 UUID */
  id: string;
  name: string;
  /** 发射时刻，ISO 8601（No Earlier Than，可能被推迟） */
  net: string;

  // ---- 图片 ----
  /** 主图（已镜像到自家 COS） */
  image?: string;
  /** 缩略图。刻意与 image 同源同值，镜像时命中同一份产物 */
  imageThumb?: string;
  /** 图片署名 */
  imageCredit?: string;
  /** 图片名，当图注用 */
  imageName?: string;
  /** 任务信息图（竖版长图） */
  infographic?: string;

  // ---- 状态 ----
  status?: LaunchStatus;

  // ---- 火箭（normal 模式只有名字） ----
  rocket?: LaunchRocket;
  /**
   * 火箭技术参数（长度 / 推力 / LEO / GTO / 造价…），由 CI 用 launchers.json
   * 按 config id 回填，前端零额外请求。
   *
   * **upcomingMore 里恒为 null**（那 376 条不做 enrich，省流量），
   * 所以这里必须可选且允许 null。
   */
  rocketBrief?: RocketBrief | null;

  // ---- 任务 ----
  mission?: LaunchMission;
  /** 发射概率（0-100 整数）。LL2 只有部分任务填，null 表示没有预报 */
  probability?: number | null;
  /** 天气顾虑，英文长句 */
  weather_concerns?: string;
  /** 天气顾虑中文，CI 回填；翻不出来为空串，前端回退英文 */
  weather_concernsZh?: string;
  /** 失败原因，只有历史失败任务有 */
  failreason?: string;
  failreasonZh?: string;

  // ---- 发射方 ----
  launch_service_provider?: LaunchProvider;

  /**
   * 发射工位（对应 slim.js:145 的 pad 对象）。
   *
   * upcoming / previous 带全套（含镜像后的 image / map_image）；
   * upcomingMore 不镜像图片，但对象键仍然存在。所以语义是「键必有、
   * 图片字段可能缺」。
   */
  pad?: LaunchPad;

  // ---- 发射窗口 ----
  /** 窗口起点。窗口可能有几小时，只给 net 会让用户以为整点发射 */
  window_start?: string;
  window_end?: string;

  // ---- LL2 直接给的累计次数（详情页「统计概览」六格） ----
  orbital_launch_attempt_count?: number | null;
  orbital_launch_attempt_count_year?: number | null;
  agency_launch_attempt_count?: number;
  agency_launch_attempt_count_year?: number;
  pad_launch_attempt_count?: number;
  pad_launch_attempt_count_year?: number;

  /**
   * 视频清单。
   *
   * TODO 需真实数据确认：线上 v14 的 launches-upcoming.json / launches-previous.json
   * 实测**已无 vid 字段**（旧 dist 快照 v11 里有 `vid: []`），但
   * utils/media.js:134 与 scripts/verify-pure.js:519 仍在消费 vid 数组 ——
   * 说明它要么在其它数据集的记录上、要么已随某次 slim 改动被移除。
   * 这里按可选字段保留，避免详情页媒体模块改结构；消费端必须先判空。
   */
  vid?: LaunchVideoRef[];
}

/** 发射状态。状态是固定枚举，中文由 CI 本地查表写入，不走翻译接口 */
export interface LaunchStatus {
  name: string;
  abbrev: string;
  /** 中文状态名，CI 写入（对应 slim.js 的 statusZh） */
  nameZh?: string;
}

/** 发射所用火箭 —— normal 模式只有名字，参数在 rocketBrief 里 */
export interface LaunchRocket {
  configuration: RocketConfig;
}

export interface RocketConfig {
  /** LL2 数字 id；slim 里是 `c.id ?? null`，可能为 null */
  id?: number | null;
  name: string;
  full_name?: string;
  /** 型号（Block 5 / A / B 这种） */
  variant?: string;
  /** 所属系列（Falcon / Long March），slim 里最多取 2 个 */
  families?: string[];
}

/**
 * 火箭技术参数精简对象，对应 scripts/lib/enrich.js 的 BRIEF_KEYS（20 个键）+ desc。
 *
 * 注意：toBrief() 会**跳过值为 undefined / null / 空串的键**，
 * 所以这 20 个字段除了 name 之外都可能缺席 → 全部可选。
 */
export interface RocketBrief {
  id?: number;
  name?: string;
  variant?: string;
  active?: boolean;
  reusable?: boolean;
  min_stage?: number;
  max_stage?: number;
  length?: number;
  diameter?: number;
  launch_mass?: number;
  to_thrust?: number;
  leo_capacity?: number;
  gto_capacity?: number;
  launch_cost?: number | null;
  maiden_flight?: string;
  manufacturer?: string;
  image?: string;
  wiki_url?: string;
  info_url?: string;
  /** 简介，按 260 字截断并补省略号 */
  desc?: string;
}

export interface LaunchMission {
  /** 载荷名，如 "Starlink Group 15-16" */
  name?: string;
  /** 任务名中文，CI 回填；空串表示没翻出来，前端回退 name */
  nameZh?: string;
  description?: string;
  descriptionZh?: string;
  /** 任务类型（Communications / Earth Science …） */
  type?: string;
  orbit?: OrbitInfo;
}

export interface OrbitInfo {
  name?: string;
  abbrev?: string;
}

export interface LaunchProvider {
  id?: number | null;
  name: string;
}

/**
 * 发射工位。
 *
 * TODO 需真实数据确认：`map_image` 只在 upcoming / previous 两个数据集里做镜像
 * （见 slim.js 注释），upcomingMore 与 publish 快照可能没有该键。
 */
export interface LaunchPad {
  name?: string;
  latitude?: number | null;
  longitude?: number | null;
  image?: string;
  imageThumb?: string;
  imageCredit?: string;
  imageName?: string;
  map_image?: string;
  total_launch_count?: number;
  location?: PadLocation;
}

export interface PadLocation {
  name?: string;
  total_launch_count?: number;
}

/**
 * 视频条目（vid 数组元素）。
 *
 * TODO 需真实数据确认：按 utils/media.js 的读取路径整理，v14 线上样本里未观察到，
 * 字段可能不全或有别名，接入媒体页时必须先用真实数据核对一遍。
 */
export interface LaunchVideoRef {
  url?: string;
  title?: string;
  publisher?: string;
  /** 直播 / 回放 / 转播 */
  kind?: string;
  /** 视频源 id */
  tid?: string;
  cover?: string;
  /** 开始时刻 */
  start?: string;
  /** 时长（分钟） */
  mins?: number;
  live?: boolean;
  /** 镜像到自家 COS 后的地址 */
  cosUrl?: string;
  /** 是否可内联播放 */
  playable?: boolean;
  sourceType?: string;
  priority?: number;
}

/**
 * 页面跳转参数。原项目用 query 串传，鸿蒙侧建议统一成这个结构。
 *
 * `from` 是来源页标识，用于详情页的「返回」文案与分享路径（对应原项目
 * pages/launch/launchInfo 的 from 参数）。
 */
export interface NavParam {
  id: string;
  from?: string;
}
