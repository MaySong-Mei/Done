# Release Check

对着走的发布冒烟清单。每版更新 build 号与「本版含/不含」，然后按 ②③④ 逐条冒烟。

**本版：0.5.0 (build 5)** — 四条 held 分支全部合入。前一版 0.5.0 (build 4) archive `2026-09-21 23:02`，已发布并连续使用约两周无明显问题（用户 2026-10-07 口述；认证侧 edge_logs 同期 `/auth/v1/token` 全 200 对得上）。

---

## ✅ 0 — 安全前置（已完成，留档）

- **build 3 带泄露的 service_role key**（archive `2026-09-21 22:59`，bump commit `4ee1a68` 早于修复 `3eb5c13`/`2e93cab`）。
- **build 4 (`45152d6`) 是第一个带 gh#232 修复的包** — archive `2026-09-21 23:02`，已上传生效。
- **顺序硬要求已按序执行**：build 4 先发 → **2026-09-23T01:25:35Z 才禁用 legacy JWT keys**。泄露 key 现全路径 401，用户会话是 ES256 非对称签名故无人被登出，两台 Done/4 设备连续 200/201。gh#232 已关闭。
- 后续版本不再需要这一节的门；`strings <binary> | grep -c sb_publishable_` 仍建议当发版硬门。详见 memory `project_service_role_leak_incident.md`。

---

---

## ① Archive 身份（上传前 30 秒）

- **来源提交(最重要的一条,不要跳)**:archive 必须切自 king,且该提交含安全修复 `2e93cab`。**本包切自 king `aa577df`**(2026-10-07 16:14:50 本地,含 `2e93cab`)。
  > 这是唯一能抓住 build-3 那类事故的工具 —— 包的 `Info.plist` 只有 Version / Build / SigningIdentity / Team,**没有任何提交戳**,所以这件事只能在切包的那次会话里断言,事后无法从包里查。build 3 就是在这条缺位时发出去的。
- Organizer 里版本显示 **0.5.0 · 5**（build 号必须是 5,不是 4）。marketing version 刻意留在 0.5.0:还在内测，同一 version 下多个 build 才是对的口径。
- `strings <binary> | grep -c sb_publishable_` **≥ 1**（发版硬门，承自 build 4）。
- 本版**新增**四条：**#234** auth 终端分类 · **#235** 日历增量写 · **#229** note 落盘防抖 · **#181** 密集日拖拽 memo。
- 本版**仍含** build 4 的 7 个 perf 修复（#37 / #164 / #163 / #148 / #195 / currentEvent / Analysis / interrupt-walk）。
- 本版**不含**:**#231**（flag 门控的测量 spike，设计上永不进生产）· **#239**（2026-10-07 归档到 `archive/widget-layout-239`，装机截图仍是老症状，未合）。

> 合并树实测:**1931 测试 / 0 失败 / 1 已知 skip**。四条逐条合、每条后跑全套,递进 1759 → 1895 → 1921 → 1931。

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
