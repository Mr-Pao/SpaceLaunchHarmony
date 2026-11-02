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
 *
 * 例外：ArticleNavParam 有 10 个字段（资讯详情要把列表里那条记录整条带过去，
 * 本页不拉网络）。给它写全参 constructor 会让调用点变成一长串同类型 string，
 * 顺序写错了编译器也不会报 —— 所以它是**无参构造 + 字段默认值 + 调用点逐字段赋值**，
 * 见 NewsListView.openArticle / TodayView.openNews。
 */

import { NewsLaunchRef } from '../model/News';

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

/**
 * 资讯详情页入参。
 *
 * 为什么把整个 NewsItem 的字段摊进来，而不是只传一个 id：
 *   news.json 没有「详情正文」这个字段，详情页要显示的就是列表里那条记录本身。
 *   只传 id 的话详情页得再 `repo.load('news')` 拉一次 100 余条全量才找得到自己，
 *   多一次几十 KB 的解析纯属浪费 —— 资讯详情应做到「点开即渲染、零等待」。
 *
 * 为什么没有全参 constructor：10 个字段里 9 个是 string，
 * 全参调用的实参顺序错了编译器不报错（类型相同），是最容易埋雷的写法。
 * 改为无参构造 + 调用点逐字段赋值，见 NewsListView.openArticle。
 *
 * 注意字段名与 NewsItem 保持一致，方便对照；但 `id` 在这里是 string
 * （路由参数通常当字符串用，且 NewsItem.id 是数字，跨类型赋值要显式转）。
 */
export class ArticleNavParam {
  /** SNAPI 数字 id，转成字符串保存（详情页只用来做 key，不做运算） */
  id: string = '';
  /** 英文标题（中文为空时的回退） */
  title: string = '';
  /** 中文标题，空串表示没翻出来 */
  titleZh: string = '';
  /** 英文摘要 */
  summary: string = '';
  /** 中文摘要，空串回退英文 */
  summaryZh: string = '';
  /** 封面（自家 CDN 镜像图），空串不画 Hero */
  image: string = '';
  /** 来源站名 */
  site: string = '';
  /** 原文链接。**只能复制，不能打开**（未配业务域名 / 无内置浏览器） */
  url: string = '';
  /** 北京时间完整时刻 "YYYY-MM-DD HH:mm"（不是 ISO，别拿去 Date.parse） */
  at: string = '';
  /**
   * 关联发射定位信息。
   * 用 NewsItem.launches（纯 UUID 列表）跳转会翻不到归档，必须用这份带 net 的。
   */
  launchRefs: NewsLaunchRef[] = [];
}
