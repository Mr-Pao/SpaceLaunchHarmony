/**
 * model/Station.ets —— 空间站类型（spacestations.json）
 *
 * 数据集：spacestations.json（CDN 前缀 space-data，TTL 12 小时），
 * 写入端是 CI 的 scripts/sync.js 拉 LL2 的 space stations 接口后瘦身。
 * 线上实测 count = 15，**list 也只有 15 条**（不是分页快照），字段清单按真实返回逐条核对：
 *   id / name / status / type / founded / deorbited / orbit / height / width /
 *   mass / volume / onboardCrew / docked / img / desc / descZh / owners / crew / expeditions
 *
 * ── 三处「字段存在但内容全空」的实测结论（决定了页面怎么画）──
 *   1. img：15 条全部是空串 → 列表缩略图与详情 Hero **一定**走无图占位，不能省。
 *   2. owners[].cc / owners[].logo：实测也是空串 → 不画国旗、不加载 logo。
 *   3. crew：15 条全部是空数组 → 详情页没有「在站航天员」这一块可画。
 *   只有 owners[].name / abbrev 有内容，所以机构卡只靠这两个字段。
 *
 * ── expeditions 内嵌字段与 expeditions.json 不是同一个东西 ──
 *   这里每条只有 { id, name, start, end }（没有 crew / patches），
 *   大多数站是空数组，ISS 与天宫各 1 条。所以详情页的「远征队」卡只列名字与起止，
 *   点进去要看完整名录得由父级跳独立页（本组件只发 onOpenExpedition 回调）。
 *
 * ── 为什么这个文件不 import utils/Format 的 strOf ──
 *   model 层保持零依赖（其它 model/*.ets 都只 import './Common'），
 *   免得将来 Format 反过来依赖某个 model 时踩成循环引用。代价是下面多一个三行的 stnStr。
 *
 * ArkTS 约束：只写 interface / type / const 与纯函数，不写 @Component。
 * 新增类型统一加 Stn 前缀（避免与 model/Common.ets 或其它页的局部类型重名合并）。
 */

import { BasePayload } from './Common';

/** null / undefined → 空串。与 utils/Format 的 strOf 同语义，这里自带一份见文件头 */
export function stnStr(v: string | null | undefined): string {
  return v !== undefined && v !== null ? v : '';
}

/** undefined / null → 0。数值字段用来判「>0 才画这一格」，绝不能让 NaN 漏下去 */
export function stnNum(v: number | null | undefined): number {
  return v !== undefined && v !== null ? v : 0;
}

/**
 * 所属机构。
 *
 * 实测 cc 与 logo 都是空串，但仍声明成可选：上游哪天补上，
 * 读取端只要判空就能多画一面旗，不需要再改类型。abbrev 有内容
 * （NASA / Roscosmos / CNSA 这种），是机构卡第二行的灰字。
 */
export interface StnOwner {
  /** 机构英文全称，如 "National Aeronautics and Space Administration" */
  name?: string;
  /** 缩写，如 "NASA"；实测有值 */
  abbrev?: string;
  /** 两位国家码；**实测 15 条全为空串**，不要按有值写 */
  cc?: string;
  /** logo 地址；**实测全为空串** */
  logo?: string;
}

/**
 * 在站航天员。
 *
 * **实测 15 条全部是空数组**，所以当前没有任何页面会渲染出内容。
 * 类型仍按上游可能的结构声明（id / name / role / agency / img），
 * 但视图层不做这块 UI —— 做了必然是一个空块。
 */
export interface StnCrew {
  id?: number;
  name?: string;
  role?: string;
  agency?: string;
  img?: string;
}

/** 空间站内嵌的远征队条目（字段比 expeditions.json 少，见文件头） */
export interface StnExpedition {
  id?: number;
  /** 形如 "Expedition 74"；展示前过 expeditionName() 变「第 74 次远征」 */
  name?: string;
  /** ISO 或短日期，可能为空 */
  start?: string;
  /** 空串 = 进行中（实测 3 条这样的记录） */
  end?: string;
}

/**
 * 一座空间站。
 *
 * 注意 id 是 **number**（4 = ISS，18 = 天宫），路由参数是字符串，
 * 比对时统一 String(id) === stationId，别拿数字直接和字符串比。
 * 除了 id / name / list 本身，其余字段一律可选：JSON.parse 只是编译期断言，
 * 运行时上游少给一个键不能让页面崩在 `undefined.length` 上。
 */
export interface StnItem {
  /** LL2 的数字 id */
  id: number;
  /** 英文名，如 "International Space Station"；展示前过 stationName() 中文化 */
  name: string;
  /** 'Active' | 'Decommissioned' | 'De-Orbited' 等；视图层负责补映射 */
  status?: string;
  /** 'Government' | 'Commercial' */
  type?: string;
  /** 成立/发射日期，形如 "1998-11-20" */
  founded?: string;
  /** 退役/再入日期；空串表示仍在役 */
  deorbited?: string;
  /** 轨道原文，如 'Low Earth Orbit'；展示前过 orbitName() */
  orbit?: string;
  /** 高度（米） */
  height?: number;
  /** 宽度（米） */
  width?: number;
  /** 质量（吨） */
  mass?: number;
  /** 加压体积（m³） */
  volume?: number;
  /** 在轨人数 */
  onboardCrew?: number;
  /** 对接飞船数 */
  docked?: number;
  /** 主图；**实测 15 条全为空串**，无图占位是常态而不是兜底 */
  img?: string;
  /** 英文长文，可能含 \r\n，进 Text 前要压平 */
  desc?: string;
  /** 中文长文；没有时回退 desc */
  descZh?: string;
  /** 所属机构；name / abbrev 有值，cc / logo 为空 */
  owners?: StnOwner[];
  /** 在站航天员；**实测全为空数组** */
  crew?: StnCrew[];
  /** 内嵌远征队；大多数为空数组 */
  expeditions?: StnExpedition[];
}

/**
 * spacestations 载荷信封。
 *
 * 实测顶层：{ v, dataset, generatedAt, count, served, list }。
 * count 与 list.length 在这份数据里都是 15，但仍分开声明：
 * 分页快照的语义下两者可以不等，展示「N 座」时应以 list.length 为准。
 */
export interface StnPayload extends BasePayload {
  /** 数据集名，CI 写入 */
  dataset?: string;
  /** 上游报的总条数 */
  count?: number;
  /** 本次实际下发条数 */
  served?: number;
  list: StnItem[];
}

// ============ 展示口径（两个视图共用，避免各写一份而漂移） ============

/**
 * 状态文案：站内自带一张小表，覆盖 spacestations.json 实测出现的三种取值
 * （'Active' / 'Decommissioned' / 'De-Orbited'）。
 *
 * 为什么不用 utils/Format 的 stationStatusZh：
 *   1) 它只认 'Active' / 'Retired' / 'Under Construction'，实测数据里的
 *      'Decommissioned' 与 'De-Orbited' 会被原样返回英文，中文页上蹦出英文很刺眼；
 *   2) model 层保持零依赖（见文件头），从 model 反向 import utils 会把这层约定打破。
 *   表里没有的取值原样返回：新枚举显示原文，比显示空白强。
 *
 * 为什么放在 model 而不是各自视图里：列表页与详情页用的是同一份枚举，
 * 抄两份迟早会出现「列表写已停用、详情写已退役」的分叉。
 */
const STN_STATUS_ZH: Map<string, string> = new Map<string, string>([
  ['Active', '在役'],
  ['Decommissioned', '已停用'],
  ['De-Orbited', '已再入大气层'],
  ['Retired', '退役'],
  ['Under Construction', '建造中']
]);

export function stnStatusText(status: string | undefined | null): string {
  const raw: string = stnStr(status).trim();
  if (raw.length === 0) {
    return '';
  }
  const hit: string | undefined = STN_STATUS_ZH.get(raw);
  return hit !== undefined ? hit : raw;
}

/** 是否在役（只有 Active 算；其余一律按「已退出」压灰，包括空值） */
export function stnIsActive(status: string | undefined | null): boolean {
  return stnStr(status).trim() === 'Active';
}

/**
 * 类型中文化：'Government' → 政府，'Commercial' → 商业。
 *
 * 实测只有这两个取值；将来上游加新枚举就原样显示，
 * 总比显示成空白或者「未知」强（「未知」在参数表里更像数据缺失）。
 */
export function stnTypeText(type: string): string {
  const raw: string = stnStr(type).trim();
  if (raw === 'Government') {
    return '政府';
  }
  if (raw === 'Commercial') {
    return '商业';
  }
  return raw;
}
