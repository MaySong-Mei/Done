import XCTest
@testable import Done

/// The category-stats payload rides the widget sync's existing write guard
/// (gh#219): one hash over everything the widget can see, so an unchanged
/// payload spends no write and no reload, and a change only the stats can see
/// is never swallowed. Same capture/restore discipline as
/// `WidgetRefreshBudgetSeedTests` — under XCTest the group is the redirected
/// test-host suite, but other suites read it too.
@MainActor
final class CategoryStatsWidgetSyncTests: XCTestCase {
    private let keys = [SharedWidgetData.snapshotKey, SharedWidgetData.lastUpdatedKey,
                        SharedWidgetData.timeFormatKey, SharedWidgetData.languageKey,
                        SharedWidgetData.timeZoneKey, SharedWidgetData.categoryStatsKey]
    private var saved: [(String, Any?)] = []
    private var suites: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        saved = keys.map { ($0, group.object(forKey: $0)) }
    }

    override func tearDown() async throws {
        if let group = SharedWidgetData.sharedDefaults {
            for (key, value) in saved {
                if let value { group.set(value, forKey: key) } else { group.removeObject(forKey: key) }
            }
        }
        for suite in suites { TestStorage.tearDown(suite) }
        try await super.tearDown()
    }

    private let calendar = Calendar.current

    /// Wednesday 21 October 2026, noon, on the host's own calendar — the one
    /// the sync cuts days in. Its month began on the 1st; its snapshot window
    /// begins on the 20th.
    private var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))! }

    private func on(day: Int, _ hour: Int, _ minutes: Int = 60, type: String = "Work") -> Event {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        return Event(title: "\(type) \(day)", timeRanges: [.init(start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)))],
                     type: type)
    }

    private func makeStore(_ name: String, clock: Date) -> (EventStore, () -> Int) {
        let (store, reloads, _) = makeStoreWithDefaults(name, clock: clock)
        return (store, reloads)
    }

    private func makeStoreWithDefaults(_ name: String, clock: Date) -> (EventStore, () -> Int, UserDefaults) {
        let defaults = UserDefaults(suiteName: name)!
        let location: EventStorageLocation
        if suites.contains(name) {
            location = .isolated(name: name)
        } else {
            location = TestStorage.reset(name)
            suites.append(name)
        }
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        store.widgetSyncClock = { clock }
        var reloads = 0
        store.reloadWidgetTimelines = { reloads += 1 }
        return (store, { reloads }, defaults)
    }

    private var group: UserDefaults { SharedWidgetData.sharedDefaults! }

    private struct TimedOut: Error {}

    /// Polls `condition` on the main actor until it holds, sleeping between
    /// polls so the store's tasks run; a generous deadline, since a slow
    /// machine only makes this wait longer.
    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAnUnchangedPayloadWritesNothingEvenAsTheClockMoves() throws {
        let name = "CategoryStatsSync-\(UUID().uuidString)"
        let (store, reloads) = makeStore(name, clock: noon)
        store.addCalendarEvent(on(day: 21, 9))
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), 1, "positive control: the first sync writes")
        let stamp = group.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date
        XCTAssertNotNil(stamp)
        XCTAssertEqual(SharedWidgetData.readCategoryStats()?.writtenAt, noon)

        // Ten minutes later in the same process: only the write stamp would
        // differ, and the write stamp is not part of the comparison.
        store.widgetSyncClock = { self.noon.addingTimeInterval(600) }
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), 1, "the clock alone is not a change")
        XCTAssertEqual(SharedWidgetData.readCategoryStats()?.writtenAt, noon, "and nothing was written")
        XCTAssertEqual(group.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date, stamp)

        // A cold relaunch, five minutes on: seeded from the group, still equal.
        let (relaunched, relaunchReloads) = makeStore(name, clock: noon.addingTimeInterval(900))
        relaunched.flushWidgetSnapshotSync()
        XCTAssertEqual(relaunchReloads(), 0, "the seed covers the stats payload too")
        XCTAssertEqual(SharedWidgetData.readCategoryStats()?.writtenAt, noon)
        XCTAssertEqual(group.object(forKey: SharedWidgetData.lastUpdatedKey) as? Date, stamp)
    }

    /// The 5th is inside this month's stats and outside the snapshots'
    /// window: moving an event there changes the stats payload and nothing
    /// else, and must still write and reload.
    func testAChangeOnlyTheStatsCanSeeStillWrites() throws {
        let (store, reloads) = makeStore("CategoryStatsSync-\(UUID().uuidString)", clock: noon)
        var early = on(day: 5, 10, 120, type: "Reading")
        store.addCalendarEvent(early)
        store.addCalendarEvent(on(day: 21, 9))
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), 1)
        let snapshots = SharedWidgetData.read()
        XCTAssertFalse(SharedWidgetData.read().contains { $0.type == "Reading" },
                       "fixture: the snapshots cannot see the 5th")
        let before = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertEqual(CategoryStats.hours(in: before, period: .month, asOf: noon)["Reading"] ?? 0, 2, accuracy: 1e-9)

        early.timeRanges = [.init(start: early.timeRanges[0].start, end: early.timeRanges[0].end.addingTimeInterval(1800))]
        store.updateCalendarEvent(early)
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), 2, "a stats-only change must write and reload")
        XCTAssertEqual(SharedWidgetData.read(), snapshots,
                       "and it really was stats-only: the snapshots did not move")
        let after = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertEqual(CategoryStats.hours(in: after, period: .month, asOf: noon)["Reading"] ?? 0, 2.5, accuracy: 1e-9)
        XCTAssertEqual(CategoryStats.hours(in: after, period: .week, asOf: noon)["Reading"], nil,
                       "the 5th is not this week")

        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), 2, "and the guard closes again")
    }

    /// A relaunch whose group holds a stats payload that differs from what
    /// the store computes — or none at all, as a build from before the stats
    /// leaves it — must write once and heal.
    func testADifferentOrMissingStatsBlobIsHealedOnRelaunch() throws {
        let name = "CategoryStatsSync-\(UUID().uuidString)"
        let (first, _) = makeStore(name, clock: noon)
        first.addCalendarEvent(on(day: 21, 9))
        first.flushWidgetSnapshotSync()
        let good = try XCTUnwrap(SharedWidgetData.readCategoryStats())

        var tampered = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        tampered.days?[0].slices?[0].n = 2
        group.set(try JSONEncoder().encode(tampered), forKey: SharedWidgetData.categoryStatsKey)
        let (second, secondReloads) = makeStore(name, clock: noon)
        second.flushWidgetSnapshotSync()
        XCTAssertEqual(secondReloads(), 1, "a seeded stats payload that differs must not suppress the write")
        let healed = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertEqual(healed, good)

        group.removeObject(forKey: SharedWidgetData.categoryStatsKey)
        let (third, thirdReloads) = makeStore(name, clock: noon)
        third.flushWidgetSnapshotSync()
        XCTAssertEqual(thirdReloads(), 1, "no stats payload: no seed, one healing write")
        XCTAssertNotNil(SharedWidgetData.readCategoryStats())
        third.flushWidgetSnapshotSync()
        XCTAssertEqual(thirdReloads(), 1)
    }

    /// The coverage ends with the snapshots' window, so a new day is one
    /// write — the same once-a-day the snapshots already cost.
    func testANewDayWritesOnce() throws {
        let (store, reloads) = makeStore("CategoryStatsSync-\(UUID().uuidString)", clock: noon)
        store.addCalendarEvent(on(day: 21, 9))
        store.flushWidgetSnapshotSync()
        let firstEnd = SharedWidgetData.readCategoryStats()?.coverageEnd
        store.widgetSyncClock = { self.noon.addingTimeInterval(86_400) }
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), 2)
        XCTAssertNotEqual(SharedWidgetData.readCategoryStats()?.coverageEnd, firstEnd)
    }

    /// What the sync writes is what the builder makes of the store's
    /// canvas-renderable events at the sync's clock, coloured by the type
    /// catalogue — the builder is the one the equivalence tests cover.
    func testTheSyncWritesTheBuildersPayload() throws {
        let (store, _) = makeStore("CategoryStatsSync-\(UUID().uuidString)", clock: noon)
        store.addCalendarEvent(on(day: 21, 9))
        store.addCalendarEvent(on(day: 12, 14, type: ""))
        store.flushWidgetSnapshotSync()
        let written = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        var expected = CategoryStatsBuilder.payload(
            events: store.canvasRenderableCalendarEvents, now: noon, calendar: calendar,
            colorHex: { EventTypeTemplateStore.colorHex(for: $0) }
        )
        expected.backgroundCategories = MeBackgroundTypes.parse(AppSettingsKeys.meBackgroundTypesDefault).sorted()
        XCTAssertEqual(written, expected)
        XCTAssertEqual(written.categories?.map(\.name), ["Other", "Work"])
        XCTAssertNotNil(written.categories?.first?.colorHex)
    }

    /// The sync builds from the canvas's events: an absorbed todo's time is
    /// its parent's, and is not counted again under its own type — the
    /// builder does not filter, so the list the sync hands it is the only
    /// gate. The control: the raw list would have counted it.
    func testAnAbsorbedTodoIsNotCountedTwice() throws {
        let (store, _) = makeStore("CategoryStatsSync-\(UUID().uuidString)", clock: noon)
        let parent = on(day: 21, 9, 180, type: "Work")
        var absorbed = on(day: 21, 9, 120, type: "Errand")
        absorbed.kind = .todo
        absorbed.absorbedIntoEventID = parent.id
        store.rawCalendarEvents = [parent, absorbed]
        store.flushWidgetSnapshotSync()
        let written = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertEqual(CategoryStats.hours(in: written, period: .week, asOf: noon), ["Work": 3])
        let raw = CategoryStatsBuilder.payload(events: store.rawCalendarEvents, now: noon, calendar: calendar,
                                               colorHex: { _ in nil })
        XCTAssertEqual(CategoryStats.hours(in: raw, period: .week, asOf: noon)["Errand"] ?? 0, 1, accuracy: 1e-9,
                       "control: the raw list shares the parent's first two hours with the todo")
    }

    /// Every write carries the Me tab's background list as that tab reads
    /// it — the setting's default when the user never set one — and editing
    /// the list writes the payload again with nothing else changed, through
    /// the same debounce a calendar edit takes.
    func testTheBackgroundListRidesThePayloadAndEditingItWrites() async throws {
        let (store, reloads, defaults) = makeStoreWithDefaults("CategoryStatsSync-\(UUID().uuidString)", clock: noon)
        store.addCalendarEvent(on(day: 21, 9))
        store.flushWidgetSnapshotSync()
        let before = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertEqual(before.backgroundCategories, MeBackgroundTypes.parse(AppSettingsKeys.meBackgroundTypesDefault).sorted())
        let snapshots = SharedWidgetData.read()
        let writes = reloads()

        defaults.set("Work, Gym", forKey: AppSettingsKeys.meBackgroundTypes)
        try await waitUntil { reloads() == writes + 1 }
        let after = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertEqual(after.backgroundCategories, ["gym", "work"])
        XCTAssertEqual(after.days, before.days, "the list is all that changed")
        XCTAssertEqual(SharedWidgetData.read(), snapshots)
        XCTAssertEqual(CategoryStats.summary(of: after, period: .week, asOf: noon, excludingBackground: true).status, .empty,
                       "and the widget reads it: Work is all there is, and Work is now background")

        // The same list in another order is the same payload.
        defaults.set("gym,work", forKey: AppSettingsKeys.meBackgroundTypes)
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), writes + 1)
        XCTAssertEqual(defaults.meBackgroundTypes, "gym,work", "the observed property is the setting's key")
    }
}

/// Builds too large for the main actor run off it (`categoryStatsInlineWork`;
/// these tests set it to 0, so any calendar with an event in it is too
/// large). The debounced sync writes when the build lands; a flush writes
/// the snapshots at once and the stats when the build lands; a build that
/// lands after a newer sync has started is dropped, so an older computation
/// can never overwrite a newer one.
@MainActor
final class CategoryStatsDeferredSyncTests: XCTestCase {
    private let keys = [SharedWidgetData.snapshotKey, SharedWidgetData.lastUpdatedKey,
                        SharedWidgetData.timeFormatKey, SharedWidgetData.languageKey,
                        SharedWidgetData.timeZoneKey, SharedWidgetData.categoryStatsKey]
    private var saved: [(String, Any?)] = []
    private let suite = "CategoryStatsDeferred-\(UUID().uuidString)"

    override func setUp() async throws {
        try await super.setUp()
        let group = try XCTUnwrap(SharedWidgetData.sharedDefaults)
        saved = keys.map { ($0, group.object(forKey: $0)) }
    }

    override func tearDown() async throws {
        if let group = SharedWidgetData.sharedDefaults {
            for (key, value) in saved {
                if let value { group.set(value, forKey: key) } else { group.removeObject(forKey: key) }
            }
        }
        TestStorage.tearDown(suite)
        try await super.tearDown()
    }

    private let calendar = Calendar.current
    private var noon: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))! }

    private func event(day: Int, hour: Int, type: String) -> Event {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
        return Event(title: type, timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))], type: type)
    }

    /// What the build probe saw, from whichever thread the build ran on.
    private final class Builds: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(days: Int, events: Int, onMain: Bool)] = []
        /// Builds whose probe call waits here until `release()`.
        private var held = 0
        private let gate = DispatchSemaphore(value: 0)

        init(holding: Int = 0) { held = holding }

        func record(_ days: Int, _ events: Int, _ onMain: Bool) {
            lock.lock()
            seen.append((days, events, onMain))
            let hold = held > 0
            if hold { held -= 1 }
            lock.unlock()
            if hold { _ = gate.wait(timeout: .now() + 30) }
        }

        func release() { gate.signal() }

        var all: [(days: Int, events: Int, onMain: Bool)] {
            lock.lock(); defer { lock.unlock() }
            return seen
        }
    }

    private func makeStore(builds: Builds? = nil) -> (EventStore, () -> Int) {
        let store = EventStore(defaults: UserDefaults(suiteName: suite)!, storage: TestStorage.reset(suite),
                               seedsSampleDataIfEmpty: false)
        store.widgetSyncClock = { [noon] in noon }
        store.categoryStatsInlineWork = 0
        if let builds { store.categoryStatsBuildProbe = { builds.record($0, $1, $2) } }
        var reloads = 0
        store.reloadWidgetTimelines = { reloads += 1 }
        return (store, { reloads })
    }

    private struct TimedOut: Error {}

    /// Polls `condition` on the main actor until it holds, sleeping between
    /// polls so the store's tasks run; a generous deadline, since a slow
    /// machine only makes this wait longer.
    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func statsHours(_ period: CategoryStatsPeriod = .month) -> [String: Double] {
        SharedWidgetData.readCategoryStats().map { CategoryStats.hours(in: $0, period: period, asOf: noon) } ?? [:]
    }

    /// A save arms the debounced sync; its write arrives once the build,
    /// run off the main thread, has landed, and matches what a synchronous
    /// flush would write.
    func testTheDebouncedSyncWritesTheStatsWhenTheBuildLands() async throws {
        let builds = Builds()
        let (store, reloads) = makeStore(builds: builds)
        store.flushWidgetSnapshotSync()
        await store.awaitDeferredWidgetSync()
        let baseline = reloads()
        store.addCalendarEvent(event(day: 9, hour: 10, type: "Reading"))
        try await waitUntil { reloads() == baseline + 1 }
        XCTAssertEqual(statsHours()["Reading"] ?? 0, 1, accuracy: 1e-9)
        let large = builds.all.filter { $0.events > 0 }
        XCTAssertFalse(large.isEmpty, "positive control: the edit's build was seen")
        XCTAssertFalse(large.contains { $0.onMain }, "\(builds.all)")

        // The flush that follows finds the build reusable and the group
        // already current.
        let written = SharedWidgetData.readCategoryStats()
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), baseline + 1)
        XCTAssertEqual(SharedWidgetData.readCategoryStats(), written)
    }

    /// No build too large for the main actor runs on its thread, from either
    /// sync: the debounced one after an edit, a flush after an edit, a flush
    /// with nothing built yet. Each builds every day of the coverage.
    func testNoLargeBuildRunsOnTheMainThread() async throws {
        let builds = Builds()
        let (store, reloads) = makeStore(builds: builds)
        store.addCalendarEvent(event(day: 21, hour: 9, type: "Work"))
        store.flushWidgetSnapshotSync()
        await store.awaitDeferredWidgetSync()
        let afterFlush = reloads()
        store.addCalendarEvent(event(day: 20, hour: 9, type: "Gym"))
        try await waitUntil { reloads() == afterFlush + 1 }
        store.addCalendarEvent(event(day: 19, hour: 9, type: "Read"))
        store.flushWidgetSnapshotSync()
        await store.awaitDeferredWidgetSync()
        XCTAssertEqual(Set(statsHours().keys), ["Work", "Gym", "Read"])

        let coverage = CategoryStatsBuilder.coverage(now: noon, calendar: calendar)
        let days = CategoryStats.days(from: coverage.start, to: coverage.end, calendar: calendar).count
        XCTAssertEqual(builds.all.count, 3, "positive control: three builds, one per sync that needed one: \(builds.all)")
        for build in builds.all {
            XCTAssertFalse(build.onMain, "\(builds.all)")
            XCTAssertEqual(build.days, days)
        }
    }

    /// A flush that hands its build off writes the snapshots before it
    /// returns — the lifecycle edge may be the app's last turn — and the
    /// stats when the build lands.
    func testAFlushWritesTheSnapshotsAtOnceAndTheStatsWhenTheBuildLands() async throws {
        SharedWidgetData.sharedDefaults?.removeObject(forKey: SharedWidgetData.categoryStatsKey)
        let builds = Builds(holding: 1)
        let (store, reloads) = makeStore(builds: builds)
        store.rawCalendarEvents = [event(day: 21, hour: 9, type: "Work")]
        store.flushWidgetSnapshotSync()
        XCTAssertTrue(SharedWidgetData.read().contains { $0.title == "Work" }, "the snapshots are in the group")
        XCTAssertEqual(reloads(), 1, "and the widget told")
        XCTAssertNil(statsHours()["Work"], "the stats are not, yet")
        builds.release()
        await store.awaitDeferredWidgetSync()
        XCTAssertEqual(statsHours()["Work"] ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(reloads(), 2)
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), 2, "the build is cached: nothing new")
    }

    /// The generation guard, delivered directly: a build from before the
    /// latest sync is dropped; one from the latest sync is written.
    func testAStaleBuildIsDroppedAndTheCurrentOneLands() async throws {
        let (store, reloads) = makeStore()
        store.addCalendarEvent(event(day: 21, hour: 9, type: "Work"))
        store.flushWidgetSnapshotSync()
        await store.awaitDeferredWidgetSync()
        let current = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        let snapshots = SharedWidgetData.read()
        let before = reloads()

        let coverage = CategoryStatsBuilder.coverage(now: noon, calendar: calendar)
        let inputs = EventStore.CategoryStatsInputs(
            revision: -1, coverageStart: coverage.start, coverageEnd: coverage.end,
            frame: CategoryStatsPayload.frame(of: calendar)
        )
        let older = CategoryStatsBuilder.payload(events: [event(day: 21, hour: 9, type: "Stale")], now: noon,
                                                 calendar: calendar, colorHex: { _ in nil })
        store.finishDeferredWidgetSync(
            generation: store.categoryStatsGeneration - 1, inputs: inputs, categoryStats: older, statsMillis: 0,
            snapshots: snapshots, sourceCount: 1, now: noon, calendar: calendar
        )
        XCTAssertEqual(reloads(), before, "a build an older sync started never writes")
        XCTAssertEqual(SharedWidgetData.readCategoryStats(), current)

        store.finishDeferredWidgetSync(
            generation: store.categoryStatsGeneration, inputs: inputs, categoryStats: older, statsMillis: 0,
            snapshots: snapshots, sourceCount: 1, now: noon, calendar: calendar
        )
        XCTAssertEqual(reloads(), before + 1, "control: the same build from the latest sync does write")
        XCTAssertEqual(SharedWidgetData.readCategoryStats()?.categories?.compactMap(\.name), ["Stale"])

        // And because its inputs are not the store's, the next sync rebuilds
        // and puts the truth back.
        store.flushWidgetSnapshotSync()
        await store.awaitDeferredWidgetSync()
        XCTAssertEqual(SharedWidgetData.readCategoryStats()?.days, current.days)
    }

    /// Every sync takes a generation of its own: a build an earlier sync
    /// started, landing after a later sync wrote, is dropped — whatever path
    /// the later sync took, here the one that writes without building.
    func testABuildFromAnEarlierSyncNeverLandsAfterALaterOne() throws {
        let (store, reloads) = makeStore()
        store.categoryStatsInlineWork = EventStore.categoryStatsInlineWorkDefault
        store.rawCalendarEvents = [event(day: 21, hour: 9, type: "Work")]
        store.flushWidgetSnapshotSync()
        let earlier = store.categoryStatsGeneration
        let earlierStats = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        let earlierSnapshots = SharedWidgetData.read()
        store.rawCalendarEvents.append(event(day: 20, hour: 9, type: "Gym"))
        store.flushWidgetSnapshotSync()
        let latest = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertNotEqual(latest.days, earlierStats.days, "fixture: the later sync changed the stats")
        let before = reloads()

        let coverage = CategoryStatsBuilder.coverage(now: noon, calendar: calendar)
        store.finishDeferredWidgetSync(
            generation: earlier,
            inputs: EventStore.CategoryStatsInputs(revision: -1, coverageStart: coverage.start, coverageEnd: coverage.end,
                                                   frame: CategoryStatsPayload.frame(of: calendar)),
            categoryStats: earlierStats, statsMillis: 0, snapshots: earlierSnapshots, sourceCount: 1, now: noon,
            calendar: calendar
        )
        XCTAssertEqual(reloads(), before)
        XCTAssertEqual(SharedWidgetData.readCategoryStats(), latest)
    }

    /// The race itself: a flush's build held mid-flight while a later edit's
    /// flush builds and lands; released, the earlier build finds itself
    /// superseded and writes nothing.
    func testAnOlderBuildStillRunningNeverWritesOverANewerOne() async throws {
        let builds = Builds(holding: 1)
        let (store, reloads) = makeStore(builds: builds)
        store.rawCalendarEvents = [event(day: 21, hour: 9, type: "Work")]
        store.flushWidgetSnapshotSync()
        try await waitUntil { builds.all.count == 1 }
        store.rawCalendarEvents.append(event(day: 20, hour: 9, type: "Gym"))
        store.flushWidgetSnapshotSync()
        await store.awaitDeferredWidgetSync()
        XCTAssertEqual(Set(statsHours().keys), ["Work", "Gym"])
        let newer = SharedWidgetData.readCategoryStats()
        let writes = reloads()

        builds.release()
        try await waitUntil { store.categoryStatsBuildsEnded == 2 }
        XCTAssertEqual(SharedWidgetData.readCategoryStats(), newer, "the older build wrote nothing")
        XCTAssertEqual(reloads(), writes)
    }

    /// Two flushes in a row — a backgrounding fires two — while the first
    /// one's build is running: the second starts none of its own, and the
    /// one build lands for both.
    func testASecondFlushAdoptsTheBuildAlreadyRunning() async throws {
        let builds = Builds(holding: 1)
        let (store, reloads) = makeStore(builds: builds)
        store.rawCalendarEvents = [event(day: 21, hour: 9, type: "Work")]
        store.flushWidgetSnapshotSync()
        try await waitUntil { builds.all.count == 1 }
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), 1, "the snapshots were already written")
        builds.release()
        try await waitUntil { store.categoryStatsBuildsEnded == 1 && reloads() == 2 }
        await store.awaitDeferredWidgetSync()
        XCTAssertEqual(builds.all.count, 1, "one build for two flushes")
        XCTAssertEqual(statsHours()["Work"] ?? 0, 1, accuracy: 1e-9)
    }

    /// The first sync of a new day builds the new day alone, where it runs,
    /// and reuses the rest: with a budget a day's build fits and a whole
    /// coverage does not, yesterday's payload is built off the main thread
    /// and today's on it — one day — and the stats move to the new coverage.
    func testANewDayBuildsOneDayWhereTheSyncRuns() async throws {
        let builds = Builds()
        let (store, reloads) = makeStore(builds: builds)
        store.rawCalendarEvents = [event(day: 21, hour: 9, type: "Work"), event(day: 2, hour: 9, type: "Gym")]
        store.categoryStatsInlineWork = store.rawCalendarEvents.count
        store.flushWidgetSnapshotSync()
        await store.awaitDeferredWidgetSync()
        let writes = reloads()
        let tomorrow = noon.addingTimeInterval(86_400)
        store.widgetSyncClock = { tomorrow }
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(builds.all.map(\.days).last, 1)
        XCTAssertEqual(builds.all.map(\.onMain).last, true)
        XCTAssertFalse(builds.all.dropLast().contains { $0.onMain })
        XCTAssertEqual(reloads(), writes + 1, "one write for the new day")
        let written = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertEqual(written.coverageEnd, CategoryStatsBuilder.coverage(now: tomorrow, calendar: calendar).end)
        XCTAssertEqual(written.days, CategoryStatsBuilder.payload(events: store.canvasRenderableCalendarEvents, now: tomorrow,
                                                                  calendar: calendar, colorHex: { _ in nil }).days)
    }

    /// Erasing leaves no category in the group by the time it returns, with
    /// a budget of nothing: a calendar with nothing in it is built where the
    /// flush runs.
    func testEraseEmptiesTheStatsBeforeItReturns() async throws {
        let (store, _) = makeStore()
        store.rawCalendarEvents = [event(day: 21, hour: 9, type: "Work")]
        store.flushWidgetSnapshotSync()
        await store.awaitDeferredWidgetSync()
        XCTAssertEqual(SharedWidgetData.readCategoryStats()?.categories?.compactMap(\.name), ["Work"])
        store.clearAllLocalData()
        let erased = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertEqual(erased.categories, [])
        XCTAssertEqual(erased.days, [])
    }

    /// The handoff is the same events, with a detached instance's missing
    /// day key resolved on the main actor — and building from it changes
    /// nothing.
    func testTheHandoffResolvesLegacyKeysWithoutChangingThePayload() {
        var instance = event(day: 21, hour: 15, type: "Moved")
        instance.recurrenceParentId = UUID()
        instance.recurrenceInstanceDate = calendar.startOfDay(for: noon)
        instance.recurrenceInstanceDayKey = nil
        let events = [event(day: 21, hour: 9, type: "Work"), instance]
        let handed = CategoryStatsBuilder.handoff(events)
        XCTAssertFalse(handed.contains { $0.recurrenceInstanceDate != nil && $0.recurrenceInstanceDayKey == nil })
        XCTAssertEqual(handed[1].recurrenceInstanceDayKey,
                       Event.resolvedRecurrenceInstanceDayKey(dayKey: nil, legacyDate: instance.recurrenceInstanceDate))
        XCTAssertEqual(CategoryStatsBuilder.payload(events: handed, now: noon, calendar: calendar, colorHex: { _ in nil }),
                       CategoryStatsBuilder.payload(events: events, now: noon, calendar: calendar, colorHex: { _ in nil }))
        let resolved = [events[0]]
        XCTAssertEqual(CategoryStatsBuilder.handoff(resolved), resolved)
    }
}
