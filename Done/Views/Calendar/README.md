# Calendar 模块架构说明（详细版）

## 目标与边界
Calendar 模块实现一个可切换预览/编辑模式的日历时间线，核心目标是：
- 交互逻辑可预测、可测试（状态机 + 组合器）。
- 视图保持“无业务逻辑”的渲染层角色。
- 时间线渲染与手势输入解耦，支持多日/多模式扩展。

本模块不负责事件数据持久化与模型定义（依赖 `EventStore`、`Event` 等）。

---

## 架构总览（从入口到渲染）

```
CalendarView
  └─ CalendarPageView
       ├─ CalendarPageStateMachine (状态转移)
       ├─ CalendarPageComposer (UI 组合与参数计算)
       ├─ CalendarPageMetrics (阈值/布局常量)
       ├─ CalendarLayout (事件过滤 + 位置计算)
       └─ Components (Header / Timeline / Gestures / Glass)
```

核心分层：
- **状态机**：只关心状态如何变化（滚动阈值、模式切换门闩）。
- **组合器**：把状态 + 滚动 + metrics 映射成 UI 参数。
- **视图层**：采集输入、绑定状态、渲染结果。

---

## 目录结构与职责

入口与主控：
- `CalendarView.swift`：tab 入口，保持稳定接口。
- `CalendarPageView.swift`：页面主控，绑定状态机与组合器，驱动渲染。

状态与组合：
- `CalendarPageStateMachine.swift`：滚动交互状态转移（纯逻辑）。
- `CalendarPageComposer.swift`：状态 → UI 组合参数（纯映射）。
- `CalendarPageTypes.swift`：PageMode / RangeMode / HeaderVisibility / CalendarPageState。
- `CalendarPageMetrics.swift`：阈值与布局常量集中定义。

数据与布局：
- `CalendarLayout.swift`：事件过滤、时间段位置/高度计算、颜色映射。
- `CalendarViewState.swift`：跨页面共享状态（选中日期、范围模式）。
- `CalendarSubtitleStore.swift`：标题副文案加载。

组件：
- `Components/Header/*`：标题、打字副标题、分页工具区。
- `Components/Timeline/*`：时间线渲染、编辑/预览样式、手势层。
- `Components/GlassCardView.swift`：通用玻璃卡片样式。

---

## 数据与状态流

### 共享状态（跨 Tab/模式）
`CalendarViewState`（`@EnvironmentObject`）：
- `selectedDayOffset`：选中日期相对今天的偏移。
- `rangeMode`：day / threeDay / week。

### 页面私有状态（仅 CalendarPageView）
`CalendarPageView` 的 `@State`：
- `pageState`：`CalendarPageState`（mode/visibility/pullToggleReady）。
- `scrollGeometry`：滚动几何（iOS 17 `onScrollGeometryChange`）。
- `headerSubtitle`：随机副标题。
- `dayRange`：当前缓存范围（默认 `-30...30`，动态扩展）。
- `occurrencesCache`：按 offset 预计算的事件列表。

### 事件数据来源
`EventStore`（`@EnvironmentObject`）作为单一数据源：
- `CalendarPageView` 在 `onChange(of: store.events)` 触发缓存重建。
- 编辑手势直接调用 `store.addWithAutoPlacement` 或 `store.update`。

---

## 交互流程细节

### 1) 滚动驱动的状态机
`CalendarPageView.handleScroll` 调用 `CalendarPageStateMachine.transition`：
- **下拉切换模式**：`scrollY <= -expandPullDistance` 且 `pullToggleReady == true`。
- **header 显隐**：`scrollY >= hideSnapDistance * hideThreshold` 时隐藏。
- **门闩规则**：必须回到顶部 (`scrollY >= 0`) 才能再次触发模式切换。
- **动画控制**：`Transition.shouldAnimate` 决定是否 `withAnimation`。

### 2) 状态映射到 UI
`CalendarPageComposer.compose` 输出 `CalendarPageComposition`：
- `headerMode`：preview → normal，edit → expanded。
- `headerPresentation`：高度/透明度/缩放/安全区 topInset。
- `activeTimelineMode`：preview/edit。
- `timelineRange`：day/threeDay/week。
- `timelineRebuildKey`：范围切换时强制重建（避免 TabView 残留）。
- `timelineTopPadding`：安全区 + headerHeight + spacing。

### 3) Timeline 渲染选择
`TimelineContainerView` 做模式 + 范围分发：
- day + preview → `TimelineView`
- day + edit → `TimelineEditView`
- threeDay/week → `TimelineMultiDayView`

为了避免模式切换跳动，`TimelineContainerView` 保持两个视图并用 opacity + hitTesting 切换。

---

## Timeline 渲染架构

### 单日视图
- `TimelineView`：预览模式，TabView 按天分页。
- `TimelineEditView`：编辑模式，TabView + label bar。
- 共同点：共享 `TimelineDayView` 作为“单日栅格 + 事件块”渲染器。

### 多日视图
- `TimelineMultiDayView`：横向 ScrollView + `LazyHStack`，支持 3/7 日。
- 内部维护滚动恢复与选中 offset 同步（`pendingScrollTarget` + `isRestoringScroll`）。

### 单日渲染核心
- `TimelineDayView` 使用 `CalendarLayout` 计算：
  - `yOffset`：事件相对午夜偏移
  - `eventHeight`：根据 duration 转换为高度（带最小高度）
  - `eventColor`：由 `EventTypeTemplateStore` 映射

---

## 手势与编辑逻辑

手势统一由 `TimelineGestureLayers` 管理，并覆盖在渲染层之上：

### 预览模式
- `TimelinePreviewGestureLayerDay` / `MultiDay`
- 长按命中事件 → `onPreviewEvent` 打开 `TimelineEventPlaceholderView`。

### 编辑模式
- `TimelineEditGestureLayerDay` / `MultiDay`
- 交互类型：
  - **拖拽现有事件**：命中后创建 `TimelinePickupState`。
  - **长按空白区域**：创建 `TimelineDraftState` 新事件。
- 关键规则：
  - 时间吸附：`snapMinutes`（默认 15）。
  - 最短时长：`minDurationMinutes`（默认 15）。
  - 跨天限制：编辑时 clamp 到当日范围。
  - 自动滚动：接近左右边缘时按天推进（`TimelineAutoScrollController`）。

手势数据处理逻辑集中在 `TimelineInteractions`：
- 坐标 → 时间 (`snappedDate`)
- 时间范围归一化 (`normalizedRange`)
- 命中框计算 (`eventFrame`)

---

## 事件缓存与范围扩展

`CalendarPageView` 维护 `dayRange` 与 `occurrencesCache`：
- 初始 `dayRange`: `-30...30`
- 当 `selectedDayOffset` 靠近边界时，扩展 `dayRange`：
  - 距离 < `dayRangeExpansionThreshold` → 向对应方向扩展 `dayRangeExpansionStep`
  - `expandDayRangeToInclude` 保证初始选中值在范围内
- `CalendarLayout.occurrencesByOffset` 用于批量构建缓存

目的：减少每次渲染时的过滤成本，并保证横向分页有足够的预加载缓冲。

---

## Header 架构

`CalendarHeaderView` 负责标题栏 UI：
- 模式切换：`normal` vs `expanded`（与 pageMode 绑定）。
- `TypingSubtitleController` 驱动副标题打字动画（与视图生命周期解耦）。
- expanded 模式下使用 TabView 实现分页工具区。
- 视觉容器使用 `GlassCardView`。

---

## 关键阈值与布局常量

集中定义于 `CalendarPageMetrics`：
- `expandPullDistance`：下拉触发模式切换的阈值。
- `hideSnapDistance` + `hideThreshold`：header 自动隐藏阈值。
- `normalHeaderHeight` / `expandedHeaderHeight`：高度逻辑。
- timeline mask：`EdgeFadeConfig`（顶部/底部渐隐）。

统一通过 `CalendarPageComposer` 访问，避免 magic numbers 分散在 View 层。

---

## iOS 17 滚动行为

`CalendarPageView` 使用：
- `onScrollGeometryChange` 获取 `ScrollGeometry`。
- 自定义 `ScrollTargetBehavior`：`SnapTopRangeScrollBehavior`
  - 在 header 区间内吸附到顶部或隐藏阈值位置，增强“半隐藏”手感。

---

## 可测试点与扩展建议

### 可测试点
- `CalendarPageStateMachine.transition`：纯逻辑，易做单元测试。
- `CalendarPageComposer.compose`：纯映射函数，可 snapshot UI 参数。
- `CalendarLayout`：事件过滤/几何算法可写数据驱动测试。

### 扩展建议
- **新增范围模式**：扩展 `RangeMode`、`TimelineContainerView.Range`，并在 `CalendarPageComposer` 映射。
- **新增交互**：优先扩展 `TimelineGestureConfig` 或 `TimelineInteractions`，不要直接在 View 中堆逻辑。
- **新增 header 样式**：保持 `CalendarHeaderPresentation` 为唯一控制入口。

---

## 依赖与外部约束

依赖：
- `EventStore` / `Event` / `EventTypeTemplateStore`（来自 Models）。
- `UIKitDragGestureView`（外部 UIKit 封装，用于更精细的拖拽）。

约束：
- 视图层不写业务决策，所有阈值统一由 `CalendarPageMetrics` 管理。
- 状态机与组合器保持纯函数特性，避免副作用。
