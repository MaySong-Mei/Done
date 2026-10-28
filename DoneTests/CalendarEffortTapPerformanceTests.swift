//
//  CalendarEffortTapPerformanceTests.swift
//  DoneTests
//
//  gh#201 — the three fixes on the effort-tap path, each pinned by a fixture
//  that dies if the fix is reverted.
//
//  Fix 1 (touch delivery): the enclosing scroll views held a stationary
//  touch until a delay expired and then delivered down+up together at lift.
//  Pinned by CalendarScrollTouchDelayTests (the walk and the property
//  write, against a synthetic hierarchy) +
//  CalendarScrollTouchDelayMountPointTests (the mount point, against the
//  real one — the half the synthetic tests structurally cannot see).
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
import Combine
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

    // MARK: The trail line (gh#201 follow-up: does the walk still reach the pager?)

    /// Named stand-ins, so the line's class names and their order are
    /// checkable — every real ancestor here would otherwise read
    /// "UIScrollView".
    private final class InnerScroll: UIScrollView {}
    private final class PagerScroll: UIScrollView {}
    private final class OuterScroll: UIScrollView {}

    /// `DiagnosticTrail` is process-global and file-backed, so each test
    /// clears it around itself and reads back only its own category.
    private func withCleanTrail(_ body: () throws -> Void) rethrows {
        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        try body()
    }

    /// The probe only trails from inside a window; the hierarchy needs one
    /// above it, not a visible one.
    private func makeWindow() -> UIWindow {
        UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
    }

    private func touchDelayLines() -> [String] {
        DiagnosticTrail.combinedText()
            .split(separator: "\n")
            .filter { $0.contains(" \(CalendarScrollTouchDelayProbe.trailCategory) ") }
            .map(String.init)
    }

    /// The shape the fix was built for: the probe's first pass in a window
    /// finds both scroll views still delaying, its next pass finds the
    /// write held — two lines — and further passes over the same hierarchy
    /// write nothing. A hierarchy change writes again.
    func testTheProbeTrailsWhatItFoundOnceAndAgainOnlyWhenThatChanges() {
        withCleanTrail {
            let window = makeWindow()
            let pager = PagerScroll()
            pager.isPagingEnabled = true
            let inner = InnerScroll()
            window.addSubview(pager)
            pager.addSubview(inner)

            let probe = CalendarScrollTouchDelayProbe.ProbeView()
            inner.addSubview(probe)
            for _ in 0..<5 { probe.refreshTouchDelayIfNeeded() }

            let lines = touchDelayLines()
            XCTAssertEqual(lines.count, 2, "\(lines)")
            XCTAssertTrue(lines.first?.hasSuffix(
                "found=2 paging=yes delayingBefore=2 views=InnerScroll|PagerScroll") ?? false, "\(lines)")
            XCTAssertTrue(lines.last?.hasSuffix(
                "found=2 paging=yes delayingBefore=0 views=InnerScroll|PagerScroll") ?? false,
                "the second pass sees the write held: \(lines)")
            XCTAssertFalse(pager.delaysContentTouches, "the write itself is unchanged")
            XCTAssertFalse(inner.delaysContentTouches)

            // Something turns the pager's delay back on: that is a change.
            pager.delaysContentTouches = true
            probe.refreshTouchDelayIfNeeded()
            probe.refreshTouchDelayIfNeeded()
            let after = touchDelayLines()
            XCTAssertEqual(after.count, 4, "\(after)")
            let third = after.count > 2 ? after[2] : ""
            XCTAssertTrue(third.hasSuffix("delayingBefore=1 views=InnerScroll|PagerScroll"), "\(after)")
            XCTAssertFalse(pager.delaysContentTouches)
        }
    }

    /// No paging ancestor: the walk returns only the nearest scroll view,
    /// so the line names what is ABOVE it too — the classes a follow-up
    /// fix would have to reach.
    func testWithoutAPagerTheLineNamesTheScrollViewsAboveTheNearest() {
        withCleanTrail {
            let window = makeWindow()
            let outer = OuterScroll()
            let middle = PagerScroll()   // a pager in name only: paging off
            let inner = InnerScroll()
            window.addSubview(outer)
            outer.addSubview(middle)
            middle.addSubview(inner)

            let probe = CalendarScrollTouchDelayProbe.ProbeView()
            inner.addSubview(probe)

            let line = touchDelayLines().first ?? ""
            XCTAssertTrue(line.hasSuffix(
                "found=1 paging=no delayingBefore=1 views=InnerScroll above=PagerScroll|OuterScroll"),
                line)
            XCTAssertTrue(middle.delaysContentTouches, "the walk's blast radius is unchanged: nothing above the nearest is written")
        }
    }

    /// One "detail open": a fresh pager over a fresh inner scroll view
    /// (`makeInner`, else an `InnerScroll`), in a window, with a fresh probe
    /// mounted inside.
    private func open(inner makeInner: (() -> UIScrollView)? = nil)
        -> (window: UIWindow, pager: UIScrollView, probe: CalendarScrollTouchDelayProbe.ProbeView) {
        let window = makeWindow()
        let pager = PagerScroll()
        pager.isPagingEnabled = true
        let inner = makeInner?() ?? InnerScroll()
        window.addSubview(pager)
        pager.addSubview(inner)
        let probe = CalendarScrollTouchDelayProbe.ProbeView()
        inner.addSubview(probe)
        probe.refreshTouchDelayIfNeeded()
        return (window, pager, probe)
    }

    /// Something keeps turning the pager's delay back on: every pass is a
    /// change, and before the cap every change was a synchronous trail
    /// write. The probe writes `linesPerProbe` lines, then one saying it
    /// stopped, then nothing — and keeps turning the delay off throughout.
    func testAProbeWhoseDelayKeepsComingBackStopsAtTheCap() {
        withCleanTrail {
            let (window, pager, probe) = open()
            for _ in 0..<20 {
                pager.delaysContentTouches = true
                probe.refreshTouchDelayIfNeeded()
                probe.refreshTouchDelayIfNeeded()
                XCTAssertFalse(pager.delaysContentTouches, "the write still runs on every pass")
            }
            let lines = touchDelayLines()
            XCTAssertEqual(lines.count, CalendarScrollTouchDelayTrail.linesPerProbe + 1, "\(lines)")
            XCTAssertTrue(lines.last?.hasSuffix(" \(CalendarScrollTouchDelayTrail.capContent)") ?? false, "\(lines)")
            XCTAssertTrue(lines.dropLast().allSatisfy { $0.contains(" found=2 paging=yes ") }, "\(lines)")
            XCTAssertTrue(lines.contains { $0.contains(" pass=3 found=2 paging=yes delayingBefore=1 ") },
                          "the delay coming back is on the record before the cap: \(lines)")
            _ = window
        }
    }

    /// The first open after launch writes its two lines; a second open of
    /// the same hierarchy, with a new probe, writes none — though that
    /// probe still turns the delays off.
    func testASecondIdenticalOpenWritesNothing() {
        withCleanTrail {
            let first = open()
            XCTAssertEqual(touchDelayLines().count, 2, "\(touchDelayLines())")

            let second = open()
            XCTAssertEqual(touchDelayLines().count, 2, "\(touchDelayLines())")
            XCTAssertFalse(second.pager.delaysContentTouches)
            _ = (first, second)
        }
    }

    /// Later opens that go differently still write, from where they differ:
    /// a different inner class writes from its first change; the same shape
    /// with the delay coming back on writes from its third change, with the
    /// pass number saying so.
    func testALaterOpenThatDiffersStillWrites() {
        withCleanTrail {
            let first = open()
            let same = open()
            XCTAssertEqual(touchDelayLines().count, 2, "rig: the repeat is silent")

            let other = open(inner: { OuterScroll() })
            let afterOther = touchDelayLines()
            XCTAssertEqual(afterOther.count, 4, "\(afterOther)")
            let third = afterOther.count > 2 ? afterOther[2] : ""
            XCTAssertTrue(third.hasSuffix("pass=1 found=2 paging=yes delayingBefore=2 views=OuterScroll|PagerScroll"),
                          "\(afterOther)")

            let back = open()
            XCTAssertEqual(touchDelayLines().count, 6,
                           "back to the first shape differs from the open just before it: \(touchDelayLines())")

            let comesBack = open()
            XCTAssertEqual(touchDelayLines().count, 6, "rig: silent while it repeats the open before")
            comesBack.pager.delaysContentTouches = true
            comesBack.probe.refreshTouchDelayIfNeeded()
            let last = touchDelayLines().last ?? ""
            XCTAssertTrue(last.hasSuffix("pass=3 found=2 paging=yes delayingBefore=1 views=InnerScroll|PagerScroll"), last)
            _ = (first, same, other, back)
        }
    }

    /// Once a probe has differed from the open before it, it writes the
    /// rest of its changes too, even one that happens to match: here the
    /// inner scroll view's delay is already off, so the first pass reads
    /// delayingBefore=1 (new), and the second pass's delayingBefore=0 is
    /// the same content the previous open wrote — written anyway, because
    /// it is how this open's story ends.
    func testOnceAProbeDiffersItWritesTheRestOfItsChanges() {
        withCleanTrail {
            let first = open()
            XCTAssertEqual(touchDelayLines().count, 2)
            let differs = open(inner: {
                let inner = InnerScroll()
                inner.delaysContentTouches = false
                return inner
            })
            let lines = touchDelayLines()
            XCTAssertEqual(lines.count, 4, "\(lines)")
            XCTAssertTrue(lines.last?.hasSuffix("pass=2 found=2 paging=yes delayingBefore=0 views=InnerScroll|PagerScroll") ?? false,
                          "\(lines)")
            _ = (first, differs)
        }
    }

    /// What the probes remember stands for lines in the trail: once the
    /// trail is cleared, an open identical to the last one writes again.
    func testClearingTheTrailForgetsWhatWasWritten() {
        withCleanTrail {
            let first = open()
            XCTAssertEqual(touchDelayLines().count, 2)
            DiagnosticTrail.clear()
            let again = open()
            XCTAssertEqual(touchDelayLines().count, 2, "\(touchDelayLines())")
            _ = (first, again)
        }
    }

    /// Outside a window the probe writes no line: SwiftUI's first
    /// `updateUIView` runs before the probe has ancestors, and its
    /// "found=0" would read like the failure the line is for. Positive
    /// control: the same probe, once in a window, writes one.
    func testTheProbeWritesNoLineOutsideAWindow() {
        withCleanTrail {
            let pager = PagerScroll()
            pager.isPagingEnabled = true
            let probe = CalendarScrollTouchDelayProbe.ProbeView()
            probe.refreshTouchDelayIfNeeded()
            pager.addSubview(probe)
            probe.refreshTouchDelayIfNeeded()
            XCTAssertEqual(touchDelayLines(), [])
            XCTAssertFalse(pager.delaysContentTouches, "the write does not wait for a window")

            let window = makeWindow()
            window.addSubview(pager)
            XCTAssertEqual(touchDelayLines().count, 1, "positive control: in a window, the probe trails")
        }
    }
}

// MARK: - Fix 1 — the mount point, in the real hierarchy

/// Everything in `CalendarScrollTouchDelayTests` drives the walk against a
/// SYNTHETIC tree, which leaves the one thing the fix actually depends on
/// unpinned: where the probe is mounted.
///
/// `.background` inserts its content BEHIND the view it modifies. Mounted on
/// `effortQuickSection` the probe is a descendant of the reflection page's
/// `ScrollView` and of the pager, so the superview walk reaches both.
/// Mounted one level up on `reflectionPage` it becomes a SIBLING of that
/// page's `ScrollView` — the walk then finds only the pager, the inner
/// scroll view keeps its delay, and half the fix is silently gone with every
/// synthetic test still green. (That is not hypothetical: it is exactly why
/// `CalendarPageTabGesturePriorityProbe`, mounted that way on each page,
/// only ever reaches the pager.)
@MainActor
final class CalendarScrollTouchDelayMountPointTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        suiteName = "CalendarScrollTouchDelayMountPointTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        TestStorage.tearDown(suiteName)
        defaults = nil
        suiteName = nil
        location = nil
        super.tearDown()
    }

    /// Mounts the real `CalendarEventDetailView` in a window and asserts the
    /// probe's walk, from where it actually lands, reaches the page's own
    /// vertical scroll view AND the pager — not the pager alone.
    ///
    /// Deliberately asserts the SHAPE (nearest is non-paging, outermost is
    /// paging) rather than a UIKit class name: on iOS 26 the `TabView(.page)`
    /// pager is a `PagingCollectionView` — a `UICollectionView`, hence a
    /// `UIScrollView` — and the walk works because `isPagingEnabled` is true
    /// on it, not because of what it is called.
    func testProbeInTheRealDetailHierarchyReachesThePagesScrollViewAndThePager() throws {
        DiagnosticTrail.clear()
        defer { DiagnosticTrail.clear() }
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        let start = Calendar.current.date(
            bySettingHour: 9, minute: 0, second: 0, of: Calendar.current.startOfDay(for: Date())
        )!
        let event = Event(
            title: "Deep Work",
            timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
            type: "Study"
        )
        store.addCalendarEvent(event)

        let route = CalendarEventDetailRoute(
            occurrence: CalendarEventOccurrenceContext(
                eventID: event.id,
                occurrenceDate: start,
                occurrenceID: nil,
                isAllDay: false,
                source: .timelineTap
            ),
            // `.selfEval` routes the initial page to `.reflection`, which is
            // where `effortQuickSection` — and therefore the probe — lives.
            initialJumpTarget: .selfEval
        )

        let controller = UIHostingController(
            rootView: CalendarEventDetailView(route: route).environmentObject(store)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        self.window = window
        window.rootViewController = controller
        window.isHidden = false
        window.layoutIfNeeded()

        var probe: CalendarScrollTouchDelayProbe.ProbeView?
        let deadline = Date().addingTimeInterval(20)
        while probe == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            probe = Self.firstProbe(in: window)
        }

        let mounted = try XCTUnwrap(
            probe,
            "the probe never appeared in the real hierarchy — if `effortQuickSection` moved off the reflection page, re-point this test rather than deleting it"
        )

        let reached = calendarScrollViewsDelayingContentTouches(above: mounted)
        XCTAssertGreaterThanOrEqual(
            reached.count, 2,
            "the probe must reach the page's own scroll view as well as the pager; reaching one means it is mounted as a SIBLING of that ScrollView (i.e. one level too high)"
        )
        let nearest = try XCTUnwrap(reached.first)
        let outermost = try XCTUnwrap(reached.last)
        XCTAssertFalse(
            nearest.isPagingEnabled,
            "the NEAREST enclosing scroll view must be the reflection page's vertical one — if the nearest is already the pager, the inner scroll view is outside the probe's reach"
        )
        XCTAssertTrue(outermost.isPagingEnabled, "the walk stops at the pager, and the pager is the outer bound")
        for scrollView in reached {
            XCTAssertFalse(
                scrollView.delaysContentTouches,
                "every scroll view the walk reaches must have had its delay turned off"
            )
        }

        // The probe's trail line, from the REAL mount: written at all (the
        // probe does get a window there), and it reports the pager. On a
        // device whose OS reshaped this hierarchy, this is the line that
        // would say paging=no.
        let lines = DiagnosticTrail.combinedText()
            .split(separator: "\n")
            .filter { $0.contains(" \(CalendarScrollTouchDelayProbe.trailCategory) ") }
        print("touch-delay trail in the real hierarchy:\n" + lines.joined(separator: "\n"))
        let first = try XCTUnwrap(lines.first, "the mounted probe never wrote its trail line")
        XCTAssertTrue(first.contains(" paging=yes "), String(first))
    }

    private static func firstProbe(in view: UIView) -> CalendarScrollTouchDelayProbe.ProbeView? {
        if let probe = view as? CalendarScrollTouchDelayProbe.ProbeView { return probe }
        for subview in view.subviews {
            if let found = firstProbe(in: subview) { return found }
        }
        return nil
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

    /// The CALL SITE, which nothing above reaches.
    /// `testEveryModelFieldMovesTheApplyKey` proves the ApplyKey TYPE is
    /// sensitive to all 31 `Model` fields;
    /// `testOccurrencesAreBuiltOnlyWhenTheKeyChanges` proves an OCCURRENCE
    /// change re-enters the build. Neither crosses the two, so both stay
    /// green against a guard narrowed to
    /// `currentApplyKey?.occurrenceKey != key.occurrenceKey` — and that
    /// mutant freezes the column against every non-occurrence input for as
    /// long as the occurrence list is static: `hourHeight` (the calendar
    /// stops moving for a whole pinch), `focusedEventID` /
    /// `isFocusContextActive` (siblings never dim), `creationPreviewRange` /
    /// `dragPreviewDayStep` (the drag-create ghost stops following the
    /// finger), `contentWidth` (rotation).
    ///
    /// Nothing downstream catches that: an under-firing key returns AT the
    /// guard, so `applyResolved`'s exact `currentModel != model` comparison
    /// is never reached. Hence both halves are asserted here — the build ran
    /// again, AND the new scalar reached the applied model.
    func testANonOccurrenceFieldAloneRebuildsAndLands() {
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        let occurrences = [occurrence(id: "a", startHour: 9)]
        let occurrenceKey = sourceKey(occurrences)
        var buildCount = 0

        host.apply(
            key: DayLayerHostView.ApplyKey(
                modelWithoutOccurrences: baseModel(), occurrenceKey: occurrenceKey
            ),
            makeOccurrences: { buildCount += 1; return occurrences }
        )
        XCTAssertEqual(buildCount, 1)
        XCTAssertEqual(host.liveModel?.hourHeight, 56, "positive control: the base fixture's own scale landed")

        // One pinch frame: same occurrence list, one scalar moved.
        var pinched = baseModel()
        pinched.hourHeight = 88
        host.apply(
            key: DayLayerHostView.ApplyKey(
                modelWithoutOccurrences: pinched, occurrenceKey: occurrenceKey
            ),
            makeOccurrences: { buildCount += 1; return occurrences }
        )

        XCTAssertEqual(
            buildCount, 2,
            "a Model-only change must re-enter the build even though the occurrence half is identical"
        )
        XCTAssertEqual(host.liveModel?.hourHeight, 88, "and the moved scalar must reach the applied model")
        XCTAssertEqual(host.liveModel?.occurrences, occurrences)
    }

    /// Callbacks are re-supplied on EVERY keyed pass, including one the key
    /// guard turns away.
    ///
    /// They are assigned before the guard on purpose: each `body` pass
    /// builds fresh closures capturing that pass's values, so a pass whose
    /// key is unchanged must still hand them over — otherwise the host keeps
    /// the PREVIOUS pass's closures and a tap fires a handler capturing a
    /// stale event or route. Moving the assignment below the guard keeps the
    /// whole suite green without this fixture, and it is exactly the line a
    /// later "this looks redundant, `applyResolved` already does it"
    /// cleanup deletes.
    func testAnUnchangedKeyStillReSuppliesTheCallbacks() {
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        let occurrences = [occurrence(id: "a", startHour: 9)]
        let key = DayLayerHostView.ApplyKey(
            modelWithoutOccurrences: baseModel(), occurrenceKey: sourceKey(occurrences)
        )
        var fired: [String] = []

        var firstPass = DayLayerHostView.Callbacks()
        firstPass.onNonEventTap = { fired.append("pass-1") }
        host.apply(key: key, callbacks: firstPass, makeOccurrences: { occurrences })
        host.gestureController.callbacks.onNonEventTap?()
        XCTAssertEqual(fired, ["pass-1"], "positive control: the first pass's closure is installed")

        // Same key — this pass takes the early-out — but a NEW closure set.
        var secondPass = DayLayerHostView.Callbacks()
        secondPass.onNonEventTap = { fired.append("pass-2") }
        host.apply(key: key, callbacks: secondPass, makeOccurrences: { occurrences })
        host.gestureController.callbacks.onNonEventTap?()

        XCTAssertEqual(
            fired, ["pass-1", "pass-2"],
            "a pass the key guard turns away must still leave the host holding THAT pass's closures"
        )
    }

    /// The key is stamped BEFORE `applyResolved`, so a keyed apply that
    /// re-enters from inside the layout pass gets the last word.
    ///
    /// `applyResolved` ends in `setNeedsLayout(); layoutIfNeeded()`, and
    /// `layoutSubviews` calls back out through `reportVisibleFrameIfNeeded()`
    /// → `callbacks.onVisibleTimelineFrameChange`. That is the re-entry seam,
    /// and this fixture drives it directly: the callback applies a NEWER key
    /// from inside the outer call's own layout pass. Stamping after
    /// `applyResolved` instead lets the outer frame overwrite that newer key
    /// on the way out, leaving the host claiming a state it is no longer in —
    /// the next pass carrying the newer key is then admitted as a no-op and
    /// the column stays stale.
    ///
    /// Honest about reachability: in production that callback hop goes
    /// through SwiftUI `@State`, so the re-apply lands on a later turn rather
    /// than synchronously inside this one, and `DayLayerCoordinator` drives
    /// its own host instance. This pins the ORDERING at the unit level; it is
    /// not a reproduction of a live symptom.
    func testTheApplyKeyIsStampedBeforeTheLayoutPassCanReEnter() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 800))
        window.isHidden = false
        defer { window.isHidden = true }
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        window.addSubview(host)

        let occurrences = [occurrence(id: "a", startHour: 9)]
        let occurrenceKey = sourceKey(occurrences)
        let outerKey = DayLayerHostView.ApplyKey(
            modelWithoutOccurrences: baseModel(), occurrenceKey: occurrenceKey
        )
        var newerModel = baseModel()
        newerModel.hourHeight = 88
        let newerKey = DayLayerHostView.ApplyKey(
            modelWithoutOccurrences: newerModel, occurrenceKey: occurrenceKey
        )

        var buildCount = 0
        var reEntries = 0
        var callbacks = DayLayerHostView.Callbacks()
        callbacks.onVisibleTimelineFrameChange = { [weak host] _ in
            guard reEntries == 0, let host else { return }
            reEntries += 1
            host.apply(key: newerKey, makeOccurrences: { buildCount += 1; return occurrences })
        }

        host.apply(key: outerKey, callbacks: callbacks, makeOccurrences: { buildCount += 1; return occurrences })

        XCTAssertEqual(reEntries, 1, "positive control: the outer call's layout pass really did re-enter apply")
        XCTAssertEqual(buildCount, 2, "positive control: outer built once, the nested call built once")
        XCTAssertEqual(host.liveModel?.hourHeight, 88, "the nested call is the newer state and must survive the unwind")

        // The stamp itself: the host must now claim the NESTED key. If the
        // outer frame stamped on its way out, this pass rebuilds.
        host.apply(key: newerKey, makeOccurrences: { buildCount += 1; return occurrences })
        XCTAssertEqual(
            buildCount, 2,
            "the key the host claims must be the nested call's, not the outer call's — otherwise the newer state is re-applied from a key that no longer describes it"
        )
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
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
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
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
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
    ///
    /// The republish count is a second, independent assertion, and it is
    /// here because a first version of this test could NOT see the flush's
    /// own epsilon re-check: dropping that guard writes the identical value
    /// back, `DurableEventStorage` skips a byte-identical commit, and
    /// `onSlotCommitted` never fires -- so the commit assertion alone stayed
    /// green through a mutant that reintroduced a store-wide `@Published`
    /// republish on every no-op flush. That republish is the cost this fix
    /// is about (it is what re-runs every mounted day column), so it gets
    /// its own assertion instead of being inferred from the commit trail.
    func testChangingBackToTheStoredValueSupersedesTheQueuedOne() throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        store.upsertLogRecord(for: ctx) { $0.effort = 3 }
        store.flushCalendarEventColorDepthMirror()
        XCTAssertEqual(try colorDepth(of: event.id, in: store), 0.6, accuracy: 0.0001)

        var commits: [String] = []
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.upsertLogRecord(for: ctx) { $0.effort = 5 }   // queues 1.0
        store.upsertLogRecord(for: ctx) { $0.effort = 3 }   // back to what is stored

        var republishes = 0
        let subscription = store.objectWillChange.sink { _ in republishes += 1 }
        defer { subscription.cancel() }
        store.flushCalendarEventColorDepthMirror()

        XCTAssertEqual(try colorDepth(of: event.id, in: store), 0.6, accuracy: 0.0001)
        XCTAssertFalse(
            commits.contains(StorageSlot.calendarEvents.rawValue),
            "nothing actually moved, so nothing may be committed — the same thing the old synchronous epsilon guard did"
        )
        XCTAssertEqual(
            republishes, 0,
            "a queued value the event already holds must not write rawCalendarEvents at all — an @Published write republishes the whole store to every calendar consumer"
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
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
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
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.upsertLogRecord(for: ctx) { $0.effort = 5 }
        XCTAssertFalse(commits.contains(StorageSlot.calendarEvents.rawValue), "positive control: still pending")

        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)

        XCTAssertTrue(commits.contains(StorageSlot.calendarEvents.rawValue))
        XCTAssertEqual(try colorDepth(of: event.id, in: store), 1.0, accuracy: 0.0001)
    }

    /// The ARMING of the debounce, which no other fixture in this class
    /// reaches: every one of them gets to the flush either by calling
    /// `flushCalendarEventColorDepthMirror()` directly or by posting
    /// `willResignActive`, and `EventStore.colorDepthMirrorCoalesceWindow`
    /// is otherwise referenced only by production code
    /// (`git grep -n colorDepthMirrorCoalesceWindow`). Delete the
    /// `Task { … Task.sleep … flush }` block while keeping the pending map
    /// and the cancel and all of them stay green — while `colorDepth` never
    /// lands until the app resigns active, so the canvas keeps stale
    /// effort-bar widths (and, through `colorOpacityMultiplier`, stale
    /// tints) for the entire session.
    ///
    /// Nothing here calls the flush. That is the whole point.
    func testThePendingMirrorLandsOnItsOwnAfterTheCoalesceWindow() async throws {
        let store = makeStore()
        let event = seed(store)
        let ctx = occurrence(event.id, on: event.timeRanges[0].start)

        var commits: [String] = []
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.upsertLogRecord(for: ctx) { $0.effort = 5 }
        XCTAssertFalse(
            commits.contains(StorageSlot.calendarEvents.rawValue),
            "positive control: inside the window nothing has committed yet"
        )

        // Read off the constant rather than hard-coded, so widening the
        // window cannot silently turn this into a race.
        try await Task.sleep(for: EventStore.colorDepthMirrorCoalesceWindow * 4)

        XCTAssertTrue(
            commits.contains(StorageSlot.calendarEvents.rawValue),
            "the debounce has to land this on its own — no flush was called"
        )
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
        store.onSlotCommitted = { slot, _ in commits.append(slot.rawValue) }
        store.flushCalendarEventColorDepthMirror()

        XCTAssertFalse(commits.contains(StorageSlot.calendarEvents.rawValue))
        XCTAssertNil(store.rawCalendarEvents.first { $0.id == event.id })
    }
}

// MARK: - Independent QA: the TouchDelay trail line (feat/fixwatch-segment)

/// Independent QA on the probe's trail line. The walk and the write are
/// checked against a reference copy of the PRE-change loop over generated
/// hierarchies; the line's de-duplication is checked on the shapes the
/// implementer's tests do not build (a pass outside the window that would
/// otherwise mask the first in-window line, a class change with equal
/// counts, two probes, no scroll view at all, nested pagers).
@MainActor
final class CalendarScrollTouchDelayTrailQATests: XCTestCase {
    private final class InnerA: UIScrollView {}
    private final class InnerB: UIScrollView {}
    private final class Pager: UIScrollView {}
    private final class OuterPager: UIScrollView {}

    override func setUp() {
        super.setUp()
        DiagnosticTrail.clear()
    }

    override func tearDown() {
        DiagnosticTrail.clear()
        super.tearDown()
    }

    private func window() -> UIWindow { UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852)) }

    private func lines() -> [String] {
        DiagnosticTrail.combinedText().split(separator: "\n")
            .filter { $0.contains(" \(CalendarScrollTouchDelayProbe.trailCategory) ") }.map(String.init)
    }

    /// "gh201 probe#<n> …" → n
    private func serial(_ line: String) -> Int? {
        guard let range = line.range(of: "probe#") else { return nil }
        return Int(line[range.upperBound...].prefix { $0.isNumber })
    }

    /// The pre-change loop, verbatim in effect: every scroll view from the
    /// probe up to and including the first paging one; with no pager, the
    /// nearest only; write `false` where it was `true`.
    private func referenceWrittenSet(above view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        var current = view.superview
        while let candidate = current {
            if let scroll = candidate as? UIScrollView {
                found.append(scroll)
                if scroll.isPagingEnabled { return found }
            }
            current = candidate.superview
        }
        return Array(found.prefix(1))
    }

    /// 300 generated chains (plain views and scroll views, random paging and
    /// random initial delay, in a window or not): after one refresh every
    /// scroll view's delay is exactly what the pre-change loop leaves —
    /// off on the reference set, untouched everywhere else. Positive
    /// controls: the generator does produce pager / no-pager / nested-pager
    /// / outside-window shapes, and does leave delays ON above the bound.
    func testTheWalkAndWriteMatchThePreChangeLoopOnGeneratedHierarchies() {
        var seed: UInt64 = 0x5EED_F1C5
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var sawPager = 0, sawNoPager = 0, sawNested = 0, sawOutside = 0, sawUntouchedAbove = 0
        for _ in 0..<300 {
            let depth = 1 + next(6)
            var chain: [UIView] = []
            for _ in 0..<depth {
                if next(3) == 0 {
                    chain.append(UIView())
                } else {
                    let scroll = [UIScrollView(), InnerA(), Pager(), OuterPager()][next(4)]
                    scroll.isPagingEnabled = next(3) == 0
                    scroll.delaysContentTouches = next(4) != 0
                    chain.append(scroll)
                }
            }
            if chain.count > 1 {
                for index in 1..<chain.count { chain[index - 1].addSubview(chain[index]) }
            }
            let inWindow = next(2) == 0
            let host = window()
            if inWindow { host.addSubview(chain[0]) } else { sawOutside += 1 }

            let scrolls = chain.compactMap { $0 as? UIScrollView }
            let before = scrolls.map(\.delaysContentTouches)
            let probe = CalendarScrollTouchDelayProbe.ProbeView()
            let stand = UIView()
            chain.last!.addSubview(stand)
            let expected = referenceWrittenSet(above: stand)
            stand.removeFromSuperview()
            chain.last!.addSubview(probe)   // didMoveToSuperview (+ didMoveToWindow) run the refresh
            probe.refreshTouchDelayIfNeeded()

            let pagers = scrolls.filter(\.isPagingEnabled).count
            if expected.contains(where: \.isPagingEnabled) { sawPager += 1 } else { sawNoPager += 1 }
            if pagers > 1 { sawNested += 1 }
            for (scroll, was) in zip(scrolls, before) {
                let inSet = expected.contains { $0 === scroll }
                XCTAssertEqual(scroll.delaysContentTouches, inSet ? false : was,
                               "chain depth \(depth), in window \(inWindow), scroll in reference set \(inSet)")
                if !inSet && was { sawUntouchedAbove += 1 }
            }
        }
        XCTAssertGreaterThan(sawPager, 20)
        XCTAssertGreaterThan(sawNoPager, 20)
        XCTAssertGreaterThan(sawNested, 5)
        XCTAssertGreaterThan(sawOutside, 20)
        XCTAssertGreaterThan(sawUntouchedAbove, 20, "the generator must leave delays on outside the bound, or nothing is checked")
    }

    /// A pass outside the window must not count as trailed. Here the
    /// pager's delay is already off, so the out-of-window pass and the
    /// in-window pass see the same snapshot — if the out-of-window pass
    /// were remembered, the in-window line would never be written.
    func testAPassOutsideTheWindowIsNotRememberedAsTrailed() {
        let pager = Pager()
        pager.isPagingEnabled = true
        pager.delaysContentTouches = false
        let probe = CalendarScrollTouchDelayProbe.ProbeView()
        pager.addSubview(probe)
        probe.refreshTouchDelayIfNeeded()
        XCTAssertEqual(lines(), [], "outside a window: no line")

        let host = window()
        host.addSubview(pager)
        let written = lines()
        XCTAssertEqual(written.count, 1, "\(written)")
        XCTAssertTrue(written.first?.hasSuffix("found=1 paging=yes delayingBefore=0 views=Pager") ?? false, "\(written)")
    }

    /// Equal counts, different classes: the probe moves from one inner
    /// scroll view to another of a different class under the same pager,
    /// every delay already off. Only the class list changed — that is a
    /// change, and the line names the new class.
    func testAClassChangeWithEqualCountsWritesAgain() {
        let host = window()
        let pager = Pager()
        pager.isPagingEnabled = true
        let a = InnerA(), b = InnerB()
        b.delaysContentTouches = false
        host.addSubview(pager)
        pager.addSubview(a)
        pager.addSubview(b)
        let probe = CalendarScrollTouchDelayProbe.ProbeView()
        a.addSubview(probe)
        probe.refreshTouchDelayIfNeeded()
        XCTAssertEqual(lines().count, 2, "first pass delayingBefore=2, second 0: \(lines())")

        b.addSubview(probe)   // moves it; didMoveToSuperview refreshes
        probe.refreshTouchDelayIfNeeded()
        let after = lines()
        XCTAssertEqual(after.count, 3, "\(after)")
        XCTAssertTrue(after.last?.hasSuffix("found=2 paging=yes delayingBefore=0 views=InnerB|Pager") ?? false, "\(after)")

        // Positive control for "only on change": back and forth over the same
        // shape twice more writes exactly one line per move, none per pass.
        a.addSubview(probe); probe.refreshTouchDelayIfNeeded(); probe.refreshTouchDelayIfNeeded()
        XCTAssertEqual(lines().count, 4)
    }

    /// Two probes keep their own numbers: every line of one probe carries
    /// one number, and the two numbers differ. (Implementer, fix round 1:
    /// the second pager is an `OuterPager` — two probes over the SAME shape
    /// are now a repeated open and the second writes nothing, see
    /// `testASecondIdenticalOpenWritesNothing`.)
    func testTwoProbesNumberTheirLinesApart() throws {
        let host = window()
        let pagerA = Pager(), pagerB = OuterPager()
        pagerA.isPagingEnabled = true
        pagerB.isPagingEnabled = true
        host.addSubview(pagerA)
        host.addSubview(pagerB)
        let first = CalendarScrollTouchDelayProbe.ProbeView()
        let second = CalendarScrollTouchDelayProbe.ProbeView()
        pagerA.addSubview(first)
        first.refreshTouchDelayIfNeeded()
        pagerB.addSubview(second)
        second.refreshTouchDelayIfNeeded()
        first.refreshTouchDelayIfNeeded()

        let all = lines()
        XCTAssertEqual(all.count, 4, "two lines per probe (delayingBefore 1, then 0): \(all)")
        let serials = all.compactMap(serial)
        // Guarded: an index past the end traps the whole test process (and
        // every test after it) instead of failing this one.
        guard serials.count == 4 else {
            return XCTFail("expected 4 numbered lines, got \(serials.count): \(all)")
        }
        XCTAssertEqual(serials[0], serials[1], "one probe, one number: \(all)")
        XCTAssertEqual(serials[2], serials[3])
        XCTAssertNotEqual(serials[0], serials[2])
        XCTAssertEqual(serials[2], serials[0] + 1, "numbered in construction order")
    }

    /// No scroll view at all above the probe, in a window: the line still
    /// says so, with both lists empty.
    func testNoScrollViewAtAllStillWritesAnHonestLine() {
        let host = window()
        let plain = UIView()
        host.addSubview(plain)
        let probe = CalendarScrollTouchDelayProbe.ProbeView()
        plain.addSubview(probe)
        let all = lines()
        XCTAssertEqual(all.count, 1, "\(all)")
        XCTAssertTrue(all.first?.hasSuffix("found=0 paging=no delayingBefore=0 views=- above=-") ?? false, "\(all)")
    }

    /// Nested pagers: the walk stops at the nearer one; the line carries no
    /// `above=` (a pager was reached) and the outer pager keeps its delay.
    func testNestedPagersStopAtTheNearerAndWriteNoAbove() {
        let host = window()
        let outer = OuterPager(), pager = Pager(), inner = InnerA()
        outer.isPagingEnabled = true
        pager.isPagingEnabled = true
        host.addSubview(outer)
        outer.addSubview(pager)
        pager.addSubview(inner)
        let probe = CalendarScrollTouchDelayProbe.ProbeView()
        inner.addSubview(probe)
        let first = lines().first ?? ""
        XCTAssertTrue(first.hasSuffix("found=2 paging=yes delayingBefore=2 views=InnerA|Pager"), first)
        XCTAssertFalse(first.contains("above="), first)
        XCTAssertTrue(outer.delaysContentTouches, "nothing above the first pager is written")
        XCTAssertFalse(pager.delaysContentTouches)
    }

    /// The line carries only class names, counts and flags — measured here
    /// as its byte length too, for the trail-volume estimate (printed).
    func testTheLineIsShortAndCarriesNoFreeText() {
        let host = window()
        let pager = Pager(); pager.isPagingEnabled = true
        let inner = InnerA()
        host.addSubview(pager); pager.addSubview(inner)
        let probe = CalendarScrollTouchDelayProbe.ProbeView()
        inner.addSubview(probe)
        for line in lines() {
            print("QA TouchDelay line bytes=\(line.utf8.count + 1): \(line)")
            XCTAssertLessThan(line.utf8.count, 200, line)
        }
    }

    // MARK: Fix round 1 — the flood guard (QA)

    /// One detail open: a fresh window, pager (`Pager`, paging) and inner
    /// scroll view (`InnerA`), and a fresh probe mounted inside.
    private func openDetail() -> (host: UIWindow, pager: UIScrollView, inner: UIScrollView,
                                  probe: CalendarScrollTouchDelayProbe.ProbeView) {
        let host = window()
        let pager = Pager()
        pager.isPagingEnabled = true
        let inner = InnerA()
        host.addSubview(pager)
        pager.addSubview(inner)
        let probe = CalendarScrollTouchDelayProbe.ProbeView()
        inner.addSubview(probe)
        probe.refreshTouchDelayIfNeeded()
        return (host, pager, inner, probe)
    }

    /// Something turns both delays back on; the probe's next two passes see
    /// delayingBefore=2 (the re-enable) and then 0 (its own write held).
    private func reenableBoth(_ open: (host: UIWindow, pager: UIScrollView, inner: UIScrollView,
                                       probe: CalendarScrollTouchDelayProbe.ProbeView)) {
        open.pager.delaysContentTouches = true
        open.inner.delaysContentTouches = true
        open.probe.refreshTouchDelayIfNeeded()
        open.probe.refreshTouchDelayIfNeeded()
        XCTAssertFalse(open.pager.delaysContentTouches, "the write itself never waits on the trail")
        XCTAssertFalse(open.inner.delaysContentTouches)
    }

    /// The signal this line hunts — the delay coming back on — must be
    /// written on a later open too, even when its line is word-for-word one
    /// the trail already holds (pass 3 re-enables to delayingBefore=2, the
    /// SAME content as every open's first pass). Sequence: a sick open
    /// (written), a healthy open (a prefix of the sick one: silent), a sick
    /// open again — compared with the healthy open just before it, it
    /// differs at pass 3 and must write from there.
    func testTheDelayComingBackIsWrittenAgainAfterAHealthyOpenEvenWithARepeatedLine() {
        let sick = openDetail()
        reenableBoth(sick)
        let afterSick = lines()
        XCTAssertEqual(afterSick.count, 4, "first open after a clear writes all four changes: \(afterSick)")
        XCTAssertTrue(afterSick.contains { $0.hasSuffix("pass=3 found=2 paging=yes delayingBefore=2 views=InnerA|Pager") },
                      "\(afterSick)")

        let healthy = openDetail()
        XCTAssertEqual(lines().count, 4, "a healthy open repeats the sick one's first two changes: silent")

        let sickAgain = openDetail()
        XCTAssertEqual(lines().count, 4, "rig: silent while it repeats the healthy open")
        reenableBoth(sickAgain)
        let after = lines()
        XCTAssertEqual(after.count, 6, "the re-enable on a later open is on the record: \(after)")
        XCTAssertTrue(after.dropFirst(4).first?.hasSuffix("pass=3 found=2 paging=yes delayingBefore=2 views=InnerA|Pager") ?? false,
                      "\(after)")
        if after.count > 4 {
            XCTAssertNotEqual(serial(after[4]), serial(after[0]), "written by the later open's own probe")
        }
        _ = (sick, healthy, sickAgain)
    }

    /// A hierarchy whose delay keeps coming back (the failure case) stays
    /// bounded per open — at most `linesPerProbe` lines plus the cap line —
    /// and the write runs on every pass. Recorded, not asserted as a
    /// design: a repeat of a flapping open is NOT silent; it writes again
    /// from the change after the previous probe's remembered prefix.
    func testAFlappingHierarchyIsBoundedPerOpen() {
        var perOpen: [Int] = []
        var opens: [Any] = []
        for _ in 0..<3 {
            let before = lines().count
            let open = openDetail()
            for _ in 0..<10 {
                open.pager.delaysContentTouches = true
                open.probe.refreshTouchDelayIfNeeded()
                open.probe.refreshTouchDelayIfNeeded()
                XCTAssertFalse(open.pager.delaysContentTouches)
            }
            perOpen.append(lines().count - before)
            opens.append(open)
        }
        print("QA flapping opens, lines per open: \(perOpen)\n" + lines().joined(separator: "\n"))
        for (index, count) in perOpen.enumerated() {
            XCTAssertLessThanOrEqual(count, CalendarScrollTouchDelayTrail.linesPerProbe + 1, "open \(index): \(perOpen)")
        }
        XCTAssertEqual(perOpen.first, CalendarScrollTouchDelayTrail.linesPerProbe + 1, "the first open is written up to the cap")
        XCTAssertTrue(lines().contains { $0.contains(" pass=3 found=2 paging=yes delayingBefore=1 ") }, "\(lines())")
        _ = opens
    }
}
