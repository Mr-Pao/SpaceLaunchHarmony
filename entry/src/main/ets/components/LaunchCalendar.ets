/**
 * components/LaunchCalendar.ets —— 发射日历（按月网格 + 日期打点）
 *
 * 对位小程序：components/launch-calendar/launch-calendar.vue（229 行）
 *   template   1-24    （月头 / 七列表头 / 42 格网格）
 *   script    27-137   （grid 计算属性 / shiftMonth / onTap）
 *   style    140-229   （.cal / .cal-head / .cal-nav / .cal-wd / .cal-cell / .cal-dot / .cal-num）
 *
 * ── 换算：rpx ÷ 2 = vp ──
 *   padding 24rpx → 12vp；圆角 20rpx → 10vp；边框 1rpx → 0.5vp
 *   月份字 30rpx → 15vp；表头 22rpx → 11vp；日期 26rpx → 13vp；角标 18rpx → 9vp
 *   圆钮 64rpx → 32vp；格 min-height 84rpx → 42vp；圆点 8rpx → 4vp
 *
 * ── 为什么这么写（ArkTS 侧的三个坑，逐条交代）──
 *   1. **按日期分组必须用 Map**。小程序是 `byDate[ds] = ...`，ArkTS 禁索引签名，
 *      动态下标 `byDate[ds]` 直接编译不过，只能用 Map<string, LaunchSummary[]>。
 *   2. **42 个格子不能用对象字面量 push**。`cells.push({ day, inMonth, ... })`
 *      在 ArkTS 非法（禁无类型对象字面量），必须 new CalCell() 后逐字段赋值。
 *   3. **选中态单独放 @State**。@State 不观察数组下标赋值（`this.cells[i].xxx = ...`
 *      不会触发重绘），所以格子的「选中底色」不写进 CalCell，而是页面级
 *      selected: string 与 dateStr 比对 —— 改一个字符串就能让整片网格重算样式，
 *      也省掉每次点格子重建 42 个对象的开销。
 *
 * ── 相对小程序的有意差异 ──
 *   1. 小程序用 CSS grid（`grid-template-columns: repeat(7, 1fr)`）。ArkTS 的 Grid
 *      强制要 GridItem 包裹、且要自己写 columnsTemplate，为 42 个格子多套一层
 *      没有收益，改成 `Row()` + 每个子项 `.layoutWeight(1)`，等分效果一致。
 *   2. 行高固定 42vp 而不是 minHeight。6 行等高才不会在切月（有/无打点）时整体跳一下，
 *      小程序靠 min-height 也基本是恒高，这里把意图写成硬约束。
 *   3. 点没有发射的日子直接 return（与小程序一致），不做「点空日清空选中」——
 *      父级拿到空列表反而要额外判断。
 *
 * ⚠ 本文件不使用 console.*（本项目日志一律 hilog，这里没有需要落日志的分支）。
 */

import { LaunchSummary } from '../model/Common';

/** 卡片底色（任务书视觉规范） */
const CAL_BG: string = '#141A26';
/** 卡片描边：rgba(255,255,255,0.05) → 0x0D */
const CAL_BORDER: string = '#0DFFFFFF';
/** 圆钮底色：rgba(255,255,255,0.06) → 0x0F */
const NAV_BG: string = '#0FFFFFFF';
/** 选中底色：rgba(56,189,248,0.14) → 0x24 */
const SEL_BG: string = '#2438BDF8';
/** 强调蓝（今天 / 选中） */
const ACCENT: string = '#38BDF8';
/** 打点黄（有发射 / 条数角标） */
const DOT_YELLOW: string = '#F5C33B';
/** 日期文字 */
const DAY_TEXT: string = '#E2E8F0';
/** 表头灰 */
const WEEK_HEAD: string = '#4A5568';

/** 月份标题内边距、格子圆角等零散尺寸，集中在顶部便于按视觉稿微调 */
const CAL_PAD: number = 12;
const CELL_H: number = 42;

/**
 * 日历格。
 *
 * 必须是 export 的 class（不是 interface）：rebuild 里要 new 出来逐个字段赋值，
 * interface 没法 new；同时按 ArkTS 的「禁止声明合并」约定加 `Cal` 前缀。
 * 注意 launches 存的是**当天**的发射条目引用，父级拿去做列表渲染即可。
 */
export class CalCell {
  /** 格子里显示的数字。上月末尾 / 下月开头是另算的日期，不是 1..31 连续 */
  day: number = 0;
  /** 是否属于当前月。false → 整格压暗且不可点 */
  inMonth: boolean = false;
  /** YYYY-MM-DD。非本月格子为空串（小程序也是空串，不是算出来的越界日期） */
  dateStr: string = '';
  /** 是否今天。按本地时区算，与小程序 `new Date()` 口径一致 */
  isToday: boolean = false;
  /** 当天的发射。按 net 前 10 位（UTC 日期）分组，与列表排序口径一致 */
  launches: LaunchSummary[] = [];
}

/** 两位补零。ArkTS 里 padStart 可用，但小函数更直白，且避免 locale 差异 */
function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

@Component
export struct LaunchCalendar {
  /**
   * 待发射 / 已发射列表，由父级传入（组件自身不发网络请求）。
   *
   * 必须挂 @Watch：父级数据是异步到的，首帧 items 是空数组，
   * 不监听就永远是空日历（这是小程序 computed 天然具备、ArkTS 要手动补的能力）。
   */
  @Prop @Watch('onItemsChange') items: LaunchSummary[] = [];

  /** 点某个有发射的日子。普通成员不加装饰器（ArkTS 不让 @Prop 承载函数） */
  onPick: (dateStr: string, launches: LaunchSummary[]) => void =
    (dateStr: string, launches: LaunchSummary[]) => {};

  /** 当前展示的年 / 月。切换月份后 rebuild 重算 42 格 */
  @State year: number = new Date().getFullYear();
  @State month: number = new Date().getMonth() + 1;
  /** 选中的日期串。单独拎出来是因为数组元素赋值不触发刷新（见文件头坑 3） */
  @State selected: string = '';
  /** 42 格。rebuild 整体换新引用，@State 才能观察到变化 */
  @State cells: CalCell[] = [];

  /** 表头七列，周日起头（与小程序 weekHeads 一致） */
  private weekHeads: string[] = ['日', '一', '二', '三', '四', '五', '六'];
  /** 6 行固定。放成员而不是在 ForEach 里写字面量，避免每次渲染新建数组 */
  private rowIndexes: number[] = [0, 1, 2, 3, 4, 5];

  aboutToAppear(): void {
    this.rebuild();
  }

  /**
   * items 变化后重算。
   * @Watch 回调会带 propName 参数，这里用不到（只有 items 一个被监听），
   * 但签名必须接住，否则 ArkTS 会报参数个数不符。
   */
  onItemsChange(propName: string): void {
    this.rebuild();
  }

  /**
   * 重算 42 格。
   *
   * 与小程序 grid() 逐行对应，唯一的结构差异就是 Map 与 new CalCell()。
   */
  private rebuild(): void {
    // 本月 1 号是周几（0 = 周日）
    const startWeek: number = new Date(this.year, this.month - 1, 1).getDay();
    // 本月天数：下月第 0 天 = 本月最后一天
    const daysInMonth: number = new Date(this.year, this.month, 0).getDate();
    // 上月天数
    const daysPrev: number = new Date(this.year, this.month - 1, 0).getDate();

    // 按日期分组。只需一次遍历，后面的格子直接查表
    const byDate: Map<string, LaunchSummary[]> = new Map<string, LaunchSummary[]>();
    for (let i = 0; i < this.items.length; i++) {
      const x: LaunchSummary = this.items[i];
      // 与小程序 `if (!x || !x.net) continue` 等价：没 net 的条目挂不到任何日期上
      if (!x.net) {
        continue;
      }
      const ds: string = x.net.slice(0, 10);
      const hit: LaunchSummary[] | undefined = byDate.get(ds);
      if (hit === undefined) {
        byDate.set(ds, [x]);
      } else {
        hit.push(x);
      }
    }

    // 今天。用本地时区拼串，与小程序 todayStr 完全同口径
    const t: Date = new Date();
    const todayStr: string =
      t.getFullYear().toString() + '-' + pad2(t.getMonth() + 1) + '-' + pad2(t.getDate());

    const next: CalCell[] = [];
    for (let i = 0; i < 42; i++) {
      // i = 0 对应本月 1 号之前 startWeek 个格子，所以减掉 startWeek
      const dayNum: number = i + 1 - startWeek;
      let day: number;
      let inMonth: boolean;
      if (dayNum < 1) {
        day = daysPrev + dayNum;
        inMonth = false;
      } else if (dayNum > daysInMonth) {
        day = dayNum - daysInMonth;
        inMonth = false;
      } else {
        day = dayNum;
        inMonth = true;
      }
      // 只有本月格子才有合法日期串；上月/下月格子留空，避免和真实日期撞车
      const dateStr: string = inMonth
        ? this.year.toString() + '-' + pad2(this.month) + '-' + pad2(day)
        : '';

      const cell: CalCell = new CalCell();
      cell.day = day;
      cell.inMonth = inMonth;
      cell.dateStr = dateStr;
      cell.isToday = dateStr === todayStr && dateStr.length > 0;
      const list: LaunchSummary[] | undefined = byDate.get(dateStr);
      cell.launches = list === undefined ? [] : list;
      next.push(cell);
    }

    // 整体换引用，@State 才会把整片网格标脏
    this.cells = next;
  }

  /** 跨年进位的月份切换。与小程序 shiftMonth 等价（0..11 的边界都处理了） */
  private shiftMonth(delta: number): void {
    let m: number = this.month + delta;
    let y: number = this.year;
    if (m < 1) {
      m = 12;
      y--;
    } else if (m > 12) {
      m = 1;
      y++;
    }
    this.year = y;
    this.month = m;
    // 换月后旧选中日不属于新网格，清掉，否则下一次点别的日子看着像「两个选中」
    this.selected = '';
    this.rebuild();
  }

  /** 点格子。没发射的日子不可点（小程序同样直接 return） */
  private onTapCell(c: CalCell): void {
    if (!c.inMonth || c.launches.length === 0) {
      return;
    }
    this.selected = c.dateStr;
    // 注意：selected 已经是 @State，改它就会重绘；不需要再重建 cells
    this.onPick(c.dateStr, c.launches);
  }

  /** 取第 row 行的 7 个格子。用方法而不是在 @Builder 里写局部变量语句 */
  private rowOf(row: number): CalCell[] {
    return this.cells.slice(row * 7, row * 7 + 7);
  }

  /** 有打点就画 1~3 个黄点：超过 3 条用右上角数字表达，不无限堆点 */
  private dotCount(c: CalCell): number {
    const n: number = c.launches.length;
    return n > 3 ? 3 : n;
  }

  // ============ 月头 ============

  @Builder
  headBar() {
    Row() {
      // 左箭头：圆形按钮，32×32，与右箭头对称
      Row() {
        Text('‹')
          .fontSize(20)
          .fontColor('#FFFFFF')
          .lineHeight(20)
          // 箭头字形本身偏上，视觉上顶一格，往下推 1vp 才落在圆心
          .margin({ top: 1 })
      }
      .width(32)
      .height(32)
      .borderRadius(16)
      .backgroundColor(NAV_BG)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.shiftMonth(-1);
      })

      // 中文年月：2026年11月（不要 2026-11，与小程序 {{ year }} 年 {{ month }} 月 同口径）
      Text(this.year.toString() + '年' + this.month.toString() + '月')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)

      Row() {
        Text('›')
          .fontSize(20)
          .fontColor('#FFFFFF')
          .lineHeight(20)
          .margin({ top: 1 })
      }
      .width(32)
      .height(32)
      .borderRadius(16)
      .backgroundColor(NAV_BG)
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.shiftMonth(1);
      })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 8 })
  }

  // ============ 表头七列 ============

  @Builder
  weekBar() {
    Row() {
      ForEach(this.weekHeads, (w: string) => {
        Text(w)
          .fontSize(11)
          .fontColor(WEEK_HEAD)
          .textAlign(TextAlign.Center)
          .padding({ bottom: 4 })
          .layoutWeight(1)
      }, (w: string) => w)
    }
    .width('100%')
  }

  // ============ 单个格子 ============

  /**
   * 一格：日期数字 + 可选打点 + 可选条数角标。
   *
   * 用 Stack 而不是相对定位：ArkTS 没有 `position: absolute` 那套，
   * 角标要靠 Stack(TopEnd) 贴右上角，Column 再放中间内容。
   */
  @Builder
  cellView(c: CalCell) {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column() {
        Text(c.day.toString())
          .fontSize(13)
          .lineHeight(18)
          .fontColor(c.isToday ? ACCENT : DAY_TEXT)
          .fontWeight(c.isToday ? FontWeight.Bold : FontWeight.Normal)

        // 有发射才打点；0 条时整块不渲染，省掉一个空 Row。
        // 用 Circle 而不是「宽高相等的空 Text 加圆角」：空 Text 中文案为空，
        // 部分场景不参与绘制，Circle 是形状组件，4vp 直径稳定可见
        if (c.launches.length > 0) {
          Row() {
            if (this.dotCount(c) >= 1) {
              Circle({ width: 4, height: 4 })
                .fill(DOT_YELLOW)
                .margin({ left: 1.5, right: 1.5 })
            }
            if (this.dotCount(c) >= 2) {
              Circle({ width: 4, height: 4 })
                .fill(DOT_YELLOW)
                .margin({ left: 1.5, right: 1.5 })
            }
            if (this.dotCount(c) >= 3) {
              Circle({ width: 4, height: 4 })
                .fill(DOT_YELLOW)
                .margin({ left: 1.5, right: 1.5 })
            }
          }
          .margin({ top: 3 })
        }
      }
      .width('100%')
      .height(CELL_H)
      // 纵向居中偏上：padding top 5 / bottom 7，与小程序 .cal-cell 一致
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({ top: 5, bottom: 7 })

      // 条数角标：>1 才显示（1 条时黄点已经够了，再写个 1 是噪音）
      if (c.launches.length > 1) {
        Text(c.launches.length.toString())
          .fontSize(9)
          .fontColor(DOT_YELLOW)
          .margin({ top: 1, right: 3 })
      }
    }
    .layoutWeight(1)
    .height(CELL_H)
    .borderRadius(6)
    .backgroundColor(this.selected.length > 0 && c.dateStr === this.selected ? SEL_BG : Color.Transparent)
    // 非本月整格压暗（0.28）；不可点由 onTapCell 里判 inMonth 兜住
    .opacity(c.inMonth ? 1 : 0.28)
    .onClick(() => {
      this.onTapCell(c);
    })
  }

  // ============ 一行 7 格 ============

  @Builder
  weekRow(row: number) {
    Row() {
      // key 里必须带格子内容，不能只用下标：
      // ForEach 的 key 不变就**不会重跑子项**，items 异步到达后 rebuild 换了新
      // CalCell 对象，若 key 仍是 row_idx 则黄点/数字永远不会出现（ArkUI 经典坑）。
      // 带上 dateStr + 条数，数据一变 key 就变，格子才会按新数据重绘。
      ForEach(this.rowOf(row), (c: CalCell, idx: number) => {
        this.cellView(c)
      }, (c: CalCell, idx: number) => row.toString() + '_' + idx.toString() + '_' +
        c.dateStr + '_' + c.launches.length.toString())
    }
    .width('100%')
  }

  build() {
    Column() {
      this.headBar()
      this.weekBar()

      // 固定 6 行 × 7 列：不同月份高度一致，切月不跳动
      Column() {
        ForEach(this.rowIndexes, (r: number) => {
          this.weekRow(r)
        }, (r: number) => 'row_' + r.toString())
      }
      .width('100%')
    }
    .width('100%')
    .padding(CAL_PAD)
    .backgroundColor(CAL_BG)
    .borderRadius(10)
    .border({ width: 0.5, color: CAL_BORDER })
    // width 只写百分比、不写死 vp：父级包一层决定实际宽度（任务书约定），
    // 而 42 格网格必须撑满可用宽度，给 0 宽度会退回内容宽度、七列等分失效
  }
}
