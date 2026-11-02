/**
 * view/ExpeditionView.ets —— 远征队详情页（对位小程序 pages/expedition/expedition.vue，333 行）
 *
 * ── 契约 ──
 *   @Component export struct ExpeditionView { @Prop expeditionId: string = ''; }
 *   三个回调由父级（路由容器）注入，本页不直接跳转：
 *     onOpenStation(id: string, name: string)
 *     onOpenPhoto(url: string, title: string)
 *     onOpenAstronaut(id: string, name: string)
 *
 * ── 数据来源 expeditions.json（2026-11-03 实测 v=14 / count=165）──
 *   id / name / start / end / stationId / stationName / patches[] / crew[]
 *   · end 为空串的 3 条 = 正在进行（页面据此出绿色「进行中」chip）
 *   · patches 是**任务徽章**（1:1 小图），118/165 非空
 *   · crew 每条 {id,name,role,agency,img}，img 实测多为空串 → 画 emoji 占位
 *
 * ── 为什么本文件自带 Exp* 类型、不建 model 文件 ──
 *   expeditions 目前只被这一页消费，为「用过一次」的结构单开 model 文件会让
 *   model/ 目录长成收容所。做法与 RocketDetailView 的 Rk* 一致；前缀 Exp 是为了
 *   避开 ArkTS 的声明合并（同名 interface 跨文件合并会静默改字段类型）。
 *
 * ── 有意差异（不是漏做）──
 *   1. 头部不铺大图：expeditions 没有 hero 字段，patches 是 1:1 徽章，
 *      拉成 200vp 通栏只会糊成一片色块，所以按任务书做成「纯文字卡 + 徽章横排」。
 *   2. 徽章 404 当场摘除：COS 上仍有失效链接，留一块 80×80 破图比少一个徽章难看。
 *   3. failed（网络挂）与 notFound（id 匹配不到）是两个独立状态，绝不合并 ——
 *      合并后用户看到「加载失败」，而真相是这个 id 根本不存在。
 *   4. 乘组名不做中文专名表：crew 里没有 nation 字段，utils/Format 的
 *      astroName(raw, nation) 第二档（中国籍专名表）用不上；硬猜国籍比显示原名更糟。
 *      因此这里保留原名，仅对空的 name 兜底「未知乘员」。
 *
 * 数据链路（与 AstronautView 同口径）：
 *   repo.peek<ExpPayload>('expeditions')  —— 同步、零网络，冷启动立刻上屏
 *   repo.load<ExpPayload>('expeditions', {onUpdate})  —— 后台刷新，onUpdate 回填
 *   .catch 里**只置 failed**，绝不置 found —— 否则弱网无缓存会变成「未找到」。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { BasePayload } from '../model/Common';
import { strOf, dayOf, expeditionName, stationName, astroName, agencyLabel } from '../utils/Format';
import { Nav } from '../routes/Nav';

const DOMAIN: number = 0x0000;
const TAG: string = 'ExpeditionView';

// ============ 视觉常量（工程约定） ============

const BG: string = '#0A0E17';
const CARD: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
/** 进行中用成功绿；已结束压成三级灰，不抢视线 */
const ACTIVE_GREEN: string = '#34C759';
const ENDED_GRAY: string = '#55617A';
/** 头像 / 徽章占位底色：比卡片再深一档，空图才不至于和卡片糊成一片 */
const PLACEHOLDER_BG: string = '#1B2330';

const CARD_RADIUS: number = 12;
const CARD_PAD: number = 14;
/** 区块间距 15vp（工程约定） */
const BLOCK_GAP: number = 15;
/** 页面左右内边距 12（与 TodayView / EventsView 对齐） */
const PAGE_PAD: number = 12;
/** 二级页底部留白统一 32，只够滑到底时最后一行不贴边 */
const BOTTOM_PAD: number = 32;

const PATCH_SIZE: number = 80;
const AVATAR_SIZE: number = 48;
/** 乘组头像占位：没有 img 时用 emoji，而不是再引一份图片资源 */
const CREW_AVATAR_EMOJI: string = '🧑‍🚀';

// ============ 类型（expeditions.json 实测结构） ============

/** 乘组一名成员。字段全部可选：上游对个别乘员的 img / agency 缺失很常见 */
export interface ExpCrew {
  id?: number;
  name?: string;
  /** 实测值：Commander / Flight Engineer / Mission Specialist / Pilot 等英文原文 */
  role?: string;
  /** 机构缩写，如 NASA / RFSA / ESA / JAXA */
  agency?: string;
  /** 头像 URL，实测多为空串 */
  img?: string;
}

/**
 * 一条远征队。
 *
 * id 是 number（实测 165 这种），路由入参是 string，比较时统一 String()；
 * end 是**空串**表示进行中（不是 null、不是缺失），所以判「进行中」看的是
 * dayOf(end).length === 0，而不是 end === undefined。
 */
export interface ExpItem {
  id?: number;
  /** 英文名，如 "Expedition 74" */
  name?: string;
  /** 开始时刻，ISO */
  start?: string;
  /** 结束时刻，ISO；空串 = 进行中 */
  end?: string;
  /** 空间站 id，0 / 缺失表示没有关联空间站 */
  stationId?: number;
  stationName?: string;
  /** 任务徽章图 URL 列表 */
  patches?: string[];
  crew?: ExpCrew[];
}

/** expeditions 载荷信封 */
export interface ExpPayload extends BasePayload {
  dataset?: string;
  count?: number;
  served?: number;
  list: ExpItem[];
}

// ============ 纯函数（放在组件外，避免每次重绘重建闭包） ============

/**
 * 乘组角色中文化。
 *
 * 只翻实测出现过的四个值，其余**原样保留**：编一个中文名会让懂行的人以为数据错了，
 * 而 "Spaceflight Participant" 这类角色本来就没有公认中文简称。
 */
function crewRoleZh(raw: string): string {
  const s: string = strOf(raw).trim();
  if (s.length === 0) {
    return '';
  }
  if (s === 'Commander') {
    return '指令长';
  }
  if (s === 'Flight Engineer') {
    return '飞行工程师';
  }
  if (s === 'Mission Specialist') {
    return '任务专家';
  }
  if (s === 'Pilot') {
    return '驾驶员';
  }
  return s;
}

/** 空片段用 · 连接：避免出现 " · NASA" 这种残缺分隔符 */
function joinParts(parts: string[]): string {
  return parts.join(' · ');
}

@Component
export struct ExpeditionView {
  /** 远征队 id（number 转字符串后传进来） */
  @Prop expeditionId: string = '';

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，不挡返回栏） */
  @State loading: boolean = true;
  /** 已经定位到这一条。**失败时绝不置 true** */
  @State found: boolean = false;
  /** 加载失败（无缓存 + 网络失败）。与「未找到」严格分开 */
  @State failed: boolean = false;

  /** 中文名（第 74 次远征）；英文名与之不同才单独显示 */
  @State expName: string = '';
  @State expNameEn: string = '';
  /** 已按 dayOf 截好的日期串，空串 = 缺失 / 进行中 */
  @State expStart: string = '';
  @State expEnd: string = '';
  @State expStationId: number = 0;
  @State expStationName: string = '';
  @State expPatches: string[] = [];
  @State expCrew: ExpCrew[] = [];

  /**
   * 徽章 / 头像加载失败表。
   *
   * 为什么用数组 + 整体替换而不是 Set：ArkTS 对 Set 的元素增删不保证触发 @State 重绘，
   * 而 `this.x = this.x.concat([v])` 换的是引用，一定重新渲染。
   */
  @State brokenPatches: string[] = [];
  @State brokenAvatars: number[] = [];

  /** 防重入：重试连点不应叠请求 */
  private loadingNow: boolean = false;

  // ============ 对外回调（普通成员，不加装饰器） ============

  onOpenStation: (id: string, name: string) => void = () => {};
  onOpenPhoto: (url: string, title: string) => void = () => {};
  onOpenAstronaut: (id: string, name: string) => void = () => {};

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadExpedition(false);
  }

  // ============ 加载 ============

  /**
   * 先 peek 再 load。
   *
   * force 只给「失败重试」用：绕过缓存直接回源，免得重试又命中那份坏缓存。
   */
  private loadExpedition(force: boolean): void {
    if (this.loadingNow) {
      return;
    }
    this.loadingNow = true;
    this.loading = true;
    this.failed = false;

    const cached: ExpPayload | null = repo.peek<ExpPayload>('expeditions');
    if (cached !== null) {
      this.applyPayload(cached);
      if (this.found) {
        // 缓存命中就收掉 loading，不等网络（后台刷新照常进行）
        this.loading = false;
      }
    }

    const opts: LoadOptions<ExpPayload> = {
      force: force,
      onUpdate: (fresh: ExpPayload) => {
        // 后台刷新只回填；这一版里找不到就保持现有画面，不把已渲染的页打回「未找到」
        this.applyPayload(fresh);
      }
    };

    repo.load<ExpPayload>('expeditions', opts)
      .then((data: ExpPayload) => {
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有内容就别喊失败，静默留在旧数据上（弱网体验优先）
        this.failed = !this.found;
        hilog.warn(DOMAIN, TAG, 'expeditions 加载失败: %{public}s', e.message);
      })
      .then(() => {
        this.loadingNow = false;
      });
  }

  /**
   * 数据落地：从载荷里找到这一条。
   *
   * list 声明成必填，但 JSON.parse 只是编译期断言、运行时不校验，
   * 所以仍按「可能 undefined」读一遍；只判 undefined 不判 null ——
   * 声明类型里没有 null，多写一个不等比较会被判成「两个类型无重叠」而报错。
   */
  private applyPayload(data: ExpPayload): void {
    const raw: ExpItem[] | undefined = data.list;
    const list: ExpItem[] = raw !== undefined ? raw : [];
    const hit: ExpItem | null = this.findIn(list);
    if (hit === null) {
      return;
    }
    this.applyExpedition(hit);
  }

  /** 按 id 定位。id 是 number、入参是 string，统一 String() 比较 */
  private findIn(list: ExpItem[]): ExpItem | null {
    const target: string = strOf(this.expeditionId).trim();
    if (target.length === 0) {
      return null;
    }
    for (let i = 0; i < list.length; i++) {
      const item: ExpItem = list[i];
      const idNum: number | undefined = item.id;
      if (idNum !== undefined && String(idNum) === target) {
        return item;
      }
    }
    return null;
  }

  /** 一条记录 → 页面状态。所有字段过一遍空值判定，不留 undefined 到 UI */
  private applyExpedition(e: ExpItem): void {
    const rawName: string = strOf(e.name).trim();
    const zh: string = expeditionName(rawName);
    this.expName = zh.length > 0 ? zh : '远征队';
    // 中文名没换字（例如上游给了个不叫 Expedition N 的名字）就别把同一行字再画一遍
    this.expNameEn = zh !== rawName ? rawName : '';

    this.expStart = dayOf(strOf(e.start));
    // 空串 end = 进行中；dayOf('') 也返回空串，两种情形天然同码
    this.expEnd = dayOf(strOf(e.end));

    const sid: number | undefined = e.stationId;
    this.expStationId = sid !== undefined ? sid : 0;
    this.expStationName = strOf(e.stationName).trim();

    const patches: string[] | undefined = e.patches;
    this.expPatches = patches !== undefined ? patches : [];
    const crew: ExpCrew[] | undefined = e.crew;
    this.expCrew = crew !== undefined ? crew : [];

    // 换一条记录时不继承上一条的破图标记
    this.brokenPatches = [];
    this.brokenAvatars = [];

    this.found = true;
  }

  // ============ 派生值 ============

  /** end 为空即进行中（数据层约定，不是靠日期跟 now 比出来） */
  private ongoing(): boolean {
    return this.expEnd.length === 0;
  }

  private statusText(): string {
    return this.ongoing() ? '进行中' : '已结束';
  }

  private statusBg(): string {
    return this.ongoing() ? ACTIVE_GREEN : ENDED_GRAY;
  }

  /** 绿底配深色字、灰底配白字（与 AstronautView 的在轨/退役同口径） */
  private statusFg(): string {
    return this.ongoing() ? BG : TEXT_MAIN;
  }

  /** 时间行：起始 → 结束 / 进行中 */
  private rangeText(): string {
    const head: string = this.expStart.length > 0 ? this.expStart : '时间待定';
    return head + ' → ' + (this.expEnd.length > 0 ? this.expEnd : '进行中');
  }

  /** 徽章列表（去掉加载失败的） */
  private patchList(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.expPatches.length; i++) {
      const url: string = strOf(this.expPatches[i]).trim();
      if (url.length > 0 && this.brokenPatches.indexOf(url) < 0) {
        out.push(url);
      }
    }
    return out;
  }

  private crewName(c: ExpCrew): string {
    const n: string = astroName(strOf(c.name), '').trim();
    return n.length > 0 ? n : '未知乘员';
  }

  /** 副行：角色中文 · 机构中文。任一段取不到就跳过，不留残缺分隔符 */
  private crewMeta(c: ExpCrew): string {
    const parts: string[] = [];
    const role: string = crewRoleZh(strOf(c.role));
    if (role.length > 0) {
      parts.push(role);
    }
    const agency: string = agencyLabel(strOf(c.agency)).trim();
    if (agency.length > 0) {
      parts.push(agency);
    }
    return joinParts(parts);
  }

  private avatarUrl(c: ExpCrew): string {
    return strOf(c.img).trim();
  }

  private avatarBroken(c: ExpCrew): boolean {
    const id: number | undefined = c.id;
    return id !== undefined && this.brokenAvatars.indexOf(id) >= 0;
  }

  private retry(): void {
    this.loadExpedition(true);
  }

  // ============ 交互 ============

  private openStation(): void {
    this.onOpenStation(String(this.expStationId), this.expStationName);
  }

  private openAstronaut(c: ExpCrew): void {
    const id: number | undefined = c.id;
    if (id === undefined) {
      // 没有 id 就进不去详情页（AstronautView 只会显示「未找到」），干脆不响应
      return;
    }
    this.onOpenAstronaut(String(id), strOf(c.name));
  }

  // ============ UI：顶栏（不滚动） ============

  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor(TEXT_SUB)
          .onClick(() => {
            Nav.pop();
          })
      }
      // 上下各 10vp 把热区撑到约 40vp，别让 15vp 的字直接当可点区域
      .padding({ right: 12, top: 10, bottom: 10 })

      Text(this.found ? this.expName : '远征队')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .alignItems(VerticalAlign.Center)
  }

  // ============ UI：头部块（纯文字，无大图） ============

  @Builder
  headCard() {
    Column() {
      Text(this.expName)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      if (this.expNameEn.length > 0) {
        Text(this.expNameEn)
          .fontSize(11.5)
          .fontColor(TEXT_SUB)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }

      Row() {
        Text(this.rangeText())
          .fontSize(12.5)
          .fontColor(TEXT_SUB)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.statusText())
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.statusFg())
          .backgroundColor(this.statusBg())
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 12 })

      // stationId 为 0 / 缺失 = 这条远征队没挂空间站（早期数据存在），整行不画
      if (this.expStationId !== 0) {
        Row() {
          Text('空间站')
            .fontSize(12)
            .fontColor(TEXT_DIM)

          Text(this.expStationName.length > 0 ? stationName(this.expStationName) : '—')
            .fontSize(13.5)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .margin({ left: 10 })

          Text('›')
            .fontSize(16)
            .fontColor(TEXT_DIM)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 11 })
        .margin({ top: 11 })
        .border({ width: { top: 1 }, color: '#1E2736' })
        .onClick(() => {
          this.openStation();
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD)
    .borderRadius(CARD_RADIUS)
  }

  // ============ UI：任务徽章卡 ============

  @Builder
  patchCard() {
    Column() {
      Text('任务徽章')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .width('100%')

      // Row 没有 flexWrap，折行必须用 Flex + FlexWrap.Wrap
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(this.patchList(), (url: string) => {
          Image(url)
            .width(PATCH_SIZE)
            .height(PATCH_SIZE)
            .objectFit(ImageFit.Contain)
            .backgroundColor(PLACEHOLDER_BG)
            .borderRadius(8)
            .margin({ right: 10, top: 10, bottom: 2 })
            .onError(() => {
              // 破图当场从列表里摘掉，不留 80×80 的空白方格
              this.brokenPatches = this.brokenPatches.concat([url]);
            })
            .onClick(() => {
              this.onOpenPhoto(url, '任务徽章');
            })
        }, (url: string) => url)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD)
    .borderRadius(CARD_RADIUS)
    .margin({ top: BLOCK_GAP })
  }

  // ============ UI：乘组卡 ============

  @Builder
  crewRow(c: ExpCrew) {
    Row() {
      if (this.avatarUrl(c).length > 0 && !this.avatarBroken(c)) {
        Image(this.avatarUrl(c))
          .width(AVATAR_SIZE)
          .height(AVATAR_SIZE)
          .borderRadius(AVATAR_SIZE / 2)
          .objectFit(ImageFit.Cover)
          .backgroundColor(PLACEHOLDER_BG)
          .onError(() => {
            const id: number | undefined = c.id;
            if (id !== undefined) {
              this.brokenAvatars = this.brokenAvatars.concat([id]);
            }
          })
      } else {
        Column() {
          Text(CREW_AVATAR_EMOJI)
            .fontSize(22)
        }
        .width(AVATAR_SIZE)
        .height(AVATAR_SIZE)
        .borderRadius(AVATAR_SIZE / 2)
        .backgroundColor(PLACEHOLDER_BG)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      Column() {
        Text(this.crewName(c))
          .fontSize(15)
          .fontColor(TEXT_MAIN)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.crewMeta(c).length > 0) {
          Text(this.crewMeta(c))
            .fontSize(11.5)
            .fontColor(TEXT_SUB)
            .width('100%')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 12 })

      Text('›')
        .fontSize(16)
        .fontColor(TEXT_DIM)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 9, bottom: 9 })
    .onClick(() => {
      this.openAstronaut(c);
    })
  }

  @Builder
  crewCard() {
    Column() {
      Text('乘组（' + this.expCrew.length + ' 人）')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .width('100%')
        .margin({ bottom: 4 })

      if (this.expCrew.length === 0) {
        // 有乘组字段但为空：这是数据缺，不是「没人」—— 直说，别留一片空白
        Text('暂无乘组信息')
          .fontSize(12)
          .fontColor(TEXT_DIM)
          .width('100%')
          .margin({ top: 8 })
      } else {
        ForEach(this.expCrew, (c: ExpCrew) => {
          this.crewRow(c)
        }, (c: ExpCrew) => String(c.id !== undefined ? c.id : c.name))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD)
    .borderRadius(CARD_RADIUS)
    .margin({ top: BLOCK_GAP })
  }

  // ============ UI：页脚 ============

  @Builder
  footerHint() {
    Text('数据来源 The Space Devs')
      .fontSize(11)
      .fontColor(TEXT_DIM)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ top: 18 })
  }

  // ============ UI：三态 ============

  @Builder
  loadingBlock() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(ACCENT)
      Text('正在加载远征队…')
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
      Text('远征队数据加载失败')
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
  notFoundBlock() {
    Column() {
      Text('未找到该远征队')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      Text('可能是链接已过期，或数据正在更新')
        .fontSize(12)
        .fontColor(TEXT_DIM)
        .textAlign(TextAlign.Center)
        .margin({ top: 8 })

      Row() {
        Text('‹ 返回')
          .fontSize(12.5)
          .fontColor(TEXT_SUB)
      }
      .padding({ left: 16, right: 16, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(CARD)
      .margin({ top: 12 })
      .onClick(() => {
        Nav.pop();
      })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  // ============ build ============

  build() {
    Column() {
      this.topBar()

      if (this.loading && !this.found) {
        this.loadingBlock()
      } else if (this.failed && !this.found) {
        this.failedBlock()
      } else if (!this.found) {
        this.notFoundBlock()
      } else {
        Scroll() {
          Column() {
            this.headCard()

            if (this.patchList().length > 0) {
              this.patchCard()
            }

            this.crewCard()
            this.footerHint()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
  }
}
