# 数据契约

本 App 的全部数据来自 COS 上的静态 JSON，由**小程序仓库**的 GitHub Actions 产出。
本仓库只读，不参与生成。

```
https://spacelaunch-1258113633.cos.ap-chengdu.myqcloud.com/space-data/
```

## 一、版本号

载荷里有两个字段描述结构版本：

| 字段 | 位置 | 说明 |
|---|---|---|
| `v` | 每个 JSON 顶层 | 全局数据结构版本，当前 **14**。只在 slim 结构变化时升 |
| `generatedAt` | 每个 JSON 顶层 | 生产时间 ISO 字符串 |

代码里的对应常量：`constants/Dataset.ets` 的 `DATA_VERSION = 14`。

**行为约定**：`Repository.ets` 发现 `body.v !== DATA_VERSION` 只打 WARN，不拒绝请求。
这样小程序侧先升级、鸿蒙侧还没跟上时，App 仍能显示，只是字段可能缺。

**什么时候必须改**：小程序仓库升 `DATA_VERSION` 时，本仓库的 `Dataset.ets` 要同步改。
同时小程序侧的改动会让缓存全部失效（缓存目录带版本号，升版即新目录）。

## 二、27 个数据集

★ = 文件名与键名不同（**不是机械转换，最容易写错的地方**）

| 键名 | 文件名 | 软 TTL |
|---|---|---|
| `upcoming` ★ | `launches-upcoming.json` | 15 min |
| `upcomingMore` ★ | `launches-upcoming-more.json` | 1 h |
| `previous` ★ | `launches-previous.json` | 1 h |
| `events` | `events.json` | 1 h |
| `agencies` | `agencies.json` | 24 h |
| `launchers` | `launchers.json` | 24 h |
| `cores` | `cores.json` | 24 h |
| `astronauts` | `astronauts.json` | 24 h |
| `astronautsInspace` ★ | `astronauts-inspace.json` | 15 min |
| `astronautsSearch` ★ | `astronauts-search.json` | 24 h |
| `spacestations` | `spacestations.json` | 24 h |
| `expeditions` | `expeditions.json` | 1 h |
| `dockings` | `dockings.json` | 1 h |
| `pads` | `pads.json` | 24 h |
| `stats` ★ | `stats-years.json` | 24 h |
| `onthisday` | `onthisday.json` | 1 h |
| `timelines` | `timelines.json` | 1 h |
| `videos` | `videos.json` | 1 h |
| `gallery` | `gallery.json` | 30 min |
| `satellites` | `satellites.json` | 24 h |
| `orbitStats` ★ | `orbit-stats.json` | 24 h |
| `debrisEvents` ★ | `debris-events.json` | 24 h |
| `neoNears` ★ | `neo-nears.json` | 1 h |
| `news` | `news.json` | 1 h |
| `apod` | `apod.json` | 6 h |
| `epic` | `epic.json` | 6 h |
| `nasaImages` ★ | `nasa-images.json` | 24 h |

以 `constants/Dataset.ets` 的 `FILES` / `SOFT_TTL` 为准（两者已与小程序侧逐值比对）。
上表 TTL 为示意，实际值见代码。

## 三、分片数据集

`gallery` 与 `satellites` 是「索引 + 第 0 片」，后续片按需拉：

```
space-data/gallery/1.json
space-data/satellites/1.json
```

索引载荷带 `count` / `chunks` / `total`，触底时按 `chunks` 循环拉取。
卫星目录两万余条，每片 800。

## 四、字段命名

**保留 LL2 / slim.js 的 snake_case**（`full_name`、`window_start`、`imageThumb` 混合），
不转成驼峰。理由：与线上 JSON 一一对应，`as` 断言零成本，排查时不用心算。

interface 定义在 `model/*.ets`，按数据集分文件：

| 文件 | 覆盖 |
|---|---|
| `Common.ets` | LaunchSummary 及其子结构（状态/火箭/任务/工位/机构/视频） |
| `Launch.ets` | upcoming / upcomingMore / previous 的 payload |
| `Astronaut.ets` | astronauts / astronautsInspace / astronautsSearch |
| `News.ets` | news |
| `Apod.ets` | apod / epic |

其余 22 个数据集**尚未定义 interface**，第二阶段按需补。
在补齐之前，`Repository.load<T>()` 的泛型参数可以直接用 `Object`。

## 五、字段来源要看小程序侧这三个文件

契约的真实来源不在本仓库，在小程序仓库：

| 文件 | 作用 |
|---|---|
| `scripts/lib/slim.js` | **字段结构的唯一权威**。每个数据集的 slim 函数定义了上游 LL2/NASA 的原始字段如何映射成这里的 JSON |
| `utils/data.js` | `FILES` / `SOFT_TTL` / `EVICT_ORDER` / `HOURLY_CACHE` 的原始定义，`Dataset.ets` 逐条翻译自它 |
| `utils/format.js` | 中文字段（`nameZh` 等）的格式化规则，以及专名白名单 |

**改契约时的顺序**：先改小程序侧 `slim.js` → 等 CI 跑一轮产出新 JSON → 再改本仓库 `model/*.ets`。
反过来会编译过但运行时字段缺失。

## 六、几个已踩过的坑（别重犯）

- **发射时间字段是 `net`**，不是 `window_start`。`window_start`/`window_end` 是窗口范围，
  `net` 才是「不早于」的发射时刻（可能被推迟）。列表按 `net` 排序。
- **任务名用 `mission.nameZh || mission.name`**，不是顶层 `item.name`。
  顶层 `name` 是 LL2 的 launch 名（如 "Falcon 9 Block 5 | Starlink Group 6-1"），两者经常不同。
- **`astronauts.json` 有 `nameZh`**（862 条中 830 条非空，由 CI 的 `fillAstronautNames()` 回填）。
  早期文档说"没有 nameZh、中文名全靠前端查表"已过时。
- **`vid` 字段在线上 v14 的 upcoming/previous 里已不存在**，但小程序侧 `utils/media.js:134`
  与 `scripts/verify-pure.js:519` 仍在消费。接媒体页前必须先拿真实数据确认。
- **图库索引签名**含 `{slice, count, chunks, total}`，`total` 只给第 0 片。
  早期签名漏了 `count`/`chunks`，导致尾部追加时第 0 片被跳过、count 永久停在旧值。
- **`EMPTY_SUSPECT`** 只有 `apod` 与 `epic` 两个数据集：空列表视为过期（上游停更时会出现）。
