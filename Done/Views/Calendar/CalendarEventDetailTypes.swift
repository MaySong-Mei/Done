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

struct CalendarQuickActionMenuState: Identifiable {
    let id = UUID()
    var occurrence: CalendarEventOccurrenceContext
    var touchPointGlobal: CGPoint
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
