import XCTest
@testable import Done

/// The phone↔watch wire contract: round trips, forward-compatible decoding,
/// and the content equality the phone uses to skip redundant pushes.
@MainActor
final class WristProtocolTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func sampleSnapshot() -> WristSnapshot {
        WristSnapshot(
            generatedAt: t0,
            language: "zh",
            types: [WristType(id: UUID(), title: "Research", colorHex: "#0A84FF")],
            occurrences: [
                WristOccurrence(
                    id: "occ-1", eventID: UUID(), title: "Paper", type: "Research", colorHex: "#0A84FF",
                    start: t0, end: t0.addingTimeInterval(1800), isInterrupt: false, quickActionsEnabled: true
                ),
            ],
            receipts: [WristReceipt(id: UUID(), outcome: .rejected, reason: "recurring")]
        )
    }

    func testSnapshotRoundTrips() throws {
        let snapshot = sampleSnapshot()
        let data = try WristWire.encode(snapshot)
        let decoded = try WristWire.decode(WristSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testEveryCommandKindRoundTrips() throws {
        let commands = [
            WristCommand(id: UUID(), issuedAt: t0, kind: .start(eventID: UUID(), typeTitle: "Gym", start: t0, end: t0.addingTimeInterval(1800))),
            WristCommand(id: UUID(), issuedAt: t0, kind: .finish(eventID: UUID(), rangeStart: t0, at: t0.addingTimeInterval(60))),
            WristCommand(id: UUID(), issuedAt: t0, kind: .extend(eventID: UUID(), rangeStart: nil, by: -900)),
        ]
        for command in commands {
            let decoded = try WristWire.decode(WristCommand.self, from: try WristWire.encode(command))
            XCTAssertEqual(decoded, command)
        }
    }

    func testCommandEventIDMatchesEveryKind() {
        let eventID = UUID()
        XCTAssertEqual(WristCommand(id: UUID(), issuedAt: t0, kind: .start(eventID: eventID, typeTitle: "x", start: t0, end: t0)).eventID, eventID)
        XCTAssertEqual(WristCommand(id: UUID(), issuedAt: t0, kind: .finish(eventID: eventID, rangeStart: nil, at: t0)).eventID, eventID)
        XCTAssertEqual(WristCommand(id: UUID(), issuedAt: t0, kind: .extend(eventID: eventID, rangeStart: nil, by: 1)).eventID, eventID)
    }

    /// A snapshot written by a phone build that knew none of today's fields
    /// still decodes — every field is defaulted.
    func testEmptyObjectDecodesToDefaults() throws {
        let decoded = try WristWire.decode(WristSnapshot.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.version, 0)
        XCTAssertEqual(decoded.generatedAt, .distantPast)
        XCTAssertNil(decoded.language)
        XCTAssertTrue(decoded.types.isEmpty)
        XCTAssertTrue(decoded.occurrences.isEmpty)
        XCTAssertTrue(decoded.receipts.isEmpty)
    }

    /// A field a FUTURE phone build adds must not break today's watch.
    func testUnknownFieldsAreIgnored() throws {
        var object = try JSONSerialization.jsonObject(with: try WristWire.encode(sampleSnapshot())) as! [String: Any]
        object["futureField"] = ["anything": 1]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try WristWire.decode(WristSnapshot.self, from: data)
        XCTAssertEqual(decoded.types.count, 1)
        XCTAssertEqual(decoded.occurrences.count, 1)
    }

    func testHasSameContentIgnoresGeneratedAtOnly() {
        let a = sampleSnapshot()
        var b = a
        b.generatedAt = t0.addingTimeInterval(3600)
        XCTAssertTrue(a.hasSameContent(as: b))
        XCTAssertNotEqual(a, b)

        var c = a
        c.receipts = []
        XCTAssertFalse(a.hasSameContent(as: c))
        var d = a
        d.occurrences[0].end = d.occurrences[0].end.addingTimeInterval(900)
        XCTAssertFalse(a.hasSameContent(as: d))
        var e = a
        e.language = "en"
        XCTAssertFalse(a.hasSameContent(as: e))
    }

    /// An occurrence written before `isOpenEnded` existed still decodes, closed.
    func testOccurrenceWithoutOpenEndedFlagDecodesClosed() throws {
        var object = try JSONSerialization.jsonObject(with: try WristWire.encode(sampleSnapshot().occurrences[0])) as! [String: Any]
        object.removeValue(forKey: "isOpenEnded")
        let decoded = try WristWire.decode(WristOccurrence.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.isOpenEnded)
        XCTAssertEqual(decoded.title, "Paper")
    }

    func testRangeStartNamesTheRangeACommandEdits() {
        let start = WristCommand(id: UUID(), issuedAt: t0, kind: .start(eventID: UUID(), typeTitle: "x", start: t0, end: t0.addingTimeInterval(60)))
        XCTAssertEqual(start.rangeStart, t0)
        XCTAssertEqual(WristCommand(id: UUID(), issuedAt: t0, kind: .finish(eventID: UUID(), rangeStart: t0, at: t0)).rangeStart, t0)
        XCTAssertNil(WristCommand(id: UUID(), issuedAt: t0, kind: .extend(eventID: UUID(), rangeStart: nil, by: 1)).rangeStart)
    }

    func testEncodingIsDeterministic() throws {
        let snapshot = sampleSnapshot()
        XCTAssertEqual(try WristWire.encode(snapshot), try WristWire.encode(snapshot))
    }
}
