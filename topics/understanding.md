# Project Understanding

## Product

- 当前 backlog 已按 P0-P5 分层，最紧急的问题集中在 calendar 交互、横屏体验、搜索结果和事件创建流程。
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

## Current Decisions

- Topic workflow initialized under `topics/`.
- Topic backlog is maintained in `topics/topic.md` and grouped by P0-P5 priority.
- 屏幕常亮策略只绑定到当前已存在的 `landscapeFocusMode` 体验，不扩展为所有横屏页面或所有 calendar 页面通用策略；并且该策略有独立用户开关，不与横屏专注模式本身绑定。
- Search results remain `event card` based instead of per-occurrence rows.
- Search cards can open event detail, open the matched occurrence log, or jump the calendar timeline to the matched occurrence.
- Extended drag-create 如果整个事件完整落在相邻 extension day，保存后留在原始当前视口，不自动 jump 到新日期。
- `calendarAgenticCreateEnabled` 当前的产品语义是设置页中的 “AI type suggestions after save”；Header 不再承载这个开关。

## Open Questions

- Which remaining P0 topic should be discussed next after closing landscape auto-sleep?
