//
//  SyncProjectionSnapshotTests.swift
//  DoneTests
//
//  The mixed-version write-back tripwire (survey S13, gap G13). An older
//  build that PATCHes a whole row it decoded erases every column it does
//  not know, and an older build that meets an enum value it does not know
//  decodes a default and writes that back. So the field set the outbound
//  projection emits, and the raw values of every enum it serializes, are
//  pinned in `SyncProjectionSnapshot.json`. The snapshot changing is the
//  trigger for survey L3: update the file only in the same change that
//  ships L3's mechanism, or with the user's explicit waiver.
//
//  Enum cases are enumerated at runtime, not listed by hand, so a new case
//  turns this red without anyone remembering to add it here.
//

import XCTest
@testable import Done

@MainActor
final class SyncProjectionSnapshotTests: XCTestCase {

    static let failureMessage = "a synced field set changed — the mixed-version write-back guard (survey L3) must ship before this build"

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var service: SupabaseSyncService!

    override func setUp() {
        super.setUp()
        suiteName = "SyncProjectionSnapshotTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        service = SupabaseSyncService(gateway: SyncFakeServer(userId: "u"), userId: "u", defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private static var snapshotURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("SyncProjectionSnapshot.json")
    }

    // MARK: Runtime enumeration of a payload-free String enum

    /// Every case of a payload-free enum, by its tag. Such an enum is one
    /// byte holding the case index, and `Optional` spends the first unused
    /// index on `nil` — so walking the indices until `nil` visits exactly
    /// the declared cases. Guarded to the one-byte layout it relies on, and
    /// checked against `allCases` in the positive control below.
    static func everyCase<E: RawRepresentable>(of type: E.Type) -> [E] where E.RawValue == String {
        precondition(MemoryLayout<E>.size == 1 && MemoryLayout<E?>.size == 1,
                     "\(E.self) is not a one-byte payload-free enum; enumerate it another way")
        var out: [E] = []
        for tag in UInt8.min...UInt8.max {
            guard let value = unsafeBitCast(tag, to: E?.self) else { break }
            out.append(value)
        }
        return out
    }

    func testRuntimeEnumerationMatchesAllCasesWhereTheCompilerKnowsThem() {
        XCTAssertEqual(Self.everyCase(of: Event.Kind.self), Event.Kind.allCases)
        XCTAssertEqual(Self.everyCase(of: EventLogCompletionStatus.self), EventLogCompletionStatus.allCases)
    }

    // MARK: The projection as it is today

    private func sortedKeys(_ row: [String: Any]) -> [String] { row.keys.sorted() }

    private func currentProjection() throws -> [String: [String]] {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        var event = Event(title: "snapshot", timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
        event.interruptRelation = EventInterruptRelation(parentEventID: UUID(), occurrenceDate: start)
        let eventRow = service.eventToRow(event, kind: "calendar")
        let ranges = try XCTUnwrap(eventRow["time_ranges"] as? [[String: String]])
        let relation = try XCTUnwrap(eventRow["interrupt_relation"] as? [String: Any])

        let occurrence = CalendarOccurrenceKey.make(for: event, occurrenceDate: start)
        let log = CalendarEventLogRecord(id: occurrence, eventID: event.id, baseSeriesEventID: nil, occurrenceDate: start)
        let feedback = CalendarEventFeedbackRecord(id: occurrence, eventID: event.id, baseSeriesEventID: nil, occurrenceDate: start)
        let prefs = AgentPreferenceStore(
            directoryURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("SyncProjectionSnapshotTests-prefs-\(UUID().uuidString)", isDirectory: true))

        func cases<E: RawRepresentable>(_ type: E.Type) -> [String] where E.RawValue == String {
            Self.everyCase(of: type).map(\.rawValue).sorted()
        }

        return [
            "row.events": sortedKeys(eventRow),
            "row.events.time_ranges[]": sortedKeys(try XCTUnwrap(ranges.first)),
            "row.events.interrupt_relation": sortedKeys(relation),
            "row.event_logs": sortedKeys(service.logToRow(log)),
            "row.event_feedback": sortedKeys(service.feedbackToRow(feedback)),
            "row.todo_lists": sortedKeys(service.todoListToRow(TodoList(title: "l", colorName: "blue"))),
            "row.event_types": sortedKeys(service.eventTypeToRow(EventTypeTemplate(title: "t", colorHex: "#000000"))),
            "row.skill_insights": sortedKeys(service.skillToRow(SkillInsight(
                skillName: "s", points: 1, date: start, eventTitle: "e", reasoning: "r"))),
            "row.user_settings": sortedKeys(service.settingsRow([:])),
            "row.user_settings.settings": SyncedSettings.allKeys.sorted(),
            "row.agent_preferences": sortedKeys(service.agentPreferencesToRow(prefs)),
            "row.agent_conversations": sortedKeys(service.agentConversationsToRow()),

            "enum.Event.Status": cases(Event.Status.self),
            "enum.Event.RepeatUnit": cases(Event.RepeatUnit.self),
            "enum.Event.RepeatEndType": cases(Event.RepeatEndType.self),
            "enum.Event.Kind": cases(Event.Kind.self),
            "enum.EventDisplayKind": cases(EventDisplayKind.self),
            "enum.EventInterruptRelationState": cases(EventInterruptRelationState.self),
            "enum.SuggestedLogTemplateSource": cases(SuggestedLogTemplateSource.self),
            "enum.EventLogCompletionStatus": cases(EventLogCompletionStatus.self),
            "enum.CalendarOccurrenceKey.Kind": cases(CalendarOccurrenceKey.Kind.self),
        ]
    }

    private static func render(_ projection: [String: [String]]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: projection, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: The tripwire

    private static func loadPinned() -> [String: [String]]? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: [String]]
    }

    static func differences(_ current: [String: [String]], _ pinned: [String: [String]]) -> [String] {
        var out: [String] = []
        for name in Set(current.keys).union(pinned.keys).sorted() {
            let now = Set(current[name] ?? [])
            let then = Set(pinned[name] ?? [])
            guard now != then else { continue }
            out.append("\(name): added \(now.subtracting(then).sorted()), removed \(then.subtracting(now).sorted())")
        }
        return out
    }

    func testSyncedFieldSetsMatchTheSnapshot() throws {
        let current = try currentProjection()
        guard let pinned = Self.loadPinned() else {
            XCTFail("\(Self.snapshotURL.path) is missing or unreadable. Current projection:\n\(Self.render(current))")
            return
        }
        let differences = Self.differences(current, pinned)
        XCTAssert(differences.isEmpty, """
        \(Self.failureMessage). Update SyncProjectionSnapshot.json only together with L3's mechanism or the user's explicit waiver.
        \(differences.joined(separator: "\n"))
        Current projection:
        \(Self.render(current))
        """)
    }

    /// Positive control: the same comparison against the pinned file goes
    /// red for an added column, a removed column, and an added enum value.
    func testTheComparisonCatchesAddedAndRemovedColumnsAndAnAddedRawValue() throws {
        let pinned = try XCTUnwrap(Self.loadPinned())
        let current = try currentProjection()
        XCTAssertEqual(try currentProjection(), current, "the projection is stable across calls")

        var added = current
        added["row.todo_lists", default: []].append("sort_order")
        XCTAssertEqual(Self.differences(added, pinned).count, 1)
        XCTAssertTrue(Self.differences(added, pinned).first?.contains("sort_order") == true)

        var removed = current
        removed["row.events"]?.removeAll { $0 == "note" }
        XCTAssertEqual(Self.differences(removed, pinned).count, 1)

        var newCase = current
        newCase["enum.Event.Status", default: []].append("paused")
        XCTAssertEqual(Self.differences(newCase, pinned).count, 1)
    }
}
