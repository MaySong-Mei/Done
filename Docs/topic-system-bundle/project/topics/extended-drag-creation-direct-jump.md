# 【calendar】extended drag creation 会导致结束 extension 直接跳转

## Background

- Calendar 支持在 timeline boundary extension 区域里继续 drag creation。
- 当前保存创建结果后，如果事件完整落在 extension 对应的相邻天，calendar 会直接切到那个日期。

## Discussion Summary

- 问题发生在保存创建表单之后，不是在松手当下。
- 只修复 `extended drag creation` 保存后的错误跳转，不改 creation 手势本身。
- 如果事件完整落在 extension 的相邻天，保存后应留在原始当前视口。
- 普通创建成功后的聚焦行为保持不变。

## Decisions

- 为 drag-create 的 pending context 增加保存后导航策略。
- `dragCreate + 整个事件完整落在 extension 相邻天` 时，保存后不自动切日。
- 其他创建路径继续沿用现有“创建后聚焦到新事件”的行为。
- 保持当前视口时，不额外聚焦这个新事件，避免通过 focus 间接再次触发跳转。

## In Scope

- 调整 pending create 上下文和创建完成后的导航逻辑。
- 为 extension 完整落在相邻天的场景增加回归测试。

## Out of Scope

- 重做 boundary extension 视觉逻辑。
- 改变 drag creation 松手后的表单弹出行为。
- 修改普通 quick add / 非 extension create 的 post-save 导航。

## Execution Notes

- Added `PendingEventCreationCompletionNavigation` to the drag-create pending context so save-time routing can distinguish normal creation from extension-only creation.
- `handleCreateEvent` now marks drag-create results that land fully on the previous/next extension day as `stayOnAnchorVisibleDate`.
- Create-sheet completion now passes the original pending context into `handleCreatedEvent`, which skips `selectedDayOffset` changes and event focus when the completion policy is `stayOnAnchorVisibleDate`.
- Verified with:
  - generic iOS build via `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`
  - focused simulator tests, all passing:
    - `testPendingCreationCompletionNavigationFocusesNormalDragCreate`
    - `testPendingCreationCompletionNavigationStaysOnAnchorForPreviousDayExtensionRange`
    - `testPendingCreationCompletionNavigationStaysOnAnchorForNextDayExtensionRange`
    - `testPendingCreationCompletionNavigationIgnoresQuickAddForAdjacentDayRange`

## Impact on Understanding

- Calendar drag-create 需要区分“创建成功”与“创建成功后是否应该切换当前视口”。
