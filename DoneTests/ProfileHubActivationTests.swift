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
        ProfileHubAggregateProbe.reset()
    }

    override func tearDown() {
        UserDefaults.standard.set(savedCelebrated, forKey: AppSettingsKeys.celebratedAchievements)
        UserDefaults.standard.set(savedSeeded, forKey: AppSettingsKeys.achievementCelebrationSeeded)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
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
}
