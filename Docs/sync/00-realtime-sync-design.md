# 全平台单账号实时同步 — 设计 v1.4

日期:2026-10-08(v0)· 2026-10-12(v1,独立评审第一轮后)· 2026-10-14(v1.4,代码勘察后的六个缺口;同日评审第五轮:1 BLOCKER + 6 MAJOR;第六轮:2 BLOCKER + 3 MAJOR + 9 minor——全部改入正文,或在 §13 以 `path:line` 证据驳回;**同日第七轮:本地台架实测**,`done-mcp/supabase/tests/ @ 6f293a8`,S1–S15 全绿、S13 部分,十三条修正改入正文,见 §13 末表)· 基线:king `65fcd7a`(擦除战役已合;本分支 `design/realtime-sync @ 6a7e50b` 仍叉在 `25f8b84`,见 §6.4)/ mac `feat/donemac-phase1 @ d88f783` / Supabase `uqnvtzblppjblwgbpqhf`(PG 17.6)
状态:**设计稿,D7 / D8 / D9 / §10.4 已于 2026-10-14 拍板;015 已应用到本地台架并全绿(§7 P0.3、§8),生产未应用**(v1.4 改了什么见 §13 末尾)。所有「现状」条目均为实测,不是转述文档;标「台架」的指本地 `supabase start` 栈上的 `sync_feed_checks.{sql,sh}` 观测值,不是生产;代码引用形如 `path:line`,均指 `design/realtime-sync @ 6a7e50b`,标 king 的指 `king-of-rubbish-bin @ 65fcd7a`。

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
1. 同一账号在 iPhone / iPad / Mac 上,前台时一端的编辑 ≤ 2 s 出现在另一端。**计时从 A 的上传算起**(A 的 2 s 出站防抖之后,`SupabaseSyncService.swift:24`),不从 A 的编辑算起:防抖是既有出站成本,不在本战役里改。
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
| D7 | 放哪 | **已拍板(2026-10-14)**:共享 Swift `Done/Services/Sync/`;**Phase 1 只接 iOS**;Mac 合 king、清 JWT 字面量后接同一引擎,`MacSyncEngine` 退役 | Mac 分支落后 88 commit 且二进制对后端 401,是独立工作量 | Phase 1 同时带 Mac |
| D8 | 开发环境 | **已拍板(2026-10-14)**:**不建第二个云项目**(免费层项目数上限);本地 `supabase start` 栈是台架(`done-mcp/supabase/config.toml` 入库);015 在台架全绿后**直接应用到生产项目**;DEBUG 对生产仍禁写,DEBUG 模拟器的上传/拉取指向本地栈 | 015 按构造向后兼容(旧 build 的 upsert 不带新列、DELETE 被改写,§5);生产只有 3 个用户;回滚 = drop 三个触发器;14 条迁移重放已实证幂等(#244) | 第二个免费项目(撞项目数上限)/ Supabase branch(要 Pro) |
| D9 | 默认开 | **已拍板(2026-10-14)**:登录即同步。现有 `syncUploadsEnabled` 开关保留为**总闸**,**同时门控上传和拉取**。「默认 ON」的实现 = 启动时 `UserDefaults.standard.register(defaults:)` 注册 true(未设置的键读到 true;用户显式关过的 false 原样保留,**不做一次性迁移写**),`AgentSettingsView.swift:685` 的 `@AppStorage` 字面量同步改 true。`resetAllLocalData` 仍显式置 false(king `AgentSettingsView.swift:884`;键故意不在 `resettableUserDefaultsKeys`,king `ContentView.swift:408`)。**交互式登录成功把键置 true**:`signInWithApple` / `signInWithGoogle` 调 `installSession` 的两个站点(`AuthService.swift:124` / `:212`),**不是** `installSession` 本身(`:938`;刷新成功 `:315` 也走它,不得翻用户的 OFF)。所以擦除 → 静默 → 再登录 → 同步恢复,不需要用户去找开关;代价明示:登录会覆盖之前显式的 OFF,D9 下登录本身就是「这台设备同步」的同意 | per-device 开关默认 OFF 和实时同步语义冲突;总闸不新建,复用已有键(`ContentView.swift:258`、读取 `SupabaseSyncService.swift:392`、界面 `AgentSettingsView.swift:685`);`canUpload` 是 `bool(forKey:)`,未设置即 false,所以「默认 ON」必须有一个实现动作,`register(defaults:)` 是唯一不碰已有值的那个;只写「擦除置 false」而不写谁再置 true,擦除 + 再登录后的 dogfood 机两个方向都不动,看起来就是「同步死了」(评审五) | 维持默认 OFF / 擦除改为删键 |

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
 ├ SyncCursorStore    per-user lastSeq,UserDefaults 键 `syncHashes.<uid>.cursor`,自己读写(丢了 = 必须先全量拉;§6.3)
 ├ SyncPuller         rpc sync_changes → [RemoteChange(table, seq, data | tombstone)];页短于 limit 即 head;
 │                    RPC 前 LocalDataEraseEpoch.capture(),每次落盘前 isStale()(§6.4)
 ├ SyncApplier        EventStore.applyRemote(_:) 单一入口;一页两遍:只读三方比较 + shelf 追加 → 改内存;复用既有级联;
 │                    每页每 slot 一次 persist,拒写 / shelf 追加失败即拒页(§6.1);pending-verify 集合 (table, id, sentSeq, sentHash / sentKeys, pullIssue)(§6 上传形状)
 ├ ConflictShelf      追加式 JSON-lines 文件 Application Support/Sync/,每行带 uid;Phase 1 无 UI(§6.3)
 ├ RealtimeDoorbell   已落(URLSessionWebSocketTask + Phoenix);合并 300 ms → pull;$session → nil 即 stop
 └ Triggers           launch / foreground / reconnect / doorbell / 前台 60 s 兜底轮询;总闸 = syncUploadsEnabled(D9)
```

Edge function 和 MCP 的写入走同样的触发器,所以 agent 改的东西也会响门铃。

**不变量**(每条要有测试或 SQL 对拍):
- I1 **先拉到 head 再推(硬门)**:本 session 至少完整拉过一次且最近一页短于 `page_limit`;游标缺失同样。**被拒的页不计入「最近一页」**(§6.1):那页完整应用并写了游标之前,本 session 不在 head。**推论**:游标在某页停住(§6.1 的 slot 拒写),九张表的上传一起停,不只是那张表——也正因为如此,停页上没写基线的内存行不会被出站 sink 当脏行推出去。**I1 是 flush 时刻的判断,不是调度时刻的**(评审六):applier 拒页时把「本 session 在 head」标志翻成 false;出站 sink 在 2 s 防抖**到期后**(`SupabaseSyncService.swift:24`)才读这个标志——在防抖滴答期间被拒的门铃页,否则会放出没写基线的内存行。
- I2 **应用不回声**:**不靠 `persist(origin:)` 参数**(代码里没有这个参数,`EventStore.swift:1306`,也不加)。做法是 restore 的先例(`RestoreCoordinator.swift:486` → `markRestoreCompleted`):applier 在**同一个 MainActor tick** 里写完 slot 后同步重播触碰行的基线,出站 sink 的 2 s 防抖到期时整表差分已经看不到脏行。`@Published` 数组任何赋值都会触发 sink(这是 `didSet` 的事实,不是可选项),所以 I2 的防线是「防抖到期前基线已更新」,不是「sink 跳过」。
- I3 **落盘顺序 = slot → 触碰行哈希基线 → 游标**,**由 MainActor 上的调用顺序保证,粒度是「每页每 slot 一次 persist」而不是每行**(§6.1):一页先在内存里对全部行做三方比较并改数组,再按固定 slot 顺序对该页触碰的每个 slot 调一次 `persist`(同步、返回 Bool);返回 true(含「磁盘已一致」的 skipped 提交)就立刻写**那个 slot** 的触碰行基线;全部 slot 都 true 才写一次游标;任何一个 false 则后面的 slot 不再 persist、不写基线、游标不动。logs / feedback 的同步 seam 是 `commitLogRecordsNow()`(`EventStore.swift:1648`,取消在途防抖后调纯 saver `saveCalendarEventLogRecords :1815`)和 `saveCalendarEventFeedbackRecords()`(`:1810`);**不得**走 `upsertLogRecord(coalesced:)` → `scheduleLogRecordCommit`(`:1617-1626`,400 ms 防抖 + 2 s 上限):那条路的落盘在游标写完之后才发生,游标领先磁盘,防抖窗口里崩溃丢整页——正是 I3 要排除的失败。**不依赖 `onSlotCommitted`**:skipped 提交不触发它(`EventStore.swift:1352-1356`),挂在它上面的 applier 会在「来件与磁盘相同」的页上永远重拉同一页。中途崩溃只会「多拉一次」或「多推一次内容相同的行」,后者被服务端的无变化短路吸收。
- I4 **服务端抹不掉删除**:DELETE 被改写为 tombstone。是触发器,不是客户端承诺。
- I5 **seq 序 = 提交序**(用户级事务锁):看到 N 就看全了 < N。
- I6 **tombstone 不被普通写入撤销**(触发器保 `old.deleted_at`);撤销是显式 RPC(#140)。
- I7 **冲突不丢字节**:本地脏且来件不同时,败方整行进 shelf。
- I8 **写必须基于当前版本**:更新走 `PATCH …?id=eq.X&seq=eq.<基线 seq>`,服务端 0 行即「过期或内容相同」,客户端拉、合、再推;返回的行 `deleted_at` 非空即「服务端已删」,不是成功(台架 S7:tombstone 行照样命中条件 PATCH,§6 上传形状)。没有它,两台设备在拉/推窗口里会互相盲覆盖,败方哪里都不在。检查放在请求过滤器而不是触发器里:`ON CONFLICT DO UPDATE` 的 `EXCLUDED` 带着 BEFORE INSERT 触发器的修改,触发器里读不到客户端的基线值(评审三 #1)。

## 5. 服务端(migration 015 v4,**已应用到本地台架,台架 S1–S15 全绿**(`done-mcp/supabase/tests/ @ 6f293a8`);**生产未应用** — 全文 `done-mcp/supabase/migrations/015_sync_change_feed.sql`)

五件事,全部幂等:
1. 9 表各加 `seq bigint not null`(先加可空、回填、再 not null,避免整表重写)和 `deleted_at timestamptz`;索引 `(user_id, seq)`。
2. `set_sync_meta()` BEFORE INSERT OR UPDATE 行级:取用户级事务锁 → UPDATE 时保 `old.deleted_at`;去掉 `seq/updated_at/synced_at` 后新旧 JSON 相等则 `return null`(不写、不取号、不响铃)→ `seq := nextval`。**它只保 `deleted_at` 一列**(台架 S7):对已 tombstone 的行做条件 PATCH 仍被接受,其它列照改、取新号、`deleted_at` 原样——服务端不拒绝「写一条已删的行」,拒绝是客户端看响应里的 `deleted_at` 做的(§6 上传形状)。请求体里带 `seq`、带本行自己的 `user_id` 都无害(触发器覆盖 `seq`;同用户 `user_id` 是空操作;改成别人的 `user_id` → 403 `42501`),客户端 PATCH 时不必从行里剥掉 `seq`。**没有**基线版本检查:在 `INSERT … ON CONFLICT DO UPDATE` 里 UPDATE 臂的 `NEW` 来自 `EXCLUDED`,而 `EXCLUDED` 已经带着 INSERT 臂取的新号,触发器里任何 SET 列都不可信是客户端的值。I8 在请求过滤器里做(§6)。
3. `notify_sync_change()` AFTER INSERT / AFTER UPDATE 语句级,`referencing new table as changed`,按 user 聚合 `max(seq)` 发一帧。security definer 是必需的:`realtime.send` 本身是 invoker,以 authenticated 身份插 `realtime.messages` 会被 RLS 拒且被 `realtime.send` 吞成 WARNING,门铃会静默失效。
4. `sync_delete_to_tombstone(key)` BEFORE DELETE 行级:`pg_trigger_depth() > 1` 则 `return old` 物理删除(只有 `auth.users` 的 RI 级联会在深度 2 删这些表,即账号擦除;台架 S6:九表清零、**零门铃帧**,已 tombstone 的行同样物理消失);否则改写成 `update … set deleted_at = coalesce(deleted_at, now()) where key = old.key; return null`。改写后的 DELETE 对 PostgREST 报 0 行:不带 `return=representation` 是 204,带了是 `200 []`,**行此刻已 tombstone 但响应体看不出来**(台架 S2)——客户端永远不从 DELETE 的响应体确认 tombstone,要确认用 `PATCH deleted_at` 形状,它返回行。**不级联到子表**:tombstone 一条父事件不会 tombstone 它的 `event_logs` / `skill_insights`,子行的 tombstone 由客户端级联 + 集合差分上传(§6 events 段)。**不按角色分**:service_role(edge function / MCP)的删除也必须变 tombstone,否则没有 feed 条目、没有门铃,所有客户端留着那行,下一次本地编辑就把它复活(评审三 #3)。以调用者身份跑,RLS 生效。管理员要硬删单行先 disable 该表的 tombstone 触发器;尤其三张按 `user_id` 单行的表,dashboard 上一次 DELETE 会把那个账号的 settings 行永久 tombstone,I6 又挡住重写,Phase 2 的 undelete 之前这个账号再也推不上 settings(评审四 L2)。
5. `realtime.messages` 的 select policy:`realtime.topic() = 'user:' || auth.uid()`(台架 S12:本人 JWT join 自己的 topic ok、插入后 5 s 内收到 `{table, seq}` 帧;A 的 JWT join `user:<B>` 被拒、B 的插入零帧漏到 A——**本地栈默认即强制私有**,dashboard 的「Allow public access」只管公开 channel,生产上关掉是纵深防御不是前置,§9.32)。`sync_changes(since_seq, page_limit)` security invoker,九表 union 按 seq 返回 `(tbl, seq, data jsonb)`;对 `public` / `anon` revoke execute(台架 S10:用户 JWT 200、只有本人的行、按 seq 升序、短页即 head;仅 apikey 拒;events 臂以 authenticated 身份走 `idx_events_user_seq`,`Index Cond: user_id = auth.uid() AND seq > since`,4k 行上一页 50 行 0.34 ms)。

**向后兼容**:旧 build 的 upsert 不带新列,触发器补 seq;旧 build 的 DELETE 变 tombstone;客户端只发 `Prefer: resolution=merge-duplicates`(return=minimal),被 BEFORE 触发器丢掉的无变化行对它不可见。`updated_at` 列不再有服务端语义。**状态码**(台架 S3 / S4 / S11):PostgREST 只在 merge-duplicates POST **真的插入了**时回 201;命中已有行的 upsert、被 BEFORE 触发器短路的内容相同 upsert 都回 200。任何处理 upsert 状态码的地方写 2xx,不写 201。king 的三种形状在台架上照常:upsert 201、`DELETE ?id=in.(…)` 204、Restore 的 `GET … Range` 200——但最后这个**把 tombstone 行一起返回**,king 的 Restore 会把它们当活行带回本地,直到 `fetchAll` 的 `deleted_at=is.null` 过滤随 Phase 1 出货(§6 Restore 路径、§7 P0.3)。

## 6. 应用远端变更(最难的一段)

`EventStore.applyRemote(_ batch: [RemoteChange]) -> ApplySummary`,**唯一**入口。对每条来件 `(table, id, data | tombstone)`:

```
h_in   = rowHash(来件经 rowToX → xToRowForHashing)      // 往返稳定性每表一条测试
h_loc  = rowHash(本地行)  或 absent
h_base = 哈希基线[id]     或 absent                      // 基线值 = (hash, seq):hash 判脏,seq 随下次上传送回(I8)
dirty  = h_loc != h_base.hash

seq == h_base.seq     → 这个服务端版本已经处理过(重拉同页:§6.1 的停页重发、I3 的崩溃后多拉一次),跳过;
                        每个分支都写 base.seq,所以这是充分判据,也是 dirty 分支不把同一来件重复写进 shelf 的唯一防线
来件是 tombstone      → 本地 absent 则无事;否则走现有删除级联(不 purge 图片资产);dirty 则本地版本先进 shelf(第一遍,§6.1);基线移除 id
h_in == h_base.hash   → 无事,只更新 base.seq(这是我们自己推上去的版本回声,或别人推了同样内容)
h_in == h_loc         → 无事;基线[id] := (h_in, seq)
!dirty 或 本地 absent → 按 id 替换 / 插入;基线[id] := (h_in, seq)
dirty                 → 本地保留;来件整行进 shelf;log sync.conflict;基线[id] := (h_base.hash, seq)(hash 不动保持脏,seq 更新让下次上传能通过 I8);
                        基线缺失(本地新建、POST 回应丢了、基线文件丢了)时 := (h_in, seq),否则下次推送又走 POST、又被忽略、永远推不上去(评审四 M1)
```

**上传形状(Phase 1 改动的唯一 HTTP 面)**:
- 基线里有 seq 的脏行:逐行 `PATCH /t?id=eq.X&seq=eq.<base>`,`Prefer: return=representation`。返回 `[row]` 且 `row.deleted_at` 为空 → 基线[id] := (**hash(本地送出的行)**, row.seq),不必等回声;返回 `[]` → 过期**或内容相同**(服务端无变化短路 `015:90-92` 的 `return null` 也不返回行,seq 不动)。**只按响应体判断,不按状态码**(三种都是 200);不要用单对象 `Accept`,0 行会变 406(台架 S7 确认)。三张按 `user_id` 单行的表过滤器是 `user_id=eq.<uid>&seq=eq.<base>`(没有 `id` 列)。
- **第三种响应:`[row]` 且 `row.deleted_at` 非空 = 服务端已删**(台架 S7,v1.4 初稿没有这一支):I6 只保 `deleted_at` 一列,所以一条本地脏、服务端已被另一台 tombstone 的行,条件 PATCH 照样命中——取新号、内容写进去、`deleted_at` 原样返回。这**不是成功**,是客户端此刻才得知的一条 tombstone,处置与拉取时遇到 tombstone 来件完全相同(§6 三方比较的 tombstone 分支):本地脏版本先进 shelf,本地行走删除级联(`unlinkAssets: false`),基线移除 id;**不写** `(hash, seq)` 基线、不把它当「已上传」。对三张 `user_id` 单行表这是永久态(直到 #140 的 undelete RPC):它们的行一旦 tombstone,每次 PATCH 都会「成功」地回一条 `deleted_at` 非空的行,客户端若只看行数就会无限次把设置写进一个死行;所以 `deleted_at` 检查在 `[row]` 分支的第一行,不是可选项。顺带的后果:这次 PATCH 在服务端留下了一个新 seq 和一份已删行的新内容,无害——其它设备拉到它仍是 tombstone(`deleted_at` 非空),走各自的 tombstone 分支。
- **`[]` 的收口(v1.4,勘察缺口 2;评审五 BLOCKER 后重写)**:客户端维护一个**内存里的 pending-verify 集合**,元素是 **`(table, id, sentSeq, sentHash, pullIssue)`**:`sentSeq` = 这次 PATCH 过滤器里送出的基线 seq;**`sentHash` = 送出的那一行的 hash**(flush 建 PATCH 时已经算过,就是它准备在 `[row]` 响应后写进基线的那个值,不是新算的;`user_settings` 的元素带的是送出 blob 的**每键 hash 表 `sentKeys`**,因为它的基线是 `{seq, keys}` 没有行 hash,§6.3;agent_preferences / agent_conversations 是整行,只带 `sentHash`);`pullIssue` = 收到 `[]` 响应时引擎的拉取发号计数(每次发出 `sync_changes` RPC 前 +1 的内存整数,引擎本来就要为「取消在途拉取」持有它)。一次拉取多页、多次 RPC,**「这次拉取的号」= 返回短页的那次 RPC 的号**:按 I5,任何让这次 PATCH 过期的 seq 都大于更早页的末 seq,所以用末页号判资格是正确的(用首页号也安全,只是把清理推迟一轮)。收到 `[]` → 入集合,触发一次拉取。**只有发号晚于 `pullIssue` 的拉取**(RPC 在 `[]` 响应到达之后才发出)才能清这个元素;更早发出的拉取即使到 head 也不碰它——它的服务端快照可能早于让这次 PATCH 过期的那笔写。有资格的拉取到 head(最后一页短于 `page_limit`)时:**本次拉取见到的** `(table, id)` 走正常三方比较(脏 → 冲突进 shelf、`base.seq := seq`),元素出集合,下次 flush 用新 seq 重新 PATCH;**没见到的**,再查 `基线[(table, id)].seq == sentSeq`:**相等** → PATCH 建立之后基线没动过、服务端也没取新号(取了就会落在 `seq > cursor` 里被见到),所以是服务端把一次内容相同的写短路了 → `基线[(table, id)].hash := sentHash`(`user_settings`:`keys := sentKeys`),**绝不从当前本地行重算**,出集合,下次差分只对 PATCH 之后的新编辑判脏;**不等** → 基线在 PATCH 在途期间被一次拉取改过(来件已按 dirty 分支进了 shelf、`base.seq` 已是新号),这次 `[]` 是过期不是相同 → 只丢掉元素、**hash 不动**,下次 flush 用当前 seq 重新 PATCH。键是 `(table, id)` 而不是 id:三张单行表的 id 都是 uid,按 id 会让 user_settings 的回声清掉 agent_preferences 的标记而不做比较、不重设 hash,那行保持脏 → PATCH → `[]` → 每 2 s 重标,一行版的风暴。**没有额外 GET,没有重试计数**;集合不落盘,进程死了下次 flush 的 `[]` 会重新标。

  被评审五用算术证伪的旧规则(「任何到 head 的拉取都清、没见到就是相同」)有两种家常交错(一个 MainActor 上 flush 对最多 8 路并发 PATCH 逐个 await、拉取 300 ms 合并,两者并存是常态):(i) A 把 X 改成 c1(基线 (h0, s0)),B 已把 X 写成 (c2, s1);A 的 60 s 轮询 P1 在 s1 提交前发出、响应仍在路上;A 的 flush PATCH `seq=eq.s0` → `[]`;P1 到 head 且没见到 X → 旧规则把基线设成 (h1, s0) → 下一次拉取见到 X@s1 时 `!dirty` → 本地 X 被 c2 覆盖,**c1 在任何设备、服务端、shelf 都不存在**(目标 3 违反)。新规则:P1 发号早于 `[]`,无资格;P2 见到 X@s1 → dirty → c2 进 shelf、`base.seq := s1` → 下次 flush 以 s1 重推 c1,服务端是 c1、B 随后拿到 c1、c2 在 A 的 shelf——设计本来要的结果。(ii) flush 读到 base.seq = s0 并建好 PATCH;请求到达服务端之前,一次拉取按 dirty 分支应用了 X@s1(base := (h0, s1),c2 进 shelf);PATCH → `[]`;之后的拉取什么都看不到(s1 ≤ 游标),旧规则「没见到 ⇒ 服务端 seq == 基线 seq」此时为真(都是 s1)但写是过期不是相同 → hash := h1 → **c1 被标干净、永不上传**,A/B 静默分叉到 A 下次再改 X(目标 2 违反)。新规则:`base.seq (s1) ≠ sentSeq (s0)` → 丢标记、hash 不动 → 下次 flush 以 s1 重推。(iii)(评审六 BLOCKER,`sentHash` 的来历)基线 (h0, s0),本地 c1,PATCH → `[]`(内容相同,例如改了哈希编码的 build);清标记要等一次有资格的拉取到 head,13k 行的账号按 `page_limit` 500 是 27 次 RPC(`015:245-272`),以秒计;窗口里用户又把 X 改成 c3。到 head、X 没见到、`base.seq == sentSeq` 都成立,但此刻实现者手里只有**当前**本地行:若从它重算 → `base := (h3, s0)` → c3 判干净、永不上传,服务端停在 c1,A/B 静默分叉到下次再改 X(目标 2,与 (ii) 同一失败类)。`sentHash` 是元素里的一个字段、不落盘,清标记写 `h1` 而不是 `h3`,c3 照常判脏、下次 flush 以同一 seq 重 PATCH(服务端是 c1,seq 未动,PATCH 命中,c3 上去)。§8 的第三条变异体「从活行重算」必须红。

  它封住的场景是 §6 下文的「某个 build 改了每一行的哈希编码但没改服务端值」(例如 `eventToRow` 新增一个值为 NSNull 的键、或某个标量的 `String(describing:)` 渲染变了,`rowHash` 在 `SupabaseSyncService.swift:267-302`):13k 行每一行 PATCH → `[]` → 拉取看不见 → 仍脏 → 2 s 后再 PATCH,**每轮 13k 次请求的静默风暴**。§9 第 2 条原先只论证了「干净行的回声不成环」,没有覆盖「脏行被短路」这一支;v1.4 起 §9.2 以本条为准。
- 基线里没有 seq 的行(本地新建、尚未得到服务端回应):批量 `POST`,`Prefer: resolution=ignore-duplicates, return=representation`。响应里有的 → 基线 := (hash(本地行), seq);响应里没有的 → 服务端已有这行(上次推送成功但回应丢了),等回声拉取补基线后走 PATCH(台架 S8:响应恰好是插入的那些行、都带 seq,已有行的 seq 与内容不动;状态码按 2xx 处理,见 §5「状态码」)。永远不用 `merge-duplicates` 盲覆盖。响应里没有、下一次拉到 head 也没见到的 id 记一条 `sync.push.orphan` 日志:唯一索引是全局的,别人账号下的同 UUID(跨账号 restore)会被 DO NOTHING 静默吞掉(评审四 L1)。
- 删除:`PATCH /t?id=in.(…)&deleted_at=is.null` 置 `deleted_at = now()`,可批量,`Prefer: return=representation` 时返回被盖戳的行、客户端时间戳原样入库、第二次同样的 PATCH 回 `[]`(台架 S9)。**tombstone 只从这个形状的响应确认**:改写后的 `DELETE` 即使带 `return=representation` 也回 `200 []`,行其实已经 tombstone 了(§5.4),响应体里看不出来。请求体里带 `seq` 无妨(§5.2)。
- 典型一次编辑 = 1 到几次 PATCH(每表每 2 s 最多一次 flush,上限约 90 req/min,实际 5 到 15)。Restore 合并**不**造成大批量:`markRestoreCompleted` 会重播基线,只有 keepLocal 的碰撞行变脏。真正的大批量是「某个 build 改了每一行的某个同步值」(006 / 014 迁移的先例):主用户 4791 events + 7836 skill_insights + 618 logs ≈ 13.2k 行,串行 PATCH 按 150 ms 一次约 33 分钟,用户自己的编辑排在后面。**Phase 1 要求 8 路并发上限**(≈ 4 分钟),并把 `sync_push(rows jsonb, base_seqs bigint[])` RPC(以参数而不是列传基线,绕开 `EXCLUDED`,一次批量、逐行返回结果)列为 Phase 2 的逃生口,触发判据 = 真发生过一次这种 build。这种 build 若只改了哈希编码没改服务端值,13k 次 PATCH 全部 `[]`,靠上面的 pending-verify 规则一轮收口,不会每 2 s 重来。基线丢失不触发整表重推:I1 先全量拉,拉完就是干净的。

基线 hash 在上传成功时写入,值是**本地送出的行**的 hash(现有行为 `SupabaseSyncService.swift:1115-1176`,不变);v1.1 起连 seq 一起写,**只有 seq 来自响应体**。拿响应体算 hash 是错的:响应带 `seq`、`deleted_at` 和服务端规范化后的值,hash 永远不等于本地 `eventToRow`,每行永远脏,每 2 s 一次 PATCH → `[]` → 拉 → 无事 → 再来,静默死循环(评审四 H1)。

**顺序敏感**:`h_in == h_base.hash` 必须在脏检测之前。否则 A 推 v1 后 0.5 s 内改成 v2,v1 的回声会被当成冲突进 shelf(评审二 C2)。

- **events**:tombstone 走 `deleteCalendarEvent`(`EventStore.swift:2621`)/ `deleteRecurringCalendarEvent(scope: .all)`(`:2873`)**同一套级联**(interrupt 子事件孤儿化、被吸收 todo 释放、log / feedback 剪枝),**新增参数 `unlinkAssets: false`** 跳过第 4 步 `commitStagedAssetDeletion`(`:2577`):图片资产不因远端 tombstone 而 purge(另一台设备可能还要用它,`ImageBackupCoordinator` 自有生命周期)。todo 的 tombstone **绕过 `stopTimerOnCalendarEvent`**(`:3664`,它会触发 `onCalendarEventRecordCompleted` → LLM 分析)。远端**插入 / 更新绕过 `addCalendarEvent` / `updateCalendarEvent`**(`:2492` / `:2499`,两者都触发 `onCalendarEventRecordCompleted` 与 `calendarEventRecorded`,即 SkillAnalysis 与 TokenInference 的 LLM 入口;远端来的行不是本机的新完成,不得触发推断,#182 的八个入口门禁不扩),直接写数组 + `saveCalendarEvents(refreshInterrupts: true)`(`:1982`)+ 各纯记录 saver。不得新写一套删除语义——#140 已记 `rawCalendarEvents` 144 处消费者的教训。**子行的 tombstone 是客户端的义务**(台架复核,`1d8c830` 评审):015 不级联——父事件 tombstone 后它的 `event_logs` / `event_feedback` 在服务端仍是活行;把它们 tombstone 的是本地删除级联(第 3 步剪 log / feedback)之后出站的集合差分(`diffSync` 把「上次哈希表里有、这次数组里没有」的 id 发 `PATCH deleted_at`,§1.1 / D6),远端来的 tombstone 也走同一条级联,所以两台设备都会各自推一遍子行 tombstone,幂等。在那之前,服务端读取面(`api` / `mcp` / `snapshot` 边缘函数、`done-mcp/src`,`1d8c830` 起全部 `deleted_at is null`)**仍会返回一条已删事件的 log**;窗口 = 删除到下一次 flush 之间,以秒计,接受,不在服务端建级联触发器(它会把 §5.4 的 `pg_trigger_depth` 门和 §9.17 的锁序一起复杂化)。`skill_insights` 不在任何级联里(没有 event id,§9.18),已删事件的 insight 在两端都留着——今天就如此,不是同步引入的。
- **recurring**:父 tombstone → 现有级联处理实例;detached 实例更新 = 普通行更新;day-key 身份照 migration 014 规则。
- **event_logs / event_feedback**:identity = `CalendarOccurrenceKey` 编码,沿 `decodeOccurrenceKey`(`SupabaseSyncService+Restore.swift:518`);同样走三方比较(它们有 `updatedAt`,但不另开规则)。**事件本地不存在的 log / feedback 行仍按 key 插入**:`upsertLogRecord` / `upsertFeedbackRecord`(`EventStore+OccurrenceRecords.swift:128` / `:38`)在 `occurrence.eventID` 不在 `rawCalendarEvents` 时静默丢弃,而 `sync_changes` 按 seq 交错九表、不保证事件行先到;applier 直接写记录数组,落盘走 `commitLogRecordsNow()` / `saveCalendarEventFeedbackRecords()`(§4 I3 点名的同步 seam,不走 coalesced 防抖)。**id 不需要编码规则**(台架 S9):含 `|` 和字面 `none` 的 occurrence-key id,原样 / 百分号编码、`in.()` / `eq.` 四种写法 PostgREST 全部接受,tombstone PATCH 用原样 `in.()` 命中两行;`SupabaseSyncService.swift:137-138` 今天不编码,保持。**时区先行**:见 §6.2。
- **event_types**:本地按 title 合并(`dedupedByTitle` 保留先到者)、wire 按 UUID。两台各建同名类型会得到两个 UUID;若 applier 只按 id 插入,本地去重会丢掉其中一个,集合差分再把它 tombstone,对称发生在另一台上,两台都失去这个类型(评审二 C3)。规则:同 title(按 `normalizedTitle`,`EventTypeTemplateStore.swift:593`)不同 UUID → 胜者 = 小写 UUID 字符串字典序最小者,由 applier 自己判(不能复用 `dedupedByTitle` 的「先到者」);**败方 UUID 永不进基线**;本地持有败方 → 本地换成胜者的行(`Event.type` 是 title 字符串,`Event.swift:257`,事件不需要改指向;只有 `colorHex` 之类取胜者的)并 tombstone 败方;来件是败方 → 不插入,同样 tombstone 它。两台都做,幂等,所以败方不会因为持有者再也不上线而永远活在服务端。
- **user_settings**:**按键三方合并,进 Phase 1**。理由由代码直接给出:`skillAnalyzedEventIds` 在 `SyncedSettings` 的同步键里,`SkillInsight` 每次分析都写它,每台设备独立增长,所以整行 blob 在两台设备上几乎永远同时脏;整行规则下用户在 A 改一个设置,会被 B 的 blob 反向覆盖到两台(评审二 D)。按键规则:键 = `settings` jsonb 的顶层键,值是字典的键整体比较;缺键是一个值(nil),一侧删键另一侧没动 → 删键传播;每个键各自 `(in, loc, base)` 三方比较,只一侧改的取那一侧,两侧都改的本地胜、远端值进 shelf。这张表的基线是「每键 hash + 行 seq」,不是行 hash;从今天单行 hash 升级的规则:旧行 hash == hash(本地行) → 每键基线 := 本地各键 hash(本地干净);否则旧行 hash == hash(远端行) → 每键基线 := 远端各键 hash(远端就是本机上次的上传,差异全是本地改动,取本地,不进 shelf);两者都不等 → 基线为空,所有不同的键按冲突处理(本地胜、远端进 shelf),不丢任何一方,但本机没碰过的陈旧键会压过对方的新值并在下次 PATCH 时推回去,这一次性代价在此明示(评审四 M4)。`skillAnalyzedEventIds`:两侧都非 nil 取并集(丢了会触发重分析和 LLM 开销);一侧 nil 且基线非 nil = 显式删除,传播。真正的「清空」是 `SkillInsightStore.clearAll()`(`SkillInsight.swift:102-107`),它同时清空 insights 数组并删掉这个键:在同步下含义变成「这个账号的 insights 全部 tombstone、所有设备重新分析」,这是单账号语义的自然结果,但 LLM 开销乘以设备数。**已拍板(§10.4,2026-10-14):清空 = 全账号**,它是并集 / nil 规则的自然推论,不另建任何机制。`occurrenceKeyReferenceTimeZoneIdentifier` 这个键**不走**上面的通用按键规则,见 §6.2。
- **agent_preferences / agent_conversations**:整行三方比较;出现真实冲突再按键化。**既有缺陷,Phase 1 出站切片必修**(台架 S13,与 015 无关):`encodeJSONOrNull`(`SupabaseSyncService.swift:1308-1316`)对空数组送 `null`,而 `agent_preferences.rules` / `decision_history` 是 `jsonb not null`(migration 009 `:21-22`)→ 零规则或零决策的用户每次 upsert 都是 400 `23502`,这一行从未上传过;显式 `[]` 则 2xx。改法:这两列空数组送 `[]`(只改这两列的调用点,其它可空列的 `null` 语义不动),读侧继续把 `[]` 当空。这是 harness「A 改设置 B 生效」能过的前置之一,因为今天的默认用户就是零规则。
- 写入走既有 `persist`(同步、返回 Bool),每页每触碰 slot 一次;返回 true 后在同一 tick 内写该 slot 的基线,全部 slot 成功后写一次游标(I2 / I3 的措辞以 §4 为准,粒度以 §6.1 为准)。
- 客户端自己的删除:`PATCH … ?id=eq.X&deleted_at=is.null` 置 `deleted_at = now()`,只对还活着的行,避免重复盖戳造成无意义的新 seq;确认看响应里的行,不看 DELETE(§5.4)。
- 派生状态(occurrence 缓存、搜索语料、widget 快照)沿现有 `didSet` / `scheduleWidgetSnapshotSync` 刷新,不另开路径。
- **示例数据**:`EventStore(storage:)` 的 `seedsSampleDataIfEmpty` 默认 true(`EventStore.swift:800`、`:921`),空库种 10 条演示事件(`seedSampleCalendarEvents :1175-1219`,随机 UUID,经 `addCalendarEvent` 落盘);`.wiped` 信封同样可种。两条规则:(1) `DoneApp.swift:629` 构造生产 store 时,**只要存在已持久化的会话就传 `seedsSampleDataIfEmpty: false`**——它只覆盖「构造时已登录」的设备。(2) 常见顺序是**首启(无会话)→ 种子 → 登录**(仓库里没有登录墙),这些行在 I1 拉到 head 后基线缺 seq → 按上文走 `POST ignore-duplicates` → 进账号、传到 A 和以后的 Mac(评审五);所以种子器把种下的 `{id: fingerprint}` 写进 UserDefaults 键 `sampleSeed.eventHashes`(键进 `resettableUserDefaultsKeys`),引擎在**本 uid 游标缺失的第一次拉取之前、第一次 flush 之前**删掉仍是「未碰过的种子」的行,然后删键。**指纹 seam(评审六 MAJOR)**:`rowHash` 是文件级 `private`(`SupabaseSyncService.swift:267`),`eventToRowForHashing` 是 `private` 实例方法(`:1220`)且投影含 `"user_id": userId`(`:1262`);种子器跑在 `EventStore.init`(`:921`),没有 sync service、没有会话,所以「用出站同一投影」在种子时刻算出的是 `user_id = ""`、在检查时刻是 `user_id = <uid>`,每条种子都判「改过」——规则整个是空操作,harness 的「第一次 flush 推 0 行」直接红。Phase 1 交付一个 **`static func SupabaseSyncService.seedFingerprint(_ event: Event) -> String`**,= `rowHash(eventRowHashableFields(event, kind: "calendar") 去掉 "user_id" 键)`,投影函数和 `rowHash` 为此从 private 实例升为 Models 可调的 static(`userId` 变成参数,`eventToRow` / `eventToRowForHashing` 改为调它,投影仍是单源);种子时刻与检查时刻调的是同一个 static,`kind` 固定 `"calendar"`(种子只种 `rawCalendarEvents`,`:1175-1219`)。**可删条件(三条同时成立,评审六 BLOCKER)**:(1) `seedFingerprint(本地行) == 种子指纹`;(2) `calendarEventLogRecords` / `calendarEventFeedbackRecords` 里**没有** `occurrence.eventID == id` 的记录——完成状态、笔记、情绪、行为、反馈全都只写进这两个记录数组(`upsertLogRecord`,`EventStore+OccurrenceRecords.swift:128-168`:改记录、`updatedAt`、append;`Event` 行不动,只有 effort 经 `scheduleCalendarEventColorDepthMirror` 镜到 `Event.colorDepth`,`:160-168` / `EventStore.swift:1540`),所以「行 hash 未变」**不是**「用户没碰过」:首启 → 打开 Morning Focus 标完成、写一条笔记 → 行 hash 未变 → 登录——只看 hash 会删掉这行,而 `deleteCalendarEvent` 级联第 3 步会剪掉它的 log / feedback(`pruneLogRecordsForDeletedCalendarEvent`,`EventStore+OccurrenceRecords.swift:559-564`),用户的笔记在第一次 flush 之前就没了;`RestoreCoordinator.swift:226-229` 早已把 logs / feedback 定为 `rawCalendarEvents` 给不出的「用户交互过」信号;(3) **不是 interrupt 父事件**(没有任何行的 `interruptRelation.parentEventID == id`)。**删除动作 = 数组移除 + 一次 `saveCalendarEvents(refreshInterrupts: true)`,不走级联**:按构造没有任何东西挂在它上面(条件 2、3 保证),级联在此只会多做三次 slot 提交;也不得「绕过级联但留下记录」——那会上传一条事件不在服务端的孤儿 log。条件任一不成立的演示行**保留**并照常上传,它的 log / feedback 也照常上传——那已经是用户内容,Data Preservation 不丢。harness 断言:新机登录后第一次 flush 推 0 行;改过一条演示行则恰好推那一行;**未改行上写一条笔记 → 行保留、行与 log 都上传**。`offerAutoRestoreIfNeeded`(`ContentView.swift:612-620`;`shouldOfferAutoRestore` 只看 todos / logs / feedback,`RestoreCoordinator.swift:230-235`)在 Phase 1 **退役**:空设备登录后 I1 的第一次拉到 head 做的就是它做的事,不再弹 sheet(`hasOfferedAutoRestore.<uid>` 键家族随它删,king 擦除里按前缀扫这个家族的那一行 `AgentSettingsView.swift:992` 一并删;`EraseWiringQATests` 的字符串断言不含这个前缀,king `65fcd7a` 全文 grep 为零,不会漂);手动 Restore 保留,给非空设备选 merge / replace。
- **`dominoPushTodosPastHorizon`**(`EventStore.swift:502`)在两台设备上各自改写过期 todo 的 timeRange,互相当成远端变更。**Phase 1 接受**:两台算的是同一个 horizon 日,行内容收敛;代价是每个日界各多一次 `sync.conflict`(§9.22),用该计数器实测,超出预期再改。
- **Restore 路径**:`fetchAll`(`SupabaseSyncService.swift:175`)的查询追加 `&deleted_at=is.null`,否则 015 之后 restore 会把 tombstone 行当活行插回本地(台架 S11 实测:king 形状的 `GET … Range` 把 tombstone 行一起返回)。这意味着 015 应用到生产之后、Phase 1 build 装机之前,**现行 king 的 Restore 会把删过的行带回本地**;窗口期不按 Restore,或接受再删一次。

### 6.1 slot 拒写与单游标(v1.4,勘察缺口 3;评审五后定粒度)

`persist` 对冻结 slot 返回 false 不抛(`EventStore.swift:1310-1313`,`isSlotFrozen` = `storageFaults[slot] != nil`,`:1128`;**不**进 `writeFailedSlots`);`calendarLogGenerationUnproven` 在 `commit` 里抛、被 `persist` 的 catch 吞成同一个 false(`DurableEventStorage.swift:1417-1420`、`EventStore.swift:1358-1362`)。applier 的粒度与规则:

- **粒度 = 每页每 slot 一次 `persist`**,不是每行(§8「apply 只写触碰的 slot」的唯一一致形状;一页 500 行 events 逐行 `persist` 是 500 次整 slot 提交)。表 → slot 的映射是静态的;tombstone 走删除级联,级联固定触碰 calendarEvents + logs + feedback 三个 slot 并自带保存,一并算进「该页触碰的 slot」。「停在该页第一条被拒写的行」这种说法在这个粒度下没有意义,v1.4 初稿的措辞作废。
- **预检(冻结)**:应用一页之前,先对该页触碰的每个 slot 查 `isSlotFrozen`(event_types 查自己的 fault 域 `areTemplatesFrozen`,与 `eventTypeExportSuppressed`(`SupabaseSyncService.swift:1057`)对称);任一冻结 → **整页拒绝**:不做三方比较(冻结 slot 的内存数组是空的或陈旧的,`:1080-1087`,拿它当「本地状态」会把每一行判成新增、每条本地行判成已删)、不改数组、不写基线、不写游标。
- **一页两遍;shelf 追加是比较阶段的持久写**(评审六 MAJOR):第一遍**只读**——对页内每行做三方比较、得出决定,把每个败方版本(dirty 分支的来件行、tombstone 分支的本地脏行)**此刻**追加进 shelf,`isStale()` 紧挨每次追加(§6.4);第二遍才改内存数组、走级联。**任何一次追加失败(ENOSPC、`/dev/null` 回退、isStale)→ 整页拒绝**,与冻结预检同形:不改数组、不写 base.seq、不写游标,`sync.apply.refused slot=shelf seq=…`。理由是算术:让 `persist` 失败的那个条件(满盘)同样让 shelf 追加失败,而 shelf 是败方版本的**唯一**副本——tombstone + dirty 下若先级联再发现 shelf 没写上,`deleteCalendarEvent` 第 1 步已把 X 移出 `rawCalendarEvents`、第 2 步 `saveCalendarEvents` 返回 false(前一份文件完好,`EventStore.swift:2630-2655`)、页被拒、游标不动;下一次拉取 tombstone X@s1 对上内存里已不在的 X → 「无事」;下一次任何成功的日历保存把内存写到盘,X 离开磁盘,c1 不在 shelf、不在任何设备、不在服务端(目标 3)。update + dirty 下 shelf 静默失败、dirty 分支照写 `base := (h0, s1)`,A 的 flush PATCH(c1, seq=eq.s1) 赢,B(干净)采用 c1,c2 哪里都不在。追加前按 `(uid, table, id, seq)` 去重:停页重拉时,没写上基线的 slot 的行会再次走 dirty 分支(它的 `base.seq` 没更新,`seq == base.seq` 不触发),同一来件会第二次到达 shelf,去重让它幂等而不是多一行。
- **提交时拒写(unproven、I/O 失败)**:三方比较已经改了内存,按固定 slot 顺序 persist;**已返回 true 的 slot 保留它的基线更新**(那些行已落盘、基线与盘一致,重拉时按 §6 的 `seq == base.seq` 跳过);返回 false 的 slot 以及它后面的 slot 不写基线;**游标不动**。内存领先磁盘的 slot 和一次普通保存失败后的状态完全相同(`writeFailedSlots`、横幅),由下一次成功保存或重拉落地;重拉时这些行 `h_in == h_loc`,该 slot 仍被 persist 一次(delta 路径对已一致的盘是 skipped 提交 → true,对落后的盘是真写)。**级联的结果怎么观察**:两条 delete 级联返回 Void,但它们只在自己的 `saveCalendarEvents` 返回 true 之后才剪 log / feedback(`EventStore.swift:2630-2655`),所以级联失败留下的是「磁盘 ≠ 内存」;而 delta 路径的 skipped 提交要求磁盘等于**最后一份确认落盘的数组**(`:1340-1356`),于是该页末尾对 calendarEvents 的那次 `persist` 必是一次**真写**,它的 Bool 就是信号——看这个返回值,**不要**去读 `writeFailedSlots`(冻结拒写根本不进它,`:1310-1313`)。级联失败而页末 persist 成功的组合里,那条事件的 log / feedback 留在本地到下一次删除扫掉(级联注释里的既有语义),不上传(它们的事件行已 tombstone,出站差分看不见新脏行)。没写基线的内存行不会被出站 sink 推出去:页被拒则 session 不在 head,I1 挡住所有上传。
- 两种拒绝都:每次拉取记一条 `sync.apply.refused slot=… seq=<该页首行 seq>`,不是每行一条;**被拒的页不计入 I1 的「最近一页」**。
- 后果直说:单游标跨九表(D2 否决了 per-table 游标,v1.4 不重开),所以**九张表都停止应用**,又经 I1,**九张表的上传也停**,直到用户确认的 restore / 擦除解冻(设备此时本来就在 `persistenceDegraded` 横幅状态,`ContentView.swift:682`)。`calendarLogGenerationUnproven` 只由下一次 `.reconcile` / `.fold` 读释放(`DurableEventStorage.swift:1045`;`loadCalendarRecordsForRead :1102-1104`,从 `:710` 调),所以它造成的停顿持续到**下一次 log 读,最坏到下次启动**,不是「只有一次拉取」。
- **applier 永远不清 fault**。解冻的两个站点(`applyRestore :4082-4084`、`clearAllLocalData :1851-1853`)都是用户确认路径;冻结 slot 的内存数组是空的或陈旧的,自动解冻后下一次普通保存会把这份空写到最后一份可读副本上(`:4076-4081` 的理由对远端应用同样成立)。出站侧 `exportSuppressed`(`SupabaseSyncService.swift:1040`)早已按同一逻辑整表压制。

### 6.2 参考时区键(v1.4,勘察缺口 4)

`occurrenceKeyReferenceTimeZoneIdentifier` 在 `SyncedSettings.allKeys` 且是 bridged 键(`SyncedSettings.swift:125`、`:138-141`);每台设备在第一次 mint dayKey 时冻结**自己**的时区(`OccurrenceKeyMetadataStore.swift:120-145`),而 `applyRestoredIdentifier`(`:243`)会无条件覆盖已建立的时区——注释写明它是**用户确认路径专用**。按 §6 通用按键规则走的话:B 新机在第一次拉取前 mint → B 的时区进基线 → B 推上去 → A 看到「只有远端改了」→ A 采用 B 的时区,而 A 的所有 series 记录都是 A 时区的 dayKey——这就是 `OccurrenceKeyMetadataStore` 文件头描述的损失,由同步送达。规则:

- **账号上先建立者胜**。applier 采用远端值的条件 = **本地没有任何锚在本地时区下的记录**:`calendarEventLogRecords` / `calendarEventFeedbackRecords` 里没有 `occurrence.baseSeriesEventID != nil` 的行(single 事件的 wire id 不含 dayKey,`encodeOccurrenceKey :1494`,换时区不改身份;本地身份同样:`CalendarOccurrenceKey ==` 对 single 事件不比 dayKey,`CalendarEventFeedback.swift:143-168`,所以只持有 single 记录的设备采用账号时区不会孤儿化任何本地记录——采用条件的安全性就立在这一行上,评审六核实)。**不是** `.fresh`(评审五):`CalendarOccurrenceKey.make` 对 single 事件也读 `referenceCalendar`(`CalendarEventFeedback.swift:346-353`),每次日历查找都调它(`feedbackRecord(for:)`,`EventStore+OccurrenceRecords.swift:34` 等;`CalendarPageView.swift:6073`);仓库里没有登录墙,首启无会话还会种演示行,所以真机上第一次画日历就已经把本机时区冻结了——`.fresh` 条件在真实安装序列里几乎永不成立,「只防新增分歧」就成了空话:iPad 在 Z2 装机、看一眼日历(冻 Z2)、再登录 → 旧条件保留 Z2 → 与 A 的 Z1 永久分歧,由正常安装顺序制造。条件成立时写入走 `applyRestoredIdentifier`(`OccurrenceKeyMetadataStore.swift:243`,仓库里唯一能覆盖已建立时区的写入者,也是 `SyncedSettings.apply` keepLocal 先例之外唯一的 seam),其注释「USER-CONFIRMED PATH ONLY」(`:230-234`)改为点名这个第二个调用者和它的条件(Phase 1 交付项);条件不成立时**永不自动覆盖**,保留本地,记 `sync.conflict key=zone local=… remote=…`,**不进 shelf**(shelf 里的时区没有消费者,也没有人能安全地「恢复」它)。给这条规则装牙的是 §8 的双时区收敛测试,没有它这条规则只是一句话。
- pusher:这个键的按键合并结果 = **服务端有值就取服务端的值**(设备永远不会把另一个时区推到已建立的账号时区上);服务端没有时才送本地值。
- **时区先行**:游标缺失(本用户没有游标)时,引擎**先** GET `user_settings` 行、在上述采用条件下应用时区,**然后**才解码任何 `event_logs` / `event_feedback` 行、才应用第一页拉取。原因:`decodeOccurrenceKey` 对 single-event 行(`SupabaseSyncService+Restore.swift:544`)和旧格式 series 行(`:555`)会调 `dayKey(from:)`,`.fresh` 时这一步就把时区冻结了;而且第一页里只要有一条 series 的 log / feedback 行先于 settings 行落到本地,§6.2 的采用条件就永久关闭了,所以顺序不是优化是正确性;今天的 restore 恰好就是先解码后应用设置(`+Restore.swift:224-225` 在 `RestoreCoordinator.swift:394-401` 之前),Phase 1 的 applier 不继承这个顺序。**时区先行受 §6.1 同一冻结预检门控**(评审六):calendarEvents / logs / feedback 任一 slot 冻结 → 不 GET、不采用、不拉第一页(游标本来就缺,没有东西要写,`sync.apply.refused` 照记);否则采用条件会拿冻结 slot 的空数组当「本地没有 series 记录」,正是 §6.1 禁止的「拿空数组当本地状态」。不门控的结果恰好也无害——唯一的解冻是用户确认的 restore,它用账号时区下的云端行替换整个 slot——但门控是零成本的一致性,不留一个「恰好」。
- **两台已各自建立且不同**:Phase 1 接受分歧,列入 §9.21。损害范围由 wire id 决定:`encodeOccurrenceKey`(`SupabaseSyncService.swift:1494`)对 single 事件不含 dayKey,只有 series occurrence 的 id 含 dayKey,且只在两个时区把同一瞬间划到不同民用日时(午夜附近)才分叉;**没有 re-key 路径**,也不建。P0.3 加一项只读检查:生产 `user_settings` 每个账号的时区值,看分歧是否已经存在。

### 6.3 三个存储的位置(v1.4,勘察缺口 5)

`DurableEventStorage.sweepUnknownEntries()`(`DurableEventStorage.swift:626-646`)在 init 时删掉 `EventStore/` 里白名单之外的一切,所以没有东西能放进去;每个值存储各占 Application Support 的一个兄弟目录并有 `-TestHost` 孪生(`OccurrenceKeyMetadataStore.swift:304-315` 是模板)。决定:

| 存储 | 位置 | 形状 | 擦除 | 备份 |
|---|---|---|---|---|
| (hash, seq) 基线 | **UserDefaults,现有键 `syncHashes.<uid>.<table>`**(`SupabaseSyncService.swift:760`)| 每行值是版本化字符串:`<hash>`(旧形状,seq 未知)或 `<hash>@<seq>`;`user_settings` 的值改成 JSON `{seq, keys: {key: hash}}`,同一个键,从旧标量升级按 §6 settings 段的规则 | `wipeAllPersistedHashes()`(`:845`)前缀扫描**原样覆盖** | 随 UserDefaults |
| 游标 | **UserDefaults 键 `syncHashes.<uid>.cursor`** | 一个整数 | 同一前缀,`wipeAllPersistedHashes`(`:845-850`,前缀扫描)**免费覆盖**;`loadHashes(forUserId:)`(`:764-782`)只读点名的表键和三个标量,**不会**顺带读到它,`SyncCursorStore` 自己读这个键;`didChangeNotification` sink(`:578`)的开销和 `persistHashes` 今天付的是同一份,`syncSettings` 的哈希守卫把它吸收 | 随 UserDefaults |
| ConflictShelf | **新兄弟目录 `Application Support/Sync/`**(XCTest 下 `Sync-TestHost`;`applicationSupport()` 不可解析时按 OccurrenceKey 的 `/dev/null` 回退,只拒写不冻结别处)| **追加式 JSON-lines** 文件,每行 `{uid, table, id, seq, reason, row}` 带完整来件行;追加前按 `(uid, table, id, seq)` 去重(§6.1);追加失败 = 整页拒绝 | **`ConflictShelf.wipe()`**,在 `resetAllLocalData` 里点名、在 `EraseWiringQATests` 的 required 列表里点名 | **进 Device Backup**,和 Application Support 里每个存储一样(`EventStorageLocation.swift:105-119` 明令不设 `isExcludedFromBackupKey`):shelf 里是用户自己账号的数据,只是另一台设备的版本,不是第三方内容 |

- **路径里不带 uid**(没有先例,也不开);uid 在键名 / 行内。多账号切换是非目标(§2),基线和游标按 `<uid>` 键隔离、shelf 按行内 uid 过滤,足够。
- `persistAllHashes` 式的整批替换保留:`markRestoreCompleted`(`:1569`)重播基线时,服务端已知的行把 seq 一起带上(`<hash>@<seq>`),不知道的写旧形状,下次走 POST ignore-duplicates 回收 seq(§6 上传形状)。
- 不用 `AtomicValueFile` 做基线:冻结的基线文件意味着上传永远拿不到新 seq → 每次 PATCH `[]` → 拉取循环;UserDefaults 没有冻结态,丢了就是 I1 全量拉。
- **降级的代价明示**:装回 Phase 1 之前的 build,它把 `<hash>@<seq>` 整串当 hash 读,全部约 13k 行判脏,走旧的 `merge-duplicates` upsert 重推一次;服务端无变化短路吸收(seq 不动、内容不变),所以是一次性的请求风暴,不是数据事故(§9.26)。
- **升级的一次性代价明示**(评审六):装上 Phase 1 build 时,一条离线编辑过的行(基线是旧编码下的 `<hash>`,本地 c1)第一次拉取遇到它的服务端副本 c0:`h_in ≠ h_base`(编码变了)、`h_in ≠ h_loc` → dirty → c0(用户自己的旧基线)进 shelf 一次,然后 c1 以新 seq PATCH 并赢。不丢任何东西;每条升级时离线编辑过的行多一条无意义的 shelf 行,Fix Watch 的 `sync.conflict` 在升级后第一次拉取会有一个尖峰,不是 bug。

### 6.4 擦除、登出与 Phase 1 写入者(v1.4,勘察缺口 1)

本分支叉在 `25f8b84`,king 之后合了擦除战役(gh#256 / #258 / #260–#266,merge `739fee9`);`git merge-tree` 今天无冲突,但 Phase 1 要改的 `ContentView.swift` / `EventStore.swift` / `AgentSettingsView.swift` / `project.pbxproj` king 都动过。规则:

- **先合 king,再写任何 Phase 1 代码**(P0.0)。king 的 `EraseWiringQATests` 按源码字符串断言 `resetAllLocalData()` 的调用清单(king `DoneTests/EraseWiringQATests.swift:51-78` 的 required 列表,`:80-82` 的循环),合进来的那一刻本分支的旧函数体就红。
- **puller / applier 是 `LocalDataEraseEpoch` 那一类的 post-await 写入者**(king `Done/Services/LocalDataEraseEpoch.swift`,文件头:「Nothing makes the next one fail on arrival」):RPC 前 `capture()`;**每一次**落盘(slot、基线、游标、shelf)之前**紧挨着** `isStale()`,中间不能有 suspension point;全部在 MainActor 上。shelf 追加在第一遍(§6.1),它的 `isStale()` 失败与 I/O 失败走同一支——整页拒绝,什么都不落。只在拉取开始检查一次是错的——零宽 TOCTOU 窗口靠的是「门 → 写」之间无挂起(`LocalDataEraseEpoch.swift:87-94`)。
- **`$session → nil`**(擦除里 `authService.signOut()` 先于 `wipeAllPersistedHashes` 发生,king `AgentSettingsView.swift:938` vs `:947`):停门铃(`credentialsDidChange()`,`SupabaseRealtimeDoorbell.swift:377`;今天没有人订阅 `$session` 调它,接线时必须对包括 nil 在内的每次发射都调)、丢掉内存里的游标和基线、**取消在途的拉取 Task**;这条路径上**什么都不持久化**——在 slot 已清、哈希未清的窗口里写盘就是把擦除打穿。`ContentView.swift:580` 用了 `compactMap`,看不到 nil,引擎不能挂在它上面。
- **擦除接线**:每个新 purge 调用(`ConflictShelf.wipe()`)追加进 `EraseWiringQATests` 的 required 列表;每个新磁盘存储(`Sync/`)有 `-TestHost` 重定向且在 `testEveryPurgeCapableStoreIsRedirectedUnderXCTest`(king `:122-154`)里有一条叶子断言——否则跑一次测试套就擦掉 dogfood 机的真 shelf(PersonAvatars 的教训)。基线和游标复用 `syncHashes.` 前缀,不需要新 purge。
- 门铃用 `URLSession.shared` 的 `URLSessionWebSocketTask`,进程死 socket 也死,epoch「不持久化」的前提(`LocalDataEraseEpoch.swift:49-63`)仍成立;**不得**给门铃配 background `URLSessionConfiguration`。

### 6.5 应用日志与 latency_ms(v1.4,勘察缺口 6)

每条应用一行:`sync.apply table=… id=… seq=… latency_ms=… age_ms=… reason=…`

- `latency_ms` = **B 本机单调时钟**(`ContinuousClock`,不是 `Date()`,见 `reference_spike_measurement_gotchas` 的纪元错位)从**门铃帧到达**(在 `onChange` 边界捕获,`SupabaseRealtimeDoorbell.swift:528`;`RealtimeChange` 自己不带时间)到 **slot 提交**。**只在 `reason=doorbell` 时出现**;launch / foreground / reconnect / poll 没有帧,字段省略。
- `age_ms` = B.now − `row.synced_at`(九表都有、都在上传时盖的**发送方**墙钟,`SupabaseSyncService.swift:1202-1213`;`updated_at` 在 todo_lists / skill_insights 上不存在,在 logs / feedback 上是编辑时刻)。**只作参考**:跨设备墙钟运算,clamp 到 0,永不做门槛。三张单行表(user_settings / agent_*)的 `synced_at` **只在内容变了才会重盖**:`syncSettings` 先比行 hash、不变就不发(`SupabaseSyncService.swift:886-887`,5 s 防抖的 sink 在 `:578-582`),而 015 的 `meta = ['seq','updated_at','synced_at']`(`015:71`)被排除在相同内容比较之外(`:90-92`),内容相同的 upsert `return null`、`synced_at` 不动;所以它们的 `age_ms` 量的就是「上次内容变更距今」,和九表其它行同义(v1.4 初稿说「每次 flush 都重盖」是错的,评审六)。
- ≤ 2 s 验收(§2 目标 1)的计时从 A 的上传算起;`latency_ms` 量的是 B 自己的管道(300 ms 合并 + RPC + apply),`age_ms` 量的是端到端但不可信;两者合起来是 harness 场景能断言的全部。**不加服务端时间列**(v2 砍掉 `server_updated_at` 的理由不变:没有消费者能把它变成可信的跨设备数字)。
- 其它行:`sync.pull.reason=… rows=…`、`sync.apply.refused slot=… seq=…`(§6.1)、`sync.conflict table=… id=…` / `sync.conflict key=zone …`(§6.2)、`sync.push.orphan`。落盘走 `DiagnosticTrail.record(category: "Sync", …)`,`key=value` 令牌,与 `RestoreCoordinator.swift:357` 同形。

## 7. 分期(每期可独立装机、各自验收)

### Phase 0 — 地基
| 项 | 内容 | 验收 |
|---|---|---|
| P0.0 | **合 king**(`65fcd7a`,擦除战役)进 `design/realtime-sync`,在任何 Phase 1 代码之前(§6.4) | `EraseWiringQATests` 在本分支绿;`git merge-base --is-ancestor 739fee9 HEAD` 为真 |
| P0.1 | **#249** 会话搬 Keychain `ThisDeviceOnly` | 备份恢复到第二台机不带 refresh token;#234 形状不再可造 |
| P0.2 | **本地台架**:`supabase start`(`done-mcp/supabase/config.toml` 入库)+ `SupabaseSyncConfig` 按 build 指向本地栈(D8) | DEBUG 模拟器能对本地栈 upsert / PATCH / rpc;对生产仍禁写 |
| P0.3 | **台架半已做**(`done-mcp/supabase/tests/sync_feed_checks.{sql,sh} @ 6f293a8`,可重跑,README 列前置):S1 锁序 / S2 DELETE→tombstone / S3 tombstone 抗 upsert / S4 无变化短路 / S5 每语句一帧 / S6 账号擦除九表清零 / S7 条件 PATCH 四种响应(含 tombstone 行)/ S8 ignore-duplicates POST / S9 tombstone PATCH 与管道符、`none` id / S10 `sync_changes` RLS、分页、EXPLAIN / S11 king 三形状 / S12 私有 channel 与外人 join / S13 `agent_preferences` null upsert / S14 service_role 删除 / S15 锁序死锁——**全部成立,S13 部分**(null 形状 400 `23502`,是客户端既有缺陷,§6 agent_* 段);原清单里「关 Allow public access 后才强制」已被 S12 证伪(§5.5 / §9.32);十三条与设计稿不一致的实测全部改入正文(§13 第七轮表)。**仍待做**:(a) **一次只读检查**:生产每个账号 `user_settings.settings->>'occurrenceKeyReferenceTimeZoneIdentifier'`(§6.2);(b) **015 应用到生产**(D8)| 台架:两个并发事务下游标不跳行;DELETE 后 `deleted_at` 非空且行还在;内容相同的 upsert 不改 seq、PATCH 返回 `[]`;现行 king build 对台架的上传和删除路径不报错——**台架上全绿**。生产:**未应用**;应用步骤与验后检查见下段 |

**015 的生产应用(P0.3 末项 → Phase 1 的交接单)**:(1) 先应用 015,**同一窗口内**重新部署三个边缘函数(`1d8c830` 的 `deleted_at` 过滤:015 之前列不存在、函数会 500,015 之后不部署则 AI 读到已删行);(2) 015 设 `lock_timeout 3s`,在**安静窗口**应用,主账号的上传先关(总闸 OFF),否则 `alter table` 等不到锁就失败回滚,幂等可重试但要知道原因;(3) 约 13k 行的 `seq` 回填在触发器建立之前跑,**没有门铃帧**,不会把在线设备拉醒;(4) 验后:`realtime.messages` 上 policy `own sync topic` 存在;`notify_sync_change` 的 owner 是 `postgres`(security definer 的前提,§5.3);`POST /rest/v1/rpc/sync_changes` 带用户 JWT 200、只带 apikey 401——404 则 `notify pgrst, 'reload schema'`;(5) 应用后到 Phase 1 装机之间,现行 king 的 Restore 会把 tombstone 带回本地(§6 Restore 路径),管理员在 dashboard 上硬删单行要先 disable 该表的 tombstone 触发器(§5.4)。

#250 刷新退避是好事但不是前置,顺手做。`015_sync_change_feed.sql` 落在 main 的部署 glob 里(`.github/workflows/supabase.yml:7`、`:31`),**没关系**:它会在任何 king→main 合并之前被有意地应用到生产,部署重跑是幂等的(#244 已实证)——这一点在此记下,免得合并时有人以为是意外部署。服务端读取面(`done-mcp/supabase/functions/api` / `mcp` / `snapshot`、`done-mcp/src`)的 `deleted_at is null` 已提交(`1d8c830`,含 count 查询);它们以 service key 绕过 RLS,所以过滤必须写在每个 query builder 里,不能指望 policy。

### Phase 1 — 入站实时,iOS 两端(用户第一次看到「另一台上出现」)
- 交付:`SyncCursorStore` / `SyncPuller` / `SyncApplier`(§6,含 settings 按键合并、event_types 胜者规则、时区先行 §6.2、slot 拒写停游标 §6.1、pending-verify 集合)/ `ConflictShelf`(§6.3)/ 门铃接线(含 `$session` sink,§6.4)/ `LocalDataEraseEpoch` 门(§6.4)/ `ConflictShelf.wipe()` 进擦除与 wiring 测试;基线值扩成 `(hash, seq)`(`<hash>@<seq>`),更新改逐行条件 PATCH、新建改 ignore-duplicates POST,`[]` → pending-verify `(table, id, sentSeq, sentHash / sentKeys, pullIssue)` + 拉取,`[row]` 带 `deleted_at` → 按 tombstone 来件处置(§6 上传形状第三种响应);upsert / POST 状态码按 2xx 判(§5);**`encodeJSONOrNull` 对 `agent_preferences.rules` / `decision_history` 送 `[]` 不送 `null`**(台架 S13 的 400 `23502`,§6 agent_* 段);applier 一页两遍、shelf 追加失败即拒页、按 `(uid, table, id, seq)` 去重、每页每 slot 一次 persist、冻结预检(时区先行同门)、「在 head」标志由 flush 时刻读、logs / feedback 走 `commitLogRecordsNow()` / `saveCalendarEventFeedbackRecords()`(§4 I3 / §6.1);`applyRestoredIdentifier` 注释点名 sync 调用者(§6.2);`SupabaseSyncService.seedFingerprint` static(投影去 `user_id`)、种子器写 `sampleSeed.eventHashes`、首次拉取前按三条件删未碰过的种子(数组移除 + 一次 save,不走级联)、`offerAutoRestoreIfNeeded` 退役并删 king `AgentSettingsView.swift:992` 的前缀扫描行(§6);客户端删除改 `PATCH deleted_at`;`deleteCalendarEvent` / `deleteRecurringCalendarEvent` 加 `unlinkAssets:`;`fetchAll` 加 `deleted_at=is.null`;`DoneApp` 有会话时 `seedsSampleDataIfEmpty: false`;`syncUploadsEnabled` 经 `register(defaults:)` 默认 ON、门控双向、交互式登录置 true(D9);应用后按触碰 id 重播基线;launch / foreground / doorbell / 60 s 兜底(带 `sync.pull.reason=poll` 计数,一个 build 内 rows>0 为零就删掉)。
- 验收:A 建 / 改 / 删 → B 前台 **自 A 上传起** ≤ 2 s 落地并有 `sync.apply table=… id=… seq=… latency_ms=… age_ms=… reason=doorbell` 日志(§6.5);B 后台 10 min 再前台 → 一次拉取追平;A 离线改、B 在线改同一条 → A 上线后 shelf 文件里有 B 的版本、服务端是 A 的版本、B 随后拿到 A 的版本;A、B 在 2 s 内同改同一条 → 一方的 PATCH 返回 0 行、拉取后另一方版本进它的 shelf,服务端两次写都基于当前版本(SQL 对拍 seq 链);**A 删 B 不会把 tombstone 抹掉**(SQL 对拍);A 改设置、B 同时在分析 → A 的设置在两台都生效;整表 upsert 重推期间门铃帧数 ≤ 语句数;**一个只改哈希编码的 build 装到 A 上 → 一轮 flush + 一次拉取后 A 不再有脏行**(pending-verify,SQL 对拍 seq 不动);**B 新机登录 → 第一条日志是 user_settings 的时区应用,之后才有 event_logs 行**(§6.2);**擦除进行中有一次在途拉取 → 擦除后磁盘无 Sync 内容、无 `syncHashes.` 键**(复用 king 的 `EraseInFlightWriteTests` 形态);**冻结一个 slot → `sync.apply.refused` 每次拉取一条、游标不动、已成功的 slot 基线不回退、restore 后一次拉取追平**;**新机首启看日历再登录 → 第一次 flush 推 0 行、时区采用账号的 Z1**(§6 示例数据、§6.2);**评审五、六的三种 `[]` 交错(§6 上传形状 (i)(ii)(iii))在纯引擎测试里各有一条:c1 最终在服务端、c2 在 A 的 shelf,(iii) 里 c3 在窗口后上传,A/B 收敛**;**未改的演示行上写一条笔记再登录 → 行与 log 都上传、不删**;**第一遍 shelf 追加失败(满盘夹具)→ 整页拒绝、数组未改、游标不动、下一次成功拉取后败方版本在 shelf**;**擦除 → 再登录 → 不碰开关就能拉能推**(D9);**零规则用户的 `agent_preferences` 行上传 2xx**(S13 的正对照);**A 脏改 X 的同时 B 删 X → A 的 PATCH 回带 `deleted_at` 的行 → A 本地 X 走级联删除、A 的版本在 shelf、基线无 X、下次 flush 不再推 X**(纯引擎测试,`FakeServer` 的 PATCH 对 tombstone 行按 S7 行为回行)。
- 已知缺口(明示):出站仍是整表哈希差分(#219 的既有成本);**Phase 1 的目标 3 是「没有版本被销毁」**:shelf 是文件 + 日志 + Fix Watch 计数,没有列表界面,用户要捞要走支持路径;列表界面在 Phase 2。

### Phase 2 — 按需,测量驱动
- Mac 合 king、清 JWT、接共享引擎。
- #140 回收站 UI 吃 tombstone + 显式 undelete RPC(解 I6 的锁)。
- per-row outbox:只在 #219 的写放大测量说哈希差分是主项时做。
- agent_preferences / agent_conversations 按键化:只在 shelf 里真出现它们的冲突时做。
- tombstone purge + 水位线:只在 tombstone 行数成为成本时做。
- people / friendGroups / reminders / customAnniversaries / reports 上 schema 进同一引擎(P4 原内容)。

## 8. 验证策略(独立 QA 循环适用)

- **纯引擎收敛测试**:两个 `EventStore`(隔离存储)+ `FakeServer`(分配 seq、tombstone 改写、无变化短路、**对 tombstone 行的条件 PATCH 照常命中并回带 `deleted_at` 的行**——台架 S7 的行为,不是设计稿原来假设的拒绝;不模拟 RLS)+ `FakeGateway`;随机操作序列(含离线编辑、同改同删)后断言 A == B == server 且 shelf 内容 = 所有败方版本(seeded,带正对照和变异体;参考 `reference_test_teeth_structural_traps`)。
- **往返稳定性**:每表一条 `rowHash(xToRowForHashing(rowToX(xToRow(x)))) == rowHash(xToRowForHashing(x))`,否则三方比较的「来件 == 本地」永远不成立。
- **pending-verify 交错测试**(§6 上传形状 (i)(ii)(iii)):`FakeServer` 允许把一次拉取的响应扣住到 PATCH 的 `[]` 之后再交付;断言旧规则下 c1 消失 / c1 被标干净的两条变异体都红,新规则下 c1 在服务端、c2 在 shelf;**第三条变异体(评审六,(iii)):清标记时从活行重算 hash 而不是写 `sentHash` → c3 永不上传,必须红**。没有这三条变异体,「收敛」断言对这两个 BLOCKER 没有区分力。
- **双时区收敛测试**(§6.2):store A 冻在 Z1 且持有 series occurrence 记录;store B 在 Z2 画过日历(已冻 Z2)但没有 series 记录,登录 → B 采用 Z1,之后两台对同一个午夜附近的 series occurrence 产出同一个 wire id;反例:B 持有一条 Z2 下的 series 记录 → 保留 Z2、`sync.conflict key=zone` 一条、不进 shelf。
- **种子测试**(§6 示例数据):空 store 种子 → 登录 → 第一次 flush 0 行;改一条演示行 → 恰好推那一行;**反例(评审六 BLOCKER)**:在未改的演示行上写一条笔记(只动 `calendarEventLogRecords`,行 hash 不变)→ 登录 → 该行保留、行与 log 都上传;指纹在种子时刻(无 uid)与检查时刻(有 uid)相等是前置断言,否则整条测试在「全删」和「全留」之间没有区分力。
- **shelf 追加失败测试**(§6.1):满盘夹具让 shelf 追加返回 false → tombstone + dirty 与 update + dirty 两种页都被整页拒绝,`rawCalendarEvents` 未改、游标不动;正对照:追加成功时同一页正常应用。
- **协议测试**:`RealtimeDoorbell` 用 fake transport 回放(已有,29 条)。
- **SQL / HTTP 对拍**(本地台架,D8)——**已执行,全部成立**(`done-mcp/supabase/tests/sync_feed_checks.sql` 走 psql + `dblink` 三连接,`sync_feed_checks.sh` 走 GoTrue + PostgREST + 裸 websocket;`@ 6f293a8`,可重跑,每条打印 PASS/FAIL 与观测值,README 列前置与副作用):两个连接各开事务、先取号者后提交,第三连接的 `sync_changes` 不跳行(S1);DELETE 变 tombstone(S2 / S14 含 service_role);活行带 `deleted_at: null` 的 upsert 不撤销 tombstone、其它列照改(S3);内容相同 upsert 的 seq 不变、无帧(S4);整表 upsert 一条语句只有一条 `realtime.messages`(S5);账号擦除九表物理清零、零帧(S6);条件 PATCH 四种响应(S7)与 ignore-duplicates POST(S8);tombstone PATCH 与特殊 id(S9);`sync_changes` 的 RLS、分页、上限夹紧、索引计划(S10);king 三形状(S11);私有 channel 自己 ok、外人拒、外人的帧不漏(S12);锁序死锁恰好一方 `40P01`(S15)。标「recorded」的条目只记录行为不断言,读输出不只看退出码。生产应用后同一套脚本**不能**对生产跑(它们建删 `auth.users`、直读 `realtime.messages`);生产的验后检查是 §7 交接单的第 (4) 项。
- **装机**:harness 场景「双机 ping-pong」(#197 形态),每一步一条结构化日志。
- **写放大**:apply 只写触碰的 slot;门铃帧数 ≤ 语句数;Fix Watch 计数器 `sync.pull.rows` / `sync.apply.slots` / `sync.conflict`。

## 9. 风险与已知坑

1. **#249 不修,多设备就是在制造 #234**:两机长期在线必毒死 token family。P0 不可跳。
2. **哈希差分与远端应用并存**:apply 必须在同一步里重播触碰行哈希,且顺序是 slot 落盘在前(I3);缺一个就是回声上传。**干净行**的回声上传不成环:`rowHash` 排除 `updated_at`,服务端又有无变化短路。**脏行**被短路是另一回事(v1.4):短路恰好抹掉了客户端重设基线所需的唯一信号(返回行 / 新 seq),由 §6 的 pending-verify 规则收口;没有它,一个改了哈希编码的 build 就是每 2 s 一轮 13k 次 PATCH。而「`[]` ⇒ 相同」这个推论本身只在**基线自 PATCH 建立后没动过、且判定它的拉取发号晚于 `[]`** 时成立——少任一条件就会把一次过期当成相同,或把一次尚未可见的并发写当成相同,两者都销毁本地版本(评审五 BLOCKER,§6 上传形状 (i)(ii));判成相同之后写进基线的 hash 必须是 PATCH **送出**的那一行的(`sentHash`),从当前行重算会把清标记窗口里的新编辑标成干净(评审六 BLOCKER,(iii))。
3. **混跑窗口**:旧 build 的 DELETE 已被服务端改写,旧 build 的 upsert 不带 `deleted_at` 也不会撤销 tombstone;旧 build 唯一看不到的是别人的变更(它没有入站)。
4. **iOS 后台**:socket 被杀是常态;正确性全靠前台追平,不靠 doorbell。
5. **Realtime 配额**:每用户每设备 1 连接、前台才连;整表重推 = 语句数帧(235),远低于 100 msg/s。
6. **settings 按键合并是 Phase 1 的必需品,不是优化**:`skillAnalyzedEventIds` 让整行在每台设备上几乎永远脏,整行规则会把用户的设置改动反向覆盖到两台(§6)。agent_preferences / agent_conversations 仍是整行,出现冲突进 shelf。
7. **事件类型按 title 合并**:两台各建同名类型 → UUID 不同 → 胜者 = 最小 UUID,败方永不进基线且被两边 tombstone(§6);只按 id 插入会让两台都失去这个类型。
8. **`EventStore` 4353 行**:applyRemote 复用级联,不新写。
9. **用户级事务锁**:同一账号的并发写串行化。两三台设备、20 行一块,等待以毫秒计;service_role 一次事务跨多个用户会按遇到顺序取锁,现有 edge function 都是单用户请求。
10. **tombstone 不 purge**:删除的行永久留在表里(内容保留给 #140)。按现在的删除频率,年增量以百计。
11. **门铃两处低优先级瑕疵**(评审 #8):退避梯子在 join 成功后归零,服务端「接受 join 又立刻踢」会以 1 s 间隔重连;token 过期前没有主动推 `access_token`,闲置设备会吃到一次重连。两者都只影响延迟。
12. **BEFORE DELETE 改写在 PostgREST 下的表现**——台架 S2 / S11 已确认:DELETE 返回 204、0 行,现行客户端的删除路径 `SupabaseSyncService.swift:134-154` 只看状态码,接受;带 `return=representation` 则 `200 []`,行已 tombstone 但响应体不说。推论写进 §5.4 / §6:tombstone 只从 `PATCH deleted_at` 的响应行确认。king 的 Restore `GET … Range` 会把 tombstone 行一起拉回(§6 Restore 路径)。
13. **账号擦除**:九张表都 `references auth.users(id) on delete cascade`。改写触发器若无角色/深度门,RI 级联的 DELETE 会被改成 UPDATE 并 `return null`,RI 只看 SPI 结果码不数行,结果是 `auth.users` 没了、九张表的 PII 带着悬空 `user_id` 全留下,**静默**(评审二 E1)。门已加(§5.4);台架 S6 对拍通过:删一个测试用户,九表存活行数为 0,**已 tombstone 的行同样物理消失**(擦除不留 tombstone),且**零门铃帧**(语句级触发器在深度 2 的级联里不发帧)。推论:被擦除账号的其它设备**不会被通知**,它们在下一次拉取 / 刷新时吃到 401(用户已不存在),走 AuthService 的终端判定登出;这正是擦除要的——擦除不是一条要同步的变更。与 #260 擦除完整性战役直接相关。
14. **启动期本地清理器现在会传播**:`sweepZombieRecurringSeries`、`dedupedByTitle` 这类在本地删行的逻辑,经集合差分变成 tombstone 推到服务端。它们以前也推物理 DELETE,所以不是新行为;新的是远端来的行可能被它们当垃圾。Phase 1 实现前逐个审计「远端来源的行不是 debris」。
15. **旧 build 的批量 DELETE 响 N 下**:`DELETE ?id=in.(N)` 被逐行改写成 N 条嵌套 UPDATE 语句,每条一帧。台架 S5 的数字:`DELETE ?id=in.(五个 id)` 响 5 帧;一条 20 行的 POST 响 1 帧,payload 的 `seq` = 这 20 行的最大号;20 条单行 POST 响 20 帧。只在过渡期、只在批量删除时发生;客户端合并后多拉一次。§7 的「帧数 ≤ 语句数」只对 upsert 成立;Phase 1 自己的删除是一条 `PATCH …id=in.()`,一帧。
16. **ON CONFLICT 下 seq 烧两次**:BEFORE INSERT 臂先取一次号,冲突后 UPDATE 臂再取一次。空洞无害。
17. **行锁与用户锁的顺序死锁**:多行 PATCH(tombstone 的 `id=in.(X,Y)`)先锁 Y 的行、在触发器里拿用户锁、再去锁 X;另一台的单行 PATCH 持有 X 的行锁、在触发器里等用户锁。PG 1 s 后报 40P01,一方回滚。台架 S15 测得**牺牲者是单语句那一侧**:它先进入等待,`deadlock_timeout` 先在它那里到期,它被选中回滚;两语句的批量侧提交。所以**重试负担落在单行 PATCH 上**——Phase 1 的逐行条件 PATCH 收到 `40P01` 时按同一 seq 重发一次即可(服务端那次没写,基线仍有效);批量 tombstone PATCH 不需要为此重试。罕见、无害,但日志里出现 deadlock 不是 bug(评审四 L3)。要根治得在语句级 BEFORE 触发器里用 `auth.uid()` 先拿用户锁,Phase 1 不做。
18. **两台同时跑分析器**:`SkillInsight` 没有 event id,applyRemote 拉到别人的 insight 时无法把对应事件标成已分析,所以两台在同一时间窗里会对同一事件各出一份 insight。`skillAnalyzedEventIds` 并集把窗口压到两次拉取之间;Phase 1 接受,insight 带 event id 是 Phase 2 的小改。
19. **在途拉取打穿擦除**(v1.4):puller 在 `await` RPC 期间用户按了「擦除全部本地数据」,返回后写 slot / 基线 / 游标 / shelf 就把刚擦的数据种回去;king 的 `LocalDataEraseEpoch` 正是为这一类写入者建的,但「没有任何东西让下一个写入者到达时失败」——靠 §6.4 的 capture / isStale 纪律和 review,不靠框架。`$session → nil` 时若引擎把内存游标「保存」到盘,就落在 slot 已清、哈希未清的窗口里;该路径只许丢、只许停。
20. **新存储漏出擦除**(v1.4):擦除按名字枚举 purge(自动普查已按用户拍板摘除,`RELEASE_CHECK` build 6),忘了 `ConflictShelf.wipe()` 没有任何测试会红,只有 `EraseWiringQATests` 的 required 列表这一道手工防线;`Sync/` 没有 `-TestHost` 重定向则测试套会擦 dogfood 机的真 shelf。基线和游标复用 `syncHashes.` 前缀,这两样不新增风险。
21. **已建立时区分歧**(v1.4):两台设备在 Phase 1 之前各自冻结了不同时区,则 series occurrence 的 log / feedback 在午夜附近会得到两个 wire id,永久、静默;没有 re-key 路径,Phase 1 不建。P0.3 的只读检查先看生产是否已经如此;§6.2 的「先建立者胜」只防新增分歧,不治旧的——而且只有采用条件是「本地没有 series 记录」而不是 `.fresh` 时才真的防得住(评审五:真机第一次画日历就冻结时区,`.fresh` 几乎永不成立)。
22. **domino 双机互推**(v1.4):`dominoPushTodosPastHorizon` 在两台上各算一次,互为远端变更。两台算的是同一个 horizon 日所以收敛,但每个日界会多一次 `sync.conflict`(后到的那台本地已脏);用计数器实测,只有它真成了 shelf 的主要来源才改成单侧推。
23. **slot 冻结即全停**(v1.4):§6.1 的停页让一张表的冻结变成九张表的入站停 + 九张表的出站停(I1);提交时拒写的页里已成功的 slot 保留基线,重拉靠 `seq == base.seq` 跳过,不会把同一来件重复写进 shelf。这是设计选择不是缺陷:冻结本来就是「用户必须看一眼」的状态,横幅已在;但一个被冻结的 dogfood 机会在日志里表现为「同步没动静」,`sync.apply.refused` 是区分它和「没有变更」的唯一信号,harness 场景必须断言它出现。
24. **015 在 main 的部署 glob 里**(v1.4):`supabase.yml` 对 main 上 `migrations/**` 的改动全量重跑;015 会先被有意应用到生产,所以 king→main 合并时的重跑是幂等重放,不是首次部署——但如果有人**先**合 main 再想起 015,部署 action 就成了 015 的首次应用,没有台架验证。P0.3 的末项(直接应用到生产)必须在任何含 015 的 main 合并之前完成。
25. **shelf 在设备备份里**(v1.4):shelf 行是其它设备的完整行,随 Application Support 进 iCloud / iTunes 备份(§6.3)。接受:它是用户自己账号的数据;真正不该进备份的是会话凭证(#249,P0.1),不是数据。
26. **降级一次性风暴**(v1.4,评审五):装回 Phase 1 之前的 build 会把 `<hash>@<seq>` 当 hash,约 13k 行全部判脏、经旧的 `merge-duplicates` 重推一次;服务端无变化短路让它 seq 不动、数据不变,只是一次约 13k 次请求的风暴。接受,不做兼容读。
27. **首次登录前删种子**(v1.4,评审五、六):§6 示例数据规则在第一次拉取前删本地行,这是全仓唯一一处不经用户确认的本地删除;边界是**三条件**——指纹仍等于种子指纹、没有任何 log / feedback 记录指向它、不是 interrupt 父——范围是 `sampleSeed.eventHashes` 里的 id,动作是数组移除 + 一次保存,不走级联。只看 hash 是评审六的 BLOCKER:用户在演示行上的完成 / 笔记只写记录数组,行 hash 不变,级联会把那条笔记剪掉。指纹必须用去掉 `user_id` 的 static 投影算,否则种子时刻与检查时刻的值永不相等、规则空转。没有这条,每台首启后再登录的设备都会把 10 条演示行推进账号。
28. **登录覆盖显式 OFF**(v1.4,评审五):D9 的「交互式登录置 true」会把用户之前显式关掉的总闸翻开;刷新成功不翻。接受:D9 下登录即同意,关闭仍在同一页设置里。
29. **shelf 追加失败 = 入站全停**(v1.4,评审六):§6.1 把 shelf 追加放在第一遍并让失败整页拒绝,所以满盘时入站和出站(经 I1)一起停,与冻结 slot 同一后果。这是有意的:让 persist 失败的条件同样让 shelf 失败,而 shelf 是败方版本的唯一副本;先级联再发现 shelf 没写上,c1 就哪里都不在。设备此时本来就在满盘横幅状态。
30. **`agent_preferences` 从未上传过**(台架 S13,既有缺陷,与 015 无关):`encodeJSONOrNull`(`SupabaseSyncService.swift:1308-1316`)把空数组编成 `null`,而 `rules` / `decision_history` 是 `jsonb not null`(migration 009),零规则 / 零决策的用户每次 upsert 都是 400 `23502`,今天的默认用户恰好就是零规则。Phase 1 出站切片对这两列送 `[]`(§6 agent_* 段;§7 交付项);读侧继续把 `[]` 当空。没有台架这条会在 harness「A 改设置 B 生效」上以一个与同步无关的 400 现身。
31. **tombstone 行接受条件 PATCH**(台架 S7):I6 只保 `deleted_at`,设计稿原来假设「I6 挡住对已删行的一切普通写入」,实测是内容照改、取新号、`deleted_at` 保留、返回 `[row]`。后果全部在客户端,且比「多一条假日志」重:若把它当成功,基线写成 `(h_loc, 新 seq)`;下一次拉取这条 tombstone 来件时 `seq == base.seq` 成立,§6 第一条规则把它当「已处理」**跳过**——本地行永远活着、服务端是 tombstone、shelf 里没有、`sync.conflict` 一条都没有,静默分叉到用户下次再改这行(再次命中死行,循环);三张单行表上这个循环从第一次就开始。所以 `deleted_at` 检查是 tombstone 能到达这台设备的**唯一**路径,不是日志整洁问题。`FakeServer` 必须模拟这个行为(§8),不模拟就测不到这一支。
32. **topic 授权失败与坏 token 同码**(台架 S12):用 A 的 JWT join `user:<B>` 被拒,`reason` 恰是 `Unauthorized: You do not have permissions to read from this Channel topic: user:<uid>`——和协议笔记里「token 无效,不重试」的 `Unauthorized` 同一个 code,按 code 分不开。两者都当终端处理(都是客户端 bug:topic 名拼错或 token 不是本人的),不重试、记日志。另:**私有 channel 在本地栈默认就强制**(realtime v2.82.0,`_realtime.tenants.private_only = false`,「Allow public access」ON 的等价状态):B 的插入没有一帧到 A 的 socket。dashboard 那个开关禁的是**公开** channel,不是给 `private: true` 的 channel 开启强制;生产上关掉它只是纵深防御,v1.4 初稿把它写成前置是错的(§5.5、协议笔记「服务端半」)。

## 10. 拍板记录(2026-10-14 全部收口)

1. D8:**不建第二个云项目**(免费层项目数上限),本地 `supabase start` 栈是台架,015 台架全绿后直接应用到生产(向后兼容、3 个用户、回滚 = drop 触发器)。
2. D9:**登录即同步**;现有开关是总闸,`register(defaults:)` 默认 ON,门控双向;擦除仍置 false,交互式登录置 true。
3. D7:**Phase 1 只接 iOS**,Mac 进 Phase 2。
4. `SkillInsightStore.clearAll()`:**清空 = 全账号**(insights 全部 tombstone、所有设备重新分析)。这是并集 / nil 规则的自然推论,不另建任何东西;LLM 开销乘以设备数是明示的代价。

其余 v0 的决策点(tombstone 保留期、APNs)已在 v1 里用「按需」收掉;settings 按键合并由代码事实直接定进 Phase 1。当前没有待拍板项;v1.4 勘察出的六个缺口全部以规则写入 §4 / §6 / §7 / §9,汇总见 §13 末尾;评审五、六的处置表同在 §13。

## 11. Realtime 协议与配额(实现 `RealtimeDoorbell` 的依据)

见 `Docs/sync/01-realtime-protocol-notes.md`(从 Supabase 文档摘录,含 wire shape)。

## 12. 关联

#21(L1/L2 架构已定,本设计是 L2 的双向化)· #24(守卫:在 I1 + I4 + I6 下大部分自然消解)· #35 · #140(软删 → tombstone)· #151 · #234 / #249 / #250(P0)· #16 / #22(图片)· #219(写放大判据)· #256 / #258 / #260–#266(擦除战役:`LocalDataEraseEpoch`、`EraseWiringQATests`,P0.0 / §6.4)· #182(LLM 入口门禁,远端应用绕过 §6 events 段)· `project_donemac_campaign`(Mac Phase 1)

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
| C1 并发推送盲覆盖:A 的防抖推送落在 B 的推送之后、A 的拉取之前,B 的版本哪里都不在 | I8:上传带基线 seq,服务端不等拒 409;基线值扩成 `(hash, seq)`(第三轮证明触发器里做不了,改为请求过滤器) |
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

评审第三轮(独立 reviewer,只看 `5982cc6..93c69b7` 的 delta)与处置:

| 发现 | 处置 |
|---|---|
| **BLOCKER** v3 的 I8 触发器检查:`EXCLUDED` 带着 INSERT 臂的 `nextval()`,UPDATE 臂的 `new.seq` 永远是新号,每一次真实编辑都会 409;`seq: null` 跳过检查又让新建行重新打开 C1 | 服务端不做检查。I8 改为请求过滤器 `PATCH …&seq=eq.<base>`,0 行即过期;新建行 `ignore-duplicates` POST,基线 seq 从响应体拿,不再有 null 基线窗口(§6 上传形状) |
| 删除门的角色那一半有害:service_role 的删除物理执行 → 无 feed、无门铃 → 所有客户端留着行 → 下一次编辑复活 | 门只看 `pg_trigger_depth() > 1`(§5.4) |
| settings 按键合并缺四个决策 | 键 = 顶层键;缺键是值;每键 hash + 行 seq 基线;单行 hash 的升级规则;并集对「清空重分析」的影响挂 §10.4(§6) |
| event_types 规则:`Event.type` 是 title,改指向是空操作;applier 不能复用 `dedupedByTitle`;败方持有者不回来则败方永远活着 | 胜者由 applier 判;两边都 tombstone 败方(§6) |
| 三方比较在 `(hash, seq)` 下无丢失、无循环、无永久推不上去的行;19 好 1 坏的块回滚后能正确重推 | 认定站得住;补了「基线在上传成功时写入」一句 |
| PostgREST 把 23505 等也映射成 409,客户端要按 body `code` 分支 | 请求过滤器方案下不再依赖 409 |
| 过时文本若干(Phase 2 的 per-key 行、§9.6/9.7、§5 版本号、§9.12 引用) | 已改 |

第三轮认定站得住:锁在检查之前、无变化短路、旧 build 自然通过、`revoke`、§9.13 的级联分析、每条新增都对应一个具体场景(减法原则成立)。

评审第四轮(独立 reviewer,只看 `93c69b7..913abe2` 的 delta,对生产库只读核查了 policy 与 FK)与处置:

| 发现 | 处置 |
|---|---|
| **H1** §6 措辞会让实现者拿响应体算基线 hash → 每行永远脏 → 每 2 s 一次 PATCH/拉取的静默死循环 | 钉死:hash 来自本地送出的行,只有 seq 来自响应(§6) |
| M1 本地脏且基线缺失的分支未定义 → 新建行回应丢失后永远推不上去 | 基线缺失时 := (h_in, seq)(§6) |
| M2 「大批量只在 Restore 后」两头都错:Restore 会重播基线;真正的大批量是改每一行的 build,13.2k 行串行 ≈ 33 min | 8 路并发上限;`sync_push` RPC 列为 Phase 2 逃生口(§6) |
| M3 并集让 `SkillInsightStore.clearAll()` 变成「全账号销毁 insights 且永不重分析」 | nil vs 非 nil 基线 = 显式删除传播;含义挂 §10.4 |
| M4 settings 升级规则缺远端 hash 检查 → 自己上次的上传被当冲突进 shelf | 加远端 hash 分支;两边都变的一次性代价明示(§6) |
| L1 跨账号 restore 的同 UUID 被 DO NOTHING 静默吞 | `sync.push.orphan` 日志(§6) |
| L2 dashboard 删单行表 = 该账号永久推不上 settings | §5.4 明示 |
| L3 行锁/用户锁顺序死锁,自愈 | §9.17 |
| L4 `normalizedTitle`、小写 UUID 比较 | §6 |

第四轮认定站得住:READ COMMITTED 下条件 PATCH 不可能更新旧版本(EvalPlanQual);`return null` → `200 []`;ignore-duplicates 只返回插入的行;tombstone 与编辑的四种交错都收敛;级联在深度 2、authenticated 到不了深度 2;三种 HTTP 形状、零服务端代码是第三轮 blocker 换来的,不是过度设计。

### v1.4 变更记录(勘察后的六个缺口)

六个只读勘察(`design/realtime-sync @ 6a7e50b` 对 king `65fcd7a`,每条带 `path:line`)各提出一个设计稿没有回答的问题;一个 critic 汇总。处置原则不变:每个新规则要么有当前消费者,要么有触发它的测量判据;没有新增机制,只有把已有机制的使用方式钉死。

| 缺口 | 决定 | 依据 |
|---|---|---|
| 1 本分支叉在擦除战役之前;puller / applier 是 post-await 写入者;擦除会登出 | **先合 king 再写代码(P0.0)**;puller / applier 走 `LocalDataEraseEpoch`:RPC 前 `capture()`,每次落盘前紧挨 `isStale()`,全在 MainActor;`$session → nil` = 停门铃、丢内存游标 / 基线、取消在途 Task,**不持久化**;`ConflictShelf.wipe()` 进 `resetAllLocalData` 与 wiring 测试,`Sync/` 有 `-TestHost` 叶子断言(§6.4;§9.19 / 9.20) | `merge-tree` 今日无冲突但 king 动了 Phase 1 要改的四个文件;`EraseWiringQATests` 按源码字符串断言调用清单(king `:51-82`);`LocalDataEraseEpoch.swift:87-94` 零宽窗口靠门→写无挂起;擦除里 `signOut()`(`:938`)先于 `wipeAllPersistedHashes()`(`:947`);`ContentView.swift:580` `compactMap` 看不到 nil;自动普查已摘除,漏 purge 不会红 |
| 2 条件 PATCH 返回 `[]` 且内容相同时,拉取看不见该行,基线永不重设,每 2 s 重 PATCH | **内存 pending-verify 集合 `(table, id, sentSeq, sentHash / sentKeys, pullIssue)`**:`[]` → 入集合 + 拉一次;只有发号晚于 `[]` 的拉取(以返回短页的 RPC 计号)到 head 才清:见到的走三方比较,没见到且 `base.seq == sentSeq` → `hash := sentHash`(settings `keys := sentKeys`),没见到且不等 → 丢标记不动 hash;无 GET、无重试计数,进程死了下次重标(§6 上传形状;§9.2 改写;评审五 BLOCKER 的两种交错见 §6) | `015:90-92` 短路 `return null`、seq 不动;`sync_changes` 是 `seq > since_seq`(`015:245-272`);`rowHash` 的 NSNull 键 / `String(describing:)` 渲染是真实可造的编码变更(`SupabaseSyncService.swift:267-302`);§9.2 原文只论证了干净行;13.2k 行的规模来自 §6 既有估算 |
| 3 slot 冻结 / `calendarLogGenerationUnproven` 时 `persist` 返回 false,单游标怎么走 | **每页每 slot 一次 persist**;冻结预检 → 整页拒绝;提交时拒写 → 已成功 slot 保留基线、其余不写、游标不动;每次拉取一条 `sync.apply.refused`;被拒页不计入 I1;九表入站停、经 I1 九表出站停,直到用户确认的 restore / 擦除;unproven 停到下一次 log 读、最坏下次启动;**applier 永不清 fault**;per-table 游标维持否决(D2);不依赖 `onSlotCommitted`,I3 靠 MainActor 调用顺序;logs / feedback 的同步 seam 点名(§4 I1–I3;§6.1;§9.23) | `EventStore.swift:1310-1313` 冻结返回 false 不入 `writeFailedSlots`;`:1358-1362` unproven 走 catch;`:4076-4081` 自动解冻会把空数组写到最后一份可读副本上;`:1352-1356` skipped 不触发 `onSlotCommitted`;`DurableEventStorage.swift:1045` unproven 自释放;`exportSuppressed`(`SupabaseSyncService.swift:1040`)是出站侧同一判断 |
| 4 参考时区键在按键合并下会让新机的自冻时区覆盖老机的已建立时区;解码行会先冻结时区 | **账号上先建立者胜**:applier 只在本地没有 series occurrence 记录时采用远端(经 `applyRestoredIdentifier`,注释改),永不自动覆盖,不同则保留本地 + `sync.conflict key=zone`,不进 shelf;pusher 服务端有值取服务端;**时区先行**:游标缺失时先 GET `user_settings` 应用时区,再解码任何 logs / feedback 行;已建立分歧 Phase 1 接受、不建 re-key;P0.3 只读检查生产时区值(§6.2;§9.21) | 键在 `SyncedSettings.allKeys` 且 bridged(`SyncedSettings.swift:125`、`:138-141`);`OccurrenceKeyMetadataStore.swift:120-145` 首次 mint 冻结;`:243` `applyRestoredIdentifier` 注释「用户确认路径专用」;`decodeOccurrenceKey` 在 `+Restore.swift:544` / `:555` mint;今天 restore 先解码(`:224-225`)后应用设置(`RestoreCoordinator.swift:394-401`);`encodeOccurrenceKey`(`:1494`)只在 series id 里含 dayKey;仓库里没有 re-key 路径 |
| 5 三个新存储放哪、用什么原语、按不按 uid 键、进不进备份 | 基线留 UserDefaults `syncHashes.<uid>.<table>`,值 `<hash>@<seq>`(旧 `<hash>` = seq 未知),settings 值改 JSON `{seq, keys}`;游标 = `syncHashes.<uid>.cursor`;shelf = `Application Support/Sync/` 追加式 JSON-lines,行带 uid,进备份,`ConflictShelf.wipe()`;路径不带 uid;`persistAllHashes` 式整批替换保留(§6.3;§9.20 / 9.25) | `sweepUnknownEntries`(`DurableEventStorage.swift:626-646`)删 `EventStore/` 里一切非白名单;`OccurrenceKeyMetadataStore.swift:304-315` 是兄弟目录 + `-TestHost` + `/dev/null` 模板;`wipeAllPersistedHashes`(`:845`)与 `loadHashes`(`:764`)按前缀;`didChangeNotification` sink(`:578`)今天已被 `persistHashes` 触发且被哈希守卫吸收;`EventStorageLocation.swift:105-119` 明令不设备份排除键;`AtomicValueFile` 冻结会让基线永远拿不到新 seq |
| 6 `latency_ms` 没有定义,feed 里没有服务端时间,四种触发没有帧 | `latency_ms` = B 本机 `ContinuousClock` 从 `onChange` 边界到 slot 提交,只在 `reason=doorbell`;`age_ms` = B.now − `row.synced_at`,参考值、clamp 0、不做门槛;≤ 2 s 验收从 A 的上传算起(§2 目标 1 改写);不加服务端时间列(§6.5;§7 验收) | `latency_ms` 全仓只出现在 §7 一句;门铃 payload 只有 `{table, seq}`、`sync_changes` 返回 `to_jsonb(row)`、v2 砍掉 `server_updated_at`;`synced_at` 是九表唯一统一的上传时刻戳(`SupabaseSyncService.swift:1202-1213`),`updated_at` 在两张表不存在、在两张表是编辑时刻;`debounceSeconds = 2.0`(`:24`)让「从编辑算起 ≤ 2 s」不可达;`RealtimeChange` 无时间字段(`SupabaseRealtimeDoorbell.swift:79-93`) |
| 附:EventStore / 出站勘察的 gotcha | (a) I2 靠 restore 先例同 tick 重播基线,删掉 `persist(origin: .remote)` 措辞;(b) 远端 tombstone 复用两条 delete 级联加 `unlinkAssets: false`,todo 绕过 `stopTimerOnCalendarEvent`,远端插入绕过 `add/updateCalendarEvent`(LLM 入口)直接写数组 + `saveCalendarEvents(refreshInterrupts: true)` + 纯 saver,事件不在本地的 log / feedback 仍按 key 插入;(c) 有会话时 `seedsSampleDataIfEmpty: false`;(d) domino 双机接受,计数实测(§9.22);(e) D9 `register(defaults:)` 默认 ON、总闸门控双向、交互式登录置 true;D7 iOS only;D8 本地台架、015 直上生产;§10.4 清空 = 全账号;(f) `fetchAll` 加 `deleted_at=is.null`;(g) 015 在 main 部署 glob 里,先有意应用再合(§9.24);(h) 服务端读取面加 `deleted_at is null`,并行实现中 | `EventStore.swift:1306` 无 `origin:` 参数;`RestoreCoordinator.swift:486` 的 `markRestoreCompleted` 时序;`:2577` `commitStagedAssetDeletion` 在 delete 第 4 步;`:2492` / `:2499` / `:3664` 触发 `onCalendarEventRecordCompleted` / `calendarEventRecorded`;`EventStore+OccurrenceRecords.swift:38` / `:128` 事件缺席时静默丢弃;`:800` / `:921` 种子默认;`:502` domino;`:175` `fetchAll` 无 `deleted_at` 过滤;`supabase.yml:7` / `:31` 的 glob 与循环;`functions/api/index.ts` 在 `6a7e50b` 还没有 `deleted_at` 过滤(`:20-24` 的四个 `.eq("user_id")` 都是裸的),工作树里另一位 agent 的改动未提交(`git status --short` 为 ` M`,工作树文件里已有 8 处 `deleted_at`),提交后再引行号 |

评审第五轮(独立 reviewer,只看 v1.4 初稿,`design/realtime-sync @ 6a7e50b`,用算术推交错)与处置:

| 发现 | 处置 |
|---|---|
| **BLOCKER** pending-verify「任何到 head 的拉取都清、没见到即相同」:在途轮询先于 `[]` 发出时把本地编辑 c1 标干净再被 c2 覆盖(目标 3);PATCH 在途期间拉取已改基线时把过期当相同、c1 永不上传(目标 2) | 元素改为 `(table, id, sentSeq, pullIssue)`:只有发号晚于 `[]` 的拉取能清;没见到且 `base.seq == sentSeq` 才判相同,否则丢标记不动 hash(§6 上传形状,两种交错原文保留;§8 两条变异体;§9.2) |
| MAJOR §6.1 粒度自相矛盾:「第一条被拒行」预设逐行 persist,但 I3 说每次 persist 后写基线,又说「这页不碰基线」 | 定为每页每 slot 一次 persist;冻结走预检整页拒绝;提交时拒写保留已成功 slot 的基线、游标不动;被拒页不计入 I1;§6 加 `seq == base.seq` 跳过让重拉幂等(§4 I1 / I3;§6;§6.1) |
| MAJOR §6.2 `.fresh` 条件在真机上几乎永不成立(首次画日历就冻结,没有登录墙) | 采用条件改为「本地没有 series occurrence 记录」;写入 seam 点名 `applyRestoredIdentifier` 且注释改;§8 双时区收敛测试(§6.2;§9.21) |
| MAJOR 示例数据规则没封住「首启种子 → 登录 → 种子上传」 | 种子器记 `{id: hash}`,首次拉取前删未改的种子,改过的保留;`offerAutoRestoreIfNeeded` 退役;harness 断言首次 flush 0 行(§6 示例数据;§8;§9.27) |
| MAJOR D9 擦除后「直到用户再登录」不成立(擦除显式写 false,键不在重置列表,登录不翻) | 交互式登录成功置 true(两个 sign-in 站点,不是 `installSession`);默认 ON 经 `register(defaults:)`,显式 OFF 保留(D9;§9.28;§10.2) |
| MAJOR pending-verify 按 id 会让三张单行表(id == uid)互相清标记 | 键为 `(table, id)`,并入 BLOCKER 的改写(§6 上传形状) |
| MAJOR logs 路径有 400 ms 防抖提交,`persist 同步返回 Bool` 只对非 coalesced saver 成立 | 点名 `commitLogRecordsNow()` / `saveCalendarEventFeedbackRecords()`,禁用 `upsertLogRecord(coalesced:)` 路径(§4 I3;§6 logs 段) |
| minor 引用:015 短路在 `:90-92`;frozen guard 在 `:1310-1313`;`loadHashes` 不读 cursor 键;`api/index.ts` 的 `deleted_at` 是未提交改动;unproven 停到下一次读而非一次拉取;king wiring 列表 `:51-78` + 循环 `:80-82` | 全部改入正文(§6、§6.1、§6.3、§6.4、§13 gap 2 / 3 / (h)) |
| minor 降级到旧 build 的一次性 13k 重推 | §6.3 末条 + §9.26 |
| minor §6.2 没点名写入 seam | `applyRestoredIdentifier` + 注释修订(§6.2) |
| minor `age_ms` 对单行表量的是上次设置上传 | §6.5 一句注明(评审六证伪:hash 守卫 + 015 `meta` 排除 `synced_at`,已改为「量的是上次内容变更」) |

第五轮认定站得住:其它 king 行号(`:122-154`、`:938` / `:947`、`LocalDataEraseEpoch :49-63` / `:87-94`)在 `65fcd7a` 上核对无误,P0.0 后会移动;所有拒写粒度的猜法对数据都安全(重拉幂等、I1 挡上传),缺的只是定一个。

评审第六轮(独立 reviewer,只看 v1.4 在盘文本与 `git diff -- Docs/sync`,`design/realtime-sync @ 6a7e50b` / king `65fcd7a`,全部引用重核)与处置:

| 发现 | 处置 |
|---|---|
| **BLOCKER** pending-verify 元素没有 `sentHash`:清标记发生在之后的拉取完成时,实现者手里只有当前本地行;13k 行 27 次 RPC 的窗口里用户再改 X → 从活行重算 → 新编辑被标干净、永不上传(目标 2,(ii) 的失败类) | 元素加一个字段 `sentHash`(内存,不落盘);清标记写 `base.hash := sentHash`,绝不重算;§6 上传形状加交错 (iii);§8 第三条变异体「从活行重算」必须红;§9.2 补一句(§4 / §6 / §7 / §8 / §9.2) |
| **BLOCKER** 种子规则按「hash 未变」删行会删掉用户的笔记:完成 / 笔记 / 情绪 / 反馈只写记录数组,`Event` 行不动;唯一允许的删除路径是 `deleteCalendarEvent` 级联,其第 3 步剪 log / feedback;绕过级联则上传孤儿 log | 可删条件改为三条同时成立(指纹未变 ∧ 无 log / feedback 指向它 ∧ 非 interrupt 父);删除 = 数组移除 + 一次 `saveCalendarEvents(refreshInterrupts: true)`,不走级联;§8 种子测试加反例「未改行上写笔记 → 行与 log 都上传」;§9.27 改写(§6 示例数据;§7;§8;§9.27) |
| **MAJOR** 种子规则按写法是空操作:`rowHash` 文件级 private(`:267`)、`eventToRowForHashing` private 实例方法(`:1220`)且投影含 `user_id`(`:1262`),种子跑在 `EventStore.init`(`:921`)无 uid → 种子时刻与检查时刻的 hash 永不相等 → 全部上传,harness 红 | 点名 seam:`static SupabaseSyncService.seedFingerprint(_:)` = 去掉 `user_id` 的同一投影的 `rowHash`,投影与 `rowHash` 升为 static、`userId` 变参数、`eventToRow` 改调它(投影仍单源);§8 加「两时刻指纹相等」前置断言(§6 示例数据;§7) |
| **MAJOR** §6.1 对 shelf 追加失败沉默,且级联自带保存:满盘时 shelf 静默失败 → tombstone + dirty 下 c1 哪里都不在;update + dirty 下 c2 哪里都不在;级联返回 Void,实现者会去读 `writeFailedSlots` | 一页两遍:第一遍只读比较 + shelf 追加(每次追加紧挨 `isStale`),任何追加失败整页拒绝(同冻结预检);第二遍才改内存、走级联;级联结果由页末对 calendarEvents 的真写 persist 的 Bool 观察(delta skipped 要求盘 == 最后确认数组,`:1340-1356`),不读 `writeFailedSlots`;追加按 `(uid, table, id, seq)` 去重;§6.4 isStale 列表加失败支;§9.29(§4;§6;§6.1;§6.3;§6.4;§8;§9.29) |
| **MAJOR** user_settings 的清标记写不出来:基线是 `{seq, keys}` 没有行 hash;不动每键 hash 则行保持脏 → `[]` → 每 5 s 重标,一行版风暴 | user_settings 的元素带送出 blob 的每键 hash 表 `sentKeys`,清标记写 `keys := sentKeys`;agent_* 整行只带 `sentHash`(§6 上传形状;§13 gap 2) |
| minor `pullIssue` 一次拉取多页,哪次 RPC 的号算「这次拉取的」 | 返回短页的那次;按 I5 正确,首页号也安全只是晚一轮(§6 上传形状) |
| minor I1 在拒页后必须是 flush 时刻读的标志,不是调度时刻 | §4 I1 一句:applier 拒页翻 false,出站 sink 防抖到期后读 |
| minor 停页重拉会把同一来件再追加进 shelf | 追加按 `(uid, table, id, seq)` 去重(§6.1;§6.3) |
| minor §6.5 「单行表每次 flush 重盖 `synced_at`」两处错:`syncSettings` 有 hash 守卫(`:886-887`),015 的 `meta` 排除 `synced_at`(`015:71` / `:90-92`),相同 upsert `return null` | 改写:它们的 `age_ms` 量的是上次内容变更,与其它行同义(§6.5) |
| minor 时区先行在第一页之前跑,没说受 §6.1 冻结预检门控;冻结 slot 的空数组会满足采用条件 | 门控于同一预检;明示不门控的结果也恰好无害(唯一解冻是 restore 整 slot 替换),但不留「恰好」(§6.2) |
| minor(核实无发现)`CalendarOccurrenceKey ==` 对 single 事件不比 dayKey(`CalendarEventFeedback.swift:143-168`),采用条件的安全性立在这一行 | §6.2 加引用 |
| minor 升级时离线编辑过的行会把自己的旧基线进 shelf 一次 | §6.3 升级段明示:无丢失,一条无意义 shelf 行 / 行,`sync.conflict` 升级后一次尖峰 |
| minor §13 (h) 行号:裸 `.eq("user_id")` 在 `api/index.ts:20-24`(四处),工作树 8 处 `deleted_at` | 改正 |
| minor 退役 `offerAutoRestoreIfNeeded` 要连 king 按前缀扫 `hasOfferedAutoRestore.` 的那一行一起删,否则 `EraseWiringQATests` 的字符串断言漂 | 半驳回:扫描行在 king `AgentSettingsView.swift:992`(`:935` 不是它,`:927` 是提它的注释),**一起删**;但 `EraseWiringQATests` 在 `65fcd7a` 全文不含 `hasOfferedAutoRestore`(`git show 65fcd7a:DoneTests/EraseWiringQATests.swift \| grep` 为零),不存在会漂的断言,删它是去死代码不是保测试(§6 示例数据) |

第六轮认定站得住:全部 `path:line` 在 `6a7e50b` / `65fcd7a` 上核对无误;`git merge-base --is-ancestor 739fee9 HEAD` 为假是 P0.0 之前的预期状态;delta 没有重新引入任何 v1 减法(pending-verify 与 `sentHash` 都在内存;无 GET、无重试计数、无 per-table 游标、无服务端列);`01-realtime-protocol-notes.md` 未动。

第七轮(**本地台架实测**,`supabase start` 栈 PG 17 + realtime v2.82.0,`done-mcp/supabase/tests/sync_feed_checks.{sql,sh} @ 6f293a8`;S1–S15 全部成立,S13 部分;服务端读取面 `deleted_at` 过滤同日提交 `1d8c830`)与处置——这一轮没有评审意见,只有观测值;凡与正文矛盾的,正文改:

| 发现 | 处置 |
|---|---|
| S3 / S4 / S11:PostgREST 只在 merge-duplicates POST **真插入**时回 201;命中已有行、被 BEFORE 触发器短路的内容相同 upsert 都回 200 | 全文状态码写 2xx 不写 201(§5 向后兼容「状态码」;§6 POST 段;§7 交付项) |
| S7:对 **tombstone 行**的条件 PATCH 被接受——`200 [row]`、新 seq、内容更新、`deleted_at` 保留(I6 只保 `deleted_at` 一列),设计稿原假设 I6 挡住一切普通写入 | §6 上传形状加**第三种响应**:`[row]` 且 `deleted_at` 非空 = 服务端已删,按 tombstone 来件处置(脏 → shelf、级联删本地、基线移除),绝不当成功;三张单行表上是永久态直到 undelete;§4 I8 一句;§8 `FakeServer` 必须模拟;§7 验收加一条;§9.31 |
| S2:DELETE 带 `return=representation` 对活行回 `200 []`,行此刻已 tombstone | 永不从 DELETE 响应体确认 tombstone;`PATCH deleted_at` 形状返回行,用它(§5.4;§6 删除段;§9.12 改写为已确认) |
| S12:内层门铃 payload 多一个 `realtime.send` 注入的 `"id"` 键:`{"id":<uuid>,"seq":N,"table":"events"}` | `RealtimeChange` 只解析 `table` / `seq`,无影响;协议笔记的 payload 示例补上 |
| S12:join 外人的私有 topic 被拒,`reason` 恰为 `Unauthorized: You do not have permissions to read from this Channel topic: user:<uid>`,与「token 无效」同 code | 两者都终端、不重试(都是客户端 bug);协议笔记错误表改写;§9.32 |
| S12:「Allow public access」ON(`_realtime.tenants.private_only = false`,realtime v2.82.0)下私有 channel **仍被强制**:外人的帧零漏;该开关禁的是公开 channel,不是给 `private: true` 开启强制 | 从「前置」降为纵深防御(§5.5;§7 P0.3;协议笔记「服务端半」);§9.32 |
| S15:锁序死锁的牺牲者是**单语句侧**(先进入等待、`deadlock_timeout` 先到期),批量侧提交 | 重试负担在单行 PATCH:`40P01` 按同一 seq 重发一次;批量 tombstone PATCH 不重试(§9.17 改写) |
| S5:`DELETE ?id=in.(5)` 响 5 帧;20 行一条 POST 响 1 帧(`seq` = 最大号);20 条单行 POST 响 20 帧 | §9.15 补数字;「帧数 ≤ 语句数」对 upsert 成立,数字坐实 |
| S6:账号擦除**零门铃帧**;已 tombstone 的行同样物理消失 | 被擦账号的其它设备在下一次拉取吃 401 后登出,不靠门铃;擦除不留 tombstone(§5.4;§9.13 改写为已确认) |
| S13:`encodeJSONOrNull` 对空数组送 `null`,`agent_preferences.rules` / `decision_history` 是 `jsonb not null` → 400 `23502`;与 015 无关的既有缺陷,零规则用户从未上传过这张表 | Phase 1 出站切片对这两列送 `[]`,读侧 `[]` 当空(§6 agent_* 段;§7 交付项 + 验收正对照;§9.30) |
| S7:PATCH 体里带 `seq`、带本行 `user_id` 无害(触发器覆盖 seq;同用户 no-op;改成别人 → 403 `42501`) | 客户端不必从行里剥 `seq`(§5.2 一句),少一处投影分叉 |
| S9:`event_logs` 含管道符与 `none` 的 id,原样 / 编码、`in.()` / `eq.` 四种写法全接受 | 不建编码规则;`SupabaseSyncService.swift:137-138` 保持不编码(§6 event_logs 段);P0.3 清单该项关闭 |
| S10(SQL):`sync_changes` 以 authenticated 身份走 `idx_events_user_seq`(`Index Cond: user_id = auth.uid() AND seq > since`),4k 行上 50 行一页 0.34 ms;`page_limit` 超上限被夹紧 | 第二轮「RLS 谓词下 `(user_id, seq)` 索引可用」的推断坐实(§5.5) |
| `1d8c830` 评审:服务端读取面已过滤 `deleted_at`,但 015 不级联——父事件 tombstone 后它的 logs 在服务端仍是活行,服务端读者直到客户端推子行 tombstone 之前都看得到 | 写明子行 tombstone 是客户端级联 + 集合差分上传的义务,窗口以秒计,不建服务端级联触发器;`skill_insights` 无 event id 不在任何级联里,今天就留(§5.4;§6 events 段) |
| S11:king 的 Restore `GET … Range` 把 tombstone 行一起返回 | 015 应用到生产后、Phase 1 装机前,king Restore 会把删过的行带回本地,窗口期不按 Restore(§5 状态码段;§6 Restore 路径;§7 交接单 (5)) |
| 生产应用的操作面(台架跑迁移的观察):`lock_timeout 3s`;回填在触发器之前;边缘函数要同窗口重部署;验后要看 policy / owner / RPC 可达 | 写成 §7 的交接单 (1)–(5),含 `notify pgrst, 'reload schema'` 与硬删要先 disable 触发器 |

第七轮认定站得住(台架直接验证,原文不动):用户级锁下取号序 = 提交序、别的用户不被阻塞、第三连接看不到未提交的号(S1);tombstone 抗 `deleted_at: null` 的 upsert(S3);内容相同 upsert 不取号不响铃(S4);service_role 的 DELETE 也变 tombstone(S14);ignore-duplicates POST 只回插入的行且已有行不动(S8);tombstone PATCH 的客户端时间戳原样入库、第二次回 `[]`(S9);`sync_changes` 只回本人的行、按 seq 升序、短页即 head、仅 apikey 被拒(S10);单对象 `Accept` 0 行 406(S7);king 三形状不报错(S11)。P0.3 原清单里唯一被证伪的是「关 Allow public access 后才强制私有」。

第七轮的减法:不建服务端级联触发器、不建 id 编码规则、不给 DELETE 加确认读、不为 topic 授权失败加重试、不为 `40P01` 加计数器(重发一次,再失败就是下一轮 flush 的事)。

v1.4 的减法:不建第二个云项目、不建 per-table 游标、不建 re-key、不加服务端时间列、不加 `persist(origin:)`、不加 `fetchOne` GET、不加重试计数、不给 shelf 设备份排除键、不给基线用 `AtomicValueFile`、不给门铃配 background session、不新建总闸键、不为 §10.4 建任何东西。
