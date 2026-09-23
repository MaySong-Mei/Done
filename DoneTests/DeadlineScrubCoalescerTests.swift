//
//  DeadlineScrubCoalescerTests.swift
//  DoneTests
//
//  gh#219 — the commit-on-release contract for the todo deadline wheel.
//
//  The window is set effectively infinite and `flush()` is driven directly, so
//  the collapse is proven without leaning on wall-clock timing (the same reason
//  the effort scrubber's decision is a pure function tested in isolation). The
//  load-bearing mutation: revert `scrub` to persist per detent → the
//  "no write per detent" assertion below counts M writes and dies.
//

import XCTest
@testable import Done

@MainActor
final class DeadlineScrubCoalescerTests: XCTestCase {
    /// A window long enough that the trailing timer never fires during a test,
    /// so every commit observed is one `flush()` explicitly asked for.
    private func makeCoalescer() -> DeadlineScrubCoalescer {
        DeadlineScrubCoalescer(window: .seconds(3600))
    }

    func testManyDetentsProduceExactlyOneDurableCommitOnRelease() {
        let coalescer = makeCoalescer()
        let id = UUID()
        var commits: [(id: UUID, value: Date)] = []

        for i in 0..<12 {
            coalescer.scrub(id: id, to: Date(timeIntervalSince1970: Double(i))) { cid, value in
                commits.append((cid, value))
            }
        }

        XCTAssertEqual(commits.count, 0,
                       "no durable write happens per detent — this is the whole point")
        XCTAssertEqual(coalescer.value(for: id), Date(timeIntervalSince1970: 11),
                       "the wheel reads back the in-flight value so it stays live")

        coalescer.flush()

        XCTAssertEqual(commits.count, 1, "release commits exactly once")
        XCTAssertEqual(commits.first?.value, Date(timeIntervalSince1970: 11),
                       "and it commits the final settled value, not an intermediate detent")
        XCTAssertFalse(coalescer.hasPending)
    }

    func testASecondGestureIsASecondCommit() {
        let coalescer = makeCoalescer()
        let id = UUID()
        var commits = 0

        coalescer.scrub(id: id, to: Date(timeIntervalSince1970: 1)) { _, _ in commits += 1 }
        coalescer.flush()
        coalescer.scrub(id: id, to: Date(timeIntervalSince1970: 2)) { _, _ in commits += 1 }
        coalescer.flush()

        XCTAssertEqual(commits, 2, "each settled gesture is its own durable write")
    }

    func testFlushWithNothingPendingIsANoOp() {
        let coalescer = makeCoalescer()
        var commits = 0
        coalescer.flush()
        coalescer.scrub(id: UUID(), to: Date()) { _, _ in commits += 1 }
        coalescer.flush()
        coalescer.flush()   // the timer firing after a disappear-flush must do nothing
        XCTAssertEqual(commits, 1, "a redundant flush is not a second write")
    }

    func testCancelDropsThePendingWithoutWriting() {
        let coalescer = makeCoalescer()
        var commits = 0
        coalescer.scrub(id: UUID(), to: Date()) { _, _ in commits += 1 }
        coalescer.cancel()
        coalescer.flush()
        XCTAssertEqual(commits, 0, "a superseding clear must not let the trailing write resurrect the value")
        XCTAssertFalse(coalescer.hasPending)
    }

    func testValueIsScopedToTheScrubbedRow() {
        let coalescer = makeCoalescer()
        let scrubbed = UUID()
        let other = UUID()
        coalescer.scrub(id: scrubbed, to: Date(timeIntervalSince1970: 5)) { _, _ in }
        XCTAssertEqual(coalescer.value(for: scrubbed), Date(timeIntervalSince1970: 5))
        XCTAssertNil(coalescer.value(for: other),
                     "another row's binding must fall through to the store, not read this scrub")
    }
}
