import XCTest
import SwiftUI
@testable import Done

/// Pure geometry behind the Todo stack drawer's chrome drag (gh#128): the
/// resistance curve past the full-page bound, the height the panel takes
/// under the finger, which of the three detents a release settles to —
/// including when full page stops being one — and which measured heights
/// are allowed to become the drawer detent in the first place.
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

    func testSettleDetentStillLandsAtTheContainerWhenTheDrawerFillsIt() {
        // Once `drawerHeight == containerHeight` there is nowhere else a
        // non-dismissing nudge can go, so the *height* is the container
        // either way — that part is geometry, not a decision.
        //
        // What must not follow is "and therefore it is full page". The two
        // detents are one number here, so full page is not a destination
        // (next assertion), and TodoStackView pairs the height with that
        // predicate before it sets `fullPageSettled`.
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
        XCTAssertFalse(todoStackFullPageIsADetent(drawerHeight: 800, containerHeight: 800))
    }

    // MARK: - Full page as a detent

    func testFullPageStopsBeingADetentOnceItIsNotMeaningfullyAboveTheDrawer() {
        // Device-measured (gh#128 round 4): with the software keyboard up
        // and 9 cards, the drawer rested 37.67pt below full page — so the
        // nearest-detent rule promoted on a 19pt nudge, and the drawer was
        // still full page after the keyboard went away. 37.67 is not a
        // destination.
        XCTAssertFalse(todoStackFullPageIsADetent(drawerHeight: 740.334, containerHeight: 778))
        // The gaps the drawer actually has on the reference device with no
        // keyboard: 289.67 with a full stack, 490 with an empty one. Both
        // are real destinations and must stay reachable.
        XCTAssertTrue(todoStackFullPageIsADetent(drawerHeight: 488.334, containerHeight: 778))
        XCTAssertTrue(todoStackFullPageIsADetent(drawerHeight: 288, containerHeight: 778))
    }

    func testFullPageDetentBoundaryIsTheMinimumSeparation() {
        // Inclusive at the boundary, so the constant reads as "at least
        // this far apart".
        let container: CGFloat = 800
        XCTAssertTrue(
            todoStackFullPageIsADetent(
                drawerHeight: container - todoStackMinimumDetentSeparation,
                containerHeight: container
            )
        )
        XCTAssertFalse(
            todoStackFullPageIsADetent(
                drawerHeight: container - todoStackMinimumDetentSeparation + 0.5,
                containerHeight: container
            )
        )
        // A drawer measured taller than its host clamps to the host, which
        // makes the separation zero rather than negative.
        XCTAssertFalse(todoStackFullPageIsADetent(drawerHeight: 900, containerHeight: 800))
    }

    func testSettleDetentRefusesToPromoteAcrossACompressedGap() {
        // The G1 repro as a rule: drawer 740.33 / full 778. The 25pt nudge
        // that promoted on device, and a 10pt one that did not, must now
        // both fall back to the drawer — as must a pull that projects past
        // full page entirely, because there is no full-page detent to reach.
        for nudge in [CGFloat(10), 25, 60, 200] {
            XCTAssertEqual(
                todoStackSettleDetent(
                    restHeight: 740.334,
                    predictedEndTranslationY: -nudge,
                    drawerHeight: 740.334,
                    containerHeight: 778
                ),
                740.334,
                "a \(nudge)pt pull promoted the drawer across a 37.67pt gap"
            )
        }
        // Dismissal is untouched: it is the drawer's own height away, not
        // the gap's, so a real downward flick still commits.
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 740.334,
                predictedEndTranslationY: 500,
                drawerHeight: 740.334,
                containerHeight: 778
            ),
            0
        )
    }

    func testSettleDetentLeavesNormalGeometryCommitThresholdsAlone() {
        // The other half of G1: the compressed-gap rule must not become a
        // dead zone on normal geometry, where the commit threshold is half
        // the (large) gap and is a product decision nobody has revisited.
        // Populated drawer on the reference device: 488.33 / 778, midpoint
        // 633.17, so 145pt of projection commits and 144 does not.
        let drawer: CGFloat = 488.334
        let container: CGFloat = 778
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: drawer,
                predictedEndTranslationY: -144,
                drawerHeight: drawer,
                containerHeight: container
            ),
            drawer
        )
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: drawer,
                predictedEndTranslationY: -146,
                drawerHeight: drawer,
                containerHeight: container
            ),
            container
        )
        // Empty drawer: 288 / 778, midpoint 533, so 245pt commits.
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 288,
                predictedEndTranslationY: -244,
                drawerHeight: 288,
                containerHeight: container
            ),
            288
        )
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 288,
                predictedEndTranslationY: -246,
                drawerHeight: 288,
                containerHeight: container
            ),
            container
        )
    }

    func testChromeHeightWithoutAMeasuredHostTracksTheFingerInsteadOfCollapsing() {
        // With `containerHeight == 0` every positive height is "past the
        // bound", and the bound has no room to resist into — so the
        // rubber-band branch would return the container plus zero, i.e. a
        // panel of no height, for a finger halfway up the screen. No host
        // measured means no bound, not a bound at nothing.
        XCTAssertEqual(
            todoStackChromeHeight(restHeight: 440, translationY: -60, containerHeight: 0),
            500,
            accuracy: 0.001
        )
        XCTAssertEqual(
            todoStackChromeHeight(restHeight: 440, translationY: 100, containerHeight: 0),
            340,
            accuracy: 0.001
        )
        XCTAssertEqual(
            todoStackChromeHeight(restHeight: 440, translationY: 900, containerHeight: 0),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            todoStackChromeHeight(restHeight: 440, translationY: 0, containerHeight: -100),
            440,
            accuracy: 0.001
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

    // MARK: - Which measured heights become the drawer detent

    func testDrawerHeightRecordsANaturalLayoutBelowTheHost() {
        XCTAssertTrue(
            todoStackShouldRecordDrawerHeight(
                height: 440,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 800
            )
        )
    }

    func testDrawerHeightRefusesAHeightThatFillsItsHost() {
        // The one value the gate exists to reject: a drawer detent equal to
        // its container collapses the settle to [0, full, full]. Keeping the
        // previous — possibly stale — value is strictly better than adopting
        // a number that is not a detent.
        XCTAssertFalse(
            todoStackShouldRecordDrawerHeight(
                height: 800,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 800
            )
        )
        XCTAssertFalse(
            todoStackShouldRecordDrawerHeight(
                height: 900,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 800
            )
        )
        // Including before the host has been measured, where every height
        // fills it.
        XCTAssertFalse(
            todoStackShouldRecordDrawerHeight(
                height: 440,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 0
            )
        )
    }

    func testDrawerHeightRefusesTheFullPageDetentAndFramesUnderTheFinger() {
        XCTAssertFalse(
            todoStackShouldRecordDrawerHeight(
                height: 700,
                isFullPage: true,
                isChromeDragging: false,
                containerHeight: 800
            )
        )
        // `isChromeDragging` covers both the finger being down and the
        // height held through a dismissal — neither is a layout the panel
        // chose.
        XCTAssertFalse(
            todoStackShouldRecordDrawerHeight(
                height: 700,
                isFullPage: false,
                isChromeDragging: true,
                containerHeight: 800
            )
        )
    }

    func testDrawerHeightRefusesNonPositiveHeights() {
        // A zero-height frame during a transition would take `drawerHeight`
        // to 0, and both `chromeDragHeights` and `todoStackSettleDetent`
        // refuse to work from there — the chrome drag would go inert for
        // the rest of the open.
        XCTAssertFalse(
            todoStackShouldRecordDrawerHeight(
                height: 0,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 800
            )
        )
        XCTAssertFalse(
            todoStackShouldRecordDrawerHeight(
                height: -20,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 800
            )
        )
    }

    func testDrawerHeightRecordsEveryFrameOfADescendingSequence() {
        // Static review predicted a ratchet here: a growth-only gate would
        // latch the first frame of a settle coming down from full page and
        // walk `drawerHeight` up toward the container. Device QA found
        // `onGeometryChange` never reports interpolated animation frames at
        // all, so the sequence does not arrive — and the gate has no growth
        // term now either way. Whatever descends, if it is a real layout
        // below the host, is recordable.
        for height in stride(from: CGFloat(778), through: 480, by: -37) {
            XCTAssertEqual(
                todoStackShouldRecordDrawerHeight(
                    height: height,
                    isFullPage: false,
                    isChromeDragging: false,
                    containerHeight: 800
                ),
                true,
                "descending frame \(height) was refused"
            )
        }
    }

    func testDrawerHeightRecordsAKeyboardCompressedLayout() {
        // Recording it is what keeps `restHeight` equal to where the panel
        // actually is, so the first frame of a chrome drag does not jump.
        // Safety comes from the detent rule instead: a drawer squeezed to
        // within 88pt of its host has no full page to be promoted to.
        XCTAssertTrue(
            todoStackShouldRecordDrawerHeight(
                height: 740.334,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 778
            )
        )
        XCTAssertFalse(todoStackFullPageIsADetent(drawerHeight: 740.334, containerHeight: 778))
    }
}
