//
//  AgentConversationEncodingTests.swift
//  DoneTests
//
//  gh#257: the synced `agent_conversations` row must encode to the same bytes
//  for the same value, or the hash baseline sees a change on every launch and
//  re-uploads the whole history. `involvedEventIDs` (a Set) and
//  `involvedEventNames` (a UUID-keyed map, which encodes as a flat
//  [key, value, ...] array) both iterate in per-process hash order;
//  `.sortedKeys` orders object keys only.
//

import XCTest
@testable import Done

@MainActor
final class AgentConversationEncodingTests: XCTestCase {

    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: - Fixtures

    /// 20 fixed ids, deliberately NOT in sorted order as listed.
    private static let ids: [UUID] = (0..<20).map { i in
        // Scramble the leading byte so list order != uuidString order.
        let lead = String(format: "%02X", (i * 37 + 11) % 256)
        return UUID(uuidString: "\(lead)\(String(format: "%06X", i))-0000-4000-8000-\(String(format: "%012X", i * 7919))")!
    }

    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds the conversation by inserting the ids in `order`, into
    /// containers sized `capacity`. Different capacities give different bucket
    /// layouts, so the two builds iterate in different orders in THIS process —
    /// the per-launch reseed reproduced within one test run.
    private func conversation(order: [UUID], capacity: Int) -> AgentConversation {
        var set = Set<UUID>(minimumCapacity: capacity)
        var names = [UUID: String](minimumCapacity: capacity)
        for id in order {
            set.insert(id)
            names[id] = "Event \(id.uuidString.prefix(4))"
        }
        return AgentConversation(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            title: "Plan the week",
            createdAt: Self.date,
            updatedAt: Self.date,
            messages: [ChatMessage(id: UUID(uuidString: "66666666-7777-4888-9999-AAAAAAAAAAAA")!,
                                   role: .user, content: "hi", timestamp: Self.date,
                                   referencedEventIDs: Array(Self.ids.prefix(3)))],
            involvedEventIDs: set,
            involvedEventNames: names
        )
    }

    private func syncBytes(_ conversations: [AgentConversation]) throws -> Data {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AgentConversationEncodingTests-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)
        let repository = AgentConversationRepository(directory: directory, legacyDefaults: nil)
        repository.ensureLoaded()
        XCTAssertTrue(repository.replaceAll(conversations))
        return try XCTUnwrap(repository.encodedJSONForSync())
    }

    private func jsonObject(_ conversation: AgentConversation) throws -> [String: Any] {
        let data = try JSONEncoder().encode(conversation)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - (a) same value, two insertion orders → identical bytes and hash

    func testSameValueInTwoInsertionOrdersEncodesToIdenticalBytes() throws {
        let a = conversation(order: Self.ids, capacity: 0)
        let b = conversation(order: Self.ids.reversed(), capacity: 1024)
        XCTAssertEqual(a, b, "precondition: the two builds are the same value")
        // Positive control: the raw containers really do iterate differently,
        // so equal bytes below are the encoder's doing, not luck.
        XCTAssertNotEqual(Array(a.involvedEventIDs), Array(b.involvedEventIDs),
                          "control: the two sets must iterate in different orders for this test to bite")

        let bytesA = try syncBytes([a])
        let bytesB = try syncBytes([b])
        XCTAssertEqual(bytesA, bytesB)

        let rowA: [String: Any] = ["conversations": try JSONSerialization.jsonObject(with: bytesA)]
        let rowB: [String: Any] = ["conversations": try JSONSerialization.jsonObject(with: bytesB)]
        XCTAssertEqual(SupabaseSyncService.rowHash(rowA), SupabaseSyncService.rowHash(rowB))
    }

    // MARK: - (b) the id array is sorted; the map's keys appear sorted, same shape

    func testIDArrayIsSortedAndNameMapIsFlatArrayInSortedKeyOrder() throws {
        let object = try jsonObject(conversation(order: Self.ids.reversed(), capacity: 1024))
        let expected = Self.ids.map(\.uuidString).sorted()

        let idArray = try XCTUnwrap(object["involvedEventIDs"] as? [String], "Set must still encode as a JSON array of strings")
        XCTAssertEqual(idArray, expected)

        let flat = try XCTUnwrap(object["involvedEventNames"] as? [String],
                                 "UUID-keyed map must still encode as the flat [key, value, ...] array")
        XCTAssertEqual(flat.count, 40)
        let keys = stride(from: 0, to: flat.count, by: 2).map { flat[$0] }
        let values = stride(from: 1, to: flat.count, by: 2).map { flat[$0] }
        XCTAssertEqual(keys, expected)
        XCTAssertEqual(values, expected.map { "Event \($0.prefix(4))" })
    }

    // MARK: - (c) round trip

    func testRoundTripDecodesToEqualValue() throws {
        let original = conversation(order: Self.ids, capacity: 64)
        let decoded = try JSONDecoder().decode(AgentConversation.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)

        var untitled = original
        untitled.title = nil
        let object = try jsonObject(untitled)
        XCTAssertNil(object["title"], "nil title is omitted, as the synthesized encoder did")
        XCTAssertEqual(try JSONDecoder().decode(AgentConversation.self, from: JSONEncoder().encode(untitled)), untitled)
    }

    // MARK: - (d) a row written in the OLD (unsorted) order still decodes

    func testOldUnsortedFixtureStillDecodes() throws {
        let z = "FFFFFFFF-0000-4000-8000-000000000001"
        let m = "88888888-0000-4000-8000-000000000002"
        let a = "00000000-0000-4000-8000-000000000003"
        // Shape and order as the synthesized encoder could have written them.
        let fixture = """
        [{"createdAt":721692800,"id":"11111111-2222-4333-8444-555555555555",
          "involvedEventIDs":["\(z)","\(a)","\(m)"],
          "involvedEventNames":["\(m)","Gym","\(z)","Dentist","\(a)","Standup"],
          "messages":[{"content":"hi","id":"66666666-7777-4888-9999-AAAAAAAAAAAA",
                       "isLoading":false,"role":"user","timestamp":721692800}],
          "updatedAt":721692800}]
        """
        let decoded = try JSONDecoder().decode([AgentConversation].self, from: Data(fixture.utf8))
        let only = try XCTUnwrap(decoded.first)
        XCTAssertNil(only.title)
        XCTAssertEqual(only.involvedEventIDs, Set([z, m, a].map { UUID(uuidString: $0)! }))
        XCTAssertEqual(only.involvedEventNames, [
            UUID(uuidString: z)!: "Dentist",
            UUID(uuidString: m)!: "Gym",
            UUID(uuidString: a)!: "Standup",
        ])

        // Re-encoding the old row gives the sorted order.
        let object = try jsonObject(only)
        XCTAssertEqual(object["involvedEventIDs"] as? [String], [a, m, z])
        XCTAssertEqual(object["involvedEventNames"] as? [String], [a, "Standup", m, "Gym", z, "Dentist"])
    }

    // MARK: - Wire shape matches the synthesized encoder

    /// Field-for-field twin with the SYNTHESIZED Codable, i.e. what build 10
    /// and earlier wrote. Each side must decode the other's bytes.
    private struct SynthesizedTwin: Codable, Equatable {
        var id: UUID
        var title: String?
        var createdAt: Date
        var updatedAt: Date
        var messages: [ChatMessage]
        var involvedEventIDs: Set<UUID>
        var involvedEventNames: [UUID: String]
    }

    func testWireShapeMatchesSynthesizedEncoder() throws {
        let value = conversation(order: Self.ids, capacity: 0)
        let twin = SynthesizedTwin(id: value.id, title: value.title, createdAt: value.createdAt,
                                   updatedAt: value.updatedAt, messages: value.messages,
                                   involvedEventIDs: value.involvedEventIDs,
                                   involvedEventNames: value.involvedEventNames)
        let newBytes = try JSONEncoder().encode(value)
        let oldBytes = try JSONEncoder().encode(twin)
        XCTAssertEqual(try JSONDecoder().decode(SynthesizedTwin.self, from: newBytes), twin)
        XCTAssertEqual(try JSONDecoder().decode(AgentConversation.self, from: oldBytes), value)

        let newObject = try XCTUnwrap(JSONSerialization.jsonObject(with: newBytes) as? [String: Any])
        let oldObject = try XCTUnwrap(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
        XCTAssertEqual(Set(newObject.keys), Set(oldObject.keys))
        XCTAssertEqual((oldObject["involvedEventNames"] as? [String])?.count, 40,
                       "control: the synthesized encoder writes the UUID map as a flat array")
    }
}
