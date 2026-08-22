import XCTest
import SwiftUI
@testable import Done

/// Pure geometry behind the Todo stack drawer's chrome drag (gh#128): the
/// resistance curve past the full-page bound, the height the panel takes
/// under the finger, what a release has to cost before it changes detent,
/// and which measured heights are allowed to become the drawer detent in
/// the first place.
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

    // MARK: - What a detent change costs

    func testCommitTravelIsHalfTheGapBetweenTheClamps() {
        // Between the clamps the threshold is the midpoint the old
        // nearest-detent rule used, restated as a price.
        XCTAssertEqual(todoStackCommitTravel(gap: 200), 100, accuracy: 0.0001)
        XCTAssertEqual(todoStackCommitTravel(gap: 150), 75, accuracy: 0.0001)
        // Both ends of the unclamped band, inclusive.
        XCTAssertEqual(todoStackCommitTravel(gap: 88), 44, accuracy: 0.0001)
        XCTAssertEqual(todoStackCommitTravel(gap: 240), 120, accuracy: 0.0001)
    }

    func testCommitTravelClampsAtBothEnds() {
        // Near end: half of the keyboard-compressed 37.67pt gap is a 19pt
        // nudge, which is what promoted the drawer to full page on device
        // in round 4. The floor is one touch target.
        XCTAssertEqual(todoStackCommitTravel(gap: 37.67), 44, accuracy: 0.0001)
        XCTAssertEqual(todoStackCommitTravel(gap: 86.5), 44, accuracy: 0.0001)
        XCTAssertEqual(todoStackCommitTravel(gap: 0), 44, accuracy: 0.0001)
        XCTAssertEqual(todoStackCommitTravel(gap: -100), 44, accuracy: 0.0001)
        // Far end: a 13" iPad portrait drawer sits ~878pt below full page,
        // and 439pt of sustained one-directional drag is a re-grip rather
        // than a gesture.
        XCTAssertEqual(todoStackCommitTravel(gap: 877.67), 120, accuracy: 0.0001)
        XCTAssertEqual(todoStackCommitTravel(gap: 100_000), 120, accuracy: 0.0001)
    }

    // MARK: - Detent selection on release

    /// A release that starts on the drawer detent. `projecting` is how far
    /// the flick projects in points, positive = upward (the sign the view
    /// works in is the gesture's, which is inverted).
    private func settleFromDrawer(
        projecting travel: CGFloat,
        drawer: CGFloat,
        container: CGFloat
    ) -> TodoStackDetent? {
        todoStackSettleDetent(
            restHeight: drawer,
            predictedEndTranslationY: -travel,
            drawerHeight: drawer,
            containerHeight: container
        )
    }

    /// The same, for a release that starts on the full-page detent.
    private func settleFromFullPage(
        projecting travel: CGFloat,
        drawer: CGFloat,
        container: CGFloat
    ) -> TodoStackDetent? {
        todoStackSettleDetent(
            restHeight: container,
            predictedEndTranslationY: -travel,
            drawerHeight: drawer,
            containerHeight: container
        )
    }

    func testSettleDetentStaysPutWhenTheReleaseGoesNowhere() {
        // `.stay`, not `.drawer`: "hold where you are" is its own answer.
        // The two happen to name the same height here, which is exactly why
        // the conflation survived five rounds — see
        // `testSettleDetentHoldsAFullPageTheLadderNoLongerOffers` for where
        // they part company.
        XCTAssertEqual(settleFromDrawer(projecting: 0, drawer: 440, container: 800), .stay)
    }

    func testSettleDetentCommitsUpwardOnlyPastTheThreshold() {
        // Drawer 440 / full 800 is a 360pt gap, so the price clamps to 120.
        // Exactly the price stays — the rule commits on *more than* it —
        // and a hair past commits, with the finger still 239pt short of
        // full page. That is the whole point of projecting: a short fast
        // flick is a decision.
        XCTAssertEqual(settleFromDrawer(projecting: 120, drawer: 440, container: 800), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: 120.5, drawer: 440, container: 800), .fullPage)
        XCTAssertEqual(settleFromDrawer(projecting: 5000, drawer: 440, container: 800), .fullPage)
    }

    func testSettleDetentCommitsDownwardOnlyPastTheThreshold() {
        // Downward out of the drawer there is one thing below, so the gap
        // is the drawer's own height (440) and the price clamps to 120.
        // Deliberately cheaper than the 220pt midpoint the nearest-detent
        // rule charged: the far-end clamp applies in both directions, and a
        // 120pt deliberate pull down on the grabber is a dismissal.
        XCTAssertEqual(settleFromDrawer(projecting: -120, drawer: 440, container: 800), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: -120.5, drawer: 440, container: 800), .dismissed)
    }

    func testSettleDetentCrossesTwoDetentsOnAHardFlickDown() {
        // From full page: a hard flick has to be able to reach dismissed
        // without stopping at the drawer, and a moderate one has to stop
        // there. Both are "one price, then land on the nearest in that
        // direction".
        XCTAssertEqual(settleFromFullPage(projecting: -900, drawer: 440, container: 800), .dismissed)
        XCTAssertEqual(settleFromFullPage(projecting: -200, drawer: 440, container: 800), .drawer)
        // The price out of full page is half the 360pt gap to the drawer,
        // clamped to 120 — so a smaller pull holds full page.
        XCTAssertEqual(settleFromFullPage(projecting: -120, drawer: 440, container: 800), .stay)
        XCTAssertEqual(settleFromFullPage(projecting: -120.5, drawer: 440, container: 800), .drawer)
    }

    func testSettleDetentLandsOnTheSmallerCommitmentOnAnExactTie() {
        // Past the price, where it lands is nearest-wins among the detents
        // in that direction, and an exact tie must be deterministic. From
        // full page 800, projecting 580 down puts the release at 220 —
        // exactly between dismissed and the 440 drawer. The deterministic
        // answer is the candidate nearer the origin: the one that commits
        // less.
        //
        // Round 5 answered `.dismissed` here — the *larger* commitment —
        // while its doc comment claimed the opposite, because narrowing the
        // candidate set to "detents ahead" reversed which of two equals
        // `min(by:)` sees first. Reachable only on float-exact equality, so
        // this pins the rule rather than reporting a symptom.
        XCTAssertEqual(settleFromFullPage(projecting: -580, drawer: 440, container: 800), .drawer)
        // A point either side, so the tie is a boundary rather than a dead
        // zone: short of the midpoint the drawer wins on distance too, past
        // it dismissed does.
        XCTAssertEqual(settleFromFullPage(projecting: -579, drawer: 440, container: 800), .drawer)
        XCTAssertEqual(settleFromFullPage(projecting: -581, drawer: 440, container: 800), .dismissed)
    }

    func testSettleDetentPriceIsClampedOnAVeryLargeGap() {
        // 13" iPad portrait: container 1366, drawer 488.33, so the gap is
        // 877.67 and half of it — the old rule's price — is 439pt of
        // sustained one-directional drag. 120 buys it now.
        XCTAssertEqual(
            settleFromDrawer(projecting: 120, drawer: 488.33, container: 1366),
            .stay
        )
        XCTAssertEqual(
            settleFromDrawer(projecting: 121, drawer: 488.33, container: 1366),
            .fullPage
        )
    }

    func testSettleDetentPriceIsFlooredOnASmallLegitimateGap() {
        // The round-4 regression, as a rule: SE 3rd gen portrait at AX5
        // with one card measured container 647 / drawer 560.5, a legitimate
        // 86.5pt gap. Round 4 deleted the full-page detent below 88pt of
        // separation, so this user could not expand the drawer at all — no
        // flick strength reached full page, on the accessibility
        // configuration only. Full page is a destination again, at a price
        // of 44 rather than the 43.25 half-gap.
        XCTAssertEqual(settleFromDrawer(projecting: 44, drawer: 560.5, container: 647), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: 44.5, drawer: 560.5, container: 647), .fullPage)
        // The 50pt of travel QA measured on device, which settled back
        // every time under round 4.
        XCTAssertEqual(settleFromDrawer(projecting: 50, drawer: 560.5, container: 647), .fullPage)
    }

    func testSettleDetentRefusesToPromoteAcrossACompressedGap() {
        // 17 Pro portrait with one card and the keyboard up: container 477,
        // drawer 439.3. The 37.7pt gap is under the minimum commit travel,
        // so full page is not a destination — arriving would move the panel
        // less than the shortest gesture that can ask for it, while
        // latching a mode that only shows itself when the keyboard goes
        // away. These are the inputs QA drove on device in round 4.
        //
        // Two coordinate pairs for one geometry: 439.3/477 is what round 5
        // drove, 740.334/778 is the original G1 repro (the same 37.67pt gap
        // measured before the keyboard shortened the host). Behaviourally
        // equivalent, and keeping both means the reported numbers stay
        // findable from the test that answers them.
        for (drawer, container) in [(CGFloat(439.3), CGFloat(477)), (740.334, 778)] {
            for travel in [CGFloat(25), 60, 90, 150, 300, 10_000] {
                XCTAssertEqual(
                    settleFromDrawer(projecting: travel, drawer: drawer, container: container),
                    .stay,
                    "a \(travel)pt projection promoted the \(drawer)/\(container) drawer across a 37.7pt gap"
                )
            }
            // Dismissal is untouched: it is the drawer's own height away,
            // not the gap's, so a real downward flick still commits.
            XCTAssertEqual(
                settleFromDrawer(projecting: -500, drawer: drawer, container: container),
                .dismissed,
                "\(drawer)/\(container)"
            )
        }
    }

    func testSettleDetentHoldsAFullPageTheLadderNoLongerOffers() {
        // The round-5 blocker, as the rule that produced it. Pull to full
        // page, then raise the keyboard: the panel rests at the container
        // height on a ladder that no longer has a full-page rung, because
        // the keyboard squeezed the drawer to within one touch target of
        // the host. Round 5 answered every release here with `.drawer` —
        // "stay" spelled as the nearest rung — and the caller read that as
        // a demotion, so the full page was destroyed by any chrome touch
        // that was not a perfect tap. Device QA reproduced it on three
        // device classes, from a 2pt delivered nudge.
        //
        // All three of those geometries, and in each one: a release that
        // goes nowhere, a 36pt pull up (QA's video: the panel rose, then the
        // release snapped it down), a 4pt commanded nudge at the ~0.5x
        // delivery ratio, and a 10pt push down. None of them buys anything,
        // so all of them hold.
        //
        // Plus a fourth pairing that is not a QA row, because on a 17 Pro it
        // is the one a device actually presents. Reaching full page at all
        // needs the keyboard *down* — the ladder has to have a full-page
        // rung to commit to — and while `isFullPage` is true
        // `todoStackShouldRecordDrawerHeight` refuses every measurement, so
        // the drawer cannot be re-measured under the keyboard. What is
        // frozen there is the keyboard-down 488.33, against a container the
        // keyboard has cut to 477: drawer > host. The 439.3/477 pairing
        // needs both a drawer recorded under the keyboard and a panel at
        // full page, and those exclude each other — recording 439.3 means
        // the panel was at the *drawer* with the keyboard up, and from
        // there the 37.7pt gap leaves no full-page rung to promote onto.
        //
        // Same behaviour in kind — only `.stay` and `.dismissed`, upward
        // holds at any strength — but the dismissal is 37.7pt cheaper,
        // because the panel is resting *on* the rung the price is quoted
        // against instead of above it. `dismissAt` is that boundary: the
        // clamped 120 plus the overhang. Anyone re-testing this on a 17 Pro
        // should expect to lose the panel at ~120pt of projection, not ~158.
        let geometries: [(label: String, drawer: CGFloat, container: CGFloat, dismissAt: CGFloat)] = [
            ("17 Pro portrait, 1 card, keyboard up", 439.3, 477, 157.7),
            ("17 Pro portrait, keyboard raised onto a full page", 488.33, 477, 120),
            ("SE 3rd gen portrait, 1 card, keyboard up", 387, 387, 120),
            ("iPad Air 11in landscape, empty, keyboard up", 288, 298, 130)
        ]
        for geometry in geometries {
            for travel in [CGFloat(0), 36, 2, -2, -10, -36] {
                XCTAssertEqual(
                    settleFromFullPage(
                        projecting: travel,
                        drawer: geometry.drawer,
                        container: geometry.container
                    ),
                    .stay,
                    "\(geometry.label): a \(travel)pt projection moved a held full page"
                )
            }
            // Upward is unconditional: there is nothing above to buy, at any
            // strength.
            XCTAssertEqual(
                settleFromFullPage(
                    projecting: 10_000,
                    drawer: geometry.drawer,
                    container: geometry.container
                ),
                .stay,
                geometry.label
            )
            // Holding is not being trapped. A real downward flick still
            // dismisses from here — priced against the ladder, so it costs
            // the drawer's own height plus however far above that rung the
            // panel is resting. Bracketed half a point either side of
            // `dismissAt` rather than asserted on it: the exact ">" edge is
            // pinned on clean numbers in
            // `testSettleDetentCommitsDownwardOnlyPastTheThreshold`, and
            // these coordinates carry measured decimals.
            XCTAssertEqual(
                settleFromFullPage(
                    projecting: -(geometry.dismissAt - 0.5),
                    drawer: geometry.drawer,
                    container: geometry.container
                ),
                .stay,
                "\(geometry.label): dismissed half a point short of \(geometry.dismissAt)"
            )
            XCTAssertEqual(
                settleFromFullPage(
                    projecting: -(geometry.dismissAt + 0.5),
                    drawer: geometry.drawer,
                    container: geometry.container
                ),
                .dismissed,
                "\(geometry.label): held half a point past \(geometry.dismissAt)"
            )
            XCTAssertEqual(
                settleFromFullPage(
                    projecting: -10_000,
                    drawer: geometry.drawer,
                    container: geometry.container
                ),
                .dismissed,
                geometry.label
            )
        }
    }

    func testSettleDetentClampsADrawerTallerThanItsHost() {
        // A measured drawer taller than its host (rotation, or a stale
        // measurement) must not become a detent above full page — the panel
        // would settle somewhere it cannot be laid out. Clamped, the gap is
        // zero, so full page drops out rather than inverting.
        XCTAssertEqual(settleFromDrawer(projecting: 0, drawer: 900, container: 800), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: 5000, drawer: 900, container: 800), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: -5000, drawer: 900, container: 800), .dismissed)
        // The panel rests 100pt above the rung the price is quoted against,
        // and the settle says so: dismissal costs the clamped 120 plus that
        // overhang. Documented at `travel` rather than corrected, because
        // the alternative is pricing a move against a height that is not on
        // the ladder the move lands on.
        XCTAssertEqual(settleFromDrawer(projecting: -220, drawer: 900, container: 800), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: -220.5, drawer: 900, container: 800), .dismissed)
    }

    func testSettleDetentOffersNoFullPageWhenTheDrawerFillsItsHost() {
        // `drawerHeight == containerHeight` is the shape that used to
        // collapse the ladder to [0, full, full], where a nudge in either
        // direction read as "go full page". There is no second full-page
        // rung now: the gap is 0, so the only places to be are here and
        // dismissed.
        XCTAssertEqual(settleFromDrawer(projecting: 10, drawer: 800, container: 800), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: 5000, drawer: 800, container: 800), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: -10, drawer: 800, container: 800), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: -5000, drawer: 800, container: 800), .dismissed)
    }

    func testSettleDetentLeavesNormalGeometryReachable() {
        // The reference device with the keyboard down, both stack states.
        // The far-end clamp makes full page cheaper than the old midpoint
        // (145 populated, 245 empty) — that is the clamp working, not a
        // dead zone opening.
        XCTAssertEqual(settleFromDrawer(projecting: 120, drawer: 488.33, container: 778), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: 121, drawer: 488.33, container: 778), .fullPage)
        XCTAssertEqual(settleFromDrawer(projecting: 120, drawer: 288, container: 778), .stay)
        XCTAssertEqual(settleFromDrawer(projecting: 121, drawer: 288, container: 778), .fullPage)
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

    func testDrawerHeightRecordsTheFirstMeasurementOfAFreshOpen() {
        // The J1 blocker, as one line. The panel reports its height before
        // the host's measurement has propagated, so the first — and, until
        // something else resizes the panel, only — measurement of an open
        // arrives with `containerHeight == 0`. Round 4 refused it through a
        // `height < containerHeight` term, `drawerHeight` stayed 0, and the
        // chrome gesture was dead on every fresh open on every device class
        // QA tried. Raising the keyboard revived it, which is what named
        // the mechanism.
        XCTAssertTrue(
            todoStackShouldRecordDrawerHeight(
                height: 488.33,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 0
            )
        )
    }

    func testDrawerHeightRecordsAHeightThatFillsItsHost() {
        // The case the deleted term was written for. Recording it is safe
        // because the settle owns the question the term was second-guessing:
        // a drawer at the container height leaves a gap of 0, so full page
        // is not a destination and the [0, full, full] collapse cannot
        // happen. Keeping a stale value instead was not "strictly better" —
        // on a fresh open the stale value is 0, the one number every
        // downstream reader refuses.
        XCTAssertTrue(
            todoStackShouldRecordDrawerHeight(
                height: 800,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 800
            )
        )
        XCTAssertEqual(
            todoStackSettleDetent(
                restHeight: 800,
                predictedEndTranslationY: -300,
                drawerHeight: 800,
                containerHeight: 800
            ),
            .stay
        )
        // Same for a height past the host, which clamps in the settle.
        XCTAssertTrue(
            todoStackShouldRecordDrawerHeight(
                height: 900,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 800
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
        // A zero-height frame would take `drawerHeight` to 0, and both
        // `chromeDragHeights` and `todoStackSettleDetent` refuse to work
        // from there — the chrome drag would go inert for the rest of the
        // open. No producer of one is known; this costs nothing to keep.
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

    func testDrawerHeightRecordsAnyPositiveLayoutWhateverItsSize() {
        // The gate has two terms and a size is not one of them. This
        // replaces a test that swept a descending sequence under a name
        // about a falsified ratchet but only ever restated
        // `height < containerHeight`: every height it tried was below the
        // host, so it would have passed the term that shipped the blocker.
        // Sweeping across the host is what makes it a test of the rule.
        for height in stride(from: CGFloat(1000), through: 20, by: -37) {
            XCTAssertTrue(
                todoStackShouldRecordDrawerHeight(
                    height: height,
                    isFullPage: false,
                    isChromeDragging: false,
                    containerHeight: 800
                ),
                "height \(height) was refused"
            )
        }
    }

    func testDrawerHeightRecordsAKeyboardCompressedLayout() {
        // Recording it is what keeps `restHeight` equal to where the panel
        // actually is, so the first frame of a chrome drag does not jump.
        // Safety comes from the settle instead: a drawer squeezed to within
        // one touch target of its host has no full page to be promoted to.
        XCTAssertTrue(
            todoStackShouldRecordDrawerHeight(
                height: 439.3,
                isFullPage: false,
                isChromeDragging: false,
                containerHeight: 477
            )
        )
        XCTAssertEqual(
            settleFromDrawer(projecting: 300, drawer: 439.3, container: 477),
            .stay
        )
    }
}

// MARK: - Device geometry fixture

/// One drawer geometry measured during the gh#128 device QA passes.
private struct TodoStackMeasuredGeometry {
    enum Provenance: String {
        /// Read off the device.
        case measured
        /// Read off the device, but the container is an approximation, so
        /// the reported gap need not exactly equal `container - drawer` on
        /// these rows.
        ///
        /// Treat the absolute heights on such a row as unreliable and not
        /// merely imprecise. The four SE rows carried this mark because the
        /// container was inferred by subtracting an assumed top inset from
        /// the screen height, and the assumed inset was wrong: 54pt against
        /// a real 20pt SE status bar, so every keyboard-down SE container
        /// read 613 where the device says 647 (667 - 20). The keyboard-up
        /// row is not one of those 613s — it reads 387 — so take a row's
        /// container from the table rather than from this arithmetic. The
        /// *gaps* survived the error, because the drawers were inferred the
        /// same way and were low by the same ~34pt, which is why nothing
        /// behavioural broke and why nothing in this file caught it for
        /// three rounds — an internally consistent row passes every
        /// arithmetic check here. Only re-measurement finds this class of
        /// error.
        case approximateContainer
    }

    let label: String
    /// The exact `xcrun simctl ui <device> content_size` value the row was
    /// measured at — `large` is the default, and the accessibility sizes
    /// are the AX1…AX5 ladder under their real names. Spelled out rather
    /// than written "AX3" because a fixture whose job is to fail on drift
    /// has to be re-measurable without guessing at a mapping: the round-4
    /// row labelled AX3 was 8.3pt off a later measurement at
    /// `accessibility-extra-large`, which is the sort of disagreement a
    /// name resolves and an abbreviation does not.
    ///
    /// Guarded by `testEveryRowNamesAContentSizeSimctlCanSet`, since this is
    /// the one field no arithmetic here would catch drifting.
    let contentSize: String
    let container: CGFloat
    /// The panel height recorded as the drawer detent in this layout.
    ///
    /// On the keyboard-up rows this is what the panel measured *under* the
    /// keyboard, which is the drawer of a panel that was at the drawer when
    /// the keyboard arrived. It is not what `drawerHeight` holds when the
    /// panel is at full page under the keyboard, and that distinction
    /// decides a real number: `todoStackShouldRecordDrawerHeight` refuses
    /// every measurement while `isFullPage`, so promoting with the keyboard
    /// down and then raising it freezes the keyboard-*down* drawer — 488.33
    /// on a 17 Pro — against a container of 477, i.e. drawer > host. See
    /// `testSettleDetentHoldsAFullPageTheLadderNoLongerOffers`, which
    /// carries that pairing and the boundary it moves.
    let drawer: CGFloat
    /// The gap as QA reported it, rounded. `container - drawer` is what the
    /// rule actually sees and what the expectations are computed from; this
    /// is carried so a transcription slip fails a build.
    let reportedGap: CGFloat
    let provenance: Provenance
    /// Whether the software keyboard was up.
    ///
    /// The implication runs one way only: every row that loses full page is
    /// a keyboard-up row, and the converse is false. `17 Pro portrait,
    /// empty, keyboard up` is 477/238 — a 239pt gap — and keeps full page.
    /// The keyboard shortens the host; whether that closes the gap depends
    /// on how much height the panel wanted, so this field separates "the
    /// affordance is intentionally absent" from "the affordance went
    /// missing" only together with the gap, never on its own.
    /// `testFullPageReachabilityOnEveryMeasuredGeometry` asserts the
    /// direction that holds, and nothing asserts the one that does not.
    let keyboardUp: Bool
    /// Whether full page is somewhere to go from the drawer at all.
    let fullPageReachable: Bool
    /// What a move up out of the drawer costs, nil where there is nothing
    /// above the drawer to buy.
    let upwardCommitTravel: CGFloat?
}

/// The device measurements, pinned so they fail a build rather than sitting
/// in a doc comment for a later round to read as a decision input. Five doc
/// comments in this slice turned out to be wrong and two of them shipped
/// defects; a table that runs cannot do that.
///
/// Provenance is marked per row and is not decoration. Only one row still
/// carries an approximated container — `SE 3rd gen portrait, 1 card,
/// keyboard up`, whose keyboard-up container nobody has read off a device.
/// The three keyboard-down SE rows were promoted to `.measured` in round 8
/// when QA measured the SE container directly; see the enum for the error
/// the approximation was making. The round-4 pass also produced AX3/AX5
/// figures for the 17 Pro — those were *derived* from the default-size
/// measurement rather than read on the device, so they are deliberately
/// absent.
///
/// Reported gaps are checked to ±1pt of `container - drawer`. That
/// tolerance used to have two causes and now has one: rounding in QA's own
/// reports. The wider cause, an approximated SE container that put the
/// default-type row 0.67pt out, is gone — all three re-measured SE rows now
/// agree exactly. What remains is `iPad Air 11in landscape, empty`
/// reporting 411.0 against 410.5 computed, its 1-card row 210.0 against
/// 210.17, and `17 Pro portrait, 1 card, keyboard up` reporting 37.67
/// against 37.7; the worst disagreement in the table is that 0.5.
///
/// So ±1pt is now roughly twice the observed worst case rather than tight
/// against it, and it is left there deliberately: tightening to 0.5 would
/// put an assertion exactly on the boundary of a real row, where the next
/// report that rounds the other way fails a build for no defect. Tighten it
/// only alongside gaps reported to more than one decimal place. Note also
/// what this check cannot do — it compares the row against itself, so it
/// catches a transcription slip and never catches the row disagreeing with
/// the device. The SE rows were internally consistent for three rounds
/// while being 34pt wrong.
final class TodoStackMeasuredGeometryTests: XCTestCase {

    // MARK: - Notes for whoever re-measures this table
    //
    // Two `idb` behaviours that cost the round-7 QA pass whole runs and
    // will cost the next one the same, recorded here because this is where
    // someone about to drive a device for these numbers will be looking.
    //
    //  - `idb ui swipe` requires *integer* coordinates. A float like
    //    `578.0` makes it exit rc=2 and print nothing, so the gesture
    //    simply never happens. Round 7 read that as a real result and
    //    reported "0/6 promoted" — a fabricated regression that took a
    //    rerun to disprove. Round the coordinates and check the exit code;
    //    a swipe that silently did not run looks exactly like a swipe the
    //    app ignored.
    //
    //  - Do not poll `describe-all` while a swipe is in flight. Running
    //    them concurrently corrupted a *later* swipe badly enough to
    //    dismiss the panel, 1 time in 5; with the polling removed the same
    //    sequence was 8/8 clean. Sample the hierarchy between gestures,
    //    never during one, or a flake gets attributed to the settle logic.

    private static let rows: [TodoStackMeasuredGeometry] = [
        .init(
            label: "17 Pro portrait, empty",
            contentSize: "large",
            container: 778.0, drawer: 288.0, reportedGap: 490.0,
            provenance: .measured, keyboardUp: false,
            fullPageReachable: true, upwardCommitTravel: 120
        ),
        .init(
            label: "17 Pro portrait, 1 card",
            contentSize: "large",
            container: 778.0, drawer: 488.33, reportedGap: 289.67,
            provenance: .measured, keyboardUp: false,
            fullPageReachable: true, upwardCommitTravel: 120
        ),
        .init(
            label: "17 Pro portrait, empty, keyboard up",
            contentSize: "large",
            container: 477.0, drawer: 238.0, reportedGap: 239.0,
            provenance: .measured, keyboardUp: true,
            fullPageReachable: true, upwardCommitTravel: 119.5
        ),
        .init(
            label: "17 Pro portrait, 1 card, keyboard up",
            contentSize: "large",
            container: 477.0, drawer: 439.3, reportedGap: 37.67,
            provenance: .measured, keyboardUp: true,
            fullPageReachable: false, upwardCommitTravel: nil
        ),
        // The three keyboard-down SE rows below were re-measured on device
        // in round 7, on an iPhone SE 3rd gen at each row's named content
        // size, and promoted from `.approximateContainer` to `.measured`.
        // The container is 647.0 — the SE's 667pt screen less its 20pt
        // status bar — where the approximation had assumed a 54pt inset and
        // said 613. Each drawer moved up by the same ~34pt, so every gap
        // is within 1pt of what these rows already claimed and no
        // reachability changed; the two prices that moved did so by tenths.
        // The promotion is what the tolerance discussion above turns on:
        // all three now satisfy `reportedGap == container - drawer` exactly.
        .init(
            label: "SE 3rd gen portrait, 1 card, default type",
            contentSize: "large",
            container: 647.0, drawer: 523.0, reportedGap: 124.0,
            provenance: .measured, keyboardUp: false,
            fullPageReachable: true, upwardCommitTravel: 62
        ),
        .init(
            // Re-measured twice. Round 5 corrected the round-4 row
            // (labelled only "AX3", 503.5 / 109.5) to the named content
            // size, 8.3pt away; round 7 confirmed that correction on device
            // at 101.0 of gap against the 101.17 recorded, and fixed the
            // container. The round-4 figure would have been ~8.5pt out.
            // Both the reason `contentSize` is a field rather than a word
            // in the label, and the reason this table gets re-measured.
            label: "SE 3rd gen portrait, 1 card, AX3",
            contentSize: "accessibility-extra-large",
            container: 647.0, drawer: 546.0, reportedGap: 101.0,
            provenance: .measured, keyboardUp: false,
            fullPageReachable: true, upwardCommitTravel: 50.5
        ),
        .init(
            // The row the floor is measured against, and the one the
            // correction mattered on: the gap is 86.5, not the 85.5 this
            // row claimed for three rounds. See
            // `testTheTightestKeyboardDownGapKeepsFullPageADestination`.
            label: "SE 3rd gen portrait, 1 card, AX5",
            contentSize: "accessibility-extra-extra-extra-large",
            container: 647.0, drawer: 560.5, reportedGap: 86.5,
            provenance: .measured, keyboardUp: false,
            fullPageReachable: true, upwardCommitTravel: 44
        ),
        .init(
            // Not re-measured: 387.0 is the keyboard-*up* container, which
            // round 7 had no reading for, so it keeps the provenance and
            // may still carry the 54pt-inset error the keyboard-down rows
            // shed. Nothing here depends on the absolute value — the drawer
            // fills the host, and a 0pt gap is a 0pt gap at any container.
            label: "SE 3rd gen portrait, 1 card, keyboard up",
            contentSize: "large",
            container: 387.0, drawer: 387.0, reportedGap: 0.0,
            provenance: .approximateContainer, keyboardUp: true,
            fullPageReachable: false, upwardCommitTravel: nil
        ),
        .init(
            label: "iPad Air 11in landscape, empty",
            contentSize: "large",
            container: 698.5, drawer: 288.0, reportedGap: 411.0,
            provenance: .measured, keyboardUp: false,
            fullPageReachable: true, upwardCommitTravel: 120
        ),
        .init(
            label: "iPad Air 11in landscape, 1 card",
            contentSize: "large",
            container: 698.5, drawer: 488.33, reportedGap: 210.0,
            provenance: .measured, keyboardUp: false,
            fullPageReachable: true, upwardCommitTravel: 105.085
        ),
        .init(
            label: "iPad Air 11in landscape, empty, keyboard up",
            contentSize: "large",
            container: 298.0, drawer: 288.0, reportedGap: 10.0,
            provenance: .measured, keyboardUp: true,
            fullPageReachable: false, upwardCommitTravel: nil
        )
    ]

    private func settle(
        _ row: TodoStackMeasuredGeometry,
        projecting travel: CGFloat
    ) -> TodoStackDetent? {
        todoStackSettleDetent(
            restHeight: row.drawer,
            predictedEndTranslationY: -travel,
            drawerHeight: row.drawer,
            containerHeight: row.container
        )
    }

    /// The same release, from a panel already at full page.
    private func settleFromFullPage(
        _ row: TodoStackMeasuredGeometry,
        projecting travel: CGFloat
    ) -> TodoStackDetent? {
        todoStackSettleDetent(
            restHeight: row.container,
            predictedEndTranslationY: -travel,
            drawerHeight: row.drawer,
            containerHeight: row.container
        )
    }

    private func describe(_ row: TodoStackMeasuredGeometry) -> String {
        "\(row.label) [\(row.provenance.rawValue), content_size \(row.contentSize)]"
    }

    /// Every value `xcrun simctl ui <device> content_size` will set — the
    /// seven standard sizes and the five extended-range ones, copied from
    /// the tool's own listing. `unknown` and `unsupported` also appear
    /// there, but only as things it can print, so they are not here.
    private static let settableContentSizes: Set<String> = [
        "extra-small",
        "small",
        "medium",
        "large",
        "extra-large",
        "extra-extra-large",
        "extra-extra-extra-large",
        "accessibility-medium",
        "accessibility-large",
        "accessibility-extra-large",
        "accessibility-extra-extra-large",
        "accessibility-extra-extra-extra-large"
    ]

    func testEveryRowNamesAContentSizeSimctlCanSet() {
        // `contentSize` is the only field with no arithmetic behind it, so
        // nothing else can catch it going stale: a re-measurement that
        // updates `container` / `drawer` / `reportedGap` and forgets the
        // size it was taken at passes every other test in this class, and
        // the row then documents a geometry nobody can reproduce. Two
        // cheap guards: the string has to be one the tool accepts, and the
        // two accessibility rows — whose whole reason for existing is the
        // size — are pinned by name.
        for row in Self.rows {
            XCTAssertTrue(
                Self.settableContentSizes.contains(row.contentSize),
                "\(describe(row)): `\(row.contentSize)` is not a size simctl can set"
            )
        }
        XCTAssertEqual(
            Self.rows.first { $0.label.hasSuffix("AX3") }?.contentSize,
            "accessibility-extra-large"
        )
        XCTAssertEqual(
            Self.rows.first { $0.label.hasSuffix("AX5") }?.contentSize,
            "accessibility-extra-extra-extra-large"
        )
    }

    func testReportedGapsMatchTheMeasuredHeights() {
        for row in Self.rows {
            XCTAssertEqual(
                row.reportedGap,
                row.container - row.drawer,
                accuracy: 1.0,
                describe(row)
            )
        }
    }

    func testFullPageReachabilityOnEveryMeasuredGeometry() {
        // The strongest flick available, so this is reachability and not a
        // question about price. Where full page is not a destination the
        // answer is `.stay` — the drawer is where the panel already is, and
        // the settle says so in those words.
        for row in Self.rows {
            XCTAssertEqual(
                settle(row, projecting: 10_000),
                row.fullPageReachable ? .fullPage : .stay,
                describe(row)
            )
        }
        // Every geometry that loses full page is a keyboard-up one — but
        // not every keyboard-up one loses it: the 17 Pro with an empty
        // stack keeps a 239pt gap under the keyboard. The keyboard is the
        // squeeze; the card count decides whether it is enough.
        for row in Self.rows where !row.fullPageReachable {
            XCTAssertTrue(row.keyboardUp, describe(row))
        }
    }

    func testAHeldFullPageSurvivesAReleaseOnEveryMeasuredGeometry() {
        // The round-5 blocker across the whole table: a panel sitting at
        // full page must not be demoted by a release that bought nothing —
        // least of all on the keyboard-up rows, where the ladder has no
        // full-page rung to name and round 5 therefore answered `.drawer`
        // to *every* release, upward ones included.
        for row in Self.rows {
            for travel in [CGFloat(0), 36, 2, -2, -10, -36] {
                XCTAssertEqual(
                    settleFromFullPage(row, projecting: travel),
                    .stay,
                    "\(describe(row)): a \(travel)pt projection moved a held full page"
                )
            }
        }
    }

    func testTheTightestKeyboardDownGapKeepsFullPageADestination() {
        // `todoStackMinimumCommitTravel` is load-bearing twice, and this is
        // the second role: below it, full page stops being a destination at
        // all. That is intended with the keyboard up — the panel would move
        // less than the shortest gesture that can ask for it — and it is a
        // silent capability loss anywhere else, which is what round 4
        // shipped by deleting the detent outright.
        //
        // The margin is not large and it is not theoretical: most of this
        // view's type is fixed-point `.system(size:)`, so Dynamic Type
        // barely moves the panel today. When that is fixed the panel grows,
        // every gap shrinks, and this row is the one that decides whether
        // AX5 users still have a full page. Re-measure then — at the named
        // content size — and let this fail rather than discovering it as a
        // missing affordance.
        let keyboardDown = Self.rows.filter { !$0.keyboardUp }
        guard let tightest = keyboardDown.min(by: {
            $0.container - $0.drawer < $1.container - $1.drawer
        }) else {
            return XCTFail("no keyboard-down rows")
        }
        XCTAssertEqual(tightest.label, "SE 3rd gen portrait, 1 card, AX5")
        XCTAssertEqual(tightest.contentSize, "accessibility-extra-extra-extra-large")
        for row in keyboardDown {
            XCTAssertGreaterThanOrEqual(
                row.container - row.drawer,
                todoStackMinimumCommitTravel,
                "\(describe(row)): full page has stopped being a destination with the keyboard down"
            )
        }
        // The margin itself, so a shrinking one is visible in the diff
        // rather than only at the cliff: 86.5 - 44.
        //
        // 42.5, not the 41.5 this asserted through round 7. The row was
        // 1pt out and this assertion faithfully pinned the wrong number —
        // which is the failure mode worth naming, because a fixture whose
        // whole job is to fail a build when reality drifts had drifted
        // itself, on the one row that guards the tightest gap. It was
        // harmless only by luck: 43.25 is still under the 44pt floor, so
        // the price stayed 44 and reachability never moved. Re-measure
        // before trusting it, not after.
        XCTAssertEqual(
            tightest.container - tightest.drawer - todoStackMinimumCommitTravel,
            42.5,
            accuracy: 0.01
        )
    }

    func testCommitPriceOnEveryMeasuredGeometry() {
        for row in Self.rows {
            guard let expected = row.upwardCommitTravel else {
                XCTAssertFalse(row.fullPageReachable, row.label)
                continue
            }
            XCTAssertEqual(
                todoStackCommitTravel(gap: row.container - row.drawer),
                expected,
                accuracy: 0.01,
                describe(row)
            )
            // And the price is what the settle actually charges. Bracketed
            // half a point either side rather than asserted on the boundary
            // itself: the exact ">= vs >" edge is pinned on clean numbers in
            // `testSettleDetentCommitsUpwardOnlyPastTheThreshold`, and these
            // rows carry float noise from measured decimals.
            XCTAssertEqual(settle(row, projecting: expected - 0.5), .stay, describe(row))
            XCTAssertEqual(settle(row, projecting: expected + 0.5), .fullPage, describe(row))
        }
    }

    func testDismissalStaysReachableOnEveryMeasuredGeometry() {
        // No configuration may trap the user in the drawer — including the
        // three where full page is not a destination, and including a panel
        // held at full page on one of those, which is the state a `.stay`
        // now preserves.
        for row in Self.rows {
            XCTAssertEqual(settle(row, projecting: -10_000), .dismissed, describe(row))
            XCTAssertEqual(
                settleFromFullPage(row, projecting: -10_000),
                .dismissed,
                describe(row)
            )
        }
    }
}
