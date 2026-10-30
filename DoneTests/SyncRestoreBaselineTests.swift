//
//  SyncRestoreBaselineTests.swift
//  DoneTests
//
//  Survey S6 / gap G12: the restore's baseline replay names the SERVER.
//  A row the cloud snapshot carried gets hash(cloud row)@cloud seq, so a
//  row restored from the cloud reads clean and a keepLocal collision row
//  reads dirty and is PATCHed on the cloud seq. A row the cloud did not
//  carry keeps its entry after a merge and takes the legacy shape after an
//  overwrite.
//

import XCTest
@testable import Done

@MainActor
final class SyncRestoreBaselineTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var server: SyncFakeServer!
    private var service: SupabaseSyncService!
    private let uid = "88888888-8888-8888-8888-888888888888"

    override func setUp() {
        super.setUp()
        suiteName = "SyncRestoreBaselineTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        server = SyncFakeServer(userId: uid)
        service = SupabaseSyncService(gateway: server, userId: uid, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeEvent(_ title: String, note: String = "") -> Event {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return Event(title: title, note: note,
                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))])
    }

    private func hash(_ event: Event) -> String {
        SupabaseSyncService.rowHash(service.eventToRow(event, kind: "calendar"))
    }

    private func entry(_ event: Event) -> SyncBaselineEntry? {
        service.baseline.entry(table: "calendar_events", id: event.id.uuidString)
    }

    private func replay(calendar: [Event], snapshot: RestoreSnapshot? = nil, strategy: RestoreStrategy = .merge) {
        service.markRestoreCompleted(
            todoEvents: [], calendarEvents: calendar, logs: [], feedback: [],
            todoLists: [], eventTypes: [], skills: [], snapshot: snapshot, strategy: strategy
        )
    }

    func testTheRestoreFetchKeepsTheCloudSeqOfEveryCarriedRow() async throws {
        let x = makeEvent("X")
        let seeded = server.seed(table: "events", rows: [service.eventToRow(x, kind: "calendar")])
        server.seed(table: "user_settings", rows: [["user_id": uid, "settings": ["a": 1]]])

        let snapshot = try await service.fetchRestoreSnapshot()

        XCTAssertEqual(snapshot.cloudSeqs[SyncBaselineKey(table: "calendar_events", id: x.id.uuidString)], seeded[x.id.uuidString],
                       "keyed by the device's spelling of the id, though the server rendered it lowercase")
        XCTAssertNotNil(snapshot.cloudSeqs[SupabaseSyncService.restoreSingletonKey("user_settings")])
        XCTAssertEqual(service.lastRestoreSnapshot?.cloudSeqs, snapshot.cloudSeqs, "kept for markRestoreCompleted")
    }

    func testKeepLocalCollisionRowIsPatchedOnTheCloudSeqAndCloudRowsReadClean_killsHashOfLocalRow() async throws {
        let cloudX = makeEvent("X", note: "cloud")
        var localX = cloudX
        localX.note = "local"
        let y = makeEvent("Y", note: "same on both")
        let seeded = server.seed(table: "events", rows: [cloudX, y].map { service.eventToRow($0, kind: "calendar") })
        let sx = try XCTUnwrap(seeded[cloudX.id.uuidString])
        let snapshot = try await service.fetchRestoreSnapshot()

        // keepLocal: X stays local, Y came from the cloud.
        replay(calendar: [localX, y])

        XCTAssertEqual(entry(localX), SyncBaselineEntry(hash: hash(cloudX), seq: sx), "the cloud's version at the cloud seq")
        XCTAssertNil(service.lastRestoreSnapshot, "consumed")
        _ = snapshot

        await service.syncEvents([localX, y], kind: "calendar")

        let patches = server.requests(.patch)
        XCTAssertEqual(patches.map(\.keys), [[localX.id.uuidString]], "only the keepLocal collision row; the mutant writes hash(local) and sends nothing")
        XCTAssertEqual(patches.first?.baseSeq, sx)
        XCTAssertEqual(server.row(table: "events", key: localX.id.uuidString)?.data["note"] as? String, "local")
        XCTAssertTrue(server.requests(.insert).isEmpty)
        XCTAssertEqual(entry(localX)?.hash, hash(localX))
    }

    func testRowTheCloudDidNotCarryKeepsItsEntryAfterAMergeAndTheLegacyShapeAfterAnOverwrite() async throws {
        let onlyLocal = makeEvent("only here")
        service.baseline.setEntry(SyncBaselineEntry(hash: "older", seq: 41), table: "calendar_events", id: onlyLocal.id.uuidString)
        let snapshot = try await service.fetchRestoreSnapshot()

        replay(calendar: [onlyLocal], snapshot: snapshot)
        XCTAssertEqual(entry(onlyLocal), SyncBaselineEntry(hash: "older", seq: 41), "a merge learned nothing about it: the entry stays")

        replay(calendar: [onlyLocal], snapshot: snapshot, strategy: .cloudOverwritesLocal)
        XCTAssertEqual(entry(onlyLocal), SyncBaselineEntry(hash: hash(onlyLocal), seq: 41), "an overwrite: local hash, the seq already known")
    }

    func testSettingsKeptLocalReadDirtyAndArePatchedOnTheCloudSeq() async throws {
        let seeded = server.seed(table: "user_settings", rows: [[
            "user_id": uid, "settings": [AppSettingsKeys.showTimerBanner: false],
        ]])
        let s0 = try XCTUnwrap(seeded[uid])
        let snapshot = try await service.fetchRestoreSnapshot()
        // keepLocal: the local value of the colliding key stays.
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)

        replay(calendar: [], snapshot: snapshot)
        await service.syncSettings()

        let patch = try XCTUnwrap(server.requests(.patch, table: "user_settings").first, "the mutant seeds local keys and sends nothing")
        XCTAssertEqual(patch.baseSeq, s0)
        let sent = try XCTUnwrap((patch.body as? [String: Any])?["settings"] as? [String: Any])
        XCTAssertEqual(sent[AppSettingsKeys.showTimerBanner] as? Bool, true)
    }

    func testSettingsTakenFromTheCloudReadClean() async throws {
        // After a keepCloud restore the local blob IS the cloud's.
        defaults.set(true, forKey: AppSettingsKeys.showTimerBanner)
        server.seed(table: "user_settings", rows: [[
            "user_id": uid, "settings": SyncedSettings.currentSnapshot(defaults),
        ]])
        let snapshot = try await service.fetchRestoreSnapshot()

        replay(calendar: [], snapshot: snapshot)
        let before = server.requests.count
        await service.syncSettings()

        XCTAssertEqual(server.requests.count, before)
    }

    func testWithoutAnySnapshotAMergeRecordsNothingAndAnOverwriteTakesTheLocalState() {
        let e = makeEvent("no fetch")
        replay(calendar: [e])
        XCTAssertNil(entry(e), "a merge with nothing from the cloud records nothing as uploaded")

        replay(calendar: [e], strategy: .cloudOverwritesLocal)
        XCTAssertEqual(entry(e), SyncBaselineEntry(hash: hash(e), seq: nil))
    }
}
