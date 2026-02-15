//
//  AnalysisCharts.swift
//  Done
//

import SwiftUI
import Charts

// MARK: - Time Allocation Pie Chart

struct TimeAllocationChart: View {
    let data: [TypeAllocation]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time Allocation")
                .font(.headline)

            Chart(data) { item in
                SectorMark(
                    angle: .value("Hours", item.hours),
                    innerRadius: .ratio(0.5),
                    angularInset: 1
                )
                .foregroundStyle(item.color)
                .cornerRadius(4)
            }
            .frame(height: 200)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(data) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 8, height: 8)
                        Text(item.type)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1fh", item.hours))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Daily Hours Bar Chart

struct DailyHoursChart: View {
    let data: [DailyHours]
    let period: AnalysisPeriod

    private var uniqueTypes: [(String, Color)] {
        var seen = Set<String>()
        var result: [(String, Color)] = []
        for item in data where seen.insert(item.type).inserted {
            result.append((item.type, item.color))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daily Hours")
                .font(.headline)

            Chart(data) { item in
                BarMark(
                    x: .value("Date", item.date, unit: .day),
                    y: .value("Hours", item.hours)
                )
                .foregroundStyle(by: .value("Type", item.type))
            }
            .chartForegroundStyleScale(
                domain: uniqueTypes.map(\.0),
                range: uniqueTypes.map(\.1)
            )
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: period == .month ? 7 : 1)) { value in
                    if let date = value.as(Date.self) {
                        AxisValueLabel {
                            Text(dayLabel(date))
                                .font(.system(size: 10))
                        }
                    }
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func dayLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        switch period {
        case .day:
            fmt.dateFormat = "MMM d"
        case .week:
            fmt.dateFormat = "EEE"
        case .month:
            fmt.dateFormat = "d"
        }
        return fmt.string(from: date)
    }
}

// MARK: - Task Completion Trend Line Chart

struct TaskCompletionTrendChart: View {
    let data: [CompletionDataPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Task Completions")
                .font(.headline)

            Chart(data) { item in
                LineMark(
                    x: .value("Date", item.date, unit: .day),
                    y: .value("Count", item.count)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.blue)

                PointMark(
                    x: .value("Date", item.date, unit: .day),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(.blue)
            }
            .frame(height: 200)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
