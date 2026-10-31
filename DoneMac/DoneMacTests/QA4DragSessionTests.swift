//
//  QA4DragSessionTests.swift
//  DoneMacTests
//
//  Independent QA (round 3, Phase 4) — session-lifecycle attack surface.
//
//  The headline: CalendarCanvasView.endDrag fires ALL THREE end* methods
//  in a fixed order (endMove, endResizeBottom, endCreate — lines 91-96),
//  under the claim "only the active session responds". The claim is
//  false: every end* method's guard-else runs clear(), which destroys
//  the session BEFORE the matching end* is reached. Only .move (first
//  in the order) survives; resize-drop and create-drop are no-ops
//  through the real view path. The implementer suite never sees this
//  because it always calls the one matching end* directly.
//
//  RED tests here pin that bug by replicating the view's literal call
//  order at controller level. They are EXPECTED RED until the order
//  dependence is fixed (e.g. end* guards that leave a non-matching
//  session untouched, or a single endDrag entry point).
//

import XCTest
@testable import Done

@MainActor
final class QA4DragSessionTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    // 2026-03-10 00:00 UTC — same fixture instant the implementer suite uses.
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private var day10: DayKey { DayKey(year: 2026, month: 3, day: 10) }

    private struct Rig {
        let store: MacEventStore
        let drag: DragController
        let bill: MacWorkBill
    }

    private func makeRig(events: [Event]) async throws -> Rig {
        let bill = MacWorkBill()
        let store = MacTestStore.make(bill: bill, calendar: calendar)
        await store.load()
        for event in events { store.addCalendarEvent(event, now: dayStart) }
        return Rig(store: store, drag: DragController(store: store, calendar: calendar), bill: bill)
    }

    private func event(id: UUID = UUID(), title: String = "E", hour: Double) -> Event {
        let start = dayStart.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: .event)
    }

    /// Replicates CalendarCanvasView.endDrag verbatim (same order, same
    /// three calls) so the controller is exercised exactly as the app
    /// exercises it.
    private func viewOrderEndDrag(_ drag: DragController, pointerDay: DayKey,
                                  fraction: CGFloat, now: Date) {
        drag.endMove(pointerDay: pointerDay, pointerFraction: fraction, now: now)
        drag.endResizeBottom(pointerDay: pointerDay, pointerFraction: fraction, now: now)
        drag.endCreate(pointerFraction: fraction, now: now)
    }

    // MARK: - The endDrag order bug (EXPECTED RED x2, one green control)

    /// EXPECTED RED — real bug. A create session dies inside endMove's
    /// guard-else clear() before endCreate ever runs: through the app's
    /// actual drop path, drag-create commits NOTHING. (The implementer's
    /// testDragCreateLandsRecordFirstThenAsksForAName passes only because
    /// it calls endCreate directly, skipping the view's order.)
    func testViewOrderEndDragMustLandDragCreate() async throws {
        let rig = try await makeRig(events: [])
        rig.drag.beginCreate(day: day10, fraction: 14.0 / 24.0)
        rig.drag.updateCreate(pointerFraction: 15.0 / 24.0)
        viewOrderEndDrag(rig.drag, pointerDay: day10, fraction: 15.0 / 24.0, now: dayStart)

        XCTAssertEqual(rig.drag.pendingCreate?.start, dayStart.addingTimeInterval(14 * 3600),
                       "drag-create through the view's endDrag order must reach the form; " +
                       "endMove's guard-else clear() kills the create session first")
    }

    /// EXPECTED RED — same root cause, resize flavor: endMove's guard-else
    /// clears the resizeBottom session, so a bottom-edge resize dropped
    /// through the real view path never commits.
    func testViewOrderEndDragMustApplyResize() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        rig.drag.beginResizeBottom(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0])
        viewOrderEndDrag(rig.drag, pointerDay: day10, fraction: 11.0 / 24.0, now: dayStart)

        let resized = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(resized?.timeRanges.first?.end, dayStart.addingTimeInterval(11 * 3600),
                       "resize to 11:00 through the view's endDrag order must commit; " +
                       "endMove's guard-else clear() kills the resize session first")
    }

    /// GREEN positive control: the same triple-call order works for a MOVE
    /// session — because endMove happens to be first. This isolates the
    /// failure above to order dependence, not to the triple-call shape.
    func testViewOrderEndDragMovePositiveControl() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        viewOrderEndDrag(rig.drag, pointerDay: day10, fraction: 11.0 / 24.0, now: dayStart)

        let moved = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(moved?.timeRanges.first?.start, dayStart.addingTimeInterval(11 * 3600),
                       "move survives the view order only because endMove is called first")
    }

    // MARK: - Session vs. store lifetime

    /// An event deleted mid-drag (another path removed it) must neither
    /// crash the drop nor be resurrected: replaceCalendarEvent no-ops on
    /// a missing id, and that silence is the pinned contract.
    func testDropOfEventDeletedMidDragDoesNotResurrect() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rig.drag.updateMove(pointerDay: day10, pointerFraction: 0.5)
        rig.store.removeCalendarEvent(id: id, now: dayStart)
        let commitsAfterRemove = rig.bill.count(.storeCommits)

        rig.drag.endMove(pointerDay: day10, pointerFraction: 11.0 / 24.0, now: dayStart)

        XCTAssertEqual(rig.bill.count(.storeCommits), commitsAfterRemove,
                       "dropping a deleted event must not commit")
        XCTAssertTrue(rig.store.calendarEvents.isEmpty,
                      "dropping a deleted event must not resurrect it")
        XCTAssertFalse(rig.drag.isDragging)
        XCTAssertNil(rig.drag.overlay)
    }

    /// Double beginCreate without an end: the controller has no isDragging
    /// guard of its own (the view's is the only one), so the second begin
    /// replaces the session. Pinned: last-wins, exactly one record lands,
    /// no orphan from the abandoned first anchor.
    func testDoubleBeginCreateLastAnchorWins() async throws {
        let rig = try await makeRig(events: [])
        rig.drag.beginCreate(day: day10, fraction: 10.0 / 24.0)
        rig.drag.beginCreate(day: day10, fraction: 14.0 / 24.0)
        rig.drag.endCreate(pointerFraction: 15.0 / 24.0, now: dayStart)

        XCTAssertTrue(rig.store.calendarEvents.isEmpty, "no orphan record")
        XCTAssertEqual(rig.drag.pendingCreate?.start,
                       dayStart.addingTimeInterval(14 * 3600),
                       "the second anchor is the one that reaches the form")
    }

    /// pendingCreate is set by endCreate ONLY. Move and resize
    /// drops must never set it — a wrong-event composer open is the
    /// failure this pins out.
    func testMoveAndResizeDropsNeverSetPendingComposer() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rig.drag.endMove(pointerDay: day10, pointerFraction: 11.0 / 24.0, now: dayStart)
        XCTAssertNil(rig.drag.pendingCreate, "a move drop opened the create form")

        guard let moved = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("move lost the event")
        }
        rig.drag.beginResizeBottom(event: moved, grabbedRange: moved.renderTimeRanges(calendar: calendar)[0])
        rig.drag.endResizeBottom(pointerDay: day10, pointerFraction: 13.0 / 24.0, now: dayStart)
        XCTAssertNil(rig.drag.pendingCreate, "a resize drop opened the create form")
    }

    /// Cancel mid-create: no commit, no overlay, no composer handoff.
    func testCancelMidCreateLeavesNothingBehind() async throws {
        let rig = try await makeRig(events: [])
        let commits = rig.bill.count(.storeCommits)
        rig.drag.beginCreate(day: day10, fraction: 10.0 / 24.0)
        rig.drag.updateCreate(pointerFraction: 12.0 / 24.0)
        rig.drag.cancel()

        XCTAssertEqual(rig.bill.count(.storeCommits), commits)
        XCTAssertNil(rig.drag.overlay)
        XCTAssertNil(rig.drag.pendingCreate)
        XCTAssertTrue(rig.store.calendarEvents.isEmpty)
    }

    /// A zero-travel create (press-drop on one spot) holds the minimum
    /// 15-minute range for the form, not a zero-height sliver.
    func testZeroTravelCreateHoldsMinimumDuration() async throws {
        let rig = try await makeRig(events: [])
        rig.drag.beginCreate(day: day10, fraction: 10.0 / 24.0)
        rig.drag.endCreate(pointerFraction: 10.0 / 24.0, now: dayStart)

        let pending = rig.drag.pendingCreate
        XCTAssertEqual(pending?.start, dayStart.addingTimeInterval(10 * 3600))
        XCTAssertEqual(pending?.end,
                       dayStart.addingTimeInterval(10 * 3600 + DragController.minimumEventSeconds))
    }
}
