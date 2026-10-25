# Issue Triage — `Done`

本仓库 issue 的分类参考,便于对着排期。**注意**:`gh issue list` 的 `updatedAt` 被 2026-08-04 的一次批量导入统一刷过,不是纯净 stale 信号——本表分类是对照代码/战役/记忆核实的,不看 updatedAt。

**开放:95 个**(截至 2026-09-13)。

## 最近关闭(2026-09-13 整理 pass)

| # | 处置 |
|---|---|
| #1 | 已完成:bundle id 已是 `wordless.shiqiliuyifanmei.app` |
| #93 | moot:spec-07 imperative day-layer 已整体回滚 |
| #52 | 并入 #43(dayRange 无界增长的用户可感症状) |
| #118 | keep 裁决:todo-stack 已 shipping,4 周窗口过、无 kill 触发 |
| #95 | stale:spec-07 Phase 1 基座已废;±12h wall 归 #57/#14 |
| #84 | 关:render refactor watch 期已过、跨午夜已被 Lean 覆盖 |
| #2 | stale:早期产品设想,被现 focus/event 模型取代 |
| #3 | stale:拖事件 vs 下滑冲突,手势系统此后重写多次 |

> 死路已钉:**#43** '窗口化 ForEach(dayRange)' = 已 revert(552adb0);真解在 UIKit 迁移(#57/#14)或单独切 O(dayRange) 成本。

## 开放 issue 分类

### ⚡ 性能战役(#219 母票)
_一次用户动作应产生 O(相关) 而非 O(全表) 的工作。活跃。#164/#163 在未合并分支 fix/detail-periodic-isolation 上。_

- **#219** 母票 perf(app): 一次用户动作应该产生多少工作 —— 资源浪费战役(审计定案 / 架构根因 / 已落地六合并 / Fix Watch 常驻判据)
- **#37** Multi-second lag on first interaction (composer open / drag-create / input tap)  `bug`
- **#148** perf(agent): 对话仓库首帧主线程解码 351KB + 每轮聊天主线程同步 fsync
- **#181** spike(calendar): inspect sustained drag / autoscroll render cost before choosing an optimization
- **#201** perf(calendar): effort tap-to-feedback still feels delayed after #162 drag fix
- **#43** Calendar may stay heavier after paging far into history
- **#164** perf(calendar): event-detail edge back-swipe drops frames from monolithic periodic timeline subtree
- **#163** perf(calendar): Add Note typing/focus fights keyboard and invalidates detail timeline
- **#33** perf(sync-inspect): cache month grid + summaries off body re-renders
- **#35** perf/UX(sync): three deferred items from full-backup architectural sign-off
- **#195** spike(perf): audit high-frequency detail interactions for parent invalidation and write amplification
- **#226** bug(domino): heartbeat advances while the calendarEvents slot is frozen — the catch-up delta is silently lost after heal
- **#64** bug(calendar): absorption pulse skips second consecutive absorb — scope 改为 detail 页快速点按路径

### 🌙 跨午夜 / 日历核心(Lean 形式化中)
_app 历史最高 bug 密度面;#224 season-two 正在上守恒定理。活跃。_

- **#53** Cross-midnight event live drag + axis time markers on CALayer renderer (3 sub-bugs)  `bug`
- **#54** 【bug】Cross-midnight events mis-render in Day view + drag-resize does not follow the finger
- **#55** Extended view open transition needs animated scroll compensation
- **#10** Re-key calendar occurrence cache by absolute Date instead of relative day-offset  `bug`
- **#11** Polish: midnight handler caveats from code review  `bug`
- **#228** report clue battery: two DST-frame window leftovers (R2 seconds-vs-wallclock baseline, R8 emergence reads the future)
- **#151** bug(sync): recurrence_instance_day_key 缺 stale 值防护 — 混合版本 rollout 期间实例会钉在错误的日子  `bug`

### 🧊 CALayer / 时间轴架构(#103 冻结区,故意 park)
_spec-07 曾 66-commit 回滚;真解=UIKit 迁移(#14)。非 stale,长期债。_

- **#14** tech-debt(calendar): plan UIKit + CALayer rewrite of the timeline / calendar surfaces
- **#57** Timeline: SwiftUI ScrollView can't atomically co-commit contentSize + scrollOffset
- **#61** perf(calendar): move boundaryDayHints to CALayer (calendar-surface CALayer-first)
- **#62** perf(calendar): replace extensionFadeMask SwiftUI VStack with CAGradientLayer mask
- **#63** feat(calendar): port in-canvas interrupt-recording visualization to CALayer
- **#66** tech-debt(calendar): post-legacy cleanup bucket (dead EventBlock plumbing, TimelineStyle, calayer* naming, stale citations, time formatter dup)
- **#69** refactor(calendar): split CalendarDayLayerView.swift (6068 LOC → ~5 sub-system files)
- **#71** perf(calendar): port miniDayTimelineVisual (event detail mini-day) to CALayer host
- **#72** perf(calendar): port FocusEventFlowView event rendering to CALayer host
- **#41** Accessibility / VoiceOver support for the CALayer timeline (future plan)
- **#42** Cross-column drag preview (target-day neighbors make way) — CALayer timeline
- **#176** bug(calendar): pinch render window can desync from horizontal viewport and blank day columns
- **#79** polish(calendar): smooth pinch density crossfade — half-hour grid line + label transition

### 🔁 Recurring
_母 #5;#105 内测反馈群。_

- **#5** Recurring events: audit and overhaul  `bug`
- **#105** Recurring 循环事件存在大量 bug  `bug,beta-feedback`
- **#150** chore(recurring): gh#124 僵尸系列 — 分类报告已上线，清理方案待真机证据
- **#153** test(recurring): 钉住 ends-on-start-day witness 臂 — 它静默失效会误判合法系列
- **#154** bug(recurring): 被封顶的旧系列保留拆分前的 afterCount，重开规则编辑器会预填旧总数  `bug`
- **#155** polish(recurring): 名义日身份的收尾簇 — 中断关系日 key / 列表行时间 / 扫描 trail 刷屏 / wire 降级无日志  `low priority`
- **#190** proposal(recurring): 多区间 × recurrence 是半支持状态 — 展开只渲 primary,例外物化的尾部策略需要产品拍板
- **#198** proposal(recurring): recurring 创建移入专属管理面 — 日历操作统一单事件语义

### 🧪 内测反馈
_真人反馈,产品级。_

- **#104** 新用户需要 walk-through 引导 (onboarding guide)  `documentation,enhancement,beta-feedback`
- **#106** Wanna（想做）与待办功能需要可开关设置  `enhancement,beta-feedback`
- **#107** 旧机型事件内容显示错误（iPhone 13 等早期型号）  `bug,beta-feedback`
- **#108** 汉化不彻底，存在未翻译的英文文案  `enhancement,beta-feedback`
- **#109** Haptic 开启需要引导（测试用户找了很久才发现）  `documentation,enhancement,beta-feedback`
- **#113** 向前一天滑动间歇性失效（iPhone 13）  `bug,beta-feedback`
- **#115** 内测反馈: 缺少「激活 + 完成反馈」闭环(习惯/提醒开不了 · 不知道能干嘛)  `enhancement,beta-feedback`

### ☁️ Sync / 存储 / 备份
_guarded sync(#24)是真隐患;#16 CloudKit 故意 deferred。_

- **#16** backup(L1): CloudKit image sync as Apple-native fast-path (deferred)
- **#24** 【sync】智能备份 / guarded sync，防止旧本地状态污染云端
- **#29** design(sync): configurable image size limit + warn user on large uploads
- **#147** feat(storage): 操作 redo journal — 独立用户操作的 FIFO/因果重放（#145-B）
- **#149** chore(storage): merge-gate 低优先观察簇 — 通知不对称 / reset 后照片滞留 / restore 撞聊天轮
- **#6** AgentRuntime doesn't re-publish on eventTypeTemplateStore changes  `bug`

### 🎯 Focus mode(工作流按 #180 暂停)
_重力开门唯一出口是 ship-blocker(#170)。_

- **#170** a11y(focus): Focus mode 只有一个用重力开的门 —— 无障碍用户与无法改变设备姿态的人会被锁在里面
- **#171** fix(focus): 闸门关闭时滑动退出的意图被丢弃,且一次虚假转屏能撤销已提交的关闭
- **#175** polish(focus): 交接时把跟踪写入锚到「surface 当前所在」而非手指位移原点(UIScrollView 抓减速滚动的约定)
- **#179** bug(focus): 飞行途中任何无意接触都会静默撤销已提交的退出(8/8,先于 gh#175 存在)
- **#180** chore(product): pause Focus Mode workstream and refocus on core Calendar / Todo

### 🗂 Todo / drawer / stack
_todo-stack 已常驻(#118 keep 收口)。_

- **#132** feat(calendar): 多槽草稿救援 — 单槽下新会话第一次击键就吃掉上一份未消费的 rescue  `enhancement`
- **#134** feat(calendar): 拖拽创建即刻落成占位事件（而不是等 Done 才提交）  `enhancement`
- **#139** fix(todo): 「已删除」列表不覆盖日历事件 — UI 承诺了一个不存在的回收站  `bug,low priority`
- **#140** feat(calendar): 日历事件软删除 / 撤销 — 目前删除完全不可逆  `enhancement`
- **#160** polish(todo-stack): 已排期 todo 的向下拖拽完全没有自动滚动 — 底部边缘整条让给了「放回 stack」
- **#168** chore(todo): fully retire HORIZON / Domino system now that Todo stack owns unscheduled intent
- **#200** polish(todo-drawer): gh#128 收口遗留三项 — Dynamic Type 字体、空栈面板跳变、re-grab 跳变
- **#205** test(calendar): interrupt-children-never-recurrence-exceptions 只是约定,五处 raw 读依赖它 —— 要么类型强制要么见证测试
- **#210** a11y(app): Dynamic Type 全 app 欠账 —— 371 处裸 .system(size:) 不随字号缩放(#200 只修了抽屉家族)

### 📅 日历 UX / 拖拽 / composer(bug + polish)

- **#25** bug(calendar): reverse cross-day drag-create preview fails in 3-day/week  `bug`
- **#82** bug(calendar): cross-day / same-day rebounce animator intermittently fails to fire
- **#136** fix(calendar): 重复事件 / 无时间段事件的编辑完全没有草稿保护  `bug`
- **#137** feat(calendar): 编辑 sheet 下滑误关丢失全部改动 — edit 侧需要自己的恢复确认面  `enhancement`
- **#166** polish(calendar): soften the hard seam between the left time axis and scrolling timeline
- **#167** feat(calendar): configurable interaction time granularity (10 / 15 min) while preserving exact timestamps
- **#169** polish(calendar): reduce event corner radius in Week View
- **#173** fix(calendar): give equal-time parallel peers stable semantic left/right ordering
- **#183** bug(calendar): detail 页 route 切换留下陈旧 composer 状态 — 尾巴丢失,且跨 occurrence 污染只靠一句无标注的守卫挡着
- **#218** design(calendar): 完整日志编辑 sheet 的保存仍是整集合覆盖 —— gh#216 同类,但需先拍语义(整份草稿 vs 字段级合并)
- **#203** design(agent): updateTodo 字段覆写是无确认不可逆的数据丢失通道 —— 并入 Confirm/Cancel pending-action 切片

### 🌊 随动(fluid interface)polish
_缺'松手继承速度';样板 ReminderPanelView。_

- **#130** polish(随动): 内容滑动缺速度投影（Analysis 周期 pager · Wanna 行滑动）  `enhancement,low priority`
- **#156** polish(随动): 时间线捏合锚点应为双指中点而非视口中心  `enhancement,low priority`
- **#157** polish(随动): Interrupt composer 关闭无过渡，出入不对称  `enhancement,low priority`
- **#158** polish(随动): 全屏图片查看器缺下滑关闭手势  `enhancement,low priority`
- **#159** polish(随动): Reminder 面板「开」不跟手，与「关」物理不对称（需先定产品方向）  `enhancement,question,low priority`

### 🔬 Spike(设计调查,故意开着)
_决策/调查类,非 bug;待排优先级。_

- **#165** proposal(calendar): decouple effort from colorDepth and use information density as the visual hierarchy
- **#182** spike(calendar): inspect type inference evidence weighting and calibration before redesign
- **#191** spike(calendar): inspect external calendar invitations → optional Done actualization
- **#192** spike(calendar): inspect visual semantics for future/planned vs elapsed/actualized events
- **#193** spike(widget): rethink home-screen widgets around lived-time recording / actualization
- **#194** spike(watch): revisit Apple Watch as a lived-time capture / actualization surface
- **#196** spike(motion): define professional lifecycle animations for event creation, deletion, and structural changes
- **#197** spike(devtools): design an in-app Spike Harness for dogfood tests, structured logs, and remote-readable experiments
- **#199** spike(devtools): Spike Harness 远程 arming — 白名单命令面讨论(从 #197 拆出)

### 📎 其它 / meta

- **#8** Restore project README  `documentation`
- **#39** Feature: Bind people or friend groups to events

