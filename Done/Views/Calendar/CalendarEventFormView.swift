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
    @State private var showMoreOptions: Bool = false
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
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                titleSection
                typeSection
                allDaySection
                timeSection
                locationSection
                repeatSection
                moreOptionsSection
                if showMoreOptions {
                    descriptionSection
                }
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
        let historicalEvents = store.calendarEvents

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
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Text(L(.cancel))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text(navigationTitle)
                .font(.system(size: 17, weight: .bold))

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
                        agenticIntake: agenticIntake
                    )
                )
                dismiss()
            } label: {
                Text(L(.done))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(trimmedTitle.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(trimmedTitle.isEmpty)
        }
    }

    func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    func deleteSection(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive) {
            action()
        } label: {
            Text(L(.deleteEvent))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

    @ViewBuilder var allDaySection: some View {
        card {
            Toggle(L(.allDay), isOn: $isAllDay)
        }
    }

    @ViewBuilder var timeSection: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text(L(.time))
                    .font(.headline)
                if isAllDay {
                    DatePicker(L(.starts), selection: $startTime, displayedComponents: [.date])
                    DatePicker(L(.ends), selection: $endTime, displayedComponents: [.date])
                } else {
                    DatePicker(L(.starts), selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                    DatePicker(L(.ends), selection: $endTime, displayedComponents: [.date, .hourAndMinute])
                }
            }
        }
    }

    @ViewBuilder var locationSection: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text(L(.location))
                    .font(.headline)
                TextField(L(.addLocation), text: $location)
            }
        }
    }

    @ViewBuilder var repeatSection: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L(.repeatLabel))
                        .font(.headline)
                    Spacer()
                    Picker(L(.repeatLabel), selection: $repeatUnit) {
                        Text("Never").tag(Event.RepeatUnit.none)
                        Text("Daily").tag(Event.RepeatUnit.day)
                        Text("Weekly").tag(Event.RepeatUnit.week)
                        Text("Monthly").tag(Event.RepeatUnit.month)
                        Text("Yearly").tag(Event.RepeatUnit.year)
                    }
                }

                if repeatUnit != .none {
                    Stepper("Every \(repeatInterval) \(repeatUnitLabel)", value: $repeatInterval, in: 1...99)

                    Picker("Ends", selection: $repeatEndType) {
                        Text("Never").tag(Event.RepeatEndType.none)
                        Text("On date").tag(Event.RepeatEndType.onDate)
                        Text("After count").tag(Event.RepeatEndType.afterCount)
                    }

                    if repeatEndType == .onDate {
                        DatePicker("End date", selection: $repeatEndDate, displayedComponents: .date)
                    }

                    if repeatEndType == .afterCount {
                        Stepper("After \(repeatEndCount) occurrences", value: $repeatEndCount, in: 1...999)
                    }
                }
            }
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
                                    initialColorHex: "#8E8E93"
                                )
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.caption)
                                    Text(L(.add))
                                }
                                .font(.system(size: 13))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.1))
                                .foregroundStyle(.secondary)
                                .clipShape(Capsule())
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

    @ViewBuilder var moreOptionsSection: some View {
        card {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMoreOptions.toggle()
                }
            } label: {
                HStack {
                    Text("More options")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showMoreOptions ? 90 : 0))
                }
            }
            .buttonStyle(.plain)
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
                                Text("Agentic Input")
                                    .font(.headline)
                                Text(agenticSourceSummary(intake))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showAgenticIntakeDetails ? 90 : 0))
                        }
                    }
                    .buttonStyle(.plain)

                    if showAgenticIntakeDetails {
                        if !intake.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Original Text")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(intake.rawText)
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !intake.images.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Images")
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
                                Text("AI Metadata")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text("Provider: \(providerMetadata.provider)\(providerMetadata.model.map { " (\($0))" } ?? "")")
                                    .font(.footnote)
                                Text("Vision: \(providerMetadata.usedVision ? "Used" : "Text-only")")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !intake.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Warnings")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(Array(intake.warnings.enumerated()), id: \.offset) { entry in
                                    Text("• \(entry.element)")
                                        .font(.footnote)
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
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(selected ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.1))
        .foregroundStyle(selected ? .primary : .secondary)
        .clipShape(Capsule())
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

    func toEvent() -> Event {
        Event(
            title: title,
            note: note,
            location: location,
            timeRanges: [Event.TimeRange(start: startTime, end: endTime)],
            repeatUnit: repeatUnit,
            isAllDay: isAllDay,
            repeatInterval: repeatInterval,
            repeatEndType: repeatEndType,
            repeatEndDate: repeatEndDate,
            repeatEndCount: repeatEndCount,
            type: typeTitle,
            agenticIntake: agenticIntake
        )
    }

    func apply(to event: Event) -> Event {
        var updated = event
        updated.title = title
        updated.type = typeTitle
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
                    RoundedRectangle(cornerRadius: 10)
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
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.12))
        )
    }
}
