import XCTest
@testable import Done

/// A hold on the watch's today page as data (`WristHold`): a still finger
/// arms after the hold time, a moved or scrolled one never does, and the
/// armed hold reads what it is on at once — a draft on empty time, a grab of
/// a block's edge or middle, a refusal — with the lift sending a draft to
/// the picker whether or not the finger moved.
final class WristHoldTests: XCTestCase {
    /// 2026-03-10 00:00 UTC.
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }
    private let down = Date(timeIntervalSince1970: 1_773_140_000)

    private func at(_ minutes: Double) -> Date { dayStart.addingTimeInterval(minutes * 60) }

    private func hold(x: Double = 100, y: Double = 120, scroll: Double = 400) -> WristHold {
        WristHold(downAt: down, x: x, y: y, scroll: scroll)
    }

    private func mapping(hourHeight: Double, edges: [Date] = []) -> WristDraftMapping {
        WristDraftMapping(dayStart: dayStart, dayEnd: dayEnd, height: 24 * hourHeight, edges: edges)
    }

    private var zooms: [Double] { WristLocalSettings.Zoom.allCases.map(\.hourHeight) }

    // MARK: Arming

    func testAStillFingerArmsOnceTheHoldTimeHasPassedAndNotBefore() {
        var h = hold()
        XCTAssertFalse(h.arm(at: down.addingTimeInterval(WristHold.duration - 2 * WristHold.timerLeeway)))
        XCTAssertTrue(h.isPending)
        XCTAssertTrue(h.arm(at: down.addingTimeInterval(WristHold.duration)))
        XCTAssertEqual(h.phase, .armed)
        XCTAssertFalse(h.arm(at: down.addingTimeInterval(WristHold.duration * 2)), "arms once")
    }

    func testJitterWithinTheSlopStillArms() {
        var h = hold(x: 100, y: 120)
        let d = WristHold.slop / 2.squareRoot()
        h.track(x: 100 + d, y: 120 - d)
        h.track(x: 100, y: 120 + WristHold.slop)
        XCTAssertTrue(h.isPending, "at the slop is still still")
        XCTAssertTrue(h.arm(at: down.addingTimeInterval(WristHold.duration)))
    }

    func testMovingPastTheSlopBeforeTheHoldTimeIsNoHold() {
        var h = hold(x: 100, y: 120)
        h.track(x: 100, y: 120 + WristHold.slop + 0.5)
        XCTAssertEqual(h.phase, .cancelled(.moved))
        XCTAssertFalse(h.arm(at: down.addingTimeInterval(WristHold.duration)))
        // Back where it went down is still no hold.
        h.track(x: 100, y: 120)
        XCTAssertEqual(h.phase, .cancelled(.moved))
        // A sideways move counts the same as a vertical one.
        var sideways = hold(x: 100, y: 120)
        sideways.track(x: 100 - WristHold.slop - 0.5, y: 120)
        XCTAssertEqual(sideways.phase, .cancelled(.moved))
    }

    func testTheDayScrollingUnderAPendingHoldIsNoHold() {
        var settled = hold(scroll: 400)
        settled.scrolled(to: 400 + WristHold.scrollTolerance)
        XCTAssertTrue(settled.isPending, "settling within the tolerance")

        var scrolled = hold(scroll: 400)
        scrolled.scrolled(to: 400 - WristHold.scrollTolerance - 0.5)
        XCTAssertEqual(scrolled.phase, .cancelled(.scrolled))
        XCTAssertFalse(scrolled.arm(at: down.addingTimeInterval(WristHold.duration)))

        var panned = hold()
        panned.scrollBegan()
        XCTAssertEqual(panned.phase, .cancelled(.scrolled))
    }

    func testOnceArmedTheFingerDrawsAndEdgeScrollingDoesNotUndoIt() {
        var h = hold(scroll: 400)
        XCTAssertTrue(h.arm(at: down.addingTimeInterval(WristHold.duration)))
        h.track(x: 100, y: 120 + 10 * WristHold.slop)
        h.scrolled(to: 900)
        h.scrollBegan()
        XCTAssertEqual(h.phase, .armed)
    }

    func testAGivenUpHoldKeepsItsFirstReason() {
        var h = hold()
        h.track(x: 100, y: 120 + WristHold.slop + 1)
        h.scrollBegan()
        XCTAssertEqual(h.phase, .cancelled(.moved))
    }

    /// A drag of a single grid step at the smallest zoom must not fit in
    /// the slop, and a real fingertip's wobble must.
    func testTheSlopIsUnderAQuarterHourAtEveryZoom() {
        let quarter = Double(WristTiming.gridMinutes) / 60
        for hour in zooms {
            XCTAssertLessThan(WristHold.slop, hour * quarter, "\(hour)")
        }
        XCTAssertGreaterThanOrEqual(WristHold.slop, 10)
    }

    // MARK: Reading

    func testAHeldPressOnEmptyTimeDraftsTheShortestRangeFromTheNearestGridMark() {
        let quarter = Double(WristTiming.gridMinutes)
        for hour in zooms {
            let m = mapping(hourHeight: hour)
            let y = { (minutes: Double) in minutes / 60 * hour }
            // Just under half a grid step past 10:00 rounds back to it,
            // just over rounds on.
            guard case .draft(let back) = WristHold.read(pressY: y(600 + quarter / 2 - 0.5), target: nil, emptyAtPress: true, mapping: m),
                  case .draft(let on) = WristHold.read(pressY: y(600 + quarter / 2 + 0.5), target: nil, emptyAtPress: true, mapping: m)
            else { return XCTFail("\(hour): no draft") }
            XCTAssertEqual(back.start, at(600), "\(hour)")
            XCTAssertEqual(back.end, at(600).addingTimeInterval(WristTiming.minimumDuration), "\(hour)")
            XCTAssertEqual(on.start, at(600 + quarter), "\(hour)")
            XCTAssertEqual(on.end.timeIntervalSince(on.start), WristTiming.minimumDuration, "\(hour)")
            // The draw's own range with the finger not yet moved: the first
            // drag step grows it from here without a jump.
            XCTAssertEqual(back, m.range(anchorY: y(600 + quarter / 2 - 0.5), currentY: y(600 + quarter / 2 - 0.5)))
        }
    }

    func testAHeldDraftStaysInTheDayAndLandsOnANeighboursEdge() {
        let hour = WristLocalSettings.Zoom.standard.hourHeight
        let m = mapping(hourHeight: hour, edges: [at(610)])
        guard case .draft(let late) = WristHold.read(pressY: 24 * hour - 1, target: nil, emptyAtPress: true, mapping: m),
              case .draft(let held) = WristHold.read(pressY: 611 / 60 * hour, target: nil, emptyAtPress: true, mapping: m)
        else { return XCTFail("no draft") }
        XCTAssertEqual(late.end, dayEnd)
        XCTAssertEqual(late.start, dayEnd.addingTimeInterval(-WristTiming.minimumDuration))
        XCTAssertEqual(held.start, at(610), "a block's end within the magnet")
        XCTAssertEqual(held.end, at(610).addingTimeInterval(WristTiming.minimumDuration))
    }

    func testAHeldPressOnABlockGrabsItsEdgeOrItsMiddle() {
        let m = mapping(hourHeight: 64)
        let block = WristHold.Target(minY: 640, height: 64, editable: true, canResizeTop: true, canResizeBottom: true)
        let zone = WristBlockEdit.edgeZone(blockHeight: block.height)
        XCTAssertGreaterThan(zone, 0)
        let read = { (dy: Double, target: WristHold.Target) in
            WristHold.read(pressY: target.minY + dy, target: target, emptyAtPress: false, mapping: m)
        }
        XCTAssertEqual(read(zone - 1, block), .grab(.resizeTop))
        XCTAssertEqual(read(block.height / 2, block), .grab(.move))
        XCTAssertEqual(read(block.height - zone + 1, block), .grab(.resizeBottom))

        var clipped = block
        clipped.canResizeTop = false
        XCTAssertEqual(read(1, clipped), .grab(.move), "an edge the day clips moves the block")

        var short = block
        short.height = 3 * WristBlockEdit.minimumEdgeZone - 1
        XCTAssertEqual(read(1, short), .grab(.move), "too short for edges")
    }

    func testAHeldPressOnABlockTheWatchMayNotEditIsRefused() {
        let m = mapping(hourHeight: 64)
        let locked = WristHold.Target(minY: 640, height: 64, editable: false, canResizeTop: true, canResizeBottom: true)
        XCTAssertEqual(WristHold.read(pressY: 650, target: locked, emptyAtPress: false, mapping: m), .refused)
        // Inside a block's time but beside its column: nothing to draw on.
        XCTAssertEqual(WristHold.read(pressY: 650, target: nil, emptyAtPress: false, mapping: m), .nothing)
    }

    // MARK: Release

    func testLiftingAHeldDraftOpensThePickerMovedOrNot() {
        let m = mapping(hourHeight: 64)
        var h = hold(y: 120)
        XCTAssertTrue(h.arm(at: down.addingTimeInterval(WristHold.duration)))
        guard case .draft(let range) = WristHold.read(pressY: 650, target: nil, emptyAtPress: true, mapping: m) else {
            return XCTFail("no draft")
        }
        XCTAssertEqual(range.end.timeIntervalSince(range.start), WristTiming.minimumDuration)
        XCTAssertEqual(WristHold.release(hasDraft: true, editChanged: false), .pick)
        XCTAssertEqual(WristHold.release(hasDraft: true, editChanged: true), .pick)
    }

    func testLiftingAGrabSendsOnlyAChangedRange() {
        XCTAssertEqual(WristHold.release(hasDraft: false, editChanged: true), .sendEdit)
        XCTAssertEqual(WristHold.release(hasDraft: false, editChanged: false), .none)
    }
}
