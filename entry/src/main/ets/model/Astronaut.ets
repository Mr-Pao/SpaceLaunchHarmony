/**
 * Astronaut.ets —— 宇航员相关类型
 *
 * 覆盖三个数据集（第一阶段只用 astronautsInspace，另两个同源、顺手写全）：
 *   astronauts.json          862 条全量，23 个键（detailed）
 *   astronauts-inspace.json  11 条，只有 8 个卡片字段
 *   astronauts-search.json   862 条，同样 8 个卡片字段（去掉 missions/evas/bio/wiki）
 *
 * 写入端：scripts/lib/slim.js 的 slimAstronaut()；
 * 派生集的字段清单在 scripts/sync.js:391 的 ASTRO_CARD_FIELDS。
 */

import { BasePayload } from './Common';

/**
 * 宇航员（全量版，对应 astronauts.json）。
 *
 * 关于 nameZh —— **本 interface 刻意不声明它**，尽管线上数据结构里确实有：
 *   实测 2026-11-02 线上 astronauts.json 862 条中 830 条 nameZh 非空，
 *   由 scripts/sync.js:287 的 fillAstronautNames() 在 CI 侧回填。
 *   之所以不写进来，是因为产品约定「中文名优先走前端专名表」：
 *   utils/format.js 的 CHINA_ASTRO_ZH 覆盖中国籍 30 人 + 香港黎家盈，
 *   命中就用表里的写法，查不到才回退 name。
 *   如果要改用 CI 回填值，把下面这行注释换成 `nameZh?: string;` 即可，
 *   数据侧无需任何改动（字段本来就存在）。
 *
 * 另外注意两处容易踩的命名：
 *   - 机构名字段叫 `agencyName`（不是 agency，也不是 agencyZh）
 *   - 国名字段叫 `nation`，slim 里优先取 nationality[0].name（France），
 *     拿不到才退 adjectives 形态（French）——前端映射表按国名组织
 */
export interface Astronaut {
  id: number;
  name: string;
  /** 状态名（Retired / Active …） */
  status?: string;
  /** 此刻是否在轨 */
  inSpace: boolean;
  /** 累计在轨天数（整数，向下取整） */
  days?: number;
  /** 累计出舱小时数（整数，四舍五入） */
  evaHours?: number;
  /** 年龄，LL2 部分人没有 */
  age?: number | null;
  /** 飞行次数 */
  flights?: number;
  /** 出舱次数 */
  spacewalks?: number;
  /** 国名（优先全称 France，退形容词 French） */
  nation?: string;
  /** 机构缩写优先，退全名 */
  agencyName?: string;
  /** 头像（缩略图） */
  img?: string;
  /** 头像署名 */
  credit?: string;
  /**
   * 英文简介。**只有在轨人员才有**：slim 里是 `bio: inSpace ? a.bio : ''`，
   * 因为详情页入口只有「此刻在天上」的卡片，离线人员没人会点进去。
   */
  bio?: string;
  /** 简介中文，CI 回填；空串表示没翻出来 */
  bioZh?: string;
  /** 生日 */
  dob?: string;
  /** 逝世日期，健在为空串 */
  dod?: string;
  wiki?: string;
  twitter?: string;
  instagram?: string;
  /**
   * 飞行任务（上下合并去重、新→旧排序、最多 10 条）。
   * slim 里空数组**不落字段**，所以可选。
   */
  missions?: AstronautMission[];
  /** 出舱记录（最多 8 条）。同样空数组不落字段 */
  evas?: AstronautEva[];
}

/**
 * 一次飞行任务。
 *
 * 字段名是缩写，别展开成驼峰：`st` = status.abbrev、`rk` = rocket full_name、
 * `dest` = destination。CI 侧就是这么写的，前端 pages/astronaut/astronaut.vue 也这么读。
 */
export interface AstronautMission {
  /** LL2 发射 UUID，点击可跳发射详情 */
  id: string;
  net: string;
  /** 状态缩写 */
  st?: string;
  /** 任务名（从 "火箭名 | 任务名" 里拆出来的后半段） */
  name?: string;
  /** 火箭全名 */
  rk?: string;
  /** 目的地（ISS / Tiangong …） */
  dest?: string;
}

/** 一次出舱（EVA）。h 是小时数 */
export interface AstronautEva {
  name?: string;
  /** 开始时刻 */
  start?: string;
  /** 时长（小时，保留一位小数） */
  h?: number;
  /** 地点 */
  loc?: string;
}

/**
 * 宇航员卡片字段（astronauts-inspace / astronauts-search 两个派生集用这个）。
 *
 * 就 8 个键，顺序与 scripts/sync.js:391 的
 *   ASTRO_CARD_FIELDS = ['id','name','nameZh','nation','agencyName','days','inSpace','img']
 * 一致。同样按产品约定不声明 nameZh（数据里其实有）。
 *
 * **注意 desc**：这 8 个里没有 desc/bio，所以卡片上不能显示简介。
 */
export interface AstronautCard {
  id: number;
  name: string;
  nation?: string;
  agencyName?: string;
  days?: number;
  inSpace: boolean;
  img?: string;
}

/** 全量宇航员库载荷（astronauts） */
export interface AstronautsPayload extends BasePayload {
  dataset?: string;
  count?: number;
  list: Astronaut[];
}

/**
 * 「此刻在天上」载荷（astronautsInspace）。
 *
 * 实测 11 条 / 2.2KB —— 启动页只该拉这一份，不要去拉 719KB 的全量库。
 */
export interface AstronautsInspacePayload extends BasePayload {
  dataset?: string;
  count?: number;
  list: AstronautCard[];
}

/** 搜索页浅字段载荷（astronautsSearch），862 条 / 172.7KB */
export interface AstronautsSearchPayload extends BasePayload {
  dataset?: string;
  count?: number;
  list: AstronautCard[];
}
