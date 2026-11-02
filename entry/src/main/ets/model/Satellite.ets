/**
 * model/Satellite.ets —— 「太空资产」三个数据集的类型与解析工具
 *
 * 覆盖：
 *   orbitStats   → orbit-stats.json   在轨物体聚合统计（无逐条 list）
 *   satellites   → satellites.json    卫星目录「索引 + 第 0 片」，后续片走 satellites/N.json
 *   debrisEvents → debris-events.json 在轨解体 / 再入事件流
 *
 * 字段全部照抄线上 v14 实测样本（2026-11-02 直接拉 COS 核对），不做任何改名。
 * 上游写入端：scripts/gcat.js（satellites / orbit-stats / debris-events 三份产物）。
 *
 * ── 为什么类型名统一加 Sa 前缀 ──
 *   ArkTS 的 interface 是**全局扁平**的（同一模块内不能重名，跨模块同名会在
 *   跨文件引用时产生歧义），而 view/RocketDetailView.ets 已经导出了
 *   `RkLaunchersPayload` 等一批 Rk 前缀类型。这里用 Sa 前缀是为了让
 *   「太空资产」这一族类型在任何地方 import 都不会撞名 —— 曾经因为两个文件
 *   各写一个 `Kv`，编译期直接报 duplicate identifier。
 *
 * ── 为什么 byDecade 单独一个 SaKvNum ──
 *   byState / byOrbit / byClass 的 k 是**字符串**（"美国" / "近地轨道" / "载荷"），
 *   而 byDecade 的 k 是**数字**（1950 / 1960 …）。ArkTS 不允许把 number 塞进
 *   `k: string`，也不允许用 `string | number` 做索引签名，更不能用声明合并去扩展
 *   同一个 interface，所以只能老老实实拆成两个两字段的 interface。
 *
 * ── 为什么 perigee / apogee / inc / mass 是 string ──
 *   上游 GCAT 是定宽文本格式，这三个字段原样落了字符串（"254" / "97.28"），
 *   空值落的是**空串**而不是 null / 0。直接当数字用会在空串上得到 NaN，
 *   塞进 Text 就会显示 "NaN" 甚至 "undefined"。所以这里保留 string 声明，
 *   需要数值时一律走 saNumOf()，需要展示时走 saDash() / saThousand()。
 *
 * ⚠ 本文件不使用 console.*，也不写 @Component —— 只放类型与纯函数。
 */

// ============ 分布项 ============

/**
 * 键值分布项，键是字符串。
 *
 * 线上样本（orbit-stats.json 的 byState 第 0 项）：{ "k": "美国", "v": 18278 }
 * byState 20 项 / byOrbit 10 项 / byClass 4 项，均已按 v 降序。
 */
export interface SaKv {
  k: string;
  v: number;
}

/**
 * 键值分布项，键是数字。
 *
 * 线上样本（byDecade）：{ "k": 1950, "v": 13 }
 * 共 8 项（1950 ~ 2020），按 k 升序。
 */
export interface SaKvNum {
  k: number;
  v: number;
}

// ============ satellites 逐条 ============

/**
 * 卫星目录条目（GCAT 活跃子集，实测 20109 条 / 26 片 × 800）。
 *
 * 注意 `alt` 不是高度而是「替代名 / 所属批次」（Starlink Group 17-41-01），
 * 真正的高度在 perigee / apogee（字符串）。两者语义不同，别混用。
 */
export interface SaItem {
  /** 内部 id，形如 "S69296"，列表 key 用它 */
  id: string;
  /** COSPAR 卫星编目号，形如 "69296" */
  satcat: string;
  /** 国际编号，形如 "2026-119A" */
  intl: string;
  /** 卫星名，形如 "Starlink 37501" */
  name: string;
  /** 替代名 / 所属批次，形如 "Starlink Group 17-41-01" */
  alt: string;
  /** 发射日期，GCAT 原始格式 "2026 May 30"（**不是 ISO**，别喂给 new Date） */
  launch: string;
  /** 再入日期，在轨物体为空串 */
  reentry: string;
  /** GCAT 行号，排序 / 去重时的稳定次键 */
  rkey: number;
  /** 状态码（"O" = 在轨），原始英文码 */
  status: string;
  /** 状态中文（"在轨"） */
  statusZh: string;
  /** 类别码（"P" = 载荷） */
  cls: string;
  /** 类别中文（"载荷" / "箭体" / "碎片"） */
  clsZh: string;
  /** 归属机构码（"SPXS"） */
  owner: string;
  /** 归属机构中文（"SpaceX"） */
  ownerZh: string;
  /** 国家 / 地区码（"US"） */
  state: string;
  /** 国家 / 地区中文（"美国"） */
  stateZh: string;
  /** 轨道码（"LLEO/S"） */
  orbit: string;
  /** 轨道中文（"近地低轨(太阳同步)"） */
  orbitZh: string;
  /** 近地点高度（**字符串**，可能是空串） */
  perigee: string;
  /** 远地点高度（**字符串**，可能是空串） */
  apogee: string;
  /** 倾角（**字符串**，可能是空串） */
  inc: string;
  /** 质量 kg（**字符串**，可能是空串 —— 上游大部分条目没有质量数据） */
  mass: string;
}

// ============ debrisEvents 逐条 ============

/**
 * 解体 / 再入事件（实测 1600 条，其中 breakupCount 条是解体）。
 *
 * 这条流的线索来自 GCAT 的「再入 + 解体」两类记录，字段比 satItem 精简，
 * 没有高度 / 质量，所以不复用 SaItem。
 */
export interface SaDebrisItem {
  id: string;
  name: string;
  /** 国际编号 */
  intl: string;
  /** 再入日期（解体事件里是解体发生的日期） */
  reentry: string;
  rkey: number;
  /** "reentry" 或 "breakup" —— Tab C 的三段筛选就按它分 */
  kind: string;
  status: string;
  statusZh: string;
  state: string;
  stateZh: string;
  orbitZh: string;
  clsZh: string;
}

// ============ 载荷 ============

/**
 * 在轨统计（orbit-stats.json）。
 *
 * 线上样本：
 *   { "v":14, "dataset":"orbit-stats", "generatedAt":"...", "total":34925,
 *     "list":[], "byState":[...20], "byOrbit":[...10], "byClass":[...4], "byDecade":[...8] }
 *
 * `list` **恒为空数组**，是 CI 沿用统一信封时留下的占位键 —— 别拿它当数据源。
 * 因此这里声明成可选：将来上游若真的删掉这个键，页面也不会因为断言失败而崩。
 */
export interface SaOrbitStatsPayload {
  v: number;
  dataset?: string;
  generatedAt?: string;
  /** 在轨物体总数（34925） */
  total?: number;
  /** 恒为 []，别用 */
  list?: SaItem[];
  byState?: SaKv[];
  byOrbit?: SaKv[];
  byClass?: SaKv[];
  byDecade?: SaKvNum[];
}

/**
 * 解体再入事件流（debris-events.json）。
 *
 * 线上样本：
 *   { "v":14, "dataset":"debris-events", "generatedAt":"...",
 *     "count":1600, "breakupCount":N, "list":[1600 条] }
 */
export interface SaDebrisPayload {
  v: number;
  dataset?: string;
  generatedAt?: string;
  count?: number;
  breakupCount?: number;
  list?: SaDebrisItem[];
}

// ============ 纯函数工具 ============
//
// 放这里的理由：解析口径只应该有一份。Tab A/B/C 三个面板都要格式化数字，
// 各写一份必然漂移（一边处理了空串、另一边没处理，线上立刻出现 NaN）。

/**
 * 把「可能为空的字符串数字」转成 number。
 *
 * 三种输入都要能吃：
 *   "254"      → 254
 *   ""         → 0     （GCAT 里大量字段是空串）
 *   "12.5abc"  → 0     （脏数据不往下传 NaN）
 *
 * 参数类型放宽到 string | undefined | null：调用方传的是 interface 上的必填
 * string，但运行时缺字段就是 undefined，这里统一兜住，免得每个调用点都写判断。
 */
export function saNumOf(raw: string | undefined | null): number {
  if (raw === undefined || raw === null) {
    return 0;
  }
  const text: string = raw.trim();
  if (text.length === 0) {
    return 0;
  }
  const n: number = Number(text);
  // Number("12.5abc") 是 NaN，Number("") 是 0（已被上面的长度判断拦掉）
  return Number.isNaN(n) ? 0 : n;
}

/**
 * 千分位数字：34925 → "34,925"。
 *
 * 为什么不用 toLocaleString：ArkTS 的 Number.toLocaleString 在不同 ROM 上
 * 分组符不一样（有的是窄空格），视觉会飘。手写死逗号最稳。
 */
export function saThousand(n: number): string {
  if (!Number.isFinite(n)) {
    return '0';
  }
  const neg: boolean = n < 0;
  const digits: string = Math.round(Math.abs(n)).toString();
  let out: string = '';
  let count: number = 0;
  // 从个位往前扫，每三位补一个逗号，最后拼成顺序
  for (let i = digits.length - 1; i >= 0; i--) {
    out = digits.charAt(i) + out;
    count++;
    if (count % 3 === 0 && i > 0) {
      out = ',' + out;
    }
  }
  return neg ? '-' + out : out;
}

/** 年代标签：1950 → "1950s"（byDecade 的 k 是数字，展示要带 s） */
export function saDecadeLabel(k: number): string {
  const year: number = Number.isNaN(k) ? 0 : Math.round(k);
  return year.toString() + 's';
}

/**
 * 造一个字符串键分布项。
 *
 * ArkTS 禁止无类型对象字面量直接当值（`{ k: x, v: y }` 会报
 * "Object literal must correspond to some explicitly declared class or interface"），
 * 所以先声明类型再赋值。byDecade → 展示用 SaKv 的转换全靠它。
 */
export function saKvOf(k: string, v: number): SaKv {
  const row: SaKv = { k: k, v: v };
  return row;
}

/** 空串显示成破折号，避免第二行出现 "69296 ·  · 美国" 这种双分隔符 */
export function saDash(text: string): string {
  return text.length > 0 ? text : '—';
}

/**
 * 取前 n 条（n <= 0 或超过长度时返回整份的浅拷贝）。
 *
 * 为什么不用 slice：ArkTS 的 Array.slice 在部分版本上返回的是 Object[]，
 * 断言回 T[] 要多一层 `as Object as`，封装一次省掉所有调用点的噪音。
 */
export function saTake<T>(list: T[], n: number): T[] {
  const out: T[] = [];
  const limit: number = n > 0 && n < list.length ? n : list.length;
  for (let i = 0; i < limit; i++) {
    out.push(list[i]);
  }
  return out;
}

/**
 * 把若干段拼成 "a · b · c"，空段自动跳过。
 *
 * 第二行元信息的固定写法，三个面板共用，保证分隔符口径一致。
 */
export function saJoin(parts: string[]): string {
  let out: string = '';
  for (let i = 0; i < parts.length; i++) {
    const part: string = parts[i];
    if (part.length === 0) {
      continue;
    }
    out = out.length === 0 ? part : out + ' · ' + part;
  }
  return out;
}
