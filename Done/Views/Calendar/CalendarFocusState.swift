//
//  CalendarFocusState.swift
//  Done
//
//  Focus-state slice carved out of `CalendarViewState` (see issue #51).
//

import Combine
import SwiftUI

/// Holds the small set of calendar state read by the root view tree
/// (tab-bar slide animation). Split out of `CalendarViewState` so the
/// high-frequency state (selectedDayOffset etc.) can be owned via plain
/// `@State` at ContentView, leaving its body untouched by auto-scroll
/// bursts — see issue #51.
final class CalendarFocusState: ObservableObject {
    @Published var isEventFocused: Bool = false
}
