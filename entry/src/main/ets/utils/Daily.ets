/**
 * utils/Daily.ets —— 「每日一图」的确定性抽取
 *
 * 对位原项目 ../../SpaceLaunch/utils/daily.js（全文 90 行），函数体逐行照抄，
 * 位运算常量、运算顺序、去重位置一处未改。
 *
 * 为什么不能「优化」：
 *   需求看着简单 —— 每天换一张、别重样 —— 但用 `list[天序号 % list.length]` 有两个硬伤：
 *     1. gallery 是新→旧倒序的，取模等于「一天往前翻一张」。相邻两天看到的是同一次
 *        发射的相邻照片（往往一个火球一个尾焰），完全没有「今天抽到一张」的感觉。
 *     2. CI 每轮往列表头部插入新图，所有下标整体后移。今天上午看到的是 A，
 *        数据同步完再进来变成 B —— 「每日一图」变成了「每小时一图」。
 *   换成「哈希打分取最大」之后：同一天恒定；相邻两天毫无关联；列表增删几乎不影响
 *   （只要抽中的那张还在，它还是最高分，新增图顶掉它的概率只有 1/(n+1)）。
 *
 * splitmix32 那一步同样不能省。直接 `hash32(seed + '|' + key)` 试过，问题很隐蔽：
 * 天序号是连续整数、只差 1，而 FNV-1a 对「尾部只改一位」的输入雪崩不够 ——
 * 365 天里只抽到 200 张中的 73 张，反复集中在那几张。先过一遍 splitmix 把种子搅乱，
 * 每个 bit 都会影响结果，分布才均匀。
 *
 * 有意差异（全部是语言层面的，不改语义）：
 *   · keyOf 从「接收一条记录」改成「接收 thumb / id / net 三个字段」——
 *     ArkTS 没有结构化鸭子类型，直接传联合类型会逼出无类型写法（ArkTS 禁止）；

 *     调用方写 keyOf(x.thumb, x.id, x.net) 与原实现 `x.thumb || x.id || x.net || ''` 等价。
 *   · 原实现的 `if (!x) continue`（跳过空元素）由 `GalleryItem[]` 的类型系统保证，故省略。
 *   · 去重从 `{}` 当 map 改成 `Set<string>`（ArkTS 禁止索引签名 `[key: string]: T`）。
 *     行为等价性说明：原实现 `if (seen[key]) continue; seen[key] = 1` 对空串同样生效
 *     （第一条空 key 通过、第二条起被跳过），Set 版本用 has/add 保持这一点。
 *     唯一的理论差异：JS 对象原型上的键（如 'toString'）在 `seen[key]` 下恒为真、
 *     会被误跳，Set 不会。本函数的 key 是 COS 图片地址 / LL2 id / ISO 时间，
 *     不可能撞上 `Object.prototype` 的成员名，故该差异无实际影响。
 *   · splitmix32 里 `let a` 改成 `const a`（原实现在函数内从未重新赋值），语义不变。
 *
 * 纯函数：无 IO、无网络、无存储、无日志、不读 Date.now()（时间由调用方传入）。
 */

/** 北京时区偏移（东八区，无夏令时，常量即可） */
const BJ_OFFSET: number = 8 * 60 * 60 * 1000;

/**
 * 图库条目。
 *
 * model/ 目录目前只有 Apod / Astronaut / Common / Launch / News，**没有 Gallery**，
 * 所以这里按实际合并逻辑（SpaceLaunch/scripts/images.js 第 250 行附近）定义一个最小接口：
 * { id, name, net, thumb, credit, cname }。
 * 将来 model/Gallery.ets 建好后，应改成 `import { GalleryItem } from '../model/Gallery'`
 * 并删掉本定义，避免两份类型漂移。
 */
export interface GalleryItem {
  id: string;
  name: string;
  net: string;
  thumb: string;
  credit: string;
  cname: string;
}

/**
 * FNV-1a 32 位。选它是因为短、无依赖、对长字符串（URL）足够均匀，
 * 不需要密码学强度。
 */
export function hash32(str: string): number {
  let h: number = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    // Math.imul 保证 32 位乘法不溢出成浮点
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/**
 * splitmix32：把种子彻底打散。
 * 每个常量都不能动 —— 0x9e3779b9 是黄金分割常数（2^32 × 0.618…），
 * 0x21f0aaad / 0x735a2d97 是该算法固定的两个混合乘子。
 */
export function splitmix32(seed: number): number {
  const a: number = (seed + 0x9e3779b9) | 0;
  let t: number = a ^ (a >>> 16);
  t = Math.imul(t, 0x21f0aaad);
  t = t ^ (t >>> 15);
  t = Math.imul(t, 0x735a2d97);
  return (t ^ (t >>> 15)) >>> 0;
}

/**
 * 图片的稳定标识：优先缩略图地址（CI 镜像后就是 COS 上的 hash 名，
 * 天然唯一且不会变），退回发射 id，再退回发射时间。
 * 对应原实现 `String(x.thumb || x.id || x.net || '')`。
 */
export function keyOf(thumb: string, id: string, net: string): string {
  if (thumb.length > 0) {
    return thumb;
  }
  if (id.length > 0) {
    return id;
  }
  if (net.length > 0) {
    return net;
  }
  return '';
}

/**
 * 北京时区的天序号（自 1970-01-01 起的天数），当作「每日一图」的种子。
 *
 * 为什么不按本地时区：这个值决定「今天抽哪张」，必须全设备一致。
 * 用 UTC 会在北京时间早上 8 点换图，用本地时区则人在国外会换个时区换张图；
 * 统一钉死东八区，才有「每天零点（北京）换一张」的确定语义。
 */
export function daySeed(nowMs: number): number {
  return Math.floor((nowMs + BJ_OFFSET) / 86400000);
}

/**
 * 每日一图：返回 list 里得分最高的那一条，列表为空返回 null。
 *
 * @param list 图库列表（gallery.json 的 list）
 * @param seed 当天种子，用 daySeed(Date.now())
 */
export function pickDaily(list: GalleryItem[], seed: number): GalleryItem | null {
  if (list.length === 0) {
    return null;
  }

  const state: number = splitmix32(seed);
  let best: GalleryItem | null = null;
  let bestScore: number = -1;
  // LL2 大量复用配图：200 条发射记录实测只有 73 张不同的图。
  // 不去重的话「不同发射撞同一张照片」会被抽中两次，用户看到的就是连着两天一样
  const seen: Set<string> = new Set<string>();

  for (let i = 0; i < list.length; i++) {
    const x: GalleryItem = list[i];
    const key: string = keyOf(x.thumb, x.id, x.net);
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);

    const score: number = splitmix32(state ^ hash32(key));
    if (score > bestScore) {
      bestScore = score;
      best = x;
    }
  }
  return best;
}
