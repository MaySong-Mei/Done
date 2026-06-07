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

    // Attributes selected before submit, applied to the new wanna on createWanna()
    @State private var draftType: String = "Wanna"
    @State private var draftPriority: Int = 0
    @State private var draftTags: [String] = []
    @State private var showTagPopover: Bool = false
    @State private var newTagDraft: String = ""
    @FocusState private var tagFieldFocused: Bool

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
                    inputCard.padding(.bottom, 4)

                    ForEach(displayItems, id: \.event.id) { item in
                        let event = item.event
                        let sub = item.isSubItem
                        let isDragged = dragID == event.id

                        WannaCardView(
                            event: event,
                            isScheduled: event.linkedCalendarEventId != nil,
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
                            if dragID == nil {
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
            wannaHeader
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
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
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(newWannaTitle.isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)

                TextField(L(.iWannaPlaceholder), text: $newWannaTitle)
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

            if inputFocused {
                inputAttributeRow
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).combined(with: .offset(y: -6)),
                        removal: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                    ))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.001), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: inputFocused)
    }

    private var inputAttributeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Type
                Menu {
                    ForEach(["Wanna", "Study", "Work", "Exercise", "Sleep"], id: \.self) { t in
                        Button {
                            draftType = t
                        } label: {
                            if draftType == t {
                                Label(t, systemImage: "checkmark")
                            } else {
                                Text(t)
                            }
                        }
                    }
                } label: {
                    inputPill(
                        icon: "paintpalette",
                        text: draftType,
                        tint: EventTypeTemplateStore.color(for: draftType),
                        isActive: draftType != "Wanna"
                    )
                }

                // Priority
                Menu {
                    ForEach(0...3, id: \.self) { level in
                        Button {
                            draftPriority = level
                        } label: {
                            let label = level == 0 ? "None" : String(repeating: "!", count: level)
                            if draftPriority == level {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
                            }
                        }
                    }
                } label: {
                    inputPill(
                        icon: "flag",
                        text: draftPriority == 0 ? "Priority" : String(repeating: "!", count: draftPriority),
                        tint: .red,
                        isActive: draftPriority > 0
                    )
                }

                // Tags — already added tags as removable pills
                ForEach(draftTags, id: \.self) { tag in
                    Button {
                        draftTags.removeAll { $0 == tag }
                    } label: {
                        HStack(spacing: 4) {
                            Text("#\(tag)")
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(EventTypeTemplateStore.color(for: draftType))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            EventTypeTemplateStore.color(for: draftType).opacity(0.18),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Tag chip — opens a popover to add new tags
                Button {
                    showTagPopover = true
                } label: {
                    inputPill(
                        icon: "tag",
                        text: L(.addTag),
                        tint: EventTypeTemplateStore.color(for: draftType),
                        isActive: !draftTags.isEmpty
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showTagPopover, attachmentAnchor: .point(.bottom)) {
                    tagInputPopover
                        .presentationCompactAdaptation(.popover)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var tagInputPopover: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(L(.enterTag), text: $newTagDraft)
                .font(.system(size: 14))
                .focused($tagFieldFocused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { commitDraftTag() }
            Button {
                commitDraftTag()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(
                        newTagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary.opacity(0.4)
                            : Color.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(newTagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 240)
        .onAppear { tagFieldFocused = true }
    }

    private func commitDraftTag() {
        let trimmed = newTagDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !trimmed.isEmpty else { return }
        if !draftTags.contains(trimmed) {
            draftTags.append(trimmed)
        }
        newTagDraft = ""
        tagFieldFocused = true
    }

    private func inputPill(icon: String, text: String, tint: Color, isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(isActive ? tint : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((isActive ? tint : .secondary).opacity(0.12), in: Capsule())
    }

    private func createWanna() {
        let title = newWannaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let manualPriority = draftPriority > 0
        let maxPriority = store.activeEvents.map(\.priority).max() ?? 0
        let event = Event(
            title: title,
            priority: manualPriority ? draftPriority : maxPriority + 1,
            tags: draftTags,
            type: draftType
        )
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            store.add(event)
        }
        newWannaTitle = ""
        draftType = "Wanna"
        draftPriority = 0
        draftTags = []
        newTagDraft = ""
    }

    // MARK: - Completion

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

    // MARK: - Headers

    private var wannaHeader: some View {
        HStack(spacing: 10) {
            Text(L(.wannaFallback))
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
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.28), value: store.completedCount)
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L(.whatDoYouWanna))
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
