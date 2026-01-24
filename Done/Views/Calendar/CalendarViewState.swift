//
//  CalendarViewState.swift
//  Done
//
//  Shared calendar view state that persists across tabs/mode switches.
//

import Combine
import SwiftUI

/// 功能：Stores the currently observed date/range for the calendar UI.
final class CalendarViewState: ObservableObject {
    @Published var selectedDayOffset: Int = 0
    @Published var rangeMode: RangeMode = .day
}
