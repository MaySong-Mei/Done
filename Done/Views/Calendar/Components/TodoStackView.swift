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
    /// Host height — the panel's full-page detent, and the bound its
    /// chrome drag rubber-bands against.
    @State private var containerHeight: CGFloat = 0

    private var isDragging: Bool { draggingTodo != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(isDragging ? 0.02 : 0.25)
                .ignoresSafeArea()
                .onTapGesture { dismissDrawer() }
                .transition(.opacity)

            // The panel rides as an overlay on a spacer that takes the
            // proposal, because a ZStack sizes to the *union* of its
            // children and the panel is deliberately taller than the
            // container while its chrome drag rubber-bands past full page.
            // As a direct child it fed its own height back through
            // `containerHeight` — which is both the rubber-band bound and
            // the drag's origin — and the two grew each other ~22pt per
            // frame until AttributeGraph wedged. An overlay can never size
            // its primary, so the spacer stays pinned to the proposal.
            // Hit testing off on the spacer only: the overlay is a separate
            // subtree, so the backdrop keeps its tap-to-dismiss.
            Color.clear
                .allowsHitTesting(false)
                // Measured here, not on the ZStack: this spacer is the one
                // child that definitionally takes the proposal, so it can
                // never report a height the panel inflated.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    containerHeight = height
                }
                .overlay(alignment: .bottom) {
                    // While a card is being dragged the drawer slides out of
                    // the way (stays mounted — removing it would cancel the
                    // active gesture) so the canvas underneath is visible
                    // for targeting.
                    TodoStackView(
                        isPresented: $isPresented,
                        containerHeight: containerHeight,
                        onDragBegan: dragBegan(_:),
                        onDragMoved: dragMoved(to:),
                        onDragEnded: dragEnded(at:),
                        onDragCancelled: dragCancelled
                    )
                    // Clears the tallest current device (13" iPad portrait ≈
                    // 1366pt full-page panel) — 1000 left a third of the
                    // glass covering the canvas there.
                    .offset(y: isDragging ? 2000 : 0)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

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
    /// Height of the host container — the full-page detent.
    var containerHeight: CGFloat = 0
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
    /// "Cut the deck": the oldest card that has sat in the stack for more
    /// than 7 days gets flipped to the top with a small caption. Resolved
    /// once per drawer open — see `resetForOpen`, which is what actually
    /// makes "per open" true. Deck-native anti-graveyard: no grouping, no
    /// archive, no notification — just one old card surfacing back into
    /// view each time the drawer opens.
    @State private var resurfacedTodoID: UUID?
    /// Pulled up into a full page. Written by `settleChrome` on every
    /// non-dismissing release and cleared by `resetForOpen()`; read only
    /// through `isFullPage`, which discounts it while a reversed dismissal
    /// unwinds.
    ///
    /// Deliberately NOT "resets with the drawer because the drawer
    /// unmounts on close" — that was the comment here, and it was wrong.
    /// A re-open during the removal transition reverses it, so the view
    /// never unmounts and nothing per-open resets on its own.
    @State private var fullPageSettled = false
    /// Live chrome-drag translation. `@GestureState` so a cancelled
    /// gesture unwinds on its own; the reset transaction springs the panel
    /// home when the release lands back on the detent it started from.
    @GestureState(resetTransaction: Transaction(animation: .spring(response: 0.35, dampingFraction: 0.85)))
    private var chromeDrag: CGFloat = 0
    /// Natural drawer height, measured while the panel rests there — the
    /// middle detent, and the height the chrome drag starts from.
    @State private var drawerHeight: CGFloat = 0
    /// Height a dismissing flick was released at, held through the removal
    /// transition so the panel keeps going from under the finger instead of
    /// popping back to drawer height for a frame first.
    ///
    /// Three writers, not one: `settleChrome` sets it on a dismissing
    /// release and clears it on every other release, and `resetForOpen()`
    /// clears it. What they add up to — and the property
    /// `dismissalWasReversed` actually reads — is that it is non-nil only
    /// between a dismissing release and the next `resetForOpen()` or
    /// non-dismissing release. `chromeDragHeights` additionally refuses to
    /// read it while the drawer is presented.
    @State private var dismissingHeight: CGFloat?

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
        .frame(maxWidth: .infinity, maxHeight: isExpandedLayout ? .infinity : nil, alignment: .top)
        .frame(height: chromeDragHeights?.layout, alignment: .top)
        .frame(height: chromeDragHeights?.window, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            guard todoStackShouldRecordDrawerHeight(
                height: height,
                isFullPage: isFullPage,
                isChromeDragging: chromeDragHeights != nil,
                containerHeight: containerHeight
            ) else { return }
            drawerHeight = height
        }
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
        .onAppear { resetForOpen() }
        .onChange(of: isPresented) { _, presented in
            // The present edge, for the open that never mounted: a re-open
            // during the removal transition reverses it, so `.onAppear`
            // above does not fire a second time. Whether this lands — and
            // whether it lands before the first body pass of the re-open —
            // depends on the removed subtree having been evaluated once
            // with `isPresented == false`, which is not something the
            // source can promise. So it is the hygiene pass, not the fix:
            // `chromeDragHeights` and `isFullPage` both derive the reversal
            // inline instead of waiting for this.
            if presented { resetForOpen() }
        }
        .onDisappear {
            // Data preservation: never drop an in-flight title edit just
            // because the drawer got dismissed mid-edit.
            if let id = expandedTodoID { commitTitle(for: id) }
            // Same for a half-typed capture — the field is its only copy,
            // and dismissing is now one flick away.
            captureTodo()
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

    /// A dismissal was committed and then undone by re-opening before the
    /// removal transition finished. SwiftUI reverses the transition rather
    /// than completing it, so the view never unmounts: `.onDisappear` and
    /// `.onAppear` both stay silent and nothing per-open resets itself.
    ///
    /// `dismissingHeight` surviving into a *presented* drawer is that
    /// signature. It goes non-nil on one write only — a dismissing release
    /// — and the two writes that clear it (a non-dismissing release, and
    /// `resetForOpen()`) both mean the drawer landed somewhere real. So the
    /// signature cannot outlive the next chrome release or the next open,
    /// whichever comes first.
    private var dismissalWasReversed: Bool { isPresented && dismissingHeight != nil }

    /// The full-page detent. Derived rather than read straight off
    /// `fullPageSettled` so a reversed open is indistinguishable from a
    /// fresh one, which always starts at the drawer detent — otherwise
    /// "flick down to dismiss, re-open within 0.35s" is the only open in
    /// the app's life that comes back full-page.
    private var isFullPage: Bool { fullPageSettled && !dismissalWasReversed }

    /// Height of the detent the panel currently rests on.
    private var restHeight: CGFloat { isFullPage ? containerHeight : drawerHeight }

    /// Panel heights under the finger, nil at rest. `layout` is the height
    /// the content is laid out in — it only ever grows past the detent, so
    /// pulling up reveals more list; `window` is the visible frame, so
    /// pulling down slides the panel off the bottom edge instead of
    /// reflowing the list on its way out.
    private var chromeDragHeights: (layout: CGFloat, window: CGFloat)? {
        // `!isPresented` is a guard, not an `onChange`: the dismissal
        // height is only meaningful while the drawer is going away, and a
        // reversed open has to be laid out correctly on its FIRST body
        // pass. An `onChange(of: isPresented)` clear runs after the body
        // that already observed the new value, so it lands a frame late —
        // and only if the removed subtree was evaluated at all.
        if let dismissingHeight, !isPresented {
            return (layout: max(restHeight, dismissingHeight), window: dismissingHeight)
        }
        guard chromeDrag != 0, containerHeight > 0, drawerHeight > 0 else { return nil }
        let height = todoStackChromeHeight(
            restHeight: restHeight,
            translationY: chromeDrag,
            containerHeight: containerHeight
        )
        return (layout: max(restHeight, height), window: height)
    }

    /// Full-page layout — at the full-page detent, and throughout a chrome
    /// drag, where the list has to be free to grow with the panel.
    private var isExpandedLayout: Bool { isFullPage || chromeDragHeights != nil }

    /// The chrome tracks the finger 1:1 (see `chromeDragHeights`); nothing
    /// commits until release, so the drag stays reversible.
    private var chromeDragGesture: some Gesture {
        // minimumDistance 1, not the conventional ~10: the higher threshold
        // makes recognition timing-sensitive (drops synthetic/fast flicks
        // and can leak the touch to the backdrop tap). The chrome zone has
        // no competing child drag, so claiming early is safe — the X
        // button still wins its own taps.
        DragGesture(minimumDistance: 1)
            .updating($chromeDrag) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                settleChrome(value)
            }
    }

    /// Settle to the detent `todoStackSettleDetent` picks: the release has
    /// to project a deliberate distance from where it started before it
    /// moves at all, and then it lands on whichever detent in that
    /// direction it was heading for. Projected end, not where the finger
    /// stopped, so a short fast flick commits and a long slow drag that ran
    /// out of speed falls back to where it started.
    ///
    /// No "a settle is in flight" flag guards `drawerHeight` while this
    /// animation runs. `onGeometryChange` does not report the interpolated
    /// frames of an animation at all — device QA (gh#128 round 4) drove a
    /// full-page → drawer settle and the intermediate heights never reached
    /// the measurement gate — so the only heights the gate ever sees are
    /// settled layouts, and each of the three outcomes is a settled layout
    /// it already handles:
    ///
    /// - full page → `fullPageSettled` is true and no dismissal is
    ///   pending, so `isFullPage` is true;
    /// - dismissed → `dismissingHeight` is non-nil and `isPresented` is
    ///   false, so `chromeDragHeights` is non-nil;
    /// - drawer → the panel lays out at the drawer detent, which is exactly
    ///   the value `drawerHeight` is supposed to hold.
    ///
    /// (An earlier version of this comment argued the interpolated frames
    /// *are* observed and merely harmless. They are not observed. The
    /// conclusion held; the stated reason was wrong.)
    ///
    /// A flag would have to be cleared from `withAnimation`'s completion,
    /// and a completion that doesn't run for a no-op change would freeze
    /// `drawerHeight` for the life of the drawer — which is the snap-to-a-
    /// stale-height bug this whole slice exists to remove.
    private func settleChrome(_ value: DragGesture.Value) {
        // A release that lands while the drawer is already on its way out
        // must not clear `dismissingHeight` — the panel would snap back to
        // drawer height mid-removal — nor write `fullPageSettled` for a
        // drawer nobody can see. Insurance, not a fix: device QA could not
        // reach it, with chrome touches at +0.05/+0.12/+0.20s into the
        // removal all swallowed by the backdrop.
        guard isPresented else { return }
        guard let target = todoStackSettleDetent(
            restHeight: restHeight,
            predictedEndTranslationY: value.predictedEndTranslation.height,
            drawerHeight: drawerHeight,
            containerHeight: containerHeight
        ) else { return }
        if target == .dismissed {
            // Deliberately outside the `withAnimation` below: this is layout
            // input, not something to interpolate. The two writes land in the
            // same runloop turn, so one body pass observes both — and
            // `chromeDragHeights` depends on that coalescing, because it
            // reads this height only while `!isPresented`. A pass that saw
            // `isPresented == false` while this was still nil would lay the
            // panel out at drawer height for a frame on its way out.
            dismissingHeight = todoStackChromeHeight(
                restHeight: restHeight,
                translationY: value.translation.height,
                containerHeight: containerHeight
            )
            if let id = expandedTodoID { commitTitle(for: id) }
        } else {
            // Every release leaves this defined. Without the else a
            // reversed dismissal would keep the drawer discounted as
            // "reversing" forever, and full page would stop being
            // reachable for the rest of the open.
            dismissingHeight = nil
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if target == .dismissed {
                isPresented = false
            } else {
                // The settle names the detent it chose; nothing here re-reads
                // it off a height. "The release landed at the container
                // height" is not the same question as "the release chose full
                // page" — when the keyboard has squeezed the drawer up against
                // the container the two are one number, and answering the
                // second with the first is how a drawer stayed full page after
                // the keyboard that compressed it had gone away.
                fullPageSettled = target == .fullPage
            }
        }
    }

    /// Everything that is true of a drawer the user just opened. Called
    /// from `.onAppear` for a fresh mount and from the present edge for a
    /// re-open that reversed its own removal and therefore never mounted.
    private func resetForOpen() {
        dismissingHeight = nil
        fullPageSettled = false
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        resurfacedTodoID = store.datelessTodos
            .filter { $0.createdAt < cutoff }
            .min(by: { $0.createdAt < $1.createdAt })?
            .id
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
        .frame(maxHeight: isExpandedLayout ? .infinity : 320)
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

// MARK: - Chrome drag geometry

/// UIScrollView's resistance curve `(x·c·d)/(d + c·x)`. Its two real
/// properties: the first points past the bound travel at `c` — 55%, not
/// 1:1 — and the overshoot asymptotes to `limit`, never past it.
///
/// Non-positive inputs return 0: the caller clamps before the bound so a
/// negative overshoot never reaches here, and a limit of zero leaves no
/// room to resist into. Both would otherwise sit near the pole at
/// `overshoot == -limit / c`.
///
/// Pure / testable. No UI side effects.
func todoStackRubberBand(overshoot: CGFloat, limit: CGFloat) -> CGFloat {
    let coefficient: CGFloat = 0.55
    guard overshoot > 0, limit > 0 else { return 0 }
    return (overshoot * coefficient * limit) / (limit + overshoot * coefficient)
}

/// Panel height for a chrome-drag translation, measured down from the
/// detent the drag started on — rubber-banded past the full-page bound,
/// clamped at dismissed.
///
/// Overshoot caps at 55% of the panel. Passing `containerHeight` itself as
/// the limit would let it reach twice the screen — the resistance here is
/// a hint that the bound exists, not a second detent.
///
/// A host that has not been measured yet (`containerHeight <= 0`) has no
/// bound to resist against, so the finger is tracked 1:1 and clamped at
/// dismissed. Without that case the rubber-band branch would hand a zero
/// limit to `todoStackRubberBand` — which correctly returns 0 for it — and
/// collapse the panel to nothing for any positive height.
///
/// Pure / testable. No UI side effects.
func todoStackChromeHeight(
    restHeight: CGFloat,
    translationY: CGFloat,
    containerHeight: CGFloat
) -> CGFloat {
    let height = restHeight - translationY
    guard containerHeight > 0 else { return max(0, height) }
    guard height > containerHeight else { return max(0, height) }
    return containerHeight + todoStackRubberBand(
        overshoot: height - containerHeight,
        limit: containerHeight * 0.55
    )
}

/// The three places a chrome release can land.
///
/// Named rather than numbered because a height is ambiguous and a name is
/// not: with the keyboard up the drawer detent and the container are the
/// same number, so "the release landed at the container height" reads as
/// full page when it is nothing of the sort. `todoStackSettleDetent` is
/// the sole owner of which detent a release chose, and the view maps this
/// value to state instead of re-deriving it from the resulting height.
enum TodoStackDetent: Equatable {
    case dismissed
    case drawer
    case fullPage
}

/// Shortest projected travel that commits to the next detent — the price
/// of a deliberate move, measured from the detent the drag started on.
///
/// One touch target. Below this, a chrome nudge that came along with a tap
/// or a scroll hand-off commits a state change the user did not ask for:
/// with the software keyboard up the drawer sits 37.67pt below full page
/// on the reference device, and half of that is a 19pt promotion that
/// survived the keyboard going away (gh#128 round 4).
///
/// Deliberately NOT tuned against that round's measurement table. Most of
/// `TodoStackView`'s type is set in fixed point sizes that do not respond
/// to Dynamic Type at all — `.system(size:)` at the card title, the empty
/// state, the capture field and the row glyphs — which is why default→AX5
/// grew the panel only 39pt. The measured gaps are a reading of a broken
/// accessibility implementation, not a stable table, and fixing those
/// fonts (its own slice, not this one) will grow the panel and shrink
/// every gap in it. This floor is what takes over when that happens, which
/// is most of why the rule is shaped as a clamp rather than a constant.
let todoStackMinimumCommitTravel: CGFloat = 44

/// Longest projected travel any single detent change may cost.
///
/// Half the gap is the right price on ordinary geometry and an absurd one
/// at the far end: on a 13" iPad the drawer rests ~880pt below full page,
/// and 440pt of sustained one-directional drag is a re-grip, not a
/// gesture.
let todoStackMaximumCommitTravel: CGFloat = 120

/// The price of moving between two detents `gap` apart: half the gap,
/// clamped at both ends.
///
/// Sole owner of "how deliberate does this have to be". Half the gap is
/// the old nearest-detent rule restated as a threshold — the midpoint is
/// exactly where nearest flipped — and the clamps are the two ends where
/// the midpoint stops being a price anyone would name.
///
/// Pure / testable. No UI side effects.
func todoStackCommitTravel(gap: CGFloat) -> CGFloat {
    min(max(gap / 2, todoStackMinimumCommitTravel), todoStackMaximumCommitTravel)
}

/// The detent a chrome release settles to.
///
/// The rule: a release that projects more than `todoStackCommitTravel` from
/// the detent it started on moves at least one detent in that direction,
/// landing on whichever detent in that direction it ended up nearest;
/// anything shorter stays where it started. Projected end, not where the
/// finger stopped, so a short fast flick commits and a long slow drag that
/// ran out of speed falls back.
///
/// Why a threshold and not "nearest detent wins": nearest has no dead zone,
/// so two detents that end up close together are one incidental nudge
/// apart — and, at the other end, two detents far apart cost half of a very
/// large gap. The threshold *is* the midpoint on ordinary geometry; the
/// clamps only bite where the midpoint stopped meaning anything. An earlier
/// round answered the near end by deleting the full-page detent instead,
/// which made the drawer unexpandable at AX5 on an SE, where the legitimate
/// gap is 85.5pt: a silent capability loss with no cue and no recovery.
/// Raising a price is discoverable — you feel yourself not quite getting
/// there, and the rubber band already says the bound is real.
///
/// Full page drops out of the ladder entirely when it sits less than
/// `todoStackMinimumCommitTravel` above the drawer. That is the one case
/// the floor decides, and it is a destination that does nothing: with the
/// keyboard up the drawer is squeezed to within 37.67pt of the container
/// (0 on an SE, 10 on an 11" iPad), so arriving moves the panel less than
/// the shortest gesture that can ask for it — while latching a mode that
/// only shows itself later, when the keyboard goes away and the full page
/// nobody saw becomes the whole screen. It decides no case in the band
/// real devices produce with the keyboard down: 85.5pt is the tightest
/// measured.
///
/// nil when the detents aren't measured yet (either bound at zero); the
/// release is then absorbed rather than settled somewhere arbitrary. A
/// drawer measured taller than its host clamps to it, which drops full page
/// out of the ladder rather than inverting the two.
///
/// Ties go to the shorter detent — the ladder is ordered shortest-first and
/// `min(by:)` keeps the first of equal elements — so a release that lands
/// exactly between two candidates in its direction takes the one that
/// commits less. That first-of-equals behaviour is pinned by
/// `testSettleDetentLandsOnTheShorterDetentOnAnExactTie`, not promised by
/// the stdlib.
///
/// Pure / testable. No UI side effects.
func todoStackSettleDetent(
    restHeight: CGFloat,
    predictedEndTranslationY: CGFloat,
    drawerHeight: CGFloat,
    containerHeight: CGFloat
) -> TodoStackDetent? {
    let full = containerHeight
    let drawer = min(drawerHeight, full)
    guard full > 0, drawer > 0 else { return nil }

    var ladder: [(detent: TodoStackDetent, height: CGFloat)] = [(.dismissed, 0), (.drawer, drawer)]
    if full - drawer >= todoStackMinimumCommitTravel {
        ladder.append((.fullPage, full))
    }
    // The detent the drag started on. `restHeight` is one of them by
    // construction; asking the ladder which keeps that true even when the
    // panel is resting on a detent the ladder no longer offers — a drawer
    // promoted to full page before the keyboard came up and squeezed the
    // two together, which then demotes on the next release rather than
    // holding a destination that no longer exists.
    guard let origin = ladder.min(by: { abs($0.height - restHeight) < abs($1.height - restHeight) })
    else { return nil }

    let projected = restHeight - predictedEndTranslationY
    let travel = projected - origin.height
    let ascending = travel > 0
    let ahead = ladder.filter { ascending ? $0.height > origin.height : $0.height < origin.height }
    // The price is set by the *first* step — "move at least one detent" is
    // the decision, and how far past it the flick carries only picks where
    // it lands. The ladder is sorted, so the adjacent detent is the near
    // end of `ahead`.
    guard let neighbour = ascending ? ahead.first : ahead.last else { return origin.detent }
    let price = todoStackCommitTravel(gap: abs(neighbour.height - origin.height))
    guard abs(travel) > price else { return origin.detent }
    return ahead.min(by: { abs($0.height - projected) < abs($1.height - projected) })?.detent
        ?? origin.detent
}

/// Whether a measured panel height is the natural drawer detent — the only
/// thing `drawerHeight` may be set from, since whatever lands there is the
/// middle detent until the panel next lays out.
///
/// Refused: the full-page detent, and any frame the chrome drag is forcing
/// — which covers both the finger being down and the height held through a
/// dismissal. Plus zero, which would take the gesture inert: both
/// `chromeDragHeights` and `todoStackSettleDetent` refuse to work from a
/// drawer of no height.
///
/// Nothing else, and the missing term is the point. A previous round also
/// refused `height >= containerHeight`, reasoning that a drawer detent
/// equal to its host is degenerate. It killed the gesture on every fresh
/// open: the panel reports its height before the host's measurement has
/// propagated, so the first — and, until something else resizes the panel,
/// only — measurement of an open arrives with `containerHeight == 0`, where
/// every height "fills the host". `drawerHeight` stayed 0 and the drag never
/// started. The general lesson, which is why the term is gone rather than
/// repaired: **a semantic gets exactly one function, and a guard that
/// re-tests it numerically is a bug report against that function, not a
/// fix.** Whether the drawer and the full page are distinct places to be is
/// `todoStackSettleDetent`'s ladder to answer, and it answers the degenerate
/// case correctly — a drawer recorded at the container height leaves a gap
/// of 0, full page is not a destination, and the `[0, full, full]` collapse
/// the term existed to prevent cannot happen.
///
/// A small-but-positive frame — 50 on a panel that wants 488 — would do the
/// same damage as a zero and passes this. Left unguarded on purpose: no
/// producer of one is known (nothing here resizes the panel through a
/// transition, and `onGeometryChange` does not report interpolated
/// animation frames), and inventing a floor against a hypothetical is how
/// the term above came to be written. If a producer ever turns up, the fix
/// belongs where the frame is produced.
///
/// `containerHeight` is unread. It stays in the signature because the case
/// that broke is stated in terms of it — a panel measurement arriving
/// before its host has one — and the regression test has to be able to say
/// that in the caller's own terms.
///
/// A settle in flight needs no term either: `onGeometryChange` does not
/// report interpolated animation frames, and each of the three settle
/// outcomes is a settled layout the guards above already handle (see
/// `settleChrome`).
///
/// No focus term, though there was one. It refused any height measured
/// while the capture field held focus unless the panel had grown, on the
/// theory that the keyboard compresses the panel to *exactly* the
/// container. Device QA (gh#128 round 4) found that branch did no
/// observable work, and the settle's ladder covers the near-miss — a height
/// that lands just short of the container — which the growth term never
/// did. Recording the compressed height is also what keeps a chrome drag
/// from jumping: `restHeight` has to be where the panel actually is.
///
/// Pure / testable. No UI side effects.
func todoStackShouldRecordDrawerHeight(
    height: CGFloat,
    isFullPage: Bool,
    isChromeDragging: Bool,
    containerHeight: CGFloat
) -> Bool {
    guard !isFullPage, !isChromeDragging else { return false }
    return height > 0
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
            // `shouldShow` reads only drag-begin/end + flash state (not the
            // per-frame touch point), so an event/resize drag never
            // invalidates this body. Read `currentTouchPointGlobal` — which
            // changes every frame — only once we're actually rendering.
            let shouldShow = isEligibleDrag || flashTodo != nil
            let screenHeight = proxy.frame(in: .global).maxY
            let touchY = shouldShow ? dragState.currentTouchPointGlobal?.y : nil
            let height = flashTodo != nil
                ? TodoPutBackPeekMetrics.flashHeight
                : TodoPutBackPeekMetrics.height(touchY: touchY, screenHeight: screenHeight)
            let inZone = flashTodo == nil
                && touchY.map { TodoPutBackPeekMetrics.isInZone(touchY: $0, screenHeight: screenHeight) } == true

            if shouldShow {
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
