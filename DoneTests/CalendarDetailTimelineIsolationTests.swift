//  CalendarDetailTimelineIsolationTests
//
//  Pins the gh#164 / gh#163 STRUCTURAL ISOLATION of the event-detail
//  timeline. Both issues have the same proximate cause and the same fix:
//  the interactive track + composer + item list used to sit inside one
//  `TimelineView(.periodic)` (gh#164) and read a parent `@State` note-draft
//  string (gh#163), so a wall-clock tick OR a keystroke re-evaluated the
//  whole ~470-line subtree. The fix moves each into its own tiny leaf:
//  time-derived values into `TimelineView(.periodic by: 1)` leaves, the
//  note draft into an unobserved `@State` box read only by two small
//  `@ObservedObject` editor leaves.
//
//  The invariant these tests pin, via the repo's `SpikeProbe` body-pass
//  seam (the resident listener is not created under XCTest, so a test owns
//  `SpikeProbe.onSignal` outright):
//
//    * gh#164  A periodic tick bumps the clock leaf's body-pass count and
//              advances its live-progress value, while leaving the timeline
//              subtree's body-pass count FLAT. (Full page, real periodic.)
//    * RED LINE 1/4  The hoist moved the clock to a smaller leaf, it did not
//              freeze it: the leaf's value is fresh every tick.
//    * gh#163  A note-draft keystroke bumps the editor leaf's body-pass
//              count while leaving the timeline subtree's count FLAT.
//              (Mechanism test on the production box + editor types, whose
//              @State-holder-does-not-observe property IS the fix.)
//
//  The interactive-pop HITCH itself is a gesture-timing artifact that
//  XCTest cannot schedule; per the task these tests pin the STRUCTURAL
//  invariant that is its proximate cause (leaf-only invalidation). The
//  cheapest device check is named in the lane report: a left-edge back
//  swipe on a populated detail page must stay finger-attached.

import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Done

@MainActor
final class CalendarDetailTimelineIsolationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var location: EventStorageLocation!

    override func setUp() {
        super.setUp()
        suiteName = "CalendarDetailTimelineIsolationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        location = TestStorage.reset(suiteName)
        SpikeProbe.onSignal = nil
    }

    override func tearDown() {
        SpikeProbe.onSignal = nil
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

    /// An event that is IN PROGRESS right now, so `.live` mode produces a
    /// display progress strictly between 0 and 1 that advances every second.
    private func inProgressEvent(now: Date) -> Event {
        Event(
            id: UUID(),
            title: "Focus block",
            timeRanges: [.init(start: now.addingTimeInterval(-1800), end: now.addingTimeInterval(1800))],
            type: "Study"
        )
    }

    private func occurrence(_ event: Event) -> CalendarEventOccurrenceContext {
        CalendarEventOccurrenceContext(
            eventID: event.id,
            occurrenceDate: event.timeRanges[0].start,
            occurrenceID: nil,
            isAllDay: false,
            source: .timelineTap
        )
    }

    // MARK: - Host helpers (real UIWindow, real run loop)

    /// Puts a SwiftUI view on screen for real and hands back the window plus
    /// the key window it displaced. A `UIHostingController` alone never
    /// materializes deep content or drives `TimelineView(.periodic)` — it
    /// takes a window on the host app's live scene, a layout pass, and run-
    /// loop time. (Same lesson as `EventStoreLookupIndexTests`.)
    private func host<V: View>(_ view: V) -> (window: UIWindow, displaced: UIWindow?) {
        let controller = UIHostingController(rootView: view)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let displaced = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        pump(0.5)
        controller.view.layoutIfNeeded()
        return (window, displaced)
    }

    private func teardownHost(_ h: (window: UIWindow, displaced: UIWindow?)) {
        h.window.isHidden = true
        h.window.rootViewController = nil
        h.displaced?.makeKeyAndVisible()
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - gh#164 : a tick touches only the clock leaf, never the subtree

    /// The load-bearing gh#164 test. Hosts the REAL detail page over an
    /// in-progress event, then waits for the live-progress leaf's own
    /// `TimelineView(.periodic by: 1)` to tick. When it does, the clock
    /// leaf's body-pass count and its live value both advance, while the
    /// timeline subtree's body-pass count stays exactly where the isolation
    /// left it: zero re-evaluations. Putting the content back inside a
    /// periodic wrapper makes `subtree` climb every tick and this dies.
    func testPeriodicTickTouchesOnlyTheClockLeafNotTheTimelineSubtree() {
        let store = makeStore()
        let event = inProgressEvent(now: Date())
        store.rawCalendarEvents = [event]

        var subtree = 0
        var clockLeaf = 0
        var progressPPMs: [Int] = []
        SpikeProbe.onSignal = { signal in
            switch signal {
            case .bodyPass(CalendarDetailTimelineSignalID.subtree):
                subtree += 1
            case .bodyPass(CalendarDetailTimelineSignalID.clockLeaf):
                clockLeaf += 1
            case let .textLength(id, value) where id == CalendarDetailTimelineSignalID.clockProgressPPM:
                progressPPMs.append(value)
            default:
                break
            }
        }

        let route = CalendarEventDetailRoute(occurrence: occurrence(event), initialJumpTarget: nil)
        let h = host(CalendarEventDetailView(route: route).environmentObject(store))
        defer { teardownHost(h) }

        // The section must actually be on screen, else the counters below
        // measure a page that never built its timeline.
        XCTAssertGreaterThan(
            subtree, 0,
            "the timeline subtree never rendered — the fixture is wrong, not the code"
        )
        XCTAssertGreaterThan(
            clockLeaf, 0,
            "the live-progress leaf never rendered — the fixture is wrong, not the code"
        )

        // Baseline the counters at the end of the initial render, then watch
        // only the tick window.
        subtree = 0
        clockLeaf = 0
        progressPPMs.removeAll()

        let deadline = Date().addingTimeInterval(5.0)
        while clockLeaf < 2 && Date() < deadline {
            pump(0.25)
        }

        // POSITIVE CONTROL: the isolation is only observable if the leaf's
        // periodic actually fires in this host. If it does not, every
        // "subtree == 0" below would pass vacuously — so demand the tick.
        XCTAssertGreaterThanOrEqual(
            clockLeaf, 2,
            "the 1s live-progress leaf did not tick in a hosted window; the isolation "
            + "test cannot observe a tick without it (saw \(clockLeaf) leaf passes)"
        )

        // THE INVARIANT: a wall-clock tick re-evaluated ONLY the leaf. The
        // timeline subtree — track shell, composer, item list — did not run
        // its body once. That flat count is the gh#164 fix.
        XCTAssertEqual(
            subtree, 0,
            "a wall-clock tick re-evaluated the timeline subtree \(subtree) time(s); that "
            + "re-eval during an interactive pop IS the gh#164 hitch"
        )

        // RED LINE 1/4: the clock was MOVED to the leaf, not frozen. Its
        // live progress must be a fresh value each tick, not a cached one.
        XCTAssertGreaterThanOrEqual(
            Set(progressPPMs).count, 2,
            "the live-progress leaf produced a frozen value across ticks — the hoist must "
            + "move the wall-clock update to a smaller leaf, never drop it (saw \(progressPPMs))"
        )
    }

    // MARK: - gh#163 : a note keystroke re-renders only the editor leaf

    /// The load-bearing gh#163 test, on the PRODUCTION types. The detail view
    /// holds the note draft in a `CalendarTimelineNoteDraft` via plain
    /// `@State` — and `@State` does not subscribe to an `ObservableObject`,
    /// so mutating `text` never re-evaluates the holder. Only the two
    /// `@ObservedObject` editor leaves do. This harness mirrors exactly that
    /// ownership: the draft is `@State`-held here too, a subtree probe sits
    /// beside the real `CalendarTimelineNoteEditor`, and typing (mutating the
    /// box) must reach the editor and NOT the probe.
    func testNoteDraftKeystrokeReRendersOnlyTheEditorNotTheSubtree() {
        let draft = CalendarTimelineNoteDraft()

        var editorPasses = 0
        var subtreePasses = 0
        SpikeProbe.onSignal = { signal in
            switch signal {
            case .bodyPass(CalendarDetailTimelineSignalID.noteField):
                editorPasses += 1
            case .bodyPass(CalendarDetailTimelineSignalID.subtree):
                subtreePasses += 1
            default:
                break
            }
        }

        let h = host(NoteDraftIsolationHarness(draft: draft))
        defer { teardownHost(h) }

        XCTAssertGreaterThan(editorPasses, 0, "the editor never rendered — fixture is wrong")
        XCTAssertGreaterThan(subtreePasses, 0, "the subtree probe never rendered — fixture is wrong")

        // Baseline after the initial render, then TYPE.
        editorPasses = 0
        subtreePasses = 0

        draft.text = "a"
        pump(0.3)
        draft.text = "ab"
        pump(0.3)
        draft.text = "abc"
        pump(0.3)

        // The character has to show, so the editor MUST re-render.
        XCTAssertGreaterThanOrEqual(
            editorPasses, 2,
            "typing did not re-render the note editor leaf (saw \(editorPasses)); the box "
            + "wiring is broken"
        )
        // gh#163: and the timeline subtree MUST NOT.
        XCTAssertEqual(
            subtreePasses, 0,
            "a note keystroke re-rendered the timeline subtree \(subtreePasses) time(s); "
            + "typing must not rebuild the timeline (gh#163)"
        )
    }

    // MARK: - RED LINE 1/4 : the live-progress leaf uses the injected clock

    /// A deterministic guard that does not lean on periodic scheduling: host
    /// the REAL leaf at two different `now` values and confirm its emitted
    /// live-progress value moves. If the leaf ever ignores `now` (e.g.
    /// pins to `range.start`), the two values collapse and this dies —
    /// exactly the "clock frozen by the hoist" failure RED LINE 4 forbids.
    func testProgressFillLeafUsesTheInjectedClockNotAFrozenOne() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))

        var ppms: [Int] = []
        var leafPasses = 0
        SpikeProbe.onSignal = { signal in
            switch signal {
            case .bodyPass(CalendarDetailTimelineSignalID.clockLeaf):
                leafPasses += 1
            case let .textLength(id, value) where id == CalendarDetailTimelineSignalID.clockProgressPPM:
                ppms.append(value)
            default:
                break
            }
        }

        let h1 = host(
            CalendarTimelineProgressFillLeaf(
                now: start.addingTimeInterval(600),
                mode: .live,
                sliderProgress: 0,
                range: range,
                trackWidth: 200
            )
        )
        teardownHost(h1)

        let h2 = host(
            CalendarTimelineProgressFillLeaf(
                now: start.addingTimeInterval(1200),
                mode: .live,
                sliderProgress: 0,
                range: range,
                trackWidth: 200
            )
        )
        teardownHost(h2)

        XCTAssertGreaterThanOrEqual(leafPasses, 2, "the leaf did not render both times (saw \(leafPasses))")
        XCTAssertEqual(ppms.count, leafPasses, "every leaf pass must emit its live progress ppm")
        XCTAssertNotEqual(
            ppms.first, ppms.last,
            "the leaf's live progress did not change when `now` advanced — a frozen clock "
            + "(saw \(ppms))"
        )
    }

    // MARK: - Behaviour preservation : live progress is a function of the clock

    /// The value the leaf renders is `calendarEventTimelineResolvedState`'s
    /// `.live` display progress, which must advance monotonically with the
    /// wall clock across an in-progress range. This is the pure kernel the
    /// leaf must keep honouring after isolation (RED LINE 1).
    func testLiveDisplayProgressAdvancesWithTheWallClock() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))

        let early = calendarEventTimelineResolvedState(
            mode: .live, manualProgress: 0, now: start.addingTimeInterval(600), range: range
        ).displayProgress
        let later = calendarEventTimelineResolvedState(
            mode: .live, manualProgress: 0, now: start.addingTimeInterval(1200), range: range
        ).displayProgress

        XCTAssertGreaterThan(later, early, "live progress must advance as the clock advances")
        XCTAssertEqual(early, 1.0 / 6.0, accuracy: 0.0005, "10 min into a 60 min block ≈ 1/6")
        XCTAssertEqual(later, 2.0 / 6.0, accuracy: 0.0005, "20 min into a 60 min block ≈ 2/6")
    }
}

// MARK: - Test harness views

/// Mirrors the production ownership of the note draft: the parent holds it
/// via PLAIN `@State` (so `@State` does not subscribe to its
/// `objectWillChange`), the real editor leaf observes it, and the `subtree`
/// body-pass is emitted INLINE in this parent's body — exactly as production
/// emits it inline in `timelineSection`, NOT from a child. That inline
/// placement is load-bearing: a stateless child probe would be diff-skipped
/// by SwiftUI even when the parent re-runs, so it could not tell "parent
/// re-rendered" from "parent stayed put" and the test would have no teeth.
/// Emitting here means the count climbs whenever THIS body runs — and a
/// keystroke must not run it. (Verified: swapping this `@State` for
/// `@ObservedObject` re-shares the scope and the isolation test then fails.)
private struct NoteDraftIsolationHarness: View {
    @State private var draft: CalendarTimelineNoteDraft
    @FocusState private var focused: Bool

    init(draft: CalendarTimelineNoteDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        let _ = SpikeProbe.emit(.bodyPass(CalendarDetailTimelineSignalID.subtree))
        return VStack(spacing: 8) {
            CalendarTimelineNoteEditor(
                draft: draft,
                isFocused: $focused,
                placeholder: "Add note",
                onInteract: {}
            )
            Color.clear.frame(width: 1, height: 1)
        }
    }
}
