//
//  QA4SnapComposerDrawerTests.swift
//  DoneMacTests
//
//  Independent QA (round 3, Phase 4) — snap arithmetic vs the shared
//  oracle, cross-day/grab clamps, DST fraction semantics, composer
//  edges, and the todo drawer's relevance gate (measured with a CLEAN
//  surfaceRebuilds counter: no calendar surface in the rig, so the
//  counter belongs to the drawer alone — the implementer suite could
//  not assert it because both surfaces share one bill).
//

import XCTest
@testable import Done

@MainActor
final class QA4SnapComposerDrawerTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private var calendarNY: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    // 2026-03-10 00:00 UTC.
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private var day10: DayKey { DayKey(year: 2026, month: 3, day: 10) }
    private var day11: DayKey { DayKey(year: 2026, month: 3, day: 11) }

    private struct Rig {
        let store: MacEventStore
        let drag: DragController
        let composer: ComposerModel
        let todos: TodoSurfaceModel
        let bill: MacWorkBill
    }

    private func makeRig(events: [Event] = [], calendar: Calendar? = nil) async throws -> Rig {
        let cal = calendar ?? self.calendar
        let bill = MacWorkBill()
        let store = MacTestStore.make(bill: bill, calendar: cal)
        await store.load()
        for event in events { store.addCalendarEvent(event, now: dayStart) }
        let todos = TodoSurfaceModel(store: store, bill: bill)
        todos.activate()
        return Rig(store: store,
                   drag: DragController(store: store, calendar: cal),
                   composer: ComposerModel(store: store, calendar: cal),
                   todos: todos, bill: bill)
    }

    private func event(id: UUID = UUID(), title: String = "E",
                       startSeconds: TimeInterval, durationSeconds: TimeInterval = 3600) -> Event {
        let start = dayStart.addingTimeInterval(startSeconds)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(durationSeconds))],
                     kind: .event)
    }

    // MARK: - Snap arithmetic vs the shared oracle

    /// Drag UP (negative offset): pointer at 06:53 against a 09:00 event
    /// gives raw -7620s; -7620/900 = -8.47 rounds to -8 -> -7200 -> the
    /// event lands at 07:00 exactly. The controller's landed instant must
    /// equal seedStart + oracle(raw) for the same raw the controller
    /// computes.
    func testDragUpNegativeOffsetMatchesOracle() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, startSeconds: 32_400)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        let seed = target.renderTimeRanges(calendar: calendar)[0]
        let fraction: CGFloat = 24_780.0 / 86_400.0  // 06:53

        // Oracle, fed the controller's own raw arithmetic.
        let raw = TimeInterval(max(0, fraction)) * 86_400 - 32_400
        let oracle = calendarPreviewOffsetSeconds(
            rawOffsetSeconds: raw, range: seed,
            snapIntervalSeconds: 900, calendar: calendar
        )
        XCTAssertEqual(oracle, -7200, accuracy: 0.0001, "away-from-boundary snap must engage")

        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rig.drag.endMove(pointerDay: day10, pointerFraction: fraction, now: dayStart)
        let landed = rig.store.calendarEvents.first { $0.id == id }?.timeRanges.first
        XCTAssertEqual(landed?.start, dayStart.addingTimeInterval(25_200), "07:00 exactly")
        XCTAssertEqual(landed?.start, seed.start.addingTimeInterval(oracle),
                       "controller and oracle must agree")
    }

    /// The +/-7.5-minute rounding boundary: .rounded() is
    /// toNearestOrAwayFromZero, so a raw offset of EXACTLY +450s snaps to
    /// +900 and EXACTLY -450s snaps to -900. Events start off-grid
    /// (08:52:30 / 09:07:30) so the raw offsets are exact doubles
    /// (0.375 * 86400 == 32400.0 with no rounding error).
    func testHalfIntervalBoundaryRoundsAwayFromZero() async throws {
        XCTAssertEqual(calendarPreviewOffsetSeconds(
            rawOffsetSeconds: 450,
            range: .init(start: dayStart.addingTimeInterval(31_950),
                         end: dayStart.addingTimeInterval(35_550)),
            snapIntervalSeconds: 900, calendar: calendar), 900)
        XCTAssertEqual(calendarPreviewOffsetSeconds(
            rawOffsetSeconds: -450,
            range: .init(start: dayStart.addingTimeInterval(32_850),
                         end: dayStart.addingTimeInterval(36_450)),
            snapIntervalSeconds: 900, calendar: calendar), -900)

        // Down-drag: 08:52:30 event, pointer 09:00 (fraction 0.375, exact).
        let downID = UUID()
        let rigDown = try await makeRig(events: [event(id: downID, startSeconds: 31_950)])
        guard let down = rigDown.store.calendarEvents.first(where: { $0.id == downID }) else {
            return XCTFail("fixture missing")
        }
        rigDown.drag.beginMove(event: down, grabbedRange: down.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rigDown.drag.endMove(pointerDay: day10, pointerFraction: 0.375, now: dayStart)
        XCTAssertEqual(rigDown.store.calendarEvents.first { $0.id == downID }?.timeRanges.first?.start,
                       dayStart.addingTimeInterval(32_850),
                       "raw +450 must snap away from zero to 09:07:30")

        // Up-drag mirror: 09:07:30 event, same pointer.
        let upID = UUID()
        let rigUp = try await makeRig(events: [event(id: upID, startSeconds: 32_850)])
        guard let up = rigUp.store.calendarEvents.first(where: { $0.id == upID }) else {
            return XCTFail("fixture missing")
        }
        rigUp.drag.beginMove(event: up, grabbedRange: up.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rigUp.drag.endMove(pointerDay: day10, pointerFraction: 0.375, now: dayStart)
        XCTAssertEqual(rigUp.store.calendarEvents.first { $0.id == upID }?.timeRanges.first?.start,
                       dayStart.addingTimeInterval(31_950),
                       "raw -450 must snap away from zero to 08:52:30")
    }

    /// The cross-day unsnap guard IS reachable from the controller's own
    /// pointer math: a 09:00 event dragged to 23:55 has raw 53700, which
    /// snaps to 54000 and would land the start at NEXT-DAY midnight while
    /// the finger stayed on Mar 10 — the guard must refuse the snap and
    /// land the drop unsnapped at 23:55.
    func testMidnightAdjacentDropRefusesCrossDaySnap() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, startSeconds: 32_400)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        let seed = target.renderTimeRanges(calendar: calendar)[0]
        XCTAssertEqual(calendarPreviewOffsetSeconds(
            rawOffsetSeconds: 53_700, range: seed,
            snapIntervalSeconds: 900, calendar: calendar), 53_700,
            "snapping 23:55 to 24:00 crosses a day the finger did not — must stay raw")

        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rig.drag.endMove(pointerDay: day10, pointerFraction: 86_100.0 / 86_400.0, now: dayStart)
        guard let landed = rig.store.calendarEvents.first(where: { $0.id == id })?
            .timeRanges.first else { return XCTFail("drop lost the event") }
        XCTAssertEqual(landed.start.timeIntervalSince(dayStart), 86_100, accuracy: 0.001,
                       "lands unsnapped at 23:55")
        XCTAssertNotEqual(landed.start, dayStart.addingTimeInterval(86_400),
                          "must not snap onto next-day midnight")
    }

    /// DST semantics pin (America/New_York). Fractions are ABSOLUTE
    /// seconds from midnight (fraction * 86400), the same mapping the
    /// axis geometry and calendarTimelineYFraction use, so a drop is
    /// geometry-consistent (it stays under the finger) — but on the
    /// 25-hour Nov 1 the axis LABEL at fraction 0.5 reads "12:00" while
    /// the landed wall time is 11:00 (13:00 on the 23-hour Mar 8). This
    /// test pins both halves of that trade with literals; severity is a
    /// product call reported in the QA findings, not decided here.
    func testDSTDayFractionIsAbsoluteSecondsNotWallClock() async throws {
        let ny = calendarNY
        let rig = try await makeRig(calendar: ny)

        // 25h fall-back day: 2026-11-01.
        let fallKey = DayKey(year: 2026, month: 11, day: 1)
        guard let fallMidnight = fallKey.startOfDay(calendar: ny) else { return XCTFail() }
        XCTAssertEqual(ny.date(byAdding: .day, value: 1, to: fallMidnight)?
            .timeIntervalSince(fallMidnight), 25 * 3600, "positive control: 25h day")

        rig.drag.beginCreate(day: fallKey, fraction: 0.5)
        rig.drag.endCreate(pointerFraction: 15.0 / 24.0, now: fallMidnight)
        guard let fallEvent = rig.store.calendarEvents.last,
              let fallRange = fallEvent.timeRanges.first else { return XCTFail() }
        XCTAssertEqual(fallRange.start.timeIntervalSince(fallMidnight), 43_200,
                       "fraction 0.5 lands at absolute midnight+12h")
        XCTAssertEqual(ny.component(.hour, from: fallRange.start), 11,
                       "…which is WALL-CLOCK 11:00 on the 25h day (axis label says 12:00)")
        XCTAssertEqual(calendarTimelineYFraction(for: fallRange.start,
                                                 containing: fallMidnight, calendar: ny),
                       0.5, "geometry round-trips: the block stays under the finger")

        // 23h spring-forward day: 2026-03-08.
        let springKey = DayKey(year: 2026, month: 3, day: 8)
        guard let springMidnight = springKey.startOfDay(calendar: ny) else { return XCTFail() }
        XCTAssertEqual(ny.date(byAdding: .day, value: 1, to: springMidnight)?
            .timeIntervalSince(springMidnight), 23 * 3600, "positive control: 23h day")

        rig.drag.beginCreate(day: springKey, fraction: 0.5)
        rig.drag.endCreate(pointerFraction: 15.0 / 24.0, now: springMidnight)
        guard let springRange = rig.store.calendarEvents.last?.timeRanges.first else {
            return XCTFail()
        }
        XCTAssertEqual(springRange.start.timeIntervalSince(springMidnight), 43_200)
        XCTAssertEqual(ny.component(.hour, from: springRange.start), 13,
                       "wall-clock 13:00 on the 23h day (axis label says 12:00)")
    }

    // MARK: - Cross-day move clamps

    /// grabFraction > pointerFraction: max(0, ...) pins the block start
    /// to the pointer day's midnight — the block cannot be pushed before
    /// the day it is over. Pinned: exact 00:00 landing, duration kept.
    func testGrabAboveDayTopClampsStartToMidnight() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, startSeconds: 32_400)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        // Grabbed 30 minutes into the block, pointer dragged to the very top.
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 1_800.0 / 86_400.0)
        rig.drag.endMove(pointerDay: day10, pointerFraction: 0, now: dayStart)

        let landed = rig.store.calendarEvents.first { $0.id == id }?.timeRanges.first
        XCTAssertEqual(landed?.start, dayStart, "clamped to the pointer day's midnight")
        XCTAssertEqual(landed?.end, dayStart.addingTimeInterval(3600), "duration preserved")
    }

    /// Negative day delta: an event on Mar 11 dragged onto Mar 10 lands
    /// exactly at the pointer time on the earlier day.
    func testMoveToEarlierDayLandsExactly() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, startSeconds: 86_400 + 32_400)])
        guard let target = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("fixture missing")
        }
        rig.drag.beginMove(event: target, grabbedRange: target.renderTimeRanges(calendar: calendar)[0], grabFraction: 0)
        rig.drag.endMove(pointerDay: day10, pointerFraction: 14.0 / 24.0, now: dayStart)
        XCTAssertEqual(rig.store.calendarEvents.first { $0.id == id }?.timeRanges.first?.start,
                       dayStart.addingTimeInterval(14 * 3600))
    }

    // NOTE (coverage gap, no test possible headlessly): the window clamp
    // for out-of-window drags lives ONLY in CalendarCanvasView.pointerDay
    // (private view function). DragController itself accepts ANY DayKey —
    // it will happily commit to a day 30 days outside the window — so the
    // view-level clamp is the single guard and is untestable without UI
    // automation. Recorded as a finding, not faked here.

    // MARK: - Composer edges

    /// Editing a dateless todo and saving with kind still .todo keeps
    /// ranges empty — no minted schedule.
    func testDatelessTodoSaveKeepsNoRanges() async throws {
        let id = UUID()
        let todo = Event(id: id, title: "Someday", timeRanges: [], kind: .todo)
        let rig = try await makeRig(events: [todo])
        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.title = "Someday soon"
        rig.composer.save(now: dayStart)
        let saved = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(saved?.timeRanges, [])
        XCTAssertEqual(saved?.kind, .todo)
    }

    /// Switching kind todo -> event on a DATELESS todo mints a range from
    /// the composer's start/end — which openForEdit seeded from Date.now
    /// (a wall-clock read inside the model, not the injected now), giving
    /// a ZERO-duration event at whatever instant the sheet opened.
    /// Pinned as-is; flagged in findings (inconsistent with the drag
    /// paths' 15-minute minimum, and a determinism hole).
    /// Round-4 contract (was the epsilon-mint pin): kind-switch with
    /// UNTOUCHED times assigns no ranges — the record stays dateless and
    /// no wall-clock instant is minted (openForEdit takes an explicit
    /// now; nothing in the model reads Date()).
    func testKindSwitchOnDatelessTodoMintsNothingUntouched() async throws {
        let id = UUID()
        let todo = Event(id: id, title: "Someday", timeRanges: [], kind: .todo)
        let rig = try await makeRig(events: [todo])
        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.kind = .event
        rig.composer.save(now: dayStart)

        let saved = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertEqual(saved?.kind, .event)
        XCTAssertEqual(saved?.timeRanges, [],
                       "untouched pickers must not schedule a dateless record")
        // And the touched path is the ONLY way it gains a schedule.
        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.start = dayStart.addingTimeInterval(14 * 3600)
        rig.composer.end = dayStart.addingTimeInterval(15 * 3600)
        rig.composer.save(now: dayStart)
        XCTAssertEqual(rig.store.calendarEvents.first { $0.id == id }?.timeRanges,
                       [Event.TimeRange(start: dayStart.addingTimeInterval(14 * 3600),
                                        end: dayStart.addingTimeInterval(15 * 3600))])
    }

    /// Round-4 contract (was the zero-duration pin): end-before-start
    /// clamps to the same 15-minute floor the drag paths enforce.
    func testEndBeforeStartClampsToMinimumDuration() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, startSeconds: 32_400)])
        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.end = rig.composer.start.addingTimeInterval(-3600)
        rig.composer.save(now: dayStart)
        let saved = rig.store.calendarEvents.first { $0.id == id }?.timeRanges.first
        XCTAssertEqual(saved?.start, dayStart.addingTimeInterval(32_400))
        XCTAssertEqual(saved?.end, (saved?.start).map { $0.addingTimeInterval(ComposerModel.minimumEventSeconds) },
                       "the composer shares the drag paths' duration floor")
    }

    /// Round-4 contract (was the duplicate pin): the create path records
    /// its new id, so a double-fired Save lands ONE record; the edit path
    /// stays idempotent via value equality.
    func testDoubleSaveCreateDuplicatesEditIsIdempotent() async throws {
        let rig = try await makeRig()
        rig.composer.openForCreate(day: day10, now: dayStart)
        rig.composer.title = "Twice"
        rig.composer.save(now: dayStart)
        rig.composer.save(now: dayStart)
        XCTAssertEqual(rig.store.calendarEvents.count, 1,
                       "a double-fired Save must not mint twice")

        guard let first = rig.store.calendarEvents.first else { return XCTFail() }
        XCTAssertTrue(rig.composer.openForEdit(eventID: first.id, now: dayStart))
        rig.composer.title = "Once"
        let commits = rig.bill.count(.storeCommits)
        rig.composer.save(now: dayStart)
        rig.composer.save(now: dayStart)
        XCTAssertEqual(rig.bill.count(.storeCommits) - commits, 1,
                       "the edit path double-save is idempotent")
    }

    /// returnToStack guards on the STORE event's kind: on a plain .event
    /// it must no-op even when the draft kind was switched to .todo (the
    /// sheet shows "Back to stack" off the DRAFT kind, so the button is
    /// reachable in exactly this state).
    func testReturnToStackOnPlainEventNoOps() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, startSeconds: 32_400)])
        let before = rig.store.calendarEvents.first { $0.id == id }
        XCTAssertTrue(rig.composer.openForEdit(eventID: id, now: dayStart))
        rig.composer.kind = .todo  // draft-only switch
        let commits = rig.bill.count(.storeCommits)
        rig.composer.returnToStack(now: dayStart)
        XCTAssertEqual(rig.bill.count(.storeCommits), commits)
        XCTAssertEqual(rig.store.calendarEvents.first { $0.id == id }, before,
                       "a plain event must survive returnToStack untouched")
    }

    // MARK: - Todo drawer relevance gate (clean counter)

    /// Removal of a stack todo: the id is gone from the store, so only
    /// the STALE rows branch can see the delta as relevant. The row must
    /// disappear.
    func testStackTodoRemovalRebuildsRows() async throws {
        let rig = try await makeRig()
        rig.todos.addTodo(title: "Doomed", now: dayStart)
        guard let id = rig.todos.rows.first?.id else { return XCTFail("addTodo landed no row") }
        rig.store.removeCalendarEvent(id: id, now: dayStart)
        XCTAssertTrue(rig.todos.rows.isEmpty,
                      "the stale-rows branch of the gate must catch a removed todo")
    }

    /// A scheduled todo made dateless through a GENERIC store edit (not
    /// returnToStack): not in rows, so only the store-lookup branch fires.
    /// The row must appear.
    func testScheduledTodoGoingDatelessEntersRows() async throws {
        let id = UUID()
        var scheduled = event(id: id, title: "Sched", startSeconds: 32_400)
        scheduled.kind = .todo
        let rig = try await makeRig(events: [scheduled])
        XCTAssertTrue(rig.todos.rows.isEmpty, "scheduled todo starts outside the stack")

        var dateless = scheduled
        dateless.timeRanges = []
        rig.store.replaceCalendarEvent(dateless, now: dayStart)
        XCTAssertEqual(rig.todos.rows.map(\.id), [id],
                       "the store-lookup branch of the gate must catch a todo going dateless")
    }

    /// The inverse: a stack todo receiving a schedule leaves the rows
    /// (stale-rows branch again, membership loss this time).
    func testStackTodoBecomingScheduledLeavesRows() async throws {
        let rig = try await makeRig()
        rig.todos.addTodo(title: "Landing", now: dayStart)
        guard let id = rig.todos.rows.first?.id,
              var todo = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("addTodo landed no row")
        }
        todo.timeRanges = [.init(start: dayStart.addingTimeInterval(32_400),
                                 end: dayStart.addingTimeInterval(36_000))]
        rig.store.replaceCalendarEvent(todo, now: dayStart)
        XCTAssertTrue(rig.todos.rows.isEmpty, "a scheduled todo must leave the drawer")
    }

    /// The gate actually GATES: an edit to an unrelated plain event must
    /// not rebuild the drawer. This rig has no calendar surface, so
    /// surfaceRebuilds counts the drawer alone — the assertion the
    /// implementer suite had to leave out.
    func testUnrelatedEventEditDoesNotRebuildDrawer() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, title: "Plain", startSeconds: 32_400)])
        rig.todos.addTodo(title: "Kept", now: dayStart)
        let rebuilds = rig.bill.count(.surfaceRebuilds)

        var renamed = rig.store.calendarEvents.first { $0.id == id }!
        renamed.title = "Renamed plain"
        rig.store.replaceCalendarEvent(renamed, now: dayStart)

        XCTAssertEqual(rig.bill.count(.surfaceRebuilds), rebuilds,
                       "an irrelevant delta must not rebuild the drawer (clean counter)")
        XCTAssertEqual(rig.todos.rows.map(\.title), ["Kept"])
    }

    /// Rename of a CURRENT stack todo flows through the rows branch and
    /// updates the row content.
    func testStackTodoRenameUpdatesRow() async throws {
        let rig = try await makeRig()
        rig.todos.addTodo(title: "Old name", now: dayStart)
        guard let id = rig.todos.rows.first?.id,
              var todo = rig.store.calendarEvents.first(where: { $0.id == id }) else {
            return XCTFail("addTodo landed no row")
        }
        todo.title = "New name"
        rig.store.replaceCalendarEvent(todo, now: dayStart)
        XCTAssertEqual(rig.todos.rows.map(\.title), ["New name"])
    }

    /// A bulk delta (affectedDayKeys == nil, here from a recurring series
    /// commit) must reach the drawer — conservative over-invalidation is
    /// the documented contract. Rows are unchanged but the rebuild fires.
    func testBulkRecurringDeltaReachesDrawer() async throws {
        let rig = try await makeRig()
        rig.todos.addTodo(title: "Steady", now: dayStart)
        let rebuilds = rig.bill.count(.todoSurfaceRebuilds)

        let series = Event(
            id: UUID(), title: "Weekly",
            timeRanges: [.init(start: dayStart.addingTimeInterval(32_400),
                               end: dayStart.addingTimeInterval(36_000))],
            repeatUnit: .week, kind: .event
        )
        rig.store.addCalendarEvent(series, now: dayStart)

        XCTAssertEqual(rig.bill.count(.todoSurfaceRebuilds) - rebuilds, 1,
                       "a nil-dayKeys bulk delta is always relevant to the drawer")
        XCTAssertEqual(rig.todos.rows.map(\.title), ["Steady"], "rows themselves are unchanged")
    }
}
