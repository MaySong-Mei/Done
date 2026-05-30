//
//  AnalysisCharts.swift
//  Done
//

import SwiftUI
import Charts

// MARK: - Swipeable Hours Chart (Allocation + Daily)

struct HoursChartPager: View {
    let allocations: [TypeAllocation]
    let dailyData: [DailyHours]
    let period: AnalysisPeriod
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                TimeAllocationPage(data: allocations)
                    .tag(0)
                DailyHoursPage(data: dailyData, period: period)
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 220)

            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { i in
                    Circle()
                        .fill(page == i ? Color.primary : Color.primary.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 6)
        }
    }
}

private struct TimeAllocationPage: View {
    let data: [TypeAllocation]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Time Allocation")
                .font(.headline)

            HStack(alignment: .center, spacing: 14) {
                Chart(data) { item in
                    SectorMark(
                        angle: .value("Hours", item.hours),
                        innerRadius: .ratio(0.5),
                        angularInset: 1
                    )
                    .foregroundStyle(item.color)
                    .cornerRadius(4)
                }
                .frame(width: 150, height: 150)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(data) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 8, height: 8)
                            Text(item.type)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1fh", item.hours))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DailyHoursPage: View {
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
                                .font(.caption)
                        }
                    }
                }
            }
            .frame(height: 150)
        }
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
    }
}

// MARK: - Game-style Skill Panel

struct SkillPanel: View {
    let data: [SkillAggregate]

    private static let skillColors: [Color] = [.blue, .green, .orange, .purple, .pink]
    private static let hoursPerLevel: Double = 5

    private var topSkills: [SkillAggregate] {
        Array(data.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skills")
                .font(.headline)

            if topSkills.isEmpty {
                Text("No skill data yet")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(topSkills.enumerated()), id: \.element.id) { index, skill in
                    let level = Int(skill.totalPoints / Self.hoursPerLevel) + 1
                    let xpInLevel = skill.totalPoints.truncatingRemainder(dividingBy: Self.hoursPerLevel)
                    let progress = xpInLevel / Self.hoursPerLevel
                    let color = Self.skillColors[index % Self.skillColors.count]

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(skill.skillName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("Lv.\(level)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(color)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(color.opacity(0.15))

                                RoundedRectangle(cornerRadius: 4)
                                    .fill(
                                        LinearGradient(
                                            colors: [color.opacity(0.7), color],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(4, geo.size.width * progress))
                            }
                        }
                        .frame(height: 8)

                        Text(String(format: "%.1f / %.0fh", xpInLevel, Self.hoursPerLevel))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
