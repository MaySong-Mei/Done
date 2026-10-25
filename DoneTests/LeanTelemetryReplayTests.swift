//
//  LeanTelemetryReplayTests.swift
//  DoneTests
//
//  DRAFT — NOT YET REGISTERED IN project.pbxproj, NOT YET COMPILED.
//
//  Depends on `Done/Models/TelemetryModel.swift` (gh#273 client skeleton),
//  which is being written in another worktree. Once it lands, the
//  coordinator registers this file in the DoneTests target (explicit file
//  refs — see memory: a .swift not in project.pbxproj silently does not
//  compile) and reconciles the five adapter points marked `ADAPT:` below
//  against the real API surface. Nothing else in the file should need to
//  move: every assertion is against a value the Lean model computed.
//
//  Replays `verification/telemetry-fixtures.json` (regenerate with
//  `cd verification && lake exe telemetryfixturegen`) against the pure
//  telemetry semantics. Every `expected` is the output of the Lean
//  definitions in `verification/Telemetry/Basic.lean` — the ones the
//  theorems in `Telemetry/Theorems.lean` are proved about — never
//  hand-written. The field contract and the seven model decisions the
//  spec left open (what `nil == nil` means for consent, the 15-minute
//  `≥`, revision 0, …) are in `verification/README.md` (Telemetry section);
//  a fixture that fails here is EITHER an implementation bug OR one of
//  those decisions going the other way — read the label before fixing.
//

import XCTest
@testable import Done

final class LeanTelemetryReplayTests: XCTestCase {

    // MARK: - Fixture schema (mirrors Telemetry/Fixtures.lean's emitters)

    private struct FixtureRecord: Decodable {
        let id: String
        let revision: Int
        let kind: String
        let startedAt: Int
        let ownerUID: String?
    }

    private struct Ack: Decodable {
        let id: String
        let revision: Int
    }

    private struct PendingExpected: Decodable {
        let id: String
        let revision: Int
    }

    private struct ClaimKeyJSON: Decodable {
        let buildConfiguration: String
        let appBuild: String
        let osVersion: String
        let ownerUID: String?
    }

    /// One row. `input` and `expected` are op-specific; every optional field
    /// below belongs to one or two ops and is nil elsewhere.
    private struct Fixture: Decodable {
        struct Input: Decodable {
            let cursor: [String: Int]?
            let acks: [Ack]?
            let records: [FixtureRecord]?
            let existing: Int?
            let incoming: Int?
            let deliveries: [Int]?
            let consentAt: Int?
            let currentOwner: String?
            let today: ClaimKeyJSON?
            let incomingKey: ClaimKeyJSON?
            let trigger: String?
            let lastDailyUploadAt: Int?
            let now: Int?
            let limit: Int?
            let pending: [FixtureRecord]?

            // `incoming` is an Int for server.apply and a key for claim.adopts;
            // decode it by hand so one struct serves both.
            private enum Keys: String, CodingKey {
                case cursor, acks, records, existing, incoming, deliveries, consentAt
                case currentOwner, today, trigger, lastDailyUploadAt, now, limit, pending
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                cursor = try c.decodeIfPresent([String: Int].self, forKey: .cursor)
                acks = try c.decodeIfPresent([Ack].self, forKey: .acks)
                records = try c.decodeIfPresent([FixtureRecord].self, forKey: .records)
                // `existing: null` must stay distinguishable from absent — both
                // decode to nil here, and `server.*` ops always carry the key.
                existing = try c.decodeIfPresent(Int.self, forKey: .existing)
                incoming = try? c.decodeIfPresent(Int.self, forKey: .incoming)
                incomingKey = try? c.decodeIfPresent(ClaimKeyJSON.self, forKey: .incoming)
                deliveries = try c.decodeIfPresent([Int].self, forKey: .deliveries)
                consentAt = try c.decodeIfPresent(Int.self, forKey: .consentAt)
                currentOwner = try c.decodeIfPresent(String.self, forKey: .currentOwner)
                today = try c.decodeIfPresent(ClaimKeyJSON.self, forKey: .today)
                trigger = try c.decodeIfPresent(String.self, forKey: .trigger)
                lastDailyUploadAt = try c.decodeIfPresent(Int.self, forKey: .lastDailyUploadAt)
                now = try c.decodeIfPresent(Int.self, forKey: .now)
                limit = try c.decodeIfPresent(Int.self, forKey: .limit)
                pending = try c.decodeIfPresent([FixtureRecord].self, forKey: .pending)
            }
        }

        struct Expected: Decodable {
            let cursor: [String: Int]?
            let records: [PendingExpected]?
            let accepted: Bool?
            let state: Int?
            let ids: [String]?
            let adopts: Bool?
        }

        let op: String
        let label: String
        let input: Input
        let expected: Expected
    }

    private static func loadFixtures() throws -> [Fixture] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("verification/telemetry-fixtures.json")
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }

    // MARK: - Adapters: fixture JSON → TelemetryModel.swift values

    private func uuid(_ s: String, _ label: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: s), "\(label): bad UUID literal \(s)")
    }

    private func date(_ unixSeconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    }

    private func kind(_ name: String, _ label: String) throws -> TelemetryRecordKind {
        // ADAPT (1): case names, not wire rawValues (`daily_rollup`).
        switch name {
        case "dailyRollup": return .dailyRollup
        case "window": return .window
        case "manualRun": return .manualRun
        case "verdictSnapshot": return .verdictSnapshot
        case "metricKitDaily": return .metricKitDaily
        default:
            XCTFail("\(label): unknown kind \(name)")
            throw XCTSkip("unknown kind")
        }
    }

    private func trigger(_ name: String, _ label: String) throws -> TelemetryTrigger {
        switch name {
        case "launch": return .launch
        case "dayRollover": return .dayRollover
        case "deckOpen": return .deckOpen
        case "backgroundEdge": return .backgroundEdge
        default:
            XCTFail("\(label): unknown trigger \(name)")
            throw XCTSkip("unknown trigger")
        }
    }

    /// ADAPT (2): the record type `pending` / `consentFilter` / `selectBatch`
    /// take. The model reads five fields; if the real API takes `SpikeRun`,
    /// build one here with placeholder spike/scenario/device fields and set
    /// exactly these five from the fixture (`id`, `revision`, `kind`,
    /// `startedAt`, `ownerUID`). Nothing else in the fixture is semantic.
    private func record(_ r: FixtureRecord, _ label: String) throws -> TelemetryRecord {
        TelemetryRecord(
            id: try uuid(r.id, label),
            revision: r.revision,
            kind: try kind(r.kind, label),
            startedAt: date(r.startedAt),
            ownerUID: r.ownerUID
        )
    }

    private func cursor(_ dict: [String: Int], _ label: String) throws -> UploadCursor {
        var uploaded: [UUID: Int] = [:]
        for (k, v) in dict { uploaded[try uuid(k, label)] = v }
        // ADAPT (3): `UploadCursor` memberwise init on `uploaded`.
        return UploadCursor(uploaded: uploaded)
    }

    private func claimKey(_ k: ClaimKeyJSON) -> TelemetryClaimKey {
        TelemetryClaimKey(
            buildConfiguration: k.buildConfiguration,
            appBuild: k.appBuild,
            osVersion: k.osVersion,
            ownerUID: k.ownerUID
        )
    }

    private func requireField<T>(_ value: T?, _ name: String, _ label: String) throws -> T {
        try XCTUnwrap(value, "\(label): fixture missing \(name)")
    }

    // MARK: - Dispatch

    private func replay(_ f: Fixture) throws {
        let label = "[\(f.op)] \(f.label)"
        switch f.op {

        case "cursor.acknowledge":
            var c = try cursor(try requireField(f.input.cursor, "cursor", label), label)
            let acks = try requireField(f.input.acks, "acks", label)
                .map { (try uuid($0.id, label), $0.revision) }
            // ADAPT (4): `acknowledge(ids:)` takes `[(UUID, Int)]`.
            c.acknowledge(ids: acks)
            let expected = try requireField(f.expected.cursor, "cursor", label)
            // Both sides read through `?? 0`: a key the implementation left
            // absent is 0, and a key it holds that the model did not name
            // must also read as the model's 0.
            for (k, v) in expected {
                XCTAssertEqual(c.uploaded[try uuid(k, label)] ?? 0, v, "\(label): \(k)")
            }
            for (k, v) in c.uploaded {
                XCTAssertEqual(v, expected[k.uuidString.lowercased()] ?? 0,
                               "\(label): implementation holds an id the model did not expect: \(k)")
            }

        case "cursor.pending":
            let c = try cursor(try requireField(f.input.cursor, "cursor", label), label)
            let records = try requireField(f.input.records, "records", label).map { try record($0, label) }
            let actual = c.pending(records).map { ($0.id.uuidString.lowercased(), $0.revision) }
            let expected = try requireField(f.expected.records, "records", label)
                .map { ($0.id, $0.revision) }
            // Compared as multisets: the model keeps input order (a filter)
            // but the spec does not promise one. README decision 7.
            XCTAssertEqual(actual.sorted { $0 < $1 }, expected.sorted { $0 < $1 }, label)

        case "server.apply":
            let incoming = try requireField(f.input.incoming, "incoming", label)
            let accepted = TelemetryServerModel.apply(existing: f.input.existing, incoming: incoming)
            XCTAssertEqual(accepted, try requireField(f.expected.accepted, "accepted", label), label)
            let state = accepted ? incoming : f.input.existing
            XCTAssertEqual(state, f.expected.state, "\(label) [state]")

        case "server.fold":
            // The fold is the Swift `apply` driven in arrival order — the
            // seam exercises `apply`'s guard, the loop is the test's.
            var state = f.input.existing
            for incoming in try requireField(f.input.deliveries, "deliveries", label) {
                if TelemetryServerModel.apply(existing: state, incoming: incoming) {
                    state = incoming
                }
            }
            XCTAssertEqual(state, f.expected.state, label)

        case "consent.filter":
            let records = try requireField(f.input.records, "records", label).map { try record($0, label) }
            let kept = consentFilter(
                records,
                consentAt: f.input.consentAt.map(date),
                currentOwner: f.input.currentOwner
            )
            let actual = kept.map { $0.id.uuidString.lowercased() }
            let expected = try requireField(f.expected.ids, "ids", label)
            XCTAssertEqual(actual.sorted(), expected.sorted(), label)

        case "claim.adopts":
            let today = claimKey(try requireField(f.input.today, "today", label))
            let incoming = claimKey(try requireField(f.input.incomingKey, "incoming", label))
            // ADAPT (5): "adopts" is `==` on the key per §4.2; if the real API
            // names the predicate, call it here instead of `==`.
            XCTAssertEqual(today == incoming, try requireField(f.expected.adopts, "adopts", label), label)

        case "batch.select":
            let pending = try requireField(f.input.pending, "pending", label).map { try record($0, label) }
            let chosen = selectBatch(
                pending,
                trigger: try trigger(try requireField(f.input.trigger, "trigger", label), label),
                lastDailyUploadAt: f.input.lastDailyUploadAt.map(date),
                now: date(try requireField(f.input.now, "now", label)),
                limit: try requireField(f.input.limit, "limit", label)
            )
            // IN ORDER: the sort is part of the contract (events first, then
            // dailies, `startedAt` ascending, ties in input order).
            XCTAssertEqual(chosen.map { $0.id.uuidString.lowercased() },
                           try requireField(f.expected.ids, "ids", label), label)

        default:
            XCTFail("unknown fixture op \(f.op)")
        }
    }

    // MARK: - The replay

    func testFixturesReplayAgainstTelemetryModel() throws {
        let fixtures = try Self.loadFixtures()
        XCTAssertGreaterThanOrEqual(fixtures.count, 58, "telemetry-fixtures.json truncated?")
        let ops = Set(fixtures.map(\.op))
        XCTAssertEqual(ops, ["cursor.acknowledge", "cursor.pending", "server.apply", "server.fold",
                             "consent.filter", "claim.adopts", "batch.select"],
                       "an op family vanished from the fixture file")
        for f in fixtures {
            try replay(f)
        }
    }

    // MARK: - Theorem shadows (the Swift side of the Lean laws, on fixture data)

    /// `acknowledge_perm`'s shadow: for every acknowledge fixture, the reversed
    /// batch lands the same cursor as the fixture's order.
    func testAcknowledgeIsOrderFreeOnAllFixtures() throws {
        for f in try Self.loadFixtures() where f.op == "cursor.acknowledge" {
            let label = "[perm] \(f.label)"
            let acks = try requireField(f.input.acks, "acks", label)
                .map { (try uuid($0.id, label), $0.revision) }
            var forward = try cursor(try requireField(f.input.cursor, "cursor", label), label)
            var backward = forward
            forward.acknowledge(ids: acks)
            backward.acknowledge(ids: acks.reversed())
            XCTAssertEqual(forward.uploaded, backward.uploaded, label)
        }
    }

    /// `acknowledge_idem` + `not_pending_after_acknowledge`'s shadow: after
    /// acknowledging every pending record at its own revision, nothing is
    /// pending, and acknowledging again changes nothing.
    func testAcknowledgingPendingDrainsIt() throws {
        for f in try Self.loadFixtures() where f.op == "cursor.pending" {
            let label = "[drain] \(f.label)"
            var c = try cursor(try requireField(f.input.cursor, "cursor", label), label)
            let records = try requireField(f.input.records, "records", label).map { try record($0, label) }
            let batch = c.pending(records).map { ($0.id, $0.revision) }
            c.acknowledge(ids: batch)
            XCTAssertTrue(c.pending(records).isEmpty, "\(label): still pending after a full acknowledge")
            let once = c.uploaded
            c.acknowledge(ids: batch)
            XCTAssertEqual(c.uploaded, once, "\(label): a second acknowledge moved the cursor")
        }
    }

    /// `fold_perm` + `fold_idem`'s shadow: every fold fixture's deliveries,
    /// reversed and then replayed twice, land the fixture's state.
    func testServerFoldIsOrderFreeAndIdempotent() throws {
        for f in try Self.loadFixtures() where f.op == "server.fold" {
            let label = "[fold] \(f.label)"
            let deliveries = try requireField(f.input.deliveries, "deliveries", label)
            func fold(_ start: Int?, _ seq: [Int]) -> Int? {
                var s = start
                for r in seq where TelemetryServerModel.apply(existing: s, incoming: r) { s = r }
                return s
            }
            let reversed = fold(f.input.existing, deliveries.reversed())
            XCTAssertEqual(reversed, f.expected.state, "\(label): reversed arrival order")
            XCTAssertEqual(fold(reversed, deliveries), f.expected.state, "\(label): redelivered after itself")
        }
    }

    /// `selectBatch_idem`'s shadow: selecting from a selection is the selection.
    func testSelectBatchIsIdempotentOnAllFixtures() throws {
        for f in try Self.loadFixtures() where f.op == "batch.select" {
            let label = "[idem] \(f.label)"
            let pending = try requireField(f.input.pending, "pending", label).map { try record($0, label) }
            let trig = try trigger(try requireField(f.input.trigger, "trigger", label), label)
            let last = f.input.lastDailyUploadAt.map(date)
            let now = date(try requireField(f.input.now, "now", label))
            let limit = try requireField(f.input.limit, "limit", label)
            let once = selectBatch(pending, trigger: trig, lastDailyUploadAt: last, now: now, limit: limit)
            let twice = selectBatch(once, trigger: trig, lastDailyUploadAt: last, now: now, limit: limit)
            XCTAssertEqual(twice.map(\.id), once.map(\.id), label)
        }
    }
}
