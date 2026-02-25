import XCTest
@testable import Done

final class EventAgenticIntakeCodableTests: XCTestCase {
    func testDecodesLegacyEventWithoutLocationOrAgenticIntake() throws {
        let original = Event(title: "Legacy", note: "note")
        let encoded = try JSONEncoder().encode(original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "location")
        json.removeValue(forKey: "agenticIntake")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Event.self, from: legacyData)
        XCTAssertEqual(decoded.title, "Legacy")
        XCTAssertEqual(decoded.note, "note")
        XCTAssertEqual(decoded.location, "")
        XCTAssertNil(decoded.agenticIntake)
    }

    func testRoundTripPersistsLocationAndAgenticIntake() throws {
        let intake = AgenticIntakeRecord(
            rawText: "开会讨论路线图",
            images: [AgenticIntakeImageRef(relativePath: "abc/img.jpg", pixelWidth: 100, pixelHeight: 80, fileSizeBytes: 2048)],
            source: .quickAdd,
            providerMetadata: AgenticProviderMetadata(provider: "openai", model: "gpt-4o", usedVision: true),
            warnings: ["vision ok"]
        )
        let event = Event(
            title: "Roadmap Sync",
            note: "AI generated",
            location: "Meeting Room A",
            startTime: Date(),
            endTime: Date().addingTimeInterval(3600),
            timeRanges: [],
            agenticIntake: intake
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(Event.self, from: data)

        XCTAssertEqual(decoded.location, "Meeting Room A")
        XCTAssertEqual(decoded.agenticIntake?.rawText, "开会讨论路线图")
        XCTAssertEqual(decoded.agenticIntake?.images.count, 1)
        XCTAssertEqual(decoded.agenticIntake?.providerMetadata?.provider, "openai")
        XCTAssertEqual(decoded.agenticIntake?.providerMetadata?.usedVision, true)
    }
}
