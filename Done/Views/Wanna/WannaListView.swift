//
//  WannaListView.swift
//  Done
//
//  Flat, single-column list of intentions (wannas).
//  A wanna is an Event with no timeRanges — pure intent, not yet scheduled.
//  Sub-items use listID to reference their parent wanna's ID.
//

import SwiftUI

struct WannaListView: View {
    @EnvironmentObject var store: EventStore
    @State private var showCompleted = false
    @State private var selectedEventID: UUID?
    @State private var newWannaTitle = ""
    @FocusState private var inputFocused: Bool

    // Batch mode
    @State private var isBatchMode = false
    @State private var batchSelection: Set<UUID> = []

    // Drag reorder
    @State private var dragItemID: UUID?
    @State private var dragOffset: CGSize = .zero
    @State private var dragSourceIndex: Int?
    @State private var dragTargetIndex: Int?
    @State private var itemFrames: [UUID: CGRect] = [:]

    /// Ordered flat list for rendering: parents followed by their children.
    private var orderedItems: [(event: Event, isSubItem: Bool)] {
        let active = store.activeEvents.sorted {
            ($0.priority) > ($1.priority)
        }
        let parents = active.filter { $0.listID == nil }
        let childrenByParent = Dictionary(grouping: active.filter { $0.listID != nil }, by: { $0.listID! })

        var result: [(Event, Bool)] = []
        for parent in parents {
            result.append((parent, false))
            if let children = childrenByParent[parent.id] {
                for child in children.sorted(by: { $0.priority > $1.priority }) {
                    result.append((child, true))
                }
            }
        }
        let parentIDs = Set(parents.map(\.id))
        for child in active where child.listID != nil && !parentIDs.contains(child.listID!) {
            result.append((child, false))
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if !isBatchMode && dragItemID == nil {
                    inputCard
                        .padding(.bottom, 4)
                }

                ForEach(Array(orderedItems.enumerated()), id: \.element.event.id) { index, item in
                    let event = item.event
                    let sub = item.isSubItem
                    let isDragging = dragItemID == event.id
                    let isDropTarget = dragTargetIndex == index && dragItemID != event.id

                    WannaCardView(
                        event: event,
                        isScheduled: event.linkedCalendarEventId != nil,
                        isSelected: batchSelection.contains(event.id),
                        isBatchMode: isBatchMode,
                        onComplete: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                store.completeWanna(event)
                            }
                        },
                        onPushToCalendar: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                store.pushWannaToCalendar(event)
                            }
                        },
                        onRecallFromCalendar: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                store.recallWannaFromCalendar(event)
                            }
                        },
                        onDelete: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                store.markArchived(event)
                            }
                        },
                        onToggleSelect: { toggleBatchSelect(event.id) },
                        onToggleIndent: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                toggleIndent(event)
                            }
                        },
                        isSubItem: sub
                    )
                    .padding(.leading, sub ? 28 : 0)
                    .scaleEffect(sub ? 0.97 : 1, anchor: .leading)
                    .opacity(isDragging ? 0.3 : 1)
                    .scaleEffect(isDropTarget ? 1.02 : 1)
                    .overlay(alignment: .top) {
                        if isDropTarget {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(height: 3)
                                .padding(.horizontal, 8)
                                .offset(y: -4)
                                .transition(.opacity)
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: WannaItemFrameKey.self,
                                value: [event.id: geo.frame(in: .named("wannaList"))]
                            )
                        }
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: -8)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))
                    ))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isBatchMode {
                            toggleBatchSelect(event.id)
                        } else if dragItemID == nil {
                            selectedEventID = event.id
                        }
                    }
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.4)
                            .sequenced(before: DragGesture())
                            .onChanged { value in
                                switch value {
                                case .second(true, let drag):
                                    if dragItemID == nil {
                                        startDrag(event: event, index: index)
                                    }
                                    if let drag {
                                        dragOffset = drag.translation
                                        updateDropTarget(dragMidY: (itemFrames[event.id]?.midY ?? 0) + drag.translation.height)
                                    }
                                default:
                                    break
                                }
                            }
                            .onEnded { _ in
                                finishDrag()
                            }
                    )
                }

                if orderedItems.isEmpty && newWannaTitle.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .coordinateSpace(name: "wannaList")
            .onPreferenceChange(WannaItemFrameKey.self) { frames in
                itemFrames = frames
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            if isBatchMode {
                batchHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            } else {
                wannaHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
        .navigationDestination(item: $selectedEventID) { eventID in
            WannaDetailView(eventID: eventID)
                .environmentObject(store)
        }
        .sheet(isPresented: $showCompleted) {
            NavigationStack {
                CompletedListView()
                    .environmentObject(store)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isBatchMode)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragTargetIndex)
    }

    // MARK: - Drag Reorder

    private func startDrag(event: Event, index: Int) {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        dragItemID = event.id
        dragSourceIndex = index
        dragTargetIndex = index
    }

    private func updateDropTarget(dragMidY: CGFloat) {
        let items = orderedItems
        var closest: (index: Int, distance: CGFloat)?
        for (i, item) in items.enumerated() {
            guard let frame = itemFrames[item.event.id] else { continue }
            let dist = abs(frame.midY - dragMidY)
            if closest == nil || dist < closest!.distance {
                closest = (i, dist)
            }
        }
        if let target = closest?.index, target != dragTargetIndex {
            let generator = UISelectionFeedbackGenerator()
            generator.selectionChanged()
            dragTargetIndex = target
        }
    }

    private func finishDrag() {
        guard let sourceIdx = dragSourceIndex,
              let targetIdx = dragTargetIndex,
              sourceIdx != targetIdx else {
            resetDragState()
            return
        }

        let items = orderedItems
        guard items.indices.contains(sourceIdx),
              items.indices.contains(targetIdx) else {
            resetDragState()
            return
        }

        let movedEvent = items[sourceIdx].event
        let targetEvent = items[targetIdx].event

        // Swap priorities to reorder
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            var updated = movedEvent
            updated.priority = targetEvent.priority
            store.update(updated)

            // Shift other items' priorities
            let ascending = sourceIdx < targetIdx
            let range = ascending ? (sourceIdx + 1)...targetIdx : targetIdx...(sourceIdx - 1)
            for i in range where items.indices.contains(i) {
                var shifted = items[i].event
                shifted.priority += ascending ? 1 : -1
                store.update(shifted)
            }
        }

        resetDragState()
    }

    private func resetDragState() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            dragItemID = nil
            dragOffset = .zero
            dragSourceIndex = nil
            dragTargetIndex = nil
        }
    }

    // MARK: - Indent / Sub-item

    private func toggleIndent(_ event: Event) {
        if event.listID != nil {
            var updated = event
            updated.listID = nil
            store.update(updated)
        } else {
            guard let parentID = findParentAbove(event) else { return }
            var updated = event
            updated.listID = parentID
            store.update(updated)
        }
    }

    private func findParentAbove(_ event: Event) -> UUID? {
        let items = orderedItems
        guard let idx = items.firstIndex(where: { $0.event.id == event.id }), idx > 0 else { return nil }
        for i in stride(from: idx - 1, through: 0, by: -1) {
            if !items[i].isSubItem {
                return items[i].event.id
            }
        }
        return nil
    }

    // MARK: - Inline Input

    private var inputCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(newWannaTitle.isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)

            TextField("I wanna...", text: $newWannaTitle)
                .font(.system(size: 16, weight: .medium))
                .focused($inputFocused)
                .onSubmit { createWanna() }
                .submitLabel(.done)

            if !newWannaTitle.isEmpty {
                Button {
                    createWanna()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(inputFocused ? 0.3 : 0.12), lineWidth: 1)
        )
    }

    private func createWanna() {
        let title = newWannaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        // New items get highest priority so they appear at top
        let maxPriority = store.activeEvents.map(\.priority).max() ?? 0
        let event = Event(title: title, priority: maxPriority + 1, type: "Wanna")
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            store.add(event)
        }
        newWannaTitle = ""
    }

    // MARK: - Batch Mode

    private func enterBatchMode(initialID: UUID) {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        isBatchMode = true
        batchSelection = [initialID]
    }

    private func exitBatchMode() {
        isBatchMode = false
        batchSelection = []
    }

    private func toggleBatchSelect(_ id: UUID) {
        if batchSelection.contains(id) {
            batchSelection.remove(id)
        } else {
            batchSelection.insert(id)
        }
    }

    private func batchComplete() {
        for id in batchSelection {
            if let event = store.events.first(where: { $0.id == id }) {
                store.completeWanna(event)
            }
        }
        exitBatchMode()
    }

    private func batchDelete() {
        for id in batchSelection {
            if let event = store.events.first(where: { $0.id == id }) {
                store.markArchived(event)
            }
        }
        exitBatchMode()
    }

    private func batchPushToCalendar() {
        for id in batchSelection {
            if let event = store.events.first(where: { $0.id == id }),
               event.linkedCalendarEventId == nil {
                store.pushWannaToCalendar(event)
            }
        }
        exitBatchMode()
    }

    // MARK: - Headers

    private var wannaHeader: some View {
        HStack(spacing: 10) {
            Text("Wanna")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer(minLength: 0)

            if store.completedCount > 0 {
                Button {
                    showCompleted = true
                } label: {
                    Text("\u{2713} \(store.completedCount)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var batchHeader: some View {
        HStack(spacing: 10) {
            Button {
                exitBatchMode()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(batchSelection.count) selected")
                        .font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button { batchPushToCalendar() } label: {
                    Image(systemName: "calendar.badge.plus")
                }
                .disabled(batchSelection.isEmpty)

                Button { batchComplete() } label: {
                    Image(systemName: "checkmark")
                }
                .disabled(batchSelection.isEmpty)

                Button { batchDelete() } label: {
                    Image(systemName: "trash")
                }
                .disabled(batchSelection.isEmpty)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("What do you wanna do?")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Preference Key

private struct WannaItemFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
