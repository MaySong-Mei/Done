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

final class AnalysisViewModel: ObservableObject {
    @Published var period: AnalysisPeriod = .week
    @Published var offset: Int = 0

    private let calendar = Calendar.current

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
        let fmt = DateFormatter()
        switch period {
        case .day:
            fmt.dateFormat = "MMM d, yyyy"
            return fmt.string(from: range.start)
        case .week:
            fmt.dateFormat = "MMM d"
            let endDisplay = calendar.date(byAdding: .day, value: -1, to: range.end)!
            let fmtEnd = DateFormatter()
            fmtEnd.dateFormat = "MMM d"
            return "\(fmt.string(from: range.start)) – \(fmtEnd.string(from: endDisplay))"
        case .month:
            fmt.dateFormat = "MMMM yyyy"
            return fmt.string(from: range.start)
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
        var total: Double = 0
        for day in daysInRange() {
            let occs = CalendarLayout.occurrencesForDate(store.calendarEvents, date: day, calendar: calendar)
            for occ in occs {
                total += clampedHours(occ.range, on: day)
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
            let occs = CalendarLayout.occurrencesForDate(store.calendarEvents, date: day, calendar: calendar)
            if occs.isEmpty { break }
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
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
            let occs = CalendarLayout.occurrencesForDate(store.calendarEvents, date: day, calendar: calendar)
            for occ in occs {
                let type = occ.event.type.isEmpty ? "Other" : occ.event.type
                hoursByType[type, default: 0] += clampedHours(occ.range, on: day)
            }
        }
        return hoursByType.map {
            TypeAllocation(type: $0.key, hours: $0.value, color: EventTypeTemplateStore.color(for: $0.key))
        }.sorted { $0.hours > $1.hours }
    }

    func dailyHoursData(store: EventStore) -> [DailyHours] {
        var result: [DailyHours] = []
        for day in daysInRange() {
            var hoursByType: [String: Double] = [:]
            let occs = CalendarLayout.occurrencesForDate(store.calendarEvents, date: day, calendar: calendar)
            for occ in occs {
                let type = occ.event.type.isEmpty ? "Other" : occ.event.type
                hoursByType[type, default: 0] += clampedHours(occ.range, on: day)
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
