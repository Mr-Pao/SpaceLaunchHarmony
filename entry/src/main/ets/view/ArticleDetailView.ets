/**
 * view/ArticleDetailView.ets —— 航天资讯详情页
 *
 * 对位小程序 `pages/news` 的详情弹层（components/news-section 的 detail 分支）。
 * 小程序侧详情是**弹层**不是页面，本工程是独立路由页（ArticleNavParam 由 DetailPages 递进来）。
 *
 * 数据全部来自入参，**不拉网络**：资讯详情就是列表里那条记录本身（标题/摘要/封面/原文链接），
 * news.json 没有「详情正文」这个字段，再去拉一次 news 只会白白多一次全量 JSON。
 * 所以这里没有 loading / failed 四态，只有「封面加载失败」这一个局部状态。
 *
 * ── 几处有意取舍 ──
 *   1. **原文链接只能复制，不能打开**。小程序未配业务域名、web-view 打不开；
 *      鸿蒙侧没有内置浏览器组件，走 want 拉起外部浏览器会让用户跳出应用，
 *      与「在 App 内看资讯」的心智不符。所以底部只有一个「复制原文链接」。
 *   2. **链接为空就不画按钮**。news.json 里确实存在 url 缺失的记录（上游 RSS 缺 link），
 *      画一个点了没反应的按钮比不画更糟。
 *   3. **关联发射卡按 launchRefs 画**。NewsItem.launches 只是 UUID 列表、没有 net，
 *      拿它跳转会翻不到归档；launchRefs 才是 CI 补好的可跳转定位信息。
 *   4. **封面 onError 后整块不画**（不是留 200vp 空块）。资讯封面是「加分项」，
 *      破图撑着高度会把标题挤到屏外。
 *
 * ⚠ 本文件不使用 console.*，日志一律 hilog。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { strOf, formatLaunchTime } from '../utils/Format';
import { Nav } from '../routes/Nav';
import { ArticleNavParam, LaunchNavParam } from '../routes/NavParam';
import { NewsLaunchRef } from '../model/News';

const DOMAIN: number = 0x0000;
const TAG: string = 'ArticleDetailView';

// ============ 视觉常量（工程约定） ============

const BG_PRIMARY: string = '#0A0E17';
const CARD_BG: string = '#141A26';
const TEXT_MAIN: string = '#FFFFFF';
const TEXT_SUB: string = '#A7B4C7';
const TEXT_DIM: string = '#55617A';
const ACCENT: string = '#38BDF8';

/** 页面左右内边距（与 TodayView / LaunchView 的 12 对齐） */
const PAGE_PAD: number = 12;
/** 封面高度（任务书 200vp） */
const HERO_H: number = 200;
/** 详情页不在 tab 内，底部留 32 即可（不用 92 的胶囊让位） */
const BOTTOM_PAD: number = 32;

@Component
export struct ArticleDetailView {
  /** 路由入参（字段全在入参里，本页不需要再取数） */
  @Prop param: ArticleNavParam = new ArticleNavParam();

  /** 封面加载失败 → 整块不画，见文件头取舍 4 */
  @State imgErr: boolean = false;

  /** 复制结果提示用。失败时给出系统错误码，方便定位「复制被禁用」这类情况 */
  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2000 });
  }

  private back(): void {
    Nav.pop();
  }

  // ============ 派生文本 ============

  private titleText(): string {
    const zh: string = strOf(this.param.titleZh);
    return zh.length > 0 ? zh : strOf(this.param.title);
  }

  private bodyText(): string {
    const zh: string = strOf(this.param.summaryZh);
    return zh.length > 0 ? zh : strOf(this.param.summary);
  }

  /**
   * 元信息行：来源 + 时间，空值跳过。
   *
   * 用数组 join 而不是字符串拼接，是为了「site 为空、at 非空」时不会留下
   * 一个孤零零的前导「 · 」。
   */
  private metaText(): string {
    const parts: string[] = [];
    const site: string = strOf(this.param.site).trim();
    if (site.length > 0) {
      parts.push(site);
    }
    const at: string = strOf(this.param.at).trim();
    if (at.length > 0) {
      parts.push(at);
    }
    return parts.join(' · ');
  }

  private refs(): NewsLaunchRef[] {
    const list: NewsLaunchRef[] | undefined = this.param.launchRefs;
    return list !== undefined && list !== null ? list : [];
  }

  private refName(ref: NewsLaunchRef): string {
    const name: string = strOf(ref.name).trim();
    return name.length > 0 ? name : '未命名任务';
  }

  // ============ 交互 ============

  /** 跳发射详情。缺 id / net 直接不动（跳过去也是「未找到」） */
  private openLaunch(ref: NewsLaunchRef): void {
    const id: string = strOf(ref.id);
    if (id.length === 0) {
      hilog.debug(DOMAIN, TAG, '关联发射缺 id，跳过');
      return;
    }
    Nav.pushLaunch(new LaunchNavParam(id, strOf(ref.net), this.refName(ref)));
  }

  /**
   * 复制原文链接。
   *
   * 工程内此前没有 pasteboard 先例（全仓 grep "pasteboard" 零命中），按系统能力文档走
   * `pasteboard.createData(MIMETYPE_TEXT_PLAIN, url)` + `getSystemPasteboard().setData()`。
   * `pasteboard.PasteData` 当类型用与 FileStore.ets:40 的 `common.Context` 同一套写法
   * （kit re-export 的 namespace 同时是值域与类型域），有先例、不赌。
   *
   * setData 的 promise 版本会抛 27787277（另一个复制/粘贴进行中）与 27787278（复制被禁止），
   * 两者都必须给用户反馈 —— 否则点了没反应会被当成按钮坏了。
   */
  private copyUrl(): void {
    const url: string = strOf(this.param.url).trim();
    if (url.length === 0) {
      return;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data)
      .then(() => {
        this.toast('原文链接已复制');
      })
      .catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, '复制链接失败 code=%{public}d', e.code);
        this.toast('复制失败，请稍后重试');
      });
  }

  // ============ UI：顶栏 ============

  /**
   * 自绘顶部栏（NavDestination 那边 hideTitleBar(true)）。
   * 结构与 RocketDetailView.topBar 一致：‹ 返回 + 标题，热区靠 padding 撑开。
   */
  @Builder
  topBar() {
    Row() {
      Row() {
        Text('‹')
          .fontSize(20)
          .fontColor(TEXT_MAIN)
          .lineHeight(20)
        Text('返回')
          .fontSize(14)
          .fontColor(TEXT_SUB)
          .margin({ left: 2 })
      }
      .alignItems(VerticalAlign.Center)
      .padding({ right: 12, top: 10, bottom: 10 })
      .onClick(() => {
        this.back();
      })

      Text('资讯')
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .maxLines(1)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: PAGE_PAD, right: PAGE_PAD })
    .backgroundColor(BG_PRIMARY)
  }

  // ============ UI：封面 ============

  @Builder
  hero() {
    Image(strOf(this.param.image))
      .width('100%')
      .height(HERO_H)
      .objectFit(ImageFit.Cover)
      .backgroundColor(CARD_BG)
      .onError(() => {
        // 破图整块撤掉，把屏幕留给标题与正文
        this.imgErr = true;
      })
  }

  // ============ UI：正文区 ============

  @Builder
  articleBlock() {
    Column() {
      Text(this.titleText())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(TEXT_MAIN)
        .lineHeight(28)
        .width('100%')

      if (this.metaText().length > 0) {
        Text(this.metaText())
          .fontSize(11)
          .fontColor(TEXT_SUB)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 8 })
      }

      if (this.bodyText().length > 0) {
        Text(this.bodyText())
          .fontSize(14)
          .fontColor(TEXT_SUB)
          .lineHeight(22)
          .width('100%')
          .margin({ top: 14 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 14 })
  }

  // ============ UI：关联发射 ============

  @Builder
  launchRefRow(ref: NewsLaunchRef, index: number) {
    // 分隔线放进行内部而不是 ForEach 里再包一层 if：
    // ForEach 的每个 item 尽量只有一个根节点，多根节点在部分 SDK 上会漏掉 key 复用。
    Column() {
      if (index > 0) {
        Divider()
          .color('#1E2637')
          .strokeWidth(0.5)
      }

      Row() {
        Column() {
          Text(this.refName(ref))
            .fontSize(13)
            .fontColor(TEXT_MAIN)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(formatLaunchTime(strOf(ref.net)))
            .fontSize(11)
            .fontColor(TEXT_DIM)
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('›')
          .fontSize(16)
          .fontColor(TEXT_DIM)
          .margin({ left: 8 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 10, bottom: 10 })
      .onClick(() => {
        this.openLaunch(ref);
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  refsCard() {
    Column() {
      Text('相关发射')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(TEXT_SUB)
        .width('100%')
        .margin({ bottom: 2 })

      ForEach(this.refs(), (ref: NewsLaunchRef, index: number) => {
        this.launchRefRow(ref, index)
      }, (ref: NewsLaunchRef, index: number) => strOf(ref.id) + '#' + index)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(CARD_BG)
    .borderRadius(12)
    .margin({ left: PAGE_PAD, right: PAGE_PAD, top: 16 })
  }

  // ============ UI：底部操作 ============

  /**
   * 复制按钮。
   * 外层 Row 负责左右留白与上间距 —— 直接把 padding 写进按钮本身的话，
   * 底色会连 padding 一起铺满整屏，圆角也就压到屏幕边缘了。
   */
  @Builder
  copyButton() {
    Row() {
      Row() {
        Text('复制原文链接')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(ACCENT)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 12, bottom: 12 })
      .backgroundColor('#16222F')
      .borderRadius(12)
      .onClick(() => {
        this.copyUrl();
      })
    }
    .width('100%')
    .padding({ left: PAGE_PAD, right: PAGE_PAD, top: 20 })
  }

  // ============ build ============

  build() {
    Column() {
      this.topBar()

      Scroll() {
        Column() {
          if (strOf(this.param.image).length > 0 && !this.imgErr) {
            this.hero()
          }

          this.articleBlock()

          if (this.refs().length > 0) {
            this.refsCard()
          }

          // url 为空整块不画（见文件头取舍 2）
          if (strOf(this.param.url).trim().length > 0) {
            this.copyButton()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        // 详情页不在 tab 内，底部留 32 即可（不用 92 的胶囊让位）
        .padding({ bottom: BOTTOM_PAD })
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG_PRIMARY)
  }
}
