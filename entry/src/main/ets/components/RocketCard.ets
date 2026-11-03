/**
 * components/RocketCard.ets —— 「全球火箭实力榜」排名卡 + launchers 数据集形状
 *
 * 对位小程序：pages/rockets/rockets.vue 的 rank-card 模板 + getData() 里的派生字段计算。
 * 视觉数值全部按 rockets.vue 的 wxss 取（rpx ÷ 2 = vp），逐条对位处标了原值。
 *
 * ── 为什么派生字段在这里一次算好 ──
 *   榜单要排序就得有 score / rateAdj；卡片要显示就得有 leoText / rateText / maker / flag。
 *   如果放到卡片里算，14 张卡片每次重建都会重跑一遍字符串拼接与翻译查表，
 *   而排序所需的分母（maxLaunch / maxLeo / 全局成功率 p0）是**全局量**，卡片自己拿不到。
 *   所以：原始 JSON → RtRocket（带全部派生字段）只在数据落地时跑一次。
 *
 * ── 为什么打分要先收缩成功率 ──
 *   只打过 2 发且全成功的型号真实成功率 100%，直接进综合分会顶掉 Falcon 9。
 *   rateAdj 给每个型号先垫 RATE_PRIOR 次「全局平均表现」，样本越少越被拉向均值；
 *   卡片显示的仍是未收缩的 rate，两个口径各司其职。
 *
 * ── 为什么类型全部带 Rt 前缀 ──
 *   ArkTS 禁止声明合并：view/RocketDetailView.ets 已经导出了 RkLauncher / RkLaunchersPayload，
 *   同名再声明一次会直接编译失败。Rt 前缀是本页独占命名空间。
 *
 * ⚠ 本文件不打日志（纯数据 + 展示）。
 */

import { agencyLabel, flagOf, rocketFullName, strOf } from '../utils/Format';
import { RocketConfig } from '../model/Common';

/** .m-v / 名称那一档 */
const TXT_MAIN: string = '#F0F5FC';
/** .rank-en 那一档 */
const TXT_EN: string = '#7D8BA0';
/** .rank-maker */
const TXT_MAKER: string = '#8FA0B6';
/** .m-k / .rank-no 的字色 */
const TXT_MUTE: string = '#5D6A7E';
const ACCENT_LIGHT: string = '#7DD3FC';

/**
 * 图区尺寸：对位 .rank-media 的 228rpx × 216rpx。
 * 原来是 88×88 正方形 —— 那是按「图标」想的；小程序这里其实是条 4:3.8 的
 * 横图位（火箭照片多是竖构图，稍高的框能少切掉箭体）。
 */
const MEDIA_W: number = 114;
const MEDIA_H: number = 108;

/** 每个型号打分前先垫 10 次「平均表现」的虚拟发射 */
const RATE_PRIOR: number = 10;

// ============ 数据集形状 ============

/**
 * launchers.json 单条。字段清单按 2026-11-02 线上快照（36 键）写全，
 * 全部可选：上游对不同型号的缺字段非常普遍，缺字段是常态不是异常。
 */
export interface RtLauncherRaw {
  /** LL2 的 id 是数字，别照 string 读 */
  id?: number | null;
  name?: string;
  full_name?: string;
  variant?: string;
  families?: string[];
  manufacturer?: string;
  /** 米 */
  length?: number | null;
  /** 米 */
  diameter?: number | null;
  /** 吨 */
  launch_mass?: number | null;
  /** 千牛 */
  to_thrust?: number | null;
  /** kg */
  leo_capacity?: number | null;
  /** kg */
  gto_capacity?: number | null;
  /** kg */
  geo_capacity?: number | null;
  /** kg */
  sso_capacity?: number | null;
  /** "2014-07-09" */
  maiden_flight?: string;
  min_stage?: number | null;
  max_stage?: number | null;
  /** 美元 */
  launch_cost?: number | null;
  reusable?: boolean;
  active?: boolean;
  total_launch_count?: number | null;
  successful_launches?: number | null;
  failed_launches?: number | null;
  pending_launches?: number | null;
  consecutive_successful_launches?: number | null;
  attempted_landings?: number | null;
  successful_landings?: number | null;
  failed_landings?: number | null;
  consecutive_successful_landings?: number | null;
  fastest_turnaround?: number | null;
  description?: string;
  descriptionZh?: string;
  /** 已镜像的 COS 地址，无图为空串 / null */
  image?: string | null;
  info_url?: string;
  wiki_url?: string;
  pads?: Object[];
}

/** launchers 数据集信封 */
export interface RtLauncherList {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  count?: number;
  served?: number;
  list?: RtLauncherRaw[];
}

/**
 * 榜单视图模型。
 *
 * 实现 RocketConfig 不是为了复用别的什么，而是为了让 utils/Format 的
 * rocketFullName(config: RocketConfig) 能直接吃它 —— 中文名/构型后缀那套
 * 查表规则（ROCKET_ZH + 长征编号推导）已经踩过一轮坑，必须复用而不是重写。
 */
export class RtRocket implements RocketConfig {
  /** ForEach 的 key：id 缺失时退化用名字 */
  key: string = '';
  id: number = 0;
  name: string = '';
  full_name: string = '';
  variant: string = '';
  families: string[] = [];
  /** 原始厂商名（英文公司名），详情跳转与搜索用 */
  manufacturer: string = '';

  /** 中文名；同中文名的多个构型会被补上构型后缀 */
  zh: string = '';
  /** 英文副名；与中文名相同则为空串（卡片上不重复占一行） */
  en: string = '';
  /** 展示用制造商：优先中文机构名，无词条回退英文原名 */
  maker: string = '';
  /** 国旗 emoji；认不出国籍为空串（flagOf 返回的是 emoji，不是图片路径） */
  flag: string = '';
  /** cn / us / ru / eu / asia / other */
  region: string = 'other';
  /** 搜索串：一次拼好，过滤时只做一次 indexOf */
  hay: string = '';

  img: string = '';
  active: boolean = false;
  reusable: boolean = false;

  /** LEO 运力（kg） */
  leo: number = 0;
  /** 累计发射次数 */
  launches: number = 0;
  /** 真实成功率（卡片显示） */
  rate: number = 0;
  /** 收缩后的成功率（只用于打分） */
  rateAdj: number = 0;
  /** 综合分 = 0.45 活跃度 + 0.35 可靠性 + 0.2 运力 */
  score: number = 0;

  /** '22.8 吨' / '850 kg' / '—' */
  leoText: string = '—';
  /** '99.8%' / '—' */
  rateText: string = '—';
  /** '643'：三格里只放数字，量词在标签上 */
  launchText: string = '0';
}

// ============ 数值格式化 ============

/** null / undefined / 负数一律归 0，绝不让 NaN 上屏 */
function rtNum(v: number | null | undefined): number {
  if (v === null || v === undefined) {
    return 0;
  }
  return v > 0 ? v : 0;
}

/**
 * kg → '22.8 吨' / '850 kg'。
 * ≥1000 换吨：23 吨比 22800 kg 好扫，小型箭仍用 kg 才有分辨率。
 * 整数不带小数点（68 吨而不是 68.0 吨）—— 卡片只有 3 个数字位，多一个 .0 就挤。
 */
function rtLeoText(kg: number): string {
  if (kg <= 0) {
    return '—';
  }
  if (kg >= 1000) {
    const t: number = Math.round(kg / 100) / 10;
    return (t === Math.floor(t) ? t.toFixed(0) : t.toFixed(1)) + ' 吨';
  }
  return Math.round(kg).toString() + ' kg';
}

/** 成功率文案：没打过就不给数字，0% 会被读成「全炸了」 */
function rtRateText(rate: number, tried: number): string {
  return tried > 0 ? (rate * 100).toFixed(1) + '%' : '—';
}

// ============ 原始 JSON → 视图模型 ============

/**
 * 全量落地：一次算出归一化分母、每条派生字段、去重后的中文名与搜索串。
 *
 * 入参是整份 list（不是单条），因为 score 依赖全局的 maxLaunch / maxLeo / p0。
 * 调用方之后只做筛选与排序，不再碰原始字段。
 */
export function rtBuildLib(rawList: RtLauncherRaw[]): RtRocket[] {
  // 分母只统计 active：退役型号的 642 次发射不该把在役型号的活跃度压扁
  let maxLaunch: number = 1;
  let maxLeo: number = 1;
  let sumOk: number = 0;
  let sumTried: number = 0;
  for (let i = 0; i < rawList.length; i++) {
    const raw: RtLauncherRaw = rawList[i];
    if (raw.active !== true) {
      continue;
    }
    const launch: number = rtNum(raw.total_launch_count);
    const leo: number = rtNum(raw.leo_capacity);
    if (launch > maxLaunch) {
      maxLaunch = launch;
    }
    if (leo > maxLeo) {
      maxLeo = leo;
    }
    sumOk += rtNum(raw.successful_launches);
    sumTried += rtNum(raw.successful_launches) + rtNum(raw.failed_launches);
  }
  // 全局成功率 = 贝叶斯先验均值；整份库都没有发射记录时给个行业常识值 0.95
  const p0: number = sumTried > 0 ? sumOk / sumTried : 0.95;
  // 活跃度取对数归一化的分母。maxLaunch ≥ 1，ln(1+1) > 0，不会除零
  const lnMax: number = Math.log(1 + maxLaunch);

  const out: RtRocket[] = [];
  for (let i = 0; i < rawList.length; i++) {
    const raw: RtLauncherRaw = rawList[i];
    const r: RtRocket = new RtRocket();
    const name: string = strOf(raw.name);
    const fullName: string = strOf(raw.full_name);
    const variant: string = strOf(raw.variant);
    r.id = raw.id === null || raw.id === undefined ? 0 : raw.id;
    r.name = name.length > 0 ? name : fullName;
    r.full_name = fullName;
    r.variant = variant;
    r.manufacturer = strOf(raw.manufacturer);
    if (raw.families !== undefined && raw.families !== null) {
      r.families = raw.families;
    }
    // 名字是唯一的展示锚点，没有名字的条目没法点也没法搜
    if (r.name.length === 0) {
      continue;
    }
    r.key = r.id > 0 ? r.id.toString() : r.name;
    r.active = raw.active === true;
    r.reusable = raw.reusable === true;
    r.img = strOf(raw.image);

    // 中文名走 Format 的查表 + 构型后缀规则；翻不出来时它内部会回退 full_name
    r.zh = rocketFullName(r);
    if (r.zh.length === 0) {
      r.zh = r.name;
    }
    const enRaw: string = fullName.length > 0 ? fullName : name;
    r.en = enRaw === r.zh ? '' : enRaw;

    const makerZh: string = agencyLabel(r.manufacturer);
    r.maker = makerZh.length > 0 ? makerZh : r.manufacturer;
    r.flag = flagOf(r.manufacturer);
    r.region = rtRegionOf(r.manufacturer);

    const ok: number = rtNum(raw.successful_launches);
    const bad: number = rtNum(raw.failed_launches);
    const tried: number = ok + bad;
    r.leo = rtNum(raw.leo_capacity);
    r.launches = rtNum(raw.total_launch_count);
    r.rate = tried > 0 ? ok / tried : 0;
    r.rateAdj = (ok + RATE_PRIOR * p0) / (tried + RATE_PRIOR);

    // 活跃度必须取对数：发射 100→200 的意义远小于 2→100，
    // 线性归一化会让 642 次的 Falcon 9 把所有型号压成一条线
    const act: number = Math.log(1 + r.launches) / lnMax;
    const cap: number = r.leo / maxLeo;
    r.score = 0.45 * act + 0.35 * r.rateAdj + 0.2 * cap;

    r.leoText = rtLeoText(r.leo);
    r.rateText = rtRateText(r.rate, tried);
    r.launchText = r.launches.toString();
    out.push(r);
  }

  rtFixDuplicateNames(out);
  rtFillHay(out);
  return out;
}

/**
 * 同中文名的多个构型（Starship / Starship V3 都译成「星舰」）在榜上会长得一模一样，
 * 看起来像重复数据。给这批补上构型后缀；已含后缀的（猎鹰 9 号 Block 5）不重复拼。
 */
function rtFixDuplicateNames(list: RtRocket[]): void {
  const cnt: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < list.length; i++) {
    if (!list[i].active) {
      continue;
    }
    const zh: string = list[i].zh;
    const old: number | undefined = cnt.get(zh);
    cnt.set(zh, old === undefined ? 1 : old + 1);
  }
  for (let i = 0; i < list.length; i++) {
    const r: RtRocket = list[i];
    if (!r.active) {
      continue;
    }
    const n: number | undefined = cnt.get(r.zh);
    if (n === undefined || n <= 1) {
      continue;
    }
    const v: string = r.variant.trim();
    if (v.length > 0 && r.zh.indexOf(v) < 0) {
      r.zh = r.zh + ' ' + v;
    }
  }
}

/**
 * 搜索串一次拼好。
 * 必须放在中文名定稿之后 —— 否则被补后缀的那批搜不到新名字。
 */
function rtFillHay(list: RtRocket[]): void {
  for (let i = 0; i < list.length; i++) {
    const r: RtRocket = list[i];
    const family: string = r.families.length > 0 ? r.families[0] : '';
    // 用数组 join 而不是逐段拼 + 判空：少一层分支，也避免出现连续空格
    const parts: string[] = [r.zh, r.name, r.full_name, r.manufacturer, family, r.variant];
    const kept: string[] = [];
    for (let j = 0; j < parts.length; j++) {
      if (parts[j].length > 0) {
        kept.push(parts[j]);
      }
    }
    r.hay = kept.join(' ').toLowerCase();
  }
}

// ============ 地区判定 ============

/**
 * LL2 型号库**没有国家字段**，manufacturer 只是一串公司名，
 * 且很多中国商业航天公司名字里没 China（LandSpace、Galactic Energy…），
 * 只能靠关键词白名单；漏掉的落 other，不硬猜。
 *
 * 为什么用 key 数组 + indexOf 而不是正则：ArkTS 里正则要写成双反斜杠字符串，
 * 这堆关键词一个转义字符都不需要，数组更不容易写错。
 */
class RtRegionRule {
  value: string = '';
  keys: string[] = [];

  constructor(value: string, keys: string[]) {
    this.value = value;
    this.keys = keys;
  }
}

const REGION_RULES: RtRegionRule[] = [
  new RtRegionRule('cn', [
    'china', 'chinese', 'landspace', 'galactic energy', 'i space', 'ispace', 'i-space',
    'cas space', 'expace', 'orienspace', 'space pioneer', 'deep blue', 'china rocket',
    'one space', 'kuaizhou', 'zhuque', 'ceres', 'hyperbola', 'gravity', 'tianlong',
    'jielong', 'kinetica', 'pallas', 'lijian', 'kaituo', 'rocket co.'
  ]),
  new RtRegionRule('us', [
    'spacex', 'united launch', 'orbital sciences', 'orbital atk', 'firefly', 'astra',
    'blue origin', 'stoke', 'rocket lab', 'northrop', 'masten', 'relativity'
  ]),
  new RtRegionRule('ru', [
    'khrunichev', 'progress rocket', 'energia', 'roskosmos', 'makeyev', 'yuzhnoye', 'yuzhmash'
  ]),
  new RtRegionRule('eu', [
    'ariane', 'esa', 'hyimpulse', 'hyprspace', 'maiaspace', 'payload aerospace', 'avio',
    'ohb', 'isaraerospace', 'orbex', 'skyrora', 'augsburg'
  ]),
  new RtRegionRule('asia', [
    'indian space', 'isro', 'mitsubishi', 'japan aerospace', 'jaxa', 'korean', 'innospace',
    'space one', 'interstellar', 'tispace', 'kari', 'galaxy space', 'land space'
  ])
];

/** 厂商名 → 地区码。顺序敏感：cn 先查，"LandSpace" 才不会被 asia 的 "land space" 抢走 */
function rtRegionOf(maker: string): string {
  const low: string = maker.toLowerCase();
  if (low.length === 0) {
    return 'other';
  }
  for (let i = 0; i < REGION_RULES.length; i++) {
    const rule: RtRegionRule = REGION_RULES[i];
    for (let j = 0; j < rule.keys.length; j++) {
      if (low.indexOf(rule.keys[j]) >= 0) {
        return rule.value;
      }
    }
  }
  return 'other';
}

// ============ 排名卡 ============

/**
 * 用法：
 *   RocketCard({ item: rocket, rankNo: index + 1, onOpen: (r: RtRocket) => { ... } })
 *
 * 卡片结构（对位 .rank-card 的 flex 横排）：
 *   [图 114×108：名次角标贴左上 / 「可复用」贴左下 / 底部渐暗]
 *   [右列：名称 + 详情胶囊 → 英文名 → 国旗 + 制造商 →（撑到底）→ 三格指标]
 */
@Component
export struct RocketCard {
  /**
   * 单条数据。
   * 用 @Prop 而不是普通成员：换榜单后整体替换数组，ForEach 的 key 可能不变，
   * 普通成员不会重新赋值（卡片就停在旧内容上）。
   * 挂 @Watch 是因为 broken 是组件内部状态：List 回收节点后同一实例会被复用给
   * 另一条数据，不重置的话新型号会顶着「图挂了」的占位。
   */
  @Prop @Watch('onItemChange') item: RtRocket = new RtRocket();
  /** 名次，1 起。改榜单后同一个节点会换到别的名次上，所以也要 @Prop */
  @Prop rankNo: number = 0;
  /** 整卡点击。普通成员 + 空实现（@Prop 不适合承载函数） */
  onOpen: (item: RtRocket) => void = () => {};

  /** 图片加载失败后置位，改画几何占位（避免留一块纯黑） */
  @State broken: boolean = false;

  onItemChange(propName: string): void {
    this.broken = false;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row() {
        this.media()

        Column() {
          // 名称行：中文名 +「详情」胶囊（对位 .rank-more）
          Row() {
            Text(this.item.zh)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)

            // 详情：青边胶囊。原来是裸灰字 —— 一行里两个可点的东西（卡片 + 详情），
            // 没有边框就看不出后者也是个入口
            Text('详情')
              .fontSize(9.5)
              .fontColor(ACCENT_LIGHT)
              .padding({ left: 7, right: 7, top: 1, bottom: 1 })
              .borderRadius(999)
              .border({ width: 1, color: '#5238BDF8' })
              .margin({ left: 5 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          // 中文在上、英文在下；没有中文词条时两者相同，就不重复显示
          if (this.item.en.length > 0) {
            Text(this.item.en)
              .fontSize(10)
              .fontColor(TXT_EN)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 2 })
          }

          // 国旗 + 制造商。
          // ⚠ 小程序这里是真图片（<image class="flag">，34×24rpx 的 png 圆角旗）；
          //   鸿蒙工程里没有国旗资源（没有 assets/flags，也没有网络旗图接口），
          //   所以保留 utils/Format 的 flagOf() 返回的 emoji。
          //   要换成真图，得先把 90+ 面旗打进 rawfile 并写「厂商 → 旗文件名」映射，
          //   那是另一个任务，这里不做。
          Row() {
            if (this.item.flag.length > 0) {
              Text(this.item.flag)
                .fontSize(10)
                .margin({ right: 4 })
            }
            Text(this.item.maker.length > 0 ? this.item.maker : '未知制造商')
              .fontSize(10.5)
              .fontColor(TXT_MAKER)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ top: 5 })

          // 撑开剩余高度，把三格指标压到卡片底部（对位 .rank-metrics 的 margin-top:auto）。
          // 右列高度固定成图高，所以这里的剩余空间是可算的，Blank 不会把卡片撑高。
          Blank()

          // 三格硬指标：数值在上、量词在下，等宽三等分（对位 .rank-metrics）
          Row() {
            this.metricLeo()
            this.metricLaunch()
            this.metricRate()
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }
        .layoutWeight(1)
        .height(MEDIA_H)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 9 })
      }
      .width('100%')
      .padding(8)
      .alignItems(VerticalAlign.Top)
      // 渐变底（对位 linear-gradient(150deg, rgba(25,32,47,.96), rgba(16,21,32,.96))）：
      // 留 4% 透明度，星空能透一点点上来，卡片不至于变成一块死黑
      .linearGradient({
        angle: 150,
        colors: [['#F519202F', 0.0], ['#F5101520', 1.0]]
      })
      .borderRadius(10)
      .border({ width: 1, color: this.rankNo <= 3 ? '#3838BDF8' : '#0FFFFFFF' })
      .shadow({ radius: 15, color: '#38000000', offsetX: 0, offsetY: 5 })

      // 前三名左侧青竖线（对位 .is-top::before：3rpx 宽、上下各收 22rpx）。
      // 高度写死 102 = 卡高 124 − 上下各 11：卡高由固定的图区 108 + padding 16 决定，
      // 不随文字换行变化，所以不需要百分比（ArkUI 也没有 calc）。
      if (this.rankNo <= 3) {
        Column()
          .width(1.5)
          .height(102)
          .margin({ top: 11 })
          .linearGradient({
            angle: 180,
            colors: [['#F27DD3FC', 0.0], ['#0038BDF8', 1.0]]
          })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .onClick(() => {
      this.onOpen(this.item);
    })
  }

  // ---- 三格指标 ----
  //
  // ⚠ 与 RocketView 的三格同一个坑：@Builder **按值传参**时不建立响应式依赖，
  //   `metric(this.item.leoText, 'LEO 运力')` 在 List 复用节点、@Prop 换数据时
  //   可能只更新外层而三格的字符串停在旧值。所以每格一个无参 @Builder，
  //   Text 里直接读 this.item.xxx。样式重复三遍，换的是「一定会刷新」。

  /** 第一格：LEO 运力（对位 .m-v 26rpx / .m-k 18rpx） */
  @Builder
  metricLeo() {
    Column() {
      Text(this.item.leoText)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(TXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text('LEO 运力')
        .fontSize(9)
        .fontColor(TXT_MUTE)
        .maxLines(1)
        .margin({ top: 1 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ right: 4 })
  }

  /** 第二格：累计发射 */
  @Builder
  metricLaunch() {
    Column() {
      Text(this.item.launchText)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(TXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text('累计发射')
        .fontSize(9)
        .fontColor(TXT_MUTE)
        .maxLines(1)
        .margin({ top: 1 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ right: 4 })
  }

  /** 第三格：成功率 */
  @Builder
  metricRate() {
    Column() {
      Text(this.item.rateText)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(TXT_MAIN)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      Text('成功率')
        .fontSize(9)
        .fontColor(TXT_MUTE)
        .maxLines(1)
        .margin({ top: 1 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 左侧图区（对位 .rank-media：114×108、radius 12rpx、底 #0f1520）。
   * 有图 → Cover；图挂了或本来就没图 → 几何火箭（见 geoRocket）。
   * 图区上压两件东西：左上名次角标、左下「可复用」标记 —— 两者都在图上，
   * 不占右列的横向空间，这也是小程序把它们放在图里的原因。
   */
  @Builder
  media() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.item.img.length > 0 && !this.broken) {
        Image(this.item.img)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
          .onError(() => {
            this.broken = true;
          })
      } else {
        this.geoRocket()
      }

      // 底部渐暗（对位 .rank-media::after：底部 64rpx 的 rgba(6,10,18,.82)→透明）。
      // 作用是让压在图上的一切（尤其是左下角标）在任何照片上都读得清。
      Column() {
        Column()
          .width('100%')
          .height(30)
          .linearGradient({
            angle: 180,
            colors: [['#00060A12', 0.0], ['#D1060A12', 1.0]]
          })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .hitTestBehavior(HitTestMode.None)

      // 名次角标：贴左上直角、右下圆角（对位 .rank-no 的 border-bottom-right-radius 12rpx）。
      // 前三名走金/银/铜渐变 + 深色字，4 名以后是半透明黑底 + 灰字。
      // 文案带井号（小程序模板是 `#{{ i + 1 }}`，见 rockets.vue:134），别去掉。
      // 四个分支只差底色与投影，字体/内边距一致 —— 拆开写是因为 ArkUI 的
      // linearGradient 不能按条件传 undefined，硬合并要造一个假渐变。
      if (this.rankNo === 1) {
        Text('#' + this.rankNo.toString())
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor('#14181F')
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius({ topLeft: 0, topRight: 0, bottomRight: 6, bottomLeft: 0 })
          .linearGradient({
            angle: 135,
            colors: [['#7DD3FC', 0.0], ['#0EA5E9', 1.0]]
          })
          .shadow({ radius: 9, color: '#6B38BDF8', offsetX: 0, offsetY: 2 })
      } else if (this.rankNo === 2) {
        Text('#' + this.rankNo.toString())
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor('#14181F')
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius({ topLeft: 0, topRight: 0, bottomRight: 6, bottomLeft: 0 })
          .linearGradient({
            angle: 135,
            colors: [['#D6ECFF', 0.0], ['#8FB3D4', 1.0]]
          })
      } else if (this.rankNo === 3) {
        Text('#' + this.rankNo.toString())
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor('#14181F')
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius({ topLeft: 0, topRight: 0, bottomRight: 6, bottomLeft: 0 })
          .linearGradient({
            angle: 135,
            colors: [['#A8C4DD', 0.0], ['#6D8AA8', 1.0]]
          })
      } else {
        Text('#' + this.rankNo.toString())
          .fontSize(10.5)
          .fontWeight(FontWeight.Bold)
          .fontColor('#8A97A8')
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .borderRadius({ topLeft: 0, topRight: 0, bottomRight: 6, bottomLeft: 0 })
          .backgroundColor('#C2060A12')
      }

      // 「可复用」贴图左下（对位 .rank-flag：18rpx 字、rgba(6,10,18,.7) 底、
      // 右上圆角 8rpx）。原来放名称行右侧，会跟「详情」抢横向空间，
      // 也在视觉上把「这是一枚可复用火箭」这条属性从图上挤进了文字里。
      if (this.item.reusable) {
        Column() {
          Text('可复用')
            .fontSize(9)
            .fontColor('#9FD0FF')
            .letterSpacing(0.25)
            .padding({ left: 6, right: 6, top: 1.5, bottom: 1.5 })
            .borderRadius({ topLeft: 0, topRight: 4, bottomRight: 0, bottomLeft: 0 })
            .backgroundColor('#B3060A12')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.Start)
        .hitTestBehavior(HitTestMode.None)
      }
    }
    .width(MEDIA_W)
    .height(MEDIA_H)
    .borderRadius(6)
    .clip(true)
    .backgroundColor('#0F1520')
  }

  /**
   * 几何占位：整流罩（圆角头）+ 箭体 + 尾翼。
   *
   * ⚠ 先说清事实差异：小程序现状（rockets.vue:133）的占位是
   *   `<text class="rank-ph-icon">🚀</text>`，56rpx / opacity .4 的一个 emoji；
   *   审计第 20 条写的「geoRocket 三段几何拼图」在小程序仓库里 grep 不到（已全文搜过
   *   geoRocket / geo-rocket，零命中），是按更早的设计稿写的。
   *   这里**保留几何剪影**：在 114×108 的图区里，三段纯色块比一个灰扑扑的 emoji
   *   更像缩略图，也不会在不同字体下大小乱飘。若要严格对齐现状，把 media() 里的
   *   `this.geoRocket()` 换成 `Text('🚀').fontSize(28).opacity(0.4)` 即可。
   */
  @Builder
  geoRocket() {
    Column() {
      Column()
        .width(17)
        .height(26)
        .borderRadius(9)
        .linearGradient({
          angle: 180,
          colors: [['#5B7FAE', 0.0], ['#2E4463', 1.0]]
        })

      Column()
        .width(14)
        .height(41)
        .backgroundColor('#2A3D5A')

      Column()
        .width(24)
        .height(6)
        .borderRadius(2)
        .backgroundColor('#3C5375')
        .margin({ top: 1 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .linearGradient({
      angle: 135,
      colors: [['#16233A', 0.0], ['#0D1420', 1.0]]
    })
  }
}
