# SpaceLaunch · HarmonyOS 项目记忆

航天发射跟踪 App 的**鸿蒙原生版**（ArkTS / ArkUI），与微信小程序版
[Mr-Pao/SpaceLaunch](https://github.com/Mr-Pao/SpaceLaunch) 是同一产品的两个独立客户端。

- **代码零共享**：小程序是 uni-app + Vue3，这里是 ArkTS，全部重写。
- **数据共享**：只共享 COS 上的静态 JSON，见 [DATA_CONTRACT.md](DATA_CONTRACT.md)。
  本仓库没有 `scripts/`、没有 `.github/workflows/`，数据管道不在这里。
- 小程序侧 27 个数据集、30 个页面、43 个组件的业务语义可以查阅小程序仓库的 `AGENTS.md`；
  但**具体页面实现一律重写，不要照搬 Vue 写法**。

## 一、环境（本机实测，2026-11-02）

- DevEco Studio **26.0.0**（build `DS-261.23567.138.36.2600865`），装在
  `C:\Users\yzx49\Program\DevEco Studio`（**不在 Program Files**）。
- SDK **HarmonyOS 26.0.0 / API 26**（`sdk/default/sdk-pkg.json`），
  路径 `sdk/default/openharmony/{ets,js,native,previewer,toolchains}`。
- hvigor **6.26.9**，自带 **Node v24.14.1**（`tools/node/node.exe`），
  自带 **JBR OpenJDK 25.0.2**（`jbr/`），ohpm 在 `tools/ohpm/bin/`。
- **Node / JBR / ohpm 都不在 PATH**，构建必须显式指定绝对路径。

## 二、构建命令（可直接复制）

```bash
cd <本仓库根>
DS="/c/Users/yzx49/Program/DevEco Studio"
export DEVECO_SDK_HOME="$DS/sdk"
export JAVA_HOME="$DS/jbr"
export PATH="$DS/jbr/bin:$DS/tools/node:$PATH"
"$DS/tools/node/node.exe" "$DS/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`（约 268KB）。
**当前未配签名**，无签名只能看不能装机。要真机装在 DevEco 里配自动签名。

## 三、四个必踩的坑（全部实测过）

| 症状 | 根因 | 修法 |
|---|---|---|
| `00303137 hvigor depends on the npmrc file` | 用户目录无 `.npmrc` | 建 `~/.npmrc`：`registry=https://registry.npmmirror.com/` |
| `00308002 '"node"' 不是内部或外部命令` | hvigor 调 pnpm 找不到 node | PATH 加 `$DS/tools/node` |
| `ERR_PNPM_FETCH_404 @ohos/hvigor-ohos-plugin` | `hvigor/hvigor-config.json5` 用老格式（`hvigorVersion` + 显式依赖），会去 npm 拉华为私有包 | 必须是 `{"modelVersion": "5.0.0", "dependencies": {}}`，吃 DevEco 内置插件 |
| `00308018 spawn java ENOENT`（PackageHap 阶段） | 打包要调 java | `JAVA_HOME=$DS/jbr`，PATH 加 `$DS/jbr/bin` |

**SDK 版本**：`build-profile.json5` 里 **不要写 `compileSdkVersion`**（官方模板也没有），
只写 `compatibleSdkVersion` / `targetSdkVersion`，本机是 `"6.0.0(20)"`。
写 `"5.0.0(12)"` 会报 `compileSdkVersion is incompatible`。

## 四、ArkTS 硬约束（编译期强制，不是建议）

- **禁止 `any` / `unknown`**（`arkts-no-any-unknown`）。catch 到的 `e` 也是 `Object`，不能当 any。
- **禁止结构化类型 / 索引签名** `[k: string]: T`、`Record<K,V>`。用 `Map<K,V>`。
- **`JSON.parse` 结果必须 `as` 到显式 interface**。泛型场景用三段断言 `data as Object as T`
  （单跳 `as T` 会报「泛型断言不兼容」）。
- **泛型逆变**：`onUpdate?: (data: T) => void` 传给形参写死 `(data: DataSet) => void` 的函数会报错，
  被调函数要自己也是泛型 `<T>`，内部 `fresh as Object as T`。
- **`Date` 相减不是合法运算**，用 `getTime()` 或自写 `parseTime` 返回 number。
- 优先 `async/await`，不要依赖 `Promise.finally()`。
- **成员名不能与同名方法共存**（`Duplicate identifier`）：`@State agencyLogo: string` 又写
  `private agencyLogo(): string` 会报错，方法改名 `agencyLogoOf()`。
- **属性方法不存在时的正确替代**（2026-11-03 实测，三条都是硬报错）：
  | 想写 | 报错 | 改用 |
  |---|---|---|
  | `Row().flexWrap(...)` | `Property 'flexWrap' does not exist on RowAttribute` | `Flex({ wrap: FlexWrap.Wrap })` |
  | `Text().maxWidth('70%')` | `Property 'maxWidth' does not exist on TextAttribute` | `.width('70%').textAlign(TextAlign.End)` |
  | `Column().overflow(Overflow.Hidden)` | 同上，且 `Overflow` 不在作用域 | `.clip(true)` |

## 五、缓存与网络设计（照小程序 `utils/data.js` 翻译）

- **三级缓存**：L1 内存 → L2 文件 → L3 COS。
- **L2 必须用文件系统，不能用 `preferences`**：`preferences` 单 value(string) 上限
  **8192 字节**，而数据集动辄几百 KB（launchers 435KB、upcomingMore 626KB）物理存不下。
  落 `context.filesDir/dataCache/v14/`，用 `fs.readTextSync` 等**同步 API**，首屏零等待。
- **缓存目录带版本号**（`v14`），升 `DATA_VERSION` 即新目录，旧缓存自然废弃。
- `force` 分支**不触发 `onUpdate`**，直接 resolve 新数据。
- **后台刷新失败必须静默**，只写 hilog，绝不影响页面。
- 只有 `generatedAt` 变了才回调 `onUpdate`。
- `EMPTY_SUSPECT = {apod, epic}`：空列表视为过期（上游停更）。
- 网络：`http.createHttp()` → `finally` 里**必须 `req.destroy()`**（否则句柄泄漏）；
  并发限 4；同 URL 去重；`connectTimeout 5000` / `readTimeout 8000`。
- 权限：`ohos.permission.INTERNET` 在 `module.json5` 的 `requestPermissions`，
  **system_grant，安装即授予**。忘了加的症状是 `2300007 连接失败`，不是明确的权限错误，极易误判。

## 六、UI 约定

- 主题色 **天蓝 `#38BDF8`**（来源：小程序 `pages.json` tabBar `selectedColor`，全库 110 次命中）。
- 底色 `#0a0e17`，更深一层 `#04060a`。色值定义在 `resources/base/element/color.json`（18 条）。
- **悬浮胶囊**：`Tabs({barPosition: BarPosition.End})` 5×`TabContent`，
  `.barHeight(0)` + `.divider({strokeWidth: 0})` + `.scrollable(false)` 隐藏系统 bar，
  Stack 底部自绘。**隐藏系统 bar 后每个 tab 内容必须留 `padding({bottom: 92})`**，
  否则列表最后一项被胶囊盖住。
- `TabContent` **必须是 `Tabs` 的直接子组件**，中间不能套 Column/Row/ForEach。
- 全仓只能有 **1 个 `@Entry`**（`pages/Index.ets`）。
- 大列表用 `List` + `LazyForEach` + `IDataSource`，`.cachedCount(3)`。
  两万条卫星数据放普通成员变量（**非 `@State`**），只把 `version`/`count` 挂 `@State`。
- **不要用 `AppStorage` 承载大数据集**（全局广播 + 响应式代理开销）。
- **`@Builder` 按值传参不建立响应式依赖**（本工程踩过两次，修了两轮才修对）：
  `this.statCell('运力之最', this.topLeoName, ...)` 里 `statGrid` 的依赖集**不含** `topLeoName`，
  异步赋值后不重绘，界面永远停在初值。**修法：随 @State 变化的文字必须写在无参 `@Builder` 里、
  在内部直接读 `this.xxx`**。只把外层改无参、内层仍带参传值，依然不刷新（第二层坑）。
- **无高父容器里的 `height('100%')` 会回溯到整屏**：`Stack` 由子节点撑开，卡片内放一个
  `.height('100%')` 的径向光层，会把整张卡撑成满屏。要么给父容器显式 `.height(N)`，
  要么让孩子用 `layoutWeight`。
- **`Stack` 里的遮罩要贴底必须包一层**：`Stack({alignContent: Alignment.TopStart})` 直接放
  70vp 的渐变遮罩会贴到**顶部**（把图上半压暗成灰带）。包一层满高
  `Column(){}.height(H).justifyContent(FlexAlign.End).hitTestBehavior(HitTestMode.None)` 才贴底。

## 七、进度（2026-11-03 02:20 更新）

**已完成并推送（最新提交 `f4efe5d`）**

| 模块 | 文件 | 状态 |
|---|---|---|
| 骨架/配置 | 15 配置 + 3 png，386 行 | ✅ |
| 网络/缓存 | `api/HttpClient`（195）+ `data/FileStore`（267）+ `data/Repository`（728） | ✅ |
| 常量/模型 | `constants/Dataset`（322）+ `constants/ZhMaps`（883）+ 9 个 model | ✅ |
| 今日 tab | `view/TodayView`（727）+ 6 组件 | ✅ 1:1 复刻 |
| 发射 tab | `view/LaunchView`（780）+ `components/LaunchCard`（296）+ `LaunchCalendar`（409） | ✅ 含日历视图 |
| 图库 tab | `view/GalleryView`（638）+ `components/GalleryGrid`（288） | ✅ 三列瀑布流 |
| 火箭 tab | `view/RocketView`（788）+ `components/RocketCard`（621） | ✅ 全球实力榜四榜七地区 |
| 我的 tab | `view/MineView`（800） | ✅ |
| 发射详情 | `view/LaunchDetailView`（1642） | ✅ |
| 火箭详情 | `view/RocketDetailView`（954） | ✅ |
| 看图器 | `view/PhotoDetailView`（620）捏合/双击/拖动/下滑关闭 | ✅ |
| 资讯 | `view/ArticleDetailView`（373）+ `view/NewsListView`（488） | ✅ |
| 数据统计 | `model/Stats`（216）+ `view/StatsView`（827） | ✅ 柱状图+明细+Top5 |
| 太空资产 | `model/Satellite`（288）+ `view/SpaceAssetsView`（1134） | ✅ 三 tab |
| 近地天体 | `model/Neo`（?）+ `view/NeoView`（708） | ✅ |
| 近期活动 | `model/Event`（136）+ `view/EventsView`（602） | ✅ |
| 服务卡片 | `EntryFormAbility`（520）+ 2 卡片页 | ⚠️ 2×2 正常，**2×4 图片纯黑未解决** |

**路由**：`routes/Nav.ets`（门面 + `NAV_DETAIL_DEPTH_KEY`）、`NavParam.ets`（4 个入参 class）、
`DetailPages.ets`（9 个 `@Builder` 页面）。**每 tab 一条独立 `NavPathStack`**，
`Index.ets` 切 tab 时把活跃栈写进 `Nav.current`。所有详情页 `NavDestination` 必须挂
`.onShown(() => Nav.markDetailShown())` + `.onHidden(() => Nav.markDetailHidden())`，
否则底部胶囊会浮在详情页上。

**未完成**
- ⬜ 卡片 2×4 图片纯黑（`formImages` + fd 通路日志全绿仍不出图，两次修法 `0eeed79`/`573621f` 均未解决，已挂起）
- ⬜ 收藏 / 提醒清单（无存储层，我的页虚线卡文案已如实写「尚未接入」）
- ⬜ 图库「看全部 N 张」中央悬浮胶囊
- ⬜ 发射 tab 右下悬浮「喇叭/搜索」两圆按钮
- ⬜ 5 个 tab 图标仍是几何圆环（`FloatingTabBar.ets` 的 `iconOf()`，要换成 `Image($r('app.media.ic_*'))`）
- ⬜ 签名（**模拟器不需要**，unsigned HAP 直接装；上真机/上架才要）
- ⬜ 元服务、分布式（用户定位 V2/V3 再做）

## 八、值得记住的教训

- **子代理交付的代码大多能一次通过 ArkTS 严格模式编译**，但**不能相信"未编译"的自查结论**。
  `LaunchSummary` 漏 `pad` 字段就是这么漏掉的（`slim.js:145` 明明有），只有编译才暴露。
- **字段结构要拿 `slim.js` 对照，不能只看 interface**。核对 212 个字段名全对，
  但整块 `pad` 对象没翻译。
- **新建目录类工作要在第一批文件落盘时就提交**，不要等全部子代理完成，
  否则用户在 GitHub 上长时间看不到进展（2026-11-02 的教训）。
- **并行子代理共用一个工作区**：主窗口 `git add -A` 会把还在写文件的子代理半成品一起提交。
  提交前先 `git status` 确认没有正在写的文件，或等子代理回报完再提交。
- **`@Prop` 名不能与 `CustomComponent` 内置方法同名**。`size` 踩过（`Countdown` 报
  `Property 'size' is not assignable to the same property in base type 'CustomComponent'`），
  已改 `sizeMode`。同类危险名：`width` / `height` / `padding` / `margin` / `clip` / `id` / `content` / `scale`。
- **`Row` 没有 `.flexWrap()`**，chip 需要折行必须用 `Flex({ wrap: FlexWrap.Wrap })`。
- **`Text` 没有 `.maxWidth()`**，要用 `.width('70%').textAlign(TextAlign.End)` 或 `constraintSize`。
- **`.overflow(Overflow.Hidden)` 在 `ColumnAttribute` 上不存在**，用 `.clip(true)`。
- **`ForEach` 的 key 必须把异步数据算进去**（`LaunchCalendar` 用 `dateStr + launches.length`），
  否则数据变了但 key 没变，ArkUI 不重跑子项，黄点永远不出现。
- **`@State` 不观察数组下标赋值**，`imgErr[i] = true` 无效，必须整体替换数组。
- **`repo.load` 无缓存 + 网络失败是 reject**，catch 里绝不能置 `loaded = true`，
  否则弱网首屏变永久空页（小程序 `gallery-all` 踩过，鸿蒙四页都刻意守这条）。
- **模拟器可直接装 unsigned HAP**（`hdc install -r entry-default-unsigned.hap`），
  所以开发期完全不用配签名。
- **OneDrive 同步会锁 `entry/build`**，编译报 `11204003 File Resource Error / Failed to delete ... No error`
  是锁冲突不是代码问题，`rm -rf entry/build` 重跑即可。
- **对齐小程序（2026-11-03 的惨痛教训，占本轮工作量一半）**：五个 tab + 三个详情页第一版都被判
  「这完全不一样」。根因是**凭着截图印象画**，没读 wxss 的具体数值。正确做法：
  ① 先 `grep`/`sed` 把小程序对应 `.vue` 的 template + style **完整读一遍**；
  ② 每条差异记 `rpx ÷ 2 = vp` 换算后的精确值（字体/间距/圆角/颜色）；
  ③ 组件结构也要对（小程序发射列表是**横向紧凑卡** 100vp 方图 + 三行，不是竖向大图卡；
  图库是**8 条横向漂移带**，不是瀑布流；火箭详情有**8 个区块**，不是 2 张卡）。
  「看起来差不多」不等于对齐，用户一眼就能看出。
- **审计要派只读子代理专门做**：让一个 agent 只读小程序与鸿蒙两侧、输出
  `序号|位置|小程序实际|鸿蒙实际|差异类型|严重度` 表格（本轮 105 + 102 条），比主窗口自己翻快得多，
  而且能避免「我改过一遍所以觉得没问题」的自我确认偏差。
- **子代理会让实现超出小程序**（例：给航天员页加「靠远征队反推所属空间站」）。看着更全，
  但与「逐页对齐」目标相反 —— 小程序那张卡因数据为空**永远不显示**，我们显示了就是不一致。
  **数据空导致的「不显示」也是需要对齐的行为**。
