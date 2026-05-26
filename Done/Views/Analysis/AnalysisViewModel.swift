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
    static let typicalDailyBand = 60.0...90.0
    static let overloadThreshold = 38.0
    static let recoveryStableThreshold = 60.0
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
    @Published private(set) var tokenHypothesisCache: TokenHypothesisAnalysis?
    @Published private(set) var isRefreshingTokenHypothesisAnalysis = false

    private let calendar = Calendar.current
    private let tokenEngine = TokenInferenceService.shared
    private var lastTokenHypothesisSignature: Int?

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
            formatter.dateFormat = "MMM d"
            let endDisplay = calendar.date(byAdding: .day, value: -1, to: range.end)!
            let endFormatter = DateFormatter()
            endFormatter.dateFormat = "MMM d"
            return "\(formatter.string(from: range.start)) – \(endFormatter.string(from: endDisplay))"
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
            // canvasRenderableCalendarEvents (= calendarEvents minus
            // absorbed todos): an absorbed `.todo` keeps its own
            // timeRanges, so feeding raw events to `occurrencesForDate`
            // emits a phantom occurrence on top of the parent event's
            // own occurrence — double-counts the same wall-clock window
            // in the total.  Filter matches the canvas-render filter.
            let occurrences = CalendarLayout.occurrencesForDate(store.canvasRenderableCalendarEvents, date: day, calendar: calendar)
            for occurrence in occurrences {
                total += clampedHours(occurrence.range, on: day)
            }
        }
        return total
    }

    func recordRate(store: EventStore) -> Double {
        let range = dateRange
        let totalHoursInPeriod = range.end.timeIntervalSince(range.start) / 3600
        guard totalHoursInPeriod > 0 else { return 0 }
        let scheduled = totalScheduledHours(store: store)
        return scheduled / totalHoursInPeriod * 100
    }

    func tasksCompletedCount(store: EventStore) -> Int {
        let range = dateRange
        return store.events.filter {
            $0.status == .completed &&
            $0.completeAt.map { $0 >= range.start && $0 < range.end } == true
        }.count
    }

    func recordStreak(store: EventStore) -> Int {
        let today = calendar.startOfDay(for: Date())
        var streak = 0
        var day = today
        while true {
            // Intentionally raw `calendarEvents` — streak semantics are
            // "did you log SOMETHING that day", and absorbing an old
            // todo into a long-ago event should NOT retroactively erase
            // the original day from the streak (the work was still
            // logged on that day, even if it now logically lives inside
            // a parent on a different day).  Differs from the hours /
            // type / baseline metrics which DO need the filter because
            // they're sums-of-windows and the parent's window already
            // covers the absorbed todo's contribution.
            let occurrences = CalendarLayout.occurrencesForDate(store.calendarEvents, date: day, calendar: calendar)
            if occurrences.isEmpty { break }
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    func completionRate(store: EventStore) -> Double {
        let completed = tasksCompletedCount(store: store)
        let active = store.events.filter { $0.status == .active }.count
        let total = completed + active
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total) * 100
    }

    func activeTasksCount(store: EventStore) -> Int {
        store.events.filter { $0.status == .active }.count
    }

    // MARK: - Chart Data

    func typeAllocations(store: EventStore) -> [TypeAllocation] {
        var hoursByType: [String: Double] = [:]
        for day in daysInRange() {
            // canvasRenderableCalendarEvents: absorbed todo's type
            // and parent's type would otherwise both add the same
            // wall-clock window to their respective type buckets.
            let occurrences = CalendarLayout.occurrencesForDate(store.canvasRenderableCalendarEvents, date: day, calendar: calendar)
            for occurrence in occurrences {
                let type = occurrence.event.type.isEmpty ? "Other" : occurrence.event.type
                hoursByType[type, default: 0] += clampedHours(occurrence.range, on: day)
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
            var hoursByType: [String: Double] = [:]
            // canvasRenderableCalendarEvents: same double-count concern
            // as `typeAllocations` above — keep the chart consistent
            // with the total + with what the canvas renders.
            let occurrences = CalendarLayout.occurrencesForDate(store.canvasRenderableCalendarEvents, date: day, calendar: calendar)
            for occurrence in occurrences {
                let type = occurrence.event.type.isEmpty ? "Other" : occurrence.event.type
                hoursByType[type, default: 0] += clampedHours(occurrence.range, on: day)
            }
            for (type, hours) in hoursByType {
                result.append(DailyHours(date: day, type: type, hours: hours, color: EventTypeTemplateStore.color(for: type)))
            }
        }
        return result
    }

    func taskCompletionTrend(store: EventStore) -> [CompletionDataPoint] {
        daysInRange().map { day in
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let count = store.events.filter {
                $0.status == .completed &&
                $0.completeAt.map { $0 >= dayStart && $0 < dayEnd } == true
            }.count
            return CompletionDataPoint(date: day, count: count)
        }
    }

    // MARK: - Token Hypothesis Analysis

    func tokenHypothesisAnalysis(store: EventStore) -> TokenHypothesisAnalysis {
        TokenAnalysisAssembler.build(
            store: store,
            dateRange: dateRange,
            period: period,
            metadata: nil
        )
    }

    func displayedTokenHypothesisAnalysis(store: EventStore) -> TokenHypothesisAnalysis {
        tokenHypothesisCache ?? tokenHypothesisAnalysis(store: store)
    }

    func tokenHypothesisRefreshSignature(store: EventStore) -> Int {
        var hasher = Hasher()
        hasher.combine(period.rawValue)
        hasher.combine(offset)
        hasher.combine(dateRange.start)
        hasher.combine(dateRange.end)
        hasher.combine(UserDefaults.standard.string(forKey: AppSettingsKeys.agentProvider) ?? AppSettingsKeys.agentProviderDefault)
        hasher.combine(!(UserDefaults.standard.string(forKey: AppSettingsKeys.agentAPIKey) ?? "").isEmpty)

        let sortedEvents = store.calendarEvents.sorted { $0.id.uuidString < $1.id.uuidString }
        for event in sortedEvents {
            hasher.combine(event.id)
            hasher.combine(event.title)
            hasher.combine(event.note)
            hasher.combine(event.type)
            hasher.combine(event.status.rawValue)
            hasher.combine(event.isDone)
            hasher.combine(event.isAllDay)
            hasher.combine(event.displayKind.rawValue)
            // Absorbing/releasing a todo flips this UUID without
            // touching any of the other hashed fields, but the
            // downstream analytics path now consumes
            // `canvasRenderableCalendarEvents` (which filters by this
            // exact field) — without including it here, an absorb
            // op would NOT bust the cache and stale results would
            // ride through.
            hasher.combine(event.absorbedIntoEventID)
            for range in event.timeRanges {
                hasher.combine(range.start)
                hasher.combine(range.end)
            }
        }

        let sortedFeedback = store.calendarEventFeedbackRecords.sorted {
            if $0.eventID != $1.eventID { return $0.eventID.uuidString < $1.eventID.uuidString }
            return $0.occurrenceDate < $1.occurrenceDate
        }
        for feedback in sortedFeedback {
            hasher.combine(feedback.eventID)
            hasher.combine(feedback.occurrenceDate)
            hasher.combine(feedback.effort ?? -1)
            hasher.combine(feedback.emotions.joined(separator: "|"))
            hasher.combine(feedback.behaviors.joined(separator: "|"))
            hasher.combine(feedback.selfNote)
            hasher.combine(feedback.updatedAt)
        }

        let sortedLogs = store.calendarEventLogRecords.sorted {
            if $0.eventID != $1.eventID { return $0.eventID.uuidString < $1.eventID.uuidString }
            return $0.occurrenceDate < $1.occurrenceDate
        }
        for log in sortedLogs {
            hasher.combine(log.eventID)
            hasher.combine(log.occurrenceDate)
            hasher.combine(log.summary)
            hasher.combine(log.note)
            hasher.combine(log.effort ?? -1)
            hasher.combine(log.emotions.joined(separator: "|"))
            hasher.combine(log.behaviors.joined(separator: "|"))
            hasher.combine(log.selectedTemplateID ?? "")
            hasher.combine(log.suggestedTemplateID ?? "")
            hasher.combine(log.updatedAt)
        }

        return hasher.finalize()
    }

    @MainActor
    func refreshTokenHypothesisAnalysis(store: EventStore) async {
        let signature = tokenHypothesisRefreshSignature(store: store)
        if signature == lastTokenHypothesisSignature, tokenHypothesisCache != nil {
            return
        }

        lastTokenHypothesisSignature = signature
        tokenHypothesisCache = tokenHypothesisAnalysis(store: store)
        isRefreshingTokenHypothesisAnalysis = true

        let metadata = await tokenEngine.syncForAnalysis(
            store: store,
            dateRange: dateRange,
            period: period
        )

        guard signature == lastTokenHypothesisSignature else { return }
        tokenHypothesisCache = TokenAnalysisAssembler.build(
            store: store,
            dateRange: dateRange,
            period: period,
            metadata: metadata
        )
        isRefreshingTokenHypothesisAnalysis = false
    }

    func invalidateTokenHypothesisAnalysis() {
        lastTokenHypothesisSignature = nil
        tokenHypothesisCache = nil
        isRefreshingTokenHypothesisAnalysis = false
    }

    // MARK: - Private

    private func clampedHours(_ range: Event.TimeRange, on day: Date) -> Double {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let start = max(range.start, dayStart)
        let end = min(range.end, dayEnd)
        return max(0, end.timeIntervalSince(start)) / 3600
    }
}
