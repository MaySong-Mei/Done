# Todo 模块

## 文件结构

```
Todo/
├── EventFormView.swift                 # 事件表单（新建/编辑共用），含 EventFormData 数据转换
├── EventCardView.swift                 # 网格中单个事件卡片的渲染
├── AddToCalendarView.swift             # 为事件添加日历时间段的 sheet
├── TemplateEditorView.swift            # 事件类型模板编辑器（名称+颜色）
└── EventGrid/
    ├── EventGridView.swift             # 主视图：状态管理 + 网格渲染 + 子视图
    ├── EventGridInteractions.swift     # 拖拽交互逻辑（z-order、snap、拖放状态机）
    ├── EventGridTypes.swift            # 类型定义（DragState、PositionedEvent）
    ├── EventGridSheets.swift           # Sheet 视图（CreateEventView、EditEventView、EmptyStateView）
    ├── GridDotsView.swift              # 背景网格圆点
    ├── ShakeEffect.swift               # 长按抖动效果
    └── UIKitDragGestureView.swift      # UIKit 长按拖拽手势桥接
```

---

## 功能 → 代码对照表

| 功能 | 文件 | 具体代码 |
|------|------|----------|
| **网格主视图** | `EventGridView.swift` | `EventGridView.body` GeometryReader + ScrollView |
| **事件卡片渲染** | `EventCardView.swift` | `EventCardView.body` 标题+优先级+deadline+备注 |
| **卡片颜色** | `EventCardView.swift` | `cardColor` 调用 `EventTypeTemplateStore.color(for:)` |
| **deadline 倒计时** | `EventCardView.swift` | `remainingText(until:)` 计算剩余/超时天时分 |
| **新建事件** | `EventGridSheets.swift` | `CreateEventView` 传默认值给 `EventFormView` |
| **编辑事件** | `EventGridSheets.swift` | `EditEventView` 传事件字段给 `EventFormView` |
| **从日历新建（带时间段）** | `EventGridSheets.swift` | `CreateEventView(timeRange:)` 预填时间 |
| **事件表单** | `EventFormView.swift` | `EventFormView` 8 个 Section 表单 |
| **表单 → Event 转换** | `EventFormView.swift` | `EventFormData.toEvent()` / `apply(to:)` |
| **时间段校验** | `EventFormView.swift` | `normalizedRanges()` 确保 end > start，按时间排序 |
| **事件类型选择** | `EventFormView.swift` | `typeSection` 列表 + checkmark + swipe 编辑/删除 |
| **模板编辑** | `TemplateEditorView.swift` | `TemplateEditorView` 名称 TextField + ColorPicker |
| **添加日历时间段** | `AddToCalendarView.swift` | `AddToCalendarView` 双 DatePicker (start/end) |
| **网格圆点背景** | `GridDotsView.swift` | `Canvas` 批量绘制圆点 |
| **长按拖拽手势** | `UIKitDragGestureView.swift` | `UILongPressGestureRecognizer` + window 坐标系 |
| **拖拽开始** | `EventGridInteractions.swift` | `beginDrag(for:)` 创建 `DragState` |
| **拖拽中更新** | `EventGridInteractions.swift` | `updateDrag(for:translation:)` 更新 translation |
| **拖拽结束/放置** | `EventGridInteractions.swift` | `endDrag(for:...)` snap 到网格 + 更新坐标 |
| **拖拽删除** | `EventGridInteractions.swift` | `endDrag` 检测 `deleteZoneFrame.contains(endLocation)` |
| **网格 snap 吸附** | `EventGridTypes.swift` | `DragState.snappedPosition()` 像素→列行换算 |
| **拖拽中 ghost 预览** | `EventGridView.swift` | `dragGhostView()` 半透明目标位置矩形 |
| **near-snap 边框** | `EventGridView.swift` | `isNearSnap` 判断偏移 < 8pt 时显示描边 |
| **z-order 层级管理** | `EventGridInteractions.swift` | `syncZOrder()` / `bringToFront()` / `zIndex(for:)` |
| **长按缩放 + 抖动** | `EventGridView.swift` | `LongPressGesture` → `scaleEffect(0.98)` + `ShakeEffect` |
| **抖动动画** | `ShakeEffect.swift` | `GeometryEffect` 正弦水平位移 |
| **拖拽放大 + 阴影** | `EventGridView.swift` | `scaleEffect(1.03)` + `shadow` |
| **空状态** | `EventGridSheets.swift` | `EmptyStateView` 图标 + 文字 |

---

## 各文件详解

### EventGridView.swift (192 行)

主视图，集状态管理与渲染于一体：

```swift
struct EventGridView: View {
    // ===== 外部输入 =====
    let events: [Event]
    @EnvironmentObject var store: EventStore
    @Binding var isDraggingEvent: Bool      // 通知父视图隐藏 tabBar
    @Binding var deleteZoneFrame: CGRect    // 删除区域坐标（父视图提供）

    // ===== 内部状态 =====
    @State var dragState: DragState?               // 当前拖拽状态
    @State private var selectedEvent: Event?       // 编辑 sheet 绑定
    @State private var addToCalendarEvent: Event?  // 日历 sheet 绑定
    @State var zOrder: [UUID] = []                 // 层级顺序数组
    @State var longPressingEventID: UUID?          // 长按中的事件
    @State private var shakeTriggers: [UUID: CGFloat] = [:]  // 抖动触发计数

    // ===== body =====
    // GeometryReader → 计算 cellSize → ScrollView + ZStack
    //   ├── GridDotsView          (背景圆点)
    //   ├── dragGhostView()       (拖拽 ghost 预览)
    //   └── ForEach → eventCardView()  (事件卡片)
    // .sheet → EditEventView / AddToCalendarView
    // .onAppear / .onChange → syncZOrder
}

// ===== 子视图 (private extension) =====
// dragGhostView()   — 拖拽时半透明目标位置指示
// eventCardView()   — 单个事件卡片 + 手势 + 动画
```

### EventGridInteractions.swift (79 行)

`EventGridView` 的 extension，所有交互逻辑：

```swift
extension EventGridView {
    // ===== z-order 管理 =====
    func syncZOrder(with events: [Event])   // 同步：保留现有顺序，追加新增
    func bringToFront(_ eventID: UUID)      // 点击/拖拽时置顶
    func zIndex(for eventID: UUID) -> Double // 返回排序索引

    // ===== 拖拽状态机 =====
    func shouldBeginDrag(for eventID: UUID) -> Bool  // 仅允许一个事件拖拽
    func beginDrag(for placed: PositionedEvent)      // 创建 DragState
    func updateDrag(for eventID: UUID, translation: CGSize)  // 更新位移

    func endDrag(
        for placed: PositionedEvent,
        translation: CGSize,
        endLocation: CGPoint,   // window 坐标，用于检测删除区域
        cellSize: CGFloat
    )
    // endDrag 流程：
    //   1. 检查 deleteZoneFrame.contains → store.delete
    //   2. 否则 snappedPosition → updateEvent 更新网格坐标

    // ===== 持久化 =====
    func updateEvent(_ event: Event, gridX: Int, gridY: Int)
    // 仅当坐标变化时调用 store.update
}
```

### EventGridTypes.swift (49 行)

纯数据类型，无 UI：

```swift
// ===== 拖拽状态 =====
struct DragState {
    let eventID: UUID
    let initialGridX: Int       // 拖拽开始时的网格列
    let initialGridY: Int       // 拖拽开始时的网格行
    let spanColumns: Int        // 事件占据列数
    let spanRows: Int           // 事件占据行数
    var translation: CGSize     // 当前拖拽位移（像素）

    // 像素位移 → 目标网格坐标（含边界约束）
    func snappedPosition(translation:cellSize:columnsCount:) -> (x: Int, y: Int)
}

// ===== 已定位的事件 =====
struct PositionedEvent: Identifiable {
    let event: Event
    let gridX: Int, gridY: Int
    let spanColumns: Int, spanRows: Int

    // 过滤有网格坐标的事件，计算 span
    static func from(_ events: [Event]) -> [PositionedEvent]
}
```

### EventGridSheets.swift (72 行)

Sheet 视图，连接 EventFormView 和 EventStore：

```swift
// ===== 新建事件 =====
struct CreateEventView: View {
    var timeRange: Event.TimeRange? = nil  // 可选预填时间（从日历拖拽创建时传入）

    // timeRange == nil → store.addWithAutoPlacement (自动分配网格位置)
    // timeRange != nil → store.add (从日历创建，不需要网格位置)
}

// ===== 编辑事件 =====
struct EditEventView: View {
    let event: Event
    // 从 event 读取初始值 → EventFormView → form.apply(to: event) → store.update
}

// ===== 空状态 =====
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    // 居中显示图标 + 文字
}
```

### EventFormView.swift (384 行)

新建/编辑共用的表单视图：

```swift
struct EventFormView: View {
    let navigationTitle: String             // "New Event" 或 "Edit Event"
    let onSave: (EventFormData) -> Void     // 保存回调

    // ===== 表单字段 (均为 @State) =====
    // title, selectedTypeTitle, note, priority,
    // tagsText, gridWidth, gridHeight, timeRanges, deadline

    // ===== 表单 Sections =====
    // titleSection       — 标题输入
    // typeSection        — 类型选择列表 (带 swipe 编辑/删除/新增模板)
    // descriptionSection — 备注 TextEditor
    // prioritySection    — 优先级 Stepper (0-5)
    // tagsSection        — 标签输入 (逗号分隔)
    // gridSection        — 网格尺寸 Stepper (3-64)
    // scheduleSection    — 时间段 Toggle + 多个 DatePicker
    // ddlSection         — Deadline Toggle + DatePicker

    // ===== 辅助逻辑 =====
    // addTimeRange()       — 添加默认 1 小时时间段
    // removeTimeRange(id:) — 删除指定时间段
    // normalizedRanges()   — end <= start 时修正为 start+1h，按时间排序
}

// ===== 表单数据 =====
struct EventFormData {
    // 所有表单字段的快照

    func toEvent() -> Event       // 创建新 Event（自动同步 startTime/endTime）
    func apply(to event: Event) -> Event  // 更新已有 Event 的字段
}

// ===== 私有类型 =====
private struct EventFormRange: Identifiable  // 表单内部的可变时间段
private struct TemplateEditorMode: Identifiable  // 模板编辑 sheet 的参数
```

### EventCardView.swift (76 行)

单个事件卡片的渲染：

```swift
struct EventCardView: View {
    let event: Event
    let availableHeight: CGFloat  // 网格分配的可用高度

    // body: VStack
    //   ├── HStack: 优先级感叹号 + 标题
    //   ├── deadline 倒计时文字 (红色)
    //   └── 备注文字 (secondary)
    // .background: 圆角矩形，颜色根据 event.type
    // .overlay: 描边

    // remainingText(until:) — 计算 "Remaining 2d 3h" 或 "Overdue 1h 30m"
    // cardColor — EventTypeTemplateStore.color(for: event.type)
}
```

### AddToCalendarView.swift (69 行)

为事件添加日历时间段：

```swift
struct AddToCalendarView: View {
    let event: Event

    // 初始值：event.primaryTimeRange ?? 当前时间起 1 小时
    @State private var startTime: Date
    @State private var endTime: Date

    // body: Form
    //   ├── Section "Event" — 显示标题
    //   ├── Section "Start" — graphical DatePicker
    //   └── Section "End"   — graphical DatePicker (下限 = startTime)
    // Done: 追加 TimeRange → 排序 → 同步 startTime/endTime → store.update
}
```

### TemplateEditorView.swift (59 行)

事件类型模板编辑器：

```swift
struct TemplateEditorView: View {
    let title: String                       // "New Template" 或 "Edit Template"
    let onSave: (String, Color) -> Void     // (标题, 颜色)

    @State private var templateTitle: String
    @State private var templateColor: Color

    // body: Form
    //   ├── Section "Name"  — TextField
    //   └── Section "Color" — ColorPicker
    // Save: 校验非空 → onSave(trimmedTitle, color)
}
```

### UIKitDragGestureView.swift (143 行)

UIKit 长按拖拽手势的 SwiftUI 桥接：

```swift
struct UIKitDragGestureView: UIViewRepresentable {
    let minimumPressDuration: TimeInterval  // 长按触发时间 (0.3s)
    let shouldBegin: () -> Bool             // 是否允许开始
    let onPanBegan: () -> Void              // 拖拽开始
    let onPanChanged: (CGSize) -> Void      // 拖拽中 (translation)
    let onPanEnded: (CGSize, CGPoint) -> Void  // 拖拽结束 (translation, window坐标)
    var allowableMovement: CGFloat = 1000   // 允许移动距离

    // Coordinator:
    //   - 使用 window 坐标计算 translation，避免 view 移动导致坐标反馈循环
    //   - shouldBegin() 失败时通过 disable/enable 重置手势
    //   - require(toFail:) 确保长按优先于 ScrollView 滚动
}
```

### GridDotsView.swift (33 行)

背景网格圆点：

```swift
struct GridDotsView: View {
    let columns: Int, rows: Int, cellSize: CGFloat

    // Canvas 批量绘制：每个 cell 中心放一个 r=1.5 的圆点
    // 使用单个 Path 合并所有圆点，一次性 fill，性能最优
}
```

### ShakeEffect.swift (23 行)

抖动动画效果：

```swift
struct ShakeEffect: GeometryEffect {
    var travelDistance: CGFloat = 6      // 振幅 (像素)
    var shakesPerUnit: CGFloat = 4      // 每个动画周期的抖动次数
    var animatableData: CGFloat         // 驱动值，+1 触发一次抖动

    // sin(animatableData * π * shakesPerUnit) * travelDistance
    // 水平方向正弦抖动
}
```

---

## 数据流

### 事件拖拽

```
用户长按事件卡片 (0.3秒)
    ↓
UIKitDragGestureView.handle(.began)
    ↓
shouldBeginDrag(for:) → 检查无其他拖拽中
    ↓
beginDrag(for:) → 创建 DragState, isDraggingEvent = true
    ↓
bringToFront() → 更新 zOrder 层级
    ↓
UI 响应：卡片 scaleEffect(1.03) + shadow
         dragGhostView 显示半透明目标位置
    ↓
用户拖动手指
    ↓
UIKitDragGestureView.handle(.changed)
    ↓
updateDrag(for:translation:) → 更新 DragState.translation
    ↓
卡片跟随移动 (position + dragOffset)
dragGhostView 实时更新 snap 位置
    ↓
用户松手
    ↓
UIKitDragGestureView.handle(.ended)
    ↓
endDrag(for:translation:endLocation:cellSize:)
    ├─ endLocation 在 deleteZoneFrame 内？
    │   → store.delete(event)
    └─ 否则
        → DragState.snappedPosition() 计算目标网格坐标
        → updateEvent() → store.update()
    ↓
dragState = nil, isDraggingEvent = false
    ↓
UI 复原：卡片回到新位置, ghost 消失
```

### 新建/编辑事件

```
用户触发新建或点击事件卡片
    ↓
.sheet 弹出 CreateEventView 或 EditEventView
    ↓
内部创建 EventFormView（传入初始值 + onSave 回调）
    ↓
用户填写表单
    ↓
点击 Done
    ↓
EventFormView 构建 EventFormData
    ├─ tags: 逗号分隔 → 数组
    ├─ timeRanges: normalizedRanges() 校验+排序
    └─ title: trimmingCharacters
    ↓
调用 onSave(EventFormData)
    ├─ CreateEventView: form.toEvent() → store.add / addWithAutoPlacement
    └─ EditEventView:   form.apply(to: event) → store.update
    ↓
dismiss()
```

### 模板编辑

```
用户在 typeSection 点击 "Add Template" 或 swipe "Edit"
    ↓
editorMode = TemplateEditorMode(originalTitle:, initialTitle:, initialColorHex:)
    ↓
.sheet 弹出 TemplateEditorView
    ↓
用户修改名称/颜色 → 点击 Save
    ↓
onSave(newTitle, newColor) 回调
    ├─ originalTitle != nil → templateStore.update() (编辑)
    └─ originalTitle == nil → templateStore.add()    (新增)
    ↓
selectedTypeTitle 同步更新
```

---

## 布局常量速查

| 常量 | 值 | 位置 | 说明 |
|------|-----|------|------|
| `horizontalPadding` | 16 | EventGridView | 网格左右边距 |
| `verticalPadding` | 12 | EventGridView | 网格上下边距 |
| `minCellSize` | 8 | EventGridView | 最小 cell 尺寸 |
| `extraRows` | 50 | EventGridView | 最底部事件下方的额外行数 |
| `minRows` | 50 | EventGridView | 网格最少行数 |
| `minimumPressDuration` | 0.3s | UIKitDragGestureView | 长按拖拽触发时间 |
| `longPressDuration` | 0.45s | EventGridView | 长按抖动触发时间 |
| `allowableMovement` | 1000 | UIKitDragGestureView | 长按允许移动距离 |
| `dotRadius` | 1.5 | GridDotsView | 背景圆点半径 |
| `dotOpacity` | 0.08 | GridDotsView | 背景圆点透明度 |
| `cardCornerRadius` | 10 | EventCardView | 卡片圆角 |
| `ghostCornerRadius` | 8 | EventGridView | 拖拽 ghost 圆角 |
| `nearSnapThreshold` | 8pt | EventGridView | 显示 snap 描边的距离阈值 |
| `dragScale` | 1.03 | EventGridView | 拖拽中卡片放大比例 |
| `longPressScale` | 0.98 | EventGridView | 长按中卡片缩小比例 |
| `shakeDistance` | 6 | ShakeEffect | 抖动振幅 (像素) |
| `shakesPerUnit` | 4 | ShakeEffect | 每次触发的抖动次数 |
| `gridWidth` 范围 | 3-64 | EventFormView | 事件网格宽度范围 |
| `gridHeight` 范围 | 3-64 | EventFormView | 事件网格高度范围 |
| `priority` 范围 | 0-5 | EventFormView | 优先级范围 |

---

## 依赖

- `EventStore` / `Event` — 事件数据模型 (Models/)
- `EventGridLayout` — 网格列数、span 计算 (Models/)
- `EventTypeTemplateStore` — 事件类型模板管理、颜色映射 (Models/)
- `ColorHex` — Color ↔ hex 字符串转换 (Models/)
- `CalendarPageView` — 从日历拖拽创建事件时使用 `CreateEventView(timeRange:)` (Views/Calendar/)
- `ContentView` — 入口，使用 `CreateEventView()` 和 `EventGridView` (Views/)
