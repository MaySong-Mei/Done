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
}
