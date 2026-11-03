/**
 * view/NeoView.ets —— 近地天体（未来一周掠过地球的小行星）
 *
 * 对位小程序 `pages/neo/neo.vue` + `components/neo-section/neo-section.vue`，
 * 尺寸严格按 wcss 的 rpx ÷ 2 换算成 vp（38rpx→19、22rpx→11 …）。
 *
 * ── 数据链路（与 NewsListView / LaunchView 同口径）──
 *   repo.peek<NePayload>('neoNears')  —— 同步、零网络，冷启动立刻有内容
 *   repo.load<NePayload>('neoNears', {onCache, onUpdate})
 *     onCache  —— 命中原生缓存时立刻上屏
 *     onUpdate —— 缓存过期、后台静默刷新拿到新数据时回填（只有 generatedAt 变了才回调）
 *
 * ── 为什么按「MM-DD」分组，而不是按「现在」切两组 ──
 *   旧实现以 Date.now() 为界切成「即将接近 / 已掠过」，那是我自己发明的秩序，
 *   小程序根本没有这个概念。小程序的语义是「未来一周的日程表」：CI 已经按
 *   接近时刻升序排好，前端只需用 atShort 的前 5 位（MM-DD，已是北京时间）
 *   当分组键，一天一组、组头写「N 颗」。这样跨午夜、跨时区都不会错位。
 *
 * ── 展开态为什么记 id 而不是布尔 ──
 *   小程序 `expanded` 存的是「当前展开的那一条的 id」（空串＝全收起），
 *   同时只能展开一条。用布尔数组会让几十条同时展开，页面立刻变成一堵墙。
 *
 * ── 四态为什么必须分开 ──
 *   小程序 utils/data.js 的 load() 在「弱网 + 无缓存」时是 **reject**，不是返回 null。
 *   如果 catch 里顺手置 loaded = true，页面就永久停在空列表。所以这里**没有 loaded**：
 *     loading && 空    → 「加载中...」
 *     failed  && 空    → 加载失败 + 重试（小程序没有这一态，鸿蒙侧必须给出口）
 *     !failed && 空    → 「暂无近地天体数据」
 *     groups 非空      → 列表（此时哪怕刷新失败也继续显示旧数据）
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { NeItem, NePayload, NeClosest } from '../model/Neo';
import { strOf } from '../utils/Format';
import { Nav } from '../routes/Nav';

const DOMAIN: number = 0x0000;
const TAG: string = 'NeoView';

// ============ 视觉常量（照抄小程序 wcss ÷ 2） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
/** 页头标题 #e2e8f0：比纯白柔一档，长标题不刺眼 */
const TEXT_TITLE: string = '#E2E8F0';
/** 卡内天体名 #e2e8f0（同名色，语义不同故分开命名，将来好单独调） */
const TEXT_NAME: string = '#E2E8F0';
/** 右侧地月距离数字 #c3cede */
const TEXT_DIST: string = '#c3cede';
/** 次级文字 #55617a（元信息、说明行） */
const TEXT_DIM: string = '#55617A';
/** 组头日期 #c3cede */
const TEXT_GROUP: string = '#C3CEDE';
const ACCENT: string = '#38BDF8';
/** 「潜在危险」chip：琥珀 #e0b25a，**刻意不用红色** —— 潜在威胁不等于撞击预警 */
const HAZ_FG: string = '#E0B25A';
/** 分隔符「·」#3a4459 */
const SEP: string = '#3A4459';
/** 底部数据来源 #4a5670 */
const NOTE_FG: string = '#4A5670';

/** rgba(255,255,255,.05) → 0x0D */
const BORDER_FAINT: string = '#0DFFFFFF';
/** rgba(255,255,255,.07) → 0x12，概览卡竖分隔线 */
const DIVIDER_LINE: string = '#12FFFFFF';
/** rgba(255,255,255,.08) → 0x14，展开区虚线上边框 */
const DASH_LINE: string = '#14FFFFFF';

/**
 * 页面左右内边距 16vp：小程序 `.page` 是 `padding: 0 32rpx 120rpx`，32rpx = 16vp。
 * 底部只留 32 —— 这一页是 NavDestination 二级页，底部悬浮胶囊在详情页已被摘掉，
 * 不需要像 tab 根页那样让位 120（工程约定「二级页底部留白 32」）。
 */
const PAGE_PAD: number = 16;
const BOTTOM_PAD: number = 32;

// ============ 新类型（Neo 侧统一 Ne2 / Nx 前缀，避开已有 Ne* 的声明合并） ============

/**
 * 一天的飞掠分组。
 *
 * ArkTS 禁止无类型对象字面量（`{ key, items }` 直接进数组会编译失败），
 * 所以先声明 class 再 new。
 */
class NxDayGroup {
  /** 分组键：atShort 的前 5 位「MM-DD」 */
  key: string = '';
  /** 组内条目，已按 atShort 升序 */
  items: NeItem[] = [];

  constructor(key: string, items: NeItem[]) {
    this.key = key;
    this.items = items;
  }
}

// ============ 纯函数（放在 @Component 外面，避免每次重绘重建闭包） ============

/**
 * 千分位。
 *
 * 为什么不用 toLocaleString：不同设备/系统版本的分组符可能是逗号、空格甚至
 * 不分组（ICU 数据缺失时静默退化成 "62779"），页面上就看不出是六万还是六百。
 * 这里自己按三位插逗号，结果完全确定。
 */
function neThousands(v: number): string {
  const s: string = String(v);
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
 * 数字兜底。`vkms` / `mag` 上游偶尔给字符串（"19.57"），
 * 直接 toFixed 会得到 "NaN" —— 所以先 Number() 再判 NaN，统一在这里做。
 */
function neNum(v: number | string | undefined | null): number {
  if (v === undefined || v === null) {
    return NaN;
  }
  return Number(v);
}

/**
 * 地月距离的「裸数字」。小程序模板是 `{{ x.lunar }}`，CI 已把它算成
 * 两位小数的 number（Math.round(lunar*100)/100），所以这里**不加单位、不补零**，
 * 原样 String() 即可 —— 加个 "LD" 会让右侧那列宽出 2 个字，把名称挤到换行。
 */
function fmtLunarNum(v: number | undefined | null): string {
  const n: number = neNum(v);
  return Number.isNaN(n) ? '—' : String(n);
}

/**
 * 相对速度：「19.57 km/s」。
 *
 * **不取整**：CI 里 `vkms` 已经是 Math.round(vh/36)/100 的两位小数，
 * 小程序模板直接 `{{ x.vkms }} km/s` 原样输出。这里若再 toFixed(1)，
 * 19.57 会变 19.6，与小程序对不上 —— 逐页对齐的要求下不做这一步美化。
 */
function fmtVkms(v: number | string | undefined | null): string {
  const n: number = neNum(v);
  return Number.isNaN(n) ? '' : String(n) + ' km/s';
}

/**
 * 直径区间："12–27 米"。
 *
 * NeoWs 只给上下限，两者相等时（罕见）收成一个数，避免出现「25–25 米」。
 * 这里返回空串表示「两端都没有」—— 调用方据此整段不画，而不是画一个「—」，
 * 因为 nr-meta 是一行用「·」串起来的短文本，中间夹个「直径 — 米」很难看。
 */
function fmtDiameterRange(dmin: number | undefined, dmax: number | undefined): string {
  const lo: number = neNum(dmin);
  const hi: number = neNum(dmax);
  if (Number.isNaN(lo) || Number.isNaN(hi)) {
    return '';
  }
  const a: number = Math.round(lo);
  const b: number = Math.round(hi);
  return a === b ? a + ' 米' : a + '–' + b + ' 米';
}

// ============ 组件 ============

@Component
export struct NeoView {
  // ============ 页面状态 ============

  /**
   * 按天分组后的列表。
   *
   * 为什么预切好放进 @State 而不是 build 里现算：ArkTS 的 build 每次重绘都会
   * 重建一遍方法返回的新数组，ForEach 的 key 生成器跟着重算，滚动中容易闪。
   */
  @State groups: NxDayGroup[] = [];

  /** 概览两格 + 一行小注 */
  @State totalKnown: number = 0;
  @State weekCount: number = 0;
  @State hazardous: number = 0;
  @State pastCount: number = 0;

  /** 「最近的一次」那条。null = 不画这张卡（小程序 v-if="closest"） */
  @State closest: NeClosest | null = null;

  /** 当前展开的那一条的 id；空串 = 全部收起 */
  @State expandedId: string = '';

  /** 首屏等待 */
  @State loading: boolean = true;
  /** 无缓存 + 网络失败。与「空列表」严格分开，见文件头四态说明 */
  @State failed: boolean = false;

  private scroller: Scroller = new Scroller();
  /** 防重入：切 tab 回来不应叠请求 */
  private loadingNow: boolean = false;

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadNeo(false);
  }

  // 本页无定时器：展开/收起全靠点击驱动，不需要 aboutToDisappear 清理。

  // ============ 加载 ============

  private loadNeo(force: boolean): void {
    if (this.loadingNow) {
      return;
    }
    this.loadingNow = true;
    this.loading = true;
    this.failed = false;

    // 先 peek：同步、零网络，冷启动能立刻把内容画出来（有缓存就不显示加载态）
    const cached: NePayload | null = repo.peek<NePayload>('neoNears');
    if (cached !== null) {
      this.applyPayload(cached);
      if (this.hasData()) {
        this.loading = false;
      }
    }

    const opts: LoadOptions<NePayload> = {
      force: force,
      onCache: (data: NePayload) => {
        this.applyPayload(data);
      },
      onUpdate: (data: NePayload) => {
        this.applyPayload(data);
      }
    };

    repo.load<NePayload>('neoNears', opts)
      .then((data: NePayload) => {
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有内容就别说失败：后台刷新失败不该把已经读到的列表清空
        this.failed = !this.hasData();
        hilog.warn(DOMAIN, TAG, 'neoNears 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingNow = false;
      });
  }

  /**
   * 数据落地。
   *
   * 中途一次半截数据（刷新失败但返回了骨架）不该把已有列表清空，
   * 所以「空列表 + 已有内容」直接忽略。
   */
  private applyPayload(data: NePayload): void {
    const raw: NeItem[] | undefined = data.list;
    const next: NeItem[] = raw !== undefined && raw !== null ? raw : [];
    if (next.length === 0 && this.hasData()) {
      return;
    }

    this.totalKnown = Number.isNaN(neNum(data.totalKnown)) ? 0 : Math.round(neNum(data.totalKnown));
    this.weekCount = Number.isNaN(neNum(data.count)) ? next.length : Math.round(neNum(data.count));
    this.hazardous = Number.isNaN(neNum(data.hazardous)) ? 0 : Math.round(neNum(data.hazardous));
    this.pastCount = Number.isNaN(neNum(data.pastCount)) ? 0 : Math.round(neNum(data.pastCount));

    const c: NeClosest | undefined = data.closest;
    this.closest = c !== undefined ? c : null;

    this.groups = this.buildGroups(next);
  }

  /**
   * 按 atShort 前 5 位分组，组键升序、组内 atShort 升序 —— 与小程序 computed.groups 逐行等价。
   *
   * 不用 Map：ArkTS 里 Map 的迭代顺序虽然稳定，但要转成数组仍要一套展开语法；
   * 这里用「键数组 + 桶数组」的下标对应，语义更直白，26~56 条的体量也够快。
   */
  private buildGroups(list: NeItem[]): NxDayGroup[] {
    const keys: string[] = [];
    const buckets: NeItem[][] = [];

    for (let i = 0; i < list.length; i++) {
      const item: NeItem = list[i];
      const short: string = strOf(item.atShort);
      const key: string = short.length >= 5 ? short.substring(0, 5) : short;
      let idx: number = keys.indexOf(key);
      if (idx < 0) {
        keys.push(key);
        buckets.push([]);
        idx = keys.length - 1;
      }
      buckets[idx].push(item);
    }

    const out: NxDayGroup[] = [];
    for (let i = 0; i < keys.length; i++) {
      // slice 一份再排：直接 sort 会改动 @State 引用的原始数组
      const items: NeItem[] = buckets[i].slice();
      items.sort((a: NeItem, b: NeItem): number => {
        const ak: string = strOf(a.atShort);
        const bk: string = strOf(b.atShort);
        return ak < bk ? -1 : (ak > bk ? 1 : 0);
      });
      out.push(new NxDayGroup(keys[i], items));
    }
    out.sort((a: NxDayGroup, b: NxDayGroup): number => {
      return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0);
    });
    return out;
  }

  private hasData(): boolean {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].items.length > 0) {
        return true;
      }
    }
    return false;
  }

  private retry(): void {
    this.loadNeo(true);
  }

  // ============ 派生展示值 ============

  /** 总数文案：0 → '—'（画个 0 会让人以为 NASA 只发现过 0 颗），其余千分位 */
  private totalKnownText(): string {
    return this.totalKnown > 0 ? neThousands(this.totalKnown) : '—';
  }

  /**
   * 「最近的一次」的时刻文案：「MM-DD HH:mm」。
   *
   * 小程序用正则从 ISO 串里抠捕获组；这里改用 substring ——
   * ArkTS 的正则字面量在单引号串里要写四层反斜杠，错了也不报错只是恒不匹配，
   * 而 ISO 串的格式 CI 是固定的（YYYY-MM-DDTHH:mm:ssZ），按下标切完全等价。
   */
  private closestShort(): string {
    const c: NeClosest | null = this.closest;
    if (c === null) {
      return '';
    }
    const at: string = strOf(c.at);
    if (at.length < 16 || at.charAt(10) !== 'T') {
      return '';
    }
    return at.substring(5, 10) + ' ' + at.substring(11, 16);
  }

  /** 「最近的一次」的地月距离：小程序直接输出数字，缺值给 '—' */
  private closestLunarText(): string {
    const c: NeClosest | null = this.closest;
    return c !== null ? fmtLunarNum(c.lunar) : '—';
  }

  /** 「最近的一次」的直径：只给上限（closest 里只有 dmax） */
  private closestDmaxText(): string {
    const c: NeClosest | null = this.closest;
    if (c === null) {
      return '';
    }
    const n: number = neNum(c.dmax);
    return Number.isNaN(n) ? '' : '直径约 ' + Math.round(n) + ' 米';
  }

  /** 单条是否属于「近」（20 倍月距以内）：右侧数字变天蓝，让人一眼看见 */
  private isNear(item: NeItem): boolean {
    const n: number = neNum(item.lunar);
    return !Number.isNaN(n) && n < 20;
  }

  // ============ 交互 ============

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  /** 点整卡：展开 / 收起。同一时刻只展开一条，与小程序 toggle 一致 */
  private toggle(item: NeItem): void {
    const id: string = strOf(item.id);
    this.expandedId = this.expandedId === id ? '' : id;
  }

  private isExpanded(item: NeItem): boolean {
    return this.expandedId.length > 0 && this.expandedId === strOf(item.id);
  }

  /**
   * 复制 JPL 轨道数据链接。
   *
   * 为什么不是「打开浏览器」：本工程没有配 https 的 want 白名单，
   * 直接 startAbility 打开外部链接在真机上会被拒。整个工程（资讯 / 详情页）
   * 都是「复制链接」策略，这里保持一致。文案对齐小程序「链接已复制，请到浏览器打开」。
   *
   * setData 的 promise 会抛 27787277（另一个复制/粘贴进行中）与
   * 27787278（复制被禁止），两者都必须给反馈 —— 否则点了没反应会被当成按钮坏了。
   */
  private copyJpl(item: NeItem): void {
    const url: string = strOf(item.jpl).trim();
    if (url.length === 0) {
      // 小程序无 jpl 时是静默 return；鸿蒙侧给一句反馈，避免「点了没反应」
      this.toast('这条没有轨道数据链接');
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => {
        this.toast('链接已复制，请到浏览器打开');
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '复制链接失败 code=%{public}d', e.code);
        this.toast('复制失败，请稍后重试');
      });
  }

  // ============ UI：页头 ============

  /**
   * 返回键。
   *
   * 路由（DetailPages.ets:230）是 `.hideTitleBar(true)`，系统标题栏连同返回箭头
   * 一起没了；本页又是「太空环境」拆出来的独立入口，没有 tab 兜底，
   * 不给出口就等于把用户关在这一页。小程序那边靠 nav-bar 组件的返回键，
   * 这里自绘一个同形制的小按钮。
   *
   * 为什么不做成整条 44vp 标题栏：页头本身已有 19vp 大标题（小程序 .hero-title 也是
   * 画在页面里的，不是 nav-bar 标题），再叠一条栏会让首屏掉 44vp 内容。
   */
  @Builder
  backBar() {
    Row() {
      Text('‹ 返回')
        .fontSize(13)
        .fontColor('#A7B4C7')
        .padding({ right: 12, top: 8, bottom: 8 })
        .onClick(() => {
          Nav.pop();
        })
    }
    .width('100%')
    .justifyContent(FlexAlign.Start)
    .padding({ top: 6 })
  }

  @Builder
  header() {
    Column() {
      Text('近地天体')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_TITLE)
        .width('100%')
        .maxLines(1)

      Text('未来一周掠过地球的小行星 · 按接近时间排')
        .fontSize(11)
        .fontColor('#6B7891')
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 3 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 小程序 .hero 是 padding: 24rpx 8rpx 14rpx → 12 / 4 / 7
    .padding({ top: 12, left: 4, right: 4, bottom: 7 })
  }

  // ============ UI：概览（两格 + 一行小注） ============

  /**
   * 一格：大数字在上、说明在下（与小程序 .glance 的 DOM 顺序一致）。
   * 数字 22vp / 说明 10.5vp，都居中。
   *
   * ⚠ 参数只有「第几格」这个常量，数值在**函数内部**读 this.xxx：
   * @Builder 按值传参不会建立响应式依赖，把 this.totalKnown 当实参传进来，
   * 后台刷新回填新数字时这一格不会重绘（要等整页重建才变）。
   */
  @Builder
  gCell(which: number) {
    Column() {
      Text(which === 0 ? this.totalKnownText() : String(this.weekCount))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(ACCENT)
        // line-height 1.1 → 24
        .lineHeight(24)
        .maxLines(1)

      Text(which === 0 ? '已发现的近地天体' : '未来 7 天接近次数')
        .fontSize(10.5)
        .fontColor('#6B7891')
        .maxLines(1)
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 概览卡：**两格**（已发现总数 / 未来 7 天次数）。
   *
   * 旧实现是三格（已知 / 本周 / 潜在威胁）—— 多出来的第三格在小程序里根本不存在，
   * 它把「潜在危险」提升成了概览级指标，而实测一周 20% 的天体都带这个标记，
   * 放到概览位会读成预警。小程序的做法是：把 hazardous 藏进下面那行小注里，
   * 用「其中 N 颗被标为…」这种从句降权。
   */
  @Builder
  glance() {
    Column() {
      Row() {
        this.gCell(0)

        // 竖分隔线：1 × 30，rgba(255,255,255,.07)
        Column()
          .width(1)
          .height(30)
          .backgroundColor(DIVIDER_LINE)

        this.gCell(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 13, bottom: 13, left: 5, right: 5 })
      .backgroundColor(CARD_BG)
      .borderRadius(10)
      .border({ width: 1, color: BORDER_FAINT })
    }
    .width('100%')
    .margin({ top: 3 })
  }

  /** 概览小注：把 pastCount 与 hazardous 合成一句从句 —— 有数、但不抢眼 */
  @Builder
  glanceNote() {
    Text('过去 7 天 ' + String(this.pastCount) + ' 次 · 其中 ' +
      String(this.hazardous) + ' 颗被标为「潜在危险」')
      .fontSize(10.5)
      .fontColor(TEXT_DIM)
      .lineHeight(16)
      .width('100%')
      .padding({ top: 6, left: 5, right: 5 })
  }

  // ============ UI：「最近的一次」 ============

  /**
   * 最近的一次：整页唯一一张带渐变的卡。
   *
   * 为什么值得单独一张：下面几十条都是「某天某颗掠过」，读者真正想知道的是
   * 「最近那颗离我们多远」。把它从列表里拎出来，等于先给答案再给清单。
   *
   * 渐变用 135deg（CSS 与 ArkUI 的 angle 都是顺时针、0 指向上），
   * 边框是天蓝 18% —— 比普通卡片的白色 5% 亮，但远不及「警示」的强度。
   */
  @Builder
  heroCard() {
    Column() {
      Row() {
        Text('最近的一次')
          .fontSize(9.5)
          .fontColor(ACCENT)
          .padding({ left: 7, right: 7, top: 1.5, bottom: 1.5 })
          .backgroundColor('#2438BDF8')
          .borderRadius(3)

        Text(this.closestShort())
          .fontSize(11)
          .fontColor('#8A97AD')
          .maxLines(1)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
      .alignItems(VerticalAlign.Center)

      Text(this.closestName())
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#E8EEF6')
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 7 })

      Row() {
        Text(this.closestLunarText() + ' 地月距离')
          .fontSize(15)
          // 小程序 hc-big 是 font-weight: 600；FontWeight.Medium 等于 500，会轻一档
          .fontWeight(600)
          .fontColor(ACCENT)
          .maxLines(1)

        if (this.closestDmaxText().length > 0) {
          Text(this.closestDmaxText())
            .fontSize(11.5)
            .fontColor('#8A97AD')
            .maxLines(1)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 5 })

      Text('月球与地球的距离算作 1，这颗相当于在 ' + this.closestLunarText() + ' 倍月距处掠过')
        .fontSize(10)
        .fontColor(TEXT_DIM)
        .lineHeight(16)
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(10)
    .border({ width: 1, color: '#2E38BDF8' })
    .linearGradient({
      angle: 135,
      colors: [['#16233A', 0.0], ['#121A28', 1.0]]
    })
    .margin({ top: 10 })
  }

  /** closest.disp 缺失时退回 id，别在最大的那张卡上画一行空白 */
  private closestName(): string {
    const c: NeClosest | null = this.closest;
    if (c === null) {
      return '';
    }
    const disp: string = strOf(c.disp).trim();
    return disp.length > 0 ? disp : strOf(c.id);
  }

  // ============ UI：分组头 ============

  @Builder
  dayHead(g: NxDayGroup) {
    Row() {
      Text(g.key)
        .fontSize(12.5)
        // day-date 是 600，Medium(500) 会细一档
        .fontWeight(600)
        .fontColor(TEXT_GROUP)
        .maxLines(1)

      Text(String(g.items.length) + ' 颗')
        .fontSize(10.5)
        .fontColor(TEXT_DIM)
        .maxLines(1)
    }
    .width('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    // 小程序 align-items: baseline；ArkUI 的 Row 没有 Baseline，用 Bottom 近似
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: 4, right: 4, bottom: 5 })
  }

  // ============ UI：单条 ============

  /**
   * 一条飞掠记录：左侧文字块（名称 + 元信息 + 展开区），右侧地月距离。
   *
   * 点整卡展开 4 行说明（小程序 nr-more），**不再**像旧实现那样直接复制 JPL ——
   * 复制是个有副作用的动作，不该是「点一下卡片」的默认结果。
   */
  @Builder
  nrow(item: NeItem) {
    Row() {
      Column() {
        // 名称 + 「潜在危险」chip
        Row() {
          Text(strOf(item.disp).length > 0 ? strOf(item.disp) : strOf(item.name))
            .fontSize(14)
            // nr-name 是 600（不是 500）
            .fontWeight(600)
            .fontColor(TEXT_NAME)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (item.haz === true) {
            Text('潜在危险')
              .fontSize(9)
              .fontColor(HAZ_FG)
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .backgroundColor('#1FE0B25A')
              .borderRadius(2.5)
              .margin({ left: 5 })
              .flexShrink(0)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 元信息一行：时间 · 直径 a–b 米 · v km/s。窄屏放不下就折行（小程序允许 wrap）
        Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
          Text(strOf(item.atShort))
            .fontSize(11)
            .fontColor('#6B7891')
            .maxLines(1)

          if (fmtDiameterRange(item.dmin, item.dmax).length > 0) {
            Text('·')
              .fontSize(10)
              .fontColor(SEP)
              .margin({ left: 4, right: 4 })
            Text('直径 ' + fmtDiameterRange(item.dmin, item.dmax))
              .fontSize(11)
              .fontColor('#6B7891')
              .maxLines(1)
          }

          if (fmtVkms(item.vkms).length > 0) {
            Text('·')
              .fontSize(10)
              .fontColor(SEP)
              .margin({ left: 4, right: 4 })
            Text(fmtVkms(item.vkms))
              .fontSize(11)
              .fontColor('#6B7891')
              .maxLines(1)
          }
        }
        .width('100%')
        .margin({ top: 4 })

        // 展开区：4 行说明 + 复制链接
        if (this.isExpanded(item)) {
          Column() {
            Text('距离 ' + this.wkmText(item) + ' 万公里（地球到月球约 38.4 万公里）')
              .fontSize(10.5)
              .fontColor('#8A97AD')
              .lineHeight(18)
              .width('100%')

            if (this.magText(item).length > 0) {
              Text('绝对星等 ' + this.magText(item) + '，数值越小代表天体本身越亮')
                .fontSize(10.5)
                .fontColor('#8A97AD')
                .lineHeight(18)
                .width('100%')
            }

            if (item.haz === true) {
              Text('「潜在危险」指的是尺寸够大、轨道够近，需要长期监测，不等于会撞上地球')
                .fontSize(10.5)
                .fontColor('#8A97AD')
                .lineHeight(18)
                .width('100%')
            }

            Text('复制 JPL 轨道数据链接')
              .fontSize(11)
              .fontColor(ACCENT)
              .margin({ top: 6 })
              .onClick(() => {
                this.copyJpl(item);
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .margin({ top: 7 })
          .padding({ top: 7 })
          // 虚线上边框：ArkUI 的 border 支持 style，但只给 top 边设虚线时
          // 用对象写法最省事，颜色 rgba(255,255,255,.08)
          .border({ width: { top: 1 }, color: DASH_LINE, style: BorderStyle.Dashed })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 右侧：地月距离（大号）+ 单位（小字）
      Column() {
        Text(fmtLunarNum(item.lunar))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isNear(item) ? ACCENT : TEXT_DIST)
          .lineHeight(18)
          .maxLines(1)

        Text('地月距离')
          .fontSize(9)
          .fontColor(TEXT_DIM)
          .maxLines(1)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.End)
      .margin({ left: 8 })
      .flexShrink(0)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10, left: 11, right: 11 })
    .backgroundColor(CARD_BG)
    .borderRadius(9)
    .border({ width: 1, color: BORDER_FAINT })
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.toggle(item);
    })
  }

  /** 最近距离（万公里）：整数，不带千分位（11vp 下千分位会把这一行挤爆） */
  private wkmText(item: NeItem): string {
    const n: number = neNum(item.wkm);
    return Number.isNaN(n) ? '—' : String(Math.round(n));
  }

  /** 绝对星等：一位小数；缺值给空串，由调用方整行不画 */
  private magText(item: NeItem): string {
    const n: number = neNum(item.mag);
    return Number.isNaN(n) ? '' : n.toFixed(1);
  }

  // ============ UI：三态 ============

  @Builder
  loadingBlock() {
    Column() {
      Text('加载中...')
        .fontSize(13)
        .fontColor('#6B7891')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    // 小程序 .loading 是 padding: 160rpx 40rpx → 80 / 20
    .padding({ top: 80, bottom: 80, left: 20, right: 20 })
  }

  @Builder
  emptyBlock() {
    Column() {
      Text('暂无近地天体数据')
        .fontSize(14)
        .fontColor('#8A97AD')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 80, bottom: 80, left: 20, right: 20 })
  }

  /**
   * 失败态：小程序没有这一态（reject 时会一直转圈）。
   * 鸿蒙侧保留，但要和「真的没有数据」明显区分开 —— 否则用户会以为 NASA 没数据。
   */
  @Builder
  failedBlock() {
    Column() {
      Text('近地天体加载失败')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_TITLE)

      Text('网络不给力，或缓存已被清理')
        .fontSize(11)
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
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 80, bottom: 80, left: 20, right: 20 })
  }

  // ============ UI：底部数据来源 ============

  @Builder
  sourceNote() {
    Text('数据来源：NASA NeoWs（近地天体观测）· 一天更新一次')
      .fontSize(10)
      .fontColor(NOTE_FG)
      .lineHeight(16)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ top: 17 })
  }

  // ============ build ============

  build() {
    Column() {
      this.backBar()
      this.header()

      List({ scroller: this.scroller }) {
        // 概览与小注常显：它们是「这件事有多大」的参照系，加载中也该先在位，
        // 加载完成后数字自然填上，页面不会整体跳一下
        ListItem() {
          this.glance()
        }

        ListItem() {
          this.glanceNote()
        }

        if (this.loading && !this.hasData()) {
          ListItem() {
            this.loadingBlock()
          }
        } else if (this.failed && !this.hasData()) {
          ListItem() {
            this.failedBlock()
          }
        } else if (!this.hasData()) {
          ListItem() {
            this.emptyBlock()
          }
        } else {
          if (this.closest !== null) {
            ListItem() {
              this.heroCard()
            }
          }

          ForEach(this.groups, (g: NxDayGroup) => {
            ListItem() {
              this.dayHead(g)
            }
            .padding({ top: 13 })

            ForEach(g.items, (item: NeItem) => {
              ListItem() {
                this.nrow(item)
              }
              .padding({ bottom: 6 })
            }, (item: NeItem) => strOf(item.id) + '@' + strOf(item.at) +
              (this.isExpanded(item) ? '#open' : '#closed'))
          }, (g: NxDayGroup) => g.key)

          ListItem() {
            this.sourceNote()
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .cachedCount(3)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    .alignItems(HorizontalAlign.Start)
    // 不做星空背景：这一页信息密度高，星点会压住 10vp 的小字
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
  }
}
