/**
 * Apod.ets —— 每日天文 / 每日地球类型
 *
 * 两个数据集，首页「每日一览」轮播的三张卡里占两张：
 *   apod.json  NASA Astronomy Picture of the Day，近 7 天（线上实测 93 条累积）
 *   epic.json  NASA EPIC（DSCOVR 拍的地球），当天若干帧（线上实测 13 条）
 *
 * 写入端：scripts/nasa-daily.js。
 *
 * 两个数据集都属于 EMPTY_SUSPECT：拿到空列表时数据层会绕缓存再取一次，
 * 因为「空」几乎总是上游故障留下的，不能当真缓存起来。
 */

import { BasePayload } from './Common';

/**
 * 一条 APOD。
 *
 * 注意 `media_type !== 'image'` 的日子（NASA 会发 YouTube 视频）**被 CI 直接跳过**，
 * 所以这里不会有视频条目，也不需要 media_type 字段。
 *
 * thumb 与 full 在 APOD 里**同源同值**（nasa-daily.js 里 `thumb: url, full: url`），
 * 都是已镜像到自家 COS 的图；区分两个字段名只是为了与界面语义对齐，
 * 将来若要改成真缩略图不必动调用方。
 */
export interface ApodItem {
  /** "YYYY-MM-DD" */
  date: string;
  title?: string;
  /** 正文。已去掉开头的 "Explanation:" 标签词，也去过 HTML */
  explanation?: string;
  /** 列表 / 卡片用图 */
  thumb?: string;
  /** 详情页大图 */
  full?: string;
  /** 署名（NASA 原文的 credit 或 copyright） */
  credit?: string;
  /** 标题中文，空串回退 title */
  titleZh?: string;
  /** 正文中文，空串回退 explanation */
  explanationZh?: string;
}

/**
 * 一条 EPIC。
 *
 * 图片是 DSCOVR 卫星拍的整幅地球，`thumb` / `full` 同样是同源同值的 PNG。
 * 没有 credit 字段（NASA/EPIC 固定署名，前端写死即可）。
 */
export interface EpicItem {
  /** "YYYY-MM-DD" */
  date: string;
  /** 官方图注（英文），可能为空串 */
  caption?: string;
  thumb?: string;
  full?: string;
  /** 图注中文，空串回退 caption */
  captionZh?: string;
}

/**
 * APOD 载荷。
 *
 * TODO 需真实数据确认：线上 apod.json 里曾有 `text` / `media_type` 一类原始字段吗？
 * 按 nasa-daily.js 的写入代码只有上面 8 个键（外加翻译回填的 titleZh/explanationZh），
 * 这里按 8 个写。若将来 CI 侧把视频日也收进来，需要补 media_type 与 videoUrl。
 */
export interface ApodPayload extends BasePayload {
  dataset?: string;
  count?: number;
  list: ApodItem[];
}

/** EPIC 载荷。同理按写入端实际字段（5 个 + captionZh）来写 */
export interface EpicPayload extends BasePayload {
  dataset?: string;
  count?: number;
  list: EpicItem[];
}
