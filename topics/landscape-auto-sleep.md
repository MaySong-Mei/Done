# 【calendar】横屏状态下会自动熄屏

## Background

- 当前 app 在横屏时会进入 `landscape focus mode` 叠层，但没有任何 `idle timer` 控制。
- 用户在横屏专注查看日程时，系统会按默认自动锁屏，打断使用流程。

## Discussion Summary

- 该问题按 P0 处理，优先于更大范围的横屏体验重构。
- 这次只修复现有 `landscape focus mode` 的自动熄屏问题，不把“常亮”扩展为所有横屏页面或所有 calendar 页面通用策略。
- `idle timer` 控制应放在 app 层，而不是 `OrientationManager` 内部；前者是产品策略，后者只负责方向状态。

## Decisions

- 仅在 `landscape focus mode` 实际激活时禁用系统自动锁屏。
- 新增独立设置项控制该行为，用户可以保留横屏专注模式，但单独关闭“横屏专注时保持常亮”。
- 以下任一条件不满足时，立即恢复系统默认自动锁屏：
  `isLandscape == false`、`landscapeFocusModeEnabled == false`、`landscapeFocusKeepAwakeEnabled == false`、`showSplash == true`、scene 不处于 active。
- scene 进入 inactive / background 时，宁可保守地恢复自动锁屏，也不延续常亮状态。

## In Scope

- 新增 app 级派生策略，统一决定何时设置 `UIApplication.shared.isIdleTimerDisabled`。
- 将该策略接入 `DoneApp` 中现有的横屏 focus mode 入口和 scene 生命周期。
- 为派生策略补充可单测的纯函数覆盖。

## Out of Scope

- 所有横屏页面统一常亮。
- 新增用户设置项。
- 调整横屏 focus mode 的布局、配色或进入/退出逻辑。

## Execution Notes

- 新增 `Done/AppIdleTimerPolicy.swift`，抽出 `doneShouldDisableIdleTimer(...)` 纯函数和 `doneApplyIdleTimerPolicy(...)` 应用函数。
- 实际实现收敛到 `DoneApp.swift`，在同文件中新增 `doneShouldDisableIdleTimer(...)` 纯函数与 `doneApplyIdleTimerPolicy(...)`，避免当前 Xcode 工程遗漏新 source file 的 target membership。
- 在 `DoneApp` 里通过 `scenePhase + orientationManager.isLandscape + landscapeFocusModeEnabled + landscapeFocusKeepAwakeEnabled + showSplash` 派生 `shouldDisableIdleTimer`，并在 `onAppear`、值变化和 `onDisappear` 时同步到系统 `idle timer`。
- 在设置页 `Recording & Workflow` 中新增“横屏专注时保持常亮”开关，并更新首页摘要与中英文说明文案。
- 在现有 `DoneTests/CalendarDragLogicTests.swift` 中新增 5 个针对 idle-timer policy 的单测，覆盖 active landscape focus mode、splash、focus mode off、keep-awake off、inactive/background 等条件。
- 验证：
  已通过 `xcodebuild test -project Done.xcodeproj -scheme Done -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4'` 的定向测试，只执行 5 个 idle-timer policy 用例，结果 5/5 通过。
  额外说明：运行整个 `DoneTests/CalendarDragLogicTests` 类时发现该类存在既有失败项，与本次改动无关，因此最终使用更窄的定向测试作为本 topic 的验收依据。

## Impact on Understanding

- 横屏 focus mode 现在不仅影响 UI 展示，还承载“保持屏幕常亮”的 app 级行为。
- 该行为明确受 `landscapeFocusMode`、新的 `landscapeFocusKeepAwake` 设置以及 scene active 状态约束，避免扩散为更宽泛的全局策略。
