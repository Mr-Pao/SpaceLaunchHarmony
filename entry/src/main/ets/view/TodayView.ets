/**
 * view/TodayView.ets —— 「今日」tab（1:1 复刻 pages/today/today.vue）
 *
 * 对位小程序 pages/today/today.vue 的完整结构（自上而下）：
 *   StarField 星空底层 → 顶部日期行 → 每日一览三卡（sl/apod/epic 横滑）→
 *   「下次发射」大卡（含秒级倒计时）→「往年今日」→「此刻在天上」→「航天资讯」→ 底部 padding 92vp。
 *
 * 数据链路（语义与 utils/data.js 对齐，谁先到谁先渲染，不 Promise.all 等齐）：
 *   gallery            → pickDaily 选每日一图，拼 sl 卡
 *   astronautsInspace  → 全量透传（数据集本身只有 inSpace 的十来条）
 *   upcoming(onUpdate) → next() 取「net 非空且 > now」最早 1 条
 *   onthisday(onUpdate)→ 透传 OnThisDay
 *   apod               → 取 list[0]
 *   epic               → 取 list[0]
 *
 * ── 相对任务书的取舍/偏差（都有理由）──
 *   1. 无路由。全工程没有 router / Navigation / NavDestination，视图回调无处跳转，
 *      onOpen/onMore/onSelect 等回调在页内做轻量处理（hilog 记录 + 详情留 TODO），
 *      等宿主层接路由后把 this.jumpToLaunch(...) 换成真实跳转即可。
 *   2. 每张每日卡只取数据源第一条（任务书口径）：APOD/EPIC 数据集每天只有 1~13 条，
 *      取 [0] 与小程序一致。
 *   3. sl 卡图用缩略图（对位 dailyCards 计算属性 `src: d.thumb`）。
 *      小程序 photo-detail 才升到原图（fullImageOf），鸿蒙侧没有详情页，就先缩略图。
 *   4. 底部 padding 92vp：与 GalleryView.ets:52 的既有口径一致（悬浮胶囊让位）。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { repo, LoadOptions } from '../data/Repository';
import { DataSet } from '../data/Repository';
import {
  strOf, formatDateTime, todayLabel
} from '../utils/Format';
import { GalleryItem, pickDaily, daySeed } from '../utils/Daily';
import { DailyCardItem, DailyCards } from '../components/DailyCards';
import { NextLaunch } from '../components/NextLaunch';
import { OnThisDay } from '../ two placeholder
