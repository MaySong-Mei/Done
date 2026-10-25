//
//  EventDeletionMotionQATests.swift
//  DoneTests
//
//  Independent QA for the delete-motion spike. Every "does not ghost" /
//  "is dropped" assertion runs beside a positive control on the SAME rig
//  that proves the rig can observe a ghost (or a played motion).
//
//  Observables (the host's ghost list is private):
//    * sublayer count of the host layer — a ghost keeps its subtree
//      parented, a recycle removes it;
//    * a played variant (dissolve, forced in setUp) adds many tiles to the
//      host layer for ~0.9s, a drop adds none;
//    * the 12-ghost cap — a host whose ghost list was NOT drained after a
//      play/drop rejects the 12th fresh ghost, so "12 more ghost" proves the
//      list was emptied.
//
//  Open findings, if any, live in `EventDeletionMotionQAFindings` and are
//  expected RED; there are none open right now.
//

import XCTest
import UIKit
@testable import Done

@MainActor
class EventDeletionMotionQABase: XCTestCase {
    var savedIsEnabled: (() -> Bool)!
    var savedVariant: Any?
    var suiteName: String!
    var defaults: UserDefaults!
    var location: EventStorageLocation!
    var window: UIWindow?

    let variantKey = SpikeFeatureFlag.variantKey(EventDeletionMotionFlag.spikeID)
    let enabledKey = SpikeFeatureFlag.enabledKey(EventDeletionMotionFlag.spikeID)

    override func setUp() {
        super.setUp()
        savedIsEnabled = EventDeletionMotionRegistry.shared.isEnabled
        EventDeletionMotionRegistry.shared.isEnabled = { true }
        savedVariant = UserDefaults.standard.object(forKey: variantKey)
        UserDefaults.standard.set(EventDeletionMotionVariant.dissolve.rawValue, forKey: variantKey)
        suiteName = "EventDeletionMotionQATests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        EventDeletionMotionRegistry.shared.isEnabled = savedIsEnabled
        if let savedVariant {
            UserDefaults.standard.set(savedVariant, forKey: variantKey)
        } else {
            UserDefaults.standard.removeObject(forKey: variantKey)
        }
        window?.isHidden = true
        window = nil
        TestStorage.tearDown(suiteName)
        defaults = nil
        location = nil
        super.tearDown()
    }

    // MARK: Fixtures

    var calendar: Calendar { .current }
    var today: Date { calendar.startOfDay(for: Date()) }
    func day(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: today)! }

    func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    func plainEvent(_ title: String, on date: Date? = nil, hour: Double = 9) -> Event {
        let start = (date ?? today).addingTimeInterval(hour * 3600)
        return Event(title: title, timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))], type: "Study")
    }

    func dailySeries(_ title: String, hour: Double = 9) -> Event {
        var series = plainEvent(title, hour: hour)
        series.repeatUnit = .day
        series.repeatInterval = 1
        return series
    }

    func occurrence(id: String, date: Date? = nil, hour: Double) -> CalendarLayout.EventOccurrence {
        let start = (date ?? today).addingTimeInterval(hour * 3600)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
        return CalendarLayout.EventOccurrence(
            id: id, event: Event(title: id, timeRanges: [range], type: "Study"), range: range
        )
    }

    func model(_ occurrences: [CalendarLayout.EventOccurrence], date: Date? = nil) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: date ?? today,
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

    func makeHost(_ occurrences: [CalendarLayout.EventOccurrence], date: Date? = nil) -> DayLayerHostView {
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        apply(host, occurrences, date: date)
        return host
    }

    func apply(_ host: DayLayerHostView, _ occurrences: [CalendarLayout.EventOccurrence], date: Date? = nil) {
        host.apply(model(occurrences, date: date))
        host.layoutIfNeeded()
    }

    func storeOccurrences(_ store: EventStore, on date: Date) -> [CalendarLayout.EventOccurrence] {
        CalendarLayout.occurrencesForDate(store.rawCalendarEvents, date: date)
    }

    func count(_ host: DayLayerHostView) -> Int { host.layer.sublayers?.count ?? 0 }

    func attachToWindow(_ host: DayLayerHostView) {
        if window == nil {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            w.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            w.isHidden = false
            window = w
        }
        window!.addSubview(host)
        host.layoutIfNeeded()
    }

    /// Runs the main run loop for `seconds`, returning the max sublayer count seen.
    @discardableResult
    func pump(_ seconds: TimeInterval, sampling host: DayLayerHostView? = nil) -> Int {
        let end = Date().addingTimeInterval(seconds)
        var maxCount = host.map(count) ?? 0
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if let host { maxCount = max(maxCount, count(host)) }
        }
        return maxCount
    }
}

@MainActor
final class EventDeletionMotionQATests: EventDeletionMotionQABase {

    // MARK: Claim 1 — flag off is king's shape

    /// The registry's DEFAULT gate reads the spike's enabled key (the
    /// existing test injects the closure, so it never exercised this).
    func testTheDefaultGateFollowsTheSpikeEnabledKey() {
        let saved = UserDefaults.standard.object(forKey: enabledKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: enabledKey) }
            else { UserDefaults.standard.removeObject(forKey: enabledKey) }
        }
        let registry = EventDeletionMotionRegistry()
        let off = UUID(), on = UUID()

        UserDefaults.standard.set(false, forKey: enabledKey)
        registry.mark([off], source: .local)
        XCTAssertNil(registry.mark(for: off), "flag off must mark nothing")

        // Positive control: same registry, same call, key on.
        UserDefaults.standard.set(true, forKey: enabledKey)
        registry.mark([on], source: .local)
        XCTAssertNotNil(registry.mark(for: on))
    }

    /// End to end through the store: flag off ⇒ a real delete recycles the
    /// block exactly like an unmarked removal; flag on (control) ⇒ the same
    /// delete keeps the subtree as a ghost.
    func testFlagOffAStoreDeleteRecyclesAndFlagOnGhosts() {
        func run(enabled: Bool) -> (delta: Int, marked: Bool) {
            EventDeletionMotionRegistry.shared.isEnabled = { enabled }
            let store = makeStore()
            let keep = plainEvent("Keep", hour: 8)
            let doomed = plainEvent("Doomed", hour: 13)
            store.addCalendarEvent(keep)
            store.addCalendarEvent(doomed)
            let host = makeHost(storeOccurrences(store, on: today))
            let before = count(host)
            store.deleteCalendarEvent(store.findCalendarEvent(id: doomed.id)!)
            apply(host, storeOccurrences(store, on: today))
            return (count(host) - before, EventDeletionMotionRegistry.shared.mark(for: doomed.id) != nil)
        }
        let off = run(enabled: false)
        XCTAssertEqual(off.delta, -1, "flag off: the deleted block is recycled")
        XCTAssertFalse(off.marked)
        let on = run(enabled: true)
        XCTAssertEqual(on.delta, 0, "control: flag on, the same delete ghosts")
        XCTAssertTrue(on.marked)
    }

    // MARK: Claim 3 — every deletion entry point marks, nothing else does

    func testDeleteCalendarEventMarksOnlyThatEventAsLocal() {
        let store = makeStore()
        let doomed = plainEvent("Doomed"), bystander = plainEvent("Bystander", hour: 14)
        store.addCalendarEvent(doomed)
        store.addCalendarEvent(bystander)
        store.deleteCalendarEvent(store.findCalendarEvent(id: doomed.id)!)
        XCTAssertEqual(EventDeletionMotionRegistry.shared.mark(for: doomed.id)?.source, .local)
        XCTAssertNil(EventDeletionMotionRegistry.shared.mark(for: bystander.id))
    }

    /// Series daily from today with materialized exceptions on day 1 and
    /// day 3. Occurrence ids are read from the REAL builder (not re-encoded)
    /// for days 0, 2, 4 (days 1/3 are suppressed by their exceptions).
    ///   .all       → whole marks: series + both exceptions.
    ///   .single@2  → span hits ONLY day 2's anchor; series id NOT whole-marked;
    ///                no exception marked.
    ///   .following@2 → span hits day 2 and day 4, not day 0; series id NOT
    ///                whole-marked; swept exception (day 3) whole-marked, the
    ///                day-1 exception not.
    func testRecurringDeleteMarksPerTheSpanContractForEveryScope() {
        for scope in [Event.RecurrenceEditScope.all, .single, .following] {
            let store = makeStore()
            let series = dailySeries("Daily \(scope)")
            store.addCalendarEvent(series)
            for n in [1, 3] {
                store.applyRecurringEdit(
                    seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(n), scope: .single
                ) { $0.title = "Exception \(n)" }
            }
            func exception(_ n: Int) -> Event? {
                store.rawCalendarEvents.first { candidate in
                    candidate.recurrenceParentId == series.id
                        && storeOccurrences(store, on: day(n)).contains(where: { $0.event.id == candidate.id })
                }
            }
            guard let ex1 = exception(1), let ex3 = exception(3) else {
                return XCTFail("fixture: .single edits must materialize exception instances on day 1 and 3")
            }
            func seriesOcc(_ n: Int) -> String {
                storeOccurrences(store, on: day(n)).first { $0.event.id == series.id }!.id
            }
            let occ0 = seriesOcc(0), occ2 = seriesOcc(2), occ4 = seriesOcc(4)
            let r = EventDeletionMotionRegistry.shared
            func span(_ occ: String) -> EventDeletionMotionRegistry.Mark? { r.mark(forOccurrence: occ, of: series.id) }
            XCTAssertNil(span(occ2), "an edit is not a delete")

            store.deleteRecurringCalendarEvent(
                seriesEvent: store.findCalendarEvent(id: series.id)!,
                occurrenceDate: scope == .all ? today : day(2),
                scope: scope
            )
            switch scope {
            case .all:
                XCTAssertEqual(r.mark(for: series.id)?.source, .local)
                XCTAssertEqual(r.mark(for: ex1.id)?.source, .local)
                XCTAssertEqual(r.mark(for: ex3.id)?.source, .local)
            case .single:
                XCTAssertNil(r.mark(for: series.id), ".single must not whole-mark the surviving series")
                XCTAssertEqual(span(occ2)?.source, .local, ".single hits its own anchor day")
                XCTAssertNil(span(occ0), ".single does not reach the day before")
                XCTAssertNil(span(occ4), ".single does not reach later days")
                XCTAssertNil(r.mark(for: ex1.id))
                XCTAssertNil(r.mark(for: ex3.id))
            case .following:
                XCTAssertNil(r.mark(for: series.id), ".following must not whole-mark the capped series")
                XCTAssertEqual(span(occ2)?.source, .local)
                XCTAssertEqual(span(occ4)?.source, .local, ".following is open-ended")
                XCTAssertNil(span(occ0), ".following does not reach before its day")
                XCTAssertEqual(r.mark(for: ex3.id)?.source, .local, "the swept exception is whole-marked")
                XCTAssertNil(r.mark(for: ex1.id), "an exception before the cut survives")
            }
        }
    }

    // MARK: Registry — span marks

    func testAnchorParsesRecurAndAllDayRecurIdsOfThatSeriesOnly() {
        let s = UUID(), other = UUID()
        let R = EventDeletionMotionRegistry.self
        XCTAssertEqual(R.anchor(ofOccurrenceID: "\(s.uuidString)-recur-1700000000", seriesID: s), 1_700_000_000)
        XCTAssertEqual(R.anchor(ofOccurrenceID: "\(s.uuidString)-allday-recur-1700000000", seriesID: s), 1_700_000_000)
        XCTAssertNil(R.anchor(ofOccurrenceID: "\(s.uuidString)-recur-1700000000", seriesID: other))
        XCTAssertNil(R.anchor(ofOccurrenceID: "\(s.uuidString)-1700000000.0-1700003600.0", seriesID: s),
                     "a plain occurrence id has no anchor")
        XCTAssertNil(R.anchor(ofOccurrenceID: "\(s.uuidString)-timer", seriesID: s))
    }

    func testASpanMarkHitsOnlyItsAnchorRange() {
        let r = EventDeletionMotionRegistry()
        r.isEnabled = { true }
        let s = UUID()
        func occ(_ n: Int, allDay: Bool = false) -> String {
            "\(s.uuidString)-\(allDay ? "allday-" : "")recur-\(Int(day(n).timeIntervalSince1970))"
        }
        r.markSeries(s, from: day(2), through: day(2), source: .remote)
        XCTAssertNil(r.mark(forOccurrence: occ(1), of: s))
        XCTAssertEqual(r.mark(forOccurrence: occ(2), of: s)?.source, .remote)
        XCTAssertNotNil(r.mark(forOccurrence: occ(2, allDay: true), of: s))
        XCTAssertNil(r.mark(forOccurrence: occ(3), of: s))
        XCTAssertNil(r.mark(for: s), "a span is not a whole-event mark")
        XCTAssertNil(r.mark(forOccurrence: occ(2), of: UUID()), "another series is untouched")

        let open = UUID()
        func occO(_ n: Int) -> String { "\(open.uuidString)-recur-\(Int(day(n).timeIntervalSince1970))" }
        r.markSeries(open, from: day(2), through: nil, source: .local)
        XCTAssertNil(r.mark(forOccurrence: occO(1), of: open))
        XCTAssertNotNil(r.mark(forOccurrence: occO(2), of: open))
        XCTAssertNotNil(r.mark(forOccurrence: occO(30), of: open))
    }

    func testASpanMarkExpiresAndFlagOffMarksNoSpan() {
        let r = EventDeletionMotionRegistry()
        r.isEnabled = { true }
        let s = UUID()
        let occ = "\(s.uuidString)-recur-\(Int(day(1).timeIntervalSince1970))"
        let t0 = Date()
        r.markSeries(s, from: day(1), through: day(1), source: .local, now: t0)
        XCTAssertNotNil(r.mark(forOccurrence: occ, of: s, now: t0.addingTimeInterval(EventDeletionMotionRegistry.lifetime - 0.01)))
        XCTAssertNil(r.mark(forOccurrence: occ, of: s, now: t0.addingTimeInterval(EventDeletionMotionRegistry.lifetime)))

        let off = EventDeletionMotionRegistry()
        off.isEnabled = { false }
        off.markSeries(s, from: day(1), through: day(1), source: .local)
        XCTAssertNil(off.mark(forOccurrence: occ, of: s))
    }

    func testARemotePlainTombstoneMarksAsRemote() {
        let store = makeStore()
        let doomed = plainEvent("Doomed"), bystander = plainEvent("Bystander", hour: 14)
        store.addCalendarEvent(doomed)
        store.addCalendarEvent(bystander)
        store.applyRemoteCalendarRows(adopts: [], deletions: [store.findCalendarEvent(id: doomed.id)!])
        XCTAssertFalse(store.rawCalendarEvents.contains { $0.id == doomed.id }, "fixture: tombstone applied")
        XCTAssertEqual(EventDeletionMotionRegistry.shared.mark(for: doomed.id)?.source, .remote)
        XCTAssertNil(EventDeletionMotionRegistry.shared.mark(for: bystander.id))
    }

    func testARemoteSeriesTombstoneMarksSeriesAndExceptionAsRemote() {
        let store = makeStore()
        let series = dailySeries("Daily")
        store.addCalendarEvent(series)
        store.applyRecurringEdit(
            seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(1), scope: .single
        ) { $0.title = "Exception" }
        let exception = store.rawCalendarEvents.first { $0.recurrenceParentId == series.id }!
        store.applyRemoteCalendarRows(adopts: [], deletions: [store.findCalendarEvent(id: series.id)!])
        XCTAssertFalse(store.rawCalendarEvents.contains { $0.id == exception.id }, "fixture: cascade ran")
        XCTAssertEqual(EventDeletionMotionRegistry.shared.mark(for: series.id)?.source, .remote)
        XCTAssertEqual(EventDeletionMotionRegistry.shared.mark(for: exception.id)?.source, .remote)
    }

    /// Non-delete mutations (add, move, recurring edit, remote adopt) mark
    /// nothing; the closing delete in the same store is the positive control.
    func testNonDeleteMutationsMarkNothing() {
        let store = makeStore()
        var event = plainEvent("Moved")
        let series = dailySeries("Edited")
        store.addCalendarEvent(event)
        store.addCalendarEvent(series)
        event.timeRanges = [.init(start: day(1).addingTimeInterval(9 * 3600), end: day(1).addingTimeInterval(10 * 3600))]
        store.updateCalendarEvent(event)
        store.applyRecurringEdit(
            seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(1), scope: .all
        ) { $0.title = "Edited all" }
        var remote = store.findCalendarEvent(id: event.id)!
        remote.title = "Remote rename"
        store.applyRemoteCalendarRows(adopts: [remote], deletions: [])
        XCTAssertNil(EventDeletionMotionRegistry.shared.mark(for: event.id))
        XCTAssertNil(EventDeletionMotionRegistry.shared.mark(for: series.id))

        store.deleteCalendarEvent(store.findCalendarEvent(id: event.id)!)
        XCTAssertNotNil(EventDeletionMotionRegistry.shared.mark(for: event.id), "control: the rig sees a mark")
    }

    /// SCOPE NOTE (passes; documents a gap, not a regression): a `.single`
    /// delete on ANOTHER device arrives as an UPDATE of the series row (one
    /// more exception day), not a tombstone, so nothing is marked and the
    /// block vanishes without motion — the spike's purpose text says remote
    /// deletes "都会播".
    func testARemoteSingleOccurrenceDeleteArrivesAsAnUpdateAndIsNotMarked() {
        let store = makeStore()
        let series = dailySeries("Daily")
        store.addCalendarEvent(series)
        var remote = store.findCalendarEvent(id: series.id)!
        remote.appendRecurrenceException(onDay: day(1), calendar: calendar)
        XCTAssertEqual(storeOccurrences(store, on: day(1)).count, 1)
        store.applyRemoteCalendarRows(adopts: [remote], deletions: [])
        XCTAssertEqual(storeOccurrences(store, on: day(1)).count, 0, "fixture: the occurrence left the day")
        XCTAssertNil(EventDeletionMotionRegistry.shared.mark(for: series.id))
    }

    // MARK: Claim 2 — scroll-out / cull recycles a marked block

    func testAMarkedBlockCulledByScrollRecyclesWhileRemovalInTheSameRigGhosts() {
        func rig() -> (UIScrollView, DayLayerHostView, CalendarLayout.EventOccurrence) {
            let b = occurrence(id: "B-\(UUID().uuidString)", hour: 2)
            let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
            sv.contentSize = CGSize(width: 360, height: 2000)
            let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
            sv.addSubview(host)
            apply(host, [b])
            return (sv, host, b)
        }
        // Positive control: same rig, the occurrence leaves the model.
        let (_, ctlHost, ctlB) = rig()
        let ctlBefore = count(ctlHost)
        EventDeletionMotionRegistry.shared.mark([ctlB.event.id], source: .local)
        apply(ctlHost, [])
        XCTAssertEqual(count(ctlHost), ctlBefore, "control: removal of a marked block ghosts")

        // Scroll-out: the occurrence stays in the model, the cull drops it.
        let (sv, host, b) = rig()
        let before = count(host)
        EventDeletionMotionRegistry.shared.mark([b.event.id], source: .local)
        sv.contentOffset = CGPoint(x: 0, y: 1200)
        XCTAssertTrue(host.debugRunCullPass())
        XCTAssertEqual(count(host), before - 1, "a culled marked block must recycle, not ghost")
        // …and scrolling back re-creates it (it was recycled, not hidden).
        sv.contentOffset = .zero
        host.debugRunCullPass()
        XCTAssertEqual(count(host), before)
    }

    // MARK: Claim 4 — cap and drain

    func testTheGhostCapIsTwelve() {
        func run(marked n: Int) -> Int {
            let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
            let doomed = (0..<n).map { occurrence(id: "D\($0)-\(UUID().uuidString)", hour: Double($0)) }
            let host = makeHost([keeper] + doomed)
            let before = count(host)
            EventDeletionMotionRegistry.shared.mark(doomed.map(\.event.id), source: .local)
            apply(host, [keeper])
            return count(host) - before
        }
        XCTAssertEqual(run(marked: 12), 0, "control: 12 ghosts all kept")
        XCTAssertEqual(run(marked: 13), -1, "the 13th is recycled")
    }

    /// A window-attached ghost plays (tiles appear) and is then removed, and
    /// its slot is released: 12 fresh ghosts still fit afterwards.
    func testAPlayedGhostLeavesTheTreeAndReleasesItsSlot() {
        let (host, before, extras, keeper) = makeDrainRig()
        attachToWindow(host)
        let attached = count(host)
        EventDeletionMotionRegistry.shared.mark([extras.target.event.id], source: .local)
        apply(host, [keeper] + extras.rest)
        XCTAssertEqual(count(host), attached, "ghost kept while waiting to play")
        let peak = pump(2.5, sampling: host)
        XCTAssertGreaterThan(peak, attached + 1, "dissolve tiles were added (the motion played)")
        XCTAssertEqual(count(host), attached - 1, "ghost and tiles removed after play")
        _ = before
        assertTwelveFreshGhostsFit(host, keeper: keeper, rest: extras.rest)
    }

    /// Stale: a ghost whose mark is older than the stale limit when the
    /// column comes back is dropped (no tiles) and its slot released. The
    /// positive control is `testAPlayedGhostLeavesTheTreeAndReleasesItsSlot`
    /// (identical rig, fresh mark ⇒ tiles), re-run inline here.
    func testAStaleGhostIsDroppedWithoutPlaying() {
        // Inline positive control on the same rig shape.
        do {
            let (host, _, extras, keeper) = makeDrainRig()
            EventDeletionMotionRegistry.shared.mark([extras.target.event.id], source: .local)
            apply(host, [keeper] + extras.rest)
            let c0 = count(host)
            attachToWindow(host)
            XCTAssertEqual(count(host), c0, "control: a fresh ghost is still there right after attach")
            XCTAssertGreaterThan(pump(2.0, sampling: host), c0, "control: fresh mark plays")
            host.removeFromSuperview()
        }
        let (host, _, extras, keeper) = makeDrainRig()
        EventDeletionMotionRegistry.shared.mark(
            [extras.target.event.id], source: .local, now: Date().addingTimeInterval(-3.9)
        )
        apply(host, [keeper] + extras.rest)
        pump(2.3) // off screen past the 6s stale limit
        let c0 = count(host)
        attachToWindow(host)
        XCTAssertEqual(count(host), c0 - 1, "a stale ghost is removed AT attach, before the settle")
        let peak = pump(1.5, sampling: host)
        XCTAssertLessThanOrEqual(peak, c0 - 1, "a stale ghost must not play")
        XCTAssertEqual(count(host), c0 - 1)
        assertTwelveFreshGhostsFit(host, keeper: keeper, rest: extras.rest)
    }

    /// A ghost claimed on day D whose column shows another day when it gets
    /// to play is dropped, not played; same-day twin plays.
    func testAGhostWhoseColumnChangedDayIsDropped() {
        // The ghost is CLAIMED on today (off window, so it waits); only then
        // does the column move. Claim-time redate rejection is pinned
        // separately in `testARedatedColumnRejectsAWholeMarkedBlockAtClaimTime`.
        func run(redate: Bool) -> (c0: Int, atAttach: Int, peak: Int, final: Int) {
            let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
            let target = occurrence(id: "T-\(UUID().uuidString)", hour: 9)
            let host = makeHost([keeper, target])
            EventDeletionMotionRegistry.shared.mark([target.event.id], source: .local)
            apply(host, [keeper])                           // claim on today
            apply(host, [], date: redate ? day(1) : today)  // column moves (or not)
            let c0 = count(host)
            attachToWindow(host)
            let atAttach = count(host)
            let peak = pump(2.0, sampling: host)
            let result = (c0, atAttach, peak, count(host))
            host.removeFromSuperview()
            return result
        }
        let same = run(redate: false)
        XCTAssertEqual(same.atAttach, same.c0, "control: same-day ghost waits for the settle")
        XCTAssertGreaterThan(same.peak, same.c0, "control: same day plays")
        XCTAssertEqual(same.final, same.c0 - 1)
        let moved = run(redate: true)
        XCTAssertEqual(moved.atAttach, moved.c0 - 1, "a different-day ghost is dropped at attach")
        XCTAssertLessThanOrEqual(moved.peak, moved.c0 - 1, "…and never plays")
        XCTAssertEqual(moved.final, moved.c0 - 1)
    }

    // MARK: Drain helpers

    private struct Extras {
        let target: CalendarLayout.EventOccurrence
        let rest: [CalendarLayout.EventOccurrence]
    }

    /// keeper @20h, target @0h, 12 extras @1h…12h.
    private func makeDrainRig() -> (DayLayerHostView, Int, Extras, CalendarLayout.EventOccurrence) {
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let target = occurrence(id: "T-\(UUID().uuidString)", hour: 0)
        let rest = (1...12).map { occurrence(id: "E\($0)-\(UUID().uuidString)", hour: Double($0)) }
        let host = makeHost([keeper, target] + rest)
        return (host, count(host), Extras(target: target, rest: rest), keeper)
    }

    /// Off window, so the 12 new ghosts just wait: if the earlier ghost was
    /// not removed from the host's list, the cap rejects one of them.
    private func assertTwelveFreshGhostsFit(
        _ host: DayLayerHostView, keeper: CalendarLayout.EventOccurrence, rest: [CalendarLayout.EventOccurrence],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        host.removeFromSuperview()
        let before = count(host)
        EventDeletionMotionRegistry.shared.mark(rest.map(\.event.id), source: .local)
        apply(host, [keeper])
        XCTAssertEqual(count(host), before, "all 12 fresh ghosts fit — the old ghost released its slot",
                       file: file, line: line)
    }
}

/// Round-1 findings (now fixed) kept as regressions, plus round-2 host
/// coverage for span marks, claim-time redate rejection, the
/// same-event-remaining rule and burst lightweight.
@MainActor
final class EventDeletionMotionQARound2Tests: EventDeletionMotionQABase {

    /// Claim 2 ("unmarked / non-deletion removal must recycle"): the mark is
    /// per EVENT but the claim is per OCCURRENCE ID. Within 4s of deleting
    /// one occurrence of a daily series (`.single`, marks the series id),
    /// renaming ANOTHER occurrence of the same series (`.single` edit) swaps
    /// its occurrence id (series occurrence suppressed → exception instance
    /// with its own id) — and the still-existing block plays the delete
    /// motion under the renamed one.
    ///
    /// Compared against the flag-off run of the identical sequence (king's
    /// shape), so chrome/reuse differences cancel. Positive control: a real
    /// `.single` delete of that day's occurrence differs from flag-off by
    /// exactly one (the ghost).
    func testEditingAnotherOccurrenceOfASeriesJustDeletedFromDoesNotGhost() {
        func run(enabled: Bool, deleteInsteadOfRename: Bool) -> Int {
            EventDeletionMotionRegistry.shared.isEnabled = { enabled }
            TestStorage.tearDown(suiteName)
            location = TestStorage.reset(suiteName)
            let store = makeStore()
            let series = dailySeries("Standup")
            store.addCalendarEvent(series)
            let host = makeHost(storeOccurrences(store, on: day(1)), date: day(1))
            XCTAssertEqual(storeOccurrences(store, on: day(1)).count, 1)
            // The delete the mark comes from: another day's occurrence.
            store.deleteRecurringCalendarEvent(
                seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(2), scope: .single
            )
            if deleteInsteadOfRename {
                store.deleteRecurringCalendarEvent(
                    seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(1), scope: .single
                )
            } else {
                store.applyRecurringEdit(
                    seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(1), scope: .single
                ) { $0.title = "Standup (moved room)" }
                XCTAssertEqual(storeOccurrences(store, on: day(1)).count, 1, "fixture: still one block on day 1")
            }
            apply(host, storeOccurrences(store, on: day(1)), date: day(1))
            return count(host)
        }
        let deleteOff = run(enabled: false, deleteInsteadOfRename: true)
        let deleteOn = run(enabled: true, deleteInsteadOfRename: true)
        XCTAssertEqual(deleteOn, deleteOff + 1, "control: a real delete leaves exactly one ghost")

        let renameOff = run(enabled: false, deleteInsteadOfRename: false)
        let renameOn = run(enabled: true, deleteInsteadOfRename: false)
        XCTAssertEqual(renameOn, renameOff, "a renamed (not deleted) occurrence must not ghost")
    }

    /// Same root cause, column side: a host re-pointed to another date (the
    /// day columns are keyed by offset-from-today, so this happens at the
    /// midnight rollover) within 4s of a series mark ghosts the old day's
    /// still-existing occurrence — and `day` is captured from the NEW model,
    /// so the same-day drop check passes and it plays on the new day.
    func testARedatedColumnDoesNotGhostAStillExistingSeriesOccurrence() {
        func run(enabled: Bool) -> Int {
            EventDeletionMotionRegistry.shared.isEnabled = { enabled }
            TestStorage.tearDown(suiteName)
            location = TestStorage.reset(suiteName)
            let store = makeStore()
            let series = dailySeries("Standup")
            store.addCalendarEvent(series)
            let host = makeHost(storeOccurrences(store, on: day(1)), date: day(1))
            store.deleteRecurringCalendarEvent(
                seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(3), scope: .single
            )
            apply(host, storeOccurrences(store, on: day(2)), date: day(2))
            return count(host)
        }
        XCTAssertEqual(run(enabled: true), run(enabled: false),
                       "re-dating a column must not ghost the old day's surviving occurrence")
    }

    /// The repro with `.following`: delete "this and following" from day 3,
    /// then rename day 1 (before the cut) → no ghost on day 1; control: day 4
    /// (after the cut) ghosts.
    func testFollowingDeleteGhostsAfterTheCutAndAnEditBeforeItDoesNot() {
        func run(enabled: Bool, hostDay: Int, renameDay1: Bool) -> Int {
            EventDeletionMotionRegistry.shared.isEnabled = { enabled }
            TestStorage.tearDown(suiteName)
            location = TestStorage.reset(suiteName)
            let store = makeStore()
            let series = dailySeries("Standup")
            store.addCalendarEvent(series)
            let host = makeHost(storeOccurrences(store, on: day(hostDay)), date: day(hostDay))
            store.deleteRecurringCalendarEvent(
                seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(3), scope: .following
            )
            if renameDay1 {
                store.applyRecurringEdit(
                    seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(1), scope: .single
                ) { $0.title = "Renamed" }
            }
            apply(host, storeOccurrences(store, on: day(hostDay)), date: day(hostDay))
            return count(host)
        }
        XCTAssertEqual(run(enabled: true, hostDay: 4, renameDay1: false),
                       run(enabled: false, hostDay: 4, renameDay1: false) + 1,
                       "control: day 4 (after the cut) ghosts")
        XCTAssertEqual(run(enabled: true, hostDay: 1, renameDay1: true),
                       run(enabled: false, hostDay: 1, renameDay1: true),
                       "a rename before the cut must not ghost")
    }

    /// `.single` on day 2 must not ghost day 3's block even if that block
    /// leaves (here: renamed into an exception). Control: day 2 itself ghosts.
    func testSingleDeleteSpanDoesNotReachTheNextDay() {
        func run(enabled: Bool, hostDay: Int) -> Int {
            EventDeletionMotionRegistry.shared.isEnabled = { enabled }
            TestStorage.tearDown(suiteName)
            location = TestStorage.reset(suiteName)
            let store = makeStore()
            let series = dailySeries("Standup")
            store.addCalendarEvent(series)
            let host = makeHost(storeOccurrences(store, on: day(hostDay)), date: day(hostDay))
            store.deleteRecurringCalendarEvent(
                seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(2), scope: .single
            )
            if hostDay != 2 {
                store.applyRecurringEdit(
                    seriesEvent: store.findCalendarEvent(id: series.id)!, occurrenceDate: day(hostDay), scope: .single
                ) { $0.title = "Renamed" }
            }
            apply(host, storeOccurrences(store, on: day(hostDay)), date: day(hostDay))
            return count(host)
        }
        XCTAssertEqual(run(enabled: true, hostDay: 2), run(enabled: false, hostDay: 2) + 1, "control")
        XCTAssertEqual(run(enabled: true, hostDay: 3), run(enabled: false, hostDay: 3), "day after")
        XCTAssertEqual(run(enabled: true, hostDay: 1), run(enabled: false, hostDay: 1), "day before")
    }

    /// The "occurrence left the model" guard is what stops a SPAN mark from
    /// ghosting a block that is merely culled: the mark is set before the
    /// store's removal reaches the host, so a scroll cull in between sees a
    /// span-marked occurrence still in the model. (For whole marks the
    /// same-event check also covers it — QA round 2: removing this guard
    /// survived every whole-mark test.) Control: removal in the same rig ghosts.
    func testASpanMarkedOccurrenceCulledByScrollRecyclesWhileRemovalGhosts() {
        func rig() -> (UIScrollView, DayLayerHostView, CalendarLayout.EventOccurrence, UUID) {
            let seriesID = UUID()
            let start = day(1).addingTimeInterval(2 * 3600)
            let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
            var series = Event(id: seriesID, title: "Daily", timeRanges: [range], type: "Study")
            series.repeatUnit = .day
            series.repeatInterval = 1
            let occ = CalendarLayout.EventOccurrence(
                id: "\(seriesID.uuidString)-recur-\(Int(day(1).timeIntervalSince1970))", event: series, range: range
            )
            let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 300))
            sv.contentSize = CGSize(width: 360, height: 2000)
            let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
            sv.addSubview(host)
            apply(host, [occ], date: day(1))
            EventDeletionMotionRegistry.shared.markSeries(seriesID, from: day(1), through: day(1), source: .local)
            return (sv, host, occ, seriesID)
        }
        let (_, ctlHost, _, _) = rig()
        let ctlBefore = count(ctlHost)
        apply(ctlHost, [], date: day(1))
        XCTAssertEqual(count(ctlHost), ctlBefore, "control: removal of a span-marked occurrence ghosts")

        let (sv, host, _, _) = rig()
        let before = count(host)
        sv.contentOffset = CGPoint(x: 0, y: 1200)
        XCTAssertTrue(host.debugRunCullPass())
        XCTAssertEqual(count(host), before - 1, "a culled span-marked block (still in the model) must recycle")
    }

    /// A whole-marked event whose block leaves because the COLUMN was
    /// re-pointed at another date recycles (renderedDay ≠ model day).
    /// Control: the same removal without the redate ghosts.
    func testARedatedColumnRejectsAWholeMarkedBlockAtClaimTime() {
        func run(redate: Bool, enabled: Bool) -> Int {
            EventDeletionMotionRegistry.shared.isEnabled = { enabled }
            let keeper = occurrence(id: "K-\(UUID().uuidString)", date: day(1), hour: 20)
            let target = occurrence(id: "T-\(UUID().uuidString)", date: day(1), hour: 9)
            let host = makeHost([keeper, target], date: day(1))
            EventDeletionMotionRegistry.shared.mark([target.event.id], source: .local)
            apply(host, [], date: redate ? day(2) : day(1))
            return count(host)
        }
        XCTAssertEqual(run(redate: false, enabled: true), run(redate: false, enabled: false) + 1,
                       "control: same-day removal of a whole-marked block ghosts")
        XCTAssertEqual(run(redate: true, enabled: true), run(redate: true, enabled: false),
                       "a redated column recycles, never ghosts")
    }

    /// Burst: ghosts accumulated off window and scheduled in ONE pass at
    /// attach — the first 3 play the variant, the 4th+ fade. Tile counts:
    /// a dissolve replaces its ghost by T tiles (delta T-1); a fade keeps the
    /// ghost layer and adds nothing (delta 0).
    func testInAnAttachBurstOnlyTheFirstThreePlayTheVariant() {
        let d1 = burstDelta(ghosts: 1, attachFirst: false)
        XCTAssertGreaterThan(d1, 10, "control: one ghost dissolves into tiles")
        XCTAssertEqual(burstDelta(ghosts: 3, attachFirst: false), 3 * d1, "three full motions")
        XCTAssertEqual(burstDelta(ghosts: 5, attachFirst: false), 3 * d1, "the 4th and 5th fade (no tiles)")
    }

    /// Round-2 finding, fixed (in-flight full ghosts count toward the
    /// budget): with the column ON SCREEN each claim schedules itself, so a
    /// burst arrives one ghost per pass — five tombstones in one apply must
    /// still dissolve only three. Off-screen twin:
    /// `testInAnAttachBurstOnlyTheFirstThreePlayTheVariant`.
    func testAnOnScreenBurstAlsoFadesPastTheThird() {
        let d1 = onScreenDelta(1)
        XCTAssertGreaterThan(d1, 10, "control: one on-screen ghost dissolves")
        XCTAssertEqual(onScreenDelta(3), 3 * d1, "control: three on screen all dissolve")
        XCTAssertEqual(onScreenDelta(5), 3 * d1, "on-screen burst of 5: only 3 should dissolve")
    }

    /// The budget is "full motions IN FLIGHT", not "per lifetime of the
    /// column": a 4th delete after the first 3 finished dissolves again.
    /// Control on the same rig: a 4th delete while the 3 are still in
    /// flight fades (adds no tiles of its own).
    func testAFourthGhostAfterTheFirstThreeFinishedPlaysTheVariantAgain() {
        let d1 = onScreenDelta(1)
        XCTAssertGreaterThan(d1, 10, "control: one on-screen ghost dissolves")
        XCTAssertEqual(fourthDelta(waitBetween: 0), 3 * d1,
                       "control: a 4th claimed while 3 are in flight fades (peak is the 3's tiles only)")
        XCTAssertEqual(fourthDelta(waitBetween: 2.5), d1,
                       "after the first 3 finished, the 4th plays the full variant")
    }

    /// Full ghosts that are DROPPED before they play (their column moved to
    /// another day during the settle) release the budget: they add no tiles,
    /// and the next delete on the new day dissolves. Control: the same 3
    /// without the redate dissolve (the burst tests), and a 4th claimed
    /// before the drop happens fades (`fourthDelta(waitBetween: 0)`).
    func testFullGhostsDroppedBeforePlayingReleaseTheBudget() {
        let d1 = onScreenDelta(1)
        XCTAssertGreaterThan(d1, 10, "control: one on-screen ghost dissolves")

        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let doomed = (0..<3).map { occurrence(id: "D\($0)-\(UUID().uuidString)", hour: Double($0 * 2)) }
        let host = makeHost([keeper] + doomed)
        attachToWindow(host)                       // settle ≈ 0.4s from now
        EventDeletionMotionRegistry.shared.mark(doomed.map(\.event.id), source: .local)
        apply(host, [keeper])                      // 3 claimed + scheduled full
        let keeper1 = occurrence(id: "K1-\(UUID().uuidString)", date: day(1), hour: 20)
        let fourth = occurrence(id: "F-\(UUID().uuidString)", date: day(1), hour: 8)
        apply(host, [keeper1, fourth], date: day(1)) // column moves before they play
        let cMoved = count(host)
        let peakDuringDrop = pump(1.0, sampling: host)
        XCTAssertLessThanOrEqual(peakDuringDrop, cMoved, "dropped full ghosts must not play")
        XCTAssertEqual(count(host), cMoved - 3, "the 3 dropped ghosts left the tree")

        EventDeletionMotionRegistry.shared.mark([fourth.event.id], source: .local)
        apply(host, [keeper1], date: day(1))
        let c0 = count(host)
        let peak = pump(2.0, sampling: host)
        host.removeFromSuperview()
        XCTAssertEqual(peak - c0, d1, "the budget was released: the next delete dissolves")
    }

    /// Peak delta of the 4th ghost's pass: 3 deleted on screen, wait, then
    /// a 4th.
    private func fourthDelta(waitBetween wait: TimeInterval) -> Int {
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let doomed = (0..<4).map { occurrence(id: "D\($0)-\(UUID().uuidString)", hour: Double($0 * 2)) }
        let host = makeHost([keeper] + doomed)
        attachToWindow(host)
        pump(0.5)
        EventDeletionMotionRegistry.shared.mark(doomed.prefix(3).map(\.event.id), source: .local)
        apply(host, [keeper, doomed[3]])
        if wait > 0 { pump(wait) }
        EventDeletionMotionRegistry.shared.mark([doomed[3].event.id], source: .local)
        apply(host, [keeper])
        let c0 = count(host)
        let peak = pump(2.0, sampling: host)
        host.removeFromSuperview()
        return peak - c0
    }

    private func onScreenDelta(_ n: Int) -> Int {
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let doomed = (0..<n).map { occurrence(id: "D\($0)-\(UUID().uuidString)", hour: Double($0 * 2)) }
        let host = makeHost([keeper] + doomed)
        attachToWindow(host)
        pump(0.5)
        EventDeletionMotionRegistry.shared.mark(doomed.map(\.event.id), source: .local)
        apply(host, [keeper])
        let c0 = count(host)
        let peak = pump(2.0, sampling: host)
        host.removeFromSuperview()
        return peak - c0
    }

    /// Peak sublayer delta over the pre-play count.
    func burstDelta(ghosts n: Int, attachFirst: Bool) -> Int {
        let keeper = occurrence(id: "K-\(UUID().uuidString)", hour: 20)
        let doomed = (0..<n).map { occurrence(id: "D\($0)-\(UUID().uuidString)", hour: Double($0 * 2)) }
        let host = makeHost([keeper] + doomed)
        if attachFirst { attachToWindow(host); pump(0.5) }
        EventDeletionMotionRegistry.shared.mark(doomed.map(\.event.id), source: .local)
        apply(host, [keeper])
        if !attachFirst { attachToWindow(host) }
        let c0 = count(host)
        let peak = pump(2.0, sampling: host)
        host.removeFromSuperview()
        return peak - c0
    }
}
