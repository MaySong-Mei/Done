# A-facts — 遥测底盘蓝图事实核查

核查对象:`/private/tmp/claude-501/-Users-maymay-code-ios-app-Done/94cbbbf7-32e8-4880-bc26-99004653f94b/scratchpad/chassis/v0-blueprint.md`
仓库:`/Users/maymay/code/ios app/Done`,分支 king-of-rubbish-bin @ fd92618(未动 git 状态)。下文路径相对仓库根。
核查环境限制:本机磁盘满(ENOSPC),Bash/grep/glob 全不可用,LSP 未索引;**所有事实来自逐文件 Read**。凡需要全库 grep 才能证实的计数(DiagnosticTrail 86 处、identifierForVendor、BGTaskScheduler 零使用)一律标「未能核实」,不猜。

---

## 1. `SpikeRun` 字段 / Codable / `collapse` / `coActiveSpikeIDs`

结论:`SpikeRun` 共 19 个存储字段,合成 Codable;`metrics` 是 `[String: SpikeMetricValue]`(number/string/bool),不是 `[String: Double]`;`buildConfiguration: String?` 蓝图漏列;`coActiveSpikeIDs` 存在;`collapse` = 同 id 最后一条胜、首现顺序保留。

- `Done/Models/SpikeModel.swift:232-280`
```
232 struct SpikeRun: Codable, Identifiable, Equatable {
233-238   let id: UUID / let spikeID: String / let scenarioID: String / var variantID: String? / let startedAt: Date / var endedAt: Date?
239-252   let appVersion, appBuild: String / let appCommit: String? / let deviceModel, osVersion, timeZoneIdentifier, localeIdentifier: String
262   var buildConfiguration: String? = nil        // "debug"/"release",可选(旧行兼容)
273   var coActiveSpikeIDs: [String]? = nil
274-277   var metrics: [String: SpikeMetricValue] / var note: String? / var outcome: SpikeRunOutcome? / var abortReason: String?
```
- `SpikeMetricValue` 自定义 Codable,单值容器:`SpikeModel.swift:199-225`(bool→number→string 顺序解码)。`SpikeRunOutcome` = completed/aborted/interrupted(179-183)。
- 日期编码:由 store 设 `.iso8601`(`Done/Services/SpikeRunStore.swift:182, 203`),模型本身无自定义。
- `SpikeRunLog.collapse` `SpikeModel.swift:295-305`:
```
296 var latest: [UUID: SpikeRun] = [:]; 297 var order: [UUID] = []
298-303 for record in records { if latest[record.id] == nil { order.append(record.id) }; latest[record.id] = record }
304 return order.compactMap { latest[$0] }
```
- `appCommit` 永远 nil:`SpikeRunStore.swift:329-332` 读 Info.plist 不存在的 `DoneGitCommitSHA`。

## 2. `SpikeRunStore`

结论:目录 `Documents/spike-runs/`(XCTest 下 `spike-runs-test-host`),文件 `<spikeID>.jsonl`;上限 200 run/spike(读时裁)+ 256KB 字节阈值(唯一的重写触发),压实目标 128KB;压实只在 `finishRun`/`setNote` 后按 stat 字节数触发;写在调用线程同步执行(生产调用方是 @MainActor 的 Center → 主线程);**无 fsync**。

- 目录/文件:`Done/Services/SpikeRunStore.swift:52-62`、`90-92`。
- 常量:
```
73  static let maxRunsPerSpike = 200
79  static let compactAtBytes = 256 * 1024
88  static let compactTargetBytes = compactAtBytes / 2
```
- 触发点:`finishRun` 115-120(append 后 `compactIfNeeded`)、`setNote` 126-137;`beginRun` 109-112 不压实。`compactIfNeeded` 237-244:`attributesOfItem[.size] >= compactAtBytes` 才 `loadRuns`→`applyRetention(200)`→`trimToByteBudget`→`rewrite`。计数上限只在读侧 `loadRuns` 191 和压实内 242 生效(229-236 注释明说文件可暂时超 200 行)。
- 写入:`appendLine` 200-227 — `FileHandle(forWritingTo:)` + `seekToEnd` + `write(contentsOf:)`,无 `synchronize()`;`rewrite` 273-290 — `Data.write(.atomic)` + `replaceItemAt`。
- 线程:全部 `static func` 同步,无队列;`ResidentObservationCenter` 为 `@MainActor`(`Done/Services/ResidentObservationCenter.swift:45`)→ 日汇总/窗口落盘在主线程。
- `wipe()` 104-106(删整个目录,供擦除用)。

## 3. `ResidentObservationCenter` flush 边沿 / 常量 / 跨天 / 每信号成本

结论:flush 挂在 (a) willResignActive + didEnterBackground + willTerminate(一轮只刷一次)、(b) 打开观察站、(c) 跨天 主队列 hop;**没有「启动」flush**(init 只读今日记录并接管 run id)。手动 #201 run 武装会关窗口但不刷日汇总。

- (a) `Done/Services/ResidentObservationCenter.swift:192-201` 订阅三通知 → `handleLifecycleEdge` 356-363;S8 令牌 `lifecycleEdgeFlushed`(89)在 didBecomeActive 清零(204-210):
```
359 guard !lifecycleEdgeFlushed else { return }
360 lifecycleEdgeFlushed = true
361 closeWindow(outcome: .completed, closedByResign: true)
362 flushDaily()
```
- (b) `flushDaily()` 367-370 ← `FixWatchAttention.loadVerdicts()` `Done/Views/Agent/FixWatchView.swift:214` `ResidentObservationCenter.shared?.flushDaily()` ← `refresh()` 181-186 ← `.onAppear(perform: refresh)` 77。
- (c) 跨天:信号路径 246-248 一次 Double 比较 → `scheduleRolloverFlush` 372-378:
```
373 guard !rolloverFlushScheduled else { return }
374 rolloverFlushScheduled = true
375 DispatchQueue.main.async { [weak self] in self?.performRolloverFlushIfDue() }
```
  `performRolloverFlushIfDue` 382-401:关窗口、以 `dayBounds.dayEnd` 写昨日记录、`core.resetForNewDay()`、重算 bounds/新 run id。
- 常量:`Done/Models/ResidentObservationModel.swift:615-618` `residentDailySpikeID = "resident-daily"`、`residentDailyScenarioID = "daily-rollup"`、`windowScenarioID = "auto-window"`、`effortPathFixID = "fix-effort-path"`(窗口记录的 spikeID,Center:327-328)。
- 每信号路径(Center 239-253):
```
246 if now().timeIntervalSinceReferenceDate >= dayEndSinceReference { scheduleRolloverFlush() }
249 let completion = core.ingest(signal: signal, mediaNow: mediaNow())
```
  `core.ingest` `ResidentObservationModel.swift:324-386`:`.counter/.invariant` 为 2-3 次字符串 `==`(329-340);`.bodyPass/.textLength` 直接 return(342-347);`.gesture` 为 lag 算术 + 环追加 + 直方图 bump(348-384)。注意:`.gesture` 不是 O(1) 常数小——含 `gestureLog.ingest` 与 `trimRecords(toLast: 32)`。
- 日汇总写入 `writeDailyRecord` 403-426:每次 `SpikeRunContext.stamp()`(含 `uname`、Locale、TimeZone)+ 一次 `finishRun`。

## 4. `ResidentCounterSet` 固定键 / 未知键 / tripwire 发射点

结论:键 = 结构体命名字段(18 个 metric 键);`init(metrics:)` 只读命名键 → 未知键静默丢弃;未知信号 id 在 `ingest` 里不 bump 任何东西。tripwire 只有 **一个**(`meComputedHidden`),另一个是 liveness 计数(`meComputedVisible`),二者由同一函数 `MeAggregateWitness.note(visible:)` 发射。

- 字段:`ResidentObservationModel.swift:156-204`;`metrics` 字典 212-233;`init(metrics:)` 240-269(`number(_:)` 只取 `.number`,直方图取 `.string` 反序列化,其余键无路径)。
- 未知 id 惰性:`ingest` 326-341(`if id == … else if …`,无 default 累加)。
- `FixWatchSignalID` 42-65:`meComputedHidden = "me.aggregates.computedHidden"`(59)、`meComputedVisible = "me.aggregates.computedVisible"`(64)。
- 发射点 `Done/Views/Analysis/AnalysisView.swift:460-468`:
```
461 static func note(visible: Bool) {
462     if visible { 463 SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible)) }
464     else      { 465 SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden)) }
```
  调用方:`AnalysisAggregates.chart` 138、`ProfileHubAggregates.compute` 596;602 把 `visible` 再传给 `AchievementCatalog.compute`(定义文件未读)。

## 5. `FixObservationRegistry.all` / `FixWatchVerdictEvaluator`

结论:三条目的 id/issue 如下;**条目没有「判定标准」字段**——阈值硬编码在 Evaluator(55ms/20 样本/10 样本、p50≤40/p95≤120),`summary` 只是散文。Evaluator 输入 = `resident-daily` 与 `fix-effort-path` 两类 run;输出 `FixVerdict{state, alarm, …}`,「回归警报」是 `alarm: Bool`,不是枚举值。三条目 `reviewBy` 均为 2026-10-17(今日已 OVERDUE)。

- 条目结构 `ResidentObservationModel.swift:598-612`:`id, issueNumbers, mergedSHAs, title, summary, hasWindows, lifecycle, addedOn, reviewBy`。
- `all` 622-656:`fix-effort-path` [201, 213] SHAs f645913,c181611 hasWindows=true;`fix-me-tab-gate` [214] 3362e4f,3f1398e;`fix-touch-delivery` [201] f645913。
- 阈值 702-705:`commitP50ThresholdMs = 55`、`commitMinSamples = 20`、`lagMinSamples = 10`;p50≤40ms/p95≤120ms 写在 `shareReadout` 调用处 814-819、920-921。
- 输入:`evaluateEffortPath(dailies:windows:)` 773、`evaluateMeTabGate(dailies:)` 866、`evaluateTouchDelivery(dailies:)` 916;实际喂入 `FixWatchView.swift:215-216`(`loadRuns("resident-daily")`、`loadRuns("fix-effort-path")`)。只用 `buildConfiguration == "release"` 记录(707-709)。
- 输出 684-696 / 状态 665-674:
```
666 case observing     // 观察中
668 case insufficient  // 数据不足
670 case holding       // 达标
672 case failing       // 未达标
689 let alarm: Bool    // 回归警报(evaluateMeTabGate 876: hidden > 0 → alarm, state=.failing)
```
  中文标签映射在 `FixWatchView.swift:141-144`,警报徽章 42-47、90。

## 6. 擦除注册机制(#266)

结论:**#266 的 `ErasableLocalStore` 注册表尚未实现**;现行机制 = `LocalDataEraser.resetAllLocalData` 手工清单 + `EraseWiringScan` 读源码(去注释)断言字符串存在 + `EraseDiskWitnessQATests` 见证每个 purge 做了它说的事。登记一个新落盘文件 = 四步(见下)。

- 注册表缺席的证据:`Done/Views/Agent/AgentSettingsView.swift:1231-1245`
```
1231 // ⚠️ THAT IS STILL TRUE. Nothing here makes the next one fail on arrival. …
1240 // The fix is a registry — an `ErasableLocalStore` the store conforms to AT ITS POINT OF DEFINITION … gh#266.
1243 // Until then this block is maintained by hand and by review, and `EraseDiskWitnessQATests` only witnesses that the calls below do what they say — not that the list is complete.
```
- 擦除主体 `AgentSettingsView.swift:1003-1274`(`struct LocalDataEraser`):`LocalDataEraseEpoch.bump()` 1020(第一句);`syncUploadsEnabled=false` 1031;`store.clearAllLocalData()` 1033;`removeResettableKeys` 1056;…;`SpikeRunStore.wipe()` 1268;`MetricPayloadStore.standard().wipe()` 1273。
- 在途写入门:`Done/Services/LocalDataEraseEpoch.swift:97-127`(`capture()/bump()/isStale()`,进程内、不持久化 49-52)。
- 测试覆盖:`DoneTests/EraseWiringScan.swift:66-84` `functionBody(of:inFileAt:)` 取函数体并去注释;`assertCalls` 135-147。`DoneTests/EraseWiringQATests.swift:44-101` `testEveryPurgeIsStillWiredIntoTheErase`,`required` 元组表 51-89:
```
72  ("SpikeRunStore.wipe()", "spike run records including user-entered notes (gh#263)"),
81  ("MetricPayloadStore.standard().wipe()", "MetricKit payloads in Diagnostics/ and the legacy Documents/Diagnostics pile"),
```
- 新文件最小登记步骤(按现行机制):① 新 store 提供 `wipe()`(处理 XCTest 重定向目录,参照 `SpikeRunStorageLocation` 52-62);② 在 `resetAllLocalData` 内加一行调用(1014-1274 之间);③ 在 `EraseWiringQATests.swift:51-89` 加一条 `(call, consequence)`;④(可选)`EraseDiskWitnessQATests` 加见证;⑤ 任何「await 后写」的路径在第一个 `await` 前 `LocalDataEraseEpoch.capture()`。

## 7. 同步上传路径 / JWT / Debug→生产闸门 / `syncUploadsEnabled` / `SyncOfflineSwitch`

结论:`SupabaseREST` 定义在 `Done/Services/SupabaseSyncService.swift:73`(不是独立文件);每请求带 `apikey`(publishable key)+ `Authorization: Bearer <用户 JWT>`,401 强刷一次重试。**Debug 禁传生产的闸门不在 `SupabaseREST.send` 里**,而在 `SupabaseSyncService.uploadsBlockedByBuild`,只在 `attach` 跳接上传 sink 与 `canUpload` 中生效——直接持有 `SyncGateway` 的新上传器不会被它挡住。

- `SupabaseSyncService.swift:73 final class SupabaseREST: SyncGateway`;协议 `Done/Services/Sync/SyncGateway.swift:89-157`(verbs:pullChanges/fetchSyncEpoch/isAncestor/patchConditional/insertIgnoringDuplicates/tombstone/upsertMerging/deletePhysically/fetchAll)。
- JWT:`send()` 338-382
```
358 request.setValue(self.projectAPIKey, forHTTPHeaderField: "apikey")
359 request.setValue(self.authorizationHeader(token), forHTTPHeaderField: "Authorization")   // "Bearer \(token)" (132)
361 if let epochHeader { request.setValue(epochHeader, forHTTPHeaderField: Self.epochHeaderField) }   // X-Sync-Epoch,仅写
370 let (data, response) = try await URLSession.shared.data(for: request)
374 if http.statusCode == 401 { throw SyncError.tokenExpired }
```
  token 来源 `userToken()` 104-110(`authService.refreshTokenIfNeeded()` → `accessToken`,空则 `notSignedIn`);重试 `withTokenRetry` 115-130。
- Debug→生产闸门 `SupabaseSyncService.swift:941-969`:
```
941 #if DEBUG
942 static let debugBlocksUploads = true
956 nonisolated var uploadsBlockedByBuild: Bool { Self.debugBlocksUploads && environment == .production }
966 nonisolated var canUpload: Bool { if uploadsBlockedByBuild { return false }; return defaults.bool(forKey: AppSettingsKeys.syncUploadsEnabled) }
```
  生效点:`attach` 1068-1072(仅日志)、1125 `if uploadsBlockedByBuild { return }`(跳过接所有上传 sink)、每个 sink `guard … self.canUpload` 1141/1150/1159/…。环境判定 `Done/Services/SupabaseEnvironment.swift:99-120`(release→production;staging→staging;debug→`SYNC_ENV` 环境变量/启动参数/`syncEnvironment` 默认值,否则 production)。
- `syncUploadsEnabled`:键 `Done/ContentView.swift:307 "syncUploadsEnabled"`;注册默认 true 312-319(`registerLaunchDefaults` 在 `DoneApp.swift:682` 调);读:`SupabaseSyncService.swift:968`、`AgentSettingsView.swift:699`(@AppStorage,Toggle 727)、798;写:擦除置 false `AgentSettingsView.swift:1031`,换号置 true `SupabaseSyncService.swift:1420`;开/关回调 976-998(关闭同时停 puller,D9 双向)。
- `SyncOfflineSwitch` `Done/Services/Sync/SyncOfflineSwitch.swift:15-32`:`#if DEBUG` 独有;`launchVariable = "SYNC_OFFLINE_FILE"`(19);`checkOnline()` 27-30 在该路径文件存在时 `throw URLError(.notConnectedToInternet)`;调用点 `SupabaseSyncService.swift:347-351`(token 之前)、466-468(fetchAll)。语义 = 模拟器「拔网」,每请求检查、无需重启。

## 8. `DiagnosticTrail`

结论:API `record(category, message)`;落盘 `Application Support/Diagnostics/trail.log` + `trail.1.log`(XCTest → `Diagnostics-TestHost`);单文件 192KB 轮转,保留 192-384KB;可从 app 内导出(`exportFile()` → tmp 文件,Developer 页用);同步 `write(2)`、无 fsync。**86 处/按文件分布未能核实(无 grep)**;下列 14 个已读站点抽样:错误/拒绝类 5、信息类 9。

- `Done/Services/DiagnosticTrail.swift`
```
42  static let rotateAtBytes = 192 * 1024
87-93  directory = Application Support/<Diagnostics|Diagnostics-TestHost>; liveURL trail.log; rotatedURL trail.1.log
103 static func record(_ category: String, _ message: String)
110 appendLocked(line: "\(timestamp()) [\(sessionID)] \(category) \(message)")
216 static func exportFile() -> URL?        // tmp/done-diagnostic-trail.txt(206-211)
233 static func clear()
```
  无 fsync:22-28 头注释明说。
- 抽样站点(file:line · 类别 · 原文 · 判定):
  1. `Done/Models/EventStore.swift:200` Persistence `DiagnosticTrail.record("Persistence", message)` · 信息(helper)
  2. `EventStore.swift:205` Persistence `"ERROR " + message` · 错误(helper)
  3. `EventStore.swift:1023-1031` Persistence `"load: calendar=… deltaRecords=… FAULTS=…"` · 信息(计数;FAULTS 后缀仅故障时)
  4. `EventStore.swift:1135` AssetGC `"skipped: \(refusal)"` · 警告
  5. `EventStore.swift:1150/1152` AssetGC `outcome.summary` / `"deleted \(path)"` · 信息
  6. `EventStore.swift:1361-1364` StraddleHeal `"healed N all-day row(s)…"` · 信息
  7. `Done/Services/Storage/DurableEventStorage.swift:72 / 77` Persistence `trail()` / `trailError("ERROR " + …)` · 信息 / 错误
  8. `Done/Services/SupabaseSyncService.swift:1301` Sync `"sync.cursor.dropped reason=generation tables=…"` · 异常
  9. `SupabaseSyncService.swift:1307` Sync `"sync.blocked.owner_mismatch owner=… session=…"` · 错误态
  10. `SupabaseSyncService.swift:1374` Sync `"sync.owner.adopt_refused reason=owner_exists…"` · 拒绝;`1382 "sync.owner.adopted…"` · 信息
  11. `SupabaseSyncService.swift:1405 / 1416` Sync `"sync.owner.switch_refused reason=…"` · 拒绝;`1423 "sync.owner.switched…"`、`1476 "sync.owner.switch_held…"`、`1490 "sync.switch_alert.presented n=…"` · 信息
  12. `Done/Services/Sync/SyncPuller.swift:242` Sync `"sync.feed.reprobe reason=foreground"` · 信息;`254 "sync.doorbell.restart reason=…"` · 信息
- 形态事实:消息是 `key=value` 风格自由文本,无结构化字段;Sync 域用 `sync.<area>.<event>` 点号命名(可直接当编译期事件 ID 候选)。

## 9. 失败枚举 / `SyncRecovery` / `storageFault*`

结论:`SyncWriteFailureKind` 8 个 case;`SyncRecovery` 产出的是「恢复提示」类型(Item/Prompt/WriteBack),不是失败枚举;存储故障 = `EventStore.storageFaults: [StorageSlot: SlotFault]`,唯一写入点在 `adopt()`(load 时),`SlotFault` 5 个 case 定义在 `DurableEventStorage`。

- `Done/Services/Sync/SyncWriteFailure.swift:28-62`
```
28 enum SyncWriteFailureKind: Equatable {
32 case unauthorized  35 case retryable  39 case schemaCache  42 case tooLarge
45 case rejected      51 case accountMissing  57 case epochStale  61 case paused
```
  `SyncWriteFailure{kind, code, mayHaveLanded}` 64-69;`classify` 84-139。同文件:`SyncTokenRefreshOutcome` 160-167(refreshed/kept/signedOut)、`SyncAccountCheck` 173-195(none/suspected/accountExists/signedOut)。
- 传输层错误 `SupabaseREST.SyncError` `SupabaseSyncService.swift:539-567`:upsertFailed/deleteFailed/fetchFailed/requestFailed/malformedResponse/accountMissing/gateRejected/missingColumn/notSignedIn/tokenExpired(10)。
- `SyncRecovery` `Done/Services/Sync/SyncRecovery.swift:34-58`:`SyncRecoveryItem{id, table, rowId, title, lastEditedAt, serverHasRow}`、`SyncRecoveryPrompt{count, leaseFailedCount, items}`、`SyncRecoveryWriteBack{accepted, leaseFailed}`;来源是 `ConflictShelf` 行(86-89、116-150)。
- 存储故障:
```
Done/Models/EventStore.swift:641  @Published private(set) var storageFaults: [StorageSlot: SlotFault] = [:]
649  @Published private(set) var writeFailedSlots: Set<StorageSlot> = []
653  @Published private(set) var persistenceDegraded = false
1179 if let fault = storage.faults[slot] { 1180 storageFaults[slot] = fault; 1181 refreshPersistenceDegraded() }   // adopt(),load() 965-995 调
Done/Services/Storage/DurableEventStorage.swift:130-155  enum SlotFault { decodeFailed(detail:quarantinedAs:), ioError(detail:), directoryUnavailable(detail:), lostAfterManifest, lostAfterCommit }  isTransient 149-154
```
  `writeFailedSlots` 的写入点(保存路径)未读到;UI 文案 `storageFaultTitle/Body/storageWriteFailedBody` `Done/Models/AppLocalization.swift:664-666`。

## 10. `AppMetricsReporter` / `MetricPayloadStore`

结论:回调里实际读取并记日志的字段:`animationMetrics.scrollHitchTimeRatio`、`memoryMetrics.peakMemoryUsage`、crash(exceptionType/exceptionCode/signal/terminationReason)、hang(hangDuration)、cpuException(totalCPUTime);**`diskWriteExceptionDiagnostics` 没有被读取**(只随整包 JSON 落盘)。原始 JSON 经 `MetricPayloadStore` 持久化,上限 2MB / 40 文件,最旧先逐。

- `Done/DoneApp.swift:496-549`
```
504 MXMetricManager.shared.add(self)                                   // AppDelegate:468 调 start()
511 if let ratio = payload.animationMetrics?.scrollHitchTimeRatio { … }
515 if let peak = payload.memoryMetrics?.peakMemoryUsage { … }
518 persist(payload.jsonRepresentation(), kind: "metric")
525-533 crashDiagnostics / hangDiagnostics(hangDuration) / cpuExceptionDiagnostics(totalCPUTime)
534 persist(payload.jsonRepresentation(), kind: "diagnostic")
```
- `Done/Services/Storage/MetricPayloadStore.swift`:`maxTotalBytes = 2 * 1024 * 1024`(43)、`maxFileCount = 40`(45);目录 `DiagnosticTrail.directory/MetricKit`(99-100),旧堆 `Documents/Diagnostics`(101);`wipe()` 149-159;持久化契约 163-170(单包超限直接拒写)。

## 11. Data & Privacy 设置页

结论:页面只有 **一个** 开关(`syncUploadsEnabled` 同步总闸),无任何诊断/遥测开关;「数据保存在本机」文案 = `hintLocalData`(另有同义的 `hintClearData`)。

- `Done/Views/Agent/AgentSettingsView.swift:684-996 struct DataPrivacySettingsView`:Privacy 卡 `Text(L(.hintLocalData))` 718-724;Sync 卡 `Toggle(isOn: $syncUploadsEnabled)` + `L(.uploadToCloud)`/`L(.uploadToCloudHint)` 726-744,DEBUG 橙字 737-743 `"Debug build: uploads to production are blocked regardless of this toggle…"`;Cloud Backup 746-770;Sync Status 772-824(`L(.uploadsOffHint)` 798-804);Manage Data 826-838(清技能洞察/清 Token 缓存/重置全部)。
- 文案(`Done/Models/AppLocalization.swift`,键声明 282 / 393):
```
659  .hintLocalData  en "Settings, insights, templates, and AI learning are kept on this device."
1328 .hintLocalData  zh "设置、洞察、模板和 AI 学习数据保存在本设备上。"
660  .hintClearData  en "Done currently keeps its data locally on this device. Clearing data below cannot be undone."   zh 1329
1137 .uploadToCloud  en "Sync this device with the cloud"          zh 1791 "此设备与云端同步"
1138 .uploadToCloudHint en "When off, this device neither uploads nor downloads: … On by default, and signing in turns it on. Independent per device…"   zh 1792
1139 .uploadsOffHint en "Sync is off for this device. Turn on the Sync switch above to send and receive changes."   zh 1793
```
  相关:`.privacy` 623/1292,`.dataAndPrivacy` 540/1209,`.hintResetAllData` 663/1332。

## 12. 服务端:RLS 惯用写法 / 触发器挂法 / `sync_feed_checks.sql`

结论:015 的 RLS 惯用写法 = `enable row level security` + `revoke all` + 精确 `grant` + `do $$ if not exists (pg_policies…) then create policy … end $$`;触发器由一个显式 `tables` 数组循环挂上,`sync_changes` RPC 也是显式九表 UNION ——**新表只要不写进这两处就天然不进变更流**。checks.sql = psql 脚本,`pg_temp.rec(id, claim, pass, observed)` 写临时表,末尾打印 PASS/FAIL 并在有 FAIL 时 `raise exception` 让 psql 非零退出。

- 文件 `done-mcp/supabase/migrations/015_sync_change_feed.sql`(731 行)。注意第 7-8 行仍写 `STATUS: DRAFT — NOT APPLIED to production`,与现场(记忆:10-22 生产已应用)不一致——文件头过期。
- RLS 原文 192-208:
```
192 alter table public.sync_epoch enable row level security;
193 revoke all on table public.sync_epoch from public, anon, authenticated, service_role;
194 grant select on table public.sync_epoch to authenticated, service_role;
196 do $$ begin if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'sync_epoch' and policyname = 'read sync epoch') then
203   create policy "read sync epoch" on public.sync_epoch for select to authenticated using ( true );
```
  按用户过滤的写法 245-253:`create policy "read own versions" … for select to authenticated using ( user_id = (select auth.uid()) );` / `"log own versions" for insert … with check ( user_id = (select auth.uid()) and pg_trigger_depth() > 0 )`。外键级联 224 `user_id uuid not null references auth.users(id) on delete cascade`。service_role 绕过 RLS 的提醒 168-170、219-221。
- 触发器挂法 485-576:
```
489 tables text[] := array['events', 'event_logs', 'event_feedback', 'todo_lists', 'event_types', 'skill_insights', 'user_settings', 'agent_preferences', 'agent_conversations'];
546 create trigger trg_%s_sync_gate before insert or update … execute function public.sync_gate()
550 trg_%s_sync_meta → set_sync_meta();  553 trg_%s_sync_version after … → sync_log_version(%L)
559/563 trg_%s_notify_ins / _upd after … for each statement → notify_sync_change()
568 trg_%s_tombstone before delete → sync_delete_to_tombstone(%L);  572 trg_%s_no_truncate before truncate
```
  `sync_changes` RPC 617-644 显式 UNION 九表;`revoke execute … from public, anon; grant … to authenticated` 646-647。门铃 392-411 `realtime.send(…, 'user:' || user_id, true)`。
- `done-mcp/supabase/tests/sync_feed_checks.sql`(806 行):
```
2-3   -- Run against a local `supabase start` stack as the postgres role: psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f sync_feed_checks.sql
21    create temp table bench (ord serial, id text, claim text, pass boolean, observed text);
22-25 create function pg_temp.rec(p_id text, p_claim text, p_pass boolean, p_observed text) …
42-47 pg_temp.as_user(conn, uid): dblink_exec 'set request.jwt.claims = {"sub":…,"role":"authenticated"}' + 'set role authenticated'
796   select case when pass then 'PASS' else 'FAIL' end as verdict, id, claim, observed from bench order by ord;
800-805 \if :any_fail  \echo 'FAILED checks:' :fails  do $$ begin raise exception 'sync_feed_checks: some checks failed'; end $$;  \else \echo 'all SQL checks passed'
```
  每条检查形如 `select pg_temp.rec('S1', '<claim>', <bool>, format('observed…'))`;S24(756-777)用 `\ir ../migrations/015_sync_change_feed.sql` 验证重跑幂等。006 迁移文件名未知、未读。

## 13. `AppSettingsKeys` 中的功能开关

结论:`enum AppSettingsKeys`(`Done/ContentView.swift:79-469`)实有 **53 个 `static let`**(不是 62):49 个 UserDefaults 键字符串 + 2 个默认值(`agentProviderDefault` 212、`meBackgroundTypesDefault` 287)+ 2 个集合(`launchRegisteredDefaults` 312、`resettableUserDefaultsKeys` 321)。其中布尔功能开关 22 个。

- 布尔开关(行号):rememberLastTab 80 · showTimerBanner 84 · landscapeFocusMode 85 · landscapeFocusKeepAwake 86 · analysisAutoLoadSuggestions 88 · effortOpacityEnabled 93 · experimentalMultiTypeEvents 97 · calendarRememberViewMode 113 · calendarAutoReturnToToday 125 · holidaysShowSolarTerms 128 · holidaysShowGregorianHolidays 131 · calendarAdjacentEventSnapEnabled 149 · calendarEventShowTimeBelowTitle 157 · focusConfirmBeforeTracking 169 · calendarUseCALayerAxisMarkers 175 · calendarUseCALayerMiniDayTimeline 182 · calendarUseUIScrollViewTimeline 191 · calendarUseImperativeDayLayer 201 · agentAskBeforeCreatingEventTypeTemplates 207 · calendarAgenticCreateEnabled 210 · tokenInferenceLLMEnabled 220 · syncUploadsEnabled 307。(`achievementCelebrationSeeded` 144 是状态位非用户开关。)
- 枚举/数值设置(抓现场也有意义):appearanceMode 81 · defaultTab 82 · analysisDefaultPeriod 87 · experimentalMultiTypeMaxCount 100 · calendarHeaderExposedTools 105 · detailHeaderExposedTools 109 · calendarLastRangeMode 111 · calendarEventFontSize 153 · nearFutureHorizonDays 163 · agentProvider 205 · calendarShareStyle 293;外加 `AppSettingsLocale.languageKey/timeFormatKey`(`AppLocalization.swift:71-72`)。
- 不在此枚举的开关:`SpikeFeatureFlag.enabledKey/variantKey` = `spike.<id>.enabled/.variant`(`SpikeModel.swift:118-126`);`SupabaseEnvironment.defaultsKey = "syncEnvironment"`(`SupabaseEnvironment.swift:85`,DEBUG 用)。
- **绝不能抓**的键(同枚举内):agentAPIKey 206、mcpURL 232(带 token 的连接 URL)、personalityProfile 141、meReflectionLog 284、meDisplayName 274。
- 425-433 注释自述 round-2 QA 时「50 个 static let」。

## 14. 后台模式 / 退后台边沿现有工作 / 耗时测量

结论:`Done/Info.plist` **没有** `UIBackgroundModes`(全文 66 行,键见 5-64)。`BGTaskScheduler`/`URLSessionConfiguration.background` 全库零使用 **未能 grep 核实**,但 `LocalDataEraseEpoch.swift:55-62` 明文记录「写作时核实:全部 `URLSession.shared`、无 `UIBackgroundModes`、无 `BGTaskScheduler`,唯一 `beginBackgroundTask` 是 widget 类别统计」,且已读的所有请求均 `URLSession.shared`(`SupabaseSyncService.swift:370, 481`)。退后台边沿上现有工作如下;**没有找到任何对这些 flush 的耗时测量**。

- `Done/Models/EventStore.swift:910-959`(init 中):
```
910-914 MergeMany(willResignActive, didEnterBackground, willTerminate)
946 self?.flushCalendarEventColorDepthMirror()
947 self?.flushWidgetSnapshotSync()
950 self?.flushCalendarDeltaCheckpoint()          // 2MB 日历 blob 的 checkpoint 折叠
956-958 if note.name == didEnterBackground { self?.storage.syncDirectoryToStableStorage() }   // 唯一全量 flush-to-media
```
- `ResidentObservationCenter.swift:193-201 → 356-363`:关窗口 + 一次 `stamp()` + 一次 JSONL append(+ stat)。
- `ContentView.swift:669-677` didEnterBackground → `skillAnalysisTask?.cancel()`。
- `DoneApp.swift:765-767` `.onChange(of: scenePhase)` → `handleDominoScenePhase`(domino 定时器停/起)。
- `SyncPuller.swift:226-233` 订阅 `willEnterForegroundNotification` → `foregroundDidReturn()` 238-246(回前台拉一次)。
- widget 构建成本门:`EventStore.swift:715-716 categoryStatsInlineWork = 1_500`(天数×事件数超此值离主线程);`beginBackgroundTask` 具体行号未定位(EventStore 后半未读)。
- 现成测量:仅 load 侧 `calendarReadMs/foldMs`(`EventStore.swift:978-980, 1029`)与 DurableEventStorage 的 fsync `syncMs`(头注释 29-30);退后台 flush 的总耗时无测量。

## 15. 退后台时的同步网络行为

结论:出站 = 主 RunLoop `Timer` 去抖(2s / settings 5s)→ `Task { await syncX }` → `URLSession.shared`;**退后台不触发任何 flush,也不取消任何请求,没有 `beginBackgroundTask`**;挂起时未到期的去抖 Timer 和在途请求随进程一起挂起,恢复后继续。未完成请求的真值靠「发送前基线写 `?` + 响应分类 `mayHaveLanded`」兜底。

- 去抖与调度:`Done/Services/Sync/SyncScheduler.swift:30-52`(`RunLoopSyncScheduler`:`Timer(fire:…)` + `RunLoop.main.add(timer, forMode: .default)`);sink 接线 `SupabaseSyncService.swift:1138-1276`(每个 `.syncDebounceSink(for: debounce, on: scheduler) { guard self.canUpload, self.isFullSyncDone … Task { await self.syncX } }`);`debounceSeconds = 2.0`、`settingsDebounceSeconds = 5.0`(28-31)。
- 生命周期订阅:`SupabaseSyncService.swift` 1-1500 内无 didEnterBackground/willResignActive;`SyncPuller.swift` 1-340 仅 willEnterForeground(226-233);`ContentView.swift:669-677` 只取消技能分析任务。
- 未完成请求语义 `Done/Services/Sync/SyncWriteFailure.swift:13-20`:
```
13 mayHaveLanded  whether the request may have reached the server and been applied even though no answer came back. …
18 It is for the log only: the baseline already holds the `?` the send wrote (survey S4, design §6 结果未知的写), and a failure writes nothing more whatever this says.
```
  `classify` 84-120(传输错误按 `notSentURLErrors` 74-79 判是否可能已落地);`[]` 应答进 `pendingVerify`(`SupabaseSyncService.swift:730-737`)等下次拉到 head 清算;`SyncUnknownResultTests.swift` 存在(pbxproj:315)。

---

## 蓝图断言核对表

| # | 蓝图位置 | 断言 | 判定 | 实际 |
|---|---|---|---|---|
| 1 | §1 L23 | `ResidentTierOneCore` 固定键计数 + 32 条手势环 | 已证实 | `gestureRingCapacity = 32` ResidentObservationModel.swift:305 |
| 2 | §1 L23 | `SpikeProbe.emit` 无监听者时一次 optional-closure nil-check | 有出入 | 生产中 resident 常驻,`onSignal` 进程期非 nil,每次 emit 是一次闭包调用进 `core.ingest`(SpikeModel.swift:859-865;Center:239-253);nil-check 路径只在 XCTest |
| 3 | §1 L25 | `Documents/spike-runs/<spikeID>.jsonl` | 已证实 | SpikeRunStore.swift:52-62, 90-92 |
| 4 | §1 L25 | 写前 OPEN + CLOSE 同 id 折叠 | 部分证实 | 手动 run 是 beginRun+finishRun;观察站日汇总/窗口只调 `finishRun`(Center:351, 425),同 id 反复 append 靠 collapse |
| 5 | §1 L25 | 200 run/spike + 256KB 字节兜底 | 已证实 | :73, :79;另有压实目标 128KB(:88)蓝图未提 |
| 6 | §1 L26 | 触发 = 观察站落盘边沿(退后台 / 启动 / 打开观察站 / 跨天) | 有出入 | 观察站边沿是 willResignActive+didEnterBackground+willTerminate(一轮一次)/ 打开观察站 / 跨天;**没有「启动」flush**,init 只读(Center:108-142) |
| 7 | §1 L27 | checks.sql 照 `sync_feed_checks.sql` | 已证实 | 文件存在,结构见 §12 |
| 8 | §2 L32 | `SpikeRun` 字段表 | 有出入 | 漏 `buildConfiguration: String?`(:262);`metrics` 是 `[String: SpikeMetricValue]`(:274)非 `[String: Double]` |
| 9 | §2 L34 | 新增 `isDebugBuild` | 有出入 | 已有 `buildConfiguration` "debug"/"release"(SpikeModel.swift:262;SpikeRunStore.swift:311-317),评估器已据此分区(:707-709) |
| 10 | §2 L36 | metrics 键只能来自编译期清单;未知键 seed 时丢弃 | 部分证实 | 对 `resident-daily` 成立(`init(metrics:)` 240-269);窗口记录键固定在 `ResidentWindowAggregates.metrics` 521-582;手动 spike runner 的 metrics 构造未读 |
| 11 | §3 L43 | 观察站现 12 窗口/天 | 已证实 | `ResidentWindowModel.dailyBudget = 12`(:439) |
| 12 | §3 L45 | `acceptance?` 验收字段 | 未找到 | 现有 `FixObservationEntry` 无此字段,阈值硬编码在 Evaluator(§5) |
| 13 | §3 L46 | 退役不删条目(R-F11) | 已证实 | `FixObservationLifecycle` 587-596 |
| 14 | §4 L50 | resident-daily + auto-window 原样上传;每修复条目一个枚举值 | 已证实 | id 常量 615-617;`FixVerdictState` 4 值 + `alarm` Bool(回归警报不是枚举值) |
| 15 | §4 L52 | 86 处 `DiagnosticTrail` 写入点(同步 22+17+11、EventStore 10、恢复 6) | 未能核实 | 无 grep;已读文件内抽样 14 处见 §8 |
| 16 | §4 L52 | `SyncWriteFailureKind` 等失败枚举 | 已证实 | 8 case,SyncWriteFailure.swift:28-62 |
| 17 | §4 L53 | `AppMetricsReporter` 回调里有 scrollHitchTimeRatio、hang 次数、峰值内存、diskWriteException 次数 | 有出入 | 回调读 scrollHitchTimeRatio/peakMemoryUsage/crash/hang/cpuException(DoneApp.swift:511-533);**diskWriteException 未读取**,只在原始 JSON 里 |
| 18 | §5 L58 | 不用 identifierForVendor | 未能核实 | 无 grep;已读文件无此调用 |
| 19 | §5 L58 | 签出状态不上传 | 已证实(机制) | `userToken()` 无 token 抛 `notSignedIn`(SupabaseSyncService.swift:104-110) |
| 20 | §5 L59 | 开关放 Data & Privacy;复用同步的「Debug 包禁止往生产传」闸门 | 有出入(重要) | 闸门是 `SupabaseSyncService.uploadsBlockedByBuild`(:956-958),只在 attach 跳接 sink(:1125)和 `canUpload` 生效,**不在 `SupabaseREST.send` 内**;新上传器直接用 gateway 不会被挡,须自判 `SupabaseEnvironment.current == .production && DEBUG` |
| 21 | §5 L59 | 「数据都保存在本机」文案 | 已证实(需改两条) | `.hintLocalData` 659/1328 与 `.hintClearData` 660/1329 都说本机 |
| 22 | §5 L61 | 账号删除 user_id 外键级联 | 已证实(惯用法) | 015:224 `references auth.users(id) on delete cascade` |
| 23 | §5 L61 / §8 L79 | 本地擦除清游标「进 #266 注册表」 | 有出入 | #266 注册表未实现(AgentSettingsView.swift:1231-1245);现行 = 手工清单 + `EraseWiringQATests` 字符串断言,新文件需走 §6 四步 |
| 24 | §6 L65 | 不进 `sync_changes` | 已证实(默认成立) | 触发器与 RPC 都是显式九表(015:489-492, 617-644),不写进去就不进 |
| 25 | §6 L65 | 不进 snapshots | 未能核实 | `BackupSnapshotService` 未读 |
| 26 | §6 L65 | RLS:insert/update/select 自己的行,不 delete | 已证实(惯用法可用) | 015:241-256 模式;注意 service_role 绕过 RLS(015:168-170, 219-221) |
| 27 | §7 L71 | 热路径每信号 ≤ 1 Date 读 + 1 Double 比较 + 1 数组下标 += 1 | 部分证实 | `.counter/.invariant` 路径符合(Center:246 + ingest 329-340);`.gesture` 路径含 lag 算术、环追加、`trimRecords` 不止一次下标 |
| 28 | §7 L74 | 本地池沿用 200 run/spike + 256KB | 已证实 | 同 #5 |
| 29 | §7 L75 | censoring 标记沿用观察站 | 已证实 | `wTapsMissingFrameAfterCommit`/`wClosedByResign`(ResidentObservationModel.swift:554-558) |
| 30 | §7 L75 | Debug 行打标并被闸门挡在生产外 | 部分证实 | 打标已有(`buildConfiguration`);闸门见 #20 |
| 31 | §8 L79 | 计数键只能来自编译期清单(源扫描) | 已证实(有先例) | 模型文件已有源扫描禁 UserDefaults/Calendar.current(ResidentObservationModel.swift:7-9);`EraseWiringScan` 是另一套读源码断言 |
| 32 | §9 L83 | 表放 public 前缀还是独立 schema | 事实 | 现有全部表与 RPC 在 `public.*`(015 全文) |
| 33 | §0 L15 | TestFlight 容器 devicectl 拉不出(#235) | 未能核实 | 非代码事实 |
| 34 | §0 L19 | #197 拍板 `spike_runs` 表/上传/独立开关 | 已证实「零实现」 | 已读的 Data & Privacy 页只有同步总闸(§11);迁移目录仅见 015,无 spike_runs 表(目录未能列出) |
| 35 | §13 任务项 | `AppSettingsKeys` 62 个 key | 有出入 | 实有 53 个 `static let`,49 个键字符串(ContentView.swift:79-469) |
| 36 | §4 任务项 | `FixWatchSignalID` 两个 tripwire | 有出入 | 一个 tripwire(`meComputedHidden`,`.invariant`)+ 一个 liveness 计数(`meComputedVisible`,`.counter`),AnalysisView.swift:463/465 |
| 37 | §7 任务项 | `SupabaseREST` 所在文件 | 事实 | 不是独立文件,在 `Done/Services/SupabaseSyncService.swift:73` |
| 38 | §12 任务项 | 015 迁移状态 | 有出入(文件头) | 015 第 7 行仍写 `DRAFT — NOT APPLIED to production`,与现场记录(10-22 已应用)不一致,文件头过期 |

未读/未能核实清单(供后续有 shell 时补):`DiagnosticTrail.record` 全库计数与按文件分布;`identifierForVendor`/`BGTaskScheduler`/`URLSessionConfiguration(` 全库 grep;`BackupSnapshotService` 的 snapshot 内容;`writeFailedSlots` 写入点;`EventStore` 中 `beginBackgroundTask` 行号;006 迁移文件;`Spike201Runner` 的 metrics 键构造;`AchievementCatalog.compute(visible:)` 定义。
