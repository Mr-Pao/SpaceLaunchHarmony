/**
 * view/GalleryView.ets —— 「图库」tab（对位小程序 pages/gallery/gallery.vue，804 行）
 *
 * ── 这一页到底是什么 ──
 *   不是列表，是一面**会自己走的墙**：8 条横向图带，左右方向交替，46~62 秒跑完一趟，
 *   首尾相接无缝循环。用户不需要滑动，图自己送上来；点任意一张进详情。
 *
 * ── 对位关系（小程序行号 → 本文件）──
 *   模板 3-30 行 .stage/.bands/.band/.track/.cell   → this.bandWall() + components/GalleryGrid.ets
 *   模板 6-8 行左右方向交替、52/44/62/48/56/40/58/46s → BAND_DUR + toLeft（宽带走左、窄带走右）
 *   模板 32-40 行 四面渐隐 .fade                    → this.fades()
 *   模板 42-52 行 .hud（青点 / SPACE GALLERY / N 张 / 下划线）→ this.hud()
 *   模板 55 行 .wall-tip 呼吸                        → this.wallTip()
 *   模板 57-63 行 .dock 的「看全部 N ›」              → this.dock()
 *   模板 65-70 行 loading / empty-box               → this.loadingBox() / this.emptyBox()
 *   脚本 3-8 行 PER_ROW=12 / ROWS=8 / shuffle       → MP_PER_ROW / MP_ROWS / this.shuffled()
 *   脚本 60-120 行 四数据集合并成 pool 再交错分桶     → loadXxx() + buildWall()
 *   脚本 122-165 行 preview() 的点击分流              → this.openItem()
 *
 * ── 单位换算（rpx ÷ 2 = vp）──
 *   页头 kicker 21rpx → 10.5vp / letter-spacing 4rpx → 2vp
 *   `N 张` 20rpx → 10vp；分隔符 18rpx → 9vp；青点 10rpx → 5vp；下划线 120×2rpx → 60×1vp
 *   wall-tip 21rpx → 10.5vp；胶囊文字 24rpx → 12vp、数字 25rpx → 12.5vp、箭头 30rpx → 15vp
 *   胶囊内边距 16/32rpx → 8/16vp；胶囊距底 152rpx → 76vp；提示距底 240rpx → 120vp
 *   空态图标 60rpx → 30vp、正文 26rpx → 13vp、副文 22rpx → 11vp
 *   （图带内的 cell 宽度换算写在 components/GalleryGrid.ets 文件头）
 *
 * ── 有意差异（都是鸿蒙侧没得选，逐条说明）──
 *   1. 鸿蒙没有 CSS keyframes / `translateX(-50%)`：位移由各条带自己的 setInterval 递推，
 *      位移量按「张数 ×（格宽 + 间距）」算出来（见 GalleryGrid.ets）。
 *   2. `.hud` 在小程序是 fixed，且要加状态栏高度。鸿蒙这边 Tabs 内容区本来就在系统栏
 *      之下（EntryAbility 没开全屏布局），所以 HUD 只需要 top 12vp，不读安全区。
 *   3. `.dock` / `.wall-tip` / 四面渐隐的 `pointer-events: none` 用 `HitTestMode.None` 等效：
 *      自身不参与命中测试，但**子节点照常响应**，也不阻塞下层图带 ——
 *      正好等于 css 里「父层 none + 子元素 auto」。页头 HUD 用 `Transparent`
 *      （自身与子节点都参与、只是不阻塞兄弟），因为它压在渐隐层之上，
 *      需要让「▶ 视频 ›」这颗按钮稳定可点，而它自己没有 onClick，多响应一层无害。
 *   4. 胶囊的 `backdrop-filter: blur(24rpx)` 没有照搬：本工程虽有 `.backdropBlur()`
 *      先例（view/RocketView.ets:556），但它吃 GPU、且这层胶囊要长期压在会动的图带上方，
 *      改用更实的底色（#B30A101A）保证在亮图上仍可读，视觉几乎等价。
 *   5. 文字没有 text-shadow：工程内无先例，且底部渐隐已经提供了暗底。
 *   6. 「▶ 视频 ›」是**有意保留的功能增量**（小程序把视频库藏在 gallery-all 第四个分段里，
 *      鸿蒙侧没有那条路由），放在页头右侧。
 *   7. 「看全部」的落点：小程序跳独立页 pages/gallery-all（分类浏览器）。鸿蒙侧没有这条
 *      路由，而本次只允许改两个文件、不许加页面 —— 所以在**本页**切到清单模式，
 *      把 gallery 全量分片按三列铺开，并给「‹ 返回图墙」回程。少了分类筛选，
 *      但「入口存在 + 能一路滑到全量」这两个核心目的达成。
 *   8. 点击分流：launch 类走发射详情，其它走看图器。**LaunchNavParam 没有 photo 标志位**，
 *      拿不到小程序的 `photo=1` 看图模式，只能进详情默认页 —— 已知差距。
 *
 * ── 数据 ──
 *   四类并行拉：gallery（发射图）/ epic（每日地球）/ apod（每日天文）/ nasaImages（星云），
 *   各自 timeout，全部落定后才 buildWall（对位小程序的 Promise.allSettled + loading=false）。
 *   总张数 = 四类 count 之和（对位 counts 汇总出的 total）。
 *   大数组放普通成员，@State 只放「上屏那一份」，避免 1000+ 条被状态代理全量 diff。
 *
 * ── 已知代价 ──
 *   8 条带各一个 16ms 定时器（共 8 个 tick/帧）。切到别的 tab 时 Tabs 不销毁 TabContent，
 *   这些定时器会继续跑；内存与耗电影响可接受但非零。要彻底停只能接可见性回调，
 *   属于后续优化项，不在本次改动范围。
 *
 * ⚠ 日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions, ChunkResult } from '../data/Repository';
import { strOf } from '../utils/Format';
import { fullImageOf } from '../utils/Media';
import { ApodItem, ApodPayload, EpicItem, EpicPayload } from '../model/Apod';
import {
  MpAllGrid, MpBand, MpBandView, MpImage,
  MpGalleryRaw, MpGalleryPayload, MpNasaRaw, MpNasaPayload,
  MP_PER_ROW, MP_ROWS
} from '../components/GalleryGrid';
import { Nav } from '../routes/Nav';
import { LaunchNavParam, PhotoNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'GalleryView';

/** 页面底色：小程序 `#070b12`（比工程主底 #0A0E17 更深，图墙需要更黑的底衬托） */
const BG_PAGE: string = '#070B12';
const ACCENT: string = '#38BDF8';
const TXT_KICKER: string = '#E2EEFB';
const TXT_SEP: string = '#36435A';
const TXT_COUNT: string = '#8FA3BD';
const TXT_DIM: string = '#55617A';

/** 页头左右边距 32rpx */
const HUD_PAD: number = 16;
/** 页头顶部留白 12vp（Tabs 内容区不含系统状态栏，不必再加状态栏高） */
const HUD_TOP: number = 12;
/** 胶囊距底 152rpx */
const DOCK_BOTTOM: number = 76;
/** 呼吸提示距底 240rpx */
const TIP_BOTTOM: number = 120;
/** 底部给悬浮 tabBar 的让位（胶囊浮层，不是布局元素） */
const BOTTOM_PAD: number = 120;
/** 清单模式顶部让出 HUD */
const LIST_TOP: number = 64;
/** 带高权重：wxss `.band { flex: 232 }` / `.band-t { flex: 164 }`（比例值，不换算） */
const BAND_W_WIDE: number = 232;
const BAND_TIGHT: number = 164;
/** t1..t8 的时长（毫秒），与 wxss 的 52s/44s/62s/48s/56s/40s/58s/46s 一一对应 */
const BAND_DUR: number[] = [52000, 44000, 62000, 48000, 56000, 40000, 58000, 46000];
/** 呼吸半周期：tipBreath 3.4s 走一轮，这里 1.7s 翻一次 */
const TIP_BREATH_MS: number = 1700;
/** 首屏四类数据的超时（小程序 5s / 3.5s×3） */
const T_GALLERY_MS: number = 5000;
const T_OTHER_MS: number = 3500;

@Component
export struct GalleryView {
  // ============ 上屏状态（必须 @State：文本/布局要跟着变） ============

  /** 8 条带。体积不小（192 个引用），但它是「上屏那一份」，只能放 @State */
  @State bands: MpBand[] = [];
  /** 四类是否全部落定 */
  @State loading: boolean = true;
  /** 总张数 = 四类 count 之和（HUD 的 `N 张`、胶囊的数字都用它） */
  @State total: number = 0;
  /** 呼吸提示的明暗两档，靠 .animation 补间 */
  @State tipOn: boolean = false;

  // ============ 清单模式（「看全部」的落点，见文件头第 7 条） ============

  @State listMode: boolean = false;
  @State listPhotos: MpImage[] = [];
  @State listTotal: number = 0;
  @State listAppending: boolean = false;
  @State listEnded: boolean = false;

  // ============ 数据（普通成员，不进 @State） ============

  /** 四类图池，分开存：onUpdate 只换自己那一类，不惊动其它 */
  private launchPool: MpImage[] = [];
  private earthPool: MpImage[] = [];
  private astroPool: MpImage[] = [];
  private nasaPool: MpImage[] = [];

  /** 四类计数（count 优先，缺失时退 list.length） */
  private cntLaunch: number = 0;
  private cntEarth: number = 0;
  private cntAstro: number = 0;
  private cntNasa: number = 0;

  /** 四个 load 的未落定计数；减到 0 才铺墙 */
  private pending: number = 4;

  /** 清单模式的母本与游标（分片规则见下 loadMoreList） */
  private listAll: MpImage[] = [];
  private listNext: number = 1;
  private listChunks: number = 1;
  private listStamp: string = '';

  /** 呼吸定时器；-1 表示没在跑 */
  private tipTimer: number = -1;

  aboutToAppear(): void {
    this.loading = true;
    this.startTipBreath();
    this.loadGallery();
    this.loadEpic();
    this.loadApod();
    this.loadNasa();
  }

  /** 退出本页必须停呼吸定时器（图带自己的定时器在各自组件里清） */
  aboutToDisappear(): void {
    if (this.tipTimer >= 0) {
      clearInterval(this.tipTimer);
      this.tipTimer = -1;
    }
  }

  // ============ 加载：四类并行，各自落定 ============

  private loadGallery(): void {
    const opts: LoadOptions<MpGalleryPayload> = {
      timeoutMs: T_GALLERY_MS,
      // 有缓存先上屏、再静默刷新。applyGallery 是纯覆盖（不追加上屏那份），
      // 所以后台刷新不会把已经铺好的墙搅乱
      onUpdate: (data: MpGalleryPayload) => {
        this.applyGallery(data);
      }
    };
    repo.load<MpGalleryPayload>('gallery', opts)
      .then((data: MpGalleryPayload) => {
        this.applyGallery(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'gallery 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  private loadEpic(): void {
    const opts: LoadOptions<EpicPayload> = {
      timeoutMs: T_OTHER_MS,
      onUpdate: (data: EpicPayload) => {
        this.applyEpic(data);
      }
    };
    repo.load<EpicPayload>('epic', opts)
      .then((data: EpicPayload) => {
        this.applyEpic(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'epic 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  private loadApod(): void {
    const opts: LoadOptions<ApodPayload> = {
      timeoutMs: T_OTHER_MS,
      onUpdate: (data: ApodPayload) => {
        this.applyApod(data);
      }
    };
    repo.load<ApodPayload>('apod', opts)
      .then((data: ApodPayload) => {
        this.applyApod(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'apod 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  private loadNasa(): void {
    const opts: LoadOptions<MpNasaPayload> = {
      timeoutMs: T_OTHER_MS,
      onUpdate: (data: MpNasaPayload) => {
        this.applyNasa(data);
      }
    };
    repo.load<MpNasaPayload>('nasaImages', opts)
      .then((data: MpNasaPayload) => {
        this.applyNasa(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'nasaImages 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.settle();
      });
  }

  /**
   * 一个 load 落定。四个都落定（成功或失败）才铺墙 —— 和小程序一样，
   * 宁可多等半秒也要一次成墙，否则会出现「墙先出 12 张、一秒后跳成 96 张」的抖动。
   */
  private settle(): void {
    if (this.pending > 0) {
      this.pending = this.pending - 1;
    }
    if (this.pending > 0) {
      return;
    }
    this.recount();
    this.loading = false;
    this.buildWall();
  }

  // ============ 四类各自的整形 ============

  private applyGallery(data: MpGalleryPayload): void {
    const raw: MpGalleryRaw[] = data.list !== undefined && data.list !== null ? data.list : [];
    const out: MpImage[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: MpGalleryRaw = raw[i];
      const thumb: string = strOf(item.thumb);
      if (thumb.length === 0) {
        // 没有缩略图就是一块黑，直接剔掉（同 TodayView 的过滤口径）
        continue;
      }
      const id: string = strOf(item.id);
      const key: string = id.length > 0 ? id : 'g-' + String(i);
      // 发射图可以从缩略图推 _2000 原图；推不出来退回缩略图
      const given: string = strOf(item.full);
      const guessed: string = fullImageOf(thumb);
      const full: string = given.length > 0 ? given : (guessed.length > 0 ? guessed : thumb);
      out.push(new MpImage(key, thumb, full, this.titleOf(item.name), 'launch', strOf(item.net)));
    }
    this.launchPool = out;
    this.cntLaunch = data.count !== undefined && data.count > 0 ? data.count : out.length;
    this.afterPoolChange();
  }

  private applyEpic(data: EpicPayload): void {
    const raw: EpicItem[] = data.list !== undefined && data.list !== null ? data.list : [];
    const out: MpImage[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: EpicItem = raw[i];
      const thumb: string = strOf(item.thumb);
      const given: string = strOf(item.full);
      const cover: string = thumb.length > 0 ? thumb : given;
      if (cover.length === 0) {
        continue;
      }
      const key: string = 'epic-' + strOf(item.date) + '-' + String(i);
      // 标题写死：EPIC 是同一颗卫星拍同一颗星球，没有逐张标题（小程序同样写死）
      out.push(new MpImage(key, cover, given.length > 0 ? given : cover,
        '地球 · DSCOVR', 'photo', ''));
    }
    this.earthPool = out;
    this.cntEarth = data.count !== undefined && data.count > 0 ? data.count : out.length;
    this.afterPoolChange();
  }

  private applyApod(data: ApodPayload): void {
    const raw: ApodItem[] = data.list !== undefined && data.list !== null ? data.list : [];
    const out: MpImage[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: ApodItem = raw[i];
      const thumb: string = strOf(item.thumb);
      const given: string = strOf(item.full);
      const cover: string = thumb.length > 0 ? thumb : given;
      if (cover.length === 0) {
        continue;
      }
      const zh: string = strOf(item.titleZh);
      const title: string = zh.length > 0 ? zh : strOf(item.title);
      const key: string = 'apod-' + strOf(item.date) + '-' + String(i);
      out.push(new MpImage(key, cover, given.length > 0 ? given : cover, title, 'photo', ''));
    }
    this.astroPool = out;
    this.cntAstro = data.count !== undefined && data.count > 0 ? data.count : out.length;
    this.afterPoolChange();
  }

  private applyNasa(data: MpNasaPayload): void {
    const raw: MpNasaRaw[] = data.list !== undefined && data.list !== null ? data.list : [];
    const out: MpImage[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: MpNasaRaw = raw[i];
      // ⚠ 星云的 thumb 与 full 是两个不同 hash 的地址，不能像发射图那样用 _2000 互推
      const thumb: string = strOf(item.thumb);
      const given: string = strOf(item.full);
      const cover: string = thumb.length > 0 ? thumb : given;
      if (cover.length === 0) {
        continue;
      }
      const zh: string = strOf(item.titleZh);
      const title: string = zh.length > 0 ? zh : strOf(item.title);
      const id: string = strOf(item.id);
      const key: string = 'nasa-' + (id.length > 0 ? id : String(i));
      out.push(new MpImage(key, cover, given.length > 0 ? given : cover, title, 'photo', ''));
    }
    this.nasaPool = out;
    this.cntNasa = data.count !== undefined && data.count > 0 ? data.count : out.length;
    this.afterPoolChange();
  }

  /**
   * 图池变化后的统一收尾。
   *
   * 已经铺过墙就不再重铺 —— 重铺会让 8 条带全部重建，漂移从 0 开始，
   * 用户会看到「墙突然跳一下」。只有「墙还是空的但数据到了」时才补铺。
   */
  private afterPoolChange(): void {
    this.recount();
    if (!this.loading) {
      this.buildWall();
    }
  }

  /** 总张数：四类 count 之和（对位小程序 counts 汇总出的 total） */
  private recount(): void {
    this.total = this.cntLaunch + this.cntEarth + this.cntAstro + this.cntNasa;
  }

  // ============ 铺墙 ============

  /**
   * 把四类图打散、切 96 张、交错分到 8 条带，每条带再复制一份接尾。
   *
   * 「交错分桶（i % 8）」而不是「按顺序切 8 段」：小程序的 pool 是四类混排，
   * 顺序切会让某一条带整条都是同一类图；交错之后每条带的题材都均匀，
   * 视觉上才像一面随机墙。
   */
  private buildWall(): void {
    if (this.bands.length > 0) {
      return;
    }
    const all: MpImage[] = this.launchPool
      .concat(this.earthPool)
      .concat(this.astroPool)
      .concat(this.nasaPool);
    if (all.length === 0) {
      return;
    }
    const want: number = MP_PER_ROW * MP_ROWS;
    const picked: MpImage[] = this.shuffled(all).slice(0, want);

    // 先建 8 个空桶再 push：ArkTS 的嵌套数组初始化不能写成 [[], []] 字面量
    const halves: MpImage[][] = [];
    for (let r = 0; r < MP_ROWS; r++) {
      const empty: MpImage[] = [];
      halves.push(empty);
    }
    for (let i = 0; i < picked.length; i++) {
      halves[i % MP_ROWS].push(picked[i]);
    }

    const built: MpBand[] = [];
    for (let r = 0; r < MP_ROWS; r++) {
      const half: MpImage[] = halves[r];
      if (half.length === 0) {
        // 池子不足 96 张时后面的带是空的，跳过即可（小程序会渲染空 track，效果相同）
        continue;
      }
      // 首尾相接：位移到 -half 时画面与起点逐像素重合，回弹那一瞬看不出接缝
      const doubled: MpImage[] = half.concat(half);
      // 宽带走左、窄带走右（wxss：t1/t3/t5/t7 是宽 + marqueeL，t2/t4/t6/t8 是窄 + marqueeR）
      const wide: boolean = r % 2 === 0;
      built.push(new MpBand(doubled, wide, BAND_DUR[r % BAND_DUR.length], wide, 'band-' + String(r)));
    }
    this.bands = built;
  }

  /** Fisher-Yates。整份新数组，不动入参（入参是缓存出来的数据） */
  private shuffled(src: MpImage[]): MpImage[] {
    const out: MpImage[] = src.slice(0);
    for (let i = out.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: MpImage = out[i];
      out[i] = out[j];
      out[j] = tmp;
    }
    return out;
  }

  /** 'Falcon 9 Block 5 | Starlink Group 15-18' → 'Starlink Group 15-18' */
  private titleOf(name: string | undefined): string {
    const raw: string = strOf(name);
    if (raw.length === 0) {
      return '';
    }
    const parts: string[] = raw.split('|');
    const picked: string = parts.length > 1 ? parts[1] : parts[0];
    return picked.trim();
  }

  // ============ 点击 ============

  /**
   * 点击分流，对位小程序 preview()：
   *   launch 且有 id → 发射详情（小程序是 launchInfo?photo=1，鸿蒙侧只有 pushLaunch）
   *   其余           → 通用看图器
   */
  private openItem(item: MpImage): void {
    if (item.kind === 'launch' && item.id.length > 0) {
      Nav.pushLaunch(new LaunchNavParam(item.id, item.net, item.title));
      return;
    }
    const url: string = item.full.length > 0 ? item.full : item.thumb;
    if (url.length === 0) {
      return;
    }
    Nav.pushPhoto(new PhotoNavParam(url, item.title));
  }

  // ============ 「看全部」清单模式 ============

  private enterListMode(): void {
    if (this.listMode) {
      return;
    }
    this.listMode = true;
    if (this.listAll.length === 0) {
      this.loadListIndex();
    }
  }

  private exitListMode(): void {
    this.listMode = false;
  }

  private loadListIndex(): void {
    const opts: LoadOptions<MpGalleryPayload> = {
      timeoutMs: T_GALLERY_MS,
      onUpdate: (data: MpGalleryPayload) => {
        this.applyListIndex(data);
      }
    };
    repo.load<MpGalleryPayload>('gallery', opts)
      .then((data: MpGalleryPayload) => {
        this.applyListIndex(data);
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '清单索引加载失败: %{public}s', e.message);
        this.listEnded = true;
      });
  }

  private applyListIndex(data: MpGalleryPayload): void {
    const stamp: string = strOf(data.generatedAt);
    // 同一份 generatedAt 的 onUpdate 重复进来时不要重置游标，否则已追加的分片全退回
    if (this.listAll.length > 0 && stamp.length > 0 && stamp === this.listStamp) {
      return;
    }
    this.listStamp = stamp;

    const raw: MpGalleryRaw[] = data.list !== undefined && data.list !== null ? data.list : [];
    const first: MpImage[] = this.toListImages(raw, 0);
    if (first.length === 0) {
      return;
    }
    this.listAll = first;
    this.listPhotos = first;
    this.listTotal = data.count !== undefined && data.count > 0 ? data.count : first.length;
    // 终止条件只认索引文件的 chunks，不用 res.end：见 data/Repository.ets 的 toChunk，
    // index > 0 时上层传 d=undefined，chunks 恒 1、end 恒 true，信它会在第一片后就停
    this.listChunks = data.chunks !== undefined && data.chunks > 0 ? data.chunks : 1;
    this.listNext = 1;
    this.listEnded = this.listNext >= this.listChunks;
  }

  /** 触底追加。三道闸门：锁、末尾、片号越界 —— 缺任何一个都会重复拉同一片 */
  private loadMoreList(): void {
    if (this.listAppending || this.listEnded) {
      return;
    }
    if (this.listNext >= this.listChunks) {
      this.listEnded = true;
      return;
    }
    this.listAppending = true;
    const idx: number = this.listNext;

    repo.chunk<MpGalleryRaw>('gallery', idx)
      .then((res: ChunkResult<MpGalleryRaw>) => {
        const more: MpImage[] = this.toListImages(res.list, idx * 1000);
        if (more.length === 0) {
          // 空片说明索引与真实分片对不上，收口，别让用户一直往下滑
          this.listEnded = true;
          return;
        }
        // concat 出新数组 → 赋值给 @State 才会触发重绘（push 改的是同一引用，观察不到）
        const next: MpImage[] = this.listAll.concat(more);
        this.listAll = next;
        this.listPhotos = next;
        this.listNext = idx + 1;
        if (this.listNext >= this.listChunks) {
          this.listEnded = true;
        }
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '清单第 %{public}d 片失败: %{public}s', idx, e.message);
        // 失败不置 ended：下次触底还能重试这一片
      })
      .then(() => {
        this.listAppending = false;
      });
  }

  /**
   * gallery 原始条目 → 清单条目。
   *
   * offset 只用来造 key：分片追加时同一条目可能在不同片里出现（索引与分片对不齐时），
   * 带上片号就能保证 ForEach 的 key 全局唯一，不会出现「复用错格子」。
   */
  private toListImages(raw: MpGalleryRaw[], offset: number): MpImage[] {
    const out: MpImage[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item: MpGalleryRaw = raw[i];
      const thumb: string = strOf(item.thumb);
      if (thumb.length === 0) {
        continue;
      }
      const id: string = strOf(item.id);
      const key: string = (id.length > 0 ? id : 'g') + '#' + String(offset + i);
      const given: string = strOf(item.full);
      const guessed: string = fullImageOf(thumb);
      const full: string = given.length > 0 ? given : (guessed.length > 0 ? guessed : thumb);
      out.push(new MpImage(key, thumb, full, this.titleOf(item.name), 'launch', strOf(item.net)));
    }
    return out;
  }

  // ============ 呼吸提示 ============

  /**
   * 清单模式的进度串。
   *
   * 写成普通方法而不是在 @Builder 里拼字符串：listPhotos 是 @State，
   * 这里读它的 length，值变了就会重算，和 @Builder 的响应式时机一致。
   * 首帧 listPhotos 还是空的（索引异步回来），容忍它显示 0 / 0。
   */
  private listProgress(): string {
    if (this.listTotal <= 0 && this.listPhotos.length === 0) {
      return '正在取全量图库…';
    }
    const got: number = this.listPhotos.length;
    const all: number = this.listTotal > 0 ? this.listTotal : got;
    if (this.listEnded && got >= all) {
      return '共 ' + String(got) + ' 张 · 到底了';
    }
    return '已载入 ' + String(got) + ' / 共 ' + String(all) + ' 张';
  }

  private startTipBreath(): void {
    if (this.tipTimer >= 0) {
      return;
    }
    this.tipTimer = setInterval(() => {
      this.tipOn = !this.tipOn;
    }, TIP_BREATH_MS);
  }

  // ============ UI ============

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ① 铺底：小程序 `#070b12` + 双径向光晕（.page 的 background 三层叠加）
      this.pageGlow()

      // ② 主体
      if (this.listMode) {
        this.listBody()
      } else {
        if (this.bands.length > 0) {
          this.bandWall()
        }
        if (this.loading) {
          this.loadingBox()
        } else if (this.bands.length === 0) {
          this.emptyBox()
        }
      }

      // ③ 四面渐隐（z 5）：压住顶/底/左右的边，图带从暗处浮出来的观感
      this.fades()

      // ④ HUD（z 20）：放渐隐之上，否则顶部 26% 的暗角会把标题压灰
      this.hud()

      // ⑤ 底部悬浮件：图墙模式是「看全部」胶囊 + 呼吸提示，清单模式是回程胶囊 + 进度
      if (this.listMode) {
        this.listTip()
        this.backDock()
      } else if (this.bands.length > 0) {
        this.wallTip()
        this.dock()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PAGE)
  }

  /**
   * 背景光晕。
   *
   * css：radial-gradient(120% 50% at 50% 0%, rgba(56,189,248,0.14), transparent 62%),
   *      radial-gradient(90% 45% at 0% 100%, rgba(88,120,255,0.1), transparent 60%), #070b12
   * ArkUI 用两个铺满的容器各自的 radialGradient 叠出来，顺序与 css 一致（先上后下）。
   */
  @Builder
  pageGlow() {
    Stack() {
      // 顶部青蓝主光
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['50%', '0%'],
          radius: '62%',
          colors: [['#2438BDF8', 0.0], ['#0038BDF8', 1.0]]
        })

      // 左下补光（rgba(88,120,255,0.1)）
      Column()
        .width('100%')
        .height('100%')
        .radialGradient({
          center: ['0%', '100%'],
          radius: '60%',
          colors: [['#1A5878FF', 0.0], ['#005878FF', 1.0]]
        })
    }
    .width('100%')
    .height('100%')
    // 纯装饰，绝不能吃掉图带的点击
    .hitTestBehavior(HitTestMode.None)
  }

  /** 8 条漂移带。每条带自带定时器与位移，父级一个 tick 都不参与 */
  @Builder
  bandWall() {
    Column() {
      ForEach(this.bands, (band: MpBand, index: number) => {
        MpBandView({
          images: band.images,
          wide: band.wide,
          durMs: band.durMs,
          toLeft: band.toLeft,
          weight: band.wide ? BAND_W_WIDE : BAND_TIGHT,
          isLast: index === this.bands.length - 1,
          onOpen: (item: MpImage) => {
            this.openItem(item);
          }
        })
      }, (band: MpBand, index: number) => band.key)
    }
    .width('100%')
    .height('100%')
  }

  /** 「看全部」的清单：三列等高，触底追加 */
  @Builder
  listBody() {
    Column() {
      MpAllGrid({
        photos: this.listPhotos,
        onOpen: (item: MpImage) => {
          this.openItem(item);
        },
        onBottom: () => {
          this.loadMoreList();
        }
      })
    }
    .width('100%')
    .height('100%')
    // 顶部让出 HUD，底部让出悬浮胶囊
    .padding({ top: LIST_TOP, bottom: BOTTOM_PAD, left: 12, right: 12 })
  }

  /**
   * 四面渐隐。
   *
   * 用嵌套 Stack 各自的对齐来定位，不用绝对定位：
   * ArkUI 的 position 只吃数值，而这里的高宽都是百分比（css 里就是 26% / 34% / 90rpx）。
   * 三块全是纯装饰、不接事件。
   */
  @Builder
  fades() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 顶部：高 26%，rgba(7,11,18) 0.94 → 0.5 → 0（css 是 to bottom）
      Column()
        .width('100%')
        .height('26%')
        .linearGradient({
          angle: 180,
          colors: [['#F0070B12', 0.0], ['#80070B12', 0.55], ['#00070B12', 1.0]]
        })

      // 左侧：宽 45vp（90rpx），向右渐隐（css to right → angle 90）
      Column()
        .width(45)
        .height('100%')
        .linearGradient({
          angle: 90,
          colors: [['#EB070B12', 0.0], ['#00070B12', 1.0]]
        })

      // 底部：高 34%，0.98 → 0.6 → 0（css to top → angle 0）
      Stack({ alignContent: Alignment.BottomStart }) {
        Column()
          .width('100%')
          .height('34%')
          .linearGradient({
            angle: 0,
            colors: [['#FA070B12', 0.0], ['#99070B12', 0.45], ['#00070B12', 1.0]]
          })
      }
      .width('100%')
      .height('100%')

      // 右侧：宽 45vp，向左渐隐（css to left → angle 270）
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column()
          .width(45)
          .height('100%')
          .linearGradient({
            angle: 270,
            colors: [['#EB070B12', 0.0], ['#00070B12', 1.0]]
          })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  /**
   * 页头 HUD：青点 + `SPACE GALLERY` + `/` + `N 张`，下方一条 120×2rpx 的青色渐变线。
   *
   * 必须写成**无参** @Builder 并直接读 this.total —— @Builder 按值传参不建立响应式依赖，
   * 传进来的字符串永远停在第一次渲染的值（本工程踩过「三格统计不刷新」）。
   */
  @Builder
  hud() {
    Column() {
      Row() {
        Row() {
          // 青点 10rpx：靠 shadow 做光晕，css 是 box-shadow 0 0 12rpx
          Row()
            .width(5)
            .height(5)
            .borderRadius(2.5)
            .backgroundColor(ACCENT)
            .shadow({ radius: 6, color: '#8038BDF8', offsetX: 0, offsetY: 0 })

          Text('SPACE GALLERY')
            .fontSize(10.5)
            .fontWeight(FontWeight.Bold)
            .fontColor(TXT_KICKER)
            .letterSpacing(2)
            .margin({ left: 6 })

          Text('/')
            .fontSize(9)
            .fontColor(TXT_SEP)
            .margin({ left: 6, right: 6 })

          Text(String(this.total) + ' 张')
            .fontSize(10)
            .fontColor(TXT_COUNT)
            .maxLines(1)
        }
        .alignItems(VerticalAlign.Center)

        Blank()

        // 「▶ 视频 ›」：有意保留的功能增量（小程序把视频库放在 gallery-all 第四个分段），
        // 放页头右侧比塞分段条更直接 —— 视频和图片是两种完全不同的浏览节奏。
        Row() {
          Text('▶')
            .fontSize(8.5)
            .fontColor(ACCENT)
          Text('视频')
            .fontSize(11)
            .fontColor(ACCENT)
            .margin({ left: 3 })
          Text('›')
            .fontSize(12.5)
            .fontColor(TXT_DIM)
            .margin({ left: 2 })
        }
        .alignItems(VerticalAlign.Center)
        .padding({ left: 9, right: 7, top: 4, bottom: 4 })
        .borderRadius(11)
        .backgroundColor('#1A2437')
        .onClick(() => {
          Nav.pushVideos('');
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 下划线：120×2rpx，左对齐在 kicker 起点（青点 5 + 间距 6）
      Row()
        .width(60)
        .height(1)
        .margin({ top: 5, left: 11 })
        .linearGradient({
          angle: 90,
          colors: [['#E638BDF8', 0.0], ['#0038BDF8', 1.0]]
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: HUD_PAD, right: HUD_PAD, top: HUD_TOP })
    // Transparent：自身与子节点都参与命中测试，但不阻塞兄弟节点 ——
    // 页头只是文字和「视频」胶囊，不需要吃掉整条顶部区域的点击
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 呼吸提示：.wall-tip 的 tipBreath 3.4s，明暗在 0.5 / 0.95 之间来回 */
  @Builder
  wallTip() {
    Column() {
      Text('点任意一张看详情')
        .fontSize(10.5)
        .fontColor('#99C8D6E8')
        .letterSpacing(0.5)
        .opacity(this.tipOn ? 0.95 : 0.5)
        // 补间交给 animation：两档来回翻，中间由框架插值
        .animation({ duration: TIP_BREATH_MS, curve: Curve.EaseInOut })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: TIP_BOTTOM })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 中央悬浮的「看全部 N ›」胶囊 */
  @Builder
  dock() {
    Column() {
      Row() {
        Text('看全部')
          .fontSize(12)
          .fontColor('#CFE6FF')
          .letterSpacing(0.5)
        Text(String(this.total))
          .fontSize(12.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(ACCENT)
          .margin({ left: 5 })
        Text('›')
          .fontSize(15)
          .fontColor(ACCENT)
          .margin({ left: 5 })
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 7.5, bottom: 7.5 })
      .borderRadius(999)
      // css 是 rgba(10,16,26,0.55) + backdrop blur；没有毛玻璃时 0.7 更实，
      // 否则压在亮图上数字读不出来（见文件头第 4 条）
      .backgroundColor('#B30A101A')
      .border({ width: 0.5, color: '#5738BDF8' })
      .shadow({ radius: 20, color: '#80000000', offsetX: 0, offsetY: 7 })
      .onClick(() => {
        this.enterListMode();
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: DOCK_BOTTOM })
    // 这层是铺满屏的定位壳，壳本身没有手势，只有里面的胶囊要能点。
    // HitTestMode.None 的语义正是「自身不参与命中测试、子节点照常响应」，
    // 等价于 css 的 `.dock{pointer-events:none}` + 胶囊自己 auto，且不阻塞下层图带。
    .hitTestBehavior(HitTestMode.None)
  }

  /** 清单模式的进度：静态，不呼吸（读进度时闪烁很烦） */
  @Builder
  listTip() {
    Column() {
      Text(this.listProgress())
        .fontSize(10.5)
        .fontColor('#99C8D6E8')
        .letterSpacing(0.5)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: TIP_BOTTOM })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 清单模式的回程胶囊（位置与「看全部」重合，眼睛不用重新找） */
  @Builder
  backDock() {
    Column() {
      Row() {
        Text('‹')
          .fontSize(15)
          .fontColor(ACCENT)
        Text('返回图墙')
          .fontSize(12)
          .fontColor('#CFE6FF')
          .letterSpacing(0.5)
          .margin({ left: 4 })
      }
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 7.5, bottom: 7.5 })
      .borderRadius(999)
      .backgroundColor('#B30A101A')
      .border({ width: 0.5, color: '#5738BDF8' })
      .shadow({ radius: 20, color: '#80000000', offsetX: 0, offsetY: 7 })
      .onClick(() => {
        this.exitListMode();
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: DOCK_BOTTOM })
    .hitTestBehavior(HitTestMode.None)
  }

  /** 加载中（对位 .loading + .hint-text） */
  @Builder
  loadingBox() {
    Column() {
      Text('加载中...')
        .fontSize(13)
        .fontColor('#6B7891')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None)
  }

  /** 空态（对位 .empty-box 的三行文案，一字不改） */
  @Builder
  emptyBox() {
    Column() {
      Text('🛰️')
        .fontSize(30)
        .margin({ bottom: 8 })

      Text('还没有图片')
        .fontSize(13)
        .fontColor('#8B95A8')

      Text('历史图片正在由后台逐批补齐，过几个小时再来看看')
        .fontSize(11)
        .fontColor('#4D5A6E')
        .lineHeight(17.6)
        .textAlign(TextAlign.Center)
        .margin({ top: 5 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 30, right: 30 })
    .hitTestBehavior(HitTestMode.None)
  }
}
