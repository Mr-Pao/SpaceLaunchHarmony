/**
 * 型号媒体库（图片库 / 视频库）
 *
 * 1:1 复刻小程序 pages/media/media.vue。
 * 小程序入口：components/launch-detail/launch-hero.vue:152 与 pages/rocket/rocket.vue:915
 * 的 goMedia(tab)，传 config.id；鸿蒙侧改用型号名，因为 RocketNavParam 只有 name。
 *
 * 取数口径与小程序一致：launchers 找当前构型 → 按 seriesKey 取同系列 → 并行拉
 * previous / upcoming / videos → videos 按 row.id 回填到发射记录的 vid → collectMedia。
 * 之所以不在本页拼图，是因为 collectMedia 已把顺序、去重、截断全定死，页面只负责铺。
 */

import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { repo } from '../data/Repository';
import { Nav } from '../routes/Nav';
import { PhotoNavParam } from '../routes/NavParam';
import { LaunchPad, LaunchSummary, RocketConfig } from '../model/Common';
import { PreviousPayload, UpcomingPayload } from '../model/Launch';
import { VideoItem, VideosPayload, VideoRef } from '../model/Video';
import { collectMedia, MdConfigRec, MdLaunchRec, MdMedia, MdPadRec, MdShot, MdVideo, MdVideoRef } from '../utils/Media';
import { rocketName, seriesKey, seriesName, strOf } from '../utils/Format';

const DOMAIN: number = 0x0A07;
const TAG: string = 'MediaView';

const BG: string = '#0A0E17';
const CARD_BG: string = '#131A26';
const TOP_BAR_BG: string = '#F50A0E17';
const DIVIDER: string = '#0DFFFFFF';
const HL: string = '#38BDF8';
const TEXT_TITLE: string = '#E2E8F0';
const TEXT_META: string = '#7D8BA0';
const TEXT_DIM: string = '#4D5A6E';
const TEXT_EMPTY: string = '#8B95A8';
const TEXT_EMPTY_SUB: string = '#4D5A6E';
const TEXT_HINT: string = '#6B7891';

/** 图片卡高度基准：两列各占半屏，176 是 375 宽下实际列宽的近似值 */
const SHOT_BASE: number = 176;
/** 视频封面高度，对应小程序 220rpx */
const VIDEO_COVER_H: number = 110;

/** launchers.json 的单条构型（全封套里只用到媒体相关的几项） */
interface MdLauncher {
  id?: number;
  name?: string;
  full_name?: string;
  variant?: string;
  families?: string[];
  image?: string;
}

interface MdLauncherPayload {
  list?: MdLauncher[];
}

@Component
export struct MediaView {
  @Prop configName: string = '';
  @Prop startTab: number = 0;

  @State tab: number = 0;
  @State loading: boolean = true;
  @State found: boolean = true;
  @State pageTitle: string = '图片库';
  @State images: MdShot[] = [];
  @State videos: MdVideo[] = [];
  @State truncated: boolean = false;
  @State colLeft: MdShot[] = [];
  @State colRight: MdShot[] = [];
  @State vcolLeft: MdVideo[] = [];
  @State vcolRight: MdVideo[] = [];
  @State playingUrl: string = '';
  @State playingTitle: string = '';

  private scroller: Scroller = new Scroller();
  /** 全量大数组放普通成员，@State 只放上屏那一份 */
  private seriesConfigs: MdConfigRec[] = [];
  private launchRecs: MdLaunchRec[] = [];

  aboutToAppear(): void {
    this.tab = this.startTab === 1 ? 1 : 0;
    this.loadAll();
  }

  // ---------------------------------------------------------------- 取数

  private async loadAll(): Promise<void> {
    let launchers: MdLauncher[] = [];
    try {
      const payload: MdLauncherPayload = await repo.load<MdLauncherPayload>('launchers');
      const list: MdLauncher[] | undefined = payload.list;
      launchers = list !== undefined ? list : [];
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'launchers 加载失败: %{public}s', (e as BusinessError).message);
    }

    const cur: MdLauncher | undefined = this.findLauncher(launchers, this.configName);
    if (cur === undefined) {
      this.found = false;
      this.loading = false;
      return;
    }

    const cfg: RocketConfig = this.cfgOf(cur);
    const key: string = seriesKey(cfg);
    const series: MdLauncher[] = [];
    for (const x of launchers) {
      if (seriesKey(this.cfgOf(x)) === key) {
        series.push(x);
      }
    }
    this.seriesConfigs = [];
    for (const x of series) {
      this.seriesConfigs.push(this.configRecOf(x));
    }

    // 三个数据集互不依赖，并行拉；任何一个失败都只降级为空数组，不拖垮整页
    let prevList: LaunchSummary[] = [];
    let upList: LaunchSummary[] = [];
    let videoList: VideoItem[] = [];
    const tasks: Promise<void>[] = [];
    tasks.push(repo.load<PreviousPayload>('previous')
      .then((data: PreviousPayload) => {
        const l: LaunchSummary[] | undefined = data.list;
        prevList = l !== undefined ? l : [];
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'previous 加载失败: %{public}s', e.message);
      }));
    tasks.push(repo.load<UpcomingPayload>('upcoming')
      .then((data: UpcomingPayload) => {
        const l: LaunchSummary[] | undefined = data.list;
        upList = l !== undefined ? l : [];
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'upcoming 加载失败: %{public}s', e.message);
      }));
    tasks.push(repo.load<VideosPayload>('videos')
      .then((data: VideosPayload) => {
        const l: VideoItem[] | undefined = data.list;
        videoList = l !== undefined ? l : [];
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'videos 加载失败: %{public}s', e.message);
      }));
    await Promise.all(tasks);

    // 视频库是独立数据集，靠 launch id 回连到发射记录；没回连上的记录就用自己的 vid
    const vmap: Map<string, VideoRef[]> = new Map<string, VideoRef[]>();
    for (const row of videoList) {
      const vids: VideoRef[] | undefined = row.vids;
      if (vids !== undefined && vids.length > 0) {
        vmap.set(row.id, vids);
      }
    }

    const ids: Set<string> = new Set<string>();
    for (const x of series) {
      if (x.id !== undefined) {
        ids.add(x.id.toString());
      }
    }

    this.launchRecs = [];
    const merged: LaunchSummary[] = prevList.concat(upList);
    for (const r of merged) {
      const rk = r.rocket;
      if (rk === undefined) {
        continue;
      }
      const cid: number | null | undefined = rk.configuration.id;
      if (cid === undefined || cid === null) {
        continue;
      }
      if (!ids.has(cid.toString())) {
        continue;
      }
      this.launchRecs.push(this.recOf(r, vmap));
    }

    const media: MdMedia = collectMedia(this.seriesConfigs, this.launchRecs);
    this.images = media.images;
    this.videos = media.videos;
    this.truncated = media.truncated;

    // 标题口径与小程序 pageTitle 一致：同系列构型够多时用系列名，否则用构型名
    let title: string = '';
    if (series.length >= 3) {
      title = seriesName(seriesKey(cfg));
    } else {
      title = rocketName(cfg);
    }
    if (title.length === 0) {
      title = strOf(cur.name);
    }
    if (title.length === 0) {
      title = '图片库';
    }
    this.pageTitle = title;

    this.sortShots();
    this.splitVideos();
    this.found = true;
    this.loading = false;
  }

  private findLauncher(list: MdLauncher[], name: string): MdLauncher | undefined {
    const target: string = name.trim();
    if (target.length === 0) {
      return undefined;
    }
    for (const x of list) {
      if (strOf(x.name) === target || strOf(x.full_name) === target) {
        return x;
      }
    }
    // 详情页传过来的名字可能大小写/空白不一致，退一步忽略大小写再匹配一次
    const lower: string = target.toLowerCase();
    for (const x of list) {
      if (strOf(x.name).toLowerCase() === lower || strOf(x.full_name).toLowerCase() === lower) {
        return x;
      }
    }
    return undefined;
  }

  private cfgOf(x: MdLauncher): RocketConfig {
    const cfg: RocketConfig = {
      id: x.id !== undefined ? x.id : null,
      name: strOf(x.name),
      full_name: strOf(x.full_name),
      variant: strOf(x.variant),
      families: x.families
    };
    return cfg;
  }

  private configRecOf(x: MdLauncher): MdConfigRec {
    // launchers.json 里没有 imageThumb / imageCredit，留空让 collectMedia 回退到 image
    const rec: MdConfigRec = {
      id: x.id,
      name: strOf(x.name),
      full_name: strOf(x.full_name),
      variant: strOf(x.variant),
      families: x.families,
      image: strOf(x.image),
      imageThumb: '',
      imageCredit: ''
    };
    return rec;
  }

  private recOf(r: LaunchSummary, vmap: Map<string, VideoRef[]>): MdLaunchRec {
    const rec: MdLaunchRec = {
      id: r.id,
      name: strOf(r.name),
      net: strOf(r.net),
      image: strOf(r.image),
      imageThumb: strOf(r.imageThumb),
      imageCredit: strOf(r.imageCredit),
      imageName: strOf(r.imageName),
      infographic: strOf(r.infographic)
    };
    const pad: LaunchPad | undefined = r.pad;
    if (pad !== undefined) {
      const p: MdPadRec = {
        name: strOf(pad.name),
        image: strOf(pad.image),
        imageThumb: strOf(pad.imageThumb),
        imageCredit: strOf(pad.imageCredit),
        imageName: strOf(pad.imageName)
      };
      rec.pad = p;
    }
    const refs: MdVideoRef[] = [];
    const fromMap: VideoRef[] | undefined = vmap.get(r.id);
    if (fromMap !== undefined) {
      for (const v of fromMap) {
        const one: MdVideoRef = {
          url: v.url,
          title: strOf(v.title),
          publisher: strOf(v.publisher),
          kind: strOf(v.kind),
          tid: v.tid,
          cover: strOf(v.cover),
          mins: v.mins,
          cosUrl: strOf(v.cosUrl),
          sourceType: ''
        };
        refs.push(one);
      }
    } else if (r.vid !== undefined) {
      for (const v of r.vid) {
        const one: MdVideoRef = {
          url: strOf(v.url),
          title: strOf(v.title),
          publisher: strOf(v.publisher),
          kind: strOf(v.kind),
          tid: v.tid,
          cover: strOf(v.cover),
          mins: v.mins,
          cosUrl: strOf(v.cosUrl),
          sourceType: strOf(v.sourceType)
        };
        refs.push(one);
      }
    }
    rec.vid = refs;
    return rec;
  }

  // ---------------------------------------------------------------- 瀑布流分配

  /**
   * 图片高度按档位比例估：小程序等 @load 回传真实比例，这里没有回调，
   * 只能先用固定基准乘档位系数，宁可估得粗糙也不让整列重排抖动（已知取舍）。
   * 各档必须取不同的值：全取同一个数时贪心会退化成奇偶交替，等于没改。
   */
  private shotHeight(kind: string): number {
    if (kind === 'infographic') {
      return SHOT_BASE * 1.5;
    }
    if (kind === 'config') {
      return SHOT_BASE * 1.15;
    }
    if (kind === 'pad') {
      return SHOT_BASE * 0.8;
    }
    if (kind === 'launch') {
      return SHOT_BASE * 0.7;
    }
    return SHOT_BASE * 0.8;
  }

  /** 贪心：每次丢进当前累计高度较小的那列 */
  private sortShots(): void {
    const left: MdShot[] = [];
    const right: MdShot[] = [];
    let hl: number = 0;
    let hr: number = 0;
    for (const img of this.images) {
      const h: number = this.shotHeight(img.kind);
      if (hl <= hr) {
        left.push(img);
        hl += h;
      } else {
        right.push(img);
        hr += h;
      }
    }
    this.colLeft = left;
    this.colRight = right;
  }

  /** 视频卡等高，奇偶分列即可 */
  private splitVideos(): void {
    const left: MdVideo[] = [];
    const right: MdVideo[] = [];
    for (let i = 0; i < this.videos.length; i++) {
      if (i % 2 === 0) {
        left.push(this.videos[i]);
      } else {
        right.push(this.videos[i]);
      }
    }
    this.vcolLeft = left;
    this.vcolRight = right;
  }

  // ---------------------------------------------------------------- 交互

  private preview(img: MdShot): void {
    const url: string = img.full.length > 0 ? img.full : img.thumb;
    const p: PhotoNavParam = new PhotoNavParam(url, img.caption);
    Nav.pushPhoto(p);
  }

  private openVideo(v: MdVideo): void {
    if (v.playable && v.cosUrl.length > 0) {
      this.playingUrl = v.cosUrl;
      this.playingTitle = v.title;
      return;
    }
    this.copyLink(v.url);
  }

  private copyLink(url: string): void {
    if (url.length === 0) {
      this.toast('该视频暂无链接');
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.toast('链接已复制');
    }).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG, '复制链接失败 code=%{public}d', e.code);
      this.toast('复制失败，请稍后重试');
    });
  }

  private closePlayer(): void {
    this.playingUrl = '';
    this.playingTitle = '';
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  // ---------------------------------------------------------------- 结构

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        this.topBar()
        if (this.loading) {
          this.loadingArea()
        } else if (!this.found) {
          this.notFoundArea()
        } else {
          this.tabBar()
          Scroll(this.scroller) {
            Column() {
              if (this.tab === 0) {
                this.imageGrid()
              } else {
                this.videoGrid()
              }
              if (this.tab === 0 && this.truncated) {
                this.tailLine()
              }
            }
            .width('100%')
            .padding({ bottom: 32 })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(BG)
      .alignItems(HorizontalAlign.Start)

      if (this.playingUrl.length > 0) {
        this.playerMask()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }

  @Builder
  topBar() {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.pageTitle)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ left: 60, right: 60 })
      Row() {
        Row() {
          Text('‹')
            .fontSize(23)
            .fontColor('#FFFFFF')
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          Nav.pop();
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ left: 10 })
    }
    .width('100%')
    .height(44)
    .backgroundColor(TOP_BAR_BG)
    .border({ width: { bottom: 0.5 }, color: DIVIDER })
  }

  @Builder
  tabBar() {
    Row() {
      Column() {
        Text('图片库')
          .fontSize(14)
          .lineHeight(20)
          .fontColor(this.tab === 0 ? '#FFFFFF' : TEXT_META)
          .fontWeight(this.tab === 0 ? FontWeight.Medium : FontWeight.Regular)
        if (this.tab === 0) {
          Row()
            .width(20)
            .height(2)
            .borderRadius(2)
            .backgroundColor(HL)
            .margin({ top: 4 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        this.tab = 0;
      })

      Column() {
        Text('视频库')
          .fontSize(14)
          .lineHeight(20)
          .fontColor(this.tab === 1 ? '#FFFFFF' : TEXT_META)
          .fontWeight(this.tab === 1 ? FontWeight.Medium : FontWeight.Regular)
        if (this.tab === 1) {
          Row()
            .width(20)
            .height(2)
            .borderRadius(2)
            .backgroundColor(HL)
            .margin({ top: 4 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        this.tab = 1;
      })
    }
    .width('100%')
    .padding({ top: 4, bottom: 6 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  imageGrid() {
    if (this.images.length === 0) {
      this.emptyBlock('🖼️', '还没有图片', '历史发射记录补齐后会陆续出现')
    } else {
      Row() {
        Column() {
          ForEach(this.colLeft, (img: MdShot, idx: number) => {
            this.shotCard(img)
          }, (img: MdShot, idx: number) => 'L' + idx.toString() + img.url)
        }
        .layoutWeight(1)
        .padding({ left: 2, right: 2 })
        .alignItems(HorizontalAlign.Start)

        Column() {
          ForEach(this.colRight, (img: MdShot, idx: number) => {
            this.shotCard(img)
          }, (img: MdShot, idx: number) => 'R' + idx.toString() + img.url)
        }
        .layoutWeight(1)
        .padding({ left: 2, right: 2 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
      .alignItems(VerticalAlign.Top)
    }
  }

  @Builder
  shotCard(img: MdShot) {
    Stack({ alignContent: Alignment.Bottom }) {
      Image(img.thumb)
        .width('100%')
        .height(this.shotHeight(img.kind))
        .objectFit(ImageFit.Cover)
        .draggable(false)
      if (img.credit.length > 0) {
        Text('@' + img.credit)
          .fontSize(9.5)
          .fontColor('#EBFFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 4, right: 4, bottom: 4 })
          .textShadow({ radius: 4, color: '#CC000000', offsetX: 0, offsetY: 1 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height(this.shotHeight(img.kind))
    .borderRadius(4)
    .backgroundColor(CARD_BG)
    .margin({ bottom: 5 })
    .clip(true)
    .onClick(() => {
      this.preview(img);
    })
  }

  @Builder
  videoGrid() {
    if (this.videos.length === 0) {
      this.emptyBlock('🎬', '还没有视频', '数据源只收录部分任务的直播回放')
    } else {
      Row() {
        Column() {
          ForEach(this.vcolLeft, (v: MdVideo, idx: number) => {
            this.videoCard(v)
          }, (v: MdVideo, idx: number) => 'VL' + idx.toString() + v.url)
        }
        .layoutWeight(1)
        .padding({ left: 2, right: 2 })
        .alignItems(HorizontalAlign.Start)

        Column() {
          ForEach(this.vcolRight, (v: MdVideo, idx: number) => {
            this.videoCard(v)
          }, (v: MdVideo, idx: number) => 'VR' + idx.toString() + v.url)
        }
        .layoutWeight(1)
        .padding({ left: 2, right: 2 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
      .alignItems(VerticalAlign.Top)
    }
  }

  @Builder
  videoCard(v: MdVideo) {
    Column() {
      Stack({ alignContent: Alignment.Center }) {
        if (v.thumb.length > 0) {
          Image(v.thumb)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .draggable(false)
        } else {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#0D1420')
        }
        // 中央播放键与左上官方标都要放行点击，否则卡片点不动
        Row() {
          Text('▶')
            .fontSize(13)
            .fontColor('#F2FFFFFF')
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .backgroundColor('#73000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .hitTestBehavior(HitTestMode.None)

        if (v.official) {
          Row() {
            Text('官方')
              .fontSize(9)
              .fontColor('#FFFFFF')
              .backgroundColor('#8C000000')
              .padding({ left: 5, right: 5, top: 1, bottom: 1 })
              .borderRadius(2)
              .lineHeight(13)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Start)
          .alignItems(VerticalAlign.Top)
          .padding({ left: 5, top: 5 })
          .hitTestBehavior(HitTestMode.None)
        }
      }
      .width('100%')
      .height(VIDEO_COVER_H)

      Text(v.title)
        .fontSize(11.5)
        .fontColor(TEXT_TITLE)
        .lineHeight(16)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 6, right: 6, top: 6, bottom: v.publisher.length > 0 ? 2 : 6 })

      if (v.publisher.length > 0) {
        Text('@' + v.publisher)
          .fontSize(10)
          .fontColor(TEXT_META)
          .lineHeight(14)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ left: 6, right: 6, top: 2, bottom: 6 })
      }
    }
    .width('100%')
    .backgroundColor(CARD_BG)
    .borderRadius(4)
    .margin({ bottom: 5 })
    .clip(true)
    .onClick(() => {
      this.openVideo(v);
    })
  }

  @Builder
  tailLine() {
    Row() {
      Text('仅显示最近 ' + this.images.length.toString() + ' 张')
        .fontSize(11)
        .fontColor(TEXT_DIM)
        .lineHeight(16)
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 10, bottom: 20 })
  }

  @Builder
  emptyBlock(icon: string, text: string, sub: string) {
    Column() {
      Text(icon)
        .fontSize(30)
        .margin({ bottom: 8 })
      Text(text)
        .fontSize(13)
        .fontColor(TEXT_EMPTY)
        .lineHeight(18)
      Text(sub)
        .fontSize(11)
        .fontColor(TEXT_EMPTY_SUB)
        .textAlign(TextAlign.Center)
        .lineHeight(17.6)
        .width('80%')
        .margin({ top: 5 })
    }
    .width('100%')
    .padding({ top: 60, bottom: 60 })
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  loadingArea() {
    Row() {
      Text('加载中...')
        .fontSize(13)
        .fontColor(TEXT_HINT)
    }
    .width('100%')
    .height('60%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  notFoundArea() {
    Column() {
      Text('🛰️')
        .fontSize(30)
        .margin({ bottom: 8 })
      Text('未找到该型号')
        .fontSize(13)
        .fontColor(TEXT_EMPTY)
        .lineHeight(18)
    }
    .width('100%')
    .height('60%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  playerMask() {
    Stack({ alignContent: Alignment.Center }) {
      Video({ src: this.playingUrl })
        .width('100%')
        .height('78%')
        .controls(true)
        .autoPlay(true)
        .loop(false)
        .objectFit(ImageFit.Contain)
        .backgroundColor('#000000')
        .onClick(() => {
        })

      // 贴底不能直接丢进居中的 Stack，得有一个满高容器把内容推到底部
      Column() {
        Row() {
          Text(this.playingTitle)
            .fontSize(12)
            .fontColor(TEXT_TITLE)
            .lineHeight(17)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
            .margin({ right: 12 })
          Row() {
            Text('✕')
              .fontSize(15)
              .fontColor('#FFFFFF')
          }
          .width(28)
          .height(28)
          .borderRadius(14)
          .backgroundColor('#1FFFFFFF')
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.closePlayer();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 14, right: 14, top: 12, bottom: 24 })
        .linearGradient({ angle: 0, colors: [['#E604060A', 0.0], ['#0004060A', 1.0]] })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F004060A')
    .onClick(() => {
      this.closePlayer();
    })
  }
}
