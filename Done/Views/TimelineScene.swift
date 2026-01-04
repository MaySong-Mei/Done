//
//  TimelineScene.swift
//  Done
//
//  Created by Shiqi Liu on 1/3/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct TimelineScene: View {
    @StateObject private var viewModel = TimelineViewModel()
    @StateObject private var dataManager = DataManager.shared
    @StateObject private var eventProvider = TimelineEventProvider()
    @StateObject private var viewportState = ViewportState()
    @StateObject private var carryTouchRouter = CarryTouchRouter()
    @State private var scrollCenterDate: Date?
    @State private var lockedScrollCenterDate: Date?
    @State private var isMagnifying = false
    @State private var isEventDragging = false
    @State private var carrySession: CarrySession?
    @State private var showCreateEntry = false
    @State private var bodyScrollFrame: CGRect = .zero
    @State private var autoScrollTimer: Timer?
    @State private var isDebugOverlayVisible = false
    @State private var lastTimeHapticTimestamp: TimeInterval = 0
    @State private var lastDayHapticTimestamp: TimeInterval = 0
    private let hourHeight: CGFloat = 60
    private var totalHeight: CGFloat { 24 * hourHeight }
    private let timeAxisWidth: CGFloat = 30
    private let horizontalPadding: CGFloat = 16
    private let autoScrollEdgeThreshold: CGFloat = 80
    private let maxAutoScrollSpeed: CGFloat = 12
    private let autoScrollTickInterval: TimeInterval = 1.0 / 60.0
    private let timeHapticInterval: TimeInterval = 0.12
    private let dayHapticInterval: TimeInterval = 0.25
    private let verticalScrollSpaceName = "timelineVerticalScroll"
    private let horizontalScrollSpaceName = "timelineHorizontalScroll"

    var body: some View {
        VStack(spacing: 0) {
            headerCard
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 8)

            bodyScroll
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
        .background(MultiTouchScrollHost(router: carryTouchRouter))
        .overlay {
            carryGhostOverlay
        }
        .overlay(alignment: .topLeading) {
            debugOverlay
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { _ in
                    guard carrySession?.isCarrying != true else { return }
                    if lockedScrollCenterDate == nil {
                        lockedScrollCenterDate = scrollCenterDate ?? viewModel.centerDate
                    }
                    isMagnifying = true
                    viewModel.beginMagnification()
                }
                .onEnded { value in
                    guard carrySession?.isCarrying != true else { return }
                    let lockedDate = lockedScrollCenterDate ?? viewModel.centerDate
                    viewModel.centerDate = Calendar.current.startOfDay(for: lockedDate)
                    viewModel.handleMagnificationGestureEnded(value)
                    scrollCenterDate = lockedDate
                    lockedScrollCenterDate = nil
                    isMagnifying = false
                }
        )
        .onAppear {
            eventProvider.update(entries: dataManager.timelineEntries)
            scrollCenterDate = viewModel.centerDate
            carryTouchRouter.onCarryCancelled = {
                if var session = carrySession, session.isCarrying {
                    session.isCarrying = false
                    session.currentDropTarget = nil
                    carrySession = session
                }
            }
        }
        .onChange(of: dataManager.timeEntries) { _, newValue in
            eventProvider.update(entries: dataManager.timelineEntries)
        }
        .onChange(of: carrySession?.isCarrying == true) { _, isCarrying in
            if isCarrying {
                startAutoScrollTimer()
            } else {
                stopAutoScrollTimer()
            }
        }
        .onChange(of: viewportState.verticalOffset) { _, _ in
            updateDropTarget()
        }
        .onChange(of: viewportState.horizontalOffset) { _, _ in
            updateDropTarget()
        }
        .onChange(of: viewportState.visibleWidth) { _, _ in
            updateDropTarget()
        }
        .sheet(isPresented: $showCreateEntry) {
            TimeEntryCreateView(selectedDate: viewModel.centerDate)
        }
        .onDisappear {
            stopAutoScrollTimer()
        }
    }

    // MARK: Body Scroll
    private var bodyScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            GeometryReader { proxy in
                let contentWidth = max(0, proxy.size.width - timeAxisWidth)
                HStack(spacing: 0) {
                    timeAxis
                        .frame(width: timeAxisWidth, alignment: .trailing)

                    timelineColumns(contentWidth: contentWidth)
                }
                .frame(height: totalHeight, alignment: .top)
                .background(
                    GeometryReader { contentProxy in
                        Color.clear.preference(
                            key: VerticalScrollOffsetPreferenceKey.self,
                            value: contentProxy.frame(in: .named(verticalScrollSpaceName)).minY
                        )
                    }
                )
            }
            .frame(height: totalHeight)
        }
        .coordinateSpace(name: verticalScrollSpaceName)
        .background(
            GeometryReader { scrollProxy in
                Color.clear.preference(key: VerticalViewportSizePreferenceKey.self, value: scrollProxy.size)
                    .preference(key: BodyScrollFramePreferenceKey.self, value: scrollProxy.frame(in: .global))
            }
        )
        .onPreferenceChange(VerticalScrollOffsetPreferenceKey.self) { newValue in
            viewportState.verticalOffset = newValue
        }
        .onPreferenceChange(VerticalViewportSizePreferenceKey.self) { newValue in
            viewportState.visibleHeight = newValue.height
        }
        .onPreferenceChange(BodyScrollFramePreferenceKey.self) { newValue in
            bodyScrollFrame = newValue
        }
    }

    // MARK: - Time Axis
    private var timeAxis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%d", hour))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .center)
            }
        }
        .padding(.trailing, 4)
    }

    // MARK: - Timeline Columns
    private func timelineColumns(contentWidth: CGFloat) -> some View {
        let columnWidth = contentWidth / CGFloat(max(1, viewModel.dayCount))
        let scrollPositionBinding = Binding<Date?>(
            get: { scrollCenterDate },
            set: { newValue in
                guard !isMagnifying else { return }
                scrollCenterDate = newValue
            }
        )
        return ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: 0) {
                ForEach(Array(viewModel.renderDates.enumerated()), id: \.element) { index, date in
                    timelineColumn(date: date, width: columnWidth, index: index)
                        .id(date)
                }
            }
            .scrollTargetLayout()
            .frame(height: totalHeight, alignment: .top)
            .background(
                GeometryReader { contentProxy in
                    Color.clear.preference(
                        key: HorizontalScrollOffsetPreferenceKey.self,
                        value: contentProxy.frame(in: .named(horizontalScrollSpaceName)).minX
                    )
                }
            )
        }
        .coordinateSpace(name: horizontalScrollSpaceName)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: scrollPositionBinding, anchor: .center)
        .frame(width: contentWidth, height: totalHeight, alignment: .leading)
        .background(
            GeometryReader { scrollProxy in
                Color.clear.preference(key: HorizontalViewportSizePreferenceKey.self, value: scrollProxy.size)
            }
        )
        .onPreferenceChange(HorizontalScrollOffsetPreferenceKey.self) { newValue in
            viewportState.horizontalOffset = newValue
        }
        .onPreferenceChange(HorizontalViewportSizePreferenceKey.self) { newValue in
            viewportState.visibleWidth = newValue.width
        }
    }

    private func timelineColumn(date: Date, width: CGFloat, index: Int) -> some View {
        let dropTarget = carrySession?.currentDropTarget
        let isTargetColumn = carrySession?.isCarrying == true && dropTarget?.dayIndex == index
        let targetLineY = dropTarget.map { yPosition(for: $0.snappedStartTime) }
        return ZStack(alignment: .topLeading) {
            if isTargetColumn {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .allowsHitTesting(false)
            }
            timelineGrid

            eventBlocks(for: date, width: width)

            if let targetLineY, isTargetColumn {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: width, height: 2)
                    .offset(y: targetLineY - 1)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: totalHeight)
    }

    // MARK: Event Blocks
    private func eventBlocks(for date: Date, width: CGFloat) -> some View {
        let entries = eventProvider.entriesForDate(date)
        // Manual regression notes:
        // - Fast flick on event should scroll (not pick up).
        // - Hold still should pick up.
        // - While held, second finger scroll should work.
        // - Drop commits correctly.
        return ZStack(alignment: .topLeading) {
            ForEach(entries) { entry in
                let dayStart = Calendar.current.startOfDay(for: date)
                let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? date
                let entryEnd = entry.endTime ?? Date()
                let start = max(entry.startTime, dayStart)
                let end = min(entryEnd, dayEnd)
                if end > start {
                    TimelineEventBlockView(
                        entry: entry,
                        renderStart: start,
                        renderEnd: end,
                        hourHeight: hourHeight,
                        availableWidth: width,
                        columnWidth: width,
                        showsLabels: viewModel.dayCount == 1,
                        type: eventProvider.type(for: entry),
                        currentDropTarget: carrySession?.eventId == entry.id ? carrySession?.currentDropTarget : nil,
                        carryDuration: carrySession?.eventId == entry.id ? carrySession?.duration : nil,
                        onDragStateChanged: { isDragging in
                            isEventDragging = isDragging
                        },
                        onMove: { updatedEntry in
                            dataManager.updateTimeEntry(updatedEntry)
                        },
                        onCarryBegan: { anchorScreenPoint, anchorOffset in
                            guard let endTime = entry.endTime else { return }
                            carrySession = CarrySession(
                                eventId: entry.id,
                                originalStart: entry.startTime,
                                originalEnd: endTime,
                                duration: endTime.timeIntervalSince(entry.startTime),
                                isCarrying: true,
                                fingerAIdentifier: nil,
                                anchorScreenPoint: anchorScreenPoint,
                                ghostScreenPoint: anchorScreenPoint,
                                ghostAnchorOffset: anchorOffset,
                                currentDropTarget: nil
                            )
                            lastTimeHapticTimestamp = 0
                            lastDayHapticTimestamp = 0
                            carryTouchRouter.beginCarry(at: anchorScreenPoint)
                            updateDropTarget()
                        },
                        onCarryChanged: { ghostScreenPoint in
                            guard var session = carrySession else { return }
                            session.ghostScreenPoint = ghostScreenPoint
                            session.isCarrying = true
                            carrySession = session
                            carryTouchRouter.updateCarry(at: ghostScreenPoint)
                            updateDropTarget()
                        },
                        onCarryEnded: {
                            carryTouchRouter.endCarry()
                            guard var session = carrySession else { return }
                            session.isCarrying = false
                            carrySession = session
                        }
                    )
                }
            }
        }
    }

    // MARK: - Timeline Grid
    private var timelineGrid: some View {
        Canvas { context, size in
            let centerOffset = hourHeight / 2
            for hour in 0..<24 {
                let y = CGFloat(hour) * hourHeight + centerOffset
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(
                    path,
                    with: .color(.gray.opacity(0.3)),
                    style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                )
            }
        }
        .frame(height: totalHeight)
    }

    private func yPosition(for date: Date) -> CGFloat {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let totalMinutes = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
        return CGFloat(totalMinutes / 60.0) * hourHeight
    }

    private func updateDropTarget() {
        guard var session = carrySession,
              session.isCarrying,
              bodyScrollFrame != .zero,
              viewportState.visibleWidth > 0 else { return }

        let columnWidth = viewportState.visibleWidth / CGFloat(max(1, viewModel.dayCount))
        let geometry = DropTargetGeometry(
            hourHeight: hourHeight,
            timeAxisWidth: timeAxisWidth,
            scrollViewOrigin: bodyScrollFrame.origin
        )
        let target = DropTargetResolver.resolve(
            ghostScreenPoint: session.ghostScreenPoint,
            viewportState: viewportState,
            timelineGeometry: geometry,
            renderDates: viewModel.renderDates,
            columnWidth: columnWidth,
            currentDayIndex: session.currentDropTarget?.dayIndex
        )
        if let target {
            fireHapticsIfNeeded(previous: session.currentDropTarget, next: target)
        }
        session.currentDropTarget = target
        carrySession = session
    }

    private func startAutoScrollTimer() {
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: autoScrollTickInterval, repeats: true) { _ in
            performAutoScroll()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func stopAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    private func performAutoScroll() {
        guard let session = carrySession, session.isCarrying, bodyScrollFrame != .zero else { return }
        let ghost = session.ghostScreenPoint
        let verticalDelta = autoScrollDelta(
            position: ghost.y,
            minEdge: bodyScrollFrame.minY,
            maxEdge: bodyScrollFrame.maxY
        )
        let horizontalDelta = autoScrollDelta(
            position: ghost.x,
            minEdge: bodyScrollFrame.minX + timeAxisWidth,
            maxEdge: bodyScrollFrame.maxX
        )

        if verticalDelta != 0 || horizontalDelta != 0 {
            carryTouchRouter.scroll(verticalBy: verticalDelta, horizontalBy: horizontalDelta)
        }
    }

    private func autoScrollDelta(position: CGFloat, minEdge: CGFloat, maxEdge: CGFloat) -> CGFloat {
        if position < minEdge {
            return -maxAutoScrollSpeed
        }
        if position > maxEdge {
            return maxAutoScrollSpeed
        }

        let distanceToMin = position - minEdge
        if distanceToMin < autoScrollEdgeThreshold {
            return -scaledAutoScrollSpeed(distanceToMin)
        }

        let distanceToMax = maxEdge - position
        if distanceToMax < autoScrollEdgeThreshold {
            return scaledAutoScrollSpeed(distanceToMax)
        }

        return 0
    }

    private func scaledAutoScrollSpeed(_ distance: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, 1 - distance / autoScrollEdgeThreshold))
        return maxAutoScrollSpeed * clamped * clamped
    }

    private func fireHapticsIfNeeded(previous: DropTarget?, next: DropTarget) {
#if canImport(UIKit)
        let now = Date().timeIntervalSinceReferenceDate
        if let previous,
           previous.snappedStartTime != next.snappedStartTime,
           now - lastTimeHapticTimestamp >= timeHapticInterval {
            lastTimeHapticTimestamp = now
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
        }

        if let previous,
           previous.dayIndex != next.dayIndex,
           now - lastDayHapticTimestamp >= dayHapticInterval {
            lastDayHapticTimestamp = now
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        }
#endif
    }

    private var carryGhostOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let session = carrySession,
                   session.isCarrying,
                   let entry = eventProvider.entries.first(where: { $0.id == session.eventId }) {
                    let containerOrigin = proxy.frame(in: .global).origin
                    let bodyWidth = max(0, proxy.size.width - horizontalPadding * 2)
                    let contentWidth = max(0, bodyWidth - timeAxisWidth)
                    let columnWidth = contentWidth / CGFloat(max(1, viewModel.dayCount))
                    let ghostWidth = max(1, columnWidth - 2)
                    let ghostHeight = max(1, CGFloat(session.duration / 3600) * hourHeight)
                    let anchorOrigin = CGPoint(
                        x: session.anchorScreenPoint.x - session.ghostAnchorOffset.width,
                        y: session.anchorScreenPoint.y - session.ghostAnchorOffset.height
                    )
                    let originalCenter = CGPoint(
                        x: anchorOrigin.x + ghostWidth / 2,
                        y: anchorOrigin.y + ghostHeight / 2
                    )
                    let deltaY = session.ghostScreenPoint.y - originalCenter.y
                    let timeDelta = TimeInterval((deltaY / hourHeight) * 3600)
                    let displayStart = session.originalStart.addingTimeInterval(timeDelta)
                    let displayEnd = session.originalEnd.addingTimeInterval(timeDelta)
                    let localGhostPoint = CGPoint(
                        x: session.ghostScreenPoint.x - containerOrigin.x,
                        y: session.ghostScreenPoint.y - containerOrigin.y
                    )

                    CarryGhostView(
                        entry: entry,
                        displayStart: displayStart,
                        displayEnd: displayEnd,
                        height: ghostHeight,
                        width: ghostWidth,
                        showsLabels: viewModel.dayCount == 1,
                        type: entry.type
                    )
                    .position(localGhostPoint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var debugOverlay: some View {
#if DEBUG
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isDebugOverlayVisible.toggle()
            } label: {
                Text(isDebugOverlayVisible ? "Hide Debug" : "Show Debug")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.7))
                    )
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            if isDebugOverlayVisible {
                debugOverlayDetails
            }
        }
        .padding(12)
#else
        EmptyView()
#endif
    }

#if DEBUG
    private var debugOverlayDetails: some View {
        let vertical = String(format: "%.1f", viewportState.verticalOffset)
        let horizontal = String(format: "%.1f", viewportState.horizontalOffset)
        let width = String(format: "%.1f", viewportState.visibleWidth)
        let height = String(format: "%.1f", viewportState.visibleHeight)
        let ghost = carrySession?.isCarrying == true ? carrySession?.ghostScreenPoint : nil
        let ghostText = ghost.map { String(format: "(%.1f, %.1f)", $0.x, $0.y) } ?? "nil"
        let target = carrySession?.isCarrying == true ? carrySession?.currentDropTarget : nil
        let targetDay = target.map { "\($0.dayIndex)" } ?? "nil"
        let targetTime = target.map { Self.debugTimeFormatter.string(from: $0.snappedStartTime) } ?? "nil"

        return VStack(alignment: .leading, spacing: 4) {
            Text("ghost: \(ghostText)")
            Text("offsets v:\(vertical) h:\(horizontal)")
            Text("viewport w:\(width) h:\(height)")
            Text("target day:\(targetDay) time:\(targetTime)")
        }
        .font(.caption2)
        .foregroundColor(.white)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.7))
        )
        .allowsHitTesting(false)
    }

    private static let debugTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
#endif

    // MARK: Header Card
    private var headerCard: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 6)
            .overlay(alignment: .topTrailing) {
                Button {
                    showCreateEntry = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(12)
                .accessibilityLabel("Add entry")
            }
    }
}

private struct VerticalScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HorizontalScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct VerticalViewportSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct HorizontalViewportSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct BodyScrollFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
