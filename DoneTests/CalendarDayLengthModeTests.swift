//
//  CalendarDayLengthModeTests.swift
//  DoneTests
//
//  The day-length mode (gh#284 / #285 S1.5): the setting, the column height
//  in each mode, a block's unchanged fraction, and the constant canvas of
//  the normalized mode.
//

import XCTest
import UIKit
@testable import Done

final class CalendarDayLengthModeTests: XCTestCase {

    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> DayClock {
        CalendarZoneClock(calendar: newYork, usesActualDayLength: true)
            .day(containing: newYork.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!)
    }

    private var fallBack: DayClock { day(2026, 11, 1) }
    private var springForward: DayClock { day(2026, 3, 8) }
    private var plain: DayClock { day(2026, 11, 10) }

    // MARK: The setting (A9)

    func testTheDefaultIsActualAndAStoredValueIsReadTolerantly() {
        XCTAssertEqual(DayLengthMode.standard, .actual)
        XCTAssertEqual(DayLengthMode(stored: nil), .actual)
        XCTAssertEqual(DayLengthMode(stored: "normalized"), .normalized)
        XCTAssertEqual(DayLengthMode(stored: "actual"), .actual)
        XCTAssertEqual(DayLengthMode(stored: "something else"), .actual)
        XCTAssertEqual(DayLengthMode.allCases.map(\.rawValue), ["actual", "normalized"])

        let key = AppSettingsKeys.calendarDayLengthMode
        let before = UserDefaults.standard.object(forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(DayLengthMode.current, .actual)
        UserDefaults.standard.set("normalized", forKey: key)
        XCTAssertEqual(DayLengthMode.current, .normalized)
    }

    func testTheKeyIsResetWithTheRestAndStaysLocalUntilTheSyncProjectionMayGrow() {
        XCTAssertTrue(AppSettingsKeys.resettableUserDefaultsKeys.contains(AppSettingsKeys.calendarDayLengthMode))
        // The synced field set is pinned by `SyncProjectionSnapshotTests`
        // until the mixed-version write-back guard ships (survey L3); the
        // mode is a per-device setting until then.
        XCTAssertFalse(SyncedSettings.allKeys.contains(AppSettingsKeys.calendarDayLengthMode))
    }

    // MARK: Column height per mode (A8)

    func testAColumnIsItsDayLongInActualAndAStandardDayTallInNormalized() {
        let hourHeight: CGFloat = 56
        for (clock, hours) in [(fallBack, 25.0), (springForward, 23.0), (plain, 24.0)] {
            let actual = calendarColumnHourHeight(hourHeight, clock: clock, mode: .actual)
            let normalized = calendarColumnHourHeight(hourHeight, clock: clock, mode: .normalized)
            XCTAssertEqual(actual, hourHeight, "\(hours)h: actual keeps the hour height")
            XCTAssertEqual(normalized, hourHeight * 24 / hours, accuracy: 0.0001, "\(hours)h: normalized scales it")
            XCTAssertEqual(
                calendarTimelineContentHeight(clock: clock, hourHeight: actual), hours * hourHeight, accuracy: 0.001,
                "\(hours)h: actual column height"
            )
            XCTAssertEqual(
                calendarTimelineContentHeight(clock: clock, hourHeight: normalized), 24 * hourHeight, accuracy: 0.001,
                "\(hours)h: normalized column height is a standard day's"
            )
        }
        XCTAssertEqual(
            calendarColumnHourHeight(hourHeight, clock: DayClock.legacy24h(start: plain.start), mode: .normalized),
            hourHeight, "a legacy clock is standard and unscaled"
        )
    }

    func testABlockKeepsItsFractionInBothModesAndOnlyItsPixelHeightChanges() {
        // A9 09:00–10:00 EST on the fall-back day: ten hours in, one hour long.
        let start = Date(timeIntervalSince1970: 1_793_541_600)
        let fraction = calendarTimelineYFraction(for: start, clock: fallBack)
        XCTAssertEqual(fraction, 10.0 / 25.0, accuracy: 0.0001)
        let hourHeight: CGFloat = 56
        for mode in DayLengthMode.allCases {
            let columnHourHeight = calendarColumnHourHeight(hourHeight, clock: fallBack, mode: mode)
            let columnHeight = calendarTimelineContentHeight(clock: fallBack, hourHeight: columnHourHeight)
            let y = fraction * columnHeight
            let expected: CGFloat = mode == .actual ? 10 * hourHeight : 10 * hourHeight * 24 / 25
            XCTAssertEqual(y, expected, accuracy: 0.001, "\(mode): the block's Y")
            XCTAssertEqual(
                calendarTimelineDurationFraction(seconds: 3600, clock: fallBack) * columnHeight,
                columnHourHeight, accuracy: 0.001, "\(mode): one hour is one scaled hour tall"
            )
        }
    }

    func testTheDayLayerDrawsTheScaledColumnOnAllThreePaths() {
        // The host reads the column's hour height like any other; a
        // normalized 25h column lands its block at ten scaled hours.
        let range = Event.TimeRange(
            start: Date(timeIntervalSince1970: 1_793_541_600),
            end: Date(timeIntervalSince1970: 1_793_541_600 + 3600)
        )
        let id = UUID()
        let a9 = CalendarLayout.EventOccurrence(
            id: "A9-\(id.uuidString)",
            event: Event(id: id, title: "A9", timeRanges: [range], type: "Work"),
            range: range
        )
        func model(hourHeight: CGFloat) -> DayLayerHostView.Model {
            DayLayerHostView.Model(
                date: fallBack.start, dayClock: fallBack, canvasLength: fallBack.length,
                occurrences: [a9], contentWidth: 360, headerHeight: 16, hourHeight: hourHeight,
                eventHorizontalInset: 8, leadingExtendedHours: 0, trailingExtendedHours: 0,
                drawableLeadingHours: 0, drawableTrailingHours: 0, useImperativeDayLayerModel: false,
                showEventText: true, isWeekMode: false, isThreeDayMode: false, titleFontSizeSetting: 13,
                showTimeBelowTitle: true, multiTypeEnabled: false, nearFutureHorizonDays: 7,
                isPinchActive: false, frozenSlotMinutes: nil
            )
        }
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 400))
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))
        scroll.contentSize = host.bounds.size
        scroll.addSubview(host)

        let normalized56 = calendarColumnHourHeight(56, clock: fallBack, mode: .normalized)
        host.apply(model(hourHeight: normalized56))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugHitFrame(of: a9.id)?.minY ?? -1, 16 + 10 * normalized56 + 1.5, accuracy: 0.01, "render")

        let normalized80 = calendarColumnHourHeight(80, clock: fallBack, mode: .normalized)
        host.apply(model(hourHeight: normalized80))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugPaintCounts.repaintVertical, 1, "fixture: the cheap path drew the pinch frame")
        XCTAssertEqual(host.debugHitFrame(of: a9.id)?.minY ?? -1, 16 + 10 * normalized80 + 1.5, accuracy: 0.01, "repaintVertical")

        scroll.contentOffset = CGPoint(x: 0, y: 16 + 9 * normalized80)
        XCTAssertTrue(host.debugRunCullPass())
        XCTAssertEqual(host.debugHitFrame(of: a9.id)?.minY ?? -1, 16 + 10 * normalized80 + 1.5, accuracy: 0.01, "cullViewport")
        XCTAssertNotNil(host.debugPieceContainers(of: a9.id)[a9.id], "the block is on screen after the cull")
    }

    // MARK: The canvas (A7, A8)

    func testTheCanvasFollowsTheLongestDayInActualAndIsConstantInNormalized() {
        XCTAssertEqual(calendarTimelineCanvasLength(longestInReach: 25 * 3600, mode: .actual), 25 * 3600)
        XCTAssertEqual(calendarTimelineCanvasLength(longestInReach: 24 * 3600, mode: .actual), 24 * 3600)
        XCTAssertEqual(calendarTimelineCanvasLength(longestInReach: 25 * 3600, mode: .normalized), 24 * 3600)
        XCTAssertEqual(calendarTimelineCanvasLength(longestInReach: 23 * 3600, mode: .normalized), 24 * 3600)
    }

    // MARK: The single-day page's mappings (review round 3, F1 / F8)

    private let header: CGFloat = 16
    private var zone: CalendarZoneClock { CalendarZoneClock(calendar: newYork, usesActualDayLength: true) }
    private var nov1Noon: Date { newYork.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))! }
    private let bandBelow = TimelineBoundaryExtensionState(leadingHours: 0, trailingHours: 12, source: nil, anchorDayOffset: 0)

    /// The page's geometry: no window, anchored on the selected day.
    private func pageGeometry(
        _ clock: DayClock, mode: DayLengthMode, hourHeight: CGFloat = 56, longestInReach: TimeInterval? = nil
    ) -> CalendarTimelineGeometry {
        CalendarTimelineGeometry(
            window: nil, selectedDayClock: clock, longestInReach: longestInReach, hourHeight: hourHeight, mode: mode
        )
    }

    func testThePagesGeometryIsAnchoredOnTheSelectedDayAndScalesItsColumn() {
        for (clock, hours) in [(fallBack, 25.0), (springForward, 23.0), (plain, 24.0)] {
            let normalized = pageGeometry(clock, mode: .normalized)
            XCTAssertEqual(normalized.selectedColumnHourHeight, 56 * 24 / hours, accuracy: 0.0001, "\(hours)h: normalized scales the column")
            XCTAssertEqual(normalized.axisClock, clock, "\(hours)h: no window, so the selected day is the axis")
            XCTAssertEqual(
                normalized.nowLegendWindow,
                CalendarNowLegendWindow(day: clock, hourHeight: normalized.selectedColumnHourHeight),
                "\(hours)h: a single-day window on the selected day at its column's hour height"
            )
            XCTAssertEqual(normalized.canvasClock.length, 24 * 3600, accuracy: 0.001, "\(hours)h: a standard-day canvas")
            XCTAssertEqual(normalized.canvasClock.start, clock.start)

            let actual = pageGeometry(clock, mode: .actual, longestInReach: 25 * 3600)
            XCTAssertEqual(actual.selectedColumnHourHeight, 56, "\(hours)h: actual keeps the hour height")
            XCTAssertEqual(actual.canvasClock.length, 25 * 3600, accuracy: 0.001, "\(hours)h: the held canvas")
            XCTAssertEqual(actual.canvasClock.start, clock.start)
        }
        // The held canvas never shortens the selected day, and a day as
        // long as the canvas keeps its transition.
        XCTAssertEqual(pageGeometry(fallBack, mode: .actual, longestInReach: 24 * 3600).canvasClock, fallBack)
        XCTAssertEqual(pageGeometry(fallBack, mode: .actual, longestInReach: 25 * 3600).canvasClock, fallBack)
    }

    func testAStackCardDroppedOnTheLastDrawnHourLandsInThatHourInBothModes() {
        // The finger half way down the column's last drawn hour is 23:30
        // on the wall in both modes. In the normalized mode a special day's
        // column is scaled, so its last hour is not where the timeline's
        // own hour height puts it: mapped at that height the same finger
        // landed an hour away, which is what the page did.
        for (clock, hours) in [(fallBack, 25.0), (springForward, 23.0), (plain, 24.0)] {
            let lastHalfHour = clock.end.addingTimeInterval(-30 * 60)
            XCTAssertEqual(newYork.component(.hour, from: lastHalfHour), 23, "fixture")
            for mode in DayLengthMode.allCases {
                let geometry = pageGeometry(clock, mode: mode)
                let columnHourHeight = geometry.selectedColumnHourHeight
                let localY = header + CGFloat(hours - 0.5) * columnHourHeight
                XCTAssertEqual(
                    calendarTodoStackDropStart(localY: localY, headerHeight: header, geometry: geometry, bandState: .none),
                    lastHalfHour, "\(hours)h \(mode): the last half hour"
                )
                XCTAssertEqual(
                    calendarTodoStackDropStart(localY: header + 9.25 * columnHourHeight, headerHeight: header, geometry: geometry, bandState: .none),
                    clock.start.addingTimeInterval(9.25 * 3600), "\(hours)h \(mode): a quarter past the ninth hour"
                )
                XCTAssertNil(
                    calendarTodoStackDropStart(localY: header + CGFloat(hours) * columnHourHeight + 1, headerHeight: header, geometry: geometry, bandState: .none),
                    "\(hours)h \(mode): below the drawn column"
                )
                XCTAssertNil(calendarTodoStackDropStart(localY: header - 1, headerHeight: header, geometry: geometry, bandState: .none))
                // With the band below open the same spot is the band's.
                XCTAssertEqual(
                    calendarTodoStackDropStart(localY: header + CGFloat(hours + 0.5) * columnHourHeight, headerHeight: header, geometry: geometry, bandState: bandBelow),
                    clock.end.addingTimeInterval(30 * 60), "\(hours)h \(mode): half an hour into the band"
                )
            }
            // The unscaled reading of the normalized column: off by about an
            // hour on a special day, the same on a plain one.
            let normalized = pageGeometry(clock, mode: .normalized)
            let unscaled = calendarTimelineDateFromYPosition(
                header + CGFloat(hours - 0.5) * normalized.selectedColumnHourHeight,
                clock: clock, headerHeight: header, hourHeight: 56, snapMinutes: 15
            )
            if hours == 24 {
                XCTAssertEqual(unscaled, lastHalfHour)
            } else {
                XCTAssertEqual(abs(unscaled.timeIntervalSince(lastHalfHour)), 3600, accuracy: 15 * 60, "\(hours)h: the timeline's hour height misreads the finger by about an hour")
            }
        }
    }

    func testTheHeaderDateFollowsTheScaledColumnWithTheBandBelowOpen() {
        // Normalized Nov 1 with the band below open and the viewport's top
        // row half an hour into the band: the header names Nov 2, whose
        // row that is, in both modes. Read at the timeline's own hour
        // height the same offset was still Nov 1's last hour.
        let nov2 = fallBack.end
        for mode in DayLengthMode.allCases {
            let geometry = pageGeometry(fallBack, mode: mode, longestInReach: 25 * 3600)
            let scrollY = 25.5 * geometry.selectedColumnHourHeight
            let shown = calendarResolvedHeaderDisplayDate(
                selectedDayOffset: 0, rangeMode: .day, currentScrollY: scrollY, headerHeight: header,
                hourHeight: geometry.selectedColumnHourHeight, boundaryExtensionState: bandBelow,
                referenceDate: nov1Noon, calendar: newYork, zoneClock: zone
            )
            XCTAssertEqual(shown, nov2, "\(mode): the row at the top is Nov 2's")
            // The touch-driven variant: a move drag with the finger there.
            let frame = CGRect(x: 0, y: 100, width: 390, height: 2000)
            let dragged = calendarResolvedTouchDrivenHeaderDisplayDate(
                draggingEventID: UUID(), dragMode: .move,
                dragTouchPointGlobal: CGPoint(x: 200, y: frame.minY + header + scrollY),
                timelineFrameGlobal: frame, selectedDayOffset: 0, rangeMode: .day, headerHeight: header,
                hourHeight: geometry.selectedColumnHourHeight, boundaryExtensionState: bandBelow,
                referenceDate: nov1Noon, calendar: newYork, zoneClock: zone
            )
            XCTAssertEqual(dragged, nov2, "\(mode): the finger is over Nov 2's row")
        }
        let normalized = pageGeometry(fallBack, mode: .normalized)
        let unscaled = calendarResolvedHeaderDisplayDate(
            selectedDayOffset: 0, rangeMode: .day, currentScrollY: 25.5 * normalized.selectedColumnHourHeight, headerHeight: header,
            hourHeight: 56, boundaryExtensionState: bandBelow, referenceDate: nov1Noon, calendar: newYork, zoneClock: zone
        )
        XCTAssertEqual(unscaled, fallBack.start, "the timeline's hour height still names Nov 1 with Nov 2's first row at the top")
    }

    func testTheBandsAreJudgedWhereTheScaledColumnDrawsThem() {
        // Normalized Nov 1, band below open, the viewport's bottom just
        // past the band's top (twenty-five scaled hours down): the band is
        // on screen and must not close. Judged at the timeline's own hour
        // height its top would be an hour lower — out of view, and the
        // band closed under the user (the gh#279 class).
        let viewport: CGFloat = 600
        for mode in DayLengthMode.allCases {
            let geometry = pageGeometry(fallBack, mode: mode, longestInReach: 25 * 3600)
            let bandTop = header + 25 * geometry.selectedColumnHourHeight
            func visible(viewportBottomAt y: CGFloat) -> Bool {
                calendarTimelineBoundaryExtensionVisibility(
                    geometry: geometry, currentOffsetY: y - viewport, viewportHeight: viewport,
                    contentTopInset: 0, allDayHeight: 0, headerHeight: header, state: bandBelow
                ).trailingVisible
            }
            XCTAssertTrue(visible(viewportBottomAt: bandTop + 10), "\(mode): ten points of the band are on screen")
            XCTAssertFalse(visible(viewportBottomAt: bandTop - 1), "\(mode): a point short of the band, none of it is")
        }
        let normalized = pageGeometry(fallBack, mode: .normalized)
        let scaledTop = header + 25 * normalized.selectedColumnHourHeight
        XCTAssertFalse(
            calendarTimelineBoundaryExtensionVisibility(
                clock: fallBack, currentOffsetY: scaledTop + 10 - viewport, viewportHeight: viewport,
                contentTopInset: 0, allDayHeight: 0, headerHeight: header, hourHeight: 56, state: bandBelow
            ).trailingVisible,
            "the timeline's hour height calls the band on screen out of view"
        )

        // Whether a scroll can take the band off screen: with a viewport a
        // little taller than the scaled column, the band's top is on screen
        // at the top of the scroll, so it cannot leave; the unscaled
        // reading, an hour taller, says it can, and would close it.
        let tall = scaledTop + 20
        func canLeave(_ geometry: CalendarTimelineGeometry) -> Bool {
            calendarTimelineBoundaryExtensionCanLeaveView(
                geometry: geometry, contentHeight: 3000, viewportHeight: tall,
                contentTopInset: 0, allDayHeight: 0, headerHeight: header, state: bandBelow
            ).trailing
        }
        XCTAssertFalse(canLeave(normalized))
        XCTAssertTrue(
            calendarTimelineBoundaryExtensionCanLeaveView(
                clock: fallBack, contentHeight: 3000, viewportHeight: tall,
                contentTopInset: 0, allDayHeight: 0, headerHeight: header, hourHeight: 56, state: bandBelow
            ).trailing,
            "the timeline's hour height says it can"
        )
        XCTAssertTrue(canLeave(pageGeometry(fallBack, mode: .actual, longestInReach: 25 * 3600)), "actual: the column is that tall, so it can")
    }

    func testTheAbandonedFadeReadsTheBandWhereTheScaledColumnDrawsIt() {
        // Normalized Nov 1, band below open, an event parked two hours into
        // the band so the finger-driven dim is off; the viewport's bottom
        // half way down the band's drawn height puts the position fade at
        // one half. Read at the timeline's own hour height the band would
        // start an hour lower and the fade would differ.
        let viewport: CGFloat = 600
        let parked = Event.TimeRange(start: fallBack.end.addingTimeInterval(2 * 3600), end: fallBack.end.addingTimeInterval(3 * 3600))
        let intent = TimelineBoundaryExtensionState(leadingHours: 0, trailingHours: 0, source: .moveDrag, anchorDayOffset: 0)
        func trailingFade(hourHeight: CGFloat, scrollY: CGFloat) -> CGFloat {
            computeAbandonedFadeCurves(AbandonedFadeInputs(
                rawState: intent, appliedState: bandBelow, dragOriginalRange: parked, dragOffsetY: 0,
                hourHeight: hourHeight, extensionOriginY: header, scrollY: scrollY, viewportHeight: viewport, dayClock: fallBack
            )).trailing ?? -1
        }
        for mode in DayLengthMode.allCases {
            let geometry = pageGeometry(fallBack, mode: mode, longestInReach: 25 * 3600)
            let columnHourHeight = geometry.selectedColumnHourHeight
            let halfWayDownTheBand = header + 25 * columnHourHeight + 6 * columnHourHeight
            XCTAssertEqual(trailingFade(hourHeight: columnHourHeight, scrollY: halfWayDownTheBand - viewport), 0.5, accuracy: 0.001, "\(mode)")
        }
        let normalized = pageGeometry(fallBack, mode: .normalized)
        let halfWay = header + 31 * normalized.selectedColumnHourHeight
        XCTAssertNotEqual(trailingFade(hourHeight: 56, scrollY: halfWay - viewport), 0.5, "the timeline's hour height reads another fade")
        XCTAssertEqual(trailingFade(hourHeight: 56, scrollY: halfWay - viewport), 1 - (halfWay - (header + 25 * 56)) / (12 * 56), accuracy: 0.001)
    }
}
