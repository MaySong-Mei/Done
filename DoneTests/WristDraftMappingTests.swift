import XCTest
@testable import Done

/// The today page's hold-and-drag as data: points → instants, the grid,
/// the magnet to block edges, the minimum, and a drag that goes up.
/// A 24-hour UTC day drawn at one point per minute, so a y is its minute.
final class WristDraftMappingTests: XCTestCase {
    /// 2026-03-10 00:00:00 UTC.
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }

    private func at(_ minute: Double) -> Date { dayStart.addingTimeInterval(minute * 60) }

    private func mapping(edges: [Date] = [], snapPoints: Double = 5) -> WristDraftMapping {
        WristDraftMapping(dayStart: dayStart, dayEnd: dayEnd, height: 1440, edges: edges, snapPoints: snapPoints)
    }

    private func block(_ start: Double, _ end: Double) -> WristDayBlock {
        let occurrence = WristOccurrence(
            id: "b\(start)", eventID: UUID(), title: "B", type: "B", colorHex: "#0A84FF",
            start: at(start), end: at(end), isInterrupt: false, quickActionsEnabled: true
        )
        return WristDayBlock(id: occurrence.id, occurrence: occurrence, start: at(start), end: at(end), lane: 0, lanes: 1, isCurrent: false)
    }

    // MARK: Points

    func testRawTimeIsProportionalAndHeldToTheDay() {
        let m = mapping()
        XCTAssertEqual(m.rawTime(atY: 0), dayStart)
        XCTAssertEqual(m.rawTime(atY: 637), at(637))
        XCTAssertEqual(m.rawTime(atY: -40), dayStart)
        XCTAssertEqual(m.rawTime(atY: 2000), dayEnd)
    }

    func testAPointRoundsToTheNearestQuarterHour() {
        let m = mapping()
        XCTAssertEqual(m.point(atY: 607), .init(time: at(600), edge: nil))
        XCTAssertEqual(m.point(atY: 608), .init(time: at(615), edge: nil))
        XCTAssertEqual(m.point(atY: 1439), .init(time: dayEnd, edge: nil))
    }

    func testABlockEdgeWithinReachWinsOverTheGrid() {
        // An edge off the grid, three points from the finger.
        let edge = at(610)
        let m = mapping(edges: [edge])
        XCTAssertEqual(m.point(atY: 613), .init(time: edge, edge: edge))
        XCTAssertEqual(m.point(atY: 615), .init(time: edge, edge: edge), "at the reach exactly")
        XCTAssertEqual(m.point(atY: 616), .init(time: at(615), edge: nil), "past the reach: the grid")
    }

    func testTheMagnetTestsTheUnroundedTime() {
        // 607 rounds to 600, but the finger is six points from the edge at
        // 613 — out of reach — while 609 is within reach of it.
        let edge = at(613)
        let m = mapping(edges: [edge])
        XCTAssertEqual(m.point(atY: 607).edge, nil)
        XCTAssertEqual(m.point(atY: 609).time, edge)
    }

    func testTheNearestOfTwoEdgesWins() {
        let m = mapping(edges: [at(600), at(604)])
        XCTAssertEqual(m.point(atY: 603).time, at(604))
        XCTAssertEqual(m.point(atY: 601).time, at(600))
    }

    func testEdgesOutsideTheDayDoNotPull() {
        let m = mapping(edges: [dayStart.addingTimeInterval(-60)])
        XCTAssertNil(m.point(atY: 1).edge)
    }

    func testNoMagnetWithoutReach() {
        let m = mapping(edges: [at(613)], snapPoints: 0)
        XCTAssertEqual(m.point(atY: 613), .init(time: at(615), edge: nil))
    }

    // MARK: Ranges

    func testAPressAloneIsTheMinimumFromTheMark() {
        let r = mapping().range(anchorY: 602, currentY: 602)
        XCTAssertEqual(r.start, at(600))
        XCTAssertEqual(r.end, at(615))
    }

    func testDraggingDownMovesTheEnd() {
        let r = mapping().range(anchorY: 602, currentY: 691)
        XCTAssertEqual(r.start, at(600))
        XCTAssertEqual(r.end, at(690))
        XCTAssertEqual(r.moving.time, at(690))
    }

    func testDraggingAboveThePressInverts() {
        let r = mapping().range(anchorY: 602, currentY: 538)
        XCTAssertEqual(r.start, at(540))
        XCTAssertEqual(r.end, at(600), "the press becomes the end")
        XCTAssertEqual(r.moving.time, at(540))
    }

    func testASmallMoveUpGrowsTheMinimumUpward() {
        // Up, but not enough to reach another mark: the block is the
        // quarter hour above the press, not below it.
        let r = mapping().range(anchorY: 602, currentY: 598)
        XCTAssertEqual(r.start, at(585))
        XCTAssertEqual(r.end, at(600))
    }

    func testAnEdgeCloserThanTheMinimumIsPaddedAwayFromThePress() {
        // A block ends at 10:05; from just above 10:00 the finger drags
        // down onto it.
        let m = mapping(edges: [at(605)])
        let down = m.range(anchorY: 597, currentY: 606)
        XCTAssertEqual(down.start, at(600))
        XCTAssertEqual(down.end, at(615))
        XCTAssertEqual(down.moving.edge, at(605))
        // From 10:15 up onto it: the finger's end is held on the edge, and
        // the minimum grows upward, away from the press.
        let up = m.range(anchorY: 615, currentY: 604)
        XCTAssertEqual(up.end, at(615))
        XCTAssertEqual(up.start, at(600))
    }

    func testTheRangeStaysInsideTheDay() {
        let m = mapping()
        let top = m.range(anchorY: 2, currentY: -50)
        XCTAssertEqual(top.start, dayStart)
        XCTAssertEqual(top.end, at(15))
        let bottom = m.range(anchorY: 1438, currentY: 1500)
        XCTAssertEqual(bottom.end, dayEnd)
        XCTAssertEqual(bottom.start, at(1425))
    }

    func testThePressMayBeMagnetizedToo() {
        // Pressing just under a block's end starts the draft on that end.
        let m = mapping(edges: [at(610)])
        let r = m.range(anchorY: 612, currentY: 700)
        XCTAssertEqual(r.start, at(610))
        XCTAssertEqual(r.end, at(705))
    }

    func testAPressInsideABlockIsNotEmptyTime() {
        let m = mapping()
        let blocks = [block(600, 660)]
        XCTAssertFalse(m.isEmpty(atY: 630, blocks: blocks))
        XCTAssertFalse(m.isEmpty(atY: 600, blocks: blocks))
        XCTAssertTrue(m.isEmpty(atY: 660, blocks: blocks), "a block's end is free time")
        XCTAssertTrue(m.isEmpty(atY: 599, blocks: blocks))
    }

    /// The watch's real geometry: thirty-four points an hour.
    func testAtWatchScaleEachGridStepIsAboutEightPoints() {
        let m = WristDraftMapping(dayStart: dayStart, dayEnd: dayEnd, height: 34 * 24, edges: [])
        let ticks = Set(stride(from: 340.0, through: 374.0, by: 1).map { m.point(atY: $0).time })
        XCTAssertEqual(ticks, [at(600), at(615), at(630), at(645), at(660)])
    }
}
