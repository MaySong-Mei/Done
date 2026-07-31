import SwiftUI

/// Drop target resolved for a Todo-stack card mid-drag. `absorbParentID`
/// non-nil means the finger sits inside an event block and release will
/// absorb the todo into that event instead of scheduling it.
struct TodoStackDropPreview: Equatable {
    var start: Date
    var absorbParentID: UUID?
    var absorbParentTitle: String?
}

/// Bottom drawer hosting the Todo stack — todos captured without a time
/// (`kind == .todo`, empty `timeRanges`). Deliberately minimal by design:
/// capture at the top, tap a card to edit title/deadline inline, and
/// long-press-drag a card out onto the canvas to schedule it (or into an
/// event block to absorb it). No grouping, no manual reordering, no bulk
/// actions — the stack is the canvas's waiting room, not a second list app.
struct TodoStackDrawer: View {
    @Binding var isPresented: Bool
    /// (global point, dragged todo id) → live drop target, nil = cancel zone.
    var resolveDrop: (CGPoint, UUID) -> TodoStackDropPreview? = { _, _ in nil }
    /// Commit a release at a global point. Returns false when the point
    /// resolves to nothing (drag cancels, drawer restores).
    var commitDrop: (UUID, CGPoint) -> Bool = { _, _ in false }

    @EnvironmentObject private var orientationManager: OrientationManager
    @State private var draggingTodo: Event?
    @State private var dragPoint: CGPoint = .zero
    @State private var dropPreview: TodoStackDropPreview?

    private var isDragging: Bool { draggingTodo != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(isDragging ? 0.02 : 0.25)
                .ignoresSafeArea()
                .onTapGesture { dismissDrawer() }
                .transition(.opacity)

            // While a card is being dragged the drawer slides out of the
            // way (stays mounted — removing it would cancel the active
            // gesture) so the canvas underneath is visible for targeting.
            TodoStackView(
                isPresented: $isPresented,
                onDragBegan: dragBegan(_:),
                onDragMoved: dragMoved(to:),
                onDragEnded: dragEnded(at:),
                onDragCancelled: dragCancelled
            )
            // Clears the tallest current device (13" iPad portrait ≈
            // 1366pt full-page panel) — 1000 left a third of the glass
            // covering the canvas there.
            .offset(y: isDragging ? 2000 : 0)
            .transition(.move(edge: .bottom).combined(with: .opacity))

            dragChipLayer
        }
        .onChange(of: orientationManager.manualFocusActive) { _, focusActive in
            // Focus is a ceremony for inhabiting one event; the stack is
            // ambient noise there. Close the drawer when focus engages.
            if focusActive {
                isPresented = false
            }
        }
    }

    // MARK: - Drag chip

    /// Floating chip that follows the finger, lifted above it so the card
    /// stays readable, with a pill announcing the resolved drop: snapped
    /// time (schedule), parent title (absorb), or a cancel glyph.
    @ViewBuilder
    private var dragChipLayer: some View {
        if let todo = draggingTodo, dragPoint != .zero {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                TodoStackDragChip(
                    title: todo.title.isEmpty ? L(.untitledTodo) : todo.title,
                    preview: dropPreview
                )
                .position(
                    x: dragPoint.x - origin.x,
                    y: dragPoint.y - origin.y - 44
                )
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    // MARK: - Drag lifecycle

    private func dragBegan(_ todo: Event) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dropPreview = nil
        dragPoint = .zero
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            draggingTodo = todo
        }
    }

    private func dragMoved(to point: CGPoint) {
        dragPoint = point
        guard let todo = draggingTodo else { return }
        let next = resolveDrop(point, todo.id)
        if next != dropPreview {
            // Tick on every 15-min snap step / target change — the
            // whisper-level equivalent of the canvas drag haptics.
            if next != nil { UISelectionFeedbackGenerator().selectionChanged() }
            dropPreview = next
        }
    }

    private func dragEnded(at point: CGPoint) {
        guard let todo = draggingTodo else { return }
        // WYSIWYG gate: commit only when the user saw a live target pill.
        // A long-press released without ever moving can still deliver a
        // final drag value at the press point — which maps to a canvas
        // time hidden UNDER the drawer, one the user never saw.
        let sawTarget = dragPoint != .zero && dropPreview != nil
        // dropPreview must survive a successful commit: the chip fades out
        // for 0.35s and a nil preview renders the cancel glyph on the
        // success frames (#123). dragCancelled / dragBegan reset it.
        if sawTarget, commitDrop(todo.id, point) {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                draggingTodo = nil
                // The card just landed on the canvas — that's the user's
                // context now; don't spring the drawer back over it.
                isPresented = false
            }
        } else {
            dragCancelled()
        }
    }

    private func dragCancelled() {
        dropPreview = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            draggingTodo = nil
        }
    }

    private func dismissDrawer() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isPresented = false
        }
    }
}

/// The chip that follows the finger during a stack-card drag.
private struct TodoStackDragChip: View {
    let title: String
    let preview: TodoStackDropPreview?

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 220)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)

            pill
        }
    }

    @ViewBuilder
    private var pill: some View {
        if let preview {
            Group {
                if let parentTitle = preview.absorbParentTitle {
                    Label(parentTitle, systemImage: "arrow.down.circle.fill")
                        .lineLimit(1)
                } else {
                    Text(preview.start, format: .dateTime.hour().minute())
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                (preview.absorbParentID != nil ? Color.orange : Color.accentColor).opacity(0.95),
                in: Capsule()
            )
        } else {
            Image(systemName: "slash.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        }
    }
}

struct TodoStackView: View {
    @EnvironmentObject private var store: EventStore
    @Binding var isPresented: Bool
    var onDragBegan: (Event) -> Void = { _ in }
    var onDragMoved: (CGPoint) -> Void = { _ in }
    var onDragEnded: (CGPoint) -> Void = { _ in }
    var onDragCancelled: () -> Void = {}

    @State private var newTitle: String = ""
    @FocusState private var inputFocused: Bool
    @State private var expandedTodoID: UUID?
    @State private var editingTitle: String = ""
    @State private var dragActive = false
    /// Delete waits for confirmation — `deleteCalendarEvent` also prunes
    /// the todo's log/feedback records, so a stray tap must not be
    /// irreversible (matches the detail page's delete-with-alert habit).
    @State private var pendingDeleteTodo: Event?
    /// "Cut the deck": resolved once per drawer open — the oldest card
    /// that has sat in the stack for more than 7 days gets flipped to
    /// the top with a small caption. Deck-native anti-graveyard: no
    /// grouping, no archive, no notification — just one old card
    /// surfacing back into view each time the drawer opens.
    @State private var resurfacedTodoID: UUID?
    /// Pulled up into a full page. Resets with the drawer (plain @State —
    /// the drawer unmounts on close).
    @State private var isFullPage = false

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 10) {
                grabber
                header
            }
            .contentShape(Rectangle())
            .gesture(chromeDragGesture)
            captureField
            if orderedTodos.isEmpty {
                emptyState
            } else {
                cardList
            }
            if isFullPage {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: isFullPage ? .infinity : nil, alignment: .top)
        .background {
            // The glass runs through the bottom safe area to the physical
            // screen edge. Without this the panel's bottom hugged the safe
            // area and the strip below it read as a dead dimmed band.
            Color.black.opacity(0.001)
                .glassEffect(
                    .regular,
                    in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
                )
                .ignoresSafeArea(edges: .bottom)
        }
        .confirmationDialog(
            L(.deleteConfirmSingle),
            isPresented: Binding(
                get: { pendingDeleteTodo != nil },
                set: { if !$0 { pendingDeleteTodo = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L(.delete), role: .destructive) {
                if let todo = pendingDeleteTodo { deleteTodo(todo) }
                pendingDeleteTodo = nil
            }
        }
        .onAppear {
            let cutoff = Date().addingTimeInterval(-7 * 86400)
            resurfacedTodoID = store.datelessTodos
                .filter { $0.createdAt < cutoff }
                .min(by: { $0.createdAt < $1.createdAt })?
                .id
        }
        .onDisappear {
            // Data preservation: never drop an in-flight title edit just
            // because the drawer got dismissed mid-edit.
            if let id = expandedTodoID { commitTitle(for: id) }
        }
    }

    // MARK: - Ordering

    /// Stack order: newest capture on top (push order is a temporal fact,
    /// not user arrangement). A single most-urgent card — earliest
    /// deadline that is overdue or within 24h — floats to the top as a
    /// whisper; everything else keeps push order even when it carries a
    /// deadline, so obligations don't bury pure wants.
    private var orderedTodos: [Event] {
        var items = store.datelessTodos.sorted { $0.createdAt > $1.createdAt }
        let now = Date()
        let urgentIndex = items.indices
            .filter { index in
                guard let deadline = items[index].deadline else { return false }
                return deadline.timeIntervalSince(now) < 24 * 3600
            }
            .min { lhs, rhs in
                (items[lhs].deadline ?? .distantFuture) < (items[rhs].deadline ?? .distantFuture)
            }
        if let urgentIndex, urgentIndex != 0 {
            let urgent = items.remove(at: urgentIndex)
            items.insert(urgent, at: 0)
        }
        // The cut card wins the very top — surfacing is the whole point;
        // an urgent card stays visible through its color and deadline
        // label wherever it sits.
        if let resurfacedTodoID,
           let index = items.firstIndex(where: { $0.id == resurfacedTodoID }),
           index != 0 {
            let resurfaced = items.remove(at: index)
            items.insert(resurfaced, at: 0)
        }
        return items
    }

    /// Same ramp as the canvas todo border (EventBlock.todoBorderColor):
    /// overdue → red, within 24h → orange, otherwise neutral.
    private func urgencyAccent(for todo: Event) -> Color {
        guard let deadline = todo.deadline else { return Color.secondary.opacity(0.35) }
        let now = Date()
        if deadline < now { return Color.red.opacity(0.95) }
        if deadline.timeIntervalSince(now) < 24 * 3600 { return Color.orange.opacity(0.95) }
        return Color.secondary.opacity(0.35)
    }

    private func isUrgent(_ todo: Event) -> Bool {
        guard let deadline = todo.deadline else { return false }
        return deadline.timeIntervalSinceNow < 24 * 3600
    }

    private func waitingDays(for todo: Event) -> Int {
        max(0, Int(Date().timeIntervalSince(todo.createdAt) / 86400))
    }

    // MARK: - Chrome (grabber + expand/collapse drag)

    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
    }

    /// Pull the chrome up → full page; pull down → back to the drawer,
    /// or dismiss when already at drawer height. Threshold-based with a
    /// spring — the card list and card drags are untouched (the gesture
    /// lives on the grabber/header zone only).
    private var chromeDragGesture: some Gesture {
        // minimumDistance 1, not the conventional ~10: the higher threshold
        // makes recognition timing-sensitive (drops synthetic/fast flicks
        // and can leak the touch to the backdrop tap). The chrome zone has
        // no competing child drag, so claiming early is safe — the X
        // button still wins its own taps.
        DragGesture(minimumDistance: 1)
            .onEnded { value in
                let dy = value.translation.height
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    if dy < -60 {
                        isFullPage = true
                    } else if dy > 60 {
                        if isFullPage {
                            isFullPage = false
                        } else {
                            if let id = expandedTodoID { commitTitle(for: id) }
                            isPresented = false
                        }
                    }
                }
            }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(L(.kindTodo))
                .font(.headline)
            if !store.datelessTodos.isEmpty {
                Text("\(store.datelessTodos.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button {
                dismissDrawer()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Capture

    /// Title-only capture: a name is enough to enter the stack; deadline
    /// and everything else can be added later from the card editor.
    private var captureField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(newTitle.isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor)

            TextField(L(.iWannaPlaceholder), text: $newTitle)
                .font(.system(size: 16, weight: .medium))
                .focused($inputFocused)
                .onSubmit { captureTodo() }
                .submitLabel(.done)

            if !newTitle.isEmpty {
                Button {
                    captureTodo()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func captureTodo() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var todo = Event(title: title)
        todo.kind = .todo
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.addCalendarEvent(todo)
        }
        newTitle = ""
    }

    // MARK: - Cards

    private var cardList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(orderedTodos) { todo in
                    card(for: todo)
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: isFullPage ? .infinity : 320)
    }

    @ViewBuilder
    private func card(for todo: Event) -> some View {
        let isExpanded = expandedTodoID == todo.id
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(urgencyAccent(for: todo))
                        .frame(width: 3, height: 18)

                    Text(todo.title.isEmpty ? L(.untitledTodo) : todo.title)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(isExpanded ? nil : 1)

                    Spacer(minLength: 4)

                    if let deadline = todo.deadline {
                        Text(deadline, format: .dateTime.month().day())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isUrgent(todo) ? urgencyAccent(for: todo) : Color.secondary)
                    }
                }

                if todo.id == resurfacedTodoID {
                    Label(
                        String(format: L(.todoResurfaceWaitingFormat), waitingDays(for: todo)),
                        systemImage: "arrow.uturn.up"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 11)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleExpanded(todo) }

            if isExpanded {
                cardEditor(for: todo)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isUrgent(todo) ? urgencyAccent(for: todo) : Color.secondary.opacity(0.2),
                    lineWidth: 1
                )
        )
        // The inline editor owns its own long-press interactions (text
        // cursor loupe, pickers) — masking the drag out while expanded
        // keeps a text-selection hold from flinging the card onto the
        // canvas mid-edit.
        .gesture(dragGesture(for: todo), including: isExpanded ? .subviews : .all)
    }

    // MARK: - Drag out

    /// Long-press (0.3s) then drag, in global coordinates so the drawer
    /// host can hit-test the canvas underneath. The system `.onDrag` path
    /// is deliberately avoided — it's documented dead-on-arrival against
    /// the canvas's UIKit long-press gestures (TimelineView.swift:3800).
    private func dragGesture(for todo: Event) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .second(true, nil):
                    startDrag(todo)
                case .second(true, .some(let drag)):
                    if !dragActive { startDrag(todo) }
                    onDragMoved(drag.location)
                default:
                    break
                }
            }
            .onEnded { value in
                let wasActive = dragActive
                dragActive = false
                if case .second(true, .some(let drag)) = value, wasActive {
                    onDragEnded(drag.location)
                } else if wasActive {
                    onDragCancelled()
                }
            }
    }

    private func startDrag(_ todo: Event) {
        guard !dragActive else { return }
        if let id = expandedTodoID {
            commitTitle(for: id)
            expandedTodoID = nil
        }
        // Dismiss the keyboard — it floats in its own window and would
        // cover the lower canvas during the drag while drops kept
        // resolving invisibly beneath it.
        inputFocused = false
        dragActive = true
        onDragBegan(todo)
    }

    // MARK: - Inline editor

    private func cardEditor(for todo: Event) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L(.title), text: $editingTitle)
                .font(.system(size: 15))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onSubmit { commitTitle(for: todo.id) }
                .submitLabel(.done)

            Toggle(isOn: deadlineEnabledBinding(for: todo.id)) {
                Text(todo.deadline == nil ? L(.noDeadline) : L(.hasDeadline))
                    .font(.subheadline)
            }

            if todo.deadline != nil {
                DatePicker(
                    "",
                    selection: deadlineDateBinding(for: todo.id),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    pendingDeleteTodo = todo
                } label: {
                    Label(L(.delete), systemImage: "trash")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.secondary.opacity(0.5))
            Text(L(.whatDoYouWanna))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Mutations

    private func toggleExpanded(_ todo: Event) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if expandedTodoID == todo.id {
                commitTitle(for: todo.id)
                expandedTodoID = nil
            } else {
                if let previous = expandedTodoID { commitTitle(for: previous) }
                editingTitle = todo.title
                expandedTodoID = todo.id
            }
        }
    }

    private func commitTitle(for id: UUID) {
        guard var event = store.rawCalendarEvents.first(where: { $0.id == id }) else { return }
        let trimmed = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != event.title else { return }
        event.title = trimmed
        store.updateCalendarEvent(event)
    }

    private func deleteTodo(_ todo: Event) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if expandedTodoID == todo.id { expandedTodoID = nil }
            store.deleteCalendarEvent(todo)
        }
    }

    private func updateDeadline(_ newValue: Date?, eventID: UUID) {
        guard var event = store.rawCalendarEvents.first(where: { $0.id == eventID }) else { return }
        event.deadline = newValue
        store.updateCalendarEvent(event)
    }

    private func deadlineEnabledBinding(for eventID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                store.rawCalendarEvents.first(where: { $0.id == eventID })?.deadline != nil
            },
            set: { isOn in
                let current = store.rawCalendarEvents.first(where: { $0.id == eventID })?.deadline
                updateDeadline(isOn ? (current ?? Date()) : nil, eventID: eventID)
            }
        )
    }

    private func deadlineDateBinding(for eventID: UUID) -> Binding<Date> {
        Binding(
            get: {
                store.rawCalendarEvents.first(where: { $0.id == eventID })?.deadline ?? Date()
            },
            set: { updateDeadline($0, eventID: eventID) }
        )
    }

    private func dismissDrawer() {
        if let id = expandedTodoID { commitTitle(for: id) }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isPresented = false
        }
    }
}

// MARK: - Put-back peek (canvas → stack)

/// Geometry shared between the peek overlay and
/// `CalendarPageView.handleTimelineEventDragEnded`'s commit check — the
/// zone the user sees highlighted MUST be the zone that commits
/// (WYSIWYG, same rule as the drag-out slice).
enum TodoPutBackPeekMetrics {
    /// Resting hint while an eligible todo drag is anywhere on the canvas.
    static let sliverHeight: CGFloat = 20
    /// Full drop-target height; also the commit zone measured from the
    /// bottom screen edge.
    static let fullHeight: CGFloat = 96
    /// Peek height while the landed-card flash plays — taller than the
    /// drop zone so the card clears the tab bar, which is already back
    /// by the time the flash shows.
    static let flashHeight: CGFloat = 140
    /// Distance from the bottom edge where the sliver starts growing.
    static let approachBand: CGFloat = 220

    static func isInZone(touchY: CGFloat, screenHeight: CGFloat) -> Bool {
        touchY >= screenHeight - fullHeight
    }

    static func height(touchY: CGFloat?, screenHeight: CGFloat) -> CGFloat {
        guard let touchY else { return sliverHeight }
        let distFromBottom = screenHeight - touchY
        guard distFromBottom < approachBand else { return sliverHeight }
        let t = max(0, min(1, (approachBand - distFromBottom) / (approachBand - fullHeight)))
        return sliverHeight + (fullHeight - sliverHeight) * t
    }
}

/// Bottom drop target for returning a scheduled todo to the stack —
/// appears only while a `canReturnToStack` todo block is move-dragged on
/// the canvas. Driven entirely by the shared `EventDragState`
/// (@Observable, per-frame `currentTouchPointGlobal` writes); it adds no
/// callbacks to the drag pipeline and never intercepts touches — the
/// commit decision lives with the drag-ended handler.
struct TodoPutBackPeek: View {
    let dragState: EventDragState
    /// Set for a beat right after a put-back commits: the peek holds its
    /// full height and shows the landed card before retracting — the
    /// "where did it go" answer the drop feedback owes the user.
    var flashTodo: Event?

    private var isEligibleDrag: Bool {
        dragState.draggingEventID != nil
            && dragState.dragMode == .move
            && dragState.draggingEvent?.canReturnToStack == true
    }

    var body: some View {
        GeometryReader { proxy in
            let screenHeight = proxy.frame(in: .global).maxY
            let touchY = dragState.currentTouchPointGlobal?.y
            let height = flashTodo != nil
                ? TodoPutBackPeekMetrics.flashHeight
                : TodoPutBackPeekMetrics.height(touchY: touchY, screenHeight: screenHeight)
            let inZone = flashTodo == nil
                && touchY.map { TodoPutBackPeekMetrics.isInZone(touchY: $0, screenHeight: screenHeight) } == true

            if isEligibleDrag || flashTodo != nil {
                VStack(spacing: 6) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 44, height: 5)
                        .padding(.top, 7)
                    if let flashTodo {
                        peekCard(title: flashTodo.title, ghost: false)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    } else if inZone, let dragged = dragState.draggingEvent {
                        // WYSIWYG: inside the zone the peek previews the
                        // card this block is about to become.
                        peekCard(title: dragged.title, ghost: true)
                            .transition(.opacity)
                    } else if height > 56 {
                        Label(L(.returnToTodoStack), systemImage: "tray.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.secondary)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(.regularMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(inZone ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.35))
                        .frame(height: inZone ? 2.5 : 1)
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isEligibleDrag)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: flashTodo?.id)
        .ignoresSafeArea()
    }

    /// The stack-card look, reused for the in-zone ghost preview and the
    /// landed flash. Mirrors the drawer card's shape at peek scale.
    @ViewBuilder
    private func peekCard(title: String, ghost: Bool) -> some View {
        Text(title.isEmpty ? L(.untitledTodo) : title)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: 260)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ghost ? Color.accentColor.opacity(0.08) : Color(.systemBackground).opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        ghost ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.25),
                        style: ghost ? StrokeStyle(lineWidth: 1.5, dash: [5, 3]) : StrokeStyle(lineWidth: 1)
                    )
            )
            .opacity(ghost ? 0.85 : 1)
    }
}
