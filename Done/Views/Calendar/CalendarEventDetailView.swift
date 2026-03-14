import SwiftUI

private enum CalendarEventDetailPage: String, Hashable {
    case detail
    case log
}

enum CalendarEventTimelineMode: Equatable {
    case live
    case manual
}

enum CalendarEventTimelineFeedback: Equatable {
    case none
    case selection
    case noteSnap
    case resumeLive
}

struct CalendarEventTimelineResolvedState: Equatable {
    var mode: CalendarEventTimelineMode
    var displayProgress: CGFloat
    var snapshotDate: Date
}

struct CalendarEventTimelineDragResolution: Equatable {
    var mode: CalendarEventTimelineMode
    var progress: CGFloat
    var snapshotDate: Date
    var isSnappedToNote: Bool
    var selectedMinute: Int
    var feedback: CalendarEventTimelineFeedback
}

func calendarEventTimelineProgress(
    for snapshotDate: Date,
    range: Event.TimeRange
) -> CGFloat {
    let duration = range.end.timeIntervalSince(range.start)
    guard duration > 0 else { return 0 }
    let raw = snapshotDate.timeIntervalSince(range.start) / duration
    return CGFloat(min(max(raw, 0), 1))
}

func calendarEventTimelineSnapshotDate(
    for progress: CGFloat,
    range: Event.TimeRange
) -> Date {
    let duration = range.end.timeIntervalSince(range.start)
    guard duration > 0 else { return range.start }
    let clamped = min(max(progress, 0), 1)
    return range.start.addingTimeInterval(duration * Double(clamped))
}

func calendarEventTimelineTrackMinute(
    progress: CGFloat,
    range: Event.TimeRange
) -> Int {
    let duration = range.end.timeIntervalSince(range.start)
    guard duration > 0 else { return 0 }
    let clamped = min(max(progress, 0), 1)
    return Int(duration * Double(clamped) / 60)
}

func calendarEventTimelineLiveProgress(
    now: Date,
    range: Event.TimeRange
) -> CGFloat {
    calendarEventTimelineProgress(for: now, range: range)
}

func calendarEventTimelineTrackNotes(
    from notes: [EventLogTimelineNote],
    range: Event.TimeRange
) -> [EventLogTimelineNote] {
    notes
}

func calendarEventTimelineCanResumeLive(
    progress: CGFloat,
    now: Date,
    range: Event.TimeRange,
    tolerance: TimeInterval = 60
) -> Bool {
    guard now >= range.start && now <= range.end else { return false }
    let manualDate = calendarEventTimelineSnapshotDate(for: progress, range: range)
    return abs(manualDate.timeIntervalSince(now)) <= tolerance
}

func calendarEventTimelineResolvedState(
    mode: CalendarEventTimelineMode,
    manualProgress: CGFloat,
    now: Date,
    range: Event.TimeRange
) -> CalendarEventTimelineResolvedState {
    switch mode {
    case .live:
        return CalendarEventTimelineResolvedState(
            mode: .live,
            displayProgress: calendarEventTimelineLiveProgress(now: now, range: range),
            snapshotDate: now
        )
    case .manual:
        let progress = min(max(manualProgress, 0), 1)
        return CalendarEventTimelineResolvedState(
            mode: .manual,
            displayProgress: progress,
            snapshotDate: calendarEventTimelineSnapshotDate(for: progress, range: range)
        )
    }
}

func calendarEventTimelineSnapProgress(
    rawProgress: CGFloat,
    notes: [EventLogTimelineNote],
    range: Event.TimeRange,
    snapWindow: TimeInterval = 2 * 60
) -> CGFloat? {
    let duration = range.end.timeIntervalSince(range.start)
    guard duration > 0 else { return nil }

    let clampedRaw = min(max(rawProgress, 0), 1)
    let snapWindowProgress = CGFloat(snapWindow / duration)
    var closest: (progress: CGFloat, distance: CGFloat)?

    for note in calendarEventTimelineTrackNotes(from: notes, range: range) {
        let noteProgress = calendarEventTimelineProgress(for: note.createdAt, range: range)
        let distance = abs(noteProgress - clampedRaw)
        guard distance <= snapWindowProgress else { continue }

        if closest == nil || distance < closest!.distance {
            closest = (noteProgress, distance)
        }
    }

    return closest?.progress
}

func calendarEventTimelineResolveDrag(
    rawProgress: CGFloat,
    range: Event.TimeRange,
    notes: [EventLogTimelineNote],
    now: Date,
    currentMode: CalendarEventTimelineMode,
    wasSnappedToNote: Bool,
    previousSelectedMinute: Int,
    noteSnapWindow: TimeInterval = 2 * 60,
    liveResumeTolerance: TimeInterval = 60
) -> CalendarEventTimelineDragResolution {
    let clampedRaw = min(max(rawProgress, 0), 1)
    let snappedProgress = calendarEventTimelineSnapProgress(
        rawProgress: clampedRaw,
        notes: notes,
        range: range,
        snapWindow: noteSnapWindow
    )
    let manualProgress = snappedProgress ?? clampedRaw

    if calendarEventTimelineCanResumeLive(
        progress: manualProgress,
        now: now,
        range: range,
        tolerance: liveResumeTolerance
    ) {
        let liveProgress = calendarEventTimelineLiveProgress(now: now, range: range)
        return CalendarEventTimelineDragResolution(
            mode: .live,
            progress: liveProgress,
            snapshotDate: now,
            isSnappedToNote: false,
            selectedMinute: calendarEventTimelineTrackMinute(progress: liveProgress, range: range),
            feedback: currentMode == .manual ? .resumeLive : .none
        )
    }

    let didSnapToNote = snappedProgress != nil
    let selectedMinute = calendarEventTimelineTrackMinute(progress: manualProgress, range: range)
    let feedback: CalendarEventTimelineFeedback
    if didSnapToNote && !wasSnappedToNote {
        feedback = .noteSnap
    } else if !didSnapToNote && selectedMinute != previousSelectedMinute {
        feedback = .selection
    } else {
        feedback = .none
    }

    return CalendarEventTimelineDragResolution(
        mode: .manual,
        progress: manualProgress,
        snapshotDate: calendarEventTimelineSnapshotDate(for: manualProgress, range: range),
        isSnappedToNote: didSnapToNote,
        selectedMinute: selectedMinute,
        feedback: feedback
    )
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
    @State private var timelineMode: CalendarEventTimelineMode = .live
    @State private var timelineSliderProgress: CGFloat = 0
    @State private var isAddingTimelineNote = false
    @State private var timelineNoteText: String = ""
    @State private var isSnappedToNote = false
    @State private var lastHapticMinute: Int = -1
    @State private var selectedPage: CalendarEventDetailPage = .detail

    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let liveResumeFeedback = UINotificationFeedbackGenerator()

    var body: some View {
        TabView(selection: $selectedPage) {
            detailPage
                .tag(CalendarEventDetailPage.detail)

            logPage
                .tag(CalendarEventDetailPage.log)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(Color.clear)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                detailHeader
                pageSwitcher
            }
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
            prepareTimelineFeedback()
            handleRouteJump(force: true)
        }
        .onChange(of: store.calendarEvents) { _ in
            guard let _ = currentEvent, let _ = currentOccurrenceRange else {
                dismiss()
                return
            }
        }
        .onChange(of: route.id) { _ in
            didHandleInitialJump = false
            resetTimelineInteractionState()
            handleRouteJump(force: true)
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

    var detailPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                overviewSection
                timelineSection
                suggestionsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    var logPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                CalendarEventLogEditor(
                    occurrence: route.occurrence,
                    mode: .embedded,
                    autoFocusNote: selectedPage == .log && route.autoOpenComposer
                )
                .environmentObject(store)
                .id(route.id)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
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

    var pageSwitcher: some View {
        HStack(spacing: 8) {
            pagerButton(title: "Detail", page: .detail)
            pagerButton(title: "Log", page: .log)
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: Capsule())
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

    var timelineSection: some View {
        sectionCard(title: "Timeline") {
            if let event = currentEvent, let range = currentOccurrenceRange, !event.isAllDay {
                let notes = (logRecord?.timelineNotes ?? []).sorted { $0.createdAt < $1.createdAt }
                let trackNotes = calendarEventTimelineTrackNotes(from: notes, range: range)
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    let timelineState = calendarEventTimelineResolvedState(
                        mode: timelineMode,
                        manualProgress: timelineSliderProgress,
                        now: context.date,
                        range: range
                    )
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(timelineTimeLabel(timelineState.snapshotDate))
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

                        GeometryReader { geo in
                            let trackWidth = max(geo.size.width, 1)
                            let trackStartX: CGFloat = 0
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.15))
                                    .frame(width: trackWidth, height: 4)

                                Capsule()
                                    .fill(Color.primary.opacity(0.4))
                                    .frame(height: 4)
                                    .frame(width: trackWidth * timelineState.displayProgress, height: 4)

                                ForEach(trackNotes) { note in
                                    let noteProgress = notePositionOnTrack(note: note, range: range)
                                    let isNearby = isNoteNearSlider(
                                        note: note,
                                        at: timelineState.snapshotDate,
                                        range: range
                                    )
                                    Circle()
                                        .fill(isNearby ? Color.primary : Color.primary.opacity(0.35))
                                        .frame(width: isNearby ? 8 : 6, height: isNearby ? 8 : 6)
                                        .offset(x: trackStartX + trackWidth * noteProgress - (isNearby ? 4 : 3))
                                        .animation(.easeInOut(duration: 0.15), value: isNearby)
                                }

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.ultraThickMaterial)
                                    .overlay(RoundedRectangle(cornerRadius: 2).fill(Color.primary).padding(3))
                                    .frame(width: 8, height: 22)
                                    .offset(x: trackStartX + trackWidth * timelineState.displayProgress - 4)
                                    .gesture(
                                        DragGesture(
                                            minimumDistance: 0,
                                            coordinateSpace: .named("eventTimelineTrack")
                                        )
                                        .onChanged { value in
                                            handleTimelineDragChanged(
                                                value: value,
                                                trackStartX: trackStartX,
                                                trackWidth: trackWidth,
                                                range: range,
                                                notes: notes,
                                                now: context.date
                                            )
                                        }
                                    )
                            }
                            .frame(height: 22)
                            .coordinateSpace(name: "eventTimelineTrack")
                        }
                        .frame(height: 22)

                        HStack {
                            Text(timelineTimeLabel(range.start))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(timelineTimeLabel(range.end))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if isAddingTimelineNote {
                            HStack(spacing: 8) {
                                TextEditor(text: $timelineNoteText)
                                    .font(.subheadline)
                                    .frame(minHeight: 36, maxHeight: 80)
                                    .scrollContentBackground(.hidden)
                                Button {
                                    addTimelineNote(at: timelineState.snapshotDate)
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

                        if !notes.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(notes) { note in
                                    let isNearby = isNoteNearSlider(
                                        note: note,
                                        at: timelineState.snapshotDate,
                                        range: range
                                    )
                                    HStack(alignment: .top, spacing: 8) {
                                        Circle()
                                            .fill(Color.primary.opacity(isNearby ? 1.0 : 0.3))
                                            .frame(width: 6, height: 6)
                                            .padding(.top, 5)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(timelineTimeLabel(note.createdAt))
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Text(note.text)
                                                .font(.subheadline)
                                                .foregroundColor(isNearby ? Color.primary : Color.primary.opacity(0.7))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .animation(.easeInOut(duration: 0.15), value: isNearby)
                                }
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

    func pagerButton(title: String, page: CalendarEventDetailPage) -> some View {
        let isSelected = selectedPage == page
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                selectedPage = page
            }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(
                    Group {
                        if isSelected {
                            Capsule()
                                .fill(Color.primary.opacity(0.12))
                        }
                    }
                )
        }
        .buttonStyle(.plain)
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

    func handleRouteJump(force: Bool = false) {
        guard force || !didHandleInitialJump else { return }
        didHandleInitialJump = true

        let targetPage: CalendarEventDetailPage
        switch route.initialJumpTarget {
        case .some(.meta), .none:
            targetPage = .detail
        case .some(.selfEval), .some(.log):
            targetPage = .log
        }

        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                selectedPage = targetPage
            }
        }
    }

    func prepareTimelineFeedback() {
        selectionFeedback.prepare()
        impactFeedback.prepare()
        liveResumeFeedback.prepare()
    }

    func resetTimelineInteractionState() {
        timelineMode = .live
        timelineSliderProgress = 0
        isAddingTimelineNote = false
        timelineNoteText = ""
        isSnappedToNote = false
        lastHapticMinute = -1
    }

    func handleTimelineDragChanged(
        value: DragGesture.Value,
        trackStartX: CGFloat,
        trackWidth: CGFloat,
        range: Event.TimeRange,
        notes: [EventLogTimelineNote],
        now: Date
    ) {
        let rawProgress = trackWidth > 0 ? (value.location.x - trackStartX) / trackWidth : 0
        let resolution = calendarEventTimelineResolveDrag(
            rawProgress: rawProgress,
            range: range,
            notes: notes,
            now: now,
            currentMode: timelineMode,
            wasSnappedToNote: isSnappedToNote,
            previousSelectedMinute: lastHapticMinute
        )

        timelineMode = resolution.mode
        timelineSliderProgress = resolution.progress
        isSnappedToNote = resolution.isSnappedToNote
        lastHapticMinute = resolution.selectedMinute

        switch resolution.feedback {
        case .none:
            break
        case .selection:
            selectionFeedback.selectionChanged()
            selectionFeedback.prepare()
        case .noteSnap:
            impactFeedback.impactOccurred()
            impactFeedback.prepare()
        case .resumeLive:
            liveResumeFeedback.notificationOccurred(.success)
            liveResumeFeedback.prepare()
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
        calendarEventTimelineProgress(for: note.createdAt, range: range)
    }

    func isNoteNearSlider(note: EventLogTimelineNote, at selectedDate: Date, range: Event.TimeRange) -> Bool {
        let totalDuration = range.end.timeIntervalSince(range.start)
        let windowSeconds = max(totalDuration * 0.05, 60)
        return abs(note.createdAt.timeIntervalSince(selectedDate)) <= windowSeconds
    }

    func snapToNearestNote(progress: CGFloat, notes: [EventLogTimelineNote], range: Event.TimeRange) -> CGFloat? {
        calendarEventTimelineSnapProgress(rawProgress: progress, notes: notes, range: range)
    }

}
