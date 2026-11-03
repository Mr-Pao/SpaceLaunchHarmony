/**
 * Stats.ets —— 数据统计（历年发射量）类型与取数工具
 *
 * 数据集：stats → stats-years.json（CI 侧按年预聚合，前端只挑年份渲染，不做任何统计）
 * 线上实测：70 条，year 从 2026 递减到 1957，顶层 { v, dataset, generatedAt, count, served, list }。
 *
 * ── 为什么所有数值字段都声明成可选 ──
 *   写入端是 CI 的另一个脚本，字段名对得上不等于每年都齐（早期年份没有
 *   orbital / sub，某些年 rockets 为空数组直接被 JSON.stringify 省掉）。
 *   声明成必填会让页面拿 undefined 去 toFixed / 拼字符串，屏幕上就会出现 "undefined"。
 *   所以一律可选，消费端统一走 stNum()。
 *
 * ── failures 子结构（2026-11-03 拉线上 JSON 实测） ──
 *   形如 { id, name, net, rocket, site, status }，status 实测只有 'Failure'，
 *   但小程序的界面上还留了 'Partial' 分支（部分成功的记录也可能挂在这里），
 *   所以本模块按「两种都可能」声明，消费端按 status 分流上色。
 *   线上 70 年里只有 521 条失败记录，早期年份的 failures 为空数组。
 *
 * ArkTS 约束：只用 interface / function，不写 @Component；类型名统一加 St 前缀
 * （StatsPayload 是任务书指定的名字，四处引用已对齐），避免与其它 model 文件撞名。
 */

import { BasePayload } from './Common';

/** 榜单一行：火箭型号 / 发射场 / 机构 / 目标轨道共用 */
export interface StRankItem {
  /** CI 给的是英文原名，中文由前端专名表处理，这里不做映射 */
  name?: string;
  count?: number;
}

/** 一个年度的预聚合结果 */
export interface StYear {
  /** 年份，如 2026 */
  year?: number;
  /** 当年发射总数（= success + fail + partial） */
  total?: number;
  success?: number;
  fail?: number;
  partial?: number;
  /** 轨道发射次数 */
  orbital?: number;
  /** 亚轨道次数 */
  sub?: number;
  /** 固定 12 个元素，下标 0 即 1 月；个别年份可能缺尾部 0，消费端先补齐 */
  months?: number[];
  /** 以下四个榜都是 CI 已排好序的，前端只取前 N 条，不重排语义 */
  rockets?: StRankItem[];
  sites?: StRankItem[];
  agencies?: StRankItem[];
  orbits?: StRankItem[];
  /** 失败 / 部分成功的发射记录，结构见文件头（实测已确认） */
  failures?: StFailure[];
}

/** 一条失败 / 部分成功记录（线上 COS 实测字段） */
export interface StFailure {
  /** LL2 launch UUID，点击进详情要用；缺失时那一行不可点 */
  id?: string;
  /** 任务名，形如「Long March 7A | ChinaSat 4B」 */
  name?: string;
  /** ISO 发射时间 */
  net?: string;
  /** 火箭型号（英文原名） */
  rocket?: string;
  /** 发射场（英文原名，含国家） */
  site?: string;
  /** 'Failure' 或 'Partial' */
  status?: string;
}

/** 统计数据集载荷 */
export interface StatsPayload extends BasePayload {
  dataset?: string;
  count?: number;
  /** 本次实际下发的条数（发布类快照带，统计集一般等于 list.length） */
  served?: number;
  list: StYear[];
}

/** 12 个月 —— 多处循环用同一个常量，避免各写一个魔法数 */
export const ST_MONTHS: number = 12;

/**
 * 数值兜底。
 *
 * 为什么不用 `x || 0`：`0 || 0` 是 0 没问题，但旧数据里出现过字符串 "3"
 * 这种半坏数据（上游某次解析错误），`"3" || 0` 会得到字符串，
 * 后面 `toFixed` 直接抛异常。这里只认 number 且有限值。
 */
export function stNum(v: number | undefined | null): number {
  if (v === undefined || v === null) {
    return 0;
  }
  const n: number = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** 按 year 找一条；找不到返回 null（消费端必须先判空再取字段） */
export function stFindYear(list: StYear[], year: number): StYear | null {
  for (let i = 0; i < list.length; i++) {
    if (stNum(list[i].year) === year) {
      return list[i];
    }
  }
  return null;
}

/**
 * 最新一年。
 *
 * 为什么不直接取 list[0]：契约写的是「倒序」，但这是 CI 的排序约定、不是本模块的
 * 不变量。挑 max(year) 无论顺序如何都成立，代价只有 70 次比较。
 */
export function stLatestYear(list: StYear[]): StYear | null {
  let best: StYear | null = null;
  let bestYear: number = -1;
  for (let i = 0; i < list.length; i++) {
    const y: number = stNum(list[i].year);
    if (y > bestYear) {
      bestYear = y;
      best = list[i];
    }
  }
  return best;
}

/** 全部年份的总数（总览卡的「累计 N 次」） */
export function stSumTotal(list: StYear[]): number {
  let sum: number = 0;
  for (let i = 0; i < list.length; i++) {
    sum += stNum(list[i].total);
  }
  return sum;
}

/**
 * 成功率（0~100 的浮点）。
 *
 * 分母取「成功 + 失败 + 部分成功」而不是 total：total 在某些年份把
 * 「已排期但未发射」也算进去了（亚轨道试验），用 total 当分母会让成功率偏低。
 * 一个已决出的都没有时返回 0，由调用方决定显示 "0.0%" 还是 "--"。
 */
export function stSuccessRate(y: StYear | null): number {
  if (y === null) {
    return 0;
  }
  const ok: number = stNum(y.success);
  const decided: number = ok + stNum(y.fail) + stNum(y.partial);
  if (decided <= 0) {
    return 0;
  }
  return ok / decided * 100;
}

/**
 * 12 个月补成定长数组。
 *
 * 长度不足就补 0、超长截断：页面要按 1~12 画 12 根柱子，
 * 直接用原始数组会因某年只有 6 个数而少画半年，视觉上像数据丢了。
 */
export function stMonths(y: StYear | null): number[] {
  const out: number[] = [];
  for (let i = 0; i < ST_MONTHS; i++) {
    out.push(0);
  }
  if (y === null) {
    return out;
  }
  const raw: number[] | undefined = y.months;
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return out;
  }
  const n: number = raw.length < ST_MONTHS ? raw.length : ST_MONTHS;
  for (let i = 0; i < n; i++) {
    out[i] = stNum(raw[i]);
  }
  return out;
}

/**
 * 取榜单前 N 条。
 *
 * 三件事一起做：
 *   1. 防御：rows 可能是 undefined / 非数组（JSON 里空数组会被写入端省掉）；
 *   2. 丢掉名称为空或次数为 0 的行 —— 这样的行画出来只有一个「0 次」，没有信息量；
 *   3. 按 count 降序后再切 —— 契约说已排序，但这一层很便宜，别赌上游。
 *
 * 用 slice 而不是在原数组上 sort：入参可能是 CI 的数组引用（内存里的同一份），
 * 就地排序会改变后面的调用（比如同一年的另一个榜如果复用数组）看到的顺序。
 */
export function stRankTop(rows: StRankItem[] | undefined, limit: number): StRankItem[] {
  const out: StRankItem[] = [];
  if (rows === undefined || rows === null || !Array.isArray(rows)) {
    return out;
  }
  for (let i = 0; i < rows.length; i++) {
    const r: StRankItem = rows[i];
    if (r === undefined || r === null) {
      continue;
    }
    const name: string = r.name !== undefined && r.name !== null ? r.name : '';
    if (name.length === 0) {
      continue;
    }
    if (stNum(r.count) <= 0) {
      continue;
    }
    out.push(r);
  }
  out.sort((a: StRankItem, b: StRankItem) => stNum(b.count) - stNum(a.count));
  return out.slice(0, limit);
}

/** 国家 / 地区聚合结果一行（页面按 count 降序画条） */
export class StCountryRow {
  name: string = '';
  count: number = 0;

  constructor(name: string, count: number) {
    this.name = name;
    this.count = count;
  }
}

/**
 * 一条「机构关键词 → 国家」规则。
 *
 * 为什么用关键词数组而不是中括号正则：小程序写的是 /a|b|c/i，
 * 语义上就是「名字里含任一关键词」，用 toLowerCase + indexOf 完全等价，
 * 还避开了 ArkTS 里动态拼正则要处理转义的麻烦。顺序必须保留 ——
 * 「Russian Space Forces」同时含 russian 和 space force，俄罗斯必须排在前面。
 */
class StCountryRule {
  name: string = '';
  keys: string[] = [];

  constructor(name: string, keys: string[]) {
    this.name = name;
    this.keys = keys;
  }
}

const COUNTRY_RULES: StCountryRule[] = [
  new StCountryRule('俄罗斯', ['russian', 'roscosmos', 'kosmotras', 'khrunichev']),
  new StCountryRule('中国', ['china', 'cas space', 'galactic energy', 'landspace',
    'expace', 'orienspace', 'space pioneer', 'kuaizhou']),
  new StCountryRule('美国', ['spacex', 'rocket lab', 'united launch', 'blue origin', 'firefly',
    'virgin', 'astra', 'relativity', 'nasa', 'us space force']),
  new StCountryRule('印度', ['indian space', 'isro']),
  new StCountryRule('日本', ['japan', 'mitsubishi', 'jaxa', 'interstellar']),
  new StCountryRule('韩国', ['korea', 'kari', 'defense development']),
  new StCountryRule('欧洲', ['arianespace', 'european space', 'avio']),
  new StCountryRule('德国', ['isar']),
  new StCountryRule('以色列', ['israel', 'iai']),
  new StCountryRule('伊朗', ['iran']),
  new StCountryRule('新西兰', ['new zealand'])
];

/** 机构名 → 国家；匹配不上归「其他」，空名归「未知」（与小程序一致） */
export function stCountryOf(agency: string | undefined | null): string {
  if (agency === undefined || agency === null || agency.length === 0) {
    return '未知';
  }
  const low: string = agency.toLowerCase();
  for (let i = 0; i < COUNTRY_RULES.length; i++) {
    const rule: StCountryRule = COUNTRY_RULES[i];
    for (let k = 0; k < rule.keys.length; k++) {
      if (low.indexOf(rule.keys[k]) !== -1) {
        return rule.name;
      }
    }
  }
  return '其他';
}

/**
 * 机构榜 → 国家聚合（最多 limit 条，按次数降序）。
 *
 * 国家不在 CI 侧聚合：规则是前端维护的，读机构那十来行开销可忽略，
 * 因此与小程序同口径在客户端算。
 */
export function stCountries(rows: StRankItem[] | undefined, limit: number): StCountryRow[] {
  const out: StCountryRow[] = [];
  if (rows === undefined || rows === null || !Array.isArray(rows) || rows.length === 0) {
    return out;
  }
  const sum: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < rows.length; i++) {
    const r: StRankItem = rows[i];
    if (r === undefined || r === null) {
      continue;
    }
    const key: string = stCountryOf(r.name);
    const prev: number | undefined = sum.get(key);
    sum.set(key, (prev === undefined ? 0 : prev) + stNum(r.count));
  }
  const names: string[] = [];
  sum.forEach((v: number, k: string) => {
    if (v > 0) {
      names.push(k);
    }
  });
  names.sort((a: string, b: string) => {
    const va: number | undefined = sum.get(a);
    const vb: number | undefined = sum.get(b);
    return (vb === undefined ? 0 : vb) - (va === undefined ? 0 : va);
  });
  const n: number = names.length < limit ? names.length : limit;
  for (let i = 0; i < n; i++) {
    const name: string = names[i];
    const v: number | undefined = sum.get(name);
    out.push(new StCountryRow(name, v === undefined ? 0 : v));
  }
  return out;
}

/** 失败 / 部分成功记录（原样返回，字段见 StFailure）；页面自己判 null */
export function stFailures(y: StYear | null): StFailure[] {
  const out: StFailure[] = [];
  if (y === null) {
    return out;
  }
  const raw: StFailure[] | undefined = y.failures;
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return out;
  }
  for (let i = 0; i < raw.length; i++) {
    const f: StFailure = raw[i];
    if (f !== undefined && f !== null) {
      out.push(f);
    }
  }
  return out;
}

/** 失败记录条数（不做任何字段读取，纯长度） */
export function stFailureCount(y: StYear | null): number {
  return stFailures(y).length;
}
