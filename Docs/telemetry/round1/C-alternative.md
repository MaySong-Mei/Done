# C 方案:独立设计的遥测底盘,与 v0 蓝图逐项对比

日期 2026-10-24。king-of-rubbish-bin @ fd92618,只读。顺序:先读代码(ResidentObservationCenter/Model、SpikeRunStore、SpikeModel、DoneApp MetricKit、DiagnosticTrail、SyncWriteFailure、LocalDataEraseEpoch、SyncGateway)+ 调研 → 写定设计 → 才读 v0 蓝图做第 3、4 节。第 1 节没有按蓝图改过一个字。

## 1. 独立设计

### 1.1 分层(四层,不多)

| 层 | 内容 | 一句理由 |
|---|---|---|
| L0 发射 | `Telemetry.bump(.key)` / `observe(.key, ms:)` / `gauge(.key, v)`;键是 `enum TelemetryKey: UInt16`,原始值直接当数组下标 | 热路径只允许「一次下标 + 一次加」。Fix Watch 的具名字段结构体对 20 个键够,对 ~100 个功能键会变成 300 行手写 metrics/init 对拍,enum 数组同样是编译期闭合,但按键数线性可扩 |
| L1 日切片 | 每 (install, 本地日, build, config) **一条**记录,内存中累加,只在 Fix Watch 已有的生命周期边沿落盘;跨天即封板 | 六个问题里五个的最细粒度都是「设备-日」;逐事件记录会把分配、字符串、payload 和隐私面一起放大 |
| L2 出站箱 | Application Support/Telemetry/outbox.jsonl,**排除备份**,同 id 最新胜,≤14 天 ≤64KB | 遥测不该占用户 iCloud 备份配额;Fix Watch 放 Documents 是为 devicectl 拉,TestFlight 容器拉不出来,这个理由对上传链不成立 |
| L3 上传 | 前台触发、同步成功后搭车、退后台包 `beginBackgroundTask`;服务端 RPC 幂等 upsert,带 `flush_seq` 单调守卫 | 「关闭即尽力发」若不包后台任务,进程在 didEnterBackground 返回后极快挂起,请求是挂着而不是完成 |
| L4 服务端 | 独立 `telemetry` schema(不在 Exposed schemas),无 policy 的 RLS 表 + security definer RPC + 键注册表 + 视图 | 用户永远不需要读自己的遥测;读侧只有开发者的 SQL,就不该让 API 角色摸到表 |

### 1.2 记录模型(day-slice)

```jsonc
{ "slice_id": "uuid5(install_id, day, build, config)",   // 同日重启同 id → 本地与服务端都「最新胜」
  "install_id": "随机 UUID,Application Support 不备份,擦除时轮换",
  "day": "2026-10-24", "tz_offset_min": -420,
  "build": 11, "version": "0.5.0", "config": "release", "os": "26.0.1", "model": "iPhone17,2",
  "cohort": "testflight",                                  // sandboxReceipt 判
  "schema_ver": 1, "flush_seq": 7, "complete": false,      // complete = 跨天后的终版
  "consent_at": "2026-10-20T03:11:00Z",                    // 早于此刻的数据不存在于任何切片
  "counters":  { "app.foreground": 5, "sync.write.ok": 212, "sync.write.fail.retryable": 3, "feature.widget.gauge.shown": 2 },
  "hists":     { "fw.commit_ms": { "b": [0,3,9,6,1,0,0,0,0,0,0,0,0], "n": 19, "sum": 611.2, "max": 88.4 } },
  "gauges":    { "mk.hitch_ratio": { "last": 2.1, "max": 2.1, "n": 1 }, "store.events": { "last": 1832, "max": 1832, "n": 4 } },
  "exemplars": { "fw.commit_ms": [88.4, 61.0, 57.3] } }   // 每直方图 top-3 原值,无属性
```

不变量(类型级,不靠注释):metrics 三个字典的值**只能是数或数组**,维度字段只能是上面七个枚举/版本串;`note` 这类自由文本在这条记录里**没有字段**。计数在切片内是**累计**(OTel cumulative),所以重传同一切片不会重复计数——这是去重论证的全部。

### 1.3 注册表契约

```swift
enum TelemetryKey: UInt16, CaseIterable {
    case appForeground, appUncleanExit, appLaunchResidentInitMs,
         syncWriteOk, syncWriteFailRetryable, syncWriteFailRejected, /* …SyncWriteFailureKind 八种各一 */
         syncPullOk, syncPullFail, syncRestoreStarted, syncRestoreOk, syncRestoreFail,
         storageCommitOk, storageCommitFail, storageDecodeFail, eraseStarted, eraseOk,
         fwCommitMs, fwTapLagMs, fwSettleMs, fwMeComputedHidden, fwMeComputedVisible,
         mkHitchRatio, mkPeakMemMb, mkHang, mkCrash, mkCpuException, mkDiskWriteException,
         featureWidgetGaugeShown, /* …feature.* ≈ 40 */
         telemetryOutboxDropped, telemetryUploadRejected, telemetryOptOut
    var name: String          // "sync.write.fail.retryable":点分小写;测试断言唯一
    var kind: Kind            // .counter | .histogram(.latencyMs | .lagMs) | .gauge
    var family: Family        // lifecycle / sync / storage / fixwatch / metrickit / feature / self
    var sinceBuild: UInt16    // 引入构建
    var retiredBuild: UInt16? // 退役 = 填这个,永不删 case、永不改义(改义 = 新 case)
    var livenessKey: TelemetryKey?  // tripwire 必须配 liveness(Fix Watch 的 0/0 规则)
}
```

契约测试(牙):① 名字唯一且合规;② 每个 case 在 `Done/` 非测试源码里至少被引用一次(死键红);③ `CaseIterable` 导出 `supabase/telemetry/key_registry.json`,与迁移里的 `telemetry.key_registry` 表逐行对拍(服务端注册表由 Swift 生成,不手抄);④ 任何 `.invariant` 键无 `livenessKey` 红;⑤ `sinceBuild ≤ 当前 CFBundleVersion`。

### 1.4 聚合类型(三种 + 一个约定)

- **counter**:Int64,切片内单调累计;`&+=`。
- **histogram**:固定桶,桶边按 kind 编译期给定:`.latencyMs` = [4,8,17,33,50,100,250,500,1000,2000,5000,+∞] + missing(13 桶);`.lagMs` = Fix Watch 现有 [10,20,40,80,120,320] + 溢出 + missing,保证设备侧 p50≤40/p95≤120 判据照旧是精确桶算术。附 n/sum/max + top-3 exemplar(无属性,纯数)。
- **gauge**:last/max/n。用于 MetricKit 日值、store 规模(作为性能的协变量)。
- **witness pair**(约定非类型):tripwire 键必配 liveness 键,SQL 读 `0/0` 为 INSUFFICIENT。

不做:逐事件信号、带属性的 exemplar、exponential histogram(桶边固定、阈值已知,显式桶更便宜且 SQL 可直接 sum 数组)。

### 1.5 上传机制

- 触发(三处,全在前台或后台边沿):(a) `didBecomeActive` 后 `Task.sleep(2s)`——**从不在首帧前**;(b) 同步 flush 成功回调后——射频已醒,不新增唤醒;(c) `willResignActive` 里包一次 `beginBackgroundTask`(本 app 已有一处同类用法,见 LocalDataEraseEpoch.swift 头注释 L60-62),2.5KB POST 在 Quinn 说的约 30s 内绝对够。
- 选取:outbox 里 `flush_seq > uploaded_seq` 的切片 ≤32 条;**今日**切片距上次上传 ≥15 分钟才带。
- 传输:`URLSession.shared` data task → `POST /rest/v1/rpc/telemetry_ingest`,带用户 JWT;协议 `TelemetryGateway { func ingest(_:) async throws -> IngestReceipt }`,独立于 `SyncGateway`(不带 `X-Sync-Epoch`,不参与 epoch 闸),测试用假服务器。
- 结果:`accepted/stale` → `uploaded_seq = flush_seq`;`rejected` → attempts+1,≥3 丢弃并 `bump(.telemetryUploadRejected)`(自报)。失败分类**复用** `SyncWriteFailure.classify`。
- 擦除:`await` 前 `LocalDataEraseEpoch.capture()`,回来 `isStale` 则不写回 `uploaded_seq`;outbox、install_id、今日切片进 #266 擦除注册表。
- 不用 background `URLSessionConfiguration`:会被 OS 重新拉起进程 → LocalDataEraseEpoch 头注释明说那时 epoch 必须持久化;也违反「不加后台模式」。

### 1.6 身份与同意

- 身份 = `install_id`(随机、不备份、擦除轮换)。**行里没有 user_id**;RPC 只用 `auth.uid() is not null` 拒匿名,不落库。
- 开关 `telemetry.enabled` 默认关,放 Data & Privacy。关 = 累加器**不落盘不上传**(内存里跑是为了预览)。开 → 记 `consent_at`,切片从此刻起算;Fix Watch 已有的历史日记录**不**上传(它们在同意前采的)。
- 预览页:展示「上一次实际发出的切片」原文 + 下一次将发的内容,透明度换开启率。
- 关掉:发**最后一次**当前切片附 `telemetry.optout=1`,然后清空本地遥测(决策点:也可改为立即停、不发)。
- `rawContentOptIn`(⑥ 用)另一开关、默认关,且每次提交用户看见内容并主动点发——这正好对上 Apple「可选披露」的四条件。

### 1.7 服务端 schema 与视图

```sql
create schema telemetry;                               -- 不加入 API Exposed schemas
create table telemetry.day_slice (
  slice_id uuid primary key, install_id uuid not null,
  day date not null, tz_offset_min smallint not null,
  build int not null, version text not null,
  config text not null check (config in ('debug','release')),
  os text not null, model text not null,
  cohort text not null check (cohort in ('testflight','appstore','dev')),
  schema_ver smallint not null, flush_seq int not null, complete boolean not null,
  consent_at timestamptz not null,
  counters jsonb not null default '{}', hists jsonb not null default '{}',
  gauges jsonb not null default '{}', exemplars jsonb not null default '{}',
  client_sent_at timestamptz not null, received_at timestamptz not null default now(),
  unique (install_id, day, build, config));
create index on telemetry.day_slice (day, build);
create index on telemetry.day_slice (install_id, day);
alter table telemetry.day_slice enable row level security;   -- 零 policy:anon/authenticated 读写皆不可
create table telemetry.key_registry (key text primary key, kind text not null, family text not null,
  since_build int not null, retired_build int, liveness_key text, description text);
create table telemetry.ingest_quota (install_id uuid, day date, n int not null, primary key (install_id, day));

create function public.telemetry_ingest(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r jsonb; accepted uuid[] := '{}'; stale uuid[] := '{}'; rejected jsonb := '[]';
begin
  if auth.uid() is null then raise exception 'anon' using errcode = '42501'; end if;
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) > 32 then raise exception 'shape' using errcode = '22023'; end if;
  for r in select * from jsonb_array_elements(p) loop
    if pg_column_size(r) > 16384
       or (r->>'day')::date not between current_date - 21 and current_date + 1
       or jsonb_typeof(r->'counters') <> 'object' then
      rejected := rejected || jsonb_build_object('id', r->>'slice_id', 'reason', 'bounds'); continue;
    end if;
    insert into telemetry.ingest_quota values ((r->>'install_id')::uuid, current_date, 1)
      on conflict (install_id, day) do update set n = telemetry.ingest_quota.n + 1;
    if (select n from telemetry.ingest_quota where install_id = (r->>'install_id')::uuid and day = current_date) > 96 then
      rejected := rejected || jsonb_build_object('id', r->>'slice_id', 'reason', 'quota'); continue;
    end if;
    insert into telemetry.day_slice
      select * from jsonb_populate_record(null::telemetry.day_slice, r || jsonb_build_object('received_at', now()))
    on conflict (slice_id) do update set
      flush_seq = excluded.flush_seq, complete = excluded.complete, counters = excluded.counters,
      hists = excluded.hists, gauges = excluded.gauges, exemplars = excluded.exemplars,
      client_sent_at = excluded.client_sent_at, received_at = now()
    where excluded.flush_seq > telemetry.day_slice.flush_seq;        -- 旧重传拒之:FOUND = false
    if found then accepted := accepted || (r->>'slice_id')::uuid; else stale := stale || (r->>'slice_id')::uuid; end if;
  end loop;
  return jsonb_build_object('accepted', to_jsonb(accepted), 'stale', to_jsonb(stale), 'rejected', rejected);
end $$;
revoke all on function public.telemetry_ingest(jsonb) from public;
grant execute on function public.telemetry_ingest(jsonb) to authenticated;
-- telemetry_forget(install_id uuid):擦除时客户端先调一次(尽力),再轮换 id。
```

视图(读侧 = 具名消费方;「0 vs 无上报」在这里判):

```sql
-- 长表:键在该构建里「应出现」才把缺失读成 0,否则 NULL
create view telemetry.counter_long as
select s.slice_id, s.install_id, s.day, s.build, s.config, s.cohort, r.key, r.family,
       case when s.build >= r.since_build and (r.retired_build is null or s.build < r.retired_build)
            then coalesce((s.counters->>r.key)::bigint, 0) end as value
from telemetry.day_slice s cross join telemetry.key_registry r where r.kind = 'counter';

-- Q⑤ 活跃设备与构建分布
create view telemetry.v_active_installs as
select day, build, cohort, count(distinct install_id) installs
from telemetry.counter_long where key = 'app.foreground' and value > 0 group by 1, 2, 3;

-- Q② 30 天无人用;expected_slices = 0 读作「没有任何上报构建含此键」而非「没人用」
create view telemetry.v_feature_unused_30d as
select key, count(*) filter (where value is not null) expected_slices,
       count(distinct install_id) filter (where value > 0) installs_used
from telemetry.counter_long
where family = 'feature' and config = 'release' and day >= current_date - 30
group by key having count(distinct install_id) filter (where value > 0) = 0;

-- Q③ 同步写失败率按构建
create view telemetry.v_sync_failure_by_build as
with x as (select build, day, install_id,
                  sum(value) filter (where key = 'sync.write.ok') ok,
                  sum(value) filter (where key like 'sync.write.fail.%') fail
           from telemetry.counter_long where config = 'release' group by 1, 2, 3)
select build, count(*) install_days, sum(ok) ok, sum(fail) fail,
       round(sum(fail)::numeric / nullif(sum(ok) + sum(fail), 0), 4) fail_rate
from x group by build order by build;

-- Q④ MetricKit 按构建(切片的 build 取 payload 的 applicationBuildVersion,不取当前进程)
create view telemetry.v_metrickit_by_build as
select build, count(*) install_days,
       percentile_cont(0.5) within group (order by (gauges->'mk.hitch_ratio'->>'last')::float) hitch_p50,
       percentile_cont(0.9) within group (order by (gauges->'mk.hitch_ratio'->>'last')::float) hitch_p90,
       percentile_cont(0.9) within group (order by (gauges->'mk.peak_mem_mb'->>'max')::float) peak_mem_p90,
       sum((counters->>'mk.hang')::int) hangs, sum((counters->>'mk.crash')::int) crashes
from telemetry.day_slice where config = 'release' and gauges ? 'mk.hitch_ratio' group by build;

-- Q① 全体设备合并直方图(桶按位相加;判据=累计份额 ≤ 桶边,与设备侧同式)
create view telemetry.v_fixwatch_pooled_buckets as
select s.build, h.key, i.idx, sum(i.v::bigint) cnt
from telemetry.day_slice s, jsonb_each(s.hists) h,
     jsonb_array_elements_text(h.value->'b') with ordinality i(v, idx)
where s.config = 'release' and h.key in ('fw.commit_ms', 'fw.tap_lag_ms', 'fw.settle_ms')
group by 1, 2, 3;
```

Q⑥ 本期不建表;届时 `telemetry.report`(install_id, build, 切片快照 jsonb, 用户文本 text, 用户自填联系方式 text)走同一 RPC 族。

### 1.8 预算(算术)

- **热路径**:counter = 1 次边界检查下标 + 1 次加 ≈ 5-10ns;histogram = 对 ≤12 条桶边线性/二分 ≤4 次比较 + 1 次加 ≈ 20-30ns。120Hz 帧预算 8.3ms → 余量 ≥ 10⁵×。日切片累加器驻留内存:128 键 × 8B + 12 直方图 × 14 × 8B + 8 gauge × 24B ≈ 1.0 + 1.3 + 0.2 ≈ **2.5KB**。
- **落盘**:只在 Fix Watch 已有边沿(resign/background/terminate/跨天/开 deck),同日同 id 追加:≈20 次/天 × 2.5KB = 50KB 追加 → 64KB 上限每天最多压实 1 次(读 ≤14 条、重写 ≤35KB)。排除备份 → iCloud 配额 0。
- **流量**:单切片编码典型 2-3KB,最坏(全键非零、全桶非零)≤ 8KB(测试钉)。每天 ≤ 前台会话数次上传,今日切片 15 分钟节流:典型 5 次 × 2.5KB ≈ **12KB/天/设备**,最坏 20 次 × 8KB = 160KB。月 0.4-5MB/设备;10 台 ≤ 50MB/月。
- **电量**:零新增射频唤醒——(a)(b) 在前台、同步刚用完连接;(c) 在同步自己也在跑的后台边沿里。每次 POST 连接复用,CPU 毫秒级。
- **冷启动**:首帧前 0 工作;驻留初始化只读今日切片一个 ≤4KB 文件(Fix Watch 现在是 loadRuns 全文件解码,≤128KB)。自测:`app.launch.resident_init_ms` gauge,目标 p90 < 5ms。
- **服务端**:1 行/设备-日-构建 → 10 台 × 365 ≈ 3.7k 行/年 × ~3KB ≈ 11MB/年;视图扫全表 < 100ms 无需 GIN;`(day, build)` B-tree 即够。RPC 限 32 切片/次、16KB/切片、96 次/设备/日 → 单设备日上限 1.5MB,滥用面有界。
- **上传可靠性**:前台触发意味着「昨天」最晚在下一次前台到齐;丢失只在(i)设备永不再前台(卸载)——损失 ≤ 最后一个未封板日;(ii)离线 >14 天——最旧切片被丢且有 `telemetry.outbox.dropped` 自报。

### 1.9 验收(可证伪,每条有正对照或变异)

1. 热路径:Release 配置 XCTest `measure` 1M 次 bump ≤ 20ms;源扫描 `Telemetry*.swift` 无 `UserDefaults/Calendar/FileManager/URLSession/@Published/objectWillChange`(同 Fix Watch 现有扫描)。
2. 幂等与时序(假服务器实现 §1.7 语义):同 `flush_seq` 重传 3 次 → 1 行值不变;先传 seq=7 后传 seq=5 → `stale`,行仍是 7。**变异**:去掉 `where excluded.flush_seq >` → 红。
3. 删失:进程在 flush 后 bump 再被杀(标记文件法)→ 下次启动 `app.unclean_exit = 1`,flush 前的计数在、flush 后的不在(测试**断言这段丢失**,不是假装没丢)。
4. 0 vs NULL:fixture 两个构建,键 K `since_build = N`;视图对 build N-1 行给 NULL、对 build N 缺 K 的行给 0。变异:去掉 since_build 判断 → 红。
5. 同意范围:开关关经 3 个生命周期循环 → Telemetry 目录不存在、假网关零调用;开关开于 t → 首个上传切片 `consent_at ≥ t`,且 outbox 中不存在 day < t 的切片(正对照:开着时存在)。
6. 体积:最坏切片 ≤ 8KB;典型 fixture ≤ 3KB。
7. 类型级隐私:遍历最坏切片 JSON,除七个维度字段外所有叶值为 number 或 number 数组 → 任何 String 叶值红。
8. 注册表对拍:Swift `CaseIterable` 导出 == 迁移里的 `key_registry` 行;死键红;tripwire 无 liveness 红。
9. 装机:两台 TestFlight 机开关开 3 天 → `v_active_installs` 每日 = 2;第 2 天起 `v_metrickit_by_build` 有行(MetricKit 首次日投递后)。

## 2. 调研摘要

### 2.1 Apple 已免费给、不必自建

- **MetricKit**:指标 payload「每个来源每天至多一次」(不同来源可能分多条到达),诊断 payload iOS 15+/macOS 12+ 立即投递;仅真机。本 app 已订阅并落盘(DoneApp.swift L496-549)。→ hitch/峰值内存/hang/崩溃**计数**从这里桥接即可,不自建帧探针做 hitch。来源:https://developer.apple.com/documentation/metrickit/mxmetricmanager 、https://developer.apple.com/documentation/metrickit/mxmetricmanagersubscriber/didreceive(_:)-9yd4u
- **Xcode Organizer**:七类指标(电池、启动、hang、内存、磁盘写、滚动 hitch、终止)「无需改 app」;hang 定义 ≥250ms 无响应;TestFlight 崩溃可在 Organizer 分诊(WWDC21「Triage TestFlight crashes in Xcode Organizer」)。来源:https://developer.apple.com/videos/play/wwdc2021/10181/ 、https://developer.apple.com/wwdc21/10087 。**未核到原文**的经验:Organizer 指标只来自同意分享分析的用户且有样本量门槛,十来人的 TF 群常显示数据不足——所以 hitch/内存按构建仍要自己存**数值**,但**崩溃/hang 堆栈不传**,Organizer/TestFlight 已给符号化堆栈。
- **TestFlight(App Store Connect)**:每构建安装数/会话数/崩溃数、测试员截图反馈,零代码。→ Q⑤ 的分母(开启率 = 上报 install / TF 安装)和 Q⑥ 的 v0。来源:https://developer.apple.com/testflight/
- **隐私标签**(原文):Product Interaction =「app launches, taps, clicks, scrolling information…」;Performance Data =「launch time, hang rate, or energy use」;Crash Data =「crash logs」;Other Diagnostic Data =「any other data collected for the purposes of measuring technical diagnostics」。「可选披露」须**同时**满足四条(不用于追踪、不用于广告营销、仅偶发且非主功能且用户可选、**用户在界面里提供、看见提交内容并每次主动选择**);「data collected on an ongoing basis after an initial request for permission must be disclosed」。「Linked to user」:默认视为关联,除非采集前去除直接标识且事后不尝试回联、不与可回联数据集拼接。来源:https://developer.apple.com/support/app-privacy-on-the-app-store/ 。→ 持续性的日切片**必须披露**(Performance + Product Interaction + Other Diagnostic);去掉 user_id 列是走向「not linked」的必要条件,但 API 日志里 JWT sub 与请求体并存,保留期内可回联,标签仍应按 linked 填。
- **Required reasons API**:五类 FileTimestamp / SystemBootTime / DiskSpace / ActiveKeyboards / UserDefaults;UserDefaults 用 CA92.1(仅本 app 访问);SystemBootTime 覆盖 `systemUptime`/`mach_absolute_time`(理由码 35F9.1「app 内事件间隔」为记忆,需对原文核)。来源:https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api 、https://developer.apple.com/forums/thread/750057 、https://bugfender.com/blog/apple-privacy-requirements/ 。→ 本设计不新增这些 API 的调用(计时沿用 `CACurrentMediaTime`,文件尺寸沿用 `attributesOfItem[.size]`)。仓库里未找到 `Done/PrivacyInfo.xcprivacy`(见 §5),这是一个独立于遥测的待办。

### 2.2 iOS 后台网络事实

- `beginBackgroundTask`:有限时长,`backgroundTimeRemaining` 可查,不 `end` 会被杀;Apple 工程师 Quinn「IIRC 约 30 秒」。来源:https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:) 、https://developer.apple.com/forums/thread/741432 。→ 2.5KB POST 绰绰有余;超时只是留在 outbox 下次前台再传,不丢。
- Background `URLSession`:交给系统守护进程,无预定时限,完成后**重新拉起 app**;必须 file-based、delegate-only。本仓库 LocalDataEraseEpoch.swift L53-65 明确:一旦引入,擦除 epoch 必须持久化。→ 不采用(也在「不加后台模式」约束内)。
- 冷启动:WWDC19 423「Optimizing App Launch」给 400ms 首帧目标(记忆,未在本次抓到原文),一致的通用指引是把网络与重初始化移出启动路径。来源:https://developer.apple.com/videos/play/wwdc2019/423/ 、https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time 。→ 上传只在 didBecomeActive + 2s 之后。

### 2.3 业界形状:可借 / 不可借

- **TelemetryDeck**:标识符设备端加盐哈希、服务端再加盐再哈希(单次哈希在 GDPR 下只是假名化);不给标识符就生成随机;payload 是扁平原始值字典(Elixir 客户端拒绝嵌套)。来源:https://telemetrydeck.com/docs/articles/anonymization-how-it-works/ 、https://telemetrydeck.com/docs/glossary/ 、https://hexdocs.pm/telemetry_deck/readme.md 。可借:随机标识 + 扁平数值 payload。不可借:逐信号模型(每次交互一条网络记录)对 120Hz 热路径与隐私面都太重。
- **OpenTelemetry metrics**:Sum 的 delta vs cumulative——cumulative「采集间歇失败时缺口自然被平均」但发送端要持状态,delta「可采样、把基数成本移出进程」;重启靠 `StartTimeUnixNano` 标;Gauge「无聚合语义」;Histogram 桶上界含、下界不含,带 count/sum/min/max;Exemplar =「已计入聚合的一个原值 + 过滤后属性」;**单写者原则**:每条流一个逻辑写者,接收端应去重重叠。来源:https://opentelemetry.io/docs/specs/otel/metrics/data-model/ 。可借:切片内 cumulative(重传幂等)、显式桶、单写者 = 一个 MainActor 累加器、无属性 exemplar。不可借:OTLP 协议/SDK 本体(第三方 SDK 禁用,且为 N 个键引入导出管线不值)。
- **PostHog iOS**:`flushAt=20`、`flushIntervalSeconds=30`、`maxQueueSize=1000`、`maxBatchSize=50`;队列落在文件、满了丢最旧、只在线时冲;事件 UUID 去重「不保证」。来源:https://posthog.com/docs/libraries/ios/configuration 、https://posthog.com/docs/libraries/ios 、https://posthog.com/docs/cdp/troubleshooting.md 。可借:有界磁盘队列 + 丢最旧 + 自报丢弃。不可借:按条数/30 秒定时冲——那是独立射频唤醒,本案靠搭车。
- **Sentry iOS**:`sampleRate=1.0`、`maxCacheItems=30` 个 envelope(超了删最旧)、`appHangTimeoutInterval=2.0s`、watchdog 终止靠启发式。来源:https://docs.sentry.io/platforms/apple/guides/ios/configuration/options/ 、https://docs.sentry.io/platforms/apple/guides/ios/configuration/sampling/ 。可借:有界缓存数;「上次前台没正常退出」的脏标记法(§1.9-3)就是 watchdog 启发式的最简版。不可借:采样——十台设备不需要也不该采样。
- **幂等管线**:「ID 必须在事件发生处(producer)铸造,而不是在存储处」。来源:https://flaviocopes.com/courses/clickhouse/design-an-idempotent-event-pipeline/ 。→ slice_id 客户端 UUIDv5。
- **Postgres jsonb**:GIN 只服务包含/键存在查询,对路径取值与数值比较无用,且有写放大与膨胀;已知标量键用表达式 B-tree。来源:https://www.crunchydata.com/blog/indexing-jsonb-in-postgres 。→ 维度列(day/build/install)用普通列 + B-tree,jsonb 不建 GIN。
- **Supabase RLS**:service_role 有 bypassrls,但「带了用户 access token 的请求不绕过」;授权数据放 `app_metadata`;`(select auth.uid())` 让优化器做 initPlan;security definer 函数**绝不**放在 Exposed schema,且 `set search_path = ''`;RBAC 用自定义 claim hook(claim 只在换 token 时更新)。来源:https://supabase.com/docs/guides/database/postgres/row-level-security 、https://supabase.com/docs/guides/database/postgres/custom-claims-and-role-based-access-control-rbac 。→ 开发者读全表 = SQL 编辑器/psql 用 service_role,不要为「开发者」造 claim(本期无应用侧读者)。
- **Schema-less 坑**:payload 里带 schema 版本;边界处校验;新属性先落通配列造成「promotion lag」;用 null 率监控抓漂移。来源:https://estuary.dev/blog/schema-drift/ 、https://airbyte.com/data-engineering-resources/schema-drift-in-etl-pipelines 、https://www.technetexperts.com/clickhouse-event-analytics-pipeline/amp/ 。→ `schema_ver` 列 + Swift 生成的 key_registry(since/retired)就是边界校验与 null 率的落地。

## 3. 比较矩阵(v0 蓝图 vs C 方案)

| 维度 | v0 蓝图 | C 方案 | 判定 |
|---|---|---|---|
| 热路径成本 | 固定键 O(1):≤1 Date 读 + 1 比较 + 1 下标加 | 同;histogram 多 ≤4 次比较 | **同** |
| 落盘与备份配额 | 沿用 Documents/spike-runs(**随 iCloud 备份**),每 spike 256KB,窗口/快照各自追加行 | Application Support 排除备份,单文件 ≤64KB,1 行/日 | **C 优**:用户备份配额 0;Fix Watch 放 Documents 的理由(devicectl 拉)对 TF 不成立 |
| 电量与流量 | ≤20 请求/天 ≤64KB;退后台「尽力发一次不等结果」 | 搭车三边沿、今日切片 15 分钟节流;典型 12KB/天 | **C 略优**:不等结果的后台请求多半挂起到下次前台,等于白发一次 |
| 上传可靠性:完成率 | 退后台不包 `beginBackgroundTask` → 请求挂起;启动补传 | 退后台包后台任务(≈30s 窗);前台 +2s 再补 | **C 优** |
| 上传可靠性:时序 | 游标 = 内容哈希,服务端 upsert「最新一条胜」 | 客户端 `flush_seq` 单调 + 服务端 `where excluded.flush_seq >` | **C 优**:启动补传与后台发送并发重排时,v0 的旧内容能覆盖新行;C 拒之 |
| 冷启动影响 | 「启动按游标补传」;seed 走 `loadRuns` 全文件解码(≤128KB) | 首帧前零网络;seed 读 ≤4KB;自测 `resident_init_ms` | **C 优**(可测) |
| 数据质量:删失 | 沿用观察站 wTapsMissing…/wClosedByResign 等标记 | 同 + `app.unclean_exit` 脏标记 + `complete`/`flush_seq` | **C 略优**:多了「上个进程非正常退出」与「切片是否封板」 |
| 数据质量:去重 | PK (user_id, run_id) upsert | slice_id UUIDv5 + 切片内累计计数 → 重传天然幂等 | **同**(两者都幂等;时序差已在上一行) |
| 数据质量:版本演化 / 0 vs 无上报 | 「键按 app_build 可区分」——靠分析者知道哪个构建引入哪个键 | `key_registry(since_build, retired_build)` 由 Swift 枚举生成,视图把「不应出现」读成 NULL、「应出现而缺」读成 0 | **C 优**:0/NULL 编码进 SQL,不靠人脑 |
| 数据质量:Q① 保真 | 窗口记录原样上传(wCommitMs 原值表)+ verdictSnapshot,可与设备卡片**逐项对拍** | 窗口关闭时折进直方图 + top-3 exemplar;SQL 合并桶 | **v0 优**:C 丢了原值表,设备 p50 与 SQL 桶份额不是同一个数,失去对拍 oracle |
| 直方图线格式 | `SpikeMetricValue.string` 空格分隔("0 3 9 …") | jsonb 数组 `{"b":[…],"n","sum","max"}` | **C 优**:SQL 直接 `jsonb_array_elements` 相加;字符串要 split+cast |
| 隐私再识别 | 行键 `user_id + install_id`,RLS 自己可读写;与用户数据表可按 user_id 直接 JOIN | 无 user_id 列;独立不暴露 schema;definer RPC;开发者 service_role 读 | **C 优**:schema 级假名化;v0 每行按 Apple 定义都是 linked |
| 账号删除 | user_id 外键级联删行 | 需 `telemetry_forget(install_id)` 由客户端在擦除时尽力调 | **v0 优**:级联是结构保证,C 是尽力 |
| 同意范围 | 开关开后「resident-daily 原样上传」→ 同意前采的历史日记录会被传 | `consent_at` 水位;关时不落盘;历史不传 | **C 优**:v0 有同意前数据外流 |
| 开启率 | 默认关 + 文案改实话 | 同 + 预览页展示实际发出的切片 | **C 略优**(透明换信任,未证) |
| Debug 隔离 | 复用同步「Debug 包禁传生产」闸 | config 列分区(debug 行进表) | **v0 优**:现成闸、生产零污染 |
| 错误计数接法 | 接 86 处 DiagnosticTrail 写入点各一 ID(首批两域) | 接类型化咽喉:`SyncWriteFailureKind` 八种 + flush/pull/restore/commit 结果 ≈ 20 键 | **C 优**(可维护性):86 个 ID 随每次重构漂移,注册表测试负担线性涨;v0 优在取证粒度 |
| 服务端查询成本 | ~20 行/设备-日(4 daily + ≤12 窗口 + 快照)→ 10 台 ≈ 73k 行/年 ≈ 110MB;字符串直方图 | 1 行/设备-日-构建 ≈ 3.7k 行/年 ≈ 11MB;数组直方图 | **C 优**(两者在此规模都不构成问题) |
| 消费方纪律 | 注册表项**必须**命名 `consumerView`,否则不许开(62.7M 教训) | 视图按问题写,但注册表项没有强制消费方字段 | **v0 优** |
| 可测性 | 关=零请求;重传一行;游标 2xx 变异红;Debug 挡;note 正对照;擦除;源扫描;**快照==卡片** | §1.9 九条:幂等时序变异、删失断言丢失、0/NULL 变异、同意水位、类型级无字串 | **各有独门**:v0 的「快照==卡片」是最强 oracle;C 的「叶值只能是数」是最强结构守卫 |
| 实现成本 | 复用 SpikeRun/SpikeRunStore/Fix Watch 整套;一张表 + 标准 RLS | 新累加器、新 outbox、RPC + 注册表生成 + 对拍测试 | **v0 优**(估 C 多 30-40% 工时) |

**结论行**:v0 胜在实现成本、Q① 原值对拍、Debug 闸、级联删除、强制消费方;C 胜在同意范围(v0 会外流同意前数据)、上传时序守卫(v0 可被重排覆盖)、0-vs-NULL 进 SQL、schema 级假名化、备份配额与冷启动。热路径、幂等、电量基本同。建议:**以 v0 的骨架(SpikeRun 信封、SpikeRunStore 池、Fix Watch 窗口原样、Debug 闸、consumerView 规则)落地,嫁接 C 的三处坚持**。

## 4. 三处坚持 / 三处让步

### 坚持(不让)

1. **同意水位 + 关则不落盘**。开关关时遥测累加器不持久化;开时记 `consent_at`,只上传 ≥ 该时刻开始的切片;Fix Watch 现有的几周 `resident-daily` 历史**不**「原样上传」。理由:Apple 原文「ongoing collection after an initial request for permission must be disclosed」,而同意前采集的数据在开关打开那一刻外流,是任何披露都盖不住的。可测:§1.9-5。
2. **服务端 `flush_seq` 守卫 + Swift 生成的 `key_registry`**。「最新一条胜」在启动补传与后台发送并发时会让旧内容覆盖新行;`since_build/retired_build` 让「0」与「该构建根本没有这个键」在 SQL 里是两个值。理由:这两点都是「删失、去重、版本、0 vs 无上报」目标函数的直接项,且各自一条变异测试就能证伪。
3. **假名化 schema**:行里无 `user_id`;独立 `telemetry` schema 不暴露;写只经 security definer RPC(auth.uid 非空 + 配额 + 边界);读只有 service_role SQL。理由:v0 的 `(user_id, run_id)` 主键让每一行按 Apple 定义都是 linked,且与用户数据表一个 JOIN 之遥——「schema 与用户数据分离」的拍板应当落到连接键上,不只是表名前缀。代价是账号删除要靠 `telemetry_forget` 尽力调用(见让步 3 的对冲)。

### 让步(向 v0)

1. **Q① 保真**:保留窗口记录(≤12/天、纯数值聚合)与 `verdictSnapshot` 原样上传,接受 SpikeRun 作为通用信封、SpikeRunStore 作为本地池。我的「折进直方图」丢掉了与设备卡片逐项对拍的 oracle;装机验证最需要的恰是这个 oracle。合并直方图作为**第二**读法保留(全体设备合并样本量,是设备单机答不了的问题),不作判定权威。
2. **Debug 闸**:复用同步已有的「Debug 包禁传生产」,不用我的 config 列分区;debug 行去 staging。现成、零污染、不用再解释「为什么表里有 debug 行」。
3. **`consumerView` 强制字段**:注册表项无具名 SQL 视图不许开。这是 62.7M token 事故的直接教训,我的设计里只是「按问题写视图」,没有把「无消费方不开」做成契约。对冲坚持 3 的代价:把 `telemetry_forget` 也列为擦除注册表(#266)的必检项,并在 `v_active_installs` 旁加一条「孤儿 install_id(擦除后仍有行)」视图,让尽力调用的失败可见。

## 5. 环境说明

- 本机内置盘在本次会话中已满(ENOSPC):Bash 无法启动(输出捕获文件建不出来),本文首次写入 scratchpad 失败后写到 `/Volumes/AgentAPFS/claude-build-cache/chassis-architect-C/C-alternative.md`(两处内容相同);未删任何文件。
- 因无 shell,`PrivacyInfo.xcprivacy` 存在性只按 `Done/PrivacyInfo.xcprivacy` 一个路径用 Read 探过;grep 级核实(如同步 Debug 闸的具体文件、`beginBackgroundTask` 的现有调用点)引用的是源码注释(LocalDataEraseEpoch.swift L53-65)而非 grep 结果。
- Apple developer.apple.com 文档页为 JS 渲染,WebFetch 只拿到标题;§2 中标「记忆/未核到原文」的条目请在落地前对原文核。
