/**
 * 收藏存储层（发射任务）。
 *
 * 为什么用 preferences 而不是 FileStore：
 * 收藏是「几十条以内的小键值」，单条精简到 7 个字段约 300 字节，
 * preferences 单 value 8192 字节的上限完全够；而 FileStore 是给几百 KB 的
 * 数据集分片落盘用的，拿来做收藏等于杀鸡用牛刀，还要自己管目录和版本。
 *
 * 为什么只存精简字段、不存整个 LaunchSummary：
 * 1) 8192 字节放不下几十条完整摘要（一条就有几十个字段）；
 * 2) 摘要里的名称会随数据源更新变化，收藏页应该显示最新的名字，
 *    存下来反而会长期显示过期文案。
 *
 * key 与小程序 `utils/favorites.js` 的 `sl_favorites_v1` 同名，方便两端口径对齐
 * （小程序只存 id 数组，这里存精简对象，是刻意的差异：这里有倒序与时间戳需求）。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'FavStore';

/** preferences 实例名（不是收藏的 key，收藏 key 见 KEY_FAV）。 */
const PREF_NAME: string = 'spacelaunch_prefs';
/** 收藏列表的键名，与小程序同名。 */
const KEY_FAV: string = 'sl_favorites_v1';

/**
 * 「我的提醒」的键名，与小程序 mine.vue 的 REMIND_KEY 完全一致。
 *
 * ⚠ 鸿蒙侧**目前没有任何写入方**（发射详情页只有 ☆ 收藏，没有「提醒」按钮），
 * 所以这里读出来必然是空数组。仍然按同名 key 只读接上，是因为：
 *   1) 将来详情页补上提醒开关时，不用再改数据层，清单会自己活过来；
 *   2) 绝不另造一个 key —— 那会让两端口径永久分叉；
 *   3) 绝不塞假数据 —— 界面上凭空冒出几条「提醒」比空白更糟。
 * 结构是小程序那套：一个 id 字符串数组。
 */
const KEY_REMIND: string = 'reminded_launches';

/**
 * 版本号常量：每次收藏变化都 +1 写进 AppStorage。
 *
 * 为什么用 AppStorage 而不是让页面自己刷新：收藏可能在任何页面被改
 * （详情页点星标、收藏页长按删），而「我的」tab 是保活的、`aboutToAppear`
 * 一辈子只跑一次，`onPageShow` 在 TabContent 里也不触发。
 * 订阅一个全局版本号是唯一不依赖导航时机的接法。
 */
export const FAV_VERSION_KEY: string = 'sl_fav_version';

/** 全局版本号；只增不减，页面靠它判断「该重读了」。 */
let favVersion: number = 0;

function bumpVersion(): void {
  favVersion = favVersion + 1;
  AppStorage.setOrCreate(FAV_VERSION_KEY, favVersion);
}

/**
 * 上限：JSON 序列化后一条约 300 字节，30 条约 9KB 已逼近 8192 字节上限，
 * 所以同时用「条数」和「序列化长度」两道闸，超了就从最旧的开始丢。
 */
const MAX_FAV: number = 30;
const MAX_JSON_LEN: number = 7000;

/** 落盘用的扁平结构。JSON.parse 必须 as 到显式类型，所以单独声明。 */
interface FavRaw {
  id?: string;
  net?: string;
  title?: string;
  rocketName?: string;
  image?: string;
  siteName?: string;
  savedAt?: number;
}

/**
 * 一条收藏。用 class 而不是 interface：ArkTS 禁止用无类型对象字面量，
 * 只有 class 才能 `new FavItem(...)` 造出带类型的值。
 */
export class FavItem {
  id: string = '';
  net: string = '';
  /** mission 名（不是 net，也不是「第 N 次发射」这类编号）。 */
  title: string = '';
  rocketName: string = '';
  image: string = '';
  siteName: string = '';
  /** 收藏时刻（毫秒）。列表按它倒序。 */
  savedAt: number = 0;

  constructor(id: string, net: string, title: string, rocketName: string, image: string,
    siteName: string, savedAt: number) {
    this.id = id;
    this.net = net;
    this.title = title;
    this.rocketName = rocketName;
    this.image = image;
    this.siteName = siteName;
    this.savedAt = savedAt;
  }
}

/** 从落盘结构还原成内存对象，顺带补齐所有空值。 */
function toItem(raw: FavRaw): FavItem {
  const id: string = raw.id !== undefined && raw.id !== null ? raw.id : '';
  const net: string = raw.net !== undefined && raw.net !== null ? raw.net : '';
  const title: string = raw.title !== undefined && raw.title !== null ? raw.title : '';
  const rocketName: string = raw.rocketName !== undefined && raw.rocketName !== null ? raw.rocketName : '';
  const image: string = raw.image !== undefined && raw.image !== null ? raw.image : '';
  const siteName: string = raw.siteName !== undefined && raw.siteName !== null ? raw.siteName : '';
  const savedAt: number = raw.savedAt !== undefined && raw.savedAt !== null ? raw.savedAt : 0;
  return new FavItem(id, net, title, rocketName, image, siteName, savedAt);
}

/**
 * 收藏仓库。模块末尾导出单例 `favorites`，与 `data/Repository.ets` 的 `repo` 同一写法。
 */
export class FavStore {
  private prefs: preferences.Preferences | null = null;
  /** 内存缓存：所有读操作走它，避免每次都碰 preferences。 */
  private cache: FavItem[] = [];
  /** 是否已从磁盘载入过一次。 */
  private loaded: boolean = false;

  /**
   * 初始化。重复调用无副作用。
   * 失败不抛：收藏丢了也不该让页面白屏。
   */
  init(ctx: common.Context): void {
    if (this.prefs !== null) {
      return;
    }
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      this.prefs = preferences.getPreferencesSync(ctx, opt);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'preferences 打开失败，收藏功能降级为只读内存');
      this.prefs = null;
      return;
    }
    this.reload();
  }

  /** 是否已经可用（用于界面上判断要不要提示「存储未就绪」）。 */
  isReady(): boolean {
    return this.prefs !== null;
  }

  /** 从 preferences 读回缓存。只在 init 后调用。 */
  private reload(): void {
    // 先取到局部变量再调：ArkTS 对 `this.xxx` 这类属性访问的类型收窄
    // 不如局部变量可靠，判空后直接用 this 取方法容易被判「可能为 null」。
    const p: preferences.Preferences | null = this.prefs;
    if (p === null || this.loaded) {
      return;
    }
    this.loaded = true;
    try {
      const raw: preferences.ValueType = p.getSync(KEY_FAV, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        this.cache = [];
        return;
      }
      const parsed: FavRaw[] = JSON.parse(raw) as FavRaw[];
      const out: FavItem[] = [];
      for (let i = 0; i < parsed.length; i++) {
        const it: FavItem = toItem(parsed[i]);
        if (it.id.length > 0) {
          out.push(it);
        }
      }
      this.cache = out;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '收藏数据解析失败，按空列表处理');
      this.cache = [];
    }
  }

  /** 把内存缓存写回 preferences。写失败只记日志。 */
  private persist(): void {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null) {
      // 存储没就绪（preferences 打开失败）：内存照改、照广播，只是不落盘。
      bumpVersion();
      return;
    }
    try {
      // 两道闸：先按条数截断，再按序列化长度从最旧的开始丢。
      if (this.cache.length > MAX_FAV) {
        this.cache = this.cache.slice(0, MAX_FAV);
      }
      let text: string = JSON.stringify(this.cache);
      while (text.length > MAX_JSON_LEN && this.cache.length > 1) {
        this.cache = this.cache.slice(0, this.cache.length - 1);
        text = JSON.stringify(this.cache);
      }
      p.putSync(KEY_FAV, text);
      p.flushSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '收藏写入失败，本条仅存在于内存');
    }
    // 无论落盘成败都广播：内存里已经变了，界面就该跟着变。
    bumpVersion();
  }

  /** 按 savedAt 倒序返回（返回副本，外部改不动缓存）。 */
  list(): FavItem[] {
    this.reload();
    const sorted: FavItem[] = this.cache.slice();
    sorted.sort((a: FavItem, b: FavItem) => b.savedAt - a.savedAt);
    return sorted;
  }

  has(id: string): boolean {
    this.reload();
    const key: string = id.trim();
    if (key.length === 0) {
      return false;
    }
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].id === key) {
        return true;
      }
    }
    return false;
  }

  /**
   * 收藏一条。同 id 已存在时只刷新 savedAt 与可能变化的展示字段，
   * 不产生重复条目（与小程序 toggle 的去重口径一致）。
   */
  add(item: FavItem): void {
    this.reload();
    const id: string = item.id.trim();
    if (id.length === 0) {
      return;
    }
    const now: number = item.savedAt > 0 ? item.savedAt : Date.now();
    const next: FavItem[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].id !== id) {
        next.push(this.cache[i]);
      }
    }
    next.push(new FavItem(id, item.net, item.title, item.rocketName, item.image, item.siteName, now));
    this.cache = next;
    this.persist();
  }

  remove(id: string): void {
    this.reload();
    const key: string = id.trim();
    if (key.length === 0) {
      return;
    }
    const next: FavItem[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].id !== key) {
        next.push(this.cache[i]);
      }
    }
    this.cache = next;
    this.persist();
  }

  /** 切换收藏，返回切换后是否已收藏（详情页星标就靠这个返回值定状态）。 */
  toggle(item: FavItem): boolean {
    this.reload();
    const id: string = item.id.trim();
    if (id.length === 0) {
      return false;
    }
    if (this.has(id)) {
      this.remove(id);
      return false;
    }
    this.add(item);
    return true;
  }

  count(): number {
    this.reload();
    return this.cache.length;
  }

  /**
   * 「我的提醒」的 id 列表（只读）。
   *
   * 只读是刻意的：鸿蒙侧还没有提醒开关，任何写入都是无源之水。等详情页接上
   * 提醒按钮时，在外层加一个 toggleRemind() 即可，读路径不用再动。
   * 解析失败 / 非数组 / 空串一律返回空数组，不抛 —— 这一格是装饰性的，
   * 一份坏数据不该把「我的」整页搞白。
   */
  remindedList(): string[] {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null) {
      return [];
    }
    try {
      const raw: preferences.ValueType = p.getSync(KEY_REMIND, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return [];
      }
      // JSON.parse 必须 as：ArkTS 不接受隐式 any
      const arr: string[] = JSON.parse(raw) as string[];
      const out: string[] = [];
      for (let i = 0; i < arr.length; i++) {
        const id: string = typeof arr[i] === 'string' ? arr[i].trim() : '';
        if (id.length > 0) {
          out.push(id);
        }
      }
      return out;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '提醒数据解析失败，按空列表处理');
      return [];
    }
  }

  /** 清空（给「清理缓存」之类入口备用，故意不暴露在 UI 上）。 */
  clear(): void {
    this.cache = [];
    this.persist();
  }
}

/** 全局单例。 */
export const favorites: FavStore = new FavStore();

/**
 * 初始化入口。调用方（各 View 的 aboutToAppear）传
 * `this.getUIContext().getHostContext()`，取不到就跳过一次初始化，
 * 下次调用还能补上。
 */
export function favInit(ctx: common.Context): void {
  favorites.init(ctx);
}

export function favList(): FavItem[] {
  return favorites.list();
}

export function favHas(id: string): boolean {
  return favorites.has(id);
}

export function favAdd(item: FavItem): void {
  favorites.add(item);
}

export function favRemove(id: string): void {
  favorites.remove(id);
}

export function favToggle(item: FavItem): boolean {
  return favorites.toggle(item);
}

export function favCount(): number {
  return favorites.count();
}

/**
 * 「我的提醒」的 id 列表（只读）。
 * 见 FavStore.remindedList 的注释：鸿蒙侧暂无写入方，返回空数组是正常结果。
 */
export function remindedList(): string[] {
  return favorites.remindedList();
}
