//
//  EventDeletionMotionTests.swift
//  DoneTests
//
//  The delete-motion spike's two load-bearing claims:
//    1. A block leaves as a ghost ONLY when its event was marked deleted —
//       the same removal without a mark (a move to another day, a filter
//       change) recycles as before. Each ghost test runs beside its
//       unmarked twin, so a host that ghosts everything, or nothing, fails.
//    2. Off is king's shape: with the flag off nothing is marked.
//

import XCTest
import UIKit
@testable import Done

final class EventDeletionMotionTests: XCTestCase {

    private var savedIsEnabled: (() -> Bool)!

    override func setUp() {
        super.setUp()
        savedIsEnabled = EventDeletionMotionRegistry.shared.isEnabled
        EventDeletionMotionRegistry.shared.isEnabled = { true }
    }

    override func tearDown() {
        EventDeletionMotionRegistry.shared.isEnabled = savedIsEnabled
        super.tearDown()
    }

    // MARK: Registry

    func testAMarkExpiresAfterItsLifetime() {
        let registry = EventDeletionMotionRegistry()
        registry.isEnabled = { true }
        let id = UUID()
        let t0 = Date()
        registry.mark([id], source: .remote, now: t0)

        XCTAssertEqual(registry.mark(for: id, now: t0)?.source, .remote)
        XCTAssertNotNil(registry.mark(for: id, now: t0.addingTimeInterval(EventDeletionMotionRegistry.lifetime - 0.01)))
        XCTAssertNil(registry.mark(for: id, now: t0.addingTimeInterval(EventDeletionMotionRegistry.lifetime)))
    }

    func testReadingAMarkDoesNotConsumeIt() {
        // A cross-midnight event has a block on two day hosts; both ask.
        let registry = EventDeletionMotionRegistry()
        registry.isEnabled = { true }
        let id = UUID()
        registry.mark([id], source: .local)
        XCTAssertNotNil(registry.mark(for: id))
        XCTAssertNotNil(registry.mark(for: id))
    }

    func testFlagOffMarksNothing() {
        let registry = EventDeletionMotionRegistry()
        registry.isEnabled = { false }
        let id = UUID()
        registry.mark([id], source: .local)
        XCTAssertNil(registry.mark(for: id))
    }

    // MARK: Host

    func testAMarkedBlockStaysInTheLayerTreeAsAGhost() {
        let (host, a, b) = makeHostWithTwoBlocks()
        let before = host.layer.sublayers?.count ?? 0

        EventDeletionMotionRegistry.shared.mark([b.event.id], source: .local)
        host.apply(makeModel([a]))
        host.layoutIfNeeded()

        // No window → the motion waits for `didMoveToWindow`; the subtree is
        // still parented, not recycled.
        XCTAssertEqual(host.layer.sublayers?.count ?? 0, before)
    }

    func testTheSameRemovalUnmarkedRecyclesTheBlock() {
        let (host, a, _) = makeHostWithTwoBlocks()
        let before = host.layer.sublayers?.count ?? 0

        host.apply(makeModel([a]))
        host.layoutIfNeeded()

        XCTAssertEqual(host.layer.sublayers?.count ?? 0, before - 1)
    }

    func testAMarkedEventStillInTheDayIsNotAGhost() {
        // The mark is per event, the ghost per leaving occurrence: a block
        // that is re-laid-out (here: moved within the day) keeps its subtree.
        let (host, a, b) = makeHostWithTwoBlocks()
        let before = host.layer.sublayers?.count ?? 0

        EventDeletionMotionRegistry.shared.mark([b.event.id], source: .local)
        let movedB = CalendarLayout.EventOccurrence(
            id: b.id, event: b.event,
            range: Event.TimeRange(start: b.range.start.addingTimeInterval(3600), end: b.range.end.addingTimeInterval(3600))
        )
        host.apply(makeModel([a, movedB]))
        host.layoutIfNeeded()

        XCTAssertEqual(host.layer.sublayers?.count ?? 0, before)
        // …and removing it afterwards still ghosts exactly one subtree, not two.
        host.apply(makeModel([a]))
        host.layoutIfNeeded()
        XCTAssertEqual(host.layer.sublayers?.count ?? 0, before)
    }

    // MARK: Fixtures

    private var day: Date { Calendar.current.startOfDay(for: Date()) }

    private func makeHostWithTwoBlocks() -> (DayLayerHostView, CalendarLayout.EventOccurrence, CalendarLayout.EventOccurrence) {
        let a = makeOccurrence(id: "A-\(UUID().uuidString)", startHour: 9)
        let b = makeOccurrence(id: "B-\(UUID().uuidString)", startHour: 13)
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        host.apply(makeModel([a, b]))
        host.layoutIfNeeded()
        return (host, a, b)
    }

    private func makeOccurrence(id: String, startHour: Double) -> CalendarLayout.EventOccurrence {
        let start = day.addingTimeInterval(startHour * 3600)
        let range = Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
        return CalendarLayout.EventOccurrence(
            id: id,
            event: Event(title: id, timeRanges: [range], type: "Study"),
            range: range
        )
    }

    private func makeModel(_ occurrences: [CalendarLayout.EventOccurrence]) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: day,
            occurrences: occurrences,
            contentWidth: 360,
            headerHeight: 16,
            hourHeight: 56,
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
}
