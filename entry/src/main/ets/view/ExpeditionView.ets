/**
 * view/ExpeditionView.ets —— 远征队详情页（对位小程序 pages/expedition/expedition.vue，333 行）
 *
 * ── 契约（不能改，路由容器按这个装配）──
 *   @Component export struct ExpeditionView { @Prop expeditionId: string = ''; }
 *   三个回调由父级（DetailPages.ets）注入：
 *     onOpenStation(id: string, name: string)
 *     onOpenPhoto(url: string, title: string)
 *     onOpenAstronaut(id: string, name: string)
 *
 * ── 数据来源 expeditions.json（实测 count=165）──
 *   id / name / start / end / stationId / stationName / patches[] / crew[]
 *   · end 为空串的 3 条 = 正在进行（页面据此出 #38bdf8 的「进行中」chip）
 *   · patches 是**任务徽章**（1:1 小图），118/165 非空
 *   · crew 每条 {id,name,role,agency,img}，img 实测多为空串 → 画 emoji 占位
 *
 * ── 本次 1:1 对齐改了什么（C 组 15 条）──
 *   1. head 去掉卡片化：小程序 `.head` 是**透明底**，只有左右 32rpx 内边距，
 *      顶部靠 `padding-top = statusBar + 52px` 让出状态栏。旧版套了一层 #141A26 卡片，
 *      首屏看起来像「标题卡」而不是小程序那种标题直接浮在页面底色上。
 *      鸿蒙侧本页顶部有常驻 48vp 的返回栏（在文档流里，天然让出了状态栏高度），
 *      所以 head 只需紧贴其下，不再重复留白。
 *   2. 名称 22vp → 18vp / 字色 #e2e8f0 / w700 / line-height 1.3，行数上限 2。
 *   3. 英文名 11.5vp #A7B4C7 → 11vp #6b7891 + letter-spacing 0.25。
 *   4. 起止文案 `start → end` → `start — end`（em dash），结束缺省由「进行中」改「至今」。
 *   5. 状态 chip 由「#34C759 实底 + 深色字」改为小程序的半透明底 + 同色字；
 *      **三页统一这套**，不再有绿实底。
 *   6. 空间站行从「嵌在卡片里的一条带顶部边框的行」改成**独立胶囊**：
 *      自己的 #141a26 底、7vp 圆角、8/10vp 内边距，名称 #38bdf8 13vp。
 *   7. 空间站空值 `—` → `未知`。
 *   8. 徽章 80vp/radius 8 → 70vp/radius 6，间距 10vp。
 *   9. 卡片标题 17vp Bold 白 → 12vp #94a3b8（两个卡都是）。
 *  10. 乘组 0 人时不补任何提示（删掉旧版的「暂无乘组信息」），标题照常写 `乘组（0 人）`。
 *  11. 乘组行 `{role} · {agency}` **原样英文**（Commander / NASA），不再翻中文；
 *      字号 13.5 / 10.5。
 *  12. 头像 48vp → 40vp，占位 emoji 22vp → 18vp。
 *  13. 卡片 radius 12→10、内边距 14→13/14、补 1rpx 描边 rgba(255,255,255,.05)。
 *  14. 页脚 11vp/#55617A/margin 18 → 10vp/#3d4a5c/margin 24。
 *  15. 三态改纯文字 `加载中...` / `未找到该远征队`（小程序只有一行 .hint-text，
 *      没有 spinner、没有图标、没有返回按钮）。
 *
 * ── 有意差异（不是漏做）──
 *   · 顶部返回栏常驻：小程序 nav-bar 是 fixed、滚 120 才出标题，鸿蒙这边沿用工程既有的
 *     48vp 自绘返回栏（不滚动），否则 NavDestination 里没有返回入口。
 *   · 徽章 404 当场摘除：COS 上仍有失效链接，留一个 70×70 破图比少一个徽章难看。
 *   · failed（网络挂）与 notFound（id 匹配不到）保持两个独立状态 —— 合并后用户看到
 *     「加载失败」，而真相是这个 id 根本不存在。
 *   · 乘组名不套中文专名表：crew 里没有 nation 字段，utils/Format 的
 *     astroName(raw, nation) 第二档用不上；硬猜国籍比显示原名更糟。
 *
 * 数据链路：
 *   repo.peek<ExpPayload>('expeditions')   —— 同步、零网络，冷启动立刻上屏
 *   repo.load<ExpPayload>('expeditions', { onUpdate }) —— 后台刷新
 *   .catch 里只置 failed，**绝不置 found** —— 否则弱网无缓存会变成「未找到」。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog；无定时器。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { BasePayload } from '../model/Common';
import { strOf, dayOf, expeditionName } from '../utils/Format';
import { Nav } from '../routes/Nav';

const DOMAIN: number = 0x0000;
const TAG: string = 'ExpeditionView';

// ============ 视觉常量（全部按 rpx ÷ 2 折算） ============

const BG: string = '#0A0E17';
const CARD: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
/** 名称 / 乘员名：小程序 #e2e8f0 */
const TEXT_NAME: string = '#E2E8F0';
/** 起止日期：小程序 #c6cfdd */
const TEXT_BODY: string = '#C6CFDD';
/** 次级灰：英文名 / 空间站标签 / 乘员副行 = 小程序 #6b7891 */
const TEXT_DIM: string = '#6B7891';
/** 卡片标题：小程序 #94a3b8 */
const TITLE_COLOR: string = '#94A3B8';
/** 箭头 / 页脚：小程序 #3d4a5c */
const TEXT_FAINT: string = '#3D4A5C';
const ACCENT: string = '#38BDF8';

/** 进行中 chip：底 rgba(56,189,248,.16) → alpha 0x29、字 #38bdf8 */
const CHIP_ON_BG: string = '#2938BDF8';
const CHIP_ON_FG: string = '#38BDF8';
/** 已结束 chip：底 rgba(255,255,255,.05) → alpha 0x0D、字 #55617a */
const CHIP_OFF_BG: string = '#0DFFFFFF';
const CHIP_OFF_FG: string = '#55617A';

/** 卡片描边 1rpx rgba(255,255,255,.05) */
const CARD_BORDER: string = '#0DFFFFFF';
/** 卡片圆角 20rpx = 10vp；内边距 26rpx 28rpx = 13/14vp */
const CARD_RADIUS: number = 10;
const CARD_PAD_V: number = 13;
const CARD_PAD_H: number = 14;
/** 卡片上间距 24rpx = 12vp */
const CARD_GAP: number = 12;
/** 页面左右 32rpx = 16vp（卡片和 head 同一口径） */
const PAGE_PAD: number = 16;
/** 二级页底部留白 32 */
const BOTTOM_PAD: number = 32;

/** 徽章 140rpx = 70vp、圆角 12rpx = 6vp、间距 20rpx = 10vp */
const PATCH_SIZE: number = 70;
const PATCH_RADIUS: number = 6;
const PATCH_GAP: number = 10;

/** 乘员头像 80rpx = 40vp，占位 emoji 36rpx = 18vp */
const AVATAR_SIZE: number = 40;
const CREW_AVATAR_EMOJI: string = '🧑‍🚀';
const CREW_AVATAR_EMOJI_SIZE: number = 18;

/** 乘组角色原样英文（小程序不翻译），副行 21rpx = 10.5vp */
const CREW_NAME_SIZE: number = 13.5;
const CREW_SUB_SIZE: number = 10.5;

// ============ 类型（expeditions.json 实测结构） ============

/** 乘组一名成员。字段全可选：上游对个别乘员的 img / agency 缺失很常见 */
export interface ExpCrew {
  id?: number;
  name?: string;
  /** 实测值：Commander / Flight Engineer / Mission Specialist / Pilot 等英文原文 */
  role?: string;
  /** 机构缩写，如 NASA / RFSA / ESA / JAXA */
  agency?: string;
  /** 头像 URL，实测多为空串 */
  img?: string;
}

/**
 * 一条远征队。
 *
 * id 是 number（实测 165 这种），路由入参是 string，比较时统一 String()；
 * end 是**空串**表示进行中（不是 null、不是缺失），所以判「进行中」看的是
 * dayOf(end).length === 0，而不是 end === undefined。
 */
export interface ExpItem {
  id?: number;
  /** 英文名，如 "Expedition 74" */
  name?: string;
  /** 开始时刻，ISO */
  start?: string;
  /** 结束时刻，ISO；空串 = 进行中 */
  end?: string;
  /** 空间站 id，0 / 缺失表示没有关联空间站 */
  stationId?: number;
  stationName?: string;
  /** 任务徽章图 URL 列表 */
  patches?: string[];
  crew?: ExpCrew[];
}

/** expeditions 载荷信封 */
export interface ExpPayload extends BasePayload {
  dataset?: string;
  count?: number;
  served?: number;
  list: ExpItem[];
}

/**
 * 徽章渲染项。
 *
 * 为什么不直接 ForEach 一个 string[]：ForEach 的第三个参数（key 生成函数）拿不到
 * 稳定的原始下标语义，重复 URL 会撞 key；包一层带上原始下标，key 就唯一且稳定。
 * 前缀 Ex2 用于避开本工程已有的 Exp/Ev/Ne/Gl/Rt/Mn/Se/Vd/Pd/Ag 等前缀。
 */
class Ex2Patch {
  url: string = '';
  index: number = 0;

  constructor(url: string, index: number) {
    this.url = url;
    this.index = index;
  }
}

// ============ 纯函数（放组件外，避免每次重绘重建闭包） ============

/** 空片段用 · 连接：避免出现 " · NASA" 这种残缺分隔符 */
function joinParts(parts: string[]): string {
  return parts.join(' · ');
}

/** 日期展示：dayOf 用正则按原串截取、不构造 Date，避免东八区差一天 */
function ex2Day(v: string): string {
  const raw: string = strOf(v).trim();
  if (raw.length === 0) {
    return '';
  }
  const d: string = dayOf(raw);
  return d.length > 0 ? d : raw;
}

@Component
export struct ExpeditionView {
  /** 远征队 id（number 转字符串后传进来） */
  @Prop expeditionId: string = '';

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，不挡返回栏） */
  @State loading: boolean = true;
  /** 已经定位到这一条。**失败时绝不置 true** */
  @State found: boolean = false;
  /** 加载失败（无缓存 + 网络失败）。与「未找到」严格分开 */
  @State failed: boolean = false;

  /** 中文名（第 74 次远征）；英文名与之不同才单独显示 */
  @State expName: string = '';
  @State expNameEn: string = '';
  /** 已按 dayOf 截好的日期串，空串 = 缺失 / 进行中 */
  @State expStart: string = '';
  @State expEnd: string = '';
  @State expStationId: number = 0;
  @State expStationName: string = '';
  @State expPatches: string[] = [];
  @State expCrew: ExpCrew[] = [];

  /**
   * 徽章 / 头像加载失败表。
   *
   * 为什么用数组 + 整体替换而不是 Set：ArkTS 对 Set 的元素增删不保证触发 @State 重绘，
   * 而 `this.x = this.x.concat([v])` 换的是引用，一定重新渲染。
   */
  @State brokenPatches: string[] = [];
  @State brokenAvatars: number[] = [];

  /** 防重入：重试连点不应叠请求 */
  private loadingNow: boolean = false;

  // ============ 对外回调（普通成员，不加装饰器） ============

  onOpenStation: (id: string, name: string) => void = () => {};
  onOpenPhoto: (url: string, title: string) => void = () => {};
  onOpenAstronaut: (id: string, name: string) => void = () => {};

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadExpedition(false);
  }

  // ============ 加载 ============

  /**
   * 先 peek 再 load。
   *
   * force 只给「失败重试」用：绕过缓存直接回源，免得重试又命中那份坏缓存。
   */
  private loadExpedition(force: boolean): void {
    if (this.loadingNow) {
      return;
    }
    this.loadingNow = true;
    this.loading = true;
    this.failed = false;

    const cached: ExpPayload | null = repo.peek<ExpPayload>('expeditions');
    if (cached !== null) {
      this.applyPayload(cached);
      if (this.found) {
        // 缓存命中就收掉 loading，不等网络（后台刷新照常进行）
        this.loading = false;
      }
    }

    const opts: LoadOptions<ExpPayload> = {
      force: force,
      onUpdate: (fresh: ExpPayload) => {
        // 后台刷新只回填；这一版里找不到就保持现有画面，不把已渲染的页打回「未找到」
        this.applyPayload(fresh);
      }
    };

    repo.load<ExpPayload>('expeditions', opts)
      .then((data: ExpPayload) => {
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
        this.loadingNow = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有内容就别喊失败，静默留在旧数据上（弱网体验优先）
        this.failed = !this.found;
        // 防重入标记必须在这条分支也清掉，否则一次网络抖动会让「重试」永久失效
        this.loadingNow = false;
        hilog.warn(DOMAIN, TAG, 'expeditions 加载失败: %{public}s', e.message);
      });
  }

  /**
   * 数据落地：从载荷里找到这一条。
   *
   * list 声明成必填，但 JSON.parse 只是编译期断言、运行时不校验，
   * 所以仍按「可能 undefined」读一遍；只判 undefined 不判 null ——
   * 声明类型里没有 null，多写一个不等比较会被判成「两个类型无重叠」而报错。
   */
  private applyPayload(data: ExpPayload): void {
    const raw: ExpItem[] | undefined = data.list;
    const list: ExpItem[] = raw !== undefined ? raw : [];
    const hit: ExpItem | null = this.findIn(list);
    if (hit === null) {
      return;
    }
    this.applyExpedition(hit);
  }

  /** 按 id 定位。id 是 number、入参是 string，统一 String() 比较 */
  private findIn(list: ExpItem[]): ExpItem | null {
    const target: string = strOf(this.expeditionId).trim();
    if (target.length === 0) {
      return null;
    }
    for (let i = 0; i < list.length; i++) {
      const item: ExpItem = list[i];
      const idNum: number | undefined = item.id;
      if (idNum !== undefined && String(idNum) === target) {
        return item;
      }
    }
    return null;
  }

  /** 一条记录 → 页面状态。所有字段过一遍空值判定，不留 undefined 到 UI */
  private applyExpedition(e: ExpItem): void {
    const rawName: string = strOf(e.name).trim();
    const zh: string = expeditionName(rawName);
    this.expName = zh.length > 0 ? zh : '远征队';
    // 中文名没换字（例如上游给了个不叫 Expedition N 的名字）就别把同一行字再画一遍
    this.expNameEn = zh !== rawName ? rawName : '';

    this.expStart = ex2Day(strOf(e.start));
    // 空串 end = 进行中；dayOf('') 也返回空串，两种情形天然同码
    this.expEnd = ex2Day(strOf(e.end));

    const sid: number | undefined = e.stationId;
    this.expStationId = sid !== undefined ? sid : 0;
    this.expStationName = strOf(e.stationName).trim();

    const patches: string[] | undefined = e.patches;
    this.expPatches = patches !== undefined ? patches : [];
    const crew: ExpCrew[] | undefined = e.crew;
    this.expCrew = crew !== undefined ? crew : [];

    // 换一条记录时不继承上一条的破图标记
    this.brokenPatches = [];
    this.brokenAvatars = [];

    this.found = true;
  }

  // ============ 派生值 ============

  /** end 为空即进行中（数据层约定，不是靠日期跟 now 比出来） */
  private ongoing(): boolean {
    return this.expEnd.length === 0;
  }

  /** 文案取小程序的原话：进行中 / 已结束 */
  private statusText(): string {
    return this.ongoing() ? '进行中' : '已结束';
  }

  /** chip 底色：进行中半透明蓝、已结束极淡白（**不再用绿实底**） */
  private statusBg(): string {
    return this.ongoing() ? CHIP_ON_BG : CHIP_OFF_BG;
  }

  private statusFg(): string {
    return this.ongoing() ? CHIP_ON_FG : CHIP_OFF_FG;
  }

  /**
   * 起止行：`{start} — {end || '至今'}`。
   *
   * 分隔符是 em dash（—）不是箭头、缺省是「至今」不是「进行中」——
   * 两条都是小程序原文，改了就在文案库里对不上。
   * 起始缺失时小程序也不补占位（dayOf('') 就是空串），这里同样不补。
   */
  private rangeText(): string {
    const head: string = this.expStart;
    const tail: string = this.expEnd.length > 0 ? this.expEnd : '至今';
    return head + ' — ' + tail;
  }

  /** 徽章列表（去掉空串与加载失败的链接），带原始下标供 ForEach 做 key */
  private patchList(): Ex2Patch[] {
    const out: Ex2Patch[] = [];
    for (let i = 0; i < this.expPatches.length; i++) {
      const url: string = strOf(this.expPatches[i]).trim();
      if (url.length > 0 && this.brokenPatches.indexOf(url) < 0) {
        out.push(new Ex2Patch(url, i));
      }
    }
    return out;
  }

  /** 乘员名：小程序直接显示 `{{ m.name }}`，这里同样不做中文专名表 */
  private crewName(c: ExpCrew): string {
    const n: string = strOf(c.name).trim();
    return n.length > 0 ? n : '未知乘员';
  }

  /**
   * 副行：`{role} · {agency}`，**原样英文**。
   *
   * 旧版走 crewRoleZh + agencyLabel 翻成「指令长 · 美国宇航局」，
   * 与小程序显示的 Commander · NASA 不一致；小程序是英文原样输出的。
   */
  private crewMeta(c: ExpCrew): string {
    const parts: string[] = [];
    const role: string = strOf(c.role).trim();
    if (role.length > 0) {
      parts.push(role);
    }
    const agency: string = strOf(c.agency).trim();
    if (agency.length > 0) {
      parts.push(agency);
    }
    return joinParts(parts);
  }

  private avatarUrl(c: ExpCrew): string {
    return strOf(c.img).trim();
  }

  private avatarBroken(c: ExpCrew): boolean {
    const id: number | undefined = c.id;
    return id !== undefined && this.brokenAvatars.indexOf(id) >= 0;
  }

  /** 空间站名：小程序 `{{ exp.stationName || '未知' }}`（不查中文表） */
  private stationText(): string {
    return this.expStationName.length > 0 ? this.expStationName : '未知';
  }

  private retry(): void {
    this.loadExpedition(true);
  }

  // ============ 交互 ============

  private openStation(): void {
    this.onOpenStation(String(this.expStationId), this.expStationName);
  }

  private openPatch(url: string): void {
    // 徽章走工程唯一的看图器，不另做灯箱
    this.onOpenPhoto(url, '任务徽章');
  }

  private openAstronaut(c: ExpCrew): void {
    const id: number | undefined = c.id;
    if (id === undefined) {
      // 没有 id 就进不去详情页（AstronautView 只会显示「未找到」），干脆不响应
      return;
    }
    this.onOpenAstronaut(String(id), strOf(c.name));
  }

  // ============ UI：顶栏（不滚动） ============

  /**
   * 自绘返回栏。
   *
   * 小程序 nav-bar 是 fixed 浮动、滚 120 才浮出标题；鸿蒙侧 NavDestination 没有系统
   * header（DetailPages 里 hideTitleBar(true)），必须常驻一条返回栏，否则进得去出不来。
   * 高度 48 也让下面的 head 天然避开状态栏区域。
   */
  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor(TEXT_DIM)
          .onClick(() => {
            Nav.pop();
          })
      }
      // 上下各 10vp 把热区撑到约 40vp，别让 15vp 的字直接当可点区域
      .padding({ right: 12, top: 10, bottom: 10 })

      Text(this.found ? this.expName : '远征队')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .alignItems(VerticalAlign.Center)
  }

  // ============ UI：头部块（**非卡片**，透明底） ============

  /**
   * 头部：透明底 + 左右 16vp + 底部 4vp。
   *
   * 对位 `.head{padding:0 32rpx 8rpx}` —— 只有内边距，**没有背景、没有圆角、没有描边**。
   * 旧版把它包成 #141A26 卡片，等于给标题加了一个小程序没有的容器。
   */
  @Builder
  headBlock() {
    Column() {
      Text(this.expName)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        // line-height 1.3 × 18 ≈ 23vp
        .lineHeight(23)
        .fontColor(TEXT_NAME)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.expNameEn.length > 0) {
        Text(this.expNameEn)
          .fontSize(11)
          .fontColor(TEXT_DIM)
          .letterSpacing(0.25)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }

      Row() {
        Text(this.rangeText())
          .fontSize(12)
          .fontColor(TEXT_BODY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(this.statusText())
          .fontSize(9.5)
          .fontColor(this.statusFg())
          .backgroundColor(this.statusBg())
          // 3rpx 12rpx = 1.5/6vp、radius 6rpx = 3vp
          .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
          .borderRadius(3)
          .margin({ left: 8 })
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 6 })

      // 空间站胶囊：独立一块 #141a26，不是卡片里的一条带边框的行
      if (this.expStationId > 0) {
        Row() {
          Text('空间站')
            .fontSize(11)
            .fontColor(TEXT_DIM)

          Text(this.stationText())
            .fontSize(13)
            .fontColor(ACCENT)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .margin({ left: 6 })

          Text('›')
            .fontSize(15)
            .fontColor(TEXT_FAINT)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        // 16rpx 20rpx = 8/10vp、radius 14rpx = 7vp
        .padding({ left: 10, right: 10, top: 8, bottom: 8 })
        .backgroundColor(CARD)
        .borderRadius(7)
        .border({ width: 0.5, color: CARD_BORDER })
        .margin({ top: 9 })
        .onClick(() => {
          this.openStation();
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: 4 })
  }

  // ============ UI：任务徽章 ============

  @Builder
  patchItem(item: Ex2Patch) {
    Image(item.url)
      .width(PATCH_SIZE)
      .height(PATCH_SIZE)
      .borderRadius(PATCH_RADIUS)
      // 小程序 .patch 背景是页面底色，徽章留白才不显得浮
      .backgroundColor(BG)
      .objectFit(ImageFit.Contain)
      .onError(() => {
        // 失效链接当场摘掉，不留一块 70×70 的破图
        if (this.brokenPatches.indexOf(item.url) < 0) {
          this.brokenPatches = this.brokenPatches.concat([item.url]);
        }
      })
      .onClick(() => {
        this.openPatch(item.url);
      })
  }

  @Builder
  patchCard() {
    Column() {
      Text('任务徽章')
        .fontSize(12)
        .fontColor(TITLE_COLOR)
        .width('100%')
        .margin({ bottom: 7 })

      // Row 没有 flexWrap，折行必须 Flex + FlexWrap.Wrap；gap 20rpx = 10vp
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
        ForEach(this.patchList(), (item: Ex2Patch) => {
          Column() {
            this.patchItem(item)
          }
          .margin({ right: PATCH_GAP, bottom: PATCH_GAP })
        // key 带上断链表长度：onError 只改 @State 数组，
        // @Builder 按值传参不建立响应式依赖，靠 key 变化强制重算
        }, (item: Ex2Patch) => String(item.index) + '|' + item.url + '#' + String(this.brokenPatches.length))
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 底部内边距扣掉每个徽章自带的 10vp 下边距，视觉上仍是 13vp 的下留白
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V - PATCH_GAP })
    .backgroundColor(CARD)
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .margin({ top: CARD_GAP })
  }

  // ============ UI：乘组 ============

  @Builder
  crewRow(c: ExpCrew, isLast: boolean) {
    Row() {
      if (this.avatarUrl(c).length > 0 && !this.avatarBroken(c)) {
        Image(this.avatarUrl(c))
          .width(AVATAR_SIZE)
          .height(AVATAR_SIZE)
          .borderRadius(AVATAR_SIZE / 2)
          .objectFit(ImageFit.Cover)
          // 小程序 .avatar 背景是页面底色 #0a0e17
          .backgroundColor(BG)
          .onError(() => {
            const id: number | undefined = c.id;
            if (id !== undefined) {
              this.brokenAvatars = this.brokenAvatars.concat([id]);
            }
          })
      } else {
        Column() {
          Text(CREW_AVATAR_EMOJI)
            .fontSize(CREW_AVATAR_EMOJI_SIZE)
        }
        .width(AVATAR_SIZE)
        .height(AVATAR_SIZE)
        .borderRadius(AVATAR_SIZE / 2)
        .backgroundColor(BG)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      Column() {
        Text(this.crewName(c))
          .fontSize(CREW_NAME_SIZE)
          .fontColor(TEXT_NAME)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.crewMeta(c).length > 0) {
          Text(this.crewMeta(c))
            .fontSize(CREW_SUB_SIZE)
            .fontColor(TEXT_DIM)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            // 4rpx = 2vp
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 20rpx = 10vp
      .margin({ left: 10 })

      Text('›')
        .fontSize(15)
        .fontColor(TEXT_FAINT)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 14rpx 0 = 上下各 7vp
    .padding({ top: 7, bottom: 7 })
    // 行分隔线 rgba(255,255,255,.04)；最后一行不画
    .border({ width: { bottom: isLast ? 0 : 0.5 }, color: '#0AFFFFFF' })
    .onClick(() => {
      this.openAstronaut(c);
    })
  }

  /**
   * 乘组卡：**总是渲染**。
   *
   * 小程序是 `<view class="card">`（没有 v-if），0 人时标题仍写「乘组（0 人）」，
   * 下面一片空白、不给任何提示文案。旧版补了「暂无乘组信息」，属于多余。
   */
  @Builder
  crewCard() {
    Column() {
      Text('乘组（' + String(this.expCrew.length) + ' 人）')
        .fontSize(12)
        .fontColor(TITLE_COLOR)
        .width('100%')
        .margin({ bottom: 7 })

      ForEach(this.expCrew, (c: ExpCrew, index: number) => {
        this.crewRow(c, index === this.expCrew.length - 1)
      // key 带断头表长度：头像 onError 只改 @State，靠 key 变化重算占位分支
      }, (c: ExpCrew, index: number) => String(index) + '|' + String(c.id) + '#' + String(this.brokenAvatars.length))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: CARD_PAD_H, right: CARD_PAD_H, top: CARD_PAD_V, bottom: CARD_PAD_V })
    .backgroundColor(CARD)
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .margin({ top: CARD_GAP })
  }

  // ============ UI：页脚 ============

  @Builder
  footerHint() {
    Text('数据来源 The Space Devs')
      .fontSize(10)
      .fontColor(TEXT_FAINT)
      .width('100%')
      .textAlign(TextAlign.Center)
      // 48rpx = 24vp
      .margin({ top: 24, bottom: 6 })
  }

  // ============ UI：三态（纯文字） ============

  /**
   * 三态：小程序只有一行 `.hint-text`（13vp #6b7891，padding 200rpx 40rpx）。
   * 没有 spinner、没有 emoji、没有「返回」按钮 —— 返回键在顶栏里。
   * 网络失败与「id 不存在」共用同一句文案，但失败态整块可点 = 重试（隐形热区）。
   */
  @Builder
  hintBlock(text: string, tappable: boolean) {
    Column() {
      Text(text)
        .fontSize(13)
        .fontColor(TEXT_DIM)
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    // 200rpx 40rpx = 上 100vp、左右 20vp
    .padding({ top: 100, left: 20, right: 20 })
    .onClick(() => {
      if (tappable) {
        this.retry();
      }
    })
  }

  // ============ build ============

  build() {
    Column() {
      this.topBar()

      if (this.loading && !this.found) {
        this.hintBlock('加载中...', false)
      } else if (!this.found) {
        this.hintBlock('未找到该远征队', this.failed)
      } else {
        Scroll() {
          Column() {
            // head 通栏（自己带左右 16vp），卡片区各自带 margin，故这里不加内边距
            this.headBlock()

            if (this.patchList().length > 0) {
              this.patchCard()
            }

            this.crewCard()
            this.footerHint()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ bottom: BOTTOM_PAD })
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }
}
