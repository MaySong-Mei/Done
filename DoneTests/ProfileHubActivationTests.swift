import XCTest
import SwiftUI
import UIKit
@testable import Done

/// gh#214 — the Me page kept doing homework it could not see.
///
/// `ProfileHubView` is created once and then kept alive by the root `TabView`
/// for the rest of the process, and it holds `EventStore` as an
/// `@EnvironmentObject`. Every `@Published` store mutation therefore re-ran a
/// body that filtered + sorted every event and rebuilt the whole achievement
/// catalogue — measured at 41% of the main-thread samples inside 26 hangs of
/// 253–538 ms, while the user was on the calendar tapping an effort scrubber.
///
/// Two layers are pinned here:
///
///  1. The pure pieces the gate is built out of — the activation predicate,
///     the background-type parser, and the aggregate reductions the sections
///     used to inline. Each fixture is chosen so inverting the rule it names
///     changes the asserted value.
///  2. The gate itself, at host level: the real view is mounted in a
///     `UIHostingController` inside a `UIWindow`, the runloop is spun, and
///     `ProfileHubAggregateProbe` is read. A skipped computation is invisible
///     from the outside, so every negative assertion below is paired with a
///     positive control on the same rig — the same mount with the Me tab
///     selected, and the same store publish with the Me tab selected, both of
///     which MUST compute. Without those, a rig that silently fails to render
///     anything would report a perfect zero.
@MainActor
final class ProfileHubActivationTests: XCTestCase {

    // MARK: - Fixtures

    private let calendar = Calendar.current
    private var store: EventStore!
    private var skillStore: SkillInsightStore!
    private var agentRuntime: AgentRuntime!
    private var authService: AuthService!
    private var suiteName: String!
    /// `ProfileHubView`'s `@AppStorage` reads `UserDefaults.standard` (the
    /// host app's own domain). The celebration path writes two of those keys,
    /// so they are saved and restored around every test.
    private var savedCelebrated: Any?
    private var savedSeeded: Any?

    override func setUp() {
        super.setUp()
        suiteName = "ProfileHubActivationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        store = EventStore(defaults: defaults,
                           storage: .ephemeral(id: UUID()),
                           seedsSampleDataIfEmpty: false)
        skillStore = SkillInsightStore(defaults: defaults)
        agentRuntime = AgentRuntime()
        authService = AuthService(defaults: defaults)
        savedCelebrated = UserDefaults.standard.object(forKey: AppSettingsKeys.celebratedAchievements)
        savedSeeded = UserDefaults.standard.object(forKey: AppSettingsKeys.achievementCelebrationSeeded)
        // Scope the probe to THIS store. The test bundle's host app is running
        // its own ContentView in the same process, and on a run where the app
        // restored the Me tab its own ProfileHubView aggregates too — which an
        // unscoped counter reports as the fixture's work. Observed: without
        // this, a `.calendar` mount read computeCount == 1.
        ProfileHubAggregateProbe.scope = store
        ProfileHubAggregateProbe.reset()
    }

    override func tearDown() {
        UserDefaults.standard.set(savedCelebrated, forKey: AppSettingsKeys.celebratedAchievements)
        UserDefaults.standard.set(savedSeeded, forKey: AppSettingsKeys.achievementCelebrationSeeded)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        ProfileHubAggregateProbe.scope = nil
        ProfileHubAggregateProbe.reset()
        store = nil
        skillStore = nil
        agentRuntime = nil
        authService = nil
        super.tearDown()
    }

    private func hoursAgo(_ hours: Double, from now: Date) -> Date {
        now.addingTimeInterval(-hours * 3600)
    }

    private func calendarEvent(
        type: String,
        startingDaysAgo days: Double,
        lastingHours hours: Double,
        from now: Date
    ) -> Event {
        let start = now.addingTimeInterval(-days * 86_400)
        return Event(
            title: type,
            timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(hours * 3600))],
            type: type
        )
    }

    private func logRecord(for eventID: UUID, on day: Date) -> CalendarEventLogRecord {
        CalendarEventLogRecord(
            id: CalendarOccurrenceKey(
                eventID: eventID,
                baseSeriesEventID: nil,
                occurrenceDate: day,
                kind: .singleEvent,
                dayKey: CalendarOccurrenceKey.dayKey(from: day)
            ),
            eventID: eventID,
            baseSeriesEventID: nil,
            occurrenceDate: day
        )
    }

    private func achievement(_ id: String, unlocked: Bool, at date: Date?) -> Achievement {
        Achievement(
            id: id,
            title: id,
            subtitle: "",
            icon: "star",
            unlocked: unlocked,
            unlockedAt: date,
            progress: unlocked ? 1 : 0,
            progressLabel: ""
        )
    }

    // MARK: - 1. The activation predicate

    /// The gate is exactly "the Me tab is the selected tab" — not "not the
    /// calendar", not "any analysis-flavoured tab". Written as a sweep over
    /// `RootTab.allCases` so a tab added later without a decision here shows
    /// up as a failure rather than as a silent extra caller of the
    /// aggregation.
    func testActivationIsExactlyTheMeTab() {
        let active = RootTab.allCases.filter { ProfileHubActivation.isActive(selectedTab: $0) }
        XCTAssertEqual(active, [.me],
                       "only the Me tab may unlock the Me page's store-wide aggregation")
        XCTAssertFalse(RootTab.allCases.isEmpty, "a vacuous sweep would pass trivially")
    }

    // MARK: - 2. Background-type parsing

    /// One string split per body pass instead of one per event and one per
    /// heatmap cell. The parse rules are the ones the old computed property
    /// applied inline: split on commas, trim whitespace, lowercase, drop
    /// empties.
    func testBackgroundTypesParseTrimsLowercasesAndDropsEmpties() {
        // The whitespace-only segment is deliberate: Swift's `split` already
        // omits EMPTY subsequences, so `,,` never reaches the filter and a
        // fixture built only from `,,` would pass with the filter deleted.
        // A `, ,` segment is the only input the drop-empties clause decides.
        let parsed = MeBackgroundTypes.parse(" Sleep , REST , ,commute ,")
        XCTAssertEqual(parsed, ["sleep", "rest", "commute"])
        XCTAssertFalse(parsed.contains(""), "empty segments must not become a matchable type")
        XCTAssertFalse(parsed.contains(" sleep "), "segments must be trimmed")
        XCTAssertFalse(parsed.contains("Sleep"), "segments must be lowercased")
    }

    func testBackgroundTypeMatchingIsCaseInsensitiveOnTheQuery() {
        let parsed = MeBackgroundTypes.parse("sleep")
        XCTAssertTrue(MeBackgroundTypes.contains("SLEEP", in: parsed))
        XCTAssertTrue(MeBackgroundTypes.contains("Sleep", in: parsed))
        XCTAssertFalse(MeBackgroundTypes.contains("Work", in: parsed))
    }

    func testEmptySettingMarksNothingAsBackground() {
        let parsed = MeBackgroundTypes.parse("")
        XCTAssertTrue(parsed.isEmpty)
        XCTAssertFalse(MeBackgroundTypes.contains("Sleep", in: parsed))
    }

    // MARK: - 3. The reductions the sections used to inline

    /// The hero line ranks the last 30 days by non-background hours and keeps
    /// the top three. Every clause is load-bearing in this fixture:
    ///   * "Sleep" has the MOST hours of all and is background → dropping the
    ///     background filter puts it first.
    ///   * "Gym" has 10 h at 40 days old and 2 h inside the window → dropping
    ///     the 30-day window puts Gym first.
    ///   * "Read" is a real fourth type → dropping `prefix(3)` lengthens the
    ///     answer.
    func testTopDescriptorsRankNonBackgroundHoursInsideThirtyDays() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let events = [
            calendarEvent(type: "Work", startingDaysAgo: 5, lastingHours: 6, from: now),
            calendarEvent(type: "Study", startingDaysAgo: 2, lastingHours: 4, from: now),
            calendarEvent(type: "Gym", startingDaysAgo: 1, lastingHours: 2, from: now),
            calendarEvent(type: "Gym", startingDaysAgo: 40, lastingHours: 10, from: now),
            calendarEvent(type: "Read", startingDaysAgo: 3, lastingHours: 0.5, from: now),
            calendarEvent(type: "Sleep", startingDaysAgo: 4, lastingHours: 24, from: now)
        ]

        let descriptors = ProfileHubAggregates.topDescriptors(
            events: events,
            backgroundTypes: MeBackgroundTypes.parse("sleep"),
            calendar: calendar,
            now: now
        )

        XCTAssertEqual(descriptors, ["Work", "Study", "Gym"])
    }

    /// Same fixture, background setting emptied: "Sleep" (24 h) takes the
    /// lead. This is the positive control for the clause above — it proves
    /// the events are actually visible to the reduction and that the
    /// exclusion, not an accident of the fixture, is what kept Sleep out.
    func testTopDescriptorsIncludeATypeOnceItStopsBeingBackground() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let events = [
            calendarEvent(type: "Work", startingDaysAgo: 5, lastingHours: 6, from: now),
            calendarEvent(type: "Study", startingDaysAgo: 2, lastingHours: 4, from: now),
            calendarEvent(type: "Sleep", startingDaysAgo: 4, lastingHours: 24, from: now)
        ]

        let descriptors = ProfileHubAggregates.topDescriptors(
            events: events,
            backgroundTypes: [],
            calendar: calendar,
            now: now
        )

        XCTAssertEqual(descriptors, ["Sleep", "Work", "Study"])
    }

    /// "N events to review": completed in the last 7 days, with no log record
    /// yet. Each row of the fixture kills exactly one clause.
    func testUnreviewedCountIsRecentCompletedAndUnlogged() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let counted = Event(title: "counted", status: .completed, completeAt: hoursAgo(48, from: now))
        let alreadyLogged = Event(title: "logged", status: .completed, completeAt: hoursAgo(48, from: now))
        let tooOld = Event(title: "old", status: .completed, completeAt: hoursAgo(24 * 10, from: now))
        let stillActive = Event(title: "active", status: .active, completeAt: hoursAgo(48, from: now))
        let inTheFuture = Event(title: "future", status: .completed, completeAt: now.addingTimeInterval(3600))

        let count = ProfileHubAggregates.unreviewedCount(
            events: [counted, alreadyLogged, tooOld, stillActive, inTheFuture],
            logs: [logRecord(for: alreadyLogged.id, on: hoursAgo(48, from: now))],
            calendar: calendar,
            now: now
        )

        XCTAssertEqual(count, 1, "only the recent, completed, unlogged event counts")
    }

    /// Positive control for the clause above: with the log record removed,
    /// the same fixture yields two. Proves the log lookup — not an unrelated
    /// filter — is what excluded `alreadyLogged`.
    func testUnreviewedCountRisesWhenTheLogRecordIsGone() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let a = Event(title: "a", status: .completed, completeAt: hoursAgo(48, from: now))
        let b = Event(title: "b", status: .completed, completeAt: hoursAgo(48, from: now))

        let count = ProfileHubAggregates.unreviewedCount(
            events: [a, b], logs: [], calendar: calendar, now: now
        )

        XCTAssertEqual(count, 2)
    }

    /// The big "Xh active" number sums the week's allocations MINUS the
    /// background types. Dropping the negation gives 5, dropping the filter
    /// gives 8.
    func testActiveWeekHoursExcludeBackgroundAllocations() {
        var aggregates = ProfileHubAggregates()
        aggregates.backgroundTypes = MeBackgroundTypes.parse("Sleep")
        aggregates.weekAllocations = [
            TypeAllocation(type: "Work", hours: 3, color: .blue),
            TypeAllocation(type: "sleep", hours: 5, color: .gray)
        ]

        XCTAssertEqual(aggregates.activeWeekHours, 3, accuracy: 0.0001)
    }

    /// "Recently earned" is the three most recently unlocked badges, newest
    /// first. The locked entry carries the newest date of all, so dropping
    /// the `unlocked` filter puts it at the head; the fourth unlocked badge
    /// makes `prefix(3)` load-bearing; the dates make the sort direction
    /// load-bearing.
    func testRecentlyEarnedIsTheThreeNewestUnlockedBadges() {
        let day = { (d: Int) in self.calendar.date(from: DateComponents(year: 2026, month: 6, day: d))! }
        var aggregates = ProfileHubAggregates()
        aggregates.achievements = [
            achievement("oldest", unlocked: true, at: day(1)),
            achievement("newest_but_locked", unlocked: false, at: day(20)),
            achievement("middle", unlocked: true, at: day(5)),
            achievement("newest", unlocked: true, at: day(10)),
            achievement("second", unlocked: true, at: day(7))
        ]

        XCTAssertEqual(aggregates.recentlyEarned.map(\.id), ["newest", "second", "middle"])
    }

    // MARK: - 4. The gate, at host level

    private final class TabSelectionBox: ObservableObject {
        @Published var tab: RootTab
        /// Drives `.navigationDestination(isPresented:)` in the pushed-page
        /// rig below — the test's stand-in for the user tapping the weekly
        /// stats block.
        @Published var pushed = false
        init(_ tab: RootTab) { self.tab = tab }
    }

    private struct ProfileHubTestHost: View {
        @ObservedObject var selection: TabSelectionBox
        let store: EventStore
        let skillStore: SkillInsightStore
        let agentRuntime: AgentRuntime
        let authService: AuthService

        var body: some View {
            ProfileHubView(selectedTab: $selection.tab)
                .environmentObject(store)
                .environmentObject(agentRuntime)
                .environmentObject(skillStore)
                .environmentObject(authService)
        }
    }

    private struct Mounted {
        let window: UIWindow
        let controller: UIViewController
        let selection: TabSelectionBox
    }

    private func mount(selectedTab: RootTab) -> Mounted {
        mount(selectedTab: selectedTab, store: store, skillStore: skillStore)
    }

    /// The store is a parameter so a test can put a SECOND live Me page in
    /// the process — the contamination `ProfileHubAggregateProbe.scope`
    /// exists to reject.
    private func mount(
        selectedTab: RootTab,
        store: EventStore,
        skillStore: SkillInsightStore
    ) -> Mounted {
        let selection = TabSelectionBox(selectedTab)
        let controller = UIHostingController(
            rootView: ProfileHubTestHost(
                selection: selection,
                store: store,
                skillStore: skillStore,
                agentRuntime: agentRuntime,
                authService: authService
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        settle(window: window, controller: controller)
        return Mounted(window: window, controller: controller, selection: selection)
    }

    /// Mount an arbitrary view on the same rig — used for the pages that are
    /// reached by a PUSH rather than by being a tab root.
    private func mount<V: View>(_ view: V) -> Mounted {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        settle(window: window, controller: controller)
        return Mounted(window: window, controller: controller, selection: TabSelectionBox(.me))
    }

    /// Force a layout pass and let SwiftUI's own update transaction land.
    private func settle(window: UIWindow, controller: UIViewController) {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
    }

    private func settle(_ mounted: Mounted) {
        settle(window: mounted.window, controller: mounted.controller)
    }

    private func seedSomeData() {
        let now = Date()
        store.rawCalendarEvents = [
            calendarEvent(type: "Work", startingDaysAgo: 1, lastingHours: 2, from: now),
            calendarEvent(type: "Study", startingDaysAgo: 2, lastingHours: 1, from: now)
        ]
        store.events = [Event(title: "done", status: .completed, completeAt: now.addingTimeInterval(-3600))]
    }

    /// The whole point of gh#214: mounted but not selected, the page must not
    /// spend a pass over the store.
    func testMountingWhileAnotherTabIsSelectedComputesNothing() {
        seedSomeData()
        ProfileHubAggregateProbe.reset()

        let mounted = mount(selectedTab: .calendar)

        XCTAssertEqual(ProfileHubAggregateProbe.computeCount, 0,
                       "an unselected Me tab must not aggregate the store")
        XCTAssertEqual(ProfileHubAggregateProbe.typeListCount, 0,
                       "the profile sheet's full type list must not be built off-tab either")
        withExtendedLifetime(mounted) {}
    }

    /// Positive control for the test above, on the identical rig: with the Me
    /// tab selected the very same mount MUST aggregate. If this ever fails,
    /// the zero above is a broken harness rather than a working gate.
    func testMountingWhileTheMeTabIsSelectedDoesCompute() {
        seedSomeData()
        ProfileHubAggregateProbe.reset()

        let mounted = mount(selectedTab: .me)

        XCTAssertGreaterThan(ProfileHubAggregateProbe.computeCount, 0,
                             "a selected Me tab must still build its page")
        // The profile sheet's list is an UNWINDOWED reduction over every
        // event. It sits in a `.sheet` content closure, and this pins the
        // measured fact that SwiftUI does not evaluate that closure while the
        // sheet is closed — if it ever starts to, the visible Me page pays a
        // second full pass per publish and this assertion says so.
        XCTAssertEqual(ProfileHubAggregateProbe.typeListCount, 0,
                       "a closed profile sheet must not build the full type list")
        withExtendedLifetime(mounted) {}
    }

    /// The traced sequence itself: the user is on the calendar, a log record
    /// publishes on the store, and the invisible Me tab used to filter+sort
    /// every event in response.
    func testStorePublishWhileUnselectedComputesNothing() {
        seedSomeData()
        let mounted = mount(selectedTab: .calendar)
        ProfileHubAggregateProbe.reset()

        store.rawCalendarEvents.append(
            calendarEvent(type: "Work", startingDaysAgo: 0.5, lastingHours: 1, from: Date())
        )
        settle(mounted)

        XCTAssertEqual(ProfileHubAggregateProbe.computeCount, 0,
                       "a store publish must not reach an unselected Me tab")
        withExtendedLifetime(mounted) {}
    }

    /// Positive control for the test above: the same publish, with the Me tab
    /// selected, must still refresh the page. This is what proves the store
    /// mutation actually propagates through this rig — without it, a publish
    /// that silently failed to invalidate anything would also read zero.
    func testStorePublishWhileSelectedRecomputes() {
        seedSomeData()
        let mounted = mount(selectedTab: .me)
        ProfileHubAggregateProbe.reset()

        store.rawCalendarEvents.append(
            calendarEvent(type: "Work", startingDaysAgo: 0.5, lastingHours: 1, from: Date())
        )
        settle(mounted)

        XCTAssertGreaterThan(ProfileHubAggregateProbe.computeCount, 0,
                             "a selected Me tab must react to a store publish")
        XCTAssertEqual(ProfileHubAggregateProbe.typeListCount, 0,
                       "a store publish must not build the closed sheet's full type list")
        withExtendedLifetime(mounted) {}
    }

    /// Selecting the tab is what turns the aggregation back on — the page is
    /// deferred, not disabled.
    func testSelectingTheMeTabTurnsAggregationOn() {
        seedSomeData()
        let mounted = mount(selectedTab: .calendar)
        ProfileHubAggregateProbe.reset()
        XCTAssertEqual(ProfileHubAggregateProbe.computeCount, 0)

        mounted.selection.tab = .me
        settle(mounted)

        XCTAssertGreaterThan(ProfileHubAggregateProbe.computeCount, 0,
                             "the page must build as soon as it becomes the selected tab")
        withExtendedLifetime(mounted) {}
    }

    /// The gate is `== .me`, not `!= .calendar`. Every mount above uses the
    /// calendar as "the other tab", which cannot tell those two rules apart;
    /// this one uses the report tab, where they disagree.
    func testMountingWhileTheReportTabIsSelectedComputesNothing() {
        seedSomeData()
        ProfileHubAggregateProbe.reset()

        let mounted = mount(selectedTab: .report)
        XCTAssertEqual(ProfileHubAggregateProbe.computeCount, 0,
                       "the report tab is not the Me tab either")

        store.rawCalendarEvents.append(
            calendarEvent(type: "Work", startingDaysAgo: 0.5, lastingHours: 1, from: Date())
        )
        settle(mounted)

        XCTAssertEqual(ProfileHubAggregateProbe.computeCount, 0,
                       "a store publish must not reach the Me tab from the report tab either")
        withExtendedLifetime(mounted) {}
    }

    // MARK: - 5. Pushed destinations (gh#214 F1)

    /// The rig for the residual: a real `TabView`, `ProfileHubView` under
    /// `.tag(RootTab.me)`, and a destination PUSHED on that tab's own
    /// `NavigationStack`. `ProfileHubView`'s gate does not reach a pushed
    /// page — the stack keeps it alive and subscribed after the user
    /// switches tabs — so `AnalysisContentView` kept reducing the whole
    /// store once per publish from the calendar tab.
    ///
    /// The calendar tab is deliberately not a bare `Text`: SwiftUI defers
    /// cheap offscreen leaves, and a rig built out of trivial leaves fails
    /// to reproduce the very thing it is meant to detect.
    ///
    /// `.rootTabContent(.me, selectedTab:)` is the production modifier at the
    /// production position (`ContentView.body`, the Me tab's child of the
    /// root `TabView`); what this rig cannot check is that ContentView spells
    /// the tab the same way — that stays an inspection.
    private struct PushedDestinationTestHost: View {
        @ObservedObject var selection: TabSelectionBox
        let store: EventStore
        let skillStore: SkillInsightStore
        let agentRuntime: AgentRuntime
        let authService: AuthService

        var body: some View {
            TabView(selection: $selection.tab) {
                NavigationStack {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(0..<40, id: \.self) { row in
                                HStack {
                                    Text("calendar row \(row)")
                                    Spacer()
                                    Text(String(format: "%.1fh", Double(row) / 2))
                                }
                                .padding(8)
                            }
                        }
                    }
                }
                .tag(RootTab.calendar)
                .tabItem { Label("Calendar", systemImage: "calendar") }

                NavigationStack {
                    ProfileHubView(selectedTab: $selection.tab)
                        .navigationDestination(isPresented: $selection.pushed) {
                            WeeklyAnalysisDetailView()
                                .environmentObject(store)
                                .environmentObject(skillStore)
                        }
                }
                .rootTabContent(.me, selectedTab: selection.tab)
                .tag(RootTab.me)
                .tabItem { Label("Me", systemImage: "person.crop.circle") }
            }
            .environmentObject(store)
            .environmentObject(agentRuntime)
            .environmentObject(skillStore)
            .environmentObject(authService)
        }
    }

    private func mountTabHost(selectedTab: RootTab) -> Mounted {
        let selection = TabSelectionBox(selectedTab)
        let controller = UIHostingController(
            rootView: PushedDestinationTestHost(
                selection: selection,
                store: store,
                skillStore: skillStore,
                agentRuntime: agentRuntime,
                authService: authService
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.isHidden = false
        settle(window: window, controller: controller)
        return Mounted(window: window, controller: controller, selection: selection)
    }

    /// Push the weekly analysis page and let the navigation transition land.
    private func push(_ mounted: Mounted) {
        mounted.selection.pushed = true
        settle(mounted)
        settle(mounted)
    }

    /// Positive control for the two tests below, on the identical rig: a
    /// pushed page on the SELECTED tab must aggregate, both on the push and
    /// on every later publish. Without this, a rig whose push silently never
    /// happened would report a perfect zero.
    func testPushedAnalysisPageAggregatesWhileItsTabIsSelected() {
        seedSomeData()
        let mounted = mountTabHost(selectedTab: .me)
        ProfileHubAggregateProbe.reset()
        push(mounted)

        XCTAssertGreaterThan(ProfileHubAggregateProbe.analysisCount, 0,
                             "the pushed weekly analysis page must build when it is on screen")

        ProfileHubAggregateProbe.reset()
        store.rawCalendarEvents.append(
            calendarEvent(type: "Work", startingDaysAgo: 0.5, lastingHours: 1, from: Date())
        )
        settle(mounted)

        XCTAssertGreaterThan(ProfileHubAggregateProbe.analysisCount, 0,
                             "a visible pushed page must react to a store publish")
        withExtendedLifetime(mounted) {}
    }

    /// gh#214 F1 itself: the user pushed the weekly page off the Me tab,
    /// switched to the calendar without popping it, and scrubbed effort.
    /// Every publish used to re-run `typeAllocations` + `dailyHoursData` +
    /// `taskCompletionTrend` + `aggregatedSkills` behind two screens.
    func testPushedAnalysisPageStopsAggregatingWhileAnotherTabIsSelected() {
        seedSomeData()
        let mounted = mountTabHost(selectedTab: .me)
        push(mounted)
        XCTAssertGreaterThan(ProfileHubAggregateProbe.analysisCount, 0,
                             "precondition: the destination really is pushed and computing")

        mounted.selection.tab = .calendar
        settle(mounted)
        ProfileHubAggregateProbe.reset()

        store.rawCalendarEvents.append(
            calendarEvent(type: "Work", startingDaysAgo: 0.5, lastingHours: 1, from: Date())
        )
        settle(mounted)

        XCTAssertEqual(ProfileHubAggregateProbe.analysisCount, 0,
                       "a pushed page whose tab is hidden must not aggregate the store")
        XCTAssertEqual(ProfileHubAggregateProbe.computeCount, 0,
                       "nor may the Me page underneath it")

        // Coming back must bring the page back — the gate defers the work,
        // it does not disable the page.
        mounted.selection.tab = .me
        settle(mounted)
        XCTAssertGreaterThan(ProfileHubAggregateProbe.analysisCount, 0,
                            "selecting the tab again must rebuild the pushed page")
        withExtendedLifetime(mounted) {}
    }

    /// `TrophyView` — pushed from the Me page's "see all", same shape. Read
    /// straight off `\.rootTabIsVisible` so the assertion is about the page's
    /// own gate rather than about a `TabView`.
    func testTrophyPageSkipsTheCatalogueWhileItsTabIsHidden() {
        seedSomeData()
        ProfileHubAggregateProbe.reset()

        let mounted = mount(
            NavigationStack {
                TrophyView()
                    .environmentObject(store)
                    .environmentObject(skillStore)
            }
            .environment(\.rootTabIsVisible, false)
        )

        XCTAssertEqual(ProfileHubAggregateProbe.trophyCount, 0,
                       "the achievement catalogue is a full pass over the store")
        withExtendedLifetime(mounted) {}
    }

    func testTrophyPageBuildsTheCatalogueWhileItsTabIsVisible() {
        seedSomeData()
        ProfileHubAggregateProbe.reset()

        let mounted = mount(
            NavigationStack {
                TrophyView()
                    .environmentObject(store)
                    .environmentObject(skillStore)
            }
            .environment(\.rootTabIsVisible, true)
        )

        XCTAssertGreaterThan(ProfileHubAggregateProbe.trophyCount, 0,
                             "a visible trophy page must still show trophies")
        withExtendedLifetime(mounted) {}
    }

    /// `TimeAllocationDetailView` — pushed two pages deep, same shape.
    func testTimeAllocationPageSkipsItsChartsWhileItsTabIsHidden() {
        seedSomeData()
        ProfileHubAggregateProbe.reset()

        let mounted = mount(
            NavigationStack {
                TimeAllocationDetailView()
                    .environmentObject(store)
            }
            .environment(\.rootTabIsVisible, false)
        )

        XCTAssertEqual(ProfileHubAggregateProbe.analysisCount, 0,
                       "the chart reduction walks every day in the period")
        withExtendedLifetime(mounted) {}
    }

    func testTimeAllocationPageBuildsItsChartsWhileItsTabIsVisible() {
        seedSomeData()
        ProfileHubAggregateProbe.reset()

        let mounted = mount(
            NavigationStack {
                TimeAllocationDetailView()
                    .environmentObject(store)
            }
            .environment(\.rootTabIsVisible, true)
        )

        XCTAssertGreaterThan(ProfileHubAggregateProbe.analysisCount, 0,
                             "a visible time-allocation page must still draw its charts")
        withExtendedLifetime(mounted) {}
    }

    /// The environment default. A subtree with no tab above it — a preview, a
    /// sheet hosted outside the tab tree, a tab that never opted in — must
    /// keep computing; the fix must not be able to blank a page by omission.
    func testAPageWithNoTabAboveItStillComputes() {
        seedSomeData()
        ProfileHubAggregateProbe.reset()

        let mounted = mount(
            NavigationStack {
                TrophyView()
                    .environmentObject(store)
                    .environmentObject(skillStore)
            }
        )

        XCTAssertGreaterThan(ProfileHubAggregateProbe.trophyCount, 0,
                             "`rootTabIsVisible` defaults to true — the gate is opt-in")
        withExtendedLifetime(mounted) {}
    }

    /// The injected value and the Me page's own gate are one rule. A sweep,
    /// so a fourth tab added later cannot quietly become "visible" for the
    /// Me tab's subtree.
    func testTabVisibilityIsExactlyTheSelectedTab() {
        for tab in RootTab.allCases {
            for selected in RootTab.allCases {
                XCTAssertEqual(RootTabVisibility.isVisible(tab: tab, selectedTab: selected),
                               tab == selected,
                               "\(tab) visible while \(selected) is selected?")
            }
        }
        XCTAssertEqual(
            RootTab.allCases.filter { RootTabVisibility.isVisible(tab: .me, selectedTab: $0) },
            RootTab.allCases.filter { ProfileHubActivation.isActive(selectedTab: $0) },
            "the Me page's gate and its pushed children's gate must be the same rule"
        )
    }

    // MARK: - 6. The celebration / activation edge (gh#214 F2)

    private func clearCelebrationState() {
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.celebratedAchievements)
        UserDefaults.standard.removeObject(forKey: AppSettingsKeys.achievementCelebrationSeeded)
    }

    private var celebratedIDs: Set<String> {
        Set((UserDefaults.standard.string(forKey: AppSettingsKeys.celebratedAchievements) ?? "")
            .split(separator: ",")
            .map(String.init))
    }

    private var unlockedIDs: Set<String> {
        Set(AchievementCatalog.compute(store: store, skillStore: skillStore)
            .filter(\.unlocked)
            .map(\.id))
    }

    /// The seeding branch is destructive if it ever runs against an empty
    /// achievement list: it stamps "nothing was ever unlocked" and the next
    /// real visit then treats every badge the user already owns as new — 2.4
    /// seconds of confetti each, in a queue. Off the tab, `aggregates` IS
    /// empty by construction, so the guard is the only thing standing between
    /// a background mount and that stamp.
    func testAnOffTabAppearWritesNoCelebrationState() {
        seedSomeData()
        clearCelebrationState()
        XCTAssertFalse(unlockedIDs.isEmpty, "fixture must own at least one badge to lose")

        let mounted = mount(selectedTab: .calendar)

        XCTAssertNil(UserDefaults.standard.object(forKey: AppSettingsKeys.achievementCelebrationSeeded),
                     "an off-tab appear must not stamp the celebration as seeded")
        XCTAssertNil(UserDefaults.standard.object(forKey: AppSettingsKeys.celebratedAchievements),
                     "...and must not overwrite the celebrated set with the empty off-tab list")
        withExtendedLifetime(mounted) {}
    }

    /// Positive control for the test above: on the tab, the same mount DOES
    /// seed — and seeds with the badges the user actually owns, not with the
    /// empty list. Without this, an `onAppear` that never fired in this rig
    /// would make the two `XCTAssertNil`s above pass for free.
    func testAnOnTabAppearSeedsTheCelebratedSetWithWhatIsAlreadyUnlocked() {
        seedSomeData()
        clearCelebrationState()
        let expected = unlockedIDs

        let mounted = mount(selectedTab: .me)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppSettingsKeys.achievementCelebrationSeeded),
                      "the first on-tab visit must seed")
        XCTAssertEqual(celebratedIDs, expected,
                       "seeding must record the badges already owned, so none of them pops")
        XCTAssertFalse(expected.isEmpty, "a vacuous fixture would pass with the seed writing nothing")
        withExtendedLifetime(mounted) {}
    }

    /// The `.onChange(of: isActiveTab)` belt. `onAppear` fires once, and on a
    /// launch that restores another tab it fires while the guard is closed —
    /// so without the activation edge the celebration would never seed at
    /// all on that run, and the first badge the user earned would be
    /// swallowed. The edge is also what makes the guard above safe to keep.
    func testActivatingTheTabSeedsWhatTheOffTabAppearSkipped() {
        seedSomeData()
        clearCelebrationState()
        let expected = unlockedIDs

        let mounted = mount(selectedTab: .calendar)
        XCTAssertNil(UserDefaults.standard.object(forKey: AppSettingsKeys.achievementCelebrationSeeded),
                     "precondition: the off-tab appear left the seed unwritten")

        mounted.selection.tab = .me
        settle(mounted)

        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppSettingsKeys.achievementCelebrationSeeded),
                      "becoming the selected tab must run the celebration check")
        XCTAssertEqual(celebratedIDs, expected,
                       "and must seed off the freshly computed list, not the empty off-tab one")
        XCTAssertFalse(expected.isEmpty, "a vacuous fixture would pass with the seed writing nothing")
        withExtendedLifetime(mounted) {}
    }

    // MARK: - 7. What `compute` reads out of the store (gh#214 F3)

    /// `topDescriptors`' call site MOVED in this fix, out of
    /// `ProfileHubView` and into `ProfileHubAggregates.compute` — the exact
    /// edit shape that has re-introduced the raw-vs-projected bug six times
    /// in this repo (#152 → #186 → #187 → #204 → #208 → #209 → #212). An
    /// absorbed `.todo` keeps its own type and its own time range, so reading
    /// `rawCalendarEvents` here adds its hours to its own bucket on top of
    /// the parent's — the hero line then ranks types differently from the
    /// canvas and from the chart.
    func testComputeRanksTypesFromTheProjectedEventList() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let parent = calendarEvent(type: "Work", startingDaysAgo: 3, lastingHours: 3, from: now)
        var absorbed = calendarEvent(type: "Errand", startingDaysAgo: 3, lastingHours: 4, from: now)
        absorbed.kind = .todo
        absorbed.absorbedIntoEventID = parent.id
        let study = calendarEvent(type: "Study", startingDaysAgo: 2, lastingHours: 2, from: now)
        store.rawCalendarEvents = [parent, absorbed, study]

        let aggregates = ProfileHubAggregates.compute(
            store: store,
            skillStore: skillStore,
            weekViewModel: AnalysisViewModel(),
            backgroundTypes: [],
            calendar: calendar,
            now: now
        )

        XCTAssertEqual(aggregates.topDescriptors, ["Work", "Study"],
                       "the absorbed todo's hours belong to its parent's block, not to a bucket of its own")

        // The fixture must be able to tell the two lists apart, or the
        // assertion above says nothing about WHICH list was read.
        XCTAssertEqual(
            ProfileHubAggregates.topDescriptors(
                events: store.rawCalendarEvents,
                backgroundTypes: [],
                calendar: calendar,
                now: now
            ),
            ["Errand", "Work", "Study"],
            "raw must rank differently here, or this fixture proves nothing"
        )
    }

    /// The weekly share image carries the same "who you are" line the page
    /// shows. Nothing else asserts on the value the share card is handed, and
    /// a card built from `[]` exports silently — the user only finds out
    /// after sending the picture.
    func testTheShareCardIsHandedTheHerosIdentityLine() {
        let savedBackground = UserDefaults.standard.object(forKey: AppSettingsKeys.meBackgroundTypes)
        defer { UserDefaults.standard.set(savedBackground, forKey: AppSettingsKeys.meBackgroundTypes) }
        UserDefaults.standard.set("Sleep", forKey: AppSettingsKeys.meBackgroundTypes)

        let now = Date()
        store.rawCalendarEvents = [
            calendarEvent(type: "Work", startingDaysAgo: 1, lastingHours: 3, from: now),
            calendarEvent(type: "Study", startingDaysAgo: 2, lastingHours: 1, from: now)
        ]
        ProfileHubAggregateProbe.reset()

        let mounted = mount(selectedTab: .me)

        XCTAssertEqual(ProfileHubAggregateProbe.heroDescriptors, ["Work", "Study"],
                       "precondition: the hero row rendered a non-empty, ordered identity line")
        XCTAssertEqual(ProfileHubAggregateProbe.shareCardDescriptors,
                       ProfileHubAggregateProbe.heroDescriptors,
                       "the exported card must carry the same identity line the page shows")
        withExtendedLifetime(mounted) {}
    }

    // MARK: - 8. The probe's own scoping

    /// Every negative assertion in this file is only worth what the scope
    /// guard is worth: `DoneTests` is a host-app bundle, the app's own
    /// `ContentView` runs in the same process, and on a launch that restored
    /// the Me tab its `ProfileHubView` aggregates on every publish. An
    /// unscoped counter reports that page's work as the fixture's — which
    /// breaks a "did not compute" assertion for an unrelated reason and, far
    /// worse, lets a "did compute" positive control pass without the view
    /// under test ever having rendered.
    func testTheProbeCountsOnlyTheStoreUnderTest() {
        let otherDefaults = UserDefaults(suiteName: "\(suiteName!)-other")!
        let otherStore = EventStore(defaults: otherDefaults,
                                    storage: .ephemeral(id: UUID()),
                                    seedsSampleDataIfEmpty: false)
        defer { UserDefaults(suiteName: "\(suiteName!)-other")?.removePersistentDomain(forName: "\(suiteName!)-other") }

        ProfileHubAggregateProbe.record(store: otherStore)
        ProfileHubAggregateProbe.recordTypeList(store: otherStore)
        ProfileHubAggregateProbe.recordAnalysis(store: otherStore)
        ProfileHubAggregateProbe.recordTrophy(store: otherStore)
        ProfileHubAggregateProbe.recordHeroDescriptors(store: otherStore, ["leaked"])
        ProfileHubAggregateProbe.recordShareDescriptors(store: otherStore, ["leaked"])

        XCTAssertEqual(ProfileHubAggregateProbe.computeCount, 0)
        XCTAssertEqual(ProfileHubAggregateProbe.typeListCount, 0)
        XCTAssertEqual(ProfileHubAggregateProbe.analysisCount, 0)
        XCTAssertEqual(ProfileHubAggregateProbe.trophyCount, 0)
        XCTAssertNil(ProfileHubAggregateProbe.heroDescriptors)
        XCTAssertNil(ProfileHubAggregateProbe.shareCardDescriptors)

        // Positive control on the same calls: the scoped store DOES count.
        ProfileHubAggregateProbe.record(store: store)
        ProfileHubAggregateProbe.recordTypeList(store: store)
        ProfileHubAggregateProbe.recordAnalysis(store: store)
        ProfileHubAggregateProbe.recordTrophy(store: store)
        ProfileHubAggregateProbe.recordHeroDescriptors(store: store, ["kept"])
        ProfileHubAggregateProbe.recordShareDescriptors(store: store, ["kept"])

        XCTAssertEqual(ProfileHubAggregateProbe.computeCount, 1)
        XCTAssertEqual(ProfileHubAggregateProbe.typeListCount, 1)
        XCTAssertEqual(ProfileHubAggregateProbe.analysisCount, 1)
        XCTAssertEqual(ProfileHubAggregateProbe.trophyCount, 1)
        XCTAssertEqual(ProfileHubAggregateProbe.heroDescriptors, ["kept"])
        XCTAssertEqual(ProfileHubAggregateProbe.shareCardDescriptors, ["kept"])
    }

    /// The same guard in the shape it actually has to survive: a SECOND live
    /// `ProfileHubView`, on its own store, aggregating on the Me tab while
    /// the page under test sits on another tab. This is the host app's own
    /// ContentView in miniature — the real thing needs the app to have
    /// restored the Me tab, which a test cannot arrange from inside the run.
    func testASecondLiveMePageDoesNotCountAgainstTheOneUnderTest() {
        let otherName = "\(suiteName!)-second-page"
        let otherDefaults = UserDefaults(suiteName: otherName)!
        let otherStore = EventStore(defaults: otherDefaults,
                                    storage: .ephemeral(id: UUID()),
                                    seedsSampleDataIfEmpty: false)
        let otherSkills = SkillInsightStore(defaults: otherDefaults)
        defer { UserDefaults(suiteName: otherName)?.removePersistentDomain(forName: otherName) }

        seedSomeData()
        let underTest = mount(selectedTab: .calendar)
        let second = mount(selectedTab: .me, store: otherStore, skillStore: otherSkills)
        ProfileHubAggregateProbe.reset()

        otherStore.rawCalendarEvents.append(
            calendarEvent(type: "Work", startingDaysAgo: 0.5, lastingHours: 1, from: Date())
        )
        settle(second)

        XCTAssertEqual(ProfileHubAggregateProbe.computeCount, 0,
                       "another store's Me page must not be counted as this one's work")

        // Non-vacuity: re-point the scope and prove the second page really is
        // alive and aggregating — otherwise the zero above means nothing.
        ProfileHubAggregateProbe.scope = otherStore
        ProfileHubAggregateProbe.reset()
        otherStore.rawCalendarEvents.append(
            calendarEvent(type: "Study", startingDaysAgo: 0.4, lastingHours: 1, from: Date())
        )
        settle(second)
        XCTAssertGreaterThan(ProfileHubAggregateProbe.computeCount, 0,
                             "the second page was computing all along — the scope guard is what hid it")

        ProfileHubAggregateProbe.scope = store
        withExtendedLifetime(underTest) {}
        withExtendedLifetime(second) {}
    }
}
