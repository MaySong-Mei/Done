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

    var body: some View {
        Group {
            if events.isEmpty {
                EmptyStateView(title: "No events", systemImage: "checklist")
            } else {
                ScrollView {
                    let columns = masonryColumns(events)
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) {
                            ForEach(columns.left) { event in
                                eventCardView(event: event)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        VStack(spacing: 12) {
                            ForEach(columns.right) { event in
                                eventCardView(event: event)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if focusedEventID != nil {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            focusedEventID = nil
                        }
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

    private func masonryColumns(_ events: [Event]) -> (left: [Event], right: [Event]) {
        var left: [Event] = []
        var right: [Event] = []
        for (i, event) in events.enumerated() {
            if i % 2 == 0 {
                left.append(event)
            } else {
                right.append(event)
            }
        }
        return (left, right)
    }
}

// MARK: - Sub Views

private extension EventGridView {

    func eventCardView(event: Event) -> some View {
        let isDragging = dragState?.eventID == event.id
        let isDismissing = dismissingEventIDs.contains(event.id)
        let isFocused = focusedEventID == event.id
        let isDimmedByFocus = focusedEventID != nil && !isFocused
        let dragOffset: CGSize = isDragging ? (dragState?.translation ?? .zero) : .zero

        return EventCardView(event: event, isCompleted: checkmarkProgress[event.id] != nil)
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
        .contentShape(Rectangle())
        .overlay {
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
                            self.isOverDeleteZone = self.deleteZoneFrame.contains(windowLocation)
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
                        } else {
                            self.mergeTargetID = nil
                            self.endDrag(for: event, endLocation: endLocation)
                        }
                    }
                )
            }
        }
        .onTapGesture(count: 2) {
            guard !isSplitMode, !isMergeMode, !isTimerMode else { return }
            completeEvent(event)
        }
        .onTapGesture(count: 1) {
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
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.blue, lineWidth: mergeTargetID == event.id ? 2.5 : 0)
                .allowsHitTesting(false)
        )
        .animation(.easeInOut(duration: 0.15), value: mergeTargetID == event.id)
        .overlay(alignment: .bottomTrailing) {
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
        .overlay(alignment: .topLeading) {
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
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: CardFramePreferenceKey.self,
                    value: [event.id: geo.frame(in: .global)]
                )
            }
        )
        .onPreferenceChange(CardFramePreferenceKey.self) { frames in
            cardFrames.merge(frames) { _, new in new }
        }
        .scaleEffect(
            isFocused ? 1.035 : (isDimmedByFocus ? 0.93 : (isDragging ? 1.05 : 1.0))
        )
        .opacity(isDimmedByFocus ? 0.28 : (isDismissing ? 0 : 1.0))
        .offset(x: dragOffset.width, y: dragOffset.height)
        .animation(.easeInOut(duration: 0.15), value: focusedEventID)
        .animation(.spring(response: 0.25, dampingFraction: 0.8, blendDuration: 0.1), value: isDragging)
        .zIndex(zIndex(for: event.id))
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

