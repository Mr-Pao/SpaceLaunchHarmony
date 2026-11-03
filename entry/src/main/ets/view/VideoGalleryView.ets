/**
 * view/VideoGalleryView.ets —— 「视频库」（发射视频）页
 *
 * 对位小程序 pages/video-gallery/video-gallery.vue。2026-11-03 按审计表 15 条差异
 * 逐条对齐，取舍写在下面：
 *
 *   · 标题改「发射视频」并复刻 nav-bar(solid)：44vp 实色条 + 0.5vp 分隔线，
 *     标题 23vp / w600 / 居中 —— 原实现是左对齐 19vp Bold 的「视频库」。
 *   · 新增统计行「共 N 段视频 · 其中 M 段可直接播放」（11vp #8B95A8）。
 *     小程序原文是「可小程序内播放」，鸿蒙侧没有「小程序」这个概念，
 *     改成「可直接播放」，字段口径不变（仍有可播/不可播两段）。
 *   · 删掉「全部/官方/其他」三段筛选：小程序没有筛选，保留筛选会让首屏
 *     默认少一半内容。
 *   · 改两列瀑布流：两个 Column 分别装偶数/奇数下标（卡片高度固定，不需要
 *     WaterFlow 的流式能力）。容器底改用 Scroll，才能整页两列一起滚。
 *   · 卡片视觉按 wxss 逐个换算：封面固定 110vp、卡片圆角 5vp、无边框、
 *     底色 #131A26、标题 11.5vp 单行、meta 10vp。
 *   · 徽标改成左「官方」+ 右「可播 / 链接」，右上是小程序里最有信息量的一个：
 *     它告诉用户点下去是播还是复制链接。
 *   · 补内联播放器骨架：Video 全屏遮罩（78% 高）+ 底部渐变标题条 + ✕。
 *     线上 videos.json 的 cosUrl 目前命中 0 条，所以实际都走复制链接分支；
 *     播放器留着，等 CI 补上 COS 转存即可生效。
 *   · 日期改 YYYY-MM-DD（小程序 fmtDate），不再用「发射 M月D日 HH:mm」。
 *   · 分页 60（小程序 PAGE=60）。
 *   · 不再按 url 去重、不再按 tid/net/start 排序：小程序就是 JSON 原序。
 *   · 尾行只留「下滑加载更多」，去掉「已经到底了」和整块失败页；
 *     失败时按小程序语义走空态（没有失败态这一说）。
 *   · 空态文案按小程序：🎬 30vp + 「还没有视频」13vp + 一行 11vp 说明。
 *   · 加载态返回纯文字「加载中...」13vp #6B7891，居中 60% 高。
 *
 * ── 保留的鸿蒙增强（报告里会单独说明）──
 *   initialUrl 定位：从发射详情跳进来时把目标行拉进首屏并滚过去，
 *   命中的卡片加 1vp #38BDF8 边框。小程序没有这个，但它在鸿蒙上是
 *   唯一能回答「我刚点的那场发射的视频在哪」的手段，删掉是倒退。
 *
 * ── 不做 ──
 *   分享：鸿蒙要接 Share Kit（Want + 系统分享面板），不在本期范围。
 */

import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { repo } from '../data/Repository';
import { Nav } from '../routes/Nav';
import { VideoRow, VideosPayload, flattenVideos } from '../model/Video';

const DOMAIN: number = 0x0000;
const TAG: string = 'VideoGallery';

/**
 * 每次渲染多少段（小程序 PAGE = 60）。
 * 60 张封面同时进场偏重，但两列卡片只有 110vp 封面，实测比原来 20 条
 * 16:9 卡片的解码压力还低；而且它决定了「滑多久才触发加载」的体感。
 */
const VD_PAGE: number = 60;

/**
 * 卡片高度估算（vp）：封面 110 + 文字区 6/16/2/14/6 + 卡间距 6 = 160。
 * 只用于「定位滚动」把第 i 行换算成像素偏移；文字行数固定（标题单行、
 * 只有 publisher / 日期 两种可选行），误差最多一行，够用。
 */
const VD_CARD_H: number = 160;

// 颜色（video-gallery.vue wxss，rpx ÷ 2）
const BG: string = '#0A0E17';
const CARD_BG: string = '#131A26';
/** nav-bar solid 的 rgba(10,14,23,0.96) */
const TOP_BAR_BG: string = '#F50A0E17';
const DIVIDER: string = '#0DFFFFFF';
/** 统计行 .stat-text */
const TEXT_STAT: string = '#8B95A8';
/** 卡片标题 .vtitle */
const TEXT_TITLE: string = '#E2E8F0';
/** meta .vmeta */
const TEXT_META: string = '#7D8BA0';
/** meta.dim（日期） */
const TEXT_DIM: string = '#4D5A6E';
/** 空态正文 .empty-text */
const TEXT_EMPTY: string = '#8B95A8';
/** 空态说明 .empty-sub */
const TEXT_EMPTY_SUB: string = '#4D5A6E';
/** 加载中 .hint-text */
const TEXT_HINT: string = '#6B7891';
/** 命中定位的卡片边框 */
const HL_COLOR: string = '#38BDF8';

@Component
export struct VideoGalleryView {
  /**
   * 可选：要定位到的目标。路由（routes/DetailPages.ets）传的是发射 UUID，
   * 站内若改成传视频链接也照样能匹配。空串 = 普通视频库列表。
   */
  @Prop @Watch('onUrlChange') initialUrl: string = '';

  /** 当前已渲染的切片。只有它进状态，全量在 allRows */
  @State shown: VideoRow[] = [];
  /** 全量行（普通成员，故意不加装饰器：几百条不值得被状态代理） */
  private allRows: VideoRow[] = [];
  /** 全量条数：统计行与「还有没有更多」都要用，单独存一份省得反复取 length */
  @State allCount: number = 0;
  /** 可内联播放的条数（cosUrl 非空），统计行第二段 */
  @State playableCount: number = 0;
  /** 首屏加载中：只在小程序那套 loading 分支里用，有缓存时不置 true */
  @State loading: boolean = true;
  /** 被 initialUrl 指定的那条，加个强调色边框方便一眼找到 */
  @State highlightKey: string = '';

  /** 正在内联播放的地址，空串 = 没有播放器 */
  @State playingUrl: string = '';
  /** 播放中的标题，只给底部渐变条用 */
  @State playingTitle: string = '';

  /** 待定位的目标：可能是视频链接，也可能是发射 UUID。路由可能先于数据到达，先存着 */
  private pendingKey: string = '';
  /** 定位滚动的延迟定时器，必须在 aboutToDisappear 清掉 */
  private scrollTimer: number = -1;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pendingKey = this.initialUrl !== undefined && this.initialUrl !== null ? this.initialUrl.trim() : '';
    this.loadData();
  }

  aboutToDisappear(): void {
    // 列表页唯一的定时器是定位滚动，漏清会在页面销毁后碰已回收的 Scroller
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
   * 小程序没有失败态：catch 里什么也不做，让空态顶着（文件头已说明）。
   */
  private loadData(): void {
    const cached: VideosPayload | null = repo.peek<VideosPayload>('videos');
    if (cached !== null) {
      this.applyPayload(cached);
      this.loading = false;
    }

    repo.load<VideosPayload>('videos').then((payload: VideosPayload) => {
      this.applyPayload(payload);
      this.loading = false;
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, '加载 videos 失败: %{public}s', e.message);
      // 有旧数据就继续显示旧数据；没有就落到空态（与小程序一致，不给失败页）
      this.loading = false;
    });
  }

  /** 载荷 → 全量行 → 重置切片。缓存与网络两条路径共用，避免逻辑分叉 */
  private applyPayload(payload: VideosPayload): void {
    this.allRows = flattenVideos(payload, 0);
    this.allCount = this.allRows.length;
    let playable: number = 0;
    for (let i = 0; i < this.allRows.length; i++) {
      if (this.allRows[i].playable) {
        playable++;
      }
    }
    this.playableCount = playable;
    this.resetSlice();
    this.consumePending();
  }

  /** 回到第一屏 */
  private resetSlice(): void {
    this.shown = this.allRows.slice(0, VD_PAGE);
  }

  /** 触底追加一页。已经到底就什么都别做，避免每帧重算 */
  private loadMore(): void {
    if (this.shown.length >= this.allCount) {
      return;
    }
    this.shown = this.allRows.slice(0, this.shown.length + VD_PAGE);
  }

  /**
   * 两列的偶数行 / 奇数行。
   * 小程序是 cols 计算属性把 shown 拆两半，这里同构；返回值每次 build 新建数组，
   * 60 条的 filter 开销可以忽略，换来的是不用维护两份切片状态。
   */
  private evenRows(): VideoRow[] {
    return this.shown.filter((row: VideoRow, idx: number): boolean => idx % 2 === 0);
  }

  private oddRows(): VideoRow[] {
    return this.shown.filter((row: VideoRow, idx: number): boolean => idx % 2 === 1);
  }

  /**
   * @Watch 回调：路由指定了要定位的目标。
   * 回调**不再加装饰器**（@Watch 只能装饰属性）。
   *
   * 入参可能是视频链接（站内跳转），也可能是发射 UUID（从发射详情进来）——
   * 两种都支持，匹配时先按 url 精确找，再按 launchId 前缀找。
   */
  onUrlChange(): void {
    const key: string = this.initialUrl !== undefined && this.initialUrl !== null
      ? this.initialUrl.trim()
      : '';
    if (key.length === 0) {
      return;
    }
    this.pendingKey = key;
    this.highlightKey = key;
    this.consumePending();
  }

  /**
   * 消费 pendingKey：把目标行拉进当前切片并滚过去。
   * 目标不在库里（数据还没抓到这条）就静默放弃 —— 不能为了一个链接把整页搞成空白。
   */
  private consumePending(): void {
    const key: string = this.pendingKey;
    if (key.length === 0 || this.allRows.length === 0) {
      return;
    }
    this.pendingKey = '';
    this.highlightKey = key;

    const all: VideoRow[] = this.allRows;
    let idx: number = -1;
    for (let i = 0; i < all.length; i++) {
      // 链接优先：同一场发射往往有好几路直播，给了链接就别按发射挑第一个
      if (all[i].url === key) {
        idx = i;
        break;
      }
    }
    if (idx < 0 && key.length >= 8) {
      // 没匹配到链接就当发射 UUID 处理。UUID 普遍 36 位，取 8 位前缀已经够区分，
      // 又不会被空串或「1」「2」这种短参数误命中。
      for (let i = 0; i < all.length; i++) {
        if (all[i].launchId.length >= 8 && all[i].launchId.startsWith(key)) {
          idx = i;
          break;
        }
      }
    }
    if (idx < 0) {
      this.resetSlice();
      hilog.info(DOMAIN, TAG, '指定目标不在视频库中，忽略定位');
      return;
    }

    const need: number = idx + 1 > VD_PAGE ? idx + 1 : VD_PAGE;
    this.shown = all.slice(0, need);
    if (this.scrollTimer >= 0) {
      clearTimeout(this.scrollTimer);
    }
    // 等一帧：刚赋值的切片还没布局，立刻 scrollTo 会滚到旧的偏移量上。
    // 两列布局下第 idx 行在第 floor(idx/2) 个卡位，用估算高度换算像素。
    const offset: number = Math.floor(idx / 2) * VD_CARD_H;
    this.scrollTimer = setTimeout(() => {
      this.scrollTimer = -1;
      this.scroller.scrollTo({ xOffset: 0, yOffset: offset, animation: true });
    }, 60);
  }

  /**
   * 这一行是不是被路由指定的目标。
   * 入参可能是 url 也可能是发射 UUID，所以两种都要判；highlightKey 为空时恒 false。
   */
  private isHighlighted(row: VideoRow): boolean {
    if (this.highlightKey.length === 0) {
      return false;
    }
    if (this.highlightKey === row.url) {
      return true;
    }
    return row.launchId.length >= 8 && row.launchId.startsWith(this.highlightKey);
  }

  /** 统一 toast 出口，方便将来换文案 */
  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  /**
   * 点卡片：可播就开内联播放器，否则复制链接。
   * 小程序 openVideo 是同一个分支（playable && cosUrl）。
   */
  private openVideo(row: VideoRow): void {
    if (row.playable && row.cosUrl.length > 0) {
      this.playingUrl = row.cosUrl;
      this.playingTitle = row.title;
      return;
    }
    this.copyLink(row.url);
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
      this.toast('链接已复制，可到浏览器打开');
    }).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG, '复制链接失败 code=%{public}d', e.code);
      this.toast('复制失败，请稍后重试');
    });
  }

  /** 关闭播放器：清地址即销毁 Video 节点，播放自然停止 */
  private closePlayer(): void {
    this.playingUrl = '';
    this.playingTitle = '';
  }

  /**
   * ISO → `YYYY-MM-DD`（小程序 fmtDate）。
   * 没有用 utils/Format 的 formatLaunchTime：那个是「M月D日 HH:mm」的口径，
   * 卡片 meta 只要日期，年月日的补零逻辑在这三行里更直观。
   */
  private dateText(iso: string): string {
    if (iso.length === 0) {
      return '';
    }
    const t: number = Date.parse(iso);
    if (Number.isNaN(t)) {
      return '';
    }
    const d: Date = new Date(t);
    const y: number = d.getFullYear();
    const m: number = d.getMonth() + 1;
    const day: number = d.getDate();
    const mm: string = m < 10 ? '0' + String(m) : String(m);
    const dd: string = day < 10 ? '0' + String(day) : String(day);
    return String(y) + '-' + mm + '-' + dd;
  }

  // ─────────────────────────── 视图 ───────────────────────────

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.topBar()

        if (this.loading) {
          this.loadingArea()
        } else {
          this.contentArea()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(BG)
      .alignItems(HorizontalAlign.Start)

      // 播放器遮罩：无条件渲染的兄弟节点会盖住列表，所以只在有地址时挂。
      // Stack 的 alignContent 是 Center，遮罩自己写满 100%×100% 才盖得住整屏。
      if (this.playingUrl.length > 0) {
        this.playerMask()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }

  /** 顶栏：nav-bar(solid) 的鸿蒙实现，标题居中 23vp w600 */
  @Builder
  topBar() {
    Stack({ alignContent: Alignment.Center }) {
      Text('发射视频')
        .fontSize(23)
        // nav-bar 的 .nav-title 是 w600，700 会明显更粗
        .fontWeight(600)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        // 左右各 60：nav-bar 的 .nav-title 是 left/right 120rpx，给返回键让位
        .padding({ left: 60, right: 60 })

      Row() {
        Row() {
          Text('‹').fontSize(23).fontColor('#FFFFFF')
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          Nav.pop();
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ left: 10 })
    }
    .width('100%')
    .height(44)
    .backgroundColor(TOP_BAR_BG)
    .border({ width: { bottom: 0.5 }, color: DIVIDER })
  }

  /** 统计 + 两列瀑布流（或空态） */
  @Builder
  contentArea() {
    Column() {
      // 统计行：小程序 .stat 的 padding 是 20rpx 24rpx 4rpx
      if (this.allCount > 0) {
        Text('共 ' + String(this.allCount) + ' 段视频 · 其中 ' + String(this.playableCount) + ' 段可直接播放')
          .fontSize(11)
          .fontColor(TEXT_STAT)
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ left: 12, right: 12, top: 10, bottom: 2 })
      }

      if (this.shown.length > 0) {
        this.gridArea()
      } else {
        this.emptyArea()
      }
    }
    .width('100%')
    // 底部留 32：本页走 NavDestination 二级页，开了 onShown 隐藏悬浮胶囊
    .layoutWeight(1)
    .padding({ bottom: 32 })
    .alignItems(HorizontalAlign.Start)
  }

  /** 两列瀑布流：偶数下标进左列、奇数下标进右列 */
  @Builder
  gridArea() {
    Scroll(this.scroller) {
      Column() {
        Row() {
          Column() {
            ForEach(this.evenRows(), (row: VideoRow) => {
              this.videoCard(row)
            }, (row: VideoRow) => row.vidKey)
          }
          .layoutWeight(1)
          .padding({ left: 2, right: 2 })
          .alignItems(HorizontalAlign.Start)

          Column() {
            ForEach(this.oddRows(), (row: VideoRow) => {
              this.videoCard(row)
            }, (row: VideoRow) => row.vidKey)
          }
          .layoutWeight(1)
          .padding({ left: 2, right: 2 })
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        // 两列各自长短不一，必须顶端对齐，否则整行会被最高的那列拽下去
        .alignItems(VerticalAlign.Top)

        // 尾行：小程序只在「还没全部露出」时显示，没有「已经到底了」
        if (this.shown.length < this.allCount) {
          Row() {
            Text('下滑加载更多').fontSize(11).fontColor(TEXT_DIM)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 10, bottom: 20 })
        }
      }
      .width('100%')
      // .grid 的 padding: 8rpx 8rpx 0
      .padding({ left: 4, right: 4, top: 4 })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    // Scroll **没有** onReachEnd（那是 List / Grid / WaterFlow 的接口，写上去直接编译报错），
    // 等价物是 onScrollEdge。只认 Bottom：顶部回弹不能触发加载，
    // 否则用户往下拉一下就凭空多一页。
    .onScrollEdge((side: Edge) => {
      if (side === Edge.Bottom) {
        this.loadMore();
      }
    })
  }

  /**
   * 一张视频卡：110vp 固定封面 + 播放三角 + 左上「官方」+ 右上「可播/链接」
   * + 单行标题 + publisher + 日期。
   *
   * 注意 .vcard 在小程序里**没有边框**（只有定位高亮时才补 1vp），
   * 所以这里 border 宽度随 isHighlighted 在 0/1 之间切，不写固定 1vp 半透明边。
   */
  @Builder
  videoCard(row: VideoRow) {
    Column() {
      // ── 封面区：固定 110vp（220rpx），不跟屏宽走 ──
      Stack({ alignContent: Alignment.Center }) {
        if (row.cover.length > 0) {
          Image(row.cover)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          // 封面镜像失败会留空串，给一块纯色别让卡片塌成一条线
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#0D1420')
        }

        // 播放三角：Row 包 Text 才能稳定垂直居中（Text 自身只保证水平居中）
        Row() {
          Text('▶').fontSize(13).fontColor('#F2FFFFFF')
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .backgroundColor('#73000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)

        // 左上角：官方（白字黑底 9vp）
        Row() {
          if (row.official) {
            Text('官方')
              .fontSize(9)
              .fontColor('#FFFFFF')
              .backgroundColor('#8C000000')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(2)
              .lineHeight(13)
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 5, top: 5 })
        .justifyContent(FlexAlign.Start)
        .alignItems(VerticalAlign.Top)

        // 右上角：能直接看标「可播」，只能复制链接标「链接」
        Row() {
          if (row.playable) {
            Text('可播')
              .fontSize(9)
              // .vbadge.ok 是 w600
              .fontWeight(600)
              .fontColor('#04121F')
              .backgroundColor('#EB38BDF8')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(2)
              .lineHeight(13)
          } else {
            Text('链接')
              .fontSize(9)
              .fontColor('#CFE6FF')
              .backgroundColor('#8C000000')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(2)
              .lineHeight(13)
          }
        }
        .width('100%')
        .height('100%')
        .padding({ right: 5, top: 5 })
        .justifyContent(FlexAlign.End)
        .alignItems(VerticalAlign.Top)
      }
      .width('100%')
      .height(110)
      .backgroundColor('#0D1420')

      // ── 文字区 ──
      Text(row.title)
        .fontSize(11.5)
        .fontColor(TEXT_TITLE)
        .lineHeight(16)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
        // .vtitle 的 padding: 12rpx 12rpx 0
        .padding({ left: 6, right: 6, top: 6 })

      if (row.publisher.length > 0) {
        Text('@' + row.publisher)
          .fontSize(10)
          .fontColor(TEXT_META)
          .lineHeight(14)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)
          // .vmeta 的 padding: 4rpx 12rpx 12rpx
          .padding({ left: 6, right: 6, top: 2, bottom: 6 })
      }

      if (this.dateText(row.net).length > 0) {
        Text(this.dateText(row.net))
          .fontSize(10)
          .fontColor(TEXT_DIM)
          .lineHeight(14)
          .width('100%')
          .textAlign(TextAlign.Start)
          .padding({ left: 6, right: 6, top: 0, bottom: 6 })
      }
    }
    .width('100%')
    .backgroundColor(CARD_BG)
    .borderRadius(5)
    .margin({ bottom: 6 })
    // 封面要跟卡片圆角一致：外层统一裁剪，别在封面单独给圆角
    .clip(true)
    .border({
      width: this.isHighlighted(row) ? 1 : 0,
      color: HL_COLOR
    })
    .onClick(() => {
      this.openVideo(row);
    })
  }

  /**
   * 内联播放器遮罩。
   * 用 Stack + 条件渲染，不用 bindSheet：播放器要全屏、要自己画标题条，
   * sheet 的半模态高度与圆角都跟小程序对不上。
   *
   * 播放地址为 cosUrl（自家 COS 转存），所以 HLS/MP4 都能被 Video 直接吃；
   * 关闭即销毁节点，不需要 VideoController 手动 stop。
   */
  @Builder
  playerMask() {
    Stack({ alignContent: Alignment.Center }) {
      Video({ src: this.playingUrl })
        .width('100%')
        .height('78%')
        .controls(true)
        .autoPlay(true)
        .loop(false)
        .objectFit(ImageFit.Contain)
        .backgroundColor('#000000')
        // 遮罩上的空白点击要能关掉播放器，但点视频本身不能关（小程序 @click.stop），
        // 所以给 Video 挂一个空 onClick 把点击吃掉
        .onClick(() => {
        })

      // 底部标题条贴底：必须包一层满高容器，直接放 Stack 会按 alignContent 居中
      Column() {
        Row() {
          Text(this.playingTitle)
            .fontSize(12)
            .fontColor(TEXT_TITLE)
            .lineHeight(17)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .margin({ right: 12 })

          // 同上：圆钮里套 Row 才稳，单独给 Text 定高会贴顶不居中
          Row() {
            Text('✕').fontSize(15).fontColor('#FFFFFF')
          }
          .width(28)
          .height(28)
          .borderRadius(14)
          .backgroundColor('#1FFFFFFF')
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.closePlayer();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        // .player-bar 的 padding: 24rpx 28rpx
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })
        // 小程序是 to top：底部深、顶部透明。ArkUI 的 angle 0 = 从下往上，
        // 所以 colors[0] 落在底边；写 180 会把深色挪到顶部，正好反过来
        .linearGradient({
          angle: 0,
          colors: [['#E604060A', 0.0], ['#0004060A', 1.0]]
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    // rgba(4,6,10,0.94)：留 6% 透出底下的列表，用户知道自己在哪一层
    .backgroundColor('#F004060A')
    .onClick(() => {
      this.closePlayer();
    })
  }

  /** 空态：小程序 .empty-box（padding 120rpx 0） */
  @Builder
  emptyArea() {
    Column() {
      Text('🎬').fontSize(30).margin({ bottom: 8 })
      Text('还没有视频')
        .fontSize(13)
        .fontColor(TEXT_EMPTY)
      Text('后台正在逐条抓取并转存，过段时间再来看看')
        .fontSize(11)
        .fontColor(TEXT_EMPTY_SUB)
        .textAlign(TextAlign.Center)
        .lineHeight(17.6)
        .width('80%')
        .margin({ top: 5 })
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ top: 60 })
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
  }

  /** 加载态：小程序只有一行 13vp #6B7891，居中、至少 60% 屏高 */
  @Builder
  loadingArea() {
    Row() {
      Text('加载中...').fontSize(13).fontColor(TEXT_HINT)
    }
    .width('100%')
    .height('60%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }
}
