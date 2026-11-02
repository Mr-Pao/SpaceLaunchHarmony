/**
 * components/Countdown.ets —— 发射倒计时（天 / 时 / 分 / 秒）
 *
 * 对位小程序：components/countdown/countdown.vue（171 行）
 *   template  1-16   （T- 前缀 + 四格数字 / 到点文案）
 *   script   36-104  （diff / units 计算 + setInterval + watch:net）
 *   style   107-171  （.cd / .cd-t / .cd-group / .cd-cell / .cd-num / .cd-unit / .cd-lg）
 *
 * 换算：rpx ÷ 2 = vp（750rpx 设计稿 → 375vp 宽）
 *   lg：数字 64rpx→32vp、单位 22rpx→11vp、T- 40rpx→20vp（原 vue 只有这一档）
 *   md：数字 22vp、单位 10vp（本文件新增，用于「下次发射」卡片图片底部叠层）
 *   sm：数字 16vp、单位 9vp（新增，备用）
 *
 * 有意差异（相对 countdown.vue）：
 *   1. 新增 md / sm 两档尺寸。原 vue 只有 lg。NextLaunch 的倒计时要压在
 *      150vp 高的图片底边上，32vp 的数字铺满一行后会挤掉状态 chip，所以另给中号。
 *   2. 数字的等宽感用 fontWeight(Bold) 实现，**没有**用 fontFeature('"tnum"')：
 *      后者在部分 SDK 版本上对中英混排行高处理不一致，Bold 在所有版本表现一致。
 *   3. 到点文案分两种：net 解析不出来（空串 / 非法串）→「时间待定」；
 *      解析成功但已过点 →「时间已到」。原 vue 不分这两种，一律「时间已到」，
 *      但 net 为空的卡片上写「时间已到」是错的。
 *   4. 定时器只在「没归零」时存在，归零后立刻 clearInterval（原 vue 也这么做）；
 *      aboutToDisappear 必清 —— Tabs 会保活子页，不清理就漏定时器。
 *   5. @Watch('net') 重新开表：父级异步下发 net 时，初始空串会让 start() 因
 *      ended 直接返回，没有这个 watch 就永远停在「时间待定」。
 *
 * 数据来源：utils/Format.ets 的 countdownParts()。它已经把「解析失败 / 已归零 /
 * 四段补零」全处理好了，这里不重写一份算法（重写等于把原项目的坑再踩一遍）。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { CountdownParts, countdownParts, parseTime, strOf } from '../utils/Format';

const DOMAIN: number = 0x0001;
const TAG: string = 'Countdown';

@Component
export struct Countdown {
  /** 发射时刻，ISO 8601。父级可能先给空串、数据到位后再给真值 */
  @Prop @Watch('onNetChange') net: string = '';
  /** 尺寸档位：lg（默认，今日页大卡）/ md（卡片内嵌）/ sm（极小占位） */
  @Prop size: string = 'lg';
  /** 是否显示 T- 前缀 */
  @Prop showLabel: boolean = true;

  // 四段数字拆成四个 @State string 而不是一个 CountdownParts 对象：
  // ArkUI 对自定义类实例的内部字段变动不敏感（要 @Observed 才行），
  // 而「重新赋一个新对象」又会每秒产生一次对象分配。四个基本类型最省。
  @State days: string = '00';
  @State hours: string = '00';
  @State mins: string = '00';
  @State secs: string = '00';
  /** 已到点 / 时间不可解析 → 不显示数字格，只显示 overText */
  @State ended: boolean = true;
  /** 到点后的文案：已过点「时间已到」；net 无效「时间待定」 */
  @State overText: string = '时间待定';

  /** setInterval 的句柄，-1 表示没在跑。归零或销毁时置回 -1 */
  private timerId: number = -1;

  aboutToAppear(): void {
    this.start();
  }

  /**
   * ★ 必须清：切 tab 时 Tabs 保活子页，aboutToAppear/aboutToDisappear 不会配对
   *   触发的前提是组件被销毁；只要它活着这个 1s 定时器就一直跑。
   */
  aboutToDisappear(): void {
    this.stop();
  }

  /**
   * 父级异步下发 net 时重新开表（原 vue 的 watch: { net() { this.start() } }）。
   * 注意 @Watch 只能装饰在属性上（见上面的 net），这里是它指向的回调方法，
   * **不能再加 @Watch 装饰器**，否则编译报装饰器位置非法。
   */
  onNetChange(propName: string): void {
    hilog.debug(DOMAIN, TAG, 'net 变化，重开倒计时 (%{public}s)', propName);
    this.start();
  }

  // ============ 计时 ============

  /** 用 Format.countdownParts 重新算四段，并同步到 @State */
  private refresh(): void {
    const raw: string = strOf(this.net);
    const parts: CountdownParts = countdownParts(raw);
    this.days = parts.days;
    this.hours = parts.hours;
    this.mins = parts.mins;
    this.secs = parts.secs;
    this.ended = parts.ended;
    // 解析失败（parseTime <= 0）与「已过点」是两件事，见文件头「有意差异 3」
    this.overText = parseTime(raw) <= 0 ? '时间待定' : '时间已到';
  }

  /** 先停再起，防止重复定时器（原 vue 的 start 内部先 stop 同理） */
  private start(): void {
    this.stop();
    this.refresh();
    if (this.ended) {
      return;
    }
    this.timerId = setInterval(() => {
      this.refresh();
      // 归零后立刻停表，别让定时器在后台空转
      if (this.ended) {
        hilog.debug(DOMAIN, TAG, '倒计时归零，停表 net=%{public}s', this.net);
        this.stop();
      }
    }, 1000);
  }

  private stop(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  // ============ 尺寸档位（rpx ÷ 2） ============

  private numSize(): number {
    if (this.size === 'sm') {
      return 16;
    }
    if (this.size === 'md') {
      return 22;
    }
    return 32; // 64rpx ÷ 2
  }

  private unitSize(): number {
    if (this.size === 'sm') {
      return 9;
    }
    if (this.size === 'md') {
      return 10;
    }
    return 11; // 22rpx ÷ 2
  }

  private labelSize(): number {
    if (this.size === 'sm') {
      return 12;
    }
    if (this.size === 'md') {
      return 15;
    }
    return 20; // 40rpx ÷ 2
  }

  private overSize(): number {
    if (this.size === 'sm') {
      return 13;
    }
    if (this.size === 'md') {
      return 16;
    }
    return 22; // 44rpx ÷ 2
  }

  /** T- 前缀相对数字顶部的偏移：对位 .cd-lg .cd-t { margin-top: 12rpx } */
  private labelTop(): number {
    if (this.size === 'sm') {
      return 0;
    }
    if (this.size === 'md') {
      return 2;
    }
    return 6;
  }

  // ============ 渲染 ============

  /** 一格：数字在上、单位在下，居中（对位 .cd-cell 的 flex-direction: column） */
  @Builder
  numCell(value: string, label: string) {
    Column() {
      Text(value)
        .fontSize(this.numSize())
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .maxLines(1)
      Text(label)
        .fontSize(this.unitSize())
        .fontColor('#6B7891')
        .maxLines(1)
        .margin({ top: 2 })
    }
    // 四格均分整行（原 vue .cd-cell { flex: 1 }）
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Row() {
      if (this.showLabel) {
        Text('T-')
          .fontSize(this.labelSize())
          .fontWeight(FontWeight.Bold)
          .fontColor('#38BDF8')
          .maxLines(1)
          .margin({ right: this.size === 'sm' ? 2 : 4, top: this.labelTop() })
      }

      if (this.ended) {
        // 到点 / 时间不可解析：一排数字全部退场，只留一句文案
        Text(this.overText)
          .fontSize(this.overSize())
          .fontWeight(FontWeight.Bold)
          .fontColor('#38BDF8')
          .layoutWeight(1)
          .maxLines(1)
      } else {
        Row() {
          this.numCell(this.days, '天')
          this.numCell(this.hours, '时')
          this.numCell(this.mins, '分')
          this.numCell(this.secs, '秒')
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
      }
    }
    .width('100%')
    // 原 vue 是 align-items: flex-start：数字不同行高时顶部对齐，不是垂直居中
    .alignItems(VerticalAlign.Top)
  }
}
