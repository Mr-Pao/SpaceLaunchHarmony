/**
 * Event.ets —— 「近期活动」类型（EVA / 轨道插入 / 飞船对接 等航天事件）
 *
 * 数据集：events.json（CDN 前缀 space-data，TTL 30 分钟），
 * 写入端是 CI 的 scripts/sync.js 拉 LL2 的 events 接口后瘦身。
 * 线上实测 count = 26，字段清单已按真实返回逐条核对。
 *
 * ── 三个字段只有「实测过外壳」，内部结构未知 ──
 *   type     可能是 { id, name, abbrev } 对象，也可能直接是字符串
 *   location 同上（可能是空间站名 / 天体 / 发射场，三种语义混在一个字段里）
 *   launches 可能是数组（元素形如 { id, name, net }），也可能缺失
 * 这三个**一律用联合类型 + 空值判断**读取，绝不按猜测的字段名硬取：
 * 拿不到就是空串，调用端据此整块不画。统一走 evRefName()，
 * 是对象就取 name、取不到再退 abbrev，是字符串就直接用。
 *
 * ── 为什么不用 any / Object 兜底 ──
 * ArkTS 禁 any，且 `JSON.parse(...) as EvPayload` 只是编译期断言、
 * 运行时不做校验。所以「防御」只能落在读取处：字段声明成可选 + 联合类型，
 * 读的时候先判 typeof，再判空串 —— 这样即使上游某天把 type 从对象改成字符串，
 * 页面也只是少一行字，不会崩。
 *
 * ── 为什么这个文件不 import utils/Format 的 strOf ──
 * model 层保持零依赖（其它 model/*.ets 都只 import './Common'），
 * 免得将来 Format 反过来依赖某个 model 时踩成循环引用。代价是下面多一个三行的 evStr。
 */

import { BasePayload } from './Common';

/** null / undefined → 空串。与 utils/Format 的 strOf 同语义，这里自带一份见文件头 */
export function evStr(v: string | null | undefined): string {
  return v !== undefined && v !== null ? v : '';
}

/**
 * 活动「类型 / 地点」的两种可能形态。
 *
 * 只有 name / abbrev 是实测确认存在的键（type 的 id 是数字、也可能没有）；
 * 不写 nameZh —— 那是猜的，真没有就省一次无效读取。
 */
export interface EvRef {
  id?: number | string;
  /** 英文全称，如 "Orbital Insertion" / "Spacecraft Docking" */
  name?: string;
  /** 缩写，如 "EVA"。英文全称取不到时用它顶上 */
  abbrev?: string;
}

/**
 * 活动关联的发射。
 *
 * 未实测到确切结构，只按 LL2 的通用形状声明这几个键；**读取端必须判空数组**。
 * 当前列表卡片按设计稿不画这一块，留着给详情页 / 后续改版用。
 */
export interface EvLaunchRef {
  id?: string | number;
  name?: string;
  nameZh?: string;
  /** 发射时刻 ISO；跳发射详情要靠它，没有就进不去 */
  net?: string;
}

/**
 * 一条活动。
 *
 * 注意 id 是 **number**（实测 1567 这种），不是字符串 —— 原项目里
 * 用 `item.id == null` 判空，鸿蒙侧同理，别拿 `''` 当空。
 */
export interface EvItem {
  /** LL2 的活动 id，数字 */
  id: number;
  /** 英文名，如 "US EVA-101" */
  name: string;
  /** 中文名，可能空串 → 前端回退 name */
  nameZh?: string;
  /** 活动时刻，ISO 8601（带 Z）。**排序与「未来 / 已结束」判定全靠它** */
  date: string;
  /** 英文长文，实测含 \r\n，直接进 Text 会出现凌乱换行，渲染前必须压平成空格 */
  description?: string;
  /** 中文长文，可能空串 → 回退英文 */
  descriptionZh?: string;
  /** 头图 URL，实测可能是 null / 空串 / 不存在的地址（要接 onError） */
  feature_image?: string | null;
  /** 活动类型，见文件头「防御式读取」 */
  type?: EvRef | string | null;
  /** 活动地点（空间站 / 天体 / 发射场），见文件头「防御式读取」 */
  location?: EvRef | string | null;
  /** 关联发射，见 EvLaunchRef 注释 */
  launches?: EvLaunchRef[] | null;
}

/** events 载荷信封。list 必在，其余头字段上游可能缺 */
export interface EvPayload extends BasePayload {
  dataset?: string;
  /** 上游给的总条数（实测 26），与 list.length 在分页场景可能不同 */
  count?: number;
  /** 本次实际下发条数 */
  served?: number;
  list: EvItem[];
}

/**
 * 把 type / location 这种「对象或字符串」的字段读成一个可显示的名字。
 *
 * 判定顺序：字符串直接用 → 对象的 name → 对象的 abbrev → 空串。
 * 取不到时返回空串而不是「未知」之类的占位词：调用端用长度判断要不要画这一块，
 * 硬塞占位词会让一屏卡片里全是「未知」，比不显示更糟。
 */
export function evRefName(v: EvRef | string | null | undefined): string {
  if (v === undefined || v === null) {
    return '';
  }
  // 有实测样本证明可能是纯字符串，必须先走一遍字符串分支，否则下面读 .name 恒为 undefined。
  // 两处 as 都是显式落类型：ArkTS 对「interface | string」联合的窄化不如 tsc 彻底，
  // 直接赋值容易报「不能把联合类型赋给 EvRef」，显式 as 后编译器的推断路径更确定。
  if (typeof v === 'string') {
    return (v as string).trim();
  }
  const ref: EvRef = v as EvRef;
  const name: string = evStr(ref.name).trim();
  if (name.length > 0) {
    return name;
  }
  return evStr(ref.abbrev).trim();
}

/** 卡片标题：中文名优先，空串回退英文（与项目其它页的 nameZh || name 同口径） */
export function evTitle(item: EvItem): string {
  const zh: string = evStr(item.nameZh).trim();
  return zh.length > 0 ? zh : evStr(item.name).trim();
}

/** 卡片摘要原文：中文优先，空串回退英文。**不做换行处理**（那是视图层的事） */
export function evDesc(item: EvItem): string {
  const zh: string = evStr(item.descriptionZh).trim();
  return zh.length > 0 ? zh : evStr(item.description).trim();
}
