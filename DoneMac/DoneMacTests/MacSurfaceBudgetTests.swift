//
//  MacSurfaceBudgetTests.swift
//  DoneMacTests
//
//  Budget assertions 1-3 (the work-bill pinned as tests): what one user
//  action is allowed to cost through the surface layer, on the 10k
//  fixture. Wall-clock bounds are soft; the counter bounds are the gate.
//

import XCTest
@testable import Done

@MainActor
final class MacSurfaceBudgetTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(count: Int) -> [Event] {
        (0..<count).map { i in
            let start = t0.addingTimeInterval(Double(i % 365) * 86_400 + Double(i % 12) * 3600)
            return Event(
                id: UUID(), title: "Fixture \(i)",
                timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
                kind: i % 4 == 0 ? .todo : .event
            )
        }
    }

    private struct Rig {
        let store: MacEventStore
        let surface: CalendarSurfaceModel
        let bill: MacWorkBill
        let clock: ClockHub
        let persistence: MacPersistence
    }

    private func makeRig(eventCount: Int) async throws -> Rig {
        let location = EventStorageLocation.ephemeral(id: UUID())
        do {
            let seeder = try MacPersistence(location: location)
            await seeder.submitCalendarEvents(fixture(count: eventCount), generation: 1, dominoStamp: nil)
            await seeder.flush()
        }
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: location)
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        let clock = ClockHub(calendar: calendar, bill: bill, drivesTimer: false)
        let surface = CalendarSurfaceModel(
            store: store, clock: clock, calendar: calendar, bill: bill,
            anchor: t0, dayCount: 7
        )
        return Rig(store: store, surface: surface, bill: bill, clock: clock, persistence: persistence)
    }

    /// BUDGET ASSERTION 1: cold activate on 10k events = at most one day
    /// model per visible day, zero writes, interactive-fast.
    func testColdActivateBudget() async throws {
        let rig = try await makeRig(eventCount: 10_000)
        let began = Date()
        rig.surface.activate(now: t0)
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertEqual(rig.surface.frame.days.count, 7)
        XCTAssertLessThanOrEqual(rig.bill.count(.dayModelBuilds), 7,
                                 "cold activate must build at most the visible window")
        XCTAssertEqual(rig.bill.count(.storeCommits), 0)
        let stats = await rig.persistence.stats
        XCTAssertEqual(stats.slotWrites, 0, "activation wrote something")
        XCTAssertLessThan(elapsed, 0.5, "cold activate left the interactive class")
    }

    /// BUDGET ASSERTION 2: scrolling one week forward builds only the
    /// newly visible days and commits nothing.
    func testWeekScrollBudget() async throws {
        let rig = try await makeRig(eventCount: 10_000)
        rig.surface.activate(now: t0)
        let buildsAfterActivate = rig.bill.count(.dayModelBuilds)

        rig.surface.shift(byDays: 7, now: t0)

        XCTAssertLessThanOrEqual(rig.bill.count(.dayModelBuilds) - buildsAfterActivate, 7)
        XCTAssertEqual(rig.bill.count(.storeCommits), 0)

        // Scrolling BACK is free: the previous week is still cached.
        let buildsBeforeReturn = rig.bill.count(.dayModelBuilds)
        rig.surface.shift(byDays: -7, now: t0)
        XCTAssertEqual(rig.bill.count(.dayModelBuilds), buildsBeforeReturn,
                       "returning to a cached week must cost zero builds")
    }

    /// BUDGET ASSERTION 3 (structural form): geometry is fractions, so
    /// nothing in the projection layer is invalidated by a resize — the
    /// same query after any number of view-layer passes is all hits.
    func testResizeInvalidatesNoDerivedState() async throws {
        let rig = try await makeRig(eventCount: 10_000)
        rig.surface.activate(now: t0)
        let builds = rig.bill.count(.dayModelBuilds)
        // A resize re-runs view bodies; the projection sees the same keys.
        for _ in 0..<50 {
            _ = rig.surface.frame  // what any body re-read costs
        }
        XCTAssertEqual(rig.bill.count(.dayModelBuilds), builds,
                       "no derived state may be invalidated by view-layer passes")
    }

    /// The anti-#201 clock assertion: a minute tick re-derives the overlay
    /// only — day models never rebuild on time passing.
    func testMinuteTickBuildsOverlayOnly() async throws {
        let rig = try await makeRig(eventCount: 1_000)
        rig.surface.activate(now: t0)
        let builds = rig.bill.count(.dayModelBuilds)

        rig.clock.pump(now: t0)                            // seed
        rig.clock.pump(now: t0.addingTimeInterval(61))     // minute edge

        XCTAssertEqual(rig.bill.count(.overlayBuilds), 1)
        XCTAssertEqual(rig.bill.count(.dayModelBuilds), builds,
                       "a clock tick rebuilt a day model — the #201 shape")
        XCTAssertNotNil(rig.surface.frame.nowLine)
    }

    /// Recipient scoping end to end: a commit on a day outside the window
    /// reaches no surface work at all.
    func testOutOfWindowCommitCostsTheSurfaceNothing() async throws {
        let rig = try await makeRig(eventCount: 1_000)
        rig.surface.activate(now: t0)
        let rebuilds = rig.bill.count(.surfaceRebuilds)
        let builds = rig.bill.count(.dayModelBuilds)

        let farStart = t0.addingTimeInterval(200 * 86_400)
        rig.store.addCalendarEvent(Event(
            id: UUID(), title: "FarAway",
            timeRanges: [.init(start: farStart, end: farStart.addingTimeInterval(3600))],
            kind: .event
        ), now: t0)

        XCTAssertEqual(rig.bill.count(.surfaceRebuilds), rebuilds,
                       "an out-of-window commit must not reach the surface")
        XCTAssertEqual(rig.bill.count(.dayModelBuilds), builds)
    }

    /// And the positive control: an in-window commit rebuilds exactly the
    /// affected day.
    func testInWindowCommitRebuildsOneDay() async throws {
        let rig = try await makeRig(eventCount: 1_000)
        rig.surface.activate(now: t0)
        let builds = rig.bill.count(.dayModelBuilds)

        rig.store.addCalendarEvent(Event(
            id: UUID(), title: "Today",
            timeRanges: [.init(start: t0.addingTimeInterval(3600),
                               end: t0.addingTimeInterval(7200))],
            kind: .event
        ), now: t0)

        XCTAssertEqual(rig.bill.count(.dayModelBuilds) - builds, 1,
                       "an in-window single-day commit rebuilds exactly one day model")
        XCTAssertTrue(rig.surface.frame.days.contains { day in
            day.blocks.contains { $0.title == "Today" }
        })
    }
}
