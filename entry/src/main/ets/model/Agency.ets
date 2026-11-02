/**
 * model/Agency.ets —— 机构（agencies 数据集）类型
 *
 * 对位小程序 pages/agencies/agencies.vue 与 scripts/lib/slim.js 的 slimAgency()。
 *
 * ── 字段口径：以线上 v14 实测为准，不按文档猜 ──
 *   实测 2026-11-02 拉 https://…/space-data/agencies.json（350 条，11 个键）：
 *     id(number) name abbrev type founding_year(string) description descriptionZh
 *     image_url(string) logo_url(string) country_code(string) launchers(string)
 *
 *   三处与旧文档/任务书不符，已在下面逐条注释：
 *     1. image_url / logo_url 是**纯字符串**（COS 直链），不是 LL2 的
 *        { image_url, thumbnail_url, credit } 对象 —— CI 侧已经在 slim 里摊平。
 *     2. founding_year 是**字符串**（如 "1960"，空串表示没有），不是 number。
 *     3. **没有** administrator / parent / launch_count 三个字段。
 *
 * 前缀约定：本文件所有类型一律 `Ag*`，避免与其它 model 的声明合并
 * （工程已占用 Rk* / Rt* / Gl* / St* / Ne* / Sa* / Ev* / Mn* / Se* / Vd*）。
 */

import { BasePayload } from './Common';

/** 机构（agencies.json 单条） */
export interface AgAgency {
  /** LL2 数字 id，进路由时统一 String() */
  id: number;
  /** 机构英文原名，例如 "Ad Astra Rocket Company" */
  name: string;
  /** 缩写，如 AARC / CNSA / NASA；多数机构为空串 */
  abbrev?: string;
  /**
   * 机构类型。线上实测只有 6 种取值：
   * Commercial / Government / Private / Multinational / Educational / Unknown
   */
  type?: string;
  /** 成立年份，字符串（"1960"）；空串表示无数据 */
  founding_year?: string;
  /** 英文简介，最长 593 字 */
  description?: string;
  /** 机翻中文简介，由 CI 回填；168/350 为空串，前端必须回退英文 */
  descriptionZh?: string;
  /** 实拍图（已镜像到自家 COS），仅 44/350 有值 */
  image_url?: string;
  /** 机构标识（已镜像），127/350 有值。长宽比不固定，展示要 aspectFit */
  logo_url?: string;
  /** 两位 ISO 码（US / CN / RU…）。有 "??" 这种脏值，前端要兜 */
  country_code?: string;
  /**
   * 现役运载火箭，**竖线分隔的长字符串**（"Falcon 9 | Falcon Heavy"），
   * 不是数组 —— LL2 原始结构就是这样，前端按 '|' 切。
   */
  launchers?: string;

  // ---- 下面三个字段线上暂不存在，留作上游补齐后自动生效 ----
  /** 上级机构（实测无此字段，行恒不画） */
  parent?: string;
  /** 负责人（实测无此字段，行恒不画） */
  administrator?: string;
  /** 累计发射次数（实测无此字段，行恒不画） */
  launch_count?: number;
}

/** agencies 载荷信封 */
export interface AgAgenciesPayload extends BasePayload {
  dataset?: string;
  count?: number;
  served?: number;
  list: AgAgency[];
}
