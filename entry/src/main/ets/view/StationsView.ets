/**
 * view/StationsView.ets —— 空间站列表页
 *
 * 对位小程序 `pages/stations/stations.vue`（203 行）：页头 + 15 张卡的空间站档案。
 * 底色 #0A0E17、不铺星空（只有今日页铺），视觉常量与工程其它页同口径。
 *
 * ── 数据链路（照抄 EventsView.ets:126-175 的写法）──
 *   repo.peek<StnPayload>('spacestations')   —— 同步、零网络，冷启动立刻上屏
 *   repo.load<StnPayload>('spacestations', { onCache, onUpdate }) —— 后台刷新
 *     onCache  —— 命中原生缓存时立刻上屏
 *     onUpdate —— 缓存过期、后台拿到新数据时回填
 *   peek 只是「先看一眼」，真正的成败以后面 load() 的 resolve/reject 为准。
 *
 * ── 为什么 failed 与「没数据」必须是两个状态 ──
 *   repo.load 在「弱网 + 无缓存」时是 **reject**，不是返回空数组。
 *   catch 里一旦置 loaded = true，页面就永久停在「暂无空间站」，
 *   用户以为真的没有数据，而实际上是网络挂了（原项目踩过的永久空页坑）。
 *   所以 catch 只置 failed，且 failed = list.length === 0：
 *     list 非空                     → 列表（此时刷新失败也继续显示旧数据）
 *     list 空 && failed             → 加载失败 + 重试
 *     list 空 && !loaded && !failed → 加载中
 *     list 空 && loaded && !failed  → 暂无数据
 *
 * ── 三处实测结论决定的做法（不是漏做）──
 *   1. **缩略图几乎一定走占位**：spacestations.json 的 img 实测 15 条全是空串，
 *      所以无图占位（#1B2330 + 🛰️）是主路径而不是兜底；同时仍保留 Image 分支
 *      与 onError，上游哪天补图就能直接显示。
 *   2. **在役站排前面**：委托方给的比较器只认 'Active'，其余（'Decommissioned' /
 *      'De-Orbited' / 空值）一律沉底；同一档内保持 CI 原序（sort 是稳定排序的
 *      实现差异不可依赖，所以比较器只做二分，不引入第二排序键）。
 *   3. **状态文案在视图侧补映射**：utils/Format 的 stationStatusZh 不认
 *      'Decommissioned' / 'De-Orbited'，会原样回英文。映射收在 model/Station.ets
 *      的 stnStatusText()，列表与详情共用一份，避免两页文案漂移。
 *
 * ── 意图边界 ──
 *   点击整卡只走成员回调 onOpen(item)，**本组件不做任何跳转**：
 *   路由接线归主窗口，视图不该知道自己是挂在哪条 NavPathStack 上。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。不使用 AppStorage / 定时器。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import {
  StnItem, StnPayload, stnStr, stnNum, stnStatusText, stnIsActive,
} from '../model/Station';
import { orbitName, stationName } from '../utils/Format';

const DOMAIN: number = 0x0000;
const TAG: string = 'StationsView';

// ============ 视觉常量（工程约定） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
/** 中文副标题 / 次级说明用的灰（与 LaunchView、EventsView 的 #6B7891 同源） */
const TEXT_LABEL: string = '#6B7891';
/** 卡片里的说明文字，比 #A7B4C7 再暗一档 */
const TEXT_META: string = '#7A8598';
const ACCENT: string = '#38BDF8';
const ACTIVE_GREEN: string = '#34C759';
const IDLE_GRAY: string = '#55617A';
/** 缩略图无图时的底色（任务书给定） */
const THUMB_BG: string = '#1B2330';

/** 卡片圆角 12vp（工程约定） */
const CARD_RADIUS: number = 12;
/** 卡片内边距 12vp：这一页左侧就是 64 的图，14 会显得右边过挤 */
const CARD_PAD: number = 12;
/** 卡间距 10vp（工程约定） */
const CARD_GAP: number = 10;
/** 缩略图边长 64vp + 圆角 8vp（任务书给定） */
const THUMB_SIZE: number = 64;
const THUMB_RADIUS: number = 8;

/** 页面左右内边距 12（与 TodayView / LaunchView / MineView 对齐） */
const PAGE_PAD: number = 12;
/**
 * 底部留白 32。
 * 本页是 NavDestination 二级页，打开时悬浮胶囊已被 Nav.markDetailShown() 摘掉，
 * 不需要按 tab 根页那样让位 92~120；32 只够滑到底时最后一张卡不贴边。
 */
const BOTTOM_PAD: number = 32;

@Component
export struct StationsView {
  // ============ 页面状态 ============

  /** 全量空间站（在役优先，见 sortedList()） */
  @State list: StnItem[] = [];
  /** 是否已经成功拿到过一次数据。**失败时绝不置 true**（见文件头状态说明） */
  @State loaded: boolean = false;
  /** 正在等首屏数据（只挡内容区） */
  @State loading: boolean = true;
  /** 无缓存 + 网络失败。与「没数据」严格分开 */
  @State failed: boolean = false;
  /**
   * 缩略图加载失败的记录 id。
   *
   * 为什么用数组 + 整体替换而不是 Set：ArkTS 对 Set 的增删不保证触发 @State 重绘，
   * 而 `concat([id])` 换的是引用，一定重新渲染。15 条的体量，线性 indexOf 成本可忽略。
   */
  @State hiddenImgs: number[] = [];

  /** 防重入：返回再进来、或连点重试，不应叠请求 */
  private loadingNow: boolean = false;

  /** 点击整卡。普通成员 + 默认空实现（工程约定），不做跳转 */
  onOpen: (item: StnItem) => void = () => {};

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadStations(false);
  }

  // ============ 加载 ============

  private loadStations(force: boolean): void {
    if (this.loadingNow) {
      return;
    }
    this.loadingNow = true;
    this.loading = true;
    this.failed = false;

    // 先 peek：同步、零网络，冷启动能立刻把列表画出来（有缓存就不显示加载态）
    const cached: StnPayload | null = repo.peek<StnPayload>('spacestations');
    if (cached !== null) {
      this.applyPayload(cached);
      if (this.list.length > 0) {
        this.loading = false;
      }
    }

    const opts: LoadOptions<StnPayload> = {
      force: force,
      onCache: (data: StnPayload) => {
        this.applyPayload(data);
      },
      onUpdate: (data: StnPayload) => {
        this.applyPayload(data);
      }
    };

    repo.load<StnPayload>('spacestations', opts)
      .then((data: StnPayload) => {
        this.applyPayload(data);
        // 成功才配 loaded = true；失败分支一个字都不能改它
        this.loaded = true;
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有内容就别说失败，静默留在旧列表上（后台刷新失败不该打断阅读）
        this.failed = this.list.length === 0;
        hilog.warn(DOMAIN, TAG, 'spacestations 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingNow = false;
      });
  }

  /**
   * 数据落地：整体替换数组才能触发 @State 的数组重绘。
   * 一条都没有时保持原样 —— 中途一次半截数据不该把已有列表清空。
   */
  private applyPayload(data: StnPayload): void {
    // list 在载荷里是必填，但 JSON.parse 只是断言、运行时不校验，
    // 所以仍按「可能是 undefined」读，缺了就当成空数组。
    const raw: StnItem[] | undefined = data.list;
    const next: StnItem[] = raw !== undefined ? raw : [];
    if (next.length === 0 && this.list.length > 0) {
      return;
    }
    this.list = next;
  }

  private retry(): void {
    this.loadStations(true);
  }

  // ============ 派生值 ============

  /**
   * 在役优先的列表。
   *
   * 为什么要自己复制一份再排：this.list 是 @State 数据源，
   * 原地 sort 会在数据没变的情况下改掉引用内容，ArkUI 的 diff 依据不足，
   * 排序结果可能不生效；复制 + 排序 + 整体赋给渲染用的临时数组最稳。
   */
  private sortedList(): StnItem[] {
    const out: StnItem[] = [];
    for (let i = 0; i < this.list.length; i++) {
      out.push(this.list[i]);
    }
    out.sort((a: StnItem, b: StnItem) => {
      const av: number = stnIsActive(a.status) ? 1 : 0;
      const bv: number = stnIsActive(b.status) ? 1 : 0;
      return bv - av;
    });
    return out;
  }

  /** 页头副标题：拿到数据才报座数，避免首屏先闪一个假的 15 */
  private subtitleText(): string {
    if (this.list.length > 0) {
      return '人类空间站档案 · ' + String(this.list.length) + ' 座';
    }
    return '人类空间站档案';
  }

  /** 站名：stationName() 查不到时原样返回英文名 */
  private nameOf(item: StnItem): string {
    const zh: string = stationName(stnStr(item.name));
    return zh.length > 0 ? zh : '未命名空间站';
  }

  /** 状态 chip 文案；空值不画 chip（比画一个「未知」干净） */
  private statusOf(item: StnItem): string {
    return stnStatusText(item.status);
  }

  /** 状态 chip 底色：在役绿，其余灰 */
  private statusBgOf(item: StnItem): string {
    return stnIsActive(item.status) ? ACTIVE_GREEN : IDLE_GRAY;
  }

  /** 状态 chip 字色：绿底用深色字，灰底用白字，两条路径对比度都够 */
  private statusFgOf(item: StnItem): string {
    return stnIsActive(item.status) ? BG_PRIMARY : TEXT_MAIN;
  }

  /**
   * 第二行：轨道 · 在轨 N 人。
   * 任一段取不到就跳过，避免留下 " · 在轨 0 人" 或孤零零的分隔符。
   */
  private metaOf(item: StnItem): string {
    const parts: string[] = [];
    const orbit: string = orbitName(stnStr(item.orbit)).trim();
    if (orbit.length > 0) {
      parts.push(orbit);
    }
    const crew: number = stnNum(item.onboardCrew);
    if (crew > 0) {
      parts.push('在轨 ' + String(crew) + ' 人');
    }
    return parts.join(' · ');
  }

  /** 缩略图地址（去掉首尾空白，空串等于没有图） */
  private imgOf(item: StnItem): string {
    return stnStr(item.img).trim();
  }

  /** 有图且没加载失败才画 Image；否则走占位 */
  private showImg(item: StnItem): boolean {
    return this.imgOf(item).length > 0 && this.hiddenImgs.indexOf(item.id) < 0;
  }

  // ============ 交互 ============

  private openItem(item: StnItem): void {
    this.onOpen(item);
  }

  // ============ UI：页头 ============

  @Builder
  header() {
    Column() {
      Text('空间站')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .letterSpacing(1)
        .width('100%')
        .maxLines(1)

      Text(this.subtitleText())
        .fontSize(11)
        .fontColor(TEXT_LABEL)
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8, bottom: 12 })
  }

  // ============ UI：缩略图 ============

  @Builder
  thumb(item: StnItem) {
    Stack() {
      if (this.showImg(item)) {
        Image(this.imgOf(item))
          .width(THUMB_SIZE)
          .height(THUMB_SIZE)
          .objectFit(ImageFit.Cover)
          .backgroundColor(THUMB_BG)
          // 破图就把这条 id 记进隐藏表：下一帧退回 emoji 占位，不留黑块
          .onError(() => {
            this.hiddenImgs = this.hiddenImgs.concat([item.id]);
          })
      } else {
        // 实测 15 条 img 全是空串，这里才是主路径
        Text('🛰️')
          .fontSize(28)
          .width(THUMB_SIZE)
          .height(THUMB_SIZE)
          .textAlign(TextAlign.Center)
          .backgroundColor(THUMB_BG)
      }
    }
    .width(THUMB_SIZE)
    .height(THUMB_SIZE)
    // 圆角裁切用 clip：Stack 没有 overflow 属性
    .borderRadius(THUMB_RADIUS)
    .clip(true)
  }

  // ============ UI：单张卡 ============

  @Builder
  card(item: StnItem) {
    Row() {
      this.thumb(item)

      Column() {
        Row() {
          Text(this.nameOf(item))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (this.statusOf(item).length > 0) {
            Text(this.statusOf(item))
              .fontSize(10)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.statusFgOf(item))
              .backgroundColor(this.statusBgOf(item))
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(4)
              .margin({ left: 8 })
              .maxLines(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.metaOf(item).length > 0) {
          Text(this.metaOf(item))
            .fontSize(11.5)
            .fontColor(TEXT_META)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 12, right: 8 })
      .height(THUMB_SIZE)

      Text('›')
        .fontSize(18)
        .fontColor(TEXT_DIM)
        .maxLines(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(CARD_PAD)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(CARD_BG)
    .onClick(() => {
      this.openItem(item);
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
      Text('正在加载空间站…')
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
      Text('空间站数据加载失败')
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
      Text('🛰️')
        .fontSize(34)
        .opacity(0.5)
      Text('暂无空间站数据')
        .fontSize(13)
        .fontColor(TEXT_SUB)
        .margin({ top: 10 })
      Text('稍后重试')
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

      if (this.sortedList().length === 0) {
        // 三种「空」绝不合并：失败 / 还在加载 / 真的没有（见文件头状态说明）
        if (this.failed) {
          this.failedBlock()
        } else if (!this.loaded) {
          this.loadingBlock()
        } else {
          this.emptyBlock()
        }
      } else {
        List() {
          ForEach(this.sortedList(), (item: StnItem) => {
            ListItem() {
              this.card(item)
            }
            .padding({ bottom: CARD_GAP })
          }, (item: StnItem) => String(item.id))
        }
        // 只给 layoutWeight：同时再写 height('100%') 会让测量拿到父级已扣掉页头的
        // 高度却又按父级 100% 撑开，滑到底时常多出一条空白
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
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
  }
}
