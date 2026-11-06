//
//  CalendarDSTTimelineTests.swift
//  DoneTests
//
//  The timeline on a day whose clock skips or repeats an hour (gh#284 / #285):
//  the label rows, the three render paths, the follow-day shift and the
//  tail of a shorter day.
//

import XCTest
import UIKit
@testable import Done

final class CalendarDSTTimelineTests: XCTestCase {

    private var newYork: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private var zone: CalendarZoneClock { CalendarZoneClock(calendar: newYork, usesActualDayLength: true) }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> DayClock {
        zone.day(containing: newYork.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!)
    }

    /// The 25h fall-back day, 2026-11-01.
    private var fallBack: DayClock { day(2026, 11, 1) }
    /// The 23h spring-forward day, 2026-03-08.
    private var springForward: DayClock { day(2026, 3, 8) }

    private func labels(
        clock: DayClock, slotMinutes: Int = 60, leading: Int = 0, trailing: Int = 0, is24: Bool = true
    ) -> [CalendarAxisHourLabel?] {
        let slotCount = calendarTimelineVisibleMinutes(
            clock: clock, leadingExtendedHours: leading, trailingExtendedHours: trailing
        ) / slotMinutes + 1
        return (0..<slotCount).map { index in
            TimeAxisLayerView.labelText(
                forSlot: index, slotMinutes: slotMinutes, leadingExtendedHours: leading,
                clock: clock, zoneClock: zone, is24: is24
            )
        }
    }

    // MARK: Label rows (A1, A2)

    func testFallBackDayHasTwentySixLabelRowsWithTheRepeatedHourZoned() {
        let rows = labels(clock: fallBack)
        XCTAssertEqual(rows.count, 26)
        XCTAssertEqual(
            rows.map { $0?.text },
            ["0:00", "1:00", "1:00"] + (2...23).map { "\($0):00" } + ["0:00"]
        )
        XCTAssertEqual(rows[1]?.zoneAbbreviation, "EDT")
        XCTAssertEqual(rows[2]?.zoneAbbreviation, "EST")
        XCTAssertEqual(rows.compactMap { $0?.zoneAbbreviation }.count, 2, "only the repeated hour carries the zone")
    }

    func testFallBackDayTwelveHourLabelsRepeatOneAmWithTheZone() {
        let rows = labels(clock: fallBack, is24: false)
        XCTAssertEqual(rows[1]?.text, "1 am")
        XCTAssertEqual(rows[2]?.text, "1 am")
        XCTAssertEqual(rows[1]?.zoneAbbreviation, "EDT")
        XCTAssertEqual(rows[2]?.zoneAbbreviation, "EST")
        XCTAssertEqual(rows[10]?.text, "9 am", "09:00 EST sits on the tenth row")
    }

    func testSpringForwardDayHasTwentyFourLabelRowsWithoutTwo() {
        let rows = labels(clock: springForward)
        XCTAssertEqual(rows.count, 24)
        XCTAssertEqual(
            rows.map { $0?.text },
            ["0:00", "1:00"] + (3...23).map { "\($0):00" } + ["0:00"]
        )
        XCTAssertTrue(rows.allSatisfy { $0?.zoneAbbreviation == nil })
    }

    func testAPlainDayHasTwentyFiveLabelRowsAsBefore() {
        let rows = labels(clock: day(2026, 11, 2))
        XCTAssertEqual(rows.count, 25)
        XCTAssertEqual(rows.map { $0?.text }, (0...23).map { "\($0):00" } + ["0:00"])
    }

    func testHalfHourSlotsAreUnlabelledOnTheFallBackDay() {
        let rows = labels(clock: fallBack, slotMinutes: 30)
        XCTAssertEqual(rows.count, 51)
        for (index, row) in rows.enumerated() {
            if index % 2 == 0 {
                XCTAssertNotNil(row, "slot \(index)")
            } else {
                XCTAssertNil(row, "slot \(index)")
            }
        }
        XCTAssertEqual(rows[2]?.text, "1:00")
        XCTAssertEqual(rows[4]?.text, "1:00")
        XCTAssertEqual(rows[2]?.zoneAbbreviation, "EDT")
        XCTAssertEqual(rows[4]?.zoneAbbreviation, "EST")
    }

    func testTheBandBelowAPlainDayLabelsTheNextDaysRepeatedHour() {
        // Oct 31 with the band below open shows the first twelve hours of
        // Nov 1, repeated hour included, marked by Nov 1's own clock.
        let rows = labels(clock: day(2026, 10, 31), trailing: 12)
        XCTAssertEqual(rows.count, 37)
        XCTAssertEqual(rows[24]?.text, "0:00")
        XCTAssertEqual(rows[25]?.text, "1:00")
        XCTAssertEqual(rows[26]?.text, "1:00")
        XCTAssertEqual(rows[25]?.zoneAbbreviation, "EDT")
        XCTAssertEqual(rows[26]?.zoneAbbreviation, "EST")
        XCTAssertEqual(rows[36]?.text, "11:00")
    }

    func testTheBandAboveTheFallBackDayLabelsThePreviousDaysHours() {
        let rows = labels(clock: fallBack, leading: 12)
        XCTAssertEqual(rows.count, 38)
        XCTAssertEqual(rows[0]?.text, "12:00")
        XCTAssertEqual(rows[11]?.text, "23:00")
        XCTAssertEqual(rows[12]?.text, "0:00")
        XCTAssertEqual(rows[13]?.text, "1:00")
        XCTAssertEqual(rows[13]?.zoneAbbreviation, "EDT")
    }

    func testTheSwiftUIAxisReadsTheSameLabelsAsTheLayerAxis() {
        let swiftUI = TimeAxisLabels(
            clock: fallBack, zoneClock: zone, headerHeight: 14, hourHeight: 56,
            slotMinutes: 60, leadingExtendedHours: 0, trailingExtendedHours: 0, mode: .preview
        )
        let layer = labels(clock: fallBack)
        for index in 0..<26 {
            XCTAssertEqual(swiftUI.label(forSlot: index, is24: true), layer[index]?.text ?? "", "slot \(index)")
            XCTAssertEqual(swiftUI.zoneLabel(forSlot: index, is24: true), layer[index]?.zoneAbbreviation, "slot \(index)")
        }
    }

    // MARK: The legend's collision measure

    func testTheLegendMeasuresElapsedMinutesNotTheWallClock() {
        // 09:00 EST on the fall-back day is ten hours after the day's start;
        // the wall clock says nine. The hour label it may collide with is
        // the one on the tenth row.
        let nineEST = Date(timeIntervalSince1970: 1_793_541_600)
        XCTAssertEqual(calendarTimelineElapsedMinutes(of: nineEST, clock: fallBack), 600, accuracy: 0.001)
        XCTAssertEqual(
            calendarTimelineElapsedMinutes(of: nineEST, clock: fallBack, leadingExtendedHours: 12),
            600 + 720, accuracy: 0.001
        )
        XCTAssertTrue(calendarShouldHideLegendHourLabel(
            legendTotalMinutes: 600, nowTotalMinutes: 600, hourHeight: 56
        ))
        XCTAssertFalse(calendarShouldHideLegendHourLabel(
            legendTotalMinutes: 540, nowTotalMinutes: 600, hourHeight: 56
        ))
    }

    // MARK: The three render paths read one clock (A1, A3)

    private func occurrence(_ title: String, epoch: TimeInterval, seconds: TimeInterval) -> CalendarLayout.EventOccurrence {
        let range = Event.TimeRange(
            start: Date(timeIntervalSince1970: epoch),
            end: Date(timeIntervalSince1970: epoch + seconds)
        )
        let id = UUID()
        return CalendarLayout.EventOccurrence(
            id: "\(title)-\(id.uuidString)",
            event: Event(id: id, title: title, timeRanges: [range], type: "Work"),
            range: range
        )
    }

    private func model(
        _ occurrences: [CalendarLayout.EventOccurrence], clock: DayClock, hourHeight: CGFloat
    ) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: clock.start,
            dayClock: clock,
            occurrences: occurrences,
            contentWidth: 360,
            headerHeight: 16,
            hourHeight: hourHeight,
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

    func testRenderRepaintAndCullPlaceTheFallBackDaysBlocksByElapsedTime() {
        // A9 09:00–10:00 EST, B1 01:15–01:45 EDT, C1 01:15–01:45 EST.
        let a9 = occurrence("A9", epoch: 1_793_541_600, seconds: 3600)
        let b1 = occurrence("B1", epoch: 1_793_510_100, seconds: 1800)
        let c1 = occurrence("C1", epoch: 1_793_513_700, seconds: 1800)
        let all = [a9, b1, c1]
        let header: CGFloat = 16

        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 360, height: 400))
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))
        scroll.contentSize = host.bounds.size
        scroll.addSubview(host)

        func expectBlocks(hourHeight hh: CGFloat, path: String, onScreen: [CalendarLayout.EventOccurrence]) {
            // Elapsed hours since 00:00 EDT: A9 ten, B1 one and a quarter, C1
            // two and a quarter — C1 is one hour below B1 although both read
            // 01:15 on the wall. Every block has a hit frame on every path;
            // only the blocks the viewport shows have layers (the cull builds
            // subtrees for the visible set alone), so the layer check is
            // asked of those.
            let expected: [(CalendarLayout.EventOccurrence, CGFloat)] = [(a9, 10), (b1, 1.25), (c1, 2.25)]
            for (occ, hours) in expected {
                let hit = host.debugHitFrame(of: occ.id)
                XCTAssertNotNil(hit, "\(path): \(occ.event.title) has a frame")
                XCTAssertEqual(hit?.minY ?? -1, header + hours * hh + 1.5, accuracy: 0.01, "\(path): \(occ.event.title)")
                guard onScreen.contains(where: { $0.id == occ.id }) else { continue }
                let container = host.debugPieceContainers(of: occ.id)[occ.id]
                XCTAssertNotNil(container, "\(path): \(occ.event.title) is drawn")
                XCTAssertEqual(container?.frame.minY ?? -1, header + hours * hh + 1.5, accuracy: 0.01, "\(path): \(occ.event.title) layer")
            }
            XCTAssertEqual(
                (host.debugHitFrame(of: c1.id)?.minY ?? 0) - (host.debugHitFrame(of: b1.id)?.minY ?? 0),
                hh, accuracy: 0.01, "\(path): the second 01:15 sits one hour below the first"
            )
        }

        // Full render.
        host.apply(model(all, clock: fallBack, hourHeight: 56))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugPaintCounts.render, 1, "fixture: the full render drew it")
        expectBlocks(hourHeight: 56, path: "render", onScreen: [b1, c1])

        // Cheap vertical repaint (a pinch frame).
        host.apply(model(all, clock: fallBack, hourHeight: 80))
        host.layoutIfNeeded()
        XCTAssertEqual(host.debugPaintCounts.render, 1, "fixture: no full render")
        XCTAssertEqual(host.debugPaintCounts.repaintVertical, 1, "fixture: the cheap path drew it")
        expectBlocks(hourHeight: 80, path: "repaintVertical", onScreen: [b1, c1])

        // Viewport cull after a scroll.
        scroll.contentOffset = CGPoint(x: 0, y: header + 9 * 80)
        let culls = host.debugPaintCounts.cull
        XCTAssertTrue(host.debugRunCullPass())
        XCTAssertEqual(host.debugPaintCounts.cull, culls + 1, "fixture: the cull ran")
        XCTAssertEqual(host.debugPaintCounts.render, 1, "fixture: no full render")
        expectBlocks(hourHeight: 80, path: "cullViewport", onScreen: [a9])
    }

    // MARK: The follow-day shift across a DST day

    func testFollowingForwardAcrossTheFallBackDayMirrorsTwentyFiveHoursAbove() {
        // From Nov 1 (25h) forward to Nov 2: the whole of Nov 1 becomes the
        // band above Nov 2, so the band is 25h; the window's start does not
        // move, and the settle puts Nov 2's 00:00 at the top, 25h down.
        let mirror = calendarFollowDayMirror(
            oldDayClock: fallBack, newDayClock: day(2026, 11, 2), dayDelta: 1,
            currentLeadingHours: 0, hourHeight: 56, newHostDayOffset: 1
        )
        XCTAssertEqual(mirror.mirroredExtension.leadingHours, 25)
        XCTAssertEqual(mirror.mirroredExtension.trailingHours, 0)
        XCTAssertEqual(mirror.mirroredExtension.anchorDayOffset, 1)
        XCTAssertEqual(mirror.scrollDelta, 0, accuracy: 0.001)
        XCTAssertEqual(mirror.settleOffset, 25 * 56, accuracy: 0.001)
    }

    func testFollowingBackwardOntoTheFallBackDayMovesByItsLengthLessTheBand() {
        // From Nov 2 (24h, band above open) back to Nov 1 (25h): the whole
        // of Nov 2 becomes the band below Nov 1, 24h; the window's start
        // moves from (Nov 2 − 12h) to Nov 1's start, i.e. 25h − 12h.
        let mirror = calendarFollowDayMirror(
            oldDayClock: day(2026, 11, 2), newDayClock: fallBack, dayDelta: -1,
            currentLeadingHours: 12, hourHeight: 56, newHostDayOffset: 0
        )
        XCTAssertEqual(mirror.mirroredExtension.leadingHours, 0)
        XCTAssertEqual(mirror.mirroredExtension.trailingHours, 24)
        XCTAssertEqual(mirror.scrollDelta, (25 - 12) * 56, accuracy: 0.001)
        XCTAssertEqual(mirror.settleOffset, 0, accuracy: 0.001)
    }

    func testFollowingAcrossTheSpringForwardDayUsesTwentyThreeHours() {
        let forward = calendarFollowDayMirror(
            oldDayClock: springForward, newDayClock: day(2026, 3, 9), dayDelta: 1,
            currentLeadingHours: 0, hourHeight: 40, newHostDayOffset: 1
        )
        XCTAssertEqual(forward.mirroredExtension.leadingHours, 23)
        XCTAssertEqual(forward.scrollDelta, 0, accuracy: 0.001)
        XCTAssertEqual(forward.settleOffset, 23 * 40, accuracy: 0.001)
        let backward = calendarFollowDayMirror(
            oldDayClock: day(2026, 3, 9), newDayClock: springForward, dayDelta: -1,
            currentLeadingHours: 12, hourHeight: 40, newHostDayOffset: 0
        )
        XCTAssertEqual(backward.mirroredExtension.trailingHours, 24)
        XCTAssertEqual(backward.scrollDelta, (23 - 12) * 40, accuracy: 0.001)
    }

    func testFollowingBetweenPlainDaysIsTheOldTwentyFourHourMaths() {
        // Control: on plain days the mirror is 24h, forward moves nothing
        // and backward moves by the band above — what the page did before.
        let forward = calendarFollowDayMirror(
            oldDayClock: day(2026, 11, 3), newDayClock: day(2026, 11, 4), dayDelta: 1,
            currentLeadingHours: 0, hourHeight: 56, newHostDayOffset: 1
        )
        XCTAssertEqual(forward.mirroredExtension.leadingHours, 24)
        XCTAssertEqual(forward.scrollDelta, 0, accuracy: 0.001)
        XCTAssertEqual(forward.settleOffset, 24 * 56, accuracy: 0.001)
        let backward = calendarFollowDayMirror(
            oldDayClock: day(2026, 11, 4), newDayClock: day(2026, 11, 3), dayDelta: -1,
            currentLeadingHours: 12, hourHeight: 56, newHostDayOffset: -1
        )
        XCTAssertEqual(backward.mirroredExtension.trailingHours, 24)
        XCTAssertEqual(backward.scrollDelta, 12 * 56, accuracy: 0.001)
    }

    // MARK: Tap and drop: the gap and the tail (A14, A15)

    func testNoSlotOfTheSpringForwardDayMapsIntoTheMissingHour() {
        // Every Y in the 23h column maps to an instant the day really has;
        // the skipped 02:00–03:00 EST is not on screen at all.
        let header: CGFloat = 16, hh: CGFloat = 56
        let missing = springForward.missingRange!
        // The column's own pixels: its exact bottom edge is the next day's
        // first instant, so the loop stops short of it.
        var y = header
        while y < header + 23 * hh {
            let instant = calendarTimelineDateFromYPosition(
                y, clock: springForward, headerHeight: header, hourHeight: hh, snapMinutes: 1
            )
            XCTAssertTrue(springForward.contains(instant), "y \(y)")
            // The missing range is expressed under the pre-jump offset; an
            // instant the day has never lands in it.
            XCTAssertFalse(missing.contains(instant) && newYork.component(.hour, from: instant) == 2, "y \(y)")
            y += hh / 4
        }
        // The rows either side of the jump: 01:00 EST then 03:00 EDT.
        let before = calendarTimelineDateFromYPosition(header + 1 * hh, clock: springForward, headerHeight: header, hourHeight: hh, snapMinutes: 1)
        let after = calendarTimelineDateFromYPosition(header + 2 * hh, clock: springForward, headerHeight: header, hourHeight: hh, snapMinutes: 1)
        XCTAssertEqual(newYork.component(.hour, from: before), 1)
        XCTAssertEqual(newYork.component(.hour, from: after), 3)
    }

    func testTheSecondOneOClockRowMapsToEasternStandardTime() {
        // A15: a tap on the third row of Nov 1 (two hours in) is 01:00 EST,
        // not 01:00 EDT; the second row is 01:00 EDT.
        let header: CGFloat = 16, hh: CGFloat = 56
        let secondRow = calendarTimelineDateFromYPosition(header + 1 * hh, clock: fallBack, headerHeight: header, hourHeight: hh)
        let thirdRow = calendarTimelineDateFromYPosition(header + 2 * hh, clock: fallBack, headerHeight: header, hourHeight: hh)
        XCTAssertEqual(secondRow.timeIntervalSince1970, 1_793_509_200, "01:00 EDT")
        XCTAssertEqual(thirdRow.timeIntervalSince1970, 1_793_512_800, "01:00 EST")
        XCTAssertEqual(fallBack.repeatedPass(of: thirdRow), 2)
        XCTAssertEqual(newYork.timeZone.secondsFromGMT(for: thirdRow), -5 * 3600)
    }

    func testTheTailBelowAShorterDayIsNotThisDay() {
        // Nov 2 (24h) drawn on a 25h canvas: the hour below its end maps to
        // Nov 3 and is refused; a plain day's own last hour is accepted.
        let plain = day(2026, 11, 2)
        let header: CGFloat = 16, hh: CGFloat = 56
        func instant(at y: CGFloat) -> Date {
            calendarTimelineDateFromYPosition(
                y, clock: plain, headerHeight: header, hourHeight: hh, snapMinutes: 1, clampToExtension: false
            )
        }
        XCTAssertTrue(calendarTimelineColumnAccepts(instant: instant(at: header + 23.5 * hh), clock: plain))
        XCTAssertFalse(calendarTimelineColumnAccepts(instant: instant(at: header + 24.5 * hh), clock: plain))
        XCTAssertFalse(calendarTimelineColumnAccepts(instant: instant(at: header - hh), clock: plain), "above the day with no band above")
        // With the band below open, the same stretch is the band's and takes a touch.
        XCTAssertTrue(calendarTimelineColumnAccepts(
            instant: instant(at: header + 24.5 * hh), clock: plain, trailingExtendedHours: 12
        ))
    }

    func testTheHostRefusesATouchInTheTailAndKeepsAWholeColumn() {
        let plain = day(2026, 11, 2)
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 3000))
        var model = self.model([], clock: plain, hourHeight: 56)
        model.canvasLength = 25 * 3600
        host.apply(model)
        host.layoutIfNeeded()
        XCTAssertTrue(host.acceptsTouch(atY: 16 + 23.5 * 56))
        XCTAssertFalse(host.acceptsTouch(atY: 16 + 24.5 * 56), "the tail is not this day")
        // Control: the same column sized to itself accepts its whole height
        // and the bottom inset below it, as it always did.
        model.canvasLength = plain.length
        host.apply(model)
        host.layoutIfNeeded()
        XCTAssertTrue(host.acceptsTouch(atY: 16 + 24.5 * 56))
    }

    // MARK: The edit path keeps the second 01:15 (A12)

    private let firstOneFifteen = Date(timeIntervalSince1970: 1_793_510_100)   // 01:15 EDT
    private let secondOneFifteen = Date(timeIntervalSince1970: 1_793_513_700)  // 01:15 EST

    func testAnOriginalOffTheDaysSecondPassTakesTheFirstPassWhateverItsOffset() {
        // Two daily 01:15 series, one seeded in December (EST) and one in
        // July (EDT): on the fall-back day both land on the first 01:15.
        // Sharing the post-fall-back offset is not being on this day's
        // second pass — only an instant on it keeps it (review round 3, F3).
        let ny = newYork
        let nov1 = ny.startOfDay(for: ny.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!)
        let december = ny.date(from: DateComponents(year: 2025, month: 12, day: 10, hour: 1, minute: 15))!
        let july = ny.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 1, minute: 15))!
        XCTAssertEqual(ny.timeZone.secondsFromGMT(for: december), -5 * 3600, "fixture: standard time")
        XCTAssertEqual(ny.timeZone.secondsFromGMT(for: july), -4 * 3600, "fixture: daylight time")
        XCTAssertEqual(
            CalendarWallTime.instant(hour: 1, minute: 15, on: nov1, keepingOffsetOf: december, calendar: ny),
            firstOneFifteen, "a December anchor"
        )
        XCTAssertEqual(
            CalendarWallTime.instant(hour: 1, minute: 15, on: nov1, keepingOffsetOf: july, calendar: ny),
            firstOneFifteen, "a July anchor"
        )
        XCTAssertEqual(Event.dateByCombining(day: nov1, timeFrom: december, calendar: ny), firstOneFifteen)
        XCTAssertEqual(Event.dateByCombining(day: nov1, timeFrom: july, calendar: ny), firstOneFifteen)
        // Through the expander: the two series' Nov 1 occurrences coincide.
        func series(from start: Date) -> Event {
            var event = Event(
                title: "Night",
                timeRanges: [Event.TimeRange(start: start, end: start.addingTimeInterval(1800))],
                type: "Work"
            )
            event.repeatUnit = .day
            event.repeatInterval = 1
            return event
        }
        XCTAssertEqual(CalendarLayout.recurrenceOccurrence(for: series(from: december), on: nov1, calendar: ny)?.start, firstOneFifteen)
        XCTAssertEqual(CalendarLayout.recurrenceOccurrence(for: series(from: july), on: nov1, calendar: ny)?.start, firstOneFifteen)

        // An event at 05:00 EST on the day itself, its hour set to 1: the
        // first 01:00, not the second, though 05:00 EST shares the second
        // pass's offset.
        let oneEDT = Date(timeIntervalSince1970: 1_793_509_200)
        let oneEST = Date(timeIntervalSince1970: 1_793_512_800)
        let fiveEST = oneEST.addingTimeInterval(4 * 3600)
        XCTAssertEqual(ny.component(.hour, from: fiveEST), 5, "fixture")
        XCTAssertEqual(ny.timeZone.secondsFromGMT(for: fiveEST), -5 * 3600, "fixture")
        XCTAssertEqual(CalendarWallTime.replacing(hour: 1, of: fiveEST, calendar: ny), oneEDT)
        // The same from 05:00 on the day after: the first pass again.
        XCTAssertEqual(
            CalendarWallTime.instant(hour: 1, minute: 0, on: nov1, keepingOffsetOf: fiveEST.addingTimeInterval(24 * 3600), calendar: ny),
            oneEDT
        )
        // Control: an instant on the second pass still keeps it when its
        // minute is edited, and 01:00 EST edited to hour 1 stays itself.
        XCTAssertEqual(CalendarWallTime.replacing(minute: 30, of: secondOneFifteen, calendar: ny), secondOneFifteen.addingTimeInterval(15 * 60))
        XCTAssertEqual(CalendarWallTime.replacing(hour: 1, of: oneEST, calendar: ny), oneEST)
    }

    func testTheResolverKeepsThePassOnlyOfAnOriginalOnThisDaysSecondPass() {
        let ny = newYork
        let noon = ny.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
        XCTAssertEqual(
            CalendarWallTime.instant(hour: 1, minute: 15, on: noon, keepingOffsetOf: secondOneFifteen, calendar: ny),
            secondOneFifteen
        )
        XCTAssertEqual(
            CalendarWallTime.instant(hour: 1, minute: 15, on: noon, keepingOffsetOf: firstOneFifteen, calendar: ny),
            firstOneFifteen
        )
        XCTAssertEqual(
            CalendarWallTime.instant(hour: 1, minute: 15, on: noon, keepingOffsetOf: nil, calendar: ny),
            firstOneFifteen, "a brand-new time takes the first occurrence"
        )
        // An original from another zone matches neither pass: first.
        let tokyo = Date(timeIntervalSince1970: 1_793_510_100 - 13 * 3600)
        XCTAssertEqual(
            CalendarWallTime.instant(hour: 1, minute: 15, on: noon, keepingOffsetOf: tokyo, calendar: ny),
            firstOneFifteen
        )
        // Control: an unambiguous time is the same whatever the original.
        XCTAssertEqual(
            CalendarWallTime.instant(hour: 9, minute: 0, on: noon, keepingOffsetOf: secondOneFifteen, calendar: ny)?.timeIntervalSince1970,
            1_793_541_600
        )
        // A wall time the day skips resolves to the first instant after the
        // jump (gh#223's policy), not to the components carried past it.
        let springNoon = ny.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        XCTAssertEqual(
            CalendarWallTime.instant(hour: 2, minute: 30, on: springNoon, keepingOffsetOf: nil, calendar: ny)?.timeIntervalSince1970,
            1_772_953_200, "03:00 EDT, not 03:30"
        )
        XCTAssertEqual(
            CalendarWallTime.replacing(hour: 2, of: Date(timeIntervalSince1970: 1_772_953_200 - 3600 + 15 * 60), calendar: ny)
                .timeIntervalSince1970,
            1_772_953_200, "01:15 EST with its hour set to 02 lands on 03:00 EDT"
        )
        // A day that starts on its jump (Santiago): a wall time before the
        // start resolves to the start.
        var scl = Calendar(identifier: .gregorian)
        scl.timeZone = TimeZone(identifier: "America/Santiago")!
        let sclNoon = scl.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!
        XCTAssertEqual(
            CalendarWallTime.instant(hour: 0, minute: 30, on: sclNoon, keepingOffsetOf: nil, calendar: scl)?.timeIntervalSince1970,
            1_788_667_200, "the day's first instant, 01:00"
        )
        XCTAssertTrue(CalendarWallTime.isAmbiguous(secondOneFifteen, calendar: ny))
        XCTAssertTrue(CalendarWallTime.isAmbiguous(firstOneFifteen, calendar: ny))
        XCTAssertFalse(CalendarWallTime.isAmbiguous(Date(timeIntervalSince1970: 1_793_541_600), calendar: ny))
    }

    func testTheWheelPickerKeepsTheSecondOneFifteenWhenTheMinuteChanges() {
        let ny = newYork
        XCTAssertEqual(
            CalendarWallTime.replacing(minute: 30, of: secondOneFifteen, calendar: ny),
            secondOneFifteen.addingTimeInterval(15 * 60), "01:30 EST"
        )
        XCTAssertEqual(
            CalendarWallTime.replacing(hour: 1, of: secondOneFifteen, calendar: ny),
            secondOneFifteen
        )
        XCTAssertEqual(
            CalendarWallTime.replacing(minute: 30, of: firstOneFifteen, calendar: ny),
            firstOneFifteen.addingTimeInterval(15 * 60), "01:30 EDT"
        )
        // Leaving the repeated hour drops the ambiguity: 03:15 EST, one instant.
        XCTAssertEqual(
            CalendarWallTime.replacing(hour: 3, of: secondOneFifteen, calendar: ny).timeIntervalSince1970,
            1_793_512_800 + 2 * 3600 + 15 * 60
        )
    }

    func testDateByCombiningTakesTheFirstPassUnlessTheSeriesStartIsOnTheSecond() {
        let ny = newYork
        let nov1 = ny.startOfDay(for: ny.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!)
        // A series started at 01:15 on another day lands on the first 01:15
        // whether that day was in winter (EST) or summer (EDT); only a start
        // on this day's own second 01:15 stays there.
        let winterStart = ny.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 1, minute: 15))!
        let summerStart = ny.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 1, minute: 15))!
        XCTAssertEqual(Event.dateByCombining(day: nov1, timeFrom: winterStart, calendar: ny), firstOneFifteen)
        XCTAssertEqual(Event.dateByCombining(day: nov1, timeFrom: summerStart, calendar: ny), firstOneFifteen)
        XCTAssertEqual(Event.dateByCombining(day: nov1, timeFrom: secondOneFifteen, calendar: ny), secondOneFifteen)
        XCTAssertEqual(Event.dateByCombining(day: nov1, timeFrom: firstOneFifteen, calendar: ny), firstOneFifteen)
        // Control: a plain day and the gh#223 end-of-day clamp are untouched.
        let nov3 = ny.startOfDay(for: ny.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!)
        XCTAssertEqual(ny.component(.hour, from: Event.dateByCombining(day: nov3, timeFrom: winterStart, calendar: ny)), 1)
        XCTAssertLessThanOrEqual(
            Event.dateByCombining(day: nov1, timeFrom: ny.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 23, minute: 59, second: 59))!, calendar: ny),
            Event.endOfDay(for: nov1, calendar: ny)
        )
    }

    func testEveryCallerOfDateByCombiningKeepsTheSecondOneFifteen() {
        // A series seeded on the fall-back day at its second 01:15: every
        // caller that re-derives that day's occurrence keeps the pass.
        let ny = newYork
        let nov1 = ny.startOfDay(for: ny.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!)
        var series = Event(
            title: "Night",
            timeRanges: [Event.TimeRange(start: secondOneFifteen, end: secondOneFifteen.addingTimeInterval(1800))],
            type: "Work"
        )
        series.repeatUnit = .day
        series.repeatInterval = 1

        // CalendarLayout.recurrenceOccurrence (the series expander).
        let occurrence = CalendarLayout.recurrenceOccurrence(for: series, on: nov1, calendar: ny)
        XCTAssertEqual(occurrence?.start, secondOneFifteen, "expander")

        // Event.applyEdit(.single): the exception instance it mints.
        let edited = Event.applyEdit(series: series, occurrenceDate: nov1, scope: .single, edit: { $0.title = "Renamed" }, calendar: ny)
        XCTAssertEqual(edited.exceptionInstance?.primaryTimeRange?.start, secondOneFifteen, "applyEdit .single")
        XCTAssertEqual(edited.exceptionInstance?.title, "Renamed")

        // Event.normalizedSingleOccurrenceException: the sheet's locked copy.
        let locked = Event.normalizedSingleOccurrenceException(series, lockedTo: nov1, calendar: ny)
        XCTAssertEqual(locked.primaryTimeRange?.start, secondOneFifteen, "normalizedSingleOccurrenceException")

        // Event.renderTimeRanges: an exception instance whose mirror midnight
        // was minted in another frame (Tokyo's Nov 1) is projected onto this
        // frame's Nov 1 keeping its time-of-day — and its offset.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var replacement = series
        replacement.repeatUnit = .none
        replacement.recurrenceParentId = series.id
        replacement.recurrenceInstanceDate = tokyo.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        replacement.recurrenceInstanceDayKey = 20_261_101
        replacement.timeRanges = [Event.TimeRange(start: secondOneFifteen, end: secondOneFifteen.addingTimeInterval(1800))]
        XCTAssertTrue(replacement.isExceptionInstance, "fixture")
        XCTAssertEqual(replacement.renderTimeRanges(calendar: ny).first?.start, secondOneFifteen, "renderTimeRanges, second pass")
        replacement.timeRanges = [Event.TimeRange(start: firstOneFifteen, end: firstOneFifteen.addingTimeInterval(1800))]
        XCTAssertEqual(replacement.renderTimeRanges(calendar: ny).first?.start, firstOneFifteen, "renderTimeRanges, first pass")
    }

    func testTheDetailViewNamesTheZoneBesideAnAmbiguousTimeAsTheFormDoes() {
        // The detail view's summary line and its time labels apply the
        // form's rule: a wall time the day visits twice carries its zone, a
        // unique one is bare.
        let ny = newYork
        func event(_ start: Date, seconds: TimeInterval) -> (Event, Event.TimeRange) {
            let range = Event.TimeRange(start: start, end: start.addingTimeInterval(seconds))
            return (Event(title: "Night", timeRanges: [range], type: "Work"), range)
        }
        let (c1, c1Range) = event(secondOneFifteen, seconds: 1800)
        let (b1, b1Range) = event(firstOneFifteen, seconds: 1800)
        let nineEST = Date(timeIntervalSince1970: 1_793_541_600)
        let (a9, a9Range) = event(nineEST, seconds: 3600)
        let dateText: (Date) -> String = { date in
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeZone = ny.timeZone
            return formatter.string(from: date)
        }

        XCTAssertEqual(
            calendarEventDetailTimeSummary(for: c1, range: c1Range, is24: true, calendar: ny),
            "\(dateText(secondOneFifteen)) • 1:15 EST - 1:45 EST"
        )
        XCTAssertEqual(
            calendarEventDetailTimeSummary(for: b1, range: b1Range, is24: true, calendar: ny),
            "\(dateText(firstOneFifteen)) • 1:15 EDT - 1:45 EDT"
        )
        XCTAssertEqual(
            calendarEventDetailTimeSummary(for: c1, range: c1Range, is24: false, calendar: ny),
            "\(dateText(secondOneFifteen)) • 1:15 am EST - 1:45 am EST"
        )
        // Control: a unique wall time on the same day, and a plain day, stay bare.
        XCTAssertEqual(
            calendarEventDetailTimeSummary(for: a9, range: a9Range, is24: true, calendar: ny),
            "\(dateText(nineEST)) • 9:00 - 10:00"
        )
        let plainStart = ny.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 1, minute: 15))!
        let (plain, plainRange) = event(plainStart, seconds: 1800)
        XCTAssertEqual(
            calendarEventDetailTimeSummary(for: plain, range: plainRange, is24: true, calendar: ny),
            "\(dateText(plainStart)) • 1:15 - 1:45"
        )
        // A range that leaves the repeated hour names the zone on the one
        // end that is ambiguous.
        let (leaving, leavingRange) = event(secondOneFifteen, seconds: 2 * 3600)
        XCTAssertEqual(
            calendarEventDetailTimeSummary(for: leaving, range: leavingRange, is24: true, calendar: ny),
            "\(dateText(secondOneFifteen)) • 1:15 EST - 3:15"
        )
        // The single time label, as the mini timeline's ends and the
        // interrupt rows read it.
        XCTAssertEqual(calendarEventDetailTimeLabel(secondOneFifteen, is24: true, calendar: ny), "1:15 EST")
        XCTAssertEqual(calendarEventDetailTimeLabel(firstOneFifteen, is24: false, calendar: ny), "1:15 am EDT")
        XCTAssertEqual(calendarEventDetailTimeLabel(nineEST, is24: true, calendar: ny), "9:00")
        // The form reads the same helper.
        let formFormatter = DateFormatter()
        formFormatter.timeZone = ny.timeZone
        formFormatter.dateFormat = "H:mm"
        XCTAssertEqual(calendarWallTimeText(secondOneFifteen, formatter: formFormatter, calendar: ny), "1:15 EST")
        XCTAssertEqual(calendarWallTimeText(nineEST, formatter: formFormatter, calendar: ny), "9:00")
    }

    func testTheLegacyClockPutsTheSecondOneFifteenOnTheWrongRow() {
        // Control for the test above: with the legacy clock the geometry is
        // the same elapsed mapping, so the blocks land on the same rows —
        // the legacy clock's error was in the labels and the day's end, not
        // in block positions. What changes is the window: 23:30 EST is
        // beyond a legacy day and inside the real one.
        let late = Date(timeIntervalSince1970: 1_793_505_600 + 24.5 * 3600)
        let legacy = CalendarZoneClock(calendar: newYork, usesActualDayLength: false).day(containing: late)
        XCTAssertFalse(legacy.contains(late))
        XCTAssertTrue(fallBack.contains(late))
        XCTAssertEqual(calendarTimelineYFraction(for: late, clock: legacy), 1, "clamped to the legacy day's end")
        XCTAssertEqual(calendarTimelineYFraction(for: late, clock: fallBack), 24.5 / 25, accuracy: 0.0001)
    }
}
