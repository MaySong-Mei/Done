//
//  EventInspectorView.swift
//  DoneMac
//
//  The right-inspector edit hub — the phone's tap→detail page, reshaped as
//  a Mac inspector pane you edit while the calendar stays visible. On a
//  recurring-series occurrence every field is editable: a field edit
//  customizes THIS occurrence (materializes an exception), while the Repeat
//  rule and Delete are scoped (this/following/all). Nothing is disabled.
//
//  Text fields commit on submit/blur AND on teardown (a local draft bound to
//  the event's id): switching selection flushes the pending edit to the
//  event it was typed into, never the newly-selected one (review #3).
//

import SwiftUI

struct EventInspectorView: View {
    @Bindable var model: EventInspectorModel
    /// Observed so the type picker refreshes the instant the catalog is
    /// edited (review #6: the old static snapshot never updated mid-pane).
    @ObservedObject var typeStore: EventTypeTemplateStore
    var onClose: () -> Void = {}

    @State private var showRepeatEditor = false
    @State private var showDeleteScope = false

    var body: some View {
        if let event = model.event {
            content(for: event)
        } else {
            // Reachable when the selected event is dropped out-of-band
            // (a sync round-trip) while the pane is open (review #7).
            ContentUnavailableView {
                Label("No longer available", systemImage: "calendar.badge.exclamationmark")
            } actions: {
                Button("Close") { onClose() }
            }
        }
    }

    @ViewBuilder
    private func content(for event: Event) -> some View {
        let scheduled = !event.renderTimeRanges(calendar: .current).isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(event)
                if model.isRecurringSeries {
                    // A field edit below customizes THIS occurrence
                    // (materializes an exception); the repeat rule itself is
                    // scoped separately.
                    Label("Editing a field customizes this occurrence.",
                          systemImage: "repeat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                kindSection(event)
                typeSection(event)
                effortSection(event)
                if event.kind == .todo {
                    todoSection(event)
                    if scheduled { timeSection() }
                } else {
                    timeSection()
                }
                repeatSection(event)
                noteSection(event)
                Divider()
                actions(event)
            }
            .padding(16)
        }
        .frame(minWidth: 260)
        .sheet(isPresented: $showRepeatEditor) {
            RepeatEditorSheet(event: event, occurrenceDate: model.selectedOccurrenceDate) {
                unit, interval, endType, endDate, endCount, scope in
                model.applyRepeat(unit: unit, interval: interval, endType: endType,
                                  endDate: endDate, endCount: endCount, scope: scope, now: Date())
                showRepeatEditor = false
            } onCancel: { showRepeatEditor = false }
        }
    }

    // MARK: - Repeat

    private func repeatSection(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Repeat")
            HStack {
                Text(model.repeatSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(event.repeatUnit == .none ? "Add…" : "Edit…") { showRepeatEditor = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Header (title)

    private func header(_ event: Event) -> some View {
        HStack(alignment: .top) {
            InspectorTextField(
                eventID: event.id,
                text: event.title,
                placeholder: "Untitled",
                font: .title3.bold(),
                commit: { id, value in model.setTitle(id: id, value, now: Date()) },
                onFocusChange: { model.textField(focused: $0) }
            )
            Spacer(minLength: 8)
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close inspector")
        }
    }

    // MARK: - Kind

    private func kindSection(_ event: Event) -> some View {
        Picker("Kind", selection: Binding(
            get: { event.kind },
            set: { model.setKind(id: event.id, $0, now: Date()) }
        )) {
            Text("Event").tag(Event.Kind.event)
            Text("Todo").tag(Event.Kind.todo)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Type (color) picker

    private func typeSection(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Type")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(EventInspectorView.typeChoices(currentType: event.type,
                                                       templates: typeStore.templates), id: \.self) { title in
                    let selected = event.type == title
                    Button { model.setType(id: event.id, title, now: Date()) } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(EventTypeTemplateStore.color(for: title))
                                .frame(width: 10, height: 10)
                            Text(title)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selected ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.10))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor,
                                              lineWidth: selected ? 1.5 : 0)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The catalog's type titles, falling back to the built-ins on a fresh
    /// install — and always including the event's CURRENT type, so a custom
    /// or legacy value the catalog doesn't list still shows as selected
    /// instead of vanishing (review #6).
    static func typeChoices(currentType: String, templates: [EventTypeTemplate]) -> [String] {
        var titles = (templates.isEmpty ? EventTypeCatalog.fallbackTemplates : templates).map(\.title)
        let trimmed = currentType.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && !titles.contains(trimmed) {
            titles.insert(trimmed, at: 0)
        }
        return titles
    }

    /// The after-count the Repeat sheet should show/apply when the scope
    /// changes: the scoped REMAINING count only when the cadence is unchanged
    /// (the "split, keep the schedule" case); otherwise the user's current
    /// value stands, because a remaining count under a new unit/interval has
    /// no meaning (code-review F6).
    static func scopedAfterCount(series: Event, draftUnit: Event.RepeatUnit, draftInterval: Int,
                                 occurrenceDate: Date?, scope: Event.RecurrenceEditScope,
                                 current: Int?) -> Int? {
        guard draftUnit == series.repeatUnit, draftInterval == series.repeatInterval else { return current }
        return Event.scopedRepeatEndCount(series: series, occurrenceDate: occurrenceDate, requestedScope: scope)
    }

    // MARK: - Effort scrubber (the sanctioned colorDepth write)

    private func effortSection(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("Effort")
                Spacer()
                if model.effortRating != nil {
                    Button("Clear") { model.setEffort(id: event.id, nil, now: Date()) }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                ForEach(1...5, id: \.self) { rating in
                    let filled = (model.effortRating ?? 0) >= rating
                    Button { model.setEffort(id: event.id, rating, now: Date()) } label: {
                        Circle()
                            .fill(filled ? Color.accentColor : Color.gray.opacity(0.22))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Effort \(rating)")
                }
            }
        }
    }

    // MARK: - Event / scheduled-todo time

    private func timeSection() -> some View {
        // The occurrence's range (from the model) — for a series this is the
        // SELECTED day's projected range, so the picker shows and writes the
        // day you clicked, not the template's day 0 (QA F1).
        guard let event = model.event else { return AnyView(EmptyView()) }
        let range = model.occurrenceRange
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Time")
            if let range {
                DatePicker("Start", selection: Binding(
                    get: { range.start },
                    set: { model.setStart(id: event.id, $0, now: Date()) }
                ))
                DatePicker("End", selection: Binding(
                    get: { range.end },
                    set: { model.setEnd(id: event.id, $0, now: Date()) }
                ))
            } else {
                Text("Unscheduled").foregroundStyle(.secondary).font(.caption)
            }
        })
    }

    // MARK: - Todo (deadline + done)

    private func todoSection(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.toggleDone(id: event.id, now: Date())
            } label: {
                Label(event.isDone ? "Completed" : "Mark Done",
                      systemImage: event.isDone ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.bordered)
            .tint(event.isDone ? .green : .accentColor)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Deadline", isOn: Binding(
                    get: { event.deadline != nil },
                    set: { on in
                        model.setDeadline(id: event.id,
                                          on ? (event.deadline ?? Date()) : nil,
                                          now: Date())
                    }
                ))
                if let deadline = event.deadline {
                    DatePicker("Due", selection: Binding(
                        get: { deadline },
                        set: { model.setDeadline(id: event.id, $0, now: Date()) }
                    ))
                }
            }
        }
    }

    // MARK: - Note

    private func noteSection(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Note")
            InspectorTextEditor(
                eventID: event.id,
                text: event.note,
                commit: { id, value in model.setNote(id: id, value, now: Date()) },
                onFocusChange: { model.textField(focused: $0) }
            )
            .frame(minHeight: 70)
        }
    }

    // MARK: - Actions

    private func actions(_ event: Event) -> some View {
        HStack {
            if event.canReturnToStack {
                Button("Return to Stack") { model.returnToStack(id: event.id, now: Date()) }
            }
            Spacer()
            // deleteScoped clears selection → the pane closes on its own. For a
            // series the button opens a scope dialog; a one-off deletes outright.
            Button("Delete", role: .destructive) {
                if model.isRecurringSeries {
                    showDeleteScope = true
                } else {
                    model.deleteScoped(scope: .all, now: Date())
                }
            }
            .confirmationDialog("Delete repeating event?",
                                isPresented: $showDeleteScope, titleVisibility: .visible) {
                Button("This event only") { model.deleteScoped(scope: .single, now: Date()) }
                Button("This and following") { model.deleteScoped(scope: .following, now: Date()) }
                Button("All events", role: .destructive) { model.deleteScoped(scope: .all, now: Date()) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// A single-line field that edits a local draft and commits only on submit,
/// on focus-loss, OR on teardown — so a burst of keystrokes is zero store
/// commits (the anti-#201 discipline), and switching selection flushes the
/// pending edit to the event it was TYPED into (the captured `eventID`),
/// never to whatever is selected at commit time (review #3).
private struct InspectorTextField: View {
    let eventID: UUID
    let text: String
    let placeholder: String
    var font: Font = .body
    let commit: (UUID, String) -> Void
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var draft: String = ""
    @State private var lastCommitted: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                if !focused { draft = newValue }
            }
            .onSubmit { commitIfChanged() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commitIfChanged() }
                onFocusChange(isFocused)
            }
            .onDisappear {
                commitIfChanged()
                if focused { onFocusChange(false) }
            }
    }

    /// Commit each distinct draft value at most once. submit/blur/teardown can
    /// all fire for one edit, and on a recurring-series field the first commit
    /// re-selects → `.id` teardown → onDisappear re-fires; without this guard
    /// that second commit mints a PHANTOM day-0 exception (code-review F1).
    private func commitIfChanged() {
        guard draft != text, draft != lastCommitted else { return }
        lastCommitted = draft
        commit(eventID, draft)
    }
}

/// The multi-line twin of InspectorTextField — same commit-on-blur/teardown
/// rule, same id-captured flush.
private struct InspectorTextEditor: View {
    let eventID: UUID
    let text: String
    let commit: (UUID, String) -> Void
    var onFocusChange: (Bool) -> Void = { _ in }

    @State private var draft: String = ""
    @State private var lastCommitted: String?
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .font(.body)
            .focused($focused)
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                if !focused { draft = newValue }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commitIfChanged() }
                onFocusChange(isFocused)
            }
            .onDisappear {
                commitIfChanged()
                if focused { onFocusChange(false) }
            }
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Add a note…")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }

    /// Same commit-once-per-draft guard as InspectorTextField (code-review F1).
    private func commitIfChanged() {
        guard draft != text, draft != lastCommitted else { return }
        lastCommitted = draft
        commit(eventID, draft)
    }
}

/// The repeat-rule sheet: seeds a draft from the event's current rule, drives
/// the shared RecurrenceRuleControl, and — only when the event is ALREADY a
/// series — offers the apply scope (all vs this-and-following). A plain event
/// gaining a rule needs no scope (it just becomes a series).
private struct RepeatEditorSheet: View {
    let event: Event
    let occurrenceDate: Date?
    let onApply: (Event.RepeatUnit, Int, Event.RepeatEndType, Date?, Int?, Event.RecurrenceEditScope) -> Void
    let onCancel: () -> Void

    @State private var unit: Event.RepeatUnit
    @State private var interval: Int
    @State private var endType: Event.RepeatEndType
    @State private var endDate: Date?
    @State private var endCount: Int?
    @State private var scope: Event.RecurrenceEditScope = .all

    init(event: Event, occurrenceDate: Date?,
         onApply: @escaping (Event.RepeatUnit, Int, Event.RepeatEndType, Date?, Int?, Event.RecurrenceEditScope) -> Void,
         onCancel: @escaping () -> Void) {
        self.event = event
        self.occurrenceDate = occurrenceDate
        self.onApply = onApply
        self.onCancel = onCancel
        _unit = State(initialValue: event.repeatUnit)
        _interval = State(initialValue: event.repeatInterval)
        _endType = State(initialValue: event.repeatEndType)
        _endDate = State(initialValue: event.repeatEndDate)
        // Seed the count SCOPED to the initial (.all) scope; the scope picker
        // re-derives it on change. This keeps the number shown == the number
        // applied, so a `.following` edit runs the REMAINING count, not a
        // fresh copy of the whole-series count (review F5 / gh#126).
        _endCount = State(initialValue: Event.scopedRepeatEndCount(
            series: event, occurrenceDate: occurrenceDate, requestedScope: .all))
    }

    private var isSeries: Bool { event.repeatUnit != .none }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Repeat").font(.title3.bold())
            RecurrenceRuleControl(unit: $unit, interval: $interval,
                                  endType: $endType, endDate: $endDate, endCount: $endCount)
            if isSeries {
                Divider()
                Picker("Apply to", selection: $scope) {
                    Text("All events").tag(Event.RecurrenceEditScope.all)
                    Text("This & following").tag(Event.RecurrenceEditScope.following)
                }
                .pickerStyle(.segmented)
                .onChange(of: scope) { _, newScope in
                    // Re-derive the after-count for the chosen scope so the
                    // field the user sees is the count that will apply — but
                    // ONLY when the cadence is unchanged. A "remaining count"
                    // under a NEW unit/interval is undefined, so if the user
                    // edited the cadence, keep the count they set (code-review
                    // F6).
                    if endType == .afterCount {
                        endCount = EventInspectorView.scopedAfterCount(
                            series: event, draftUnit: unit, draftInterval: interval,
                            occurrenceDate: occurrenceDate, scope: newScope, current: endCount)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(unit, interval, endType, endDate, endCount, isSeries ? scope : .all)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
