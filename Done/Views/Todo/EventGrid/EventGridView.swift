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
    @State private var splitEvent: Event?
    @State private var splitUndoInfo: SmartSplitUndoInfo?
    @State private var splitUndoTimer: DispatchWorkItem?
    @State var focusedEventID: UUID?
    @State var resizeState: ResizeState?
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
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if focusedEventID != nil {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            focusedEventID = nil
                                        }
                                    }
                                }

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
        .sheet(item: $splitEvent) { event in
            SplitChatView(event: event) { subtasks in
                performSmartSplit(event, subtasks: subtasks)
            }
        }
        .overlay(alignment: .bottom) {
            if splitUndoInfo != nil {
                Button {
                    if let info = splitUndoInfo {
                        splitUndoTimer?.cancel()
                        splitUndoTimer = nil
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            store.undoSmartSplit(info)
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
        let isDragging = dragState?.eventID == placed.event.id
        let isResizing = resizeState?.eventID == placed.event.id
        let resizeSnap = isResizing ? resizeState?.snappedResult(cellSize: cellSize, columnsCount: EventGridLayout.columnsCount) : nil

        let height = cellSize * CGFloat(resizeSnap?.spanRows ?? placed.spanRows)
        let width = cellSize * CGFloat(resizeSnap?.spanColumns ?? placed.spanColumns)

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

        let baseGridX = isDragging ? (dragState?.initialGridX ?? placed.gridX) : (resizeSnap?.gridX ?? placed.gridX)
        let baseGridY = isDragging ? (dragState?.initialGridY ?? placed.gridY) : (resizeSnap?.gridY ?? placed.gridY)
        let baseX = CGFloat(baseGridX) * cellSize
        let baseY = CGFloat(baseGridY) * cellSize
        let isDismissing = dismissingEventIDs.contains(placed.event.id)
        let isFocused = focusedEventID == placed.event.id
        let isDimmedByFocus = focusedEventID != nil && !isFocused

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
        }
        .overlay {
            if isSplitMode {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        EventTypeTemplateStore.color(for: placed.event.type),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.3), value: isDismissing)
        .animation(.easeInOut(duration: 0.25), value: isSplitMode)
        .contentShape(Rectangle())
        .overlay {
            if !isSplitMode && !isTimerMode && !isFocused {
                UIKitDragGestureView(
                    minimumPressDuration: 0.3,
                    shouldBegin: { self.shouldBeginDrag(for: placed.event.id) },
                    onPanBegan: {
                        self.bringToFront(placed.event.id)
                        self.focusedEventID = placed.event.id
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
                splitEvent = placed.event
                isSplitMode = false
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
        .overlay {
            if isFocused && !isDragging && !isSplitMode && !isMergeMode && !isTimerMode {
                resizeHandles(placed: placed, width: width, height: height, cellSize: cellSize)
            }
        }
        .scaleEffect(
            isFocused ? 1.035 : (isDimmedByFocus ? 0.93 : (isDragging ? 1.03 : 1.0))
        )
        .opacity(isDimmedByFocus ? 0.28 : (isDismissing ? 0 : 1.0))
        .offset(y: isDimmedByFocus ? 6 : 0)
        .shadow(
            color: .black.opacity(0.08),
            radius: isFocused ? 10 : (isDragging ? 5 : 4),
            x: 0.5, y: 0.5
        )
        .animation(.easeInOut(duration: 0.15), value: focusedEventID)
        .animation(.spring(response: 0.25, dampingFraction: 0.8, blendDuration: 0.1), value: isDragging)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: resizeSnap?.spanColumns)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: resizeSnap?.spanRows)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: resizeSnap?.gridX)
        .animation(.spring(response: 0.2, dampingFraction: 0.85), value: resizeSnap?.gridY)
        .position(
            x: baseX + width * 0.5 + dragOffset.width,
            y: baseY + height * 0.5 + dragOffset.height
        )
        .zIndex(zIndex(for: placed.event.id))
    }

    func resizeHandles(placed: PositionedEvent, width: CGFloat, height: CGFloat, cellSize: CGFloat) -> some View {
        let handleColor: Color = EventTypeTemplateStore.color(for: placed.event.type).opacity(0.5)
        let hLen: CGFloat = min(width * 0.35, 36)
        let vLen: CGFloat = min(height * 0.35, 36)
        return VStack(spacing: 0) {
            resizeBar(color: handleColor, capsuleWidth: hLen, capsuleHeight: 3, frameWidth: .infinity, frameHeight: 16)
                .gesture(makeResizeGesture(edge: .top, placed: placed, cellSize: cellSize))
            HStack(spacing: 0) {
                resizeBar(color: handleColor, capsuleWidth: 3, capsuleHeight: vLen, frameWidth: 16, frameHeight: .infinity)
                    .gesture(makeResizeGesture(edge: .leading, placed: placed, cellSize: cellSize))
                Spacer(minLength: 0)
                resizeBar(color: handleColor, capsuleWidth: 3, capsuleHeight: vLen, frameWidth: 16, frameHeight: .infinity)
                    .gesture(makeResizeGesture(edge: .trailing, placed: placed, cellSize: cellSize))
            }
            resizeBar(color: handleColor, capsuleWidth: hLen, capsuleHeight: 3, frameWidth: .infinity, frameHeight: 16)
                .gesture(makeResizeGesture(edge: .bottom, placed: placed, cellSize: cellSize))
        }
    }

    func resizeBar(color: Color, capsuleWidth: CGFloat, capsuleHeight: CGFloat, frameWidth: CGFloat, frameHeight: CGFloat) -> some View {
        Capsule()
            .fill(color)
            .frame(width: capsuleWidth, height: capsuleHeight)
            .frame(maxWidth: frameWidth, maxHeight: frameHeight)
            .contentShape(Rectangle())
    }

    func makeResizeGesture(edge: ResizeEdge, placed: PositionedEvent, cellSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if resizeState == nil {
                    bringToFront(placed.event.id)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    resizeState = ResizeState(
                        eventID: placed.event.id,
                        edge: edge,
                        initialGridX: placed.gridX,
                        initialGridY: placed.gridY,
                        initialSpanColumns: placed.spanColumns,
                        initialSpanRows: placed.spanRows,
                        translation: value.translation
                    )
                } else {
                    resizeState?.translation = value.translation
                }
            }
            .onEnded { _ in
                commitResize(for: placed, cellSize: cellSize)
            }
    }

    func performSmartSplit(_ event: Event, subtasks: [SplitService.SubTask]) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        let tuples = subtasks.map { (title: $0.title, portion: $0.portion) }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            let undoInfo = store.smartSplitEvent(event, subtasks: tuples)

            if let undoInfo {
                splitUndoTimer?.cancel()
                splitUndoInfo = undoInfo
                let timer = DispatchWorkItem { [self] in
                    withAnimation { splitUndoInfo = nil }
                }
                splitUndoTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timer)
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

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.2, y: rect.height * 0.5))
        path.addLine(to: CGPoint(x: rect.width * 0.45, y: rect.height * 0.75))
        path.addLine(to: CGPoint(x: rect.width * 0.8, y: rect.height * 0.25))
        return path
    }
}
