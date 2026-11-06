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
}
