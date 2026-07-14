//
//  ContentView.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import SwiftUI
import Combine

enum RootTab: String, CaseIterable, Identifiable {
    case wanna
    case calendar
    case report
    case me

    var id: String { rawValue }

    var titleKey: LKey {
        switch self {
        case .wanna:    return .tabWanna
        case .calendar: return .tabCalendar
        case .report:   return .tabReport
        case .me:       return .tabMe
        }
    }
}

enum AppSettingsKeys {
    static let rememberLastTab = "generalRememberLastTab"
    static let appearanceMode = "generalAppearanceMode"
    static let defaultTab = "generalDefaultTab"
    static let lastSelectedTab = "generalLastSelectedTab"
    static let showTimerBanner = "generalShowTimerBanner"
    static let landscapeFocusMode = "workflowEnableLandscapeFocusMode"
    static let landscapeFocusKeepAwake = "workflowLandscapeFocusKeepAwake"
    static let analysisDefaultPeriod = "analysisDefaultPeriod"
    static let analysisAutoLoadSuggestions = "analysisAutoLoadSuggestions"
    /// When true, calendar event blocks are rendered with effort-based
    /// opacity: events without an effort log are drawn at medium opacity
    /// (~0.7), high-effort events are fully opaque, low-effort events are
    /// more transparent.  When false, all events render at full opacity.
    static let effortOpacityEnabled = "calendarEffortOpacityEnabled"
    /// Experimental: when ON, events can carry more than one event type and
    /// the calendar block color is a perceptual blend of those types' colors.
    /// This is a Labs feature; data is preserved when toggled off.
    static let experimentalMultiTypeEvents = "experimentalMultiTypeEvents"
    /// Experimental: maximum number of types (including the primary) allowed
    /// when `experimentalMultiTypeEvents` is on. Range 2...4.
    static let experimentalMultiTypeMaxCount = "experimentalMultiTypeMaxCount"

    /// Comma-separated list of header tool IDs to show exposed (not in "..." menu).
    /// Available IDs: "create", "search", "agent"
    /// Default: "create" (only create button exposed, rest in menu)
    static let calendarHeaderExposedTools = "calendarHeaderExposedTools"
    /// Comma-separated list of detail header tool IDs to show exposed.
    /// Available IDs: "add", "chat", "edit", "delete"
    /// Default: "add" (only add button exposed, rest in menu)
    static let detailHeaderExposedTools = "detailHeaderExposedTools"
    /// Persisted calendar view mode (day/threeDay/week).
    static let calendarLastRangeMode = "calendarLastRangeMode"
    /// Whether to restore the last used view mode on launch.
    static let calendarRememberViewMode = "calendarRememberViewMode"
    /// When true, returning to the calendar tab resets to today's date.
    static let calendarAutoReturnToToday = "calendarAutoReturnToToday"
    /// When true, the Chinese 24 solar terms (二十四节气) are shown as
    /// lightweight labels on calendar dates. Default ON.
    static let holidaysShowSolarTerms = "calendarHolidaysShowSolarTerms"
    /// When true, common Gregorian-fixed holidays (元旦/劳动节/国庆节 …) are
    /// shown as lightweight labels on calendar dates. Default ON.
    static let holidaysShowGregorianHolidays = "calendarHolidaysShowGregorianHolidays"
    /// User-defined anniversaries, persisted as a JSON array string of
    /// `CustomAnniversary`. Shown as lightweight labels on their yearly
    /// month/day, like holidays. See `CalendarAnnotation.swift`.
    static let customAnniversaries = "calendarCustomAnniversaries"
    /// Comma-separated achievement IDs whose unlock has already been
    /// celebrated (confetti shown), so we only celebrate each badge once.
    static let celebratedAchievements = "meCelebratedAchievements"
    /// Cached AI-generated personality profile (JSON of `PersonalityProfile`),
    /// regenerated only on explicit refresh so we don't burn tokens per render.
    static let personalityProfile = "mePersonalityProfile"
    /// Time-capsule letters to the user's future self (JSON array of
    /// `TimeCapsuleLetter`); hidden until each one's reveal date.
    static let timeCapsules = "meTimeCapsules"
    /// Whether the celebrated-achievements set has been seeded on first run.
    /// Prevents a confetti storm for badges earned before this feature shipped.
    static let achievementCelebrationSeeded = "meAchievementCelebrationSeeded"
    /// When true, drag-to-create snaps the new event's start/end to nearby
    /// existing event edges within an 8pt magnetic threshold. Designed for
    /// users who keep continuous back-to-back records; users who log
    /// non-aligned moments should turn it off.
    static let calendarAdjacentEventSnapEnabled = "calendarAdjacentEventSnapEnabled"
    /// Title font size (in points) used for text inside calendar event
    /// blocks. Time-range font scales proportionally. Default 12 matches
    /// the historical hard-coded value; clamped to 9...16 in the UI.
    static let calendarEventFontSize = "calendarEventFontSize"
    /// When true, the event time range renders below the title in event
    /// blocks whenever it geometrically fits. When false, time only shows
    /// in tall blocks (the legacy 88x42pt gate).
    static let calendarEventShowTimeBelowTitle = "calendarEventShowTimeBelowTitle"
    /// Number of days into the future that defines the "near future" zone —
    /// the user's processing capacity beyond NOW. Items inside this window
    /// are user-controlled (system never mutates their date); items beyond
    /// are in the "future" zone and subject to HORIZON-driven domino push-
    /// back when the horizon advances. Default 7. See `EventZone`.
    static let nearFutureHorizonDays = "calendarNearFutureHorizonDays"
    /// When true, tapping a type pill from focus mode's idle clock surfaces
    /// a brief preview ("entry ceremony") before creating the event — title
    /// can be edited, range can be confirmed, and the user crosses into the
    /// inhabiting state deliberately. When false, the type tap creates the
    /// event immediately (quick path).
    static let focusConfirmBeforeTracking = "focusConfirmBeforeTracking"
    /// Experimental: when true, the time axis (hour labels + now-time legend
    /// + drag-preview pills) is rendered through a CALayer-backed UIView
    /// instead of the SwiftUI `TimeAxisLabels` tree. Strictly parity-first;
    /// the SwiftUI path remains the default until A/B verification settles.
    /// See `TimeAxisLayerView.swift` (issue #60).
    static let calendarUseCALayerAxisMarkers = "calendarUseCALayerAxisMarkers"
    /// Experimental: when true, the event-detail mini-day timeline
    /// (`miniDayTimelineVisual` in `CalendarEventDetailView`) is rendered
    /// through a CALayer-backed UIView instead of the SwiftUI tree. Same
    /// strict-parity stance as `calendarUseCALayerAxisMarkers`; the SwiftUI
    /// path remains the default until A/B verification settles. See
    /// `MiniDayTimelineLayerView.swift` (issue #71).
    static let calendarUseCALayerMiniDayTimeline = "calendarUseCALayerMiniDayTimeline"
    /// Experimental: when true, the calendar's vertical timeline scroll
    /// uses a `UIScrollView`-backed host (`TimelineScrollHost`) instead of
    /// the SwiftUI `ScrollView`. The new host can atomically co-commit
    /// `contentSize` + `contentOffset` in a single `CATransaction`, so the
    /// boundary-extension close path (today covered by the
    /// `timelineCollapseDim` opacity dip) collapses without a 1-frame
    /// layout flash. Strict parity, default OFF until on-device A/B
    /// settles. See `TimelineScrollHost.swift` (issue #57).
    static let calendarUseUIScrollViewTimeline = "calendarUseUIScrollViewTimeline"

    /// Issue #57 / spec 07: when ON (and the UIScrollView timeline is also ON),
    /// single-day mode drives the day-layer with a 48h-CONSTANT coordinate
    /// model (12h leading + 24h + 12h trailing). Band open/close mutates only
    /// `contentInset`, never `contentSize` — removing the two-write-surface
    /// race the co-commit path papers over. The all-day pill row is pinned to
    /// the scroll frame top so the negative leading inset can hide the band
    /// without scrolling the pills off. Strict-parity, default OFF until
    /// on-device A/B settles. See `docs/calayer-rewrite/07-day-layer-imperative.md`.
    static let calendarUseImperativeDayLayer = "calendarUseImperativeDayLayer"

    // MARK: - Agent / LLM

    static let agentProvider = "agentProvider"
    static let agentAPIKey = "agentAPIKey"
    static let agentAskBeforeCreatingEventTypeTemplates = "agentAskBeforeCreatingEventTypeTemplates"
    /// When true, calendar forms can preselect a type while typing using
    /// existing event history and local heuristics, then ask AI after save.
    static let calendarAgenticCreateEnabled = "calendarAgenticCreateEnabled"
    /// Default LLM provider used by every service-layer read.
    static let agentProviderDefault = "claude"
    /// Experimental: when ON, the token-inference engine (hypothesis OS,
    /// Discussion #111) runs its LLM loop on every calendar event add/edit and
    /// log/feedback save. Default OFF: the engine's output currently has no UI
    /// surface (`TokenAnalysisAssembler.build` has no callers), while the loop
    /// was the dominant share of API spend — one agentic run per upcoming
    /// occurrence per event mutation. Deterministic bootstrap projections are
    /// still written when OFF, so learned-state sync/restore keep working.
    static let tokenInferenceLLMEnabled = "agentTokenInferenceLLMEnabled"

    // MARK: - MCP

    /// Permanent MCP connector URL (with token) that lets external AI apps
    /// read this user's Done data.
    static let mcpURL = "mcpURL"

    // MARK: - Me profile

    static let meDisplayName = "meDisplayName"
    static let meAvatarHue = "meAvatarHue"
    /// Cache-buster bumped after each avatar image save so views that load
    /// `MeAvatarStore.load()` refresh without a stored equality check.
    static let meAvatarVersion = "meAvatarVersion"
    /// Comma-separated list of type names treated as background time
    /// (sleep / meals / commute) — counted in totals but excluded from
    /// identity visuals on the Me tab.
    static let meBackgroundTypes = "meBackgroundTypes"
    /// Multi-line free-form reflection log persisted across launches.
    static let meReflectionLog = "meReflectionLog"
    /// Default background-types list when the user hasn't customized one.
    /// Mixes EN/中 names to cover both interface languages out of the box.
    static let meBackgroundTypesDefault = "Sleep,睡眠,睡觉,Rest,Eat,Meal,吃饭,Commute,Transit,通勤"

    // MARK: - Calendar share

    /// Raw value of `CalendarDailyShareStyle` chosen most recently from the
    /// daily share sheet.
    static let calendarShareStyle = "calendarShareStyle"

    // MARK: - Sync upload gate

    /// User-controlled gate: when ON, this device pushes local changes to
    /// Supabase. When OFF, the device only reads (restore still works) and
    /// nothing is uploaded. Defaults to OFF so a fresh install on a new
    /// device doesn't surprise-write the user's cloud data. Independent of
    /// the DEBUG safety net, which always blocks uploads regardless.
    ///
    /// **DO NOT add to `SyncedSettings.allKeys`.** This key is per-device by
    /// design — syncing it to the cloud would let one device override another
    /// device's upload preference, which defeats the whole point of the toggle.
    static let syncUploadsEnabled = "syncUploadsEnabled"

    static let resettableUserDefaultsKeys: [String] = [
        agentProvider,
        agentAPIKey,
        calendarAgenticCreateEnabled,
        agentAskBeforeCreatingEventTypeTemplates,
        rememberLastTab,
        appearanceMode,
        defaultTab,
        lastSelectedTab,
        showTimerBanner,
        landscapeFocusMode,
        landscapeFocusKeepAwake,
        analysisDefaultPeriod,
        analysisAutoLoadSuggestions,
        effortOpacityEnabled,
        experimentalMultiTypeEvents,
        experimentalMultiTypeMaxCount,
        calendarAdjacentEventSnapEnabled,
        calendarEventFontSize,
        calendarEventShowTimeBelowTitle,
        nearFutureHorizonDays,
        focusConfirmBeforeTracking,
        calendarUseCALayerMiniDayTimeline,
        calendarUseUIScrollViewTimeline,
        calendarUseImperativeDayLayer
    ]
}

/// App-wide light/dark override. `.system` defers to the OS setting; the
/// other two force a scheme via `.preferredColorScheme` at the app root.
/// Backed by `AppSettingsKeys.appearanceMode`.
enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var titleKey: LKey {
        switch self {
        case .system: return .appearanceSystem
        case .light:  return .appearanceLight
        case .dark:   return .appearanceDark
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var orientationManager: OrientationManager
    @AppStorage(AppSettingsKeys.rememberLastTab) private var rememberLastTab = true
    @AppStorage(AppSettingsKeys.defaultTab) private var defaultTabRawValue = RootTab.calendar.rawValue
    @AppStorage(AppSettingsKeys.lastSelectedTab) private var lastSelectedTabRawValue = RootTab.calendar.rawValue
    @AppStorage(AppSettingsKeys.showTimerBanner) private var showTimerBanner = true
    @State private var calendarState = CalendarViewState()
    @StateObject private var calendarFocusState = CalendarFocusState()
    @State private var savedDayOffsetBeforeLandscape: Int?
    @State private var calendarDayOffsetUnfreezeTask: Task<Void, Never>?
    /// Tracks the wall-clock start-of-day so a midnight crossing during
    /// landscape can shift `savedDayOffsetBeforeLandscape` in lockstep with
    /// `calendarState.selectedDayOffset` (shifted by CalendarPageView's own
    /// midnight handler).  Without this, rotating back to portrait after
    /// midnight would restore an off-by-one offset.
    @State private var midnightLastKnownStartOfDay: Date = Calendar.current.startOfDay(for: Date())
    @StateObject private var skillInsightStore = SkillInsightStore()
    @StateObject private var authService = AuthService()
    @StateObject private var syncService = SupabaseSyncService()
    @StateObject private var restoreCoordinator = RestoreCoordinator()
    @StateObject private var backupSnapshotService = BackupSnapshotService()
    @StateObject private var imageBackupCoordinator = ImageBackupCoordinator()
    @StateObject private var syncStatusReporter = SyncStatusReporter()
    @State private var skillAnalysisService: SkillAnalysisService?
    @State private var tokenInferenceCoordinator: TokenInferenceCoordinator?
    @State private var selectedTab: RootTab = .calendar
    @State private var isPresentingRestoreSheet = false

    private var isDecisionQuestionVisible: Bool {
        agentRuntime.decisionCenter.currentDecision != nil
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                // NOTE: The "想做" (wanna) tab is temporarily removed. The
                // RootTab.wanna case and WannaListView are intentionally kept
                // so the rest of the app keeps compiling; to restore the tab,
                // re-add the NavigationStack block below and revert the
                // wanna-related default tab values.
                NavigationStack {
                    CalendarPageView()
                        .environmentObject(store)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showTimerBanner,
                       let calEvent = store.activeTimerCalendarEvent,
                       let timerStart = calEvent.timerStartedAt {
                        TimerBannerView(
                            title: calEvent.title,
                            startedAt: timerStart,
                            color: EventTypeTemplateStore.color(for: calEvent.type),
                            onStop: {
                                if let todoId = calEvent.linkedTodoEventId,
                                   let todo = store.events.first(where: { $0.id == todoId }) {
                                    store.stopTimer(for: todo)
                                } else {
                                    store.stopActiveTimer()
                                }
                            }
                        )
                    }
                }
                .toolbar(isDecisionQuestionVisible ? .hidden : .visible, for: .tabBar)
                .slideHideTabBar(calendarFocusState.isEventFocused)
                .tag(RootTab.calendar)
                .tabItem {
                    Label(L(.tabCalendar), systemImage: "calendar")
                }

                NavigationStack {
                    ReportTabView()
                        .environmentObject(store)
                }
                .toolbar(isDecisionQuestionVisible ? .hidden : .visible, for: .tabBar)
                .tag(RootTab.report)
                .tabItem {
                    Label(L(.tabReport), systemImage: "doc.text")
                }

                NavigationStack {
                    ProfileHubView(selectedTab: $selectedTab)
                        .environmentObject(store)
                        .environmentObject(agentRuntime)
                        .environmentObject(skillInsightStore)
                        .environmentObject(authService)
                        .environmentObject(restoreCoordinator)
                }
                .toolbar(isDecisionQuestionVisible ? .hidden : .visible, for: .tabBar)
                .tag(RootTab.me)
                .tabItem {
                    Label(L(.tabMe), systemImage: "person.crop.circle")
                }
            }
            .scaleEffect(isDecisionQuestionVisible ? AgentDecisionPresentationStyle.backgroundScale : 1)
            .offset(y: isDecisionQuestionVisible ? AgentDecisionPresentationStyle.backgroundOffsetY : 0)
            .shadow(
                color: .black.opacity(isDecisionQuestionVisible ? AgentDecisionPresentationStyle.backgroundShadowOpacity : 0),
                radius: isDecisionQuestionVisible ? AgentDecisionPresentationStyle.backgroundShadowRadius : 0,
                x: 0,
                y: isDecisionQuestionVisible ? AgentDecisionPresentationStyle.backgroundShadowYOffset : 0
            )
            .animation(AgentDecisionPresentationStyle.spring, value: isDecisionQuestionVisible)

            Color.black
                .opacity(isDecisionQuestionVisible ? AgentDecisionPresentationStyle.scrimOpacity : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(AgentDecisionPresentationStyle.spring, value: isDecisionQuestionVisible)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AgentDecisionCardHost()
        }
        .environmentObject(calendarState)
        .environmentObject(calendarFocusState)
        .environmentObject(restoreCoordinator)
        .environmentObject(imageBackupCoordinator)
        .environmentObject(syncStatusReporter)
        .environmentObject(syncService)
        // RestoreSheet's per-row review needs SkillInsightStore in env (the
        // sheet is presented from this view's body, outside the Profile-tab
        // NavigationStack where the store is otherwise injected).
        .environmentObject(skillInsightStore)
        .onChange(of: orientationManager.isLandscape) { _, isLandscape in
            calendarDayOffsetUnfreezeTask?.cancel()
            if isLandscape {
                savedDayOffsetBeforeLandscape = calendarState.selectedDayOffset
                calendarState.isDayOffsetFrozen = true
            } else {
                if let saved = savedDayOffsetBeforeLandscape {
                    calendarState.selectedDayOffset = saved
                }
                calendarDayOffsetUnfreezeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled, !orientationManager.isLandscape else { return }
                    calendarState.isDayOffsetFrozen = false
                    savedDayOffsetBeforeLandscape = nil
                }
            }
        }
        .onDisappear {
            calendarDayOffsetUnfreezeTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            shiftSavedLandscapeOffsetForMidnightIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            shiftSavedLandscapeOffsetForMidnightIfNeeded()
        }
        .onAppear {
            selectedTab = startupTab
            let service = SkillAnalysisService(insightStore: skillInsightStore)
            skillAnalysisService = service
            if tokenInferenceCoordinator == nil {
                tokenInferenceCoordinator = TokenInferenceCoordinator(store: store)
            }
            store.onCalendarEventRecordCompleted = { event in
                Task { await service.analyzeEvent(event) }
            }
            let events = store.rawCalendarEvents
            Task { await service.analyzePastEvents(events) }
            syncService.statusReporter = syncStatusReporter
            imageBackupCoordinator.statusReporter = syncStatusReporter
            backupSnapshotService.statusReporter = syncStatusReporter
            syncService.attach(
                authService: authService,
                eventStore: store,
                eventTypeStore: agentRuntime.eventTypeTemplateStore,
                skillStore: skillInsightStore,
                preferenceStore: agentRuntime.preferenceStore
            )
            restoreCoordinator.configure(
                syncService: syncService,
                eventStore: store,
                eventTypeStore: agentRuntime.eventTypeTemplateStore,
                skillStore: skillInsightStore,
                preferenceStore: agentRuntime.preferenceStore,
                imageBackupCoordinator: imageBackupCoordinator
            )
            backupSnapshotService.attach(
                eventStore: store,
                eventTypeStore: agentRuntime.eventTypeTemplateStore,
                skillStore: skillInsightStore,
                preferenceStore: agentRuntime.preferenceStore
            )
            imageBackupCoordinator.attach(
                eventStore: store,
                authService: authService
            )
        }
        .onChange(of: selectedTab) { _, newValue in
            if rememberLastTab {
                lastSelectedTabRawValue = newValue.rawValue
            }
        }
        .onReceive(authService.$session.compactMap { $0 }) { session in
            offerAutoRestoreIfNeeded(forUserID: session.user.id)
        }
        .sheet(isPresented: $isPresentingRestoreSheet) {
            RestoreSheet()
                .environmentObject(restoreCoordinator)
                .environmentObject(imageBackupCoordinator)
        }
    }

    /// One-shot prompt to restore from the cloud the first time we see a given
    /// signed-in user on a device whose local data looks empty. The flag is keyed
    /// by userID so signing in as a different account re-prompts.
    private func offerAutoRestoreIfNeeded(forUserID userID: String) {
        guard !userID.isEmpty else { return }
        let flagKey = "hasOfferedAutoRestore.\(userID)"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard restoreCoordinator.shouldOfferAutoRestore() else { return }
        UserDefaults.standard.set(true, forKey: flagKey)
        isPresentingRestoreSheet = true
    }

    private var startupTab: RootTab {
        // The wanna tab is temporarily removed, so any persisted "wanna"
        // selection must fall back to a tab that still exists.
        if rememberLastTab, let last = RootTab(rawValue: lastSelectedTabRawValue), last != .wanna {
            return last
        }
        if let preferred = RootTab(rawValue: defaultTabRawValue), preferred != .wanna {
            return preferred
        }
        return .calendar
    }

    /// When midnight passes while the device is in landscape, CalendarPageView's
    /// own handler shifts `calendarState.selectedDayOffset` to keep the visual
    /// column on the same physical date.  This shifts the cached restore value
    /// by the same amount so rotating back to portrait doesn't snap the user
    /// to an off-by-one day.
    private func shiftSavedLandscapeOffsetForMidnightIfNeeded() {
        let days = CalendarMidnightHandler.daysCrossed(
            from: midnightLastKnownStartOfDay,
            to: Date()
        )
        guard days != 0 else { return }
        midnightLastKnownStartOfDay = Calendar.current.startOfDay(for: Date())
        if let saved = savedDayOffsetBeforeLandscape {
            savedDayOffsetBeforeLandscape = saved - days
        }
    }
}

private enum AgentDecisionPresentationStyle {
    static let backgroundScale: CGFloat = 0.985
    static let backgroundOffsetY: CGFloat = -6
    static let scrimOpacity: Double = 0.08
    static let backgroundShadowOpacity: Double = 0.08
    static let backgroundShadowRadius: CGFloat = 14
    static let backgroundShadowYOffset: CGFloat = 4
    static let spring = Animation.spring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.1)
}

struct TimerBannerView: View {
    let title: String
    let startedAt: Date
    let color: Color
    var onStop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            HStack(spacing: 10) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Text(formattedDuration(elapsed))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    onStop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

struct AgentDecisionCardHost: View {
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @State private var visibleOperationEventID: UUID?
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 8) {
            if let latest = agentRuntime.operationCenter.latestEvent,
               visibleOperationEventID == latest.id {
                agentOperationToast(latest)
            }

            if let decision = agentRuntime.decisionCenter.currentDecision {
                AgentDecisionCardView(
                    request: decision,
                    pendingCount: agentRuntime.decisionCenter.pendingCount,
                    onSelect: { optionID in
                        agentRuntime.decisionCenter.resolveCurrent(with: .selected(optionID: optionID))
                    },
                    onOtherwise: { text in
                        agentRuntime.decisionCenter.resolveCurrent(with: .otherwise(text: text))
                    },
                    onDismiss: {
                        agentRuntime.decisionCenter.dismissCurrent()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(AgentDecisionPresentationStyle.spring, value: agentRuntime.decisionCenter.currentDecision != nil)
        .onChange(of: agentRuntime.operationCenter.latestEvent?.id) {
            showLatestOperationToastIfNeeded()
        }
        .onChange(of: agentRuntime.decisionCenter.currentDecision?.id) { _, newID in
            if let newID {
                agentDecisionDebugLog("AgentDecisionCardHost currentDecision visible id=\(newID.uuidString)")
            } else {
                agentDecisionDebugLog("AgentDecisionCardHost currentDecision cleared")
            }
        }
        .onDisappear {
            toastDismissTask?.cancel()
        }
    }

    @ViewBuilder
    private func agentOperationToast(_ event: AgentOperationEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconName(for: event.phase))
                .font(.system(size: 12, weight: .semibold))
            Text(event.message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.001), in: Capsule())
        .glassEffect(.regular, in: Capsule())
        .overlay(
            Capsule()
                .stroke(strokeColor(for: event.phase).opacity(0.35), lineWidth: 1)
        )
    }

    private func showLatestOperationToastIfNeeded() {
        toastDismissTask?.cancel()
        guard let latest = agentRuntime.operationCenter.latestEvent else {
            visibleOperationEventID = nil
            return
        }
        visibleOperationEventID = latest.id
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if self.visibleOperationEventID == latest.id {
                    self.visibleOperationEventID = nil
                }
            }
        }
    }

    private func iconName(for phase: AgentOperationPhase) -> String {
        switch phase {
        case .started, .resumed:
            return "bolt.fill"
        case .waitingDecision:
            return "questionmark.circle"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .defaulted:
            return "clock.badge.exclamationmark"
        }
    }

    private func strokeColor(for phase: AgentOperationPhase) -> Color {
        switch phase {
        case .succeeded:
            return .green
        case .failed:
            return .orange
        case .defaulted:
            return .yellow
        case .waitingDecision:
            return .blue
        case .started, .resumed:
            return .accentColor
        }
    }
}

private struct AgentDecisionCardView: View {
    let request: AgentDecisionRequest
    let pendingCount: Int
    let onSelect: (String) -> Void
    let onOtherwise: (String) -> Void
    let onDismiss: () -> Void

    @State private var showOtherwiseInput = false
    @State private var otherwiseText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(request.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if pendingCount > 0 {
                    Text("+\(pendingCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            VStack(spacing: 8) {
                ForEach(Array(request.options.enumerated()), id: \.element.id) { index, option in
                    Button {
                        onSelect(option.id)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(index + 1).")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(option.title)
                                        .font(.system(size: 14, weight: .semibold))
                                        .multilineTextAlignment(.leading)
                                    if option.isRecommended {
                                        Text(L(.recommended))
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.green.opacity(0.12), in: Capsule())
                                    }
                                }
                                if let subtitle = option.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemBackground).opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if request.otherwiseEnabled {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showOtherwiseInput.toggle()
                        }
                    } label: {
                        HStack {
                            Text(L(.tellDoneStep))
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Image(systemName: showOtherwiseInput ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.systemBackground).opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    if showOtherwiseInput {
                        VStack(spacing: 8) {
                            TextField(L(.tellDoneOtherwise), text: $otherwiseText, axis: .vertical)
                                .textFieldStyle(.plain)
                                .lineLimit(1...3)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.systemBackground).opacity(0.75), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                            HStack {
                                Spacer()
                                Button(L(.submit)) {
                                    let text = otherwiseText.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !text.isEmpty else { return }
                                    onOtherwise(text)
                                    otherwiseText = ""
                                    showOtherwiseInput = false
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(otherwiseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            HStack {
                if let timeout = request.timeout, timeout > 0 {
                    Text(L(.dismissToDefault))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L(.dismissToApply))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L(.dismiss)) {
                    onDismiss()
                }
                .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 2)
    }
}
