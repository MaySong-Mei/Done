//
//  ObsReadQAScanTests.swift
//  DoneTests
//
//  Independent QA for perf/obs-read, steps 3 and 5: the backward byte search
//  that finds an id's revision (`SpikeRunFileScan.latestLine`) and the launch
//  seed that reads only the daily file's tail (`SpikeRunFileScan.newestMatch`).
//
//  The oracle is NOT the code under test. `ObsReadQAOracle` is the reader as
//  it stands at 3111ef1 — what users have installed — copied here verbatim
//  (String split on "\n", JSONDecoder per line with `try?`, latest line per
//  id wins, the 200-newest cap), so a refactor of the store cannot move the
//  answer it is judged against.
//
//  Every harness check is also run against deliberately wrong scanners
//  (positive controls) and must catch them; and against a correct scanner of
//  this file's own, which it must pass — so "no violations" means something.
//

import XCTest
@testable import Done

// MARK: - The installed build's reader (3111ef1), verbatim

@MainActor
enum ObsReadQAOracle {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 3111ef1 `SpikeRunStore.loadRuns`, up to the collapse.
    static func records(_ data: Data) -> [SpikeRun] {
        let decoder = decoder()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SpikeRun.self, from: lineData)
        }
    }

    /// 3111ef1 `SpikeRunLog.collapse`.
    static func collapse(_ records: [SpikeRun]) -> [SpikeRun] {
        var latest: [UUID: SpikeRun] = [:]
        var order: [UUID] = []
        for record in records {
            if latest[record.id] == nil { order.append(record.id) }
            latest[record.id] = record
        }
        return order.compactMap { latest[$0] }
    }

    /// 3111ef1 `SpikeRunLog.applyRetention`.
    static func retention(_ collapsed: [SpikeRun], cap: Int) -> [SpikeRun] {
        guard cap >= 0, collapsed.count > cap else { return collapsed }
        return Array(collapsed.sorted { $0.startedAt > $1.startedAt }.prefix(cap))
    }

    /// The record 3111ef1's `nextRevision` read its revision from.
    static func record(of id: UUID, in data: Data) -> SpikeRun? {
        collapse(records(data)).first { $0.id == id }
    }

    static func revision(of id: UUID, in data: Data) -> Int {
        record(of: id, in: data)?.revision ?? 0
    }

    /// 3111ef1 `ResidentObservationCenter.latestDailyRecord`.
    static func seed(_ data: Data, matches: (SpikeRun) -> Bool) -> SpikeRun? {
        retention(collapse(records(data)), cap: SpikeRunStore.maxRunsPerSpike)
            .filter(matches)
            .max { $0.startedAt < $1.startedAt }
    }
}

// MARK: - Bytes

/// A seeded SplitMix64, so any failing case reproduces from its seed.
struct ObsReadQARandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
enum ObsReadQABytes {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated static let base = Date(timeIntervalSince1970: 1_790_000_000)

    static func run(
        id: UUID, spikeID: String = "qa-scan", startedAt: Date = base, revision: Int?,
        note: String? = nil, installID: UUID? = nil, build: String = "10", owner: String? = "owner-a",
        configuration: String? = "release", metrics: [String: SpikeMetricValue] = ["n": .number(1)]
    ) -> SpikeRun {
        var run = SpikeRun(
            id: id, spikeID: spikeID, scenarioID: "sc", variantID: nil,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1),
            appVersion: "0.5.0", appBuild: build, appCommit: nil,
            deviceModel: "iPhone17,2", osVersion: "26.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US", buildConfiguration: configuration,
            metrics: metrics, note: note, outcome: .completed, abortReason: nil
        )
        run.revision = revision
        run.installID = installID
        run.ownerUID = owner
        return run
    }

    /// The bytes the store appends for `run`: one encode, then `\n`.
    static func line(_ run: SpikeRun) -> Data {
        var data = try! encoder().encode(run)
        data.append(0x0A)
        return data
    }

    /// Rewrites the record id's text (not any other field's) in an encoded
    /// line — lower or mixed case, as a fixture or a copied-in file may hold it.
    static func recase(_ line: Data, id: UUID, rng: inout ObsReadQARandom) -> Data {
        let key = Data("\"id\":\"\(id.uuidString)\"".utf8)
        guard let range = line.range(of: key) else { return line }
        let start = range.lowerBound + 6
        var out = line
        let lower = Bool.random(using: &rng)
        for offset in 0..<36 {
            let byte = out[start + offset]
            guard byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F") else { continue }
            if lower || Bool.random(using: &rng) { out[start + offset] = byte | 0x20 }
        }
        return out
    }

    /// A line that is valid JSON but no `SpikeRun` (a required key renamed —
    /// a future schema), still holding the id's text.
    static func undecodable(_ line: Data) -> Data {
        let key = Data("\"spikeID\":".utf8)
        guard let range = line.range(of: key) else { return line }
        var out = line
        out.replaceSubrange(range, with: Data("\"spikeIDv2\":".utf8))
        return out
    }

    /// A byte that is not UTF-8 inside the note's text. The installed reader
    /// decodes the line (it maps the byte to U+FFFD before JSON); a raw-byte
    /// decoder may not.
    static func invalidUTF8InNote(_ line: Data, marker: String) -> Data {
        let key = Data(marker.utf8)
        guard let range = line.range(of: key) else { return line }
        var out = line
        out[range.lowerBound] = 0xFF
        return out
    }

    static func lines(_ data: Data) -> [Data] {
        data.split(separator: 0x0A, omittingEmptySubsequences: false).map { Data($0) }
    }

    /// The bytes with `A`–`F` folded to lower case — the only letters a
    /// UUID string holds — so a native search finds an id in any case.
    static func folded(_ data: Data) -> Data {
        Data(data.map { $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "F") ? $0 | 0x20 : $0 })
    }

    /// Lines (split on the `\n` byte) holding the id's text in any case.
    static func holderCount(_ data: Data, id: UUID) -> Int {
        let needle = Data(id.uuidString.lowercased().utf8)
        return folded(data).split(separator: 0x0A).filter { Data($0).range(of: needle) != nil }.count
    }

    static let multiByte = ["日本語", "观察站", "🙂", "👩‍👩‍👧", "e\u{301}", "한국어", "Ω", "ß", "𝄞"]

    static func note(_ rng: inout ObsReadQARandom, mention: [UUID]) -> String? {
        switch Int.random(in: 0..<10, using: &rng) {
        case 0, 1: return nil
        case 2:
            // Longer than a search chunk, now and then.
            guard Int.random(in: 0..<4, using: &rng) == 0 else { return nil }
            let count = Int.random(in: SpikeRunFileScan.searchChunkBytes...(SpikeRunFileScan.searchChunkBytes * 2),
                                   using: &rng)
            return String(repeating: "c", count: count)
        case 3: return String(repeating: "a", count: Int.random(in: 0...200, using: &rng))
        case 4:
            return (0..<Int.random(in: 1...400, using: &rng))
                .map { _ in multiByte.randomElement(using: &rng)! }.joined()
        case 5:
            // Long enough that a search chunk edge can fall inside the line.
            return String(repeating: "b", count: Int.random(in: 1_000...9_000, using: &rng))
        default:
            guard let other = mention.randomElement(using: &rng) else { return "none" }
            var text = other.uuidString
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: text = text.lowercased()
            case 1: text = String(text.map { Bool.random(using: &rng) ? Character($0.lowercased()) : $0 })
            default: break
            }
            let copies = Int.random(in: 1...(Bool.random(using: &rng) ? 3 : 300), using: &rng)
            return (0..<copies).map { _ in "see \(text) " }.joined()
                + (Bool.random(using: &rng) ? multiByte.randomElement(using: &rng)! : "")
        }
    }
}

// MARK: - A scanner of this file's own, and the wrong ones

/// A whole-file reimplementation of the revision search, used two ways:
/// configured correctly it must PASS the harness (the harness does not cry
/// wolf), and each wrong configuration must FAIL it (the harness has teeth).
@MainActor
enum ObsReadQAControlScanner {
    struct Config {
        var chunk = SpikeRunFileScan.searchChunkBytes
        /// Chunks overlap by needle − 1 bytes, as the real search's do.
        var overlap = true
        var caseInsensitive = true
        /// Skip a candidate that does not decode, instead of deferring to
        /// the full read.
        var skipUndecodable = false
        /// Newest candidate first (correct) or oldest first.
        var newestFirst = true
    }

    static func scanner(_ config: Config) -> (UUID, URL) -> SpikeRunFileScan.Latest {
        { id, url in
            guard let data = try? Data(contentsOf: url) else { return .absent }
            let haystack = config.caseInsensitive ? ObsReadQABytes.folded(data) : data
            let needle = Data((config.caseInsensitive ? id.uuidString.lowercased() : id.uuidString).utf8)
            // Occurrence starts the configured search would see.
            var starts = Set<Int>()
            var high = haystack.count
            while high > 0 {
                let low = max(0, high - config.chunk)
                var from = low
                while from < high, let hit = haystack.range(of: needle, in: from..<high) {
                    starts.insert(hit.lowerBound)
                    from = hit.lowerBound + 1
                }
                if low == 0 { break }
                high = config.overlap ? low + needle.count - 1 : low
            }
            // Group by line, newest or oldest first.
            var lineStarts = Set<Int>()
            for start in starts {
                let previous = data.range(of: Data([0x0A]), options: .backwards, in: 0..<start)
                lineStarts.insert(previous.map { $0.upperBound } ?? 0)
            }
            let ordered = config.newestFirst ? lineStarts.sorted(by: >) : lineStarts.sorted()
            for lineStart in ordered {
                let lineEnd = data.range(of: Data([0x0A]), in: lineStart..<data.count)?.lowerBound ?? data.count
                guard let run = try? ObsReadQAOracle.decoder().decode(SpikeRun.self, from: data.subdata(in: lineStart..<lineEnd)) else {
                    if config.skipUndecodable { continue }
                    return .undetermined
                }
                if run.id == id { return .found(run) }
            }
            return .absent
        }
    }

    static let real: (UUID, URL) -> SpikeRunFileScan.Latest = { id, url in
        var decodes = 0
        return SpikeRunFileScan.latestLine(of: id, in: url, decodedLines: &decodes)
    }
}

// MARK: - Step 3: the revision search against the full read

@MainActor
final class ObsReadQARevisionSearchTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private let spikeID = "qa-scan"

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        try? FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: location.directory)
        location = nil
        super.tearDown()
    }

    private var url: URL { location.directory.appendingPathComponent("\(spikeID).jsonl") }

    private struct Tally {
        var found = 0, absent = 0, undetermined = 0
        var violations: [String] = []
    }

    /// The harness: every answer is the installed reader's, or "ask the
    /// full read" (which IS the installed reader).
    private func check(_ scanner: (UUID, URL) -> SpikeRunFileScan.Latest, data: Data, ids: [UUID], label: String,
                       into tally: inout Tally) {
        for id in ids {
            let reference = ObsReadQAOracle.record(of: id, in: data)
            switch scanner(id, url) {
            case .found(let run):
                tally.found += 1
                if run != reference {
                    tally.violations.append("\(label) \(id): found revision \(run.revision ?? -1), full read \(reference?.revision ?? -1)")
                }
            case .absent:
                tally.absent += 1
                if let reference {
                    tally.violations.append("\(label) \(id): absent, full read has revision \(reference.revision ?? -1)")
                }
            case .undetermined:
                tally.undetermined += 1
            }
        }
    }

    // MARK: Random files

    /// One random file: several ids, several revisions each, notes holding
    /// other ids' text in any case (once or hundreds of times), install ids
    /// equal to another record's id, multi-byte notes, lines shorter and
    /// longer than a search chunk, ids written in lower or mixed case,
    /// healed and glued torn lines, blank lines, future-schema lines,
    /// invalid UTF-8, an unterminated or NUL-filled tail.
    private func randomFile(_ rng: inout ObsReadQARandom) -> (Data, [UUID]) {
        let ids = (0..<Int.random(in: 1...8, using: &rng)).map { _ in UUID() }
        var revisions: [UUID: Int] = [:]
        var bytes = Data()
        let lineCount = Int.random(in: 0...40, using: &rng)
        for index in 0..<lineCount {
            let id = ids.randomElement(using: &rng)!
            revisions[id, default: 0] += Int.random(in: 1...2, using: &rng)
            let marker = "Q\(index)Z"
            var note = ObsReadQABytes.note(&rng, mention: ids)
            let poison = Int.random(in: 0..<25, using: &rng) == 0
            if poison { note = marker + (note ?? "") }
            let installID: UUID? = Int.random(in: 0..<8, using: &rng) == 0 ? ids.randomElement(using: &rng)! : nil
            var line = ObsReadQABytes.line(ObsReadQABytes.run(
                id: id, spikeID: spikeID, revision: revisions[id], note: note, installID: installID))
            if Int.random(in: 0..<6, using: &rng) == 0 { line = ObsReadQABytes.recase(line, id: id, rng: &rng) }
            if Int.random(in: 0..<15, using: &rng) == 0 { line = ObsReadQABytes.undecodable(line) }
            if poison { line = ObsReadQABytes.invalidUTF8InNote(line, marker: marker) }
            switch Int.random(in: 0..<14, using: &rng) {
            case 0:
                // Killed mid-append, then a healed append after it.
                line = line.prefix(Int.random(in: 1..<(line.count - 1), using: &rng)) + Data([0x0A])
            case 1 where index < lineCount - 1:
                // Killed mid-append under a build that did not heal: the
                // next line glues on.
                line = line.prefix(Int.random(in: 1..<(line.count - 1), using: &rng))
            case 2:
                line += Data(repeating: 0x0A, count: Int.random(in: 1...3, using: &rng))
            default:
                break
            }
            bytes += line
        }
        switch Int.random(in: 0..<8, using: &rng) {
        case 0 where !bytes.isEmpty:
            bytes.removeLast()      // an unterminated last line
        case 1 where bytes.count > 2:
            bytes = bytes.prefix(Int.random(in: 1..<bytes.count, using: &rng))   // torn at EOF
        case 2:
            bytes += Data(repeating: 0, count: Int.random(in: 1...64, using: &rng))
        default:
            break
        }
        return (bytes, ids)
    }

    /// Step 3's claim, held against the installed reader on 400 random files:
    /// found = its record, absent = it has none, anything else = the full read.
    /// The search must also decide most lookups itself, and spend at most one
    /// decode per line holding the id's text.
    func testTheSearchAgreesWithTheInstalledReaderOnRandomFiles() throws {
        var rng = ObsReadQARandom(seed: 0x0B5_2EAD_0001)
        var tally = Tally()
        var maxBytes = 0
        for round in 0..<300 {
            let (bytes, ids) = randomFile(&rng)
            maxBytes = max(maxBytes, bytes.count)
            try bytes.write(to: url)
            check(ObsReadQAControlScanner.real, data: bytes, ids: ids + [UUID()], label: "round \(round)", into: &tally)
            for id in ids {
                var decodes = 0
                _ = SpikeRunFileScan.latestLine(of: id, in: url, decodedLines: &decodes)
                let holders = ObsReadQABytes.holderCount(bytes, id: id)
                if decodes > holders {
                    tally.violations.append("round \(round): \(decodes) decodes for \(holders) lines holding the id")
                }
            }
        }
        XCTAssertEqual(tally.violations, [], "\(tally.violations.count) disagreements")
        XCTAssertGreaterThan(tally.found, 0)
        XCTAssertGreaterThan(tally.absent, 0)
        XCTAssertGreaterThan(tally.undetermined, 0, "liveness: some lookups had to defer")
        let decided = Double(tally.found + tally.absent) / Double(tally.found + tally.absent + tally.undetermined)
        XCTAssertGreaterThan(decided, 0.6, "the search decides most lookups itself (\(tally))")
        XCTAssertGreaterThan(maxBytes, 2 * SpikeRunFileScan.searchChunkBytes, "liveness: files span several chunks")
        print("QA revision search: \(tally.found) found, \(tally.absent) absent, \(tally.undetermined) deferred; largest file \(maxBytes) B")
    }

    // MARK: Chunk edges, swept

    /// The id placed at every byte offset around the first and second search
    /// chunk edges (measured from the end of the file), and around the edges
    /// of a search that restarts at a rejected candidate's line start.
    private func edgeFiles() -> [(Data, UUID, String)] {
        let chunk = SpikeRunFileScan.searchChunkBytes
        var files: [(Data, UUID, String)] = []
        let encoder = ObsReadQABytes.encoder()
        for rejected in [false, true] {
            for edge in [chunk, 2 * chunk - 35] {
                for delta in -3...38 {
                    let target = UUID()
                    let targetLine = ObsReadQABytes.line(ObsReadQABytes.run(id: target, spikeID: spikeID, revision: 4))
                    let idOffset = targetLine.range(of: Data(target.uuidString.utf8))!.lowerBound
                    // Bytes from the id's first byte to the edge's anchor:
                    // the end of the file, or the rejected line's start.
                    let wanted = edge + delta
                    let fillerBase = (try! encoder.encode(ObsReadQABytes.run(id: UUID(), spikeID: spikeID, revision: 1, note: ""))).count + 1
                    let noteLength = wanted - (targetLine.count - idOffset) - fillerBase
                    guard noteLength >= 0 else { continue }
                    let filler = ObsReadQABytes.line(ObsReadQABytes.run(
                        id: UUID(), spikeID: spikeID, revision: 1, note: String(repeating: "f", count: noteLength)))
                    var bytes = ObsReadQABytes.line(ObsReadQABytes.run(id: target, spikeID: spikeID, revision: 3))
                        + targetLine + filler
                    precondition(bytes.count - (bytes.count - filler.count - targetLine.count + idOffset) == wanted)
                    if rejected {
                        bytes += ObsReadQABytes.line(ObsReadQABytes.run(
                            id: UUID(), spikeID: spikeID, revision: 1, note: "mentions \(target.uuidString)"))
                    }
                    files.append((bytes, target, "edge \(edge) delta \(delta) rejected \(rejected)"))
                }
            }
        }
        return files
    }

    func testAnIDAtEveryOffsetAroundAChunkEdgeIsFound() throws {
        var tally = Tally()
        var count = 0
        for (bytes, target, label) in edgeFiles() {
            try bytes.write(to: url)
            check(ObsReadQAControlScanner.real, data: bytes, ids: [target], label: label, into: &tally)
            count += 1
        }
        XCTAssertEqual(tally.violations, [])
        XCTAssertEqual(tally.found, count, "every placement decided as found (\(tally))")
    }

    /// Files exactly one chunk long, one byte either side, and two chunks,
    /// with the id on the first line and on the last.
    func testFilesOfExactlyOneChunkAndItsNeighbours() throws {
        let chunk = SpikeRunFileScan.searchChunkBytes
        let fillerBase = (try ObsReadQABytes.encoder().encode(
            ObsReadQABytes.run(id: UUID(), spikeID: spikeID, revision: 1, note: ""))).count + 1
        var tally = Tally()
        for size in [chunk - 1, chunk, chunk + 1, 2 * chunk, 2 * chunk + 1] {
            for first in [true, false] {
                let target = UUID()
                let targetLine = ObsReadQABytes.line(ObsReadQABytes.run(id: target, spikeID: spikeID, revision: 9))
                let filler = ObsReadQABytes.line(ObsReadQABytes.run(
                    id: UUID(), spikeID: spikeID, revision: 1,
                    note: String(repeating: "p", count: size - targetLine.count - fillerBase)))
                let bytes = first ? targetLine + filler : filler + targetLine
                XCTAssertEqual(bytes.count, size, "rig: the file is \(size) bytes")
                try bytes.write(to: url)
                check(ObsReadQAControlScanner.real, data: bytes, ids: [target, UUID()],
                      label: "\(size) first=\(first)", into: &tally)
            }
        }
        XCTAssertEqual(tally.violations, [])
        XCTAssertEqual(tally.found, 10)
        XCTAssertEqual(tally.absent, 10)
    }

    func testAMissingAnEmptyAndABlankOnlyFileAreAbsent() throws {
        XCTAssertEqual(ObsReadQAControlScanner.real(UUID(), url), .absent, "missing")
        for bytes in [Data(), Data([0x0A]), Data(repeating: 0x0A, count: 70_000)] {
            try bytes.write(to: url)
            XCTAssertEqual(ObsReadQAControlScanner.real(UUID(), url), .absent)
        }
    }

    // MARK: Through the store

    /// The append path itself (`finishRun` → `nextRevision`), from a fresh
    /// process's point of view (a fresh directory: no cached revision), on
    /// random files below the compaction cap: the line it writes carries
    /// the installed reader's revision plus one — whichever way the search
    /// decided.
    func testTheStoreStampsTheInstalledReadersRevisionPlusOne() throws {
        var rng = ObsReadQARandom(seed: 0x0B5_2EAD_0002)
        var checked = 0
        var undetermined = 0
        for _ in 0..<120 {
            let (bytes, ids) = randomFile(&rng)
            guard bytes.count < SpikeRunStore.compactAtBytes - 8_192 else { continue }
            for id in ids.prefix(2) + [UUID()] {
                let fresh = SpikeRunStorageLocation.ephemeral(id: UUID())
                defer { try? FileManager.default.removeItem(at: fresh.directory) }
                let freshURL = fresh.directory.appendingPathComponent("\(spikeID).jsonl")
                try FileManager.default.createDirectory(at: fresh.directory, withIntermediateDirectories: true)
                try bytes.write(to: freshURL)
                let expected = ObsReadQAOracle.revision(of: id, in: bytes) + 1
                let before = SpikeRunStore.wholeFileReads
                XCTAssertTrue(SpikeRunStore.finishRun(
                    ObsReadQABytes.run(id: id, spikeID: spikeID, revision: nil), owner: .explicit(nil), location: fresh))
                if SpikeRunStore.wholeFileReads != before { undetermined += 1 }
                let after = try Data(contentsOf: freshURL)
                let last = try XCTUnwrap(after.split(separator: 0x0A).last)
                let written = try ObsReadQAOracle.decoder().decode(SpikeRun.self, from: Data(last))
                XCTAssertEqual(written.id, id)
                XCTAssertEqual(written.revision, expected)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 200)
        XCTAssertGreaterThan(undetermined, 0, "liveness: some appends went the full-read way")
        XCTAssertLessThan(undetermined, checked / 2, "most appends did not read the whole file")
    }

    // MARK: Positive controls

    private func violations(of scanner: @escaping (UUID, URL) -> SpikeRunFileScan.Latest) throws -> Tally {
        var rng = ObsReadQARandom(seed: 0x0B5_2EAD_0003)
        var tally = Tally()
        for round in 0..<200 {
            let (bytes, ids) = randomFile(&rng)
            try bytes.write(to: url)
            check(scanner, data: bytes, ids: ids + [UUID()], label: "round \(round)", into: &tally)
        }
        for (bytes, target, label) in edgeFiles() {
            try bytes.write(to: url)
            check(scanner, data: bytes, ids: [target], label: label, into: &tally)
        }
        return tally
    }

    func testTheHarnessPassesACorrectScannerOfItsOwn() throws {
        let tally = try violations(of: ObsReadQAControlScanner.scanner(.init()))
        XCTAssertEqual(tally.violations, [], "a correct scanner is not flagged")
        XCTAssertGreaterThan(tally.found, 0)
    }

    func testTheHarnessCatchesASearchWhoseChunksDoNotOverlap() throws {
        var config = ObsReadQAControlScanner.Config()
        config.overlap = false
        XCTAssertGreaterThan(try violations(of: ObsReadQAControlScanner.scanner(config)).violations.count, 0)
    }

    func testTheHarnessCatchesACaseSensitiveSearch() throws {
        var config = ObsReadQAControlScanner.Config()
        config.caseInsensitive = false
        XCTAssertGreaterThan(try violations(of: ObsReadQAControlScanner.scanner(config)).violations.count, 0)
    }

    func testTheHarnessCatchesASearchThatReturnsTheOldestLine() throws {
        var config = ObsReadQAControlScanner.Config()
        config.newestFirst = false
        XCTAssertGreaterThan(try violations(of: ObsReadQAControlScanner.scanner(config)).violations.count, 0)
    }

    /// Skipping an undecodable candidate instead of asking the full read is
    /// wrong exactly when the installed reader DOES decode the line: a byte
    /// that is not UTF-8 inside a note, which the installed reader maps to
    /// U+FFFD before JSON and a raw-byte decode rejects.
    func testTheHarnessCatchesASearchThatSkipsAnUndecodableCandidate() throws {
        var config = ObsReadQAControlScanner.Config()
        config.skipUndecodable = true
        let id = UUID()
        let marker = "MARK"
        let bytes = ObsReadQABytes.line(ObsReadQABytes.run(id: id, spikeID: spikeID, revision: 1))
            + ObsReadQABytes.invalidUTF8InNote(
                ObsReadQABytes.line(ObsReadQABytes.run(id: id, spikeID: spikeID, revision: 2, note: marker + "x")), marker: marker)
        try bytes.write(to: url)
        XCTAssertEqual(ObsReadQAOracle.revision(of: id, in: bytes), 2, "rig: the installed reader decodes the line")
        XCTAssertEqual(ObsReadQAControlScanner.real(id, url), .undetermined, "the real search defers it")
        guard case .found(let run) = ObsReadQAControlScanner.scanner(config)(id, url) else {
            return XCTFail("the control should find the older line")
        }
        XCTAssertEqual(run.revision, 1, "control: skipping returns the stale revision")
        XCTAssertGreaterThan(try violations(of: ObsReadQAControlScanner.scanner(config)).violations.count, 0)
    }
}

// MARK: - Step 5: the launch seed's tail against the full read

@MainActor
final class ObsReadQALaunchSeedTests: XCTestCase {
    private var location: SpikeRunStorageLocation!
    private let maxBytes = ResidentObservationCenter.seedTailBytes
    private let maxDecodes = ResidentObservationCenter.seedMaxDecodes
    /// Noon today in whole seconds: today's bounds, whatever the hour.
    private let noon = Date(timeIntervalSinceReferenceDate: Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: Date())!.timeIntervalSinceReferenceDate.rounded(.down))
    private var centers: [ResidentObservationCenter] = []

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        try? FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for center in centers { center.deactivate() }
        centers = []
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        location = nil
        super.tearDown()
    }

    private var url: URL {
        location.directory.appendingPathComponent("\(FixObservationRegistry.residentDailySpikeID).jsonl")
    }

    private var todaysBounds: ResidentDayBounds { ResidentDayBounds.compute(for: noon, calendar: .current) }

    private struct Claim: Hashable {
        var build: Int
        var owner: String?
        var key: TelemetryClaimKey {
            TelemetryClaimKey(buildConfiguration: "release", appBuild: String(build), osVersion: "26.0", ownerUID: owner)
        }
    }

    private func matcher(_ claim: Claim) -> (SpikeRun) -> Bool {
        let bounds = todaysBounds
        let key = claim.key
        return { bounds.contains($0.startedAt) && TelemetryClaimKey(run: $0) == key }
    }

    /// A daily line as the center writes one, about 1 to 3.2 KB.
    private func daily(_ id: UUID, startedAt: Date, claim: Claim, revision: Int, rng: inout ObsReadQARandom) -> SpikeRun {
        var counters = ResidentCounterSet()
        counters.meComputedVisible = revision
        counters.tapCount = Int.random(in: 0...500, using: &rng)
        var metrics = counters.metrics
        metrics["follower.qa.histogram"] = .string(String(repeating: "7 ", count: Int.random(in: 0...1_000, using: &rng)))
        var run = ObsReadQABytes.run(
            id: id, spikeID: FixObservationRegistry.residentDailySpikeID, startedAt: startedAt, revision: revision,
            build: String(claim.build), owner: claim.owner, metrics: metrics)
        run.kind = .dailyRollup
        return run
    }

    private struct History {
        var bytes = Data()
        var lastClaim = Claim(build: 10, owner: "owner-a")
        var claimsToday: [Claim] = []
    }

    /// The center's own writing discipline: one live id at a time, several
    /// lines per id, starts moving forward; builds and owners change, and a
    /// consent re-mint or a missed seed starts a second id under the same
    /// claim; days roll over. Cut, from the front at a line boundary, to
    /// about the device file's 240 KB.
    private func centerHistory(_ rng: inout ObsReadQARandom) -> History {
        var history = History()
        var claim = history.lastClaim
        let calendar = Calendar.current
        for back in stride(from: Int.random(in: 0...40, using: &rng), through: 0, by: -1) {
            let dayStart = calendar.startOfDay(for: noon.addingTimeInterval(-86_400 * Double(back)))
            let isToday = back == 0
            let count = Int.random(in: 1...4, using: &rng)
            for index in 0..<count {
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: claim.build += 1
                case 1: claim.owner = claim.owner == nil ? (Bool.random(using: &rng) ? "owner-a" : "owner-b") : nil
                default: break
                }
                // Strictly later starts, all before today's noon launch.
                let start = dayStart.addingTimeInterval(3_600 + Double(index) * (10 * 3_600 / Double(count)))
                    .addingTimeInterval(Double(Int.random(in: 0...600, using: &rng)))
                let id = UUID()
                for revision in 1...Int.random(in: 1...(Bool.random(using: &rng) ? 4 : 40), using: &rng) {
                    history.bytes += ObsReadQABytes.line(daily(id, startedAt: start, claim: claim, revision: revision, rng: &rng))
                }
                if isToday { history.claimsToday.append(claim) }
            }
        }
        if history.bytes.count > 240_000 {
            let cut = history.bytes.count - 240_000
            let newline = history.bytes[cut...].firstIndex(of: 0x0A)!
            history.bytes = history.bytes.subdata(in: (newline + 1)..<history.bytes.endIndex)
        }
        history.lastClaim = claim
        return history
    }

    /// Whether the tail can see the full read's record: its newest line
    /// wholly inside the last `maxBytes`, within `maxDecodes` lines of the end.
    private func reachable(_ record: SpikeRun, in bytes: Data) -> Bool {
        let windowStart = max(0, bytes.count - maxBytes)
        var segments: [(start: Int, end: Int)] = []
        var lineStart = 0
        bytes.withUnsafeBytes { raw in
            for index in 0..<raw.count where raw[index] == 0x0A {
                if index > lineStart { segments.append((lineStart, index)) }
                lineStart = index + 1
            }
        }
        if lineStart < bytes.count { segments.append((lineStart, bytes.count)) }
        let decoder = ObsReadQAOracle.decoder()
        for (rank, segment) in segments.reversed().enumerated() {
            guard let run = try? decoder.decode(SpikeRun.self, from: bytes.subdata(in: segment.start..<segment.end)),
                  run.id == record.id else { continue }
            return segment.start >= windowStart && rank < maxDecodes
        }
        return false
    }

    private struct Tally {
        var hits = 0, agreeingMisses = 0, boundMisses = 0
        var violations: [String] = []
    }

    private typealias Seed = (URL, @escaping (SpikeRun) -> Bool) -> SpikeRunFileScan.TailRecord

    private var realSeed: Seed {
        { [maxBytes, maxDecodes] url, matches in
            SpikeRunFileScan.newestMatch(in: url, maxBytes: maxBytes, maxDecodes: maxDecodes, where: matches)
        }
    }

    /// The installed build's seed, given the file's collapsed-and-capped records.
    private func reference(_ retained: [SpikeRun], _ matches: (SpikeRun) -> Bool) -> SpikeRun? {
        retained.filter(matches).max { $0.startedAt < $1.startedAt }
    }

    /// Strict check, for files the center itself writes: a hit is the full
    /// read's record, newest line and all; a miss is allowed only when that
    /// record is out of the tail's reach.
    private func checkStrict(_ seed: Seed, bytes: Data, retained: [SpikeRun], claim: Claim, label: String,
                             into tally: inout Tally) {
        let matches = matcher(claim)
        let reference = reference(retained, matches)
        switch seed(url, matches) {
        case .found(let run, let decodes):
            tally.hits += 1
            if run != reference { tally.violations.append("\(label): adopted \(run.id), full read \(reference?.id.uuidString ?? "nil")") }
            if decodes > maxDecodes { tally.violations.append("\(label): \(decodes) decodes") }
        case .miss(let reason, let decodes):
            if decodes > maxDecodes { tally.violations.append("\(label): \(decodes) decodes") }
            guard let reference else { tally.agreeingMisses += 1; return }
            if reachable(reference, in: bytes) {
                tally.violations.append("\(label): missed (\(reason.rawValue)) a record within the tail's reach")
            } else {
                tally.boundMisses += 1
                if reason == .wholeFile || reason == .noFile {
                    tally.violations.append("\(label): \(reason.rawValue) while the full read has a record")
                }
            }
        }
    }

    private func retained(_ bytes: Data) -> [SpikeRun] {
        ObsReadQAOracle.retention(ObsReadQAOracle.collapse(ObsReadQAOracle.records(bytes)), cap: SpikeRunStore.maxRunsPerSpike)
    }

    /// Launches over the center's own histories: the last claim (adopt), a
    /// new build's first launch (nothing to adopt), and earlier claims of the
    /// day (an account toggled back, a re-mint): the tail always finds the
    /// installed build's record, or misses one that is out of its reach.
    func testOnTheCentersOwnHistoriesTheTailIsTheFullReadOrABoundsMiss() throws {
        var rng = ObsReadQARandom(seed: 0x5EED_0B5_0001)
        var tally = Tally()
        for round in 0..<150 {
            let history = centerHistory(&rng)
            try history.bytes.write(to: url)
            let retained = retained(history.bytes)
            var launches = [history.lastClaim, Claim(build: history.lastClaim.build + 1, owner: history.lastClaim.owner)]
            launches += Array(Set(history.claimsToday)).shuffled(using: &rng).prefix(3)
            for (index, claim) in launches.enumerated() {
                checkStrict(realSeed, bytes: history.bytes, retained: retained, claim: claim,
                            label: "round \(round) launch \(index)", into: &tally)
            }
        }
        XCTAssertEqual(tally.violations, [], tally.violations.prefix(5).joined(separator: "\n"))
        XCTAssertGreaterThan(tally.hits, 100, "liveness: \(tally)")
        XCTAssertGreaterThan(tally.agreeingMisses, 0, "liveness: \(tally)")
        XCTAssertGreaterThan(tally.boundMisses, 0, "liveness: some records were out of reach (\(tally))")
        print("QA launch seed (center histories): \(tally.hits) hits, \(tally.agreeingMisses) agreeing misses, \(tally.boundMisses) bound misses")
    }

    /// One hostile file. Lines the center never writes but a device can hold:
    /// ids interleaved, starts out of order (a clock stepped back), an id
    /// whose claim changes between its lines, torn lines healed or glued,
    /// blank lines, lines longer than the tail, multi-byte text across the
    /// window's edge, ids in lower or mixed case, a newest line that does
    /// not decode.
    private func hostileFile(_ rng: inout ObsReadQARandom) -> (Data, Set<Claim>) {
        let ids = (0..<Int.random(in: 1...6, using: &rng)).map { _ in UUID() }
        var claims: [UUID: Claim] = [:]
        var starts: [UUID: Date] = [:]
        var revisions: [UUID: Int] = [:]
        var used = Set<Claim>()
        var bytes = Data()
        for _ in 0..<Int.random(in: 1...60, using: &rng) {
            let id = ids.randomElement(using: &rng)!
            if claims[id] == nil || Int.random(in: 0..<10, using: &rng) == 0 {
                claims[id] = Claim(build: Int.random(in: 10...11, using: &rng), owner: Bool.random(using: &rng) ? "owner-a" : nil)
            }
            used.insert(claims[id]!)
            if starts[id] == nil {
                starts[id] = noon.addingTimeInterval(Double(Int.random(in: -100_000...(-1), using: &rng)))
            }
            revisions[id, default: 0] += 1
            var run = daily(id, startedAt: starts[id]!, claim: claims[id]!, revision: revisions[id]!, rng: &rng)
            switch Int.random(in: 0..<12, using: &rng) {
            case 0: run.note = String(repeating: "x", count: Int.random(in: maxBytes...(maxBytes + 4_000), using: &rng))
            case 1, 2:
                run.note = (0..<Int.random(in: 1...3_000, using: &rng))
                    .map { _ in ObsReadQABytes.multiByte.randomElement(using: &rng)! }.joined()
            default: break
            }
            var line = ObsReadQABytes.line(run)
            if Int.random(in: 0..<5, using: &rng) == 0 { line = ObsReadQABytes.recase(line, id: id, rng: &rng) }
            if Int.random(in: 0..<20, using: &rng) == 0 { line = ObsReadQABytes.undecodable(line) }
            switch Int.random(in: 0..<14, using: &rng) {
            case 0: line = line.prefix(Int.random(in: 1..<(line.count - 1), using: &rng)) + Data([0x0A])
            case 1: line = line.prefix(Int.random(in: 1..<(line.count - 1), using: &rng))
            case 2: line += Data(repeating: 0x0A, count: Int.random(in: 1...3, using: &rng))
            default: break
            }
            bytes += line
        }
        return (bytes, used)
    }

    /// The seed on hostile files may miss, or pick another same-day,
    /// same-claim id (attack N1). It must never adopt a line that is not its
    /// id's newest decodable line — the center would write those stale counts
    /// back over newer ones — never adopt a record that does not match,
    /// never adopt when the installed build finds nothing, and never break
    /// the decode budget.
    func testOnHostileFilesTheSeedNeverAdoptsAStaleOrForeignLine() throws {
        var rng = ObsReadQARandom(seed: 0x5EED_0B5_0002)
        var tally = Tally()
        var differ = 0
        for round in 0..<250 {
            let (bytes, claims) = hostileFile(&rng)
            try bytes.write(to: url)
            let collapsed = ObsReadQAOracle.collapse(ObsReadQAOracle.records(bytes))
            let newest = Dictionary(uniqueKeysWithValues: collapsed.map { ($0.id, $0) })
            let retained = ObsReadQAOracle.retention(collapsed, cap: SpikeRunStore.maxRunsPerSpike)
            for claim in claims {
                let matches = matcher(claim)
                let reference = reference(retained, matches)
                switch realSeed(url, matches) {
                case .found(let run, let decodes):
                    tally.hits += 1
                    if !matches(run) { tally.violations.append("round \(round): adopted a record that does not match") }
                    if run != newest[run.id] {
                        tally.violations.append("round \(round): adopted a stale line of \(run.id) (revision \(run.revision ?? -1), newest \(newest[run.id]?.revision ?? -1))")
                    }
                    if decodes > maxDecodes { tally.violations.append("round \(round): \(decodes) decodes") }
                    if reference == nil { tally.violations.append("round \(round): adopted while the full read finds nothing") }
                    if let reference, reference.id != run.id { differ += 1 }
                case .miss(let reason, let decodes):
                    if decodes > maxDecodes { tally.violations.append("round \(round): \(decodes) decodes") }
                    if reason == .wholeFile, let reference {
                        tally.violations.append("round \(round): whole_file miss while the full read has \(reference.id)")
                    }
                    if reference == nil { tally.agreeingMisses += 1 } else { tally.boundMisses += 1 }
                }
            }
        }
        // `differ` is attack N1's case — another same-day, same-claim id,
        // newest by append order rather than by start. Reported, not failed.
        print("QA launch seed (hostile files): \(tally.hits) hits (\(differ) another same-day id), \(tally.agreeingMisses) agreeing misses, \(tally.boundMisses) misses; violations \(tally.violations.count)")
        XCTAssertEqual(tally.violations, [], tally.violations.prefix(5).joined(separator: "\n"))
        XCTAssertGreaterThan(tally.hits, 50)
        XCTAssertGreaterThan(differ, 0, "liveness: the hostile mix produced N1's case")
    }

    /// The one shape on which the two fast reads part ways. A byte that is
    /// not UTF-8 inside the newest line of today's id: the installed reader
    /// maps it to U+FFFD and keeps that line; the revision search defers it
    /// to the full read (`.undetermined`); the tail seed skips it and adopts
    /// the id's OLDER line, whose counts the center would then write back
    /// over the newer ones. The center never writes such a byte (every daily
    /// field is an ASCII-only encode), so this needs a file from outside the
    /// app. Expected to fail until the seed treats an undecodable line that
    /// may be an id's newest the way the revision search does.
    func testAnUndecodableNewestLineOfTodaysIDIsNotSkippedPastToAStaleLine() throws {
        var rng = ObsReadQARandom(seed: 7)
        let claim = Claim(build: 10, owner: "owner-a")
        let id = UUID()
        let start = noon.addingTimeInterval(-3_600)
        var newer = daily(id, startedAt: start, claim: claim, revision: 2, rng: &rng)
        newer.note = "MARK-newer"
        let bytes = ObsReadQABytes.line(daily(id, startedAt: start, claim: claim, revision: 1, rng: &rng))
            + ObsReadQABytes.invalidUTF8InNote(ObsReadQABytes.line(newer), marker: "MARK")
        try bytes.write(to: url)
        let matches = matcher(claim)
        let reference = try XCTUnwrap(reference(retained(bytes), matches), "rig: the installed reader keeps the newer line")
        XCTAssertEqual(reference.revision, 2)
        var decodes = 0
        XCTAssertEqual(SpikeRunFileScan.latestLine(of: id, in: url, decodedLines: &decodes), .undetermined,
                       "the revision search defers this line")
        XCTExpectFailure("RISK (not reachable from the app's own writes): the tail seed skips an undecodable newest line and adopts the id's older line")
        if case .found(let run, _) = realSeed(url, matches) {
            XCTAssertEqual(run.revision, 2, "the seed adopted a stale line of today's id")
        }
    }

    // MARK: Positive controls

    private func strictViolations(_ seed: @escaping Seed) throws -> Int {
        var rng = ObsReadQARandom(seed: 0x5EED_0B5_0001)
        var tally = Tally()
        for round in 0..<60 {
            let history = centerHistory(&rng)
            try history.bytes.write(to: url)
            let retained = retained(history.bytes)
            var launches = [history.lastClaim]
            launches += Array(Set(history.claimsToday)).shuffled(using: &rng).prefix(3)
            for (index, claim) in launches.enumerated() {
                checkStrict(seed, bytes: history.bytes, retained: retained, claim: claim,
                            label: "round \(round) launch \(index)", into: &tally)
            }
        }
        return tally.violations.count
    }

    /// A tail reader of the test's own, with the real one's window and budget
    /// rules, and knobs that break them.
    private func controlSeed(window: Int? = nil, oldestFirst: Bool = false) -> Seed {
        { [maxBytes, maxDecodes] url, matches in
            let data = (try? Data(contentsOf: url)) ?? Data()
            let start = max(0, data.count - (window ?? maxBytes))
            var bytes = data.subdata(in: max(0, start - 1)..<data.count)
            if start > 0 {
                guard let newline = bytes.firstIndex(of: 0x0A) else { return .miss(.window, decodedLines: 0) }
                bytes = bytes.subdata(in: (newline + 1)..<bytes.endIndex)
            }
            var seen = Set<UUID>()
            var candidates: [SpikeRun] = []
            for line in bytes.split(separator: 0x0A).reversed().prefix(maxDecodes) {
                guard let run = try? ObsReadQAOracle.decoder().decode(SpikeRun.self, from: Data(line)) else { continue }
                guard seen.insert(run.id).inserted else { continue }
                if matches(run) { candidates.append(run) }
            }
            if let pick = oldestFirst ? candidates.last : candidates.first { return .found(pick, decodedLines: 1) }
            return .miss(.window, decodedLines: 0)
        }
    }

    func testTheStrictCheckPassesACorrectSeedOfItsOwn() throws {
        XCTAssertEqual(try strictViolations(controlSeed()), 0)
    }

    func testTheStrictCheckCatchesATailThatIsTooShort() throws {
        XCTAssertGreaterThan(try strictViolations(controlSeed(window: 2_048)), 0)
    }

    func testTheStrictCheckCatchesASeedThatPicksTheOlderMatch() throws {
        XCTAssertGreaterThan(try strictViolations(controlSeed(oldestFirst: true)), 0)
    }

    // MARK: Through the center

    /// The launch itself, end to end: the center's next day line goes to the
    /// id the installed build would have adopted when that record is in the
    /// tail's reach (counts summed onto it), and to a fresh id otherwise —
    /// never to a third record's id.
    func testTheCentersNextDayLineGoesWhereTheInstalledBuildsWouldOrToAFreshID() throws {
        var rng = ObsReadQARandom(seed: 0x5EED_0B5_0003)
        var adopted = 0
        var fresh = 0
        for round in 0..<40 {
            let history = centerHistory(&rng)
            try history.bytes.write(to: url)
            let claim = Bool.random(using: &rng) ? history.lastClaim : (history.claimsToday.randomElement(using: &rng) ?? history.lastClaim)
            let reference = reference(retained(history.bytes), matcher(claim))
            let knownIDs = Set(ObsReadQAOracle.collapse(ObsReadQAOracle.records(history.bytes)).map(\.id))

            let clock = noon
            let center = ResidentObservationCenter(
                coordinator: SpikeSessionCoordinator(), store: nil, location: location, calendar: .current,
                now: { clock }, mediaNow: { 500 }, makeFrameProbe: { SpikeFrameProbe() },
                ownerUID: { claim.owner },
                stamp: {
                    SpikeRunContext.Stamp(appVersion: "0.5.0", appBuild: String(claim.build), appCommit: nil,
                                          deviceModel: "iPhone17,2", osVersion: "26.0", timeZoneIdentifier: "UTC",
                                          localeIdentifier: "en_US", buildConfiguration: "release")
                },
                verifiesSeed: false)
            centers.append(center)
            center.activate()
            SpikeProbe.emit(.counter(FixWatchSignalID.meComputedVisible))
            center.flushDaily()
            center.deactivate()

            let written = try XCTUnwrap(ObsReadQAOracle.records(try Data(contentsOf: url)).last, "round \(round)")
            if let reference, reachable(reference, in: history.bytes) {
                XCTAssertEqual(written.id, reference.id, "round \(round): the day the installed build adopted")
                XCTAssertEqual(ResidentCounterSet(metrics: written.metrics).meComputedVisible,
                               ResidentCounterSet(metrics: reference.metrics).meComputedVisible + 1, "round \(round): counts summed")
                adopted += 1
            } else {
                XCTAssertFalse(knownIDs.contains(written.id), "round \(round): a fresh id, never another record's")
                XCTAssertEqual(ResidentCounterSet(metrics: written.metrics).meComputedVisible, 1)
                fresh += 1
            }
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertGreaterThan(adopted, 0)
        XCTAssertGreaterThan(fresh, 0)
    }
}
