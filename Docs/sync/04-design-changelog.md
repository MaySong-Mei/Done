# 全平台单账号实时同步 — 设计变更记录

`Docs/sync/00-realtime-sync-design.md`(下称「契约」)的变更史。2026-10-19 从契约原样搬出两块:契约头部第 3–4 行的日期史(下一节),与契约的 §13 全部(再下一节,标题与表格一字不改,所以契约与其它文件里「§13 第七轮表」「§13 v1.5 表末」「round-nine §13 row」之类的引用在这里按同名的表找)。之后每轮的新行加在文件末尾。契约是规则,这里只是记录;两者不一致时以契约为准。

## 契约原头部第 3–4 行(2026-10-19 原样搬出)

日期:2026-10-08(v0)· 2026-10-12(v1,独立评审第一轮后)· 2026-10-14(v1.4,代码勘察后的六个缺口;同日评审第五轮:1 BLOCKER + 6 MAJOR;第六轮:2 BLOCKER + 3 MAJOR + 9 minor——全部改入正文,或在 §13 以 `path:line` 证据驳回;**同日第七轮:本地台架实测**,`done-mcp/supabase/tests/ @ 6f293a8`,S1–S15 全绿、S13 部分,十三条修正改入正文;**同日评审七(对台架版文本的对抗评审):1 BLOCKER + 4 MAJOR + 9 minor,全部改入正文**;**同日第八轮:形式化模型**,`verification/CivilCalendar/SyncMerge.lean`(Lean 4,另一 agent 在途),1 条规则加强(跳过行 `==` → `≤`)+ 4 条钉死 + 1 条新风险;**第九轮:冲突行基线**,冲突行与 pending-delete 行改写 `(h_in, seq)`、settings 冲突键写远端 hash、`skillAnalyzedEventIds` 并集排序;两轮均见 §13 末表)· **2026-10-18(v1.5,业内调研回写)**:`Docs/sync/02-industry-survey.md @ 3c8d1af`(下称「调研」,条目编号 G / M / S / L / X 指它)的 must-before-local-test(M1–M7)与 should(S1、S4–S11、S12 的检测半、S13)全部写成正文规则,三项待用户拍板(M4 / S2 / S12)挂 §10.5–10.7 并在每个依赖处注明,later / reject(L* / X*)带触发条件进 §9.36 / §13;§8 整节换成调研的分层本地测试计划与信心判据;调研证伪的旧文本(§9.22「同一个 horizon 日」、60 s 轮询的删除规则、「管理员先 disable 触发器再硬删」、I1 的 2000 上界、§9.13「下一次拉取吃 401」、§9.11 的 token 推送、§9.35「不建机制」)就地改写,见 §13 末表;**同日对 v1.5 在盘文本的评审:1 BLOCKER + 4 MAJOR + 7 minor,全部改入正文**——S4 改为发送时记 `?`、结果对基线条目做比较交换,M2 改为按基线 seq 判别、每页应用前查 epoch、重置只在链边界、纪元并进游标键,回滚的重新启用由同一条 epoch 语句覆盖,见 §13 末表后半;**同日 fresh-eyes 评审(对 v1.5 修订稿 `f57c024`):2 BLOCKER + 7 MAJOR + 9 minor,另并入 Lean 流的三条遗留规则,全部改入正文或带证据驳回**——游标代次对本页出现的每张表推进(含跳过行)、tombstone 级联剪掉的脏子记录进 shelf、在途写的回声行与按发送 token 的比较交换、每表单飞 flush、恢复后序列跳号(`resume`)、服务端暂停位(`paused`)、S12 检测的三种结局,见 §13 v1.5 表末「fresh-eyes」各行;本轮新引用标 `@ f57c024`;**10-19 fresh-eyes 复核(对 `e7a31e5`,三位 reviewer 27 条)**:恢复不回拨计数器 + 累积 `lost` 取代 `resume` 跳号,撤掉页等在途写、首登删种子与 `age_ms`,见 §13 v1.5 表末「复核」各行 · 基线:king `65fcd7a`(擦除战役已合;**P0.0 已完成**:`282119b` 把 king 合进本分支,`git merge-base --is-ancestor 739fee9 HEAD` 为真,见 §6.4)/ mac `feat/donemac-phase1 @ d88f783` / Supabase `uqnvtzblppjblwgbpqhf`(PG 17.6)
状态:**设计稿,D7 / D8 / D9 / §10.4 已于 2026-10-14 拍板;§10.5–10.7 三项待拍板(2026-10-18);015 v4 已在本地台架全绿,v5(M1 / M2 的改动)待合成一次重跑(§7 P0.3、§8.3);生产未应用**(v1.4 / v1.5 改了什么见 §13 末尾)。v1.5 从调研搬来的代码引用指 slice 1 的 `a95690b`(本分支 HEAD 的祖先),行号以调研复核时为准。所有「现状」条目均为实测,不是转述文档;标「台架」的指本地 `supabase start` 栈上的 `sync_feed_checks.{sql,sh}` 观测值,不是生产;代码引用形如 `path:line`,均指 `design/realtime-sync @ 6a7e50b`,标 king 的指 `king-of-rubbish-bin @ 65fcd7a`——**两者现在都是本分支 HEAD 的祖先**(P0.0 合并 `282119b`),每条引用在各自的 commit 上仍核得到;合并后 HEAD 上 `EventStore.swift` 的行号在合入区之后整体后移(`deleteCalendarEvent` 2621→2713、`commitLogRecordsNow` 1648→1662、`stopTimerOnCalendarEvent` 3664→3756),`AgentSettingsView` / `AuthService` / `ContentView` 同理(king 的行号在 HEAD 上也变了:`resetAllLocalData` 置 false 在 `:884`,`signOut()` 在 `:946`、`wipeAllPersistedHashes` 在 `:955`)。引用不在本版重锚;Phase 1 第一个代码 commit 按 HEAD 重锚。

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
| D 60 s 轮询无测量 | 带 reason 计数,一个 build 内零命中则删(§7)(**v1.5 撤销**:轮询常驻当看门狗,M5) |
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
| 1 本分支叉在擦除战役之前;puller / applier 是 post-await 写入者;擦除会登出 | **先合 king 再写代码(P0.0;已于 `282119b` 完成)**;puller / applier 走 `LocalDataEraseEpoch`:RPC 前 `capture()`,每次落盘前紧挨 `isStale()`,全在 MainActor;`$session → nil` = 停门铃、丢内存游标 / 基线、取消在途 Task,**不持久化**;`ConflictShelf.wipe()` 进 `resetAllLocalData` 与 wiring 测试,`Sync/` 有 `-TestHost` 叶子断言(§6.4;§9.19 / 9.20) | `merge-tree` 今日无冲突但 king 动了 Phase 1 要改的四个文件;`EraseWiringQATests` 按源码字符串断言调用清单(king `:51-82`);`LocalDataEraseEpoch.swift:87-94` 零宽窗口靠门→写无挂起;擦除里 `signOut()`(`:938`)先于 `wipeAllPersistedHashes()`(`:947`);`ContentView.swift:580` `compactMap` 看不到 nil;自动普查已摘除,漏 purge 不会红 |
| 2 条件 PATCH 返回 `[]` 且内容相同时,拉取看不见该行,基线永不重设,每 2 s 重 PATCH | **内存 pending-verify 集合 `(table, id, sentSeq, sentHash / sentKeys, pullIssue)`**:`[]` → 入集合 + 拉一次;只有发号晚于 `[]` 的拉取(以返回短页的 RPC 计号)到 head 才清:见到的走三方比较,没见到且 `base.seq == sentSeq` → `hash := sentHash`(settings `keys := sentKeys`),没见到且不等 → 丢标记不动 hash;无 GET、无重试计数,进程死了下次重标(§6 上传形状;§9.2 改写;评审五 BLOCKER 的两种交错见 §6) | `015:90-92` 短路 `return null`、seq 不动;`sync_changes` 是 `seq > since_seq`(`015:245-272`);`rowHash` 的 NSNull 键 / `String(describing:)` 渲染是真实可造的编码变更(`SupabaseSyncService.swift:267-302`);§9.2 原文只论证了干净行;13.2k 行的规模来自 §6 既有估算 |
| 3 slot 冻结 / `calendarLogGenerationUnproven` 时 `persist` 返回 false,单游标怎么走 | **每页每 slot 一次 persist**;冻结预检 → 整页拒绝;提交时拒写 → 已成功 slot 保留基线、其余不写、游标不动;每次拉取一条 `sync.apply.refused`;被拒页不计入 I1;九表入站停、经 I1 九表出站停,直到用户确认的 restore / 擦除;unproven 停到下一次 log 读、最坏下次启动;**applier 永不清 fault**;per-table 游标维持否决(D2);不依赖 `onSlotCommitted`,I3 靠 MainActor 调用顺序;logs / feedback 的同步 seam 点名(§4 I1–I3;§6.1;§9.23) | `EventStore.swift:1310-1313` 冻结返回 false 不入 `writeFailedSlots`;`:1358-1362` unproven 走 catch;`:4076-4081` 自动解冻会把空数组写到最后一份可读副本上;`:1352-1356` skipped 不触发 `onSlotCommitted`;`DurableEventStorage.swift:1045` unproven 自释放;`exportSuppressed`(`SupabaseSyncService.swift:1040`)是出站侧同一判断 |
| 4 参考时区键在按键合并下会让新机的自冻时区覆盖老机的已建立时区;解码行会先冻结时区 | **账号上先建立者胜**:applier 只在本地没有 series occurrence 记录时采用远端(经 `applyRestoredIdentifier`,注释改),永不自动覆盖,不同则保留本地 + `sync.conflict key=zone`,不进 shelf;pusher 服务端有值取服务端;**时区先行**:游标缺失时先 GET `user_settings` 应用时区,再解码任何 logs / feedback 行;已建立分歧 Phase 1 接受、不建 re-key;P0.3 只读检查生产时区值(§6.2;§9.21) | 键在 `SyncedSettings.allKeys` 且 bridged(`SyncedSettings.swift:125`、`:138-141`);`OccurrenceKeyMetadataStore.swift:120-145` 首次 mint 冻结;`:243` `applyRestoredIdentifier` 注释「用户确认路径专用」;`decodeOccurrenceKey` 在 `+Restore.swift:544` / `:555` mint;今天 restore 先解码(`:224-225`)后应用设置(`RestoreCoordinator.swift:394-401`);`encodeOccurrenceKey`(`:1494`)只在 series id 里含 dayKey;仓库里没有 re-key 路径 |
| 5 三个新存储放哪、用什么原语、按不按 uid 键、进不进备份 | 基线留 UserDefaults `syncHashes.<uid>.<table>`,值 `<hash>@<seq>`(旧 `<hash>` = seq 未知),settings 值改 JSON `{seq, keys}`;游标 = `syncHashes.<uid>.cursor`;shelf = `Application Support/Sync/` 追加式 JSON-lines,行带 uid,进备份,`ConflictShelf.wipe()`;路径不带 uid;`persistAllHashes` 式整批替换保留(§6.3;§9.20 / 9.25) | `sweepUnknownEntries`(`DurableEventStorage.swift:626-646`)删 `EventStore/` 里一切非白名单;`OccurrenceKeyMetadataStore.swift:304-315` 是兄弟目录 + `-TestHost` + `/dev/null` 模板;`wipeAllPersistedHashes`(`:845`)与 `loadHashes`(`:764`)按前缀;`didChangeNotification` sink(`:578`)今天已被 `persistHashes` 触发且被哈希守卫吸收;`EventStorageLocation.swift:105-119` 明令不设备份排除键;`AtomicValueFile` 冻结会让基线永远拿不到新 seq |
| 6 `latency_ms` 没有定义,feed 里没有服务端时间,四种触发没有帧 | `latency_ms` = B 本机 `ContinuousClock` 从 `onChange` 边界到 slot 提交,只在 `reason=doorbell`;`age_ms` = B.now − `row.synced_at`,参考值、clamp 0、不做门槛;≤ 2 s 验收从 A 的上传算起(§2 目标 1 改写);不加服务端时间列(§6.5;§7 验收) | `latency_ms` 全仓只出现在 §7 一句;门铃 payload 只有 `{table, seq}`、`sync_changes` 返回 `to_jsonb(row)`、v2 砍掉 `server_updated_at`;`synced_at` 是九表唯一统一的上传时刻戳(`SupabaseSyncService.swift:1202-1213`),`updated_at` 在两张表不存在、在两张表是编辑时刻;`debounceSeconds = 2.0`(`:24`)让「从编辑算起 ≤ 2 s」不可达;`RealtimeChange` 无时间字段(`SupabaseRealtimeDoorbell.swift:79-93`) |
| 附:EventStore / 出站勘察的 gotcha | (a) I2 靠 restore 先例同 tick 重播基线,删掉 `persist(origin: .remote)` 措辞;(b) 远端 tombstone 复用两条 delete 级联加 `unlinkAssets: false`,todo 绕过 `stopTimerOnCalendarEvent`,远端插入绕过 `add/updateCalendarEvent`(LLM 入口)直接写数组 + `saveCalendarEvents(refreshInterrupts: true)` + 纯 saver,事件不在本地的 log / feedback 仍按 key 插入;(c) 有会话时 `seedsSampleDataIfEmpty: false`;(d) domino 双机接受,计数实测(§9.22;**v1.5 证伪**,M4);(e) D9 `register(defaults:)` 默认 ON、总闸门控双向、交互式登录置 true;D7 iOS only;D8 本地台架、015 直上生产;§10.4 清空 = 全账号;(f) `fetchAll` 加 `deleted_at=is.null`;(g) 015 在 main 部署 glob 里,先有意应用再合(§9.24);(h) 服务端读取面加 `deleted_at is null`,并行实现中 | `EventStore.swift:1306` 无 `origin:` 参数;`RestoreCoordinator.swift:486` 的 `markRestoreCompleted` 时序;`:2577` `commitStagedAssetDeletion` 在 delete 第 4 步;`:2492` / `:2499` / `:3664` 触发 `onCalendarEventRecordCompleted` / `calendarEventRecorded`;`EventStore+OccurrenceRecords.swift:38` / `:128` 事件缺席时静默丢弃;`:800` / `:921` 种子默认;`:502` domino;`:175` `fetchAll` 无 `deleted_at` 过滤;`supabase.yml:7` / `:31` 的 glob 与循环;`functions/api/index.ts` 在 `6a7e50b` 还没有 `deleted_at` 过滤(`:20-24` 的四个 `.eq("user_id")` 都是裸的),工作树里另一位 agent 的改动未提交(`git status --short` 为 ` M`,工作树文件里已有 8 处 `deleted_at`),提交后再引行号 |

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

第六轮认定站得住:全部 `path:line` 在 `6a7e50b` / `65fcd7a` 上核对无误;`git merge-base --is-ancestor 739fee9 HEAD` 为假是 P0.0 之前的预期状态(P0.0 随后于 `282119b` 完成,第七轮评审核出正文没跟上);delta 没有重新引入任何 v1 减法(pending-verify 与 `sentHash` 都在内存;无 GET、无重试计数、无 per-table 游标、无服务端列);`01-realtime-protocol-notes.md` 未动。

第七轮(**本地台架实测**,`supabase start` 栈 PG 17 + realtime v2.82.0,`done-mcp/supabase/tests/sync_feed_checks.{sql,sh} @ 6f293a8`;S1–S15 全部成立,S13 部分;服务端读取面 `deleted_at` 过滤同日提交 `1d8c830`)与处置——这一轮没有评审意见,只有观测值;凡与正文矛盾的,正文改:

| 发现 | 处置 |
|---|---|
| S3 / S4 / S11:PostgREST 只在 merge-duplicates POST **真插入**时回 201;命中已有行、被 BEFORE 触发器短路的内容相同 upsert 都回 200 | 全文状态码写 2xx 不写 201(§5 向后兼容「状态码」;§6 POST 段;§7 交付项) |
| S7:对 **tombstone 行**的条件 PATCH 被接受——`200 [row]`、新 seq、内容更新、`deleted_at` 保留(I6 只保 `deleted_at` 一列),设计稿原假设 I6 挡住一切普通写入 | §6 上传形状加**第三种响应**:`[row]` 且 `deleted_at` 非空 = 服务端已删,按 tombstone 来件处置(脏 → shelf、级联删本地、基线移除),绝不当成功;三张单行表上是永久态直到 undelete;§4 I8 一句;§8 `FakeServer` 必须模拟;§7 验收加一条;§9.31。**评审七修正**(下表第二、三行):id 表按规则到不了这个响应(另一台的 tombstone 取了新号,本机拿到 `[]`),它是守卫;单行表上才是常规路径,且基线跟死行 seq 走、不循环 |
| S2:DELETE 带 `return=representation` 对活行回 `200 []`,行此刻已 tombstone | 永不从 DELETE 响应体确认 tombstone;`PATCH deleted_at` 形状返回行,用它(§5.4;§6 删除段;§9.12 改写为已确认) |
| S12:内层门铃 payload 多一个 `realtime.send` 注入的 `"id"` 键:`{"id":<uuid>,"seq":N,"table":"events"}` | `RealtimeChange` 只解析 `table` / `seq`,无影响;协议笔记的 payload 示例补上 |
| S12:join 外人的私有 topic 被拒,`reason` 恰为 `Unauthorized: You do not have permissions to read from this Channel topic: user:<uid>`,与「token 无效」同 code | 两者都终端、不重试(都是客户端 bug);协议笔记错误表改写;§9.32 |
| S12:「Allow public access」ON(`_realtime.tenants.private_only = false`,realtime v2.82.0)下私有 channel **仍被强制**:外人的帧零漏;该开关禁的是公开 channel,不是给 `private: true` 开启强制 | 从「前置」降为纵深防御(§5.5;§7 P0.3;协议笔记「服务端半」);§9.32 |
| S15:锁序死锁的牺牲者是**单语句侧**(先进入等待、`deadlock_timeout` 先到期),批量侧提交 | 重试负担在单行 PATCH:`40P01` 按同一 seq 重发一次;批量 tombstone PATCH 不重试(§9.17 改写) |
| S5:`DELETE ?id=in.(5)` 响 5 帧;20 行一条 POST 响 1 帧(`seq` = 最大号);20 条单行 POST 响 20 帧 | §9.15 补数字;「帧数 ≤ 语句数」对 upsert 成立,数字坐实 |
| S6:账号擦除**零门铃帧**;已 tombstone 的行同样物理消失 | 被擦账号的其它设备在下一次拉取吃 401 后登出,不靠门铃;擦除不留 tombstone(§5.4;§9.13 改写为已确认)(前半 **v1.5 改**:token 过期之前不会 401,改为「token 过期后的下一次请求」,调研 G24、§9.13) |
| S13:`encodeJSONOrNull` 对空数组送 `null`,`agent_preferences.rules` / `decision_history` 是 `jsonb not null` → 400 `23502`;与 015 无关的既有缺陷,零规则用户从未上传过这张表 | Phase 1 出站切片对这两列送 `[]`,读侧 `[]` 当空(§6 agent_* 段;§7 交付项 + 验收正对照;§9.30) |
| S7:PATCH 体里带 `seq`、带本行 `user_id` 无害(触发器覆盖 seq;同用户 no-op;改成别人 → 403 `42501`) | 客户端不必从行里剥 `seq`(§5.2 一句),少一处投影分叉 |
| S9:`event_logs` 含管道符与 `none` 的 id,原样 / 编码、`in.()` / `eq.` 四种写法全接受 | 不建编码规则;`SupabaseSyncService.swift:137-138` 保持不编码(§6 event_logs 段);P0.3 清单该项关闭 |
| S10(SQL):`sync_changes` 以 authenticated 身份走 `idx_events_user_seq`(`Index Cond: user_id = auth.uid() AND seq > since`),4k 行上 50 行一页 0.34 ms;`page_limit` 超上限被夹紧 | 第二轮「RLS 谓词下 `(user_id, seq)` 索引可用」的推断坐实(§5.5) |
| `1d8c830` 评审:服务端读取面已过滤 `deleted_at`,但 015 不级联——父事件 tombstone 后它的 logs 在服务端仍是活行,服务端读者直到客户端推子行 tombstone 之前都看得到 | 写明子行 tombstone 是客户端级联 + 集合差分上传的义务,窗口以秒计,不建服务端级联触发器;`skill_insights` 无 event id 不在任何级联里,今天就留(§5.4;§6 events 段) |
| S11:king 的 Restore `GET … Range` 把 tombstone 行一起返回 | 015 应用到生产后、Phase 1 装机前,king Restore 会把删过的行带回本地,窗口期不按 Restore(§5 状态码段;§6 Restore 路径;§7 交接单 (5)) |
| 生产应用的操作面(台架跑迁移的观察):`lock_timeout 3s`;回填在触发器之前;边缘函数要同窗口重部署;验后要看 policy / owner / RPC 可达 | 写成 §7 的交接单 (1)–(5),含 `notify pgrst, 'reload schema'` 与硬删要先 disable 触发器(后半 **v1.5 撤销**:不硬删、触发器保持启用,M1(c)) |
| **评审七**(独立 reviewer 对台架版在盘文本的对抗评审,`design/realtime-sync @ c404d8d`,全部引用重核)——以下各行 | |
| **BLOCKER** 示例数据三条件会删掉一条**有 todo 被吸进去**的演示行:种子全是 `.event`(`Event.swift:261` / `:548` 默认,种子器不传 kind),满足吸收的父端门槛(`EventStore.swift:385-388`);吸收只写 todo 的 `absorbedIntoEventID`(`:390`、gh#213 注释 `:405`),父行不动,条件 1–3 全成立;「数组移除不走级联」跳过了 `releaseAbsorbedTodos`(`:2598-2604`,注释 `:2593-2597` 写明死指针的后果)→ todo 从画布(`canvasRenderableCalendarEvents :329-334`、`CalendarPageView.swift:1983` / `:2011`)、todo 列表(`AnalysisViewModel.swift:349`、`CalendarEventDetailView.swift:2689`)、domino(`:556`)全部消失,只剩父详情页(`:2629`)能到而父已不在;再带 `absorbed_into_event_id`(投影 `:1291`)上传,B 得到同一条悬空行。与第六轮 BLOCKER 同形:挂在种子上、行 hash 看不见的第二种记录 | 条件 (4):`rawCalendarEvents` 里没有任何行的 `absorbedIntoEventID == id`;四条件对应今天全部三种「挂在事件上但不在事件行里」的关系;§8 种子测试第三反例「吸一个 todo 进未改演示行 → 登录 → 行与 todo 都保留、都上传」+ 去掉条件 4 的变异体必须红;§7 交付项与验收、§9.27 改写(§6 示例数据) |
| **MAJOR** §6「第三种响应」对六张 id 表**不可达**,§7 验收「A 改 B 删 → A 的 PATCH 回带 `deleted_at` 的行」断言了服务端产不出的响应:B 的 tombstone 是改写后的 UPDATE(`015:155`),过 `set_sync_meta` 取新号 s1(`015:100`);A 的 PATCH `seq=eq.s0` 匹配 0 行 → `200 []`。台架 S7 在死行上拿到 `[row]` 是脚本故意用 tombstone 之后的 seq 过滤(`sync_feed_checks.sh:179` 的 `$useq1`,取自 `:99`);客户端要持有它只能是拉到过 tombstone,而 tombstone 分支移除基线。§9.31「`deleted_at` 检查是 tombstone 到达本机的唯一路径」因此是错的——拉取才是 | §6 第三种响应改写:id 表到不了,留作廉价守卫(命中 = 基线与死行同号的 bug,记 `sync.push.dead_row_hit`),处置不变;单行表上它是常规路径(见下一行);§7 该条验收改为真实路径(`[]` → pending-verify → 有资格的拉取 → tombstone 分支:c1 在 shelf、级联、基线无 X),并加一条 user_settings 死行的 `[row]` 验收;§8 FakeServer 的 `seq=eq.` 过滤按真实语义 + 一条「无视过滤回行」变异体;§4 I8、§5.4、§9.31 改写 |
| **MAJOR** 三张单行表的 tombstone 语义在拉取侧与 PATCH 侧都未定义:本地没有「absent」、没有级联(settings 在 `SyncedSettings` / UserDefaults,preferences 在 `AgentPreferenceStore`),实现者只能在「一次 dashboard DELETE 重置每台设备的设置」和「留着」之间猜;而「基线移除 id」之后下次 flush 无 seq → POST ignore-duplicates → 行存在 → `[]` → 等不到的回声 → 每次改动一条 `sync.push.orphan`,所以 §6「每次 PATCH 都会成功地回死行」和 §9.31「单行表上循环从第一次就开始」描述的循环按规则根本发生不了;§6.2 时区先行 GET(带 `deleted_at=is.null`)对死 settings 行返回空 → pusher 送本地时区 → 被忽略 → 账号时区永不建立 | 定一条规则:单行表的 tombstone → 本地永不重置、不进 shelf,基线 := (hash(本地), seq)(settings:keys := 本地各键 hash),一条 `sync.apply.tombstoned_singleton`;之后每次本地改动一次死行写入,基线跟死行的新 seq 走,不循环;写 h_in 会两台经死行 ping-pong、移基线会每次 flush 一条 orphan,两者被算术排除;**不建「停止上传」标志**(干净判定即停、随基线落盘)。§6.2 加:死行不算「服务端有值」,GET 返回空 → 本机保留自己的时区、不记 zone conflict,undelete 后按采用条件重判(归 §9.21);§6 单行表段;§9.34 |
| **MAJOR** 失败的 tombstone PATCH 被继承的 `diffSync` 忘掉,删除跨设备静默复活(目标 4):`deletedIds = 上次 − 这次`(`SupabaseSyncService.swift:1123`),`rest.delete` 抛错只记日志(`:1132-1134`)仍 `return currentHashes`(`:1176`),`syncEvents` 无条件持久化(`:1187-1198`),只有 upsert 块回滚(`:1152-1157`);D6 只换 DELETE → PATCH 不改这一支。反方向:「tombstone 只从这个形状的响应确认」+ tombstone 分支在 absent 时不移基线 → A、B 同删、B 先落 → A 回 `[]` → 留基线 → 拉到 tombstone 「无事」→ 每 2 s 再 PATCH | 一条规则封两头:抛错 → 被请求的 id 留在基线、下次 flush 重发(同失败的 upsert 块);任何 2xx → 全部移出基线、不看响应体;tombstone 分支在本地 absent 时也移基线;写明这是 D6 的一部分不是 Phase 2;§8 加 tombstone 基线测试 + 「继承的 diffSync 行为」变异体;§7 验收两条;§5.4 / §9.12 措辞跟着改;§9.33(§6 删除段) |
| **MAJOR** P0.0 在本工作树已完成而正文说反:`git merge-base --is-ancestor 739fee9 HEAD` 为真(merge `282119b`),但首行「仍叉在 `25f8b84`」、§6.4「先合 king 再写代码」、§7 P0.0 未勾;合并后 HEAD 上 `EventStore.swift` 引用整体后移(`deleteCalendarEvent` 2621→2713、`commitLogRecordsNow` 1648→1662、`stopTimerOnCalendarEvent` 3664→3756),`AgentSettingsView` +166/−6、`AuthService` +117/−20、`ContentView` +136/−1;每条 `path:line` 在 `6a7e50b` / `65fcd7a` 上仍核得到 | 首行、§4 引用说明、§6.4、§7 P0.0 全部改为「已完成」;「king vs 本分支」的分叉措辞收掉;写明引用仍锚在 `6a7e50b` / king `65fcd7a`(两者都是 HEAD 祖先)、Phase 1 第一个代码 commit 时按 HEAD 重锚;king 的 `:938` / `:947` 在 HEAD 是 `:946` / `:955`,`EraseWiringQATests` 绿留到第一次跑套核(合并 commit 没记录跑套) |
| minor I1「最近一页短于 `page_limit`」vs 服务端 `least(page_limit, 2000)`(`015:271`):客户端 `page_limit` > 2000 会把一整页 2000 行读成短页 → 假 head → 提前上传 | §4 I1:`page_limit` ≤ 2000(全文用 500)(**v1.5 改** ≤ min(1000, `max_rows`),M1(b)) |
| minor event_types「来件是败方 → 不插入,同样 tombstone 它」:败方从不进基线,`diffSync` 的集合差分发不出它的 tombstone | applier 直接发 `PATCH /event_types?id=in.(败方)&deleted_at=is.null`,基线处置同删除段(§6 event_types 段) |
| minor shelf 去重键 `(uid, table, id, seq)` 对 tombstone + dirty(进 shelf 的是本地版本)没说 seq 是哪个 | 一律写来件的 seq(tombstone 的 s1),不写 base.seq;理由:停页重拉时同一来件还是 s1,去重成立,base.seq 第二遍后就变了(§6 规则表;§6.1) |
| minor `$session → nil` 要连内存里的 pending-verify 集合一起丢:键是 `(table, id)` 不带 uid,单行表 id == uid,旧用户的陈旧元素会活过再登录 | §6.4 加一句 |
| minor 「`!dirty` 或本地 absent → 插入」在「absent 是因为本地未 flush 的删除(基线在)」时会把 X 插回、挂起的 tombstone 永不发出——远端编辑静默赢过本地删除,设计没选边 | 选边:absent + 基线有 id + 非 tombstone 来件 → 按 dirty(保持 absent、来件进 shelf、base.seq := seq),下次 flush 的 tombstone PATCH(过滤器不带 seq)照常发出——删除胜编辑,与 D4 / I6 同向;§7 加一条验收(§6 规则表) |
| minor §6.4 引用:king `EraseWiringQATests` 的循环在 `:84-86`,`:80-82` 仍在 required 列表里(列表 `:82` 收尾) | 改正(核过,king 与 HEAD 同行号) |
| minor §6.2「引擎先 GET `user_settings` 行」没点名 helper,会有人加减法禁掉的 `fetchOne` | 点名 `fetchAll(table: "user_settings", userId:)`(`SupabaseSyncService.swift:164`)带新加的 `deleted_at=is.null`(§6.2) |
| minor 游标缺失时,删种子(要可写的 calendarEvents slot)、时区先行 GET、§6.1 冻结预检三者顺序未定 | 预检 → 删种子 → 时区 GET → 第一页;预检拒绝则种子删除随页跳过、下一次游标仍缺失的拉取前重判,不单独重试(§6.2;§7 交付项) |
| minor §9.17 一次性 `40P01` 重发:重发若回 `[]`(批量侧 tombstone 了这行)要按 `[]` 入 pending-verify,不得再重发 | §9.17 一句:只有一条重试路径 |

第七轮认定站得住(台架直接验证,原文不动):用户级锁下取号序 = 提交序、别的用户不被阻塞、第三连接看不到未提交的号(S1);tombstone 抗 `deleted_at: null` 的 upsert(S3);内容相同 upsert 不取号不响铃(S4);service_role 的 DELETE 也变 tombstone(S14);ignore-duplicates POST 只回插入的行且已有行不动(S8);tombstone PATCH 的客户端时间戳原样入库、第二次回 `[]`(S9);`sync_changes` 只回本人的行、按 seq 升序、短页即 head、仅 apikey 被拒(S10);单对象 `Accept` 0 行 406(S7);king 三形状不报错(S11)。P0.3 原清单里唯一被证伪的是「关 Allow public access 后才强制私有」。

第七轮的减法:不建服务端级联触发器、不建 id 编码规则、不给 DELETE 加确认读、不为 topic 授权失败加重试、不为 `40P01` 加计数器(重发一次,再失败就是下一轮 flush 的事)。评审七的减法:不为单行表建「停止上传」标志(干净判定即停)、不加 `fetchOne`、不为种子规则跑级联(多一条谓词而不是多一条路径)、不为 `[]` 的 tombstone PATCH 加确认读(2xx 即移基线)、不为第三种响应建新处置(id 表与 tombstone 来件同一分支,单行表与 tombstone 来件同一基线写法)、不重锚引用(两 commit 都是祖先,Phase 1 代码 commit 时一次锚到 HEAD)。评审七的两条正文反转记在这里,免得下一轮再被当成规则引用:「`deleted_at` 检查是 tombstone 到达本机的唯一路径」(错,拉取才是)、「A 的 PATCH 回带 `deleted_at` 的行」(服务端产不出,A 拿到的是 `[]`)。

第八轮(**形式化模型**,`verification/CivilCalendar/SyncMerge.lean` + `verification/sync-fixtures.json`,另一 agent 在途未提交;README「Sync merge (gh#257)」段列全部定理与 witness)与处置——这一轮的发现是构造性反例,不是意见;凡与正文矛盾的,正文改:

| 发现 | 处置 |
|---|---|
| **规则加强** 跳过行 `seq == h_base.seq` 放过陈旧页:本机 PATCH 之前取回、之后应用的页带着同行的更旧版本(in_seq < base.seq),`==` 下本地干净 → 采用 → 回退到旧版、base.seq 倒退(`stale_feed_row_regresses_witness`,对被取代的 `==` 行 `decideRowEq`);第八轮初稿另引的「陈旧页叠上 pending-verify 永久分叉」已撤回:那一页不是任何服务端状态的快照(I5,`scenarioAPage_not_head`),初稿引的定理名从未存在 | 改为 `seq ≤ h_base.seq → 跳过`,理由只取模型证得的:陈旧行成空操作(同上 witness)、重应用对 shelf 按列表幂等(`applyRow_idempotent`)、head 页上 `≤` 恰在 `==` 触发处触发(`BaseAnchored` + `decideRowEq_eq_decideRow`);三处引用 `==` 的文字同改(§6 规则表;§6.1;§9.23;§9.31)。`decideRow` 已取 `≤`,fixture 已重生成:skip 360 = 144 相等 + 216 严格低于,Swift 回放跟 fixture 走,不得特判 |
| event_types 胜者若让 tombstone 的同名者参选,B 拉到 A 对较小 UUID 的 tombstone 会 tombstone 自己活的类型,两台都失去它且不进 shelf(`naive_dead_namesake_erases_live_type_witness`) | 钉死:胜者只在活同名者中选;tombstone 来件只移除自己的 UUID(§6 event_types 段;§9.7) |
| settings 按键规则两处未定:两侧改成同样字节算不算冲突;远端删键败给本地改动时 shelf 记什么 | 钉死:同字节不是冲突(镜像行级 `h_in == h_loc`,`mergeKey`);shelf 行 `{key, remote: absent}`(`remote_deletion_overridden_is_shelved`)(§6 settings 段) |
| 不认识新同步键的 build 上传整 blob,按键规则把缺键读成删除并传播(`deletion_propagates`) | Phase 1 不加键,现在咬不到;以后加键的 build 必须透传上次拉到的未知键——§9.3 第二个窗口、§7 Phase 2 一行,现在不建机制 |
| `skillAnalyzedEventIds` 并集是字面的:restore(keep-cloud / cloudOverwritesLocal)缩小集合后下次合并并回去(`union_undoes_shrink_witness`) | 接受并明示:唯一缩小途径是删键(`clearAll`)(§6 settings 段) |
| 表序的两条「不得重排」守卫(`dirty_before_echo_shelves_own_push_witness` / `echo_before_tombstone_keeps_deleted_row_witness`);`Inv`(`Server.WF` ∧ `BaseBounded` ∧ `NoDeadBase` ∧ `BaseAnchored` ∧ 游标不超过计数器)被每种操作保持;fixture 是 applier 纯决策核的回放契约 | §8 列为形式化接缝;Swift 回放是 slice 2 交付项 |

第八轮认定站得住(定理,非意见):tombstone 单调(I4 / I6,含 pre-015 盲 upsert);同页拉两次只应用一次;回声不动任何东西也不进 shelf,在每个可达状态上成立;本地内容变化只有「本来干净」或「已进 shelf」两个出口(I7);干净副本拉一页 head 落在服务端活内容上;PATCH 的 `[]` 只有过期与相同两个原因(I8);pending-verify 清标记在 `Inv` 下、有资格的 head 拉取之后写出的就是服务端持有的字节(`pending_unseen_means_identical`);event_types 最小 UUID 规则对称、幂等、不铸第三个 UUID、三台任意发现序收敛;settings 升级三分支与 §6 一致。第八轮的减法:不为陈旧页建「页快照序号」或服务端时间列(`≤` 一个比较就够)、不为同字节冲突建特例(它是通用规则的一个分支)、不为 settings 透传现在建机制(没有键要透传)、不为并集回弹建反向机制(删键已经是出口)。

第九轮(**形式化模型:冲突行基线**;反例在 `SyncMerge.lean` 的旧写法上 `decide` 检查,新写法在模型的草稿副本上整体重编译)与处置:

| 发现 | 处置 |
|---|---|
| **规则加强** 冲突行和 pending-delete 行留旧 hash:`(h_base.hash, seq)` 是服务端从未同时持有过的一对。算术:A 基线 (h0, s0)、本地 c1,拉到 c2@s1 → 冲突、基线 (h0, s1)、c2 进 shelf;A 改回 c0 → hash = h0 = 基线 → 干净、零请求、计数器不动,服务端 c2(`conflict_then_revert_reads_clean_witness`);新写法基线 (h2, s1),c0 判脏,PATCH `seq=eq.s1` 落 c0 | 两行都改为 `基线[id] := (h_in, seq)`(M1 特例并入);`BaseHashSound` 不再有例外;单行表 tombstone 的 `(hash(本地), seq)` 是唯一且有意的例外(`naive_half_round`)(§6 规则表及其后一段) |
| 同一缺口的 I7 版:冲突后 B 把 X 改回 c0@s2 → 留下的 h0 让回声行先触发 → c0 不进 shelf → A 推 c1@s3、B(在自己的 (h0, s2) 上干净)采用 c1 → c0 不在任何设备、服务端、shelf | 同上一条;新写法下 c0 走冲突、进 shelf,c1 照样落地 |
| 同一缺口的删除版:未推出去的本地删除遇上对端编辑,随后撤销(`undoMerge` 的 `add(sourceEvent)`、`undoSmartSplit` 的 `add(originalEvent)` 写回删除前字节)→ 旧写法判干净、本地不再 absent,PATCH 和 tombstone 都不发,服务端停在对端版本 | 同上;`pushDelete` 不看 hash,删除照样落(新写法下 tombstone 仍是 `deleted_at=is.null` 一条 PATCH) |
| settings 冲突键有同一个洞:键 k 本地 1、基线 0、远端 2(冲突)→ 改回 0 判干净;升级第三分支(基线为空)里删掉一个冲突键也判干净,服务端留着值 | 冲突键基线 := 远端键 hash(§6 settings 段「合并后的每键基线」);`mergeKeys_local_change_stays_dirty` 在新基线下重证仍成立 |
| `skillAnalyzedEventIds` 字面并集遇上顺序敏感的按键 hash:A=[1,2]、B=[1,3] → A=[1,2,3] / B=[1,3,2] 交替,每半轮一次 PATCH,永不停;两种冲突行写法下都发生 | 并集排序后写回并参与 hash 和上传(§6 settings 段);排序后第二台推一次即收敛 |
| 同族写入者,**未端到端核实**:`markRestoreCompleted` 的基线重播写 `(hash(本地行), 旧 seq)`(slice-1 工作树 `replayBaseline`;HEAD 也按本地行算 hash),keepLocal 的碰撞行因此读成干净,与 §6 上传形状末条「只有 keepLocal 的碰撞行变脏」相反——与旧冲突行同一种服务端从未持有过的对 | Phase 1 restore 接线时按同一原则核:云端知道的行写 `hash(云端行)@云端 seq`;本轮不改正文规则 |
| 在途 / 丢失的 `[row]` 响应 + 改回基线值:判干净,拉取带回自己先前的推送并覆盖改回;两种写法都有 | §9.35 明示,不建机制;新写法下被覆盖的是已在 shelf 的 c2(**v1.5 撤销**:「丢失」一支由 S4 收口,§9.35、§6 上传形状) |

第九轮试过、两种写法结果相同或新写法不破的反例:回声与重拉(冲突后推 c1 → 基线 (h1, s7),X@s7 重来走 skip,shelf 不变;同页 / 更旧的页按 seq-only 的 skip 行跳过);冲突时 pending-verify 元素在场(冲突要求 s_in > base.seq ≥ sentSeq,所以 base.seq ≠ sentSeq,元素被丢、hash 留在 h_in,确认分支覆盖不了冲突写下的 hash);I8 的下一次 PATCH(两种写法写同一个 seq,双方都发的 PATCH 逐字节相同,只在本地是 c0 或 c2 时不同);冲突后对端又写 c3(再冲突,shelf 两行,基线 (h3, s2),改回 c0 照推);冲突后到达 tombstone(新写法只把与服务端最后活版本不同的本地行进 shelf,不重复 shelf c2);slot 写与基线写之间崩溃(冲突行不写 slot,shelf 追加按 `(uid, table, id, seq)` 去重,重拉后同一结论);§6.3 旧 `<hash>` 升级(c0 仍进 shelf 一次,新写法顺带把基线换成新编码);event_types 胜者规则(败方不进基线,不经冲突行);单行表活行(干净一侧推一次后采用胜者,不 ping-pong)。旧写法的唯一理由(v1.1 `93c69b7` 从 v0「基线不动(本地随后照常上传并在服务端胜出)」沿袭)只保护了「本地必须仍脏」,而冲突行在 `same` 行之后,h_loc ≠ h_in,写 h_in 同样保住它;没有别的东西依赖它。新写法在模型草稿副本上整体重编译:结构性定理全部保留(T4、T5、T5'、幂等、`Inv` 保持、T9a / T9b、回声惰性、表序 witness、event_types、单行表),只需重述 pending-delete / conflict 的三条陈述并重证 `mergeKeys_local_change_stays_dirty`;五条带旧 hash 字面量的 witness 改字面量,实质部分(shelf、PATCH 落地、tombstone 落地、seq)不变。**在盘状态**:写入本表时 `decideRowBody` 与在盘 fixture 仍是旧写法(36 条冲突用例 `base_hash` = `h_base`:18 条脏且有基线、18 条 pending-delete);Lean 流改规则后重生成,这 36 条翻为 `h_in`,Swift 回放跟 fixture 走。第九轮的减法:不为冲突史建任何标记或状态(新写法让冲突后状态与一次普通本地编辑相同)、不为在途响应 + 改回建机制、restore 写入者只记待核不改规则。

v1.4 的减法:不建第二个云项目、不建 per-table 游标、不建 re-key、不加服务端时间列、不加 `persist(origin:)`、不加 `fetchOne` GET、不加重试计数、不给 shelf 设备份排除键、不给基线用 `AtomicValueFile`、不给门铃配 background session、不新建总闸键、不为 §10.4 建任何东西。

### v1.5 变更记录(业内调研)

契约是 `Docs/sync/02-industry-survey.md @ 3c8d1af`:八份独立调研(Replicache / Zero、Linear、CloudKit、PowerSync / Electric、CouchDB 等经典复制系统、Supabase 社区、Postgres 变更流、业内验证方法)合并去重,三位质疑者 45 条逐条处置(调研 §H)。调研的白话结论:骨架的每一块都有成熟系统用过,但没有哪一家整套和我们一样;护栏不够,测法要升级。处置原则不变——每个新机制写明它防住的、我们这里的具体失败,配一个日志令牌,承重的触发交给测试或验后检查执行。

| 条目 | 决定 | 依据 |
|---|---|---|
| 015 定稿:TRUNCATE、硬删、夹紧、触发器启用 | 九表语句级 `BEFORE TRUNCATE` 抛错(§5.6);夹紧 `least(page_limit, 1000)`、I1 改 `page_limit` ≤ min(1000, `max_rows`)、客户端常量与 FakeServer 同改、`max_rows` 探针进验后检查与每次 `sync.audit`(§4 I1、§9.38);删「先 disable 触发器再硬删」,换成 §5「运维规则」;验后检查九表三触发器 + 守卫 `tgenabled = 'O'`(§7 交接单 (4));I10 写明「没见到 ⇒ 相同」的前提;合成一次台架重跑(§7 P0.3、§8.3) | M1(a)–(d);G2、G3 |
| 服务端倒退 | `sync_epoch(epoch, floor)` 一行表(§5.7)+ 入库恢复脚本同一事务换 epoch;设备每页应用前 GET(评审后取代 (a) 首拉前 (b) `.joined` (c) 判相同前);重置按条目 seq 与 floor 改写基线(评审后取代按来件 seq 两段);游标键带 epoch 与 floor;未见行 POST 回去;不 `setval`(fresh-eyes M3 曾改为跳号,复核撤销并加强为「恢复不回拨计数器」,§6.6)、不加 `sync_head()`;D10;§6.6 | M2;G1;§B.4 C3 / C4 / C8 |
| 拉取单飞 | 一条 RPC 链 + `rerun`;游标 `max`;Restore 不推进游标(I9) | M3;G4 |
| domino | **顺序规则已定**(到 head 之后才推、tick 前先拉,I1 同门);**跨设备只推一次的方案待拍板 §10.5**;§9.22 的「同一个 horizon 日」与 §6 的「Phase 1 接受」改写为被证伪 | M4;G5;§B.4 C1 / C1b |
| 60 s 轮询 | 常驻当看门狗,删掉「一个 build 内零命中就删」;`.joined` 必拉;`sync.doorbell.missed` 带自写 seq 与 5 s 宽限(D1、§4、§6.5、§7) | M5;G6 |
| 测试牙 | FakeServer 八类钩子各配变异体、`stabilize()`、两类 oracle、可注入时钟与 UserDefaults(入库清单)、与层 3 共用重启点名(§7 P0.4、§8.2) | M6;G18 |
| 真栈层 | LiveGateway 对拍按五项比较零差异(必须);四条脚本化核心场景(§7 P0.5、§8.3) | M7;G18 |
| 永久拒绝 | 失败五类(401 / 重试 / 表结构缓存 / 块大小 / 拒绝),拒绝类先逐行重发一次、`rejected` 表、`sync.push.rejected`、不丢不回滚(§6 上传形状) | S1;G7;§B.4 C6 |
| 撤销窗口 | **待拍板 §10.6**(推荐 A 延迟 tombstone;备选 B 提前做 #140 undelete);拍板前 §6「冲突行基线」(d) 如实写明行为 | S2;G8 |
| 结果未知的写 | 每次发送时基线记 `?`、结果对条目做比较交换(评审后取代「失败时记 `?`」),awaitingEcho 期间删除照发 tombstone,替换 slice 1 的丢 key;§9.35「不建机制」改写为由 S4 收口;D6 写明与 CKSyncEngine 的差别 | S4;G10、G23;§B.3 |
| 所有者守卫 | `syncHashes.ownerUid`,不等即不拉不推 + `sync.blocked.owner_mismatch`(I11、§6.3、§6.4) | S5;G11 |
| Restore 基线 | `replayBaseline` 写 `hash(云端行)@云端 seq`;收口第九轮表末「同族写入者,未端到端核实」一行(§6 Restore 路径、§6.3) | S6;G12 |
| 冲突列名 | `sync.conflict cols=`,只做字典 diff;不加 `local_dirty_since_ms` / `remote_age_ms`(§6.5) | S7;G14 |
| 对账 | `sync.audit` + 独立 Python 比较器(显式列映射,不复用 rowHash)+ schema 完整性测试;部署门改为打开 apply 后立刻对账为 0、一周每天为 0(§7 交接单 (7)、§8.3、§8.6) | S8;G17 |
| 文档与运行手册 | 先扩后缩、新同步表同迁移、恢复只走脚本(§5「运维规则」);§9.3 扩成混版本写回;policy 恰好一行(§5.5、§9.47);门铃注释与 §9.11 订正;Restore 不推进游标;shelf UI 账号级、行格式可上传(§7 Phase 2);残余风险 §9.37 / §9.38 | S9(a)–(g);G13、G16、G21 |
| shelf 落盘 | 批内追加过则推胜方 PATCH 前一次 `F_FULLFSYNC`(§6.1、§6.3) | S10;G20 |
| 游标代次 | 每张表基线带 `gen`,游标键 `{cursor, gen}`,不一致即丢游标重拉;不测 UserDefaults 崩溃顺序(§6.3、§8.5) | S11;G22;X11 |
| 被擦账号的设备 | 检测半已定:user_id 外键 23503 → 不进 `rejected`、停本表、`forceRefreshToken()`;窗口内 `[]` 判相同接受不建机制;**本地数据处置待拍板 §10.7**(推荐保留 + 停同步);§9.13「下一次拉取吃 401」改为「token 过期后的下一次请求」(§6.4) | S12;G24 |
| 混版本绊线 | 投影键集合与枚举 rawValue 快照测试,一变红即「先做 L3」(§9.3、§8.2) | S13;G13 |
| §8 整节 | 换成层 0–5 的分层计划(层 1 FakeServer 随机套件、层 2 本地栈、层 3 双模拟器为本地三层)与 §8.7 的十条信心判据;v1.4 的定向测试并入 §8.2 保留;§2 目标 1 的 ≤ 2 s 改为生产 p95,加目标 7 | §E、§F;Q3.1 / Q3.2 / Q3.12 / Q3.17 |
| 被调研证伪、就地改写的旧文本 | §9.22 / §6 domino「同一个 horizon 日」;§7「60 s 轮询零命中就删」;§5.4 与 §7 交接单 (5)「管理员先 disable 触发器再硬删」;§4 I1「`page_limit` ≤ 2000」;§9.13「下一次拉取 / 刷新时吃 401」;§9.11「token 过期前没有主动推」;§9.35「不建机制」;§9.17 X2 的理由;§13 旧表里对应三行加了「v1.5 撤销 / 证伪」标注,原文保留 | C1、C6、G2、G3、G21、G24、G10、X2 |
| later(L1–L10,L6 已提为 S11) | 全部进 §9.36 的表,每条带触发条件与形状;L8 现在只做 `sync.apply.resurrect_flash` 计数 | L1–L10 |
| 第九轮冲突行基线 | **保留不动**(冲突行与 pending-delete 行写 `(h_in, seq)`、settings 冲突键写远端 hash、并集排序);S6 是它在 restore 写入者上的延伸 | 第九轮;S6 |
| **对 v1.5 在盘文本的评审**(独立 reviewer,同日;1 BLOCKER + 4 MAJOR + 7 minor,逐条用算术推;另三行是回写这些修正时自查出来的)——以下各行 | | |
| **BLOCKER** S4 照抄调研写成「失败时记 `?`,seq 已知则 `?@<seq>`、重发 `PATCH seq=eq.s0`」:超时约 60 s、回声约 0.3 s,回声先到时 `?@10` 把已推进到 (h1, 11) 的条目拉回 10,此后每次编辑 `[]` → 判相同 → 永不上传、无 shelf 无日志;POST 版每次 flush 一条 orphan、Z 的编辑全被 DO NOTHING 吞掉 | **改**:`?` 在**发送时**写(同一 tick、每表一次写盘),之后一切写 `(hash, seq)` 的结果对条目做比较交换,条目已被拉取改过即不写,`?` 永不把 seq 往回挪;只给失败加比较交换(评审的最小修法)会留下「发送后、回声前改回」这一支(因果账本判红),发送时写一起关掉,还覆盖 `patch_committed_before_baseline`;`[row]` 迟到也走比较交换。§8.2 加「回声先于失败」「发送后回声前改回」「`[row]` 迟到」三条与「失败时无条件写 `?@sentSeq`」「只在失败时记 `?`」「不做比较交换」三个变异体;调研的四条测试都在回声之前交付失败,抓不到它(§6 上传形状、D6、§9.35、§7) | `grep -rn timeoutInterval Done` 为空;`git grep -n URLSession.shared a95690b -- Done/Services/SupabaseSyncService.swift` → `:125` / `:150` / `:285` / `:341`;URLRequest 默认超时 60 s;调研 §B.3 第三条原话就是「在发送时写下、确认之后才清掉」,§D 的 S4 写成了失败时,本轮按 §B.3 |
| **MAJOR** M2 按**来件** seq 分两段,抹掉导出后版本的唯一副本:落后设备 B 先在 X@50 上写出 c_b@101,A 再检测时 X@101 > F → 普通规则 → 干净采用 c_b,c_a 哪里都没有 | **改**:按**条目自己的** seq 判别——条目 seq > F(本机那一版服务端已没有)→ `?`;≤ F → 保留 hash、seq 标未知、skip 停用。评审的「≤ N0 的号在两条时间线上相同」大体成立,例外是导出进行中提交的写(序列不受快照约束),记进 §6.6 代价与 §9.37。调研的三条 M2 测试在新规则下照样过;加评审要的「恢复后、持有者检测前另一台先写」测试与「按来件分段」变异体(§6.6、D10) | 评审算术,本轮按两种规则各推一遍(§6.6「为什么按条目」);`pg_dump` 读序列不走快照,`restore_with_epoch.sql` 的 floor = 恢复后序列值 |
| **MAJOR** 同一规则让落后设备回退导出前的编辑:C 基线 (h_old, 40),A 的 c_new@99 ≤ F → 哨兵 → C 胜、推 c_old,A 采用,恢复时游标低于 N0 的设备都暴露 | **改**:同上一行,40 ≤ F → 普通规则 → 采用 c_new;测试与变异体同上(§6.6) | 同上 |
| **MAJOR** 回滚的重新启用照搬「恢复脚本同一条 epoch / floor 语句」,在来件规则下每行都成哨兵,回滚期间 agent 的编辑被回退 | **改,但不换语句**:新规则下 floor = 当前序列值意味着每条基线都 ≤ floor,不出哨兵,只停用 skip、保留 hash → 干净设备采用回滚窗口里的写;所以 `restore_with_epoch.sql` 可以原样单独跑,评审的「演练不能直接用它」只在来件规则下成立。另写明回滚窗口里的物理 DELETE 经 POST 复活(D8、§7 交接单 (8)、§10.1、§8.3 回滚演练) | 评审算术(X = c0@50、c_ag 仍 @50、F = 130)在新规则下重推:A 的 (h0, 50) → 保留 h0、seq 未知 → X@50 的 h_ag ≠ h0、本地干净 → 采用 |
| (自查)回滚只 drop 触发器,`seq` 仍是 not null 且无默认值,每一条不带 seq 的 INSERT 与 upsert 都 `23502` | **改**:回滚同时给九表 `seq` 列默认值 `nextval('public.sync_seq')`,重新启用时去掉;演练里加一次 king 形状的 upsert(§7 交接单 (8)、§8.3) | `015:229-236`(加列、回填、`set not null`,无 default);本地栈临时表 `insert … on conflict (id) do update` 撞已有行仍报 `null value in column "seq" … violates not-null constraint`;ops README R2 |
| **MAJOR** M2 × M3:重置时有一条在途的旧链,它的页在重置后按 `max(旧, 页末)` 写游标 140,101..130 永远拉不到,所有旧形状基线变成永久 orphan;(b) 也没规定 GET 先于拉取 | **改**:epoch 检查从三个时点改为「每次 `sync_changes` 返回之后、应用这一页之前」,变了即放弃本链(不应用、不写游标与基线),重置只由单飞执行器在链边界做,别处不丢游标;一条规则代替 (a)(b)(c)。加评审要的「扣住 C1、rewind、交付 `.joined`、放开 C1」测试与「只在三个时点检查」变异体(§6.6、I9、§4 架构) | 评审算术;restore 脚本让数据与 epoch 同事务换,所以 RPC 之后的 GET 看得到这一页快照里的恢复 |
| (自查)恢复时在线、门铃连着的设备不经过 (a)(b),也很少走到 (c):新时间线的号越过它的游标后照常拉到、用旧基线应用,X@135 让它干净采用 c_b、c_a 消失 | **改**:由上一行的每页检查封住;代价每页一次单行 GET(27 页全量拉多 27 次,门铃路径多一个往返);同快照响应头变体要改服务端,p95 逼近 2 s 时再评估(§6.6) | 本轮算术(§6.6「设备何时查 epoch」(i)) |
| minor §5.7「`db reset` 或重跑迁移生成新 epoch」:部署每次 main push 重跑全部迁移,字面读法每次部署都重置每台设备,§8.7 判据 9 不可能成立;§5.7 / §6.6 的形状与服务端流不一致 | **改**:只有全新库得到新 epoch,重跑 015 不动它;形状按 015(`epoch text`、`changed_at`、单行唯一索引 `((true))`)与 `restore_with_epoch.sql`(upsert、`is_called` 调整)重写;台架加「重跑 015 epoch 不变」(§5.7、§6.6、§8.3) | `015:354-366`(`where not exists` 播种);`ops/restore_with_epoch.sql`;§7 末段与 #244 |
| minor 重置跨游标、九张基线、纪元三类键,UserDefaults 不保证跨键顺序(S11 自己的前提),「新 epoch 落盘、丢游标没落」后 (N0, N1] 永久跳过 | **改**:纪元并进游标键 `{cursor, gen, epoch, floor}`,每张表基线带 `epoch`;游标键丢了 → 下一页再重置(改写幂等),某张表丢了 → 按游标键的 floor 补改写;独立键 `syncHashes.<uid>.epoch` 撤销;§8.2 加重置途中逐键回滚与「纪元单独一个键」变异体(§6.3、§6.6) | §6.3 S11 段原文 |
| minor (c)「每次判相同前多一次 GET(这条路径很少走到)」与哈希编码 build 的 13k 个元素矛盾 | **改**:按页不按元素,13k 个元素由同一条 27 页的链清掉是 27 次(§6 上传形状、§6.6) | §6 上传形状 (iii) 与 §6 末条的 13k 估算 |
| minor `01-realtime-protocol-notes.md:63` 把带内续期标「已实现」:`credentialsDidChange` 在 `a95690b` 零调用者 | **改**:协议笔记与 §9.11 都写「推送机制在、接线是 Phase 1 交付项」;§6.4 同改一句;刷新是按需的(请求前剩余 < 300 s) | `git grep -n credentialsDidChange a95690b -- Done` → 只有 `SupabaseRealtimeDoorbell.swift:377` 定义与 `:406` 注释;`AuthService.swift:262` |
| minor §6.4 与 §9.41「守卫在任何选项下都先拦住」替用户否了 §10.7 (C) | **改**:两处改为「(A)(B) 下拦住;选 (C) 即给 S5 开例外(终态登出时清 `ownerUid`)」,§10.7 (C) 与「依赖本项的地方」补上 | — |
| minor §13 第七轮 S6 行「下一次拉取吃 401」、第九轮 §9.35 行「不建机制」与 v1.5 矛盾却没标注 | **改**:两行加「v1.5 改 / 撤销」标注,原文保留 | — |
| minor S12 的检测半写成了规则,首行与 §8.7 判据 1 却漏掉它 | **改**:两处都加「S12 的检测半」(调研 §F.1 列 S1、S2、S4–S13) | — |
| 评审核实无发现:M1–M7 与 S1 / S4–S13 都有可实现的规则;L1–L10 在 §9.36、X1–X12 在驳回段;三项待拍板记为 open;§8 与调研 §E / §F 一致(逐步安全 oracle、只在静止点查收敛、扣留跨步、注入时钟与 UserDefaults 加决定论正对照、四个共用崩溃点、独立 Python 比较器、≥ 150 s 静止窗口、交错类变异体只开随机套件、十条判据);M3 的 G4 算术在 I9 下成立;单飞下 `pullIssue` 资格成立 | 原文不动 | 评审逐条核对 |
| **fresh-eyes 评审**(独立 reviewer 对 v1.5 修订稿 `design/realtime-sync @ f57c024`,2026-10-18;2 BLOCKER + 7 MAJOR + 9 minor,逐条用算术推;另三行是 Lean 流的遗留规则 (a)(b)(c))——以下各行 | | |
| **BLOCKER B1** S11 的游标代次只推进「本批触碰」的表;最常见的一页是自己 PATCH 的回声,全被 skip 行跳过、touched = {}、gen 不动;断电丢掉 flush 写进的表键而游标键留下(正是 S11 要防的跨键顺序)→ 盘上 `?@0` 或 (h0, 0)、gen 相等、游标 5 留下 → 下一次编辑 `PATCH seq=eq.0` → `[]` → 见不到 → 判相同 → 永不上传、无日志(G22 原样回来),「按构造」不成立 | **改**:§6.3「本批触碰」→「本批页内出现」(含跳过行、本地 absent 的 tombstone),并写明为什么出站写不推进 gen 而按「出现」就够(出站写下的 (h, s) 在游标越过 s 之前,s 所在的页必含这一行;pending-verify 判相同不带 seq、丢了方向安全);§8.2 加「被丢的恰是 flush 写的表键」的逐键回滚用例与变异体「touched 不含跳过行」;§8.1 记为模型外 | `Done/Services/Sync/SyncBaseline.swift:488-494 @ f57c024`(`commit(seq:baseline:touched:)` 只 `advanceGeneration(tables: touched)`);reviewer 的算术本轮逐步重推成立 |
| **BLOCKER B2** 远端 tombstone 的级联剪掉脏的、或从未上传的子 log / feedback,不进 shelf:A 离线写笔记、B 删 X、X 的 tombstone 先到(X 干净不 shelf)、级联剪掉 L,B 对 L 的 tombstone 在后页或 L 只在 A 上 → 那页见 L 本地 absent → 不 shelf;A 的差分把 L 在服务端 tombstone → 笔记在每台设备上消失(I7、目标 3);账本第四款把级联当成本机自己的后写而放过 | **改**:§6.1 第一遍用级联自己用的纯函数 `recordsSurviving(_:afterDeleting:)` / `afterDeletingSeries` 求将剪的记录,`h_loc ≠ base.hash`(含 `?`)或无基线的逐条进 shelf(seq = 父 tombstone 的 seq,reason = cascade;本页带它自己 tombstone 的由自己的分支处理、不重复),追加失败照旧整页拒;§8.2 账本把 applier 与级联改动记为远端;定向测试(离线笔记 + 远端删除 → 笔记在 shelf,含「只在 A 上」变体与干净正对照)与变异体「级联剪枝不进 shelf」;§4 I2、§6 events 段同步一句 | `Done/Models/EventStore.swift:2713-2748`(`deleteCalendarEvent` 第 3 步无条件剪)、`Done/Models/EventStore+OccurrenceRecords.swift:459` / `:513`(两个纯 `recordsSurviving`)/ `:550-565`(两个 prune 不看脏)`@ f57c024` |
| **MAJOR M1** 发送时记 `?` 之后,在途期间 `h_in == h_base.hash` 的回声行按构造不触发(正文自己写着「回声行永不触发」),C2 的顺序守卫(Lean `dirty_before_echo_shelves_own_push_witness`,「不得重排」)在整个在途窗口里是死的:基线 (h0, 10)、发 c1、`?@10`、服务端 c1@11、用户打字 c2、回声 h1 → dirty → 本机自己的 c1 进 shelf、记 `sync.conflict cols=…`;收敛,但每个慢或丢的响应都造一条自冲突,污染 L1 触发看的 S7 计数与 Fix Watch,让 domino 测试的「shelf 增量 0 / `sync.conflict` 0」不稳 | **改**(同时落地 Lean 遗留 (b)):内存在途表 `(table, id) → (token, sentHash / sentKeys, sentSeq)`,发送时与 `?` 同一 tick 写、发送结束时删、`$session → nil` / uid 变化 / 重置时清空;规则表 `same` 之后、pending-delete 与 dirty 之前加「在途回声」行(h_in == sentHash 且 seq > sentSeq → 基线 := (h_in, seq),不 shelf、不记冲突;settings 按键同理);改回 c0 仍判脏推上去(c0 ≠ h1),保住 S4 防的改回;§6 S4 (1) 的结局与代价句改写;§8.1 要求 witness 按 `?` 重写再生成;§8.2 定向测试与变异体「没有在途回声行」。选内存表而不是 reviewer 备选的 `?<sentHash>@<seq>` 落盘编码:进程死了就没有在途请求,落盘的 sentHash 只会在重发换了 sentHash 之后误认旧回声 | §6 规则表注释原文;reviewer 算术本轮重推成立 |
| **MAJOR M2** 迟到的 `[row]` 遇上已推进到**更新外来版本**的条目(S4 分析 (1) 只覆盖拉取见到自己版本):A 发 c1、服务端 c1@11、B 在 c1 上知情地改成 c2@12、A 的响应还没到时拉到 X@12 → dirty → c2 进 A 的 shelf、A 推回 c1;比较交换随后正确地什么都不写,但决定已做;账本放过(c2 在 shelf)。默认超时 60 s 把窗口拉到一分钟 | **改**(其中「页等在途写」复核撤销,见表末),取 reviewer 的 (a) 并把 (a) 覆盖不到的部分按 (b) 记残余:写请求 `URLRequest.timeoutInterval = 15 s`;一页里有「在途、h_in ≠ sentHash、seq > sentSeq」的行就等这些发送结束(上限即超时)再应用,自己的回声不等;响应**丢失**时仍未知,按 `?` 应用,进 §9.49 并由 §8.2 的残余用例钉住;§8.2 定向测试与变异体「不等在途写」| `grep -rn timeoutInterval Done` 为空(本轮在工作树重跑);`sync_changes` 每行只给当前版本,丢响应时 A 无从知道 c2 是否基于 c1 |
| **MAJOR M3** 恢复后序列回到 N0 = F,新时间线从 F+1 重新发号,与设备基线里旧时间线 (N0, N1] 的号重名:(a) A 持有旧时间线 X@120、检测前先 flush,B 在恢复后已把 X 写到新时间线的 120 → A 的 `PATCH seq=eq.120` 命中盲覆盖、无 shelf,c_b 丢失;(b) 检测前的出站成功拿到 > F 的新号,重置改成 `?`,对端之后更新的编辑被回退 | **改**(复核撤销,改为恢复不回拨计数器 + 累积 `lost`,见表末):恢复脚本写完 floor 后 `setval(sync_seq, F + 2^40)`,`sync_epoch.resume` 记新时间线起点;重置按条目分三段——≥ resume 原样、(F, resume) → `?`、≤ F 或未知保留 hash 去 seq;游标键与补改写带 resume;§5.7 加列;X4 与 D10 备选列、v1.5 减法里的「不 setval」改为「单独抬高仍驳回,作为 floor 之外的跳号采用」;§6.6 测试加两条与变异体「不跳号」「≥ resume 也改成 `?`」。服务端流随之改 `restore_with_epoch.sql` 的文件头与校验(floor 先算、再跳号) | `done-mcp/supabase/ops/restore_with_epoch.sql` 文件头「Do not setval sync_seq upward … hides the rewind」——有 epoch 宣告之后它不再藏任何东西;reviewer 算术 |
| **MAJOR M4** 回滚的「关总闸」是每台设备的 UserDefaults 键,D9 每次交互式登录翻回 ON,「打开 apply」从未定义成机制,没有远程开关;`set_sync_meta` 被 drop 后 UPDATE 保留 seq、I8 失效:两台同 `seq=eq.50` PATCH 互相盲覆盖、都拉不到,重新启用后干净的一方采用对方,c_a 丢失;§8.3 演练没有活客户端,抓不到;「不扩大到第三台」没有机制 | **改**,取 reviewer 的第一种:`sync_epoch.paused`,每页 GET 读到即放弃本链(不重置),flush 的门要求两个轮询周期内读到过 `paused = false`;回滚先置位、等两个轮询周期加一个写超时、再 drop 触发器,重新启用最后清位;§7 (7) 定义「打开 apply」并明示第三台靠分发;§8.3 演练加活的 Phase 1 客户端与变异体;服务端流改 `rollback.sql` 文件头。不取「回滚保留 `set_sync_meta`、只 drop 门铃与 tombstone 触发器」:用户级锁就在 `set_sync_meta` 里,它是回滚最可能要撤掉的东西 | `done-mcp/supabase/ops/rollback.sql`(服务端流在途、未入库)文件头「Turn the clients' sync switch off first」;§10.2 D9;reviewer 算术 |
| **MAJOR M5** S12 的检测半只写了两支(终态 / 刷新成功),实际有三种结局:`forceRefreshToken()` 返回 Void,网络错误、429、5xx 与集合外的任何 400 code 都**静默保留**会话;「停本表上传」没有解除条件;GoTrue 对已删用户 refresh 的 code 未观测,不在终态集合里则会话永久保留、每个请求 401 再强刷(#250 未做),检测永远不触发 | **改**:§6.4 写明引擎按调用前后的会话与 accessToken 判三种结局(nil → 终态;token 变了 → 刷新成功、按拒绝类;都没变 → 未决、表保持暂停、按重试类退避在下一次 flush 再试、`sync.account_check outcome=kept`)与解除条件;§8.3 跨设备擦除断言 GoTrue 的实际 status 与 code 并抄成 `refreshOutcome` 的 fixture,三种结局各走一次;不在集合内则按 `AuthService` 注释的「ON EVIDENCE」程序扩集合,之前 §8.7 判据 1 的检测半不算落地。本机数据的处置仍待 §10.7 | `Done/Services/AuthService.swift:284-296`(`forceRefreshToken() async`,无返回值)、`:439-462`(`terminalRefreshCodes` 四个、`refreshOutcome` 要求 400)`@ f57c024` |
| **MAJOR M6** 出站没有每表单飞:每次防抖到期都起一个 `Task { await self.syncEvents(...) }`,慢于 2 s 的 flush 与下一次重叠;发送时 `?` 让重叠的 flush 把在途行读成脏、按同一 seq 再发——13k 行重推期间每次编辑都把仍是 `?` 的行重发一遍,8 路变 8 × k,pending-verify 塞满重复 `[]`,「一轮收口」不成立 | **改**(其中「在途行不进 flush」复核删去,见表末):§6 上传形状加「每表单飞 flush」——同一时刻每表最多一次 flush,期间到达的防抖只置 `rerun`;在途表里有元素的行不进本次 flush(tombstone 差分同);「每表每 2 s 最多一次 flush」改写;§8.2 定向测试与变异体「flush 不单飞」| `Done/Services/SupabaseSyncService.swift:779-800 @ f57c024` |
| **MAJOR M7** 层 3 静止窗口断言 `pg_stat_user_tables` 的 `n_tup_ins + n_tup_upd` 不变,而它包含 `auth.refresh_tokens` / `auth.sessions`;`jwt_expiry = 360`、剩余 < 300 s 即刷新,每台前台设备约每 60 s 刷新一次,150 s 窗口至少两次——判据 7 按构造红 | **改**:只对九张 `public` 同步表求和(可另加 `realtime` 的 `messages%` 分区),统计异步上报,窗口首读等两次读数相等再取 | `Done/Services/AuthService.swift:259-262 @ f57c024`(剩余 < 300 s 刷新);§8.4 的 `jwt_expiry = 360` |
| minor 比较交换按值比较会 ABA:§6.6 重置把 POST 的 `?` 改写成同一个 `?`,恢复前的 POST `[row]` 在重置后到达照样通过,把旧时间线 (h, s_old) 写进新 epoch,若那行恰在恢复中丢失、「没见到 → POST」已跑过,G1 回来 | **改**:比较交换另比在途表里的 token(每次发送 +1 的进程内计数器),重置清空在途表(§6 S4) | 出站流工作树 `Done/Services/SupabaseSyncService.swift` 的 `markSent` / `stillMarked` 按值比较(`baseline.entry(...) == marker`,未提交)|
| minor epoch GET 没说空页之后也要跑(恢复后的第一页通常是空的,为省 GET 跳过空页的实现会让在线设备晚发现);§7 交接单 (4) 只验 `rpc/sync_changes`,`sync_epoch` 的表结构缓存 404 会卡住每次拉取、经 I1 卡住每次上传 | **改**:§6.6 写明空页之后同样 GET、GET 读四列、404 / PGRST2xx 归表结构缓存类;§7 (4) 加 `GET /rest/v1/sync_epoch` 带用户 JWT 200 且恰好一行;§6.6 测试加变异体「空页不 GET」| reviewer;§6 失败分类的表结构缓存类 |
| minor 重置改写只对逐行条目写了;`user_settings` 的 `{seq, keys}` 与 agent_* 的映射没写;§6.3 表漏了代码已存的 `zone` | **改**:§6.6 加「非逐行的基线」一条(三段同样适用,(F, resume) → 每键 `?`,`zone` 原样);§6.3 表的 settings 形状补 `zone` | `Done/Services/Sync/SyncBaseline.swift:123-126 @ f57c024`(`.versioned(seq:keys:zone:)`)|
| minor I9 / §6.6 说「重置只有这一个入口,别处不丢游标」,而 S11 的加载时校验也丢游标 | **改**:两处都改成「session 内唯一的重置入口」,并点名加载时校验发生在任何链之前 | `Done/Services/Sync/SyncBaseline.swift:503-510 @ f57c024`(`validate(against:)` → `clear()`)|
| minor I2 / I3「重播触碰行的基线」对级联在本地改动、却没有来件版本的行有歧义(被释放的吸收 todo、孤儿化的 interrupt 子事件):它们若被重播就永不上传,service_role / MCP 的删除不跑客户端级联,服务端的 `absorbed_into_event_id` 永远悬空,新设备把 todo 处处隐藏 | **改**:I2 写明「触碰行」只指带来件版本的行,级联改动的行保持脏、不重播;I3 同注;§6 events 段一句 | `Done/Models/EventStore.swift:2690-2697 @ f57c024`(`releaseAbsorbedTodos`)|
| minor event_types 的胜者(活的同名者里最小 UUID)在两遍下依赖「页后」集合,结论取决于选胜放在哪一步 | **改**:第一遍算,集合 = 页前本地活行 ∪ 本页活行 − 本页 tombstone 的 UUID(§6 event_types 段)| 第八轮 `naive_dead_namesake_erases_live_type_witness` 的同一失败类 |
| minor §6.2 的 `sync.conflict key=zone` 在每次拉到 settings 行时都记;`skillAnalyzedEventIds` 每次分析都改这一行,时区分歧的设备会淹没 `sync.conflict` | **改**:每个 session 对同一个远端时区值只记一次 | `SkillInsight.swift` 写 `skillAnalyzedEventIds`(§6 user_settings 段原文)|
| minor §8.2 收敛 oracle (2) 不排除 `rejected` 的行,而「某一行永久 4xx」故障按设计让它红 | **改**:两侧都先去掉任何一台设备 `rejected` 里的 `(table, id)` | reviewer |
| minor §8.7 部分不可证伪:判据 3 的触达最低次数「由测试推导」没有公式,从观测值推导是套套逻辑;判据 9 的「每条都有解释」没有点名的产物 | **改**:最低次数 = ⌈r × 步数 / 1000⌉,r 是入库的每千步速率表(首次夜跑后按观测一半由人写定,只随动作权重改);判据 9 落在 `Docs/sync/03-production-trail-ledger.md`(到时新建,trail 行 → 原因 → 票号),行数 = 令牌条数 | reviewer |
| Lean 遗留 (a) 迟到的 `[row]` 是对发送时写下条目的比较交换 | **改**(S4 已是这条规则,补到每个写入点):§6 上传形状的 `[row]` 条、POST 条、「基线 hash 在上传成功时写入」段都写明按 token 比较交换 | Lean 流的 S4 模型 |
| Lean 遗留 (c) 单行表 tombstone + 未来的 #140 undelete 丢未推的脏改动(Lean `singleton_dirty_tombstone_lost_on_undelete_witness`);正文的「不丢任何一方」写错了 | **改**:§6 单行表段订正并写明今天不可达;§9.50 记为绑定 #140 的残余(附一种可选形状);§7 Phase 2 的 #140 行与 §10.6 (B) 写明它是 undelete 的前置 | Lean 流(witness 在 Lean 流在途的模型里,本工作树未入库)|
| reviewer 核为安全(按编排要求逐条推过):(a) 拉取链在途时恢复——RPC 之后的每页 GET 两种次序都拦住,写之前就放弃;(b) `?@s0` 落盘后、请求发出前进程死——重启后脏、`PATCH seq=eq.s0` 落地、比较交换对上重写的 `?@s0`;改回 c0 走 `[]` → pending-verify;POST 与 tombstone 同样收口;(c) token 窗口里的 23503 只能是 user_id 外键(同步表上的外键都是 user_id → auth.users)| 原文不动;(b) 在本轮之后仍成立:重启后在途表为空,重发写下新 token,比较交换照旧 | `grep -ln 'references auth.users' done-mcp/supabase/migrations/*`:同步表在 001 / 006 / 009 / 010,002–005 是非同步表;没有别的 `references` |
| 文档 → 代码引用抽查(约 120 处,reviewer 抽查的全部在所引 commit 上成立);漂移两处:`SyncedSettings.swift:152` / `:258`、`ContentView.swift:580`;S12 的「刷新成功」分支假设了 `forceRefreshToken()` 不返回的结果(见 M5)| **改**:两处漂移在原引用后补 `@ f57c024` 的行号(`:171` / `:277`、`Done/ContentView.swift:715`);其余引用照 header 的约定不重锚 | `git show f57c024:Done/Models/SyncedSettings.swift`、`git show f57c024:Done/ContentView.swift` 本轮核过 |
| **fresh-eyes 复核**(三位独立 reviewer 对 `design/realtime-sync @ e7a31e5`,2026-10-19;client 7 条、server 9 条、减法 11 条,逐条按 `e7a31e5` 的文本与代码复推)——以下各行 | | |
| 复核 R11-C1 MAJOR:rerun 拿防抖时的数组对新基线作差,中间一次拉取采用的行读成本地删除(B 新建的 todo 被 tombstone) | **改**:flush(含 rerun)在读基线的同一 tick 读活数组,防抖值只是触发;§8.2 加变异体 | `SupabaseSyncService.swift:836-850`、`:1392`、`:1420 @ e7a31e5`;算术见 §6「每表单飞 flush」(2) |
| 复核 R11-C2 MAJOR:六处「下一次 flush」没有调度者,留脏的行停到下次编辑 | **改**:每表待 flush 标志,到 head 的链结束时 flush 置位的表;轮询即重试时钟,不建计时器与退避 | 文件无重试计时器(`:642` 只是表结构缓存窗口);sink `:836-905`、fullSync `:803-820` |
| 复核 R11-C3 MAJOR + R11-S6 minor:暂停门只在 flush 开始查;`timeoutInterval` 是空闲超时;读按响应到达记;服务端执行不随客户端取消 | **改**:门逐请求查、读按发出时刻记、写 15 s 总时限、等待 W = 2P + T + S(约 3 分钟),S 在台架实测 | `pushTable` 只在 `:1390` 查门、之后 `:1464-1468` 连发;13.2k 行的算术见 §6.6 |
| 复核 R11-C4 minor:页等待实际要等排队时长(≈ 225 s) | **随减法 S2 撤销页等在途写而消失**;在途条目改在请求发出时写 | `:1446-1462` 在任何请求发出前标完整张表 |
| 复核 R11-C5 subtract:「在途行不进 flush」在单飞下只拦住被 23503 截断、从未发出的行,挡到重启 | **改**:删去,改为 flush 开始处的断言;在途条目在请求发出时写 | `:1464-1468`(`accountMissing` 跳过 PATCH / POST 阶段) |
| 复核 R11-C6 minor:页等待遇上 tombstone 在途行造成闪回 | **随减法 S2 消失**(§9.49 记下重开时 tombstone 不等) | — |
| 复核 R11-C7 minor:加入在途刷新会误判「刷新成功」;`rejected` 落盘与正文「内存、下次启动重发」不一致 | **改**:调用时已有在途刷新则再调一次;正文改为按 uid 落盘、重启不重发(与代码同) | `AuthService.swift:285-288`;`SyncWriteFailure.swift:176-178 @ e7a31e5` |
| 复核 R11-S1 / R11-S4 MAJOR + 减法 S1:跳号起点取自 dump、不单调(更旧的导出、重试的恢复);`setval` 不随事务回滚,中止的恢复把计数器留在 N0;跳号可整个去掉 | **改**,取 R11-S4 的强形式:恢复永不回拨计数器——`restore.sh` 从 data.sql 取出 `sync_seq` 的 setval 当 F 并删掉它,L = 活计数器;`resume`、`F + 2^40`、第三段、两个变异体与 Lean 跳号撤销;新项目恢复 `--last-seq` 必填。减法 S1 的「恢复前先暂停、等 135 s」不采用:不回拨之后不需要等待,而它的界本身要先修 R11-C3 / S6 | `sync_restore_drill.sh:412`、`:243-251`;`restore.sh:41-50`;算术见 §6.6「恢复脚本」 |
| 复核 R11-S2 MAJOR:设备只记最近一次 floor,跨「恢复 + 重新启用」离线的设备把丢掉的版本当成 ≤ F,干净采用 | **改**:`sync_epoch.lost` 累积丢失段,重置按 seq ∈ `lost`;不回拨保证并集不覆盖活号,对已重置设备幂等;Lean 加两次恢复轨迹 | 算术见 §6.6 重置 |
| 复核 R11-S3 MAJOR:`--replace` 的数据恢复把 dump 里的 `paused` 带回来 | **改**:`restore_with_epoch` 写 `paused := true`,运维在验后检查通过后单独置 false;`restore.sh` 结尾打印 `paused` | `restore.sh:41-45`(TRUNCATE 含 `sync_epoch`)、`restore_with_epoch.sql:28-36` |
| 复核 R11-S5 minor:单独跑 epoch 步骤时并发取号落进 (F, resume) | **随不回拨消失**:单独跑 F = L、`lost` 不增,并发取到的号是活的、不在任何丢失段里;`--replace` 路径由 TRUNCATE 持锁 | — |
| 复核 R11-S7 minor:跳号让演练四处断言红、守卫要改 | **改**(对不回拨同样成立):§6.6 点名四处演练断言、守卫的新条件、P10 | `sync_restore_drill.sh:182`、`:193`、`:253`、`:489`;`restore_with_epoch.sql:49-51` |
| 复核 R11-S8 minor:`create table if not exists` 不给跑过 v4 的表加列,每页 GET 400 `42703` | **改**:两列用 `alter table … add column if not exists`,P5 断言列存在 | `015:357` |
| 复核 R11-S9 subtract:用 revoke / grant `sync_epoch` 代替 `paused` 列 | **驳回**:`015:369-370` 每次重跑都 grant select,`reenable.sql` 第一步与每次 main push 都重跑 015,授权在重置之前回来,agent 在回滚期间的编辑被盲覆盖、零 shelf(算术见 §6.6「服务端暂停位」) | `015:369-370`;`ops/reenable.sql` 文件头 |
| 复核 减法 S2:页等在途写延到 Phase 2 | **改**:撤销;15 s 改成总时限并保留;残余与重开触发并进 §9.49 | — |
| 复核 减法 S3:S12 检测半在 Phase 1 不可达 | **不改,交用户**:代码已有(`SupabaseSyncService.swift:1674-1697 @ e7a31e5`),删正文省不掉代码;它能否移出 §8.7 判据 1、§8.3 的 GoTrue fixture 能否延期,与 §10.7 相连 | 仓库 grep 无应用内删号;`AgentSettingsView.swift:882-884` 只清本地 |
| 复核 减法 S4:首登前删种子延期 | **改**:Phase 1 只留规则 (1);规则 (2) 带触发条件进 §9.27 与 §7 Phase 2;§6.2 顺序、§7 交付与验收、§8.2 种子测试同删 | `EventStore.swift:935`(空库才种) |
| 复核 减法 S5:在途表与 pending-verify 合并;清空清单三处不一 | **改**(部分):写明 pending-verify 行不进 flush、两者前后相接不重叠、可实现成一张两相表;§6.4 一条清空规则覆盖全部内存表;不改名 | `SupabaseSyncService.swift:1439`;`PendingVerifySet.swift:45-49` |
| 复核 减法 S6:§13 搬到独立 changelog | **不改,交用户**:本轮只许改这一份文件,本轮的复核行也要求写在这里;漂移的「不 setval」三处就地加注 | — |
| 复核 减法 S7 / S8 / S9 / S10 / S11 | **改**:§9.35 改成一句指向 §6(原「回声先到则 c1 进 shelf」与在途回声行矛盾),旧的 60 s 标成当时的默认值;D8 与 §10.1 只指向 §7 (8);POST 无 sentSeq 时回声行的 seq 条件视为成立;§9.2 / 26 / 29 / 30 / 31 / 33 / 34 改成一句 + 锚点(§9.31 的 `h_loc` 漂移随之消失;39 / 40 本来就短,不动);`age_ms` 删去 | `grep age_ms`:§8 与 `Done` 零命中 |

**驳回**(调研 X 类,理由一句):X1 `[]` 之后显式读一次当前 seq——pending-verify 的推理在 `Inv` 下已证,打破 `Inv` 的三条路由 M1 / M2 关掉,加读要重写 `pullVerify` 模型与三条交错测试并逆转「不加额外 GET」;§6.6 的页前 GET 读的是 epoch 不是 seq。X2 预取用户锁消除 40P01——见 §9.17。X3 现在就做字段合并——主驱动 domino 被证伪,先 S7 量、L1 触发。X4 恢复后 `setval` 抬高序列——恢复行的 seq 仍小于基线,编辑照样被判相同(仍驳回;fresh-eyes M3 的跳号与 `resume` 复核撤销,改为恢复不回拨计数器,§6.6)。X5 用旧 `<hash>` 形状对所有行做倒退重置——恢复点之后已同步的编辑被回退。X6 拿门铃 seq 或响应到达时的游标当倒退信号——两者都误报,每次误报一次 27 页全量拉。X7 给 shelf 设上限或修剪——shelf 是败方唯一副本,设上限等于按设计丢数据;最坏一次恢复后多 10–20 MB,随设备备份,增长由 `sync.conflict` 计数看着。X8 业内有、我们有意不要的机制(操作日志 + 服务端 mutator、带数据推送、CVR / xid8 / 复制槽、墓碑压缩、原子 checkpoint、引导模式、按 sender 过滤回声)——调研 §B.3。X9 两参数 advisory 锁命名空间——碰撞没有证据,只给台架重跑多一个变量。X10 生产影子模式——只活一天,要验证的已被对拍、层 1 oracle 与层 3 对账覆盖,按原写法要么请求风暴(基线 seq 永不前进)、要么判据达不到。X11 UserDefaults 崩溃顺序测量——`kill -9` 造不出,由 S11 构造保证。X12 把 3/N 写成失败率「上界」——那是种子生成器分布上的上界,只记 N 与 commit。

v1.5 的减法:不建 outbox 或持久 pending-ID 集合(`?` 只覆盖在途写);评审后:epoch 的三个检查时点并成一条(每页)、纪元并进游标键(少一个键)、回滚的重新启用不另写语句(同一条 epoch 语句在新规则下就是「无丢失段」的重置)、不加 `sync_head()` 或任何新 RPC(epoch 一次普通 GET;`sync_digest` / `sync_counts` 留作 L7)、不 `setval`(复核:恢复脚本删掉 dump 的 setval,计数器永不回拨,§6.6)、不预取锁、不测 UserDefaults 崩溃顺序、不做生产影子模式、不给 shelf 设上限、不为被擦账号窗口内的 `[]` 建机制、L8 只留计数、两参数锁命名空间不进 015、§8 的随机套件不进默认全量(只跑冒烟版)。fresh-eyes 之后:在途表只在内存(不落盘 `?<sentHash>`)、M2 只等慢响应不为丢响应建机制、暂停位并进已有的每页 GET(不加新请求)、跳号复用恢复脚本那一条语句。

## 2026-10-19 变更记录(恢复规则交给 Lean 模型、§10.5–10.7 拍板、变更记录外移)

对 `design/realtime-sync @ 021860e` 的契约文本。恢复机制在散文评审里一轮轮重开(fresh-eyes M3 的跳号 → 复核的不回拨 + 累积 `lost` → checker 又报 1 MAJOR + 1 minor),这一轮不再用散文推,改由 `verification/CivilCalendar/SyncRestore.lean`(有界穷举,不是证明)对契约文本建模、给出规则。模型文件与搜索驱动在工作树里、未提交。

| 项 | 处置 |
|---|---|
| 模型对什么 | 契约 §5.7 第 7 条、§6.6、D10、§7 交接单 (8) 在 `021860e` 的文本;`ops/` 脚本在该 commit 上仍是旧版(`ops/restore_with_epoch.sql:28-36` 从活计数器取 floor、没有 `lost`),契约写的是「服务端流随本条改」,所以模型按文本走、称它「现行」。性质 P1 / P2 / P3 与只报告的 P3s 定义在 `SyncRestore.lean` 文件头;每个世界先静止(两台轮流拉取、flush 到一整轮无变化,最多 8 轮)再判。 |
| checker MAJOR (1) 成立 | `[dump, edit A X, flush A, bypass D0]`(绕开脚本后立刻单独跑 epoch 步骤):单独跑加的是空段,A 的条目保留 hash、seq 未知,采用恢复回来的行,c_a 不在任何地方 → P2。重放 `#guard failsWith current major1 "P2"`。改法:单独跑必须带 `--last-seq`(契约 §6.6「恢复规则」1)。 |
| checker minor (2) 成立 | `[dump, edit A X, flush A, restore.sh D0, dump(no sync_epoch), restore.sh D1]`:第二次 `--replace` 的 TRUNCATE 连第一次记下的段一起抹掉 → P2。重放 `#guard failsWith current minor2 "P2"`。改法:`restore.sh` 把活 `lost` 并进恢复行;同样通过的另一写法是拒绝不带 `sync_epoch` 的 dump(`altRefuse`)(契约 §6.6「恢复规则」2)。同时补上 minor 说的那句:`--replace` 之后留下的是 dump 行的 `lost` ∪ 活 `lost` ∪ (F, L](契约 §5.7 第 7 条)。 |
| 新:中止的 setval 回拨计数器 | 一次非脚本恢复在 data.sql 的 `setval` 之后中止,再单独跑:计数器停在回拨后的值、seq 被重用 → P1(`[edit A X, edit B X, dump, flush A, abort-after-setval D0]`);两行时出现不静止(一条孤儿 POST 每轮烧一个号,`[edit A Y, edit B Y, dump, agent X, abort-after-setval D0, pull B]`)。改法同 MAJOR (1):单独跑把计数器抬到 `--last-seq`。 |
| 新:F 只取计数器 | setval 之后中止、再单独跑时,若 F 只取活计数器,仍然活着的版本被宣布为丢失,落后设备的 `?` 回退一次更新的活编辑 → P3(`abortLagging`,`#guard failsWith abCounterFloor abortLagging "P3"`)。改法:F = max(计数器, 同步行 max(seq))。 |
| 新:回滚期间 UPDATE 保留旧 seq | `[dump, rollback, agent X, reenable, pull A, restore.sh D0]`:同一个 seq 命名两个版本,A 采用过的 agent 编辑不在 `lost` 里 → P2(`#guard failsWith abNoStamp rollbackRestore "P2"`;去掉这一部分、其余全留的一行搜索也找到它,所以它独立于 checker 的两条)。改法:回滚期间保留只做 `seq := nextval` 的盖号触发器;重新启用时整表重新取号不行(`#guard failsWith altRestamp restampRevert "P3"`)。 |
| 固定跳号不够 | (F, F + J] 代替 `--last-seq`:同一份旧导出绕开两次,第二次没盖住 → P2(`#guard failsWith abJump twoBypass "P2"`)。 |
| 正对照 | X4(只向上 setval、没有 epoch / floor)、X5(重置保留 hash 与 seq)、「任何 epoch 变化后一律本地胜」都被抓(`x4 scripted "P1"`、`x5 scripted "P1"`、`localWins lagging "P3"`),现行文本在 `lagging` 上通过(`verdict current lagging == none`)。 |
| 搜索规模(`lake exe syncrestoresearch 8 7`,约 766 s、峰值约 2.3 GB) | 推荐规则:一行、全部运维动作、深度 8、至多 4 个运维动作 1,201,025 个世界,违例 1,219 全是 P3s;一行、只有 `restore.sh`、深度 8 561,719 个世界,924 全是 P3s;两行、全部运维动作、深度 7、至多 3 个运维动作 3,171,667 个世界,292 全是 P3s;「窗口开着」族(绕开或中止之后、epoch 步骤之前设备就动作)1,887,268 个世界,P1 86,515、P2 34,773、P3 228——对每条规则都失败,即 §9.37 的残余。`altRefuse` 三族 1,269,919 / 440,100 / 3,252,203 个世界,只有 P3s。`altOvershoot`(`--last-seq` 多给 J)三族 1,675,248 / 611,739 / 3,458,500 个世界,只有 P3s(这一节不在那次运行的输出里,本轮另跑 `lake exe syncrestoresearch 8 7 "alternative: last-seq"`,约 57 s,退出码 0)。 现行文本:一行全部动作 1,773,449 个世界、95,731 违例(P2 67,486,P1 26,725,P3s 1,416,P3 104);只有 `restore.sh` 560,865 个(P3s 804,P2 486);两行 3,774,514 个(P2 43,452,P1 24,452,不静止 352,P3s 320,P3 8)。数字来自那次运行的输出,不进契约(会烂);构建期的小界穷举 `buildBounds` 每次 `lake build` 都重跑。 |
| 接受的代价 P3s | 写进契约 §6.6「恢复规则」:两台持有同一个被恢复丢掉的版本、一台又改过,另一台的 `?` 把更新的版本盖回去,更新的版本进 shelf(`forkRevert`)。两种设备侧变体 `devRemoteWins` / `devHybrid` 只减少不消除。 |
| 规则写进哪里 | 契约 §5.7 第 7 条(写入者)、§5「运维规则」末两条、D10、§6.6 新增「恢复规则」(规则、证据、代价、模型没覆盖的、Phase 1 交付清单)与「测试」的五条模型重放、§6.6「代价明示」、§6.6「服务端暂停位」末注、§7 交接单 (6)(8)、§7 Phase 1 增补、§8.1、§8.2 变异体、§8.3 演练、§8.7 判据 1 / 2 / 4、§9.37(含「待查」四条)、§12。设备侧规则不变。`ops/` 与 `tests/` 本轮未动,改动列为 Phase 1 交付。 |
| §10.5 拍板 | 用户 2026-10-19:(i) 按行锚定。每个待办行带 `domino_anchor`,推移 = now − 锚点,推完锚点 := now,锚点随行同步;015 还没上生产,列并进 015 v5(契约 §5 第 8 条)。代码改动点 king `Done/Models/EventStore.swift:502-577`、`Done/DoneApp.swift:913` / `:944`(king `ee6f47a` 上核过)。随之去掉:(ii) 的「非写者 domino 写为 0」测试、透传提前、§9.22 的「方案 (ii) 无此残余」。 |
| §10.6 拍板 | 用户 2026-10-19:(A) 撤销提示期间 merge / smart split 删掉的行不发 tombstone,计时器触发后再发。改写 §6「冲突行基线」(d)、§6 上传形状 S4 段的撤销结局、§7 Phase 2 的 #140 行、§8.2 / §8.4 的 S2 断言、§9.40、§9.50。 |
| §10.7 拍板 | 用户 2026-10-19 原话「让用户选择」:终态之后停止同步、什么都不删;提示三选一——留在本机(不同步)/ 清空本机 / 登录新账号后显式上传本机数据;选之前数据不动;S5 守卫只在第三项清掉。三项都复用已有路径(不动、`resetAllLocalData()`、S5 的「把本机数据用于新账号」)。事实:`git grep -i -E 'deleteAccount\|delete_account\|account deletion\|deleteUser' -- Done/` 在 king `ee6f47a` 与本分支 HEAD 上零命中,今天没有应用内删除账号,Phase 1 的触发只可能是服务端删除。改写 §6.4、§8.2、§8.3、§9.13、§9.41。 |
| 「待拍板」字样 | 契约里依赖这三项的「待拍板 / 拍板前 / 若选」全部改成拍板后的规则:头部状态行、§6 I1 段与 domino 段、§6.4、§7 Phase 1 / 2、§8.2、§8.3、§8.4、§8.7 判据 1、§9.3、§9.13、§9.22、§9.40、§9.41、§9.50、§10.5–10.7 与 §10 末段。§10 各项保留开项时的选项原文作记录。 |
| 变更记录外移 | 契约 §13(原第 535 行到文末)与头部第 3–4 行的日期史原样搬进本文件;契约留一行指针与一行状态,§13 标题保留为指针,正文引用 §13 的三处(§7 P0.3、§8.7 判据 1、§10 末段)改指本文件。契约大小 814 行 / 323,513 字节 → 559 行 / 256,545 字节。 |
