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
            warnings: ["vision ok"],
            processingPhase: .failed,
            failureMessage: "Network timeout"
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
        XCTAssertEqual(decoded.agenticIntake?.processingPhase, .failed)
        XCTAssertEqual(decoded.agenticIntake?.failureMessage, "Network timeout")
    }

    func testLegacyAgenticIntakeDefaultsProcessingPhaseToCompleted() throws {
        let intake = AgenticIntakeRecord(
            rawText: "legacy intake",
            source: .quickAdd
        )
        let event = Event(
            title: "Legacy Intake Event",
            startTime: Date(),
            endTime: Date().addingTimeInterval(1800),
            timeRanges: [],
            agenticIntake: intake
        )

        let encoded = try JSONEncoder().encode(event)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var intakeJSON = try XCTUnwrap(json["agenticIntake"] as? [String: Any])
        intakeJSON.removeValue(forKey: "processingPhase")
        intakeJSON.removeValue(forKey: "processingUpdatedAt")
        intakeJSON.removeValue(forKey: "failureMessage")
        json["agenticIntake"] = intakeJSON
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(Event.self, from: legacyData)
        XCTAssertEqual(decoded.agenticIntake?.processingPhase, .completed)
        XCTAssertNil(decoded.agenticIntake?.failureMessage)
    }
}

final class SkillAnalysisServiceTests: XCTestCase {
    func testSkipsAgenticAnalyzingEvent() {
        XCTAssertTrue(skillAnalysisShouldSkipForAgenticProcessing(makeEvent(processingPhase: .analyzing)))
    }

    func testSkipsAgenticFailedEvent() {
        XCTAssertTrue(skillAnalysisShouldSkipForAgenticProcessing(makeEvent(processingPhase: .failed)))
    }

    func testCompletedAgenticEventDoesNotSkip() {
        XCTAssertFalse(skillAnalysisShouldSkipForAgenticProcessing(makeEvent(processingPhase: .completed)))
    }

    func testNonAgenticEventDoesNotSkip() {
        let now = Date()
        let event = Event(
            title: "Normal Event",
            startTime: now.addingTimeInterval(-1800),
            endTime: now,
            timeRanges: [Event.TimeRange(start: now.addingTimeInterval(-1800), end: now)],
            type: "Work"
        )
        XCTAssertFalse(skillAnalysisShouldSkipForAgenticProcessing(event))
    }

    private func makeEvent(processingPhase: AgenticIntakeProcessingPhase) -> Event {
        let now = Date()
        let intake = AgenticIntakeRecord(
            rawText: "placeholder",
            source: .quickAdd,
            processingPhase: processingPhase,
            failureMessage: processingPhase == .failed ? "no key" : nil
        )
        return Event(
            title: "Test Event",
            note: "",
            startTime: now.addingTimeInterval(-1800),
            endTime: now,
            timeRanges: [Event.TimeRange(start: now.addingTimeInterval(-1800), end: now)],
            type: "Work",
            agenticIntake: intake
        )
    }
}
