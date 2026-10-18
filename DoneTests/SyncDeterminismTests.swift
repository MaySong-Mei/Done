//
//  SyncDeterminismTests.swift
//  DoneTests
//
//  Survey M6(4)'s positive control for the simulation harness: the same
//  seed run twice gives byte-identical request logs. Two virtual devices,
//  each with its own UserDefaults suite and manual clock, write to one fake
//  server through seeded creates, edits, deletes and settings changes, with
//  seeded lost answers. Every byte a request carries comes from the seed or
//  from the injected clock — including the `updated_at` / `synced_at`
//  stamps and the tombstone's `deleted_at`, which the server stores as sent.
//

import CryptoKit
import XCTest
@testable import Done

@MainActor
final class SyncDeterminismTests: XCTestCase {

    private let uid = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    private let unionKey = "skillAnalyzedEventIds"
    private let epoch = Date(timeIntervalSince1970: 1_780_000_000)
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    /// SplitMix64: a fixed, portable generator, so a seed means the same
    /// run on every machine and in every process.
    fileprivate struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private struct Device {
        let service: SupabaseSyncService
        let clock: SyncManualScheduler
        let defaults: UserDefaults
        var events: [Event] = []
    }

    private struct Run {
        let log: [String]
        let lostAnswers: Int
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// One request as a line: verb, table, keys, base seq and the body as
    /// sorted-key JSON (a tombstone's body is its `deleted_at`).
    private static func line(_ r: SyncFakeServer.Request) -> String {
        let body: String
        switch r.body {
        case let date as Date:
            body = iso.string(from: date)
        case let object? where JSONSerialization.isValidJSONObject(object):
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            body = String(decoding: data, as: UTF8.self)
        case let other?:
            body = String(describing: other)
        case nil:
            body = "-"
        }
        return "\(r.verb.rawValue) \(r.table) keys=\(r.keys.joined(separator: ",")) base=\(r.baseSeq.map(String.init) ?? "-") body=\(body)"
    }

    private func makeDevice(_ index: Int, seed: UInt64, server: SyncFakeServer) -> Device {
        let name = "SyncDeterminismTests-\(seed)-\(index)-\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let clock = SyncManualScheduler(start: epoch.addingTimeInterval(Double(index)))
        let service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults, scheduler: clock)
        return Device(service: service, clock: clock, defaults: defaults)
    }

    private func run(seed: UInt64, steps: Int) async -> Run {
        let server = SyncFakeServer(userId: uid)
        var devices = [makeDevice(0, seed: seed, server: server), makeDevice(1, seed: seed, server: server)]
        var rng = SeededGenerator(state: seed)
        var minted = 0
        var lost = 0

        for step in 0..<steps {
            let d = rng.below(devices.count)
            devices[d].clock.advance(by: Double(1 + rng.below(30)))
            let loseAnswer = rng.below(6) == 0
            if loseAnswer { lost += 1 }
            server.dropResponseWhen = loseAnswer ? { _, _ in URLError(.networkConnectionLost) } : nil

            switch rng.below(5) {
            case 0, 1:
                minted += 1
                let id = UUID(uuidString: String(format: "%08X-0000-4000-8000-%012X", d, minted))!
                let start = epoch.addingTimeInterval(Double(rng.below(96)) * 900)
                devices[d].events.append(Event(id: id, title: "e\(minted)", note: "n0",
                                               timeRanges: [.init(start: start, end: start.addingTimeInterval(1800))],
                                               createdAt: epoch))
                await devices[d].service.syncEvents(devices[d].events, kind: "calendar")
            case 2 where !devices[d].events.isEmpty:
                let i = rng.below(devices[d].events.count)
                devices[d].events[i].note = "n\(step)"
                await devices[d].service.syncEvents(devices[d].events, kind: "calendar")
            case 3 where !devices[d].events.isEmpty:
                devices[d].events.remove(at: rng.below(devices[d].events.count))
                await devices[d].service.syncEvents(devices[d].events, kind: "calendar")
            case 4:
                // The union key in a seeded order: canonical form sends it sorted.
                var ids = (0...rng.below(3)).map { "s\(d)-\(step)-\($0)" }
                ids.shuffle(using: &rng)
                devices[d].defaults.set(ids, forKey: unionKey)
                devices[d].defaults.set(rng.below(2) == 0, forKey: AppSettingsKeys.showTimerBanner)
                await devices[d].service.syncSettings()
            default:
                await devices[d].service.syncEvents(devices[d].events, kind: "calendar")
            }
            server.dropResponseWhen = nil
        }
        return Run(log: server.requests.map(Self.line), lostAnswers: lost)
    }

    private static func digest(_ log: [String]) -> String {
        SHA256.hash(data: Data(log.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testTheSameSeedTwiceGivesByteIdenticalRequestLogs_killsWallClockInARequest() async throws {
        let seed: UInt64 = 0x5EED_0257
        let first = await run(seed: seed, steps: 80)
        let second = await run(seed: seed, steps: 80)

        // The run is not trivial: every kind of write went out, unmasked
        // stamps included, and some answers were lost.
        let joined = first.log.joined(separator: "\n")
        for verb in ["insert", "patch", "tombstone"] {
            XCTAssertTrue(first.log.contains { $0.hasPrefix("\(verb) events ") }, "no \(verb) in the run")
        }
        XCTAssertTrue(first.log.contains { $0.contains(" user_settings ") }, "no settings write in the run")
        XCTAssertTrue(joined.contains("\"synced_at\":\"2026-"), "stamps are in the compared bytes, not masked")
        XCTAssertGreaterThan(first.lostAnswers, 0)

        XCTAssertEqual(first.log.count, second.log.count)
        for (index, (a, b)) in zip(first.log, second.log).enumerated() where a != b {
            XCTFail("request \(index) differs:\n\(a)\n\(b)")
            break
        }
        XCTAssertEqual(Self.digest(first.log), Self.digest(second.log))
        // Printed so two separate test processes can be compared too.
        print("SYNC-DETERMINISM seed=\(seed) requests=\(first.log.count) sha256=\(Self.digest(first.log))")
    }

    /// Positive control: the comparison resolves a different run.
    func testADifferentSeedGivesADifferentLog() async {
        let a = await run(seed: 1, steps: 30)
        let b = await run(seed: 2, steps: 30)
        XCTAssertNotEqual(Self.digest(a.log), Self.digest(b.log))
    }

    /// The direct pin under the log comparison: the row stamps and the
    /// tombstone time are the injected clock's, not the wall clock's.
    func testRowStampsAndTheTombstoneTimeReadTheInjectedClock_killsWallClockStamp() async throws {
        let server = SyncFakeServer(userId: uid)
        let device = makeDevice(0, seed: 0, server: server)
        let e = Event(title: "stamped", createdAt: epoch)

        await device.service.syncEvents([e], kind: "calendar")
        let inserted = try XCTUnwrap((server.requests(.insert).first?.body as? [[String: Any]])?.first)
        let at = Self.iso.string(from: device.clock.now())
        XCTAssertEqual(inserted["updated_at"] as? String, at)
        XCTAssertEqual(inserted["synced_at"] as? String, at)

        device.clock.advance(by: 90)
        await device.service.syncEvents([], kind: "calendar")
        XCTAssertEqual(server.requests(.tombstone).first?.body as? Date, device.clock.now())
        XCTAssertEqual(server.row(table: "events", key: e.id.uuidString)?.deletedAt, Self.iso.string(from: device.clock.now()))

        device.defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        await device.service.syncSettings()
        let settings = try XCTUnwrap((server.requests(.insert, table: "user_settings").first?.body as? [[String: Any]])?.first)
        XCTAssertEqual(settings["synced_at"] as? String, Self.iso.string(from: device.clock.now()))
    }
}

