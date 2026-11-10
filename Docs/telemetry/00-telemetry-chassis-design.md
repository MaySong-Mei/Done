# 遥测底盘设计(Telemetry Chassis)— v1 裁决稿

日期:2026-10-24。分支 king-of-rubbish-bin @ fd92618。实施票:#273。拍板来源:#197(2026-08-26)。
过程:蓝图 v0 → 三方对抗(事实核查 A / 攻击 B / 独立设计 C,见 `round1/`)→ 本稿裁决。
修订:2026-11-09 §6.3 功能使用改为分阶段(进入 / 用了 / 完成 / 放弃 + 停留),附逐站点清单(king @ 81d0999f)。
本稿只做「纯粹的数据收集」。agent 自动分流、候选修复不在范围(另议)。

## 0. 一页结论

- **一种形状**:所有观察系统都写成 `SpikeRun` 信封里的记录,默认粒度是「每台设备每天一行固定键计数」,事件型记录(自动窗口、手动 spike、判定快照)原样保留。
- **一条通道**:记录落在现有 `Documents/spike-runs/*.jsonl` 池;上传器是单写者,按每条记录的单调 `revision` 推进游标,不用内容哈希。
- **一张表**:`public.spike_runs`,主键 `(user_id, run_id)`,写入即覆盖但服务端拒绝旧 `revision`;不进同步变更流,不进快照;账号删除级联。
- **只靠 SQL 读**:每个观察系统注册时必须指名一条消费视图,且视图要有定时读者(每周 checks 回帖 #273),否则不许开。
- **同意水位**:开关默认关;打开那一刻记 `consent_at`,只上传此后的记录;观察站几周的历史不外流。`note` 是唯一自由文本,单独开关。
- **激活是功能不是文案**:TestFlight 构建首页一次性卡片 + 测试说明明文请求 + 成功判据(发包 7 天 ≥2 台开启),否则下一片做激活而不是再加采集器。

对抗改掉了 v0 的六处:内容哈希游标(每次冷启动会全量重传且全程 2xx)、复用不到的 Debug 闸门位置、缺失的认领键(升级日/换账号日/旅行日数据全错)、退后台边沿上传不包后台任务、每日汇总每个边沿都重传、自由文本出口有三个不是一个。替代设计 C 嫁接进来三处:同意水位、服务端 revision 守卫 + Swift 生成的键注册表、合并直方图作为第二读法。C 的「行里不放 user_id」没有采纳,理由见 §8.1。

## 1. 目标、非目标、已拍板

**六个要用 SQL 回答的问题**
1. 已合入的性能修复(#201 / #213 / #214)在现场达标没有。
2. 哪些功能 30 天没人用。
3. 同步 / 存储 / 恢复在现场多久失败一次;新构建有没有让某类错误变多。
4. 卡顿 / hitch / 峰值内存按构建的趋势。
5. 多少活跃设备、各在什么构建。
6. (后续)用户主动报告的问题及其现场。

**现实约束**:TestFlight 签名的容器 `devicectl device copy from` 拉不出来(#235),观察站数据现在只能一台台打开设置页看。

**非目标(本期)**:agent 自动分流/修复;第三方分析 SDK;`BGTaskScheduler` / `UIBackgroundModes` / 后台 `URLSession`;上传原始日志、MetricKit 原始 JSON、事件标题/备注/照片;服务端重算判定;面板。

**已拍板,不重议(#197 2026-08-26)**:`spike_runs` 表;关闭即尽力上传 + 启动补传;默认关的独立开关;指标默认可传、原始内容显式 opt-in;schema 与用户数据分离;agent 侧直接 SQL 读。

## 2. 对抗过程与主要裁决

| 来源 | 发现 | 裁决 | 落点 |
|---|---|---|---|
| B·F9 (P0) | 内容哈希游标:`SpikeRunStore` 的 `JSONEncoder` 未设 `.sortedKeys`,字典序每进程随机 → 每次冷启动全量重传,幂等 upsert 把它藏得严严实实 | **成立**。弃用内容哈希,改每记录单调 `revision` | §7.2 |
| B·F27 (P0) | 默认关 + 无提示 + 二级页 ⇒ 开启数 ≈ 0 | **成立**。激活进范围并定成功判据 | §8.4 |
| B·F15/16/17 | 认领键只按 buildConfiguration;记录不带主人;dayKey 与日界时区两个来源 | **成立**。认领键 = (config, build, os, owner);dayKey/tz 取自日界 | §4.2 |
| B·F5/F6/F10/F11 | 每日汇总每边沿重传击穿预算;无脏检查;退后台上传不包后台任务;启动补传在主线程 | **成立**。每日汇总只在跨天/启动/开观察站传,边沿只传事件记录并包 `beginBackgroundTask`;脏检查;补传延后 2s 走 `.utility` | §7.1 |
| B·F1/F21/F24/F37 | 字符串键四处手工登记是死线之源;自由文本出口三个(`note`/`abortReason`/`.string` metric) | **成立**。usage/incident 键改枚举下标;`abortReason` 改枚举;统一 Redactor + 字节级哨兵测试 | §5, §11 |
| A·#20 | Debug→生产闸门在 `SupabaseSyncService.uploadsBlockedByBuild`(:956-958),不在 `SupabaseREST.send` 里,新上传器复用不到 | **成立**。上传器只问同一个属性;源扫描禁第二个 `#if DEBUG` 闸门 | §7.4 |
| A·#23 | #266 擦除注册表尚未实现,现行是手工清单 + `EraseWiringQATests` 字符串断言 | **成立**。游标与 installID 文件放进 `spike-runs/` 目录,随 `SpikeRunStore.wipe()` 一起擦;再加一条 QA 断言 | §7.5 |
| A·#17 | MetricKit 回调未读 `diskWriteExceptionDiagnostics` | **成立**。补读计数 | §6.5 |
| A·#6 | 观察站没有「启动」flush 边沿 | **成立**。启动边沿由上传器自己加(只读不写) | §7.1 |
| B·F14 | 复用 `send` 但遥测表绝不能进 015 触发器循环,否则 sync 暂停时遥测跟着被拒 | **成立**。迁移明确不入表数组;checks 断言该表无 `trg_*_sync_gate` | §9.3 |
| B·F31 | 「视图 = 具名消费方」不是消费方 | **成立**。开启条件改为「视图有定时读者」 | §5, §9.5 |
| B·F18 / C·坚持2 | 键级「死线 vs 真零」不可分 | **成立**。Swift 枚举导出 `key_registry(since_build, retired_build)`,视图把「不应出现」读成 NULL;sessions 作分母;源扫描死键红 | §9.4 |
| B·F22 / C·坚持2 | 挂起的旧请求可能晚于新请求到达 | **成立**。单写者上传器 + 服务端 `revision` 守卫触发器 | §7.2, §9.2 |
| C·坚持1 | 同意前采集的历史记录在开关打开时外流 | **成立**。`consent_at` 水位 | §8.2 |
| C·坚持3 | 行里不放 `user_id`,独立不暴露 schema,写走 definer RPC | **不采纳**。级联删除是结构保证,forget RPC 是尽力;隐私标签按 Apple 定义两种做法都是 linked(API 日志里 JWT sub 与请求体并存);开发者本来就能读用户表。保留 `user_id`,但共享/喂 agent 的视图一律聚合、不暴露 install 级设备列 | §8.1 |
| C·L2 | 池放 Documents 随 iCloud 备份 | **延期**。池本来为 devicectl 导出放 Documents;总量 ≤ ~1.3MB 有界;游标文件标 excludedFromBackup | §14 |
| C·让步1 | 窗口折进直方图丢失对拍 oracle | **按 C 自己的让步**:窗口原样上传是判定权威,合并直方图只作第二读法 | §6.1, §9.5 |
| B·F7 | diskWriteException 之忧 | **非问题**:~120KB/天 vs 1GB/天阈值,差四个数量级 | — |
| B·F1(性能面) | 字符串键线性比较 | **非问题**:最坏 0.6µs/emit;改枚举是为了消灭手工登记,不是为了性能 | §5 |

完整条目见 `round1/B-attack.md`(F1–F41)、`round1/A-facts.md`(38 条核对表)、`round1/C-alternative.md`(比较矩阵与三坚持三让步)。

## 3. 底盘分层

| 层 | 内容 | 现成的 | 本期新增 |
|---|---|---|---|
| L0 信号 | 热路径上 O(1) 固定键 bump;禁 UserDefaults / Calendar / 落盘 / 网络 / publish / 字符串分配 | `ResidentTierOneCore`、`SpikeProbe.emit` | `UsageKey` / `IncidentKey` 枚举下标计数;`UsageProbe` 的 enter / use / done 只许在用户动作闭包和手势结束处调,`onAppear` 不许记进入(§6.3 落点规则) |
| L1 聚合 | 每日汇总(counter / 固定桶 histogram / gauge last·max·n);事件记录(窗口、手动 run、判定快照) | 观察站 | 脏检查(`ResidentCounterSet` 已 Equatable);`evictedUnuploaded` 删失计数 |
| L2 落盘 | `Documents/spike-runs/<spikeID>.jsonl`,同 id 最新胜,200 run / 256KB→128KB 压实 | `SpikeRunStore` | 每记录 `revision`;MetricKit 独占文件且回调 hop 到 main |
| L3 上传 | 单写者(`@MainActor` 类 + 串行 Task);`revision` 游标 + 隔离集;四个触发点;keep-alive 包退后台边沿;复用 `SupabaseREST.send` 的鉴权/401 重试/offline 开关;**上传器随 `DoneApp` 的 @State 初值创建**(不是 onAppear),ContentView 的 attach 幂等并有 onChange 兜底;每个门拦截结果变化时打 trail | `SupabaseREST` | `TelemetryUploader`、`.upload-cursor.json`、`.install-id`、Redactor |
| L4 服务端 | `public.spike_runs` + `revision` 守卫触发器 + RLS 只写不读 + `key_registry` + 视图 + `telemetry_checks.sql` | 015 的 RLS/checks 范式 | 迁移 016 |
| L5 读侧 | 视图 = 具名消费方;每周 checks 回帖;共享视图只聚合 | — | 五条视图 + 一条孤儿/死线诊断视图 |

## 4. 记录信封

### 4.1 字段(`SpikeRun` 扩展,旧行兼容全部可选)

现有:`id, spikeID, scenarioID, variantID?, startedAt, endedAt?, appVersion, appBuild, appCommit?, deviceModel, osVersion, timeZoneIdentifier, localeIdentifier, buildConfiguration?, coActiveSpikeIDs?, metrics: [String: SpikeMetricValue], note?, outcome?, abortReason?`(`Done/Models/SpikeModel.swift:232-280`)。

新增(全部可选,解码旧行不报错):
- `installID: UUID` — 本机随机,文件 `spike-runs/.install-id`,擦除轮换;不用 identifierForVendor(仓库里本就没有)。
- `ownerUID: String?` — 记录落盘时的登录账号,由 `SpikeRunStore.appendLine` 统一盖戳(与 `revision` / `installID` 同一咽喉)。写入方通过 `OwnerStamp { fromProvider | explicit(String?) }` 表态:手动 runner 用 `fromProvider`(店里的当前登录者),观察站的 daily / 窗口 / 关旧记录一律 `explicit(claim.ownerUID)`,所以签出期的记录即使在登录后被关掉,owner 仍是 nil(review P1-1)。`nil` = 签出期,永不上传。
- `dayKey: String` — 以日界的 `calendar.timeZone` 对 `dailyRunStartedAt` 取 startOfDay 格式化,铸 id 时写一次。
- `dayTZOffsetMin: Int` — 日界时区在该日的偏移分钟;上传后替代 `timeZoneIdentifier`。
- `revision: Int` — 该 id 每次 append 递增;游标和服务端守卫都看它。
- `kind: enum` — `dailyRollup / window / manualRun / verdictSnapshot / metricKitDaily`(`userReport` 预留)。
- `abortReason` 由 `String?` 改为枚举。实施时清点为五个字面量(`SpikeModel.swift:330`、`ResidentObservationCenter.swift:218, 223`、`Spike195DetailPerf.swift:354`、`Spike201EffortTap.swift:223`)→ 五个 case;旧行里的未知字符串解码为带关联值的 `.legacyUnknown`,原文只留本地,`wireValue` 为 nil 永不上传。

不上传的本地字段:`localeIdentifier`(B·F23:对一小撮内测者几乎等于实名,且六个问题都不用它)。

### 4.2 认领键(修正 A·#6 / B·F15/16/17)

今日 daily 记录的 run id 只在 `(buildConfiguration, appBuild, osVersion, ownerUID)` 全部相同时接管;任一不同就为同一天铸新 run id。视图对同 `(install_id, day_key)` 求和。效果:TestFlight 当天自动升级,上午的计数留在旧构建;同机换账号,各归各主;签出期的计数 owner 为 nil,不出设备。
进程内登录/登出(不重启):关旧 run id、铸新 id;切换与下一次 flush 之间的少量信号归旧 owner,与午夜 hop 同级的既定不精确。nil owner 与 nil owner 视为同主(签出期每日一条本地记录)。

### 4.3 不变量

- `metrics` 的键只能来自编译期注册表;未知键 seed 时丢弃并计 `unknownKeyDrops`(运行时可测)。
- 每个键声明值类型:`number | fixedFormatString(regex) | bool`;`.string` 只允许直方图/列表的固定格式(观察站现有 `"0 3 9 …"`)。
- 自由文本只有 `note`。Redactor 在序列化后的行上按 `(kind, key, 值类型)` 白名单过滤,是外发前最后一道,不依赖上游自觉。

## 5. 注册表契约(观察系统怎样插上来)

每个观察系统 = 一条编译期条目:

```
id · tier(daily | event) · keys(枚举,CaseIterable)
每键:name(点分小写,全局唯一)· kind(counter | histogram(buckets) | gauge)· valueSchema · sinceBuild · retiredBuild? · livenessKey?(tripwire 必配)
privacyClass:metric(默认可传)| enumContext | rawContent(仅 note)
costContract:每信号 O(1);每日最多 N 条事件记录
consumerView:具名 SQL 视图(必填)
reader:定时读者(必填;本期 = 每周 telemetry_checks.sql 回帖 #273)
acceptance?:修复验收方向(键、方向、阈值)— 本期不实现字段,阈值仍在 Evaluator(A·#5)
```

规则:
- 键只增不改义;改义 = 新键 + 旧键填 `retiredBuild`;条目退役不删(R-F11)。
- `CaseIterable` 导出 `done-mcp/supabase/telemetry/key_registry.json`,迁移里的 `key_registry` 表由它生成,测试逐行对拍;服务端注册表不手抄。
- 源扫描:每个键 case 在 `Done/` 非测试源码里至少一处引用,否则红(死线)。
- usage 键的 emit 只许在用户动作闭包与手势结束处,不许在 `body`(B·F2:body pass 数的是重渲染),进入不许在 `onAppear`(返回、重建、启动选 Tab 都会再触发);`onChange` 只在排除了程序写入和同步写入后才可用。细则见 §6.3。服务端 sanity 视图:某键日计数 > 当日 `detailBodyPasses` 即标 suspicious;分阶段一致性见 `v_usage_suspicious`。
- 多个观察系统共用一个 resident、一个 switch(B·F3),不各自注册。

## 6. 首批观察系统

### 6.1 观察站(已存在)
`resident-daily` 每日汇总与 `auto-window`(≤12/天)原样上传;窗口记录是问题 1 的判定权威,与设备卡片逐项对拍。合并直方图(全体设备按桶相加)作为第二读法,只回答「样本量够不够」,不作判定。

### 6.2 判定快照 `verdictSnapshot`(修正 B·F28)
评估器是纯函数(`FixWatchView.swift:213-222` 两次 `loadRuns` + 算术)。改为在跨天 flush 之后和启动补传之前各算一次(off-main),打开观察站只是额外一次。每个修复条目两个键:`state`(4 态枚举数值)+ `alarm`(bool)。

### 6.3 功能使用 `usage-daily`(2026-11-09 改为分阶段)

用户 2026-11-09:「很多东西都要考虑是进入了还是使用了,粒度或许要细致一点」。原稿每功能每天一个数,#273 的起步清单里「打开」和「提交」混记:「重复事件 0」分不出是没人发现,还是有人打开了又退出。改为每个功能按阶段记。

**阶段**(每个功能只登记它有的阶段)
- `enter.<入口>`:到了这个功能里。必带入口细分(如事件详情的 `canvas` / `menu` / `list` / `search`),每个入口在注册表里标来源 `user`(用户点进来)或 `auto`(非用户动作带进来,如横屏自动进 Focus 的 `focus.enter.auto`、自动弹出的恢复面板)。启动时落在哪个 Tab 不算进入。
- `use`:在里面动了手(改了、发了、拖了、切了)。可带细分(`focus.use.extend`)。
- `done`:留下了结果(保存、提交、生成)。
- `abandon`:一次访问从进入到离开没有任何 `use` / `done`。
- 可选 `view.<子页>`:看了某个子页面(如详情的反思页),不算动手,不影响 `abandon`。

**停留**:有界面的功能每次访问结算一次 `usage.<功能>.dwell`,直方图,边界 3 / 30 / 300 秒,四档;只记档位,不记时间点。停留只算前台时间(退后台暂停,回前台继续,回前台不算新进入);进程在后台被杀的访问不结算,不计停留也不计放弃。访问在离开那天结算。

**键名**:`usage.<功能>.<阶段>[.<细分>]`,例如 `usage.focus.enter.tap`、`usage.focus.enter.auto`、`usage.event_detail.enter.search`、`usage.focus.use.extend`、`usage.event_detail.abandon`、`usage.focus.dwell`。服务端视图按前缀切分(同 `sync.write.` 的做法),只认注册表里的键。

**登记**:`enum UsageFeature: UInt16, CaseIterable`,每个 case 声明自己的阶段、入口(及其来源)和细分;`UsageKey` 由它派生,登记一个功能 = 加一个 case。分母 `sessions`(键名沿用 016 checks 夹具与 `liveness_key`)= 后台→前台次数(不用 `didBecomeActive`:控制中心、Face ID、系统弹窗也会触发)。

**落点规则**(替换 §3 L0 与 §5 原来「action 闭包 / `onAppear` / `onChange`」的写法)
1. `enter` 只记在打开它的那一下用户动作里(按钮 action、点按回调)。不许在 `body`,也不许在 `onAppear`:从下一页返回、视图重建、启动选 Tab 都会再触发(`ReportViews.swift:66`、`FixWatchView.swift:96`、`ContentView.swift:297`)。
2. 非用户动作带进来的,在触发处记 `enter.auto`(如 `DoneApp.swift:828` 横屏判定)。
3. 由 `onChange` 观察的状态(Tab 选择、设置开关)必须先排除程序写入和跨设备同步写入:Tab 的 `onChange`(`ContentView.swift:371`)也会被启动选 Tab(:297)和「我」页的跳转(`AnalysisView.swift:829`)触发;多数设置键会从别的设备同步过来(`SyncedSettings.swift`),直接挂 `onChange` 会把远端改动算成本机使用。
4. 手势只在结束(commit)那一下记,不在逐帧回调里记。
5. `done` 记在通向保存的那个用户动作里,不记在 store 内部:store 层的写入也会被同步回放、agent / MCP 写入触发。
6. 同一界面从几处打开,每处入口都要记,来源一致;源扫描测试保证每个声明了 `enter` 的功能有结算点(离开)。

**和数据库的分工**:会留下数据的功能,`done` 在云端按账号、按日期本来就数得出来;埋点重点补 `enter` / `abandon` / 停留。设备上照样记 `done`,每周和云端对一次数(同账号全部设备求和),差得多说明漏了落点。

**一致性检查(服务端)**:同一 (install, 日, 功能):`abandon ≤ enter 合计`;停留各档之和 ≤ `enter` 合计;有 `enter` 阶段的功能出现 `use + done > 0` 而 `enter = 0` → 标 `missing_enter`(漏了入口)。这三条进 `v_usage_suspicious`。

**成本**:每次信号仍是 1 次下标 + 1 次加;每个打开中的界面在内存里放一个访问记录(进入时刻 + 有没有动过手),离开时 ≤3 次比较 + 2 次加。键数从 23 涨到约 150(清单见 §6.3.1);值为 0 的键不写进记录(服务端 `counter_long` 按注册表把缺失读成 0,契约 §4),一条日记录通常 <2KB,在 §10 预算内。

**隐私**:不变。只有整数和固定档位,不记标题、内容、时间点。

#### 6.3.1 功能清单(2026-11-09,king @ 81d0999f 逐站点核对)

缩写(路径相对 `Done/`,不带目录的在 `Views/Calendar/` 下):PV `Views/Calendar/CalendarPageView.swift` · DV `CalendarEventDetailView.swift` · FV `CalendarEventFormView.swift` · SH `CalendarEventSheets.swift` · SV `CalendarSearchView.swift` · TS `Components/TodoStackView.swift` · HV `Components/Header/AppleCalendarHeaderView.swift` · DL / TL `Components/Timeline/CalendarDayLayerView.swift` / `TimelineView.swift` · RP `Components/Reminder/ReminderPanelView.swift` · CV `CalendarEventChatView.swift` · FM / FE `Views/Focus/FocusModeView.swift` / `FocusModeEventView.swift` · APP `DoneApp.swift` · OM `Models/OrientationManager.swift` · CT `ContentView.swift` · AS `Views/Agent/AgentSettingsView.swift` · AV `Views/Analysis/AnalysisView.swift` · RV `Views/Analysis/ReportViews.swift`。行号只作实施起点,落点以源扫描测试为准。

**日历**

| 功能(键前缀) | 进入 | 用了 | 完成 | 放弃 / 离开 | 注意 |
|---|---|---|---|---|---|
| Tab(`tab.calendar` / `tab.report` / `tab.me`) | 点 Tab 栏:`CT:371` 的 `onChange(selectedTab)`,排除程序写入 | — | — | 停留 | 启动选 Tab(`CT:297`,还会随视图重建再跑)和「我」页跳日历(`AV:829`)都会写 `selectedTab`,写之前打标记 |
| 事件详情 `event_detail` | 细分 `canvas`(DL:6819→PV:4740;全天条 TL:2867)· `menu`(PV:2473 / 2489)· `list`(`CalendarListView.swift:28`)· `search`(SV:748 / 765 / 845 / 873) | 细分 `plan`(类型 784/796、时长 3451/3467、重复 1513、改名 3560、编辑 3565)· `reflect`(完成 2574、精力 3542、标签 2205/2218、备注 2302、模板 1159)· `timeline_note`(3108/3284/3356/3255)· `todo`(2425/2442/2543/829/874)· `delete`(954) | 无保存按钮;动过手即「留下」 | 返回 1201、侧滑;`abandon` = 没动手就走 | 另记 `view.reflection`(翻到反思页,不算动手;`selectedPage` 目前没人观察);`onDisappear`(471)推聊天页时也会触发,不能当离开;`DV.onAppear`(975)从聊天页返回会再触发 |
| 新建 `create` | 细分 `drag`(DL:8086→PV:6078)· `plus`(PV:3137)· `resume_draft`(PV:6880)· `reminder_ai`(PV:6164,异步 AI 后才弹) | — | FV:434 Done;另记 `done.repeat` / `done.all_day` / `done.note`(保存时带了这项) | `abandon.cancel`(FV:416)· `abandon.swipe`(FV:210)· `abandon.banner`(PV:6917) | Done / Cancel 都回调 nil,要用 `draftSession.endedExplicitly` 区分;AI 关或失败的回退另记 `create.ai_fallback`(PV:6181 / 6249) |
| 重复规则 `repeat` | 新建表单里打不开观察(Menu);详情里的规则编辑器 DV:1513 | 选了非「不重复」(FV:683,需新加 `onChange`,排除草稿恢复 SH:85 / 414) | 规则编辑器 Save(`CalendarRecurrenceRuleEditor.swift:165`);新建时见 `create.done.repeat` | 编辑器 Cancel(:162) | |
| 全天 `all_day` | — | 开关 FV:595(仅事件类型显示) | 见 `create.done.all_day` | — | |
| 照片 `photo` | 系统相册选择器不报打开 | 选了图:DV:2360(反思页)、DV:4772(时间线备注);只在新数量 > 0 时记 | 反思页图片立即保存(2376);备注图片随备注保存(4730) | 不可观察 | 选完重置选择(2367 / 4812)会让数量 `onChange` 再触发一次 |
| 待办栈 `todo_stack` | PV:3131 | 展开 TS:881 · 新增 TS:820 · 开始拖 TS:935 | 拖到画布成功 TS:194-201 | `drag_cancel`(TS:203 / 207)· 关闭 X 777 / 背景 61 / 下滑 689 | 进 Focus 时自动关(TS:115),不算放弃;`onDisappear`(503)会存半截标题,不算新增 |
| Focus `focus` | `tap`(PV:3153)· `auto`(横屏 + 设置,APP:828);两者都在 APP:791 `onChange(focusActive)` 读 `manualFocusActive` / `autoFocusTrigger` 分来源 | `extend`(FE:228→APP:929)· `end_now`(FE:230→APP:941)· `note`(FE:291 / 304→APP:882)· `track`(`FocusModeClockView.swift:165`→APP:908) | 预建选择器 Begin(`FocusPreCreateView.swift:256`) | 离开细分 `swipe`(FM:640)· `rotate`(OM:637)· `system`(FM:1120 前台恢复 / OM:536 关设置);预建 Cancel(:244) | 退后台(FE:102)和 `onDisappear`(FE:110)自动存的备注不算 `note`;部分事件不显示快捷操作(FM:255) |
| 手势 `pinch` / `view_mode` / `move` / `resize` | — | 捏合结束 TL:2222→PV:4885 · 视图切换 HV:169 / 183→PV:3119(细分 day / 3day / week)· 移动提交 PV:4826(细分 `same_day` / `cross_day`,5509)· 调时长 PV:4863 | — | — | 不在逐帧回调里记;排除几何夹紧(PV:4113)和启动恢复视图(`CalendarViewState.swift:59`、PV:2851);浮动 chip 已关(DL:6665),跨日移动走普通移动 |
| 精力滑杆 | — | 已有观察站 `tapCount` / `dragCount`(`GlassCardView.swift:276 / 285`),复用不另记 | 提交 DV:3542(值没变不写) | — | 退后台 flush(:125)不算 |
| 搜索 `search` | PV:3127 | 稳定后的查询(SV:610,不按每个字) | 点结果(→ `event_detail.enter.search`)· `jump`(跳到日历 768 / 876 / 881) | 返回 SV:695、侧滑 | `SV.onAppear`(649)返回时再触发 |
| 每日分享卡 `share_card` | PV:3155 | 换样式 PV:3295 | 导出闭包 `CalendarDailyShareCard.swift:821`(弱代理:`ShareLink` 不报完成,预览也走它) | Done 3196、下滑 | |
| 提醒面板 `reminder` | 过度下拉 PV:4538→6141(逐帧回调,只在关→开那一下记) | 新增 RP:200 / 206 · 勾选 155 · 改名 281 · 删除 171 | 排进日历 RP:267 / 285→PV:6164(→ `create.enter.reminder_ai`) | PV:6150、RP:126 | RP:83 / 250 / 295 的自动保存不算 |
| 打断 `interrupt` / 并行 `parallel` | 画布菜单 PV:2481 · 详情 DV:1287;并行 DV:1290 | — | 计划打断 PV:2564 · 实时开始 2573 / 结束 2593 · 详情保存 DV:4184;并行保存 DV:4389 | PV:2596 · DV:4170;并行 DV:4376 | |
| 吸收 `absorb` | 选择器 DV:656 / 2465 | — | 画布放下 PV:5543 · 待办栈放下 PV:2356 · 选择器选中 DV:677 / 2487 | 选择器取消 DV:699 / 2509 | store 吸收时自动完成待办(`EventStore.swift:396`)不算 |
| 事件聊天 `event_chat` | DV:1321 | 发送 CV:150 | — | CV:49、侧滑;停留 | 首次打开自动发种子提示(CV:190),不算发送 |

**其他页面**

| 功能(键前缀) | 进入 | 用了 | 完成 | 放弃 / 离开 | 注意 |
|---|---|---|---|---|---|
| Agent 对话 `agent_chat` | 顶栏工具 HV:159→PV:3123(默认收在「…」菜单) | 发送 `AgentChatView.swift:150` · 新对话 :64 · 切历史 `ConversationHistoryView.swift:52` · 从消息打开事件 :106 | 确认待执行动作 :118(取消 :119 记 `abandon.action`) | 下滑关闭;停留 | 聊天视图没有 `onDisappear`,离开要在 sheet 的 `onDismiss` 记 |
| 报告 `report` | Tab 栏(`tab.report`) | 切周期 RV:73 · 前后翻 84 / 101 · 打开旧报告 169 · 评分 406 · 写备注 373 · 删除 175 | 生成 RV:147 / 136→214,成功 248;失败另记 `generate_fail`(254) | — | `RV.onAppear`(66)每次切回和从报告返回都触发;报告详情从两处打开(64 / 170) |
| 我 `me` | Tab 栏(`tab.me`) | 编辑资料 AV:781(保存 2499 / 取消 2496)· 性格生成 1090 / 刷新 1017 · 周分享 959(分享 2835)· 周分析 885 · 反思提交 1506 · 连接 993 · 奖杯 1171 · 设置 683 | 见「用了」里各自的保存 | — | 语言切换自动重算性格(1029)不算;`meComputedVisible` / `Hidden` 数的是渲染次数,不是进入 |
| Agent 设置 `settings_agent` | AS:366 · 聊天齿轮 `AgentChatView.swift:73` | 供应商 AS:175 · API key :186(按提交记,不按每个字)· 开关 :209 · 清规则 :237 · 清决策 :241 | — | 没改就走 | |
| MCP 连接 `mcp` | AS:389 · AV:993 | 复制 `AccountView.swift:457` · 显示 :448 · AI 快照链接 :532 | 生成 :409 / 重新生成 :482→506,成功 :512 | — | `mcpURL` 会从别的设备同步过来(`SyncedSettings.swift:114`),同步来的不算生成 |
| 人物 `people` | AS:356 | `PeopleSettingsView.swift`:新增 36 / 37 · 改名 129 · 归档 130 · 分组 87 / 183 / 205 | — | 没改就走 | 日历里的人物选择器(`EventPeoplePickerView.swift`)写同一份数据,另设 `people_picker`,落点待实施时补 |
| 节假日 `holidays` | AS:341 | 开关 `HolidaysSettingsView.swift:36 / 38`(需新加处理)· 纪念日编辑 43 / 新增 51 · 删除 199 | 保存 213 | 取消 210 | 这两项数据不同步,`onChange` 可用 |
| 云端恢复 `restore` | `tap`:AS:800(恢复)/ 788(预览);`auto`:CT:499 自动弹出 | 合并 `RestoreSheet.swift:156` · 覆盖 167(确认 64)· 保留本机 / 云端 / 逐条 250 / 261 / 272 · 逐行 632 | 各 `apply` 之后,或完成页 Done :425 | 取消 :43 · 对话框取消 :67 · 下滑(:54 `onDisappear`) | `RestoreSheet()` 没有来源参数,要加一个才能分 `tap` / `auto` |
| 观察站 `fixwatch` | AS:413 / 750 | 上传开关 `FixWatchView.swift:115` · 备注开关 :133 · 看样本 AS:1157 · 立即上传 AS:1168 | — | 没改就走 | `FixWatchView.onAppear`(96)从 Spike 列表返回再触发;TF 默认开(`TelemetryUploader.swift:654`)不算用户打开开关 |
| 通用设置 `settings_general` | 设置页本身 | 只用自定义 Binding 的 setter 记 | — | — | 多数设置键会从别的设备同步(`SyncedSettings.swift`),挂 `onChange` 会把远端改动算进来 |

**现在够不着的功能**(不登记键;功能恢复时再登记。前 4 项在 #273 起步清单里)
- Wanna 打开:Tab 06-22 拿掉(e659e06a);`WannaListView` 没有任何地方创建,`completeWanna` 只在它和 `WannaDetailView` 里调。
- LogSheet 提交:`CalendarEventLogEditor` 没有任何地方创建;记录实际在事件详情反思页里改,归 `event_detail.use.reflect`。
- 反馈提交:没有用户提交入口;`event_feedback` 行在第一次打开事件聊天时自动写(CV:39→`EventStore+OccurrenceRecords.swift:478`),所以云端 `event_feedback` 行数不是使用量。
- 小组件深链进入:全仓库(含 `DoneWidget/`)没有 `onOpenURL` / `widgetURL` / 用户活动 / 通知入口;URL scheme 只用于登录回调。手表只经 `WCSession` 传数据,不导航。
- 计时器开始:只在 `EventGridView.swift:344`,该视图没有地方创建。
- Domino:只有自动(APP:760 / 806 / 1008),不是用户功能。
- 地点:没有输入框,只由提醒 AI 预填。
- 智能录入的照片提交、乐观创建横幅(`CalendarAgenticCreateView`):只有测试调用。
- 页面级聊天入口(PV:1250 / 1570):目的地从不被设置。

### 6.4 错误计数 `incident-daily`(采 C 的接法,不接 104 处轨迹点)
接类型化咽喉,而不是给每处 `DiagnosticTrail.record` 发 ID(全库 104 处,随重构漂移):
- `SyncWriteFailureKind` 8 个 case 各一键(`SyncWriteFailure.swift:28-62`);写成功 1 键。
- 拉取 ok/fail;恢复 started/ok/fail;存储 commit ok/fail;`SlotFault` 5 个 case(`DurableEventStorage.swift:130-155`);`writeFailedSlots` 进入次数;擦除 started/ok;`appUncleanExit`(上次进程脏退出标记)。
- 轨迹兜底:`DiagnosticTrail` 在自己的锁下维护按类别的固定 `[Int]` 计数(它已有 NSLock,`DiagnosticTrail.swift:44`),flush 时读走;类别→下标用编译期枚举,未映射类别计 `trailUnmapped`。不跨线程往 @MainActor core 投递(B·F4)。

### 6.5 MetricKit 日摘要 `metrickit-daily`(修正 A·#17 / B·F8)
`AppMetricsReporter` 回调不在主线程,hop 到 main 再写;独占文件;`dayKey` 取 payload 的 `timeStampBegin`,`appBuild` 取 payload 的 `applicationBuildVersion`(不是当前进程)。键:`hitchRatio`(gauge)、`peakMemMB`(gauge)、`hang`、`crash`、`cpuException`、`diskWriteException`(counter)。原始 JSON 继续只留本地。崩溃/hang 堆栈不传,TestFlight / Xcode Organizer 已给。

### 6.6 用户报告 `user-report`(预留,最后一片)
自动抓现场 = 22 个布尔开关 + 枚举设置(清单 `round1/A-facts.md §13`;绝不抓 `agentAPIKey / mcpURL / personalityProfile / meReflectionLog / meDisplayName`)+ 构建/设备 + 可选文字。发送页原样展示将发出的内容,发送动作即同意(满足 Apple「可选披露」四条件)。轨迹片段含 uid、事件 UUID、相对路径(B·F25),若带入须替换为报告内短哈希。本期不建表。

## 7. 上传机制

### 7.1 触发点(修正 B·F5/F10/F11)
1. **启动**:`didBecomeActive` 后 +2s,`.utility` Task:先算判定快照,再按游标补传;从不在首帧前。
2. **跨天**:观察站现有的主队列 hop 写完昨日记录后,调度同一个 Task。
3. **打开观察站**:flush 后调度。
4. **退后台边沿**(resign / background / terminate,一轮一次):写盘照旧;上传只带事件记录(窗口、快照、手动 run)+ 距上次 daily 上传 ≥15 分钟(900 s 整算带)的 daily_rollup,**任何一天的**,不按今日区分;`metricKitDaily` 永不随边沿(启动触发覆盖它);整段包在 `beginBackgroundTask` 里(≈30s 窗;全 app 现有唯一同类用法 `EventStore.swift:4721`,不是被禁的后台模式),到期即 end,未完成的留给下次启动。边沿触发到达时若已有在途批次,立刻 begin 一个 keep-alive 挂到「在途 + 排队」全部完成;`start()` 在 app 非 active 时同样建。保证边沿触发的工作从不裸跑(review P2-1)。
不做:同步成功后搭车(耦合)、定时冲(独立射频唤醒)。

### 7.2 游标与幂等(修正 B·F9/F12/F13/F22)
- 游标文件 `spike-runs/.upload-cursor.json`:`run_id → uploadedRevision`。只有本地 `revision > uploadedRevision` 的记录进批;只在 2xx 后写回。
- 单写者:`TelemetryUploader` 是 `@MainActor` 类 + 一条串行 Task(不是 actor;邻居全是 MainActor,UI 要 ObservableObject),同一时刻只有一个在途批次,后到的触发合并进 `queued`;启动补传与边沿上传串行,不会重排。
- 服务端兜底:BEFORE UPDATE 触发器在 `NEW.revision <= OLD.revision` 时跳过;对客户端这仍是 2xx,游标前进是正确的(本地更高 revision 迟早会发)。
- 批:一次 PostgREST bulk upsert ≤32 条,`on_conflict=user_id,run_id`(网关加复合键参数,假服务器同样按复合键去重,B·F13)。
- 游标损坏 = 空游标 = 幂等全传,绝不 crash、绝不当「已全传」;重装无游标无记录,无可补。
- 旧 JSONL 行没有 `revision` 字段 → 解码为 0 → 永不 pending。这类行必然早于升级也就早于 consent,本来不该传;升级后同 id 再 append 的记录从 1 起算。
- 同 revision 重传在服务端是「跳过」(守卫 `<=`),对客户端仍是 2xx,`last_uploaded_at` 不动。
- **被拒行隔离**(review P1-2):整批 4xx 且分类为 `rejected / tooLarge` 时,对本批逐行重发一次;单行仍被拒的 `(id, revision)` 写进游标文件的 `quarantined`,trail 点名 run id 与 PostgREST code;`pending` 排除同 revision 的隔离条目,更高 revision 自然重试;成功行照常 acknowledge。`schemaCache`(PGRST204,迁移后 NOTIFY 前的暂态)**不**隔离,留给下次触发。Redactor 对 NOT NULL 文本列不合白名单时发 `"unknown"` 而不是删列,只删可空列与自由文本。
- 「2xx 但 0 行」不可观测(契约 `return=minimal`),靠 revision 守卫;不做 B·F36 的那个负例。
- 游标孤儿条目:每次成功落地后用本次从盘上读到的 id 集合裁掉不存在的键;「累计」是独立只增的 `totalAcknowledged`。

### 7.3 删失可见(修正 B·F19)
压实丢弃「尚未上传」的记录时,条数计入下一条 daily 的 `evictedUnuploaded`。按现有上限,窗口约保留 10 天,daily 约 150 天。

### 7.4 闸门(修正 A·#20 / B·F38)
上传器只问 `SupabaseSyncService.uploadsBlockedByBuild`(DEBUG 且 production 为真)和遥测开关;不自建第二个 `#if DEBUG`;源扫描钉死。DEBUG 的 `SYNC_OFFLINE_FILE` 拔网开关经 `send()` 自然生效。

### 7.5 擦除
游标、installID、所有记录都在 `spike-runs/` 下,`SpikeRunStore.wipe()` 已在擦除清单(`AgentSettingsView.swift:1268`);`EraseWiringQATests` 加一条「擦除后 `.upload-cursor.json` / `.install-id` 不存在且首个请求体带新 installID」。上传器任何 `await` 前 `LocalDataEraseEpoch.capture()`,回来 `isStale` 不写游标。

## 8. 身份、同意、文案、激活

### 8.1 身份(对 C·坚持3 的裁决)
行键 `user_id`(auth.uid)+ `install_id`。保留 `user_id` 的理由:账号删除级联是结构保证;Apple 隐私标签两种做法都按 linked 填(请求日志里 JWT sub 与请求体并存);开发者本来就能读用户表,假名化对开发者无增益。约束:共享给他人或喂 agent 的视图一律聚合、不含 `install_id / device_model / os_version` 列;不存 `locale`;tz 只存偏移分钟。此裁决可逆,记为决策点 2。

### 8.2 同意
- 开关「分享性能与使用统计(不含内容)」默认关,放 Data & Privacy。
- 打开记 `consent_at`(只在设置页的 OFF→ON 边沿写一次);只上传 `startedAt ≥ floor(consent_at 到整秒)` 的记录(本地存储把 `startedAt` 截到整秒,不取整的话同意后几毫秒铸出的记录会读成早于同意、被挡一整天——真机 build 17 的事故,2026-10-27);代价是同一秒内、同意之前开始的记录也会上传,上限不到一秒的计数,接受。观察站历史不外流(TestFlight 包例外,见 §16)。本地记录照旧(它是本机功能,有界、不出设备)。
- **首日不沉默**(review P2-3):OFF→ON 视为认领变化,观察站关掉当日旧 daily(其 startedAt < consent,自然不传)、`resetForNewDay`、以 now 铸新 id;当日 consent 之后的计数当天就能上传。副作用:窗口预算随之归零,同意日理论上多一轮 12 窗口,与换账号同形,接受。
- 关闭:立即停止上传,游标保留;已上传的行不删(RLS 不许 delete),文案明说「已上传的统计随账号删除一并删除」。
- `note` 第二开关「附带手动 Spike 备注(文字)」默认关;主开关 ON→OFF 时一并置 OFF(子同意随主同意撤销)。

### 8.3 文案(修正 B·F30)
- 开关副文:「仅上传计数与耗时:哪些功能用过几次、卡顿与同步失败次数、设备型号与系统版本。永不上传事件标题、备注、照片或任何文字。」
- `hintLocalData`(`AppLocalization.swift:659/1328`)按开关状态改写;`FixWatchView.swift:74` 的「所有数据只写本机」同理。`hintClearData`(660/1329)全库无显示位,不动。
- 可见反馈:开关下方「上次上传 · 条数 · 累计 · 构建」;「查看样本」展示最近一次实际请求体;「立即上传」按钮(兼作装机验收探针)。

### 8.4 激活(修正 B·F27)
- TestFlight 构建(sandbox receipt 判)设置首页顶部一次性可关卡片:「帮助改进 Done:分享性能与使用统计(不含任何内容)→ 开启 / 以后再说」,每 install 只出一次。
- TestFlight 测试说明明文请求。
- 成功判据:发包 7 天内 ≥2/N 台开启;否则下一片做激活,不再加采集器。
- 存储默认仍是关,卡片不改默认值。

## 9. 服务端

### 9.1 表 `public.spike_runs`(迁移 016)
`user_id uuid references auth.users on delete cascade, run_id uuid, install_id uuid, kind text, spike_id text, scenario_id text, day_key date, day_tz_offset_min smallint, app_build int, app_version text, build_configuration text check in ('debug','release'), device_model text, os_version text, revision int, metrics jsonb, context jsonb, note text null, outcome text, client_updated_at timestamptz, first_uploaded_at timestamptz default now(), last_uploaded_at timestamptz`。
主键 `(user_id, run_id)`;索引 `(user_id, kind, day_key)`、`(app_build, kind)`;jsonb 不建 GIN。
RLS:authenticated `select / insert / update` 自己的行(`user_id = (select auth.uid())`;PostgREST upsert 的 ON CONFLICT 需要 select);**无 delete**;anon / service_role 零授权(泄露过 service key,且表含 note)。
表名定为 `spike_runs`(拍板名、信封名一致;B·F33 不再漂移)。

### 9.2 触发器
- `revision` 守卫:BEFORE UPDATE,`NEW.revision <= OLD.revision` → return NULL(跳过)。
- `last_uploaded_at = now()` BEFORE INSERT/UPDATE(merge-duplicates 下 `default now()` 只在首插生效,B·F33)。
- 不进 015 的表数组、不挂 `trg_*_sync_*`、不进 `sync_changes` RPC、不进 snapshots。

### 9.3 checks(`done-mcp/supabase/tests/telemetry_checks.sql`,照 `sync_feed_checks.sql` 范式)
断言:重传同 revision 两次 → 一行且 `last_uploaded_at` 不动;低 revision 不覆盖高 revision;用户 A 读/改不到 B 的行;authenticated delete 被权限拒(42501);表上无任何 015 家族触发器且恰好只有自己那一个;`key_registry` 与导出 JSON 逐列双向对拍;视图定义全部含 `build_configuration = 'release'`;共享视图列不含 install/device/os;级联删除;迁移重跑幂等;Lean 的 `server.*` 夹具在真触发器上回放。条数与编号以 checks 文件本身为准(不在此抄数字);变异体对照记录见 #273 评论。

### 9.4 键注册表与 0/NULL
`key_registry(key, kind, family, value_schema, since_build, retired_build, liveness_key, spike_id, description)` 由 Swift 导出生成(列以契约 §4 为准;`value_schema` 含 `number_list`)。`counter_long` 视图只覆盖 `kind = counter ∧ value_schema = number`:对每个 `(行, 键)`,`app_build` 在 `[since, retired)` 内 → `coalesce(值, 0)`,否则 NULL;gauge / histogram 由各自视图直接读。已知局限:注册表没有 scenario 维度,键只按 `spike_id` 配对行。问题 2 的「没人用」只在「应出现且全机为 0 且 sessions > 0」时成立;另有 `v_possible_dead_wire` 列出这类键供人核。

### 9.5 视图(具名消费方)
`v_active_installs`(问题 5)· `v_feature_unused_30d`(问题 2)· `v_sync_failure_by_build`(问题 3)· `v_metrickit_by_build`(问题 4)· `v_fixwatch_verdicts_by_install` + `v_fixwatch_pooled_buckets`(问题 1,前者权威、后者样本量;直方图实际在 `daily_rollup` 的 `ResidentCounterSet` 里而不在窗口行,pooled 视图按注册表 `kind = histogram` + `spike_id` 选行)· `v_possible_dead_wire`(诊断)· 第 3 片新增 `v_usage_funnel_30d`(按账号 × 功能:各入口进入、用了、完成、放弃、停留四档、`sessions`)与 `v_usage_suspicious`(§6.3 三条一致性);`v_feature_unused_30d` 对 usage 改按功能前缀聚合,只看 enter / use / done(`abandon` 为 0 是常态,不能读成「没人用」)。全部 `security_invoker`,末尾 `revoke all`。
读者:每周跑 `telemetry_checks.sql` + 五条视图的摘要回帖 #273(PASS/FAIL + 各视图行数);这是「有读者」的最低形式。

### 9.6 保留
先不做定时删。量级 10 台 × ~20 行/天 ≈ 7 万行/年,毫秒级全表扫。`note` 90 天后置 null(唯一含用户文字的列)——**本期未实现**,列在 §14。

## 10. 预算(修正后)

| 项 | 数字 | 来源 |
|---|---|---|
| 热路径 | counter:1 次下标 + 1 次加;histogram:≤4 次比较 + 1 次加;`.gesture` 路径沿用观察站现状 | A·§3、B·F1 |
| 每日记录/设备 | daily ≤4 条 + 窗口 ≤12 + 快照 ≤3 + 手动 run 任意 | §6 |
| 上传 | 典型 ≤10 请求/天(每触发一批)、≤40KB/天;最坏 ≤25 请求、≤160KB | B·F5 修正、C·§1.8 |
| 落盘增量 | ≈20–50KB/天追加,256KB 阈值约 1–2 周压一次;远低于 MetricKit 1GB/天告警线 | B·F6/F7 |
| 冷启动 | 首帧前 0 工作;补传在 +2s off-main;自测 gauge `residentInitMs` p90 < 5ms | B·F11、C·§1.8 |
| 服务端 | ≈7 万行/年、≈100MB/年;B-tree 够 | §9.6 |

## 11. 验收(牙)— 每条带正对照或变异

1. **开关关 = 零请求**:`URLProtocol` 桩拦截一切到 Supabase host 的请求(不是网关 seam,B·F34);正对照:开关开 → 恰 1 个请求。
2. **幂等与时序**:SQL checks(dblink as-user):同 revision 两次 → 1 行且戳不动;先 7 后 5 → 行仍是 7;8 覆盖 7。变异:去掉守卫触发器 → 红。
3. **游标只在 2xx 后前进**:假服务器分别 500 / URLError / 2xx → 前两者游标不动;落盘游标后新建上传器 → 零请求(B·F36)。
4. **Debug→生产被挡**:上传器只问 `uploadsBlockedByBuild`;源扫描遥测文件内无 `#if DEBUG`。
5. **自由文本不外流**:夹具在 `note`、`abortReason`、一个 `.string` metric 各放 UUID 哨兵;opt-out 时所有外发请求体字节不含任一哨兵;opt-in 后只有 `note` 哨兵出现(B·F37)。
6. **同意水位**:开关关经 3 个生命周期循环 → 零请求;开于 t → 首批无 `startedAt < floor(t)` 的记录,且同意那一秒铸出的 daily 必须被选中(小数部分 <0.5 与 ≥0.5 各一例);正对照:关掉水位检查 → 红(C·§1.9-5)。
7. **擦除**:调真实入口 `LocalDataEraser.resetAllLocalData` 后 `.upload-cursor.json` / `.install-id` 不存在,首个请求体带新 installID(B·F39)。
8. **键注册表**:Swift 导出 == 迁移行;死键红;tripwire 无 liveness 红;发未知 id → 一切不动且 `unknownKeyDrops == 1`(B·F40)。
9. **认领键**:同日 build 10→11 → 两条 daily;同日 qa-a→qa-b → 两条且 owner 各异;LA→东京 → dayKey 不变。
10. **判定快照 == 卡片**:手算夹具(dailies/windows 字面量 → 期望快照字面量),SQL 侧插该行解出同一状态(B·F41,避免「测自己算的值」)。
11. **删失**:flush 后 bump 再杀进程 → 下次 `appUncleanExit = 1`,断言 flush 后那段计数确实丢了(C·§1.9-3)。
12. **装机**:两台 TestFlight 机开关开 3 天 → `v_active_installs` 每日 = 2 且 `build_configuration = 'release' and app_build = <TF build>`;第 2 天起 `v_metrickit_by_build` 有行。
13. **返回不重复计进入**(§6.3):打开详情 → 推聊天页 → 返回 → `event_detail.enter.*` 仍为 1,`abandon` 不结算;正对照:再点一次块 → 2。变异:把进入挪到 `onAppear` → 红。
14. **启动落 Tab 不算进入**:默认页设为「我」冷启动 → `tab.me.enter` = 0;点 Tab 栏 → 1。变异:去掉程序写入标记 → 红。
15. **同步来的改动不算使用**:对同步设置键施加一条远端变更 → 对应 `use` = 0;本机拨同一开关 → 1。
16. **访问结算**:进入 → 退后台 10 分钟 → 回前台 5 秒后离开 → 停留落 3–30 秒档且 `abandon` = 1;进入 → 用了 → 离开 → `abandon` = 0;进程在后台被杀 → 停留与放弃都不记。
17. **一致性视图有牙**:SQL 夹具「`use` > 0 且 `enter` = 0」→ `v_usage_suspicious` 出 `missing_enter`;一致夹具 → 0 行。
18. **源扫描**:每个声明了 `enter` 的功能在 `Done/` 非测试源里至少有一个进入点和一个离开结算点;`onAppear` 闭包里出现 `UsageProbe.enter` → 红。

## 12. 切片与顺序

0. 按账号 SQL 数现有云端表(todo_lists / event_logs / event_feedback / agent_conversations / 带图 / 重复 / snapshots):零改动,今天可跑。
1. **服务端**:迁移 016(表、触发器、RLS、`key_registry`、六视图)+ `telemetry_checks.sql`。
2. **客户端骨架**:installID、ownerUID 与认领键、dayKey/tz、revision、游标、单写者上传器、四触发点、`beginBackgroundTask`、同意水位、闸门、Redactor、开关与文案与可见反馈、擦除 QA 断言、测试 1–7。观察站数据先通。
3. **观察系统**:判定快照改在跨天/启动;`usage-daily`(分阶段键、入口来源、访问结算与停留、`UsageProbe`、落点规则,§6.3);`incident-daily`(类型化咽喉 + 轨迹类别计数);`metrickit-daily`(独占文件、payload 的 build/day、补 diskWrite);脏检查;`evictedUnuploaded`;键注册表导出与对拍;测试 8–11。
4. **激活**:TestFlight 卡片 + 测试说明 + 成功判据;装机验收 12。
5. (另开)用户报告。

每片走独立 QA / review 循环;分支直到 release-grade 再合 king。

## 13. 决策点(挂 #273)

1. **`note` 去向**:A 第二开关「附带手动 Spike 备注」;B 永不上传。建议 A。
2. **行键是否保留 `user_id`**:本稿保留(§8.1);C 主张假名化 install-only + forget RPC。建议保留。
3. **TestFlight 一次性激活卡片**:做 / 不做。建议做;不做则问题 1–5 大概率无数据。
4. **关闭开关时**:立即停(本稿)/ 发最后一条带 `optOut=1` 再停(C)。建议立即停。
5. **功能清单**:2026-11-09 用户批分阶段方向(「这样我们数据分析精致一点」),清单见 §6.3.1;起步清单里 4 项(Wanna 打开 / LogSheet 提交 / 反馈提交 / 小组件深链进入)现在够不着,不登记。删减与先做哪几组仍待定。

## 14. 延期 / 不做

- 池搬出 Documents(备份配额):有界 ≤ ~1.3MB,游标文件标 excludedFromBackup 即可;若将来上 App Store 再议。
- `acceptance` 字段进注册表:阈值仍在 Evaluator;等第二个「修复验收」用例出现再抽。
- 同步成功后搭车上传、定时冲、采样:不做。
- 服务端定时删除:量级不需要。
- `PrivacyInfo.xcprivacy`:仓库里没有(`project.pbxproj` 无引用),上架前必须补;遥测新增「Performance Data / Crash Data / Product Interaction / Other Diagnostic Data,linked,not tracking」四项披露;已在用的 required-reason API:UserDefaults(CA92.1)、文件修改时间(C617.1)、systemUptime(35F9.1)。独立待办。
- 015 迁移文件头仍写 `DRAFT — NOT APPLIED`,与现场不一致(A·#38):顺手修(已改)。
- **上架 App Store 前必须做(§16 review P1-2a)**:苹果审核机跑的 App Store 提交包同样返回 StoreKit `.sandbox`,与 TestFlight 是同一个二进制,运行时无法区分 → 会被判成 TestFlight 而默认开、补传历史。需要一个只有 TestFlight 分发才带的构建期标记(如 archive 脚本为 TestFlight 上传写入的 Info.plist 键,App Store 提交用另一次 archive 不写),或上架前把 TF 默认开整体关掉。同时补 `PrivacyInfo.xcprivacy` 与隐私标签。
- 英文文案「1 rows」在状态行已改;「partial」「set aside」两行仍可能出现「1 rows」(待改)。
- `note` 90 天置 null 的定时任务:未实现;等 staging 有真实 note 行再加(pg_cron 或每周手工 SQL 同 checks 一起跑)。
- 擦除本机数据后上传器内存状态(样本、计数)的清空:终审 P1-2,已在合并前修。
- 观察站三条目 `reviewBy` 2026-10-17 已过期(A·#5):等现场判定到了再处置。
- **启动补传的文件读在主线程**(+2s 后,`.utility` 任务里仍回主线程):`SpikeRunStore` / `SpikeRunLog` / `SpikeRun` 在模块默认 MainActor 隔离下无法从 detached task 调;真 off-main 要把这几个类型标 `nonisolated`。第 3 片加 `residentInitMs` / `catchUpReadMs` gauge 先测,超 p90 5ms 再改。
- `key_registry_load.sql` 不在 migrations 里(注册表随构建变,不是一次性迁移):部署流程要多一步,见 `done-mcp/supabase/ops/README.md`。
- 首批 `since_build = 5` 全为占位,第 3 片 Swift 导出时按枚举修正(`slotWritesCalendarCheckpoints` / `dragMemo*` 很可能晚于 build 5)。
- 手动 spike 的 owner 由 store 盖戳后才会上传(第 2 片修正轮);此前写的手动 run 无 owner,永不上传。

## 15. Spike 与观察站:两个板块,一条生命周期(2026-10-26 用户补充)

**两个板块,职责不同**
- **Spike**:每个 spike 是一个待定的 feature(变体开关 `spike.<id>.enabled / .variant`)。它**自带一段观察**:性能、报错等探针只在这个 spike 存活期间跟着它跑,目的只有一个——让用户看完数据后点**留存**或**丢弃**。
- **观察站(ob)**:常驻的几个探针(今天是 `resident-daily` 的 18 个键、修复条目的判定),不随任何 feature 来去,一直在。它回答的是「app 整体现在怎样」,不是「这个 feature 要不要」。

**生命周期(spike)**
1. 立项:注册表加条目(id、变体、要看的键、判据),探针与变体开关一起进代码。
2. 测量:TestFlight 上跑;spike 的 `manual_run` / 变体标记随遥测上传;用户在 Spike 板块看按 **spike × 变体** 汇总的性能与报错。
3. 决定:用户点「留存」或「丢弃」。这个点击本身要落成一条记录(`kind = spike_decision`:spike_id、variant、verdict、时刻),随遥测上传,这样决定能到仓库这边被执行,而不是留在一台手机里。
4. 执行(代码变更,不是运行时按钮):
   - **留存** → 被选变体直接成为默认行为(删开关、删分支),spike 的探针与变体开关一并移除,注册表条目填 `retired_build`(退役不删条目,沿用 R-F11);
   - **丢弃** → feature 与探针一起删,条目同样填 `retired_build`。
   两种结局都不会把 spike 的探针并进观察站:要常驻观察一个东西,得单独在 ob 立项。
5. 守卫:源扫描保证已退役 spike 在 `Done/` 里没有存活的 emit 站点和开关读取(否则是死线,服务端会把 0 读成「没人用」);已退役键在视图里对 `app_build ≥ retired_build` 读 NULL。

**底盘已经有的**:记录类型分开(spike 的 `manual_run` 带 `variantID`;ob 的 `daily_rollup` / `verdict_snapshot`);注册表 `retired_build`;修复条目的 `FixObservationLifecycle.active / retired`。
**缺的(归第 3/4 片)**:`v_spike_variant_summary`(spike_id × variant → 性能与报错计数,只看 release 行);`spike_decision` 记录类型(契约 §2 的 `kind` 加值,服务端 check 同步);退役 spike 的源扫描测试;Spike 板块里的「留存 / 丢弃」按钮与按变体汇总的展示。

**两处待拍**(建议附后)
- 「留存」点击落在哪里:**在 app 的 Spike 板块**(建议,和「我来点击」一致),决定作为记录上传;GitHub 票只做执行记录。
- 「直接部署」的含义:**下一个构建里删开关、把被选变体写死**(建议;本 app 没有远程开关,也不该为此加一个);不是远程翻 flag。

## 16. 观察站就是数据收集(2026-10-27 用户拍板,改 §8 的部分决定)

用户原话:「观察站本质就是数据收集的一部分」;选 1+2+3;「肯定还是分用户的,但是数据收集和分析可以聚合分析」。

**规则**
1. **一个入口**:开关、上传状态(上次上传 / 条数 / 累计)、「立即上传」、「查看样本」从「数据与隐私」挪到**观察站页面顶部**;「数据与隐私」只留一句说明和指向观察站的链接。
2. **默认上传(仅 TestFlight 包)**:TestFlight 包首次运行这一版时默认开,**补传本机保留的全部历史**(用户 2026-10-27:「可以补传吧,至少目前对我来说更方便」;TF 下同意水位取 `.distantPast`)。补传只覆盖带账号的记录(build 13 起写的);遥测上线前写的旧记录(无 `revision` / `ownerUID`)**不认领、不上传**——用户 2026-10-27:「我的观察站的数据我之后单独处理」;签出期写的记录仍不传。一次触发循环发批直到清空(每批 ≤32)。用户仍可在观察站页面关掉,关掉即停。App Store 包保持默认关,上架前补 `PrivacyInfo.xcprivacy` 与隐私标签后再定。备注开关(note)不随之默认开。**这改掉 #197(2026-08-26)「默认关」的拍板,仅对 TestFlight。**
3. **观察站读云端、按用户**:观察站卡片的判定与计数改读服务端里**本账号**所有设备的行(RLS 本来就允许 select 自己的行),本机数据作为离线回退与「尚未上传」的补足;「Release 天数」等变成本账号全部设备合计,卡片注明来源(云端 · N 台设备 / 仅本机)。
4. **数据按用户存,分析可聚合**:行仍以 `user_id` 为键;跨用户聚合只在开发者侧的 SQL 视图里做,不进 app,也不对 authenticated 开放。

**服务端**:新迁移给 authenticated 一组 `security_invoker` 的「我的」视图(只能看到自己的行),供观察站读;既有共享视图保持 revoke。
**TestFlight 判定**(顺序即优先级,结果按进程缓存,每次启动在轨迹记 `environment.source=…` 与 `environment=…`):① 带 `embedded.mobileprovision` → 开发包;② 模拟器 → 开发包;③ `appStoreReceiptURL` 末段为 `sandboxReceipt` → TestFlight,为 `receipt` → App Store(名字由系统按安装来源给出,与收据文件是否存在无关——**不要加「文件存在」检查**,TestFlight 安装本来就没有收据文件);④ 以上都不成立才问 StoreKit 2 `AppTransaction`(build 20 真机上它抛 `StoreKitError`,只能作兜底);失败按「未知」处理,未知不默认开。App Review 的提交包同样是 `sandboxReceipt`,见 §14 与发布清单的上架前检查项。
**测试**:默认开只在 TestFlight 判定为真时生效;首启写入的同意起点之前的记录不传;观察站在离线 / 未登录 / 云端为空时回退本机且标注来源;「我的」视图对另一个用户返回空(SQL checks)。

## 附录:参考文件

- `round1/v0-blueprint.md` — 对抗前的蓝图
- `round1/A-facts.md` — 事实核查(38 条核对表,有出入项 11 条)
- `round1/B-attack.md` — 攻击报告(F1–F41,P0 两条)
- `round1/C-alternative.md` — 独立设计、调研(带 URL)、比较矩阵
- 相关:#197(拍板)· #219(观察站落地判据、62.7M 规则)· #235(TestFlight 容器拉不出)· #266(擦除注册表)· #273(实施票)

## 附录 B:实施期裁决记录(2026-10-24)

形式化者挑出的 7 处歧义:① 旧行 revision 缺省为 0、永不 pending(接受);② 边沿上所有 daily 统一 15 分钟门,不分今日(接受);③ 15 分钟是 `>=`(接受);④ metricKitDaily 永不随边沿(接受);⑤ consentFilter 的 currentOwner 为 nil → 空,不许裸 `==`(接受);⑥ 认领键 nil owner 同主(接受);⑦ 过滤保序、选批有序(接受)。
服务端实现者报的 8 条:T2 同 revision 戳不动(契约为准);RLS 含 select(契约为准);直方图在 daily 行(接受按注册表选行);值类型加 `number_list`(契约 v1.1);counter_long 只覆盖 counter∧number(接受);无 scenario 维度(接受为局限);key_registry 列以契约为准;触发器家族检查更严(接受)。
客户端实现者报的 6 条:手动 run 无 owner(**必修**:store 统一盖戳);abortReason 五个字面量(接受关联值做法);进程内 owner 变化关旧铸新(接受);旧行 dayKey 回退(接受);hintClearData 无显示位(取消要求);边沿 daily 不分今日(接受)。
基线:fd92618 · iPhone 17 Pro · 2840 / 0 / 2。模拟器 iPhone 17(19C67606)状态坏(钥匙串 -34018、无 App Group 容器),同构建 45 红,不用。

## 附录 C:第 1+2 片实施记录(2026-10-25)

**落地**:服务端 016 + `key_registry` + `telemetry_checks.sql` + QA 的 `telemetry_wire_conformance.sql`;客户端纯模型 / 信封 / revision 游标 + 隔离集 / 单写者上传器 / 四触发 + keep-alive / 同意水位 + 首日重铸 / OwnerStamp / 设置卡与文案 / 擦除接线;Lean 66 定理 + 58 夹具回放 58/58;deploy 工作流加载注册表一步。
**对抗**:review round 1(P0 ×1、P1 ×3、P2 ×15、问题 ×7)全部裁决,P0/P1 与 10 条 P2 已修;QA 20 个变异体 18 直接 KILLED、1 补测试后 KILLED(X-Sync-Epoch)、1 等价(tie-break,stdlib 排序实测稳定);契约夹具 6 行由生产路径生成逐字节对拍并灌进本地真表。
**端到端**:真 app(Debug)在擦净的模拟器上,`SYNC_ENV=local` + 注入会话,退后台边沿 `upload.ok rows=1`,本地 `spike_runs` 落 1 行 daily_rollup(build 11 / debug / revision 1)。这是 review 问题 Q1 的答案,也是 P0-1 在真进程里成立的证据。
**定性为环境、非回归**:全量在 iPhone 17 Pro 上的 4 个 `SyncApplierTests` / `SyncCatchUpTests` 红——模拟器测试宿主的 UserDefaults 残留 `tokenInferenceProjections.v2`,干净机 170/0;隔离实验证明遥测测试不是泄漏源(宿主 app 的 TokenInference 协调器绑着真实 EventStore 的日志/反馈变更,既有套件里某个测试触发)。全量以后在专用机上先 erase 再跑。
**staging(2026-10-26)**:016 + 注册表经 `supabase-staging.yml`(workflow_dispatch on king ff93997,run 40255421366)应用到 done-staging;Debug 模拟器以 qa-a 会话真传一行 daily_rollup(build 11 / debug / 18 键),视图按契约忽略 debug 行(全部 0 行)。release 标记的行要等真机 release 包:`SYNC_DEBUG_SESSION` 只在 DEBUG 下可用,模拟器上无法以 release 配置登录。MCP `apply_migration` 在终端里弹不出确认框,DDL 一律走工作流。

**留给第 3 片 / 清单**:注册表 Swift 导出(QA #9、契约 §4);Redactor 的 metric 键白名单来自注册表(review P2-7);Lean 回放覆盖 `inferred` 路径(QA #8);假服务器 vs SQL 用同一份 Lean `server.*` 夹具机器对拍(服务端 T27);启动补传读文件仍在主线程(`residentInitMs` / `catchUpReadMs` 量测后再定);每 daily 两次 `stamp()` 与窗口首次 append 全量解码(P2-10);合并到 main 即自动把 016 应用到生产(P2-15,流程事实,合并顺序 = 部署顺序);既有套件的 token 投影泄漏(找出写入方并隔离到独立 suite)。

## 附录 D:`usage-daily` 第一片实施记录(2026-11-09,分支 feat/usage-daily-g1)

范围:§6.3 的底盘 + §6.3.1 里的 focus / event_detail / create / repeat / all_day 五组。服务端视图(`v_usage_funnel_30d` / `v_usage_suspicious`)另做。下面是后来的读者需要知道、但规范没写死的决定。

**登记与键名**
- 唯一登记处是 `UsageFeature.declaration`(`Done/Models/UsageModel.swift`):每个功能列出入口(带 `user` / `auto`)、用了、完成、子页、离开路线、独立计数;`UsageKey` 与 O(1) 槽位表由它推出,一次建好。注册表 JSON 的 usage 行由测试 `UsageRegistryTests` 与 Swift 逐列双向对拍(不一致时测试把应有的行打印出来),`since_build` 全部为 29(本片随下一个构建出;实际构建号不同就改 `UsageFeature.firstUsageBuild` 一处)。
- 分区与属性:`enter.<入口>`、`use.<组>`、`exit.<路线>`、`abandon.<路线>` 都是**分区**(一次信号只加其中一个),阶段合计 = 子键之和,此时没有裸键;`done.<属性>`(`create.done.repeat` / `all_day` / `note`)是**属性**(保存时带了这一项,每个 ≤ 裸 `done`),不能按前缀求和。服务端视图读 `done` 用裸键。
- 离开路线两种记法:focus 记 `exit.<路线>`(每次结算都记,用没用过都记)+ 裸 `abandon`;create 只在放弃时记 `abandon.<路线>`(cancel / swipe),没有裸 `abandon`,避免前缀求和重复。
- `create.abandon.banner` 不是一次访问的结算:它数的是「横幅上丢弃已保存的草稿」,发生在那次访问(以 swipe 结算)之后,或在进程死掉、访问从未结算之后。`abandon ≤ enter` 的一致性检查只能用 `abandon.cancel + abandon.swipe`。
- `repeat.use.form` 发生在新建 / 编辑表单里,不在任何 rule_editor 访问内;`v_usage_suspicious` 的 `missing_enter` 对 repeat 要排除这个键,否则「只在表单里选了重复」的日子会被误标。
- 预建选择器(confirm-before-tracking 打开时点类型)单独成一个功能 `focus_precreate`:入口 `pill`,Begin 为 `done`,Cancel(或预建还开着时离开 focus)为 `abandon`。这样「预建放弃」不会和「focus 一次访问没动手」混在同一个 `focus.abandon` 里。focus 本身没有 `done`。

**`sessions`(分母)的确切定义**:一条记录的 `sessions` = 该记录存续期间开始的前台会话数 + 记录铸出时已经在前台运行、且本进程已计过数的那个会话(1 或 0;测试宿主那种本进程没计过的前台不带入)。前台会话开始 = 冷启动时进程已在前台(激活中心那一刻 `applicationState != .background`),或 `didEnterBackground` 之后第一次 `willEnterForeground` / `didBecomeActive`(两个通知只算一次)。没有 `didEnterBackground` 在前的 `didBecomeActive`(控制中心、Face ID、系统弹窗)不算。「铸出时已在前台」覆盖午夜跨天、进程内换账号、同意重铸、擦除:那天 / 那个账号仍有分母,代价是跨午夜的一个会话两天各记一次。回到前台的那一下先做跨天检查,午夜后回来的会话记在新的一天。

**访问与停留**
- 每个有入口的功能同一时刻最多一个打开的访问,只在内存里(进入时的媒体时钟、累计前台秒数、是否动过手)。离开时结算:停留档 + 没动过手则放弃(或放弃路线)+ focus 的离开路线。
- 停留只算前台:`didEnterBackground` 停表,回前台续表;`willResignActive` 不停(控制中心下拉时界面还在)。档位上界不含:<3 s、<30 s、<300 s、≥300 s。访问在离开那天结算(进入记在进入那天)。
- 进程在后台被杀:访问从未结算,不记停留也不记放弃;它的 `enter` 早已随退后台的 flush 落盘。
- 离开时没有打开的访问:什么都不记(路线也不记)。同一功能再次 `enter` 时旧访问还开着:旧访问**丢弃不结算**(与被杀同形),所以漏了离开点只会让停留 / 放弃偏少,不会凭空造出放弃。
- focus 的离开路线:surface 在调 `onExit` 之前 `noteExit(.focusSwipe / .focusSystem)`,离开时以此为准;没有提示时,设置仍开着 = 转回竖屏(`rotate`),设置已关 = `system`(本机开关或同步写入)。

**记录**:`usage-daily` 是常驻中心写的第二条 daily(`kind = daily_rollup`,`scenario = daily-rollup`),与 `resident-daily` 共用认领键、日界、dayKey、flush 边沿、同日采纳、换账号 / 同意 / 跨天重铸与擦除;id 独立。值为 0 的键不写;一天没有任何使用就不写 usage 行。启动采纳时本构建不认识的键(或形状不对的值)丢弃并计数(`usageUnknownKeyDrops`,并打一行轨迹),该行在下一次 flush 时不带它重写。Redactor 对 `spike_id = usage-daily` 的行再按 `UsageKey` 过一遍:未登记的键删除,计数必须是非负整数,停留必须正好四个非负整数。

**成本**:信号路径 = 一次静态 weak 读 + 一次 `Date()` + 一次 Double 比较(日界)+ 数组下标加一;进入 / 离开另读一次媒体时钟;结算 ≤3 次比较 + ≤3 次加。脏检查比的是一个变更计数,不持有计数数组的副本(持有副本会让 flush 后的第一次加触发写时复制)。新增的落盘只有 usage 行本身,随原有 flush 追加;同一文件的压实规则与其他 spike 文件相同。

**§6.3.1 落点的更正 / 细化**(以源扫描为准)
- `create.done` 及属性、`abandon.cancel / swipe` 记在 `CreateCalendarEventView`(SH)的保存闭包与 `onDraftSessionEnd` 里,不在 FV 的按钮里:FV 同时是编辑表单,在 FV 里记会把编辑的保存也算成新建。
- event_detail 的离开:三个呈现者(PV、`CalendarSearchView`、`CalendarListView`)各自在路由绑定变成 nil 时记;DV 自己的 `onAppear` / `onDisappear` 一律不记。
- search 入口记在 `openEvent` / `openOccurrenceLog` 两个汇合函数里(四个按钮都走它们);canvas 入口记在 `handleTimelineEventTap`(时间线块与全天条都走它)。
- focus 的 `track` 记在 FM 的 `handleClockTrackingTap`(时钟视图只是转发);`extend` / `end_now` 记在 DoneApp 构造 FocusModeView 的闭包里;`note` 只在发送按钮与键盘发送处记(`commitNote(byUser:)`)。
- 反思页备注 / 模板:不改 `detailNoteSection` 与备注加载 / 保存代码(另一分支在改),改为在 DV 的修饰链上观察 `(已加载, 备注, 模板, 答案数)`,只有加载前后都为「已加载」的变化才算用户编辑,每个详情页只记一次(不按每个字)。todo 事件上同样的编辑记为 `use.todo`。
- todo 组:`toggleTodoDone`、`releaseAbsorption`、`putBackToStack`、`updateDeadline`(开关与滚轮提交都走它)。`timeline_note`:保存、删除、长按开始编辑。
- 重复规则编辑器:进入记在 DV 的「管理重复」按钮(同时记 `event_detail.use.plan`),离开记在该 sheet 的 `onDismiss`(Save / Cancel / 删除整个系列 / 下滑都经过它);删除整个系列另记 `repeat.use.delete_series`,不算放弃。
- `reminder_ai` 的访问从点按开始(表单在 AI 返回后才弹出),所以它的停留含等待 AI 的时间;`create.ai_fallback` 在 AI 关和 AI 失败两种回退里都记。

**已知局限**
- 详情页还在导航栈里时切到别的 Tab,访问不结束,停留含在别的 Tab 的时间;推到聊天页的时间同样算在详情页里(聊天被视为详情的一部分)。
- 带着详情页一起被弹出的搜索页(从搜索结果跳日历)不会把详情页的路由写回 nil,该访问不结算,下次进入时丢弃。
- 预建选择器打开时若恰好有事件开始(界面切到当前事件),预建访问保持打开,直到 Begin / Cancel 或离开 focus。
- 测试宿主下中心不数冷启动会话(`countsLaunchSession` 默认在 XCTest 下为 false,与 `installsFollowerProbe` 同一理由);测试显式传入。
