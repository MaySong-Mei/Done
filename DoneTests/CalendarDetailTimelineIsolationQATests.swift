//  CalendarDetailTimelineIsolationQATests
//
//  INDEPENDENT QA (lane: detail-subtree) for the gh#164 / gh#163 structural
//  isolation of the event-detail timeline. Written by a reviewer who does
//  not touch production code; these tests attack the gaps the branch's own
//  `CalendarDetailTimelineIsolationTests` leaves open:
//
//    * QA1  The hidden AUTO-RESUME DRIVER leaf is a `Color.clear` framed to
//           ZERO size wrapped in `TimelineView(.periodic by: 1)`. The branch
//           proves the *visible* progress leaf ticks, but a zero-size view is
//           exactly the kind SwiftUI can decline to schedule. If this leaf
//           does not tick, `handleTimelineTick` never runs and the
//           manual->live auto-resume the old whole-block `.onChange(of:
//           context.date)` carried is silently dead. Faithful mirror of the
//           production driver, with a visible-frame positive control so a
//           host-wide scheduling failure is distinguishable from the
//           zero-size defect.
//    * QA2  A clock tick must NOT re-render the real `CalendarTimelineNote
//           Editor` leaf. That leaf hosts the live `TextEditor`; if a tick
//           rebuilt it, the field would lose its first responder / cursor
//           mid-type. The branch never places the editor beside a ticking
//           clock; this does, and demands the editor's body-pass count stay
//           flat while the clock leaf climbs (view-identity red line).
//    * QA3  gh#163 persistence mechanism: the draft text lives in an
//           unobserved box that the flush/save read IMPERATIVELY. This types
//           through the REAL editor's two-way binding and confirms an
//           imperative `draft.text` read (exactly what `flushTimelineNote
//           Draft`/`saveTimelineNote` do) sees every character — the note
//           can still be persisted.
//    * QA4  Frozen-clock teeth: same `now` twice -> same ppm; the branch
//           proves different-now -> different-ppm, this proves the value is a
//           pure function of the injected clock (so the different-now result
//           is not an artifact of two independent renders drifting).
//
//  Uses the repo `SpikeProbe` body-pass seam (resident listener is not
//  created under XCTest, so a test owns `SpikeProbe.onSignal`) and the same
//  real-UIWindow host + run-loop pump the branch's tests established.

import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Done

@MainActor
final class CalendarDetailTimelineIsolationQATests: XCTestCase {

    override func setUp() {
        super.setUp()
        SpikeProbe.onSignal = nil
    }

    override func tearDown() {
        SpikeProbe.onSignal = nil
        super.tearDown()
    }

    // MARK: - Host helpers (real UIWindow, real run loop)

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

    // MARK: - QA1 : the zero-size auto-resume driver leaf actually ticks

    /// Mirrors the production driver leaf EXACTLY: a `Color.clear` framed to
    /// 0x0 inside a `TimelineView(.periodic by: 1)`, carrying the side effect
    /// on `.onChange(of: context.date)` and a warm-up on `.onAppear`. A
    /// visible-frame sibling is the positive control: if BOTH fail to tick,
    /// the host could not schedule any periodic (infrastructure); if only the
    /// zero-size one fails, the production auto-resume is dead.
    func testHiddenZeroSizeDriverLeafTicksLikeAVisibleOne() {
        final class Counters {
            var zeroAppear = 0
            var zeroTick = 0
            var visibleTick = 0
        }
        let c = Counters()

        let h = host(
            VStack(spacing: 0) {
                // Production driver mirror: zero size.
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    Color.clear
                        .frame(width: 0, height: 0)
                        .onChange(of: context.date) { _, _ in c.zeroTick += 1 }
                        .onAppear { c.zeroAppear += 1 }
                }
                // Positive control: visible size, same periodic.
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    Color.clear
                        .frame(width: 10, height: 10)
                        .onChange(of: context.date) { _, _ in c.visibleTick += 1 }
                }
            }
        )
        defer { teardownHost(h) }

        XCTAssertGreaterThanOrEqual(
            c.zeroAppear, 1,
            "the zero-size driver leaf never appeared; it is not in the hosted hierarchy"
        )

        let deadline = Date().addingTimeInterval(5.0)
        while (c.zeroTick < 1 || c.visibleTick < 1) && Date() < deadline {
            pump(0.25)
        }

        // Positive control: the host CAN drive a periodic leaf.
        XCTAssertGreaterThanOrEqual(
            c.visibleTick, 1,
            "no periodic leaf ticked in the host at all — infrastructure, not the zero-size "
            + "question (visible=\(c.visibleTick))"
        )
        // THE INVARIANT: the zero-size driver ticks too, so `handleTimelineTick`
        // (auto-resume manual->live) still runs each second.
        XCTAssertGreaterThanOrEqual(
            c.zeroTick, 1,
            "the zero-size auto-resume driver leaf did NOT tick while a visible one did "
            + "(zero=\(c.zeroTick), visible=\(c.visibleTick)); the manual->live auto-resume "
            + "side effect is stranded — a behaviour regression the branch's tests miss"
        )
    }

    // MARK: - QA2 : a tick does not re-render the real note editor leaf

    /// The real `CalendarTimelineNoteEditor` sits beside a real
    /// `CalendarTimelineProgressFillLeaf` clock leaf. Ticks must climb the
    /// clock leaf's body-pass count while leaving the editor's flat: the
    /// TextEditor keeps its identity (and thus first-responder/cursor) across
    /// wall-clock ticks. If a tick rebuilt the editor, `noteField` would
    /// climb and this dies.
    func testClockTickDoesNotReRenderTheRealNoteEditorLeaf() {
        let start = Date(timeIntervalSince1970: 3_000_000)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
        let draft = CalendarTimelineNoteDraft()
        draft.text = "typed"

        var clockLeaf = 0
        var noteField = 0
        SpikeProbe.onSignal = { signal in
            switch signal {
            case .bodyPass(CalendarDetailTimelineSignalID.clockLeaf):
                clockLeaf += 1
            case .bodyPass(CalendarDetailTimelineSignalID.noteField):
                noteField += 1
            default:
                break
            }
        }

        let h = host(EditorBesideClockHarness(draft: draft, range: range))
        defer { teardownHost(h) }

        XCTAssertGreaterThan(clockLeaf, 0, "the clock leaf never rendered — fixture is wrong")
        XCTAssertGreaterThan(noteField, 0, "the note editor never rendered — fixture is wrong")

        clockLeaf = 0
        noteField = 0

        let deadline = Date().addingTimeInterval(5.0)
        while clockLeaf < 2 && Date() < deadline {
            pump(0.25)
        }

        XCTAssertGreaterThanOrEqual(
            clockLeaf, 2,
            "the clock leaf did not tick in the host (saw \(clockLeaf)); cannot observe the "
            + "isolation without a tick"
        )
        XCTAssertEqual(
            noteField, 0,
            "a wall-clock tick re-rendered the note editor leaf \(noteField) time(s); the live "
            + "TextEditor would lose its cursor/first-responder mid-type (view-identity red line)"
        )
    }

    // MARK: - QA3 : typing flows through the box to an imperative reader

    /// gh#163 persistence mechanism. Type through the REAL editor's binding
    /// (mutating the box, as a keystroke does) and confirm an IMPERATIVE read
    /// of `draft.text` — the exact shape `flushTimelineNoteDraft` /
    /// `saveTimelineNote` use, `trimmingCharacters(in: .whitespacesAndNewlines)`
    /// — sees every character even though the parent body never re-ran. If the
    /// box failed to carry the value to imperative readers, the flush/save
    /// would persist stale or empty text and the note would be lost.
    func testTypedTextReachesImperativeReaderThroughTheDraftBox() {
        let draft = CalendarTimelineNoteDraft()

        var noteField = 0
        SpikeProbe.onSignal = { signal in
            if case .bodyPass(CalendarDetailTimelineSignalID.noteField) = signal { noteField += 1 }
        }

        let h = host(NoteEditorOnlyHarness(draft: draft))
        defer { teardownHost(h) }

        XCTAssertGreaterThan(noteField, 0, "the editor never rendered — fixture is wrong")
        noteField = 0

        // Type, the way the branch's own mechanism test does.
        draft.text = "b"
        pump(0.2)
        draft.text = "br"
        pump(0.2)
        draft.text = "brunch  "   // trailing space the trim must drop
        pump(0.2)

        // The character had to show, so the editor re-rendered.
        XCTAssertGreaterThanOrEqual(
            noteField, 2,
            "typing did not re-render the editor leaf (saw \(noteField)); the two-way binding "
            + "to the box is broken"
        )
        // The imperative read persistence uses sees the latest characters.
        let imperativeTrimmed = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            imperativeTrimmed, "brunch",
            "an imperative read of the draft box did not see the typed text; a flush/save at "
            + "this instant would persist '\(imperativeTrimmed)' instead of 'brunch'"
        )
    }

    // MARK: - QA4 : frozen-clock teeth (pure function of the injected clock)

    /// The branch proves different-`now` -> different-ppm. This proves the
    /// complementary half: identical `now` -> identical ppm. Together they
    /// pin that the leaf's value is a pure function of the clock it is handed
    /// — so the branch's freshness result is real, not two renders drifting.
    func testProgressFillLeafIsAPureFunctionOfTheInjectedClock() {
        let start = Date(timeIntervalSince1970: 4_000_000)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
        let fixedNow = start.addingTimeInterval(900) // 15 min in -> 0.25

        var ppms: [Int] = []
        SpikeProbe.onSignal = { signal in
            if case let .textLength(id, value) = signal,
               id == CalendarDetailTimelineSignalID.clockProgressPPM {
                ppms.append(value)
            }
        }

        for _ in 0..<2 {
            let h = host(
                CalendarTimelineProgressFillLeaf(
                    now: fixedNow,
                    mode: .live,
                    sliderProgress: 0,
                    range: range,
                    trackWidth: 200
                )
            )
            teardownHost(h)
        }

        XCTAssertGreaterThanOrEqual(ppms.count, 2, "the leaf did not render twice (saw \(ppms))")
        XCTAssertEqual(
            Set(ppms).count, 1,
            "the same injected clock produced DIFFERENT ppm values (\(ppms)); the leaf is not a "
            + "pure function of `now` — its freshness cannot be trusted"
        )
        XCTAssertEqual(ppms.first, 250_000, "15 min into a 60 min block == 0.25 == 250000 ppm")
    }
}

// MARK: - QA harness views

/// Real production editor beside a real production clock leaf. The clock is
/// wrapped in its own `TimelineView(.periodic by: 1)` so ONLY it re-evaluates
/// per tick; the editor is a plain sibling, exactly as production places it
/// next to the "drop note at" leaf. If a tick disturbed the editor, its
/// `noteField` body-pass would climb.
@MainActor
private struct EditorBesideClockHarness: View {
    let draft: CalendarTimelineNoteDraft
    let range: Event.TimeRange
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                CalendarTimelineProgressFillLeaf(
                    now: context.date,
                    mode: .live,
                    sliderProgress: 0,
                    range: range,
                    trackWidth: 200
                )
            }
            CalendarTimelineNoteEditor(
                draft: draft,
                isFocused: $focused,
                placeholder: "Add note",
                onInteract: {}
            )
        }
    }
}

/// The real editor alone, observing the box, so a keystroke re-renders it.
@MainActor
private struct NoteEditorOnlyHarness: View {
    let draft: CalendarTimelineNoteDraft
    @FocusState private var focused: Bool

    var body: some View {
        CalendarTimelineNoteEditor(
            draft: draft,
            isFocused: $focused,
            placeholder: "Add note",
            onInteract: {}
        )
    }
}
