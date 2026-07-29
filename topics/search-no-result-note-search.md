# 【search】搜索系统现在都反馈 no result，主要搜 note

## Background

- Calendar 搜索当前只覆盖 `Event` 本体字段。
- 用户主要搜索的是 log note / timeline note，现有实现无法命中。

## Discussion Summary

- 搜索范围扩展到事件字段和 occurrence 级日志内容。
- 结果列表继续按 `event card` 聚合，不改成“每个 occurrence 一条”。
- 点击卡片默认打开事件本体详情。
- 卡内需要支持跳回 calendar，并能针对具体 occurrence 打开 log。
- 兼容历史数据，旧的 feedback self note / logs 也纳入搜索。

## Decisions

- 搜索覆盖 `title / note / location / tag / type / log summary / log note / timeline note`。
- 同一 event 多个 occurrence 命中时聚合到一张卡内。
- 卡内展示多个命中的 occurrence 日期与摘要。
- occurrence 行支持跳到 log，也支持跳回 calendar。
- 事件卡长按提供跳回 calendar 的上下文入口，默认跳最近命中的 occurrence。

## In Scope

- 重构 Calendar 搜索结果模型与匹配逻辑。
- 扩展搜索页 UI，展示 occurrence 级命中摘要。
- 增加 calendar 跳转入口与相关测试。

## Out of Scope

- 全文索引、模糊匹配、搜索高亮。
- 重新设计搜索入口或全局导航结构。

## Execution Notes

- Added an aggregated search model in `CalendarSearchView` that searches:
  - `calendarEvents`
  - `calendarEventLogRecords`
  - legacy `calendarEventFeedbackRecords`
- Search results now group by `event`, keep multiple matched occurrences on one card, and sort purely by time — newest first across match kinds (changed on fix/search-sort-and-back-nav; originally occurrence hits ranked ahead of event-only hits).
- Card tap opens event detail; occurrence rows open the log tab for that occurrence.
- Added calendar jump handling in `CalendarPageView` to focus the matched occurrence and leave month mode for `threeDay` when needed.
- Verified with:
  - generic iOS build via `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`
  - 5 targeted search tests, all passing:
    - `testSearchResultsIncludeEventFieldsAndOccurrenceLogMatches`
    - `testSearchResultsAggregateMultipleRecurringOccurrencesIntoSingleCard`
    - `testSearchResultsSortByTimeNewestFirstAcrossMatchKinds`
    - `testSearchResultsIgnoreOrphanLogRecords`
    - `testSearchResultsIncludeLegacyFeedbackNotes`
- Note: the full `CalendarDragLogicTests` suite still has unrelated pre-existing failures/crashes outside this topic.

## Impact on Understanding

- Calendar 搜索不再只是事件字段过滤，而是事件与 occurrence 日志的聚合搜索入口。
- 搜索结果已经承担“打开事件详情 / 打开 occurrence log / 跳回 calendar 聚焦”三种导航职责。
