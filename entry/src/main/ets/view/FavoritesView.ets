/**
 * 收藏列表页。
 *
 * 骨架照 `view/NewsListView.ets`：顶部返回条 + 标题 + 一行小字副标题 + List。
 * 不铺 StarField：本页是纯清单，背景加了星空会让卡片边界糊掉。
 *
 * 收藏里存的是精简字段（见 data/Favorites.ets），要显示成卡片就得**临时拼**
 * 一个 LaunchSummary。这里每一层都显式标注 interface 类型再赋值，
 * 因为 ArkTS 禁无类型对象字面量，嵌套层没有上下文类型时会报错。
 */

import { common } from '@kit.AbilityKit';
import { LaunchSummary, LaunchMission, LaunchRocket, RocketConfig, LaunchPad, PadLocation } from '../model/Common';
import { LaunchCard } from '../components/LaunchCard';
import { Nav } from '../routes/Nav';
import { LaunchNavParam } from '../routes/NavParam';
import {
  FavItem, favInit, favList, favRemove, FAV_VERSION_KEY
} from '../data/Favorites';

const BG_PRIMARY: string = '#0A0E17';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const DANGER: string = '#F87171';
const PAGE_PAD: number = 12;
const BOTTOM_PAD: number = 120;

/**
 * 把一条精简收藏拼成卡片能吃的 LaunchSummary。
 *
 * 只填 LaunchCard 真正会读的字段：
 *   - `mission.name` → 卡片主标题（missionLabelOf 的首选）
 *   - `rocket.configuration.name` → 火箭行
 *   - `pad.location.name` → 场地行（注意 placeLabelOf 读的是 location.name，
 *     只填 pad.name 等于没填，两处都给同一个值）
 *   - `image` → 头图
 * 其余字段留空：卡片对 undefined 全部判空，不会崩也不会显示空占位。
 */
function toSummary(fav: FavItem): LaunchSummary {
  const mission: LaunchMission = { name: fav.title };
  const config: RocketConfig = { name: fav.rocketName };
  const rocket: LaunchRocket = { configuration: config };
  const loc: PadLocation = { name: fav.siteName };
  const pad: LaunchPad = { name: fav.siteName, location: loc };
  const summary: LaunchSummary = {
    id: fav.id,
    name: fav.title,
    net: fav.net,
    image: fav.image,
    imageThumb: fav.image,
    mission: mission,
    rocket: rocket,
    pad: pad
  };
  return summary;
}

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
    return '共 ' + String(this.list.length) + ' 条 · 数据存在本机';
  }

  /** 长按删除：先弹确认，避免误触把收藏清了找不回来。 */
  private askRemove(fav: FavItem): void {
    const name: string = fav.title.length > 0 ? fav.title : (fav.net.length > 0 ? fav.net : '这条发射');
    AlertDialog.show({
      title: '取消收藏',
      message: '把「' + name + '」从收藏里移除？',
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
      .fontSize(11).fontColor('#6B7891').width('100%').maxLines(1)
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

  @Builder
  row(fav: FavItem) {
    Column() {
      LaunchCard({
        item: toSummary(fav),
        live: false,
        onSelect: (picked: LaunchSummary) => {
          const target: LaunchNavParam = new LaunchNavParam(picked.id, picked.net, fav.title);
          Nav.pushLaunch(target);
        }
      })
      // 长按删除：卡片自己只负责点击进详情，删除手势挂在外层，
      // 免得去改 LaunchCard（它不属于本次允许修改的文件）。
      .gesture(
        LongPressGesture({ repeat: false, duration: 600 })
          .onAction(() => {
            this.askRemove(fav);
          })
      )
    }
    .width('100%')
  }

  build() {
    Column() {
      this.topBar()
      this.subHeader()
      if (this.list.length === 0) {
        this.emptyBlock()
      } else {
        List() {
          ForEach(this.list, (fav: FavItem) => {
            ListItem() {
              this.row(fav)
            }.padding({ bottom: 10 })
          }, (fav: FavItem) => fav.id)
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
