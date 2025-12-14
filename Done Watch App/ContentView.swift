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
    }
}

struct ActivityCrownPickerView: View {
    @StateObject private var dataManager = DataManager.shared
    @State private var selectedIndex: Int = 0
    @State private var crownValue: Double = 0

    var body: some View {
        let templates = dataManager.templates

        VStack(spacing: 12) {
            header

            if let current = currentTemplate {
                currentCard(for: current)
                previewRow(for: current)
                startButton(for: current)
            } else {
                emptyState
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .navigationTitle("Track Time")
        .digitalCrownRotation(
            $crownValue,
            from: 0,
            through: Double(max(templates.count - 1, 0)),
            by: 1,
            sensitivity: .medium,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: crownValue) { _, newValue in
            syncSelectedIndex(from: newValue)
        }
        .onChange(of: dataManager.templates.count) { _, _ in
            clampSelection()
        }
        .onAppear {
            clampSelection()
        }
    }

    private var header: some View {
        HStack {
            Text("Done")
                .font(.headline)
            Spacer()
            Text("Rotate crown to choose")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func currentCard(for template: ActivityTemplate) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if !template.icon.isEmpty {
                    Image(systemName: template.icon)
                        .font(.title2)
                        .foregroundColor(.white)
                        .frame(width: 38, height: 38)
                        .background(template.color.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Text(template.name)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [template.color.opacity(0.9), template.color.opacity(0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func previewRow(for template: ActivityTemplate) -> some View {
        let previous = neighborName(offset: -1)
        let next = neighborName(offset: 1)

        return HStack(spacing: 6) {
            Text("‹")
                .foregroundColor(.secondary)

            Text(previous ?? "")
                .font(.caption2)
                .foregroundColor(.secondary)
                .opacity(previous == nil ? 0.3 : 1)

            Text(template.name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary)

            Text(next ?? "")
                .font(.caption2)
                .foregroundColor(.secondary)
                .opacity(next == nil ? 0.3 : 1)

            Text("›")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func startButton(for template: ActivityTemplate) -> some View {
        Button {
            dataManager.startTracking(template: template)
        } label: {
            Text("Start \"\(template.name)\"")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(template.color)
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

    private func neighborName(offset: Int) -> String? {
        let index = selectedIndex + offset
        guard dataManager.templates.indices.contains(index) else { return nil }
        return dataManager.templates[index].name
    }

    private func clampSelection() {
        let maxIndex = max(dataManager.templates.count - 1, 0)
        selectedIndex = min(selectedIndex, maxIndex)
        crownValue = Double(selectedIndex)
    }

    private func syncSelectedIndex(from crownValue: Double) {
        let newIndex = min(max(Int(round(crownValue)), 0), max(dataManager.templates.count - 1, 0))
        if newIndex != selectedIndex {
            selectedIndex = newIndex
        }
    }
}

struct ActiveTimerView: View {
    let entry: TimeEntry
    @StateObject private var dataManager = DataManager.shared
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var minuteRemainder: Int = 0
    @State private var hourCount: Int = 0
    @State private var marbleScene = MarbleScene(size: CGSize(width: 180, height: 180))
    @State private var stopProgress: CGFloat = 0

    private let stopHoldDuration: TimeInterval = 0.8

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

            GeometryReader { proxy in
                let pageHeight = proxy.size.height

                if #available(watchOS 10.0, *) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            marbleOnlyPage
                                .frame(height: pageHeight)
                            controlPage
                                .frame(height: pageHeight)
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned)
                    .ignoresSafeArea(.all, edges: .vertical)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            marbleOnlyPage
                                .frame(height: pageHeight)
                            controlPage
                                .frame(height: pageHeight)
                        }
                    }
                    .ignoresSafeArea(.all, edges: .vertical)
                }
            }
        }
        .onAppear {
            syncElapsed(initial: true)
            startTimer()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private var marbleOnlyPage: some View {
        GeometryReader { proxy in
            VStack {
                Spacer(minLength: 8)
                marbleStage(height: min(proxy.size.height * 0.9, 220))
                    .padding(.horizontal, 12)
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controlPage: some View {
        GeometryReader { proxy in
            let ringSize = min(proxy.size.width - 28, 220)

            VStack {
                Spacer()

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: stopProgress)
                        .stroke(Color.red, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Circle()
                        .fill(Color.red.opacity(0.9))
                        .frame(width: ringSize * 0.22, height: ringSize * 0.22)
                        .overlay(
                            Image(systemName: "stop.fill")
                                .foregroundColor(.white)
                                .font(.title2)
                        )
                }
                .frame(width: ringSize, height: ringSize)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    dataManager.stopTracking()
                }
            )
        }
    }

    private func marbleStage(height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )

            SpriteView(scene: marbleScene)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .frame(height: height)
    }

    private var templateColor: Color {
        Color(hex: entry.colorHex) ?? .blue
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            syncElapsed(initial: false)
        }
    }

    private func syncElapsed(initial: Bool) {
        elapsedTime = Date().timeIntervalSince(entry.startTime)

        let totalMinutes = Int(elapsedTime / 60)
        let newHourCount = totalMinutes / 60
        let newMinuteRemainder = totalMinutes % 60

        if initial {
            marbleScene.updatePalette(
                primary: SKColor(hex: entry.colorHex) ?? SKColor.cyan,
                accent: SKColor(hex: entry.colorHex)?.lifted() ?? SKColor.blue
            )
            marbleScene.setInitialState(minutes: newMinuteRemainder, hours: newHourCount)
        } else {
            if newHourCount > hourCount {
                for _ in hourCount..<newHourCount {
                    marbleScene.mergeMinutesIntoHourBead()
                }
            }

            if newMinuteRemainder > minuteRemainder {
                for _ in minuteRemainder..<newMinuteRemainder {
                    marbleScene.dropMinuteBead()
                }
            }
        }

        minuteRemainder = newMinuteRemainder
        hourCount = newHourCount
    }
}

#Preview {
    ContentView()
}

// MARK: - Marble Scene

final class MarbleScene: SKScene {
    private var minuteNodes: [SKNode] = []
    private var hourNodes: [SKNode] = []
    private var bowlNode: SKShapeNode?

    private var primaryColor: SKColor = .cyan
    private var accentColor: SKColor = .blue

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
        physicsWorld.gravity = CGVector(dx: 0, dy: -4.8)
    }

    func updatePalette(primary: SKColor, accent: SKColor) {
        primaryColor = primary
        accentColor = accent
        bowlNode?.strokeColor = primary.withAlphaComponent(0.45)
        bowlNode?.fillColor = primary.withAlphaComponent(0.08)
    }

    func setInitialState(minutes: Int, hours: Int) {
        removeAllChildren()
        minuteNodes.removeAll()
        hourNodes.removeAll()

        buildBowl()

        for _ in 0..<hours {
            dropHourBead(immediate: true)
        }

        for _ in 0..<minutes {
            dropMinuteBead(immediate: true)
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        rebuildBowl()
        clampNodesToBounds()
    }

    func dropMinuteBead(immediate: Bool = false) {
        guard size.width > 0 else { return }

        let radius: CGFloat = 7
        let node = SKShapeNode(circleOfRadius: radius)
        node.fillColor = primaryColor.withAlphaComponent(0.9)
        node.strokeColor = primaryColor.withAlphaComponent(0.45)
        node.glowWidth = 1
        node.lineWidth = 1.2

        let xPosition = CGFloat.random(in: (radius + 12)...(size.width - radius - 12))
        node.position = CGPoint(x: xPosition, y: size.height - radius - 6)
        node.alpha = immediate ? 1 : 0

        let body = SKPhysicsBody(circleOfRadius: radius)
        body.restitution = 0.3
        body.friction = 0.35
        body.linearDamping = 0.12
        node.physicsBody = body

        addChild(node)
        minuteNodes.append(node)

        if !immediate {
            let fadeIn = SKAction.fadeIn(withDuration: 0.18)
            let impulse = SKAction.run {
                let dx = CGFloat.random(in: -0.8...0.8)
                let dy = CGFloat.random(in: 1.2...2.0)
                body.applyImpulse(CGVector(dx: dx, dy: dy))
            }
            node.run(.sequence([fadeIn, impulse]))
        }
    }

    func mergeMinutesIntoHourBead() {
        let nodes = minuteNodes
        minuteNodes.removeAll()

        for (index, node) in nodes.enumerated() {
            let wait = SKAction.wait(forDuration: 0.01 * Double(index))
            let fade = SKAction.group([
                SKAction.fadeOut(withDuration: 0.18),
                SKAction.scale(to: 0.2, duration: 0.18)
            ])
            node.run(.sequence([wait, fade, .removeFromParent()]))
        }

        let drop = SKAction.sequence([
            .wait(forDuration: 0.22),
            .run { [weak self] in
                self?.dropHourBead()
            }
        ])
        run(drop)
    }

    func dropHourBead(immediate: Bool = false) {
        guard size.width > 0 else { return }

        let radius: CGFloat = 13
        let node = SKShapeNode(circleOfRadius: radius)
        node.fillColor = accentColor.withAlphaComponent(0.95)
        node.strokeColor = accentColor.withAlphaComponent(0.55)
        node.glowWidth = 1.5
        node.lineWidth = 1.6

        let xPosition = CGFloat.random(in: (radius + 14)...(size.width - radius - 14))
        node.position = CGPoint(x: xPosition, y: size.height - radius - 6)
        node.alpha = immediate ? 1 : 0

        let body = SKPhysicsBody(circleOfRadius: radius)
        body.restitution = 0.25
        body.friction = 0.4
        body.linearDamping = 0.1
        node.physicsBody = body

        addChild(node)
        hourNodes.append(node)

        if !immediate {
            let fadeIn = SKAction.fadeIn(withDuration: 0.18)
            let impulse = SKAction.run {
                let dx = CGFloat.random(in: -0.6...0.6)
                let dy = CGFloat.random(in: 1.5...2.4)
                body.applyImpulse(CGVector(dx: dx, dy: dy))
            }
            node.run(.sequence([fadeIn, impulse]))
        }
    }

    private func rebuildBowl() {
        bowlNode?.removeFromParent()
        buildBowl()
    }

    private func buildBowl() {
        guard size.width > 0 else { return }

        let inset: CGFloat = 10
        let baseRect = CGRect(
            x: inset,
            y: inset,
            width: size.width - inset * 2,
            height: size.height - inset * 2
        )

        let path = CGMutablePath()
        let lipHeight: CGFloat = 16

        path.move(to: CGPoint(x: baseRect.minX, y: baseRect.maxY - lipHeight))
        path.addQuadCurve(
            to: CGPoint(x: baseRect.midX, y: baseRect.maxY - lipHeight + 18),
            control: CGPoint(x: baseRect.minX + 18, y: baseRect.maxY + 10)
        )
        path.addQuadCurve(
            to: CGPoint(x: baseRect.maxX, y: baseRect.maxY - lipHeight),
            control: CGPoint(x: baseRect.maxX - 18, y: baseRect.maxY + 10)
        )
        path.addLine(to: CGPoint(x: baseRect.maxX, y: baseRect.minY))
        path.addLine(to: CGPoint(x: baseRect.minX, y: baseRect.minY))
        path.closeSubpath()

        let bowl = SKShapeNode(path: path)
        bowl.lineWidth = 1.6
        bowl.strokeColor = primaryColor.withAlphaComponent(0.45)
        bowl.fillColor = primaryColor.withAlphaComponent(0.08)

        let body = SKPhysicsBody(edgeLoopFrom: path)
        body.friction = 0.65
        body.restitution = 0.1
        bowl.physicsBody = body

        bowlNode = bowl
        addChild(bowl)
    }

    private func clampNodesToBounds() {
        let minX: CGFloat = 12
        let maxX = size.width - 12
        let minY: CGFloat = 12
        let maxY = size.height - 12
        for node in minuteNodes + hourNodes {
            var position = node.position
            position.x = min(max(position.x, minX), maxX)
            position.y = min(max(position.y, minY), maxY)
            node.position = position
        }
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
