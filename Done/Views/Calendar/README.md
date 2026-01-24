# Calendar 架构与运作机制

## 概览
Calendar 模块采用“状态机 + 组合器 + 纯视图”的分层结构：
- **状态机**只负责状态转移（滚动阈值、门闩、模式切换）。
- **组合器**把状态映射为“应该渲染什么/如何呈现”。
- **视图层**只做输入采集与渲染绑定，不承载复杂业务规则。

## 目录结构（关键文件）
- `CalendarView.swift`：入口包装，稳定的 tab 接口。
- `CalendarPageView.swift`：页面主控，采集输入并绑定状态与组合结果。
- `CalendarPageStateMachine.swift`：滚动交互的纯状态转移。
- `CalendarPageComposer.swift`：把状态转为具体 UI 组合与展示参数。
- `CalendarPageTypes.swift`：页面状态与枚举定义。
- `CalendarPageMetrics.swift`：布局参数与阈值常量。
- `CalendarLayout.swift`：事件过滤与布局计算。
- `Components/*`：Header/Timeline/Glass 组件实现。

## 运作机制（从入口到渲染）
1) `CalendarView` 进入 `CalendarPageView`。
2) `CalendarPageView` 监听 `scrollY`（`onScrollGeometryChange`）。
3) 滚动输入交给 `CalendarPageStateMachine.transition(...)` 得到下一状态（是否需要动画）。
4) `CalendarPageComposer.compose(...)` 产出 `CalendarPageComposition`：
   - header 模式、展示参数（height/opacity/scale/topInset）
   - timeline 模式、range、rebuild key、top padding
5) 视图层用 composition 渲染：
   - Header -> `CalendarHeaderView`
   - Timeline -> `TimelineContainerView` + `TimelineHeaderBar`
   - Mask -> `TimelineMaskView`

## 交互规则摘要
- **下拉切换模式**：顶部下拉超过阈值，切换 `pageMode`（preview/edit）。
- **隐藏 header**：滚动超过阈值将 `headerVisibility` 置为 hidden。
- **门闩（pullToggleReady）**：必须回到顶部才能再次触发切换。

## 代码标准（本模块约定）
- **分层原则**
  - 规则只在 `StateMachine/Composer`；View 不写复杂逻辑。
  - `StateMachine` 纯逻辑、无 SwiftUI 依赖；`Composer` 纯映射、无副作用。
- **命名与职责**
  - `StateMachine` 仅处理“状态怎么变”。
  - `Composer` 仅处理“状态变了后怎么拼 UI”。
- **动画**
  - 是否动画由 `StateMachine` 的输出（`shouldAnimate`）决定。
  - View 只根据 `shouldAnimate` 包裹 `withAnimation`。
- **文档注释**
  - 统一格式：`/// 功能：...`
  - 只写“职责/目的”，不写实现细节。
- **依赖方向**
  - View -> Composer/StateMachine/Types/Metrics
  - 组件层不依赖 PageView（避免环形依赖）

## 维护建议
- 新增交互优先扩展 `StateMachine`（状态转移）与 `Composer`（映射逻辑）。
- 如果状态变复杂，优先增加 State/Transition 类型而不是在 View 里堆 `if/else`。
- 任何跨组件的展示决策，都应进入 `Composer`。
