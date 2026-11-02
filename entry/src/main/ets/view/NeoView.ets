/**
 * view/NeoView.ets —— 近地天体（未来一周掠过地球的小行星）
 *
 * 对位小程序 `pages/neo` 的列表态。这一页在**主 tab 体系里**（底部有悬浮胶囊），
 * 所以根容器下方留 120 让位给胶囊，而不是详情页那种 24。
 *
 * ── 数据链路（与 NewsListView / LaunchView 同口径）──
 *   repo.peek<NePayload>('neoNears')  —— 同步、零网络，冷启动立刻有内容
 *   repo.load<NePayload>('neoNears', {onCache, onUpdate})
 *     onCache  —— 命中原生缓存时立刻上屏
 *     onUpdate —— 缓存过期、后台静默刷新拿到新数据时回填（只有 generatedAt 变了才回调）
 *
 * ── 四态为什么必须分开（原项目踩过的坑）──
 *   小程序 utils/data.js 的 load() 在「弱网 + 无缓存」时是 **reject**，不是返回 null。
 *   如果 catch 里顺手置 loaded = true，页面就永久停在空列表，用户以为真的没有天体。
 *   所以这里**没有 loaded 这个变量**：失败用独立的 @State failed 表示，
 *   与「空列表」严格分开：
 *     loading && 空    → 加载中
 *     failed  && 空    → 加载失败 + 重试
 *     !failed && 空    → 暂无数据
 *     list 非空        → 列表（此时哪怕刷新失败也继续显示旧数据）
 *
 * ── 时间分组为什么要前端自己算（CI 没给）──
 *   CI 只给 `at`（ISO）与 `pastCount`（条数），没给分组边界。以「现在」为界
 *   把列表切成「即将接近 / 已掠过」两块，直接用 Date.now() 与 Date.parse(at)
 *   比较即可；`pastCount` 只在数据完全对齐时等于过去组长度，缓存跨过午夜就会
 *   对不上，所以**不用它当分组依据**，也就不用处理「边界那天」这种麻烦。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { NeItem, NePayload } from '../model/Neo';
import { strOf } from '../utils/Format';

const DOMAIN: number = 0x0000;
const TAG: string = 'NeoView';

// ============ 视觉常量（工程约定） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
/** 琥珀：PHA 用色。**刻意不用红色** —— 潜在威胁不等于撞击预警 */
const WARN: string = '#F5C33B';
/** 分隔线：比卡片亮一点点，够看出分栏又不抢视线 */
const DIVIDER: string = '#1E2736';

/** 页面左右内边距（与 TodayView / LaunchView 的 12 对齐） */
const PAGE_PAD: number = 12;
/** 底部 120：本页在主 tab 里，底部悬浮胶囊要占位 */
// 底部留白：本页是 NavDestination 二级页，胶囊在详情页打开时已被摘掉，
// 不需要按 tab 根页那样让位 92~120，32 只够滑到底时最后一行不贴边。
const BOTTOM_PAD: number = 32;

// 提示条文案：**一字不改**。措辞是做过风险沟通的，「20% 上下 / Sentry 为 0」
// 这两句是核心 —— 删掉就变成纯口号，反而更容易被误读成预警。
const NOTICE_TEXT: string = 'PHA（潜在威胁小行星）不等于会撞击地球：本周命中通常在 20% 上下，' +
  'Sentry 风险表为 0。这里只做科普，不做预警。';

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

/** 地月距离："140.5 LD"；取不到给 "—" 而不是 0（0 LD 会被读成撞上了） */
function fmtLunar(v: number | undefined | null): string {
  const n: number = neNum(v);
  return Number.isNaN(n) ? '—' : n.toFixed(1) + ' LD';
}

/**
 * 最近距离（万公里）：整数。
 *
 * 这里**不加千分位**：卡片第二行是三格等分，11vp 下「最近 5,403 万公里」比
 * 「最近 5403 万公里」宽出两个字，第三格的「速度 xx.x km/s」就会被挤到截断。
 * 千分位只留给概览卡的六位数总数量。
 */
function fmtWkm(v: number | undefined | null): string {
  const n: number = neNum(v);
  return Number.isNaN(n) ? '—' : Math.round(n) + ' 万公里';
}

/** 相对速度：一位小数 */
function fmtVkms(v: number | string | undefined | null): string {
  const n: number = neNum(v);
  return Number.isNaN(n) ? '—' : n.toFixed(1) + ' km/s';
}

/** 视星等：一位小数 */
function fmtMag(v: number | string | undefined | null): string {
  const n: number = neNum(v);
  return Number.isNaN(n) ? '—' : n.toFixed(1);
}

/**
 * 直径区间："12–27 米"。
 *
 * NeoWs 只给上下限，两者相等时（罕见）收成一个数，避免出现「25–25 米」。
 * 只有一端时 display 单值 —— 缺的是估算范围，不是整条数据，不该整行 `—`。
 */
function fmtDiameter(dmin: number | undefined | null, dmax: number | undefined | null): string {
  const lo: number = neNum(dmin);
  const hi: number = neNum(dmax);
  const hasLo: boolean = !Number.isNaN(lo);
  const hasHi: boolean = !Number.isNaN(hi);
  if (hasLo && hasHi) {
    const a: number = Math.round(lo);
    const b: number = Math.round(hi);
    return a === b ? a + ' 米' : a + '–' + b + ' 米';
  }
  if (hasLo) {
    return '≥ ' + Math.round(lo) + ' 米';
  }
  if (hasHi) {
    return '≤ ' + Math.round(hi) + ' 米';
  }
  return '—';
}

/** 时间戳（毫秒）。解析失败返回 -1，调用方按「无法判定」处理，不参与过去分组 */
function atMillis(item: NeItem): number {
  const t: number = Date.parse(strOf(item.at));
  return Number.isNaN(t) ? -1 : t;
}

// ============ 组件 ============

@Component
export struct NeoView {
  // ============ 页面状态 ============

  /**
   * 按「现在」切成两组。
   *
   * 为什么用两个 @State 数组而不是一个 list + 渲染时过滤：
   * ArkTS 对「方法返回新数组」在 build 里每次重绘都会重建一遍，ForEach 的
   * key 生成器也就要重算，滚动中容易看到闪烁。预切好只在数据落地时算一次。
   */
  @State upcoming: NeItem[] = [];
  @State past: NeItem[] = [];

  /** 概览三格：总数 / 本周条数 / 潜在威胁数 */
  @State totalKnown: number = 0;
  @State weekCount: number = 0;
  @State hazardous: number = 0;

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
      if (this.totalItems() > 0) {
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
        this.failed = this.totalItems() === 0;
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
    if (next.length === 0 && this.totalItems() > 0) {
      return;
    }

    this.totalKnown = Number.isNaN(neNum(data.totalKnown)) ? 0 : Math.round(neNum(data.totalKnown));
    this.weekCount = Number.isNaN(neNum(data.count)) ? next.length : Math.round(neNum(data.count));
    this.hazardous = Number.isNaN(neNum(data.hazardous)) ? 0 : Math.round(neNum(data.hazardous));

    this.splitByNow(next);
  }

  /**
   * 以「现在」为界切成两组，保持 CI 原始顺序（接近时间升序）。
   *
   * at 解析失败（-1）的条目归到「即将接近」：宁可让它正常显示、不被压暗，
   * 也不要因为一个坏时间戳把它藏进「已掠过」里。
   */
  private splitByNow(list: NeItem[]): void {
    const now: number = Date.now();
    const up: NeItem[] = [];
    const gone: NeItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const item: NeItem = list[i];
      const t: number = atMillis(item);
      if (t >= 0 && t < now) {
        gone.push(item);
      } else {
        up.push(item);
      }
    }
    this.upcoming = up;
    this.past = gone;
  }

  private totalItems(): number {
    return this.upcoming.length + this.past.length;
  }

  private retry(): void {
    this.loadNeo(true);
  }

  // ============ 交互 ============

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  /**
   * 复制 JPL 详情链接。
   *
   * 为什么不是「打开浏览器」：本工程的 module.json5 没有 ohos.permission.INTERNET
   * 之外的浏览器 want 声明，也没有配 want 跳转白名单，直接 startAbility 打开
   * https 链接在真机上会被拒。整个工程（资讯 / 详情页）都是「复制链接」策略，
   * 这里保持一致，用户粘到浏览器就能看。
   *
   * setData 的 promise 版本会抛 27787277（另一个复制/粘贴进行中）与
   * 27787278（复制被禁止），两者都必须给反馈 —— 否则点了没反应会被当成按钮坏了。
   */
  private copyJpl(item: NeItem): void {
    const url: string = strOf(item.jpl).trim();
    if (url.length === 0) {
      this.toast('这条没有详情链接');
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => {
        this.toast('链接已复制');
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '复制链接失败 code=%{public}d', e.code);
        this.toast('复制失败，请稍后重试');
      });
  }

  // ============ UI：页头 ============

  @Builder
  header() {
    Column() {
      Text('近地天体')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .letterSpacing(1)
        .width('100%')

      Text('未来一周掠过地球的小行星 · 按接近时间排')
        .fontSize(11)
        .fontColor('#6B7891')
        .width('100%')
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8, bottom: 12 })
  }

  // ============ UI：概览三格 ============

  /**
   * 一格：说明在上、大数字在下（数字与单位同排）。
   *
   * 为什么说明放上面：任务书里的三格读作「已知 N 个 / 本周 N 次 / 潜在威胁 N」，
   * 说明词在前、数字在后。按这个顺序竖排，一列读下来就是原话；
   * 反过来（数字在上）会读成「N 潜在威胁」，顺序是错的。
   *
   * 为什么数字与单位同排而不塞进说明行：三格并排时每格只有约 1/3 屏宽，
   * 「已知 62,779 个」排成一行会挤到换行（Text 没有 maxWidth，只能靠 maxLines 硬截）。
   */
  @Builder
  statCell(value: string, unit: string, label: string, color: string) {
    Column() {
      Text(label)
        .fontSize(11)
        .fontColor('#6B7891')
        .maxLines(1)

      Row() {
        Text(value)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(color)
          .maxLines(1)
        if (unit.length > 0) {
          Text(unit)
            .fontSize(11)
            .fontColor('#6B7891')
            .maxLines(1)
            .margin({ left: 2, bottom: 1 })
        }
      }
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 3 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 竖分隔线：高 26，避免三格数字糊成一片。
   *
   * 用 Divider().vertical(true) 而不是「宽 1 的空 Column」：空容器在 Row 里
   * 交叉轴对齐为 Center 时高度会塌到 0，分隔线就看不见了。Divider 有默认绘制尺寸，
   * MineView.statDivider 也是这么写的。
   */
  @Builder
  statDivider() {
    Divider()
      .vertical(true)
      .height(26)
      .strokeWidth(1)
      .color(DIVIDER)
  }

  @Builder
  overviewCard() {
    Row() {
      this.statCell(neThousands(this.totalKnown), '个', '已知', TEXT_MAIN)
      this.statDivider()
      // 「本周 N 次」：count 是窗口内条数，不是已知总数（见 model/Neo.ets 注释）
      this.statCell(String(this.weekCount), '次', '本周', TEXT_MAIN)
      this.statDivider()
      // 潜在威胁用琥珀色 —— 表达「值得关注」，不表达「危险」（不用红色）
      this.statCell(String(this.hazardous), '', '潜在威胁', WARN)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(14)
    .backgroundColor(CARD_BG)
    .borderRadius(12)
  }

  // ============ UI：提示条 ============

  /**
   * 科普提示。
   *
   * 左侧 3vp 琥珀竖条 + 浅底卡片：用「信息条」而不是「警告条」的视觉
   * （警告条一般是整圈描边 + 图标），与文案里「不做预警」的立场一致。
   *
   * 竖条用 border-left 而不是一个 width(3) 的子 Column：Row 的高度由文字行数撑开，
   * 子节点写 height('100%') 在自适应的父容器里拿不到确定高度，会缩成 0 或撑满屏幕。
   * 边框天然跟随 Row 的最终高度，行数变了也不用管。
   */
  @Builder
  noticeCard() {
    Row() {
      Text(NOTICE_TEXT)
        .fontSize(11)
        .lineHeight(17)
        .fontColor(TEXT_SUB)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 13, right: 12, top: 12, bottom: 12 })
    .backgroundColor(CARD_BG)
    .borderRadius(12)
    .border({ width: { left: 3 }, color: WARN })
  }

  // ============ UI：分组标题 ============

  @Builder
  groupHeader(title: string, count: number) {
    Row() {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      Text(String(count) + ' 条')
        .fontSize(11)
        .fontColor(TEXT_DIM)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 4, bottom: 8 })
  }

  // ============ UI：chip ============

  /**
   * 小标签。
   *
   * 底色用 8 位十六进制（#33 + 6 位）而不是 opacity(0.2)：
   * opacity 会把文字一起压透明，chip 字就发灰了；直接给带 alpha 的底色只影响底板。
   */
  @Builder
  chip(text: string, bg: string, fg: string) {
    Text(text)
      .fontSize(10)
      .fontColor(fg)
      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      .backgroundColor(bg)
      .borderRadius(6)
      .margin({ left: 6 })
  }

  // ============ UI：单条卡片 ============

  /**
   * 一条飞掠记录。
   *
   * `isPast` 由调用方传：已掠过的整卡压到 0.55，
   * 视觉上退到背景层，但**仍然可点**（历史条目也值得看 JPL 页）。
   */
  @Builder
  neoCard(item: NeItem, isPast: boolean) {
    Column() {
      // 首行：名称 + 接近时刻
      Row() {
        Text(strOf(item.disp).length > 0 ? strOf(item.disp) : strOf(item.name))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_MAIN)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(strOf(item.atShort))
          .fontSize(11)
          .fontColor(TEXT_DIM)
          .maxLines(1)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 第二行：三格数据。用等分 triple 而不是空格拼接，
      // 这样三列数字的起始位置在所有卡片上对齐，纵向扫读不会跳
      Row() {
        Text('地月距离 ' + fmtLunar(item.lunar))
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .layoutWeight(1)
        Text('最近 ' + fmtWkm(item.wkm))
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .layoutWeight(1)
        Text('速度 ' + fmtVkms(item.vkms))
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 6 })

      // 第三行：直径 + 视星等 + chip。
      // Row 没有 flexWrap（ArkTS 硬约束），两个 chip 同时出现时容易顶出卡片，
      // 所以这一行用 Flex({ wrap }) 让它自动折行
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        Text('直径 ' + fmtDiameter(item.dmin, item.dmax))
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .maxLines(1)
        Text('视星等 ' + fmtMag(item.mag))
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .maxLines(1)
          .margin({ left: 12 })

        if (item.haz === true) {
          this.chip('潜在威胁', '#33F5C33B', WARN)
        }
        if (item.sentry === true) {
          this.chip('Sentry', '#33FF3B30', '#FF3B30')
        }
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(CARD_BG)
    .borderRadius(12)
    .opacity(isPast ? 0.55 : 1.0)
    .onClick(() => {
      this.copyJpl(item);
    })
  }

  // ============ UI：三套占位 ============

  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ACCENT)
      Text('正在获取近地天体…')
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
      Text('近地天体加载失败')
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
  emptyBlock() {
    Column() {
      Text('☄')
        .fontSize(34)
        .opacity(0.5)
      Text('本周没有近地天体记录')
        .fontSize(13)
        .fontColor(TEXT_SUB)
        .margin({ top: 10 })
      Text('数据来自 NASA NeoWs，每天更新一次')
        .fontSize(11)
        .fontColor(TEXT_DIM)
        .margin({ top: 6 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ============ build ============

  build() {
    Column() {
      this.header()

      if (this.totalItems() === 0) {
        // 空列表分成三种，绝不合并（见文件头四态说明）
        if (this.loading) {
          this.loadingBlock()
        } else if (this.failed) {
          this.failedBlock()
        } else {
          this.emptyBlock()
        }
      } else {
        List({ scroller: this.scroller }) {
          // 概览与提示条也放进 List：页面整体只有一个滚动容器，
          // 滚动到列表中部时它们自然滚出屏幕，不会占着首屏高度
          ListItem() {
            this.overviewCard()
          }
          .padding({ bottom: 10 })

          ListItem() {
            this.noticeCard()
          }
          .padding({ bottom: 14 })

          if (this.upcoming.length > 0) {
            ListItem() {
              this.groupHeader('即将接近', this.upcoming.length)
            }
            ForEach(this.upcoming, (item: NeItem) => {
              ListItem() {
                // 未来条目正常亮度
                this.neoCard(item, false)
              }
              .padding({ bottom: 10 })
            }, (item: NeItem) => 'up-' + strOf(item.id) + '@' + strOf(item.at))
          }

          if (this.past.length > 0) {
            // 两组之间留一点呼吸；已掠过组整体在下面，不需要额外分隔线
            ListItem() {
              this.groupHeader('已掠过', this.past.length)
            }
            .padding({ top: this.upcoming.length > 0 ? 6 : 0 })

            ForEach(this.past, (item: NeItem) => {
              ListItem() {
                // 已掠过压到 0.55，视觉退后但仍可点
                this.neoCard(item, true)
              }
              .padding({ bottom: 10 })
            }, (item: NeItem) => 'past-' + strOf(item.id) + '@' + strOf(item.at))
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(3)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    .alignItems(HorizontalAlign.Start)
    // 不铺星空：这一页信息密度高，星点会压住小字。底部 120 给悬浮胶囊让位
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
  }
}
