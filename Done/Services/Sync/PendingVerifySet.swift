//
//  PendingVerifySet.swift
//  Done
//
//  What a conditional PATCH's `[]` response leaves behind (design §6 上传形状,
//  "`[]` 的收口"). `[]` means stale OR content-identical, and the two look the
//  same on the wire; the pull that follows tells them apart. An element
//  remembers everything that pull needs:
//
//    sentSeq    the baseline seq the PATCH filter carried
//    payload    the hash of the row AS SENT (settings: its per-key hashes) —
//               computed when the request was built, never from the row the
//               device holds later (interleaving (iii))
//    pullIssue  the engine's pull issue counter when `[]` arrived; only a pull
//               issued AFTER that may clear the element (interleaving (i))
//
//  In memory only, keyed by (table, id) and not by id — the three
//  single-row tables share one id (the uid). Dies with the process; the
//  next flush's `[]` re-marks.
//

import Foundation

enum PendingVerifyPayload: Equatable {
    case rowHash(String)
    case settingsKeys([String: String])
}

struct PendingVerifyElement: Equatable {
    let sentSeq: Int64
    let payload: PendingVerifyPayload
    let pullIssue: Int
}

struct PendingVerifySet {
    private(set) var elements: [SyncBaselineKey: PendingVerifyElement] = [:]

    var isEmpty: Bool { elements.isEmpty }
    var count: Int { elements.count }

    subscript(key: SyncBaselineKey) -> PendingVerifyElement? { elements[key] }

    func contains(_ key: SyncBaselineKey) -> Bool { elements[key] != nil }

    /// A later `[]` for the same key replaces the element: the newer PATCH
    /// carried the newer baseline seq and the newer sent hash.
    mutating func insert(_ key: SyncBaselineKey, sentSeq: Int64, payload: PendingVerifyPayload, pullIssue: Int) {
        elements[key] = PendingVerifyElement(sentSeq: sentSeq, payload: payload, pullIssue: pullIssue)
    }

    mutating func remove(_ key: SyncBaselineKey) {
        elements[key] = nil
    }

    /// Sign-out: nothing survives into the next session.
    mutating func reset() {
        elements = [:]
    }

    /// Called once per pull that reached head, with the (table, id) set that
    /// pull delivered and the issue number of the RPC that returned the short
    /// page. Exactly the design's rule:
    ///
    ///   * an element whose `pullIssue` is not below `pullIssue` is untouched —
    ///     that pull may have snapshotted the server before the write that
    ///     made the PATCH stale;
    ///   * seen → dropped (the three-way compare already moved `base.seq`);
    ///   * unseen and `baselineSeq == sentSeq` → the server short-circuited an
    ///     identical write: `confirm` is handed the SENT payload to write as
    ///     the baseline hash / keys, then dropped;
    ///   * unseen and `baselineSeq != sentSeq` → a pull moved the baseline
    ///     while the PATCH was in flight: stale, dropped, hash untouched.
    ///
    /// Returns the keys that were cleared.
    @discardableResult
    mutating func resolveAtHead(
        seen: Set<SyncBaselineKey>,
        pullIssue: Int,
        baselineSeq: (SyncBaselineKey) -> Int64?,
        confirm: (SyncBaselineKey, PendingVerifyPayload) -> Void
    ) -> [SyncBaselineKey] {
        var cleared: [SyncBaselineKey] = []
        for (key, element) in elements {
            guard pullIssue > element.pullIssue else { continue }
            if !seen.contains(key), baselineSeq(key) == element.sentSeq {
                confirm(key, element.payload)
            }
            cleared.append(key)
        }
        for key in cleared { elements[key] = nil }
        return cleared
    }
}
