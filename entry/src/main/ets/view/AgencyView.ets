/**
 * view/AgencyView.ets —— 机构详情页（对位小程序 pages/agencies/agencies.vue）
 *
 * 由路由方以 `<AgencyView agencyId={id} agencyName={name}>` 挂进 NavDestination。
 * 返回走 Nav.pop()，与 RocketDetailView / AstronautView 同口径。
 *
 * ── 数据链路：先 peek 再 load（与 RocketDetailView 完全一致）──
 *   repo.peek<AgAgenciesPayload>('agencies')   同步、只查内存+文件，零网络
 *   repo.load<AgAgenciesPayload>('agencies', { onUpdate })
 *     onUpdate 只在「缓存过期 + 后台刷新拿到新数据」时回调，用来静默回填
 *
 *   agencies.json 只有 350 条（约 180KB），但它不是启动必备数据 ——
 *   进这一页才有必要拉，所以页面自己负责 load，不依赖别人预热。
 *
 * ── 为什么 found / failed 必须分开（原项目踩过的永久空页坑）──
 *   repo.load 在「无缓存 + 网络失败」时是 **reject**，不是返回 null。
 *   早期写法在 catch 里顺手把 loaded 置 true，页面就永久停在「未找到该机构」——
 *   网络抖一下等于把这家机构从库里删了。所以这里：
 *     loading && !found → 加载中
 *     failed  && !found → 网络异常 + 点击重试
 *     !failed && !found → 真的没这条记录
 *     found             → 正常内容（此时刷新失败也继续显示旧数据）
 *
 * ── 字段口径（已用线上 v14 数据逐条核对，见 model/Agency.ets）──
 *   image_url / logo_url 是**纯字符串**（COS 直链），不是 LL2 的图片对象；
 *   founding_year 是**字符串**；**没有** administrator / parent / launch_count。
 *   那三个字段在 model 里仍留成可空，上游哪天补上，这里的行会自动出现。
 *
 * ── 与小程序的三处有意差异 ──
 *   1. Hero 图**先实拍图再 logo**（小程序是先 logo）。200vp 通栏用实拍图信息量
 *      更大，logo 只在没有实拍图时顶上 —— 任务书口径，且与 RocketDetailView 一致。
 *   2. 不做「该机构的火箭」那一块：小程序是拿机构名去 launchers 数据集反查，
 *      跨数据集硬套会丢型号类型；任务书明确改为展示 agencies 自带的 launchers 串。
 *   3. 标题不截断：agencyLabel() 截 16 字是给列表用的，详情页标题用原名 + 省略号。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。不使用 AppStorage。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { AgAgency, AgAgenciesPayload } from '../model/Agency';
import { Nav } from '../routes/Nav';
import { strOf, descText, descNeedFold } from '../utils/Format';

const DOMAIN: number = 0x0000;
const TAG: string = 'AgencyView';

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

/** Hero 高度（任务书 200vp） */
const HERO_H: number = 200;
/** 页面左右内边距，与 TodayView / RocketDetailView 的 12 对齐 */
const PAGE_PAD: number = 12;
/**
 * 底部 120：详情页不是 tab 页，但悬浮胶囊（TabBar）仍盖在 NavDestination 之上，
 * 留够高度最后一张卡才不会被吃掉。FavoritesView 同值。
 */
const BOTTOM_PAD: number = 120;

/** 简介折叠：4 行 + 120 字阈值（拿不到 Text 实际行数，只能按字符数粗判） */
const DESC_FOLD_LINES: number = 4;
const DESC_FOLD_CHARS: number = 120;

/**
 * 国家/地区两位码 → 中文。
 *
 * 为什么本页自建一份而不复用 constants/ZhMaps.ets 的 COUNTRY_ZH：
 * 那张表的键是**国名全称**（'USA' / 'United States' / 'China'），
 * 而 agencies.json 的 country_code 是两位 ISO 码（'US' / 'CN'），键对不上。
 * utils/Format.ets 也没有「两位码 → 中文」的导出（countryOf 只吃 LaunchSummary）。
 *
 * 码表按线上实测的 74 个取值建（含 "??" 这种脏值，查不到时原样显示）。
 * 港澳台一律带「中国」前缀，这是合规红线。
 */
const AG_COUNTRY_ZH: Map<string, string> = new Map<string, string>([
  ['US', '美国'], ['CN', '中国'], ['RU', '俄罗斯'], ['JP', '日本'], ['IN', '印度'],
  ['FR', '法国'], ['DE', '德国'], ['GB', '英国'], ['KR', '韩国'], ['KP', '朝鲜'],
  ['IL', '以色列'], ['NZ', '新西兰'], ['AU', '澳大利亚'], ['CA', '加拿大'],
  ['IT', '意大利'], ['ES', '西班牙'], ['BR', '巴西'], ['IR', '伊朗'],
  ['UA', '乌克兰'], ['NL', '荷兰'], ['SE', '瑞典'], ['NO', '挪威'], ['SG', '新加坡'],
  ['AR', '阿根廷'], ['MX', '墨西哥'], ['TR', '土耳其'], ['AE', '阿联酋'],
  ['SA', '沙特阿拉伯'], ['KZ', '哈萨克斯坦'], ['TW', '中国台湾'], ['HK', '中国香港'],
  ['MO', '中国澳门'], ['UY', '乌拉圭'], ['DZ', '阿尔及利亚'], ['MY', '马来西亚'],
  ['AT', '奥地利'], ['AZ', '阿塞拜疆'], ['BY', '白俄罗斯'], ['BE', '比利时'],
  ['VE', '委内瑞拉'], ['BO', '玻利维亚'], ['BG', '保加利亚'], ['CO', '哥伦比亚'],
  ['DK', '丹麦'], ['HR', '克罗地亚'], ['PT', '葡萄牙'], ['TH', '泰国'],
  ['HU', '匈牙利'], ['GR', '希腊'], ['LU', '卢森堡'], ['LT', '立陶宛'],
  ['CZ', '捷克'], ['EG', '埃及'], ['PE', '秘鲁'], ['ID', '印度尼西亚'],
  ['MN', '蒙古'], ['TN', '突尼斯'], ['NG', '尼日利亚'], ['PK', '巴基斯坦'],
  ['PL', '波兰'], ['BM', '百慕大'], ['MU', '毛里求斯'], ['RO', '罗马尼亚'],
  ['MA', '摩洛哥'], ['CH', '瑞士'], ['ZA', '南非'], ['BD', '孟加拉国'],
  ['LK', '斯里兰卡'], ['TM', '土库曼斯坦'], ['UZ', '乌兹别克斯坦'], ['VN', '越南'],
  ['GF', '法属圭亚那'], ['MH', '马绍尔群岛'], ['OM', '阿曼']
]);

/**
 * 机构类型中文。LL2 只有这 6 种取值（线上 350 条实测全覆盖），
 * 用 Map 而不是 if 链是因为这里要「表驱动」，将来上游加枚举只需补一行。
 */
const AG_TYPE_ZH: Map<string, string> = new Map<string, string>([
  ['Commercial', '商业航天'],
  ['Government', '政府机构'],
  ['Multinational', '多国合作'],
  ['Private', '私营企业'],
  ['Educational', '教育机构'],
  ['Unknown', '未知']
]);

// ============ 纯函数（放 @Component 外面，避免每次重绘重建闭包） ============

/**
 * 两位 ISO 码 → 中文。
 * 查不到就原样回码（显示 "GF" 也比显示空白强），"??" 视为脏值返回空串。
 */
function agCountryZh(code: string): string {
  const c: string = strOf(code).trim().toUpperCase();
  if (c.length === 0) {
    return '';
  }
  const hit: string | undefined = AG_COUNTRY_ZH.get(c);
  if (hit !== undefined) {
    return hit;
  }
  // "??" 是 LL2 里「国家未知」的占位，画出来只会让人困惑
  return c === '??' ? '' : c;
}

/**
 * 两位 ISO 码 → 国旗 emoji。
 *
 * 不复用 utils/Format.ets 的 flagOf()：那个是「传国家名」的，内部先跑
 * FLAG_RULES 正则猜码（'US' 这种两位码不在规则里，恒返回空）。
 * 这里已有确定的两位码，直接按 Unicode regional indicator 拼。
 */
function agFlagOf(code: string): string {
  const up: string = strOf(code).trim().toUpperCase();
  if (up.length !== 2) {
    return '';
  }
  const a: number = up.charCodeAt(0) - 65;
  const b: number = up.charCodeAt(1) - 65;
  if (a < 0 || a > 25 || b < 0 || b > 25) {
    return '';
  }
  return String.fromCodePoint(0x1F1E6 + a) + String.fromCodePoint(0x1F1E6 + b);
}

/** 机构类型中文化；表里没有就原样显示（新枚举不该显示成空白） */
function agTypeZh(t: string): string {
  const s: string = strOf(t).trim();
  if (s.length === 0) {
    return '';
  }
  const hit: string | undefined = AG_TYPE_ZH.get(s);
  return hit !== undefined ? hit : s;
}

/**
 * 把 agencies.launchers 的竖线串拆成标签数组。
 *
 * 线上实测是 `"Falcon 9 | Falcon Heavy"` 这样的**字符串**（LL2 原始结构），
 * 不是数组，所以必须按 '|' 切；空段（"A | | B" 这种）过滤掉，
 * 否则 Flex 里会出现一个空标签。
 */
function agLauncherTags(raw: string): string[] {
  const s: string = strOf(raw).trim();
  if (s.length === 0) {
    return [];
  }
  const out: string[] = [];
  const parts: string[] = s.split('|');
  for (let i = 0; i < parts.length; i++) {
    const t: string = parts[i].trim();
    if (t.length > 0) {
      out.push(t);
    }
  }
  return out;
}

/** 用 · 连接非空片段（空串不占位，避免出现 " ·  · 1960 年成立" 这种残缺分隔） */
function agJoin(parts: string[]): string {
  const kept: string[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (parts[i].length > 0) {
      kept.push(parts[i]);
    }
  }
  return kept.join(' · ');
}

@Component
export struct AgencyView {
  /** LL2 agency id（number 的字符串形式）。空串表示只能按名字匹配 */
  @Prop agencyId: string = '';
  /** 兜底：拿不到 id 时按名字匹配（pads / launchers 里只带机构名不带 id） */
  @Prop agencyName: string = '';

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，不挡返回栏） */
  @State loading: boolean = true;
  /** 是否拿到了这条记录 */
  @State found: boolean = false;
  /** 加载失败（无缓存 + 网络失败）。与「未找到」严格分开，见文件头说明 */
  @State failed: boolean = false;

  /** 机构名（原名，不截断） */
  @State agName: string = '';
  /** 副标题：缩写 · 国家 · YYYY 年成立 */
  @State agSubline: string = '';
  /** Hero 图地址（实拍图优先，其次 logo） */
  @State heroUrl: string = '';
  /** 当前 Hero 用的是不是 logo（logo 要 Contain 不裁切） */
  @State heroIsLogo: boolean = false;
  /** 图加载失败 → 退回 emoji 占位，避免破图 */
  @State imgErr: boolean = false;

  /**
   * 简介正文（中文优先）。
   *
   * 名字特意叫 agDesc 而不是 descText：utils/Format.ets 里已经有一个同名函数
   * `descText(descZh, desc)`，成员与 import 同名时 ArkTS 会报重复标识符。
   */
  @State agDesc: string = '';
  /** 简介是否已展开 */
  @State descExpanded: boolean = false;

  // ---- 基本信息七行：空串 = 该行不画 ----
  @State abbrevText: string = '';
  @State typeText: string = '';
  @State yearText: string = '';
  @State countryText: string = '';
  @State parentText: string = '';
  @State adminText: string = '';
  @State launchText: string = '';

  /** 运载火箭标签（已按 '|' 切好） */
  @State launcherTags: string[] = [];

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadAgency(false);
    // 无定时器、无监听、无长连接，aboutToDisappear 无事可做，故不实现
  }

  // ============ 加载 ============

  /**
   * 先 peek 再 load。
   *
   * peek 是同步的（内存 + 文件），二次进页能立刻把详情画出来；
   * 找不到（或压根没缓存）才等 load。
   * force=true 绕过缓存直接回源，避免「重试还命中那份坏缓存」。
   */
  private loadAgency(force: boolean): void {
    this.loading = true;
    this.failed = false;

    const cached: AgAgenciesPayload | null = repo.peek<AgAgenciesPayload>('agencies');
    if (cached !== null) {
      const hit: AgAgency | null = this.findIn(this.listOf(cached));
      if (hit !== null) {
        this.applyAgency(hit);
        // 缓存就命中 → 立刻收掉 loading，不等网络（后台刷新照常进行）
        this.loading = false;
      }
    }

    const opts: LoadOptions<AgAgenciesPayload> = {
      force: force,
      onUpdate: (fresh: AgAgenciesPayload) => {
        // 后台刷新只做回填；找不到就保持现有画面，不把已渲染的页打回「未找到」
        this.applyPayload(fresh);
      }
    };

    repo.load<AgAgenciesPayload>('agencies', opts)
      .then((data: AgAgenciesPayload) => {
        // 命中缓存时 resolve 的就是缓存值，重复落地一次无害（幂等）
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有内容就别说「失败」，静默留在旧数据上（弱网体验优先）
        this.failed = !this.found;
        hilog.warn(DOMAIN, TAG, 'agencies 加载失败: %{public}s', e.message);
      });
  }

  /**
   * 取载荷里的 list。
   *
   * 不直接写 `data.list !== undefined ? data.list : []`：list 在 interface 里是**必填**，
   * 拿必填类型和 undefined 比较会被判成「两个类型无重叠」而报错。
   * 先赋给显式可空的局部变量，既绕开类型层面，又保住运行时兜底。
   */
  private listOf(data: AgAgenciesPayload): AgAgency[] {
    const maybe: AgAgency[] | undefined = data.list;
    return maybe !== undefined ? maybe : [];
  }

  /** 数据落地：从载荷里找到这一条 → 拆到各个 @State */
  private applyPayload(data: AgAgenciesPayload): void {
    const hit: AgAgency | null = this.findIn(this.listOf(data));
    if (hit === null) {
      // 已找到过就保持原样：中途一次半截数据不该把整页清空
      return;
    }
    this.applyAgency(hit);
  }

  /**
   * 按 id 定位，id 不中再按名字兜。
   *
   * 两种入口都存在：搜索页/工位页给的是 id，发射详情里带的机构只有名字。
   * 名字比大小写和首尾空格都忽略 —— LL2 里 "SpaceX" 与 "spacex" 都出现过。
   */
  private findIn(list: AgAgency[]): AgAgency | null {
    const target: string = strOf(this.agencyId).trim();
    if (target.length > 0) {
      for (let i = 0; i < list.length; i++) {
        const item: AgAgency = list[i];
        if (item !== undefined && String(item.id) === target) {
          return item;
        }
      }
    }

    const want: string = strOf(this.agencyName).trim().toLowerCase();
    if (want.length === 0) {
      return null;
    }
    for (let i = 0; i < list.length; i++) {
      const item: AgAgency = list[i];
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
  private applyAgency(a: AgAgency): void {
    const nm: string = strOf(a.name).trim();
    this.agName = nm.length > 0 ? nm : '未知机构';

    // ---- Hero 图：实拍图 → logo → emoji 占位 ----
    const img: string = strOf(a.image_url).trim();
    const logo: string = strOf(a.logo_url).trim();
    if (img.length > 0) {
      this.heroUrl = img;
      this.heroIsLogo = false;
    } else if (logo.length > 0) {
      this.heroUrl = logo;
      this.heroIsLogo = true;
    } else {
      this.heroUrl = '';
      this.heroIsLogo = false;
    }
    // 换机构时不继承上一条的破图标记
    this.imgErr = false;

    // ---- 副标题：缩写 · 国家 · 成立年份 ----
    const abbrev: string = strOf(a.abbrev).trim();
    const country: string = agCountryZh(strOf(a.country_code));
    const year: string = strOf(a.founding_year).trim();
    this.agSubline = agJoin([abbrev, country, year.length > 0 ? year + ' 年成立' : '']);

    // ---- 简介：CI 回填的 descriptionZh 优先，缺失回落英文 ----
    this.agDesc = descText(strOf(a.descriptionZh), strOf(a.description)).trim();
    this.descExpanded = false;

    // ---- 基本信息：空串即整行不画（不留「未知」空行） ----
    this.abbrevText = abbrev;
    this.typeText = agTypeZh(strOf(a.type));
    this.yearText = year.length > 0 ? year + ' 年' : '';
    // 国旗 emoji 只在有真实两位码时拼，脏码（"??"）拼接会得到两个方块
    const flag: string = agFlagOf(strOf(a.country_code));
    this.countryText = country.length === 0
      ? ''
      : (flag.length > 0 ? flag + ' ' + country : country);
    this.parentText = strOf(a.parent).trim();
    this.adminText = strOf(a.administrator).trim();
    // launch_count 线上没有；只有 > 0 才画，0 与 undefined 一律不画（0 次发射的机构没意义）
    const cnt: number | undefined = a.launch_count;
    this.launchText = cnt !== undefined && cnt > 0 ? String(cnt) + ' 次' : '';

    // ---- 运载火箭：竖线串切标签，不反查 launchers 数据集 ----
    this.launcherTags = agLauncherTags(strOf(a.launchers));

    this.found = true;
  }

  // ============ 交互 ============

  /**
   * 重试。
   *
   * 传 false 而不是 true：能走到「失败」分支意味着 peek 也没命中（本页 found=false），
   * 此时缓存里根本没有可用数据，force=false 照样会回源；反而 force=true 会连带
   * 把「缓存里其实是好数据」的场景也强刷一遍。任务书口径即 load(false)。
   */
  private retry(): void {
    this.loadAgency(false);
  }

  private back(): void {
    Nav.pop();
  }

  // ============ 派生值 ============

  /** 简介是否需要给「展开全文」（拿不到 Text 行数，按字符数粗判） */
  private canExpandDesc(): boolean {
    return descNeedFold(this.agDesc, DESC_FOLD_CHARS);
  }

  /** 简介当前的最大行数：展开时给一个足够大的数（不用 Infinity，避免测量异常） */
  private descLines(): number {
    return this.descExpanded ? DESC_FOLD_LINES * 200 : DESC_FOLD_LINES;
  }

  /** 基本信息卡是否至少有一行 —— 全空就整卡不画 */
  private hasBasicInfo(): boolean {
    return this.abbrevText.length > 0
      || this.typeText.length > 0
      || this.yearText.length > 0
      || this.countryText.length > 0
      || this.parentText.length > 0
      || this.adminText.length > 0
      || this.launchText.length > 0;
  }

  /** 顶栏标题：机构名，没拿到数据时用兜底文案 */
  private titleText(): string {
    if (this.agName.length > 0) {
      return this.agName;
    }
    return '机构信息';
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

  /**
   * Hero 200vp：图（或 emoji 占位）+ 底部压黑 + 左下名称/副标题。
   *
   * 为什么压一层 linearGradient：机构实拍图亮度不可控（白天厂房、夜间发射），
   * 白字直接压上去大概率糊掉；从底往上的黑色渐变既保可读又不遮主体。
   */
  @Builder
  hero() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 1 主图 / logo / emoji 占位
      if (this.heroUrl.length > 0 && !this.imgErr) {
        Image(this.heroUrl)
          .width('100%')
          .height(HERO_H)
          // logo 多为透明 PNG，Cover 会裁掉标识的一部分，用 Contain
          .objectFit(this.heroIsLogo ? ImageFit.Contain : ImageFit.Cover)
          .backgroundColor(CARD_BG)
          .onError(() => {
            // 破图退回占位块，比留一块 200vp 的空白好
            this.imgErr = true;
          })
      } else {
        Column() {
          Text('🏢')
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

      // 3 左下名称 + 副标题
      Column() {
        Text(this.agName)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.agSubline.length > 0) {
          Text(this.agSubline)
            .fontSize(11.5)
            .fontColor(TEXT_SUB)
            .maxLines(2)
            .width('100%')
            .margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: CARD_PAD, right: CARD_PAD, bottom: 14 })
      .width('100%')
    }
    .width('100%')
    .height(HERO_H)
    // 圆角裁切用 clip，不用 overflow（Attribute 上没有 overflow）
    .clip(true)
    .borderRadius(CARD_RADIUS)
  }

  // ============ UI：机构简介 ============

  @Builder
  descCard() {
    Column() {
      Text('机构简介')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      Text(this.agDesc)
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

  // ============ UI：基本信息 ============

  /** 单行 label/value。调用处一律包在 if 里，所以不会出现「未知」空行 */
  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12.5)
        .fontColor(TEXT_DIM)
        .width(76)
      Text(value)
        .fontSize(13)
        .fontColor(TEXT_MAIN)
        .layoutWeight(1)
        // 机构名/上级机构可能很长，给 2 行比截成半句强
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 7, bottom: 7 })
  }

  @Builder
  basicCard() {
    Column() {
      Text('基本信息')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      if (this.abbrevText.length > 0) {
        this.infoRow('缩写', this.abbrevText)
      }
      if (this.typeText.length > 0) {
        this.infoRow('机构类型', this.typeText)
      }
      if (this.yearText.length > 0) {
        this.infoRow('成立年份', this.yearText)
      }
      if (this.countryText.length > 0) {
        this.infoRow('国家/地区', this.countryText)
      }
      if (this.parentText.length > 0) {
        this.infoRow('上级机构', this.parentText)
      }
      if (this.adminText.length > 0) {
        this.infoRow('负责人', this.adminText)
      }
      if (this.launchText.length > 0) {
        this.infoRow('累计发射', this.launchText)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：运载火箭 ============

  /**
   * agencies.launchers 是竖线串，这里切成标签平铺。
   *
   * 为什么不反查 launchers 数据集：那边的型号是另一个模型（含长度/推力/LEO 等参数），
   * 按名字硬匹配既会漏也会错配，而且要多拉一份 500KB 的数据。任务书明确不做。
   */
  @Builder
  launcherCard() {
    Column() {
      Row() {
        Text('运载火箭')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_MAIN)
        Blank()
        Text(String(this.launcherTags.length) + ' 型')
          .fontSize(11.5)
          .fontColor(TEXT_DIM)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 必须用 Flex 而不是 Row：Row 是线性布局，没有 flexWrap
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        ForEach(this.launcherTags, (tag: string) => {
          Text(tag)
            .fontSize(11)
            .fontColor(ACCENT)
            .backgroundColor('#16222F')
            .border({ width: 1, color: '#22303F' })
            .borderRadius(6)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .margin({ right: 6, top: 6 })
        }, (tag: string) => tag)
      }
      .width('100%')
      .margin({ top: 4 })
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

  // ============ UI：状态块（加载 / 失败 / 未找到） ============

  /** 加载态用转圈而不是 emoji：动画本身就是「还在等」的语义，比静态图标准 */
  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ACCENT)
      Text('正在读取机构档案…')
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

  build() {
    // 根容器统一 12 侧距 + 120 底距（见文件头常量注释）；页头也在这条内边距里，
    // 因此 Hero 与卡片左右边缘天然对齐，不需要各自再设 margin
    Column() {
      this.topBar()

      if (this.loading && !this.found) {
        this.loadingBlock()
      } else if (this.failed && !this.found) {
        this.stateBlock('', '网络异常，点击重试', '网络不给力，或缓存已被清理', true)
      } else if (!this.found) {
        this.stateBlock('🏢', '未找到该机构信息', '可能是链接已过期，或数据正在更新', false)
      } else {
        Scroll() {
          Column() {
            this.hero()

            Column() {
              if (this.agDesc.length > 0) {
                this.descCard()
              }
              if (this.hasBasicInfo()) {
                this.basicCard()
              }
              if (this.launcherTags.length > 0) {
                this.launcherCard()
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
