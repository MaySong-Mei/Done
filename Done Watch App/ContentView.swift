//
//  ContentView.swift
//  Done Watch App
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI
import SpriteKit
import UIKit

struct ContentView: View {
    @StateObject private var dataManager = DataManager.shared

    var body: some View {
        NavigationStack {
            if let activeEntry = dataManager.activeEntry {
                ActiveTimerView(entry: activeEntry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ActivityCrownPickerView()
            }
        }
        .ignoresSafeArea(.all)
        .onAppear {
            WatchConnectivityManager.shared.requestTemplates()
        }
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
    }
}

struct ActivityCrownPickerView: View {
    @StateObject private var dataManager = DataManager.shared
    @State private var selectedIndex: Int = 0
    @State private var crownValue: Double = 0
    @Namespace private var cardNamespace

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
        .focusable(true)
        .digitalCrownRotation(
            $crownValue,
            from: 0,
            through: Double(max(templates.count - 1, 0)),
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownValue) { _, newValue in
            selectedIndex = Int(newValue.rounded())
        }
        .onChange(of: dataManager.templates.count) { _, _ in
            clampSelection()
            crownValue = Double(selectedIndex)
        }
        .onAppear {
            clampSelection()
            crownValue = Double(selectedIndex)
        }
    }

    private func currentCard(for template: ActivityTemplate) -> some View {
        let blockColor = Color(hex: "#303030") ?? Color(red: 48/255, green: 48/255, blue: 48/255)

        return VStack(spacing: 8) {
            if !template.icon.isEmpty {
                Image(systemName: template.icon)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .matchedGeometryEffect(id: "icon\(template.id)", in: cardNamespace)
            }

            Text(template.name)
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .matchedGeometryEffect(id: "title\(template.id)", in: cardNamespace)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .padding(.horizontal, 6)
        .background(
            ZStack {
                blockColor
                template.color.opacity(0.15)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: blockColor.opacity(0.35), radius: 12, x: 0, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: selectedIndex)
    }

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

    private var currentTemplate: ActivityTemplate? {
        guard dataManager.templates.indices.contains(selectedIndex) else { return nil }
        return dataManager.templates[selectedIndex]
    }

    private func clampSelection() {
        let maxIndex = max(dataManager.templates.count - 1, 0)
        selectedIndex = min(selectedIndex, maxIndex)
    }
}

struct ActiveTimerView: View {
    let entry: TimeEntry
    @StateObject private var dataManager = DataManager.shared
    @State private var rainScene = RainScene(size: CGSize(width: 180, height: 180))
    @State private var stopProgress: CGFloat = 0
    @State private var showSummary = false
    @State private var summaryData: (start: Date, end: Date, duration: TimeInterval, name: String)?
    @State private var longPressTimer: Timer?
    @State private var pressStartTime: Date?

    private let stopHoldDuration: TimeInterval = 2.0

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            rainScene.updatePalette(
                primary: SKColor(hex: entry.colorHex) ?? SKColor.cyan,
                accent: SKColor(hex: entry.colorHex)?.lifted() ?? SKColor.blue
            )
            rainScene.initialize()
        }
        .sheet(isPresented: $showSummary, onDismiss: {
            // Stop tracking when summary is dismissed
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

    private var rainPage: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            ZStack {
                // 全屏舞台
                SpriteView(scene: rainScene)
                    .frame(width: w, height: h)
                    .ignoresSafeArea()

                // 全屏 Stop progress border
                if stopProgress > 0.01 {
                    let lineWidth: CGFloat = 6

                    StartAtTopRoundedRect(cornerRadius: 49)
                        .inset(by: lineWidth / 2)
                        .trim(from: 0, to: stopProgress)
                        .stroke(
                            templateColor.opacity(0.8),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                        )
                        .frame(width: w, height: h)
                }
            }
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .onAppear {
                // 初始化时设置正确的 scene 尺寸
                updateSceneSize(width: w, height: h)
            }
            .onChange(of: proxy.size) { _, newSize in
                // 尺寸变化时更新 scene
                updateSceneSize(width: newSize.width, height: newSize.height)
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: stopHoldDuration)
                    .onChanged { _ in
                        if pressStartTime == nil {
                            pressStartTime = Date()
                            startProgressTimer()
                        }
                    }
                    .onEnded { _ in
                        stopProgressTimer()
                        let endTime = Date()
                        let duration = endTime.timeIntervalSince(entry.startTime)
                        summaryData = (start: entry.startTime, end: endTime, duration: duration, name: entry.templateName)
                        showSummary = true
                        stopProgress = 0
                        pressStartTime = nil
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if pressStartTime == nil {
                            pressStartTime = Date()
                            startProgressTimer()
                        }
                    }
                    .onEnded { _ in
                        stopProgressTimer()
                        stopProgress = 0
                        pressStartTime = nil
                    }
            )
        }
        .ignoresSafeArea()
    }


    private var templateColor: Color {
        Color(hex: entry.colorHex) ?? .blue
    }

    private func updateSceneSize(width: CGFloat, height: CGFloat) {
        guard width > 0 && height > 0 else { return }
        let newSize = CGSize(width: width, height: height)
        if rainScene.size != newSize {
            rainScene.size = newSize
        }
    }

    private func startProgressTimer() {
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            guard let startTime = pressStartTime else { return }
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(elapsed / stopHoldDuration, 1.0)
            stopProgress = CGFloat(progress)
        }
    }

    private func stopProgressTimer() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }
}

// MARK: - Custom Shape for Progress Border

struct StartAtTopRoundedRect: InsettableShape {
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let cr = min(cornerRadius, min(r.width, r.height) / 2)

        let minX = r.minX, maxX = r.maxX
        let minY = r.minY, maxY = r.maxY
        let midX = r.midX

        var p = Path()

        // 从 12 点（上边中点）开始，顺时针走一圈
        p.move(to: CGPoint(x: midX, y: minY))

        // 上边到右上角圆弧起点
        p.addLine(to: CGPoint(x: maxX - cr, y: minY))
        // 右上角圆弧
        p.addArc(
            center: CGPoint(x: maxX - cr, y: minY + cr),
            radius: cr,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )

        // 右边到右下角
        p.addLine(to: CGPoint(x: maxX, y: maxY - cr))
        // 右下角圆弧
        p.addArc(
            center: CGPoint(x: maxX - cr, y: maxY - cr),
            radius: cr,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )

        // 下边到左下角
        p.addLine(to: CGPoint(x: minX + cr, y: maxY))
        // 左下角圆弧
        p.addArc(
            center: CGPoint(x: minX + cr, y: maxY - cr),
            radius: cr,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )

        // 左边到左上角
        p.addLine(to: CGPoint(x: minX, y: minY + cr))
        // 左上角圆弧（回到上边）
        p.addArc(
            center: CGPoint(x: minX + cr, y: minY + cr),
            radius: cr,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )

        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var s = self
        s.insetAmount += amount
        return s
    }
}

#Preview {
    ContentView()
}

// MARK: - Rain Scene

final class RainScene: SKScene {
    // Raindrop management
    private struct Raindrop {
        let node: SKShapeNode
        var velocity: CGVector
        let alpha: CGFloat
    }

    private var raindrops: [Raindrop] = []
    private var lastRaindropTime: TimeInterval = 0

    // Water system
    private var waterLevel: CGFloat = 0 // 0.0 to 1.0
    private var maxWaterHeight: CGFloat = 0
    private var waterNode: SKShapeNode?
    private var surfaceNode: SKShapeNode?
    private var surfacePhase: CGFloat = 0
    private var previousWaterLevel: CGFloat = 0  // Track to detect when reaching 100%
    // Water animation cycle
    private let waterMinLevel: CGFloat = 0.25
    private let waterMaxLevel: CGFloat = 0.75
    private let waterRiseDuration: TimeInterval = 10
    private let waterFallDuration: TimeInterval = 10
    private var waterCycleTime: TimeInterval = 0

    // Ripple pool
    private var ripplePool: [SKShapeNode] = []
    private var activeRipples: Set<SKShapeNode> = []

    // Decorations (Emoji sprites)
    enum DecorationType: CaseIterable {
        case weed, shell, fish, crab, tropicalFish, puffer, coral

        var emoji: String {
            switch self {
            case .weed: return "🌿"
            case .shell: return "🐚"
            case .fish: return "🐟"
            case .crab: return "🦀"
            case .tropicalFish: return "🐠"
            case .puffer: return "🐡"
            case .coral: return "🪸"
            }
        }

        var baseSize: CGFloat {
            switch self {
            case .shell: return 30
            case .coral: return 32
            case .weed, .crab: return 34
            default: return 36
            }
        }

        var scaleRange: ClosedRange<CGFloat> {
            switch self {
            case .shell: return 0.45...0.65
            case .coral: return 0.75...0.9
            case .weed: return 0.55...0.75
            case .crab: return 0.55...0.65
            default: return 0.55...0.85
            }
        }

        var rotationRange: ClosedRange<CGFloat> {
            switch self {
            case .fish, .tropicalFish, .puffer: return -10...10
            default: return -8...8
            }
        }

        var alpha: CGFloat {
            switch self {
            case .shell: return 0.9
            case .coral: return 0.95
            default: return 0.95
            }
        }

        var anchorPoint: CGPoint {
            switch self {
            case .shell, .weed, .crab, .coral:
                return CGPoint(x: 0.5, y: 0)
            default:
                return CGPoint(x: 0.5, y: 0.5)
            }
        }
    }

    private struct Decoration {
        let type: DecorationType
        let x: CGFloat
        let node: SKNode
    }

    private var decorations: [Decoration] = []
    private var emojiTextureCache: [DecorationType: SKTexture] = [:]

    // MARK: - Fish System (emoji)

    private struct Fish {
        let node: SKSpriteNode
        var baseY: CGFloat
        var speed: CGFloat
        var direction: CGFloat
        var phase: CGFloat
        var amplitude: CGFloat
    }

    private var fishes: [Fish] = []
    private var nextFishTime: TimeInterval = 0
    private let maxFishCount = 100
    private let swimmingFishTypes: [DecorationType] = [.fish, .tropicalFish, .puffer]

    // Colors
    private var primaryColor: SKColor = .cyan
    private var accentColor: SKColor = .blue

    // Wave noise (pre-generated phases)
    private let waveOffsets: [CGFloat] = (0..<5).map { _ in CGFloat.random(in: 0...(.pi * 2)) }

    // Time tracking
    private var lastUpdateTime: TimeInterval = 0

    override init(size: CGSize) {
        super.init(size: size)
        commonInit()
    }

    required override init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        scaleMode = .resizeFill
        backgroundColor = .clear
        physicsWorld.gravity = CGVector(dx: 0, dy: 0)
    }

    func updatePalette(primary: SKColor, accent: SKColor) {
        primaryColor = primary
        accentColor = accent
        updateWaterColors()
    }

    func initialize() {
        guard size.width > 0 else { return }

        removeAllChildren()
        raindrops.removeAll()
        activeRipples.removeAll()
        decorations.removeAll()
        fishes.removeAll()
        nextFishTime = 0

        maxWaterHeight = size.height
        waterLevel = waterMinLevel
        previousWaterLevel = waterMinLevel
        waterCycleTime = 0
        lastUpdateTime = 0
        decorationAccumulator = 0
        minuteAccumulator = 0

        buildWaterSystem()
        createRipplePool()
    }

    func setProgress(_ progress: CGFloat) {
        waterLevel = min(max(progress, 0), 1.0)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        rebuildAll()
    }

    override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)

        let dt = lastUpdateTime > 0 ? currentTime - lastUpdateTime : 0
        lastUpdateTime = currentTime

        // Water level: 0.25 -> 0.75 in 60s, then 0.75 -> 0.25 in 60s (loop)
        let cycle = waterRiseDuration + waterFallDuration
        if dt > 0 {
            waterCycleTime += dt
        }
        let t = waterCycleTime.truncatingRemainder(dividingBy: cycle)

        if t < waterRiseDuration {
            let p = CGFloat(t / waterRiseDuration) // 0..1
            waterLevel = waterMinLevel + p * (waterMaxLevel - waterMinLevel)
        } else {
            let p = CGFloat((t - waterRiseDuration) / waterFallDuration) // 0..1
            waterLevel = waterMaxLevel - p * (waterMaxLevel - waterMinLevel)
        }

        previousWaterLevel = waterLevel

        // Update water visuals
        updateWaterHeight()
        updateWaveSurface(dt: dt)

        // Update raindrops manually
        updateRaindrops(dt: dt)

        // Update fish
        spawnOneThingPerMinute(dt: dt)
        updateFish(dt: dt)

        // Spawn new raindrops
        if currentTime - lastRaindropTime > 0.015 {
            spawnRaindrop()
            lastRaindropTime = currentTime
        }
    }

    // MARK: - Water System

    private func buildWaterSystem() {
        // Water body
        let water = SKShapeNode()
        water.zPosition = 5
        water.fillColor = accentColor.withAlphaComponent(0.5)
        water.strokeColor = .clear
        waterNode = water
        addChild(water)

        // Water surface
        let surface = SKShapeNode()
        surface.zPosition = 6
        surface.strokeColor = accentColor.withAlphaComponent(0.8)
        surface.lineWidth = 2.0
        surface.lineCap = .round
        surfaceNode = surface
        addChild(surface)
    }

    private func updateWaterHeight() {
        guard let water = waterNode else { return }

        let h = maxWaterHeight * waterLevel
        if h <= 0.5 {
            water.path = nil
            return
        }

        // Water body from y=0 upward, full width
        let rect = CGRect(x: 0, y: 0, width: size.width, height: h)
        water.path = CGPath(rect: rect, transform: nil)
    }

    private func updateWaveSurface(dt: TimeInterval) {
        guard let surface = surfaceNode else { return }

        let waterY = getWaterSurfaceY()
        guard waterY > 1 else {
            surface.path = nil
            return
        }

        surfacePhase += CGFloat(dt) * 2.0

        let segments = 14
        let path = CGMutablePath()

        for i in 0...segments {
            let t = CGFloat(i) / CGFloat(segments)
            let x = t * size.width

            // Multi-frequency wave (more natural)
            var wave: CGFloat = 0
            wave += sin((t * 3.0 + surfacePhase) * .pi * 2 + waveOffsets[0]) * 1.2
            wave += sin((t * 5.0 + surfacePhase * 0.7) * .pi * 2 + waveOffsets[1]) * 0.7
            wave += sin((t * 7.0 - surfacePhase * 0.5) * .pi * 2 + waveOffsets[2]) * 0.4

            let y = waterY + wave

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        surface.path = path
    }

    private func updateWaterColors() {
        waterNode?.fillColor = accentColor.withAlphaComponent(0.30)
        surfaceNode?.strokeColor = accentColor.withAlphaComponent(0.55)
        surfaceNode?.lineWidth = 1.8
    }

    private func getWaterSurfaceY() -> CGFloat {
        return maxWaterHeight * waterLevel
    }

    // MARK: - Ripple System

    private func createRipplePool() {
        for _ in 0..<12 {
            let ripple = SKShapeNode(circleOfRadius: 1)
            ripple.strokeColor = .white
            ripple.fillColor = .clear
            ripple.lineWidth = 1.5
            ripple.isHidden = true
            ripple.zPosition = 7
            addChild(ripple)
            ripplePool.append(ripple)
        }
    }

    private func spawnRipple(at point: CGPoint) {
        guard let ripple = ripplePool.first(where: { !activeRipples.contains($0) }) else { return }

        activeRipples.insert(ripple)
        ripple.isHidden = false
        ripple.position = point
        ripple.alpha = 0.6
        ripple.setScale(0.1)

        let expand = SKAction.scale(to: 3.5, duration: 0.6)
        expand.timingMode = .easeOut

        let fade = SKAction.fadeOut(withDuration: 0.6)
        fade.timingMode = .easeOut

        let cleanup = SKAction.run { [weak self, weak ripple] in
            guard let ripple = ripple else { return }
            ripple.isHidden = true
            ripple.setScale(1)
            self?.activeRipples.remove(ripple)
        }

        ripple.run(.sequence([.group([expand, fade]), cleanup]))
    }

    private func spawnOneThingPerMinute(dt: TimeInterval) {
        guard dt > 0 else { return }
        minuteAccumulator += dt

        while minuteAccumulator >= minuteInterval {
            minuteAccumulator -= minuteInterval
            spawnMinuteEvent()
        }
    }

    private func spawnMinuteEvent() {
        let waterY = getWaterSurfaceY()

        let fishChance: Double = 0.7

        if Double.random(in: 0...1) < fishChance {
            spawnSwimmingFishAtMinute(waterY: waterY)
        } else {
            spawnBottomDecorationAtMinute(waterY: waterY)
        }
    }


    private func spawnSwimmingFishAtMinute(waterY: CGFloat) {
        if fishes.count >= maxFishCount, let first = fishes.first {
            fishes.removeFirst()
            first.node.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
        }

        spawnFish(waterY: waterY)
    }

    private func spawnBottomDecorationAtMinute(waterY: CGFloat) {
        let bottomTypes: [DecorationType] = [.shell, .coral, .crab, .weed]
        let type = bottomTypes.randomElement() ?? .shell

        let x = CGFloat.random(in: size.width * 0.15...size.width * 0.85)

        guard let node = createDecorationNode(for: type, at: x) else { return }

        node.position.y = 0
        node.zPosition = 4

        addChild(node)
        decorations.append(Decoration(type: type, x: x, node: node))

        if decorations.count > maxBottomDecorations {
            let old = decorations.removeFirst()
            old.node.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
        }
    }

    // Timed decoration spawning
    private var decorationAccumulator: TimeInterval = 0
    private let decorationInterval: TimeInterval = 60
    private let maxDecorations: Int = 200
    // MARK: - Minute scheduler
    private var minuteAccumulator: TimeInterval = 0
    private let minuteInterval: TimeInterval = 10
    private let maxBottomDecorations = 100

    // MARK: - Decoration System

    private func spawnDecoration() {
        let type = DecorationType.allCases.randomElement() ?? .fish
        let x = CGFloat.random(in: size.width * 0.15...size.width * 0.85)

        guard let node = createDecorationNode(for: type, at: x) else { return }

        addChild(node)

        let decoration = Decoration(type: type, x: x, node: node)
        decorations.append(decoration)
    }

    private func createDecorationNode(for type: DecorationType, at x: CGFloat) -> SKNode? {
        guard let texture = emojiTexture(for: type) else { return nil }
        let sprite = SKSpriteNode(texture: texture)
        sprite.anchorPoint = type.anchorPoint
        sprite.setScale(CGFloat.random(in: type.scaleRange))
        sprite.zRotation = CGFloat.random(in: type.rotationRange) * (.pi / 180)
        sprite.alpha = type.alpha
        sprite.zPosition = 4  // Below water body (z=5)
        sprite.color = accentColor
        sprite.colorBlendFactor = 0.1

        let waterHeight = getWaterSurfaceY()
        sprite.position = CGPoint(x: x, y: decorationBaseY(for: type, waterHeight: waterHeight))

        return sprite
    }

    private func decorationBaseY(for type: DecorationType, waterHeight: CGFloat) -> CGFloat {
        switch type {
        case .shell, .weed, .crab, .coral:
            let upper = max(10, waterHeight * 0.25)
            return CGFloat.random(in: 0...upper)
        default:
            let lower = max(8, waterHeight * 0.3)
            let upper = max(lower + 8, waterHeight * 0.9)
            return CGFloat.random(in: lower...upper)
        }
    }

    private func emojiTexture(for type: DecorationType) -> SKTexture? {
        if let cached = emojiTextureCache[type] {
            return cached
        }

        guard let image = emojiImage(for: type.emoji, size: type.baseSize) else {
            return nil
        }

        let texture = SKTexture(image: image)
        emojiTextureCache[type] = texture
        return texture
    }

    private func emojiImage(for emoji: String, size: CGFloat) -> UIImage? {
        let font = UIFont.systemFont(ofSize: size)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]

        let text = NSString(string: emoji)
        let measured = text.size(withAttributes: attributes)
        let canvasSize = CGSize(
            width: ceil(measured.width) + 6,
            height: ceil(measured.height) + 6
        )

        UIGraphicsBeginImageContextWithOptions(canvasSize, false, 0)
        defer { UIGraphicsEndImageContext() }

        let drawRect = CGRect(
            x: (canvasSize.width - measured.width) / 2,
            y: (canvasSize.height - measured.height) / 2,
            width: measured.width,
            height: measured.height
        )
        text.draw(in: drawRect, withAttributes: attributes)

        return UIGraphicsGetImageFromCurrentImageContext()
    }

    // MARK: - Fish System

    private func maybeSpawnFish(currentTime: TimeInterval) {
        let waterY = getWaterSurfaceY()
        guard waterY > 40 else {
            if !fishes.isEmpty {
                for f in fishes {
                    f.node.run(.sequence([.fadeOut(withDuration: 0.25), .removeFromParent()]))
                }
                fishes.removeAll()
            }
            return
        }

        guard fishes.count < maxFishCount else { return }
        if currentTime < nextFishTime { return }
        nextFishTime = currentTime + TimeInterval(CGFloat.random(in: 4.0...7.0))
        guard Double.random(in: 0...1) < 0.7 else { return }

        spawnFish(waterY: waterY)
    }

    private func spawnFish(waterY: CGFloat) {
        let type = swimmingFishTypes.randomElement() ?? .fish
        guard let texture = emojiTexture(for: type) else { return }

        let node = SKSpriteNode(texture: texture)
        node.zPosition = 5.4
        node.alpha = CGFloat.random(in: 0.65...0.9)

        node.setScale(CGFloat.random(in: 0.55...0.75))

        let dir: CGFloat = Bool.random() ? 1 : -1
        let speed = CGFloat.random(in: 18...42)

        let minY = max(10, waterY * 0.25)
        let maxY = max(minY + 8, waterY * 0.75)
        let baseY = CGFloat.random(in: minY...maxY)

        let startX: CGFloat = dir > 0 ? -30 : (size.width + 30)
        node.position = CGPoint(x: startX, y: baseY)

        node.xScale = abs(node.xScale) * (dir > 0 ? -1 : 1)

        addChild(node)

        let fish = Fish(
            node: node,
            baseY: baseY,
            speed: speed,
            direction: dir,
            phase: CGFloat.random(in: 0...(2 * .pi)),
            amplitude: CGFloat.random(in: 1.5...4.5)
        )
        fishes.append(fish)

        node.alpha = 0
        node.run(.fadeIn(withDuration: 0.25))
    }

    private func updateFish(dt: TimeInterval) {
        guard dt > 0 else { return }
        let waterY = getWaterSurfaceY()
        guard waterY > 40 else { return }

        let topMargin: CGFloat = 10
        let bottomMargin: CGFloat = 8
        let minY = bottomMargin + 2
        let maxY = max(minY + 10, waterY - topMargin)

        for i in fishes.indices {
            var f = fishes[i]
            let node = f.node

            node.position.x += f.direction * f.speed * CGFloat(dt)

            f.phase += CGFloat(dt) * 2.2
            var y = f.baseY + sin(f.phase) * f.amplitude

            y = min(max(y, minY), maxY)
            node.position.y = y

            let depthT = (maxY - y) / max(1, (maxY - minY))
            node.alpha = 0.55 + (1 - depthT) * 0.25

            if node.position.x > size.width + 30 {
                node.position.x = -30
            } else if node.position.x < -30 {
                node.position.x = size.width + 30
            }

            if Double.random(in: 0...1) < 0.005 {
                f.speed = min(max(f.speed + CGFloat.random(in: -6...6), 14), 55)
            }

            fishes[i] = f
        }
    }

    // MARK: - Raindrop System

    private func spawnRaindrop() {
        guard size.width > 0, size.height > 0 else { return }

        if raindrops.count >= 120 {
            raindrops.first?.node.removeFromParent()
            raindrops.removeFirst()
        }

        // Random parameters
        let speed = CGFloat.random(in: 250...900)
        let lineWidth = CGFloat.random(in: 1.5...3.0)
        let alpha = CGFloat.random(in: 0.12...0.35)
        let length = min(max(speed * 0.03, 6), 22)

        // Starting position
        let startX = CGFloat.random(in: 0...size.width)
        let startY = size.height + 10

        // Drift
        let driftAngle = CGFloat.random(in: -10...10) * .pi / 180
        let sinDrift = sin(driftAngle)
        let driftX = sinDrift * 50 // horizontal drift speed

        // Create raindrop
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: sinDrift * length * 0.3, y: -length))

        let node = SKShapeNode(path: path)
        node.strokeColor = primaryColor.withAlphaComponent(alpha)
        node.lineWidth = lineWidth
        node.lineCap = .round
        node.position = CGPoint(x: startX, y: startY)
        node.zPosition = 10
        node.isAntialiased = true

        addChild(node)

        let raindrop = Raindrop(
            node: node,
            velocity: CGVector(dx: driftX, dy: -speed),
            alpha: alpha
        )

        raindrops.append(raindrop)
    }

    private func updateRaindrops(dt: TimeInterval) {
        let waterY = getWaterSurfaceY()
        var toRemove: [Int] = []

        for (index, raindrop) in raindrops.enumerated() {
            var drop = raindrop
            let node = drop.node

            // Update position
            node.position.x += drop.velocity.dx * CGFloat(dt)
            node.position.y += drop.velocity.dy * CGFloat(dt)

            // Check if hit water
            if waterLevel > 0.01 && node.position.y <= waterY {
                let clampedX = min(max(node.position.x, 0), size.width)
                spawnRipple(at: CGPoint(x: clampedX, y: waterY))
                toRemove.append(index)
                node.removeFromParent()
                continue
            }

            // Check if off screen
            if node.position.y < -20 || node.position.x < -50 || node.position.x > size.width + 50 {
                toRemove.append(index)
                node.removeFromParent()
                continue
            }

            // Fade out near bottom (when no water)
            if waterLevel < 0.01 && node.position.y < 30 {
                let fadeProgress = max(0, node.position.y / 30)
                node.alpha = drop.alpha * fadeProgress
            }

            raindrops[index] = drop
        }

        // Remove in reverse order
        for i in toRemove.reversed() {
            raindrops.remove(at: i)
        }
    }

    // MARK: - Rebuild

    private func rebuildAll() {
        let savedLevel = waterLevel

        removeAllChildren()
        raindrops.removeAll()
        activeRipples.removeAll()
        decorations.removeAll()
        fishes.removeAll()
        nextFishTime = 0
        minuteAccumulator = 0

        maxWaterHeight = size.height
        waterLevel = savedLevel

        buildWaterSystem()
        createRipplePool()
    }
}

// MARK: - Helpers

extension SKColor {
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

    func toColor() -> Color {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }
}

// MARK: - Summary View

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
                Text("Complete")
                    .font(.title2)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 16) {
                    // Task name
                    InfoRow(
                        label: "Task",
                        value: taskName,
                        icon: "checkmark.circle.fill"
                    )

                    Divider()

                    // Start time
                    InfoRow(
                        label: "Started",
                        value: timeFormatter.string(from: startTime),
                        icon: "play.circle"
                    )

                    // End time
                    InfoRow(
                        label: "Ended",
                        value: timeFormatter.string(from: endTime),
                        icon: "stop.circle"
                    )

                    Divider()

                    // Total duration
                    InfoRow(
                        label: "Duration",
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
                    Text("Done")
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
