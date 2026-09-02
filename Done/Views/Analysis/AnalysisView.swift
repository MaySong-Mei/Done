//
//  AnalysisView.swift
//  Done
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

// MARK: - Me Avatar Persistence

/// Saves the user's avatar image to a stable filename in Documents. Views
/// observe `meAvatarVersion` (via @AppStorage) to know when to reload.
enum MeAvatarStore {
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("me-avatar.jpg")
    }

    static var hasImage: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func load() -> UIImage? {
        guard hasImage else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    @discardableResult
    static func save(_ image: UIImage) -> Bool {
        let resized = downscale(image, maxEdge: 512)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Raw I/O for sync (Phase 1 of full-backup completion)
    //
    // The sync layer deals in bytes, not UIImage. These helpers let
    // `ImageBackupCoordinator` upload the current avatar to Supabase
    // Storage and write a freshly-downloaded one back to disk on restore
    // without re-encoding through `UIImage.jpegData` (which would change
    // bytes round-trip).

    /// Raw JPEG bytes of the current avatar, or nil if none on disk.
    static func loadData() -> Data? {
        guard hasImage else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Write raw JPEG bytes to the avatar slot. Caller-supplied bytes are
    /// assumed to be already-compressed JPEG (the sync layer fetches the
    /// exact bytes that were previously uploaded by the source device).
    static func writeRaw(_ data: Data) throws {
        try data.write(to: url, options: .atomic)
    }

    private static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let longestEdge = max(w, h)
        guard longestEdge > maxEdge else { return image }
        let scale = maxEdge / longestEdge
        let size = CGSize(width: w * scale, height: h * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Everything the analysis pages need that costs a pass over the store,
/// computed once per body pass — and only while the tab hosting the page is
/// on screen (gh#214).
///
/// These pages are PUSHED destinations. `ProfileHubView`'s own gate does not
/// reach them: a `NavigationStack` keeps a pushed page alive and subscribed
/// after the user switches tabs, so `AnalysisContentView.body` was measured
/// running once per store publish from the Calendar tab — the same count as
/// when it is visible. They read `\.rootTabIsVisible` instead.
struct AnalysisAggregates {
    var allocations: [TypeAllocation] = []
    var dailyData: [DailyHours] = []
    var trend: [CompletionDataPoint] = []
    var skills: [SkillAggregate] = []
    /// True only when the reduction actually RAN. `false` means "skipped",
    /// which is not the same claim as "ran and found nothing" — and the
    /// sections branch on it rather than on emptiness, because collapsing a
    /// `NavigationLink` out of the tree while its destination is pushed pops
    /// the user's page out from under them on a tab switch.
    var isComputed = false

    /// Whether the charts block — and the `NavigationLink` that OWNS the
    /// pushed time-allocation page — stays in the tree. A skipped reduction
    /// keeps it: a link that disappears takes its pushed destination with
    /// it, so gating this on emptiness alone would pop the user's page the
    /// moment they switched tabs (gh#214).
    var showsChartSection: Bool {
        !isComputed || !allocations.isEmpty || !dailyData.isEmpty
    }

    /// Same rule for the completion trend. Nothing is pushed from under it,
    /// so this one is symmetry rather than necessity — but a section that
    /// vanishes and returns on a tab switch is churn either way.
    var showsTrendSection: Bool {
        !isComputed || trend.contains { $0.count > 0 }
    }

    /// The two chart reductions, shared by both pages. `visible:` is the
    /// Fix Watch witness answer — required, so no caller can run this
    /// store-wide pass without stating whether the surface is on screen
    /// (see `MeAggregateWitness`).
    @MainActor
    static func chart(store: EventStore, viewModel: AnalysisViewModel, visible: Bool) -> AnalysisAggregates {
        MeAggregateWitness.note(visible: visible)
        #if DEBUG
        ProfileHubAggregateProbe.recordAnalysis(store: store)
        #endif
        var result = AnalysisAggregates()
        result.allocations = viewModel.typeAllocations(store: store)
        result.dailyData = viewModel.dailyHoursData(store: store)
        result.isComputed = true
        return result
    }

    /// The charts plus the completion trend and the skill aggregation —
    /// `AnalysisContentView`'s full bill.
    @MainActor
    static func full(
        store: EventStore,
        skillStore: SkillInsightStore,
        viewModel: AnalysisViewModel,
        visible: Bool
    ) -> AnalysisAggregates {
        // `chart` witnesses; no second note here — one call, one witness.
        var result = chart(store: store, viewModel: viewModel, visible: visible)
        result.trend = viewModel.taskCompletionTrend(store: store)
        let range = viewModel.dateRange
        result.skills = skillStore.aggregatedSkills(start: range.start, end: range.end)
        return result
    }
}

struct AnalysisContentView: View {
    @EnvironmentObject var store: EventStore
    @EnvironmentObject var skillStore: SkillInsightStore
    /// gh#214. This page is pushed on the Me tab and survives a tab switch;
    /// see `RootTabIsVisibleKey` in ContentView.swift.
    @Environment(\.rootTabIsVisible) private var isTabVisible
    @AppStorage(AppSettingsKeys.analysisAutoLoadSuggestions) private var autoLoadSuggestions = false
    @StateObject private var viewModel: AnalysisViewModel
    @State private var suggestions: [AISuggestion] = []
    @State private var isLoadingSuggestions = false
    private let suggestionService = AnalysisSuggestionService()

    private var dateSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 1.5 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.offset += dx < 0 ? 1 : -1
                }
            }
    }

    init() {
        _viewModel = StateObject(wrappedValue: AnalysisViewModel())
    }

    /// The store-touching part of a body pass, skipped whole while the tab
    /// hosting this page is off screen (gh#214).
    private func currentAggregates() -> AnalysisAggregates {
        guard isTabVisible else { return AnalysisAggregates() }
        return AnalysisAggregates.full(store: store, skillStore: skillStore, viewModel: viewModel, visible: isTabVisible)
    }

    var body: some View {
        let data = currentAggregates()
        return VStack(spacing: 16) {
            Picker(L(.periodPickerLabel), selection: $viewModel.period) {
                ForEach(AnalysisPeriod.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.period) { _, _ in
                viewModel.offset = 0
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(viewModel.periodLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.offset != 0 {
                        Button(L(.today)) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.offset = 0
                            }
                        }
                        .font(.caption)
                    }
                }
                .contentShape(Rectangle())
                .simultaneousGesture(dateSwipeGesture)

                if data.showsChartSection {
                    NavigationLink {
                        TimeAllocationDetailView(initialPeriod: viewModel.period)
                            .environmentObject(store)
                    } label: {
                        HoursChartPager(
                            allocations: data.allocations,
                            dailyData: data.dailyData,
                            period: viewModel.period
                        )
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 16) {
                    if data.showsTrendSection {
                        Divider()
                        TaskCompletionTrendChart(data: data.trend)
                    }

                    Divider()
                    SkillPanel(data: data.skills)

                    Divider()
                    AISuggestionsCard(
                        suggestions: suggestions,
                        isLoading: isLoadingSuggestions,
                        onRefresh: { loadSuggestions() },
                        onAddEvent: { addSuggestedEvent($0) }
                    )
                }
                .contentShape(Rectangle())
                .simultaneousGesture(dateSwipeGesture)
            }
        }
        .task(id: autoLoadSuggestions) {
            triggerSuggestionLoadIfNeeded()
        }
    }

    // MARK: - AI Suggestions

    private func loadSuggestions() {
        guard !isLoadingSuggestions else { return }
        isLoadingSuggestions = true
        Task {
            let result = await suggestionService.generateSuggestions(store: store, viewModel: viewModel)
            await MainActor.run {
                suggestions = result
                isLoadingSuggestions = false
            }
        }
    }

    private func triggerSuggestionLoadIfNeeded() {
        guard autoLoadSuggestions, suggestions.isEmpty, !isLoadingSuggestions else { return }
        loadSuggestions()
    }

    private func addSuggestedEvent(_ suggested: SuggestedEvent) {
        let calendar = Calendar.current
        let now = Date()
        let roundedMinute = (calendar.component(.minute, from: now) / 15 + 1) * 15
        let start = calendar.date(bySettingHour: calendar.component(.hour, from: now),
                                  minute: roundedMinute, second: 0, of: now) ?? now
        let end = start.addingTimeInterval(Double(suggested.durationMinutes) * 60)

        let event = Event(
            title: suggested.title,
            timeRanges: [Event.TimeRange(start: start, end: end)],
            type: suggested.type
        )
        store.addCalendarEvent(event)
    }
}

struct AnalysisDetailView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var skillStore: SkillInsightStore

    var body: some View {
        ScrollView {
            AnalysisContentView()
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
        }
        .navigationTitle(L(.analysis))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TimeAllocationDetailView: View {
    @EnvironmentObject var store: EventStore
    /// gh#214 — pushed two pages deep on the Me tab and kept alive there.
    @Environment(\.rootTabIsVisible) private var isTabVisible
    @StateObject private var viewModel: AnalysisViewModel

    init(initialPeriod: AnalysisPeriod = .week) {
        let vm = AnalysisViewModel()
        vm.period = initialPeriod
        _viewModel = StateObject(wrappedValue: vm)
    }

    /// Nothing here is conditional on the data, so the empty value only
    /// empties the chart — no structure to preserve (this page pushes
    /// nothing of its own).
    private func currentAggregates() -> AnalysisAggregates {
        guard isTabVisible else { return AnalysisAggregates() }
        return AnalysisAggregates.chart(store: store, viewModel: viewModel, visible: isTabVisible)
    }

    var body: some View {
        let data = currentAggregates()
        return ScrollView {
            VStack(spacing: 20) {
                PeriodSelector(viewModel: viewModel)

                HoursChartPager(
                    allocations: data.allocations,
                    dailyData: data.dailyData,
                    period: viewModel.period
                )
            }
            .padding(16)
        }
        .navigationTitle(L(.timeAllocation))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PeriodSelector: View {
    @ObservedObject var viewModel: AnalysisViewModel

    var body: some View {
        VStack(spacing: 12) {
            Picker(L(.periodPickerLabel), selection: $viewModel.period) {
                ForEach(AnalysisPeriod.allCases, id: \.self) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: viewModel.period) { _, _ in
                viewModel.offset = 0
            }

            HStack {
                Button { viewModel.offset -= 1 } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                }

                Spacer()

                VStack(spacing: 2) {
                    Text(viewModel.periodLabel)
                        .font(.headline)
                    if viewModel.offset != 0 {
                        Button(L(.today)) {
                            viewModel.offset = 0
                        }
                        .font(.caption)
                    }
                }

                Spacer()

                Button { viewModel.offset += 1 } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }
}

// MARK: - Me page activation gate (gh#214)

/// Whether `ProfileHubView` is allowed to spend a pass over the store.
///
/// The Me page is created once and then kept alive by the root `TabView` for
/// the rest of the process (`ContentView.swift`, `.tag(RootTab.me)`), and it
/// holds `EventStore` as an `@EnvironmentObject` — so **every** `@Published`
/// mutation on the store re-runs its body, including while the user is on the
/// calendar tapping the effort scrubber. On a real dataset that body pass is
/// a filter + sort of every event plus the whole achievement catalogue, and
/// it was measured at ~41% of the main-thread samples inside 26 hangs of
/// 253–538 ms (gh#214).
///
/// A free predicate rather than a condition inside `body`: SwiftUI body
/// composition is not reachable from XCTest, so a gate that only exists in
/// `body` cannot be pinned by a test.
enum ProfileHubActivation {
    /// The Me tab's specialisation of `RootTabVisibility.isVisible` — one
    /// rule, so this page's gate and the gate its PUSHED children read out of
    /// `\.rootTabIsVisible` cannot drift apart (gh#214).
    static func isActive(selectedTab: RootTab) -> Bool {
        RootTabVisibility.isVisible(tab: .me, selectedTab: selectedTab)
    }
}

/// FIX WATCH (gh#214, Entry 2) — the witness every store-wide Me
/// reduction answers. The reductions take a required `visible:` parameter
/// (compiler-forced: a future caller cannot invoke one without answering
/// the visibility question) and route it here; a `false` answer is the
/// TRIPWIRE — this exact work was 41% of main-thread samples inside 26
/// hangs of 253–538ms before the gate — and a `true` answer is the
/// liveness counter that keeps 0 violations distinguishable from a dead
/// wire.
///
/// HONESTY (R-F7): the answer is the SAME predicate the gate reads
/// (`ProfileHubActivation.isActive` / `\.rootTabIsVisible`). This
/// tripwire detects CALL-SITE BYPASSES; it is blind to rot inside
/// `RootTabVisibility.isVisible` itself — if that predicate breaks, the
/// gate and the tripwire go blind together. No independent ground truth
/// is built in this slice, deliberately.
///
/// A hidden hero pass emits twice (its own compute + the catalogue it
/// calls): the count is "witnessed reduction executions", and the verdict
/// is alarm-on-ANY, so multiplicity never changes the reading. Zero-cost
/// when nothing is armed and no resident is attached: one optional-closure
/// nil-check, exactly like every other emit.
enum MeAggregateWitness {
    static func note(visible: Bool) {
        if visible {
            SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
        } else {
            SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        }
    }
}

/// The Me page's "background types" setting (`AppSettingsKeys.meBackgroundTypes`)
/// is one comma-separated string. Parsing lives here, out of the view, so a
/// body pass splits it ONCE: the resulting set feeds a predicate that is
/// called per event (inside `calendarProjectedTypeHours`), per heatmap cell,
/// and per stacked-bar segment, and the old computed-property form re-split
/// the raw string on every one of those calls (gh#214).
enum MeBackgroundTypes {
    static func parse(_ raw: String) -> Set<String> {
        Set(raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        )
    }

    /// Matching is case-insensitive on the type name, exactly as the
    /// computed-property form was.
    static func contains(_ type: String, in parsed: Set<String>) -> Bool {
        parsed.contains(type.lowercased())
    }
}

#if DEBUG
/// Test seam for gh#214. The gate's claim is about work that does **not**
/// happen, and a skipped computation is invisible from the outside — so the
/// Me page's store-touching entry points record that they ran, and a
/// host-level test mounts the real view and reads the counts. DEBUG-only:
/// the release binary carries no counters.
///
/// Every count is SCOPED to one `EventStore`. `DoneTests` is a host-app
/// bundle: the app's own `ContentView` — and, on whatever tab the app last
/// restored, its own live `ProfileHubView` — is running in the same process.
/// An unscoped counter counts that page too, which would make a "did not
/// compute" assertion fail for an unrelated reason and, far worse, let a
/// "did compute" positive control pass without the view under test ever
/// having rendered.
enum ProfileHubAggregateProbe {
    /// The store whose page is under test. Weak so a finished test's store
    /// cannot keep counting.
    nonisolated(unsafe) weak static var scope: EventStore?
    nonisolated(unsafe) private(set) static var computeCount = 0
    /// The profile sheet's full type list — the Me page's second store-wide
    /// reduction, sitting inside a `.sheet` content closure whose evaluation
    /// schedule is not something to guess at.
    nonisolated(unsafe) private(set) static var typeListCount = 0
    /// `AnalysisAggregates` — the reduction behind the weekly-analysis page
    /// and the time-allocation page. Both are PUSHED destinations, which the
    /// Me tab keeps alive across a tab switch, so they publish-compute from
    /// off screen unless `\.rootTabIsVisible` stops them (gh#214).
    nonisolated(unsafe) private(set) static var analysisCount = 0
    /// `TrophyView`'s achievement-catalogue pass — same shape, pushed from
    /// the Me page's "see all".
    nonisolated(unsafe) private(set) static var trophyCount = 0
    /// The identity line the hero row last rendered, and the one the share
    /// card was last handed. `nil` until that section has run once. Two
    /// recordings rather than one because the interesting property is that
    /// they AGREE: the exported image and the page must rank types the same.
    nonisolated(unsafe) private(set) static var heroDescriptors: [String]?
    nonisolated(unsafe) private(set) static var shareCardDescriptors: [String]?

    static func record(store: EventStore) {
        guard scope === store else { return }
        computeCount += 1
    }

    static func recordTypeList(store: EventStore) {
        guard scope === store else { return }
        typeListCount += 1
    }

    static func recordAnalysis(store: EventStore) {
        guard scope === store else { return }
        analysisCount += 1
    }

    static func recordTrophy(store: EventStore) {
        guard scope === store else { return }
        trophyCount += 1
    }

    static func recordHeroDescriptors(store: EventStore, _ descriptors: [String]) {
        guard scope === store else { return }
        heroDescriptors = descriptors
    }

    static func recordShareDescriptors(store: EventStore, _ descriptors: [String]) {
        guard scope === store else { return }
        shareCardDescriptors = descriptors
    }

    static func reset() {
        computeCount = 0
        typeListCount = 0
        analysisCount = 0
        trophyCount = 0
        heroDescriptors = nil
        shareCardDescriptors = nil
    }
}
#endif

/// Everything `ProfileHubView`'s body needs that costs a pass over the store,
/// computed once per body pass — and only while the Me tab is the selected
/// tab (gh#214). Sections read this value; none of them reaches for the store
/// on their own, so the gate has exactly one place to hold.
///
/// Collapsing the sections' reads into one value also removes two duplicate
/// passes the old shape paid every single time: `topDescriptors()` ran once
/// for the hero row and again for the share card, and `AchievementCatalog`
/// ran once for the "recently earned" rows and again on every appear.
struct ProfileHubAggregates {
    /// Parsed even when the page is gated off — one string split, and the
    /// predicate built from it is handed to child views regardless.
    var backgroundTypes: Set<String> = []
    var topDescriptors: [String] = []
    var achievements: [Achievement] = []
    var weekDoneCount: Int = 0
    var weekAllocations: [TypeAllocation] = []
    var weekDaily: [DailyHours] = []
    /// Legacy active wannas with no calendar event behind them yet.
    var waitingWannaCount: Int = 0
    var unreviewedCount: Int = 0

    var activeWeekHours: Double {
        weekAllocations
            .filter { !MeBackgroundTypes.contains($0.type, in: backgroundTypes) }
            .reduce(0) { $0 + $1.hours }
    }

    var recentlyEarned: [Achievement] {
        Array(
            achievements
                .filter { $0.unlocked }
                .sorted { ($0.unlockedAt ?? .distantPast) > ($1.unlockedAt ?? .distantPast) }
                .prefix(3)
        )
    }

    @MainActor
    static func compute(
        store: EventStore,
        skillStore: SkillInsightStore,
        weekViewModel: AnalysisViewModel,
        backgroundTypes: Set<String>,
        visible: Bool,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> ProfileHubAggregates {
        MeAggregateWitness.note(visible: visible)
        #if DEBUG
        ProfileHubAggregateProbe.record(store: store)
        #endif
        var result = ProfileHubAggregates()
        result.backgroundTypes = backgroundTypes
        result.achievements = AchievementCatalog.compute(store: store, skillStore: skillStore, visible: visible)
        result.weekDoneCount = weekViewModel.tasksCompletedCount(store: store)
        result.weekAllocations = weekViewModel.typeAllocations(store: store)
        result.weekDaily = weekViewModel.dailyHoursData(store: store)
        result.waitingWannaCount = store.activeEvents.filter { $0.linkedCalendarEventId == nil }.count
        result.unreviewedCount = unreviewedCount(
            events: store.events,
            logs: store.calendarEventLogRecords,
            calendar: calendar,
            now: now
        )
        result.topDescriptors = topDescriptors(
            events: store.canvasRenderableCalendarEvents,
            backgroundTypes: backgroundTypes,
            calendar: calendar,
            now: now
        )
        return result
    }

    /// Completed events from the last 7 days that carry no log record yet.
    /// Pure so the "Now" row's count is testable without a view.
    static func unreviewedCount(
        events: [Event],
        logs: [CalendarEventLogRecord],
        calendar: Calendar,
        now: Date
    ) -> Int {
        guard let weekStart = calendar.date(byAdding: .day, value: -7, to: now) else { return 0 }
        let logged = Set(logs.map(\.eventID))
        return events.filter {
            $0.status == .completed
                && ($0.completeAt ?? .distantPast) >= weekStart
                && ($0.completeAt ?? .distantFuture) <= now
                && !logged.contains($0.id)
        }.count
    }

    /// The hero row's "who you are" line: the three types you spent the most
    /// non-background hours on over the last 30 days.
    ///
    /// canvasRenderableCalendarEvents at the call site: an absorbed `.todo`
    /// keeps its own type + timeRanges, so it would otherwise add its hours
    /// to its own type bucket on top of the parent event already adding to
    /// the parent's — keep the ranking consistent with what the canvas and
    /// the chart say.
    static func topDescriptors(
        events: [Event],
        backgroundTypes: Set<String>,
        calendar: Calendar,
        now: Date
    ) -> [String] {
        guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return [] }
        return calendarProjectedTypeHours(
            events: events,
            window: start...now,
            isBackground: { MeBackgroundTypes.contains($0, in: backgroundTypes) },
            calendar: calendar
        )
        .sorted { $0.value > $1.value }
        .prefix(3)
        .map { $0.key }
    }
}

struct ProfileHubView: View {
    @Binding var selectedTab: RootTab
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var skillStore: SkillInsightStore
    @EnvironmentObject private var authService: AuthService

    @StateObject private var weekViewModel = AnalysisViewModel(initialPeriod: .week)
    @AppStorage(AppSettingsKeys.mcpURL) private var mcpURL: String = ""
    @AppStorage(AppSettingsKeys.meDisplayName) private var displayName: String = ""
    @AppStorage(AppSettingsKeys.meAvatarHue) private var avatarHue: Double = -1
    @AppStorage(AppSettingsKeys.meAvatarVersion) private var avatarVersion: Int = 0
    @AppStorage(AppSettingsKeys.meBackgroundTypes) private var backgroundTypesRaw: String = AppSettingsKeys.meBackgroundTypesDefault
    @State private var isEditingProfile = false
    @State private var isShowingWeeklyShare: Bool = false
    @AppStorage(AppSettingsKeys.celebratedAchievements) private var celebratedRaw: String = ""
    @AppStorage(AppSettingsKeys.achievementCelebrationSeeded) private var celebrationSeeded: Bool = false
    @State private var celebrationQueue: [Achievement] = []
    @State private var celebratingAchievement: Achievement?
    @AppStorage(AppSettingsKeys.personalityProfile) private var personalityRaw: String = ""
    @AppStorage(AppSettingsLocale.languageKey) private var appLanguage: String = "en"
    @State private var isLoadingPersonality = false
    @State private var personalityFailed = false
    @State private var personalityErrorMessage: String?
    private let personalityService = PersonalityTagsService()

    /// gh#214's gate, read once per body pass. See `ProfileHubActivation`.
    private var isActiveTab: Bool {
        ProfileHubActivation.isActive(selectedTab: selectedTab)
    }

    /// The single store-touching computation of a body pass — skipped whole
    /// while this is not the selected tab (gh#214). Every section reads the
    /// returned value instead of reaching for the store, so the gate has
    /// exactly one place to hold.
    ///
    /// One store read in this view sits outside it: `knownTypeNames()`, which
    /// builds the profile sheet's type list inside the sheet's own content
    /// closure. A closed sheet's closure is measured not to run on a body
    /// pass (`ProfileHubAggregateProbe.typeListCount`, pinned by the host
    /// tests both on and off the tab), so it costs nothing per publish.
    private func currentAggregates() -> ProfileHubAggregates {
        // Parsed unconditionally: it is one string split, and the predicate
        // it feeds is handed to child views that render regardless.
        let backgroundTypes = MeBackgroundTypes.parse(backgroundTypesRaw)
        guard isActiveTab else {
            return ProfileHubAggregates(backgroundTypes: backgroundTypes)
        }
        return ProfileHubAggregates.compute(
            store: store,
            skillStore: skillStore,
            weekViewModel: weekViewModel,
            backgroundTypes: backgroundTypes,
            visible: isActiveTab
        )
    }

    var body: some View {
        let aggregates = currentAggregates()
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroSection(aggregates)
                personalitySection
                nowSection(aggregates)
                thisWeekSection(aggregates)
                if !mcpURL.isEmpty {
                    connectionsSection
                }
                recentlyEarnedSection(aggregates)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $isEditingProfile) {
            ProfileEditSheet(
                displayName: $displayName,
                avatarHue: $avatarHue,
                backgroundTypesRaw: $backgroundTypesRaw,
                fallbackName: fallbackNameFromAuth(),
                allTypes: knownTypeNames()
            )
            .presentationDetents([.large])
        }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            SwiftUI.GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Text(L(.tabMe))
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .contentShape(Capsule())
                        .background(Color.black.opacity(0.001), in: Capsule())
                        .glassEffect(.regular, in: Capsule())
                    Spacer(minLength: 0)
                    NavigationLink {
                        SettingsHomeView()
                            .environmentObject(store)
                            .environmentObject(agentRuntime)
                            .environmentObject(skillStore)
                            .environmentObject(authService)
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 40, height: 40)
                            .contentShape(Capsule())
                            .background(Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .overlay {
            if let achievement = celebratingAchievement {
                ZStack {
                    ConfettiView()
                    AchievementUnlockedView(achievement: achievement)
                }
                // Recreate per achievement so both animations restart from t=0.
                .id(achievement.id)
                .ignoresSafeArea()
                .task(id: achievement.id) {
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    advanceCelebration()
                }
            }
        }
        .onAppear { celebrateNewlyUnlockedAchievements(aggregates) }
        // Belt for the seeding branch below, which is destructive if it ever
        // runs against an empty achievement list: it would stamp "nothing was
        // ever unlocked" and then pop every badge at once on the next visit.
        // `onAppear` alone is enough only as long as it fires on a pass where
        // the tab is already selected, which is not this view's to guarantee;
        // the activation edge fires the same check off the same pass's
        // aggregates, and the second call is a no-op once the first has
        // written the celebrated set.
        .onChange(of: isActiveTab) { _, active in
            if active { celebrateNewlyUnlockedAchievements(aggregates) }
        }
    }

    /// Show the next queued unlock, or end the celebration when the queue
    /// is empty. Each one plays its own confetti + reveal before the next.
    private func advanceCelebration() {
        if celebrationQueue.isEmpty {
            celebratingAchievement = nil
        } else {
            celebratingAchievement = celebrationQueue.removeFirst()
        }
    }

    /// Fires confetti + a center "achievement unlocked" reveal when a badge has
    /// been earned since the last visit. On first run it silently seeds the
    /// celebrated set with whatever is already unlocked, so old badges don't
    /// all pop at once.
    private func celebrateNewlyUnlockedAchievements(_ aggregates: ProfileHubAggregates) {
        // Only ever runs against a real computed pass: while the Me tab is
        // not selected `aggregates.achievements` is empty by construction,
        // and seeding off that empty list is exactly the confetti storm the
        // seed is there to prevent.
        guard isActiveTab else { return }
        let unlocked = aggregates.achievements.filter { $0.unlocked }
        let unlockedIDs = Set(unlocked.map(\.id))

        guard celebrationSeeded else {
            celebratedRaw = unlockedIDs.sorted().joined(separator: ",")
            celebrationSeeded = true
            return
        }

        let celebrated = Set(celebratedRaw.split(separator: ",").map(String.init))
        let newlyUnlocked = unlocked.filter { !celebrated.contains($0.id) }
        guard !newlyUnlocked.isEmpty else { return }

        celebratedRaw = unlockedIDs.sorted().joined(separator: ",")
        celebrationQueue = newlyUnlocked
        advanceCelebration()
    }

    // MARK: - Hero

    private func heroSection(_ aggregates: ProfileHubAggregates) -> some View {
        let descriptors = aggregates.topDescriptors
        #if DEBUG
        ProfileHubAggregateProbe.recordHeroDescriptors(store: store, descriptors)
        #endif
        let name = effectiveName()

        return Button {
            isEditingProfile = true
        } label: {
            HStack(alignment: .center, spacing: 14) {
                avatarCircle(name: name, hue: avatarHue >= 0 ? avatarHue : nil, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if descriptors.isEmpty {
                        Text(L(.doneLearningWhoYouAre))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(descriptors.joined(separator: " · "))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: - Now

    @ViewBuilder
    private func nowSection(_ aggregates: ProfileHubAggregates) -> some View {
        let waitingCount = aggregates.waitingWannaCount
        let toReviewCount = aggregates.unreviewedCount

        if waitingCount > 0 || toReviewCount > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                sectionHeader("Now")
                    .padding(.top, 4)

                if waitingCount > 0 {
                    Button {
                        // Wanna tab is temporarily removed; route to calendar.
                        selectedTab = .calendar
                    } label: {
                        NowRow(
                            icon: "sparkles",
                            tint: .orange,
                            title: "\(waitingCount) wanna\(waitingCount == 1 ? "" : "s") waiting",
                            subtitle: "Push to calendar when ready"
                        )
                    }
                    .buttonStyle(.plain)
                }

                if toReviewCount > 0 {
                    NowRow(
                        icon: "circle.dotted.circle",
                        tint: .blue,
                        title: "\(toReviewCount) event\(toReviewCount == 1 ? "" : "s") to review",
                        subtitle: "Past 7 days, no log yet"
                    )
                }
            }
        }
    }

    // MARK: - This Week

    private func thisWeekSection(_ aggregates: ProfileHubAggregates) -> some View {
        let doneCount = aggregates.weekDoneCount
        let allAllocations = aggregates.weekAllocations
        let allDaily = aggregates.weekDaily
        let activeHours = aggregates.activeWeekHours
        let weekStart = weekViewModel.dateRange.start
        // Captures the already-parsed SET. The old form re-split the raw
        // settings string on every heatmap cell and every bar segment.
        let backgroundTypes = aggregates.backgroundTypes
        let bgPredicate: (String) -> Bool = { MeBackgroundTypes.contains($0, in: backgroundTypes) }

        return VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack(alignment: .firstTextBaseline) {
                sectionHeader(L(.thisWeek))
                Spacer(minLength: 12)
                shareButton(
                    totalHours: activeHours,
                    doneCount: doneCount,
                    daily: allDaily,
                    weekStart: weekStart,
                    descriptors: aggregates.topDescriptors,
                    isBackground: bgPredicate
                )
            }
            .padding(.top, 4)

            // Stats + heatmap + stacked bar are tappable as a unit, leading
            // to the rich weekly analysis page. The chevron in the corner
            // signals affordance.
            NavigationLink {
                WeeklyAnalysisDetailView()
                    .environmentObject(store)
                    .environmentObject(skillStore)
            } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(String(format: "%.1fh", activeHours))
                                    .font(.system(size: 28, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                                Text(L(.weekActive))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.tertiary)
                                    .baselineOffset(2)
                                Text("·")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.tertiary)
                                Text(String(format: L(.weekDoneCountFormat), doneCount))
                                    .font(.system(size: 17))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 10)
                    }

                    WeekHeatmapView(daily: allDaily, weekStart: weekStart, isBackground: bgPredicate)
                        .padding(.top, 4)

                    if !allAllocations.isEmpty {
                        TypeStackedBar(allocations: allAllocations, isBackground: bgPredicate)
                            .padding(.top, 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ReflectionPromptField()
                .padding(.top, 6)
        }
    }

    private func shareButton(
        totalHours: Double,
        doneCount: Int,
        daily: [DailyHours],
        weekStart: Date,
        descriptors: [String],
        isBackground: @escaping (String) -> Bool
    ) -> some View {
        // `descriptors` is threaded in rather than recomputed: this is called
        // from `thisWeekSection`, which the hero section has already paid the
        // 30-day type reduction for once this pass (gh#214).
        #if DEBUG
        ProfileHubAggregateProbe.recordShareDescriptors(store: store, descriptors)
        #endif
        let card = WeeklyShareCard(
            name: effectiveName(),
            descriptors: descriptors,
            hue: avatarHue >= 0 ? avatarHue : nil,
            totalHours: totalHours,
            doneCount: doneCount,
            daily: daily,
            weekStart: weekStart,
            weekLabel: weekViewModel.periodLabel,
            isBackground: isBackground
        )
        return Button {
            isShowingWeeklyShare = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                Text(L(.toolShare))
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isShowingWeeklyShare) {
            WeeklyShareSheet(card: card) {
                isShowingWeeklyShare = false
            }
            .presentationDetents([.large])
        }
    }

    @MainActor
    static func renderWeeklyShareImage(_ card: WeeklyShareCard) -> UIImage? {
        let renderer = ImageRenderer(content: card.frame(width: WeeklyShareCard.cardSize.width, height: WeeklyShareCard.cardSize.height))
        renderer.scale = 3
        return renderer.uiImage
    }

    // MARK: - Connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            sectionHeader("Connections")
                .padding(.top, 4)
            NavigationLink {
                ConnectionsView()
                    .environmentObject(authService)
            } label: {
                MCPMonitorCard()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Personality

    private var personalityProfile: PersonalityProfile? {
        guard let data = personalityRaw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PersonalityProfile.self, from: data)
    }

    @ViewBuilder
    private var personalitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader(L(.personality))
                Spacer()
                if personalityProfile != nil, PersonalityTagsService.isConfigured, !isLoadingPersonality {
                    Button { loadPersonality() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)

            personalityContent
        }
        .task(id: appLanguage) {
            regeneratePersonalityIfLanguageChanged()
        }
    }

    /// When the app language changes, a cached profile generated in the old
    /// language (or one with no language stamp) is stale. Regenerate it so the
    /// headline, tags, and summary follow the current language. Skips if a key
    /// isn't configured, a regeneration is already running, or the cache
    /// already matches.
    private func regeneratePersonalityIfLanguageChanged() {
        guard PersonalityTagsService.isConfigured,
              !isLoadingPersonality,
              let profile = personalityProfile,
              profile.language != appLanguage else { return }
        loadPersonality()
    }

    @ViewBuilder
    private var personalityContent: some View {
        if isLoadingPersonality {
            HStack(spacing: 10) {
                ProgressView()
                Text(L(.personalityGenerating))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else if let profile = personalityProfile {
            VStack(alignment: .leading, spacing: 10) {
                Text(profile.headline)
                    .font(.system(size: 20, weight: .bold))
                if !profile.tags.isEmpty {
                    PersonalityFlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(profile.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.purple.opacity(0.14), in: Capsule())
                                .foregroundStyle(.purple)
                        }
                    }
                }
                if !profile.summary.isEmpty {
                    Text(profile.summary)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if personalityFailed {
                    Text(personalityErrorMessage ?? L(.personalityFailed))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if PersonalityTagsService.isConfigured {
                    Button { loadPersonality() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text(L(.personalityGenerate))
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .contentShape(Capsule())
                        .background(Color.black.opacity(0.001), in: Capsule())
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(L(.personalityConfigureHint))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func loadPersonality() {
        guard !isLoadingPersonality else { return }
        isLoadingPersonality = true
        personalityFailed = false
        personalityErrorMessage = nil
        Task {
            do {
                let profile = try await personalityService.generate(store: store, skillStore: skillStore)
                let raw = (try? JSONEncoder().encode(profile)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                await MainActor.run {
                    personalityRaw = raw
                    isLoadingPersonality = false
                }
            } catch {
                let message = Self.personalityErrorText(error)
                await MainActor.run {
                    personalityErrorMessage = message
                    personalityFailed = true
                    isLoadingPersonality = false
                }
            }
        }
    }

    /// Humanizes an LLM failure so the card can show the real reason (e.g.
    /// "Insufficient Balance") rather than a generic message.
    private static func personalityErrorText(_ error: Error) -> String? {
        guard let llm = error as? LLMError else { return nil }
        switch llm {
        case .apiError(let status, let body):
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let message = err["message"] as? String, !message.isEmpty {
                return "\(message) (\(status))"
            }
            return "API error \(status)"
        case .noAPIKey:
            return nil
        case .invalidResponse:
            return "Invalid response from the AI provider."
        case .visionUnsupported:
            return nil
        }
    }

    // MARK: - Recently Earned

    @ViewBuilder
    private func recentlyEarnedSection(_ aggregates: ProfileHubAggregates) -> some View {
        let recent = aggregates.recentlyEarned

        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    sectionHeader(L(.recentlyEarned))
                    Spacer()
                    NavigationLink {
                        TrophyView()
                            .environmentObject(store)
                            .environmentObject(skillStore)
                    } label: {
                        HStack(spacing: 2) {
                            Text(L(.seeAll))
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
                VStack(spacing: 8) {
                    ForEach(Array(recent), id: \.id) { achievement in
                        AchievementRow(achievement: achievement)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func avatarCircle(name: String, hue overrideHue: Double?, size: CGFloat) -> some View {
        // Touch avatarVersion so SwiftUI re-renders this view (and reloads
        // the image from disk) whenever the user updates their photo.
        let _ = avatarVersion
        let image = MeAvatarStore.load()
        let initial = name.first.map(String.init)?.uppercased() ?? "?"
        let hue = overrideHue ?? (Double(abs(name.hashValue) % 360) / 360.0)
        return ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(LinearGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.55, brightness: 0.78),
                            Color(hue: hue, saturation: 0.65, brightness: 0.55)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func effectiveName() -> String {
        if !displayName.isEmpty { return displayName }
        return fallbackNameFromAuth()
    }

    private func knownTypeNames() -> [String] {
        // Fix Watch witness: the sheet's content closure evaluates only
        // while the sheet is up on the Me tab, so `isActiveTab` IS this
        // reduction's visibility answer (see `MeAggregateWitness`).
        MeAggregateWitness.note(visible: isActiveTab)
        #if DEBUG
        ProfileHubAggregateProbe.recordTypeList(store: store)
        #endif
        // canvasRenderableCalendarEvents (= raw minus absorbed todos):
        // an absorbed `.todo` keeps its own type + timeRanges, so it
        // would otherwise add its hours to its own type bucket on top
        // of the parent event already adding to the parent's type.
        return calendarProjectedTypeHours(
            events: store.canvasRenderableCalendarEvents,
            calendar: .current
        )
        .sorted { $0.value > $1.value }
        .map { $0.key }
    }

    private func fallbackNameFromAuth() -> String {
        if let email = authService.session?.user.email {
            let base = String(email.split(separator: "@").first ?? Substring(email))
            guard !base.isEmpty else { return L(.tabMe) }
            return base.prefix(1).capitalized + base.dropFirst()
        }
        return L(.tabMe)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }

}

// MARK: - Shared type-hour reduction

/// Hours-by-type reduction shared by the Me page (`ProfileHubView`'s
/// `knownTypeNames`/`topDescriptors`) and the personality-summary builder
/// (`PersonalityTagsService.typeDistribution`). Render-frame ranges, not raw
/// storage: a traveled detached exception instance is drawn on its nominal
/// day, so its hours must land in the window of the instant the canvas
/// draws, not the stored mint-frame instant a whole frame away (gh#204; the
/// same decision as `ReportStatsBuilder.expandOccurrences`, gh#187). A free
/// function per the `calendar*` idiom so both consumers — and the tests —
/// bind one reduction.
func calendarProjectedTypeHours(
    events: [Event],
    window: ClosedRange<Date>? = nil,
    isBackground: (String) -> Bool = { _ in false },
    calendar: Calendar
) -> [String: Double] {
    var hoursByType: [String: Double] = [:]
    for event in events {
        let type = event.type.isEmpty ? "Other" : event.type
        if isBackground(type) { continue }
        for range in event.renderTimeRanges(calendar: calendar) {
            var lo = range.start
            var hi = range.end
            if let window {
                if hi < window.lowerBound || lo > window.upperBound { continue }
                lo = max(lo, window.lowerBound)
                hi = min(hi, window.upperBound)
            }
            hoursByType[type, default: 0] += max(0, hi.timeIntervalSince(lo)) / 3600
        }
    }
    return hoursByType
}

// MARK: - Week Heatmap

private struct WeekHeatmapView: View {
    let daily: [DailyHours]
    let weekStart: Date
    let isBackground: (String) -> Bool

    private let cellHeight: CGFloat = 48

    var body: some View {
        let calendar = Calendar.current
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
        let aggregated = aggregateByDay()
        let weekMaxTotal = aggregated.values.map(\.totalHours).max() ?? 1

        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    let key = calendar.startOfDay(for: day)
                    let entry = aggregated[key]
                    DayHeatmapCell(
                        totalHours: entry?.totalHours ?? 0,
                        segments: entry?.segments ?? [],
                        weekMax: weekMaxTotal,
                        cellHeight: cellHeight
                    )
                }
            }
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    Text(weekdayLabel(for: day))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func aggregateByDay() -> [Date: (totalHours: Double, segments: [DaySegment])] {
        let calendar = Calendar.current
        var byDay: [Date: [String: (hours: Double, color: Color)]] = [:]
        for entry in daily {
            let key = calendar.startOfDay(for: entry.date)
            var bucket = byDay[key, default: [:]]
            var (hours, color) = bucket[entry.type] ?? (0, entry.color)
            hours += entry.hours
            color = entry.color
            bucket[entry.type] = (hours, color)
            byDay[key] = bucket
        }
        var result: [Date: (totalHours: Double, segments: [DaySegment])] = [:]
        for (day, types) in byDay {
            let total = types.values.reduce(0) { $0 + $1.hours }
            let bgSegs = types
                .filter { isBackground($0.key) }
                .map { DaySegment(type: $0.key, hours: $0.value.hours, color: $0.value.color, isBackground: true) }
                .sorted { $0.hours > $1.hours }
            let activeSegs = types
                .filter { !isBackground($0.key) }
                .map { DaySegment(type: $0.key, hours: $0.value.hours, color: $0.value.color, isBackground: false) }
                .sorted { $0.hours > $1.hours }
            // background renders at top of fill (fades upward), active anchors at bottom (visible)
            result[day] = (total, bgSegs + activeSegs)
        }
        return result
    }

    private func weekdayLabel(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current.locale
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: day)
    }
}

private struct DaySegment: Identifiable {
    let id = UUID()
    let type: String
    let hours: Double
    let color: Color
    let isBackground: Bool
}

private struct DayHeatmapCell: View {
    let totalHours: Double
    let segments: [DaySegment]
    let weekMax: Double
    let cellHeight: CGFloat

    var body: some View {
        let fillFraction = weekMax > 0 ? min(1.0, totalHours / weekMax) : 0
        let fillHeight = cellHeight * fillFraction

        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.gray.opacity(0.08))

            if totalHours > 0 {
                VStack(spacing: 0) {
                    ForEach(segments) { seg in
                        Rectangle()
                            .fill(seg.color.opacity(seg.isBackground ? 0.32 : 0.95))
                            .frame(height: fillHeight * (seg.hours / totalHours))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: cellHeight)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
        )
    }
}

// MARK: - Type Stacked Bar

private struct TypeStackedBar: View {
    let allocations: [TypeAllocation]
    let isBackground: (String) -> Bool
    private let displayLimit = 6

    var body: some View {
        let top = Array(allocations.prefix(displayLimit))
        let total = top.reduce(0) { $0 + $1.hours }

        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(top) { alloc in
                        let frac = total > 0 ? alloc.hours / total : 0
                        let width = max(0, geo.size.width * frac - 2)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(alloc.color.opacity(isBackground(alloc.type) ? 0.35 : 0.95))
                            .frame(width: width)
                    }
                }
            }
            .frame(height: 8)

            FlowingTags(items: top, isBackground: isBackground)
        }
    }
}

private struct FlowingTags: View {
    let items: [TypeAllocation]
    let isBackground: (String) -> Bool

    var body: some View {
        // Flow layout so the whole dot+label item wraps to the next line when
        // it doesn't fit; lineLimit(1) + fixedSize keep each label on one line
        // instead of breaking inside a word ("Housewor" / "k").
        PersonalityFlowLayout(spacing: 10, lineSpacing: 6) {
            ForEach(items) { alloc in
                let bg = isBackground(alloc.type)
                HStack(spacing: 5) {
                    Circle()
                        .fill(alloc.color.opacity(bg ? 0.35 : 1.0))
                        .frame(width: 6, height: 6)
                    Text(alloc.type)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(bg ? .tertiary : .secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }
}

// MARK: - Reflection Prompt

private struct ReflectionPromptField: View {
    @State private var draft: String = ""
    @State private var saved: Bool = false
    @AppStorage(AppSettingsKeys.meReflectionLog) private var log: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
            if saved {
                Text(L(.savedConfirmation))
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            } else {
                TextField(L(.reflectionPrompt), text: $draft)
                    .font(.system(size: 14))
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit { persist() }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.001), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func persist() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        log = log.isEmpty ? "\(stamp)\t\(trimmed)" : log + "\n\(stamp)\t\(trimmed)"
        draft = ""
        isFocused = false
        withAnimation(.easeInOut(duration: 0.25)) { saved = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) { saved = false }
            }
        }
    }
}

// MARK: - MCP Monitor Card

private struct MCPMonitorCard: View {
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                Image(systemName: "link")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.purple)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text("Claude")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L(.canReadLast7Days))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

// MARK: - Achievements

struct Achievement: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let unlocked: Bool
    let unlockedAt: Date?
    let progress: Double
    let progressLabel: String
}

enum AchievementCatalog {
    static func compute(store: EventStore, skillStore: SkillInsightStore, visible: Bool) -> [Achievement] {
        MeAggregateWitness.note(visible: visible)
        let completed = store.events
            .filter { $0.status == .completed && $0.completeAt != nil }
            .sorted { ($0.completeAt ?? .distantPast) < ($1.completeAt ?? .distantPast) }
        let count = completed.count

        var items: [Achievement] = []

        // First Done
        items.append(makeFirstDone(completed: completed))

        // Done milestones
        for milestone in [10, 100, 1000] {
            items.append(makeDoneMilestone(milestone: milestone, completed: completed, count: count))
        }

        // Skills
        let insights = skillStore.insights.sorted { $0.date < $1.date }
        let distinctSkills = Set(insights.map(\.skillName))
        for milestone in [1, 5, 10] {
            items.append(makeSkillMilestone(milestone: milestone, insights: insights, distinct: distinctSkills))
        }

        // Type variety.  canvasRenderableCalendarEvents: an absorbed
        // `.todo` whose type differs from its parent would otherwise
        // inflate the achievement's distinct-type count, unlocking a
        // milestone for variety the user didn't actually canvas-create.
        let distinctTypes = Set(store.canvasRenderableCalendarEvents.map { $0.type.isEmpty ? "Other" : $0.type })
        let zhTypes = AppLanguage.current == .chinese
        for milestone in [3, 10] {
            let unlocked = distinctTypes.count >= milestone
            items.append(Achievement(
                id: "types_\(milestone)",
                title: zhTypes
                    ? (milestone == 3 ? "丰富多彩" : "\(milestone) 种类型")
                    : (milestone == 3 ? "Variety" : "\(milestone) Types"),
                subtitle: zhTypes
                    ? "记录了 \(milestone) 种不同类型的活动"
                    : "\(milestone) different types of activity",
                icon: "circle.grid.3x3.fill",
                unlocked: unlocked,
                unlockedAt: nil,
                progress: min(1, Double(distinctTypes.count) / Double(milestone)),
                progressLabel: "\(distinctTypes.count) / \(milestone)"
            ))
        }

        // Hidden easter eggs — only ever appear once earned, so there's no
        // locked "0 / 1" goal nagging the user beforehand.
        var hiddenEarned = 0
        // Both builders read the canvas-renderable population (absorbed todos
        // fold into their parents) with wall-clock and frame injected HERE —
        // in events/logs/calendar/now the builders are pure functions. One
        // ambient read remains inside: `AppLanguage.current`, which only
        // picks display strings (tests assert on ids and dates) (gh#204).
        if let festive = makeFestive(
            events: store.canvasRenderableCalendarEvents,
            logs: store.calendarEventLogRecords,
            calendar: Calendar.current,
            now: Date()
        ) {
            items.append(festive)
            hiddenEarned += 1
        }
        let funny = makeFunnyHiddenAchievements(
            events: store.canvasRenderableCalendarEvents,
            logs: store.calendarEventLogRecords,
            calendar: Calendar.current,
            now: Date()
        )
        items.append(contentsOf: funny)
        hiddenEarned += funny.count

        // Meta "collector" capstone for finding several hidden ones.
        if hiddenEarned >= 3 {
            let zh = AppLanguage.current == .chinese
            items.append(Achievement(
                id: "hidden_collector",
                title: zh ? "彩蛋猎人" : "Easter Egg Hunter",
                subtitle: zh ? "已发现 \(hiddenEarned) 个隐藏成就" : "Found \(hiddenEarned) hidden achievements",
                icon: "sparkles",
                unlocked: true,
                unlockedAt: nil,
                progress: 1,
                progressLabel: ""
            ))
        }

        return items
    }

    /// Tongue-in-cheek hidden achievements derived from quirky patterns in the
    /// user's calendar. Each only appears once its condition is met (returns
    /// only earned ones), so they read as collectible surprises. Bilingual.
    static func makeFunnyHiddenAchievements(
        events: [Event],
        logs: [CalendarEventLogRecord],
        calendar: Calendar,
        now: Date
    ) -> [Achievement] {
        let oneYearOut = calendar.date(byAdding: .year, value: 1, to: now) ?? now
        // Render-frame ranges, not raw storage (gh#204): a traveled detached
        // instance contributes the instant the canvas draws it on — the
        // weekday/day-set patterns below re-bucket across a frame change
        // otherwise.
        let ranges = events.flatMap { $0.renderTimeRanges(calendar: calendar) }
        let zh = AppLanguage.current == .chinese

        var result: [Achievement] = []
        func add(_ id: String, _ en: String, _ zhT: String, _ enSub: String, _ zhSub: String, _ icon: String, _ date: Date?) {
            result.append(Achievement(
                id: id,
                title: zh ? zhT : en,
                subtitle: zh ? zhSub : enSub,
                icon: icon,
                unlocked: true,
                unlockedAt: date,
                progress: 1,
                progressLabel: ""
            ))
        }

        // Night Owl — an event starting between midnight and 5am.
        if let r = ranges.first(where: { calendar.component(.hour, from: $0.start) < 5 }) {
            add("hidden_night_owl", "Night Owl", "夜猫子",
                "Scheduled something after midnight. Sleep is merely a suggestion.",
                "凌晨还在安排日程，睡觉对你只是个建议。", "moon.stars.fill", r.start)
        }
        // Marathoner — a single event 8h or longer.
        if let r = ranges.first(where: { $0.end.timeIntervalSince($0.start) >= 8 * 3600 }) {
            add("hidden_marathon", "Marathoner", "马拉松选手",
                "One event, eight hours straight. We're not worthy.",
                "一件事干了整整八小时，失敬失敬。", "figure.run", r.start)
        }
        // Blink and you'll miss it — a 0–5 minute event.
        if let r = ranges.first(where: { let d = $0.end.timeIntervalSince($0.start); return d > 0 && d <= 300 }) {
            add("hidden_blink", "Blink and Miss It", "一眨眼",
                "A five-minute event. Did it even happen?",
                "五分钟的日程，这也好意思叫一件事？", "bolt.fill", r.start)
        }
        // Time Traveler — an event scheduled over a year out.
        if ranges.contains(where: { $0.start > oneYearOut }) {
            add("hidden_time_traveler", "Time Traveler", "时间旅行者",
                "Planned something over a year ahead. Bold of you.",
                "一年多以后的事都安排上了，真有远见。", "clock.arrow.2.circlepath", nil)
        }
        // Clone Needed — 3+ events overlapping at the same instant.
        if maxConcurrency(ranges) >= 3 {
            add("hidden_clone", "Clone Needed", "分身乏术",
                "Three things at once. Time to order a clone.",
                "同一时刻三件事，建议下单一个克隆人。", "person.3.fill", nil)
        }
        // Weekend Warrior — events on both a Saturday and a Sunday.
        let weekdays = Set(ranges.map { calendar.component(.weekday, from: $0.start) })
        if weekdays.contains(7), weekdays.contains(1) {
            add("hidden_weekend", "Weekend Warrior", "周末战士",
                "Booked solid on Saturday AND Sunday. Rest is a myth.",
                "周六周日都排满了，休息是不存在的。", "calendar.badge.exclamationmark", nil)
        }

        // ── Pop-culture tie-ins ──────────────────────────────────────────

        // It's Over 9000! (Dragon Ball) — an event longer than 9000 seconds.
        if let r = ranges.first(where: { $0.end.timeIntervalSince($0.start) > 9000 }) {
            add("hidden_over9000", "It's Over 9000!", "战斗力超过九千",
                "This event's power level is OVER NINE THOUSAND!",
                "这件事的战斗力……竟然超过九千了！", "flame.fill", r.start)
        }
        // Groundhog Day — a daily-recurring event.
        if events.contains(where: { $0.repeatUnit == .day }) {
            add("hidden_groundhog", "Groundhog Day", "土拨鼠之日",
                "A daily repeat. Again? Same day, every day.",
                "每天重复的日程。又是一模一样的一天。", "arrow.triangle.2.circlepath", nil)
        }
        // May the 4th (Star Wars) — an event on May 4.
        if let r = ranges.first(where: {
            let c = calendar.dateComponents([.month, .day], from: $0.start)
            return c.month == 5 && c.day == 4
        }) {
            add("hidden_may4", "May the 4th", "星战日",
                "Something on May 4th. May the Force be with you.",
                "5月4日有安排。愿原力与你同在。", "sparkles", r.start)
        }
        // Platform 9¾ (Harry Potter) — an event starting at 9:45.
        if let r = ranges.first(where: {
            let c = calendar.dateComponents([.hour, .minute], from: $0.start)
            return c.hour == 9 && c.minute == 45
        }) {
            add("hidden_platform934", "Platform 9¾", "九又四分之三站台",
                "A 9:45 start. Just run straight at the wall.",
                "9:45 开始。对着墙跑过去就行。", "tram.fill", r.start)
        }
        // The Long Voyage (One Piece) — events spanning over a year apart.
        let starts = ranges.map(\.start)
        if let earliest = starts.min(), let latest = starts.max(),
           latest.timeIntervalSince(earliest) > 365 * 86400 {
            add("hidden_voyage", "The Grand Voyage", "伟大航路",
                "Your records span over a year. A long adventure indeed.",
                "你的记录跨越了一年多，这是一场漫长的伟大航路。", "sailboat.fill", nil)
        }
        // Total Concentration (Demon Slayer) — a max-effort log.
        if logs.contains(where: { ($0.effort ?? 0) >= 5 }) {
            add("hidden_concentration", "Total Concentration", "全集中呼吸",
                "Logged an activity at maximum effort. Breathe!",
                "记录了一次投入度拉满的活动。全集中·常中！", "wind", nil)
        }
        // Let It Go (Frozen) — a skipped log.
        if logs.contains(where: { $0.completionStatus == .skipped }) {
            add("hidden_letitgo", "Let It Go", "随它吧",
                "You skipped one and logged it. And that's okay.",
                "你放过了一件事，并记录了下来。随它吧～", "snowflake", nil)
        }
        // Shadow Clone Jutsu (Naruto) — 5+ events overlapping at once.
        if maxConcurrency(ranges) >= 5 {
            add("hidden_shadowclone", "Shadow Clone Jutsu", "影分身之术",
                "Five things at the same time — now that's a jutsu.",
                "同一时刻五件事，这已经是忍术了。", "person.3.sequence.fill", nil)
        }
        // Coach, I Want to Play (Slam Dunk) — an Exercise-type event.
        if let r = events.first(where: { $0.type.lowercased() == "exercise" })?.renderPrimaryTimeRange(calendar: calendar) {
            add("hidden_slamdunk", "Coach, I Want to Play", "教练，我想打篮球",
                "Logged exercise. The whole team believes in you.",
                "记录了运动。教练，我想打篮球……", "figure.basketball", r.start)
        }

        // ── Habit rewards (sleep / exercise) ─────────────────────────────
        // Well Rested — a single sleep event of 8 hours or more.
        if let r = events.filter({ isSleepType($0.type) }).flatMap({ $0.renderTimeRanges(calendar: calendar) })
            .first(where: { $0.end.timeIntervalSince($0.start) >= 8 * 3600 }) {
            add("hidden_well_rested", "Well Rested", "睡饱了",
                "A full eight hours of sleep. Rare and glorious.",
                "睡满了整整八小时，难得又奢侈。", "bed.double.fill", r.start)
        }
        // Steady Sleeper — slept on 3+ consecutive days (a rhythm, any hour).
        let sleepDays = Set(events.filter { isSleepType($0.type) }
            .flatMap { $0.renderTimeRanges(calendar: calendar) }.map { calendar.startOfDay(for: $0.start) })
        if maxConsecutiveDayRun(sleepDays, calendar: calendar) >= 3 {
            add("hidden_steady_sleep", "Steady Sleeper", "作息规律",
                "Slept three days running. A rhythm, finally.",
                "连续三天都按时睡了，作息总算规律起来了。", "moon.zzz.fill", nil)
        }
        // Three-Day Streak — exercised on 3+ consecutive days.
        let exerciseDays = Set(events.filter { isExerciseType($0.type) }
            .flatMap { $0.renderTimeRanges(calendar: calendar) }.map { calendar.startOfDay(for: $0.start) })
        if maxConsecutiveDayRun(exerciseDays, calendar: calendar) >= 3 {
            add("hidden_workout_streak", "Three-Day Streak", "运动三连",
                "Worked out three days in a row. Momentum!",
                "连续三天运动健身，势头来了！", "figure.run.circle.fill", nil)
        }
        // Square Meals — AI-recognized meal photos on 3+ consecutive days
        // (the "did I eat on time" reward; meals are identified by the photo
        // analysis rather than a fixed clock).
        let mealDays = Set(logs.flatMap { $0.timelineItems }
            .compactMap { $0.noteValue }
            .filter { $0.mealAnalysis != nil }
            .map { calendar.startOfDay(for: $0.createdAt) })
        if maxConsecutiveDayRun(mealDays, calendar: calendar) >= 3 {
            add("hidden_regular_meals", "Square Meals", "按时吃饭",
                "Logged a meal three days running. Your body says thanks.",
                "连续三天都好好吃饭（还拍了照），身体会感谢你的。", "fork.knife", nil)
        }

        return result
    }

    /// Maximum number of time ranges overlapping at any instant (sweep line).
    private static func maxConcurrency(_ ranges: [Event.TimeRange]) -> Int {
        var points: [(Date, Int)] = []
        for r in ranges where r.end > r.start {
            points.append((r.start, 1))
            points.append((r.end, -1))
        }
        points.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var current = 0
        var best = 0
        for (_, delta) in points {
            current += delta
            best = max(best, current)
        }
        return best
    }

    /// Type-name heuristics for habit achievements — the `type` is a freeform
    /// user string, so match the seed names plus common synonyms (EN + 中文).
    private static func isSleepType(_ type: String) -> Bool {
        let t = type.lowercased()
        return t.contains("sleep") || t.contains("nap") || type.contains("睡") || type.contains("午休")
    }

    private static func isExerciseType(_ type: String) -> Bool {
        let t = type.lowercased()
        return t.contains("exercise") || t.contains("workout") || t.contains("gym")
            || t.contains("fitness") || type.contains("运动") || type.contains("健身") || type.contains("锻炼")
    }

    /// Longest run of calendar-consecutive days present in `dayStarts` (each a
    /// `startOfDay`). Used by the "N days in a row" habit rewards.
    private static func maxConsecutiveDayRun(_ dayStarts: Set<Date>, calendar: Calendar) -> Int {
        let sorted = dayStarts.sorted()
        guard !sorted.isEmpty else { return 0 }
        var best = 1
        var run = 1
        for i in 1..<sorted.count {
            if let next = calendar.date(byAdding: .day, value: 1, to: sorted[i - 1]),
               calendar.isDate(next, inSameDayAs: sorted[i]) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
        }
        return best
    }

    /// Easter egg earned by spending a special day with the app — having any
    /// event scheduled on a holiday/solar-term date (today or in the past), or
    /// an explicit log record on one. Returns `nil` (hidden) until earned;
    /// counts distinct special days celebrated for flavor.
    static func makeFestive(
        events: [Event],
        logs: [CalendarEventLogRecord],
        calendar: Calendar,
        now: Date
    ) -> Achievement? {
        let todayStart = calendar.startOfDay(for: now)

        func dayKey(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
        }

        var distinctDays: Set<String> = []
        var earnedDates: [Date] = []

        // Any calendar event whose scheduled day is a special day and isn't in
        // the future (a day you've actually reached, not just planned ahead).
        // `events` is the canvas-renderable population — same source the
        // Variety badge counts. Render-frame ranges (gh#204): the special-day
        // test must run against the day the canvas draws the instance on.
        for event in events {
            for range in event.renderTimeRanges(calendar: calendar) {
                guard calendar.startOfDay(for: range.start) <= todayStart else { continue }
                if CalendarAnnotations.hasAnyAnnotation(on: range.start, calendar: calendar) {
                    distinctDays.insert(dayKey(range.start))
                    earnedDates.append(event.completeAt ?? range.start)
                }
            }
        }

        // Explicit log records on a special day.
        for log in logs {
            if CalendarAnnotations.hasAnyAnnotation(on: log.occurrenceDate, calendar: calendar) {
                distinctDays.insert(dayKey(log.occurrenceDate))
                earnedDates.append(log.createdAt)
            }
        }

        let count = distinctDays.count
        guard count > 0 else { return nil }
        let zh = AppLanguage.current == .chinese
        return Achievement(
            id: "festive_spirit",
            title: zh ? "节日气氛" : "Festive Spirit",
            subtitle: zh
                ? "在 \(count) 个特别的日子里有安排"
                : "Active on \(count) special \(count == 1 ? "day" : "days")",
            icon: "gift.fill",
            unlocked: true,
            unlockedAt: earnedDates.min(),
            progress: 1,
            progressLabel: ""
        )
    }

    private static func makeFirstDone(completed: [Event]) -> Achievement {
        let zh = AppLanguage.current == .chinese
        if let first = completed.first {
            return Achievement(
                id: "first_done",
                title: zh ? "首次完成" : "First Done",
                subtitle: zh ? "完成了你的第一件事" : "Completed your first event",
                icon: "checkmark.seal.fill",
                unlocked: true,
                unlockedAt: first.completeAt,
                progress: 1,
                progressLabel: ""
            )
        }
        return Achievement(
            id: "first_done",
            title: zh ? "首次完成" : "First Done",
            subtitle: zh ? "完成你的第一件事" : "Complete your first event",
            icon: "checkmark.seal",
            unlocked: false,
            unlockedAt: nil,
            progress: 0,
            progressLabel: "0 / 1"
        )
    }

    private static func makeDoneMilestone(milestone: Int, completed: [Event], count: Int) -> Achievement {
        let unlocked = count >= milestone
        let date = unlocked ? completed[milestone - 1].completeAt : nil
        let zh = AppLanguage.current == .chinese
        return Achievement(
            id: "done_\(milestone)",
            title: zh ? "完成 \(milestone) 件" : "\(milestone) Done",
            subtitle: zh ? "已完成 \(milestone) 件事" : "\(milestone) events completed",
            icon: unlocked ? "checkmark.circle.fill" : "checkmark.circle",
            unlocked: unlocked,
            unlockedAt: date,
            progress: min(1, Double(count) / Double(milestone)),
            progressLabel: "\(count) / \(milestone)"
        )
    }

    private static func makeSkillMilestone(milestone: Int, insights: [SkillInsight], distinct: Set<String>) -> Achievement {
        let unlocked = distinct.count >= milestone
        var unlockDate: Date? = nil
        if unlocked {
            var seen: Set<String> = []
            for insight in insights {
                if seen.insert(insight.skillName).inserted, seen.count == milestone {
                    unlockDate = insight.date
                    break
                }
            }
        }
        let zh = AppLanguage.current == .chinese
        return Achievement(
            id: "skills_\(milestone)",
            title: zh
                ? (milestone == 1 ? "首个技能" : "\(milestone) 个技能")
                : (milestone == 1 ? "First Skill" : "\(milestone) Skills"),
            subtitle: zh
                ? "已追踪 \(milestone) 个不同技能"
                : "\(milestone) different skills tracked",
            icon: unlocked ? "sparkles" : "sparkles",
            unlocked: unlocked,
            unlockedAt: unlockDate,
            progress: min(1, Double(distinct.count) / Double(milestone)),
            progressLabel: "\(distinct.count) / \(milestone)"
        )
    }
}

private struct AchievementRow: View {
    let achievement: Achievement

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.yellow.opacity(0.18))
                Image(systemName: achievement.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(achievement.title)
                    .font(.system(size: 14, weight: .semibold))
                if let date = achievement.unlockedAt {
                    Text(relativeDateString(from: date))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func relativeDateString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Flow Layout

/// A minimal wrapping layout: lays children left-to-right, wrapping to a new
/// line when the row is full. Used for the personality tag chips.
struct PersonalityFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Achievement Unlock Reveal

/// The "achievement unlocked" hero reveal: the badge pops large in the center,
/// holds, then shrinks and drops toward its resting place below while fading.
/// Driven by `KeyframeAnimator` so it self-starts reliably (no onAppear race).
struct AchievementUnlockedView: View {
    let achievement: Achievement

    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let s = Self.state(at: t)
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.yellow, Color.orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: achievement.icon)
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 116, height: 116)
                .shadow(color: Color.orange.opacity(0.4), radius: 18, y: 8)

                VStack(spacing: 4) {
                    Text(L(.achievementUnlocked).uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                    Text(achievement.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.primary)
                }
            }
            .scaleEffect(s.scale)
            .offset(y: s.y)
            .opacity(s.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    /// Pop in (center) → settle → hold → shrink + drop + fade, as a pure
    /// function of elapsed time so it always plays (no onAppear/animation race).
    private static func state(at t: Double) -> (scale: CGFloat, y: CGFloat, opacity: CGFloat) {
        func smooth(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }
        func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }

        var scale = 1.0, y = 0.0, opacity = 1.0
        if t < 0.42 {                              // pop in
            let p = smooth(t / 0.42)
            scale = lerp(0.4, 1.14, p)
            opacity = min(1, t / 0.28)
        } else if t < 0.6 {                        // settle the overshoot
            scale = lerp(1.14, 1.0, smooth((t - 0.42) / 0.18))
        } else if t < 1.45 {                       // hold
            scale = 1.0
        } else {                                    // shrink + drop + fade
            let p = smooth(min(1, (t - 1.45) / 0.6))
            scale = lerp(1.0, 0.32, p)
            y = lerp(0, 300, p)
            opacity = 1 - min(1, (t - 1.45) / 0.6)
        }
        return (CGFloat(scale), CGFloat(y), CGFloat(opacity))
    }
}

// MARK: - Confetti

/// A full-screen "stage cannon" confetti burst shown when a badge unlocks.
/// Pieces launch upward from the bottom corners with horizontal spread, then
/// arc back down under gravity — a parabolic trajectory computed per frame
/// from elapsed time. Drawn with `Canvas` + `TimelineView(.animation)` so it's
/// immune to onAppear/withAnimation timing quirks. Deterministic per index.
struct ConfettiView: View {
    var pieceCount: Int = 170
    var duration: Double = 2.2

    /// Downward acceleration (points / second²).
    private let gravity: Double = 1750

    @State private var start = Date()
    private let palette: [Color] = [.red, .orange, .yellow, .green, .mint, .blue, .indigo, .purple, .pink]

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                let globalFade = elapsed > duration - 0.4
                    ? max(0, 1 - (elapsed - (duration - 0.4)) / 0.4)
                    : 1
                let floorY = Double(size.height) + 60

                for index in 0..<pieceCount {
                    // Alternate cannons: even from bottom-left, odd bottom-right.
                    let fromLeft = index % 2 == 0
                    let x0 = fromLeft ? -10.0 : Double(size.width) + 10
                    let y0 = Double(size.height) + 10

                    // Slight stagger so the burst isn't one instant.
                    let launch = elapsed - Double(Self.rand(index, 53)) * 0.16
                    guard launch > 0 else { continue }

                    let up = 1250 + Double(Self.rand(index, 37)) * 560        // upward speed
                    let spread = 120 + Double(Self.rand(index, 17)) * 520      // horizontal speed
                    let vx = fromLeft ? spread : -spread
                    let vy = -up

                    let x = x0 + vx * launch
                    let y = y0 + vy * launch + 0.5 * gravity * launch * launch
                    guard y < floorY else { continue }   // fallen off bottom → gone

                    let w = 9 + Double(Self.rand(index, 41)) * 9              // 9…18pt
                    let h = w * 0.5
                    let angle = launch * (3 + Double(Self.rand(index, 23)) * 6)

                    let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
                    let piece = Path(roundedRect: rect, cornerRadius: 2)
                    let transform = CGAffineTransform(translationX: x, y: y).rotated(by: angle)
                    context.fill(
                        piece.applying(transform),
                        with: .color(palette[index % palette.count].opacity(globalFade))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    /// Deterministic pseudo-random in [0, 1) from a piece index + salt.
    private static func rand(_ index: Int, _ salt: Int) -> CGFloat {
        let hashed = ((index &* 73856093) ^ (salt &* 19349663)) & 0x7fff_ffff
        return CGFloat(hashed % 10000) / 10000
    }
}

struct TrophyView: View {
    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var skillStore: SkillInsightStore
    /// gh#214 — pushed from the Me page's "see all" and kept alive there.
    @Environment(\.rootTabIsVisible) private var isTabVisible

    /// The whole catalogue is one pass over every event plus every skill
    /// insight. Nothing on this page pushes a destination, so an empty list
    /// while off screen collapses two sections that own nothing.
    private func currentAchievements() -> [Achievement] {
        guard isTabVisible else { return [] }
        #if DEBUG
        ProfileHubAggregateProbe.recordTrophy(store: store)
        #endif
        return AchievementCatalog.compute(store: store, skillStore: skillStore, visible: isTabVisible)
    }

    var body: some View {
        let achievements = currentAchievements()
        let unlocked = achievements
            .filter { $0.unlocked }
            .sorted { ($0.unlockedAt ?? .distantPast) > ($1.unlockedAt ?? .distantPast) }
        let locked = achievements
            .filter { !$0.unlocked }
            .sorted { $0.progress > $1.progress }

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !unlocked.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(L(.achievementUnlocked))
                        ForEach(unlocked) { TrophyCard(achievement: $0) }
                    }
                }
                if !locked.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader(L(.achievementsInProgress))
                        ForEach(locked) { TrophyCard(achievement: $0) }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(L(.trophies))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

private struct TrophyCard: View {
    let achievement: Achievement

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(achievement.unlocked ? Color.yellow.opacity(0.2) : Color.gray.opacity(0.12))
                Image(systemName: achievement.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(achievement.unlocked ? .orange : .secondary)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(achievement.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(achievement.unlocked ? .primary : .secondary)
                    Spacer(minLength: 0)
                    if achievement.unlocked, let date = achievement.unlockedAt {
                        Text(relativeDateString(from: date))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                }
                Text(achievement.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)

                if !achievement.unlocked {
                    HStack(spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.gray.opacity(0.15))
                                    .frame(height: 4)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.accentColor.opacity(0.7))
                                    .frame(width: max(0, geo.size.width * achievement.progress), height: 4)
                            }
                        }
                        .frame(height: 4)
                        Text(achievement.progressLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func relativeDateString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Now Row

private struct NowRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Profile Edit Sheet

private struct ProfileEditSheet: View {
    @Binding var displayName: String
    @Binding var avatarHue: Double
    @Binding var backgroundTypesRaw: String
    let fallbackName: String
    let allTypes: [String]
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettingsKeys.meAvatarVersion) private var avatarVersion: Int = 0
    @State private var draftName: String = ""
    @State private var draftHue: Double = 0
    @State private var draftBackground: Set<String> = []
    @State private var draftImage: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var didLoadInitialImage = false
    @State private var isPickerPresented = false
    @FocusState private var nameFocused: Bool

    private let presetHues: [Double] = [
        0.05, 0.10, 0.15,
        0.32, 0.50, 0.58,
        0.65, 0.78, 0.92
    ]

    var body: some View {
        NavigationStack {
            settingsPage(L(.editProfile)) {
                avatarPreview
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .padding(.bottom, 4)

                settingsCard(L(.name)) {
                    TextField(fallbackName, text: $draftName)
                        .focused($nameFocused)
                        .submitLabel(.done)
                }

                settingsCard(L(.color)) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 9), spacing: 10) {
                        ForEach(presetHues, id: \.self) { hue in
                            Button {
                                draftHue = hue
                            } label: {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: [
                                            Color(hue: hue, saturation: 0.55, brightness: 0.78),
                                            Color(hue: hue, saturation: 0.65, brightness: 0.55)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary, lineWidth: abs(draftHue - hue) < 0.001 ? 2 : 0)
                                    )
                                    .aspectRatio(1, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !allTypes.isEmpty {
                    settingsCard(L(.hideFromMeTab)) {
                        ForEach(allTypes, id: \.self) { type in
                            Toggle(isOn: Binding(
                                get: { draftBackground.contains(type.lowercased()) },
                                set: { newValue in
                                    if newValue {
                                        draftBackground.insert(type.lowercased())
                                    } else {
                                        draftBackground.remove(type.lowercased())
                                    }
                                }
                            )) {
                                Text(type)
                            }
                        }
                    }
                    settingsHintCard(L(.hintHideFromMe))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L(.cancel)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(.save)) {
                        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                        displayName = trimmed
                        avatarHue = draftHue
                        backgroundTypesRaw = draftBackground.sorted().joined(separator: ",")
                        // Persist avatar image
                        if let img = draftImage {
                            MeAvatarStore.save(img)
                        } else {
                            MeAvatarStore.delete()
                        }
                        avatarVersion &+= 1
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            draftName = displayName
            draftHue = avatarHue >= 0 ? avatarHue : presetHues.first!
            nameFocused = displayName.isEmpty
            // Same parse the Me page reads the setting with — a second copy
            // here is how the sheet's checkmarks and the page's exclusions
            // drift apart.
            draftBackground = MeBackgroundTypes.parse(backgroundTypesRaw)
            if !didLoadInitialImage {
                draftImage = MeAvatarStore.load()
                didLoadInitialImage = true
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run { draftImage = img }
                }
            }
        }
    }

    private var avatarPreview: some View {
        let name = draftName.isEmpty ? fallbackName : draftName
        let initial = name.first.map(String.init)?.uppercased() ?? "?"
        let hue = draftHue
        return Menu {
            Button {
                isPickerPresented = true
            } label: {
                Label(draftImage == nil ? L(.choosePhoto) : L(.replacePhoto), systemImage: "photo")
            }
            if draftImage != nil {
                Button(role: .destructive) {
                    draftImage = nil
                    pickerItem = nil
                } label: {
                    Label(L(.removePhoto), systemImage: "trash")
                }
            }
        } label: {
            ZStack {
                Group {
                    if let img = draftImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [
                                        Color(hue: hue, saturation: 0.55, brightness: 0.78),
                                        Color(hue: hue, saturation: 0.65, brightness: 0.55)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                            Text(initial)
                                .font(.system(size: 36, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: 88, height: 88)
                .clipShape(Circle())

                // Edit affordance — small camera badge at bottom-right
                Image(systemName: "camera.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                    .offset(x: 30, y: 30)
            }
            .frame(width: 88, height: 88)
        }
        .buttonStyle(.plain)
        .photosPicker(isPresented: $isPickerPresented, selection: $pickerItem, matching: .images)
    }
}

// MARK: - Weekly Share Card

struct WeeklyShareCard: View {
    let name: String
    let descriptors: [String]
    let hue: Double?
    let totalHours: Double
    let doneCount: Int
    let daily: [DailyHours]
    let weekStart: Date
    let weekLabel: String
    /// Background-type predicate. Used to fade non-active types in the
    /// heatmap and stacked bar so the visual matches the Me page exactly.
    /// Defaults to "nothing is background" for backwards-compat with any
    /// older call sites.
    var isBackground: (String) -> Bool = { _ in false }

    static let cardSize = CGSize(width: 360, height: 450)

    /// Roll daily data up into per-type totals for the stacked bar.
    private var allocations: [TypeAllocation] {
        var hoursByType: [String: (hours: Double, color: Color)] = [:]
        for entry in daily {
            var bucket = hoursByType[entry.type] ?? (0, entry.color)
            bucket.hours += entry.hours
            bucket.color = entry.color
            hoursByType[entry.type] = bucket
        }
        return hoursByType.map {
            TypeAllocation(type: $0.key, hours: $0.value.hours, color: $0.value.color)
        }
        .sorted { $0.hours > $1.hours }
    }

    var body: some View {
        let bgHue = hue ?? (Double(abs(name.hashValue) % 360) / 360.0)
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: bgHue, saturation: 0.20, brightness: 0.97),
                    Color(hue: bgHue, saturation: 0.40, brightness: 0.85)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    avatar(size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.85))
                        if !descriptors.isEmpty {
                            Text(descriptors.joined(separator: " · "))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.black.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L(.thisWeek).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.5))
                        .tracking(1.0)
                    Text(weekLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.black.opacity(0.55))
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(String(format: "%.1f", totalHours))
                        .font(.system(size: 56, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.black.opacity(0.9))
                    Text(L(.hours).lowercased())
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.black.opacity(0.55))
                    Spacer()
                }
                Text(String(format: L(.weekEventsCompletedFormat), doneCount))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.black.opacity(0.55))

                WeekHeatmapView(daily: daily, weekStart: weekStart, isBackground: isBackground)
                    .padding(.top, 4)

                if !allocations.isEmpty {
                    TypeStackedBar(allocations: allocations, isBackground: isBackground)
                        .padding(.top, 2)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Text("done")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.4))
                        .tracking(2.0)
                }
            }
            .padding(28)
        }
        .frame(width: 360, height: 450)
    }

    private func avatar(size: CGFloat) -> some View {
        let initial = name.first.map(String.init)?.uppercased() ?? "?"
        let avatarHue = hue ?? (Double(abs(name.hashValue) % 360) / 360.0)
        let image = MeAvatarStore.load()
        return ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(LinearGradient(
                        colors: [
                            Color(hue: avatarHue, saturation: 0.55, brightness: 0.78),
                            Color(hue: avatarHue, saturation: 0.65, brightness: 0.55)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

}

// MARK: - Weekly Analysis Detail (rich page reached from the "This week" card)

// TODO: build out a richer breakdown (daily list, per-type deltas vs last
// week, time-of-day distribution, top events, insights). For now this just
// hosts the existing AnalysisContentView so the tappable entry-point ships.
struct WeeklyAnalysisDetailView: View {
    var body: some View {
        AnalysisDetailView()
    }
}

// MARK: - Weekly Share Item (Transferable)

struct WeeklyShareItem: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            item.image.pngData() ?? Data()
        }
    }
}

// MARK: - Weekly Share Sheet

/// Preview-first share flow that matches the day/event share sheets:
/// shows a scaled card preview with a glass Share button at the bottom that
/// fires the actual ShareLink. Replaces the previous one-tap ShareLink which
/// jumped straight to the system share menu without preview context.
struct WeeklyShareSheet: View {
    let card: WeeklyShareCard
    let onDismiss: () -> Void

    var body: some View {
        let cardSize = WeeklyShareCard.cardSize

        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Text(L(.shareWeek))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    HStack {
                        Spacer()
                        Button {
                            onDismiss()
                        } label: {
                            Text(L(.done))
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .frame(height: 40)
                                .contentShape(Capsule())
                                .background(Color.black.opacity(0.001), in: Capsule())
                                .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                GeometryReader { proxy in
                    let topInset: CGFloat = 16
                    let shareEstimate: CGFloat = 48
                    let minSpacing: CGFloat = 14
                    let bottomInset: CGFloat = 12
                    let reserved = topInset + shareEstimate + minSpacing + bottomInset
                    let cardHeightBudget = max(0, proxy.size.height - reserved)
                    let cardWidthBudget = max(0, proxy.size.width - 24)
                    let scaleByHeight = cardSize.height > 0 ? cardHeightBudget / cardSize.height : 1
                    let scaleByWidth = cardWidthBudget / cardSize.width
                    let previewScale = min(scaleByHeight, scaleByWidth, 0.92)

                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 0) {
                                card
                                    .frame(width: cardSize.width, height: cardSize.height)
                                    .scaleEffect(previewScale)
                                    .frame(
                                        width: cardSize.width * previewScale,
                                        height: cardSize.height * previewScale
                                    )
                                    .shadow(color: Color.black.opacity(0.15), radius: 18, x: 0, y: 6)
                                    .padding(.top, topInset)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        if let image = ProfileHubView.renderWeeklyShareImage(card) {
                            let item = WeeklyShareItem(image: image)
                            ShareLink(
                                item: item,
                                preview: SharePreview("This week on Done", image: item)
                            ) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 15, weight: .semibold))
                                    Text(L(.toolShare))
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 20)
                                .frame(maxWidth: .infinity)
                                .frame(height: shareEstimate)
                                .contentShape(Capsule())
                                .background(Color.black.opacity(0.001), in: Capsule())
                                .glassEffect(.regular.interactive(), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 24)
                            .padding(.top, minSpacing)
                            .padding(.bottom, bottomInset)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}
