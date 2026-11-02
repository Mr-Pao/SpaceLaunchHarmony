/**
 * view/EventDetailView.ets —— 活动详情页（对位小程序 pages/event/eventInfo.vue，345 行）
 *
 * ── 契约 ──
 *   @Component export struct EventDetailView { @Prop eventId: string = ''; }
 *   一个回调由父级（路由容器）注入，本页不直接跳转：
 *     onOpenLaunch(id: string, net: string, title: string)
 *
 * ── 数据来源 events.json（2026-11-03 实测 v=14 / count=26）──
 *   id / name / nameZh / date / description / descriptionZh / feature_image /
 *   type / location / launches[]
 *   · type、location 是**联合类型** EvRef | string | null —— 上游有时给对象有时给字符串，
 *     一律用 model/Event.ets 的 evRefName() 读名字，别自己判 typeof。
 *   · description / descriptionZh **含 \r\n**（上游正文带硬换行），不压平会被 Text
 *     当成段落切成一堆碎行，所以渲染前统一 split/join 成空格。
 *   · feature_image 可能 null 也可能空串 → 两种都按「没有图」处理，画 emoji 占位。
 *
 * ── 为什么本文件不新建类型 ──
 *   events 的字段已经全在 model/Event.ets 里（EvItem / EvPayload / EvLaunchRef），
 *   再声明一份 interface 只会触发 ArkTS 的声明合并风险（同名 interface 跨文件合并）。
 *   所以这里**不声明任何新类型**；若将来要加，前缀必须是 Evd（任务书约定，避合并）。
 *
 * ── 有意差异（不是漏做）──
 *   1. 长文折叠阈值取 200 字：小程序按行数折，但鸿蒙这边不同字号下 8 行的字数差很多，
 *      用字数判定更稳；≤200 字直接铺开，还给「展开全文」只会浪费一次点击。
 *   2. 相对时间自己算：Format.ets 的 relativeTime 是「过去式」口径（用于发射倒计时列表），
 *      活动有大量未来日期，需要「N 天后」这种未来式，口径不同故本页自备 relTimeOf()。
 *   3. failed（网络挂）与 notFound（id 匹配不到）是两个独立状态，绝不合并。
 *
 * 数据链路（与 ExpeditionView 同口径）：
 *   repo.peek<EvPayload>('events')  —— 同步、零网络，冷启动立刻上屏
 *   repo.load<EvPayload>('events', {onUpdate})  —— 后台刷新，onUpdate 回填
 *   .catch 里**只置 failed**，绝不置 found —— 否则弱网无缓存会变成「未找到」。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { EvItem, EvPayload, EvLaunchRef, evStr, evRefName, evTitle, evDesc } from '../model/Event';
import { strOf, parseTime, dayOf, formatShort, eventTypeName, applyTermFix } from '../utils/Format';
import { Nav } from '../routes/Nav';

const DOMAIN: number = 0x0000;
const TAG: string = 'EventDetailView';

// ============ 视觉常量（工程约定） ============

const BG: string = '#0A0E17';
const CARD: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
/** 占位底色：比卡片深一档，空图时才不至于和卡片糊成一片 */
const PLACEHOLDER_BG: string = '#1B2330';
/** 分隔线 */
const LINE: string = '#1E2736';

const CARD_RADIUS: number = 12;
const CARD_PAD: number = 14;
/** 区块间距 15vp（工程约定） */
const BLOCK_GAP: number = 15;
const PAGE_PAD: number = 12;
/** 二级页底部留白统一 32 */
const BOTTOM_PAD: number = 32;

const HERO_H: number = 200;
/** 无封面图时的占位图标：不引图片资源，emoji 足够 */
const HERO_EMOJI: string = '🛰️';
/** 正文折叠阈值（字数，不是行数 —— 理由见文件头） */
const DESC_FOLD_LIMIT: number = 200;
/** 折叠时保留 8 行 */
const DESC_COLLAPSED_LINES: number = 8;

const MIN_MS: number = 60 * 1000;
const HOUR_MS: number = 60 * MIN_MS;
const DAY_MS: number = 24 * HOUR_MS;
/** 超过一个月就不再报具体天数：活动是一次性节点，读者要的是「很久以前」 */
const STALE_DAYS: number = 30;

// ============ 纯函数（放在组件外，避免每次重绘重建闭包） ============

/**
 * 正文压平。
 *
 * 为什么不用 replace 链：ArkTS 里 replace 的字符串分片容易踩转义，
 * split/join 语义更直白，也顺带把连续空行收成一个空格。
 */
function flattenText(raw: string): string {
  const s: string = strOf(raw);
  if (s.length === 0) {
    return '';
  }
  return s.split('\r\n').join(' ').split('\n').join(' ').split('\r').join(' ');
}

/**
 * 相对时间（未来式 + 过去式统一口径）。
 *
 * 输出示例：即将开始 / 5 分钟后 / 3 小时后 / 3 天后 / 刚刚结束 / 5 小时前 / 12 天前 / 已结束。
 * 日期无效返回空串，调用方据此整行不画。
 */
function relTimeOf(iso: string): string {
  const t: number = parseTime(strOf(iso));
  if (t <= 0) {
    return '';
  }
  const diff: number = t - Date.now();

  if (diff > 0) {
    if (diff < MIN_MS) {
      return '即将开始';
    }
    if (diff < HOUR_MS) {
      return String(Math.max(1, Math.round(diff / MIN_MS))) + ' 分钟后';
    }
    if (diff < DAY_MS) {
      return String(Math.max(1, Math.round(diff / HOUR_MS))) + ' 小时后';
    }
    const days: number = Math.round(diff / DAY_MS);
    if (days <= STALE_DAYS) {
      return String(Math.max(1, days)) + ' 天后';
    }
    return '未来';
  }

  const ago: number = -diff;
  if (ago < MIN_MS) {
    return '刚刚结束';
  }
  if (ago < HOUR_MS) {
    return String(Math.max(1, Math.round(ago / MIN_MS))) + ' 分钟前';
  }
  if (ago < DAY_MS) {
    return String(Math.max(1, Math.round(ago / HOUR_MS))) + ' 小时前';
  }
  const daysAgo: number = Math.floor(ago / DAY_MS);
  if (daysAgo <= STALE_DAYS) {
    return String(daysAgo) + ' 天前';
  }
  return '已结束';
}

/** 发射标题：中文优先，缺了就英文，全缺兜底一句人话，别画空行 */
function launchTitle(l: EvLaunchRef): string {
  const zh: string = evStr(l.nameZh).trim();
  if (zh.length > 0) {
    return zh;
  }
  const en: string = evStr(l.name).trim();
  return en.length > 0 ? en : '未命名发射';
}

@Component
export struct EventDetailView {
  /** 活动 id（number 转字符串后传进来） */
  @Prop eventId: string = '';

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，不挡返回栏） */
  @State loading: boolean = true;
  /** 已经定位到这一条。**失败时绝不置 true** */
  @State found: boolean = false;
  /** 加载失败（无缓存 + 网络失败）。与「未找到」严格分开 */
  @State failed: boolean = false;

  /** 整条记录。字段判定都在 applyItem 里做完，UI 只读渲染 */
  @State item: EvItem | null = null;

  /** 封面图是否已挂：远程图 404 时回落到 emoji 占位 */
  @State heroBroken: boolean = false;
  /** 正文是否展开 */
  @State expanded: boolean = false;

  /** 防重入：重试连点不应叠请求 */
  private loadingNow: boolean = false;

  // ============ 对外回调（普通成员，不加装饰器） ============

  onOpenLaunch: (id: string, net: string, title: string) => void = () => {};

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadEvent(false);
  }

  // ============ 加载 ============

  /**
   * 先 peek 再 load。
   *
   * force 只给「失败重试」用：绕过缓存直接回源，免得重试又命中那份坏缓存。
   */
  private loadEvent(force: boolean): void {
    if (this.loadingNow) {
      return;
    }
    this.loadingNow = true;
    this.loading = true;
    this.failed = false;

    const cached: EvPayload | null = repo.peek<EvPayload>('events');
    if (cached !== null) {
      this.applyPayload(cached);
      if (this.found) {
        // 缓存命中就收掉 loading，不等网络（后台刷新照常进行）
        this.loading = false;
      }
    }

    const opts: LoadOptions<EvPayload> = {
      force: force,
      onUpdate: (fresh: EvPayload) => {
        // 后台刷新只回填；这一版里找不到就保持现有画面，不把已渲染的页打回「未找到」
        this.applyPayload(fresh);
      }
    };

    repo.load<EvPayload>('events', opts)
      .then((data: EvPayload) => {
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有内容就别喊失败，静默留在旧数据上（弱网体验优先）
        this.failed = !this.found;
        hilog.warn(DOMAIN, TAG, 'events 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingNow = false;
      });
  }

  /**
   * 数据落地：从载荷里找到这一条。
   *
   * list 声明成必填，但 JSON.parse 只是编译期断言、运行时不校验，
   * 所以仍按「可能 undefined」读一遍；只判 undefined 不判 null ——
   * 声明类型里没有 null，多写一个不等比较会被判成「两个类型无重叠」而报错。
   */
  private applyPayload(data: EvPayload): void {
    const raw: EvItem[] | undefined = data.list;
    const list: EvItem[] = raw !== undefined ? raw : [];
    const hit: EvItem | null = this.findIn(list);
    if (hit === null) {
      return;
    }
    this.applyItem(hit);
  }

  /** 按 id 定位。id 是 number、入参是 string，统一 String() 比较 */
  private findIn(list: EvItem[]): EvItem | null {
    const target: string = strOf(this.eventId).trim();
    if (target.length === 0) {
      return null;
    }
    for (let i = 0; i < list.length; i++) {
      const it: EvItem = list[i];
      if (String(it.id) === target) {
        return it;
      }
    }
    return null;
  }

  private applyItem(it: EvItem): void {
    this.item = it;
    // 换一条记录时不继承上一条的破图 / 展开态
    this.heroBroken = false;
    this.expanded = false;
    this.found = true;
  }

  // ============ 派生值 ============

  private titleOf(): string {
    const it: EvItem | null = this.item;
    return it !== null ? evTitle(it) : '';
  }

  /** 英文名：仅当中文名存在且与英文不同才展示，否则同一行字画两遍没意义 */
  private subTitleOf(): string {
    const it: EvItem | null = this.item;
    if (it === null) {
      return '';
    }
    const zh: string = evStr(it.nameZh).trim();
    const en: string = evStr(it.name).trim();
    if (zh.length === 0 || zh === en) {
      return '';
    }
    return en;
  }

  private typeText(): string {
    const it: EvItem | null = this.item;
    if (it === null) {
      return '';
    }
    const raw: string = evRefName(it.type).trim();
    return raw.length > 0 ? eventTypeName(raw) : '';
  }

  private placeText(): string {
    const it: EvItem | null = this.item;
    if (it === null) {
      return '';
    }
    return evRefName(it.location).trim();
  }

  /** 封面地址：null 与空串都算没有 */
  private heroUrl(): string {
    const it: EvItem | null = this.item;
    if (it === null) {
      return '';
    }
    return strOf(it.feature_image).trim();
  }

  private showHeroImage(): boolean {
    return this.heroUrl().length > 0 && !this.heroBroken;
  }

  private dateText(): string {
    const it: EvItem | null = this.item;
    if (it === null) {
      return '';
    }
    const d: string = dayOf(strOf(it.date));
    return d.length > 0 ? d : '时间待定';
  }

  private relText(): string {
    const it: EvItem | null = this.item;
    return it !== null ? relTimeOf(strOf(it.date)) : '';
  }

  /**
   * 正文：applyTermFix 必须在压平**之后**跑 —— 术语纠正表里有跨词匹配的条目，
   * 先压平能保证「轨道插入\n（TMI）」这种被换行打断的写法也能命中。
   */
  private descText(): string {
    const it: EvItem | null = this.item;
    if (it === null) {
      return '';
    }
    return applyTermFix(flattenText(evDesc(it)));
  }

  private needFold(): boolean {
    return this.descText().length > DESC_FOLD_LIMIT;
  }

  /** 展开后给一个足够大的行数，比切两个 Text 分支省一份重复样式 */
  private descLines(): number {
    return this.expanded ? 1000 : DESC_COLLAPSED_LINES;
  }

  private launches(): EvLaunchRef[] {
    const it: EvItem | null = this.item;
    if (it === null) {
      return [];
    }
    const raw: EvLaunchRef[] | undefined = it.launches !== null && it.launches !== undefined ? it.launches : undefined;
    return raw !== undefined ? raw : [];
  }

  private retry(): void {
    this.loadEvent(true);
  }

  // ============ 交互 ============

  private openLaunch(l: EvLaunchRef): void {
    // EvLaunchRef.id 在 model 里声明成 string | number（LL2 两种都出现过），
    // 声明成窄类型会让编译报「Type 'string' is not assignable to type 'number'」，
    // 所以按原声明收，下面统一 String() 一次再进路由。
    const id: string | number | undefined = l.id;
    if (id === undefined) {
      // 没有 id 就进不去发射详情（LaunchDetailView 只会显示「未找到」），干脆不响应
      return;
    }
    this.onOpenLaunch(String(id), strOf(l.net), launchTitle(l));
  }

  // ============ UI：顶栏（不滚动） ============

  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor(TEXT_SUB)
          .onClick(() => {
            Nav.pop();
          })
      }
      // 上下各 10vp 把热区撑到约 40vp，别让 15vp 的字直接当可点区域
      .padding({ right: 12, top: 10, bottom: 10 })

      Text('活动详情')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .alignItems(VerticalAlign.Center)
  }

  // ============ UI：Hero ============

  @Builder
  chipRow() {
    // 两个 chip 加起来可能超宽，用 Flex 折行而不是 Row
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      if (this.typeText().length > 0) {
        Text(this.typeText())
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(BG)
          .backgroundColor(ACCENT)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .margin({ right: 6, bottom: 4 })
      }

      if (this.placeText().length > 0) {
        Text(this.placeText())
          .fontSize(10.5)
          .fontColor(TEXT_MAIN)
          .backgroundColor('#33FFFFFF')
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .margin({ right: 6, bottom: 4 })
      }
    }
    .width('100%')
    .margin({ bottom: 8 })
  }

  @Builder
  heroBlock() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.showHeroImage()) {
        Image(this.heroUrl())
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .backgroundColor(PLACEHOLDER_BG)
          .onError(() => {
            // 远程封面挂掉就回落到占位，别留一块 200vp 的黑洞
            this.heroBroken = true;
          })
      } else {
        Column() {
          Text(HERO_EMOJI)
            .fontSize(48)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(PLACEHOLDER_BG)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      // 压黑层：保证白色标题在亮图上仍然读得出来（不改图，只加渐变）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#000A0E17', 0.0], ['#E60A0E17', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      Column() {
        this.chipRow()

        Text(this.titleOf())
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_MAIN)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.subTitleOf().length > 0) {
          Text(this.subTitleOf())
            .fontSize(11.5)
            .fontColor(TEXT_SUB)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(14)
    }
    .width('100%')
    .height(HERO_H)
    // Stack 里的子层不会互相裁剪，圆角得靠 clip 兜住
    .clip(true)
    .borderRadius(CARD_RADIUS)
  }

  // ============ UI：时间卡 ============

  @Builder
  infoLine(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(TEXT_DIM)
        .width(64)

      Text(value)
        .fontSize(13.5)
        .fontColor(TEXT_MAIN)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  timeCard() {
    Column() {
      this.infoLine('日期', this.dateText())

      if (this.relText().length > 0) {
        Divider()
          .strokeWidth(1)
          .color(LINE)
          .margin({ top: 10, bottom: 10 })

        this.infoLine('相对时间', this.relText())
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD)
    .borderRadius(CARD_RADIUS)
    .margin({ top: BLOCK_GAP })
  }

  // ============ UI：详情卡 ============

  @Builder
  descCard() {
    Column() {
      Text('详情')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .width('100%')

      Text(this.descText())
        .fontSize(13.5)
        .fontColor(TEXT_SUB)
        .lineHeight(21)
        .width('100%')
        .margin({ top: 10 })
        .maxLines(this.descLines())
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.needFold()) {
        // 折叠按钮只长在「确实有更多字」的时候，避免无意义的一次点击
        Text(this.expanded ? '收起' : '展开全文')
          .fontSize(12.5)
          .fontColor(ACCENT)
          .margin({ top: 10 })
          .onClick(() => {
            this.expanded = !this.expanded;
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD)
    .borderRadius(CARD_RADIUS)
    .margin({ top: BLOCK_GAP })
  }

  // ============ UI：关联发射卡 ============

  @Builder
  launchRow(l: EvLaunchRef) {
    Row() {
      Column() {
        Text(launchTitle(l))
          .fontSize(15)
          .fontColor(TEXT_MAIN)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(strOf(l.net).length > 0 ? formatShort(strOf(l.net)) : '时间待定')
          .fontSize(11.5)
          .fontColor(TEXT_SUB)
          .width('100%')
          .maxLines(1)
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(16)
        .fontColor(TEXT_DIM)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 9, bottom: 9 })
    .onClick(() => {
      this.openLaunch(l);
    })
  }

  @Builder
  launchCard() {
    Column() {
      Text('关联发射（' + this.launches().length + '）')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .width('100%')
        .margin({ bottom: 4 })

      ForEach(this.launches(), (l: EvLaunchRef) => {
        this.launchRow(l)
      }, (l: EvLaunchRef) => String(l.id !== undefined ? l.id : launchTitle(l)))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD)
    .borderRadius(CARD_RADIUS)
    .margin({ top: BLOCK_GAP })
  }

  // ============ UI：页脚 ============

  @Builder
  footerHint() {
    Text('数据来源 The Space Devs')
      .fontSize(11)
      .fontColor(TEXT_DIM)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ top: 18 })
  }

  // ============ UI：三态 ============

  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ACCENT)
      Text('正在加载活动…')
        .fontSize(12)
        .fontColor(TEXT_DIM)
        .margin({ top: 10 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  failedBlock() {
    Column() {
      Text('活动数据加载失败')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      Text('网络不给力，或缓存已被清理')
        .fontSize(12)
        .fontColor(TEXT_DIM)
        .margin({ top: 8 })

      Row() {
        Text('重试')
          .fontSize(12.5)
          .fontColor(ACCENT)
      }
      .padding({ left: 18, right: 18, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor('#16222F')
      .margin({ top: 16 })
      .onClick(() => {
        this.retry();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  @Builder
  notFoundBlock() {
    Column() {
      Text('未找到该活动')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      Text('可能是链接已过期，或数据正在更新')
        .fontSize(12)
        .fontColor(TEXT_DIM)
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })

      Row() {
        Text('‹ 返回')
          .fontSize(12.5)
          .fontColor(TEXT_SUB)
      }
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(CARD)
      .margin({ top: 12 })
      .onClick(() => {
        Nav.pop();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  // ============ build ============

  build() {
    Column() {
      this.topBar()

      if (this.loading && !this.found) {
        this.loadingBlock()
      } else if (this.failed && !this.found) {
        this.failedBlock()
      } else if (!this.found) {
        this.notFoundBlock()
      } else {
        Scroll() {
          Column() {
            this.heroBlock()
            this.timeCard()

            if (this.descText().length > 0) {
              this.descCard()
            }

            if (this.launches().length > 0) {
              this.launchCard()
            }

            this.footerHint()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
  }
}
