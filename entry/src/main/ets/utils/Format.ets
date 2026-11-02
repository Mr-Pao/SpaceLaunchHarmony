/**
 * utils/Format.ets —— 时间、文本格式化 + 中文翻译层
 *
 * 对位原项目 utils/format.js（1340 行），**全量移植**：
 *   第一部分（本文件中段）：时间 / 状态 / 列表格式化；
 *   第二部分（本文件后段）：中文翻译层 —— 查表 + 规则推导。
 *   数据表本身在 constants/ZhMaps.ets（470 条，逐条与源文件对齐）。
 *
 * 迁移原则：函数体逐行照抄，不做「顺手优化」。
 * 原项目里每一处 if/else 都是踩过坑之后写下的（见各函数注释），
 * 重写一遍等于把坑再踩一次。
 *
 * 与原项目的**有意差异**（全部写在各函数注释里）：
 *   1. 数据表用 Map，不用对象字面量（ArkTS 禁索引签名）；
 *   2. 正则统一 `new RegExp('...')` 且反斜杠写两个；
 *   3. flagSrc 返回 emoji 而不是 /static/flags/*.png（鸿蒙侧没有国旗图片资源）；
 *   4. astroName 少了 nameZh 那一档（鸿蒙侧 model/Astronaut.ets 刻意不声明该字段）；
 *   5. eventName / astroName 改成吃字符串参数（鸿蒙侧没有对应的 Event 模型）。
 *
 * 约定：本文件不出现 console.*，也不做任何 IO，全部为纯函数。
 */

import { LaunchSummary, RocketConfig, LaunchProvider } from '../model/Common';
import { AstronautCard } from '../model/Astronaut';
import {
  CORE_STATUS, CoreStatusEntry,
  NATION_ZH, CHINA_ASTRO_ZH,
  ROCKET_ZH, ROCKET_ZH_PREFIX_KEYS, CN_NUM, CN_TAIL,
  SERIES_ZH, TERM_FIX, TermFix,
  ORBIT_ZH, MISSION_TYPE_ZH, CRAFT_TYPE_ZH, CRAFT_STATUS_ZH, DEST_ZH, EVENT_TYPE_ZH,
  COUNTRY_ZH, AGENCY_ZH, FINAL_STATUS,
  PLACE_ZH, PlaceRule,
  STATION_ZH, EVENT_TERM_FIX, FLAG_RULES, FlagRule,
} from '../constants/ZhMaps';

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
 * 走 rocketFullName()：先查 ROCKET_ZH 中文表，再走长征规则推导（CN_NUM/CN_TAIL），
 * 再按前缀兜底，最后才回退英文 full_name —— 与原项目完全一致。
 * 构型后缀的拼接判断也在 rocketFullName 里（「猎鹰 9 号 Block 5」）。
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
  return rocketFullName(c);
}

/** 发射机构。走 agencyLabel() 中文表（查不到截断到 15 字 + 省略号） */
export function providerLabelOf(item: LaunchSummary): string {
  const p = item.launch_service_provider;
  if (p === undefined || p === null) {
    return '';
  }
  return agencyLabel(strOf(p.name));
}

/** 目标轨道（近地轨道 / 地球同步转移轨道…）；表里没有的给原名或缩写 */
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
    return orbitName(name);
  }
  return strOf(o.abbrev);
}

/**
 * 发射工位的地点名。
 *
 * 与原项目 launch-card 一致：对 pad.location.name 整串跑 placeZh，
 * 命中地名表就整串换成中文短名（"Cape Canaveral SFS, FL, USA" → 卡纳维拉尔角）。
 * 地名表没命中时再退一步用 countryOf（至少给个国家名），仍为空才给原文。
 */
export function placeLabelOf(item: LaunchSummary): string {
  const pad2 = item.pad;
  if (pad2 === undefined || pad2 === null) {
    return '';
  }
  const loc = pad2.location;
  if (loc === undefined || loc === null) {
    return '';
  }
  const name: string = strOf(loc.name);
  if (name.length === 0) {
    return '';
  }
  const zh: string = placeZh(name);
  if (zh.length > 0 && zh !== name) {
    return zh;
  }
  const country: string = countryOf(item);
  return country.length > 0 ? country : name;
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
  // WEEK_ZH 已提到模块级（见下方 longDate 上方），这里不再重复定义一份
  const d: Date = new Date();
  return (d.getMonth() + 1) + '月' + d.getDate() + '日 ' + WEEK_ZH[d.getDay()];
}

// ============================================================
// 第二部分：中文翻译层（对位原项目 utils/format.js:105-1340）
// ============================================================
// 数据表全部在 constants/ZhMaps.ets，本段只有「查表 + 规则推导」，
// 与原项目一致：纯函数、无 IO、无模块级可变量。
//
// ArkTS 约束备忘（三条都是踩过的坑）：
//   1. Map.get 返回 string | undefined —— 统一走 zhOf() 收口成空串，
//      空串语义 =「没译」，调用方回退原文（与原项目 `TBL[k] || s` 等价）；
//   2. 正则必须 new RegExp('...')，源码里的一个反斜杠在这边要写成两个；
//   3. 不用 any / 索引签名 / 匿名对象字面量。

/** 查表取值：没命中返回空串（空串 = 没译，调用方回退原文） */
function zhOf(table: Map<string, string>, key: string): string {
  if (key.length === 0) {
    return '';
  }
  const v: string | undefined = table.get(key);
  return v === undefined ? '' : v;
}

/** 取正则捕获组：未参与匹配的分组在 JS 里是 undefined，这里统一成空串 */
function group(m: RegExpMatchArray, i: number): string {
  if (i >= m.length) {
    return '';
  }
  const v: string | undefined = m[i];
  return v === undefined ? '' : v;
}

/** 去掉所有空白。源实现是 replace(/\s+/g, '')，这里按字符剔除，避开转义 */
function stripSpaces(s: string): string {
  let out: string = '';
  for (let i = 0; i < s.length; i++) {
    const c: string = s.charAt(i);
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') {
      continue;
    }
    out += c;
  }
  return out;
}

/** 含汉字？源实现是 /[\u4e00-\u9fa5]/.test(zh)，这里按码点判，避开转义 */
function hasHanzi(s: string): boolean {
  for (let i = 0; i < s.length; i++) {
    const code: number = s.charCodeAt(i);
    if (code >= 0x4e00 && code <= 0x9fa5) {
      return true;
    }
  }
  return false;
}

/**
 * 超长文本截断，末位补省略号。
 *
 * 源项目按 JS 的 length（UTF-16 码元）算，这里照抄：中文一个字算 1，
 * 需要「视觉宽度」的地方另有 textUnits。
 */
export function truncate(text: string, max: number): string {
  const s: string = strOf(text);
  if (s.length === 0) {
    return '';
  }
  if (max <= 0) {
    return s.length > 0 ? '…' : '';
  }
  return s.length > max ? s.substring(0, max) + '…' : s;
}

/**
 * 芯级个体状态中文化。
 *
 * LL2 /launchers/ 的 status 是固定枚举（实测全库只出现 5 种）：
 * active 现役 / retired 退役 / expended 已消耗（设计上不回收，飞完即弃）/
 * lost 坠毁（回收失败）/ destroyed 炸毁（地面事故等）。查表不走翻译。
 *
 * 源实现接受 string 或 {name}；鸿蒙侧调用方拿到的是字符串，需要对象时自己取 .name。
 */
export function coreStatus(statusName: string): CoreStatusEntry {
  const key: string = strOf(statusName);
  const hit: CoreStatusEntry | undefined = CORE_STATUS.get(key);
  if (hit !== undefined) {
    return hit;
  }
  return new CoreStatusEntry(key.length > 0 ? key : '未知', 'dim');
}

/** 国籍中文化。表里没有的保留原文 —— 译错国籍比不译更糟 */
export function nationZh(nation: string): string {
  const s: string = strOf(nation);
  if (s.length === 0) {
    return '';
  }
  const zh: string = zhOf(NATION_ZH, s);
  return zh.length > 0 ? zh : s;
}

/**
 * 航天员姓名中文化。
 *
 * 中国籍走 CHINA_ASTRO_ZH 专名表（LL2 只给拼音，同音字太多，推不出来）。
 * 源实现还有一档 a.nameZh 兜底，但鸿蒙侧 model/Astronaut.ets **刻意不声明 nameZh**
 * （注释写明产品约定走前端专名表），所以那一档在这里恒为空，没有移植的意义。
 *
 * 表里没有的中国人保留拼音原文：宁可显示拼音，也不要编一个错的名字。
 */
export function astroName(rawName: string, nation: string): string {
  const raw: string = strOf(rawName).trim();
  if (raw.length === 0) {
    return '';
  }
  if (strOf(nation) === 'China') {
    const zh: string = zhOf(CHINA_ASTRO_ZH, raw);
    if (zh.length > 0) {
      return zh;
    }
  }
  return raw;
}

/** 便捷重载：直接吃 astronautsInspace 的 AstronautCard */
export function astroNameOf(a: AstronautCard): string {
  if (a === undefined || a === null) {
    return '';
  }
  return astroName(a.name, strOf(a.nation));
}

/**
 * 长征系列规则推导：
 *   Long March 5            → 长征五号
 *   Long March 3B/E         → 长征三号乙/E     （斜杠后是构型/上面级，保留原文）
 *   Long March 2F/G         → 长征二号F/G
 *   Long March 2C/YZ-1S     → 长征二号丙/YZ-1S
 *   Long March 8 (Core Only)→ 长征八号（仅芯级）
 * 对不上格式就返回空串，调用方回退英文原文。
 */
const LONG_MARCH_RE: RegExp = new RegExp(
  '^Long March(?:\\s+(\\d+)([A-Z])?)?(\\s*\\/\\s*[A-Za-z0-9][\\w\\-]*)?(\\s*\\(Core Only\\))?$', 'i');

export function zhLongMarch(raw: string): string {
  const s: string = strOf(raw).trim();
  if (s.length === 0) {
    return '';
  }
  const m: RegExpMatchArray | null = s.match(LONG_MARCH_RE);
  if (m === null) {
    return '';
  }
  const numRaw: string = group(m, 1);
  // 型号库里有一条光秃秃的 "Long March"（没有编号）
  if (numRaw.length === 0) {
    return '长征';
  }
  const num: string = zhOf(CN_NUM, numRaw);
  if (num.length === 0) {
    return '';
  }
  const letter: string = group(m, 2);
  let tail: string = '';
  if (letter.length > 0) {
    const t: string = zhOf(CN_TAIL, letter.toUpperCase());
    tail = t.length > 0 ? t : letter;
  }
  const extraRaw: string = group(m, 3);
  const extra: string = extraRaw.length > 0 ? stripSpaces(extraRaw).toUpperCase() : '';
  const core: string = group(m, 4).length > 0 ? '（仅芯级）' : '';
  return '长征' + num + '号' + tail + extra + core;
}

/** 构型后缀：Block 5 / V3 这类不该拼进中文名（中文名本身已经够用） */
const BLOCK_TAIL_RE: RegExp = new RegExp('^(Block|V)\\s*\\d+$', 'i');

/**
 * 长后缀兜底：型号表里只有基础名时，按前缀认。
 *
 * Atlas V 551 / Atlas V 401 这些配置代号不可能逐个入库，
 * 但都该归到「宇宙神 5 号」；后面的数字保留，因为它是真的配置差异。
 * 从最长 key 开始试，避免 "Atlas" 抢在 "Atlas V" 前面。
 * 前缀表顺序在 ZhMaps.ets 里按 key 长度降序预先排好（源文件是运行时 sort）。
 */
export function rocketByPrefix(s: string): string {
  const str: string = strOf(s);
  if (str.length === 0) {
    return '';
  }
  const keys: string[] = ROCKET_ZH_PREFIX_KEYS;
  for (let i = 0; i < keys.length; i++) {
    const k: string = keys[i];
    if (str === k || !str.startsWith(k + ' ')) {
      continue;
    }
    const base: string = zhOf(ROCKET_ZH, k);
    const tail: string = str.substring(k.length + 1).trim();
    if (BLOCK_TAIL_RE.test(tail)) {
      return base;
    }
    return base + ' ' + tail;
  }
  return '';
}

/** name 自己就带构型后缀时要先剥掉再查表（Falcon 9 Block 5 → Falcon 9） */
const VARIANT_SUFFIX_RE: RegExp = new RegExp('\\s+(V\\d+|Block\\s*\\d+)$', 'i');

/**
 * 火箭型号名，中国型号换成中文，其余保留原文。
 *
 * 查表顺序有讲究：LL2 的 full_name 常带构型后缀（Falcon 9 Block 5），
 * 中文名却是钉在基础型号上的（猎鹰 9 号），所以四个候选按 full → base →
 * 去后缀 → 去上面级 依次试；长征规则推导也必须 **full 优先**，
 * 否则 {name:'Long March', full_name:'Long March 5'} 会先命中「长征」而丢掉编号。
 */
export function rocketName(config: RocketConfig): string {
  if (config === undefined || config === null) {
    return '';
  }
  const nameRaw: string = strOf(config.name);
  const fullRaw: string = strOf(config.full_name);
  const full: string = fullRaw.length > 0 ? fullRaw : nameRaw;
  const base: string = nameRaw.length > 0 ? nameRaw : full;
  if (full.length === 0) {
    return '';
  }
  const bare: string = base.replace(VARIANT_SUFFIX_RE, '');
  // 上面级写法（Soyuz 2.1b/Fregat-M、Angara A5/Briz-M）剥掉斜杠后半段再查
  const noUpper: string = base.split('/')[0].trim();

  const candidates: string[] = [full, base, bare, noUpper];
  for (let i = 0; i < candidates.length; i++) {
    const hit: string = zhOf(ROCKET_ZH, candidates[i]);
    if (hit.length > 0) {
      return hit;
    }
  }
  for (let i = 0; i < candidates.length; i++) {
    const hit: string = zhLongMarch(candidates[i]);
    if (hit.length > 0) {
      return hit;
    }
  }
  const byBase: string = rocketByPrefix(base);
  if (byBase.length > 0) {
    return byBase;
  }
  const byFull: string = rocketByPrefix(full);
  if (byFull.length > 0) {
    return byFull;
  }
  return full;
}

/**
 * 型号所属「系列」的聚合键。
 *
 * LL2 的 families 是层级路径，由粗到细：
 *   Falcon 9 Block 5 → ["Falcon", "Falcon 9"]
 *   Long March 2C    → ["Long March", "Long March 2"]
 *   Titan 34D IUS    → ["Titan", "Titan 34D", "Titan III"]
 * 取第二层刚好是「型号系列」这一级，同系列的各构型就能聚合到一起；
 * 只有一层的退回第一层；连系列都没有的用 name 自成一组。
 */
export function seriesKey(config: RocketConfig): string {
  if (config === undefined || config === null) {
    return '';
  }
  const fams: string[] = [];
  const rawFams: string[] | undefined = config.families;
  if (rawFams !== undefined && rawFams !== null) {
    for (let i = 0; i < rawFams.length; i++) {
      const f: string = strOf(rawFams[i]);
      if (f.length > 0) {
        fams.push(f);
      }
    }
  }
  if (fams.length >= 2) {
    return fams[1];
  }
  if (fams.length === 1) {
    return fams[0];
  }
  return strOf(config.name);
}

const LONG_MARCH_SERIES_RE: RegExp = new RegExp('^Long March(?:\\s+(\\d+))?$', 'i');

/** 系列名里的长征：Long March 2 → 长征二号（无编号的裸 "Long March" → 长征） */
function zhLongMarchSeries(raw: string): string {
  const s: string = strOf(raw).trim();
  if (s.length === 0) {
    return '';
  }
  const m: RegExpMatchArray | null = s.match(LONG_MARCH_SERIES_RE);
  if (m === null) {
    return '';
  }
  const numRaw: string = group(m, 1);
  if (numRaw.length === 0) {
    return '长征';
  }
  const num: string = zhOf(CN_NUM, numRaw);
  return num.length > 0 ? '长征' + num + '号' : '';
}

/** 系列名中文化：查表 → 长征规则 → 原文 */
export function seriesName(raw: string): string {
  const s: string = strOf(raw).trim();
  if (s.length === 0) {
    return '';
  }
  const hit: string = zhOf(SERIES_ZH, s);
  if (hit.length > 0) {
    return hit;
  }
  const lm: string = zhLongMarchSeries(s);
  return lm.length > 0 ? lm : s;
}

/** 通用术语修正（星链集团 → 星链 …），对机翻文本做后处理 */
function fixTerms(text: string): string {
  let s: string = strOf(text);
  if (s.length === 0) {
    return '';
  }
  for (let i = 0; i < TERM_FIX.length; i++) {
    const t: TermFix = TERM_FIX[i];
    s = s.replace(t.re, t.to);
  }
  return s;
}

/** 对外名（任务书叫 applyTermFix，源文件同名函数是私有 fixTerms） */
export function applyTermFix(text: string): string {
  return fixTerms(text);
}

/** 去掉任务名末尾的「(TBD)」「待定」这类占位后缀 */
const MISSION_TAIL_RE: RegExp =
  new RegExp('[\\s,，]*[(（]?\\s*(TBD|TBC|待定|待公布)\\s*[)）]?\\s*[?？]?\\s*$', 'i');

function cleanMission(text: string): string {
  return strOf(text).replace(MISSION_TAIL_RE, '').trim();
}

/**
 * 发射标题：「猎鹰 9 号 | 星链 G7-12」。
 * 任务名先做术语修正再去占位后缀；型号走 rocketFullName（含构型）。
 */
export function launchTitle(item: LaunchSummary): string {
  if (item === undefined || item === null) {
    return '';
  }
  let rocket: string = '';
  const r = item.rocket;
  if (r !== undefined && r !== null) {
    rocket = rocketFullName(r.configuration);
  }
  let mission: string = '';
  const m = item.mission;
  if (m !== undefined && m !== null) {
    const zh: string = strOf(m.nameZh);
    mission = cleanMission(fixTerms(zh.length > 0 ? zh : strOf(m.name)));
  }
  if (rocket.length > 0 && mission.length > 0) {
    return rocket + ' | ' + mission;
  }
  if (mission.length > 0) {
    return mission;
  }
  if (rocket.length > 0) {
    return rocket;
  }
  return strOf(item.name);
}

/** unknown / n/a / none / tbd / tbc → 未知（大小写不敏感） */
const UNKNOWN_RE: RegExp = new RegExp('^(unknown|n/a|none|tbd|tbc)$', 'i');

export function zhValue(value: string): string {
  const s: string = strOf(value).trim();
  if (s.length === 0) {
    return '';
  }
  return UNKNOWN_RE.test(s) ? '未知' : s;
}

/** 目标轨道中文化（表 key 全是小写，先 zhValue 再 toLowerCase 查） */
export function orbitName(value: string): string {
  const s: string = zhValue(value);
  if (s.length === 0) {
    return '';
  }
  const hit: string = zhOf(ORBIT_ZH, s.toLowerCase());
  return hit.length > 0 ? hit : s;
}

/** 任务类型中文化 */
export function missionTypeName(value: string): string {
  const s: string = zhValue(value);
  if (s.length === 0) {
    return '';
  }
  const hit: string = zhOf(MISSION_TYPE_ZH, s.toLowerCase());
  return hit.length > 0 ? hit : s;
}

/** 航天器类型（载人舱 / 货运飞船 …） */
export function craftTypeName(value: string): string {
  const s: string = zhValue(value);
  if (s.length === 0) {
    return '';
  }
  const hit: string = zhOf(CRAFT_TYPE_ZH, s.toLowerCase());
  return hit.length > 0 ? hit : s;
}

/** 航天器状态（在役 / 已退役 …） */
export function craftStatusName(value: string): string {
  const s: string = zhValue(value);
  if (s.length === 0) {
    return '';
  }
  const hit: string = zhOf(CRAFT_STATUS_ZH, s.toLowerCase());
  return hit.length > 0 ? hit : s;
}

/** 活动类型 */
export function eventTypeName(value: string): string {
  const s: string = zhValue(value);
  if (s.length === 0) {
    return '';
  }
  const hit: string = zhOf(EVENT_TYPE_ZH, s.toLowerCase());
  return hit.length > 0 ? hit : s;
}

/**
 * 目的地：先查 DEST_ZH，再退回轨道表。
 * 「Low Earth Orbit」这种既是目的地又是轨道的写法，靠后一档兜住。
 */
export function destName(value: string): string {
  const s: string = zhValue(value);
  if (s.length === 0) {
    return '';
  }
  const low: string = s.toLowerCase();
  const dest: string = zhOf(DEST_ZH, low);
  if (dest.length > 0) {
    return dest;
  }
  const orb: string = zhOf(ORBIT_ZH, low);
  return orb.length > 0 ? orb : s;
}

/** 空间站中文名；Salyut 1-7 走编号规则推导（礼炮一号…） */
export function stationName(raw: string): string {
  const s: string = strOf(raw).trim();
  if (s.length === 0) {
    return '';
  }
  const hit: string = zhOf(STATION_ZH, s);
  if (hit.length > 0) {
    return hit;
  }
  const m: RegExpMatchArray | null = s.match(SALYUT_RE);
  if (m === null) {
    return s;
  }
  const cn: string = zhOf(CN_NUM, group(m, 1));
  return cn.length > 0 ? '礼炮' + cn + '号' : s;
}

/**
 * 活动地点：空间站名 → 目的地 → 地名字典 → 原文。
 * 前两档是「返回值与入参不同即采用」，和源实现一模一样。
 */
export function eventPlace(loc: string): string {
  const s: string = strOf(loc).trim();
  if (s.length === 0) {
    return '';
  }
  const st: string = stationName(s);
  if (st !== s) {
    return st;
  }
  const dest: string = destName(s);
  if (dest !== s) {
    return dest;
  }
  const place: string = placeZh(s);
  return place.length > 0 ? place : s;
}

/**
 * 发射地点的国家/地区。
 *
 * pad.location.name 是「场地, 州, 国」的整串（"Cape Canaveral SFS, FL, USA"），
 * 取最后一段先查国名表，查不到再拿地名字典碰一次，最后截断兜底。
 */
export function countryOf(item: LaunchSummary): string {
  if (item === undefined || item === null) {
    return '';
  }
  const p = item.pad;
  if (p === undefined || p === null) {
    return '';
  }
  const loc = p.location;
  if (loc === undefined || loc === null) {
    return '';
  }
  const name: string = strOf(loc.name);
  if (name.length === 0) {
    return '';
  }
  const segs: string[] = name.split(',');
  const last: string = segs[segs.length - 1].trim();
  if (last.length === 0) {
    return '';
  }
  const hit: string = zhOf(COUNTRY_ZH, last);
  if (hit.length > 0) {
    return hit;
  }
  const place: string = placeZh(last);
  if (place.length > 0 && place !== last) {
    return place;
  }
  return last.length > 12 ? last.substring(0, 11) + '…' : last;
}

/**
 * 机构中文短名。
 *
 * LL2 给的是官方长名（"China Aerospace Science and Technology Corporation"），
 * 横向 chip 里一行放不下，所以只收常见大机构；查不到就截断，
 * 保留原文前缀也比撑破布局好 —— 译错机构名比不译更糟。
 */
export function agencyLabel(name: string): string {
  const s: string = strOf(name);
  if (s.length === 0) {
    return '';
  }
  const hit: string = zhOf(AGENCY_ZH, s);
  if (hit.length > 0) {
    return hit;
  }
  return s.length > 16 ? s.substring(0, 15) + '…' : s;
}

/** 便捷重载：直接吃 launch_service_provider */
export function agencyNameZh(p: LaunchProvider): string {
  if (p === undefined || p === null) {
    return '';
  }
  return agencyLabel(strOf(p.name));
}

/**
 * 一段文字的「视觉宽度」：半角记 1，中日韩全角记 2。
 *
 * 详情页简介按行数折叠（line-clamp 4），中文一个字约占英文两倍宽；
 * 纯按字符数判断，英文 160 字约 3 行、中文 160 字已 6 行，
 * 中文会被悄悄截掉却不显示「展开全部」。
 *
 * 实现说明：源用 codePointAt 逐码点累加，这里用 charCodeAt 逐码元；
 * 对 BMP（含全部中日韩字符）结果完全相同，对增补平面字符
 * （emoji，两个码元）源算 2、这里也累加成 2，等价。
 */
export function textUnits(s: string): number {
  const str: string = strOf(s);
  let n: number = 0;
  for (let i = 0; i < str.length; i++) {
    const c: number = str.charCodeAt(i);
    n += c >= 0x2e80 ? 2 : 1;
  }
  return n;
}

/**
 * 是否还该出现在「即将发射」列表里。
 *
 * LL2 的 /launches/upcoming/ 会把刚发射完的任务再挂一段时间（状态已是 Success），
 * 不过滤的话首页顶部会冒出「8 小时前 · 成功」的历史任务。
 * 但时间过了、状态还是 Go / TBD 的必须保留 —— 那多半是推迟了、LL2 还没更新 net。
 */
export function isStillUpcoming(item: LaunchSummary): boolean {
  if (item === undefined || item === null) {
    return false;
  }
  const d: Date | null = toDate(strOf(item.net));
  if (d === null) {
    return true;
  }
  if (d.getTime() > Date.now()) {
    return true;
  }
  const st = item.status;
  const a: string = st === undefined || st === null ? '' : strOf(st.abbrev);
  return FINAL_STATUS.indexOf(a) === -1;
}

/** 只要时刻：12:45（详情页做成一行大字） */
export function clock(value: string): string {
  const d: Date | null = toDate(strOf(value));
  if (d === null) {
    return '';
  }
  return pad(d.getHours()) + ':' + pad(d.getMinutes());
}

/**
 * 星期表。
 * ⚠ 源文件里它定义在 longDate 之前、todayLabel 内部也有一份；
 * 鸿蒙侧只保留这一份模块级常量，todayLabel 改为引用它（不再重复定义）。
 */
/**
 * 星期表。
 *
 * ⚠ 源文件里它定义在 longDate 之前，且 todayLabel 内部又抄了一份；
 * 鸿蒙侧只保留这**一份**模块级常量（放在这个分区是为了与源文件的行号对得上），
 * todayLabel 也改为引用它，不再重复定义。
 */
export const WEEK_ZH: string[] = [
  '星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];

/** 长日期：2026年10月27日 星期二 */
export function longDate(value: string): string {
  const d: Date | null = toDate(strOf(value));
  if (d === null) {
    return '';
  }
  return d.getFullYear() + '年' + (d.getMonth() + 1) + '月' + d.getDate() + '日 ' +
    WEEK_ZH[d.getDay()];
}

/** 两个时间的时间跨度，「X 小时 Y 分钟」；非法或非正返回空串 */
export function spanText(from: string, to: string): string {
  const a: Date | null = toDate(strOf(from));
  const b: Date | null = toDate(strOf(to));
  if (a === null || b === null) {
    return '';
  }
  const ms: number = b.getTime() - a.getTime();
  if (!(ms > 0)) {
    return '';
  }
  const min: number = Math.round(ms / 60000);
  if (min < 60) {
    return min + ' 分钟';
  }
  const h: number = Math.floor(min / 60);
  const m: number = min % 60;
  return m > 0 ? h + ' 小时 ' + m + ' 分钟' : h + ' 小时';
}

/**
 * 千分位。火箭参数动辄上万，不加逗号读不出来。
 *
 * 源实现是一行正则 replace(/\B(?=(\d{3})+(?!\d))/g, ',')；
 * 这里按整数位从右往左每三位插逗号，小数部分原样保留（负数不参与业务，不处理）。
 */
function thousands(v: number): string {
  const s: string = String(v);
  const dot: number = s.indexOf('.');
  const intPart: string = dot === -1 ? s : s.substring(0, dot);
  const fracPart: string = dot === -1 ? '' : s.substring(dot);
  let out: string = '';
  let count: number = 0;
  for (let i = intPart.length - 1; i >= 0; i--) {
    out = intPart.charAt(i) + out;
    count = count + 1;
    if (count % 3 === 0 && i > 0) {
      out = ',' + out;
    }
  }
  return out + fracPart;
}

/** 质量：≥1000 kg 转吨，≥100 吨取整，否则留一位小数 */
export function massText(kg: number): string {
  if (!Number.isFinite(kg) || kg <= 0) {
    return '';
  }
  if (kg >= 1000) {
    const t: number = kg / 1000;
    const shown: number = t >= 100 ? Math.round(t) : Math.round(t * 10) / 10;
    return thousands(shown) + ' 吨';
  }
  return Math.round(kg) + ' kg';
}

/** 造价：1 亿美元 / 1200 万美元 / 800 美元 */
export function costText(usd: number): string {
  if (!Number.isFinite(usd) || usd <= 0) {
    return '';
  }
  if (usd >= 100000000) {
    return (Math.round((usd / 100000000) * 10) / 10) + ' 亿美元';
  }
  if (usd >= 10000) {
    return Math.round(usd / 10000) + ' 万美元';
  }
  return Math.round(usd) + ' 美元';
}

/**
 * 地名字典。
 *
 * pad.location 是「场地, 州, 国」的整串（"Cape Canaveral SFS, FL, USA"），
 * 和机构那种精确 key 不同，只能拿已知地名的子串去比；
 * PLACE_ZH 的顺序即优先级（短的先命中会误伤长的，所以源里也刻意排过序）。
 * 命不中就原样返回 —— 宁可不翻，也不要把地点翻错。
 */
export function placeZh(loc: string): string {
  const s: string = strOf(loc);
  if (s.length === 0) {
    return '';
  }
  const low: string = s.toLowerCase();
  for (let i = 0; i < PLACE_ZH.length; i++) {
    const rule: PlaceRule = PLACE_ZH[i];
    if (low.indexOf(rule.key) !== -1) {
      return rule.zh;
    }
  }
  return s;
}

/**
 * 工位名缩写：Space Launch Complex 40 → SLC-40。
 *
 * 源实现是三条 /^…\s+/i 正则 replace；这里用「前缀比对 + 截断」，
 * 结果一致且不用处理转义。
 */
export function padShort(name: string): string {
  const s: string = strOf(name);
  if (s.length === 0) {
    return '';
  }
  const prefixes: string[] = ['space launch complex', 'launch complex', 'launch pad'];
  const shorts: string[] = ['SLC-', 'LC-', 'LP-'];
  const low: string = s.toLowerCase();
  for (let i = 0; i < prefixes.length; i++) {
    const p: string = prefixes[i];
    if (low.startsWith(p)) {
      return shorts[i] + s.substring(p.length).trim();
    }
  }
  return s;
}

/**
 * 型号完整名（含构型后缀）：「猎鹰 9 号 Block 5」。
 *
 * 拼之前先判断基础名到底是中文还是英文：
 *   - 基础名没译（仍是英文），直接给 full_name，别拼成 "Falcon 9 Block 5 Block 5"；
 *   - 基础名已含该后缀（例如名称本身就叫 "Starship V3"），不重复拼。
 */
export function rocketFullName(config: RocketConfig): string {
  if (config === undefined || config === null) {
    return '';
  }
  const zh: string = rocketName(config);
  if (zh.length === 0) {
    return '';
  }
  if (!hasHanzi(zh)) {
    const fullRaw: string = strOf(config.full_name);
    if (fullRaw.length > 0) {
      return fullRaw;
    }
    const nameRaw: string = strOf(config.name);
    return nameRaw.length > 0 ? nameRaw : zh;
  }

  const variant: string = strOf(config.variant).trim();
  if (variant.length === 0) {
    return zh;
  }
  const rawName: string = strOf(config.name);
  const nameHasVariant: boolean =
    rawName.toLowerCase().indexOf(variant.toLowerCase()) !== -1;
  const zhHasVariant: boolean = zh.indexOf(variant) !== -1;

  if (nameHasVariant) {
    // 名称本身已带构型（Falcon Heavy / Vulcan VC2S / Long March 2D），
    // 要判断中文名是否也译到了这一级：
    //   · 完整名有词条（Falcon Heavy → 猎鹰重型）→ 已译到，别再拼出「猎鹰重型 Heavy」
    //   · 长征走编号规则（2D → 丁）→ 已译到
    //   · 都没有（Vulcan VC2S 只匹配到前缀 Vulcan → 火神）→ 构型丢了，补回来
    const named: string = zhOf(ROCKET_ZH, rawName);
    const namedFull: string = zhOf(ROCKET_ZH, strOf(config.full_name));
    if (named.length > 0 || namedFull.length > 0 || zhLongMarch(rawName).length > 0) {
      return zh;
    }
    return zhHasVariant ? zh : zh + ' ' + variant;
  }
  return zhHasVariant ? zh : zh + ' ' + variant;
}

/** Salyut 1-7 → 礼炮一号…；其余站名靠 STATION_ZH 表 */
const SALYUT_RE: RegExp = new RegExp('^Salyut\\s+(\\d+)$', 'i');

/** 远征队名：Expedition 72 → 第 72 次远征 */
const EXPEDITION_RE: RegExp = new RegExp('^Expedition\\s+(\\d+)$', 'i');

export function expeditionName(raw: string): string {
  const s: string = strOf(raw).trim();
  if (s.length === 0) {
    return '';
  }
  const m: RegExpMatchArray | null = s.match(EXPEDITION_RE);
  if (m === null) {
    return s;
  }
  return '第 ' + group(m, 1) + ' 次远征';
}

/**
 * 活动名术语纠正。
 *
 * 机翻在几个航天专名上会翻车（JUICE → 「果汁」、Europa Clipper → 「欧罗巴快艇」、
 * Orbit Insertion → 「轨道插入」、Reentry → 「重返」）。数据层的 nameZh 是批量
 * 生成的，改一次要重跑整轮，所以在展示层做后处理，新增活动也自动生效。
 */
function fixEventTerms(text: string): string {
  let s: string = strOf(text);
  if (s.length === 0) {
    return '';
  }
  for (let i = 0; i < EVENT_TERM_FIX.length; i++) {
    const t: TermFix = EVENT_TERM_FIX[i];
    s = s.replace(t.re, t.to);
  }
  return s;
}

/**
 * 活动名。源实现吃 {nameZh, name} 对象；鸿蒙侧没有 Event 模型，
 * 改成两个字符串参数，调用方按 nameZh 优先传入即可。
 */
export function eventName(nameZh: string, name: string): string {
  const zh: string = strOf(nameZh);
  return fixEventTerms(zh.length > 0 ? zh : strOf(name));
}

/**
 * 国家/机构名 → ISO 两字母码。
 *
 * 数据里没有国别字段（launcher 只有 manufacturer 字符串，
 * launch_service_provider 只有 id + name），只能靠名字认。
 * FLAG_RULES 顺序即优先级：朝鲜在韩国前、乌克兰在俄罗斯前、
 * 具体国家在「欧洲」前、Rocket Lab USA 在 Rocket Lab 前 —— 见 ZhMaps.ets 注释。
 */
export function countryCode(name: string): string {
  const s: string = strOf(name).trim();
  if (s.length === 0) {
    return '';
  }
  for (let i = 0; i < FLAG_RULES.length; i++) {
    const rule: FlagRule = FLAG_RULES[i];
    if (rule.re.test(s)) {
      return rule.code;
    }
  }
  return '';
}

/** ISO 两字母码 → 国旗 emoji（地区指示符 A=0x1F1E6 … Z=0x1F1E6+25） */
function isoToFlagEmoji(code: string): string {
  const up: string = code.toUpperCase();
  if (up.length !== 2) {
    return '';
  }
  const base: number = 0x1F1E6;
  const a: number = up.charCodeAt(0) - 65;
  const b: number = up.charCodeAt(1) - 65;
  if (a < 0 || a > 25 || b < 0 || b > 25) {
    return '';
  }
  return String.fromCodePoint(base + a) + String.fromCodePoint(base + b);
}

/**
 * 国旗。
 *
 * ⚠ 与源实现的差异（有意为之）：源返回 '/static/flags/cn.png'，
 * 而鸿蒙侧的 resources/base/media 里**没有任何国旗图片**（只有 app_icon / startIcon），
 * 直接搬路径会 404。这里改成返回 emoji，语义仍是「可直接渲染的国旗」，
 * 调用方把 Image 换成 Text 即可，不必自己维护一份 emoji 表。
 */
export function flagOf(name: string): string {
  const code: string = countryCode(name);
  return code.length === 0 ? '' : isoToFlagEmoji(code);
}

/** flagOf 的兼容别名：老调用点还叫 flagSrc，返回值同样是 emoji，不是图片路径 */
export function flagSrc(name: string): string {
  return flagOf(name);
}

/** 空间站状态中文化（LL2 只有三种值） */
export function stationStatusZh(status: string): string {
  const s: string = strOf(status);
  if (s === 'Active') {
    return '在役';
  }
  if (s === 'Retired') {
    return '退役';
  }
  if (s === 'Under Construction') {
    return '建造中';
  }
  return s;
}

/** 远征队状态与空间站状态同一套枚举，直接转发 */
export function expeditionStatusZh(status: string): string {
  return stationStatusZh(status);
}

/** 简介正文：中文优先，回退英文 */
export function descText(descZh: string, desc: string): string {
  const zh: string = strOf(descZh);
  return zh.length > 0 ? zh : strOf(desc);
}

/** 简介是否需要折叠：源按字符数比（不是 textUnits），阈值默认 120 */
export function descNeedFold(text: string, limit: number): boolean {
  const n: number = limit > 0 ? limit : 120;
  return strOf(text).length > n;
}
