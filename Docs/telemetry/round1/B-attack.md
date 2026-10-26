# B — 对抗报告:遥测底盘 v0 蓝图

对象:`scratchpad/chassis/v0-blueprint.md`(2026-10-24)。仓库 king-of-rubbish-bin @ fd92618,只读。
取证限制:本机磁盘已满(ENOSPC),Bash/grep 不可用,所有事实来自直接 Read。蓝图说的「86 处 DiagnosticTrail 写入点」只核了约 30 处(SupabaseSyncService 1–3750 行、EventStore 1–2320/4560–4741、ContentView、DoneApp);`SpikeProbe.emit` 站点数与仓库级 PrivacyInfo 搜索未能完成,相关条目已标明。
记录尺寸基线(按 SpikeRun 字段逐项估算):resident-daily 一行 ≈ 0.8–0.9 KB(18 个 metrics 键 + 12 个上下文字段);auto-window 一行 ≈ 1.0–1.2 KB。下文用 0.85 KB / 1.1 KB。

---

## A. 热路径性能

**F1** · A · P2 · `.counter(String)` 的线性 if 链是 O(K) 不是 O(1),但真正的危险是三处手工登记。
证据:ResidentObservationModel.swift:324-341 用 `id == FixWatchSignalID.x` 链式比较;每加一个键要同时改 ingest(:329-335)、`ResidentCounterSet` 字段(:161-204)、`metrics`(:212-233)、`init(metrics:)`(:240-269)四处;SpikeModel.swift:1008-1013 的 TRAP 注释已承认漏登记 = 「干净的零」。算术:23 usage + 首批 incident ≈ 30–60 个 id,长度不等的 String `==` 约 5–10 ns 早退,最坏 60×10 ns = 0.6 µs/emit,占 120 Hz 帧预算 8.33 ms 的 0.007% — 性能上不致命。
修正:`enum UsageKey: Int, CaseIterable` 下标进固定 `[Int]`;`SpikeSignal.counter(UsageKey)`;metrics/seed 由 `allCases` 派生,登记=加一个 case。改 §1 L0、§3。

**F2** · A · P1 · 蓝图没有规定 usage emit 的落点;落在 `body` 里的 emit 数的是重渲染不是使用。
证据:常驻体故意忽略 `.bodyPass`(ResidentObservationModel.swift:342-347),理由正是 body pass ≠ 用户动作;detailBodyPasses 一天数千。一个「打开周视图」计数若放在 `CalendarPageView.body`,一次拖拽 = 几十次「使用」。
修正:usage 只允许从 action 闭包 / `onAppear` / `onChange` 发,走独立 `UsageProbe.used(.x)` API 便于 review;服务端 sanity:某键日计数 > 当日 detailBodyPasses 即标 suspicious。改 §3 costContract、§4.2。

**F3** · A · P2 · 每个观察系统各注册一个 resident,则每 emit 多一次 String 哈希字典查找 + 一次 switch。
证据:SpikeSessionCoordinator.swift:346-353 `dispatch` 对 `residentOrder` 逐个 `residents[id]`(Dictionary<String,…>,20 字符键哈希 ≈ 50–100 ns)。今天 1 个 resident;若 usage/incident/metrickit 各自成 resident = 4 次哈希 + 4 次 switch/emit。
修正:单一 resident、单一 switch;或 residents 存数组。改 §1 L0、§3。

**F4** · A · P2 · incident 计数从 `DiagnosticTrail.record` 进 @MainActor core 需要线程跳转或不安全写。
证据:DiagnosticTrail 是 `nonisolated enum`,任何线程可调(DiagnosticTrail.swift:39, :103);core 在 @MainActor(ResidentObservationCenter.swift:45)。每条 trail 加 `DispatchQueue.main.async` = 一次闭包分配。category 是自由字符串(:103)。
修正:计数器放在 DiagnosticTrail 自己的 `lock` 下的固定 `[Int]`(它已有 NSLock :44),flush 时读;category→下标映射用编译期枚举,`default` 走 `trailUnmappedCount`(liveness,覆盖漂移可见)。改 §4.3。

## B. 落盘与电量

**F5** · B · P1 · §7 预算「≤64 KB、≤20 请求/天」被 §1 L3 的触发设计直接击穿。
算术:每次退后台 flush 4 条 daily(计数变了→哈希变了→重传):0.85 KB × 4 × 25 次/天 = 85 KB/天(>64 KB);请求数 = 25(逐边沿合包)或 100(逐记录),均 >20。20 次/天也 68 KB。
修正:daily 只在跨天 + 启动(+ 打开观察站)上传;边沿只传 window/verdict/manualRun;加脏标记(F6)。改 §1 L3、§7。

**F6** · B · P2 · `writeDailyRecord` 在每个边沿无条件追加同 id 行,哪怕计数没变;压实周期与主线程成本随之。
证据:ResidentObservationCenter.swift:356-370 → :403-426 无脏检查;`finishRun` 同步调 `compactIfNeeded`(SpikeRunStore.swift:115-120),过阈值全量 read-decode-rewrite(:237-244)。算术:25 行/天 × 0.85 KB = 21 KB/天/文件,256 KB 阈值 ≈ 12 天一压,每压 ≈ 300 次 JSON decode ≈ 12–15 ms,落在退后台边沿主线程;4 个 daily 文件各自如此。
修正:`ResidentCounterSet` 已 Equatable,flush 前比对上次快照,相等不写;churn 降 ≥60%。改 §1 L2。

**F7** · B · 非问题(记录以免浪费精力)· diskWriteException 之忧在此量级不成立。
算术:追加 85 KB/天 + 压实 (256+128) KB/12 天 ≈ 32 KB/天 ≈ 120 KB/天;MetricKit 阈值 1 GB/天;#235 的肇事量是 2 MB × 461 ≈ 922 MB/天。差 4 个数量级。改 §7(删掉该担忧,换成 F5 的预算)。

**F8** · B/D · P2 · MetricKit 回调不在主线程,`finishRun` 不是线程安全的追加。
证据:`appendLine` 用 `seekToEnd` 再 `write`,无 O_APPEND、无锁(SpikeRunStore.swift:218-222);`didReceive` 由 MetricKit 在其自身队列回调(DoneApp.swift:509-536)。两个写者同文件 = 撕裂/覆盖行。另外 payload 覆盖的是前一天(`timeStampBegin/End`),dayKey 若取收到时刻就差一天。
修正:metrickit-daily 独占一个文件且回调 hop 到 main 再写;dayKey 取 payload 的 `timeStampBegin`。改 §4.4。

## C. 上传机制

**F9** · C · **P0** · 进程级随机哈希种子让游标永远「不一致」→ 每次启动全量重传,且全程 2xx、全部测试绿。
证据:(1) `appendLine` 的 `JSONEncoder()` 未设 `.sortedKeys`(SpikeRunStore.swift:202-203),`metrics: [String: SpikeMetricValue]`(SpikeModel.swift:274)按 Swift Dictionary 迭代序编码,而 Dictionary 的 Hasher 种子每进程随机 → 同一记录两次启动编码字节不同;(2) 若用 `Hasher`/`hashValue` 直接算,同样每进程不同。算术:≤200 run × 5 文件 × ~1 KB ≈ 1 MB/启动;5 台 × 10 次启动/天 = 50 MB/天,是 §7 预算的 ~800 倍;服务端 upsert 幂等所以行数不变、没人察觉 — 正是 62.7M 的形状(无守卫、无去重、看起来在工作)。
修正:哈希 = SHA-256(CryptoKit)over `.sortedKeys` 编码,或 over 规范化元组;测试见 F36。改 §1 L3、§8。

**F10** · C · P1 · 「退后台尽力发一次不等结果」没有 `beginBackgroundTask`,大概率被挂起切断,请求翻倍。
证据:退后台时上传排在 EventStore 的四步 flush 之后(EventStore.swift:910-959:颜色深度镜像、widget 快照 + 分类统计构建、delta checkpoint、目录 sync),起步就晚;蜂窝冷 DNS+TLS 0.5–1.5 s;`send` 走 `URLSession.shared` 默认配置(SupabaseSyncService.swift:370),挂起后响应读不到 → 游标不前进 → 启动再传一遍。全 app 唯一一处 `beginBackgroundTask` 在 EventStore.swift:4717-4731,LocalDataEraseEpoch.swift:60-62 明言它「只延长运行中的进程、不重启任何东西」— 它不是被禁的 BGTaskScheduler/后台模式。
修正:要么复用同样的 assertion 包住边沿上传(≤30 s,完成即 end),要么干脆删掉边沿上传,只靠启动 + 跨天 + 打开观察站(更简单,预算内)。改 §1 L3。

**F11** · C · P1 · 启动补传把全部 JSONL 读进主线程,冷启动可见变慢。
证据:`loadRuns` = 整文件读 + 逐行 decode(SpikeRunStore.swift:178-192);常驻体 init 已在主线程做一次(ResidentObservationCenter.swift:129-135, 148-156)。算术:5–8 文件 × ≤256 KB ≈ 1.3–2 MB,1500–2400 次 decode ≈ 60–120 ms;再加 3 个 daily 各自照抄 init 读法 ≈ 4× 今天。
修正:上传器在首个 `didBecomeActive` 后 +2 s 的 `.utility` Task 里跑;每文件一次读、与常驻体 seed 共享;冷启动 harness 前后对拍。改 §1 L3。

**F12** · C · P2 · 游标/installID 的损坏、重装、备份恢复三种失效要写死,碰撞不是问题。
算术:64 位哈希 × 200 记录碰撞概率 ≈ 200²/2⁶⁵ ≈ 1e-15 — 风险在种子(F9)不在碰撞。损坏:decode 失败 = 空游标(幂等全传),绝不 crash、绝不当「已全传」。重装:Documents 没了,无可补。备份恢复到新机:同 install_id 两台在跑,`v_active_installs` 少数 1 — 接受并写明。
修正:游标与 installID 文件放进 `Documents/spike-runs/`(如 `.upload-cursor.json`),`SpikeRunStore.wipe()` 已在擦除清单(AgentSettingsView.swift:1268)→「擦除后游标不存在」结构成立,不新增 #266 条目。改 §1 L3、§5。

**F13** · C · P2 · 「2xx 但没落」有两条真实路径,且现有网关的单列 `on_conflict` 对不上复合主键。
证据:`merge-duplicates, return=minimal` 下 PostgREST 一律 201;静默不落只会来自 BEFORE 触发器返 NULL 或带 WHERE 的 RPC 影响 0 行(F22 的建议会引入后者)。`upsertMerging(table:keyColumn:)` 只接一个键列(SyncGateway.swift:147),PK (user_id, run_id) 需 `on_conflict=user_id,run_id`,内存假服务器按单列去重会与生产分叉。
修正:`return=representation` 并断言返回行数 == 发送行数后才推进游标;网关加复合键参数且假服务器同样按复合键。改 §1 L3、§6、§8。

**F14** · C · P1 · 必须复用 `SupabaseREST.send` 与现有闸门,但要把遥测表排除在 015 触发器循环之外。
证据:`send` 负责 token 刷新 + 401 重试、offline 开关、apikey/Authorization(SupabaseSyncService.swift:338-382);闸门 `uploadsBlockedByBuild`/`canUpload`(:956-969)。自写 URLSession 会复制鉴权、绕过 DEBUG offline 开关,使「开关关=零请求」无法用 harness 验。但 `send` 对每个写请求附 `X-Sync-Epoch`(:346, :361-363);若遥测表被加进 015 的逐表触发器循环(015_sync_change_feed.sql:485-576)得到 `sync_gate`,则 sync 暂停/epoch 过期时遥测跟着被拒 — 观测者与被观测者耦合。
修正:复用网关;迁移里明确遥测表不进 015 表数组、无 sync 触发器;checks.sql 断言该表上无 `trg_*_sync_gate`。改 §6。

## D. 数据质量

**F15** · D · P1 · 当天 app 升级(TestFlight 自动更新)把整天重贴成新构建 — 恰恰毁掉问题 3/4 最关心的那一天。
证据:`latestDailyRecord` 只按 `buildConfiguration` 认领今日 run id(ResidentObservationCenter.swift:129-135, 148-156);`writeDailyRecord` 盖当前 `appBuild`(:404-419);latest-wins 折叠(SpikeModel.swift:295-305)→ 上午 build 10 的计数归 build 11。osVersion 同理。
修正:认领键 = (config, appBuild, osVersion),不匹配即铸新同日 run id(B1 规则推广);视图对同 install 同 day 求和。改 §2、§4.1、§6。

**F16** · D · P1 · 记录不带主人,`user_id` 在上传时绑定 → 签出期与换账号的数据归下一个登录者。
证据:蓝图 §5「签出状态不上传,数据留本地等下次登录」;staging 有 qa-a/qa-b 同机切换的既定做法;一天跨两个账号会折叠进同一 run id。
修正:flush 时把 `ownerUID`(或其哈希)写进记录;上传器只发 owner == 当前 uid 的记录;owner 变化铸新 run id;签出期记录 owner=nil 直接不传并在文案里说明。改 §2、§5。

**F17** · D · P1 · dayKey 的时区与日界的时区是两个来源,旅行后错位。
证据:日界来自 init 时快照的 `calendar`(`Calendar.current` 非 autoupdating,ResidentObservationCenter.swift:102, 108-111),只在跨天重算;记录的 `timeZoneIdentifier` 是 flush 时的 `TimeZone.current`(SpikeRunStore.swift:335)。LA→东京:日界仍 LA,戳说东京;若 dayKey 由 startedAt 按戳的时区格式化,09:00 LA 启动 = 01:00 东京次日 → dayKey 比日界多一天;且旧日界下这一「天」可长达 40 h。
修正:dayKey 在铸 run id 时按 `calendar.timeZone` 对 `dailyRunStartedAt` 取 startOfDay 格式化一次;tz 列存日界的 tz(或偏移分钟),不是 flush 时的。改 §2、§7。

**F18** · D · P1 · 键级「死线 vs 真零」无法区分,问题 2 的答案「30 天没人用」可能是谎话。
证据:emit 站点被删/改名后该键在所有机器上永远 0,与「没人用」同形;SpikeModel.swift:1008-1013 已为 `.counter` 承认此陷阱。
修正:(1) 源扫描:每个 `UsageKey` case 在注册表与测试之外有 ≥1 引用;(2) 同记录带 `sessions`/`appOpened` 作分母;视图把「30 天 sessions>0 且该键全机为 0」标 `possible_dead_wire`;(3) F1 的枚举消灭四处手工登记。改 §3、§6、§8。

**F19** · D · P2 · 本地池会在上传前淘汰未传记录,服务端分不清「被淘汰」与「没发生」。
算术:`loadRuns` 施加 200 上限(SpikeRunStore.swift:191),压实目标 128 KB(:88, :241-243)。window 12/天:按数 200/12 ≈ 16.7 天,按字节 128 KB/1.1 KB ≈ 116 条 ≈ 10 天;daily 128 KB/0.85 KB ≈ 150 天无虞。开关默认关 3 周再开 → 约一半 window 已丢。
修正:接受并写明上界;或压实时把丢弃的未传条数计入下一条 daily(`evictedUnuploaded`),删失可见。改 §1 L2、§7。

**F20** · D · P2 · 删失标记埋在 jsonb 里,视图不复刻设备侧过滤就会与卡片不一致。
证据:`wContaminated`/`wClosedByResign`/`wTapsMissingFrameAfterCommit`/`wTruncatedGesture` 是 metrics 内的 bool/number(ResidentObservationModel.swift:539-559);评估器排除污染窗口(:786-789)。daily 的删失 = `endedAt` < 该 tz 的日终(最后一次 flush 没传上)。
修正:视图派生 `is_contaminated`、`is_partial` 列;commit p50 视图与评估器用同一排除规则并由 checks.sql 用同一夹具对拍。改 §6。

**F21** · D · P2 · 蓝图 §2 把 metrics 写成 `[String: Double]`,实际有 string/bool,且「键来自清单」不约束值。
证据:`SpikeMetricValue` = number/string/bool(SpikeModel.swift:199-203),直方图 `"0 0 1 2 …"`、列表 `"12.3 45.6"` 是 `.string`;`abortReason: String?` 自由文本(:277,今天三个字面量:SpikeModel.swift:330、ResidentObservationCenter.swift:218, 223)。`(metrics->>'tapLagBuckets')::numeric` 直接报错。
修正:注册表每键带值 schema(number | fixedFormatString | bool);`abortReason` 改枚举;视图用 `string_to_array(...,' ')::int[]`。改 §2、§3。

**F22** · D/G · P2 · 同一进程恢复后,被挂起的旧请求可能晚于新请求到达,服务端留下旧版。
修正:记录带单调 `revision`(追加次数);RPC upsert `… WHERE excluded.revision > t.revision`;不要用 `endedAt`(跨天时被设为过去的日终,改 note 也不动它)。配合 F13 的行数校验。改 §6。

## E. 隐私与再识别

**F23** · E · P2 · 设备列对开发者不增加再识别(行本来就以 `user_id` 为键),但一旦离库(贴进 issue、喂给 agent)就是实名。
算术:5 名内测者 × (tz, locale, device_model) 组合 ≈ 一一对应。六个问题只用到 device_model/os_version/app_build。
修正:删 `locale`;tz 只存解释 day_key 所需的偏移分钟;agent 面向的视图聚合且不暴露 install 级设备列。改 §6。

**F24** · E · P1 · 自由文本载体有三个不是一个:`note`、`abortReason`、任何 `.string` metric。只剥 `note` 的实现能过「note 不出现」测试。
证据:SpikeModel.swift:275, :277, :201。
修正:单一 `TelemetryRedactor` 对序列化后的行按 kind/键/值类型白名单过滤;测试见 F37。改 §2、§5、§8。

**F25** · E · P2 · 用户报告的「最近几十行轨迹」含 uid、事件 UUID、occurrence key、相对资源路径、`String(describing: error)`;未见标题/邮箱/响应体(约 30/86 站点已核)。
证据:uid 插值 SupabaseSyncService.swift:1307, 1374, 1382, 1416, 1423, 1476, 1513(`owner=… session=…`);事件 id :2603, :2956;路径 EventStore.swift:1152;error 文本 EventStore.swift:205 ← :1455, :4589;HTTP 体只进 os_log(SupabaseSyncService.swift:377)。事件 UUID 对持 service_role 者可 join 到 `events.title`。
修正:发送页原样展示将发出的行;UUID 替换为报告内短哈希或明示「含事件 ID」;`user-report` 按 rawContent 处理(它就是原始内容)。改 §4.5、§5。

**F26** · E · P2 · 项目未引用 PrivacyInfo.xcprivacy;遥测新增「与用户身份关联的诊断/使用数据」须进 App Store Connect 隐私问卷。
证据:project.pbxproj 无引用、`Done/PrivacyInfo.xcprivacy` 不存在(仓库级搜索未能完成);build 5–11 已上传,说明今天至多是 ITMS-91053 警告。已在用的 required-reason API:UserDefaults(CA92.1)、文件修改时间(C617.1,MetricPayloadStore.swift:226)、systemUptime(35F9.1,Spike201EpochStamp)。
修正:补 manifest(上述三类 reason + NSPrivacyCollectedDataTypes: Performance Data / Crash Data / Product Interaction / Other Diagnostic Data,linked to user,not tracking);外测前填问卷。改 §5、§9。

## F. 用户体验

**F27** · F · **P0** · 没有激活方案:默认关 + 无提示 + 开关埋在二级页 ⇒ 预期开启数 ≈ 0 ⇒ 问题 1–5 无数据,底盘白做。
证据:开关拟放 Data & Privacy(AgentSettingsView.swift:684,入口 :436-445),内测者不会主动去;蓝图 §0–§9 无一字提到如何让人打开。
修正(不违反「存储默认 OFF」):(a) TestFlight 构建的设置首页顶部一次性可关卡片「帮助改进 Done:分享性能与使用统计(不含任何内容)→ 开启 / 以后再说」,每 install 只出一次;(b) TestFlight「测试内容」明文请求;(c) 定义成功判据:发包 7 天内 ≥2/N 台开启,否则下一片做激活而不是再加采集器。改 §0、§5。

**F28** · F · P1 · `verdictSnapshot` 只在打开观察站时写,而内测者不会打开 ⇒ 问题 1 无数据。
证据:§4.1;观察站是设置首页一行(AgentSettingsView.swift:400-420)但仍是开发者页面;评估器纯函数、两次 `loadRuns` + 算术(FixWatchView.swift:213-222),便宜。
修正:快照在跨天与启动上传时(off-main)各算一次/天/install;打开观察站只是额外快照。改 §4.1、§7。

**F29** · F · P1 · 无可见反馈 ⇒「传了没、传了什么」不可答 ⇒ 要么不信要么误以为在工作。
修正:开关下方「上次上传 3 分钟前 · 4 条 · 累计 212 条 · 构建 11」;「查看样本」弹出最近一次请求体(pretty JSON)— 这是对「是不是在传我的日程」唯一诚实的回答;「立即上传」按钮兼作验收项 9 的手动探针与 harness 正对照;开关 OFF→ON 立即尝试一次。改 §5。

**F30** · F · P2 · 文案:「分享诊断与使用统计」会被读成「分享我的使用」;且 ON 后两处现有文案成谎。
证据:`hintLocalData`「设置、洞察、模板和 AI 学习数据保存在本设备上。」(AppLocalization.swift:1328,显示于 AgentSettingsView.swift:455-461、:718-724);FixWatchView.swift:74「所有数据只写本机…导出仍是 devicectl」、:39。RLS 不允许 delete ⇒ 关掉开关不会删已传行,需说明。
修正:标题「分享性能与使用统计(不含内容)」,副文「仅上传计数与耗时:哪些功能用过几次、卡顿与同步失败次数、设备型号与系统版本。永不上传事件标题、备注、照片或任何文字。」note 开关「附带手动 Spike 备注(文字)」;上述两处按开关状态改写;加一句「已上传的统计随账号删除一并删除」。改 §5。

## G. 服务端与运维

**F31** · G · P1 · 「视图 = 具名消费方」不是消费方;没人跑的视图与没有视图等价 — 62.7M 规则换了说法而已。
修正:定时读取且产出 artifact:每周跑 `telemetry_checks.sql`(照 sync_feed_checks.sql),断言「近 7 天每个活跃 install ≥1 条 release 行」「无键全机死零」并把 PASS/FAIL 写回母票;设备侧观察站的「最近上传」行回读 `v_active_installs` 中本机那行(上传断了会可见地失败)。规则改成:观察系统「开」的条件是其视图有定时读者,不是视图存在。改 §1 L5、§3。

**F32** · G · P1 · RLS「只读自己的行」下,开发者读全表的路径只剩 service_role(#232 泄露同类)或管理 API。
修正:`telemetry_readers(uid)` 表 + SELECT 策略 `user_id = auth.uid() OR exists(select 1 from telemetry_readers r where r.uid = auth.uid())`;开发者用自己登录态(app 或带用户 JWT 的 MCP)读全表;agent 读走该 JWT,永不 service_role。改 §6。

**F33** · G · P2 · 若干表级决定悬而未决,每一个拖到视图写完都要返工。
(1) 表名:#197 拍的是 `spike_runs`,§6/§9 又漂到 `telemetry_runs` — 拍一次停。(2) `uploaded_at default now()` 在 merge-duplicates 下永不更新(只 SET 请求体里的列)⇒ 实际是「首次上传时间」;改名 `first_uploaded_at`,加 `last_uploaded_at` 两行 BEFORE UPDATE 触发器。(3) 索引:PK (user_id, run_id) + (user_id, kind, day_key) + (app_build, kind);量级 5 台 × ~20 行/天 = 100 行/天 = 3.6 万行/年,jsonb 全表扫毫秒级 — 不要加分区/保留机器。(4) 唯一含用户文字的列 `note` 90 天后置 null。(5) 所有视图 `where is_debug = false`(§6 一处都没写)。(6) 遥测表不进 015 触发器(F14)。改 §6、§9。

## H. 测试的牙(每条给能让「看起来绿」现形的变异体)

**F34** · H · P1 · 「开关关 = 零请求」在网关 seam 上测,对第二条 HTTP 路径失明。
变异体:上传器直接 `URLSession.shared.data(for:)` → 假网关计数为 0,测试绿。
修正:测试注册 `URLProtocol` 桩,开关关时任何到 Supabase host 的请求即 fail;正对照:开关开 → 恰 1 个请求。

**F35** · H · P1 · 「同记录重传两次服务端一行」对内存假服务器测,只证明假服务器会去重。
变异体:PK 只有 `(run_id)`;`on_conflict` 单列(F13)— 假服务器看不出。
修正:SQL 侧 checks(照 sync_feed_checks.sql:41-47 的 dblink as-user 模式):U 两次 upsert → 1 行;V 用同 run_id → 2 行;U 读/改不到 V 的行;U 删不了自己的行。

**F36** · H · P1 · 「游标只在 2xx 后前进」缺三个负例与一次「重启」。
变异体:请求前先推进游标 — 只查成功后状态的测试照样绿;F9 的非规范哈希 — 单进程测试永远复现不出种子变化。
修正:假服务器分别返回 500 / 抛 URLError / 2xx 但 0 行(F13)→ 游标不动;落盘游标后新建上传器 → 零请求;显式测试:同一记录由两个插入顺序不同的字典编码 → 哈希相等。

**F37** · H · P1 · 「note 未 opt-in 不出现」用键检查(`body["note"] == nil`)会被 `abortReason`/`.string` metric 里的文字绕过(F24)。
修正:夹具在 `note`、`abortReason`、一个 `.string` metric 各放一个 UUID 哨兵;断言 opt-out 时所有外发请求体的字节不含任一哨兵;正对照:opt-in 后只有 `note` 哨兵出现,另两个永不出现。

**F38** · H · P2 · 「Debug→生产被挡」:现有闸门已是注入 `environment` 的纯属性且有矩阵测试(SupabaseSyncService.swift:956-958);XCTest 下 `debugBlocksUploads` 恒 true,Release 臂靠 `false && _` 成立。真正的陷阱是遥测上传器自建第二个 `#if DEBUG` 闸门。
修正:上传器只问 `uploadsBlockedByBuild`;源扫描断言遥测文件里没有第二个 `#if DEBUG` 闸门。

**F39** · H · P2 · 「擦除后游标文件不存在」变异体:注册表有条目、擦除函数不调它。
修正:测试调真实入口 `LocalDataEraser.resetAllLocalData`(AgentSettingsView.swift:1003)后 stat 文件;并断言 installID 已变且擦除后首个请求体带新 id。F12 的目录结构让它免登记成立。

**F40** · H · P2 · 「计数键只能来自编译期清单(源扫描)」:正则扫 `.counter("` 被注释满足、被 `let k = …; emit(.counter(k))` 绕过。
修正:F1 的类型化枚举使扫描多余;保留一条运行时测试:发未知 id → 一切不动且新增的 `unknownKeyDrops` == 1。

**F41** · H · P2 · 「判定快照与卡片逐项一致」= 同函数同输入,套套逻辑(测自己算的值);「两台 TF 机 SQL 能读到」会被 Debug 开发机的行满足。
修正:手算夹具(dailies/windows 字面量 → 期望快照字面量);SQL 侧插该快照行,断言 `v_fixwatch_verdicts_by_install` 解出同一状态枚举;装机验收断言 `is_debug=false AND app_build=<TF build> AND count(distinct install_id)=2`。

---

## 若只能改五处(按影响排序)

1. **F9 规范化哈希 + 稳定游标**(P0)。不改则每次启动全量重传、预算 ×800、全程 2xx、全部验收绿 — 62.7M 的精确复刻。顺带 F36 的四个负例。改 §1 L3、§8。
2. **F27 + F28 + F29 激活与可见性**(P0/P1)。没有人开开关、快照没人触发、开了也看不见 ⇒ 六个问题全部无数据。一次性卡片 + TF 说明 + 「上次上传/查看样本/立即上传」+ 快照改在跨天/启动算。改 §0、§4.1、§5。
3. **F15 + F16 + F17 记录身份戳**(P1)。认领键 (config, build, os, owner),不匹配铸新 run id;dayKey/tz 取自日界而非 flush 时刻;上传只发 owner==当前 uid。否则升级日、换账号日、旅行日的数据都是错的,而这些正是问题 3/4 要看的日子。改 §2、§4.1、§5。
4. **F5 + F6 + F10 + F11 上传与落盘策略**(P1)。daily 只在跨天/启动传,边沿只传事件记录,脏检查免写,启动补传 off-main 延后,边沿上传要么包 assertion 要么删。否则 85 KB/天 vs 64 KB 预算、请求翻倍、冷启动多 60–120 ms。改 §1 L2/L3、§7。
5. **F1 + F21 + F24 + F37 类型化键与值 + 字节级 note 测试**(P1)。枚举下标计数器消灭四处手工登记(死线之源),`abortReason` 枚举、每键值 schema,哨兵字节扫描。否则「键来自清单」只约束了三分之一的文本出口。改 §2、§3、§8。

未进前五但不能不做:F14(复用 `send` + 遥测表排除 015 触发器)、F31(视图要有定时读者)、F32(开发者读全表不走 service_role)。
