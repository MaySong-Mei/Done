//
//  MacScrollHostTests.swift
//  DoneMacTests
//
//  B4: the timeline's NSScrollView host carries no arithmetic of its own —
//  the offset math lives in the pure `TimelineScrollController.scrollTargetY`
//  so it's testable without the AppKit view. (The host plumbing itself is
//  verified by build + the review reading the flipped-coord/constraint code.)
//

import XCTest
@testable import Done

@MainActor
final class MacScrollHostTests: XCTestCase {

    func testScrollTargetCentersFractionAndClamps() {
        let content: CGFloat = 1000, visible: CGFloat = 400
        // 0.5 → 0.5*1000 − 200 = 300, inside [0, 600].
        XCTAssertEqual(TimelineScrollController.scrollTargetY(
            fraction: 0.5, contentHeight: content, visibleHeight: visible), 300, accuracy: 0.001)
        // Top clamps to 0 (would be −200).
        XCTAssertEqual(TimelineScrollController.scrollTargetY(
            fraction: 0.0, contentHeight: content, visibleHeight: visible), 0, accuracy: 0.001)
        // Bottom clamps to contentHeight − visible = 600 (would be 800).
        XCTAssertEqual(TimelineScrollController.scrollTargetY(
            fraction: 1.0, contentHeight: content, visibleHeight: visible), 600, accuracy: 0.001)
    }

    func testScrollTargetIsZeroWhenEverythingFits() {
        // A viewport taller than the content never scrolls.
        XCTAssertEqual(TimelineScrollController.scrollTargetY(
            fraction: 0.5, contentHeight: 300, visibleHeight: 500), 0)
    }

    func testScrollTargetRealisticNowAnchor() {
        // 8am on a 1344pt day (56pt/hr) in a 700pt viewport: 8/24 * 1344 − 350
        // = 448 − 350 = 98, inside range → opens near the working morning.
        XCTAssertEqual(TimelineScrollController.scrollTargetY(
            fraction: 8.0 / 24.0, contentHeight: 56 * 24, visibleHeight: 700), 98, accuracy: 0.5)
    }

    // MARK: - B1 zoom

    func testZoomHeightClamps() {
        XCTAssertEqual(CalendarCanvasView.clampedHourHeight(56), 56, "in-range height untouched")
        XCTAssertEqual(CalendarCanvasView.clampedHourHeight(5), CalendarCanvasView.minHourHeight,
                       "too-small clamps to the minimum")
        XCTAssertEqual(CalendarCanvasView.clampedHourHeight(1000), CalendarCanvasView.maxHourHeight,
                       "too-large clamps to the maximum")
    }

    /// B1 focal anchor: the offset `scrollTargetY` returns for a fraction puts
    /// exactly that fraction at the viewport center — so re-centering on the
    /// captured center-fraction after a zoom holds the focal TIME fixed
    /// (whenever the target is inside the scrollable range).
    func testFocalFractionIsCenteredByScrollTarget() {
        let content: CGFloat = 2000, visible: CGFloat = 400
        for f in [0.25, 0.4, 0.6, 0.75] as [CGFloat] {
            let y = TimelineScrollController.scrollTargetY(
                fraction: f, contentHeight: content, visibleHeight: visible)
            XCTAssertEqual((y + visible / 2) / content, f, accuracy: 0.0001,
                           "fraction \(f) sits at the viewport center after re-centering")
        }
    }
}
