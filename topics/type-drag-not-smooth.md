# 【bug】type 拖拽不丝滑

## Background

- `CalendarEventFormView` 的 type 模板目前以横向 chip 行展示，既支持点选，也支持拖拽重排。
- 旧实现依赖系统 `.onDrag` / `.onDrop` 和 `dropEntered` 触发重排，在横向 `ScrollView` 里会有明显的 target-jump 感，不够跟手。
- 同一个表单在自动 type 选择命中后，也不会把被选中的 type chip 滚动到可见区域，用户容易错过自动切换结果。

## Discussion Summary

- 保留现有交互语义，不移除 type 拖拽重排，也不把重排迁到单独的管理页。
- 这次修复重点是“流畅度”，不是改产品模型。
- 自动 type 选择命中后，需要顺便把对应 chip 聚焦到可见区域，避免选择结果发生了但用户看不到。
- 第一轮 direct-drag 改造后，补充确认 drag 到横向列表边缘时还需要 continuous auto-scroll；否则只能在当前可见范围内重排，交互仍然不完整。

## Decisions

- type chip 重排继续留在 `CalendarEventFormView` 内。
- 重排改为表单内直接拖拽跟手，而不是继续依赖系统 drag/drop 的 drop target 进入事件。
- 自动 type 选择改变 `selectedTypeTitle` 时，横向 type 行应滚动到对应 chip，并优先使用居中可见的滚动目标。
- 手动点选 type 不额外强制滚动；自动选择才触发这个聚焦行为。
- 当拖拽中的 chip 接近横向列表左右边缘时，type 行需要连续自动滚动，允许用户不松手就跨出当前可见区域继续重排。

## In Scope

- 重写 `CalendarEventFormView` 的 type chip 重排交互。
- 为重排阈值和自动聚焦决策抽出可测试的纯 helper。
- 为拖拽中的 type chip 补齐左右边缘 auto-scroll。
- 更新 topic backlog / understanding / per-topic summary。

## Out of Scope

- 重做 event form 的整体视觉样式。
- 移除 type 拖拽能力或新增独立模板管理页面。
- 修改 timeline event drag / resize 相关逻辑。

## Execution Notes

- `CalendarEventFormView` 已移除旧的 `.onDrag` / `.onDrop` + `TemplateDropDelegate` 路径，改为在 type chip 行内使用 direct long-press + drag 重排。
- 新增 `CalendarTypeChipReorderRequest` 与 `calendarTypeChipReorderRequest(...)`，按 chip frame midpoint 决定重排时机；拖拽中的 chip 通过本地 overlay 跟手显示，其余 chip 用 spring 动画重排。
- type chip 行现在通过 `ScrollViewReader` + stable chip id 支持聚焦；`scheduleAutomaticTypeSelection(...)` 命中新的自动类型后，会通过 `calendarTypeChipAutoFocusTarget(...)` 请求横向滚动到该 chip。
- follow-up 补齐了 edge auto-scroll：type chip 行现在会解析底层 `UIScrollView`，复用既有 `calendarAutoScrollVelocity(...)` / `calendarHorizontalAutoScrollDelta(...)` 速度模型，通过 display-link 在拖拽贴近左右边缘时持续滚动，同时继续用 live chip frames 判定跨屏重排。
- 已新增 7 个 focused regression tests 到 `DoneTests/CalendarDragLogicTests.swift`，覆盖向左/向右重排、未越过 midpoint 不移动、自动聚焦 target 的变化/不变化规则，以及 auto-scroll step 的推进/边界钳制。
- 验证：
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Done.xcodeproj -scheme Done -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4'`
  仅执行 7 个 type-chip helper 用例，结果 7/7 通过。

## Impact on Understanding

- type 模板拖拽问题确认发生在 event form 的 type chip 行，而不是 timeline event drag surface。
- 自动 type 选择现在不仅会更新选中值，也会把对应 chip 带到用户当前可见范围内。
- type chip 的拖拽完整体验还依赖边缘自动滚动；direct-drag 跟手和 edge auto-scroll 需要一起存在，用户才能连续跨出可见区域调整顺序。
