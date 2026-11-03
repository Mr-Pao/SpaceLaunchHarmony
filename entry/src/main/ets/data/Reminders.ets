/**
 * 发射提醒存储层 + 系统日历投递。
 *
 * 为什么用日历而不是代理提醒：
 *   先试的是 `reminderAgentManager.publishReminder`（系统代理提醒，到期直接弹通知，
 *   语义上更贴「发射前叫我一声」），但实测被拒：
 *     `Reminders: 发布系统提醒失败 code=1700002`
 *   官方错误码文档写明：**「因管控限制，普通应用如果没有代理提醒的使用权限，
 *   视为这个普通应用提醒数量上限为 0」**，要拿到该权限必须在 AGC 侧单独申请、
 *   且必须用**申请通过的正式签名 profile** 才生效 —— 那是发布准备阶段的事，
 *   不该卡住功能本身。
 *
 *   `CalendarKit`（`@kit.CalendarKit` → `@ohos.calendarManager`）对应小程序的
 *   `uni.addPhoneCalendar`，只需要 `ohos.permission.WRITE_CALENDAR` ——
 *   **user_grant、availableLevel=normal**，运行时弹一次授权框即可，不需要 AGC 审批。
 *   同一份数据在系统日历里也可见，对「发射前 30 分钟」这种一次性事件够用。
 *
 * 账号策略：不往用户现有日历里塞事件，而是建一个**本应用专属的日历账户**
 * （`name: 'SpaceLaunch'`、`type: CalendarType.LOCAL`）。好处有两个：
 *   1) 取消提醒有据可依 —— 只删自己账号下的事件，绝不误删用户的日程；
 *   2) 用户不爽可以整块删掉这个日历，不留痕迹。
 *
 * 存储：沿用小程序同名 key `reminded_launches`（id 字符串数组），另存
 * `reminded_ids` 记录 `launchId → 日历事件 id` 映射 —— 取消时只能拿事件 id 删。
 * 两份都放 preferences（几十条小键值，远低于单 value 8192 字节上限）。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
// PermissionRequestResult 是独立模块 security/PermissionRequestResult，
// 不在 abilityAccessCtrl 命名空间下 —— 从 @kit.AbilityKit 具名导入。
import { PermissionRequestResult } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { parseTime } from '../utils/Format';
import { FAV_VERSION_KEY } from './Favorites';

const DOMAIN: number = 0x0001;
const TAG: string = 'Reminders';

/** 与 Favorites.ets 同一个实例名，getPreferencesSync 按名返回同一个对象。 */
const PREF_NAME: string = 'spacelaunch_prefs';
/** 提醒清单的键名，与小程序 mine.vue 的 REMIND_KEY 完全一致。 */
const KEY_REMIND: string = 'reminded_launches';
/** launchId → 日历事件 id 的映射（JSON 数组）。 */
const KEY_REMIND_IDS: string = 'reminded_ids';

/** 本应用专属日历账户名。系统日历里会以此名显示一个日历。 */
const ACCOUNT_NAME: string = 'SpaceLaunch';
/** 账户显示名。 */
const ACCOUNT_DISPLAY: string = '航天发射提醒';
/** 日历配色（与主题青一致，0xFF 前缀 + RGB）。 */
const ACCOUNT_COLOR: number = 0xFF38BDF8;

/** 上限：纯本地保护，日历本身没有这么低的限制。 */
const MAX_REMIND: number = 60;

/** 提前多久提醒（分钟）。30 分钟是「够穿衣出门」与「不会忘」的折中。 */
const AHEAD_MIN: number = 30;

/** launchId 与日历事件 id 的配对。class 而非匿名对象：ArkTS 要求显式类型。 */
class ReminderPair {
  launchId: string = '';
  eventId: number = 0;

  constructor(launchId: string, eventId: number) {
    this.launchId = launchId;
    this.eventId = eventId;
  }
}

/** JSON.parse 的落点。字段可选，因为历史数据可能只存了其中一部分。 */
interface PairRaw {
  launchId?: string;
  eventId?: number;
}

/**
 * 一次提醒请求需要的最小信息。
 *
 * 传 class 而不是散参数：调用点在详情页要凑四项，位置化参数读不出含义。
 */
export class RemindTarget {
  id: string = '';
  net: string = '';
  title: string = '';
  rocketName: string = '';

  constructor(id: string, net: string, title: string, rocketName: string) {
    this.id = id;
    this.net = net;
    this.title = title;
    this.rocketName = rocketName;
  }
}

export class RemindStore {
  private prefs: preferences.Preferences | null = null;
  private ids: string[] = [];
  private pairs: ReminderPair[] = [];
  private loaded: boolean = false;

  /** 已创建的日历对象缓存（建账户是一次 IPC，不该每次点都建）。 */
  private cal: calendarManager.Calendar | null = null;
  /** 授权是否已确认（true 之后不再重复弹框）。 */
  private granted: boolean = false;

  init(ctx: common.Context): void {
    if (this.prefs !== null) {
      return;
    }
    try {
      const opt: preferences.Options = { name: PREF_NAME };
      this.prefs = preferences.getPreferencesSync(ctx, opt);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'preferences 打开失败，提醒功能降级为只读内存');
      this.prefs = null;
      return;
    }
    this.reload();
  }

  isReady(): boolean {
    return this.prefs !== null;
  }

  private reload(): void {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null || this.loaded) {
      return;
    }
    this.loaded = true;
    try {
      const raw: preferences.ValueType = p.getSync(KEY_REMIND, '');
      if (typeof raw === 'string' && raw.length > 0) {
        const arr: string[] = JSON.parse(raw) as string[];
        const out: string[] = [];
        for (let i = 0; i < arr.length; i++) {
          const id: string = typeof arr[i] === 'string' ? arr[i].trim() : '';
          if (id.length > 0) {
            out.push(id);
          }
        }
        this.ids = out;
      } else {
        this.ids = [];
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '提醒清单解析失败，按空列表处理');
      this.ids = [];
    }
    try {
      const raw: preferences.ValueType = p.getSync(KEY_REMIND_IDS, '');
      if (typeof raw === 'string' && raw.length > 0) {
        const arr: PairRaw[] = JSON.parse(raw) as PairRaw[];
        const out: ReminderPair[] = [];
        for (let i = 0; i < arr.length; i++) {
          const it: PairRaw = arr[i];
          const lid: string = typeof it.launchId === 'string' ? it.launchId : '';
          const eid: number = typeof it.eventId === 'number' ? it.eventId : 0;
          if (lid.length > 0) {
            out.push(new ReminderPair(lid, eid));
          }
        }
        this.pairs = out;
      } else {
        this.pairs = [];
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '提醒映射解析失败，按空列表处理');
      this.pairs = [];
    }
  }

  private persist(): void {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null) {
      bumpVersion();
      return;
    }
    try {
      p.putSync(KEY_REMIND, JSON.stringify(this.ids));
      p.putSync(KEY_REMIND_IDS, JSON.stringify(this.pairs));
      p.flushSync();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, '提醒写入失败，本条仅存在于内存');
    }
    // 落盘成败都广播：内存里已经变了，界面就该跟着变。
    bumpVersion();
  }

  list(): string[] {
    this.reload();
    return this.ids.slice();
  }

  count(): number {
    this.reload();
    return this.ids.length;
  }

  has(launchId: string): boolean {
    this.reload();
    return this.ids.indexOf(launchId) !== -1;
  }

  private eventIdOf(launchId: string): number {
    for (let i = 0; i < this.pairs.length; i++) {
      if (this.pairs[i].launchId === launchId) {
        return this.pairs[i].eventId;
      }
    }
    return 0;
  }

  private setPair(launchId: string, eventId: number): void {
    const next: ReminderPair[] = [];
    for (let i = 0; i < this.pairs.length; i++) {
      if (this.pairs[i].launchId !== launchId) {
        next.push(this.pairs[i]);
      }
    }
    next.push(new ReminderPair(launchId, eventId));
    this.pairs = next;
  }

  private dropPair(launchId: string): number {
    const removed: number = this.eventIdOf(launchId);
    const next: ReminderPair[] = [];
    for (let i = 0; i < this.pairs.length; i++) {
      if (this.pairs[i].launchId !== launchId) {
        next.push(this.pairs[i]);
      }
    }
    this.pairs = next;
    return removed;
  }

  /**
   * 申请日历写入权限。已授权过就直接返回 true，不重复弹框。
   *
   * `WRITE_CALENDAR` 是 user_grant：第一次调用会弹系统授权框。
   * 用户拒绝时返回 false —— 调用方据此 toast，而不是静默失败。
   */
  private async ensurePermission(ctx: common.Context): Promise<boolean> {
    if (this.granted) {
      return true;
    }
    try {
      const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      // 两个都要：getCalendar 查读权限、addEvent/deleteEvent 查写权限。
      // 只申 WRITE 会在 getCalendar 处报 201（实测）。
      const perms: Permissions[] =
        ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
      const res: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(ctx, perms);
      const results: number[] = res.authResults;
      for (let i = 0; i < results.length; i++) {
        if (results[i] === 0) {
          this.granted = true;
          return true;
        }
      }
      hilog.warn(DOMAIN, TAG, '日历写入权限未授予');
      return false;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '申请日历权限失败 code=%{public}d', err.code);
      return false;
    }
  }

  /**
   * 拿到本应用专属的日历。
   *
   * **`getCalendar(account)` 不会自动建账户** —— 实测首次调用报
   * `23900003 The specified account was not found`。要先 `createCalendar(account)`。
   * 反过来直接 create 也不行：账户已存在时会报错。所以是
   * 「先取 → 取不到再建」两段式，而不是注释里曾误写的「取或建」。
   *
   * 两个调用查的权限不同：getCalendar 要 READ_CALENDAR、createCalendar 要
   * WRITE_CALENDAR —— 都已在 module.json5 声明，缺一个就是 code=201。
   */
  private async calendarOf(ctx: common.Context): Promise<calendarManager.Calendar | null> {
    if (this.cal !== null) {
      return this.cal;
    }
    const account: calendarManager.CalendarAccount = {
      name: ACCOUNT_NAME,
      type: calendarManager.CalendarType.LOCAL,
      displayName: ACCOUNT_DISPLAY
    };
    let mgr: calendarManager.CalendarManager | null = null;
    try {
      mgr = calendarManager.getCalendarManager(ctx);
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '获取日历管理器失败 code=%{public}d', err.code);
      return null;
    }
    // 第一段：账户已存在（用户之前点过提醒）→ 直接拿到。
    try {
      const cal: calendarManager.Calendar = await mgr.getCalendar(account);
      this.cal = cal;
      return cal;
    } catch (e) {
      const err = e as BusinessError;
      // 23900003 = 账户不存在，属于预期分支，走下面新建。其余错误照样新建一次，
      // 因为日历数据有可能被用户清理过，把「找不到」以外的失败也当「没有」处理
      // 不会造成数据损坏（create 是幂等的：已存在会再报错，届时返回 null）。
      hilog.info(DOMAIN, TAG, '账户不存在或无读权限 code=%{public}d，尝试新建', err.code);
    }
    // 第二段：新建本应用专属日历。
    try {
      const cal: calendarManager.Calendar = await mgr.createCalendar(account);
      this.cal = cal;
      return cal;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '新建应用日历失败 code=%{public}d', err.code);
      return null;
    }
  }

  /**
   * 取消一条提醒。返回 true 表示清单里原本有它。
   *
   * deleteEvent 失败只记日志：事件可能已被用户从日历里手动删掉，
   * 但这**不该拦住本地清单的清理** —— 否则用户会卡在「界面显示已提醒、
   * 实际什么都没有」的状态里，比直接删掉更糟。
   */
  async remove(launchId: string): Promise<boolean> {
    this.reload();
    const idx: number = this.ids.indexOf(launchId);
    if (idx === -1) {
      return false;
    }
    const ids: string[] = this.ids.slice();
    ids.splice(idx, 1);
    this.ids = ids;
    const eid: number = this.dropPair(launchId);
    if (eid > 0 && this.cal !== null) {
      try {
        await this.cal.deleteEvent(eid);
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, '删除日历事件失败 code=%{public}d（本地已清理）', err.code);
      }
    }
    this.persist();
    return true;
  }

  /**
   * 添加一条提醒。返回 true 表示成功。
   *
   * 事件的开始时刻就用**发射时刻本身**，提醒偏移交给 `reminderTime: [30]`
   * （系统按「事件开始前 N 分钟」触发）—— 与小程序 addPhoneCalendar 的
   * `alarm: true` + `alarmOffset` 是同一套语义，比我们自己算「提前 30 分钟
   * 作为事件开始时间」更准确：日历里看到的就是发射时间。
   *
   * 发射时刻已过（或不足 1 分钟）时，事件放「1 分钟后」并取消提醒偏移 ——
   * 用户点提醒时发射可能就在眼前，直接失败比晚一分钟更糟。
   */
  async add(ctx: common.Context, target: RemindTarget): Promise<boolean> {
    this.reload();
    if (target.id.length === 0) {
      return false;
    }
    if (this.ids.length >= MAX_REMIND) {
      hilog.warn(DOMAIN, TAG, '提醒数量已达上限 %{public}d', MAX_REMIND);
      return false;
    }
    const ok: boolean = await this.ensurePermission(ctx);
    if (!ok) {
      return false;
    }
    const cal: calendarManager.Calendar | null = await this.calendarOf(ctx);
    if (cal === null) {
      return false;
    }
    const start: number = this.startOf(target.net);
    const soon: boolean = start - Date.now() < 60 * 1000;
    // 事件持续 30 分钟：CAL 的 endTime 必须 > startTime，给 0 时长会被拒。
    const event: calendarManager.Event = {
      type: calendarManager.EventType.NORMAL,
      title: target.title.length > 0 ? ('发射：' + target.title) : '航天发射',
      description: this.descOf(target),
      startTime: start,
      endTime: start + 30 * 60 * 1000,
      // 提前 30 分钟通知；已过点则不留提醒（事件本身仍记着）。
      reminderTime: soon ? [] : [AHEAD_MIN]
    };
    try {
      const eid: number = await cal.addEvent(event);
      const next: string[] = this.ids.slice();
      next.unshift(target.id);
      this.ids = next;
      this.setPair(target.id, eid);
      this.persist();
      return true;
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '写入日历事件失败 code=%{public}d', err.code);
      return false;
    }
  }

  /**
   * 切换。返回切换后的状态（true = 已提醒）。
   *
   * ctx 由调用方传：只有 View 拿得到 UIContext 上的 HostContext，
   * 存储层不该自己去猜。
   */
  async toggle(ctx: common.Context, target: RemindTarget): Promise<boolean> {
    this.reload();
    if (this.has(target.id)) {
      await this.remove(target.id);
      return false;
    }
    const ok: boolean = await this.add(ctx, target);
    return ok;
  }

  /** 事件描述：火箭型号 + 数据来源，方便用户在日历里辨认。 */
  private descOf(target: RemindTarget): string {
    const parts: string[] = [];
    if (target.rocketName.length > 0) {
      parts.push(target.rocketName);
    }
    parts.push('由「航天发射」App 添加');
    return parts.join(' · ');
  }

  /**
   * 事件开始时刻（毫秒）。取发射时刻；已过点则退到 1 分钟后。
   *
   * 注意与代理提醒版的差别：那边减的是 AHEAD_MS（提醒时刻 = 发射前 30 分钟），
   * 这边事件本身就要落在发射时刻，提前量交给 reminderTime。
   */
  private startOf(net: string): number {
    const at: number = parseTime(net);
    const floor: number = Date.now() + 60 * 1000;
    return at > floor ? at : floor;
  }
}

/** 全局单例。 */
export const reminders: RemindStore = new RemindStore();

/** 递增全局版本号，让「我的」页重读清单。 */
function bumpVersion(): void {
  const cur: number | undefined = AppStorage.get<number>(FAV_VERSION_KEY);
  const base: number = cur === undefined ? 0 : cur;
  AppStorage.setOrCreate(FAV_VERSION_KEY, base + 1);
}

export function remindInit(ctx: common.Context): void {
  reminders.init(ctx);
}

export function remindList(): string[] {
  return reminders.list();
}

export function remindCount(): number {
  return reminders.count();
}

export function remindHas(id: string): boolean {
  return reminders.has(id);
}

export function remindToggle(ctx: common.Context, target: RemindTarget): Promise<boolean> {
  return reminders.toggle(ctx, target);
}

export function remindRemove(id: string): Promise<boolean> {
  return reminders.remove(id);
}
