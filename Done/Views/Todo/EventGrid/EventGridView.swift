//
//  EventGridView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI

struct EventGridView: View {
    let events: [Event]
    var listID: UUID? = nil
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
    @Binding var isDraggingEvent: Bool
    @Binding var deleteZoneFrame: CGRect
    @Binding var isOverDeleteZone: Bool
    @Binding var isSplitMode: Bool
    @Binding var isMergeMode: Bool
    @Binding var isTimerMode: Bool
    @State var mergeTargetID: UUID?
    @State private var mergeUndoInfo: MergeUndoInfo?
    @State private var mergeUndoTimer: DispatchWorkItem?
    @State var cardFrames: [UUID: CGRect] = [:]
    @State var dragStartCardFrames: [UUID: CGRect] = [:]
    @State var reorderTarget: ReorderTarget?
    @State var dragStartFrame: CGRect?

    var body: some View {
        Group {
            if events.isEmpty {
                EmptyStateView(title: "No events", systemImage: "checklist")
            } else {
                ScrollView {
                    MasonryLayout(spacing: 4, columnSpacing: 6) {
                        ForEach(previewEvents) { event in
                            eventCardView(event: event)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: reorderTarget)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if focusedEventID != nil {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            focusedEventID = nil
                        }
                    }
                }
                .overlay { floatingDragCard }
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
        .onChange(of: events) { _, updatedEvents in
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

    private var previewEvents: [Event] {
        guard let dragState = dragState,
              let target = reorderTarget,
              let event = events.first(where: { $0.id == dragState.eventID }) else {
            return events
        }

        var left = events.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
        var right = events.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }

        left.removeAll { $0.id == event.id }
        right.removeAll { $0.id == event.id }

        if target.column == 0 {
            left.insert(event, at: min(target.row, left.count))
        } else {
            right.insert(event, at: min(target.row, right.count))
        }

        // Rebalance: left must have ceil(total/2), right floor(total/2)
        let total = left.count + right.count
        let targetLeftCount = (total + 1) / 2
        while left.count > targetLeftCount {
            right.insert(left.removeLast(), at: 0)
        }
        while left.count < targetLeftCount && !right.isEmpty {
            left.append(right.removeFirst())
        }

        var result: [Event] = []
        for i in 0..<max(left.count, right.count) {
            if i < left.count { result.append(left[i]) }
            if i < right.count { result.append(right[i]) }
        }
        return result
    }
}

// MARK: - Sub Views

private extension EventGridView {

    @ViewBuilder
    var floatingDragCard: some View {
        if let dragState = dragState,
           let event = events.first(where: { $0.id == dragState.eventID }),
           let startFrame = dragStartFrame {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                let x = startFrame.minX - origin.x + dragState.translation.width + startFrame.width / 2
                let y = startFrame.minY - origin.y + dragState.translation.height + startFrame.height / 2
                EventCardView(event: event, isCompleted: checkmarkProgress[event.id] != nil)
                    .frame(width: startFrame.width)
                    .scaleEffect(1.05)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .position(x: x, y: y)
            }
            .allowsHitTesting(false)
        }
    }

    func eventCardView(event: Event) -> some View {
        let isDragging = dragState?.eventID == event.id
        let isDismissing = dismissingEventIDs.contains(event.id)
        let isFocused = focusedEventID == event.id
        let isDimmedByFocus = dragState == nil && focusedEventID != nil && !isFocused

        return cardContentView(event: event, isDismissing: isDismissing)
            .contentShape(Rectangle())
            .overlay { dragGestureOverlay(for: event) }
            .onTapGesture(count: 2) {
                guard !isSplitMode, !isMergeMode, !isTimerMode else { return }
                completeEvent(event)
            }
            .onTapGesture(count: 1) { handleCardTap(event: event) }
            .overlay(mergeHighlightOverlay(for: event))
            .animation(.easeInOut(duration: 0.15), value: mergeTargetID == event.id)
            .overlay(alignment: .bottomTrailing) { cardCalendarButton(for: event) }
            .overlay(alignment: .topLeading) { cardCompleteButton(for: event) }
            .background(cardFrameReader(for: event))
            .onPreferenceChange(CardFramePreferenceKey.self) { frames in
                if dragState == nil {
                    cardFrames.merge(frames) { _, new in new }
                }
            }
            .scaleEffect(
                isDragging ? 1.0 : (isFocused ? 1.035 : (isDimmedByFocus ? 0.93 : 1.0))
            )
            .opacity(isDragging ? 0 : (isDimmedByFocus ? 0.28 : (isDismissing ? 0 : 1.0)))
            .animation(.easeInOut(duration: 0.15), value: focusedEventID)
            .animation(.spring(response: 0.25, dampingFraction: 0.8, blendDuration: 0.1), value: isDragging)
            .zIndex(zIndex(for: event.id))
    }

    // MARK: - Card Content

    @ViewBuilder
    func cardContentView(event: Event, isDismissing: Bool) -> some View {
        EventCardView(event: event, isCompleted: checkmarkProgress[event.id] != nil)
            .scaleEffect(longPressingEventID == event.id ? 0.98 : 1.0)
            .modifier(ShakeEffect(animatableData: shakeTriggers[event.id, default: 0]))
            .animation(.easeOut(duration: 0.2), value: longPressingEventID == event.id)
            .overlay {
                if isSplitMode {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            EventTypeTemplateStore.color(for: event.type),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        )
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.3), value: isDismissing)
            .animation(.easeInOut(duration: 0.25), value: isSplitMode)
    }

    // MARK: - Drag Gesture Overlay

    @ViewBuilder
    func dragGestureOverlay(for event: Event) -> some View {
        if !isSplitMode && !isTimerMode {
            UIKitDragGestureView(
                minimumPressDuration: 0.3,
                shouldBegin: { self.shouldBeginDrag(for: event.id) },
                onPanBegan: {
                    self.bringToFront(event.id)
                    self.focusedEventID = event.id
                    self.beginDrag(for: event)
                },
                onPanChanged: { translation, windowLocation in
                    self.updateDrag(for: event.id, translation: translation)
                    if isMergeMode {
                        mergeTargetID = findMergeTarget(for: event.id, windowLocation: windowLocation)
                    } else {
                        let overDelete = self.deleteZoneFrame.contains(windowLocation)
                        self.isOverDeleteZone = overDelete
                        if overDelete {
                            if self.reorderTarget != nil {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    self.reorderTarget = nil
                                }
                            }
                        } else {
                            let newTarget = self.findReorderTarget(for: event.id, windowLocation: windowLocation, events: events)
                            if newTarget != self.reorderTarget {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    self.reorderTarget = newTarget
                                }
                                if newTarget != nil {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            }
                        }
                    }
                },
                onPanEnded: { translation, endLocation in
                    self.isOverDeleteZone = false
                    if isMergeMode, let targetID = mergeTargetID,
                       let targetEvent = store.activeEvents.first(where: { $0.id == targetID }) {
                        performMerge(source: event, target: targetEvent)
                        self.dragState = nil
                        self.isDraggingEvent = false
                        self.mergeTargetID = nil
                        self.reorderTarget = nil
                        self.dragStartFrame = nil
                        self.dragStartCardFrames = [:]
                    } else if self.reorderTarget != nil,
                              !self.deleteZoneFrame.contains(endLocation) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        let newOrder = self.previewEvents.map { $0.id }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            store.reorderEvents(inList: listID, newOrder: newOrder)
                            self.reorderTarget = nil
                            self.mergeTargetID = nil
                            self.dragStartFrame = nil
                            self.dragStartCardFrames = [:]
                            self.dragState = nil
                            self.isDraggingEvent = false
                        }
                    } else {
                        self.mergeTargetID = nil
                        self.reorderTarget = nil
                        self.endDrag(for: event, endLocation: endLocation)
                    }
                }
            )
        }
    }

    // MARK: - Tap Handling

    func handleCardTap(event: Event) {
        if isTimerMode {
            let isRunning = store.isTimerRunning(for: event)
            if isRunning {
                store.stopTimer(for: event)
            } else {
                store.startTimer(for: event)
            }
            isTimerMode = false
        } else if isSplitMode {
            splitEvent = event
            isSplitMode = false
        } else if !isMergeMode {
            bringToFront(event.id)
            selectedEvent = event
        }
    }

    // MARK: - Action Overlays

    func mergeHighlightOverlay(for event: Event) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.blue, lineWidth: mergeTargetID == event.id ? 2.5 : 0)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    func cardCalendarButton(for event: Event) -> some View {
        if !isSplitMode && !isMergeMode {
            Button {
                addToCalendarEvent = event
            } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add to calendar")
            .padding(8)
        }
    }

    @ViewBuilder
    func cardCompleteButton(for event: Event) -> some View {
        if !isSplitMode && !isMergeMode && !isTimerMode {
            Button {
                completeEvent(event)
            } label: {
                Color.clear
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    func cardFrameReader(for event: Event) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: CardFramePreferenceKey.self,
                value: [event.id: geo.frame(in: .global)]
            )
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

private struct CardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
