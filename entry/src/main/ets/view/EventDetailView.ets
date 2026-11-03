/**
 * view/EventDetailView.ets —— 活动详情页
 *
 * 对位小程序 `pages/event/eventInfo.vue`（345 行），尺寸按 wcss 的 rpx ÷ 2 换算：
 *   首图 470rpx→235、遮罩 300rpx→150、标题 40rpx→20、卡标题 30rpx→15、
 *   正文 29rpx→14.5、行标签 26rpx→13、行值 27rpx→13.5、卡圆角 20rpx→10。
 *
 * ── 契约 ──
 *   @Component export struct EventDetailView { @Prop eventId: string = ''; }
 *   onOpenLaunch 由路由容器（DetailPages.ets:486）注入。小程序这一版**没有**
 *   「关联发射」卡（实测 26 条 events 的 launches 全空），所以本页不再画它；
 *   回调成员保留声明，否则路由侧的具名参数会编译不过。
 *
 * ── 数据来源 events.json ──
 *   id / name / nameZh / date / description / descriptionZh / feature_image /
 *   type / location / launches[]
 *   · type、location 是**联合类型** EvRef | string | null —— 上游有时给对象有时给字符串，
 *     一律用 model/Event.ets 的 evRefName() 读名字，别自己判 typeof。
 *   · description / descriptionZh **含 \r\n**（上游正文带硬换行），不压平会被 Text
 *     当成段落切成一堆碎行，所以渲染前统一 split/join 成空格。
 *   · feature_image 可能 null 也可能空串 → 两种都按「没有图」处理，画 emoji 占位。
 *
 * ── 三处删除（都是「小程序没有、鸿蒙多画」）──
 *   1. 「关联发射」卡：数据里 launches 恒空，画出来永远是「（0）」。
 *   2. 页脚「数据来源 The Space Devs」：小程序详情页没有页脚。
 *   3. 正文折叠：「展开全文」按钮去掉了。实测最长 152 字，整段铺开只占 6 行，
 *      为了省 3 行让用户点一次，是把阅读切成两段。
 *
 * ── 三态合并成一个空态 ──
 *   小程序只有 loading / notFound 两态（load 失败时 ev 为空，落到同一个空态）。
 *   鸿蒙这边保留 failed 的判定，但**画面与 notFound 合并**，只在文案下面
 *   多给一个「重试」——否则弱网时用户看到「没有找到这项活动」会以为数据没了。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { EvItem, EvPayload, evStr, evRefName, evDesc } from '../model/Event';
import {
  strOf, formatDateTime, relativeTime, eventTypeName, eventPlace, eventName, applyTermFix
} from '../utils/Format';
import { Nav } from '../routes/Nav';
import { PhotoNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'EventDetailView';

// ============ 视觉常量（照抄小程序 wcss ÷ 2） ============

const BG: string = '#0A0E17';
const CARD: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
/** 行值 #e2e8f0 */
const TEXT_VALUE: string = '#E2E8F0';
/** 行标签 #6b7891 */
const TEXT_LABEL: string = '#6B7891';
/** 卡标题与高亮值 #38bdf8 */
const ACCENT: string = '#38BDF8';
/** 英文原名 #93a3b8 */
const TEXT_HERO_EN: string = '#93A3B8';
/** 正文 #cbd5e0 */
const TEXT_DESC: string = '#CBD5E0';
/** 无图占位底色 #0f1520 */
const PLACEHOLDER_BG: string = '#0F1520';

/** rgba(255,255,255,.05) → 0x0D */
const BORDER_FAINT: string = '#0DFFFFFF';
/** 地点标签底 rgba(255,255,255,.08) → 0x14，字色 #9aa7b8 */
const TAG_LOC_BG: string = '#14FFFFFF';
const TAG_LOC_FG: string = '#9AA7B8';
/** 类型标签底 rgba(56,189,248,.16) → 0x29 */
const TAG_TYPE_BG: string = '#2938BDF8';

/** 首图 470rpx → 235 */
const HERO_H: number = 235;
/** 遮罩 300rpx → 150 */
const MASK_H: number = 150;
/** 卡圆角 20rpx → 10 */
const CARD_RADIUS: number = 10;
/** 卡间距 24rpx → 12 */
const BLOCK_GAP: number = 12;
/** 卡内边距 28rpx 30rpx → 14 / 15 */
const CARD_PAD_V: number = 14;
const CARD_PAD_H: number = 15;
/** 正文区左右 32rpx → 16 */
const PAGE_PAD: number = 16;
/** 行标签列宽 110rpx → 55 */
const LABEL_W: number = 55;

const HERO_EMOJI: string = '🛰️';

// ============ 纯函数（放在组件外，避免每次重绘重建闭包） ============

/**
 * 正文压平。
 *
 * 为什么不用 replace 链：ArkTS 里 replace 的字符串分片容易踩转义，
 * split/join 语义更直白，也不会把连续空行留下。
 */
function flattenText(raw: string): string {
  const s: string = strOf(raw);
  if (s.length === 0) {
    return '';
  }
  let out: string = s.split('\r\n').join(' ').split('\n').join(' ').split('\r').join(' ');
  let guard: number = 0;
  while (out.indexOf('  ') >= 0 && guard < 32) {
    out = out.split('  ').join(' ');
    guard++;
  }
  return out.trim();
}

@Component
export struct EventDetailView {
  /** 活动 id（number 转字符串后传进来） */
  @Prop eventId: string = '';

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区） */
  @State loading: boolean = true;
  /** 已经定位到这一条。**失败时绝不置 true** */
  @State found: boolean = false;
  /** 加载失败（无缓存 + 网络失败）。画面与「未找到」合并，只多给一个重试 */
  @State failed: boolean = false;

  /** 整条记录。字段判定都在 applyItem 里做完，UI 只读渲染 */
  @State item: EvItem | null = null;

  /** 封面图是否已挂：远程图 404 时回落到 emoji 占位 */
  @State heroBroken: boolean = false;

  /** 防重入：重试连点不应叠请求 */
  private loadingNow: boolean = false;

  // ============ 对外回调（普通成员，不加装饰器） ============
  //
  // 本页不再画「关联发射」卡，但路由（DetailPages.ets:486）仍以具名参数传入，
  // 删掉这个成员会让那条构造调用编译失败，所以保留声明。
  // eslint 类告警无所谓，宁可留一个未用成员，也不改别人文件。
  onOpenLaunch: (id: string, net: string, title: string) => void = () => {};

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadEvent(false);
  }

  // 本页无定时器：相对时间在渲染时现算，不需要 aboutToDisappear 清理。

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
        // 后台刷新只回填；这一版里找不到就保持现有画面，不把已渲染的页打回空态
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
    // 换一条记录时不继承上一条的破图态
    this.heroBroken = false;
    this.found = true;
  }

  private retry(): void {
    this.loadEvent(true);
  }

  // ============ 派生值 ============

  private titleOf(): string {
    const it: EvItem | null = this.item;
    if (it === null) {
      return '';
    }
    // 中文名优先，缺失回退英文；再跑一遍术语纠正（专有事件名不该被机翻带歪）
    return eventName(evStr(it.nameZh), evStr(it.name));
  }

  /** 英文原名：仅当中文名存在且与英文不同才展示，否则同一行字画两遍没意义 */
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

  /** 类型名：小程序是 `eventTypeName(t) || '活动'`，所以这里兜底成「活动」 */
  private typeText(): string {
    const it: EvItem | null = this.item;
    if (it === null) {
      return '活动';
    }
    const raw: string = evRefName(it.type).trim();
    if (raw.length === 0) {
      return '活动';
    }
    const zh: string = eventTypeName(raw);
    return zh.length > 0 ? zh : '活动';
  }

  /**
   * 地点：必须过 eventPlace —— 活动地点可能是空间站（"ISS"）、天体轨道
   * 或发射场，三张字典都压在 eventPlace 里。直接 evRefName 会露出英文原串。
   */
  private placeText(): string {
    const it: EvItem | null = this.item;
    if (it === null) {
      return '';
    }
    return eventPlace(evRefName(it.location)).trim();
  }

  private hasLocation(): boolean {
    const it: EvItem | null = this.item;
    if (it === null) {
      return false;
    }
    return evRefName(it.location).trim().length > 0;
  }

  /** 有 type 才画「类型」那一行（对齐小程序 v-if="ev.type && ev.type.name"） */
  private hasType(): boolean {
    const it: EvItem | null = this.item;
    if (it === null) {
      return false;
    }
    return evRefName(it.type).trim().length > 0;
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

  /** 日期：formatDateTime（含时分），解析失败给「时间待定」 */
  private dateText(): string {
    const it: EvItem | null = this.item;
    if (it === null) {
      return '时间待定';
    }
    const s: string = formatDateTime(strOf(it.date));
    return s.length > 0 ? s : '时间待定';
  }

  /** 距今：直接复用 Format.relativeTime，与小程序的 computed.relText 同一个函数 */
  private relText(): string {
    const it: EvItem | null = this.item;
    return it !== null ? relativeTime(strOf(it.date)) : '';
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

  // ============ 交互 ============

  /** 点首图 → 全屏看图（对齐小程序 uni.previewImage；本工程走 PhotoView） */
  private preview(): void {
    const url: string = this.heroUrl();
    if (url.length === 0) {
      return;
    }
    Nav.pushPhoto(new PhotoNavParam(url, this.titleOf()));
  }

  // ============ UI：首图 ============

  /**
   * 首图区：整屏宽、无圆角（小程序里它顶到屏幕两边，是沉浸式的）。
   *
   * 遮罩单独一层而不是给图片加 linearGradient：图片要保持原色，
   * 只在底部 150vp 把底色渐变上来，标题才压得住亮图。
   */
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
            // 远程封面挂掉就回落到占位，别留一块 235vp 的黑洞
            this.heroBroken = true;
          })
          .onClick(() => {
            this.preview();
          })
      } else {
        Column() {
          Text(HERO_EMOJI)
            .fontSize(44)
            .opacity(0.28)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .linearGradient({
          angle: 135,
          colors: [['#16233A', 0.0], ['#0D1420', 1.0]]
        })
      }

      // 底部渐隐：rgba(10,14,23,0) → #0a0e17
      Column()
        .width('100%')
        .height(MASK_H)
        .linearGradient({
          angle: 180,
          colors: [['#000A0E17', 0.0], ['#0A0E17', 1.0]]
        })
        .hitTestBehavior(HitTestMode.None)

      Column() {
        // 标签行：类型 + 地点。可能超宽，必须折行
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          Text(this.typeText())
            .fontSize(11)
            .fontColor(ACCENT)
            .backgroundColor(TAG_TYPE_BG)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(3)
            .margin({ right: 6, bottom: 4 })
            .maxLines(1)

          if (this.hasLocation()) {
            Text(this.placeText())
              .fontSize(11)
              .fontColor(TAG_LOC_FG)
              .backgroundColor(TAG_LOC_BG)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(3)
              .margin({ right: 6, bottom: 4 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
        .margin({ bottom: 6 })

        // 标题 20vp / 600 / line-height 1.35 → 27
        Text(this.titleOf())
          .fontSize(20)
          // 小程序 .hero-name 是 font-weight: 600
          .fontWeight(600)
          .fontColor(TEXT_MAIN)
          .lineHeight(27)
          .width('100%')
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.subTitleOf().length > 0) {
          Text(this.subTitleOf())
            .fontSize(11)
            .fontColor(TEXT_HERO_EN)
            .lineHeight(16)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      // 小程序 .hero-body 是 left/right 32rpx、bottom 26rpx → 16 / 13
      .padding({ left: 16, right: 16, bottom: 13 })
    }
    .width('100%')
    .height(HERO_H)
  }

  // ============ UI：时间卡（4 行） ============

  @Builder
  infoRow(label: string, value: string, highlight: boolean) {
    Row() {
      Text(label)
        .fontSize(13)
        .fontColor(TEXT_LABEL)
        .width(LABEL_W)
        .flexShrink(0)

      Text(value)
        .fontSize(13.5)
        .fontColor(highlight ? ACCENT : TEXT_VALUE)
        .lineHeight(21)
        .layoutWeight(1)
    }
    .width('100%')
    // 小程序 .row 是 align-items: flex-start + padding: 10rpx 0 → 5
    .alignItems(VerticalAlign.Top)
    .padding({ top: 5, bottom: 5 })
  }

  /**
   * 时间卡：**4 行**（日期 / 距今 / 地点 / 类型）。
   *
   * 旧实现只有 2 行（日期 / 相对时间），且日期用 dayOf 只给了 YYYY-MM-DD ——
   * 活动是有具体时刻的（EVA 出舱 06:30 与 18:30 完全是两件事），
   * 时间必须到「时分」，所以改用 formatDateTime。
   */
  @Builder
  timeCard() {
    Column() {
      Text('时间')
        .fontSize(15)
        // card-title 是 600
        .fontWeight(600)
        .fontColor(ACCENT)
        .width('100%')
        .margin({ bottom: 8 })

      this.infoRow('日期', this.dateText(), false)

      if (this.relText().length > 0) {
        this.infoRow('距今', this.relText(), true)
      }

      if (this.hasLocation()) {
        this.infoRow('地点', this.placeText(), false)
      }

      if (this.hasType()) {
        this.infoRow('类型', this.typeText(), false)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CARD_PAD_V, bottom: CARD_PAD_V, left: CARD_PAD_H, right: CARD_PAD_H })
    .backgroundColor(CARD)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: BORDER_FAINT })
    .margin({ top: BLOCK_GAP })
  }

  // ============ UI：简介卡（不折叠） ============

  @Builder
  descCard() {
    Column() {
      Text('简介')
        .fontSize(15)
        // card-title 是 600
        .fontWeight(600)
        .fontColor(ACCENT)
        .width('100%')
        .margin({ bottom: 8 })

      // 14.5vp / line-height 1.75 → 25，整段铺开不截断
      Text(this.descText())
        .fontSize(14.5)
        .fontColor(TEXT_DESC)
        .lineHeight(25)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CARD_PAD_V, bottom: CARD_PAD_V, left: CARD_PAD_H, right: CARD_PAD_H })
    .backgroundColor(CARD)
    .borderRadius(CARD_RADIUS)
    .border({ width: 1, color: BORDER_FAINT })
    .margin({ top: BLOCK_GAP })
  }

  // ============ UI：三态 ============

  @Builder
  loadingBlock() {
    Column() {
      Text('加载中...')
        .fontSize(13)
        .fontColor(TEXT_LABEL)
    }
    .width('100%')
    // 父级是 Stack，子项不吃 layoutWeight（会被忽略、退化成内容高），
    // 撑满得用 100%；父 Stack 有确定高度，不会回溯到整屏。
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    // 小程序 .state 是 padding: 220rpx 40rpx → 110 / 20
    .padding({ top: 110, bottom: 110, left: 20, right: 20 })
  }

  /**
   * 空态：🛰️ + 「没有找到这项活动」。
   *
   * 网络失败与 id 匹配不到**共用这一屏**（小程序就是这样：load 抛错时 ev 为 null，
   * 落到同一个空态）。只在失败时多给一个「重试」——没有它，弱网用户只能退出去再进来。
   * 出口由常显的 floatBack 胶囊负责，这里不再重复画「返回」。
   */
  @Builder
  emptyBlock() {
    Column() {
      Text('🛰️')
        .fontSize(32)
        .opacity(0.35)
        .margin({ bottom: 8 })

      Text('没有找到这项活动')
        .fontSize(13)
        .fontColor(TEXT_LABEL)

      if (this.failed) {
        Text('重试')
          .fontSize(12.5)
          .fontColor(ACCENT)
          .margin({ top: 16 })
          .onClick(() => {
            this.retry();
          })
      }
    }
    .width('100%')
    // 同 loadingBlock：父级 Stack 里 layoutWeight 不生效，用 100% 撑满
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 110, bottom: 110, left: 20, right: 20 })
  }

  // ============ UI：悬浮返回 ============

  /**
   * 首图是沉浸式的（顶到左右边缘），不能再画一条 48vp 的实心标题栏，
   * 否则首图会被压掉一块。代价是返回键得自己造，做成半透明胶囊压在图上。
   * 深色底 + 白字：亮图暗图上都读得出来。
   */
  @Builder
  floatBack() {
    Row() {
      Text('‹ 返回')
        .fontSize(13)
        .fontColor('#FFFFFF')
    }
    .padding({ left: 11, right: 11, top: 6, bottom: 6 })
    .backgroundColor('#73000000')
    .borderRadius(15)
    .position({ x: PAGE_PAD, y: 10 })
    .onClick(() => {
      Nav.pop();
    })
  }

  // ============ build ============

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.loading && !this.found) {
        this.loadingBlock()
      } else if (!this.found) {
        this.emptyBlock()
      } else {
        Scroll() {
          Column() {
            this.heroBlock()

            Column() {
              this.timeCard()

              if (this.descText().length > 0) {
                this.descCard()
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            // 小程序 .body 是 padding: 6rpx 32rpx 60rpx → 3 / 16 / 30
            .padding({ top: 3, left: PAGE_PAD, right: PAGE_PAD, bottom: 30 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }

      // 返回胶囊常显：空态与加载态也要有出口
      this.floatBack()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .padding({ bottom: 0 })
  }
}
