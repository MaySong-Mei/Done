//
//  WannaListView.swift
//  Done
//
//  Flat, single-column list of intentions (wannas).
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

    // Drag reorder — live rearranging
    @State private var dragID: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragCardFrame: CGRect = .zero
    @State private var liveOrder: [UUID] = []
    @State private var itemFrames: [UUID: CGRect] = [:]

    // Complete-to-badge fly animation
    @State private var completedBadgeFrame: CGRect = .zero
    @State private var flyingWanna: FlyingWanna?
    @State private var flyingProgress: CGFloat = 0
    @State private var badgePulse: Bool = false

    fileprivate struct FlyingWanna: Equatable {
        let eventID: UUID
        let typeName: String
        let source: CGRect
    }

    /// Source of truth ordering from store.
    private var storeOrder: [(event: Event, isSubItem: Bool)] {
        let active = store.activeEvents.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        let activeIDs = Set(active.map(\.id))
        return active.map { event in
            let isSub = event.listID != nil && activeIDs.contains(event.listID!)
            return (event, isSub)
        }
    }

    /// Items in display order (live-rearranged during drag).
    private var displayItems: [(event: Event, isSubItem: Bool)] {
        let base = storeOrder
        guard dragID != nil, !liveOrder.isEmpty else { return base }
        let lookup = Dictionary(base.map { ($0.event.id, $0) }, uniquingKeysWith: { a, _ in a })
        return liveOrder.compactMap { lookup[$0] }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Main list
            ScrollView {
                LazyVStack(spacing: 6) {
                    if !isBatchMode {
                        inputCard.padding(.bottom, 4)
                    }

                    ForEach(displayItems, id: \.event.id) { item in
                        let event = item.event
                        let sub = item.isSubItem
                        let isDragged = dragID == event.id

                        WannaCardView(
                            event: event,
                            isScheduled: event.linkedCalendarEventId != nil,
                            isSelected: batchSelection.contains(event.id),
                            isBatchMode: isBatchMode,
                            onComplete: {
                                completeWithFlyingAnimation(event: event)
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
                        // During drag: ghost placeholder at original slot
                        .opacity(isDragged ? 0 : 1)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: WannaItemFrameKey.self,
                                    value: [event.id: geo.frame(in: .global)]
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
                            } else if dragID == nil {
                                selectedEventID = event.id
                            }
                        }
                        .simultaneousGesture(dragReorderGesture(event: event))
                    }

                    if displayItems.isEmpty && newWannaTitle.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .onPreferenceChange(WannaItemFrameKey.self) { itemFrames = $0 }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: liveOrder)

            // Fly-to-badge overlay — small colored disc that streaks from
            // the completed card to the "✓ N" pill in the header.
            if let flying = flyingWanna {
                let target = completedBadgeFrame
                let s = flying.source
                let x = s.midX + (target.midX - s.midX) * flyingProgress
                let y = s.midY + (target.midY - s.midY) * flyingProgress
                let scale = 1.0 - 0.6 * flyingProgress
                let opacity = 1.0 - 0.45 * flyingProgress
                ZStack {
                    Circle()
                        .fill(EventTypeTemplateStore.color(for: flying.typeName))
                        .frame(width: 30, height: 30)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
                .scaleEffect(scale)
                .opacity(opacity)
                .position(x: x, y: y)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(50)
            }

            // Floating dragged card — follows finger
            if let dragID, let item = displayItems.first(where: { $0.event.id == dragID }) {
                let sub = item.isSubItem
                WannaCardView(
                    event: item.event,
                    isScheduled: item.event.linkedCalendarEventId != nil,
                    isSelected: false,
                    isBatchMode: false,
                    onComplete: {},
                    onPushToCalendar: {},
                    onRecallFromCalendar: {},
                    onDelete: {},
                    isSubItem: sub
                )
                .padding(.leading, sub ? 28 : 0)
                .padding(.horizontal, 16)
                .scaleEffect(1.04)
                .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
                .opacity(0.92)
                .offset(y: dragCardFrame.minY + dragTranslation.height)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.scale(scale: 1.04).combined(with: .opacity))
            }
        }
        .navigationBarHidden(true)
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
    }

    // MARK: - Drag Reorder

    private func dragReorderGesture(event: Event) -> some Gesture {
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 6)
            .sequenced(before: DragGesture(minimumDistance: 6, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .second(true, let drag):
                    guard let drag else { return }
                    let h = abs(drag.translation.width)
                    let v = abs(drag.translation.height)
                    if dragID == nil {
                        // Only begin reorder on predominantly vertical drag
                        guard v > 10 && v > h * 1.5 else { return }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        liveOrder = storeOrder.map(\.event.id)
                        dragID = event.id
                        dragCardFrame = itemFrames[event.id] ?? .zero
                    }
                    dragTranslation = drag.translation
                    reorderLive(dragMidY: dragCardFrame.midY + drag.translation.height)
                default:
                    break
                }
            }
            .onEnded { _ in
                if dragID != nil {
                    commitReorder()
                }
            }
    }

    private func reorderLive(dragMidY: CGFloat) {
        guard let dragID, var order = Optional(liveOrder),
              let fromIndex = order.firstIndex(of: dragID) else { return }

        // Find which slot the dragged card's center overlaps
        var targetIndex = fromIndex
        for (i, id) in order.enumerated() {
            guard id != dragID, let frame = itemFrames[id] else { continue }
            if dragMidY < frame.midY {
                targetIndex = i
                break
            }
            targetIndex = i + 1
        }
        targetIndex = min(targetIndex, order.count - 1)

        if targetIndex != fromIndex {
            UISelectionFeedbackGenerator().selectionChanged()
            order.remove(at: fromIndex)
            order.insert(dragID, at: min(targetIndex, order.count))
            liveOrder = order
        }
    }

    private func commitReorder() {
        // Persist the new order via priority values
        let order = liveOrder
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            for (i, id) in order.enumerated() {
                let newPriority = order.count - i
                if var event = store.events.first(where: { $0.id == id }),
                   event.priority != newPriority {
                    event.priority = newPriority
                    store.update(event)
                }
            }
            dragID = nil
            dragTranslation = .zero
            dragCardFrame = .zero
            liveOrder = []
        }
    }

    // MARK: - Indent / Sub-item

    private func toggleIndent(_ event: Event) {
        var updated = event
        if event.listID != nil {
            // Promote back to top-level
            updated.listID = nil
        } else {
            // Indent — become child of the item directly above
            let items = storeOrder
            guard let parentID = findParentAbove(event, in: items) else { return }
            updated.listID = parentID
        }
        store.update(updated)
    }

    private func findParentAbove(_ event: Event, in items: [(event: Event, isSubItem: Bool)]) -> UUID? {
        guard let idx = items.firstIndex(where: { $0.event.id == event.id }), idx > 0 else { return nil }
        for i in stride(from: idx - 1, through: 0, by: -1) {
            // Always bind to a root-level item (listID == nil), never to another child
            if items[i].event.listID == nil { return items[i].event.id }
        }
        return nil
    }

    // MARK: - Inline Input

    private var inputCard: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: 18, weight: .light))
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
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
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
        let maxPriority = store.activeEvents.map(\.priority).max() ?? 0
        let event = Event(title: title, priority: maxPriority + 1, type: "Wanna")
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            store.add(event)
        }
        newWannaTitle = ""
    }

    // MARK: - Batch Mode

    private func enterBatchMode(initialID: UUID) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isBatchMode = true
        batchSelection = [initialID]
    }

    private func exitBatchMode() {
        isBatchMode = false
        batchSelection = []
    }

    private func toggleBatchSelect(_ id: UUID) {
        if batchSelection.contains(id) { batchSelection.remove(id) }
        else { batchSelection.insert(id) }
    }

    /// Complete an event with a small colored disc flying from the card to
    /// the "completed" badge in the header. Falls back to the plain spring
    /// removal when we don't have the source/target frames yet.
    private func completeWithFlyingAnimation(event: Event) {
        let source = itemFrames[event.id] ?? .zero
        guard source != .zero, completedBadgeFrame != .zero else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                store.completeWanna(event)
            }
            return
        }
        flyingWanna = FlyingWanna(eventID: event.id, typeName: event.type, source: source)
        flyingProgress = 0
        withAnimation(.timingCurve(0.55, 0.05, 0.4, 1, duration: 0.45)) {
            flyingProgress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            flyingWanna = nil
            badgePulse = true
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                store.completeWanna(event)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                badgePulse = false
            }
        }
    }

    private func batchComplete() {
        for id in batchSelection {
            if let e = store.events.first(where: { $0.id == id }) { store.completeWanna(e) }
        }
        exitBatchMode()
    }

    private func batchDelete() {
        for id in batchSelection {
            if let e = store.events.first(where: { $0.id == id }) { store.markArchived(e) }
        }
        exitBatchMode()
    }

    private func batchPushToCalendar() {
        for id in batchSelection {
            if let e = store.events.first(where: { $0.id == id }), e.linkedCalendarEventId == nil {
                store.pushWannaToCalendar(e)
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
                .background(Color.black.opacity(0.001), in: Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
            Spacer(minLength: 0)
            // Always render the badge so its frame is measurable from the
            // first tap. When `completedCount == 0` it's invisible and
            // non-interactive, but the layout is in place so the fly-to
            // animation has a valid target. Fading in when the first
            // completion lands makes the badge feel "born" from the ball.
            Button { showCompleted = true } label: {
                Text("\u{2713} \(max(store.completedCount, 1))")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(Color.black.opacity(0.001), in: Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .opacity(store.completedCount > 0 ? 1 : 0)
            .allowsHitTesting(store.completedCount > 0)
            .scaleEffect(badgePulse ? 1.18 : 1)
            .animation(.spring(response: 0.32, dampingFraction: 0.7), value: store.completedCount > 0)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: CompletedBadgeFrameKey.self,
                        value: geo.frame(in: .global)
                    )
                }
            )
        }
        .onPreferenceChange(CompletedBadgeFrameKey.self) { completedBadgeFrame = $0 }
    }

    private var batchHeader: some View {
        HStack(spacing: 10) {
            Button { exitBatchMode() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    Text("\(batchSelection.count) selected").font(.system(size: 15, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(Color.black.opacity(0.001), in: Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button { batchPushToCalendar() } label: { Image(systemName: "calendar.badge.plus") }.disabled(batchSelection.isEmpty)
                Button { batchComplete() } label: { Image(systemName: "checkmark") }.disabled(batchSelection.isEmpty)
                Button { batchDelete() } label: { Image(systemName: "trash") }.disabled(batchSelection.isEmpty)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.black.opacity(0.001), in: Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
        }
    }

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

private struct WannaItemFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct CompletedBadgeFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
