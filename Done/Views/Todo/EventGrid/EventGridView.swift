//
//  EventGridView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct EventGridView: View {
    let events: [Event]
    @EnvironmentObject var store: EventStore
    @State var dragState: DragState?
    @State private var selectedEvent: Event?
    @State private var addToCalendarEvent: Event?
    @State private var checkmarkProgress: [UUID: CGFloat] = [:]
    @State private var dismissingEventIDs: Set<UUID> = []
    @State var zOrder: [UUID] = []
    @State var longPressingEventID: UUID?
    @State private var shakeTriggers: [UUID: CGFloat] = [:]
    @State private var splittingEventID: UUID?
    @State private var splitUndoInfo: SplitUndoInfo?
    @State private var splitUndoTimer: DispatchWorkItem?
    @Binding var isDraggingEvent: Bool
    @Binding var deleteZoneFrame: CGRect
    @Binding var isOverDeleteZone: Bool
    @Binding var isSplitMode: Bool
    @Binding var isMergeMode: Bool
    @Binding var isTimerMode: Bool
    @State var mergeTargetID: UUID?
    @State private var mergeUndoInfo: MergeUndoInfo?
    @State private var mergeUndoTimer: DispatchWorkItem?

    var body: some View {
        GeometryReader { proxy in
            let columnsCount = EventGridLayout.columnsCount
            let horizontalPadding: CGFloat = 16
            let verticalPadding: CGFloat = 12
            let availableWidth = proxy.size.width - horizontalPadding * 2
            let cellSize = max(8, availableWidth / CGFloat(columnsCount))
            let placedEvents = PositionedEvent.from(events)
            let maxRow = placedEvents.map { $0.gridY + $0.spanRows }.max() ?? 0
            let contentRows = max(50, maxRow + 50)
            let contentHeight = max(
                proxy.size.height,
                CGFloat(contentRows) * cellSize + verticalPadding * 2
            )

            Group {
                if events.isEmpty {
                    EmptyStateView(title: "No events", systemImage: "checklist")
                } else {
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            GridDotsView(columns: columnsCount, rows: contentRows, cellSize: cellSize)
                                .frame(width: availableWidth, height: contentHeight, alignment: .topLeading)

                            ForEach(placedEvents) { placed in
                                eventCardView(placed: placed, cellSize: cellSize)
                            }
                        }
                        .frame(width: availableWidth, height: contentHeight, alignment: .topLeading)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, verticalPadding)
                    }
                }
            }
        }
        .sheet(item: $selectedEvent) { event in
            EditEventView(event: event)
        }
        .sheet(item: $addToCalendarEvent) { event in
            AddToCalendarView(event: event)
        }
        .onAppear {
            syncZOrder(with: events)
        }
        .onChange(of: events) { updatedEvents in
            syncZOrder(with: updatedEvents)
        }
        .overlay(alignment: .bottom) {
            if splitUndoInfo != nil {
                Button {
                    if let info = splitUndoInfo {
                        splitUndoTimer?.cancel()
                        splitUndoTimer = nil
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            store.undoSplit(info)
                            splitUndoInfo = nil
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: splitUndoInfo != nil)
        .overlay(alignment: .bottom) {
            if mergeUndoInfo != nil {
                Button {
                    if let info = mergeUndoInfo {
                        mergeUndoTimer?.cancel()
                        mergeUndoTimer = nil
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            store.undoMerge(info)
                            mergeUndoInfo = nil
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mergeUndoInfo != nil)
    }
}

// MARK: - Sub Views

private extension EventGridView {

    func eventCardView(placed: PositionedEvent, cellSize: CGFloat) -> some View {
        let height = cellSize * CGFloat(placed.spanRows)
        let width = cellSize * CGFloat(placed.spanColumns)
        let isDragging = dragState?.eventID == placed.event.id

        // Calculate snapped drag offset for real-time grid snapping
        let dragOffset: CGSize = {
            guard let dragState, isDragging else { return .zero }
            let columnsCount = EventGridLayout.columnsCount
            let snapped = dragState.snappedPosition(
                translation: dragState.translation,
                cellSize: cellSize,
                columnsCount: columnsCount
            )
            return CGSize(
                width: CGFloat(snapped.x - dragState.initialGridX) * cellSize,
                height: CGFloat(snapped.y - dragState.initialGridY) * cellSize
            )
        }()

        let baseGridX = isDragging ? (dragState?.initialGridX ?? placed.gridX) : placed.gridX
        let baseGridY = isDragging ? (dragState?.initialGridY ?? placed.gridY) : placed.gridY
        let baseX = CGFloat(baseGridX) * cellSize
        let baseY = CGFloat(baseGridY) * cellSize
        let isDismissing = dismissingEventIDs.contains(placed.event.id)
        let canSplit = max(placed.spanColumns, placed.spanRows) >= 6
        let isSplitting = splittingEventID == placed.event.id

        return ZStack {
            EventCardView(event: placed.event, availableHeight: height)
                .frame(width: width, height: height)
                .scaleEffect(longPressingEventID == placed.event.id ? 0.98 : 1.0)
                .modifier(ShakeEffect(animatableData: shakeTriggers[placed.event.id, default: 0]))
                .animation(.easeOut(duration: 0.2), value: longPressingEventID == placed.event.id)
            CheckmarkShape()
                .trim(from: 0, to: checkmarkProgress[placed.event.id] ?? 0)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                .frame(width: 36, height: 36)
                .allowsHitTesting(false)

            // Split mode: dashed/solid divider line at center
            if isSplitMode && canSplit {
                let typeColor = EventTypeTemplateStore.color(for: placed.event.type)
                let splitByHeight = placed.spanRows > placed.spanColumns
                SplitDividerLine(isSolid: isSplitting, isHorizontal: splitByHeight)
                    .stroke(
                        typeColor,
                        style: StrokeStyle(
                            lineWidth: 2,
                            lineCap: .round,
                            dash: isSplitting ? [] : [6, 4]
                        )
                    )
                    .frame(
                        width: splitByHeight ? width - 16 : 2,
                        height: splitByHeight ? 2 : height - 16
                    )
                    .allowsHitTesting(false)
            }
        }
        .opacity(isDismissing ? 0 : (isSplitMode && !canSplit ? 0.35 : 1.0))
        .animation(.easeOut(duration: 0.3), value: isDismissing)
        .animation(.easeInOut(duration: 0.25), value: isSplitMode)
        .contentShape(Rectangle())
        .overlay {
            if !isSplitMode && !isTimerMode {
                UIKitDragGestureView(
                    minimumPressDuration: 0.3,
                    shouldBegin: { self.shouldBeginDrag(for: placed.event.id) },
                    onPanBegan: {
                        self.bringToFront(placed.event.id)
                        self.beginDrag(for: placed)
                    },
                    onPanChanged: { translation, windowLocation in
                        self.updateDrag(for: placed.event.id, translation: translation)
                        if isMergeMode {
                            let placedEvents = PositionedEvent.from(store.activeEvents)
                            mergeTargetID = findMergeTarget(for: placed, translation: translation, cellSize: cellSize, in: placedEvents)
                        } else {
                            self.isOverDeleteZone = self.deleteZoneFrame.contains(windowLocation)
                        }
                    },
                    onPanEnded: { translation, endLocation in
                        self.isOverDeleteZone = false
                        if isMergeMode, let targetID = mergeTargetID,
                           let targetEvent = store.activeEvents.first(where: { $0.id == targetID }) {
                            performMerge(source: placed.event, target: targetEvent)
                            self.dragState = nil
                            self.isDraggingEvent = false
                            self.mergeTargetID = nil
                        } else {
                            self.mergeTargetID = nil
                            self.endDrag(for: placed, translation: translation, endLocation: endLocation, cellSize: cellSize)
                        }
                    }
                )
            }
        }
        .onTapGesture(count: 2) {
            guard !isSplitMode, !isMergeMode, !isTimerMode else { return }
            completeEvent(placed.event)
        }
        .onTapGesture(count: 1) {
            if isTimerMode {
                let isRunning = store.isTimerRunning(for: placed.event)
                if isRunning {
                    store.stopTimer(for: placed.event)
                } else {
                    store.startTimer(for: placed.event)
                }
                isTimerMode = false
            } else if isSplitMode {
                guard canSplit else { return }
                performSplit(placed.event)
            } else if !isMergeMode {
                bringToFront(placed.event.id)
                selectedEvent = placed.event
            }
        }
        .frame(width: width, height: height)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.blue, lineWidth: mergeTargetID == placed.event.id ? 2.5 : 0)
                .allowsHitTesting(false)
        )
        .animation(.easeInOut(duration: 0.15), value: mergeTargetID == placed.event.id)
        .overlay(alignment: .bottomTrailing) {
            if !isSplitMode && !isMergeMode {
                Button {
                    addToCalendarEvent = placed.event
                } label: {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add to calendar")
                .padding(8)
            }
        }
        .scaleEffect(isDragging ? 1.03 : 1.0)
        .shadow(
            color: .black.opacity(0.08),
            radius: isDragging ? 5 : 4,
            x: 0.5, y: 0.5
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.8, blendDuration: 0.1), value: isDragging)
        .position(
            x: baseX + width * 0.5 + dragOffset.width,
            y: baseY + height * 0.5 + dragOffset.height
        )
        .zIndex(zIndex(for: placed.event.id))
    }

    func performSplit(_ event: Event) {
        guard splittingEventID == nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        // Phase 1: show solid line
        withAnimation(.easeInOut(duration: 0.2)) {
            splittingEventID = event.id
        }

        // Phase 2: execute split
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                let undoInfo = store.splitEvent(event)
                splittingEventID = nil
                isSplitMode = false

                if let undoInfo {
                    splitUndoTimer?.cancel()
                    splitUndoInfo = undoInfo
                    let timer = DispatchWorkItem { [self] in
                        withAnimation { splitUndoInfo = nil }
                    }
                    splitUndoTimer = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timer)
                }
            }
        }
    }

    func performMerge(source: Event, target: Event) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            let undoInfo = store.mergeEvents(source: source, into: target)
            isMergeMode = false

            mergeUndoTimer?.cancel()
            mergeUndoInfo = undoInfo
            let timer = DispatchWorkItem { [self] in
                withAnimation { mergeUndoInfo = nil }
            }
            mergeUndoTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timer)
        }
    }

    func completeEvent(_ event: Event) {
        guard checkmarkProgress[event.id] == nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.35)) {
            checkmarkProgress[event.id] = 1.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeOut(duration: 0.3)) {
                _ = dismissingEventIDs.insert(event.id)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            store.markComplete(event)
            checkmarkProgress.removeValue(forKey: event.id)
            dismissingEventIDs.remove(event.id)
        }
    }
}

private struct SplitDividerLine: Shape {
    var isSolid: Bool
    var isHorizontal: Bool

    var animatableData: EmptyAnimatableData { .init() }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if isHorizontal {
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        } else {
            path.move(to: CGPoint(x: rect.midX, y: 0))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.height))
        }
        return path
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.2, y: rect.height * 0.5))
        path.addLine(to: CGPoint(x: rect.width * 0.45, y: rect.height * 0.75))
        path.addLine(to: CGPoint(x: rect.width * 0.8, y: rect.height * 0.25))
        return path
    }
}
