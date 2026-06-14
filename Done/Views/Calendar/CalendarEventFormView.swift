//
//  CalendarEventFormView.swift
//  Done
//
//  Calendar event form - Google Calendar content with Todo visual style
//

import SwiftUI
import UniformTypeIdentifiers

func calendarTypeChipAutoFocusTarget(
    previousSelectedTypeTitle: String,
    nextSelectedTypeTitle: String
) -> String? {
    let trimmedNextTitle = nextSelectedTypeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedNextTitle.isEmpty else {
        return nil
    }

    let previous = EventTypeTemplateStore.normalizedTitle(previousSelectedTypeTitle)
    let next = EventTypeTemplateStore.normalizedTitle(trimmedNextTitle)
    guard previous != next else {
        return nil
    }

    return trimmedNextTitle
}

struct CalendarEventFormView: View {
    private struct TemplateEditorMode: Identifiable {
        let id = UUID()
        let originalTitle: String?
        let initialTitle: String
        let initialColorHex: String
    }

    let navigationTitle: String
    let agenticIntake: AgenticIntakeRecord?
    let onDeleteRequest: (() -> Void)?
    let allowsAutomaticTypeSelection: Bool
    let onSave: (CalendarEventFormData) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: EventStore
    @StateObject private var templateStore = EventTypeTemplateStore()
    @State private var title: String
    @State private var kind: Event.Kind
    @State private var deadline: Date?
    @State private var selectedTypeTitle: String
    @State private var isAllDay: Bool
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var location: String
    @State private var note: String
    @State private var repeatUnit: Event.RepeatUnit
    @State private var repeatInterval: Int
    @State private var repeatEndType: Event.RepeatEndType
    @State private var repeatEndDate: Date
    @State private var repeatEndCount: Int
    @State private var selectedPeopleIDs: [UUID]
    @State private var showPeoplePicker: Bool = false
    private enum DateFieldExpansion: Hashable {
        case date(String)
        case time(String)
    }
    @State private var expandedDateField: DateFieldExpansion?
    @State private var showAgenticIntakeDetails: Bool = false
    @State private var editorMode: TemplateEditorMode?
    @State private var draggingTemplateID: UUID?
    @State private var didExplicitlySelectType: Bool = false
    @State private var automaticTypeSelectionTask: Task<Void, Never>?
    @State private var pendingFocusedTypeTitle: String?

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        navigationTitle: String,
        initialTitle: String,
        initialKind: Event.Kind = .event,
        initialDeadline: Date? = nil,
        initialTypeTitle: String,
        initialNote: String,
        initialLocation: String = "",
        initialStartTime: Date,
        initialEndTime: Date,
        initialIsAllDay: Bool = false,
        initialRepeatUnit: Event.RepeatUnit = .none,
        initialRepeatInterval: Int = 1,
        initialRepeatEndType: Event.RepeatEndType = .none,
        initialRepeatEndDate: Date? = nil,
        initialRepeatEndCount: Int? = nil,
        initialPeopleIDs: [UUID] = [],
        agenticIntake: AgenticIntakeRecord? = nil,
        allowsAutomaticTypeSelection: Bool = false,
        onDeleteRequest: (() -> Void)? = nil,
        onSave: @escaping (CalendarEventFormData) -> Void
    ) {
        self.navigationTitle = navigationTitle
        self.agenticIntake = agenticIntake
        self.allowsAutomaticTypeSelection = allowsAutomaticTypeSelection
        self.onDeleteRequest = onDeleteRequest
        self.onSave = onSave
        _title = State(initialValue: initialTitle)
        _kind = State(initialValue: initialKind)
        _deadline = State(initialValue: initialDeadline)
        _selectedTypeTitle = State(initialValue: initialTypeTitle)
        _note = State(initialValue: initialNote)
        _startTime = State(initialValue: initialStartTime)
        _endTime = State(initialValue: initialEndTime)
        _isAllDay = State(initialValue: initialIsAllDay)
        _location = State(initialValue: initialLocation)
        _repeatUnit = State(initialValue: initialRepeatUnit)
        _repeatInterval = State(initialValue: initialRepeatInterval)
        _repeatEndType = State(initialValue: initialRepeatEndType)
        _repeatEndDate = State(initialValue: initialRepeatEndDate ?? Calendar.current.date(byAdding: .month, value: 1, to: initialStartTime) ?? initialStartTime)
        _repeatEndCount = State(initialValue: initialRepeatEndCount ?? 10)
        _selectedPeopleIDs = State(initialValue: initialPeopleIDs)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                titleSection
                kindSection
                if kind == .todo {
                    deadlineSection
                }
                typeSection
                peopleSection
                timeSection
                repeatSection
                descriptionSection
                if agenticIntake != nil {
                    agenticSourceSection
                }
                if let onDeleteRequest {
                    deleteSection(onDeleteRequest)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            calendarFormHeader
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .onAppear {
            if selectedTypeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selectedTypeTitle = fallbackTypeTitle
            }
            scheduleAutomaticTypeSelection(immediate: true)
        }
        .onDisappear {
            automaticTypeSelectionTask?.cancel()
        }
        .onChange(of: title) {
            scheduleAutomaticTypeSelection()
        }
        .onChange(of: note) {
            scheduleAutomaticTypeSelection()
        }
        .sheet(item: $editorMode) { mode in
            TemplateEditorView(
                title: mode.originalTitle == nil ? "New Template" : "Edit Template",
                initialTitle: mode.initialTitle,
                initialColor: ColorHex.toColor(mode.initialColorHex)
            ) { newTitle, newColor in
                let colorHex = ColorHex.fromColor(newColor)
                if let originalTitle = mode.originalTitle {
                    templateStore.update(from: originalTitle, to: newTitle, colorHex: colorHex)
                    if selectedTypeTitle == originalTitle {
                        selectedTypeTitle = newTitle
                        didExplicitlySelectType = true
                    }
                } else {
                    templateStore.add(newTitle, colorHex: colorHex)
                    selectedTypeTitle = newTitle
                    didExplicitlySelectType = true
                }
            }
        }
    }

    private var normalizedEndTime: Date {
        let calendar = Calendar.current
        return endTime <= startTime
            ? calendar.date(byAdding: .hour, value: 1, to: startTime) ?? startTime
            : endTime
    }

    private var fallbackTypeTitle: String {
        let trimmedSelectedTypeTitle = selectedTypeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSelectedTypeTitle.isEmpty {
            return trimmedSelectedTypeTitle
        }
        return templateStore.templates.first?.title ?? "Study"
    }

    private func scheduleAutomaticTypeSelection(immediate: Bool = false) {
        automaticTypeSelectionTask?.cancel()
        guard allowsAutomaticTypeSelection, !didExplicitlySelectType else { return }

        let rawText = calendarTypeSuggestionRawText(title: title, note: note)
        let availableTypes = templateStore.templates.map(\.title)
        let currentTypeTitle = selectedTypeTitle
        let historicalEvents = store.rawCalendarEvents

        automaticTypeSelectionTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            guard !Task.isCancelled else { return }
            guard allowsAutomaticTypeSelection, !didExplicitlySelectType else { return }

            // Try local matching first (instant)
            if let suggestion = calendarPreferredLocalTypeSuggestion(
                rawText: rawText,
                availableTypes: availableTypes,
                historicalEvents: historicalEvents
            ) {
                applyTypeSuggestion(suggestion.typeTitle, previousTypeTitle: currentTypeTitle)
                return
            }

            // No local match — debounce then try LLM
            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if currentTypeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    applyTypeSuggestion(
                        templateStore.templates.first?.title ?? "Study",
                        previousTypeTitle: currentTypeTitle
                    )
                }
                return
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            guard allowsAutomaticTypeSelection, !didExplicitlySelectType else { return }

            do {
                let llmResult = try await AgenticCalendarIntakeService().generateTypeSuggestion(
                    rawText: rawText,
                    availableTypes: availableTypes
                )
                guard !Task.isCancelled, !didExplicitlySelectType else { return }
                if let resolved = calendarResolvedAvailableTypeTitle(
                    llmResult.typeTitle,
                    availableTypes: availableTypes
                ) {
                    applyTypeSuggestion(resolved, previousTypeTitle: currentTypeTitle)
                }
            } catch {
                // LLM failed — leave current selection
            }
        }
    }

    private func applyTypeSuggestion(_ nextTypeTitle: String, previousTypeTitle: String) {
        selectedTypeTitle = nextTypeTitle
        pendingFocusedTypeTitle = calendarTypeChipAutoFocusTarget(
            previousSelectedTypeTitle: previousTypeTitle,
            nextSelectedTypeTitle: nextTypeTitle
        )
    }

    private func scrollPendingFocusedTypeIfNeeded(proxy: ScrollViewProxy) {
        guard let title = pendingFocusedTypeTitle else {
            return
        }

        pendingFocusedTypeTitle = nil
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(title, anchor: .center)
            }
        }
    }
}

private extension CalendarEventFormView {
    var calendarFormHeader: some View {
        SwiftUI.GlassEffectContainer(spacing: 10) {
            ZStack {
                Text(navigationTitle)
                    .font(.headline.weight(.bold))

                HStack(spacing: 10) {
                    Button {
                        dismiss()
                    } label: {
                        Text(L(.cancel))
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .contentShape(Capsule())
                            .background(Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Button {
                        onSave(
                            CalendarEventFormData(
                                title: trimmedTitle.isEmpty ? "Untitled Event" : trimmedTitle,
                                typeTitle: fallbackTypeTitle,
                                note: note,
                                location: location,
                                startTime: isAllDay ? Calendar.current.startOfDay(for: startTime) : startTime,
                                endTime: isAllDay ? Calendar.current.startOfDay(for: endTime).addingTimeInterval(86399) : normalizedEndTime,
                                isAllDay: isAllDay,
                                repeatUnit: repeatUnit,
                                repeatInterval: repeatInterval,
                                repeatEndType: repeatUnit == .none ? .none : repeatEndType,
                                repeatEndDate: repeatEndType == .onDate ? repeatEndDate : nil,
                                repeatEndCount: repeatEndType == .afterCount ? repeatEndCount : nil,
                                didExplicitlySelectType: didExplicitlySelectType,
                                agenticIntake: agenticIntake,
                                kind: kind,
                                deadline: deadline,
                                peopleIDs: selectedPeopleIDs
                            )
                        )
                        dismiss()
                    } label: {
                        Text(L(.done))
                            .font(.headline)
                            .foregroundStyle(trimmedTitle.isEmpty ? .secondary : .primary)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .contentShape(Capsule())
                            .background(Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedTitle.isEmpty)
                }
            }
        }
    }

    func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            content()
        }
    }

    func deleteSection(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive) {
            action()
        } label: {
            Text(L(.deleteEvent))
                .font(.headline)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .background(Color.black.opacity(0.001), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder var titleSection: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text(L(.title))
                    .font(.headline)
                TextField(L(.eventTitlePlaceholder), text: $title)
            }
        }
    }

    /// Kind picker (Event ↔ Todo). Property panel — not a type selector —
    /// per [[calendar-design-bedrock]] #5. Default is `.event`; `.todo`
    /// opts into the explicit-completion / user-managed-time variant.
    /// Subsequent slices layer behavior on top of this flag.
    @ViewBuilder var kindSection: some View {
        // Dropdown (Menu) as requested, in a card that matches the others.
        // The glass is a SEPARATE background layer rather than the `card { }`
        // wrapper: a popup menu nested INSIDE a single-row `.glassEffect` makes
        // the whole glass morph into the menu and the card vanishes. Here the
        // menu sits on TOP of the glass (a sibling, not a descendant), so there's
        // no enclosing glass to lift — the card stays, with the exact same color.
        HStack {
            Text(L(.kind))
                .font(.headline)
            Spacer()
            Menu {
                Picker("", selection: $kind) {
                    Text(L(.kindEvent)).tag(Event.Kind.event)
                    Text(L(.kindTodo)).tag(Event.Kind.todo)
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Text(kind == .event ? L(.kindEvent) : L(.kindTodo))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
            }
            .tint(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.001))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    /// Deadline — optional hard time constraint, only shown for `.todo`.
    /// `Event.deadline: Date?` is the underlying field (the Wanna feature
    /// already uses it). Off by default; toggling on seeds with `Date()`,
    /// toggling off clears.
    @ViewBuilder var deadlineSection: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: deadlineEnabledBinding) {
                    Text(L(.deadline))
                        .font(.headline)
                }
                if deadline != nil {
                    // Same glass date/time pills (with inline expanding pickers)
                    // as the Preferred Time rows.
                    formDateRow(label: "", date: deadlineDateBinding, showTime: true)
                }
            }
        }
    }

    private var deadlineEnabledBinding: Binding<Bool> {
        Binding(
            get: { deadline != nil },
            set: { isOn in
                deadline = isOn ? (deadline ?? Date()) : nil
            }
        )
    }

    private var deadlineDateBinding: Binding<Date> {
        Binding(
            get: { deadline ?? Date() },
            set: { deadline = $0 }
        )
    }

    @ViewBuilder var timeSection: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind == .todo ? L(.preferredTime) : L(.time))
                    .font(.headline)
                if kind == .event {
                    HStack {
                        Text(L(.allDay))
                            .font(.subheadline)
                        Spacer()
                        Toggle(L(.allDay), isOn: $isAllDay)
                            .labelsHidden()
                    }
                }
                formDateRow(label: L(.starts), date: $startTime, showTime: !isAllDay)
                formDateRow(label: L(.ends), date: $endTime, showTime: !isAllDay)
            }
        }
    }


    func formDateRow(label: String, date: Binding<Date>, showTime: Bool) -> some View {
        let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            return f
        }()
        let timeFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return f
        }()
        let isDateExpanded = expandedDateField == .date(label)
        let isTimeExpanded = expandedDateField == .time(label)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expandedDateField = isDateExpanded ? nil : .date(label)
                        }
                    } label: {
                        Text(dateFormatter.string(from: date.wrappedValue))
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                            .background(isDateExpanded ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if showTime {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                expandedDateField = isTimeExpanded ? nil : .time(label)
                            }
                        } label: {
                            Text(timeFormatter.string(from: date.wrappedValue))
                                .font(.subheadline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Capsule())
                                .background(isTimeExpanded ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.001), in: Capsule())
                                .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if isDateExpanded {
                CompactCalendarPicker(date: date)
            }

            if isTimeExpanded {
                CompactTimePicker(date: date)
            }
        }
    }

    @ViewBuilder var repeatSection: some View {
        // Same container pattern as `kindSection`: a sibling glass background
        // (not `card { }`), so the Menu sits ON the glass instead of morphing it.
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L(.repeatLabel))
                    .font(.headline)
                Spacer()
                Menu {
                    Picker("", selection: $repeatUnit) {
                        Text(L(.never)).tag(Event.RepeatUnit.none)
                        Text(L(.daily)).tag(Event.RepeatUnit.day)
                        Text(L(.weekly)).tag(Event.RepeatUnit.week)
                        Text(L(.monthly)).tag(Event.RepeatUnit.month)
                        Text(L(.yearly)).tag(Event.RepeatUnit.year)
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Text(repeatUnitDisplayLabel)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                }
                .tint(.primary)
            }

            if repeatUnit != .none {
                Stepper("Every \(repeatInterval) \(repeatUnitLabel)", value: $repeatInterval, in: 1...99)

                Picker(L(.ends), selection: $repeatEndType) {
                    Text(L(.never)).tag(Event.RepeatEndType.none)
                    Text(L(.onDate)).tag(Event.RepeatEndType.onDate)
                    Text(L(.afterCount)).tag(Event.RepeatEndType.afterCount)
                }

                if repeatEndType == .onDate {
                    DatePicker(L(.endDate), selection: $repeatEndDate, displayedComponents: .date)
                }

                if repeatEndType == .afterCount {
                    Stepper("After \(repeatEndCount) occurrences", value: $repeatEndCount, in: 1...999)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.001))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var repeatUnitDisplayLabel: String {
        switch repeatUnit {
        case .none: return L(.never)
        case .day: return L(.daily)
        case .week: return L(.weekly)
        case .month: return L(.monthly)
        case .year: return L(.yearly)
        }
    }

    private var repeatUnitLabel: String {
        switch repeatUnit {
        case .none: return ""
        case .day: return repeatInterval == 1 ? "day" : "days"
        case .week: return repeatInterval == 1 ? "week" : "weeks"
        case .month: return repeatInterval == 1 ? "month" : "months"
        case .year: return repeatInterval == 1 ? "year" : "years"
        }
    }

    @ViewBuilder var typeSection: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text(L(.type))
                    .font(.headline)
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(templateStore.templates) { template in
                                let selected = selectedTypeTitle == template.title
                                Button {
                                    selectedTypeTitle = template.title
                                    didExplicitlySelectType = true
                                } label: {
                                    TypeTemplateChip(
                                        template: template,
                                        selected: selected
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(template.title)
                                .contentShape(.dragPreview, Capsule())
                                .onDrag {
                                    draggingTemplateID = template.id
                                    let provider = NSItemProvider()
                                    provider.registerDataRepresentation(forTypeIdentifier: "com.done.template-reorder", visibility: .ownProcess) { completion in
                                        completion(nil, nil)
                                        return nil
                                    }
                                    return provider
                                }
                                .onDrop(of: ["com.done.template-reorder"], delegate: TemplateDropDelegate(
                                    targetTemplate: template,
                                    templates: templateStore.templates,
                                    draggingID: $draggingTemplateID,
                                    onMove: { from, to in
                                        templateStore.move(from: from, to: to)
                                    }
                                ))
                                .contextMenu {
                                    Button(L(.edit)) {
                                        editorMode = TemplateEditorMode(
                                            originalTitle: template.title,
                                            initialTitle: template.title,
                                            initialColorHex: template.colorHex
                                        )
                                    }
                                    Button(L(.delete), role: .destructive) {
                                        templateStore.remove(title: template.title)
                                        if selectedTypeTitle == template.title {
                                            selectedTypeTitle = templateStore.templates.first?.title ?? "Study"
                                            didExplicitlySelectType = true
                                        }
                                    }
                                }
                            }

                            Button {
                                editorMode = TemplateEditorMode(
                                    originalTitle: nil,
                                    initialTitle: "",
                                    initialColorHex: EventTypeTemplateStore.fallbackColorHex
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.caption2)
                                    Text(L(.add))
                                }
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 5)
                                .foregroundStyle(.secondary)
                                .contentShape(Capsule())
                                .background(Color.black.opacity(0.001), in: Capsule())
                                .glassEffect(.regular.interactive(), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDrop(of: ["com.done.template-reorder"], isTargeted: nil) { _ in
                        draggingTemplateID = nil
                        return false
                    }
                    .onAppear {
                        scrollPendingFocusedTypeIfNeeded(proxy: scrollProxy)
                    }
                    .onChange(of: pendingFocusedTypeTitle) { _, _ in
                        scrollPendingFocusedTypeIfNeeded(proxy: scrollProxy)
                    }
                }
            }
        }
    }

    @ViewBuilder var peopleSection: some View {
        let boundPeople = store.people(for: selectedPeopleIDs)
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text(L(.withWhom))
                    .font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(boundPeople) { person in
                            PersonChip(person: person) {
                                selectedPeopleIDs.removeAll { $0 == person.id }
                            }
                        }
                        Button {
                            showPeoplePicker = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.caption2)
                                Text(L(.add))
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .foregroundStyle(.secondary)
                            .contentShape(Capsule())
                            .background(Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .sheet(isPresented: $showPeoplePicker) {
            EventPeoplePickerView(selectedPeopleIDs: $selectedPeopleIDs)
                .environmentObject(store)
        }
    }

    @ViewBuilder var descriptionSection: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text(L(.description))
                    .font(.headline)
                TextEditor(text: $note)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder var agenticSourceSection: some View {
        if let intake = agenticIntake {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showAgenticIntakeDetails.toggle()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L(.agenticInput))
                                    .font(.headline)
                                Text(agenticSourceSummary(intake))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showAgenticIntakeDetails ? 90 : 0))
                        }
                    }
                    .buttonStyle(.plain)

                    if showAgenticIntakeDetails {
                        if !intake.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L(.originalText))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(intake.rawText)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !intake.images.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L(.images))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(intake.images) { imageRef in
                                            AgenticIntakeThumbnailView(imageRef: imageRef)
                                        }
                                    }
                                }
                            }
                        }

                        if let providerMetadata = intake.providerMetadata {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L(.aiMetadata))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text("Provider: \(providerMetadata.provider)\(providerMetadata.model.map { " (\($0))" } ?? "")")
                                    .font(.caption)
                                Text(String(format: L(.visionLabelFormat), providerMetadata.usedVision ? L(.visionUsed) : L(.visionTextOnly)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !intake.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L(.warnings))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(Array(intake.warnings.enumerated()), id: \.offset) { entry in
                                    Text("• \(entry.element)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func agenticSourceSummary(_ intake: AgenticIntakeRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let imagePart = intake.images.isEmpty ? "No images" : "\(intake.images.count) image\(intake.images.count == 1 ? "" : "s")"
        return "\(imagePart) • \(formatter.string(from: intake.createdAt))"
    }
}

private struct TypeTemplateChip: View {
    let template: EventTypeTemplate
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ColorHex.toColor(template.colorHex))
                .frame(width: 8, height: 8)
            Text(template.title)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .foregroundStyle(selected ? .primary : .secondary)
        .contentShape(Capsule())
        .background(selected ? Color.primary.opacity(0.15) : Color.black.opacity(0.001), in: Capsule())
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

private struct TemplateDropDelegate: DropDelegate {
    let targetTemplate: EventTypeTemplate
    let templates: [EventTypeTemplate]
    @Binding var draggingID: UUID?

    let onMove: (IndexSet, Int) -> Void

    func performDrop(info: DropInfo) -> Bool {
        DispatchQueue.main.async { draggingID = nil }
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              let fromIndex = templates.firstIndex(where: { $0.id == draggingID }),
              let toIndex = templates.firstIndex(where: { $0.id == targetTemplate.id }),
              fromIndex != toIndex else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            onMove(IndexSet(integer: fromIndex), toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        // Keep draggingID alive during reorder — only clear in performDrop
    }
}

struct CalendarEventFormData {
    let title: String
    let typeTitle: String
    let note: String
    let location: String
    let startTime: Date
    let endTime: Date
    let isAllDay: Bool
    let repeatUnit: Event.RepeatUnit
    let repeatInterval: Int
    let repeatEndType: Event.RepeatEndType
    let repeatEndDate: Date?
    let repeatEndCount: Int?
    let didExplicitlySelectType: Bool
    var agenticIntake: AgenticIntakeRecord? = nil
    /// Behavioral kind selected in the composer. Defaults to `.event` so
    /// existing call sites that construct `CalendarEventFormData` without
    /// specifying a kind keep their current behavior.
    var kind: Event.Kind = .event
    /// Optional hard time constraint. Only the composer surfaces this when
    /// `kind == .todo`, but the value rides through to `Event.deadline`
    /// regardless of kind (so transient kind flips in the form don't
    /// silently drop it).
    var deadline: Date? = nil
    /// People bound to the event ("with whom"). Resolved to `Person` ids;
    /// empty means no one bound. Defaults to `[]` so existing call sites that
    /// build `CalendarEventFormData` keep compiling unchanged.
    var peopleIDs: [UUID] = []

    func toEvent() -> Event {
        Event(
            title: title,
            note: note,
            location: location,
            timeRanges: [Event.TimeRange(start: startTime, end: endTime)],
            deadline: deadline,
            repeatUnit: repeatUnit,
            isAllDay: isAllDay,
            repeatInterval: repeatInterval,
            repeatEndType: repeatEndType,
            repeatEndDate: repeatEndDate,
            repeatEndCount: repeatEndCount,
            type: typeTitle,
            kind: kind,
            agenticIntake: agenticIntake,
            peopleIDs: peopleIDs.isEmpty ? nil : peopleIDs
        )
    }

    func apply(to event: Event) -> Event {
        var updated = event
        updated.title = title
        updated.type = typeTitle
        updated.kind = kind
        updated.deadline = deadline
        updated.note = note
        updated.location = location
        updated.isAllDay = isAllDay
        updated.timeRanges = [Event.TimeRange(start: startTime, end: endTime)]
        updated.repeatUnit = repeatUnit
        updated.repeatInterval = repeatInterval
        updated.repeatEndType = repeatEndType
        updated.repeatEndDate = repeatEndDate
        updated.repeatEndCount = repeatEndCount
        updated.agenticIntake = agenticIntake
        updated.peopleIDs = peopleIDs.isEmpty ? nil : peopleIDs
        return updated
    }
}

private struct AgenticIntakeThumbnailView: View {
    let imageRef: AgenticIntakeImageRef
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
                .task {
                    if image == nil {
                        image = AgenticIntakeAssetStore().loadImage(for: imageRef)
                    }
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12))
        )
    }
}

private struct CompactCalendarPicker: View {
    @Binding var date: Date
    @State private var displayedMonth: Date

    private let calendar = Calendar.current
    private let weekdaySymbols = Calendar.current.veryShortWeekdaySymbols

    init(date: Binding<Date>) {
        _date = date
        _displayedMonth = State(initialValue: date.wrappedValue)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: displayedMonth)
    }

    private var daysInMonth: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: displayedMonth),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth))
        else { return [] }

        let weekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingBlanks = weekday - calendar.firstWeekday
        let adjusted = leadingBlanks < 0 ? leadingBlanks + 7 : leadingBlanks

        var days: [Date?] = Array(repeating: nil, count: adjusted)
        for day in range {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth) {
                days.append(d)
            }
        }
        return days
    }

    private func isSelected(_ d: Date) -> Bool {
        calendar.isDate(d, inSameDayAs: date)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(monthTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { shiftMonth(-1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                Button { shiftMonth(1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { sym in
                    Text(sym)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(height: 20)
                }

                ForEach(Array(daysInMonth.enumerated()), id: \.offset) { _, day in
                    if let day {
                        Button {
                            selectDay(day)
                        } label: {
                            Text("\(calendar.component(.day, from: day))")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background(isSelected(day) ? Color.accentColor : Color.clear, in: Circle())
                                .foregroundStyle(isSelected(day) ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 28)
                    }
                }
            }
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            withAnimation(.easeInOut(duration: 0.15)) {
                displayedMonth = next
            }
        }
    }

    private func selectDay(_ day: Date) {
        var comps = calendar.dateComponents([.hour, .minute, .second], from: date)
        let dayComps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.year = dayComps.year
        comps.month = dayComps.month
        comps.day = dayComps.day
        if let d = calendar.date(from: comps) {
            date = d
        }
    }
}

private struct CompactTimePicker: View {
    @Binding var date: Date

    private var hour: Int {
        Calendar.current.component(.hour, from: date)
    }
    private var minute: Int {
        Calendar.current.component(.minute, from: date)
    }

    var body: some View {
        HStack(spacing: 0) {
            Picker("", selection: Binding(
                get: { hour },
                set: { newHour in
                    var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                    comps.hour = newHour
                    if let d = Calendar.current.date(from: comps) { date = d }
                }
            )) {
                ForEach(0..<24, id: \.self) { h in
                    Text(String(format: "%02d", h))
                        .font(.subheadline)
                        .tag(h)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 80, height: 120)
            .clipped()

            Text(":")
                .font(.subheadline.weight(.semibold))

            Picker("", selection: Binding(
                get: { minute },
                set: { newMinute in
                    var comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                    comps.minute = newMinute
                    if let d = Calendar.current.date(from: comps) { date = d }
                }
            )) {
                ForEach(0..<60, id: \.self) { m in
                    Text(String(format: "%02d", m))
                        .font(.subheadline)
                        .tag(m)
                }
            }
            .pickerStyle(.wheel)
            .frame(width: 80, height: 120)
            .clipped()
        }
        .frame(maxWidth: .infinity)
    }
}
