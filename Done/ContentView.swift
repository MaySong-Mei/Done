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

// MARK: - Root-tab visibility (gh#214)

/// Whether the root tab hosting this subtree is the one currently on screen.
///
/// The root `TabView` builds every tab once and then keeps all of them alive
/// for the rest of the process, and a `NavigationStack` keeps every pushed
/// destination alive underneath its tab. A page that holds `EventStore` as an
/// `@EnvironmentObject` therefore re-runs its body on every `@Published`
/// mutation whether or not anyone can see it — including a weekly-analysis
/// page the user pushed an hour ago and never popped (gh#214).
///
/// Injected once per tab, on that tab's own child of the root `TabView`
/// (`ContentView.body`). That is the only level that knows which tab a
/// subtree belongs to, and it sits above every push, so a destination several
/// pages deep reads the same answer as the tab's root view.
///
/// Defaults to `true`. A subtree with no tab above it — a `#Preview`, a test
/// host, a tab that has not opted in — keeps computing: "compute" is the
/// pre-gh#214 behaviour, while guessing wrong in the other direction shows
/// the user a page with nothing in it.
private struct RootTabIsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var rootTabIsVisible: Bool {
        get { self[RootTabIsVisibleKey.self] }
        set { self[RootTabIsVisibleKey.self] = newValue }
    }
}

/// The predicate behind `\.rootTabIsVisible`, free of SwiftUI so XCTest can
/// pin it. `ProfileHubActivation.isActive` is this same rule specialised to
/// `.me`, so the Me page's own gate and its pushed children's gate cannot
/// drift apart.
enum RootTabVisibility {
    static func isVisible(tab: RootTab, selectedTab: RootTab) -> Bool {
        tab == selectedTab
    }
}

extension View {
    /// Marks this subtree as the content of `tab`. Apply to a direct child of
    /// the root `TabView`; every descendant, pushed or not, can then read
    /// `\.rootTabIsVisible`.
    func rootTabContent(_ tab: RootTab, selectedTab: RootTab) -> some View {
        environment(\.rootTabIsVisible, RootTabVisibility.isVisible(tab: tab, selectedTab: selectedTab))
    }
}

// AppSettingsKeys lives in Models/SyncedSettings.swift (shared, UIKit-free).

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
    @StateObject private var syncService = SupabaseSyncService(ownerRecord: .production)
    @StateObject private var restoreCoordinator = RestoreCoordinator()
    @StateObject private var backupSnapshotService = BackupSnapshotService()
    @StateObject private var imageBackupCoordinator = ImageBackupCoordinator()
    @StateObject private var syncStatusReporter = SyncStatusReporter()
    @State private var skillAnalysisService: SkillAnalysisService?
    /// Handle for the launch-time backlog sweep (gh#219). Non-nil once a
    /// sweep has been launched this app launch: onAppear re-runs on
    /// view-graph rebuilds, and without the nil-check each re-run would
    /// start another paid full sweep. Deliberately never reset to nil —
    /// after a background-cancel, the remaining backlog waits for the next
    /// app launch rather than restarting (and re-spending) on re-foreground.
    @State private var skillAnalysisTask: Task<Void, Never>?
    @State private var tokenInferenceCoordinator: TokenInferenceCoordinator?
    @State private var selectedTab: RootTab = .calendar
    @State private var isPresentingRestoreSheet = false
    /// Design §10.7: the account was erased on another device (a terminal
    /// `accountCheck`). One prompt, three choices; local data is untouched
    /// until the user picks. "Erase this phone" opens the existing erase
    /// with its confirmation armed — the erase itself lives there.
    @State private var isPresentingAccountGoneChoice = false
    /// The sign-in whose restore offer waits for the first pull (design §7
    /// Phase 1); nil when nothing waits.
    @State private var autoRestoreOwedUserID: String?
    @State private var isPresentingEraseAfterAccountGone = false

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
                .concealTabBar(calendarFocusState.isEventFocused ? .hidden : .visible)
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
                // gh#214. Only the Me tab opts in: it is the only tab whose
                // pushed pages reduce the whole store on every publish. The
                // others inherit the `true` default — exactly their
                // pre-gh#214 behaviour — and opting them in would buy
                // nothing but an extra invalidation of the calendar's
                // subtree on every tab switch.
                .rootTabContent(.me, selectedTab: selectedTab)
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
        // gh#258: "erase all local data" has to TELL this service, not just
        // delete around it — the snapshot is a plaintext copy of everything,
        // in Documents, which is where iOS Backup looks.
        .environmentObject(backupSnapshotService)
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
            skillAnalysisTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // End of the launch session for cost purposes: stop the backlog
            // sweep between events (it checks Task.isCancelled and flushes
            // the analyzed-id marks it has earned so far). The root view's
            // onDisappear does not reliably fire on scene teardown, so the
            // scene-level background notification is the cancellation
            // signal; onDisappear above is belt-and-suspenders.
            skillAnalysisTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            shiftSavedLandscapeOffsetForMidnightIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            shiftSavedLandscapeOffsetForMidnightIfNeeded()
        }
        .onAppear {
            selectedTab = startupTab
            let service: SkillAnalysisService
            if let existing = skillAnalysisService {
                service = existing
            } else {
                service = SkillAnalysisService(insightStore: skillInsightStore)
                skillAnalysisService = service
            }
            if tokenInferenceCoordinator == nil {
                tokenInferenceCoordinator = TokenInferenceCoordinator(store: store)
            }
            store.onCalendarEventRecordCompleted = { event in
                Task { await service.analyzeEvent(event) }
            }
            // One backlog sweep per launch, idempotent against onAppear
            // re-entry like the attach calls below; the service's own
            // re-entry guard backstops this. The sweep itself is capped at
            // SkillAnalysisService.perLaunchAnalysisCap provider calls.
            if skillAnalysisTask == nil {
                let events = store.rawCalendarEvents
                skillAnalysisTask = Task { await service.analyzePastEvents(events) }
            }
            syncService.statusReporter = syncStatusReporter
            imageBackupCoordinator.statusReporter = syncStatusReporter
            backupSnapshotService.statusReporter = syncStatusReporter
            // gh#257 (data belongs to its account): a sign-in over another
            // account's data that is all in the cloud switches on its own,
            // through the one erase the account card's switch runs. Set
            // before `attach`, whose session sink may switch at once.
            let ownerSwitchEraser = LocalDataEraser(store: store, skillStore: skillInsightStore, agentRuntime: agentRuntime,
                                                    authService: authService, calendarState: calendarState,
                                                    syncService: syncService,
                                                    imageBackupCoordinator: imageBackupCoordinator,
                                                    backupSnapshotService: backupSnapshotService)
            syncService.ownerSwitchEraser = { ownerSwitchEraser.resetAllLocalData(keepingSession: true) }
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
            offerAutoRestoreIfNeeded(forUserID: session.user.id, feed: syncService.feedAvailability)
        }
        // The offer waits for the session's first pull (design §7 Phase 1):
        // `@Published` delivers the new value before it is stored, so the
        // decision reads the delivered one.
        .onReceive(syncService.$feedAvailability) { feed in
            guard let owed = autoRestoreOwedUserID else { return }
            guard owed == authService.session?.user.id else {
                autoRestoreOwedUserID = nil
                return
            }
            offerAutoRestoreIfNeeded(forUserID: owed, feed: feed)
        }
        .onReceive(syncService.$accountCheck) { check in
            if case .signedOut = check, syncService.accountGoneChoice == nil {
                isPresentingAccountGoneChoice = true
            }
        }
        .alert(L(.accountGoneTitle), isPresented: $isPresentingAccountGoneChoice) {
            // The design's three choices and no fourth (sim QA: the system
            // added a Cancel that left the user undecided). Keeping the data
            // is the choice that changes nothing, so it takes the cancel role.
            Button(L(.accountGoneKeepLocal), role: .cancel) {
                syncService.chooseAfterAccountGone(.keepLocalData)
            }
            Button(L(.accountGoneUploadNext)) {
                syncService.chooseAfterAccountGone(.uploadIntoNextAccount)
            }
            Button(L(.accountGoneErase), role: .destructive) {
                syncService.chooseAfterAccountGone(.eraseThisDevice)
                isPresentingEraseAfterAccountGone = true
            }
        } message: {
            Text(L(.accountGoneBody))
        }
        // gh#257 staging QA round 7: a sign-in held over another account's
        // unsynced changes says so over the main screen, once per launch,
        // with the card's two answers. "Cancel" signs out so that account
        // can sign in and sync.
        .alert(L(.ownerSwitchConfirmTitle),
               isPresented: Binding(get: { syncService.heldSwitchAlert != nil },
                                    set: { if !$0 { syncService.heldSwitchAlert = nil } }),
               presenting: syncService.heldSwitchAlert) { _ in
            Button(L(.ownerUnsyncedSwitchAnyway), role: .destructive) {
                syncService.switchAnyway()
            }
            Button(L(.cancel), role: .cancel) {
                syncService.deferSwitchUntilOwnerSyncs()
                authService.signOut()
            }
        } message: { unsynced in
            Text(LCount(.ownerUnsyncedFormat, one: .ownerUnsyncedOne, unsynced))
        }
        .sheet(isPresented: $isPresentingEraseAfterAccountGone) {
            NavigationStack {
                DataPrivacySettingsView(armResetConfirmation: true)
                    .environmentObject(store)
                    .environmentObject(agentRuntime)
                    .environmentObject(skillInsightStore)
                    .environmentObject(authService)
                    .environmentObject(restoreCoordinator)
                    .environmentObject(imageBackupCoordinator)
                    .environmentObject(backupSnapshotService)
                    .environmentObject(syncStatusReporter)
                    .environmentObject(syncService)
                    .environmentObject(calendarState)
            }
        }
        .sheet(isPresented: $isPresentingRestoreSheet) {
            RestoreSheet()
                .environmentObject(restoreCoordinator)
                .environmentObject(imageBackupCoordinator)
        }
        // The one recovery prompt after a catch-up (design §6.6).
        .syncRecoveryPrompt(syncService)
        // A frozen slot presents to the user as an EMPTY calendar. Without
        // this the app would look like it silently ate their data, and the
        // one action that makes it worse — carrying on editing, which writes
        // nothing — would be the natural thing to do. Not dismissible on
        // purpose: it clears when the condition clears.
        //
        // Bottom rather than top: every tab puts its own controls under the
        // status bar, and a top overlay covered the calendar header including
        // the Create button (verified on the simulator).
        .overlay(alignment: .bottom) { storageFaultBanner }
    }

    private var storageFaultBanner: some View {
        StorageFaultBanner(
            store: store,
            eventTypeStore: agentRuntime.eventTypeTemplateStore,
            conversations: AgentConversationRepository.shared,
            occurrenceKeyMetadata: OccurrenceKeyMetadataStore.shared
        )
    }

    /// One-shot prompt to restore from the cloud the first time we see a given
    /// signed-in user on a device whose local data looks empty. The flag is keyed
    /// by userID so signing in as a different account re-prompts.
    ///
    /// Retired where the change feed answers (design §7 Phase 1; gh#257
    /// staging QA round 4 bug 2): the first pull to head loads the account,
    /// so no sheet. Kept on a server without migration 015 and while sync is
    /// off on this device (`SupabaseSyncService.autoRestoreOfferDecision`).
    private func offerAutoRestoreIfNeeded(forUserID userID: String, feed: SyncFeedAvailability) {
        guard !userID.isEmpty else { return }
        let flagKey = "hasOfferedAutoRestore.\(userID)"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        guard restoreCoordinator.shouldOfferAutoRestore() else { return }
        switch SupabaseSyncService.autoRestoreOfferDecision(syncRuns: syncService.canUpload, feed: feed) {
        case .wait:
            autoRestoreOwedUserID = userID
            return
        case .retired:
            autoRestoreOwedUserID = nil
            DiagnosticTrail.record("Sync", "sync.restore_offer decision=retired reason=feed_available")
            return
        case .offer:
            autoRestoreOwedUserID = nil
        }
        UserDefaults.standard.set(true, forKey: flagKey)
        DiagnosticTrail.record("Sync", "sync.restore_offer decision=offer feed=\(feed)")
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

// `StorageFaultBannerState` lives in Models/StorageFaultBannerState.swift (shared with the Mac target).

/// The persistence-degraded banner.
///
/// Its own view rather than a `@ViewBuilder` on `ContentView` for one
/// mechanical reason: it watches FOUR independent stores, and neither the
/// event-type store (reached through `agentRuntime`, whose own
/// `objectWillChange` says nothing about a nested store's `@Published`) nor
/// the conversation repository and occurrence-key metadata store
/// (process-wide singletons nobody owns) would otherwise redraw it. An
/// `@ObservedObject` on each is what makes a mid-session write failure raise
/// the banner rather than wait for some unrelated redraw.
///
/// EVERY durable store that can refuse writes belongs here. The chat history
/// is the one this was added for: a frozen conversation file shows an empty
/// chat list, accepts new rounds, refuses every save and loses the lot on the
/// next launch, and only a user-initiated restore ends that — so a store that
/// cannot tell the user is a store that stays broken.
private struct StorageFaultBanner: View {
    @ObservedObject var store: EventStore
    @ObservedObject var eventTypeStore: EventTypeTemplateStore
    @ObservedObject var conversations: AgentConversationRepository
    /// The zone store resolves lazily, so evaluating this banner's predicate
    /// is itself what forces the first read — by the first render the state
    /// is known, and after that it only changes on the two user-confirmed
    /// exits (restore, reset), both of which publish.
    @ObservedObject var occurrenceKeyMetadata: OccurrenceKeyMetadataStore

    private var state: StorageFaultBannerState {
        StorageFaultBannerState(store: store,
                                eventTypeStore: eventTypeStore,
                                conversations: conversations,
                                occurrenceKeyMetadata: occurrenceKeyMetadata)
    }
    private var isDegraded: Bool { state.isDegraded }
    private var isUnreadable: Bool { state.isUnreadable }

    var body: some View {
        if isDegraded {
            VStack(alignment: .leading, spacing: 4) {
                Label(L(.storageFaultTitle), systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.semibold))
                Text(isUnreadable ? L(.storageFaultBody) : L(.storageWriteFailedBody))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.6), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 96)   // clears the tab bar
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
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
