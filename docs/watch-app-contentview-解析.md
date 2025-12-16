# Watch App ContentView 代码解析

本文档详细解释了 Apple Watch 应用的 `ContentView.swift` 文件，该文件实现了 Watch 应用的核心界面和交互逻辑。

## 目录

- [文件概述](#文件概述)
- [导入和主视图](#导入和主视图)
- [ActivityCrownPickerView - 活动选择器](#activitycrownpickerview---活动选择器)
- [ActiveTimerView - 计时器视图](#activetimerView---计时器视图)
- [RainScene - 雨滴动画场景](#rainscene---雨滴动画场景)
- [辅助组件](#辅助组件)

---

## 文件概述

**文件路径**: `Done Watch App/ContentView.swift`
**总行数**: 735行
**主要功能**:
- 时间追踪的主界面
- 基于表冠的活动选择
- 雨滴和水位上升的视觉化计时效果
- 计时摘要展示

**技术栈**:
- SwiftUI (界面构建)
- SpriteKit (雨滴动画)
- Watch Connectivity (与iPhone通信)

---

## 导入和主视图

### 导入部分 (1-10行)

```swift
import SwiftUI      // 8: 导入 SwiftUI 框架用于构建用户界面
import SpriteKit    // 9: 导入 SpriteKit 用于创建雨滴动画效果
```

### ContentView 主视图 (11-27行)

ContentView 是应用的根视图，负责根据当前状态显示不同的界面。

```swift
struct ContentView: View {
    @StateObject private var dataManager = DataManager.shared

    var body: some View {
        NavigationStack {
            if let activeEntry = dataManager.activeEntry {
                ActiveTimerView(entry: activeEntry)
            } else {
                ActivityCrownPickerView()
            }
        }
        .onAppear {
            WatchConnectivityManager.shared.requestTemplates()
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}
```

**关键点**:
- **第12行**: 使用 `@StateObject` 管理数据管理器的生命周期
- **第16-19行**: 根据是否有活跃计时条目显示不同视图
  - 有活跃计时 → 显示 `ActiveTimerView` (计时器界面)
  - 无活跃计时 → 显示 `ActivityCrownPickerView` (选择器界面)
- **第23行**: 视图出现时从iPhone请求模板数据
- **第25行**: 隐藏导航栏以获得更大的显示空间

---

## ActivityCrownPickerView - 活动选择器

这个视图允许用户通过Apple Watch的表冠（Digital Crown）选择要追踪的活动。

### 状态变量 (30-33行)

```swift
@StateObject private var dataManager = DataManager.shared  // 数据管理器
@State private var selectedIndex: Int = 0                   // 当前选中的模板索引
@FocusState private var pickerFocused: Bool                // 选择器焦点状态
@Namespace private var cardNamespace                        // 用于匹配几何效果的命名空间
```

**变量说明**:
- `selectedIndex`: 追踪当前选中的模板在数组中的位置
- `pickerFocused`: 控制选择器是否响应表冠输入
- `cardNamespace`: 用于实现卡片切换时的流畅动画效果

### 主布局 (35-61行)

```swift
var body: some View {
    let templates = dataManager.templates

    VStack(spacing: 12) {
        if let current = currentTemplate {
            currentCard(for: current)
                .id(current.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

            startButton(for: current)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedIndex)
        } else {
            emptyState
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 14)
    .background(wheelPickerOverlay(templates: templates))
    .onChange(of: dataManager.templates.count) { _, _ in clampSelection() }
    .onAppear {
        clampSelection()
        pickerFocused = true
    }
}
```

**布局逻辑**:
1. **第36行**: 获取所有可用的活动模板
2. **第39-45行**: 显示当前选中的卡片，带有非对称过渡动画
   - 插入时：从右侧滑入并淡入
   - 移除时：从左侧滑出并淡出
3. **第47-48行**: 显示开始按钮，带有弹簧动画效果
4. **第55行**: 背景中放置隐藏的滚轮选择器（响应表冠）
5. **第56行**: 当模板数量变化时，确保选择索引在有效范围内
6. **第59行**: 视图出现时自动聚焦选择器，启用表冠控制

### 当前卡片视图 (63-99行)

显示当前选中活动的卡片UI。

```swift
private func currentCard(for template: ActivityTemplate) -> some View {
    let blockColor = Color(hex: "#303030") ?? Color(red: 48/255, green: 48/255, blue: 48/255)

    return VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
            if !template.icon.isEmpty {
                Image(systemName: template.icon)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 46, height: 46)
                    .background(template.color.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .matchedGeometryEffect(id: "icon\(template.id)", in: cardNamespace)
            }

            Text(template.name)
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .matchedGeometryEffect(id: "title\(template.id)", in: cardNamespace)

            Spacer()
        }
    }
    .frame(maxWidth: .infinity)
    .frame(height: 140)
    .padding(.horizontal, 6)
    .background(blockColor)
    .overlay(
        RoundedRectangle(cornerRadius: 18)
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .shadow(color: blockColor.opacity(0.35), radius: 12, x: 0, y: 6)
    .animation(.spring(response: 0.3, dampingFraction: 0.82), value: selectedIndex)
}
```

**UI设计细节**:
- **第64行**: 使用深灰色 `#303030` 作为卡片背景
- **第68-76行**: 显示活动图标（如果有）
  - 46×46 的正方形区域
  - 半透明的主题色背景
  - 圆角矩形裁剪
- **第75行**: `matchedGeometryEffect` 实现元素间的流畅过渡动画
- **第78-83行**: 显示活动名称
  - 30号超粗圆角字体
  - 单行显示，必要时缩小到70%
- **第89行**: 固定高度140点
- **第97行**: 添加柔和的阴影效果

### 开始按钮 (101-120行)

```swift
private func startButton(for template: ActivityTemplate) -> some View {
    let blockColor = Color(hex: "#303030") ?? Color(red: 48/255, green: 48/255, blue: 48/255)

    return Button {
        dataManager.startTracking(template: template)
    } label: {
        HStack(spacing: 8) {
            Image(systemName: "play.fill")
            Text("Start \"\(template.name)\"")
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .foregroundColor(.white)
    }
    .buttonStyle(.borderedProminent)
    .tint(blockColor)
    .controlSize(.large)
    .clipShape(RoundedRectangle(cornerRadius: 12))
}
```

**按钮功能**:
- **第105行**: 点击时调用 `dataManager.startTracking()` 开始追踪
- **第108-109行**: 显示播放图标和"Start [活动名]"文本
- **第116-118行**: 使用突出的按钮样式，深灰色背景，大尺寸控件

### 空状态视图 (122-132行)

当没有可用模板时显示的提示界面。

```swift
private var emptyState: some View {
    VStack(spacing: 8) {
        Text("No templates")
            .font(.headline)
        Text("Add templates on your iPhone to start tracking.")
            .font(.caption)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

### 隐藏的滚轮选择器 (139-153行)

这是一个巧妙的设计：使用一个几乎不可见的选择器来响应表冠输入。

```swift
private func wheelPickerOverlay(templates: [ActivityTemplate]) -> some View {
    Picker("Templates", selection: $selectedIndex) {
        ForEach(templates.indices, id: \.self) { index in
            let template = templates[index]
            Text(template.name).tag(index)
        }
    }
    .pickerStyle(.wheel)
    .labelsHidden()
    .frame(height: 1)      // 高度仅1点
    .opacity(0.01)         // 几乎完全透明
    .focused($pickerFocused)
    .focusable(true)
}
```

**设计思路**:
- 将选择器设置为几乎不可见（高度1点，透明度0.01）
- 用户看到的是自定义的卡片UI
- 但表冠输入被这个隐藏选择器捕获
- 实现了美观UI和表冠功能的完美结合

### 辅助方法 (134-158行)

```swift
private var currentTemplate: ActivityTemplate? {
    guard dataManager.templates.indices.contains(selectedIndex) else { return nil }
    return dataManager.templates[selectedIndex]
}

private func clampSelection() {
    let maxIndex = max(dataManager.templates.count - 1, 0)
    selectedIndex = min(selectedIndex, maxIndex)
}
```

**功能说明**:
- `currentTemplate`: 安全地获取当前选中的模板
- `clampSelection()`: 确保选择索引不会超出数组范围

---

## ActiveTimerView - 计时器视图

当用户开始追踪某个活动时显示的视图，包含雨滴动画和水位上升效果。

### 状态变量 (162-169行)

```swift
let entry: TimeEntry                          // 时间条目（传入参数）
@StateObject private var dataManager = DataManager.shared
@State private var rainScene = RainScene(size: CGSize(width: 180, height: 180))
@State private var stopProgress: CGFloat = 0  // 停止按钮的进度（0-1）
@State private var showSummary = false         // 是否显示摘要
@State private var summaryData: (start: Date, end: Date, duration: TimeInterval, name: String)?

private let stopHoldDuration: TimeInterval = 3.0  // 长按停止所需时间（3秒）
```

**变量说明**:
- `rainScene`: SpriteKit场景，用于渲染雨滴和水位动画
- `stopProgress`: 追踪长按进度，用于显示红色进度边框
- `summaryData`: 保存完成后的摘要数据（开始时间、结束时间、持续时间、任务名）

### 主视图结构 (171-207行)

```swift
var body: some View {
    ZStack {
        LinearGradient(
            colors: [
                templateColor.opacity(0.35),
                templateColor.opacity(0.15),
                Color.black.opacity(0.35)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        rainPage
    }
    .onAppear {
        let totalMinutes = Int(Date().timeIntervalSince(entry.startTime) / 60)
        rainScene.updatePalette(
            primary: SKColor(hex: entry.colorHex) ?? SKColor.cyan,
            accent: SKColor(hex: entry.colorHex)?.lifted() ?? SKColor.blue
        )
        rainScene.setInitialWaterLevel(totalMinutes, startTime: entry.startTime)
    }
    .sheet(isPresented: $showSummary, onDismiss: {
        dataManager.stopTracking()
    }) {
        if let data = summaryData {
            SummaryView(
                startTime: data.start,
                endTime: data.end,
                duration: data.duration,
                taskName: data.name
            )
        }
    }
}
```

**视图层次**:
1. **第173-182行**: 渐变背景
   - 从左上角的主题色（35%透明度）
   - 过渡到右下角的黑色（35%透明度）
   - 营造深度感
2. **第186-192行**: 视图出现时初始化雨景
   - 计算已经过去的分钟数
   - 设置颜色方案（主色和提亮的强调色）
   - 设置初始水位（根据已过去的时间）
3. **第194-206行**: 摘要表单
   - 显示计时完成后的摘要
   - 关闭时自动停止追踪

### 雨滴页面布局 (209-262行)

```swift
private var rainPage: some View {
    GeometryReader { proxy in
        let stageHeight = min(proxy.size.height * 0.9, 220)

        VStack {
            Spacer(minLength: 8)

            ZStack {
                rainStage(height: stageHeight)

                // 停止进度边框
                if stopProgress > 0 {
                    RoundedRectangle(cornerRadius: 16)
                        .trim(from: 0, to: stopProgress)
                        .stroke(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(height: stageHeight)
                }
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onLongPressGesture(
                minimumDuration: stopHoldDuration,
                maximumDistance: 200,
                pressing: { pressing in
                    if pressing {
                        withAnimation(.linear(duration: stopHoldDuration)) {
                            stopProgress = 1
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) {
                            stopProgress = 0
                        }
                    }
                },
                perform: {
                    let endTime = Date()
                    let duration = endTime.timeIntervalSince(entry.startTime)
                    summaryData = (
                        start: entry.startTime,
                        end: endTime,
                        duration: duration,
                        name: entry.templateName
                    )
                    showSummary = true
                }
            )

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**交互设计**:
- **第211行**: 舞台高度为屏幕高度的90%或220点（取较小值）
- **第218行**: 显示雨滴舞台（SpriteKit视图）
- **第221-226行**: 显示停止进度指示器
  - 红色圆角矩形边框
  - 从0%到100%逐渐绘制
  - 6点线宽，圆头线帽
- **第230-256行**: 长按手势处理
  - **最小持续时间**: 3秒（防止误触）
  - **按下时**: 用3秒线性动画将进度从0增加到1
  - **松开时**: 用0.2秒缓出动画将进度归零
  - **完成时**:
    - 记录结束时间
    - 计算总持续时间
    - 保存摘要数据
    - 显示摘要表单

### 雨滴舞台 (264-277行)

```swift
private func rainStage(height: CGFloat) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )

        SpriteView(scene: rainScene)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    .frame(height: height)
}
```

**UI层次**:
1. 半透明白色背景（8%透明度）
2. 半透明白色边框（18%透明度）
3. SpriteKit场景（雨滴和水位动画）

---

## RainScene - 雨滴动画场景

这是整个应用最核心的视觉效果实现，使用SpriteKit创建雨滴下落和水位上升的动画。

### 类定义和属性 (290-304行)

```swift
final class RainScene: SKScene {
    // 节点
    private var waterNode: SKShapeNode?          // 水体节点
    private var waterSurfaceNode: SKShapeNode?   // 水面节点（带波浪）
    private var containerNode: SKShapeNode?      // 容器边框节点
    private var raindrops: [SKShapeNode] = []    // 雨滴数组

    // 颜色
    private var primaryColor: SKColor = .cyan    // 主色
    private var accentColor: SKColor = .blue     // 强调色（用于波浪）

    // 动画状态
    private var currentWaterLevel: CGFloat = 0   // 当前水位（0.0-1.0）
    private var wavePhase: CGFloat = 0           // 波浪相位（用于动画）
    private var lastRaindropTime: TimeInterval = 0  // 上次生成雨滴的时间

    // 计时相关
    private var startTime: Date?                 // 开始时间
    private var hasCompletedInitialAnimation = false  // 是否完成初始动画
}
```

**数据结构说明**:
- **节点**: 使用SKShapeNode创建各种图形元素
- **颜色**: 从活动模板继承，实现主题化
- **水位**: 用0-1的浮点数表示，每10分钟达到100%
- **动画标志**: 区分初始快速填充动画和后续实时更新

### 初始化 (306-320行)

```swift
override init(size: CGSize) {
    super.init(size: size)
    commonInit()
}

required override init?(coder: NSCoder) {
    super.init(coder: coder)
    commonInit()
}

private func commonInit() {
    scaleMode = .resizeFill       // 填充缩放模式
    backgroundColor = .clear       // 透明背景
    physicsWorld.gravity = CGVector(dx: 0, dy: 0)  // 无重力
}
```

**初始化配置**:
- 支持两种初始化方式（代码创建和Interface Builder）
- 设置为填充缩放，适应不同屏幕尺寸
- 透明背景，与SwiftUI背景融合
- 禁用物理引擎重力（手动控制雨滴运动）

### 设置调色板和初始水位 (322-361行)

```swift
func updatePalette(primary: SKColor, accent: SKColor) {
    primaryColor = primary
    accentColor = accent
    updateColors()
}

func setInitialWaterLevel(_ minutes: Int, startTime: Date) {
    guard size.width > 0 else { return }

    removeAllChildren()
    raindrops.removeAll()

    buildContainer()
    buildWater()

    self.startTime = startTime
    self.hasCompletedInitialAnimation = false

    // 从0开始
    currentWaterLevel = 0
    updateWaterHeight(animated: false)

    // 计算目标水位（每10分钟100%）
    let targetLevel = min(CGFloat(minutes) / 10.0, 1.0)
    guard targetLevel > 0 else {
        hasCompletedInitialAnimation = true
        return
    }

    // 用2.5秒动画填充到当前水位
    let duration: TimeInterval = 2.5
    let action = SKAction.customAction(withDuration: duration) { [weak self] _, elapsedTime in
        let progress = elapsedTime / duration
        self?.currentWaterLevel = targetLevel * CGFloat(progress)
        self?.updateWaterHeight(animated: false)
    }
    let completion = SKAction.run { [weak self] in
        self?.hasCompletedInitialAnimation = true
    }
    run(.sequence([action, completion]))
}
```

**初始化逻辑**:
1. 清空所有现有元素
2. 构建容器和水体
3. 计算目标水位：`水位 = min(分钟数 / 10, 1.0)`
   - 例如：5分钟 → 50%水位
   - 例如：15分钟 → 100%水位（上限）
4. 用2.5秒动画从0%填充到目标水位
5. 完成后标记，切换到实时更新模式

### 场景更新循环 (368-389行)

```swift
override func update(_ currentTime: TimeInterval) {
    super.update(currentTime)
    animateWaves()  // 波浪动画

    // 初始动画完成后，持续根据经过时间更新水位
    if hasCompletedInitialAnimation, let start = startTime {
        let elapsed = Date().timeIntervalSince(start)
        let minutes = elapsed / 60.0
        let newLevel = min(CGFloat(minutes / 10.0), 1.0)

        if abs(newLevel - currentWaterLevel) > 0.0001 {
            currentWaterLevel = newLevel
            updateWaterHeight(animated: false)
        }
    }

    // 持续生成雨滴（约66滴/秒）
    if currentTime - lastRaindropTime > 0.015 {
        spawnRaindrop()
        lastRaindropTime = currentTime
    }
}
```

**每帧更新**:
1. **波浪动画**: 每帧更新波浪相位
2. **水位更新**:
   - 只在初始动画完成后执行
   - 根据实际经过时间实时计算水位
   - 仅在变化超过0.0001时更新（优化性能）
3. **雨滴生成**:
   - 每0.015秒生成一个雨滴
   - 约66滴/秒的生成速率

### 构建容器 (393-411行)

```swift
private func buildContainer() {
    guard size.width > 0 else { return }

    let inset: CGFloat = 10
    let rect = CGRect(
        x: inset,
        y: inset,
        width: size.width - inset * 2,
        height: size.height - inset * 2
    )

    let container = SKShapeNode(rect: rect, cornerRadius: 12)
    container.lineWidth = 1.6
    container.strokeColor = primaryColor.withAlphaComponent(0.4)
    container.fillColor = .clear

    containerNode = container
    addChild(container)
}
```

**容器设计**:
- 10点内边距
- 圆角矩形（圆角半径12）
- 半透明主色边框（40%透明度）
- 无填充色（透明）

### 生成雨滴 (413-477行)

这是最复杂的方法之一，负责创建每个雨滴的外观和动画。

```swift
private func spawnRaindrop() {
    guard size.width > 0, size.height > 0 else { return }

    // 随机参数
    let speed = CGFloat.random(in: 250...900)        // 速度：250-900 像素/秒
    let lineWidth = CGFloat.random(in: 1.5...3.0)    // 线宽：1.5-3.0
    let alpha = CGFloat.random(in: 0.12...0.35)      // 透明度：12%-35%

    // 长度基于速度：len = clamp(speed * 0.03, 6, 22)
    let length = min(max(speed * 0.03, 6), 22)

    // 起始位置（顶部随机位置）
    let startX = CGFloat.random(in: 0...size.width)
    let startY = size.height + 10

    // 漂移角度（-10°到+10°）
    let driftAngle = CGFloat.random(in: -10...10) * .pi / 180
    let dx = sin(driftAngle) * length * 0.3
    let dy = -length

    // 创建雨滴路径（一条线段）
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: dx, y: dy))

    let raindrop = SKShapeNode(path: path)
    raindrop.strokeColor = primaryColor.withAlphaComponent(alpha)
    raindrop.lineWidth = lineWidth
    raindrop.lineCap = .round
    raindrop.position = CGPoint(x: startX, y: startY)
    raindrop.zPosition = 10
    raindrop.isAntialiased = true

    // 下落动画
    let fallDistance = size.height + 40
    let duration = TimeInterval(fallDistance / speed)

    let moveX = sin(driftAngle) * fallDistance * 0.15
    let moveY = -fallDistance

    let move = SKAction.moveBy(x: moveX, y: moveY, duration: duration)
    let fadeOut = SKAction.fadeOut(withDuration: duration * 0.3)
    fadeOut.timingMode = .easeIn

    let sequence = SKAction.sequence([
        SKAction.group([move, SKAction.sequence([
            SKAction.wait(forDuration: duration * 0.7),
            fadeOut
        ])]),
        SKAction.removeFromParent(),
        SKAction.run { [weak self] in
            self?.raindrops.removeAll { $0 == raindrop }
        }
    ])

    raindrop.run(sequence)
    addChild(raindrop)
    raindrops.append(raindrop)

    // 限制雨滴数量（性能优化）
    if raindrops.count > 120 {
        raindrops.first?.removeFromParent()
        raindrops.removeFirst()
    }
}
```

**雨滴设计**:
1. **随机化参数**:
   - 速度：250-900像素/秒（产生快慢不同的雨滴）
   - 线宽：1.5-3.0点（粗细不一）
   - 透明度：12%-35%（深浅不一）
   - 长度：根据速度计算，快的雨滴更长（6-22点）

2. **运动轨迹**:
   - 主要是垂直下落
   - 轻微的随机角度漂移（±10°）
   - 水平漂移随下落增加

3. **动画时序**:
   - 前70%时间：正常可见
   - 后30%时间：渐渐淡出（fadeOut）
   - 使用缓入（easeIn）时间函数

4. **性能优化**:
   - 限制最多120个雨滴同时存在
   - 超过时移除最早的雨滴

### 构建水体 (479-497行)

```swift
private func buildWater() {
    let inset: CGFloat = 10

    // 水体
    let water = SKShapeNode()
    water.zPosition = 5
    waterNode = water
    addChild(water)

    // 水面（带波浪）
    let surface = SKShapeNode()
    surface.zPosition = 6
    surface.strokeColor = accentColor.withAlphaComponent(0.7)
    surface.lineWidth = 2.0
    waterSurfaceNode = surface
    addChild(surface)

    updateWaterHeight(animated: false)
}
```

**水体层次**:
- **水体节点** (zPosition: 5): 填充的矩形，表示水的主体
- **水面节点** (zPosition: 6): 波浪线条，在水体上方

### 更新水位高度 (501-529行)

```swift
private func updateWaterHeight(animated: Bool) {
    guard let water = waterNode, let surface = waterSurfaceNode else { return }

    let inset: CGFloat = 10
    let containerHeight = size.height - inset * 2
    let waterHeight = containerHeight * currentWaterLevel

    // 更新水体
    let waterRect = CGRect(
        x: inset,
        y: inset,
        width: size.width - inset * 2,
        height: waterHeight
    )

    let waterPath = CGPath(
        roundedRect: waterRect,
        cornerWidth: 12,
        cornerHeight: 12,
        transform: nil
    )

    water.path = waterPath
    water.fillColor = primaryColor.withAlphaComponent(0.35)
    water.strokeColor = .clear

    // 更新水面波浪
    updateWavePath()
}
```

**水位计算**:
- 容器高度 = 总高度 - 上下内边距(20)
- 水体高度 = 容器高度 × 当前水位(0-1)
- 从底部向上填充
- 半透明主色填充（35%透明度）

### 波浪动画 (531-568行)

```swift
private func animateWaves() {
    wavePhase += 0.03
    updateWavePath()
}

private func updateWavePath() {
    guard let surface = waterSurfaceNode else { return }

    let inset: CGFloat = 10
    let containerHeight = size.height - inset * 2
    let baseY = inset + containerHeight * currentWaterLevel

    guard currentWaterLevel > 0.01 else {
        surface.path = nil
        return
    }

    // 创建波浪线
    let path = CGMutablePath()
    let waveAmplitude: CGFloat = 3.0      // 振幅3点
    let waveFrequency: CGFloat = 4.0      // 4个完整波浪
    let segments = 60                     // 60个线段

    for i in 0...segments {
        let t = CGFloat(i) / CGFloat(segments)
        let x = inset + t * (size.width - inset * 2)
        let wave = sin((t * waveFrequency + wavePhase) * .pi * 2) * waveAmplitude
        let y = baseY + wave

        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }

    surface.path = path
}
```

**波浪效果**:
- **公式**: `y = baseY + amplitude × sin(2π × (frequency × t + phase))`
- **振幅**: 3点（波浪高度）
- **频率**: 4（横跨宽度有4个完整波浪）
- **相位**: 每帧增加0.03，产生流动效果
- **分段**: 60个点连成的平滑曲线

### 辅助方法 (570-591行)

```swift
private func updateColors() {
    containerNode?.strokeColor = primaryColor.withAlphaComponent(0.4)
    waterNode?.fillColor = primaryColor.withAlphaComponent(0.35)
    waterSurfaceNode?.strokeColor = accentColor.withAlphaComponent(0.7)
}

private func rebuildAll() {
    let savedStartTime = startTime
    let savedCompleted = hasCompletedInitialAnimation
    let savedLevel = currentWaterLevel

    removeAllChildren()
    raindrops.removeAll()
    buildContainer()
    buildWater()

    startTime = savedStartTime
    hasCompletedInitialAnimation = savedCompleted
    currentWaterLevel = savedLevel
    updateWaterHeight(animated: false)
}
```

**重建逻辑**:
- 保存当前状态（开始时间、水位等）
- 清空所有元素
- 重新构建
- 恢复保存的状态
- 用于处理尺寸变化等情况

---

## 辅助组件

### SKColor 扩展 (596-619行)

提供颜色处理的辅助方法。

```swift
extension SKColor {
    // 提亮颜色
    func lifted(_ amount: CGFloat = 0.18) -> SKColor {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)

        let adjust: (CGFloat) -> CGFloat = { value in
            min(max(value + amount, 0), 1)
        }

        return SKColor(red: adjust(r), green: adjust(g), blue: adjust(b), alpha: a)
    }

    // 转换为SwiftUI Color
    func toColor() -> Color {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }
}
```

**方法说明**:
- `lifted()`: 将RGB各分量增加指定值（默认0.18），用于创建更亮的强调色
- `toColor()`: 将SKColor转换为SwiftUI的Color类型

### SummaryView - 摘要视图 (623-709行)

完成追踪后显示的摘要界面。

```swift
struct SummaryView: View {
    let startTime: Date
    let endTime: Date
    let duration: TimeInterval
    let taskName: String

    @Environment(\.dismiss) private var dismiss

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }

    private var durationString: String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%dh %dm %ds", hours, minutes, seconds)
        } else if minutes > 0 {
            return String(format: "%dm %ds", minutes, seconds)
        } else {
            return String(format: "%ds", seconds)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("完成")
                    .font(.title2)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 16) {
                    InfoRow(
                        label: "任务",
                        value: taskName,
                        icon: "checkmark.circle.fill"
                    )

                    Divider()

                    InfoRow(
                        label: "开始",
                        value: timeFormatter.string(from: startTime),
                        icon: "play.circle"
                    )

                    InfoRow(
                        label: "结束",
                        value: timeFormatter.string(from: endTime),
                        icon: "stop.circle"
                    )

                    Divider()

                    InfoRow(
                        label: "总时长",
                        value: durationString,
                        icon: "timer"
                    )
                }
                .padding()
                .background(Color.white.opacity(0.1))
                .cornerRadius(12)

                Button {
                    dismiss()
                } label: {
                    Text("完成")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding()
        }
    }
}
```

**显示内容**:
1. 标题："完成"
2. 任务信息卡片：
   - 任务名称
   - 开始时间（短时间格式）
   - 结束时间（短时间格式）
   - 总时长（智能格式：根据时长显示时/分/秒）
3. 完成按钮（绿色）

### InfoRow - 信息行组件 (711-734行)

```swift
struct InfoRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.blue)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.body)
                    .fontWeight(.medium)
            }

            Spacer()
        }
    }
}
```

**布局**:
- 左侧：蓝色图标
- 中间：上下两行文字（标签+值）
- 右侧：弹性空间

---

## 总结

### 核心功能流程

1. **启动应用** → 显示 `ContentView`
2. **无活跃计时** → 显示 `ActivityCrownPickerView`
3. **转动表冠** → 浏览不同活动模板
4. **点击开始** → 调用 `dataManager.startTracking()`
5. **切换到** `ActiveTimerView`
6. **雨景初始化** → 2.5秒动画填充到当前水位
7. **实时更新** → 水位随时间上升（每10分钟100%）
8. **长按3秒** → 显示停止进度边框
9. **松开** → 进度归零
10. **完成长按** → 显示 `SummaryView`
11. **关闭摘要** → 停止追踪，返回选择器

### 关键技术点

| 技术 | 应用场景 |
|------|----------|
| **@StateObject** | 管理数据管理器的生命周期 |
| **@State** | 追踪局部UI状态（选择索引、进度等） |
| **@FocusState** | 控制表冠输入焦点 |
| **@Namespace** | 实现matchedGeometryEffect动画 |
| **NavigationStack** | 管理视图导航 |
| **GeometryReader** | 获取可用空间尺寸 |
| **SpriteKit** | 实现雨滴和水位动画 |
| **SKAction** | 编排复杂动画序列 |
| **LongPressGesture** | 实现长按停止功能 |
| **Sheet** | 显示模态摘要视图 |

### 设计亮点

1. **隐藏选择器技巧**: 使用几乎不可见的Picker捕获表冠输入，同时显示自定义UI
2. **水位时间映射**: 用水位高度直观表示时间流逝（每10分钟100%）
3. **初始动画优化**: 快速填充到当前水位，然后切换到实时更新
4. **雨滴随机化**: 速度、长度、粗细、透明度的随机化创造自然效果
5. **长按防误触**: 3秒长按时间避免意外停止
6. **进度可视化**: 红色边框实时显示长按进度
7. **性能优化**: 限制雨滴数量、只在变化时更新水位

### 文件结构概览

```
ContentView.swift (735行)
├── ContentView (11-27)                    # 根视图
├── ActivityCrownPickerView (29-159)      # 活动选择器
│   ├── currentCard()                      # 卡片视图
│   ├── startButton()                      # 开始按钮
│   ├── emptyState                         # 空状态
│   └── wheelPickerOverlay()               # 隐藏选择器
├── ActiveTimerView (161-282)             # 计时器视图
│   ├── rainPage                           # 雨滴页面
│   └── rainStage()                        # 雨滴舞台
├── RainScene (290-592)                   # SpriteKit场景
│   ├── 初始化方法
│   ├── setInitialWaterLevel()             # 设置初始水位
│   ├── update()                           # 每帧更新
│   ├── buildContainer()                   # 构建容器
│   ├── spawnRaindrop()                    # 生成雨滴
│   ├── buildWater()                       # 构建水体
│   ├── updateWaterHeight()                # 更新水位
│   ├── animateWaves()                     # 波浪动画
│   └── updateWavePath()                   # 更新波浪路径
├── SKColor Extension (596-619)           # 颜色扩展
├── SummaryView (623-709)                 # 摘要视图
└── InfoRow (711-734)                     # 信息行组件
```

---

**文档版本**: 1.0
**创建日期**: 2025-12-16
**适用于**: Done Watch App ContentView.swift
