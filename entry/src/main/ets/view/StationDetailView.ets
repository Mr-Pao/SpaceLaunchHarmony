/**
 * view/StationDetailView.ets —— 空间站详情页
 *
 * 对位小程序 `pages/station/station.vue`（586 行）。结构顺序严格照抄：
 *   浮动 nav-bar（滚 160 后浮出标题）→ Hero 160vp → KPI 四格 → 简介 →
 *   **当前乘组** → 远征队 → 所属机构 → 页脚。
 *
 * ── 与旧版的四处结构性改动（都是「1:1」而不是「优化」）──
 *   1. Hero 从 200vp 降到 160vp，且**通栏不缩进、无圆角** —— 小程序 `.hero` 是
 *      铺满屏宽、`overflow:hidden` 但没写 border-radius。旧版把它包在 12vp 内边距里
 *      做成圆角大图卡，与小程序首屏对不上。
 *   2. 删除「基本信息」卡（成立/退役日期、轨道、高度、宽度、类型）—— 小程序**没有**
 *      这一块，这些字段它根本没渲染。多出来的卡会把「简介」往下顶一整屏。
 *   3. 补回「当前乘组」卡并做成可点跳航天员 —— 旧版以 crew 实测全空为由整块不做，
 *      但小程序是 `v-if="station.crew.length"`：空数组时它自然不显示，代码必须在。
 *      实测 15 条确实全空，所以这一版运行时同样看不到，但上游补数据就能直接出。
 *   4. 卡片圆角 12→10、内边距 14→13/14、加 1rpx 描边、标题 17vp 白 → 12vp #94a3b8。
 *
 * ── 为什么「对接记录」卡仍然不做（小程序有，这里没有）──
 *   它是 station.vue 里唯一依赖 dockings 数据集的块。鸿蒙侧该数据实测不可用：
 *   vehicle / serial / agency / stationId 全空，按 stationId 匹配恒为 0 条，
 *   做出来必然是「对接记录（近 0 次）」下面一片空。宁可整块不画，也不画一个必然空的标题。
 *
 * ── 数据链路（照抄 EventsView.ets:126-175 的写法）──
 *   repo.peek<StnPayload>('spacestations')   —— 同步、零网络，冷启动立刻上屏
 *   repo.load<StnPayload>('spacestations', { onUpdate }) —— 缓存过期时后台刷新
 *
 * ── 为什么不置 loaded ──
 *   repo.load 在「无缓存 + 网络失败」时是 reject。catch 里顺手把 loaded 置 true
 *   会让页面永久停在「未找到该空间站」，网络抖一下等于把这座站从库里删了
 *   （原项目踩过的永久空页坑）。这里用 found 表示「真的定位到了这条记录」。
 *
 * ── 三态 1:1（纯文字，无 spinner、无 emoji、无返回按钮）──
 *   小程序只有 `.hint-text`「加载中...」与 `.empty-text`「未找到该空间站」两行字。
 *   网络失败与「id 不存在」在小程序里**本来就是同一句文案**；这里照抄，
 *   但失败态整块可点 = 重试（隐形热区），否则弱网用户只能杀进程。
 *
 * ── 状态 / 类型文案在视图侧补映射 ──
 *   utils/Format 的 stationStatusZh 只认 Active / Retired / Under Construction，
 *   实测的 Decommissioned / De-Orbited 会原样回英文；映射收在 model/Station.ets
 *   的 stnStatusText()，列表与详情共用一份。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。不使用 AppStorage / 定时器。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import {
  StnItem, StnPayload, StnOwner, StnCrew, StnExpedition,
  stnStr, stnNum, stnStatusText, stnIsActive,
} from '../model/Station';
import {
  stationName, agencyLabel, expeditionName, dayOf,
} from '../utils/Format';
import { Nav } from '../routes/Nav';
import { AstronautNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'StationDetailView';

// ============ 视觉常量 ============
// 全部按小程序 rpx ÷ 2 折算（750rpx 设计稿 → 375vp）。

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
/** 卡片圆角 20rpx = 10vp */
const CARD_RADIUS: number = 10;
/** 卡片内边距 26rpx 28rpx = 上下 13 / 左右 14vp */
const CARD_PAD_V: number = 13;
const CARD_PAD_H: number = 14;
/** 卡间距 24rpx = 12vp */
const CARD_GAP: number = 12;
/** 卡片描边 1rpx rgba(255,255,255,.05) */
const CARD_BORDER: string = '#0DFFFFFF';

const TEXT_MAIN: string = '#FFFFFF';
/** 简介正文 / 机构名：小程序 #c6cfdd */
const TEXT_BODY: string = '#C6CFDD';
/** 次级灰：小程序 #6b7891 */
const TEXT_DIM: string = '#6B7891';
/** 卡片标题：小程序 #94a3b8 */
const TITLE_COLOR: string = '#94A3B8';
/** 箭头 / 页脚：小程序 #3d4a5c */
const TEXT_FAINT: string = '#3D4A5C';
const ACCENT: string = '#38BDF8';

/** 在役 chip：底 rgba(56,189,248,.18)=alpha 0x2E、字 #38bdf8 */
const CHIP_ON_BG: string = '#2E38BDF8';
const CHIP_ON_FG: string = '#38BDF8';
/** 其他状态 chip：底 rgba(255,255,255,.06)=alpha 0x0F、字 #55617a */
const CHIP_OFF_BG: string = '#0FFFFFFF';
const CHIP_OFF_FG: string = '#55617A';

/** Hero 无图时的底色（小程序 .hero-ph 背景 #141a26） */
const HERO_BG: string = '#141A26';
/** Hero 高度 320rpx = 160vp */
const HERO_H: number = 160;
/** Hero 文字区左右留白 32rpx = 16vp */
const PAGE_PAD: number = 16;
/** 二级页底部留白 32（悬浮胶囊已被摘掉，不用让位 92） */
const BOTTOM_PAD: number = 32;
/** 卡片标题 24rpx = 12vp */
const TITLE_SIZE: number = 12;
/** 顶栏高度：nav-bar.vue 的 .nav-inner 44px */
const NAV_H: number = 44;
/** 滚动超过 160 才浮出标题（station.vue 的 NAV_SOLID_SCROLL） */
const NAV_SOLID_Y: number = 160;
/** 顶栏实色：rgba(10,14,23,.96) → alpha 0xF5 */
const NAV_SOLID_BG: string = '#F50A0E17';

/** 简介：13vp、line-height 1.7（≈22vp）、最多折 4 行 */
const DESC_SIZE: number = 13;
const DESC_LINE_H: number = 22;
const DESC_FOLD_LINES: number = 4;
/**
 * 出不出「展开全文」的阈值。
 *
 * 小程序是 CSS `-webkit-line-clamp:4` 负责**折行**，另用 descNeedFoldOf（按字数 >120）
 * 决定要不要显示切换按钮。ArkTS 侧没有 onTextLayout / measureText 可用
 * （全工程 grep 0 命中），量不到真实行数，因此沿用同一套近似：
 * 折行交给 maxLines(DESC_FOLD_LINES)（行数语义一致），按钮出现与否看字数。
 */
const DESC_FOLD_CHARS: number = 120;

const AVATAR_SIZE: number = 40;
const AVATAR_EMOJI: string = '🧑‍🚀';

// ============ 局部类型（ArkTS 禁无类型对象字面量，一律 class） ============

/** KPI 一格：值纯数字，单位写在标签里 */
class Stn2Kpi {
  label: string = '';
  value: string = '';

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

// ============ 纯函数（放 @Component 外面，避免每次重绘重建） ============

/** 数值 → 展示串：整数不带小数点，非整数保留 1 位（40 不该显示成 "40.0"） */
function stnOneDec(v: number): string {
  if (Number.isNaN(v)) {
    return '0';
  }
  const r: number = Math.round(v * 10) / 10;
  if (r === Math.floor(r)) {
    return String(r);
  }
  return r.toFixed(1);
}

/**
 * 压平长文里的换行。
 *
 * desc 实测带 CRLF；ArkUI 按真实换行排版，maxLines 既救不了也会让卡片里出现
 * 莫名其妙的一行半空白。用 split/join 而不是正则：转义在 ArkTS 单引号串里容易写错
 * 且不报错，split 语义直白。
 */
function stnFlat(text: string): string {
  let s: string = stnStr(text).trim();
  s = s.split('\r\n').join(' ');
  s = s.split('\n').join(' ');
  s = s.split('\r').join(' ');
  s = s.split('\t').join(' ');
  let guard: number = 0;
  while (s.indexOf('  ') >= 0 && guard < 32) {
    s = s.split('  ').join(' ');
    guard++;
  }
  return s.trim();
}

/** 日期展示：优先按原串截 YYYY-MM-DD（dayOf 用正则、不构造 Date，避免东八区差一天） */
function stnDateOf(v: string): string {
  const raw: string = stnStr(v).trim();
  if (raw.length === 0) {
    return '';
  }
  const d: string = dayOf(raw);
  return d.length > 0 ? d : raw;
}

/** 字段是否存在（KPI 按「有字段就画」，0 也要画出来） */
function stnHas(v: number | undefined): boolean {
  return v !== undefined;
}

@Component
export struct StationDetailView {
  /** 路由参数：目标空间站 id（字符串形式） */
  @Prop stationId: string = '';

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，不挡返回栏） */
  @State loading: boolean = true;
  /** 是否定位到了这条记录。catch 里绝不置 true */
  @State found: boolean = false;
  /** 无缓存 + 网络失败。与「未找到」分开 */
  @State failed: boolean = false;

  /** 站名（英文原文；展示前过 stationName()） */
  @State name: string = '';
  @State status: string = '';
  @State img: string = '';
  /** 图片加载失败 → 退回占位，避免破图占着 160vp */
  @State imgErr: boolean = false;

  /** KPI 四格（**不**按 0 过滤，字段在就画） */
  @State kpis: Stn2Kpi[] = [];
  /** 简介（descZh || desc，已压平换行） */
  @State desc: string = '';
  @State descExpanded: boolean = false;
  /** 当前乘组（实测 15 条全空，空则整卡不画） */
  @State crew: StnCrew[] = [];
  /** 头像加载失败的乘员 id */
  @State brokenCrew: number[] = [];
  /** 所属机构 */
  @State owners: StnOwner[] = [];
  /** 机构 logo 加载失败的下标（logo 实测全空，正常不会触发） */
  @State brokenLogos: number[] = [];
  /** 内嵌远征队 */
  @State expeditions: StnExpedition[] = [];

  /** 顶栏是否已浮出实色 + 标题 */
  @State navSolid: boolean = false;

  /** 滚动容器 */
  private scroller: Scroller = new Scroller();

  /** 点击远征队：跳转由父级接（本组件不做路由） */
  onOpenExpedition: (item: StnExpedition) => void = () => {};

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadStation(false);
  }

  // ============ 加载 ============

  private loadStation(force: boolean): void {
    this.loading = true;
    this.failed = false;

    const cached: StnPayload | null = repo.peek<StnPayload>('spacestations');
    if (cached !== null) {
      this.applyPayload(cached);
      // 缓存里就找到了 → 立刻收掉 loading；没找到则先挂着，等网络回来再判
      if (this.found) {
        this.loading = false;
      }
    }

    const opts: LoadOptions<StnPayload> = {
      force: force,
      onCache: (data: StnPayload) => {
        this.applyPayload(data);
      },
      onUpdate: (data: StnPayload) => {
        this.applyPayload(data);
      }
    };

    repo.load<StnPayload>('spacestations', opts)
      .then((data: StnPayload) => {
        // 命中缓存时 resolve 给的就是缓存值，重复落地一次无害（幂等）
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经找到记录就别说失败，静默留在已有内容上
        this.failed = !this.found;
        hilog.warn(DOMAIN, TAG, 'spacestations 加载失败: %{public}s', e.message);
      });
  }

  /** 数据落地：定位记录 → 拆到各 @State */
  private applyPayload(data: StnPayload): void {
    const raw: StnItem[] | undefined = data.list;
    const list: StnItem[] = raw !== undefined ? raw : [];
    const hit: StnItem | null = this.findStation(list);

    if (hit === null) {
      // 已渲染过就保持原样：中途一次半截数据不该把整页打回「未找到」。
      // 首次就没命中则 found 保持 false，由 build() 落到三态。
      return;
    }
    this.applyStation(hit);
  }

  /** 按 id 定位。id 是数字、路由参数是字符串，统一转字符串比对 */
  private findStation(list: StnItem[]): StnItem | null {
    const target: string = stnStr(this.stationId).trim();
    if (target.length === 0) {
      return null;
    }
    for (let i = 0; i < list.length; i++) {
      const s: StnItem = list[i];
      if (String(s.id) === target) {
        return s;
      }
    }
    return null;
  }

  /** 一条记录 → 页面状态。所有字段都过一遍空值判定，不留 undefined 下去的缝 */
  private applyStation(s: StnItem): void {
    this.name = stnStr(s.name).trim();
    this.status = stnStr(s.status).trim();
    this.img = stnStr(s.img).trim();
    this.imgErr = false;

    const zh: string = stnFlat(stnStr(s.descZh));
    this.desc = zh.length > 0 ? zh : stnFlat(stnStr(s.desc));
    // 换了一条记录就收起，否则上一次的展开态会带过来
    this.descExpanded = false;

    this.kpis = this.buildKpis(s);

    const crew: StnCrew[] | undefined = s.crew;
    this.crew = crew !== undefined ? crew : [];
    this.brokenCrew = [];

    const own: StnOwner[] | undefined = s.owners;
    this.owners = own !== undefined ? own : [];
    this.brokenLogos = [];

    const exp: StnExpedition[] | undefined = s.expeditions;
    this.expeditions = exp !== undefined ? exp : [];

    this.found = true;
    this.loading = false;
    this.failed = false;
  }

  private retry(): void {
    this.loadStation(true);
  }

  // ============ 派生：KPI ============

  /**
   * KPI 四格。
   *
   * **只判字段存在、不判 > 0** —— 这一条和旧版相反，也是本页最实质的字段修正：
   * 小程序是 `v-if="station.onboardCrew"` 式的存在判断，0 会老老实实显示 `0`；
   * 旧版逐个 `> 0` 才生成，于是 docked=0 的站在真实数据里会少掉一整格，
   * 四格版式塌成三格、两格。
   * 单位按小程序写在标签里（`加压体积 m³` / `质量 t`），值只放数字。
   */
  private buildKpis(s: StnItem): Stn2Kpi[] {
    const out: Stn2Kpi[] = [];

    if (stnHas(s.onboardCrew)) {
      out.push(new Stn2Kpi('在轨人数', stnOneDec(stnNum(s.onboardCrew))));
    }
    if (stnHas(s.docked)) {
      out.push(new Stn2Kpi('对接飞船', stnOneDec(stnNum(s.docked))));
    }
    if (stnHas(s.volume)) {
      out.push(new Stn2Kpi('加压体积 m³', stnOneDec(stnNum(s.volume))));
    }
    if (stnHas(s.mass)) {
      out.push(new Stn2Kpi('质量 t', stnOneDec(stnNum(s.mass))));
    }

    return out;
  }

  // ============ 展示口径 ============

  /** 中文站名：查不到时回退「空间站详情」 */
  private nameZhOf(): string {
    const zh: string = stationName(this.name);
    return zh.length > 0 ? zh : '空间站详情';
  }

  /** 英文名：只有中文名与英文不同才显示（ISS → 国际空间站 + International Space Station） */
  private engNameOf(): string {
    return stationName(this.name) !== this.name ? this.name : '';
  }

  private statusTextOf(): string {
    return stnStatusText(this.status);
  }

  private statusBgOf(): string {
    return stnIsActive(this.status) ? CHIP_ON_BG : CHIP_OFF_BG;
  }

  private statusFgOf(): string {
    return stnIsActive(this.status) ? CHIP_ON_FG : CHIP_OFF_FG;
  }

  /** 顶栏标题：站名取不到时给一句兜底，别让顶栏空着 */
  private titleText(): string {
    const zh: string = this.nameZhOf();
    return zh.length > 0 ? zh : '空间站详情';
  }

  private canExpandDesc(): boolean {
    return this.desc.length > DESC_FOLD_CHARS;
  }

  private descLines(): number {
    // 展开态给一个足够大的行数（不写 Infinity，避免布局测量异常）
    return this.descExpanded ? 1000 : DESC_FOLD_LINES;
  }

  /** 乘组卡标题：小程序 `当前乘组（N 人）` */
  private crewTitle(): string {
    return '当前乘组（' + String(this.crew.length) + ' 人）';
  }

  /** 乘员名：没有中文专名表可用（crew 无 nation 字段），保留原名 */
  private crewNameOf(c: StnCrew): string {
    const n: string = stnStr(c.name).trim();
    return n.length > 0 ? n : '未知乘员';
  }

  /** 乘员副行：`{role} · {agency}`，**原样英文**（小程序就是这么显示的） */
  private crewMetaOf(c: StnCrew): string {
    const parts: string[] = [];
    const role: string = stnStr(c.role).trim();
    if (role.length > 0) {
      parts.push(role);
    }
    const agency: string = stnStr(c.agency).trim();
    if (agency.length > 0) {
      parts.push(agency);
    }
    return parts.join(' · ');
  }

  private crewImgOf(c: StnCrew): string {
    return stnStr(c.img).trim();
  }

  private crewImgBroken(c: StnCrew): boolean {
    const id: number | undefined = c.id;
    return id !== undefined && this.brokenCrew.indexOf(id) >= 0;
  }

  /** 机构卡标题：多家时带数量，让人一眼知道要往下看几行 */
  private ownersTitle(): string {
    if (this.owners.length > 1) {
      return '所属机构（' + String(this.owners.length) + ' 家）';
    }
    return '所属机构';
  }

  /** 机构名：agencyLabel 查表，查不到原样返回；再空则用缩写顶上 */
  private ownerNameOf(o: StnOwner): string {
    const name: string = agencyLabel(stnStr(o.name)).trim();
    if (name.length > 0) {
      return name;
    }
    const abbrev: string = stnStr(o.abbrev).trim();
    return abbrev.length > 0 ? abbrev : '未知机构';
  }

  private ownerLogoOf(o: StnOwner): string {
    return stnStr(o.logo).trim();
  }

  private logoBroken(index: number): boolean {
    return this.brokenLogos.indexOf(index) >= 0;
  }

  /** 远征队名：'Expedition 74' → '第 74 次远征' */
  private expNameOf(e: StnExpedition): string {
    const zh: string = expeditionName(stnStr(e.name)).trim();
    return zh.length > 0 ? zh : '未命名远征队';
  }

  /**
   * 远征队起止：`{start} — {end || '至今'}`。
   *
   * 分隔符是 em dash（—）不是箭头，结束缺省是「至今」不是「进行中」——
   * 两条都是小程序原文，改动会立刻在文案库里对不上。
   */
  private expRangeOf(e: StnExpedition): string {
    const start: string = stnDateOf(stnStr(e.start));
    const end: string = stnDateOf(stnStr(e.end));
    const endText: string = end.length > 0 ? end : '至今';
    if (start.length === 0) {
      return endText;
    }
    return start + ' — ' + endText;
  }

  // ============ 顶栏滚动状态 ============

  /**
   * 滚动时同步顶栏实色标记。
   *
   * 用 scroller.currentOffset() 取绝对偏移，而不是回调里的 scrollOffset 增量 ——
   * 增量在不同版本上有「本次位移」和「累计位移」两种解读，绝对偏移没有歧义。
   */
  private syncNavSolid(): void {
    // 不写 `: OffsetResult` 显式标注：它是 ArkUI 全局内置接口，交给推断更稳
    const off = this.scroller.currentOffset();
    const solid: boolean = off.yOffset > NAV_SOLID_Y;
    if (solid !== this.navSolid) {
      this.navSolid = solid;
    }
  }

  // ============ 交互 ============

  private back(): void {
    Nav.pop();
  }

  private openExpedition(e: StnExpedition): void {
    this.onOpenExpedition(e);
  }

  /**
   * 乘员行点击 → 宇航员详情。
   *
   * 小程序 `goAstro(m)` 走 `/pages/astronaut/astronaut?id=`，这里直接压路由。
   * 为什么不像远征队那样走父级回调：DetailPages.ets 里 StationDetailView 的入参
   * 是固定的 {stationId, onOpenExpedition}，本任务不允许改那个文件；多一个回调
   * 没处接，索性在视图内直接调 Nav（本文件本来就已 import Nav）。
   */
  private openAstronaut(c: StnCrew): void {
    const id: number | undefined = c.id;
    if (id === undefined) {
      // 没有 id 就进不去详情页（AstronautView 只会显示「未找到」），干脆不响应
      return;
    }
    Nav.pushAstronaut(new AstronautNavParam(String(id), stnStr(c.name)));
  }

  // ============ UI：浮动顶栏 ============

  /**
   * 自绘顶栏（对位 nav-bar.vue）。NavDestination 那边 hideTitleBar(true)，
   * 标题由这里画：滚过 160 之前全透明、只有圆形返回键；之后浮出实色条 + 居中标题。
   */
  @Builder
  navBar() {
    Row() {
      // 返回：半透明黑底圆形 + ‹；变实色后圆底去掉（nav-bar.vue 的 .nav.solid .nav-back）
      Row() {
        Text('‹')
          .fontSize(23)
          .fontColor(TEXT_MAIN)
          .lineHeight(23)
          .margin({ top: -2 })
      }
      .width(32)
      .height(32)
      .borderRadius(16)
      .backgroundColor(this.navSolid ? '#00000000' : '#52000000')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.back();
      })

      // 标题只在滚动变实色后出现 —— 透明时压在首图上，文字会与图打架
      Row() {
        if (this.navSolid && this.found) {
          Text(this.titleText())
            .fontSize(23)
            .fontWeight(600)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .textAlign(TextAlign.Center)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)

      // 右侧占位 32，标题才是真正居中（不是「剩余空间居中」）
      Row()
        .width(32)
    }
    .width('100%')
    .height(NAV_H)
    .alignItems(VerticalAlign.Center)
    .padding({ left: 10, right: 10 })
    .backgroundColor(this.navSolid ? NAV_SOLID_BG : '#00000000')
    .border({ width: { bottom: this.navSolid ? 0.5 : 0 }, color: '#0DFFFFFF' })
  }

  // ============ UI：Hero ============

  /**
   * 首图区：320rpx=160vp、**通栏**、无圆角（对位 `.hero`）。
   *
   * 三层：图（或 #141a26 + 🛰️）→ 自下而上的压黑带 → 左下站名/英文名 + 右侧状态 chip。
   * 渐变对位 `linear-gradient(to top, #0a0e17 0%, rgba(10,14,23,.2) 60%, transparent 100%)`；
   * ArkUI 里 `angle: 0` 就是「从下往上」，三个色标按 0 / 0.6 / 1.0 落位。
   */
  @Builder
  hero() {
    Stack({ alignContent: Alignment.BottomStart }) {
      if (this.img.length > 0 && !this.imgErr) {
        Image(this.img)
          .width('100%')
          .height(HERO_H)
          .objectFit(ImageFit.Cover)
          .backgroundColor(HERO_BG)
          .onError(() => {
            // 破图退回占位，比留一块 160vp 的空白好
            this.imgErr = true;
          })
      } else {
        // 实测 15 条 img 全空，这里才是主路径
        Column() {
          Text('🛰️')
            .fontSize(60)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height(HERO_H)
        .backgroundColor(HERO_BG)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      // 压黑带：白字压在任意亮度的图上都要可读
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 0,
          colors: [
            ['#FF0A0E17', 0.0],
            ['#330A0E17', 0.6],
            ['#000A0E17', 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      // 左下站名 + 英文名；右侧状态 chip
      Row() {
        Column() {
          Text(this.nameZhOf())
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.engNameOf().length > 0) {
            Text(this.engNameOf())
              .fontSize(10)
              .fontColor('#9EFFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.statusTextOf().length > 0) {
          Text(this.statusTextOf())
            .fontSize(10)
            .fontColor(this.statusFgOf())
            .backgroundColor(this.statusBgOf())
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .borderRadius(3)
            .margin({ left: 7 })
            .maxLines(1)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: 12 })
    }
    .width('100%')
    .height(HERO_H)
    // 通栏不加圆角：小程序 .hero 没有 border-radius，只有 overflow:hidden。
    // 图片按 Cover 铺满，超出部分靠 clip 收掉（Stack 没有 overflow 属性）
    .clip(true)
  }

  // ============ UI：KPI ============

  @Builder
  kpiCell(cell: Stn2Kpi) {
    Column() {
      Text(cell.value)
        .fontSize(15)
        .fontWeight(600)
        .fontColor(ACCENT)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(cell.label)
        .fontSize(9.5)
        .fontColor(TEXT_DIM)
        .maxLines(1)
        .margin({ top: 3 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  kpiCard() {
    // 四格一行等分：Row + 每格 layoutWeight(1)，等价于小程序的 `display:flex; .kpi-cell{flex:1}`
    Row() {
      ForEach(this.kpis, (cell: Stn2Kpi) => {
        this.kpiCell(cell)
      }, (cell: Stn2Kpi) => cell.label)
    }
    .width('100%')
    .padding({ top: 11, bottom: 11 })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    // 区块间距由卡片自带：条件渲染（某块没数据）时不会在中间留一个空槽
    .margin({ top: CARD_GAP })
  }

  // ============ UI：简介 ============

  @Builder
  descCard() {
    Column() {
      Text('简介')
        .fontSize(TITLE_SIZE)
        .fontColor(TITLE_COLOR)
        .width('100%')

      Text(this.desc)
        .fontSize(DESC_SIZE)
        .lineHeight(DESC_LINE_H)
        .fontColor(TEXT_BODY)
        .width('100%')
        .maxLines(this.descLines())
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 7 })

      if (this.canExpandDesc()) {
        Text(this.descExpanded ? '收起' : '展开全文')
          .fontSize(12)
          .fontColor(ACCENT)
          .margin({ top: 6 })
          .onClick(() => {
            this.descExpanded = !this.descExpanded;
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CARD_PAD_V, bottom: CARD_PAD_V, left: CARD_PAD_H, right: CARD_PAD_H })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .margin({ top: CARD_GAP })
  }

  // ============ UI：当前乘组 ============

  @Builder
  crewRow(c: StnCrew, isLast: boolean) {
    Row() {
      if (this.crewImgOf(c).length > 0 && !this.crewImgBroken(c)) {
        Image(this.crewImgOf(c))
          .width(AVATAR_SIZE)
          .height(AVATAR_SIZE)
          .borderRadius(AVATAR_SIZE / 2)
          .objectFit(ImageFit.Cover)
          // 小程序 .avatar 背景是页面底色 #0a0e17
          .backgroundColor(BG_PRIMARY)
          .onError(() => {
            const id: number | undefined = c.id;
            if (id !== undefined) {
              this.brokenCrew = this.brokenCrew.concat([id]);
            }
          })
      } else {
        Column() {
          Text(AVATAR_EMOJI)
            .fontSize(18)
        }
        .width(AVATAR_SIZE)
        .height(AVATAR_SIZE)
        .borderRadius(AVATAR_SIZE / 2)
        .backgroundColor(BG_PRIMARY)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      Column() {
        Text(this.crewNameOf(c))
          .fontSize(13.5)
          .fontColor('#E2E8F0')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.crewMetaOf(c).length > 0) {
          Text(this.crewMetaOf(c))
            .fontSize(10.5)
            .fontColor(TEXT_DIM)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })

      Text('›')
        .fontSize(16)
        .fontColor(TEXT_FAINT)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 7, bottom: 7 })
    // 行分隔线 rgba(255,255,255,.04)；最后一行不画
    .border({ width: { bottom: isLast ? 0 : 0.5 }, color: '#0AFFFFFF' })
    .onClick(() => {
      this.openAstronaut(c);
    })
  }

  @Builder
  crewCard() {
    Column() {
      Text(this.crewTitle())
        .fontSize(TITLE_SIZE)
        .fontColor(TITLE_COLOR)
        .width('100%')

      ForEach(this.crew, (c: StnCrew, index: number) => {
        this.crewRow(c, index === this.crew.length - 1)
      // key 带上 brokenCrew 长度：头像 onError 只改 @State 数组，
      // @Builder 按值传参不会重建，靠 key 变化强制重算占位分支
      }, (c: StnCrew, index: number) => String(index) + '|' + String(c.id) + '#' + String(this.brokenCrew.length))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CARD_PAD_V, bottom: 6, left: CARD_PAD_H, right: CARD_PAD_H })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .margin({ top: CARD_GAP })
  }

  // ============ UI：远征队 ============

  @Builder
  expeditionRow(e: StnExpedition, isLast: boolean) {
    Row() {
      Column() {
        // 竖排两行：名称一行、起止一行（旧版把两者挤在同一行左右排，与小程序不符）
        Text(this.expNameOf(e))
          .fontSize(13.5)
          .fontColor('#E2E8F0')
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.expRangeOf(e))
          .fontSize(10.5)
          .fontColor(TEXT_DIM)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(16)
        .fontColor(TEXT_FAINT)
        .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 7, bottom: 7 })
    .border({ width: { bottom: isLast ? 0 : 0.5 }, color: '#0AFFFFFF' })
    .onClick(() => {
      this.openExpedition(e);
    })
  }

  @Builder
  expeditionsCard() {
    Column() {
      Text('远征队')
        .fontSize(TITLE_SIZE)
        .fontColor(TITLE_COLOR)
        .width('100%')

      ForEach(this.expeditions, (e: StnExpedition, index: number) => {
        this.expeditionRow(e, index === this.expeditions.length - 1)
      }, (e: StnExpedition, index: number) => String(index) + '|' + stnStr(e.name))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CARD_PAD_V, bottom: 6, left: CARD_PAD_H, right: CARD_PAD_H })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .margin({ top: CARD_GAP })
  }

  // ============ UI：所属机构（胶囊 + logo） ============

  @Builder
  ownerChip(o: StnOwner, index: number) {
    Row() {
      if (this.ownerLogoOf(o).length > 0 && !this.logoBroken(index)) {
        Image(this.ownerLogoOf(o))
          .width(18)
          .height(18)
          .borderRadius(3)
          .objectFit(ImageFit.Contain)
          .backgroundColor(BG_PRIMARY)
          .margin({ right: 5 })
          .onError(() => {
            this.brokenLogos = this.brokenLogos.concat([index]);
          })
      }

      Text(this.ownerNameOf(o))
        .fontSize(11)
        .fontColor(TEXT_BODY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    // 胶囊：padding 8rpx 14rpx = 4/7vp、radius 10rpx = 5vp、底 rgba(255,255,255,.04)
    .padding({ left: 7, right: 7, top: 4, bottom: 4 })
    .borderRadius(5)
    .backgroundColor('#0AFFFFFF')
  }

  @Builder
  ownersCard() {
    Column() {
      Text(this.ownersTitle())
        .fontSize(TITLE_SIZE)
        .fontColor(TITLE_COLOR)
        .width('100%')

      // Row 没有 flexWrap，折行必须用 Flex + FlexWrap.Wrap；gap 16rpx = 8vp
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start, alignItems: ItemAlign.Center }) {
        ForEach(this.owners, (o: StnOwner, index: number) => {
          Column() {
            this.ownerChip(o, index)
          }
          .margin({ right: 8, top: 8 })
        }, (o: StnOwner, index: number) => String(index) + '|' + stnStr(o.name) + '#' + String(this.brokenLogos.length))
      }
      .width('100%')
      .margin({ top: -8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: CARD_PAD_V, bottom: CARD_PAD_V, left: CARD_PAD_H, right: CARD_PAD_H })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .border({ width: 0.5, color: CARD_BORDER })
    .margin({ top: CARD_GAP })
  }

  // ============ UI：页脚 ============

  @Builder
  footer() {
    Text('数据来源 The Space Devs')
      .fontSize(10)
      .fontColor(TEXT_FAINT)
      .width('100%')
      .textAlign(TextAlign.Center)
      // 48rpx = 24vp
      .margin({ top: 24, bottom: 6 })
  }

  // ============ UI：三态（纯文字） ============

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
    // 小程序 `padding:200rpx 40rpx` = 上 100vp、左右 20vp
    .padding({ top: 100, left: 20, right: 20 })
    .onClick(() => {
      if (tappable) {
        this.retry();
      }
    })
  }

  // ============ build ============

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.loading && !this.found) {
        Column() {
          this.hintBlock('加载中...', false)
        }
        .width('100%')
        .height('100%')
      } else if (!this.found) {
        // 网络失败与「id 不存在」在小程序里是同一句文案，这里统一（失败态可点重试）
        Column() {
          this.hintBlock('未找到该空间站', this.failed)
        }
        .width('100%')
        .height('100%')
      } else {
        Scroll(this.scroller) {
          Column() {
            // Hero 通栏：左右内边距只给下面的卡片，hero 自己贴边
            this.hero()

            Column() {
              if (this.kpis.length > 0) {
                this.kpiCard()
              }
              if (this.desc.length > 0) {
                this.descCard()
              }
              if (this.crew.length > 0) {
                this.crewCard()
              }
              if (this.expeditions.length > 0) {
                this.expeditionsCard()
              }
              if (this.owners.length > 0) {
                this.ownersCard()
              }
              this.footer()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: PAGE_PAD, right: PAGE_PAD })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ bottom: BOTTOM_PAD })
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        // 滚动驱动顶栏变实色。零参 lambda 规避 Scroll 回调签名差异
        .onDidScroll(() => {
          this.syncNavSolid();
        })
      }

      // 固定顶栏：压在 hero 上、不占文档流（最后画 = 最上层）
      this.navBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }
}
