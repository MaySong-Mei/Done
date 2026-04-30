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
        VStack(alignment: .leading, spacing: 18) {
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
        .padding(14)
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
        VStack(alignment: .leading, spacing: 8) {
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
        .padding(14)
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
    }
}

// MARK: - Token Hypothesis Analysis

struct TokenHypothesisSection: View {
    let analysis: TokenHypothesisAnalysis
    let period: AnalysisPeriod
    let isRefreshing: Bool

    var body: some View {
        if analysis.averageConfidence > 0 {
            VStack(spacing: 14) {
                TokenOverviewCard(analysis: analysis, isRefreshing: isRefreshing)

                NavigationLink {
                    TokenDetailView(analysis: analysis, period: period)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        if period == .day, let day = analysis.latestDay {
                            TokenDayFlowCard(day: day)
                        } else {
                            TokenPeriodFlowCard(analysis: analysis, period: period)
                        }

                        HStack {
                            Text("Open Token Details")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct TokenDetailView: View {
    let analysis: TokenHypothesisAnalysis
    let period: AnalysisPeriod

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if period == .day, let day = analysis.latestDay {
                    TokenDayFlowCard(day: day)
                    TokenEventReasoningCard(day: day)
                    TokenHypothesisCardsPanel(
                        title: "Hypothesis Changes",
                        subtitle: "World-model, state, and meta hypotheses active in this window",
                        hypotheses: day.hypotheses.isEmpty ? analysis.evolvingHypotheses : day.hypotheses
                    )
                } else {
                    TokenPeriodFlowCard(analysis: analysis, period: period)
                    TokenLearningTimelineCard(dayAnalyses: analysis.dayAnalyses)
                    TokenHypothesisCardsPanel(
                        title: "Hypothesis Changes",
                        subtitle: "World-model, state, and meta hypotheses active in this window",
                        hypotheses: analysis.evolvingHypotheses
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Token Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TokenOverviewCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let analysis: TokenHypothesisAnalysis
    let isRefreshing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Token (k/day)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(tokenLabel(analysis.currentToken))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(tokenColor(for: analysis.currentToken))
                    Text(analysis.usedLLM ? "How much mental energy you have for today (AI estimate)" : "How much mental energy you have for today (rough estimate)")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                ConfidenceBadge(confidence: analysis.averageConfidence)
            }

            if isRefreshing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Refreshing")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let fallbackReason = analysis.fallbackReason, !fallbackReason.isEmpty {
                Text(fallbackReason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TokenMetricPill(
                    title: "Physical Calories",
                    value: caloriesLabel(analysis.currentPhysicalCalories),
                    color: .orange
                )
                TokenMetricPill(
                    title: "Tomorrow Token",
                    value: tokenRangeLabel(analysis.nextDayTokenRange),
                    color: .blue
                )
            }

            HStack(spacing: 10) {
                TokenMetricPill(
                    title: "Tomorrow Calories",
                    value: calorieRangeLabel(analysis.nextDayPhysicalCaloriesRange),
                    color: .green
                )
                TokenMetricPill(
                    title: "State",
                    value: primaryStateTag,
                    color: .pink
                )
            }

            if !analysis.currentStateTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(analysis.currentStateTags, id: \.self) { tag in
                            HypothesisChip(title: tag, color: .secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: overviewGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(overviewStrokeColor, lineWidth: 1)
        )
    }

    private func tokenLabel(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return "\(rounded)k"
    }

    private func caloriesLabel(_ value: Double) -> String {
        "\(Int(value.rounded())) cal"
    }

    private func tokenRangeLabel(_ range: ClosedRange<Double>) -> String {
        "\(Int(range.lowerBound.rounded()))k-\(Int(range.upperBound.rounded()))k"
    }

    private func calorieRangeLabel(_ range: ClosedRange<Double>) -> String {
        "\(Int(range.lowerBound.rounded()))-\(Int(range.upperBound.rounded())) cal"
    }

    private func tokenColor(for value: Double) -> Color {
        switch value {
        case ..<35: return .red
        case ..<60: return .orange
        case ..<90: return .primary
        default: return .green
        }
    }

    private var overviewGradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.18, green: 0.15, blue: 0.12),
                Color(red: 0.11, green: 0.14, blue: 0.18)
            ]
        }
        return [
            Color(red: 0.98, green: 0.96, blue: 0.92),
            Color(red: 0.92, green: 0.95, blue: 0.98)
        ]
    }

    private var overviewStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    private var primaryStateTag: String {
        analysis.currentStateTags.first ?? "Observing"
    }
}

private struct TokenMetricPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(fillColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 0.8)
        )
    }

    private var fillColor: Color {
        color.opacity(colorScheme == .dark ? 0.18 : 0.08)
    }

    private var borderColor: Color {
        color.opacity(colorScheme == .dark ? 0.28 : 0.12)
    }
}

private struct ConfidenceBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let confidence: Double

    var body: some View {
        HStack(spacing: 6) {
            Text("Confidence")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(Int((confidence * 100).rounded()))%")
                .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(confidenceColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(confidenceColor.opacity(colorScheme == .dark ? 0.2 : 0.12), in: Capsule())
    }

    private var confidenceColor: Color {
        switch confidence {
        case ..<0.45: return .orange
        case ..<0.7: return .blue
        default: return .green
        }
    }
}

private struct TokenDayFlowCard: View {
    let day: TokenDayAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Token Cognitive Flow (k/day)")
                        .font(.headline)
                    Text(day.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Chart(day.flow) { point in
                AreaMark(
                    x: .value("Step", point.stepIndex),
                    y: .value("Token", point.token)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.orange.opacity(0.35), Color.blue.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Step", point.stepIndex),
                    y: .value("Token", point.token)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.orange)
                .lineStyle(.init(lineWidth: 3, lineCap: .round))

                PointMark(
                    x: .value("Step", point.stepIndex),
                    y: .value("Token", point.token)
                )
                .foregroundStyle(point.confidence < 0.5 ? .orange.opacity(0.65) : .orange)
            }
            .chartXAxis {
                AxisMarks(values: day.flow.map(\.stepIndex)) { value in
                    AxisValueLabel {
                        if let step = value.as(Int.self),
                           let point = day.flow.first(where: { $0.stepIndex == step }) {
                            Text(point.label)
                                .font(.system(size: 10))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 220)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TokenPeriodFlowCard: View {
    let analysis: TokenHypothesisAnalysis
    let period: AnalysisPeriod

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(period == .week ? "Weekly Token Drift (k/day)" : "Token Drift (k/day)")
                .font(.headline)

            Chart(analysis.dayAnalyses) { day in
                LineMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Ending Token", day.endingToken)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.orange)
                .lineStyle(.init(lineWidth: 3, lineCap: .round))

                PointMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Starting Token", day.startingToken)
                )
                .foregroundStyle(Color.blue.opacity(0.5))
                .symbolSize(50)
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .frame(height: 220)

            Text("The orange line tracks projected cognitive token drift. Blue markers show where each day opened before later evidence and reconciliation shifted the posterior.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if let latest = analysis.dayAnalyses.last {
                HStack(spacing: 8) {
                    TokenMetricPill(
                        title: "Physical",
                        value: "\(Int(latest.endingPhysicalCalories.rounded())) cal",
                        color: .green
                    )
                    TokenMetricPill(
                        title: "State",
                        value: latest.stateTags.first ?? "Observing",
                        color: .purple
                    )
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct TokenHypothesisCardsPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String
    let hypotheses: [TokenHypothesisSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if hypotheses.isEmpty {
                Text("The model has not accumulated enough evidence in this window yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(hypotheses) { hypothesis in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hypothesis.statement)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(hypothesis.evidenceSummary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(Int((hypothesis.confidence * 100).rounded()))%")
                                    .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.primary)
                                if abs(hypothesis.confidenceDelta) > 0.01 {
                                    Text(hypothesis.confidenceDelta >= 0 ? "+\(Int((hypothesis.confidenceDelta * 100).rounded()))" : "\(Int((hypothesis.confidenceDelta * 100).rounded()))")
                                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                                        .foregroundStyle(hypothesis.confidenceDelta >= 0 ? .green : .orange)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            HypothesisChip(title: hypothesis.kind.title, color: chipColor(for: hypothesis.kind))
                            HypothesisChip(title: hypothesis.isPersistent ? "Persistent" : "Tentative", color: hypothesis.isPersistent ? .green : .secondary)
                            HypothesisChip(title: "\(hypothesis.supportCount)x", color: .pink)
                        }
                    }
                    .padding(14)
                    .background(rowFill, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(rowStroke, lineWidth: 0.8)
                    )
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func chipColor(for kind: TokenHypothesisKind) -> Color {
        switch kind {
        case .worldModel:
            return .blue
        case .state:
            return .orange
        case .meta:
            return .purple
        case .compressed:
            return .green
        }
    }

    private var rowFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)
    }

    private var rowStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04)
    }
}

private struct HypothesisChip: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(colorScheme == .dark ? 0.2 : 0.12), in: Capsule())
    }
}

private struct TokenEventReasoningCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let day: TokenDayAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Event Reasoning")
                .font(.headline)

            if day.eventAnalyses.isEmpty {
                Text("No timed events landed in this day window.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(day.eventAnalyses) { event in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(event.summary)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 8) {
                                DimensionRow(title: "Cognitive", value: event.dimensions.cognitiveTokenDelta, color: event.dimensions.cognitiveTokenDelta >= 0 ? .green : .orange)
                                DimensionRow(title: "Physical", value: event.dimensions.physicalCaloriesDelta, color: event.dimensions.physicalCaloriesDelta >= 0 ? .green : .pink)
                                DimensionRow(title: "Tomorrow Token", value: event.dimensions.tomorrowTokenDelta, color: event.dimensions.tomorrowTokenDelta >= 0 ? .blue : .red)
                                DimensionRow(title: "Tomorrow Calories", value: event.dimensions.tomorrowCaloriesDelta, color: event.dimensions.tomorrowCaloriesDelta >= 0 ? .blue : .red)
                                DimensionRow(title: "Observability", value: event.dimensions.observability * 100, color: .purple)
                            }

                            if !event.stateTags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(event.stateTags, id: \.self) { tag in
                                            HypothesisChip(title: tag, color: .secondary)
                                        }
                                    }
                                }
                            }

                            if !event.evidence.isEmpty {
                                EvidenceSection(title: "Direct Evidence", items: event.evidence.direct)
                                EvidenceSection(title: "Structural Evidence", items: event.evidence.structural)
                                EvidenceSection(title: "Historical Evidence", items: event.evidence.historical)
                            }

                            if !event.hypotheses.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Affected Hypotheses")
                                        .font(.system(size: 12, weight: .semibold))
                                    ForEach(event.hypotheses.prefix(3)) { hypothesis in
                                        Text("• \(hypothesis.statement)")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.title)
                                    .font(.system(size: 14, weight: .semibold))
                                Text("\(event.typeLabel) • \(timeRangeLabel(start: event.start, end: event.end))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(event.tokenChange >= 0 ? "+\(Int(event.tokenChange.rounded()))k" : "\(Int(event.tokenChange.rounded()))k")
                                    .font(.system(size: 14, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(event.tokenChange >= 0 ? .green : .orange)
                                Text(event.physicalCaloriesChange >= 0 ? "+\(Int(event.physicalCaloriesChange.rounded())) cal" : "\(Int(event.physicalCaloriesChange.rounded())) cal")
                                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                                    .foregroundStyle(event.physicalCaloriesChange >= 0 ? .green : .pink)
                                Text("\(Int((event.confidence * 100).rounded()))%")
                                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(rowFill, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(rowStroke, lineWidth: 0.8)
                    )
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func timeRangeLabel(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        if AppTimeFormat.current.is24 {
            formatter.dateFormat = "H:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }

    private var rowFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)
    }

    private var rowStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04)
    }
}

private struct DimensionRow: View {
    let title: String
    let value: Double
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 110, alignment: .leading)

            ProgressView(value: min(max(abs(value) / scale, 0), 1))
                .tint(color)

            Text(formattedValue)
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)
        }
    }

    private var scale: Double {
        switch title {
        case "Physical", "Tomorrow Calories":
            return 220
        case "Observability":
            return 100
        default:
            return 45
        }
    }

    private var formattedValue: String {
        switch title {
        case "Physical", "Tomorrow Calories":
            return "\(Int(value.rounded())) cal"
        case "Observability":
            return "\(Int(value.rounded()))%"
        default:
            return "\(Int(value.rounded()))k"
        }
    }
}

private struct TokenLearningTimelineCard: View {
    let dayAnalyses: [TokenDayAnalysis]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daily Learning Trace")
                .font(.headline)

            ForEach(dayAnalyses) { day in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(day.endingToken < 40 ? Color.orange : Color.blue)
                        .frame(width: 10, height: 10)
                        .padding(.top, 5)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(dateLabel(day.date))
                            .font(.system(size: 14, weight: .semibold))
                        Text(day.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            HypothesisChip(title: "Token \(Int(day.endingToken.rounded()))k", color: .orange)
                            HypothesisChip(title: "Calories \(Int(day.endingPhysicalCalories.rounded()))", color: .green)
                            if let firstTag = day.stateTags.first {
                                HypothesisChip(title: firstTag, color: .blue)
                            }
                        }
                    }
                }
                if day.id != dayAnalyses.last?.id {
                    Divider()
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

private struct EvidenceSection: View {
    let title: String
    let items: [String]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
