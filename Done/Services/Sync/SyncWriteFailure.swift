//
//  SyncWriteFailure.swift
//  Done
//
//  What an outbound write's failure means (survey S1, gap G7; design §6
//  失败分类), and the persisted set of rows the server refused.
//
//  Every thrown error is asked about independently:
//
//    kind           what to do about the row: send it again next flush, give
//                   the server's schema cache time, split the request, or
//                   stop sending this version of the row.
//    mayHaveLanded  whether the request may have reached the server and been
//                   applied even though no answer came back (survey S4). An
//                   HTTP status means the server answered, so it did not land
//                   unless it said 2xx; a transport error after the request
//                   left, or a 2xx whose body could not be read, may have.
//

import Foundation

enum SyncWriteFailureKind: Equatable {
    /// A 401 that `SupabaseREST`'s own forced refresh and retry did not
    /// cure. Nothing to record; the next flush tries again with whatever
    /// session `AuthService` holds by then.
    case unauthorized
    /// Transport errors, 5xx, 408, 429, deadlock / statement timeout / lock
    /// timeout. Sent again next flush.
    case retryable
    /// PostgREST's schema cache (`PGRST2xx`) — seen between a migration and
    /// the `NOTIFY pgrst` reload. Retryable for a bounded window, then
    /// treated as a rejection carrying the code.
    case schemaCache
    /// 413 / 414: the request was too big (a long `id=in.(…)` URL or a big
    /// POST chunk). Split, never rejected while it can still be split.
    case tooLarge
    /// The server refused the row itself: data exceptions, integrity
    /// constraints, insufficient privilege.
    case rejected
}

struct SyncWriteFailure: Equatable {
    let kind: SyncWriteFailureKind
    /// PostgREST / Postgres code when the body carried one, otherwise the
    /// HTTP status or the transport error, as text for the trail.
    let code: String
    let mayHaveLanded: Bool

    /// Transport errors that are raised before a request leaves the device:
    /// no route, no host, no connection. Every other `URLError` may have
    /// been raised after the server received the request.
    nonisolated private static let notSentURLErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
        .dnsLookupFailed, .internationalRoamingOff, .callIsActive,
        .dataNotAllowed, .badURL, .unsupportedURL,
        .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
    ]

    nonisolated private static let retryableCodes: Set<String> = ["40P01", "57014", "55P03"]
    nonisolated private static let retryableStatuses: Set<Int> = [408, 429]

    static func classify(_ error: Error) -> SyncWriteFailure {
        if let urlError = error as? URLError {
            return SyncWriteFailure(
                kind: .retryable,
                code: "url\(urlError.code.rawValue)",
                mayHaveLanded: !notSentURLErrors.contains(urlError.code)
            )
        }
        if let syncError = error as? SupabaseREST.SyncError {
            switch syncError {
            case .tokenExpired:
                return SyncWriteFailure(kind: .unauthorized, code: "401", mayHaveLanded: false)
            case .notSignedIn:
                return SyncWriteFailure(kind: .retryable, code: "not_signed_in", mayHaveLanded: false)
            case .malformedResponse:
                // A 2xx came back: the write ran, its rows are unreadable.
                return SyncWriteFailure(kind: .retryable, code: "malformed_response", mayHaveLanded: true)
            case .requestFailed(_, _, let status, let code):
                return classify(status: status, code: code)
            case .upsertFailed(_, let status), .deleteFailed(_, let status), .fetchFailed(_, let status):
                return classify(status: status, code: nil)
            }
        }
        // Anything else reached here after the request was built: a body
        // that failed to decode after a 2xx, a cancelled task mid-flight.
        // The safe reading is "may have landed" — it costs a re-verify.
        return SyncWriteFailure(kind: .retryable, code: String(describing: type(of: error)), mayHaveLanded: true)
    }

    /// A response with a status: the server answered, so nothing landed.
    static func classify(status: Int, code: String?) -> SyncWriteFailure {
        let label = code ?? "http\(status)"
        func failure(_ kind: SyncWriteFailureKind) -> SyncWriteFailure {
            SyncWriteFailure(kind: kind, code: label, mayHaveLanded: false)
        }
        if status == 401 { return failure(.unauthorized) }
        if status == 413 || status == 414 { return failure(.tooLarge) }
        if let code {
            if retryableCodes.contains(code) { return failure(.retryable) }
            if code.hasPrefix("PGRST2") { return failure(.schemaCache) }
            if isRejectionCode(code) { return failure(.rejected) }
        }
        if status >= 500 || retryableStatuses.contains(status) { return failure(.retryable) }
        // An unlisted 4xx: not known to be permanent, so it is not recorded
        // as a rejection; it is sent again like any retryable failure.
        return failure(.retryable)
    }

    /// Class 22 (data exception), class 23 (integrity constraint violation),
    /// and 42501 (insufficient privilege, e.g. an RLS refusal).
    static func isRejectionCode(_ code: String) -> Bool {
        guard code.count == 5 else { return false }
        return code.hasPrefix("22") || code.hasPrefix("23") || code == "42501"
    }
}

/// What the server refused, kept so the row is not sent again while it is
/// the same row (survey S1): keyed by `(table, id)` with the hash of the
/// version that was refused. A changed local row has a different hash and
/// goes out again; the local value and the baseline are never touched.
///
/// Persisted under `syncHashes.<uid>.rejected`, so a relaunch does not
/// resend a refused row and the erase's prefix sweep removes it.
@MainActor
final class SyncRejectedSet {
    nonisolated static let tableLabel = "rejected"
    /// The hash recorded for a refused tombstone: the local state that was
    /// refused is "absent", which no row hash equals.
    nonisolated static let deletedHash = "-"

    struct Element: Equatable, Codable {
        let hash: String
        let code: String
    }

    let defaults: UserDefaults
    let userId: String
    private var elements: [String: [String: Element]] = [:]

    init(defaults: UserDefaults, userId: String) {
        self.defaults = defaults
        self.userId = userId
        load()
    }

    private var key: String { SyncBaselineStore.key(userId: userId, table: Self.tableLabel) }

    var isEmpty: Bool { elements.values.allSatisfy(\.isEmpty) }

    subscript(key: SyncBaselineKey) -> Element? { elements[key.table]?[key.id] }

    func ids(table: String) -> [String] { Array((elements[table] ?? [:]).keys) }

    /// Whether `hash` is the version of this row the server refused.
    func refuses(_ key: SyncBaselineKey, hash: String) -> Bool {
        self[key]?.hash == hash
    }

    /// Returns true when this is a new `(table, id, hash)` — the caller
    /// writes the trail line once per refused version.
    @discardableResult
    func insert(_ key: SyncBaselineKey, hash: String, code: String) -> Bool {
        let element = Element(hash: hash, code: code)
        guard self[key] != element else { return false }
        elements[key.table, default: [:]][key.id] = element
        persist()
        return true
    }

    func remove(_ key: SyncBaselineKey) {
        guard self[key] != nil else { return }
        elements[key.table]?[key.id] = nil
        persist()
    }

    private func load() {
        guard !userId.isEmpty,
              let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [String: Element]].self, from: data)
        else { return }
        elements = decoded
    }

    private func persist() {
        guard !userId.isEmpty else { return }
        let compact = elements.filter { !$0.value.isEmpty }
        if compact.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(compact) {
            defaults.set(data, forKey: key)
        }
    }
}
