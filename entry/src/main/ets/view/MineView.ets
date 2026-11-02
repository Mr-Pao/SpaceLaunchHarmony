/**
 * view/MineView.ets —— 「我的」tab
 *
 * 对位小程序 pages/mine/mine.vue 的「身份区 + 关于」这两块。
 * 小程序里另有收藏发射 / 收藏火箭 / 提醒三份清单，鸿蒙侧还没有收藏存储层，
 * 本轮**不做**这三块 —— 先画出永远空着的区块只会误导用户。
 *
 * 结构（自上而下）：
 *   页头（我的 / 一句副标题）→ 身份卡（图标 + 品牌 + 版本）→
 *   数据概览卡（数据集数 / 结构版本 / 缓存项数与目录）→
 *   功能行组（数据说明 / 数据更新 / 清理缓存 / 关于）→ CC-BY 署名页脚。
 *
 * 为什么不铺星空背景：这一页以阅读为主，小字压在星点上会糊；
 * 全站只保留「今日」一处星空，视觉上才分得清轻重。
 *
 * 数据来源（硬性义务）：发射与航天员数据来自 The Space Devs（LL2），
 * 卫星编目来自 Jonathan McDowell 的 GCAT（CC-BY，必须署名），图像来自 NASA。
 * 页脚小字与「数据结构说明」弹窗是这条义务的落点，**不要删**。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions, DataSet, CacheStats } from '../data/Repository';
import { fileStore } from '../data/FileStore';
import { FILES, DATA_VERSION } from '../constants/Dataset';
import { formatGeneratedAt } from '../utils/Format';

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
const DIVIDER_COLOR: string = '#1E2637';

/** 页面左右内边距 */
const PAGE_PAD: number = 16;

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
class MineRow {
  icon: string = '';
  title: string = '';
  key: string = '';

  constructor(icon: string, title: string, key: string) {
    this.icon = icon;
    this.title = title;
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

  /** 四个功能行。key 是给 onRow 用的稳定标识，不参与渲染 */
  private rows: MineRow[] = [
    new MineRow('📖', '数据结构说明', 'data'),
    new MineRow('🔄', '数据更新', 'refresh'),
    new MineRow('🧹', '清理缓存', 'clear'),
    new MineRow('ℹ️', '关于', 'about')
  ];

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.refreshCacheInfo();
    this.loadLastSync(false);
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
      return 'v' + APP_VERSION + ' · 许可与数据来源';
    }
    return 'The Space Devs · NASA · GCAT';
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

  private doVacuum(): void {
    const freed: number = repo.vacuum(0);
    this.refreshCacheInfo();
    hilog.info(DOMAIN, TAG, '清理缓存释放 %{public}d 字节', freed);
    AlertDialog.show({
      title: '清理完成',
      message: freed > 0 ? '已释放 ' + formatBytes(freed) + '。' :
        '没有可清理的缓存，当前数据都在使用中。',
      autoCancel: true,
      confirm: {
        value: '好',
        action: () => {
        }
      }
    });
  }

  // ============ UI ============

  /** 页头：19vp Bold 白 + 11vp 灰，与 TodayView / LaunchView 同档 */
  @Builder
  pageHeader() {
    Column() {
      Text('我的')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(0.5)

      Text('数据来源、缓存与版本')
        .fontSize(11)
        .fontColor('#6B7891')
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 12, bottom: 12 })
  }

  /** 身份卡：图标 + 品牌 + 版本号 */
  @Builder
  heroCard() {
    Row() {
      // 资源已存在（resources/base/media/app_icon.png），可以直接引用
      Image($r('app.media.app_icon'))
        .width(56)
        .height(56)
        .borderRadius(14)
        .objectFit(ImageFit.Contain)
        .backgroundColor('#1B2434')

      Column() {
        // 品牌字标：Space 白 + Launch 青。两个 Text 紧挨着，中间不能留空格，
        // 否则会露出一道缝（小程序侧同样踩过）
        Row() {
          Text('Space')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Text('Launch')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(ACCENT)
        }

        Text('航天发射跟踪')
          .fontSize(12)
          .fontColor(TEXT_SECONDARY)
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      Text('v' + APP_VERSION)
        .fontSize(11)
        .fontColor(TEXT_TERTIARY)
        .margin({ left: 8 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(16)
    .borderRadius(16)
    .backgroundColor(CARD_BG)
    .margin({ bottom: 12 })
  }

  /** 概览卡的一格数值。index 为字面量，动态值在内部现算（同 subOf 的理由） */
  @Builder
  statCell(index: number) {
    Column() {
      Text(index === 0 ? String(FILES.size) :
        (index === 1 ? 'v' + String(DATA_VERSION) : String(this.cachedCount) + ' 项'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')

      Text(index === 0 ? '数据集' : (index === 1 ? '结构版本' : '本地缓存'))
        .fontSize(10)
        .fontColor(TEXT_TERTIARY)
        .margin({ top: 3 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  statDivider() {
    Divider()
      .vertical(true)
      .height(24)
      .strokeWidth(1)
      .color(DIVIDER_COLOR)
  }

  /** 数据概览卡：数据集总数 / 结构版本 / 本地缓存 / 缓存目录 */
  @Builder
  overviewCard() {
    Column() {
      Row() {
        Text('数据概览')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(TEXT_SECONDARY)
          .layoutWeight(1)

        Text('结构版本变化时会自动重建缓存目录')
          .fontSize(10)
          .fontColor(TEXT_TERTIARY)
      }
      .width('100%')

      Row() {
        // FILES.size 是数据层真实条目数（27），不写死数字
        this.statCell(0)
        this.statDivider()
        this.statCell(1)
        this.statDivider()
        this.statCell(2)
      }
      .width('100%')
      .margin({ top: 14 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .strokeWidth(1)
        .color(DIVIDER_COLOR)
        .margin({ top: 14, bottom: 10 })

      Text('缓存目录')
        .fontSize(10)
        .fontColor(TEXT_TERTIARY)

      // 真实路径（<filesDir>/dataCache/v{DATA_VERSION}/）。
      // 用户排查「缓存写在哪」就靠这一行，不给模糊说法
      Text(this.cacheDir.length > 0 ? this.cacheDir : '尚未初始化（首次取数后生成）')
        .fontSize(10)
        .fontColor(TEXT_SECONDARY)
        .lineHeight(15)
        .margin({ top: 3 })
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text('占用 ' + formatBytes(this.cacheBytes) + ' · 存放于应用私有目录，卸载即清除')
        .fontSize(10)
        .fontColor(TEXT_TERTIARY)
        .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .borderRadius(16)
    .backgroundColor(CARD_BG)
    .margin({ bottom: 12 })
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

        if (this.subOf(this.rows[index].key).length > 0) {
          Text(this.subOf(this.rows[index].key))
            .fontSize(10)
            .fontColor(TEXT_TERTIARY)
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
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
    .borderRadius(16)
    .backgroundColor(CARD_BG)
    .margin({ bottom: 16 })
  }

  /** CC-BY 署名页脚 —— 项目硬性义务，任何重构都不要删这几行 */
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
    .padding({ left: 8, right: 8, top: 4 })
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          this.pageHeader()
          this.heroCard()
          this.overviewCard()
          this.actionCard()
          this.creditFooter()
        }
        .width('100%')
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
