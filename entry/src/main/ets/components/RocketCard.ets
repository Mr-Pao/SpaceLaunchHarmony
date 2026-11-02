/**
 * components/RocketCard.ets —— 火箭列表卡片（+ launchers 数据集形状）
 *
 * 对位小程序：
 *   pages/rockets/rockets.vue 的列表卡片 + rocket-lookup.js 的型号补全
 *
 * ── 为什么 launchers 的 model 写在这里而不是 model/ ──
 *   任务书写明「launchers 数据集还没有 model，按实际 JSON 结构自己定义，放组件文件里」。
 *   工程里 model/ 下的文件是跨页面共享的契约（Launch/Astronaut/News...），
 *   而 launchers 目前只有火箭 tab 一个消费方，提前塞进 model/ 等于给别的页面
 *   发一份没人用的接口。等真有第二个页面要读 launchers 再搬过去。
 *   命名统一 Rk 前缀，避免与 model/Common.ets 的 LaunchRocket / RocketConfig 撞名。
 *
 * ── 字段口径（2026-11-02 线上 COS 实测 532 条）──
 *   length / diameter 是**米制小数**（41.5 / 2.9），leo_capacity 是 **kg 整数**（3700），
 *   launch_cost 是美元整数，均可能为 null；image 是 COS 地址或空；
 *   **没有 agencyName 字段** —— 机构只有 manufacturer（英文公司名），
 *   所以卡片上不硬造「国别」，只显示厂商，缺就整行不画。
 *
 * ── 卡片为什么不显示「全部参数」──
 *   532 条里绝大多数字段是空的（Antares 330 连 length 都没有）。逐行渲染再判空
 *   会让列表出现大量半空卡片；这里把所有可选参数压成**一行** `·` 分隔的摘要，
 *   一个都没有就整行省略，卡片高度不会因数据贫富而抖动。
 *
 * ⚠ 本文件不打日志（纯展示）。
 */

import { strOf } from '../utils/Format';

const CARD_BG: string = '#141A26';
const CARD_BORDER: string = '#0DFFFFFF';
const TXT_MAIN: string = '#E8EEF8';
const TXT_SUB: string = '#A7B4C7';
const TXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';
/** 缩略图列宽。58×72 刚好是 4:5，与 COS 上竖构型照片的平均比例接近 */
const THUMB_W: number = 58;
const THUMB_H: number = 72;

// ============ 数据集形状 ============

/**
 * launchers.json 单条。
 * 全部可选：CI 的 slim 会按字段有无裁剪，缺字段是常态不是异常。
 */
export interface RkLauncherRaw {
  id?: string;
  name?: string;
  full_name?: string;
  variant?: string;
  families?: string[];
  manufacturer?: string;
  /** 米 */
  length?: number | null;
  /** 米 */
  diameter?: number | null;
  launch_mass?: number | null;
  to_thrust?: number | null;
  /** kg */
  leo_capacity?: number | null;
  /** kg */
  gto_capacity?: number | null;
  /** kg */
  sso_capacity?: number | null;
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
  /** COS 地址；无图为空串或 null */
  image?: string | null;
}

export interface RkLaunchersPayload {
  v?: number;
  dataset?: string;
  generatedAt?: string;
  count?: number;
  served?: number;
  list?: RkLauncherRaw[];
}

/**
 * 列表视图模型。
 *
 * 字符串字段全部在造数据时算好（params / flights / hay），
 * 因为列表滚动时每一帧都会重跑 build，卡片里不该再做数值格式化与字符串拼接。
 * hay 是搜索用的小写拼接串：532 条 × 每次输入都对 5 个字段做 toLowerCase 太浪费，
 * 拼一次存起来，过滤时只做 indexOf。
 */
export class RkRocket {
  /** ForEach 的 key。id 缺失时退化用名字 */
  key: string = '';
  name: string = '';
  /** 厂商（LL2 的 manufacturer），缺则为空串 */
  maker: string = '';
  /** 预拼好的参数摘要：'高 41.5 m · Ø 2.9 m · LEO 3.7 t'，空串表示这几项都没有 */
  params: string = '';
  /** 发射次数角标：'7 飞'，空串不画 */
  flights: string = '';
  /** 缩略图，空串走几何占位 */
  img: string = '';
  /** 在役标记，只用于缩略图上的小角标 */
  active: boolean = false;
  /** 搜索用：name/full_name/manufacturer/variant/families 拼成的小写串 */
  hay: string = '';
}

/** 米制数值 → '41.5 m'。整数不补 '.0'（一半以上是整数，补零反而像测量值） */
function rkMeters(v: number | null | undefined): string {
  if (v === null || v === undefined || v <= 0) {
    return '';
  }
  const rounded: number = Math.round(v * 10) / 10;
  if (rounded === Math.floor(rounded)) {
    return `${Math.floor(rounded).toString()} m`;
  }
  return `${rounded.toFixed(1)} m`;
}

/**
 * kg → 吨（≥1000 才换单位）。
 * 3700 kg 写成 '3.7 t' 与工程内其他页面（Stats 里的运力）口径一致。
 */
function rkMass(v: number | null | undefined): string {
  if (v === null || v === undefined || v <= 0) {
    return '';
  }
  if (v >= 1000) {
    const t: number = Math.round(v / 100) / 10;
    return `${t.toString()} t`;
  }
  return `${Math.round(v).toString()} kg`;
}

/** 原始 JSON → 视图模型。字段缺失一律降级成空串/默认值，绝不留 undefined 上屏 */
export function rkFromRaw(raw: RkLauncherRaw): RkRocket {
  const r: RkRocket = new RkRocket();
  const name: string = strOf(raw.name);
  const fullName: string = strOf(raw.full_name);
  r.name = name.length > 0 ? name : fullName;
  r.key = strOf(raw.id).length > 0 ? strOf(raw.id) : r.name;
  r.maker = strOf(raw.manufacturer);
  r.img = strOf(raw.image);
  r.active = raw.active === true;

  const parts: string[] = [];
  const h: string = rkMeters(raw.length);
  if (h.length > 0) {
    parts.push(`高 ${h}`);
  }
  const d: string = rkMeters(raw.diameter);
  if (d.length > 0) {
    parts.push(`Ø ${d}`);
  }
  const leo: string = rkMass(raw.leo_capacity);
  if (leo.length > 0) {
    parts.push(`LEO ${leo}`);
  }
  r.params = parts.join(' · ');

  const n: number = raw.total_launch_count === null || raw.total_launch_count === undefined
    ? 0 : raw.total_launch_count;
  r.flights = n > 0 ? `${Math.round(n).toString()} 飞` : '';

  // 搜索串：家族名是数组，先 join 再拼；全部小写，过滤时只做一次 indexOf
  let families: string = '';
  if (raw.families !== undefined && raw.families !== null) {
    families = raw.families.join(' ');
  }
  const hayParts: string[] = [];
  const seeds: string[] = [r.name, fullName, r.maker, strOf(raw.variant), families];
  for (let i = 0; i < seeds.length; i++) {
    if (seeds[i].length > 0) {
      hayParts.push(seeds[i]);
    }
  }
  r.hay = hayParts.join(' ').toLowerCase();
  return r;
}

// ============ 卡片 ============

/**
 * 用法：
 *   RocketCard({ item: rocket, onOpen: (r: RkRocket) => { ... } })
 */
@Component
export struct RocketCard {
  /**
   * 单条数据。
   * 用 @Prop 而不是普通成员：搜索结果整体替换数组后，ForEach 的 key 可能不变，
   * 普通成员不会重新赋值（卡片就停在旧内容上）。
   * 挂 @Watch 是因为 broken 是组件内部状态：List 回收节点后同一实例会被复用给
   * 另一条数据（同 LaunchCard.ets:65 的处理），不重置的话新型号会顶着「图挂了」的占位。
   */
  @Prop @Watch('onItemChange') item: RkRocket = new RkRocket();
  /** 整卡点击。普通成员 + 空实现（@Prop 不适合承载函数） */
  onOpen: (item: RkRocket) => void = () => {};

  /** 图片加载失败后置位，改画几何占位（避免留一块纯黑） */
  @State broken: boolean = false;

  /** 换了数据就重新给图一次机会 */
  onItemChange(propName: string): void {
    this.broken = false;
  }

  build() {
    Row() {
      this.thumb()

      Column() {
        // 型号名：28 字符是实测最长值，单行省略足够
        Row() {
          Text(this.item.name)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(TXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)

          if (this.item.flights.length > 0) {
            Text(this.item.flights)
              .fontSize(9)
              .fontColor(TXT_DIM)
              .margin({ left: 6 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        if (this.item.maker.length > 0) {
          Text(this.item.maker)
            .fontSize(11)
            .fontColor(TXT_SUB)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 3 })
        }

        // 参数摘要整行省略，不拆成多行：卡片高固定 92vp，列表才好算滚动位置
        if (this.item.params.length > 0) {
          Text(this.item.params)
            .fontSize(10)
            .fontColor(TXT_DIM)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ top: 4 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 })
      .justifyContent(FlexAlign.Center)

      Text('›')
        .fontSize(18)
        .fontColor(TXT_DIM)
        .margin({ left: 4 })
    }
    .width('100%')
    .padding(10)
    .alignItems(VerticalAlign.Center)
    .backgroundColor(CARD_BG)
    .borderRadius(12)
    .border({ width: 1, color: CARD_BORDER })
    .onClick(() => {
      this.onOpen(this.item);
    })
  }

  /**
   * 左侧缩略图位。
   * 有图 → Image(Cover)；图挂了或本来就没图 → 画一个几何火箭。
   * 任务书明确「不要留空白块」，所以占位必须是看得过去的东西而不是灰底。
   */
  @Builder
  thumb() {
    Stack({ alignContent: Alignment.TopEnd }) {
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

      if (this.item.active) {
        Text('在役')
          .fontSize(8)
          .fontColor(ACCENT)
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .borderRadius(3)
          .backgroundColor('#1A1F2E')
          .margin({ top: 4, right: 4 })
      }
    }
    .width(THUMB_W)
    .height(THUMB_H)
    .borderRadius(8)
    .clip(true)
    .backgroundColor('#0F1520')
  }

  /**
   * 几何占位：整流罩（圆角头）+ 箭体 + 尾翼。
   * 三段纯色块拼出来的剪影，比一个 🚀 emoji 更像「缩略图」，
   * 也比灰底方块更能一眼认出这是火箭。
   */
  @Builder
  geoRocket() {
    Column() {
      // 整流罩：上圆下方
      Column()
        .width(13)
        .height(16)
        .borderRadius({ topLeft: 7, topRight: 7 })
        .linearGradient({
          angle: 180,
          colors: [['#5B7FAE', 0.0], ['#2E4463', 1.0]]
        })

      // 箭体
      Column()
        .width(11)
        .height(26)
        .backgroundColor('#2A3D5A')

      // 尾翼 + 喷口（一条略宽的横梁，让剪影有「底座」）
      Column()
        .width(19)
        .height(5)
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
