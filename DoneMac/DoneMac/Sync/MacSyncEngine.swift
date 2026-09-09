//
//  MacSyncEngine.swift
//  DoneMac
//
//  Sync phase 1 (the plan's "read through + safe local push"): pull the
//  Supabase mirror, adopt server truth except locally-dirty rows, then
//  push the dirty ones through the SHARED SupabaseEventRowCodec — a
//  Mac-authored row is shape-identical to an iOS row, so the iOS restore
//  path stays safe by construction. Conflict policy is the stale-write
//  guardrail: a dirty row whose server stamp moved since our last pull —
//  or that LEFT the server's calendar slot (deleted / kind-flipped on
//  iOS) — lost the race: iOS wins, surfaced in the summary. Baselines
//  and tombstones are PERSISTED in the sidecar (round-5: an in-memory
//  map died with the session while dirtiness survived, so a relaunch let
//  a stale Mac edit clobber a newer iPhone write). Still not promised
//  this phase: field-level merging, offline three-way.
//

import Foundation

/// The seam a test can fake: what the engine needs from the network.
@MainActor
protocol RemoteEventsGateway {
    func fetchEventRows(userId: String) async throws -> [[String: Any]]
    func upsertEventRows(_ rows: [[String: Any]]) async throws
    func deleteEventRows(ids: [String]) async throws
}

@MainActor
struct SupabaseEventsGateway: RemoteEventsGateway {
    let rest: SupabaseREST

    init(authService: AuthService) {
        // SupabaseSyncConfig.anonKey is platform-split: the Mac compilation
        // carries ONLY the true anon key (role verified via the management
        // API) — the service_role literal never enters this binary.
        rest = SupabaseREST(
            url: SupabaseSyncConfig.url,
            projectAPIKey: SupabaseSyncConfig.anonKey,
            authService: authService
        )
    }

    func fetchEventRows(userId: String) async throws -> [[String: Any]] {
        try await rest.fetchAll(table: "events", userId: userId)
    }

    func upsertEventRows(_ rows: [[String: Any]]) async throws {
        try await rest.upsert(table: "events", rows: rows)
    }

    func deleteEventRows(ids: [String]) async throws {
        try await rest.delete(table: "events", ids: ids)
    }
}

@MainActor
@Observable
final class MacSyncEngine {
    enum Phase: Equatable {
        case signedOut
        case idle
        case pulling
        case pushing
        case failed(String)
    }

    private(set) var phase: Phase = .signedOut
    private(set) var lastSyncAt: Date?
    private(set) var lastSummary: String = ""

    @ObservationIgnored private let store: MacEventStore
    @ObservationIgnored private let gateway: RemoteEventsGateway
    /// Who is signed in — a closure so tests never need a real AuthService.
    /// The production closure captures the runtime's process-lifetime
    /// AuthService strongly; a deallocated auth graph should fail loudly,
    /// not read as signed-out (round-5 review #15).
    @ObservationIgnored private let identity: () -> String?

    @ObservationIgnored private static let isoFormatter: ISO8601DateFormatter = {
        // Must match the iOS uploader's configuration exactly so row
        // timestamps hash/compare identically across devices.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(
        store: MacEventStore,
        gateway: RemoteEventsGateway,
        identity: @escaping () -> String?
    ) {
        self.store = store
        self.gateway = gateway
        self.identity = identity
    }

    var isBusy: Bool { phase == .pulling || phase == .pushing }

    func syncNow(now: Date) async {
        guard !isBusy else { return }
        guard let userId = identity() else {
            phase = .signedOut
            return
        }
        guard !store.sidecarFrozen else {
            // Every live edit reads clean under a frozen sidecar — a pull
            // would revert them (round-5 review #8).
            phase = .failed("Local revision tracking unavailable — sync paused")
            return
        }
        phase = .pulling
        do {
            let rows = try await gateway.fetchEventRows(userId: userId)
            var remote: [Event] = []
            var stamps: [UUID: String] = [:]
            var decoded = 0
            for row in rows {
                // Stamps are captured for EVERY row id, BEFORE the kind
                // filter — a row that left the calendar slot must still be
                // visible to the guardrail (round-5 review #4b).
                if let idString = row["id"] as? String, let id = UUID(uuidString: idString),
                   let stamp = row["updated_at"] as? String {
                    stamps[id] = stamp
                }
                guard row["kind"] as? String == "calendar" else { continue }
                guard let event = SupabaseEventRowCodec.rowToEvent(row) else { continue }
                remote.append(event)
                decoded += 1
                if decoded % 500 == 0 {
                    // Hitch bound for large pulls; the isolation surgery
                    // that would move decode fully off-main is gated on a
                    // phase-6 measurement, not assumed (falsifiable gate).
                    await Task.yield()
                }
            }
            // Deterministic order: the merge's no-change guard compares
            // arrays, and PostgREST order is only as stable as our query
            // (round-5 review #12; fetchAll now orders by id too).
            remote.sort { $0.id.uuidString < $1.id.uuidString }

            // Stale-write guardrail, persisted baseline: conflicted =
            // stamp moved, OR the row left the server's calendar slot
            // while we hold it dirty/tombstoned (deleted or kind-flipped
            // on iOS — iOS wins both ways).
            let baseline = store.serverStamps
            let awaiting = store.pushedAwaitingRebaseline
            let dirtyAndDead = store.dirtyEventIDs().union(store.tombstonedIDs)
            let conflicted = dirtyAndDead.filter { id in
                // Our own push's echo is not a foreign write — it rebaselines
                // without a conflict (round-6: string-comparing our formatted
                // stamp against the server's echo misfires on format alone).
                guard !awaiting.contains(id) else { return false }
                guard let old = baseline[id] else { return false }
                guard let new = stamps[id] else { return true }  // left the slot
                return old != new
            }

            let adoption = store.applyRemoteEvents(
                remote, overridingDirty: conflicted, now: now
            )
            // Tombstones the server re-wrote came back via the merge;
            // the rest still carry a pending delete.
            store.setServerStamps(stamps)

            phase = .pushing
            var pushedCount = 0
            let dirtyRevisions = store.dirtyRevisions()
            let dirty = store.dirtyEvents()
            if !dirty.isEmpty {
                // Wire timestamp only — freshly read so a slow pull can't
                // stamp rows into the past of an iOS write that landed
                // mid-sync (round-5 review #11). Domain time stays `now`.
                let wireNow = Date()
                let payload = dirty.map {
                    SupabaseEventRowCodec.eventToRow(
                        $0, kind: "calendar", userId: userId,
                        now: wireNow, iso: Self.isoFormatter
                    )
                }
                try await gateway.upsertEventRows(payload)
                store.markPushed(dirtyRevisions)
                store.markAwaitingRebaseline(Set(dirty.map(\.id)))
                pushedCount = dirty.count
            }
            // Delete push: tombstones that survived the merge.
            let pendingDeletes = store.tombstonedIDs
            if !pendingDeletes.isEmpty {
                try await gateway.deleteEventRows(ids: pendingDeletes.map(\.uuidString))
                store.clearTombstones(pendingDeletes)
            }

            lastSyncAt = now
            lastSummary = summaryText(
                adoption: adoption, pushed: pushedCount, deleted: pendingDeletes.count
            )
            phase = .idle
        } catch {
            let nsError = error as NSError
            phase = .failed(nsError.localizedDescription.isEmpty
                ? String(describing: error) : nsError.localizedDescription)
        }
    }

    private func summaryText(
        adoption: MacEventStore.RemoteAdoption, pushed: Int, deleted: Int
    ) -> String {
        var parts: [String] = []
        if adoption.adopted > 0 { parts.append("\(adoption.adopted) pulled") }
        if adoption.removed > 0 { parts.append("\(adoption.removed) removed") }
        if adoption.overriddenDirty > 0 { parts.append("\(adoption.overriddenDirty) updated on iPhone") }
        if pushed > 0 { parts.append("\(pushed) pushed") }
        if deleted > 0 { parts.append("\(deleted) deletes propagated") }
        return parts.isEmpty ? "up to date" : parts.joined(separator: ", ")
    }
}
