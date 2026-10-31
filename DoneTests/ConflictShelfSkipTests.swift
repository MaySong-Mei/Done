//
//  ConflictShelfSkipTests.swift
//  DoneTests
//
//  The read-only shelf queries pass over the one-row tables' lines without
//  parsing them (`ConflictShelf.entries(skippingTables:)`). Held here to
//  the reference — parse every line, then filter — line shapes chosen to
//  fool a byte-level read: a row that carries `"table":"…"` or
//  `"offered":true` itself, escapes and unicode, an escaped table name,
//  corrupt lines (one with a convincing tail), a duplicate key, another key
//  order, blank and CRLF lines, a last line without its newline, and a
//  multi-megabyte one-row line. Every `mine()` consumer of `SyncRecovery`
//  runs on two copies of the same file, one with the fast path and one
//  without, and must answer and write the same; `rewrite` after a fast
//  read leaves every one-row line byte for byte.
//

import XCTest
@testable import Done

@MainActor
final class ConflictShelfSkipTests: XCTestCase {

    private let me = "5a5a5a5a-0000-4000-8000-0000000000b1"
    private let other = "5a5a5a5a-0000-4000-8000-0000000000b2"
    private var scratch: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        scratch = []
        suites = []
        super.tearDown()
    }

    // MARK: - Fixture lines

    private func line(_ entry: ConflictShelfEntry) throws -> Data {
        try XCTUnwrap(entry.jsonLine(), "fixture: \(entry.table) encodes")
    }

    private func catchup(_ table: String, id: String, seq: Int64, uid: String? = nil, row: [String: Any],
                         offered: Bool = false, localClean: Bool = false) -> ConflictShelfEntry {
        ConflictShelfEntry(uid: uid ?? me, table: table, id: id, seq: seq, reason: .catchup, row: row,
                           against: .init(seq: seq, vid: nil), localClean: localClean, catchup: true, offered: offered)
    }

    /// A one-row line whose row is `megabytes` of content.
    private func largeSingletonRow(megabytes: Int) -> [String: Any] {
        let filler = String(repeating: "projection 漢字 ", count: megabytes * 1024 * 1024 / 18)
        return ["user_id": me, "rules": [["lastUsedAt": 802_000_000.123456, "weight": 0.1, "id": "r1"]],
                "token_projections": [["reasoningSummary": filler, "tokenAfter": 61.25]]]
    }

    /// The adversarial shelf, as bytes, and each line with whether the fast
    /// path should settle it without parsing.
    private func adversarialShelf() throws -> (data: Data, sniffable: Int, lines: [(line: Data, skipped: Bool)]) {
        var lines: [(line: Data, skipped: Bool)] = []
        func add(_ data: Data, sniffable isSniffable: Bool = false) {
            lines.append((data, isSniffable))
        }
        let rowWithEscapes: [String: Any] = ["title": "quote \" backslash \\ slash / tab \t 漢字 🚀 \u{0001}",
                                             "note": "\\\"table\\\":\\\"agent_preferences\\\""]
        // An offered, undecided id-table line with escapes and unicode.
        add(try line(catchup("calendar_events", id: "E1", seq: 3, row: rowWithEscapes, offered: true)))
        // A catch-up candidate the prompt has not judged yet.
        add(try line(catchup("calendar_events", id: "E2", seq: 4, row: ["title": "Candidate"])))
        // An id-table line whose ROW names a one-row table and a uid.
        add(try line(catchup("calendar_events", id: "E3", seq: 5,
                             row: ["title": "Names a singleton", "table": "agent_preferences", "uid": me], offered: true)))
        // A one-row line whose row names an id table and carries
        // `"offered":true`: a second `"table"`, so it is parsed.
        add(try line(catchup("agent_preferences", id: me, seq: 6,
                             row: ["table": "calendar_events", "offered": true, "title": "not a title"])))
        // One already marked offered by an earlier build: never counted.
        add(try line(catchup("agent_preferences", id: me, seq: 7, row: ["user_id": me], offered: true)), sniffable: true)
        add(try line(catchup("user_settings", id: me, seq: 8, row: ["settings": ["a": 1]], offered: true)), sniffable: true)
        add(try line(catchup("agent_conversations", id: me, seq: 9, row: ["conversations": []], offered: true)),
            sniffable: true)
        // The large one-row line.
        let large = try line(catchup("agent_preferences", id: me, seq: 10, row: largeSingletonRow(megabytes: 3), offered: true))
        add(large, sniffable: true)
        // Corrupt: the large line cut in half.
        add(large.prefix(large.count / 2))
        // Corrupt, with a tail that reads like a one-row line.
        add(Data(#"{not json at all,"table":"agent_preferences","uid":"\#(me)"}"#.utf8), sniffable: true)
        // Corrupt, with a tail that reads like an id-table line.
        add(Data(#"{broken,"table":"calendar_events","uid":"\#(me)"}"#.utf8))
        // An escaped one-row table name: excluded, but only a parse can say so.
        let escaped = String(decoding: try line(catchup("agent_preferences", id: me, seq: 11, row: ["x": 1], offered: true)),
                             as: UTF8.self)
            .replacingOccurrences(of: #""table":"agent_preferences""#, with: #""table":"agent\u005fpreferences""#)
        add(Data(escaped.utf8))
        // An escaped id-table name, offered: kept.
        let escapedId = String(decoding: try line(catchup("calendar_events", id: "E4", seq: 12, row: ["title": "Escaped"],
                                                          offered: true)), as: UTF8.self)
            .replacingOccurrences(of: #""table":"calendar_events""#, with: #""table":"calendar\u005fevents""#)
        add(Data(escapedId.utf8))
        // A duplicate top-level key, the one-row table last: a parser keeps
        // the first, so only a parse can say.
        add(Data(#"{"catchup":true,"id":"E5","offered":true,"reason":"catchup","row":{},"seq":13,"table":"calendar_events","uid":"\#(me)","table":"agent_preferences","uid":"\#(me)"}"#.utf8))
        // The same with the first key escaped.
        add(Data(#"{"catchup":true,"id":"E10","offered":true,"reason":"catchup","row":{},"seq":20,"t\u0061ble":"calendar_events","table":"agent_preferences","uid":"\#(me)"}"#.utf8))
        // A one-row line whose row holds a `\u` escape: parsed.
        add(try line(catchup("agent_preferences", id: me, seq: 21, row: ["note": "bell \u{0007}"], offered: true)))
        // Another key order: a one-row line with uid before table.
        add(Data(#"{"uid":"\#(me)","id":"\#(me)","reason":"catchup","row":{},"seq":14,"offered":true,"catchup":true,"table":"agent_preferences"}"#.utf8))
        // An escaped quote inside the uid.
        add(Data(#"{"catchup":true,"id":"E6","offered":true,"reason":"catchup","row":{},"seq":15,"table":"agent_preferences","uid":"x\"y"}"#.utf8))
        // Blank lines.
        add(Data())
        add(Data())
        // A CRLF id-table line, offered.
        var crlf = try line(catchup("calendar_events", id: "E7", seq: 16, row: ["title": "CRLF"], offered: true))
        crlf.removeLast()
        crlf.append(contentsOf: [0x0D])
        add(crlf)
        // Another account's lines.
        add(try line(catchup("calendar_events", id: "E8", seq: 17, uid: other, row: ["title": "Theirs"], offered: true)))
        add(try line(catchup("agent_preferences", id: other, seq: 18, uid: other, row: ["user_id": other], offered: true)),
            sniffable: true)
        // The last line, offered, without its newline.
        var last = try line(catchup("calendar_events", id: "E9", seq: 19, row: ["title": "Last"], offered: true))
        last.removeLast()

        var data = Data()
        for piece in lines.map(\.line) {
            data.append(piece)
            if piece.last != 0x0A { data.append(0x0A) }
        }
        data.append(last)
        lines.append((last, false))
        return (data, lines.filter(\.skipped).count, lines)
    }

    private func shelf(with data: Data, fastPath: Bool) throws -> ConflictShelf {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConflictShelfSkipTests-\(UUID().uuidString)", isDirectory: true)
        scratch.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let shelf = ConflictShelf(directory: directory)
        try data.write(to: shelf.fileURL)
        shelf.skipsLinesUnparsed = fastPath
        return shelf
    }

    private func bytes(_ entries: [ConflictShelfEntry]) -> [Data] {
        entries.map { $0.jsonLine() ?? Data("unencodable".utf8) }
    }

    // MARK: - The shelf

    /// Line by line: what the fast path settles is what the fixture says it
    /// can, and what it settles agrees with a parse.
    func testEachFixtureLineIsSettledOrParsedAsExpected() throws {
        let singletons = SupabaseSyncService.singletonTables
        for (index, fixture) in try adversarialShelf().lines.enumerated() where !fixture.line.isEmpty {
            var body = fixture.line
            if body.last == 0x0A { body.removeLast() }
            let sniffed: String? = body.withUnsafeBytes { raw in
                ConflictShelf.sniffedTable(raw).map { String(decoding: $0, as: UTF8.self) }
            }
            let skipped = sniffed.map(singletons.contains) ?? false
            XCTAssertEqual(skipped, fixture.skipped, "line \(index): sniffed \(sniffed ?? "nil")")
            if let sniffed, let parsed = ConflictShelfEntry(jsonLine: body) {
                XCTAssertEqual(parsed.table, sniffed, "line \(index): a settled line names the table a parse reads")
            }
        }
    }

    /// Fast path vs parse-everything-then-filter, at the shelf: the same
    /// entries in the same order, and the fast path parsed only what it
    /// could not settle.
    func testTheFastPathReturnsExactlyTheFilteredFullParse() throws {
        let fixture = try adversarialShelf()
        let fast = try shelf(with: fixture.data, fastPath: true)
        let singletons = SupabaseSyncService.singletonTables

        let read = fast.entries(skippingTables: singletons)
        let reference = fast.entries().filter { !singletons.contains($0.table) }

        XCTAssertEqual(bytes(read.entries), bytes(reference))
        XCTAssertFalse(reference.isEmpty, "fixture")
        XCTAssertEqual(read.stats.lines, fixture.data.split(separator: 0x0A).count)
        XCTAssertEqual(read.stats.skipped, fixture.sniffable, "every conclusive one-row line, and only those")
        XCTAssertEqual(read.stats.parsed, read.stats.lines - read.stats.skipped)
        XCTAssertEqual(read.stats.bytes, fixture.data.count)

        let slow = try shelf(with: fixture.data, fastPath: false).entries(skippingTables: singletons)
        XCTAssertEqual(bytes(slow.entries), bytes(reference), "the reference switch is the reference")
        XCTAssertEqual(slow.stats.skipped, 0)
    }

    /// Positive control: the large one-row line is really there, parsed,
    /// in the full read — the fast path left it out, it did not lose it.
    func testTheSkippedLinesAreStillOnTheShelfForEveryOtherReader() throws {
        let fixture = try adversarialShelf()
        let fast = try shelf(with: fixture.data, fastPath: true)
        _ = fast.entries(skippingTables: SupabaseSyncService.singletonTables)
        let all = fast.entries()
        XCTAssertEqual(all.filter { $0.table == "agent_preferences" && $0.seq == 10 }.count, 1)
        XCTAssertGreaterThan(fixture.data.count, 3_000_000)
        XCTAssertEqual(try Data(contentsOf: fast.fileURL), fixture.data, "a read writes nothing")
    }

    // MARK: - Every mine() consumer

    private struct Rig {
        let server: SyncFakeServer
        let service: SupabaseSyncService
        let shelf: ConflictShelf
        let recovery: SyncRecovery
    }

    private func rig(_ data: Data, fastPath: Bool) throws -> Rig {
        let suite = "ConflictShelfSkipTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let server = SyncFakeServer(userId: me)
        let service = SupabaseSyncService(gateway: server, userId: me, defaults: defaults)
        let shelf = try shelf(with: data, fastPath: fastPath)
        return Rig(server: server, service: service, shelf: shelf,
                   recovery: SyncRecovery(engine: service, gateway: server, shelf: shelf))
    }

    private func describe(_ prompt: SyncRecoveryPrompt?) -> String {
        guard let prompt else { return "nil" }
        let items = prompt.items.map { "\($0.id)|\($0.table)|\($0.rowId)|\($0.title)|\($0.serverHasRow)" }
        return "\(prompt.count) \(prompt.leaseFailedCount) \(items)"
    }

    private func file(_ rig: Rig) throws -> Data {
        try Data(contentsOf: rig.shelf.fileURL)
    }

    func testEveryRecoveryQueryAnswersTheSameWithAndWithoutTheFastPath() async throws {
        let data = try adversarialShelf().data
        let fast = try rig(data, fastPath: true)
        let slow = try rig(data, fastPath: false)

        XCTAssertEqual(bytes(fast.recovery.undecidedOffers), bytes(slow.recovery.undecidedOffers))
        XCTAssertFalse(slow.recovery.undecidedOffers.isEmpty, "fixture")
        XCTAssertEqual(bytes(fast.recovery.undecidedOffers(uid: other)), bytes(slow.recovery.undecidedOffers(uid: other)))
        XCTAssertEqual(slow.recovery.undecidedOffers(uid: other).count, 1, "fixture")
        XCTAssertEqual(fast.recovery.hasUndecidedOffers, slow.recovery.hasUndecidedOffers)
        fast.recovery.refreshBadge()
        slow.recovery.refreshBadge()
        XCTAssertEqual(fast.service.pendingPromptCount, slow.service.pendingPromptCount)
        XCTAssertEqual(describe(fast.recovery.buildPrompt()), describe(slow.recovery.buildPrompt()))

        let fastPrompt = await fast.recovery.computeOffers()
        let slowPrompt = await slow.recovery.computeOffers()
        XCTAssertNotNil(slowPrompt, "fixture: the candidate is offered")
        XCTAssertEqual(describe(fastPrompt), describe(slowPrompt))
        XCTAssertEqual(try file(fast), try file(slow), "the rewrite wrote the same file")
        XCTAssertEqual(fast.service.pendingPromptCount, slow.service.pendingPromptCount)
        XCTAssertEqual(describe(fast.recovery.presentAgain()), describe(slow.recovery.presentAgain()))
    }

    func testDiscardAndAcceptActOnTheSameLinesWithAndWithoutTheFastPath() async throws {
        let data = try adversarialShelf().data
        for action in ["discard", "accept"] {
            let fast = try rig(data, fastPath: true)
            let slow = try rig(data, fastPath: false)
            if action == "discard" {
                let discarded = slow.recovery.discard()
                XCTAssertEqual(fast.recovery.discard(), discarded)
                XCTAssertGreaterThan(discarded, 0, "fixture")
                XCTAssertTrue(slow.recovery.undecidedOffers.isEmpty, "fixture: every offer decided")
            } else {
                let fastResult = await fast.recovery.accept()
                let slowResult = await slow.recovery.accept()
                XCTAssertEqual(fastResult, slowResult)
                XCTAssertFalse(slow.server.requests.isEmpty, "fixture: write-backs went out")
                XCTAssertEqual(fast.server.requests.map { "\($0.verb) \($0.table) \($0.keys)" },
                               slow.server.requests.map { "\($0.verb) \($0.table) \($0.keys)" })
            }
            XCTAssertEqual(try file(fast), try file(slow), "\(action): the same file")
        }
    }

    // MARK: - rewrite after a fast read

    /// A shelf of well-formed lines (the only kind `rewrite` keeps): after
    /// the fast queries and the three rewrites the prompt makes, every
    /// one-row line is on the shelf byte for byte, the large one included.
    func testRewriteAfterAFastReadKeepsEveryOneRowLineByteForByte() async throws {
        var data = Data()
        let singletonLines = [
            try line(catchup("agent_preferences", id: me, seq: 2, row: largeSingletonRow(megabytes: 2), offered: true)),
            try line(catchup("agent_preferences", id: me, seq: 3,
                             row: ["table": "calendar_events", "offered": true, "note": "quote \" 漢字 🚀"])),
            try line(catchup("user_settings", id: me, seq: 4, row: ["settings": ["k": 0.1, "z": [1, 2]]])),
            try line(catchup("agent_conversations", id: me, seq: 5, row: ["conversations": [["t": "x"]]], offered: true)),
        ]
        let idLines = [
            try line(catchup("calendar_events", id: "E1", seq: 6, row: ["title": "Candidate"])),
            try line(catchup("calendar_events", id: "E2", seq: 7, row: ["title": "Offered"], offered: true)),
        ]
        for piece in singletonLines + idLines { data.append(piece) }
        let rig = try rig(data, fastPath: true)

        rig.recovery.refreshBadge()
        let offered = await rig.recovery.computeOffers()
        XCTAssertNotNil(offered, "fixture: a rewrite marks the candidate offered")
        XCTAssertGreaterThan(rig.recovery.discard(), 0, "fixture: a rewrite marks the offers discarded")

        let after = try file(rig).split(separator: 0x0A).map { Data($0) + Data([0x0A]) }
        XCTAssertNotEqual(after.filter { idLines.contains($0) }.count, idLines.count, "positive control: the id lines changed")
        for (index, singleton) in singletonLines.enumerated() {
            XCTAssertEqual(after.filter { $0 == singleton }.count, 1, "one-row line \(index) byte for byte")
        }
        XCTAssertEqual(after.count, singletonLines.count + idLines.count, "no line dropped")
    }

    // MARK: - The trail at session start

    func testTheSessionStartLeavesTheShelfReadOnTheTrail() throws {
        let fixture = try adversarialShelf()
        let suite = "ConflictShelfSkipTests-\(UUID().uuidString)"
        let location = TestStorage.reset(suite)
        defer { TestStorage.tearDown(suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let store = EventStore(defaults: defaults, storage: location, seedsSampleDataIfEmpty: false)
        let server = SyncFakeServer(userId: me)
        let service = SupabaseSyncService(gateway: server.connection(), userId: me, defaults: defaults,
                                          scheduler: SyncManualScheduler())
        service.attachStores(eventStore: store, eventTypeStore: nil, skillStore: nil, preferenceStore: nil)
        let shelf = try shelf(with: fixture.data, fastPath: true)
        let puller = service.installInbound(shelf: shelf)
        puller.observesForeground = false
        puller.headFlag = SyncHeadFlag()
        let lines = fixture.data.split(separator: 0x0A).count
        let expected = "sync.shelf.read lines=\(lines) skipped=\(fixture.sniffable) parsed=\(lines - fixture.sniffable) bytes=\(fixture.data.count) ms="
        let before = DiagnosticTrail.combinedText().components(separatedBy: expected).count

        puller.beginSession(autoPull: false)
        defer { puller.endSession() }

        XCTAssertEqual(DiagnosticTrail.combinedText().components(separatedBy: expected).count, before + 1)
        XCTAssertEqual(service.pendingPromptCount, SyncRecovery(engine: service, gateway: server, shelf: shelf).undecidedOffers.count)
    }
}
