/**
 * view/TodayView.ets —— 「今日」tab
 *
 * 第一阶段只做**最核心的一块：即将发射列表**，把数据链路跑通。
 * 刻意没做的（第二阶段补，不要以为是漏了）：
 *   每日一图（APOD）/ 每日地球（EPIC）/ 此刻在天上（astronautsInspace）/
 *   往年今日（onthisday）/ 下次发射大卡 + 秒级倒计时。
 * 原项目 today.vue 这些块各自还有独立的加载态、空态、点击跳转，
 * 一次性全做进来会让「数据链路是否真的通」这个验证目标失焦。
 *
 * 数据链路（与 utils/data.js 的语义逐条对齐）：
 *   repo.load('upcoming', { onCache, onUpdate })
 *     ├─ onCache  → 有 L2 文件缓存就立刻吐出来，首屏不等网络（★ 立刻撤 loading）
 *     ├─ onUpdate → 后台刷新且 generatedAt 变了才回调，静默回填不打断滚动
 *     └─ finally  → 无论走哪条路，结束时都要撤 loading
 *   弱网 + 无缓存时 load() 是 **reject**，所以必须有 catch 兜到错误态；
 *   但「已有缓存时网络失败」Repository 内部会静默 resolve 缓存，不会走到 catch。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { repo, LoadOptions } from '../data/Repository';
import { UpcomingPayload, LaunchSummary } from '../model/Launch';
import {
  strOf, parseTime, relativeTime, formatLaunchTime, formatGeneratedAt, todayLabel,
  statusOf, statusToneColor, statusToneBg,
  missionLabelOf, rocketLabelOf, providerLabelOf, orbitLabelOf, compareByNet
} from '../utils/Format';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'TodayView';

/** 第一阶段列表上限。100 条全画出来既没必要也伤滚动性能，先给 20 条 */
const LIST_LIMIT: number = 20;
/** 刚发射/推迟中的任务仍值得留在列表里，往前留 3 小时的余量 */
const KEEP_PAST_MS: number = 3 * 3600 * 1000;

@Component
export struct TodayView {
  /** 已经排好序、过滤好的展示列表（不是原始 payload.list） */
  @State items: LaunchSummary[] = [];
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State errorText: string = '';
  /** ISO 串，页脚显示「数据更新于 HH:mm」 */
  @State generatedAt: string = '';
  /** 全量待发总数（payload.count），说明「还有更多」 */
  @State totalCount: number = 0;

  aboutToAppear(): void {
    this.loadData(false);
  }

  /**
   * 把 payload 转成展示列表。
   *
   * 为什么不在 build() 里现算：build 可能因为任意 @State 变化被反复执行，
   * 20 条 × 每次 build 排一次序纯属浪费；而且 Dart 式的「渲染期计算」
   * 在 ArkUI 里会让 diff 更抖。数据一变就重算一次，存在 items 上。
   */
  private applyPayload(data: UpcomingPayload): void {
    // data.list 在接口里是非可选的，但磁盘上可能是旧版本 payload，
    // 用长度判断代替 undefined 比较（ArkTS 下对非可选类型做 === undefined
    // 会被判为「不可能相等」而报错）
    const raw: LaunchSummary[] = data.list;
    if (raw === null || raw.length === 0) {
      this.items = [];
      this.generatedAt = strOf(data.generatedAt);
      this.totalCount = data.count !== undefined && data.count !== null ? data.count : 0;
      return;
    }
    const now: number = Date.now();
    const kept: LaunchSummary[] = [];
    for (let i = 0; i < raw.length; i++) {
      const it: LaunchSummary = raw[i];
      const t: number = parseTime(strOf(it.net));
      // 时间解析不出来的一律不进列表：卡片上「时间待定」的条目
      // 排在哪都是错的（原项目 today 页也只取有 net 的）
      if (t <= 0) {
        continue;
      }
      if (t < now - KEEP_PAST_MS) {
        continue;
      }
      kept.push(it);
    }
    // 包一层箭头函数而不是直接传 compareByNet：sort 的回调签名是
    // (a: T, b: T) => number，显式写出来类型最稳，也便于将来换成别的排序键
    kept.sort((a: LaunchSummary, b: LaunchSummary) => compareByNet(a, b));

    this.items = kept.length > LIST_LIMIT ? kept.slice(0, LIST_LIMIT) : kept;
    this.generatedAt = strOf(data.generatedAt);
    this.totalCount = data.count !== undefined && data.count !== null ? data.count : 0;
  }

  /**
   * 加载数据的入口。
   *
   * 用 async/await + try/finally 而不是 .then().catch().finally()：
   * ArkTS 的 Promise 声明来自 ES2017 lib，finally 虽然在多数运行时可用，
   * 但工程 tsconfig 的 target 未必含它；await 写法零歧义，且异常/收尾分离得更清楚。
   */
  private async loadData(force: boolean): Promise<void> {
    // 只有「手上没数据」时才显示骨架屏；已有内容时后台刷新不许把列表换成骨架
    if (this.items.length === 0) {
      this.loading = true;
    }
    this.errorText = '';

    const opts: LoadOptions<UpcomingPayload> = {
      force: force,
      onCache: (data: UpcomingPayload, ageMs: number) => {
        this.applyPayload(data);
        // ★ 缓存命中立刻撤 loading：冷启动的体感「秒开」全靠这一行
        this.loading = false;
        hilog.debug(DOMAIN, TAG, 'cache hit, age=%{public}dms', ageMs);
      },
      onUpdate: (data: UpcomingPayload) => {
        this.applyPayload(data);
      }
    };

    try {
      const data: UpcomingPayload = await repo.load<UpcomingPayload>('upcoming', opts);
      // onCache 可能已经填过一份了，这里再填一次是幂等的
      this.applyPayload(data);
    } catch (e) {
      // 有缓存时走不到这里（Repository 会静默 resolve 旧缓存），
      // 所以只有「彻底没数据」才会显示错误态
      const err = e as Error;
      if (this.items.length === 0) {
        this.errorText = err.message;
      }
      hilog.warn(DOMAIN, TAG, 'load upcoming failed: %{public}s', err.message);
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  // ============ 骨架屏 ============

  @Builder
  skeletonCard() {
    Column() {
      Row() {
        // 占位色块用中性灰，不要用发光色，否则骨架期看起来像加载完的标题。
        // 用 Row 而不是 Blank 画色块：Blank 的主轴行为是「自动撑满」，
        // 给它定宽不够直观，换成普通容器最稳
        Row()
          .width('62%')
          .height(15)
          .backgroundColor('#1A2436')
          .borderRadius(4)
        Blank()
          .layoutWeight(1)
        Row()
          .width(52)
          .height(18)
          .backgroundColor('#1A2436')
          .borderRadius(4)
      }
      .width('100%')

      Row()
        .width('42%')
        .height(13)
        .backgroundColor('#1A2436')
        .borderRadius(4)
        .margin({ top: 12 })

      Row() {
        Row()
          .width(90)
          .height(11)
          .backgroundColor('#161E2C')
          .borderRadius(4)
        Blank()
          .layoutWeight(1)
        Row()
          .width(64)
          .height(11)
          .backgroundColor('#161E2C')
          .borderRadius(4)
      }
      .width('100%')
      .margin({ top: 14 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#141A26')
    .borderRadius(12)
    .border({ width: 1, color: '#0DFFFFFF' })
    .margin({ bottom: 10 })
  }

  @Builder
  skeletonList() {
    Column() {
      this.skeletonCard()
      this.skeletonCard()
      this.skeletonCard()
      this.skeletonCard()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4 })
  }

  // ============ 错误态 ============

  @Builder
  errorBlock() {
    Column() {
      Text('暂时拿不到数据')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
      Text(this.errorText.length > 0 ? this.errorText : '网络似乎不太顺畅')
        .fontSize(12)
        .fontColor('#7A8598')
        .margin({ top: 8 })
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('点此重试')
        .fontSize(13)
        .fontColor('#38BDF8')
        .margin({ top: 18 })
        .padding({ left: 20, right: 20, top: 8, bottom: 8 })
        .borderRadius(16)
        .backgroundColor('#2638BDF8')
        .onClick(() => {
          this.loadData(true);
        })
    }
    .width('100%')
    .padding({ left: 32, right: 32, top: 80 })
    .alignItems(HorizontalAlign.Center)
  }

  // ============ 空态 ============

  @Builder
  emptyBlock() {
    Column() {
      Text('暂无即将发射的任务')
        .fontSize(14)
        .fontColor('#7A8598')
      Text('数据每 15 分钟自动更新一次')
        .fontSize(11)
        .fontColor('#55617A')
        .margin({ top: 8 })
    }
    .width('100%')
    .padding({ top: 80 })
    .alignItems(HorizontalAlign.Center)
  }

  // ============ 顶部标题 ============

  @Builder
  header() {
    Column() {
      Row() {
        Column() {
          // 对位 today.vue 的 .nav-date：38rpx→19vp、600、letter-spacing 1
          Text(todayLabel())
            .fontSize(19)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .letterSpacing(1)
          Text(this.subtitleText())
            .fontSize(11)
            .fontColor('#6B7891')
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 总数徽标：让「列表只有 20 条」这件事有出处，不是被截断了却不说
        if (this.totalCount > 0) {
          Text(String(this.totalCount) + ' 场')
            .fontSize(11)
            .fontColor('#38BDF8')
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(8)
            .backgroundColor('#1F38BDF8')
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  private subtitleText(): string {
    if (this.loading) {
      return '正在获取发射计划…';
    }
    if (this.items.length === 0) {
      return '即将发射';
    }
    const gen: string = formatGeneratedAt(this.generatedAt);
    return gen.length > 0 ? ('即将发射 · 更新于 ' + gen) : '即将发射';
  }

  // ============ 列表卡片 ============

  @Builder
  card(item: LaunchSummary) {
    Column() {
      // 第一行：任务名 + 状态 chip
      Row() {
        Text(missionLabelOf(item))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(statusOf(item).text)
          .fontSize(10)
          .fontColor(statusToneColor(statusOf(item).tone))
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .borderRadius(5)
          .backgroundColor(statusToneBg(statusOf(item).tone))
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 第二行：火箭型号 —— 比任务名更能让爱好者一眼认出是哪一发
      Row() {
        Text(rocketLabelOf(item))
          .fontSize(12)
          .fontColor('#A7B4C7')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 6 })

      // 第三行：发射时间（强调色）+ 倒计时（右对齐）
      Row() {
        Text(formatLaunchTime(strOf(item.net)))
          .fontSize(13)
          .fontColor('#38BDF8')
          .layoutWeight(1)
        Text(relativeTime(strOf(item.net)))
          .fontSize(12)
          .fontColor('#8A97A8')
      }
      .width('100%')
      .margin({ top: 10 })
      .alignItems(VerticalAlign.Center)

      // 第四行：机构 · 轨道（都可能缺，缺一个就只显示一个）
      Row() {
        Text(this.metaText(item))
          .fontSize(11)
          .fontColor('#5D6A7D')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor('#141A26')
    .borderRadius(12)
    // 对位 launch-card 的 border: 1rpx solid rgba(255,255,255,0.05)
    .border({ width: 1, color: '#0DFFFFFF' })
  }

  /** 「SpaceX · 近地轨道」这种省略拼接，任一侧为空就不多留分隔符 */
  private metaText(item: LaunchSummary): string {
    const p: string = providerLabelOf(item);
    const o: string = orbitLabelOf(item);
    if (p.length > 0 && o.length > 0) {
      return p + ' · ' + o;
    }
    if (p.length > 0) {
      return p;
    }
    return o;
  }

  build() {
    Column() {
      this.header()

      if (this.loading && this.items.length === 0) {
        this.skeletonList()
      } else if (this.items.length === 0) {
        // 错误优先于空态：有错就说错，不要用「暂无任务」掩盖网络失败
        if (this.errorText.length > 0) {
          this.errorBlock()
        } else {
          this.emptyBlock()
        }
      } else {
        // Refresh：下拉刷新强制回源（force=true 不走缓存也不触发 onUpdate）
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 10 }) {
            ForEach(this.items, (item: LaunchSummary) => {
              ListItem() {
                this.card(item)
              }
              .width('100%')
            }, (item: LaunchSummary) => strOf(item.id) + '_' + strOf(item.net))

            // 页脚
            ListItem() {
              Text(this.footerText())
                .fontSize(10)
                .fontColor('#3E4859')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 14, bottom: 8 })
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
        .onRefreshing(() => {
          this.loadData(true);
        })
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0a0e17')
    // ★ 92vp 底部内边距，**必须有**：
    //   FloatingTabBar 在 Index.ets 的 Stack 里是浮层，不占布局空间，
    //   所以 Tabs 的内容区一路铺到屏幕物理底部。不加这段内边距，
    //   列表最后一张卡会被胶囊压住，而且因为 List 的边界就在屏幕底，
    //   滚到底也翻不出来。92 = 胶囊 58 + 底部 margin 20 + 14 呼吸位。
    .padding({ bottom: 92 })
  }

  private footerText(): string {
    const gen: string = formatGeneratedAt(this.generatedAt);
    const n: string = String(this.items.length);
    const total: string = this.totalCount > 0 ? String(this.totalCount) : n;
    if (gen.length > 0) {
      return '显示 ' + n + ' / ' + total + ' 场 · 数据更新于 ' + gen;
    }
    return '显示 ' + n + ' / ' + total + ' 场';
  }
}
