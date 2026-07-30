//
//  AnalysisViewModel.swift
//  Done
//

import SwiftUI
import Combine

enum AnalysisPeriod: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"

    static func fromStoredValue(_ value: String?) -> AnalysisPeriod {
        guard let value, let period = AnalysisPeriod(rawValue: value) else {
            return .week
        }
        return period
    }
}

struct TypeAllocation: Identifiable {
    let id = UUID()
    let type: String
    let hours: Double
    let color: Color
}

struct DailyHours: Identifiable {
    let id = UUID()
    let date: Date
    let type: String
    let hours: Double
    let color: Color
}

struct CompletionDataPoint: Identifiable {
    let id = UUID()
    let date: Date
    let count: Int
}

enum TokenHypothesisKind: String, CaseIterable, Identifiable {
    case worldModel = "world_model"
    case state
    case meta
    case compressed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .worldModel: return "World Model"
        case .state: return "State"
        case .meta: return "Meta"
        case .compressed: return "Compressed"
        }
    }
}

struct TokenDimensionBreakdown: Codable, Hashable {
    var cognitiveTokenDelta: Double
    var physicalCaloriesDelta: Double
    var tomorrowTokenDelta: Double
    var tomorrowCaloriesDelta: Double
    var observability: Double

    var dominantLabel: String {
        let ranked = [
            ("Cognitive", abs(cognitiveTokenDelta)),
            ("Physical", abs(physicalCaloriesDelta)),
            ("Tomorrow Token", abs(tomorrowTokenDelta)),
            ("Tomorrow Calories", abs(tomorrowCaloriesDelta)),
            ("Observability", observability)
        ].sorted { $0.1 > $1.1 }
        return ranked.first?.0 ?? "Mixed"
    }
}

struct TokenEvidenceBundle: Codable, Hashable {
    var direct: [String]
    var structural: [String]
    var historical: [String]

    var isEmpty: Bool {
        direct.isEmpty && structural.isEmpty && historical.isEmpty
    }
}

struct TokenHypothesisSnapshot: Identifiable, Hashable {
    var id: String
    var statement: String
    var kind: TokenHypothesisKind
    var confidence: Double
    var confidenceDelta: Double
    var evidenceSummary: String
    var supportCount: Int
    var isPersistent: Bool
    var lastUpdated: Date
}

struct TokenFlowPoint: Identifiable {
    var id: String
    var stepIndex: Int
    var label: String
    var date: Date
    var token: Double
    var physicalCalories: Double
    var confidence: Double
}

struct TokenEventAnalysis: Identifiable {
    var id: String
    var eventID: UUID
    var title: String
    var typeLabel: String
    var start: Date
    var end: Date
    var tokenBefore: Double
    var tokenAfter: Double
    var tokenChange: Double
    var physicalCaloriesBefore: Double
    var physicalCaloriesAfter: Double
    var physicalCaloriesChange: Double
    var confidence: Double
    var dimensions: TokenDimensionBreakdown
    var summary: String
    var evidence: TokenEvidenceBundle
    var stateTags: [String]
    var hypotheses: [TokenHypothesisSnapshot]
}

struct TokenDayAnalysis: Identifiable {
    var id: String
    var date: Date
    var startingToken: Double
    var endingToken: Double
    var startingPhysicalCalories: Double
    var endingPhysicalCalories: Double
    var averageConfidence: Double
    var nextDayTokenRange: ClosedRange<Double>
    var nextDayPhysicalCaloriesRange: ClosedRange<Double>
    var summary: String
    var flow: [TokenFlowPoint]
    var eventAnalyses: [TokenEventAnalysis]
    var hypotheses: [TokenHypothesisSnapshot]
    var stateTags: [String]
}

struct TokenHypothesisAnalysis {
    var currentToken: Double
    var currentPhysicalCalories: Double
    var averageConfidence: Double
    var nextDayTokenRange: ClosedRange<Double>
    var nextDayPhysicalCaloriesRange: ClosedRange<Double>
    var currentStateTags: [String]
    var dayAnalyses: [TokenDayAnalysis]
    var evolvingHypotheses: [TokenHypothesisSnapshot]
    var usedLLM: Bool
    var analysisSourceLabel: String
    var fallbackReason: String?

    var latestDay: TokenDayAnalysis? {
        dayAnalyses.last
    }
}

enum TokenCalibration {
    // Calibrated as thousands of effective cognitive tokens per day.
    static let neutralDailyCapacity = 84.0
    static let emptyWindowRange = 78.0...90.0
    static let projectionFloor = 0.0
    static let projectionCeiling = 130.0
    static let nextDayFloor = 20.0
    static let nextDayBaselineFloor = 48.0
    static let neutralPhysicalCalories = 2200.0
    static let physicalFloor = 0.0
    static let physicalCeiling = 4200.0
    static let emptyPhysicalRange = 1800.0...2600.0
    static let nextDayPhysicalFloor = 900.0
    static let nextDayPhysicalBaselineFloor = 1400.0
}

final class AnalysisViewModel: ObservableObject {
    @Published var period: AnalysisPeriod = .week
    @Published var offset: Int = 0

    private let calendar = Calendar.current

    /// Wall-clock source for the elapsed-clamp (#121). Injectable so tests can
    /// pin "now"; production code never overrides the real clock.
    var now: () -> Date = { Date() }

    init(initialPeriod: AnalysisPeriod? = nil, defaults: UserDefaults = .standard) {
        if let initialPeriod {
            period = initialPeriod
        } else {
            period = AnalysisPeriod.fromStoredValue(
                defaults.string(forKey: AppSettingsKeys.analysisDefaultPeriod)
            )
        }
    }

    var dateRange: (start: Date, end: Date) {
        let today = calendar.startOfDay(for: Date())
        switch period {
        case .day:
            let start = calendar.date(byAdding: .day, value: offset, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return (start, end)
        case .week:
            let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
            let start = calendar.date(byAdding: .weekOfYear, value: offset, to: weekStart)!
            let end = calendar.date(byAdding: .day, value: 7, to: start)!
            return (start, end)
        case .month:
            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
            let start = calendar.date(byAdding: .month, value: offset, to: monthStart)!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            return (start, end)
        }
    }

    var periodLabel: String {
        let range = dateRange
        let formatter = DateFormatter()
        switch period {
        case .day:
            formatter.dateFormat = "MMM d, yyyy"
            return formatter.string(from: range.start)
        case .week:
            let endDisplay = calendar.date(byAdding: .day, value: -1, to: range.end)!
            // Weeks in the current year stay compact; once navigation crosses
            // into another year the label carries the year on both ends
            // ("Dec 29, 2025 – Jan 4, 2026") to stay unambiguous.
            let currentYear = calendar.component(.year, from: Date())
            let compact = calendar.component(.year, from: range.start) == currentYear
                && calendar.component(.year, from: endDisplay) == currentYear
            formatter.dateFormat = compact ? "MMM d" : "MMM d, yyyy"
            return "\(formatter.string(from: range.start)) – \(formatter.string(from: endDisplay))"
        case .month:
            formatter.dateFormat = "MMMM yyyy"
            return formatter.string(from: range.start)
        }
    }

    func daysInRange() -> [Date] {
        let range = dateRange
        var days: [Date] = []
        var current = range.start
        while current < range.end {
            days.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        return days
    }

    // MARK: - Summary

    func totalScheduledHours(store: EventStore) -> Double {
        var total = 0.0
        for day in daysInRange() {
            // canvasRenderableCalendarEvents (= rawCalendarEvents minus
            // absorbed todos): an absorbed `.todo` keeps its own
            // timeRanges, so feeding raw events to `occurrencesForDate`
            // emits a phantom occurrence on top of the parent event's
            // own occurrence — double-counts the same wall-clock window
            // in the total.  Filter matches the canvas-render filter.
            let occurrences = CalendarLayout.occurrencesForDate(store.canvasRenderableCalendarEvents, date: day, calendar: calendar)
            total += overlapSharedHoursByType(occurrences, on: day).values.reduce(0, +)
        }
        return total
    }

    func recordRate(store: EventStore) -> Double {
        let range = dateRange
        // Elapsed-clamp (#121): the numerator (`totalScheduledHours`) only
        // counts elapsed hours now, so the denominator must be the elapsed
        // span of the period — dividing by the full week on a Wednesday would
        // read the rate artificially low.
        let cut = Event.elapsedWindowCut(
            windowStart: range.start, windowEnd: range.end, asOf: now()
        )
        let elapsedHoursInPeriod = cut.timeIntervalSince(range.start) / 3600
        guard elapsedHoursInPeriod > 0 else { return 0 }
        let scheduled = totalScheduledHours(store: store)
        return scheduled / elapsedHoursInPeriod * 100
    }

    func tasksCompletedCount(store: EventStore) -> Int {
        let range = dateRange
        return completedTaskCount(store: store, from: range.start, to: range.end)
    }

    func recordStreak(store: EventStore) -> Int {
        let today = calendar.startOfDay(for: Date())
        // Anchor at the last day of the selected period that isn't in the
        // future, so the streak reflects the viewed range/offset rather than
        // always ending today.
        let lastDayOfRange = calendar.date(byAdding: .day, value: -1, to: dateRange.end) ?? today
        var day = min(calendar.startOfDay(for: lastDayOfRange), today)
        var streak = 0
        while true {
            // Intentionally `rawCalendarEvents` — streak semantics are
            // "did you log SOMETHING that day", and absorbing an old
            // todo into a long-ago event should NOT retroactively erase
            // the original day from the streak (the work was still
            // logged on that day, even if it now logically lives inside
            // a parent on a different day).  Differs from the hours /
            // type / baseline metrics which DO need the filter because
            // they're sums-of-windows and the parent's window already
            // covers the absorbed todo's contribution.
            let occurrences = CalendarLayout.occurrencesForDate(store.rawCalendarEvents, date: day, calendar: calendar)
            if occurrences.isEmpty { break }
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    func completionRate(store: EventStore) -> Double {
        let completed = tasksCompletedCount(store: store)
        let active = activeTasksCount(store: store)
        let total = completed + active
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total) * 100
    }

    /// Open tasks across both domains (#120): legacy active wannas plus open
    /// calendar todos.  Unabsorbed only — an open absorbed todo lives inside
    /// its parent event, not as an independent task.  The linked-twin guard
    /// mirrors `completedTaskCount` so a wanna already pushed to the calendar
    /// isn't counted twice.  Keeps `completionRate`'s denominator in the same
    /// frame as its (now two-domain) numerator.
    func activeTasksCount(store: EventStore) -> Int {
        let activeWannas = store.events.filter { $0.status == .active }
        let wannaLinkedCalendarIDs = Set(activeWannas.compactMap(\.linkedCalendarEventId))
        let openCalendarTodos = store.rawCalendarEvents.filter {
            $0.kind == .todo && !$0.isDone && $0.absorbedIntoEventID == nil
                && !wannaLinkedCalendarIDs.contains($0.id)
        }
        return activeWannas.count + openCalendarTodos.count
    }

    // MARK: - Chart Data

    func typeAllocations(store: EventStore) -> [TypeAllocation] {
        var hoursByType: [String: Double] = [:]
        for day in daysInRange() {
            // canvasRenderableCalendarEvents: absorbed todo's type
            // and parent's type would otherwise both add the same
            // wall-clock window to their respective type buckets.
            let occurrences = CalendarLayout.occurrencesForDate(store.canvasRenderableCalendarEvents, date: day, calendar: calendar)
            for (type, hours) in overlapSharedHoursByType(occurrences, on: day) {
                hoursByType[type, default: 0] += hours
            }
        }

        return hoursByType.map {
            TypeAllocation(type: $0.key, hours: $0.value, color: EventTypeTemplateStore.color(for: $0.key))
        }
        .sorted { $0.hours > $1.hours }
    }

    func dailyHoursData(store: EventStore) -> [DailyHours] {
        var result: [DailyHours] = []
        for day in daysInRange() {
            // canvasRenderableCalendarEvents: same double-count concern
            // as `typeAllocations` above — keep the chart consistent
            // with the total + with what the canvas renders.
            let occurrences = CalendarLayout.occurrencesForDate(store.canvasRenderableCalendarEvents, date: day, calendar: calendar)
            let hoursByType = overlapSharedHoursByType(occurrences, on: day)
            for (type, hours) in hoursByType.sorted(by: { $0.key < $1.key }) {
                guard hours > 0 else { continue }
                result.append(DailyHours(date: day, type: type, hours: hours, color: EventTypeTemplateStore.color(for: type)))
            }
        }
        return result
    }

    func taskCompletionTrend(store: EventStore) -> [CompletionDataPoint] {
        daysInRange().map { day in
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            return CompletionDataPoint(
                date: day,
                count: completedTaskCount(store: store, from: dayStart, to: dayEnd)
            )
        }
    }

    // MARK: - Private

    /// Completed-task count for `[start, end)` across BOTH task domains
    /// (#120 — post-Todo-unification the legacy list alone is a blind spot):
    ///
    /// - Legacy Wanna tasks (`store.events`) keep the original predicate:
    ///   `status == .completed` with `completeAt` inside the window.
    /// - Calendar todos count on `kind == .todo && isDone` with `completeAt`
    ///   inside the window.  `isDone` is the calendar-domain completion flag
    ///   (the done-fade and the report's `(done)` marker read it), and every
    ///   mark-done path writes the isDone/status/completeAt trio together
    ///   (detail-page `toggleTodoDone`, and the absorb auto-cascade in
    ///   `EventStore.absorbTodoIntoEvent`).  Reads `rawCalendarEvents`
    ///   deliberately — this is a count of completed intents, not a
    ///   sum-of-windows, so the absorbed-todo double-count that forces the
    ///   hour metrics onto `canvasRenderableCalendarEvents` can't happen
    ///   here: an absorbed todo auto-completed by its past parent is still a
    ///   completed intent, and the parent `.event` never enters this count.
    /// - Dedup: a legacy wanna scheduled onto the calendar carries
    ///   `linkedCalendarEventId`; when both twins complete in the window the
    ///   calendar one is skipped so a single intent counts once.  (Today the
    ///   push/timer paths link wannas to `.event` twins only, so the guard is
    ///   defensive — it keeps the count honest if a future path links a
    ///   wanna to a real `.todo`.)
    private func completedTaskCount(store: EventStore, from start: Date, to end: Date) -> Int {
        func completeAtInWindow(_ event: Event) -> Bool {
            event.completeAt.map { $0 >= start && $0 < end } == true
        }
        let completedWannas = store.events.filter {
            $0.status == .completed && completeAtInWindow($0)
        }
        let wannaLinkedCalendarIDs = Set(completedWannas.compactMap(\.linkedCalendarEventId))
        let completedCalendarTodos = store.rawCalendarEvents.filter {
            $0.kind == .todo && $0.isDone && completeAtInWindow($0)
                && !wannaLinkedCalendarIDs.contains($0.id)
        }
        return completedWannas.count + completedCalendarTodos.count
    }

    /// Maps each parent event ID to the ranges of its embedded interrupt
    /// children present in `occurrences`. Interrupt children render as their
    /// own occurrences here (via `interruptRelation`), so we collect them once
    /// per day and subtract their time from the matching parent.
    private func interruptChildRangesByParent(
        _ occurrences: [CalendarLayout.EventOccurrence]
    ) -> [UUID: [Event.TimeRange]] {
        var map: [UUID: [Event.TimeRange]] = [:]
        for occurrence in occurrences {
            guard let relation = occurrence.event.interruptRelation,
                  relation.state == .embedded else { continue }
            map[relation.parentEventID, default: []].append(occurrence.range)
        }
        return map
    }

    /// Per-type hours for `day`, conserving wall-clock time:
    ///
    /// - Parents use NET — embedded interrupt children are cut out of the
    ///   parent's intervals first (the children contribute their own time
    ///   under their own type bucket), so a parent/child pair never reads
    ///   as an overlap.
    /// - A window covered by n remaining occurrences credits each 1/n
    ///   (two overlapping events each count half), so a fully-logged day
    ///   sums to 24h instead of over-counting — which would otherwise
    ///   inflate the week-max and make every other day's heatmap bar
    ///   read as "not full".
    ///
    /// The netting and the sweep live on `Event` (`remainingIntervals` /
    /// `overlapSharedHours`) and are shared with `ReportStatsBuilder`, so the
    /// report and these charts can never disagree about a day's hours (#116).
    private func overlapSharedHoursByType(
        _ occurrences: [CalendarLayout.EventOccurrence],
        on day: Date
    ) -> [String: Double] {
        let dayStart = calendar.startOfDay(for: day)
        let fullDayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        // Elapsed-clamp (#121): every consumer of this aggregation ("Xh
        // active", the per-day heatmap, the type split) claims *spent* time,
        // so an occurrence contributes min(end, now) − start when it has
        // started and nothing at all when it lies in the future — a plan
        // scheduled for tomorrow must not paint this week's bars.  The cut
        // rule is `Event.elapsedWindowCut`, shared with the report clue
        // battery so the two surfaces can't drift (#111/#116).
        let dayEnd = Event.elapsedWindowCut(
            windowStart: dayStart, windowEnd: fullDayEnd, asOf: now()
        )
        guard dayEnd > dayStart else { return [:] }
        let childRangesByParent = interruptChildRangesByParent(occurrences)

        var types: [String] = []
        var contributions: [[Event.TimeRange]] = []
        for occurrence in occurrences {
            let intervals = Event.remainingIntervals(
                occurrence.range,
                excluding: childRangesByParent[occurrence.event.id] ?? [],
                windowStart: dayStart,
                windowEnd: dayEnd
            )
            guard !intervals.isEmpty else { continue }
            types.append(occurrence.event.type.isEmpty ? "Other" : occurrence.event.type)
            contributions.append(intervals)
        }

        var hoursByType: [String: Double] = [:]
        let shared = Event.overlapSharedHours(contributions: contributions)
        for (index, hours) in shared.enumerated() where hours > 0 {
            hoursByType[types[index], default: 0] += hours
        }
        return hoursByType
    }
}
