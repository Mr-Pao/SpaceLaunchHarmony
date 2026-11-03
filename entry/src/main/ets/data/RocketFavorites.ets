/**
 * 火箭收藏存储层（「我的 → 收藏的火箭」）。
 *
 * 为什么单独一个文件、而不是往 data/Favorites.ets 里塞：
 * 小程序 utils/favorites.js 的 createStore 明确把两份清单**分开**存
 * （`sl_favorites_v1` 存发射、`sl_fav_rockets_v1` 存火箭），因为两者的
 * 主键语义不同：发射是 LL2 的 UUID，火箭是 launchers 里的型号名。
 * 混在一个数组里，删除、去重、计数三处都要先判类型，得不偿失。
 *
 * 为什么只存「名字 + 配图 + 收藏时刻」，不存 launchers 的完整记录：
 *   1) preferences 单个 value 上限 8192 字节，一条 launchers 记录（36 个字段、
 *      带 description）序列化后 1KB 起步，存三条就超；
 *   2) 型号参数（长度 / 推力 / LEO）天天可能被数据源修正，存下来只会长期显示旧值。
 *      名字是稳定主键，展示时按名字回查即可 —— 与本页「收藏的火箭」只显示
 *      名字 + 「运载火箭」一行的口径一致。
 *
 * 与 Favorites.ets 的版本号机制完全同构（AppStorage 广播）：
 * 「我的」tab 在 TabContent 里保活、onPageShow 不触发，只有全局版本号
 * 能把「在别的页面改了收藏」这件事推进来。这里用独立的 key，
 * 免得改火箭收藏把发射收藏页也重刷一遍。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0002;
const TAG: string = 'RkFavStore';

/** preferences 实例名，与 Favorites.ets 共用同一个实例（同名 key 空间互不冲突）。 */
const PREF_NAME: string = 'spacelaunch_prefs';
/** 火箭收藏的键名，与小程序 `sl_fav_rockets_v1` 同名，方便两端口径对齐。 */
const KEY_RK: string = 'sl_fav_rockets_v1';

/**
 * 火箭收藏版本号。每次变化都 +1 写进 AppStorage，
 * 「我的」页订阅它来重读清单（理由见文件头）。
 */
export const RKF_VERSION_KEY: string = 'sl_rkfav_version';

let rkVersion: number = 0;

function bumpRkVersion(): void {
  rkVersion = rkVersion + 1;
  AppStorage.setOrCreate(RKF_VERSION_KEY, rkVersion);
}

/**
 * 上限。型号名普遍短于发射标题（「Falcon 9」约 8 字节），
 * 一条精简记录连同 JSON 结构约 120 字节，40 条约 4.8KB；
 * 再加 7000 字节的第二道闸，保证永远碰不到 8192 的硬上限。
 */
const MAX_RK: number = 40;
const MAX_JSON_LEN: number = 7000;

/** 落盘用的扁平结构。JSON.parse 必须 as 到显式类型，所以单独声明。 */
interface MvRkRaw {
  name?: string;
  image?: string;
  savedAt?: number;
}

/**
 * 一条火箭收藏。
 * 用 class 而不是 interface：ArkTS 禁无类型对象字面量，列表项必须可 new。
 */
export class MvRocketFav {
  /** 型号名（launchers 的 name，也是 RocketNavParam 的唯一入参） */
  name: string = '';
  /** 型号配图（launchers.image），空串则列表画 🚀 占位 */
  image: string = '';
  /** 收藏时刻（毫秒）。列表按它倒序 */
  savedAt: number = 0;

  constructor(name: string, image: string, savedAt: number) {
    this.name = name;
    this.image = image;
    this.savedAt = savedAt;
  }
}

/** 从落盘结构还原，顺带补齐所有空值。 */
function toRkItem(raw: MvRkRaw): MvRocketFav {
  const name: string = raw.name !== undefined && raw.name !== null ? raw.name : '';
  const image: string = raw.image !== undefined && raw.image !== null ? raw.image : '';
  const savedAt: number = raw.savedAt !== undefined && raw.savedAt !== null ? raw.savedAt : 0;
  return new MvRocketFav(name, image, savedAt);
}

/** 火箭收藏仓库。模块末尾导出单例 `rocketFavorites`。 */
export class MvRocketFavStore {
  private prefs: preferences.Preferences | null = null;
  private cache: MvRocketFav[] = [];
  private loaded: boolean = false;

  /** 初始化。重复调用无副作用；失败不抛 —— 收藏坏了也不该让页面白屏。 */
  init(ctx: common.Context): void {
    if (this.prefs !== null) {
      return;
    }
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      this.prefs = preferences.getPreferencesSync(ctx, opt);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'preferences 打开失败，火箭收藏降级为只读内存');
      this.prefs = null;
      return;
    }
    this.reload();
  }

  isReady(): boolean {
    return this.prefs !== null;
  }

  private reload(): void {
    // 先取局部变量：ArkTS 对 this.xxx 判空后的类型收窄不如局部变量可靠
    const p: preferences.Preferences | null = this.prefs;
    if (p === null || this.loaded) {
      return;
    }
    this.loaded = true;
    try {
      const raw: preferences.ValueType = p.getSync(KEY_RK, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        this.cache = [];
        return;
      }
      const parsed: MvRkRaw[] = JSON.parse(raw) as MvRkRaw[];
      const out: MvRocketFav[] = [];
      for (let i = 0; i < parsed.length; i++) {
        const it: MvRocketFav = toRkItem(parsed[i]);
        if (it.name.length > 0) {
          out.push(it);
        }
      }
      this.cache = out;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '火箭收藏解析失败，按空列表处理');
      this.cache = [];
    }
  }

  private persist(): void {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null) {
      // 存储没就绪：内存照改、照广播，只是不落盘（与 Favorites.ets 同策略）
      bumpRkVersion();
      return;
    }
    try {
      if (this.cache.length > MAX_RK) {
        this.cache = this.cache.slice(0, MAX_RK);
      }
      let text: string = JSON.stringify(this.cache);
      while (text.length > MAX_JSON_LEN && this.cache.length > 1) {
        this.cache = this.cache.slice(0, this.cache.length - 1);
        text = JSON.stringify(this.cache);
      }
      p.putSync(KEY_RK, text);
      p.flushSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '火箭收藏写入失败，本条仅存在于内存');
    }
    bumpRkVersion();
  }

  /** 按 savedAt 倒序返回副本。 */
  list(): MvRocketFav[] {
    this.reload();
    const sorted: MvRocketFav[] = this.cache.slice();
    sorted.sort((a: MvRocketFav, b: MvRocketFav) => b.savedAt - a.savedAt);
    return sorted;
  }

  has(name: string): boolean {
    this.reload();
    const key: string = name.trim();
    if (key.length === 0) {
      return false;
    }
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].name === key) {
        return true;
      }
    }
    return false;
  }

  /** 收藏一个型号。同名只刷新 image/savedAt，不产生重复条目。 */
  add(item: MvRocketFav): void {
    this.reload();
    const key: string = item.name.trim();
    if (key.length === 0) {
      return;
    }
    const now: number = item.savedAt > 0 ? item.savedAt : Date.now();
    const next: MvRocketFav[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].name !== key) {
        next.push(this.cache[i]);
      }
    }
    next.push(new MvRocketFav(key, item.image, now));
    this.cache = next;
    this.persist();
  }

  remove(name: string): void {
    this.reload();
    const key: string = name.trim();
    if (key.length === 0) {
      return;
    }
    const next: MvRocketFav[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].name !== key) {
        next.push(this.cache[i]);
      }
    }
    this.cache = next;
    this.persist();
  }

  /** 切换收藏，返回切换后是否已收藏（详情页星标靠它定状态）。 */
  toggle(item: MvRocketFav): boolean {
    this.reload();
    const key: string = item.name.trim();
    if (key.length === 0) {
      return false;
    }
    if (this.has(key)) {
      this.remove(key);
      return false;
    }
    this.add(item);
    return true;
  }

  count(): number {
    this.reload();
    return this.cache.length;
  }

  /** 清空。故意不暴露在 UI 上，留给「清理数据」类入口备用。 */
  clear(): void {
    this.cache = [];
    this.persist();
  }
}

/** 全局单例。 */
export const rocketFavorites: MvRocketFavStore = new MvRocketFavStore();

/** 初始化入口：调用方传 `this.getUIContext().getHostContext()`。 */
export function rocketFavInit(ctx: common.Context): void {
  rocketFavorites.init(ctx);
}

export function rocketFavList(): MvRocketFav[] {
  return rocketFavorites.list();
}

export function rocketFavHas(name: string): boolean {
  return rocketFavorites.has(name);
}

export function rocketFavAdd(item: MvRocketFav): void {
  rocketFavorites.add(item);
}

export function rocketFavRemove(name: string): void {
  rocketFavorites.remove(name);
}

export function rocketFavToggle(item: MvRocketFav): boolean {
  return rocketFavorites.toggle(item);
}

export function rocketFavCount(): number {
  return rocketFavorites.count();
}
