/**
 * view/RocketDetailView.ets —— 火箭详情页（对位小程序 pages/rocket/rocket.vue）
 *
 * 数据来源（2026-11-02 实测 launchers.json，v=14 / count=532 / 36 个键）：
 *   小程序 page/rocket 是「spaceData.load('launchers') 拿全量 532 条 → 按 id 找」，
 *   鸿蒙侧暂时没有 launchers 的 model，所以本文件自带 Rk* 类型。
 *
 *   为什么**不复用** model/Common.ets 的 RocketBrief：
 *     1) 字段名不同 —— launchers.json 是 `description` / `descriptionZh`，
 *        RocketBrief 是 `desc`（CI 的 toBrief() 会改名并截断到 260 字）；
 *     2) launchers 还带 total_launch_count / successful_launches / pads 等
 *        20 个 RocketBrief 里没有的字段，用 RocketBrief 断言会丢字段（虽然运行时
 *        JSON.parse 的属性都在，但类型层面读不到，等于逼人写 any）；
 *     3) 按任务书「新增类型名统一加前缀 Rk」的约定，这里定义 RkLauncher 最干净。
 *
 * 数据链路（与 TodayView 同口径：先上缓存再静默刷新，谁先到谁先渲染）：
 *   repo.peek<RkLaunchersPayload>('launchers')  —— 同步、零网络，冷启动立刻有内容
 *   repo.load<RkLaunchersPayload>('launchers')  —— 后台刷新，onUpdate 回填
 *
 * 有意取舍（逐条写清，方便复核）：
 *   1. **定位先精确、后忽略大小写**。调用方（DetailPages）传进来的 name 来自
 *      LL2 的 rocket.configuration.name，理论上与 launchers 的 name 一致；
 *      但上游偶尔会把 "Falcon 9" 写成 "falcon 9"，所以第二遍用 toLowerCase 兜底。
 *   2. **副标题只在 full_name 与 name 不同时显示**。launchers 里绝大多数记录的
 *      full_name === name（实测 Angara 1.2 / Angara 1.2），照抄会在大字下面
 *      再重复一遍同样的字。
 *   3. **后端没数据 ≠ 没找到**。repo.load 在「无缓存 + 网络失败」时是 reject
 *      （原项目踩过：catch 里置 xLoaded=true 会变成永久空页），所以这里用
 *      failed 单独出一个「加载失败 + 重试」，不与「未找到该火箭型号」混为一谈。
 *   4. **参数格按「值无效就整格不画」过滤**，绝不出现 undefined / NaN / 0 值格。
 *      0 在这份数据里确实存在（pending_launches、attempted_landings 大面积是 0），
 *      拿 0 当「有值」会看到一屏「0」。
 *   5. **简介优先 descriptionZh**。CI 的 descriptionZh 是机翻，但小程序详情页
 *      同样优先中文；翻不出来时 CI 留空串，这里会自然回退英文。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。不使用 AppStorage。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { strOf } from '../utils/Format';
import { Nav } from '../routes/Nav';
import { PhotoNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'RocketDetailView';

// ============ 视觉常量（工程约定） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const CARD_RADIUS: number = 12;
const CARD_PAD: number = 14;
const CARD_GAP: number = 10;

const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
const ACTIVE_GREEN: string = '#34C759';
const RETIRED_GRAY: string = '#55617A';

/** Hero 高度（任务书 200vp） */
const HERO_H: number = 200;
/** 页面左右内边距（与 TodayView 的 12 对齐） */
const PAGE_PAD: number = 12;
/** 详情页不在 tab 内，不留 92 的胶囊让位 */
const BOTTOM_PAD: number = 32;

/** 简介折叠行数 */
const DESC_FOLD_LINES: number = 4;
/**
 * 「展开全文」的显示阈值（字符数）。
 * ArkUI 拿不到 Text 实际行数（onTextLayout 不在本工程既有写法里用过），
 * 只能用字符数粗判：正文 13vp 在 343vp 宽下约 26 个汉字 / 行，
 * 4 行约 104 字；留一点余量取 80，宁可多给一个无效的「展开」也不藏掉内容。
 */
const DESC_HINT_MIN: number = 80;

// ============ 类型（launchers.json 真实结构） ============

/**
 * launchers.json 的单条记录。
 *
 * 字段清单来自 2026-11-02 的线上快照（第一条 Angara 1.2，共 36 个键）。
 * 全部可选：上游对不同型号的缺字段情况很普遍（gto_capacity / geo_capacity /
 * launch_cost / fastest_turnaround 都可能为 null）。
 */
export interface RkLauncher {
  /** LL2 数字 id */
  id?: number;
  /** 型号名，如 "Falcon 9 Block 5" */
  name?: string;
  /** 全名，多数记录与 name 相同 */
  full_name?: string;
  /** 变体，如 "Block 5" / "1.2" */
  variant?: string;
  /** 所属系列，如 ["Falcon", "Falcon 9"] */
  families?: string[];
  manufacturer?: string;

  // ---- 尺寸与运力（LL2 单位：length/diameter 米，mass 吨，thrust 千牛，运力 千克）----
  length?: number;
  diameter?: number;
  launch_mass?: number;
  to_thrust?: number;
  leo_capacity?: number;
  gto_capacity?: number;
  geo_capacity?: number;
  sso_capacity?: number;

  /** 首飞日期，形如 "2014-07-09" */
  maiden_flight?: string;
  min_stage?: number;
  max_stage?: number;
  /** 单次造价（美元），可能为 null */
  launch_cost?: number | null;

  reusable?: boolean;
  active?: boolean;

  // ---- 累计统计（本页暂未展示，留作后续「发射记录」模块）----
  total_launch_count?: number;
  successful_launches?: number;
  failed_launches?: number;
  pending_launches?: number;
  consecutive_successful_launches?: number;
  attempted_landings?: number;
  successful_landings?: number;
  failed_landings?: number;
  consecutive_successful_landings?: number;
  fastest_turnaround?: number | null;

  /** 英文简介（原文） */
  description?: string;
  /** 中文简介（CI 机翻，翻不出来是空串） */
  descriptionZh?: string;

  image?: string;
  info_url?: string;
  wiki_url?: string;
  /** 发射工位引用（本页未展示） */
  pads?: RkPadRef[];
}

/** launchers 里 pads 的单项：{ name, location, count } */
export interface RkPadRef {
  name?: string;
  location?: string;
  count?: number;
}

/**
 * launchers 数据集信封。
 * 与 model/Common.ets 的 ListPayload<T> 同形，但 list 这里声明为可选：
 * 旧缓存或上游异常时可能没有 list，页面必须能兜住。
 */
export interface RkLaunchersPayload {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  count?: number;
  served?: number;
  list?: RkLauncher[];
}

// ============ 参数格（ArkTS 禁止无类型对象字面量，先建 class 再 new） ============

/** 一个参数格：11vp 灰标签 + 14vp 粗体值 */
class RkSpecCell {
  label: string = '';
  value: string = '';
  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/**
 * 两列网格的一行。
 *
 * 右侧为什么不用 `RkSpecCell | null`：ArkTS 的收窄在 @Builder 调用参数上不可靠
 * （`row.right !== null` 之后传 `row.right` 仍可能被判成可空类型而编译失败）。
 * 这里改成「一定有一个 right 对象 + hasRight 布尔」，渲染时按布尔分支，类型上零可空。
 */
class RkSpecRow {
  left: RkSpecCell = new RkSpecCell('', '');
  right: RkSpecCell = new RkSpecCell('', '');
  /** 这一行右侧是否真有参数（奇数个参数时末行为 false） */
  hasRight: boolean = false;
  constructor(left: RkSpecCell, right: RkSpecCell, hasRight: boolean) {
    this.left = left;
    this.right = right;
    this.hasRight = hasRight;
  }
}

@Component
export struct RocketDetailView {
  /** 火箭型号名（DetailPages 从 RocketNavParam.name 传进来） */
  @Prop rocketName: string = '';

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，不挡返回栏） */
  @State loading: boolean = true;
  /** 是否拿到了这条记录 */
  @State found: boolean = false;
  /** 加载失败（无缓存 + 网络失败）。与「未找到」分开，见文件头取舍 3 */
  @State failed: boolean = false;

  /** 展示用型号名（优先数据里的 name，缺了回退 prop） */
  @State name: string = '';
  /** 英文全名（与 name 相同时不显示，见取舍 2） */
  @State fullName: string = '';
  /** Hero 图 */
  @State image: string = '';
  /** 图片加载失败 → 退回纯色块，避免破图占着 200vp */
  @State imgErr: boolean = false;
  /** 现役 / 已退役 */
  @State active: boolean = false;

  // ---- 特点标签三件套 ----
  @State reusable: boolean = false;
  @State maxStage: number = 0;
  @State variant: string = '';

  /** 简介（descriptionZh || description） */
  @State desc: string = '';
  /** 简介是否已展开 */
  @State descExpanded: boolean = false;

  /** 参数格（已按「值无效就跳过」过滤，两列成行） */
  @State specs: RkSpecRow[] = [];

  /** 滚动容器 */
  private scroller: Scroller = new Scroller();

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadLauncher(false);
  }

  // ============ 加载 ============

  /**
   * 先 peek 再 load（与 MineView.loadLastSync 同一套写法）：
   *   peek 只查内存 + 文件、绝不发网络，冷启动能立刻把详情画出来；
   *   随后 load 走正常链路，命中过期缓存时由 onUpdate 把新数据补上屏。
   */
  private loadLauncher(force: boolean): void {
    this.loading = true;
    this.failed = false;

    const cached: RkLaunchersPayload | null = repo.peek<RkLaunchersPayload>('launchers');
    if (cached !== null) {
      this.applyPayload(cached);
      // 缓存里就找到了 → 立刻收掉 loading；没找到则先挂着，等网络回来再判
      if (this.found) {
        this.loading = false;
      }
    }

    const opts: LoadOptions<RkLaunchersPayload> = {
      force: force,
      onUpdate: (fresh: RkLaunchersPayload) => {
        this.applyPayload(fresh);
      }
    };

    repo.load<RkLaunchersPayload>('launchers', opts)
      .then((data: RkLaunchersPayload) => {
        // load 的 resolve 在「命中缓存」时给的就是缓存值，重复落地一次无害（幂等）
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有缓存内容就别说「失败」，静默留在已有页面上
        this.failed = !this.found;
        hilog.warn(DOMAIN, TAG, 'launchers 加载失败: %{public}s', e.message);
      });
  }

  /** 数据落地：找记录 → 拆到各个 @State */
  private applyPayload(data: RkLaunchersPayload): void {
    const raw: RkLauncher[] = data.list !== undefined ? data.list : [];
    const hit: RkLauncher | null = this.findLauncher(raw);

    if (hit === null) {
      // 已渲染过就保持原样：中途一次半截数据不该把整页打回「未找到」
      if (!this.found) {
        this.found = false;
      }
      return;
    }
    this.applyLauncher(hit);
  }

  /**
   * 定位型号：先精确匹配 name / full_name，再忽略大小写与首尾空格来一遍。
   * 两遍都空 → null（调用方据此显示「未找到该火箭型号」）。
   */
  private findLauncher(list: RkLauncher[]): RkLauncher | null {
    const target: string = strOf(this.rocketName).trim();
    if (target.length === 0) {
      return null;
    }

    const exact: RkLauncher | undefined =
      list.find((x: RkLauncher) => strOf(x.name) === target || strOf(x.full_name) === target);
    if (exact !== undefined) {
      return exact;
    }

    const lower: string = target.toLowerCase();
    const loose: RkLauncher | undefined = list.find((x: RkLauncher) => {
      const n: string = strOf(x.name).trim().toLowerCase();
      const f: string = strOf(x.full_name).trim().toLowerCase();
      return n === lower || f === lower;
    });
    return loose !== undefined ? loose : null;
  }

  /** 一条记录 → 页面状态。所有字段都过一遍空值判定，不留 undefined 下去的缝 */
  private applyLauncher(x: RkLauncher): void {
    this.name = strOf(x.name).trim();
    if (this.name.length === 0) {
      this.name = strOf(this.rocketName).trim();
    }

    const full: string = strOf(x.full_name).trim();
    this.fullName = full === this.name ? '' : full;

    this.image = strOf(x.image).trim();
    this.imgErr = false;
    this.active = x.active === true;

    this.reusable = x.reusable === true;
    this.maxStage = x.max_stage !== undefined ? x.max_stage : 0;
    this.variant = strOf(x.variant).trim();

    const zh: string = strOf(x.descriptionZh).trim();
    this.desc = zh.length > 0 ? zh : strOf(x.description).trim();
    // 换了型号就收起，否则上一次的展开态会带过来
    this.descExpanded = false;

    this.specs = this.buildSpecs(x);
    this.found = true;
    this.loading = false;
    this.failed = false;
  }

  // ============ 数值格式化 ============

  /**
   * 数字转展示串：整数不带小数点，非整数保留 1 位。
   * 不用 toFixed 一刀切 —— 40 会变成 "40.0"，在「长度 40 米」里很别扭。
   */
  private oneDec(v: number): string {
    // 只判 NaN：Infinity 在这份数据里不存在，而 ArkTS 对 Infinity 全局常量的
    // 可用性不保证（Number.isFinite 同样没有稳定声明），少一个不确定点
    if (Number.isNaN(v)) {
      return '';
    }
    const r: number = Math.round(v * 10) / 10;
    if (r === Math.floor(r)) {
      return String(r);
    }
    return r.toFixed(1);
  }

  /** 千分位：1920 → "1,920"。参数值动辄四五位，不分位读起来要数零 */
  private commaOf(n: number): string {
    const s: string = String(Math.round(n));
    let out: string = '';
    let count: number = 0;
    for (let i = s.length - 1; i >= 0; i--) {
      out = s.charAt(i) + out;
      count = count + 1;
      if (count % 3 === 0 && i > 0) {
        out = ',' + out;
      }
    }
    return out;
  }

  /**
   * 运力换算（任务书：≥1000 用吨并保留 1 位小数，否则千克）。
   * LL2 的 leo_capacity / gto_capacity 单位是千克。
   */
  private capacityText(v: number): string {
    if (v >= 1000) {
      return this.oneDec(v / 1000) + ' 吨';
    }
    return this.commaOf(v) + ' 千克';
  }

  /** 造价（美元）→ 亿美元 / 万美元。31_000_000 直接写出来没人愿意读 */
  private costText(v: number): string {
    if (v >= 100000000) {
      return this.oneDec(v / 100000000) + ' 亿美元';
    }
    return this.commaOf(v / 10000) + ' 万美元';
  }

  /**
   * 首飞日期只留 YYYY-MM-DD。
   * 数据本身就是 "2014-07-09"，但保险起见按 10 位截断，避免哪天上游塞进时分。
   */
  private dateText(v: string): string {
    return v.length >= 10 ? v.slice(0, 10) : v;
  }

  // ============ 参数格组装 ============

  /** 单格收集：值无效（undefined / null / 0 / 空串）就直接不进列表 */
  private buildSpecs(x: RkLauncher): RkSpecRow[] {
    const cells: RkSpecCell[] = [];

    const thrust: number | undefined = x.to_thrust;
    if (thrust !== undefined && thrust > 0) {
      cells.push(new RkSpecCell('起飞推力', this.commaOf(thrust) + ' 千牛'));
    }

    const len: number | undefined = x.length;
    if (len !== undefined && len > 0) {
      cells.push(new RkSpecCell('长度', this.oneDec(len) + ' 米'));
    }

    const dia: number | undefined = x.diameter;
    if (dia !== undefined && dia > 0) {
      cells.push(new RkSpecCell('直径', this.oneDec(dia) + ' 米'));
    }

    const stage: number | undefined = x.max_stage;
    if (stage !== undefined && stage > 0) {
      cells.push(new RkSpecCell('级数', String(stage) + ' 级'));
    }

    const leo: number | undefined = x.leo_capacity;
    if (leo !== undefined && leo > 0) {
      cells.push(new RkSpecCell('LEO 运力', this.capacityText(leo)));
    }

    const gto: number | undefined = x.gto_capacity;
    if (gto !== undefined && gto > 0) {
      cells.push(new RkSpecCell('GTO 运力', this.capacityText(gto)));
    }

    const mass: number | undefined = x.launch_mass;
    if (mass !== undefined && mass > 0) {
      cells.push(new RkSpecCell('起飞质量', this.oneDec(mass) + ' 吨'));
    }

    // launch_cost 可能显式为 null（LL2 对部分型号没填），两个都要判
    const cost: number | null | undefined = x.launch_cost;
    if (cost !== undefined && cost !== null && cost > 0) {
      cells.push(new RkSpecCell('单次造价', this.costText(cost)));
    }

    const maiden: string = strOf(x.maiden_flight).trim();
    if (maiden.length > 0) {
      cells.push(new RkSpecCell('首飞', this.dateText(maiden)));
    }

    const maker: string = strOf(x.manufacturer).trim();
    if (maker.length > 0) {
      cells.push(new RkSpecCell('制造商', maker));
    }

    return this.toRows(cells);
  }

  /** 一维格子按 2 个一行切；奇数末行 hasRight=false，渲染时补 Blank 占位 */
  private toRows(cells: RkSpecCell[]): RkSpecRow[] {
    const rows: RkSpecRow[] = [];
    for (let i = 0; i < cells.length; i = i + 2) {
      const hasRight: boolean = i + 1 < cells.length;
      const right: RkSpecCell = hasRight ? cells[i + 1] : new RkSpecCell('', '');
      rows.push(new RkSpecRow(cells[i], right, hasRight));
    }
    return rows;
  }

  // ============ 展示口径 ============

  /** 顶部栏标题：型号名，取不到就用 prop */
  private titleText(): string {
    const n: string = this.name.length > 0 ? this.name : strOf(this.rocketName).trim();
    return n.length > 0 ? n : '火箭详情';
  }

  /** 无图时的色块首字 */
  private initialText(): string {
    const n: string = this.titleText();
    return n.length > 0 ? n.slice(0, 1) : '?';
  }

  /** 特点标签：可复用 / N 级 / 变体。空标签不占位 */
  private tagLabels(): string[] {
    const tags: string[] = [];
    if (this.reusable) {
      tags.push('可复用');
    }
    if (this.maxStage > 0) {
      tags.push(String(this.maxStage) + ' 级');
    }
    if (this.variant.length > 0) {
      tags.push('变体 ' + this.variant);
    }
    return tags;
  }

  /** 折叠态 4 行；展开态给一个足够大的行数（不写 Infinity，避免布局测量异常） */
  private descLines(): number {
    return this.descExpanded ? 1000 : DESC_FOLD_LINES;
  }

  /** 简介超过阈值才给「展开全文」入口 */
  private canExpandDesc(): boolean {
    return this.desc.length > DESC_HINT_MIN;
  }

  private descToggleText(): string {
    return this.descExpanded ? '收起' : '展开全文';
  }

  /** 状态文案与配色（现役绿 / 已退役灰） */
  private statusText(): string {
    return this.active ? '现役' : '已退役';
  }

  private statusTextColor(): string {
    return this.active ? BG_PRIMARY : TEXT_MAIN;
  }

  private statusBgColor(): string {
    return this.active ? ACTIVE_GREEN : RETIRED_GRAY;
  }

  // ============ 交互 ============

  private back(): void {
    Nav.pop();
  }

  /** Hero 点击看大图；没图就什么都不做（不弹 toast 打扰） */
  private openPhoto(): void {
    if (this.image.length === 0 || this.imgErr) {
      return;
    }
    const title: string = this.titleText();
    Nav.pushPhoto(new PhotoNavParam(this.image, title));
  }

  private retry(): void {
    this.loadLauncher(true);
  }

  // ============ UI：返回栏 ============

  /**
   * 自绘顶部栏。NavDestination 那边 hideTitleBar(true)，
   * 标题由这里画（这样「‹ 返回」的热区和字号都能自己定）。
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

      Text(this.titleText())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .backgroundColor(BG_PRIMARY)
  }

  // ============ UI：Hero ============

  @Builder
  hero() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 1 主图（或纯色块 + 首字）
      if (this.image.length > 0 && !this.imgErr) {
        Image(this.image)
          .width('100%')
          .height(HERO_H)
          .objectFit(ImageFit.Cover)
          .backgroundColor(CARD_BG)
          .onError(() => {
            // 破图退回色块，比留一块 200vp 的空白好
            this.imgErr = true;
          })
      } else {
        Column() {
          Text(this.initialText())
            .fontSize(64)
            .fontWeight(FontWeight.Bold)
            .fontColor('#243044')
        }
        .width('100%')
        .height(HERO_H)
        .backgroundColor('#141A26')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      // 2 底部压黑层：标题白字压在任意亮度的图上都要可读（angle 0 = 从下往上）
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

      // 3 左下型号名 / 英文全名 + 右下状态徽章
      Row() {
        Column() {
          Text(this.titleText())
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.fullName.length > 0) {
            Text(this.fullName)
              .fontSize(11)
              .fontColor(TEXT_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 3 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.statusText())
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.statusTextColor())
          .backgroundColor(this.statusBgColor())
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: CARD_PAD, right: CARD_PAD, bottom: 12 })
    }
    .width('100%')
    .height(HERO_H)
    // 图片圆角裁切用 clip，不用 overflow（ColumnAttribute 上没有 overflow）
    .clip(true)
    .onClick(() => {
      this.openPhoto();
    })
  }

  // ============ UI：特点标签 ============

  @Builder
  tagRow() {
    // 必须用 Flex 而不是 Row：Row 是线性布局，没有 flexWrap；标签 0~3 个宽度不一，
    // 挤在一行会被压缩到换行符都放不下，用 Flex(wrap) 才能自然折行。
    Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
      ForEach(this.tagLabels(), (tag: string) => {
        Text(tag)
          .fontSize(11)
          .fontColor(ACCENT)
          .backgroundColor('#16222F')
          .border({ width: 1, color: '#22303F' })
          .borderRadius(6)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .margin({ right: 6, bottom: 6 })
      }, (tag: string) => tag)
    }
    .width('100%')
    .margin({ top: CARD_GAP })
  }

  // ============ UI：参数卡 ============

  @Builder
  specCell(cell: RkSpecCell) {
    Column() {
      Text(cell.value)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .lineHeight(19)
        // 制造商这类长串在半列宽里必然放不下，给 2 行比截成 "Khrunichev Sta…" 有用
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text(cell.label)
        .fontSize(11)
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
      Text('技术参数')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      ForEach(this.specs, (row: RkSpecRow) => {
        Row() {
          this.specCell(row.left)
          if (row.hasRight) {
            this.specCell(row.right)
          } else {
            // 奇数个参数：右侧留同权重的空位，保证左列不被拉宽
            Blank().layoutWeight(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (row: RkSpecRow) => row.left.label)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：简介卡 ============

  @Builder
  descCard() {
    Column() {
      Text('简介')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      Text(this.desc)
        .fontSize(13)
        .fontColor(TEXT_SUB)
        .lineHeight(21)
        // 折叠限 4 行；展开给一个大而行之有效的数（不用 Infinity，避免布局测量异常）
        .maxLines(this.descLines())
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 8 })

      if (this.canExpandDesc()) {
        Row() {
          Text(this.descToggleText())
            .fontSize(12)
            .fontColor(ACCENT)
          Text(this.descExpanded ? '⌃' : '⌄')
            .fontSize(11)
            .fontColor(ACCENT)
            .margin({ left: 3 })
        }
        .alignItems(VerticalAlign.Center)
        .padding({ top: 8, bottom: 2 })
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
    .margin({ top: CARD_GAP })
  }

  // ============ UI：三态占位 ============

  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ACCENT)
      Text('正在加载火箭参数…')
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
      Text('未找到该火箭型号')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      Text(strOf(this.rocketName).trim().length > 0 ? strOf(this.rocketName).trim() : '（未提供型号名）')
        .fontSize(12)
        .fontColor(TEXT_DIM)
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })
      this.stateBackButton()
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
      Text('火箭数据加载失败')
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

      this.stateBackButton()
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  /** 占位块里的返回按钮（返回栏已有一份，这里给「无内容可看」时的明确出口） */
  @Builder
  stateBackButton() {
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
            // Hero 通栏，内容区才留左右内边距
            this.hero()

            Column() {
              if (this.tagLabels().length > 0) {
                this.tagRow()
              }
              if (this.specs.length > 0) {
                this.specCard()
              }
              if (this.desc.length > 0) {
                this.descCard()
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: PAGE_PAD, right: PAGE_PAD })
          }
          .width('100%')
          // 详情页不在 tab 内，底部留 32 即可（不用 92 的胶囊让位）
          .padding({ bottom: BOTTOM_PAD })
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
  }
}
