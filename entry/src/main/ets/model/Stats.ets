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
 * ── 为什么 failures 只声明成 Object[]、本模块也不提供解析函数 ──
 *   这个子结构没有实测过（任务书明确说未知），猜字段名（id / net / status …）
 *   一旦猜错，运行时读到 undefined，画出来就是一行行空白卡片，比不画更糟。
 *   故这里只保留「它是一个数组」这一点，页面侧不做任何字段读取，
 *   失败信息改用同一条记录里**确定存在**的 fail / partial 计数呈现。
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
  /** 结构未知（未实测）。刻意不在本工程内猜字段，见文件头说明 */
  failures?: Object[];
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

/**
 * 失败记录条数。
 *
 * 只读「数组长度」这一个确定信息，不碰任何子字段 —— 任务书说 failures 的
 * 结构没实测过，猜字段名会画出满地 undefined。页面目前也不用这个数
 * （四格里的失败 / 部分成功来自确定的 fail / partial），留着是给将来
 * 数据侧补齐结构后的入口。
 */
export function stFailureCount(y: StYear | null): number {
  if (y === null) {
    return 0;
  }
  const raw: Object[] | undefined = y.failures;
  if (raw === undefined || raw === null || !Array.isArray(raw)) {
    return 0;
  }
  return raw.length;
}
