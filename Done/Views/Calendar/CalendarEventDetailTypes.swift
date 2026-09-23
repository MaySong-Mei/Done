import Foundation
import CoreGraphics

struct CalendarEventOccurrenceContext: Hashable, Codable, Identifiable {
    enum Source: String, Codable, Hashable {
        case timelineTap
        case timelineLongPress
        case allDayTap
        case detailToolbarChat
        /// Built inside focus mode to attach a timeline note to the
        /// current event without leaving the focus surface.
        case focus
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

    var id: String {
        let day = Int(Calendar.current.startOfDay(for: occurrence.occurrenceDate).timeIntervalSince1970)
        let target = initialJumpTarget?.rawValue ?? "none"
        return "\(occurrence.eventID.uuidString)-\(day)-\(target)"
    }
}

enum CalendarResizeGraceTrigger: String, Hashable, Codable {
    case longPressRelease
    case moveCommit
    case resizeCommit
    case createCommit
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

struct CalendarEventLongPressResolution {
    var event: Event
    var occurrenceID: String?
    var actionDate: Date
    var dragMode: EventDragMode
    var terminalState: EventDragTerminalState
    var didMove: Bool
    var touchPointGlobal: CGPoint
}

struct CalendarEventLongPressBegan {
    var event: Event
    var occurrenceID: String?
    var actionDate: Date
    var dragMode: EventDragMode
    var touchPointGlobal: CGPoint
    var eventFrameGlobal: CGRect
}

func calendarShouldPromoteLongPressToManipulation(
    dragMode: EventDragMode,
    movementExceededThreshold: Bool
) -> Bool {
    guard movementExceededThreshold else { return false }
    switch dragMode {
    case .move, .resizeTop, .resizeBottom:
        return true
    }
}

/// Shared focus/grace predicate. Returns true when the given (event, occurrence)
/// is in any selected state that justifies dropping the fall-through edge inset
/// — i.e., the user has committed attention to this event and the day column
/// should stop yielding edge-band touches to drag-to-create.
func calendarEventShowsResizeHandles(
    focusedEventID: UUID?,
    focusedOccurrenceID: String?,
    graceResizeEventID: UUID?,
    graceResizeOccurrenceID: String?,
    eventID: UUID,
    occurrenceID: String?
) -> Bool {
    let isFocused = focusedEventID == eventID
        && (focusedOccurrenceID == nil || focusedOccurrenceID == occurrenceID)
    let isGrace = graceResizeEventID == eventID
        && (graceResizeOccurrenceID == nil || graceResizeOccurrenceID == occurrenceID)
    return isFocused || isGrace
}

func calendarOccurrenceTimeSummary(
    event: Event,
    range: Event.TimeRange,
    calendar: Calendar = .current
) -> String {
    let dateFormatter = DateFormatter()
    let timeFormatter = DateFormatter()
    dateFormatter.dateStyle = .medium
    if AppTimeFormat.current.is24 {
        timeFormatter.dateFormat = "H:mm"
    } else {
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.amSymbol = "am"
        timeFormatter.pmSymbol = "pm"
    }
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
            // Day-key identity, not `isDate(_:inSameDayAs:)` on the stored
            // mirror midnight: after a tz change the mirror reads as the
            // adjacent local day and the suppressed day's detail lookup goes
            // dark while its detached instance exists (gh#127 item 1
            // follow-up).
            if let exception = calendarEvents.first(where: { candidate in
                candidate.recurrenceParentId == exact.id
                    && candidate.recurrenceInstanceMatches(day: targetDay, calendar: calendar)
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
            && candidate.recurrenceInstanceMatches(day: targetDay, calendar: calendar)
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
    if event.recurrenceInstanceDate != nil,
       !event.recurrenceInstanceMatches(day: occurrenceDate, calendar: calendar) {
        return nil
    }
    // Render-frame range so the detail header shows the same slot the canvas
    // drew the instance in (nominal day; identical to `primaryTimeRange`
    // whenever the minting frame is the current frame).
    return event.renderPrimaryTimeRange(calendar: calendar)
}
