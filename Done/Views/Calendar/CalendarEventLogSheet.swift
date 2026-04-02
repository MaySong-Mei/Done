import SwiftUI
import PhotosUI

enum CalendarEventLogEditorMode {
    case embedded
    case sheet
}

@MainActor
struct CalendarEventLogEditor: View {
    private enum FocusField: Hashable {
        case note
    }

    let occurrence: CalendarEventOccurrenceContext
    let mode: CalendarEventLogEditorMode
    var autoFocusNote: Bool = false

    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss

    @State private var completionStatus: EventLogCompletionStatus?
    @State private var note: String = ""
    @State private var effort: Int?
    @State private var emotionIDs: Set<String> = []
    @State private var behaviorIDs: Set<String> = []
    @State private var selectedTemplateID: EventLogTemplateID?
    @State private var templateAnswers: [String: EventLogAnswerValue] = [:]
    @State private var didLoadDraft = false
    @State private var didApplyInitialFocus = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var existingImages: [AgenticIntakeImageRef] = []
    @State private var newImages: [LogImageDraft] = []

    private struct LogImageDraft: Identifiable {
        let id: UUID
        let data: Data
        let preview: UIImage
    }

    @FocusState private var focusedField: FocusField?

    var body: some View {
        Group {
            switch mode {
            case .embedded:
                VStack(spacing: 12) {
                    embeddedSaveBar
                    editorSections
                }
            case .sheet:
                ScrollView {
                    VStack(spacing: 12) {
                        headerSection
                        templateSection
                        quickSection
                        imagesSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top) {
                    logSheetHeader
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 8)
                }
            }
        }
        .onAppear {
            loadDraftIfNeeded()
            applyInitialFocusIfNeeded()
        }
        .onChange(of: autoFocusNote) {
            guard autoFocusNote else { return }
            applyInitialFocusIfNeeded()
        }
    }

    private var logSheetHeader: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text("Log Event")
                .font(.system(size: 15, weight: .semibold))

            Spacer(minLength: 0)

            Button {
                save()
            } label: {
                Text("Save")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

private extension CalendarEventLogEditor {
    var editorSections: some View {
        Group {
            headerSection
            templateSection
            quickSection
            imagesSection
        }
    }

    var embeddedSaveBar: some View {
        card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log")
                        .font(.headline)
                    Text("Edit and save this event log here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    save()
                } label: {
                    Text("Save Log")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    var event: Event? {
        calendarResolvedEventForOccurrenceContext(occurrence, in: store.calendarEvents)
    }

    var range: Event.TimeRange? {
        guard let event else { return nil }
        return calendarOccurrenceDisplayRange(event: event, occurrenceDate: occurrence.occurrenceDate)
    }

    var suggestedTemplateID: EventLogTemplateID? {
        store.prefilledDraft(for: occurrence).suggestedTemplateID
    }

    var selectedTemplateDefinition: EventLogTemplateDefinition? {
        selectedTemplateID.flatMap(EventLogTemplateRegistry.definition(for:))
    }

    var eventTitle: String {
        guard let title = event?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Untitled Event"
        }
        return title
    }

    var headerSection: some View {
        card {
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
        }
    }

    var quickSection: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Completion")
                        .font(.headline)
                    Spacer()
                    Picker("Completion", selection: Binding(
                        get: { completionStatus ?? .completed },
                        set: { completionStatus = $0 }
                    )) {
                        ForEach(EventLogCompletionStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Note")
                        .font(.headline)
                    TextEditor(text: $note)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .note)
                }
            }
        }
    }

    var templateSection: some View {
        card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Template")
                    .font(.headline)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            selectedTemplateID = nil
                            templateAnswers = [:]
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.secondary)
                                    .frame(width: 8, height: 8)
                                Text("None")
                            }
                            .font(.system(size: 13))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(selectedTemplateID == nil ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.1))
                            .foregroundStyle(selectedTemplateID == nil ? .primary : .secondary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(EventLogTemplateRegistry.definitions) { definition in
                            let isSelected = selectedTemplateID == definition.id
                            Button {
                                selectedTemplateID = definition.id
                                templateAnswers = definition.filteredAnswers(templateAnswers)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(isSelected ? Color.accentColor : Color.secondary)
                                        .frame(width: 8, height: 8)
                                    Text(definition.title)
                                }
                                .font(.system(size: 13))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(isSelected ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.1))
                                .foregroundStyle(isSelected ? .primary : .secondary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let selectedTemplateDefinition {
                    ForEach(selectedTemplateDefinition.fields) { field in
                        templateFieldView(field)
                    }
                } else {
                    baseFields
                }
            }
        }
    }

    var baseFields: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("Effort")
                    .font(.headline)
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

    @ViewBuilder
    func templateFieldView(_ field: EventLogTemplateFieldDefinition) -> some View {
        switch field.kind {
        case .singleSelect:
            VStack(alignment: .leading, spacing: 8) {
                Text(field.title)
                    .font(.headline)
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
                    .font(.headline)
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
                    .font(.headline)
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
                    .font(.headline)
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
                .font(.headline)
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

    var imagesSection: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Images")
                        .font(.headline)
                    Spacer()
                    let totalCount = existingImages.count + newImages.count
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: max(0, 5 - totalCount),
                        matching: .images
                    ) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                    .disabled(totalCount >= 5)
                }

                let hasImages = !existingImages.isEmpty || !newImages.isEmpty
                if hasImages {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(existingImages) { ref in
                                LogExistingImageThumbnail(imageRef: ref) {
                                    existingImages.removeAll { $0.id == ref.id }
                                }
                            }
                            ForEach(newImages) { item in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: item.preview)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    Button {
                                        newImages.removeAll { $0.id == item.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.white, .black.opacity(0.5))
                                    }
                                    .offset(x: 4, y: -4)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: pickerItems.count) {
            let items = pickerItems
            Task { await loadPickedImages(items) }
        }
        .onAppear {
            if existingImages.isEmpty {
                existingImages = event?.agenticIntake?.images ?? []
            }
        }
    }

    private func loadPickedImages(_ items: [PhotosPickerItem]) async {
        defer { pickerItems = [] }
        let totalCount = existingImages.count + newImages.count
        guard totalCount < 5 else { return }
        for item in items {
            if existingImages.count + newImages.count >= 5 { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else { continue }
            newImages.append(LogImageDraft(id: UUID(), data: data, preview: uiImage))
        }
    }

    func save() {
        let filteredAnswers = selectedTemplateDefinition?.filteredAnswers(templateAnswers) ?? [:]
        store.upsertLogRecord(for: occurrence) { record in
            record.suggestedTemplateID = suggestedTemplateID?.rawValue ?? event?.suggestedLogTemplateID
            record.selectedTemplateID = selectedTemplateID?.rawValue
            record.completionStatus = completionStatus
            record.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            record.effort = effort
            record.emotions = Array(emotionIDs).sorted()
            record.behaviors = Array(behaviorIDs).sorted()
            record.templateAnswers = filteredAnswers
        }

        if let event {
            EventLogTemplateAdvisor().recordOverride(
                eventType: event.type,
                selectedTemplateID: selectedTemplateID,
                suggestedTemplateID: suggestedTemplateID
            )

            // Save images if changed
            let imagesChanged = !newImages.isEmpty || existingImages.count != (event.agenticIntake?.images.count ?? 0)
            if imagesChanged {
                var updated = event
                var intake = updated.agenticIntake ?? AgenticIntakeRecord(
                    rawText: "",
                    source: .classicFallback
                )
                intake.images = existingImages
                if !newImages.isEmpty {
                    let imported = newImages.map { AgenticIntakeAssetStore.ImportedImage(id: $0.id, data: $0.data) }
                    if let savedRefs = try? AgenticIntakeAssetStore().saveImages(imported, for: event.id) {
                        intake.images.append(contentsOf: savedRefs)
                    }
                }
                updated.agenticIntake = intake
                store.updateCalendarEvent(updated)
            }
        }

        if case .sheet = mode {
            dismiss()
        }
    }

    func applyInitialFocusIfNeeded() {
        guard autoFocusNote, !didApplyInitialFocus else { return }
        didApplyInitialFocus = true
        DispatchQueue.main.async {
            focusedField = .note
        }
    }

    func loadDraftIfNeeded() {
        guard !didLoadDraft else { return }
        didLoadDraft = true
        let draft = store.prefilledDraft(for: occurrence)
        completionStatus = draft.completionStatus ?? .completed
        note = draft.note
        effort = draft.effort
        emotionIDs = Set(draft.emotions)
        behaviorIDs = Set(draft.behaviors)
        selectedTemplateID = draft.effectiveTemplateID
        templateAnswers = draft.templateAnswers
    }
}

private struct LogExistingImageThumbnail: View {
    let imageRef: AgenticIntakeImageRef
    let onRemove: () -> Void
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .offset(x: 4, y: -4)
        }
        .onAppear {
            if image == nil {
                image = AgenticIntakeAssetStore().loadImage(for: imageRef)
            }
        }
    }
}
