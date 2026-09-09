//
//  MacSyncEngine.swift
//  DoneMac
//
//  Sync phase 1 (the plan's "read through + safe local push"): pull the
//  Supabase mirror, adopt server truth except locally-dirty rows, then
//  push the dirty ones through the SHARED SupabaseEventRowCodec — a
//  Mac-authored row is shape-identical to an iOS row, so the iOS restore
//  path stays safe by construction. Conflict policy is the plan's
//  stale-write guardrail: a dirty row whose server stamp moved since our
//  last pull means an iOS write landed — iOS wins, the local edit is
//  dropped and the server row adopted. What phase 1 explicitly does NOT
//  promise: merging, tombstones, offline three-way. The server-stamp map
//  is in-memory (per-session guardrail) — persisting it is phase-2 work
//  alongside real per-record revisions on the wire.
//
//  API-key note: this client sends the true `anon` key (role: anon) —
//  never the misnamed service_role literal iOS is still stuck with until
//  #28 Stage 3 rotation completes. RLS is the enforcement either way
//  (Authorization carries the user JWT).
//

import Foundation

/// The seam a test can fake: what the engine needs from the network.
@MainActor
protocol RemoteEventsGateway {
    func fetchEventRows(userId: String) async throws -> [[String: Any]]
    func upsertEventRows(_ rows: [[String: Any]]) async throws
}

@MainActor
struct SupabaseEventsGateway: RemoteEventsGateway {
    /// The project's true anon key (role: "anon", verified via the
    /// management API 2026-09-09). Routing/identity only — RLS authority
    /// is the per-user JWT the shared REST client attaches.
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVxbnZ0emJscHBqYmx3Z2JwcWhmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYxNjMwOTIsImV4cCI6MjA5MTczOTA5Mn0.yBuF38eU6etNUii-VGC_R5Ts7O4ioVOhlm_3JlOEHkc"

    let rest: SupabaseREST

    init(authService: AuthService) {
        rest = SupabaseREST(
            url: SupabaseSyncConfig.url,
            projectAPIKey: Self.anonKey,
            authService: authService
        )
    }

    func fetchEventRows(userId: String) async throws -> [[String: Any]] {
        try await rest.fetchAll(table: "events", userId: userId)
    }

    func upsertEventRows(_ rows: [[String: Any]]) async throws {
        try await rest.upsert(table: "events", rows: rows)
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
    @ObservationIgnored private let identity: () -> String?
    @ObservationIgnored private let calendar: Calendar
    /// Server `updated_at` per row as of OUR last pull — the stale-write
    /// guardrail's memory. In-memory by design this phase.
    @ObservationIgnored private var serverStamp: [UUID: String] = [:]

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
        calendar: Calendar,
        identity: @escaping () -> String?
    ) {
        self.store = store
        self.gateway = gateway
        self.calendar = calendar
        self.identity = identity
    }

    var isBusy: Bool { phase == .pulling || phase == .pushing }

    func syncNow(now: Date) async {
        guard !isBusy else { return }
        guard let userId = identity() else {
            phase = .signedOut
            return
        }
        phase = .pulling
        do {
            let rows = try await gateway.fetchEventRows(userId: userId)
            var remote: [Event] = []
            var stamps: [UUID: String] = [:]
            var decoded = 0
            for row in rows {
                // The events table carries both slots; the Mac store owns
                // the calendar slot only this phase.
                guard row["kind"] as? String == "calendar" else { continue }
                guard let event = SupabaseEventRowCodec.rowToEvent(row) else { continue }
                remote.append(event)
                if let stamp = row["updated_at"] as? String {
                    stamps[event.id] = stamp
                }
                decoded += 1
                if decoded % 500 == 0 {
                    // Hitch bound for large pulls; the isolation surgery
                    // that would move decode fully off-main is gated on a
                    // phase-6 measurement, not assumed (falsifiable gate).
                    await Task.yield()
                }
            }

            // Stale-write guardrail: a dirty row whose server stamp moved
            // since our last pull lost the race — iOS wins.
            let conflicted = store.dirtyEventIDs().filter { id in
                guard let old = serverStamp[id], let new = stamps[id] else { return false }
                return old != new
            }

            let adoption = store.applyRemoteEvents(
                remote, overridingDirty: conflicted, now: now
            )
            serverStamp = stamps

            phase = .pushing
            let dirty = store.dirtyEvents()
            if !dirty.isEmpty {
                let payload = dirty.map {
                    SupabaseEventRowCodec.eventToRow(
                        $0, kind: "calendar", userId: userId,
                        now: now, iso: Self.isoFormatter
                    )
                }
                try await gateway.upsertEventRows(payload)
                store.markPushed(Set(dirty.map(\.id)))
                // Our own writes changed the server stamps; forget the ones
                // we just overwrote so the NEXT pull re-baselines them
                // instead of reading our own push as a foreign conflict.
                for id in dirty.map(\.id) { serverStamp.removeValue(forKey: id) }
            }

            lastSyncAt = now
            lastSummary = summaryText(adoption: adoption, pushed: dirty.count)
            phase = .idle
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private func summaryText(adoption: MacEventStore.RemoteAdoption, pushed: Int) -> String {
        var parts: [String] = []
        if adoption.adopted > 0 { parts.append("\(adoption.adopted) pulled") }
        if adoption.removed > 0 { parts.append("\(adoption.removed) removed") }
        if adoption.overriddenDirty > 0 { parts.append("\(adoption.overriddenDirty) updated on iPhone") }
        if pushed > 0 { parts.append("\(pushed) pushed") }
        return parts.isEmpty ? "up to date" : parts.joined(separator: ", ")
    }
}
