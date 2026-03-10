import SwiftUI

private enum CalendarEventDetailSectionAnchor: String {
    case overview
    case record
    case timeline
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
    @State private var timelineSliderProgress: CGFloat = 0
    @State private var isAddingTimelineNote = false
    @State private var timelineNoteText: String = ""
    @State private var isSnappedToNote = false
    @State private var lastHapticMinute: Int = -1

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    overviewSection
                        .id(CalendarEventDetailSectionAnchor.overview.rawValue)
                    recordSection
                        .id(CalendarEventDetailSectionAnchor.record.rawValue)
                    timelineSection
                        .id(CalendarEventDetailSectionAnchor.timeline.rawValue)
                    suggestionsSection
                        .id(CalendarEventDetailSectionAnchor.suggestions.rawValue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color.clear)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top) {
                detailHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
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

    var detailHeader: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text(detailNavigationTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                Button(action: openChat) {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .disabled(currentEvent == nil)

                Button(action: startEditFlow) {
                    Image(systemName: "pencil")
                }
                .disabled(currentEvent == nil)

                Button(action: startDeleteFlow) {
                    Image(systemName: "trash")
                }
                .disabled(currentEvent == nil)
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
        }
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

    var overviewSection: some View {
        sectionCard(title: "Overview") {
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

                        Label {
                            Text(durationSummary(for: event, range: range))
                        } icon: {
                            Image(systemName: "hourglass")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    } else {
                        Label("Occurrence unavailable", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("Event not found.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var recordSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                capsuleButton(logRecord == nil ? "Start Log" : "Edit Log") {
                    openLogSheet()
                }
            }
            if let record = logRecord {
                VStack(alignment: .leading, spacing: 8) {
                    if record.completionStatus != nil || record.effort != nil {
                        HStack(spacing: 6) {
                            if let status = record.completionStatus {
                                Text(status.title)
                                    .font(.subheadline.weight(.semibold))
                            }
                            if record.completionStatus != nil && record.effort != nil {
                                Text("•")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            if let effort = record.effort {
                                Text("Effort \(effort)")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }

                    let allTags = record.emotions + record.behaviors
                    if !allTags.isEmpty {
                        tagsRow(allTags)
                    }

                    let trimmedNote = record.note.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedNote.isEmpty {
                        Text(trimmedNote)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            } else {
                Text("No log recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    var timelineSection: some View {
        sectionCard(title: "Timeline") {
            if let event = currentEvent, let range = currentOccurrenceRange, !event.isAllDay {
                let duration = range.end.timeIntervalSince(range.start)
                let selectedDate = range.start.addingTimeInterval(duration * Double(timelineSliderProgress))
                let notes = (logRecord?.timelineNotes ?? []).sorted { $0.createdAt < $1.createdAt }
                VStack(alignment: .leading, spacing: 12) {
                    // Selected time label + add button
                    HStack {
                        Text(timelineTimeLabel(selectedDate))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Spacer()
                        Button {
                            isAddingTimelineNote = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 28, height: 28)
                                .background(Color.secondary.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Timeline track with note markers
                    GeometryReader { geo in
                        let trackWidth = geo.size.width
                        ZStack(alignment: .leading) {
                            // Track background
                            Capsule()
                                .fill(Color.secondary.opacity(0.15))
                                .frame(height: 4)

                            // Filled portion
                            Capsule()
                                .fill(Color.primary.opacity(0.4))
                                .frame(width: trackWidth * timelineSliderProgress, height: 4)

                            // Note markers on track
                            ForEach(notes) { note in
                                let noteProgress = notePositionOnTrack(note: note, range: range)
                                let isNearby = isNoteNearSlider(note: note, at: selectedDate, range: range)
                                Circle()
                                    .fill(isNearby ? Color.primary : Color.primary.opacity(0.35))
                                    .frame(width: isNearby ? 8 : 6, height: isNearby ? 8 : 6)
                                    .offset(x: trackWidth * noteProgress - (isNearby ? 4 : 3))
                                    .animation(.easeInOut(duration: 0.15), value: isNearby)
                            }

                            // Thumb
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.ultraThickMaterial)
                                .overlay(RoundedRectangle(cornerRadius: 2).fill(Color.primary).padding(3))
                                .frame(width: 8, height: 22)
                                .offset(x: trackWidth * timelineSliderProgress - 4)
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            let raw = min(max(value.location.x / trackWidth, 0), 1)
                                            let snapped = snapToNearestNote(progress: raw, notes: notes, range: range)
                                            let didSnap = snapped != nil
                                            let finalProgress = snapped ?? raw
                                            timelineSliderProgress = finalProgress

                                            if didSnap && !isSnappedToNote {
                                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                            }
                                            isSnappedToNote = didSnap

                                            let currentMinute = Int(duration * Double(finalProgress) / 60)
                                            if currentMinute != lastHapticMinute {
                                                lastHapticMinute = currentMinute
                                                if !didSnap {
                                                    UISelectionFeedbackGenerator().selectionChanged()
                                                }
                                            }
                                        }
                                )
                        }
                        .frame(height: 22)
                    }
                    .frame(height: 22)

                    // Start / End labels
                    HStack {
                        Text(timelineTimeLabel(range.start))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(timelineTimeLabel(range.end))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Add note composer
                    if isAddingTimelineNote {
                        HStack(spacing: 8) {
                            TextField("Note at \(timelineTimeLabel(selectedDate))", text: $timelineNoteText, axis: .vertical)
                                .font(.subheadline)
                                .lineLimit(1...3)
                                .textFieldStyle(.plain)
                            Button {
                                addTimelineNote(at: selectedDate)
                            } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                            .disabled(timelineNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button {
                                isAddingTimelineNote = false
                                timelineNoteText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }

                    // All notes, highlighted when nearby
                    if !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(notes) { note in
                                let isNearby = isNoteNearSlider(note: note, at: selectedDate, range: range)
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Color.primary.opacity(isNearby ? 1 : 0.3))
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(timelineTimeLabel(note.createdAt))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(isNearby ? .primary : .secondary)
                                        Text(note.text)
                                            .font(.caption)
                                            .foregroundStyle(isNearby ? .primary : .secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .animation(.easeInOut(duration: 0.15), value: isNearby)
                            }
                        }
                    }
                }
            } else {
                Text("Not available for all-day events.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

    func tagsRow(_ tags: [String]) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }
    }

    func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    func capsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    func openLogSheet() {
        logSheetRequest = CalendarEventLogSheetRequest(
            occurrence: route.occurrence
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
            anchorID = CalendarEventDetailSectionAnchor.overview.rawValue
        case .selfEval, .log:
            anchorID = CalendarEventDetailSectionAnchor.record.rawValue
        }

        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            if route.autoOpenComposer {
                switch target {
                case .meta:
                    break
                case .selfEval, .log:
                    openLogSheet()
                }
            }
        }
    }

    func addTimelineNote(at date: Date) {
        let trimmed = timelineNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.upsertLogRecord(for: route.occurrence) { record in
            record.timelineNotes.append(EventLogTimelineNote(text: trimmed, createdAt: date, source: "detailTimeline"))
            record.timelineNotes.sort { $0.createdAt > $1.createdAt }
        }
        timelineNoteText = ""
        isAddingTimelineNote = false
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

    func durationSummary(for event: Event, range: Event.TimeRange) -> String {
        if event.isAllDay { return "All-day" }
        let minutes = Int(range.end.timeIntervalSince(range.start) / 60)
        let hours = minutes / 60
        let remaining = minutes % 60
        if hours == 0 { return "\(remaining)min" }
        if remaining == 0 { return "\(hours)h" }
        return "\(hours)h \(remaining)min"
    }

    func timelineTimeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func notePositionOnTrack(note: EventLogTimelineNote, range: Event.TimeRange) -> CGFloat {
        let duration = range.end.timeIntervalSince(range.start)
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(note.createdAt.timeIntervalSince(range.start) / duration, 0), 1))
    }

    func isNoteNearSlider(note: EventLogTimelineNote, at selectedDate: Date, range: Event.TimeRange) -> Bool {
        let totalDuration = range.end.timeIntervalSince(range.start)
        let windowSeconds = max(totalDuration * 0.05, 60)
        return abs(note.createdAt.timeIntervalSince(selectedDate)) <= windowSeconds
    }

    func snapToNearestNote(progress: CGFloat, notes: [EventLogTimelineNote], range: Event.TimeRange) -> CGFloat? {
        let duration = range.end.timeIntervalSince(range.start)
        guard duration > 0 else { return nil }
        let snapWindow: TimeInterval = 2 * 60
        let currentTime = range.start.addingTimeInterval(duration * Double(progress))

        var closest: (progress: CGFloat, distance: TimeInterval)?
        for note in notes {
            let dist = abs(note.createdAt.timeIntervalSince(currentTime))
            if dist <= snapWindow {
                if closest == nil || dist < closest!.distance {
                    let np = CGFloat(note.createdAt.timeIntervalSince(range.start) / duration)
                    closest = (min(max(np, 0), 1), dist)
                }
            }
        }
        return closest?.progress
    }

}
