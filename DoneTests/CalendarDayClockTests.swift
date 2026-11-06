//
//  CalendarDayClockTests.swift
//  DoneTests
//
//  The day clock (gh#284 / #285): what one civil day looks like under a zone,
//  pinned on the days the timeline has to get right.
//

import XCTest
@testable import Done

final class CalendarDayClockTests: XCTestCase {

    private func calendar(_ zoneID: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneID)!
        return calendar
    }

    private func noon(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    // MARK: Africa/Cairo (a mid-week special day for the week view's QA)

    func testCairoHasATwentyFiveHourThursdayInOctoberAndATwentyThreeHourFridayInApril() {
        let cairo = calendar("Africa/Cairo")
        let zone = CalendarZoneClock(calendar: cairo, usesActualDayLength: true)

        let fallBack = zone.day(containing: noon(cairo, 2026, 10, 29))
        XCTAssertEqual(cairo.component(.weekday, from: fallBack.start), 5, "a Thursday")
        XCTAssertEqual(fallBack.length, 25 * 3600)
        XCTAssertFalse(fallBack.isStandard)
        XCTAssertEqual(fallBack.offsetChange, -3600)

        let springForward = zone.day(containing: noon(cairo, 2026, 4, 24))
        XCTAssertEqual(cairo.component(.weekday, from: springForward.start), 6, "a Friday")
        XCTAssertEqual(springForward.length, 23 * 3600)
        XCTAssertFalse(springForward.isStandard)
        XCTAssertEqual(springForward.offsetChange, 3600)

        for day in [28, 30] {
            XCTAssertTrue(zone.day(containing: noon(cairo, 2026, 10, day)).isStandard, "October \(day) is plain")
        }
    }

    // MARK: America/New_York

    func testNewYorkFallBackDayIsTwentyFiveHoursAndVisitsOneHourTwice() {
        let ny = calendar("America/New_York")
        let clock = CalendarZoneClock(calendar: ny, usesActualDayLength: true).day(containing: noon(ny, 2026, 11, 1))

        XCTAssertEqual(clock.start.timeIntervalSince1970, 1_793_505_600, "00:00 EDT")
        XCTAssertEqual(clock.end.timeIntervalSince1970, 1_793_595_600, "the next day's 00:00 EST")
        XCTAssertEqual(clock.length, 25 * 3600)
        XCTAssertFalse(clock.isStandard)
        XCTAssertEqual(clock.transition?.timeIntervalSince1970, 1_793_512_800, "01:00 EST, the second 01:00")
        XCTAssertEqual(clock.offsetChange, -3600)
        XCTAssertNil(clock.missingRange)

        let repeated = clock.repeatedRange
        XCTAssertEqual(repeated?.start.timeIntervalSince1970, 1_793_509_200, "01:00 EDT")
        XCTAssertEqual(repeated?.end.timeIntervalSince1970, 1_793_516_400, "02:00 EST")

        let firstOneFifteen = Date(timeIntervalSince1970: 1_793_510_100)   // 01:15 EDT
        let secondOneFifteen = Date(timeIntervalSince1970: 1_793_513_700)  // 01:15 EST
        let nineEST = Date(timeIntervalSince1970: 1_793_541_600)
        XCTAssertEqual(clock.repeatedPass(of: firstOneFifteen), 1)
        XCTAssertEqual(clock.repeatedPass(of: secondOneFifteen), 2)
        XCTAssertNil(clock.repeatedPass(of: nineEST))
        XCTAssertNil(clock.repeatedPass(of: clock.start))
        XCTAssertTrue(clock.contains(nineEST))
        XCTAssertFalse(clock.contains(clock.end))
    }

    func testNewYorkSpringForwardDayIsTwentyThreeHoursAndSkipsOneHour() {
        let ny = calendar("America/New_York")
        let clock = CalendarZoneClock(calendar: ny, usesActualDayLength: true).day(containing: noon(ny, 2026, 3, 8))

        XCTAssertEqual(clock.start.timeIntervalSince1970, 1_772_946_000, "00:00 EST")
        XCTAssertEqual(clock.length, 23 * 3600)
        XCTAssertFalse(clock.isStandard)
        XCTAssertEqual(clock.transition?.timeIntervalSince1970, 1_772_953_200, "03:00 EDT, right after 01:59:59 EST")
        XCTAssertEqual(clock.offsetChange, 3600)
        XCTAssertNil(clock.repeatedRange)

        // The missing 02:00–03:00 EST, as the instants those wall times would
        // have been under the offset in force before the jump.
        let missing = clock.missingRange
        XCTAssertEqual(missing?.start.timeIntervalSince1970, 1_772_953_200)
        XCTAssertEqual(missing?.duration, 3600)
        var twoThirtyUnderEST = DateComponents(year: 2026, month: 3, day: 8, hour: 2, minute: 30)
        twoThirtyUnderEST.timeZone = TimeZone(secondsFromGMT: -5 * 3600)
        XCTAssertTrue(missing!.contains(ny.date(from: twoThirtyUnderEST)!))
    }

    func testNewYorkPlainDayIsStandard() {
        let ny = calendar("America/New_York")
        let clock = CalendarZoneClock(calendar: ny, usesActualDayLength: true).day(containing: noon(ny, 2026, 11, 2))
        XCTAssertTrue(clock.isStandard)
        XCTAssertEqual(clock.length, DayClock.standardLength)
        XCTAssertNil(clock.transition)
        XCTAssertNil(clock.repeatedRange)
        XCTAssertNil(clock.missingRange)
    }

    // MARK: America/Santiago (gh#221: a day with no midnight)

    func testSantiagoSpringDayHasNoMidnightAndStartsOnItsTransition() {
        let scl = calendar("America/Santiago")
        let clock = CalendarZoneClock(calendar: scl, usesActualDayLength: true).day(containing: noon(scl, 2026, 9, 6))

        XCTAssertEqual(scl.component(.hour, from: clock.start), 1, "the day's first instant is 01:00; 00:00 does not exist")
        XCTAssertEqual(clock.start.timeIntervalSince1970, 1_788_667_200)
        XCTAssertEqual(clock.length, 23 * 3600)
        XCTAssertEqual(clock.transition, clock.start, "the jump IS the day's start, so it still counts as inside the day")
        XCTAssertEqual(clock.offsetChange, 3600)
        XCTAssertEqual(clock.missingRange?.start, clock.start)
        XCTAssertEqual(clock.missingRange?.duration, 3600)
        XCTAssertFalse(clock.isStandard)
        // Hour lines at whole hours from the start read 01, 02, … 23, then the
        // next day's 00 — a 23h day with 24 rows, none of them 00 on this day.
        var hours: [Int] = []
        var t = clock.start
        while t <= clock.end {
            hours.append(scl.component(.hour, from: t))
            t = t.addingTimeInterval(3600)
        }
        XCTAssertEqual(hours, Array(1...23) + [0])
    }

    func testSantiagoFallBackDayIsTwentyFiveHoursAtItsEnd() {
        let scl = calendar("America/Santiago")
        let clock = CalendarZoneClock(calendar: scl, usesActualDayLength: true).day(containing: noon(scl, 2026, 4, 4))
        XCTAssertEqual(clock.length, 25 * 3600)
        XCTAssertEqual(clock.transition?.timeIntervalSince1970, 1_775_358_000, "23:00 GMT-4, the second 23:00")
        XCTAssertEqual(clock.offsetChange, -3600)
        XCTAssertEqual(clock.repeatedRange?.end, clock.end, "the repeated hour is the day's last")
    }

    // MARK: UTC

    func testUTCDaysAreStandard() {
        let utc = calendar("UTC")
        let zone = CalendarZoneClock(calendar: utc, usesActualDayLength: true)
        for (month, day) in [(3, 8), (11, 1), (6, 15)] {
            let clock = zone.day(containing: noon(utc, 2026, month, day))
            XCTAssertTrue(clock.isStandard, "\(month)/\(day)")
            XCTAssertNil(clock.transition)
        }
    }

    // MARK: Australia/Lord_Howe — deferred (gh#285 S4)

    func testLordHoweHalfHourShiftIsMeasuredButItsGridIsDeferred() {
        // The clock measures the half-hour day correctly. The hour lines
        // are still drawn at whole hours from the start, so after 02:00 the
        // lines sit at :30 wall clock — accepted for now, handled in S4.
        let lhi = calendar("Australia/Lord_Howe")
        let clock = CalendarZoneClock(calendar: lhi, usesActualDayLength: true).day(containing: noon(lhi, 2026, 4, 5))
        XCTAssertEqual(clock.length, 24.5 * 3600)
        XCTAssertEqual(clock.offsetChange, -1800)
        XCTAssertEqual(calendarTimelineVisibleMinutes(clock: clock), 24 * 60 + 30)
        let afterTheShift = clock.start.addingTimeInterval(5 * 3600)
        XCTAssertEqual(lhi.component(.minute, from: afterTheShift), 30, "a whole-hour line lands on :30 wall clock")
    }

    // MARK: Legacy clock and the kill switch

    func testLegacyClockIsAStandardDayFromTheStartWhateverTheZoneDoes() {
        let ny = calendar("America/New_York")
        let dayStart = ny.startOfDay(for: noon(ny, 2026, 11, 1))
        let legacy = CalendarZoneClock(calendar: ny, usesActualDayLength: false).day(containing: noon(ny, 2026, 11, 1))
        XCTAssertEqual(legacy, DayClock.legacy24h(start: dayStart))
        XCTAssertEqual(legacy.length, DayClock.standardLength)
        XCTAssertTrue(legacy.isStandard)
        XCTAssertEqual(legacy.end, dayStart.addingTimeInterval(DayClock.standardLength), "an hour before the real next day")
        XCTAssertNil(legacy.repeatedRange)
    }

    func testTheZoneClockWalksCivilDaysNotFixedLengths() {
        let ny = calendar("America/New_York")
        let zone = CalendarZoneClock(calendar: ny, usesActualDayLength: true)
        let fallBack = zone.day(containing: noon(ny, 2026, 11, 1))
        let next = zone.day(1, from: fallBack)
        let previous = zone.day(-1, from: fallBack)
        XCTAssertEqual(next.start, fallBack.end)
        XCTAssertEqual(previous.end, fallBack.start)
        XCTAssertTrue(next.isStandard)
        XCTAssertTrue(previous.isStandard)
    }

    func testTheDefaultZoneClockReadsTheKillSwitch() {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: AppSettingsKeys.calendarDayClockEnabled)
        defer {
            if let before { defaults.set(before, forKey: AppSettingsKeys.calendarDayClockEnabled) }
            else { defaults.removeObject(forKey: AppSettingsKeys.calendarDayClockEnabled) }
        }
        defaults.set(false, forKey: AppSettingsKeys.calendarDayClockEnabled)
        XCTAssertFalse(CalendarZoneClock.current.usesActualDayLength)
        defaults.set(true, forKey: AppSettingsKeys.calendarDayClockEnabled)
        XCTAssertTrue(CalendarZoneClock.current.usesActualDayLength)
        defaults.removeObject(forKey: AppSettingsKeys.calendarDayClockEnabled)
        XCTAssertEqual(CalendarZoneClock.current.usesActualDayLength, CalendarZoneClock.dayClockEnabledByDefault)
        XCTAssertTrue(AppSettingsKeys.resettableUserDefaultsKeys.contains(AppSettingsKeys.calendarDayClockEnabled))
    }
}
