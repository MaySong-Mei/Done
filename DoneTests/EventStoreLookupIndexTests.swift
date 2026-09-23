//
//  EventStoreLookupIndexTests.swift
//  DoneTests
//
//  gh#213 slice 1. Two changes, one file of tests.
//
//  CHANGE B — the id→index maps behind `findCalendarEvent(id:)`,
//  `logRecord(for:)` and `feedbackRecord(for:)`. The maps themselves cannot
//  be wrong in an interesting way; the INVALIDATION can. A map that outlives
//  the mutation that moved its elements has TWO failure modes, not one: it
//  returns the wrong row (or `nil` for a row that exists) with no error
//  anywhere, AND — because `findCalendarEvent(id:)` and
//  `mutateCalendarEvent(id:)` subscript with the index they get back — it is
//  a hard `Index out of range` trap whenever the mutation SHRANK the array.
//  The delete path is exactly that shape.
//
//  So the fixtures below are one per MUTATION SHAPE, and each one is written
//  so a dropped `didSet` produces a WRONG ANSWER rather than a trap — a red
//  assertion is evidence, a crashed test process is noise, and a crashed test
//  HOST truncates every suite scheduled after it. Where a fixture has to
//  outlive a shrink it compares `Int?` against `Int?`
//  (`calendarEventIndex(id:)` vs `firstIndex(where:)`) and never dereferences
//  an index it has not first bounds-checked.
//
//  MEASURED, not intended: with the invalidation dropped on all three arrays,
//  this class runs 19 executed / 67 failures / 0 crashes / 0 host relaunches,
//  and 15 of the 19 go red. The earlier version of the sequence fixture below
//  trapped instead, taking the host with it.
//
//  The invalidation argument these fixtures back up, stated so it stays true:
//  `didSet` runs on EVERY WRITE THROUGH THE PROPERTY NAME, whatever accessor
//  form the compiler picks. (NOT "a stored property with an observer gets no
//  `_modify`": these are `@Published`, i.e. wrapper-backed, and for a plain
//  stored property SE-0268 grants a `didSet` that never mentions `oldValue`
//  exactly the in-place `_modify` that argument says cannot exist. See the
//  comment on `EventStore.rawCalendarEvents`.) The one language-level
//  exception is `init`, where Swift skips observers entirely; closed here
//  only because the arrays are filled from `load()`, a method.
//
//  The ORDER of the observer is load-bearing too, and no fixture tested it
//  until `testASynchronousPublishedSubscriberDoesNotStrandAStaleIndex`:
//  `willSet` in place of `didSet` on all three arrays passed 17/17, even
//  though `@Published` publishes in `willSet` and a synchronous subscriber
//  doing a by-id lookup would therefore rebuild the index against the
//  PRE-write array with nothing left to invalidate it. With that fixture the
//  same mutant runs 19 executed / 2 failures, and the failure is the identity
//  swap itself: `findCalendarEvent(id: a.id)` returns `b` after a reverse.
//
//  What these tests do NOT show: that the index is faster. Read-side it is
//  (286x on 1000 reads with no interleaved write, Debug, n = 2000); write-
//  side it is slightly worse (2.6x slower on 500 write+read alternations,
//  3.3x with the target at slot 0). So "pure optimization" is the wrong
//  phrase — but every fixture here also passes against the `first(where:)`
//  linear scan it replaced, which is what makes them correctness tests. Only
//  the device profile settles the speed.
//
//  CHANGE A — one `prefilledLogDraft` per `CalendarEventDetailView` body
//  pass. Observable through TWO seams, deliberately:
//  `EventStore.onPrefilledDraftComputed` counts draft computations and
//  `EventStore.onDetailBodyPass` counts body passes, so the assertion is the
//  invariant `drafts <= passes` rather than a constant. The first version
//  asserted `drafts <= 8` from measurements of 2 (hoisted) and 13 (fully
//  un-hoisted); un-hoisting ONE section produced 6 and sailed through it.
//

import XCTest
import Combine
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
        // updatedEvent` takes (mutateCalendarEvent's rebase writeback; the
        // old synchronous colorDepth mirror also wrote this way before
        // gh#201 queued it) when the row is replaced wholesale rather than
        // field-patched.
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
    ///
    /// Compares `Int?` to `Int?` and NEVER dereferences. The sequence contains
    /// shrinking steps (`removeAll`, `removeAll()`), so with invalidation
    /// dropped a warm index outruns the array's end; the earlier version of
    /// this test called `findCalendarEvent(id:)`, which subscripts, and died
    /// with `Fatal error: Index out of range` — taking the test HOST down and
    /// truncating the run at 251 of 1175 tests under a headline of "15
    /// failures". A crash here is not a stronger signal than an assertion, it
    /// is a weaker one: it destroys the evidence of every test after it.
    func testIndexedLookupAgreesWithLinearScanAcrossAMutationSequence() {
        let store = makeStore()
        let a = event("a"), b = event("b"), c = event("c"), d = event("d")
        let ghost = UUID()
        let probes = [a.id, b.id, c.id, d.id, ghost]

        func check(_ step: String) {
            for id in probes {
                let indexed = store.calendarEventIndex(id: id)
                let scanned = store.rawCalendarEvents.firstIndex(where: { $0.id == id })
                XCTAssertEqual(indexed, scanned, "\(step): index mismatch for \(id)")
                // Bounds-checked before any dereference, so a stale index is a
                // red assertion and not a trap.
                guard let indexed else { continue }
                guard store.rawCalendarEvents.indices.contains(indexed) else {
                    XCTFail("\(step): index \(indexed) is past the end of a "
                            + "\(store.rawCalendarEvents.count)-element array for \(id)")
                    continue
                }
                XCTAssertEqual(store.rawCalendarEvents[indexed].id, id,
                               "\(step): the index points at the wrong element for \(id)")
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

    /// An empty map is a BUILT map, not an unbuilt one: `nil` must never be
    /// read as "no events". The trap is `if let map, !map.isEmpty`, which
    /// distrusts an empty map and rebuilds it on every lookup.
    ///
    /// That trap is invisible to a correctness assertion — a needless rebuild
    /// still returns the right answer, which is why the first version of this
    /// test named the trap and then passed with it applied. It takes
    /// `lookupIndexBuildCount` to see it at all.
    func testEmptyArrayIsABuiltIndexNotAnUnbuiltOne() {
        let store = makeStore()
        store.rawCalendarEvents = []

        let before = store.lookupIndexBuildCount
        XCTAssertNil(store.findCalendarEvent(id: UUID()))
        XCTAssertNil(store.findCalendarEvent(id: UUID()))
        XCTAssertEqual(store.lookupIndexBuildCount - before, 1,
                       "two lookups with no write between them must build the map ONCE, "
                       + "even though the map is empty")

        let a = event("a")
        store.rawCalendarEvents = [a]
        XCTAssertEqual(store.findCalendarEvent(id: a.id)?.title, "a",
                       "the empty lookup above must not have cached 'nothing exists'")
    }

    /// The invalidation is a `didSet`, and the ORDER matters: `@Published`
    /// publishes in `willSet`, BEFORE the new value is stored. Move the
    /// observer to `willSet` and a synchronous subscriber that does a by-id
    /// lookup rebuilds the index against the PRE-write array, and nothing
    /// clears it afterwards — the store is left holding a warm, wrong map.
    ///
    /// Unreachable in production today: every `$rawCalendarEvents` /
    /// `$calendarEventLogRecords` / `$calendarEventFeedbackRecords`
    /// subscriber debounces on `RunLoop.main`
    /// (`SupabaseSyncService:510/520/530`, `BackupSnapshotService:96-98`,
    /// `ImageBackupCoordinator:81`). That is a fact about today's call sites,
    /// not about `EventStore`, so it is pinned here rather than assumed. A
    /// reorder is used on purpose: no id enters or leaves, so a stale index
    /// swaps identities instead of running off the end.
    func testASynchronousPublishedSubscriberDoesNotStrandAStaleIndex() {
        let store = makeStore()
        let a = event("a")
        let b = event("b")
        store.rawCalendarEvents = [a, b]

        var lookupsFromSubscriber = 0
        let cancellable = store.$rawCalendarEvents.sink { [weak store] _ in
            guard let store else { return }
            lookupsFromSubscriber += 1
            _ = store.findCalendarEvent(id: a.id)
        }
        defer { cancellable.cancel() }

        store.rawCalendarEvents.reverse()

        XCTAssertGreaterThanOrEqual(
            lookupsFromSubscriber, 2,
            "positive control: the subscriber must have run on subscribe AND on the "
            + "write, or this test pins nothing"
        )
        XCTAssertEqual(store.findCalendarEvent(id: a.id)?.title, "a",
                       "a synchronous subscriber rebuilt the index while the store still "
                       + "held the pre-write array; only a post-write invalidation clears it")
        XCTAssertEqual(store.findCalendarEvent(id: b.id)?.title, "b")
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
    /// Asserts an INVARIANT, not a constant: draft computations must not
    /// outnumber body passes. The first version asserted `drafts <= 8` from
    /// measurements of 2 (hoisted) and 13 (fully un-hoisted) — a revert
    /// detector, not a regression detector. Un-hoisting `signalsQuickSection`
    /// alone produces 6 and cannot pass this one. Measured on this rig: 2
    /// drafts across 2 passes as written, 6 across the same 2 passes with
    /// `signalsQuickSection` un-hoisted, 13 fully un-hoisted. The invariant
    /// also stops depending on SwiftUI's pass count staying at 2.
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
        var passes = 0
        store.onPrefilledDraftComputed = { _ in drafts += 1 }
        store.onDetailBodyPass = { _ in passes += 1 }
        let host = renderDetailView(for: a.id, store: store)
        defer { teardownHost(host) }
        assertPageContentMaterialized(host.window)

        XCTAssertGreaterThan(passes, 0,
                             "the render never reached pagerContent — the fixture is wrong, "
                             + "not the code")
        XCTAssertGreaterThan(drafts, 0,
                             "the render never reached the draft — the fixture is wrong, "
                             + "not the code")
        XCTAssertLessThanOrEqual(
            drafts, passes,
            "one detail render must compute the log draft once per BODY PASS, not once per "
            + "reader (gh#213 change A): \(drafts) drafts across \(passes) passes"
        )
    }

    /// The one state where the hoist changes the shape rather than only the
    /// count: `let draft = prefilledLogDraft` sits above the `currentEvent`
    /// fork in `pagerContent`, so it runs even after the event is gone.
    ///
    /// Measured rather than argued, because the obvious worry ("0 → 1 per
    /// pass on a page that can get stuck in exactly this state") assumes the
    /// old readers were all inside the `currentEvent` guard, and two of them
    /// —`completionQuickSection` and `signalsQuickSection` — were not. The
    /// invariant is the same one as above and must hold here too.
    func testDetailBodyPassHoldsWhenTheEventIsGone() {
        let store = makeStore()
        let a = event("a")
        store.rawCalendarEvents = [a]
        store.rawCalendarEvents.removeAll { $0.id == a.id }
        XCTAssertNil(store.findCalendarEvent(id: a.id), "fixture: the event must be gone")

        var drafts = 0
        var passes = 0
        store.onPrefilledDraftComputed = { _ in drafts += 1 }
        store.onDetailBodyPass = { _ in passes += 1 }
        let host = renderDetailView(for: a.id, store: store)
        defer { teardownHost(host) }
        assertPageContentMaterialized(host.window)

        XCTAssertGreaterThan(passes, 0, "the render never reached pagerContent")
        XCTAssertLessThanOrEqual(
            drafts, passes,
            "a detail page whose event was deleted must not compute more drafts than body "
            + "passes either: \(drafts) drafts across \(passes) passes"
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

    // MARK: - currentEvent id-index fast path (gh#213 / gh#219)

    /// A recurring SERIES: `repeatUnit != .none`, no parent, no instance date.
    /// `event(_:id:)` already leaves the recurrence fields nil, so this is the
    /// one field that flips `isRecurringSeries` on.
    private func recurringSeries(_ title: String, id: UUID = UUID()) -> Event {
        var series = event(title, id: id)
        series.repeatUnit = .day
        return series
    }

    /// The point of the gh#213/#219 reroute, and the test that dies if
    /// `currentEvent` goes back to always calling the resolver.
    ///
    /// `lookupIndexBuildCount` cannot see this (it counts BUILDS, and the
    /// warm index a resolver fallback also consults bumps nothing), so the
    /// assertion rides `onCurrentEventResolution`, which reports whether each
    /// `currentEvent` read served the plain event from the O(1) index or fell
    /// back to the O(N) `calendarResolvedEventForOccurrenceContext` linear
    /// scan. A plain event must NEVER fall back: opening its detail runs zero
    /// resolver scans.
    func testOpeningANonRecurringDetailNeverRunsTheResolverLinearScan() {
        let store = makeStore()
        let a = event("a")
        store.rawCalendarEvents = [a]
        XCTAssertFalse(store.findCalendarEvent(id: a.id)?.isRecurringSeries ?? true,
                       "fixture: the event must be a plain non-recurring event")

        var fastPathHits = 0
        var resolverFallbacks = 0
        store.onCurrentEventResolution = { usedFastPath in
            if usedFastPath { fastPathHits += 1 } else { resolverFallbacks += 1 }
        }
        let host = renderDetailView(for: a.id, store: store)
        defer {
            store.onCurrentEventResolution = nil
            teardownHost(host)
        }
        assertPageContentMaterialized(host.window)

        XCTAssertGreaterThan(fastPathHits, 0,
                             "positive control: the render never resolved currentEvent, so the "
                             + "fallback count below pins nothing — the fixture is wrong, not the code")
        XCTAssertEqual(resolverFallbacks, 0,
                       "opening a plain non-recurring detail must resolve entirely through the "
                       + "O(1) id index and never fall back to the O(N) "
                       + "calendarResolvedEventForOccurrenceContext scan (gh#213/#219): "
                       + "\(resolverFallbacks) fallback(s) across \(fastPathHits) fast-path hits")
    }

    /// The other side of the fork: a recurring series must NOT take the fast
    /// path. Its `isRecurringSeries` hit falls back to the resolver so the
    /// recurrenceOccurrence + day-key exception scan (the gh#127 tz-change
    /// path) still runs — short-circuiting it is the #1 regression this fix
    /// guards against. Opened on its own series-start day so the occurrence
    /// resolves and the page materializes.
    func testOpeningARecurringDetailFallsBackToTheResolver() {
        let store = makeStore()
        let series = recurringSeries("standup")
        store.rawCalendarEvents = [series]
        XCTAssertTrue(store.findCalendarEvent(id: series.id)?.isRecurringSeries ?? false,
                      "fixture: the event must be a recurring series")

        var fastPathHits = 0
        var resolverFallbacks = 0
        store.onCurrentEventResolution = { usedFastPath in
            if usedFastPath { fastPathHits += 1 } else { resolverFallbacks += 1 }
        }
        let host = renderDetailView(for: series.id, store: store)
        defer {
            store.onCurrentEventResolution = nil
            teardownHost(host)
        }
        assertPageContentMaterialized(host.window)

        XCTAssertGreaterThan(resolverFallbacks, 0,
                             "a recurring series must resolve through "
                             + "calendarResolvedEventForOccurrenceContext — its recurrenceOccurrence "
                             + "+ day-key exception scan (gh#127) is the only correct route: "
                             + "\(resolverFallbacks) fallback(s)")
        XCTAssertEqual(fastPathHits, 0,
                       "a recurring series must never be served by the non-recurring fast path "
                       + "(the #1 gh#127 regression this fix guards against): \(fastPathHits) hit(s)")
    }

    // MARK: - Independent QA: currentEvent ≡ resolver equivalence witness (gh#213/#219)
    //
    // Written by an independent reviewer who does NOT trust the implementer's
    // own case analysis. The load-bearing claim is that the rerouted
    // `currentEvent` returns, for EVERY case, the same event the ORIGINAL
    // `calendarResolvedEventForOccurrenceContext` linear scan would — that
    // free function is untouched by the fix, so calling it directly is the
    // reference oracle. `currentEvent` is private, but its value is fully
    // determined by (a) which fork it took — observed through the real render
    // via `onCurrentEventResolution` — and (b) the two production functions it
    // returns from, `store.findCalendarEvent(id:)` (fast path) and the
    // resolver (fallback), both callable here. So:
    //   fast path taken  ⟹ currentEvent == findCalendarEvent(id:)  — asserted == resolver
    //   fallback taken   ⟹ currentEvent == resolver               — trivially equal (same call)
    // No hidden transform sits between findCalendarEvent's result and the
    // `return hit`, verified by reading the diff. Every expectation below is
    // computed by hand, then cross-checked against the oracle.

    /// The ORIGINAL behavior, untouched by the fix: what `currentEvent` MUST
    /// still return for the given occurrence.
    private func resolverOracle(
        _ store: EventStore,
        _ occ: CalendarEventOccurrenceContext
    ) -> Event? {
        calendarResolvedEventForOccurrenceContext(occ, in: store.rawCalendarEvents)
    }

    /// A detached exception instance addressed by its OWN id: parent set,
    /// instance date set (so `isExceptionInstance` is true), `.none` repeat
    /// (so `isRecurringSeries` is false).
    private func detachedInstance(
        parent: UUID,
        _ title: String,
        id: UUID = UUID()
    ) -> Event {
        Event(
            id: id,
            title: title,
            timeRanges: [.init(start: day, end: day.addingTimeInterval(3600))],
            type: "Study",
            recurrenceParentId: parent,
            recurrenceInstanceDate: Calendar.current.startOfDay(for: day)
        )
    }

    /// Render the real detail page for `eventID`, counting fast-path vs
    /// fallback resolutions of the real `currentEvent`, and whether the
    /// scrolling content materialized (so a green count isn't a page that
    /// never rendered). Restores the host window like the implementer's tests.
    private func openDetailCountingResolutions(
        for eventID: UUID,
        store: EventStore
    ) -> (fast: Int, fallback: Int, sawScroll: Bool, sawPaging: Bool) {
        var fast = 0
        var fallback = 0
        store.onCurrentEventResolution = { usedFastPath in
            if usedFastPath { fast += 1 } else { fallback += 1 }
        }
        let host = renderDetailView(for: eventID, store: store)
        var sawScroll = false
        var sawPaging = false
        func walk(_ view: UIView) {
            if view is UICollectionView { sawPaging = true }
            else if view is UIScrollView { sawScroll = true }
            view.subviews.forEach(walk)
        }
        walk(host.window)
        store.onCurrentEventResolution = nil
        teardownHost(host)
        return (fast, fallback, sawScroll, sawPaging)
    }

    /// Case ① — a PLAIN non-recurring exact hit, parked at a non-zero slot
    /// behind a decoy so an index that returned "slot 0 regardless" would
    /// diverge from the linear scan. currentEvent must take the fast path and
    /// its value (findCalendarEvent) must equal the resolver's.
    func testEquivalenceWitness_plainExactHit_indexPathMatchesLinearScan() {
        let store = makeStore()
        let decoyA = event("decoyA")
        let target = event("target")
        let decoyB = event("decoyB")
        store.rawCalendarEvents = [decoyA, target, decoyB]
        let occ = occurrence(target.id)

        // Independent expectation: the linear scan finds `target` at slot 1.
        XCTAssertEqual(store.rawCalendarEvents.first(where: { $0.id == target.id })?.id,
                       target.id, "hand-check: the scan lands on the target")
        let ref = resolverOracle(store, occ)
        XCTAssertEqual(ref?.id, target.id, "oracle: the resolver's exact branch returns the target")

        let cap = openDetailCountingResolutions(for: target.id, store: store)
        XCTAssertTrue(cap.sawScroll && cap.sawPaging,
                      "the page must materialize, or the counts below pin nothing")
        XCTAssertGreaterThan(cap.fast, 0,
                             "positive control: the render resolved currentEvent at least once")
        XCTAssertEqual(cap.fallback, 0,
                       "a plain exact hit must resolve entirely through the O(1) index — "
                       + "\(cap.fallback) resolver fallback(s)")
        // The value witness: currentEvent's fast-path return IS
        // findCalendarEvent(id:), which must equal the resolver's value.
        XCTAssertEqual(store.findCalendarEvent(id: target.id)?.id, ref?.id,
                       "index path and linear-scan resolver must return the SAME event")
    }

    /// Case ② — a bare recurring SERIES with a live occurrence on the opened
    /// day. currentEvent must FALL BACK (a series never fast-paths), and the
    /// resolver returns the series itself (occurrence present, no exception).
    func testEquivalenceWitness_recurringSeries_fallsBackToResolver() {
        let store = makeStore()
        let series = recurringSeries("standup")
        store.rawCalendarEvents = [series]
        let occ = occurrence(series.id)

        // Independent expectation: daily series seeded on `day`, no exception →
        // recurrenceOccurrence is present → resolver returns the series.
        XCTAssertNotNil(CalendarLayout.recurrenceOccurrence(for: series, on: day, calendar: .current),
                        "hand-check: the series has a live occurrence on the opened day")
        let ref = resolverOracle(store, occ)
        XCTAssertEqual(ref?.id, series.id, "oracle: a live series occurrence resolves to the series")

        let cap = openDetailCountingResolutions(for: series.id, store: store)
        XCTAssertTrue(cap.sawScroll && cap.sawPaging, "the page must materialize")
        XCTAssertGreaterThan(cap.fallback, 0,
                             "a recurring series must resolve through the resolver — "
                             + "its recurrenceOccurrence path is the only correct route")
        XCTAssertEqual(cap.fast, 0,
                       "a series must NEVER take the non-recurring fast path (the #1 regression): "
                       + "\(cap.fast) fast-path hit(s)")
        // Fallback returns the resolver verbatim → currentEvent == ref = series.
    }

    /// Case ③ — a DETACHED exception instance addressed by its OWN id. It is
    /// `isExceptionInstance` (not a series), so the extra `!isExceptionInstance`
    /// conjunct routes it to the fallback (over-restrictive, honoring the red
    /// line's literal "never short-circuit a detached instance"). The resolver's
    /// non-series exact branch returns it unchanged — same event either way.
    func testEquivalenceWitness_detachedInstanceByOwnId_fallsBackAndAgrees() {
        let store = makeStore()
        let seriesID = UUID()
        let decoy = event("decoy")
        let instance = detachedInstance(parent: seriesID, "moved")
        store.rawCalendarEvents = [decoy, instance]
        let occ = occurrence(instance.id)

        XCTAssertTrue(instance.isExceptionInstance, "fixture: parent + instance date set")
        XCTAssertFalse(instance.isRecurringSeries, "fixture: .none repeat, so not a series")
        let ref = resolverOracle(store, occ)
        XCTAssertEqual(ref?.id, instance.id,
                       "oracle: the resolver's non-series exact branch returns the instance itself")

        let cap = openDetailCountingResolutions(for: instance.id, store: store)
        XCTAssertTrue(cap.sawScroll && cap.sawPaging, "the page must materialize")
        XCTAssertGreaterThan(cap.fallback, 0,
                             "a detached instance must fall back to the resolver (red-line #1 literal)")
        XCTAssertEqual(cap.fast, 0,
                       "the !isExceptionInstance conjunct keeps a detached instance off the fast path: "
                       + "\(cap.fast) fast-path hit(s)")
        // The value still has to agree: index and scan must find the same event.
        XCTAssertEqual(store.findCalendarEvent(id: instance.id)?.id, ref?.id,
                       "even on the fallback route, the index must agree with the linear scan")
    }

    /// Case ④ — an id ABSENT from the store. findCalendarEvent is nil, so the
    /// fast path is skipped and currentEvent falls back to the resolver's
    /// parent scan, which also returns nil. No fast-path hit is possible.
    func testEquivalenceWitness_idNotFound_fallsBackToNil() {
        let store = makeStore()
        store.rawCalendarEvents = [event("a"), event("b")]
        let ghost = UUID()
        let occ = occurrence(ghost)

        XCTAssertNil(store.rawCalendarEvents.first(where: { $0.id == ghost }),
                     "hand-check: the ghost id is absent")
        XCTAssertNil(resolverOracle(store, occ), "oracle: an absent id resolves to nil")
        XCTAssertNil(store.findCalendarEvent(id: ghost), "index agrees: nil for an absent id")

        let cap = openDetailCountingResolutions(for: ghost, store: store)
        XCTAssertGreaterThan(cap.fallback, 0,
                             "a not-found id must reach the resolver fallback (nil hit ⇒ no fast path)")
        XCTAssertEqual(cap.fast, 0,
                       "a nil index hit cannot satisfy `if let hit`, so the fast path is impossible: "
                       + "\(cap.fast) fast-path hit(s)")
    }

    /// Case ⑤ — the gh#127 tz-change path, and the ONLY case where the fast
    /// path and the correct answer DIFFER by value: a series that SUPPRESSES
    /// its occurrence on the opened day, plus a detached replacement sharing
    /// that day's nominal key. Addressed by the SERIES id, the resolver's
    /// day-key exception scan must return the REPLACEMENT, not the series.
    /// If the fast path ever short-circuited the series it would return the
    /// series — a different event — so this is the value-level guard against
    /// the #1 regression.
    func testEquivalenceWitness_seriesWithDetachedException_resolvesToReplacementNotSeries() {
        let store = makeStore()
        var series = recurringSeries("standup")
        // The series gives up its own occurrence on `day`.
        series.appendRecurrenceException(onDay: day, calendar: .current)
        // A detached replacement on the same nominal day, at a different clock
        // time so it is unmistakably a distinct event.
        let replacement = Event(
            id: UUID(),
            title: "moved-standup",
            timeRanges: [.init(start: day.addingTimeInterval(7200),
                               end: day.addingTimeInterval(9000))],
            type: "Study",
            recurrenceParentId: series.id,
            recurrenceInstanceDate: Calendar.current.startOfDay(for: day),
            recurrenceInstanceDayKey: Event.recurrenceDayKey(for: day, calendar: .current)
        )
        store.rawCalendarEvents = [series, replacement]
        let occ = occurrence(series.id)

        // Independent expectations, computed by hand and pinned:
        XCTAssertNil(CalendarLayout.recurrenceOccurrence(for: series, on: day, calendar: .current),
                     "fixture: the series must suppress its occurrence on the exception day")
        XCTAssertTrue(replacement.recurrenceInstanceMatches(
                        day: Calendar.current.startOfDay(for: day), calendar: .current),
                      "fixture: the replacement must match the suppressed day's key")
        let ref = resolverOracle(store, occ)
        XCTAssertEqual(ref?.id, replacement.id,
                       "oracle: the gh#127 day-key scan returns the REPLACEMENT, not the series")
        XCTAssertNotEqual(ref?.id, series.id,
                          "oracle sanity: the correct answer is NOT the series")

        let cap = openDetailCountingResolutions(for: series.id, store: store)
        XCTAssertTrue(cap.sawScroll && cap.sawPaging, "the page must materialize")
        XCTAssertGreaterThan(cap.fallback, 0,
                             "the series must resolve through the resolver's day-key scan (gh#127)")
        XCTAssertEqual(cap.fast, 0,
                       "short-circuiting the series is the #1 regression — here it would also "
                       + "return the WRONG event: \(cap.fast) fast-path hit(s)")
        // Make the value divergence explicit: the fast-path hit (the series)
        // is a DIFFERENT event from the correct resolution (the replacement),
        // so taking the fast path here is a value regression, not just a
        // wasted scan. `cap.fast == 0` above is therefore a value guard.
        let wouldBeFastHit = store.findCalendarEvent(id: series.id)
        XCTAssertEqual(wouldBeFastHit?.id, series.id,
                       "the index maps the series id to the series")
        XCTAssertNotEqual(wouldBeFastHit?.id, ref?.id,
                          "the fast-path hit (series) differs from the correct resolved event "
                          + "(replacement): only the fallback is correct")
    }
}
