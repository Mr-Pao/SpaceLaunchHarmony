/**
 * News.ets —— 航天资讯类型（SNAPI v4，免 key）
 *
 * 数据集：news.json，CI 每 3 小时一轮，保留最近 200 条（线上实测 count=102）。
 * 写入端：scripts/news.js（含中文化、封面复查、关联发射三道后处理）。
 *
 * 三个容易踩的点（都写进字段注释里了）：
 *   1. `launches[]` 是「本文提到的发射集合」，**不是主角**，可以 0 个也可能 6 个；
 *   2. `launchRefs` 才是前端可直接跳转的定位信息，且**必须带 net** ——
 *      没有 net 就翻不到归档分片，点进去必然「未找到」，所以 CI 会把这类整条丢掉；
 *   3. `titleZh` / `summaryZh` 翻不出来是**空串**，不是 undefined，前端要 `||` 回退英文。
 */

import { BasePayload } from './Common';

/**
 * 一条资讯。
 *
 * 时间有两个字段，别混：
 *   at      → "2026-10-28 13:39"（完整，详情页用；注意**是北京时间字符串，不是 ISO**）
 *   atShort → "10-28 13:39"（列表用，就是 at.slice(5)）
 */
export interface NewsItem {
  /** SNAPI 的数字 id */
  id: number;
  title: string;
  /** 摘要，已清洗：去掉 APOD 尾句 / "appeared first on ..." / 按词边界截断 */
  summary?: string;
  /** 封面，一律自家 CDN 镜像图（SNAPI 快照 URL 会失效） */
  image?: string;
  /** 来源站名（SpaceNews / NASASpaceflight …） */
  site?: string;
  /** 原文链接。**只能复制，不能 web-view 打开**（未配业务域名） */
  url?: string;
  /** 北京时间完整时刻，"YYYY-MM-DD HH:mm" */
  at?: string;
  /** 列表用短格式，"MM-DD HH:mm" */
  atShort?: string;
  /**
   * 本文提到的 LL2 发射 UUID 列表（最多 8 个）。
   * 数组顺序是 SNAPI 的提及顺序，**没有语义**，不要当「主角」用。
   */
  launches?: string[];
  /** 标题中文，空串表示没翻出来 → 前端回退 title */
  titleZh?: string;
  /** 摘要中文，空串回退 summary */
  summaryZh?: string;
  /**
   * 关联发射的定位信息，按 |net - 发布时间| 升序排好 ——
   * 前端「一条直接跳、多条让用户选」正好用这个顺序。
   * 全部定位失败时该字段被 delete，所以可选。
   */
  launchRefs?: NewsLaunchRef[];
  /**
   * 封面重试次数。置空不等于放弃：还有次数就下轮再试。
   * 抓够了（>= MAX_COVER_TRIES）才留着这个数让下轮跳过。
   * 前端不消费，这里写出来只为完整。
   */
  coverTries?: number;
}

/** 一条资讯关联的发射（供点击跳转 + 弹窗选择） */
export interface NewsLaunchRef {
  /** LL2 发射 UUID */
  id: string;
  /** 发射时刻。**跳转归档分片必须靠它**，缺了就等于进不去 */
  net: string;
  /** 任务名；资讯里显示「所属任务 · MSL｜2011-11-26」用 */
  name?: string;
}

/** 资讯载荷 */
export interface NewsPayload extends BasePayload {
  dataset?: string;
  count?: number;
  list: NewsItem[];
}
