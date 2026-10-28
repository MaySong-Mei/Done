> **历史文件**:2026-10-24 对抗前的 v0 蓝图,已被 `../00-telemetry-chassis-design.md` 取代;保留只为对照 `A-facts.md` / `B-attack.md` / `C-alternative.md` 三份报告指向的行号。其中的决定不再有效。

# 遥测底盘(Telemetry Chassis)v0 蓝图 — 供对抗用

日期:2026-10-24。仓库:Done(iOS,SwiftUI,本地优先,Supabase 同步)。分支 king-of-rubbish-bin @ fd92618。

## 0. 目标与非目标

目标:一条上传通道、一种记录形状、一张服务端表,让 N 个「观察系统」插上去;读数只靠 SQL。首批要回答六个问题:
1. 已合入的性能修复(#201/#213/#214)在现场达标没有(观察站判定)。
2. 哪些功能 30 天没人用。
3. 同步/存储/恢复在现场多久失败一次;新构建有没有让某类错误变多。
4. 卡顿/hitch/峰值内存按构建的趋势。
5. 多少活跃设备、各在什么构建。
6. (后续)用户主动报告的问题及其现场。

现实约束:TestFlight 签名的容器 `devicectl device copy from` 拉不出来(#235),观察站数据现在只能一台台打开设置页看。

非目标(本期):agent 自动分流/修复;第三方分析 SDK;`BGTaskScheduler`/后台模式;上传原始日志或 MetricKit 原始 JSON;上传任何事件标题/备注/照片;服务端重算判定。

已拍板、不重议(#197 2026-08-26):`spike_runs` 表 + 关闭即尽力上传 + 启动补传 + **默认关的独立开关**;指标默认可传、**原始内容显式 opt-in**;schema 与用户数据分离;agent 侧直接 SQL 读。

## 1. 分层

- **L0 信号(emit)**:热路径(SwiftUI body pass、120Hz 手势闭包)上的 O(1) 固定键 bump。禁止:字符串分配、UserDefaults、Calendar、落盘、网络、publish。现成:`ResidentTierOneCore` 固定键计数 + 32 条手势环;`SpikeProbe.emit` 无监听者时一次 optional-closure nil-check。
- **L1 聚合(tier)**:每日汇总(counter / histogram 固定桶 / gauge-last / min / max);事件记录(自动窗口、手动 spike run、判定快照、用户报告)。
- **L2 落盘**:`SpikeRunStore` 同池同上限同压实(Documents/spike-runs/<spikeID>.jsonl;写前 OPEN + CLOSE 同 id 折叠;200 run/spike + 256KB 字节兜底)。
- **L3 上传**:游标文件(记录 id → 上次成功上传的内容哈希);触发 = 观察站已有的落盘边沿(退后台 / 启动 / 打开观察站 / 跨天);退后台尽力发一次不等结果;启动按游标补传;只在 2xx 后前进。
- **L4 服务端**:一张表 + RLS + 视图 + checks.sql(照 `done-mcp/supabase/tests/sync_feed_checks.sql`)。
- **L5 读侧**:SQL 视图 = 具名消费方;未来 agent 只读 L5。

## 2. 记录模型(把 SpikeRun 推广成通用记录)

现有 `SpikeRun` 字段:id、spikeID、scenarioID、variantID?、startedAt/endedAt、appVersion/appBuild/appCommit?、deviceModel、osVersion、timeZoneIdentifier、localeIdentifier、metrics: [String: Double]、note?、outcome、abortReason?、coActiveSpikeIDs。

新增:`installID`(本机随机 UUID,擦除轮换)、`dayKey`(本地日期 yyyy-MM-dd)、`kind` 枚举(dailyRollup / window / manualRun / verdictSnapshot / metricKitDaily / userReport)、`isDebugBuild`。

不变量:metrics 的键只能来自编译期清单;未知键 seed 时丢弃;自由字符串只能出现在 `note`(单独 opt-in)。

## 3. 观察系统的插接契约(Registry entry)

每个观察系统 = 一条编译期注册表项:
- `id`、`tier`(daily / event)、`keys`(编译期字符串常量集合)、每键的 `aggregation`(count / histogram(buckets) / last / min / max)
- `privacyClass`:metric(默认可传)/ enumContext(枚举字段)/ rawContent(仅 note,单独 opt-in)
- `costContract`:每信号 O(1);每日最多 N 条事件记录(观察站现 12 窗口/天)
- `consumerView`:必须命名一条 SQL 视图,否则不许开(62.7M 事故的「无消费方不开」规则)
- `acceptance?`:修复验收方向(键、方向、阈值),给观察站式判定用
- 规则:键只增不改义(改义 = 新键);退役不删条目(R-F11);判定在设备上算,服务端只读快照。

## 4. 首批观察系统

1. 观察站(已存在):resident-daily + auto-window 原样上传;新增 `verdictSnapshot` 记录:打开观察站算判定那一刻写一条,每个修复条目一个枚举值。
2. 功能使用 `usage-daily`:编译期功能 ID 清单(≈23 项起步),每天每 ID 一个整数。
3. 错误计数 `incident-daily`:接到现有 86 处 `DiagnosticTrail` 写入点(同步 22+17+11、EventStore 10、恢复 6 …)和失败枚举(`SyncWriteFailureKind` 等)上,每处一个编译期事件 ID;首批只接同步 + 存储两域。
4. MetricKit 日摘要 `metrickit-daily`:`scrollHitchTimeRatio`、hang 次数、峰值内存、diskWriteException 次数,现有 `AppMetricsReporter` 回调里多写一条记录。
5. (最后一片)用户报告 `user-report`:自动抓现场(开着的开关、最近几十行轨迹、构建/设备)+ 可选文字;发送动作即同意。

## 5. 身份与同意

- 行键 = `user_id`(auth.uid)+ `install_id`。不用 identifierForVendor。签出状态不上传,数据留本地等下次登录。
- 开关「分享诊断与使用统计」默认关,放 Data & Privacy;复用同步的「Debug 包禁止往生产传」闸门。开关存在后,设置页「数据都保存在本机」文案改成实话。
- `note` 单独开关,默认关。
- 账号删除:`user_id` 外键级联删行。本地擦除:换 install_id、清游标;服务端旧行留着但再接不上。

## 6. 服务端

`telemetry_runs`(或拍板名 `spike_runs`):user_id、install_id、run_id、kind、spike_id、scenario_id、day_key、tz、app_build、app_version、app_commit、device_model、os_version、locale、is_debug、metrics jsonb、context jsonb、note text null、outcome、client_updated_at、uploaded_at default now()。主键 (user_id, run_id);upsert 覆盖 = 最新一条胜。RLS:insert/update/select 自己的行,不 delete。不进 sync_changes、不进 snapshots。保留:先不做定时删。

视图:v_usage_30d、v_fixwatch_verdicts_by_install、v_incidents_by_build、v_metrickit_daily、v_active_installs。

## 7. 预算(待对抗用算术顶回来)

- 热路径:每信号 ≤ 1 次 Date 读 + 1 次 Double 比较 + 1 次数组下标 += 1。
- 每日记录数/设备:dailyRollup ≤ 4 条(resident/usage/incident/metrickit)+ window ≤ 12 + verdictSnapshot ≤ N 次打开 + manualRun 任意。
- 每日上传:≤ 20 请求、≤ 64KB。
- 本地池:沿用 200 run/spike + 256KB/文件。
- 数据质量:censoring 标记(删失)沿用观察站;Debug 行打标并被闸门挡在生产外;dayKey 本地日期 + tz;键按 app_build 可区分版本。

## 8. 验收(牙)

开关关 = 零请求;同记录重传两次服务端一行;游标只在 2xx 后前进(变异必红);Debug→生产被挡;note 未 opt-in 不出现在任何请求体(正对照:opt-in 后出现);擦除后游标文件不存在(进 #266 注册表);计数键只能来自编译期清单(源扫描);判定快照与设备观察站卡片逐项一致;装机两台 TestFlight 机 SQL 能读到。

## 9. 未决点

note 去向(第二开关 vs 永不传)/ 错误计数首批域 / 用户报告是否本期 / 表放 public 前缀还是独立 schema / 服务端保留。
