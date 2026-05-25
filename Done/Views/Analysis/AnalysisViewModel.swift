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
            let occurrences = CalendarLayout.occurrencesForDate(store.calendarEvents, date: day, calendar: calendar)
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
        // Anchor at the last day of the selected period that isn't in the
        // future, so the streak reflects the viewed range/offset rather than
        // always ending today.
        let lastDayOfRange = calendar.date(byAdding: .day, value: -1, to: dateRange.end) ?? today
        var day = min(calendar.startOfDay(for: lastDayOfRange), today)
        var streak = 0
        while true {
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
            let occurrences = CalendarLayout.occurrencesForDate(store.calendarEvents, date: day, calendar: calendar)
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
            let occurrences = CalendarLayout.occurrencesForDate(store.calendarEvents, date: day, calendar: calendar)
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

    // MARK: - Private

    private func clampedHours(_ range: Event.TimeRange, on day: Date) -> Double {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let start = max(range.start, dayStart)
        let end = min(range.end, dayEnd)
        return max(0, end.timeIntervalSince(start)) / 3600
    }
}
