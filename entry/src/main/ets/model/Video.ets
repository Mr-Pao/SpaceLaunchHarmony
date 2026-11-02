/**
 * model/Video.ets —— 「视频库」的类型与展平逻辑
 *
 * 数据集：videos.json（COS 前缀 space-data，SOFT_TTL 6 小时，见 constants/Dataset.ets:189）。
 * **单文件不分片**：一次 load 就是全量（线上实测 count ≈ 341，信封里 total 7662、
 * cursor 440 —— 那俩是 CI 侧的抓取游标，不是前端分页信息，别拿它们算「还有多少」）。
 *
 * 真实结构（2026-11-03 本地 dist/videos.json 实测 35 条 / 74 个 vids 核对）：
 *   { v, dataset, generatedAt, count, served, cursor, total, list }
 *   list 单条 = { id, name, net, at, vids[] }
 *   vids 单条 = { url, title, publisher, kind, tid, cover, start, mins, live }
 *   kind 实测三~四种：'Official Webcast' | 'Unofficial Webcast' | 'Unofficial Re-stream' | 'Recap'
 *   tid：1 官方 / 3 转播 / 4 重播
 *
 * ── 三个必须记住的字段陷阱 ──
 *   1. `at` 是**抓取时刻**（ISO），`net` 才是发射时刻。要显示「发射时间」用 net，
 *      并且必须过 utils/Format 的 formatLaunchTime（那边才处理东八区与跨年）。
 *   2. `vids[].start` 是直播开始时刻，`mins` 是时长分钟数（整数，实测 21 / 47 / 173）。
 *   3. 排序看 `tid`，**不能看 priority**：LL2 的 priority 与「官方优先」是反的
 *      （官方 priority 最大），小程序当初就栽在这一条上。
 *
 * ── 为什么这里不 import utils/Format ──
 * model 层保持零依赖（与 model/Event.ets 同约定），避免将来 Format 反向依赖某个
 * model 时踩成循环引用。所以下面自带一个三行的 vdStr，时间格式化留给视图层。
 *
 * ArkTS 约束：禁 any / 禁索引签名 / 不写 @Component；对象字面量一律带显式类型注解。
 */

import { BasePayload } from './Common';

/**
 * 一条视频源。
 *
 * 除 url 外全部可选：JSON.parse 的 `as` 只是编译期断言、运行时零校验，
 * 上游某天少个字段不能让整页崩。读取端一律先用 vdStr 包一层。
 */
export interface VideoRef {
  /** 播放地址（YouTube / X 直播页），**必填**，空串的记录在展平时丢弃 */
  url: string;
  title?: string;
  /** 发布渠道，如 SpaceX / Spaceflight Now / The Space Devs */
  publisher?: string;
  /** 英文类型名，见文件头；只用于展示兜底，排序一律用 tid */
  kind?: string;
  /** 1 官方 / 3 转播 / 4 重播 */
  tid?: number;
  /** 已镜像到自家 COS 的 480px 封面（≤30KB），可直接 Image() */
  cover?: string;
  /** 直播开始时刻，ISO 8601 */
  start?: string;
  /** 时长（整数分钟） */
  mins?: number;
  /** 抓取时是否仍在直播 */
  live?: boolean;
}

/** 一次发射下挂的全部视频 */
export interface VideoItem {
  /** LL2 发射 UUID */
  id: string;
  /** 发射名（如 "Falcon 9 Block 5 | Starlink Group 15-15"） */
  name: string;
  /** **发射时刻**（不是抓取时刻），显示前过 formatLaunchTime */
  net?: string;
  /** 抓取时刻，仅用于排查数据新鲜度，界面不显示 */
  at?: string;
  vids?: VideoRef[];
}

/**
 * videos 载荷信封。
 *
 * cursor / total 是 CI 的抓取进度（440 / 7662）：表示「上游还有这么多没抓」，
 * 前端既无法也没有必要去补 —— 别拿它做「加载更多」的文案。
 */
export interface VideosPayload extends BasePayload {
  dataset?: string;
  /** 本次文件里的发射条数（≈341） */
  count?: number;
  served?: number;
  /** CI 抓取游标 */
  cursor?: number;
  /** 上游总量（7662），只作参考 */
  total?: number;
  list: VideoItem[];
}

/**
 * UI 用的展平行 —— 一条视频 = 一行。
 *
 * 小程序是把「发射 → vids」摊平后再渲染（video-gallery.vue:144-163），
 * 鸿蒙侧同样摊平：列表项要能独立回收，层次一深 List 的复用就白做了。
 * 发射名与 net 一并带下来，卡片下方才能显示「发射 11月5日 20:30」。
 */
export interface VideoRow {
  /** 去重后的唯一键（就是 url），ForEach 的 key 用它 */
  vidKey: string;
  url: string;
  /**
   * 所属发射的 LL2 UUID（list[].id）。
   * 路由从发射详情跳过来带的是这个 id 而不是视频链接，
   * 所以定位要同时支持「按 url」与「按 launchId」两种入参。
   */
  launchId: string;
  /** 视频标题；空则回退发射名，再空则「发射视频」 */
  title: string;
  publisher: string;
  kind: string;
  /** 1 官方 / 3 转播 / 4 重播 / 0 未知 */
  tid: number;
  cover: string;
  start: string;
  /** 整数分钟，0 表示没数据（不画时长胶囊） */
  mins: number;
  live: boolean;
  /** 发射时刻（不是抓取时刻） */
  net: string;
  /** 所属发射名，标题为空时兜底 */
  launchName: string;
  /** tid === 1，筛选与徽标都用它 */
  official: boolean;
}

/** null / undefined → 空串（与 utils/Format 的 strOf 同语义，见文件头） */
function vdStr(v: string | null | undefined): string {
  return v !== undefined && v !== null ? v : '';
}

/** ISO → 毫秒，解析失败返回 0（不用 NaN 往下传，比较时才不会全假） */
function vdTime(v: string): number {
  const t: number = Date.parse(v);
  return Number.isNaN(t) ? 0 : t;
}

/**
 * tid → 排序档位。
 *
 * 注意 tid 是数字、不是字符串（实测 1 / 3 / 4）。未知值排最后而不是排除：
 * 上游将来加 2（比如「官方回放」）时，宁可多出一条排末尾，也不要静默消失。
 */
function vdRank(tid: number): number {
  if (tid === 1) {
    return 0;
  }
  if (tid === 3) {
    return 1;
  }
  if (tid === 4) {
    return 2;
  }
  return 3;
}

/**
 * 时长胶囊文案：`21:00` / `1:21:00`。
 *
 * 只有整数分钟可用，所以秒位恒为 00。小于一小时给 mm:ss（与 YouTube 一致），
 * 超过一小时补小时段 —— 「173 分钟」要用户心算，`2:53:00` 一眼就懂。
 */
export function vdDuration(mins: number): string {
  const m: number = mins > 0 ? Math.round(mins) : 0;
  if (m <= 0) {
    return '';
  }
  const h: number = Math.floor(m / 60);
  const rest: number = m % 60;
  const mm: string = rest < 10 ? '0' + String(rest) : String(rest);
  if (h <= 0) {
    return String(m) + ':00';
  }
  return String(h) + ':' + mm + ':00';
}

/**
 * 类型徽标文案。
 *
 * 优先按 tid 判定（排序依据同一个字段，展示口径才一致），tid 缺失时才看 kind 字符串。
 * 不用 kind 原文：'Unofficial Re-stream' 在 11vp 的徽标里放不下。
 */
export function vdKindLabel(tid: number, kind: string): string {
  if (tid === 1) {
    return '官方直播';
  }
  if (tid === 3) {
    return '转播';
  }
  if (tid === 4) {
    return '重播';
  }
  if (kind === 'Official Webcast') {
    return '官方直播';
  }
  if (kind === 'Unofficial Webcast') {
    return '第三方直播';
  }
  if (kind === 'Unofficial Re-stream') {
    return '转播';
  }
  if (kind === 'Recap') {
    return '重播';
  }
  return '视频';
}

/**
 * 把 videos 载荷摊平成 UI 行。
 *
 * @param limit 最多返回多少行；<= 0 表示不限制。
 *              页面自己按 20 条一屏切片，这里给 0 拿全量 —— 全量放普通成员，
 *              不进 @State（341 个对象被状态代理不划算）。
 *
 * 三件事必须在这里做完，否则视图层会各写一遍：
 *   ① 丢掉没有 url 的记录（点了没反应比没有更糟）；
 *   ② 按 url 去重 —— 同一场直播常被同一发射的多个条目重复收录；
 *   ③ 排序 = tid 档位优先，同档内发射时间新的在前（直播列表的常识）。
 */
export function flattenVideos(payload: VideosPayload, limit: number): VideoRow[] {
  const rows: VideoRow[] = [];
  if (payload === null || payload === undefined) {
    return rows;
  }
  const list: VideoItem[] = payload.list !== undefined && payload.list !== null ? payload.list : [];
  const seen: Set<string> = new Set<string>();

  for (let i = 0; i < list.length; i++) {
    const item: VideoItem = list[i];
    if (item === null || item === undefined) {
      continue;
    }
    const net: string = vdStr(item.net);
    const launchId: string = vdStr(item.id).trim();
    const launchName: string = vdStr(item.name).trim();
    const vids: VideoRef[] = item.vids !== undefined && item.vids !== null ? item.vids : [];

    for (let j = 0; j < vids.length; j++) {
      const v: VideoRef = vids[j];
      if (v === null || v === undefined) {
        continue;
      }
      const url: string = vdStr(v.url).trim();
      if (url.length === 0) {
        continue;
      }
      if (seen.has(url)) {
        continue;
      }
      seen.add(url);

      const tid: number = v.tid !== undefined && v.tid !== null ? v.tid : 0;
      const ownTitle: string = vdStr(v.title).trim();
      const title: string = ownTitle.length > 0
        ? ownTitle
        : (launchName.length > 0 ? launchName : '发射视频');

      // 显式类型注解是 ArkTS 的硬要求（禁无类型对象字面量），不是风格问题
      const row: VideoRow = {
        vidKey: url,
        url: url,
        launchId: launchId,
        title: title,
        publisher: vdStr(v.publisher).trim(),
        kind: vdStr(v.kind).trim(),
        tid: tid,
        cover: vdStr(v.cover).trim(),
        start: vdStr(v.start),
        mins: v.mins !== undefined && v.mins !== null ? v.mins : 0,
        live: v.live === true,
        net: net,
        launchName: launchName,
        official: tid === 1
      };
      rows.push(row);
    }
  }

  rows.sort((a: VideoRow, b: VideoRow): number => {
    const ra: number = vdRank(a.tid);
    const rb: number = vdRank(b.tid);
    if (ra !== rb) {
      return ra - rb;
    }
    const ta: number = vdTime(a.net);
    const tb: number = vdTime(b.net);
    if (ta !== tb) {
      return tb - ta;
    }
    // 同一场发射的多个源：直播开始得晚的更接近「正片」
    return vdTime(b.start) - vdTime(a.start);
  });

  if (limit > 0 && rows.length > limit) {
    return rows.slice(0, limit);
  }
  return rows;
}
