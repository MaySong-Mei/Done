# Release Check — 0.5.0

对着走的发布冒烟清单。每版更新 build 号与「本版含/不含」，然后按 ②③ 逐条冒烟。

**当前可发版本：0.5.0 (build 4)** — king `45152d6`（origin 同步）。

---

## ⚠️ 0 — 安全前置（build 3 已污染，必读）

- **build 3（已 archive/上传）带泄露的 service_role key** — 它的 bump commit `4ee1a68`(2026-09-15 17:12) 早于安全修复 `3eb5c13`/`2e93cab`(2026-09-16 07:44)，archive 出的包在修复之前。
- **build 4 (`45152d6`) 是第一个带 gh#232 修复的包**（publishable key + env-based done-mcp secrets）。
- **顺序硬要求：先发 build 4、TestFlight 生效后，再吊销 legacy service_role key。** 反了会把仍在跑 build 3 的客户端打断。详见 memory `project_service_role_leak_incident.md`。

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

各分支合并前需 rebase 到当时 king + 合并树重跑全套。

---

## 附：perf 战役记分牌（截至 build 4）

- **已合入 king（7）**：#37 / #164 / #163 / #148 / #195 / currentEvent(#213) / Analysis(#213) / interrupt-walk(#213)
- **held 待装机（3）**：#181 / #229 / #231
- **死路**：#43/#52（越翻越卡；真解 = UIKit 时间线迁移 #57/#14，架构级另立项，撞 #103 冻结）
- **边际（未做）**：absorb-picker rescan / clue-battery hoist（small）；gh#225 blocked；#64 是 UX 非 perf
- **母票**：#219（战役总账，保持打开）
