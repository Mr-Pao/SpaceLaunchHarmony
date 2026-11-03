/**
 * view/MineView.ets —— 「我的」tab（按小程序 pages/mine/mine.vue 逐段对齐）
 *
 * 结构（与小程序同序，注释里标出对应的小程序选择器，方便复核）：
 *   StarField 星空底（小程序 <star-field />）
 *   → hero：辉光 + 76vp 圆形真图 logo + 双色字标 + 标语 + 三格统计（收藏 / 提醒 / 当前版本）
 *   → 我的收藏（.rows 列表 + 右上「全部 ›」）
 *   → 收藏的火箭（.rows 列表）
 *   → 我的提醒（🔔 行 + 名称 + meta + ›，点击进发射详情）
 *   → 三块全空时的青虚线引导卡（.tips）
 *   → 探索（4 格，48.6% 百分宽）
 *   → 数据与设置（鸿蒙增量，视觉按「关于」行对齐）
 *   → 关于（4 行 + CC-BY 长注）
 *   → 页脚一句
 *
 * 为什么整页没有「我的」标题：小程序 mine.vue:5-7 明确写了理由 ——
 * 这一页只有一个 tab，标题只是重复；内容直接从状态栏下开始、整宽铺开，
 * 才能和星空融成一片（沉浸感），而不是「一张浮起来的卡」。照抄。
 *
 * 与小程序的差异全部是「鸿蒙侧能力边界」造成的，逐条列在这里：
 *   1. 统计第三格用 currentVersion()（constants/Changelog.ets 末条版本），
 *      小程序用 utils/changelog.js 的 current；两边语义完全一致。
 *   2. 「我的收藏」右上多一个「全部 ›」。小程序没有这一行：它的清单就 5 条封顶、
 *      也不存在收藏专页；鸿蒙有独立的 FavoritesView（还能长按删除），
 *      不给门就等于把删除能力藏起来。这是**有意的功能增量**。
 *   3. 「我的提醒」照小程序的**完整清单**渲染（🔔 行 + 名称 + meta + ›，点击进发射详情），
 *      key 仍是 `reminded_launches`。鸿蒙侧目前**没有写入方**（LaunchDetailView 顶栏只有
 *      ☆ 收藏），所以这份清单现在必然为空、区块自然不出现 —— 这是数据为空，不是没做。
 *      刻意不塞假数据：凭空冒出几条「提醒」比空白更糟。
 *   4. 没有「联系作者」。小程序用的是微信客服通道（<button open-type="contact">），
 *      鸿蒙没有对应能力；伪造一个「发消息」按钮、或凭空编一个邮箱地址，都比省略更糟
 *      （编出来的邮箱发出去没人收，用户会以为作者不回复）。这一行**直接省略**。
 *   5. 多一组「数据与设置」（数据结构说明 / 数据更新 / 清理缓存 / 关于）。
 *      小程序靠微信清缓存、靠「关于」弹窗回答一切；鸿蒙是本地文件缓存，用户必须能
 *      自己清、也必须能看见最后同步时间，否则弱网问题无从排查。视觉上刻意与
 *      小程序「关于」分组用同一套行样式（14vp 标签 + 13vp 值 + 1vp 分割线），
 *      让这组增量不像外来物。
 *
 * 关于 CC-BY 署名：小程序把它放在「关于」块下方的 .about-note 长注里（mine.vue:180），
 * 这里**原样照抄那段文案**，义务没有丢；「数据结构说明」「关于」两个弹窗是第二处落点。
 * 页脚只是小程序那一句「SpaceLaunch · 为航天爱好者而做」，不再重复署名。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { repo, LoadOptions, DataSet, CacheStats } from '../data/Repository';
import { fileStore } from '../data/FileStore';
import { formatGeneratedAt, formatShort, relativeTime, statusOf, strOf } from '../utils/Format';
import { LaunchSummary, LaunchMission } from '../model/Common';
import { UpcomingPayload, PreviousPayload } from '../model/Launch';
import { StarField } from '../components/StarField';
import {
  Nav,
  ROUTE_STATS,
  ROUTE_ASSETS,
  ROUTE_NEO,
  ROUTE_EVENTS,
  ROUTE_FAVORITES,
  ROUTE_VERSION
} from '../routes/Nav';
import { LaunchNavParam, RocketNavParam } from '../routes/NavParam';
import { favInit, favList, remindedList, FavItem, FAV_VERSION_KEY } from '../data/Favorites';
import { rocketFavInit, rocketFavList, MvRocketFav, RKF_VERSION_KEY } from '../data/RocketFavorites';
import { currentVersion } from '../constants/Changelog';

const DOMAIN: number = 0x0000;
const TAG: string = 'MineView';

// ============ 配色（工程约定 + 小程序实测值） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const ACCENT: string = '#38BDF8';
/** 字标里 Launch 的颜色，比全站强调色更偏青（小程序 #22d3ee） */
const BRAND_CYAN: string = '#22D3EE';
/** 字标青光：rgba(34,211,238,0.42) */
const BRAND_CYAN_GLOW: string = '#6B22D3EE';
/** 卡片描边 rgba(255,255,255,0.05) */
const CARD_BORDER: string = '#0DFFFFFF';
/** 卡片内分割线 rgba(255,255,255,0.045) */
const ROW_DIVIDER: string = '#0BFFFFFF';
/** 行标题 #e2e8f0 */
const ROW_TITLE: string = '#E2E8F0';
/** 行次要信息 / 标签 #6b7891 */
const TEXT_LABEL: string = '#6B7891';
/** 引导卡正文 #7d8ba0（比三级文字亮一档） */
const TEXT_HINT: string = '#7D8BA0';
/** 探索格副标题 #5f6b80 */
const TEXT_TILE_DESC: string = '#5F6B80';
/** 行尾 chevron #3d4a5c */
const ARROW: string = '#3D4A5C';
/** 缩略图占位底 #0f1520 */
const IMG_BG: string = '#0F1520';
/** 引导卡底 rgba(56,189,248,0.05) */
const TIPS_BG: string = '#0D38BDF8';
/** 引导卡虚线 rgba(56,189,248,0.2) */
const TIPS_BORDER: string = '#3338BDF8';
/** 页脚 #35404f */
const FOOTER_TEXT: string = '#35404F';
/** CC-BY 长注 #4d596b */
const NOTE_TEXT: string = '#4D596B';
/** 辉光三档：0.26 / 0.07 / 0 */
const GLOW_A: string = '#4238BDF8';
const GLOW_B: string = '#1238BDF8';
const GLOW_C: string = '#0038BDF8';

// ============ 尺寸 ============

/** 页面左右内边距（工程约定 16） */
const PAGE_PAD: number = 16;
/** logo 直径：小程序 152rpx = 76vp */
const LOGO_SIZE: number = 76;
/** hero 辉光高度：小程序 620rpx = 310vp（宽度随屏幕，760rpx 已超过屏宽） */
const HERO_GLOW_H: number = 310;
/** 清单行缩略图：小程序 96rpx = 48vp */
const ROW_IMG: number = 48;
/** 每份清单最多露几条。小程序 SHOW_MAX = 5，理由同款：收藏几十条时这页会变成列表页 */
const SHOW_MAX: number = 5;
/** 探索格高度：ArkUI 的 Flex 换行不做 css 那种同行拉伸，给固定高保证 2×2 对齐 */
const TILE_H: number = 108;
/** 底部内边距 92vp：让开悬浮胶囊（胶囊 58 + 底留 20 + 顶部渐变 14） */
const BOTTOM_PAD: number = 92;
/** 构建日期，手写；改版本时顺手改这里 */
const APP_BUILD: string = '2026-11-02';
// 提醒清单的键名不在这里定义：`reminded_launches` 的读法收口到
// data/Favorites.ets 的 remindedList()。同一份存储有两个读取入口，
// 迟早会分叉出两种解析口径（一个去空、一个不去空），所以本页只反查 id。

/** 字节数 → 人读体积（utils/Format.ets 是纯时间/文本层，没有体积函数） */
function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return String(Math.ceil(bytes)) + ' B';
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return kb.toFixed(1) + ' KB';
  }
  return (kb / 1024).toFixed(1) + ' MB';
}

/**
 * 探索格的一格。
 * ArkTS 禁无类型对象字面量，列表项必须可 new。
 * 字段名避开 size / width / height / content 等内置属性名（同名会被内置成员遮蔽）。
 */
class MvTile {
  icon: string = '';
  title: string = '';
  desc: string = '';
  /** 跳转分发用的稳定标识，不参与渲染 */
  key: string = '';

  constructor(icon: string, title: string, desc: string, key: string) {
    this.icon = icon;
    this.title = title;
    this.desc = desc;
    this.key = key;
  }
}

/** 「数据与设置」的一行 */
class MvSettingRow {
  title: string = '';
  key: string = '';

  constructor(title: string, key: string) {
    this.title = title;
    this.key = key;
  }
}

@Component
export struct MineView {
  // ============ 状态 ============

  /** 已收藏的发射（最多 SHOW_MAX 条，供列表渲染） */
  @State favItems: FavItem[] = [];
  /** 收藏总数（清单可能被截断，头部「N 条」必须用真实总数） */
  @State favTotal: number = 0;
  /** 已收藏的火箭型号（最多 SHOW_MAX 条） */
  @State rocketItems: MvRocketFav[] = [];
  @State rocketTotal: number = 0;
  /** 提醒条数（清单可能被截断，头部「N 条」用真实总数） */
  @State remindTotal: number = 0;
  /**
   * 我的提醒清单（最多 SHOW_MAX 条）。
   *
   * 用 LaunchSummary 而不是自造一个精简类：小程序的 `rems` 就是**回查出来的发射对象**
   * （mine.vue 的 loadFavs 拿 upcoming + previous 建 Map，再用 id 反查），
   * 行里的格式短时间 / 相对时间 / 状态都从它身上取。照抄同一套口径，
   * 收藏行与提醒行的 meta 才是同一个函数算出来的。
   */
  @State remindItems: LaunchSummary[] = [];
  /** 最近一次数据同步的人读时间 */
  @State lastSyncText: string = '尚未同步';
  @State refreshing: boolean = false;
  /** 磁盘缓存项数 / 字节 / 目录，供「数据与设置」两行显示 */
  @State cachedCount: number = 0;
  @State cacheBytes: number = 0;
  @State cacheDir: string = '';

  /**
   * 订阅收藏版本号（data/Favorites.ets 每改一次 +1）。
   *
   * **这是「从收藏页返回后数字不更新」的唯一解**：本页在 TabContent 里保活，
   * aboutToAppear 一辈子只跑一次；onPageShow 在 TabContent 里不触发；
   * 收藏页压的是另一个 NavPathStack 的详情层，pop 回来不会重建本组件。
   * 只有全局版本号能穿透这几种情况。
   */
  @StorageProp(FAV_VERSION_KEY) @Watch('onFavChanged') favVersion: number = 0;
  /**
   * 火箭收藏用独立的版本键（data/RocketFavorites.ets）。
   * 不复用收藏的键：两份清单在不同页面被改，共用一个键会让无关的刷新互相触发。
   */
  @StorageProp(RKF_VERSION_KEY) @Watch('onRkFavChanged') rkFavVersion: number = 0;

  /**
   * 提醒 id → 发射对象的解析缓存。
   *
   * 不在页面里自己开 preferences：`reminded_launches` 的读法收口在 data/Favorites.ets
   * 的 remindedList() 里，这里只负责「id 反查对象」。两条清单在不同页面被改，
   * 多一个读取入口就多一处会分叉的口径。
   */
  private remindIds: string[] = [];
  /**
   * id → 发射对象 的现查索引（upcoming + previous 两张表合成）。
   *
   * 收藏行要显示状态、提醒行要显示整条发射信息，两边都需要「按 id 拿对象」。
   * 一次 reloadLists 建一次索引，比每行各 peek 一次省事，也保证两处的
   * 取数口径完全一致。
   */
  private launchIndex: Map<string, LaunchSummary> = new Map<string, LaunchSummary>();

  /**
   * 探索格。**与小程序 entries 完全一致的四格**。
   *
   * 曾加过第 5 格「空间站」，2026-11-03 按「逐页对齐小程序」的要求撤掉：
   * 探索区是小程序最讲究的一屏（2×2 布局、每格 48.6% 宽），多一格会破成 2/2/1，
   * 用户一眼就看出不是同一版。空间站入口改挂到「数据与设置」下 —— 那一组本来
   * 就是鸿蒙侧的增量区，加一行不影响版式。
   */
  private tiles: MvTile[] = [
    new MvTile('📊', '数据统计', '历年发射量', 'stats'),
    new MvTile('🛰️', '太空资产', '在轨统计 · 卫星百科 · 解体再入', 'assets'),
    new MvTile('☄️', '近地天体', '未来一周掠地日程', 'neo'),
    new MvTile('📅', '近期活动', 'EVA · 轨道插入 · 飞掠', 'events')
  ];

  /**
   * 「数据与设置」。key 是 onSetting 的稳定标识。
   *
   * 「空间站」放在这里：小程序那边空间站列表页没有任何入口（只有分享 path），
   * 鸿蒙既然做完了列表与详情就该有个门；而这一组本来就是增量区，多一行不破版式。
   */
  private settings: MvSettingRow[] = [
    new MvSettingRow('空间站', 'stations'),
    new MvSettingRow('数据结构说明', 'data'),
    new MvSettingRow('数据更新', 'refresh'),
    new MvSettingRow('清理缓存', 'clear'),
    new MvSettingRow('关于', 'about')
  ];

  // ============ 生命周期 ============

  aboutToAppear(): void {
    // preferences 需要 Context，而这里是首个拿得到 this.getUIContext() 的时机
    // （模块级没有 Context 可用）。收藏与火箭收藏各自初始化，互不依赖。
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      favInit(ctx);
      rocketFavInit(ctx);
    }
    this.reloadLists();
    this.refreshCacheInfo();
    this.loadLastSync(false);
  }

  /**
   * 收藏版本号变了就地重读。
   *
   * 形参 `propName` 必须留着：@Watch 回调签名是 `(propName: string) => void`。
   */
  onFavChanged(propName: string): void {
    this.reloadLists();
  }

  onRkFavChanged(propName: string): void {
    this.reloadLists();
  }

  // ============ 数据 ============

  /**
   * 重读三份清单。
   *
   * 只取前 SHOW_MAX 条渲染、但总数用 length —— 小程序也是这个口径
   * （计数按记录条数算，列表只露 5 条）。拉不到详情的收藏条目不占位这件事，
   * 鸿蒙侧不存在：Favorites.ets 存的就是标题/时间/地点快照，不依赖数据源。
   */
  private reloadLists(): void {
    const favs: FavItem[] = favList();
    this.favTotal = favs.length;
    this.favItems = favs.length > SHOW_MAX ? favs.slice(0, SHOW_MAX) : favs;

    const rockets: MvRocketFav[] = rocketFavList();
    this.rocketTotal = rockets.length;
    this.rocketItems = rockets.length > SHOW_MAX ? rockets.slice(0, SHOW_MAX) : rockets;

    this.readRemindList();
  }

  /**
   * 重读提醒清单。
   *
   * 小程序把提醒记在 `reminded_launches`（一个 id 数组），渲染时拿 id 回查发射对象。
   * 鸿蒙侧沿用同名 key，**但目前没有任何写入方**（发射详情只做了收藏星标、没有
   * 「提醒」按钮），所以现在必然读到空 —— 这是照实呈现，不塞假数据：
   * 将来详情页接上提醒开关、写入同名 key，这一块会自己活过来。
   *
   * 查不到对象的 id **不占位**，与小程序 pick() 同口径（否则会出现一行只有 id 的空壳）。
   */
  private readRemindList(): void {
    this.remindIds = remindedList();
    this.remindTotal = this.remindIds.length;
    this.buildLaunchIndex();

    const picked: LaunchSummary[] = [];
    let i: number = 0;
    while (i < this.remindIds.length && picked.length < SHOW_MAX) {
      const hit: LaunchSummary | undefined = this.launchIndex.get(this.remindIds[i]);
      if (hit !== undefined) {
        picked.push(hit);
      }
      i++;
    }
    this.remindItems = picked;
  }

  /**
   * 建 id → 发射对象 的索引（upcoming + previous）。
   *
   * 收藏行要显示状态、提醒行要显示整条发射信息，两边都得「按 id 拿对象」。
   * 一次重建供两处共用，既不重复 peek，也保证两处的取数口径不会分叉。
   * 用 peek 而不是 load：这是纯本地查询，页面不该因为建索引去发网络请求。
   */
  private buildLaunchIndex(): void {
    const idx: Map<string, LaunchSummary> = new Map<string, LaunchSummary>();

    const up: UpcomingPayload | null = repo.peek<UpcomingPayload>('upcoming');
    if (up !== null) {
      for (let i = 0; i < up.list.length; i++) {
        const one: LaunchSummary = up.list[i];
        if (one.id.length > 0) {
          idx.set(one.id, one);
        }
      }
    }

    const prev: PreviousPayload | null = repo.peek<PreviousPayload>('previous');
    if (prev !== null) {
      for (let i = 0; i < prev.list.length; i++) {
        const one: LaunchSummary = prev.list[i];
        if (one.id.length > 0) {
          idx.set(one.id, one);
        }
      }
    }

    this.launchIndex = idx;
  }

  /**
   * 读缓存现状。
   *
   * 用 repo.stats() 而不是自己扫目录：stats() 已经把「内存条目 / 磁盘键 / 磁盘字节」
   * 一次算好，页面再拼一遍容易与数据层口径分叉。缓存目录另取 fileStore.getDir()，
   * 因为「缓存到底写在哪」是排查时的第一个问题，清理确认框里要给出真实路径。
   */
  private refreshCacheInfo(): void {
    const s: CacheStats = repo.stats();
    this.cachedCount = s.diskKeys;
    this.cacheBytes = s.diskBytes;
    this.cacheDir = fileStore.getDir();
  }

  /**
   * 读上一次数据同步时间。
   *
   * 有意「先 peek 后 load」：peek() 只查内存 + 文件、不发网络请求，冷启动能立刻
   * 亮出上次时间；随后 load() 走正常链路，命中过期缓存时由 onUpdate 回填。
   * 只认 load 的结果的话，弱网下这一行会长时间空白。
   */
  private loadLastSync(force: boolean): void {
    this.refreshing = true;

    const cached: DataSet | null = repo.peek<DataSet>('upcoming');
    if (cached !== null && cached.generatedAt !== undefined) {
      this.applyGeneratedAt(cached.generatedAt);
    }

    const opts: LoadOptions<DataSet> = {
      force: force,
      onUpdate: (data: DataSet) => {
        this.applyGeneratedAt(data.generatedAt);
        this.refreshCacheInfo();
      }
    };

    repo.load<DataSet>('upcoming', opts)
      .then((data: DataSet) => {
        this.applyGeneratedAt(data.generatedAt);
        this.refreshCacheInfo();
        this.refreshing = false;
      })
      .catch((err: BusinessError) => {
        // 失败不清空已有时间：上一次同步时间仍然是有意义的信息
        this.refreshing = false;
        hilog.warn(DOMAIN, TAG, '读取 upcoming 失败: %{public}s', err.message);
      });
  }

  /** generatedAt（ISO）→「11月2日 20:30」；解析不出来就说「尚未同步」 */
  private applyGeneratedAt(raw: string | undefined): void {
    if (raw === undefined || raw.length === 0) {
      this.lastSyncText = '尚未同步';
      return;
    }
    const shown: string = formatGeneratedAt(raw);
    this.lastSyncText = shown.length > 0 ? shown : '尚未同步';
  }

  // ============ 展示口径 ============

  /**
   * 三格统计的值。
   *
   * 刻意在 @Builder 渲染时调用、而不是算好了当参数传进去：
   * @Builder 的多参是**按值传递**，状态变量变化不会引起 Builder 内 UI 刷新。
   */
  private statValue(index: number): string {
    if (index === 0) {
      return String(this.favTotal);
    }
    if (index === 1) {
      return String(this.remindTotal);
    }
    return currentVersion();
  }

  private statLabel(index: number): string {
    if (index === 0) {
      return '收藏';
    }
    if (index === 1) {
      return '提醒';
    }
    return '当前版本';
  }

  /** 清单行标题：任务名优先；没有就退回火箭型号，再不济给一个诚实占位 */
  private favTitle(item: FavItem): string {
    if (item.title.length > 0) {
      return item.title;
    }
    if (item.rocketName.length > 0) {
      return item.rocketName;
    }
    return '未命名任务';
  }

  /**
   * 发射对象的次要信息：短时间 · 相对时间 · 状态。
   *
   * 与小程序 metaOf(x)（mine.vue:274-279）完全同口径 —— 三个字段、同一个
   * `filter(Boolean).join(' · ')` 语义（这里用 parts 数组 + 非空判断等价实现）。
   * 状态走 statusOf()，它会优先取 status.nameZh，没有中文就用英文名、再退缩写。
   */
  private metaOfLaunch(sum: LaunchSummary): string {
    const parts: string[] = [];
    const t: string = formatShort(sum.net);
    if (t.length > 0) {
      parts.push(t);
    }
    const rel: string = relativeTime(sum.net);
    if (rel.length > 0 && rel !== t) {
      parts.push(rel);
    }
    const st: string = statusOf(sum).text;
    if (st.length > 0) {
      parts.push(st);
    }
    return parts.join(' · ');
  }

  /**
   * 收藏行次要信息。
   *
   * 小程序口径是「短时间 · 相对时间 · 状态」。FavItem **没有 status 快照**
   * （存的是 id/net/title/rocketName/image/siteName/savedAt），所以状态只能
   * 拿 id 去 launchIndex 现查：查得到就用真状态，查不到（如很早的发射已滚出
   * upcoming/previous 窗口）退回火箭型号 / 场地 —— 那仍比留一个「未知」有用。
   * 改数据层加 status 字段属越界（写作用域只允许必要时动 Favorites.ets 的读法），
   * 现查是这条约束下最接近小程序的解。
   */
  private favMeta(item: FavItem): string {
    const sum: LaunchSummary | undefined = this.launchIndex.get(item.id);
    if (sum !== undefined) {
      return this.metaOfLaunch(sum);
    }

    const parts: string[] = [];
    const t: string = formatShort(item.net);
    if (t.length > 0) {
      parts.push(t);
    }
    const rel: string = relativeTime(item.net);
    if (rel.length > 0 && rel !== t) {
      parts.push(rel);
    }
    if (item.rocketName.length > 0) {
      parts.push(item.rocketName);
    } else if (item.siteName.length > 0) {
      parts.push(item.siteName);
    }
    return parts.join(' · ');
  }

  /**
   * 提醒行标题。
   *
   * 小程序 goLaunch 只传 id、标题由目标页自己取；鸿蒙这边行内要先显示一个名字，
   * 所以按「任务中文名 → 任务英文名 → 发射名」的优先级取 —— 与工程里
   * LaunchCard 的取题口径一致（先把翻译出来的任务名给用户看，没有才退英文）。
   */
  private remindTitle(item: LaunchSummary): string {
    const m: LaunchMission | undefined = item.mission;
    // 只判 undefined 不判 null：类型上是 `LaunchMission | undefined`，
    // 多写一个 `!== null` 在 ArkTS 的严格比较下会报「两种类型没有重叠」。
    if (m !== undefined) {
      const zh: string = strOf(m.nameZh);
      if (zh.length > 0) {
        return zh;
      }
      const en: string = strOf(m.name);
      if (en.length > 0) {
        return en;
      }
    }
    const name: string = strOf(item.name);
    return name.length > 0 ? name : '未命名任务';
  }

  /** 「数据与设置」行的右侧值。同样必须现算，理由同 statValue() */
  private settingValue(key: string): string {
    if (key === 'stations') {
      return '15 座';
    }
    if (key === 'data') {
      return '查看';
    }
    if (key === 'refresh') {
      return this.refreshing ? '同步中…' : this.lastSyncText;
    }
    if (key === 'clear') {
      return formatBytes(this.cacheBytes) + ' · ' + String(this.cachedCount) + ' 项';
    }
    return 'v' + currentVersion();
  }

  // ============ 交互 ============

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private onSetting(key: string): void {
    if (key === 'stations') {
      Nav.pushStations();
      return;
    }
    if (key === 'data') {
      this.showDataSourceDialog();
      return;
    }
    if (key === 'refresh') {
      this.loadLastSync(true);
      return;
    }
    if (key === 'clear') {
      this.showClearCacheDialog();
      return;
    }
    if (key === 'about') {
      this.showAboutDialog();
      return;
    }
  }

  /**
   * 探索格点击。
   *
   * 对位小程序 pages/stats / space-assets / neo / events，鸿蒙侧各已实现，
   * 由 Index.ets 的 PageMap 分发、共用 Nav.pushBlank。
   * 空间站例外，走 Nav.pushStations()——虽然也没有入参，但它有自己的 push 方法，
   * 语义比「任意空白页」清楚，将来加筛选参数不用改调用点。
   */
  private onTile(key: string): void {
    if (key === 'stats') {
      Nav.pushBlank(ROUTE_STATS);
    } else if (key === 'assets') {
      Nav.pushBlank(ROUTE_ASSETS);
    } else if (key === 'neo') {
      Nav.pushBlank(ROUTE_NEO);
    } else if (key === 'events') {
      Nav.pushBlank(ROUTE_EVENTS);
    } else if (key === 'stations') {
      Nav.pushStations();
    } else {
      // key 只在内部产生、五值穷举，走到这里说明 tiles 数组被改漏了一项
      hilog.warn(DOMAIN, TAG, '探索格出现未知 key: %{public}s', key);
    }
  }

  /**
   * 数据结构说明 —— 同时是 CC-BY 告知义务的正式落点。
   * 文案逐条说清哪一批数据来自哪儿、许可是什么，不写「本应用」这种空话。
   */
  private showDataSourceDialog(): void {
    AlertDialog.show({
      title: '数据结构说明',
      message: '发射与活动数据：The Space Devs · Launch Library 2（LL2）API；\n' +
        '航天员、空间站、远征队数据同源。\n\n' +
        '卫星编目与在轨资产统计：Jonathan McDowell · GCAT\n' +
        '（planet4589.org/space/gcat），CC-BY 4.0 授权，必须保留署名。\n\n' +
        '图像：NASA（APOD / EPIC / Image Library）。\n\n' +
        '全部数据由云端定时抓取后以静态 JSON 分发，App 只读；\n' +
        '不收集个人信息，也没有账号体系。',
      autoCancel: true,
      confirm: {
        value: '知道了',
        action: () => {
        }
      }
    });
  }

  private showAboutDialog(): void {
    AlertDialog.show({
      title: '关于 SpaceLaunch',
      message: '版本 v' + currentVersion() + '\n' +
        '构建 ' + APP_BUILD + '\n\n' +
        '数据来源：The Space Devs (LL2) · NASA · Jonathan McDowell (GCAT)\n\n' +
        '开源许可：应用代码 MIT；数据按各自来源许可使用 ——\n' +
        'GCAT 为 CC-BY 4.0（署名 Jonathan McDowell），\n' +
        'NASA 图像属公有领域，LL2 数据遵循其 API 使用条款。',
      autoCancel: true,
      confirm: {
        value: '好',
        action: () => {
        }
      }
    });
  }

  /**
   * 清理缓存。
   *
   * 用 repo.vacuum(0) 而不是 repo.clearAll()：clearAll() 会把 upcoming（首屏）
   * 一起清掉，下次冷启动要白等一次网络；vacuum() 按 EVICT_ORDER 逐个删、
   * 且**永不删 upcoming**，正好是「清大件、保首屏」的语义。
   */
  private showClearCacheDialog(): void {
    AlertDialog.show({
      title: '清理缓存',
      message: '当前占用 ' + formatBytes(this.cacheBytes) + '，共 ' +
        String(this.cachedCount) + ' 个数据集。\n\n' +
        '缓存目录：' + (this.cacheDir.length > 0 ? this.cacheDir : '尚未初始化') + '\n\n' +
        '将删除「即将发射」之外的本地数据集（火箭 / 宇航员 / 卫星目录等），\n' +
        '「即将发射」保留，首屏不受影响。\n' +
        '清理后再次浏览相关页面需要重新下载。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清理',
        fontColor: ACCENT,
        action: () => {
          this.doVacuum();
        }
      }
    });
  }

  /** 清理结果用 toast 而不是弹窗：没有需要用户决策的信息，弹窗只是多一次点击 */
  private doVacuum(): void {
    const freed: number = repo.vacuum(0);
    this.refreshCacheInfo();
    hilog.info(DOMAIN, TAG, '清理缓存释放 %{public}d 字节', freed);
    this.toast(freed > 0 ? '已释放 ' + formatBytes(freed) : '没有可清理的缓存');
  }

  // ============ UI：hero ============

  /**
   * hero 辉光（小程序 .hero-glow：760×620rpx 圆，中心在 50% / 46%）。
   *
   * ArkUI 没有 css 的 radial-gradient 语法，用容器自身的 radialGradient 表达：
   * 三档透明度与 css 的 0% / 42% / 68% 停靠点一一对应。
   * 宽度取 100%（小程序 760rpx 已经宽于 750rpx 屏，等价于「铺满并溢出」），
   * 高度 310vp。纯装饰、不接事件 —— 否则会挡住 logo 的点击热区。
   */
  @Builder
  heroGlow() {
    Column()
      .width('100%')
      .height(HERO_GLOW_H)
      .radialGradient({
        center: ['50%', '46%'],
        radius: '58%',
        colors: [[GLOW_A, 0.0], [GLOW_B, 0.42], [GLOW_C, 0.68]]
      })
      .hitTestBehavior(HitTestMode.None)
  }

  /**
   * logo：小程序是 152×152rpx 的**真图片**（/static/logo.png），不是色块 + emoji。
   * 鸿蒙 resources/base/media/app_icon.png 与那张图字节完全相同，直接用。
   * 边框 rgba(56,189,248,0.3) 1vp：小程序 2rpx，用 1vp 是因为 2rpx 在 3x 屏上
   * 会被抹成半像素、发虚。
   */
  @Builder
  logoBadge() {
    Image($r('app.media.app_icon'))
      .width(LOGO_SIZE)
      .height(LOGO_SIZE)
      .borderRadius(LOGO_SIZE / 2)
      .border({ width: 1, color: '#4D38BDF8' })
      .objectFit(ImageFit.Cover)
  }

  /** 身份区：辉光 + logo + 双色字标 + 标语 + 统计 */
  @Builder
  heroBlock() {
    Stack({ alignContent: Alignment.Top }) {
      this.heroGlow()

      Column() {
        this.logoBadge()

        // 双色字标：Space 白 + Launch 青（#22d3ee + 青光）。
        // 两个 Text 紧贴排，中间不能有空格/换行，否则会露出一道缝 ——
        // 这也是小程序注释里专门写过的坑。
        Row() {
          Text('Space')
            .fontSize(28)
            // 小程序是 font-weight:900。ArkUI 的 FontWeight 枚举没有 900 这一档
            // （Bolder 是「比父级更粗」的相对语义，父级 400 时只到 700），
            // 所以直接传数值 —— TextStyle 的 fontWeight 接受 100~900。
            .fontWeight(900)
            .fontColor('#FFFFFF')
            .letterSpacing(-0.5)
          Text('Launch')
            .fontSize(28)
            .fontWeight(900)
            .fontColor(BRAND_CYAN)
            .letterSpacing(-0.5)
            // 小程序 text-shadow 0 0 28rpx rgba(34,211,238,0.42) → 14vp 模糊、无偏移
            .textShadow({ radius: 14, color: BRAND_CYAN_GLOW, offsetX: 0, offsetY: 0 })
        }
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 13 })

        Text('记录人类成为多星球物种的进程')
          .fontSize(12)
          .fontColor(TEXT_HINT)
          .letterSpacing(0.5)
          .margin({ top: 7 })

        // 统计三格：收藏 / 提醒 / 当前版本。整行只有上分割线，没有卡片底 ——
        // 小程序把这块当作 hero 的一部分，套一层卡就成了另一个组件。
        Row() {
          this.statCell(0)
          this.statDivider()
          this.statCell(1)
          this.statDivider()
          this.statCell(2)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 20 })
        .padding({ top: 13, bottom: 15 })
        // 只画上边一条：小程序 .stats 是 border-top，不是整圈卡片
        .border({ width: { top: 1 }, color: '#0FFFFFFF' })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 26, bottom: 20 })
    }
    .width('100%')
  }

  /** 三格统计的一格。参数是 number 字面量（按值传入无副作用），动态值内部现算 */
  @Builder
  statCell(index: number) {
    Column() {
      Text(this.statValue(index))
        // 版本号比数字短不了多少，但用 16vp 与「20vp 数字」区分开（小程序 stat-ver 32rpx）
        .fontSize(index === 2 ? 16 : 20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .maxLines(1)

      Text(this.statLabel(index))
        .fontSize(11)
        .fontColor(TEXT_LABEL)
        .margin({ top: 5 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  /** 统计格之间的竖线：1×23vp（小程序 .stat-line 1×46rpx） */
  @Builder
  statDivider() {
    Divider()
      .vertical(true)
      .height(23)
      .strokeWidth(1)
      .color('#12FFFFFF')
  }

  // ============ UI：清单 ============

  /** 收藏行：48vp 缩略图（无图 🚀 占位）+ 两行标题 + 一行 meta + › */
  @Builder
  favRow(item: FavItem) {
    Row() {
      if (item.image.length > 0) {
        Image(item.image)
          .width(ROW_IMG)
          .height(ROW_IMG)
          .borderRadius(7)
          .objectFit(ImageFit.Cover)
          .backgroundColor(IMG_BG)
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Text('🚀')
            .fontSize(22)
            .opacity(0.45)
        }
        .width(ROW_IMG)
        .height(ROW_IMG)
        .borderRadius(7)
        .backgroundColor(IMG_BG)
      }

      Column() {
        Text(this.favTitle(item))
          .width('100%')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(ROW_TITLE)
          .lineHeight(20)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.favMeta(item))
          .width('100%')
          .fontSize(11.5)
          .fontColor(TEXT_LABEL)
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 9, right: 9 })
      // 不裁切的话，长任务名会把 arrow 顶出卡片
      .clip(true)

      Text('›')
        .fontSize(16)
        .fontColor(ARROW)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .onClick(() => {
      // 用收藏时存下的 net/title 直接进详情，不依赖本地缓存里有没有这条
      Nav.pushLaunch(new LaunchNavParam(item.id, item.net, item.title));
    })
  }

  /** 火箭收藏行：与收藏行同构，第二行固定「运载火箭」（小程序同款） */
  @Builder
  rocketRow(item: MvRocketFav) {
    Row() {
      if (item.image.length > 0) {
        Image(item.image)
          .width(ROW_IMG)
          .height(ROW_IMG)
          .borderRadius(7)
          .objectFit(ImageFit.Cover)
          .backgroundColor(IMG_BG)
      } else {
        Stack({ alignContent: Alignment.Center }) {
          Text('🚀')
            .fontSize(22)
            .opacity(0.45)
        }
        .width(ROW_IMG)
        .height(ROW_IMG)
        .borderRadius(7)
        .backgroundColor(IMG_BG)
      }

      Column() {
        Text(item.name)
          .width('100%')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(ROW_TITLE)
          .lineHeight(20)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text('运载火箭')
          .width('100%')
          .fontSize(11.5)
          .fontColor(TEXT_LABEL)
          .margin({ top: 4 })
          .maxLines(1)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 9, right: 9 })
      .clip(true)

      Text('›')
        .fontSize(16)
        .fontColor(ARROW)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .onClick(() => {
      Nav.pushRocket(new RocketNavParam(item.name));
    })
  }

  /** 「我的收藏」整块 */
  @Builder
  favoriteBlock() {
    Column() {
      // 头部：小程序只有「N 条」；这里多一个「全部 ›」直达 FavoritesView
      // （鸿蒙独有的删除能力得有门，见文件头差异 2）
      Row() {
        Text('我的收藏')
          .fontSize(17)
          .fontWeight(600)
          .fontColor('#FFFFFF')
          .letterSpacing(0.5)

        Column().layoutWeight(1)

        Text(String(this.favTotal) + ' 条')
          .fontSize(12)
          .fontColor(TEXT_LABEL)

        Text('全部 ›')
          .fontSize(12)
          .fontColor(ACCENT)
          .margin({ left: 10 })
          .onClick(() => {
            Nav.pushBlank(ROUTE_FAVORITES);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ bottom: 10 })

      Column() {
        ForEach(this.favItems, (item: FavItem) => {
          this.favRow(item)
        }, (item: FavItem) => 'f' + item.id + '_' + item.savedAt)
      }
      .width('100%')
      .backgroundColor(CARD_BG)
      .borderRadius(11)
      .border({ width: 1, color: CARD_BORDER })
      // 小程序靠 overflow:hidden 把首尾行的直角裁掉；ArkUI 用 clip
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 22 })
  }

  /** 「收藏的火箭」整块 */
  @Builder
  rocketBlock() {
    Column() {
      // 头部直接写在这里、不抽成带参 @Builder：@Builder 的多参按值传递，
      // 「N 个型号」这种跟着 @State 变的文案必须在不带参的 Builder 里直读 this，
      // 否则火箭收藏数变化时头部不会刷新（body 刷新而标题停在旧值）。
      Row() {
        Text('收藏的火箭')
          .fontSize(17)
          .fontWeight(600)
          .fontColor('#FFFFFF')
          .letterSpacing(0.5)

        // 不能用 Blank()：它在 Row 里会吃掉全部剩余宽度把右侧文字挤成 0
        Column().layoutWeight(1)

        Text(String(this.rocketTotal) + ' 个型号')
          .fontSize(12)
          .fontColor(TEXT_LABEL)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ bottom: 10 })

      Column() {
        ForEach(this.rocketItems, (item: MvRocketFav) => {
          this.rocketRow(item)
        }, (item: MvRocketFav) => 'rk' + item.name)
      }
      .width('100%')
      .backgroundColor(CARD_BG)
      .borderRadius(11)
      .border({ width: 1, color: CARD_BORDER })
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 22 })
  }

  /**
   * 提醒行：与收藏行同构，但**没有图**，占位固定 🔔。
   *
   * 小程序 .row-ph 就是这个形状（🔔 + 22vp opacity .45），因为它回查到的发射对象
   * 虽然带 imageThumb，提醒那份清单里却统一走占位 —— 照抄外观，别自作聪明加图。
   */
  @Builder
  remindRow(item: LaunchSummary) {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        Text('🔔')
          .fontSize(22)
          .opacity(0.45)
      }
      .width(ROW_IMG)
      .height(ROW_IMG)
      .borderRadius(7)
      .backgroundColor(IMG_BG)

      Column() {
        Text(this.remindTitle(item))
          .width('100%')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(ROW_TITLE)
          .lineHeight(20)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.metaOfLaunch(item))
          .width('100%')
          .fontSize(11.5)
          .fontColor(TEXT_LABEL)
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 9, right: 9 })
      .clip(true)

      Text('›')
        .fontSize(16)
        .fontColor(ARROW)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .onClick(() => {
      Nav.pushLaunch(new LaunchNavParam(item.id, item.net, this.remindTitle(item)));
    })
  }

  /**
   * 「我的提醒」整块。
   *
   * 头部「N 条」不带「全部 ›」：小程序那边提醒**没有独立页**（收藏有 FavoritesView 的等价物，
   * 提醒没有），多一个箭头点了没处去。所以这里只保留计数。
   * 整块在 build() 里由 remindItems.length > 0 守卫 —— 空清单不渲染空壳（小程序同理）。
   */
  @Builder
  remindBlock() {
    Column() {
      Row() {
        Text('我的提醒')
          .fontSize(17)
          .fontWeight(600)
          .fontColor('#FFFFFF')
          .letterSpacing(0.5)

        Column().layoutWeight(1)

        Text(String(this.remindTotal) + ' 条')
          .fontSize(12)
          .fontColor(TEXT_LABEL)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ bottom: 10 })

      Column() {
        ForEach(this.remindItems, (item: LaunchSummary) => {
          this.remindRow(item)
        }, (item: LaunchSummary) => 'rm' + item.id)
      }
      .width('100%')
      .backgroundColor(CARD_BG)
      .borderRadius(11)
      .border({ width: 1, color: CARD_BORDER })
      .clip(true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 22 })
  }

  /**
   * 空态引导卡（小程序 .tips）。
   *
   * 与小程序的旧实现相反：**不可点、无箭头、青虚线**。原来那版是一整张可点卡片、
   * 带 › 直达收藏页 —— 那是「收藏功能刚上线、没有入口」时的权宜；现在清单本身
   * 就是入口，再让一张说明卡抢戏反而混乱。
   */
  @Builder
  tipsCard() {
    Row() {
      Text('☆')
        .fontSize(17)
        .fontColor(ACCENT)
        .margin({ right: 8 })

      Text('在详情页点「☆ 收藏」或「提醒」，你的清单会出现在这里')
        .fontSize(12)
        .fontColor(TEXT_HINT)
        .lineHeight(19)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 15, bottom: 15, left: 14, right: 14 })
    .backgroundColor(TIPS_BG)
    .border({ width: 1, color: TIPS_BORDER, style: BorderStyle.Dashed })
    .borderRadius(10)
    .margin({ top: 17 })
  }

  // ============ UI：探索 ============

  /** 分组标题（小程序 .block-title-standalone 17vp/600） */
  @Builder
  sectionTitle(title: string) {
    Text(title)
      .width('100%')
      .fontSize(17)
      .fontWeight(600)
      .fontColor('#FFFFFF')
      .letterSpacing(0.5)
      .margin({ top: 22, bottom: 10 })
  }

  /**
   * 探索格的一格。
   *
   * 小程序 .cell：width 48.6%、padding 26/24rpx、圆角 20rpx、**有 1rpx 白 5% 描边**。
   * （任务书差异 9 写「无 border」，但 mine.vue:673 明确写着 border，以源码为准。）
   * 高度写死 108vp：ArkUI 的 Flex 换行不做 css align-items:stretch 那种同行拉伸，
   * 不写死的话「在轨统计 · 卫星百科 · 解体再入」换行后两张卡就差一截。
   */
  @Builder
  tileCell(t: MvTile) {
    Column() {
      Text(t.icon)
        .fontSize(19)
        .lineHeight(19)

      Text(t.title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(ROW_TITLE)
        .margin({ top: 8 })
        .maxLines(1)

      Text(t.desc)
        .fontSize(11)
        .fontColor(TEXT_TILE_DESC)
        .lineHeight(16)
        .margin({ top: 3 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('48.6%')
    .height(TILE_H)
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 13, bottom: 13, left: 12, right: 12 })
    .backgroundColor(CARD_BG)
    .borderRadius(10)
    .border({ width: 1, color: CARD_BORDER })
    .margin({ bottom: 9 })
    .onClick(() => {
      this.onTile(t.key);
    })
  }

  /** 探索区：Flex 换行 + space-between，5 格自然排成 2/2/1 */
  @Builder
  exploreBlock() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween, alignItems: ItemAlign.Start }) {
      ForEach(this.tiles, (t: MvTile) => {
        this.tileCell(t)
      }, (t: MvTile) => t.key)
    }
    .width('100%')
  }

  // ============ UI：数据与设置 ============

  /** 一行设置。样式与「关于」行完全一致，让这组鸿蒙增量看着不像外来物 */
  @Builder
  settingRow(index: number) {
    Row() {
      Text(this.settings[index].title)
        .fontSize(14)
        .fontColor(ROW_TITLE)
        .layoutWeight(1)

      Text(this.settingValue(this.settings[index].key))
        .fontSize(13)
        .fontColor(TEXT_LABEL)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 值可能很长（最后同步时间）但只有这一行可挤，留出 chevron 的位置
        .layoutWeight(1)
        .textAlign(TextAlign.End)

      Text('›')
        .fontSize(16)
        .fontColor(ARROW)
        .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 14, bottom: 14, left: 13, right: 13 })
    .onClick(() => {
      this.onSetting(this.settings[index].key);
    })
  }

  @Builder
  settingCard() {
    Column() {
      this.settingRow(0)
      Divider().strokeWidth(1).color(ROW_DIVIDER).margin({ left: 13, right: 13 })
      this.settingRow(1)
      Divider().strokeWidth(1).color(ROW_DIVIDER).margin({ left: 13, right: 13 })
      this.settingRow(2)
      Divider().strokeWidth(1).color(ROW_DIVIDER).margin({ left: 13, right: 13 })
      this.settingRow(3)
    }
    .width('100%')
    .backgroundColor(CARD_BG)
    .borderRadius(11)
    .border({ width: 1, color: CARD_BORDER })
    .clip(true)
    .margin({ bottom: 20 })
  }

  // ============ UI：关于 ============

  /**
   * 关于块的一行。
   * `action` 只有 'version' 会真的跳转（版本记录页）；其余行传空串，
   * 点击不做任何事 —— ArkTS 不能条件挂 onClick，所以在回调里判空。
   */
  @Builder
  aboutRow(label: string, value: string, arrow: boolean, action: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor(ROW_TITLE)
        .layoutWeight(1)

      Text(value)
        .fontSize(13)
        .fontColor(TEXT_LABEL)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (arrow) {
        Text('›')
          .fontSize(16)
          .fontColor(ARROW)
          .margin({ left: 6 })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 14, bottom: 14, left: 13, right: 13 })
    .onClick(() => {
      if (action === 'version') {
        Nav.pushBlank(ROUTE_VERSION);
      }
    })
  }

  /**
   * 关于块：小程序 5 行减去「联系作者」。
   * 少的那一行不是漏做：小程序用 <button open-type="contact"> 走微信客服，
   * 鸿蒙没有这条通道，做一个点了没反应的「发消息」比不做更糟。
   */
  @Builder
  aboutBlock() {
    Column() {
      Column() {
        this.aboutRow('版本记录', currentVersion(), true, 'version')
        Divider().strokeWidth(1).color(ROW_DIVIDER).margin({ left: 13, right: 13 })
        this.aboutRow('数据来源', 'The Space Devs', false, '')
        Divider().strokeWidth(1).color(ROW_DIVIDER).margin({ left: 13, right: 13 })
        this.aboutRow('卫星编目', 'GCAT', false, '')
        Divider().strokeWidth(1).color(ROW_DIVIDER).margin({ left: 13, right: 13 })
        this.aboutRow('同步频率', '每日自动', false, '')
      }
      .width('100%')
      .backgroundColor(CARD_BG)
      .borderRadius(11)
      .border({ width: 1, color: CARD_BORDER })
      .clip(true)

      // CC-BY 署名（文案与小程序 mine.vue:180 完全一致，是义务不是装饰）
      Text('发射与活动数据来自 Launch Library 2 API，活动信息以官方发布为准。' +
        '卫星编目与在轨资产统计数据来自 GCAT (J. McDowell, planet4589.org/space/gcat)，' +
        '采用 CC-BY 授权。')
        .width('100%')
        .fontSize(11)
        .fontColor(NOTE_TEXT)
        .lineHeight(19)
        .margin({ top: 9 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 20 })
  }

  /** 页脚：小程序只有这一句（署名已在关于块的长注里，不重复） */
  @Builder
  footerLine() {
    Text('SpaceLaunch · 为航天爱好者而做')
      .width('100%')
      .fontSize(11)
      .fontColor(FOOTER_TEXT)
      .letterSpacing(0.5)
      .textAlign(TextAlign.Center)
      .margin({ top: 8, bottom: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1 星空底层：绝对定位铺满、不参与命中测试，必须是 Stack 的第一个子节点
      StarField()

      // 2 内容层
      Scroll() {
        Column() {
          this.heroBlock()

          // 三块清单都按「有数据才显示」——与小程序 v-if 一致，不给空区块占位。
          if (this.favItems.length > 0) {
            this.favoriteBlock()
          }
          if (this.rocketItems.length > 0) {
            this.rocketBlock()
          }
          // 顺序照 mine.vue：收藏 → 火箭 → 提醒。提醒在最后，因为它是三者里
          // 触发路径最深的一个（要先进发射详情）。
          if (this.remindItems.length > 0) {
            this.remindBlock()
          }
          // 引导卡的判定看「三块清单是不是都空」。提醒现在恒为空（无写入方），
          // 但判定仍把它算进来：将来接上提醒开关后，只有提醒的用户不该再看到
          // 「你的清单会出现在这里」。
          if (this.favItems.length === 0 && this.rocketItems.length === 0
            && this.remindItems.length === 0) {
            this.tipsCard()
          }

          this.sectionTitle('探索')
          this.exploreBlock()

          this.sectionTitle('数据与设置')
          this.settingCard()

          this.sectionTitle('关于')
          this.aboutBlock()

          this.footerLine()
        }
        .width('100%')
        // 左右 16 + 底部 92vp 胶囊让位
        .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }
}
