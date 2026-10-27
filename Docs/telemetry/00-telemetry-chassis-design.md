# 遥测底盘设计(Telemetry Chassis)— v1 裁决稿

日期:2026-10-24。分支 king-of-rubbish-bin @ fd92618。实施票:#273。拍板来源:#197(2026-08-26)。
过程:蓝图 v0 → 三方对抗(事实核查 A / 攻击 B / 独立设计 C,见 `round1/`)→ 本稿裁决。
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
| L0 信号 | 热路径上 O(1) 固定键 bump;禁 UserDefaults / Calendar / 落盘 / 网络 / publish / 字符串分配 | `ResidentTierOneCore`、`SpikeProbe.emit` | `UsageKey` / `IncidentKey` 枚举下标计数;`UsageProbe.used(_:)` 只许从 action 闭包、`onAppear`、`onChange` 调 |
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
- usage 键的 emit 只许在 action 闭包 / `onAppear` / `onChange`,不许在 `body`(B·F2:body pass 数的是重渲染);服务端 sanity 视图:某键日计数 > 当日 `detailBodyPasses` 即标 suspicious。
- 多个观察系统共用一个 resident、一个 switch(B·F3),不各自注册。

## 6. 首批观察系统

### 6.1 观察站(已存在)
`resident-daily` 每日汇总与 `auto-window`(≤12/天)原样上传;窗口记录是问题 1 的判定权威,与设备卡片逐项对拍。合并直方图(全体设备按桶相加)作为第二读法,只回答「样本量够不够」,不作判定。

### 6.2 判定快照 `verdictSnapshot`(修正 B·F28)
评估器是纯函数(`FixWatchView.swift:213-222` 两次 `loadRuns` + 算术)。改为在跨天 flush 之后和启动补传之前各算一次(off-main),打开观察站只是额外一次。每个修复条目两个键:`state`(4 态枚举数值)+ `alarm`(bool)。

### 6.3 功能使用 `usage-daily`
`enum UsageKey: UInt16, CaseIterable`,起步 ≈ 23 项(清单在 #273,待删);每天每键一个整数;同记录带 `sessions`(didBecomeActive 次数)作分母。入口 `UsageProbe.used(.x)`。

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
`v_active_installs`(问题 5)· `v_feature_unused_30d`(问题 2)· `v_sync_failure_by_build`(问题 3)· `v_metrickit_by_build`(问题 4)· `v_fixwatch_verdicts_by_install` + `v_fixwatch_pooled_buckets`(问题 1,前者权威、后者样本量;直方图实际在 `daily_rollup` 的 `ResidentCounterSet` 里而不在窗口行,pooled 视图按注册表 `kind = histogram` + `spike_id` 选行)· `v_possible_dead_wire`(诊断)。全部 `security_invoker`,末尾 `revoke all`。
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

## 12. 切片与顺序

0. 按账号 SQL 数现有云端表(todo_lists / event_logs / event_feedback / agent_conversations / 带图 / 重复 / snapshots):零改动,今天可跑。
1. **服务端**:迁移 016(表、触发器、RLS、`key_registry`、六视图)+ `telemetry_checks.sql`。
2. **客户端骨架**:installID、ownerUID 与认领键、dayKey/tz、revision、游标、单写者上传器、四触发点、`beginBackgroundTask`、同意水位、闸门、Redactor、开关与文案与可见反馈、擦除 QA 断言、测试 1–7。观察站数据先通。
3. **观察系统**:判定快照改在跨天/启动;`usage-daily`(枚举键、`UsageProbe`、emit 落点规则);`incident-daily`(类型化咽喉 + 轨迹类别计数);`metrickit-daily`(独占文件、payload 的 build/day、补 diskWrite);脏检查;`evictedUnuploaded`;键注册表导出与对拍;测试 8–11。
4. **激活**:TestFlight 卡片 + 测试说明 + 成功判据;装机验收 12。
5. (另开)用户报告。

每片走独立 QA / review 循环;分支直到 release-grade 再合 king。

## 13. 决策点(挂 #273)

1. **`note` 去向**:A 第二开关「附带手动 Spike 备注」;B 永不上传。建议 A。
2. **行键是否保留 `user_id`**:本稿保留(§8.1);C 主张假名化 install-only + forget RPC。建议保留。
3. **TestFlight 一次性激活卡片**:做 / 不做。建议做;不做则问题 1–5 大概率无数据。
4. **关闭开关时**:立即停(本稿)/ 发最后一条带 `optOut=1` 再停(C)。建议立即停。
5. **功能 ID 起步清单**:#273 的 23 项待删。

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
**TestFlight 判定**:StoreKit 2 `AppTransaction.environment == .sandbox`(或回退 sandbox receipt),结果缓存;判定失败按「非 TestFlight」处理(默认关)。
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
