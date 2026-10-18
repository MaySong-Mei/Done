//
//  SyncScheduler.swift
//  Done
//
//  The clock the outbound debounce runs on, as a seam (survey M6(4)). The
//  app hands in `RunLoopSyncScheduler`, which fires on the main run loop in
//  its default mode — the same place `.debounce(for:scheduler: RunLoop.main)`
//  fired, so the production timing is unchanged. Tests hand in a manual
//  scheduler whose time only moves when the test advances it, so a seeded
//  run decides every flush and the same seed gives the same request log.
//

import Combine
import Foundation

/// A piece of scheduled work that can be called off before it fires.
protocol SyncScheduledWork: AnyObject {
    func cancel()
}

/// Time and delayed work for the sync engine. Main-actor: every caller is.
protocol SyncScheduler: AnyObject {
    /// The scheduler's current time.
    func now() -> Date
    /// Run `work` once, `delay` seconds from `now()`, unless cancelled first.
    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> SyncScheduledWork
}

/// Production: a one-shot `Timer` on the main run loop in `.default` mode,
/// which is how Combine's `RunLoop` scheduler arms a delayed action.
final class RunLoopSyncScheduler: SyncScheduler {
    private final class TimerWork: SyncScheduledWork {
        private var timer: Timer?
        init(_ timer: Timer) { self.timer = timer }
        func cancel() {
            timer?.invalidate()
            timer = nil
        }
    }

    func now() -> Date { Date() }

    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> SyncScheduledWork {
        let timer = Timer(fire: Date().addingTimeInterval(delay), interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
        RunLoop.main.add(timer, forMode: .default)
        return TimerWork(timer)
    }
}

/// Trailing-edge debounce on a `SyncScheduler`: every value re-arms the
/// delay, and only the latest value is delivered once the input has been
/// quiet for the whole delay — `Publishers.Debounce`'s contract.
final class SyncDebouncer<Value> {
    private let delay: TimeInterval
    private let scheduler: SyncScheduler
    private let deliver: (Value) -> Void
    private var pending: SyncScheduledWork?

    init(delay: TimeInterval, scheduler: SyncScheduler, deliver: @escaping (Value) -> Void) {
        self.delay = delay
        self.scheduler = scheduler
        self.deliver = deliver
    }

    var isPending: Bool { pending != nil }

    func submit(_ value: Value) {
        pending?.cancel()
        pending = scheduler.schedule(after: delay) { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.deliver(value)
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// Main-thread-only flag shared by a debounce sink's two halves.
private final class SyncDebounceSinkState {
    var cancelled = false
}

extension Publisher where Failure == Never {
    /// `.debounce(for: delay, scheduler:)` followed by `.sink`, on a
    /// `SyncScheduler`. A value published off the main thread (a
    /// `UserDefaults.didChangeNotification` from a background write) hops to
    /// main before it re-arms the delay, as the run-loop debounce delivered
    /// it there. Cancelling the result also cancels a pending delivery, and
    /// a value still on its way to main when the cancel lands is dropped
    /// there: like `Publishers.Debounce`, nothing is delivered after cancel.
    func syncDebounceSink(
        for delay: TimeInterval,
        on scheduler: SyncScheduler,
        receiveValue: @escaping (Output) -> Void
    ) -> AnyCancellable {
        let debouncer = SyncDebouncer(delay: delay, scheduler: scheduler, deliver: receiveValue)
        let state = SyncDebounceSinkState()
        let upstream = sink { @Sendable value in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    if !state.cancelled { debouncer.submit(value) }
                }
            } else {
                DispatchQueue.main.async {
                    if !state.cancelled { debouncer.submit(value) }
                }
            }
        }
        return AnyCancellable {
            upstream.cancel()
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    state.cancelled = true
                    debouncer.cancel()
                }
            } else {
                // Queued behind any value already hopping to main, so the
                // cancel below also undoes what that value arms.
                DispatchQueue.main.async {
                    state.cancelled = true
                    debouncer.cancel()
                }
            }
        }
    }
}
