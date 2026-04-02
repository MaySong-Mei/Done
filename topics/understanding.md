# Project Understanding

## Product

- 当前 backlog 已按 P0-P5 分层，最紧急的问题集中在 calendar 交互、横屏体验、搜索结果和事件创建流程。
- Calendar 搜索现在需要同时支持事件字段检索和 occurrence 级日志/笔记检索。
- Calendar drag-create 落在 boundary extension 相邻天时，保存后不应该强制切换当前视口。

## Architecture

- Calendar 搜索基于 `calendarEvents`、`calendarEventLogRecords`，并兼容 legacy `calendarEventFeedbackRecords`，在 UI 层聚合成按 `event` 分组的结果卡。
- Calendar `PendingEventCreation` 现在携带 post-save navigation policy，用来区分“创建成功后聚焦新事件”与“保留原始 anchor 视口”。

## Current Decisions

- Topic workflow initialized under `topics/`.
- Topic backlog is maintained in `topics/topic.md` and grouped by P0-P5 priority.
- Search results remain `event card` based instead of per-occurrence rows.
- Search cards can open event detail, open the matched occurrence log, or jump the calendar timeline to the matched occurrence.
- Extended drag-create 如果整个事件完整落在相邻 extension day，保存后留在原始当前视口，不自动 jump 到新日期。

## Open Questions

- Which remaining P0 topic should be discussed next?
