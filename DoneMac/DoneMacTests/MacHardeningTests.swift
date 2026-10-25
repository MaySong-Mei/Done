//
//  MacHardeningTests.swift
//  DoneMacTests
//
//  Phase-6 hardening: the visibility clause (delta ∩ interest ∧ visible,
//  finally whole), multi-window sanity (N surfaces, one store), and the
//  dogfood evidence channel (daily work-bill JSONL).
//

import XCTest
@testable import Done

@MainActor
final class MacHardeningTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let t0 = Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC

    private struct Rig {
        let store: MacEventStore
        let clock: ClockHub
        let bill: MacWorkBill
    }

    private func makeRig() async throws -> Rig {
        let bill = MacWorkBill()
        let store = MacTestStore.make(bill: bill, calendar: calendar)
        await store.load()
        return Rig(store: store,
                   clock: ClockHub(calendar: calendar, bill: bill, drivesTimer: false),
                   bill: bill)
    }

    private func makeSurface(_ rig: Rig, rangeMode: CalendarRangeMode = .week) -> CalendarSurfaceModel {
        let surface = CalendarSurfaceModel(
            store: rig.store, clock: rig.clock, calendar: calendar,
            bill: rig.bill, anchor: t0, rangeMode: rangeMode
        )
        surface.activate(now: t0)
        return surface
    }

    private func event(id: UUID = UUID(), title: String = "E", hour: Double) -> Event {
        let start = t0.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .event)
    }

    // MARK: - Visibility clause

    /// Hidden surface: deltas cost NO frame rebuilds; re-appearance costs
    /// exactly one, however many arrived — the plan's third clause.
    func testHiddenSurfaceDefersToOneRebuildOnReappearance() async throws {
        let rig = try await makeRig()
        let surface = makeSurface(rig)
        surface.setVisible(false, now: t0)
        let rebuilds = rig.bill.count(.surfaceRebuilds)

        for hour in [9.0, 10.0, 11.0] {
            rig.store.addCalendarEvent(event(hour: hour), now: t0)
        }
        XCTAssertEqual(rig.bill.count(.surfaceRebuilds), rebuilds,
                       "a hidden surface must not rebuild frames")
        XCTAssertEqual(surface.frame.days.flatMap(\.blocks).count, 0,
                       "the frame stays stale while hidden — that's the point")

        surface.setVisible(true, now: t0)
        XCTAssertEqual(rig.bill.count(.surfaceRebuilds) - rebuilds, 1,
                       "three hidden deltas collapse to ONE rebuild on re-appearance")
        XCTAssertEqual(surface.frame.days.flatMap(\.blocks).count, 3)
    }

    /// The projection still hears hidden deltas (the round-2 lesson: the
    /// intake must never starve) — only frame work defers.
    func testHiddenDeltasStillReachTheProjectionIntake() async throws {
        let rig = try await makeRig()
        let surface = makeSurface(rig)
        surface.setVisible(false, now: t0)
        // An out-of-window commit while hidden: after re-appearance and a
        // scroll, the event must be there (index heard it).
        let farStart = t0.addingTimeInterval(10 * 86_400)
        let id = UUID()
        rig.store.addCalendarEvent(Event(
            id: id, title: "Far while hidden",
            timeRanges: [.init(start: farStart, end: farStart.addingTimeInterval(3600))],
            kind: .event), now: t0)
        surface.setVisible(true, now: t0)
        surface.shift(byDays: 7, now: t0)
        XCTAssertTrue(surface.frame.days.flatMap(\.blocks).contains { $0.eventID == id },
                      "the hidden-period commit renders after scroll — the intake never starved")
    }

    func testNoRefreshNeededMeansNoRebuildOnReappearance() async throws {
        let rig = try await makeRig()
        let surface = makeSurface(rig)
        let rebuilds = rig.bill.count(.surfaceRebuilds)
        surface.setVisible(false, now: t0)
        surface.setVisible(true, now: t0)
        XCTAssertEqual(rig.bill.count(.surfaceRebuilds), rebuilds,
                       "hide/show with no deltas must cost nothing")
    }

    // MARK: - Multi-window sanity

    /// Two surfaces over one store: both hear, independently windowed,
    /// deactivation of one never touches the other.
    func testTwoSurfacesOneStore() async throws {
        let rig = try await makeRig()
        let a = makeSurface(rig)
        let b = makeSurface(rig)
        b.shift(byDays: 7, now: t0)

        rig.store.addCalendarEvent(event(title: "This week", hour: 9), now: t0)
        let nextWeekStart = t0.addingTimeInterval(8 * 86_400)
        rig.store.addCalendarEvent(Event(
            id: UUID(), title: "Next week",
            timeRanges: [.init(start: nextWeekStart, end: nextWeekStart.addingTimeInterval(3600))],
            kind: .event), now: t0)

        XCTAssertTrue(a.frame.days.flatMap(\.blocks).contains { $0.title == "This week" })
        XCTAssertFalse(a.frame.days.flatMap(\.blocks).contains { $0.title == "Next week" })
        XCTAssertTrue(b.frame.days.flatMap(\.blocks).contains { $0.title == "Next week" })
        XCTAssertFalse(b.frame.days.flatMap(\.blocks).contains { $0.title == "This week" })

        a.deactivate()
        rig.store.addCalendarEvent(Event(
            id: UUID(), title: "After A left",
            timeRanges: [.init(start: nextWeekStart.addingTimeInterval(3600),
                               end: nextWeekStart.addingTimeInterval(7200))],
            kind: .event), now: t0)
        XCTAssertTrue(b.frame.days.flatMap(\.blocks).contains { $0.title == "After A left" },
                      "B keeps hearing after A deactivates")
        XCTAssertEqual(rig.store.observerCount, 1)
    }

    // MARK: - The evidence channel

    func testBillLogAppendsDailyLinesWithTripwires() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let bill = MacWorkBill()
        let log = try BillLog(location: location, calendar: calendar)
        bill.bump(.storeCommits, by: 3)
        bill.bump(.clockTicksWhileOccluded)  // a tripwire fires

        log.appendSnapshot(bill, now: t0)
        log.appendSnapshot(bill, now: t0.addingTimeInterval(60))

        let content = try String(contentsOf: log.fileURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "one line per snapshot, append-only")
        let last = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        )
        XCTAssertEqual(last["day"] as? String, "2026-03-10")
        let counters = try XCTUnwrap(last["counters"] as? [String: Int])
        XCTAssertEqual(counters["storeCommits"], 3)
        XCTAssertEqual(last["tripwiresFired"] as? [String], ["clockTicksWhileOccluded"],
                       "a fired tripwire is named in the evidence line")
    }

    func testBillLogLivesBesideTheEngineDirectoryNeverInside() async throws {
        let location = EventStorageLocation.ephemeral(id: UUID())
        let log = try BillLog(location: location, calendar: calendar)
        let engineDir = try location.directoryURL()
        // Containment, not string prefix — the sibling naming pattern
        // (…-BillLog) intentionally SHARES the engine dir's string prefix.
        XCTAssertFalse(log.fileURL.path.hasPrefix(engineDir.path + "/"),
                       "sweepUnknownEntries deletes unknown files inside the engine dir — the round-2 sidecar lesson")
        XCTAssertNotEqual(log.fileURL.deletingLastPathComponent().path, engineDir.path)
    }
}
