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

// MARK: - Skill Activity Matrix

struct SkillActivityMatrix: View {
    let insights: [SkillInsight]
    let days: [Date]
    let period: AnalysisPeriod

    private var skills: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for i in insights {
            if seen.insert(i.skillName).inserted {
                result.append(i.skillName)
            }
        }
        return result
    }

    private var maxPoints: Double {
        var grid: [String: [Date: Double]] = [:]
        let cal = Calendar.current
        for i in insights {
            let day = cal.startOfDay(for: i.date)
            grid[i.skillName, default: [:]][day, default: 0] += i.points
        }
        return grid.values.flatMap(\.values).max() ?? 1
    }

    private func points(skill: String, day: Date) -> Double {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        return insights
            .filter { $0.skillName == skill && cal.startOfDay(for: $0.date) == dayStart }
            .reduce(0) { $0 + $1.points }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skill Activity")
                .font(.headline)

            // Day labels
            HStack(spacing: 0) {
                Color.clear.frame(width: 90, height: 1)
                ForEach(days, id: \.self) { day in
                    Text(dayLabel(day))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Matrix rows
            let cap = maxPoints
            ForEach(skills, id: \.self) { skill in
                HStack(spacing: 0) {
                    Text(skill)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .frame(width: 90, alignment: .trailing)
                        .padding(.trailing, 6)

                    ForEach(days, id: \.self) { day in
                        let pts = points(skill: skill, day: day)
                        let intensity = pts > 0 ? max(0.2, min(1.0, pts / cap)) : 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(pts > 0 ? Color.blue.opacity(intensity) : Color.primary.opacity(0.06))
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .padding(1.5)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func dayLabel(_ date: Date) -> String {
        let fmt = DateFormatter()
        switch period {
        case .day:
            fmt.dateFormat = "ha"
        case .week:
            fmt.dateFormat = "E"
        case .month:
            fmt.dateFormat = "d"
        }
        return fmt.string(from: date)
    }
}

// MARK: - Skill Growth Bar Chart

struct SkillGrowthChart: View {
    let data: [SkillAggregate]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skill Growth")
                .font(.headline)

            Chart(data) { item in
                BarMark(
                    x: .value("Hours", item.totalPoints),
                    y: .value("Skill", item.skillName)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [.blue.opacity(0.6), .blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(4)
            }
            .chartXAxisLabel("Hours")
            .frame(height: CGFloat(max(data.count, 1)) * 36 + 40)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Skill Insight List

struct SkillInsightList: View {
    let insights: [SkillInsight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Insights")
                .font(.headline)

            ForEach(insights.suffix(10).reversed()) { insight in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(insight.skillName)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text("+\(String(format: "%.1f", insight.points))h")
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundStyle(.blue)
                        }
                        Text(insight.eventTitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(insight.reasoning)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
                if insight.id != insights.suffix(10).reversed().last?.id {
                    Divider()
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
