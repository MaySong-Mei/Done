import SwiftUI

private enum CalendarEventDetailSectionAnchor: String {
    case meta
    case selfEval
    case log
    case suggestions
}

private struct CalendarDetailEditSheetRequest: Identifiable {
    let id = UUID()
    let eventID: UUID
    let occurrenceDate: Date?
    let recurrenceScope: Event.RecurrenceEditScope?
}

struct CalendarEventDetailView: View {
    let route: CalendarEventDetailRoute

    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedEffort: Int?
    @State private var selectedEmotionIDs: Set<String> = []
    @State private var selectedBehaviorIDs: Set<String> = []
    @State private var selfNoteDraft: String = ""
    @State private var logDraft: String = ""
    @State private var didLoadFeedback = false
    @State private var didHandleInitialJump = false

    @State private var editSheetRequest: CalendarDetailEditSheetRequest?
    @State private var pendingRecurringAction: CalendarRecurringScopedAction?
    @State private var showRecurringScopeDialog = false
    @State private var pendingDeleteScope: Event.RecurrenceEditScope?
    @State private var showDeleteConfirmation = false
    @State private var chatOccurrenceContext: CalendarEventOccurrenceContext?

    @FocusState private var isLogComposerFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    metaSection
                        .id(CalendarEventDetailSectionAnchor.meta.rawValue)
                    selfEvalSection
                        .id(CalendarEventDetailSectionAnchor.selfEval.rawValue)
                    logSection
                        .id(CalendarEventDetailSectionAnchor.log.rawValue)
                    suggestionsSection
                        .id(CalendarEventDetailSectionAnchor.suggestions.rawValue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.clear)
            .navigationTitle(detailNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        openChat()
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    .disabled(currentEvent == nil)

                    Button {
                        startEditFlow()
                    } label: {
                        Text("Edit")
                            .fontWeight(.semibold)
                    }
                    .disabled(currentEvent == nil)

                    Button(role: .destructive) {
                        startDeleteFlow()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(currentEvent == nil)
                }
            }
            .sheet(item: $editSheetRequest) { request in
                if let event = store.calendarEvents.first(where: { $0.id == request.eventID }) {
                    EditCalendarEventView(
                        event: event,
                        occurrenceDate: request.occurrenceDate,
                        recurrenceScope: request.recurrenceScope
                    )
                    .environmentObject(store)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                } else {
                    Text("Event not found")
                        .padding()
                }
            }
            .confirmationDialog(
                recurringScopeDialogTitle,
                isPresented: $showRecurringScopeDialog,
                titleVisibility: .visible
            ) {
                Button("This Event") {
                    handleRecurringScopeSelection(.single)
                }
                Button("This & Future Events") {
                    handleRecurringScopeSelection(.following)
                }
                Button("All Events") {
                    handleRecurringScopeSelection(.all)
                }
                Button("Cancel", role: .cancel) {
                    pendingRecurringAction = nil
                }
            }
            .alert("Delete Event", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    performDelete()
                }
            } message: {
                Text(deleteConfirmationMessage)
            }
            .navigationDestination(item: $chatOccurrenceContext) { occurrence in
                CalendarEventChatView(occurrence: occurrence)
                    .environmentObject(store)
            }
            .onAppear {
                loadFeedbackDraftsIfNeeded()
                handleRouteJump(proxy: proxy, force: true)
            }
            .onChange(of: store.calendarEventFeedbackRecords) { _ in
                if !isEditingSelfEval {
                    syncFeedbackDraftsFromStore()
                }
            }
            .onChange(of: store.calendarEvents) { _ in
                guard let _ = currentEvent, let _ = currentOccurrenceRange else {
                    dismiss()
                    return
                }
            }
            .onChange(of: route.id) { _ in
                didLoadFeedback = false
                didHandleInitialJump = false
                loadFeedbackDraftsIfNeeded()
                handleRouteJump(proxy: proxy, force: true)
            }
        }
    }
}

private extension CalendarEventDetailView {
    var currentEvent: Event? {
        calendarResolvedEventForOccurrenceContext(route.occurrence, in: store.calendarEvents)
    }

    var detailNavigationTitle: String {
        guard let title = currentEvent?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Event Detail"
        }
        return title
    }

    var currentOccurrenceRange: Event.TimeRange? {
        guard let event = currentEvent else { return nil }
        return calendarOccurrenceDisplayRange(event: event, occurrenceDate: route.occurrence.occurrenceDate)
    }

    var feedbackRecord: CalendarEventFeedbackRecord? {
        store.feedbackRecord(for: route.occurrence)
    }

    var isEditingSelfEval: Bool {
        (selectedEffort != (feedbackRecord?.effort))
            || selectedEmotionIDs != Set(feedbackRecord?.emotions ?? [])
            || selectedBehaviorIDs != Set(feedbackRecord?.behaviors ?? [])
            || selfNoteDraft != (feedbackRecord?.selfNote ?? "")
    }

    var recurringScopeDialogTitle: String {
        switch pendingRecurringAction {
        case .delete:
            return "Delete Recurring Event"
        case .edit, .none:
            return "Edit Recurring Event"
        }
    }

    var deleteConfirmationMessage: String {
        guard let event = currentEvent else {
            return "This event will be permanently deleted."
        }
        if !event.isRecurringSeries {
            return "This event will be permanently deleted."
        }
        switch pendingDeleteScope ?? .all {
        case .single:
            return "This occurrence will be deleted."
        case .following:
            return "This and future occurrences will be deleted."
        case .all:
            return "All events in this series will be deleted."
        }
    }

    var metaSection: some View {
        sectionCard(title: "Meta") {
            if let event = currentEvent {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Circle()
                            .fill(EventTypeTemplateStore.color(for: event.type))
                            .frame(width: 10, height: 10)
                        Text(event.type.isEmpty ? "Calendar Event" : event.type)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    if let range = currentOccurrenceRange {
                        Label {
                            Text(timeSummary(for: event, range: range))
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.subheadline)
                    } else {
                        Label("Occurrence unavailable", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }

                    if !event.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label {
                            Text(event.location)
                        } icon: {
                            Image(systemName: "mappin.and.ellipse")
                        }
                        .font(.subheadline)
                    }

                    if event.repeatUnit != .none {
                        Label {
                            Text(repeatSummary(for: event))
                        } icon: {
                            Image(systemName: "repeat")
                        }
                        .font(.subheadline)
                    }

                    if !event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(event.note)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let intake = event.agenticIntake {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Agentic")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(agenticSummary(intake))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Event not found.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var selfEvalSection: some View {
        sectionCard(title: "Self-Eval Dashboard") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Effort")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        ForEach(CalendarEffortRating.allCases) { rating in
                            let isSelected = selectedEffort == rating.rawValue
                            Button {
                                selectedEffort = isSelected ? nil : rating.rawValue
                            } label: {
                                Text("\(rating.rawValue)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 34, height: 34)
                                    .background(
                                        isSelected
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.12),
                                        in: Circle()
                                    )
                                    .foregroundStyle(isSelected ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                tagPickerSection(
                    title: "Emotion",
                    tags: CalendarEmotionTag.allCases.map { (id: $0.rawValue, title: $0.title) },
                    selection: $selectedEmotionIDs
                )

                tagPickerSection(
                    title: "Behavior",
                    tags: CalendarBehaviorTag.allCases.map { (id: $0.rawValue, title: $0.title) },
                    selection: $selectedBehaviorIDs
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Note")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $selfNoteDraft)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack {
                    if let updatedAt = feedbackRecord?.updatedAt {
                        Text("Updated \(relativeTimestamp(updatedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save Review") {
                        saveReview()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    var logSection: some View {
        sectionCard(title: "Log") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $logDraft)
                        .focused($isLogComposerFocused)
                        .frame(minHeight: 78)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    HStack {
                        Spacer()
                        Button("Add Log") {
                            addLog()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(logDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if let logs = feedbackRecord?.logs, !logs.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(logs.sorted(by: { $0.createdAt > $1.createdAt })) { log in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(log.text)
                                        .font(.subheadline)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(logTimestamp(log.createdAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Button(role: .destructive) {
                                    store.deleteCalendarEventLog(log.id, for: route.occurrence)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                } else {
                    Text("No logs yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var suggestionsSection: some View {
        sectionCard(title: "Suggestions") {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                Text("Coming soon")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                content()
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(tags, id: \.id) { tag in
                    let isSelected = selection.wrappedValue.contains(tag.id)
                    Button {
                        var set = selection.wrappedValue
                        if isSelected {
                            set.remove(tag.id)
                        } else {
                            set.insert(tag.id)
                        }
                        selection.wrappedValue = set
                    } label: {
                        Text(tag.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.secondary.opacity(0.1),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func loadFeedbackDraftsIfNeeded() {
        guard !didLoadFeedback else { return }
        didLoadFeedback = true
        syncFeedbackDraftsFromStore()
    }

    func syncFeedbackDraftsFromStore() {
        selectedEffort = feedbackRecord?.effort
        selectedEmotionIDs = Set(feedbackRecord?.emotions ?? [])
        selectedBehaviorIDs = Set(feedbackRecord?.behaviors ?? [])
        selfNoteDraft = feedbackRecord?.selfNote ?? ""
    }

    func saveReview() {
        store.upsertFeedbackRecord(for: route.occurrence) { record in
            record.effort = selectedEffort
            record.emotions = Array(selectedEmotionIDs).sorted()
            record.behaviors = Array(selectedBehaviorIDs).sorted()
            record.selfNote = selfNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        syncFeedbackDraftsFromStore()
    }

    func addLog() {
        let trimmed = logDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.appendCalendarEventLog(trimmed, source: "detailInline", for: route.occurrence)
        logDraft = ""
        isLogComposerFocused = false
    }

    func openChat() {
        var occurrence = route.occurrence
        occurrence.source = .detailToolbarChat
        chatOccurrenceContext = occurrence
    }

    func startEditFlow() {
        guard let event = currentEvent else { return }
        if event.isRecurringSeries {
            pendingRecurringAction = .edit
            showRecurringScopeDialog = true
        } else {
            editSheetRequest = CalendarDetailEditSheetRequest(
                eventID: event.id,
                occurrenceDate: nil,
                recurrenceScope: nil
            )
        }
    }

    func startDeleteFlow() {
        guard let event = currentEvent else { return }
        if event.isRecurringSeries {
            pendingRecurringAction = .delete
            showRecurringScopeDialog = true
        } else {
            pendingDeleteScope = nil
            showDeleteConfirmation = true
        }
    }

    func handleRecurringScopeSelection(_ scope: Event.RecurrenceEditScope) {
        guard let event = currentEvent else { return }
        let action = pendingRecurringAction
        pendingRecurringAction = nil
        switch action {
        case .edit:
            editSheetRequest = CalendarDetailEditSheetRequest(
                eventID: event.id,
                occurrenceDate: route.occurrence.occurrenceDate,
                recurrenceScope: scope
            )
        case .delete:
            pendingDeleteScope = scope
            showDeleteConfirmation = true
        case .none:
            break
        }
    }

    func performDelete() {
        guard let event = currentEvent else { return }
        if event.isRecurringSeries {
            store.deleteRecurringCalendarEvent(
                seriesEvent: event,
                occurrenceDate: route.occurrence.occurrenceDate,
                scope: pendingDeleteScope ?? .all
            )
        } else {
            store.deleteCalendarEvent(event)
        }
        dismiss()
    }

    func handleRouteJump(proxy: ScrollViewProxy, force: Bool = false) {
        guard force || !didHandleInitialJump else { return }
        didHandleInitialJump = true
        guard let target = route.initialJumpTarget else { return }

        let anchorID: String
        switch target {
        case .meta:
            anchorID = CalendarEventDetailSectionAnchor.meta.rawValue
        case .selfEval:
            anchorID = CalendarEventDetailSectionAnchor.selfEval.rawValue
        case .log:
            anchorID = CalendarEventDetailSectionAnchor.log.rawValue
        }

        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            if target == .log && route.autoOpenComposer {
                isLogComposerFocused = true
            }
        }
    }

    func timeSummary(for event: Event, range: Event.TimeRange) -> String {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        let timeFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        timeFormatter.timeStyle = .short
        if event.isAllDay {
            if calendar.isDate(range.start, inSameDayAs: range.end) {
                return "\(dateFormatter.string(from: range.start)) • All-day"
            }
            return "\(dateFormatter.string(from: range.start)) - \(dateFormatter.string(from: range.end)) • All-day"
        }
        if calendar.isDate(range.start, inSameDayAs: range.end) {
            return "\(dateFormatter.string(from: range.start)) • \(timeFormatter.string(from: range.start)) - \(timeFormatter.string(from: range.end))"
        }
        return "\(dateFormatter.string(from: range.start)) \(timeFormatter.string(from: range.start)) - \(dateFormatter.string(from: range.end)) \(timeFormatter.string(from: range.end))"
    }

    func repeatSummary(for event: Event) -> String {
        let interval = max(1, event.repeatInterval)
        let unit: String
        switch event.repeatUnit {
        case .none: unit = "Never"
        case .day: unit = interval == 1 ? "Daily" : "Every \(interval) days"
        case .week: unit = interval == 1 ? "Weekly" : "Every \(interval) weeks"
        case .month: unit = interval == 1 ? "Monthly" : "Every \(interval) months"
        case .year: unit = interval == 1 ? "Yearly" : "Every \(interval) years"
        }
        guard event.repeatUnit != .none else { return unit }

        switch event.repeatEndType {
        case .none:
            return unit
        case .onDate:
            if let date = event.repeatEndDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                return "\(unit) • Ends \(formatter.string(from: date))"
            }
            return unit
        case .afterCount:
            if let count = event.repeatEndCount {
                return "\(unit) • \(count) occurrences"
            }
            return unit
        }
    }

    func agenticSummary(_ intake: AgenticIntakeRecord) -> String {
        let provider = intake.providerMetadata?.provider ?? "AI"
        let phase = intake.processingPhase.rawValue.capitalized
        let imageCount = intake.images.count
        if imageCount > 0 {
            return "\(provider) • \(phase) • \(imageCount) image\(imageCount == 1 ? "" : "s")"
        }
        return "\(provider) • \(phase)"
    }

    func relativeTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func logTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
