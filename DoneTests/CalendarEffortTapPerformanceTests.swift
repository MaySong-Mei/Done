//
//  CalendarEffortTapPerformanceTests.swift
//  DoneTests
//
//  gh#201 — the three fixes on the effort-tap path, each pinned by a fixture
//  that dies if the fix is reverted.
//
//  Fix 1 (touch delivery): the enclosing scroll views held a stationary
//  touch until a delay expired and then delivered down+up together at lift.
//  Pinned by CalendarScrollTouchDelayTests.
//
//  Fix 2 (discarded day-column models): the day-column model was built
//  eagerly by the SwiftUI parent, once per mounted column per body pass, and
//  the host then compared it against what it already held and threw it away
//  in ≥99% of cases. Pinned by CalendarDayLayerApplyKeyTests +
//  CalendarDayOccurrenceSourceTests.
//
//  Fix 3 (colorDepth mirror off the critical path): the effort→colorDepth
//  mirror mutated the @Published calendar array and re-committed the whole
//  calendar-events slot inside the tap's own turn. Pinned by
//  CalendarColorDepthMirrorTests.
//
//  What none of these pin, stated because the repo has been bitten by
//  reports that implied otherwise: the 664–1009 ms post-commit main-thread
//  stall the device traces still show with the mirror AND the log subject
//  removed. None of these fixes addresses it and no test here measures it.
//

import XCTest
import SwiftUI
import UIKit
@testable import Done

// MARK: - Fix 1 — touch delivery

@MainActor
final class CalendarScrollTouchDelayTests: XCTestCase {

    /// Both enclosing scroll views, because both delay independently: the
    /// effort control sits inside the reflection page's vertical ScrollView,
    /// which sits inside the detail pager's paging UIScrollView, and each
    /// one applies its own `delaysContentTouches` hold to a touch destined
    /// for the content below it. Turning it off on the inner one only would
    /// leave the outer one still batching the touch to lift.
    ///
    /// Dies if the walk is narrowed to `.prefix(1)` / "nearest only", or if
    /// it stops before reaching the paging ancestor.
    func testWalkReachesBothTheVerticalScrollViewAndThePager() {
        let pager = UIScrollView()
        pager.isPagingEnabled = true
        let vertical = UIScrollView()
        let content = UIView()
        let probe = UIView()
        pager.addSubview(vertical)
        vertical.addSubview(content)
        content.addSubview(probe)

        let found = calendarScrollViewsDelayingContentTouches(above: probe)

        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.first === vertical, "nearest scroll view first")
        XCTAssertTrue(found.last === pager, "the paging ancestor must be reached too")
    }

    /// The paging scroll view is the OUTER BOUND. A scroll view above it —
    /// whatever presented the detail view — keeps the UIKit default, so this
    /// change cannot leak out of the detail view.
    ///
    /// Dies if the `isPagingEnabled` stop is removed and the walk runs to
    /// the top of the hierarchy.
    func testWalkStopsAtThePagerAndDoesNotReachScrollViewsAboveIt() {
        let outer = UIScrollView()
        let pager = UIScrollView()
        pager.isPagingEnabled = true
        let vertical = UIScrollView()
        let probe = UIView()
        outer.addSubview(pager)
        pager.addSubview(vertical)
        vertical.addSubview(probe)

        let found = calendarScrollViewsDelayingContentTouches(above: probe)

        XCTAssertEqual(found.count, 2)
        XCTAssertFalse(found.contains { $0 === outer }, "nothing above the pager may be touched")
    }

    /// No paging ancestor (a shape the current mount point does not produce)
    /// must SHRINK the blast radius to the nearest scroll view, not widen it
    /// to every scroll view up to the window.
    ///
    /// Dies if the fallback returns `found` instead of `found.prefix(1)`.
    func testWithoutAPagingAncestorOnlyTheNearestScrollViewIsReturned() {
        let outer = UIScrollView()
        let inner = UIScrollView()
        let probe = UIView()
        outer.addSubview(inner)
        inner.addSubview(probe)

        let found = calendarScrollViewsDelayingContentTouches(above: probe)

        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first === inner)
    }

    /// The wiring, not the walk: the probe must actually WRITE the property.
    /// A walk that returns the right scroll views and a probe that never
    /// assigns `delaysContentTouches` would leave every test above green and
    /// the bug entirely unfixed — the exact shape of gap this repo has been
    /// caught by before.
    func testProbeTurnsTheDelayOffOnInstall() {
        let pager = UIScrollView()
        pager.isPagingEnabled = true
        let vertical = UIScrollView()
        pager.addSubview(vertical)

        XCTAssertTrue(pager.delaysContentTouches, "UIKit default, and the positive control for this test")
        XCTAssertTrue(vertical.delaysContentTouches)

        let probe = CalendarScrollTouchDelayProbe.ProbeView()
        vertical.addSubview(probe)

        XCTAssertFalse(vertical.delaysContentTouches)
        XCTAssertFalse(pager.delaysContentTouches)
    }
}

// MARK: - Fix 2 — the deferred occurrence source

@MainActor
final class CalendarDayOccurrenceSourceTests: XCTestCase {

    private func makeOccurrence(
        id: String,
        title: String,
        day: Date,
        startHour: Int,
        durationMinutes: Double = 60
    ) -> CalendarLayout.EventOccurrence {
        let start = Calendar.current.date(byAdding: .hour, value: startHour, to: day)!
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(durationMinutes * 60))
        return CalendarLayout.EventOccurrence(
            id: id,
            event: Event(title: title, timeRanges: [range], type: "Study"),
            range: range
        )
    }

    private var today: Date { Calendar.current.startOfDay(for: Date()) }

    /// The whole point of the key: taken twice off an untouched cache it is
    /// equal, so the day layer can skip without building anything.
    func testKeyIsStableAcrossPassesOverAnUntouchedCache() {
        let day = today
        let cache: [Int: [CalendarLayout.EventOccurrence]] = [
            0: [makeOccurrence(id: "a", title: "A", day: day, startHour: 9)]
        ]
        func source() -> CalendarLayout.DayOccurrenceSource {
            CalendarLayout.timelineVisibleOccurrenceSource(
                forDayOffset: 0, anchorDate: day, occurrencesForOffset: { cache[$0] ?? [] }
            )
        }

        XCTAssertEqual(source().key, source().key)
    }

    /// …and the other half of that: a cache entry that CHANGED must move the
    /// key. A key that misses this is a silently stale column.
    func testKeyChangesWhenTheDaysCachedOccurrencesChange() {
        let day = today
        var cache: [Int: [CalendarLayout.EventOccurrence]] = [
            0: [makeOccurrence(id: "a", title: "A", day: day, startHour: 9)]
        ]
        let before = CalendarLayout.timelineVisibleOccurrenceSource(
            forDayOffset: 0, anchorDate: day, occurrencesForOffset: { cache[$0] ?? [] }
        ).key

        cache[0]?.append(makeOccurrence(id: "b", title: "B", day: day, startHour: 11))
        let afterAdd = CalendarLayout.timelineVisibleOccurrenceSource(
            forDayOffset: 0, anchorDate: day, occurrencesForOffset: { cache[$0] ?? [] }
        ).key
        XCTAssertNotEqual(before, afterAdd, "an added occurrence must move the key")

        cache[0] = [makeOccurrence(id: "a", title: "RENAMED", day: day, startHour: 9)]
        let afterRename = CalendarLayout.timelineVisibleOccurrenceSource(
            forDayOffset: 0, anchorDate: day, occurrencesForOffset: { cache[$0] ?? [] }
        ).key
        XCTAssertNotEqual(before, afterRename, "an edited event inside the same occurrence must move the key")

        cache[0] = [makeOccurrence(id: "a", title: "A", day: day, startHour: 14)]
        let afterMove = CalendarLayout.timelineVisibleOccurrenceSource(
            forDayOffset: 0, anchorDate: day, occurrencesForOffset: { cache[$0] ?? [] }
        ).key
        XCTAssertNotEqual(before, afterMove, "a moved occurrence must move the key")
    }

    /// The anchor day is an input to the filter window, so it is an input to
    /// the key. Without it a column that rolls over midnight while its cache
    /// entry happens to be identical would keep yesterday's list.
    func testKeyChangesWithTheAnchorDay() {
        let day = today
        let cache: [Int: [CalendarLayout.EventOccurrence]] = [
            0: [makeOccurrence(id: "a", title: "A", day: day, startHour: 9)]
        ]
        let a = CalendarLayout.timelineVisibleOccurrenceSource(
            forDayOffset: 0, anchorDate: day, occurrencesForOffset: { cache[$0] ?? [] }
        ).key
        let b = CalendarLayout.timelineVisibleOccurrenceSource(
            forDayOffset: 0,
            anchorDate: Calendar.current.date(byAdding: .day, value: 1, to: day)!,
            occurrencesForOffset: { cache[$0] ?? [] }
        ).key

        XCTAssertNotEqual(a, b)
    }

    /// The two extension-hour counts are inputs twice over: they widen the
    /// visible window AND they decide which adjacent days are pulled in.
    func testKeyChangesWithEachBoundaryExtensionCount() {
        let day = today
        let cache: [Int: [CalendarLayout.EventOccurrence]] = [
            0: [makeOccurrence(id: "a", title: "A", day: day, startHour: 9)]
        ]
        func key(leading: Int, trailing: Int) -> CalendarLayout.DayOccurrenceSource.Key {
            CalendarLayout.timelineVisibleOccurrenceSource(
                forDayOffset: 0,
                anchorDate: day,
                leadingExtendedHours: leading,
                trailingExtendedHours: trailing,
                occurrencesForOffset: { cache[$0] ?? [] }
            ).key
        }

        XCTAssertNotEqual(key(leading: 0, trailing: 0), key(leading: 12, trailing: 0))
        XCTAssertNotEqual(key(leading: 0, trailing: 0), key(leading: 0, trailing: 12))
    }

    /// An adjacent day is an input only when an extension pulls it in — and
    /// then it must be one. Both directions asserted so the key is neither
    /// blind to a real input nor churning on a non-input.
    func testAdjacentDayCountsOnlyWhileItsExtensionIsOpen() {
        let day = today
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        var cache: [Int: [CalendarLayout.EventOccurrence]] = [
            0: [makeOccurrence(id: "a", title: "A", day: day, startHour: 9)],
            -1: [makeOccurrence(id: "y", title: "Y", day: yesterday, startHour: 23)]
        ]
        func key(leading: Int) -> CalendarLayout.DayOccurrenceSource.Key {
            CalendarLayout.timelineVisibleOccurrenceSource(
                forDayOffset: 0,
                anchorDate: day,
                leadingExtendedHours: leading,
                occurrencesForOffset: { cache[$0] ?? [] }
            ).key
        }

        let closedBefore = key(leading: 0)
        let openBefore = key(leading: 12)
        cache[-1] = [makeOccurrence(id: "y", title: "Y-EDITED", day: yesterday, startHour: 23)]

        XCTAssertEqual(closedBefore, key(leading: 0), "yesterday is not an input while the leading band is closed")
        XCTAssertNotEqual(openBefore, key(leading: 12), "yesterday IS an input while the leading band is open")
    }

    /// Key and value must describe the same thing: what `build` returns has
    /// to be exactly what the eager call would have returned. If these two
    /// ever diverge, every "key unchanged ⇒ skip" decision above is unsound.
    func testBuildMatchesTheEagerFunctionItReplaces() {
        let day = today
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day)!
        let cache: [Int: [CalendarLayout.EventOccurrence]] = [
            0: [
                makeOccurrence(id: "b", title: "B", day: day, startHour: 11),
                makeOccurrence(id: "a", title: "A", day: day, startHour: 9)
            ],
            -1: [makeOccurrence(id: "y", title: "Y", day: yesterday, startHour: 23, durationMinutes: 120)]
        ]

        for (leading, trailing) in [(0, 0), (12, 0), (0, 12), (12, 12)] {
            let deferred = CalendarLayout.timelineVisibleOccurrenceSource(
                forDayOffset: 0,
                anchorDate: day,
                leadingExtendedHours: leading,
                trailingExtendedHours: trailing,
                occurrencesForOffset: { cache[$0] ?? [] }
            ).build()
            let eager = CalendarLayout.timelineVisibleOccurrences(
                forDayOffset: 0,
                leadingExtendedHours: leading,
                trailingExtendedHours: trailing,
                anchorDate: day,
                occurrencesForOffset: { cache[$0] ?? [] }
            )
            XCTAssertEqual(deferred, eager, "leading=\(leading) trailing=\(trailing)")
        }
    }
}

// MARK: - Fix 2 — the host's cheap admission test

@MainActor
final class CalendarDayLayerApplyKeyTests: XCTestCase {

    private var day: Date { Calendar.current.startOfDay(for: Date()) }

    private func occurrence(id: String, startHour: Int) -> CalendarLayout.EventOccurrence {
        let start = Calendar.current.date(byAdding: .hour, value: startHour, to: day)!
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
        return CalendarLayout.EventOccurrence(
            id: id,
            event: Event(title: id, timeRanges: [range], type: "Study"),
            range: range
        )
    }

    private func baseModel(
        occurrences: [CalendarLayout.EventOccurrence] = []
    ) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: day,
            occurrences: occurrences,
            contentWidth: 360,
            headerHeight: 16,
            hourHeight: 56,
            eventHorizontalInset: 8,
            leadingExtendedHours: 0,
            trailingExtendedHours: 0,
            drawableLeadingHours: 0,
            drawableTrailingHours: 0,
            useImperativeDayLayerModel: false,
            showEventText: true,
            isWeekMode: false,
            isThreeDayMode: false,
            titleFontSizeSetting: 13,
            showTimeBelowTitle: true,
            multiTypeEnabled: false,
            nearFutureHorizonDays: 7,
            isPinchActive: false,
            frozenSlotMinutes: nil
        )
    }

    private func sourceKey(
        _ occurrences: [CalendarLayout.EventOccurrence]
    ) -> CalendarLayout.DayOccurrenceSource.Key {
        CalendarLayout.timelineVisibleOccurrenceSource(
            forDayOffset: 0, anchorDate: day, occurrencesForOffset: { _ in occurrences }
        ).key
    }

    /// One case per Model field. Each fixture changes exactly ONE field and
    /// asserts the key moved with it — a field that quietly stops
    /// participating is a column that renders stale state forever.
    ///
    /// The `Mirror` check is the half that survives future edits: it fails if
    /// a field is added to `Model` and not given a case here, so this table
    /// cannot silently fall behind the type it is supposed to cover.
    func testEveryModelFieldMovesTheApplyKey() {
        let mutations: [(String, (inout DayLayerHostView.Model) -> Void)] = [
            ("date", { $0.date = $0.date.addingTimeInterval(86_400) }),
            ("contentWidth", { $0.contentWidth += 1 }),
            ("headerHeight", { $0.headerHeight += 1 }),
            ("hourHeight", { $0.hourHeight += 1 }),
            ("eventHorizontalInset", { $0.eventHorizontalInset += 1 }),
            ("leadingExtendedHours", { $0.leadingExtendedHours += 1 }),
            ("trailingExtendedHours", { $0.trailingExtendedHours += 1 }),
            ("drawableLeadingHours", { $0.drawableLeadingHours += 1 }),
            ("drawableTrailingHours", { $0.drawableTrailingHours += 1 }),
            ("useImperativeDayLayerModel", { $0.useImperativeDayLayerModel.toggle() }),
            ("showEventText", { $0.showEventText.toggle() }),
            ("isWeekMode", { $0.isWeekMode.toggle() }),
            ("isThreeDayMode", { $0.isThreeDayMode.toggle() }),
            ("titleFontSizeSetting", { $0.titleFontSizeSetting += 1 }),
            ("showTimeBelowTitle", { $0.showTimeBelowTitle.toggle() }),
            ("multiTypeEnabled", { $0.multiTypeEnabled.toggle() }),
            ("nearFutureHorizonDays", { $0.nearFutureHorizonDays += 1 }),
            ("isPinchActive", { $0.isPinchActive.toggle() }),
            ("frozenSlotMinutes", { $0.frozenSlotMinutes = 30 }),
            ("dayColumnStep", { $0.dayColumnStep += 1 }),
            ("dragPreviewDayStep", { $0.dragPreviewDayStep += 1 }),
            ("creationPreviewRange", { model in
                let start = model.date.addingTimeInterval(3600)
                model.creationPreviewRange = Event.TimeRange(start: start, end: start.addingTimeInterval(1800))
            }),
            ("creationPreviewTitle", { $0.creationPreviewTitle = "Draft" }),
            ("externalDragActive", { $0.externalDragActive.toggle() }),
            ("focusedEventID", { $0.focusedEventID = UUID() }),
            ("focusedOccurrenceID", { $0.focusedOccurrenceID = "occ" }),
            ("graceResizeEventID", { $0.graceResizeEventID = UUID() }),
            ("graceResizeOccurrenceID", { $0.graceResizeOccurrenceID = "occ" }),
            ("graceResizeHandleOpacity", { $0.graceResizeHandleOpacity = 0.5 }),
            ("isFocusContextActive", { $0.isFocusContextActive.toggle() }),
            ("recentlyAbsorbedEventIDs", { $0.recentlyAbsorbedEventIDs = [UUID()] })
        ]

        let occurrenceKey = sourceKey([occurrence(id: "a", startHour: 9)])
        let base = DayLayerHostView.ApplyKey(
            modelWithoutOccurrences: baseModel(), occurrenceKey: occurrenceKey
        )
        XCTAssertEqual(base, DayLayerHostView.ApplyKey(
            modelWithoutOccurrences: baseModel(), occurrenceKey: occurrenceKey
        ), "positive control: an unchanged fixture must produce an equal key")

        for (name, mutate) in mutations {
            var model = baseModel()
            mutate(&model)
            let mutated = DayLayerHostView.ApplyKey(
                modelWithoutOccurrences: model, occurrenceKey: occurrenceKey
            )
            XCTAssertNotEqual(base, mutated, "\(name) must move the ApplyKey")
        }

        let fields = Mirror(reflecting: baseModel()).children.compactMap(\.label)
        XCTAssertEqual(
            Set(fields).subtracting(["occurrences"]),
            Set(mutations.map(\.0)),
            "every Model field except `occurrences` (which the occurrenceKey half covers) needs a case above"
        )
    }

    /// The occurrence half of the key, at the host boundary: same Model
    /// fields, different occurrences, must not be admitted as equal.
    func testOccurrenceChangeAloneMovesTheApplyKey() {
        let a = DayLayerHostView.ApplyKey(
            modelWithoutOccurrences: baseModel(),
            occurrenceKey: sourceKey([occurrence(id: "a", startHour: 9)])
        )
        let b = DayLayerHostView.ApplyKey(
            modelWithoutOccurrences: baseModel(),
            occurrenceKey: sourceKey([occurrence(id: "a", startHour: 9), occurrence(id: "b", startHour: 11)])
        )

        XCTAssertNotEqual(a, b)
    }

    /// The fix itself: the occurrence list is built ONCE for a run of
    /// identical keys, and again as soon as the key moves.
    ///
    /// Dies if `apply(key:…)` builds before comparing (build count 2 on the
    /// repeat) or never rebuilds (build count 1 after the key moves).
    func testOccurrencesAreBuiltOnlyWhenTheKeyChanges() {
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        let first = [occurrence(id: "a", startHour: 9)]
        let second = [occurrence(id: "a", startHour: 9), occurrence(id: "b", startHour: 11)]
        var buildCount = 0

        let keyA = DayLayerHostView.ApplyKey(
            modelWithoutOccurrences: baseModel(), occurrenceKey: sourceKey(first)
        )
        host.apply(key: keyA, makeOccurrences: { buildCount += 1; return first })
        XCTAssertEqual(buildCount, 1)

        host.apply(key: keyA, makeOccurrences: { buildCount += 1; return first })
        XCTAssertEqual(buildCount, 1, "an unchanged key must not build the list at all")

        let keyB = DayLayerHostView.ApplyKey(
            modelWithoutOccurrences: baseModel(), occurrenceKey: sourceKey(second)
        )
        host.apply(key: keyB, makeOccurrences: { buildCount += 1; return second })
        XCTAssertEqual(buildCount, 2, "a moved key must build")
        XCTAssertEqual(host.liveModel?.occurrences, second)
    }

    /// Identical rendering, stated as an equality: what the keyed path
    /// applies is the same Model the eager path applied.
    func testKeyedApplyLandsTheSameModelTheEagerPathWould() {
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        let occurrences = [occurrence(id: "a", startHour: 9), occurrence(id: "b", startHour: 11)]

        host.apply(
            key: DayLayerHostView.ApplyKey(
                modelWithoutOccurrences: baseModel(), occurrenceKey: sourceKey(occurrences)
            ),
            makeOccurrences: { occurrences }
        )

        XCTAssertEqual(host.liveModel, baseModel(occurrences: occurrences))
    }

    /// A direct `apply(_:)` — the imperative coordinator's channel — must
    /// invalidate the cached key. Otherwise a later keyed call carrying the
    /// key that was current BEFORE that write would be admitted as a no-op
    /// and the host would stay parked on the coordinator's model.
    ///
    /// Dies if `currentApplyKey = nil` is dropped from `apply(_:)`.
    func testDirectModelApplyInvalidatesTheCachedKey() {
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        let occurrences = [occurrence(id: "a", startHour: 9)]
        let key = DayLayerHostView.ApplyKey(
            modelWithoutOccurrences: baseModel(), occurrenceKey: sourceKey(occurrences)
        )
        var buildCount = 0

        host.apply(key: key, makeOccurrences: { buildCount += 1; return occurrences })
        XCTAssertEqual(buildCount, 1)

        var coordinatorModel = baseModel(occurrences: occurrences)
        coordinatorModel.hourHeight = 96
        host.apply(coordinatorModel)
        XCTAssertEqual(host.liveModel?.hourHeight, 96)

        host.apply(key: key, makeOccurrences: { buildCount += 1; return occurrences })
        XCTAssertEqual(buildCount, 2, "the key no longer describes what is applied, so it must not be trusted")
        XCTAssertEqual(host.liveModel, baseModel(occurrences: occurrences))
    }
}

// MARK: - Fix 3 — the coalesced colorDepth mirror

@MainActor
final class CalendarColorDepthMirrorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarColorDepthMirrorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    private func occurrence(_ eventID: UUID, on date: Date) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: eventID,
            occurrenceDate: date,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
    }

    private func seed(_ store: EventStore) -> Event {
        let event = Event(
            title: "Deep Work",
            timeRanges: [.init(start: Date(), end: Date().addingTimeInterval(3600))],
            type: "Study"
        )
        store.addCalendarEvent(event)
        return event
    }

    private func colorDepth(of eventID: UUID, in store: EventStore) throws -> Double {
        try XCTUnwrap(store.rawCalendarEvents.first { $0.id == eventID }).colorDepth
    }

    /// The fix: the tap's own turn commits the LOG RECORD (the user's actual
    /// input) and nothing else. The calendar-events slot — a whole-array
    /// re-encode, plus an @Published write every mounted day column reacts
    /// to — no longer rides along with it.
    ///
    /// Dies the moment the mirror goes back to writing inside
    /// `upsertLogRecord`.
    func testTheTapsOwnTurnCommitsOnlyTheLogRecord() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.upsertLogRecord(for: ctx) { $0.effort = 4 }

        XCTAssertEqual(commits, [StorageSlot.calendarEventLogRecords.rawValue])
        XCTAssertEqual(try colorDepth(of: event.id, in: store), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(store.logRecord(for: ctx)).effort, 4)

        store.flushCalendarEventColorDepthMirror()

        XCTAssertEqual(commits, [
            StorageSlot.calendarEventLogRecords.rawValue,
            StorageSlot.calendarEvents.rawValue
        ])
        // Event.colorDepth(forEffort: 4) = 4/5, written longhand: that
        // function is part of what is under test.
        XCTAssertEqual(try colorDepth(of: event.id, in: store), 0.8, accuracy: 0.0001)
    }

    /// Coalescing + last-value-wins, in one fixture: four effort changes in
    /// a row (the step count a real drag across the 5-step track produces)
    /// must reach disk as ONE calendar-events commit carrying the LAST
    /// value, not four commits.
    ///
    /// Dies if the pending map is replaced by an immediate write (4 commits)
    /// or if an earlier value is allowed to win (0.2 instead of 0.8).
    func testRapidChangesCoalesceIntoOneCommitCarryingTheLastValue() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        for step in [1, 2, 3, 4] {
            store.upsertLogRecord(for: ctx) { $0.effort = step }
        }
        store.flushCalendarEventColorDepthMirror()

        XCTAssertEqual(
            commits.filter { $0 == StorageSlot.calendarEventLogRecords.rawValue }.count, 4,
            "each effort change is still its own durable log-record commit"
        )
        XCTAssertEqual(
            commits.filter { $0 == StorageSlot.calendarEvents.rawValue }.count, 1,
            "the four mirrors must coalesce into exactly one calendar-events commit"
        )
        XCTAssertEqual(try colorDepth(of: event.id, in: store), 0.8, accuracy: 0.0001)
    }

    /// The subtle half of last-value-wins. Queue 1.0, then change back to a
    /// value the event ALREADY holds. The second change must supersede the
    /// queued one, not be discarded as a no-op that leaves 1.0 queued.
    ///
    /// Dies if the schedule-time guard compares against `rawCalendarEvents`
    /// instead of the pending value: that mutant early-outs on the second
    /// call, the stale 1.0 survives to the flush, and the last change the
    /// user made loses.
    func testChangingBackToTheStoredValueSupersedesTheQueuedOne() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx) { $0.effort = 3 }
        store.flushCalendarEventColorDepthMirror()
        XCTAssertEqual(try colorDepth(of: event.id, in: store), 0.6, accuracy: 0.0001)

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.upsertLogRecord(for: ctx) { $0.effort = 5 }   // queues 1.0
        store.upsertLogRecord(for: ctx) { $0.effort = 3 }   // back to what is stored
        store.flushCalendarEventColorDepthMirror()

        XCTAssertEqual(try colorDepth(of: event.id, in: store), 0.6, accuracy: 0.0001)
        XCTAssertFalse(
            commits.contains(StorageSlot.calendarEvents.rawValue),
            "nothing actually moved, so nothing may be committed — the same thing the old synchronous epsilon guard did"
        )
    }

    /// An effort change that does not move `colorDepth` still writes nothing,
    /// exactly as the old `abs(...) > 0.0001` guard declined to.
    func testAnUnchangedColorDepthCommitsNothing() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx) { $0.effort = 4 }
        store.flushCalendarEventColorDepthMirror()

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.upsertLogRecord(for: ctx) { $0.effort = 4 }
        store.flushCalendarEventColorDepthMirror()

        XCTAssertFalse(commits.contains(StorageSlot.calendarEvents.rawValue))
        XCTAssertEqual(try colorDepth(of: event.id, in: store), 0.8, accuracy: 0.0001)
    }

    /// Durability: an app that stops running has already committed. The
    /// three lifecycle edges the store subscribes to all flush this, so a
    /// backgrounding inside the coalescing window is not a lost write.
    ///
    /// Dies if the flush is dropped from the lifecycle sink.
    func testResigningActiveFlushesThePendingMirror() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.upsertLogRecord(for: ctx) { $0.effort = 5 }
        XCTAssertFalse(commits.contains(StorageSlot.calendarEvents.rawValue), "positive control: still pending")

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)

        XCTAssertTrue(commits.contains(StorageSlot.calendarEvents.rawValue))
        XCTAssertEqual(try colorDepth(of: event.id, in: store), 1.0, accuracy: 0.0001)
    }

    /// Resolved at flush time, not at schedule time: an event deleted inside
    /// the window has no tint left to mirror, and the flush must drop it
    /// rather than resurrect a row or commit a no-op.
    func testAnEventDeletedInsideTheWindowIsDroppedAtFlush() {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx) { $0.effort = 4 }
        store.deleteCalendarEvent(event)

        var commits: [String] = []
        store.onSlotCommitted = { commits.append($0.rawValue) }
        store.flushCalendarEventColorDepthMirror()

        XCTAssertFalse(commits.contains(StorageSlot.calendarEvents.rawValue))
        XCTAssertNil(store.rawCalendarEvents.first { $0.id == event.id })
    }
}
