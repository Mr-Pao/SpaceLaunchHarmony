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
 *
 * 2026-11-03 补记：本文件尾部新增 collectMedia()（型号媒体库摊平 + 去重），
 * 对位小程序 utils/media.js 第 72-175 行。原计划「等第二阶段媒体页再迁」已完成，
 * 消费方是 view/MediaView.ets。它同样是纯函数，上面这条约定继续成立。
 */

import { parseTime, strOf } from './Format';

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

// ==================== 型号媒体库摊平（collectMedia） ====================
//
// 对位小程序 utils/media.js 第 72-175 行。消费方是 view/MediaView.ets。
//
// 为什么不直接用 model/Common.ets 的 LaunchSummary 当入参：
//   1. 该接口声明 `vid?: LaunchVideoRef[]`，而 LaunchVideoRef.tid 写的是 string，
//      线上 videos.json 实测是 number（1 官方 / 3 转播 / 4 重播）。拿它当入参会
//      逼着每个调用点做类型断言，ArkTS 又对跨类型 as 很挑。
//   2. 模型接口字段多且部分必填（name / net），而这里真正读的只有 10 个键，
//      上游少一个字段不该让整页崩。
//   3. launchers 数据集里的构型记录根本不是 LaunchSummary（它有 image 但
//      没有 net / rocket），硬塞进同一个类型反而更绕。
//   所以这里定义一组**只读必要字段、除 url 外全可选**的入参接口，页面侧做一次
//   显式转换。转换是十行字面量，比在算法里到处兜空好读。

/** 构型记录的只读投影（launchers.json 单条的必要子集） */
export interface MdConfigRec {
  /** LL2 数字 id；与发射记录里的 rocket.configuration.id 对齐 */
  id?: number;
  name?: string;
  full_name?: string;
  variant?: string;
  families?: string[];
  image?: string;
  imageThumb?: string;
  imageCredit?: string;
}

/** 发射工位记录的只读投影（只取图片相关的 5 个键） */
export interface MdPadRec {
  name?: string;
  image?: string;
  imageThumb?: string;
  imageCredit?: string;
  imageName?: string;
}

/**
 * 视频源的只读投影。
 *
 * tid 写成 `string | number` 是**故意的**：模型层两种声明都存在
 * （Common.ets 是 string，Video.ets 是 number），这里都收，判定时统一转。
 * 其它字段与上游一一对应，全部可选 —— 缺字段就按空值走，不抛。
 */
export interface MdVideoRef {
  url?: string;
  title?: string;
  publisher?: string;
  kind?: string;
  tid?: string | number;
  cover?: string;
  mins?: number;
  cosUrl?: string;
  sourceType?: string;
}

/** 发射记录的只读投影（图片 + 视频两类素材的来源） */
export interface MdLaunchRec {
  id?: string;
  name?: string;
  /** 发射时刻，倒序排序与卡片 meta 都用它 */
  net?: string;
  image?: string;
  imageThumb?: string;
  imageCredit?: string;
  imageName?: string;
  /** 信息图地址（竖长图，独立成一张） */
  infographic?: string;
  pad?: MdPadRec;
  vid?: MdVideoRef[];
}

/** 图片墙上的一张图 */
export interface MdShot {
  /** 去重键；空串的条目在摊平时就被丢掉 */
  url: string;
  /** 列表用（480px）。弱网先出这张，别一上来就拉 2000px */
  thumb: string;
  /**
   * 点开用（2000px）。**信息图没有 full 预设**（COS 只给缩略与 1080 两档），
   * 所以这一档恒为空串，调用方必须回退 thumb，否则点开就是一张裂图。
   */
  full: string;
  /** 署名，空串表示上游没给 */
  credit: string;
  /** 图注：发射名 / 工位名 / 构型名 */
  caption: string;
  /** config | launch | pad | infographic —— 决定图片墙上的高度档 */
  kind: string;
  /** 发射时刻，config 档恒空串 */
  net: string;
}

/** 视频库里的一张卡片 */
export interface MdVideo {
  url: string;
  title: string;
  publisher: string;
  kind: string;
  /** tid === 1（LL2 的官方源）或 kind 为官方直播 */
  official: boolean;
  /** 封面；上游可能给的是未镜像的外链，Image 能直接吃 */
  cover: string;
  /** 与 cover 同值，留着是为了调用点语义清晰（列表用 thumb） */
  thumb: string;
  net: string;
  mins: number;
  cosUrl: string;
  /** cosUrl 非空 = 能内联播放；否则只能复制链接 */
  playable: boolean;
  sourceType: string;
}

/** collectMedia 的返回值 */
export interface MdMedia {
  images: MdShot[];
  videos: MdVideo[];
  /** 摊平后超过上限时为真，页面尾部提示「仅显示最近 N 张」 */
  truncated: boolean;
}

/**
 * 图片上限 60、视频上限 40。
 *
 * 视频为什么是 40 而不是 60：小程序 utils/media.js 第 16 行写的就是 40
 * （MAX_IMAGES 60 / MAX_VIDEOS 40 是两组不同的数）。任务书里写成 60 是笔误，
 * 以源码与线上体感为准 —— 40 张 110vp 封面已经要滑四屏。
 * 图片 60 张两列 = 30 行，也够「型号媒体库」这个量级。
 */
const MD_MAX_IMAGES: number = 60;
const MD_MAX_VIDEOS: number = 40;

/**
 * 一条记录的时间戳（毫秒）。
 * net 缺失或非法时按 0 处理 —— 与小程序 timeOf 的 `NaN → 0` 一致，
 * 这样没有 net 的记录会稳定沉到列表底部，而不是随机插在中间。
 */
function mdTimeOf(rec: MdLaunchRec): number {
  const net: string = strOf(rec.net);
  return net.length > 0 ? parseTime(net) : 0;
}

/** 数值字段兜底：上游一律可能缺席 */
function mdNumOf(raw: number | undefined): number {
  return raw === undefined ? 0 : raw;
}

/**
 * tid 是不是「官方源」。
 *
 * 不写成 `raw === 1` 有两个原因：模型层一处声明 string、一处声明 number；
 * 而 JSON.parse 的 as 只是编译期断言，运行时数字就是数字。
 * 两种写法都认，判定才稳。不引入 Number() 是为了绕开类型收窄的麻烦。
 */
function mdIsOfficialTid(raw: string | number | undefined): boolean {
  if (raw === undefined || raw === null) {
    return false;
  }
  return raw === 1 || raw === '1';
}

/**
 * 按 url 去重，保留首次出现，空 url 直接跳过。
 *
 * 为什么是「首次出现」而不是「信息量大的优先」：调用方按
 * config → launch → pad → infographic 的顺序拼，先出现的就是优先级高的
 * （构型定妆照比发射现场图更代表这个型号）。顺序即优先级，不需要额外权重。
 */
function mdUniqShots(list: MdShot[]): MdShot[] {
  const seen: Set<string> = new Set<string>();
  const out: MdShot[] = [];
  for (let i = 0; i < list.length; i++) {
    const it: MdShot = list[i];
    if (it.url.length === 0) {
      continue;
    }
    if (seen.has(it.url)) {
      continue;
    }
    seen.add(it.url);
    out.push(it);
  }
  return out;
}

/** 视频去重，规则同上（同一场直播在 previous / upcoming 里各出现一次很常见） */
function mdUniqVideos(list: MdVideo[]): MdVideo[] {
  const seen: Set<string> = new Set<string>();
  const out: MdVideo[] = [];
  for (let i = 0; i < list.length; i++) {
    const it: MdVideo = list[i];
    if (it.url.length === 0) {
      continue;
    }
    if (seen.has(it.url)) {
      continue;
    }
    seen.add(it.url);
    out.push(it);
  }
  return out;
}

/**
 * 把「同系列构型 + 它们的历次发射」摊平成图片墙与视频墙。
 *
 * @param configs 同系列的构型记录（含当前型号自己），每张取一张代表图
 * @param records 属于这些构型的发射记录，**顺序无所谓**，内部按 net 倒序重排
 *
 * 倒序的理由：型号媒体库是「最近长什么样」的展示位，越新越靠前；
 * 而 upcoming 的 net 在未来、previous 在过去，不重排就会是
 * 「未来的全在最前、历史的乱序」这种在小程序上被专门修过的观感。
 */
export function collectMedia(configs: MdConfigRec[], records: MdLaunchRec[]): MdMedia {
  // ── 1. 构型定妆照 ──
  // 线上 launchers.json 只有 image（480px 镜像）没有 imageThumb，所以
  // thumb 会退化成同一张；full 由 image 推出 _2000 版本，能否命中取决于 CI
  // 当时有没有生成原图，命中不了就是 404 —— 页面侧点开时的回退逻辑兜住。
  const configImages: MdShot[] = [];
  for (let i = 0; i < configs.length; i++) {
    const c: MdConfigRec = configs[i];
    const image: string = strOf(c.image);
    const imageThumb: string = strOf(c.imageThumb);
    const url: string = image.length > 0 ? image : imageThumb;
    const thumb: string = imageThumb.length > 0 ? imageThumb : image;
    const shot: MdShot = {
      url: url,
      thumb: thumb,
      full: fullImageOf(imageThumb.length > 0 ? imageThumb : image),
      credit: strOf(c.imageCredit),
      caption: strOf(c.name),
      kind: 'config',
      net: '',
    };
    configImages.push(shot);
  }

  // ── 2. 发射记录按时刻倒序（不改入参：records 可能是 repo 的缓存数组） ──
  const sorted: MdLaunchRec[] = records.slice();
  sorted.sort((a: MdLaunchRec, b: MdLaunchRec) => mdTimeOf(b) - mdTimeOf(a));

  // ── 3. 发射现场图 / 工位图 / 信息图 ──
  const launchImages: MdShot[] = [];
  const padImages: MdShot[] = [];
  const infographics: MdShot[] = [];
  for (let i = 0; i < sorted.length; i++) {
    const r: MdLaunchRec = sorted[i];
    const net: string = strOf(r.net);
    const rName: string = strOf(r.name);
    const rImage: string = strOf(r.image);
    const rThumb: string = strOf(r.imageThumb);

    const lUrl: string = rImage.length > 0 ? rImage : rThumb;
    const lThumb: string = rThumb.length > 0 ? rThumb : rImage;
    const lName: string = strOf(r.imageName);
    const launchShot: MdShot = {
      url: lUrl,
      thumb: lThumb,
      full: fullImageOf(rThumb.length > 0 ? rThumb : rImage),
      credit: strOf(r.imageCredit),
      caption: lName.length > 0 ? lName : rName,
      kind: 'launch',
      net: net,
    };
    launchImages.push(launchShot);

    const p: MdPadRec | undefined = r.pad;
    if (p !== undefined) {
      const pImage: string = strOf(p.image);
      const pThumb: string = strOf(p.imageThumb);
      const pName: string = strOf(p.imageName);
      const pPadName: string = strOf(p.name);
      const padShot: MdShot = {
        url: pImage.length > 0 ? pImage : pThumb,
        thumb: pThumb.length > 0 ? pThumb : pImage,
        full: fullImageOf(pThumb.length > 0 ? pThumb : pImage),
        credit: strOf(p.imageCredit),
        caption: pName.length > 0 ? pName : pPadName,
        kind: 'pad',
        net: net,
      };
      padImages.push(padShot);
    }

    const info: string = strOf(r.infographic);
    if (info.length > 0) {
      // 信息图是**竖长的一张**（比例约 1:1.5），没有 full 版本：
      // 上游给什么就用什么，full 留空让页面回退 thumb。
      const infoShot: MdShot = {
        url: info,
        thumb: info,
        full: '',
        credit: '',
        caption: rName,
        kind: 'infographic',
        net: net,
      };
      infographics.push(infoShot);
    }
  }

  // 顺序即优先级，见 mdUniqShots 的注释
  const merged: MdShot[] = [];
  const groups: MdShot[][] = [configImages, launchImages, padImages, infographics];
  for (let i = 0; i < groups.length; i++) {
    const g: MdShot[] = groups[i];
    for (let j = 0; j < g.length; j++) {
      merged.push(g[j]);
    }
  }
  const all: MdShot[] = mdUniqShots(merged);
  const images: MdShot[] = all.slice(0, MD_MAX_IMAGES);
  const truncated: boolean = all.length > MD_MAX_IMAGES;

  // ── 4. 视频 ──
  // 遍历 sorted（已倒序），所以「最近一场发射的视频」自然排在最前。
  // 注意这里**不再按 tid 排序**：小程序 media 页就是原序，排序是
  // video-gallery 页（另一个页面）的诉求，两处混用会让本页顺序不可预期。
  const videoList: MdVideo[] = [];
  for (let i = 0; i < sorted.length; i++) {
    const r: MdLaunchRec = sorted[i];
    const vids: MdVideoRef[] | undefined = r.vid;
    if (vids === undefined || vids.length === 0) {
      continue;
    }
    const rNet: string = strOf(r.net);
    const rName: string = strOf(r.name);
    const rThumb: string = strOf(r.imageThumb);
    const rImage: string = strOf(r.image);
    for (let j = 0; j < vids.length; j++) {
      const v: MdVideoRef = vids[j];
      const url: string = strOf(v.url);
      if (url.length === 0) {
        continue;
      }
      // 封面三级回退：视频自带封面 → 发射缩略图 → 发射原图。
      // 线上 vids[].cover 基本都是镜像好的 480px，走第一档。
      let cover: string = strOf(v.cover);
      if (cover.length === 0) {
        cover = rThumb.length > 0 ? rThumb : rImage;
      }
      const vTitle: string = strOf(v.title);
      const kind: string = strOf(v.kind);
      const cosUrl: string = strOf(v.cosUrl);
      const one: MdVideo = {
        url: url,
        title: vTitle.length > 0 ? vTitle : rName,
        publisher: strOf(v.publisher),
        kind: kind,
        official: mdIsOfficialTid(v.tid) || kind === 'Official Webcast',
        cover: cover,
        thumb: cover,
        net: rNet,
        mins: mdNumOf(v.mins),
        cosUrl: cosUrl,
        // playable 与 cosUrl 必须同源判断：分成两处写，将来改一处就会出现
        // 「徽标说能播、点下去却复制链接」的错位
        playable: cosUrl.length > 0,
        sourceType: strOf(v.sourceType),
      };
      videoList.push(one);
    }
  }
  const videos: MdVideo[] = mdUniqVideos(videoList).slice(0, MD_MAX_VIDEOS);

  const out: MdMedia = {
    images: images,
    videos: videos,
    truncated: truncated,
  };
  return out;
}
