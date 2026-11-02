/**
 * Repository —— 三级缓存数据层（ArkTS 版）
 *
 * 对位原项目 utils/data.js：
 *   L1 内存 Map   —— 同一次会话内二次调用 0 消耗
 *   L2 文件缓存   —— 冷启动立刻渲染，不用等网络（鸿蒙用 filesDir 文件，不用 preferences）
 *   L3 CDN JSON   —— 后台静默刷新，generatedAt 变了才回填页面
 *
 * 与 utils/data.js 的三处有意偏差（详见交付报告）：
 *   a) 少了 uni.getStorageInfoSync 那种「按前缀扫历史版本」的能力，改为
 *      缓存目录本身带 v{DATA_VERSION}，升版本即新目录，旧目录由 clearAll() 收走；
 *   b) chunk(name, 0) 直接返回索引文件自身的 list（原项目返回空数组，
 *      因为调用方手上已经有第 0 片了）。这里做成「给什么拉什么」，语义更直白；
 *   c) 新增 onCache 首屏回调、vacuum/stats，原项目没有。
 */

import {
  DatasetName, FILES, SOFT_TTL, getSoftTTL, EVICT_ORDER, HOURLY_CACHE,
  CDN_BASE, DATA_VERSION, GALLERY_V, storageKey, chunkFile
} from '../constants/Dataset';
import { fileStore } from './FileStore';
import { getText } from '../api/HttpClient';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'SpaceRepo';

const MINUTE: number = 60 * 1000;
const HOUR: number = 60 * MINUTE;
const DAY: number = 24 * HOUR;

// ============ 类型 ============

/**
 * 数据集对象的形状。
 *
 * 关键点（对应原项目 decorate 的教训）：
 *   原项目 decorate() 曾经用「白名单式挑选」重建对象，新增字段忘记同步就会
 *   「数据里有、页面显示 0」，而且不报错 —— neoNears 的 totalKnown / pastCount /
 *   closest 就这么丢过一轮。后来改成 Object.assign 以原始数据打底。
 *
 *   ArkTS 里我们**不重建对象**：JSON.parse 出来的就是完整对象，
 *   `as DataSet` 只是编译期断言，运行时属性一个都不少，因此天然不会丢字段。
 *   下面这些字段全部可选，只是为了让消费端有类型可依；缺失值由 fillDefaults()
 *   就地补，而不是造一个新对象 —— 这正是原项目踩过的坑。
 */
export interface DataSet {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  count?: number;
  served?: number;
  // gallery 分片元信息
  chunks?: number;
  chunkSize?: number;
  launchTotal?: number;
  // satellites（活跃总数）/ orbitStats（聚合统计）
  total?: number;
  byState?: Object[];
  byOrbit?: Object[];
  byClass?: Object[];
  byDecade?: Object[];
  // debrisEvents
  breakupCount?: number;
  // neoNears
  totalKnown?: number;
  hazardous?: number;
  pastCount?: number;
  window?: string;
  closest?: Object;
  // nasaImages：主题清单，少了标签栏会静默消失
  themes?: Object[];
  // 逐条数据
  list?: Object[];
  // 缓存时间戳（我们自己写入）
  savedAt?: number;
  stale?: boolean;
}

export interface LoadOptions<T> {
  /** 命中缓存立即回调（首屏用），ageMs 为缓存年龄 */
  onCache?: (data: T, ageMs: number) => void;
  /** 后台刷新且 generatedAt 变了才回调 */
  onUpdate?: (data: T) => void;
  /** 跳过缓存直接回源 */
  force?: boolean;
  /** 覆盖读超时（毫秒） */
  timeoutMs?: number;
}

export interface ChunkResult<T> {
  index: number;
  list: T[];
  chunks: number;
  chunkSize: number;
  /** 是否最后一片 */
  end: boolean;
}

export interface CacheStats {
  memoryEntries: number;
  diskKeys: number;
  diskBytes: number;
  chunkEntries: number;
  inflight: number;
  dataVersion: number;
  galleryVersion: number;
}

/** 内存里的缓存条目 */
interface CacheEntry {
  data: DataSet;
  savedAt: number;
}

/** 只有 id 一个字段的结构，用于 findById 的运行时断言 */
interface ItemWithId {
  id?: string | number;
}

// ============ 常量（沿用 utils/data.js） ============

/**
 * 硬过期：超过这个时间的缓存不再无限期占磁盘，读到就删掉，但数据照样返回，
 * 随后由 load() 触发后台刷新重写。对应 data.js 的 HARD_TTL。
 *
 * 注：这组常量本应放 constants/Dataset.ets，但那份文件由同事负责、且未约定导出
 * HARD_TTL，为了不阻塞这里先本地放着；等 Dataset 导出了就删掉这段、改成 import。
 */
const HARD_TTL_DEFAULT: number = 7 * DAY;
const HARD_TTL_KEYS: string[] = [
  'upcomingMore', 'agencies', 'launchers', 'pads', 'timelines', 'videos',
  'gallery', 'satellites', 'orbitStats', 'debrisEvents', 'news', 'onthisday'
];
const HARD_TTL_VALUES: number[] = [
  2 * DAY, 2 * DAY, 2 * DAY, 3 * DAY, 2 * DAY, 2 * DAY,
  3 * DAY, 2 * DAY, 3 * DAY, 3 * DAY, 2 * DAY, 12 * HOUR
];

/**
 * 每日类数据集：拿到空列表几乎总是上游故障留下的，即使没到 TTL 也当过期。
 * 对应 data.js 的 EMPTY_SUSPECT —— 经源码确认**只有 apod / epic 两个**。
 */
const EMPTY_SUSPECT: Set<string> = new Set<string>(['apod', 'epic']);

/**
 * 每日类数据集在 TTL 内也要做一次轻量校验：否则线上已经从 6 条涨到 89 条，
 * 页面还在旧缓存上干等满一个 TTL。对应 data.js 的 DAILY_REVALIDATE。
 */
const DAILY_REVALIDATE: Set<string> = new Set<string>(['apod', 'epic', 'nasaImages']);
const REVALIDATE_GAP_KEYS: string[] = ['apod', 'epic', 'nasaImages'];
const REVALIDATE_GAP_VALUES: number[] = [5 * MINUTE, 5 * MINUTE, HOUR];

/** 首页首屏数据集，任何情况下都不主动淘汰 */
const PROTECTED: string = 'upcoming';

// ============ 主体 ============

export class Repository {
  // 数据集名 → { data, savedAt }
  private memory: Map<string, CacheEntry> = new Map<string, CacheEntry>();

  // 数据集名 → Promise：同一数据集并发只发一次（前台与后台刷新共用）
  private inflight: Map<string, Promise<DataSet>> = new Map<string, Promise<DataSet>>();

  // 分片只活在本会话内存里，不落盘（一份 140KB，落盘没意义）
  private chunkMemory: Map<string, Object[]> = new Map<string, Object[]>();
  private chunkInflight: Map<string, Promise<Object[]>> = new Map<string, Promise<Object[]>>();

  // 每日类数据集上次校验时间
  private lastRecheck: Map<string, number> = new Map<string, number>();

  // 硬过期标记：读到过期缓存时置位，由下一次 load 消费
  private expiredFlag: Map<string, boolean> = new Map<string, boolean>();

  // ============ 对外接口 ============

  /**
   * 读一个数据集。
   *
   * 流程严格对齐 data.js 的 load()：
   *   force          → 直接回源，成功写缓存，**不触发任何回调**，resolve 新数据
   *   有缓存         → onCache 立即回调；必要时后台刷新（不阻塞），resolve 缓存
   *                     · 硬过期 / 年龄 > SOFT_TTL / apod·epic 空列表 → 视为 stale，必须刷
   *                     · 每日类到点 → 也刷一次
   *   无缓存         → 等网络；apod/epic 拿到空列表自动 bypass 再取一次
   *   网络失败且有缓存 → 静默 resolve 缓存值（不能把错误抛给已渲染的页面）
   *   网络失败且无缓存 → reject（对应原项目「弱网无缓存必须 reject」的约定）
   */
  async load<T>(name: DatasetName, opts?: LoadOptions<T>): Promise<T> {
    const key: string = String(name);
    const fileName: string | undefined = FILES.get(name);
    if (fileName === undefined || fileName.length === 0) {
      throw new Error('未知数据集: ' + key);
    }

    const options: LoadOptions<T> = opts !== undefined ? opts : {};

    // ---------- 强制刷新 ----------
    if (options.force === true) {
      const fresh: DataSet = await this.fetchShared(name, true, options.timeoutMs);
      // force 分支不触发 onUpdate，直接 resolve 新数据（与 data.js 一致）
      return fresh as Object as T;
    }

    // ---------- 有缓存 ----------
    const hit: CacheEntry | null = this.readEntry(name);
    if (hit !== null) {
      const data: DataSet = hit.data;
      const age: number = Date.now() - hit.savedAt;
      const ttl: number = this.softTtlOf(name);
      const list: Object[] | undefined = data.list;
      const isEmptyDaily: boolean =
        EMPTY_SUSPECT.has(key) && (list === undefined || list.length === 0);
      const expired: boolean = this.expiredFlag.get(key) === true;
      this.expiredFlag.delete(key);

      const stale: boolean = expired || age > ttl || isEmptyDaily;

      // 首屏回调：有缓存就立刻给，不等网络
      if (options.onCache !== undefined) {
        options.onCache(data as Object as T, age);
      }

      // 过期了（或每日类到点）就在后台刷一次，不阻塞本次返回
      const needCheck: boolean = stale || this.shouldRecheck(name);
      if (needCheck) {
        this.refreshInBackground(name, data.generatedAt, options.onUpdate, options.timeoutMs);
      }

      data.stale = stale;
      return data as Object as T;
    }

    // ---------- 无缓存，必须等网络 ----------
    // 走到这里说明确实没有任何缓存可用，失败只能把错误交给调用方
    const d: DataSet = await this.fetchOrRetryEmpty(name, options.timeoutMs);
    return d as Object as T;
  }

  /**
   * 纯内存 + 文件缓存查找，**绝不触发网络**。
   * 对应原项目 peekLaunchById 的思路（进详情页前先判断能不能打开）。
   */
  peek<T>(name: DatasetName): T | null {
    const hit: CacheEntry | null = this.readEntry(name);
    if (hit === null) {
      return null;
    }
    return hit.data as Object as T;
  }

  /** 下拉刷新：绕过缓存重新拉（force） */
  refresh<T>(name: DatasetName): Promise<T> {
    const options: LoadOptions<T> = { force: true };
    return this.load<T>(name, options);
  }

  /**
   * 拉第 index 片。
   *
   * index === 0 读索引文件本身（gallery.json / satellites.json 就带第 0 片），
   * index >= 1 读 gallery/1.json、satellites/1.json …
   * 分片只进内存，杀进程后重拉。
   */
  async chunk<T>(name: 'gallery' | 'satellites', index: number): Promise<ChunkResult<T>> {
    const i: number = index > 0 ? Math.floor(index) : 0;

    if (i === 0) {
      const d: DataSet = await this.load<DataSet>(name, undefined);
      return this.toChunk<T>(i, d.count !== undefined ? d.count : 0, d);
    }

    const memoKey: string = String(name) + '#' + i;
    const cachedList: Object[] | undefined = this.chunkMemory.get(memoKey);
    if (cachedList !== undefined) {
      return this.toChunk<T>(i, cachedList.length, undefined);
    }
    const running: Promise<Object[]> | undefined = this.chunkInflight.get(memoKey);
    if (running !== undefined) {
      const list: Object[] = await running;
      return this.toChunk<T>(i, list.length, undefined);
    }

    const p: Promise<Object[]> = this.fetchChunk(name, i);
    this.chunkInflight.set(memoKey, p);
    const clear = () => {
      if (this.chunkInflight.get(memoKey) === p) {
        this.chunkInflight.delete(memoKey);
      }
    };
    p.then(clear, clear);

    const list: Object[] = await p;
    return this.toChunk<T>(i, list.length, undefined);
  }

  /**
   * 按 id 找一条（同步，只查缓存）。
   * 详情页不要传下标，传 id —— 列表刷新后下标会错位，id 不会。
   */
  findById<T>(name: DatasetName, id: string): T | null {
    if (id === undefined || id === null || id.length === 0) {
      return null;
    }
    const hit: CacheEntry | null = this.readEntry(name);
    if (hit === null) {
      return null;
    }
    const list: Object[] | undefined = hit.data.list;
    if (list === undefined) {
      return null;
    }
    for (let i = 0; i < list.length; i++) {
      const item: Object = list[i];
      const rec: ItemWithId = item as ItemWithId;
      if (rec !== null && rec !== undefined && rec.id !== undefined && rec.id !== null) {
        if (String(rec.id) === id) {
          return item as Object as T;
        }
      }
    }
    return null;
  }

  /** 清空全部缓存（内存 + 文件 + 分片） */
  clearAll(): void {
    this.memory.clear();
    this.inflight.clear();
    this.chunkMemory.clear();
    this.chunkInflight.clear();
    this.lastRecheck.clear();
    this.expiredFlag.clear();
    // 只清当前版本目录：别的版本目录由系统清理 / init 时重建
    fileStore.clearAllSync();
  }

  /**
   * 配额淘汰：按 EVICT_ORDER 逐个删，直到占用 <= targetBytes。
   *
   * **upcoming 永远不主动丢** —— 它是首页首屏，被清掉的话下次冷启动白屏等网络。
   * 同理：绝不能 clear() 清空全部，那会把首页缓存一起带走，首屏体验从 0ms
   * 退化到一次网络往返。所以这里只按名单逐个删，不做整目录清空。
   *
   * @returns 实际释放的字节数
   */
  vacuum(targetBytes: number): number {
    const before: number = fileStore.totalSizeSync();
    if (before <= targetBytes) {
      return 0;
    }

    for (let i = 0; i < EVICT_ORDER.length; i++) {
      if (fileStore.totalSizeSync() <= targetBytes) {
        break;
      }
      const victim: DatasetName = EVICT_ORDER[i];
      // upcoming 永不主动丢
      if (String(victim) === PROTECTED) {
        continue;
      }
      fileStore.removeSync(storageKey(victim));
      this.memory.delete(String(victim));
    }

    const after: number = fileStore.totalSizeSync();
    return before > after ? before - after : 0;
  }

  /** 缓存现状，供「我的 → 存储」诊断用 */
  stats(): CacheStats {
    const s: CacheStats = {
      memoryEntries: this.memory.size,
      diskKeys: fileStore.listKeysSync().length,
      diskBytes: fileStore.totalSizeSync(),
      chunkEntries: this.chunkMemory.size,
      inflight: this.inflight.size,
      dataVersion: DATA_VERSION,
      galleryVersion: GALLERY_V
    };
    return s;
  }

  // ============ 缓存读写 ============

  /** 命中内存优先，其次文件；文件命中会回填内存 */
  private readEntry(name: DatasetName): CacheEntry | null {
    const key: string = String(name);
    const memo: CacheEntry | undefined = this.memory.get(key);
    if (memo !== undefined) {
      return memo;
    }

    const raw: string | null = fileStore.readSync(storageKey(name));
    if (raw === null) {
      return null;
    }

    let data: DataSet | null = null;
    try {
      data = JSON.parse(raw) as DataSet;
    } catch (e) {
      // 文件损坏就当没有缓存（原子写理论上不该出现，但别赌）
      fileStore.removeSync(storageKey(name));
      return null;
    }
    if (data === null || data === undefined) {
      fileStore.removeSync(storageKey(name));
      return null;
    }

    // 空列表视为无效缓存，除非它是聚合型数据集（本体没有 list，
    // 数据在 byState/byOrbit/total 里 —— 否则 orbitStats 每次都走网络）
    const list: Object[] | undefined = data.list;
    const hasList: boolean = list !== undefined && Array.isArray(list);
    const hasAggregate: boolean =
      data.byState !== undefined || data.byOrbit !== undefined || data.total !== undefined;
    if (!hasList || (list !== undefined && list.length === 0 && !hasAggregate)) {
      return null;
    }
    const savedAt: number | undefined = data.savedAt;
    if (savedAt === undefined || savedAt <= 0) {
      return null;
    }

    const age: number = Date.now() - savedAt;
    if (age > this.hardTtlOf(name)) {
      // 硬过期：立刻腾出磁盘，但数据照样返回给本次会话，
      // 随后 load() 会触发后台刷新重写缓存（与 data.js 一致）
      fileStore.removeSync(storageKey(name));
      this.expiredFlag.set(key, true);
    }

    const entry: CacheEntry = { data: data, savedAt: savedAt };
    this.memory.set(key, entry);
    return entry;
  }

  /**
   * 写缓存。写失败（磁盘满）时按 EVICT_ORDER 淘汰别的数据集再重试，
   * **绝不整目录清空**（否则首页缓存一起没了）。
   */
  private writeStorage(name: DatasetName, data: DataSet): void {
    const key: string = String(name);
    if (fileStore.writeSync(storageKey(name), JSON.stringify(data))) {
      return;
    }

    hilog.warn(DOMAIN, TAG, '写缓存失败，开始淘汰其它数据集 %{public}s', key);
    for (let i = 0; i < EVICT_ORDER.length; i++) {
      const victim: DatasetName = EVICT_ORDER[i];
      if (String(victim) === key) {
        continue;
      }
      fileStore.removeSync(storageKey(victim));
      this.memory.delete(String(victim));
      if (fileStore.writeSync(storageKey(name), JSON.stringify(data))) {
        return;
      }
    }
    // 淘汰后仍写不进去：仅保留内存缓存（下次冷启动重新拉）
    hilog.warn(DOMAIN, TAG, '淘汰后仍写不进去，仅保留内存缓存 %{public}s', key);
  }

  // ============ 网络 ============

  /**
   * 带并发去重的网络抓取：同一数据集在途时复用同一个 Promise。
   * bypass 的 URL 每次都不同，不能复用（与 data.js 的 fetchShared 一致）。
   */
  private fetchShared(name: DatasetName, bypass: boolean, timeoutMs?: number): Promise<DataSet> {
    const key: string = String(name);
    if (!bypass) {
      const running: Promise<DataSet> | undefined = this.inflight.get(key);
      if (running !== undefined) {
        return running;
      }
    }

    const p: Promise<DataSet> = this.fetchDataset(name, bypass, timeoutMs);
    if (!bypass) {
      this.inflight.set(key, p);
      const clear = () => {
        if (this.inflight.get(key) === p) {
          this.inflight.delete(key);
        }
      };
      // 成败都清理，失败后下一次调用允许重新发请求
      p.then(clear, clear);
    }
    return p;
  }

  /**
   * 拉一个数据集：拼 URL → getText → JSON.parse → 落内存 + 落盘。
   *
   * URL 时间戳：高频数据集按分钟取整，小时级数据集（HOURLY_CACHE）
   * 按小时取整，让 CDN 边缘缓存真正生效。
   * bypass 追加唯一随机参数：COS 对象带 Cache-Control: max-age=3600，
   * 小时级 t 在同一小时内不变，光靠 force 走网络也会被运行时缓存挡回去。
   */
  private async fetchDataset(
    name: DatasetName, bypass: boolean, timeoutMs?: number
  ): Promise<DataSet> {
    const fileName: string | undefined = FILES.get(name);
    if (fileName === undefined) {
      throw new Error('未知数据集: ' + String(name));
    }

    const granularity: number = HOURLY_CACHE.has(name) ? HOUR : MINUTE;
    let url: string = CDN_BASE + '/' + fileName + '?t=' + Math.floor(Date.now() / granularity);
    if (bypass) {
      url += '&r=' + Date.now() + '-' + Math.floor(Math.random() * 1000000);
    }

    const text: string = await getText(url, timeoutMs);
    const body: DataSet = JSON.parse(text) as DataSet;

    if (body === null || body === undefined) {
      throw new Error('数据格式异常: ' + String(name));
    }

    // 版本不一致不拒绝，只提示：字段都是后加的，旧数据照样能用，
    // 硬拒绝会让「前端先更新、CI 还没跑」的窗口期整页报错。
    // 缓存目录带版本号，所以旧缓存不会被误用。
    const bodyVersion: number | undefined = body.v;
    if (bodyVersion !== undefined && bodyVersion !== DATA_VERSION) {
      hilog.warn(
        DOMAIN, TAG, '数据版本不一致 %{public}s 线上=%{public}d 本地=%{public}d',
        String(name), bodyVersion, DATA_VERSION
      );
    }

    // 不重建对象：直接在解析结果上补 savedAt，未知字段一个都不动
    const savedAt: number = Date.now();
    body.savedAt = savedAt;
    if (body.dataset === undefined) {
      body.dataset = String(name);
    }
    this.fillDefaults(body);

    const entry: CacheEntry = { data: body, savedAt: savedAt };
    this.memory.set(String(name), entry);
    this.writeStorage(name, body);

    return body;
  }

  /**
   * 每日类数据拿到空列表时自动绕缓存再取一次。
   * 原因：COS 的 max-age=3600 会让同一小时内的空响应被压住，
   * 空结果不该被信任，必须换唯一 URL 回源确认。对应 fetchOrRetryEmpty。
   */
  private async fetchOrRetryEmpty(name: DatasetName, timeoutMs?: number): Promise<DataSet> {
    const d: DataSet = await this.fetchShared(name, false, timeoutMs);
    if (EMPTY_SUSPECT.has(String(name))) {
      const list: Object[] | undefined = d.list;
      if (list === undefined || list.length === 0) {
        return this.fetchShared(name, true, timeoutMs);
      }
    }
    return d;
  }

  /**
   * 后台刷新。失败必须静默 —— 用户手里已经有数据了，后台刷新失败不值得影响页面。
   * 只有 generatedAt 变了才回调 onUpdate：没变说明线上还没更新，不必打扰页面。
   */
  private refreshInBackground<T>(
    name: DatasetName,
    oldGeneratedAt: string | undefined,
    onUpdate: ((data: T) => void) | undefined,
    timeoutMs?: number
  ): void {
    const key: string = String(name);
    // 已经在刷同一个数据集就不要再发一遍（并发去重在这里也生效）
    if (this.inflight.get(key) !== undefined) {
      return;
    }

    // 后台刷新的目的就是拿最新，必须 bypass
    this.fetchShared(name, true, timeoutMs)
      .then((fresh: DataSet) => {
        if (onUpdate !== undefined && fresh.generatedAt !== oldGeneratedAt) {
          // 与 load() 相同的三段断言：DataSet 是结构基线，由调用方断言成具体 payload
          onUpdate(fresh as Object as T);
        }
      })
      .catch((e: Error) => {
        // 静默：只在日志里留一笔，绝不向上抛
        const msg: string = e !== undefined && e !== null ? e.message : '';
        hilog.info(DOMAIN, TAG, '后台刷新失败 %{public}s %{public}s', key, msg);
      });
  }

  /** 分片真正拉取：分片只进内存 */
  private async fetchChunk(name: 'gallery' | 'satellites', index: number): Promise<Object[]> {
    const rel: string = chunkFile(name, index);
    const url: string = CDN_BASE + '/' + rel + '?t=' + Math.floor(Date.now() / HOUR);
    const text: string = await getText(url);
    const body: DataSet = JSON.parse(text) as DataSet;
    const list: Object[] | undefined = body !== null && body !== undefined ? body.list : undefined;
    const safe: Object[] = list !== undefined && Array.isArray(list) ? list : [];
    this.chunkMemory.set(String(name) + '#' + index, safe);
    return safe;
  }

  // ============ 小工具 ============

  private toChunk<T>(index: number, count: number, d: DataSet | undefined): ChunkResult<T> {
    const list: Object[] = d !== undefined && d.list !== undefined ? d.list : [];
    const chunks: number = d !== undefined && d.chunks !== undefined ? d.chunks : 1;
    const chunkSize: number = d !== undefined && d.chunkSize !== undefined ? d.chunkSize : 0;
    const total: number = d !== undefined && d.total !== undefined ? d.total : count;
    // 最后一片：索引号到达 chunks-1，或已覆盖 total 条
    const end: boolean =
      index >= chunks - 1 || (total > 0 && chunkSize > 0 && index * chunkSize + list.length >= total);
    const result: ChunkResult<T> = {
      index: index,
      list: list as Object as T[],
      chunks: chunks,
      chunkSize: chunkSize,
      end: end
    };
    return result;
  }

  /**
   * 就地补兜底值（**不是**重建对象）。
   *
   * 对应原项目 decorate()：原版用 Object.assign 以原始数据打底、只覆盖需要改写的字段，
   * 就是因为白名单式重建会静默丢新字段。这里连 assign 都不需要 ——
   * 解析结果本身就是完整对象，只需把缺失的几个展示字段填上默认值。
   */
  private fillDefaults(data: DataSet): void {
    if (data.count === undefined) {
      if (data.total !== undefined) {
        data.count = data.total;
      } else if (data.list !== undefined) {
        data.count = data.list.length;
      } else {
        data.count = 0;
      }
    }
    if (data.served === undefined) {
      data.served = data.list !== undefined ? data.list.length : 0;
    }
    if (data.generatedAt === undefined) {
      data.generatedAt = '';
    }
    if (data.chunks === undefined) {
      data.chunks = 1;
    }
    if (data.chunkSize === undefined) {
      data.chunkSize = 0;
    }
    if (data.launchTotal === undefined) {
      data.launchTotal = 0;
    }
    if (data.total === undefined) {
      data.total = 0;
    }
    if (data.byState === undefined) {
      data.byState = [];
    }
    if (data.byOrbit === undefined) {
      data.byOrbit = [];
    }
    if (data.byClass === undefined) {
      data.byClass = [];
    }
    if (data.byDecade === undefined) {
      data.byDecade = [];
    }
    if (data.breakupCount === undefined) {
      data.breakupCount = 0;
    }
  }

  /** 软 TTL：优先用 Dataset 的 getSoftTTL()，取不到回退 SOFT_TTL Map，再回退 15 分钟 */
  private softTtlOf(name: DatasetName): number {
    const fromMap: number | undefined = SOFT_TTL.get(name);
    if (fromMap !== undefined && fromMap > 0) {
      return fromMap;
    }
    const fallback: number = getSoftTTL(name);
    return fallback > 0 ? fallback : 15 * MINUTE;
  }

  private hardTtlOf(name: DatasetName): number {
    const key: string = String(name);
    for (let i = 0; i < HARD_TTL_KEYS.length; i++) {
      if (HARD_TTL_KEYS[i] === key) {
        return HARD_TTL_VALUES[i];
      }
    }
    return HARD_TTL_DEFAULT;
  }

  /**
   * 每日类数据集是否到点校验。5 分钟内不重复请求，
   * 既不刷爆流量又能及时跟上线上数据（对应 shouldRecheck）。
   */
  private shouldRecheck(name: DatasetName): boolean {
    const key: string = String(name);
    if (!DAILY_REVALIDATE.has(key)) {
      return false;
    }
    const gap: number = this.recheckGapOf(key);
    const last: number | undefined = this.lastRecheck.get(key);
    if (last !== undefined && Date.now() - last < gap) {
      return false;
    }
    this.lastRecheck.set(key, Date.now());
    return true;
  }

  private recheckGapOf(key: string): number {
    for (let i = 0; i < REVALIDATE_GAP_KEYS.length; i++) {
      if (REVALIDATE_GAP_KEYS[i] === key) {
        return REVALIDATE_GAP_VALUES[i];
      }
    }
    return 5 * MINUTE;
  }
}

/** 全局单例 */
export const repo: Repository = new Repository();
