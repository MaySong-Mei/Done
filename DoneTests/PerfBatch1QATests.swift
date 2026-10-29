//
//  PerfBatch1QATests.swift
//  DoneTests
//
//  Independent QA for perf batch 1 (branch perf/batch1): written by the QA
//  side of the loop, against the spec, not against the implementer's tests.
//
//  B — `ConflictShelf.entries(skippingTables:)` held to "parse every line,
//      then filter" on line shapes the implementer's fixture does not have
//      (a second `"table"` key past the first kilobytes, UTF-16 lines, a
//      BOM, NUL bytes, look-alike names, two JSON values on one line, …),
//      on seeded random shelves with byte-level damage, and — when
//      `QA_REAL_SHELF_PATH` is set — on a real shelf file, read only.
//  A — the agent_preferences upgrade transition on every (rules side ×
//      token side) a legacy baseline can name, what it keeps of the entry,
//      what it remembers when it misses; token columns never reaching a
//      hash; the bootstrap batch save on a full prediction horizon; and the
//      new `upsertProjection` against the old algorithm on random sequences.
//  C — `SettingsOrphanCleanup` at the 24 h boundary, all seven keys, and a
//      registered default.
//

import XCTest
@testable import Done

@MainActor
final class PerfBatch1QATests: XCTestCase {

    private static let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private let me = "9c9c9c9c-0000-4000-8000-0000000000d1"
    private var scratch: [URL] = []
    private var suites: [String] = []

    override func tearDown() {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        for suite in suites { TestStorage.tearDown(suite); UserDefaults().removePersistentDomain(forName: suite) }
        scratch = []
        suites = []
        super.tearDown()
    }

    private func scratchDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerfBatch1QA-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratch.append(url)
        return url
    }

    private func trailCount(_ needle: String) -> Int {
        DiagnosticTrail.combinedText().components(separatedBy: needle).count - 1
    }

    // MARK: - B. The shelf fast path

    private var singletons: Set<String> { SupabaseSyncService.singletonTables }

    private func sniff(_ line: Data) -> String? {
        line.withUnsafeBytes { raw in ConflictShelf.sniffedTable(raw).map { String(decoding: $0, as: UTF8.self) } }
    }

    private func shelf(_ data: Data, fastPath: Bool = true) throws -> ConflictShelf {
        let shelf = ConflictShelf(directory: scratchDirectory("shelf"))
        try data.write(to: shelf.fileURL)
        shelf.skipsLinesUnparsed = fastPath
        return shelf
    }

    /// The comparison the spec names: the same kept entries, in order,
    /// byte-identical when re-encoded, plus the fields `jsonLine` drops
    /// nothing of.
    private func assertSameEntries(_ fast: [ConflictShelfEntry], _ reference: [ConflictShelfEntry],
                                   _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fast.count, reference.count, "\(message): entry count", file: file, line: line)
        for (index, (a, b)) in zip(fast, reference).enumerated() {
            XCTAssertEqual(a.jsonLine(), b.jsonLine(), "\(message): entry \(index) bytes", file: file, line: line)
            XCTAssertEqual(a.dedupeKey, b.dedupeKey, "\(message): entry \(index) key", file: file, line: line)
            XCTAssertEqual(a.isUndecidedOffer, b.isUndecidedOffer, "\(message): entry \(index) offer", file: file, line: line)
        }
    }

    /// Fast path vs the reference, plus the line-level invariant: a line the
    /// fast path passes over is one a full parse drops or files under a
    /// one-row table. Returns how many lines it skipped.
    @discardableResult
    private func differential(_ lines: [Data], _ label: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        var data = Data()
        for piece in lines { data.append(piece); data.append(0x0A) }
        let fast = try shelf(data)
        let read = fast.entries(skippingTables: singletons)
        let reference = fast.entries().filter { !singletons.contains($0.table) }
        assertSameEntries(read.entries, reference, label, file: file, line: line)
        let slow = try shelf(data, fastPath: false).entries(skippingTables: singletons)
        assertSameEntries(slow.entries, reference, "\(label) (switch off)", file: file, line: line)
        for (index, piece) in lines.enumerated() where !piece.isEmpty {
            guard let table = sniff(piece), singletons.contains(table) else { continue }
            if let parsed = ConflictShelfEntry(jsonLine: piece) {
                XCTAssertTrue(singletons.contains(parsed.table),
                              "\(label) line \(index): skipped, but a full parse keeps it as \(parsed.table)", file: file, line: line)
            }
        }
        return read.stats.skipped
    }

    private func entry(_ table: String, id: String, seq: Int64, uid: String? = nil, row: [String: Any] = ["title": "t"],
                       offered: Bool = true) -> ConflictShelfEntry {
        ConflictShelfEntry(uid: uid ?? me, table: table, id: id, seq: seq, reason: .catchup, row: row,
                           against: .init(seq: seq, vid: nil), catchup: true, offered: offered)
    }

    private func bytes(_ entry: ConflictShelfEntry) throws -> Data {
        var data = try XCTUnwrap(entry.jsonLine())
        data.removeLast()   // the newline
        return data
    }

    /// Positive control for the duplicate-key shapes below: on this runtime
    /// a parser keeps the FIRST of two `table` keys (the reason the sniff
    /// refuses a line with a second `"table"`). If this ever flips, the
    /// duplicate-key fixtures still hold the fast path to the reference.
    func testQA_B0_theRuntimeParserKeepsTheFirstOfTwoTableKeys() throws {
        let line = Data(#"{"catchup":true,"id":"D","offered":true,"reason":"catchup","row":{},"seq":1,"table":"calendar_events","uid":"u","table":"agent_preferences"}"#.utf8)
        let parsed = try XCTUnwrap(ConflictShelfEntry(jsonLine: line), "a duplicate key still parses")
        XCTAssertEqual(parsed.table, "calendar_events", "JSONSerialization keeps the first duplicate here")
    }

    /// Line shapes beyond the implementer's fixture. Every one must leave the
    /// fast path equal to the reference; the ones marked `kept` must really be
    /// kept by the reference (so a skip would show), and the ones marked
    /// `skippable` must be skipped (so the test is not vacuous).
    func testQA_B1_adversarialLinesNeverSkipALineAFullParseKeeps() throws {
        var lines: [Data] = []
        var mustKeep: [String] = []      // ids the reference keeps
        var mustSkip = 0

        // 1. A second top-level `"table"` key PAST the first 4 KB, the one-row
        //    table last: the parser keeps the first (an id table).
        let big = String(repeating: "x", count: 6_000)
        lines.append(Data(#"{"catchup":true,"id":"BIGDUP","offered":true,"reason":"catchup","row":{"big":"\#(big)"},"seq":2,"table":"calendar_events","uid":"\#(me)","table":"agent_preferences","uid":"\#(me)"}"#.utf8))
        mustKeep.append("BIGDUP")
        // 2. The same with 3 MB of row before the first key.
        let huge = String(repeating: "y", count: 3 * 1024 * 1024)
        lines.append(Data(#"{"catchup":true,"id":"HUGEDUP","offered":true,"reason":"catchup","row":{"big":"\#(huge)"},"seq":3,"table":"todo_lists","uid":"\#(me)","table":"user_settings","uid":"\#(me)"}"#.utf8))
        mustKeep.append("HUGEDUP")
        // 3. A nested object that ends in the one-row tail, closed one brace later.
        lines.append(Data(#"{"catchup":true,"id":"NEST","offered":true,"reason":"catchup","row":{},"seq":4,"table":"calendar_events","uid":"\#(me)","z":{"table":"agent_preferences","uid":"\#(me)"}}"#.utf8))
        mustKeep.append("NEST")
        // 4. Whitespace before the key, and after the brace.
        lines.append(Data(#"{"catchup":true,"id":"WS1","offered":true,"reason":"catchup","row":{},"seq":5, "table":"agent_preferences","uid":"\#(me)"}"#.utf8))
        lines.append(try bytes(entry("agent_preferences", id: me, seq: 6)) + Data(" ".utf8))
        lines.append(try bytes(entry("calendar_events", id: "WS3", seq: 7)) + Data(" \t".utf8))
        mustKeep.append("WS3")
        // 5. A look-alike one-row name (Cyrillic "р"): an id table to a parser.
        lines.append(try bytes(entry("agent_\u{0440}references", id: "LOOK", seq: 8)))
        mustKeep.append("LOOK")
        // 6. Two `uid` keys, the one-row table at the tail: skipped either way.
        lines.append(Data(#"{"catchup":true,"id":"\#(me)","offered":true,"reason":"catchup","row":{},"seq":9,"uid":"someone-else","table":"agent_preferences","uid":"\#(me)"}"#.utf8))
        mustSkip += 1
        // 7. An escaped key that CONTAINS table but is not `table`.
        lines.append(Data(#"{"catchup":true,"id":"ESCKEY","offered":true,"reason":"catchup","row":{"x\"table\"y":1},"seq":10,"table":"calendar_events","uid":"\#(me)"}"#.utf8))
        mustKeep.append("ESCKEY")
        // 8. `\\u` (an escaped backslash, then u) in a one-row line: parsed.
        lines.append(Data(#"{"catchup":true,"id":"\#(me)","offered":true,"reason":"catchup","row":{"p":"C:\\users"},"seq":11,"table":"agent_preferences","uid":"\#(me)"}"#.utf8))
        // 9. Two JSON values on one 0x0A line (a CR between them), tail one-row.
        lines.append(Data(#"{"a":1}"#.utf8) + Data([0x0D]) + (try bytes(entry("agent_preferences", id: me, seq: 12))))
        lines.append(try bytes(entry("calendar_events", id: "CR2", seq: 13)) + Data([0x0D]) + (try bytes(entry("agent_preferences", id: me, seq: 14))))
        // 10. A BOM before a kept line and before a one-row line.
        lines.append(Data([0xEF, 0xBB, 0xBF]) + (try bytes(entry("calendar_events", id: "BOM1", seq: 15))))
        lines.append(Data([0xEF, 0xBB, 0xBF]) + (try bytes(entry("agent_preferences", id: me, seq: 16))))
        // 11. UTF-16LE / BE encodings of a kept line (no 0x0A unit inside).
        let ascii = String(decoding: try bytes(entry("calendar_events", id: "U16", seq: 17)), as: UTF8.self)
        lines.append(try XCTUnwrap(ascii.data(using: .utf16LittleEndian)))
        lines.append(try XCTUnwrap(ascii.data(using: .utf16BigEndian)))
        // 12. NUL bytes: in a one-row string, and in an id-table string.
        var nul1 = try bytes(entry("agent_preferences", id: me, seq: 18, row: ["n": "a"]))
        if let r = nul1.range(of: Data(#""n":"a""#.utf8)) { nul1.replaceSubrange(r, with: Data(#""n":"a"#.utf8) + Data([0x00]) + Data(#"""#.utf8)) }
        lines.append(nul1)
        var nul2 = try bytes(entry("calendar_events", id: "NUL2", seq: 19, row: ["n": "a"]))
        if let r = nul2.range(of: Data(#""n":"a""#.utf8)) { nul2.replaceSubrange(r, with: Data(#""n":"a"#.utf8) + Data([0x00]) + Data(#"""#.utf8)) }
        lines.append(nul2)
        // 13. The table spelled `table`, an empty table, a slash-escaped one.
        lines.append(try bytes(entry("table", id: "TT", seq: 20)))
        mustKeep.append("TT")
        lines.append(try bytes(entry("", id: "EMPTY", seq: 21)))
        mustKeep.append("EMPTY")
        lines.append(Data(#"{"catchup":true,"id":"SLASH","offered":true,"reason":"catchup","row":{},"seq":22,"table":"agent\/preferences","uid":"\#(me)"}"#.utf8))
        mustKeep.append("SLASH")
        // 14. A space before the colon; a top-level array; minimal shapes.
        lines.append(Data(#"{"catchup":true,"id":"\#(me)","offered":true,"reason":"catchup","row":{},"seq":23,"table" :"agent_preferences","uid":"\#(me)"}"#.utf8))
        lines.append(Data(#"[{"table":"agent_preferences","uid":"u"}]"#.utf8))
        lines.append(Data(#"{}"#.utf8))
        lines.append(Data(#"{"table":"agent_preferences","uid":"u"}"#.utf8))
        lines.append(Data(#""}"#.utf8))
        // 15. Non-ASCII uid, the one-row table: skipped.
        lines.append(try bytes(entry("user_settings", id: "u", seq: 24, uid: "用户-🚀")))
        mustSkip += 1
        // 16. Plain one-row lines, so the fast path has work.
        for (i, t) in ["agent_preferences", "user_settings", "agent_conversations"].enumerated() {
            lines.append(try bytes(entry(t, id: me, seq: Int64(30 + i), row: ["blob": String(repeating: "z", count: 50_000)])))
            mustSkip += 1
        }
        // 17. A duplicate where the FIRST `table` is the one-row one and the
        //     tail is an id table: dropped by the reference (first wins).
        lines.append(Data(#"{"catchup":true,"table":"agent_preferences","id":"FIRSTONE","offered":true,"reason":"catchup","row":{},"seq":40,"table":"calendar_events","uid":"\#(me)"}"#.utf8))

        let skipped = try differential(lines, "adversarial")
        let reference = try shelf(lines.reduce(into: Data()) { $0.append($1); $0.append(0x0A) })
            .entries().filter { !singletons.contains($0.table) }
        let keptIDs = Set(reference.map(\.id))
        for id in mustKeep { XCTAssertTrue(keptIDs.contains(id), "fixture: the reference keeps \(id)") }
        XCTAssertGreaterThanOrEqual(skipped, mustSkip, "fixture: the fast path really skipped the plain one-row lines")
    }

    /// Seeded random shelves: entries with hostile strings, then byte-level
    /// damage on a share of the lines. Fast path == reference on every one.
    func testQA_B2_seededRandomShelvesWithDamageMatchTheReference() throws {
        var rng = SplitMix64(seed: 0x5EED_BA7C_0001)
        let tables = ["calendar_events", "events", "todo_lists", "event_logs", "event_types",
                      "agent_preferences", "user_settings", "agent_conversations"]
        let atoms = ["\"", "\\", "/", "table", "\"table\":\"agent_preferences\"", ",\"uid\":\"", "}", "{", "漢字", "🚀",
                     "\u{0001}", "\u{001F}", "\t", "\n", "\\u0074", "agent_preferences", " ", "\"}", "é", "\u{2028}"]
        func text(_ n: Int) -> String { (0..<n).map { _ in atoms[Int(rng.next() % UInt64(atoms.count))] }.joined() }
        var totalSkipped = 0
        for round in 0..<6 {
            var lines: [Data] = []
            for i in 0..<400 {
                let table = tables[Int(rng.next() % UInt64(tables.count))]
                var row: [String: Any] = ["title": text(Int(rng.next() % 12)), "n": Int(rng.next() % 1000)]
                if rng.next() % 4 == 0 { row[text(3)] = text(5) }
                if rng.next() % 5 == 0 { row["table"] = tables[Int(rng.next() % UInt64(tables.count))] }
                let e = entry(table, id: text(2) + "\(i)", seq: Int64(i), uid: rng.next() % 7 == 0 ? "other" : me,
                              row: row, offered: rng.next() % 2 == 0)
                guard var line = e.jsonLine() else { continue }
                line.removeLast()
                switch rng.next() % 10 {
                case 0:  // truncate
                    line = line.prefix(Int(rng.next() % UInt64(max(line.count, 1))))
                case 1:  // a top-level duplicate `table` right after `{`
                    let dup = tables[Int(rng.next() % UInt64(tables.count))]
                    line.replaceSubrange(0..<1, with: Data("{\"table\":\"\(dup)\",".utf8))
                case 2:  // one byte replaced
                    if !line.isEmpty { line[Int(rng.next() % UInt64(line.count))] = UInt8(truncatingIfNeeded: rng.next()) }
                case 3:  // trailing CR / space
                    line.append(rng.next() % 2 == 0 ? 0x0D : 0x20)
                default: break
                }
                lines.append(line.filter { $0 != 0x0A })
            }
            totalSkipped += try differential(lines, "random round \(round)")
        }
        XCTAssertGreaterThan(totalSkipped, 100, "fixture: the random shelves give the fast path real work")
    }

    /// The real shelf, when the runner is handed its path
    /// (`TEST_RUNNER_QA_REAL_SHELF_PATH`). Read only; prints counts and
    /// timings, never content.
    func testQA_B3_realShelfFromEnvironmentMatchesTheReference() throws {
        guard let path = ProcessInfo.processInfo.environment["QA_REAL_SHELF_PATH"], !path.isEmpty else {
            throw XCTSkip("QA_REAL_SHELF_PATH not set")
        }
        let url = URL(fileURLWithPath: path)
        XCTAssertEqual(url.lastPathComponent, ConflictShelf.filename)
        let shelf = ConflictShelf(directory: url.deletingLastPathComponent())
        func ms(_ body: () -> Void) -> Double {
            let t = DispatchTime.now().uptimeNanoseconds; body(); return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
        }
        var reference: [ConflictShelfEntry] = []
        var read: (entries: [ConflictShelfEntry], stats: ConflictShelf.ReadStats) = ([], .init())
        var refTimes: [Double] = [], fastTimes: [Double] = []
        for _ in 0..<3 {
            refTimes.append(ms { reference = shelf.entries().filter { !self.singletons.contains($0.table) } })
            fastTimes.append(ms { read = shelf.entries(skippingTables: self.singletons) })
        }
        assertSameEntries(read.entries, reference, "real shelf")
        let data = try Data(contentsOf: url)
        var falseNegatives = 0
        for piece in data.split(separator: 0x0A) {
            let line = Data(piece)
            guard let t = sniff(line), singletons.contains(t) else { continue }
            if let parsed = ConflictShelfEntry(jsonLine: line), !singletons.contains(parsed.table) { falseNegatives += 1 }
        }
        XCTAssertEqual(falseNegatives, 0)
        print("QA-REAL-SHELF bytes=\(read.stats.bytes) lines=\(read.stats.lines) skipped=\(read.stats.skipped) parsed=\(read.stats.parsed) kept=\(reference.count) identical=\(read.entries.count == reference.count) falseNegatives=\(falseNegatives) ref_ms=\(refTimes.map { Int($0) }) fast_ms=\(fastTimes.map { Int($0) })")
    }

    // MARK: - A. agent_preferences token-free projection

    private func rule(_ value: String) -> AgentPreferenceRule {
        AgentPreferenceRule(scope: .eventTypeMapping,
                            triggerPattern: .init(kind: .exactEventTypeTitle, value: value),
                            preferredAction: .init(kind: .keepTypeOnly, value: nil),
                            source: .explicitSelection, lastUsedAt: Self.t0)
    }

    private func tokens(_ label: String) -> TokenInferenceRepository.Snapshot {
        let dynamic = TokenDynamicHypothesisRecord(
            id: "dyn-\(label)", category: .state, statement: "s \(label)", confidence: 0.5, weight: 0.5,
            windowStart: Self.t0, windowEnd: Self.t0.addingTimeInterval(86_400), relatedOccurrenceKeys: [],
            rationale: "r \(label)", derivedFromIDs: [], status: .active, updatedAt: Self.t0)
        let meta = TokenMetaHypothesisRecord(
            kind: .inputSparse, confidence: 0.4, windowStart: Self.t0, windowEnd: Self.t0.addingTimeInterval(86_400),
            rationale: "m \(label)", status: .active, updatedAt: Self.t0)
        return ([dynamic], [meta], [])
    }

    private func wire<T: Encodable>(_ value: [T]) throws -> Any {
        guard !value.isEmpty else { return NSNull() }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    /// The row an older build hashed: today's columns plus the three token
    /// columns, built column by column (not through the engine's legacy path).
    private func legacyRow(_ service: SupabaseSyncService, rules: [AgentPreferenceRule],
                           tokens: TokenInferenceRepository.Snapshot) throws -> [String: Any] {
        var row = service.agentPreferencesRow(rules: rules, decisionHistory: [])
        row["token_dynamic_hypotheses"] = try wire(tokens.dynamic)
        row["token_meta_hypotheses"] = try wire(tokens.meta)
        row["token_projections"] = try wire(tokens.projections)
        return row
    }

    private func service(localTokens: TokenInferenceRepository.Snapshot, calls: @escaping () -> Void = {}) -> SupabaseSyncService {
        let suite = "PerfBatch1QA-svc-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let service = SupabaseSyncService(gateway: SyncFakeServer(userId: me), userId: me, defaults: defaults,
                                          scheduler: SyncManualScheduler())
        service.legacyTokenState = { calls(); return localTokens }
        return service
    }

    private func tokenFree(_ service: SupabaseSyncService, _ rules: [AgentPreferenceRule]) -> String {
        SupabaseSyncService.rowHash(service.agentPreferencesRow(rules: rules, decisionHistory: []))
    }

    /// Every pairing of (whose rules, whose token state) a legacy entry can
    /// be the hash of is re-hashed to that rules side's token-free hash —
    /// and seq, version id and the catch-up marker are kept.
    func testQA_A1_transitionMatrix_everyRulesSideTimesEveryTokenSide() throws {
        let localRules = [rule("local")]
        let incomingRules = [rule("incoming"), rule("incoming-2")]
        let localTokens = tokens("L")
        let incomingTokens = tokens("I")
        let cases: [(rules: [AgentPreferenceRule], tokens: TokenInferenceRepository.Snapshot, side: String)] = [
            (localRules, localTokens, "local"), (localRules, incomingTokens, "local"),
            (incomingRules, localTokens, "incoming"), (incomingRules, incomingTokens, "incoming"),
        ]
        for (index, c) in cases.enumerated() {
            let svc = service(localTokens: localTokens)
            let incoming = try legacyRow(svc, rules: incomingRules, tokens: incomingTokens)
            let legacy = SupabaseSyncService.rowHash(try legacyRow(svc, rules: c.rules, tokens: c.tokens))
            XCTAssertNotEqual(legacy, tokenFree(svc, c.rules), "fixture \(index)")
            let entry = SyncBaselineEntry(hash: legacy, seq: 41 + Int64(index), vid: "vid-\(index)", stale: index % 2 == 1)
            let line = "sync.baseline.token_free table=agent_preferences matched=\(c.side) seq=\(41 + index)\n"
            let before = trailCount(line)

            let out = try XCTUnwrap(svc.preferencesBaseInTokenFreeProjection(entry, rules: localRules, decisionHistory: [],
                                                                               incoming: incoming))

            XCTAssertEqual(out.hash, tokenFree(svc, c.rules), "case \(index): re-hashed to the \(c.side) rules")
            XCTAssertEqual(out.seq, entry.seq, "case \(index): seq kept")
            XCTAssertEqual(out.vid, entry.vid, "case \(index): version id kept")
            XCTAssertEqual(out.stale, entry.stale, "case \(index): catch-up marker kept")
            XCTAssertEqual(trailCount(line), before + 1, "case \(index): trail names the side")
        }
    }

    /// A miss is remembered: the second identical call neither hashes the
    /// token state again nor writes a second line; nil, `?` and an entry
    /// already token-free come back as they are without reading it at all.
    func testQA_A2_missesAreRememberedAndTheCheapCasesNeverReadTheTokenState() throws {
        var reads = 0
        let svc = service(localTokens: tokens("now")) { reads += 1 }
        let rules = [rule("r")]
        XCTAssertNil(svc.preferencesBaseInTokenFreeProjection(nil, rules: rules, decisionHistory: []))
        let unknown = SyncBaselineEntry.unknown(seq: 5)
        XCTAssertEqual(svc.preferencesBaseInTokenFreeProjection(unknown, rules: rules, decisionHistory: []), unknown)
        let clean = SyncBaselineEntry(hash: tokenFree(svc, rules), seq: 6)
        XCTAssertEqual(svc.preferencesBaseInTokenFreeProjection(clean, rules: rules, decisionHistory: []), clean)
        XCTAssertEqual(reads, 0, "nil / ? / token-free: the token state is not read")

        let stray = SyncBaselineEntry(hash: SupabaseSyncService.rowHash(try legacyRow(svc, rules: rules, tokens: tokens("then"))), seq: 7)
        let missLine = "sync.baseline.token_free table=agent_preferences matched=none seq=7\n"
        let before = trailCount(missLine)
        XCTAssertEqual(svc.preferencesBaseInTokenFreeProjection(stray, rules: rules, decisionHistory: []), stray, "unexplained: unchanged")
        XCTAssertEqual(svc.preferencesBaseInTokenFreeProjection(stray, rules: [rule("edited")], decisionHistory: []), stray)
        XCTAssertEqual(reads, 1, "the miss is remembered (a later local edit does not retry it)")
        XCTAssertEqual(trailCount(missLine), before + 1)
    }

    /// Token columns an incoming row carries never reach a hash: the
    /// projected hash of a row with any token columns equals the local hash
    /// of the same rules, whatever this device's own token state is; the
    /// empty row is the same projection; only non-null columns are reported.
    func testQA_A3_incomingTokenColumnsNeverReachAHash() throws {
        let suite = "PerfBatch1QA-adapter-\(UUID().uuidString)"
        suites.append(suite)
        let prefs = AgentPreferenceStore(directoryURL: scratchDirectory("prefs"))
        let gym = [rule("gym")]   // one id: `rule` mints a fresh UUID per call
        XCTAssertTrue(prefs.applyRestore(rules: gym, decisionHistory: [], strategy: .cloudOverwritesLocal,
                                         resolution: .keepCloud))
        let svc = service(localTokens: tokens("whatever"))
        let adapter = AgentPreferencesSyncAdapter(engine: svc, store: prefs)
        let local = SupabaseSyncService.rowHash(adapter.localRow())
        for label in ["a", "b"] {
            var incoming = try legacyRow(svc, rules: gym, tokens: tokens(label))
            incoming["seq"] = 9
            incoming["version_id"] = "v"
            let projected = try XCTUnwrap(adapter.projected(incoming))
            XCTAssertEqual(SupabaseSyncService.rowHash(projected), local, "token columns \(label) do not change the hash")
            XCTAssertEqual(Set(projected.keys).intersection(SupabaseSyncService.agentPreferencesTokenColumns), [])
            XCTAssertEqual(adapter.ignoredColumns(incoming), ["token_dynamic_hypotheses", "token_meta_hypotheses"],
                           "null projections column not reported")
        }
        let emptyPrefs = AgentPreferenceStore(directoryURL: scratchDirectory("prefs-empty"))
        let emptyAdapter = AgentPreferencesSyncAdapter(engine: svc, store: emptyPrefs)
        XCTAssertEqual(SupabaseSyncService.rowHash(try XCTUnwrap(emptyAdapter.emptyRow())),
                       SupabaseSyncService.rowHash(emptyAdapter.localRow()),
                       "a device with token state but no rules reads as the empty row (QA-5)")
    }

    /// What one missed transition costs on the main actor with a token
    /// state of device size. Measurement only (prints); the number goes in
    /// the QA report. Also pins that the miss is paid once per entry.
    func testQA_A4_costOfAMissWithADeviceSizedTokenState() throws {
        let template = tokens("big").dynamic[0]
        let dynamic = (0..<6_000).map { i -> TokenDynamicHypothesisRecord in
            var r = template
            r.id = "dyn-\(i)"
            r.statement = String(repeating: "statement \(i) ", count: 40)
            r.rationale = String(repeating: "rationale \(i) ", count: 40)
            return r
        }
        let big: TokenInferenceRepository.Snapshot = (dynamic, [], [])
        let bytes = try JSONEncoder().encode(dynamic).count
        var reads = 0
        let svc = service(localTokens: big) { reads += 1 }
        let entry = SyncBaselineEntry(hash: tokenFree(svc, [rule("before-edit")]), seq: 3)
        let started = DispatchTime.now().uptimeNanoseconds
        _ = svc.preferencesBaseInTokenFreeProjection(entry, rules: [rule("after-edit")], decisionHistory: [])
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        _ = svc.preferencesBaseInTokenFreeProjection(entry, rules: [rule("after-edit")], decisionHistory: [])
        XCTAssertEqual(reads, 1)
        print("QA-A4 token state bytes=\(bytes) one ordinary-edit miss ms=\(Int(ms))")
    }

    /// A daily series over the whole prediction horizon: every occurrence
    /// placed, one save, the trail line's count equal to what was placed.
    func testQA_A5_bootstrapOverAFullHorizonSavesOnce() async throws {
        try XCTSkipIf(UserDefaults.standard.bool(forKey: AppSettingsKeys.tokenInferenceLLMEnabled), "LLM path on")
        let suite = "PerfBatch1QA-boot-\(UUID().uuidString)"
        suites.append(suite)
        let location = TestStorage.reset(suite)
        let defaults = CountingDefaults(suiteName: suite)!
        let store = EventStore(defaults: UserDefaults(suiteName: suite + "-store")!, storage: location,
                               seedsSampleDataIfEmpty: false)
        suites.append(suite + "-store")
        let repository = TokenInferenceRepository(defaults: defaults)
        let service = TokenInferenceService(repository: repository)
        let start = Date().addingTimeInterval(1800)
        let event = Event(title: "QA daily", timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
                          repeatUnit: .day, repeatInterval: 1)
        store.addCalendarEvent(event)

        await service.predict(event: event, store: store)

        let placed = repository.snapshot().projections
        XCTAssertGreaterThanOrEqual(placed.count, 14, "a 14-day horizon of a daily series")
        XCTAssertEqual(defaults.writes[TokenInferenceRepository.projectionKey], 1, "\(placed.count) upserts, one save")
        XCTAssertEqual(Set(placed.map(\.id)).count, placed.count, "no duplicate occurrence")
        XCTAssertEqual(TokenInferenceRepository(defaults: defaults).snapshot().projections, placed, "the save is the memory")
        XCTAssertTrue(DiagnosticTrail.combinedText().contains("tokens: projections batch upserts=\(placed.count) saves=1 count=\(placed.count) landed=true"))
    }

    /// The new `upsertProjection` (insert in place, sort only when unordered)
    /// against the old one (replace or append, then sort) on random
    /// sequences with ties, replacements and reconciles. Reports how many
    /// sequences end in a different order; they may differ only among exact
    /// (start, updatedAt) ties.
    func testQA_A6_upsertMatchesTheOldAlgorithmExceptAmongExactTies() async throws {
        try XCTSkipIf(UserDefaults.standard.bool(forKey: AppSettingsKeys.tokenInferenceLLMEnabled), "LLM path on")
        // A real record as the template.
        let suite = "PerfBatch1QA-model-\(UUID().uuidString)"
        suites.append(suite)
        let location = TestStorage.reset(suite)
        let store = EventStore(defaults: UserDefaults(suiteName: suite + "-store")!, storage: location,
                               seedsSampleDataIfEmpty: false)
        suites.append(suite + "-store")
        let seedRepo = TokenInferenceRepository(defaults: UserDefaults(suiteName: suite)!)
        let start = Date().addingTimeInterval(1800)
        let event = Event(title: "QA template", timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
                          repeatUnit: .day, repeatInterval: 1)
        store.addCalendarEvent(event)
        await TokenInferenceService(repository: seedRepo).predict(event: event, store: store)
        let template = try XCTUnwrap(seedRepo.snapshot().projections.first)

        func old(_ storage: inout [TokenOccurrenceProjectionRecord], _ record: TokenOccurrenceProjectionRecord) {
            if record.phase == .reconciled {
                storage.removeAll { $0.occurrenceKey == record.occurrenceKey && $0.phase == .predicted }
            }
            if let index = storage.firstIndex(where: { $0.id == record.id }) { storage[index] = record } else { storage.append(record) }
            storage.sort { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.updatedAt < rhs.updatedAt
            }
        }
        var rng = SplitMix64(seed: 0xA6A6_0001)
        let events = (0..<4).map { _ in UUID() }
        var sequences = 0, differing = 0, differingWithoutTies = 0
        for _ in 0..<300 {
            let repo = TokenInferenceRepository(defaults: UserDefaults(suiteName: suite + "-m")!)
            repo.clearAll()
            var model: [TokenOccurrenceProjectionRecord] = []
            for _ in 0..<12 {
                var r = template
                let day = Self.t0.addingTimeInterval(Double(rng.next() % 3) * 86_400)
                r.occurrenceKey = CalendarOccurrenceKey(eventID: events[Int(rng.next() % 4)], baseSeriesEventID: nil,
                                                        occurrenceDate: day, kind: .singleEvent,
                                                        dayKey: 20_260_101 + Int(rng.next() % 3))
                r.phase = rng.next() % 3 == 0 ? .reconciled : .predicted
                r.start = Self.t0.addingTimeInterval(Double(rng.next() % 3) * 3600)
                r.updatedAt = Self.t0.addingTimeInterval(Double(rng.next() % 2))
                repo.upsertProjection(r)
                old(&model, r)
            }
            sequences += 1
            let new = repo.snapshot().projections
            XCTAssertEqual(Set(new.map(\.id)), Set(model.map(\.id)), "the same records survive")
            if new.map(\.id) != model.map(\.id) {
                differing += 1
                let key: (TokenOccurrenceProjectionRecord) -> String = { "\($0.start.timeIntervalSince1970)|\($0.updatedAt.timeIntervalSince1970)" }
                if new.map(key) != model.map(key) { differingWithoutTies += 1 }
            }
        }
        UserDefaults().removePersistentDomain(forName: suite + "-m")
        XCTAssertEqual(differingWithoutTies, 0, "orders differ only among exact (start, updatedAt) ties")
        print("QA-A6 sequences=\(sequences) differentOrder=\(differing) differentBeyondTies=\(differingWithoutTies)")
    }

    // MARK: - C. Settings cleanup

    private let bundle = "wordless.shiqiliuyifanmei.app"

    func testQA_C1_theAgeLimitIsStrictAndAFutureFileStays() throws {
        let suite = "PerfBatch1QA-c1-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let dir = scratchDirectory("prefs-dir")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        func file(_ suffix: String, age: TimeInterval) throws {
            let url = dir.appendingPathComponent("\(bundle).plist.\(suffix)")
            try Data(repeating: 0x42, count: 7).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try file("exactly24h", age: 24 * 3600)
        try file("24hplus1s", age: 24 * 3600 + 1)
        try file("future", age: -3600)
        let outcome = SettingsOrphanCleanup.run(defaults: defaults, preferencesDirectory: dir, bundleIdentifier: bundle, now: now)
        let left = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        XCTAssertEqual(outcome.removedFiles, 1)
        XCTAssertEqual(left, ["\(bundle).plist.exactly24h", "\(bundle).plist.future"])
    }

    func testQA_C2_allSevenKeysGoAndNearMissesStay() {
        let suite = "PerfBatch1QA-c2-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        for key in SettingsOrphanCleanup.orphanedKeys { defaults.set(Data("x".utf8), forKey: key) }
        let survivors = ["googleAccessTokenX", "tokenInferenceProjections.v2", "tokenInferenceDynamicHypotheses.v2",
                         "tokenInferenceMetaHypotheses.v2", "tokenInferenceProjections.v3", "syncHashes.\(me).agent_preferences",
                         "syncHashes.ownerUid", "skillInsights", "calendarEvents", "events"]
        for key in survivors { defaults.set("keep", forKey: key) }
        let outcome = SettingsOrphanCleanup.run(defaults: defaults, preferencesDirectory: nil, bundleIdentifier: nil)
        XCTAssertEqual(outcome.removedKeys.sorted(), SettingsOrphanCleanup.orphanedKeys.sorted())
        XCTAssertEqual(SettingsOrphanCleanup.orphanedKeys.count, 7)
        for key in SettingsOrphanCleanup.orphanedKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        for key in survivors { XCTAssertEqual(defaults.string(forKey: key), "keep", key) }
    }

    func testQA_C3_aRegisteredDefaultIsNeitherCountedNorReported() {
        let suite = "PerfBatch1QA-c3-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.register(defaults: ["googleUserEmail": "registered@example.invalid"])
        defaults.set("persisted", forKey: "googleAccessToken")
        let outcome = SettingsOrphanCleanup.run(defaults: defaults, preferencesDirectory: nil, bundleIdentifier: nil)
        XCTAssertEqual(outcome.removedKeys, ["googleAccessToken"])
    }
}

/// Counts writes per key, in its own suite.
private final class CountingDefaults: UserDefaults {
    var writes: [String: Int] = [:]
    override func set(_ value: Any?, forKey defaultName: String) {
        writes[defaultName, default: 0] += 1
        super.set(value, forKey: defaultName)
    }
}

/// A seeded generator, so a failing shelf can be rebuilt.
private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
