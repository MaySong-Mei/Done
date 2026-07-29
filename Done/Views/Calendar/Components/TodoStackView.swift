import SwiftUI

/// Bottom drawer hosting the Todo stack — todos captured without a time
/// (`kind == .todo`, empty `timeRanges`). Deliberately minimal by design:
/// capture at the top, tap a card to edit title/deadline inline, and
/// (later slice) drag a card onto the canvas to schedule it. No grouping,
/// no manual reordering, no bulk actions — the stack is the canvas's
/// waiting room, not a second list app.
struct TodoStackDrawer: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var orientationManager: OrientationManager

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .transition(.opacity)
                .onTapGesture { dismissDrawer() }

            TodoStackView(isPresented: $isPresented)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .onChange(of: orientationManager.manualFocusActive) { _, focusActive in
            // Focus is a ceremony for inhabiting one event; the stack is
            // ambient noise there. Close the drawer when focus engages.
            if focusActive {
                isPresented = false
            }
        }
    }

    private func dismissDrawer() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isPresented = false
        }
    }
}

struct TodoStackView: View {
    @EnvironmentObject private var store: EventStore
    @Binding var isPresented: Bool

    @State private var newTitle: String = ""
    @FocusState private var inputFocused: Bool
    @State private var expandedTodoID: UUID?
    @State private var editingTitle: String = ""

    var body: some View {
        VStack(spacing: 10) {
            header
            captureField
            if orderedTodos.isEmpty {
                emptyState
            } else {
                cardList
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(
            Color.black.opacity(0.001),
            in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
        )
        .glassEffect(
            .regular,
            in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
        )
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
        .frame(maxHeight: 320)
    }

    @ViewBuilder
    private func card(for todo: Event) -> some View {
        let isExpanded = expandedTodoID == todo.id
        VStack(alignment: .leading, spacing: 10) {
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
                    deleteTodo(todo)
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
