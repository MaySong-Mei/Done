//
//  CalendarViewState.swift
//  Done
//
//  Shared calendar view state that persists across tabs/mode switches.
//

import Combine
import SwiftUI

let calendarTimelineHourHeightDefault: CGFloat = 56
let calendarTimelineHourHeightMin: CGFloat = 34
let calendarTimelineHourHeightMax: CGFloat = 96

/// 功能：Stores the currently observed date/range for the calendar UI.
final class CalendarViewState: ObservableObject {
    @Published var selectedDayOffset: Int = 0
    @Published var rangeMode: RangeMode = .day
    @Published private(set) var timelineHourHeight: CGFloat
    @Published var isEventFocused: Bool = false

    /// When true, scroll-driven updates to selectedDayOffset are suppressed (e.g. during orientation change).
    @Published var isDayOffsetFrozen: Bool = false

    private let defaults: UserDefaults
    private let timelineHourHeightKey = "calendar.timeline.hourHeight"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let persisted = defaults.object(forKey: timelineHourHeightKey) as? Double
        let initialValue = CGFloat(persisted ?? Double(calendarTimelineHourHeightDefault))
        self.timelineHourHeight = Self.clampTimelineHourHeight(initialValue)
    }

    func setTimelineHourHeight(_ value: CGFloat) {
        let clamped = Self.clampTimelineHourHeight(value)
        guard abs(clamped - timelineHourHeight) > 0.0001 else { return }
        timelineHourHeight = clamped
    }

    func commitTimelineHourHeight() {
        defaults.set(Double(timelineHourHeight), forKey: timelineHourHeightKey)
    }

    private static func clampTimelineHourHeight(_ value: CGFloat) -> CGFloat {
        min(max(value, calendarTimelineHourHeightMin), calendarTimelineHourHeightMax)
    }
}
