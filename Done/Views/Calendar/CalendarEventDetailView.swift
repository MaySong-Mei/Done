import PhotosUI
import SwiftUI
import UIKit

// MARK: - Detail Header Tool Configuration

enum DetailHeaderTool: String, CaseIterable, Identifiable {
    case add
    case chat
    case edit
    case delete

    var id: String { rawValue }

    var label: String {
        switch self {
        case .add: return "Add"
        case .chat: return "Chat"
        case .edit: return "Edit"
        case .delete: return "Delete"
        }
    }

    var icon: String {
        switch self {
        case .add: return "plus"
        case .chat: return "bubble.left.and.bubble.right"
        case .edit: return "pencil"
        case .delete: return "trash"
        }
    }
}

func detailHeaderExposedTools(from raw: String) -> Set<DetailHeaderTool> {
    let ids = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    var result = Set<DetailHeaderTool>()
    for id in ids {
        if let tool = DetailHeaderTool(rawValue: id) {
            result.insert(tool)
        }
    }
    return result
}

func detailHeaderExposedToolsString(from tools: Set<DetailHeaderTool>) -> String {
    DetailHeaderTool.allCases.filter { tools.contains($0) }.map(\.rawValue).joined(separator: ",")
}

// MARK: - Timeline Composer Mode

enum TimelineComposerMode: Equatable {
    case note
    case interrupt
    case parallel
}

private let calendarEventQuickAdjustStepMinutes = 15
private let calendarEventMinimumDuration: TimeInterval = 15 * 60
private let calendarEventTimelineIdleAutoResumeInterval: TimeInterval = 30
private let calendarEventTimelineAutoResumeAnimationDuration: TimeInterval = 0.24
private let calendarEventTimelineComposerAnimationDuration: TimeInterval = 0.18
private let detailHeaderEstimatedHeight: CGFloat = 52



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

private struct CalendarResolvedParallelTimelineItem: Identifiable {
    let reference: EventLogParallelReference
    let childEvent: Event
    let childRange: Event.TimeRange
    let clippedRange: Event.TimeRange?
    var id: UUID { reference.id }
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

private struct TimelineNoteImageDraft: Identifiable {
    let id: UUID
    let data: Data
    let preview: UIImage
}

/// Two-page split for the event detail view: page 1 is a passive overview
/// + quick-action surface (low cognitive load); page 2 is the heavier
/// reflective record surface (note + signals + images).  Users swipe
/// horizontally between them.
enum CalendarEventDetailPage: String, Hashable {
    case overview
    case reflection
}

struct CalendarEventDetailView: View {
    let route: CalendarEventDetailRoute

    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedPage: CalendarEventDetailPage = .overview
    @State private var didHandleInitialJump = false

    @AppStorage(AppSettingsKeys.detailHeaderExposedTools) private var detailExposedToolsRaw = "add"
    @AppStorage(AppSettingsKeys.experimentalMultiTypeEvents) private var experimentalMultiTypeEnabled = false
    @AppStorage(AppSettingsKeys.experimentalMultiTypeMaxCount) private var experimentalMultiTypeMaxCount = 2
    @StateObject private var multiTypeTemplateStore = EventTypeTemplateStore()
    @State private var editSheetRequest: CalendarDetailEditSheetRequest?
    @State private var pendingRecurringAction: CalendarRecurringScopedAction?
    @State private var showRecurringScopeDialog = false
    @State private var pendingDeleteScope: Event.RecurrenceEditScope?
    @State private var showDeleteConfirmation = false
    @State private var chatOccurrenceContext: CalendarEventOccurrenceContext?
    @State private var timelineMode: CalendarEventTimelineMode = .live
    @State private var timelineSliderProgress: CGFloat = 0
    @State private var timelineComposerMode: TimelineComposerMode = .note
    @State private var isAddingTimelineNote = false
    @State private var timelineNoteText: String = ""
    @State private var interruptTitle: String = ""
    @State private var interruptTypeTitle: String = ""
    @State private var interruptNoteText: String = ""
    @State private var interruptStartProgress: CGFloat = 0.5
    @State private var interruptEndProgress: CGFloat = 0.75
    @State private var interruptDidExplicitlySelectType = false
    @State private var interruptAutoTypeTask: Task<Void, Never>?
    @State private var editingInterruptID: UUID?
    @StateObject private var interruptTemplateStore = EventTypeTemplateStore()
    @State private var parallelTitle: String = ""
    @State private var parallelTypeTitle: String = ""
    @State private var parallelNoteText: String = ""
    @State private var parallelStartProgress: CGFloat = 0.0
    @State private var parallelEndProgress: CGFloat = 1.0
    @State private var parallelDidExplicitlySelectType = false
    @State private var parallelAutoTypeTask: Task<Void, Never>?
    @State private var isSnappedToNote = false
    @State private var lastHapticMinute: Int = -1
    @State private var timelineLastInteractionAt: Date?
    @State private var timelineEditingNoteID: UUID?
    @State private var timelineNotePickerItems: [PhotosPickerItem] = []
    @State private var timelineNoteImageDrafts: [TimelineNoteImageDraft] = []
    @State private var timelineNoteExistingImages: [AgenticIntakeImageRef] = []
    @FocusState private var isTimelineNoteFieldFocused: Bool

    @State private var detailNoteText: String = ""
    @State private var detailSelectedTemplateID: EventLogTemplateID?
    @State private var detailTemplateAnswers: [String: EventLogAnswerValue] = [:]
    @State private var detailPickerItems: [PhotosPickerItem] = []
    @State private var detailExistingImages: [AgenticIntakeImageRef] = []
    @State private var detailNewImages: [DetailImageDraft] = []
    @State private var didLoadDetailDraft = false

    private struct DetailImageDraft: Identifiable {
        let id: UUID
        let data: Data
        let preview: UIImage
    }

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
            overviewPage
                .background {
                    // Defers TabView's paging pan to the navigation
                    // controller's interactive-pop gesture so left-edge
                    // swipes still pop back to the calendar.
                    CalendarPageTabGesturePriorityProbe()
                }
                .tag(CalendarEventDetailPage.overview)
                .accessibilityLabel(L(.pageOverview))
            reflectionPage
                .background {
                    CalendarPageTabGesturePriorityProbe()
                }
                .tag(CalendarEventDetailPage.reflection)
                .accessibilityLabel(L(.pageReflection))
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    var decoratedContent: some View {
        GeometryReader { proxy in
            let windowInsets = calendarWindowSafeAreaInsets()
            let safeTop = calendarResolvedSafeAreaInset(
                proxyInset: proxy.safeAreaInsets.top,
                windowInset: windowInsets.top
            )

            ZStack(alignment: .top) {
                pagerContent
                    .contentMargins(.top, safeTop - 12, for: .scrollContent)

                VStack(spacing: 8) {
                    detailHeader
                }
                .padding(.horizontal, 16)
                .padding(.top, safeTop + 4)
                .padding(.bottom, 8)
            }
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .background(Color.clear)
        .background {
            CalendarNativeInteractivePopBridge()
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .scrollContentBackground(.hidden)
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
                    Text(L(.eventNotFound))
                        .padding()
                }
            }
            .confirmationDialog(
                recurringScopeDialogTitle,
                isPresented: $showRecurringScopeDialog,
                titleVisibility: .visible
            ) {
                Button(L(.thisEvent)) {
                    handleRecurringScopeSelection(.single)
                }
                Button(L(.thisAndFuture)) {
                    handleRecurringScopeSelection(.following)
                }
                Button(L(.allEvents)) {
                    handleRecurringScopeSelection(.all)
                }
                Button(L(.cancel), role: .cancel) {
                    pendingRecurringAction = nil
                }
            }
            .alert(L(.deleteEvent), isPresented: $showDeleteConfirmation) {
                Button(L(.cancel), role: .cancel) { }
                Button(L(.delete), role: .destructive) {
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
            .onChange(of: store.calendarEvents) {
                guard let _ = currentEvent, let _ = currentOccurrenceRange else {
                    dismiss()
                    return
                }
            }
            .onChange(of: route.id) {
                didHandleInitialJump = false
                resetTimelineInteractionState()
                handleRouteJump(force: true)
            }
            .onChange(of: timelineNoteText) {
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

    var prefilledLogDraft: CalendarEventLogDraft {
        store.prefilledDraft(for: route.occurrence)
    }

    var quickCompletionValue: EventLogCompletionStatus? {
        prefilledLogDraft.completionStatus
    }

    var quickEmotionIDs: Set<String> {
        Set(prefilledLogDraft.emotions)
    }

    var quickBehaviorIDs: Set<String> {
        Set(prefilledLogDraft.behaviors)
    }

    var quickEffortValue: Int? {
        prefilledLogDraft.effort
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

    /// Page 1 — Overview.  Passive summary + quick state setters.  Low
    /// cognitive load: no keyboard, just glance + tap.
    var overviewPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                overviewSection
                timelineSection
                completionQuickSection
                effortQuickSection
                if let images = currentEvent?.agenticIntake?.images, !images.isEmpty {
                    intakeImagesSection(images: images)
                }
                if currentEvent?.isInterrupt == true {
                    interruptRelationSection
                }
                if currentEvent?.isParallel == true {
                    parallelRelationSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    /// Page 2 — Reflection.  Higher cognitive load: free-text note,
    /// emotion/behavior tagging, image attachments.  Mini header at top
    /// keeps the user anchored to which event they're recording.
    var reflectionPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                reflectionMiniHeader
                if experimentalMultiTypeEnabled {
                    multiTypeStackedCardsSection
                }
                signalsQuickSection
                detailNoteSection
                detailImagesSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .onAppear { loadDetailDraftIfNeeded() }
        .onChange(of: detailNoteText) { if didLoadDetailDraft { saveDetailNoteAndTemplate() } }
        .onChange(of: detailSelectedTemplateID) { if didLoadDetailDraft { saveDetailNoteAndTemplate() } }
        .onChange(of: detailTemplateAnswers.count) { if didLoadDetailDraft { saveDetailNoteAndTemplate() } }
    }

    /// Compact one-line "what event am I recording" anchor for Page 2.
    /// Doesn't take an action — just keeps the user oriented.
    var reflectionMiniHeader: some View {
        Group {
            if let event = currentEvent {
                HStack(spacing: 8) {
                    Circle()
                        .fill(CalendarLayout.eventColor(for: event))
                        .frame(width: 8, height: 8)
                    Text(event.title.isEmpty ? "Untitled" : event.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let range = currentOccurrenceRange {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(timeSummary(for: event, range: range))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }


    private var detailExposedTools: Set<DetailHeaderTool> {
        detailHeaderExposedTools(from: detailExposedToolsRaw)
    }

    var detailHeader: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
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

            detailHeaderActionCapsule
        }
    }

    private var detailHeaderActionCapsule: some View {
        let exposed = DetailHeaderTool.allCases.filter { detailExposedTools.contains($0) }
        let showLabels = exposed.count == 1
        let menuTools = DetailHeaderTool.allCases.filter { !detailExposedTools.contains($0) }

        return HStack(spacing: 0) {
            ForEach(Array(exposed.enumerated()), id: \.element.id) { index, tool in
                if index > 0 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: 1, height: 16)
                }
                detailHeaderToolButton(tool, showLabel: showLabels)
            }

            if !exposed.isEmpty {
                Rectangle()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: 1, height: 16)
            }

            Menu {
                ForEach(menuTools) { tool in
                    Button { detailHeaderAction(for: tool) } label: {
                        Label(tool.label, systemImage: tool.icon)
                    }
                    .disabled(tool != .add && currentEvent == nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.primary)
        .frame(height: 40)
        .contentShape(Capsule())
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private func detailHeaderToolButton(_ tool: DetailHeaderTool, showLabel: Bool) -> some View {
        if tool == .add {
            detailHeaderAddMenu(showLabel: showLabel)
        } else {
            Button { detailHeaderAction(for: tool) } label: {
                detailHeaderToolLabel(tool, showLabel: showLabel)
            }
            .buttonStyle(.plain)
            .disabled(currentEvent == nil)
        }
    }

    private func detailHeaderAddMenu(showLabel: Bool) -> some View {
        Menu {
            Button { beginAddingTimelineNote() } label: {
                Label("Note", systemImage: "note.text")
            }
            Button { beginAddingInterruptFromDetail() } label: {
                Label("Interrupt", systemImage: "bolt.fill")
            }
            Button { beginAddingParallelFromDetail() } label: {
                Label("Parallel", systemImage: "arrow.triangle.branch")
            }
        } label: {
            detailHeaderToolLabel(.add, showLabel: showLabel)
        }
    }

    @ViewBuilder
    private func detailHeaderToolLabel(_ tool: DetailHeaderTool, showLabel: Bool) -> some View {
        if showLabel {
            HStack(spacing: 6) {
                Image(systemName: tool.icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(tool.label)
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
        } else {
            Image(systemName: tool.icon)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
    }

    private func detailHeaderAction(for tool: DetailHeaderTool) {
        switch tool {
        case .add: break // handled by menu
        case .chat: openChat()
        case .edit: startEditFlow()
        case .delete: startDeleteFlow()
        }
    }

    func beginAddingInterruptFromDetail() {
        guard currentEvent != nil, let range = currentOccurrenceRange else { return }
        timelineComposerMode = .interrupt
        interruptTitle = ""
        interruptNoteText = ""
        interruptDidExplicitlySelectType = false
        interruptTypeTitle = currentEvent?.type ?? ""
        // Default to a segment in the latter half of the event
        let now = Date()
        if (range.start...range.end).contains(now) {
            let progress = calendarEventTimelineProgress(for: now, range: range)
            interruptStartProgress = progress
            interruptEndProgress = min(1.0, progress + 0.15)
        } else {
            interruptStartProgress = 0.5
            interruptEndProgress = 0.75
        }
        isAddingTimelineNote = true
    }

    func beginAddingParallelFromDetail() {
        guard currentEvent != nil, let range = currentOccurrenceRange else { return }
        timelineComposerMode = .parallel
        parallelTitle = ""
        parallelNoteText = ""
        parallelTypeTitle = ""
        parallelDidExplicitlySelectType = false
        parallelStartProgress = 0.0
        parallelEndProgress = 1.0
        isAddingTimelineNote = true
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
        sectionCard(title: detailNavigationTitle) {
            if let event = currentEvent {
                VStack(alignment: .leading, spacing: 4) {

                    HStack(spacing: 6) {
                        Circle()
                            .fill(CalendarLayout.eventColor(for: event))
                            .frame(width: 8, height: 8)
                        Text(event.type.isEmpty ? "Calendar Event" : event.type)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if event.isRecurringSeries {
                            detailPillLabel("Recurring")
                        }
                    }

                    if let range = currentOccurrenceRange {
                        HStack {
                            Text(timeSummary(for: event, range: range))
                                .font(.caption.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer()

                            durationQuickActions(range: range)
                        }
                    } else {
                        Label("Occurrence unavailable", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }

                    if quickCompletionValue != nil || quickEffortValue != nil {
                        HStack(spacing: 6) {
                            if let status = quickCompletionValue {
                                overviewBadgeSmall(status.title, tint: .primary, fill: Color.secondary.opacity(0.08))
                            }
                            if let effortVal = quickEffortValue {
                                let descriptor = calendarHumanEffortDescriptor(for: effortVal)
                                let tint = EventTypeTemplateStore.color(for: event.type)
                                overviewBadgeSmall(descriptor.title, tint: tint, fill: tint.opacity(0.14))
                            }
                        }
                    }

                    if !quickEmotionIDs.isEmpty {
                        overviewBadgeRow(title: L(.emotion)) {
                            ForEach(quickEmotionIDs.sorted(), id: \.self) { eid in
                                if let tag = CalendarEmotionTag(rawValue: eid) {
                                    overviewBadge(tag.title, tint: .accentColor, fill: Color.accentColor.opacity(0.18))
                                }
                            }
                        }
                    }

                    if !quickBehaviorIDs.isEmpty {
                        overviewBadgeRow(title: L(.behaviorLabel)) {
                            ForEach(quickBehaviorIDs.sorted(), id: \.self) { bid in
                                if let tag = CalendarBehaviorTag(rawValue: bid) {
                                    overviewBadge(tag.title, tint: .accentColor, fill: Color.accentColor.opacity(0.18))
                                }
                            }
                        }
                    }
                }
            } else {
                Text(L(.eventNotFound))
                    .foregroundStyle(.secondary)
            }
        }
    }

    var signalsQuickSection: some View {
        sectionCard(title: "Signals") {
            VStack(alignment: .leading, spacing: 14) {
                quickTagPicker(
                    title: L(.emotion),
                    tags: CalendarEmotionTag.allCases.map { (id: $0.rawValue, title: $0.title) },
                    selection: quickEmotionIDs
                ) { applyQuickTags(emotions: $0) }

                quickTagPicker(
                    title: L(.behaviorLabel),
                    tags: CalendarBehaviorTag.allCases.map { (id: $0.rawValue, title: $0.title) },
                    selection: quickBehaviorIDs
                ) { applyQuickTags(behaviors: $0) }
            }
        }
    }

    func quickTagPicker(
        title: String,
        tags: [(id: String, title: String)],
        selection: Set<String>,
        onChange: @escaping (Set<String>) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.id) { tag in
                    let selected = selection.contains(tag.id)
                    Button {
                        var next = selection
                        if selected {
                            next.remove(tag.id)
                        } else {
                            next.insert(tag.id)
                        }
                        onChange(next)
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

    func overviewBadgeRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                content()
            }
        }
    }

    func overviewBadge(_ text: String, tint: Color, fill: Color) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fill, in: Capsule())
    }

    func overviewBadgeSmall(_ text: String, tint: Color, fill: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
    }

    var detailNoteSection: some View {
        sectionCard(title: L(.note)) {
            TextEditor(text: $detailNoteText)
                .font(.subheadline)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
        }
    }

    @MainActor var detailSelectedTemplateDefinition: EventLogTemplateDefinition? {
        detailSelectedTemplateID.flatMap(EventLogTemplateRegistry.definition(for:))
    }

    var detailTemplateSection: some View {
        sectionCard(title: L(.template)) {
            VStack(alignment: .leading, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            detailSelectedTemplateID = nil
                            detailTemplateAnswers = [:]
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.secondary)
                                    .frame(width: 8, height: 8)
                                Text(L(.none))
                            }
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(detailSelectedTemplateID == nil ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.1))
                            .foregroundStyle(detailSelectedTemplateID == nil ? .primary : .secondary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(EventLogTemplateRegistry.definitions) { definition in
                            let isSelected = detailSelectedTemplateID == definition.id
                            Button {
                                detailSelectedTemplateID = definition.id
                                detailTemplateAnswers = definition.filteredAnswers(detailTemplateAnswers)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(isSelected ? Color.accentColor : Color.secondary)
                                        .frame(width: 8, height: 8)
                                    Text(definition.title)
                                }
                                .font(.caption.weight(.semibold))
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

                if let definition = detailSelectedTemplateDefinition {
                    ForEach(definition.fields) { field in
                        detailTemplateFieldView(field)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func detailTemplateFieldView(_ field: EventLogTemplateFieldDefinition) -> some View {
        switch field.kind {
        case .singleSelect:
            VStack(alignment: .leading, spacing: 8) {
                Text(field.title)
                    .font(.headline)
                FlowLayout(spacing: 6) {
                    ForEach(field.options) { option in
                        let selected = detailTemplateString(for: field.id) == option.id
                        Button {
                            if selected {
                                detailTemplateAnswers.removeValue(forKey: field.id)
                            } else {
                                detailTemplateAnswers[field.id] = .string(option.id)
                            }
                            saveDetailNoteAndTemplate()
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
                        let selected = detailTemplateStrings(for: field.id).contains(option.id)
                        Button {
                            var values = Set(detailTemplateStrings(for: field.id))
                            if selected { values.remove(option.id) } else { values.insert(option.id) }
                            let sorted = values.sorted()
                            if sorted.isEmpty {
                                detailTemplateAnswers.removeValue(forKey: field.id)
                            } else {
                                detailTemplateAnswers[field.id] = .strings(sorted)
                            }
                            saveDetailNoteAndTemplate()
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
                HStack(spacing: 8) {
                    ForEach(1...5, id: \.self) { value in
                        let isSelected = detailTemplateInt(for: field.id) == value
                        Button {
                            if isSelected {
                                detailTemplateAnswers.removeValue(forKey: field.id)
                            } else {
                                detailTemplateAnswers[field.id] = .int(value)
                            }
                            saveDetailNoteAndTemplate()
                        } label: {
                            Text("\(value)")
                                .font(.subheadline.weight(.semibold))
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
        case .shortText:
            TextField(field.placeholder ?? field.title, text: Binding(
                get: { detailTemplateString(for: field.id) ?? "" },
                set: {
                    let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        detailTemplateAnswers.removeValue(forKey: field.id)
                    } else {
                        detailTemplateAnswers[field.id] = .string($0)
                    }
                    saveDetailNoteAndTemplate()
                }
            ))
        case .longText:
            VStack(alignment: .leading, spacing: 8) {
                Text(field.title)
                    .font(.headline)
                TextEditor(text: Binding(
                    get: { detailTemplateString(for: field.id) ?? "" },
                    set: {
                        let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            detailTemplateAnswers.removeValue(forKey: field.id)
                        } else {
                            detailTemplateAnswers[field.id] = .string($0)
                        }
                        saveDetailNoteAndTemplate()
                    }
                ))
                .font(.subheadline)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
            }
        }
    }

    func detailTemplateString(for fieldID: String) -> String? {
        guard case .string(let value) = detailTemplateAnswers[fieldID] else { return nil }
        return value
    }

    func detailTemplateStrings(for fieldID: String) -> [String] {
        guard case .strings(let values) = detailTemplateAnswers[fieldID] else { return [] }
        return values
    }

    func detailTemplateInt(for fieldID: String) -> Int? {
        guard case .int(let value) = detailTemplateAnswers[fieldID] else { return nil }
        return value
    }

    var detailImagesSection: some View {
        sectionCard(title: L(.images)) {
            VStack(alignment: .leading, spacing: 8) {
                let totalCount = detailExistingImages.count + detailNewImages.count
                HStack {
                    Spacer()
                    PhotosPicker(
                        selection: $detailPickerItems,
                        maxSelectionCount: max(0, 5 - totalCount),
                        matching: .images
                    ) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                    .disabled(totalCount >= 5)
                }

                if !detailExistingImages.isEmpty || !detailNewImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(detailExistingImages) { ref in
                                DetailImageThumbnail(imageRef: ref)
                            }
                            ForEach(detailNewImages) { item in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: item.preview)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    Button {
                                        detailNewImages.removeAll { $0.id == item.id }
                                        saveDetailImages()
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
        .onChange(of: detailPickerItems.count) {
            let items = detailPickerItems
            Task { await loadDetailPickedImages(items) }
        }
    }

    func loadDetailPickedImages(_ items: [PhotosPickerItem]) async {
        defer { detailPickerItems = [] }
        let totalCount = detailExistingImages.count + detailNewImages.count
        guard totalCount < 5 else { return }
        for item in items {
            if detailExistingImages.count + detailNewImages.count >= 5 { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else { continue }
            detailNewImages.append(DetailImageDraft(id: UUID(), data: data, preview: uiImage))
        }
        saveDetailImages()
    }

    func saveDetailImages() {
        guard let event = currentEvent else { return }
        var updated = event
        var intake = updated.agenticIntake ?? AgenticIntakeRecord(rawText: "", source: .classicFallback)
        intake.images = detailExistingImages
        if !detailNewImages.isEmpty {
            let imported = detailNewImages.map { AgenticIntakeAssetStore.ImportedImage(id: $0.id, data: $0.data) }
            if let savedRefs = try? AgenticIntakeAssetStore().saveImages(imported, for: event.id) {
                intake.images.append(contentsOf: savedRefs)
            }
        }
        updated.agenticIntake = intake
        store.updateCalendarEvent(updated)
    }

    var completionQuickSection: some View {
        sectionCard(title: L(.completion)) {
            HStack(spacing: 8) {
                ForEach(EventLogCompletionStatus.allCases) { status in
                    let isSelected = (quickCompletionValue ?? .completed) == status
                    Button {
                        applyQuickCompletion(status)
                    } label: {
                        Text(status.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                isSelected ? Color.primary.opacity(0.14) : Color.secondary.opacity(0.08),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    var effortQuickSection: some View {
        sectionCard(title: L(.effort)) {
            if let event = currentEvent {
                let tint = EventTypeTemplateStore.color(for: event.type)
                let descriptor = quickEffortValue.map(calendarHumanEffortDescriptor(for:))

                AdaptivePanelPair(spacing: 12, horizontalThreshold: 380) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let descriptor {
                            Text(descriptor.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(tint)
                            Text(descriptor.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } secondary: {
                    CalendarEffortScrubber(
                        value: Binding(
                            get: { quickEffortValue },
                            set: { nextValue in
                                guard nextValue != quickEffortValue else { return }
                                applyQuickEffort(nextValue)
                            }
                        ),
                        tint: tint
                    )
                }
            } else {
                Text("Event not found.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    func intakeImagesSection(images: [AgenticIntakeImageRef]) -> some View {
        sectionCard(title: L(.images)) {
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
        sectionCard(title: L(.interruptRelation), supportingText: "How this interruption relates to the original event.") {
            if let event = currentEvent,
               let relation = event.interruptRelation {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: relationStateIcon(relation.state))
                            .font(.caption.weight(.semibold))
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
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var parallelParentEvent: Event? {
        guard let relation = currentEvent?.parallelRelation else { return nil }
        return store.findCalendarEvent(id: relation.parentEventID)
    }

    var parallelRelationSection: some View {
        sectionCard(title: "Parallel Relation", supportingText: "This event runs alongside another event.") {
            if let event = currentEvent,
               let relation = event.parallelRelation {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                        Text("Running in parallel")
                            .font(.subheadline.weight(.semibold))
                    }

                    if let parentEvent = parallelParentEvent {
                        Text(parentEvent.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Event" : parentEvent.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Original event is no longer available.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Text(interruptOccurrenceDateLabel(relation.occurrenceDate))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    var timelineSection: some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            VStack(alignment: .leading, spacing: 12) {
            if let event = currentEvent, let range = currentOccurrenceRange, !event.isAllDay {
                let notes = timelineNotes
                let interruptItems = resolvedInterruptTimelineItems(for: range)
                let parallelItems = resolvedParallelTimelineItems(for: range)
                let trackNotes = calendarEventTimelineTrackNotes(from: notes, range: range)
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    let timelineState = calendarEventTimelineResolvedState(
                        mode: timelineMode,
                        manualProgress: timelineSliderProgress,
                        now: context.date,
                        range: range
                    )
                    let mergedItems: [(id: String, date: Date, isInterrupt: Bool, isParallel: Bool, noteIndex: Int?, interruptIndex: Int?, parallelIndex: Int?)] = {
                        var items: [(id: String, date: Date, isInterrupt: Bool, isParallel: Bool, noteIndex: Int?, interruptIndex: Int?, parallelIndex: Int?)] = []
                        for (i, item) in interruptItems.enumerated() {
                            items.append((
                                id: "interrupt-\(item.id)",
                                date: item.childRange.start,
                                isInterrupt: true,
                                isParallel: false,
                                noteIndex: nil,
                                interruptIndex: i,
                                parallelIndex: nil
                            ))
                        }
                        for (i, item) in parallelItems.enumerated() {
                            items.append((
                                id: "parallel-\(item.id)",
                                date: item.childRange.start,
                                isInterrupt: false,
                                isParallel: true,
                                noteIndex: nil,
                                interruptIndex: nil,
                                parallelIndex: i
                            ))
                        }
                        for (i, note) in notes.enumerated() {
                            items.append((
                                id: "note-\(note.id)",
                                date: note.createdAt,
                                isInterrupt: false,
                                isParallel: false,
                                noteIndex: i,
                                interruptIndex: nil,
                                parallelIndex: nil
                            ))
                        }
                        return items.sorted { $0.date < $1.date }
                    }()

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L(.timeline))
                                .font(.headline)
                            Spacer()
                            HStack(spacing: 8) {
                                if timelineState.mode == .manual {
                                    Button {
                                        resumeTimelineToLive(now: context.date, range: range, animated: true)
                                    } label: {
                                        Label("Live", systemImage: "arrow.clockwise")
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Color.secondary.opacity(0.08), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }

                                Button {
                                    beginAddingTimelineNote()
                                } label: {
                                    Label(L(.addNote), systemImage: "plus")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.secondary.opacity(0.08), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(timelineEditingNoteID != nil)
                                .opacity(timelineEditingNoteID == nil ? 1 : 0.35)
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
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

                                    ForEach(interruptItems.filter { $0.childEvent.id != editingInterruptID }) { item in
                                        let tint = EventTypeTemplateStore.color(for: item.childEvent.type)
                                        if let clippedRange = item.clippedRange {
                                            let startProgress = calendarEventTimelineProgress(for: clippedRange.start, range: range)
                                            let endProgress = calendarEventTimelineProgress(for: clippedRange.end, range: range)
                                            Capsule()
                                                .fill(tint)
                                                .frame(
                                                    width: max(8, trackWidth * max(0.02, endProgress - startProgress)),
                                                    height: 4
                                                )
                                                .offset(x: trackStartX + trackWidth * startProgress)
                                        }
                                        if item.overflowsLeading {
                                            Capsule()
                                                .fill(tint.opacity(0.7))
                                                .frame(width: 5, height: 4)
                                                .offset(x: trackStartX - 1)
                                        }
                                        if item.overflowsTrailing {
                                            Capsule()
                                                .fill(tint.opacity(0.7))
                                                .frame(width: 5, height: 4)
                                                .offset(x: trackStartX + trackWidth - 4)
                                        }
                                    }

                                    ForEach(parallelItems) { item in
                                        let tint = EventTypeTemplateStore.color(for: item.childEvent.type)
                                        if let clippedRange = item.clippedRange {
                                            let startProgress = calendarEventTimelineProgress(for: clippedRange.start, range: range)
                                            let endProgress = calendarEventTimelineProgress(for: clippedRange.end, range: range)
                                            Capsule()
                                                .fill(tint.opacity(0.5))
                                                .frame(
                                                    width: max(8, trackWidth * max(0.02, endProgress - startProgress)),
                                                    height: 4
                                                )
                                                .offset(x: trackStartX + trackWidth * startProgress, y: 6)
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

                                    if timelineComposerMode != .interrupt {
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

                                    // Interrupt range preview + draggable handles
                                    if timelineComposerMode == .interrupt {
                                        let interruptTint = interruptTypeTitle.isEmpty
                                            ? Color.orange
                                            : EventTypeTemplateStore.color(for: interruptTypeTitle)

                                        // Range bar
                                        Capsule()
                                            .fill(interruptTint.opacity(0.5))
                                            .frame(
                                                width: max(8, trackWidth * max(0.02, interruptEndProgress - interruptStartProgress)),
                                                height: 6
                                            )
                                            .offset(x: trackStartX + trackWidth * interruptStartProgress)

                                        // Start handle
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(interruptTint)
                                            .overlay(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.6)).padding(3))
                                            .frame(width: 10, height: 26)
                                            .offset(x: trackStartX + trackWidth * interruptStartProgress - 5)
                                            .gesture(
                                                DragGesture(minimumDistance: 0, coordinateSpace: .named("eventTimelineTrack"))
                                                    .onChanged { value in
                                                        let raw = (value.location.x - trackStartX) / trackWidth
                                                        let clamped = max(0, min(raw, interruptEndProgress - 0.02))
                                                        interruptStartProgress = clamped
                                                    }
                                            )

                                        // End handle
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(interruptTint)
                                            .overlay(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.6)).padding(3))
                                            .frame(width: 10, height: 26)
                                            .offset(x: trackStartX + trackWidth * interruptEndProgress - 5)
                                            .gesture(
                                                DragGesture(minimumDistance: 0, coordinateSpace: .named("eventTimelineTrack"))
                                                    .onChanged { value in
                                                        let raw = (value.location.x - trackStartX) / trackWidth
                                                        let clamped = min(1.0, max(raw, interruptStartProgress + 0.02))
                                                        interruptEndProgress = clamped
                                                    }
                                            )
                                    }

                                    // Parallel range preview + draggable handles
                                    if timelineComposerMode == .parallel {
                                        let parallelTint = parallelTypeTitle.isEmpty
                                            ? Color.blue
                                            : EventTypeTemplateStore.color(for: parallelTypeTitle)

                                        Capsule()
                                            .fill(parallelTint.opacity(0.35))
                                            .frame(
                                                width: max(8, trackWidth * max(0.02, parallelEndProgress - parallelStartProgress)),
                                                height: 6
                                            )
                                            .offset(x: trackStartX + trackWidth * parallelStartProgress)

                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(parallelTint)
                                            .overlay(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.6)).padding(3))
                                            .frame(width: 10, height: 26)
                                            .offset(x: trackStartX + trackWidth * parallelStartProgress - 5)
                                            .gesture(
                                                DragGesture(minimumDistance: 0, coordinateSpace: .named("eventTimelineTrack"))
                                                    .onChanged { value in
                                                        let raw = (value.location.x - trackStartX) / trackWidth
                                                        let clamped = max(0, min(raw, parallelEndProgress - 0.02))
                                                        parallelStartProgress = clamped
                                                    }
                                            )

                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(parallelTint)
                                            .overlay(RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.6)).padding(3))
                                            .frame(width: 10, height: 26)
                                            .offset(x: trackStartX + trackWidth * parallelEndProgress - 5)
                                            .gesture(
                                                DragGesture(minimumDistance: 0, coordinateSpace: .named("eventTimelineTrack"))
                                                    .onChanged { value in
                                                        let raw = (value.location.x - trackStartX) / trackWidth
                                                        let clamped = min(1.0, max(raw, parallelStartProgress + 0.02))
                                                        parallelEndProgress = clamped
                                                    }
                                            )
                                    }
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
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        if isAddingTimelineNote && timelineComposerMode == .note {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Drop a note at \(timelineTimeLabel(timelineState.snapshotDate))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                ZStack(alignment: .topLeading) {
                                    if timelineNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Text(L(.addNote))
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

                                timelineNoteImagePreviews

                                HStack(spacing: 12) {
                                    timelineNotePhotoPicker

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
                                        .disabled(timelineNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && timelineNoteImageDrafts.isEmpty && timelineNoteExistingImages.isEmpty)
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

                        if isAddingTimelineNote && timelineComposerMode == .interrupt {
                            timelineInterruptComposer(range: range)
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .opacity
                                    )
                                )
                        }

                        if isAddingTimelineNote && timelineComposerMode == .parallel {
                            timelineParallelComposer(range: range)
                                .transition(
                                    .asymmetric(
                                        insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .opacity
                                    )
                                )
                        }

                        if mergedItems.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "waveform.path.ecg")
                                    .foregroundStyle(.secondary)
                                Text("No notes or interruptions yet.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(mergedItems, id: \.id) { merged in
                                    if merged.isInterrupt, let idx = merged.interruptIndex,
                                       interruptItems[idx].childEvent.id != editingInterruptID {
                                        let item = interruptItems[idx]
                                        let tint = EventTypeTemplateStore.color(for: item.childEvent.type)
                                        let isInterruptNearby = isInterruptNearSlider(
                                            item: item,
                                            at: timelineState.snapshotDate
                                        )

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 8) {
                                                Circle()
                                                    .fill(tint.opacity(isInterruptNearby ? 1.0 : 0.4))
                                                    .frame(width: 8, height: 8)
                                                Text(interruptTimelineSummary(item: item))
                                                    .font(.caption)
                                                    .foregroundColor(isInterruptNearby ? Color.secondary : Color.secondary.opacity(0.5))
                                            }

                                            Text(item.childEvent.title)
                                                .font(.subheadline)
                                                .foregroundColor(isInterruptNearby ? Color.primary : Color.primary.opacity(0.5))
                                                .fixedSize(horizontal: false, vertical: true)
                                                .padding(.leading, 16)
                                        }
                                        .padding(.vertical, 4)
                                        .animation(.easeInOut(duration: 0.15), value: isInterruptNearby)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            beginEditingInterrupt(item.childEvent, range: range)
                                        }
                                    } else if merged.isParallel, let idx = merged.parallelIndex {
                                        let item = parallelItems[idx]
                                        let tint = EventTypeTemplateStore.color(for: item.childEvent.type)

                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 8) {
                                                Image(systemName: "arrow.triangle.branch")
                                                    .font(.caption2)
                                                    .foregroundStyle(tint)
                                                Text("\(timelineTimeLabel(item.childRange.start)) - \(timelineTimeLabel(item.childRange.end))")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }

                                            Text(item.childEvent.title)
                                                .font(.subheadline)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .padding(.leading, 16)
                                        }
                                        .padding(.vertical, 4)
                                    } else if let idx = merged.noteIndex {
                                        let note = notes[idx]
                                        let isNearby = isNoteNearSlider(
                                            note: note,
                                            at: timelineState.snapshotDate,
                                            range: range
                                        )
                                        let isEditing = timelineEditingNoteID == note.id

                                        HStack(alignment: .top, spacing: 8) {
                                            if isEditing {
                                                Circle()
                                                    .fill(Color.primary)
                                                    .frame(width: 8, height: 8)
                                                    .padding(.top, 6)
                                            }

                                            if isEditing {
                                                VStack(alignment: .leading, spacing: 10) {
                                                    Text(timelineTimeLabel(note.createdAt))
                                                        .font(.caption.weight(.semibold).monospacedDigit())
                                                        .foregroundStyle(.secondary)

                                                    TextEditor(text: $timelineNoteText)
                                                        .font(.subheadline)
                                                        .frame(minHeight: 36, maxHeight: 80)
                                                        .scrollContentBackground(.hidden)
                                                        .focused($isTimelineNoteFieldFocused)
                                                        .onTapGesture {
                                                            noteTimelineInteraction(at: context.date)
                                                        }

                                                    timelineNoteImagePreviews

                                                    HStack(spacing: 12) {
                                                        timelineNotePhotoPicker

                                                        Button {
                                                            deleteTimelineNote(note, at: context.date)
                                                        } label: {
                                                            Image(systemName: "trash")
                                                                .font(.system(size: 15, weight: .semibold))
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
                                                            .disabled(timelineNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && timelineNoteImageDrafts.isEmpty && timelineNoteExistingImages.isEmpty)
                                                        }
                                                    }
                                                }
                                                .padding(10)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(
                                                    Color.secondary.opacity(0.1),
                                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                )
                                            } else {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    HStack(spacing: 8) {
                                                        Circle()
                                                            .fill(Color.primary.opacity(isNearby ? 0.9 : 0.35))
                                                            .frame(width: 8, height: 8)
                                                        Text(timelineTimeLabel(note.createdAt))
                                                            .font(.caption)
                                                            .foregroundColor(isNearby ? Color.secondary : Color.secondary.opacity(0.5))
                                                    }

                                                    if !note.text.isEmpty {
                                                        Text(note.text)
                                                            .font(.subheadline)
                                                            .foregroundColor(isNearby ? Color.primary : Color.primary.opacity(0.5))
                                                            .fixedSize(horizontal: false, vertical: true)
                                                            .padding(.leading, 16)
                                                    }
                                                    if !note.images.isEmpty {
                                                        ScrollView(.horizontal, showsIndicators: false) {
                                                            HStack(spacing: 4) {
                                                                ForEach(note.images) { ref in
                                                                    TimelineNoteInlineImageThumb(imageRef: ref)
                                                                }
                                                            }
                                                        }
                                                        .padding(.leading, 16)
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.vertical, 4)
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
                    }
                    .onChange(of: context.date) { _, newValue in
                        handleTimelineTick(now: newValue, range: range)
                    }
                    .onAppear {
                        handleTimelineTick(now: context.date, range: range)
                    }
                }
            } else {
                Text(L(.timeline))
                    .font(.headline)
                Text(L(.notAvailableAllDay))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            }
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

    func sectionCard<Content: View>(
        title: String,
        supportingText: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: supportingText == nil ? 0 : 4) {
                    Text(title)
                        .font(.headline)
                    if let supportingText {
                        Text(supportingText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                content()
            }
        }
    }

    func detailMetaTile<Footer: View>(
        label: String,
        value: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder footer: () -> Footer = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            footer()
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func detailPillLabel(
        _ title: String,
        tint: Color = .secondary,
        fillOpacity: Double = 0.12
    ) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(fillOpacity), in: Capsule())
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
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canDecrease)
                .opacity(canDecrease ? 1 : 0.35)

                Text(label)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 36)

                Button {
                    quickAdjustDuration(by: calendarEventQuickAdjustStepMinutes)
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }


    func openChat() {
        var occurrence = route.occurrence
        occurrence.source = .detailToolbarChat
        chatOccurrenceContext = occurrence
    }

    func loadDetailDraftIfNeeded() {
        guard !didLoadDetailDraft else { return }
        didLoadDetailDraft = true
        let draft = prefilledLogDraft
        detailNoteText = draft.note
        detailSelectedTemplateID = draft.selectedTemplateID
        detailTemplateAnswers = draft.templateAnswers
        detailExistingImages = currentEvent?.agenticIntake?.images ?? []
    }

    func saveDetailNoteAndTemplate() {
        let shouldSeedDraft = logRecord == nil
        let draft = shouldSeedDraft ? prefilledLogDraft : .empty
        let filteredAnswers = detailSelectedTemplateDefinition?.filteredAnswers(detailTemplateAnswers) ?? [:]

        store.upsertLogRecord(for: route.occurrence) { record in
            if shouldSeedDraft {
                record.selectedTemplateID = draft.selectedTemplateID?.rawValue
                record.completionStatus = draft.completionStatus
                record.actualDurationMinutes = draft.actualDurationMinutes
                record.summary = draft.summary
                record.note = draft.note
                record.effort = draft.effort
                record.emotions = draft.emotions
                record.behaviors = draft.behaviors
                record.templateAnswers = draft.templateAnswers
                record.timelineItems = draft.timelineNotes.map(EventLogTimelineItem.note)
            }
            record.note = detailNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
            record.selectedTemplateID = detailSelectedTemplateID?.rawValue
            record.templateAnswers = filteredAnswers
        }
    }

    func applyQuickTags(emotions: Set<String>? = nil, behaviors: Set<String>? = nil) {
        let shouldSeedDraft = logRecord == nil
        let draft = shouldSeedDraft ? prefilledLogDraft : .empty

        store.upsertLogRecord(for: route.occurrence) { record in
            if shouldSeedDraft {
                record.selectedTemplateID = draft.selectedTemplateID?.rawValue
                record.completionStatus = draft.completionStatus
                record.actualDurationMinutes = draft.actualDurationMinutes
                record.summary = draft.summary
                record.note = draft.note
                record.effort = draft.effort
                record.emotions = draft.emotions
                record.behaviors = draft.behaviors
                record.templateAnswers = draft.templateAnswers
                record.timelineItems = draft.timelineNotes.map(EventLogTimelineItem.note)
            }
            if let emotions {
                record.emotions = Array(emotions).sorted()
            }
            if let behaviors {
                record.behaviors = Array(behaviors).sorted()
            }
        }
    }

    func applyQuickCompletion(_ status: EventLogCompletionStatus) {
        let shouldSeedDraft = logRecord == nil
        let draft = shouldSeedDraft ? prefilledLogDraft : .empty

        store.upsertLogRecord(for: route.occurrence) { record in
            if shouldSeedDraft {
                record.selectedTemplateID = draft.selectedTemplateID?.rawValue
                record.completionStatus = draft.completionStatus
                record.actualDurationMinutes = draft.actualDurationMinutes
                record.summary = draft.summary
                record.note = draft.note
                record.effort = draft.effort
                record.emotions = draft.emotions
                record.behaviors = draft.behaviors
                record.templateAnswers = draft.templateAnswers
                record.timelineItems = draft.timelineNotes.map(EventLogTimelineItem.note)
            }
            record.completionStatus = status
        }
    }

    func applyQuickEffort(_ nextEffort: Int?) {
        let shouldSeedDraft = logRecord == nil
        let draft = shouldSeedDraft ? prefilledLogDraft : .empty

        store.upsertLogRecord(for: route.occurrence) { record in
            if shouldSeedDraft {
                record.selectedTemplateID = draft.selectedTemplateID?.rawValue
                record.completionStatus = draft.completionStatus
                record.actualDurationMinutes = draft.actualDurationMinutes
                record.summary = draft.summary
                record.note = draft.note
                record.effort = draft.effort
                record.emotions = draft.emotions
                record.behaviors = draft.behaviors
                record.templateAnswers = draft.templateAnswers
                record.timelineItems = draft.timelineNotes.map(EventLogTimelineItem.note)
            }
            record.effort = nextEffort
        }
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
        // Pick the initial page based on which target the caller asked for.
        // .meta → overview (passive read).  .log / .selfEval → reflection
        // (active recording).  Default to overview when nothing specified.
        let target: CalendarEventDetailPage
        switch route.initialJumpTarget {
        case .log, .selfEval:
            target = .reflection
        case .meta, .none:
            target = .overview
        }
        if selectedPage != target {
            selectedPage = target
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
        guard !isAddingTimelineNote || timelineEditingNoteID != nil || timelineComposerMode != .note else {
            focusTimelineNoteField()
            noteTimelineInteraction(at: now)
            return
        }
        runTimelineComposerAnimation {
            timelineComposerMode = .note
            timelineEditingNoteID = nil
            isAddingTimelineNote = true
            timelineNoteText = ""
            timelineNoteImageDrafts = []
            timelineNoteExistingImages = []
            timelineNotePickerItems = []
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
            timelineNoteImageDrafts = []
            timelineNoteExistingImages = note.images
            timelineNotePickerItems = []
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
            timelineComposerMode = .note
            timelineEditingNoteID = nil
            timelineNoteText = ""
            timelineNoteImageDrafts = []
            timelineNoteExistingImages = []
            timelineNotePickerItems = []
        }
        noteTimelineInteraction(at: now)
    }

    // MARK: - Interrupt Composer

    func beginEditingInterrupt(_ interrupt: Event, range parentRange: Event.TimeRange) {
        let duration = parentRange.end.timeIntervalSince(parentRange.start)
        guard duration > 0, let childRange = interrupt.primaryTimeRange else { return }

        editingInterruptID = interrupt.id
        timelineComposerMode = .interrupt
        interruptTitle = interrupt.title
        interruptTypeTitle = interrupt.type
        interruptNoteText = interrupt.note
        interruptDidExplicitlySelectType = true

        let startP = childRange.start.timeIntervalSince(parentRange.start) / duration
        let endP = childRange.end.timeIntervalSince(parentRange.start) / duration
        interruptStartProgress = CGFloat(max(0, min(1, startP)))
        interruptEndProgress = CGFloat(max(0, min(1, endP)))

        runTimelineComposerAnimation {
            isAddingTimelineNote = true
        }
    }

    func cancelInterruptComposer() {
        interruptAutoTypeTask?.cancel()
        runTimelineComposerAnimation {
            isAddingTimelineNote = false
            timelineComposerMode = .note
            editingInterruptID = nil
            interruptTitle = ""
            interruptTypeTitle = ""
            interruptNoteText = ""
            interruptDidExplicitlySelectType = false
        }
    }

    private func scheduleInterruptAutoTypeSelection() {
        interruptAutoTypeTask?.cancel()
        guard !interruptDidExplicitlySelectType else { return }

        let rawText = calendarTypeSuggestionRawText(title: interruptTitle, note: "")
        let availableTypes = interruptTemplateStore.templates.map(\.title)
        let currentType = interruptTypeTitle
        let historicalEvents = store.calendarEvents

        interruptAutoTypeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, !interruptDidExplicitlySelectType else { return }

            if let suggestion = calendarPreferredLocalTypeSuggestion(
                rawText: rawText,
                availableTypes: availableTypes,
                historicalEvents: historicalEvents
            ), suggestion.typeTitle != currentType {
                interruptTypeTitle = suggestion.typeTitle
            }
        }
    }

    func saveInterrupt() {
        guard let event = currentEvent, let range = currentOccurrenceRange else { return }
        let title = interruptTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = title.isEmpty ? "Interrupt" : title
        let type = interruptTypeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = interruptNoteText.trimmingCharacters(in: .whitespacesAndNewlines)

        let startDate = range.start.addingTimeInterval(
            range.end.timeIntervalSince(range.start) * Double(interruptStartProgress)
        )
        let endDate = range.start.addingTimeInterval(
            range.end.timeIntervalSince(range.start) * Double(interruptEndProgress)
        )
        let timeRange = Event.TimeRange(start: startDate, end: endDate)

        let resultEvent: Event

        if let editID = editingInterruptID,
           var existing = store.findCalendarEvent(id: editID) {
            // Update existing interrupt
            existing.title = resolvedTitle
            existing.type = type
            existing.note = trimmedNote
            existing.timeRanges = [timeRange]
            store.updateCalendarEvent(existing)
            resultEvent = existing
        } else {
            // Create new interrupt
            guard let created = store.createInterrupt(
                parentEvent: event,
                occurrenceDate: route.occurrence.occurrenceDate,
                title: resolvedTitle,
                type: type,
                timeRange: timeRange
            ) else {
                cancelInterruptComposer()
                return
            }
            if !trimmedNote.isEmpty {
                var updated = created
                updated.note = trimmedNote
                store.updateCalendarEvent(updated)
            }
            resultEvent = store.findCalendarEvent(id: created.id) ?? created
        }

        // Post-save type inference (same as normal event creation)
        if !interruptDidExplicitlySelectType {
            let form = CalendarEventFormData(
                title: resultEvent.title,
                typeTitle: resultEvent.type,
                note: resultEvent.note,
                location: resultEvent.location,
                startTime: timeRange.start,
                endTime: timeRange.end,
                isAllDay: false,
                repeatUnit: .none,
                repeatInterval: 1,
                repeatEndType: .none,
                repeatEndDate: nil,
                repeatEndCount: nil,
                didExplicitlySelectType: false
            )
            Task { @MainActor in
                await CalendarEventTypeInferenceService().inferTypeIfNeeded(
                    for: resultEvent,
                    savedForm: form,
                    isSuggestionEnabled: true,
                    store: store
                )
            }
        }

        cancelInterruptComposer()
    }

    private func interruptTimeRange(for range: Event.TimeRange) -> Event.TimeRange {
        let duration = range.end.timeIntervalSince(range.start)
        let startDate = range.start.addingTimeInterval(duration * Double(interruptStartProgress))
        let endDate = range.start.addingTimeInterval(duration * Double(interruptEndProgress))
        return Event.TimeRange(start: startDate, end: endDate)
    }

    @ViewBuilder
    func timelineInterruptComposer(range: Event.TimeRange) -> some View {
        let iRange = interruptTimeRange(for: range)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.caption2.weight(.semibold))
                Text("\(editingInterruptID != nil ? "Edit" : "New") interrupt \(timelineTimeLabel(iRange.start)) – \(timelineTimeLabel(iRange.end))")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            TextField("Title", text: $interruptTitle)
                .font(.subheadline.weight(.semibold))
                .textFieldStyle(.plain)
                .onChange(of: interruptTitle) {
                    scheduleInterruptAutoTypeSelection()
                }

            ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(interruptTemplateStore.templates) { template in
                        let selected = interruptTypeTitle == template.title
                        Button {
                            interruptTypeTitle = template.title
                            interruptDidExplicitlySelectType = true
                        } label: {
                            let textColor: Color = selected ? .primary : .primary.opacity(0.6)
                            let bgColor: Color = selected ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.08)
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(ColorHex.toColor(template.colorHex))
                                    .frame(width: 6, height: 6)
                                Text(template.title)
                                    .fixedSize()
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(bgColor)
                            .foregroundStyle(textColor)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(template.title)
                    }
                }
            }
            .onChange(of: interruptTypeTitle) {
                withAnimation {
                    scrollProxy.scrollTo(interruptTypeTitle, anchor: .center)
                }
            }
            }

            ZStack(alignment: .topLeading) {
                if interruptNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Note (optional)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $interruptNoteText)
                    .font(.caption)
                    .frame(minHeight: 28, maxHeight: 60)
                    .scrollContentBackground(.hidden)
            }

            HStack {
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        cancelInterruptComposer()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        saveInterrupt()
                    } label: {
                        Image(systemName: editingInterruptID != nil ? "checkmark.circle.fill" : "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Parallel Composer

    func cancelParallelComposer() {
        parallelAutoTypeTask?.cancel()
        runTimelineComposerAnimation {
            isAddingTimelineNote = false
            timelineComposerMode = .note
            parallelTitle = ""
            parallelTypeTitle = ""
            parallelNoteText = ""
            parallelDidExplicitlySelectType = false
        }
    }

    func saveParallel() {
        guard let parentEvent = currentEvent, let range = currentOccurrenceRange else { return }
        let title = parallelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let type = parallelTypeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = parallelNoteText.trimmingCharacters(in: .whitespacesAndNewlines)

        let duration = range.end.timeIntervalSince(range.start)
        let startDate = range.start.addingTimeInterval(duration * Double(parallelStartProgress))
        let endDate = range.start.addingTimeInterval(duration * Double(parallelEndProgress))
        let timeRange = Event.TimeRange(start: startDate, end: endDate)

        let relation = EventParallelRelation(
            parentEventID: parentEvent.id,
            baseSeriesEventID: parentEvent.recurrenceParentId,
            occurrenceDate: route.occurrence.occurrenceDate,
            createdAt: timeRange.start
        )

        let event = Event(
            title: title,
            note: trimmedNote,
            location: "",
            timeRanges: [timeRange],
            type: type.isEmpty ? parentEvent.type : type,
            displayKind: .parallel,
            parallelRelation: relation
        )
        store.addCalendarEvent(event)

        // Add parallel reference to parent event's log record
        let occurrence = route.occurrence
        store.upsertLogRecord(for: occurrence) { record in
            if !record.timelineItems.contains(where: { $0.parallelReferenceValue?.childEventID == event.id }) {
                record.timelineItems.append(
                    .parallelRef(
                        EventLogParallelReference(
                            childEventID: event.id,
                            createdAt: timeRange.start
                        )
                    )
                )
                record.timelineItems.sort { $0.createdAt > $1.createdAt }
            }
        }

        // Post-save type inference
        if !parallelDidExplicitlySelectType {
            let form = CalendarEventFormData(
                title: event.title,
                typeTitle: event.type,
                note: event.note,
                location: event.location,
                startTime: timeRange.start,
                endTime: timeRange.end,
                isAllDay: false,
                repeatUnit: .none,
                repeatInterval: 1,
                repeatEndType: .none,
                repeatEndDate: nil,
                repeatEndCount: nil,
                didExplicitlySelectType: false
            )
            Task { @MainActor in
                await CalendarEventTypeInferenceService().inferTypeIfNeeded(
                    for: event,
                    savedForm: form,
                    isSuggestionEnabled: true,
                    store: store
                )
            }
        }

        cancelParallelComposer()
    }

    private func scheduleParallelAutoTypeSelection() {
        parallelAutoTypeTask?.cancel()
        guard !parallelDidExplicitlySelectType else { return }

        let rawText = calendarTypeSuggestionRawText(title: parallelTitle, note: "")
        let availableTypes = interruptTemplateStore.templates.map(\.title)
        let currentType = parallelTypeTitle
        let historicalEvents = store.calendarEvents

        parallelAutoTypeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, !parallelDidExplicitlySelectType else { return }

            if let suggestion = calendarPreferredLocalTypeSuggestion(
                rawText: rawText,
                availableTypes: availableTypes,
                historicalEvents: historicalEvents
            ), suggestion.typeTitle != currentType {
                parallelTypeTitle = suggestion.typeTitle
            }
        }
    }

    private func parallelTimeRange(for range: Event.TimeRange) -> Event.TimeRange {
        let duration = range.end.timeIntervalSince(range.start)
        let startDate = range.start.addingTimeInterval(duration * Double(parallelStartProgress))
        let endDate = range.start.addingTimeInterval(duration * Double(parallelEndProgress))
        return Event.TimeRange(start: startDate, end: endDate)
    }

    @ViewBuilder
    func timelineParallelComposer(range: Event.TimeRange) -> some View {
        let pRange = parallelTimeRange(for: range)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2.weight(.semibold))
                Text("Parallel \(timelineTimeLabel(pRange.start)) – \(timelineTimeLabel(pRange.end))")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)

            TextField("Title", text: $parallelTitle)
                .font(.subheadline.weight(.semibold))
                .textFieldStyle(.plain)
                .onChange(of: parallelTitle) {
                    scheduleParallelAutoTypeSelection()
                }

            ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(interruptTemplateStore.templates) { template in
                        let selected = parallelTypeTitle == template.title
                        Button {
                            parallelTypeTitle = template.title
                            parallelDidExplicitlySelectType = true
                        } label: {
                            let textColor: Color = selected ? .primary : .primary.opacity(0.6)
                            let bgColor: Color = selected ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.08)
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(ColorHex.toColor(template.colorHex))
                                    .frame(width: 6, height: 6)
                                Text(template.title)
                                    .fixedSize()
                            }
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(bgColor)
                            .foregroundStyle(textColor)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id("parallel-\(template.title)")
                    }
                }
            }
            .onChange(of: parallelTypeTitle) {
                withAnimation {
                    scrollProxy.scrollTo("parallel-\(parallelTypeTitle)", anchor: .center)
                }
            }
            }

            ZStack(alignment: .topLeading) {
                if parallelNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Note (optional)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $parallelNoteText)
                    .font(.caption)
                    .frame(minHeight: 28, maxHeight: 60)
                    .scrollContentBackground(.hidden)
            }

            HStack {
                Spacer()
                HStack(spacing: 10) {
                    Button {
                        cancelParallelComposer()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        saveParallel()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(parallelTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    func saveTimelineNote(at date: Date) {
        let trimmed = timelineNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !timelineNoteImageDrafts.isEmpty || !timelineNoteExistingImages.isEmpty else { return }

        var savedImages = timelineNoteExistingImages
        if !timelineNoteImageDrafts.isEmpty, let event = currentEvent {
            let imported = timelineNoteImageDrafts.map { AgenticIntakeAssetStore.ImportedImage(id: $0.id, data: $0.data) }
            if let refs = try? AgenticIntakeAssetStore().saveImages(imported, for: event.id) {
                savedImages.append(contentsOf: refs)
            }
        }

        if let timelineEditingNoteID {
            store.updateTimelineNote(
                timelineEditingNoteID,
                text: trimmed,
                images: savedImages,
                for: route.occurrence
            )
        } else {
            store.appendTimelineNote(
                trimmed,
                createdAt: date,
                source: "detailTimeline",
                images: savedImages,
                for: route.occurrence
            )
        }
        cancelTimelineNoteComposer()
    }

    var timelineNotePhotoPicker: some View {
        let totalCount = timelineNoteExistingImages.count + timelineNoteImageDrafts.count
        return PhotosPicker(
            selection: $timelineNotePickerItems,
            maxSelectionCount: max(0, 5 - totalCount),
            matching: .images
        ) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(totalCount >= 5)
        .opacity(totalCount >= 5 ? 0.35 : 1)
        .onChange(of: timelineNotePickerItems.count) {
            let items = timelineNotePickerItems
            Task { await loadTimelineNotePickedImages(items) }
        }
    }

    @ViewBuilder
    var timelineNoteImagePreviews: some View {
        let hasImages = !timelineNoteExistingImages.isEmpty || !timelineNoteImageDrafts.isEmpty
        if hasImages {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(timelineNoteExistingImages) { ref in
                        TimelineNoteExistingImageThumb(imageRef: ref) {
                            timelineNoteExistingImages.removeAll { $0.id == ref.id }
                        }
                    }
                    ForEach(timelineNoteImageDrafts) { draft in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: draft.preview)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Button {
                                timelineNoteImageDrafts.removeAll { $0.id == draft.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.white, .black.opacity(0.5))
                            }
                            .offset(x: 4, y: -4)
                        }
                    }
                }
            }
        }
    }

    func loadTimelineNotePickedImages(_ items: [PhotosPickerItem]) async {
        defer { timelineNotePickerItems = [] }
        let totalCount = timelineNoteExistingImages.count + timelineNoteImageDrafts.count
        guard totalCount < 5 else { return }
        for item in items {
            if timelineNoteExistingImages.count + timelineNoteImageDrafts.count >= 5 { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else { continue }
            timelineNoteImageDrafts.append(TimelineNoteImageDraft(id: UUID(), data: data, preview: uiImage))
        }
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
        if AppTimeFormat.current.is24 {
            timeFormatter.dateFormat = "H:mm"
        } else {
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.dateFormat = "h:mm a"
            timeFormatter.amSymbol = "am"
            timeFormatter.pmSymbol = "pm"
        }
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
        if AppTimeFormat.current.is24 {
            formatter.dateFormat = "H:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
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

    func isInterruptNearSlider(item: CalendarResolvedInterruptTimelineItem, at selectedDate: Date) -> Bool {
        let childRange = item.childRange
        return selectedDate >= childRange.start && selectedDate <= childRange.end
            || abs(childRange.start.timeIntervalSince(selectedDate)) <= 120
            || abs(childRange.end.timeIntervalSince(selectedDate)) <= 120
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

    func resolvedParallelTimelineItems(
        for range: Event.TimeRange
    ) -> [CalendarResolvedParallelTimelineItem] {
        (logRecord?.timelineItems ?? [])
            .compactMap(\.parallelReferenceValue)
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
                return CalendarResolvedParallelTimelineItem(
                    reference: reference,
                    childEvent: childEvent,
                    childRange: childRange,
                    clippedRange: clippedRange
                )
            }
            .sorted { $0.childRange.start < $1.childRange.start }
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
    @State private var showFullScreen = false

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
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            if image != nil { showFullScreen = true }
        }
        .onAppear {
            if image == nil {
                image = AgenticIntakeAssetStore().loadImage(for: imageRef)
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let image {
                ImageFullScreenViewer(image: image) { showFullScreen = false }
            }
        }
    }
}

private struct TimelineNoteExistingImageThumb: View {
    let imageRef: AgenticIntakeImageRef
    let onRemove: () -> Void
    @State private var image: UIImage?
    @State private var showFullScreen = false

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
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture {
                if image != nil { showFullScreen = true }
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .offset(x: 4, y: -4)
        }
        .onAppear {
            if image == nil {
                image = AgenticIntakeAssetStore().loadImage(for: imageRef)
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let image {
                ImageFullScreenViewer(image: image) { showFullScreen = false }
            }
        }
    }
}

private struct TimelineNoteInlineImageThumb: View {
    let imageRef: AgenticIntakeImageRef
    @State private var image: UIImage?
    @State private var showFullScreen = false

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
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onTapGesture {
            if image != nil { showFullScreen = true }
        }
        .onAppear {
            if image == nil {
                image = AgenticIntakeAssetStore().loadImage(for: imageRef)
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            if let image {
                ImageFullScreenViewer(image: image) { showFullScreen = false }
            }
        }
    }
}

private struct ImageFullScreenViewer: View {
    let image: UIImage
    let onDismiss: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1, min(5, lastScale * value))
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale <= 1 {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        scale = 1
                                        offset = .zero
                                        lastOffset = .zero
                                    }
                                    lastScale = 1
                                }
                            },
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if scale > 1 {
                            scale = 1
                            offset = .zero
                            lastOffset = .zero
                            lastScale = 1
                        } else {
                            scale = 2
                            lastScale = 2
                        }
                    }
                }
                .onTapGesture {
                    onDismiss()
                }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.5))
                            .padding()
                    }
                }
                Spacer()
            }
        }
        .statusBarHidden()
    }
}

// MARK: - Multi-type stacked cards (experimental)
//
// Renders the event's types as a stack of cards on the Reflection page:
// the primary card is full-size and on top, secondary types are thinner
// indented rows beneath. Tap a secondary row to promote it to primary;
// long-press for a context menu with promote/remove. The "+ add" chip row
// at the bottom appends new types up to the configured max.
//
// Weights are deliberately not surfaced in this UI — they remain on the
// `Event` record (`typeWeights`) for downstream consumers but the user
// only manipulates the type *list* and its order.

private extension CalendarEventDetailView {

    var multiTypeStackedCardsSection: some View {
        sectionCard(
            title: "Parallel types",
            supportingText: "Top card is the primary type. Tap a card to make it primary."
        ) {
            if let event = currentEvent {
                let types = event.effectiveTypes
                VStack(alignment: .leading, spacing: 10) {
                    multiTypePrimaryCard(name: types.first ?? "", event: event)

                    if types.count > 1 {
                        VStack(spacing: 6) {
                            ForEach(Array(types.dropFirst().enumerated()), id: \.element) { offset, name in
                                multiTypeSecondaryRow(
                                    name: name,
                                    indentDepth: offset,
                                    event: event
                                )
                            }
                        }
                    }

                    if canAddMoreMultiTypes(to: event) {
                        multiTypeAddChipRow(event: event)
                    }
                }
            }
        }
    }

    func multiTypePrimaryCard(name: String, event: Event) -> some View {
        let color = EventTypeTemplateStore.color(for: name)
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Untitled" : name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("primary")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }

    func multiTypeSecondaryRow(name: String, indentDepth: Int, event: Event) -> some View {
        let color = EventTypeTemplateStore.color(for: name)
        let indent = CGFloat(min(indentDepth, 3)) * 8
        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 4)
            Text(name)
                .font(.footnote)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .padding(.leading, indent)
        .padding(.trailing, indent)
        .contentShape(Rectangle())
        .onTapGesture {
            promoteMultiType(name: name, in: event)
        }
        .contextMenu {
            Button {
                promoteMultiType(name: name, in: event)
            } label: {
                Label("Make primary", systemImage: "arrow.up.circle")
            }
            Button(role: .destructive) {
                removeMultiType(name: name, in: event)
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
        }
    }

    func multiTypeAddChipRow(event: Event) -> some View {
        let alreadyUsed = Set(event.effectiveTypes.map {
            EventTypeTemplateStore.normalizedTitle($0)
        })
        let available = multiTypeTemplateStore.templates.filter { template in
            !alreadyUsed.contains(EventTypeTemplateStore.normalizedTitle(template.title))
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(available) { template in
                    Button {
                        addMultiType(name: template.title, in: event)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.caption2.weight(.bold))
                            Circle()
                                .fill(ColorHex.toColor(template.colorHex))
                                .frame(width: 8, height: 8)
                            Text(template.title)
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    var clampedMultiTypeMaxCount: Int {
        let raw = experimentalMultiTypeMaxCount == 0 ? 2 : experimentalMultiTypeMaxCount
        return max(2, min(4, raw))
    }

    func canAddMoreMultiTypes(to event: Event) -> Bool {
        event.effectiveTypes.count < clampedMultiTypeMaxCount
    }

    func addMultiType(name: String, in event: Event) {
        guard canAddMoreMultiTypes(to: event) else { return }
        var updated = event
        updated.appendAdditionalType(name)
        store.updateCalendarEvent(updated)
    }

    func removeMultiType(name: String, in event: Event) {
        var updated = event
        updated.removeType(name)
        store.updateCalendarEvent(updated)
    }

    func promoteMultiType(name: String, in event: Event) {
        var updated = event
        updated.promoteTypeToPrimary(name)
        store.updateCalendarEvent(updated)
    }
}

// MARK: - Detail Header Settings

struct DetailHeaderSettingsView: View {
    @AppStorage(AppSettingsKeys.detailHeaderExposedTools) private var exposedToolsRaw = "add"

    private var exposedTools: Set<DetailHeaderTool> {
        detailHeaderExposedTools(from: exposedToolsRaw)
    }

    private func toggleTool(_ tool: DetailHeaderTool) {
        var current = exposedTools
        if current.contains(tool) {
            current.remove(tool)
        } else {
            current.insert(tool)
        }
        exposedToolsRaw = detailHeaderExposedToolsString(from: current)
    }

    var body: some View {
        Form {
            Section {
                ForEach(DetailHeaderTool.allCases) { tool in
                    Toggle(isOn: Binding(
                        get: { exposedTools.contains(tool) },
                        set: { _ in toggleTool(tool) }
                    )) {
                        Label(tool.label, systemImage: tool.icon)
                    }
                }
            } header: {
                Text("Detail Tools")
            } footer: {
                Text("Enabled tools appear directly in the detail header bar. Disabled tools are placed in the \u{2026} menu.")
            }
        }
        .navigationTitle("Event Detail")
    }
}
