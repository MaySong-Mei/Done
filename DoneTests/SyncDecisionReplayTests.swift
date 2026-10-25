//
//  SyncDecisionReplayTests.swift
//  DoneTests
//
//  verification/sync-fixtures.json replayed through `SyncDecision.decide`.
//  Every `expected` in that file is the Lean `decideRow`'s output, never
//  hand-written; the contract is verification/README.md (Sync section).
//  Hashes are opaque tokens: compared for equality only.
//
//  The second half holds what the fixtures do not carry: the in-flight
//  echo (an input the Lean table lacks), the legacy seq-less entry and the
//  `?` marker.
//

import XCTest
@testable import Done

@MainActor
final class SyncDecisionReplayTests: XCTestCase {

    private struct Expected: Decodable {
        let action: String
        let base_hash: String?
        let base_seq: Int64?
        let shelf_remote: Bool
        let shelf_local: Bool
    }

    private struct Fixture: Decodable {
        let label: String
        let tombstone: Bool
        let h_in: String
        let h_loc: String?
        let h_base: String?
        let base_seq: Int64?
        let in_seq: Int64
        let expected: Expected
    }

    private static func loadFixtures() throws -> [Fixture] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("verification/sync-fixtures.json")
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }

    private func decide(_ f: Fixture, inFlight: String? = nil) -> SyncDecision {
        SyncDecision.decide(
            tombstone: f.tombstone,
            incomingHash: f.h_in,
            localHash: f.h_loc,
            base: f.h_base.map { SyncBaselineEntry(hash: $0, seq: f.base_seq) },
            incomingSeq: f.in_seq,
            inFlightSentHash: inFlight
        )
    }

    // MARK: - The replay

    func testEveryFixtureCaseReplays() throws {
        let fixtures = try Self.loadFixtures()
        XCTAssertGreaterThanOrEqual(fixtures.count, 672, "sync-fixtures.json truncated?")

        var seenActions: Set<String> = []
        for f in fixtures {
            let d = decide(f)
            let before = f.h_base.map { SyncBaselineEntry(hash: $0, seq: f.base_seq) }
            let after = d.baseAfter(before)
            XCTAssertEqual(d.action.rawValue, f.expected.action, f.label)
            XCTAssertEqual(after?.hash, f.expected.base_hash, "\(f.label) [base_hash]")
            XCTAssertEqual(after?.seq, f.expected.base_seq, "\(f.label) [base_seq]")
            XCTAssertEqual(d.shelfRemote, f.expected.shelf_remote, "\(f.label) [shelf_remote]")
            XCTAssertEqual(d.shelfLocal, f.expected.shelf_local, "\(f.label) [shelf_local]")
            seenActions.insert(f.expected.action)
        }
        // Liveness: every row of the table is exercised by the file.
        XCTAssertEqual(seenActions, ["skip", "tombstone", "echo", "same", "adopt", "conflict"])
    }

    /// The README's structural checks, asserted on the fixture file itself
    /// before anything is compared case by case: a regenerated file that
    /// broke the table's shape fails here with its own message.
    func testTheFixtureFileHasTheTablesStructure() throws {
        for f in try Self.loadFixtures() {
            let e = f.expected
            XCTAssertEqual(e.base_hash == nil, e.base_seq == nil, f.label)
            XCTAssertEqual(f.h_base == nil, f.base_seq == nil, f.label)
            XCTAssertFalse(e.shelf_remote && e.shelf_local, f.label)
            if e.action == "skip" {
                XCTAssertNotNil(f.h_base, "\(f.label): skip never fires without a baseline")
                XCTAssertEqual(e.base_hash, f.h_base, f.label)
                XCTAssertEqual(e.base_seq, f.base_seq, f.label)
            } else if e.action == "tombstone" {
                XCTAssertNil(e.base_hash, f.label)
            } else {
                XCTAssertEqual(e.base_hash, f.h_in, f.label)
                XCTAssertEqual(e.base_seq, f.in_seq, f.label)
            }
            XCTAssertEqual(e.shelf_remote, e.action == "conflict", f.label)
            XCTAssertEqual(e.shelf_local,
                           e.action == "tombstone" && f.h_loc != nil && f.h_loc != f.h_base,
                           f.label)
        }
    }

    /// Hashes are opaque: renaming the tokens consistently changes nothing.
    func testTokensAreOpaque() throws {
        let rename = ["A": "9f3a1c00deadbeef", "B": "0000000000000001", "C": "?x"]
        for f in try Self.loadFixtures() {
            let renamed = SyncDecision.decide(
                tombstone: f.tombstone,
                incomingHash: rename[f.h_in]!,
                localHash: f.h_loc.map { rename[$0]! },
                base: f.h_base.map { SyncBaselineEntry(hash: rename[$0]!, seq: f.base_seq) },
                incomingSeq: f.in_seq
            )
            let original = decide(f)
            XCTAssertEqual(renamed.action, original.action, f.label)
            XCTAssertEqual(renamed.shelfRemote, original.shelfRemote, f.label)
            XCTAssertEqual(renamed.shelfLocal, original.shelfLocal, f.label)
            XCTAssertEqual(renamed.baseAfter(nil)?.hash, (original.baseAfter(nil)?.hash).flatMap { rename[$0] }, f.label)
        }
    }

    func testLocalEffectIsAFunctionOfTheAction() {
        func effect(_ action: SyncDecisionAction) -> SyncLocalEffect {
            SyncDecision(action: action, baseline: .keep, shelfRemote: false, shelfLocal: false).localEffect
        }
        XCTAssertEqual(effect(.tombstone), .remove)
        XCTAssertEqual(effect(.adopt), .replaceWithIncoming)
        for action in [SyncDecisionAction.skip, .echo, .same, .conflict] {
            XCTAssertEqual(effect(action), .keep, "\(action)")
        }
    }

    // MARK: - The in-flight echo (not in the fixtures)

    /// The race the guard exists for: our PATCH sent c1 (hash h1) on base
    /// h0 and the user edited to c3 before the echo arrived. Without
    /// the guard the echo of our own write is a conflict and our own c1
    /// lands on the shelf; with it the echo is an echo and c3 stays dirty.
    func testInFlightSentHashTurnsOurOwnWriteIntoAnEcho() {
        let base = SyncBaselineEntry(hash: "h0", seq: 5)
        let plain = SyncDecision.decide(tombstone: false, incomingHash: "h1", localHash: "h3",
                                        base: base, incomingSeq: 6)
        XCTAssertEqual(plain.action, .conflict, "control: the table alone shelves our own write")
        XCTAssertTrue(plain.shelfRemote)

        let guarded = SyncDecision.decide(tombstone: false, incomingHash: "h1", localHash: "h3",
                                          base: base, incomingSeq: 6, inFlightSentHash: "h1")
        XCTAssertEqual(guarded.action, .echo)
        XCTAssertFalse(guarded.shelfRemote)
        XCTAssertFalse(guarded.shelfLocal)
        XCTAssertEqual(guarded.localEffect, .keep, "c3 stays local and dirty against (h1, 6)")
        XCTAssertEqual(guarded.baseline, .write(SyncBaselineEntry(hash: "h1", seq: 6)))
    }

    /// The revert race: the user changed back to c0 (= base hash) after
    /// the send. The table adopts our own c1 over c0; the guard keeps c0.
    func testInFlightEchoKeepsALocalRevertInsteadOfAdoptingOurOwnWrite() {
        let base = SyncBaselineEntry(hash: "h0", seq: 5)
        let plain = SyncDecision.decide(tombstone: false, incomingHash: "h1", localHash: "h0",
                                        base: base, incomingSeq: 6)
        XCTAssertEqual(plain.action, .adopt, "control")
        let guarded = SyncDecision.decide(tombstone: false, incomingHash: "h1", localHash: "h0",
                                          base: base, incomingSeq: 6, inFlightSentHash: "h1")
        XCTAssertEqual(guarded.action, .echo)
        XCTAssertEqual(guarded.localEffect, .keep)
    }

    /// Under the S4 marker (the entry became `?@sentSeq` at send time) the
    /// guard is what keeps the echo off the shelf.
    func testInFlightEchoUnderTheUnknownMarker() {
        let marker = SyncBaselineEntry.unknown(seq: 5)
        let plain = SyncDecision.decide(tombstone: false, incomingHash: "h1", localHash: "h3",
                                        base: marker, incomingSeq: 6)
        XCTAssertEqual(plain.action, .conflict, "control")
        let guarded = SyncDecision.decide(tombstone: false, incomingHash: "h1", localHash: "h3",
                                          base: marker, incomingSeq: 6, inFlightSentHash: "h1")
        XCTAssertEqual(guarded.action, .echo)
        XCTAssertFalse(guarded.shelfRemote)
    }

    /// The guard never touches the skip row, the tombstone row, or a row
    /// whose bytes are not the ones sent — and writes exactly the table's
    /// baseline wherever it fires (Lean `decideRowInflight_base`).
    func testInFlightGuardIsConsultedOnlyAfterSkipAndTombstoneAndWritesTheTablesBaseline() throws {
        for f in try Self.loadFixtures() {
            let plain = decide(f)
            let matching = decide(f, inFlight: f.h_in)
            let other = decide(f, inFlight: f.h_in == "A" ? "B" : "A")

            XCTAssertEqual(other, plain, "\(f.label): a different sent hash changes nothing")
            XCTAssertEqual(matching.baseline, plain.baseline, "\(f.label): same baseline as the table")
            if plain.action == .skip || plain.action == .tombstone {
                XCTAssertEqual(matching, plain, "\(f.label): skip and tombstone precede the guard")
            } else {
                XCTAssertEqual(matching.action, .echo, f.label)
                XCTAssertFalse(matching.shelfRemote, f.label)
                XCTAssertFalse(matching.shelfLocal, f.label)
            }
        }
    }

    // MARK: - Baseline shapes the fixtures do not carry

    /// A legacy `<hash>` entry has no seq, so the skip row cannot fire —
    /// whatever the incoming seq. The rest of the table still sees the hash.
    func testLegacyEntryWithoutSeqNeverSkips() {
        let legacy = SyncBaselineEntry(encoded: "h0")
        XCTAssertNil(legacy?.seq, "fixture liveness: the legacy shape decodes seq-less")
        for seq: Int64 in [0, 1, 5] {
            let echo = SyncDecision.decide(tombstone: false, incomingHash: "h0", localHash: "h1",
                                           base: legacy, incomingSeq: seq)
            XCTAssertEqual(echo.action, .echo, "seq \(seq)")
            XCTAssertEqual(echo.baseline, .write(SyncBaselineEntry(hash: "h0", seq: seq)))

            let adopt = SyncDecision.decide(tombstone: false, incomingHash: "h2", localHash: "h0",
                                            base: legacy, incomingSeq: seq)
            XCTAssertEqual(adopt.action, .adopt, "seq \(seq): clean local against the legacy hash")

            let conflict = SyncDecision.decide(tombstone: false, incomingHash: "h2", localHash: "h1",
                                               base: legacy, incomingSeq: seq)
            XCTAssertEqual(conflict.action, .conflict)
            XCTAssertEqual(conflict.baseline, .write(SyncBaselineEntry(hash: "h2", seq: seq)),
                           "round nine: (h_in, seq) also over a legacy entry")
        }
        // Control: the same entry WITH a seq skips at that seq.
        XCTAssertEqual(SyncDecision.decide(tombstone: false, incomingHash: "h2", localHash: "h1",
                                           base: SyncBaselineEntry(hash: "h0", seq: 5), incomingSeq: 5).action,
                       .skip)
    }

    /// `?` equals no hash: never an echo, always dirty, settled without a
    /// shelf line only by `h_in == h_loc`.
    func testUnknownMarkerEqualsNoHashAndReadsDirty() {
        for marker in [SyncBaselineEntry.unknown(seq: 5), SyncBaselineEntry.unknown(seq: nil)] {
            // Not an echo even when h_in is literally the marker's text.
            let literal = SyncDecision.decide(tombstone: false, incomingHash: SyncBaselineEntry.unknownHash,
                                              localHash: "h1", base: marker, incomingSeq: 6)
            XCTAssertNotEqual(literal.action, .echo)

            let same = SyncDecision.decide(tombstone: false, incomingHash: "h1", localHash: "h1",
                                           base: marker, incomingSeq: 6)
            XCTAssertEqual(same.action, .same)
            XCTAssertEqual(same.baseline, .write(SyncBaselineEntry(hash: "h1", seq: 6)))

            let differs = SyncDecision.decide(tombstone: false, incomingHash: "h2", localHash: "h1",
                                              base: marker, incomingSeq: 6)
            XCTAssertEqual(differs.action, .conflict, "dirty against `?`: local kept, incoming shelved")
            XCTAssertTrue(differs.shelfRemote)

            let tomb = SyncDecision.decide(tombstone: true, incomingHash: "h2", localHash: "h1",
                                           base: marker, incomingSeq: 6)
            XCTAssertEqual(tomb.action, .tombstone)
            XCTAssertTrue(tomb.shelfLocal, "a local row under `?` is dirty: shelved before the cascade")
            XCTAssertEqual(tomb.baseline, .remove)

            let pendingDelete = SyncDecision.decide(tombstone: false, incomingHash: "h2", localHash: nil,
                                                    base: marker, incomingSeq: 6)
            XCTAssertEqual(pendingDelete.action, .conflict, "absent local with an entry: delete beats edit")
            XCTAssertEqual(pendingDelete.localEffect, .keep)
        }
        // `?@seq` keeps its seq: the skip row still fires at or below it, and
        // `?` without a seq never skips.
        XCTAssertEqual(SyncDecision.decide(tombstone: false, incomingHash: "h2", localHash: "h1",
                                           base: .unknown(seq: 5), incomingSeq: 5).action, .skip)
        XCTAssertNotEqual(SyncDecision.decide(tombstone: false, incomingHash: "h2", localHash: "h1",
                                              base: .unknown(seq: nil), incomingSeq: 0).action, .skip)
    }
}
