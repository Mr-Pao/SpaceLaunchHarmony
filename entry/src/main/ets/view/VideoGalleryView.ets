/**
 * view/VideoGalleryView.ets —— 「视频库」页
 *
 * 对应小程序 pages/video-gallery/video-gallery.vue（442 行）。鸿蒙侧只做两件事：
 * 把 videos.json 展平成视频行、点卡片把链接复制走。**不做内联播放**——
 * 工程里没有内置浏览器，open-url 要 Want 跳转，不在本期范围（小程序那边能直接
 * 播是因为有 uni 的 video 组件；鸿蒙要复刻得先接 Web 容器，属于另一个任务）。
 *
 * 三个设计决定，先写清楚为什么：
 *   ① **全量放普通成员、只把切片放进 @State**。线上 341 条，一次性塞 @State 会让
 *      每个 VideoRow 都过一遍状态代理，首屏就要多花几十毫秒，而屏幕上只有 20 条。
 *      所以 allRows 是普通成员，shown 才是 @State 切片。
 *   ② **首屏 20 条、触底再 20 条**。341 条 × 一张 480px 封面同时发请求，ArkUI 的
 *      Image 缓存扛不住，会明显掉帧甚至内存告警。分页是最省事的削峰。
 *   ③ **三态分开，catch 里绝不置 loaded**。EventsView 那边踩过：网络失败时若
 *      loaded=true，页面就永远停在「还没有视频」，用户只能杀进程重进。
 *
 * 数据字段用 net（发射时刻）显示时间，不是 at（抓取时刻）—— 详见 model/Video.ets。
 */

import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { repo } from '../data/Repository';
import { Nav } from '../routes/Nav';
import { formatLaunchTime } from '../utils/Format';
import { VideoRow, VideosPayload, flattenVideos, vdDuration, vdKindLabel } from '../model/Video';

const DOMAIN: number = 0x0000;
const TAG: string = 'VideoGallery';

/**
 * 首屏条数与每次触底追加条数。
 * 20 是「一屏多一点」：够撑满首屏又不至于让 Image 一次性排 20 张以上。
 * 放模块级常量而不是 struct 的 static —— struct 里写 static 在部分 SDK 版本上不支持。
 */
const VD_PAGE: number = 20;

/** 筛选分段文案，顺序即 filterIdx：0 全部 / 1 官方 / 2 其他 */
const VD_TABS: string[] = ['全部', '官方', '其他'];

@Component
export struct VideoGalleryView {
  /**
   * 可选：指定先定位到某条视频（按 url 匹配）。
   * 由路由参数带进来，可为空 —— 空串时就是普通的视频库列表。
   */
  @Prop @Watch('onUrlChange') initialUrl: string = '';

  /** 当前筛选切片。只有它进状态，全量在下面 allRows */
  @State shown: VideoRow[] = [];
  /** 全量行（普通成员，故意不加装饰器：341 条不值得被代理） */
  private allRows: VideoRow[] = [];
  /** 全量条数，页头「共 N 条」用；单独记一份省得模板里反复取 length */
  @State allCount: number = 0;
  /** 当前筛选下的总条数：也是单独存，模板里若调 filteredRows() 会每次 build 都新建数组 */
  @State matchCount: number = 0;
  /** 是否已经拿到过一次数据（成功才算，失败不置） */
  @State loaded: boolean = false;
  /** 首次加载失败且一条都没有 —— 只有这种情况才显示失败页 */
  @State failed: boolean = false;
  /** 0 全部 / 1 官方 / 2 其他 */
  @State filterIdx: number = 0;
  /** 被 initialUrl 指定的那条，加个强调色边框方便一眼找到 */
  @State highlightKey: string = '';

  /** 待定位的 url：路由可能先于数据到达，先存下来等数据齐了再消费 */
  private pendingUrl: string = '';
  /** 定位滚动的延迟定时器，必须在 aboutToDisappear 清掉 */
  private scrollTimer: number = -1;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pendingUrl = this.initialUrl !== undefined && this.initialUrl !== null ? this.initialUrl.trim() : '';
    this.loadData();
  }

  aboutToDisappear(): void {
    // 列表页没有轮询定时器，唯一的定时器是定位滚动，漏清会在页面销毁后碰已回收的 Scroller
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
      this.scrollTimer = -1;
    }
  }

  /**
   * 拉数据。顺序是「先吃缓存、再吃网络」：
   *   peek 只查内存与文件、零网络，命中就立刻上屏，用户看不到白屏；
   *   load 随后静默刷新（SOFT_TTL 6 小时，超了才会真的发请求）。
   *
   * 注意 catch 里**只置 failed**，绝不置 loaded —— 见文件头第 ③ 点。
   */
  private loadData(): void {
    this.failed = false;

    const cached: VideosPayload | null = repo.peek<VideosPayload>('videos');
    if (cached !== null && cached !== undefined) {
      this.applyPayload(cached);
      this.loaded = true;
    }

    repo.load<VideosPayload>('videos').then((payload: VideosPayload) => {
      this.applyPayload(payload);
      this.loaded = true;
      this.failed = false;
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '加载 videos 失败: %{public}s', e.message);
      // 有旧数据就继续显示旧数据，没有才让用户看到失败页
      this.failed = this.allRows.length === 0;
    });
  }

  /** 载荷 → 全量行 → 重置切片。缓存与网络两条路径共用，避免逻辑分叉 */
  private applyPayload(payload: VideosPayload): void {
    this.allRows = flattenVideos(payload, 0);
    this.allCount = this.allRows.length;
    this.resetSlice();
    this.consumePending();
  }

  /** 按当前筛选取全量（不切片），分页与计数都基于它 */
  private filteredRows(): VideoRow[] {
    if (this.filterIdx === 1) {
      return this.allRows.filter((r: VideoRow): boolean => r.official);
    }
    if (this.filterIdx === 2) {
      return this.allRows.filter((r: VideoRow): boolean => !r.official);
    }
    return this.allRows;
  }

  /** 换筛选或换数据时回到第一屏 */
  private resetSlice(): void {
    const all: VideoRow[] = this.filteredRows();
    this.matchCount = all.length;
    this.shown = all.slice(0, VD_PAGE);
  }

  /** 切换筛选：切片重置 + 回顶部（否则会停在上一屏的位置，看起来像没刷新） */
  private setFilter(idx: number): void {
    if (this.filterIdx === idx) {
      return;
    }
    this.filterIdx = idx;
    this.resetSlice();
    if (this.shown.length > 0) {
      this.scroller.scrollEdge(Edge.Top);
    }
  }

  /** 触底追加一页。已经到底就什么都别做，避免每帧重算 */
  private loadMore(): void {
    if (this.shown.length >= this.matchCount) {
      return;
    }
    this.shown = this.filteredRows().slice(0, this.shown.length + VD_PAGE);
  }

  /**
   * @Watch 回调：路由指定了某条视频。
   * 回调**不再加装饰器**（Countdown 那边踩过：@Watch 只能装饰属性）。
   */
  onUrlChange(): void {
    const url: string = this.initialUrl !== undefined && this.initialUrl !== null
      ? this.initialUrl.trim()
      : '';
    if (url.length === 0) {
      return;
    }
    this.pendingUrl = url;
    this.highlightKey = url;
    this.consumePending();
  }

  /**
   * 消费 pendingUrl：把目标行拉进当前切片并滚过去。
   * 目标不在库里（数据还没抓到这条）就静默放弃 —— 不能为了一个链接把整页搞成空白。
   */
  private consumePending(): void {
    const url: string = this.pendingUrl;
    if (url.length === 0 || this.allRows.length === 0) {
      return;
    }
    this.pendingUrl = '';
    this.highlightKey = url;

    // 官方筛选下未必包含目标，统一回「全部」，保证指定链接一定能被看到
    if (this.filterIdx !== 0) {
      this.filterIdx = 0;
    }
    const all: VideoRow[] = this.filteredRows();
    let idx: number = -1;
    for (let i = 0; i < all.length; i++) {
      if (all[i].vidKey === url) {
        idx = i;
        break;
      }
    }
    if (idx < 0) {
      this.resetSlice();
      hilog.info(DOMAIN, TAG, '指定视频不在库中，忽略定位');
      return;
    }

    const need: number = idx + 1 > VD_PAGE ? idx + 1 : VD_PAGE;
    this.matchCount = all.length;
    this.shown = all.slice(0, need);
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
    }
    // 等一帧：刚赋值的 List 还没布局，立刻 scrollToIndex 会滚到一个不存在的下标
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      this.scroller.scrollToIndex(idx, true);
    }, 60);
  }

  /** 统一 toast 出口，方便将来换文案 */
  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  /**
   * 复制视频链接。
   * 鸿蒙没有内置浏览器，open-url 要走 Want 跳转（还得对方应用在目标里），
   * 所以和小程序非可播路径一样：复制 + 提示用户自己去浏览器打开。
   */
  private copyLink(url: string): void {
    if (url.length === 0) {
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.toast('链接已复制');
    }).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG, '复制链接失败 code=%{public}d', e.code);
      this.toast('复制失败，请稍后重试');
    });
  }

  // ─────────────────────────── 视图 ───────────────────────────

  @Builder
  headerBar() {
    Row() {
      Row() {
        Text('‹').fontSize(20).fontColor('#A7B4C7')
        Text('返回').fontSize(13).fontColor('#A7B4C7').margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Center)
      .padding({ right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        Nav.pop();
      })

      Text('视频库')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .letterSpacing(1)

      Blank()

      Text('共 ' + String(this.allCount) + ' 条')
        .fontSize(11)
        .fontColor('#6B7891')
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  segmentBar() {
    Row() {
      ForEach(VD_TABS, (label: string, idx: number) => {
        Text(label)
          .fontSize(12.5)
          .fontWeight(this.filterIdx === idx ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.filterIdx === idx ? '#38BDF8' : '#6B7891')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 7, bottom: 7 })
          .borderRadius(13)
          .backgroundColor(this.filterIdx === idx ? '#2938BDF8' : '#00000000')
          .onClick(() => {
            this.setFilter(idx);
          })
      }, (label: string) => label)
    }
    .width('100%')
    .padding(3)
    .backgroundColor('#141A26')
    .borderRadius(16)
    .border({ width: 1, color: '#0DFFFFFF' })
    .margin({ top: 4, bottom: 10 })
  }

  /** 一张视频卡：16:9 封面 + 播放三角 + 时长胶囊 + 标题两行 + 发布者·类型 */
  @Builder
  videoCard(row: VideoRow) {
    Column() {
      // ── 封面区 ──
      // 用 aspectRatio 而不是固定高度：屏宽一变卡片高度跟着走，不会拉伸封面
      Stack({ alignContent: Alignment.Center }) {
        if (row.cover.length > 0) {
          Image(row.cover)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .alt($r('app.media.app_icon'))
            .draggable(false)
        } else {
          // 没有封面（镜像失败会保留空）就给一块纯色，别让卡片塌成一条线
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#1B2330')
        }

        // 播放三角：Row 包 Text 才能稳定垂直居中（Text 自身只保证水平居中）
        Row() {
          Text('▶').fontSize(20).fontColor('#FFFFFF')
        }
        .width(54)
        .height(54)
        .borderRadius(27)
        .backgroundColor('#66000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .border({ width: 1, color: '#33FFFFFF' })

        // 时长胶囊贴右下角
        if (vdDuration(row.mins).length > 0) {
          Row() {
            Text(vdDuration(row.mins))
              .fontSize(10.5)
              .fontColor('#FFFFFF')
              .backgroundColor('#B3000000')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(3)
          }
          .width('100%')
          .height('100%')
          .padding({ right: 8, bottom: 8 })
          .justifyContent(FlexAlign.End)
          .alignItems(VerticalAlign.Bottom)
        }

        // 左上角：官方标 / 直播中
        Row() {
          if (row.official) {
            Text('官方')
              .fontSize(10)
              .fontColor('#38BDF8')
              .backgroundColor('#2938BDF8')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(3)
          }
          if (row.live) {
            Text('直播中')
              .fontSize(10)
              .fontColor('#FFFFFF')
              .backgroundColor('#99EF4444')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(3)
              .margin({ left: 6 })
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 8, top: 8 })
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .aspectRatio(16 / 9)
      .backgroundColor('#1B2330')
      .borderRadius({ topLeft: 12, topRight: 12 })
      .clip(true)

      // ── 文字区 ──
      Column() {
        Text(row.title)
          .fontSize(13.5)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
          .lineHeight(19)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        Row() {
          Text(row.publisher.length > 0 ? row.publisher : '来源未知')
            .fontSize(11)
            .fontColor('#A7B4C7')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          Text(vdKindLabel(row.tid, row.kind))
            .fontSize(10)
            .fontColor(row.official ? '#38BDF8' : '#8A97AB')
            .backgroundColor(row.official ? '#2938BDF8' : '#1B2330')
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(4)
            .margin({ left: 8 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 6 })

        // 发射时间用 net（不是 at），formatLaunchTime 负责东八区与「时间待定」兜底
        if (row.net.length > 0) {
          Text('发射 ' + formatLaunchTime(row.net))
            .fontSize(10.5)
            .fontColor('#55617A')
            .margin({ top: 4 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 12 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundColor('#141A26')
    .borderRadius(12)
    .border({
      width: 1,
      color: this.highlightKey === row.vidKey ? '#38BDF8' : '#12FFFFFF'
    })
    .onClick(() => {
      this.copyLink(row.url);
    })
  }

  @Builder
  listArea() {
    List({ space: 10, scroller: this.scroller }) {
      ForEach(this.shown, (row: VideoRow) => {
        ListItem() {
          this.videoCard(row)
        }
      }, (row: VideoRow) => row.vidKey)

      ListItem() {
        Row() {
          Text(this.shown.length < this.matchCount ? '下滑加载更多' : '已经到底了')
            .fontSize(11)
            .fontColor('#55617A')
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 14, bottom: 20 })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(3)
    .onReachEnd(() => {
      this.loadMore();
    })
  }

  @Builder
  loadingArea() {
    Column() {
      LoadingProgress().width(36).height(36).color('#38BDF8')
      Text('正在加载视频库…').fontSize(12).fontColor('#6B7891').margin({ top: 10 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  failedArea() {
    Column() {
      Text('⚠️').fontSize(30)
      Text('加载失败').fontSize(14).fontColor('#A7B4C7').margin({ top: 10 })
      Text('网络或数据异常，请稍后重试').fontSize(11).fontColor('#55617A').margin({ top: 6 })
      Text('重新加载')
        .fontSize(12)
        .fontColor('#38BDF8')
        .padding({ left: 18, right: 18, top: 8, bottom: 8 })
        .backgroundColor('#16222F')
        .borderRadius(15)
        .margin({ top: 16 })
        .onClick(() => {
          this.loadData();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyArea() {
    Column() {
      Text('🎬').fontSize(30)
      Text(this.allCount > 0 ? '当前筛选没有视频' : '还没有视频')
        .fontSize(13)
        .fontColor('#A7B4C7')
        .margin({ top: 10 })
      Text(this.allCount > 0 ? '试试切回「全部」' : '视频数据还在准备中')
        .fontSize(11)
        .fontColor('#55617A')
        .margin({ top: 6 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Column() {
      this.headerBar()
      this.segmentBar()

      // 有内容优先显示内容：有缓存时即使网络还在跑，也应该先让用户看到列表
      if (this.shown.length > 0) {
        this.listArea()
      } else if (this.failed) {
        this.failedArea()
      } else if (!this.loaded) {
        this.loadingArea()
      } else {
        this.emptyArea()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0A0E17')
    .alignItems(HorizontalAlign.Start)
    // bottom 120 是给悬浮 tabBar 让位，与其它二级页保持一致
    .padding({ left: 12, right: 12, bottom: 120 })
  }
}
