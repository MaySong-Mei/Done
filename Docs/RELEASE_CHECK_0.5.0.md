# Release Check — 0.5.0

对着走的发布冒烟清单。每版更新 build 号与「本版含/不含」，然后按 ②③ 逐条冒烟。

**已发布：0.5.0 (build 4)** — archive `2026-09-21 23:02`，king `45152d6`。下一版为 build 5。

---

## ✅ 0 — 安全前置（已完成，留档）

- **build 3 带泄露的 service_role key**（archive `2026-09-21 22:59`，bump commit `4ee1a68` 早于修复 `3eb5c13`/`2e93cab`）。
- **build 4 (`45152d6`) 是第一个带 gh#232 修复的包** — archive `2026-09-21 23:02`，已上传生效。
- **顺序硬要求已按序执行**：build 4 先发 → **2026-09-23T01:25:35Z 才禁用 legacy JWT keys**。泄露 key 现全路径 401，用户会话是 ES256 非对称签名故无人被登出，两台 Done/4 设备连续 200/201。gh#232 已关闭。
- 后续版本不再需要这一节的门；`strings <binary> | grep -c sb_publishable_` 仍建议当发版硬门。详见 memory `project_service_role_leak_incident.md`。

---

## ① Archive 身份（上传前 30 秒）

- Xcode 打开的是 king，`git log -1` = `45152d6`（或更新的 king，只要含 `2e93cab` 安全修复）。
- Organizer 里版本显示 **0.5.0 · 4**（不是 3）。
- 本版**含**：7 个 perf 修复（#37 / #164 / #163 / #148 / #195 / #213 currentEvent / #213 Analysis / #213 interrupt-walk）+ gh#232 key 轮换。
- 本版**不含**：#181 / #229 / #231（在各自 held 分支上，未合并）。

---

## ② 冒烟：7 个 perf 修复功能正常 + 无 liveness 回归

逐条「做动作 → 看是否 pass」。

| 查 | 动作 | pass = |
|---|---|---|
| **#37** 类型建议缓存 | 事件/日志 composer 打字；再加/改一个类型模板后打字 | 打字不卡；建议出现且**立即反映**新模板 |
| **#164/#163** detail 隔离 | 打开事件详情盯几秒；Add Note 打字；**左缘返回手势** | 进度填充/时长**在走**（没冻）；打字键盘稳；返回**跟手不掉帧** |
| **#195** composer 隔离 | 详情里开 interrupt composer 打标题 | 时间线 capsule + tint **随打字反应**（标题文字**不**回显 = 设计）；保存后块出现 |
| **#148** 对话首帧 | 打开 agent/聊天页 | 历史直接出，**无空白闪一下再 pop** |
| **currentEvent** O(1) index | 打开多个详情：非重复 + 一个**重复系列** + 一个**脱离的例外实例** | 每个都显示**正确事件**（重复/脱离尤其看） |
| **Analysis** hoist | 打开 Analysis tab | 小时数/类型分配**数字对** |
| **interrupt-walk** | 把一个 todo **absorb** 进事件；看有 interrupt 子块的事件 | absorb 成功；**关系链完好** |

---

## ③ 可选 liveness 瞥一眼（archive-前 liveness 审计留的 2 个，非阻塞）

- 事件时间线**坐着不动** → 自己从 manual **翻回 live**（auto-resume 驱动叶子仍 1s tick）。
- （可跳）损坏对话文件冷启动 → storage-fault banner **首帧就出**（不是等点进聊天才出）。

> 判读：②③ 全 pass → 这版干净，放心 TestFlight。

---

## ④ Held 分支设备待办（**不在这版**，要单独 build 那个分支装机）

数据出来才决定进不进下一版（build 5）。

| 分支 | # | 装机验什么 |
|---|---|---|
| `spike/report-gen-mainthread-231` | #231 | 开 measure flag → 生成报告 → Diagnostic Trail 读 `Spike231 path=report variant=onMain ranOnMain=true buildMs=NNN`。`ranOnMain=true` 时的 `buildMs` = 主线程 stall。开 A/B off-main 对比 `ranOnMain=false`。**卡就连 clue-battery 一起 productionize；不卡就关掉留档。** |
| `fix/drag-render-memo-181` | #181 | 密集日 move-drag 拖到边缘触发 autoscroll → 尾部帧（p95/max 非均值）下降 + 被拖块跟手无回弹无冻结源列 |
| `fix/log-record-commit-debounce` | #229 | 在 detail 页**和**内嵌 log editor 各打多字符 note → 打字中途 background/杀 → 重启断言 note 在（kill-cycle durability） |
| `fix/calendar-events-delta-log-235` | #235 | **B6**：`willResignActive` 边，每会话数 `mode=checkpoint reason=background` 的行数与各自 `encodeMs`，对照 #201/#195 帧数据确认该边无新慢帧。三个生命周期边里 `flushCalendarDeltaCheckpoint` 只有**第一个**清空 log、后两个空 log 早返回短路 → **每次打断至多一次** 2 MB 主线程编码，**超过一次就是 finding**。<br>**syncMs 判读**：设备 A/B 若也从未观察到非零的 delta `syncMs`，读作「在此粒度下不可测」，**不是「免费」**——它在模拟器上恒为 0，没有任何东西把它钉成一次测量。 |

各分支合并前需 rebase 到当时 king + 合并树重跑全套。

---

## ⑤ gh#235 calendar 增量日志 —— 合并前必须知道的两个用户可见变化

> **状态**：`fix/calendar-events-delta-log-235`，**未合并、不在 build 4**。下面两条不是 bug，是这个改动**设计上的代价**，在决定合进哪一版之前必须先被知道。夹具实测：一次编辑的写入 12,713,275 B → 27,582 B（461×），主线程 encode 271 ms → 0 ms。

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

## 附：perf 战役记分牌（截至 build 4）

- **已合入 king（7）**：#37 / #164 / #163 / #148 / #195 / currentEvent(#213) / Analysis(#213) / interrupt-walk(#213)
- **held 待装机（3）**：#181 / #229 / #231
- **死路**：#43/#52（越翻越卡；真解 = UIKit 时间线迁移 #57/#14，架构级另立项，撞 #103 冻结）
- **边际（未做）**：absorb-picker rescan / clue-battery hoist（small）；gh#225 blocked；#64 是 UX 非 perf
- **母票**：#219（战役总账，保持打开）
