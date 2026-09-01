//
//  EventStoreLookupIndexTests.swift
//  DoneTests
//
//  gh#213 slice 1. Two changes, one file of tests.
//
//  CHANGE B — the id→index maps behind `findCalendarEvent(id:)`,
//  `logRecord(for:)` and `feedbackRecord(for:)`. The maps themselves cannot
//  be wrong in an interesting way; the INVALIDATION can, and silently: a map
//  that outlives the mutation that moved its elements returns the wrong event
//  or `nil` for an event that exists, with no error anywhere. So the fixtures
//  below are one per MUTATION SHAPE, and each one is written so a dropped
//  `didSet` produces a WRONG ANSWER rather than an index-out-of-range trap —
//  a red assertion is evidence, a crashed test process is noise.
//
//  The invalidation argument these fixtures back up: `rawCalendarEvents` is a
//  stored property with a `didSet`, and a stored property with an observer
//  gets no `_modify` accessor, so every mutation form compiles to
//  get → mutate a temporary → set. There is no way to change the array
//  through that name without running the setter. These tests are the
//  measurement of that claim rather than a comment repeating it — one test
//  per form the compiler is claimed to route through the setter.
//
//  What these tests do NOT show: that the index is faster. It is a pure
//  optimization, so every one of them also passes against the `first(where:)`
//  linear scan it replaced. Only the device profile settles the speed.
//
//  CHANGE A — one `prefilledLogDraft` per `CalendarEventDetailView` body
//  pass. That one IS observable, via `EventStore.onPrefilledDraftComputed`,
//  and `testDetailBodyPassComputesOneDraft` dies if the hoist is reverted.
//

import XCTest
import SwiftUI
import UIKit
@testable import Done

@MainActor
final class EventStoreLookupIndexTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "EventStoreLookupIndexTests-\(UUID().uuidString)"
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

    // MARK: - Fixtures

    private func makeStore() -> EventStore {
        EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
    }

    private let day = Date(timeIntervalSince1970: 1_770_000_000)

    private func event(_ title: String, id: UUID = UUID()) -> Event {
        Event(
            id: id,
            title: title,
            timeRanges: [.init(start: day, end: day.addingTimeInterval(3600))],
            type: "Study"
        )
    }

    private func occurrence(_ eventID: UUID) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: eventID,
            occurrenceDate: day,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
    }

    /// Force the index to be built, so what follows is testing INVALIDATION
    /// and not a cold first lookup (which cannot be stale).
    private func warmCalendarIndex(_ store: EventStore) {
        _ = store.findCalendarEvent(id: UUID())
    }

    /// What the lookup replaced, kept as the oracle for the differential test.
    private func linearScan(_ store: EventStore, _ id: UUID) -> Event? {
        store.rawCalendarEvents.first(where: { $0.id == id })
    }

    // MARK: - Calendar event index: one fixture per mutation shape

    func testIndexSeesWholesaleReplacement() {
        let store = makeStore()
        let a = event("a")
        store.rawCalendarEvents = [a]
        warmCalendarIndex(store)

        let b = event("b")
        store.rawCalendarEvents = [b]

        XCTAssertNil(store.findCalendarEvent(id: a.id),
                     "load/restore/wipe replace the whole array; the old ids must stop resolving")
        XCTAssertEqual(store.findCalendarEvent(id: b.id)?.title, "b")
    }

    func testIndexSeesAppend() {
        let store = makeStore()
        let a = event("a")
        store.rawCalendarEvents = [a]
        warmCalendarIndex(store)

        let b = event("b")
        store.rawCalendarEvents.append(b)

        XCTAssertEqual(store.findCalendarEvent(id: b.id)?.title, "b",
                       "a warmed index must not hide an appended event")
        XCTAssertEqual(store.findCalendarEvent(id: a.id)?.title, "a")
    }

    func testIndexSeesElementAssignment() {
        let store = makeStore()
        let a = event("a")
        let b = event("b")
        store.rawCalendarEvents = [a, b]
        warmCalendarIndex(store)

        // Slot 0 now holds a DIFFERENT id — the shape `rawCalendarEvents[i] =
        // updatedEvent` takes (syncCalendarEventColorDepthIfNeeded,
        // mutateCalendarEvent's rebase writeback) when the row is replaced
        // wholesale rather than field-patched.
        let c = event("c")
        store.rawCalendarEvents[0] = c

        XCTAssertNil(store.findCalendarEvent(id: a.id), "a is no longer in the array")
        XCTAssertEqual(store.findCalendarEvent(id: c.id)?.title, "c")
        XCTAssertEqual(store.findCalendarEvent(id: b.id)?.title, "b")
    }

    func testIndexSeesFieldMutationThroughSubscript() {
        let store = makeStore()
        let a = event("a")
        store.rawCalendarEvents = [a]
        warmCalendarIndex(store)

        // `rawCalendarEvents[i].field = v` — the form loops in EventStore use
        // (`for i in rawCalendarEvents.indices { rawCalendarEvents[i]... }`).
        // Positions do not move here, so a stale index would still answer
        // correctly; the assertion that matters is that the RETURNED VALUE is
        // re-read from the array rather than served from anything cached.
        store.rawCalendarEvents[0].title = "patched"

        XCTAssertEqual(store.findCalendarEvent(id: a.id)?.title, "patched")
    }

    func testIndexSeesRemoveAll() {
        let store = makeStore()
        let a = event("a")
        let b = event("b")
        let c = event("c")
        store.rawCalendarEvents = [a, b, c]
        warmCalendarIndex(store)

        // The shape `deleteCalendarEvent` uses. Removing the FIRST element
        // shifts every later one, so a stale index answers with the wrong
        // neighbour rather than trapping.
        store.rawCalendarEvents.removeAll { $0.id == a.id }

        XCTAssertNil(store.findCalendarEvent(id: a.id))
        XCTAssertEqual(store.findCalendarEvent(id: b.id)?.title, "b",
                       "a stale index would answer with c, which is what slot 1 holds now")
    }

    func testIndexSeesRemoveAt() {
        let store = makeStore()
        let a = event("a")
        let b = event("b")
        let c = event("c")
        store.rawCalendarEvents = [a, b, c]
        warmCalendarIndex(store)

        store.rawCalendarEvents.remove(at: 0)

        XCTAssertNil(store.findCalendarEvent(id: a.id))
        XCTAssertEqual(store.findCalendarEvent(id: b.id)?.title, "b")
    }

    func testIndexSeesReorder() {
        let store = makeStore()
        let a = event("a")
        let b = event("b")
        store.rawCalendarEvents = [a, b]
        warmCalendarIndex(store)

        store.rawCalendarEvents.reverse()

        XCTAssertEqual(store.findCalendarEvent(id: a.id)?.title, "a",
                       "a reorder moves no ids in or out — a stale index returns b for a")
        XCTAssertEqual(store.findCalendarEvent(id: b.id)?.title, "b")
    }

    func testIndexSeesInOutMutation() {
        let store = makeStore()
        let a = event("a")
        let b = event("b")
        store.rawCalendarEvents = [a, b]
        warmCalendarIndex(store)

        // `&rawCalendarEvents` is copy-in/copy-out through the property's
        // setter — `refreshInterruptRelationStates(in:)` is the production
        // caller of this shape.
        func swapFirstTwo(_ events: inout [Event]) { events.swapAt(0, 1) }
        swapFirstTwo(&store.rawCalendarEvents)

        XCTAssertEqual(store.findCalendarEvent(id: a.id)?.title, "a")
        XCTAssertEqual(store.findCalendarEvent(id: b.id)?.title, "b")
    }

    func testIndexSeesSort() {
        let store = makeStore()
        let a = event("a")
        let b = event("b")
        store.rawCalendarEvents = [b, a]
        warmCalendarIndex(store)

        store.rawCalendarEvents.sort { $0.title < $1.title }

        XCTAssertEqual(store.findCalendarEvent(id: a.id)?.title, "a")
        XCTAssertEqual(store.findCalendarEvent(id: b.id)?.title, "b")
    }

    func testDuplicateIDsResolveToTheFirstMatchLikeTheLinearScan() {
        let store = makeStore()
        let shared = UUID()
        store.rawCalendarEvents = [event("first", id: shared), event("second", id: shared)]

        XCTAssertEqual(store.findCalendarEvent(id: shared)?.title, "first",
                       "duplicate ids are damaged data, but the index and the scan it "
                       + "replaced must be damaged identically")
        XCTAssertEqual(store.findCalendarEvent(id: shared)?.title,
                       linearScan(store, shared)?.title)
    }

    /// Backstop for every shape the per-shape fixtures above do not name:
    /// after each mutation in a scripted sequence, the indexed lookup and the
    /// linear scan it replaced must agree for every id — including ids that
    /// were removed and one that never existed.
    func testIndexedLookupAgreesWithLinearScanAcrossAMutationSequence() {
        let store = makeStore()
        let a = event("a"), b = event("b"), c = event("c"), d = event("d")
        let ghost = UUID()
        let probes = [a.id, b.id, c.id, d.id, ghost]

        func check(_ step: String) {
            for id in probes {
                let indexed = store.findCalendarEvent(id: id)
                let scanned = linearScan(store, id)
                XCTAssertEqual(indexed?.id, scanned?.id, "\(step): id mismatch for \(id)")
                XCTAssertEqual(indexed?.title, scanned?.title, "\(step): element mismatch for \(id)")
            }
        }

        store.rawCalendarEvents = [a, b]; check("assign")
        store.rawCalendarEvents.append(c); check("append")
        store.rawCalendarEvents[1] = d; check("subscript-replace")
        store.rawCalendarEvents[0].title = "a2"; check("field-patch")
        store.rawCalendarEvents.reverse(); check("reverse")
        store.rawCalendarEvents.removeAll { $0.id == c.id }; check("removeAll")
        store.rawCalendarEvents.insert(b, at: 0); check("insert")
        store.rawCalendarEvents.sort { $0.title < $1.title }; check("sort")
        store.rawCalendarEvents.removeAll(); check("removeAll-empty")
        store.rawCalendarEvents = [a, b, c, d]; check("reassign")
        store.mutateCalendarEvent(id: c.id) { $0.title = "c2" }; check("mutateCalendarEvent")
        store.rawCalendarEvents.swapAt(0, 3); check("swapAt")
    }

    /// An empty map is a built map, not an unbuilt one: `nil` must never be
    /// read as "no events". The trap here would be `if let map, !map.isEmpty`.
    func testEmptyArrayIsAnAnswerNotAnUnbuiltIndex() {
        let store = makeStore()
        store.rawCalendarEvents = []
        XCTAssertNil(store.findCalendarEvent(id: UUID()))

        let a = event("a")
        store.rawCalendarEvents = [a]
        XCTAssertEqual(store.findCalendarEvent(id: a.id)?.title, "a",
                       "the empty lookup above must not have cached 'nothing exists'")
    }

    // MARK: - Log / feedback record indices

    func testLogRecordIndexSeesRemovalAndReorder() {
        let store = makeStore()
        let a = event("a")
        let b = event("b")
        store.rawCalendarEvents = [a, b]

        store.upsertLogRecord(for: occurrence(a.id)) { $0.note = "a-note" }
        store.upsertLogRecord(for: occurrence(b.id)) { $0.note = "b-note" }
        XCTAssertEqual(store.logRecord(for: occurrence(a.id))?.note, "a-note")

        store.calendarEventLogRecords.reverse()
        XCTAssertEqual(store.logRecord(for: occurrence(a.id))?.note, "a-note",
                       "reordering the record array must not swap whose log is returned")
        XCTAssertEqual(store.logRecord(for: occurrence(b.id))?.note, "b-note")

        store.calendarEventLogRecords.removeAll { $0.eventID == a.id }
        XCTAssertNil(store.logRecord(for: occurrence(a.id)))
        XCTAssertEqual(store.logRecord(for: occurrence(b.id))?.note, "b-note")

        store.calendarEventLogRecords = []
        XCTAssertNil(store.logRecord(for: occurrence(b.id)),
                     "a wholesale replacement — the restore/sync ingress shape — must land too")
    }

    func testLogRecordIndexSeesAppendAndFieldPatch() {
        let store = makeStore()
        let a = event("a")
        let b = event("b")
        store.rawCalendarEvents = [a, b]

        store.upsertLogRecord(for: occurrence(a.id)) { $0.note = "a-note" }
        XCTAssertNil(store.logRecord(for: occurrence(b.id)))

        // Appending through the real write path, after a miss has warmed the
        // index with b ABSENT — the shape most likely to be served stale.
        store.upsertLogRecord(for: occurrence(b.id)) { $0.note = "b-note" }
        XCTAssertEqual(store.logRecord(for: occurrence(b.id))?.note, "b-note")

        store.calendarEventLogRecords[0].note = "patched"
        XCTAssertEqual(store.logRecord(for: occurrence(a.id))?.note, "patched")
    }

    func testFeedbackRecordIndexSeesRemovalAndReorder() {
        let store = makeStore()
        let a = event("a")
        let b = event("b")
        store.rawCalendarEvents = [a, b]

        store.upsertFeedbackRecord(for: occurrence(a.id)) { $0.selfNote = "a-note" }
        store.upsertFeedbackRecord(for: occurrence(b.id)) { $0.selfNote = "b-note" }
        XCTAssertEqual(store.feedbackRecord(for: occurrence(a.id))?.selfNote, "a-note")

        store.calendarEventFeedbackRecords.reverse()
        XCTAssertEqual(store.feedbackRecord(for: occurrence(a.id))?.selfNote, "a-note")
        XCTAssertEqual(store.feedbackRecord(for: occurrence(b.id))?.selfNote, "b-note")

        store.calendarEventFeedbackRecords.removeAll { $0.eventID == a.id }
        XCTAssertNil(store.feedbackRecord(for: occurrence(a.id)))
        XCTAssertEqual(store.feedbackRecord(for: occurrence(b.id))?.selfNote, "b-note")

        store.calendarEventFeedbackRecords = []
        XCTAssertNil(store.feedbackRecord(for: occurrence(b.id)))
    }

    // MARK: - Change A: one draft per body pass

    /// Put `CalendarEventDetailView` on screen for real, and hand back the
    /// window plus the key window it displaced.
    ///
    /// A `UIHostingController` on its own is not enough, and neither is
    /// `ImageRenderer`: both build `pagerContent` and stop, never evaluating
    /// the `ScrollView` / `TabView` content where the `quick*` readers live.
    /// An `ImageRenderer` version of `testDetailBodyPassComputesOneDraftPerPass`
    /// PASSED against deliberately un-hoisted code — it was measuring only how
    /// many times `pagerContent` itself ran. It takes a window attached to the
    /// host app's real scene, plus a layout pass and a run-loop turn, before
    /// the page content is materialized.
    private func renderDetailView(
        for eventID: UUID,
        store: EventStore
    ) -> (window: UIWindow, displaced: UIWindow?) {
        let route = CalendarEventDetailRoute(occurrence: occurrence(eventID), initialJumpTarget: nil)
        let controller = UIHostingController(
            rootView: CalendarEventDetailView(route: route).environmentObject(store)
        )
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let displaced = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        controller.view.layoutIfNeeded()
        return (window, displaced)
    }

    /// Give the host app its key window back — `DoneTests` runs inside
    /// Done.app, so a window this suite leaves key is a window every later
    /// test inherits.
    private func teardownHost(_ host: (window: UIWindow, displaced: UIWindow?)) {
        host.window.isHidden = true
        host.window.rootViewController = nil
        host.displaced?.makeKeyAndVisible()
    }

    /// Positive control for the harness, written against UIKit BASE classes
    /// rather than the private SwiftUI subclass names they actually are
    /// (`HostingScrollView`, `PagingCollectionView` on iOS 26), so an OS
    /// rename does not silently turn this into a test of nothing.
    private func assertPageContentMaterialized(
        _ window: UIWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var sawScrollView = false
        var sawPagingContainer = false
        func walk(_ view: UIView) {
            if view is UICollectionView { sawPagingContainer = true }
            else if view is UIScrollView { sawScrollView = true }
            view.subviews.forEach(walk)
        }
        walk(window)
        XCTAssertTrue(
            sawScrollView && sawPagingContainer,
            "the detail page's scrolling content was never built, so the draft count below "
            + "measures only how often pagerContent ran — the exact way the ImageRenderer "
            + "version of this test passed against un-hoisted code "
            + "(scrollView=\(sawScrollView) paging=\(sawPagingContainer))",
            file: file, line: line
        )
    }

    /// The point of change A, and the test that dies if it is reverted.
    ///
    /// Mutation-checked rather than argued: with every render-side reader put
    /// back onto its own `prefilledLogDraft` read, this same render computes
    /// 13 drafts. With the hoist it computes 2 — one per body pass SwiftUI
    /// chose to run, and the number that matters is that it tracks BODY
    /// PASSES and not the number of `quick*` readers. The bound sits between
    /// the two measurements with room for a couple of extra passes.
    func testDetailBodyPassComputesOneDraftPerPass() {
        let store = makeStore()
        let a = event("a")
        store.rawCalendarEvents = [a]
        store.upsertLogRecord(for: occurrence(a.id)) { record in
            record.effort = 3
            record.completionStatus = .completed
            record.emotions = ["calm"]
            record.behaviors = ["focused"]
        }

        var drafts = 0
        store.onPrefilledDraftComputed = { _ in drafts += 1 }
        let host = renderDetailView(for: a.id, store: store)
        defer { teardownHost(host) }
        assertPageContentMaterialized(host.window)

        XCTAssertGreaterThan(drafts, 0, "the render never reached the draft — the fixture is wrong, not the code")
        XCTAssertLessThanOrEqual(
            drafts, 8,
            "one detail render must compute the log draft once per body pass, not once per "
            + "quick* reader (gh#213 change A): measured 2 with the hoist, 13 without it"
        )
    }

    /// Why the WRITE path keeps its own fresh read instead of taking the
    /// hoisted draft: a draft is a snapshot, and the action handlers run at
    /// tap time out of a view value built in an earlier body pass.
    func testACapturedDraftGoesStaleAcrossAWriteButAFreshReadDoesNot() {
        let store = makeStore()
        let a = event("a")
        store.rawCalendarEvents = [a]
        let occ = occurrence(a.id)

        let captured = store.prefilledDraft(for: occ)
        XCTAssertNil(captured.effort)

        store.upsertLogRecord(for: occ) { $0.effort = 4 }

        XCTAssertNil(captured.effort,
                     "a hoisted draft is frozen at the body pass that produced it")
        XCTAssertEqual(store.prefilledDraft(for: occ).effort, 4,
                       "commitEffortDrag's idempotence defense (gh#162 W1) depends on this "
                       + "difference: it re-reads so a second commit sees what the first wrote")
    }
}
