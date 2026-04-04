# Project Understanding

## Product

- 当前 backlog 已按 P0-P5 分层；活跃 P0 已进一步收敛到 timeline small-event drag / resize 与最小时长逻辑，横屏主题/排版、事件表单打开性能和 type 模板拖拽流畅度问题已于 2026-04-04 关闭。
- 横屏 `landscape focus mode` 激活时，app 只有在“横屏专注时保持常亮”设置开启时才保持屏幕常亮；退出该模式、关闭任一相关设置、停留在 splash、或 scene 不再 active 时，立即恢复系统自动锁屏。
- Calendar 搜索现在需要同时支持事件字段检索和 occurrence 级日志/笔记检索。
- Calendar drag-create 落在 boundary extension 相邻天时，保存后不应该强制切换当前视口。
- 普通 calendar 创建现在默认走表单；AI 不再作为独立默认创建模式，而是在保存后补全 type。
- `AI type suggestions` 现在只由设置控制，不再在 Header 或 type 区里暴露单独的 `Auto` tag。
- 设置开启时，创建表单会在输入过程中优先利用已有 calendar events 的历史经验做 autocomplete 风格的即时预选，title 还没输完也可以切 type；保存后才允许 LLM 在现有 type 库内兜底补全。

## Architecture

- `DoneApp` 现在在 app 层统一派生 `shouldDisableIdleTimer`，并通过 `UIApplication.shared.isIdleTimerDisabled` 管理横屏 focus mode 的常亮行为；该派生同时受 `landscapeFocusMode` 与 `landscapeFocusKeepAwake` 两个设置控制。
- Calendar 搜索基于 `calendarEvents`、`calendarEventLogRecords`，并兼容 legacy `calendarEventFeedbackRecords`，在 UI 层聚合成按 `event` 分组的结果卡。
- Calendar `PendingEventCreation` 现在携带 post-save navigation policy，用来区分“创建成功后聚焦新事件”与“保留原始 anchor 视口”。
- `CalendarEventFormView` 现在把 `didExplicitlySelectType` 带到 `CalendarEventFormData`，供保存后的 inference 决定是否运行。
- 新增 `CalendarEventTypeInferenceService`，输入期和保存后都会先看历史 calendar events 是否已经形成稳定 type 经验，再退回本地关键词匹配，并只安全回写 `type + suggested log template`。
- `AgenticCalendarIntakeService` 的 type suggestion / autofill 现在都被约束到现有 type 模板库，自动流程不再引入库外 type。
- legacy `CalendarAgenticCreateCoordinator` 的异步 autofill 已收窄为安全回写，不再覆盖 `timeRanges` 或其他核心表单字段。
- `CalendarEventFormView` 的 type 模板行现在使用表单内直接拖拽重排，而不是系统 drag/drop；自动 type 选择命中后会把对应 chip 横向滚动到可见区域，拖拽贴近左右边缘时会连续 auto-scroll 以支持跨屏重排。

## Current Decisions

- Topic workflow initialized under `topics/`.
- Topic backlog is maintained in `topics/topic.md` and grouped by P0-P5 priority.
- 屏幕常亮策略只绑定到当前已存在的 `landscapeFocusMode` 体验，不扩展为所有横屏页面或所有 calendar 页面通用策略；并且该策略有独立用户开关，不与横屏专注模式本身绑定。
- Search results remain `event card` based instead of per-occurrence rows.
- Search cards can open event detail, open the matched occurrence log, or jump the calendar timeline to the matched occurrence.
- Extended drag-create 如果整个事件完整落在相邻 extension day，保存后留在原始当前视口，不自动 jump 到新日期。
- `calendarAgenticCreateEnabled` 当前的产品语义是设置页中的 “AI type suggestions after save”；Header 不再承载这个开关。
- `【performance】点击事件弹出表单速度很慢`、`【bug】横屏模式的黑白切换和系统不一致`、`【bug】横屏模式排版有显示 bug` 已于 2026-04-04 作为历史 backlog 项关闭；本轮没有新增代码变更。
- 保留 event form 内的 type 模板拖拽重排交互，但实现改为表单内直接拖拽跟手；当自动 type 选择改变 `selectedTypeTitle` 时，type 行会主动滚动到该 chip，拖到横向边缘时则继续自动滚动。

## Open Questions

- Which remaining timeline P0 should be discussed next: `small event drag logic` or `30min minimum bug`?
