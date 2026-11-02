/**
 * Dataset.ets —— 数据层常量（ArkTS 版）
 *
 * 逐条对位原项目 utils/data.js 的 FILES / SOFT_TTL / EVICT_ORDER / HOURLY_CACHE
 * 与 cacheKey() / galleryChunk() / satelliteChunk() 的 URL 拼接。
 *
 * 与 data.js 的两处写法差异（语义完全一致）：
 *   1. 对象字面量 → Map。ArkTS 严格模式禁止用对象字面量声明带索引签名的常量，
 *      而 Record<K, V> 在 ArkTS 里同样受限，故统一改用 Map<K, V>。
 *   2. data.js 里没有 IMG_BASE 这个常量（图片域名散落在 scripts/lib/image.js），
 *      这里按需求补上，值取同一个 COS 桶的 space-img 前缀。
 *
 * 数据文件全部由 GitHub Actions 在 CI 侧产出并直传 COS，前端只读。
 */

const MINUTE: number = 60 * 1000;
const HOUR: number = 60 * MINUTE;
const DAY: number = 24 * HOUR;

// ============ 基础常量 ============

/** 数据 JSON 前缀（COS 直连域名，无 CDN 缓存层，控制台改完即生效） */
export const CDN_BASE: string = 'https://spacelaunch-1258113633.cos.ap-chengdu.myqcloud.com/space-data';

/** 图片前缀（缩略图仓库，缓存一年） */
export const IMG_BASE: string = 'https://spacelaunch-1258113633.cos.ap-chengdu.myqcloud.com/space-img';

/**
 * 全局数据结构版本。**只在 slim 结构变化时升**（升了 = 全部数据集缓存失效）。
 * 升级时必须与 CI 侧十处同改：utils/data.js、scripts/{sync,images,gcat,nasa-daily,
 * nasa-images,neo,news}.js 的 const，以及 scripts/{videos,timeline}.js 载荷里的 v。
 */
export const DATA_VERSION: number = 14;

/**
 * 图库独立小版本。图库天天涨，不该牵动全局缓存，所以单独挂在 v{DATA_VERSION}.{GALLERY_V}。
 */
export const GALLERY_V: number = 1;

/**
 * GCAT 三数据集的独立小版本（3.2.7 修正了数据口径，靠它强制重拉一次）。
 * 对应 data.js 的 GCAT_V。
 */
export const GCAT_V: number = 2;

/** 默认请求超时（毫秒），原封不动沿用 data.js */
export const REQUEST_TIMEOUT: number = 8000;

/** 软 TTL 兜底值：数据集没在 SOFT_TTL 里登记时用它（15 分钟） */
export const DEFAULT_SOFT_TTL: number = 15 * MINUTE;

// ============ 数据集名 ============

/**
 * 27 个数据集键。
 *
 * 用字符串字面量联合类型而不是 enum：原项目大量 `load('upcoming')` 这种调用，
 * 字面量联合能直接接受字符串、不用先转 enum，迁移时改动量最小。
 */
export type DatasetName =
  | 'upcoming'
  | 'upcomingMore'
  | 'previous'
  | 'events'
  | 'agencies'
  | 'launchers'
  | 'cores'
  | 'astronauts'
  | 'astronautsInspace'
  | 'astronautsSearch'
  | 'spacestations'
  | 'expeditions'
  | 'dockings'
  | 'pads'
  | 'stats'
  | 'onthisday'
  | 'timelines'
  | 'videos'
  | 'gallery'
  | 'satellites'
  | 'orbitStats'
  | 'debrisEvents'
  | 'neoNears'
  | 'news'
  | 'apod'
  | 'epic'
  | 'nasaImages';

/** 可分片拉取的两个数据集 */
export type ChunkName = 'gallery' | 'satellites';

// ============ FILES（27 项，必须与 utils/data.js 完全一致） ============

/**
 * 数据集 → COS 文件名。
 *
 * 键名与文件名的对应关系不是机械转换，下面逐项标出**不是同名**的那几个：
 *   stats → stats-years.json / orbitStats → orbit-stats.json /
 *   debrisEvents → debris-events.json / neoNears → neo-nears.json /
 *   astronautsInspace → astronauts-inspace.json / astronautsSearch → astronauts-search.json /
 *   upcoming → launches-upcoming.json / upcomingMore → launches-upcoming-more.json /
 *   previous → launches-previous.json / nasaImages → nasa-images.json
 * 其余 17 个是「键名 + .json」。
 */
export const FILES: Map<DatasetName, string> = new Map<DatasetName, string>([
  ['upcoming', 'launches-upcoming.json'],
  // 即将发射的第 100 条之后（每天更新一次，首页翻到底时加载）
  ['upcomingMore', 'launches-upcoming-more.json'],
  ['previous', 'launches-previous.json'],
  ['events', 'events.json'],
  ['agencies', 'agencies.json'],
  // 火箭型号库（532 个型号，含技术参数）
  ['launchers', 'launchers.json'],
  // 芯级个体库（196 枚真实第一级硬件）
  ['cores', 'cores.json'],
  // 宇航员库（862 人，detailed）
  ['astronauts', 'astronauts.json'],
  // 启动页专用的轻量版：只有 inSpace 的十来条 + 卡片字段（实测 11 条 / 2.2KB）
  ['astronautsInspace', 'astronauts-inspace.json'],
  // 搜索页专用的浅字段版：862 条，去掉 missions / evas / bio / wiki
  ['astronautsSearch', 'astronauts-search.json'],
  // 空间站（15 个）
  ['spacestations', 'spacestations.json'],
  // 远征队（165 条）
  ['expeditions', 'expeditions.json'],
  // 对接事件（飞船→空间站）
  ['dockings', 'dockings.json'],
  // 发射工位库（251 个 pad）
  ['pads', 'pads.json'],
  // 统计页数据：CI 侧按年预聚合
  ['stats', 'stats-years.json'],
  // 往年今日：CI 侧按「月-日」筛好的历史发射（最多 40 条）
  ['onthisday', 'onthisday.json'],
  // 发射时间线（T- 序列），CI 每 3 小时抓 8 条
  ['timelines', 'timelines.json'],
  // 发射视频（官方直播 / 回放 / 第三方转播），按 id 索引
  ['videos', 'videos.json'],
  // 图库：**索引 + 第 0 片**，后续片走 gallery/N.json
  ['gallery', 'gallery.json'],
  // 航天器/卫星百科（GCAT 活跃子集）：**索引 + 第 0 片**
  ['satellites', 'satellites.json'],
  // 全球在轨资产聚合统计（total + byState/byOrbit/byDecade，无逐条 list）
  ['orbitStats', 'orbit-stats.json'],
  // 在轨解体 / 再入事件流
  ['debrisEvents', 'debris-events.json'],
  // 近地天体：未来 7 天飞掠地球的小行星（NASA NeoWs）
  ['neoNears', 'neo-nears.json'],
  // 航天资讯（SNAPI v4），CI 每 3 小时一轮
  ['news', 'news.json'],
  // NASA 每日天文（APOD 近 7 天）
  ['apod', 'apod.json'],
  // 每日地球（EPIC 当天）
  ['epic', 'epic.json'],
  // NASA Image Library 主题精选
  ['nasaImages', 'nasa-images.json']
]);

// ============ SOFT_TTL（27 项，全覆盖） ============

/**
 * 软过期时间：超过就认为「可以先展示、但值得后台刷新一次」。
 *
 * 与抓取频率对齐、并略大于它，避免刚生成就被判过期。
 * 实测 data.js 的 SOFT_TTL **27 个键一个不缺**，所以 getSoftTTL() 的兜底值
 * 实际上永远不会命中 —— 但函数仍然保留兜底，防止将来加数据集时漏登记。
 */
export const SOFT_TTL: Map<DatasetName, number> = new Map<DatasetName, number>([
  ['upcoming', 15 * MINUTE],
  ['previous', 60 * MINUTE],
  ['events', 30 * MINUTE],
  ['agencies', DAY],
  // 以下都是每天才更新一次的大数据集，统一放宽到 12 小时，
  // 否则每次进页都触发后台刷新白拉一遍
  ['upcomingMore', 12 * HOUR],
  ['launchers', 12 * HOUR],
  ['cores', 12 * HOUR],
  ['astronauts', 12 * HOUR],
  // 两个派生版跟主库同源、同频率
  ['astronautsInspace', 12 * HOUR],
  ['astronautsSearch', 12 * HOUR],
  ['spacestations', 12 * HOUR],
  ['expeditions', 12 * HOUR],
  ['dockings', 12 * HOUR],
  ['pads', 12 * HOUR],
  ['stats', 12 * HOUR],
  // 往年今日：北京时间过 0 点就换一天，不能等 12 小时
  ['onthisday', 60 * MINUTE],
  ['timelines', 3 * HOUR],
  ['videos', 6 * HOUR],
  // 图库每小时都在补图，1 小时软过期
  ['gallery', 60 * MINUTE],
  // GCAT 季度才更新一次，但数据集较大
  ['satellites', 12 * HOUR],
  ['orbitStats', 12 * HOUR],
  ['debrisEvents', 12 * HOUR],
  ['neoNears', 3 * HOUR],
  ['news', 60 * MINUTE],
  // APOD/EPIC 每天才换一次，但上游故障恢复后要尽快可见
  ['apod', 60 * MINUTE],
  ['epic', 60 * MINUTE],
  ['nasaImages', 2 * HOUR]
]);

/**
 * 取软 TTL。等价于 data.js 的 `SOFT_TTL[name] || 15 * 60 * 1000`，
 * 只是把「缺失键」显式写成兜底分支 —— 当前 27 个键全覆盖，走不到兜底。
 */
export function getSoftTTL(name: DatasetName): number {
  const ttl: number | undefined = SOFT_TTL.get(name);
  if (ttl === undefined) {
    return DEFAULT_SOFT_TTL;
  }
  // 0 / 负数视为「没配置」，同样回退；避免误传 0 导致每帧都判过期
  return ttl > 0 ? ttl : DEFAULT_SOFT_TTL;
}

// ============ 配额淘汰 ============

/**
 * 淘汰顺序（先丢前面的）。体积大、低频访问的排在前面。
 *
 * 注意：**upcoming 不在名单里** —— 它是首页首屏，被清掉下次冷启动就要白等网络。
 * Repository.vacuum() 另外还有一道保护，双重保险。
 */
export const EVICT_ORDER: DatasetName[] = [
  'pads',
  'cores',
  'astronauts',
  'launchers',
  'satellites',
  'agencies',
  'gallery',
  'videos',
  'timelines',
  'news',
  'upcomingMore',
  'stats',
  'events',
  'previous',
  'onthisday',
  'spacestations',
  'expeditions',
  'dockings',
  'nasaImages'
];

// ============ 按小时缓存 ============

/**
 * 这些数据集在 URL 上带**小时级**时间戳，绕开 COS 的 max-age=3600。
 *
 * 原因：CDN 边缘缓存按 URL 命中，若时间戳精确到分钟，每人每秒都是新 URL，
 * 等于完全没有缓存；而这些数据集本身就是小时级 / 天级更新，按小时取整刚好。
 */
export const HOURLY_CACHE: Set<DatasetName> = new Set<DatasetName>([
  'satellites',
  'orbitStats',
  'debrisEvents',
  'neoNears',
  'apod',
  'epic',
  'nasaImages'
]);

/** GCAT 三数据集（独立版本号管理） */
const GCAT_NAMES: Set<DatasetName> = new Set<DatasetName>(['satellites', 'orbitStats', 'debrisEvents']);

// ============ 缓存 key ============

/**
 * L2 缓存 key，对应 data.js 的 cacheKey()：
 *   gallery            → sl_data_gallery_v14.1
 *   satellites / orbitStats / debrisEvents → sl_data_xxx_v14.2
 *   其余                → sl_data_xxx_v14
 *
 * 版本号嵌在 key 里，升版本即天然失效，不需要额外写清理逻辑。
 */
export function storageKey(name: DatasetName): string {
  let version: string = String(DATA_VERSION);
  if (name === 'gallery') {
    version = String(DATA_VERSION) + '.' + String(GALLERY_V);
  } else if (GCAT_NAMES.has(name)) {
    version = String(DATA_VERSION) + '.' + String(GCAT_V);
  }
  return 'sl_data_' + String(name) + '_v' + version;
}

// ============ 分片文件 ============

/**
 * 分片相对路径，对应 data.js 的 galleryChunk() / satelliteChunk() 里的 URL 段。
 *
 *   chunkFile('gallery', 3)    → 'gallery/3.json'
 *   chunkFile('satellites', 7) → 'satellites/7.json'
 *   chunkFile('gallery', 0)    → 'gallery.json'（第 0 片就躺在索引文件里）
 *
 * 参数类型说明：任务书建议写成 `'gallery' | 'satellites'`，但 Repository.ets:571
 * 已经以 `chunkFile(name as DatasetName, index)` 的形式调用，窄联合形参会直接
 * 编译不过。故放宽为 DatasetName，并在运行时收敛 —— 语义上仍然只服务这两个。
 */
export function chunkFile(name: DatasetName, index: number): string {
  const i: number = Math.floor(index);
  if (!(i > 0)) {
    // 与原项目一致：索引文件本身就是第 0 片
    return String(name) + '.json';
  }
  return String(name) + '/' + String(i) + '.json';
}

/**
 * 拼完整分片地址。时间戳按小时取整（与原项目一致），同一小时内所有人命中
 * 同一份 CDN 缓存。
 */
export function chunkUrl(name: DatasetName, index: number): string {
  const rel: string = chunkFile(name, index);
  const t: number = Math.floor(Date.now() / HOUR);
  return CDN_BASE + '/' + rel + '?t=' + String(t);
}
