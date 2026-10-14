# Release Check

对着走的发布冒烟清单。每版更新 build 号与「本版含/不含」，然后按 ②③④ 逐条冒烟。

**本版：0.5.0 (build 6)** — 一个主题：**「擦除所有本地数据」**。前一版 0.5.0 (build 5) archive `2026-10-07 16:14`（king `aa577df`，四条 held 分支 #234/#235/#229/#181 首次出包）。

**本版含**（king `aa577df` → `739fee9`，三次合并）：
- **gh#255/#256** —— 擦除必须取消它自己的待写入（笔记 commit 在擦除后落盘）。
- **gh#258** —— `Documents/backup-snapshot.json`（全量明文，且**在 iOS 设备备份里**）此前没有任何代码删它；并且快照只是**信使** —— 六个键各自活下来、第一次 `didEnterBackground` 原样写回，其中 `mcpURL` 是带 token 的永久连接器 URL。
- **gh#260/#261/#263/#265/#266** —— 又四个 store 活过擦除（用户照片、别人的照片、`Documents/Reports/*.json` 含用户自己写的 note、用量账本）；`LocalDataEraseEpoch` 管住**在途写入**（六个写入方）；**七个 test-host seam** —— 在此之前**在装机设备上跑这套测试会毁掉该用户自己的数据**；擦除现在**会登出**（`supabaseAuthSession` = 活的 refresh token + 邮箱）。

**本版不含**（确认不在包里）：
- **gh#266 的 `ErasableLocalStore` 注册表** —— 这个家族的真修法（清单从定义处派生，忘写变编译错误）。本版仍然靠**点名**，接线断言只钉住「这一行还在」。
- 普查（已按用户拍板摘除，四轮评审四次发假绿灯）。
- gh#239 小组件排版簇（归档在 `archive/widget-layout-239`，缺陷仍在设备上）。
- 报告那条 token 晚一跳、`AgentDecisionDebugFileLogger` 的 DEBUG 落盘、`spike.<id>` 开发者 flag —— 均已评审记录、刻意未动。

> build 4 archive `2026-09-21 23:02`，发布后连续使用约两周无明显问题（用户 2026-10-07 口述；认证侧 edge_logs 同期 `/auth/v1/token` 全 200 对得上）。

---

## ✅ 0 — 安全前置（已完成，留档）

- **build 3 带泄露的 service_role key**（archive `2026-09-21 22:59`，bump commit `4ee1a68` 早于修复 `3eb5c13`/`2e93cab`）。
- **build 4 (`45152d6`) 是第一个带 gh#232 修复的包** — archive `2026-09-21 23:02`，已上传生效。
- **顺序硬要求已按序执行**：build 4 先发 → **2026-09-23T01:25:35Z 才禁用 legacy JWT keys**。泄露 key 现全路径 401，用户会话是 ES256 非对称签名故无人被登出，两台 Done/4 设备连续 200/201。gh#232 已关闭。
- 后续版本不再需要这一节的门；`strings <binary> | grep -c sb_publishable_` 仍建议当发版硬门。详见 memory `project_service_role_leak_incident.md`。

---

---

## ① Archive 身份（上传前 30 秒）

- **来源提交(最重要的一条,不要跳)**:archive 必须切自 king,且该提交含安全修复 `2e93cab`。**build 6 切自 king `739fee9`** —— 切包时在那次会话里把实际提交和本地时间写在这里。
  > 这是唯一能抓住 build-3 那类事故的工具 —— 包的 `Info.plist` 只有 Version / Build / SigningIdentity / Team,**没有任何提交戳**,所以这件事只能在切包的那次会话里断言,事后无法从包里查。build 3 就是在这条缺位时发出去的。
- Organizer 里版本显示 **0.5.0 · 6**（build 号必须是 6,不是 5）。marketing version 刻意留在 0.5.0:还在内测，同一 version 下多个 build 才是对的口径。
- `strings <binary> | grep -c sb_publishable_` **≥ 1**（发版硬门，承自 build 4）。
- 泄露 key 前缀 `LUwM3K` 计数 **= 0**。
- 本版**新增 / 不含**见文件顶部的「本版含/不含」。build 5 的四条（#234 / #235 / #229 / #181）和 build 4 的 7 个 perf 修复都**仍在包里**。

> 合并树实测:**1988 测试 / 0 失败 / 1 已知 skip**(build 5 时是 1931)。擦除家族逐条合、每条后跑全套;round 2 的 25 个变异体全杀,含两个证明量具有牙的正对照。

---

## ② 回归冒烟:build 4 那 7 个修复还在正常工作

这一节是**回归检查**(它们已经跑了两周),快速过一遍即可。

| 查 | 动作 | pass = |
|---|---|---|
| **#37** 类型建议缓存 | composer 打字;加/改类型模板后再打字 | 不卡;建议**立即反映**新模板 |
| **#164/#163** detail 隔离 | 开事件详情盯几秒;Add Note 打字;**左缘返回手势** | 进度/时长**在走**;打字稳;返回跟手 |
| **#195** composer 隔离 | 详情里开 interrupt composer 打标题 | capsule + tint 随打字反应(标题文字**不**回显 = 设计) |
| **#148** 对话首帧 | 开 agent/聊天页 | 历史直接出,**无空白闪一下** |
| **currentEvent** O(1) | 开多个详情:非重复 + **重复系列** + **脱离的例外实例** | 每个都显示**正确事件** |
| **Analysis** hoist | 开 Analysis tab | 小时数/类型分配**数字对** |
| **interrupt-walk** | 把 todo **absorb** 进事件 | absorb 成功;**关系链完好** |

---

## ③ 本版四条新增的装机验证(**这是这版的主要目的**)

### #234 — auth 终端分类

走不到死状态就验**出口存在**即可:Account 页在未登录时显示登录界面(这一条已经由 #234 的类型改动接住)。真要造死状态需要两台设备争用同一条 refresh token。

**要留意的两条**:
- 登录失败时错误卡片的文案;非 JSON 的 4xx/5xx 现在显示 `Authentication failed (HTTP n)` 而不是 `Invalid response`。
- Settings → Developer 的 trail 提示已改成「Counts, row IDs, and a fixed list of auth error codes…」—— 确认它和 trail 实际内容相符。

### #235 — 日历增量写(B6,**本版最重要的一项**)

**怎么读(上一版这条写成了跑不起来的样子,已改)**:trail 行是 `save calendarEvents: seq=… count=… mode=checkpoint … encodeMs=… … reason=background` —— `mode=` 和 `reason=` 中间隔着九个字段,**所以不能把 `mode=checkpoint reason=background` 当一个字符串去 grep,那样恒为零行,而零行读起来像「干净」**。

正确做法:导出 Diagnostic Trail → 筛**同时**含 `mode=checkpoint` 和 `reason=background` 的行(两个独立条件)→ 按会话计数 → 读各自的 `encodeMs`。

**判据**:三个生命周期边里 `flushCalendarDeltaCheckpoint` 只有**第一个**清空 log、后两个空 log 早返回 → **每次打断至多一次** 2 MB 主线程编码,**超过一次就是 finding**。再和 #201 / #195 的帧数据对照,确认这条边没有新慢帧。

> ⚠️ **本版新增的交互,合并点才出现**:背景化那条边现在依次跑 `flushCalendarEventColorDepthMirror` → `flushWidgetSnapshotSync` → `flushCalendarDeltaCheckpoint`(顺序是刻意的,见代码注释),而 **#229 在编辑器开着时会从 `scenePhase` 再加一次 `flushPendingLogRecordCommit`**。所以「打断边的主线程开销」要按边分别数:**`willResignActive` = 四件**(mirror + widget + checkpoint + #229 的视图层 flush);**`didEnterBackground` = 五件**(多一个 `storage.syncDirectoryToStableStorage()`)。别把 #229 的 flush 误记成 #235 的第二次编码。

> 🔍 **顺便验一个评审提出、但没人在设备上测过的怀疑**:`flushCalendarDeltaCheckpoint` 是生命周期 sink 的**最后一句**,但 sink 不是这条边上最后跑的东西 —— `CalendarEffortQuickControl` 和 detail 页的 deadline coalescer 各有一个 `.onChange(of: scenePhase)`,它们**在 sink 之后**还会写 `.calendarEvents`,把 checkpoint 刚清空的 log 重新弄脏。
>
> **怎么验**:开事件详情 → 手势进行中拨 effort 或转 deadline 轮 → 触发一个**只有 `willResignActive` 没有 `didEnterBackground`** 的打断(来电横幅 / 控制中心 / 通知栏下拉 / Face ID)。然后在 trail 里找:`mode=checkpoint reason=background` 之后有没有出现 `mode=delta` 行、且后面再没有 checkpoint。
>
> **有 = 怀疑成立**(下次冷启动要付 #235 本来设计成「仅崩溃时」的同步 fold,且「启动时 log 非空 = 崩溃证据」在普通来电后变成假阳性);**delta 行出现在 checkpoint 之前 = 怀疑被证伪,可以关掉**。两种情况都**不是丢数据** —— delta 追加自己 fsync 过,fold 也是对的。

**syncMs 判读**:设备 A/B 若也从未观察到非零的 delta `syncMs`,读作「在此粒度下不可测」,**不是「免费」**——它在模拟器上恒为 0。

### #229 — note 落盘防抖

在 detail 页**和**内嵌 log editor 各打多字符 note → 打字中途 background / 杀 → 重启断言 note 在(kill-cycle durability)。两个入口都要试:它的 flush 挂在视图层 **5 个站点**(log sheet 的 `scenePhase` / `onDisappear` / Cancel,detail 页的 `scenePhase` / `onDisappear`),**不在** store 的生命周期发布器上 —— 这是刻意的。

### #181 — 密集日拖拽

密集日 move-drag 拖到边缘触发 autoscroll → 看**尾部帧**(p95/max,**不看均值** —— 均值正好藏住要查的那种顿挫)。被拖块跟手无回弹,源列不冻结。

---

### 擦除完整性 —— gh#258/#260/#261/#263/#265/#266(**合入后必跑,且是这一族唯一的真验证**)

这一族五个缺陷的共同形状:**「擦除所有本地数据」留下了用户数据**,而且每一个都是靠某次 review 恰好看到才发现的。套件里**没有**任何东西断言清单完整(普查试过两版、四轮被否,见 #266)。所以这一节不是冒烟,是这一族的验收本身。

> ⚠️ **第 3 步的「立刻强杀」是整节的关键**,不是谨慎。本地 DR 快照的写盘是 **30 秒防抖**;擦除靠重建订阅把那次防抖丢掉。如果你擦完先在 app 里看一圈再杀,那条防抖已经过去了,**你验的就不是防抖被丢掉,而是「它没来得及触发」** —— 两者都显示「文件没了」。

**1. 播种(一样都别省 —— 每一样都对应一个修过的缺陷)**

| 种 | 怎么种 | 对应 |
|---|---|---|
| 事件附件照片 | 给一个事件加 2 张照片;给一条 log note 再加 1 张 | #260 |
| 联系人头像 | 给两个 person 各设一张头像 | #263 |
| 我的头像 | Me → 设头像 | 原有 |
| 报告 + 自己写的 note | 生成一份报告,在里面写一句 note | #261 |
| 时间线缩放 | 在日历上**双指捏合**改时间线高度(别用默认值) | #265 |
| MCP 连接 URL | Settings → 生成 MCP URL(**带 token**) | #258 |
| spike 运行记录 | FixWatch 里跑一次 spike 并写 note | #263 |
| 自定义纪念日 + Me 反思 | 各写一条 | #265 |
| 本地 DR 快照 | 背景化一次,等 ≥30 s 让它落盘 | #258 |
| 登录态 | 保持登录(第二轮新增) | #266 |
| MCP URL 进剪贴板 | Me → Account 生成 URL,点「复制」,**之后别再复制任何东西** | #266 |
| 界面语言/时钟 | 切成中文 + 12 小时制 | #266 |
| 日历视图状态 | 捏一下缩放,切到「周」,打开「记住视图模式」 | #266 |

**2. 擦除**:Settings → Data & Privacy → Reset All Local Data。

**3. 立刻强杀**(上滑杀进程,**不要先逛**)→ 重启。

**4. 判据(每条都要看,任一条留存 = ship-blocker)**

- [ ] 事件/log 的照片全空,**且**不会在几秒后自己回来(后台恢复循环会重建目录)
- [ ] 联系人头像没了
- [ ] Me 头像没了
- [ ] 报告列表空,**report 里那句 note 不在任何地方**
- [ ] 时间线高度回到默认(≈56 pt),不是你捏成的那个值。**然后再捏一下、松手**,确认写回去的是新值而不是擦除前那个 —— 这一条原来只因为第 3 步立刻强杀才通过:活着的 `CalendarViewState` 当时还捏着旧值,下一次 pinch 或者一次布局就会把它写回磁盘
- [ ] 视图模式回到「日」(不是你切的「周」)
- [ ] **处于未登录状态**。Me → Account 看不到任何邮箱,也点不动「从云端恢复」(第二轮新增:`supabaseAuthSession` 是第七个漏清的,里面有活着的 refresh token 和你的邮箱,下一个拿手机的人能直接把擦掉的数据全拉回来)。云端数据本身没动,重新登录就还在
- [ ] **界面语言和时钟格式回到默认**(英文 / 24h)
- [ ] 随便找个输入框**粘贴** —— 粘不出那个 MCP URL(擦除前刚复制过的话)
- [ ] **MCP URL 不在了**。⚠️ 但要知道这只是本地:服务端 `api_keys` 那行**仍然有效**,拿着旧 URL 的人照样能读 —— 吊销是单独的事(见 #258 的注释)
- [ ] spike 运行记录和 note 没了
- [ ] 纪念日、Me 反思没了
- [ ] **Diagnostic Trail 是空的**(Settings → Developer → 导出),只有本次启动的 banner
- [ ] 再背景化一次、等 40 s、再强杀重启 —— 快照**没有**带着擦除前的内容回来

**5. 三条在途竞态(gh#266 / `LocalDataEraseEpoch`)**

这三条是「擦除时有网络请求在飞」,只能手动造:

- [ ] **报告**:点「生成报告」→ 在转圈期间立刻去擦除 → 等请求回来 → **报告列表仍为空**,`Documents/Reports/` 没被重建
- [ ] **照片恢复**:在另一台设备上有照片的账号上触发 restore → 下载进度条走起来时擦除 → **照片不回来**,进度条停住而不是继续
- [ ] **用量账本**:擦除时有 LLM 请求在飞 → Developer → LLM Usage **仍为空**;然后做一次正常的 agent 操作 → **它要重新开始计数**(不计数 = 修成了「永远不记账」,是另一个 bug)
- [ ] **技能分析**(第二轮新增):启动后它会对过去的事件逐个发 LLM 请求 —— 趁这个扫描在跑时擦除 → Me 的技能洞察**仍为空**,而且不会在几秒后自己长回来
- [ ] **头像恢复**(第二轮新增):这条反直觉 —— **擦除本身就是它的触发条件**。`MeAvatarStore.delete()` 让 `downloadAvatarIfMissing` 的「本地没有头像」判据成立。所以:在有云端头像的账号上触发 restore,下载期间擦除 → **头像不许回来**

**6. 套件自身不再有破坏性**(这是我自己制造的隐患,已修)

> ⚠️ **这一步必须在第 1 步之前做**,而且要在一台**还没擦**的机器上。
>
> 它原来写在最后,而且是不可能通过的:第 1–4 步刚刚亲手删掉了 Me 头像、事件照片、联系人头像,第 6 步却让你确认这三样「还在」。照字面执行,三条里有三条无法满足,人只能划个勾或者自己临场发挥。
>
> Trail 那条更糟:第 4 步的判据本身就是「Diagnostic Trail 是空的,只有本次启动的 banner」,第 6 步接着问「真实的 trail 还在吗」—— 强杀重启之后,**一个健康的 trail 和一个被毁掉的 trail 读起来一模一样**:都是一条 session banner 加本次运行的几行。这是唯一不可恢复的介质,而原来给它的手法没有任何分辨力。
>
> 所以:**先量,再跑套件,再比对**。没有基线的「还在」不是判据。

跑套件**之前**,在机器上记下这些(Developer → 导出,或 Finder 看容器):

| 位置 | 记什么 |
|---|---|
| `Application Support/Diagnostics/trail.log` | 字节数 + 最后一行 |
| `Application Support/Diagnostics/MetricKit/` | 文件个数 |
| `Application Support/PersonAvatars/` | 文件清单 |
| `Application Support/AgenticIntakeAssets/` | 文件个数 |
| `Application Support/AgentRuntime/` | 两个 json 的字节数 |
| `Documents/me-avatar.jpg` | 存在 + mtime |
| `Documents/spike-runs/` | 文件个数 |
| `Documents/Reports/` | 文件个数 |
| 小组件 | 主屏/锁屏截一张图 |

- [ ] 在**这台 dogfood 机**上跑一次完整套件
- [ ] 上表逐行比对:**全部逐字节不变**
- [ ] 小组件和跑之前那张截图一致(没变空、也没出现 demo 事件)
- [ ] `UserDefaults.standard` 里**没有** `MetricPayloadStore.migratedDocumentsDiagnostics.v1`(只有 `.test-host` 那个)

> 为什么要查这条:`DiagnosticTrail`、`MeAvatarStore`、`PersonAvatarStore`、`AgenticIntakeAssetStore`、`SpikeRunStore`、`AgentPreferenceStore`、`MetricPayloadStore`、以及 App Group 的小组件载荷,原本都解析**容器级**路径且没有 XCTest 重定向,而擦除路径被测试驱动着 —— 跑一次套件就会毁掉这台机器上的真实数据。Diagnostic Trail 最严重:它存在的意义就是回答「上个进程死前报告的写入到底落盘了没」,iOS 不让第三方 app 读回系统日志,**毁了就没了**。
>
> 最后一条是第二轮新增的,量的是另一种损失:重定向当初只搬了路径、没搬迁移标志位,于是套件跑一次就把真机的「旧堆已迁移」设成 true,`Documents/Diagnostics` 那堆旧文件**永远不会再被清理**(gh#219 的磁盘占满缺陷被钉成永久状态)。**只搬一半状态的重定向比不重定向更坏** —— 生产代码会拿一半去读另一半。
>
> 每个 seam 现在都有测试钉住(`EraseWiringQATests.testEveryPurgeCapableStoreIsRedirectedUnderXCTest`)。这句话上一版写的是「四个 seam 都在 `EraseInFlightWriteTests` 里钉住」,而四个里有两个根本没钉:`PersonAvatarStore` 哪里都没钉,把它的重定向改回生产名字,整套 1974 个测试照样全绿 —— 而那一步会永久删掉这台机器上每一张联系人照片,同时 `Person.avatarImageName` 已经先被删了,连手工辨认都做不到。

---

## ④ 可选 liveness 瞥一眼(非阻塞)

- 事件时间线**坐着不动** → 自己从 manual **翻回 live**。
- (可跳)损坏对话文件冷启动 → storage-fault banner **首帧就出**。

> 判读:②③ 全 pass → 这版干净。

---

## ⑤ gh#235 calendar 增量日志 —— 已发布,三个用户可见变化(其中 (b) 带回滚代价)

> **状态**:已合入 king,**在 build 5 里**。下面两条不是 bug，是这个改动**设计上的代价**。夹具实测：一次编辑的写入 12,713,275 B → 27,582 B（461×），主线程 encode 271 ms → 0 ms。

### (a) 恢复粒度：backup-promotion 现在落后**一个 checkpoint**，不再是一次编辑

`.bak` 以前每次 save 刷新，现在**每个 checkpoint 刷新一次**。普通编辑只往 `calendarEvents.log` 追加、不动 slot 文件，因此也不动 `.bak` 硬链。结果：从 `.bak` 恢复时拿到的是**上一个 checkpoint 的那一代**，最坏情况落后**一整个前台会话**（checkpoint 只在后台化边和各种 fallback 上产生）。

**不丢数据**：primary 坏掉而 log 还活着时，promotion 被**直接拒绝**并冻结该槽（`refuseCalendarPromotionWithLiveLog`），不会悄悄把更旧的一代当成现状端上来。但**恢复粒度本身是用户可见的变化**，属于发布说明该写的那一类。

### (b) 降级窗口：旧版二进制不认识 `calendarEvents.log`

旧版**完全不认识**这个文件，只会服务最后一个 checkpoint；而它下一次全量写会让那些 delta **不可恢复**。`flushCalendarDeltaCheckpoint` 把窗口**收窄到一次后台化**（每个后台边先把 log 折回 slot 文件），但**没有消除**它：在「最后一次编辑」和「下一次后台化」之间降级，那段编辑就没了。

**含义**：这版一旦发出去，回滚到不含 #235 的二进制不是零成本操作。运行时 kill switch（`calendarDeltaLogEnabled`，缺省 ON）是字段级 rollback —— 关掉后下一次 save 即写全量 checkpoint 并清空 log，是**完整**回到 pre-#235 的路径。

### (c) 两条测试现在见证的是**旧形状**，不是已发布的形状

`EventStoreDeletionOrderingTests.swift:646`（`testLaunchSweepIsRefusedAfterABackupRecovery`）和 `EventStoreDurabilityTests.swift:281`（`testWipeRemovesThePreWipePlaintextCopies`）原本见证的就是上面 (a) 的旧粒度。两条都用 `flushCalendarDeltaCheckpoint()` 重做了夹具，好让「`.bak` 持有真正更老的一代 + log 为空」这个形状还能造出来。

**明说，免得夹具暗示相反**：它们现在证明的是「**在强制 checkpoint 之后**这条路径仍然正确」，**不是**「日常编辑之后仍然正确」。日常编辑之后 `.bak` 就是落后一个 checkpoint 的 —— 那是 (a)，是设计，不是这两条测试能盖住的东西。

---

---

## 附:perf 战役记分牌(截至 build 5)

- **已合入 king(11)**:#37 / #164 / #163 / #148 / #195 / currentEvent / Analysis / interrupt-walk(以上 build 4)+ **#234 / #235 / #229 / #181**(build 5)
- **归档未合**:#239(`archive/widget-layout-239`,票仍 OPEN,缺陷还在设备上)
- **永不合**:#231(flag 门控测量 spike;要数据就单独 build 那条分支)
- **死路**:#43/#52(越翻越卡;真解 = UIKit 时间线迁移 #57/#14,撞 #103 冻结)
- **#234 拆出的后续**:#249 Keychain(复发向量)· #250 瞬时退避 · #251 restore 会话门 · #252 四条小项 · #253 登录日志 `.private`
- **#235 拆出的后续**:#240 / #241 / #242
- **母票**:#219(战役总账)· #235(性能续章)
