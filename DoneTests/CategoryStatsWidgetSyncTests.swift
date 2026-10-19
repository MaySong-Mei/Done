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
        return (store, { reloads })
    }

    private var group: UserDefaults { SharedWidgetData.sharedDefaults! }

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
        let expected = CategoryStatsBuilder.payload(
            events: store.canvasRenderableCalendarEvents, now: noon, calendar: calendar,
            colorHex: { EventTypeTemplateStore.colorHex(for: $0) }
        )
        XCTAssertEqual(written, expected)
        XCTAssertEqual(written.categories?.map(\.name), ["Other", "Work"])
        XCTAssertNotNil(written.categories?.first?.colorHex)
    }
}

/// The debounced sync builds the stats off the main actor and writes when
/// the build lands; a build that lands after a newer sync has started is
/// dropped, so an older computation can never overwrite a newer one.
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

    private func makeStore() -> (EventStore, () -> Int) {
        let store = EventStore(defaults: UserDefaults(suiteName: suite)!, storage: TestStorage.reset(suite),
                               seedsSampleDataIfEmpty: false)
        store.widgetSyncClock = { [noon] in noon }
        var reloads = 0
        store.reloadWidgetTimelines = { reloads += 1 }
        return (store, { reloads })
    }

    /// A save arms the debounced sync; its write arrives with the stats
    /// built off the main actor, and matches what a synchronous flush writes.
    func testTheDebouncedSyncWritesTheStatsWhenTheBuildLands() async throws {
        let (store, reloads) = makeStore()
        store.flushWidgetSnapshotSync()
        let baseline = reloads()
        store.addCalendarEvent(event(day: 9, hour: 10, type: "Reading"))
        try await Task.sleep(for: .milliseconds(600))
        await store.awaitDeferredWidgetSync()
        XCTAssertEqual(reloads(), baseline + 1, "one write, once the build landed")
        let written = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertEqual(CategoryStats.hours(in: written, period: .month, asOf: noon)["Reading"] ?? 0, 1, accuracy: 1e-9)

        // The flush that follows finds the build reusable and the group
        // already current.
        store.flushWidgetSnapshotSync()
        XCTAssertEqual(reloads(), baseline + 1)
        XCTAssertEqual(SharedWidgetData.readCategoryStats(), written)
    }

    /// The generation guard, delivered directly: a build from before the
    /// latest sync is dropped; one from the latest sync is written.
    func testAStaleBuildIsDroppedAndTheCurrentOneLands() throws {
        let (store, reloads) = makeStore()
        store.addCalendarEvent(event(day: 21, hour: 9, type: "Work"))
        store.flushWidgetSnapshotSync()
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
        XCTAssertEqual(SharedWidgetData.readCategoryStats(), current)
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
