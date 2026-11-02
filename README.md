# SpaceLaunch · HarmonyOS

航天发射跟踪 App 的**鸿蒙原生版**（ArkTS / ArkUI）。

微信小程序版在 [Mr-Pao/SpaceLaunch](https://github.com/Mr-Pao/SpaceLaunch)，
本仓库是同一产品的第二个客户端，代码完全独立重写，**只共享运行时的数据**（见下）。

## 数据从哪来

两边都不含后端。数据由小程序仓库的 GitHub Actions 定时抓取后写入腾讯 COS，
本 App **只做 https GET**：

```
https://spacelaunch-1258113633.cos.ap-chengdu.myqcloud.com/space-data/*.json   27 个数据集
https://spacelaunch-1258113633.cos.ap-chengdu.myqcloud.com/space-img/*.jpg     缩略图（480px / ≤30KB）
```

- 无鉴权、无 API 服务、无 SDK。
- **本仓库不需要 `scripts/`、不需要 `.github/workflows/`** —— 数据管道不是这里的事。
- 数据结构契约见 [DATA_CONTRACT.md](DATA_CONTRACT.md)。

## 构建

必须装 **DevEco Studio 26.0.0**（自带 SDK / Node / JBR，均不在 PATH，需显式指定）。

```bash
DS="/c/Users/yzx49/Program/DevEco Studio"     # 改成你的实际安装路径
export DEVECO_SDK_HOME="$DS/sdk"
export JAVA_HOME="$DS/jbr"                     # 打包阶段 spawn java 需要
export PATH="$DS/jbr/bin:$DS/tools/node:$PATH"

"$DS/tools/node/node.exe" "$DS/tools/hvigor/bin/hvigorw.js" \
  --mode module -p product=default -p module=entry@default assembleHap --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

### 三个必踩的坑

| 症状 | 原因 | 修法 |
|---|---|---|
| `hvigor depends on the npmrc file` | 用户目录没有 `.npmrc` | 建 `~/.npmrc`，内容 `registry=https://registry.npmmirror.com/` |
| `ERR_PNPM_FETCH_404 @ohos/hvigor-ohos-plugin` | `hvigor/hvigor-config.json5` 用了老格式（`hvigorVersion` + 显式依赖），会去 npm 拉华为私有包 | 必须是 `{"modelVersion": "5.0.0", "dependencies": {}}`，吃 DevEco 内置插件 |
| `spawn java ENOENT`（PackageHap 阶段） | 打包要调 java | `JAVA_HOME` 指到 `$DS/jbr` 并把 `$DS/jbr/bin` 加进 PATH |

### 签名

当前 `build-profile.json5` 的 `signingConfigs` 为空，产出的是 **unsigned HAP**，只能看不能装。
要真机安装需在 DevEco 里配自动签名（File → Project Structure → Signing Configs → Automatically generate signature），
会写入 `signingConfigs` 并生成 `.p12` / `.cer` / `.p7b`。**这几个证书文件不要入库**（`.gitignore` 已排除 `local.properties`，
证书路径在 `build-profile.json5` 里，入库前需自行确认不含私钥密码）。

## 目录

```
AppScope/                     应用级配置与图标
entry/src/main/
  module.json5                权限（INTERNET）、入口 ability
  ets/
    entryability/EntryAbility.ets   启动、窗口底色、fileStore 初始化
    pages/Index.ets                 唯一 @Entry，Tabs + 悬浮胶囊
    components/FloatingTabBar.ets   自绘悬浮胶囊（替代小程序 custom-tab-bar）
    view/                           五个 tab 的内容
    api/HttpClient.ets              网络层（并发 4、同 URL 去重、超时 8s）
    data/FileStore.ets              filesDir 同步文件缓存
    data/Repository.ets             三级缓存（内存 → 文件 → COS）
    model/                          27 个数据集的 ArkTS interface
    constants/Dataset.ets           数据集常量、TTL、缓存 key
    utils/Format.ets                时间/状态/标签等纯函数
```

## 已知状态（2026-11-02）

- ✅ 编译通过，HAP 268KB
- ✅ 五 tab 骨架 + 今日页（即将发射列表）
- ⬜ 发射 / 图库 / 火箭 / 我的四个 tab 仍是占位页
- ⬜ 悬浮胶囊图标用「圆环 + 实心点」几何图形临时替代，5 个 PNG 未画
- ⬜ 未配签名，未上真机
