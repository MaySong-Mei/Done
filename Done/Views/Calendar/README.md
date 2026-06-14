# Calendar 模块

## 文件结构

```
Calendar/
├── CalendarView.swift           # 入口，注入环境对象
├── CalendarViewState.swift      # 跨页面共享状态 (selectedDayOffset, rangeMode)
├── CalendarPageView.swift       # 主视图，组装所有组件，处理滚动和拖拽
├── CalendarPageState.swift      # 状态管理（类型定义+状态机+组合器+布局常量+数学工具）
├── CalendarLayout.swift         # 事件布局计算（过滤、位置、高度、颜色）
├── CalendarSubtitleStore.swift  # 从 subtitles.txt 加载随机副标题
└── Components/
    ├── GlassCardView.swift                    # 毛玻璃卡片容器
    ├── Header/
    │   └── CalendarHeaderView.swift           # 头部视图（标题+打字动画+按钮+分页）
    └── Timeline/
        ├── TimelineView.swift                 # 时间线（容器+单日分页+多日滚动+日视图+网格）
        ├── TimelineHeaderBar.swift            # 日/三日/周 切换按钮栏
        ├── TimelineMaskView.swift             # 上下边缘渐隐遮罩
        └── Event/
            └── EventBlock.swift               # 事件块（样式+长按拖拽手势）
```

---

## 功能 → 代码对照表

| 功能 | 文件 | 具体代码 |
|------|------|----------|
| **页面入口** | `CalendarView.swift` | `CalendarView` 注入 `CalendarViewState` |
| **主视图** | `CalendarPageView.swift` | `CalendarPageView.body` |
| **edit/preview 模式切换** | `CalendarPageState.swift` | `CalendarPageStateMachine.transition()` 检测下拉距离 |
| **下拉阈值** | `CalendarPageState.swift` | `CalendarPageMetrics.expandPullDistance = 72` |
| **header 显示/隐藏** | `CalendarPageState.swift` | `hideSnapDistance * hideThreshold` 计算临界点 |
| **header 动画参数** | `CalendarPageState.swift` | `CalendarPageComposer.compose()` → `CalendarHeaderPresentation` |
| **header 渲染** | `CalendarHeaderView.swift` | `CalendarHeaderView.body` |
| **打字机效果** | `CalendarHeaderView.swift` | `TypingSubtitleController.start()` 驱动 `TypingSubtitleView` |
| **日/三日/周切换** | `TimelineView.swift` | `TimelineContainerView.daysCount` 根据 `RangeMode` 返回 1/3/7 |
| **单日分页** | `TimelineView.swift` | `TimelinePagerView.singleDayContent()` 用 `TabView` |
| **多日横滑** | `TimelineView.swift` | `TimelinePagerView.multiDayContent()` 用 `ScrollView` + `LazyHStack` |
| **时间网格** | `CalendarDayLayerView.swift` | CALayer 网格层绘制 25 条横线 |
| **事件块** | `EventBlock.swift` | `EventBlock.body` 渲染圆角矩形+文字 |
| **事件位置 (Y)** | `CalendarLayout.swift` | `yOffset(for:on:headerHeight:hourHeight:)` |
| **事件高度** | `CalendarLayout.swift` | `eventHeight(for:on:minimumHeight:hourHeight:)` |
| **事件颜色** | `CalendarLayout.swift` | `eventColor(for:)` 调用 `EventTypeTemplateStore` |
| **事件过滤** | `CalendarLayout.swift` | `occurrencesForDate(_:date:)` 筛选当天事件 |
| **长按拖拽** | `EventBlock.swift` | `LongPressDragGesture` (UIKit 实现) |
| **拖拽更新时间** | `CalendarPageView.swift` | `handleEventDrag()` 计算新时间并调用 `store.update()` |
| **Y → 时间转换** | `CalendarLayout.swift` | `timeFromYOffset()` 带 15 分钟吸附 |
| **滚动吸附** | `CalendarPageView.swift` | `SnapTopRangeScrollBehavior` 实现 `ScrollTargetBehavior` |
| **边缘渐隐** | `TimelineMaskView.swift` | 渐变 mask 从透明到不透明 |
| **毛玻璃卡片** | `GlassCardView.swift` | `.ultraThinMaterial` 背景 |
| **范围切换栏** | `TimelineHeaderBar.swift` | 三个按钮切换 `rangeMode` |
| **选中日期** | `CalendarViewState.swift` | `@Published var selectedDayOffset: Int` |
| **范围模式** | `CalendarViewState.swift` | `@Published var rangeMode: RangeMode` |
| **副标题加载** | `CalendarSubtitleStore.swift` | `randomSubtitle()` 从 txt 文件随机取一行 |
| **数学工具** | `CalendarPageState.swift` | `clamp()` 全局函数 |

---

## 各文件详解

### CalendarPageState.swift (217 行)

集中了所有状态相关的代码：

```swift
// ===== 数学工具 =====
func clamp(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat
func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int

// ===== 类型定义 =====
enum PageMode { case preview, edit }
enum RangeMode { case day, threeDay, week }
enum HeaderVisibility { case visible, hidden }

struct CalendarPageState {
    var pageMode: PageMode           // 当前模式
    var headerVisibility: HeaderVisibility  // header 是否可见
    var pullToggleReady: Bool        // 是否可以再次触发切换
    static var initial: CalendarPageState  // 初始状态
}

// ===== 布局常量 =====
struct CalendarPageMetrics {
    let containerSize: CGSize
    let safeAreaTop: CGFloat
    var normalHeaderHeight: CGFloat    // 普通模式高度
    var expandedHeaderHeight: CGFloat  // 展开模式高度
    var hideSnapDistance: CGFloat      // 隐藏触发距离
    let hideThreshold: CGFloat = 0.55  // 隐藏触发比例
    let expandPullDistance: CGFloat = 72  // 下拉切换模式的距离
    var topMaskConfig: EdgeFadeConfig  // 顶部渐隐配置
    var bottomMaskConfig: EdgeFadeConfig  // 底部渐隐配置
}

// ===== 状态机 =====
struct CalendarPageStateMachine {
    struct Transition {
        let state: CalendarPageState
        let shouldAnimate: Bool
    }

    // 核心：根据滚动位置计算新状态
    static func transition(from:scrollY:metrics:) -> Transition
}

// ===== 组合器 =====
struct CalendarHeaderPresentation {
    let height: CGFloat    // header 高度
    let topInset: CGFloat  // 安全区顶部
    let opacity: CGFloat   // 透明度 0-1
    let scale: CGFloat     // 缩放 0.98-1
}

struct CalendarPageComposition {
    let headerMode: CalendarHeaderView.Mode  // normal/expanded
    let headerPresentation: CalendarHeaderPresentation
    let activeTimelineMode: PageMode  // 当前激活的时间线模式
    let timelineRange: RangeMode      // 日/三日/周
    let timelineRebuildKey: String    // 强制重建的 key
    let timelineTopPadding: CGFloat   // 时间线顶部间距
}

struct CalendarPageComposer {
    // 核心：把状态映射成 UI 参数
    static func compose(state:rangeMode:scrollY:metrics:) -> CalendarPageComposition
}
```

### CalendarPageView.swift (399 行)

主视图，职责：
- 组装 header 和 timeline
- 监听滚动，驱动状态机
- 处理事件拖拽
- 管理事件缓存

```swift
struct CalendarPageView: View {
    // ===== 状态 =====
    @State private var pageState: CalendarPageState = .initial
    @State private var scrollGeometry: ScrollGeometry
    @State private var occurrencesCache: [Int: [EventOccurrence]]
    @State private var dayRange: ClosedRange<Int> = -30...30

    // ===== 主体 =====
    var body: some View {
        GeometryReader { proxy in
            let metrics = CalendarPageMetrics(...)
            let composition = CalendarPageComposer.compose(...)

            ZStack(alignment: .top) {
                timelineScroll(...)   // ScrollView + TimelineContainerView
                headerCard(...)       // CalendarHeaderView
            }
        }
    }

    // ===== 关键方法 =====
    func handleScroll(_ scrollY: CGFloat, metrics:)  // 调用状态机
    func handleEventDrag(event:draggedRange:offset:rangeMode:)  // 处理拖拽
    func rebuildOccurrencesCache()  // 重建事件缓存
    func expandDayRangeIfNeeded(for:)  // 动态扩展日期范围
}
```

### TimelineView.swift (397 行)

时间线视图，包含三层：

```swift
// ===== 样式 =====
struct TimelineStyle {
    enum Variant { case view, edit }
    let gridDashed: Bool      // 网格是否虚线
    let gridColor: Color      // 网格颜色
    static let edit: TimelineStyle   // 编辑模式样式
    static let view: TimelineStyle   // 预览模式样式
}

// ===== 容器层 (公开) =====
struct TimelineContainerView: View {
    // 根据 RangeMode 决定显示几天
    private var daysCount: Int {
        switch range {
        case .day: return 1
        case .threeDay: return 3
        case .week: return 7
        }
    }
}

// ===== 分页层 (私有) =====
private struct TimelinePagerView: View {
    // 单日：TabView 分页
    func singleDayContent() -> some View {
        TabView(selection: $selectedDayOffset) { ... }
    }

    // 多日：ScrollView 横滑
    func multiDayContent() -> some View {
        ScrollView(.horizontal) {
            LazyHStack { ... }
        }
    }
}

// ===== 日视图层 =====
// 在 `CalendarDayLayerView.swift` 中以 UIKit + CALayer 实现。
// 单日列内的网格 + 事件块全部由 CALayer 直接绘制；不再有 SwiftUI 的
// `TimelineDayView` 中间层。
```

### CalendarLayout.swift (115 行)

纯计算，无 UI：

```swift
enum CalendarLayout {
    static let defaultDayRange: ClosedRange<Int> = -30...30

    struct EventOccurrence: Identifiable {
        let id: String
        let event: Event
        let range: Event.TimeRange
    }

    // 过滤某天的事件
    static func occurrencesForDate(_ events:, date:) -> [EventOccurrence]

    // 批量构建缓存
    static func occurrencesByOffset(_ events:, dayRange:) -> [Int: [EventOccurrence]]

    // 时间 → Y 坐标
    static func yOffset(for range:, on date:, headerHeight:, hourHeight:) -> CGFloat

    // 时长 → 高度
    static func eventHeight(for range:, on date:, minimumHeight:, hourHeight:) -> CGFloat

    // 事件颜色
    static func eventColor(for event:) -> Color

    // Y 坐标 → 时间（带吸附）
    static func timeFromYOffset(yOffset:, on date:, headerHeight:, hourHeight:, snapMinutes: = 15) -> Date
}
```

### EventBlock.swift (190 行)

事件块 + 拖拽手势：

```swift
// ===== 样式 =====
struct EventBlockStyle {
    let fillOpacity: Double
    let strokeOpacity: Double
    let strokeWidth: CGFloat
    let showTimeRange: Bool
    static let edit: EventBlockStyle
    static let preview: EventBlockStyle
}

// ===== 拖拽偏移 =====
struct DragOffset: Equatable {
    var x: CGFloat
    var y: CGFloat
}

// ===== UIKit 手势 =====
struct LongPressDragGesture: UIViewRepresentable {
    var minimumPressDuration: TimeInterval = 0.3
    var onDragChanged: ((DragOffset) -> Void)?
    var onDragEnded: ((DragOffset) -> Void)?
    @Binding var isDragging: Bool
    @Binding var dragOffset: DragOffset
}

// ===== 事件块视图 =====
struct EventBlock: View {
    let event: Event
    let displayRange: Event.TimeRange?
    let color: Color
    let showText: Bool
    let style: EventBlockStyle
    var onTap: (() -> Void)?
    var onDragEnded: ((DragOffset) -> Void)?

    var body: some View {
        content
            .background(RoundedRectangle(...).fill(color.opacity(...)))
            .overlay(RoundedRectangle(...).stroke(...))
            .scaleEffect(isDragging ? 1.05 : 1.0)  // 拖拽放大
            .shadow(radius: isDragging ? 8 : 0)    // 拖拽阴影
            .offset(x: dragOffset.x, y: dragOffset.y)  // 跟随手指
            .overlay { LongPressDragGesture(...) }  // 手势层
    }
}
```

### CalendarView.swift (19 行)

入口视图，职责单一：

```swift
struct CalendarView: View {
    var body: some View {
        CalendarPageView()  // 委托给主视图
    }
}
```

### CalendarViewState.swift (16 行)

跨页面共享状态，作为 `@EnvironmentObject` 注入：

```swift
final class CalendarViewState: ObservableObject {
    @Published var selectedDayOffset: Int = 0   // 相对今天的天数偏移（0=今天，-1=昨天，1=明天）
    @Published var rangeMode: RangeMode = .day  // 日/三日/周
}
```

### CalendarSubtitleStore.swift (39 行)

从 Bundle 资源加载随机副标题：

```swift
enum CalendarSubtitleStore {
    private static let subdirectory = "CalendarSubtitles"
    private static let filename = "subtitles"
    private static let fileExtension = "txt"

    // 返回随机副标题
    static func randomSubtitle() -> String {
        guard let subtitles = loadSubtitles(), !subtitles.isEmpty else {
            return "shit，load nothing"
        }
        return subtitles.randomElement() ?? ""
    }

    // 从 CalendarSubtitles/subtitles.txt 加载所有行
    private static func loadSubtitles() -> [String]? {
        let url = Bundle.main.url(forResource: filename, withExtension: fileExtension, subdirectory: subdirectory)
        guard let resolvedUrl = url else { return nil }
        guard let contents = try? String(contentsOf: resolvedUrl, encoding: .utf8) else { return nil }
        return contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
```

### CalendarHeaderView.swift (206 行)

头部视图，包含打字机效果：

```swift
// ===== 打字机控制器 =====
@MainActor
final class TypingSubtitleController: ObservableObject {
    @Published var progress: Int = 0  // 已显示字符数

    func start(text: String, interval: TimeInterval) {
        // 每隔 interval 秒增加 progress，直到显示完整文本
        task = Task {
            for i in 1...text.count {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                self.progress = i
            }
        }
    }

    func stop() { task?.cancel() }
}

// ===== 打字机视图 =====
private struct TypingSubtitleView: View {
    let text: String
    let progress: Int

    var body: some View {
        Text(String(text.prefix(progress)))  // 只显示前 progress 个字符
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

// ===== 头部视图 =====
struct CalendarHeaderView: View {
    enum Mode { case normal, expanded }

    var title: String
    var subtitle: String
    var mode: Mode = .normal
    var onTodayTapped: () -> Void
    var onAddTapped: () -> Void
    // ...

    @StateObject private var subtitleController = TypingSubtitleController()

    var body: some View {
        GlassCardView {
            VStack(alignment: .leading, spacing: 6) {
                if mode == .expanded {
                    expandedPager  // TabView 分页，包含工具按钮
                } else {
                    normalRow      // 标题 + 副标题 + Today 按钮
                }
            }
        }
        .onAppear { subtitleController.start(text: subtitle, interval: 0.05) }
    }
}
```

### GlassCardView.swift (63 行)

毛玻璃卡片容器：

```swift
// ===== 卡片容器 =====
struct GlassCardView<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var contentPadding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        GlassEffectContainer(cornerRadius: cornerRadius) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(contentPadding)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 8)
    }
}

// ===== 毛玻璃效果 =====
struct GlassEffectContainer<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .background {
                shape.fill(.ultraThinMaterial)           // 毛玻璃背景
                    .overlay { shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.8) }  // 边框
                    .overlay { shape.fill(.white.opacity(0.06)) }  // 高光
            }
            .clipShape(shape)
    }
}
```

### TimelineHeaderBar.swift (34 行)

范围切换栏（仅 edit 模式显示）：

```swift
struct TimelineHeaderBar: View {
    let isEditing: Bool
    @Binding var rangeMode: RangeMode
    let selectedDayOffset: Int

    var body: some View {
        if isEditing {
            HStack {
                Picker("Range", selection: $rangeMode) {
                    Text("Day").tag(RangeMode.day)
                    Text("3-Day").tag(RangeMode.threeDay)
                    Text("Week").tag(RangeMode.week)
                }
                .pickerStyle(.segmented)  // 分段控件样式
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.move(edge: .top).combined(with: .opacity))  // 进入/退出动画
        }
    }
}
```

### TimelineMaskView.swift (61 行)

上下边缘渐隐遮罩：

```swift
// ===== 边缘配置 =====
struct EdgeFadeConfig {
    let holdHeight: CGFloat    // 完全透明区域高度
    let featherHeight: CGFloat // 渐变过渡区域高度

    var maskHeight: CGFloat { holdHeight + featherHeight }
    var holdStop: CGFloat { holdHeight / maskHeight }  // 渐变停止点 (0-1)
}

// ===== 遮罩视图 =====
struct TimelineMaskView: View {
    let top: EdgeFadeConfig
    let bottom: EdgeFadeConfig

    var body: some View {
        VStack(spacing: 0) {
            // 顶部渐隐：透明 → 不透明
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: 0),
                    .init(color: .black.opacity(0), location: top.holdStop),
                    .init(color: .black.opacity(1), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: top.maskHeight)

            // 中间：不透明
            Rectangle().fill(.black).frame(maxHeight: .infinity)

            // 底部渐隐：不透明 → 透明
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(1), location: 0),
                    .init(color: .black.opacity(1), location: bottom.holdStop),
                    .init(color: .black.opacity(0), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: bottom.maskHeight)
        }
    }
}
```

---

## 数据流

### 滚动 → 状态更新

```
用户滚动 ScrollView
    ↓
onScrollGeometryChange 触发
    ↓
CalendarPageView.handleScroll(scrollY)
    ↓
CalendarPageStateMachine.transition(from: pageState, scrollY, metrics)
    ├─ scrollY >= 0 → pullToggleReady = true
    ├─ scrollY <= -72 且 pullToggleReady → 切换 pageMode
    └─ scrollY >= cutoff → headerVisibility = .hidden
    ↓
返回 Transition { state, shouldAnimate }
    ↓
pageState = transition.state
    ↓
SwiftUI 重新计算 body
    ↓
CalendarPageComposer.compose(state, rangeMode, scrollY, metrics)
    ↓
返回 CalendarPageComposition
    ↓
headerCard 和 timelineScroll 使用 composition 渲染
```

### 事件拖拽

```
用户长按 EventBlock (0.3秒)
    ↓
LongPressDragGesture.handleGesture(.began)
    ↓
isDragging = true, dragOffset = .zero
    ↓
EventBlock 应用放大+阴影效果
    ↓
用户拖动手指
    ↓
LongPressDragGesture.handleGesture(.changed)
    ↓
dragOffset 更新, EventBlock 跟随移动
    ↓
用户松手
    ↓
LongPressDragGesture.handleGesture(.ended)
    ↓
onDragEnded?(finalOffset) 回调
    ↓
CalendarDayLayerView 的拖拽 handler 透传 (event, originalRange, offset)
    ↓
TimelinePagerView → TimelineContainerView → CalendarPageView
    ↓
CalendarPageView.handleEventDrag(event, draggedRange, offset, rangeMode)
    ↓
计算新位置：
  1. dayOffsetFromDrag = offset.x 转换为天数偏移
  2. currentY = CalendarLayout.yOffset(draggedRange)
  3. newY = currentY + offset.y
  4. newStart = CalendarLayout.timeFromYOffset(newY, targetDate)
  5. newEnd = newStart + duration
    ↓
更新事件：
  1. 找到 draggedRange 在 timeRanges 中的位置
  2. 替换为新的 TimeRange
  3. store.update(event)
    ↓
EventStore 保存，触发 @Published
    ↓
CalendarPageView.onChange(of: store.events)
    ↓
rebuildOccurrencesCache()
    ↓
UI 刷新显示新位置
```

---

## 布局常量速查

| 常量 | 值 | 说明 |
|------|-----|------|
| `hourHeight` | 56 | 每小时高度 |
| `labelWidth` | 36 | 左侧时间标签宽度 |
| `daySpacing` | 12 | 多日视图的天间距 |
| `expandPullDistance` | 72 | 下拉多少切换模式 |
| `hideThreshold` | 0.55 | 滚动多少比例隐藏 header |
| `snapMinutes` | 15 | 时间吸附间隔 |
| `minimumPressDuration` | 0.3 | 长按触发时间 |

---

## 依赖

- `EventStore` / `Event` - 事件数据模型 (Models/)
- `EventTypeTemplateStore` - 事件类型颜色映射 (Models/)
- `EditEventView` - 事件编辑页面 (Views/Todo/)
