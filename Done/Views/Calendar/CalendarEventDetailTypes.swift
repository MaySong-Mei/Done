import Foundation
import CoreGraphics

struct CalendarEventOccurrenceContext: Hashable, Codable, Identifiable {
    enum Source: String, Codable, Hashable {
        case timelineTap
        case timelineLongPress
        case allDayTap
        case quickActionLog
        case quickActionRate
        case quickActionChat
        case detailToolbarChat
    }

    var eventID: UUID
    var occurrenceDate: Date
    var occurrenceID: String?
    var isAllDay: Bool
    var source: Source

    var occurrenceDayStart: Date {
        Calendar.current.startOfDay(for: occurrenceDate)
    }

    var id: String {
        let day = Int(occurrenceDayStart.timeIntervalSince1970)
        return "\(eventID.uuidString)-\(day)-\(source.rawValue)"
    }
}

enum CalendarEventDetailJumpTarget: String, Codable, Hashable {
    case meta
    case selfEval
    case log
}

struct CalendarEventDetailRoute: Hashable, Identifiable {
    var occurrence: CalendarEventOccurrenceContext
    var initialJumpTarget: CalendarEventDetailJumpTarget?
    var autoOpenComposer: Bool = false

    var id: String {
        let day = Int(Calendar.current.startOfDay(for: occurrence.occurrenceDate).timeIntervalSince1970)
        let target = initialJumpTarget?.rawValue ?? "none"
        return "\(occurrence.eventID.uuidString)-\(day)-\(target)-\(autoOpenComposer ? 1 : 0)"
    }
}

enum CalendarRecurringScopedAction: Hashable {
    case edit
    case delete
}

enum CalendarLongPressPhase: String, Hashable, Codable {
    case handlePreview
    case compactMenu
    case expandedMenu
}

struct CalendarLongPressPhaseState: Equatable, Identifiable {
    var eventID: UUID
    var occurrenceID: String?
    var phase: CalendarLongPressPhase
    var dragMode: EventDragMode
    var touchPointGlobal: CGPoint
    var eventSegmentFrameGlobal: CGRect
    var startedAt: Date
    var phase2TriggerAt: Date
    var phase3TriggerAt: Date

    var id: String {
        let occurrenceToken = occurrenceID ?? "nil"
        return "\(eventID.uuidString)-\(occurrenceToken)-\(phase.rawValue)-\(Int(startedAt.timeIntervalSince1970 * 1000))"
    }
}

enum CalendarResizeGraceTrigger: String, Hashable, Codable {
    case longPressRelease
    case quickMenuDismiss
    case moveCommit
    case resizeCommit
}

struct CalendarResizeGraceState: Equatable, Identifiable {
    var eventID: UUID
    var occurrenceID: String?
    var startedAt: Date
    var deadline: Date
    var fadeStartAt: Date
    var handleOpacity: Double
    var trigger: CalendarResizeGraceTrigger

    var id: String {
        let occurrenceToken = occurrenceID ?? "nil"
        return "\(eventID.uuidString)-\(occurrenceToken)-\(Int(startedAt.timeIntervalSince1970 * 1000))"
    }
}

enum CalendarQuickActionDismissReason: Hashable {
    case passiveDismiss
    case actionOpenDetail
    case actionChat
    case actionDelete
    case dragResume
    case programmatic
}

enum CalendarQuickActionMenuPresentation: Hashable {
    case compact
    case expanded
}

struct CalendarQuickActionMetaSummary: Equatable {
    var title: String
    var occurrenceTimeText: String
    var locationText: String?
    var recurrenceText: String?
}

struct CalendarQuickActionMenuState: Identifiable {
    let id = UUID()
    var occurrence: CalendarEventOccurrenceContext
    var touchPointGlobal: CGPoint
    var eventSegmentFrameGlobal: CGRect
    var presentation: CalendarQuickActionMenuPresentation
    var metaSummary: CalendarQuickActionMetaSummary?
    var sourcePhase: CalendarLongPressPhase
}

struct CalendarEventLongPressResolution {
    var event: Event
    var occurrenceID: String?
    var actionDate: Date
    var dragMode: EventDragMode
    var terminalState: EventDragTerminalState
    var didMove: Bool
    var touchPointGlobal: CGPoint
}

func calendarLongPressPhase(
    elapsedSinceTouchDown: TimeInterval,
    phase1Trigger: TimeInterval = 0.25,
    phase2Trigger: TimeInterval = 0.60,
    phase3Trigger: TimeInterval = 1.05
) -> CalendarLongPressPhase? {
    guard elapsedSinceTouchDown >= phase1Trigger else { return nil }
    if elapsedSinceTouchDown >= phase3Trigger {
        return .expandedMenu
    }
    if elapsedSinceTouchDown >= phase2Trigger {
        return .compactMenu
    }
    return .handlePreview
}

func calendarQuickActionMenuPresentation(
    for phase: CalendarLongPressPhase
) -> CalendarQuickActionMenuPresentation? {
    switch phase {
    case .handlePreview:
        return nil
    case .compactMenu:
        return .compact
    case .expandedMenu:
        return .expanded
    }
}

func calendarShouldBeginResizeGraceAfterQuickMenuDismiss(
    reason: CalendarQuickActionDismissReason
) -> Bool {
    reason == .passiveDismiss
}

func calendarShouldPromoteLongPressToManipulation(
    dragMode: EventDragMode,
    canMove: Bool,
    movementExceededThreshold: Bool
) -> Bool {
    guard movementExceededThreshold else { return false }
    switch dragMode {
    case .move:
        return canMove
    case .resizeTop, .resizeBottom:
        return true
    }
}

func calendarShouldSetFocusAfterLongPressManipulationPromotion(
    didPromote: Bool,
    currentPhase: CalendarLongPressPhase?,
    quickMenuWasPresented: Bool,
    hasPendingGraceOccurrence: Bool
) -> Bool {
    guard didPromote else { return false }
    return currentPhase != nil || quickMenuWasPresented || hasPendingGraceOccurrence
}

func calendarOccurrenceTimeSummary(
    event: Event,
    range: Event.TimeRange,
    calendar: Calendar = .current
) -> String {
    let dateFormatter = DateFormatter()
    let timeFormatter = DateFormatter()
    dateFormatter.dateStyle = .medium
    timeFormatter.timeStyle = .short
    if event.isAllDay {
        if calendar.isDate(range.start, inSameDayAs: range.end) {
            return "\(dateFormatter.string(from: range.start)) • All-day"
        }
        return "\(dateFormatter.string(from: range.start)) - \(dateFormatter.string(from: range.end)) • All-day"
    }
    if calendar.isDate(range.start, inSameDayAs: range.end) {
        return "\(dateFormatter.string(from: range.start)) • \(timeFormatter.string(from: range.start)) - \(timeFormatter.string(from: range.end))"
    }
    return "\(dateFormatter.string(from: range.start)) \(timeFormatter.string(from: range.start)) - \(dateFormatter.string(from: range.end)) \(timeFormatter.string(from: range.end))"
}

func calendarRepeatSummary(for event: Event) -> String {
    let interval = max(1, event.repeatInterval)
    let unit: String
    switch event.repeatUnit {
    case .none: unit = "Never"
    case .day: unit = interval == 1 ? "Daily" : "Every \(interval) days"
    case .week: unit = interval == 1 ? "Weekly" : "Every \(interval) weeks"
    case .month: unit = interval == 1 ? "Monthly" : "Every \(interval) months"
    case .year: unit = interval == 1 ? "Yearly" : "Every \(interval) years"
    }
    guard event.repeatUnit != .none else { return unit }

    switch event.repeatEndType {
    case .none:
        return unit
    case .onDate:
        if let date = event.repeatEndDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            return "\(unit) • Ends \(formatter.string(from: date))"
        }
        return unit
    case .afterCount:
        if let count = event.repeatEndCount {
            return "\(unit) • \(count) occurrences"
        }
        return unit
    }
}

func calendarResolvedEventForOccurrenceContext(
    _ context: CalendarEventOccurrenceContext,
    in calendarEvents: [Event],
    calendar: Calendar = .current
) -> Event? {
    if let exact = calendarEvents.first(where: { $0.id == context.eventID }) {
        if exact.isRecurringSeries {
            let targetDay = calendar.startOfDay(for: context.occurrenceDate)
            if CalendarLayout.recurrenceOccurrence(for: exact, on: targetDay, calendar: calendar) != nil {
                return exact
            }
            if let exception = calendarEvents.first(where: { candidate in
                candidate.recurrenceParentId == exact.id
                    && candidate.recurrenceInstanceDate.map { calendar.isDate($0, inSameDayAs: targetDay) } == true
            }) {
                return exception
            }
            return exact
        }
        return exact
    }

    let targetDay = calendar.startOfDay(for: context.occurrenceDate)
    return calendarEvents.first(where: { candidate in
        candidate.recurrenceParentId == context.eventID
            && candidate.recurrenceInstanceDate.map { calendar.isDate($0, inSameDayAs: targetDay) } == true
    })
}

func calendarOccurrenceDisplayRange(
    event: Event,
    occurrenceDate: Date,
    calendar: Calendar = .current
) -> Event.TimeRange? {
    if event.isRecurringSeries {
        return CalendarLayout.recurrenceOccurrence(for: event, on: occurrenceDate, calendar: calendar)
    }
    if let instanceDay = event.recurrenceInstanceDate,
       !calendar.isDate(instanceDay, inSameDayAs: occurrenceDate) {
        return nil
    }
    return event.primaryTimeRange
}
