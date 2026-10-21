//
//  SyncHeadGateTests.swift
//  DoneTests
//
//  The domino's head gate (design §6 domino 段, §10.5): with no engine the
//  push runs as it always did; with one it waits for the pull chain to end
//  at head, pulling first when the engine offers a hook.
//

import XCTest
@testable import Done

@MainActor
final class SyncHeadGateTests: XCTestCase {

    private final class Ran {
        var labels: [String] = []
    }

    private func request(_ gate: SyncHeadFlag, _ label: String, _ ran: Ran) {
        gate.runWhenAtHead { ran.labels.append(label) }
    }

    func testWithNoEngineTheWorkRunsAtOnce() {
        let gate = SyncHeadFlag()
        let ran = Ran()

        request(gate, "tick", ran)

        XCTAssertEqual(ran.labels, ["tick"], "the pre-sync app: signed out or the feed unavailable")
    }

    func testWithAnEngineNotAtHeadTheWorkWaitsForTheChainToEndAtHead_killsGateIgnoresEngine() {
        let gate = SyncHeadFlag()
        gate.engineRunning = true
        let ran = Ran()

        request(gate, "foreground", ran)
        XCTAssertEqual(ran.labels, [], "not at head: a push now would conflict with every row the pull is about to bring")

        gate.chainEnded(atHead: false)
        XCTAssertEqual(ran.labels, [], "a long page: still not at head")

        gate.chainEnded(atHead: true)
        XCTAssertEqual(ran.labels, ["foreground"])

        gate.chainEnded(atHead: true)
        XCTAssertEqual(ran.labels, ["foreground"], "runs once per request")
    }

    func testWithAnEngineAtHeadAndNoPullHookTheWorkRunsAtOnce() {
        let gate = SyncHeadFlag()
        gate.engineRunning = true
        gate.chainEnded(atHead: true)
        let ran = Ran()

        request(gate, "tick", ran)

        XCTAssertEqual(ran.labels, ["tick"])
    }

    func testWithAPullHookEveryRequestPullsFirstAndRunsWhenThatChainEndsAtHead() {
        let gate = SyncHeadFlag()
        gate.engineRunning = true
        gate.chainEnded(atHead: true)
        var pulls = 0
        gate.pullNow = { pulls += 1 }
        let ran = Ran()

        request(gate, "tick", ran)
        XCTAssertEqual(pulls, 1, "每次 tick 前先拉")
        XCTAssertEqual(ran.labels, [], "even at head: the tick's own pull comes first")

        gate.chainEnded(atHead: true)
        XCTAssertEqual(ran.labels, ["tick"])

        request(gate, "next", ran)
        XCTAssertEqual(pulls, 2)
        gate.chainEnded(atHead: false)
        XCTAssertEqual(ran.labels, ["tick"], "the chain stopped short of head: the push waits")
        gate.chainEnded(atHead: true)
        XCTAssertEqual(ran.labels, ["tick", "next"])
    }

    func testOnlyTheLatestRequestIsKeptWhileWaiting() {
        let gate = SyncHeadFlag()
        gate.engineRunning = true
        let ran = Ran()

        request(gate, "first", ran)
        request(gate, "second", ran)
        gate.chainEnded(atHead: true)

        XCTAssertEqual(ran.labels, ["second"], "one catch-up push covers every tick that queued behind the same pull")
    }

    func testStoppingTheEngineReleasesWaitingWorkAndForgetsHead() {
        let gate = SyncHeadFlag()
        gate.engineRunning = true
        gate.chainEnded(atHead: true)
        gate.pullNow = {}
        let ran = Ran()
        request(gate, "tick", ran)
        XCTAssertEqual(ran.labels, [])

        gate.engineRunning = false

        XCTAssertEqual(ran.labels, ["tick"], "no engine: the domino behaves as it always did")
        XCTAssertFalse(gate.isAtHead)
        request(gate, "after", ran)
        XCTAssertEqual(ran.labels, ["tick", "after"])
    }
}
