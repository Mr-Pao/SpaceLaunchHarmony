/**
 * view/VersionView.ets —— 「版本记录」页
 *
 * 契约：`@Component export struct VersionView { }`（无入参，由路由侧直接挂到 NavDestination）。
 * 对位小程序 `pages/version/version.vue`（202 行）：顶栏 → 页头 → 时间线卡片 → 页脚。
 *
 * ── 数据是编译期常量，不走 repo/网络 ──
 *   CHANGELOG 全部写在 constants/Changelog.ets 里，98 条、零请求。
 *   所以本页**没有** loading / failed / 空态三件套：没有异步就永远不会有中间态，
 *   加那种状态机只会让代码看起来像在等什么。唯一可能是数组为空（理论上不会），
 *   此时 currentVersion() 返回 '—'，页面照常渲染页头，时间线为空。
 *
 * ── 顺序为什么在这里反转，而不是在数据层 ──
 *   CHANGELOG 保持「旧在前、新在末尾」，与小程序 `utils/changelog.js` 逐条对齐，
 *   这样两个仓库的末条永远能对拍（小程序拿末条比 manifest.versionName）。
 *   「新在上」是**展示**需求，所以在 aboutToAppear 里 `slice().reverse()`：
 *     · slice() 先复制一层 —— 直接 CHANGELOG.reverse() 会就地改掉全局常量，
 *       页面重建一次顺序就翻回去，而且别的页面（如「我的」）读到的是被翻过的数组；
 *     · 只在 aboutToAppear 做一次，不在 build 里做 —— build 每次重绘都会跑，
 *       在里面 reverse 等于每帧翻一次，画面会来回跳。
 *
 * ── 竖线为什么用 border 而不是 Column().width(1) ──
 *   设计要求是「左侧一条 1vp 竖线」。这里**没有**用 `Column().width(1).backgroundColor()`：
 *   本页根是 Scroll，时间线的高度完全由内容撑开，`height('100%')` 在没有定高父容器时
 *   会塌成 0（ArkTS 的百分比只对定尺寸父组件有意义），线会整条消失。
 *   改用每条记录的 `border({ width: { left: 1 } })`：边框一定跟随元素自身高度，
 *   而每条记录的底部留白 12 算在 padding 里（不是 margin），所以相邻两条的边框首尾相接，
 *   整条时间线在视觉上是连续的一根线，且 98 条记录无论文字折几行都不会断。
 *   圆点用 offset 往左挪半个直径，让圆心正好压在线上。
 *
 * ⚠ 本文件不使用 console.*，也没有需要打日志的分支。
 */

import { Nav } from '../routes/Nav';
import { CHANGELOG, ChangelogEntry, currentVersion } from '../constants/Changelog';

// ============ 视觉常量（工程约定） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
/** 页头副标题「当前版本 x.y.z」用的辅助灰，比 TEXT_DIM 亮一档 */
const TEXT_LABEL: string = '#6B7891';
const ACCENT: string = '#38BDF8';
/** 时间线竖线：比卡片底色略亮一点，能看见但不抢内容 */
const LINE: string = '#1E2836';
/** 非最新一条的圆点，暗到只起「这里有个节点」的作用 */
const DOT_DIM: string = '#2A3547';
/** 非最新一条的版本号 */
const VERSION_DIM: string = '#A7B4C7';

/** 页面左右留白；底部 32 是本工程二级页的统一留白（见 FavoritesView 同类注释） */
const PAGE_PAD: number = 12;
const BOTTOM_PAD: number = 32;
/** 时间线轨道宽度：线 + 线到卡片的间距 */
const RAIL_W: number = 22;
/** 记录之间的空隙；算在 padding 里，竖线才能连续 */
const ENTRY_GAP: number = 12;

@Component
export struct VersionView {
  /**
   * 新 → 旧的展示副本。用 @State 而不是局部变量：万一将来要从别处推数据进来，
   * 状态通道已经在了；当前只在 aboutToAppear 赋值一次。
   */
  @State entries: ChangelogEntry[] = [];

  aboutToAppear(): void {
    // slice() 复制后反转：绝不就地翻全局常量（见文件头）
    this.entries = CHANGELOG.slice().reverse();
  }

  // ============ 顶栏 ============

  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹').fontSize(20).fontColor(TEXT_MAIN).lineHeight(20)
        Text('返回').fontSize(14).fontColor(TEXT_SUB).margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Center)
      // 点击热区比文字大一圈，拇指不容易点偏
      .padding({ right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        Nav.pop();
      })

      Text('版本记录')
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor(TEXT_MAIN)
        .maxLines(1)

      // 标题不设 layoutWeight：让 Blank 独占剩余空间，标题就不会被拉长到出现点击热区
      Blank()
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  // ============ 页头 ============

  @Builder
  headerBlock() {
    Column() {
      Text('版本记录')
        .fontSize(22).fontWeight(FontWeight.Bold).fontColor(TEXT_MAIN)
        .width('100%')

      Text('当前版本 ' + currentVersion())
        .fontSize(11.5).fontColor(TEXT_LABEL)
        .width('100%')
        .margin({ top: 6 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // 上留白给顶栏喘口气，下留白把页头和时间线拉开层级
    .padding({ top: 10, bottom: 18 })
  }

  // ============ 时间线 ============

  /**
   * 圆点。最新一条（列表第 0 条）大一圈、用强调色，其余暗灰小点。
   *
   * 定位算法：
   *   · x 方向 —— ArkUI 的边框画在组件自身尺寸内、不占子节点布局，所以子节点仍从 x=0 起排，
   *     那条 1vp 线覆盖 x∈[0,1]、中线在 0.5。圆点左移 (半径 − 0.5)
   *     （4.5 / 3.5），圆心正好落在 x=0.5 的线中；
   *   · y 方向 —— 卡片 padding 是 14，版本号 13.5vp Bold 的行盒约 19vp，
   *     行盒中心在 14 + 9.5 = 23.5，所以 10vp 的圆心要放在 18.5、8vp 的放在 19.5，
   *     两种直径的圆心都落在 23.5，视觉上圆点高度一致。
   */
  @Builder
  railDot(latest: boolean) {
    Text('')
      .width(latest ? 10 : 8)
      .height(latest ? 10 : 8)
      .borderRadius(latest ? 5 : 4)
      .backgroundColor(latest ? ACCENT : DOT_DIM)
      .offset({ x: latest ? -4.5 : -3.5, y: latest ? 18.5 : 19.5 })
  }

  @Builder
  versionBlock(row: ChangelogEntry, latest: boolean) {
    Column() {
      // 版本号与日期同一行：都靠左，日期紧跟版本号（不推到右边，
      // 因为右侧没有别的元素，推过去只会让「3.3.1 …… 2026-10-31」中间空一大片）
      Row() {
        Text('v' + row.version)
          .fontSize(13.5)
          .fontWeight(FontWeight.Bold)
          .fontColor(latest ? ACCENT : VERSION_DIM)
        Text(row.date)
          .fontSize(11)
          .fontColor(TEXT_DIM)
          .margin({ left: 8 })
        Blank()
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(row.title)
        .fontSize(14.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_MAIN)
        .width('100%')
        .margin({ top: 6 })

      Column() {
        ForEach(row.items, (line: string) => {
          Row() {
            Text('·')
              .fontSize(12.5)
              .fontColor(ACCENT)
              // 12.5 × 1.55 = 19.375：与正文同高，首行才能和正文对齐
              .lineHeight(19.375)
              .margin({ right: 6 })
            Text(line)
              .fontSize(12.5)
              .fontColor(TEXT_SUB)
              .lineHeight(19.375)
              .layoutWeight(1)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ bottom: 6 })
        }, (line: string, idx: number) => String(idx) + '|' + line)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ top: 10 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(CARD_BG)
    .borderRadius(12)
  }

  @Builder
  entry(row: ChangelogEntry, index: number) {
    // 竖线 = 这一条记录的左边框；底部的 12 空隙放在 padding 里，两条之间线才连得上
    Stack({ alignContent: Alignment.TopStart }) {
      this.railDot(index === 0)
      Column() {
        this.versionBlock(row, index === 0)
      }
      .width('100%')
      .padding({ left: RAIL_W, bottom: ENTRY_GAP })
    }
    .width('100%')
    .border({ width: { left: 1 }, color: LINE })
  }

  // ============ 页脚 ============

  @Builder
  footerBlock() {
    Text('数据来源 The Space Devs · 每日自动同步')
      .fontSize(11)
      .fontColor(TEXT_DIM)
      .width('100%')
      .textAlign(TextAlign.Center)
      .margin({ top: 18 })
  }

  @Builder
  content() {
    Column() {
      this.headerBlock()

      Column() {
        ForEach(this.entries, (row: ChangelogEntry, index: number) => {
          this.entry(row, index)
        }, (row: ChangelogEntry) => row.version)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      this.footerBlock()
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    // 外层 Stack 只做一件事：让顶栏和滚动区在同一个坐标系里，
    // 顶栏不参与滚动（Scroll 只包内容），后续要加吸顶渐隐遮罩也有地方挂。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.topBar()

        Scroll() {
          this.content()
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
      .backgroundColor(BG_PRIMARY)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }
}
