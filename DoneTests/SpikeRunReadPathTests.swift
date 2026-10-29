//
//  SpikeRunReadPathTests.swift
//  DoneTests
//
//  The spike-run reads that run on the main thread, made to read only what
//  they need (red-team design R3 / R1, attack S6 / M2). Every fast answer is
//  held against the full read's (`SpikeRunStore.loadRuns`), which stays the
//  reference: the fast path either agrees with it, falls back to it, or — for
//  the launch seed only — misses, which mints a fresh same-day id.
//

import XCTest
@testable import Done

// MARK: - Fixture bytes

/// Lines written past the store, so a test controls every byte of the file.
@MainActor
enum SpikeRunFixtureBytes {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func run(
        id: UUID = UUID(), spikeID: String, startedAt: Date = Date(timeIntervalSince1970: 1_790_000_000),
        revision: Int?, note: String? = nil, installID: UUID? = nil
    ) -> SpikeRun {
        var run = SpikeRun(
            id: id, spikeID: spikeID, scenarioID: "sc", variantID: nil,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1),
            appVersion: "1.0", appBuild: "1", appCommit: nil,
            deviceModel: "iPhone99,1", osVersion: "99.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
            metrics: ["n": .number(1)], note: note, outcome: .completed, abortReason: nil
        )
        run.revision = revision
        run.installID = installID
        return run
    }

    /// One line exactly as the store writes it, newline included.
    static func line(_ run: SpikeRun) -> Data {
        var data = try! encoder().encode(run)
        data.append(0x0A)
        return data
    }

    static func fileURL(spikeID: String, location: SpikeRunStorageLocation) -> URL {
        location.directory.appendingPathComponent("\(spikeID).jsonl")
    }

    static func write(_ bytes: Data, spikeID: String, location: SpikeRunStorageLocation) {
        try! FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try! bytes.write(to: fileURL(spikeID: spikeID, location: location))
    }
}

// MARK: - R3: the revision lookup

@MainActor
final class SpikeRunRevisionLookupTests: XCTestCase {
    private let spikeID = "revision-lookup"
    private var location: SpikeRunStorageLocation!

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: location.directory)
        location = nil
        super.tearDown()
    }

    private func line(_ id: UUID, revision: Int?, note: String? = nil, installID: UUID? = nil) -> Data {
        SpikeRunFixtureBytes.line(SpikeRunFixtureBytes.run(id: id, spikeID: spikeID, revision: revision,
                                                           note: note, installID: installID))
    }

    private func write(_ bytes: Data) {
        SpikeRunFixtureBytes.write(bytes, spikeID: spikeID, location: location)
    }

    /// A line cut short by a kill mid-append, still holding the id's text —
    /// `JSONEncoder`'s key order is not stable, so the cut is placed from
    /// where the id actually landed, never from a fixed offset.
    private func tornLine(_ id: UUID, revision: Int) throws -> Data {
        let full = line(id, revision: revision)
        let text = String(decoding: full, as: UTF8.self)
        let idEnd = try XCTUnwrap(text.range(of: id.uuidString)).upperBound.utf16Offset(in: text)
        let torn = full.prefix(max(idEnd, full.count - 9))
        XCTAssertNil(try? SpikeRunFixtureBytes.decoder().decode(SpikeRun.self, from: torn), "rig: the line is torn")
        return torn
    }

    /// The full read's answer: the revision on the line collapse keeps.
    private func reference(_ id: UUID) -> Int {
        SpikeRunStore.loadRuns(spikeID: spikeID, location: location, applyRetention: false)
            .first { $0.id == id }?.revision ?? 0
    }

    private func scan(_ id: UUID) -> (SpikeRunFileScan.Latest, decodes: Int) {
        var decodes = 0
        let latest = SpikeRunFileScan.latestLine(
            of: id, in: SpikeRunFixtureBytes.fileURL(spikeID: spikeID, location: location), decodedLines: &decodes)
        return (latest, decodes)
    }

    private func assertFound(_ id: UUID, revision: Int, decodes expected: Int,
                             file: StaticString = #filePath, line: UInt = #line) {
        let (latest, decodes) = scan(id)
        guard case .found(let run) = latest else {
            return XCTFail("expected a found line, got \(latest)", file: file, line: line)
        }
        XCTAssertEqual(run.id, id, file: file, line: line)
        XCTAssertEqual(run.revision, revision, file: file, line: line)
        XCTAssertEqual(reference(id), revision, "the full read agrees", file: file, line: line)
        XCTAssertEqual(decodes, expected, "decoded lines", file: file, line: line)
    }

    // The shapes the attack's prototype (p1-uuid) ran, each against the full read.

    func testTheIDsTextInALaterLinesNoteIsRejectedAndTheRealLineFound() {
        let x = UUID(), y = UUID()
        write(line(x, revision: 3) + line(y, revision: 1, note: "see \(x.uuidString)"))
        assertFound(x, revision: 3, decodes: 2)
    }

    /// Attack S6: the search resumes before the rejected LINE, not before the
    /// hit — a note repeating the id two thousand times costs one decode for
    /// that line, and the note is longer than one search chunk.
    func testANoteRepeatingTheIDCostsOneDecodeNotOnePerCopy() {
        let x = UUID(), y = UUID()
        let note = String(repeating: x.uuidString + " ", count: 2_000)
        XCTAssertGreaterThan(note.utf8.count, SpikeRunFileScan.searchChunkBytes, "rig: the line spans chunks")
        write(line(x, revision: 7) + line(y, revision: 1, note: note))
        assertFound(x, revision: 7, decodes: 2)
    }

    func testTheLatestOfSeveralLinesForTheIDWins() {
        let x = UUID(), y = UUID()
        // A compacted part (one line per id), then lines appended after it.
        write(line(y, revision: 9) + line(x, revision: 3) + line(x, revision: 4))
        assertFound(x, revision: 4, decodes: 1)
    }

    func testTheIDOnlyAsAnotherLinesInstallIDIsAbsent() {
        let x = UUID(), y = UUID()
        write(line(y, revision: 1, installID: x))
        let (latest, decodes) = scan(x)
        XCTAssertEqual(latest, .absent)
        XCTAssertEqual(decodes, 1, "the candidate was decoded and rejected")
        XCTAssertEqual(reference(x), 0)
    }

    func testAFreshIDDecodesNothing() {
        write(line(UUID(), revision: 2) + line(UUID(), revision: 5))
        let (latest, decodes) = scan(UUID())
        XCTAssertEqual(latest, .absent)
        XCTAssertEqual(decodes, 0)
    }

    func testAMissingOrEmptyFileIsAbsent() {
        XCTAssertEqual(scan(UUID()).0, .absent, "no file")
        write(Data())
        XCTAssertEqual(scan(UUID()).0, .absent, "empty file")
    }

    func testANULFilledTailAfterAGoodLine() {
        let x = UUID()
        write(line(x, revision: 6) + Data(repeating: 0, count: 300))
        assertFound(x, revision: 6, decodes: 1)
    }

    /// Attack N4: `JSONDecoder` reads a lower-case (or mixed-case) id; the
    /// store writes upper case, but fixtures and copied-in files need not. An
    /// upper-case-only search returned 0 where the full read returned 5.
    func testALowerOrMixedCaseIDIsFoundAsTheFullReadFindsIt() {
        let x = UUID(), y = UUID()
        let lower = String(decoding: line(x, revision: 5), as: UTF8.self)
            .replacingOccurrences(of: x.uuidString, with: x.uuidString.lowercased())
        let mixedY = y.uuidString.enumerated()
            .map { $0.offset.isMultiple(of: 2) ? $0.element.lowercased() : String($0.element) }
            .joined()
        let mixed = String(decoding: line(y, revision: 8), as: UTF8.self)
            .replacingOccurrences(of: y.uuidString, with: mixedY)
        XCTAssertNotEqual(mixedY, y.uuidString, "rig: the id's case changed")
        write(Data(lower.utf8) + Data(mixed.utf8))
        assertFound(x, revision: 5, decodes: 1)
        assertFound(y, revision: 8, decodes: 1)
    }

    /// An occurrence across a search-chunk edge is seen exactly once.
    func testAnIDStraddlingASearchChunkEdgeIsFound() throws {
        let x = UUID(), y = UUID()
        let target = line(x, revision: 11)
        let idOffset = try XCTUnwrap(String(decoding: target, as: UTF8.self).range(of: x.uuidString)).lowerBound.utf16Offset(
            in: String(decoding: target, as: UTF8.self))
        // Filler after the target sized so the chunk read from EOF starts in
        // the middle of the id's 36 characters.
        let fillerBase = line(y, revision: 1, note: "").count
        let wanted = SpikeRunFileScan.searchChunkBytes - (target.count - idOffset) + 18
        let filler = line(y, revision: 1, note: String(repeating: "f", count: wanted - fillerBase))
        XCTAssertEqual(filler.count, wanted, "rig: the filler has the computed size")
        let bytes = target + filler
        XCTAssertTrue((idOffset..<(idOffset + 36)).contains(bytes.count - SpikeRunFileScan.searchChunkBytes),
                      "rig: the first chunk edge falls inside the id")
        write(bytes)
        assertFound(x, revision: 11, decodes: 1)
    }

    // Lines that hold the id's text but do not decode: the full read decides.

    func testATornLastLineOfTheIDIsTheFullReadsCall() throws {
        let x = UUID()
        write(line(x, revision: 4) + (try tornLine(x, revision: 5)))
        XCTAssertEqual(scan(x).0, .undetermined)
        XCTAssertEqual(reference(x), 4)
    }

    func testAFutureSchemaLatestLineIsTheFullReadsCall() {
        let x = UUID()
        let future = String(decoding: line(x, revision: 3), as: UTF8.self)
            .replacingOccurrences(of: "\"outcome\":\"completed\"", with: "\"outcome\":\"a-newer-outcome\"")
        XCTAssertNotEqual(future, String(decoding: line(x, revision: 3), as: UTF8.self), "rig: the line changed")
        write(line(x, revision: 2) + Data(future.utf8))
        XCTAssertEqual(scan(x).0, .undetermined)
        XCTAssertEqual(reference(x), 2)
    }

    /// The byte-level oracle (attack S5). `loadRuns` splits a Swift `String`
    /// on `Character("\n")`, and `"\r\n"` is ONE character, so a CRLF file is
    /// a single undecodable line to it; the scan frames on the `\n` byte and
    /// finds the true latest revision. No writer of these files emits a raw
    /// CR, so on everything the app writes the two agree; here the scan's
    /// answer is the higher one, which is the safe side for a revision.
    func testACRLFFileIsReadAtTheByteLevel() {
        let x = UUID()
        var bytes = Data()
        for revision in [1, 2] {
            var one = line(x, revision: revision)
            one.removeLast()
            bytes += one + Data([0x0D, 0x0A])
        }
        write(bytes)
        XCTAssertEqual(reference(x), 0, "the String split sees one line")
        guard case .found(let run) = scan(x).0 else { return XCTFail("the byte framing sees two") }
        XCTAssertEqual(run.revision, 2)
    }

    /// Random files of the shapes the app can write, plus notes holding other
    /// ids' text in any case and terminated torn lines: every answer is the
    /// full read's, or a fallback to it where a line with the id's text does
    /// not decode.
    func testRandomFilesAgreeWithTheFullRead() {
        var rng = SeededReadPathRandom(seed: 0x5EED_0B5E)
        var tally = (found: 0, absent: 0, undetermined: 0)
        for _ in 0..<150 {
            let ids = (0..<4).map { _ in UUID() }
            var revisions = [UUID: Int]()
            var bytes = Data()
            for _ in 0..<Int.random(in: 1...24, using: &rng) {
                let id = ids.randomElement(using: &rng)!
                revisions[id, default: 0] += 1
                var note: String?
                if Int.random(in: 0..<3, using: &rng) == 0 {
                    let other = ids.randomElement(using: &rng)!.uuidString
                    note = "about " + (Bool.random(using: &rng) ? other : other.lowercased())
                }
                var one = line(id, revision: revisions[id], note: note)
                if Int.random(in: 0..<12, using: &rng) == 0 {
                    // A kill mid-append, then a healed append after it.
                    one = one.prefix(Int.random(in: 1..<(one.count - 1), using: &rng)) + Data([0x0A])
                }
                bytes += one
            }
            write(bytes)
            let text = String(decoding: bytes, as: UTF8.self)
            for id in ids + [UUID()] {
                let (latest, _) = scan(id)
                switch latest {
                case .found(let run):
                    tally.found += 1
                    XCTAssertEqual(run.revision, reference(id))
                case .absent:
                    tally.absent += 1
                    XCTAssertEqual(reference(id), 0)
                    let holders = text.split(separator: "\n").filter {
                        $0.range(of: id.uuidString, options: .caseInsensitive) != nil
                    }
                    for holder in holders {
                        let decoded = try? SpikeRunFixtureBytes.decoder().decode(SpikeRun.self, from: Data(holder.utf8))
                        XCTAssertNotNil(decoded, "absent only when every line with the id's text is another id's")
                        XCTAssertNotEqual(decoded?.id, id)
                    }
                case .undetermined:
                    tally.undetermined += 1
                    let undecodableHolder = text.split(separator: "\n").contains { line in
                        line.range(of: id.uuidString, options: .caseInsensitive) != nil
                            && (try? SpikeRunFixtureBytes.decoder().decode(SpikeRun.self, from: Data(line.utf8))) == nil
                    }
                    XCTAssertTrue(undecodableHolder, "only an undecodable line with the id's text defers")
                }
            }
        }
        XCTAssertGreaterThan(tally.found, 0, "liveness")
        XCTAssertGreaterThan(tally.absent, 0, "liveness")
        XCTAssertGreaterThan(tally.undetermined, 0, "liveness")
    }

    // Through the store: the appends that used to read the whole file.

    /// A window close (always a fresh id) and the day's re-append (its own
    /// line at the end) both stamp the right revision without a whole-file
    /// read; a torn line holding the id falls back to one and still stamps
    /// the full read's answer plus one.
    func testAppendsStampTheRevisionWithoutAWholeFileRead() throws {
        var bytes = Data()
        for _ in 0..<20 { bytes += line(UUID(), revision: 3) }
        let day = UUID()
        bytes += line(day, revision: 7)
        write(bytes)

        let before = SpikeRunStore.wholeFileReads
        let fresh = SpikeRunFixtureBytes.run(spikeID: spikeID, revision: nil)
        XCTAssertTrue(SpikeRunStore.finishRun(fresh, owner: .explicit(nil), location: location))
        XCTAssertTrue(SpikeRunStore.finishRun(SpikeRunFixtureBytes.run(id: day, spikeID: spikeID, revision: nil),
                                              owner: .explicit(nil), location: location))
        XCTAssertEqual(SpikeRunStore.wholeFileReads, before, "neither append read the whole file")

        XCTAssertEqual(reference(fresh.id), 1)
        XCTAssertEqual(reference(day), 8)
    }

    func testATornLineWithTheIDFallsBackToTheFullReadForTheRevision() throws {
        let x = UUID()
        write(line(x, revision: 4) + (try tornLine(x, revision: 5)) + Data([0x0A]))

        let before = SpikeRunStore.wholeFileReads
        XCTAssertTrue(SpikeRunStore.finishRun(SpikeRunFixtureBytes.run(id: x, spikeID: spikeID, revision: nil),
                                              owner: .explicit(nil), location: location))
        XCTAssertEqual(SpikeRunStore.wholeFileReads, before + 1, "the fallback is the full read")
        XCTAssertEqual(reference(x), 5, "the full read's 4, plus one")
    }
}

/// A seeded generator, so a failing random case reproduces.
private struct SeededReadPathRandom: RandomNumberGenerator {
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

// MARK: - I2: the healing newline

/// A kill mid-append leaves an unterminated last line. The next append used
/// to land directly after it: the two became one undecodable line and BOTH
/// records were lost to every reader. The store now closes the torn line off
/// with a newline of its own before appending.
@MainActor
final class SpikeRunHealingAppendTests: XCTestCase {
    private let spikeID = "healing-append"
    private var location: SpikeRunStorageLocation!

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: location.directory)
        location = nil
        super.tearDown()
    }

    private var url: URL { SpikeRunFixtureBytes.fileURL(spikeID: spikeID, location: location) }

    private func record(_ id: UUID = UUID(), revision: Int? = nil) -> SpikeRun {
        SpikeRunFixtureBytes.run(id: id, spikeID: spikeID, revision: revision)
    }

    func testAnAppendAfterATornLastLineIsNotGluedToIt() throws {
        let kept = record(revision: 1)
        var torn = SpikeRunFixtureBytes.line(record(revision: 1))
        torn.removeLast(9)
        let prefix = SpikeRunFixtureBytes.line(kept) + torn
        SpikeRunFixtureBytes.write(prefix, spikeID: spikeID, location: location)

        let next = record()
        XCTAssertTrue(SpikeRunStore.finishRun(next, owner: .explicit(nil), location: location))

        let ids = SpikeRunStore.loadRuns(spikeID: spikeID, location: location).map(\.id)
        XCTAssertEqual(ids, [kept.id, next.id], "the append after a torn line is its own line")
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.prefix(prefix.count + 1), prefix + Data([0x0A]), "the torn line is closed off, not rewritten")
    }

    /// The healing is only for a torn tail: after a whole line the append adds
    /// exactly its own bytes, so the file stays what older builds wrote.
    func testAnAppendAfterAWholeLineAddsNoBlankLine() throws {
        let first = record(revision: 1)
        let prefix = SpikeRunFixtureBytes.line(first)
        SpikeRunFixtureBytes.write(prefix, spikeID: spikeID, location: location)

        XCTAssertTrue(SpikeRunStore.finishRun(record(), owner: .explicit(nil), location: location))

        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.prefix(prefix.count), prefix)
        XCTAssertNotEqual(bytes[prefix.count], 0x0A, "no blank line after a complete one")
        XCTAssertEqual(bytes.last, 0x0A)
        XCTAssertEqual(bytes.split(separator: 0x0A, omittingEmptySubsequences: false).count, 3, "two lines and the final empty tail")
    }

    func testTheFirstAppendToANewFileWritesNoLeadingNewline() throws {
        XCTAssertTrue(SpikeRunStore.finishRun(record(), owner: .explicit(nil), location: location))
        XCTAssertNotEqual(try Data(contentsOf: url).first, 0x0A)
    }
}

// MARK: - R1: the launch seed reads the tail

/// The center adopts today's record at launch from the file's TAIL — at most
/// `seedTailBytes`, at most `seedMaxDecodes` lines — instead of decoding the
/// whole file on the main thread. A record the tail cannot see is a miss,
/// and a miss mints a fresh same-day id, a state the claim rules already
/// produce and the evaluator sums.
@MainActor
final class ResidentLaunchSeedTests: XCTestCase {
    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private var location: SpikeRunStorageLocation!
    private var coordinator: SpikeSessionCoordinator!
    private var centers: [ResidentObservationCenter] = []
    private var trail: [String] = []
    private let owner = Box<String?>("owner-a")
    /// Noon today on the device calendar, in whole seconds (a line's dates
    /// are ISO-8601 to the second): today's bounds, whatever the hour.
    private let noon = Date(timeIntervalSinceReferenceDate: Calendar.current.date(
        bySettingHour: 12, minute: 0, second: 0, of: Date())!.timeIntervalSinceReferenceDate.rounded(.down))

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
        coordinator = SpikeSessionCoordinator()
        trail = []
        owner.value = "owner-a"
    }

    override func tearDown() {
        for center in centers { center.deactivate() }
        centers = []
        SpikeProbe.onSignal = nil
        try? FileManager.default.removeItem(at: location.directory)
        coordinator = nil
        location = nil
        super.tearDown()
    }

    private func stamp(build: String = "10") -> SpikeRunContext.Stamp {
        SpikeRunContext.Stamp(appVersion: "0.5.0", appBuild: build, appCommit: nil, deviceModel: "iPhone17,2",
                              osVersion: "26.0", timeZoneIdentifier: "UTC", localeIdentifier: "en_US",
                              buildConfiguration: "release")
    }

    private func makeCenter(verifies: Bool = false) -> ResidentObservationCenter {
        let clock = noon
        let owner = owner
        let made = ResidentObservationCenter(
            coordinator: coordinator, store: nil, location: location, calendar: .current,
            now: { clock }, mediaNow: { 500 }, makeFrameProbe: { SpikeFrameProbe() },
            ownerUID: { owner.value }, stamp: { [unowned self] in self.stamp() },
            verifiesSeed: verifies,
            seedTrail: { [unowned self] line in self.trail.append(line) }
        )
        centers.append(made)
        return made
    }

    /// A day line as the center writes it, under a claim the test chooses.
    private func daily(_ id: UUID = UUID(), startedAt: Date? = nil, build: String = "10", owner: String? = "owner-a",
                       hidden: Int = 0, note: String? = nil) -> SpikeRun {
        let start = startedAt ?? noon.addingTimeInterval(-3_600)
        var counters = ResidentCounterSet()
        counters.meComputedHidden = hidden
        var run = SpikeRun(
            id: id, spikeID: FixObservationRegistry.residentDailySpikeID,
            scenarioID: FixObservationRegistry.residentDailyScenarioID, variantID: nil,
            startedAt: start, endedAt: start.addingTimeInterval(60),
            appVersion: "0.5.0", appBuild: build, appCommit: nil, deviceModel: "iPhone17,2", osVersion: "26.0",
            timeZoneIdentifier: "UTC", localeIdentifier: "en_US", buildConfiguration: "release",
            metrics: counters.metrics, note: note, outcome: .completed, abortReason: nil
        )
        run.ownerUID = owner
        run.revision = 1
        run.kind = .dailyRollup
        return run
    }

    private func write(_ runs: [SpikeRun]) {
        SpikeRunFixtureBytes.write(runs.reduce(Data()) { $0 + SpikeRunFixtureBytes.line($1) },
                                   spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
    }

    private var dailyURL: URL {
        SpikeRunFixtureBytes.fileURL(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
    }

    private func dailies() -> [SpikeRun] {
        SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location)
    }

    private func olderDays(_ count: Int) -> [SpikeRun] {
        (1...count).map { daily(startedAt: noon.addingTimeInterval(-86_400 * Double($0))) }.reversed()
    }

    private func todaysBounds() -> ResidentDayBounds { ResidentDayBounds.compute(for: noon, calendar: .current) }

    private func claim(owner: String? = "owner-a") -> TelemetryClaimKey {
        TelemetryClaimKey(buildConfiguration: "release", appBuild: "10", osVersion: "26.0", ownerUID: owner)
    }

    private func reference() -> SpikeRun? {
        ResidentObservationCenter.referenceDailyRecord(
            in: SpikeRunStore.loadRuns(spikeID: FixObservationRegistry.residentDailySpikeID, location: location,
                                       applyRetention: false),
            within: todaysBounds(), claim: claim(), retention: SpikeRunStore.maxRunsPerSpike)
    }

    private func waitForVerification(_ center: ResidentObservationCenter, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while center.seedVerification == .pending && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertNotEqual(center.seedVerification, .pending, "the verification came back", file: file, line: line)
    }

    // MARK: The seed

    func testTheSeedAdoptsTodaysLastLineFromOneDecodeWithoutAWholeFileRead() throws {
        let today = daily(hidden: 3)
        write(olderDays(30) + [today])

        let before = SpikeRunStore.wholeFileReads
        let center = makeCenter()
        XCTAssertEqual(SpikeRunStore.wholeFileReads, before, "the launch seed read the whole file")
        XCTAssertEqual(center.launchSeed, .found(today, decodedLines: 1))
        XCTAssertEqual(reference()?.id, today.id, "the full read agrees")

        center.activate()
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        center.flushDaily()
        let written = try XCTUnwrap(dailies().first { $0.id == today.id }, "the adopted id is re-appended")
        XCTAssertEqual(written.metrics["meComputedHidden"], .number(4), "the morning's counts carried over")
    }

    /// Today's record behind more lines than the budget decodes: a miss, a
    /// fresh same-day id, and the tripwire still sums across both records.
    func testTodaysRecordBeyondTheDecodeBudgetIsAMissAndTheDaySums() throws {
        let today = daily(hidden: 3)
        let otherBuild = (0..<ResidentObservationCenter.seedMaxDecodes).map { _ in daily(build: "9") }
        write([today] + otherBuild)

        let center = makeCenter()
        XCTAssertEqual(center.launchSeed, .miss(.cap, decodedLines: ResidentObservationCenter.seedMaxDecodes))
        // Control: with no budget the same tail finds it — the miss is the
        // budget's, not the filter's.
        XCTAssertEqual(SpikeRunFileScan.newestMatch(in: dailyURL, maxBytes: ResidentObservationCenter.seedTailBytes,
                                                    maxDecodes: .max) {
            self.todaysBounds().contains($0.startedAt) && TelemetryClaimKey(run: $0) == self.claim()
        }, .found(today, decodedLines: ResidentObservationCenter.seedMaxDecodes + 1))

        center.activate()
        SpikeProbe.emit(.invariant(FixWatchSignalID.meComputedHidden))
        center.flushDaily()
        let todays = dailies().filter { todaysBounds().contains($0.startedAt) && $0.appBuild == "10" }
        XCTAssertEqual(todays.count, 2, "the missed record and the fresh one")
        XCTAssertFalse(todays.contains { $0.id != today.id && $0.metrics["meComputedHidden"] == .number(4) },
                       "the fresh id did not inherit the missed counts")
        let gate = FixWatchVerdictEvaluator.evaluateMeTabGate(dailies: todays)
        XCTAssertEqual(gate.readouts.first { $0.id == "hidden computes" }?.measured, "4", "the evaluator sums both")
    }

    func testTodaysRecordBeforeTheTailWindowIsAMiss() {
        let today = daily()
        let half = ResidentObservationCenter.seedTailBytes / 2
        let wide = (0..<2).map { _ in daily(build: "9", note: String(repeating: "w", count: half)) }
        write([today] + wide)

        let center = makeCenter()
        // The window starts inside the first wide line: that partial line is
        // not a line, and only the second is decoded.
        XCTAssertEqual(center.launchSeed, .miss(.window, decodedLines: 1))
        XCTAssertEqual(SpikeRunFileScan.newestMatch(in: dailyURL, maxBytes: .max,
                                                    maxDecodes: ResidentObservationCenter.seedMaxDecodes) {
            self.todaysBounds().contains($0.startedAt) && TelemetryClaimKey(run: $0) == self.claim()
        }, .found(today, decodedLines: wide.count + 1), "control: a window that reaches it finds it")
    }

    /// Only today, and only this claim, is ever adopted.
    func testTheSeedAdoptsNoOtherDayAndNoOtherClaim() {
        write([daily(startedAt: noon.addingTimeInterval(-86_400)),   // yesterday, same claim
               daily(owner: "owner-b"), daily(owner: nil), daily(build: "9")])
        let center = makeCenter()
        XCTAssertEqual(center.launchSeed, .miss(.wholeFile, decodedLines: 4))
        XCTAssertNil(reference())
    }

    /// Collapse keeps an id's NEWEST line. When that line does not match, an
    /// older line of the same id that does is not today's record — the tail
    /// skips it as the full read would.
    func testAnOlderLineOfAnIDWhoseNewestLineDoesNotMatchIsNotAdopted() {
        let id = UUID()
        write([daily(id), daily(id, owner: "owner-b")])
        let center = makeCenter()
        XCTAssertEqual(center.launchSeed, .miss(.wholeFile, decodedLines: 2))
        XCTAssertNil(reference(), "the full read agrees: the id's newest line is another owner's")
    }

    func testNoFileIsAMissAndAFreshID() {
        let center = makeCenter()
        XCTAssertEqual(center.launchSeed, .miss(.noFile, decodedLines: 0))
    }

    /// Histories shaped by the center's own writes — one live id at a time,
    /// several lines per id, builds and owners changing, days rolling over —
    /// read at launches along the way: the tail finds the full read's record
    /// or misses; it never adopts a different one.
    func testTheTailNeverDisagreesWithTheFullReadOnTheCentersOwnHistories() {
        var rng = SeededSeedRandom(seed: 0x00C0_FFEE)
        var tally = (agree: 0, miss: 0, found: 0)
        for _ in 0..<40 {
            var runs: [SpikeRun] = []
            var day = noon.addingTimeInterval(-86_400 * 6)
            var build = 10
            var owner: String? = "owner-a"
            while day <= noon {
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    if Int.random(in: 0..<4, using: &rng) == 0 { build += 1 }
                    if Int.random(in: 0..<5, using: &rng) == 0 { owner = owner == nil ? "owner-a" : nil }
                    let id = UUID()
                    let start = day.addingTimeInterval(Double(runs.count))
                    for _ in 0..<Int.random(in: 1...6, using: &rng) {
                        runs.append(daily(id, startedAt: start, build: String(build), owner: owner,
                                          hidden: Int.random(in: 0...3, using: &rng)))
                    }
                }
                day = day.addingTimeInterval(86_400)
            }
            write(runs)
            // Sometimes the launch is a new build's first: nothing to adopt.
            let launchBuild = Int.random(in: 0..<3, using: &rng) == 0 ? build + 1 : build
            let launchClaim = TelemetryClaimKey(buildConfiguration: "release", appBuild: String(launchBuild),
                                                osVersion: "26.0", ownerUID: owner)
            let full = ResidentObservationCenter.referenceDailyRecord(
                in: SpikeRunLog.collapse(runs), within: todaysBounds(), claim: launchClaim,
                retention: SpikeRunStore.maxRunsPerSpike)
            let tail = SpikeRunFileScan.newestMatch(in: dailyURL, maxBytes: ResidentObservationCenter.seedTailBytes,
                                                    maxDecodes: ResidentObservationCenter.seedMaxDecodes) {
                self.todaysBounds().contains($0.startedAt) && TelemetryClaimKey(run: $0) == launchClaim
            }
            switch tail {
            case .found(let run, _):
                tally.agree += 1
                tally.found += 1
                XCTAssertEqual(run, full, "the tail adopted the full read's record, newest line and all")
            case .miss(let reason, _):
                if full == nil { tally.agree += 1 } else { tally.miss += 1 }
                if full != nil {
                    XCTAssertTrue([.cap, .window].contains(reason), "a miss the full read disagrees with is a bound's")
                }
            }
        }
        XCTAssertGreaterThan(tally.agree, 0, "liveness")
        XCTAssertGreaterThan(tally.found, 0, "liveness: some launches adopted")
    }

    // MARK: The verification read

    func testTheVerificationLogsOneAgreeLineAndWritesNothing() throws {
        write(olderDays(3) + [daily(hidden: 1)])
        let before = try Data(contentsOf: dailyURL)
        var triggers: [TelemetryTrigger] = []

        let center = makeCenter(verifies: true)
        center.onUploadTrigger = { triggers.append($0) }
        XCTAssertEqual(center.seedVerification, .pending)
        waitForVerification(center)

        guard case .logged(let report) = center.seedVerification else {
            return XCTFail("expected a logged report, got \(center.seedVerification)")
        }
        XCTAssertEqual(report.result, .agree)
        XCTAssertEqual(report.seed, "hit")
        XCTAssertEqual(report.idsToday, 1)
        XCTAssertEqual(report.fileBytes, before.count)
        XCTAssertEqual(trail, [report.trailLine])
        XCTAssertTrue(report.trailLine.hasPrefix("resident.seed.verify result=agree seed=hit decodes=1 "))
        XCTAssertEqual(try Data(contentsOf: dailyURL), before, "the read wrote nothing")
        XCTAssertEqual(triggers, [], "the read triggered nothing")
    }

    func testTheVerificationReportsAMissTheTailCouldNotSee() {
        write([daily(hidden: 3)] + (0..<ResidentObservationCenter.seedMaxDecodes).map { _ in daily(build: "9") })
        let center = makeCenter(verifies: true)
        waitForVerification(center)
        guard case .logged(let report) = center.seedVerification else {
            return XCTFail("expected a logged report, got \(center.seedVerification)")
        }
        XCTAssertEqual(report.result, .miss)
        XCTAssertEqual(report.seed, "cap")
        XCTAssertEqual(report.idsToday, 1 + ResidentObservationCenter.seedMaxDecodes)
    }

    /// Attack M1's lesson: a read that started before an erase reports
    /// nothing after it, whichever way the erase is seen.
    func testAVerificationReadFromBeforeTheCentersEraseIsDropped() {
        write([daily(hidden: 3)])
        let center = makeCenter(verifies: true)
        center.forgetAfterErase()     // before the read can come back to the main thread
        waitForVerification(center)
        XCTAssertEqual(center.seedVerification, .dropped(reason: "erase"))
        XCTAssertEqual(trail, ["resident.seed.verify result=dropped reason=erase"], "nothing from the read is reported")
    }

    func testAVerificationReadFromBeforeAnEraseEpochBumpIsDropped() {
        write([daily(hidden: 3)])
        LocalDataEraseEpoch.withIsolatedEpoch {
            let center = makeCenter(verifies: true)
            LocalDataEraseEpoch.bump()
            waitForVerification(center)
            XCTAssertEqual(center.seedVerification, .dropped(reason: "erase"))
        }
    }

    func testAVerificationReadForAnOwnerWhoLeftIsDropped() {
        write([daily(hidden: 3)])
        let center = makeCenter(verifies: true)
        owner.value = nil
        waitForVerification(center)
        XCTAssertEqual(center.seedVerification, .dropped(reason: "owner"))
    }

    func testTheVerificationIsOffUnderXCTestUnlessATestAsks() {
        XCTAssertEqual(makeCenter().seedVerification, .notRequested)
    }
}

/// A seeded generator, so a failing random history reproduces.
private struct SeededSeedRandom: RandomNumberGenerator {
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

// MARK: - Main-thread cost (report-only)

/// Times the old whole-file path against the new one at the sizes that
/// matter: the resident-daily file as pulled from the 18 Pro, the shared cap,
/// and a 1 MiB file. Report-only: it prints and never fails on a time.
@MainActor
final class SpikeRunReadCostMeasurement: XCTestCase {
    private var location: SpikeRunStorageLocation!

    override func setUp() {
        super.setUp()
        location = .ephemeral(id: UUID())
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: location.directory)
        location = nil
        super.tearDown()
    }

    /// A day line at its widest: every counter and follower key, wide values,
    /// the envelope filled in.
    static func wideDailyLine(id: UUID = UUID(), startedAt: Date, claimBuild: String = "99999") -> SpikeRun {
        var metrics: [String: SpikeMetricValue] = [:]
        for (key, value) in ResidentCounterSet().metrics {
            switch value {
            case .string: metrics[key] = .string(Array(repeating: "9999999", count: ResidentLagHistogram.bucketCount).joined(separator: " "))
            case .number, .bool: metrics[key] = .number(9_999_999)
            }
        }
        for follower in FollowerID.allCases {
            metrics[FollowerStatTable.dailyCountKey(follower)] = .number(9_999_999)
            metrics[FollowerStatTable.dailyTotalKey(follower)] = .number(86_399_999.99)
            metrics[FollowerStatTable.dailyMaxKey(follower)] = .number(99_999.99)
        }
        var run = SpikeRun(
            id: id, spikeID: FixObservationRegistry.residentDailySpikeID,
            scenarioID: FixObservationRegistry.residentDailyScenarioID, variantID: nil,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(86_399),
            appVersion: "0.5.0", appBuild: claimBuild, appCommit: nil,
            deviceModel: "iPhone18,2", osVersion: "27.0.1",
            timeZoneIdentifier: "America/Los_Angeles", localeIdentifier: "zh-Hans_CN", buildConfiguration: "release",
            metrics: metrics, note: nil, outcome: .completed, abortReason: nil
        )
        run.installID = UUID()
        run.ownerUID = UUID().uuidString.lowercased()
        run.dayKey = "2026-10-27"
        run.dayTZOffsetMin = -420
        run.revision = 40
        run.kind = .dailyRollup
        return run
    }

    /// Distinct-id wide lines until the next would pass `bytes`; returns the
    /// last line's id.
    @discardableResult
    static func fill(_ location: SpikeRunStorageLocation, spikeID: String, bytes: Int) -> UUID {
        var payload = Data()
        var last = UUID()
        var index = 0
        while true {
            last = UUID()
            let next = SpikeRunFixtureBytes.line(wideDailyLine(id: last, startedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 43_200)))
            if payload.count + next.count > bytes { break }
            payload += next
            index += 1
        }
        // The last line written is the one before the line that did not fit.
        let lastWritten = try! SpikeRunFixtureBytes.decoder().decode(
            SpikeRun.self, from: payload.split(separator: 0x0A).last.map { Data($0) } ?? Data())
        SpikeRunFixtureBytes.write(payload, spikeID: spikeID, location: location)
        return lastWritten.id
    }

    static func medianMs(_ runs: Int = 7, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        return samples.sorted()[samples.count / 2]
    }

    static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    func testMeasureTheRevisionLookup() {
        let spikeID = "measure-revision"
        let url = SpikeRunFixtureBytes.fileURL(spikeID: spikeID, location: location)
        var lines = ["revision lookup (\(Self.configuration)), median of 7"]
        for (label, bytes) in [("windows-size", 35_283), ("device resident-daily", 242_805),
                               ("shared cap", SpikeRunStore.compactAtBytes), ("1 MiB", 1 << 20)] {
            let last = Self.fill(location, spikeID: spikeID, bytes: bytes)
            var oldRevision = 0
            let old = Self.medianMs {
                oldRevision = SpikeRunStore.loadRuns(spikeID: spikeID, location: location, applyRetention: false)
                    .first { $0.id == last }?.revision ?? 0
            }
            var newRevision = 0
            let present = Self.medianMs {
                var decodes = 0
                if case .found(let run) = SpikeRunFileScan.latestLine(of: last, in: url, decodedLines: &decodes) {
                    newRevision = run.revision ?? 0
                }
            }
            let fresh = Self.medianMs {
                var decodes = 0
                _ = SpikeRunFileScan.latestLine(of: UUID(), in: url, decodedLines: &decodes)
            }
            XCTAssertEqual(newRevision, oldRevision, "liveness: both paths read the same line")
            lines.append(String(format: "%@ (%d B): full read %.2f ms | scan, id on the last line %.2f ms | scan, fresh id %.2f ms",
                                label, bytes, old, present, fresh))
        }
        print(lines.joined(separator: "\n"))
    }

    /// The launch seed: the old whole-file read and filter against the tail
    /// read, when today's record is the last line (the common launch) and
    /// when nothing in the tail matches (a new build's first launch, which
    /// spends the whole decode budget).
    func testMeasureTheLaunchSeed() throws {
        let spikeID = FixObservationRegistry.residentDailySpikeID
        let url = SpikeRunFixtureBytes.fileURL(spikeID: spikeID, location: location)
        var lines = ["launch seed (\(Self.configuration)), median of 7"]
        for (label, bytes) in [("device resident-daily", 242_805), ("shared cap", SpikeRunStore.compactAtBytes),
                               ("1 MiB", 1 << 20)] {
            let lastID = Self.fill(location, spikeID: spikeID, bytes: bytes)
            let last = try XCTUnwrap(SpikeRunStore.loadRuns(spikeID: spikeID, location: location).first { $0.id == lastID })
            let bounds = ResidentDayBounds.compute(for: last.startedAt, calendar: .current)
            let claim = TelemetryClaimKey(run: last)
            var oldID: UUID?
            let old = Self.medianMs {
                oldID = SpikeRunStore.loadRuns(spikeID: spikeID, location: location)
                    .filter { bounds.contains($0.startedAt) && TelemetryClaimKey(run: $0) == claim }
                    .max { $0.startedAt < $1.startedAt }?.id
            }
            var tail: SpikeRunFileScan.TailRecord?
            let hit = Self.medianMs {
                tail = SpikeRunFileScan.newestMatch(in: url, maxBytes: ResidentObservationCenter.seedTailBytes,
                                                    maxDecodes: ResidentObservationCenter.seedMaxDecodes) {
                    bounds.contains($0.startedAt) && TelemetryClaimKey(run: $0) == claim
                }
            }
            var missed: SpikeRunFileScan.TailRecord?
            let miss = Self.medianMs {
                missed = SpikeRunFileScan.newestMatch(in: url, maxBytes: ResidentObservationCenter.seedTailBytes,
                                                      maxDecodes: ResidentObservationCenter.seedMaxDecodes) { _ in false }
            }
            XCTAssertEqual(oldID, lastID, "liveness: the old read found the last line")
            guard case .found(let found, 1)? = tail else { return XCTFail("the tail found the last line in one decode") }
            XCTAssertEqual(found.id, lastID)
            guard case .miss(_, let spent)? = missed else { return XCTFail("nothing matches") }
            lines.append(String(format: "%@ (%d B): full read + filter %.2f ms | tail, last line %.2f ms | tail, no match (%d decodes) %.2f ms",
                                label, bytes, old, hit, spent, miss))
        }
        print(lines.joined(separator: "\n"))
    }
}
