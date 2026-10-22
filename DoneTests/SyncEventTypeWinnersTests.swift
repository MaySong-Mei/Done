//
//  SyncEventTypeWinnersTests.swift
//  DoneTests
//
//  The event_types namesake rule (design §6 event_types 段; newest
//  `updated_at` wins since gh#257). Test names carry the Lean theorem they
//  mirror (namespace `EventTypes`).
//

import XCTest
@testable import Done

@MainActor
final class SyncEventTypeWinnersTests: XCTestCase {

    private typealias N = SyncEventTypeWinners.Namesake

    // u3 < u7 < u9 in lowercase order; the uppercase spelling is
    // how the device keys rows.
    private let u3 = "33333333-AAAA-4000-8000-000000000003"
    private let u7 = "77777777-AAAA-4000-8000-000000000007"
    private let u9 = "99999999-AAAA-4000-8000-000000000009"

    private func resolve(_ local: [N], _ incoming: N, live: Bool = true) -> SyncEventTypeWinners.Resolution {
        SyncEventTypeWinners.resolve(localLive: local, incoming: incoming, incomingIsLive: live)
    }

    func testNoNamesakeAdmitsTheIncomingRow() {
        let r = resolve([N(id: u9, title: "Gym")], N(id: u7, title: "Work"))
        XCTAssertEqual(r.winnerId, u7)
        XCTAssertTrue(r.incomingEntersTable)
        XCTAssertTrue(r.removeLocally.isEmpty)
        XCTAssertTrue(r.tombstoneDirectly.isEmpty)
    }

    func testWinnerIdemOnOwnUuid() {
        let r = resolve([N(id: u7, title: "Work")], N(id: u7, title: "Work"))
        XCTAssertEqual(r.winnerId, u7)
        XCTAssertTrue(r.incomingEntersTable)
        XCTAssertTrue(r.removeLocally.isEmpty)
        XCTAssertTrue(r.tombstoneDirectly.isEmpty)
    }

    /// The holder of the loser takes the winner's row, drops its own, and
    /// leaves the loser's tombstone to the collection diff.
    func testLocalLoserIsReplacedByTheIncomingWinner() {
        let r = resolve([N(id: u7, title: "Work")], N(id: u3, title: "Work"))
        XCTAssertEqual(r.winnerId, u3)
        XCTAssertTrue(r.incomingEntersTable)
        XCTAssertEqual(r.removeLocally, [u7])
        XCTAssertTrue(r.tombstoneDirectly.isEmpty)
    }

    /// Lean `loser_never_in_base`: an incoming loser is not inserted, gets
    /// no baseline entry, and is tombstoned directly.
    func testLoserNeverInBase() {
        let r = resolve([N(id: u3, title: "Work")], N(id: u7, title: "Work"))
        XCTAssertEqual(r.winnerId, u3)
        XCTAssertFalse(r.incomingEntersTable, "the loser never reaches the table, so never the baseline")
        XCTAssertEqual(r.tombstoneDirectly, [u7])
        XCTAssertTrue(r.removeLocally.isEmpty)
    }

    /// Lean `both_holders_converge`: A holding 3 sees 7, B holding 7 sees 3
    /// — same winner, same loser.
    func testBothHoldersConverge() {
        let a = resolve([N(id: u3, title: "Work")], N(id: u7, title: "Work"))
        let b = resolve([N(id: u7, title: "Work")], N(id: u3, title: "Work"))
        XCTAssertEqual(a.winnerId, b.winnerId)
        XCTAssertEqual(Set(a.tombstoneDirectly + a.removeLocally), Set(b.tombstoneDirectly + b.removeLocally))
        // Fixed point: the winner's row re-applied tombstones nothing more.
        let again = resolve([N(id: u3, title: "Work")], N(id: u3, title: "Work"))
        XCTAssertTrue(again.tombstoneDirectly.isEmpty && again.removeLocally.isEmpty)
    }

    /// Lean `naive_dead_namesake_erases_live_type_witness`: A creates 3, B
    /// creates 7, A deletes 3. B pulls 3's TOMBSTONE and keeps 7.
    func testDeadNamesakeTakesNoPartInWinnerSelection() {
        let r = resolve([N(id: u7, title: "Work")], N(id: u3, title: "Work"), live: false)
        XCTAssertEqual(r.winnerId, u7, "B keeps its live 7")
        XCTAssertTrue(r.removeLocally.isEmpty)
        XCTAssertTrue(r.tombstoneDirectly.isEmpty, "the dead 3 tombstones nothing")
        XCTAssertTrue(r.incomingEntersTable, "the tombstone goes through the table, removing only its own id")

        // Control: the same 3 arriving LIVE does beat 7.
        let live = resolve([N(id: u7, title: "Work")], N(id: u3, title: "Work"))
        XCTAssertEqual(live.winnerId, u3)
        XCTAssertEqual(live.removeLocally, [u7])
    }

    func testTombstoneOfTheHeldTypeLeavesNoWinner() {
        let r = resolve([N(id: u3, title: "Work")], N(id: u3, title: "Work"), live: false)
        XCTAssertNil(r.winnerId)
        XCTAssertTrue(r.tombstoneDirectly.isEmpty)
    }

    /// Titles compare by `normalizedTitle`: case, diacritics, surrounding
    /// whitespace.
    func testNamesakesMatchByNormalizedTitle() {
        let r = resolve([N(id: u7, title: "  Café ")], N(id: u3, title: "cafe"))
        XCTAssertEqual(r.winnerId, u3)
        XCTAssertEqual(r.removeLocally, [u7])
    }

    /// The winner is the smallest LOWERCASE string, whatever spelling the
    /// ids arrive in, and the same id in two spellings is one id.
    func testWinnerOrderIsOnLowercaseUuidStrings() {
        let upperB = "BBBBBBBB-0000-4000-8000-000000000000"
        let lowerA = "aaaaaaaa-0000-4000-8000-000000000000"
        let r = resolve([N(id: upperB, title: "X")], N(id: lowerA, title: "X"))
        XCTAssertEqual(r.winnerId, lowerA, "a < b once lowercased (uppercase B would sort first raw)")

        let sameId = resolve([N(id: u7, title: "X")], N(id: u7.lowercased(), title: "X"))
        XCTAssertTrue(sameId.removeLocally.isEmpty)
        XCTAssertTrue(sameId.tombstoneDirectly.isEmpty)
    }

    /// Three holders: the winner does not depend on discovery order.
    func testWinnerAssocAcrossThreeNamesakes() {
        let r1 = resolve([N(id: u9, title: "W"), N(id: u7, title: "W")], N(id: u3, title: "W"))
        XCTAssertEqual(r1.winnerId, u3)
        XCTAssertEqual(Set(r1.removeLocally), [u7, u9])
        let r2 = resolve([N(id: u3, title: "W"), N(id: u9, title: "W")], N(id: u7, title: "W"))
        XCTAssertEqual(r2.winnerId, u3)
        XCTAssertEqual(r2.tombstoneDirectly, [u7])
        XCTAssertEqual(r2.removeLocally, [u9])
    }

    // MARK: - gh#257: the newest namesake wins

    /// Postgres `to_jsonb(timestamptz)` spelling, parsed the way the applier
    /// parses a page row.
    private static func ts(_ s: String) -> Date {
        guard let d = SupabaseSyncService.rowUpdatedAt(["updated_at": s]) else {
            fatalError("unparseable fixture timestamp \(s)")
        }
        return d
    }

    /// The production account of gh#257 (2026-10-21), four of its titles:
    /// the app's defaults uploaded twice on 05-18 (00:37 and 00:47) and the
    /// user's customised rows later. The DEFAULT rows hold the smaller UUIDs
    /// ("0…"/"1…" against "f…"), as they did for Sleep and Work in
    /// production, so smallest-UUID-only picks a default for every title.
    private struct ProdRow { let id: String; let title: String; let color: String; let at: String }
    private static let prod: [ProdRow] = [
        ProdRow(id: "0a000000-0000-4000-8000-000000000001", title: "Sleep", color: "#AF52DE", at: "2026-05-18T00:37:05.123456+00:00"),
        ProdRow(id: "1a000000-0000-4000-8000-000000000001", title: "Sleep", color: "#AF52DE", at: "2026-05-18T00:47:05.123456+00:00"),
        ProdRow(id: "FA000000-0000-4000-8000-000000000001", title: "Sleep", color: "#FFC8C7", at: "2026-05-22T09:12:44.5+00:00"),
        ProdRow(id: "0b000000-0000-4000-8000-000000000002", title: "Work", color: "#0A84FF", at: "2026-05-18T00:37:05.223456+00:00"),
        ProdRow(id: "1b000000-0000-4000-8000-000000000002", title: "Work", color: "#0A84FF", at: "2026-05-18T00:47:05.223456+00:00"),
        ProdRow(id: "fb000000-0000-4000-8000-000000000002", title: "Work", color: "#037E00", at: "2026-06-02T18:03:10.000001+00:00"),
        ProdRow(id: "0c000000-0000-4000-8000-000000000003", title: "Study", color: "#34C759", at: "2026-05-18T00:37:05.323456+00:00"),
        ProdRow(id: "1c000000-0000-4000-8000-000000000003", title: "Study", color: "#34C759", at: "2026-05-18T00:47:05.323456+00:00"),
        ProdRow(id: "fc000000-0000-4000-8000-000000000003", title: "Study", color: "#48FB00", at: "2026-06-02T18:03:11+00:00"),
        ProdRow(id: "0d000000-0000-4000-8000-000000000004", title: "Exercise", color: "#FFD60A", at: "2026-05-18T00:37:05.423456+00:00"),
        ProdRow(id: "1d000000-0000-4000-8000-000000000004", title: "Exercise", color: "#FFD60A", at: "2026-05-18T00:47:05.423456+00:00"),
    ]

    private func prodNamesakes() -> [N] {
        Self.prod.map { N(id: $0.id, title: $0.title, updatedAt: Self.ts($0.at)) }
    }

    private func color(of id: String?) -> String? {
        Self.prod.first { SyncEventTypeWinners.sameId($0.id, id ?? "") }?.color
    }

    /// (a) Every row of the page arriving as the incoming row against all
    /// the others — the shape `SyncApplier` hands the resolver on a first
    /// pull — picks the user's colours, never the 05-18 defaults.
    func testGH257ProductionAccountKeepsTheUsersCustomisedColours() {
        let all = prodNamesakes()
        let expected = ["Sleep": "#FFC8C7", "Work": "#037E00", "Study": "#48FB00", "Exercise": "#FFD60A"]
        // Fixture guard: smallest-UUID-only really would pick a default here.
        for title in ["Sleep", "Work", "Study"] {
            let smallest = all.filter { $0.title == title }.map(\.id).min { $0.lowercased() < $1.lowercased() }
            XCTAssertNotEqual(color(of: smallest), expected[title], "fixture: the default must hold the smaller UUID for \(title)")
        }
        for incoming in all {
            let others = all.filter { !SyncEventTypeWinners.sameId($0.id, incoming.id) }
            let r = resolve(others, incoming)
            XCTAssertEqual(color(of: r.winnerId), expected[incoming.title], "incoming \(incoming.id) (\(incoming.title))")
            let losers = Set(r.removeLocally + r.tombstoneDirectly)
            XCTAssertFalse(losers.contains { SyncEventTypeWinners.sameId($0, r.winnerId ?? "") }, "the winner is never a loser")
        }
        // Exercise has only the two defaults: the later upload (00:47) wins.
        let exercise = resolve(all.filter { $0.title == "Exercise" && $0.id.hasPrefix("0d") }, all.first { $0.id.hasPrefix("1d") }!)
        XCTAssertEqual(exercise.winnerId, "1d000000-0000-4000-8000-000000000004")
        XCTAssertEqual(exercise.removeLocally, ["0d000000-0000-4000-8000-000000000004"])
        XCTAssertTrue(exercise.incomingEntersTable)
        // The customised Sleep held locally, a default arriving: the default
        // is tombstoned directly and never enters the table.
        let sleepPink = all.first { $0.id.hasPrefix("FA") }!
        let staleDefault = all.first { $0.id.hasPrefix("0a") }!
        let held = resolve([sleepPink], staleDefault)
        XCTAssertEqual(held.winnerId, sleepPink.id)
        XCTAssertFalse(held.incomingEntersTable)
        XCTAssertEqual(held.tombstoneDirectly, [staleDefault.id])
        XCTAssertTrue(held.removeLocally.isEmpty)
    }

    /// (b) Equal `updated_at` → the smallest lowercase UUID, whichever side
    /// is incoming.
    func testEqualUpdatedAtFallsBackToTheSmallestUuid() {
        let t = Self.ts("2026-05-18T00:37:05.123456+00:00")
        let a = N(id: u9, title: "Sleep", updatedAt: t)
        let b = N(id: u3, title: "Sleep", updatedAt: t)
        XCTAssertEqual(resolve([a], b).winnerId, u3)
        XCTAssertEqual(resolve([b], a).winnerId, u3)
        XCTAssertEqual(resolve([b], a).tombstoneDirectly, [u9])
        // Control: one millisecond newer on the larger UUID flips it.
        let newer = N(id: u9, title: "Sleep", updatedAt: t.addingTimeInterval(0.001))
        XCTAssertEqual(resolve([b], newer).winnerId, u9)
    }

    /// A title with ANY undated candidate (a local row the page does not
    /// carry) is decided by the smallest UUID alone — Lean
    /// `holders_views_agree`: A holds its own a (undated to A) and pulls b
    /// (dated), B holds b (undated to B) and pulls a (dated); both must
    /// pick the same row or the type dies on both.
    func testAnUndatedCandidateMakesTheWholeTitleFallBackToTheSmallestUuid() {
        let early = Self.ts("2026-05-18T00:37:05+00:00")
        let late = Self.ts("2026-06-02T18:03:11+00:00")
        // a = u3 written early, b = u9 written late.
        let atA = resolve([N(id: u3, title: "W")], N(id: u9, title: "W", updatedAt: late))
        let atB = resolve([N(id: u9, title: "W")], N(id: u3, title: "W", updatedAt: early))
        XCTAssertEqual(atA.winnerId, u3)
        XCTAssertEqual(atB.winnerId, u3, "both holders agree")
        XCTAssertEqual(Set(atA.removeLocally + atA.tombstoneDirectly), [u9])
        XCTAssertEqual(Set(atB.removeLocally + atB.tombstoneDirectly), [u9])
        // Control: both dated (a third device's first pull) → the newest.
        let atC = resolve([N(id: u3, title: "W", updatedAt: early)], N(id: u9, title: "W", updatedAt: late))
        XCTAssertEqual(atC.winnerId, u9)
    }

    /// (c) A tombstone never wins and takes no part, however new it is.
    func testANewestTombstoneNeverWinsAndTakesNoPart() {
        let all = prodNamesakes().filter { $0.title == "Sleep" }
        let pink = all.first { $0.id.hasPrefix("FA") }!
        let defaults = all.filter { !$0.id.hasPrefix("FA") }
        let deadPink = resolve(defaults, pink, live: false)
        XCTAssertEqual(deadPink.winnerId, "1a000000-0000-4000-8000-000000000001", "the newest LIVE row is left: the 00:47 default")
        XCTAssertTrue(deadPink.removeLocally.isEmpty)
        XCTAssertTrue(deadPink.tombstoneDirectly.isEmpty)
        XCTAssertTrue(deadPink.incomingEntersTable)
        // A tombstone of an older row leaves the newest live row the winner
        // and tombstones nothing.
        let deadDefault = resolve([pink] + defaults.dropFirst(), defaults[0], live: false)
        XCTAssertEqual(deadDefault.winnerId, pink.id)
        XCTAssertTrue(deadDefault.removeLocally.isEmpty && deadDefault.tombstoneDirectly.isEmpty)
    }

    /// (d) Determinism: every order of the same rows, with every row as the
    /// incoming one, gives the same winner.
    func testWinnerIsIndependentOfInputOrder() {
        let sleep = prodNamesakes().filter { $0.title == "Sleep" }
        let orders = [sleep, Array(sleep.reversed()), [sleep[1], sleep[2], sleep[0]], [sleep[2], sleep[0], sleep[1]]]
        var winners = Set<String>()
        for order in orders {
            winners.insert(SyncEventTypeWinners.winner(order)?.id ?? "nil")
            for incoming in order {
                let others = order.filter { $0.id != incoming.id }
                winners.insert(resolve(others, incoming).winnerId ?? "nil")
                winners.insert(resolve(Array(others.reversed()), incoming).winnerId ?? "nil")
            }
        }
        XCTAssertEqual(winners, ["FA000000-0000-4000-8000-000000000001"])
    }
}
