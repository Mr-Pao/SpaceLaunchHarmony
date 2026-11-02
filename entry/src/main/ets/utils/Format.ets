/**
 * utils/Format.ets —— 时间与文本格式化（第一阶段子集）
 *
 * 对位原项目 utils/format.js。**只迁第一阶段真正用到的几个纯函数**，
 * 不搬那些上千行的中文译名表（ROCKET_ZH / CHINA_ASTRO_ZH / ORBIT_ZH…）——
 * 那些属于第二阶段的翻译层，第一阶段先用原始英文名跑通数据链路。
 *
 * 迁移原则：函数体逐行照抄，不做「顺手优化」。
 * 原项目里每一处 if/else 都是踩过坑之后写下的（见各函数注释），
 * 重写一遍等于把坑再踩一次。
 *
 * 约定：本文件不出现 console.*，也不做任何 IO，全部为纯函数。
 */

import { LaunchSummary } from '../model/Launch';

/** 补零：0 → '00' */
function pad(n: number): string {
  return n < 10 ? '0' + n : String(n);
}

/**
 * 把「可能为 undefined / null」的字符串字段安全取成 string。
 *
 * 为什么需要它：model/Launch.ets 由同事负责，字段是否声明成可选（`?`）不确定。
 * 用 strOf(x) 包一层，无论声明是 `name: string` 还是 `name?: string` 都能编译，
 * 而且运行时 null 也不会让 `||` 拿到 'null' 这个字符串。
 */
export function strOf(v: string | undefined | null): string {
  return v !== undefined && v !== null ? v : '';
}

/** 解析 ISO 串成毫秒时间戳，失败返回 0（不用 NaN 往下传） */
export function parseTime(value: string): number {
  const t: number = Date.parse(value);
  return Number.isNaN(t) ? 0 : t;
}

/** 解析成 Date，失败返回 null。LL2 的时间是带时区的 ISO 串 */
export function toDate(value: string): Date | null {
  const t: number = parseTime(value);
  return t > 0 ? new Date(t) : null;
}

/** 2026-10-23 06:51（完整时间，详情页用） */
export function formatDateTime(value: string): string {
  const d: Date | null = toDate(value);
  if (d === null) {
    return '';
  }
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
    ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}

/** 10-23 06:51（列表卡片用，省掉年份）；跨年任务自动带年份：2025-04-12 08:00 */
export function formatShort(value: string): string {
  const d: Date | null = toDate(value);
  if (d === null) {
    return '时间待定';
  }
  const hm: string = pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
    pad(d.getHours()) + ':' + pad(d.getMinutes());
  // 老任务不带年份分不清哪年（原项目复审 P2-6）；当年任务保持短格式
  if (d.getFullYear() !== new Date().getFullYear()) {
    return d.getFullYear() + '-' + hm;
  }
  return hm;
}

/**
 * 发射时间的中文展示：「11月5日 20:30」。
 *
 * 为什么不用 formatShort：卡片上「10-23 06:51」这种数字格式在中文语境里
 * 要读两遍才知道是月还是日；今天页要的是「一眼看懂哪天发射」，
 * 所以月日带「月 / 日」两个字，时分仍用冒号。
 *
 * 跨年任务自动补年份，理由同 formatShort：老任务不写年份会误读成今年。
 */
export function formatLaunchTime(value: string): string {
  const d: Date | null = toDate(value);
  if (d === null) {
    return '时间待定';
  }
  const md: string = (d.getMonth() + 1) + '月' + d.getDate() + '日 ' +
    pad(d.getHours()) + ':' + pad(d.getMinutes());
  if (d.getFullYear() !== new Date().getFullYear()) {
    return d.getFullYear() + '年' + md;
  }
  return md;
}

/**
 * 相对时间：发射列表最该先看的是「还有多久发射」，而不是一串年份数字
 *   未来  -> 「3 天后」「2 小时后」「18 分钟后」
 *   过去  -> 「3 天前」
 *
 * 原项目同一函数对历史发射也复用（「多久前」），语义照样成立，故不拆两个。
 */
export function relativeTime(value: string): string {
  const t: number = parseTime(value);
  if (t <= 0) {
    return '时间待定';
  }

  const diff: number = t - Date.now();
  const abs: number = Math.abs(diff);
  const future: boolean = diff > 0;

  // 一律向下取整：「1 天前」允许少报（1.6 天显示 1 天），
  // round 会把 1.6 天报成 2 天，明明还差 10 小时才满两天却看着像过了两天
  const mins: number = Math.floor(abs / 60000);
  const hours: number = Math.floor(abs / 3600000);
  const days: number = Math.floor(abs / 86400000);

  if (mins < 1) {
    return '即将发射';
  }
  if (mins < 60) {
    return future ? mins + ' 分钟后' : mins + ' 分钟前';
  }
  if (hours < 24) {
    return future ? hours + ' 小时后' : hours + ' 小时前';
  }
  if (days < 30) {
    return future ? days + ' 天后' : days + ' 天前';
  }

  // 超过 30 天回退短格式：formatShort 对跨年任务会自动带年份
  return formatShort(value);
}

/**
 * ISO 日期 → 短日期 "2024-03-15"（去掉时间部分）。
 *
 * ⚠ 必须保持原实现：**用正则按原串截取，绝不用 new Date()**。
 * 理由（原项目 utils/format.js:1321-1330 的注释写得很清楚，这里是原文照译）：
 *   数据是零补位的 UTC 串，本地时区（东八区）会把跨零点时刻的日期往前/后推一天。
 *   例：'2024-03-15T20:00:00Z' 在东八区是 3 月 16 日 04:00，
 *   用 new Date().getDate() 会得到 16，而页面口径（GCAT / 站 / 远征队各页）
 *   一直按原串截取显示 15，两边就会分叉。
 * 所以这里一个 Date 都不构造，纯字符串匹配。
 */
export function dayOf(iso: string): string {
  const s: string = strOf(iso);
  // 原实现是 /^(\d{4}-\d{2}-\d{2})/.exec(...) 取捕获组；
  // 这里改成「先 test 再 substring(0, 10)」，语义完全等价，
  // 但避开了对 RegExpExecArray 取下标（ArkTS 对下标访问更挑剔）。
  const re: RegExp = new RegExp('^\\d{4}-\\d{2}-\\d{2}');
  if (s.length < 10 || !re.test(s)) {
    return '';
  }
  return s.substring(0, 10);
}

/**
 * 倒计时拆解。
 *
 * 对位 components/countdown/countdown.vue 的 units 计算：四组数字（天/时/分/秒），
 * 每组 2 位补零，归零后 ended = true。
 *
 * 第一阶段列表卡片只用 relativeTime 的文字版（与原项目 launch-card 一致：
 * 列表不跑秒级定时器，六十张卡各起一个 setInterval 会直接把主线程拖住）；
 * 秒级跳动留给第二阶段的「下次发射」大卡，届时由独立组件持有定时器。
 * 这里先把算法备好，避免第二阶段再抄一遍。
 */
export class CountdownParts {
  days: string = '00';
  hours: string = '00';
  mins: string = '00';
  secs: string = '00';
  ended: boolean = true;
  /** 已到点时的文案：措辞留余地——可能是推迟，也可能是已经发射 */
  overText: string = '时间已到';
}

export function countdownParts(value: string): CountdownParts {
  const out: CountdownParts = new CountdownParts();
  const t: number = parseTime(value);
  if (t <= 0) {
    out.ended = true;
    return out;
  }
  const diff: number = Math.max(0, t - Date.now());
  out.ended = diff <= 0;
  if (out.ended) {
    return out;
  }
  const s: number = Math.floor(diff / 1000);
  out.days = pad(Math.floor(s / 86400));
  out.hours = pad(Math.floor((s % 86400) / 3600));
  out.mins = pad(Math.floor((s % 3600) / 60));
  out.secs = pad(s % 60);
  return out;
}

/**
 * 状态 → 展示文案 + 色调。
 *
 * 色调只保留语义名（不直接返回颜色值），让调用方决定用哪套色板：
 * 卡片 chip、详情页大字、时间线圆点可以各自映射，不必为每处再写一遍判断。
 */
export class StatusInfo {
  text: string = '';
  /** go / success / failure / flying / pending / normal */
  tone: string = 'normal';

  constructor(text: string, tone: string) {
    this.text = text;
    this.tone = tone;
  }
}

export function statusOf(item: LaunchSummary): StatusInfo {
  const st = item.status;
  const zh: string = strOf(st === undefined || st === null ? undefined : st.nameZh);
  const en: string = strOf(st === undefined || st === null ? undefined : st.name);
  const ab: string = strOf(st === undefined || st === null ? undefined : st.abbrev);
  const text: string = zh.length > 0 ? zh : (en.length > 0 ? en : (ab.length > 0 ? ab : '未知'));

  if (ab === 'Success' || ab === 'Deployed') {
    return new StatusInfo(text, 'success');
  }
  if (ab === 'Failure' || ab === 'Partial') {
    return new StatusInfo(text, 'failure');
  }
  if (ab === 'In Flight') {
    // LL2 的 upcoming 快照会滞后几小时（原项目 utils/format.js:96-100），
    // 超过 6 小时还挂着「飞行中」就是陈旧状态，不能一直显示
    const t: number = parseTime(strOf(item.net));
    if (t > 0 && Date.now() - t > 6 * 3600 * 1000) {
      return new StatusInfo('状态待更新', 'pending');
    }
    return new StatusInfo(text, 'flying');
  }
  if (ab === 'Go') {
    return new StatusInfo(text, 'go');
  }
  return new StatusInfo(text, 'pending');
}

/** 状态文字色。对应 launch-card.vue 的 .status.go/.success/.failure/.flying */
export function statusToneColor(tone: string): string {
  if (tone === 'success') {
    return '#34C759';
  }
  if (tone === 'failure') {
    return '#FF3B30';
  }
  if (tone === 'flying') {
    return '#F5C33B';
  }
  if (tone === 'go') {
    return '#38BDF8';
  }
  return '#8A97A8';
}

/**
 * 状态底色。原项目用 rgba(…, 0.06~0.16) 的淡色块，
 * ArkUI 的字符串色值统一用 #AARRGGBB，alpha 已折算好。
 */
export function statusToneBg(tone: string): string {
  if (tone === 'success') {
    return '#2434C759'; // rgba(52,199,89,0.14)
  }
  if (tone === 'failure') {
    return '#24FF3B30'; // rgba(255,59,48,0.14)
  }
  if (tone === 'flying') {
    return '#24F5C33B'; // rgba(245,195,59,0.14)
  }
  if (tone === 'go') {
    return '#2638BDF8'; // rgba(56,189,248,0.15)
  }
  return '#0FFFFFFF'; // rgba(255,255,255,0.06)
}

/**
 * 任务名：优先中文，回退英文，最后回退 item.name。
 * 对位原项目 launchTitle() 里 mission 的那一半（型号那一半在 rocketLabelOf）。
 */
export function missionLabelOf(item: LaunchSummary): string {
  const m = item.mission;
  if (m !== undefined && m !== null) {
    const zh: string = strOf(m.nameZh);
    if (zh.length > 0) {
      return zh;
    }
    const en: string = strOf(m.name);
    if (en.length > 0) {
      return en;
    }
  }
  const raw: string = strOf(item.name);
  return raw.length > 0 ? raw : '未命名任务';
}

/**
 * 火箭型号。
 *
 * 原项目走 rocketName()：先查 ROCKET_ZH 中文表，再走长征规则推导，
 * 都查不到才回 full_name。**第一阶段只做最后那一步兜底**——
 * 中文型号表属于翻译层，等第二阶段整体迁过来再替换这里的返回表达式。
 * 现在返回英文 full_name，与原项目「查不到就保留英文」的表现一致。
 */
export function rocketLabelOf(item: LaunchSummary): string {
  const rocket = item.rocket;
  if (rocket === undefined || rocket === null) {
    return '';
  }
  const c = rocket.configuration;
  if (c === undefined || c === null) {
    return '';
  }
  const full: string = strOf(c.full_name);
  if (full.length > 0) {
    return full;
  }
  return strOf(c.name);
}

/** 发射机构。原项目走 agencyLabel() 中文表，第一阶段直接给原名 */
export function providerLabelOf(item: LaunchSummary): string {
  const p = item.launch_service_provider;
  if (p === undefined || p === null) {
    return '';
  }
  return strOf(p.name);
}

/** 目标轨道（近地轨道 / 地球同步转移轨道…第一阶段给缩写或原名） */
export function orbitLabelOf(item: LaunchSummary): string {
  const m = item.mission;
  if (m === undefined || m === null) {
    return '';
  }
  const o = m.orbit;
  if (o === undefined || o === null) {
    return '';
  }
  const name: string = strOf(o.name);
  if (name.length > 0) {
    return name;
  }
  return strOf(o.abbrev);
}

/** 发射工位的地点名（「卡纳维拉尔角 SLC-40」这一类太长，只取 location.name） */
export function placeLabelOf(item: LaunchSummary): string {
  const pad2 = item.pad;
  if (pad2 === undefined || pad2 === null) {
    return '';
  }
  const loc = pad2.location;
  if (loc === undefined || loc === null) {
    return '';
  }
  return strOf(loc.name);
}

/**
 * 列表排序键：按 net 升序，时间无法解析的排到最后。
 * 不能用 `new Date(a.net) - new Date(b.net)` 直接相减——ArkTS 里
 * 两个 Date 相减不是合法运算（TS 会报 arithmetic operand 错误）。
 */
export function compareByNet(a: LaunchSummary, b: LaunchSummary): number {
  const ta: number = parseTime(strOf(a.net));
  const tb: number = parseTime(strOf(b.net));
  if (ta <= 0 && tb <= 0) {
    return 0;
  }
  if (ta <= 0) {
    return 1;
  }
  if (tb <= 0) {
    return -1;
  }
  return ta - tb;
}

/**
 * generatedAt 的人读形式。
 * 同一天只给「20:30」，跨天才带月日——今日页的副标题不需要重复今天的日期。
 */
export function formatGeneratedAt(value: string): string {
  const d: Date | null = toDate(value);
  if (d === null) {
    return '';
  }
  const hm: string = pad(d.getHours()) + ':' + pad(d.getMinutes());
  const now: Date = new Date();
  const sameDay: boolean = d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
  if (sameDay) {
    return hm;
  }
  return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + hm;
}

/** 「11月2日 星期日」——今日页导航标题（对位 today.vue 的 todayText()） */
export function todayLabel(): string {
  const WEEK_ZH: string[] = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
  const d: Date = new Date();
  return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + WEEK_ZH[d.getDay()];
}
