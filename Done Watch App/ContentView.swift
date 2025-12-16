//
//  ContentView.swift
//  Done Watch App
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI
import SpriteKit

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

    private let stopHoldDuration: TimeInterval = 3.0

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
            let size = min(proxy.size.width, proxy.size.height) * 1.1
            let cornerRadius: CGFloat = 28

            ZStack(alignment: .center) {
                // Rain stage
                rainStage(size: size, cornerRadius: cornerRadius)

                // Stop progress border (follows rain frame shape)
                if stopProgress > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .trim(from: 0, to: stopProgress)
                        .stroke(Color.red.opacity(0.9), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
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
                    // Save summary data and show summary (stop tracking when dismissed)
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
        }
    }

    private func rainStage(size: CGFloat, cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.white.opacity(0.08))

            SpriteView(scene: rainScene)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.white.opacity(0.3), lineWidth: 2.5)
        )
    }

    private var templateColor: Color {
        Color(hex: entry.colorHex) ?? .blue
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

    // Ripple pool
    private var ripplePool: [SKShapeNode] = []
    private var activeRipples: Set<SKShapeNode> = []

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

        maxWaterHeight = size.height * 0.35
        waterLevel = 0

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

        // Update water level (auto-grow at 0.003/sec if not set externally)
        if waterLevel < 1.0 {
            waterLevel = min(waterLevel + CGFloat(dt) * 0.003, 1.0)
        }

        // Update water visuals
        updateWaterHeight()
        updateWaveSurface(dt: dt)

        // Update raindrops manually
        updateRaindrops(dt: dt)

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

        let currentHeight = maxWaterHeight * waterLevel
        guard currentHeight > 0 else {
            water.path = nil
            return
        }

        let inset: CGFloat = 10
        let waterRect = CGRect(
            x: inset,
            y: inset,
            width: size.width - inset * 2,
            height: currentHeight
        )

        water.path = CGPath(
            roundedRect: waterRect,
            cornerWidth: 24,
            cornerHeight: 24,
            transform: nil
        )
    }

    private func updateWaveSurface(dt: TimeInterval) {
        guard let surface = surfaceNode else { return }

        let currentHeight = maxWaterHeight * waterLevel
        guard currentHeight > 1 else {
            surface.path = nil
            return
        }

        surfacePhase += CGFloat(dt) * 2.0

        let inset: CGFloat = 10
        let baseY = inset + currentHeight
        let segments = 12
        let path = CGMutablePath()

        for i in 0...segments {
            let t = CGFloat(i) / CGFloat(segments)
            let x = inset + t * (size.width - inset * 2)

            // Multi-frequency wave (more natural)
            var wave: CGFloat = 0
            wave += sin((t * 3.0 + surfacePhase) * .pi * 2 + waveOffsets[0]) * 1.5
            wave += sin((t * 5.0 + surfacePhase * 0.7) * .pi * 2 + waveOffsets[1]) * 0.8
            wave += sin((t * 7.0 - surfacePhase * 0.5) * .pi * 2 + waveOffsets[2]) * 0.5

            let y = baseY + wave

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        surface.path = path
    }

    private func updateWaterColors() {
        waterNode?.fillColor = accentColor.withAlphaComponent(0.5)
        surfaceNode?.strokeColor = accentColor.withAlphaComponent(0.8)
    }

    private func getWaterSurfaceY() -> CGFloat {
        let inset: CGFloat = 10
        return inset + maxWaterHeight * waterLevel
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
                spawnRipple(at: CGPoint(x: node.position.x, y: waterY))
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

        maxWaterHeight = size.height * 0.35
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
                Text("完成")
                    .font(.title2)
                    .fontWeight(.bold)

                VStack(alignment: .leading, spacing: 16) {
                    // Task name
                    InfoRow(
                        label: "任务",
                        value: taskName,
                        icon: "checkmark.circle.fill"
                    )

                    Divider()

                    // Start time
                    InfoRow(
                        label: "开始",
                        value: timeFormatter.string(from: startTime),
                        icon: "play.circle"
                    )

                    // End time
                    InfoRow(
                        label: "结束",
                        value: timeFormatter.string(from: endTime),
                        icon: "stop.circle"
                    )

                    Divider()

                    // Total duration
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
