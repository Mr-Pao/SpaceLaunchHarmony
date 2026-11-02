/**
 * routes/NavParam.ets —— 路由入参类型
 *
 * 为什么用 class 不用 interface：
 *   1. ArkTS 要求 `NavPathStack.pushPathByName()` 的 param 是可序列化值，
 *      class 实例比 interface 更稳（interface 在运行时不存在，无法 new）；
 *   2. `@Prop` 的默认值必须是可实例化的东西，interface 不能直接当默认值。
 *
 * 每个 class 都带全参 constructor —— ArkTS 不允许无类型对象字面量，
 * 也不允许省略字段的部分构造，所以统一走 constructor 最省事。
 */

/** 发射详情页入参 */
export class LaunchNavParam {
  /** LL2 launch UUID，用于回连详情数据 */
  id: string = '';
  /** ISO 时间，用于「没有 id 时按时间反查」的兜底 */
  net: string = '';
  /** 页头展示用标题（任务名，已按 mission.nameZh || mission.name 取过） */
  title: string = '';

  constructor(id: string, net: string, title: string) {
    this.id = id;
    this.net = net;
    this.title = title;
  }
}

/** 图片详情页入参 */
export class PhotoNavParam {
  /** 图片完整地址（COS 直链） */
  url: string = '';
  /** 标题（发射名 / APOD 标题 / 宇航员名，视来源而定） */
  title: string = '';

  constructor(url: string, title: string) {
    this.url = url;
    this.title = title;
  }
}

/** 火箭详情页入参 */
export class RocketNavParam {
  /** 火箭名（LL2 rocket.configuration.name，如 "Falcon 9"） */
  name: string = '';

  constructor(name: string) {
    this.name = name;
  }
}
