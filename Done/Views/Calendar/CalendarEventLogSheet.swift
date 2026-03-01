import SwiftUI

enum CalendarEventLogSheetInitialFocus: String, Hashable {
    case base
    case template
    case notes
}

struct CalendarEventLogSheetRequest: Identifiable, Hashable {
    var occurrence: CalendarEventOccurrenceContext
    var initialFocus: CalendarEventLogSheetInitialFocus

    var id: String {
        "\(occurrence.id)-\(initialFocus.rawValue)"
    }
}

struct CalendarEventLogSheet: View {
    private enum FocusField: Hashable {
        case summary
        case note
        case timelineComposer
    }

    let request: CalendarEventLogSheetRequest

    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss

    @State private var completionStatus: EventLogCompletionStatus?
    @State private var actualDurationMinutesText: String = ""
    @State private var summary: String = ""
    @State private var note: String = ""
    @State private var effort: Int?
    @State private var emotionIDs: Set<String> = []
    @State private var behaviorIDs: Set<String> = []
    @State private var selectedTemplateID: EventLogTemplateID?
    @State private var templateAnswers: [String: EventLogAnswerValue] = [:]
    @State private var timelineNotes: [EventLogTimelineNote] = []
    @State private var timelineComposer: String = ""
    @State private var isTemplatePickerExpanded: Bool = false
    @State private var didApplyInitialFocus = false
    @State private var didLoadDraft = false

    @FocusState private var focusedField: FocusField?

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                baseSection
                templateSection
                timelineNotesSection
            }
            .navigationTitle("Log Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        save()
                    }
                }
            }
            .onAppear {
                loadDraftIfNeeded()
                applyInitialFocusIfNeeded()
            }
        }
    }
}

private extension CalendarEventLogSheet {
    var event: Event? {
        calendarResolvedEventForOccurrenceContext(request.occurrence, in: store.calendarEvents)
    }

    var range: Event.TimeRange? {
        guard let event else { return nil }
        return calendarOccurrenceDisplayRange(event: event, occurrenceDate: request.occurrence.occurrenceDate)
    }

    var suggestedTemplateID: EventLogTemplateID? {
        store.prefilledDraft(for: request.occurrence).suggestedTemplateID
    }

    var selectedTemplateDefinition: EventLogTemplateDefinition? {
        selectedTemplateID.flatMap(EventLogTemplateRegistry.definition(for:))
    }

    var actualDurationMinutes: Int? {
        Int(actualDurationMinutesText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var eventTitle: String {
        guard let title = event?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Untitled Event"
        }
        return title
    }

    var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(eventTitle)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let event, !event.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(event.type)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(EventTypeTemplateStore.color(for: event.type).opacity(0.16), in: Capsule())
                    }
                    if let selectedTemplateDefinition {
                        Text(selectedTemplateDefinition.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    } else if let suggestedTitle = EventLogTemplateRegistry.title(for: suggestedTemplateID?.rawValue) {
                        Text("Suggested: \(suggestedTitle)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                }

                if let range {
                    Text(calendarOccurrenceTimeSummary(event: event ?? Event(title: ""), range: range))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    var baseSection: some View {
        Section("Base Record") {
            Picker("Completion", selection: Binding(
                get: { completionStatus ?? .completed },
                set: { completionStatus = $0 }
            )) {
                ForEach(EventLogCompletionStatus.allCases) { status in
                    Text(status.title).tag(status)
                }
            }

            TextField("Actual duration (minutes)", text: $actualDurationMinutesText)
                .keyboardType(.numberPad)

            TextField("One-line summary", text: $summary, axis: .vertical)
                .lineLimit(1...3)
                .focused($focusedField, equals: .summary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Note")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $note)
                    .frame(minHeight: 90)
                    .focused($focusedField, equals: .note)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Effort")
                    .font(.subheadline.weight(.semibold))
                ratingRow(currentValue: $effort)
            }

            tagPickerSection(
                title: "Emotion",
                tags: CalendarEmotionTag.allCases.map { (id: $0.rawValue, title: $0.title) },
                selection: $emotionIDs
            )

            tagPickerSection(
                title: "Behavior",
                tags: CalendarBehaviorTag.allCases.map { (id: $0.rawValue, title: $0.title) },
                selection: $behaviorIDs
            )
        }
    }

    var templateSection: some View {
        Section("Type Template") {
            if let selectedTemplateDefinition {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedTemplateDefinition.title)
                            .font(.subheadline.weight(.semibold))
                        Text(selectedTemplateDefinition.familyTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isTemplatePickerExpanded ? "Done" : "Change Template") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isTemplatePickerExpanded.toggle()
                        }
                    }
                }

                if isTemplatePickerExpanded {
                    templatePickerGroups
                }

                ForEach(selectedTemplateDefinition.fields) { field in
                    templateFieldView(field)
                }
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isTemplatePickerExpanded = true
                    }
                } label: {
                    Label("Add Template", systemImage: "plus.circle")
                }

                if isTemplatePickerExpanded {
                    templatePickerGroups
                }
            }
        }
    }

    var timelineNotesSection: some View {
        Section("Timeline Notes") {
            TextField("Add a timeline note", text: $timelineComposer, axis: .vertical)
                .lineLimit(1...4)
                .focused($focusedField, equals: .timelineComposer)

            HStack {
                Spacer()
                Button("Add Note") {
                    addTimelineNote()
                }
                .disabled(timelineComposer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if timelineNotes.isEmpty {
                Text("No notes yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(timelineNotes) { note in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(noteTimestamp(note.createdAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                removeTimelineNote(note.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    var templatePickerGroups: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(EventLogTemplateRegistry.groupedDefinitions, id: \.familyTitle) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.familyTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    templateChipWrap(group.templates)
                }
            }

            if selectedTemplateID != nil {
                Button("Use Base Section Only") {
                    selectedTemplateID = nil
                    templateAnswers = [:]
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    func templateChipWrap(_ templates: [EventLogTemplateDefinition]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(templates, id: \.id) { definition in
                let isSelected = selectedTemplateID == definition.id
                Button {
                    selectedTemplateID = definition.id
                    templateAnswers = definition.filteredAnswers(templateAnswers)
                } label: {
                    Text(definition.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                            in: Capsule()
                        )
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    func templateFieldView(_ field: EventLogTemplateFieldDefinition) -> some View {
        switch field.kind {
        case .singleSelect:
            VStack(alignment: .leading, spacing: 8) {
                Text(field.title)
                    .font(.subheadline.weight(.semibold))
                FlowLayout(spacing: 6) {
                    ForEach(field.options) { option in
                        let selected = selectedString(for: field.id) == option.id
                        Button {
                            setSingleSelectAnswer(fieldID: field.id, value: selected ? nil : option.id)
                        } label: {
                            Text(option.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                                    in: Capsule()
                                )
                                .foregroundStyle(selected ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .multiSelect:
            VStack(alignment: .leading, spacing: 8) {
                Text(field.title)
                    .font(.subheadline.weight(.semibold))
                FlowLayout(spacing: 6) {
                    ForEach(field.options) { option in
                        let selected = selectedStrings(for: field.id).contains(option.id)
                        Button {
                            toggleMultiSelectAnswer(fieldID: field.id, value: option.id)
                        } label: {
                            Text(option.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                                    in: Capsule()
                                )
                                .foregroundStyle(selected ? Color.accentColor : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        case .rating:
            VStack(alignment: .leading, spacing: 8) {
                Text(field.title)
                    .font(.subheadline.weight(.semibold))
                ratingRow(
                    currentValue: Binding(
                        get: { selectedInt(for: field.id) },
                        set: { setIntAnswer(fieldID: field.id, value: $0) }
                    )
                )
            }
        case .shortText:
            TextField(field.placeholder ?? field.title, text: Binding(
                get: { selectedString(for: field.id) ?? "" },
                set: { setShortTextAnswer(fieldID: field.id, value: $0) }
            ))
        case .longText:
            VStack(alignment: .leading, spacing: 8) {
                Text(field.title)
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: Binding(
                    get: { selectedString(for: field.id) ?? "" },
                    set: { setShortTextAnswer(fieldID: field.id, value: $0) }
                ))
                .frame(minHeight: 100)
            }
        }
    }

    func tagPickerSection(
        title: String,
        tags: [(id: String, title: String)],
        selection: Binding<Set<String>>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.id) { tag in
                    let selected = selection.wrappedValue.contains(tag.id)
                    Button {
                        var next = selection.wrappedValue
                        if selected {
                            next.remove(tag.id)
                        } else {
                            next.insert(tag.id)
                        }
                        selection.wrappedValue = next
                    } label: {
                        Text(tag.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                                in: Capsule()
                            )
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func ratingRow(currentValue: Binding<Int?>) -> some View {
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { value in
                let isSelected = currentValue.wrappedValue == value
                Button {
                    currentValue.wrappedValue = isSelected ? nil : value
                } label: {
                    Text("\(value)")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: Circle()
                        )
                        .foregroundStyle(isSelected ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    func selectedString(for fieldID: String) -> String? {
        guard case .string(let value) = templateAnswers[fieldID] else { return nil }
        return value
    }

    func selectedStrings(for fieldID: String) -> [String] {
        guard case .strings(let values) = templateAnswers[fieldID] else { return [] }
        return values
    }

    func selectedInt(for fieldID: String) -> Int? {
        guard case .int(let value) = templateAnswers[fieldID] else { return nil }
        return value
    }

    func setSingleSelectAnswer(fieldID: String, value: String?) {
        if let value, !value.isEmpty {
            templateAnswers[fieldID] = .string(value)
        } else {
            templateAnswers.removeValue(forKey: fieldID)
        }
    }

    func toggleMultiSelectAnswer(fieldID: String, value: String) {
        var values = Set(selectedStrings(for: fieldID))
        if values.contains(value) {
            values.remove(value)
        } else {
            values.insert(value)
        }
        let sorted = values.sorted()
        if sorted.isEmpty {
            templateAnswers.removeValue(forKey: fieldID)
        } else {
            templateAnswers[fieldID] = .strings(sorted)
        }
    }

    func setShortTextAnswer(fieldID: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            templateAnswers.removeValue(forKey: fieldID)
        } else {
            templateAnswers[fieldID] = .string(value)
        }
    }

    func setIntAnswer(fieldID: String, value: Int?) {
        if let value {
            templateAnswers[fieldID] = .int(value)
        } else {
            templateAnswers.removeValue(forKey: fieldID)
        }
    }

    func addTimelineNote() {
        let trimmed = timelineComposer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        timelineNotes.insert(EventLogTimelineNote(text: trimmed, source: "logSheet"), at: 0)
        timelineComposer = ""
    }

    func removeTimelineNote(_ id: UUID) {
        timelineNotes.removeAll { $0.id == id }
    }

    func save() {
        let filteredAnswers = selectedTemplateDefinition?.filteredAnswers(templateAnswers) ?? [:]
        store.upsertLogRecord(for: request.occurrence) { record in
            record.suggestedTemplateID = suggestedTemplateID?.rawValue ?? event?.suggestedLogTemplateID
            record.selectedTemplateID = selectedTemplateID?.rawValue
            record.completionStatus = completionStatus
            record.actualDurationMinutes = actualDurationMinutes
            record.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            record.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            record.effort = effort
            record.emotions = Array(emotionIDs).sorted()
            record.behaviors = Array(behaviorIDs).sorted()
            record.templateAnswers = filteredAnswers
            record.timelineNotes = timelineNotes.sorted { $0.createdAt > $1.createdAt }
        }

        if let event {
            EventLogTemplateAdvisor().recordOverride(
                eventType: event.type,
                selectedTemplateID: selectedTemplateID,
                suggestedTemplateID: suggestedTemplateID
            )
        }

        dismiss()
    }

    func applyInitialFocusIfNeeded() {
        guard !didApplyInitialFocus else { return }
        didApplyInitialFocus = true
        switch request.initialFocus {
        case .base:
            focusedField = .summary
        case .template:
            isTemplatePickerExpanded = true
        case .notes:
            focusedField = .timelineComposer
        }
    }

    func noteTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func loadDraftIfNeeded() {
        guard !didLoadDraft else { return }
        didLoadDraft = true
        let draft = store.prefilledDraft(for: request.occurrence)
        completionStatus = draft.completionStatus ?? .completed
        actualDurationMinutesText = draft.actualDurationMinutes.map(String.init) ?? ""
        summary = draft.summary
        note = draft.note
        effort = draft.effort
        emotionIDs = Set(draft.emotions)
        behaviorIDs = Set(draft.behaviors)
        selectedTemplateID = draft.effectiveTemplateID
        templateAnswers = draft.templateAnswers
        timelineNotes = draft.timelineNotes.sorted { $0.createdAt > $1.createdAt }
        isTemplatePickerExpanded = request.initialFocus == .template || draft.effectiveTemplateID == nil
    }
}
