//
//  EventResizeTweenTests.swift
//  DoneTests
//
//  The resize-tween spike's load-bearing claims:
//    1. A length changed elsewhere glides on the SAME block subtree (the
//       re-ided block is handed its old subtree), and neighbours pushed
//       aside glide with it.
//    2. Nothing else glides: the flag off, a move that keeps the length, a
//       zoom. Each runs beside the tweened case, so a host that tweens
//       everything, or nothing, fails.
//    3. A path that changed kind is set, not inbetweened.
//

import XCTest
import UIKit
@testable import Done

@MainActor
final class EventResizeTweenTests: XCTestCase {

    private let enabledKey = SpikeFeatureFlag.enabledKey(EventResizeTweenFlag.spikeID)
    private var savedEnabled: Any?

    override func setUp() {
        super.setUp()
        savedEnabled = UserDefaults.standard.object(forKey: enabledKey)
        UserDefaults.standard.set(true, forKey: enabledKey)
    }

    override func tearDown() {
        if let savedEnabled {
            UserDefaults.standard.set(savedEnabled, forKey: enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: enabledKey)
        }
        super.tearDown()
    }

    // MARK: Host

    func testALengthEditGlidesOnTheSameSubtreeAndTheOffTwinJumps() {
        let event = Event(title: "A", timeRanges: [range(9, 10)], type: "Study")
        let host = makeHost([occurrence(event, 9, 10)])
        let before = blockContainers(host)
        XCTAssertEqual(before.count, 1)

        host.apply(makeModel([occurrence(event, 9, 11)]))
        host.layoutIfNeeded()
        let after = blockContainers(host)
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after[0] === before[0], "the re-ided block keeps its subtree")
        XCTAssertTrue(isTweening(after[0]), "and glides to the new length")

        UserDefaults.standard.set(false, forKey: enabledKey)
        let twin = makeHost([occurrence(event, 9, 10)])
        twin.apply(makeModel([occurrence(event, 9, 11)]))
        twin.layoutIfNeeded()
        XCTAssertFalse(blockContainers(twin).contains(where: isTweening), "off: it jumps")
    }

    func testAMoveThatKeepsTheLengthDoesNotGlide() {
        let event = Event(title: "A", timeRanges: [range(9, 10)], type: "Study")
        let host = makeHost([occurrence(event, 9, 10)])
        host.apply(makeModel([occurrence(event, 13, 14)]))
        host.layoutIfNeeded()
        XCTAssertFalse(blockContainers(host).contains(where: isTweening))

        let control = makeHost([occurrence(event, 9, 10)])
        control.apply(makeModel([occurrence(event, 13, 15)]))
        control.layoutIfNeeded()
        XCTAssertTrue(blockContainers(control).contains(where: isTweening), "control: a length change does")
    }

    func testAZoomDoesNotGlideEvenWithALengthChange() {
        let event = Event(title: "A", timeRanges: [range(9, 10)], type: "Study")
        let host = makeHost([occurrence(event, 9, 10)])
        host.apply(makeModel([occurrence(event, 9, 11)], hourHeight: 80))
        host.layoutIfNeeded()
        XCTAssertFalse(blockContainers(host).contains(where: isTweening))
    }

    func testANeighbourPushedAsideGlidesWithTheEdit() {
        let a = Event(title: "A", timeRanges: [range(9, 10)], type: "Study")
        let b = Event(title: "B", timeRanges: [range(10.5, 11.5)], type: "Work")
        let host = makeHost([occurrence(a, 9, 10), occurrence(b, 10.5, 11.5)])
        let bBlock = blockContainers(host).first { $0.frame.minY > 560 }
        XCTAssertNotNil(bBlock)
        // A now runs into B: both split into columns.
        host.apply(makeModel([occurrence(a, 9, 11), occurrence(b, 10.5, 11.5)]))
        host.layoutIfNeeded()
        XCTAssertEqual(blockContainers(host).count, 2)
        XCTAssertTrue(bBlock.map(isTweening) ?? false, "B, squeezed into a column, glides too")
    }

    // MARK: Tween

    func testAPathThatChangedKindIsSetNotInbetweened() {
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 100, height: 40)
        let same = CAShapeLayer()
        same.path = UIBezierPath(roundedRect: root.bounds, cornerRadius: 4).cgPath
        let changed = CAShapeLayer()
        changed.path = UIBezierPath(rect: root.bounds).cgPath
        root.addSublayer(same)
        root.addSublayer(changed)
        let capture = EventResizeTween.capture(root)

        root.frame = CGRect(x: 0, y: 0, width: 100, height: 60)
        same.path = UIBezierPath(roundedRect: root.bounds, cornerRadius: 4).cgPath
        changed.path = UIBezierPath(roundedRect: root.bounds, cornerRadius: 4).cgPath
        XCTAssertTrue(EventResizeTween.animate(from: capture, root: root, duration: 0.1))
        XCTAssertNotNil(same.animation(forKey: "resizeTween.path"), "same shape: inbetweened")
        XCTAssertNil(changed.animation(forKey: "resizeTween.path"), "rect → rounded rect: set")
        XCTAssertNotNil(root.animation(forKey: "resizeTween.bounds"))
    }

    // MARK: Fixtures

    private var day: Date { Calendar.current.startOfDay(for: Date()) }

    private func range(_ start: Double, _ end: Double) -> Event.TimeRange {
        Event.TimeRange(start: day.addingTimeInterval(start * 3600), end: day.addingTimeInterval(end * 3600))
    }

    /// Ids carry the times, as `CalendarLayout` mints them.
    private func occurrence(_ event: Event, _ start: Double, _ end: Double) -> CalendarLayout.EventOccurrence {
        let r = range(start, end)
        return CalendarLayout.EventOccurrence(
            id: "\(event.id.uuidString)-\(r.start.timeIntervalSince1970)-\(r.end.timeIntervalSince1970)",
            event: event, range: r
        )
    }

    private func isTweening(_ layer: CALayer) -> Bool {
        layer.animationKeys()?.contains(where: { $0.hasPrefix("resizeTween.") }) == true
    }

    /// Event block containers: the host's sublayers that hold a subtree.
    private func blockContainers(_ host: DayLayerHostView) -> [CALayer] {
        host.layer.sublayers?.filter { !$0.isHidden && ($0.sublayers?.count ?? 0) >= 3 && $0.frame.width > 100 } ?? []
    }

    private func makeHost(_ occurrences: [CalendarLayout.EventOccurrence]) -> DayLayerHostView {
        let host = DayLayerHostView(frame: CGRect(x: 0, y: 0, width: 360, height: 2000))
        host.apply(makeModel(occurrences))
        host.layoutIfNeeded()
        return host
    }

    private func makeModel(
        _ occurrences: [CalendarLayout.EventOccurrence], hourHeight: CGFloat = 56
    ) -> DayLayerHostView.Model {
        DayLayerHostView.Model(
            date: day,
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
}
