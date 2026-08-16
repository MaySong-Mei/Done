import XCTest
import SwiftUI
@testable import Done

/// Pure geometry behind the Todo stack drawer's chrome drag (gh#128): the
/// resistance curve past the full-page bound, the height the panel takes
/// under the finger, and which of the three detents a release settles to.
///
/// Everything here is the *rule*, not the presentation. Whether the panel
/// visibly follows the finger is a device question and belongs to QA; what
/// these pin down is that the numbers the panel is asked to take are the
/// ones the comments in `TodoStackView.swift` claim.
final class TodoStackChromeDragTests: XCTestCase {

    // MARK: - Rubber band

    func testChromeRubberBandStartsAt55PercentOfTheOvershoot() {
        // The comment this curve carried before gh#128 said the first
        // points past the bound travel "nearly 1:1". They don't — they
        // travel at the coefficient, and the cap was sized off that wrong
        // reading. The slope at the origin is 0.55, full stop.
        let limit: CGFloat = 500
        for overshoot in [CGFloat(0.001), 0.01, 0.1] {
            XCTAssertEqual(
                todoStackRubberBand(overshoot: overshoot, limit: limit) / overshoot,
                0.55,
                accuracy: 0.001
            )
        }
    }

    func testChromeRubberBandMatchesTheDocumentedCurve() {
        // (x·d·c)/(d + c·x), spelled out so a "simplification" that changes
        // the shape has to change this line too.
        let c: CGFloat = 0.55
        for (overshoot, limit) in [(CGFloat(100), CGFloat(500)), (37, 240), (900, 440)] {
            XCTAssertEqual(
                todoStackRubberBand(overshoot: overshoot, limit: limit),
                (overshoot * limit * c) / (limit + c * overshoot),
                accuracy: 0.0001
            )
        }
        // One worked value, so the identity above can't be satisfied by
        // two matching mistakes: 100 past a 500 bound gives 27500/555.
        XCTAssertEqual(
            todoStackRubberBand(overshoot: 100, limit: 500),
            49.5495,
            accuracy: 0.001
        )
    }

    func testChromeRubberBandAsymptotesToTheLimitWithoutReachingIt() {
        // The asymptote is `limit`, not `limit * 0.55` — the other half of
        // the comment that was wrong. No pull, however hard, gets past it.
        let limit: CGFloat = 440
        XCTAssertLessThan(todoStackRubberBand(overshoot: 100_000, limit: limit), limit)
        XCTAssertGreaterThan(todoStackRubberBand(overshoot: 100_000, limit: limit), limit * 0.99)
        XCTAssertLessThan(todoStackRubberBand(overshoot: 1_000_000_000, limit: limit), limit)
        XCTAssertEqual(
            todoStackRubberBand(overshoot: 1_000_000_000, limit: limit),
            limit,
            accuracy: 0.01
        )
    }

    func testChromeRubberBandIsMonotonic() {
        // A drag that keeps going must never come back toward the bound,
        // or the panel would fold under the finger.
        let limit: CGFloat = 500
        var previous = todoStackRubberBand(overshoot: 0, limit: limit)
        for overshoot in stride(from: CGFloat(1), through: 2000, by: 7) {
            let current = todoStackRubberBand(overshoot: overshoot, limit: limit)
            XCTAssertGreaterThan(current, previous)
            previous = current
        }
    }

    func testChromeRubberBandReturnsZeroForNonPositiveInput() {
        // Callers clamp before the bound, so a negative overshoot is a
        // caller bug rather than a shape to interpolate — and the raw
        // formula has a pole at `-limit / c` (here -909.09) that would
        // hand back a wild height instead of a wrong-but-small one.
        XCTAssertEqual(todoStackRubberBand(overshoot: 0, limit: 500), 0, accuracy: 0.0001)
        XCTAssertEqual(todoStackRubberBand(overshoot: -50, limit: 500), 0, accuracy: 0.0001)
        XCTAssertEqual(todoStackRubberBand(overshoot: -909.0909, limit: 500), 0, accuracy: 0.0001)
        // A bound of zero has no room to resist into. This is the state
        // the drawer is in before the host has been measured.
        XCTAssertEqual(todoStackRubberBand(overshoot: 300, limit: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(todoStackRubberBand(overshoot: 300, limit: -100), 0, accuracy: 0.0001)
    }

    // MARK: - Panel height under the finger

    func testChromeHeightTracksTheFingerBelowTheBound() {
        // 1:1 while there is room: pulling up 60 from a 440 drawer is 500,
        // pushing down 100 is 340. No resistance until the bound.
        XCTAssertEqual(
            todoStackChromeHeight(restHeight: 440, translationY: -60, containerHeight: 800),
            500,
            accuracy: 0.001
        )
        XCTAssertEqual(
            todoStackChromeHeight(restHeight: 440, translationY: 100, containerHeight: 800),
            340,
            accuracy: 0.001
        )
    }

    func testChromeHeightClampsAtDismissed() {
        // Dragging past the bottom of the screen is still the bottom of
        // the screen — a negative frame height would trap in layout.
        XCTAssertEqual(
            todoStackChromeHeight(restHeight: 440, translationY: 440, containerHeight: 800),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            todoStackChromeHeight(restHeight: 440, translationY: 5000, containerHeight: 800),
            0,
            accuracy: 0.001
        )
    }

    func testChromeHeightResistsPastTheFullPageBound() {
        // 100pt of pull past a full-page 800 panel yields 48.9, not 100 —
        // the bound announces itself immediately.
        XCTAssertEqual(
            todoStackChromeHeight(restHeight: 800, translationY: -100, containerHeight: 800),
            800 + (100 * 440 * 0.55) / (440 + 0.55 * 100),
            accuracy: 0.001
        )
        XCTAssertEqual(
            todoStackChromeHeight(restHeight: 800, translationY: -100, containerHeight: 800),
            848.889,
            accuracy: 0.01
        )
    }

    func testChromeHeightCapsOvershootAt55PercentOfThePanel() {
        // The limit passed to the curve is `containerHeight * 0.55`, so the
        // panel asymptotes at 1.55x the host. Passing the host itself —
        // which is what shipped before gh#128 — asymptotes at 2x, i.e. a
        // panel twice the screen with the finger still on it.
        let container: CGFloat = 800
        let reached = todoStackChromeHeight(
            restHeight: container,
            translationY: -100_000,
            containerHeight: container
        )
        XCTAssertLessThan(reached, container * 1.55)
        XCTAssertGreaterThan(reached, container * 1.54)
        // The shipped-before-gh#128 cap, for contrast.
        XCTAssertLessThan(reached, container * 2)
    }

    // MARK: - Detent selection on release

    func testSettleDetentHoldsTheDrawerWhenTheReleaseGoesNowhere() {
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 440,
                predictedEndTranslationY: 0,
                drawerHeight: 440,
                containerHeight: 800
            ),
            440
        )
    }

    func testSettleDetentCommitsToFullPageOnAnUpwardFlick() {
        // Projected 840 against detents 0 / 440 / 800: full page is 40 away
        // and the drawer 400, so the flick commits even though the finger
        // may have stopped well short.
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 440,
                predictedEndTranslationY: -400,
                drawerHeight: 440,
                containerHeight: 800
            ),
            800
        )
    }

    func testSettleDetentDismissesOnADownwardFlick() {
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 440,
                predictedEndTranslationY: 400,
                drawerHeight: 440,
                containerHeight: 800
            ),
            0
        )
    }

    func testSettleDetentFallsBackToTheShorterDetentOnAnExactTie() {
        // Landing exactly between two detents must be deterministic, and
        // the deterministic answer is the one that commits less.
        // Midpoint of 0 and 440, projected 220:
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 440,
                predictedEndTranslationY: 220,
                drawerHeight: 440,
                containerHeight: 800
            ),
            0
        )
        // Midpoint of 440 and 800, projected 620:
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 440,
                predictedEndTranslationY: -180,
                drawerHeight: 440,
                containerHeight: 800
            ),
            440
        )
        // One point past that midpoint and full page wins, which is what
        // makes the tie a boundary rather than a dead zone.
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 440,
                predictedEndTranslationY: -181,
                drawerHeight: 440,
                containerHeight: 800
            ),
            800
        )
    }

    func testSettleDetentClampsTheDrawerToTheContainer() {
        // A measured drawer taller than its host (rotation, or a stale
        // measurement) must not become a detent above full page — the
        // panel would settle somewhere it cannot be laid out.
        let target = todoStackSettleDetent(
            restHeight: 800,
            predictedEndTranslationY: 0,
            drawerHeight: 900,
            containerHeight: 800
        )
        XCTAssertEqual(target, 800)
    }

    func testSettleDetentDegeneratesWhenTheDrawerFillsTheContainer() {
        // The failure mode the measurement gate in TodoStackView guards
        // against: once `drawerHeight == containerHeight` the detents are
        // [0, full, full] and every non-dismissing nudge — in either
        // direction — reads as "go full page". Pinned here so the shape of
        // the degeneracy is on record, not so it is endorsed.
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 800,
                predictedEndTranslationY: -10,
                drawerHeight: 800,
                containerHeight: 800
            ),
            800
        )
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 800,
                predictedEndTranslationY: 10,
                drawerHeight: 800,
                containerHeight: 800
            ),
            800
        )
    }

    func testSettleDetentRefusesDetentsThatHaveNotBeenMeasured() {
        // Before the host or the panel has reported a height there is
        // nothing to settle to; the release is absorbed rather than
        // snapping the drawer to zero.
        XCTAssertNil(
            todoStackSettleDetent(
                restHeight: 0,
                predictedEndTranslationY: 0,
                drawerHeight: 440,
                containerHeight: 0
            )
        )
        XCTAssertNil(
            todoStackSettleDetent(
                restHeight: 0,
                predictedEndTranslationY: -300,
                drawerHeight: 0,
                containerHeight: 800
            )
        )
        XCTAssertNil(
            todoStackSettleDetent(
                restHeight: 440,
                predictedEndTranslationY: 0,
                drawerHeight: -440,
                containerHeight: 800
            )
        )
    }
}
