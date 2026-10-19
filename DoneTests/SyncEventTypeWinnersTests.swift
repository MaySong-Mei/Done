//
//  SyncEventTypeWinnersTests.swift
//  DoneTests
//
//  The event_types namesake rule (design §6 event_types 段). Test names
//  carry the Lean theorem they mirror (namespace `EventTypes`).
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
}
