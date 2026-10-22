//
//  SyncManualScheduler.swift
//  DoneTests
//
//  A `SyncScheduler` whose time moves only when the test says so (survey
//  M6(4)). Work fires inside `advance(by:)`, in due-time order, ties in the
//  order it was scheduled, so a test — or a seeded run — decides exactly
//  which debounced flushes have happened.
//

import Foundation
@testable import Done

@MainActor
final class SyncManualScheduler: SyncScheduler {
    private final class Work: SyncScheduledWork {
        let due: Date
        let order: Int
        let action: @MainActor () -> Void
        var cancelled = false
        init(due: Date, order: Int, action: @escaping @MainActor () -> Void) {
            self.due = due
            self.order = order
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    private var current: Date
    private var queue: [Work] = []
    private var nextOrder = 0
    private(set) var firedCount = 0

    init(start: Date = Date(timeIntervalSince1970: 1_780_000_000)) {
        self.current = start
    }

    func now() -> Date { current }

    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> SyncScheduledWork {
        let item = Work(due: current.addingTimeInterval(max(0, delay)), order: nextOrder, action: work)
        nextOrder += 1
        queue.append(item)
        return item
    }

    /// Work that is scheduled and not cancelled.
    var pendingCount: Int { queue.filter { !$0.cancelled }.count }

    /// Move time forward, firing everything that falls due on the way.
    /// Work scheduled by fired work is fired too if it falls due in range.
    func advance(by interval: TimeInterval) {
        let target = current.addingTimeInterval(interval)
        while let next = queue
            .filter({ !$0.cancelled && $0.due <= target })
            .min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            queue.removeAll { $0 === next }
            current = next.due
            firedCount += 1
            next.action()
        }
        queue.removeAll { $0.cancelled }
        current = target
    }
}
