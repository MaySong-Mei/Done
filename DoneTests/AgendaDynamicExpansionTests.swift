//
//  AgendaDynamicExpansionTests.swift
//  DoneTests
//
//  Test dynamic day range expansion for Agenda view
//

import XCTest
@testable import Done

@MainActor
final class AgendaDynamicExpansionTests: XCTestCase {
    let calendar = Calendar.current

    // Test: Initial day range should be -30...30
    func testInitialDayRange() {
        let initialRange: ClosedRange<Int> = -30...30
        XCTAssertEqual(initialRange.lowerBound, -30)
        XCTAssertEqual(initialRange.upperBound, 30)
        XCTAssertEqual(initialRange.count, 61)
    }

    // Test: Generate date range creates correct number of dates
    func testGenerateDateRange() {
        let today = calendar.startOfDay(for: Date())
        let dayRange: ClosedRange<Int> = -30...30
        var dates: [Date] = []

        for offset in dayRange.lowerBound...dayRange.upperBound {
            if let date = calendar.date(byAdding: .day, value: offset, to: today) {
                dates.append(date)
            }
        }

        XCTAssertEqual(dates.count, 61, "Should generate 61 dates for -30...30 range")
    }

    // Test: Expansion logic when approaching lower bound
    func testExpandBackward() {
        let dayRangeExpansionStep = 30
        let dayRangeExpansionThreshold = 14
        var dayRange: ClosedRange<Int> = -30...30

        // Simulate viewing a date 14 days from the lower bound
        let dayOffset = -30 + 13 // -17, which is < threshold (14 days from -30)

        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound
        var newLower = lower
        var newUpper = upper

        if dayOffset - lower < dayRangeExpansionThreshold {
            newLower = lower - dayRangeExpansionStep
        }

        if upper - dayOffset < dayRangeExpansionThreshold {
            newUpper = upper + dayRangeExpansionStep
        }

        if newLower != lower || newUpper != upper {
            dayRange = newLower...newUpper
        }

        XCTAssertEqual(dayRange.lowerBound, -60, "Should expand backward by 30 days")
        XCTAssertEqual(dayRange.upperBound, 30, "Upper bound should remain unchanged")
    }

    // Test: Expansion logic when approaching upper bound
    func testExpandForward() {
        let dayRangeExpansionStep = 30
        let dayRangeExpansionThreshold = 14
        var dayRange: ClosedRange<Int> = -30...30

        // Simulate viewing a date 14 days from the upper bound
        let dayOffset = 30 - 13 // 17, which is < threshold (14 days from 30)

        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound
        var newLower = lower
        var newUpper = upper

        if dayOffset - lower < dayRangeExpansionThreshold {
            newLower = lower - dayRangeExpansionStep
        }

        if upper - dayOffset < dayRangeExpansionThreshold {
            newUpper = upper + dayRangeExpansionStep
        }

        if newLower != lower || newUpper != upper {
            dayRange = newLower...newUpper
        }

        XCTAssertEqual(dayRange.lowerBound, -30, "Lower bound should remain unchanged")
        XCTAssertEqual(dayRange.upperBound, 60, "Should expand forward by 30 days")
    }

    // Test: No expansion when in the middle
    func testNoExpansionInMiddle() {
        let dayRangeExpansionStep = 30
        let dayRangeExpansionThreshold = 14
        var dayRange: ClosedRange<Int> = -30...30

        // Simulate viewing today (offset 0)
        let dayOffset = 0

        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound
        var newLower = lower
        var newUpper = upper

        if dayOffset - lower < dayRangeExpansionThreshold {
            newLower = lower - dayRangeExpansionStep
        }

        if upper - dayOffset < dayRangeExpansionThreshold {
            newUpper = upper + dayRangeExpansionStep
        }

        if newLower != lower || newUpper != upper {
            dayRange = newLower...newUpper
        }

        XCTAssertEqual(dayRange.lowerBound, -30, "Lower bound should not change")
        XCTAssertEqual(dayRange.upperBound, 30, "Upper bound should not change")
    }

    // Test: Calculate day offset correctly
    func testCalculateDayOffset() {
        let today = calendar.startOfDay(for: Date())

        // Test: today should have offset 0
        if let offset = calendar.dateComponents([.day], from: today, to: today).day {
            XCTAssertEqual(offset, 0)
        }

        // Test: tomorrow should have offset 1
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           let offset = calendar.dateComponents([.day], from: today, to: tomorrow).day {
            XCTAssertEqual(offset, 1)
        }

        // Test: yesterday should have offset -1
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
           let offset = calendar.dateComponents([.day], from: today, to: yesterday).day {
            XCTAssertEqual(offset, -1)
        }
    }

    // Test: Multiple expansions work correctly
    func testMultipleExpansions() {
        let dayRangeExpansionStep = 30
        let dayRangeExpansionThreshold = 14
        var dayRange: ClosedRange<Int> = -30...30

        // First expansion backward
        expandRange(&dayRange, for: -17, step: dayRangeExpansionStep, threshold: dayRangeExpansionThreshold)
        XCTAssertEqual(dayRange, -60...30)

        // Second expansion backward
        expandRange(&dayRange, for: -47, step: dayRangeExpansionStep, threshold: dayRangeExpansionThreshold)
        XCTAssertEqual(dayRange, -90...30)

        // Expansion forward
        expandRange(&dayRange, for: 17, step: dayRangeExpansionStep, threshold: dayRangeExpansionThreshold)
        XCTAssertEqual(dayRange, -90...60)
    }

    // Helper function to expand range
    private func expandRange(
        _ dayRange: inout ClosedRange<Int>,
        for dayOffset: Int,
        step: Int,
        threshold: Int
    ) {
        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound
        var newLower = lower
        var newUpper = upper

        if dayOffset - lower < threshold {
            newLower = lower - step
        }

        if upper - dayOffset < threshold {
            newUpper = upper + step
        }

        if newLower != lower || newUpper != upper {
            dayRange = newLower...newUpper
        }
    }
}
