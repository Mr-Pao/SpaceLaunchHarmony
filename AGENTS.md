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

## 七、进度（2026-11-02）

- ✅ 工程骨架 37 文件，编译通过，HAP 268KB
- ✅ 五 tab 骨架 + 今日页（即将发射列表，含骨架屏/错误态/空态/下拉刷新）
- ✅ 网络层 `HttpClient.ets`（195 行）、缓存层 `FileStore.ets`（267）+ `Repository.ets`（728）
- ✅ 常量与模型 `Dataset.ets`（322）+ 5 个 model（691）
- ⬜ 发射 / 图库 / 火箭 / 我的四个 tab 仍是**占位页**（各 54–63 行）
- ⬜ 悬浮胶囊图标用「圆环 + 实心点」几何图形临时替代，5 个 PNG 未画（`ic_today` / `ic_launch` /
  `ic_gallery` / `ic_rocket` / `ic_mine`，建议 96×96 @3x，替换位置在 `FloatingTabBar.ets` 的 `iconOf()`）
- ⬜ 未配签名、未上真机
- ⬜ 22 个数据集还没有 interface（当前可用 `Repository.load<Object>()` 绕过）

## 八、值得记住的教训

- **子代理交付的代码能一次性通过 ArkTS 严格模式编译**（37 文件 / 3463 行，除 3 处已修的错误）。
  但**不能相信子代理"未编译"的自查结论**——`LaunchSummary` 漏 `pad` 字段就是这么漏掉的
  （`slim.js:145` 明明有），只有编译才暴露。
- **字段结构要拿 `slim.js` 对照，不能只看 interface**。B 子代理核对 212 个字段名全对，
  但整块 `pad` 对象没翻译。
- **新建目录类工作要在第一批文件落盘时就提交**，不要等全部子代理完成，
  否则用户在 GitHub 上长时间看不到进展（2026-11-02 的教训）。
