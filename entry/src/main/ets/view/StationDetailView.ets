/**
 * view/StationDetailView.ets —— 空间站详情页
 *
 * 对位小程序 `pages/station/station.vue`（586 行）：Hero → KPI 四格 → 简介 →
 * 基本信息 → 所属机构 → 远征队 → 数据来源。
 *
 * 契约（由路由方以 `<StationDetailView stationId={id}>` 挂进 NavDestination）：
 *   @Prop stationId: string = '';   // 路由参数一律字符串，比对时 String(item.id) === stationId
 *   返回走 Nav.pop()，与 RocketDetailView / AgencyView 同口径。
 *
 * ── 数据链路（照抄 EventsView.ets:126-175 的写法）──
 *   repo.peek<StnPayload>('spacestations')   —— 同步、零网络，冷启动立刻上屏
 *   repo.load<StnPayload>('spacestations', { onUpdate }) —— 缓存过期时后台刷新
 *   找不到（String(s.id) !== this.stationId）是**独立**的 notFound 状态，
 *   与 failed（网络失败）严格分开 —— 见下面「三个空态」。
 *
 * ── 为什么不置 loaded ──
 *   repo.load 在「无缓存 + 网络失败」时是 reject。catch 里顺手把 loaded 置 true
 *   会让页面永久停在「未找到该空间站」，网络抖一下等于把这座站从库里删了
 *   （原项目踩过的永久空页坑）。这里用 found 表示「真的定位到了这条记录」，
 *   catch 只置 failed = !found。
 *
 * ── 三处「字段存在但内容全空」的实测结论（决定了哪些块不画）──
 *   1. img：15 条全为空串 → Hero 的 #1B2330 + 🛰️ 占位是**主路径**，不是兜底。
 *      仍保留 Image 分支与 onError，上游补图后自动生效。
 *   2. crew：15 条全是空数组 → **不做**「在站航天员」卡（做了必然是空块）。
 *   3. dockings 数据源实测不可用（vehicle / serial / agency / stationId 全空），
 *      → **不做**「对接记录」卡。小程序有这一块，但那批数据在鸿蒙侧是空的。
 *   KPI 四格因此只保留 onboardCrew / docked / volume / mass，且**逐个判 > 0**：
 *   0 在这份数据里确实大面积存在，画出来就是一屏「0」。
 *
 * ── 有意差异 ──
 *   · 状态 chip、类型、机构名都在视图侧做中文映射（utils/Format 的
 *     stationStatusZh 不认 'Decommissioned' / 'De-Orbited'，会原样回英文）；
 *   · 远征队只列名字与起止（内嵌条目没有 crew / patches），
 *     点击走成员回调 onOpenExpedition，跳转由父级接 —— 本组件不做路由。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。不使用 AppStorage / 定时器。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import {
  StnItem, StnPayload, StnOwner, StnExpedition,
  stnStr, stnNum, stnStatusText, stnIsActive, stnTypeText,
} from '../model/Station';
import {
  stationName, orbitName, agencyLabel, expeditionName, dayOf,
} from '../utils/Format';
import { Nav } from '../routes/Nav';

const DOMAIN: number = 0x0000;
const TAG: string = 'StationDetailView';

// ============ 视觉常量（工程约定） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const CARD_RADIUS: number = 12;
const CARD_PAD: number = 14;
const CARD_GAP: number = 15;

const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const TEXT_META: string = '#7A8598';
const ACCENT: string = '#38BDF8';
const ACTIVE_GREEN: string = '#34C759';
const IDLE_GRAY: string = '#55617A';
/** Hero 无图时的底色（任务书给定） */
const HERO_BG: string = '#1B2330';

/** Hero 高度（任务书 200vp） */
const HERO_H: number = 200;
/** 页面左右内边距（与 TodayView / RocketDetailView 的 12 对齐） */
const PAGE_PAD: number = 12;
/** 二级页底部留白 32（详情页里悬浮胶囊已被摘掉，不用让位 92） */
const BOTTOM_PAD: number = 32;
/** 区块标题 17vp Bold（工程约定） */
const SECTION_TITLE: number = 17;

/** 简介折叠 6 行；超过 120 字才给「展开全文」 */
const DESC_FOLD_LINES: number = 6;
const DESC_FOLD_CHARS: number = 120;

// ============ 局部类型（ArkTS 禁无类型对象字面量，一律 class） ============

/** KPI 一格 */
class StnKpi {
  label: string = '';
  value: string = '';

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/**
 * 参数表格的一格。
 *
 * 为什么右格不用 `StnSpecCell | null`：ArkTS 在 @Builder 调用参数上的收窄不可靠
 * （判过 null 之后传进去仍可能被判成可空类型）。改成「一定有一个 right + hasRight
 * 布尔」，类型上零可空，渲染时按布尔分支。
 */
class StnSpecCell {
  label: string = '';
  value: string = '';

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/** 参数表格的一行（两列） */
class StnSpecRow {
  left: StnSpecCell = new StnSpecCell('', '');
  right: StnSpecCell = new StnSpecCell('', '');
  hasRight: boolean = false;

  constructor(left: StnSpecCell, right: StnSpecCell, hasRight: boolean) {
    this.left = left;
    this.right = right;
    this.hasRight = hasRight;
  }
}

// ============ 纯函数（放 @Component 外面，避免每次重绘重建） ============

/** 数值 → 展示串：整数不带小数点，非整数保留 1 位（40 不该显示成 "40.0"） */
function stnOneDec(v: number): string {
  if (Number.isNaN(v)) {
    return '';
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
 * desc 实测带 \r\n；ArkUI 按真实换行排版，maxLines 既救不了也会让卡片里出现
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
  /** 图片加载失败 → 退回占位，避免破图占着 200vp */
  @State imgErr: boolean = false;

  /** KPI 四格（已过滤掉 0 值格） */
  @State kpis: StnKpi[] = [];
  /** 简介（descZh || desc，已压平换行） */
  @State desc: string = '';
  @State descExpanded: boolean = false;
  /** 参数表格行（逐行判空，空值整行不生成） */
  @State specs: StnSpecRow[] = [];
  /** 所属机构 */
  @State owners: StnOwner[] = [];
  /** 内嵌远征队 */
  @State expeditions: StnExpedition[] = [];

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
      // 首次就没命中则 found 保持 false，由 build() 落到 notFoundBlock。
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
    this.specs = this.buildSpecs(s);

    const own: StnOwner[] | undefined = s.owners;
    this.owners = own !== undefined ? own : [];

    const exp: StnExpedition[] | undefined = s.expeditions;
    this.expeditions = exp !== undefined ? exp : [];

    this.found = true;
    this.loading = false;
    this.failed = false;
  }

  private retry(): void {
    this.loadStation(true);
  }

  // ============ 派生：KPI 与参数表 ============

  /**
   * KPI 四格。**逐个判 > 0**：0 在这份数据里大面积存在（docked 常常是 0），
   * 画出来就是一屏「0」；空数组时整块不画。
   */
  private buildKpis(s: StnItem): StnKpi[] {
    const out: StnKpi[] = [];

    const crew: number = stnNum(s.onboardCrew);
    if (crew > 0) {
      out.push(new StnKpi('在轨人数', String(crew) + ' 人'));
    }

    const docked: number = stnNum(s.docked);
    if (docked > 0) {
      out.push(new StnKpi('对接飞船', String(docked) + ' 艘'));
    }

    const volume: number = stnNum(s.volume);
    if (volume > 0) {
      out.push(new StnKpi('加压体积', stnOneDec(volume) + ' m³'));
    }

    const mass: number = stnNum(s.mass);
    if (mass > 0) {
      out.push(new StnKpi('质量', stnOneDec(mass) + ' t'));
    }

    return out;
  }

  /** 参数表格：逐行判空，取不到的行整行不生成（不留「—」占位） */
  private buildSpecs(s: StnItem): StnSpecRow[] {
    const cells: StnSpecCell[] = [];

    const founded: string = stnDateOf(stnStr(s.founded));
    if (founded.length > 0) {
      cells.push(new StnSpecCell('成立日期', founded));
    }

    // 退役日期只有真有值才画：在役站这一行不该出现空白
    const deorbited: string = stnDateOf(stnStr(s.deorbited));
    if (deorbited.length > 0) {
      cells.push(new StnSpecCell('退役日期', deorbited));
    }

    const orbit: string = orbitName(stnStr(s.orbit)).trim();
    if (orbit.length > 0) {
      cells.push(new StnSpecCell('轨道', orbit));
    }

    const h: number = stnNum(s.height);
    if (h > 0) {
      cells.push(new StnSpecCell('高度', stnOneDec(h) + ' 米'));
    }

    const w: number = stnNum(s.width);
    if (w > 0) {
      cells.push(new StnSpecCell('宽度', stnOneDec(w) + ' 米'));
    }

    const type: string = stnTypeText(stnStr(s.type));
    if (type.length > 0) {
      cells.push(new StnSpecCell('类型', type));
    }

    return this.toRows(cells);
  }

  /** 一维格子按 2 个一行切；奇数末行 hasRight = false，渲染时补 Blank 占位 */
  private toRows(cells: StnSpecCell[]): StnSpecRow[] {
    const rows: StnSpecRow[] = [];
    for (let i = 0; i < cells.length; i = i + 2) {
      const hasRight: boolean = i + 1 < cells.length;
      const right: StnSpecCell = hasRight ? cells[i + 1] : new StnSpecCell('', '');
      rows.push(new StnSpecRow(cells[i], right, hasRight));
    }
    return rows;
  }

  // ============ 展示口径 ============

  /** 中文站名：查不到时回退英文原文 */
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
    return stnIsActive(this.status) ? ACTIVE_GREEN : IDLE_GRAY;
  }

  private statusFgOf(): string {
    return stnIsActive(this.status) ? BG_PRIMARY : TEXT_MAIN;
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
    return stnStr(o.abbrev).trim();
  }

  /** 机构缩写灰字（与机构名重复时不画） */
  private ownerAbbrevOf(o: StnOwner): string {
    const abbrev: string = stnStr(o.abbrev).trim();
    if (abbrev.length === 0) {
      return '';
    }
    return abbrev === this.ownerNameOf(o) ? '' : abbrev;
  }

  /** 远征队名：'Expedition 74' → '第 74 次远征' */
  private expNameOf(e: StnExpedition): string {
    const zh: string = expeditionName(stnStr(e.name)).trim();
    return zh.length > 0 ? zh : '未命名远征队';
  }

  /**
   * 远征队起止：'2024-03-15 → 进行中'。
   * end 为空 = 进行中（实测 3 条这样的记录），用绿色标出来；
   * 起点取不到就只显示右侧，不留一个孤零零的箭头。
   */
  private expRangeOf(e: StnExpedition): string {
    const start: string = stnDateOf(stnStr(e.start));
    const end: string = stnDateOf(stnStr(e.end));
    const endText: string = end.length > 0 ? end : '进行中';
    if (start.length === 0) {
      return endText;
    }
    return start + ' → ' + endText;
  }

  private expRunning(e: StnExpedition): boolean {
    return stnDateOf(stnStr(e.end)).length === 0;
  }

  // ============ 交互 ============

  private back(): void {
    Nav.pop();
  }

  private openExpedition(e: StnExpedition): void {
    this.onOpenExpedition(e);
  }

  // ============ UI：返回栏 ============

  /**
   * 自绘顶部栏。NavDestination 那边 hideTitleBar(true)，标题由这里画，
   * 这样「‹ 返回」的热区和字号都能自己定。
   */
  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹')
          .fontSize(20)
          .fontColor(TEXT_MAIN)
          .lineHeight(20)
        Text('返回')
          .fontSize(14)
          .fontColor(TEXT_SUB)
          .margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Center)
      // 上下各 10vp 把热区撑到约 40vp，别让 14vp 的字直接当可点区域
      .padding({ right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        this.back();
      })

      // 标题吃掉剩余宽度（等价于「标题 + Blank()」），站名过长才走省略号
      Text(this.titleText())
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 左右内边距已由根容器统一给 12，这里再加一次会变成 24，顶栏比卡片多缩进一截
    .backgroundColor(BG_PRIMARY)
  }

  // ============ UI：Hero ============

  @Builder
  hero() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 1 主图（或纯色块 + emoji）。实测 15 条 img 全空，占位是主路径
      if (this.img.length > 0 && !this.imgErr) {
        Image(this.img)
          .width('100%')
          .height(HERO_H)
          .objectFit(ImageFit.Cover)
          .backgroundColor(HERO_BG)
          .onError(() => {
            // 破图退回占位，比留一块 200vp 的空白好
            this.imgErr = true;
          })
      } else {
        Column() {
          Text('🛰️')
            .fontSize(48)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .height(HERO_H)
        .backgroundColor(HERO_BG)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      // 2 底部压黑层：白字压在任意亮度的图上都要可读（angle 0 = 从下往上）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 0,
          colors: [
            ['#D90A0E17', 0.0],
            ['#000A0E17', 0.75]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      // 3 左下站名 + 英文名；右下状态 chip
      Row() {
        Column() {
          Text(this.nameZhOf())
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          if (this.engNameOf().length > 0) {
            Text(this.engNameOf())
              .fontSize(11.5)
              .fontColor(TEXT_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 3 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.statusTextOf().length > 0) {
          Text(this.statusTextOf())
            .fontSize(10.5)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.statusFgOf())
            .backgroundColor(this.statusBgOf())
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(6)
            .margin({ left: 8 })
            .maxLines(1)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: CARD_PAD, right: CARD_PAD, bottom: 12 })
    }
    .width('100%')
    .height(HERO_H)
    // 圆角裁切用 clip：Stack 没有 overflow 属性
    .borderRadius(CARD_RADIUS)
    .clip(true)
  }

  // ============ UI：KPI 四格 ============

  @Builder
  kpiCell(cell: StnKpi) {
    Column() {
      Text(cell.value)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(cell.label)
        .fontSize(10.5)
        .fontColor(TEXT_META)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  kpiCard() {
    // KPI 个数不定（0 值格不画），用 Flex 折行：Row 没有 flexWrap，
    // 四个格子挤一行在窄屏上会把「419.7 t」压成两行。
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      ForEach(this.kpis, (cell: StnKpi) => {
        Column() {
          this.kpiCell(cell)
        }
        // 两列布局：每格占一半宽，1 格时独占一行也不会被拉到通栏
        .width('50%')
        .padding({ left: 2, right: 2 })
      }, (cell: StnKpi) => cell.label)
    }
    .width('100%')
    .padding({ top: 4, bottom: 4, left: 6, right: 6 })
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    // 区块间距 15vp 由卡片自己带：父级 Column 不给 space，
    // 这样条件渲染（某块没数据）时不会在中间留一个空槽，底部也不会多一截。
    .margin({ top: CARD_GAP })
  }

  // ============ UI：简介卡 ============

  @Builder
  descCard() {
    Column() {
      Text('简介')
        .fontSize(SECTION_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      Text(this.desc)
        .fontSize(13)
        .lineHeight(21)
        .fontColor(TEXT_SUB)
        .width('100%')
        .maxLines(this.descLines())
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 10 })

      if (this.canExpandDesc()) {
        Text(this.descExpanded ? '收起' : '展开全文')
          .fontSize(12)
          .fontColor(ACCENT)
          .margin({ top: 8 })
          .onClick(() => {
            this.descExpanded = !this.descExpanded;
          })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    // 间距由卡片自带，见 kpiCard 上方的说明
    .margin({ top: CARD_GAP })
  }

  // ============ UI：参数卡 ============

  @Builder
  specCell(cell: StnSpecCell) {
    Column() {
      Text(cell.value)
        .fontSize(13.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
        .lineHeight(19)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(cell.label)
        .fontSize(10.5)
        .fontColor(TEXT_DIM)
        .maxLines(1)
        .margin({ top: 3 })
        .width('100%')
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 7, bottom: 7 })
  }

  @Builder
  specCard() {
    Column() {
      Text('基本信息')
        .fontSize(SECTION_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      ForEach(this.specs, (row: StnSpecRow) => {
        Row() {
          this.specCell(row.left)
          if (row.hasRight) {
            this.specCell(row.right)
          } else {
            // 奇数个参数时末行右半留空，否则单格会被 layoutWeight 拉成通栏
            Blank()
              .layoutWeight(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (row: StnSpecRow) => row.left.label)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    // 间距由卡片自带，见 kpiCard 上方的说明
    .margin({ top: CARD_GAP })
  }

  // ============ UI：所属机构卡 ============

  @Builder
  ownerRow(o: StnOwner) {
    Row() {
      Text(this.ownerNameOf(o))
        .fontSize(13.5)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      if (this.ownerAbbrevOf(o).length > 0) {
        Text(this.ownerAbbrevOf(o))
          .fontSize(11)
          .fontColor(TEXT_DIM)
          .maxLines(1)
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  ownersCard() {
    Column() {
      Text(this.ownersTitle())
        .fontSize(SECTION_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      ForEach(this.owners, (o: StnOwner) => {
        this.ownerRow(o)
      }, (o: StnOwner, index: number) => String(index) + '|' + stnStr(o.name))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    // 间距由卡片自带，见 kpiCard 上方的说明
    .margin({ top: CARD_GAP })
  }

  // ============ UI：远征队卡 ============

  @Builder
  expeditionRow(e: StnExpedition) {
    Row() {
      Text(this.expNameOf(e))
        .fontSize(13.5)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Text(this.expRangeOf(e))
        .fontSize(11)
        .fontColor(this.expRunning(e) ? ACTIVE_GREEN : TEXT_DIM)
        .maxLines(1)
        .margin({ left: 8 })

      Text('›')
        .fontSize(15)
        .fontColor(TEXT_DIM)
        .margin({ left: 6 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 9, bottom: 9 })
    .onClick(() => {
      this.openExpedition(e);
    })
  }

  @Builder
  expeditionsCard() {
    Column() {
      Text('远征队')
        .fontSize(SECTION_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      ForEach(this.expeditions, (e: StnExpedition) => {
        this.expeditionRow(e)
      }, (e: StnExpedition, index: number) => String(index) + '|' + stnStr(e.name))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    // 间距由卡片自带，见 kpiCard 上方的说明
    .margin({ top: CARD_GAP })
  }

  // ============ UI：页脚 ============

  @Builder
  footer() {
    Text('数据来源 The Space Devs')
      .fontSize(11)
      .fontColor(TEXT_DIM)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ top: 18, bottom: 6 })
  }

  // ============ UI：三套占位 ============

  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ACCENT)
      Text('正在加载空间站…')
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
  notFoundBlock() {
    Column() {
      Text('未找到该空间站')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      Text(stnStr(this.stationId).trim().length > 0
        ? '（id ' + stnStr(this.stationId).trim() + '）'
        : '（未提供 id）')
        .fontSize(12)
        .fontColor(TEXT_DIM)
        .margin({ top: 8 })

      Row() {
        Text('‹ 返回')
          .fontSize(12.5)
          .fontColor(TEXT_SUB)
      }
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(CARD_BG)
      .margin({ top: 12 })
      .onClick(() => {
        this.back();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  @Builder
  failedBlock() {
    Column() {
      Text('空间站数据加载失败')
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
        Scroll(this.scroller) {
          Column() {
            // Hero 与内容同宽（根容器已有左右 12），视觉上像一张顶部大图卡
            this.hero()

            Column() {
              if (this.kpis.length > 0) {
                this.kpiCard()
              }
              if (this.desc.length > 0) {
                this.descCard()
              }
              if (this.specs.length > 0) {
                this.specCard()
              }
              if (this.owners.length > 0) {
                this.ownersCard()
              }
              if (this.expeditions.length > 0) {
                this.expeditionsCard()
              }
              this.footer()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            // 左右内边距由根容器统一给；上下间距由各卡片自带的 margin 负责
          }
          .width('100%')
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
    .backgroundColor(BG_PRIMARY)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
  }
}
