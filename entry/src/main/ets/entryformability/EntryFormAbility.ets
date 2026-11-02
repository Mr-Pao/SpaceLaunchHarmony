/**
 * entryformability/EntryFormAbility.ets —— 服务卡片（Form Kit）的 FormExtensionAbility
 *
 * 两张卡片共用一个 FormExtensionAbility：
 *   next_launch  (2*2)  下次发射倒计时
 *   today_image  (2*4)  今日一图（APOD）
 *
 * 数据流（与 App 内页面完全一致，不另开一条数据通道）：
 *   onAddForm    → 同步读三级缓存（repo.peek 只碰 L1 内存 + L2 文件，绝不发网络），
 *                  拿不到就给占位值 → 桌面第一帧立刻有内容，不等网络
 *   onUpdateForm → repo.load('upcoming') + repo.load('apod')，
 *                  命中缓存时是同步快的；有更新就在后台静默刷新，
 *                  组装成同一份 LocalStorage → formProvider.updateForm 推回卡片
 *
 * 为什么更新时把两张卡片的键一次性都写进 bindingData：
 *   FormExtensionAbility 在 onUpdateForm 里拿不到「这次更新的是哪一张卡」，
 *   getFormsInfo 又要多一次异步调用；两张卡各自只读自己的键，
 *   多带 3 个字符串没有代价，胜在逻辑只有一条。
 *
 * 为什么数据容器用 class 而不是 Record：
 *   ArkTS 里 `Record<K,V>` 只是类型别名，不能 `new Record<...>()`
 *   （编译报 10505001 'Record' only refers to a type），也禁止索引签名。
 *   固定字段的 class 实例既能被 createFormBindingData 序列化，
 *   又完全不需要动态下标。
 *
 * 禁用清单（FormExtensionAbility 内不可用，import 了会编译过、运行崩）：
 *   particleAbility、@ohos.multimedia.audio、camera、media、backgroundTaskManager
 */

import { formBindingData, FormExtensionAbility, formProvider, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';

import { repo } from '../data/Repository';
import { fileStore } from '../data/FileStore';
import { DATA_VERSION } from '../constants/Dataset';
import { countdownParts, missionLabelOf, formatLaunchTime, strOf } from '../utils/Format';
import { UpcomingPayload } from '../model/Launch';
import { ApodPayload, ApodItem } from '../model/Apod';
import { LaunchSummary } from '../model/Common';

const DOMAIN: number = 0x0001;
const TAG: string = 'EntryFormAbility';

/** 卡片名（与 form_config.json 的 name 一一对应） */
const FORM_NAME_NEXT: string = 'next_launch';

/** 卡片被删除后 updateForm 会报这个错误码，属正常现象，静默忽略 */
const ERR_FORM_NOT_FOUND: number = 16501001;

/** want 里系统传的卡片名字段 */
const WANT_FORM_NAME: string = 'ohos.extra.param.key.form_name';

/** 本地图片缓存最多保留几张（APOD 每天换 URL，不清理会无限增长） */
const MAX_CACHED: number = 4;

/** 清理缓存时用的排序条目 */
class CacheEntry {
  path: string = '';
  mtimeMs: number = 0;

  constructor(path: string, mtimeMs: number) {
    this.path = path;
    this.mtimeMs = mtimeMs;
  }
}

/**
 * 卡片数据的完整形状 —— 两张卡的键合并成一份。
 *
 * 键名必须与卡片页的 @LocalStorageProp('xxx') 字符串**逐字一致**，
 * 改名要两边一起改（编译器不会跨 HAP 检查这个约定）。
 */
class CardData {
  // ---- next_launch ----
  mission: string = '—';
  dd: string = '--';
  hh: string = '--';
  mm: string = '--';
  stamp: string = '';
  status: string = '等待数据';
  // ---- today_image ----
  imgTitle: string = '今日一图';
  imgDate: string = '';
  /**
   * 图片地址（远程 URL）。
   *
   * 只给 Ability 内部算缓存文件名 / 判断要不要下载用，**从不直接下发给卡片**。
   * 卡片端的 @LocalStorageProp('img') 由 formImages 注入，两者不要混用。
   */
  imgUrl: string = '';
  /**
   * 卡片端 Image(this.img) 读的键。
   *
   * 这里必须是空字符串：Form Kit 在处理 bindingData 时，会用 formImages 里
   * 同名 key 对应的 fd 去解析真实图片，再覆盖这个字段。若这里塞了本地路径，
   * 系统会把它当 URL 再去加载，反而失败。
   */
  img: string = '';
}

/**
 * formImages 的键值对容器。
 *
 * 官方约定的最终形状是 {'formImages': {'img': fd}}；ArkTS 禁索引签名、
 * 禁无类型对象字面量，所以只能用一个只有一个字段的 class 来表示。
 */
class FormImages {
  img: number = 0;
}

/**
 * 带图片的 bindingData 形状 = CardData 全部字段 + formImages。
 *
 * 为什么要单独一个 class 而不是给 CardData 加 `formImages?: FormImages`：
 * 可选字段序列化后是 undefined，createFormBindingData 的行为没有文档保证；
 * 用独立 class 可以做到「有图才带 formImages」，两张卡片共用一条更新链路时
 * 也不会互相污染。
 */
class CardDataWithImage {
  mission: string = '—';
  dd: string = '--';
  hh: string = '--';
  mm: string = '--';
  stamp: string = '';
  status: string = '等待数据';
  imgTitle: string = '今日一图';
  imgDate: string = '';
  img: string = '';
  formImages: FormImages = new FormImages();

  /** 把基础数据搬进来（字段是固定集合，不需要动态遍历） */
  copyFrom(src: CardData): void {
    this.mission = src.mission;
    this.dd = src.dd;
    this.hh = src.hh;
    this.mm = src.mm;
    this.stamp = src.stamp;
    this.status = src.status;
    this.imgTitle = src.imgTitle;
    this.imgDate = src.imgDate;
    this.img = src.img;
  }
}

export default class EntryFormAbility extends FormExtensionAbility {
  /** 数据层是否已初始化（FormExtensionAbility 的 context 不是 UIAbilityContext） */
  private storeReady: boolean = false;

  /**
   * 初始化 L2 文件缓存。
   *
   * 必须做：Repository 的所有缓存都落在 filesDir 下，未 init 时 FileStore 是
   * ready=false，peek() 永远拿到 null、load() 每次都回源 —— 卡片就退化成
   * 「每次更新都要等一次完整网络请求」，桌面会一直转圈。
   */
  private ensureStore(): void {
    if (this.storeReady) {
      return;
    }
    try {
      fileStore.init(this.context, DATA_VERSION);
      this.storeReady = true;
    } catch (e) {
      this.storeReady = false;
      hilog.warn(DOMAIN, TAG, 'fileStore init failed: %{public}s', JSON.stringify(e));
    }
  }

  /** 从 want 里取卡片名，取不到就当「下次发射」 */
  private formNameOf(want: Want): string {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined || params === null) {
      return FORM_NAME_NEXT;
    }
    const raw: Object | undefined = params[WANT_FORM_NAME];
    const name: string = raw === undefined || raw === null ? '' : String(raw);
    return name.length > 0 ? name : FORM_NAME_NEXT;
  }

  // ============ 数据组装 ============

  /**
   * 下次发射：同步读缓存拼出卡片所需字段。
   * 缓存未命中就返回占位值，绝不在这里发网络请求（onAddForm 有超时预算）。
   */
  private fillNextLaunch(data: CardData): void {
    data.mission = '—';
    data.dd = '--';
    data.hh = '--';
    data.mm = '--';
    data.stamp = '';
    data.status = '等待数据';

    const payload: UpcomingPayload | null = repo.peek<UpcomingPayload>('upcoming');
    if (payload === null || payload === undefined) {
      return;
    }
    const list: LaunchSummary[] = payload.list;
    if (list === undefined || list.length === 0) {
      return;
    }
    this.applyNextLaunch(data, this.soonestOf(list));
  }

  private applyNextLaunch(data: CardData, item: LaunchSummary): void {
    const iso: string = strOf(item.net);
    const parts = countdownParts(iso);
    data.mission = missionLabelOf(item);
    data.dd = parts.days;
    data.hh = parts.hours;
    data.mm = parts.mins;
    data.stamp = formatLaunchTime(iso);
    data.status = parts.ended ? '时间已到' : '距离发射';
  }

  /**
   * 取最近的一条。
   *
   * 不用 compareByNet 排序整表：upcoming 有 100 条，每次更新都 sort 一遍
   * 没必要；线性扫一遍找最小即可，且对 net 缺失的记录免疫（时间解析失败跳过）。
   */
  private soonestOf(list: LaunchSummary[]): LaunchSummary {
    let best: LaunchSummary = list[0];
    let bestT: number = this.netTimeOf(best);
    for (let i = 1; i < list.length; i++) {
      const t: number = this.netTimeOf(list[i]);
      if (t > 0 && (bestT <= 0 || t < bestT)) {
        best = list[i];
        bestT = t;
      }
    }
    return best;
  }

  private netTimeOf(item: LaunchSummary): number {
    const iso: string = strOf(item.net);
    if (iso.length === 0) {
      return 0;
    }
    const ms: number = new Date(iso).getTime();
    return isNaN(ms) ? 0 : ms;
  }

  /** 今日一图：同样只读缓存 */
  private fillImage(data: CardData): void {
    data.imgTitle = '今日一图';
    data.imgDate = '';
    data.imgUrl = '';

    const payload: ApodPayload | null = repo.peek<ApodPayload>('apod');
    if (payload === null || payload === undefined) {
      return;
    }
    const list: ApodItem[] = payload.list;
    if (list === undefined || list.length === 0) {
      return;
    }
    this.applyImage(data, list[0]);
  }

  private applyImage(data: CardData, item: ApodItem): void {
    const zh: string = strOf(item.titleZh);
    const en: string = strOf(item.title);
    const title: string = zh.length > 0 ? zh : en;
    const full: string = strOf(item.full).length > 0 ? strOf(item.full) : strOf(item.thumb);
    data.imgTitle = title.length > 0 ? title : '今日一图';
    data.imgDate = strOf(item.date);
    data.imgUrl = full;
  }

  /** 一次性组装两张卡的数据（同步、只读缓存） */
  private collectSync(): CardData {
    const data: CardData = new CardData();
    this.fillNextLaunch(data);
    this.fillImage(data);
    return data;
  }

  // ============ 卡片图片：下载 → 本地文件 → fd ============

  /**
   * 图片缓存目录：<filesDir>/formImg/
   *
   * 为什么必须落本地文件：Form Kit 的卡片进程**没有网络访问能力**，
   * Image(远程URL) 在卡片里恒为黑块（2026-11-02 桌面实测确认）。
   * 官方通路是 formImages + 文件描述符，卡片进程只读 fd 指向的本地文件。
   */
  private imageDir(): string {
    const dir: string = this.context.filesDir + '/formImg';
    // 直接 mkdir：已存在会抛，吞掉即可。不先 accessSync 判断，是因为
    // 不同 SDK 小版本 accessSync 的返回值/抛异常行为不一致（见 data/FileStore.ets 的注释）。
    try {
      fs.mkdirSync(dir);
    } catch (e) {
      // 已存在（绝大多数情况）
    }
    return dir;
  }

  /**
   * URL → 文件名。用 djb2 取 32 位散列转 16 进制。
   *
   * 不用 crypto：图片 URL 只是缓存键，碰撞概率对几十个文件可以忽略，
   * 而 crypto 在 FormExtensionAbility 里是同步调用的阻塞项。
   */
  private hashOf(text: string): string {
    let h: number = 5381;
    for (let i = 0; i < text.length; i++) {
      // h * 33 + c，每步都收敛到 32 位，避免 JS 双精度丢精度后散列退化
      h = ((h * 33) ^ text.charCodeAt(i)) | 0;
    }
    // 取绝对值再转 36 进制，短且稳定
    return (h < 0 ? -h : h).toString(36);
  }

  private cachePathOf(url: string): string {
    return this.imageDir() + '/' + this.hashOf(url) + '.img';
  }

  /**
   * 文件是否真的存在。
   *
   * ⚠️ 必须消费 accessSync 的**返回值**，不能只靠 try/catch：
   * 当前 SDK 的签名是 `declare function accessSync(path: string, mode?: AccessModeType): boolean;`
   * —— 文件不存在时**返回 false 而不是抛异常**。只写 try/catch 会把「不存在」判成「存在」，
   * 于是 downloadTo 直接返回一个没写过的路径、cachedFdOf 去 open 一个不存在的文件拿到 -1，
   * 最终卡片永远 image=false（2026-11-02 实测踩中，排查了很久）。
   * 同时兼容「不存在时抛 BusinessError」的旧实现：抛了就按 false 处理。
   */
  private fileExists(path: string): boolean {
    let ok: boolean = false;
    try {
      ok = fs.accessSync(path) === true;
    } catch (e) {
      ok = false;
    }
    return ok;
  }

  /**
   * 打开缓存文件拿 fd。
   *
   * @returns fd，文件不存在或打不开时返回 -1
   *   （不用 0 作哨兵：0 是合法 fd）
   */
  private cachedFdOf(url: string): number {
    if (url.length === 0) {
      return -1;
    }
    const path: string = this.cachePathOf(url);
    if (!this.fileExists(path)) {
      hilog.info(DOMAIN, TAG, 'fd: no cache %{public}s', path);
      return -1;
    }
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      hilog.info(DOMAIN, TAG, 'fd: open ok %{public}s fd=%{public}d', path, file.fd);
      return file.fd;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'fd: open fail %{public}s %{public}s', path, err.message);
      return -1;
    }
  }

  private closeFd(fd: number): void {
    if (fd < 0) {
      return;
    }
    try {
      // closeSync 的签名是 `file: number | File`，传裸 fd 即可，
      // 不要手搓 File 对象字面量（File 上还有 getParent/lock/tryLock/unlock，补齐才能过编译）
      fs.closeSync(fd);
    } catch (e) {
      // 关不掉不影响本次渲染，下次 updateForm 会重新 open
    }
  }

  /**
   * 下载图片字节并落盘，返回缓存文件路径（失败返回空串）。
   *
   * 用 @kit.NetworkKit 的 http，**必须** expectDataType=ARRAY_BUFFER：
   * 默认按 STRING 解，JPEG 二进制会被当 UTF-8 解码成乱码字符串，写出去的文件打不开。
   * 项目里的 api/HttpClient.ets 只封装了 getText，这里不能复用。
   */
  private async downloadTo(url: string): Promise<string> {
    const path: string = this.cachePathOf(url);
    // 已有同 URL 的缓存直接复用，不重复下载（必须看返回值，见 fileExists 的注释）
    if (this.fileExists(path)) {
      hilog.info(DOMAIN, TAG, 'image cache hit: %{public}s', path);
      return path;
    }

    const req: http.HttpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 20000,
        usingCache: true
      });
      if (resp.responseCode !== 200) {
        hilog.warn(DOMAIN, TAG, 'image http %{public}d: %{public}s', resp.responseCode, url);
        return '';
      }
      // HttpResponse.result 的声明类型是 string | Object | ArrayBuffer，
      // ArkTS 不允许把它直接赋给 ArrayBuffer | string（Object 无法收窄），
      // 所以先用 Object 接住，再用 instanceof 判定成 ArrayBuffer。
      const raw: Object = resp.result;
      if (!(raw instanceof ArrayBuffer)) {
        hilog.warn(DOMAIN, TAG, 'image body not arraybuffer');
        return '';
      }
      const body: ArrayBuffer = raw;
      if (!this.writeFileSync(path, body)) {
        return '';
      }
      this.pruneCache();
      return path;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'download image failed: %{public}s', err.message);
      return '';
    } finally {
      // HttpRequest 持有 socket，必须显式 destroy，否则卡片刷新几次就泄漏
      try {
        req.destroy();
      } catch (e2) {
        // destroy 失败无需处理
      }
    }
  }

  private writeFileSync(path: string, buf: ArrayBuffer): boolean {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, buf);
      return true;
    } catch (e) {
      // 写失败就把半截文件删掉，免得下次 accessSync 命中脏文件
      try {
        fs.unlinkSync(path);
      } catch (e2) {
        // 删不掉也无妨
      }
      return false;
    } finally {
      if (file !== null) {
        try {
          fs.closeSync(file);
        } catch (e3) {
          // 忽略
        }
      }
    }
  }

  /**
   * 缓存清理：最多留 MAX_CACHED 张，按修改时间从旧到新删。
   *
   * 卡片只显示今天这一张，但 APOD 每天换 URL —— 不清理的话 filesDir
   * 会随天数无限增长（每张 200KB~2MB）。留 4 张足够覆盖「昨天/今天来回切」。
   */
  private pruneCache(): void {
    try {
      const dir: string = this.imageDir();
      const names: string[] = fs.listFileSync(dir);
      if (names.length <= MAX_CACHED) {
        return;
      }
      const entries: CacheEntry[] = [];
      for (let i = 0; i < names.length; i++) {
        const full: string = dir + '/' + names[i];
        try {
          const st: fs.Stat = fs.statSync(full);
          entries.push(new CacheEntry(full, st.mtime * 1000));
        } catch (e) {
          // 单个文件 stat 失败跳过
        }
      }
      entries.sort((a: CacheEntry, b: CacheEntry) => a.mtimeMs - b.mtimeMs);
      const removeCount: number = entries.length - MAX_CACHED;
      for (let i = 0; i < removeCount; i++) {
        try {
          fs.unlinkSync(entries[i].path);
        } catch (e) {
          // 忽略
        }
      }
    } catch (e) {
      // 清理是尽力而为，失败不影响出图
    }
  }

  /** 把 data 连同（可能有的）图片 fd 一起推给卡片 */
  private async pushToForm(formId: string, data: CardData): Promise<void> {
    let fd: number = this.cachedFdOf(data.imgUrl);
    const hasImage: boolean = fd >= 0;
    let binding: formBindingData.FormBindingData;
    if (hasImage) {
      const payload: CardDataWithImage = new CardDataWithImage();
      payload.copyFrom(data);
      payload.formImages.img = fd;
      binding = formBindingData.createFormBindingData(payload);
    } else {
      // 没图也要推：标题/日期/倒计时仍要走这条链路更新
      binding = formBindingData.createFormBindingData(data);
    }

    try {
      await formProvider.updateForm(formId, binding);
      hilog.info(DOMAIN, TAG, 'form updated: %{public}s image=%{public}s', formId, String(hasImage));
    } catch (e) {
      // 卡片被删时这里是 16501001，属正常路径，静默
      const err: BusinessError = e as BusinessError;
      if (err.code !== ERR_FORM_NOT_FOUND) {
        hilog.warn(DOMAIN, TAG, 'updateForm failed: %{public}s', JSON.stringify(err));
      }
    } finally {
      if (hasImage) {
        this.closeFd(fd);
      }
    }
  }

  // ============ 生命周期 ============

  /**
   * 卡片被添加到桌面。
   *
   * 必须**同步**返回 FormBindingData：系统对 onAddForm 有超时预算，
   * 一旦 await 网络就可能超时导致「卡片添加失败」。所以这里只读缓存，
   * 真正的数据由随后系统触发的 onUpdateForm 补齐。
   */
  onAddForm(want: Want): formBindingData.FormBindingData {
    this.ensureStore();
    const name: string = this.formNameOf(want);
    hilog.info(DOMAIN, TAG, 'onAddForm: %{public}s', name);

    const data: CardData = this.collectSync();

    // 有图就立刻用缓存里的 fd 顶上去（同步，不等网络）；
    // 缓存没有则先给无图占位，由下面的 downloadAndPush 补齐。
    const fd: number = this.cachedFdOf(data.imgUrl);
    let binding: formBindingData.FormBindingData;
    if (fd >= 0) {
      const payload: CardDataWithImage = new CardDataWithImage();
      payload.copyFrom(data);
      payload.formImages.img = fd;
      binding = formBindingData.createFormBindingData(payload);
      // ⚠ fd 不能在返回前 close：系统是在拿到 bindingData 之后才去读文件的
      // （关闭时机没有文档保证，交给下次更新时被新 fd 覆盖；
      //  卡片进程只读一次，泄漏 1 个 fd 的代价可以接受）
    } else {
      binding = formBindingData.createFormBindingData(data);
    }

    // fire-and-forget：onAddForm 必须同步返回，下载只能异步补推一次 updateForm。
    // formId 从 want 里取；取不到就跳过（卡片首帧已是占位，系统 updateDuration 会兜底）。
    const formId: string = this.formIdOf(want);
    if (formId.length > 0) {
      this.refreshAsync(formId).catch((err: BusinessError) => {
        if (err !== undefined && err !== null && err.code !== ERR_FORM_NOT_FOUND) {
          hilog.warn(DOMAIN, TAG, 'refreshAsync failed: %{public}s', JSON.stringify(err));
        }
      });
    }
    return binding;
  }

  /** want 里的 formId，取不到返回空串 */
  private formIdOf(want: Want): string {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined || params === null) {
      return '';
    }
    const raw: Object | undefined = params[formInfo.FormParam.IDENTITY_KEY];
    if (raw === undefined || raw === null) {
      return '';
    }
    const id: string = String(raw);
    return id.length > 0 ? id : '';
  }

  /**
   * 异步补图：下载 → 落盘 → 拿 fd → updateForm。
   *
   * 这是 onAddForm / onUpdateForm 共用的唯一刷新入口，
   * 两条路径行为一致，避免「加卡片」和「定时刷新」看到的图不一样。
   */
  private async refreshAsync(formId: string): Promise<void> {
    const data: CardData = new CardData();
    await this.loadNextLaunch(data);
    await this.loadImage(data);

    hilog.info(DOMAIN, TAG, 'refresh: imgUrl len=%{public}d title=%{public}s',
      data.imgUrl.length, data.imgTitle);
    if (data.imgUrl.length > 0) {
      // 下载失败返回空串，此时 pushToForm 会退化成「无图但文字更新」
      const saved: string = await this.downloadTo(data.imgUrl);
      hilog.info(DOMAIN, TAG, 'refresh: saved=%{public}s', saved);
    }
    await this.pushToForm(formId, data);
  }

  /**
   * 卡片定时 / 系统触发更新。
   *
   * updateDuration 单位是 30 分钟：两张卡分别是 30 / 60 分钟。
   * 命中缓存时 repo.load 是同步快的（L1/L2 直接 resolve），
   * 只有过期才在后台静默刷新，所以 await 不会拖长系统给的回调预算。
   */
  onUpdateForm(formId: string): void {
    this.ensureStore();
    this.refreshAsync(formId).catch((err: BusinessError) => {
      // 卡片已被删除 / 系统已回收时不打扰用户
      if (err !== undefined && err !== null && err.code !== ERR_FORM_NOT_FOUND) {
        hilog.warn(DOMAIN, TAG, 'refresh failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  private async loadNextLaunch(data: CardData): Promise<void> {
    try {
      const payload: UpcomingPayload = await repo.load<UpcomingPayload>('upcoming');
      const list: LaunchSummary[] = payload.list;
      if (list === undefined || list.length === 0) {
        this.fillNextLaunch(data);
        return;
      }
      this.applyNextLaunch(data, this.soonestOf(list));
    } catch (e) {
      // 弱网无缓存：退回缓存/占位值，卡片保持上一帧内容
      hilog.warn(DOMAIN, TAG, 'load upcoming failed');
      this.fillNextLaunch(data);
    }
  }

  private async loadImage(data: CardData): Promise<void> {
    try {
      const payload: ApodPayload = await repo.load<ApodPayload>('apod');
      const list: ApodItem[] = payload.list;
      if (list === undefined || list.length === 0) {
        this.fillImage(data);
        return;
      }
      this.applyImage(data, list[0]);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'load apod failed');
      this.fillImage(data);
    }
  }

  /** 临时卡片转正式卡片：不做额外处理 */
  onCastToNormalForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onCastToNormalForm: %{public}s', formId);
  }

  /** 可见性变化（桌面滑出/滑入）：不重拉，系统更新节奏足够 */
  onChangeFormVisibility(newStatus: Record<string, number>): void {
    hilog.info(DOMAIN, TAG, 'onChangeFormVisibility');
  }

  /**
   * 卡片上的自定义事件（postCardAction 的 action='message' 触发）。
   * 当前两张卡都用 action='router' 直接拉 App，没有自定义事件，留空实现。
   */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, 'onFormEvent: %{public}s %{public}s', formId, message);
  }

  /** 卡片被移除：无本地资源需要释放，留空实现（保留是为了将来可能的埋点） */
  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onRemoveForm: %{public}s', formId);
  }

  /** 查询卡片状态：READY 表示可正常添加 */
  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
