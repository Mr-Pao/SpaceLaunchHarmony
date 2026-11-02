/**
 * model/Pad.ets —— 发射工位（pads 数据集）类型
 *
 * 对位小程序 pages/pad/pad.vue 与 scripts/lib/slim.js 的 slimPad()。
 *
 * ── 字段口径：以线上 v14 实测为准（2026-11-02 拉 pads.json，251 条 / 14 个键）──
 *   id(number) name image(string) map_image(string) description descriptionZh
 *   info_url wiki_url latitude(number) longitude(number) active(bool)
 *   country_code(string) total_launch_count(number) location(object) agencies(object[])
 *
 * 三处与任务书线索不符，按实测写：
 *   1. `image` / `map_image` 都是**纯字符串**（COS 直链），不是 {url, credit} 对象。
 *      map_image 251/251 全有；image 只有 74/251。
 *   2. **没有 `agency_id` 单字段**，而是一个 `agencies` 数组（`[{id,name}]`），
 *      125/251 非空，且实测每条最多一个机构；其余是空数组。
 *   3. 计数字段只有两个：工位级 `total_launch_count` 与发射场级
 *      `location.total_launch_count`（没有 pad 自己的 orbital/orbital_attempt 系列）。
 *
 * 前缀约定：一律 `Pd*`，与工程已占用的 Rk*/Rt*/Gl*/St*/Ne*/Sa*/Ev*/Mn*/Se*/Vd* 无冲突；
 * 也刻意不复用 model/Common.ets 的 LaunchPad —— 那个是绑定在发射记录里的精简副本，
 * 没有 agencies 数组，硬套会丢字段。
 */

import { BasePayload } from './Common';

/** 工位所属发射场（location 子对象） */
export interface PdLocation {
  /** 发射场 id（LL2 数字 id） */
  id?: number;
  /** 发射场名，如 "Palmachim Airbase, State of Israel" */
  name?: string;
  /** 该发射场累计发射次数（不是这个工位的） */
  total_launch_count?: number;
}

/** 工位的运营机构引用（只带 id + 名字，用来跳机构详情） */
export interface PdAgencyRef {
  id: number;
  name: string;
}

/** 发射工位（pads.json 单条） */
export interface PdPad {
  /** LL2 数字 id，进路由时统一 String() */
  id: number;
  /** 工位英文名，如 "Space Launch Complex 40"（展示时走 padShort 缩写） */
  name: string;
  /** 实拍图（已镜像），74/251 有值 */
  image?: string;
  /** 示意地图（已镜像），251/251 全有 —— 所以 Hero 优先用它 */
  map_image?: string;
  /** 简介，多数为空串 */
  description?: string;
  /** 机翻中文简介，CI 回填 */
  descriptionZh?: string;
  /** 官网地址（本页不展示外链，仅保留字段） */
  info_url?: string;
  /** 维基地址（本页不展示外链，仅保留字段） */
  wiki_url?: string;
  /** 纬度，3 条记录缺失 */
  latitude?: number;
  /** 经度，3 条记录缺失 */
  longitude?: number;
  /** 是否现役 */
  active?: boolean;
  /** 两位 ISO 码；12/251 是空串 */
  country_code?: string;
  /** 该工位累计发射次数（251/251 都有） */
  total_launch_count?: number;
  /** 所属发射场 */
  location?: PdLocation;
  /** 运营机构数组（实测每条约 0~1 个） */
  agencies?: PdAgencyRef[];
}

/** pads 载荷信封 */
export interface PdPadsPayload extends BasePayload {
  dataset?: string;
  count?: number;
  served?: number;
  list: PdPad[];
}
