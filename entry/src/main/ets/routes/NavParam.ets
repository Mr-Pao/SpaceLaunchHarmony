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
  /**
   * 以下四个字段对位小程序 photo-detail 的 `_photo_detail` Storage 载荷
   * （`pages/gallery/gallery.vue:407` 写入 `{full, title, date, intro, credit, tag}`）。
   *
   * 为什么不放进 constructor：现有 10 个 pushPhoto 调用点里只有图库那一路有这些值，
   * 再加 4 个同类型 string 会让调用点变成一长串参数、顺序写错编译器也不报。
   * 所以保持两参构造，需要的调用点 new 完再逐字段赋值
   * （与 ArticleNavParam 同一取舍，见本文件头说明）。
   */
  /** 日期（YYYY-MM-DD，来自 apod / epic / nasaImages 的 date） */
  date: string = '';
  /** 版权署名（不含 @ 前缀，渲染时页面自己补） */
  credit: string = '';
  /** 分类标签（每日天文 / 每日地球 / 每日一图 …），兼作顶栏兜底标题 */
  tag: string = '';
  /** 中文介绍正文（apod 的 explanationZh、epic 的 captionZh，可能上千字） */
  intro: string = '';

  constructor(url: string, title: string) {
    this.url = url;
    this.title = title;
  }
}

/**
 * 型号媒体库入参（图片库 / 视频库）。
 *
 * 小程序 media.vue 的入口传的是 LL2 的 config.id（数字），但鸿蒙侧
 * RocketNavParam 只有 name、AgencyView 拿到的也是名字，所以这里统一用型号名，
 * MediaView 内部再回到 launchers 里按名字找构型 —— 与 RocketDetailView 同一口径。
 */
export class MediaNavParam {
  /** 型号英文原名（launchers 的 name，不是中文译名） */
  name: string = '';
  /** 0 = 图片库，1 = 视频库（对位小程序 goMedia(tab) 的 tab 参数） */
  tab: number = 0;

  constructor(name: string, tab: number) {
    this.name = name;
    this.tab = tab;
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

/**
 * 航天员详情入参。
 *
 * id 用 string 而不是 number：AstronautCard.id 是 number，但路由参数、
 * favorites 的 id、URL 都当字符串流转，统一在入口 String() 一次，
 * 免得页内到处写 String(item.id) 比较。
 */
export class AstronautNavParam {
  /** LL2 航天员数字 id 的字符串形式 */
  id: string = '';
  /** 姓名（英文原名，详情页拿到数据前先显示它，避免顶部空标题） */
  name: string = '';

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

/**
 * 机构详情入参。
 *
 * 同时带 id 和 name：LL2 的 agencies 里 id 是 number，而详情页拿到的可能是
 * 从 pads / launchers 里带出来的名字（那些地方只有 agency 名没有 id）。
 * 两个都传，页内先按 id 找、找不到再按名字匹配 —— 比在调用方判断更省事。
 */
export class AgencyNavParam {
  /** LL2 agency id 的字符串形式，空串表示按名字匹配 */
  id: string = '';
  /** 机构名（英文原名），id 为空时用它兜底匹配 */
  name: string = '';

  constructor(id: string, name: string) {
    this.id = id;
    this.name = name;
  }
}

/**
 * 工位详情入参。理由同 AgencyNavParam：id 可能缺，name 常能从发射数据里拿到。
 */
export class PadNavParam {
  id: string = '';
  name: string = '';
  /**
   * 发射场名（= pads 里 pad.location.name 的原文）。
   *
   * 为什么需要它：LL2 的发射记录里 pad 对象**不带 id**，只能拿 name 去 pads 数据集
   * 反查；而 pads.json 里 `name` 为 "Unknown Pad" 的多达数条（不同发射场各一条），
   * 光按 name 精确匹配会稳定命中第一条（Sea Launch），点 Mahia 会跳到夏威夷。
   * 所以带上 location.name 做二次消歧。空串表示调用方没有场地信息。
   */
  place: string = '';

  constructor(id: string, name: string, place: string) {
    this.id = id;
    this.name = name;
    this.place = place;
  }
}

/**
 * 视频库入参。
 *
 * 目前只有「从发射详情点进来时定位到某个发射的视频」这一种用法，
 * 所以只带 launchId；空串表示看全量视频列表。
 */
export class VideoNavParam {
  /** LL2 发射 UUID，空串表示不筛选 */
  launchId: string = '';

  constructor(launchId: string) {
    this.launchId = launchId;
  }
}

/**
 * 全局搜索入参。
 *
 * 只有「进页时的初始关键词」一项：搜索本身在页内即时过滤，
 * 不进路由参数（否则每敲一个字都要 push 一次）。
 */
export class SearchNavParam {
  /** 进页即填进输入框的关键词，空串表示只显示「可以搜什么」的引导 */
  keyword: string = '';

  constructor(keyword: string) {
    this.keyword = keyword;
  }
}

/**
 * 空间站详情入参。
 *
 * 只有 id 一项：spacestations 只有 15 条，详情页用 repo.peek 同步拿全量后按 id 匹配，
 * 不需要调用方再传名字（传了反而两处可能不一致）。
 * id 用 string：LL2 里它是 number，入口统一 String() 一次，页内只做字符串比较。
 */
export class StationNavParam {
  /** spacestations 的 id（number 转字符串），空串表示匹配不到 */
  id: string = '';

  constructor(id: string) {
    this.id = id;
  }
}

/**
 * 远征队详情入参。
 *
 * 与 StationNavParam 同构：expeditions 165 条、体积小，页内 peek 全量按 id 匹配。
 */
export class ExpeditionNavParam {
  /** expeditions 的 id（number 转字符串） */
  id: string = '';

  constructor(id: string) {
    this.id = id;
  }
}

/**
 * 活动（EVA / 入轨 / 对接）详情入参。
 *
 * events 只有 26 条，同样是页内 peek 全量后按 id 匹配。
 */
export class EventNavParam {
  /** events 的 id（number 转字符串） */
  id: string = '';

  constructor(id: string) {
    this.id = id;
  }
}
