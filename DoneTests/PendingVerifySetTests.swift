//
//  PendingVerifySetTests.swift
//  DoneTests
//
//  The pure rule behind "`[]` 的收口" (design §6 上传形状), pinned against
//  the three interleavings the reviews derived and the three mutants §8
//  names: "clear on any pull", "recompute the hash from the live row", and
//  "key by id only". Each test's name says which mutant it kills.
//

import XCTest
@testable import Done

@MainActor
final class PendingVerifySetTests: XCTestCase {

    private let x = SyncBaselineKey(table: "calendar_events", id: "X")
    private let uid = "USER"

    /// A baseline fixture the set is resolved against; the closure pair is
    /// what the service wires to `SyncBaselineStore`.
    private final class Baseline {
        var seq: [SyncBaselineKey: Int64] = [:]
        var hash: [SyncBaselineKey: String] = [:]
        var confirmed: [(SyncBaselineKey, PendingVerifyPayload)] = []

        func resolve(_ set: inout PendingVerifySet, seen: Set<SyncBaselineKey>, pullIssue: Int) -> [SyncBaselineKey] {
            set.resolveAtHead(
                seen: seen,
                pullIssue: pullIssue,
                baselineSeq: { self.seq[$0] },
                confirm: { key, payload in
                    self.confirmed.append((key, payload))
                    if case .rowHash(let h) = payload { self.hash[key] = h }
                }
            )
        }
    }

    // MARK: (i) a pull issued before the `[]` must not clear
    // Mutant "clear on any pull that reaches head" fails here.

    func testPullIssuedBeforeTheEmptyResponseLeavesTheElement_killsClearOnAnyPull() {
        var set = PendingVerifySet()
        let base = Baseline()
        base.seq[x] = 0
        base.hash[x] = "h0"
        // `[]` arrived while pull issue 5 (P1) was already in flight.
        set.insert(x, sentSeq: 0, payload: .rowHash("h1"), pullIssue: 5)

        let cleared = base.resolve(&set, seen: [], pullIssue: 5)

        XCTAssertEqual(cleared, [], "P1 (issue 5) carries no information about a write it may predate")
        XCTAssertTrue(set.contains(x))
        XCTAssertEqual(base.hash[x], "h0", "the mutant would have marked c1 clean here, and the next pull would overwrite it with c2")
        XCTAssertTrue(base.confirmed.isEmpty)
    }

    func testEligiblePullThatSeesTheRowDropsItWithoutConfirming() {
        var set = PendingVerifySet()
        let base = Baseline()
        base.seq[x] = 1          // the applier's dirty branch already moved base.seq to s1
        base.hash[x] = "h0"
        set.insert(x, sentSeq: 0, payload: .rowHash("h1"), pullIssue: 5)

        let cleared = base.resolve(&set, seen: [x], pullIssue: 6)

        XCTAssertEqual(cleared, [x])
        XCTAssertFalse(set.contains(x))
        XCTAssertEqual(base.hash[x], "h0", "seen rows were compared three-way already; nothing to confirm")
        XCTAssertTrue(base.confirmed.isEmpty)
    }

    // MARK: (ii) baseline moved while the PATCH was in flight → stale, not identical

    func testUnseenWithMovedBaselineSeqIsDroppedWithHashUntouched_killsOldSameRule() {
        var set = PendingVerifySet()
        let base = Baseline()
        base.seq[x] = 1          // a pull applied X@s1 between building and sending the PATCH
        base.hash[x] = "h0"
        set.insert(x, sentSeq: 0, payload: .rowHash("h1"), pullIssue: 5)

        let cleared = base.resolve(&set, seen: [], pullIssue: 6)

        XCTAssertEqual(cleared, [x])
        XCTAssertEqual(base.hash[x], "h0", "the old rule (unseen ⇒ identical) would have written h1 and c1 would never upload")
        XCTAssertTrue(base.confirmed.isEmpty)
    }

    // MARK: (iii) identical write: confirm with the SENT hash, never the live row

    func testUnseenWithSameSeqConfirmsTheSentHash_killsRecomputeFromLiveRow() {
        var set = PendingVerifySet()
        let base = Baseline()
        base.seq[x] = 0
        base.hash[x] = "h0"
        set.insert(x, sentSeq: 0, payload: .rowHash("h1"), pullIssue: 5)
        // The user edited X to c3 in the window; the live row now hashes to
        // h3. The element must not know or care.
        let liveRowHash = "h3"

        let cleared = base.resolve(&set, seen: [], pullIssue: 6)

        XCTAssertEqual(cleared, [x])
        XCTAssertEqual(base.confirmed.count, 1)
        XCTAssertEqual(base.confirmed.first?.1, .rowHash("h1"))
        XCTAssertEqual(base.hash[x], "h1")
        XCTAssertNotEqual(base.hash[x], liveRowHash, "writing the live hash would mark c3 clean and it would never upload")
    }

    func testSettingsElementConfirmsSentKeysNotRowHash() {
        var set = PendingVerifySet()
        let base = Baseline()
        let settings = SyncBaselineKey(table: "user_settings", id: uid)
        base.seq[settings] = 7
        let sentKeys = ["a": "ha", "b": "hb"]
        set.insert(settings, sentSeq: 7, payload: .settingsKeys(sentKeys), pullIssue: 1)

        base.resolve(&set, seen: [], pullIssue: 2)

        XCTAssertEqual(base.confirmed.first?.1, .settingsKeys(sentKeys))
    }

    // MARK: key is (table, id), not id

    func testSingletonTablesSharingTheUidAreIndependent_killsKeyByIdOnly() {
        var set = PendingVerifySet()
        let base = Baseline()
        let settings = SyncBaselineKey(table: "user_settings", id: uid)
        let prefs = SyncBaselineKey(table: "agent_preferences", id: uid)
        base.seq[settings] = 3
        base.seq[prefs] = 9
        set.insert(settings, sentSeq: 3, payload: .settingsKeys(["k": "h"]), pullIssue: 1)
        set.insert(prefs, sentSeq: 9, payload: .rowHash("hp"), pullIssue: 1)
        XCTAssertEqual(set.count, 2, "two tables, one id, two elements")

        // The pull saw the settings echo only.
        let cleared = base.resolve(&set, seen: [settings], pullIssue: 2)

        XCTAssertEqual(Set(cleared), [settings, prefs])
        XCTAssertEqual(base.confirmed.count, 1, "settings was seen (no confirm); prefs was unseen with the same seq (confirmed)")
        XCTAssertEqual(base.confirmed.first?.0, prefs)
        XCTAssertEqual(base.confirmed.first?.1, .rowHash("hp"))
    }

    func testUnseenPrefsWithUnrelatedSettingsBaselineSeqIsComparedAgainstItsOwnTable() {
        var set = PendingVerifySet()
        let base = Baseline()
        let settings = SyncBaselineKey(table: "user_settings", id: uid)
        let prefs = SyncBaselineKey(table: "agent_preferences", id: uid)
        base.seq[settings] = 9       // same number as prefs' sentSeq — a by-id lookup could be fooled
        base.seq[prefs] = 10         // prefs' own baseline moved
        set.insert(prefs, sentSeq: 9, payload: .rowHash("hp"), pullIssue: 1)

        base.resolve(&set, seen: [], pullIssue: 2)

        XCTAssertTrue(base.confirmed.isEmpty, "prefs' baseline seq is 10 ≠ 9: stale, not identical")
        XCTAssertFalse(set.contains(prefs))
    }

    // MARK: housekeeping

    func testInsertReplacesAnExistingElementForTheSameKey() {
        var set = PendingVerifySet()
        set.insert(x, sentSeq: 0, payload: .rowHash("h1"), pullIssue: 1)
        set.insert(x, sentSeq: 2, payload: .rowHash("h2"), pullIssue: 3)
        XCTAssertEqual(set.count, 1)
        XCTAssertEqual(set[x], PendingVerifyElement(sentSeq: 2, payload: .rowHash("h2"), pullIssue: 3))
    }

    func testResetDropsEverything() {
        var set = PendingVerifySet()
        set.insert(x, sentSeq: 0, payload: .rowHash("h1"), pullIssue: 1)
        set.insert(SyncBaselineKey(table: "user_settings", id: uid), sentSeq: 0, payload: .settingsKeys([:]), pullIssue: 1)
        set.reset()
        XCTAssertTrue(set.isEmpty)
    }

    func testMixedEligibilityInOneResolve() {
        var set = PendingVerifySet()
        let base = Baseline()
        let y = SyncBaselineKey(table: "calendar_events", id: "Y")
        base.seq[x] = 0
        base.seq[y] = 0
        set.insert(x, sentSeq: 0, payload: .rowHash("hx"), pullIssue: 4)   // eligible
        set.insert(y, sentSeq: 0, payload: .rowHash("hy"), pullIssue: 5)   // not yet

        let cleared = base.resolve(&set, seen: [], pullIssue: 5)

        XCTAssertEqual(cleared, [x])
        XCTAssertTrue(set.contains(y))
        XCTAssertEqual(base.hash[x], "hx")
        XCTAssertNil(base.hash[y])
    }
}
