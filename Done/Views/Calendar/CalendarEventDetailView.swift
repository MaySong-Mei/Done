import SwiftUI

private enum CalendarEventDetailSectionAnchor: String {
    case meta
    case record
    case notes
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

    @State private var didHandleInitialJump = false
    @State private var editSheetRequest: CalendarDetailEditSheetRequest?
    @State private var pendingRecurringAction: CalendarRecurringScopedAction?
    @State private var showRecurringScopeDialog = false
    @State private var pendingDeleteScope: Event.RecurrenceEditScope?
    @State private var showDeleteConfirmation = false
    @State private var chatOccurrenceContext: CalendarEventOccurrenceContext?
    @State private var logSheetRequest: CalendarEventLogSheetRequest?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    metaSection
                        .id(CalendarEventDetailSectionAnchor.meta.rawValue)
                    recordSection
                        .id(CalendarEventDetailSectionAnchor.record.rawValue)
                    timelineNotesSection
                        .id(CalendarEventDetailSectionAnchor.notes.rawValue)
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
            .sheet(item: $logSheetRequest) { request in
                CalendarEventLogSheet(request: request)
                    .environmentObject(store)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
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
                handleRouteJump(proxy: proxy, force: true)
            }
            .onChange(of: store.calendarEvents) { _ in
                guard let _ = currentEvent, let _ = currentOccurrenceRange else {
                    dismiss()
                    return
                }
            }
            .onChange(of: route.id) { _ in
                didHandleInitialJump = false
                handleRouteJump(proxy: proxy, force: true)
            }
        }
    }
}

private extension CalendarEventDetailView {
    var currentEvent: Event? {
        calendarResolvedEventForOccurrenceContext(route.occurrence, in: store.calendarEvents)
    }

    var currentOccurrenceRange: Event.TimeRange? {
        guard let event = currentEvent else { return nil }
        return calendarOccurrenceDisplayRange(event: event, occurrenceDate: route.occurrence.occurrenceDate)
    }

    var logRecord: CalendarEventLogRecord? {
        store.logRecord(for: route.occurrence)
    }

    var fallbackDraft: CalendarEventLogDraft {
        store.prefilledDraft(for: route.occurrence)
    }

    var timelineNotes: [EventLogTimelineNote] {
        if let logRecord {
            return logRecord.timelineNotes.sorted { $0.createdAt > $1.createdAt }
        }
        return fallbackDraft.timelineNotes.sorted { $0.createdAt > $1.createdAt }
    }

    var detailNavigationTitle: String {
        guard let title = currentEvent?.title.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Event Detail"
        }
        return title
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

    var effectiveTemplateTitle: String? {
        if let logRecord, let selected = EventLogTemplateRegistry.title(for: logRecord.selectedTemplateID) {
            return selected
        }
        return EventLogTemplateRegistry.title(for: currentEvent?.suggestedLogTemplateID)
    }

    var summaryPreview: String {
        if let summary = logRecord?.summary.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return summary
        }
        if let note = logRecord?.note.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            return note
        }
        if !fallbackDraft.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallbackDraft.summary
        }
        return fallbackDraft.note
    }

    var recordUpdatedAt: Date? {
        logRecord?.updatedAt ?? store.feedbackRecord(for: route.occurrence)?.updatedAt
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

    var recordSection: some View {
        sectionCard(title: "Record") {
            VStack(alignment: .leading, spacing: 12) {
                if let effectiveTemplateTitle {
                    infoRow(title: "Template", value: effectiveTemplateTitle)
                }

                if let completionStatus = logRecord?.completionStatus {
                    infoRow(title: "Completion", value: completionStatus.title)
                }

                if let updatedAt = recordUpdatedAt {
                    infoRow(title: "Updated", value: relativeTimestamp(updatedAt))
                }

                if !summaryPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Summary")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(summaryPreview)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("No structured record yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(logRecord == nil ? "Open Log" : "Edit Log") {
                    openLogSheet(initialFocus: .base)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    var timelineNotesSection: some View {
        sectionCard(title: "Timeline Notes") {
            VStack(alignment: .leading, spacing: 12) {
                if timelineNotes.isEmpty {
                    Text("No notes yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(timelineNotes.prefix(3))) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(logTimestamp(note.createdAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                HStack {
                    Button(timelineNotes.isEmpty ? "Add Note" : "View All") {
                        openLogSheet(initialFocus: .notes)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Open Log") {
                        openLogSheet(initialFocus: .base)
                    }
                    .buttonStyle(.borderedProminent)
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

    func infoRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    func openLogSheet(initialFocus: CalendarEventLogSheetInitialFocus) {
        logSheetRequest = CalendarEventLogSheetRequest(
            occurrence: route.occurrence,
            initialFocus: initialFocus
        )
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
            anchorID = CalendarEventDetailSectionAnchor.record.rawValue
        case .log:
            anchorID = CalendarEventDetailSectionAnchor.notes.rawValue
        }

        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            if route.autoOpenComposer {
                switch target {
                case .meta:
                    break
                case .selfEval:
                    openLogSheet(initialFocus: .base)
                case .log:
                    openLogSheet(initialFocus: .notes)
                }
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
        calendarRepeatSummary(for: event)
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
