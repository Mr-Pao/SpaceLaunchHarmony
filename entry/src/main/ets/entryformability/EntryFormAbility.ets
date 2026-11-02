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
  imgUrl: string = '';
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
    hilog.info(DOMAIN, TAG, 'onAddForm: %{public}s', this.formNameOf(want));
    const data: CardData = this.collectSync();
    return formBindingData.createFormBindingData(data);
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
    this.refresh(formId).catch((err: BusinessError) => {
      // 卡片已被删除 / 系统已回收时不打扰用户
      if (err !== undefined && err !== null && err.code !== ERR_FORM_NOT_FOUND) {
        hilog.warn(DOMAIN, TAG, 'refresh failed: %{public}s', JSON.stringify(err));
      }
    });
  }

  private async refresh(formId: string): Promise<void> {
    const data: CardData = new CardData();
    await this.loadNextLaunch(data);
    await this.loadImage(data);

    try {
      await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
      hilog.info(DOMAIN, TAG, 'form updated: %{public}s', formId);
    } catch (e) {
      // 卡片被删时这里是 16501001，属正常路径，静默
      const err: BusinessError = e as BusinessError;
      if (err.code !== ERR_FORM_NOT_FOUND) {
        hilog.warn(DOMAIN, TAG, 'updateForm failed: %{public}s', JSON.stringify(err));
      }
    }
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
