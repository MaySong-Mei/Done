import XCTest
@testable import Done

/// Independent QA of the watch's "Tap a Block" setting
/// (`WristLocalSettings.TapMode`, ebd77d2c) and of how the bottom card's
/// End earlier / End later meets the event page's turn on the same event
/// (`WristEndCrownSession`). Expected values are derived from the spec in
/// the commit message, not from the implementation.
@MainActor
final class WristTapModeQATests: XCTestCase {

    // MARK: Stored value

    /// Select unless exactly "card" is stored: nothing, empty, unknown,
    /// another casing or stray whitespace all read as Select Only.
    func testOnlyTheExactCardValueOpensTheCard() {
        let reads: [(String?, WristLocalSettings.TapMode)] = [
            (nil, .select), ("", .select), ("sheet", .select), ("Card", .select), ("CARD", .select),
            (" card", .select), ("card ", .select), ("card\n", .select), ("select", .select),
            ("large", .select), ("card", .card),
        ]
        for (stored, expected) in reads {
            XCTAssertEqual(WristLocalSettings.TapMode(stored: stored), expected, "stored \(String(reflecting: stored))")
        }
    }

    /// The stored strings and the debug argument's words are the same
    /// strings: a launch with `-wristTapMode card` stores what the row
    /// itself would store, and an older build's "select"/"card" still reads.
    func testRawValuesArePinned() {
        XCTAssertEqual(WristLocalSettings.TapMode.select.rawValue, "select")
        XCTAssertEqual(WristLocalSettings.TapMode.card.rawValue, "card")
        XCTAssertEqual(WristLocalSettings.TapMode(rawValue: "card"), .card)
        XCTAssertNil(WristLocalSettings.TapMode(rawValue: "Card"), "the debug argument ignores an unknown word")
        for mode in WristLocalSettings.TapMode.allCases {
            XCTAssertEqual(WristLocalSettings.TapMode(stored: mode.rawValue), mode, "round trip \(mode)")
        }
    }

    /// The `@AppStorage` default (`standard.rawValue`) reads back as Select
    /// Only, and Select Only is first in the order the row cycles.
    func testTheDefaultIsSelectOnly() {
        XCTAssertEqual(WristLocalSettings.TapMode(stored: WristLocalSettings.TapMode.standard.rawValue), .select)
        XCTAssertEqual(WristLocalSettings.TapMode.allCases.first, .select)
        XCTAssertEqual(WristLocalSettings.TapMode.allCases.count, 2, "the row cycles two values")
    }

    /// Its own key, shared with no other watch-local or protocol value.
    func testTheKeyIsItsOwn() {
        XCTAssertEqual(WristLocalSettings.tapModeKey, "wrist.tapMode")
        let others = [
            WristLocalSettings.zoomKey, WristLocalSettings.statsPeriodKey,
            "wrist.gestureLog", // WristGestureTrail.enabledKey (watch target only)
            WristWire.snapshotKey, WristWire.commandKey,
        ]
        XCTAssertFalse(others.contains(WristLocalSettings.tapModeKey))
    }

    // MARK: Card and event page on one event

    /// 2026-03-10 00:00 UTC.
    private static let dayStart = Date(timeIntervalSince1970: 1_773_100_800)
    private static let dayEnd = dayStart.addingTimeInterval(86_400)
    private static func at(_ h: Int, _ m: Int) -> Date { dayStart.addingTimeInterval(Double(h * 3600 + m * 60)) }
    private static let eventID = UUID()

    private static func subject(end: Date) -> (WristEventSubject, WristEndCrown.Availability) {
        let start = at(10, 0)
        let occurrence = WristOccurrence(
            id: "\(eventID.uuidString)@\(start.timeIntervalSince1970)", eventID: eventID, title: "e", type: "t",
            colorHex: "#000000", start: start, end: end, isInterrupt: false,
            quickActionsEnabled: true, isOpenEnded: false
        )
        let subject = WristEventSubject(source: .selected, occurrence: occurrence, key: "\(eventID.uuidString)#0", isRunning: false)
        let availability = WristEndCrown.availability(
            start: start, end: end, isOpenEnded: false, quickActionsEnabled: true, isRunning: false,
            takesRangeEdits: true, dayStart: dayStart, dayEnd: dayEnd, now: dayStart, edges: []
        )
        return (subject, availability)
    }

    /// Event 10:00–11:00. On the event page, + once: 11:15 is sent (the
    /// page left for Today sends it). On Today's card, End later: the day
    /// now shows 11:30 (both commands overlaid in order). The page follows
    /// the day: 11:30, nothing more to send. (Positive control for the
    /// next test: here the card went the same way the page did.)
    func testACardEditTheSameWayAsThePagesSendIsShownOnThePage() {
        var session = WristEndCrownSession()
        let (s0, a0) = Self.subject(end: Self.at(11, 0))
        session.show(s0, availability: a0)
        XCTAssertEqual(session.turn(crownDelta: WristEndCrown.crownLater)?.moved, true)
        XCTAssertEqual(session.takeUnsent(now: Self.at(9, 0))?.end, Self.at(11, 15))
        // The page's send overlaid.
        let (s1, a1) = Self.subject(end: Self.at(11, 15))
        session.show(s1, availability: a1)
        // The card's End later overlaid on top.
        let (s2, a2) = Self.subject(end: Self.at(11, 30))
        session.show(s2, availability: a2)
        XCTAssertEqual(session.shownEnd, Self.at(11, 30))
        XCTAssertNil(session.takeUnsent(now: Self.at(9, 0)))
    }

    /// Event 10:00–11:00. On the event page, − once: 10:45 is sent. Before
    /// the phone answers, Today's card End later computes from the overlaid
    /// 10:45 and sends 11:00. The page must show 11:00 — the newest command —
    /// not hold its own 10:45 as "sent, not yet on the day": its send was
    /// overlaid at once, so it is already on the day and the turn starts over
    /// from each later end. Nothing is re-sent, and the phone's answer
    /// changes nothing.
    func testACardEditAgainstThePagesSendIsShownOnThePage() {
        var session = WristEndCrownSession()
        let (s0, a0) = Self.subject(end: Self.at(11, 0))
        session.show(s0, availability: a0)
        XCTAssertEqual(session.turn(crownDelta: -WristEndCrown.crownLater)?.moved, true)
        XCTAssertEqual(session.takeUnsent(now: Self.at(9, 0))?.end, Self.at(10, 45))
        let (s1, a1) = Self.subject(end: Self.at(10, 45))
        session.show(s1, availability: a1)
        // Card: End later from the overlaid 10:45.
        let (s2, a2) = Self.subject(end: Self.at(10, 45).addingTimeInterval(WristTiming.extendStep))
        session.show(s2, availability: a2)
        XCTAssertNil(session.takeUnsent(now: Self.at(9, 0)), "nothing is re-sent")
        XCTAssertEqual(session.shownEnd, Self.at(11, 0), "the page shows the newest command's end")
        XCTAssertEqual(session.crown?.inFlight, false, "no superseded end is held as in flight")
        XCTAssertEqual(session.crown?.hasUnsent, false)
        session.settle(pendingEventIDs: [])
        XCTAssertEqual(session.shownEnd, Self.at(11, 0))
    }
}
