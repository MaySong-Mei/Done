import SwiftUI
import UIKit

private let calendarEventQuickAdjustStepMinutes = 15
private let calendarEventMinimumDuration: TimeInterval = 15 * 60
private let calendarEventTimelineIdleAutoResumeInterval: TimeInterval = 30
private let calendarEventTimelineAutoResumeAnimationDuration: TimeInterval = 0.24
private let calendarEventTimelineComposerAnimationDuration: TimeInterval = 0.18

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

func calendarEventTimelineShouldAutoResumeLive(
    mode: CalendarEventTimelineMode,
    lastInteractionAt: Date?,
    now: Date,
    idleTimeout: TimeInterval = calendarEventTimelineIdleAutoResumeInterval
) -> Bool {
    guard mode == .manual,
          idleTimeout > 0,
          let lastInteractionAt else {
        return false
    }
    return now.timeIntervalSince(lastInteractionAt) >= idleTimeout
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

func calendarEventAdjustedRangeForDurationDelta(
    range: Event.TimeRange,
    deltaMinutes: Int,
    minimumDuration: TimeInterval = calendarEventMinimumDuration
) -> Event.TimeRange? {
    let currentDuration = range.end.timeIntervalSince(range.start)
    guard currentDuration > 0 else { return nil }

    let delta = TimeInterval(deltaMinutes * 60)
    let targetDuration = max(minimumDuration, currentDuration + delta)
    guard abs(targetDuration - currentDuration) >= 1 else { return nil }

    return Event.TimeRange(
        start: range.start,
        end: range.start.addingTimeInterval(targetDuration)
    )
}

func calendarEventCanDecreaseDuration(
    range: Event.TimeRange,
    minimumDuration: TimeInterval = calendarEventMinimumDuration
) -> Bool {
    range.end.timeIntervalSince(range.start) - minimumDuration >= 1
}

func calendarEventShouldEnableNativeInteractivePopGesture(
    viewControllerCount: Int
) -> Bool {
    viewControllerCount > 1
}

private struct CalendarDetailEditSheetRequest: Identifiable {
    let id = UUID()
    let eventID: UUID
    let occurrenceDate: Date?
    let recurrenceScope: Event.RecurrenceEditScope?
}

private struct CalendarResolvedInterruptTimelineItem: Identifiable {
    let reference: EventLogInterruptReference
    let childEvent: Event
    let childRange: Event.TimeRange
    let clippedRange: Event.TimeRange?
    let overflowsLeading: Bool
    let overflowsTrailing: Bool

    var id: UUID { reference.id }
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
    @State private var timelineLastInteractionAt: Date?
    @State private var timelineEditingNoteID: UUID?
    @State private var selectedPage: CalendarEventDetailPage = .detail
    @FocusState private var isTimelineNoteFieldFocused: Bool

    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let liveResumeFeedback = UINotificationFeedbackGenerator()

    var body: some View {
        decoratedContent
    }
}

private extension CalendarEventDetailView {
    @ViewBuilder
    var pagerContent: some View {
        TabView(selection: $selectedPage) {
            detailPage
                .background {
                    CalendarPageTabGesturePriorityProbe()
                }
                .tag(CalendarEventDetailPage.detail)

            logPage
                .background {
                    CalendarPageTabGesturePriorityProbe()
                }
                .tag(CalendarEventDetailPage.log)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    var decoratedContent: some View {
        pagerContent
            .background(Color.clear)
            .background {
                CalendarNativeInteractivePopBridge()
            }
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
            .onChange(of: timelineNoteText) { _ in
                guard isTimelineNoteComposerPresented else { return }
                noteTimelineInteraction()
            }
    }

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

    var timelineNotes: [EventLogTimelineNote] {
        (logRecord?.timelineItems ?? [])
            .compactMap(\.noteValue)
            .sorted { $0.createdAt < $1.createdAt }
    }

    var isTimelineNoteComposerPresented: Bool {
        isAddingTimelineNote || timelineEditingNoteID != nil
    }

    var interruptParentOccurrenceContext: CalendarEventOccurrenceContext? {
        guard let relation = currentEvent?.interruptRelation else { return nil }
        return CalendarEventOccurrenceContext(
            eventID: relation.parentEventID,
            occurrenceDate: relation.occurrenceDate,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineLongPress
        )
    }

    var interruptParentEvent: Event? {
        guard let context = interruptParentOccurrenceContext else { return nil }
        return calendarResolvedEventForOccurrenceContext(context, in: store.calendarEvents)
    }

    var detailPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                overviewSection
                if let images = currentEvent?.agenticIntake?.images, !images.isEmpty {
                    intakeImagesSection(images: images)
                }
                if currentEvent?.isInterrupt == true {
                    interruptRelationSection
                }
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
        case .adjustDuration:
            return "Adjust Event Duration"
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

                        HStack(spacing: 8) {
                            Label {
                                Text(durationSummary(for: event, range: range))
                            } icon: {
                                Image(systemName: "hourglass")
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                            Spacer(minLength: 0)

                            durationQuickActions(range: range)
                        }
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

    func intakeImagesSection(images: [AgenticIntakeImageRef]) -> some View {
        sectionCard(title: "Images") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(images) { ref in
                        DetailImageThumbnail(imageRef: ref)
                    }
                }
            }
        }
    }

    var interruptRelationSection: some View {
        sectionCard(title: "Interrupt Relation") {
            if let event = currentEvent,
               let relation = event.interruptRelation {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: relationStateIcon(relation.state))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(relationStateColor(relation.state))
                        Text(relationStateTitle(relation.state))
                            .font(.subheadline.weight(.semibold))
                    }

                    if let parentEvent = interruptParentEvent {
                        Text(parentEvent.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Event" : parentEvent.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Original occurrence is no longer available.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text(interruptOccurrenceDateLabel(relation.occurrenceDate))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var timelineSection: some View {
        sectionCard(title: "Timeline") {
            if let event = currentEvent, let range = currentOccurrenceRange, !event.isAllDay {
                let notes = timelineNotes
                let interruptItems = resolvedInterruptTimelineItems(for: range)
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
                                beginAddingTimelineNote()
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(width: 28, height: 28)
                                    .background(Color.secondary.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(timelineEditingNoteID != nil)
                            .opacity(timelineEditingNoteID == nil ? 1 : 0.35)
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

                                ForEach(interruptItems) { item in
                                    let tint = EventTypeTemplateStore.color(for: item.childEvent.type)
                                    if let clippedRange = item.clippedRange {
                                        let startProgress = calendarEventTimelineProgress(for: clippedRange.start, range: range)
                                        let endProgress = calendarEventTimelineProgress(for: clippedRange.end, range: range)
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(tint.opacity(0.42))
                                            .frame(
                                                width: max(8, trackWidth * max(0.02, endProgress - startProgress)),
                                                height: 10
                                            )
                                            .offset(
                                                x: trackStartX + trackWidth * startProgress,
                                                y: -3
                                            )
                                    }
                                    if item.overflowsLeading {
                                        Capsule()
                                            .fill(tint.opacity(0.7))
                                            .frame(width: 5, height: 12)
                                            .offset(x: trackStartX - 1, y: -4)
                                    }
                                    if item.overflowsTrailing {
                                        Capsule()
                                            .fill(tint.opacity(0.7))
                                            .frame(width: 5, height: 12)
                                            .offset(x: trackStartX + trackWidth - 4, y: -4)
                                    }
                                }

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
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .topLeading) {
                                    if timelineNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text("Add note")
                                            .font(.subheadline)
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 8)
                                            .allowsHitTesting(false)
                                    }

                                    TextEditor(text: $timelineNoteText)
                                        .font(.subheadline)
                                        .frame(minHeight: 36, maxHeight: 80)
                                        .scrollContentBackground(.hidden)
                                        .focused($isTimelineNoteFieldFocused)
                                        .onTapGesture {
                                            noteTimelineInteraction(at: context.date)
                                        }
                                }

                                HStack(spacing: 12) {
                                    Spacer(minLength: 0)

                                    HStack(spacing: 10) {
                                        Button {
                                            cancelTimelineNoteComposer()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 22))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            saveTimelineNote(at: timelineState.snapshotDate)
                                        } label: {
                                            Image(systemName: "plus.circle.fill")
                                                .font(.system(size: 22))
                                                .foregroundStyle(.primary)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(timelineNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                            .transition(
                                .asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity
                                )
                            )
                        }

                        if !interruptItems.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(interruptItems) { item in
                                    let tint = EventTypeTemplateStore.color(for: item.childEvent.type)
                                    HStack(alignment: .top, spacing: 8) {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(tint.opacity(0.65))
                                            .frame(width: 10, height: 18)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.childEvent.title)
                                                .font(.subheadline.weight(.semibold))
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(interruptTimelineSummary(item: item))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        if !notes.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(notes) { note in
                                    let isNearby = isNoteNearSlider(
                                        note: note,
                                        at: timelineState.snapshotDate,
                                        range: range
                                    )
                                    let isEditing = timelineEditingNoteID == note.id

                                    HStack(alignment: .top, spacing: 8) {
                                        Circle()
                                            .fill(isEditing ? Color.primary : Color.primary.opacity(isNearby ? 1.0 : 0.3))
                                            .frame(width: 6, height: 6)
                                            .padding(.top, 5)
                                        VStack(alignment: .leading, spacing: isEditing ? 8 : 2) {
                                            Text(timelineTimeLabel(note.createdAt))
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)

                                            if isEditing {
                                                TextEditor(text: $timelineNoteText)
                                                    .font(.subheadline)
                                                    .frame(minHeight: 36, maxHeight: 80)
                                                    .scrollContentBackground(.hidden)
                                                    .focused($isTimelineNoteFieldFocused)
                                                    .onTapGesture {
                                                        noteTimelineInteraction(at: context.date)
                                                    }

                                                HStack(spacing: 12) {
                                                    Button {
                                                        deleteTimelineNote(note, at: context.date)
                                                    } label: {
                                                        Image(systemName: "trash")
                                                            .font(.system(size: 14, weight: .semibold))
                                                            .foregroundStyle(.red)
                                                            .frame(width: 28, height: 28)
                                                            .background(Color.red.opacity(0.08), in: Circle())
                                                    }
                                                    .buttonStyle(.plain)

                                                    Spacer(minLength: 0)

                                                    HStack(spacing: 10) {
                                                        Button {
                                                            cancelTimelineNoteComposer(at: context.date)
                                                        } label: {
                                                            Image(systemName: "xmark.circle.fill")
                                                                .font(.system(size: 22))
                                                                .foregroundStyle(.secondary)
                                                        }
                                                        .buttonStyle(.plain)

                                                        Button {
                                                            saveTimelineNote(at: timelineState.snapshotDate)
                                                        } label: {
                                                            Image(systemName: "checkmark.circle.fill")
                                                                .font(.system(size: 22))
                                                                .foregroundStyle(.primary)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .disabled(timelineNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                                    }
                                                }
                                            } else {
                                                Text(note.text)
                                                    .font(.subheadline)
                                                    .foregroundColor(isNearby ? Color.primary : Color.primary.opacity(0.7))
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, isEditing ? 10 : 0)
                                    .padding(.vertical, isEditing ? 10 : 2)
                                    .background(
                                        Color.secondary.opacity(isEditing ? 0.07 : 0),
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .contentShape(Rectangle())
                                    .onLongPressGesture {
                                        guard !isEditing else { return }
                                        beginEditingTimelineNote(note, at: context.date)
                                    }
                                    .animation(.easeInOut(duration: 0.15), value: isNearby)
                                }
                            }
                        }
                    }
                    .onChange(of: context.date) { newValue in
                        handleTimelineTick(now: newValue, range: range)
                    }
                    .onAppear {
                        handleTimelineTick(now: context.date, range: range)
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

    @ViewBuilder
    func durationQuickActions(range: Event.TimeRange) -> some View {
        if let event = currentEvent, !event.isAllDay {
            let canDecrease = calendarEventCanDecreaseDuration(range: range)
            let minutes = Int(range.end.timeIntervalSince(range.start) / 60)
            let label = minutes >= 60
                ? (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h\(minutes % 60)m")
                : "\(minutes)m"

            HStack(spacing: 0) {
                Button {
                    quickAdjustDuration(by: -calendarEventQuickAdjustStepMinutes)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canDecrease)
                .opacity(canDecrease ? 1 : 0.35)

                Text(label)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 40)

                Button {
                    quickAdjustDuration(by: calendarEventQuickAdjustStepMinutes)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(Color.secondary.opacity(0.08), in: Capsule())
        }
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

    func quickAdjustDuration(by deltaMinutes: Int) {
        guard let event = currentEvent else { return }
        if event.isRecurringSeries {
            pendingRecurringAction = .adjustDuration(deltaMinutes: deltaMinutes)
            showRecurringScopeDialog = true
            return
        }
        applyDurationAdjustment(to: event, deltaMinutes: deltaMinutes, scope: nil)
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
        case let .adjustDuration(deltaMinutes):
            applyDurationAdjustment(to: event, deltaMinutes: deltaMinutes, scope: scope)
        case .delete:
            pendingDeleteScope = scope
            showDeleteConfirmation = true
        case .none:
            break
        }
    }

    func applyDurationAdjustment(
        to event: Event,
        deltaMinutes: Int,
        scope: Event.RecurrenceEditScope?
    ) {
        guard let currentRange = currentOccurrenceRange,
              let adjustedRange = calendarEventAdjustedRangeForDurationDelta(
                range: currentRange,
                deltaMinutes: deltaMinutes
              ) else {
            return
        }

        if event.isRecurringSeries, let scope {
            store.applyRecurringEdit(
                seriesEvent: event,
                occurrenceDate: route.occurrence.occurrenceDate,
                scope: scope
            ) { editableEvent in
                guard let start = editableEvent.primaryTimeRange?.start else { return }
                editableEvent.timeRanges = [
                    Event.TimeRange(start: start, end: start.addingTimeInterval(adjustedRange.end.timeIntervalSince(adjustedRange.start)))
                ]
            }
            return
        }

        guard let start = event.primaryTimeRange?.start else { return }
        var updated = event
        updated.timeRanges = [
            Event.TimeRange(start: start, end: start.addingTimeInterval(adjustedRange.end.timeIntervalSince(adjustedRange.start)))
        ]
        store.updateCalendarEvent(updated)
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
        timelineLastInteractionAt = nil
        timelineEditingNoteID = nil
        isTimelineNoteFieldFocused = false
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
        noteTimelineInteraction(at: now)
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

    func handleTimelineTick(now: Date, range: Event.TimeRange) {
        guard calendarEventTimelineShouldAutoResumeLive(
            mode: timelineMode,
            lastInteractionAt: timelineLastInteractionAt,
            now: now
        ) else {
            return
        }
        resumeTimelineToLive(now: now, range: range, animated: true)
    }

    func resumeTimelineToLive(
        now: Date,
        range: Event.TimeRange,
        animated: Bool
    ) {
        let liveProgress = calendarEventTimelineLiveProgress(now: now, range: range)
        let update = {
            timelineMode = .live
            timelineSliderProgress = liveProgress
            isSnappedToNote = false
            lastHapticMinute = calendarEventTimelineTrackMinute(progress: liveProgress, range: range)
            timelineLastInteractionAt = nil
        }

        if animated {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: calendarEventTimelineAutoResumeAnimationDuration)) {
                update()
            }
        } else {
            update()
        }
    }

    func noteTimelineInteraction(at now: Date = Date()) {
        timelineLastInteractionAt = now
    }

    func focusTimelineNoteField() {
        DispatchQueue.main.async {
            isTimelineNoteFieldFocused = true
        }
    }

    func runTimelineComposerAnimation(_ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(.easeOut(duration: calendarEventTimelineComposerAnimationDuration)) {
                updates()
            }
        }
    }

    func beginAddingTimelineNote(at now: Date = Date()) {
        guard !isAddingTimelineNote || timelineEditingNoteID != nil else {
            focusTimelineNoteField()
            noteTimelineInteraction(at: now)
            return
        }
        runTimelineComposerAnimation {
            timelineEditingNoteID = nil
            isAddingTimelineNote = true
            timelineNoteText = ""
        }
        focusTimelineNoteField()
        noteTimelineInteraction(at: now)
    }

    func beginEditingTimelineNote(_ note: EventLogTimelineNote, at now: Date = Date()) {
        guard timelineEditingNoteID != note.id || isAddingTimelineNote else {
            focusTimelineNoteField()
            noteTimelineInteraction(at: now)
            return
        }
        runTimelineComposerAnimation {
            timelineEditingNoteID = note.id
            isAddingTimelineNote = false
            timelineNoteText = note.text
        }
        focusTimelineNoteField()
        noteTimelineInteraction(at: now)
    }

    func cancelTimelineNoteComposer(at now: Date = Date()) {
        guard isTimelineNoteComposerPresented else {
            noteTimelineInteraction(at: now)
            return
        }
        isTimelineNoteFieldFocused = false
        runTimelineComposerAnimation {
            isAddingTimelineNote = false
            timelineEditingNoteID = nil
            timelineNoteText = ""
        }
        noteTimelineInteraction(at: now)
    }

    func saveTimelineNote(at date: Date) {
        let trimmed = timelineNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let timelineEditingNoteID {
            store.updateTimelineNote(
                timelineEditingNoteID,
                text: trimmed,
                for: route.occurrence
            )
        } else {
            store.appendTimelineNote(
                trimmed,
                createdAt: date,
                source: "detailTimeline",
                for: route.occurrence
            )
        }
        cancelTimelineNoteComposer()
    }

    func deleteTimelineNote(_ note: EventLogTimelineNote, at now: Date = Date()) {
        store.deleteTimelineNote(note.id, for: route.occurrence)
        if timelineEditingNoteID == note.id {
            isTimelineNoteFieldFocused = false
            runTimelineComposerAnimation {
                isAddingTimelineNote = false
                timelineEditingNoteID = nil
                timelineNoteText = ""
            }
        }
        noteTimelineInteraction(at: now)
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

    func resolvedInterruptTimelineItems(
        for range: Event.TimeRange
    ) -> [CalendarResolvedInterruptTimelineItem] {
        (logRecord?.timelineItems ?? [])
            .compactMap(\.interruptReferenceValue)
            .compactMap { reference in
                guard let childEvent = store.findCalendarEvent(id: reference.childEventID),
                      let childRange = childEvent.primaryTimeRange else {
                    return nil
                }
                let clippedStart = max(range.start, childRange.start)
                let clippedEnd = min(range.end, childRange.end)
                let clippedRange = clippedEnd > clippedStart
                    ? Event.TimeRange(start: clippedStart, end: clippedEnd)
                    : nil
                return CalendarResolvedInterruptTimelineItem(
                    reference: reference,
                    childEvent: childEvent,
                    childRange: childRange,
                    clippedRange: clippedRange,
                    overflowsLeading: childRange.start < range.start,
                    overflowsTrailing: childRange.end > range.end
                )
            }
            .sorted { lhs, rhs in
                if lhs.childRange.start != rhs.childRange.start {
                    return lhs.childRange.start < rhs.childRange.start
                }
                return lhs.childEvent.id.uuidString < rhs.childEvent.id.uuidString
            }
    }

    func interruptTimelineSummary(item: CalendarResolvedInterruptTimelineItem) -> String {
        let base = "\(timelineTimeLabel(item.childRange.start)) - \(timelineTimeLabel(item.childRange.end))"
        if let state = item.childEvent.interruptRelation?.state {
            return "\(base) • \(relationStateTitle(state))"
        }
        return base
    }

    func interruptOccurrenceDateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    func relationStateTitle(_ state: EventInterruptRelationState) -> String {
        switch state {
        case .embedded:
            return "Inside original occurrence"
        case .detached:
            return "Moved outside original occurrence"
        case .orphaned:
            return "Original occurrence missing"
        }
    }

    func relationStateIcon(_ state: EventInterruptRelationState) -> String {
        switch state {
        case .embedded:
            return "link"
        case .detached:
            return "arrow.up.right"
        case .orphaned:
            return "link.slash"
        }
    }

    func relationStateColor(_ state: EventInterruptRelationState) -> Color {
        switch state {
        case .embedded:
            return .green
        case .detached:
            return .orange
        case .orphaned:
            return .secondary
        }
    }

}

private struct CalendarNativeInteractivePopBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.refreshInteractivePopGestureIfNeeded()
    }

    final class Controller: UIViewController {
        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            refreshInteractivePopGestureIfNeeded()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            refreshInteractivePopGestureIfNeeded()
        }

        func refreshInteractivePopGestureIfNeeded() {
            guard let navigationController,
                  let interactivePopGestureRecognizer = navigationController.interactivePopGestureRecognizer else {
                return
            }

            interactivePopGestureRecognizer.isEnabled =
                calendarEventShouldEnableNativeInteractivePopGesture(
                    viewControllerCount: navigationController.viewControllers.count
                )
            interactivePopGestureRecognizer.delegate = nil
        }
    }
}

private struct CalendarPageTabGesturePriorityProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.refreshGesturePriorityIfNeeded()
    }

    final class ProbeView: UIView {
        private weak var configuredPagingScrollView: UIScrollView?
        private weak var configuredInteractivePopGestureRecognizer: UIGestureRecognizer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refreshGesturePriorityIfNeeded()
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            refreshGesturePriorityIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            refreshGesturePriorityIfNeeded()
        }

        func refreshGesturePriorityIfNeeded() {
            guard let pagingScrollView = nearestPagingScrollView(),
                  let interactivePopGestureRecognizer = nearestNavigationController()?.interactivePopGestureRecognizer else {
                return
            }

            if configuredPagingScrollView !== pagingScrollView
                || configuredInteractivePopGestureRecognizer !== interactivePopGestureRecognizer {
                pagingScrollView.panGestureRecognizer.require(toFail: interactivePopGestureRecognizer)
                configuredPagingScrollView = pagingScrollView
                configuredInteractivePopGestureRecognizer = interactivePopGestureRecognizer
            }
        }

        private func nearestPagingScrollView() -> UIScrollView? {
            var current = superview
            while let view = current {
                if let scrollView = view as? UIScrollView,
                   scrollView.isPagingEnabled {
                    return scrollView
                }
                current = view.superview
            }
            return nil
        }

        private func nearestNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let navigationController = current as? UINavigationController {
                    return navigationController
                }
                if let viewController = current as? UIViewController,
                   let navigationController = viewController.navigationController {
                    return navigationController
                }
                responder = current.next
            }
            return nil
        }
    }
}

private struct DetailImageThumbnail: View {
    let imageRef: AgenticIntakeImageRef
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            if image == nil {
                image = AgenticIntakeAssetStore().loadImage(for: imageRef)
            }
        }
    }
}
