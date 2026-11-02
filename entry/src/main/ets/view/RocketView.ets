/**
 * view/RocketView.ets —— 「火箭」tab
 *
 * 对位小程序：pages/rockets/rockets.vue（1277 行，分组 + 筛选 + 实例非响应式全量池）
 *
 * 结构（自上而下）：
 *   页头「火箭」+ 副标题 → 搜索框 → List（RocketCard × N）→ 底部状态行
 *
 * ── 为什么全量不放进 @State ──
 *   532 条 launchers，每条视图模型带 8 个字符串字段。塞进 @State 意味着：
 *   ① 代理对象包一层（内存翻倍）；② 任何一次过滤都会把整个数组过一遍脏检查。
 *   小程序为同一问题在 rockets.vue:563-619 里把全量挂 `this._all`（非响应式）、
 *   只留渲染池 —— 这里的做法等价：全量在私有成员 `all`，@State 只放**当前要画的那一段**。
 *
 * ── 为什么只画前 100 条 ──
 *   ForEach 不是懒加载（不像 LazyForEach），532 张卡片会一次性建好所有节点。
 *   首屏只放 100 条、触底再放 100 条，是「用滑动换建树时间」的折中：
 *   100 条 × 约 6 个节点 ≈ 600 个组件，一个 List 视口本来也就能装 8 条左右。
 *   搜索过滤后同样先截 100 条 —— 输入 'f' 命中 80 条时没必要一次建 80 个。
 *
 * ── 搜索为什么在本地做 ──
 *   launchers 是全量 532 条的静态文件（软 TTL 12 小时），一次 load 就在内存里。
 *   每次打字都发请求既没必要也会闪。视图模型里预拼了 `hay`（name/full_name/
 *   manufacturer/variant/families 的小写串），过滤只做一次 indexOf。
 *
 * ── 有意差异（相对小程序 rockets.vue）──
 *   1. 不做「国家/地区」分组。LL2 没有国别字段，小程序只能靠 manufacturer 关键词
 *      白名单猜（rockets.vue:246-252），漏了就落 other —— 猜错的代价比不分组大，
 *      所以这里改成单列表 + 搜索，不做假的地区归类。
 *   2. 不做「只看在役」筛选条。在役标记压成缩略图角标（RocketCard 里画），
 *      信息不丢，少一层交互。
 *   3. 不合并同 name 的不同构型。小程序 pool() 按 name 去重（rockets.vue:302-331）
 *      是为了竖排分组好看；单列表直接按原顺序铺开，同名构型各自可点开，
 *      反而不会漏掉某个 variant。
 *
 * ⚠ 日志一律 hilog，不用 console。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { strOf } from '../utils/Format';
import { RocketCard, RkRocket, RkLauncherRaw, RkLauncherList, rkFromRaw } from '../components/RocketCard';
import { Nav } from '../routes/Nav';
import { RocketNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'RocketView';

const BG_PRIMARY: string = '#0A0E17';
const TXT_MAIN: string = '#FFFFFF';
const TXT_SUB: string = '#A7B4C7';
const TXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
const PAGE_PAD: number = 12;
const BOTTOM_PAD: number = 92;

/** 一次渲染多少条（触底再放一批） */
const PAGE_SIZE: number = 100;
/** 卡片间距 */
const CARD_GAP: number = 8;

@Component
export struct RocketView {
  // ============ 渲染状态 ============

  /** 当前搜索词（受控 TextInput 需要回填，故进 @State） */
  @State keyword: string = '';
  /** 当前要画的这一段（最多 PAGE_SIZE 的整数倍） */
  @State shown: RkRocket[] = [];
  /** 命中总条数（可能远大于 shown.length） */
  @State hitTotal: number = 0;
  /** 全量型号数，副标题用 */
  @State total: number = 0;
  @State loading: boolean = true;
  @State failed: boolean = false;

  // ============ 全量池（普通成员，不进 @State） ============

  /** 532 条视图模型。改它不会触发重绘，改完必须显式 reapply() */
  private all: RkRocket[] = [];
  /** 过滤后的完整结果（只用于算 shown 的下一批，同样不进 @State） */
  private filtered: RkRocket[] = [];

  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.load();
  }

  // ============ 加载 ============

  private load(): void {
    this.loading = true;
    this.failed = false;

    const opts: LoadOptions<RkLauncherList> = {
      // 有缓存先渲染再静默刷新：launchers 是 532 条静态数据，不该每次进页转圈。
      // 刷新走 keepScroll=true —— 用户可能已经滚到第 300 条在看，后台回填后
      // 把他弹回顶部比不刷新更糟；关键词也保留，不能被一次刷新清掉。
      onUpdate: (data: RkLauncherList) => {
        this.applyPayload(data, true);
      }
    };

    repo.load<RkLauncherList>('launchers', opts)
      .then((data: RkLauncherList) => {
        // 首屏/首次成功：从顶部开始看，重算后回顶
        this.applyPayload(data, false);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'launchers 加载失败: %{public}s', e.message);
        if (this.all.length === 0) {
          this.failed = true;
        }
      })
      .then(() => {
        this.loading = false;
      });
  }

  /** 原始载荷 → 全量池。只在首屏/刷新时跑一次，不在滚动路径上 */
  private applyPayload(data: RkLauncherList, keepScroll: boolean): void {
    const raw: RkLauncherRaw[] = data.list !== undefined && data.list !== null ? data.list : [];
    const built: RkRocket[] = [];
    for (let i = 0; i < raw.length; i++) {
      const r: RkRocket = rkFromRaw(raw[i]);
      // 名字是唯一的展示锚点，没有名字的条目（极少）没法点，直接跳过
      if (r.name.length === 0) {
        continue;
      }
      built.push(r);
    }
    if (built.length === 0) {
      return;
    }
    this.all = built;
    this.total = built.length;
    this.failed = false;
    this.reapply(keepScroll);
  }

  // ============ 过滤 ============

  /**
   * 重算 filtered + shown。
   * keepScroll=false 时滚回顶部 —— 换搜索词后停在原来位置会让人以为没响应。
   */
  private reapply(keepScroll: boolean): void {
    const kw: string = this.keyword.trim().toLowerCase();
    const out: RkRocket[] = [];

    if (kw.length === 0) {
      for (let i = 0; i < this.all.length; i++) {
        out.push(this.all[i]);
      }
    } else {
      for (let i = 0; i < this.all.length; i++) {
        // hay 已是小写拼接串，一次 indexOf 覆盖型号名/全名/厂商/构型/家族
        if (this.all[i].hay.indexOf(kw) >= 0) {
          out.push(this.all[i]);
        }
      }
    }

    this.filtered = out;
    this.hitTotal = out.length;
    this.shown = this.slice(out, 0, PAGE_SIZE);

    if (!keepScroll && this.shown.length > 0) {
      // 只有 shown 非空时 List 才存在；空态下 Scroller 还没绑定节点，scrollEdge 拿不到目标
      this.scroller.scrollEdge(Edge.Top);
    }
  }

  /** 取 [from, from+count) 区间。手写循环而不是 slice()：slice 会额外复制一层对象数组 */
  private slice(src: RkRocket[], from: number, count: number): RkRocket[] {
    const out: RkRocket[] = [];
    const end: number = Math.min(from + count, src.length);
    for (let i = from; i < end; i++) {
      out.push(src[i]);
    }
    return out;
  }

  /**
   * 触底放下一批。
   * 用 concat 语义（重建数组）而不是 push：@State 的数组要整体替换才能保证重绘，
   * 就地 push 在某些 ArkUI 版本上只刷新长度不刷新子节点。
   */
  private loadMore(): void {
    if (this.shown.length >= this.filtered.length) {
      return;
    }
    const more: RkRocket[] = this.slice(this.filtered, this.shown.length, PAGE_SIZE);
    const next: RkRocket[] = [];
    for (let i = 0; i < this.shown.length; i++) {
      next.push(this.shown[i]);
    }
    for (let i = 0; i < more.length; i++) {
      next.push(more[i]);
    }
    this.shown = next;
  }

  private onSearch(text: string): void {
    const v: string = strOf(text);
    if (v === this.keyword) {
      return;
    }
    this.keyword = v;
    this.reapply(false);
  }

  private openRocket(item: RkRocket): void {
    if (item.name.length === 0) {
      return;
    }
    Nav.pushRocket(new RocketNavParam(item.name));
  }

  private subtitle(): string {
    if (this.total > 0) {
      return `运载火箭谱系 · 共 ${this.total} 型`;
    }
    return this.loading ? '正在加载型号库…' : '运载火箭谱系';
  }

  // ============ UI ============

  build() {
    Column() {
      this.header()
      this.searchBar()

      if (this.shown.length === 0) {
        this.emptyState()
      } else {
        this.list()
        this.statusRow()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
    // ★ 92vp：避开底部悬浮胶囊（胶囊是浮层，内容会铺到屏幕底）
    .padding({ bottom: BOTTOM_PAD })
  }

  @Builder
  header() {
    Column() {
      Text('火箭')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TXT_MAIN)
        .letterSpacing(0.5)
      Text(this.subtitle())
        .fontSize(11)
        .fontColor('#6B7891')
        .margin({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 12, bottom: 10 })
  }

  /**
   * 搜索框。
   * 用 TextInput + 自绘左侧图标而不是 Search 组件：Search 的自带样式（灰底、
   * 取消按钮）与暗色主题冲突，覆盖成本比自绘高。
   */
  @Builder
  searchBar() {
    // 外层 Column 专门吃左右边距：Row 上同时写 width('100%') 和左右 margin
    // 在 ArkUI 里会先按 100% 量宽再扣 margin，右侧会被挤出容器
    Column() {
      this.searchField()
    }
    .width('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: 10 })
  }

  @Builder
  searchField() {
    Row() {
      Text('🔍')
        .fontSize(12)
        .opacity(0.5)
        .margin({ right: 6 })

      TextInput({ text: this.keyword, placeholder: '搜索型号 / 厂商' })
        .layoutWeight(1)
        .type(InputType.Normal)
        .enterKeyType(EnterKeyType.Search)
        .placeholderColor(TXT_DIM)
        .placeholderFont({ size: 12 })
        .fontSize(12)
        .fontColor('#E8EEF8')
        .caretColor(ACCENT)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .height(34)
        .onChange((value: string) => {
          this.onSearch(value);
        })

      if (this.keyword.length > 0) {
        Text('✕')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .padding({ left: 8, right: 2, top: 4, bottom: 4 })
          .onClick(() => {
            this.onSearch('');
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 10 })
    .height(36)
    .backgroundColor('#141A26')
    .borderRadius(10)
    .border({ width: 1, color: '#0DFFFFFF' })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 列表。
   * 用 List 而不是 Scroll+Column：List 自带节点回收与滚动惯性，
   * 532 条（哪怕只画 100 条）在 Column 里都会全量建树。
   */
  @Builder
  list() {
    List({ space: CARD_GAP, scroller: this.scroller }) {
      ForEach(this.shown, (item: RkRocket) => {
        ListItem() {
          RocketCard({
            item: item,
            onOpen: (r: RkRocket) => {
              this.openRocket(r);
            }
          })
        }
      }, (item: RkRocket, index: number) => item.key + '#' + index)
    }
    .layoutWeight(1)
    .width('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(6)
    .onReachEnd(() => {
      this.loadMore();
    })
  }

  /**
   * 底部状态行。
   * 「已显示 N/M」是必要的：不写清总数，用户会以为库只有这么点型号。
   */
  @Builder
  statusRow() {
    Text(this.shown.length < this.hitTotal
      ? `已显示 ${this.shown.length}/${this.hitTotal} · 继续下滑`
      : (this.keyword.length > 0 ? `匹配 ${this.hitTotal} 型` : `共 ${this.hitTotal} 型`))
      .fontSize(10)
      .fontColor(TXT_DIM)
      .width('100%')
      .textAlign(TextAlign.Center)
      .padding({ top: 8, bottom: 4 })
  }

  /** 空态：加载中 / 加载失败 / 搜不到，三种文案不能混（混了用户不知道该干嘛） */
  @Builder
  emptyState() {
    Column() {
      if (this.loading) {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(ACCENT)
        Text('正在加载型号库…')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .margin({ top: 10 })
      } else if (this.failed) {
        Text('🚀')
          .fontSize(30)
          .opacity(0.3)
        Text('型号库加载失败')
          .fontSize(13)
          .fontColor(TXT_SUB)
          .margin({ top: 10 })
        Text('检查网络后重试')
          .fontSize(11)
          .fontColor(TXT_DIM)
          .margin({ top: 6 })
        Text('重新加载')
          .fontSize(12)
          .fontColor(ACCENT)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .borderRadius(14)
          .backgroundColor('#1B2A3C')
          .margin({ top: 14 })
          .onClick(() => {
            this.load();
          })
      } else {
        Text('🔍')
          .fontSize(30)
          .opacity(0.3)
        Text('没有匹配的型号')
          .fontSize(13)
          .fontColor(TXT_SUB)
          .margin({ top: 10 })
        Text(`换个关键词试试，比如「Falcon」`)
          .fontSize(11)
          .fontColor(TXT_DIM)
          .margin({ top: 6 })
      }
    }
    .layoutWeight(1)
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
  }
}
