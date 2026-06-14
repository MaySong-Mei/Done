//
//  CalendarViewState.swift
//  Done
//
//  Shared calendar view state that persists across tabs/mode switches.
//

import Combine
import SwiftUI

let calendarTimelineHourHeightDefault: CGFloat = 56
/// Absolute safety floor for timeline hour height.  The live pinch min is
/// usually larger than this — see `calendarPinchEffectiveMinHourHeight`,
/// which returns ~60% of the "whole day fits viewport" point so the user
/// can compress past exact fit but not so far the timeline becomes
/// unreadable.
let calendarTimelineHourHeightMin: CGFloat = 12
let calendarTimelineHourHeightMax: CGFloat = 96

/// 功能：Stores the currently observed date/range for the calendar UI.
final class CalendarViewState: ObservableObject {
    @Published var selectedDayOffset: Int = 0
    @Published var rangeMode: RangeMode = .day {
        didSet { persistRangeMode() }
    }
    @Published private(set) var timelineHourHeight: CGFloat

    /// When true, scroll-driven updates to selectedDayOffset are suppressed (e.g. during orientation change).
    @Published var isDayOffsetFrozen: Bool = false

    private let defaults: UserDefaults
    private let timelineHourHeightKey = "calendar.timeline.hourHeight"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let persisted = defaults.object(forKey: timelineHourHeightKey) as? Double
        let initialValue = CGFloat(persisted ?? Double(calendarTimelineHourHeightDefault))
        self.timelineHourHeight = Self.clampTimelineHourHeight(initialValue)

        // Restore persisted range mode (only when the setting is enabled)
        if defaults.bool(forKey: AppSettingsKeys.calendarRememberViewMode),
           let raw = defaults.string(forKey: AppSettingsKeys.calendarLastRangeMode) {
            switch raw {
            case "day": rangeMode = .day
            case "threeDay": rangeMode = .threeDay
            case "week": rangeMode = .week
            case "stream": rangeMode = .stream
            default: break
            }
        }
    }

    func persistRangeMode() {
        let raw: String
        switch rangeMode {
        case .day: raw = "day"
        case .threeDay: raw = "threeDay"
        case .week: raw = "week"
        case .month: raw = "month"
        case .stream: raw = "stream"
        }
        defaults.set(raw, forKey: AppSettingsKeys.calendarLastRangeMode)
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
