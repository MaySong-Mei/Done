//
//  CalendarPageTypes.swift
//  Done
//
//  Shared state and enums for CalendarPage composition.
//

enum PageMode {
    case preview
    case edit
}

enum RangeMode {
    case day
    case threeDay
    case week
}

enum HeaderVisibility: Equatable {
    case visible
    case hidden
}

struct CalendarPageState: Equatable {
    var pageMode: PageMode
    var headerVisibility: HeaderVisibility
    var pullToggleReady: Bool

    static var initial: CalendarPageState {
        CalendarPageState(pageMode: .preview, headerVisibility: .visible, pullToggleReady: true)
    }
}
