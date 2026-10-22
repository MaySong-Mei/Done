//
//  SyncSchedulerTests.swift
//  DoneTests
//
//  The outbound debounce on an injectable clock (survey M6(4)): the manual
//  scheduler decides exactly when a debounced flush fires, and the debounce
//  keeps `Publishers.Debounce`'s contract — latest value, after the input
//  has been quiet for the whole delay.
//

import Combine
import XCTest
@testable import Done

@MainActor
final class SyncSchedulerTests: XCTestCase {

    func testManualSchedulerFiresOnlyWhenTimeReachesTheDueTime() {
        let clock = SyncManualScheduler()
        let t0 = clock.now()
        var fired: [String] = []
        clock.schedule(after: 2) { fired.append("b") }
        clock.schedule(after: 1) { fired.append("a") }
        clock.schedule(after: 2) { fired.append("c") }

        clock.advance(by: 0.999)
        XCTAssertEqual(fired, [])
        clock.advance(by: 0.001)
        XCTAssertEqual(fired, ["a"])
        clock.advance(by: 5)
        XCTAssertEqual(fired, ["a", "b", "c"], "due-time order, ties in scheduling order")
        XCTAssertEqual(clock.now(), t0.addingTimeInterval(6))
    }

    func testCancelledWorkNeverFires() {
        let clock = SyncManualScheduler()
        var fired = false
        let work = clock.schedule(after: 1) { fired = true }
        work.cancel()
        clock.advance(by: 10)
        XCTAssertFalse(fired)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testDebounceDeliversOnlyTheLatestValueOnceTheInputIsQuietForTheWholeDelay() {
        let clock = SyncManualScheduler()
        let subject = PassthroughSubject<Int, Never>()
        var delivered: [Int] = []
        let cancellable = subject.syncDebounceSink(for: 2, on: clock) { delivered.append($0) }
        defer { cancellable.cancel() }

        subject.send(1)
        clock.advance(by: 1.5)
        subject.send(2)            // re-arms: quiet period restarts
        clock.advance(by: 1.5)
        XCTAssertEqual(delivered, [], "the second value restarted the delay")
        clock.advance(by: 0.5)
        XCTAssertEqual(delivered, [2])

        subject.send(3)
        clock.advance(by: 2)
        XCTAssertEqual(delivered, [2, 3])
        clock.advance(by: 60)
        XCTAssertEqual(delivered, [2, 3], "nothing fires twice")
    }

    /// Positive control: without the debounce the same burst is delivered
    /// value by value, so the collapse above is the debounce's doing.
    func testTheSameBurstUndebouncedIsEveryValue() {
        let subject = PassthroughSubject<Int, Never>()
        var delivered: [Int] = []
        let cancellable = subject.sink { delivered.append($0) }
        defer { cancellable.cancel() }
        subject.send(1); subject.send(2); subject.send(3)
        XCTAssertEqual(delivered, [1, 2, 3])
    }

    func testCancellingTheSubscriptionCancelsAPendingDelivery() {
        let clock = SyncManualScheduler()
        let subject = PassthroughSubject<Int, Never>()
        var delivered: [Int] = []
        let cancellable = subject.syncDebounceSink(for: 2, on: clock) { delivered.append($0) }
        subject.send(1)
        XCTAssertEqual(clock.pendingCount, 1)

        cancellable.cancel()
        clock.advance(by: 5)

        XCTAssertEqual(delivered, [])
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testAValuePublishedOffMainArmsTheDelayOnMain() async throws {
        let clock = SyncManualScheduler()
        let subject = PassthroughSubject<Int, Never>()
        var delivered: [Int] = []
        let cancellable = subject.syncDebounceSink(for: 2, on: clock) { value in
            XCTAssertTrue(Thread.isMainThread)
            delivered.append(value)
        }
        defer { cancellable.cancel() }

        await Task.detached { subject.send(7) }.value
        try await syncEventually("off-main value armed the delay") { clock.pendingCount == 1 }
        clock.advance(by: 2)

        XCTAssertEqual(delivered, [7])
    }

    /// A value published off main is still on its way to main when the
    /// subscription is cancelled there; it must not arm a delivery after the
    /// cancel (`Publishers.Debounce` never delivers after cancel).
    func testAValueStillHoppingToMainWhenTheSinkIsCancelledIsNeverDelivered_killsSubmitAfterCancel() {
        let clock = SyncManualScheduler()
        let subject = PassthroughSubject<Int, Never>()
        var delivered: [Int] = []
        let cancellable = subject.syncDebounceSink(for: 2, on: clock) { delivered.append($0) }

        // Publish from another thread while main is blocked, so the hop to
        // main is queued and has not run when the cancel below happens.
        let sent = DispatchSemaphore(value: 0)
        let publisher = Thread {
            subject.send(7)
            sent.signal()
        }
        publisher.qualityOfService = .userInteractive
        publisher.start()
        sent.wait()
        cancellable.cancel()

        // Let the queued hop run.
        var drained = false
        DispatchQueue.main.async { drained = true }
        let deadline = Date().addingTimeInterval(2)
        while !drained, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(drained)
        clock.advance(by: 5)

        XCTAssertEqual(delivered, [])
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testRunLoopSchedulerFiresOnMainAndHonoursCancel() async throws {
        let live = RunLoopSyncScheduler()
        var fired = false
        var cancelledFired = false
        let cancelled = live.schedule(after: 0.01) { cancelledFired = true }
        cancelled.cancel()
        live.schedule(after: 0.02) {
            XCTAssertTrue(Thread.isMainThread)
            fired = true
        }
        try await syncEventually("live timer fired") { fired }
        XCTAssertFalse(cancelledFired)
    }

    func testServiceKeepsTheInjectedScheduler() throws {
        let suite = "SyncSchedulerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = SyncManualScheduler()

        let injected = SupabaseSyncService(gateway: SyncFakeServer(userId: "u"), userId: "u", defaults: defaults, scheduler: clock)
        XCTAssertTrue(injected.scheduler === clock)
        let standalone = SupabaseSyncService(gateway: SyncFakeServer(userId: "u"), userId: "u", defaults: defaults)
        XCTAssertTrue(standalone.scheduler is RunLoopSyncScheduler, "production default")
    }
}
