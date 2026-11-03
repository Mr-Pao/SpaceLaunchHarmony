/**
 * view/FavoritesView.ets —— 收藏的发射清单
 *
 * 对位小程序 pages/mine/mine.vue 里「我的收藏」那一段的 `.rows > .row`：
 *   row  padding 20rpx 24rpx = 10/12vp，行内三段 —— 48vp 图（radius 7）/
 *   标题 14vp w500 #e2e8f0 两行截断 + meta 11.5vp #6b7891 单行省略 / 「›」16vp #3d4a5c
 *
 * ── 为什么从 LaunchCard 换成小行 ──
 * 小程序**没有独立收藏页**：收藏只在「我的」里露 5 条小行，点某一行直接进发射详情。
 * 鸿蒙原来拿 LaunchCard 大卡（带倒计时条、机构行、场地行）渲染，一屏只能放 3 条，
 * 与「我的」里那一段的视觉语言完全不是一套。这里按小行重做，两处看起来才是同一个清单。
 *
 * ── 保留的鸿蒙增量 ──
 * 长按 600ms 弹「取消收藏」。小程序只能在详情页再点一次 ☆，而鸿蒙这一页是独立页面、
 * 从「我的 → 全部」进来后没有任何取消入口，不给删除就等于把收藏变成单向。这是**有意保留**。
 *
 * ── 一处字段差异（改不动）──
 * 小程序行第三段是 `formatShort · relativeTime · status(成功/进行中/待定)`；
 * 鸿蒙 data/Favorites.ets 的 FavItem 没有 status 快照（存的是 id/net/title/rocketName/
 * image/siteName/savedAt），这里第三段显示「火箭型号，没有则场地」。
 * 「我的」页那一份行（MineView.favMeta）能显示真状态，因为它额外用 id 去
 * upcoming/previous 现查了一遍；本页有意不做同样的查询 —— 收藏清单里可能有
 * 早已滚出两个窗口的老发射，一半有状态一半没状态比统一显示型号更参差。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { common } from '@kit.AbilityKit';
import { Nav } from '../routes/Nav';
import { LaunchNavParam } from '../routes/NavParam';
import { formatShort, relativeTime } from '../utils/Format';
import { FavItem, favInit, favList, favRemove, FAV_VERSION_KEY } from '../data/Favorites';

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const CARD_BORDER: string = '#0DFFFFFF';
const ROW_TITLE: string = '#E2E8F0';
const TEXT_LABEL: string = '#6B7891';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const ARROW: string = '#3D4A5C';
const DANGER: string = '#F87171';
const IMG_BG: string = '#0F1520';

const PAGE_PAD: number = 12;
/** 行内图片 96rpx = 48vp（小程序 .row-img） */
const ROW_IMG: number = 48;
const BOTTOM_PAD: number = 32;

@Component
export struct FavoritesView {
  @State list: FavItem[] = [];
  /**
   * 订阅收藏版本号：详情页点星标、本页长按删，都会让它 +1。
   *
   * 为什么不用 aboutToAppear 之外的办法刷新：本页虽然会被 push/pop，
   * 但如果用户在详情页收藏后再退回本页，组件是复用的，
   * 只有全局版本号能把变化推进来。
   */
  @StorageProp(FAV_VERSION_KEY) @Watch('onFavChanged') favVersion: number = 0;

  aboutToAppear(): void {
    const ctx: common.Context | undefined = this.getUIContext().getHostContext();
    if (ctx !== undefined) {
      favInit(ctx);
    }
    this.reload();
  }

  /** 版本号一变就地重读，不用等页面重建。形参由 @Watch 框架传入，必须留着。 */
  onFavChanged(propName: string): void {
    this.reload();
  }

  private reload(): void {
    this.list = favList();
  }

  private countText(): string {
    return '共 ' + String(this.list.length) + ' 条';
  }

  /** 行标题：任务名优先，没有就退回火箭型号，再不行给诚实占位 */
  private rowTitle(fav: FavItem): string {
    if (fav.title.length > 0) {
      return fav.title;
    }
    if (fav.rocketName.length > 0) {
      return fav.rocketName;
    }
    return '未命名任务';
  }

  /**
   * 行副标题：短时间 · 相对时间 · 火箭型号（没有则场地）。
   * 用数组 join 而不是拼接：某一项为空时不会留下孤零零的「 · 」。
   */
  private rowMeta(fav: FavItem): string {
    const parts: string[] = [];
    const t: string = formatShort(fav.net);
    if (t.length > 0) {
      parts.push(t);
    }
    const rel: string = relativeTime(fav.net);
    if (rel.length > 0 && rel !== t) {
      parts.push(rel);
    }
    if (fav.rocketName.length > 0) {
      parts.push(fav.rocketName);
    } else if (fav.siteName.length > 0) {
      parts.push(fav.siteName);
    }
    return parts.join(' · ');
  }

  private openLaunch(fav: FavItem): void {
    Nav.pushLaunch(new LaunchNavParam(fav.id, fav.net, this.rowTitle(fav)));
  }

  /** 长按删除：先弹确认，避免误触把收藏清了找不回来。 */
  private askRemove(fav: FavItem): void {
    AlertDialog.show({
      title: '取消收藏',
      message: '把「' + this.rowTitle(fav) + '」从收藏里移除？',
      autoCancel: true,
      primaryButton: {
        value: '留着',
        action: () => {
        }
      },
      secondaryButton: {
        value: '移除',
        fontColor: DANGER,
        action: () => {
          favRemove(fav.id);
          // favRemove 内部会 bumpVersion 触发 onFavChanged，
          // 这里不直接改 this.list：单一数据源，免得两处状态不一致。
        }
      }
    });
  }

  // ============ UI ============

  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹').fontSize(20).fontColor(TEXT_MAIN).lineHeight(20)
        Text('返回').fontSize(14).fontColor(TEXT_SUB).margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Center)
      .padding({ right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        Nav.pop();
      })

      Text('我的收藏')
        .fontSize(19).fontWeight(FontWeight.Bold).fontColor(TEXT_MAIN)
        .maxLines(1).layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .backgroundColor(BG_PRIMARY)
  }

  @Builder
  subHeader() {
    Text(this.countText())
      .fontSize(11).fontColor(TEXT_LABEL).width('100%').maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ bottom: 10 })
  }

  @Builder
  emptyBlock() {
    Column() {
      Text('☆').fontSize(34).fontColor(TEXT_DIM)
      Text('还没有收藏')
        .fontSize(13).fontColor(TEXT_SUB).margin({ top: 12 })
      Text('在发射详情页点右上角 ☆ 收藏')
        .fontSize(11).fontColor(TEXT_DIM).margin({ top: 6 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 清单行。结构与小程序 mine.vue 的 `.row` 一模一样：
   * 图 / (标题 + 副标题) / 「›」，只有这三段。
   */
  @Builder
  row(fav: FavItem) {
    Row() {
      if (fav.image.length > 0) {
        Image(fav.image)
          .width(ROW_IMG)
          .height(ROW_IMG)
          .borderRadius(7)
          .objectFit(ImageFit.Cover)
          .backgroundColor(IMG_BG)
      } else {
        // 无图占位：小程序 .row-ph 是渐变底 + 🚀，这里同样不画破图
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .linearGradient({
              angle: 135,
              colors: [['#141C28', 0.0], ['#0E1520', 1.0]]
            })
          Text('🚀').fontSize(22).opacity(0.45)
        }
        .width(ROW_IMG)
        .height(ROW_IMG)
        .borderRadius(7)
        .clip(true)
      }

      Column() {
        Text(this.rowTitle(fav))
          .width('100%')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(ROW_TITLE)
          .lineHeight(19.6)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.rowMeta(fav))
          .width('100%')
          .fontSize(11.5)
          .fontColor(TEXT_LABEL)
          .margin({ top: 4 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 9, right: 9 })
      .clip(true)

      Text('›')
        .fontSize(16)
        .fontColor(ARROW)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10, left: 12, right: 12 })
    .onClick(() => {
      this.openLaunch(fav);
    })
    // 长按删除挂在整个行上：行是自己画的，不用去改 LaunchCard（它不属于本次可改文件）
    .gesture(
      LongPressGesture({ repeat: false, duration: 600 })
        .onAction(() => {
          this.askRemove(fav);
        })
    )
  }

  build() {
    Column() {
      this.topBar()
      this.subHeader()
      if (this.list.length === 0) {
        this.emptyBlock()
      } else {
        List() {
          ListItem() {
            Column() {
              ForEach(this.list, (fav: FavItem, idx: number) => {
                // 每个 item 只给一个根（Column 包住 分割线 + 行）：
                // ForEach 的 item 多根节点在部分 SDK 上会漏掉 key 复用
                Column() {
                  if (idx > 0) {
                    Divider()
                      .color('#0BFFFFFF')
                      .strokeWidth(1)
                      .margin({ left: 12, right: 12 })
                  }
                  this.row(fav)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
              }, (fav: FavItem) => fav.id)
            }
            .width('100%')
            .backgroundColor(CARD_BG)
            .borderRadius(11)
            .border({ width: 1, color: CARD_BORDER })
            .clip(true)
          }
          .padding({ bottom: 10 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(3)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD, bottom: BOTTOM_PAD })
    .backgroundColor(BG_PRIMARY)
    .alignItems(HorizontalAlign.Start)
  }
}
