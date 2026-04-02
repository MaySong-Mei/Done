# Project Understanding

## Product

- 当前 backlog 已按 P0-P5 分层，最紧急的问题集中在 calendar 交互、横屏体验、搜索结果和事件创建流程。
- Calendar 搜索现在需要同时支持事件字段检索和 occurrence 级日志/笔记检索。

## Architecture

- Calendar 搜索基于 `calendarEvents`、`calendarEventLogRecords`，并兼容 legacy `calendarEventFeedbackRecords`，在 UI 层聚合成按 `event` 分组的结果卡。

## Current Decisions

- Topic workflow initialized under `topics/`.
- Topic backlog is maintained in `topics/topic.md` and grouped by P0-P5 priority.
- Search results remain `event card` based instead of per-occurrence rows.
- Search cards can open event detail, open the matched occurrence log, or jump the calendar timeline to the matched occurrence.

## Open Questions

- Which remaining P0 topic should be discussed next?
