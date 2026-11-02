/**
 * view/MineView.ets —— 「我的」tab（按小程序 pages/mine/mine.vue 视觉重写）
 *
 * 视觉基准（小程序实测截图，1:1 复刻）：
 *   整页星空背景
 *   → 居中圆形火箭 logo（56vp，深蓝底 + 青色边）
 *   → 双色字标 Space / Launch（紧贴无空格）
 *   → 一句 tagline「记录人类成为多星球物种的进程」
 *   → 三格统计（数字 20vp Bold 白 / 标签 10vp 灰）
 *   → 虚线边框提示卡（☆ + 两行说明）
 *   → 分组标题「探索」+ 2×2 四宫格（图标 / 标题 / 副标题）
 *   → 分组标题「数据与设置」+ 四行功能卡（带 chevron）
 *   → 分组标题「关于」+ 版本 / 构建 / 数据来源
 *   → CC-BY 署名页脚
 *
 * 与小程序的**有意差异**（各条都说明为什么，不是偷懒）：
 *   1. 统计三格：小程序的「收藏 0 / 提醒 0 / 版本」在鸿蒙侧曾经是三个恒为 0 的
 *      假数字（收藏存储层尚未接入），留着只会误导。现在收藏已接入，第 3 格改回
 *      **真实收藏数**（favCount()），前两格保持真实可诊断的数据集数（FILES.size）
 *      与数据版本（DATA_VERSION）；缓存项数与缓存目录、占用一起放到下面那行小字里。
 *      提醒功能仍未接入，所以不出现「提醒」格 —— 不摆一个永远点不动的假入口。
 *   2. 虚线提示卡换了文案：小程序写「在详情页点『☆ 收藏』或『提醒』」。鸿蒙版现在
 *      收藏已实现、提醒没有，所以文案只讲收藏，并整卡可点直达收藏清单。
 *      卡片、图标、边框、字号全部保持一致。
 *   3. 四宫格点击跳到鸿蒙侧已实现的四个页面（StatsView / SpaceAssetsView /
 *      NeoView / EventsView），由 Index.ets 的 PageMap 分发、共用 Nav.pushBlank。
 *
 * 为什么这一页也要星空：小程序「我的」页本来就有（与「今日」同款 160 颗星）。
 * 复用 components/StarField（不改它），按它文件头写的用法作为 Stack 第一个子节点。
 * 每个 tab 是独立 TabContent，各有一个 StarField 实例，互不干扰。
 *
 * 数据来源（硬性义务）：发射与航天员数据来自 The Space Devs（LL2），
 * 卫星编目来自 Jonathan McDowell 的 GCAT（CC-BY 4.0，必须署名），图像来自 NASA。
 * 页脚小字与「数据结构说明 / 关于」两个弹窗是这条义务的落点，**不要删**。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions, DataSet, CacheStats } from '../data/Repository';
import { fileStore } from '../data/FileStore';
import { FILES, DATA_VERSION } from '../constants/Dataset';
import { formatGeneratedAt } from '../utils/Format';
import { StarField } from '../components/StarField';
import { Nav, ROUTE_STATS, ROUTE_ASSETS, ROUTE_NEO, ROUTE_EVENTS, ROUTE_FAVORITES, ROUTE_VERSION } from '../routes/Nav';
import { favInit, favCount, FAV_VERSION_KEY } from '../data/Favorites';
import { common } from '@kit.AbilityKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'MineView';

/**
 * 版本号。
 *
 * **必须手动与 AppScope/app.json5 的 versionName 保持同步**。
 * 为什么不在运行时读：app.json5 是编译期配置，ArkTS 侧没有直接读它的 API；
 * 走 bundleManager 只能拿到 bundleName / versionCode，要拿 versionName 得
 * 按包名查 BundleInfo，页面里为此引一个系统能力不划算。当前值 '1.0.0'
 * 即 app.json5 的 versionName。
 */
const APP_VERSION: string = '1.0.0';

/**
 * 构建日期，同样手写。只到「日」：这一行的用途是回答「我装的是哪一版」，
 * 精确到秒没有意义，改版本号时顺手改这里。
 */
const APP_BUILD: string = '2026-11-02';

/** 配色（全站统一，与 TodayView / FloatingTabBar 同源） */
const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TEXT_SECONDARY: string = '#A7B4C7';
const TEXT_TERTIARY: string = '#55617A';
const ACCENT: string = '#38BDF8';
/** 收藏星色（与详情页顶栏星标同色，跨页一致） */
const STAR: string = '#F5C33B';
const DIVIDER_COLOR: string = '#1E2637';
/** 提示卡虚线边框色（小程序 1px #2a3547） */
const DASH_COLOR: string = '#2A3547';
/** 提示卡正文色（小程序 #7a8598），比三级文字稍亮，保证 11vp 也读得清 */
const TEXT_HINT: string = '#7A8598';
/** 标签/副标题灰（小程序 #6b7891） */
const TEXT_LABEL: string = '#6B7891';
/** 火箭 logo 底与边（小程序 #1a2a3a 深蓝 + 青色描边） */
const LOGO_BG: string = '#1A2A3A';
const LOGO_RING: string = '#6638BDF8';

/** 页面左右内边距 */
const PAGE_PAD: number = 16;
/** logo 直径（小程序约 56vp） */
const LOGO_SIZE: number = 56;
/**
 * 四宫格卡高度。写死是为了同一行两张卡无论副标题长短都等高。
 * 112 是「图标行 + 标题行 + 两行副标题 + 上下内边距」的实测下限：
 * 再矮一行，emoji 22vp 与两行 10vp 副标题就会被压出边界。
 */
const TILE_H: number = 112;

/**
 * 底部内边距 92vp：让开悬浮胶囊。
 * 胶囊本体 58 + 底部留白 20 = 78，再留 14 给胶囊顶上那层渐变。
 */
const BOTTOM_PAD: number = 92;

/**
 * 字节数 → 人读体积。
 * utils/Format.ets 是纯时间/文本格式化层，没有体积函数；而且只此一处用，
 * 放本地比往公共模块里塞一个专用函数干净。
 */
function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return String(Math.ceil(bytes)) + ' B';
  }
  const kb: number = bytes / 1024;
  if (kb < 1024) {
    return kb.toFixed(1) + ' KB';
  }
  return (kb / 1024).toFixed(1) + ' MB';
}

/**
 * 功能行描述。
 * 为什么用 class 而不是对象字面量：ArkTS 严格模式禁止无类型对象字面量，
 * 列表项必须有一个可 new 的类型。
 * 副标题**不放进这里** —— 它随状态变化，必须在 @Builder 内部现算，
 * 否则会踩「@Builder 按值传参不随状态刷新」的坑。
 */
class MnRow {
  icon: string = '';
  title: string = '';
  key: string = '';

  constructor(icon: string, title: string, key: string) {
    this.icon = icon;
    this.title = title;
    this.key = key;
  }
}

/**
 * 四宫格的一格。
 * 与 MnRow 同样必须显式建类：ArkTS 禁止无类型对象字面量。
 * 字段名刻意避开 size / width / height / content 等内置属性名（同名会被内置成员遮蔽）。
 */
class MnTile {
  icon: string = '';
  title: string = '';
  desc: string = '';
  /** 用于 toast 文案与将来跳转分发的稳定标识，不参与渲染 */
  key: string = '';

  constructor(icon: string, title: string, desc: string, key: string) {
    this.icon = icon;
    this.title = title;
    this.desc = desc;
    this.key = key;
  }
}

@Component
export struct MineView {
  // ============ 状态 ============

  /** 最近一次数据同步的人读时间（来自 upcoming 的 generatedAt） */
  @State lastSyncText: string = '尚未同步';
  /** 是否正在拉数据（只影响「数据更新」那行的副标题） */
  @State refreshing: boolean = false;
  /** 磁盘上已缓存的数据集个数 */
  @State cachedCount: number = 0;
  /** 缓存占用字节数 */
  @State cacheBytes: number = 0;
  /** 缓存目录（FileStore 未初始化时为空串） */
  @State cacheDir: string = '';
  /**
   * 收藏条数。
   *
   * 为什么不直接调 favCount() 当值用：@Builder 在渲染时求值，读不到变化；
   * 必须是个 @State，改了才会重绘。
   */
  @State favTotal: number = 0;
  /**
   * 订阅收藏版本号（data/Favorites.ets 里每改一次收藏就 +1）。
   *
   * **这是「从收藏页返回后数字不更新」的解**：本页在 TabContent 里是保活的，
   * `aboutToAppear` 一辈子只跑一次；`onPageShow` 在 TabContent 里也不触发；
   * 收藏页压的是另一个 NavPathStack 的详情层，pop 回来不会重建本组件。
   * 只有全局版本号能穿透这几种情况——不论用户是从收藏页删的、
   * 还是在任意发射详情页点星标改的，数字都会跟着变。
   */
  @StorageProp(FAV_VERSION_KEY) @Watch('onFavChanged') favVersion: number = 0;

  /** 四个功能行。key 是给 onRow 用的稳定标识，不参与渲染 */
  private rows: MnRow[] = [
    new MnRow('📖', '数据结构说明', 'data'),
    new MnRow('🔄', '数据更新', 'refresh'),
    new MnRow('🧹', '清理缓存', 'clear'),
    new MnRow('ℹ️', '关于', 'about')
  ];

  /** 探索四宫格。顺序即 1-2 / 3-4 的阅读顺序，与小程序一致 */
  private tiles: MnTile[] = [
    new MnTile('📊', '数据统计', '历年发射量', 'stats'),
    new MnTile('🛰️', '太空资产', '在轨统计·卫星百科·解体', 'assets'),
    new MnTile('☄️', '近地天体', '未来一周掠地日程', 'neo'),
    new MnTile('📅', '近期活动', 'EVA·轨道插入·飞船事件', 'events')
  ];

  // ============ 生命周期 ============

  aboutToAppear(): void {
    // 收藏要显式初始化一次：preferences 需要 Context，而这里是首个拿得到
    // `this.getUIContext()` 的时机（模块级没有 Context 可用）。
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      favInit(ctx);
    }
    this.readFavTotal();
    this.refreshCacheInfo();
    this.loadLastSync(false);
  }

  /**
   * 收藏版本号变了就地重读，不重建组件也不依赖导航时机。
   *
   * 形参 `propName` 必须留着：@Watch 回调签名是 `(propName: string) => void`，
   * 框架生成调用时总会传一个参数。
   */
  onFavChanged(propName: string): void {
    this.readFavTotal();
  }

  private readFavTotal(): void {
    this.favTotal = favCount();
  }

  // ============ 数据 ============

  /**
   * 读缓存现状。
   *
   * 用 repo.stats() 而不是自己扫目录：stats() 已经把「内存条目 / 磁盘键 /
   * 磁盘字节」一次算好，页面再拼一遍容易与数据层口径分叉。
   * 缓存目录另取 fileStore.getDir() —— stats() 里没有它，而「缓存到底写在
   * 哪」是用户排查时的第一个问题，必须给真实路径。
   */
  private refreshCacheInfo(): void {
    const s: CacheStats = repo.stats();
    this.cachedCount = s.diskKeys;
    this.cacheBytes = s.diskBytes;
    this.cacheDir = fileStore.getDir();
  }

  /**
   * 读上一次数据同步时间。
   *
   * 有意「先 peek 后 load」：
   *   peek() 只查内存 + 文件、绝不发网络请求，冷启动能立刻把上次时间亮出来；
   *   随后 load() 走正常链路，命中过期缓存时由 onUpdate 回填新时间。
   * 只认 load 的结果的话，弱网下这一行会长时间空白。
   */
  private loadLastSync(force: boolean): void {
    this.refreshing = true;

    const cached: DataSet | null = repo.peek<DataSet>('upcoming');
    if (cached !== null && cached.generatedAt !== undefined) {
      this.applyGeneratedAt(cached.generatedAt);
    }

    const opts: LoadOptions<DataSet> = {
      force: force,
      onUpdate: (data: DataSet) => {
        this.applyGeneratedAt(data.generatedAt);
        this.refreshCacheInfo();
      }
    };

    repo.load<DataSet>('upcoming', opts)
      .then((data: DataSet) => {
        this.applyGeneratedAt(data.generatedAt);
        this.refreshCacheInfo();
        this.refreshing = false;
      })
      .catch((err: BusinessError) => {
        // 失败不清空已有时间：上一次同步时间仍然是有意义的信息
        this.refreshing = false;
        hilog.warn(DOMAIN, TAG, '读取 upcoming 失败: %{public}s', err.message);
      });
  }

  /** generatedAt（ISO）→「11月2日 20:30」；解析不出来就说「尚未同步」 */
  private applyGeneratedAt(raw: string | undefined): void {
    if (raw === undefined || raw.length === 0) {
      this.lastSyncText = '尚未同步';
      return;
    }
    const shown: string = formatGeneratedAt(raw);
    this.lastSyncText = shown.length > 0 ? shown : '尚未同步';
  }

  /**
   * 行副标题。
   *
   * 刻意在 @Builder 渲染时调用，而不是算好了当参数传进去：
   * @Builder 的多参是**按值传递**，状态变量变化不会引起 Builder 内 UI 刷新，
   * 传字符串会让「占用 xx MB」「最后同步 xx」在清理/刷新后停留在旧值。
   */
  private subOf(key: string): string {
    if (key === 'refresh') {
      return this.refreshing ? '正在同步…' : '最后同步 ' + this.lastSyncText;
    }
    if (key === 'clear') {
      return '占用 ' + formatBytes(this.cacheBytes) + ' · 保留首屏数据';
    }
    if (key === 'about') {
      return 'v' + APP_VERSION + ' · 构建 ' + APP_BUILD;
    }
    return 'The Space Devs · NASA · GCAT';
  }

  /** 统一 toast 出口：本页只有「即将上线」「已释放 xx」两类轻提示 */
  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  // ============ 交互 ============

  private onRow(key: string): void {
    if (key === 'data') {
      this.showDataSourceDialog();
      return;
    }
    if (key === 'refresh') {
      this.loadLastSync(true);
      return;
    }
    if (key === 'clear') {
      this.showClearCacheDialog();
      return;
    }
    if (key === 'about') {
      this.showAboutDialog();
      return;
    }
  }

  /**
   * 四宫格点击。
   *
   * 对位小程序 pages/stats / space-assets / neo / events 四页，
   * 鸿蒙侧已各自实现为 view/StatsView、SpaceAssetsView、NeoView、EventsView，
   * 由 Index.ets 的 PageMap 分发。四页都无入参，所以共用 Nav.pushBlank。
   */
  private onTile(key: string): void {
    if (key === 'stats') {
      Nav.pushBlank(ROUTE_STATS);
    } else if (key === 'assets') {
      Nav.pushBlank(ROUTE_ASSETS);
    } else if (key === 'neo') {
      Nav.pushBlank(ROUTE_NEO);
    } else if (key === 'events') {
      Nav.pushBlank(ROUTE_EVENTS);
    } else {
      // key 只在内部产生、四值穷举，走到这里说明 tiles 数组被改漏了一项
      hilog.warn(DOMAIN, TAG, '四宫格出现未知 key: %{public}s', key);
    }
  }

  /**
   * 数据结构说明 —— 同时是 CC-BY 告知义务的正式落点。
   * 文案逐条说清哪一批数据来自哪儿、许可是什么，不写「本应用」这种空话。
   */
  private showDataSourceDialog(): void {
    AlertDialog.show({
      title: '数据结构说明',
      message: '发射与活动数据：The Space Devs · Launch Library 2（LL2）API；\n' +
        '航天员、空间站、远征队数据同源。\n\n' +
        '卫星编目与在轨资产统计：Jonathan McDowell · GCAT\n' +
        '（planet4589.org/space/gcat），CC-BY 4.0 授权，必须保留署名。\n\n' +
        '图像：NASA（APOD / EPIC / Image Library）。\n\n' +
        '全部数据由云端定时抓取后以静态 JSON 分发，App 只读；\n' +
        '不收集个人信息，也没有账号体系。',
      autoCancel: true,
      confirm: {
        value: '知道了',
        action: () => {
        }
      }
    });
  }

  private showAboutDialog(): void {
    AlertDialog.show({
      title: '关于 SpaceLaunch',
      message: '版本 v' + APP_VERSION + '\n' +
        '构建 ' + APP_BUILD + '\n\n' +
        '数据来源：The Space Devs (LL2) · NASA · Jonathan McDowell (GCAT)\n\n' +
        '开源许可：应用代码 MIT；数据按各自来源许可使用 ——\n' +
        'GCAT 为 CC-BY 4.0（署名 Jonathan McDowell），\n' +
        'NASA 图像属公有领域，LL2 数据遵循其 API 使用条款。',
      autoCancel: true,
      confirm: {
        value: '好',
        action: () => {
        }
      }
    });
  }

  /**
   * 清理缓存。
   *
   * 用 repo.vacuum(0) 而不是 repo.clearAll()：
   * clearAll() 会把 upcoming（首页首屏）一起清掉，下次冷启动要白等一次网络；
   * vacuum() 按 EVICT_ORDER 逐个删，并且**永不删 upcoming**，
   * 正好是「清大件、保首屏」的语义。targetBytes = 0 表示按名单清到底。
   */
  private showClearCacheDialog(): void {
    const sizeText: string = formatBytes(this.cacheBytes);
    AlertDialog.show({
      title: '清理缓存',
      message: '当前占用 ' + sizeText + '，共 ' + String(this.cachedCount) + ' 个数据集。\n\n' +
        '将删除「即将发射」之外的本地数据集（火箭 / 宇航员 / 卫星目录等），\n' +
        '「即将发射」保留，首屏不受影响。\n' +
        '清理后再次浏览相关页面需要重新下载。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清理',
        fontColor: ACCENT,
        action: () => {
          this.doVacuum();
        }
      }
    });
  }

  /** 清理结果用 toast 而不是弹窗：这一步没有需要用户决策的信息，弹窗只是多一次点击 */
  private doVacuum(): void {
    const freed: number = repo.vacuum(0);
    this.refreshCacheInfo();
    hilog.info(DOMAIN, TAG, '清理缓存释放 %{public}d 字节', freed);
    this.toast(freed > 0 ? '已释放 ' + formatBytes(freed) : '没有可清理的缓存');
  }

  // ============ UI ============

  /** 居中火箭 logo：深蓝圆 + 青色描边 + emoji 火箭（media 里没有火箭图，emoji 跨设备最稳） */
  @Builder
  logoBadge() {
    Stack({ alignContent: Alignment.Center }) {
      Circle({ width: LOGO_SIZE, height: LOGO_SIZE })
        .fill(LOGO_BG)
        .stroke(LOGO_RING)
        .strokeWidth(1)

      Text('🚀')
        .fontSize(26)
    }
    .width(LOGO_SIZE)
    .height(LOGO_SIZE)
  }

  /** 身份区：logo + 双色字标 + tagline，整体居中（小程序同款） */
  @Builder
  heroBlock() {
    Column() {
      this.logoBadge()

      // 双色字标：Space 白 + Launch 青。两个 Text 紧贴着排，中间不能留空格，
      // 否则会露出一道缝（小程序侧同样踩过）
      Row() {
        Text('Space')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Text('Launch')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(ACCENT)
      }
      .margin({ top: 14 })

      Text('记录人类成为多星球物种的进程')
        .fontSize(11)
        .fontColor(TEXT_LABEL)
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 16, bottom: 18 })
  }

  /**
   * 三格统计的一格。
   * 参数是 number 字面量（按值传入无副作用），动态值在内部现算，
   * 理由同 subOf()：@Builder 按值传参会冻结状态。
   */
  @Builder
  statCell(index: number) {
    Column() {
      // 三格分别是：数据集数 / 数据版本 / 收藏数。
      // 收藏数放第三格是刻意的：它和收藏页是同一份数据，用户核对时一眼能对得上。
      Text(index === 0 ? String(FILES.size) :
        (index === 1 ? String(DATA_VERSION) : String(this.favTotal)))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')

      Text(index === 0 ? '数据集' : (index === 1 ? '数据版本' : '收藏'))
        .fontSize(10)
        .fontColor(TEXT_LABEL)
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  statDivider() {
    Divider()
      .vertical(true)
      .height(26)
      .strokeWidth(1)
      .color(DIVIDER_COLOR)
  }

  /**
   * 数据概览：三格统计 + 一行真实缓存目录。
   *
   * 三格给的是「数据面」的三个数（数据集 / 版本 / 收藏）；缓存项数与占用
   * 这一行原本只在第三格里出现，现在挪到下面这行小字里 ——
   * 这一页对用户的实用价值是「我装了多少数据、存在哪、占多大」，
   * 三格数字换了也必须保住这三条信息，不能为了加收藏把它们挤掉。
   */
  @Builder
  overviewBlock() {
    Column() {
      Row() {
        // FILES.size 是数据层真实条目数（27），不写死数字
        this.statCell(0)
        this.statDivider()
        this.statCell(1)
        this.statDivider()
        this.statCell(2)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 真实路径（<filesDir>/dataCache/v{DATA_VERSION}/）+ 实际占用 + 缓存项数。
      // 用户排查「缓存写在哪」就靠这一行，不给模糊说法。
      // 缓存项数从第三格挪到这里，是因为第三格让给了收藏数（见 statCell 注释）。
      Text((this.cacheDir.length > 0 ? this.cacheDir : '缓存目录尚未初始化') +
        ' · ' + formatBytes(this.cacheBytes) + ' · ' + String(this.cachedCount) + ' 项')
        .width('100%')
        .fontSize(10)
        .fontColor(TEXT_TERTIARY)
        .lineHeight(15)
        .margin({ top: 12 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 16, bottom: 14, left: 8, right: 8 })
    .borderRadius(14)
    .backgroundColor(CARD_BG)
    .margin({ top: 4, bottom: 14 })
  }

  /**
   * 虚线提示卡（小程序同款 1vp 虚线 #2A3547、圆角 12）。
   *
   * 文案与小程序不同，见文件头「有意差异 2」：小程序写「在详情页点『☆ 收藏』
   * 或『提醒』」，鸿蒙版没有提醒功能，照抄就是骗用户去点不存在的东西。
   * 现在收藏已真实可用，这张卡整块变成入口：点一下直达收藏清单。
   * 视觉结构（☆ + 两行小字 + 虚线框）保持小程序原样。
   */
  @Builder
  hintCard() {
    Row() {
      Text(this.favTotal > 0 ? '★' : '☆')
        .fontSize(18)
        .fontColor(this.favTotal > 0 ? STAR : ACCENT)
        .margin({ right: 10 })

      Column() {
        Text('点这里查看收藏清单')
          .fontSize(11)
          .fontColor(TEXT_HINT)
          .lineHeight(17)

        Text(this.favTotal > 0
          ? '已收藏 ' + String(this.favTotal) + ' 条发射，长按可移除'
          : '在发射详情页点右上角 ☆ 就能收藏')
          .fontSize(11)
          .fontColor(TEXT_HINT)
          .lineHeight(17)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 右向箭头：暗示这张卡可点，不然虚线框看起来只是说明文字
      Text('›')
        .fontSize(18)
        .fontColor(TEXT_TERTIARY)
        .margin({ left: 8 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 14, bottom: 14, left: 14, right: 14 })
    .borderStyle(BorderStyle.Dashed)
    .borderWidth(1)
    .borderColor(DASH_COLOR)
    .borderRadius(12)
    .margin({ bottom: 20 })
    .onClick(() => {
      // 无入参页，走 pushBlank（与四宫格里的统计/资产/天体/活动同一门面）
      Nav.pushBlank(ROUTE_FAVORITES);
    })
  }

  /** 分组标题：15vp Bold 白（小程序「探索」「关于」同档） */
  @Builder
  groupTitle(title: string) {
    Text(title)
      .width('100%')
      .fontSize(15)
      .fontWeight(FontWeight.Bold)
      .fontColor('#FFFFFF')
      .margin({ top: 4, bottom: 10 })
  }

  /** 四宫格的一格：图标 / 标题 / 副标题，整块可点 */
  @Builder
  tileCell(index: number) {
    Column() {
      Text(this.tiles[index].icon)
        .fontSize(22)

      Text(this.tiles[index].title)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .margin({ top: 8 })

      Text(this.tiles[index].desc)
        .fontSize(10)
        .fontColor(TEXT_TERTIARY)
        .lineHeight(14)
        .margin({ top: 4 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    // 只给高度不给宽度：宽度由 layoutWeight 在 Row 里均分，
    // 同时写 width('100%') 会被 layoutWeight 覆盖，留着只是噪音
    .height(TILE_H)
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Start)
    .padding({ left: 14, right: 12, top: 14, bottom: 12 })
    .borderRadius(12)
    .backgroundColor(CARD_BG)
    .onClick(() => {
      this.onTile(this.tiles[index].key);
    })
  }

  /** 探索区：两行两列。Row 没有 flexWrap，直接两行写死（四格固定，不需要自适应） */
  @Builder
  exploreBlock() {
    Column() {
      Row({ space: 12 }) {
        this.tileCell(0)
        this.tileCell(1)
      }
      .width('100%')

      Row({ space: 12 }) {
        this.tileCell(2)
        this.tileCell(3)
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 20 })
  }

  /**
   * 一行功能。
   *
   * 图标位用 emoji 文本：图标资源尚未配齐（见 FloatingTabBar 顶部说明），
   * 此时 Image($r('app.media.ic_xxx')) 会因资源 id 不存在直接编译失败。
   * 图标到位后把 Text(icon) 换成 Image 即可，布局不用动。
   *
   * 参数是 number 字面量（按值传递无副作用），动态文案在内部读 this 状态。
   */
  @Builder
  rowCell(index: number) {
    Row() {
      Text(this.rows[index].icon)
        .fontSize(16)
        .width(24)
        .textAlign(TextAlign.Center)

      Column() {
        Text(this.rows[index].title)
          .fontSize(14)
          .fontColor('#FFFFFF')

        Text(this.subOf(this.rows[index].key))
          .fontSize(10)
          .fontColor(TEXT_TERTIARY)
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })

      Text('›')
        .fontSize(18)
        .fontColor(TEXT_TERTIARY)
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onRow(this.rows[index].key);
    })
  }

  /** 功能行组：一张卡里排四行，行间 1px 分割线 */
  @Builder
  actionCard() {
    Column() {
      this.rowCell(0)
      Divider().strokeWidth(1).color(DIVIDER_COLOR)
      this.rowCell(1)
      Divider().strokeWidth(1).color(DIVIDER_COLOR)
      this.rowCell(2)
      Divider().strokeWidth(1).color(DIVIDER_COLOR)
      this.rowCell(3)
    }
    .width('100%')
    .padding({ left: 16, right: 16 })
    .borderRadius(14)
    .backgroundColor(CARD_BG)
    .margin({ bottom: 20 })
  }

  /** 关于卡：版本 / 构建 / 数据来源，比弹窗更适合长读（弹窗只留给「关于」行的详情） */
  @Builder
  aboutCard() {
    Column() {
      Row() {
        Text('版本')
          .fontSize(12)
          .fontColor(TEXT_TERTIARY)
          .layoutWeight(1)
        Text('v' + APP_VERSION)
          .fontSize(12)
          .fontColor(TEXT_SECONDARY)
        Text('›')
          .fontSize(14)
          .fontColor(TEXT_TERTIARY)
          .margin({ left: 6 })
      }
      .width('100%')
      // 版本行整行可点 → 版本记录页。小程序这里也是「版本记录」独立页，
      // 但入口在「我的 → 关于」分组里单独一行；鸿蒙侧版本号直接就是入口，
      // 少一行、语义一样（点版本号看版本记录是通用直觉）。
      .onClick(() => {
        Nav.pushBlank(ROUTE_VERSION);
      })

      Row() {
        Text('构建')
          .fontSize(12)
          .fontColor(TEXT_TERTIARY)
          .layoutWeight(1)
        Text(APP_BUILD)
          .fontSize(12)
          .fontColor(TEXT_SECONDARY)
      }
      .width('100%')
      .margin({ top: 8 })

      Divider()
        .strokeWidth(1)
        .color(DIVIDER_COLOR)
        .margin({ top: 12, bottom: 10 })

      Text('数据来源')
        .fontSize(12)
        .fontColor(TEXT_TERTIARY)

      Text('发射与活动：The Space Devs · Launch Library 2 (LL2)\n' +
        '卫星编目：Jonathan McDowell · GCAT（CC-BY 4.0）\n' +
        '图像：NASA（APOD / EPIC / Image Library）')
        .width('100%')
        .fontSize(11)
        .fontColor(TEXT_SECONDARY)
        .lineHeight(17)
        .margin({ top: 5 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .borderRadius(14)
    .backgroundColor(CARD_BG)
    .margin({ bottom: 14 })
  }

  /** CC-BY 署名页脚 —— 项目硬性义务，任何重构都不要删这几行（原文不得改写） */
  @Builder
  creditFooter() {
    Column() {
      Text('发射与航天员数据 © The Space Devs (LL2) · 卫星目录 © Jonathan McDowell (CC-BY) · 图像 © NASA')
        .fontSize(10)
        .fontColor(TEXT_TERTIARY)
        .lineHeight(16)
        .textAlign(TextAlign.Center)

      Text('SpaceLaunch · 为航天爱好者而做')
        .fontSize(9)
        .fontColor('#3E4860')
        .margin({ top: 8 })
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 4, bottom: 8 })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 1 星空底层：绝对定位铺满、不参与命中测试，必须是 Stack 的第一个子节点
      StarField()

      // 2 内容层
      Scroll() {
        Column() {
          this.heroBlock()
          this.overviewBlock()
          this.hintCard()

          this.groupTitle('探索')
          this.exploreBlock()

          this.groupTitle('数据与设置')
          this.actionCard()

          this.groupTitle('关于')
          this.aboutCard()

          this.creditFooter()
        }
        .width('100%')
        // 左右 16 + 底部 92vp 胶囊让位
        .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }
}
