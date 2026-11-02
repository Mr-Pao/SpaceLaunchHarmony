/**
 * view/PadView.ets —— 发射工位详情页（对位小程序 pages/pad/pad.vue）
 *
 * 由路由方以 `<PadView padId={id} padName={name}>` 挂进 NavDestination。
 * 返回走 Nav.pop()；点「所属机构」跳 Nav.pushAgency(new AgencyNavParam(...))。
 *
 * ── 两种入口必须都支持 ──
 *   1. 机构页 / 搜索页：带 LL2 数字 id（会 String() 成 padId）；
 *   2. 发射详情页（LaunchDetailView 里的工位名）：**只有名字，padId 是空串**
 *      —— 所以 findIn() 必须先按 id 找、找不着再按名字找，缺一不可。
 *
 * ── 数据链路：peek → load，与 RocketDetailView / AgencyView 同口径 ──
 *   pads.json 251 条，同样不属于启动必备数据，本页自己负责拉。
 *
 *   found / failed 必须分开：repo.load 在「无缓存 + 网络失败」时是 reject，
 *   若在 catch 里顺手置 found=true，页面就永久停在「未找到该工位」，
 *   网络抖一下等于把这个工位从库里删了 —— 这个坑原项目踩过。
 *
 * ── 字段口径（线上 v14 实测，见 model/Pad.ets）──
 *   image / map_image 都是**纯字符串**（COS 直链），不是图片对象；
 *   **没有 agency_id 单字段**，而是 agencies: [{id, name}] 数组（实测每条 0~1 个）；
 *   计数字段只有两个：total_launch_count（本工位）与 location.total_launch_count（所在发射场）。
 *
 * ── 与小程序的两处有意差异 ──
 *   1. 不画「外部资料」卡：wiki_url / info_url 要调剪贴板并弹 toast，
 *      鸿蒙侧没有统一的复制组件，任务书也没要求，干脆不画。
 *   2. 「所属机构」卡只在 agencies 缓存里**真的能查到**时才画 ——
 *      画一个点了没反应的按钮比不画更糟。查不到时会静默预热一次 agencies
 *      （见 ensureAgencies），命中后卡片自己出现，不是假按钮。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { PdPad, PdPadsPayload, PdLocation, PdAgencyRef } from '../model/Pad';
import { AgAgency, AgAgenciesPayload } from '../model/Agency';
import { Nav } from '../routes/Nav';
import { AgencyNavParam } from '../routes/NavParam';
import { strOf, descText, descNeedFold, padShort, placeZh } from '../utils/Format';

const DOMAIN: number = 0x0000;
const TAG: string = 'PadView';

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
/** 现役绿 / 停用灰，与小程序 tag 同色系 */
const OK_GREEN: string = '#34D399';

const HERO_H: number = 200;
const PAGE_PAD: number = 12;
/** 悬浮胶囊 TabBar 盖在 NavDestination 之上，留够底距最后一张卡才不被吃 */
const BOTTOM_PAD: number = 120;

/** 简介折叠：4 行 + 120 字阈值（拿不到 Text 实际行数，只能按字符数粗判） */
const DESC_FOLD_LINES: number = 4;
const DESC_FOLD_CHARS: number = 120;

/** 经纬度保留 4 位小数 ≈ 11 米精度，够定位到工位，再多就是噪声 */
const COORD_DIGITS: number = 4;

// ============ 纯函数 ============

/**
 * 数字 → 定点小数字符串。
 *
 * 为什么不直接 `v.toFixed(n)`：latitude / longitude 在 interface 里是可空的
 * （实测 251 条里有 3 条缺失），先过 undefined 判定返回空串，调用处才知道「这行不画」。
 */
function pdFixed(v: number | undefined, digits: number): string {
  // 只判 undefined：v 的类型是 number | undefined，再和 null 比较会被 ArkTS
  // 判成「两种类型无重叠」而编译失败（null 是 object 侧的取值，不属于 number）
  if (v === undefined) {
    return '';
  }
  // toFixed 对 NaN / Infinity 会吐出 "NaN" / "Infinity"，那种值宁可当没有
  if (!Number.isFinite(v)) {
    return '';
  }
  return v.toFixed(digits);
}

/** 非负整数计数 → 字符串；缺失或 <= 0 一律空串（0 次发射的工位不需要一行「0」） */
function pdCount(v: number | undefined): string {
  if (v === undefined || !Number.isFinite(v) || v <= 0) {
    return '';
  }
  return String(Math.round(v));
}

/** 用 · 连接非空片段，避免出现 " ·  · 现役" 这种残缺分隔 */
function pdJoin(parts: string[]): string {
  const kept: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (parts[i].length > 0) {
      kept.push(parts[i]);
    }
  }
  return kept.join(' · ');
}

@Component
export struct PadView {
  /** LL2 pad id（number 的字符串形式）。空串表示只能按名字匹配 */
  @Prop padId: string = '';
  /** 兜底：拿不到 id 时按名字匹配（发射详情页只带工位名） */
  @Prop padName: string = '';

  // ============ 页面状态 ============

  @State loading: boolean = true;
  @State found: boolean = false;
  /** 加载失败（无缓存 + 网络失败）。与「未找到」严格分开 */
  @State failed: boolean = false;

  /** 主标题：padShort 缩写，没有缩写时回原名 */
  @State pdTitle: string = '';
  /** 副标题：所在发射场（中文优先）+ 国家码 */
  @State pdSubline: string = '';
  /** 状态：现役 / 已停用 / 未知（未知时不画徽章） */
  @State pdStatus: string = '';
  @State pdActive: boolean = false;

  /** Hero 图地址（实拍图优先，其次示意地图） */
  @State heroUrl: string = '';
  /** 图加载失败 → 退回 emoji 占位，避免破图 */
  @State imgErr: boolean = false;

  /** 经纬度（各保留 4 位小数；空串 = 该行不画） */
  @State latText: string = '';
  @State lonText: string = '';
  /** 经纬度是否带半球标记（有真实值时才有意义） */
  @State coordHemi: string = '';

  /** 本工位累计发射 */
  @State totalText: string = '';
  /** 所在发射场累计发射 */
  @State venueText: string = '';
  /** 所在发射场名（发射统计卡里单独再列一次，因为副标题会被截断） */
  @State venueName: string = '';

  /** 所属机构：命中 agencies 缓存才为 true，否则整卡不画 */
  @State hasAgency: boolean = false;
  @State agencyRefName: string = '';
  @State agencyRefId: string = '';

  /** 简介正文（中文优先） */
  @State pdDesc: string = '';
  @State descExpanded: boolean = false;

  /** 本页命中的那条原始记录里的 agencies 数组，供预热后重新解析（普通成员，不参与重绘） */
  private refAgencies: PdAgencyRef[] = [];
  /** agencies 预热是否已发起过（避免每次 applyPayload 都打一次网络） */
  private agenciesTried: boolean = false;

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadPad(false);
    // 无定时器、无监听，aboutToDisappear 无事可做，故不实现
  }

  // ============ 加载 ============

  /**
   * 先 peek 再 load。
   *
   * peek 是同步的（内存 + 文件），二次进页能立刻出内容；没命中才等网络。
   * force=true 绕过缓存回源，「重试」按钮走的是 force=false（见 retry 注释）。
   */
  private loadPad(force: boolean): void {
    this.loading = true;
    this.failed = false;

    const cached: PdPadsPayload | null = repo.peek<PdPadsPayload>('pads');
    if (cached !== null) {
      const hit: PdPad | null = this.findIn(this.listOf(cached));
      if (hit !== null) {
        this.applyPad(hit);
        // 缓存就命中 → 立刻收掉 loading，不等网络（后台刷新照常进行）
        this.loading = false;
      }
    }

    const opts: LoadOptions<PdPadsPayload> = {
      force: force,
      onUpdate: (fresh: PdPadsPayload) => {
        // 后台刷新只做回填；找不到就保持现有画面，不把已渲染的页打回「未找到」
        this.applyPayload(fresh);
      }
    };

    repo.load<PdPadsPayload>('pads', opts)
      .then((data: PdPadsPayload) => {
        // 命中缓存时 resolve 的就是缓存值，重复落地一次无害（幂等）
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有内容就别说「失败」，静默留在旧数据上（弱网体验优先）
        this.failed = !this.found;
        hilog.warn(DOMAIN, TAG, 'pads 加载失败: %{public}s', e.message);
      });
  }

  /**
   * 取载荷里的 list。
   *
   * 不直接写 `data.list !== undefined ? data.list : []`：list 在 interface 里是必填，
   * 拿必填类型和 undefined 比较会被判成「两个类型无重叠」。先落一个显式可空的局部变量。
   */
  private listOf(data: PdPadsPayload): PdPad[] {
    const maybe: PdPad[] | undefined = data.list;
    return maybe !== undefined ? maybe : [];
  }

  private applyPayload(data: PdPadsPayload): void {
    const hit: PdPad | null = this.findIn(this.listOf(data));
    if (hit === null) {
      // 已找到过就保持原样：中途一次半截数据不该把整页清空
      return;
    }
    this.applyPad(hit);
  }

  /**
   * 按 id 定位，id 不中再按名字兜。
   *
   * 发射详情跳过来时 padId 是空串、只有 padName —— 这条兜底路径是**主路径**之一，
   * 不是可选的容错。名字比对忽略大小写与首尾空格（数据里 "LC-39A" 与 "lc-39a" 都有）。
   */
  private findIn(list: PdPad[]): PdPad | null {
    const target: string = strOf(this.padId).trim();
    if (target.length > 0) {
      for (let i = 0; i < list.length; i++) {
        const item: PdPad = list[i];
        if (item !== undefined && String(item.id) === target) {
          return item;
        }
      }
    }

    const want: string = strOf(this.padName).trim().toLowerCase();
    if (want.length === 0) {
      return null;
    }
    for (let i = 0; i < list.length; i++) {
      const item: PdPad = list[i];
      if (item === undefined) {
        continue;
      }
      if (strOf(item.name).trim().toLowerCase() === want) {
        return item;
      }
    }
    return null;
  }

  /** 一条记录 → 页面状态。所有字段都过一遍空值判定，不留 undefined 到 UI */
  private applyPad(p: PdPad): void {
    const rawName: string = strOf(p.name).trim();
    // padShort 会把 "Space Launch Complex 40" 压成 "SLC-40"，标题行才放得下；
    // 压不出来（不是已知长名）时它原样返回，所以这里要再 || 一次兜底
    const short: string = padShort(rawName).trim();
    this.pdTitle = short.length > 0 ? short : (rawName.length > 0 ? rawName : '未知工位');

    // ---- Hero：实拍图 → 示意地图 → emoji 占位 ----
    const img: string = strOf(p.image).trim();
    const map: string = strOf(p.map_image).trim();
    // 实拍图信息量 > 示意地图；map_image 是 251/251 全有，所以它是稳定兜底
    this.heroUrl = img.length > 0 ? img : map;
    // 换工位时不继承上一条的破图标记
    this.imgErr = false;

    // ---- 发射场（location 是对象，可能整体缺失） ----
    const loc: PdLocation | undefined = p.location;
    let venueRaw: string = '';
    let venueCount: number | undefined = undefined;
    if (loc !== undefined) {
      venueRaw = strOf(loc.name).trim();
      venueCount = loc.total_launch_count;
    }
    // placeZh 认的是发射场串（"Cape Canaveral, FL" 这类），转不出中文时原样返回
    const venueZh: string = venueRaw.length > 0 ? placeZh(venueRaw) : '';
    this.venueName = venueZh.length > 0 ? venueZh : venueRaw;

    // 副标题：发射场 · 国家码（国家码只有两位，没必要为它再引一张码表进来）
    const cc: string = strOf(p.country_code).trim().toUpperCase();
    this.pdSubline = pdJoin([this.venueName, cc.length === 2 ? cc : '']);

    // ---- 状态徽章：只有明确 true/false 才画，undefined 属于「数据没给」 ----
    const active: boolean | undefined = p.active;
    if (active === undefined) {
      this.pdStatus = '';
      this.pdActive = false;
    } else if (active) {
      this.pdStatus = '现役';
      this.pdActive = true;
    } else {
      this.pdStatus = '已停用';
      this.pdActive = false;
    }

    // ---- 经纬度：4 位小数，缺一条就只画另一条 ----
    this.latText = pdFixed(p.latitude, COORD_DIGITS);
    this.lonText = pdFixed(p.longitude, COORD_DIGITS);
    // 半球方向给个中文提示，纯数字容易看不出东西经（编号里没负号概念）
    let hemi: string = '';
    const lat: number | undefined = p.latitude;
    const lon: number | undefined = p.longitude;
    if (this.latText.length > 0 && lat !== undefined) {
      hemi += lat < 0 ? '南纬' : '北纬';
    }
    if (this.lonText.length > 0 && lon !== undefined) {
      hemi += (hemi.length > 0 ? ' · ' : '') + (lon >= 0 ? '东经' : '西经');
    }
    this.coordHemi = hemi;

    // ---- 发射统计：只有两个计数字段，都没有就整卡不画 ----
    this.totalText = pdCount(p.total_launch_count);
    this.venueText = pdCount(venueCount);

    // ---- 所属机构：先把引用存下来，命中缓存才画卡 ----
    const refs: PdAgencyRef[] | undefined = p.agencies;
    this.refAgencies = refs !== undefined ? refs : [];
    this.resolveAgency();

    // ---- 简介：CI 回填的 descriptionZh 优先，缺失回落英文 ----
    this.pdDesc = descText(strOf(p.descriptionZh), strOf(p.description)).trim();
    this.descExpanded = false;

    this.found = true;
  }

  /**
   * 解析所属机构。
   *
   * 实测 agencies 是数组且每条最多一个元素，所以取**第一个纯数字 id** 即可
   * （脏数据里出现过 {id: 0} 这种没有意义的引用，0 不是合法 LL2 id，跳过）。
   *
   * 缓存里查不到就整卡不画 —— 不画假按钮；同时发起一次 agencies 预热，
   * 拿到后重新解析，卡片自己出现。预热只做一次（agenciesTried 挡住重复请求）。
   */
  private resolveAgency(): void {
    let idNum: number = 0;
    let fallbackName: string = '';
    for (let i = 0; i < this.refAgencies.length; i++) {
      const ref: PdAgencyRef = this.refAgencies[i];
      if (ref === undefined) {
        continue;
      }
      const n: number = ref.id;
      if (n > 0 && Math.floor(n) === n) {
        idNum = n;
        fallbackName = strOf(ref.name).trim();
        break;
      }
    }

    if (idNum <= 0) {
      this.hasAgency = false;
      this.agencyRefId = '';
      this.agencyRefName = '';
      return;
    }

    const idStr: string = String(idNum);
    // findById 是 2 参、同步、只读缓存（不发网络），所以这里不会炸也不会卡
    const hit: AgAgency | null = repo.findById<AgAgency>('agencies', idStr);
    if (hit !== null) {
      const nm: string = strOf(hit.name).trim();
      this.agencyRefId = idStr;
      this.agencyRefName = nm.length > 0 ? nm : fallbackName;
      this.hasAgency = this.agencyRefName.length > 0;
    } else {
      // 缓存里没有 → 现在画不出来，先藏卡，等预热回来再说
      this.hasAgency = false;
      this.agencyRefId = idStr;
      this.agencyRefName = '';
      this.ensureAgencies();
    }
  }

  /**
   * 预热 agencies 数据集。
   *
   * 只在这一页真的需要跳机构、而缓存里又没有时才触发，且只触发一次。
   * 失败静默忽略：宁可卡片不出现，也不要因为一张次要卡片弹错误。
   */
  private ensureAgencies(): void {
    if (this.agenciesTried) {
      return;
    }
    this.agenciesTried = true;

    repo.load<AgAgenciesPayload>('agencies')
      .then((data: AgAgenciesPayload) => {
        // 数据到位后重算一次；命中就把卡片亮出来
        this.resolveAgency();
      })
      .catch((e: BusinessError) => {
        // 这里**不能**动 found / failed：主内容已经渲染好了，机构卡缺席是小事
        hilog.info(DOMAIN, TAG, 'agencies 预热失败（忽略）: %{public}s', e.message);
      });
  }

  // ============ 交互 ============

  /**
   * 重试。
   *
   * 传 false：能走到「失败」分支说明 peek 也没命中（found=false），
   * 此时缓存里没有可用数据，force=false 照样回源；反而 force=true 会把
   * 「缓存其实是好数据」的场景也强刷一遍。任务书口径即 load(false)。
   */
  private retry(): void {
    this.loadPad(false);
  }

  private back(): void {
    Nav.pop();
  }

  /** 跳机构详情。id 一定非空（resolveAgency 里 idNum > 0 才走到这） */
  private goAgency(): void {
    if (this.agencyRefId.length === 0) {
      return;
    }
    Nav.pushAgency(new AgencyNavParam(this.agencyRefId, this.agencyRefName));
  }

  // ============ 派生值 ============

  private canExpandDesc(): boolean {
    return descNeedFold(this.pdDesc, DESC_FOLD_CHARS);
  }

  /** 展开时给一个足够大的行数（不用 Infinity，避免测量异常） */
  private descLines(): number {
    return this.descExpanded ? DESC_FOLD_LINES * 200 : DESC_FOLD_LINES;
  }

  /** 坐标卡是否至少有一条 */
  private hasCoord(): boolean {
    return this.latText.length > 0 || this.lonText.length > 0;
  }

  /** 发射统计卡是否至少有一格 */
  private hasStat(): boolean {
    return this.totalText.length > 0 || this.venueText.length > 0;
  }

  private titleText(): string {
    if (this.pdTitle.length > 0) {
      return this.pdTitle;
    }
    return '发射工位';
  }

  // ============ UI：返回栏 ============

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

  /**
   * Hero 200vp：实拍图 / 示意地图 + 底部压黑 + 左下名称、发射场、状态徽章。
   *
   * 为什么压一层 linearGradient：map_image 是浅色卫星图，白字直接压上去必糊；
   * 从底往上的黑色渐变既保可读又不遮主体。
   */
  @Builder
  hero() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 1 主图 / emoji 占位
      if (this.heroUrl.length > 0 && !this.imgErr) {
        Image(this.heroUrl)
          .width('100%')
          .height(HERO_H)
          // map_image 是俯视卫星图，Cover 裁一点没关系；实拍图同理
          .objectFit(ImageFit.Cover)
          .backgroundColor(CARD_BG)
          .onError(() => {
            // 破图退回占位块，比留一块 200vp 的空白好
            this.imgErr = true;
          })
      } else {
        Column() {
          Text('🛫')
            .fontSize(52)
        }
        .width('100%')
        .height(HERO_H)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .linearGradient({
          angle: 135,
          colors: [['#16233A', 0.0], ['#0D1420', 1.0]]
        })
      }

      // 2 底部压黑层（angle 0 = 从下往上）
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

      // 3 左下名称 + 副标题 + 右下状态徽章
      Row() {
        Column() {
          Text(this.pdTitle)
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.pdSubline.length > 0) {
            Text(this.pdSubline)
              .fontSize(11.5)
              .fontColor(TEXT_SUB)
              .maxLines(2)
              .width('100%')
              .margin({ top: 4 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 状态徽章只在数据明确给了 active 时才画（见 applyPad）
        if (this.pdStatus.length > 0) {
          Text(this.pdStatus)
            .fontSize(10.5)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.pdActive ? OK_GREEN : TEXT_SUB)
            .backgroundColor(this.pdActive ? '#1B3A2F' : '#242C3A')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(6)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: CARD_PAD, right: CARD_PAD, bottom: 14 })
    }
    .width('100%')
    .height(HERO_H)
    // 圆角裁切用 clip，不用 overflow（Attribute 上没有 overflow）
    .clip(true)
    .borderRadius(CARD_RADIUS)
  }

  // ============ UI：经纬度 ============

  /**
   * 坐标卡。
   *
   * 不画示意图：Map 组件要额外权限 + 网络瓦片，任务书明确不在范围内，
   * 两个 4 位小数足以定位。
   */
  @Builder
  coordCard() {
    Column() {
      Row() {
        Text('经纬度')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_MAIN)
        Blank()
        if (this.coordHemi.length > 0) {
          Text(this.coordHemi)
            .fontSize(11)
            .fontColor(TEXT_DIM)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        if (this.latText.length > 0) {
          this.coordCell('纬度', this.latText)
        }
        if (this.lonText.length > 0) {
          this.coordCell('经度', this.lonText)
        }
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  @Builder
  coordCell(label: string, value: string) {
    Column() {
      Text(label)
        .fontSize(11)
        .fontColor(TEXT_DIM)
      Text(value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
        .margin({ top: 3 })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  // ============ UI：发射统计 ============

  /**
   * 发射统计卡。
   *
   * 线上只有两个计数：本工位 total_launch_count 与所在发射场
   * location.total_launch_count —— 有几格画几格，全空则整卡不画。
   */
  @Builder
  statCard() {
    Column() {
      Text('发射统计')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      Row() {
        if (this.totalText.length > 0) {
          this.statCell(this.totalText, '该工位累计发射')
        }
        if (this.venueText.length > 0) {
          this.statCell(this.venueText, '所在发射场累计')
        }
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Top)

      if (this.venueName.length > 0) {
        Text(this.venueName)
          .fontSize(11)
          .fontColor(TEXT_DIM)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 10 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  @Builder
  statCell(value: string, label: string) {
    Column() {
      Row() {
        Text(value)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(ACCENT)
        Text('次')
          .fontSize(11)
          .fontColor(TEXT_DIM)
          .margin({ left: 3, bottom: 3 })
      }
      .alignItems(VerticalAlign.Bottom)

      Text(label)
        .fontSize(11)
        .fontColor(TEXT_DIM)
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  // ============ UI：所属机构 ============

  /**
   * 所属机构卡：只在 repo.findById 命中 agencies 缓存时才被调用（build 里判 hasAgency）。
   * 点击整行进机构详情。
   */
  @Builder
  agencyCard() {
    Column() {
      Text('所属机构')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      Row() {
        Text(this.agencyRefName)
          .fontSize(13.5)
          .fontColor(TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('›')
          .fontSize(16)
          .fontColor(TEXT_DIM)
          .margin({ left: 6 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 10, bottom: 2 })
      .onClick(() => {
        this.goAgency();
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：简介 ============

  @Builder
  descCard() {
    Column() {
      Text('工位简介')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      Text(this.pdDesc)
        .fontSize(13)
        .fontColor(TEXT_SUB)
        .lineHeight(21)
        .maxLines(this.descLines())
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 8 })

      if (this.canExpandDesc()) {
        Row() {
          Text(this.descExpanded ? '收起' : '展开全文')
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

  // ============ UI：页脚 ============

  @Builder
  footerHint() {
    Text('数据来源 The Space Devs')
      .fontSize(10.5)
      .fontColor(TEXT_DIM)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ top: 16 })
  }

  // ============ UI：状态块 ============

  /** 加载态用转圈：动画本身就是「还在等」的语义 */
  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ACCENT)
      Text('正在读取工位档案…')
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
  stateBlock(icon: string, title: string, hint: string, showRetry: boolean) {
    Column() {
      if (icon.length > 0) {
        Text(icon)
          .fontSize(44)
          .margin({ bottom: 14 })
      }
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      if (hint.length > 0) {
        Text(hint)
          .fontSize(12)
          .fontColor(TEXT_DIM)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
      if (showRetry) {
        Row() {
          Text('网络异常，点击重试')
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
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  // ============ build ============

  build() {
    // 根容器统一 12 侧距 + 120 底距；页头也在这条内边距里，
    // 因此 Hero 与卡片左右边缘天然对齐，不需要各自再设 margin
    Column() {
      this.topBar()

      if (this.loading && !this.found) {
        this.loadingBlock()
      } else if (this.failed && !this.found) {
        this.stateBlock('', '网络异常，点击重试', '网络不给力，或缓存已被清理', true)
      } else if (!this.found) {
        this.stateBlock('🛫', '未找到该工位信息', '可能是链接已过期，或数据正在更新', false)
      } else {
        Scroll() {
          Column() {
            this.hero()

            Column() {
              if (this.hasCoord()) {
                this.coordCard()
              }
              if (this.hasStat()) {
                this.statCard()
              }
              // 卡片自己会在 resolveAgency 里把 hasAgency 置准；没命中就不画假按钮
              if (this.hasAgency) {
                this.agencyCard()
              }
              if (this.pdDesc.length > 0) {
                this.descCard()
              }
              this.footerHint()
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
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
