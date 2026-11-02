/**
 * utils/Media.ets —— COS 图片地址互推（缩略图 ↔ 原图）
 *
 * 对位原项目 ../../SpaceLaunch/utils/media.js 第 31-49 行（fullImageOf / thumbOf）。
 * 原文件另外还有 collectMedia()（火箭媒体库摊平 + 去重），那是页面级逻辑，
 * 依赖 LL2 的 launcher / launch / pad / infographic 结构，不属于本文件的纯地址推导范围，
 * 等第二阶段媒体页再迁。
 *
 * 为什么不能「优化」成别的写法：
 *   COS key 规则（SpaceLaunch/scripts/lib/image.js 的 keyOf）是：
 *     thumb = space-img/{hash}.{ext}          —— hash 是原始 URL 的 md5 前 16 位
 *     full  = space-img/{hash}_2000.{ext}     —— 同一原始 URL 在 full 预设下的产物
 *   两者共享同一个 hash，所以纯字符串互推即可，不需要任何 JSON 里多带一个字段。
 *   规则是「16 位小写十六进制 + 3~4 位扩展名 + 允许尾部 ?query」，写宽了会把
 *   信息图（_1080）、工位地图（_750）也误判成缩略图 —— 它们没有 full 预设，
 *   换成 _2000 就是 404，previewImage 会直接显示失败。
 *   只匹配「无宽度后缀」的缩略图，不匹配时返回空串，调用方回退用缩略图自己。
 *
 * 有意差异（语言层面，不改语义）：
 *   · 原实现的 `typeof url !== 'string'` 兜底由 ArkTS 参数类型 string 保证，故省略；
 *     空串判断改用 `url.length === 0`（任务约定）。
 *   · 正则用 `new RegExp(字符串)` 构造而不是字面量：与原项目 utils/format.js 迁到
 *     Format.ets 时同一取舍（见 Format.ets 的 dayOf 注释），行为完全一致。
 *   · 捕获组只用 replace 的 $1/$2，不取 m[1]/m[2] 下标（ArkTS 对 RegExpMatchArray
 *     的下标访问更挑剔；match 只用来做「是否匹配」的判定）。
 *
 * 纯函数：无 IO、无网络、无存储、无日志。
 */

/**
 * 缩略图 → 原图：space-img/<16 位 hash>.<ext> → space-img/<16 位 hash>_2000.<ext>
 * 带 query（COS 预签名 / 缓存参数）时保留 query；不匹配返回空串。
 */
const FULL_RE: RegExp = new RegExp('space-img/([0-9a-f]{16})\\.(\\w{3,4})(?:\\?.*)?$');

export function fullImageOf(url: string): string {
  if (url.length === 0) {
    return '';
  }
  // match 只用来判断「是不是可推导的缩略图」，替换仍走 replace，
  // 与原实现的两步结构一致（原实现也是先 match 判空、再 replace）
  const m: RegExpMatchArray | null = url.match(FULL_RE);
  if (m === null) {
    return '';
  }
  return url.replace(FULL_RE, 'space-img/$1_2000.$2');
}

/**
 * fullImageOf 的反向：把镜像的原图地址换回 480px 缩略版。
 *
 * 用途：首图区一屏要塞好几张，直接拿 2000px 原图当缩略图，每张几百 KB，
 * 弱网下要等很久才出图（首屏就是一片黑）。缩略版在手机上完全够看，点开再看原图。
 * 非镜像地址原样返回，不去猜 CDN 的缩略图规则。
 *
 * 注意这里**没有 $ 锚定**：原实现就没有 —— _2000 可能出现在地址中间
 * （例如后接 ?query），锚定尾部会漏掉这类地址。
 */
const THUMB_RE: RegExp = new RegExp('(space-img/[0-9a-f]{16})_2000\\.(\\w{3,4})');

export function thumbOf(url: string): string {
  if (url.length === 0) {
    return url;
  }
  return url.replace(THUMB_RE, '$1.$2');
}
