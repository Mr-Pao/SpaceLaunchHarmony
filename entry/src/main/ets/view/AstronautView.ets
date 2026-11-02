/**
 * view/AstronautView.ets —— 航天员详情页（对位小程序 pages/astronaut/astronaut.vue）
 *
 * 本文件由路由方（DetailPages.ets）以 `<AstronautView param>` 形式挂进 NavDestination，
 * 入参只有 id（string，调用方负责 toString）。返回走 Nav.pop()，与 RocketDetailView 同口径。
 *
 * ── 数据链路：先 peek 再 load ──
 *   repo.peek<AstronautsPayload>('astronauts')  同步、只查内存+文件，零网络
 *   repo.load<AstronautsPayload>('astronauts', { onUpdate })
 *     onUpdate 只在「缓存过期 + 后台刷新拿到新数据」时才回调，用来静默回填
 *
 *   astronauts.json 是 862 条 / 约 700KB 的大集合，进这一页**不该**再拉一遍全量：
 *   只要缓存里有，peek 就能立刻上屏；缓存为空时才真正走一次网络（冷启动首进）。
 *
 * ── 为什么 found / failed 必须分开（原项目踩过的永久空页坑）──
 *   repo.load 在「无缓存 + 网络失败」时是 **reject**，不是返回 null。
 *   老的 utils/data.js 写法在 catch 里顺手把 loaded 置 true，页面就永久停在
 *   「查无此人」——网络抖一下等于把这个人从库里删了。所以这里：
 *     loading && !found          → 加载中
 *     failed  && !found          → 加载失败 + 「加载失败，点此重试」
 *     !failed && !found && 已结束 → 真的没这条记录
 *     found                      → 正常内容（此时刷新失败也继续显示旧数据）
 *
 * ── 字段口径（已逐条核对 model/Astronaut.ets，不猜）──
 *   Astronaut         : id name status? inSpace days? evaHours? age? flights?
 *                       spacewalks? nation? agencyName? img? credit? bio? bioZh?
 *                       dob? dod? wiki? twitter? instagram? missions? evas?
 *   AstronautMission  : id(string, LL2 发射 UUID) net st? name? rk? dest?
 *                       → **没有 role 字段**，第二行用 rk · 日期 · 目的地 代替
 *   AstronautEva      : name? start? h? loc?
 *
 * ── 其它取舍 ──
 *   1. 姓名走 astroName(name, nation)：中国籍查 CHINA_ASTRO_ZH 专名表，
 *      查不到保留拼音 —— 编一个错名字比显示拼音更糟。
 *   2. 简介用 descText(bioZh, bio)（中文优先），超过 120 字才给展开按钮。
 *      bio 只有「在轨人员」才有（CI 侧裁剪过），历史航天员靠任务列表撑内容。
 *   3. 数字格 0 与 undefined 一律显示 —：0 天/0 小时在这份数据里通常表示
 *      「没统计到」，画成 0 会被读成「飞了 0 天」。
 *   4. missions / evas 空数组在 slim 里**不落字段**，所以全部按 undefined 兜。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。不使用 AppStorage。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { repo, LoadOptions } from '../data/Repository';
import { Astronaut, AstronautMission, AstronautEva, AstronautsPayload } from '../model/Astronaut';
import {
  strOf, astroName, nationZh, agencyLabel, flagOf, destName, dayOf, descText, descNeedFold
} from '../utils/Format';
import { Nav } from '../routes/Nav';
import { LaunchNavParam } from '../routes/NavParam';

const DOMAIN: number = 0x0000;
const TAG: string = 'AstronautView';

// ============ 视觉常量（工程约定） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const CARD_RADIUS: number = 12;
const CARD_PAD: number = 14;
const CARD_GAP: number = 10;

const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
/** 在轨用成功绿；其余状态（现役/退役/已故）统一压成中性灰，不抢视线 */
const ACTIVE_GREEN: string = '#34C759';
const RETIRED_GRAY: string = '#55617A';
/** 分隔线：比卡片亮一点点，够看出分栏又不抢视线 */
const DIVIDER: string = '#1E2736';

/** Hero 高度（任务书 240vp） */
const HERO_H: number = 240;
/** 页面左右内边距（与 TodayView / RocketDetailView 的 12 对齐） */
const PAGE_PAD: number = 12;
/**
 * 底部 120：任务书明确要求（底部悬浮胶囊让位）。
 * 本页虽由详情栈推入、胶囊此时已被 Index 摘掉，但留 120 是保险值 ——
 * 万一将来从 tab 内直接嵌进来，内容不会被胶囊盖住最后一格。
 */
// 底部留白：本页是 NavDestination 二级页，胶囊在详情页打开时已被摘掉，
// 不需要按 tab 根页那样让位 92~120，32 只够滑到底时最后一行不贴边。
const BOTTOM_PAD: number = 32;

/** 简介折叠行数（任务书 6 行） */
const BIO_FOLD_LINES: number = 6;
/** 超过这个字符数才显示「展开」：6 行 × 约 20 汉字 ≈ 120 */
const BIO_FOLD_MIN: number = 120;
/** 出舱记录最多显示条数（slim 侧本来也只留 8 条） */
const EVA_MAX: number = 8;

/** 无头像时的占位 */
const AVATAR_PLACEHOLDER: string = '👨‍🚀';

// ============ 纯函数（放在 @Component 外面，避免每次重绘重建闭包） ============

/**
 * 状态中文化。LL2 只有 5 种值，写死 if 链比 Map 更省事，
 * 也避开「不能 new Record」的限制。
 */
function astroStatusZh(status: string): string {
  const s: string = strOf(status).trim();
  if (s === 'Active') {
    return '现役';
  }
  if (s === 'Retired') {
    return '退役';
  }
  if (s === 'Deceased') {
    return '已故';
  }
  if (s === 'In space') {
    return '在轨';
  }
  if (s === 'Unknown') {
    return '未知';
  }
  return s;
}

/**
 * 数字格取值：undefined / 0 一律给 —。
 *
 * 为什么把 0 也当空：days / evaHours / flights 在 LL2 里对「没统计到」和
 * 「真的 0」不作区分，画成 0 会被读成「飞了 0 次」，比 — 更误导。
 */
function numCell(v: number | undefined): string {
  if (v === undefined) {
    return '—';
  }
  if (v <= 0) {
    return '—';
  }
  return String(v);
}

/** 把非空片段用 · 连起来，空串不占位置（避免出现 " ·  · ISS" 这种残缺分隔） */
function joinParts(parts: string[]): string {
  return parts.join(' · ');
}

@Component
export struct AstronautView {
  /** 航天员 id。注意是 string —— 入参由路由那边 toString 后传进来 */
  @Prop astronautId: string = '';

  // ============ 页面状态 ============

  /** 正在等数据（只挡内容区，不挡返回栏） */
  @State loading: boolean = true;
  /** 是否拿到了这条记录 */
  @State found: boolean = false;
  /** 加载失败（无缓存 + 网络失败）。与「未找到」严格分开，见文件头说明 */
  @State failed: boolean = false;

  /** 展示名（中文名优先） */
  @State astName: string = '';
  /** 状态中文（现役 / 退役 / 已故 …） */
  @State astStatus: string = '';
  /** 此刻是否在轨 */
  @State astInSpace: boolean = false;
  /** 国籍中文 */
  @State astNation: string = '';
  /** 国旗 emoji（flagOf 返回 emoji，不是图片路径） */
  @State astFlag: string = '';
  /** 机构短名 */
  @State astAgency: string = '';
  /** 头像地址 */
  @State avatarUrl: string = '';
  /** 头像加载失败 → 退回 emoji 占位，避免破图 */
  @State avatarErr: boolean = false;

  /** 概览三格（已格式化，— 表示无值） */
  @State daysText: string = '—';
  @State evaHoursText: string = '—';
  @State flightsText: string = '—';
  /** 出舱次数（空串 = 没有统计） */
  @State walkText: string = '';

  /** 简介正文（bioZh || bio） */
  @State bioText: string = '';
  /** 简介是否已展开 */
  @State bioExpanded: boolean = false;

  /** 飞行任务（原样保留 model 结构，渲染时再取字段） */
  @State missionList: AstronautMission[] = [];
  /** 出舱记录（已裁到最多 8 条） */
  @State evaList: AstronautEva[] = [];
  /** 出舱总次数（spacewalks 优先，缺失时退 evas.length） */
  @State evaTotal: number = 0;

  // ============ 生命周期 ============

  aboutToAppear(): void {
    this.loadAstronaut(false);
    // 无定时器、无监听、无长连接，aboutToDisappear 无事可做，故不实现
  }

  // ============ 加载 ============

  /**
   * 先 peek 再 load。
   *
   * peek 是同步的（内存 + 文件），冷启动能立刻把详情画出来；
   * 找不到（或压根没缓存）才等 load。
   * force=true 只给「失败重试」用：绕过缓存直接回源，避免重试还命中那份坏缓存。
   */
  private loadAstronaut(force: boolean): void {
    this.loading = true;
    this.failed = false;

    const cached: AstronautsPayload | null = repo.peek<AstronautsPayload>('astronauts');
    if (cached !== null) {
      const hit: Astronaut | null = this.findAstronaut(cached);
      if (hit !== null) {
        this.applyAstronaut(hit);
        // 缓存就命中 → 立刻收掉 loading，不等网络（后台刷新照常进行）
        this.loading = false;
      }
    }

    const opts: LoadOptions<AstronautsPayload> = {
      force: force,
      onUpdate: (fresh: AstronautsPayload) => {
        // 后台刷新只做回填；找不到就保持现有画面，不把已渲染的页打回「未找到」
        this.applyPayload(fresh);
      }
    };

    repo.load<AstronautsPayload>('astronauts', opts)
      .then((data: AstronautsPayload) => {
        // 命中缓存时 resolve 的就是缓存值，重复落地一次无害（幂等）
        this.applyPayload(data);
        this.loading = false;
        this.failed = false;
      })
      .catch((e: BusinessError) => {
        this.loading = false;
        // 已经有内容就别说「失败」，静默留在旧数据上（弱网体验优先）
        this.failed = !this.found;
        hilog.warn(DOMAIN, TAG, 'astronauts 加载失败: %{public}s', e.message);
      });
  }

  /**
   * 取载荷里的 list。
   *
   * 为什么不直接写 `data.list !== undefined ? data.list : []`：
   * AstronautsPayload.list 在 model 里是**必填**的 `Astronaut[]`，
   * 拿必填类型和 undefined 做比较会被 ArkTS/TS 判成「两个类型无重叠」而报错。
   * 这里先赋给一个显式可空的局部变量，既绕开类型层面，又保住运行时兜底
   * （旧缓存里 list 真有可能缺）。
   */
  private listOf(data: AstronautsPayload): Astronaut[] {
    const maybe: Astronaut[] | undefined = data.list;
    return maybe !== undefined ? maybe : [];
  }

  /** 数据落地：从载荷里找到这一条 → 拆到各个 @State */
  private applyPayload(data: AstronautsPayload): void {
    const hit: Astronaut | null = this.findAstronautIn(this.listOf(data));
    if (hit === null) {
      // 已找到过就保持原样：中途一次半截数据不该把整页清空
      return;
    }
    this.applyAstronaut(hit);
  }

  private findAstronaut(data: AstronautsPayload): Astronaut | null {
    return this.findAstronautIn(this.listOf(data));
  }

  /**
   * 按 id 定位。id 在 model 里是 number，入参是 string，统一 String() 比较。
   * 返回 null 表示「这一版载荷里没有他」，由调用方决定是等下一轮还是判未找到。
   */
  private findAstronautIn(list: Astronaut[]): Astronaut | null {
    const target: string = strOf(this.astronautId).trim();
    if (target.length === 0) {
      return null;
    }
    for (let i = 0; i < list.length; i++) {
      const item: Astronaut = list[i];
      // item.id 在 model 里是必填 number，所以不做 undefined 判定
      // （number 与 undefined 做 === 比较会被判成「两个类型无重叠」而报错）
      if (item !== null && item !== undefined && String(item.id) === target) {
        return item;
      }
    }
    return null;
  }

  /** 一条记录 → 页面状态。所有字段都过一遍空值判定，不留 undefined 到 UI */
  private applyAstronaut(a: Astronaut): void {
    const zhName: string = astroName(a.name, strOf(a.nation)).trim();
    this.astName = zhName.length > 0 ? zhName : strOf(a.name).trim();
    this.astStatus = astroStatusZh(strOf(a.status));
    this.astInSpace = a.inSpace === true;
    this.astNation = nationZh(strOf(a.nation));
    this.astFlag = flagOf(strOf(a.nation));
    this.astAgency = agencyLabel(strOf(a.agencyName));

    this.avatarUrl = strOf(a.img).trim();
    // 换人时不继承上一条的破图标记
    this.avatarErr = false;

    this.daysText = numCell(a.days);
    this.evaHoursText = numCell(a.evaHours);
    this.flightsText = numCell(a.flights);

    // 先落局部变量再判空：ArkTS 对「可选属性」的收窄在长表达式里不可靠，
    // 直接写 a.spacewalks > 0 可能被判成 number | undefined 参与比较
    const walks: number | undefined = a.spacewalks;
    this.walkText = walks !== undefined && walks > 0 ? String(walks) : '';

    this.bioText = descText(strOf(a.bioZh), strOf(a.bio)).trim();
    this.bioExpanded = false;

    const missions: AstronautMission[] = a.missions !== undefined ? a.missions : [];
    this.missionList = missions;

    const evas: AstronautEva[] = a.evas !== undefined ? a.evas : [];
    this.evaList = evas.length > EVA_MAX ? evas.slice(0, EVA_MAX) : evas;
    // 统计口径优先用 spacewalks（含没有逐条日志的旧任务）；缺失时退列表长度
    this.evaTotal = walks !== undefined && walks > 0 ? walks : evas.length;

    this.found = true;
  }

  // ============ 交互 ============

  private retry(): void {
    this.loadAstronaut(true);
  }

  /**
   * 点飞行任务 → 发射详情。
   * model 里 AstronautMission.id 就是 LL2 发射 UUID，有才跳；没有就整行不响应
   * （旧数据/归档缺失时点击跳过去也只会看到「未找到」）。
   */
  private openMission(m: AstronautMission): void {
    const id: string = strOf(m.id).trim();
    if (id.length === 0) {
      return;
    }
    Nav.pushLaunch(new LaunchNavParam(id, strOf(m.net), this.missionName(m)));
  }

  // ============ 派生文案 ============

  private headerTitle(): string {
    return this.astName.length > 0 ? this.astName : '航天员';
  }

  /** 徽章文案：在轨优先，其次状态；都没有就不画徽章 */
  private badgeText(): string {
    if (this.astInSpace) {
      return '在轨';
    }
    return this.astStatus;
  }

  private badgeBgColor(): string {
    return this.astInSpace ? ACTIVE_GREEN : RETIRED_GRAY;
  }

  /** 绿底配深色字，灰底配白字 —— 与 RocketDetailView 的现役/退役同口径 */
  private badgeTextColor(): string {
    return this.astInSpace ? BG_PRIMARY : TEXT_MAIN;
  }

  private bioLines(): number {
    // 展开时给一个大而有效的行数（不用 Infinity，避免布局测量异常）
    return this.bioExpanded ? 400 : BIO_FOLD_LINES;
  }

  private canExpandBio(): boolean {
    return descNeedFold(this.bioText, BIO_FOLD_MIN);
  }

  /** 任务主标题：name（CI 已从 "火箭 | 任务" 里拆好）→ 火箭名 → 兜底 */
  private missionName(m: AstronautMission): string {
    const n: string = strOf(m.name).trim();
    if (n.length > 0) {
      return n;
    }
    const rk: string = strOf(m.rk).trim();
    return rk.length > 0 ? rk : '未命名任务';
  }

  /** 任务副行：火箭 · 日期 · 目的地。空片段自动跳过，不留残缺分隔符 */
  private missionSub(m: AstronautMission): string {
    const parts: string[] = [];
    const rk: string = strOf(m.rk).trim();
    if (rk.length > 0) {
      parts.push(rk);
    }
    const day: string = dayOf(strOf(m.net));
    if (day.length > 0) {
      parts.push(day);
    }
    if (strOf(m.dest).trim().length > 0) {
      const dest: string = destName(strOf(m.dest)).trim();
      if (dest.length > 0) {
        parts.push(dest);
      }
    }
    return joinParts(parts);
  }

  private evaName(e: AstronautEva): string {
    const n: string = strOf(e.name).trim();
    return n.length > 0 ? n : '出舱活动';
  }

  private evaSub(e: AstronautEva): string {
    const parts: string[] = [];
    const day: string = dayOf(strOf(e.start));
    if (day.length > 0) {
      parts.push(day);
    }
    const loc: string = strOf(e.loc).trim();
    if (loc.length > 0) {
      parts.push(loc);
    }
    return joinParts(parts);
  }

  private evaHoursTextOf(e: AstronautEva): string {
    // 先落局部变量再判：ArkTS 对可选属性的类型收窄不可靠，
    // 直接写 e.h > 0 可能被判成 number | undefined 与 number 比较
    const h: number | undefined = e.h;
    if (h === undefined || h <= 0) {
      return '';
    }
    return String(h) + ' 小时';
  }

  // ============ UI：页头（不滚动） ============

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

      Text(this.headerTitle())
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: 4 })
    }
    .width('100%')
    .height(48)
    .alignItems(VerticalAlign.Center)
  }

  // ============ UI：Hero ============

  @Builder
  hero() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 1 头像大图 / emoji 占位
      if (this.avatarUrl.length > 0 && !this.avatarErr) {
        Image(this.avatarUrl)
          .width('100%')
          .height(HERO_H)
          .objectFit(ImageFit.Cover)
          .backgroundColor(CARD_BG)
          .onError(() => {
            // 破图退回占位，比留一块 240vp 的空白好
            this.avatarErr = true;
          })
      } else {
        Column() {
          Text(AVATAR_PLACEHOLDER)
            .fontSize(40)
        }
        .width('100%')
        .height(HERO_H)
        .backgroundColor(CARD_BG)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      // 2 底部压黑层：白色姓名压在任意亮度的照片上都要可读（angle 0 = 从下往上）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 0,
          colors: [
            ['#D90A0E17', 0.0],
            ['#000A0E17', 0.72]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      // 3 姓名 + 徽章 / 国籍 / 机构，三行压在图底
      Column() {
        Row() {
          Text(this.astName)
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (this.badgeText().length > 0) {
            Text(this.badgeText())
              .fontSize(10.5)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.badgeTextColor())
              .backgroundColor(this.badgeBgColor())
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(6)
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)

        if (this.astNation.length > 0) {
          Row() {
            if (this.astFlag.length > 0) {
              Text(this.astFlag)
                .fontSize(12)
                .margin({ right: 4 })
            }
            Text(this.astNation)
              .fontSize(12.5)
              .fontColor(TEXT_SUB)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(VerticalAlign.Center)
          .margin({ top: 6 })
        }

        if (this.astAgency.length > 0) {
          Text(this.astAgency)
            .fontSize(11.5)
            .fontColor(TEXT_SUB)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({ left: CARD_PAD, right: CARD_PAD, bottom: 14 })
    }
    .width('100%')
    .height(HERO_H)
    .borderRadius(CARD_RADIUS)
    // 圆角裁切用 clip，不用 overflow（Attribute 上没有 overflow）
    .clip(true)
  }

  // ============ UI：概览三格 ============

  @Builder
  statCell(value: string, label: string) {
    Column() {
      Text(value)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        // — 用三级灰，别让「没有数据」看起来像「数据是 0」
        .fontColor(value === '—' ? TEXT_DIM : TEXT_MAIN)
      Text(label)
        .fontSize(11)
        .fontColor(TEXT_DIM)
        .margin({ top: 3 })
        .maxLines(1)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  overviewCard() {
    Row() {
      this.statCell(this.daysText, '累计在轨（天）')
      this.statCell(this.evaHoursText, '出舱小时')
      this.statCell(this.flightsText, '飞行次数')
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: CARD_PAD, bottom: CARD_PAD })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：出舱统计 ============

  @Builder
  evaStatCard() {
    Row() {
      Text('出舱统计')
        .fontSize(13)
        .fontColor(TEXT_SUB)
      Blank()
      Text(this.walkText.length > 0 ? this.walkText + ' 次' : '— 次')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.walkText.length > 0 ? TEXT_MAIN : TEXT_DIM)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：简介 ============

  @Builder
  bioCard() {
    Column() {
      Text('简介')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      Text(this.bioText)
        .fontSize(13)
        .fontColor(TEXT_SUB)
        .lineHeight(21)
        .maxLines(this.bioLines())
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 8 })

      if (this.canExpandBio()) {
        Row() {
          Text(this.bioExpanded ? '收起' : '展开全文')
            .fontSize(12)
            .fontColor(ACCENT)
          Text(this.bioExpanded ? '⌃' : '⌄')
            .fontSize(11)
            .fontColor(ACCENT)
            .margin({ left: 3 })
        }
        .alignItems(VerticalAlign.Center)
        .padding({ top: 8, bottom: 2 })
        .onClick(() => {
          this.bioExpanded = !this.bioExpanded;
        })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：飞行任务 ============

  @Builder
  missionCard() {
    Column() {
      Text('飞行任务')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)

      ForEach(this.missionList, (m: AstronautMission, i: number) => {
        // 单根 Column：分隔线挂在行内，避免 ForEach 生成多个根节点
        Column() {
          if (i > 0) {
            Divider()
              .color(DIVIDER)
              .strokeWidth(1)
              .margin({ top: 8, bottom: 8 })
          }

          Row() {
            Column() {
              Text(this.missionName(m))
                .fontSize(13.5)
                .fontColor(TEXT_MAIN)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
              if (this.missionSub(m).length > 0) {
                Text(this.missionSub(m))
                  .fontSize(11)
                  .fontColor(TEXT_DIM)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 3 })
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // 有 LL2 发射 UUID 才给箭头，避免点了没反应
            if (strOf(m.id).trim().length > 0) {
              Text('›')
                .fontSize(16)
                .fontColor(TEXT_DIM)
                .margin({ left: 8 })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ top: i > 0 ? 0 : 8, bottom: 2 })
          .onClick(() => {
            this.openMission(m);
          })
        }
        .width('100%')
      }, (m: AstronautMission, i: number) => strOf(m.id) + '@' + strOf(m.net) + '#' + String(i))
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：出舱活动列表 ============

  @Builder
  evaCard() {
    Column() {
      Row() {
        Text('出舱活动')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(TEXT_MAIN)
        Blank()
        // 总次数始终给出来：日志被裁到 8 条时，这里才是「共几次」的权威口径
        if (this.evaTotal > 0) {
          Text('共 ' + String(this.evaTotal) + ' 次')
            .fontSize(11.5)
            .fontColor(TEXT_DIM)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.evaList.length === 0) {
        Text('暂无逐条出舱记录')
          .fontSize(12)
          .fontColor(TEXT_DIM)
          .margin({ top: 10 })
      } else {
        ForEach(this.evaList, (e: AstronautEva, i: number) => {
          Column() {
            if (i > 0) {
              Divider()
                .color(DIVIDER)
                .strokeWidth(1)
                .margin({ top: 8, bottom: 8 })
            }

            Row() {
              // 小圆点：比序号轻，纯装饰不参与阅读
              Column()
                .width(6)
                .height(6)
                .borderRadius(3)
                .backgroundColor(ACCENT)
                .margin({ top: 6, right: 8 })

              Column() {
                Text(this.evaName(e))
                  .fontSize(13)
                  .fontColor(TEXT_MAIN)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                if (this.evaSub(e).length > 0) {
                  Text(this.evaSub(e))
                    .fontSize(11)
                    .fontColor(TEXT_DIM)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .margin({ top: 3 })
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              if (this.evaHoursTextOf(e).length > 0) {
                Text(this.evaHoursTextOf(e))
                  .fontSize(12)
                  .fontColor(TEXT_SUB)
                  .margin({ left: 8 })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: i > 0 ? 0 : 8, bottom: 2 })
          }
          .width('100%')
        }, (e: AstronautEva, i: number) => strOf(e.name) + '@' + strOf(e.start) + '#' + String(i))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(CARD_PAD)
    .backgroundColor(CARD_BG)
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  // ============ UI：三态占位 ============

  @Builder
  stateBlock(title: string, hint: string, showRetry: boolean) {
    Column() {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
      if (hint.length > 0) {
        Text(hint)
          .fontSize(12)
          .fontColor(TEXT_DIM)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
      if (showRetry) {
        Row() {
          Text('加载失败，点此重试')
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
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  // ============ build ============

  build() {
    // 根容器统一留 12 侧距 + 120 底距（见文件头常量注释）；页头也在这条内边距里，
    // 因此 Hero 与卡片左右边缘天然对齐，不需要各自再设 margin
    Column() {
      this.topBar()

      if (this.loading && !this.found) {
        this.stateBlock('加载中…', '正在读取航天员档案', false)
      } else if (this.failed && !this.found) {
        this.stateBlock('加载失败', '网络不给力，或缓存已被清理', true)
      } else if (!this.found) {
        this.stateBlock('未找到该航天员', '可能是链接已过期，或数据正在更新', false)
      } else {
        Scroll() {
          Column() {
            this.hero()

            Column() {
              this.overviewCard()

              // 出舱统计：spacewalks 有值，或至少有逐条日志时才画这张卡
              if (this.walkText.length > 0 || this.evaTotal > 0) {
                this.evaStatCard()
              }
              if (this.bioText.length > 0) {
                this.bioCard()
              }
              if (this.missionList.length > 0) {
                this.missionCard()
              }
              if (this.evaTotal > 0 || this.evaList.length > 0) {
                this.evaCard()
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
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
    .backgroundColor(BG_PRIMARY)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
  }
}
