//
//  ClockHubTests.swift
//  DoneMacTests
//
//  The one clock: bucket-edge firing, occlusion suspension with single-tick
//  catch-up, and the clockTicksWhileOccluded tripwire.
//

import XCTest
@testable import Done

@MainActor
final class ClockHubTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    // An on-the-minute anchor so bucket edges are predictable.
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_100 - 800_000_100.truncatingRemainder(dividingBy: 60))

    private func makeHub(bill: MacWorkBill? = nil) -> ClockHub {
        ClockHub(calendar: calendar, bill: bill, drivesTimer: false)
    }

    func testFirstPumpSeedsWithoutFiring() {
        let hub = makeHub()
        var fired = 0
        hub.register(.minute) { _ in fired += 1 }
        hub.pump(now: t0)
        XCTAssertEqual(fired, 0, "the seeding pump must not deliver a phantom tick")
    }

    func testSameBucketDoesNotFire() {
        let hub = makeHub()
        var fired = 0
        hub.register(.minute) { _ in fired += 1 }
        hub.pump(now: t0)
        hub.pump(now: t0.addingTimeInterval(30))
        XCTAssertEqual(fired, 0)
    }

    func testMinuteBoundaryFiresOnce() {
        let hub = makeHub()
        var fired = 0
        hub.register(.minute) { _ in fired += 1 }
        hub.pump(now: t0)
        hub.pump(now: t0.addingTimeInterval(61))
        XCTAssertEqual(fired, 1)
    }

    func testGranularitiesAreIndependent() {
        let hub = makeHub()
        var thirty = 0
        var minute = 0
        hub.register(.thirtySeconds) { _ in thirty += 1 }
        hub.register(.minute) { _ in minute += 1 }
        hub.pump(now: t0)
        hub.pump(now: t0.addingTimeInterval(31))
        XCTAssertEqual(thirty, 1)
        XCTAssertEqual(minute, 0, "a 30s edge is not a minute edge")
    }

    func testDayBoundaryFires() {
        let hub = makeHub()
        var fired = 0
        hub.register(.day) { _ in fired += 1 }
        hub.pump(now: t0)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: t0)!
        hub.pump(now: nextDay)
        XCTAssertEqual(fired, 1)
    }

    func testOccludedPumpFiresNothingAndTripsCounter() {
        let bill = MacWorkBill()
        let hub = makeHub(bill: bill)
        var fired = 0
        hub.register(.minute) { _ in fired += 1 }
        hub.pump(now: t0)
        hub.setOccluded(true, now: t0)
        hub.pump(now: t0.addingTimeInterval(120))
        XCTAssertEqual(fired, 0, "an occluded hub delivered a tick")
        XCTAssertEqual(bill.count(.clockTicksWhileOccluded), 1)
    }

    func testUnoccludeCatchUpCollapsesToOneTick() {
        let bill = MacWorkBill()
        let hub = makeHub(bill: bill)
        var fired = 0
        hub.register(.minute) { _ in fired += 1 }
        hub.pump(now: t0)
        hub.setOccluded(true, now: t0)
        // Ten minutes pass hidden; the catch-up is ONE tick, not ten.
        hub.setOccluded(false, now: t0.addingTimeInterval(600))
        XCTAssertEqual(fired, 1, "catch-up must collapse the hidden gap to one tick")
        XCTAssertEqual(bill.count(.clockTicksMinute), 1)
    }

    func testUnregisterStopsDelivery() {
        let hub = makeHub()
        var fired = 0
        let id = hub.register(.minute) { _ in fired += 1 }
        hub.pump(now: t0)
        hub.unregister(id)
        hub.pump(now: t0.addingTimeInterval(61))
        XCTAssertEqual(fired, 0)
        XCTAssertEqual(hub.registeredCount, 0)
    }

    func testNextBoundaryMathAroundEdges() {
        let g = ClockGranularity.minute
        let onEdge = Date(timeIntervalSinceReferenceDate: 600)
        XCTAssertEqual(g.nextBoundary(after: onEdge, calendar: calendar),
                       Date(timeIntervalSinceReferenceDate: 660),
                       "a moment exactly on the edge belongs to ITS bucket; next is strictly later")
        let midBucket = Date(timeIntervalSinceReferenceDate: 630)
        XCTAssertEqual(g.nextBoundary(after: midBucket, calendar: calendar),
                       Date(timeIntervalSinceReferenceDate: 660))
    }
}
