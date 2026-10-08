# 全平台单账号实时同步 — 设计 v0

日期:2026-10-08 · 基线:king `25f8b84` / mac `feat/donemac-phase1 @ d88f783` / Supabase `uqnvtzblppjblwgbpqhf`(PG 17.6)
状态:**设计稿,待拍板**(决策点见 §10)。所有「现状」条目均为本次实测,不是转述文档。

## 0. 一句话

把 Supabase 从「iOS 的只读镜像」改成「这个账号的变更日志」。每台设备既是带游标的订阅者,也是带 outbox 的发布者。Realtime 只当门铃;真相永远走游标拉取。

## 1. 现状(实测)

### 1.1 iOS 上传链路 `Done/Services/SupabaseSyncService.swift`
- **单向**:注释原话「iOS is the single source of truth; the server is a read-only mirror」。没有任何入站路径,除了手动 Restore。
- **整表哈希差分**:每个 `@Published` 数组 2 s 防抖后,对**全部行**重算 `rowHash`(SHA-256),和上次持久化的哈希表比;主用户 4695 个 event 行,每次任何一处改动都走一遍 O(N)。#219 已把「Supabase 哈希表零改动照写」列为写放大项。
- **删除 = 集合差**:`diffSync` 把「上次哈希表里有、这次数组里没有」的 id 物理 `DELETE`。这是唯一的删除机制,没有 tombstone。两台设备一旦都写,它就错:A 拉到 B 的删除后把行移出数组,A 自己的 sink 会再发一次 `DELETE`,把服务端的删除记录也抹掉,第三台设备永远不知道这条被删了。
- **`updated_at` 是上传时刻**:`eventToRow` 对 events / event_types 写 `iso(Date())`;只有 logs / feedback 送真实的 `updatedAt`。云端 `updated_at` 不能用来判「谁后改」。
- **门禁**:`debugBlocksUploads`(DEBUG 编译期禁上传)∧ `syncUploadsEnabled`(用户开关,默认 OFF)。模拟器里今天不可能测到双向。
- **Restore**:`RestoreCoordinator` 手动全量拉 9 张表 → merge(keep-local / keep-cloud / per-row)或 replace → `markRestoreCompleted` 全量重播哈希。merge 永不删本地独有行。

### 1.2 macOS `feat/donemac-phase1 @ d88f783`(落后 king 88 个 commit,merge-base `c1946e9` 2026-09-09)
- 自己的 `MacEventStore` + `MacPersistence`,文件路径与 iOS 同名但在各自沙盒里;**磁盘上两端零共享**,Supabase 是唯一通道。
- `DoneMac/DoneMac/Sync/MacSyncEngine.swift`:手动 `syncNow`(按钮),**只管 `events` 表**,pull-all → 采用服务端 → push 脏行 → push tombstone。冲突规则「iOS wins」(服务端 stamp 动了就放弃本地脏行)。
- `Truth/RevisionSidecar.swift`:per-row `revision / updatedAt / lastPushedRevision`、`serverStamps` 基线、`tombstones`、`pushedAwaitingRebaseline`。这是仓库里**唯一**已存在的「出站 outbox」形态,设计可以升格为共享。
- **合并前必须清**:`Done/Services/Sync/SupabaseCore.swift` 在该分支里 `#if os(iOS)` 仍带已吊销的 service_role JWT 字面量,`#else` 带 legacy anon JWT;legacy keys 已于 2026-09-23 禁用(#232),该分支现在的 Mac 二进制对后端是全路径 401。king 侧早已换成 `sb_publishable_…`。

### 1.3 服务端(`done-mcp/supabase/migrations/001…014`,已对库实测)
- 9 张人类表:`events` / `event_logs` / `event_feedback` / `todo_lists` / `event_types` / `skill_insights` / `user_settings` / `agent_preferences` / `agent_conversations`;RLS 全部 `auth.uid() = user_id`。
- **没有**:`deleted_at`、服务端序号、`device_id`、服务端写入的时间戳(`updated_at` 由客户端供)。
- `supabase_realtime` publication 存在但**零表**;所有表 replica identity = default;`public` 上**零触发器**;扩展只有 plpgsql / pg_stat_statements / uuid-ossp / pgcrypto / vault(**没有 pg_cron**)。
- 行量:events 4787 / event_logs 687 / skill_insights 7515 / event_types 30 / users 3;主用户 4695 events。

### 1.4 本地存储(`Done/Services/Storage/`,4510 行)
- `DurableEventStorage`:8 个 slot(events / calendarEvents / feedback / logs / todoLists / people / friendGroups / reminders)各一个 json + bak + log;slot 信封头有本地单调 `seq`。
- `calendarEvents` 有 gh#235 delta log,记录 `changed: [Event]`;**删除只体现在 `order` 变化**,没有显式删除记录。
- `persist()` 显式同步调用;`onSlotCommitted(slot, mode)` 是「本地持久写入确实落盘」的唯一干净钩子。
- `Event`(212 字段)**没有 `updatedAt`**;`TodoList` / `EventTypeTemplate` / `SkillInsight` 也没有。`CalendarEventLogRecord` / `FeedbackRecord` 有。
- 没有任何实体有 tombstone;删除全是数组移除(`People` 例外,有 `isArchived`)。
- **事件类型本地按 title 去重合并**(`dedupedByTitle`),wire 上按 UUID。
- **未同步实体**:people / friendGroups / reminders / reports / customAnniversaries(#39 people 绑定已 shipping 但不上云)。

### 1.5 认证 `Done/Services/AuthService.swift`
- Apple / Google → GoTrue;会话存 `UserDefaults.standard`(`supabaseAuthSession`)。
- **#249 未修**:UserDefaults 进 iCloud/iTunes 备份、被 Quick Start 复制 → 两机共用一条 refresh token family → 轮换互相作废 → GoTrue reuse detection 吊销整条 family。**这是 #234(202 次 `refresh_token_already_used`)的根因,多设备同步的硬前置。**
- #250 瞬时失败退避未做(96 秒 16 次 `/auth/v1/token`)。

## 2. 目标与非目标

**目标**(每条可证伪):
1. 同一账号在 iPhone / iPad / Mac 上,前台时一端的编辑 ≤ 2 s 出现在另一端。
2. 离线编辑后上线自动收敛;冷启动 / 切前台必追平到服务端 head。
3. 两端同时改同一条:任何一方的版本都不丢(败方留在本地 conflict shelf,不覆盖)。
4. 删除可传播、可撤销(服务端 tombstone 是 #140 的服务端半)。
5. 客户端永不发物理 `DELETE`。
6. 每一步有 log,能在 harness / 真机上证明(用户 2026-08-30 定的硬要求)。

**非目标**(本战役不做):协同编辑的字段级合并;多账号切换;Android;图片二进制的实时(沿用 `ImageBackupCoordinator`);APNs 静默推送(后续可叠加)。

## 3. 核心决策(推荐 · 理由 · 备选)

| # | 决策 | 推荐 | 理由 | 备选 |
|---|---|---|---|---|
| D1 | 变更如何到达客户端 | **门铃 + 游标拉取**:DB 触发器 `realtime.send` 到私有 channel `user:<uid>`,payload 只有 `{table,id,seq,device_id}`;客户端合并 300 ms 后 RPC `sync_changes(since_seq)` | iOS 后台必断线,拉取无论如何必须有;只留一条应用路径;RLS 在 join 判一次而非每行判;payload 极小 | `postgres_changes` 整行推送:9 个订阅、每行 RLS、断线仍要拉,两套应用路径 |
| D2 | 变更的身份 | **服务端 `seq`**(触发器 `nextval`),不是 `updated_at` | 客户端时钟不可信(今天 `updated_at` 就是上传时刻);单调、可续传;一个游标覆盖 9 张表 | 每表 `server_updated_at` 游标:9 个游标,时间戳并发相等时丢行 |
| D3 | 删除 | **tombstone**(`deleted_at`),30 天后服务端 purge | 变更日志必须含删除;第三台设备要能看到;备份恢复不会「复活」已删行(#21 场景 B / #24) | 物理 DELETE + 删除日志表:两张表要对齐 |
| D4 | 冲突 | **按编辑时刻 LWW + 败方上架**(本地 conflict shelf 文件,不丢字节);Phase 1 过渡期用「服务端先到者胜,本地脏行推后」 | 「不丢任何一方」是底线(Data Preservation First);Event 现在没 `updatedAt`,先到者胜是唯一诚实的过渡规则(Mac 现行) | 字段级三路合并:非目标 |
| D5 | 回声 | `device_id`(每次安装一个 UUID,Keychain ThisDeviceOnly);广播带它,客户端忽略自己的,游标照样推进 | 没有它每次 push 都会触发一次自拉 | 比 `updated_at` 字符串:Mac round-6 已实证格式脆弱 |
| D6 | 出站 | **per-row outbox**(revision / lastPushedRevision / tombstone,沿 Mac sidecar 形态做成共享);Phase 1 先保留哈希差分探测变更,但删除改 tombstone、应用远端后只重播被触碰行的哈希 | 整表哈希是 O(N) 写放大;outbox 是 O(改动) | 继续哈希差分:与 tombstone 并存的坑见 §9 |
| D7 | 放哪 | 共享 Swift `Done/Services/Sync/`(两 target 编译,进 `shared-manifest.txt`);`MacSyncEngine` 退役 | Mac 引擎是 phase-1 脚手架,明文「不承诺 offline three-way」 | 两套引擎:必然漂移 |
| D8 | 开发环境 | DEBUG 保留「禁写生产」,但指向**开发后端**(Supabase branch 或第二个项目)并允许上传 | 否则模拟器里永远测不到双向 | 只在 Release 真机测:装机队列已是瓶颈 |
| D9 | 默认开 | 登录即同步;「暂停同步」保留为显式动作 | per-device 开关默认 OFF 和实时同步语义冲突 | 维持默认 OFF:每台新设备都要手点 |

## 4. 架构

```
                      ┌──────────────── Supabase ────────────────────┐
  device A ──push────▶│ 9 tables  + seq / deleted_at / device_id      │
   outbox             │ trigger set_sync_meta: seq=nextval, srv_upd=now│
                      │ trigger notify: realtime.send('user:<uid>')    │
  device B ◀──pull────│ rpc sync_changes(since_seq, limit) [invoker]   │
   cursor             │ realtime.messages RLS: topic == 'user:'||uid   │
  ◀─ ws doorbell ─────│ channel realtime:user:<uid>  (private=true)    │
                      └───────────────────────────────────────────────┘

SyncEngine (@MainActor, shared)
 ├ SyncCursorStore    per-user lastSeq(AtomicValueFile;丢了 = 必须先全量拉)
 ├ SyncOutbox         dirty / tombstone 日志(Phase 2;Phase 1 由哈希差分代)
 ├ SyncPusher         drain → upsert(updated_at = 编辑时刻, device_id);tombstone = upsert deleted_at
 ├ SyncPuller         rpc sync_changes → [RemoteChange(table, id, row | tombstone, seq, device_id)]
 ├ SyncApplier        EventStore.applyRemote(_:) 单一入口:绕过 outbox、只重播触碰行哈希、复用既有级联
 ├ RealtimeDoorbell   URLSessionWebSocketTask + Phoenix 协议;heartbeat 20 s(文档上限 25 s);token 刷新;合并 300 ms → pull
 └ Triggers           launch / foreground / reconnect / doorbell / push 之后 / 前台 60 s 兜底轮询
```

**不变量**(每条要有测试):
- I1 **先拉后推**:本 session 至少拉到过服务端 head 才允许 push;游标丢失同样。
- I2 **应用不回声**:远端写入经 `persist(origin: .remote)`,出站 sink / outbox 跳过。
- I3 **游标只在落盘后推进**:崩溃 → 重拉,upsert 幂等。
- I4 **客户端永不物理 DELETE**。
- I5 **自己的回声被忽略但 seq 仍推进**。
- I6 **一行的 tombstone 比它的任何旧版本都新**:恢复出来的旧行(备份复活)推不过服务端的 tombstone。

## 5. 服务端变更(migration 015 草案,未应用 — 全文见 `done-mcp/supabase/migrations/015_sync_change_feed.sql`)

```sql
-- 全局序列即可:客户端只在自己 user 内比较
create sequence if not exists public.sync_seq;

-- 对 9 张表各加:
alter table public.events
  add column if not exists seq               bigint not null default nextval('public.sync_seq'),
  add column if not exists deleted_at        timestamptz,
  add column if not exists device_id         text,
  add column if not exists server_updated_at timestamptz not null default now();
create index if not exists idx_events_user_seq on public.events(user_id, seq);

create or replace function public.set_sync_meta() returns trigger
language plpgsql as $$
begin
  new.seq := nextval('public.sync_seq');
  new.server_updated_at := now();
  return new;
end $$;
create trigger trg_events_sync_meta before insert or update on public.events
  for each row execute function public.set_sync_meta();

-- 门铃:只带定位信息,不带行
create or replace function public.notify_sync_change() returns trigger
language plpgsql security definer as $$
begin
  perform realtime.send(
    jsonb_build_object('table', tg_table_name, 'id', new.id, 'seq', new.seq,
                       'device_id', new.device_id, 'deleted', new.deleted_at is not null),
    'change', 'user:' || new.user_id::text, true);
  return new;
end $$;
create trigger trg_events_notify after insert or update on public.events
  for each row execute function public.notify_sync_change();

-- 私有 channel:只能收自己的
create policy "own sync topic" on realtime.messages for select to authenticated
  using (realtime.topic() = 'user:' || auth.uid()::text);

-- 一次调用拉全部表(security invoker → RLS 生效)
create or replace function public.sync_changes(since_seq bigint, page_limit int default 500)
returns table (tbl text, seq bigint, row jsonb)
language sql stable as $$
  select * from (
    select 'events', seq, to_jsonb(e) from public.events e where seq > since_seq
    union all select 'event_logs', seq, to_jsonb(l) from public.event_logs l where seq > since_seq
    -- … 其余 7 表
  ) s order by seq limit page_limit;
$$;
```

**向后兼容**:旧客户端 upsert 不带新列 → 触发器补 seq / server_updated_at,`device_id` 为 null(视为外来变更);PostgREST 返回多余列 `RowReader` 忽略;旧客户端的物理 `DELETE` 在过渡期丢 tombstone(可接受,混跑窗口同 #151 一类)。`updated_at` 列**不再**由触发器覆盖——它要变成「编辑时刻」(Phase 2)。

## 6. 应用远端变更(最难的一段)

`EventStore.applyRemote(_ batch: [RemoteChange]) -> ApplySummary`,**唯一**入口,规则:
- **events**(两 kind):insert / update = 按 id 替换;tombstone = 走 `deleteCalendarEvent` / todo `delete` **同一套级联**(interrupt 子事件孤儿化、被吸收 todo 释放、log / feedback 剪枝),**但不 purge 图片资产**(留给 purge 期)。不得新写一套删除语义——#140 已记 `rawCalendarEvents` 144 处消费者的教训。
- **recurring**:父 tombstone → 现有级联处理实例;detached 实例更新 = 普通行更新;day-key 身份照 migration 014 规则(#151 的 stale 标量防护顺带补)。
- **event_logs / event_feedback**:有 `updatedAt`,从第一天起 LWW by `updatedAt`;identity = `CalendarOccurrenceKey` 编码,沿 `decodeOccurrenceKey`。
- **event_types**:本地按 title 合并、wire 按 UUID → applier 按 title 合并并记录 UUID 不一致(日志),不改本地身份规则。
- **todo_lists**:无 `updatedAt`,Phase 1 先到者胜。
- **单行 blob**(user_settings / agent_preferences / agent_conversations):Phase 1 整行按 seq 先到者胜;settings 的 per-key 合并放 Phase 3(两台设备各改一个不相干的键会互相覆盖——今天 restore 也是这样)。
- 写入经 `persist(origin: .remote)`;`onSlotCommitted` 之后才推进游标;只对触碰的 id 重算哈希基线(不是 `markRestoreCompleted` 的全量)。
- 派生状态(occurrence 缓存、搜索语料、widget 快照)沿现有 `didSet` / `scheduleWidgetSnapshotSync` 刷新,不另开路径。

## 7. 分期(每期可独立装机、各自验收)

### Phase 0 — 地基(全部是现有 issue 或纯加法)
| 项 | 内容 | 验收 |
|---|---|---|
| P0.1 | **#249** 会话搬 Keychain `ThisDeviceOnly`(两 target) | 备份恢复到第二台机不带 refresh token;#234 形状不再可造 |
| P0.2 | **#250** 瞬时刷新退避熔断 | 断网 60 s 内 `/auth/v1/token` ≤ 2 次 |
| P0.3 | Mac 分支合 king(`25f8b84`→`feat/donemac-phase1`),删两个 JWT 字面量,改 publishable key | Mac 二进制对后端非 401;`verify-both.sh` 绿 |
| P0.4 | 开发后端(D8)+ `SupabaseSyncConfig` 环境切换 | DEBUG 模拟器能 upsert 到开发库 |
| P0.5 | migration 015(§5)先在开发后端跑;`sync_changes` 用 SQL 对拍 | 老客户端 upsert 后 `seq` 非空;RLS 下只见自己 |
| P0.6 | `device_id`(Keychain)+ 现有 upsert 带上它 | 行上 `device_id` 非空 |

### Phase 1 — 入站实时(用户第一次看到「另一台上出现」)
- 交付:`SyncCursorStore` / `SyncPuller` / `SyncApplier`(§6)/ `RealtimeDoorbell`(**已在本分支**:`Done/Services/Sync/SupabaseRealtimeDoorbell.swift`,脚本化 socket 测试,未接线);客户端删除改 tombstone upsert;`diffSync` 的物理 DELETE 删除;应用后按触碰 id 重播哈希;launch / foreground / doorbell 三触发。
- 两 target 都接(Mac 用同一引擎,`MacSyncEngine` 退役)。
- 验收:A 建 / 改 / 删 → B 前台 ≤ 2 s 落地并有 `sync.apply table=… id=… seq=… latency_ms=…` 日志;B 后台 10 min 再前台 → 一次拉取追平;断网编辑 → 联网后收敛;**A 删 B 不会把 tombstone 抹掉**(I4 的 SQL 对拍)。
- 已知缺口(明示):出站仍是哈希差分;冲突规则是先到者胜。

### Phase 2 — 出站精确
- `Event` / `TodoList` / `EventTypeTemplate` 加可选 `updatedAt`(`decodeIfPresent`,三条 Codable 消费路径兼容);`SyncOutbox` 替换哈希差分;`updated_at` = 编辑时刻;LWW + conflict shelf;`device_id` 回声抑制。
- 验收:一次编辑 = 一次 upsert(不再 O(N) 哈希);双端同改同一条 → 两个版本都在(一个在 shelf);shelf 文件可读。

### Phase 3 — 守卫与软删
- **#24** 风险门(`SyncSafetyEvaluator`:游标缺失 / 大量旧行 / 复活 tombstone → cautious / quarantine);**#140** 回收站 UI 吃 tombstone;settings per-key 合并;服务端 purge(edge function 定时 / pg_cron)。
- 验收:iCloud 备份恢复的旧机不会把 tombstone 行推回;回收站能撤销。

### Phase 4 — 覆盖面
- people / friendGroups / reminders / customAnniversaries / reports 上 schema 并进同一引擎;widget 快照在 apply 后刷新;图片同步由 doorbell 唤醒。

## 8. 验证策略(独立 QA 循环适用)

- **纯引擎收敛测试**:两个 `EventStore`(隔离存储)+ `FakeServer`(分配 seq、存 tombstone、不模拟 RLS)+ `FakeGateway`;随机操作序列后断言 A == B == server(seeded,带正对照和变异体;参考 `reference_test_teeth_structural_traps`)。
- **协议测试**:`RealtimeDoorbell` 用 fake transport 回放 `phx_reply` / `heartbeat` / `access_token` / 错误帧 / 断线重连。
- **SQL 对拍**:`sync_changes` 在开发库上对 execute_sql 结果;I4 用 `count(*) where deleted_at is not null` 前后对比。
- **装机**:harness 场景「双机 ping-pong」(#197 形态),每一步一条结构化日志;帧看尾部(`reference_device_perf_measurement`)。
- **写放大**:apply 只写触碰的 slot;doorbell 合并;Fix Watch 计数器 `sync.pull.rows` / `sync.apply.slots`。

## 9. 风险与已知坑

1. **#249 不修,多设备就是在制造 #234**:两机长期在线必毒死 token family。P0 不可跳。
2. **哈希差分与 tombstone 并存期**:Phase 1 必须同时(a)删物理 DELETE、(b)应用后重播触碰行哈希,缺一个就会回声删除或回声上传。
3. **`Event` 加 `updatedAt`**:durable / backup snapshot / widget 三条 Codable 路径;Lean fixtures 不含该字段;optional + `decodeIfPresent` 才能让旧 build 读新文件。
4. **混跑窗口**(#151 一类):老 build 的 DELETE 丢 tombstone;老 build 的 `updated_at` 是上传时刻,会在 LWW 里「赢」——Phase 2 上线前要全机队升到 Phase 1 build。
5. **iOS 后台**:socket 被杀是常态;正确性全靠前台追平,不靠 doorbell。
6. **Realtime 配额**:每用户每设备 1 连接、前台才连;配额数字见 §11。
7. **单行 blob 互相覆盖**:两台设备各改一个 settings 键会互相抹——今天已如此,Phase 3 才修。
8. **事件类型按 title 合并**:两台各建同名类型 → UUID 不同 → applier 必须按 title 合并否则重复。
9. **`EventStore` 4353 行**:applyRemote 复用级联,不新写;否则重蹈 canvasRenderable 审计的 11 个 Tier-1。
10. **#24 的「老本地状态污染云端」**在 I1 + I6 下大部分自然消解,但「游标缺失时先全量拉再推」要做成硬门,不是建议。

## 10. 待拍板

1. D8 开发后端形态:Supabase branch(Pro 计费)vs 第二个免费项目。
2. D9 登录即同步,还是保留 per-device 开关默认 OFF。
3. Phase 1 是否同时带 Mac(前置 P0.3 合并,88 个 commit 的 rebase)。
4. tombstone 保留期(建议 30 天)与 purge 载体(edge function cron vs 申请 pg_cron)。
5. settings per-key 合并是否提前到 Phase 2。
6. 是否要 APNs 静默推送让后台也近实时(本设计不依赖它)。

## 11. Realtime 协议与配额(实现 `RealtimeDoorbell` 的依据)

见 `Docs/sync/01-realtime-protocol-notes.md`(从 Supabase 文档摘录,含 wire shape)。

## 12. 关联

#21(L1/L2 架构已定,本设计是 L2 的双向化)· #24(守卫 → Phase 3)· #35 · #140(软删 → tombstone)· #151 · #234 / #249 / #250(P0)· #16 / #22(图片)· #219(写放大判据)· `project_donemac_campaign`(Mac Phase 1)
