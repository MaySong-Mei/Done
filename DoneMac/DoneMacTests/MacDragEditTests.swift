//
//  MacDragEditTests.swift
//  DoneMacTests
//
//  Budget assertion 4 and the drop-write contracts: mid-drag costs zero
//  commits and zero day builds; a drop is exactly one commit seeded from
//  renderTimeRanges with every range shifted uniformly; snapping is the
//  shared 15-minute rule.
//

import XCTest
@testable import Done

@MainActor
final class MacDragEditTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    // 2026-03-10 00:00 UTC.
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private var day10: DayKey { DayKey(year: 2026, month: 3, day: 10) }
    private var day11: DayKey { DayKey(year: 2026, month: 3, day: 11) }

    private struct Rig {
        let store: MacEventStore
        let surface: CalendarSurfaceModel
        let drag: DragController
        let bill: MacWorkBill
    }

    private func makeRig(events: [Event]) async throws -> Rig {
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        for event in events { store.addCalendarEvent(event, now: dayStart) }
        let clock = ClockHub(calendar: calendar, bill: bill, drivesTimer: false)
        let surface = CalendarSurfaceModel(
            store: store, clock: clock, calendar: calendar, bill: bill,
            anchor: dayStart, dayCount: 7
        )
        surface.activate(now: dayStart)
        return Rig(store: store, surface: surface,
                   drag: DragController(store: store, calendar: calendar), bill: bill)
    }

    private func event(id: UUID = UUID(), title: String = "E",
                       hour: Double, durationHours: Double = 1) -> Event {
        let start = dayStart.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(durationHours * 3600))],
                     kind: .event)
    }

    /// BUDGET ASSERTION 4: drag 2s (many updates) commits nothing and
    /// builds nothing; the drop is one commit, one record, ≤2 day builds.
    func testDragBudget() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        let commitsBefore = rig.bill.count(.storeCommits)
        let buildsBefore = rig.bill.count(.dayModelBuilds)
        let recordsBefore = rig.bill.count(.recordsRewritten)

        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        for step in 0..<120 {
            rig.drag.updateMove(pointerDay: day10,
                                pointerFraction: 0.375 + CGFloat(step) * 0.001)
        }
        XCTAssertEqual(rig.bill.count(.storeCommits), commitsBefore, "a mid-drag commit")
        XCTAssertEqual(rig.bill.count(.dayModelBuilds), buildsBefore, "a mid-drag day build")
        XCTAssertNotNil(rig.drag.overlay)

        // Drop on the NEXT day at 11:00 (cross-day: two day rebuilds max).
        rig.drag.endMove(pointerDay: day11, pointerFraction: 11.0 / 24.0, now: dayStart)

        XCTAssertEqual(rig.bill.count(.storeCommits) - commitsBefore, 1, "a drop is exactly one commit")
        XCTAssertEqual(rig.bill.count(.recordsRewritten) - recordsBefore, 1, "one record for the drop")
        XCTAssertLessThanOrEqual(rig.bill.count(.dayModelBuilds) - buildsBefore, 2,
                                 "a cross-day drop rebuilds at most source+target days")
        XCTAssertNil(rig.drag.overlay)
    }

    func testMoveDropSnapsToFifteenMinutesAndLandsExactly() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail()
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        // Pointer at 11:07 → raw offset 2h07m = 7620s → nearest 900s = 7200 → 11:00.
        let pointer = (11.0 * 3600 + 7 * 60) / 86_400
        rig.drag.endMove(pointerDay: day10, pointerFraction: pointer, now: dayStart)

        let moved = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(moved?.timeRanges.first?.start,
                       dayStart.addingTimeInterval(11 * 3600))
        XCTAssertEqual(moved?.timeRanges.first?.end,
                       dayStart.addingTimeInterval(12 * 3600), "duration preserved")
    }

    func testMoveShiftsEveryRangeUniformly() async throws {
        let id = UUID()
        var multi = event(id: id, hour: 9)
        multi.timeRanges.append(.init(start: dayStart.addingTimeInterval(20 * 3600),
                                      end: dayStart.addingTimeInterval(21 * 3600)))
        let rig = try await makeRig(events: [multi])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail()
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rig.drag.endMove(pointerDay: day10, pointerFraction: 10.0 / 24.0, now: dayStart)

        let moved = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(moved?.timeRanges.map(\.start),
                       [dayStart.addingTimeInterval(10 * 3600),
                        dayStart.addingTimeInterval(21 * 3600)],
                       "all ranges shift by the same offset — the domino/move contract")
    }

    func testZeroOffsetDropCommitsNothing() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        let commits = rig.bill.count(.storeCommits)
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail()
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rig.drag.endMove(pointerDay: day10, pointerFraction: 9.0 / 24.0, now: dayStart)
        XCTAssertEqual(rig.bill.count(.storeCommits), commits,
                       "a drop where it started must not commit")
    }

    func testResizeBottomSnapsAndEnforcesMinimum() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail()
        }
        rig.drag.beginResizeBottom(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0])
        rig.drag.endResizeBottom(pointerDay: day10, pointerFraction: (11.0 * 3600 + 8 * 60) / 86_400, now: dayStart)
        var resized = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(resized?.timeRanges.first?.start, dayStart.addingTimeInterval(9 * 3600),
                       "resize must not move the start")
        XCTAssertEqual(resized?.timeRanges.first?.end, dayStart.addingTimeInterval(11 * 3600 + 900),
                       "11:08 snaps to 11:15")

        // Dragging above the start clamps to the minimum duration.
        guard let again = rig.store.calendarEvents.first(where: { $0.id == id }) else { return XCTFail() }
        rig.drag.beginResizeBottom(event: again, grabbedRange: again.renderTimeRanges(calendar: calendar)[0])
        rig.drag.endResizeBottom(pointerDay: day10, pointerFraction: 8.0 / 24.0, now: dayStart)
        resized = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(resized?.timeRanges.first?.end,
                       dayStart.addingTimeInterval(9 * 3600 + DragController.minimumEventSeconds))
    }

    /// Review round-3 F12's killer fixture: a straddling range gripped on
    /// its SECOND day resolves the pointer in that day's frame — the
    /// 5-hour event grows to 05:00, never collapses to the minimum.
    func testStraddleResizeFromSecondDayUsesPointerDayFrame() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 22, durationHours: 5)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail()
        }
        rig.drag.beginResizeBottom(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0])
        rig.drag.endResizeBottom(pointerDay: day11, pointerFraction: 5.0 / 24.0, now: dayStart)
        let resized = rig.store.calendarEvents.first { $0.id == id }?.timeRanges.first
        XCTAssertEqual(resized?.start, dayStart.addingTimeInterval(22 * 3600))
        XCTAssertEqual(resized?.end, dayStart.addingTimeInterval(29 * 3600),
                       "05:00 on the second civil day — not a collapse to start+15min")
    }

    func testDragCreateLandsRecordFirstThenAsksForAName() async throws {
        let rig = try await makeRig(events: [])
        let commits = rig.bill.count(.storeCommits)
        rig.drag.beginCreate(day: day10, fraction: 14.0 / 24.0)
        rig.drag.updateCreate(pointerFraction: 15.5 / 24.0)
        XCTAssertEqual(rig.bill.count(.storeCommits), commits, "no commit mid-create")
        rig.drag.endCreate(pointerFraction: 15.5 / 24.0, now: dayStart)

        XCTAssertEqual(rig.bill.count(.storeCommits) - commits, 1)
        let created = rig.store.calendarEvents.last
        XCTAssertEqual(created?.title, "", "data preservation: placeholder title, never a gate")
        XCTAssertEqual(created?.timeRanges.first?.start, dayStart.addingTimeInterval(14 * 3600))
        XCTAssertEqual(created?.timeRanges.first?.end, dayStart.addingTimeInterval(15 * 3600 + 1800))
        XCTAssertEqual(rig.drag.pendingComposerEventID, created?.id,
                       "the composer opens ON the already-persisted record")
    }

    func testCancelClearsWithoutCommit() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        let commits = rig.bill.count(.storeCommits)
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail()
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rig.drag.updateMove(pointerDay: day10, pointerFraction: 0.5)
        rig.drag.cancel()
        XCTAssertNil(rig.drag.overlay)
        XCTAssertFalse(rig.drag.isDragging)
        XCTAssertEqual(rig.bill.count(.storeCommits), commits)
    }
}
