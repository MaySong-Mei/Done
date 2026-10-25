//
//  MacInspectorEditTests.swift
//  DoneMacTests
//
//  The inspector hub's edit contract: every field commits through the QA'd
//  store path exactly once, the effort scrubber is the one sanctioned
//  colorDepth write (and round-trips 1...5, clamps off-grid reads), the todo
//  lifecycle toggles clean, and a recurring-series field edit customizes one
//  occurrence (materializes an exception) with the rule + delete scoped.
//

import XCTest
@testable import Done

@MainActor
final class MacInspectorEditTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC

    private struct Rig {
        let store: MacEventStore
        let inspector: EventInspectorModel
        let bill: MacWorkBill
    }

    private func makeRig(events: [Event]) async throws -> Rig {
        let bill = MacWorkBill()
        let store = MacTestStore.make(bill: bill, calendar: calendar)
        await store.load()
        for event in events { store.addCalendarEvent(event, now: dayStart) }
        let inspector = EventInspectorModel(store: store, calendar: calendar)
        return Rig(store: store, inspector: inspector, bill: bill)
    }

    private func event(id: UUID = UUID(), title: String = "E", hour: Double, kind: Event.Kind = .event) -> Event {
        let start = dayStart.addingTimeInterval(hour * 3600)
        return Event(id: id, title: title,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                     kind: kind)
    }

    private func stored(_ rig: Rig, _ id: UUID) -> Event? {
        rig.store.calendarEvents.first { $0.id == id }
    }

    // MARK: - Selection reads live truth

    func testSelectionReadsLiveEvent() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, title: "Original", hour: 9)])
        XCTAssertNil(rig.inspector.event, "nothing selected → no event")
        rig.inspector.select(id)
        XCTAssertEqual(rig.inspector.event?.title, "Original")

        var edited = stored(rig, id)!
        edited.title = "Elsewhere"
        rig.store.replaceCalendarEvent(edited, now: dayStart)
        XCTAssertEqual(rig.inspector.event?.title, "Elsewhere")
    }

    // MARK: - Field commits

    func testSetTitleCommitsOnce() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, title: "Before", hour: 9)])
        rig.inspector.select(id)
        let commits = rig.bill.count(.storeCommits)
        rig.inspector.setTitle(id: id, "After", now: dayStart)
        XCTAssertEqual(rig.bill.count(.storeCommits) - commits, 1)
        XCTAssertEqual(stored(rig, id)?.title, "After")
    }

    func testSetTypeChangesTypeOneCommit() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        rig.inspector.select(id)
        let commits = rig.bill.count(.storeCommits)
        rig.inspector.setType(id: id, "Work", now: dayStart)
        XCTAssertEqual(rig.bill.count(.storeCommits) - commits, 1)
        XCTAssertEqual(stored(rig, id)?.type, "Work")
    }

    func testSetKind() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        rig.inspector.select(id)
        rig.inspector.setKind(id: id, .todo, now: dayStart)
        XCTAssertEqual(stored(rig, id)?.kind, .todo)
    }

    // MARK: - Effort scrubber = the sanctioned colorDepth write

    func testEffortScrubberRoundTrips() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        rig.inspector.select(id)

        for rating in 1...5 {
            rig.inspector.setEffort(id: id, rating, now: dayStart)
            let depth = try XCTUnwrap(stored(rig, id)?.colorDepth)
            XCTAssertEqual(depth, Double(rating) / 5.0, accuracy: 1e-9,
                           "effort \(rating) mirrors to colorDepth")
            XCTAssertEqual(rig.inspector.effortRating, rating,
                           "colorDepth reads back as the same rating")
        }
        rig.inspector.setEffort(id: id, nil, now: dayStart)
        XCTAssertEqual(stored(rig, id)?.colorDepth, 0)
        XCTAssertNil(rig.inspector.effortRating)
    }

    /// QA F2: an OFF-grid colorDepth from a synced/legacy row must read back
    /// clamped to 1...5, never 0 or 8.
    func testEffortRatingClampsOffGridDepth() async throws {
        let id = UUID()
        var e = event(id: id, hour: 9)
        let rig = try await makeRig(events: [])
        for (depth, expected) in [(0.05, 1), (0.099, 1), (0.5, 3), (1.0, 5), (1.5, 5)] {
            e.colorDepth = depth
            if stored(rig, id) == nil {
                rig.store.addCalendarEvent(e, now: dayStart)
            } else {
                rig.store.replaceCalendarEvent(e, now: dayStart)
            }
            rig.inspector.select(id)
            XCTAssertEqual(rig.inspector.effortRating, expected,
                           "colorDepth \(depth) must clamp to \(expected)")
        }
    }

    func testEffortIsOneCommit() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        rig.inspector.select(id)
        let commits = rig.bill.count(.storeCommits)
        rig.inspector.setEffort(id: id, 4, now: dayStart)
        XCTAssertEqual(rig.bill.count(.storeCommits) - commits, 1)
    }

    // MARK: - Time edits (seeded from render ranges)

    /// code-review F2: the Start picker RESIZES (keeps the end), symmetric
    /// with End — it does not move the whole event.
    func testSetStartResizesKeepingEnd() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])  // 09:00–10:00
        rig.inspector.select(id)
        rig.inspector.setStart(id: id, dayStart.addingTimeInterval(8 * 3600), now: dayStart)
        let saved = stored(rig, id)
        XCTAssertEqual(saved?.timeRanges.first?.start, dayStart.addingTimeInterval(8 * 3600),
                       "start moves to 08:00")
        XCTAssertEqual(saved?.timeRanges.first?.end, dayStart.addingTimeInterval(10 * 3600),
                       "the end stays put (resize, not move)")
    }

    /// Start dragged at/past the end clamps to end − 15 min, never inverts.
    func testSetStartClampsPastEnd() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])  // 09:00–10:00
        rig.inspector.select(id)
        rig.inspector.setStart(id: id, dayStart.addingTimeInterval(10 * 3600 + 1800), now: dayStart)  // 10:30
        let saved = stored(rig, id)
        XCTAssertEqual(saved?.timeRanges.first?.start,
                       dayStart.addingTimeInterval(10 * 3600 - 900), "clamped to end − 15 min")
        XCTAssertEqual(saved?.timeRanges.first?.end, dayStart.addingTimeInterval(10 * 3600))
    }

    func testSetEndEnforcesMinimumDuration() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        rig.inspector.select(id)
        rig.inspector.setEnd(id: id, dayStart.addingTimeInterval(8 * 3600), now: dayStart)
        let saved = stored(rig, id)
        XCTAssertEqual(saved?.timeRanges.first?.end,
                       dayStart.addingTimeInterval(9 * 3600 + 900))
    }

    // MARK: - Todo lifecycle

    func testToggleDoneOnTodo() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9, kind: .todo)])
        rig.inspector.select(id)
        rig.inspector.toggleDone(id: id, now: dayStart)
        var saved = stored(rig, id)
        XCTAssertEqual(saved?.isDone, true)
        XCTAssertEqual(saved?.status, .completed)
        XCTAssertEqual(saved?.completeAt, dayStart)

        rig.inspector.toggleDone(id: id, now: dayStart.addingTimeInterval(60))
        saved = stored(rig, id)
        XCTAssertEqual(saved?.isDone, false)
        XCTAssertEqual(saved?.status, .active)
        XCTAssertNil(saved?.completeAt)
    }

    func testToggleDoneIsNoOpOnEvent() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9, kind: .event)])
        rig.inspector.select(id)
        let commits = rig.bill.count(.storeCommits)
        rig.inspector.toggleDone(id: id, now: dayStart)
        XCTAssertEqual(rig.bill.count(.storeCommits), commits, "an event has no done state to toggle")
        XCTAssertEqual(stored(rig, id)?.isDone, false)
    }

    func testSetDeadline() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9, kind: .todo)])
        rig.inspector.select(id)
        let due = dayStart.addingTimeInterval(5 * 86_400)
        rig.inspector.setDeadline(id: id, due, now: dayStart)
        XCTAssertEqual(stored(rig, id)?.deadline, due)
        rig.inspector.setDeadline(id: id, nil, now: dayStart)
        XCTAssertNil(stored(rig, id)?.deadline)
    }

    // MARK: - Return to stack / delete

    func testReturnToStackDropsRangesKeepsDeadline() async throws {
        let id = UUID()
        var todo = event(id: id, hour: 9, kind: .todo)
        let due = dayStart.addingTimeInterval(30 * 86_400)
        todo.deadline = due
        let rig = try await makeRig(events: [todo])
        rig.inspector.select(id)
        rig.inspector.returnToStack(id: id, now: dayStart)
        XCTAssertEqual(stored(rig, id)?.timeRanges, [])
        XCTAssertEqual(stored(rig, id)?.deadline, due)
    }

    func testDeleteRemovesAndClearsSelection() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        rig.inspector.select(id)
        rig.inspector.delete(id: id, occurrenceDate: nil, now: dayStart)
        XCTAssertNil(stored(rig, id))
        XCTAssertNil(rig.inspector.selectedID)
        XCTAssertFalse(rig.inspector.isOpen)
    }

    /// #1: deleting some OTHER block via the context menu must not tear down
    /// an open inspection of a different event.
    func testDeletingOtherBlockKeepsSelection() async throws {
        let a = UUID(), b = UUID()
        let rig = try await makeRig(events: [event(id: a, hour: 9), event(id: b, hour: 11)])
        rig.inspector.select(b)
        rig.inspector.delete(id: a, occurrenceDate: nil, now: dayStart)
        XCTAssertNil(stored(rig, a), "the right-clicked block is gone")
        XCTAssertEqual(rig.inspector.selectedID, b, "the inspected block stays selected")
        XCTAssertTrue(rig.inspector.isOpen)
    }

    // MARK: - Reading is free

    func testReadingEventIsZeroCommits() async throws {
        let id = UUID()
        let rig = try await makeRig(events: [event(id: id, hour: 9)])
        rig.inspector.select(id)
        let commits = rig.bill.count(.storeCommits)
        _ = rig.inspector.event
        _ = rig.inspector.effortRating
        _ = rig.inspector.isRecurringSeries
        _ = rig.inspector.repeatSummary
        XCTAssertEqual(rig.bill.count(.storeCommits), commits, "reads never commit")
    }

    // MARK: - Series editing (A1b: field edits customize one occurrence)

    /// A field edit on a selected SERIES occurrence materializes a `.single`
    /// exception for that day (the series itself is untouched) and re-selects
    /// the concrete instance so further edits target it directly.
    func testSeriesFieldEditMaterializesExceptionAndReselects() async throws {
        let id = UUID()
        var series = event(id: id, title: "Standup", hour: 9)
        series.type = "Work"
        series.repeatUnit = .week
        let rig = try await makeRig(events: [series])
        XCTAssertTrue(series.isRecurringSeries, "fixture really is a series")
        let occ = dayStart.addingTimeInterval(7 * 86_400)   // a later occurrence
        rig.inspector.select(id, occurrenceDate: occ)
        XCTAssertTrue(rig.inspector.isRecurringSeries)

        rig.inspector.setType(id: id, "Study", now: dayStart)

        // The series template is unchanged...
        let template = try XCTUnwrap(stored(rig, id))
        XCTAssertEqual(template.type, "Work", "the series itself keeps its type")
        XCTAssertTrue(template.isRecurringSeries)
        // ...an exception instance carries the edit...
        let instance = try XCTUnwrap(rig.store.calendarEvents.first { $0.recurrenceParentId == id })
        XCTAssertEqual(instance.type, "Study")
        // ...and the pane re-selected that instance (now a concrete row).
        XCTAssertEqual(rig.inspector.selectedID, instance.id)
        XCTAssertFalse(rig.inspector.isRecurringSeries, "selection is now the concrete exception")

        // A second edit lands directly on the instance (no new exception).
        rig.inspector.setEffort(id: instance.id, 5, now: dayStart)
        XCTAssertEqual(rig.store.calendarEvents.filter { $0.recurrenceParentId == id }.count, 1,
                       "editing the re-selected instance does not mint another exception")
        XCTAssertEqual(stored(rig, instance.id)?.colorDepth, 1.0)
    }

    /// The Repeat rule editor, `.all` scope: changes the whole series' cadence.
    func testApplyRepeatAllChangesSeriesCadence() async throws {
        let id = UUID()
        var series = event(id: id, title: "Weekly", hour: 9)
        series.repeatUnit = .week
        let rig = try await makeRig(events: [series])
        rig.inspector.select(id, occurrenceDate: dayStart.addingTimeInterval(7 * 86_400))
        rig.inspector.applyRepeat(unit: .day, interval: 3, endType: .none,
                                  endDate: nil, endCount: nil, scope: .all, now: dayStart)
        let saved = stored(rig, id)
        XCTAssertEqual(saved?.repeatUnit, .day)
        XCTAssertEqual(saved?.repeatInterval, 3)
        XCTAssertEqual(rig.store.calendarEvents.count, 1, ".all edits in place, no split")
    }

    /// The Repeat rule editor, `.following` scope: splits the series and
    /// re-selects the new one.
    func testApplyRepeatFollowingSplitsAndReselects() async throws {
        let id = UUID()
        var series = event(id: id, title: "Weekly", hour: 9)
        series.repeatUnit = .week
        let rig = try await makeRig(events: [series])
        let occ = dayStart.addingTimeInterval(14 * 86_400)
        rig.inspector.select(id, occurrenceDate: occ)
        rig.inspector.applyRepeat(unit: .day, interval: 1, endType: .none,
                                  endDate: nil, endCount: nil, scope: .following, now: dayStart)
        let new = try XCTUnwrap(rig.store.calendarEvents.first { $0.id != id && $0.isRecurringSeries })
        XCTAssertEqual(new.repeatUnit, .day, "the split-off series took the new cadence")
        XCTAssertEqual(rig.inspector.selectedID, new.id, "the pane re-selected the new series")
    }

    /// deleteScoped `.single` on a series skips one day; the series survives.
    func testDeleteScopedSingleSkipsOneDay() async throws {
        let id = UUID()
        var series = event(id: id, title: "Weekly", hour: 9)
        series.repeatUnit = .week
        let rig = try await makeRig(events: [series])
        let occ = dayStart.addingTimeInterval(7 * 86_400)
        rig.inspector.select(id, occurrenceDate: occ)
        rig.inspector.deleteScoped(scope: .single, now: dayStart)
        let saved = try XCTUnwrap(stored(rig, id))
        XCTAssertTrue(saved.isRecurringSeries, "the series survives a single-occurrence delete")
        let key = Event.recurrenceDayKey(for: calendar.startOfDay(for: occ), calendar: calendar)
        XCTAssertTrue(saved.recurrenceExceptionDayKeys.contains(key), "the skipped day is recorded")
        XCTAssertNil(rig.inspector.selectedID, "the pane closed")
    }

    /// deleteScoped `.all` removes the whole series.
    func testDeleteScopedAllRemovesSeries() async throws {
        let id = UUID()
        var series = event(id: id, title: "Weekly", hour: 9)
        series.repeatUnit = .week
        let rig = try await makeRig(events: [series])
        rig.inspector.select(id, occurrenceDate: dayStart.addingTimeInterval(7 * 86_400))
        rig.inspector.deleteScoped(scope: .all, now: dayStart)
        XCTAssertNil(stored(rig, id))
        XCTAssertTrue(rig.store.calendarEvents.isEmpty)
    }

    /// QA F1 regression: a TIME edit on a series occurrence lands on the
    /// CLICKED day, not the template's day 0 — the old bug made the picker
    /// show/write day-0 and silently deleted the real occurrence.
    func testSeriesTimeEditLandsOnClickedDay() async throws {
        let id = UUID()
        var series = event(id: id, title: "Standup", hour: 9)  // 09:00 day 0
        series.repeatUnit = .week
        let rig = try await makeRig(events: [series])
        let occ = dayStart.addingTimeInterval(7 * 86_400)       // day 7 occurrence
        rig.inspector.select(id, occurrenceDate: occ)

        // The picker shows the day-7 occurrence, not day 0.
        let shown = try XCTUnwrap(rig.inspector.occurrenceRange)
        XCTAssertEqual(shown.start, occ.addingTimeInterval(9 * 3600),
                       "the Time picker shows the clicked occurrence's range")

        // Nudge start to 09:30 on day 7 (resize, in range — keeps the 10:00 end).
        rig.inspector.setStart(id: id, occ.addingTimeInterval(9 * 3600 + 1800), now: dayStart)
        let instance = try XCTUnwrap(rig.store.calendarEvents.first { $0.recurrenceParentId == id })
        XCTAssertEqual(instance.timeRanges.first?.start, occ.addingTimeInterval(9 * 3600 + 1800),
                       "the exception lands on day 7 at 09:30, not day 0")
        XCTAssertEqual(instance.timeRanges.first?.end, occ.addingTimeInterval(10 * 3600),
                       "resize keeps the occurrence's 10:00 end")
        // The series records the day-7 exception (so the default day-7 block
        // is replaced by the instance, not duplicated onto day 0).
        let key = Event.recurrenceDayKey(for: calendar.startOfDay(for: occ), calendar: calendar)
        XCTAssertTrue(stored(rig, id)?.recurrenceExceptionDayKeys.contains(key) ?? false)
    }

    /// code-review F4: setting a series occurrence's start/end to the SAME
    /// time it already has must not fork an exception (the generic no-op guard
    /// compared the template's day-0 frame and missed this).
    func testNoopSeriesTimeEditDoesNotFork() async throws {
        let id = UUID()
        var series = event(id: id, title: "Standup", hour: 9)  // 09:00–10:00 template
        series.repeatUnit = .week
        let rig = try await makeRig(events: [series])
        let occ = dayStart.addingTimeInterval(7 * 86_400)
        rig.inspector.select(id, occurrenceDate: occ)
        let commits = rig.bill.count(.storeCommits)
        // The occurrence's current start is 09:00 on its day — set it to that.
        rig.inspector.setStart(id: id, occ.addingTimeInterval(9 * 3600), now: dayStart)
        XCTAssertEqual(rig.bill.count(.storeCommits), commits, "a same-time set must not commit")
        XCTAssertFalse(rig.store.calendarEvents.contains { $0.recurrenceParentId == id },
                       "no phantom exception forked")
    }

    /// QA F2 regression: re-tapping the type/effort a series occurrence
    /// ALREADY has must not fork an exception (a visual no-op).
    func testNoopSeriesFieldEditDoesNotFork() async throws {
        let id = UUID()
        var series = event(id: id, title: "Standup", hour: 9)
        series.type = "Work"
        series.repeatUnit = .week
        let rig = try await makeRig(events: [series])
        rig.inspector.select(id, occurrenceDate: dayStart.addingTimeInterval(7 * 86_400))
        let commits = rig.bill.count(.storeCommits)
        rig.inspector.setType(id: id, "Work", now: dayStart)   // already "Work"
        XCTAssertEqual(rig.bill.count(.storeCommits), commits, "a no-op edit must not commit")
        XCTAssertFalse(rig.store.calendarEvents.contains { $0.recurrenceParentId == id },
                       "no exception forked")
        XCTAssertEqual(rig.inspector.selectedID, id, "selection stays on the series")
    }

    /// review F5 regression: `.following` rule edit on an `.afterCount` series
    /// runs the REMAINING count, not a fresh copy of the whole-series count.
    func testFollowingRuleEditKeepsRemainingCount() async throws {
        let id = UUID()
        var series = event(id: id, title: "Ten", hour: 9)
        series.repeatUnit = .week
        series.repeatEndType = .afterCount
        series.repeatEndCount = 10
        let rig = try await makeRig(events: [series])
        let occ = dayStart.addingTimeInterval(14 * 86_400)   // a later occurrence
        rig.inspector.select(id, occurrenceDate: occ)
        // The SCOPED remaining count the sheet shows for .following — fewer
        // than the whole-series 10 (the engine's authoritative arithmetic).
        let remaining = try XCTUnwrap(Event.scopedRepeatEndCount(
            series: series, occurrenceDate: occ, requestedScope: .following))
        XCTAssertLessThan(remaining, 10, "the scoped count is the REMAINING count")
        rig.inspector.applyRepeat(unit: .week, interval: 1, endType: .afterCount,
                                  endDate: nil, endCount: remaining, scope: .following, now: dayStart)
        let new = try XCTUnwrap(rig.store.calendarEvents.first { $0.id != id && $0.isRecurringSeries })
        XCTAssertEqual(new.repeatEndCount, remaining,
                       "the split-off runs exactly the scoped remaining — not inflated back to 10")
    }

    /// code-review F6: on scope change, the after-count auto-derives the
    /// remaining count ONLY when the cadence is unchanged; a changed cadence
    /// keeps the user's value (a remaining count under a new cadence is
    /// undefined).
    func testScopedAfterCountGatesOnCadenceChange() {
        var series = event(id: UUID(), title: "Ten", hour: 9)
        series.repeatUnit = .week
        series.repeatEndType = .afterCount
        series.repeatEndCount = 10
        let occ = dayStart.addingTimeInterval(14 * 86_400)

        let unchanged = EventInspectorView.scopedAfterCount(
            series: series, draftUnit: .week, draftInterval: 1,
            occurrenceDate: occ, scope: .following, current: 10)
        XCTAssertNotNil(unchanged)
        XCTAssertLessThan(unchanged!, 10, "unchanged cadence → scoped remaining count")

        let cadenceChanged = EventInspectorView.scopedAfterCount(
            series: series, draftUnit: .day, draftInterval: 1,
            occurrenceDate: occ, scope: .following, current: 5)
        XCTAssertEqual(cadenceChanged, 5, "changed cadence → keep the user's count, not the old-cadence remaining")

        let intervalChanged = EventInspectorView.scopedAfterCount(
            series: series, draftUnit: .week, draftInterval: 2,
            occurrenceDate: occ, scope: .following, current: 7)
        XCTAssertEqual(intervalChanged, 7, "changed interval also keeps the user's count")
    }

    // MARK: - Type choices always include the current type (review #6)

    func testTypeChoicesIncludeCustomCurrentType() {
        let templates = [EventTypeTemplate(title: "Work", colorHex: "#0A84FF"),
                         EventTypeTemplate(title: "Study", colorHex: "#34C759")]
        let choices = EventInspectorView.typeChoices(currentType: "Custom-Legacy-Type", templates: templates)
        XCTAssertEqual(choices.first, "Custom-Legacy-Type",
                       "a type absent from the catalog still appears (and is selectable)")
        // A catalog type is not duplicated.
        let dup = EventInspectorView.typeChoices(currentType: "Work", templates: templates)
        XCTAssertEqual(dup.count, Set(dup).count, "no duplicate when current type is already listed")
        XCTAssertEqual(dup.count, 2, "current type already in the catalog isn't prepended again")
    }
}
