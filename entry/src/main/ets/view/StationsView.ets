/**
 * view/StationsView.ets —— 空间站列表页
 *
 * 对位小程序 `pages/stations/stations.vue`（203 行）：只有 15 张卡，**没有页头大标题**。
 *
 * ── 为什么页头被删掉了（这一条最容易看成「退步」）──
 *   小程序的标题由 nav-bar 承载：`<nav-bar :solid="navSolid" :title="navSolid ? '空间站' : ''" />`，
 *   即滚动超过 120 之后 nav 才浮出「空间站」。页面自身 `.page` 顶部没有任何标题、
 *   没有副标题，第一张卡离顶只有 `.list{margin-top:20rpx}` = 10vp。
 *   鸿蒙版原来常显「空间站」19vp + 「人类空间站档案 · 15 座」11vp，是**多出来的**，
 *   与小程序首屏对不齐，因此整块删除，只在列表上方留 10vp。
 *
 * ── 数据链路（照抄 EventsView.ets:126-175 的写法）──
 *   repo.peek<StnPayload>('spacestations')   —— 同步、零网络，冷启动立刻上屏
 *   repo.load<StnPayload>('spacestations', { onCache, onUpdate }) —— 后台刷新
 *   peek 只是「先看一眼」，真正的成败以后面 load() 的 resolve/reject 为准。
 *
 * ── 为什么 failed 与「没数据」必须是两个状态 ──
 *   repo.load 在「弱网 + 无缓存」时是 **reject**，不是返回空数组。
 *   catch 里一旦置 loaded = true，页面就永久停在「暂无空间站数据」，
 *   用户以为真的没有数据，而实际上是网络挂了（原项目踩过的永久空页坑）。
 *   所以 catch 只置 failed，且 failed = list.length === 0。
 *
 * ── 三态文案 1:1（对位 .hint-text / .empty-text）──
 *   小程序是**纯文字**：加载中 `加载中...`（英文三点）、空态 `暂无空间站数据`，
 *   都没有 spinner / emoji / 按钮。鸿蒙版原来那套 spinner + 🛰️ + 「稍后重试」全删。
 *   唯一保留的差异：失败态也复用「暂无空间站数据」这一行字（视觉与空态一致），
 *   但整块可点 = 重试。理由 —— 删掉重试入口后，弱网无缓存的用户只能杀进程；
 *   而加按钮又会让失败态的版式与小程序不同，所以做成「文字一致 + 隐形热区」。
 *
 * ── 缩略图为什么仍然保留 Image 分支 ──
 *   img 实测 15 条全为空串，无图占位（#0A0E17 + 🛰️）是主路径而不是兜底；
 *   但上游哪天补图就该直接显示，所以 Image 分支与 onError 照留。
 *
 * ── 意图边界 ──
 *   点击整卡只走成员回调 onOpen(item)，**本组件不做任何跳转**：
 *   路由接线归主页面（DetailPages.ets:406-422），视图不该知道自己是挂在哪条 NavPathStack 上。
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

// ============ 视觉常量 ============
// 全部按小程序 rpx ÷ 2 折算（750rpx 设计稿 → 375vp）。

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
/** 站名：小程序 `.name{color:#e2e8f0;font-weight:600}`，不是纯白 */
const TEXT_NAME: string = '#E2E8F0';
/** 副行：小程序 `.meta{color:#6b7891}` */
const TEXT_META: string = '#6B7891';
/** 箭头：小程序 `.arrow{color:#3d4a5c}` */
const TEXT_FAINT: string = '#3D4A5C';
const ACCENT: string = '#38BDF8';

/** 在役 chip：底 rgba(56,189,248,.16)、字 #38bdf8（不是绿实底） */
const CHIP_ON_BG: string = '#2938BDF8';
const CHIP_ON_FG: string = '#38BDF8';
/** 非在役 chip：底 rgba(255,255,255,.05)、字 #55617a */
const CHIP_OFF_BG: string = '#0DFFFFFF';
const CHIP_OFF_FG: string = '#55617A';

/** 缩略图无图时的底色：小程序 `.thumb{background:#0a0e17}`，即页面底色 */
const THUMB_BG: string = '#0A0E17';

/** 卡片圆角 20rpx = 10vp */
const CARD_RADIUS: number = 10;
/** 卡片内边距 20rpx = 10vp */
const CARD_PAD: number = 10;
/** 卡间距 18rpx = 9vp */
const CARD_GAP: number = 9;
/** 缩略图 120rpx = 60vp 方形，圆角 16rpx = 8vp */
const THUMB_SIZE: number = 60;
const THUMB_RADIUS: number = 8;
/** 图文间距：小程序 `.info{margin:0 18rpx}` = 左右各 9vp */
const INFO_GAP: number = 9;

/** 页面左右内边距 32rpx = 16vp（对位 `.page{padding:0 32rpx 80rpx}`） */
const PAGE_PAD: number = 16;
/**
 * 底部留白 32。
 * 小程序给的是 80rpx=40vp，但本工程二级页统一 32（NavDestination 不再有悬浮胶囊要躲），
 * 差 8vp 只在滑到底时可见，沿用工程约定以免这一页比别的二级页多一截空白。
 */
const BOTTOM_PAD: number = 32;
/** 列表顶部留白：对位 `.list{margin-top:20rpx}` = 10vp（也是被删掉的页头留下的空档） */
const LIST_TOP: number = 10;

/**
 * 卡片描边 1rpx → 0.5vp，颜色 rgba(255,255,255,.05) → alpha 0x0D。
 * 用 '#0DFFFFFF' 而不是 'rgba(...)' 字符串：工程内描边一律走这个写法，便于和 nav-bar 对拍。
 */
const CARD_BORDER: string = '#0DFFFFFF';

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
   * 比较器只做「在役 / 非在役」二分（对位小程序的 sort），同档内保持 CI 原序。
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

  /** 站名：stationName() 查不到时原样返回英文名 */
  private nameOf(item: StnItem): string {
    const zh: string = stationName(stnStr(item.name));
    return zh.length > 0 ? zh : '未命名空间站';
  }

  /** 状态 chip 文案；空值不画 chip（比画一个「未知」干净） */
  private statusOf(item: StnItem): string {
    return stnStatusText(item.status);
  }

  /** 在役 = 蓝色半透明底 + 同色字；其余 = 白色 5% 底 + 三级灰字 */
  private statusBgOf(item: StnItem): string {
    return stnIsActive(item.status) ? CHIP_ON_BG : CHIP_OFF_BG;
  }

  private statusFgOf(item: StnItem): string {
    return stnIsActive(item.status) ? CHIP_ON_FG : CHIP_OFF_FG;
  }

  /**
   * 第二行：轨道 · 在轨 N 人（对位 `{{s.orbit || '未知轨道'}} · 在轨 N 人`）。
   * 轨道缺省时小程序给「未知轨道」，这里照抄，不留空串；
   * 在轨人数按小程序的 `v-if="s.onboardCrew"` 判真假，0 人就不写这一段。
   */
  private metaOf(item: StnItem): string {
    const orbit: string = orbitName(stnStr(item.orbit)).trim();
    const head: string = orbit.length > 0 ? orbit : '未知轨道';
    const crew: number = stnNum(item.onboardCrew);
    if (crew > 0) {
      return head + ' · 在轨 ' + String(crew) + ' 人';
    }
    return head;
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
        // 实测 15 条 img 全是空串，这里才是主路径；占位 56rpx = 28vp
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
            // 小程序 w600；ArkTS 没有 Semibold 枚举，用 600 的字重数值最接近
            .fontWeight(600)
            .fontColor(TEXT_NAME)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (this.statusOf(item).length > 0) {
            // 19rpx = 9.5vp、padding 3rpx 12rpx = 1.5/6vp、圆角 6rpx = 3vp
            Text(this.statusOf(item))
              .fontSize(9.5)
              .fontColor(this.statusFgOf(item))
              .backgroundColor(this.statusBgOf(item))
              .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
              .borderRadius(3)
              .margin({ left: 6 })
              .maxLines(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text(this.metaOf(item))
          .fontSize(11)
          .fontColor(TEXT_META)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 5 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Center)
      .padding({ left: INFO_GAP, right: INFO_GAP })
      // 两行文字的块与 60vp 的图等高，名称/副行才能贴着图的垂直中线分布
      .height(THUMB_SIZE)

      Text('›')
        .fontSize(17)
        .fontColor(TEXT_FAINT)
        .maxLines(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(CARD_PAD)
    .borderRadius(CARD_RADIUS)
    .backgroundColor(CARD_BG)
    .border({ width: 0.5, color: CARD_BORDER })
    .onClick(() => {
      this.openItem(item);
    })
  }

  // ============ UI：三态（纯文字，对位 .hint-text / .empty-text） ============

  @Builder
  hintBlock(text: string, tappable: boolean) {
    Column() {
      Text(text)
        .fontSize(13)
        .fontColor(TEXT_META)
        .textAlign(TextAlign.Center)
        .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Start)
    // 小程序 `padding:200rpx 40rpx` = 上 100vp、左右 20vp，文字落在屏幕上方三分之一处
    .padding({ top: 100, left: 20, right: 20 })
    .onClick(() => {
      // 只有失败态可点（tappable），加载中 / 真·空态点了没意义
      if (tappable) {
        this.retry();
      }
    })
  }

  // ============ build ============

  build() {
    Column() {
      if (this.sortedList().length === 0) {
        // 三种「空」绝不合并：失败 / 还在加载 / 真的没有（见文件头状态说明）
        if (this.failed) {
          // 文案与空态一致，但整块可点重试（隐形热区，不加按钮）
          this.hintBlock('暂无空间站数据', true)
        } else if (!this.loaded) {
          // 小程序原文就是英文三点，别改成中文省略号
          this.hintBlock('加载中...', false)
        } else {
          this.hintBlock('暂无空间站数据', false)
        }
      } else {
        List() {
          ForEach(this.sortedList(), (item: StnItem) => {
            ListItem() {
              this.card(item)
            }
            .padding({ bottom: CARD_GAP })
          // key 里带上 hiddenImgs 长度：缩略图 onError 只改 @State 数组，
          // 而 @Builder 按值传参不会因此重建，靠 key 变化强制这张卡重算占位分支
          }, (item: StnItem) => String(item.id) + '#' + String(this.hiddenImgs.length))
        }
        // 只给 layoutWeight：同时再写 height('100%') 会让测量拿到父级已扣掉页头的高度
        // 却又按父级 100% 撑开，滑到底时常多出一条空白
        .width('100%')
        .layoutWeight(1)
        .padding({ top: LIST_TOP })
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
