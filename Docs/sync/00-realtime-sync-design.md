# 全平台单账号实时同步 — 设计 v1

日期:2026-10-08(v0)· 2026-10-12(v1,独立评审第一轮后)· 基线:king `25f8b84` / mac `feat/donemac-phase1 @ d88f783` / Supabase `uqnvtzblppjblwgbpqhf`(PG 17.6)
状态:**设计稿,待拍板**(决策点见 §10;v1 改了什么、砍了什么见 §13)。所有「现状」条目均为实测,不是转述文档。

## 0. 一句话

把 Supabase 从「iOS 的只读镜像」改成「这个账号的变更日志」。每台设备既是带游标的订阅者,也是带哈希基线的发布者。Realtime 只当门铃;真相永远走游标拉取。

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
5. 任何客户端(新旧 build)都抹不掉一条删除记录。
6. 每一步有 log,能在 harness / 真机上证明(用户 2026-08-30 定的硬要求)。

**非目标**(本战役不做):协同编辑的字段级合并;多账号切换;Android;图片二进制的实时(沿用 `ImageBackupCoordinator`);APNs 静默推送(后续可叠加)。

## 3. 核心决策(推荐 · 理由 · 备选)

| # | 决策 | 推荐 | 理由 | 备选 |
|---|---|---|---|---|
| D1 | 变更如何到达客户端 | **门铃 + 游标拉取**:语句级触发器 `realtime.send` 到私有 channel `user:<uid>`,payload 只有 `{table, seq}`,每条语句一帧;客户端合并 300 ms 后 RPC `sync_changes(since_seq)` | iOS 后台必断线,拉取无论如何必须有;只留一条应用路径;RLS 在 join 判一次;一次 4695 行的整表重推只响 235 下而不是 4695 下 | `postgres_changes` 整行推送:9 个订阅、每行 RLS、断线仍要拉,两套应用路径 |
| D2 | 变更的身份 | **服务端 `seq`**,BEFORE 触发器取号前先 `pg_advisory_xact_lock(hashtext(user_id))` | 没有锁,取号序和提交可见序会错位,游标会永久跳过一行(评审 #1);锁按用户分,只串行化同一账号的写 | 按 `server_updated_at` 游标:9 个游标,时间戳相等时丢行 |
| D3 | 删除 | **tombstone**(`deleted_at`),**不 purge**;物理 DELETE 在服务端被触发器改写成 tombstone;普通写入不能撤销 tombstone | 变更日志必须含删除;改写让旧 build 的 DELETE 也无害,过渡期不丢;这个规模删除稀少,purge 需要一套水位线机制才不会复活,不值 | 30 天 purge + 水位线:等 tombstone 真成了成本再做 |
| D4 | 冲突 | **以哈希基线做三方比较**:来件 == 本地 → 无事;本地干净 → 采用来件;本地脏且来件不同 → 本地胜,来件整行进 conflict shelf 文件;来件是 tombstone → 总是采用,本地脏版本进 shelf | 不需要 `updatedAt`、不信任时钟、双方版本都在;基线本来就在 | 按编辑时刻 LWW:要给 `Event` 加 `updatedAt`(三条 Codable 路径),时钟不可信,而 shelf 已经保证不丢 |
| D5 | 回声 | **不做发送者标识**。自己推上去的行拉回来与本地一致,三方比较判为无事 | 省一列、一个 Keychain 项、一个字段;代价是每次推送后多拉一次自己刚推的行(20 行一块) | `device_id` 列 + 客户端忽略 |
| D6 | 出站 | **保留整表哈希差分**;删除改为 `PATCH deleted_at`(服务端也会把 DELETE 改写);应用远端后只重播触碰行的哈希,顺序是先落盘、再基线、再游标 | 差分已在跑;per-row outbox 留给 #219 的测量判断,不预先建 | 立刻做 outbox |
| D7 | 放哪 | 共享 Swift `Done/Services/Sync/`;**Phase 1 只接 iOS**;Mac 合 king、清 JWT 字面量后接同一引擎,`MacSyncEngine` 退役 | Mac 分支落后 88 commit 且二进制对后端 401,是独立工作量 | Phase 1 同时带 Mac |
| D8 | 开发环境 | **第二个免费 Supabase 项目** + `SupabaseSyncConfig` 按 build 配置切换;DEBUG 对生产仍禁写 | 14 条迁移重放已实证幂等(#244),建库零成本;branch 要 Pro | Supabase branch |
| D9 | 默认开 | 登录即同步;「暂停同步」保留为显式动作 | per-device 开关默认 OFF 和实时同步语义冲突 | 维持默认 OFF |

## 4. 架构

```
                      ┌──────────────── Supabase ────────────────────────────┐
  device A ──push────▶│ 9 tables + seq / deleted_at                           │
   hash diff          │ BEFORE row: user lock → seq=nextval; no-op write 丢弃; │
                      │             tombstone 不被撤销                         │
                      │ BEFORE DELETE row: 改写为 update deleted_at           │
  device B ◀──pull────│ AFTER stmt: realtime.send('user:<uid>', {table,seq})  │
   cursor             │ rpc sync_changes(since_seq, limit)  [security invoker]│
  ◀─ ws doorbell ─────│ realtime.messages RLS: topic == 'user:'||uid          │
                      └───────────────────────────────────────────────────────┘

SyncEngine (@MainActor, shared)
 ├ SyncCursorStore    per-user lastSeq(丢了 = 必须先全量拉)
 ├ SyncPuller         rpc sync_changes → [RemoteChange(table, seq, data | tombstone)];页短于 limit 即 head
 ├ SyncApplier        EventStore.applyRemote(_:) 单一入口;三方比较;shelf;复用既有级联
 ├ ConflictShelf      per-user 追加式 json 文件 + 日志;Phase 1 无 UI
 ├ RealtimeDoorbell   已落(URLSessionWebSocketTask + Phoenix);合并 300 ms → pull
 └ Triggers           launch / foreground / reconnect / doorbell / 前台 60 s 兜底轮询
```

Edge function 和 MCP 的写入走同样的触发器,所以 agent 改的东西也会响门铃。

**不变量**(每条要有测试或 SQL 对拍):
- I1 **先拉到 head 再推(硬门)**:本 session 至少完整拉过一次且最近一页短于 `page_limit`;游标缺失同样。
- I2 **应用不回声**:远端写入经 `persist(origin: .remote)`,出站 sink 跳过。
- I3 **落盘顺序 = slot → 触碰行哈希基线 → 游标**。中途崩溃只会「多拉一次」或「多推一次内容相同的行」,后者被服务端的无变化短路吸收。
- I4 **服务端抹不掉删除**:DELETE 被改写为 tombstone。是触发器,不是客户端承诺。
- I5 **seq 序 = 提交序**(用户级事务锁):看到 N 就看全了 < N。
- I6 **tombstone 不被普通写入撤销**(触发器保 `old.deleted_at`);撤销是显式 RPC(#140)。
- I7 **冲突不丢字节**:本地脏且来件不同时,败方整行进 shelf。
- I8 **写必须基于当前版本**:客户端随行带上它最后拉到的 `seq`,服务端不等则拒(HTTP 409);客户端拉、合、再推。没有它,两台设备在拉/推窗口里会互相盲覆盖,败方哪里都不在。

## 5. 服务端(migration 015 v2 草案,未应用 — 全文 `done-mcp/supabase/migrations/015_sync_change_feed.sql`)

五件事,全部幂等:
1. 9 表各加 `seq bigint not null`(先加可空、回填、再 not null,避免整表重写)和 `deleted_at timestamptz`;索引 `(user_id, seq)`。
2. `set_sync_meta()` BEFORE INSERT OR UPDATE 行级:取用户级事务锁 → UPDATE 时保 `old.deleted_at`;去掉 `seq/updated_at/synced_at` 后新旧 JSON 相等则 `return null`(不写、不取号、不响铃);客户端带来的 `seq`(它最后拉到的版本)非空且 ≠ `old.seq` 则 `raise sqlstate 'PT409'`(I8;旧 build 不带 seq,ON CONFLICT 下 `new.seq = old.seq` 自然通过)→ `seq := nextval`。
3. `notify_sync_change()` AFTER INSERT / AFTER UPDATE 语句级,`referencing new table as changed`,按 user 聚合 `max(seq)` 发一帧。security definer 是必需的:`realtime.send` 本身是 invoker,以 authenticated 身份插 `realtime.messages` 会被 RLS 拒且被 `realtime.send` 吞成 WARNING,门铃会静默失效。
4. `sync_delete_to_tombstone(key)` BEFORE DELETE 行级:只在 `current_user = 'authenticated'` 且 `pg_trigger_depth() = 1` 时改写成 `update … set deleted_at = coalesce(deleted_at, now()) where key = old.key; return null`;否则 `return old` 物理删除。后者覆盖 `auth.users` 的 RI 级联(账号擦除,以表 owner 身份在深度 2 跑)、service_role 和 dashboard。以调用者身份跑,RLS 生效。
5. `realtime.messages` 的 select policy:`realtime.topic() = 'user:' || auth.uid()`。`sync_changes(since_seq, page_limit)` security invoker,九表 union 按 seq 返回 `(tbl, seq, data jsonb)`;对 `public` / `anon` revoke execute。

**向后兼容**:旧 build 的 upsert 不带新列,触发器补 seq;旧 build 的 DELETE 变 tombstone;客户端只发 `Prefer: resolution=merge-duplicates`(return=minimal),被 BEFORE 触发器丢掉的无变化行对它不可见。`updated_at` 列不再有服务端语义。

## 6. 应用远端变更(最难的一段)

`EventStore.applyRemote(_ batch: [RemoteChange]) -> ApplySummary`,**唯一**入口。对每条来件 `(table, id, data | tombstone)`:

```
h_in   = rowHash(来件经 rowToX → xToRowForHashing)      // 往返稳定性每表一条测试
h_loc  = rowHash(本地行)  或 absent
h_base = 哈希基线[id]     或 absent                      // 基线值 = (hash, seq):hash 判脏,seq 随下次上传送回(I8)
dirty  = h_loc != h_base.hash

来件是 tombstone      → 走现有删除级联(不 purge 图片资产);dirty 则本地版本先进 shelf;基线移除 id
h_in == h_base.hash   → 无事,只更新 base.seq(这是我们自己推上去的版本回声,或别人推了同样内容)
h_in == h_loc         → 无事;基线[id] := (h_in, seq)
!dirty 或 本地 absent → 按 id 替换 / 插入;基线[id] := (h_in, seq)
dirty                 → 本地保留;来件整行进 shelf;log sync.conflict;基线[id] := (h_base.hash, seq)(hash 不动保持脏,seq 更新让下次上传能通过 I8)
```

上传随行带 `seq = 基线[id].seq`(本地新建、从未拉到过的行为 null)。服务端 409 → 不重试该块,立即触发一次拉取;拉完后哈希差分照常重推。一块 20 行里有一行过期,整块延后一轮,可接受。

**顺序敏感**:`h_in == h_base.hash` 必须在脏检测之前。否则 A 推 v1 后 0.5 s 内改成 v2,v1 的回声会被当成冲突进 shelf(评审二 C2)。

- **events**:tombstone 走 `deleteCalendarEvent` / todo `delete` **同一套级联**(interrupt 子事件孤儿化、被吸收 todo 释放、log / feedback 剪枝)。不得新写一套删除语义——#140 已记 `rawCalendarEvents` 144 处消费者的教训。
- **recurring**:父 tombstone → 现有级联处理实例;detached 实例更新 = 普通行更新;day-key 身份照 migration 014 规则。
- **event_logs / event_feedback**:identity = `CalendarOccurrenceKey` 编码,沿 `decodeOccurrenceKey`;同样走三方比较(它们有 `updatedAt`,但不另开规则)。
- **event_types**:本地按 title 合并(`dedupedByTitle` 保留先到者)、wire 按 UUID。两台各建同名类型会得到两个 UUID;若 applier 只按 id 插入,本地去重会丢掉其中一个,集合差分再把它 tombstone,对称发生在另一台上,两台都失去这个类型(评审二 C3)。规则:同 title 不同 UUID → 胜者 = 字典序最小的 UUID,**败方 UUID 永不进基线**;持有败方的设备把本地引用改指向胜者并 tombstone 自己的败方(幂等,两台都做也无害);来件是败方则忽略。
- **user_settings**:**按键三方合并,进 Phase 1**。理由由代码直接给出:`skillAnalyzedEventIds` 在 `SyncedSettings` 的同步键里,`SkillInsight` 每次分析都写它,每台设备独立增长,所以整行 blob 在两台设备上几乎永远同时脏;整行规则下用户在 A 改一个设置,会被 B 的 blob 反向覆盖到两台(评审二 D)。按键规则:每个键各自 `(in, loc, base)` 三方比较,只一侧改的取那一侧,两侧都改的本地胜、远端值进 shelf;`skillAnalyzedEventIds` 取并集(丢了会触发重分析和 LLM 开销)。
- **agent_preferences / agent_conversations**:整行三方比较;出现真实冲突再按键化。
- 写入经 `persist(origin: .remote)`;`onSlotCommitted` 之后才写基线和游标(I3)。
- 客户端自己的删除:`PATCH … ?id=eq.X&deleted_at=is.null` 置 `deleted_at = now()`,只对还活着的行,避免重复盖戳造成无意义的新 seq。
- 派生状态(occurrence 缓存、搜索语料、widget 快照)沿现有 `didSet` / `scheduleWidgetSnapshotSync` 刷新,不另开路径。

## 7. 分期(每期可独立装机、各自验收)

### Phase 0 — 地基
| 项 | 内容 | 验收 |
|---|---|---|
| P0.1 | **#249** 会话搬 Keychain `ThisDeviceOnly` | 备份恢复到第二台机不带 refresh token;#234 形状不再可造 |
| P0.2 | 第二个 Supabase 项目 + `SupabaseSyncConfig` 按 build 切换 | DEBUG 模拟器能 upsert 到开发库;对生产仍禁写 |
| P0.3 | 015 v2 应用到开发库;SQL 对拍 I4 / I5 / I6 和无变化短路 | 两个并发事务下游标不跳行;DELETE 后 `deleted_at` 非空且行还在;内容相同的 upsert 不改 seq;现行 king build 对开发库的上传和删除路径不报错 |

#250 刷新退避是好事但不是前置,顺手做。

### Phase 1 — 入站实时,iOS 两端(用户第一次看到「另一台上出现」)
- 交付:`SyncCursorStore` / `SyncPuller` / `SyncApplier`(§6,含 settings 按键合并与 event_types 胜者规则)/ `ConflictShelf` / 门铃接线;基线值扩成 `(hash, seq)`,上传带 `seq`,409 → 拉取;客户端删除改 `PATCH deleted_at`;应用后按触碰 id 重播基线;launch / foreground / doorbell / 60 s 兜底(带 `sync.pull.reason=poll` 计数,一个 build 内 rows>0 为零就删掉)。
- 验收:A 建 / 改 / 删 → B 前台 ≤ 2 s 落地并有 `sync.apply table=… id=… seq=… latency_ms=…` 日志;B 后台 10 min 再前台 → 一次拉取追平;A 离线改、B 在线改同一条 → A 上线后 shelf 文件里有 B 的版本、服务端是 A 的版本、B 随后拿到 A 的版本;A、B 在 2 s 内同改同一条 → 一方 409、拉取后另一方版本进它的 shelf,服务端两次写都基于当前版本(SQL 对拍 seq 链);**A 删 B 不会把 tombstone 抹掉**(SQL 对拍);A 改设置、B 同时在分析 → A 的设置在两台都生效;整表 upsert 重推期间门铃帧数 ≤ 语句数。
- 已知缺口(明示):出站仍是整表哈希差分(#219 的既有成本);**Phase 1 的目标 3 是「没有版本被销毁」**:shelf 是文件 + 日志 + Fix Watch 计数,没有列表界面,用户要捞要走支持路径;列表界面在 Phase 2。

### Phase 2 — 按需,测量驱动
- Mac 合 king、清 JWT、接共享引擎。
- #140 回收站 UI 吃 tombstone + 显式 undelete RPC(解 I6 的锁)。
- per-row outbox:只在 #219 的写放大测量说哈希差分是主项时做。
- settings per-key 合并:只在 shelf 里真出现 settings 冲突时做。
- tombstone purge + 水位线:只在 tombstone 行数成为成本时做。
- people / friendGroups / reminders / customAnniversaries / reports 上 schema 进同一引擎(P4 原内容)。

## 8. 验证策略(独立 QA 循环适用)

- **纯引擎收敛测试**:两个 `EventStore`(隔离存储)+ `FakeServer`(分配 seq、tombstone 改写、无变化短路;不模拟 RLS)+ `FakeGateway`;随机操作序列(含离线编辑、同改同删)后断言 A == B == server 且 shelf 内容 = 所有败方版本(seeded,带正对照和变异体;参考 `reference_test_teeth_structural_traps`)。
- **往返稳定性**:每表一条 `rowHash(xToRowForHashing(rowToX(xToRow(x)))) == rowHash(xToRowForHashing(x))`,否则三方比较的「来件 == 本地」永远不成立。
- **协议测试**:`RealtimeDoorbell` 用 fake transport 回放(已有,29 条)。
- **SQL 对拍**(开发库):两个连接各开事务、先取号者后提交,第三连接的 `sync_changes` 不跳行;DELETE 变 tombstone;活行带 `deleted_at: null` 的 upsert 不撤销 tombstone;内容相同 upsert 的 seq 不变;整表 upsert 一条语句只有一条 `realtime.messages`。
- **装机**:harness 场景「双机 ping-pong」(#197 形态),每一步一条结构化日志。
- **写放大**:apply 只写触碰的 slot;门铃帧数 ≤ 语句数;Fix Watch 计数器 `sync.pull.rows` / `sync.apply.slots` / `sync.conflict`。

## 9. 风险与已知坑

1. **#249 不修,多设备就是在制造 #234**:两机长期在线必毒死 token family。P0 不可跳。
2. **哈希差分与远端应用并存**:apply 必须在同一步里重播触碰行哈希,且顺序是 slot 落盘在前(I3);缺一个就是回声上传。回声上传本身不成环:`rowHash` 排除 `updated_at`,服务端又有无变化短路。
3. **混跑窗口**:旧 build 的 DELETE 已被服务端改写,旧 build 的 upsert 不带 `deleted_at` 也不会撤销 tombstone;旧 build 唯一看不到的是别人的变更(它没有入站)。
4. **iOS 后台**:socket 被杀是常态;正确性全靠前台追平,不靠 doorbell。
5. **Realtime 配额**:每用户每设备 1 连接、前台才连;整表重推 = 语句数帧(235),远低于 100 msg/s。
6. **单行 blob 互相覆盖**:两台设备各改一个 settings 键会进 shelf 而不是互相抹;但用户要手动从 shelf 里捞。接受。
7. **事件类型按 title 合并**:两台各建同名类型 → UUID 不同 → applier 必须按 title 合并否则重复。
8. **`EventStore` 4353 行**:applyRemote 复用级联,不新写。
9. **用户级事务锁**:同一账号的并发写串行化。两三台设备、20 行一块,等待以毫秒计;service_role 一次事务跨多个用户会按遇到顺序取锁,现有 edge function 都是单用户请求。
10. **tombstone 不 purge**:删除的行永久留在表里(内容保留给 #140)。按现在的删除频率,年增量以百计。
11. **门铃两处低优先级瑕疵**(评审 #8):退避梯子在 join 成功后归零,服务端「接受 join 又立刻踢」会以 1 s 间隔重连;token 过期前没有主动推 `access_token`,闲置设备会吃到一次重连。两者都只影响延迟。
12. **BEFORE DELETE 改写在 PostgREST 下的表现**(DELETE 返回 204、0 行,现行客户端 `:1140-1147` 接受)在 P0.3 用现行 king build 实打确认。
13. **账号擦除**:九张表都 `references auth.users(id) on delete cascade`。改写触发器若无角色/深度门,RI 级联的 DELETE 会被改成 UPDATE 并 `return null`,RI 只看 SPI 结果码不数行,结果是 `auth.users` 没了、九张表的 PII 带着悬空 `user_id` 全留下,**静默**(评审二 E1)。门已加(§5.4);P0.3 对拍:删一个测试用户,九表存活行数必须为 0。与 #260 擦除完整性战役直接相关。
14. **启动期本地清理器现在会传播**:`sweepZombieRecurringSeries`、`dedupedByTitle` 这类在本地删行的逻辑,经集合差分变成 tombstone 推到服务端。它们以前也推物理 DELETE,所以不是新行为;新的是远端来的行可能被它们当垃圾。Phase 1 实现前逐个审计「远端来源的行不是 debris」。
15. **旧 build 的批量 DELETE 响 N 下**:`DELETE ?id=in.(N)` 被逐行改写成 N 条嵌套 UPDATE 语句,每条一帧。只在过渡期、只在批量删除时发生;客户端合并后多拉一次。§7 的「帧数 ≤ 语句数」只对 upsert 成立。
16. **ON CONFLICT 下 seq 烧两次**:BEFORE INSERT 臂先取一次号,冲突后 UPDATE 臂再取一次。空洞无害。

## 10. 待拍板

1. D8:第二个免费项目(推荐)还是 Supabase branch。
2. D9:登录即同步(推荐)还是维持 per-device 开关默认 OFF。
3. D7:Phase 1 只接 iOS(推荐),Mac 进 Phase 2。

其余 v0 的决策点(tombstone 保留期、settings per-key 时机、APNs)已在 v1 里用「按需」收掉,不再需要拍板。

## 11. Realtime 协议与配额(实现 `RealtimeDoorbell` 的依据)

见 `Docs/sync/01-realtime-protocol-notes.md`(从 Supabase 文档摘录,含 wire shape)。

## 12. 关联

#21(L1/L2 架构已定,本设计是 L2 的双向化)· #24(守卫:在 I1 + I4 + I6 下大部分自然消解)· #35 · #140(软删 → tombstone)· #151 · #234 / #249 / #250(P0)· #16 / #22(图片)· #219(写放大判据)· `project_donemac_campaign`(Mac Phase 1)

## 13. v1 变更记录(评审第一轮 → 修订与减法)

评审发现(独立 reviewer,`design/realtime-sync @ ea1ffe2`)与处置:

| 发现 | 处置 |
|---|---|
| 取号序 ≠ 提交序,游标跳行 | 用户级 `pg_advisory_xact_lock`(D2 / I5) |
| 逐行门铃撞配额、内容相同的 upsert 仍取新 seq | 语句级触发器;无变化短路 `return null`(D1 / §5.2–5.3) |
| Phase 1 静默丢离线编辑 | 哈希基线三方比较 + shelf,进 Phase 1(D4 / I7) |
| I4 / I6 只是承诺 | BEFORE DELETE 改写 + 保 `old.deleted_at`(§5.2 / 5.4) |
| purge 无水位线会复活 | 不 purge(D3) |
| `row` 是关键字,015 应用不了 | 改名 `data` |
| 基线与数据两个存储无原子提交 | 定死顺序 slot → 基线 → 游标;崩溃窗口的后果被无变化短路吸收(I3) |
| 门铃低优先级瑕疵 | 记入 §9.11,不动 |

减法(相对 v0):`device_id` 列与 Keychain 项、`server_updated_at`、`sync_head()`、purge 与水位线、按编辑时刻 LWW 与 `Event.updatedAt`、per-row outbox 作为固定期、#24 quarantine 门、APNs、Phase 1 带 Mac。原则:每个机制要么有当前消费者,要么有触发它的测量判据。

评审第二轮(独立 reviewer,`design/realtime-sync @ 5982cc6`,对生产库只读核查过关键字表、函数 overload、`($1).col`、policy)与处置:

| 发现 | 处置 |
|---|---|
| 第一轮 #1 / #4 / #5 / #6 / #7 关闭;#2 对 upsert 关闭、对旧 build 批量 DELETE 是 N 帧 | §9.15 记录,接受 |
| C1 并发推送盲覆盖:A 的防抖推送落在 B 的推送之后、A 的拉取之前,B 的版本哪里都不在 | I8:上传带基线 seq,服务端不等拒 409;基线值扩成 `(hash, seq)` |
| C2 自己的回声被当冲突进 shelf | `h_in == h_base.hash → 无事` 放在脏检测之前 |
| C3 event_types 同名不同 UUID 两台都丢 | 胜者 = 最小 UUID,败方永不进基线(§6) |
| D settings 单行 blob 因 `skillAnalyzedEventIds` 永远脏,用户改动被反向覆盖 | settings 按键合并进 Phase 1,该键取并集(§6) |
| D shelf 无消费者 | 明示 Phase 1 目标 3 = 不销毁版本;界面 Phase 2(§7) |
| D 60 s 轮询无测量 | 带 reason 计数,一个 build 内零命中则删(§7) |
| E1 tombstone 改写让账号擦除静默失效 | 角色 + 触发器深度门(§5.4 / §9.13);P0.3 对拍九表清零 |
| E2 本地清理器传播 | §9.14,Phase 1 前审计 |
| `sync_changes` 对 anon 可调 | revoke |
| `drop function sync_head()` 死文本 | 删 |

第二轮认定站得住:用户级锁、`($1).col`、`jsonb - text[]`、自更新后 `return null` 不触发 "tuple already modified"、九表共用一个带 transition table 的函数(plpgsql 按 (函数, 表) 缓存计划)、`security definer` 是必需而非过度、RLS 谓词下 `(user_id, seq)` 索引可用、tombstone 总是胜 + I6 处理「脏编辑 vs 并发删除」正确。
