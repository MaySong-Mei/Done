//
//  TimelineGestureTypes.swift
//  Done
//
//  Shared gesture state/config for calendar timeline interactions.
//

import SwiftUI
import Combine

/// Configuration for timeline gesture behavior (snap, thresholds, auto-scroll).
struct TimelineGestureConfig {
    var snapMinutes: Int = 15
    var minDurationMinutes: Int = 15
    var longPressDuration: TimeInterval = 0.35
    var autoScrollEdgePadding: CGFloat = 36
    var autoScrollInterval: TimeInterval = 0.2
    var autoScrollStepDays: Int = 1
}

struct TimelinePickupState {
    let eventID: UUID
    let originalRange: Event.TimeRange
    let grabOffsetMinutes: Int
    var currentRange: Event.TimeRange
    var currentDayOffset: Int
}

struct TimelineDraftState {
    var dayOffset: Int
    var start: Date
    var end: Date
}

struct TimelineInteractionState {
    var pickup: TimelinePickupState?
    var draft: TimelineDraftState?

    var isActive: Bool {
        pickup != nil || draft != nil
    }
}

@MainActor
final class TimelineAutoScrollController: ObservableObject {
    private var task: Task<Void, Never>?
    private var direction: Int = 0

    func start(direction: Int, interval: TimeInterval, step: Int, action: @escaping (Int) -> Void) {
        guard direction != 0 else {
            stop()
            return
        }
        if self.direction == direction, task != nil {
            return
        }
        stop()
        self.direction = direction

        let delay = UInt64(max(0.05, interval) * 1_000_000_000)
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                action(step * direction)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        direction = 0
    }
}
