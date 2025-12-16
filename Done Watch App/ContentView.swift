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
    private var containerNode: SKShapeNode?
    private var raindrops: [SKShapeNode] = []

    private var primaryColor: SKColor = .cyan
    private var accentColor: SKColor = .blue

    private var lastRaindropTime: TimeInterval = 0

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
        physicsWorld.gravity = CGVector(dx: 0, dy: 0) // No physics needed
    }

    func updatePalette(primary: SKColor, accent: SKColor) {
        primaryColor = primary
        accentColor = accent
    }

    func initialize() {
        guard size.width > 0 else { return }

        removeAllChildren()
        raindrops.removeAll()

        buildContainer()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        rebuildAll()
    }

    override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)

        // Generate raindrops continuously
        if currentTime - lastRaindropTime > 0.015 { // ~66 drops/sec
            spawnRaindrop()
            lastRaindropTime = currentTime
        }
    }

    // MARK: - Build Components

    private func buildContainer() {
        guard size.width > 0 else { return }

        let inset: CGFloat = 10
        let rect = CGRect(
            x: inset,
            y: inset,
            width: size.width - inset * 2,
            height: size.height - inset * 2
        )

        let container = SKShapeNode(rect: rect, cornerRadius: 24)
        container.lineWidth = 0
        container.strokeColor = .clear
        container.fillColor = .clear

        containerNode = container
        addChild(container)
    }

    private func spawnRaindrop() {
        guard size.width > 0, size.height > 0 else { return }

        // Random parameters following user specs
        let speed = CGFloat.random(in: 250...900) // px/s
        let lineWidth = CGFloat.random(in: 1.5...3.0) // Thicker lines
        let alpha = CGFloat.random(in: 0.12...0.35)

        // Length based on speed: len = clamp(speed * 0.03, 6, 22)
        let length = min(max(speed * 0.03, 6), 22)

        // Starting position (across the top)
        let startX = CGFloat.random(in: 0...size.width)
        let startY = size.height + 10

        // Vertical rain with slight horizontal drift (-10° to +10° from vertical)
        let driftAngle = CGFloat.random(in: -10...10) * .pi / 180
        let dx = sin(driftAngle) * length * 0.3 // Small horizontal drift
        let dy = -length // Vertical downward

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

        // Calculate fall distance and duration
        let fallDistance = size.height + 40
        let duration = TimeInterval(fallDistance / speed)

        // Movement action: fall vertically with slight drift
        let moveX = sin(driftAngle) * fallDistance * 0.15 // Slight horizontal drift
        let moveY = -fallDistance // Vertical fall

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

        // Limit total raindrop count for performance
        if raindrops.count > 120 {
            raindrops.first?.removeFromParent()
            raindrops.removeFirst()
        }
    }

    private func rebuildAll() {
        removeAllChildren()
        raindrops.removeAll()
        buildContainer()
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
